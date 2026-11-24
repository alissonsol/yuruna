<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42943432-e3ca-4bf8-aed1-54ee11042ee9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos settings noninteractive pester
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
    The host-settings recipe can run with nobody at the keyboard, and the
    attended setup path is unchanged when it is not asked to.
.DESCRIPTION
    The Enable-TestAutomation.ps1 scripts' -NoOperatorPrompt (on macOS, Ubuntu
    and Windows) and
    Initialize-HostSetupModule -SkipModuleInstall are the two switches that
    take the prompts out of the settings recipe: no consent dialog, no Dock or
    screen saver restart, no PSGallery install, no sudo prompt and no
    networkStorage questionnaire.

    The script is exercised as the real file, copied byte for byte into a
    sandbox tree and run in a child pwsh, with stub modules in place of the
    host-condition, capture, pool-storage and host controller modules, so no
    run reaches sudo, a multiplexer or a controller root. Each stub records every
    call, its bound parameters, the confirmation preference it ran under and
    the YURUNA_NONINTERACTIVE it saw, so a case asserts on what was called and
    how -- including that a refusal called nothing at all. The module switch is
    exercised in process with its install helpers stubbed and module discovery
    mocked.

    YURUNA_NONINTERACTIVE alone must not suppress the consent dialogs:
    install/setup.ps1 runs this script with it set and relies on them, so the
    attended case sets it too and expects the full path.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

$script:EnableScript = Join-Path $repoRoot 'host/macos.utm/Enable-TestAutomation.ps1'
$script:HostSetupModule = Join-Path $repoRoot 'automation/Yuruna.HostSetup.psm1'

# The stubs every sandbox shares. They record through the .NET file API, not
# Add-Content: inside a callee bound with -WhatIf, Add-Content honors the
# preview and silently writes nothing. Each call is one line:
#   call|<name>|<bound parameters, sorted>|nonint=<value>|confirm=<preference>
$script:RecorderText = @'
function Write-StubCall {
    param([string]$Name, [System.Collections.IDictionary]$Bound, [string]$Confirm)
    $pairs = @($Bound.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $Bound[$_] })
    $nonInteractive = if (Test-Path -LiteralPath 'Env:YURUNA_NONINTERACTIVE') { $env:YURUNA_NONINTERACTIVE } else { '<unset>' }
    [IO.File]::AppendAllText('__LOG__', ('call|{0}|{1}|nonint={2}|confirm={3}' -f $Name, ($pairs -join ';'), $nonInteractive, $Confirm) + "`n")
}
'@

function New-EnableSandbox {
    <#
    .DESCRIPTION
        The answers of the host controller stand-ins are files in the
        sandbox, read at each call, so Set-EnableSandboxState can change them
        between two runs of the same sandbox. The deployed shim's folder,
        <root>/controller, stands in for the controller root.
    .PARAMETER Deployment
        What the stand-in deployment check answers.
    .PARAMETER FilesReason
        The stand-in deployment's reason. As in Install-HostUpdateControllerFile,
        only a reason after the snapshot was staged (installed, unchanged,
        current-io-error) carries a snapshot.
    .PARAMETER EntryReason
        What the stand-in entry install answers.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a sandbox tree under the temp path that the test removes.')]
    param(
        [ValidateSet('capable', 'capable-unmet', 'legacy')][string]$ConditionModule = 'capable',
        [string]$Deployment = 'ready',
        [string]$FilesReason = 'installed',
        [switch]$ShimChanged,
        [ValidateSet('installed', 'unchanged', 'replaced', 'failed')][string]$EntryReason = 'installed',
        [ValidateSet('ended', 'absent', 'failed')][string]$SessionReason = 'ended',
        [ValidateRange(0, 9)][int]$ClaimedFrom = 0,
        [string]$JournalStatus = 'ok',
        [ValidateRange(1, 9)][int]$JournalStatusFrom = 1
    )
    $root = New-YurunaTestTempDir -Prefix 'yuruna-enable-noprompt'
    $log = Join-Path $root 'calls.log'
    foreach ($dir in @('host/macos.utm', 'automation', 'test/modules', 'controller')) { New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null }
    Set-EnableSandboxState -Root $root -ShimChanged:$ShimChanged -SessionReason $SessionReason -ClaimedFrom $ClaimedFrom -JournalStatus $JournalStatus -JournalStatusFrom $JournalStatusFrom
    Copy-Item -LiteralPath $script:EnableScript -Destination (Join-Path $root 'host/macos.utm/Enable-TestAutomation.ps1')
    Copy-Item -LiteralPath $script:HostSetupModule -Destination (Join-Path $root 'automation/Yuruna.HostSetup.psm1')
    $recorder = $script:RecorderText.Replace('__LOG__', $log)

    [IO.File]::WriteAllText((Join-Path $root 'automation/Yuruna.Globalization.psm1'), @"
function Format-YurunaOperatorMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]`$Key, [hashtable]`$Arguments)
    [IO.File]::AppendAllText('$log', 'message|' + `$Key + "``n")
    return `$Key
}
Export-ModuleMember -Function Format-YurunaOperatorMessage
"@)
    # The real facade imports its siblings with -Global; that is how the
    # script, outside the setup module, sees Set-MacHostConditionSet.
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostContract.psm1'),
        "Import-Module (Join-Path `$PSScriptRoot 'Test.HostCondition.psm1') -Global -Force -DisableNameChecking`n")
    $conditionParam = if ($ConditionModule -eq 'legacy') { '' } else { '[switch]$NoGuiDisruption' }
    $unmet = if ($ConditionModule -eq 'capable-unmet') { '2' } else { '0' }
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostCondition.psm1'), $recorder + @"

function Install-PowerShellYamlIfMissing {
    [CmdletBinding(SupportsShouldProcess)] param()
    Write-StubCall -Name 'Install-PowerShellYamlIfMissing' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    `$true
}
function Install-PSScriptAnalyzerIfMissing {
    [CmdletBinding(SupportsShouldProcess)] param()
    Write-StubCall -Name 'Install-PSScriptAnalyzerIfMissing' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    `$true
}
function Initialize-SudoCache {
    [CmdletBinding()] param([string[]]`$Reasons = @())
    Write-StubCall -Name 'Initialize-SudoCache' -Bound @{ ReasonCount = `$Reasons.Count } -Confirm `$ConfirmPreference
    `$true
}
function Set-MacHostConditionSet {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param($conditionParam)
    Write-StubCall -Name 'Set-MacHostConditionSet' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    $unmet
}
Export-ModuleMember -Function Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Initialize-SudoCache, Set-MacHostConditionSet
"@)
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostAutomationState.psm1'), $recorder + @"

function Save-HostAutomationState {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([string]`$Platform, [switch]`$Force)
    Write-StubCall -Name 'Save-HostAutomationState' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    ''
}
Export-ModuleMember -Function Save-HostAutomationState
"@)
    # The host controller and the elevation entry. None of these stand-ins
    # reaches sudo, a multiplexer or the controller root.
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.SingleFlightLock.psm1'), "# stand-in: Enable calls nothing of it directly`n")
    $queueCount = Join-Path $root 'queue.count'
    $state = Join-Path $root 'state'
    # Like the real read, a status other than ok or recovered-previous
    # carries no claim.
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostOperationJournal.psm1'), $recorder + @"

function Get-HostUpdateQueue {
    [CmdletBinding()] param()
    Write-StubCall -Name 'Get-HostUpdateQueue' -Bound @{} -Confirm `$ConfirmPreference
    `$n = 1
    if ([IO.File]::Exists('$queueCount')) { `$n = [int][IO.File]::ReadAllText('$queueCount') + 1 }
    [IO.File]::WriteAllText('$queueCount', "`$n")
    `$claimedFrom = [int][IO.File]::ReadAllText('$state/claimed.from')
    `$status = if (`$n -ge [int][IO.File]::ReadAllText('$state/journal.from')) { [IO.File]::ReadAllText('$state/journal.status') } else { 'ok' }
    `$claimed = if (`$status -in @('ok', 'recovered-previous') -and `$claimedFrom -gt 0 -and `$n -ge `$claimedFrom) { @{ requestId = '4242aaaa-0000-4000-8000-000000000001' } } else { `$null }
    [pscustomobject]@{ Status = `$status; Claimed = `$claimed; Queued = `$null }
}
Export-ModuleMember -Function Get-HostUpdateQueue
"@)
    $snapshot = if ($FilesReason -in @('installed', 'unchanged', 'current-io-error')) { "'0123456789abcdef'" } else { '$null' }
    $shim = Join-Path $root 'controller/shim'
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostUpdate.psm1'), $recorder + @"

function Test-HostUpdateControllerDeployment {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]`$RepoRoot, [string]`$Definition, [string]`$InstalledDefinition, [switch]`$NoDefinition)
    Write-StubCall -Name 'Test-HostUpdateControllerDeployment' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    '$Deployment'
}
function Install-HostUpdateControllerFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]`$RepoRoot)
    Write-StubCall -Name 'Install-HostUpdateControllerFile' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    [pscustomobject]@{ ShimChanged = [IO.File]::Exists('$state/shim.changed'); Snapshot = $snapshot; CurrentWritten = `$true; Shim = '$shim'; Reason = '$FilesReason' }
}
function Install-HostUpdateAccessEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]`$Account, [scriptblock]`$Native, [string]`$WorkDirectory)
    Write-StubCall -Name 'Install-HostUpdateAccessEntry' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    [pscustomobject]@{ Reason = '$EntryReason'; Detail = `$(if ('$EntryReason' -eq 'failed') { 'install-failed' } else { `$null }) }
}
function Stop-HostUpdateControllerSession {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]`$Service)
    Write-StubCall -Name 'Stop-HostUpdateControllerSession' -Bound `$PSBoundParameters -Confirm `$ConfirmPreference
    `$reason = [IO.File]::ReadAllText('$state/session.reason')
    [pscustomobject]@{ Ended = (`$reason -ne 'failed'); Reason = `$reason }
}
Export-ModuleMember -Function Test-HostUpdateControllerDeployment, Install-HostUpdateControllerFile, Install-HostUpdateAccessEntry, Stop-HostUpdateControllerSession
"@)
    [IO.File]::WriteAllText((Join-Path $root 'test/modules/Test.HostIdentity.psm1'), $recorder + @"

function Invoke-PoolStorageSetupAndReclaim {
    [CmdletBinding()] param([Parameter(Mandatory)][string]`$RepoRoot)
    Write-StubCall -Name 'Invoke-PoolStorageSetupAndReclaim' -Bound @{} -Confirm `$ConfirmPreference
}
Export-ModuleMember -Function Invoke-PoolStorageSetupAndReclaim
"@)
    # Runs the copied script in process of a child pwsh, then records the exit
    # code and the YURUNA_NONINTERACTIVE the caller has afterwards.
    [IO.File]::WriteAllText((Join-Path $root 'driver.ps1'), @"
param([string]`$Switches = '', [string]`$Preset = 'unset')
if (`$Preset -eq 'unset') { Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue } else { `$env:YURUNA_NONINTERACTIVE = `$Preset }
`$splat = @{}
foreach (`$name in (`$Switches -split ',')) { if (`$name) { `$splat[`$name] = `$true } }
& '$(Join-Path $root 'host/macos.utm/Enable-TestAutomation.ps1')' @splat
`$code = `$LASTEXITCODE
`$after = if (Test-Path -LiteralPath 'Env:YURUNA_NONINTERACTIVE') { 'set:' + `$env:YURUNA_NONINTERACTIVE } else { 'unset' }
[IO.File]::AppendAllText('$log', 'after|exit=' + `$code + '|nonint=' + `$after + "``n")
exit `$code
"@)
    return @{ Root = $root; Log = $log; Driver = (Join-Path $root 'driver.ps1') }
}

function Set-EnableSandboxState {
    <#
    .SYNOPSIS
        What the host controller stand-ins of a sandbox answer from now on,
        with a fresh call log and queue read count for the next run.
    .PARAMETER ShimChanged
        The stand-in deployment replaced the shim.
    .PARAMETER SessionReason
        What the stand-in session end answers.
    .PARAMETER ClaimedFrom
        The first call of the stand-in queue read that finds a claimed host
        update; 0 never does.
    .PARAMETER JournalStatus
        The journal read status the stand-in queue read answers from the
        call JournalStatusFrom on; ok before it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes the answers of stand-ins inside a sandbox the test removes.')]
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$ShimChanged,
        [ValidateSet('ended', 'absent', 'failed')][string]$SessionReason = 'ended',
        [ValidateRange(0, 9)][int]$ClaimedFrom = 0,
        [string]$JournalStatus = 'ok',
        [ValidateRange(1, 9)][int]$JournalStatusFrom = 1
    )
    $state = Join-Path $Root 'state'
    $null = New-Item -ItemType Directory -Force -Path $state
    $changed = Join-Path $state 'shim.changed'
    if ($ShimChanged) { [IO.File]::WriteAllText($changed, '') } else { [IO.File]::Delete($changed) }
    [IO.File]::WriteAllText((Join-Path $state 'session.reason'), $SessionReason)
    [IO.File]::WriteAllText((Join-Path $state 'claimed.from'), "$ClaimedFrom")
    [IO.File]::WriteAllText((Join-Path $state 'journal.status'), $JournalStatus)
    [IO.File]::WriteAllText((Join-Path $state 'journal.from'), "$JournalStatusFrom")
    foreach ($name in @('calls.log', 'queue.count')) { [IO.File]::Delete((Join-Path $Root $name)) }
}

# Child output goes into assertion messages, which end up in the NUnit XML: an
# escape sequence or a stray control character there truncates the report.
function ConvertTo-PlainText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $noAnsi = [regex]::Replace($Text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
    return [regex]::Replace($noAnsi, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
}

function Invoke-EnableSandbox {
    param([Parameter(Mandatory)][hashtable]$Sandbox, [string[]]$Switch = @(), [string]$Preset = 'unset')
    $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 120 -Environment @{ NO_COLOR = '1' } -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Sandbox.Driver, '-Switches', ($Switch -join ','), '-Preset', $Preset)
    Assert-True ($r.Started -and -not $r.TimedOut) 'the sandboxed script must start and finish inside its cap'
    $lines = if (Test-Path -LiteralPath $Sandbox.Log) { @(Get-Content -LiteralPath $Sandbox.Log) } else { @() }
    $calls = @(foreach ($line in $lines) {
            if ($line -match '^call\|([^|]+)\|([^|]*)\|nonint=([^|]*)\|confirm=(.*)$') {
                $bound = @{}
                foreach ($pair in ($Matches[2] -split ';')) { if ($pair) { $k, $v = $pair -split '=', 2; $bound[$k] = $v } }
                [pscustomobject]@{ Name = $Matches[1]; Bound = $bound; NonInteractive = $Matches[3]; Confirm = $Matches[4] }
            }
        })
    $after = $lines | Where-Object { $_ -like 'after|*' } | Select-Object -Last 1
    return @{
        ExitCode = $r.ExitCode
        Output   = ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr)
        Calls    = $calls
        Messages = @($lines | Where-Object { $_ -like 'message|*' } | ForEach-Object { $_.Substring(8) })
        After    = if ($after) { ($after -split '\|nonint=')[1] } else { $null }
    }
}

function Get-StubCall {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][string]$Name)
    @($Result.Calls | Where-Object Name -eq $Name)
}
}

Describe 'Enable-TestAutomation.ps1 -NoOperatorPrompt' {
    It 'applies the settings without a prompt path when the host-condition module can stay out of the GUI session' {
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt')
            Assert-Equal 0 $r.ExitCode "a clean no-prompt run exits 0; output: $($r.Output)"
            $set = Get-StubCall -Result $r -Name 'Set-MacHostConditionSet'
            Assert-Equal 1 $set.Count 'the settings are applied once'
            Assert-Equal 'True' $set[0].Bound['NoGuiDisruption'] 'the module is told not to restart the Dock or raise dialogs'
            Assert-Equal 'False' $set[0].Bound['Confirm'] 'every ShouldProcess callee runs with -Confirm:$false'
            Assert-False ($set[0].Bound.ContainsKey('NoOperatorPrompt')) 'the script''s own switch is not splatted through'
            Assert-False ($set[0].Bound.ContainsKey('SkipPoolStorage')) 'nor is -SkipPoolStorage'
            Assert-Equal 'None' $set[0].Confirm 'the callee never prompts for confirmation'
            Assert-Equal '1' $set[0].NonInteractive 'every prompt predicate the settings reach sees YURUNA_NONINTERACTIVE=1'
            $capture = Get-StubCall -Result $r -Name 'Save-HostAutomationState'
            Assert-Equal 1 $capture.Count 'the original settings are still captured first'
            Assert-Equal 'False' $capture[0].Bound['Confirm'] 'the capture cannot prompt either'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Install-PowerShellYamlIfMissing').Count 'no PSGallery install'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Install-PSScriptAnalyzerIfMissing').Count 'no PSGallery install'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Initialize-SudoCache').Count 'no sudo prompt is primed'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Invoke-PoolStorageSetupAndReclaim').Count 'the storage questionnaire never runs'
            $verify = Get-StubCall -Result $r -Name 'Test-HostUpdateControllerDeployment'
            Assert-Equal 1 $verify.Count 'the host controller is verified once'
            Assert-Equal 'True' $verify[0].Bound['NoDefinition'] 'macOS registers no job, so there is no definition to compare'
            foreach ($name in @('Install-HostUpdateControllerFile', 'Install-HostUpdateAccessEntry', 'Stop-HostUpdateControllerSession')) {
                Assert-Equal 0 (Get-StubCall -Result $r -Name $name).Count "$name never runs: a host update runs this mode, and its controller is the one a deployment replaces"
            }
            Assert-Equal 1 @($r.Messages | Where-Object { $_ -eq 'host.enable_automation_no_prompt_mode' }).Count 'the mode is announced once'
            Assert-Equal 'unset' $r.After 'YURUNA_NONINTERACTIVE is removed again when the caller had none'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'puts back the caller''s own YURUNA_NONINTERACTIVE value afterwards' {
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt') -Preset '0'
            Assert-Equal 0 $r.ExitCode ''
            Assert-Equal '1' (Get-StubCall -Result $r -Name 'Set-MacHostConditionSet')[0].NonInteractive 'inside the run it is 1 whatever the caller had'
            Assert-Equal 'set:0' $r.After 'the caller gets its own value back'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'still reports unmet settings through exit 2 and restores the environment' {
        $sb = New-EnableSandbox -ConditionModule 'capable-unmet'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt')
            Assert-Equal 2 $r.ExitCode 'a setting left for an operator is exit 2, not a prompt'
            Assert-True ($r.Messages -contains 'host.operator_6661089d0f925ca8') 'the unmet warning is the shared one'
            Assert-Equal 'unset' $r.After ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'counts a deployed controller that is not this checkout''s as unmet, and replaces nothing' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -Deployment 'shim-differs'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt')
            Assert-Equal 2 $r.ExitCode "a difference is left for an attended run; output: $($r.Output)"
            Assert-True ($r.Messages -contains 'host.host_controller_not_verified') 'the difference is named'
            Assert-True ($r.Messages -contains 'host.operator_6661089d0f925ca8') 'and counted with the unmet settings'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Install-HostUpdateControllerFile').Count 'the shim is never replaced under the switch'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'refuses, capturing and changing nothing, when Set-MacHostConditionSet has no -NoGuiDisruption' {
        $sb = New-EnableSandbox -ConditionModule 'legacy'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt')
            Assert-Equal 1 $r.ExitCode 'a module that would disrupt the session is a refusal'
            Assert-True ($r.Messages -contains 'host.enable_automation_no_prompt_unsupported') 'the refusal says why'
            Assert-False ($r.Messages -contains 'host.enable_automation_no_prompt_mode') 'a refused run never announces the mode it refused'
            foreach ($name in @('Save-HostAutomationState', 'Set-MacHostConditionSet', 'Install-PowerShellYamlIfMissing',
                    'Install-PSScriptAnalyzerIfMissing', 'Initialize-SudoCache', 'Invoke-PoolStorageSetupAndReclaim',
                    'Test-HostUpdateControllerDeployment', 'Install-HostUpdateControllerFile', 'Install-HostUpdateAccessEntry')) {
                Assert-Equal 0 (Get-StubCall -Result $r -Name $name).Count "$name must not run after a refusal"
            }
            Assert-Equal 'unset' $r.After 'a refusal restores the environment too'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'refuses -Confirm before loading or changing anything' {
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt', 'Confirm')
            Assert-Equal 1 $r.ExitCode 'asking for a prompt per change contradicts the switch'
            Assert-True ($r.Messages -contains 'host.enable_automation_no_prompt_confirm_conflict') ''
            Assert-False ($r.Messages -contains 'host.enable_automation_no_prompt_mode') 'a refused run never announces the mode it refused'
            Assert-Equal 0 @($r.Calls).Count ('nothing may be called; got: ' + (@($r.Calls | ForEach-Object Name) -join ', '))
            Assert-Equal 'unset' $r.After ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'previews under -WhatIf with the same no-prompt settings' {
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt', 'WhatIf')
            Assert-Equal 0 $r.ExitCode ''
            $set = Get-StubCall -Result $r -Name 'Set-MacHostConditionSet'
            Assert-Equal 'True' $set[0].Bound['WhatIf'] 'the preview reaches the settings'
            Assert-Equal 'True' $set[0].Bound['NoGuiDisruption'] ''
            Assert-Equal 'True' (Get-StubCall -Result $r -Name 'Save-HostAutomationState')[0].Bound['WhatIf'] 'and the capture'
            foreach ($name in @('Install-HostUpdateControllerFile', 'Install-HostUpdateAccessEntry', 'Stop-HostUpdateControllerSession')) {
                Assert-Equal 0 (Get-StubCall -Result $r -Name $name).Count "$name never runs"
            }
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }
}

Describe 'Enable-TestAutomation.ps1 without -NoOperatorPrompt (the attended setup path)' {
    It 'keeps installs, the sudo prime, the dialogs and the storage questionnaire, even under YURUNA_NONINTERACTIVE=1' {
        # install/setup.ps1 runs the script with YURUNA_NONINTERACTIVE=1 and an
        # operator present to answer the consent dialogs; only the explicit
        # switch may take them away.
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Preset '1'
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Install-PowerShellYamlIfMissing').Count 'powershell-yaml is still ensured'
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Install-PSScriptAnalyzerIfMissing').Count 'PSScriptAnalyzer is still ensured'
            $sudo = Get-StubCall -Result $r -Name 'Initialize-SudoCache'
            Assert-Equal 1 $sudo.Count 'the sudo prompt is still primed early'
            Assert-Equal '6' $sudo[0].Bound['ReasonCount'] 'with its reason banner, which names the sudoers entry'
            $set = Get-StubCall -Result $r -Name 'Set-MacHostConditionSet'
            Assert-Equal 1 $set.Count ''
            Assert-False ($set[0].Bound.ContainsKey('NoGuiDisruption')) 'the settings may restart the Dock and raise the dialogs'
            Assert-False ($set[0].Bound.ContainsKey('Confirm')) 'no confirmation preference is imposed'
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Invoke-PoolStorageSetupAndReclaim').Count 'the storage questionnaire is offered'
            Assert-Equal 0 @($r.Messages | Where-Object { $_ -like 'host.enable_automation_no_prompt*' }).Count 'no no-prompt message on this path'
            Assert-Equal 'set:1' $r.After 'the caller''s variable is left as it was'
            $entry = Get-StubCall -Result $r -Name 'Install-HostUpdateAccessEntry'
            Assert-Equal 1 $entry.Count 'the sudoers entry is installed once'
            Assert-Equal ([Environment]::UserName) $entry[0].Bound['Account'] 'for the account that runs the script'
            Assert-Equal 'False' $entry[0].Bound['Confirm'] ''
            $names = @($r.Calls | ForEach-Object Name)
            Assert-True ([array]::IndexOf($names, 'Install-HostUpdateAccessEntry') -gt [array]::IndexOf($names, 'Initialize-SudoCache')) 'after the credential is primed'
            Assert-True ([array]::IndexOf($names, 'Install-HostUpdateAccessEntry') -lt [array]::IndexOf($names, 'Set-MacHostConditionSet')) `
                'before the grant assist, which can wait longer than macOS keeps the credential'
            Assert-True ($r.Messages -contains 'host.host_update_access_entry_installed') 'the entry''s outcome is reported'
            $files = Get-StubCall -Result $r -Name 'Install-HostUpdateControllerFile'
            Assert-Equal 1 $files.Count 'the controller''s shim and snapshot are deployed once'
            Assert-Equal 'False' $files[0].Bound['Confirm'] ''
            Assert-True ($r.Messages -contains 'host.host_controller_deployed_macos') 'the deployment is reported'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Test-HostUpdateControllerDeployment').Count 'the attended run deploys instead of verifying'
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count 'an unchanged shim leaves the session alone'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'ends an idle controller session whose shim changed, and says the next runner start starts the new one' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            $stop = Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession'
            Assert-Equal 1 $stop.Count 'the session that runs the replaced shim is ended'
            Assert-Equal 'False' $stop[0].Bound['Confirm'] ''
            Assert-Equal 2 (Get-StubCall -Result $r -Name 'Get-HostUpdateQueue').Count 'the claim is read before and after the end'
            Assert-True ($r.Messages -contains 'host.host_controller_session_restart_pending') ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'leaves running the session of a claimed host update whose shim changed' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -ClaimedFrom 1
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count 'ending it would end the controller of the update'
            Assert-True ($r.Messages -contains 'host.host_controller_session_kept') 'the new shim waits for that session to end'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'names both ways on when the controller claimed an update while its session was ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -ClaimedFrom 2
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count ''
            Assert-True ($r.Messages -contains 'host.host_controller_session_ended_claimed') ''
            Assert-False ($r.Messages -contains 'host.host_controller_session_restart_pending') 'the line names the update instead'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'warns, without counting it as unmet, when the session of a replaced shim cannot be ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -SessionReason 'failed'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "the old shim still runs a working controller; output: $($r.Output)"
            Assert-True ($r.Messages -contains 'host.host_controller_session_end_failed') ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'ends on a later run the session of a replaced shim that a claimed update kept, once the update has ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -ClaimedFrom 1
        try {
            $kept = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $kept.ExitCode "output: $($kept.Output)"
            Assert-True ($kept.Messages -contains 'host.host_controller_session_kept') 'the first run names the run that ends the session'
            Assert-Equal 0 (Get-StubCall -Result $kept -Name 'Stop-HostUpdateControllerSession').Count ''
            # The update has ended. The new shim is on disk since the first
            # run, so the deployment no longer reports a change.
            Set-EnableSandboxState -Root $sb.Root
            $again = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $again.ExitCode "output: $($again.Output)"
            Assert-Equal 1 (Get-StubCall -Result $again -Name 'Stop-HostUpdateControllerSession').Count 'the session still runs the replaced shim, and this run ends it'
            Assert-True ($again.Messages -contains 'host.host_controller_session_restart_pending') ''
            Set-EnableSandboxState -Root $sb.Root
            $third = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 (Get-StubCall -Result $third -Name 'Stop-HostUpdateControllerSession').Count 'once ended, a run with an unchanged shim leaves the new session alone'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'ends on a later run the session of a replaced shim that could not be ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -SessionReason 'failed'
        try {
            $failed = Invoke-EnableSandbox -Sandbox $sb
            Assert-True ($failed.Messages -contains 'host.host_controller_session_end_failed') "output: $($failed.Output)"
            Set-EnableSandboxState -Root $sb.Root
            $again = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $again.ExitCode "output: $($again.Output)"
            Assert-Equal 1 (Get-StubCall -Result $again -Name 'Stop-HostUpdateControllerSession').Count 'the end is tried again'
            Assert-True ($again.Messages -contains 'host.host_controller_session_restart_pending') ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'leaves running the session of a replaced shim while the journal reads <Status>, and ends it on a later run' -ForEach @(
        @{ Status = 'corrupt' }
        @{ Status = 'unreadable' }
        @{ Status = 'unknown-version' }
    ) {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -JournalStatus $Status
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count 'a journal that cannot be read may hide the update that session runs'
            Assert-True ($r.Messages -contains 'host.host_controller_session_kept_unknown') 'the journal status is named'
            Assert-False ($r.Messages -contains 'host.host_controller_session_restart_pending') ''
            Set-EnableSandboxState -Root $sb.Root
            $again = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 1 (Get-StubCall -Result $again -Name 'Stop-HostUpdateControllerSession').Count 'a later run with a readable journal ends it'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'ends the idle session of a replaced shim when no journal exists yet' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -JournalStatus 'absent'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count "no journal is no host update; output: $($r.Output)"
            Assert-True ($r.Messages -contains 'host.host_controller_session_restart_pending') ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'says so when the journal cannot be read again after the session ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged -JournalStatus 'corrupt' -JournalStatusFrom 2
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Stop-HostUpdateControllerSession').Count ''
            Assert-True ($r.Messages -contains 'host.host_controller_session_ended_unknown') 'an update claimed meanwhile cannot be ruled out'
            Assert-False ($r.Messages -contains 'host.host_controller_session_restart_pending') ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'counts <Case> as unmet' -ForEach @(
        @{ Case = 'a controller deployment that failed'; Files = 'shim-io-error'; Entry = 'installed'; Key = 'host.host_controller_files_failed_macos' }
        @{ Case = 'a current that was not written'; Files = 'current-io-error'; Entry = 'installed'; Key = 'host.host_controller_files_failed_macos' }
        @{ Case = 'a sudoers entry that was not installed'; Files = 'installed'; Entry = 'failed'; Key = 'host.host_update_access_entry_failed' }
    ) {
        $sb = New-EnableSandbox -ConditionModule 'capable' -FilesReason $Files -EntryReason $Entry
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 2 $r.ExitCode "output: $($r.Output)"
            Assert-True ($r.Messages -contains $Key) "$Key is reported"
            Assert-True ($r.Messages -contains 'host.operator_6661089d0f925ca8') 'with the unmet settings'
            Assert-Equal ($Files -eq 'installed') ($r.Messages -contains 'host.host_controller_deployed_macos') 'only a deployment a runner start can use is reported as deployed'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'reports an entry that was <Reason> without counting it' -ForEach @(
        @{ Reason = 'unchanged' }
        @{ Reason = 'replaced' }
    ) {
        $sb = New-EnableSandbox -ConditionModule 'capable' -EntryReason $Reason
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            Assert-True ($r.Messages -contains "host.host_update_access_entry_$Reason") ''
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'previews under -WhatIf: no deployment, no sudoers entry, no session ended' {
        $sb = New-EnableSandbox -ConditionModule 'capable' -ShimChanged
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('WhatIf')
            Assert-Equal 0 $r.ExitCode "output: $($r.Output)"
            foreach ($name in @('Install-HostUpdateControllerFile', 'Install-HostUpdateAccessEntry', 'Stop-HostUpdateControllerSession', 'Test-HostUpdateControllerDeployment')) {
                Assert-Equal 0 (Get-StubCall -Result $r -Name $name).Count "$name does not run under -WhatIf"
            }
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }

    It 'skips only the questionnaire under -SkipPoolStorage and does not forward the switch' {
        $sb = New-EnableSandbox -ConditionModule 'capable'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('SkipPoolStorage')
            Assert-Equal 0 $r.ExitCode ''
            Assert-Equal 0 (Get-StubCall -Result $r -Name 'Invoke-PoolStorageSetupAndReclaim').Count ''
            Assert-True ($r.Messages -contains 'host.operator_07d790b607ee2b44') 'the skip is announced'
            $set = Get-StubCall -Result $r -Name 'Set-MacHostConditionSet'
            Assert-False ($set[0].Bound.ContainsKey('SkipPoolStorage')) 'the switch is the script''s own'
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Install-PowerShellYamlIfMissing').Count 'installs are unaffected'
        } finally { Remove-YurunaTestTempDir $sb.Root }
    }
}

Describe 'Enable-TestAutomation.ps1 source shape' {
    BeforeAll {
        $script:EnableAst = Get-YurunaTestFileAst -Path $script:EnableScript
    }

    It 'declares -NoOperatorPrompt as a switch' {
        $param = @($script:EnableAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'NoOperatorPrompt' })
        Assert-Equal 1 $param.Count ''
        Assert-Equal 'System.Management.Automation.SwitchParameter' $param[0].StaticType.FullName ''
    }

    It 'feature-detects -NoGuiDisruption before the capture writes anything' {
        $text = [IO.File]::ReadAllText($script:EnableScript)
        $detect = $text.IndexOf(".Parameters.ContainsKey('NoGuiDisruption')", [StringComparison]::Ordinal)
        $capture = $text.IndexOf('Save-HostAutomationState -Platform', [StringComparison]::Ordinal)
        Assert-True ($detect -gt 0) 'the detection reads the loaded command''s own parameter metadata'
        Assert-True ($detect -lt $capture) 'a refusal must come before the first write'
    }

    It 'pairs with a host-condition module that declares -NoGuiDisruption' {
        # Without it every -NoOperatorPrompt run refuses; read from the AST so
        # the check imports and runs nothing.
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $repoRoot 'test/modules/Test.HostCondition.Mac.psm1') -Name 'Set-MacHostConditionSet'
        Assert-NotNull $fn 'Set-MacHostConditionSet exists'
        $names = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-True ($names -contains 'NoGuiDisruption') ('parameters: ' + ($names -join ', '))
    }

    It 'passes -SkipModuleInstall, and no sudo reasons, on the no-prompt path' {
        $calls = @($script:EnableAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-HostSetupModule' }, $true))
        $skip = @($calls | Where-Object { $_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SkipModuleInstall' } })
        Assert-Equal 1 $skip.Count 'exactly one call site skips module installs'
        $skipHasReason = @($skip[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SudoCacheReason' })
        Assert-Equal 0 $skipHasReason.Count 'the no-prompt call primes no sudo prompt'
    }
}

Describe 'Enable-TestAutomation.ps1 -NoOperatorPrompt on Ubuntu and Windows (the enable phase of a host update)' {
    BeforeAll {
        $script:HostScripts = @('host/ubuntu.kvm/Enable-TestAutomation.ps1', 'host/windows.hyper-v/Enable-TestAutomation.ps1')
        function Get-CommandCall {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Name',
                Justification = 'Captured by the closure that filters the AST.')]
            param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string]$Name)
            @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }.GetNewClosure(), $true))
        }
        function Test-CallHasParameter {
            param([Parameter(Mandatory)]$Call, [Parameter(Mandatory)][string]$Name)
            [bool]@($Call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $Name }).Count
        }
        # The innermost if statement whose condition reads $NoOperatorPrompt
        # and whose then-branch holds the node.
        function Test-InsideNoPromptBranch {
            param([Parameter(Mandatory)]$Node)
            for ($p = $Node.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                    foreach ($clause in $p.Clauses) {
                        if ($clause.Item1.Extent.Text -match '^\$NoOperatorPrompt$' -and $Node.Extent.StartOffset -ge $clause.Item2.Extent.StartOffset -and
                            $Node.Extent.EndOffset -le $clause.Item2.Extent.EndOffset) { return $true }
                    }
                }
            }
            return $false
        }
        # True only when the switch keeps the node from running. Being outside
        # the then-branch is not enough: a call placed after the if still runs
        # under the switch. The node must sit after the then-branch of an if
        # whose first condition is $NoOperatorPrompt (in a later clause or the
        # else), or after such an if whose then-branch ends in return, in a
        # block that encloses the node.
        function Test-ExcludedFromNoPromptBranch {
            param([Parameter(Mandatory)]$Node)
            $start = $Node.Extent.StartOffset
            for ($p = $Node.Parent; $p; $p = $p.Parent) {
                if ($p -is [System.Management.Automation.Language.IfStatementAst] -and $p.Clauses[0].Item1.Extent.Text -match '^\$NoOperatorPrompt$' -and
                    $start -ge $p.Clauses[0].Item2.Extent.EndOffset) { return $true }
                if ($p -is [System.Management.Automation.Language.StatementBlockAst] -or $p -is [System.Management.Automation.Language.NamedBlockAst]) {
                    foreach ($sibling in $p.Statements) {
                        if ($sibling.Extent.EndOffset -gt $start) { break }
                        if ($sibling -isnot [System.Management.Automation.Language.IfStatementAst] -or $sibling.Clauses[0].Item1.Extent.Text -notmatch '^\$NoOperatorPrompt$') { continue }
                        $then = @($sibling.Clauses[0].Item2.Statements)
                        if ($then.Count -gt 0 -and $then[-1] -is [System.Management.Automation.Language.ReturnStatementAst]) { return $true }
                    }
                }
            }
            return $false
        }
    }

    It 'declares -NoOperatorPrompt as a switch of an advanced script' {
        foreach ($relative in $script:HostScripts) {
            $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot $relative)
            $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
            Assert-Equal 1 $binding.Count "$relative must be an advanced script"
            $param = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'NoOperatorPrompt' })
            Assert-Equal 1 $param.Count "$relative declares -NoOperatorPrompt"
            Assert-Equal 'System.Management.Automation.SwitchParameter' $param[0].StaticType.FullName $relative
        }
    }

    It 'refuses -Confirm before it imports, captures or changes anything' {
        foreach ($relative in $script:HostScripts) {
            $text = [IO.File]::ReadAllText((Join-Path $repoRoot $relative))
            $refusal = $text.IndexOf("Format-YurunaOperatorMessage -Key 'host.enable_automation_no_prompt_confirm_conflict'", [StringComparison]::Ordinal)
            Assert-True ($refusal -gt 0) "$relative names the conflict"
            foreach ($later in @('Initialize-HostSetupModule -RepoRoot', 'Save-HostAutomationState -Platform')) {
                Assert-True ($refusal -lt $text.IndexOf($later, [StringComparison]::Ordinal)) "$relative refuses before $later"
            }
        }
    }

    It 'skips the module installs and the sudo prime, and never reaches the storage questionnaire' {
        foreach ($relative in $script:HostScripts) {
            $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot $relative)
            $skip = @(Get-CommandCall -Ast $ast -Name 'Initialize-HostSetupModule' | Where-Object { Test-CallHasParameter -Call $_ -Name 'SkipModuleInstall' })
            Assert-Equal 1 $skip.Count "$relative has one call site that skips module installs"
            Assert-False (Test-CallHasParameter -Call $skip[0] -Name 'SudoCacheReason') "$relative primes no sudo prompt there"
            Assert-True (Test-InsideNoPromptBranch -Node $skip[0]) "$relative takes that call site only under -NoOperatorPrompt"
            $attended = @(Get-CommandCall -Ast $ast -Name 'Initialize-HostSetupModule' | Where-Object { -not (Test-CallHasParameter -Call $_ -Name 'SkipModuleInstall') })
            Assert-True ($attended.Count -gt 0) "$relative keeps an attended call site"
            foreach ($call in $attended) {
                Assert-True (Test-ExcludedFromNoPromptBranch -Node $call) "${relative}: the call site that installs modules or primes sudo is unreachable under -NoOperatorPrompt ($($call.Extent.StartLineNumber))"
            }
            $text = $ast.Extent.Text
            Assert-True ($text -match '(?m)^\s+\$SkipPoolStorage = \$true$') "${relative}: -NoOperatorPrompt implies -SkipPoolStorage"
        }
    }

    It 'verifies the host controller and never registers, replaces or restarts it under the switch' {
        foreach ($relative in $script:HostScripts) {
            $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot $relative)
            $verify = @(Get-CommandCall -Ast $ast -Name 'Test-HostUpdateControllerDeployment')
            Assert-Equal 1 $verify.Count "$relative verifies the deployment once"
            Assert-True (Test-InsideNoPromptBranch -Node $verify[0]) "$relative verifies only under -NoOperatorPrompt"
            # What registers, replaces or restarts the controller: the file
            # deployment and the scheduled task everywhere, and on Ubuntu the
            # privileged tee and systemctl calls of the deployment step.
            $changing = [System.Collections.Generic.List[object]]::new()
            foreach ($name in @('Install-HostUpdateControllerFile', 'Register-HostUpdateControllerTask')) {
                foreach ($call in (Get-CommandCall -Ast $ast -Name $name)) { $changing.Add($call) }
            }
            foreach ($step in @(Get-CommandCall -Ast $ast -Name 'Invoke-Step' | Where-Object { $_.Extent.Text -match 'Deploy the host controller' })) {
                foreach ($call in (Get-CommandCall -Ast $step -Name 'Invoke-HostSudo')) {
                    $verbs = @($call.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -in @('tee', 'systemctl') }, $true))
                    if ($verbs.Count -gt 0) { $changing.Add($call) }
                }
            }
            $expected = if ($relative -like 'host/ubuntu.kvm/*') { 5 } else { 2 }
            Assert-Equal $expected $changing.Count "$relative has the registration calls this case knows of"
            foreach ($call in $changing) {
                Assert-True (Test-ExcludedFromNoPromptBranch -Node $call) "${relative}: $($call.Extent.Text) is unreachable under -NoOperatorPrompt (line $($call.Extent.StartLineNumber))"
            }
        }
    }

    It 'adds the firewall rules through sudo -n under the switch on Ubuntu' {
        # Without -NonInteractive the firewall module runs plain sudo, which
        # asks for a password on the terminal when no credential is cached.
        $ast = Get-YurunaTestFileAst -Path (Join-Path $repoRoot 'host/ubuntu.kvm/Enable-TestAutomation.ps1')
        $calls = @(Get-CommandCall -Ast $ast -Name 'Set-YurunaStatusFirewallRule')
        Assert-Equal 2 $calls.Count 'the status and the config service ports'
        foreach ($call in $calls) {
            $bound = @($call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'NonInteractive' })
            Assert-Equal 1 $bound.Count "$($call.Extent.Text) binds -NonInteractive"
            Assert-True ($bound[0].Argument -is [System.Management.Automation.Language.VariableExpressionAst] -and $bound[0].Argument.VariablePath.UserPath -eq 'NoOperatorPrompt') `
                "$($call.Extent.Text) binds -NonInteractive from the switch"
        }
    }

    It 'refuses -NoOperatorPrompt -Confirm with exit 1 and calls nothing, run as the real Ubuntu file' -Skip:(-not $IsLinux) {
        # A sandbox copy: should the refusal ever not happen, the copy finds
        # no module to change this host with.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-enable-kvm-noprompt'
        try {
            foreach ($dir in @('host/ubuntu.kvm', 'automation')) { New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null }
            Copy-Item -LiteralPath (Join-Path $repoRoot 'host/ubuntu.kvm/Enable-TestAutomation.ps1') -Destination (Join-Path $root 'host/ubuntu.kvm/Enable-TestAutomation.ps1')
            $log = Join-Path $root 'messages.log'
            [IO.File]::WriteAllText((Join-Path $root 'automation/Yuruna.Globalization.psm1'), @"
function Format-YurunaOperatorMessage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]`$Key, [hashtable]`$Arguments)
    [IO.File]::AppendAllText('$log', `$Key + "``n")
    return `$Key
}
Export-ModuleMember -Function Format-YurunaOperatorMessage
"@)
            $r = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) -TimeoutSeconds 120 -Environment @{ NO_COLOR = '1' } -ArgumentList @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $root 'host/ubuntu.kvm/Enable-TestAutomation.ps1'), '-NoOperatorPrompt', '-Confirm')
            Assert-Equal 1 $r.ExitCode (ConvertTo-PlainText ($r.StdOut + $r.StdErr))
            Assert-Equal 'host.enable_automation_no_prompt_confirm_conflict' (([IO.File]::ReadAllText($log)).Trim()) 'the conflict is the only message'
        } finally { Remove-YurunaTestTempDir $root }
    }
}


Describe 'Initialize-HostSetupModule -SkipModuleInstall' {
    BeforeAll {
        # A throwaway repo root whose contract facade loads recording stubs for
        # the two install helpers and the sudo prime.
        $script:SetupRoot = New-YurunaTestTempDir -Prefix 'yuruna-hostsetup-skip'
        $script:SetupLog = Join-Path $script:SetupRoot 'calls.log'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:SetupRoot 'test/modules') | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:SetupRoot 'test/modules/Test.HostContract.psm1'),
            "Import-Module (Join-Path `$PSScriptRoot 'Test.HostCondition.psm1') -Global -Force -DisableNameChecking`n")
        [IO.File]::WriteAllText((Join-Path $script:SetupRoot 'test/modules/Test.HostCondition.psm1'), @"
function Install-PowerShellYamlIfMissing { [CmdletBinding(SupportsShouldProcess)] param() [IO.File]::AppendAllText('$($script:SetupLog)', 'Install-PowerShellYamlIfMissing WhatIf=' + [bool]`$WhatIfPreference + "``n"); `$true }
function Install-PSScriptAnalyzerIfMissing { [CmdletBinding(SupportsShouldProcess)] param() [IO.File]::AppendAllText('$($script:SetupLog)', 'Install-PSScriptAnalyzerIfMissing WhatIf=' + [bool]`$WhatIfPreference + "``n"); `$true }
function Initialize-SudoCache { [CmdletBinding()] param([string[]]`$Reasons = @()) [IO.File]::AppendAllText('$($script:SetupLog)', 'Initialize-SudoCache ' + `$Reasons.Count + "``n"); `$true }
Export-ModuleMember -Function Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Initialize-SudoCache
"@)
        Import-Module $script:HostSetupModule -Force -DisableNameChecking
        function Get-SetupCall {
            if (Test-Path -LiteralPath $script:SetupLog) { @(Get-Content -LiteralPath $script:SetupLog) } else { @() }
        }
    }

    AfterAll {
        Remove-Module -Name 'Test.HostCondition', 'Test.HostContract', 'Yuruna.HostSetup' -Force -ErrorAction SilentlyContinue
        Remove-YurunaTestTempDir $script:SetupRoot
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:SetupLog -Force -ErrorAction SilentlyContinue
        Mock -ModuleName 'Yuruna.HostSetup' Format-YurunaOperatorMessage { if ($Arguments) { "$Key|$($Arguments['module'])" } else { $Key } }
    }

    It 'declares the switch' {
        Assert-True ((Get-Command Initialize-HostSetupModule).Parameters.ContainsKey('SkipModuleInstall')) ''
    }

    It 'installs nothing and names each missing module with the command that installs it' {
        Mock -ModuleName 'Yuruna.HostSetup' Get-Module { $null } -ParameterFilter { $ListAvailable }
        $warnings = $null
        Initialize-HostSetupModule -RepoRoot $script:SetupRoot -SkipModuleInstall -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Equal 0 @(Get-SetupCall | Where-Object { $_ -like 'Install-*' }).Count 'no PSGallery install may run'
        $texts = @($warnings | ForEach-Object { "$_" })
        Assert-True ($texts -contains 'automation.host_setup_module_install_skipped|powershell-yaml') ('warnings: ' + ($texts -join ' / '))
        Assert-True ($texts -contains 'automation.host_setup_module_install_skipped|PSScriptAnalyzer') ('warnings: ' + ($texts -join ' / '))
    }

    It 'stays silent when both modules are already present' {
        Mock -ModuleName 'Yuruna.HostSetup' Get-Module { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $ListAvailable }
        $warnings = $null
        Initialize-HostSetupModule -RepoRoot $script:SetupRoot -SkipModuleInstall -WarningVariable warnings -WarningAction SilentlyContinue
        Assert-Equal 0 @($warnings).Count 'nothing is missing, so nothing is reported'
        Assert-Equal 0 @(Get-SetupCall | Where-Object { $_ -like 'Install-*' }).Count ''
    }

    It 'still primes sudo only when the caller asks for it' {
        Mock -ModuleName 'Yuruna.HostSetup' Get-Module { [pscustomobject]@{ Name = $Name } } -ParameterFilter { $ListAvailable }
        Initialize-HostSetupModule -RepoRoot $script:SetupRoot -SkipModuleInstall
        Assert-Equal 0 @(Get-SetupCall | Where-Object { $_ -like 'Initialize-SudoCache*' }).Count 'no reason list, no prime'
    }

    It 'without the switch runs both install helpers and forwards -WhatIf to them, as before' {
        Initialize-HostSetupModule -RepoRoot $script:SetupRoot -BoundParameters @{ WhatIf = [switch]$true } -SudoCacheReason @('one reason')
        $calls = @(Get-SetupCall)
        Assert-True ($calls -contains 'Install-PowerShellYamlIfMissing WhatIf=True') ('calls: ' + ($calls -join ' / '))
        Assert-True ($calls -contains 'Install-PSScriptAnalyzerIfMissing WhatIf=True') ('calls: ' + ($calls -join ' / '))
        Assert-True ($calls -contains 'Initialize-SudoCache 1') 'the sudo prime still runs before the installs'
    }
}
