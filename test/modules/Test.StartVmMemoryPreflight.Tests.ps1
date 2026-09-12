<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42b5c288-370d-4abd-9a24-488e540acb2d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host hyper-v memory commit start-vm pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    A VM start is admitted against the system commit limit, not against free
    physical memory: the Hyper-V driver must read the right quantity, wait for
    it without ever becoming a failure of its own, and retry only the refusal
    that a wait can actually fix.
.DESCRIPTION
    A guest's startup memory is charged against physical memory plus the page
    file, and with a system-managed page file that ceiling moves by gigabytes
    while nothing else changes. So a start can be refused for want of system
    resources at the moment free physical memory looks healthiest, and a
    teardown returns before the departing guest's reservation is handed back.
    Those two facts are why the driver reads commit, waits for it, and retries.

    THE THREE RULES PINNED HERE, each of which fails silently if it breaks:
      * the refusal classifier matches on numbers, never on English, so a
        localized host does not quietly stop recognizing the condition;
      * the wait is bounded and its timeout RETURNS -- a preflight that threw
        would turn a start that would have succeeded into a new failure mode;
      * the retry is scoped to the resource refusal and capped at one, so a
        standing fault is reported now rather than after a second attempt.

    The functions are lifted out of the driver's source by AST and dot-sourced
    into a scope holding stand-ins for the hypervisor, so no Hyper-V module is
    imported and no VM is ever addressed. The Start-VM stand-in is a plain
    function named for the module-qualified call, which wins over a real
    Hyper-V module in the scope that declares it; every scenario asserts it was
    the stand-in that answered before it asserts anything else.

    Run: pwsh -NoProfile -File test/modules/Test.StartVmMemoryPreflight.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:Driver = Join-Path (Get-YurunaTestRepoRoot -SuiteDirectory $here) 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
$script:Lifted = @{}
foreach ($name in 'Get-HostMemoryStatus', 'Format-HostMemoryStatus', 'Test-HostResourceExhaustionError',
                  'Get-HyperVVMStartupMemory', 'Wait-HostMemoryHeadroom', 'Start-HyperVVM') {
    $fn = Get-YurunaTestFunctionAst -Path $script:Driver -Name $name
    if (-not $fn) { throw "$name is not defined in $script:Driver" }
    $script:Lifted[$name] = $fn.Extent.Text
}

# The three self-contained readers are dot-sourced once, at the scope the tests
# run in; the two that drive the hypervisor are dot-sourced per case, beside the
# stand-ins they must resolve.
. ([scriptblock]::Create($script:Lifted['Get-HostMemoryStatus']))
. ([scriptblock]::Create($script:Lifted['Format-HostMemoryStatus']))
. ([scriptblock]::Create($script:Lifted['Test-HostResourceExhaustionError']))

$script:NoSystemResources = -2147023446

function New-HostMemoryReading {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory reading for a test case; it changes nothing a confirmation could protect.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int64]$CommitAvailableBytes, [int64]$CommitLimitBytes = 48GB)
    return @{
        availableMb          = [int64]($CommitAvailableBytes / 1MB)
        committedBytes       = $CommitLimitBytes - $CommitAvailableBytes
        commitLimitBytes     = $CommitLimitBytes
        commitAvailableBytes = $CommitAvailableBytes
        source               = 'Win32_OperatingSystem'
    }
}

function New-ResourceRefusal {
    <#
    .SYNOPSIS
        The exception shape a host refusing an allocation produces, built the
        three ways the refusal has been observed to arrive.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory exception for a test case; it changes nothing a confirmation could protect.')]
    [CmdletBinding()]
    [OutputType([System.Exception], [System.Runtime.InteropServices.COMException], [System.InvalidOperationException], [System.ComponentModel.Win32Exception])]
    param([ValidateSet('hresult', 'inner', 'win32', 'text', 'lowercase', 'other-hresult', 'unrelated', 'access')][string]$Shape)
    switch ($Shape) {
        'hresult' {
            $e = [System.Runtime.InteropServices.COMException]::new("'guest' could not initialize.")
            $e.HResult = -2147023446
            return $e
        }
        'inner' {
            $inner = [System.Runtime.InteropServices.COMException]::new('not enough storage is available.')
            $inner.HResult = -2147023446
            return [System.InvalidOperationException]::new("'guest' failed to start.", $inner)
        }
        'win32'         { return [System.ComponentModel.Win32Exception]::new(1450) }
        'text'          { return [System.Exception]::new("Ressources systeme insuffisantes. (0x800705AA)") }
        'lowercase'     { return [System.Exception]::new('failed to start (0x800705aa)') }
        'other-hresult' {
            $e = [System.Runtime.InteropServices.COMException]::new("'guest' is not in a valid state. (0x8007053C)")
            $e.HResult = -2147023556
            return $e
        }
        'access'        { return [System.ComponentModel.Win32Exception]::new(5) }
        default         { return [System.Exception]::new("'guest' failed to start: the virtual disk is in use.") }
    }
}

function ConvertTo-CaughtErrorRecord {
    <#
    .SYNOPSIS
        The same exception as the ErrorRecord a catch block actually receives.
    .DESCRIPTION
        The classifier is handed $_ from a catch, never a bare exception, and
        the wrapping is where a chain-walking bug would hide.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.ErrorRecord])]
    param([Parameter(Mandatory)][Exception]$Exception)
    try { throw $Exception } catch { return $_ }
}

function Invoke-HeadroomWait {
    <#
    .SYNOPSIS
        Run the lifted wait against a scripted sequence of host readings.
    .DESCRIPTION
        Start-Sleep is shadowed for the length of the call so a poll costs
        milliseconds instead of seconds, and so the test can state how many
        times the wait actually slept. The stopwatch the wait bounds itself
        with is real either way, so the budget still ends the loop.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Start-Sleep is shadowed on purpose and only inside this call, so a bounded wait can be exercised in milliseconds and its sleeps counted. The stub goes out of scope with the function.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is read by the stand-in functions declared in this scope; the analyzer does not follow references into a nested function body.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [object[]]$Reading,
        [int64]$RequiredBytes,
        [int]$TimeoutSeconds = 1,
        [int]$PollSeconds = 1
    )
    $seen = [pscustomobject]@{ Index = 0; Sleeps = 0 }
    function Get-HostMemoryStatus {
        $value = $Reading[[Math]::Min($seen.Index, $Reading.Count - 1)]
        $seen.Index++
        return $value
    }
    function Start-Sleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the built-in of the same name, so the wait under test can be driven in milliseconds; a confirmation prompt would hang the run.')]
        param([int]$Seconds, [int]$Milliseconds)
        $seen.Sleeps++
        [System.Threading.Thread]::Sleep(25)
    }
    . ([scriptblock]::Create($script:Lifted['Wait-HostMemoryHeadroom']))
    $result = Wait-HostMemoryHeadroom -RequiredBytes $RequiredBytes -Label "'guest'" `
        -TimeoutSeconds $TimeoutSeconds -PollSeconds $PollSeconds 6>$null
    return @{ Result = $result; Readings = $seen.Index; Sleeps = $seen.Sleeps }
}

function Invoke-StartCase {
    <#
    .SYNOPSIS
        Run the lifted Start-HyperVVM against a stand-in hypervisor.
    .DESCRIPTION
        The stand-ins are declared in this scope, which is where the lifted
        function is dot-sourced, so it resolves them exactly as it resolves its
        real siblings and nothing survives the call. $env:SystemRoot is pointed
        at an empty directory so the vmconnect leg -- which is not what this
        file is about -- finds no executable and is skipped.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
        Justification = 'Start-Sleep is shadowed on purpose and only inside this call, so the retry pause costs milliseconds. The stub goes out of scope with the function.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Every parameter is read by the stand-in functions declared in this scope; the analyzer does not follow references into a nested function body.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [int]$RefusalCount = 0,
        [string]$RefusalShape = 'hresult',
        [string]$VMState = 'off',
        [int64]$StartupMemory = 2GB,
        [hashtable]$Reading,
        [int]$MemoryWaitSeconds = 45,
        [switch]$AsWhatIf
    )
    $seen = [pscustomobject]@{ Starts = 0; Definitions = 0; Sleeps = 0 }
    function Hyper-V\Start-VM {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
            Justification = 'The name is the module-qualified call the driver makes, not a verb-noun pair; spelling it exactly is what makes the stand-in resolve.')]
        param($Name, $ErrorAction, $WarningAction)
        $seen.Starts++
        if ($seen.Starts -le $RefusalCount) { throw (New-ResourceRefusal -Shape $RefusalShape) }
    }
    function Hyper-V\Get-VM {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '',
            Justification = 'The name is the module-qualified call the driver makes, not a verb-noun pair; spelling it exactly is what makes the stand-in resolve.')]
        param($Name, $ErrorAction)
        $seen.Definitions++
        if ($StartupMemory -le 0) { throw "Hyper-V could not find a virtual machine named '$Name'." }
        return [pscustomobject]@{ MemoryStartup = $StartupMemory }
    }
    function Get-VMState { param($VMName) $VMState }
    function Get-HostMemoryStatus { $Reading }
    function Start-Sleep {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stand-in for the built-in of the same name, so the retry pause costs milliseconds; a confirmation prompt would hang the run.')]
        param([int]$Seconds, [int]$Milliseconds)
        $seen.Sleeps++
        [System.Threading.Thread]::Sleep(25)
    }
    # Proof that the stand-in is what answers: a Cmdlet here would mean a real
    # Hyper-V module resolved the call, and the case must never reach a live
    # hypervisor to find that out.
    $resolved = Get-Command 'Hyper-V\Start-VM'
    if ($resolved.CommandType -ne 'Function') {
        throw "the Start-VM stand-in did not take precedence (resolved a $($resolved.CommandType) from $($resolved.ModuleName)); refusing to address a live hypervisor"
    }
    . ([scriptblock]::Create($script:Lifted['Get-HyperVVMStartupMemory']))
    . ([scriptblock]::Create($script:Lifted['Wait-HostMemoryHeadroom']))
    . ([scriptblock]::Create($script:Lifted['Start-HyperVVM']))

    $savedSystemRoot = $env:SystemRoot
    $emptyRoot = Join-Path ([IO.Path]::GetTempPath()) ('yrn-startvm-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
    $env:SystemRoot = $emptyRoot
    try {
        $result = if ($AsWhatIf) {
            Start-HyperVVM -VMName 'stand-in.guest' -MemoryWaitSeconds $MemoryWaitSeconds -WhatIf 6>$null
        } else {
            Start-HyperVVM -VMName 'stand-in.guest' -MemoryWaitSeconds $MemoryWaitSeconds 6>$null
        }
    } finally {
        $env:SystemRoot = $savedSystemRoot
        Remove-Item -LiteralPath $emptyRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    return @{ Result = $result; Starts = $seen.Starts; Definitions = $seen.Definitions; Sleeps = $seen.Sleeps }
}

$script:Ample = New-HostMemoryReading -CommitAvailableBytes 30GB
$script:Short = New-HostMemoryReading -CommitAvailableBytes 1GB
}

Describe 'a refusal for want of system resources is recognized by its number' {

    # Every word around the code is translated on a localized host, and those are
    # the machines least likely to be watched. The digits are not translated.
    It 'matches the refusal however the failing call wrapped it' {
        foreach ($shape in 'hresult', 'inner', 'win32', 'text', 'lowercase') {
            $bare = New-ResourceRefusal -Shape $shape
            Assert-True (Test-HostResourceExhaustionError -ErrorRecord $bare) "as an exception, the $shape shape must be recognized"
            Assert-True (Test-HostResourceExhaustionError -ErrorRecord (ConvertTo-CaughtErrorRecord -Exception $bare)) `
                "as the ErrorRecord a catch receives, the $shape shape must be recognized"
        }
    }

    It 'matches nothing else, so a standing fault is never retried as a transient one' {
        foreach ($shape in 'other-hresult', 'access', 'unrelated') {
            $bare = New-ResourceRefusal -Shape $shape
            Assert-False (Test-HostResourceExhaustionError -ErrorRecord $bare) "the $shape shape is not a resource refusal"
            Assert-False (Test-HostResourceExhaustionError -ErrorRecord (ConvertTo-CaughtErrorRecord -Exception $bare)) `
                "the $shape shape is not a resource refusal, wrapped either"
        }
        Assert-False (Test-HostResourceExhaustionError -ErrorRecord $null) 'nothing to classify is not a refusal'
    }

    It 'rests the text fallback on the code alone, not on the sentence around it' {
        $body = (Get-YurunaTestFunctionAst -Path $script:Driver -Name 'Test-HostResourceExhaustionError').Extent.Text
        $comparisons = [regex]::Matches($body, "-match\s+'(?<pattern>[^']*)'")
        Assert-True ($comparisons.Count -ge 1) 'the classifier must keep a rendered-text fallback'
        foreach ($comparison in $comparisons) {
            $pattern = $comparison.Groups['pattern'].Value
            Assert-True ($pattern -match '^[\s|0-9a-fA-FxX]+$') `
                "a text match on words stops working on a localized host: '$pattern'"
        }
        Assert-True ($body.Contains([string]$script:NoSystemResources)) `
            'the numeric comparison must state the HRESULT the refusal carries'
    }
}

Describe 'the host states its own memory position' {

    It 'reads commit, and the reading is internally consistent' {
        if (-not $IsWindows) {
            Set-ItResult -Skipped -Because 'the counters read here are the Windows ones; the driver is the Windows host driver'
            return
        }
        $status = Get-HostMemoryStatus
        Assert-NotNull $status 'a Windows host that answers WMI or its performance counters must state its position'
        Assert-True ($status.commitLimitBytes -gt 0) "commit limit must be a real quantity: $($status.commitLimitBytes)"
        Assert-True ($status.committedBytes -gt 0) "a running host has commit charged: $($status.committedBytes)"
        Assert-True ($status.committedBytes -le $status.commitLimitBytes) 'a host cannot have charged more than its limit'
        Assert-Equal -Expected ($status.commitLimitBytes - $status.committedBytes) -Actual $status.commitAvailableBytes `
            -Because 'uncharged commit is the limit less the charge, and the wait compares against it'
        Assert-True ($status.availableMb -ge 0) "available physical memory must be a count: $($status.availableMb)"
        Assert-True (@('Win32_OperatingSystem', 'Win32_PerfRawData_PerfOS_Memory') -contains $status.source) `
            "the reading must name which source answered: $($status.source)"
    }

    It 'states commit before physical, because commit is what admits the start' {
        $line = Format-HostMemoryStatus -Status (New-HostMemoryReading -CommitAvailableBytes 2GB)
        Assert-Match 'commit' $line 'the operator-facing line has to name the quantity the decision was made on'
        Assert-True ($line.IndexOf('commit') -lt $line.IndexOf('physical')) `
            "physical memory read first is what misleads; commit comes first: $line"
        Assert-Equal -Expected 'host memory position unreadable' -Actual (Format-HostMemoryStatus -Status $null) `
            -Because 'an unreadable host must say so rather than render as zeros'
    }
}

Describe 'the wait for headroom is bounded, and a timeout is not a failure' {

    It 'does not wait when there is nothing to wait for' {
        $unknownSize = Invoke-HeadroomWait -Reading @($script:Short) -RequiredBytes 0
        Assert-True $unknownSize.Result.Satisfied 'an unknown allocation size gives no predicate, so there is nothing to wait for'
        Assert-Equal -Expected 0 -Actual $unknownSize.Sleeps -Because 'such a wait could only spend its whole budget'

        $unreadable = Invoke-HeadroomWait -Reading @($null) -RequiredBytes 2GB
        Assert-True $unreadable.Result.Satisfied 'a host that will not state its position gives nothing to wait for either'
        Assert-Equal -Expected 0 -Actual $unreadable.Sleeps -Because 'no reading, no wait'
    }

    It 'returns at once when the host already holds the allocation' {
        $run = Invoke-HeadroomWait -Reading @($script:Ample) -RequiredBytes 2GB
        Assert-True $run.Result.Satisfied 'ample headroom is satisfied on the first reading'
        Assert-Equal -Expected 0 -Actual $run.Sleeps -Because 'the common case must cost nothing'
        Assert-Equal -Expected 0 -Actual $run.Result.WaitedSeconds -Because 'no time was spent'
    }

    It 'waits for a departing guest to hand its reservation back' {
        $run = Invoke-HeadroomWait -Reading @($script:Short, $script:Short, $script:Ample) -RequiredBytes 2GB -TimeoutSeconds 10
        Assert-True $run.Result.Satisfied 'headroom that arrives during the budget must end the wait'
        Assert-True ($run.Sleeps -ge 1) 'it must actually have waited'
        Assert-True ($run.Result.Status.commitAvailableBytes -ge 2GB) 'the reading it returns is the one that satisfied the request'
    }

    # The hypervisor's own answer is the authoritative one and the only one that
    # carries a diagnosable error. A preflight that threw here would replace a
    # start that might well succeed with a guess about one nobody attempted.
    It 'gives up by returning, never by throwing' {
        $run = Invoke-HeadroomWait -Reading @($script:Short) -RequiredBytes 40GB -TimeoutSeconds 1
        Assert-False $run.Result.Satisfied 'an unsatisfiable request must report that it was not satisfied'
        Assert-True ($run.Result.WaitedSeconds -le 3) "the budget bounds the wait: $($run.Result.WaitedSeconds)s"
        Assert-NotNull $run.Result.Status 'the caller is handed the last reading, for the record it is about to write'
    }
}

Describe 'Start-VM waits, attempts, and retries only what a wait can fix' {

    It 'starts the guest once when the host holds the memory' {
        $run = Invoke-StartCase -Reading $script:Ample
        Assert-True $run.Result.success 'a clean start succeeds'
        Assert-Equal -Expected 1 -Actual $run.Starts -Because 'one start, no retry'
        Assert-NotNull $run.Result['hostMemory'] 'the result carries the reading taken before the attempt'
        Assert-Equal -Expected 0 -Actual $run.Sleeps -Because 'an unloaded host pays nothing for the preflight'
    }

    It 'retries a resource refusal once, and succeeds when the memory comes back' {
        $run = Invoke-StartCase -Reading $script:Ample -RefusalCount 1
        Assert-True $run.Result.success 'the second attempt succeeds'
        Assert-Equal -Expected 2 -Actual $run.Starts -Because 'the refusal is transient by nature: one retry'
        Assert-True ($run.Sleeps -ge 1) 'the retry pauses before re-reading, or it retries into the same instant'
    }

    It "stops after the retry, and reports the hypervisor's own words" {
        $run = Invoke-StartCase -Reading $script:Short -RefusalCount 2 -MemoryWaitSeconds 0
        Assert-False $run.Result.success 'two refusals are a failure'
        Assert-Equal -Expected 2 -Actual $run.Starts -Because 'the retry is capped at one'
        Assert-Match 'stand-in.guest' $run.Result.errorMessage 'the message must name the guest'
        Assert-Match 'could not initialize' $run.Result.errorMessage `
            "the hypervisor's own text is the diagnosable part and must not be replaced"
        Assert-NotNull $run.Result['hostMemory'] 'a refusal must carry what the machine held when it refused'
        Assert-Equal -Expected 1GB -Actual $run.Result['hostMemory'].commitAvailableBytes `
            -Because 'the reading is the position the refusal was made in'
    }

    It 'does not retry a failure a wait cannot fix' {
        $run = Invoke-StartCase -Reading $script:Ample -RefusalCount 1 -RefusalShape 'unrelated'
        Assert-False $run.Result.success 'a standing fault fails'
        Assert-Equal -Expected 1 -Actual $run.Starts -Because 'a second attempt would only delay the report'
    }

    # The wait can delay a start; it can never prevent one.
    It 'attempts the start even when the headroom never arrives' {
        $run = Invoke-StartCase -Reading $script:Short -MemoryWaitSeconds 1
        Assert-True $run.Result.success 'an unsatisfied preflight must not stop the attempt'
        Assert-Equal -Expected 1 -Actual $run.Starts -Because 'the hypervisor states the outcome, not the wait'
    }

    It 'skips the wait when there is no size to wait for' {
        $run = Invoke-StartCase -Reading $script:Short -StartupMemory 0 -MemoryWaitSeconds 5
        Assert-True $run.Result.success 'an unreadable VM definition must not stop the start'
        Assert-Equal -Expected 0 -Actual $run.Sleeps -Because 'no size, no predicate, no wait'
    }

    It 'skips the wait for a guest that is already running' {
        $run = Invoke-StartCase -Reading $script:Short -VMState 'running' -MemoryWaitSeconds 5
        Assert-True $run.Result.success 'a start against a running guest is a no-op'
        Assert-Equal -Expected 0 -Actual $run.Definitions -Because 'a running guest already holds its commit, so its size is not even asked for'
        Assert-Equal -Expected 0 -Actual $run.Sleeps -Because 'the common restart path must cost nothing'
    }

    It 'starts nothing under -WhatIf' {
        $run = Invoke-StartCase -Reading $script:Ample -AsWhatIf
        Assert-Equal -Expected 0 -Actual $run.Starts -Because 'ShouldProcess gates the whole attempt'
        Assert-True $run.Result.success 'a declined start is not a failure'
    }
}

Describe 'the driver publishes what the runner and the record builder call' {

    It 'exports every function the failure record and the preflight depend on' {
        $source = Get-Content -Raw -LiteralPath $script:Driver
        $export = [regex]::Match($source, '(?s)Export-ModuleMember\s+-Function\s+(?<names>.+?)\r?\n\r?\n')
        Assert-True $export.Success 'the driver must carry an Export-ModuleMember block'
        foreach ($name in 'Get-HostMemoryStatus', 'Format-HostMemoryStatus', 'Test-HostResourceExhaustionError',
                          'Wait-HostMemoryHeadroom', 'Get-HyperVVMStartupMemory') {
            Assert-Match $name $export.Groups['names'].Value "an unexported $name is invisible outside the driver"
        }
    }

    # The other host drivers return a start result with no hostMemory key at all,
    # so the runner reads it with the indexer. Naming the key in the result is
    # what makes that read worth doing.
    It 'returns the reading under the key the runner indexes' {
        $run = Invoke-StartCase -Reading $script:Ample
        Assert-True ($run.Result -is [hashtable]) 'the start result is a hashtable the caller indexes'
        Assert-True ($run.Result.ContainsKey('hostMemory')) 'the Windows driver states the reading under hostMemory'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
