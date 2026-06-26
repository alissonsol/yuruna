<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345672a
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
# the retry/recoverFromSnapshot split: https://yuruna.link/test/harness

# Test.HostIO carries the Invoke-HostIOAction primitive that the
# Send-Key / Send-Text / Send-Click dispatchers in Invoke-Sequence
# delegate to; Test.SequenceAction provides Register-SequenceAction
# itself. Both come in -Global so the registrations below are visible
# to the engine without Invoke-Sequence having to re-import this
# module's internals.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Force -DisableNameChecking -Global

# Bind the shared, cross-module sequence failure-state. sshWaitReady writes
# the installer-failure-pattern signal here; the engine (Invoke-Sequence)
# reads it from the SAME $global:-anchored store. Writing to a per-module
# $script: slot instead would leave the engine reading $null and mis-classify
# an installer crash as a plain timeout. See Test.SequenceFailureState.psm1.
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceFailureState.psm1') -Force -Global
$script:Fail = Get-SequenceFailureState

# OCR-tolerant matching: sshWaitReady's slow path scans the console for
# installer-failure patterns via Test-CombinedOcrMatch. It lives in
# Test.OcrMatch (extracted from the engine) and is imported -Global here so
# the handler scope resolves it instead of an unexported engine function.
Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1') -Force -Global

# retry backs off between attempts via Get-PollDelay (jittered, capped). It
# lives in Test.Backoff; import it -Global so the retry Handler below resolves
# it by bare name. Test.Backoff is stateless, so a -Force reimport wipes nothing.
Import-Module (Join-Path $PSScriptRoot 'Test.Backoff.psm1') -Force -Global

# ----------------------------------------------------------------------------
# Helpers shared by the pattern-bearing verbs (waitForText, waitForAndEnter,
# passwdPrompt). Kept private to this module -- the engine never calls them.
# ----------------------------------------------------------------------------

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
    # Returns @{ patterns; failurePatterns; timeout; poll; fresh; tailLines }
    # from a $Context. Used by waitForText / waitForAndEnter / passwdPrompt
    # Handlers so the three verbs share one expansion path.
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
    }
}

# ----------------------------------------------------------------------------
# Verb registrations. Each Register-SequenceAction binds (Name -> Handler).
# Handlers communicate with the engine via $Context:
#   $Context.Step             -- parsed YAML step (IDictionary)
#   $Context.StepNum/StepCount-- 1-based position in the sequence
#   $Context.Steps            -- full sequence (rare; retry uses it)
#   $Context.Vars             -- variable scope (writable; auto-derived
#                                fields like loginUser already merged in)
#   $Context.VMName/GuestKey/HostType -- target VM / planner identity
#   $Context.LogDir/RuntimeDir/ScreenshotDir -- per-cycle paths
#   $Context.ShowSensitive    -- when $true, masked text is logged as-is
#   $Context.SequencePath     -- path to the sequence YAML
#   $Context.ExpandVariable   -- function-reference for variable expansion
#   $Context.Default*         -- engine defaults from test.config.yml
#   $Context.WriteCurrentAction, WaitWhilePaused, InvokeStepBlock -- engine
#                                callbacks (used by break / retry-style verbs)
#   $Context.Description      -- the engine-expanded description string
# ----------------------------------------------------------------------------

Register-SequenceAction -Name 'waitForSeconds' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'wait_timeout' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description 'Sleep N seconds with progress ticks.' `
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
    -Description 'Send a single named keystroke.' `
    -FailureLabel { param($c) "pressKey: $($c.Step.name)" } `
    -Handler {
        param([hashtable]$c)
        $keyName = $c.Step.name
        Write-Debug "      Sending key '$keyName'..."
        return [bool](Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName $keyName)
    }

Register-SequenceAction -Name 'break' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'unknown' -Severity 'soft' `
    -Description 'Cooperative breakpoint; waits for operator Continue or marker-file deletion.' `
    -Handler {
        param([hashtable]$c)
        if ($env:YURUNA_BREAK_DISABLED -eq '1') {
            Write-Warning "      break: YURUNA_BREAK_DISABLED=1 -- skipping breakpoint."
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
            Write-Warning "break-active.json write failed after $breakAttempts attempts: $($breakLastErr.Exception.Message) (path=$breakActivePath)"
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
            Write-Information "    [break] Paused at step $($c.StepNum). Open $breakStatusUrl and click Continue, or delete '$markerPath' to resume."
        } else {
            Write-Information "    [break] Paused at step $($c.StepNum). Click Continue in the status UI, or delete '$markerPath' to resume."
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
        while ($true) {
            if (Test-Path -LiteralPath $breakContinueFlag) {
                $resumedVia = 'continue-button'
                Remove-Item -LiteralPath $breakContinueFlag -Force -ErrorAction SilentlyContinue
                break
            }
            if (-not (Test-Path -LiteralPath $markerPath)) { break }
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
                    Write-Warning "    [break/continue] restoreOnContinue is set but the step has no 'id'; nothing to restore -- resuming in place."
                } elseif (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
                    Write-Warning "    [break/continue] Restore-VMDiskSnapshot not loaded; cannot restore snapshot '$breakSnapshotId'."
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
                        Write-Information "    [break/continue] restoreOnContinue set but no snapshot '$breakSnapshotId' on $($c.VMName); resuming in place." -InformationAction Continue
                    } else {
                        Write-Information "    [break/continue] Restoring snapshot '$breakSnapshotId' on $($c.VMName)..." -InformationAction Continue
                        try {
                            $restored = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $breakSnapshotId -Confirm:$false)
                            if (-not $restored) { Write-Warning "    [break/continue] Restore-VMDiskSnapshot returned `$false; continuing anyway." }
                        } catch {
                            # YurunaCycleRestart is a control-flow marker; re-throw before the
                            # generic handler turns it into "continuing anyway", which would
                            # leave control.cycle-restart unconsumed by the cycle-level catch.
                            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
                            Write-Warning "    [break/continue] Restore-VMDiskSnapshot threw: $($_.Exception.Message). Continuing anyway."
                        }
                        # Restore-VMDiskSnapshot stops the VM to swap the disk, so
                        # bring it back up. Only needed on this path -- a plain
                        # breakpoint leaves the VM running and must not restart it.
                        if (Get-Command Start-VM -ErrorAction SilentlyContinue) {
                            Write-Information "    [break/continue] Starting $($c.VMName)..." -InformationAction Continue
                            try {
                                $startRes = Start-VM -VMName $c.VMName -Confirm:$false
                                if ($startRes -is [hashtable] -and -not $startRes.success) {
                                    Write-Warning "    [break/continue] Start-VM returned failure: $($startRes.errorMessage). Continuing anyway."
                                }
                            } catch {
                                if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
                                Write-Warning "    [break/continue] Start-VM threw: $($_.Exception.Message). Continuing anyway."
                            }
                        } else {
                            Write-Warning "    [break/continue] Start-VM not loaded; VM remains stopped after restore."
                        }
                    }
                }
            }
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $breakActivePath -Force -ErrorAction SilentlyContinue
        Write-Information "    [break] Resumed (via $resumedVia)."
        return $true
    }

Register-SequenceAction -Name 'saveDiskSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'hard' -SuggestedRecoveries @('operator_intervention_required') `
    -Description 'Save-VMDiskSnapshot with a sequence-local id.' `
    -FailureLabel { param($c) "saveDiskSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning "      saveDiskSnapshot: missing required 'id' field."; return $false }
        if (-not (Get-Command Save-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
            Write-Warning "      saveDiskSnapshot: Save-VMDiskSnapshot not loaded (Yuruna.Host import missing)."
            return $false
        }
        Write-Debug "      Saving disk snapshot '$snapId' for $($c.VMName)"
        $ok = $false
        try { $ok = [bool](Save-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch {
            # YurunaCycleRestart is a control-flow marker -- re-throw so
            # the cycle-level handler in Invoke-TestInnerRunner consumes
            # control.cycle-restart; otherwise the warning + return $false
            # turns the marker into a soft step failure and the flag
            # re-fires on every subsequent sequence.
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            Write-Warning "      saveDiskSnapshot: $($_.Exception.Message)"; return $false
        }
        if ($ok -and $c.VMName -ne $snapId) {
            Write-Information "      saveDiskSnapshot: VM renamed '$($c.VMName)' -> '$snapId'; subsequent steps will target '$snapId'." -InformationAction Continue
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
            $null = Write-SnapshotManifest -VMName $effectiveVm -SnapshotId $snapId -HostType $c.HostType -Confirm:$false
        }
        return $ok
    }

Register-SequenceAction -Name 'loadDiskSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'snapshot_restore_failed' -Severity 'hard' -SuggestedRecoveries @('operator_intervention_required') `
    -Description 'Restore-VMDiskSnapshot by id, then Start-VM.' `
    -FailureLabel { param($c) "loadDiskSnapshot: `"$(& $c.ExpandVariable $c.Step.id $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $snapId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $snapId) { Write-Warning "      loadDiskSnapshot: missing required 'id' field."; return $false }
        if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue)) {
            Write-Warning "      loadDiskSnapshot: Restore-VMDiskSnapshot not loaded (Yuruna.Host import missing)."
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
                Write-Warning "      loadDiskSnapshot: Test-VMDiskSnapshot threw ($($_.Exception.Message)); proceeding with restore attempt."
                $snapExists = $true
            }
            if (-not $snapExists) {
                Write-Warning "      loadDiskSnapshot: snapshot '$snapId' not found on $($c.VMName); aborting restore."
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
                Write-Warning "      loadDiskSnapshot: manifest mismatch for '$snapId' on $($c.VMName); aborting restore. $($check.Violations -join '; ')"
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
                Write-Warning "      loadDiskSnapshot: no manifest for '$snapId' on $($c.VMName); proceeding (legacy snapshot)."
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
            Write-Warning "      loadDiskSnapshot: Start-VM not loaded; cannot start '$($c.VMName)' after restore."
            return $false
        }
        Write-Debug "      Starting $($c.VMName) after snapshot restore"
        try {
            $startRes = Start-VM -VMName $c.VMName -Confirm:$false
            if ($startRes -is [hashtable] -and -not $startRes.success) {
                Write-Warning "      loadDiskSnapshot: Start-VM returned failure: $($startRes.errorMessage)"
                return $false
            }
        } catch {
            if ($_.Exception.Message -like 'YurunaCycleRestart:*') { throw }
            Write-Warning "      loadDiskSnapshot: Start-VM threw: $($_.Exception.Message)"; return $false
        }
        return $true
    }

Register-SequenceAction -Name 'saveSystemDiagnostic' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'instrumentation_failure' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description 'SSH-driven post-mortem capture (logs, processes, network state).' `
    -Handler {
        param([hashtable]$c)
        $diagId = & $c.ExpandVariable $c.Step.id $c.Vars
        if (-not $diagId) { Write-Warning "      saveSystemDiagnostic: missing required 'id' field."; return $false }
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
            Write-Warning "      saveSystemDiagnostic: no cycle folder established; skipping."
            return $true
        }
        Write-Debug "      Capturing diagnostic '$diagId' from $($c.VMName) to $diagFolder"
        $diagManifest = $null
        try { $diagManifest = Save-GuestDiagnostic -VMName $c.VMName -GuestKey $c.GuestKey -OutputFolder $diagFolder -Id $diagId }
        catch { Write-Warning "      saveSystemDiagnostic: $($_.Exception.Message)" }
        # Emit one NDJSON line so an autonomous remediator sees the
        # capture outcome (mechanism, attempts, bytes) without parsing
        # the diagnostic file body. Best-effort: Write-CycleNdjsonEvent
        # already self-degrades on failure.
        if ($diagManifest -is [hashtable]) {
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
            }
        }
        return $true
    }

Register-SequenceAction -Name 'callExtension' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'extension_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description 'Side-effecting call into the active extension for an area.' `
    -Handler {
        param([hashtable]$c)
        $methodFqn = [string]$c.Step.method
        if (-not $methodFqn -or $methodFqn -notmatch '^([A-Za-z0-9_]+)\.([A-Za-z][A-Za-z0-9_-]*)$') {
            throw "callExtension: 'method' must be 'area.Method' (got '$methodFqn')."
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
        catch { Write-Warning "callExtension $callArea.$callMethod failed: $($_.Exception.Message)"; return $false }
    }

Register-SequenceAction -Name 'inputText' -HostIORequirement @('Send-Text') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description 'Type a text string into the guest GUI.' `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' (charDelay=${charDelay}ms)"
        return [bool](Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape)
    }

Register-SequenceAction -Name 'inputTextAndEnter' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
    -Aliases @('typeAndEnter') `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description 'Type a text string + Enter, with a drain pause.' `
    -FailureLabel { param($c) [string]$c.Step.action } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        $ok = Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape
        if ($ok -eq $false) { return $false }
        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
        for ($r = $delaySecsInt; $r -gt 0; $r--) {
            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
            Write-ProgressTick -Activity 'inputTextAndEnter' -Status "drain ${r}s" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'inputTextAndEnter' -Completed
        Start-Sleep -Milliseconds 800
        return [bool](Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter')
    }

Register-SequenceAction -Name 'networkRelease' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' -SuggestedRecoveries @('retry_immediately') `
    -Description 'Release the guest DHCP lease / network resources at end of sequence so the address returns to the pool.' `
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
            $ok = Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $cmd -CharDelayMs $charDelay -ShellEscape
            if ($ok -eq $false) { return $false }
            Start-Sleep -Milliseconds 800
            return [bool](Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter')
        }
        # TODO(windows.11): implement DHCP lease release for Windows guests
        # (e.g. `ipconfig /release`). Left as a no-op reminder until the
        # Windows.11 guest path is wired up.
        if ($guest -match 'windows') {
            Write-Warning "      networkRelease: Windows guest release not implemented yet (TODO windows.11) -- skipping for '$guest'."
            return $true
        }
        Write-Warning "      networkRelease: no release path for guest '$guest' -- skipping."
        return $true
    }

Register-SequenceAction -Name 'waitForText' -HostIORequirement @() -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description 'OCR-poll the guest framebuffer for one of N patterns.' `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "waitForText: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s$(if ($p.fresh) { ', freshMatch' })$(if ($p.failurePatterns.Count) { ", $($p.failurePatterns.Count) failurePatterns" }))"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -FailurePattern $p.failurePatterns)
    }

Register-SequenceAction -Name 'waitForAndEnter' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description 'waitForText then typeAndEnter.' `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "waitForAndEnter: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s)"
        $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -FailurePattern $p.failurePatterns
        if ($ok -eq $false) { return $false }
        $tabCount = $c.Step.tabCount ? [int]$c.Step.tabCount : 0
        if ($tabCount -gt 0) {
            Write-Debug "      Sending $tabCount Tab(s) to reach the target element"
            for ($t = 0; $t -lt $tabCount; $t++) {
                Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Tab' | Out-Null
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep -Milliseconds 500
        }
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $text
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        $ok = Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape
        if ($ok -eq $false) { return $false }
        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
        for ($r = $delaySecsInt; $r -gt 0; $r--) {
            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
            Write-ProgressTick -Activity 'waitForAndEnter' -Status "drain ${r}s" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'waitForAndEnter' -Completed
        Start-Sleep -Milliseconds 800
        return [bool](Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter')
    }

Register-SequenceAction -Name 'passwdPrompt' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'credential_expired' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description 'waitForText + typed password (sensitive: redacts in logs).' `
    -FailureLabel { param($c)
        $pd = Format-SequencePatternLabel -Step $c.Step -Vars $c.Vars -ExpandVariable $c.ExpandVariable
        "passwdPrompt: `"$pd`""
    } `
    -Handler {
        param([hashtable]$c)
        $p = Resolve-WaitForTextStepParam -Context $c
        $patternDisplay = $p.patterns -join "' | '"
        Write-Debug "      Watching screen for: '$patternDisplay' (timeout: $($p.timeout)s)"
        $ok = Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern $p.patterns `
            -TimeoutSeconds $p.timeout -PollSeconds $p.poll -FreshMatch $p.fresh `
            -FreshMatchTailLines $p.tailLines -FailurePattern $p.failurePatterns
        if ($ok -eq $false) { return $false }
        $tabCount = $c.Step.tabCount ? [int]$c.Step.tabCount : 0
        if ($tabCount -gt 0) {
            Write-Debug "      Sending $tabCount Tab(s) to reach the target element"
            for ($t = 0; $t -lt $tabCount; $t++) {
                Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Tab' | Out-Null
                Start-Sleep -Milliseconds 300
            }
            Start-Sleep -Milliseconds 500
        }
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $masked = $c.ShowSensitive ? $text : '***'
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      Typing: '$masked' + Enter (charDelay=${charDelay}ms, delay ${delaySeconds}s)"
        $ok = Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay
        if ($ok -eq $false) { return $false }
        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
        for ($r = $delaySecsInt; $r -gt 0; $r--) {
            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
            Write-ProgressTick -Activity 'passwdPrompt' -Status "drain ${r}s" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'passwdPrompt' -Completed
        Start-Sleep -Milliseconds 800
        return [bool](Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter')
    }

Register-SequenceAction -Name 'tapOn' -HostIORequirement @('Send-Click') -OcrRequired $true `
    -FailureClass 'ocr_timeout' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot') `
    -Description 'OCR-locate a pattern then click its on-screen rectangle.' `
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
    -Description 'Capture a host-side screenshot and persist it.' `
    -Handler {
        param([hashtable]$c)
        $label = $c.Step.label ?? "step$($c.StepNum)"
        Save-DebugScreenshot -VMName $c.VMName -Label $label -OutputDir $c.ScreenshotDir | Out-Null
        return $true
    }

Register-SequenceAction -Name 'fetchAndExecute' -HostIORequirement @('Send-Text', 'Send-Key') -OcrRequired $true `
    -FailureClass 'pattern_matched_failure' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description 'Type a command + Enter then wait for a freshMatch completion pattern.' `
    -FailureLabel { param($c) "fetchAndExecute: `"$(& $c.ExpandVariable $c.Step.text $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $text = & $c.ExpandVariable $c.Step.text $c.Vars
        $delaySeconds = $c.Step.delaySeconds ? [double]$c.Step.delaySeconds : 2
        $charDelay = $c.Step.charDelayMs ? [int]$c.Step.charDelayMs : $c.DefaultCharDelayMs
        Write-Debug "      fetchAndExecute: typing '$text' + Enter"
        $ok = Invoke-Sequence\Send-Text -HostType $c.HostType -VMName $c.VMName -Text $text -CharDelayMs $charDelay -ShellEscape
        if ($ok -eq $false) { return $false }
        $delaySecsInt = [int][math]::Ceiling($delaySeconds)
        for ($r = $delaySecsInt; $r -gt 0; $r--) {
            $pct = [math]::Round((($delaySecsInt - $r) / [math]::Max($delaySecsInt,1)) * 100)
            Write-ProgressTick -Activity 'fetchAndExecute' -Status "drain ${r}s" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'fetchAndExecute' -Completed
        Start-Sleep -Milliseconds 800
        $ok = Invoke-Sequence\Send-Key -HostType $c.HostType -VMName $c.VMName -KeyName 'Enter'
        if ($ok -eq $false) { return $false }
        $waitPattern = & $c.ExpandVariable $c.Step.waitPattern $c.Vars
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        $failPatterns = @()
        if ($c.Step.failPattern) {
            $failPatterns = @(& $c.ExpandVariable $c.Step.failPattern $c.Vars)
        } elseif ($waitPattern -match '^\s*FETCHED AND EXECUTED:') {
            # Must stay in sync with automation/fetch-and-execute.sh. The marker
            # avoids the words "fetch"/"execute" on purpose: Test-OCRMatch is
            # fuzzy, so a failure pattern containing them fuzzy-matches the
            # echoed 'fetch-and-execute.sh ...' command line on the first poll
            # and fails a healthy run in ~4 s before any output appears (the
            # false-failure class). "NONZERO" can't collide with a command or
            # normal script output.
            $failPatterns = @('NONZERO SCRIPT EXIT:')
        }
        Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${timeout}s, freshMatch); failurePatterns=$($failPatterns -join ', ')"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern @($waitPattern) `
            -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $true `
            -FreshMatchTailLines 12 -FailurePattern $failPatterns)
    }

Register-SequenceAction -Name 'sshWaitReady' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'network_timeout' -Severity 'soft' -SuggestedRecoveries @('retry_with_backoff','restart_from_snapshot') `
    -Description 'Block until the guest accepts an SSH handshake.' `
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
        # yuruna_retry exp-backoff auto-retry in Invoke-TestInnerRunner so
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
            $remainingSec = [int]($deadlineUtc - [DateTime]::UtcNow).TotalSeconds
            if ($remainingSec -le 0) { break }
            $thisChunk = [Math]::Min($chunkSeconds, $remainingSec)
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
            Write-Warning "      sshWaitReady: installer-failure pattern matched: '$matchedPattern' -- aborting wait early"
            $failScreenPath = Join-Path $logDir "failure_screenshot_$($c.VMName).png"
            Copy-Item -Path $rawScreenPath -Destination $failScreenPath -Force -ErrorAction SilentlyContinue
            Write-Information "      Failure screenshot saved: $failScreenPath (sequence: $screensDir)"
            if ($result.AnyText) {
                $failOcrPath = Join-Path $logDir "failure_ocr_$($c.VMName).txt"
                Set-Content -Path $failOcrPath -Value $result.AnyText -Force -ErrorAction SilentlyContinue
                Write-Information "      Failure OCR text saved: $failOcrPath"
                # Bounded tail + the sought patterns into causeDetail (set on
                # failure only, so a successful wait can't leak them).
                $script:Fail.WaitForTextOcrTail = if ($result.AnyText.Length -le 1200) { $result.AnyText } else { $result.AnyText.Substring($result.AnyText.Length - 1200) }
                $script:Fail.WaitForTextPatternsSought = [string[]]@($installerFailPatterns)
            }
            return $false
        }
        Write-Warning "      sshWaitReady: SSH did not become ready within ${timeout}s and no installer-failure pattern matched"
        return $false
    }

Register-SequenceAction -Name 'sshExec' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description 'Run a one-shot command over SSH.' `
    -FailureLabel { param($c) "sshExec: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $cmd     = & $c.ExpandVariable $c.Step.command $c.Vars
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $masked  = ($c.Step.sensitive -and -not $c.ShowSensitive) ? '***' : $cmd
        Write-Debug "      sshExec: $masked"
        $result  = Invoke-GuestSsh -VMName $c.VMName -GuestKey $c.GuestKey -Command $cmd -TimeoutSeconds $timeout
        Write-Debug "      sshExec output: $($result.output)"
        if (-not $result.success) {
            if ($c.Step.allowFailure -eq $true) {
                Write-Debug "      sshExec exit=$($result.exitCode) (allowFailure=true)"
                return $true
            }
            Write-Warning "      sshExec failed (exit=$($result.exitCode)): $masked"
            if ($result.output) { Write-Warning "      output: $($result.output)" }
            return $false
        }
        return $true
    }

Register-SequenceAction -Name 'sshFetchAndExecute' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'script_error' -Severity 'hard' -SuggestedRecoveries @('pause_and_inspect') `
    -Description 'fetchAndExecute over SSH (no OCR, no host-I/O keystrokes).' `
    -FailureLabel { param($c) "sshFetchAndExecute: `"$(& $c.ExpandVariable $c.Step.command $c.Vars)`"" } `
    -Handler {
        param([hashtable]$c)
        $cmd     = & $c.ExpandVariable $c.Step.command $c.Vars
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        Write-Debug "      sshFetchAndExecute: $cmd"
        $result  = Invoke-GuestSsh -VMName $c.VMName -GuestKey $c.GuestKey -Command $cmd -TimeoutSeconds $timeout
        Write-Debug "      sshFetchAndExecute output: $($result.output)"
        if (-not $result.success) {
            Write-Warning "      sshFetchAndExecute failed (exit=$($result.exitCode)): $cmd"
            if ($result.output) { Write-Warning "      output: $($result.output)" }
            return $false
        }
        return $true
    }

# ---------------------------------------------------------------------------
# retry / recoverFromSnapshot: these coordinate the cross-module failure state
# in Test.SequenceFailureState ($script:Fail, bound above). retry re-runs an
# inner steps block; recoverFromSnapshot restores a snapshot after a prior step
# failed. They live here with the rest of the verb catalog so the engine stays
# a pure executor.
# ---------------------------------------------------------------------------
Register-SequenceAction -Name 'retry' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'retry_exhausted' -Severity 'hard' -SuggestedRecoveries @('restart_from_snapshot','pause_and_inspect') `
    -Description 'Wrap inner steps with restart-on-failure semantics.' `
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
            Write-Warning "    [$($c.StepNum)/$($c.StepCount)] retry block has no inner steps; treating as failure."
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
            # blow past stepTimeoutMinutes without ever signalling
            # proof-of-life. Per-attempt refresh keeps the watchdog
            # aligned with reality.
            try {
                $stepHbFile = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat'
                [System.IO.File]::WriteAllText($stepHbFile, [DateTime]::UtcNow.ToString('o'))
            } catch {
                Write-Verbose "runner.stepHeartbeat refresh (retry loop) failed: $($_.Exception.Message)"
            }
            Write-Information ("    [{0}/{1}] retry attempt {2}/{3}: {4}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts, $c.Description)
            $attemptOk = & $c.InvokeStepBlock -Steps $innerSteps -ParentOrdinal $c.StepNum -ParentAction 'retry'
            if ($attemptOk) {
                Write-Information ("    [{0}/{1}] retry succeeded on attempt {2}/{3}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts)
                break
            }
            if ($attempt -lt $maxAttempts) {
                Write-Warning ("    [{0}/{1}] retry attempt {2}/{3} failed; restarting from step 1 of {4}" -f $c.StepNum, $c.StepCount, $attempt, $maxAttempts, $innerSteps.Count)
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
    -Description 'Auto-recovery: when the prior step failed, restore a snapshot and start the VM.' `
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
        if (-not $snapId) { Write-Warning "      recoverFromSnapshot: missing required 'id' field."; return $false }
        if (-not (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue) -or `
            -not (Get-Command Start-VM -ErrorAction SilentlyContinue)) {
            Write-Warning "      recoverFromSnapshot: Restore-VMDiskSnapshot or Start-VM not loaded; cannot recover."
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
                Write-Warning "      recoverFromSnapshot: Test-VMDiskSnapshot threw ($($_.Exception.Message)); proceeding with restore attempt."
                $snapExists = $true
            }
            if (-not $snapExists) {
                Write-Warning "      recoverFromSnapshot: snapshot '$snapId' not found on $($c.VMName); aborting restore. Manual intervention required."
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
                Write-Warning "      recoverFromSnapshot: manifest mismatch for '$snapId' on $($c.VMName); aborting restore. $($check.Violations -join '; ')"
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
                Write-Warning "      recoverFromSnapshot: no manifest for '$snapId' on $($c.VMName); proceeding (legacy snapshot)."
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    event      = 'snapshot_manifest_missing'
                    vmName     = [string]$c.VMName
                    snapshotId = [string]$snapId
                    handler    = 'recoverFromSnapshot'
                }
            }
        }
        Write-Information "      recoverFromSnapshot: prior step $script:Fail.LastFailedStepNumber failed; restoring '$snapId' on $($c.VMName)."
        try { $restored = [bool](Restore-VMDiskSnapshot -VMName $c.VMName -Id $snapId -Confirm:$false) }
        catch { Write-Warning "      recoverFromSnapshot: $($_.Exception.Message)"; return $false }
        if (-not $restored) { return $false }
        try {
            $startRes = Start-VM -VMName $c.VMName -Confirm:$false
            if ($startRes -is [hashtable] -and -not $startRes.success) {
                Write-Warning "      recoverFromSnapshot: Start-VM returned failure: $($startRes.errorMessage)"
                return $false
            }
        } catch { Write-Warning "      recoverFromSnapshot: Start-VM threw: $($_.Exception.Message)"; return $false }
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
