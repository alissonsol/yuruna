<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42f3caf7-8560-4882-9123-5ffeec757e6c
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
.EXAMPLE
    pwsh test/Start-DownloadAgentServiceVM.ps1
    # Builds + starts the VM, waits for :80, and publishes the marker.
.EXAMPLE
    $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = '120'
    pwsh test/Start-DownloadAgentServiceVM.ps1
    # Short readiness budget for a quick re-check of a VM that is already up.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service'
)

$InformationPreference = 'Continue'

# $ErrorActionPreference is deliberately left at its inherited 'Continue', and
# must stay that way. A script-scoped 'Stop' is not scoped to the script: an
# advanced function invoked from here runs under it too, so every helper this
# bring-up calls would have its NON-terminating errors promoted to terminating
# ones. Several of the steps below are built on exactly that tolerance -- the
# storage pre-flight warns and proceeds when the share does not answer, and the
# post-boot publish steps are reported-never-fatal. Under 'Stop' each of those
# designed outcomes ends the bring-up instead, and its reason is left on a
# console that is gone by the time anyone reads the run log. The sibling service
# bring-ups (stash, caching proxy) run at 'Continue' for the same reason. Where a
# condition really must stop this script, it says so itself with an explicit
# Write-Error + exit, as the pre-flight hard gates below do.

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# lines above on purpose: an explicit level is the operator's choice and replaces
# this script's own default. $InformationPreference is then re-read from the
# global the cascade writes, because the script-scoped assignment above shadows
# it for the rest of this file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
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
Write-Information "Host type: $HostType" -InformationAction Continue
[void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

# --- REGION: pool storage pre-flight
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
    try { $poolCfg = Get-YurunaPoolStorageConfig -Config $tc -IgnoreReplicate } catch { Write-Verbose "pool storage config: $($_.Exception.Message)" }
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
    Write-Information "pool storage pre-flight OK (networkUser='$($poolCfg.NetworkUser)'; credential authenticates)." -InformationAction Continue
} else {
    Write-Warning @"
pool networkUser '$($poolCfg.NetworkUser)' has a stored credential, but it did NOT
authenticate to the pool share '$($poolCfg.NetworkPath)' just now (wrong/stale password,
or the NAS is unreachable). Bringing the VM up anyway: the daemon will START but serve an
EMPTY pool -- every ensure answers 'pool-unavailable' and hosts fall back to downloading
for themselves -- until this is fixed. If the password is stale, update it and rebuild:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
"@
}

# --- REGION: resolve the per-host New-VM
$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.download-agent-service'
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit $ExitFailure
}

# --- REGION: host status service (serves the local repo to the guest) -- BEFORE the build
# The download-agent-service guest's cloud-init fetches the framework from
# http://<host>:<port>/yuruna-archive.tar.gz at first boot, and falls back to a
# public github clone when that server is down -- so it must be up BEFORE New-VM
# bakes and boots the guest, not after (a server started later is one the guest
# never saw). Best-effort; honors statusService.enabled + port.
try {
    $statusScript = Join-Path $repoRoot 'test/Start-StatusService.ps1'
    if ($tc -and (Test-Path -LiteralPath $statusScript)) {
        [void](Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript)
    }
} catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

# --- REGION: delegate to the per-host New-VM (build + start the VM)
# Each New-VM runs Get-Image auto-fetch when the base image is missing, tears
# down any prior VM, creates the new one, and (Hyper-V + KVM) starts it. UTM only
# builds the bundle -- register + start below.
if (-not $PSCmdlet.ShouldProcess($VMName, "Build and start the download-agent service VM on $HostType")) {
    Write-Information "Skipped: '$VMName' would be rebuilt on $HostType (nothing was changed)." -InformationAction Continue
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
    Write-Information "Starting '$VMName'..." -InformationAction Continue
    $startResult = Start-VM -VMName $VMName -Confirm:$false
    if (-not $startResult.success) {
        Write-Error "Could not start '$VMName': $($startResult.errorMessage)"
        exit $ExitFailure
    }
}

# --- REGION: the VM must be RUNNING before the daemon is blamed for anything
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

# --- REGION: post-boot readiness probe on :80 + on-failure guest diagnostics
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

$daemonReady = $false
if ($vmIp) {
    Write-Information "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the download-agent-service daemon to serve on :80 (first boot builds it in-guest)..." -InformationAction Continue
    $readyDeadline = (Get-Date).AddSeconds($readyTimeoutSeconds)
    $probeStart    = Get-Date
    $nextTick      = 30
    # Two very different faults look identical from out here -- a daemon still
    # building in-guest, and a daemon that has been serving for minutes on an
    # address this host cannot reach. Waiting helps the first and can never help
    # the second, so once the guest is far enough along to answer SSH, ask IT
    # whether anything is listening. Deferred to $reachabilityCheckAfterSeconds
    # because sshd is not up instantly and an early no-answer would prove nothing.
    $reachabilityCheckAfterSeconds = 120
    $reachabilityChecked = $false
    $listeningButUnreachable = $false
    while ((Get-Date) -lt $readyDeadline) {
        if (Test-DownloadAgentServicePort -Address $vmIp -Port 80 -TimeoutMilliseconds 1000) { $daemonReady = $true; break }
        $elapsed = [int]((Get-Date) - $probeStart).TotalSeconds
        if ($elapsed -ge $nextTick) {
            # Floor, not [int]: the cast rounds half-to-even, so 90s printed as
            # "02m30s" and the tick sequence read as though it went backwards
            # (04m30s before 04m00s).
            Write-Information ("  [{0:D2}m{1:D2}s / {2}m] still waiting for the daemon on :80..." -f [int][math]::Floor($elapsed / 60), ($elapsed % 60), $readyTimeoutMinutes) -InformationAction Continue
            $nextTick += 30
        }
        if (-not $reachabilityChecked -and $elapsed -ge $reachabilityCheckAfterSeconds -and
            (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
            $inGuest = $null
            try {
                $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.download-agent-service' `
                    -User 'download-agent-service-admin' -TimeoutSeconds 30 `
                    -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
            } catch { Write-Verbose "download-agent-service in-guest listener probe: $($_.Exception.Message)" }
            # Only a completed answer settles anything. SSH that did not connect
            # means the guest is still coming up, so leave the check unmade and
            # let a later pass ask again.
            if ($inGuest -and "$($inGuest.output)" -match 'YURUNA_(NOT_)?LISTENING') {
                $reachabilityChecked = $true
                if ("$($inGuest.output)" -match 'YURUNA_LISTENING') {
                    $listeningButUnreachable = $true
                    break
                }
                Write-Information "  (reachable over SSH; the daemon has not bound :80 in-guest yet -- still building)" -InformationAction Continue
            }
        }
        Start-Sleep -Seconds 3
    }
    if ($listeningButUnreachable) {
        $waited = [int]((Get-Date) - $probeStart).TotalSeconds
        Write-Warning @"
The download-agent-service daemon IS serving on :80 inside the guest, but this host
cannot open a connection to ${vmIp}:80 (gave up after ${waited}s; SSH to the same
guest works, so the VM is up and the daemon is running).

Waiting longer cannot fix this -- the daemon is already up. What is broken is the
path from this host to ${vmIp}:80:
  * $vmIp may not be this VM's current address. A stale DHCP lease resolves to
    whichever guest holds that address now; check the guest console's own
    "eth0: <ip>" line against $vmIp.
  * The guest firewall may be dropping :80 from outside (ufw).
  * On UTM Shared NAT, the host reaches the guest through the 192.168.64.0/24
    gateway only -- a bridged-mode address is not routable from here.
"@
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
                   "discovery, not a boot failure. The :80 readiness probe never ran -- going straight to guest diagnostics.")
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
# active tracks the READINESS VERDICT, not the fact that this script ran: a
# bring-up that ends at the failure exit below would otherwise advertise a
# download-agent service that is not serving, and hosts would route image
# requests at a dead endpoint instead of falling back to their own download path.
$downloadAgentServiceBaseUrl = Resolve-DownloadAgentServiceBaseUrl -VMIp ([string]$vmIp) -NetworkMode $bundleMode -HostAddress $hostAddress
[void](Write-DownloadAgentServiceMarker -RuntimeDir $runtimeDir -Active $daemonReady -VMName $VMName -HostType $HostType -BaseUrl $downloadAgentServiceBaseUrl)
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

if ($daemonReady) {
    Write-Information "" -InformationAction Continue
    Write-Information "== download-agent-service is READY (daemon serving on :80) ==" -InformationAction Continue
    Write-Information "  VM:   $VMName ($HostType)" -InformationAction Continue
    Write-Information "  UI:   $downloadAgentServiceBaseUrl  (pool inspection, Force refresh / Delete / Prune previous)" -InformationAction Continue
    Write-Information "  SSH:  ssh download-agent-service-admin@$vmIp  (harness key authorized)" -InformationAction Continue
    Write-Information "  Stop: test/Stop-DownloadAgentServiceVM.ps1" -InformationAction Continue
    Write-Information "  Unlock the UI's actions with the 6-character Lab token from the Yuruna hosts dashboard (docs/download-agent.md)." -InformationAction Continue
    exit $ExitOk
}

# Not serving. Collect the in-guest build log + service state over the harness
# key (download-agent-service-admin, NOPASSWD sudo) so the operator sees the
# actual failure instead of a dead URL. -User pins the account the cloud-init
# seed created: it is the only login this VM has, and Get-GuestSshUser would
# otherwise return a per-cycle cascade override that an earlier run in this same
# shell session left registered for guest.download-agent-service.
# Says what ACTUALLY happened, not what the budget allowed. Two very different
# failures reach this line -- an address that never appeared, and an address that
# never answered -- and quoting the nominal timeout for the first one describes a
# wait that did not occur, sending the reader to look for a fifteen-minute
# in-guest build behind a failure that took seconds.
$failureDetail = if ($vmIp) {
    "is NOT serving on :80 (VM $vmIp) after $readyTimeoutMinutes min"
} else {
    "never got an address (no IP after ${ipWaitSeconds}s), so :80 was never probed"
}
Write-Warning "download-agent-service daemon $failureDetail. Collecting in-guest diagnostics over the harness SSH key..."
$diagCmd = @(
    'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
    'echo "=== systemctl status download-agent-service.service ==="; systemctl --no-pager --full status download-agent-service.service 2>&1 | head -n 25',
    'echo "=== journalctl -u download-agent-service.service (last 40) ==="; sudo journalctl -u download-agent-service.service --no-pager -n 40 2>&1',
    'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
    'echo "=== pool mount ==="; findmnt /mnt/yuruna-pool 2>&1 || echo "(/mnt/yuruna-pool is not mounted)"',
    'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
) -join "`n"
$diag = $null
if ($vmIp -and (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
    try { $diag = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.download-agent-service' -User 'download-agent-service-admin' -Command $diagCmd -TimeoutSeconds 120 }
    catch { Write-Verbose "guest diagnostics ssh: $($_.Exception.Message)" }
}
Write-Information "" -InformationAction Continue
Write-Information "================= download-agent-service guest diagnostics =================" -InformationAction Continue
if ($diag -and -not [string]::IsNullOrWhiteSpace([string]$diag.output)) {
    foreach ($line in ([string]$diag.output -split "`r?`n")) { Write-Information "  $line" -InformationAction Continue }
    if (-not $diag.success) {
        Write-Information "  (ssh ended with exit=$($diag.exitCode); the capture above is what completed before it did)" -InformationAction Continue
    }
} else {
    Write-Information "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)." -InformationAction Continue
    if ($vmIp) { Write-Information "  Try manually:  ssh download-agent-service-admin@$vmIp 'sudo tail -n 120 /var/log/cloud-init-output.log'" -InformationAction Continue }
}
Write-Information "===========================================================================" -InformationAction Continue
Write-Information "" -InformationAction Continue
Write-Information "The download-agent-service daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
Write-Information "  * cloud-init status 'running'  -> the in-guest build (golang) is still going; wait, then" -InformationAction Continue
Write-Information "                                    re-run to re-check (or raise YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS)." -InformationAction Continue
Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
Write-Information "  * '/mnt/yuruna-pool' unmounted -> the pool share is unreachable; re-check the pool storage credential." -InformationAction Continue
Write-Information "                                    The daemon still serves, so this is a pool fault, not a build fault." -InformationAction Continue
if ($vmIp) { Write-Information "Re-check any time:  ssh download-agent-service-admin@$vmIp 'systemctl status download-agent-service.service'" -InformationAction Continue }
Write-Information "See docs/download-agent.md." -InformationAction Continue
exit $ExitFailure
