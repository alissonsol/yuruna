<#PSScriptInfo
.VERSION 2026.06.26
.GUID 425458ca-5060-4a2d-b2e3-2fb297ec265e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Canonical log-level cascade. Why this lives in its own module: it is
# the single source for the rank table + preference-cascade logic shared
# by Invoke-TestInnerRunner.ps1, Test-Sequence.ps1, Invoke-Sequence.psm1,
# and every host/<platform>/guest.<x>/{Get-Image,New-VM}.ps1 (28+
# consumers). A new level (or a tweak to ProgressPreference) is a single
# edit here instead of a hand edit in every copy.
#
# See docs/loglevels.md for the cascade semantics and why env-var
# propagation is the only way to reach child pwsh processes.

$script:LogLevelRank = [ordered]@{
    Error       = 1
    Warning     = 2
    Information = 3
    Verbose     = 4
    Debug       = 5
}

function Get-LogLevelRank {
    <#
    .SYNOPSIS
        Returns the ordered map of log-level name -> numeric rank.
    .DESCRIPTION
        Used by Set-LogLevelPreference (and external diagnostics) to
        compare a configured level against the canonical rank order:
        Error=1, Warning=2, Information=3, Verbose=4, Debug=5.
    #>
    return $script:LogLevelRank
}

function Set-LogLevelPreference {
    <#
    .SYNOPSIS
        Apply the stream-visibility cascade for a single level name.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Sets in-process PowerShell preference variables only; no externally observable state change.')]
    param([Parameter(Mandatory)][string]$Level)
    if (-not $script:LogLevelRank.Contains($Level)) { return }
    $eff = $script:LogLevelRank[$Level]
    # Stream visibility cascade. $ErrorActionPreference is intentionally
    # left at its inherited default ('Continue') — even at logLevel='Error'
    # we want errors visible, and lowering it would also hide them.
    $global:WarningPreference     = if ($script:LogLevelRank.Warning     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:InformationPreference = if ($script:LogLevelRank.Information -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference     = if ($script:LogLevelRank.Verbose     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:DebugPreference       = if ($script:LogLevelRank.Debug       -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    # Verbose and below want a quiet progress bar — Write-Progress otherwise
    # overwrites the per-poll OCR debug lines and makes the transcript unreadable.
    if ($eff -ge $script:LogLevelRank.Verbose) { $global:ProgressPreference = 'SilentlyContinue' }
}

function Resolve-LogLevel {
    <#
    .SYNOPSIS
        Three-state resolver: CmdLineLevel > ConfigLevel > 'Information'.
        Applies the preference cascade and publishes $env:YURUNA_LOG_LEVEL
        so child pwsh processes inherit the effective level.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$CmdLineLevel,
        [AllowNull()][AllowEmptyString()][string]$ConfigLevel
    )
    $effective = if ($CmdLineLevel) { $CmdLineLevel }
                 elseif ($ConfigLevel) { $ConfigLevel }
                 else { 'Information' }
    # Normalize case. Reject anything not in the rank table; fall back to
    # 'Information' so a typo in YAML still surfaces step-level output.
    $matched = $script:LogLevelRank.Keys | Where-Object { $_ -ieq $effective } | Select-Object -First 1
    if (-not $matched) {
        Write-Warning "logLevel '$effective' is not one of $($script:LogLevelRank.Keys -join ', '); falling back to 'Information'."
        $matched = 'Information'
    }
    Set-LogLevelPreference -Level $matched
    $env:YURUNA_LOG_LEVEL = $matched
    return $matched
}

function Use-LogLevelFromEnv {
    <#
    .SYNOPSIS
        Apply the cascade in a child script that inherited YURUNA_LOG_LEVEL
        from its parent. No-op when the env var is unset or invalid — the
        script keeps PowerShell's default preference values.
    #>
    if ($env:YURUNA_LOG_LEVEL -and $script:LogLevelRank.Contains($env:YURUNA_LOG_LEVEL)) {
        Set-LogLevelPreference -Level $env:YURUNA_LOG_LEVEL
    }
}

Export-ModuleMember -Function Get-LogLevelRank, Set-LogLevelPreference, Resolve-LogLevel, Use-LogLevelFromEnv
