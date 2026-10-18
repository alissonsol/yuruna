<#PSScriptInfo
.VERSION 2026.10.18
.GUID 4215c5b2-75d8-47ea-9edd-261bf78adcaa
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

# Bootstrap helpers must run before entrypoints replace the operation modules.
# See https://yuruna.link/42e220c4-0019

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
# --- REGION: Set-YurunaLogLevel
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

# --- REGION: Resolve-YurunaRootSet
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
    if ($null -eq $resolvedRoot -or @($resolvedRoot).Count -ne 1) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_6530aabbb1b7a40a' -Arguments @{ projectRoot = "$ProjectRoot" }); return $false }
    $ProjectRoot = $resolvedRoot
    Set-Item -Path Env:project_root -Value ${ProjectRoot}
    Write-Debug "project_root is $ProjectRoot"

    $configRelative = Join-Path -Path $ProjectRoot -ChildPath "config/$ConfigSubfolder"
    $configRoot = Resolve-Path -LiteralPath $configRelative -ErrorAction SilentlyContinue
    if ($null -eq $configRoot -or @($configRoot).Count -ne 1) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_2bcf3d5983bd68a0' -Arguments @{ configRelative = "$configRelative" }); return $false }
    Set-Item -Path Env:config_root -Value ${configRoot}
    Write-Debug "config_root is $configRoot"

    return @{ YurunaRoot = $yurunaRoot; ProjectRoot = $ProjectRoot; ConfigRoot = $configRoot }
}

# --- REGION: Resolve-YurunaTranscriptPath
function Resolve-YurunaTranscriptPath {
    <#
    .SYNOPSIS
        The file this run should record its transcript in.
    .DESCRIPTION
        A caller that means to read the transcript afterwards names the file in
        YURUNA_TRANSCRIPT_PATH before launching the run, so it holds the path
        already and never has to recover one from what the run printed. Printed
        output is written for a person to read: a caller that recognizes a word
        in it has made that sentence a wire format, and the sentence then cannot
        be reworded or translated without breaking the caller silently.

        An environment variable rather than a parameter, for the same reason the
        preflight sidecar uses one: every existing caller, and every stand-in
        script a test substitutes for one of these, keeps working untouched.

        The variable is CONSUMED, not merely read. These entry points can launch
        one another, and an inherited value would aim two runs at one file --
        the inner one truncating the record the outer is still writing.

        A named path that cannot be used is not worth failing a run over: the
        transcript is a diagnostic, so an unusable name falls back to the
        default and the run proceeds.

        The default is a named file in a yuruna-transcripts folder under the
        temp folder, which keeps only the newest $TranscriptRetention files.
        A failed run prints its transcript, and a successful one leaves it for
        whoever follows the debug pointer, so the recent ones are worth
        keeping; an unbounded series of anonymous tmp*.tmp files is not, and
        on Windows GetTempFileName fails outright once 65,535 of them exist.
    .PARAMETER TranscriptRetention
        How many default transcripts to keep, the new one included.
    .OUTPUTS
        [string] An absolute path to write the transcript to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(1, 1000)][int]$TranscriptRetention = 20)

    $named = "$env:YURUNA_TRANSCRIPT_PATH".Trim()
    $env:YURUNA_TRANSCRIPT_PATH = ''
    if (-not $named) { return (New-YurunaDefaultTranscriptPath -Retention $TranscriptRetention) }
    try {
        $full = [IO.Path]::GetFullPath($named)
        $parent = Split-Path -Parent $full
        if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
        }
        # Proving it is writable here, rather than at Start-Transcript, keeps the
        # fallback available: by then the run has already committed to the path.
        [IO.File]::WriteAllText($full, '')
        return $full
    } catch {
        Write-Verbose ("The named transcript path could not be used, so the default is: {0}" -f $_.Exception.Message)
        return (New-YurunaDefaultTranscriptPath -Retention $TranscriptRetention)
    }
}

function New-YurunaDefaultTranscriptPath {
    <#
    .SYNOPSIS
        A new transcript path in the bounded yuruna-transcripts temp folder,
        after pruning that folder to its newest Retention-1 files.
    .DESCRIPTION
        Never throws: a folder that cannot be created or pruned falls back to
        a named file directly in the temp folder, which is still one file per
        run rather than an anonymous one.
    .OUTPUTS
        [string] An absolute path that does not exist yet.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Prunes only its own bounded transcript folder on the way to naming a log; a -WhatIf run would still need the path.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [ValidateRange(1, 1000)][int]$Retention = 20,
        [string]$Root = (Join-Path ([IO.Path]::GetTempPath()) 'yuruna-transcripts')
    )
    $leaf = 'transcript-{0}-{1}.log' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [Guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $null = New-Item -ItemType Directory -Path $Root -Force -ErrorAction Stop
        # New-Item -Force returns quietly when a FILE already holds the name.
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "'$Root' exists and is not a folder." }
        $old = @(Get-ChildItem -LiteralPath $Root -File -Filter 'transcript-*.log' -ErrorAction Stop |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip ($Retention - 1))
        foreach ($file in $old) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        return (Join-Path $Root $leaf)
    } catch {
        Write-Verbose ("The transcript folder '{0}' is unusable, so the transcript goes beside it: {1}" -f $Root, $_.Exception.Message)
        return (Join-Path ([IO.Path]::GetTempPath()) "yuruna-$leaf")
    }
}

Export-ModuleMember -Function Set-YurunaLogLevel, Resolve-YurunaRootSet, Resolve-YurunaTranscriptPath, New-YurunaDefaultTranscriptPath
