<#PSScriptInfo
.VERSION 2026.09.30
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
    host/macos.utm/Enable-TestAutomation.ps1 -NoOperatorPrompt and
    Initialize-HostSetupModule -SkipModuleInstall are the two switches that
    take the prompts out of the settings recipe: no consent dialog, no Dock or
    screen saver restart, no PSGallery install, no sudo prompt and no
    networkStorage questionnaire.

    The script is exercised as the real file, copied byte for byte into a
    sandbox tree and run in a child pwsh, with stub modules in place of the
    host-condition, capture and pool-storage modules. Each stub records every
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a sandbox tree under the temp path that the test removes.')]
    param([ValidateSet('capable', 'capable-unmet', 'legacy')][string]$ConditionModule = 'capable')
    $root = New-YurunaTestTempDir -Prefix 'yuruna-enable-noprompt'
    $log = Join-Path $root 'calls.log'
    foreach ($dir in @('host/macos.utm', 'automation', 'test/modules')) { New-Item -ItemType Directory -Force -Path (Join-Path $root $dir) | Out-Null }
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

    It 'refuses, capturing and changing nothing, when Set-MacHostConditionSet has no -NoGuiDisruption' {
        $sb = New-EnableSandbox -ConditionModule 'legacy'
        try {
            $r = Invoke-EnableSandbox -Sandbox $sb -Switch @('NoOperatorPrompt')
            Assert-Equal 1 $r.ExitCode 'a module that would disrupt the session is a refusal'
            Assert-True ($r.Messages -contains 'host.enable_automation_no_prompt_unsupported') 'the refusal says why'
            Assert-False ($r.Messages -contains 'host.enable_automation_no_prompt_mode') 'a refused run never announces the mode it refused'
            foreach ($name in @('Save-HostAutomationState', 'Set-MacHostConditionSet', 'Install-PowerShellYamlIfMissing',
                    'Install-PSScriptAnalyzerIfMissing', 'Initialize-SudoCache', 'Invoke-PoolStorageSetupAndReclaim')) {
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
            Assert-Equal '5' $sudo[0].Bound['ReasonCount'] 'with its reason banner'
            $set = Get-StubCall -Result $r -Name 'Set-MacHostConditionSet'
            Assert-Equal 1 $set.Count ''
            Assert-False ($set[0].Bound.ContainsKey('NoGuiDisruption')) 'the settings may restart the Dock and raise the dialogs'
            Assert-False ($set[0].Bound.ContainsKey('Confirm')) 'no confirmation preference is imposed'
            Assert-Equal 1 (Get-StubCall -Result $r -Name 'Invoke-PoolStorageSetupAndReclaim').Count 'the storage questionnaire is offered'
            Assert-Equal 0 @($r.Messages | Where-Object { $_ -like 'host.enable_automation_no_prompt*' }).Count 'no no-prompt message on this path'
            Assert-Equal 'set:1' $r.After 'the caller''s variable is left as it was'
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

    It 'is refused at parameter binding by the Ubuntu and Windows host scripts, which have no such recipe' {
        # An advanced script refuses an undeclared switch before its body
        # runs; a plain script would absorb it into $args and apply its
        # settings, prompts included. Read from metadata, never executed.
        foreach ($relative in @('host/ubuntu.kvm/Enable-TestAutomation.ps1', 'host/windows.hyper-v/Enable-TestAutomation.ps1')) {
            $path = Join-Path $repoRoot $relative
            $ast = Get-YurunaTestFileAst -Path $path
            $binding = @($ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
            Assert-Equal 1 $binding.Count "$relative must be an advanced script"
            Assert-False ((Get-Command -Name $path).Parameters.ContainsKey('NoOperatorPrompt')) "$relative must not accept -NoOperatorPrompt"
        }
    }

    It 'passes -SkipModuleInstall, and no sudo reasons, on the no-prompt path' {
        $calls = @($script:EnableAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Initialize-HostSetupModule' }, $true))
        $skip = @($calls | Where-Object { $_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SkipModuleInstall' } })
        Assert-Equal 1 $skip.Count 'exactly one call site skips module installs'
        $skipHasReason = @($skip[0].CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SudoCacheReason' })
        Assert-Equal 0 $skipHasReason.Count 'the no-prompt call primes no sudo prompt'
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
