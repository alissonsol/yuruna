<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4232820e-f96a-47ea-863b-f94b73f9c76f
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

# Built-in verb Handler scriptblocks for the sequence engine.
# Sequence-engine layering (registry / handler catalog / driver) and
# the retry/recoverFromSnapshot split: https://yuruna.link/42d38664

# Test.HostIO carries the Invoke-HostIOAction primitive that the
# Send-Key / Send-Text / Send-Click dispatchers in Invoke-Sequence
# delegate to; Test.SequenceAction provides Register-SequenceAction
# itself. Both come in -Global so the registrations below are visible
# to the engine without Invoke-Sequence having to re-import this
# module's internals.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Force -DisableNameChecking -Global

# Bind the shared, cross-module sequence failure-state. sshWaitReady writes
# the installer-failure-pattern signal here; the engine (Invoke-Sequence)
# reads it from the SAME $global:-anchored store. Writing to a per-module
# $script: slot instead would leave the engine reading $null and mis-classify
# an installer crash as a plain timeout. See Test.SequenceFailureState.psm1.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceFailureState.psm1') -Force -Global
$script:Fail = Get-SequenceFailureState

# Cross-language fetch-and-execute failure sentinel. The guest wrapper
# (automation/fetch-and-execute.sh) and the guest install scripts PRINT this
# exact string on a non-zero child exit; the fetchAndExecute verb below MATCHES
# it via Wait-ForText -FailurePattern for a seconds-fast crash detection.
# Declared here (and mirrored bash-side) so the coupling is one named constant
# per language rather than two bare literals that can silently drift; the
# Test.NonzeroExitSentinel drift-guard asserts the bash producer agrees.
$script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'

# The wrapper prints the sentinel for two different events, and only it can tell
# them apart: a script that RAN and exited non-zero, and a payload that was never
# served so nothing ran at all. It already says which in the parenthetical it
# appends. Matching only the sentinel discards that, and the second event then
# arrives as the verb registry's script_error -- a script to debug that never
# existed, and a class the transient allow-lists exclude, so the failure most
# likely to clear on its own is the one nothing retries.
#
# These are the never-ran reasons that are SAFE to retry. Two are deliberately
# absent. "(exit N)" is the script's own non-zero status -- it ran, and
# script_error is correct. "(integrity mismatch -- refusing to run)" also never
# ran, but it is a refusal, not a shortage: the fetched bytes did not match the
# host's digest, and a retry is the one response that must not be advertised for
# it. The strings are mirrored from automation/fetch-and-execute.sh and pinned
# against it by a drift guard, the same coupling the sentinel itself uses.
$script:PayloadUnavailableReason = @(
    '(no fetch source)',
    '(fetch failed, wget exit ',
    '(could not create temp file)'
)

function Test-GuestPayloadUnavailable {
    <#
    .SYNOPSIS
        Did the guest report that no source served the script, so nothing ran?
    .OUTPUTS
        [bool] true only for a wrapper failure that never reached the payload.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Output)
    if ([string]::IsNullOrEmpty($Output)) { return $false }
    if ($Output -notmatch [regex]::Escape($script:NonzeroScriptExitSentinel)) { return $false }
    foreach ($reason in $script:PayloadUnavailableReason) {
        if ($Output.Contains($reason)) { return $true }
    }
    return $false
}

# The shell's own refusal of the command line it was just handed. Unlike the
# sentinel above -- which the wrapper prints, and which therefore proves the
# wrapper RAN -- these come from bash before anything of ours executes: the
# interpreter named on the line does not exist, so no script, no wrapper and no
# sentinel will ever appear, and the completion marker is unreachable from the
# first second onward.
#
# The way a console-typed command reaches that state is the keystroke
# transport: the line is delivered one key event per character into a guest
# whose input layer can drop and reorder them under load, and a command word
# that loses four characters is a command word that does not resolve. Nothing
# upstream can see that happen, and nothing downstream can distinguish it from
# a payload that is merely slow, which is why the shell's answer is worth
# reading directly.
#
# These are matched ONLY inside Wait-ForText's early window (see
# $script:ShellRejectionWindowSeconds). Both strings are also routine output
# from a healthy script -- probing for an optional binary prints one or the
# other constantly -- so outside that window they carry no signal at all.
$script:ShellRejectedCommandPattern = @(
    'command not found',
    'No such file or directory'
)

# How long after Enter the shell's refusal is still the only plausible source
# of those strings. bash answers a command line it cannot resolve immediately;
# this is sized to cover a handful of OCR polls rather than to bound the
# shell, so a frame lost to a capture glitch still leaves later frames inside
# the window. Beyond it the fetched script owns the console and the same
# strings become its ordinary output.
$script:ShellRejectionWindowSeconds = 20

# --- REGION: https://yuruna.link/428e4df6-0014
# Complete command length above which macOS GUI fetches use verified staging.
# Other console paths retain their warning. Include metadata and shell quoting
# in this budget; see the linked sequence authoring guidance.
$script:FetchExecuteTypedCharWarn = 400

function Get-NonzeroScriptExitSentinel {
    <#
    .SYNOPSIS
        The cross-language fetch-and-execute failure sentinel produced by
        automation/fetch-and-execute.sh and matched by the fetchAndExecute verb.
    #>
    [OutputType([string])]
    param()
    return $script:NonzeroScriptExitSentinel
}

# OCR-tolerant matching: sshWaitReady's slow path scans the console for
# installer-failure patterns via Test-CombinedOcrMatch. It lives in
# Test.OcrMatch and is imported -Global here so
# the handler scope resolves it instead of an unexported engine function.
Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force -Global

# retry backs off between attempts via Get-PollDelay (jittered, capped). It
# lives in Test.Backoff; import it -Global so the retry Handler below resolves
# it by bare name. Test.Backoff is stateless, so a -Force reimport wipes nothing.
Import-Module (Join-Path $PSScriptRoot 'Test.Backoff.psm1') -Force -Global

# fetchAndExecute tells the guest which GitHub repo + commit to fall back to when
# the host status service is unreachable. Get-YurunaGitHubSource answers that from
# the same place the New-VM seed does, so the typed and the baked coordinates can
# never name different repositories.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.GitHubSource.psm1') -Force -Global

# --- REGION: Helpers shared by the pattern-bearing verbs
# (waitForText, waitForAndEnter, passwdPrompt). Kept private to this module --
# the engine never calls them.

function Format-SequencePatternLabel {
    # Shared helper for the four pattern-bearing actions (waitForText,
    # waitForAndEnter, passwdPrompt). $Step's `pattern` may be a single
    # string or an array; arrays render as "' | '"-joined for the
    # human-readable label.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Vars, [Parameter(Mandatory)]$ExpandVariable)
    $raw = $Step.pattern
    if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) {
        return (($raw | ForEach-Object { & $ExpandVariable $_ $Vars }) -join "' | '")
    }
    return (& $ExpandVariable $raw $Vars)
}

function Resolve-WaitForTextStepParam {
    # Returns @{ patterns; failurePatterns; timeout; poll; fresh; tailLines;
    # sinceStepStart } from a $Context. Used by waitForText /
    # waitForTextWithNudge / waitForAndEnter / passwdPrompt Handlers so the
    # pattern-bearing verbs share one expansion path.
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $step = $Context.Step
    $raw = $step.pattern
    [string[]]$patterns = if ($raw -is [System.Collections.IEnumerable] -and $raw -isnot [string]) {
        $raw | ForEach-Object { & $Context.ExpandVariable $_ $Context.Vars }
    } else { @(& $Context.ExpandVariable $raw $Context.Vars) }
    $rawF = $step.failurePatterns
    [string[]]$fp = @()
    if ($null -ne $rawF) {
        $fp = if ($rawF -is [System.Collections.IEnumerable] -and $rawF -isnot [string]) {
            @($rawF | ForEach-Object { & $Context.ExpandVariable $_ $Context.Vars })
        } else { @(& $Context.ExpandVariable $rawF $Context.Vars) }
    }
    @{
        patterns        = $patterns
        failurePatterns = $fp
        timeout         = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $Context.DefaultTimeoutSeconds
        poll            = $step.pollSeconds    ? [int]$step.pollSeconds    : $Context.DefaultPollSeconds
        fresh           = $step.freshMatch -eq $true
        tailLines       = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
        # Confine the positive match to lines that were NOT already on screen
        # when the wait began. A prompt whose wording is a subsequence of text
        # standing above it -- PAM's "New password:" against the banner saying
        # the password must be changed -- matches that banner on the first
        # poll, and the verb then answers a prompt the guest has not printed:
        # the password lands on a tty PAM has not yet switched to no-echo,
        # echoes in the clear, and the retype can no longer match. Only text
        # the step itself provoked can carry that verdict. failurePatterns are
        # deliberately NOT narrowed this way -- a crash screen is evidence
        # whenever it is visible, including when it was visible on arrival.
        sinceStepStart  = $step.sinceStepStart -eq $true
    }
}

# --- REGION: Verb registrations
# Each Register-SequenceAction binds (Name -> Handler). Handlers
# communicate with the engine via the $Context hashtable (Step, Vars,
# VMName/GuestKey/HostType, per-cycle paths, engine defaults and
# callbacks). Full field table: See docs/test-sequences.md, "Handler contract".

# Send the optional Tab-navigation prefix a keyboard-input verb uses to reach the
# target field before typing: read $Context.Step.tabCount, press Tab that many times
# (300ms between presses so the guest UI keeps up), then a 500ms settle. Shared by
# waitForAndEnter and passwdPrompt so the Tab cadence cannot drift between them.
function Send-TabNavigation {
    param([Parameter(Mandatory)][hashtable]$Context)
    $tabCount = $Context.Step.tabCount ? [int]$Context.Step.tabCount : 0
    if ($tabCount -gt 0) {
        Write-Debug "      Sending $tabCount Tab(s) to reach the target element"
        for ($t = 0; $t -lt $tabCount; $t++) {
            Test.SequenceEngine\Send-Key -HostType $Context.HostType -VMName $Context.VMName -KeyName 'Tab' | Out-Null
            Start-Sleep -Milliseconds 300
        }
        Start-Sleep -Milliseconds 500
    }
}

# Shared tail of the type-then-Enter input verbs (inputTextAndEnter, waitForAndEnter,
# passwdPrompt, fetchAndExecute): send the already-expanded $Text; on a Send-Text
# failure bail BEFORE draining (no Enter is sent); otherwise drain $DelaySeconds with
# progress ticks + an 800ms settle, then press Enter. Returns the Enter result as
# [bool] (or $false when Send-Text failed). Callers keep their own "Typing ..." debug
# line -- the message text and the sensitive-masking rule differ per verb -- and decide
# whether to return the result or continue (fetchAndExecute continues to wait for a
# completion marker). $ShellEscape is OFF for passwdPrompt so the password types
# literally, ON for the command/text verbs, matching each verb's Send-Text call.
# Send-Text / Send-Key are qualified to Invoke-Sequence's dispatcher (the same names
# also exist on the per-host I/O modules imported here). Write-Progress-only ticks
# emit nothing to the output stream, so the single [bool] return is uncontaminated.
function Invoke-TypeDrainEnter {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][double]$DelaySeconds,
        [Parameter(Mandatory)][int]$CharDelayMs,
        [Parameter(Mandatory)][string]$Activity,
        [switch]$ShellEscape
    )
    $ok = Test.SequenceEngine\Send-Text -HostType $Context.HostType -VMName $Context.VMName -Text $Text -CharDelayMs $CharDelayMs -ShellEscape:$ShellEscape
    if ($ok -eq $false) { return $false }
    $delaySecsInt = [int][math]::Ceiling($DelaySeconds)
    for ($r = $delaySecsInt; $r -gt 0; $r--) {
        $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt, 1)) * 100)
        Write-ProgressTick -Activity $Activity -Status "drain ${r}s" -PercentComplete $pct
        Start-Sleep -Seconds 1
    }
    Write-ProgressTick -Activity $Activity -Completed
    Start-Sleep -Milliseconds 800
    return [bool](Test.SequenceEngine\Send-Key -HostType $Context.HostType -VMName $Context.VMName -KeyName 'Enter')
}

function Invoke-BlindAnswer {
    <#
    .SYNOPSIS
        Send a waitForAndEnter step's answer to a console its pattern could not
        be read off, when the screen says the guest is parked rather than busy.
    .DESCRIPTION
        A prompt printed once and never reprinted is a consumable: the guest goes
        on waiting for input long after the question has scrolled out of the
        visible surface, and no amount of further waiting brings it back. The
        wait that just failed cannot tell that guest from one still working, but
        its verdict can -- a parked guest prints nothing, so its console CONTENT
        stops moving while a working one keeps changing.

        Sending the answer is bounded by that evidence and by proof it landed:
        the console content moving again IS the answer being consumed. Where a
        step names `confirmPattern`, that is used instead, for guests whose next
        screen is known. Without either, the step is left to fail exactly as it
        would have.
    .OUTPUTS
        [bool] $true when the answer was sent AND confirmed; $false otherwise,
        including when the screen gave no reason to send it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string[]]$Patterns
    )
    $verdict = Get-LastWaitVerdict
    $patternDisplay = $Patterns -join "' | '"
    # A wait that confined its match to the console tail (freshMatch) publishes no
    # console text and no static reading, because it runs neither tracker. Those
    # are the same empty values a dead capture feed produces, and the no-text
    # message below would report a screen state nothing observed. Say which it is
    # before saying anything about the guest. Explicit $false only: a verdict
    # without the flag -- one from a caller, or from a wait that never ran -- is
    # left to the checks below rather than being refused on a missing key.
    if ($false -eq $verdict.ConsoleSignalsMeasured) {
        Write-Debug "      Blind answer skipped for '$patternDisplay': the wait confined its match to the console tail, so nothing measured the screen and there is no evidence to answer from."
        return $false
    }
    # A screen with no text is a capture problem, not a parked guest, and typing
    # at one proves nothing. Wait-ForText's own no-text self-heal owns that case.
    if (-not $verdict.ConsoleText) {
        Write-Debug "      Blind answer skipped for '$patternDisplay': no text on screen."
        return $false
    }
    # A screen this step names is one the answer must never be typed at. Both
    # halves of the blind contract are satisfied by an interactive menu just as
    # well as by the scrolled-away prompt they were written for: a menu waiting
    # on a keystroke is perfectly static, and the keystroke navigates it, so the
    # console moves and reads as consumption. Only the screen itself separates
    # the two. Declining costs nothing but the recovery -- the step still spends
    # the rest of its budget on the wait it asked for -- so a pattern here is
    # safe to be wrong about in a way a failurePattern is not. Matched with
    # -NoSegmentMatch so an anti-pattern cannot fire on its own words scattered
    # across an unrelated screen.
    $rawSkip = $Context.Step.blindSkipPattern
    if ($null -ne $rawSkip) {
        $skipPatterns = if ($rawSkip -is [System.Collections.IEnumerable] -and $rawSkip -isnot [string]) {
            @($rawSkip | ForEach-Object { & $Context.ExpandVariable $_ $Context.Vars })
        } else { @(& $Context.ExpandVariable $rawSkip $Context.Vars) }
        foreach ($skip in $skipPatterns) {
            if (-not $skip) { continue }
            if (Test-OCRMatch -Text ([string]$verdict.ConsoleText) -Pattern $skip -NoSegmentMatch) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6b60cfa8b09732e1' -Arguments @{ patternDisplay = "$patternDisplay"; skip = "$skip" })
                return $false
            }
        }
    }
    # "Parked" means the content did not move for most of the window just spent.
    # A guest still printing -- an install running, a service looping -- fails
    # this and is left alone, which is what keeps the answer away from a console
    # whose reader is no longer the prompt this step was written for.
    $staticSecs = [int]$verdict.ConsoleStaticSeconds
    $elapsed    = [int]$verdict.ElapsedSeconds
    if ($staticSecs -le 0 -or ($staticSecs * 2) -lt $elapsed) {
        Write-Debug "      Blind answer skipped for '$patternDisplay': console still moving (static ${staticSecs}s of ${elapsed}s)."
        return $false
    }
    $text   = & $Context.ExpandVariable $Context.Step.text $Context.Vars
    $masked = ($Context.Step.sensitive -and -not $Context.ShowSensitive) ? '***' : $text
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e14f9f746130d056' -Arguments @{ patternDisplay = "$patternDisplay"; staticSecs = "${staticSecs}"; elapsed = "${elapsed}"; masked = "$masked" })
    $baselineText = [string]$verdict.ConsoleText
    Send-TabNavigation -Context $Context
    $delaySeconds = $Context.Step.delaySeconds ? [double]$Context.Step.delaySeconds : 2
    $charDelay    = $Context.Step.charDelayMs ? [int]$Context.Step.charDelayMs : $Context.DefaultCharDelayMs
    if (-not (Invoke-TypeDrainEnter -Context $Context -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'waitForAndEnter' -ShellEscape)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_99bfd6c66d50c714')
        return $false
    }
    $confirmSeconds = $Context.Step.confirmSeconds ? [int]$Context.Step.confirmSeconds : 90
    $rawConfirm = $Context.Step.confirmPattern
    [string[]]$confirmPatterns = @()
    if ($null -ne $rawConfirm) {
        $confirmPatterns = if ($rawConfirm -is [System.Collections.IEnumerable] -and $rawConfirm -isnot [string]) {
            @($rawConfirm | ForEach-Object { & $Context.ExpandVariable $_ $Context.Vars })
        } else { @(& $Context.ExpandVariable $rawConfirm $Context.Vars) }
    }
    $confirmed = if ($confirmPatterns.Count -gt 0) {
        [bool](Wait-ForText -HostType $Context.HostType -VMName $Context.VMName -Pattern $confirmPatterns `
            -TimeoutSeconds $confirmSeconds -PollSeconds ($Context.Step.pollSeconds ? [int]$Context.Step.pollSeconds : $Context.DefaultPollSeconds))
    } else {
        [bool](Wait-ForConsoleChange -HostType $Context.HostType -VMName $Context.VMName `
            -BaselineText $baselineText -TimeoutSeconds $confirmSeconds)
    }
    if ($confirmed) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e5f3311fb1c7efe3')
        return $true
    }
    # "Nothing changed" is a claim about the guest, and the confirmation can only
    # make it when it could read the console at all. A reader that came back
    # empty on every frame observed nothing, and saying the answer was wrong
    # there sends the reader of this log after the guest instead of after the
    # capture path that actually failed. Guarded because the engine that
    # publishes the verdict is imported alongside this module, not by it.
    $changeVerdict = $null
    if ($confirmPatterns.Count -eq 0 -and (Get-Command Get-LastConsoleChangeVerdict -ErrorAction SilentlyContinue)) {
        $changeVerdict = Get-LastConsoleChangeVerdict
    }
    if ($changeVerdict -and $changeVerdict.Captures -gt 0 -and -not $changeVerdict.Readable) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_55df2212959dcc27' -Arguments @{ confirmSeconds = "${confirmSeconds}" })
        return $false
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_50a7bf951f965871' -Arguments @{ confirmSeconds = "${confirmSeconds}" })
    return $false
}

Register-SequenceAction -Name 'waitForSeconds' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'wait_timeout' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_30c3357c36a22f3f') `
    -Handler {
        param([hashtable]$c)
        $secs = [int]$c.Step.seconds
        Write-Debug "      Waiting $secs seconds..."
        for ($r = $secs; $r -gt 0; $r--) {
            $pct = [math]::Round((($secs - $r) / [math]::Max($secs,1)) * 100)
            Write-ProgressTick -Activity 'waitForSeconds' -Status "${r}s remaining" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'waitForSeconds' -Completed
        return $true
    }

Register-SequenceAction -Name 'pressKey' -HostIORequirement @('Send-Key') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_9adf9c3e3080cfe9') `
    -FailureLabel { param($c) "pressKey: $($c.Step.name)" } `
    -Handler {
        param([hashtable]$c)
        $keyName = $c.Step.name
        Write-Debug "      Sending key '$keyName'..."
        return [bool](Test.SequenceEngine\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName $keyName)
    }

Register-SequenceAction -Name 'break' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'unknown' -Severity 'soft' `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_ba423d49315a4ad5') `
    -Handler {
        param([hashtable]$c)
        if ($env:YURUNA_BREAK_DISABLED -eq '1') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bb0ea5e83baa8154')
            return $true
        }
        if (-not (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
            $logModule = Join-Path $PSScriptRoot 'Test.Log.psm1'
            if (Test-Path $logModule) { Import-Module $logModule -Global -Force -Verbose:$false }
        }
        $diagFolder = Get-CycleGuestDataFolder -VMName $c.VMName
        if (-not $diagFolder) { $diagFolder = $c.LogDir }
        $markerName = ".yuruna-break-{0:D3}.lock" -f [int]$c.StepNum
        $markerPath = Join-Path $diagFolder $markerName
        $reason = & $c.ExpandVariable $c.Step.reason $c.Vars
        # `id` is a pure label (shown in the marker file + status UI). It does NOT
        # by itself trigger a snapshot restore: a break id legitimately matches a
        # real snapshot name (e.g. the workload's requiresSnapshot / loadDiskSnapshot
        # id) for traceability without meaning "rewind to it". Restore-on-Continue
        # is opt-in via `restoreOnContinue: true`, so a plain breakpoint just pauses
        # and resumes in place -- the usual breakpoint semantics.
        $breakSnapshotId   = & $c.ExpandVariable $c.Step.id $c.Vars
        $restoreOnContinue = ($c.Step.restoreOnContinue -eq $true)
        $resumeDesc = if ($restoreOnContinue -and $breakSnapshotId) {
            "restores snapshot '$breakSnapshotId', restarts the VM, then resumes"
        } else {
            "resumes the sequence in place (no snapshot restore)"
        }
        $bodyLines = @(
            "Yuruna sequence breakpoint",
            "VM:       $($c.VMName)",
            "GuestKey: $($c.GuestKey)",
            "Step:     $($c.StepNum)/$($c.StepCount)",
            "Reason:   $(if ($reason) { $reason } else { '(no reason supplied)' })",
            "Label:    $(if ($breakSnapshotId) { $breakSnapshotId } else { '(none)' })",
            "On Continue: $resumeDesc",
            "",
            "To resume:",
            "  - Click 'Continue' in the status UI (http://localhost:8080/status/),",
            "    which $resumeDesc; or",
            "  - Delete this file manually (always resumes in place):",
            "      Remove-Item -LiteralPath '$markerPath'",
            "    or, on a POSIX shell:",
            "      rm `"$markerPath`""
        )
        Set-Content -LiteralPath $markerPath -Value ($bodyLines -join [Environment]::NewLine) -Encoding utf8 -Force
        $breakActivePath   = Join-Path $c.RuntimeDir 'break-active.json'
        $breakContinueFlag = Join-Path $c.RuntimeDir 'control.break-continue'
        Remove-Item -LiteralPath $breakContinueFlag -Force -ErrorAction SilentlyContinue
        $breakAttempts = 0
        $breakLastErr  = $null
        while ($breakAttempts -lt 3) {
            $breakAttempts++
            try {
                $breakDoc = [ordered]@{
                    guestKey   = $c.GuestKey
                    vmName     = $c.VMName
                    hostType   = $c.HostType
                    stepNum    = [int]$c.StepNum
                    stepCount  = [int]$c.StepCount
                    snapshotId = $breakSnapshotId
                    restoreOnContinue = [bool]$restoreOnContinue
                    reason     = if ($reason) { [string]$reason } else { '' }
                    markerPath = [string]$markerPath
                    startedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
                $tmp = "$breakActivePath.tmp"
                $breakDoc | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding utf8NoBOM
                Move-Item -Path $tmp -Destination $breakActivePath -Force
                $breakLastErr = $null
                break
            } catch {
                $breakLastErr = $_
                Start-Sleep -Milliseconds (50 * $breakAttempts)
            }
        }
        if ($breakLastErr) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7c7b00a26a30f926' -Arguments @{ breakAttempts = "$breakAttempts"; message = "$($breakLastErr.Exception.Message)"; breakActivePath = "$breakActivePath" })
            Send-CycleEventSafely -EventRecord @{
                timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event     = 'sidecar_write_failed'
                file      = 'break-active.json'
                path      = [string]$breakActivePath
                attempts  = $breakAttempts
                error     = $breakLastErr.Exception.Message
            }
        }
        # Compose a clickable status-service URL so the operator can find
        # the Continue button without hunting for the UI. Port comes from
        # test.config.yml's statusService.port (default 8080). Localhost
        # is used because the operator is on the host; guests use
        # Resolve-StatusServiceEndpoint for the LAN-reachable URL.
        $breakStatusUrl = $null
        try {
            $breakStatusPort = 8080
            $breakCfgPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else {
                Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
            }
            if ((Test-Path -LiteralPath $breakCfgPath) -and (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
                $breakCfg = Read-TestConfig -Path $breakCfgPath
                if ($breakCfg -and $breakCfg.statusService -and $breakCfg.statusService.port) {
                    $breakStatusPort = [int]$breakCfg.statusService.port
                }
            }
            $breakStatusUrl = "http://localhost:${breakStatusPort}/status/"
        } catch { $null = $_ }
        if ($breakStatusUrl) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8ad9793072ea0223' -Arguments @{ stepNum = "$($c.StepNum)"; breakStatusUrl = "$breakStatusUrl"; markerPath = "$markerPath" })
        } else {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b489eb84ebf27ffb' -Arguments @{ stepNum = "$($c.StepNum)"; markerPath = "$markerPath" })
        }
        & $c.WriteCurrentAction "[$($c.StepNum)/$($c.StepCount)] break (waiting for operator: $markerName)"
        $resumedVia = 'marker-delete'
        # Fixed short poll interval (250 ms) instead of Get-PollDelay's
        # exponential backoff. An operator clicking Continue in the UI
        # expects sub-second feedback; that backoff caps at 59 s after a
        # handful of iterations, so a click could sit unread for nearly a
        # minute. Two Test-Path calls every 250 ms is ~8 file
        # checks/s -- a rounding error on any modern Windows VM. Worst-
        # case latency is one poll interval (~250 ms); average is half.
        $breakPollMs = 250
        # Optional wall-clock bound so an UNATTENDED cycle does not wedge here
        # forever: step.timeoutSeconds, else a global YURUNA_BREAK_MAX_SECONDS,
        # bounds the wait. With neither set the wait is effectively unbounded --
        # the interactive default when an operator is present. On timeout the
        # break auto-resumes IN PLACE (resumedVia='timeout'); the continue-button
        # snapshot-restore path below is intentionally skipped for a timeout.
        # Parse the optional timeout defensively. A bare [int] cast throws on a
        # non-numeric value (e.g. an operator typo like '5m' in the free-text
        # YURUNA_BREAK_MAX_SECONDS, or a bad step.timeoutSeconds the schema does not
        # constrain for break). This handler's dispatch wrapper has a finally but no
        # catch, so an escaping throw would bypass the break's soft/return-$false
        # envelope and abort the cycle -- the opposite of the unattended-wedge guard
        # intended here. Default to 0 (unbounded interactive wait) when unparseable.
        $breakMaxRaw = if ($c.Step.timeoutSeconds) { $c.Step.timeoutSeconds }
        elseif ($env:YURUNA_BREAK_MAX_SECONDS) { $env:YURUNA_BREAK_MAX_SECONDS }
        else { $null }
        $breakMaxSeconds = 0
        if ($null -ne $breakMaxRaw) {
            try { $breakMaxSeconds = [int]$breakMaxRaw }
            catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_87e7326472d5d6bd' -Arguments @{ breakMaxRaw = "$breakMaxRaw" }) }
        }
        $breakDeadlineUtc = if ($breakMaxSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($breakMaxSeconds) } else { $null }
        while ($true) {
            if (Test-Path -LiteralPath $breakContinueFlag) {
                $resumedVia = 'continue-button'
                Remove-Item -LiteralPath $breakContinueFlag -Force -ErrorAction SilentlyContinue
                break
            }
            if (-not (Test-Path -LiteralPath $markerPath)) { break }
            if ($breakDeadlineUtc -and [DateTime]::UtcNow -ge $breakDeadlineUtc) {
                $resumedVia = 'timeout'
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5acc85b3d32caa00' -Arguments @{ breakMaxSeconds = "${breakMaxSeconds}" })
                break
            }
            Start-Sleep -Milliseconds $breakPollMs
        }
        if ($resumedVia -eq 'continue-button') {
            # Default: a plain breakpoint resumes in place -- it never touches the
            # VM, matching the usual breakpoint meaning. Snapshot-restore + VM
            # restart happen ONLY when the step opted in with `restoreOnContinue:
            # true`; the `id` alone is just a label. Marker-file delete also always
            # resumes in place (it never reaches this branch).
            if ($restoreOnContinue) {
                if (-not $breakSnapshotId) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_cf2d092ebde4891f')
                } elseif (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_39a7f1d5a0a2a2b7' -Arguments @{ breakSnapshotId = "$breakSnapshotId" })
                } else {
                    # Probe before restoring: restoreOnContinue with an id that
                    # names no actual snapshot is a no-op resume-in-place, not a
                    # noisy "no checkpoint / continuing anyway" warning every click.
                    $snapPresent = $false
                    if (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue) {
                        try { $snapPresent = [bool](Test-VMDiskSnapshot -VMName $c.VMName -Id $breakSnapshotId) }
                        catch { $null = $_ }
                    }
                    if (-not $snapPresent) {
                        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_92f1247570b3216b' -Arguments @{ breakSnapshotId = "$breakSnapshotId"; vMName = "$($c.VMName)" }) -InformationAction Continue
                    } else {
                        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_62b042de6133ae7f' -Arguments @{ breakSnapshotId = "$breakSnapshotId"; vMName = "$($c.VMName)" }) -InformationAction Continue
                        try {
                            $restored = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $breakSnapshotId -Confirm:$false)
                            if (-not $restored) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_eef349268384cc8a') }
                        } catch {
                            # YurunaCycleRestart is a control-flow marker; re-throw before the
                            # generic handler turns it into "continuing anyway", which would
                            # leave control.cycle-restart unconsumed by the cycle-level catch.
                            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
                            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_13f62b2ffa686ec3' -Arguments @{ message = "$($_.Exception.Message)" })
                        }
                        # Restore-VMDiskSnapshot stops the VM to swap the disk, so
                        # bring it back up. Only needed on this path -- a plain
                        # breakpoint leaves the VM running and must not restart it.
                        if (Get-Command Start-VM -ErrorAction SilentlyContinue) {
                            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_68341a9ddbe34650' -Arguments @{ vMName = "$($c.VMName)" }) -InformationAction Continue
                            try {
                                $startRes = Start-VM -VMName $c.VMName -Confirm:$false
                                if ($startRes -is [hashtable] -and -not $startRes.success) {
                                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_65723f23878cc607' -Arguments @{ errorMessage = "$($startRes.errorMessage)" })
                                }
                            } catch {
                                if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
                                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_10efec7f4ca6c612' -Arguments @{ message = "$($_.Exception.Message)" })
                            }
                        } else {
                            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a6463045311dbeb6')
                        }
                    }
                }
            }
        }
        # Clean the per-step marker + active sidecar however we resumed
        # (continue-button, marker-delete no-op, or timeout) so no stale on-disk
        # break state outlives the pause.
        Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $breakActivePath -Force -ErrorAction SilentlyContinue
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7be731c96153c9cd' -Arguments @{ resumedVia = "$resumedVia" })
        return $true
    }

Register-SequenceAction -Name 'saveDiskSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'hard' -SuggestedRecoveries @('operator_intervention_required') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_aaafb05d4ba418b5') `
    -FailureLabel { param($c) "saveDiskSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_62308c734fb38a09'); return $false }
        if (-not (Get-Command Save-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_61e004dc934546d2')
            return $false
        }
        $manifestExtra = @{}
        if ($c.SnapshotPolicy) {
            try {
                Import-Module (Join-Path $PSScriptRoot 'Test.SnapshotManifest.psm1') -DisableNameChecking -Global
                $manifestExtra = @{
                    managedBaseline = $true
                    sourceIdentity = Get-SnapshotSourceIdentity -RepoRoot $c.RepoRoot -GuestKey $c.GuestKey `
                        -Policy $c.SnapshotPolicy -Variables $c.Vars
                }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_efeaf16e6d9784b0' -Arguments @{ message = "$($_.Exception.Message)" })
                return $false
            }
        }
        Write-Debug "      Saving disk snapshot '$snapId' for $($c.VMName)"
        $ok = $false
        try { $ok = [bool](Save-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch {
            # YurunaCycleRestart is a control-flow marker -- re-throw so
            # the cycle-level handler in Invoke-TestRunnerInnerLoop consumes
            # control.cycle-restart; otherwise the warning + return $false
            # turns the marker into a soft step failure and the flag
            # re-fires on every subsequent sequence.
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            Write-Warning "      saveDiskSnapshot: $($_.Exception.Message)"; return $false
        }
        if ($ok -and $c.VMName -ne $snapId) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7db15dd3eb273c11' -Arguments @{ vMName = "$($c.VMName)"; snapId = "$snapId" }) -InformationAction Continue
            $c.NewVMName = $snapId
        }
        # Manifest sidecar. Written right after the hypervisor
        # confirms the snapshot landed. A future loadDiskSnapshot /
        # recoverFromSnapshot reads this manifest to validate identity
        # before invoking Restore-VMDiskSnapshot. Best-effort: a write
        # failure logs Verbose but does not flunk the snapshot itself
        # (the binary is on disk; missing manifest -> warn-only at
        # restore time).
        if ($ok -and (Get-Command Write-SnapshotManifest -ErrorAction SilentlyContinue)) {
            $effectiveVm = if ($c.NewVMName) { $c.NewVMName } else { $c.VMName }
            $manifestPath = Write-SnapshotManifest -VMName $effectiveVm -SnapshotId $snapId -HostType $c.HostType -Extra $manifestExtra -Confirm:$false
            if ($c.SnapshotPolicy -and -not $manifestPath) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_46640d933a23cb0d')
                return $false
            }
        }
        return $ok
    }

Register-SequenceAction -Name 'loadDiskSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'snapshot_restore_failed' -Severity 'hard' -SuggestedRecoveries @('operator_intervention_required') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_7fd5db2fdbbc0cc5') `
    -FailureLabel { param($c) "loadDiskSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_419f7edb1d5f67bd'); return $false }
        if ($c.SnapshotPolicy) {
            try {
                Import-Module (Join-Path $PSScriptRoot 'Test.SnapshotManifest.psm1') -DisableNameChecking -Global
                $identity = Get-SnapshotSourceIdentity -RepoRoot $c.RepoRoot -GuestKey $c.GuestKey `
                    -Policy $c.SnapshotPolicy -Variables $c.Vars
                $reuse = Test-SnapshotReusePolicy -VMName $c.VMName -SnapshotId $snapId -HostType $c.HostType `
                    -Policy $c.SnapshotPolicy -SourceIdentity $identity
                if ($reuse.Status -ne 'reusable') { throw $reuse.Reason }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5ce198ab0fe7961a' -Arguments @{ message = "$($_.Exception.Message)" })
                return $false
            }
        }
        # A restore boots the guest again, so it goes back for a fresh lease and
        # the address ssh proved a moment ago belongs to the generation being
        # discarded. Forget it here rather than letting the age bound retire it:
        # the bound exists for addresses that MIGHT have moved, and this one
        # certainly has.
        if (Get-Command Clear-ProvenGuestAddress -ErrorAction SilentlyContinue) {
            Clear-ProvenGuestAddress -VMName $c.VMName
        }
        if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_35f52ea8e7416232')
            return $false
        }
        # Pre-validation: confirm the snapshot exists before the restore.
        # Restore-VMDiskSnapshot on a missing snapshot can leave the VM
        # in an ambiguous state on some hypervisors; fail-loud here so
        # the operator sees the missing snapshot directly.
        if (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue) {
            $snapExists = $false
            try { $snapExists = [bool](Test-VMDiskSnapshot -VMName $c.VMName -Id $snapId) }
            catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d18cdfa85cd1558e' -Arguments @{ message = "$($_.Exception.Message)" })
                $snapExists = $true
            }
            if (-not $snapExists) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_27c75a0e1cc7f8d9' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_missing'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'loadDiskSnapshot'
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            }
        }
        # Manifest identity check. The existence check above proves
        # the hypervisor knows the snapshot id; the manifest check proves
        # YURUNA wrote it (vmName + snapshotId + hostType all match what
        # we're about to restore from). A missing manifest is warn-only
        # (snapshots taken before manifests were introduced don't have
        # one); a manifest whose fields disagree with the call is a hard
        # refuse.
        if (Get-Command Test-SnapshotManifestMatch -ErrorAction SilentlyContinue) {
            $check = Test-SnapshotManifestMatch -VMName $c.VMName -SnapshotId $snapId -HostType $c.HostType
            if ($check.Status -eq 'mismatch') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_93d6b96984f8145c' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)"; join = "$($check.Violations -join '; ')" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_manifest_mismatch'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'loadDiskSnapshot'
                    violations   = @($check.Violations)
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            } elseif ($check.Status -eq 'missing') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bb0c0f58e4cfceea' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event      = 'snapshot_manifest_missing'
                    vmName     = [string]$c.VMName
                    snapshotId = [string]$snapId
                    handler    = 'loadDiskSnapshot'
                }
            }
        }
        Write-Debug "      Restoring disk snapshot '$snapId' for $($c.VMName)"
        try { $ok = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch {
            # YurunaCycleRestart is a control-flow marker -- re-throw so
            # the cycle-level handler consumes it; otherwise the warning
            # + return $false turns the marker into a step failure.
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            Write-Warning "      loadDiskSnapshot: $($_.Exception.Message)"; return $false
        }
        if (-not $ok) { return $false }
        if (-not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ebc4e292986adc76' -Arguments @{ vMName = "$($c.VMName)" })
            return $false
        }
        Write-Debug "      Starting $($c.VMName) after snapshot restore"
        try {
            $startRes = Start-VM -VMName $c.VMName -Confirm:$false
            # Take the LAST status record rather than testing $startRes itself.
            # A driver that writes progress to the success stream returns an
            # Object[] with the record at the end, and `$startRes -is
            # [hashtable]` is then false -- which silently skipped this check
            # and let a VM that never started report a restored, running guest.
            # The step passed and the failure surfaced minutes later as an SSH
            # timeout against a powered-off VM.
            $startRec = @($startRes) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
            if (-not $startRec) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_dc191ba5b61b338b' -Arguments @{ vMName = "$($c.VMName)" })
                return $false
            }
            if (-not $startRec.success) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ccabd79caf97eda9' -Arguments @{ errorMessage = "$($startRec.errorMessage)" })
                return $false
            }
        } catch {
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ea69002928c6384f' -Arguments @{ message = "$($_.Exception.Message)" }); return $false
        }
        return $true
    }

Register-SequenceAction -Name 'saveSystemDiagnostic' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'instrumentation_failure' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_9557327232acf7b4') `
    -Handler {
        param([hashtable]$c)
        $c.DiagnosticOutcome = 'unavailable'
        $diagId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $diagId) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c1baf8f3a5c28b39'); return $false }
        if (-not (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
            $logModule = Join-Path $PSScriptRoot 'Test.Log.psm1'
            if (Test-Path $logModule) { Import-Module $logModule -Global -Force -Verbose:$false }
        }
        if (-not (Get-Command Save-GuestDiagnostic -ErrorAction SilentlyContinue)) {
            $diagModule = Join-Path $PSScriptRoot 'Test.Diagnostic.psm1'
            if (Test-Path $diagModule) { Import-Module $diagModule -Global -Force -Verbose:$false }
        }
        $diagFolder = Get-CycleGuestDataFolder -VMName $c.VMName
        if (-not $diagFolder) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_db8440ec21476df1')
            return $true
        }
        Write-Debug "      Capturing diagnostic '$diagId' from $($c.VMName) to $diagFolder"
        $diagManifest = $null
        try {
            $diagManifest = Save-GuestDiagnostic -VMName $c.VMName -GuestKey $c.GuestKey -OutputFolder $diagFolder -Id $diagId `
                -StepInvocationId $c.StepInvocationId -SequenceInvocationId $c.SequenceInvocationId
        }
        catch { Write-Warning "      saveSystemDiagnostic: $($_.Exception.Message)" }
        # Emit one NDJSON line so an autonomous remediator sees the
        # capture outcome (mechanism, attempts, bytes) without parsing
        # the diagnostic file body. Best-effort: Write-CycleNdjsonEvent
        # already self-degrades on failure.
        if ($diagManifest -is [hashtable]) {
            $c.DiagnosticOutcome = [string]$diagManifest.diagnosticOutcome
            Send-CycleEventSafely -EventRecord @{
                timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                event      = 'guest_diagnostic'
                diagId     = [string]$diagId
                vmName     = [string]$c.VMName
                guestKey   = [string]$c.GuestKey
                success    = [bool]$diagManifest.success
                mechanism  = [string]$diagManifest.mechanism
                attempted  = @($diagManifest.attempted)
                exitCode   = [int]$diagManifest.exitCode
                bytes      = [long]$diagManifest.bytes
                skipped    = [bool]$diagManifest.skipped
                reason     = [string]$diagManifest.reason
                outPath    = [string]$diagManifest.outPath
                diagnosticOutcome = [string]$diagManifest.diagnosticOutcome
                stepInvocationId = [string]$c.StepInvocationId
                sequenceInvocationId = [string]$c.SequenceInvocationId
                hostSnapshot = $diagManifest.hostSnapshot
                guestSnapshot = $diagManifest.guestSnapshot
            }
        }
        return $true
    }

Register-SequenceAction -Name 'callExtension' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'extension_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_9803b4c05c2239fd') `
    -Handler {
        param([hashtable]$c)
        $methodFqn = [string]$c.Step.method
        if (-not $methodFqn -or $methodFqn -notmatch '^([A-Za-z0-9_]+)\.([A-Za-z][A-Za-z0-9_-]*)$') {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_6f99aa1ba9ef5572' -Arguments @{ methodFqn = "$methodFqn" })
        }
        $callArea   = $matches[1]
        $callMethod = $matches[2]
        $resolvedArgs = @{}
        if ($c.Step.args) {
            foreach ($argKey in $c.Step.args.Keys) {
                $val = $c.Step.args[$argKey]
                if ($val -is [string]) { $val = & $c.ExpandVariable $val $c.Vars }
                $resolvedArgs[$argKey] = $val
            }
        }
        $loaderPath = Join-Path $PSScriptRoot 'Test.Extension.psm1'
        if (Test-Path $loaderPath) { Import-Module $loaderPath -Global -Force -Verbose:$false }
        $extName = (@(Get-ActiveExtensionName -Area $callArea))[0]
        [void](Import-Extension -Area $callArea)
        $cmd = Resolve-ExtensionMethod -Area $callArea -ExtensionName $extName -Method $callMethod
        Write-Debug "      callExtension: $callArea/$extName.$callMethod ($($resolvedArgs.Keys -join ', '))"
        try { & $cmd @resolvedArgs; return $true }
        catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_784ff212589ae772' -Arguments @{ callArea = "$callArea"; callMethod = "$callMethod"; message = "$($_.Exception.Message)" }); return $false }
    }

Register-SequenceAction -Name 'inputText' -HostIORequirement @('Send-Text') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_121cac02691001a9') `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' (charDelay=${charDelay}ms)"
        return [bool](Test.SequenceEngine\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape)
    }

Register-SequenceAction -Name 'inputTextAndEnter' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
    -Aliases @('typeAndEnter') `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_dd0c755911af00a8') `
    -FailureLabel { param($c) [string]$c.Step.action } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'inputTextAndEnter' -ShellEscape)
    }

Register-SequenceAction -Name 'networkRelease' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_806d3ca199c6f400') `
    -FailureLabel { param($c) "networkRelease: $($c.GuestKey)" } `
    -Handler {
        param([hashtable]$c)
        $guest = [string]$c.GuestKey
        # Ubuntu + Amazon Linux: type the release command on the guest console.
        # yuruna-network.sh is baked into the image at install time; the
        # `release` verb dispatches to network_release(), which sends a
        # DHCPRELEASE so the lease returns to the pool instead of lingering
        # until expiry. gui mode types the path; the future SSH variant will
        # connect and send the same command.
        if ($guest -match 'ubuntu|amazon') {
            $cmd = $c.Step.text `
                ? (& $c.ExpandVariable $c.Step.text $c.Vars) `
                : 'bash /usr/local/lib/yuruna/yuruna-network.sh release'
            $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
            Write-Debug "      networkRelease: typing '$cmd' + Enter"
            $ok = Test.SequenceEngine\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $cmd -CharDelayMs $charDelay -ShellEscape
            if ($ok -eq $false) { return $false }
            Start-Sleep -Milliseconds 800
            return [bool](Test.SequenceEngine\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter')
        }
        # Windows guests have no release path yet: the equivalent
        # (`ipconfig /release`) is unwired, so this stays a warned no-op.
        if ($guest -match 'windows') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4389a1023dafba93' -Arguments @{ guest = "$guest" })
            return $true
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b4808071c6833947' -Arguments @{ guest = "$guest" })
        return $true
    }

Register-SequenceAction -Name 'waitForText' -HostIORequirement @() -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -UsesWaitSignals $true -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_e13f26910245761c') `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "waitForText: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($p.fresh) { ', freshMatch' })$(if ($p.sinceStepStart) { ', sinceStepStart' })$(if ($p.failurePatterns.Count) { ", $($p.failurePatterns.Count) failurePatterns" }))"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -FailurePattern $p.failurePatterns)
    }

Register-SequenceAction -Name 'waitForTextWithNudge' -HostIORequirement @('Send-Key') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -UsesWaitSignals $true -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_aedd181e3f9cf9c0') `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "waitForTextWithNudge: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $nudgeKey = [string]$c.Step.nudgeKey
        $nudgeInterval = $c.Step.nudgeIntervalSeconds ? [int]$c.Step.nudgeIntervalSeconds : 0
        if ([string]::IsNullOrWhiteSpace($nudgeKey) -or $nudgeInterval -lt 1) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c6fe2ea8991642c6')
            return $false
        }
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s, nudge '$nudgeKey' every ${nudgeInterval}s$(if ($p.fresh) { ', freshMatch' })$(if ($p.sinceStepStart) { ', sinceStepStart' })$(if ($p.failurePatterns.Count) { ", $($p.failurePatterns.Count) failurePatterns" }))"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -FailurePattern $p.failurePatterns `
            -NudgeKey $nudgeKey -NudgeIntervalSeconds $nudgeInterval)
    }

Register-SequenceAction -Name 'waitForAndEnter' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -UsesWaitSignals $true -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_64d18932f8504050') `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "waitForAndEnter: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        $blindAfter = $c.Step.blindAfterSeconds ? [int]$c.Step.blindAfterSeconds : 0
        # blindAfterSeconds splits the budget: the first window is an ordinary
        # wait, and what it leaves behind decides whether the answer is worth
        # sending to a screen the pattern cannot be read off. A value that does
        # not leave a second window is the same as no value at all.
        $useBlind = ($blindAfter -gt 0 -and $blindAfter -lt $p.timeout)
        $firstWindow = $useBlind ? $blindAfter : $p.timeout
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($useBlind) { ", blind answer after ${blindAfter}s" }))"
        $waitStartUtc = [DateTime]::UtcNow
        $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $firstWindow -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -FailurePattern $p.failurePatterns
        # A wait that stopped on one of its own failurePatterns read the console
        # and found a screen the step declared wrong. That is the one $false the
        # blind path must not act on: it is evidence about the screen, not the
        # absence of evidence the blind answer exists to cover.
        $matchedFailure = $null
        if (Get-Command Get-SequenceFailureState -ErrorAction SilentlyContinue) {
            $matchedFailure = (Get-SequenceFailureState).WaitForTextMatchedFailurePattern
        }
        if ($ok -eq $false -and $useBlind -and -not $matchedFailure) {
            if (Invoke-BlindAnswer -Context $c -Patterns $p.patterns) { return $true }
            # The answer either was not warranted or did not land. Spend what is
            # left of the configured budget on the wait that was asked for, so a
            # guest that was merely slow still gets the time the step allows.
            # A resumed wait takes its own since-start baseline: by now the text
            # the first window looked at is screen this step arrived to rather
            # than screen it provoked, so the narrowing keeps meaning what it
            # says -- only what the guest prints from here on can match.
            $remaining = $p.timeout - [int]([DateTime]::UtcNow - $waitStartUtc).TotalSeconds
            if ($remaining -gt 0) {
                Write-Debug "      Resuming the wait for '$patternDisplay' (${remaining}s left of $($p.timeout)s)"
                $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
                    -TimeoutSeconds $remaining -PollSeconds $p.poll -FreshMatch $p.fresh `
                    -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
                    -FailurePattern $p.failurePatterns
            }
        }
        if ($ok -eq $false) { return $false }
        Send-TabNavigation -Context $c
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'waitForAndEnter' -ShellEscape)
    }

Register-SequenceAction -Name 'passwdPrompt' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'credential_expired' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -UsesWaitSignals $true -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_a581e70e444c9b39') `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "passwdPrompt: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($p.sinceStepStart) { ', sinceStepStart' }))"
        $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -FailurePattern $p.failurePatterns
        if ($ok -eq $false) { return $false }
        Send-TabNavigation -Context $c
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = $c.ShowSensitive ? $text : '***'
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'passwdPrompt')
    }

Register-SequenceAction -Name 'tapOn' -HostIORequirement @('Send-Click') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_93d8c93707d2b133') `
    -Handler {
        param([hashtable]$c)
        $rawLabels = $c.Step.label
        [string[]]$labels = if ($rawLabels -is [System.Collections.IEnumerable] -and $rawLabels -isnot [string]) {
            $rawLabels | ForEach-Object { & $c.ExpandVariable $_ $c.Vars }
        } else { @(& $c.ExpandVariable $rawLabels $c.Vars) }
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        $offX    = $c.Step.offsetX        ? [int]$c.Step.offsetX        : 0
        $offY    = $c.Step.offsetY        ? [int]$c.Step.offsetY        : 0
        $labelDisplay = $labels -join "' | '"
        Write-Debug "      Waiting for button '$labelDisplay' (timeout: ${timeout}s)"
        return [bool](Invoke-TapOn -HostType $c.HostType -VMName $c.VMName -Label $labels `
            -TimeoutSeconds $timeout -PollSeconds $poll -OffsetX $offX -OffsetY $offY)
    }

Register-SequenceAction -Name 'takeScreenshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'instrumentation_failure' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_5c7b9da45b618812') `
    -Handler {
        param([hashtable]$c)
        $label = $c.Step.label ?? "step$($c.StepNum)"
        Save-DebugScreenshot -VMName $c.VMName -Label $label -OutputDir $c.ScreenshotDir | Out-Null
        return $true
    }

function Get-FetchExecutionCommand {
    <#
    .SYNOPSIS
        Applies the environment to the whole command, including compound shell input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$CommandLine, [string]$EnvPrefix)
    $quote = [string][char]39
    $escapedQuote = $quote + [char]34 + $quote + [char]34 + $quote
    return $EnvPrefix + 'bash -c ' + $quote + $CommandLine.Replace($quote,$escapedQuote) + $quote
}

function Get-FetchObservationEnvPrefix {
    <#
    .SYNOPSIS
        Arms command traces and identifies the invocation across both transports.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $prefix = if ($Context.Step.sensitive) { 'EXEC_PROFILE=0 EXEC_KEEP_PROFILE=0 ' } else { 'EXEC_KEEP_PROFILE=1 ' }
    foreach ($entry in @(@('E_SI',$Context.StepInvocationId), @('E_QI',$Context.SequenceInvocationId))) {
        if ($entry[1] -match '^[A-Za-z0-9-]{1,64}$') { $prefix += "$($entry[0])=$($entry[1]) " }
    }
    return $prefix
}

function Get-GuiFetchExecutionInput {
    <#
    .SYNOPSIS
        Stages an over-budget GUI command in bounded, verified shell input lines.
    .DESCRIPTION
        The open subshell defers all execution until its final closing line.
        Its temporary variable stays local, and the complete command's digest
        must match before eval. Existing guest bash and sha256sum are sufficient.
    #>
    [CmdletBinding()]
    [OutputType([string], [string[]])]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [ValidateRange(240,400)][int]$MaxTypedChars = 400
    )
    if ($CommandLine.Length -le $MaxTypedChars) { return $CommandLine }
    $quote = [string][char]39
    $escapedQuote = $quote + [char]34 + $quote + [char]34 + $quote
    $lines = [System.Collections.Generic.List[string]]::new()
    $prefix = '(unset __y;__y='
    $chunk = ''
    # Count the quoted representation, including apostrophe expansion, rather
    # than the raw substring. Keep headroom below the transport's 400-char cap.
    $chunkBudget = 240
    foreach ($character in $CommandLine.ToCharArray()) {
        $encoded = if ([string]$character -eq $quote) { $escapedQuote } else { [string]$character }
        if ($prefix.Length + $chunk.Length + $encoded.Length + 2 -gt $chunkBudget) {
            $lines.Add($prefix + $quote + $chunk + $quote)
            $prefix = '__y+='
            $chunk = ''
        }
        $chunk += $encoded
    }
    if ($chunk.Length) { $lines.Add($prefix + $quote + $chunk + $quote) }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = [BitConverter]::ToString($sha256.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($CommandLine))).Replace('-', '').ToLowerInvariant()
    } finally { $sha256.Dispose() }
    # Encode the whole sentinel: even a nearly matching visible string can
    # trigger the existing fuzzy OCR failure monitor while the command echoes.
    $sentinelFormat = -join @($script:NonzeroScriptExitSentinel.ToCharArray() | ForEach-Object {
        '\' + [Convert]::ToString([int]$_, 8).PadLeft(3, '0')
    })
    $guard = 'if [ "$(printf %s "$__y"|sha256sum)" = ' + $quote + $digest + '  -' + $quote +
        ' ];then eval "$__y";else printf ' + $quote + $sentinelFormat +
        ' GUI command integrity mismatch\n' + $quote + ';exit 125;fi)'
    if ($guard.Length -gt $MaxTypedChars) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_31cfbd18727596c9') }
    $lines.Add($guard)
    return $lines.ToArray()
}

function Save-FetchExecutionEvidence {
    <#
    .SYNOPSIS
        Collects slow or failed invocation traces while their log still exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [bool]$Succeeded,
        [double]$ElapsedSeconds
    )
    if ($Context.Step.sensitive) { return }
    if ($Succeeded -and $ElapsedSeconds -lt 60) { return }
    $sourceId = if ($Context.CheckpointSourceStepInvocationId) { $Context.CheckpointSourceStepInvocationId } else { $Context.StepInvocationId }
    if ($sourceId -notmatch '^[A-Za-z0-9-]{1,64}$') { return }
    $captureClock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not (Get-Command Save-GuestExecutionProfile -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Global -ErrorAction Stop
        }
        $folder = Get-CycleGuestDataFolder -VMName $Context.VMName
        if (-not $folder) { return }
        $Context.ExecutionProfile = Save-GuestExecutionProfile -VMName $Context.VMName -GuestKey $Context.GuestKey `
            -OutputFolder $folder -StepInvocationId $sourceId -TimeoutSeconds 20 -Variables $Context.Vars
    } catch { Write-Verbose "Execution profile capture unavailable: $($_.Exception.Message)" }
    finally { $Context.EvidenceCaptureDurationMs = [long]$captureClock.Elapsed.TotalMilliseconds }
}

function Get-FetchExecuteEnvPrefix {
    <#
    .SYNOPSIS
        Build an "E_SHA=<hex> E_RETRY_SHA=<hex> " env prefix for a
        fetch-and-execute.sh invocation so the guest can verify the fetched
        bytes before running them.
    .DESCRIPTION
        The host hashes the working-tree copy of the script the guest is about
        to fetch and passes that digest over the trusted channel that TYPES the
        command (SSH / VM console) -- not over the HTTP the guest fetches over.
        The guest refuses to run bytes that do not match. That closes the
        on-path network-MITM (ARP/DHCP/rogue-responder) and moving-`main`
        GitHub-fallback RCE class: neither controls the typing channel, so
        neither can forge bytes matching a digest they never saw. A host-local
        compromise is out of scope (it controls both the digest and the bytes).
        For any matched fetch-and-execute command it also sets
        EXEC_REQUIRE_SHA256=1, so if the target file cannot be hashed here (a
        served-root/working-tree drift or a bad path) the guest fails CLOSED
        rather than running unverified. Every character of this prefix is an
        individual key event on the console path, so the value-carrying names
        are terse (E_SHA, E_RETRY_SHA, E_FB_REPO, E_FB_REF) and the fallback
        commit is abbreviated; see the typed-envelope definition linked below.
        Returns '' only when the command is not
        a fetch-and-execute invocation (or, defensively, when RepoRoot is unset
        -- a code regression, not a runtime state), preserving rollout-compat.
    #>
    param([string]$CommandLine, [string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $m = [regex]::Match($CommandLine, 'fetch-and-execute\.sh\s+(\S+)')
    if (-not $m.Success) { return '' }
    # Without the served base we cannot compute a digest. Only reachable via a
    # code regression (the engine always threads RepoRoot), so degrade to the
    # guest's rollout-compat path rather than break every guest at once.
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return '' }
    # Matched a fetch-and-execute invocation on the automated path: ENFORCE. The
    # guest refuses if it does not also receive a matching E_SHA, so a
    # served-root/working-tree drift or a bad path fails closed, not open.
    #
    # --- REGION: https://yuruna.link/42fa6f45-0005
    # This one name is NOT shortened, and that is the point: a guest imaged
    # before the rename knows only the EXEC_* spellings, so it would ignore a
    # short-named digest and run the bytes UNVERIFIED. Seeing this flag with no
    # digest it recognizes, it refuses instead -- the rename fails closed on an
    # old guest, loudly, rather than silently reopening the fetch-to-bash hole.
    $prefix = 'EXEC_REQUIRE_SHA256=1 '
    $rel = ($m.Groups[1].Value -split '\?', 2)[0]
    if ([string]::IsNullOrWhiteSpace($rel) -or $rel -match '\.\.[\\/]' -or [System.IO.Path]::IsPathRooted($rel)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_00403c4aae99968d' -Arguments @{ rel = "$rel" })
        return $prefix
    }
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6603f9463ffd92bc' -Arguments @{ rel = "$rel" })
        return $prefix
    }
    $prefix += "E_SHA=$((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()) "
    # fetch-and-execute.sh self-heals the retry lib over the same channel; give
    # the guest that digest too so its sudo-installed copy is verified as well.
    $retryLib = Join-Path $RepoRoot 'automation/yuruna-retry.sh'
    if (Test-Path -LiteralPath $retryLib -PathType Leaf) {
        $prefix += "E_RETRY_SHA=$((Get-FileHash -LiteralPath $retryLib -Algorithm SHA256).Hash.ToLower()) "
    }

    # Where the guest should fetch from if it cannot reach this host: THIS
    # repository, at the commit whose bytes the digest above was taken from.
    # Typed per step rather than baked at New-VM time, so a guest provisioned
    # days ago still falls back to the commit being served right now.
    #
    # GH_TOKEN is deliberately NOT typed. This command line is rendered on the VM
    # console, which the host screenshots and OCRs into the run log published by
    # the status service -- a token typed here would be readable in
    # failure_screenshot.png and failure_ocr.txt. The guest gets it from the
    # cloud-init seed instead, which never leaves the VM.
    $source = Get-YurunaGitHubSource -RepoRoot $RepoRoot
    if ($source.Repo -and $source.Ref) {
        # 12 hex characters of the commit, not 40: both fallback routes
        # (raw.githubusercontent.com/<repo>/<ref>/<path> and the Contents API's
        # ?ref=) resolve an abbreviated sha, and 48 bits is far past ambiguity
        # for any repository this framework serves. Saves 28 keystrokes per
        # step on a console path that corrupts long sends. The digest, not the
        # ref, is what actually pins the bytes.
        $shortRef = $source.Ref.Substring(0, [math]::Min(12, $source.Ref.Length))
        $prefix += "E_FB_REPO=$($source.Repo) E_FB_REF=$shortRef "
        # The digest covers the WORKING TREE copy, but the fallback fetches the
        # commit. When they differ, the fallback can only fetch bytes that fail
        # the integrity gate -- so if the host is also unreachable, the run dies
        # on an "INTEGRITY MISMATCH" whose real cause is this uncommitted edit.
        # Say it here, where it is still cheap to act on.
        if (-not (Test-YurunaFileMatchesHead -RepoRoot $RepoRoot -RelativePath $rel)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d9b7f7780d748cd8' -Arguments @{ rel = "$rel" })
        }
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f1e69844d12e14d2' -Arguments @{ repoRoot = "$RepoRoot" })
    }
    return $prefix
}

# The registered class is the DEFAULT -- what this verb failed as when no
# failPattern matched. That is the completion marker never arriving, i.e. a
# wait_timeout; the fetched script hanging on a stalled package mirror is the
# common cause. Registering 'pattern_matched_failure' here asserted the
# opposite: that the wrapper printed its failure tag. Nothing re-checked it,
# so a plain timeout was reported as a script-reported failure, routed to
# pause_and_inspect ("auto-retry would just re-trigger it") and excluded from
# warm resume -- turning a transient upstream stall into a dead cycle needing
# an operator. Build-SequenceFailureRecord still reclassifies to
# pattern_matched_failure when a pattern actually matched, so that case keeps
# its own label and its no-retry routing.
Register-SequenceAction -Name 'fetchAndExecute' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'wait_timeout' -Severity 'hard' -SuggestedRecoveries @('retry_with_backoff','pause_and_inspect') `
    -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_d1d328d999fc31cf') `
    -FailureLabel { param($c) "fetchAndExecute: `"$(& $c.ExpandVariable $c.Step.text $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $envPrefix  = (Get-FetchObservationEnvPrefix -Context $c) + (Get-FetchExecuteEnvPrefix -CommandLine $text -RepoRoot $c.RepoRoot)
        $executionClock = [System.Diagnostics.Stopwatch]::StartNew()
        $executionSucceeded = $false
        try {
        $payloadLen = $text.Length
        $text = Get-FetchExecutionCommand -CommandLine $text -EnvPrefix $envPrefix
        $typedCommands = @($text)
        if ($c.HostType -eq 'host.macos.utm' -and $text.Length -gt $script:FetchExecuteTypedCharWarn) {
            $typedCommands = @(Get-GuiFetchExecutionInput -CommandLine $text -MaxTypedChars $script:FetchExecuteTypedCharWarn)
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0ed289c55b84fcb5' -Arguments @{ length = "$($text.Length)"; count = "$($typedCommands.Count)" })
        }
        # Typed one key event per character; see $script:FetchExecuteTypedCharWarn
        # for why length matters and why the prefix counts against the budget.
        if ($typedCommands.Count -eq 1 -and $text.Length -gt $script:FetchExecuteTypedCharWarn) {
            Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_51bc77d2f69ec90e' -Arguments @{ length = "$($text.Length)"; length2 = "$($envPrefix.Length)"; payloadLen = "$payloadLen"; fetchExecuteTypedCharWarn = "$($script:FetchExecuteTypedCharWarn)" }))
        }
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        if (-not $c.Step.sensitive) { Write-Debug "      fetchAndExecute: command '$text'" }
        foreach ($typedCommand in $typedCommands) {
            # The CGEvent fallback's ShellEscape wrapper evaluates each input
            # independently. Continuation lines must reach the shell literally.
            if (-not (Invoke-TypeDrainEnter -Context $c -Text $typedCommand -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'fetchAndExecute' -ShellEscape:($typedCommands.Count -eq 1))) { return $false }
        }
        $waitPattern = & $c.ExpandVariable $c.Step.waitPattern $c.Vars
        if ([string]::IsNullOrWhiteSpace($waitPattern)) {
            # fetchAndExecute REQUIRES a waitPattern (the completion marker). An empty/missing one
            # makes Wait-ForText poll @('') -- which either "matches" any frame (false pass) or
            # burns the full timeout. Fail fast with a clear message instead.
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_64c3f8a2035c9363')
            return $false
        }
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        $failPatterns = @()
        $rawFail = $c.Step.failurePatterns
        if ($null -ne $rawFail) {
            # Same string-or-array shape every other pattern-bearing verb
            # accepts, so `failurePatterns` means one thing across the schema
            # rather than one thing here and another everywhere else.
            $failPatterns = if ($rawFail -is [System.Collections.IEnumerable] -and $rawFail -isnot [string]) {
                @($rawFail | ForEach-Object { & $c.ExpandVariable $_ $c.Vars })
            } else {
                @(& $c.ExpandVariable $rawFail $c.Vars)
            }
        } else {
            # This IS the fetchAndExecute action, so its fetch-and-execute
            # contract (automation/fetch-and-execute.sh) always applies: the
            # wrapper prints "NONZERO SCRIPT EXIT:" on a non-zero child exit.
            # Derive the fast-fail from the ACTION, never from the literal
            # waitPattern text -- keying it off the waitPattern (e.g. matching
            # "FETCHED AND EXECUTED:") silently disabled this seconds-fast crash
            # detection the moment anyone decorated or reworded the human-facing
            # completion marker, leaving a crashed fetch to burn the full timeout.
            # The marker deliberately avoids the words "fetch"/"execute"
            # (Test-OCRMatch is fuzzy and would otherwise match the echoed
            # 'fetch-and-execute.sh ...' command line on the first poll and fail
            # a healthy run in ~4 s); "NONZERO" cannot collide with a command or
            # normal script output. A step can still override via failurePatterns.
            $failPatterns = @($script:NonzeroScriptExitSentinel)
        }
        # The window is the ONLY thing keeping a marker printed by an EARLIER
        # fetchAndExecute from satisfying this one: freshMatch here is a tail
        # restriction and nothing else -- it does not first require the pattern
        # to clear -- and sequences reuse one generic completion marker for
        # every step. So the window cannot simply be opened up: past the point
        # where the previous step's marker is still inside it, a step that never
        # ran reports success, which is worse than the failure widening it
        # would prevent.
        #
        # It cannot stay at the waitForText default either. Anything the guest
        # emits after the marker -- a console repaint, a completion listing, a
        # late daemon line -- pushes it out and fails a run that SUCCEEDED, and
        # the replay that follows re-runs work that already landed. A modest
        # default absorbs an extra repaint; a sequence that clears the screen
        # before this step has nothing stale to confuse and can safely raise
        # freshMatchTailLines as far as its own output needs. The near-miss
        # report at the wait's timeout names that knob and the value to use.
        $tailLines = $c.Step.freshMatchTailLines ? [int]$c.Step.freshMatchTailLines : 24
        # The shell-rejection set is NOT part of $failPatterns and is not
        # overridable with them: those describe how this step's PAYLOAD fails,
        # and a step that wants to say something about its own script has no
        # reason to also give up the harness reading whether the command line
        # was accepted at all.
        Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${timeout}s, freshMatch, tail ${tailLines} lines); failurePatterns=$($failPatterns -join ', '); shell-rejection window=${script:ShellRejectionWindowSeconds}s"
        $executionSucceeded = [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern @($waitPattern) `
            -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $true `
            -FreshMatchTailLines $tailLines -FailurePattern $failPatterns `
            -EarlyFailurePattern $script:ShellRejectedCommandPattern `
            -EarlyFailureSeconds $script:ShellRejectionWindowSeconds)
        return $executionSucceeded
        } finally {
            Save-FetchExecutionEvidence -Context $c -Succeeded $executionSucceeded -ElapsedSeconds $executionClock.Elapsed.TotalSeconds
        }
    }

Register-SequenceAction -Name 'sshWaitReady' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'network_timeout' -Severity 'soft' -SuggestedRecoveries @('retry_with_backoff','restart_from_snapshot') `
    -UsesWaitSignals $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_241d50d60bce8e27') `
    -Handler {
        param([hashtable]$c)
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds

        # Optional OCR-based fast-fail: when `installerFailurePatterns` is
        # set, periodically screen-OCR the guest while waiting for SSH and
        # short-circuit if any pattern matches. Targets subiquity's
        # "install_fail.crash" / "Press enter to start a shell" output --
        # without this, a crashed install only surfaces after the full
        # timeoutSeconds (~40 min on the Ubuntu Server sequences) because
        # sshd never comes up to satisfy Wait-SshReady. Pairs with the
        # yuruna_retry exp-backoff auto-retry in Invoke-TestRunnerInnerLoop so
        # a transient installer flake is recovered on the next cycle.
        [string[]]$installerFailPatterns = @()
        if ($null -ne $c.Step.installerFailurePatterns) {
            $rawIfp = $c.Step.installerFailurePatterns
            if ($rawIfp -is [System.Collections.IEnumerable] -and $rawIfp -isnot [string]) {
                $installerFailPatterns = @($rawIfp | ForEach-Object { & $c.ExpandVariable $_ $c.Vars } | Where-Object { $_ })
            } else {
                $installerFailPatterns = @((& $c.ExpandVariable $rawIfp $c.Vars)) | Where-Object { $_ }
            }
        }

        if ($installerFailPatterns.Count -eq 0) {
            # Fast path: no OCR scan requested -- preserve the original
            # single-shot Wait-SshReady contract for callers that don't
            # need installer-fail detection (most non-Ubuntu-server flows).
            Write-Debug "      sshWaitReady: $($c.GuestKey)@$($c.VMName) (timeout: ${timeout}s)"
            return [bool](Wait-SshReady -VMName $c.VMName -GuestKey $c.GuestKey -TimeoutSeconds $timeout -PollSeconds $poll)
        }

        # Slow path: chunked SSH wait + OCR scan between chunks. Reset the
        # cross-function signals so a prior step can't leak into this step's
        # failure label (same contract as Wait-ForText). The cause slots are
        # populated ONLY at the failure branch below, so a successful wait leaves
        # them empty and cannot leak its sought-pattern set forward.
        $script:Fail.WaitForTextMatchedFailurePattern = $null
        $script:Fail.WaitForTextOcrTail        = $null
        $script:Fail.WaitForTextPatternsSought = [string[]]@()
        $script:Fail.WaitForTextFreshWindowNearMiss = [string[]]@()
        # No closest-line scan on this path at all, so $null rather than an
        # empty list, which would credit the record with a reading of the screen.
        $script:Fail.WaitForTextClosestOnScreen = $null

        # Test.OcrEngine + Test.YurunaDir + Test.Log live alongside this
        # module; Import-Module -Force is cheap once warm. -Global on all
        # three is load-bearing: a nested -Force WITHOUT -Global evicts the
        # module from the parent (global) session. Test-CombinedOcrMatch
        # (Test.OcrMatch module, called below) resolves Get-EnabledOcrProvider
        # / Invoke-OcrProvider through global, so evicting Test.OcrEngine here
        # crashes the OCR scan (the module-eviction regression class,
        # feedback_module_force_import_evicts_global.md).
        Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1')       -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

        $logDir     = Initialize-YurunaLogDir
        $screensDir = Get-CycleScreenDir -VMName $c.VMName -WhatIf:$false

        # Chunk size balances detection lag (smaller = faster fail) against
        # OCR cost (~50-200 ms per scan on a typical host). 15 s gives
        # subiquity ~1-2 frames of "install_fail.crash" output between
        # checks while still keeping wall-clock detection under 30 s.
        $chunkSeconds = 15
        $deadlineUtc  = [DateTime]::UtcNow.AddSeconds($timeout)

        Write-Debug "      sshWaitReady: $($c.GuestKey)@$($c.VMName) (timeout: ${timeout}s, installerFailurePatterns=[$($installerFailPatterns -join ', ')], chunk=${chunkSeconds}s)"

        while ([DateTime]::UtcNow -lt $deadlineUtc) {
            $remainingSeconds = [int]($deadlineUtc - [DateTime]::UtcNow).TotalSeconds
            if ($remainingSeconds -le 0) { break }
            $thisChunk = [Math]::Min($chunkSeconds, $remainingSeconds)
            if (Wait-SshReady -VMName $c.VMName -GuestKey $c.GuestKey -TimeoutSeconds $thisChunk -PollSeconds $poll) {
                return $true
            }
            # SSH still not up -- OCR-scan one frame for installer-fail signatures.
            $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $rawScreenPath = Join-Path $screensDir "raw_${stamp}.png"
            $captured = Get-VMScreenshot -VMName $c.VMName -OutFile $rawScreenPath
            if (-not $captured -or -not (Test-Path $rawScreenPath)) { continue }

            $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $installerFailPatterns
            if ($result.AnyText) {
                $ocrSections = [System.Collections.Generic.List[string]]::new()
                foreach ($eName in $result.EngineResults.Keys) {
                    $er = $result.EngineResults[$eName]
                    $status = $er.Matched ? "MATCH '$($er.MatchedPattern)'" : "no match"
                    $ocrSections.Add("== $eName ($status) ==")
                    $ocrSections.Add($er.Text)
                    $ocrSections.Add('')
                }
                Save-OcrSidecar -ScreenshotPath $rawScreenPath -Sections $ocrSections
            }
            if (-not $result.Match) { continue }

            $matchedPattern = $null
            foreach ($eName in $result.EngineResults.Keys) {
                $er = $result.EngineResults[$eName]
                if ($er.Matched -and $er.MatchedPattern) { $matchedPattern = $er.MatchedPattern; break }
            }
            if (-not $matchedPattern) { $matchedPattern = $installerFailPatterns[0] }
            $script:Fail.WaitForTextMatchedFailurePattern = $matchedPattern
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5eefabfaa35c260f' -Arguments @{ matchedPattern = "$matchedPattern" })
            $failScreenPath = Join-Path $logDir "failure_screenshot_$($c.VMName).png"
            Copy-Item -Path $rawScreenPath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b24a2d8bfa724905' -Arguments @{ failScreenPath = "$failScreenPath"; screensDir = "$screensDir" })
            if ($result.AnyText) {
                $failOcrPath = Join-Path $logDir "failure_ocr_$($c.VMName).txt"
                Set-Content -Path $failOcrPath -Value $result.AnyText -Force -ErrorAction SilentlyContinue
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ae9f061222f374f7' -Arguments @{ failOcrPath = "$failOcrPath" })
                # Bounded tail + the sought patterns into causeDetail (set on
                # failure only, so a successful wait can't leak them).
                $script:Fail.WaitForTextOcrTail = if ($result.AnyText.Length -le 1200) { $result.AnyText } else { $result.AnyText.Substring($result.AnyText.Length - 1200) }
                $script:Fail.WaitForTextPatternsSought = [string[]]@($installerFailPatterns)
            }
            return $false
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bd38b0b11908de53' -Arguments @{ timeout = "${timeout}" })
        return $false
    }

function Publish-GuestRetryMarker {
    <#
    .SYNOPSIS
        Parse YURUNA_RETRY {json} markers out of captured guest SSH output and
        re-emit each as a retry_attempt NDJSON event, so guest-side retries on the
        SSH path become queryable in the cycle stream (the bash lib emits the
        markers but cannot reach the host stream itself). Best-effort; a malformed
        marker line is skipped.
    .OUTPUTS
        [int] the number of markers published.
    #>
    [OutputType([int])]
    param(
        [AllowNull()]$Output,
        [string]$GuestKey,
        [string]$VmName
    )
    if ($null -eq $Output) { return 0 }
    if (-not (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue)) { return 0 }
    $text  = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
    $count = 0
    foreach ($line in ($text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*YURUNA_RETRY\s+(\{.*\})\s*$')
        if (-not $m.Success) { continue }
        try { $obj = $m.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $rec = @{
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event     = 'retry_attempt'
            stack     = 'bash'
        }
        if ($obj.label)                 { $rec['description'] = [string]$obj.label }
        if ($null -ne $obj.attempt)     { $rec['attempt']     = [int]$obj.attempt }
        if ($null -ne $obj.maxAttempts) { $rec['maxAttempts'] = [int]$obj.maxAttempts }
        if ($null -ne $obj.rc)          { $rec['exitCode']    = [int]$obj.rc }
        if ($null -ne $obj.permanent)   { $rec['permanent']   = [bool]$obj.permanent }
        if ($GuestKey) { $rec['guestKey'] = [string]$GuestKey }
        if ($VmName)   { $rec['vmName']   = [string]$VmName }
        Send-CycleEventSafely -EventRecord ([hashtable]$rec)
        $count++
    }
    return $count
}

Register-SequenceAction -Name 'sshExec' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_84d963e1b876d615') `
    -FailureLabel { param($c) "sshExec: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $cmd     = & $c.ExpandVariable $c.Step.command $c.Vars
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $masked  = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $cmd
        Write-Debug "      sshExec: $masked"
        # Cleared before the attempt, set only on the unresolved-address failure
        # below, so a successful step never leaves the signal behind for a later
        # step's failure record to pick up.
        $script:Fail.StepGuestAddressUnresolved = $null
        $script:Fail.StepGuestTransportLost     = $null
        # No reconnect by default: this verb runs whatever command the YAML
        # names, and a dropped transport leaves it unknown whether that command
        # already ran. A step whose command is safe to repeat opts in with
        # `transportRetries:`.
        $transportRetries = $null -ne $c.Step.transportRetries ? [int]$c.Step.transportRetries : 0
        $result  = Invoke-GuestSsh -VMName $c.VMName -GuestKey $c.GuestKey -Command $cmd -TimeoutSeconds $timeout -TransportRetryCount $transportRetries
        Write-Debug "      sshExec output: $($result.output)"
        [void](Publish-GuestRetryMarker -Output $result.output -GuestKey $c.GuestKey -VmName $c.VMName)
        if (-not $result.success) {
            if ($c.Step.allowFailure -eq $true) {
                Write-Debug "      sshExec exit=$($result.exitCode) (allowFailure=true)"
                return $true
            }
            if (-not $result.addressResolved) { $script:Fail.StepGuestAddressUnresolved = $true }
            if ($result.transportLost) { $script:Fail.StepGuestTransportLost = $true }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1bfdeecd0b234a34' -Arguments @{ exitCode = "$($result.exitCode)"; masked = "$masked" })
            if ($result.output) { Write-Warning "      output: $($result.output)" }
            return $false
        }
        return $true
    }

Register-SequenceAction -Name 'sshFetchAndExecute' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_6ba8527c12297fee') `
    -FailureLabel { param($c) "sshFetchAndExecute: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $cmd     = & $c.ExpandVariable $c.Step.command $c.Vars
        $prefix  = (Get-FetchObservationEnvPrefix -Context $c) + (Get-FetchExecuteEnvPrefix -CommandLine $cmd -RepoRoot $c.RepoRoot)
        $cmd     = Get-FetchExecutionCommand -CommandLine $cmd -EnvPrefix $prefix
        $executionClock = [System.Diagnostics.Stopwatch]::StartNew()
        $executionSucceeded = $false
        try {
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        Write-Debug "      sshFetchAndExecute: $cmd"
        $script:Fail.StepGuestAddressUnresolved = $null
        $script:Fail.StepGuestTransportLost     = $null
        $script:Fail.StepGuestRunLost           = $null
        $script:Fail.StepGuestPayloadUnavailable = $null
        # --- REGION: https://yuruna.link/4220a755-0041
        # Detached by default. The payload runs under a supervisor on the guest
        # and outlives the session, so a renumber costs a re-attach instead of
        # the step -- and, unlike a re-run, that is sound for a payload that
        # seeds records and then asserts counts over them, which is most of what
        # this verb carries. `detach: false` opts a step out.
        #
        # The token is derived rather than random, and that is load-bearing
        # twice: a reconnect within the step attaches to the same run, and a
        # warm resume that re-enters this step on a guest that is still up
        # attaches to the work already in flight rather than starting it again.
        $detach = $null -ne $c.Step.detach ? [bool]$c.Step.detach : $true
        $detachToken = ''
        if ($detach) {
            $detachToken = Get-GuestRunToken -SequencePath $c.SequencePath -StepNumber $c.StepNum -VMName $c.VMName
        }
        $transportRetries = $null -ne $c.Step.transportRetries ? [int]$c.Step.transportRetries : 0
        $result  = Invoke-GuestSsh -VMName $c.VMName -GuestKey $c.GuestKey -Command $cmd -TimeoutSeconds $timeout `
                       -TransportRetryCount $transportRetries -DetachToken $detachToken
        Write-Debug "      sshFetchAndExecute output: $($result.output)"
        if ($result.output -match '(?m)^YURUNA_EXECUTION stepInvocationId=([A-Za-z0-9-]{1,64})') {
            if ($Matches[1] -ne $c.StepInvocationId) { $c.CheckpointSourceStepInvocationId = $Matches[1] }
        }
        [void](Publish-GuestRetryMarker -Output $result.output -GuestKey $c.GuestKey -VmName $c.VMName)
        if (-not $result.success) {
            if (-not $result.addressResolved) { $script:Fail.StepGuestAddressUnresolved = $true }
            if ($result.transportLost) { $script:Fail.StepGuestTransportLost = $true }
            if ($result.runLost) { $script:Fail.StepGuestRunLost = $true }
            if (Test-GuestPayloadUnavailable -Output $result.output) { $script:Fail.StepGuestPayloadUnavailable = $true }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_35be02c672504936' -Arguments @{ exitCode = "$($result.exitCode)"; cmd = "$cmd" })
            if ($result.output) { Write-Warning "      output: $($result.output)" }
            return $false
        }
        $executionSucceeded = $true
        return $true
        } finally {
            Save-FetchExecutionEvidence -Context $c -Succeeded $executionSucceeded -ElapsedSeconds $executionClock.Elapsed.TotalSeconds
        }
    }

# --- REGION: retry / recoverFromSnapshot
# These coordinate the cross-module failure state in Test.SequenceFailureState
# ($script:Fail, bound above). retry re-runs an inner steps block;
# recoverFromSnapshot restores a snapshot after a prior step failed. They live
# here with the rest of the verb catalog so the engine stays a pure executor.
Register-SequenceAction -Name 'retry' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'retry_exhausted' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_21d8d5a86bdeaee9') `
    -FailureLabel { param($c)
        $null = $c
        # Use whatever the deepest inner step set on $script:Fail.LastFailureLabel
        # (the recursive call already wrapped or set it). Fallback to a
        # generic label when the inner never set one (empty steps block).
        if ($script:Fail.LastFailureLabel) { [string]$script:Fail.LastFailureLabel } else { 'retry: no inner failure label captured' }
    } `
    -Handler {
        param([hashtable]$c)
        # `retry` re-runs inner steps from the top on any failure.
        # Each attempt invokes $c.InvokeStepBlock recursively on the
        # inner `steps:` array; the first attempt that runs every
        # inner step cleanly wins. If all attempts fail, the deepest
        # inner failure label is wrapped with a "retry exhausted
        # (N attempts)" prefix so the operator sees both that retry
        # gave up AND which inner step ran out of patience.
        $maxAttempts = $c.Step.maxAttempts ? [int]$c.Step.maxAttempts : 3
        $innerSteps  = @($c.Step.steps)
        if ($innerSteps.Count -eq 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_55a49008b08e5b55' -Arguments @{ stepNum = "$($c.StepNum)"; stepCount = "$($c.StepCount)" })
            $script:Fail.LastFailureLabel       = 'retry: empty steps block'
            $script:Fail.LastFailureDescription = $c.Description
            $script:Fail.LastFailedAction       = 'retry'
            $script:Fail.LastFailedStepNumber   = $c.StepNum
            return $false
        }
        $attemptOk = $false
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            # Refresh runner.stepHeartbeat per attempt. The engine
            # already refreshes at step boundaries (top of
            # $invokeStepBlock); a multi-attempt retry block runs as
            # a SINGLE step from the watchdog's perspective and would
            # blow past stepTimeoutSeconds without ever signaling
            # proof-of-life. Per-attempt refresh keeps the watchdog
            # aligned with reality.
            try {
                $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh (retry loop) failed: $($_.Exception.Message)"
            }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0dfd5c6b86f1046f' -FormatValues ($c.StepNum, $c.StepCount, $attempt, $maxAttempts, $c.Description) -FormatBindings @{ stepNum = '0'; stepCount = '1'; attempt = '2'; maxAttempts = '3'; description = '4' })
            $attemptOk = & $c.InvokeStepBlock -Steps $innerSteps -ParentOrdinal $c.StepNum -ParentAction 'retry' -ParentAttempt $attempt
            if ($attemptOk) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b59032415dc73ae4' -FormatValues ($c.StepNum, $c.StepCount, $attempt, $maxAttempts) -FormatBindings @{ stepNum = '0'; stepCount = '1'; attempt = '2'; maxAttempts = '3' })
                break
            }
            # Preserve what the failed attempt had on screen, before the next
            # attempt's waits recycle the frame ring and overwrite the
            # per-VM failure screenshot. An attempt that later succeeds
            # takes the whole cycle to a pass, and every path that gathers
            # evidence is a cycle-failure path -- so without a copy taken
            # here, a recovered failure is unreconstructable no matter how
            # often it recurs. Gated on hard severity: soft classes are the
            # ones the retry exists to absorb, and copying for those would
            # bury the real captures under routine ones.
            $attemptVerbEntry = Get-SequenceAction -Name $script:Fail.LastFailedAction
            if ($attemptVerbEntry -and $attemptVerbEntry.Severity -eq 'hard' -and
                (Get-Command Save-StepFailureEvidence -ErrorAction SilentlyContinue)) {
                $evidenceRel = Save-StepFailureEvidence -VMName $c.VMName `
                    -Label ("step{0}-attempt{1}" -f $c.StepNum, $attempt) -WhatIf:$false
            } else {
                $evidenceRel = $null
            }

            # Structured per-attempt record so a flaky retry is queryable in the
            # cycle NDJSON stream, not just the human log. evidencePath carries
            # the capture above so a consumer can reach the frames without
            # knowing the naming convention.
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'retry_attempt'
                    stack        = 'sequence'
                    attempt      = [int]$attempt
                    maxAttempts  = [int]$maxAttempts
                    description  = [string]$c.Description
                    vmName       = [string]$c.VMName
                    failureClass = [string]$(if ($attemptVerbEntry) { $attemptVerbEntry.FailureClass } else { 'unknown' })
                    severity     = [string]$(if ($attemptVerbEntry) { $attemptVerbEntry.Severity }     else { 'unknown' })
                    evidencePath = [string]$evidenceRel
                    ok           = $false
                }
            }
            if ($attempt -lt $maxAttempts) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5e0f817304f680f9' -FormatValues ($c.StepNum, $c.StepCount, $attempt, $maxAttempts, $innerSteps.Count) -FormatBindings @{ stepNum = '0'; stepCount = '1'; attempt = '2'; maxAttempts = '3'; count = '4' })
                # Back off before the next attempt. Re-running instantly
                # burns all attempts in milliseconds and gives a transient
                # fault (network blip, a service still coming up) no time to
                # clear. Get-PollDelay is jittered + exponentially capped,
                # so it also breaks lock-step when many guests retry at
                # once. Refresh the heartbeat first so the watchdog stays
                # aligned across the wait (mirrors the per-attempt refresh
                # above).
                try {
                    $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                    [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
                } catch {
                    Write-Verbose "runner.stepHeartbeat refresh (retry backoff) failed: $($_.Exception.Message)"
                }
                Start-Sleep -Milliseconds (Get-PollDelay -Attempt $attempt)
            }
        }
        if (-not $attemptOk) {
            # Capture the deepest inner verb's classification BEFORE the
            # outer per-step block overwrites $script:Fail.LastFailedAction
            # with 'retry'. Without this, v2's failureClass collapses to
            # 'retry_exhausted' alone and a remediator can't distinguish
            # the inner cause (OCR timeout vs host_io_blocked vs ...).
            $innerVerbEntry = Get-SequenceAction -Name $script:Fail.LastFailedAction
            $script:Fail.LastInnerFailedAction        = [string]$script:Fail.LastFailedAction
            $script:Fail.LastInnerFailureClass        = if ($innerVerbEntry) { [string]$innerVerbEntry.FailureClass } else { 'unknown' }
            $script:Fail.LastInnerSeverity            = if ($innerVerbEntry) { [string]$innerVerbEntry.Severity }     else { 'unknown' }
            # [string[]] cast prevents the single-element unwrap so a
            # downstream consumer of $script:Fail.LastInnerSuggestedRecoveries
            # (innerSuggestedRecoveries field on step_failure NDJSON)
            # always sees a JSON array. Two-step assignment so an empty
            # SuggestedRecoveries does not collapse to $null via the
            # if-pipeline flatten.
            $script:Fail.LastInnerSuggestedRecoveries = [string[]]@()
            if ($innerVerbEntry -and $null -ne $innerVerbEntry.SuggestedRecoveries) {
                $script:Fail.LastInnerSuggestedRecoveries = [string[]]@($innerVerbEntry.SuggestedRecoveries)
            }
            # Retry ladder exhausted -- emit a structured terminal record carrying
            # the deepest inner cause (the outer class collapses to retry_exhausted).
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'retry_exhausted'
                    stack        = 'sequence'
                    attempt      = [int]$maxAttempts
                    maxAttempts  = [int]$maxAttempts
                    description  = [string]$c.Description
                    failureClass = [string]$script:Fail.LastInnerFailureClass
                    severity     = [string]$script:Fail.LastInnerSeverity
                }
            }
            $script:Fail.LastFailureLabel     = "retry exhausted ($maxAttempts attempts): $($script:Fail.LastFailureLabel)"
            $script:Fail.LastFailedStepNumber = $c.StepNum
            return $false
        }
        return $true
    }
# recoverFromSnapshot -- declarative auto-recovery primitive.
# Fires AFTER a prior step's failure when $script:Fail.LastFailedAction is
# set and matches the trigger condition. Restores a known snapshot and
# starts the VM, leaving the sequence to continue with a clean guest.
Register-SequenceAction -Name 'recoverFromSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'snapshot_restore_failed' -Severity 'soft' -SuggestedRecoveries @('operator_intervention_required') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_ecc35158d6b76576') `
    -FailureLabel { param($c) "recoverFromSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        # No-op when the prior step succeeded -- this verb only fires on
        # failure of an earlier step in the same sequence. $script:Fail.Last-
        # FailedStepNumber is set by the engine's failure path.
        $priorFailed = ($null -ne $script:Fail.LastFailedStepNumber -and $script:Fail.LastFailedStepNumber -ne 0)
        if (-not $priorFailed) {
            Write-Debug "      recoverFromSnapshot: no prior failure; skipping."
            return $true
        }
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d93099009c5a7d59'); return $false }
        if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue) -or `
            -not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c1dfab35d5d580a4')
            return $false
        }
        # Pre-validation: confirm the snapshot exists before any restore.
        # Restore-VMDiskSnapshot on a missing snapshot can leave the VM
        # in an ambiguous state on some hypervisors (Hyper-V silently
        # no-ops; KVM virsh returns non-zero late, AFTER it has stopped
        # the domain). Fail-loud here so the operator sees the missing
        # snapshot, not a stopped VM with no explanation.
        if (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue) {
            $snapExists = $false
            try { $snapExists = [bool](Test-VMDiskSnapshot -VMName $c.VMName -Id $snapId) }
            catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a52dca22e2a172d7' -Arguments @{ message = "$($_.Exception.Message)" })
                $snapExists = $true
            }
            if (-not $snapExists) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_df7ed91aac9f4403' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_missing'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'recoverFromSnapshot'
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            }
        }
        # Manifest identity check; same contract as loadDiskSnapshot.
        # Missing manifest is warn-only (older snapshots may not have
        # one); mismatch is a hard refuse.
        if (Get-Command Test-SnapshotManifestMatch -ErrorAction SilentlyContinue) {
            $check = Test-SnapshotManifestMatch -VMName $c.VMName -SnapshotId $snapId -HostType $c.HostType
            if ($check.Status -eq 'mismatch') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a8da3c2cf2b9b4d2' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)"; join = "$($check.Violations -join '; ')" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event        = 'snapshot_manifest_mismatch'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = 'recoverFromSnapshot'
                    violations   = @($check.Violations)
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            } elseif ($check.Status -eq 'missing') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e788536aac40e0f6' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event      = 'snapshot_manifest_missing'
                    vmName     = [string]$c.VMName
                    snapshotId = [string]$snapId
                    handler    = 'recoverFromSnapshot'
                }
            }
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_daae4716ca62f521' -Arguments @{ lastFailedStepNumber = "$($script:Fail.LastFailedStepNumber)"; snapId = "$snapId"; vMName = "$($c.VMName)" })
        try { $restored = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch { Write-Warning "      recoverFromSnapshot: $($_.Exception.Message)"; return $false }
        if (-not $restored) { return $false }
        try {
            $startRes = Start-VM -VMName $c.VMName -Confirm:$false
            if ($startRes -is [hashtable] -and -not $startRes.success) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_190bc05bcd0421f2' -Arguments @{ errorMessage = "$($startRes.errorMessage)" })
                return $false
            }
        } catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_a7a00252a7d2e710' -Arguments @{ message = "$($_.Exception.Message)" }); return $false }
        # Clear the failed-step marker so downstream steps see a clean state.
        $script:Fail.LastFailedStepNumber = 0
        $script:Fail.LastFailureLabel     = $null
        $script:Fail.LastFailedAction     = $null
        return $true
    }

# No Export-ModuleMember: every public surface for this module is the
# side-effect of the Register-SequenceAction calls above, which write
# into the Test.SequenceAction registry. The engine reads from that
# registry; nothing imports symbols from here directly.
