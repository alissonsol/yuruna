<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42f17d0e-cf42-4655-b11b-a34a4a0b449c
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

<#
.SYNOPSIS
    Bring up the Download-agent service on THIS host by building + launching it
    on its OWN VM, and publish its marker.
.DESCRIPTION
    Like Start-StashServiceVM / Start-PoolControlServiceVM, this brings the
    service up on a dedicated VM (guest.download-agent-service): it runs the
    pool-storage pre-flight, then delegates to the per-host New-VM.ps1, whose
    cloud-init fetches the framework and runs the bring-up script that builds
    the Go daemon, CIFS-mounts the pool share at /mnt/yuruna-pool for the image
    pool, and launches the daemon under systemd (UI + API on :80) INSIDE the
    guest -- no Go toolchain is needed on the host.

    Writes runtime/download-agent-service.json (the marker Test.Capability folds
    into host.registration.json so the service shows up in the Extension hosts
    table) and refreshes the registration record so the host appears within one
    aggregator poll. The Go service also self-announces to the aggregator via
    its beacon, so the Extension-hosts row appears by marker AND by beacon
    independently.
.PARAMETER VMName
    Name of the download-agent-service VM. Default:
    yuruna-download-agent-service.
.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
    Without it, a bring-up whose guest could not fetch this host's framework --
    or one whose daemon turns out to have been built from another snapshot -- is
    refused rather than deploying code older than the operator is working in.
    Legitimate off-LAN, where the mirror is the only source there is.
.EXAMPLE
    pwsh test/service/Start-DownloadAgentServiceVM.ps1
    # Builds + starts the VM, waits for :80, and publishes the marker.
.EXAMPLE
    $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = '120'
    pwsh test/service/Start-DownloadAgentServiceVM.ps1
    # Short readiness budget for a quick re-check of a VM that is already up.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service',
    [switch]$AllowMirrorSource
)

$InformationPreference = 'Continue'

# --- REGION: https://yuruna.link/extensions-api#service-scripts-run-at-erroractionpreference-continue
# Left at the inherited 'Continue' deliberately, and it must stay that way:
# 'Stop' is not scoped to this script and would promote every helper's
# non-terminating error. Hard stops here are explicit Write-Error + exit, as the
# pre-flight hard gates below do.

# --- REGION: https://yuruna.link/loglevels#propagation-across-pwsh-boundaries
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default. $InformationPreference
# is re-read afterwards because the script-scoped assignment above shadows the
# global the cascade writes.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit $ExitFailure
}

# Windows has no mid-run elevation: the Hyper-V guest.download-agent-service
# New-VM.ps1 refuses without Administrator -- but only after the pool-storage
# pre-flight and the status-service start have already run. Check NOW, while
# nothing has changed. Windows only -- neither the UTM nor the KVM New-VM.ps1
# has such a gate. The inline principal expression is deliberate: no module is
# loaded yet.
if ($IsWindows -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "This script requires elevation (Run as Administrator)."
    Write-Output "Start-DownloadAgentServiceVM needs an elevated session to:"
    Write-Output "  * query Hyper-V for the VHD folder (Get-VMHost)"
    Write-Output "  * create and remove the '$VMName' VM and its disk"
    Write-Output "Re-launch PowerShell as Administrator and run this script again."
    Write-Error "Start-DownloadAgentServiceVM requires Administrator on Windows. Nothing was changed."
    exit $ExitFailure
}

# Initialize-YurunaEntryPoint returns only paths -- it imports no modules -- so
# pull in Test.YurunaDir explicitly for Initialize-YurunaRuntimeDir /
# Get-YurunaHostId. Initialize-YurunaRuntimeDir DEFAULTS + creates
# <testRoot>/status/runtime when $env:YURUNA_RUNTIME_DIR is unset, so the marker
# always has a home on a fresh shell instead of depending on an inherited env var.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.DownloadAgentService.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Verbose "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

# --- REGION: Pool storage pre-flight
# The image pool IS the pool share: the daemon serves generations out of
# <pool>/images and writes its audit log + status under
# <pool>/download-agent-service. Refuse to bring up a VM that would have nothing
# to serve: fail fast HERE, before the long VM build, when the pool storage is
# unconfigured or its NAS credential is not stored.
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1')      -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Extension.psm1')   -Global -Force
$null = @(Import-Extension -Area 'authentication' -RequireSingle)
$tcPath = Join-Path $repoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $tcPath) {
    try { $tc = Read-TestConfig -Path $tcPath } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
}
$poolCfg = $null
if ($tc) {
    try { $poolCfg = Get-YurunaPoolStorageConfig -Config $tc } catch { Write-Verbose "pool storage config: $($_.Exception.Message)" }
}
if (-not $poolCfg) {
    Write-Error @"
Start-DownloadAgentServiceVM requires the pool storage to be configured:
set networkStorage.poolStorageNetworkPath / poolStorageNetworkUser / poolStorageLocalPath in
test/test.config.yml and Set-Password the poolStorageNetworkUser. See docs/test-config.md
and docs/download-agent.md.
"@
    exit $ExitFailure
}
# Hard gate: a REAL password must already be stored for the pool SMB user.
# A mapped-but-unstored vaultKey would make the seed bake an AUTO-GENERATED
# junk password the NAS rejects (cifs mount error(13)); the SMB user
# authenticates to a PRE-EXISTING NAS account, so require a stored entry.
if (-not (Test-PoolStorageStoredCredential -Config $poolCfg)) {
    Write-Error @"
pool networkUser '$($poolCfg.NetworkUser)' has NO password stored in the vault.
The download-agent-service VM mounts the pool share with this account; without a stored
credential the VM seed bakes an auto-generated value the NAS rejects (cifs mount
error(13)), so the image pool never mounts. Store the real NAS password first, then re-run:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
    exit $ExitFailure
}
# Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
# pool share. WARNING, not a hard stop: the daemon stays up and reports
# poolAvailable:false when the share is offline, and the NAS may merely be
# transiently unreachable.
if (Connect-YurunaPoolStorage -Config $poolCfg -Confirm:$false) {
    Write-Verbose "pool storage pre-flight OK (networkUser='$($poolCfg.NetworkUser)'; credential authenticates)."
} else {
    # Report the reason the mount RECORDED, and prescribe from it. A mount that
    # sudo refused never reaches the NAS, so naming the credential there sends
    # the operator to reset a password that was never wrong -- and to rebuild the
    # VM for it -- while the actual fault stays in place.
    $why = Get-PoolStorageLastMountError
    if (-not $why) { $why = 'the attempt recorded no reason (check that the NAS is reachable and the share name is right).' }
    $remedy = if (Test-PoolStorageSudoRefusal -StdErr $why) {
        "sudo refused the mount, so the pool credential is NOT implicated. Fix passwordless
sudo for mount on this host (see docs/pool-storage.md) or run Sync-HostConfiguration, then
re-run. No rebuild is needed once the mount works."
    } else {
        "If the password is stale, update it and rebuild:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'"
    }
    Write-Warning @"
pool share '$($poolCfg.NetworkPath)' did NOT mount just now as networkUser
'$($poolCfg.NetworkUser)': $why
Bringing the VM up anyway: the daemon will START but serve an EMPTY pool -- every ensure
answers 'pool-unavailable' and hosts fall back to downloading for themselves -- until this
is fixed.
$remedy
"@
}

# --- REGION: Resolve the per-host New-VM
$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.download-agent-service'
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit $ExitFailure
}

# --- REGION: Host status service (serves the local repo to the guest) -- BEFORE the build
# --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
# Best-effort; honors statusService.enabled + port. The {ShouldStart; Port}
# record is kept rather than discarded: the framework-source gate below probes
# the port THIS decision resolved, so it cannot disagree with the config reading
# that started the server.
$statusDecision = $null
try {
    $statusScript = Join-Path $repoRoot 'test/service/Start-StatusService.ps1'
    if ($tc -and (Test-Path -LiteralPath $statusScript)) {
        $statusResult = Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript
        $statusDecision = @($statusResult | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
    }
} catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

# --- REGION: Framework source -- refuse to build from a snapshot older than this enlistment
# --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
# Stopping here costs the operator a message; not stopping costs a half-hour
# build and a service nobody has reason to re-examine. The snapshot is captured
# for the post-boot check too, which is the half that can prove what got
# deployed.
Import-Module (Join-Path $ModulesDir 'Test.FrameworkSource.psm1') -Global -Force
$frameworkExpected = Get-FrameworkSourceSnapshot -RepoRoot $repoRoot
if (-not (Assert-GuestFrameworkSource -RepoRoot $repoRoot -StatusDecision $statusDecision `
            -ServiceLabel 'download-agent-service' -AllowMirrorSource:$AllowMirrorSource)) {
    exit $ExitFailure
}

# --- REGION: Delegate to the per-host New-VM (build + start the VM)
# Each New-VM runs Get-Image auto-fetch when the base image is missing, tears
# down any prior VM, creates the new one, and (Hyper-V + KVM) starts it. UTM only
# builds the bundle -- register + start below.
if (-not $PSCmdlet.ShouldProcess($VMName, "Build and start the download-agent service VM on $HostType")) {
    Write-Verbose "Skipped: '$VMName' would be rebuilt on $HostType (nothing was changed)."
    exit $ExitOk
}
Write-Information "== Bringing up '$VMName' on $HostType ==" -InformationAction Continue
& pwsh -NoProfile -File $newVm -VMName $VMName
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Error "$newVm exited $rc -- aborting."
    exit $rc
}

# --- REGION: UTM register + start (Hyper-V/KVM already started in New-VM)
# Hyper-V and KVM already started the VM inside New-VM.ps1; only UTM needs
# registration + start here. The host contract's Start-VM owns the whole UTM
# sequence -- VNC-display arbitration, the custom-QEMU-args dialog watchdog
# (without which this bring-up cannot run unattended, because UTM blocks on a
# modal), open, utmctl start, and the exit-0-but-QEMU-died check.
if ($HostType -eq 'host.macos.utm') {
    $UtmDir = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $UtmDir)) {
        Write-Error "UTM bundle missing at $UtmDir after New-VM."
        exit $ExitFailure
    }
    Write-Verbose "Starting '$VMName'..."
    $startResult = Start-VM -VMName $VMName -Confirm:$false
    if (-not $startResult.success) {
        Write-Error "Could not start '$VMName': $($startResult.errorMessage)"
        exit $ExitFailure
    }
}

# --- REGION: The VM must be RUNNING before the daemon is blamed for anything
# `utmctl start` can exit 0 while UTM silently drops the request, and Hyper-V/KVM
# start the VM inside New-VM.ps1 without this script ever checking the result.
# Without this gate the readiness probe below attributes a VM that never booted
# to cloud-init, the go build, or the pool share -- none of which ran -- and the
# host advertises a download-agent service that does not exist.
if (-not (Wait-VMRunning -VMName $VMName -TimeoutSeconds 120)) {
    $observed = try { Get-VMState -VMName $VMName } catch { 'unknown' }
    Write-Error "VM '$VMName' did not reach 'running' (state: $observed); the download-agent service was NOT started. Nothing in the guest -- cloud-init, the go build, the pool share mount -- has run yet. Open the VM in the hypervisor UI and start it by hand to see why."
    exit $ExitFailure
}

Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
# Wait-VMIp, not a single Get-VMIp. A guest that has just been started has no
# address for the first several seconds -- on UTM Shared NAT it appears only
# once DHCP completes -- and a one-shot call there returns empty, which used to
# skip the readiness probe entirely and report the service as failed seconds
# after the VM booted. "No address yet" and "daemon still building" are the same
# wait to an operator, so the address wait draws from the SAME readiness budget
# as the port probe rather than being a separate, invisible give-up.
$ipDeadline = (Get-Date)
$vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
$ipWaitSeconds = [int]((Get-Date) - $ipDeadline).TotalSeconds

# --- REGION: Shared NAT -> forward a host port so peers can still reach the UI
# A Bridged VM takes a LAN lease and peers reach the UI at <vm-lan-ip>:80.
# vmnet cannot bridge a Wi-Fi uplink, so on a Wi-Fi host New-VM builds this VM
# on UTM Shared NAT instead, where it is invisible to the LAN -- the host's own
# LAN address is the only way in. The bundle is the source of truth for which
# mode the VM is actually on: a host that has since moved between Wi-Fi and
# Ethernet needs a rebuild, not a different guess here.
$bundleMode  = ''
$hostAddress = ''
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = [string](Get-UtmNetworkModeFromBundle -VMName $VMName)
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; rebuild it (Stop-DownloadAgentServiceVM.ps1 then re-run this script)."
    }
    # Host port 8082, not 80: on a shared-services machine the caching proxy
    # already forwards host :80 (its CA-cert endpoint), the stash service owns
    # 2222, and the pool-control service owns 8081. Asking for a port already
    # forwarded would attach to that forwarder and publish the WRONG service at
    # the URL this script then advertises.
    if ($bundleMode -eq 'Shared') {
        if ($vmIp) {
            $mapped = Add-PortMap -VMIp $vmIp -Port @() -PortRemap @{ 8082 = 80 } -Confirm:$false
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

# --- REGION: Post-boot readiness probe on :80 + on-failure guest diagnostics
# New-VM confirmed the VM has an IP, but the daemon still has to build INSIDE
# the guest (apt golang, go build, CIFS mount, systemd start), which takes
# several minutes on first boot -- so an IP alone is NOT "the service is up".
# Probe :80 until it actually serves before declaring success. If it never comes
# up, pull the in-guest build log + cloud-init status + service journal over the
# harness SSH key so the operator sees WHY without SSHing in blind.
# download-agent-service-admin has NOPASSWD sudo in the seed, so `sudo tail`
# reads /var/log/cloud-init-output.log (root-only -- a plain `tail` as
# download-agent-service-admin returns Permission denied).
$readyTimeoutSeconds = Get-DownloadAgentServiceReadyTimeoutSeconds
$readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)
# How long a guest located by the last-resort route below gets to answer on :80.
# Deliberately short: it runs only after the ordinary wait has already spent its
# whole budget, and it is confirming a listener that either answers within a few
# polls or was never there.
$recoveryProbeSeconds = 60

# ONE readiness verdict for the whole script, and it starts $false: every path
# that never confirmed a listener -- including the paths that never got far
# enough to probe one -- must publish an INACTIVE marker rather than an
# optimistic one. The aggregator paints the Extension-hosts row and its
# deep-link from this value, so a marker that says "active" because the script
# merely ran routes peers' image requests at an endpoint that is not serving,
# instead of letting them fall back to downloading for themselves.
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
# The wait resolves the guest's address on EVERY poll rather than trusting the
# one resolved above: a guest re-requests DHCP under a changed client identity
# while cloud-init runs, so the address discovered at boot is frequently one the
# guest abandons seconds later. Following it also keeps the host-side forwarder
# pointed at the live address instead of leaving it dialing an abandoned one --
# a forwarder that accepts and cannot connect is worse than one that is down,
# because callers hang for a full timeout instead of failing fast.
if ($vmIp) {
    Write-Verbose "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the download-agent-service daemon to serve on :80 (first boot builds it in-guest)."
    Write-Verbose "  The wait extends itself while the guest reports it is still building; progress is printed as it happens."
    Write-Verbose "  Override the budget with YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS."
    $repointForwarder = {
        param($newAddress)
        $script:vmIp = $newAddress
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            if (Add-PortMap -VMIp $newAddress -Port @() -PortRemap @{ 8082 = 80 } -Confirm:$false) {
                $script:hostAddress = [string](Get-BestHostIp)
                Write-Verbose "  Re-pointed host :8082 -> ${newAddress}:80."
            }
        }
    }
    # Wait-YurunaServiceVmDaemon rather than the wait underneath it: the wait
    # takes a FIXED progress label and prints it unchanged for the whole budget,
    # so a guest sitting at a login prompt with cloud-init dead reads identically
    # to one mid-compile -- and the operator waits out the full budget on the
    # strength of a line nothing measured. This one paints from what was actually
    # observed of the guest.
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
    # The VM is confirmed RUNNING by the state gate above, so this is a host-side
    # address-discovery gap, not a VM that failed to start. On UTM a Bridged guest
    # has no dhcpd lease and no guest agent, so this is the normal path there
    # rather than an anomaly.
    #
    # The elapsed wait is named because the number is the whole diagnosis: a few
    # seconds means the address lookup itself is unsupported for this networking
    # mode, while the full budget means DHCP never completed. Reporting the
    # nominal readiness timeout here instead -- for a probe that never ran --
    # is what made an eight-second failure read as a fifteen-minute one.
    Write-Warning ("Could not resolve the VM's IP after waiting ${ipWaitSeconds}s (Wait-VMIp); the VM IS running, so this is address " +
                   "discovery, not a boot failure. Asking the guest itself whether the daemon is up.")
    # Address discovery failing is not the same as the service failing, and the
    # two must not share a verdict. SSH resolves the guest by NAME through its
    # own path, so it can still get in where the lease lookup found nothing --
    # and the daemon's answer is the fact that matters. A service confirmed up
    # here is advertised by presence alone (no host-side URL to offer), and its
    # own announce is what carries the address to the pool.
    if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
        $inGuest = $null
        try {
            $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.download-agent-service' `
                -User 'download-agent-service-admin' -TimeoutSeconds 30 `
                -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
        } catch { Write-Verbose "download-agent-service in-guest listener probe: $($_.Exception.Message)" }
        if ($inGuest -and "$($inGuest.output)" -match 'YURUNA_LISTENING') {
            # The guest's own answer IS this path's readiness record. No wait
            # ran, so there is nothing else to hand the verdict below, and
            # "bound inside the guest, unreachable from here" is precisely what
            # the Unreachable outcome names. Shaping it like the wait's record
            # keeps one decision function for both paths instead of a second
            # opinion that can disagree with the first.
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

# --- REGION: One place decides whether this bring-up succeeded
# The script routes on that decision instead of each site judging for itself. A
# readiness timeout is a FAILURE: a run that records PASS for a daemon that
# never started sends the operator looking for the fault in whatever breaks
# next, which is the most expensive place to look for this one.
$verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint

# --- REGION: https://yuruna.link/network#why-a-mac-sweep-is-spent-only-on-a-failed-bring-up
# Spent here and nowhere else: the sweep costs about two minutes, and this is
# the one place where the alternative is calling a healthy daemon failed.
$recoveredIp = ''
if ($verdict.IsFailure) {
    $recoveredIp = Resolve-GuestDiagnosticAddress -VMName $VMName
    if ($recoveredIp -and $recoveredIp -ne [string]$vmIp) {
        Write-Warning "Located '$VMName' at $recoveredIp -- an address the readiness wait never probed. Re-checking :80 there before failing the bring-up."
        # Bounded by the wall clock rather than an iteration count: the bound
        # that matters to the operator is a duration, and each probe's own
        # timeout stretches under load -- so a counted loop silently becomes an
        # unbounded one exactly when the host is busiest.
        $readyDeadline = (Get-Date).AddSeconds($recoveryProbeSeconds)
        while (-not $daemonReady -and (Get-Date) -lt $readyDeadline) {
            if (Test-DownloadAgentServicePort -Address $recoveredIp -Port 80) {
                $daemonReady = $true
            } else {
                Start-Sleep -Seconds 3
            }
        }
        if ($daemonReady) {
            Write-Verbose "  The daemon IS serving at ${recoveredIp}:80 -- the wait was probing an address this guest never had."
            $vmIp = $recoveredIp
            # Re-decided through the same helper rather than set by hand: two
            # ways of producing a verdict are two verdicts that can disagree
            # with each other.
            $endpoint = [pscustomobject]@{
                Ready         = $true
                Unreachable   = $false
                StillBuilding = $false
                Address       = $recoveredIp
                WaitedSeconds = $(if ($endpoint) { $endpoint.WaitedSeconds } else { $ipWaitSeconds })
                # Names the route, not the rung. The last-resort lookup tries
                # the ordinary resolver before it reaches the bundle MAC, so
                # which one answered is not knowable from here -- and a record
                # that asserts a mechanism which may not have run is the same
                # false lead as a probe that never happened.
                ObservedState = 'located by the last-resort guest discovery once the readiness wait had no address for it, then confirmed serving on :80'
            }
            $verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint
            # The forwarder has to follow, or peers keep dialing an address that
            # accepts on this host and then cannot connect -- which hangs every
            # caller for a full timeout instead of failing fast, strictly worse
            # than no forwarder at all.
            if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
                if (Add-PortMap -VMIp $recoveredIp -Port @() -PortRemap @{ 8082 = 80 } -Confirm:$false) {
                    $hostAddress = [string](Get-BestHostIp)
                    Write-Verbose "  Re-pointed host :8082 -> ${recoveredIp}:80."
                }
            }
        } else {
            Write-Warning "${recoveredIp}:80 did not answer within ${recoveryProbeSeconds}s either, so the guest was found but its daemon is not serving."
        }
    }
}

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

# Publish the marker + refresh registration: write
# runtime/download-agent-service.json, then regenerate host.registration.json so
# the aggregator lists this host under Extension hosts on its next poll -- not
# only after the next test cycle. downloadAgentServiceBaseUrl gives the Extension
# cell a deep-link even before the daemon's first beacon, and on UTM Shared NAT
# it is the ONLY endpoint peers can use (the beacon's announce address is
# source-IP-derived, so the aggregator sees the NAT'd host address without the
# forwarded port). The registration refresh is best-effort telemetry and must
# never fail the bring-up. Write-HostRegistrationRecord reads
# $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
#
# --- REGION: https://yuruna.link/extensions-api#3-the-host-side-module--the-runtime-marker
#
# Here the readiness verdict decides whether peers route image requests at an
# endpoint that is not serving instead of falling back to their own download
# path -- so `active` carries the verdict, never "the bring-up script ran".
#
# A URL is published only where THIS host opened the port itself. The degraded
# tier -- the guest confirmed the daemon bound, this host has no route to it --
# stays advertised as active with no URL: the service exists and peers reach it
# through its own announce, while a link only this host cannot follow would send
# every reader to a dead endpoint.
$downloadAgentServiceBaseUrl = if ($daemonReady -and -not $listeningButUnreachable) {
    Resolve-DownloadAgentServiceBaseUrl -VMIp ([string]$vmIp) -NetworkMode $bundleMode -HostAddress $hostAddress
} else { '' }
[void](Write-DownloadAgentServiceMarker -RuntimeDir $runtimeDir -Active $daemonReady -VMName $VMName -HostType $HostType -BaseUrl $downloadAgentServiceBaseUrl)
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

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
    # --- REGION: What actually got deployed
    # --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
    # The daemon is serving, so this is the first point where the framework it
    # was built from can be answered from evidence rather than prediction.
    if (-not (Assert-ServiceVmFrameworkSource -Address ([string]$vmIp) -Port 80 `
                -GuestKey 'guest.download-agent-service' -User 'download-agent-service-admin' `
                -Expected $frameworkExpected -ServiceLabel 'download-agent-service' `
                -AllowMirrorSource:$AllowMirrorSource)) {
        Write-Verbose ""
        Write-Verbose "== download-agent-service start: FAILED (deployed an obsolete framework snapshot) =="
        Write-Verbose "  VM:   $VMName ($HostType)"
        Write-Information "  The VM is up and the daemon is serving -- it is running the WRONG BUILD, not nothing." -InformationAction Continue
        Write-Verbose "  Stop: test/service/Stop-DownloadAgentServiceVM.ps1"
        exit $ExitFailure
    }

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

# --- REGION: The daemon never served -- gather the evidence, then FAIL
# --- REGION: https://yuruna.link/extensions-api#a-service-that-never-served-fails-loudly
# -User pins the account the cloud-init seed created: Get-GuestSshUser would
# otherwise return a per-cycle cascade override that an earlier run in this same
# shell session left registered for guest.download-agent-service.
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

# The console frame answers what SSH cannot reach to answer. A guest that
# stopped at a failed cifs mount, or sits at a login prompt with cloud-init
# dead, shows exactly that on screen while every host-side probe can only report
# silence.
try {
    $logDir = Initialize-YurunaLogDir
    if ($logDir -and (Get-Command Get-VMScreenshot -ErrorAction SilentlyContinue)) {
        $consolePng = Join-Path $logDir "download-agent-service-console_${VMName}.png"
        $captured = Get-VMScreenshot -VMName $VMName -OutFile $consolePng
        # Get-VMScreenshot can report truthy without writing the file, so the
        # path is advertised only once it is on disk.
        if ($captured -and (Test-Path -LiteralPath $consolePng)) {
            Write-Verbose "  Guest console captured: $consolePng"
        } else {
            Write-Information "  Guest console could not be captured (the hypervisor returned no frame)." -InformationAction Continue
        }
    }
} catch { Write-Verbose "download-agent-service console capture: $($_.Exception.Message)" }

$diagCmd = @(
    # First, because it is the fact that settles the most common confusion here:
    # when the guest's own address differs from the one this host probed, the
    # daemon was never the problem. Printing both side by side names that
    # immediately instead of leaving it to be inferred from a service journal.
    "echo `"=== guest addresses (this host probed: $(if ($diagIp) { $diagIp } else { '<none resolved>' })) ===`"; ip -4 -o addr show scope global 2>&1 | awk '{print `$2, `$4}'",
    'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
    'echo "=== systemctl status download-agent-service.service ==="; systemctl --no-pager --full status download-agent-service.service 2>&1 | head -n 25',
    'echo "=== journalctl -u download-agent-service.service (last 40) ==="; sudo journalctl -u download-agent-service.service --no-pager -n 40 2>&1',
    'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
    'echo "=== pool mount ==="; findmnt /mnt/yuruna-pool 2>&1 || echo "(/mnt/yuruna-pool is not mounted)"',
    'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
) -join "`n"
$diag = $null
# Not gated on an address: SSH resolves the guest by name through its own path,
# so it often gets in when the lease lookup found nothing -- and "no address" is
# exactly the failure whose diagnosis lives inside the guest. Dialed at the
# address discovered above whenever there is one: Invoke-GuestSsh hands a literal
# address straight back, so a name and an address are equally acceptable to it,
# but passing the NAME here would re-run the very lookup that already came back
# empty and discard the only thing that located the guest.
$sshTarget = if ($diagIp) { $diagIp } else { $VMName }
if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
    try { $diag = Invoke-GuestSsh -VMName $sshTarget -GuestKey 'guest.download-agent-service' -User 'download-agent-service-admin' -Command $diagCmd -TimeoutSeconds 120 }
    catch { Write-Verbose "guest diagnostics ssh: $($_.Exception.Message)" }
}
Write-Verbose ""
Write-Information "================= download-agent-service guest diagnostics =================" -InformationAction Continue
if ($diag -and -not [string]::IsNullOrWhiteSpace([string]$diag.output)) {
    foreach ($line in ([string]$diag.output -split "`r?`n")) { Write-Information "  $line" -InformationAction Continue }
    if (-not $diag.success) {
        Write-Verbose "  (ssh ended with exit=$($diag.exitCode); the capture above is what completed before it did)"
    }
} else {
    Write-Information "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)." -InformationAction Continue
    # Never an ssh line with a hole where the host should be: an address this
    # host never learned makes the command unrunnable AND hides the fact that is
    # actually blocking the reader.
    foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'download-agent-service-admin' -Address $diagIp -VMName $VMName `
                -Command 'sudo tail -n 120 /var/log/cloud-init-output.log') -split "`r?`n")) {
        Write-Verbose "  $hintLine"
    }
}
Write-Verbose "==========================================================================="
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
