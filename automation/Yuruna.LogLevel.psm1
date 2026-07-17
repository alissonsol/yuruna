<#PSScriptInfo
.VERSION 2026.07.17
.GUID 4233f4cf-65ad-4c8f-9aa1-c98c89574996
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.LogLevel
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

# Leaf utility: the bootstrap prelude shared by every automation entrypoint -- the
# logLevel cascade and the project/config root resolution. It has no dependencies and
# holds no module state, so it can be imported -Global -Force at the very top of an
# entrypoint (before that script applies its preferences, resolves its roots, and
# evicts + re-imports the Yuruna.* operation modules) without side effects.
# (The module name is historical -- it began as the logLevel helper.)

function Set-YurunaLogLevel {
    <#
    .SYNOPSIS
        Apply the logLevel cascade: enable each preference stream at or above the
        selected level (Error highest), silence the rest.
    .DESCRIPTION
        Sets the four $global:*Preference streams from one level name so that, e.g.,
        -LogLevel Warning shows Error + Warning and silences Information/Verbose/Debug.
        Error < Warning < Information < Verbose < Debug by verbosity; a level shows
        itself and every higher-priority (lower-rank) stream. $ErrorActionPreference
        is deliberately left at its inherited default ('Continue') so errors stay
        visible at every level -- lowering it here would silence them too. Assigns
        $global: so the effect reaches the calling script and everything it runs.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets the session preference streams from one level name; a preference cascade, not a resource mutation. ShouldProcess would not fit a bootstrap logLevel setter.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'The $global:*Preference automatic variables ARE the cross-scope contract this helper exists to set; scoping them narrower would not affect downstream code.')]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
        [string]$LogLevel
    )
    $rank = @{ Error = 1; Warning = 2; Information = 3; Verbose = 4; Debug = 5 }
    $eff  = $rank[$LogLevel]
    $global:WarningPreference     = if ($rank.Warning     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:InformationPreference = if ($rank.Information -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference     = if ($rank.Verbose     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:DebugPreference       = if ($rank.Debug       -le $eff) { 'Continue' } else { 'SilentlyContinue' }
}

function Resolve-YurunaRootSet {
    <#
    .SYNOPSIS
        Resolve the yuruna / project / config roots for an automation entrypoint, set
        the matching Env: items, and return them (or $false on a missing/ambiguous path).
    .DESCRIPTION
        The root-resolution prelude shared by every entrypoint: resolve yuruna_root
        from the caller's script folder; default an empty -ProjectRoot to the current
        location and Resolve-Path it (failing on a missing/ambiguous path); then resolve
        config/<subfolder> under it with the same guard. Each resolved path is exported
        as Env:yuruna_root / Env:project_root / Env:config_root for the tofu/helm
        subprocesses. Returns @{ YurunaRoot; ProjectRoot; ConfigRoot } on success, or
        $false after writing a 'not found or ambiguous' Information message.

        CALL BEFORE the 'Get-Module Yuruna.* | Remove-Module' eviction: the resolution
        never needs the operation modules, so running it first lets this leaf provide the
        helper before the eviction sweeps it up, and the operation modules -- which take
        project_root as a parameter, not from the environment at load -- are unaffected by
        the order.
    .OUTPUTS
        [hashtable] { YurunaRoot; ProjectRoot; ConfigRoot } on success; [bool] $false on a
        missing/ambiguous project or config path.
    #>
    [CmdletBinding()]
    [OutputType([hashtable], [bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resolves paths and sets Env: items for the run; a bootstrap resolver, not a resource mutation. ShouldProcess would not fit an entrypoint prelude that returns $false on a bad path.')]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter()][string]$ProjectRoot,
        [Parameter()][string]$ConfigSubfolder
    )
    $yurunaRoot = Resolve-Path -Path (Join-Path -Path $ScriptRoot -ChildPath "..")
    Set-Item -Path Env:yuruna_root -Value ${yurunaRoot}
    Write-Debug "yuruna_root is $yurunaRoot"

    if ([string]::IsNullOrEmpty($ProjectRoot)) { $ProjectRoot = Get-Location }
    $resolvedRoot = Resolve-Path -LiteralPath $ProjectRoot -ErrorAction SilentlyContinue
    if ($null -eq $resolvedRoot -or @($resolvedRoot).Count -ne 1) { Write-Information "Project folder not found or ambiguous: $ProjectRoot"; return $false }
    $ProjectRoot = $resolvedRoot
    Set-Item -Path Env:project_root -Value ${ProjectRoot}
    Write-Debug "project_root is $ProjectRoot"

    $configRelative = Join-Path -Path $ProjectRoot -ChildPath "config/$ConfigSubfolder"
    $configRoot = Resolve-Path -LiteralPath $configRelative -ErrorAction SilentlyContinue
    if ($null -eq $configRoot -or @($configRoot).Count -ne 1) { Write-Information "Configuration folder not found or ambiguous: $configRelative"; return $false }
    Set-Item -Path Env:config_root -Value ${configRoot}
    Write-Debug "config_root is $configRoot"

    return @{ YurunaRoot = $yurunaRoot; ProjectRoot = $ProjectRoot; ConfigRoot = $configRoot }
}

Export-ModuleMember -Function Set-YurunaLogLevel, Resolve-YurunaRootSet
