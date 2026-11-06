<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42541303-69a5-4838-b859-71ad4fcefc3e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service lifecycle pid pester
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
    Structural (AST) guards on the host-service lifecycle entry-point scripts:
    Stop-ConfigService.ps1, Stop-StatusService.ps1, Start-ConfigService.ps1,
    and Start-StashServiceVM.ps1, and the teardown order of the shared
    Stop-ExtensionService.ps1.
.DESCRIPTION
    These scripts run top-to-bottom with `exit`/`return` and heavy I/O
    (Import-Module, runtime-dir init, process control), so they are not
    invoked in-process here; instead the tests parse each file and assert the
    required defensive SHAPE via AST nodes (method invocations, command
    arguments, string literals) rather than raw source text -- so a code comment
    cannot satisfy a guard and reformatting cannot break one. The shared
    extension stop is the exception: it runs in a runspace of its own against
    stand-ins that record every host effect, so its teardown order is observed
    rather than read.

    Pinned invariants:
      * Both Stop-* scripts gate on an [int]::TryParse of the PID file (the parse
        result controls a stale-PID exit) before Get-Process/Stop-Process, and
        pass the typed int (not the raw string) to -Id -- a raw non-numeric
        string reaches -Id and throws a ParameterBindingException that
        -ErrorAction SilentlyContinue does NOT suppress.
      * Start-ConfigService gates on an [int]::TryParse of the Linux detached
        child's echoed PID and probes Get-Process -Id $bgPidInt right after
        launch, so a PID file is never written for a process that died
        immediately.

    These are structural guards: they verify the required nodes are present and
    correctly shaped/gated, not that the scripts execute correctly end to end.
      * Start-StashServiceVM captures the status-service start decision (rather than
        discarding it) and TCP-probes the status port via BeginConnect, warning
        when the host will not be reachable by the pool-aggregator service.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$testDir = Split-Path -Parent $here   # .../test

$script:startHostConfig = Join-Path $testDir 'service/Start-ConfigService.ps1'
$script:startStash      = Join-Path $testDir 'service/Start-StashServiceVM.ps1'
$script:stopExtension   = Join-Path $testDir 'service/Stop-ExtensionService.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.ServiceStartSource.psm1') -Force -DisableNameChecking

function Get-ScriptAst {
    param([string]$Path)
    return Get-YurunaTestFileAst -Path $Path
}

function Get-CommandCall {
    param($Ast, [string]$Name)
    # Bind to a local so the parameter is referenced in the function body itself
    # (the closure below captures it, but PSReviewUnusedParameter cannot see a
    # use that only occurs inside a scriptblock handed to another command).
    $wanted = $Name
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted }, $true))
}

# Text of the argument bound to -Id on a Get-Process/Stop-Process CommandAst.
function Get-IdArgumentText {
    param($CommandAst)
    $els = $CommandAst.CommandElements
    for ($i = 0; $i -lt $els.Count; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Id') {
            $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
            if ($arg) { return $arg.Extent.Text }
        }
    }
    return $null
}

# Names of every .Method(...) / [Type]::Method(...) invocation in the tree (AST
# InvokeMemberExpressionAst). Comments are not AST nodes, so a phrase inside a
# comment cannot satisfy a membership test against this list.
function Get-InvokedMember {
    param($Ast)
    @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        ForEach-Object { $_.Member.Extent.Text })
}

# Names of every method invoked INSIDE an if-statement condition. A guard that
# checks membership here verifies the invocation gates a branch (e.g. the
# [int]::TryParse result controls the stale-PID exit), not merely that it appears
# somewhere as a discarded expression.
function Get-IfConditionMember {
    param($Ast)
    $names = @()
    foreach ($ifs in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true))) {
        foreach ($clause in $ifs.Clauses) {
            $names += @($clause.Item1.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
                ForEach-Object { $_.Member.Extent.Text })
        }
    }
    $names
}

# String LITERAL nodes only (excludes comments), so a phrase match cannot be
# satisfied by an unrelated code comment.
function Get-StringLiteralExtent {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true) | ForEach-Object { $_.Extent.Text })
}

# True when some assignment binds the named command's result to a REAL variable
# (not the $null / $_ discard idioms, which capture nothing) -- proving the
# result is retained rather than thrown away.
function Test-AssignsFromCommand {
    param($Ast, [string]$Command)
    $wanted = $Command
    foreach ($a in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $lhs = $a.Left
        if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $lhsName = $lhs.VariablePath.UserPath
            if ($lhsName -eq 'null' -or $lhsName -eq '_') { continue }
        }
        foreach ($c in @($a.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            if ($c.GetCommandName() -eq $wanted) { return $true }
        }
    }
    return $false
}

# Extent text of every value assigned to a named variable anywhere in the tree.
# An AssignmentStatementAst, so a mention of the variable in a comment or a
# string cannot register as an assignment.
function Get-AssignedValueText {
    param($Ast, [string]$Variable)
    $wanted = $Variable
    $out = @()
    foreach ($a in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $lhs = $a.Left
        if ($lhs -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $lhs.VariablePath.UserPath -eq $wanted) {
            $out += $a.Right.Extent.Text
        }
    }
    $out
}

# Runs the real Stop-ExtensionService.ps1 in a runspace of its own with every
# module and host effect replaced by a stand-in that records its call, for a
# service deployed on a VM (no host-side process to stop). VMPresent decides
# whether the host still has the VM registered when the stop begins.
function Invoke-ExtensionStopFixture {
    param([Parameter(Mandatory)][string]$ServiceKey, [Parameter(Mandatory)][string]$Area, [bool]$VMPresent = $true)
    $driver = {
        param($Path, $ServiceKey, $Area, $VMPresent)
        # Read by the stand-ins below; bound here so the use is visible.
        $null = $VMPresent
        $fixture = @{ Order = [System.Collections.Generic.List[string]]::new(); ExitCall = ''; Removed = $false }
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
        function Get-ExtensionServiceDeploymentIdentity { [pscustomobject]@{ HostingMode = 'vm'; Pid = $null; ProcessStartUnixMs = $null } }
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
        function Read-ExtensionServiceMarker { [pscustomobject]@{ active = $true } }
        function Remove-ExtensionServiceMarker {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a file.')]
            param()
            $fixture.Order.Add('remove-marker')
            $true
        }
        function Get-YurunaHostId { 'host' }
        function Write-HostRegistrationRecord { $false }
        function Remove-PortMap {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param([string]$Owner)
            $fixture.Order.Add("portmap:$Owner")
            $true
        }
        function Get-VMState { if ($VMPresent -and -not $fixture.Removed) { 'running' } else { 'absent' } }
        function Stop-VM {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param()
            $fixture.Order.Add('stop-vm')
            $true
        }
        function Stop-VMForce {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Isolated host-operation stub has no external effects.')]
            param()
            $fixture.Order.Add('stop-vm-force')
            $true
        }
        function Remove-GuestVMQuietly {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Records fixture state without touching a VM.')]
            param()
            $fixture.Order.Add('remove-vm')
            $fixture.Removed = $true
        }
        $warned = $null
        & $Path -VMName 'fixture-vm' -ServiceKey $ServiceKey -Area $Area -ServiceName 'Fixture' -CallerScript "Stop-$ServiceKey.ps1" -Confirm:$false -WarningVariable warned -WarningAction SilentlyContinue 1>$null 4>$null 5>$null 6>$null
        $code = $LASTEXITCODE
        [pscustomobject]@{
            Order = [string[]]$fixture.Order.ToArray()
            ExitCall = $fixture.ExitCall
            ExitCode = $code
            Warnings = [string[]]@($warned | ForEach-Object { "$_" })
        }
    }
    $shell = [PowerShell]::Create()
    try {
        [void]$shell.AddScript($driver.ToString()).AddArgument($script:stopExtension).AddArgument($ServiceKey).AddArgument($Area).AddArgument($VMPresent)
        $row = @($shell.Invoke()) | Select-Object -Last 1
        [pscustomobject]@{
            Errors = [string[]]@($shell.Streams.Error | ForEach-Object { "$_" })
            Order = $row.Order; ExitCall = $row.ExitCall; ExitCode = $row.ExitCode; Warnings = $row.Warnings
        }
    } finally {
        $shell.Dispose()
    }
}

}

# Case lists for the Describes below. Both are read while the file is being
# DISCOVERED, which happens before any BeforeAll body runs, so they resolve their
# own paths here at file scope rather than reading the run-phase variables: a
# list built inside BeforeAll is still empty when the Describe that consumes it
# is enumerated, and that Describe then emits no tests at all and passes
# vacuously, while a path read from BeforeAll arrives as $null.
$discoveryTestDir = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # .../test

# Every service VM bring-up and teardown in test/service/, discovered rather than
# listed so a service added later is held to the same invariant without a second
# edit; the shared extension-service start and its per-service parts run the
# bring-ups' code. An empty result would make its Describe vacuously pass, so the
# count is asserted here -- a folder rename must fail loudly, not silently stop
# checking.
$serviceVmScriptCases = @(
    Get-ChildItem -LiteralPath (Join-Path $discoveryTestDir 'service') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { (($_.Name -like 'Start-*' -or $_.Name -like 'Stop-*') -and $_.Name -like '*ServiceVM.ps1') -or $_.Name -like 'Start-ExtensionService*.ps1' } |
        Sort-Object Name |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
)
if ($serviceVmScriptCases.Count -lt 12) {
    throw "Expected at least 12 Start-/Stop-*ServiceVM.ps1 and Start-ExtensionService scripts under $(Join-Path $discoveryTestDir 'service'), found $($serviceVmScriptCases.Count). The discovery glob is pointed at the wrong folder."
}

Describe 'service VM scripts leave ErrorActionPreference at the inherited value' {
    foreach ($case in $serviceVmScriptCases) {
        It "$($case.Name) does not force ErrorActionPreference to Stop" -TestCases @(@{ Path = $case.Path; Name = $case.Name }) {
            param([string]$Path, [string]$Name)
            $ast = Get-ScriptAst $Path
            $stops = @(Get-AssignedValueText -Ast $ast -Variable 'ErrorActionPreference' |
                       ForEach-Object { $_.Trim([char[]]@("'", '"')) } |
                       Where-Object { $_ -eq 'Stop' })
            # See https://yuruna.link/42e220c4-0014
            # Preserve helpers' nonterminating outcomes; hard stops are explicit.
            Assert-True ($stops.Count -eq 0) "$Name assigns ErrorActionPreference = 'Stop'; service VM scripts must run at the inherited 'Continue' and stop explicitly where they mean to"
        }
    }
}

# Both Stop-* scripts carry the identical PID guard, so one It body covers them
# from a file-scope case list. The per-case path reaches the It body through
# -TestCases rather than the loop variable: a Describe body -- including a foreach
# that emits Its -- runs during discovery, and its variables are discarded before
# any It executes, so a `$case.Path` read inside the body would arrive as $null and
# assert against an empty path.
$stopScriptCases = @(
    @{ Name = 'Stop-ConfigService.ps1'; Path = (Join-Path $discoveryTestDir 'service/Stop-ConfigService.ps1') },
    @{ Name = 'Stop-StatusService.ps1'; Path = (Join-Path $discoveryTestDir 'service/Stop-StatusService.ps1') }
)

Describe 'Stop-* scripts parse the PID defensively before process control' {
    foreach ($case in $stopScriptCases) {
        It "$($case.Name) gates on [int]::TryParse and passes only the typed int to -Id" -TestCases @(@{ Path = $case.Path }) {
            param([string]$Path)
            # Both scripts hand the PID file to the shared stopper, which owns the guard.
            $ast = Get-ScriptAst $Path
            Assert-True ((Get-CommandCall -Ast $ast -Name 'Stop-YurunaPidFileService').Count -ge 1) 'the script stops the service through the shared PID-file stopper'
            $module = Get-ScriptAst (Join-Path $discoveryTestDir 'modules/Test.YurunaDir.psm1')
            $stopper = $module.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-YurunaPidFileService' }, $true)
            Assert-True ($null -ne $stopper) 'the shared stopper exists'
            Assert-True ((Get-InvokedMember -Ast $stopper) -contains 'TryParse') 'a real [int]::TryParse invocation guards the PID (a comment does not count)'
            Assert-True ((Get-IfConditionMember -Ast $stopper) -contains 'TryParse') 'the [int]::TryParse result gates an if-branch (not an ignored expression)'
            foreach ($cmd in @('Get-Process', 'Stop-Process')) {
                foreach ($call in (Get-CommandCall -Ast $stopper -Name $cmd)) {
                    $idText = Get-IdArgumentText -CommandAst $call
                    Assert-True ($idText -eq '$servicePid') "$cmd -Id must use the validated int variable, got '$idText'"
                }
            }
        }
    }
}

Describe 'Start-ConfigService.ps1 verifies the Linux child survived launch' {
    It 'gates on [int]::TryParse of the echoed PID and probes Get-Process -Id $bgPidInt' {
        $ast = Get-ScriptAst $script:startHostConfig
        Assert-True ((Get-InvokedMember -Ast $ast) -contains 'TryParse') '[int]::TryParse validates the echoed child PID'
        Assert-True ((Get-IfConditionMember -Ast $ast) -contains 'TryParse') 'the [int]::TryParse result gates the survival branch'
        $probes = @(Get-CommandCall -Ast $ast -Name 'Get-Process' |
            Where-Object { (Get-IdArgumentText -CommandAst $_) -eq '$bgPidInt' })
        Assert-True ($probes.Count -ge 1) 'Get-Process -Id $bgPidInt survival probe is present'
    }
}

Describe 'Start-StashServiceVM.ps1 surfaces status-service unreachability' {
    It 'captures the start decision, TCP-probes the status port, and warns on unreachable' {
        # The start runs the shared pipeline with the stash readiness part, read here in place.
        $ast = Get-YurunaServiceStartAst -Path $script:startStash
        Assert-True (Test-AssignsFromCommand -Ast $ast -Command 'Start-YurunaStatusServiceIfEnabled') 'the start decision is captured in an assignment (not discarded)'
        Assert-True ((Get-CommandCall -Ast $ast -Name 'Test-TcpEndpointOpen').Count -ge 1) 'the status port is TCP-probed through the shared endpoint probe'
        # The warning must tie an unreachable status port to the degraded Extension-hosts
        # consequence. It states the accurate outcome -- the aggregator falls back to the
        # stash-service VM's presence beacon (the host still appears, minus its status baseUrl link)
        # -- rather than a blanket "won't appear", so match on that durable phrasing.
        $warn = @(Get-StringLiteralExtent -Ast $ast | Where-Object { $_ -match 'Extension hosts row depends' })
        Assert-True ($warn.Count -ge 1) 'a warning literal ties an unreachable status port to the degraded Extension-hosts row'
    }
}

Describe 'Stop-ExtensionService.ps1 releases the host port forwards its service owns' {
    # Every forward a service start adds is recorded under the service's area
    # as its owner, so the stop can release exactly those: a forward left
    # behind keeps a host port (on UTM, a forwarder process) pointed at an
    # address nothing answers on until that owner's next start re-points it.
    It 'removes the <Area> forwards under their owner, after the marker is cleared and before the VM goes' -ForEach @(
        @{ Key = 'stash'; Area = 'stash-service' }
        @{ Key = 'pool-control'; Area = 'pool-control-service' }
        @{ Key = 'download-agent'; Area = 'download-agent-service' }
    ) {
        $run = Invoke-ExtensionStopFixture -ServiceKey $Key -Area $Area
        Assert-Equal -Expected 0 -Actual $run.Errors.Count -Because ($run.Errors -join '; ')
        Assert-StringEqual -Expected "enter,remove-marker,portmap:$Area,stop-vm,remove-vm" -Actual ($run.Order -join ',') `
            -Because 'the forwards are released under the service''s own owner, once its advertisement is withdrawn and before its VM is torn down'
        Assert-StringEqual -Expected 'confirmed|absent' -Actual $run.ExitCall
        Assert-Equal -Expected 0 -Actual $run.ExitCode
    }

    It 'releases the forwards of a VM the host no longer has' {
        $run = Invoke-ExtensionStopFixture -ServiceKey 'stash' -Area 'stash-service' -VMPresent $false
        Assert-Equal -Expected 0 -Actual $run.Errors.Count -Because ($run.Errors -join '; ')
        Assert-StringEqual -Expected 'enter,remove-marker,portmap:stash-service,remove-vm' -Actual ($run.Order -join ',') `
            -Because 'a forward outlives a VM removed by hand until its owner releases it'
        Assert-Equal -Expected 0 -Actual $run.ExitCode
    }
}
