<#PSScriptInfo
.VERSION 2026.11.05
.GUID 428ee2d7-b078-4350-802e-6f235f2102bf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna stash service extension service
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

# The stash service's readiness phases. Start-ExtensionService.ps1 runs this
# part in its own scope, inside the start operation's try block, after the VM
# is adopted or built: it reads and sets that script's variables, and each of
# its exits ends the start. The outcome is decided by the pipeline's shared
# step, dot-sourced where it runs, from the verdict this part reaches.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'sourceAccepted',
    Justification = 'Read by the shared decideServiceStartOutcome block dot-sourced from Start-ExtensionService.ps1.')]
param()

if ($startPart -ne $PSCommandPath) { throw "$PSCommandPath runs only inside Start-ExtensionService.ps1." }

# An adopted guest's address is where the readiness wait starts; a rebuilt
# guest is found by name.
$stashVmIp = if ($adoption.Decision -ne 'rebuild') { [string]$adoption.Address } else { $null }

# --- REGION: Configure Shared NAT forwarding
# See https://yuruna.link/42e220c4-0008
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = Get-UtmNetworkModeFromBundle -VMName $VMName
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; run Stop-StashServiceVM.ps1 and then this script again to rebuild it."
    }
    if ($bundleMode -eq 'Shared') {
        $stashVmIp = Get-VMIp -VMName $VMName
        if ($stashVmIp) {
            $mapped = Add-PortMap -Owner 'stash-service' -VMIp $stashVmIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false
            if ($mapped) { Write-Output "  Shared NAT: peers reach this stash service at $(Get-BestHostIp):2222 (forwarded to ${stashVmIp}:22), not at the VM's address." }
            else { Write-Warning "Shared NAT: could not forward host port 2222 to ${stashVmIp}:22; this stash service is reachable from this host only." }
        } else {
            Write-Warning "Shared NAT: '$VMName' has no address yet, so no host port was forwarded; re-run once it has booted to publish it to the LAN."
        }
    }
}

# --- REGION: Initialize the runtime directory
# See https://yuruna.link/42e220c4-0008
# See https://yuruna.link/42f52e37-0020
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$runtimeDir = $null
try {
    $runtimeDir = Initialize-YurunaRuntimeDir
} catch { Write-Verbose "stash-service runtime directory: $($_.Exception.Message)" }

# --- REGION: Probe service readiness
# See https://yuruna.link/42e220c4-0008
# See https://yuruna.link/42d69dfa-0024
# See https://yuruna.link/42f52e37-0020
$stashReadyTimeoutSeconds = Get-ExtensionServiceReadyTimeoutSeconds -Area 'stash-service'
$stashReadyCapSeconds = $stashReadyTimeoutSeconds * 2
Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
Write-Verbose "Waiting up to $([int]($stashReadyTimeoutSeconds / 60)) min for the stash-service daemon to serve on :80 (first boot builds it in-guest)."
Write-Verbose ("  The budget grows to at most $([int]($stashReadyCapSeconds / 60)) min, and only while the guest ITSELF answers over SSH that " +
              "cloud-init is still running -- nothing is assumed about the guest. Override with YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS.")
$stashEndpoint = Wait-YurunaServiceVmDaemon -VMName $VMName -Port 80 `
    -TimeoutSeconds $stashReadyTimeoutSeconds -MaxTimeoutSeconds $stashReadyCapSeconds `
    -Address ([string]$stashVmIp) `
    -GuestKey 'guest.stash-service' -User 'stash-admin' `
    -ServiceLabel 'stash-service daemon' `
    -OnAddressChanged {
        param($newAddress)
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            if (Add-PortMap -Owner 'stash-service' -VMIp $newAddress -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                Write-Verbose "  Re-pointed host :2222 -> ${newAddress}:22."
            }
        }
    }
if ($stashEndpoint.Address) { $stashVmIp = $stashEndpoint.Address }
if ($stashEndpoint.ExtendedSeconds -gt 0) {
    Write-Verbose ("  Waited $([int]($stashEndpoint.WaitedSeconds / 60)) min in total -- extended by " +
                  "$([int]($stashEndpoint.ExtendedSeconds / 60)) min because the guest reported it was still building.")
}

# --- REGION: Recover the VM address
# See https://yuruna.link/4220a755-0046
$stashRecovery = $null
if ((Get-ServiceVmReadinessVerdict -Endpoint $stashEndpoint).IsFailure) {
    Write-Output "  The wait ended without the daemon answering -- looking for the guest by a route the wait could not use..."
    $stashRecovery = Confirm-ServiceVmAtRecoveredAddress -VMName $VMName -Port 80 `
        -KnownAddress ([string]$stashEndpoint.Address) -TimeoutSeconds 60
    Write-Verbose "  $($stashRecovery.Summary)."
    if ($stashRecovery.Ready) {
        $stashVmIp = $stashRecovery.Address
        # A NEW endpoint record rather than a mutated one: everything downstream
        # -- the verdict, the marker, the report -- reads this object, and a
        # half-updated copy that still carried the old address would advertise
        # the address the daemon is NOT on.
        $stashEndpoint = New-ServiceVmRecoveredEndpoint -Endpoint $stashEndpoint -Address $stashRecovery.Address
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            try {
                if (Add-PortMap -Owner 'stash-service' -VMIp $stashVmIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                    Write-Verbose "  Re-pointed host :2222 -> ${stashVmIp}:22."
                }
            } catch { Write-Verbose "stash forwarder re-point after recovery: $($_.Exception.Message)" }
        }
    }
}

# --- REGION: Evaluate service readiness
# See https://yuruna.link/42e220c4-0008
# Every downstream branch routes on this one verdict instead of judging for
# itself. A readiness timeout is a FAILURE: a run that records PASS for a daemon
# that never started sends the operator looking for the fault in whatever
# breaks next.
$verdict = Get-ServiceVmReadinessVerdict -Endpoint $stashEndpoint
switch ($verdict.Outcome) {
    'Ready' {
        Write-Output "  Stash daemon is serving on :80 -- the pool resolves it and the dashboard cell links to it."
    }
    'Unreachable' {
        Write-Warning ("The stash daemon IS serving on :80 inside the guest, and this host cannot open a connection to it. " +
                       "The service is UP and reaches the pool through its own announce; only this host's direct path is missing.")
    }
    'StillBuilding' {
        Write-Warning @"
The stash-service guest is STILL BUILDING after $([int]($stashEndpoint.WaitedSeconds / 60)) min (cloud-init: $($stashEndpoint.CloudInitStatus)).
$(if ($stashEndpoint.LastProgress) { "Last step seen: $($stashEndpoint.LastProgress)`n" })
Nothing is broken -- a first boot installs a Go toolchain and compiles the daemon.
It finishes on its own and then registers itself with the pool, at which point the
dashboard's Extension cell links to it. The bring-up is NOT failed over this.
"@
    }
}

# --- REGION: Report the deployed source
# See https://yuruna.link/42fffc2c-0013
# The daemon is serving, so this is the first point where the framework it
# was built from can be answered from evidence rather than prediction. It is
# read before anything is published, so a refused build is never advertised.
$sourceAccepted = $true
if ($verdict.Outcome -eq 'Ready') {
    $sourceAccepted = Assert-ServiceVmFrameworkSource -Address ([string]$stashVmIp) -Port 80 `
        -GuestKey 'guest.stash-service' -User 'stash-admin' `
        -Expected $frameworkExpected -ServiceLabel 'stash-service' `
        -AllowMirrorSource:$AllowMirrorSource
}

# --- REGION: Decide the start outcome
. $decideServiceStartOutcome

# --- REGION: Publish service readiness
# See https://yuruna.link/42fffc2c-0008
if ($runtimeDir) {
    try {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtimeDir `
            -Active $startOutcome.Advertise -VMName $VMName -HostType $HostType -HostingMode 'vm')
    } catch { Write-Verbose "stash-service marker write: $($_.Exception.Message)" }
}
if ($runtimeDir -and $startOutcome.Advertise -and $verdict.Outcome -eq 'Ready') {
    try {
        $stashUrl = Update-StashServiceMarkerAddress -RuntimeDir $runtimeDir -VMName $VMName -TimeoutSeconds 180
        if ($stashUrl) { Write-Output "  Stash VM address: $stashUrl (Extension cell deep-links here)." }
        else { Write-Output "  Stash VM address not resolved yet -- the Extension deep-link populates on a later refresh." }
    } catch { Write-Verbose "stash address resolve: $($_.Exception.Message)" }

    # --- REGION: Re-point the Shared NAT forwarder
    # See https://yuruna.link/42e220c4-0008
    if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
        try {
            $settledIp = Get-VMIp -VMName $VMName
            if ($settledIp -and $settledIp -ne $stashVmIp) {
                Write-Verbose "  '$VMName' settled on $settledIp (was $stashVmIp) -- re-pointing host :2222."
                if (Add-PortMap -Owner 'stash-service' -VMIp $settledIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                    Write-Verbose "  Shared NAT: peers reach this stash service at $(Get-BestHostIp):2222 (forwarded to ${settledIp}:22)."
                } else {
                    Write-Warning "Could not re-point host port 2222 to ${settledIp}:22. Peers following the old address will hang until it is corrected; re-run this script to retry."
                }
            }
        } catch { Write-Verbose "stash forwarder re-point: $($_.Exception.Message)" }
    }
}

# Publish the marker NOW: regenerate host.registration.json so the aggregator sees
# the active extension on its next poll, without waiting for a test cycle (the only
# other point Write-HostRegistrationRecord runs). It reads the runtime dir +
# $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Verbose "  Refreshed host.registration.json (Extension hosts updates within one aggregator poll)."
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# --- REGION: Collect failure diagnostics
# See https://yuruna.link/42fffc2c-000c
# See https://yuruna.link/42f52e37-0020
if ($verdict.IsFailure) {
    $stashWaitedMinutes = if ($stashEndpoint) { [int]($stashEndpoint.WaitedSeconds / 60) } else { 0 }
    $stashObserved = if ($stashEndpoint -and $stashEndpoint.ObservedState) { [string]$stashEndpoint.ObservedState } else { 'nothing' }
    Write-Warning ("The stash-service daemon did not come up on :80 after $stashWaitedMinutes min -- " +
                   "$($verdict.Summary). Observed: $stashObserved.")

    # The MAC-match sweep above already ran on this path; reusing its answer
    # keeps a second ICMP sweep out of a script that has already made the
    # operator wait.
    $stashDiagIp = if ($stashEndpoint) { [string]$stashEndpoint.Address } else { '' }
    if (-not $stashDiagIp -and $stashRecovery) { $stashDiagIp = [string]$stashRecovery.Address }

    Invoke-YurunaServiceVmFailureDiagnostic -ServiceName 'stash-service' -GuestKey 'guest.stash-service' -User 'stash-admin' -VMName $VMName -Address $stashDiagIp -MountPath '/mnt/yuruna-stash'
    Write-Verbose ""
    Write-Output "Reading the capture above:"
    Write-Output "  * cloud-init status 'running'   -> the in-guest build is still going; re-run this script to"
    Write-Verbose "                                     re-check, or raise YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS."
    Write-Output "  * 'cifs_mount failed' / -111    -> the stash share did not mount, so cloud-init stopped before the"
    Write-Verbose "                                     daemon was ever built. Check that the stash share's server is"
    Write-Verbose "                                     actually serving SMB and that its credential is current."
    Write-Output "  * a 'go build' / apt error      -> a package or source problem; the log tail shows the line."
    Write-Output "  * nothing at all over SSH       -> the console capture above is the remaining evidence."
    Write-Verbose "See https://yuruna.link/42f5e921."
    Write-Verbose ""
    # Names every address this host actually probed. "The daemon never served"
    # is a claim about the machine, and the operator's first question is which
    # address it was tested at -- an answer that also tells them whether the
    # second, recovered address was tried at all.
    $stashFailureDetail = if ($stashRecovery -and $stashRecovery.Probed) {
        "the daemon answered on :80 at neither $($stashEndpoint.Address) nor $($stashRecovery.Address)"
    } elseif ($stashDiagIp) {
        "the daemon never served on :80 at $stashDiagIp"
    } else {
        'the daemon never served on :80, and no address for the guest was ever found'
    }
    Write-Verbose "== stash-service start: FAILED ($stashFailureDetail) =="
    Write-Verbose "  VM:       $VMName"
    Write-Verbose "  Host:     $HostType"
    Write-Verbose ""
    Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
    exit $ExitFailure
}

# --- REGION: Verify the host status service
# See https://yuruna.link/42e220c4-0008
if ($statusDecision -and $statusDecision.ShouldStart) {
    $statusPort = [int]$statusDecision.Port
    $accepting = Test-TcpEndpointOpen -Address '127.0.0.1' -Port $statusPort -TimeoutMilliseconds 2000
    if ($accepting) {
        Write-Verbose "  Status service accepting on :$statusPort -- this host will appear under Extension hosts."
    } else {
        Write-Warning "Status service is not accepting on :$statusPort -- the pool-aggregator service cannot read host.registration.json over HTTP, so the Extension hosts row depends solely on the stash-service VM's own presence beacon (which the aggregator shows without the host's status baseUrl link). Run test/service/Start-StatusService.ps1 to diagnose."
    }
}

if ($startOutcome.Degraded.Count -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_start_degraded' -Arguments @{ vmName = $VMName; names = ($startOutcome.Degraded -join ', ') })
}
if ($startOutcome.State -eq 'stop-requested') {
    Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
    exit $ExitFailure
}

Write-Verbose ""
# "Complete" is claimed only where the daemon was actually observed serving. A
# guest that is still compiling has not completed anything yet -- it is a
# successful bring-up whose service is not up, and saying so is what stops the
# operator looking for a UI that does not answer.
if ($verdict.Outcome -eq 'StillBuilding') {
    Write-Output "== stash-service start: STILL BUILDING -- '$VMName' is up, daemon not serving yet =="
    Write-Verbose "  VM:       $VMName"
    Write-Verbose "  Host:     $HostType"
    Write-Verbose ""
    Write-Verbose "Watch the build finish:"
    foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'stash-admin' -Address ([string]$stashVmIp) -VMName $VMName `
                -Command 'sudo tail -f /var/log/cloud-init-output.log') -split "`r?`n")) {
        Write-Verbose "  $hintLine"
    }
    Write-Verbose "Then: test/service/Start-StashServiceVM.ps1   (adopts the VM once it serves)"
    Write-Verbose ""
    Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
    exit $ExitOk
}

if ($startOutcome.State -eq 'wrong-build') {
    Write-Verbose ""
    Write-Verbose "== stash-service start: FAILED (deployed an obsolete framework snapshot) =="
    Write-Verbose "  VM:       $VMName"
    Write-Verbose "  Host:     $HostType"
    Write-Verbose ""
    Write-Output "The VM is up and the daemon is serving -- it is running the WRONG BUILD, not nothing."
    Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
    exit $ExitFailure
}

Write-Output "== stash-service start: complete -- '$VMName' on $HostType =="
Write-Verbose ""
Write-Verbose "Cloud-init mounted the stash share, fetched the framework, and ran the"
Write-Verbose "bring-up script that built + launched the stash daemon under systemd."
Write-Verbose "(See https://yuruna.link/42f5e921.)"
Write-Verbose ""
Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
exit $ExitOk
