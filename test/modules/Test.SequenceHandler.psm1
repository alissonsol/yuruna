<#PSScriptInfo
.VERSION 2026.10.11
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

# See https://yuruna.link/4213a0b3-0156
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

# See https://yuruna.link/4213a0b3-0157
$script:ShellRejectedCommandPattern = @(
    'command not found',
    'No such file or directory',
    'syntax error near unexpected token',
    'syntax error: unexpected end of file'
)

# How long after Enter the shell's refusal is still the only plausible source
# of those strings. bash answers a command line it cannot resolve immediately;
# this is sized to cover a handful of OCR polls rather than to bound the
# shell, so a frame lost to a capture glitch still leaves later frames inside
# the window. Beyond it the fetched script owns the console and the same
# strings become its ordinary output.
$script:ShellRejectionWindowSeconds = 20

# --- REGION: https://yuruna.link/428e4df6-0014
# Complete command length above which GUI fetches use verified staging.
# Include metadata, shell quoting, and assignment terminators
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

function Resolve-SequenceCharDelay {
    <#
    .SYNOPSIS
        Select an explicit per-step delay, including zero, or the context default.
    #>
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable]$Context)
    if ($null -ne $Context.Step.charDelayMs) { return [int]$Context.Step.charDelayMs }
    return [int]$Context.DefaultCharDelayMs
}

function Expand-SequencePatternList {
    <#
    .SYNOPSIS
        Expands a scalar or collection into a stable nonempty pattern array.
    .PARAMETER Raw
        The unexpanded pattern value or collection.
    .PARAMETER Vars
        Variables for the current sequence step.
    .PARAMETER ExpandVariable
        The sequence variable expansion callback.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param($Raw, [Parameter(Mandatory)]$Vars, [Parameter(Mandatory)][scriptblock]$ExpandVariable)
    $patterns = [Collections.Generic.List[string]]::new()
    foreach ($item in @($Raw)) {
        $expanded = [string](& $ExpandVariable $item $Vars)
        if (-not [string]::IsNullOrWhiteSpace($expanded)) { $patterns.Add($expanded) }
    }
    return ,([string[]]$patterns.ToArray())
}

function Format-SequencePatternLabel {
    # Shared helper for the four pattern-bearing actions (waitForText,
    # waitForAndEnter, passwdPrompt). $Step's `pattern` may be a single
    # string or an array; arrays render as "' | '"-joined for the
    # human-readable label.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Step, [Parameter(Mandatory)]$Vars, [Parameter(Mandatory)]$ExpandVariable)
    return ((Expand-SequencePatternList -Raw $Step.pattern -Vars $Vars -ExpandVariable $ExpandVariable) -join "' | '")
}

function Resolve-WaitForTextStepParam {
    # Returns @{ patterns; failurePatterns; timeout; poll; fresh; tailLines;
    # sinceStepStart; noSegmentMatch } from a $Context. Used by waitForText /
    # waitForTextWithNudge / waitForAndEnter / passwdPrompt Handlers so the
    # pattern-bearing verbs share one expansion path.
    [CmdletBinding()][OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Context, [switch]$DefaultNoSegmentMatch)
    $step = $Context.Step
    $raw = $step.pattern
    [string[]]$patterns = Expand-SequencePatternList -Raw $raw -Vars $Context.Vars -ExpandVariable $Context.ExpandVariable
    $rawF = $step.failurePatterns
    [string[]]$fp = @()
    if ($null -ne $rawF) {
        $fp = Expand-SequencePatternList -Raw $rawF -Vars $Context.Vars -ExpandVariable $Context.ExpandVariable
    }
    @{
        patterns        = $patterns
        failurePatterns = $fp
        timeout         = $step.timeoutSeconds ? [int]$step.timeoutSeconds : $Context.DefaultTimeoutSeconds
        poll            = $step.pollSeconds    ? [int]$step.pollSeconds    : $Context.DefaultPollSeconds
        fresh           = $step.freshMatch -eq $true
        tailLines       = $step.freshMatchTailLines ? [int]$step.freshMatchTailLines : 12
        # Credentials require a prompt whose words occur together. Other waits
        # can opt in without changing callers that rely on reordered OCR text.
        noSegmentMatch  = $null -ne $step.noSegmentMatch ? [bool]$step.noSegmentMatch : [bool]$DefaultNoSegmentMatch
        # See https://yuruna.link/4213a0b3-0158
        sinceStepStart  = $step.sinceStepStart -eq $true
        # Set only on the copies of its steps that a retry block able to
        # cold-restart the guest hands down (see the retry handler). A splat,
        # so a wait without it binds exactly as it did before the switch.
        livelockExit    = if ($step.endWaitOnGuestLivelock -eq $true) { @{ EndOnGuestLivelock = $true } } else { @{} }
    }
}

function Invoke-Arm64HyperVColdPowerCycle {
    <#
    .SYNOPSIS
        Cold-restart a running ARM64 Hyper-V guest between safe retry attempts.
    .DESCRIPTION
        The caller owns the platform/architecture policy. This helper is
        deliberately fail-closed: a retry must not continue when the VM's
        stopped/running postconditions or its console transport are ambiguous.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context)

    foreach ($commandName in 'Get-VMState', 'Stop-VMForce', 'Start-VM', 'Restart-VMConsole') {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) { return $false }
    }

    try {
        if ([string](Get-VMState -VMName $Context.VMName) -ne 'running') { return $false }
        if (-not (Stop-VMForce -VMName $Context.VMName -StopTimeoutSeconds 20 -Confirm:$false)) { return $false }
        if ([string](Get-VMState -VMName $Context.VMName) -ne 'stopped') { return $false }

        $startResult = Start-VM -VMName $Context.VMName -Confirm:$false
        $startRecord = @($startResult) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
        if (-not $startRecord -or -not $startRecord.success) { return $false }
        if ([string](Get-VMState -VMName $Context.VMName) -ne 'running') { return $false }

        # Start-VM can leave the viewer from the failed boot alive. Reopening it
        # ensures both screenshots and keyboard input bind to the new boot.
        if (-not (Restart-VMConsole -VMName $Context.VMName -Confirm:$false)) { return $false }
        if (Get-Command Repair-ScreenshotRing -ErrorAction SilentlyContinue) {
            [void](Repair-ScreenshotRing -VMName $Context.VMName -Confirm:$false)
        }
        return $true
    } catch {
        if (($_.Exception.Data -and $_.Exception.Data['YurunaCycleRestart']) -or
            $_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
        Write-Verbose "ARM64 Hyper-V cold retry failed for '$($Context.VMName)': $($_.Exception.Message)"
        return $false
    }
}

function Test-Arm64HyperVColdPowerCycleMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()][string]$Mode,
        [AllowEmptyString()][string]$HostType,
        [System.Runtime.InteropServices.Architecture]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    )
    return (
        $Mode -in @('arm64HyperVColdPowerCycle', 'arm64HyperVInstallerBoot') -and
        $HostType -eq 'host.windows.hyper-v' -and
        $Architecture -eq [System.Runtime.InteropServices.Architecture]::Arm64
    )
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

# See https://yuruna.link/4213a0b3-0159
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
    # See https://yuruna.link/4213a0b3-015a
    $rawSkip = $Context.Step.blindSkipPattern
    if ($null -ne $rawSkip) {
        $skipPatterns = Expand-SequencePatternList -Raw $rawSkip -Vars $Context.Vars -ExpandVariable $Context.ExpandVariable
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
    $delaySeconds = ($null -ne $Context.Step.delaySeconds) ? [double]$Context.Step.delaySeconds : 2
    $charDelay    = (Resolve-SequenceCharDelay -Context $Context)
    if (-not (Invoke-TypeDrainEnter -Context $Context -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'waitForAndEnter' -ShellEscape)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_99bfd6c66d50c714')
        return $false
    }
    $confirmSeconds = $Context.Step.confirmSeconds ? [int]$Context.Step.confirmSeconds : 90
    $rawConfirm = $Context.Step.confirmPattern
    [string[]]$confirmPatterns = @()
    if ($null -ne $rawConfirm) {
        $confirmPatterns = Expand-SequencePatternList -Raw $rawConfirm -Vars $Context.Vars -ExpandVariable $Context.ExpandVariable
    }
    $confirmed = if ($confirmPatterns.Count -gt 0) {
        [bool](Wait-ForText -HostType $Context.HostType -VMName $Context.VMName -Pattern $confirmPatterns `
            -NoSegmentMatch:($Context.Step.noSegmentMatch -eq $true) `
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

Register-SequenceAction -Name 'waitForSeconds' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
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

Register-SequenceAction -Name 'pressKey' -ReplaySafety 'input' -HostIORequirement @('Send-Key') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_9adf9c3e3080cfe9') `
    -FailureLabel { param($c) "pressKey: $($c.Step.name)" } `
    -Handler {
        param([hashtable]$c)
        $keyName = $c.Step.name
        Write-Debug "      Sending key '$keyName'..."
        return [bool](Test.SequenceEngine\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName $keyName)
    }

# --- REGION: Test-SequenceCpuClockApplicable
function Test-SequenceCpuClockApplicable {
    <#
    .SYNOPSIS
        Limits restart accounting evidence to the native ARM64 Hyper-V Linux policy.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context)
    return ($Context.HostType -eq 'host.windows.hyper-v' -and $Context.GuestKey -match '^guest\.(ubuntu|amazon|debian|fedora|alpine)' -and
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [Runtime.InteropServices.Architecture]::Arm64)
}

# --- REGION: Save-SequenceCpuRestartEvidence
function Save-SequenceCpuRestartEvidence {
    <#
    .SYNOPSIS
        Records advisory evidence without adding guest discovery or recovery.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('before-cpu-restart','after-cpu-restart','offline-before-resize','offline-after-resize')][string]$Phase)
    if (-not (Test-SequenceCpuClockApplicable -Context $Context)) { return }
    try {
        if (-not (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Global -ErrorAction Stop
        }
        if (-not (Get-Command Save-GuestCpuRestartEvidence -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Global -ErrorAction Stop
        }
        $folder = Get-CycleGuestDataFolder -VMName $Context.VMName
        if (-not $folder) { return }
        if ($Phase.StartsWith('offline-')) {
            $null = Save-HyperVCpuRestartHostContext -VMName $Context.VMName -OutputFolder $folder -Phase $Phase
        } else {
            $capture = Save-GuestCpuRestartEvidence -VMName $Context.VMName -GuestKey $Context.GuestKey -OutputFolder $folder -Phase $Phase `
                -StepInvocationId $Context.StepInvocationId -SequenceInvocationId $Context.SequenceInvocationId
            $Context.DiagnosticOutcome = [string]$capture.diagnosticOutcome
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp=[DateTime]::UtcNow.ToString('o'); event='guest_clock_accounting'; phase=$Phase
                    guestKey=$Context.GuestKey; vmName=$Context.VMName; stepInvocationId=$Context.StepInvocationId
                    sequenceInvocationId=$Context.SequenceInvocationId; diagnosticOutcome=$capture.diagnosticOutcome
                    advisoryOnly=$true; analysis=$capture.analysis; outPath=$capture.outPath
                }
            }
        }
    } catch { Write-Verbose "CPU restart evidence unavailable: $($_.Exception.Message)" }
}

Register-SequenceAction -Name 'startVm' -ReplaySafety 'state-changing' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'provisioning_failure' -Severity 'hard' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef') `
    -FailureLabel { param($c) "startVm: `"$($c.VMName)`"" } `
    -Handler {
        param([hashtable]$c)
        if (-not (Get-Command Get-VMState -ErrorAction SilentlyContinue) -or
            -not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
            return $false
        }

        $timeoutSeconds = 120
        if ($null -ne $c.Step.timeoutSeconds) {
            try { $timeoutSeconds = [int]$c.Step.timeoutSeconds } catch { return $false }
        }
        if ($timeoutSeconds -lt 1) { return $false }
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        do {
            try { $state = [string](Get-VMState -VMName $c.VMName) } catch { return $false }
            if ($state -eq 'stopped') { break }
            if ($state -eq 'absent' -or [DateTime]::UtcNow -ge $deadline) { return $false }
            Start-Sleep -Seconds 1
        } while ($true)

        if ($c.HostType -eq 'host.windows.hyper-v' -and $null -ne $c.Step.arm64HyperVProcessorCount) {
            $processorCount = 0
            $processorCountText = & $c.ExpandVariable $c.Step.arm64HyperVProcessorCount $c.Vars
            if (-not [int]::TryParse([string]$processorCountText, [ref]$processorCount) -or $processorCount -lt 1) {
                return $false
            }
            if (-not (Get-Command Set-HyperVArm64LinuxGuestProcessorCount -ErrorAction SilentlyContinue)) {
                return $false
            }
            Save-SequenceCpuRestartEvidence -Context $c -Phase offline-before-resize
            try {
                if (-not (Set-HyperVArm64LinuxGuestProcessorCount -VMName $c.VMName -Count $processorCount -Confirm:$false)) {
                    return $false
                }
            } catch {
                if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
                return $false
            }
            Save-SequenceCpuRestartEvidence -Context $c -Phase offline-after-resize
        }

        try {
            $startResult = Start-VM -VMName $c.VMName -Confirm:$false
            $startRecord = @($startResult) | Where-Object { $_ -is [System.Collections.IDictionary] } | Select-Object -Last 1
            if (-not $startRecord -or -not $startRecord.success) { return $false }
        } catch {
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            return $false
        }
        return $true
    }

# Replay-safe: a second break only pauses again. Its optional restore on
# continue puts the guest back to a known snapshot, which cannot add residue.
Register-SequenceAction -Name 'break' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
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
            startedAt  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        }
        $null = Write-YurunaSidecarWithRetry -Path $breakActivePath -InputObject $breakDoc -FileLabel 'break-active.json'
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
        # See https://yuruna.link/4213a0b3-015b
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
                        if (-not (Restore-SequenceSnapshot -c $c -snapId $breakSnapshotId -HandlerName 'break')) { return $false }
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

Register-SequenceAction -Name 'saveDiskSnapshot' -ReplaySafety 'state-changing' -HostIORequirement @() -OcrRequired $false `
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

function Write-YurunaSidecarWithRetry {
    <# .SYNOPSIS
    Publishes an atomic sidecar with bounded retries and an explicit failure event.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal diagnostic publication; caller owns confirmation.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$InputObject, [Parameter(Mandatory)][string]$FileLabel)
    $message = 'atomic sidecar publication failed'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            if (Write-YurunaStateFileJson -Path $Path -InputObject $InputObject -Confirm:$false) { return $true }
        } catch { $message = $_.Exception.Message }
        if ($attempt -lt 3) { Start-Sleep -Milliseconds (50 * $attempt) }
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7c7b00a26a30f926' -Arguments @{ breakAttempts = '3'; message = $message; breakActivePath = $Path })
    Send-CycleEventSafely -EventRecord @{ timestamp = [datetime]::UtcNow.ToString('o'); event = 'sidecar_write_failed'; file = $FileLabel; path = $Path; attempts = 3; error = $message }
    return $false
}

function Restore-SequenceSnapshot {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Shared action implementation; the VM driver owns confirmation for restore and start.')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$c, [Parameter(Mandatory)][string]$snapId, [string]$HandlerName = 'loadDiskSnapshot')
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
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event        = 'snapshot_missing'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = $HandlerName
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
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event        = 'snapshot_manifest_mismatch'
                    vmName       = [string]$c.VMName
                    snapshotId   = [string]$snapId
                    handler      = $HandlerName
                    violations   = @($check.Violations)
                    failureClass = 'snapshot_restore_failed'
                    severity     = 'hard'
                }
                return $false
            } elseif ($check.Status -eq 'missing') {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bb0c0f58e4cfceea' -Arguments @{ snapId = "$snapId"; vMName = "$($c.VMName)" })
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event      = 'snapshot_manifest_missing'
                    vmName     = [string]$c.VMName
                    snapshotId = [string]$snapId
                    handler    = $HandlerName
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

Register-SequenceAction -Name 'loadDiskSnapshot' -ReplaySafety 'restore-point' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'snapshot_restore_failed' -Severity 'hard' -SuggestedRecoveries @('operator_intervention_required') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_7fd5db2fdbbc0cc5') `
    -FailureLabel { param($c) "loadDiskSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_419f7edb1d5f67bd'); return $false }
        return (Restore-SequenceSnapshot -c $c -snapId $snapId)
    }

Register-SequenceAction -Name 'saveGuestClockSnapshot' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'instrumentation_failure' -Severity 'soft' `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_9557327232acf7b4') `
    -Handler {
        param([hashtable]$c)
        $c.DiagnosticOutcome = 'skipped'
        Save-SequenceCpuRestartEvidence -Context $c -Phase ([string]$c.Step.phase)
        return $true
    }

Register-SequenceAction -Name 'saveSystemDiagnostic' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
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
                timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
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

Register-SequenceAction -Name 'callExtension' -ReplaySafety 'state-changing' -HostIORequirement @() -OcrRequired $false `
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
        try { $null = & $cmd @resolvedArgs; return $true }
        catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_784ff212589ae772' -Arguments @{ callArea = "$callArea"; callMethod = "$callMethod"; message = "$($_.Exception.Message)" }); return $false }
    }

Register-SequenceAction -Name 'inputText' -ReplaySafety 'input' -HostIORequirement @('Send-Text') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_121cac02691001a9') `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $charDelay = (Resolve-SequenceCharDelay -Context $c)
        Write-Debug "      Typing: '$masked' (charDelay=${charDelay}ms)"
        return [bool](Test.SequenceEngine\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape)
    }

Register-SequenceAction -Name 'inputTextAndEnter' -ReplaySafety 'input' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
    -Aliases @('typeAndEnter') `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_dd0c755911af00a8') `
    -FailureLabel { param($c) [string]$c.Step.action } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = ($null -ne $c.Step.delaySeconds) ? [double]$c.Step.delaySeconds : 2
        $charDelay = (Resolve-SequenceCharDelay -Context $c)
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'inputTextAndEnter' -ShellEscape)
    }

Register-SequenceAction -Name 'networkRelease' -ReplaySafety 'state-changing' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
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
            $charDelay = (Resolve-SequenceCharDelay -Context $c)
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

Register-SequenceAction -Name 'waitForText' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $true `
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
        $livelockExit = $p.livelockExit
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($p.fresh) { ', freshMatch' })$(if ($p.sinceStepStart) { ', sinceStepStart' })$(if ($p.failurePatterns.Count) { ", $($p.failurePatterns.Count) failurePatterns" }))"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -NoSegmentMatch:$p.noSegmentMatch -FailurePattern $p.failurePatterns @livelockExit)
    }

# Replay-safe despite sending a key: the nudge is a redraw Enter chosen because
# repeating it changes nothing, and the verb is built to send it on a timer.
Register-SequenceAction -Name 'waitForTextWithNudge' -ReplaySafety 'observe' -HostIORequirement @('Send-Key') -OcrRequired $true `
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
        $livelockExit = $p.livelockExit
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s, nudge '$nudgeKey' every ${nudgeInterval}s$(if ($p.fresh) { ', freshMatch' })$(if ($p.sinceStepStart) { ', sinceStepStart' })$(if ($p.failurePatterns.Count) { ", $($p.failurePatterns.Count) failurePatterns" }))"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -NoSegmentMatch:$p.noSegmentMatch -FailurePattern $p.failurePatterns `
            -NudgeKey $nudgeKey -NudgeIntervalSeconds $nudgeInterval @livelockExit)
    }

Register-SequenceAction -Name 'waitForAndEnter' -ReplaySafety 'input' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
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
        $livelockExit = $p.livelockExit
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
            -NoSegmentMatch:$p.noSegmentMatch -FailurePattern $p.failurePatterns @livelockExit
        # A wait that stopped on one of its own failurePatterns read the console
        # and found a screen the step declared wrong. That is the one $false the
        # blind path must not act on: it is evidence about the screen, not the
        # absence of evidence the blind answer exists to cover.
        $matchedFailure = $null
        $livelocked = $false
        if (Get-Command Get-SequenceFailureState -ErrorAction SilentlyContinue) {
            $waitState = Get-SequenceFailureState
            $matchedFailure = $waitState.WaitForTextMatchedFailurePattern
            # A step that asked to end on a livelock wants the recovery now;
            # an answer typed into processors trapping in place lands nowhere.
            $livelocked = $livelockExit.Count -gt 0 -and [bool]$waitState.WaitForTextGuestLivelocked
        }
        if ($ok -eq $false -and $useBlind -and -not $matchedFailure -and -not $livelocked) {
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
                    -NoSegmentMatch:$p.noSegmentMatch -FailurePattern $p.failurePatterns @livelockExit
            }
        }
        if ($ok -eq $false) { return $false }

        # Some recovery waits have two successful terminal screens: the prompt
        # that needs an answer, and a later screen proving the guest is already
        # beyond that prompt. Match the latter against the same OCR frame and
        # succeed without typing into it (notably, never type "yes" at login).
        $rawSkipInput = $c.Step.skipInputPattern
        if ($null -ne $rawSkipInput) {
            [string[]]$skipInputPatterns = Expand-SequencePatternList -Raw $rawSkipInput -Vars $c.Vars -ExpandVariable $c.ExpandVariable
            $waitVerdict = Get-LastWaitVerdict
            foreach ($skipInputPattern in $skipInputPatterns) {
                if ($waitVerdict.ConsoleText -and (Test-OCRMatch -Text ([string]$waitVerdict.ConsoleText) -Pattern $skipInputPattern -NoSegmentMatch:$p.noSegmentMatch)) {
                    Write-Debug "      '$skipInputPattern' is already satisfied; skipping input"
                    return $true
                }
            }
        }
        Send-TabNavigation -Context $c
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = ($null -ne $c.Step.delaySeconds) ? [double]$c.Step.delaySeconds : 2
        $charDelay = (Resolve-SequenceCharDelay -Context $c)
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'waitForAndEnter' -ShellEscape)
    }

Register-SequenceAction -Name 'passwdPrompt' -ReplaySafety 'input' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'credential_expired' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -UsesWaitSignals $true -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_a581e70e444c9b39') `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "passwdPrompt: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c -DefaultNoSegmentMatch
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($p.sinceStepStart) { ', sinceStepStart' }))"
        $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -SinceStepStart:$p.sinceStepStart `
            -NoSegmentMatch:$p.noSegmentMatch -FailurePattern $p.failurePatterns
        if ($ok -eq $false) { return $false }
        Send-TabNavigation -Context $c
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = $c.ShowSensitive ? $text : '***'
        $delaySeconds = ($null -ne $c.Step.delaySeconds) ? [double]$c.Step.delaySeconds : 2
        $charDelay = (Resolve-SequenceCharDelay -Context $c)
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        return (Invoke-TypeDrainEnter -Context $c -Text $text -DelaySeconds $delaySeconds -CharDelayMs $charDelay -Activity 'passwdPrompt')
    }

Register-SequenceAction -Name 'tapOn' -ReplaySafety 'input' -HostIORequirement @('Send-Click') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_93d8c93707d2b133') `
    -Handler {
        param([hashtable]$c)
        $rawLabels = $c.Step.label
        [string[]]$labels = Expand-SequencePatternList -Raw $rawLabels -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        $offX    = $c.Step.offsetX        ? [int]$c.Step.offsetX        : 0
        $offY    = $c.Step.offsetY        ? [int]$c.Step.offsetY        : 0
        $labelDisplay = $labels -join "' | '"
        Write-Debug "      Waiting for button '$labelDisplay' (timeout: ${timeout}s)"
        return [bool](Invoke-TapOn -HostType $c.HostType -VMName $c.VMName -Label $labels `
            -TimeoutSeconds $timeout -PollSeconds $poll -OffsetX $offX -OffsetY $offY)
    }

Register-SequenceAction -Name 'takeScreenshot' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
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
        [ValidateRange(240,400)][int]$MaxTypedChars = 400,
        [switch]$CompactEnvelope,
        [string]$EnvelopeDigest
    )
    if ($CompactEnvelope -and ($EnvelopeDigest -cnotmatch '^[0-9a-f]{64}$' -or $CommandLine -cnotmatch '^[A-Za-z0-9+/]+={0,2}$')) {
        throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_GUI_ENCODING'; detail = 'YFEG1' })
    }
    if (-not $CompactEnvelope -and $CommandLine.Length -le $MaxTypedChars) { return $CommandLine }
    $quote = [string][char]39
    $escapedQuote = $quote + [char]34 + $quote + [char]34 + $quote
    $lines = [System.Collections.Generic.List[string]]::new()
    $prefix = '(unset __y;__y='
    $chunk = ''
    # Count the quoted representation, including apostrophe expansion, rather
    # than the raw substring. Include the command terminator: an Enter event
    # can be lost even when both adjacent text chunks arrive intact. Explicit
    # semicolons keep assignments and the guard separate in that case.
    $chunkBudget = 240
    foreach ($character in $CommandLine.ToCharArray()) {
        $encoded = if ([string]$character -eq $quote) { $escapedQuote } else { [string]$character }
        if ($prefix.Length + $chunk.Length + $encoded.Length + 3 -gt $chunkBudget) {
            $lines.Add($prefix + $quote + $chunk + $quote + ';')
            $prefix = '__y+='
            $chunk = ''
        }
        $chunk += $encoded
    }
    if ($chunk.Length) { $lines.Add($prefix + $quote + $chunk + $quote + ';') }
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
    $guard = if ($CompactEnvelope) { 'yfe --gui ' + $EnvelopeDigest + ' "$__y")' } else {
        'if [ "$(printf %s "$__y"|sha256sum --text)" = ' + $quote + $digest + '  -' + $quote +
            ' ];then eval "$__y";else printf ' + $quote + $sentinelFormat +
            ' GUI command integrity mismatch\n' + $quote + ';exit 125;fi)'
    }
    if ($guard.Length -gt $MaxTypedChars) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_31cfbd18727596c9') }
    $lines.Add($guard)
    return $lines.ToArray()
}

function Get-GuiFetchEnvelopeInput {
    <#
    .SYNOPSIS
        Compresses one immutable context and original command without nested transport encodings.
    #>
    [CmdletBinding()]
    [OutputType([string], [object[]])]
    param([Parameter(Mandatory)]$FetchContext, [Parameter(Mandatory)][string]$CommandLine)
    if ($CommandLine.Contains([char]0)) { return }
    $commandBytes = [Text.Encoding]::UTF8.GetBytes($CommandLine)
    $contextDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($FetchContext.Bytes)).ToLowerInvariant()
    $header = [Text.Encoding]::ASCII.GetBytes("YFEG1`n$($FetchContext.Id)`n$($FetchContext.Bytes.Length)`n$contextDigest`n$($commandBytes.Length)`n")
    $size = $header.Length + $FetchContext.Bytes.Length + $commandBytes.Length
    if ($size -gt 65536) { return }
    $bytes = [byte[]]::new($size)
    [Array]::Copy($header, 0, $bytes, 0, $header.Length)
    [Array]::Copy($FetchContext.Bytes, 0, $bytes, $header.Length, $FetchContext.Bytes.Length)
    [Array]::Copy($commandBytes, 0, $bytes, $header.Length + $FetchContext.Bytes.Length, $commandBytes.Length)
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    $buffer = [IO.MemoryStream]::new()
    try {
        $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
        try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
        $encoded = [Convert]::ToBase64String($buffer.ToArray())
    } finally { $buffer.Dispose() }
    return @(Get-GuiFetchExecutionInput -CommandLine $encoded -CompactEnvelope -EnvelopeDigest $digest)
}

function Test-GuiFetchEnvelopeSupported {
    <#
    .SYNOPSIS
        Checks the running guest's launcher without discovery, key creation, or snapshot-stale memoization.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Context)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($name in 'Get-ProvenGuestAddress', 'Invoke-GuestSsh') {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { return $false }
        }
        $address = Get-ProvenGuestAddress -VMName $Context.VMName
        $ip = $null
        if (-not [Net.IPAddress]::TryParse([string]$address, [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
        $key = Join-Path (Split-Path -Parent $PSScriptRoot) 'status/ssh/yuruna_ed25519'
        if (-not (Test-Path -LiteralPath $key -PathType Leaf) -or -not $Context.Vars.username -or $clock.Elapsed.TotalSeconds -ge 1) { return $false }
        # One second for SSH, with the other second reserved for these local
        # prerequisites. Supplying both paths bypasses driver/IP/key setup.
        $result = Invoke-GuestSsh -VMName $Context.VMName -GuestKey $Context.GuestKey -User ([string]$Context.Vars.username) `
            -ResolvedAddress $address -PrivateKeyPath $key -AddressWaitSeconds 0 -TimeoutSeconds 1 -MaxCapturedChars 4096 `
            -Command '/usr/local/bin/yfe --gui-capability' -WarningAction SilentlyContinue
        return ($clock.Elapsed.TotalSeconds -lt 2 -and $result.success -and $result.exitCode -eq 0 -and
            ([string]$result.output).TrimEnd("`r", "`n") -ceq 'YFE_GUI_1')
    } catch { return $false }
}

function Test-GuiFetchInputStalled {
    <#
    .SYNOPSIS
        True when a timed-out GUI fetch left its staged input open in the console.
    .DESCRIPTION
        Get-GuiFetchExecutionInput keeps a subshell open until its guard line
        arrives, so bash answers each typed line with a continuation prompt and
        the staging variable shows in the echo. A long typed line wraps, so the
        prompt is not necessarily on the last visible row. The staged state holds
        when a continuation prompt is visible and no shell prompt has appeared
        after it, because a completed guard always returns to one.
        This is only a screen reading. A caller that needs to act on it must
        confirm the state with the guest, which is what Get-GuiFetchPayloadState
        does.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$OcrTail)
    if ($OcrTail -notmatch '_{1,2}y\b') { return $false }
    $lastContinuation = -1
    $lastShellPrompt = -1
    $rows = @($OcrTail -split "`r?`n")
    for ($row = 0; $row -lt $rows.Count; $row++) {
        if ($rows[$row] -match '^\s*>') { $lastContinuation = $row }
        elseif ($rows[$row] -match '\$\s*$') { $lastShellPrompt = $row }
    }
    return ($lastContinuation -ge 0 -and $lastShellPrompt -lt $lastContinuation)
}

function Get-GuiFetchPayloadState {
    <#
    .SYNOPSIS
        Ask the guest whether a GUI fetch's guard ever ran.
    .DESCRIPTION
        The guard prepares a context under the command id and the launcher
        removes it when it takes the context to run the payload. So a guard that
        never ran leaves no context and no fetch process, while a guard that ran
        leaves a context (not yet taken), or a running fetch process (taken).
        Returns PREPARED, RUNNING or NOT_PREPARED, or $null when the guest did
        not answer or the id is not one this module issues. Callers test for
        NOT_PREPARED alone, so $null never reads as a confirmed state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName, [string]$GuestKey, [string]$ContextId)
    if ($ContextId -notmatch '^[0-9a-f]{11}$') { return $null }
    # Bracketed first letters keep pgrep from matching this probe's own command line.
    $probe = 'if [ -e "$HOME/.local/state/yuruna/fetch-context/' + $ContextId + '" ]; then echo PREPARED; ' +
        'elif pgrep -f "[f]etch-and-execute|[y]uruna-fetch-context" >/dev/null 2>&1; then echo RUNNING; ' +
        'else echo NOT_PREPARED; fi'
    $result = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $probe -TimeoutSeconds 30
    if (-not $result.success) { return $null }
    $state = ([string]$result.output).Trim()
    if ($state -in @('PREPARED', 'RUNNING', 'NOT_PREPARED')) { return $state }
    return $null
}

function Get-FetchExecutionContext {
    <#
    .SYNOPSIS
        Builds one immutable, integrity-bound context for console and SSH fetches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$CommandLine,
        [switch]$Compress
    )
    $Context.FetchExecutionPath = $null
    $Context.Remove('CheckpointSourceStepInvocationId')
    $Context.Remove('CheckpointSourceSequenceInvocationId')
    if (-not $script:FetchContextIds) {
        $script:FetchContextIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
    $random = [byte[]]::new(6)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($random) } finally { $rng.Dispose() }
    $id = [BitConverter]::ToString($random).Replace('-', '').ToLowerInvariant().Substring(0, 11)
    if (-not $script:FetchContextIds.Add($id)) {
        throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_CONTEXT_COLLISION'; detail = $id })
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $commandDigest = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($CommandLine))).Replace('-', '').ToLowerInvariant()
    } finally { $sha256.Dispose() }
    $fields = [ordered]@{
        id = $id
        cmd_sha = $commandDigest
        EXEC_KEEP_PROFILE = if ($Context.Step.sensitive) { '0' } else { '1' }
    }
    if ($Context.Step.sensitive) {
        $fields['EXEC_PROFILE'] = '0'
        $fields['EXEC_RECORDER'] = '0'
    } elseif ($Context.VMName -and (Get-Command Get-CycleGuestDataFolder -ErrorAction SilentlyContinue)) {
        try {
            $folder = Get-CycleGuestDataFolder -VMName $Context.VMName
            if ($folder) {
                $cycle = Split-Path -Leaf (Split-Path -Parent $folder)
                $guest = Split-Path -Leaf $folder
                if ($cycle -match '^[A-Za-z0-9_.-]+$' -and $cycle -notmatch '\.\.' -and
                    $guest -match '^[A-Za-z0-9_.-]+$' -and $guest -notmatch '\.\.' -and
                    $Context.StepInvocationId -match '^[A-Za-z0-9-]{1,64}$') {
                    $fileName = "execution.system.diagnostic.$($Context.StepInvocationId).txt"
                    # The guest already resolved its host while fetching the payload;
                    # a relative path avoids another potentially blocking driver call.
                    $fields['E_RECORDER_PATH'] = "diagnostics/$cycle/$guest/$fileName"
                    $Context.RecorderArtifactPath = Join-Path $folder $fileName
                }
            }
        } catch { Write-Verbose "Guest recorder upload unavailable: $($_.Exception.Message)" }
    }
    foreach ($entry in @(@('E_SI', $Context.StepInvocationId), @('E_QI', $Context.SequenceInvocationId))) {
        if ([string]$entry[1] -match '^[A-Za-z0-9-]{1,64}$') { $fields[$entry[0]] = [string]$entry[1] }
    }

    $matched = [regex]::Match($CommandLine, 'fetch-and-execute\.sh\s+(\S+)')
    if ($matched.Success) {
        $rel = ($matched.Groups[1].Value -split '\?', 2)[0]
        if ([string]::IsNullOrWhiteSpace($rel) -or $rel -notmatch '^[A-Za-z0-9_./-]+$' -or
            $rel -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($rel)) {
            throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_CONTEXT_PATH'; detail = "$rel" })
        }
        $root = [string]$Context.RepoRoot
        if ([string]::IsNullOrWhiteSpace($root)) {
            throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_REPO_ROOT_MISSING'; detail = 'RepoRoot' })
        }
        $full = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_PAYLOAD_MISSING'; detail = "$rel" })
        }
        $retryLib = Join-Path $root 'automation/yuruna-retry.sh'
        if (-not (Test-Path -LiteralPath $retryLib -PathType Leaf)) {
            throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_RETRY_LIB_MISSING'; detail = "$retryLib" })
        }
        $fields['rel'] = $rel
        $Context.FetchExecutionPath = $rel
        $fields['EXEC_REQUIRE_SHA256'] = '1'
        $fields['E_SHA'] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
        $fields['E_RETRY_SHA'] = (Get-FileHash -LiteralPath $retryLib -Algorithm SHA256).Hash.ToLowerInvariant()
        $source = Get-YurunaGitHubSource -RepoRoot $root
        if ($source.Repo -and $source.Ref) {
            $fields['E_FB_REPO'] = [string]$source.Repo
            $fields['E_FB_REF'] = [string]$source.Ref
            if (-not $rel.StartsWith('project/', [StringComparison]::Ordinal) -and
                -not (Test-YurunaFileMatchesHead -RepoRoot $root -RelativePath $rel)) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d9b7f7780d748cd8' -Arguments @{ rel = "$rel" })
            }
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f1e69844d12e14d2' -Arguments @{ repoRoot = "$root" })
        }
        if ($rel.StartsWith('project/', [StringComparison]::Ordinal)) {
            # Git searches parent directories. A plain project folder must not
            # inherit the framework remote and HEAD as its fallback identity.
            $projectRoot = [IO.Path]::GetFullPath((Join-Path $root 'project'))
            $projectTop = & git -C $projectRoot rev-parse --show-toplevel 2>$null
            $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            $ownCheckout = $LASTEXITCODE -eq 0 -and $projectTop -and [string]::Equals(
                [IO.Path]::GetFullPath(([string]$projectTop).Trim()).TrimEnd([char[]]'\/'),
                $projectRoot.TrimEnd([char[]]'\/'), $pathComparison)
            # A framework clone URL in project configuration cannot prove where
            # the project's commit lives; only its checkout remote can do that.
            $projectRemote = if ($ownCheckout) { ConvertTo-GitHubRepoSlug -Url (Get-YurunaCheckoutRemoteUrl -RepoRoot $projectRoot) } else { '' }
            $projectSource = if ($projectRemote) { Get-YurunaGitHubSource -RepoRoot $projectRoot } else { $null }
            if ($projectSource -and $projectSource.Repo -cmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -and
                $projectSource.Ref -cmatch '^[0-9a-f]{40}$') {
                $fields['E_PROJECT_REPO'] = [string]$projectSource.Repo
                $fields['E_PROJECT_REF'] = [string]$projectSource.Ref
                if (-not (Test-YurunaFileMatchesHead -RepoRoot $projectRoot -RelativePath $rel.Substring(8))) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d9b7f7780d748cd8' -Arguments @{ rel = "$rel" })
                }
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f1e69844d12e14d2' -Arguments @{ repoRoot = "$projectRoot" })
            }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('YFE1')
    foreach ($key in $fields.Keys) {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$fields[$key]))
        $lines.Add("$key=$encoded")
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n")
    if ($bytes.Length -gt 4096) {
        throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_CONTEXT_SIZE'; detail = "$($bytes.Length)/4096" })
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
    $prefix = "yfe $id "
    if ($prefix.Length -ne 16) {
        throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_PREFIX_LENGTH'; detail = "$($prefix.Length)/16" })
    }
    $launch = Get-FetchExecutionCommand -CommandLine $CommandLine -EnvPrefix $prefix
    $encodedContext = [Convert]::ToBase64String($bytes)
    $prepare = "printf '%s' '$encodedContext' | yfe --prepare $id $($bytes.Length) $digest"
    if ($Compress) {
        # Console input pays per character and per drained line. Compress the
        # transport only; the seeded launcher still verifies the original byte
        # count, full SHA-256 digest, field allowlist, and command binding. The
        # Linux guests already provide gzip and GNU base64 for their bootstrap.
        $buffer = [IO.MemoryStream]::new()
        try {
            $gzip = [IO.Compression.GZipStream]::new($buffer, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $gzip.Write($bytes, 0, $bytes.Length) } finally { $gzip.Dispose() }
            $compressedContext = [Convert]::ToBase64String($buffer.ToArray())
        } finally { $buffer.Dispose() }
        # gzip can emit all bytes before reporting a corrupt footer. Preserve
        # upstream failures without changing the payload shell's options.
        $compressedPrepare = "(set -o pipefail; printf '%s' '$compressedContext' | base64 -d | gzip -dc | base64 -w0 | yfe --prepare $id $($bytes.Length) $digest)"
        if ($compressedPrepare.Length -lt $prepare.Length) { $prepare = $compressedPrepare }
    }
    $sentinelOctal = -join @($script:NonzeroScriptExitSentinel.ToCharArray() | ForEach-Object {
        '\' + [Convert]::ToString([int]$_, 8).PadLeft(3, '0')
    })
    $combined = "if $prepare; then $launch; else printf '%b\n' '$sentinelOctal'; exit 125; fi"
    return [pscustomobject]@{
        Id = $id
        Prefix = $prefix
        Launch = $launch
        Preparation = $prepare
        Command = $combined
        Fields = $fields
        Bytes = $bytes
    }
}

function Save-FetchExecutionEvidence {
    <#
    .SYNOPSIS
        Records capture outcomes and collects traces before the guest log is reused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [bool]$Succeeded,
        [double]$ElapsedSeconds
    )
    $Context.ExecutionProfile = @{ diagnosticOutcome='skipped'; reasonCode='fast-success'; outPath=$null }
    if ($Context.Step.sensitive) { $Context.ExecutionProfile.reasonCode='sensitive-step'; return }
    if ($Succeeded -and $ElapsedSeconds -lt 60) { return }
    $sourceId = if ($Context.CheckpointSourceStepInvocationId) { $Context.CheckpointSourceStepInvocationId } else { $Context.StepInvocationId }
    if ($sourceId -notmatch '^[A-Za-z0-9-]{1,64}$') { $Context.ExecutionProfile.reasonCode='invalid-invocation-id'; return }
    $captureClock = [System.Diagnostics.Stopwatch]::StartNew()
    $folder = $null
    try {
        if (-not (Get-Command Save-GuestExecutionProfile -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Global -ErrorAction Stop
        }
        $folder = Get-CycleGuestDataFolder -VMName $Context.VMName
        if (-not $folder) {
            $Context.ExecutionProfile = @{ diagnosticOutcome='unavailable'; reasonCode='cycle-folder-unavailable'; outPath=$null }
            return
        }
        $identity = @{}
        if ($Context.FetchExecutionPath) {
            $identity.ScriptPath = $Context.FetchExecutionPath
            $identity.SequenceInvocationId = if ($Context.CheckpointSourceStepInvocationId) {
                $Context.CheckpointSourceSequenceInvocationId
            } else { $Context.SequenceInvocationId }
        }
        $Context.ExecutionProfile = Save-GuestExecutionProfile -VMName $Context.VMName -GuestKey $Context.GuestKey `
            -OutputFolder $folder -StepInvocationId $sourceId -TimeoutSeconds 20 -Variables $Context.Vars @identity
    } catch {
        $captureReason = if (Get-Command Protect-GuestEvidenceText -ErrorAction SilentlyContinue) {
            Protect-GuestEvidenceText -Text $_.Exception.Message -Variables $Context.Vars
        } else { 'Execution profile capture could not complete.' }
        $Context.ExecutionProfile = @{ diagnosticOutcome='unavailable'; reasonCode='profile-capture-error'; outPath=$null
            reason=$captureReason; stepInvocationId=$sourceId; sshResponsive=$false }
        Write-Verbose "Execution profile capture unavailable: $captureReason"
    } finally {
        $Context.EvidenceCaptureDurationMs = [long]$captureClock.Elapsed.TotalMilliseconds
        if ($folder) {
            try {
                $artifact = Join-Path $folder "execution.system.diagnostic.$sourceId.txt"
                $recorder = @{ diagnosticOutcome='unavailable'; outPath=$null; reasonCode='recorder-not-uploaded' }
                if (Test-Path -LiteralPath $artifact -PathType Leaf) {
                    $reader = [IO.StreamReader]::new($artifact)
                    try { $buffer=[char[]]::new(8192); $length=$reader.Read($buffer,0,$buffer.Length); $header=[string]::new($buffer,0,$length) }
                    finally { $reader.Dispose() }
                    if ($header -match "(?m)^stepInvocationId=$([regex]::Escape($sourceId))\r?`$") {
                        $recorder.diagnosticOutcome='partial'; $recorder.outPath=$artifact; $recorder.reasonCode='recorder-upload-retained'
                        if ($header -match '(?m)^heartbeatUtc=([^\r\n]+)') {
                            $recorder.heartbeatUtc=$Matches[1]
                            $stamp=[datetimeoffset]::MinValue
                            if ([datetimeoffset]::TryParse($recorder.heartbeatUtc,[ref]$stamp)) {
                                $recorder.heartbeatAgeSeconds=[math]::Max(0,([datetimeoffset]::UtcNow-$stamp).TotalSeconds)
                            }
                        }
                    } else { $recorder.reasonCode='recorder-invocation-mismatch' }
                }
                $Context.ExecutionProfile.recorder=$recorder
                $manifestPath = Join-Path $folder "fetch-and-execute.$sourceId.evidence.json"
                [IO.File]::WriteAllText($manifestPath,($Context.ExecutionProfile | ConvertTo-Json -Depth 5))
            } catch { Write-Verbose "Execution evidence manifest unavailable: $($_.Exception.Message)" }
        }
    }
}

# See https://yuruna.link/4213a0b3-015c
Register-SequenceAction -Name 'fetchAndExecute' -ReplaySafety 'state-changing' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'wait_timeout' -Severity 'hard' -SuggestedRecoveries @('retry_with_backoff','pause_and_inspect') `
    -CapturesOwnFailureScreenshot $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_d1d328d999fc31cf') `
    -FailureLabel { param($c) if ($c.Step.sensitive) { return 'fetchAndExecute: "***"' }; "fetchAndExecute: `"$(& $c.ExpandVariable $c.Step.text $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $executionClock = [System.Diagnostics.Stopwatch]::StartNew()
        $executionSucceeded = $false
        try {
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $fetchContext = Get-FetchExecutionContext -Context $c -CommandLine $text -Compress
        $originalCommand = $text
        $text = $fetchContext.Command
        $typedCommands = @(Get-GuiFetchExecutionInput -CommandLine $text -MaxTypedChars $script:FetchExecuteTypedCharWarn)
        $compactInput = @(Get-GuiFetchEnvelopeInput -FetchContext $fetchContext -CommandLine $originalCommand)
        $legacyChars = ($typedCommands | Measure-Object -Property Length -Sum).Sum
        $compactChars = ($compactInput | Measure-Object -Property Length -Sum).Sum
        if ($compactInput.Count -gt 0 -and $compactInput.Count -le $typedCommands.Count -and $compactChars -lt $legacyChars -and
            (Test-GuiFetchEnvelopeSupported -Context $c)) {
            $typedCommands = $compactInput
        }
        if ($typedCommands.Count -gt 1) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0ed289c55b84fcb5' -Arguments @{ length = "$($text.Length)"; count = "$($typedCommands.Count)" })
        }
        $delaySeconds = ($null -ne $c.Step.delaySeconds) ? [double]$c.Step.delaySeconds : 2
        $charDelay = (Resolve-SequenceCharDelay -Context $c)
        if (-not $c.Step.sensitive) { Write-Debug "      fetchAndExecute: command '$($fetchContext.Launch)'" }
        $inputIndex = 0
        foreach ($typedCommand in $typedCommands) {
            if ($typedCommand.Length -gt $script:FetchExecuteTypedCharWarn) {
                throw (Format-YurunaOperatorMessage -Key 'runner.fetch_context_rejected' -Arguments @{ reason = 'YFE_PHYSICAL_SEND_LIMIT'; detail = "$($typedCommand.Length)/$($script:FetchExecuteTypedCharWarn)" })
            }
            if ($executionClock.Elapsed.TotalSeconds -ge $timeout) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.fetch_context_deadline' -Arguments @{ timeoutSeconds = "$timeout" })
                return $false
            }
            # The CGEvent fallback's ShellEscape wrapper evaluates each input
            # independently. Continuation lines must reach the shell literally.
            # Intermediate lines only assemble data in a deferred subshell, so
            # a settle between them is not needed for ordering. UTM is the
            # exception: its keystrokes are delivered one osascript call at a
            # time, and with no settle the staged subshell has stalled before
            # its guard line arrived. Retain the paced keystrokes and 800ms
            # drain, the final launch delay, and any explicit operator delay.
            # The final digest rejects corrupted input.
            $settleBetweenLines = $c.HostType -eq 'host.macos.utm'
            $drainSeconds = if ($null -eq $c.Step.delaySeconds -and $inputIndex -lt $typedCommands.Count - 1 -and -not $settleBetweenLines) { 0 } else { $delaySeconds }
            if (-not (Invoke-TypeDrainEnter -Context $c -Text $typedCommand -DelaySeconds $drainSeconds -CharDelayMs $charDelay -Activity 'fetchAndExecute' -ShellEscape:($typedCommands.Count -eq 1))) { return $false }
            $inputIndex++
        }
        $waitPattern = & $c.ExpandVariable $c.Step.waitPattern $c.Vars
        if ([string]::IsNullOrWhiteSpace($waitPattern)) {
            # fetchAndExecute REQUIRES a waitPattern (the completion marker). An empty/missing one
            # makes Wait-ForText poll @('') -- which either "matches" any frame (false pass) or
            # burns the full timeout. Fail fast with a clear message instead.
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_64c3f8a2035c9363')
            return $false
        }
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        $failPatterns = @()
        $rawFail = $c.Step.failurePatterns
        if ($null -ne $rawFail) {
            # Same string-or-array shape every other pattern-bearing verb
            # accepts, so `failurePatterns` means one thing across the schema
            # rather than one thing here and another everywhere else.
            $failPatterns = Expand-SequencePatternList -Raw $rawFail -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        } else {
            # See https://yuruna.link/4213a0b3-015d
            $failPatterns = @($script:NonzeroScriptExitSentinel)
        }
        # See https://yuruna.link/4213a0b3-015e
        $tailLines = $c.Step.freshMatchTailLines ? [int]$c.Step.freshMatchTailLines : 24
        # The shell-rejection set is NOT part of $failPatterns and is not
        # overridable with them: those describe how this step's PAYLOAD fails,
        # and a step that wants to say something about its own script has no
        # reason to also give up the harness reading whether the command line
        # was accepted at all.
        Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${timeout}s, freshMatch, tail ${tailLines} lines); failurePatterns=$($failPatterns -join ', '); shell-rejection window=${script:ShellRejectionWindowSeconds}s"
        $remaining = $timeout - [int][Math]::Ceiling($executionClock.Elapsed.TotalSeconds)
        if ($remaining -le 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.fetch_context_deadline' -Arguments @{ timeoutSeconds = "$timeout" })
            return $false
        }
        $script:Fail.StepInputLost = $null
        # Sustained hypervisor livelock cannot produce a completion marker. End
        # this wait for diagnostics without replaying the partially run payload.
        $executionSucceeded = [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern @($waitPattern) `
            -TimeoutSeconds $remaining -PollSeconds $poll -FreshMatch $true `
            -FreshMatchTailLines $tailLines -FailurePattern $failPatterns `
            -NoSegmentMatch:($c.Step.noSegmentMatch -eq $true) `
            -EarlyFailurePattern $script:ShellRejectedCommandPattern `
            -EarlyFailureSeconds $script:ShellRejectionWindowSeconds -EndOnGuestLivelock)
        if (-not $executionSucceeded -and (Test-GuiFetchInputStalled -OcrTail ([string]$script:Fail.WaitForTextOcrTail))) {
            # A screen that shows an open subshell does not prove the guard never
            # arrived: a payload that ran and went quiet can look the same. Only
            # a guest with no prepared context and no fetch process has never run
            # the payload, and only that case is replayable without repeating work.
            $payloadState = Get-GuiFetchPayloadState -VMName $c.VMName -GuestKey $c.GuestKey -ContextId ([string]$fetchContext.Id)
            if ($payloadState -eq 'NOT_PREPARED') {
                $script:Fail.StepInputLost = $true
                Write-Warning "      fetchAndExecute: staged input never closed in the guest shell after $($typedCommands.Count) line(s); the guest holds no prepared payload."
            }
        }
        return $executionSucceeded
        } finally {
            Save-FetchExecutionEvidence -Context $c -Succeeded $executionSucceeded -ElapsedSeconds $executionClock.Elapsed.TotalSeconds
        }
    }

Register-SequenceAction -Name 'sshWaitReady' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'network_timeout' -Severity 'soft' -SuggestedRecoveries @('retry_with_backoff','restart_from_snapshot') `
    -UsesWaitSignals $true `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_241d50d60bce8e27') `
    -Handler {
        param([hashtable]$c)
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds

        # See https://yuruna.link/4213a0b3-015f
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

        # See https://yuruna.link/4213a0b3-0160
        Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Force -Global -ErrorAction SilentlyContinue -Verbose:$false
        Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1')       -Force -Global -ErrorAction SilentlyContinue -Verbose:$false

        $logDir     = Initialize-YurunaLogDir
        $screensDir = Get-CycleScreenDir -VMName $c.VMName -WhatIf:$false
        $rawQueue = [Collections.Generic.Queue[string]]::new()
        Get-ChildItem -LiteralPath $screensDir -Filter 'raw_*.png' -File -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object { $rawQueue.Enqueue($_.FullName) }

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

            Add-OcrHistoryFrame -Queue $rawQueue -Path $rawScreenPath -Limit (Test.SequenceEngine\Get-ScreenHistorySize)
            $result = Test-CombinedOcrMatch -ImagePath $rawScreenPath -Pattern $installerFailPatterns
            if ($result.AnyText) {
                Test.SequenceEngine\Save-EngineOcrSidecar -ScreenshotPath $rawScreenPath -EngineResults $result.EngineResults
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
            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
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

Register-SequenceAction -Name 'sshExec' -ReplaySafety 'state-changing' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_84d963e1b876d615') `
    -FailureLabel { param($c) if ($c.Step.sensitive) { return 'sshExec: "***"' }; "sshExec: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
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

Register-SequenceAction -Name 'sshFetchAndExecute' -ReplaySafety 'state-changing' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description (Format-YurunaOperatorMessage -Key 'runner.operator_6ba8527c12297fee') `
    -FailureLabel { param($c) if ($c.Step.sensitive) { return 'sshFetchAndExecute: "***"' }; "sshFetchAndExecute: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $cmd     = & $c.ExpandVariable $c.Step.command $c.Vars
        $fetchContext = Get-FetchExecutionContext -Context $c -CommandLine $cmd
        $cmd = $fetchContext.Command
        $executionClock = [System.Diagnostics.Stopwatch]::StartNew()
        $executionSucceeded = $false
        try {
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        if (-not $c.Step.sensitive) { Write-Debug "      sshFetchAndExecute: $($fetchContext.Launch)" }
        $script:Fail.StepGuestAddressUnresolved = $null
        $script:Fail.StepGuestTransportLost     = $null
        $script:Fail.StepGuestRunLost           = $null
        $script:Fail.StepGuestPayloadUnavailable = $null
        # --- REGION: https://yuruna.link/4220a755-0041
        # See https://yuruna.link/4213a0b3-0161
        $detach = $null -ne $c.Step.detach ? [bool]$c.Step.detach : $true
        $detachToken = ''
        if ($detach) {
            $detachToken = Get-GuestRunToken -SequencePath $c.SequencePath -StepNumber $c.StepNum -VMName $c.VMName
        }
        $transportRetries = $null -ne $c.Step.transportRetries ? [int]$c.Step.transportRetries : 0
        $result  = Invoke-GuestSsh -VMName $c.VMName -GuestKey $c.GuestKey -Command $cmd -TimeoutSeconds $timeout `
                       -TransportRetryCount $transportRetries -DetachToken $detachToken
        Write-Debug "      sshFetchAndExecute output: $($result.output)"
        if ($result.output -match '(?m)^YURUNA_EXECUTION stepInvocationId=([A-Za-z0-9-]{1,64}) sequenceInvocationId=([A-Za-z0-9-]{1,64})\r?$') {
            if ($Matches[1] -ne $c.StepInvocationId -or $Matches[2] -ne $c.SequenceInvocationId) {
                $c.CheckpointSourceStepInvocationId = $Matches[1]
                $c.CheckpointSourceSequenceInvocationId = $Matches[2]
            }
        } elseif ($result.output -match '(?m)^YURUNA_EXECUTION stepInvocationId=([A-Za-z0-9-]{1,64})(?:\s|$)') {
            if ($Matches[1] -ne $c.StepInvocationId) { $c.CheckpointSourceStepInvocationId = $Matches[1] }
        }
        [void](Publish-GuestRetryMarker -Output $result.output -GuestKey $c.GuestKey -VmName $c.VMName)
        if (-not $result.success) {
            if (-not $result.addressResolved) { $script:Fail.StepGuestAddressUnresolved = $true }
            if ($result.transportLost) { $script:Fail.StepGuestTransportLost = $true }
            if ($result.runLost) { $script:Fail.StepGuestRunLost = $true }
            if (Test-GuestPayloadUnavailable -Output $result.output) { $script:Fail.StepGuestPayloadUnavailable = $true }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_35be02c672504936' -Arguments @{ exitCode = "$($result.exitCode)"; cmd = "$($fetchContext.Launch)" })
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
Register-SequenceAction -Name 'retry' -ReplaySafety 'composite' -HostIORequirement @() -OcrRequired $false `
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
        $configuredMaxAttempts = $maxAttempts
        $retrySuppressionReason = ''
        $innerSteps  = @($c.Step.steps)
        $installerBootRetry = ([string]$c.Step.restartVmBeforeRetry -eq 'arm64HyperVInstallerBoot')
        if ($installerBootRetry) {
            # This recovery may replay only the initial, non-credential installer
            # confirmation. Other providers retain one ordinary prompt wait.
            # Only post-confirmation stages may stand in for the prompt: the
            # parent Install/install context and the Mirror apt-config check
            # both print before Subiquity asks.
            $installerSkipPatterns = @('subiquity/Install/install/configure_apt', 'subiquity/Install/install/curtin_install')
            $installerPatterns = @('Continue with autoinstall?') + $installerSkipPatterns
            $installerBlindSkipPatterns = @('Bahasa Indonesia') + $installerSkipPatterns
            if ($innerSteps.Count -ne 1 -or
                [string]$innerSteps[0].action -ne 'waitForAndEnter' -or
                (@($innerSteps[0].pattern) -join '|') -cne ($installerPatterns -join '|') -or
                (@($innerSteps[0].skipInputPattern) -join '|') -cne ($installerSkipPatterns -join '|') -or
                (@($innerSteps[0].blindSkipPattern) -join '|') -cne ($installerBlindSkipPatterns -join '|') -or
                -not $innerSteps[0].noSegmentMatch -or
                [string]$innerSteps[0].text -cne 'yes' -or
                $innerSteps[0].sensitive -or $c.Step.stepsAfterVmRestart) {
                return $false
            }
            $maxAttempts = if (Test-Arm64HyperVColdPowerCycleMode -Mode 'arm64HyperVInstallerBoot' -HostType $c.HostType) {
                # Stop on explicit installer errors before they can become a
                # static boot screen. Clone so other invocations keep their
                # declared wait policy and non-ARM providers stay unchanged.
                $bootStep = @{}
                foreach ($key in $innerSteps[0].Keys) { $bootStep[$key] = $innerSteps[0][$key] }
                $bootStep.failurePatterns = @($bootStep.failurePatterns) + @(
                    'Bahasa Indonesia', 'install_fail.crash',
                    'Press enter to start a shell', 'An error occurred'
                ) | Where-Object { $_ }
                # A livelocked guest never shows the prompt, so the wait ends
                # when the hypervisor says so instead of spending its budget.
                $bootStep.endWaitOnGuestLivelock = $true
                $innerSteps = @($bootStep)
                [Math]::Min($maxAttempts, 2)
            } else {
                $retrySuppressionReason = 'provider is not native ARM64 Hyper-V'
                1
            }
        } elseif (Test-Arm64HyperVColdPowerCycleMode -Mode ([string]$c.Step.restartVmBeforeRetry) -HostType $c.HostType) {
            # The login wait this mode restarts on ends early on a livelocked
            # guest for the same reason. Copies, so the declared steps keep
            # their wait policy for every other invocation.
            $innerSteps = @(foreach ($innerStep in $innerSteps) {
                if ([string]$innerStep.action -eq 'waitForTextWithNudge') {
                    $loginStep = @{}
                    foreach ($key in $innerStep.Keys) { $loginStep[$key] = $innerStep[$key] }
                    $loginStep.endWaitOnGuestLivelock = $true
                    $loginStep
                } else { $innerStep }
            })
            # The post-restart recovery wait -- re-answering the installer
            # confirmation or settling into an installed guest -- can hit the
            # same livelock the cold restart was meant to clear, and it owns
            # its own long timeout (stepsAfterVmRestart runs once per restart,
            # outside the main wait this block already marks above).
            $stepsAfterVmRestartMarked = @(foreach ($afterStep in @($c.Step.stepsAfterVmRestart)) {
                if ([string]$afterStep.action -in @('waitForAndEnter', 'waitForTextWithNudge')) {
                    $afterStepCopy = @{}
                    foreach ($key in $afterStep.Keys) { $afterStepCopy[$key] = $afterStep[$key] }
                    $afterStepCopy.endWaitOnGuestLivelock = $true
                    $afterStepCopy
                } else { $afterStep }
            })
        }
        $permittedMaxAttempts = $maxAttempts
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
            $finishedVm = if (Get-Command Get-SequenceFinishedVMName -ErrorAction SilentlyContinue) { Get-SequenceFinishedVMName } else { $c.VMName }
            if ($finishedVm -and $finishedVm -ne $c.VMName) {
                $c.VMName = $finishedVm
                $c.NewVMName = $finishedVm
            }
            if ($attemptOk) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b59032415dc73ae4' -FormatValues ($c.StepNum, $c.StepCount, $attempt, $maxAttempts) -FormatBindings @{ stepNum = '0'; stepCount = '1'; attempt = '2'; maxAttempts = '3' })
                break
            }
            # See https://yuruna.link/4213a0b3-0162
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
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event        = 'retry_attempt'
                    stack        = 'sequence'
                    attempt      = [int]$attempt
                    maxAttempts  = [int]$maxAttempts
                    description  = [string]$c.Description
                    vmName       = [string]$c.VMName
                    failureClass = [string]$(if ($attemptVerbEntry) { $attemptVerbEntry.FailureClass } else { 'unknown' })
                    severity     = [string]$(if ($attemptVerbEntry) { $attemptVerbEntry.Severity }     else { 'unknown' })
                    evidencePath = [string]$evidenceRel
                    # Whether the hypervisor saw the guest livelocked when the
                    # attempt failed, so restarts it justified are queryable.
                    guestLivelocked        = [bool]$script:Fail.WaitForTextGuestLivelocked
                    guestLivelockedSeconds = [int]$(if ($script:Fail.WaitForTextGuestLivelock) { $script:Fail.WaitForTextGuestLivelock.LivelockedSeconds } else { 0 })
                    ok           = $false
                }
            }
            if ($attempt -lt $maxAttempts) {
                if ($installerBootRetry) {
                    $retrySuppressionReason = if ([string]$script:Fail.LastFailedAction -ne 'waitForAndEnter') {
                        'failed action is not installer confirmation'
                    } elseif ($script:Fail.WaitForTextMatchedFailurePattern) {
                        'installer reported a failure pattern'
                    } elseif ($script:Fail.WaitForTextConsoleFlood) {
                        'console flood prevents a safe restart'
                    } elseif ($script:Fail.WaitForTextGuestLivelocked) {
                        # The hypervisor's verdict stands in for both screen
                        # proofs below. A boot can wedge before the console
                        # prints anything -- a blank framebuffer has no casper
                        # line to read and no text to call unchanged -- yet
                        # every processor trapping in place is a stall no
                        # wait outlasts. Before the confirmation nothing is
                        # written to the target disk, so the restart costs
                        # only time. An installed system's login prompt is the
                        # one screen that says the boot phase is long past;
                        # the later login wait owns that guest.
                        if ([string]$script:Fail.WaitForTextOcrTail -match '(?im)\blogin:') {
                            'installed guest login is visible'
                        } else { '' }
                    } elseif ([string]$script:Fail.WaitForTextOcrTail -notmatch '(?i)/scripts/casper-|Setting up console keyboard') {
                        'installer is beyond the boot phase or boot phase is unproven'
                    } elseif (-not $script:Fail.WaitForTextGuestBootStalled) {
                        'independent static-guest verdict is missing'
                    } else { '' }
                }
                if ($retrySuppressionReason) {
                    # Missing or live-frame evidence is not permission to cut
                    # power. End this specialized retry without replaying input.
                    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                        Send-CycleEventSafely -EventRecord @{
                            timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                            event = 'retry_suppressed'; stack = 'sequence'
                            attempt = [int]$attempt; maxAttempts = [int]$maxAttempts
                            configuredMaxAttempts = [int]$configuredMaxAttempts
                            permittedMaxAttempts = [int]$permittedMaxAttempts
                            reason = [string]$retrySuppressionReason
                            description = [string]$c.Description; vmName = [string]$c.VMName
                        }
                    }
                    $maxAttempts = $attempt
                    break
                }
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5e0f817304f680f9' -FormatValues ($c.StepNum, $c.StepCount, $attempt, $maxAttempts, $innerSteps.Count) -FormatBindings @{ stepNum = '0'; stepCount = '1'; attempt = '2'; maxAttempts = '3'; count = '4' })
                # See https://yuruna.link/4213a0b3-0163
                $restartMode = [string]$c.Step.restartVmBeforeRetry
                $nativeArm64HyperV = Test-Arm64HyperVColdPowerCycleMode `
                    -Mode $restartMode -HostType $c.HostType
                $restartableLoginOcrTimeout = (
                    [string]$script:Fail.LastFailedAction -eq 'waitForTextWithNudge' -and
                    -not $script:Fail.WaitForTextMatchedFailurePattern -and
                    -not $script:Fail.WaitForTextConsoleFlood
                )
                if ($nativeArm64HyperV -and ($restartableLoginOcrTimeout -or $installerBootRetry)) {
                    if (-not (Invoke-Arm64HyperVColdPowerCycle -Context $c)) {
                        $script:Fail.LastFailureLabel = "retry VM cold restart failed after attempt $attempt"
                        $script:Fail.LastFailureDescription = $c.Description
                        $script:Fail.LastFailedAction = 'retry'
                        $script:Fail.LastFailedStepNumber = $c.StepNum
                        return $false
                    }

                    # Run only the explicitly declared boot-recovery steps before
                    # retrying the login wait. An incomplete install can re-answer
                    # its live-ISO confirmation; an installed guest can simply
                    # settle. These steps never run when no power cycle happened.
                    $stepsAfterVmRestart = if ($stepsAfterVmRestartMarked) { $stepsAfterVmRestartMarked } else { @($c.Step.stepsAfterVmRestart) }
                    if ($c.Step.stepsAfterVmRestart -and $stepsAfterVmRestart.Count -gt 0) {
                        $restartRecoveryOk = & $c.InvokeStepBlock -Steps $stepsAfterVmRestart `
                            -ParentOrdinal $c.StepNum -ParentAction 'retry' -ParentAttempt $attempt
                        if (-not $restartRecoveryOk) {
                            $c.OriginatingStepInvocationId = $script:Fail.OriginatingStepInvocationId
                            $c.OriginatingSequenceInvocationId = $script:Fail.OriginatingSequenceInvocationId
                            $c.OriginatingProgressAdvisory = $script:Fail.StepProgressAdvisory
                            $script:Fail.LastFailureLabel = "retry VM boot recovery failed after attempt ${attempt}: $($script:Fail.LastFailureLabel)"
                            $script:Fail.LastFailedStepNumber = $c.StepNum
                            return $false
                        }
                    }
                }
                # See https://yuruna.link/4213a0b3-0164
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
            # Keep the evidence identity as the stack restores each wrapper's
            # own ID. Nested retries forward the same deepest failed leaf.
            $c.OriginatingStepInvocationId = $script:Fail.OriginatingStepInvocationId
            $c.OriginatingSequenceInvocationId = $script:Fail.OriginatingSequenceInvocationId
            $c.OriginatingProgressAdvisory = $script:Fail.StepProgressAdvisory
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
                    timestamp    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event        = 'retry_exhausted'
                    stack        = 'sequence'
                    attempt      = [int]$maxAttempts
                    maxAttempts  = [int]$maxAttempts
                    configuredMaxAttempts = [int]$configuredMaxAttempts
                    permittedMaxAttempts = [int]$permittedMaxAttempts
                    retrySuppressionReason = [string]$retrySuppressionReason
                    description  = [string]$c.Description
                    failureClass = [string]$script:Fail.LastInnerFailureClass
                    severity     = [string]$script:Fail.LastInnerSeverity
                }
            }
            $script:Fail.LastFailureLabel = if ($retrySuppressionReason) {
                "retry stopped after $maxAttempts/$permittedMaxAttempts permitted attempts ($retrySuppressionReason): $($script:Fail.LastFailureLabel)"
            } else {
                "retry exhausted ($maxAttempts attempts): $($script:Fail.LastFailureLabel)"
            }
            $script:Fail.LastFailedStepNumber = $c.StepNum
            return $false
        }
        return $true
    }
# recoverFromSnapshot -- declarative auto-recovery primitive.
# Fires AFTER a prior step's failure when $script:Fail.LastFailedAction is
# set and matches the trigger condition. Restores a known snapshot and
# starts the VM, leaving the sequence to continue with a clean guest.
Register-SequenceAction -Name 'recoverFromSnapshot' -ReplaySafety 'restore-point' -HostIORequirement @() -OcrRequired $false `
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
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_daae4716ca62f521' -Arguments @{ lastFailedStepNumber = "$($script:Fail.LastFailedStepNumber)"; snapId = "$snapId"; vMName = "$($c.VMName)" })
        if (-not (Restore-SequenceSnapshot -c $c -snapId $snapId -HandlerName 'recoverFromSnapshot')) { return $false }
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
