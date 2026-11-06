<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42f891c9-8b81-4f84-a567-4c9eaa355537
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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

# The download-agent service's readiness phases. Start-ExtensionService.ps1
# runs this part in its own scope, inside the start operation's try block,
# after the VM is adopted or built: it reads and sets that script's variables,
# and each of its exits ends the start. The steps it shares with the
# pool-control part (waiting for the address and recovering it, reporting the
# source, deciding the outcome) are the pipeline's script blocks, dot-sourced
# where they run.
param()

if ($startPart -ne $PSCommandPath) { throw "$PSCommandPath runs only inside Start-ExtensionService.ps1." }

# --- REGION: Resolve the VM address
. $resolveServiceVmAddress

# --- REGION: Configure Shared NAT forwarding
# See https://yuruna.link/42e220c4-0008
$bundleMode  = ''
$hostAddress = ''
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = [string](Get-UtmNetworkModeFromBundle -VMName $VMName)
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; run Stop-DownloadAgentServiceVM.ps1 and then this script again to rebuild it."
    }
    # Host port 8082, not 80: on a shared-services machine the caching-proxy
    # already forwards host :80 (its CA-cert endpoint) and pool-control holds
    # 8081, so this UI takes a host port of its own.
    if ($bundleMode -eq 'Shared') {
        if ($vmIp) {
            $mapped = Add-PortMap -Owner 'download-agent-service' -VMIp $vmIp -Port @() -PortRemap @{ 8082 = 80 } -Confirm:$false
            $hostAddress = [string](Get-BestHostIp)
            if ($mapped) { Write-Information "  Shared NAT: peers reach the download-agent service UI at http://${hostAddress}:8082/ (forwarded to ${vmIp}:80), not at the VM's address." -InformationAction Continue }
            else {
                Write-Warning "Shared NAT: could not forward host port 8082 to ${vmIp}:80; the download-agent service is reachable from this host only, and peers will keep downloading images for themselves."
                $hostAddress = ''
            }
        } else {
            Write-Warning "Shared NAT: '$VMName' has no address yet, so no host port was forwarded; re-run once it has booted to publish the UI to the LAN."
        }
    }
}

# --- REGION: Probe service readiness
# See https://yuruna.link/42e220c4-0008
$readyTimeoutSeconds = Get-DownloadAgentServiceReadyTimeoutSeconds
$readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)

$daemonReady = $false
# A different question, kept apart from the one above: the daemon can be serving
# while THIS host has no route to it. That costs this host its local path and
# nothing else -- peers reach the daemon through its own announce -- so it
# suppresses the published URL without withdrawing the service.
$listeningButUnreachable = $false
$stillBuilding = $false
# $null until a wait actually runs, which is itself an answer: a verdict that was
# never taken is not a pass.
$endpoint = $null
# Re-points the host forward at an address the guest moved to: during the
# wait below, and when the guest is found again at another address.
$repointForwarder = {
    param($newAddress)
    $script:vmIp = $newAddress
    if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
        if (Add-PortMap -Owner 'download-agent-service' -VMIp $newAddress -Port @() -PortRemap @{ 8082 = 80 } -Confirm:$false) {
            $script:hostAddress = [string](Get-BestHostIp)
            Write-Verbose "  Re-pointed host :8082 -> ${newAddress}:80."
        }
    }
}
if ($vmIp) {
    Write-Verbose "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the download-agent-service daemon to serve on :80 (first boot builds it in-guest)."
    Write-Verbose "  The wait extends itself while the guest reports it is still building; progress is printed as it happens."
    Write-Verbose "  Override the budget with YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS."
    $endpoint = Wait-YurunaServiceVmDaemon -VMName $VMName -Port 80 `
        -TimeoutSeconds $readyTimeoutSeconds -Address $vmIp `
        -GuestKey 'guest.download-agent-service' -User 'download-agent-service-admin' `
        -ServiceLabel 'download-agent-service daemon' `
        -OnAddressChanged $repointForwarder
    if ($endpoint.Address) { $vmIp = $endpoint.Address }
    if ($endpoint.ExtendedSeconds -gt 0) {
        Write-Verbose ("  Waited $([int]($endpoint.WaitedSeconds / 60)) min in total -- the budget was extended by " +
                           "$([int]($endpoint.ExtendedSeconds / 60)) min because the guest reported it was still building.") -InformationAction Continue
    }
} else {
    Write-Warning ("Could not resolve the VM's IP after waiting ${ipWaitSeconds}s (Wait-VMIp); the VM IS running, so this is address " +
                   "discovery, not a boot failure. Asking the guest itself whether the daemon is up.")
    if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
        $inGuest = $null
        try {
            $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.download-agent-service' `
                -User 'download-agent-service-admin' -TimeoutSeconds 30 `
                -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
        } catch { Write-Verbose "download-agent-service in-guest listener probe: $($_.Exception.Message)" }
        if ($inGuest -and "$($inGuest.output)" -match 'YURUNA_LISTENING') {
            $endpoint = [pscustomobject]@{
                Ready         = $false
                Unreachable   = $true
                StillBuilding = $false
                Address       = ''
                WaitedSeconds = $ipWaitSeconds
                ObservedState = 'the guest itself reports the daemon bound on :80; this host never resolved its address'
            }
        }
    }
}

# --- REGION: Recover the VM address
. $recoverServiceVmAddress

# --- REGION: Evaluate service readiness
# See https://yuruna.link/42e220c4-0008
$verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint
# Every downstream branch reads these, and all three come from the one verdict:
# a bring-up cannot be "ready" in the banner and "not ready" in the marker.
$daemonReady             = ($verdict.Outcome -eq 'Ready' -or $verdict.Outcome -eq 'Unreachable')
$listeningButUnreachable = ($verdict.Outcome -eq 'Unreachable')
$stillBuilding           = ($verdict.Outcome -eq 'StillBuilding')

switch ($verdict.Outcome) {
    'Ready' {
        Write-Information "  The download-agent-service daemon is serving on :80." -InformationAction Continue
    }
    'Unreachable' {
        # Address-safe: this outcome is reached both with and without a resolved
        # address, and naming a host that was never resolved would print a
        # connection target that does not exist.
        $unreachableAt = if ($endpoint.Address) { "$($endpoint.Address):80" }
                         else { "it at all -- this host never resolved the guest's address" }
        Write-Warning @"
The download-agent-service daemon IS serving on :80 inside the guest (the guest was
asked directly), and this host cannot open a connection to $unreachableAt.

The service is UP -- this is a host-to-guest path problem, not a bring-up failure,
so the bring-up is reported as a success. What it costs: this host cannot use the
agent locally, so its own Get-Image calls fall back to fetching from the origin.
Peers are unaffected -- the daemon registers itself with the pool through its own
announce, whose address the aggregator confirms by probing.

Worth checking if you want the local path back:
  * The guest firewall may be dropping :80 from outside (ufw).
  * On UTM Shared NAT, the host reaches the guest through the 192.168.64.0/24
    gateway only -- a bridged-mode address is not routable from here.
"@
    }
    'StillBuilding' {
        # Not a failure: the guest is working, it just needs longer than any
        # budget this script is willing to hold the operator for. It finishes on
        # its own, and the daemon registers with the pool through its own
        # announce -- so the honest report is "not yet", not "broken".
        Write-Warning @"
The download-agent-service guest is STILL BUILDING after $([int]($endpoint.WaitedSeconds / 60)) min (cloud-init: $($endpoint.CloudInitStatus)).
$(if ($endpoint.LastProgress) { "Last step seen: $($endpoint.LastProgress)`n" })
Nothing is broken and nothing needs fixing -- a first boot installs a Go toolchain
and compiles the daemon, which runs long on a slow arch or a cold package mirror.
The build finishes on its own and the daemon then registers itself with the pool.

The bring-up is NOT failed over this, so the run continues. To confirm once it is up:
  test/service/Start-DownloadAgentServiceVM.ps1     # adopts a VM that is already serving
To hold this script longer next time:
  `$env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = '5400'
"@
    }
}

# --- REGION: Report the deployed source
. $reportServiceVmSource

# --- REGION: Decide the start outcome
. $decideServiceStartOutcome

# --- REGION: Publish service readiness
# See https://yuruna.link/42fffc2c-0008
$downloadAgentServiceBaseUrl = if ($startOutcome.Advertise -and -not $listeningButUnreachable) {
    Resolve-DownloadAgentServiceBaseUrl -VMIp ([string]$vmIp) -NetworkMode $bundleMode -HostAddress $hostAddress
} else { '' }
[void](Write-DownloadAgentServiceMarker -RuntimeDir $runtimeDir -Active $startOutcome.Advertise -VMName $VMName -HostType $HostType -BaseUrl $downloadAgentServiceBaseUrl)
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

if ($startOutcome.Degraded.Count -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_start_degraded' -Arguments @{ vmName = $VMName; names = ($startOutcome.Degraded -join ', ') })
}
if ($startOutcome.State -eq 'stop-requested') {
    Write-Verbose "  Stop: test/service/Stop-DownloadAgentServiceVM.ps1"
    exit $ExitFailure
}
if ($startOutcome.State -eq 'wrong-build') {
    Write-Verbose ""
    Write-Verbose "== download-agent-service start: FAILED (deployed an obsolete framework snapshot) =="
    Write-Verbose "  VM:   $VMName ($HostType)"
    Write-Information "  The VM is up and the daemon is serving -- it is running the WRONG BUILD, not nothing." -InformationAction Continue
    Write-Verbose "  Stop: test/service/Stop-DownloadAgentServiceVM.ps1"
    exit $ExitFailure
}

if ($stillBuilding) {
    Write-Verbose ""
    Write-Information "== download-agent-service is STILL BUILDING (VM up, daemon not serving yet) ==" -InformationAction Continue
    Write-Verbose "  VM:   $VMName ($HostType)"
    Write-Verbose "  Watch the build finish:"
    # Never an ssh line with a hole where the host should be: an address this
    # host never learned makes the command unrunnable AND hides the fact that is
    # actually blocking the reader.
    foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'download-agent-service-admin' -Address ([string]$vmIp) -VMName $VMName `
                -Command 'sudo tail -f /var/log/cloud-init-output.log') -split "`r?`n")) {
        Write-Verbose "  $hintLine"
    }
    Write-Verbose "  Then:  test/service/Start-DownloadAgentServiceVM.ps1   (adopts it once it serves)"
    exit $ExitOk
}

if ($daemonReady) {
    Write-Verbose ""
    if ($listeningButUnreachable) {
        Write-Verbose "== download-agent-service is RUNNING (daemon serving on :80 in-guest; not reachable from this host) =="
    } else {
        Write-Verbose "== download-agent-service is READY (daemon serving on :80) =="
    }
    Write-Verbose "  VM:   $VMName ($HostType)"
    if ($downloadAgentServiceBaseUrl) {
        Write-Verbose "  UI:   $downloadAgentServiceBaseUrl  (pool inspection, Force refresh / Delete / Prune previous)"
    } else {
        Write-Verbose "  UI:   not published -- this host cannot reach the daemon, so no URL is advertised. The pool still"
        Write-Verbose "        resolves the service from its own announce; the Yuruna hosts dashboard links it there."
    }
    if ($vmIp) { Write-Information "  SSH:  ssh download-agent-service-admin@$vmIp  (harness key authorized)" -InformationAction Continue }
    Write-Verbose "  Stop: test/service/Stop-DownloadAgentServiceVM.ps1"
    Write-Verbose "  Unlock the UI's actions with the 6-character Lab token from the Yuruna hosts dashboard (docs/download-agent.md)."
    exit $ExitOk
}

# --- REGION: Collect failure diagnostics
# See https://yuruna.link/42fffc2c-000c
$failureDetail = if ($vmIp -and $recoveredIp -and $recoveredIp -ne [string]$vmIp) {
    "is NOT serving on :80 at $vmIp after $readyTimeoutMinutes min, nor at $recoveredIp, the other address this host could find for the guest"
} elseif ($vmIp) {
    "is NOT serving on :80 (VM $vmIp) after $readyTimeoutMinutes min"
} elseif ($recoveredIp) {
    "did not answer on :80 at $recoveredIp, the only address this host could find for the guest"
} else {
    "never got an address (no IP after ${ipWaitSeconds}s), so :80 was never probed"
}
Write-Warning "download-agent-service daemon $failureDetail -- $($verdict.Summary). Collecting in-guest diagnostics over the harness SSH key..."

# The MAC-match sweep above already ran on this path; reusing its answer keeps a
# second ICMP sweep out of a script that has already made the operator wait.
$diagIp = if ($vmIp) { [string]$vmIp } else { [string]$recoveredIp }
if (-not $diagIp) { Write-Information "  '$VMName' could not be located by any discovery route this host has." -InformationAction Continue }

Invoke-YurunaServiceVmFailureDiagnostic -ServiceName 'download-agent-service' -GuestKey 'guest.download-agent-service' -User 'download-agent-service-admin' -VMName $VMName -Address $diagIp
Write-Verbose ""
Write-Information "The download-agent-service daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
Write-Information "  * cloud-init status 'running'  -> the in-guest build (golang) is still going; wait, then" -InformationAction Continue
Write-Verbose "                                    re-run to re-check (or raise YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS)."
Write-Information "  * 'cifs_mount failed' / -111   -> the pool share did not mount, so cloud-init stopped before the daemon" -InformationAction Continue
Write-Verbose "                                    was ever built. The console capture above shows this when SSH cannot."
Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
Write-Information "  * '/mnt/yuruna-pool' unmounted -> the pool share is unreachable; re-check the pool storage credential." -InformationAction Continue
Write-Verbose "                                    The daemon still serves, so this is a pool fault, not a build fault."
Write-Information "  * nothing at all over SSH      -> the console capture above is the remaining evidence." -InformationAction Continue
Write-Verbose "See docs/download-agent.md."
Write-Verbose ""
Write-Verbose "== download-agent-service start: FAILED (the daemon never served on :80) =="
Write-Verbose "  VM:   $VMName"
Write-Verbose "  Host: $HostType"
Write-Verbose "  Stop: test/service/Stop-DownloadAgentServiceVM.ps1"
exit $ExitFailure
