<#PSScriptInfo
.VERSION 2026.07.10
.GUID 428c1a6d-4b29-4e07-9d51-7a2c8e0b5f31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-loop pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Pester coverage for the per-pool testCycle override merge in Test.RunnerOuterLoop.psm1:
    Get-OuterPoolTestCycleOverride (pure extraction) and the override-WINS precedence in
    Get-OuterAutoRemediation / Get-OuterStepTimeoutMinute (pool > test.config.yml > default).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Config.psm1')          -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

function New-TempConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway temp config file, removed in finally; not user-facing state.')]
    [CmdletBinding()]
    param([string]$Yaml)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("ol-" + [guid]::NewGuid().ToString('N') + '.yml')
    Set-Content -LiteralPath $p -Value $Yaml -Encoding utf8
    return $p
}

Describe 'Get-OuterPoolTestCycleOverride (pure extraction)' {
    It 'returns an empty map for null / no-config / no-testCycle pools' {
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool $null).Count -Because 'null -> empty'
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool ([ordered]@{ poolId = 'lab' })).Count -Because 'no config -> empty'
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool ([ordered]@{ config = [ordered]@{} })).Count -Because 'no testCycle -> empty'
    }
    It 'returns the testCycle map when present' {
        $pool = [ordered]@{ config = [ordered]@{ testCycle = [ordered]@{ autoRemediationEnabled = $true; stepTimeoutMinutes = 12 } } }
        $tc = Get-OuterPoolTestCycleOverride -Pool $pool
        Assert-True  $tc['autoRemediationEnabled'] 'flag carried'
        Assert-Equal -Expected 12 -Actual $tc['stepTimeoutMinutes'] -Because 'value carried'
    }
}

Describe 'Get-OuterAutoRemediation (pool override WINS over config > default)' {
    $cfgOn  = New-TempConfig "testCycle:`n  autoRemediationEnabled: true`n  autoRemediationMaxAttemptsPerCycle: 4`n"
    $cfgOff = New-TempConfig "testCycle:`n  autoRemediationEnabled: false`n"
    try {
        It 'reads the local config when there is no pool override' {
            $r = Get-OuterAutoRemediation -ConfigPath $cfgOn
            Assert-True  $r.Enabled 'config enabled'
            Assert-Equal -Expected 4 -Actual $r.MaxAttempts -Because 'config maxAttempts'
        }
        It 'defaults to off / 2 when the config omits the keys' {
            $r = Get-OuterAutoRemediation -ConfigPath $cfgOff
            Assert-False $r.Enabled 'config off'
            Assert-Equal -Expected 2 -Actual $r.MaxAttempts -Because 'default maxAttempts'
        }
        It 'lets a pool override ENGAGE remediation over a config that is off' {
            $r = Get-OuterAutoRemediation -ConfigPath $cfgOff -PoolTestCycleOverride @{ autoRemediationEnabled = $true; autoRemediationMaxAttemptsPerCycle = 3 }
            Assert-True  $r.Enabled 'override engages'
            Assert-Equal -Expected 3 -Actual $r.MaxAttempts -Because 'override maxAttempts wins'
        }
        It 'lets a pool override DISABLE remediation over a config that is on' {
            $r = Get-OuterAutoRemediation -ConfigPath $cfgOn -PoolTestCycleOverride @{ autoRemediationEnabled = $false }
            Assert-False $r.Enabled 'override disables'
        }
    } finally {
        Remove-Item -LiteralPath $cfgOn, $cfgOff -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-OuterStepTimeoutMinute (pool override WINS over config > default)' {
    $cfg = New-TempConfig "testCycle:`n  stepTimeoutMinutes: 20`n"
    $bare = New-TempConfig "testCycle: {}`n"
    try {
        It 'reads the config value when there is no override' {
            Assert-Equal -Expected 20 -Actual (Get-OuterStepTimeoutMinute -ConfigPath $cfg -DefaultMinutes 90) -Because 'config value'
        }
        It 'falls back to the default when the config omits the key' {
            Assert-Equal -Expected 90 -Actual (Get-OuterStepTimeoutMinute -ConfigPath $bare -DefaultMinutes 90) -Because 'default'
        }
        It 'lets a pool override win over both config and default' {
            Assert-Equal -Expected 7 -Actual (Get-OuterStepTimeoutMinute -ConfigPath $cfg -DefaultMinutes 90 -PoolTestCycleOverride @{ stepTimeoutMinutes = 7 }) -Because 'override wins'
        }
        It 'ignores a non-positive override (keeps the config value)' {
            Assert-Equal -Expected 20 -Actual (Get-OuterStepTimeoutMinute -ConfigPath $cfg -DefaultMinutes 90 -PoolTestCycleOverride @{ stepTimeoutMinutes = 0 }) -Because 'zero override ignored'
        }
    } finally {
        Remove-Item -LiteralPath $cfg, $bare -Force -ErrorAction SilentlyContinue
    }
}
