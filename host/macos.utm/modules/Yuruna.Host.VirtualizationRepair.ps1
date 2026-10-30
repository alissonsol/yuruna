<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42962b36-68ce-45e4-a001-c18ffad41207
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver virtualization repair
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

# --- REGION: Virtualization repair
# --- REGION: Test-VirtualizationResponsive
function Test-VirtualizationResponsive {
    <#
    .SYNOPSIS
        Bounded probe of UTM's control channel. Returns the versioned
        Yuruna.VirtualizationProbe record (schema version 1).
    .DESCRIPTION
        Evaluated in order, each step bounded by the probe's own deadline (the
        smaller of -TimeoutSeconds and what -Deadline has left):
          1. utmctl on PATH or in the UTM bundle; none -> Undetermined/missing-client.
          2. the GUI session; anything but Aqua -> Undetermined/no-session, and
             utmctl is not invoked (from SSH it can only fail, or hang on a
             consent dialog nobody can see).
          3. the same-user UTM process census, with no Apple Event; positively
             no UTM and no helper -> Unresponsive/app-stopped, and utmctl is not
             invoked (an Apple Event to a UTM that is not running launches it).
          4. `utmctl list`: a recognized listing -> Responsive; Apple Event
             denial (-1743) -> Undetermined/permission-denied; an SSH refusal ->
             no-session; another OSStatus failure -> provider-error; output not
             fully drained or cut at the cap -> invalid-response even at exit 0;
             anything unrecognized -> invalid-response; a cap hit or -1712 -> a
             timeout candidate.
          5. with -LifecycleProbe, after a recognized listing: `utmctl stop` on
             a VM that listing shows as stopped. UTM has a wedge in which
             enumeration keeps answering while every lifecycle verb (start,
             stop, delete) waits out the Apple Event timeout; a listing alone
             rates that UTM responsive, and a start issued into it burns its
             whole timeout. A stop sent to a VM already stopped changes
             nothing on a healthy UTM and returns at once, so it is the one
             lifecycle round trip that is safe to send unasked. The VM is
             chosen from this probe's own listing (never from an earlier
             read), preferring names under -LifecycleProbePrefix; with no
             stopped VM the step is skipped and recorded as such, and the
             listing's verdict stands. The verb answering at all -- even with
             a refusal -- is responsive; a cap hit or -1712 is a timeout
             candidate.
        A timeout is not, by itself, evidence that UTM is hung: an unanswered
        Automation consent dialog blocks the sender and looks exactly like one.
        Without -Corroborate a timeout is Undetermined/timeout. With
        -Corroborate the probe waits out -DialogWindowSeconds, re-reads the
        process census, and probes once more; only a second timeout, with UTM
        positively still running, no Apple Event denial, and this process's
        Automation subject among -RecordedAutomationSubject, is
        Unresponsive/timeout with corroborated=$true. A later denial, a missing
        session or an unclassified answer on the second probe invalidates the
        first. When the deadline cannot fit the window plus one probe the result
        stays Undetermined/timeout.

        A lifecycle timeout is corroborated on different grounds: the listing
        that preceded it in the same probe is a completed round trip under this
        process's own grant, so a consent dialog cannot be what held the verb.
        The wait before the second probe is therefore -LifecycleRetryWindowSeconds
        rather than the dialog window, and a second lifecycle timeout is
        Unresponsive/timeout with corroborated=$true whether or not the
        Automation subject was recorded. The reason token stays 'timeout' so
        the restart gate reads it as the control timeout it is; which path hung
        is in evidence.lifecycle.

        Read-only apart from that one no-op stop: never writes, never repairs
        the utmctl link, never throws. Diagnostic text goes only to the private
        'diagnostic' field.
    .PARAMETER TimeoutSeconds
        Cap for each utmctl call.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline).
    .PARAMETER Corroborate
        Qualify a timeout as described above.
    .PARAMETER DialogWindowSeconds
        How long a consent dialog is given to be answered before the second probe.
    .PARAMETER RecordedAutomationSubject
        Automation subjects previously seen to complete a responsive round trip.
    .PARAMETER IncludeInventory
        With a Responsive result, attach the parsed listing as 'inventory'.
    .PARAMETER LifecycleProbe
        Also exercise one lifecycle verb, as described in step 5.
    .PARAMETER LifecycleProbePrefix
        Name prefixes preferred when choosing the stopped VM for step 5.
    .PARAMETER LifecycleRetryWindowSeconds
        The pause before the second probe when the first failure was a
        lifecycle timeout after an answered listing.
    .OUTPUTS
        [pscustomobject] PSTypeName 'Yuruna.VirtualizationProbe': schemaVersion,
        hostType, state, reason, started, timedOut, deadlineExhausted,
        corroborated, observedUtc, observedTick, elapsedMs, evidence
        {utmctlSource; sessionKind; appState; automationGrant; exitCode;
        drainTimedOut; outputTruncated; lifecycle {attempted; verb; vmName;
        outcome ('not-attempted' | 'skipped-no-stopped-vm' | 'responsive' |
        'timeout' | 'deadline-exhausted'); exitCode; timedOut}}, diagnostic,
        automationSubject, inventory.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20,
        $Deadline,
        [switch]$Corroborate,
        [ValidateRange(0, 600)][int]$DialogWindowSeconds = 120,
        [string[]]$RecordedAutomationSubject = @(),
        [switch]$IncludeInventory,
        [switch]$LifecycleProbe,
        [string[]]$LifecycleProbePrefix = @(),
        [ValidateRange(0, 600)][int]$LifecycleRetryWindowSeconds = 15
    )
    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $facts = [ordered]@{
        utmctlSource = 'missing'; sessionKind = 'Unknown'; appState = 'unknown'; automationGrant = 'unknown'
        exitCode = -1; drainTimedOut = $false; outputTruncated = $false
        started = $false; timedOut = $false; deadlineExhausted = $false; corroborated = $false
        diagnostic = ''; subject = ''; inventory = $null; rows = @()
        lifecycle = [ordered]@{ attempted = $false; verb = 'stop'; vmName = ''; outcome = 'not-attempted'; exitCode = -1; timedOut = $false }
    }
    $emit = {
        param([string]$State, [string]$Reason)
        $record = New-YurunaVirtualizationProbeRecord -HostType 'host.macos.utm' -State $State -Reason $Reason `
            -Started ([bool]$facts.started) -TimedOut ([bool]$facts.timedOut) -DeadlineExhausted ([bool]$facts.deadlineExhausted) `
            -Corroborated ([bool]$facts.corroborated) -ObservedUtc $observedUtc -ObservedTick ([long](Get-UtmClockTick -Deadline $Deadline)) `
            -ElapsedMs ([long]$stopwatch.ElapsedMilliseconds) -Evidence ([ordered]@{
                utmctlSource    = [string]$facts.utmctlSource
                sessionKind     = [string]$facts.sessionKind
                appState        = [string]$facts.appState
                automationGrant = [string]$facts.automationGrant
                exitCode        = [int]$facts.exitCode
                drainTimedOut   = [bool]$facts.drainTimedOut
                outputTruncated = [bool]$facts.outputTruncated
                lifecycle       = [pscustomobject]@{
                    attempted = [bool]$facts.lifecycle.attempted
                    verb      = [string]$facts.lifecycle.verb
                    vmName    = [string]$facts.lifecycle.vmName
                    outcome   = [string]$facts.lifecycle.outcome
                    exitCode  = [int]$facts.lifecycle.exitCode
                    timedOut  = [bool]$facts.lifecycle.timedOut
                }
            }) -Diagnostic (ConvertTo-UtmDiagnosticText -Text ([string]$facts.diagnostic))
        # The two fields only the UTM probe has, after the common ones.
        $record | Add-Member -NotePropertyName automationSubject -NotePropertyValue ([string]$facts.subject)
        $record | Add-Member -NotePropertyName inventory -NotePropertyValue $facts.inventory
        $record
    }
    # One bounded utmctl list, classified; returns the probe-level verdict
    # ('responsive', 'timeout', or an Undetermined reason) and records facts.
    $probeOnce = {
        param($Window, [string]$UtmctlPath, [int]$CapSeconds, [bool]$WithInventory)
        $listing = Invoke-UtmctlProbe -Arguments @('list') -TimeoutSeconds $CapSeconds -UtmctlPath $UtmctlPath -Deadline $Window -Quiet
        $facts.timedOut        = $false
        $facts.started         = [bool]$listing['Started']
        $facts.exitCode        = [int]$listing['ExitCode']
        $facts.drainTimedOut   = [bool]$listing['DrainTimedOut']
        $facts.outputTruncated = [bool]$listing['OutputTruncated']
        $facts.diagnostic      = "$($listing['StdOut'])`n$($listing['StdErr'])"
        if ($listing['DeadlineExhausted']) { $facts.deadlineExhausted = $true; return 'deadline-exhausted' }
        if (-not $listing['Started']) { return 'missing-client' }
        if ($listing['TimedOut']) { $facts.timedOut = $true; return 'timeout' }
        $parsed = ConvertFrom-UtmctlListResult -Result $listing
        if ($parsed.Reason -eq 'timeout') { $facts.timedOut = $true; return 'timeout' }
        if (-not $parsed.Recognized) { return [string]$parsed.Reason }
        $facts.rows = @($parsed.Row)
        if ($WithInventory) { $facts.inventory = ConvertTo-UtmInventoryRecord -Parsed $parsed }
        return 'responsive'
    }
    # One bounded no-op lifecycle verb against a VM this probe's own listing
    # shows stopped; returns 'responsive', 'timeout' or 'deadline-exhausted',
    # and records the attempt. With no stopped VM the listing's verdict stands.
    $preferredPrefix = [string[]]@($LifecycleProbePrefix | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
    $probeLifecycle = {
        param($Window, [int]$CapSeconds)
        $stopped = @($facts.rows | Where-Object { "$($_.Status)" -eq 'stopped' -and -not [string]::IsNullOrWhiteSpace("$($_.Name)") })
        $preferred = @($stopped | Where-Object {
                $name = "$($_.Name)"
                [bool]@($preferredPrefix | Where-Object { $name.StartsWith([string]$_, [System.StringComparison]::OrdinalIgnoreCase) }).Count
            })
        $pool = if ($preferred.Count -gt 0) { $preferred } else { $stopped }
        $candidate = @($pool | Sort-Object { [string]$_.Name } | Select-Object -First 1)
        if ($candidate.Count -eq 0) {
            $facts.lifecycle.outcome = 'skipped-no-stopped-vm'
            return 'responsive'
        }
        $vmName = [string]$candidate[0].Name
        $facts.lifecycle.attempted = $true
        $facts.lifecycle.vmName = $vmName
        $verb = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $vmName -TimeoutSeconds $CapSeconds -Deadline $Window -Quiet
        $facts.lifecycle.exitCode = [int]$verb['ExitCode']
        $facts.lifecycle.timedOut = [bool]$verb['TimedOut']
        if ($verb['Text']) { $facts.diagnostic = "$($facts.diagnostic)`nstop $vmName`: $($verb['Text'])" }
        if ($verb['DeadlineExhausted']) { $facts.lifecycle.outcome = 'deadline-exhausted'; $facts.deadlineExhausted = $true; return 'deadline-exhausted' }
        if ($verb['TimedOut'] -or (Get-UtmAppleEventReason -Text ([string]$verb['Text'])) -eq 'timeout') {
            $facts.lifecycle.outcome = 'timeout'
            $facts.lifecycle.timedOut = $true
            $facts.timedOut = $true
            return 'timeout'
        }
        $facts.lifecycle.outcome = 'responsive'
        return 'responsive'
    }
    try {
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            $facts.deadlineExhausted = $true
            return (& $emit 'Undetermined' 'deadline-exhausted')
        }
        $resolver = Resolve-UtmctlExecutable
        $facts.utmctlSource = $resolver.Source
        if ($resolver.Source -eq 'missing') { return (& $emit 'Undetermined' 'missing-client') }

        $facts.sessionKind = Get-UtmProbeSessionKind -Deadline $Deadline
        if ($facts.sessionKind -ne 'Aqua') { return (& $emit 'Undetermined' 'no-session') }

        $facts.subject = Get-UtmAutomationSubject -Deadline $Deadline
        if (Test-UtmAutomationSubjectQualified -Subject $facts.subject -RecordedSubject $RecordedAutomationSubject) { $facts.automationGrant = 'recorded' }

        $app = Get-UtmApplicationState -Deadline $Deadline
        $facts.appState = $app.State
        if ($app.State -eq 'absent') { return (& $emit 'Unresponsive' 'app-stopped') }

        $first = & $probeOnce $Deadline $resolver.Path $TimeoutSeconds ([bool]$IncludeInventory)
        $lifecycleHeld = $false
        if ($first -eq 'responsive' -and $LifecycleProbe) {
            $first = & $probeLifecycle $Deadline $TimeoutSeconds
            $lifecycleHeld = ($first -eq 'timeout')
        }
        if ($first -eq 'responsive') { return (& $emit 'Responsive' 'responsive') }
        if ($first -ne 'timeout') { return (& $emit 'Undetermined' $first) }
        if (-not $Corroborate) { return (& $emit 'Undetermined' 'timeout') }

        # Corroboration needs the whole dialog window and one more probe of
        # at least a second; a deadline that cannot fit both leaves the
        # timeout uncorroborated rather than cutting the window short. A
        # lifecycle verb held after an answered listing has no dialog to wait
        # for, so its window is the shorter retry pause.
        $windowMs = if ($lifecycleHeld) { [long]$LifecycleRetryWindowSeconds * 1000 } else { [long]$DialogWindowSeconds * 1000 }
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt ($windowMs + 1000)) {
            return (& $emit 'Undetermined' 'timeout')
        }
        if ($windowMs -gt 0) { $null = Wait-UtmInterval -Milliseconds ([int]$windowMs) -Deadline $Deadline }
        $again = Get-UtmApplicationState -Deadline $Deadline
        $facts.appState = $again.State
        if ($again.State -eq 'absent') { return (& $emit 'Unresponsive' 'app-stopped') }
        if ($again.State -ne 'running') { return (& $emit 'Undetermined' 'timeout') }
        $second = & $probeOnce $Deadline $resolver.Path $TimeoutSeconds ([bool]$IncludeInventory)
        $lifecycleHeldAgain = $false
        if ($second -eq 'responsive' -and $LifecycleProbe) {
            $second = & $probeLifecycle $Deadline $TimeoutSeconds
            $lifecycleHeldAgain = ($second -eq 'timeout')
        }
        if ($second -eq 'responsive') { return (& $emit 'Responsive' 'responsive') }
        if ($second -ne 'timeout') { return (& $emit 'Undetermined' $second) }
        $facts.timedOut = $true
        if ($facts.automationGrant -eq 'recorded' -or ($lifecycleHeld -and $lifecycleHeldAgain)) {
            $facts.corroborated = $true
            return (& $emit 'Unresponsive' 'timeout')
        }
        return (& $emit 'Undetermined' 'timeout')
    } catch {
        $facts.diagnostic = "$($_.Exception.Message)"
        return (& $emit 'Undetermined' 'invalid-response')
    }
}

# --- REGION: Start-VirtualizationServiceIfStopped
function Start-VirtualizationServiceIfStopped {
    <#
    .SYNOPSIS
        Launch UTM for this user only when this function positively observes it
        not running; refuse on anything it cannot establish. Returns a
        Yuruna.VirtualizationStartResult.
    .DESCRIPTION
        Runs its own detection immediately before acting and never trusts an
        earlier probe: a GUI (Aqua) session, a known non-root uid, and a
        same-user process census that shows neither UTM nor its helpers. UTM
        already running for this user is 'already-running'; anything that cannot
        be established refuses and launches nothing. The launch is
        Start-UtmApplication -RequireGuiSession, whose outcomes map as
        launched -> started, already-running -> already-running, launch-failed
        -> failed, not-observed -> unknown, refused -> refused.

        Under -WhatIf only the bounded read-only detection runs and the outcome
        is 'preview'. Never prompts and never throws. -DependentVMName is
        accepted for the shared signature; UTM has no separate network service
        for it to decide on.
    .PARAMETER TimeoutSeconds
        Budget for detection plus the launch wait.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline).
    .PARAMETER DependentVMName
        Guests whose restoration depends on this hypervisor; unused on macOS.
    .OUTPUTS
        [pscustomobject] PSTypeName 'Yuruna.VirtualizationStartResult':
        schemaVersion, hostType, outcome ('started' | 'already-running' |
        'refused' | 'failed' | 'unknown' | 'unavailable' | 'preview'), reason,
        layout ('not-applicable'), actions [object[]], observedUtc, elapsedMs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        $Deadline,
        [string[]]$DependentVMName = @()
    )
    $stopwatch   = [System.Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $actions = [System.Collections.Generic.List[object]]::new()
    $emit = {
        param([string]$Outcome, [string]$Reason)
        [pscustomobject]@{
            PSTypeName    = 'Yuruna.VirtualizationStartResult'
            schemaVersion = 1
            hostType      = 'host.macos.utm'
            outcome       = $Outcome
            reason        = $Reason
            layout        = 'not-applicable'
            actions       = [object[]]$actions.ToArray()
            observedUtc   = $observedUtc
            elapsedMs     = [long]$stopwatch.ElapsedMilliseconds
        }
    }
    $addAction = {
        param([string]$Kind, [string]$Before, [string]$After, [string]$Result, [string]$Reason, $ExitCode, [bool]$TimedOut, [long]$ElapsedMs)
        $actions.Add([pscustomobject]@{
            target = 'UTM'; kind = $Kind; before = $Before; after = $After; result = $Result; reason = $Reason
            command = [string[]]@('open', '-a', 'UTM'); exitCode = $ExitCode; timedOut = $TimedOut; elapsedMs = $ElapsedMs
        })
    }
    try {
        if ($DependentVMName.Count -gt 0) { Write-Verbose "Start-VirtualizationServiceIfStopped on host.macos.utm: -DependentVMName is not used; UTM has no separate network service." }
        $budget = Get-UtmChildDeadline -Milliseconds ([long]$TimeoutSeconds * 1000) -Parent $Deadline
        if ((Get-YurunaDeadlineRemainingMs -Deadline $budget) -lt 1000) { return (& $emit 'refused' 'deadline-exhausted') }
        # No utmctl on PATH or in the bundle: UTM is not installed where this
        # driver expects it, and `open -a UTM` has nothing to launch.
        if ((Resolve-UtmctlExecutable).Source -eq 'missing') { return (& $emit 'refused' 'missing-client') }
        $prerequisite = Get-UtmControlPrerequisite -Deadline $budget
        $beforeState = if ($prerequisite.AppState) { [string]$prerequisite.AppState.State } else { 'unknown' }
        if (-not $prerequisite.Ok) {
            & $addAction 'app-launch' $beforeState $beforeState 'refused' $prerequisite.Reason $null $false 0
            return (& $emit 'refused' $prerequisite.Reason)
        }
        if (@($prerequisite.AppState.UtmPid).Count -gt 0) {
            & $addAction 'app-launch' 'running' 'running' 'already-running' 'already-running' $null $false 0
            return (& $emit 'already-running' 'already-running')
        }
        if (@($prerequisite.AppState.HelperPid).Count -gt 0) {
            & $addAction 'app-launch' 'running' 'running' 'refused' 'helpers-without-app' $null $false 0
            return (& $emit 'refused' 'helpers-without-app')
        }
        if (-not $PSCmdlet.ShouldProcess('UTM', (Format-YurunaOperatorMessage -Key 'host.utm_app_launch_action'))) {
            & $addAction 'app-launch' 'absent' 'absent' 'preview' 'preview' $null $false 0
            return (& $emit 'preview' 'preview')
        }
        $launchWait = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 600
        if ($null -eq $launchWait) { return (& $emit 'refused' 'deadline-exhausted') }
        $launch = Start-UtmApplication -Deadline $budget -LaunchWaitSeconds ([int]$launchWait) -RequireGuiSession -Confirm:$false -WhatIf:$false
        $afterState = if (@($launch.UtmPid).Count -gt 0) { 'running' } else { 'unknown' }
        $timedOut = ($launch.Outcome -eq 'not-observed')
        switch ($launch.Outcome) {
            'launched' {
                & $addAction 'app-launch' 'absent' 'running' 'started' 'started' $launch.LaunchExitCode $false $launch.ElapsedMs
                return (& $emit 'started' 'started')
            }
            'already-running' {
                & $addAction 'app-launch' 'absent' 'running' 'already-running' 'already-running' $null $false $launch.ElapsedMs
                return (& $emit 'already-running' 'already-running')
            }
            'launch-failed' {
                & $addAction 'app-launch' 'absent' $afterState 'failed' 'start-failed' $launch.LaunchExitCode $false $launch.ElapsedMs
                return (& $emit 'failed' 'start-failed')
            }
            'not-observed' {
                & $addAction 'app-launch' 'absent' $afterState 'unknown' 'not-observed' $launch.LaunchExitCode $timedOut $launch.ElapsedMs
                return (& $emit 'unknown' 'not-observed')
            }
            'deadline-exhausted' {
                & $addAction 'app-launch' 'absent' 'absent' 'refused' 'deadline-exhausted' $null $false $launch.ElapsedMs
                return (& $emit 'refused' 'deadline-exhausted')
            }
            default {
                & $addAction 'app-launch' 'absent' $afterState 'refused' ([string]$launch.Reason) $null $false $launch.ElapsedMs
                return (& $emit 'refused' ([string]$launch.Reason))
            }
        }
    } catch {
        Write-Verbose "Start-VirtualizationServiceIfStopped on host.macos.utm failed: $($_.Exception.Message)"
        return (& $emit 'failed' 'start-failed')
    }
}
