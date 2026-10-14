<#PSScriptInfo
.VERSION 2026.10.14
.GUID 428fe362-c96d-4c08-9308-f0535686fefc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host provisioning new-vm dispatch forwarding pester
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
    Behavioral coverage for Invoke-PerGuestNewVm: which optional arguments a
    guest's New-VM.ps1 is handed, in what order, and what the dispatcher says
    about the ones it withholds.
.DESCRIPTION
    A sequence's cascaded values (user name, host name, memory, cores, nested
    virtualization) and the caching-proxy URL reach a guest only through this
    dispatcher, and it hands each one only to a script that declares the
    matching parameter. Nothing fails when a value is dropped by mistake: the
    VM is built, with the wrong user, name or size. The one trace is a Verbose
    line, so both halves are pinned here -- what the child receives, and the
    exact text the operator reads when something is withheld.

    Five things are easy to change without noticing, and each has a case:

      * The order. The child's arguments follow the order the dispatcher
        declares its own parameters, whatever order the guest script declares
        them in. That order is visible in the "Running:" Verbose line and on
        the child's command line.
      * The caching-proxy URL is the exception to "forward only a non-empty
        value". Every caller binds it, and an empty value is how a caller says
        "no cache", so a script that declares it must still receive the empty
        string. It is also the one value withheld without a Verbose line.
      * A script whose parameters cannot be read (it does not parse, or the
        path is not a script file) is treated as declaring nothing.
      * Strict mode. Set in the global scope it reaches the module's
        functions, where reading a key that is not there throws instead of
        yielding $null.
      * The streams. Each driver's New-VM hands back whatever the dispatcher
        writes to its output stream, so that has to be the one result and
        nothing beside it. A parameter lookup that fails is an answer, not an
        error: nothing reaches the error stream, whichever error preference
        is in force.

    The runs are real: each case calls the exported function, which starts a
    child pwsh on a throwaway guest script that reports the parameters it was
    bound with. The script only reports, so no hypervisor, VM, network or host
    driver is involved and the same cases run on Windows, macOS and Linux.

    Text is compared with -BeExactly: the Verbose lines are what an operator
    searches a transcript for, so their case and punctuation are part of the
    contract.

    Run: pwsh -NoProfile -File test/modules/Test.PerGuestNewVm.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking

    # The layout the dispatcher resolves: <RepoRoot>/<HostSubdir>/<GuestKey>/New-VM.ps1.
    $script:FixtureRoot = New-YurunaTestTempDir -Prefix 'yuruna-per-guest-new-vm'
    $script:HostSubdir  = Join-Path 'host' 'fixture.host'
    $script:VMName      = 'vm-under-test'
    # The optional pass-through parameters, in the order the child must receive them.
    $script:Optional = @('CachingProxyServiceUrl', 'Username', 'Hostname', 'MemoryStartupBytes', 'Cores', 'ExposeVirtualizationExtensions')
    # A different value for each, so a value handed over under the wrong name shows.
    $script:Truthy = @{
        CachingProxyServiceUrl         = 'http://10.1.2.3:3128'
        Username                       = 'alice'
        Hostname                       = 'node-a'
        MemoryStartupBytes             = '4GB'
        Cores                          = '2'
        ExposeVirtualizationExtensions = 'true'
    }
    $script:Empty = @{}
    foreach ($name in $script:Optional) { $script:Empty[$name] = '' }
    # No fixture exits with this, so an exit code the dispatcher left alone is
    # distinguishable from a child that ran and returned 0.
    $script:UntouchedExitCode = 91
    # What the guest fixtures print: the parameters they were bound with, in the
    # order they arrived, and any argument they do not declare.
    $script:ReportLines = @(
        'Write-Output ("RECEIVED:" + (ConvertTo-Json -Compress -InputObject @($PSBoundParameters.Keys | ForEach-Object { "$_=$($PSBoundParameters[$_])" })))'
        'Write-Output ("UNDECLARED:" + (ConvertTo-Json -Compress -InputObject @($args | ForEach-Object { "$_" })))'
    )

    function Get-GuestScriptPath {
        param([Parameter(Mandatory)][string]$GuestKey)
        # Composed exactly as the dispatcher composes it: the path appears
        # verbatim in its Verbose lines and in its not-found message.
        return (Join-Path $script:FixtureRoot (Join-Path $script:HostSubdir (Join-Path $GuestKey 'New-VM.ps1')))
    }

    function Write-GuestScript {
        # A guest script that declares -VMName plus $Declare (in that order),
        # reports what it was handed and exits with $ExitCode. -Body replaces
        # the whole script.
        param(
            [Parameter(Mandatory)][string]$GuestKey,
            [string[]]$Declare = @(),
            [int]$ExitCode = 0,
            [string]$Body
        )
        $path = Get-GuestScriptPath -GuestKey $GuestKey
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        if (-not $Body) {
            $declared = @('[string]$VMName') + @($Declare | ForEach-Object { "[string]`$$_ = ''" })
            $Body = (@("param($($declared -join ', '))") + $script:ReportLines + @("exit $ExitCode")) -join "`n"
        }
        [IO.File]::WriteAllText($path, $Body + "`n")
    }

    function Invoke-Dispatch {
        # One call of the real dispatcher. Returns everything it wrote to its
        # output stream, anything it wrote to its error stream, its own
        # forwarding narration (the "Cascaded ..." and "Running: ..." Verbose
        # lines, in order), what the child reported, and the exit code left
        # behind for the caller. -ErrorPreference is handed to the dispatcher
        # as -ErrorAction, which sets the preference inside it whatever the
        # global one is.
        param(
            [Parameter(Mandatory)][string]$GuestKey,
            [hashtable]$Bind = @{},
            [switch]$Preview,
            [string]$ErrorPreference = ''
        )
        $call = @{ HostSubdir = $script:HostSubdir; GuestKey = $GuestKey; RepoRoot = $script:FixtureRoot; VMName = $script:VMName }
        foreach ($name in $Bind.Keys) { $call[$name] = $Bind[$name] }
        if ($Preview) { $call['WhatIf'] = $true } else { $call['Confirm'] = $false }
        if ($ErrorPreference) { $call['ErrorAction'] = $ErrorPreference }
        $relayed = $null
        $global:LASTEXITCODE = $script:UntouchedExitCode
        $emitted = @(Invoke-PerGuestNewVm @call -Verbose -InformationVariable relayed 2>&1 4>&1)
        $exitCode = $global:LASTEXITCODE
        $lines = @($relayed | ForEach-Object { [string]$_.MessageData })
        $report = @{ 'RECEIVED:' = @(); 'UNDECLARED:' = @() }
        $childRan = $false
        foreach ($tag in @($report.Keys)) {
            $line = @($lines | Where-Object { $_.StartsWith($tag, [StringComparison]::Ordinal) })
            if ($line.Count -ne 1) { continue }
            $report[$tag] = @(ConvertFrom-Json -InputObject $line[0].Substring($tag.Length))
            if ($tag -ceq 'RECEIVED:') { $childRan = $true }
        }
        return [pscustomobject]@{
            # Whatever is neither a Verbose nor an error record came down the
            # output stream. It is kept whole rather than filtered by type: a
            # stray value beside the result would reach every caller.
            Result     = @($emitted | Where-Object { $_ -isnot [System.Management.Automation.VerboseRecord] -and $_ -isnot [System.Management.Automation.ErrorRecord] })
            Errors     = (@($emitted | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n")
            Narration  = (@($emitted | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
                        ForEach-Object { $_.Message } | Where-Object { $_ -cmatch '^(Cascaded|Running:) ' }) -join "`n")
            Received   = ($report['RECEIVED:'] -join "`n")
            Undeclared = ($report['UNDECLARED:'] -join "`n")
            ChildRan   = $childRan
            ExitCode   = $exitCode
            ScriptPath = (Get-GuestScriptPath -GuestKey $GuestKey)
        }
    }

    function Confirm-Outcome {
        # The result contract every caller reads: the output stream carries
        # exactly one object, a hashtable with success and errorMessage; the
        # error stream carries nothing; the child's exit code is left in place.
        param(
            [Parameter(Mandatory)]$Run,
            [Parameter(Mandatory)][bool]$Success,
            [string]$ErrorPattern = '',
            [string]$ExitCodePattern = '^0$'
        )
        $Run.Errors | Should -BeExactly '' -Because 'a failure is reported in the result, so the error stream stays silent'
        $Run.Result.Count | Should -Be 1 -Because 'the dispatcher writes exactly one object, its result, to the output stream'
        $result = $Run.Result[0]
        $result | Should -BeOfType ([hashtable]) -Because 'the result is a hashtable'
        (@($result.Keys | Sort-Object) -join ',') | Should -BeExactly 'errorMessage,success' -Because 'callers read these two keys and no others'
        $result.success | Should -BeOfType ([bool]) -Because 'success is a boolean, not a truthy value'
        $result.success | Should -Be $Success -Because "errorMessage: $($result.errorMessage)"
        if ($Success) {
            ($null -eq $result.errorMessage) | Should -BeTrue -Because 'a successful run carries no error message'
        } else {
            [string]$result.errorMessage | Should -MatchExactly $ErrorPattern -Because 'the failure must say what happened'
        }
        [string]$Run.ExitCode | Should -MatchExactly $ExitCodePattern -Because 'the kvm driver reads $LASTEXITCODE right after this call'
    }

    function Get-WithheldNarration {
        # The whole narration for a script at $Path that declares none of the
        # five cascaded parameters when all five are bound to $script:Truthy.
        param([Parameter(Mandatory)][string]$Path)
        return (@(
                "Cascaded -Username 'alice' NOT forwarded: $Path does not declare a -Username parameter."
                "Cascaded -Hostname 'node-a' NOT forwarded: $Path does not declare a -Hostname parameter."
                "Cascaded -MemoryStartupBytes '4GB' NOT forwarded: $Path does not declare a -MemoryStartupBytes parameter."
                "Cascaded -Cores '2' NOT forwarded: $Path does not declare a -Cores parameter."
                "Cascaded -ExposeVirtualizationExtensions 'true' NOT forwarded: $Path does not declare an -ExposeVirtualizationExtensions parameter."
                "Running: $Path -VMName $($script:VMName)"
            ) -join "`n")
    }

    # Declared in reverse, so an order taken from the guest script instead of
    # the dispatcher would show.
    Write-GuestScript -GuestKey 'guest.all' -Declare @('ExposeVirtualizationExtensions', 'Cores', 'MemoryStartupBytes', 'Hostname', 'Username', 'CachingProxyServiceUrl')
    Write-GuestScript -GuestKey 'guest.none'
    # The first, third and fifth: forwarded and withheld values interleave.
    Write-GuestScript -GuestKey 'guest.alternate' -Declare @('CachingProxyServiceUrl', 'Hostname', 'Cores')
    Write-GuestScript -GuestKey 'guest.exit3' -Declare $script:Optional -ExitCode 3
    Write-GuestScript -GuestKey 'guest.anycase' -Body ((@('param([string]$vmname, [string]$USERNAME = '''', [string]$hostName = '''')') + $script:ReportLines) -join "`n")
    # An unclosed parameter list: the file exists and is a script, but has no
    # readable parameters.
    Write-GuestScript -GuestKey 'guest.unparseable' -Body "param([string]`$VMName, [string]`$Username = ''`nexit 0"
    # A directory where the script should be: the path exists, so the dispatcher
    # goes on to read its parameters, and that lookup throws.
    $null = New-Item -ItemType Directory -Path (Get-GuestScriptPath -GuestKey 'guest.directory') -Force
}

AfterAll {
    Remove-YurunaTestTempDir $script:FixtureRoot
}

Describe 'per-guest New-VM dispatch -- what a declaring script receives' {

    It 'hands every bound, non-empty value to a script that declares them all, in the dispatcher''s order' {
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind $script:Truthy
        Confirm-Outcome -Run $run -Success $true
        $expected = @(
            "VMName=$($script:VMName)"
            'CachingProxyServiceUrl=http://10.1.2.3:3128'
            'Username=alice'
            'Hostname=node-a'
            'MemoryStartupBytes=4GB'
            'Cores=2'
            'ExposeVirtualizationExtensions=true'
        ) -join "`n"
        $run.Received | Should -BeExactly $expected -Because 'the child is bound in the order the arguments arrive'
        $run.Undeclared | Should -BeExactly '' -Because 'nothing may reach a script that does not declare it'
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName) -CachingProxyServiceUrl http://10.1.2.3:3128 -Username alice -Hostname node-a -MemoryStartupBytes 4GB -Cores 2 -ExposeVirtualizationExtensions true" `
            -Because 'the Running line is the only narration when nothing is withheld'
    }

    It 'forwards every optional parameter the dispatcher declares, in its declaration order' {
        # Read from the function itself, so a pass-through parameter added to
        # the dispatcher without the forwarding to go with it fails here.
        $command = Get-Command -Name Invoke-PerGuestNewVm
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $optional = @($command.Parameters.Values | Where-Object {
                $_.Name -notin $common -and
                -not @($_.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory })
            } | ForEach-Object { $_.Name })
        ($optional -join ',') | Should -BeExactly ($script:Optional -join ',') -Because 'this suite pins the forwarding of each optional parameter by name; a new one needs its cases here'

        Write-GuestScript -GuestKey 'guest.every' -Declare $optional
        $bind = @{}
        foreach ($name in $optional) { $bind[$name] = "value-of-$name" }
        $run = Invoke-Dispatch -GuestKey 'guest.every' -Bind $bind
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly ((@("VMName=$($script:VMName)") + @($optional | ForEach-Object { "$_=value-of-$_" })) -join "`n")
    }

    It 'hands <Name> alone to a script that declares it' -ForEach @(
        @{ Name = 'CachingProxyServiceUrl'; Value = 'http://10.1.2.3:3128' }
        @{ Name = 'Username'; Value = 'alice' }
        @{ Name = 'Hostname'; Value = 'node-a' }
        @{ Name = 'MemoryStartupBytes'; Value = '4GB' }
        @{ Name = 'Cores'; Value = '2' }
        @{ Name = 'ExposeVirtualizationExtensions'; Value = 'true' }
    ) {
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind @{ $Name = $Value }
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`n$Name=$Value" -Because 'each value is decided on its own binding, not on a neighbor''s'
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName) -$Name $Value"
    }

    It 'hands over nothing optional when the caller bound nothing optional' {
        $run = Invoke-Dispatch -GuestKey 'guest.all'
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)"
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName)"
    }

    It 'treats any non-empty string as a value, including 0 and False' {
        # The values are strings the guest script parses for itself; the
        # dispatcher's only test is "non-empty".
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind @{ Cores = '0'; ExposeVirtualizationExtensions = 'False' }
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`nCores=0`nExposeVirtualizationExtensions=False"
    }

    It 'matches a declared parameter name without regard to case' {
        $run = Invoke-Dispatch -GuestKey 'guest.anycase' -Bind @{ Username = 'alice'; Hostname = 'node-a' }
        Confirm-Outcome -Run $run -Success $true
        # The child reports each parameter under its own spelling of the name.
        $run.Received | Should -BeExactly "vmname=$($script:VMName)`nUSERNAME=alice`nhostName=node-a" -Because 'a script that spells the parameter its own way still declares it'
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName) -Username alice -Hostname node-a" -Because 'the argument is spelled the dispatcher''s way whatever the script''s spelling'
    }
}

Describe 'per-guest New-VM dispatch -- the caching-proxy URL is forwarded even when empty' {

    It 'hands an empty proxy URL to a script that declares it, and withholds the other empty values in silence' {
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind $script:Empty
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`nCachingProxyServiceUrl=" -Because 'an empty URL is how a caller says "no cache"; the script must be told'
        # The trailing space is the empty value after its parameter name.
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName) -CachingProxyServiceUrl " `
            -Because 'an empty value is not a dropped value, so nothing is narrated for the other five'
    }

    It 'binds $null as the empty string: the proxy URL is still forwarded and a null user name is not' {
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind @{ CachingProxyServiceUrl = $null; Username = $null }
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`nCachingProxyServiceUrl="
    }

    It 'withholds the proxy URL from a script that does not declare it, without a Verbose line' {
        $run = Invoke-Dispatch -GuestKey 'guest.none' -Bind @{ CachingProxyServiceUrl = 'http://10.1.2.3:3128' }
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)"
        $run.Undeclared | Should -BeExactly ''
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName)" -Because 'guests that take no proxy are the common case, not a dropped cascade'
    }
}

Describe 'per-guest New-VM dispatch -- what is withheld, and what the operator is told' {

    It 'withholds every value from a script that declares none and narrates the five cascaded ones in order' {
        $run = Invoke-Dispatch -GuestKey 'guest.none' -Bind $script:Truthy
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)"
        $run.Undeclared | Should -BeExactly '' -Because 'an undeclared argument fails a guest script that binds strictly'
        $run.Narration | Should -BeExactly (Get-WithheldNarration -Path $run.ScriptPath) -Because 'this text is what an operator searches a transcript for'
    }

    It 'narrates <Name> alone when only it is bound and the script does not declare it' -ForEach @(
        @{ Name = 'Username'; Value = 'alice'; Article = 'a' }
        @{ Name = 'Hostname'; Value = 'node-a'; Article = 'a' }
        @{ Name = 'MemoryStartupBytes'; Value = '4GB'; Article = 'a' }
        @{ Name = 'Cores'; Value = '2'; Article = 'a' }
        @{ Name = 'ExposeVirtualizationExtensions'; Value = 'true'; Article = 'an' }
    ) {
        $run = Invoke-Dispatch -GuestKey 'guest.none' -Bind @{ $Name = $Value }
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)"
        $expected = @(
            "Cascaded -$Name '$Value' NOT forwarded: $($run.ScriptPath) does not declare $Article -$Name parameter."
            "Running: $($run.ScriptPath) -VMName $($script:VMName)"
        ) -join "`n"
        $run.Narration | Should -BeExactly $expected
    }

    It 'says nothing about an empty value, declared or not' {
        $run = Invoke-Dispatch -GuestKey 'guest.none' -Bind $script:Empty
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)"
        $run.Narration | Should -BeExactly "Running: $($run.ScriptPath) -VMName $($script:VMName)" -Because 'an empty value leaves the guest on its own default; there is no cascade to report'
    }

    It 'narrates a withheld 0 and False like any other non-empty value' {
        $run = Invoke-Dispatch -GuestKey 'guest.none' -Bind @{ Cores = '0'; ExposeVirtualizationExtensions = 'False' }
        Confirm-Outcome -Run $run -Success $true
        $path = $run.ScriptPath
        $expected = @(
            "Cascaded -Cores '0' NOT forwarded: $path does not declare a -Cores parameter."
            "Cascaded -ExposeVirtualizationExtensions 'False' NOT forwarded: $path does not declare an -ExposeVirtualizationExtensions parameter."
            "Running: $path -VMName $($script:VMName)"
        ) -join "`n"
        $run.Narration | Should -BeExactly $expected
    }

    It 'keeps both orders when a script declares every other parameter' {
        # Each list must keep the dispatcher's order, and the Running line must
        # still come last.
        $run = Invoke-Dispatch -GuestKey 'guest.alternate' -Bind $script:Truthy
        Confirm-Outcome -Run $run -Success $true
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`nCachingProxyServiceUrl=http://10.1.2.3:3128`nHostname=node-a`nCores=2"
        $run.Undeclared | Should -BeExactly ''
        $path = $run.ScriptPath
        $expected = @(
            "Cascaded -Username 'alice' NOT forwarded: $path does not declare a -Username parameter."
            "Cascaded -MemoryStartupBytes '4GB' NOT forwarded: $path does not declare a -MemoryStartupBytes parameter."
            "Cascaded -ExposeVirtualizationExtensions 'true' NOT forwarded: $path does not declare an -ExposeVirtualizationExtensions parameter."
            "Running: $path -VMName $($script:VMName) -CachingProxyServiceUrl http://10.1.2.3:3128 -Hostname node-a -Cores 2"
        ) -join "`n"
        $run.Narration | Should -BeExactly $expected
    }
}

Describe 'per-guest New-VM dispatch -- a script whose parameters cannot be read declares nothing' {

    It 'forwards nothing optional to a script that does not parse, and reports its failure' {
        $run = Invoke-Dispatch -GuestKey 'guest.unparseable' -Bind $script:Truthy
        Confirm-Outcome -Run $run -Success $false -ErrorPattern '^New-VM\.ps1 exited with code [1-9][0-9]*$' -ExitCodePattern '^[1-9][0-9]*$'
        $run.ChildRan | Should -BeFalse -Because 'a script that does not parse never reaches its body'
        $run.Narration | Should -BeExactly (Get-WithheldNarration -Path $run.ScriptPath)
    }

    It 'forwards nothing optional when the parameter lookup itself throws, and reports the failure' {
        $path = Get-GuestScriptPath -GuestKey 'guest.directory'
        { Get-Command -Name $path -ErrorAction Stop } | Should -Throw -Because 'the fixture must make the lookup throw, or this case tests nothing'
        $run = Invoke-Dispatch -GuestKey 'guest.directory' -Bind $script:Truthy
        Confirm-Outcome -Run $run -Success $false -ErrorPattern '^New-VM\.ps1 exited with code [1-9][0-9]*$' -ExitCodePattern '^[1-9][0-9]*$'
        $run.ChildRan | Should -BeFalse
        $run.Narration | Should -BeExactly (Get-WithheldNarration -Path $path)
    }

    It 'takes a lookup that throws as an answer, not an error, under error preference <Preference>' -ForEach @(
        @{ Preference = 'Continue' }
        @{ Preference = 'Stop' }
    ) {
        # A suite started on its own runs under Continue and the suite runner
        # sets Stop, so each is named here to keep both covered however the
        # suite is started. Under Continue a lookup left to fail softly would
        # put an error on the stream for a condition the dispatcher handles;
        # under Stop the same failure must not escape as a throw.
        $run = Invoke-Dispatch -GuestKey 'guest.directory' -Bind $script:Truthy -ErrorPreference $Preference
        Confirm-Outcome -Run $run -Success $false -ErrorPattern '^New-VM\.ps1 exited with code [1-9][0-9]*$' -ExitCodePattern '^[1-9][0-9]*$'
        $run.Narration | Should -BeExactly (Get-WithheldNarration -Path $run.ScriptPath)
    }
}

Describe 'per-guest New-VM dispatch -- the result a caller branches on' {

    It 'reports a missing script without starting a child' {
        $run = Invoke-Dispatch -GuestKey 'guest.absent' -Bind $script:Truthy
        $path = Get-GuestScriptPath -GuestKey 'guest.absent'
        Confirm-Outcome -Run $run -Success $false -ErrorPattern ('^' + [regex]::Escape("New-VM.ps1 not found at: $path") + '$') -ExitCodePattern "^$($script:UntouchedExitCode)`$"
        $run.Narration | Should -BeExactly '' -Because 'nothing is forwarded or run for a guest that has no script'
    }

    It 'maps a non-zero child exit to a failure that names the code' {
        $run = Invoke-Dispatch -GuestKey 'guest.exit3' -Bind @{ Username = 'alice' }
        Confirm-Outcome -Run $run -Success $false -ErrorPattern '^New-VM\.ps1 exited with code 3$' -ExitCodePattern '^3$'
        $run.Received | Should -BeExactly "VMName=$($script:VMName)`nUsername=alice" -Because 'the child ran with its arguments before it failed'
    }

    It 'previews without running the child' {
        $run = Invoke-Dispatch -GuestKey 'guest.all' -Bind $script:Truthy -Preview
        Confirm-Outcome -Run $run -Success $false -ErrorPattern '^WhatIf$' -ExitCodePattern "^$($script:UntouchedExitCode)`$"
        $run.ChildRan | Should -BeFalse -Because '-WhatIf must not create anything'
        $run.Narration | Should -BeExactly ''
    }
}

Describe 'per-guest New-VM dispatch -- strict mode in the module scope' {
    # Strict mode set in the global scope (an operator's session, a dot-sourced
    # script) is inherited by every module function. Under it, reading a key or
    # property that is not there throws instead of yielding $null, so a
    # dispatcher that leaned on the lenient read would fail every New-VM on such
    # a host and nowhere else. This Describe runs last: the setting stays on the
    # module until AfterAll.
    BeforeAll {
        $script:DispatcherModule = (Get-Command -Name Invoke-PerGuestNewVm).Module
        . $script:DispatcherModule { Set-StrictMode -Version Latest }
    }
    AfterAll {
        . $script:DispatcherModule { Set-StrictMode -Off }
    }

    It 'has strict mode in force inside the module' {
        $verdict = & $script:DispatcherModule { try { $null = @{ present = 1 }.absent; 'lenient' } catch { 'strict' } }
        $verdict | Should -BeExactly 'strict' -Because 'otherwise the next case proves nothing'
    }

    It 'forwards, withholds and narrates exactly as it does without strict mode' {
        $forwarded = Invoke-Dispatch -GuestKey 'guest.all' -Bind $script:Truthy
        Confirm-Outcome -Run $forwarded -Success $true
        $forwarded.Received | Should -BeExactly "VMName=$($script:VMName)`nCachingProxyServiceUrl=http://10.1.2.3:3128`nUsername=alice`nHostname=node-a`nMemoryStartupBytes=4GB`nCores=2`nExposeVirtualizationExtensions=true"

        $withheld = Invoke-Dispatch -GuestKey 'guest.none' -Bind $script:Truthy
        Confirm-Outcome -Run $withheld -Success $true
        $withheld.Narration | Should -BeExactly (Get-WithheldNarration -Path $withheld.ScriptPath)

        $empty = Invoke-Dispatch -GuestKey 'guest.all' -Bind $script:Empty
        Confirm-Outcome -Run $empty -Success $true
        $empty.Received | Should -BeExactly "VMName=$($script:VMName)`nCachingProxyServiceUrl="

        $unreadable = Invoke-Dispatch -GuestKey 'guest.directory' -Bind $script:Truthy
        Confirm-Outcome -Run $unreadable -Success $false -ErrorPattern '^New-VM\.ps1 exited with code [1-9][0-9]*$' -ExitCodePattern '^[1-9][0-9]*$'
        $unreadable.Narration | Should -BeExactly (Get-WithheldNarration -Path $unreadable.ScriptPath)
    }
}
