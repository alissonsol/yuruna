<#PSScriptInfo
.VERSION 2026.05.29
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
        $breakSnapshotId = & $c.ExpandVariable $c.Step.id $c.Vars
        $bodyLines = @(
            "Yuruna sequence breakpoint",
            "VM:       $($c.VMName)",
            "GuestKey: $($c.GuestKey)",
            "Step:     $($c.StepNum)/$($c.StepCount)",
            "Reason:   $(if ($reason) { $reason } else { '(no reason supplied)' })",
            "Snapshot: $(if ($breakSnapshotId) { $breakSnapshotId } else { '(none -- Continue resumes without snapshot restore)' })",
            "",
            "To resume:",
            "  - Click 'Continue' in the status UI (http://localhost:8080/status/)",
            "    which restores the snapshot above (if set), starts the VM,",
            "    then deletes the marker; or",
            "  - Delete this file manually:",
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
        # expects sub-second feedback; the backoff used to cap at 59 s
        # after a handful of iterations, so a click could sit unread for
        # nearly a minute. Two Test-Path calls every 250 ms is ~8 file
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
            if ($breakSnapshotId) {
                if (Get-Command Restore-VMDiskSnapshot -ErrorAction SilentlyContinue) {
                    # Probe before restoring: a `break: id:` with no preceding
                    # saveDiskSnapshot step is a "label-only" breakpoint -- the
                    # operator named the resume point but no snapshot was ever
                    # saved. Restoring would warn "no checkpoint" + "continuing
                    # anyway" on every Continue for those sequences. Test the
                    # snapshot exists first; restore only when present, else
                    # treat the id as a label and resume the VM in place.
                    $snapPresent = $false
                    if (Get-Command Test-VMDiskSnapshot -ErrorAction SilentlyContinue) {
                        try { $snapPresent = [bool](Test-VMDiskSnapshot -VMName $c.VMName -Id $breakSnapshotId) }
                        catch { $null = $_ }
                    }
                    if (-not $snapPresent) {
                        Write-Information "    [break/continue] No snapshot '$breakSnapshotId' on $($c.VMName); resuming in place." -InformationAction Continue
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
                    }
                } else {
                    Write-Warning "    [break/continue] Restore-VMDiskSnapshot not loaded; cannot restore snapshot '$breakSnapshotId'."
                }
            }
            if (Get-Command Start-VM -ErrorAction SilentlyContinue) {
                Write-Information "    [break/continue] Starting $($c.VMName)..."
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
                Write-Warning "    [break/continue] Start-VM not loaded; VM remains stopped."
            }
            Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $breakActivePath -Force -ErrorAction SilentlyContinue
        Write-Information "    [break] Resumed (via $resumedVia)."
        return $true
    }

Register-SequenceAction -Name 'saveDiskSnapshot' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'hard' -SuggestedRecoveries @('abort_cycle') `
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
    -FailureClass 'snapshot_restore_failed' -Severity 'hard' -SuggestedRecoveries @('abort_cycle') `
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
            $failPatterns = @('FETCH AND EXECUTE FAILED:')
        }
        Write-Debug "      fetchAndExecute: waiting for '$waitPattern' (timeout: ${timeout}s, freshMatch); failurePatterns=$($failPatterns -join ', ')"
        return [bool](Wait-ForText -HostType $c.HostType -VMName $c.VMName -Pattern @($waitPattern) `
            -TimeoutSeconds $timeout -PollSeconds $poll -FreshMatch $true `
            -FreshMatchTailLines 12 -FailurePattern $failPatterns)
    }

Register-SequenceAction -Name 'sshWaitReady' -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'network_timeout' -Severity 'soft' -SuggestedRecoveries @('wait_5s_retry','restart_from_snapshot') `
    -Description 'Block until the guest accepts an SSH handshake.' `
    -Handler {
        param([hashtable]$c)
        $timeout = $c.Step.timeoutSeconds ? [int]$c.Step.timeoutSeconds : $c.DefaultTimeoutSeconds
        $poll    = $c.Step.pollSeconds    ? [int]$c.Step.pollSeconds    : $c.DefaultPollSeconds
        Write-Debug "      sshWaitReady: $($c.GuestKey)@$($c.VMName) (timeout: ${timeout}s)"
        return [bool](Wait-SshReady -VMName $c.VMName -GuestKey $c.GuestKey -TimeoutSeconds $timeout -PollSeconds $poll)
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

# No Export-ModuleMember: every public surface for this module is the
# side-effect of the Register-SequenceAction calls above, which write
# into the Test.SequenceAction registry. The engine reads from that
# registry; nothing imports symbols from here directly.
