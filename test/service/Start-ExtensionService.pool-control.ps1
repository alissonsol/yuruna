<#PSScriptInfo
.VERSION 2026.10.31
.GUID 427d5263-0226-4480-81d1-9a13f2b7a4b1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool-control service extension service
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

# The pool-control service's readiness phases. Start-ExtensionService.ps1 runs
# this part in its own scope, inside the start operation's try block, after the
# VM is adopted or built: it reads and sets that script's variables, and each
# of its exits ends the start.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'serviceOpResult',
    Justification = 'Start-ExtensionService.ps1 reads it in the finally that closes the start operation.')]
param()

if ($startPart -ne $PSCommandPath) { throw "$PSCommandPath runs only inside Start-ExtensionService.ps1." }

# --- REGION: Resolve the VM address
# See https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$ipWaitStart = (Get-Date)
$vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
$ipWaitSeconds = [int]((Get-Date) - $ipWaitStart).TotalSeconds

# --- REGION: Configure Shared NAT forwarding
# See https://yuruna.link/42e220c4-0008
$script:poolControlForwarded = $false
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = Get-UtmNetworkModeFromBundle -VMName $VMName
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; run Stop-PoolControlServiceVM.ps1 and then this script again to rebuild it."
    }
    # Host port 8081, not 80: on a shared-services machine the caching-proxy
    # already forwards host :80 (its CA-cert endpoint), and asking for the
    # same port would attach to that forwarder -- publishing the CACHE at
    # the URL this script then prints for the pool-control UI.
    if ($bundleMode -eq 'Shared') {
        $pcVmIp = $vmIp
        if ($pcVmIp) {
            $script:poolControlForwarded = Add-PortMap -Owner 'pool-control-service' -VMIp $pcVmIp -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false
            if ($script:poolControlForwarded) { Write-Information "  Shared NAT: peers reach the pool-control service UI at http://$(Get-BestHostIp):8081/ (forwarded to ${pcVmIp}:80), not at the VM's address." -InformationAction Continue }
            else { Write-Warning "Shared NAT: could not forward host port 8081 to ${pcVmIp}:80; the pool-control service UI is reachable from this host only." }
        } else {
            Write-Warning "Shared NAT: '$VMName' has no address yet, so no host port was forwarded; re-run once it has booted to publish the UI to the LAN."
        }
    }
}

# --- REGION: Probe service readiness
# See https://yuruna.link/42e220c4-0008
$readyTimeoutSeconds = Get-ExtensionServiceReadyTimeoutSeconds -Area 'pool-control-service'
$readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)
# How long a guest located by the last-resort route below gets to answer on
# :80. Deliberately short: it runs only after the ordinary wait has already
# spent its whole budget, and it is confirming a listener that either answers
# within a few polls or was never there.
$recoveryProbeSeconds = 60

$daemonReady = $false
# A different question, kept apart from the one above: the daemon can be
# serving while THIS host has no route to it. That costs this host its local
# path and nothing else -- peers reach the daemon through its own announce --
# so it suppresses the published URL without withdrawing the service.
$listeningButUnreachable = $false
$stillBuilding = $false
# $null until a wait actually runs, which is itself an answer: a verdict that
# was never taken is not a pass.
$endpoint = $null
if ($vmIp) {
    Write-Verbose "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the pool-control-service daemon to serve on :80 (first boot builds it in-guest)."
    Write-Verbose "  The wait extends itself while the guest reports it is still building; progress is printed as it happens."
    Write-Verbose "  Override the budget with YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS."
    $repointForwarder = {
        param($newAddress)
        $script:vmIp = $newAddress
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            $script:poolControlForwarded = Add-PortMap -Owner 'pool-control-service' -VMIp $newAddress -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false
            if ($script:poolControlForwarded) {
                Write-Verbose "  Re-pointed host :8081 -> ${newAddress}:80."
            }
        }
    }
    $endpoint = Wait-YurunaServiceVmDaemon -VMName $VMName -Port 80 `
        -TimeoutSeconds $readyTimeoutSeconds -Address $vmIp `
        -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' `
        -ServiceLabel 'pool-control-service daemon' `
        -OnAddressChanged $repointForwarder
    if ($endpoint.Address) { $vmIp = $endpoint.Address }
    if ($endpoint.ExtendedSeconds -gt 0) {
        Write-Verbose ("  Waited $([int]($endpoint.WaitedSeconds / 60)) min in total -- the budget was extended by " +
                           "$([int]($endpoint.ExtendedSeconds / 60)) min because the guest reported it was still building.") -InformationAction Continue
    }
} else {
    Write-Warning ("Could not resolve the VM's IP after waiting ${ipWaitSeconds}s (Wait-VMIp); the VM IS running, so this is " +
                   "address discovery, not a boot failure. Asking the guest itself whether the daemon is up.")
    if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
        $inGuest = $null
        try {
            $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.pool-control-service' `
                -User 'pool-control-service-admin' -TimeoutSeconds 30 `
                -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
        } catch { Write-Verbose "pool-control-service in-guest listener probe: $($_.Exception.Message)" }
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
# See https://yuruna.link/4220a755-0046
$recoveredIp = ''
if ((Get-ServiceVmReadinessVerdict -Endpoint $endpoint).IsFailure) {
    $recovery = Confirm-ServiceVmAtRecoveredAddress -VMName $VMName -Port 80 -KnownAddress ([string]$vmIp) -TimeoutSeconds $recoveryProbeSeconds
    $recoveredIp = [string]$recovery.Address
    Write-Verbose "  $($recovery.Summary)."
    if ($recovery.Ready) {
        $vmIp = $recoveredIp
        $endpoint = New-ServiceVmRecoveredEndpoint -Endpoint $endpoint -Address $recoveredIp -WaitedSeconds $ipWaitSeconds
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            $script:poolControlForwarded = Add-PortMap -Owner 'pool-control-service' -VMIp $recoveredIp -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false
            if ($script:poolControlForwarded) {
                Write-Verbose "  Re-pointed host :8081 -> ${recoveredIp}:80."
            }
        }
    }
}

# --- REGION: Evaluate service readiness
# See https://yuruna.link/42e220c4-0008
$verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint
# Every downstream branch reads these, and all three come from the one
# verdict: a bring-up cannot be "ready" in the banner and "not ready" in the
# marker.
$daemonReady             = ($verdict.Outcome -eq 'Ready' -or $verdict.Outcome -eq 'Unreachable')
$listeningButUnreachable = ($verdict.Outcome -eq 'Unreachable')
$stillBuilding           = ($verdict.Outcome -eq 'StillBuilding')

switch ($verdict.Outcome) {
    'Ready' {
        Write-Information "  The pool-control-service daemon is serving on :80." -InformationAction Continue
    }
    'Unreachable' {
        # Address-safe: this outcome is reached both with and without a
        # resolved address, and naming a host that was never resolved would
        # print a connection target that does not exist.
        $unreachableAt = if ($endpoint.Address) { "$($endpoint.Address):80" }
                         else { "it at all -- this host never resolved the guest's address" }
        Write-Warning @"
The pool-control-service daemon IS serving on :80 inside the guest (the guest was
asked directly), and this host cannot open a connection to $unreachableAt.

The service is UP -- this is a host-to-guest path problem, not a bring-up failure,
so the bring-up is reported as a success. Peers reach the daemon through its own
announce, whose address the pool confirms by probing.

Worth checking if you want this host's own path back:
  * The guest firewall may be dropping :80 from outside (ufw).
  * On UTM Shared NAT, the host reaches the guest through the 192.168.64.0/24
    gateway only -- a bridged-mode address is not routable from here.
"@
    }
    'StillBuilding' {
        # Not a failure: the guest is working, it just needs longer than any
        # budget this script is willing to hold the operator for. It finishes
        # on its own, and the daemon registers with the pool through its own
        # announce -- so the honest report is "not yet", not "broken".
        Write-Warning @"
The pool-control-service guest is STILL BUILDING after $([int]($endpoint.WaitedSeconds / 60)) min (cloud-init: $($endpoint.CloudInitStatus)).
$(if ($endpoint.LastProgress) { "Last step seen: $($endpoint.LastProgress)`n" })
Nothing is broken and nothing needs fixing -- a first boot installs a Go toolchain
and pwsh and compiles the daemon, which runs long on a slow arch or a cold package
mirror. The build finishes on its own and the daemon then registers itself.

The bring-up is NOT failed over this, so the run continues. To confirm once it is up:
  test/service/Start-PoolControlServiceVM.ps1     # adopts a VM that is already serving
To hold this script longer next time:
  `$env:YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS = '5400'
"@
    }
}

# --- REGION: Report the deployed source
# See https://yuruna.link/42fffc2c-0013
# The daemon is serving, so this is the first point where the framework it
# was built from can be answered from evidence rather than prediction. It is
# read before anything is published, so a refused build is never advertised.
$sourceAccepted = $true
if ($daemonReady) {
    $sourceAccepted = Assert-ServiceVmFrameworkSource -Address ([string]$vmIp) -Port 80 `
        -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' `
        -Expected $frameworkExpected -ServiceLabel 'pool-control-service' `
        -AllowMirrorSource:$AllowMirrorSource
}

# --- REGION: Decide the start outcome
# One record decides the census result, the advertisement and the exit. A stop
# requested while this start ran wins: nothing is advertised for it.
$stillWanted = Test-YurunaServiceOperationCurrent -Context $serviceOp
$startOutcome = Resolve-YurunaServiceStartOutcome -Verdict $verdict -StillWanted $stillWanted -SourceAccepted $sourceAccepted -Degraded $buildDegraded
if ($startOutcome.Result -eq 'confirmed') { $serviceOpResult = 'confirmed' }
if (-not $stillWanted) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_start_stop_requested' -Arguments @{ vmName = $VMName; stopScript = 'Stop-PoolControlServiceVM.ps1' })
}

# --- REGION: Publish service readiness
# See https://yuruna.link/42fffc2c-0008
$poolControlServiceBaseUrl = if (-not $startOutcome.Advertise -or $listeningButUnreachable -or -not $vmIp) { '' }
                             elseif ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
                                 if ($script:poolControlForwarded) {
                                     $peerHostIp = Get-BestHostIp
                                     if ($peerHostIp -match ':') { "http://[${peerHostIp}]:8081" }
                                     elseif ($peerHostIp) { "http://${peerHostIp}:8081" } else { '' }
                                 } else { '' }
                             }
                             elseif ($vmIp -match ':') { "http://[$vmIp]" } else { "http://$vmIp" }
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
[void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir `
    -Active $startOutcome.Advertise -VMName $VMName -HostType $HostType -BaseUrl $poolControlServiceBaseUrl -HostingMode 'vm')
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

if ($startOutcome.Degraded.Count -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_start_degraded' -Arguments @{ vmName = $VMName; names = ($startOutcome.Degraded -join ', ') })
}
if ($startOutcome.State -eq 'stop-requested') {
    Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
    exit $ExitFailure
}
if ($startOutcome.State -eq 'wrong-build') {
    Write-Verbose ""
    Write-Verbose "== pool-control-service start: FAILED (deployed an obsolete framework snapshot) =="
    Write-Verbose "  VM:   $VMName ($HostType)"
    Write-Information "  The VM is up and the daemon is serving -- it is running the WRONG BUILD, not nothing." -InformationAction Continue
    Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
    exit $ExitFailure
}

if ($stillBuilding) {
    Write-Verbose ""
    Write-Information "== pool-control-service is STILL BUILDING (VM up, daemon not serving yet) ==" -InformationAction Continue
    Write-Verbose "  VM:   $VMName ($HostType)"
    Write-Verbose "  Watch the build finish:"
    # Never an ssh line with a hole where the host should be: an address this
    # host never learned makes the command unrunnable AND hides the fact that
    # is actually blocking the reader.
    foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'pool-control-service-admin' -Address ([string]$vmIp) -VMName $VMName `
                -Command 'sudo tail -f /var/log/cloud-init-output.log') -split "`r?`n")) {
        Write-Verbose "  $hintLine"
    }
    Write-Verbose "  Then:  test/service/Start-PoolControlServiceVM.ps1   (adopts it once it serves)"
    exit $ExitOk
}

if ($daemonReady) {
    # --- REGION: Sync the pool-configuration alias
    # See https://yuruna.link/42e220c4-0008
    try {
        Import-Module (Join-Path $ModulesDir 'Test.CachingProxyService.psm1') -Global -Force
        $aliasSync = Sync-PoolConfigurationAliasOnProxy -Confirm:$false
        if ($aliasSync.Changed) {
            Write-Verbose "  Proxy: /pool-configuration.git now serves the pool NAS store (runners pull what this UI writes)."
        } elseif (-not $aliasSync.Ok) {
            Write-Warning "pool-configuration alias not reconciled on the caching-proxy service: $($aliasSync.Message). Runners may still pull the proxy's older local store; the pool-control service UI is unaffected."
        } else {
            Write-Verbose "pool-configuration alias: $($aliasSync.Message)"
        }
    } catch { Write-Verbose "pool-configuration alias sync: $($_.Exception.Message)" }

    Write-Verbose ""
    if ($listeningButUnreachable) {
        Write-Verbose "== pool-control-service is RUNNING (daemon serving on :80 in-guest; not reachable from this host) =="
    } else {
        Write-Verbose "== pool-control-service is READY (daemon serving on :80) =="
    }
    Write-Verbose "  VM:   $VMName ($HostType)"
    if ($poolControlServiceBaseUrl) {
        Write-Verbose "  UI:   $poolControlServiceBaseUrl  (Board / Hosts / Pools)"
    } else {
        Write-Verbose "  UI:   not published -- this host cannot reach the daemon, so no URL is advertised. The pool still"
        Write-Verbose "        resolves the service from its own announce; the Yuruna hosts dashboard links it there."
    }
    if ($vmIp) { Write-Information "  SSH:  ssh pool-control-service-admin@$vmIp  (harness key authorized)" -InformationAction Continue }
    Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
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
Write-Warning "pool-control-service daemon $failureDetail -- $($verdict.Summary). Collecting in-guest diagnostics over the harness SSH key..."

# The MAC-match sweep above already ran on this path; reusing its answer
# keeps a second ICMP sweep out of a script that has already made the
# operator wait.
$diagIp = if ($vmIp) { [string]$vmIp } else { [string]$recoveredIp }
if (-not $diagIp) { Write-Information "  '$VMName' could not be located by any discovery route this host has." -InformationAction Continue }

Invoke-YurunaServiceVmFailureDiagnostic -ServiceName 'pool-control-service' -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' -VMName $VMName -Address $diagIp
Write-Verbose ""
Write-Information "The pool-control-service daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
Write-Information "  * cloud-init status 'running'  -> the in-guest build (go/pwsh) is still going; wait, then" -InformationAction Continue
Write-Verbose "                                    re-run to re-check (or raise YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS)."
Write-Information "  * 'cifs_mount failed' / -111   -> the pool NAS did not mount, so cloud-init stopped before the daemon" -InformationAction Continue
Write-Verbose "                                    was ever built. The console capture above shows this when SSH cannot."
Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
Write-Information "  * 'NAS mount failed'           -> pool NAS unreachable; re-check the pool storage credential." -InformationAction Continue
Write-Information "  * nothing at all over SSH      -> the console capture above is the remaining evidence." -InformationAction Continue
Write-Verbose "See https://yuruna.link/4207d71a-000c."
Write-Verbose ""
Write-Verbose "== pool-control-service start: FAILED (the daemon never served on :80) =="
Write-Verbose "  VM:   $VMName"
Write-Verbose "  Host: $HostType"
Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
exit $ExitFailure
