<#PSScriptInfo
.VERSION 2026.08.05
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
# by Invoke-TestRunnerInnerLoop.ps1, Invoke-TestSequence.ps1, Test.SequenceEngine.psm1,
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

# The caller's ProgressPreference, captured the first time
# Set-LogLevelPreference suppresses it (at Verbose/Debug) and restored when the
# level rises back above Verbose. $null means "nothing suppressed to restore".
$script:SavedProgressPreference = $null

# Path this process is transcribing to, or $null when it is not. Guards against
# a second Start-Transcript in a script that re-imports this module.
$script:ChildTranscriptPath = $null

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
    # left at its inherited default ('Continue') -- even at logLevel='Error'
    # we want errors visible, and lowering it would also hide them.
    $global:WarningPreference     = if ($script:LogLevelRank.Warning     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:InformationPreference = if ($script:LogLevelRank.Information -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:VerbosePreference     = if ($script:LogLevelRank.Verbose     -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    $global:DebugPreference       = if ($script:LogLevelRank.Debug       -le $eff) { 'Continue' } else { 'SilentlyContinue' }
    # Verbose and below want a quiet progress bar -- Write-Progress otherwise
    # overwrites the per-poll OCR debug lines and makes the transcript unreadable.
    # Restore is symmetric with the four stream preferences above, but puts back
    # the CAPTURED value rather than forcing 'Continue': a caller that set
    # SilentlyContinue for a reason (Write-Progress trips SetCursorPosition on
    # tmux/vscode/sshd -- feedback_pwsh_linux_write_progress_setcursor) keeps its
    # choice instead of having the progress bar force-enabled under it.
    if ($eff -ge $script:LogLevelRank.Verbose) {
        if ($null -eq $script:SavedProgressPreference) { $script:SavedProgressPreference = $global:ProgressPreference }
        $global:ProgressPreference = 'SilentlyContinue'
    } elseif ($null -ne $script:SavedProgressPreference) {
        $global:ProgressPreference = $script:SavedProgressPreference
        $script:SavedProgressPreference = $null
    }
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

function Start-YurunaChildTranscript {
    <#
    .SYNOPSIS
        Tee this process's PowerShell streams into a file under
        $env:YURUNA_CHILD_TRANSCRIPT_DIR when a parent asked for one.
        Silent no-op when the variable is unset.
    .DESCRIPTION
        A parent that hands its real console to a child -- so the child's
        prompts stay visible and Read-Host still reaches the keyboard -- cannot
        also pipe that child's output somewhere it can read back afterwards. Its
        own log then records an exit code and nothing else, and the reason a
        child failed lives only in the operator's scrollback.

        Start-Transcript closes that gap from the child's side: it writes a copy
        of the output streams to a file WITHOUT taking the console away, so a
        parent gets a readable record and the operator still sees, and can
        answer, every prompt.

        One file per process, named for the script and its pid. A child that
        spawns pwsh grandchildren of its own -- a Start-*ServiceVM delegating to
        a per-host New-VM.ps1 -- would otherwise have two processes writing one
        file. Each generation lands in the shared directory under a name of its
        own, and the parent reads whichever ones exist.

        Best-effort, and deliberately silent when it cannot start: a transcript
        is a diagnostic aid, so a host that has transcription running already,
        an unwritable directory, or a host that does not implement transcription
        at all must not cost the script the work it was started to do.

        A native command's stderr is NOT part of a PowerShell transcript -- that
        goes straight to the console handle. Every PowerShell stream does land
        in the file, which is where an entry point's own failure text is written.
    .OUTPUTS
        [string] the transcript path, or '' when none was started.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Opens a diagnostic transcript for this process; a log-level prelude carries no -WhatIf intent.')]
    param()
    if ($script:ChildTranscriptPath) { return $script:ChildTranscriptPath }
    $dir = $env:YURUNA_CHILD_TRANSCRIPT_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false | Out-Null
        }
        # The BOTTOM call-stack frame is the script pwsh was launched with, which
        # is the name an operator recognizes in the parent's report. A dot-sourced
        # or interactive caller leaves it empty, hence the fallback.
        $leaf = 'child'
        $bottom = @(Get-PSCallStack)[-1].ScriptName
        if ($bottom) { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($bottom) }
        $leaf = $leaf -replace '[^A-Za-z0-9._-]', '_'
        $path = Join-Path $dir ('{0}.{1}.log' -f $leaf, $PID)
        $transcriptArgs = @{ Path = $path; Append = $true; WhatIf = $false; ErrorAction = 'Stop' }
        # -UseMinimalHeader keeps the preamble to one line instead of a dozen. It
        # arrived after 7.0, which #requires -version 7 still admits, so it is
        # passed only where the parameter exists.
        if ((Get-Command Start-Transcript).Parameters.ContainsKey('UseMinimalHeader')) {
            $transcriptArgs['UseMinimalHeader'] = $true
        }
        Start-Transcript @transcriptArgs | Out-Null
        $script:ChildTranscriptPath = $path
        return $path
    } catch {
        # Nowhere useful to report this: the console belongs to the operator and
        # the parent's log is not reachable from here.
        $script:ChildTranscriptPath = $null
        return ''
    }
}

function Use-LogLevelFromEnv {
    <#
    .SYNOPSIS
        Apply the cascade in a child script that inherited YURUNA_LOG_LEVEL
        from its parent. No-op when the env var is unset or invalid -- the
        script keeps PowerShell's default preference values.
    .DESCRIPTION
        Also opens the child transcript when a parent asked for one. Both
        concerns answer the same question -- what this run says, and where it
        can be read afterwards -- and this is the one call every yuruna entry
        point already makes, so hanging the transcript here reaches all of them
        (including the per-guest builders a service bring-up spawns) without a
        second line in each.
    #>
    if ($env:YURUNA_LOG_LEVEL -and $script:LogLevelRank.Contains($env:YURUNA_LOG_LEVEL)) {
        Set-LogLevelPreference -Level $env:YURUNA_LOG_LEVEL
    }
    [void](Start-YurunaChildTranscript)
}

Export-ModuleMember -Function Get-LogLevelRank, Set-LogLevelPreference, Resolve-LogLevel, `
    Use-LogLevelFromEnv, Start-YurunaChildTranscript
