<#PSScriptInfo
.VERSION 2026.09.27
.GUID 424533be-1c51-4584-9728-27ea5064d2b7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cleanup ocr pester
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
    Structural (AST) guards on the service VM lifecycle scripts and two
    maintenance entry-point scripts (Remove-TestVMFiles.ps1 and
    Test-WinRtOcr.ps1), plus an isolated run of Stop-CachingProxyServiceVM.ps1.
.DESCRIPTION
    These scripts run top-to-bottom with `exit` and heavy I/O (host contract
    imports, virsh/utmctl, process control), so they are not invoked in-process
    here; the tests parse each file and assert the required SHAPE via AST nodes
    (loop conditions, method invocations, string literals, variable references)
    rather than raw source text, so a code comment cannot satisfy a guard. The
    one execution is the caching-proxy stop, in a separate runspace with every
    host effect stubbed.

    Pinned invariants:
      * Every service Start/Stop script records its intent and takes the
        service's operation lock (Enter-YurunaServiceOperation) after the
        libvirt group relaunch and before its first mutation, names the
        roster key whose manifest lists that script, and runs every later
        exit through a finally that records the result
        (Exit-YurunaServiceOperation) -- the refusal is the only exit
        outside it. Start scripts recheck the intent before building the VM.
      * The caching-proxy stop confirms the stop only from a final state of
        absent read after the removal, and reports anything else as failed.
      * The caching-proxy start makes no bare utmctl call: status and start go
        through the macOS driver's bounded wrappers, or the shared bounded
        runner when the driver is not loaded.
      * The UTM stop-wait loops on a [DateTime]::UtcNow deadline with no
        iteration accumulator (no += / ++ in the loop body, and no variable
        named $waited), and surfaces an unconfirmed stop before the delete.
        The wait lives in Wait-UtmVMPoweredOff, which the host driver's
        Remove-VM runs before deleting a bundle; the guard is scoped to that
        one function so unrelated loops elsewhere in the driver -- some of
        which legitimately count iterations -- cannot satisfy or trip it.
      * Test-WinRtOcr.ps1 names its temp OCR script with a per-run GUID, so
        concurrent runs cannot collide on a fixed shared name.

    These are structural guards: they verify the required nodes are present and
    correctly shaped, not that the scripts execute correctly end to end.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

Describe 'service VM operation dry runs' {
    It 'returns before any side effects for every VM start and stop' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $serviceDir = Join-Path $repoRoot 'test/service'
        $scripts = @(Get-ChildItem -LiteralPath $serviceDir -Filter '*-?*ServiceVM.ps1' -File)
        Assert-Equal -Expected 8 -Actual $scripts.Count -Because 'all four VM service pairs must participate'
        foreach ($script in $scripts) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)
            Assert-Equal -Expected 0 -Actual @($errors).Count -Because "$($script.Name) must parse"
            $first = $ast.EndBlock.Statements[0]
            Assert-True ($first -is [System.Management.Automation.Language.IfStatementAst]) `
                "$($script.Name) must gate before imports or any other operation"
            Assert-True ($first.Extent.Text -match '\$PSCmdlet\.ShouldProcess\(') "$($script.Name) must honor WhatIf"
            # Execute only the real parameter block and first guard. A broken
            # guard reaches this throw, never the launcher's external operations.
            $attributes = @($ast.ParamBlock.Attributes | ForEach-Object { $_.Extent.Text }) -join "`n"
            $guard = [scriptblock]::Create($attributes + "`n" + $ast.ParamBlock.Extent.Text + "`n" + $first.Extent.Text + "`nthrow 'dry run reached side effects'")
            & $guard -WhatIf
            if ($script.Name -eq 'Start-PoolControlServiceVM.ps1') { & $guard -HostSideProof -WhatIf }
        }
    }
}

Describe 'caching proxy stop state across hosts' {
    It 'withdraws the cached address before <Platform> teardown, preserves the password and confirms the stop from the final state' -TestCases @(
        @{ Platform = 'Windows' }, @{ Platform = 'MacOS' }, @{ Platform = 'Linux' }
    ) {
        param($Platform)
        $result = Invoke-CachingProxyStopFixture -Platform $Platform -RemovalSticks $true
        Assert-Equal -Expected 0 -Actual $result.Errors -Because "the isolated $Platform stop script must execute cleanly"
        Assert-Equal -Expected 1 -Actual $result.Returned -Because 'the real stop script must return to the fixture'
        Assert-Equal -Expected 1 -Actual $result.ClearCount -Because 'each host withdraws the persisted address exactly once'
        Assert-StringEqual -Expected '' -Actual $result.AddressAtRemoval -Because 'VM removal must not leave a reusable stale proxy address'
        Assert-StringEqual -Expected 'retained-password' -Actual $result.Password -Because 'stopping the VM must preserve the persistent credential'
        Assert-StringEqual -Expected 'enter,clear-lock' -Actual (($result.Order | Where-Object { $_ -in @('enter', 'clear-lock') }) -join ',') `
            -Because 'the stop intent and operation lock come before the first mutation'
        Assert-StringEqual -Expected 'confirmed|absent' -Actual $result.ExitCall -Because 'a removal that left the VM absent confirms the stop'
        Assert-Equal -Expected 0 -Actual $result.ExitCode
        Assert-Equal -Expected 0 -Actual $result.Warnings
    }

    It 'reports a <Platform> removal that left the VM registered as a failed stop' -TestCases @(
        @{ Platform = 'Windows' }, @{ Platform = 'MacOS' }, @{ Platform = 'Linux' }
    ) {
        param($Platform)
        $result = Invoke-CachingProxyStopFixture -Platform $Platform -RemovalSticks $false
        Assert-Equal -Expected 0 -Actual $result.Errors -Because 'a failed stop is a warning and an exit code, not an error record'
        Assert-StringEqual -Expected 'failed|running' -Actual $result.ExitCall -Because 'the stop request stands, recorded as failed'
        Assert-Equal -Expected 1 -Actual $result.ExitCode
        Assert-Equal -Expected 1 -Actual $result.Warnings
        Assert-Match 'runner\.service_stop_final_state_unexpected' $result.WarningText
    }

    It 'refuses, changing nothing, when the stop cannot be recorded' {
        $result = Invoke-CachingProxyStopFixture -Platform 'Linux' -RemovalSticks $true -Refuse
        Assert-Equal -Expected 1 -Actual $result.Errors -Because 'the refusal is reported'
        Assert-Equal -Expected 1 -Actual $result.ExitCode
        Assert-Equal -Expected 0 -Actual $result.ClearCount -Because 'nothing was changed'
        Assert-StringEqual -Expected 'enter' -Actual ($result.Order -join ',') -Because 'no mutation follows a refusal'
        Assert-StringEqual -Expected '' -Actual $result.ExitCall -Because 'a refused operation has nothing to close'
    }
}

Describe 'service VM lifecycle scripts record their intent around every mutation' {
    It '<Name> records its intent after the relaunch and before its first mutation, under its own roster key' -ForEach @(
        @{ Name = 'Stop-CachingProxyServiceVM.ps1'; FirstMutation = @('Clear-CachingProxyServiceLock') }
        @{ Name = 'Stop-StashServiceVM.ps1'; FirstMutation = @('Remove-ExtensionServiceMarker') }
        @{ Name = 'Stop-PoolControlServiceVM.ps1'; FirstMutation = @('Stop-Process', 'Remove-ExtensionServiceMarker') }
        @{ Name = 'Stop-DownloadAgentServiceVM.ps1'; FirstMutation = @('Remove-DownloadAgentServiceMarker') }
        @{ Name = 'Start-CachingProxyServiceVM.ps1'; FirstMutation = @('Enter-CachingProxyServiceLock') }
        @{ Name = 'Start-StashServiceVM.ps1'; FirstMutation = @('pwsh') }
        @{ Name = 'Start-PoolControlServiceVM.ps1'; FirstMutation = @('pwsh') }
        @{ Name = 'Start-DownloadAgentServiceVM.ps1'; FirstMutation = @('pwsh') }
    ) {
        $path = Join-Path $script:serviceDir $Name
        $ast = Get-ScriptAst $path
        $enter = @(Get-CommandCallAst -Ast $ast -Name 'Enter-YurunaServiceOperation')
        Assert-True ($enter.Count -ge 1) "$Name records its intent"
        $relaunch = @(Get-CommandCallAst -Ast $ast -Name 'Invoke-LibvirtGroupReExecIfNeeded')
        Assert-True ($relaunch.Count -eq 1 -and $relaunch[0].Extent.EndOffset -lt $enter[0].Extent.StartOffset) `
            "$Name records the intent after the relaunch, so the relaunched child is the one that holds the lock"
        $first = @(foreach ($m in $FirstMutation) { Get-CommandCallAst -Ast $ast -Name $m }) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
        Assert-True ($null -ne $first) "$Name still performs its first mutation ($($FirstMutation -join ', '))"
        Assert-True ($enter[0].Extent.EndOffset -lt $first.Extent.StartOffset) "$Name records the intent before '$($first.GetCommandName())'"
        $expectedKey = $script:ScriptKey[$Name]
        foreach ($call in $enter) {
            Assert-StringEqual -Expected "'$expectedKey'" -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'Key') `
                -Because "$Name is listed by the '$expectedKey' manifest"
            $operation = if ($Name -like 'Stop-*') { 'Stop' } else { 'Start' }
            Assert-StringEqual -Expected $operation -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'Operation')
            Assert-StringEqual -Expected "'$Name'" -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'Script')
        }
    }

    It '<Name> closes the operation in a finally on every exit after the intent, except the refusal' -ForEach @(
        @{ Name = 'Stop-CachingProxyServiceVM.ps1' }, @{ Name = 'Stop-StashServiceVM.ps1' }, @{ Name = 'Stop-PoolControlServiceVM.ps1' }
        @{ Name = 'Stop-DownloadAgentServiceVM.ps1' }, @{ Name = 'Start-CachingProxyServiceVM.ps1' }, @{ Name = 'Start-StashServiceVM.ps1' }
        @{ Name = 'Start-PoolControlServiceVM.ps1' }, @{ Name = 'Start-DownloadAgentServiceVM.ps1' }
    ) {
        $ast = Get-ScriptAst (Join-Path $script:serviceDir $Name)
        $enter = @(Get-CommandCallAst -Ast $ast -Name 'Enter-YurunaServiceOperation') | Sort-Object { $_.Extent.StartOffset }
        $guards = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally -and
                    @($n.Finally.FindAll({ param($m) $m -is [System.Management.Automation.Language.CommandAst] -and $m.GetCommandName() -eq 'Exit-YurunaServiceOperation' }, $true)).Count -gt 0
                }, $true))
        Assert-Equal -Expected $enter.Count -Actual $guards.Count -Because "$Name closes each operation it opens"
        $refusals = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -match 'serviceOp\.Proceed'
                }, $true))
        $leaked = @()
        foreach ($ex in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))) {
            if ($ex.Extent.StartOffset -le $enter[0].Extent.EndOffset) { continue }
            $covered = $false
            foreach ($g in @($guards) + @($refusals)) {
                if ($g.Extent.StartOffset -le $ex.Extent.StartOffset -and $g.Extent.EndOffset -ge $ex.Extent.EndOffset) { $covered = $true }
            }
            if (-not $covered) { $leaked += $ex.Extent.StartLineNumber }
        }
        Assert-NoFinding -Finding @($leaked | ForEach-Object { "$Name line $_" }) -Because 'an exit outside the finally would leave the operation lock held and the intent pending'
        foreach ($g in $guards) {
            $confirmed = @($g.Body.FindAll({ param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$serviceOpResult' -and $n.Right.Extent.Text -eq "'confirmed'"
                    }, $true))
            Assert-True ($confirmed.Count -ge 1) "$Name confirms its operation somewhere inside the guarded section"
        }
    }

    It '<Name> rechecks its intent before it builds the VM' -ForEach @(
        @{ Name = 'Start-StashServiceVM.ps1'; Mutation = 'pwsh' }, @{ Name = 'Start-PoolControlServiceVM.ps1'; Mutation = 'pwsh' }
        @{ Name = 'Start-DownloadAgentServiceVM.ps1'; Mutation = 'pwsh' }, @{ Name = 'Start-CachingProxyServiceVM.ps1'; Mutation = 'Initialize-YurunaHost' }
    ) {
        $ast = Get-ScriptAst (Join-Path $script:serviceDir $Name)
        $recheck = @(Get-CommandCallAst -Ast $ast -Name 'Test-YurunaServiceOperationCurrent')
        Assert-True ($recheck.Count -ge 1) "$Name rechecks the intent generation"
        $build = if ($Mutation -eq 'pwsh') {
            @(Get-CommandCallAst -Ast $ast -Name 'pwsh')[0]
        } else {
            # The caching proxy tears the old VM down first; the recheck guards
            # the 'Remove existing VM' region.
            $text = $ast.Extent.Text
            $offset = $text.IndexOf('# --- REGION: Remove existing VM', [StringComparison]::Ordinal)
            [pscustomobject]@{ Extent = [pscustomobject]@{ StartOffset = $offset } }
        }
        Assert-True ($recheck[0].Extent.StartOffset -lt $build.Extent.StartOffset) "$Name rechecks before the VM is torn down or built"
        $enter = @(Get-CommandCallAst -Ast $ast -Name 'Enter-YurunaServiceOperation')[0]
        Assert-True ($enter.Extent.EndOffset -lt $recheck[0].Extent.StartOffset) 'the recheck follows the intent it checks'
    }

    It 'Start-CachingProxyServiceVM.ps1 makes no bare utmctl call' {
        # utmctl reaches UTM over Apple Events; an unanswered consent dialog
        # never returns, so every call goes through a bounded runner.
        $ast = Get-ScriptAst (Join-Path $script:serviceDir 'Start-CachingProxyServiceVM.ps1')
        Assert-Equal -Expected 0 -Actual @(Get-CommandCallAst -Ast $ast -Name 'utmctl').Count -Because 'a bare utmctl call can hang the bring-up'
        $assign = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$cpUtmctl' }, $true))
        Assert-Equal -Expected 1 -Actual $assign.Count
        $router = $assign[0].Right.Expression.ScriptBlock.GetScriptBlock()
        $calls = [System.Collections.Generic.List[string]]::new()
        $withDriver = {
            param($Router, $Calls)
            # Read by the stand-ins below; bound here so the use is visible.
            $null = $Calls
            function Invoke-UtmctlProbe { param([string[]]$Arguments, [int]$TimeoutSeconds, [switch]$Quiet) $Calls.Add("probe:$($Arguments -join ' '):${TimeoutSeconds}:$Quiet"); @{ Started = $true; ExitCode = 0 } }
            function Invoke-UtmctlLifecycle { param([string]$Verb, [string]$VMName, [int]$TimeoutSeconds, [switch]$Quiet) $Calls.Add("lifecycle:$Verb ${VMName}:${TimeoutSeconds}:$Quiet"); @{ Started = $true; ExitCode = 0 } }
            function Invoke-BoundedNativeCommand { param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds) $Calls.Add("native:$FilePath $($ArgumentList -join ' '):$TimeoutSeconds"); @{ Started = $true; ExitCode = 0 } }
            $null = & $Router 'status' 'cache-vm' 7
            $null = & $Router 'start' 'cache-vm' 120
        }
        $shell = [PowerShell]::Create()
        try {
            [void]$shell.AddScript($withDriver.ToString()).AddArgument($router).AddArgument($calls)
            $null = $shell.Invoke()
        } finally { $shell.Dispose() }
        Assert-StringEqual -Expected 'probe:status cache-vm:7:True|lifecycle:start cache-vm:120:True' -Actual ($calls -join '|') -Because 'the driver''s bounded wrappers are used when loaded'
        $calls.Clear()
        $withoutDriver = {
            param($Router, $Calls)
            $null = $Calls
            function Invoke-BoundedNativeCommand { param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds) $Calls.Add("native:$FilePath $($ArgumentList -join ' '):$TimeoutSeconds"); @{ Started = $true; ExitCode = 0 } }
            $null = & $Router 'status' 'cache-vm' 7
        }
        $shell = [PowerShell]::Create()
        try {
            [void]$shell.AddScript($withoutDriver.ToString()).AddArgument($router).AddArgument($calls)
            $null = $shell.Invoke()
        } finally { $shell.Dispose() }
        Assert-StringEqual -Expected 'native:utmctl status cache-vm:7' -Actual ($calls -join '|') -Because 'without the driver the shared bounded runner calls utmctl by name'
    }

    It 'Start-CachingProxyServiceVM.ps1 reports a failed utmctl start through the catalog, and ends the registration wait on time' {
        $ast = Get-ScriptAst (Join-Path $script:serviceDir 'Start-CachingProxyServiceVM.ps1')
        $startFailure = @(Get-CommandCallAst -Ast $ast -Name 'Write-Error' | Where-Object { $_.Extent.Text -match 'utmctl start|utmctl_start' })
        Assert-Equal -Expected 1 -Actual $startFailure.Count
        $keys = @($startFailure[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
        Assert-True ($keys -contains 'runner.service_cachingproxy_utmctl_start_failed') 'the failure text comes from the catalog'
        $window = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$cpRegisterLeft' }, $true))
        Assert-Equal -Expected 1 -Actual $window.Count
        Assert-True ($window[0].Right.Extent.Text -notmatch 'Max\(1') 'a probe never gets more time than the window has left'
        $stop = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$cpRegisterLeft -lt 1' }, $true))
        Assert-Equal -Expected 1 -Actual $stop.Count -Because 'no probe starts with under a second of the window left'
    }

    It 'Stop-PoolControlServiceVM.ps1 keeps the marker, and records a failed stop, when a live host process could not be verified' {
        $result = Invoke-PoolControlStopFixture -HostProcess 'unverified'
        Assert-Equal -Expected 0 -Actual $result.Errors
        Assert-StringEqual -Expected 'enter,remove-vm' -Actual ($result.Order -join ',') -Because 'the process is left running and its marker kept, so a later stop can still find it'
        Assert-StringEqual -Expected 'failed|host-process-running' -Actual $result.ExitCall -Because 'an absent VM does not make the stop complete while the process runs'
        Assert-Equal -Expected 1 -Actual $result.ExitCode
        Assert-True ($result.Warnings -contains 'runner.service_poolcontrol_pid_unverified') 'the unverified pid is named'
        Assert-True ($result.Warnings -contains 'runner.service_poolcontrol_stop_incomplete') 'the incomplete stop is named'
    }

    It 'Stop-PoolControlServiceVM.ps1 stops a verified host process, or none at all, and then clears the marker: <HostProcess>' -ForEach @(
        @{ HostProcess = 'verified'; Order = 'enter,stop-process,remove-marker,remove-vm'; StoppedPid = 4242 }
        @{ HostProcess = 'exited'; Order = 'enter,remove-marker,remove-vm'; StoppedPid = 0 }
        @{ HostProcess = 'none'; Order = 'enter,remove-marker,remove-vm'; StoppedPid = 0 }
    ) {
        $result = Invoke-PoolControlStopFixture -HostProcess $HostProcess
        Assert-Equal -Expected 0 -Actual $result.Errors
        Assert-StringEqual -Expected $Order -Actual ($result.Order -join ',')
        Assert-Equal -Expected $StoppedPid -Actual $result.StoppedPid
        Assert-StringEqual -Expected 'confirmed|absent' -Actual $result.ExitCall
        Assert-Equal -Expected 0 -Actual $result.ExitCode
    }

    It 'Stop-CachingProxyServiceVM.ps1 reads the final state after the removal' {
        $ast = Get-ScriptAst (Join-Path $script:serviceDir 'Stop-CachingProxyServiceVM.ps1')
        $removals = @(Get-CommandCallAst -Ast $ast -Name 'Remove-VM') | Sort-Object { $_.Extent.StartOffset }
        $reads = @(Get-CommandCallAst -Ast $ast -Name 'Get-VMState') | Sort-Object { $_.Extent.StartOffset }
        Assert-True ($reads[-1].Extent.StartOffset -gt $removals[-1].Extent.StartOffset) 'the last state read follows the last removal'
        $regionAt = $ast.Extent.Text.IndexOf('# --- REGION: Report the service state', [StringComparison]::Ordinal)
        Assert-True ($regionAt -ge 0 -and $reads[-1].Extent.StartOffset -gt $regionAt) 'the final read sits in the closing region'
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.CatalogSource.psm1') -DisableNameChecking
$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$script:removeVmFiles = Join-Path $testDir 'Remove-TestVMFiles.ps1'
$script:winRtOcr      = Join-Path $testDir 'check/Test-WinRtOcr.ps1'
$script:utmDriver     = Join-Path (Split-Path -Parent $testDir) 'host/macos.utm/modules/Yuruna.Host.psm1'
$script:serviceDir    = Join-Path $testDir 'service'
$script:stopCpPath    = Join-Path $script:serviceDir 'Stop-CachingProxyServiceVM.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.ExtensionService.psm1') -DisableNameChecking

# The roster key each lifecycle script must record its intent under, read
# from the manifests that name the scripts.
$script:ScriptKey = @{}
foreach ($manifest in @(Get-ExtensionServiceManifestAll -WithVMOnly)) {
    $key = [string]$manifest.Area -replace '-service$', ''
    if ($manifest.StartScript) { $script:ScriptKey[[string]$manifest.StartScript] = $key }
    if ($manifest.StopScript) { $script:ScriptKey[[string]$manifest.StopScript] = $key }
}

function Get-CommandCallAst {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted }.GetNewClosure(), $true))
}

# Text of the argument bound to a named parameter on a CommandAst, covering both
# `-Name value` and `-Name:value` forms.
function Get-NamedArgumentText {
    param($CommandAst, [string]$ParameterName)
    $els = $CommandAst.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $ParameterName) {
            $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
            if ($arg) { return $arg.Extent.Text }
        }
    }
    return $null
}

# Runs the real Stop-CachingProxyServiceVM.ps1 in a separate runspace with
# every host effect stubbed, so its platform branches and preferences stay
# isolated. RemovalSticks decides whether Get-VMState reads absent once
# Remove-VM has run; Refuse makes the intent step refuse.
function Invoke-CachingProxyStopFixture {
    param([string]$Platform, [bool]$RemovalSticks, [switch]$Refuse)
    $driver = {
        param($Path, $Platform, $RemovalSticks, $Refuse)
        # Read by the stand-ins below; bound here so the use is visible.
        $null = $RemovalSticks, $Refuse
        Set-Variable IsWindows -Value ($Platform -eq 'Windows') -Force
        Set-Variable IsMacOS -Value ($Platform -eq 'MacOS') -Force
        Set-Variable IsLinux -Value ($Platform -eq 'Linux') -Force
        $fixture = @{
            CacheState = @{ ipAddress = '192.0.2.10'; password = 'retained-password' }
            AddressAtRemoval = $null
            ClearCount = 0
            Removed = $false
            Order = [System.Collections.Generic.List[string]]::new()
            ExitCall = ''
        }
        function Import-Module {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'Isolated test stub blocks real module loading and filesystem access.')]
            param()
        }
        function Use-LogLevelFromEnv {}
        function Initialize-YurunaEntryPoint { @{ ModulesDir = '/unused/modules' } }
        function Initialize-YurunaEntryPointModuleSet {}
        function Invoke-LibvirtGroupReExecIfNeeded {}
        function Get-HostType { 'test.host' }
        function Format-YurunaOperatorMessage { param([string]$Key) $Key }
        function Enter-YurunaServiceOperation {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated stub records the call without touching any state.')]
            param()
            $fixture.Order.Add('enter')
            [pscustomobject]@{ Proceed = -not $Refuse; Reason = if ($Refuse) { 'operation-busy' } else { 'ok' }; Message = 'refused by fixture' }
        }
        function Exit-YurunaServiceOperation {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated stub records the call without touching any state.')]
            param($Context, [string]$Result, [string]$FinalState)
            $null = $Context
            $fixture.ExitCall = "$Result|$FinalState"
        }
        function Initialize-SudoCache { $true }
        function Clear-CachingProxyServiceLock { $fixture.Order.Add('clear-lock'); @{ Reason = 'no-lock' } }
        function Initialize-YurunaHost { $true }
        function Remove-HostProxy {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param()
            $true
        }
        function Remove-PortMap {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param()
            $true
        }
        function Test-Path {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'Isolated test stub blocks real module loading and filesystem access.')]
            param()
            $false
        }
        function Get-VMHost { @{ VirtualHardDiskPath = '/unused/disks' } }
        function Get-VMState { if ($fixture.Removed -and $RemovalSticks) { 'absent' } else { 'running' } }
        function Stop-VM {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param()
            $true
        }
        function Remove-VM {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a VM.')]
            param()
            $fixture.AddressAtRemoval = $fixture.CacheState.ipAddress
            $fixture.Removed = $true
            $true
        }
        function Remove-Item {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'A rejecting fixture prevents every attempted deletion.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'The isolated test must never delete real files.')]
            param()
            throw 'The stop fixture must never delete files'
        }
        function Get-UbuntuExtensionImageInfo { @{ BaseImageFile = '/unused/base-image' } }
        function Save-CachingProxyServiceState {
            param([string]$IpAddress)
            $fixture.CacheState.ipAddress = $IpAddress
            $fixture.ClearCount++
            $true
        }
        $warned = $null
        & $Path -Confirm:$false -WarningVariable warned -WarningAction SilentlyContinue 1>$null 4>$null 5>$null 6>$null
        $code = $LASTEXITCODE
        $warnings = @($warned | ForEach-Object { "$_" })
        [pscustomobject]@{
            AddressAtRemoval = $fixture.AddressAtRemoval
            Password = $fixture.CacheState.password
            ClearCount = $fixture.ClearCount
            Order = [string[]]$fixture.Order.ToArray()
            ExitCall = $fixture.ExitCall
            ExitCode = $code
            Warnings = $warnings.Count
            WarningText = ($warnings -join "`n")
        }
    }
    $shell = [PowerShell]::Create()
    try {
        [void]$shell.AddScript($driver.ToString()).AddArgument($script:stopCpPath).AddArgument($Platform).AddArgument($RemovalSticks).AddArgument([bool]$Refuse)
        $out = @($shell.Invoke())
        $row = $out | Select-Object -Last 1
        [pscustomobject]@{
            Errors = $shell.Streams.Error.Count; Returned = $out.Count
            AddressAtRemoval = $row.AddressAtRemoval; Password = $row.Password; ClearCount = $row.ClearCount
            Order = $row.Order; ExitCall = $row.ExitCall; ExitCode = $row.ExitCode; Warnings = $row.Warnings; WarningText = $row.WarningText
        }
    } finally {
        $shell.Dispose()
    }
}

# Runs the real Stop-PoolControlServiceVM.ps1 in a separate runspace with every
# host effect stubbed. HostProcess decides what the marker's pid turns out to
# be: a verified host-side daemon, a live process that cannot be verified as
# one, a process that is gone, or no pid at all (a VM deployment).
function Invoke-PoolControlStopFixture {
    param([ValidateSet('verified', 'unverified', 'exited', 'none')][string]$HostProcess)
    $driver = {
        param($Path, $ProcessCase)
        # Read by the stand-ins below; bound here so the use is visible.
        $null = $ProcessCase
        $fixture = @{ Order = [System.Collections.Generic.List[string]]::new(); ExitCall = ''; StoppedPid = 0 }
        function Import-Module {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'Isolated test stub blocks real module loading.')]
            param()
        }
        function Use-LogLevelFromEnv {}
        function Initialize-YurunaEntryPoint { @{ RepoRoot = '/unused'; ModulesDir = '/unused/modules' } }
        function Get-EntryPointExitCode { param([string]$Outcome) if ($Outcome -eq 'Ok') { 0 } else { 1 } }
        function Invoke-LibvirtGroupReExecIfNeeded {}
        function Get-HostType { 'test.host' }
        function Initialize-YurunaHost { $true }
        function Format-YurunaOperatorMessage { param([string]$Key) $Key }
        function Initialize-YurunaRuntimeDir { '/unused/runtime' }
        function Get-ExtensionServiceDeploymentIdentity {
            if ($ProcessCase -eq 'none') { return [pscustomobject]@{ HostingMode = 'vm'; Pid = $null; ProcessStartUnixMs = $null } }
            [pscustomobject]@{ HostingMode = 'host-process'; Pid = 4242; ProcessStartUnixMs = [long]1790000000000 }
        }
        function Enter-YurunaServiceOperation {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated stub records the call without touching any state.')]
            param()
            $fixture.Order.Add('enter')
            [pscustomobject]@{ Proceed = $true; Reason = 'ok'; Message = '' }
        }
        function Exit-YurunaServiceOperation {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated stub records the call without touching any state.')]
            param($Context, [string]$Result, [string]$FinalState)
            $null = $Context
            $fixture.ExitCall = "$Result|$FinalState"
        }
        function Read-ExtensionServiceMarker { [pscustomobject]@{ active = $true; pid = 4242 } }
        function Get-ExtensionServiceHostProcessState {
            switch ($ProcessCase) {
                'verified'   { [pscustomobject]@{ Alive = $true; IdentityVerified = $true; Reason = 'verified' } }
                'unverified' { [pscustomobject]@{ Alive = $true; IdentityVerified = $false; Reason = 'start-time-mismatch' } }
                default      { [pscustomobject]@{ Alive = $false; IdentityVerified = $false; Reason = 'not-running' } }
            }
        }
        function Stop-Process {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'The isolated test must never signal a real process.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a process.')]
            [CmdletBinding()]
            param([int]$Id, [switch]$Force)
            $null = $Force
            $fixture.StoppedPid = $Id
            $fixture.Order.Add('stop-process')
        }
        function Remove-ExtensionServiceMarker {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a file.')]
            param()
            $fixture.Order.Add('remove-marker')
            $true
        }
        function Get-YurunaHostId { 'host' }
        function Write-HostRegistrationRecord { $false }
        function Get-VMState { 'absent' }
        function Remove-GuestVMQuietly {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a VM.')]
            param()
            $fixture.Order.Add('remove-vm')
        }
        $warned = $null
        & $Path -Confirm:$false -WarningVariable warned -WarningAction SilentlyContinue 1>$null 4>$null 5>$null 6>$null
        $code = $LASTEXITCODE
        [pscustomobject]@{
            Order = [string[]]$fixture.Order.ToArray()
            ExitCall = $fixture.ExitCall
            ExitCode = $code
            StoppedPid = $fixture.StoppedPid
            Warnings = [string[]]@($warned | ForEach-Object { "$_" })
        }
    }
    $shell = [PowerShell]::Create()
    try {
        [void]$shell.AddScript($driver.ToString()).AddArgument((Join-Path $script:serviceDir 'Stop-PoolControlServiceVM.ps1')).AddArgument($HostProcess)
        $out = @($shell.Invoke())
        $row = $out | Select-Object -Last 1
        [pscustomobject]@{
            Errors = $shell.Streams.Error.Count
            Order = $row.Order; ExitCall = $row.ExitCall; ExitCode = $row.ExitCode; StoppedPid = $row.StoppedPid; Warnings = $row.Warnings
        }
    } finally {
        $shell.Dispose()
    }
}

function Get-ScriptAst {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path) "script exists: $Path"
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}

# Names of every .Method(...) / [Type]::Method(...) invocation in the tree (AST
# InvokeMemberExpressionAst). Comments are not AST nodes, so a phrase inside a
# comment cannot satisfy a membership test against this list.
function Get-InvokedMember {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        ForEach-Object { $_.Member.Extent.Text })
}

# Condition text of every while-loop in the tree.
function Get-WhileConditionText {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true) |
        ForEach-Object { $_.Condition.Extent.Text })
}

# String LITERAL nodes only (excludes comments).
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

# True when the tree references a variable by name (AST VariableExpressionAst) --
# a name-specific regression pin.
function Test-UsesVariable {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -eq $wanted
    }, $true)).Count -ge 1
}

# True when any while-loop body accumulates an iteration counter (a compound
# assignment += / -= ... or a ++ / -- increment). A wall-clock-bounded wait must
# not also count iterations: a fixed iteration bound in the body could break out
# before the deadline, so the real timeout would drift with per-call cost. This
# catches the defect class regardless of the counter's variable name.
function Test-WhileBodyAccumulator {
    param($Ast)
    foreach ($w in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] }, $true))) {
        $compound = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals
        }, $true))
        if ($compound.Count -ge 1) { return $true }
        $incr = @($w.Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            @('PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') -contains "$($n.TokenKind)"
        }, $true))
        if ($incr.Count -ge 1) { return $true }
    }
    return $false
}

}

Describe 'The UTM stop-wait is bounded by wall-clock' {
    It 'waits on a shared monotonic deadline with no iteration accumulator, and warns when never confirmed stopped' {
        $driverAst = Get-ScriptAst $script:utmDriver
        $findFunction = {
            param([string]$Name)
            $wanted = $Name
            @($driverAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
            }.GetNewClosure(), $true))
        }
        $wait = @(& $findFunction 'Wait-UtmVMPoweredOff')
        Assert-True ($wait.Count -eq 1) 'Wait-UtmVMPoweredOff is defined once in the UTM driver'
        $ast = $wait[0]
        $whileConds = Get-WhileConditionText -Ast $ast
        Assert-True (@($whileConds | Where-Object { $_ -match 'Test-YurunaDeadlineExpired' }).Count -ge 1) 'a while loop gates on the shared monotonic deadline'
        Assert-True (@($whileConds | Where-Object { $_ -match 'UtcNow|Get-Date' }).Count -eq 0) 'no wall-clock reading decides the loop'
        # The deadline is built by the driver's child-deadline helper, which is
        # New-YurunaDeadline on the caller's clock, never later than -Deadline.
        Assert-True ($ast.Extent.Text -match 'Get-UtmChildDeadline') 'the wait builds one deadline for the whole call'
        $child = @(& $findFunction 'Get-UtmChildDeadline')
        Assert-True ($child.Count -eq 1 -and $child[0].Extent.Text -match 'New-YurunaDeadline') 'that deadline is a New-YurunaDeadline'
        Assert-True (-not (Test-WhileBodyAccumulator -Ast $ast)) 'no while-loop body accumulates an iteration counter (+= / ++), which would short-circuit the deadline'
        Assert-True (-not (Test-UsesVariable -Ast $ast -Name 'waited')) 'the specific $waited counter is gone'
        # The warning lives in the removal path that calls the wait.
        $remove = @(& $findFunction 'Remove-UtmTestVM')
        Assert-True ($remove.Count -eq 1 -and $remove[0].Extent.Text -match 'Wait-UtmVMPoweredOff') 'the removal path waits for the power-off'
        $warn = @(Get-CatalogSourceMessage -Source $remove[0].Extent.Text | Where-Object { $_ -match 'did not confirm powered-off|did not confirm stopped' })
        Assert-True ($warn.Count -ge 1) 'an unconfirmed-stop warning is emitted before delete'
    }

    It 'routes the prefix sweep through the host contract rather than utmctl' {
        # The sweep must not re-grow its own hypervisor branch: the stop-wait
        # guarantee above is only reached when removal goes through the
        # driver's Remove-VM.
        $ast = Get-ScriptAst $script:removeVmFiles
        $commands = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        Assert-True ($commands -notcontains 'utmctl') 'the sweep calls no utmctl directly'
        Assert-True ($commands -notcontains 'virsh') 'the sweep calls no virsh directly'
        Assert-True ($commands -contains 'Get-VMName') 'the sweep enumerates through the contract'
        Assert-True ($commands -contains 'Remove-VM') 'the sweep removes through the contract'
    }
}

Describe 'Test-WinRtOcr.ps1 uses a unique temp script name' {
    It 'names the temp OCR script with a per-run GUID, not a fixed shared name' {
        $ast = Get-ScriptAst $script:winRtOcr
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'NewGuid') 'the temp script name includes a NewGuid'
        $fixed = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -eq "'Test-WinRtOcr-run.ps1'" })
        Assert-True ($fixed.Count -eq 0) 'the fixed shared temp name is gone'
    }
}
