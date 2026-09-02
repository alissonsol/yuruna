<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42d07272-8c12-4ba7-807e-c0b201076d87
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

<#
.SYNOPSIS
    Brings up the Yuruna stash service VM (host.windows.hyper-v,
    host.ubuntu.kvm, host.macos.utm). See
    https://yuruna.link/stash-guide for the stash user guide.

.PARAMETER VMName   Name for the stash-service VM. Default: yuruna-stash-service.

.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
    Without it, a bring-up whose guest could not fetch this host's framework --
    or one whose daemon turns out to have been built from another snapshot --
    is refused rather than deploying code older than the operator is working in.
    Legitimate off-LAN, where the mirror is the only source there is.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service",
    [switch]$AllowMirrorSource
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

# --- REGION: https://yuruna.link/loglevels#propagation-across-pwsh-boundaries
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
$RepoRoot    = $paths.RepoRoot
$ModulesDir  = $paths.ModulesDir

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit $ExitFailure
}

# Windows has no mid-run elevation: the Hyper-V guest.stash-service New-VM.ps1
# this script delegates to refuses without Administrator -- but only after the
# stash-NAS mount pre-flight and the status-service start have already run and
# left a mapping and a detached process behind. Check NOW, while nothing has
# changed. Windows only: the UTM and KVM New-VM.ps1 have no Administrator gate,
# and KVM's libvirt group access is handled by Invoke-LibvirtGroupReExecIfNeeded
# below. The inline principal expression is deliberate -- no module is loaded yet.
if ($IsWindows -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Verbose ""
    Write-Output "This script requires elevation (Run as Administrator)."
    Write-Output "Start-StashServiceVM needs an elevated session to:"
    Write-Verbose "  * query Hyper-V for the VHD folder (Get-VMHost)"
    Write-Verbose "  * create and remove the '$VMName' VM and its disk"
    Write-Output "Re-launch PowerShell as Administrator and run this script again."
    Write-Error "Start-StashServiceVM requires Administrator on Windows. Nothing was changed."
    exit $ExitFailure
}

# Same module set as Start-CachingProxyServiceVM: Test.HostContract (for Get-HostType /
# Initialize-YurunaHost), Test.VMUtility (host-agnostic helpers),
# Test.CachingProxyService reuse not needed here (stash-service VM is independent of
# the cache).
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit $ExitFailure }
Write-Verbose "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- REGION: Stash storage pre-flight
# The stash service stores its files on its OWN, isolated stash share
# (networkStorage.stash*), separate from the pool. Refuse to bring up a VM that
# would have nowhere durable to write: fail fast HERE, before the long VM build,
# when the stash storage is unconfigured or its NAS credential is not stored.
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1')      -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Extension.psm1')   -Global -Force
$null = @(Import-Extension -Area 'authentication' -RequireSingle)
$tcPath = Join-Path $RepoRoot 'test/test.config.yml'
$tc = $null
if (Test-Path -LiteralPath $tcPath) {
    try { $tc = Read-TestConfig -Path $tcPath } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
}
$stashCfg = $null
if ($tc) {
    try { $stashCfg = Get-YurunaStashStorageConfig -Config $tc } catch { Write-Verbose "stash storage config: $($_.Exception.Message)" }
}
if (-not $stashCfg) {
    Write-Error @"
Start-StashServiceVM requires the stash storage to be configured (isolated from the pool):
set networkStorage.stashStorageNetworkPath / stashStorageNetworkUser / stashStorageLocalPath in
test/test.config.yml and Set-Password the stashStorageNetworkUser. See docs/test-config.md.
"@
    exit $ExitFailure
}
# Hard gate: a REAL password must already be stored for the stash SMB user.
# Test-PoolStorageVaultReady is too lenient here -- it also passes when only a
# vaultKey is MAPPED (no stored password), which makes the seed bake an
# AUTO-GENERATED junk password the NAS rejects (cifs mount error(13)). The SMB
# user authenticates to a PRE-EXISTING NAS account, so require a stored entry.
if (-not (Test-PoolStorageStoredCredential -Config $stashCfg)) {
    Write-Error @"
stash networkUser '$($stashCfg.NetworkUser)' has NO password stored in the vault.
The stash-service VM mounts the stash share with this account; without a stored credential the
VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
share never mounts. Store the real NAS password first, then re-run:
    Set-Password -Username '$($stashCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
    exit $ExitFailure
}
# Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
# stash share (catches a stale/wrong stored password, which the read-only check
# above cannot). WARNING, not a hard stop: the daemon buffers locally when the
# share is offline, and the NAS may merely be
# transiently unreachable. Connect-YurunaPoolStorage is bounded + best-effort and
# uses the SAME credential the seed will bake.
if (Connect-YurunaPoolStorage -Config $stashCfg -Confirm:$false) {
    Write-Verbose "stash storage pre-flight OK (networkUser='$($stashCfg.NetworkUser)'; credential authenticates)."
} else {
    # Report the reason the mount RECORDED, and prescribe from it. A mount that
    # sudo refused never reaches the NAS, so naming the credential there sends
    # the operator to reset a password that was never wrong -- and to rebuild the
    # VM for it -- while the actual fault stays in place.
    $why = Get-PoolStorageLastMountError
    if (-not $why) { $why = 'the attempt recorded no reason (check that the NAS is reachable and the share name is right).' }
    $remedy = if (Test-PoolStorageSudoRefusal -StdErr $why) {
        "sudo refused the mount, so the stash credential is NOT implicated. Fix passwordless
sudo for mount on this host (see docs/pool-storage.md) or run Sync-HostConfiguration, then
re-run. No rebuild is needed once the mount works."
    } else {
        "If the password is stale, update it and rebuild:
    Set-Password -Username '$($stashCfg.NetworkUser)' -NewPassword '<the real NAS password>'"
    }
    Write-Warning @"
stash share '$($stashCfg.NetworkPath)' did NOT mount just now as networkUser
'$($stashCfg.NetworkUser)': $why
Bringing the VM up anyway: the daemon will START and BUFFER uploads locally, but they will
NOT persist to the stash share until this is fixed.
$remedy
"@
}

# --- REGION: Resolve the per-host New-VM
$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $RepoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.stash-service'
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit $ExitFailure
}

# --- REGION: Host status service (serves the local repo to the guest) -- BEFORE the build
# --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
# The second consumer is the pool-aggregator-service, which reads this host's
# registration over the same port to list it under Extension hosts.
# Honors statusService.enabled + port; a healthy server is left running.
$statusDecision = $null
try {
    $statusScript = Join-Path $RepoRoot 'test/service/Start-StatusService.ps1'
    if ($tc -and (Test-Path -LiteralPath $statusScript)) {
        # Start-YurunaStatusServiceIfEnabled's own console output is intentionally
        # not surfaced; keep only the {ShouldStart; Port} record, the last
        # non-string object the gate returns.
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
$frameworkExpected = Get-FrameworkSourceSnapshot -RepoRoot $RepoRoot
if (-not (Assert-GuestFrameworkSource -RepoRoot $RepoRoot -StatusDecision $statusDecision `
            -ServiceLabel 'stash-service' -AllowMirrorSource:$AllowMirrorSource)) {
    exit $ExitFailure
}

# --- REGION: Delegate to the per-host New-VM (build + start the VM)
# Each New-VM already runs Get-Image auto-fetch when the base image is missing,
# tears down any prior VM, creates the new one, and (Hyper-V + KVM) starts it.
# UTM only builds the bundle -- register + start lives below.
Write-Verbose ""
Write-Output "== Bringing up '$VMName' on $HostType =="
& pwsh -NoProfile -File $newVm -VMName $VMName
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Error "$newVm exited $rc -- aborting."
    exit $rc
}

# --- REGION: UTM register + start (Hyper-V/KVM already started in New-VM)
# Hyper-V and KVM already started the VM inside New-VM.ps1 (Hyper-V\Start-VM and
# virt-install --import respectively); only UTM needs registration + start here.
# The host contract's Start-VM owns the whole UTM sequence -- VNC-display
# arbitration, the custom-QEMU-args dialog watchdog (without which this bring-up
# cannot run unattended, because UTM blocks on a modal), open, utmctl start, and
# the exit-0-but-QEMU-died check. Hand-rolling it here gets all four wrong.
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
# Without this gate the marker below advertises a stash service that does not
# exist, this script prints "start: complete" over a stopped VM, and the next
# failure names a layer -- cloud-init, the share -- that never ran.
if (-not (Wait-VMRunning -VMName $VMName -TimeoutSeconds 120)) {
    $observed = try { Get-VMState -VMName $VMName } catch { 'unknown' }
    Write-Error "VM '$VMName' did not reach 'running' (state: $observed); the stash service was NOT started. Open the VM in the hypervisor UI and start it by hand to see why."
    exit $ExitFailure
}

# --- REGION: Shared NAT -> forward a host port so peers can still reach the VM over SSH
# A Bridged VM takes a LAN lease and peers reach it at <vm-lan-ip>:22 directly.
# vmnet cannot bridge a Wi-Fi uplink, so on a Wi-Fi host New-VM builds this VM on
# UTM Shared NAT instead, where it is invisible to the LAN -- the host's own LAN
# address is the only way in. The bundle is the source of truth for which mode
# the VM is actually on: a host that has since moved between Wi-Fi and Ethernet
# needs a rebuild, not a different guess here.
# Host port 2222, not 22: the Mac's own sshd already owns 22.
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = Get-UtmNetworkModeFromBundle -VMName $VMName
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; re-run this script with -ForceRebuild to rebuild it."
    }
    if ($bundleMode -eq 'Shared') {
        $stashVmIp = Get-VMIp -VMName $VMName
        if ($stashVmIp) {
            $mapped = Add-PortMap -VMIp $stashVmIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false
            if ($mapped) { Write-Output "  Shared NAT: peers reach this stash service at $(Get-BestHostIp):2222 (forwarded to ${stashVmIp}:22), not at the VM's address." }
            else { Write-Warning "Shared NAT: could not forward host port 2222 to ${stashVmIp}:22; this stash service is reachable from this host only." }
        } else {
            Write-Warning "Shared NAT: '$VMName' has no address yet, so no host port was forwarded; re-run once it has booted to publish it to the LAN."
        }
    }
}

# --- REGION: https://yuruna.link/extensions-api#3-the-host-side-module--the-runtime-marker
# Advertise that THIS host actively runs a stash service, so the pool-aggregator-service
# lists it in the dashboard's Extension hosts table. The marker (stash-service.json)
# is folded into host.registration.json (activeExtensions + extensionTargets) by
# Write-HostRegistrationRecord; the aggregator -- already polling every pool host's
# registration -- reads it WITHOUT mounting ystash-nas or needing a config service on
# its own host. Stop-StashServiceVM.ps1 removes the marker. Best-effort throughout;
# never fails the bring-up. Written optimistically here and retracted below on
# failure, rather than written once after the verdict as the download-agent and
# pool-control bring-ups do.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$runtimeDir = $null
try {
    $runtimeDir = Initialize-YurunaRuntimeDir
    [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtimeDir `
        -Active $true -VMName $VMName -HostType $HostType)
    Write-Verbose "  Recorded stash-service marker -- this host will appear under Extension hosts."
} catch { Write-Verbose "stash-service marker write: $($_.Exception.Message)" }

# --- REGION: Post-boot readiness probe on :80 + on-failure guest diagnostics
# --- REGION: https://yuruna.link/memory#why-stash-service-bring-up-waits-for-the-daemon-not-just-the-vm
# Same contract as Get-DownloadAgentServiceReadyTimeoutSeconds, kept inline
# here; test/service/README.md records the divergence.
$stashReadyTimeoutSeconds = 2700
if ($env:YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS) {
    $parsedStashTimeout = 0
    if ([int]::TryParse($env:YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS, [ref]$parsedStashTimeout) -and $parsedStashTimeout -gt 0) {
        $stashReadyTimeoutSeconds = $parsedStashTimeout
    } else {
        Write-Verbose "YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS='$($env:YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS)' is not a positive integer; using $stashReadyTimeoutSeconds."
    }
}
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
            if (Add-PortMap -VMIp $newAddress -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                Write-Verbose "  Re-pointed host :2222 -> ${newAddress}:22."
            }
        }
    }
if ($stashEndpoint.Address) { $stashVmIp = $stashEndpoint.Address }
if ($stashEndpoint.ExtendedSeconds -gt 0) {
    Write-Verbose ("  Waited $([int]($stashEndpoint.WaitedSeconds / 60)) min in total -- extended by " +
                  "$([int]($stashEndpoint.ExtendedSeconds / 60)) min because the guest reported it was still building.")
}

# Before the verdict, not after it: a wait that timed out having probed the wrong
# address -- or no address at all -- is a FALSE NEGATIVE, and the daemon may have
# been serving for the whole budget. Locating the guest by bundle MAC and
# re-probing :80 THERE is the only thing that tells the two apart, and doing it
# here means a recovered service is reported as the success it is rather than
# being described in the failure diagnostics after the verdict is already cast.
#
# Costs an ICMP sweep, so it runs only on the failure branch, once.
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
        $stashEndpoint = [pscustomobject]@{
            Ready            = $true
            Address          = $stashRecovery.Address
            WaitedSeconds    = $stashEndpoint.WaitedSeconds
            Unreachable      = $false
            ListeningInGuest = $stashEndpoint.ListeningInGuest
            StillBuilding    = $false
            CloudInitStatus  = $stashEndpoint.CloudInitStatus
            LastProgress     = $stashEndpoint.LastProgress
            ExtendedSeconds  = $stashEndpoint.ExtendedSeconds
            AddressChanges   = [int]$stashEndpoint.AddressChanges + 1
        }
        if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
            try {
                if (Add-PortMap -VMIp $stashVmIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                    Write-Verbose "  Re-pointed host :2222 -> ${stashVmIp}:22."
                }
            } catch { Write-Verbose "stash forwarder re-point after recovery: $($_.Exception.Message)" }
        }
    }
}

# --- REGION: One place decides whether this bring-up succeeded
# The script routes on that decision instead of each site judging for itself. A
# readiness timeout is a FAILURE: a run that records PASS for a daemon that
# never started sends the operator looking for the fault in whatever breaks next.
$stashVerdict = Get-ServiceVmReadinessVerdict -Endpoint $stashEndpoint
switch ($stashVerdict.Outcome) {
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

# Resolve the stash-service VM's guest address into the marker (stashBaseUrl) so the
# dashboard's Extension cell deep-links to the stash UI. Best-effort + bounded: a
# Hyper-V External vSwitch can report the address minutes after boot, so poll
# briefly; if it is not up yet the link stays absent until a later refresh (the
# per-cycle runner call, or a re-run) populates it. Uses the host contract Get-VMIp
# wired by Initialize-YurunaHost above.
if ($runtimeDir -and -not $stashVerdict.IsFailure) {
    try {
        $stashUrl = Update-StashServiceMarkerAddress -RuntimeDir $runtimeDir -VMName $VMName -TimeoutSeconds 180
        if ($stashUrl) { Write-Output "  Stash VM address: $stashUrl (Extension cell deep-links here)." }
        else { Write-Output "  Stash VM address not resolved yet -- the Extension deep-link populates on a later refresh." }
    } catch { Write-Verbose "stash address resolve: $($_.Exception.Message)" }

    # Re-point the forwarder at whatever address the guest SETTLED on. The map
    # above was built from the first address discovery returned, and a guest
    # re-requests DHCP under a changed client identity while cloud-init runs --
    # so that first answer is frequently one the guest abandons seconds later.
    # The resolve above already waited for the guest to answer, which makes this
    # the first point where the address is known to be the live one.
    #
    # Re-pointing matters more than it looks: a forwarder left aimed at an
    # abandoned address still ACCEPTS on the host and only then fails to
    # connect, so every caller hangs for a full timeout instead of failing fast
    # -- strictly worse than no forwarder at all.
    if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
        try {
            $settledIp = Get-VMIp -VMName $VMName
            if ($settledIp -and $settledIp -ne $stashVmIp) {
                Write-Verbose "  '$VMName' settled on $settledIp (was $stashVmIp) -- re-pointing host :2222."
                if (Add-PortMap -VMIp $settledIp -Port @() -PortRemap @{ 2222 = 22 } -Confirm:$false) {
                    Write-Verbose "  Shared NAT: peers reach this stash service at $(Get-BestHostIp):2222 (forwarded to ${settledIp}:22)."
                } else {
                    Write-Warning "Could not re-point host port 2222 to ${settledIp}:22. Peers following the old address will hang until it is corrected; re-run this script to retry."
                }
            }
        } catch { Write-Verbose "stash forwarder re-point: $($_.Exception.Message)" }
    }
}

# Withdraw the advertisement when the daemon never started. The marker was
# written optimistically before the build, and leaving it standing would have the
# dashboard list this host as running a stash service that does not exist -- the
# same false claim as a passing exit code, made to a different audience.
if ($runtimeDir -and $stashVerdict.IsFailure) {
    try {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtimeDir `
            -Active $false -VMName $VMName -HostType $HostType)
        Write-Output "  Cleared the stash-service marker -- this host does not advertise a service that is not serving."
    } catch { Write-Verbose "stash-service marker retract: $($_.Exception.Message)" }
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

# --- REGION: The daemon never served -- gather the evidence, then FAIL
# --- REGION: https://yuruna.link/extensions-api#a-service-that-never-served-fails-loudly
if ($stashVerdict.IsFailure) {
    $stashWaitedMinutes = if ($stashEndpoint) { [int]($stashEndpoint.WaitedSeconds / 60) } else { 0 }
    $stashObserved = if ($stashEndpoint -and $stashEndpoint.ObservedState) { [string]$stashEndpoint.ObservedState } else { 'nothing' }
    Write-Warning ("The stash-service daemon did not come up on :80 after $stashWaitedMinutes min -- " +
                   "$($stashVerdict.Summary). Observed: $stashObserved.")

    # The address to dial for the in-guest capture below: whatever the wait
    # settled on, or -- when it never resolved one -- whatever the recovery step
    # above located. Reused rather than looked up again; that lookup costs an
    # ICMP sweep per candidate subnet and its answer has not changed since.
    $stashDiagIp = if ($stashEndpoint) { [string]$stashEndpoint.Address } else { '' }
    if (-not $stashDiagIp -and $stashRecovery) { $stashDiagIp = [string]$stashRecovery.Address }

    # The console frame answers what SSH cannot reach to answer. A guest that
    # stopped at a failed cifs mount, or sits at a login prompt with cloud-init
    # dead, shows exactly that on screen while every host-side probe can only
    # report silence.
    try {
        $stashLogDir = Initialize-YurunaLogDir
        if ($stashLogDir -and (Get-Command Get-VMScreenshot -ErrorAction SilentlyContinue)) {
            $stashConsolePng = Join-Path $stashLogDir "stash-service-console_${VMName}.png"
            $stashCaptured = Get-VMScreenshot -VMName $VMName -OutFile $stashConsolePng
            # Get-VMScreenshot can report truthy without writing the file, so the
            # path is advertised only once it is on disk.
            if ($stashCaptured -and (Test-Path -LiteralPath $stashConsolePng)) {
                Write-Verbose "  Guest console captured: $stashConsolePng"
            } else {
                Write-Output "  Guest console could not be captured (the hypervisor returned no frame)."
            }
        }
    } catch { Write-Verbose "stash console capture: $($_.Exception.Message)" }

    # In-guest capture over the harness key. -User pins the account the cloud-init
    # seed created: it is the only login this VM has, and Get-GuestSshUser would
    # otherwise return a per-cycle cascade override that an earlier run in this
    # same shell session left registered for guest.stash-service.
    $stashDiagCmd = @(
        # First, because it settles the most common confusion here: when the
        # guest's own address differs from the one this host probed, the daemon
        # was never the problem.
        "echo `"=== guest addresses (this host probed: $(if ($stashDiagIp) { $stashDiagIp } else { '<none resolved>' })) ===`"; ip -4 -o addr show scope global 2>&1 | awk '{print `$2, `$4}'",
        'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
        'echo "=== systemctl status stash-service.service ==="; systemctl --no-pager --full status stash-service.service 2>&1 | head -n 25',
        'echo "=== journalctl -u stash-service.service (last 40) ==="; sudo journalctl -u stash-service.service --no-pager -n 40 2>&1',
        'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
        'echo "=== stash share mount ==="; findmnt /mnt/yuruna-stash 2>&1 || echo "(/mnt/yuruna-stash is not mounted)"',
        'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
    ) -join "`n"
    $stashDiag = $null
    # Dialed at the address discovered above whenever there is one. Invoke-GuestSsh
    # resolves -VMName through Get-GuestAddress, which hands a literal address
    # straight back, so a name and an address are equally acceptable there --
    # but handing it the NAME here would re-run the very lookup that already
    # came back empty and discard the only thing that located the guest. The
    # name stays the fallback: ssh has resolution routes the lease lookup lacks.
    $stashSshTarget = if ($stashDiagIp) { $stashDiagIp } else { $VMName }
    try { $stashDiag = Invoke-GuestSsh -VMName $stashSshTarget -GuestKey 'guest.stash-service' -User 'stash-admin' -Command $stashDiagCmd -TimeoutSeconds 120 }
    catch { Write-Verbose "stash guest diagnostics ssh: $($_.Exception.Message)" }

    Write-Verbose ""
    Write-Output "======== stash-service guest diagnostics ========"
    if ($stashDiag -and -not [string]::IsNullOrWhiteSpace([string]$stashDiag.output)) {
        foreach ($line in ([string]$stashDiag.output -split "`r?`n")) { Write-Output "  $line" }
        if (-not $stashDiag.success) {
            Write-Verbose "  (ssh ended with exit=$($stashDiag.exitCode); the capture above is what completed before it did)"
        }
    } else {
        Write-Output "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)."
        # Never an ssh line with a hole where the host should be: an address this
        # host never learned makes the command unrunnable AND hides the fact that
        # is actually blocking the reader.
        foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'stash-admin' -Address $stashDiagIp -VMName $VMName `
                    -Command 'sudo tail -n 120 /var/log/cloud-init-output.log') -split "`r?`n")) {
            Write-Verbose "  $hintLine"
        }
    }
    Write-Verbose "========"
    Write-Verbose ""
    Write-Output "Reading the capture above:"
    Write-Output "  * cloud-init status 'running'   -> the in-guest build is still going; re-run this script to"
    Write-Verbose "                                     re-check, or raise YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS."
    Write-Output "  * 'cifs_mount failed' / -111    -> the stash share did not mount, so cloud-init stopped before the"
    Write-Verbose "                                     daemon was ever built. Check that the stash share's server is"
    Write-Verbose "                                     actually serving SMB and that its credential is current."
    Write-Output "  * a 'go build' / apt error      -> a package or source problem; the log tail shows the line."
    Write-Output "  * nothing at all over SSH       -> the console capture above is the remaining evidence."
    Write-Verbose "See https://yuruna.link/stash-guide."
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

# The aggregator lists this host under Extension hosts ONLY if a status service is
# actually serving /runtime/host.registration.json. The ensure above ran before the
# build, and Start-StatusService runs its own readiness wait, but that verdict is
# invisible here -- so confirm the port now: a stash-only host whose status service
# never came up would otherwise print "complete" yet never appear in the dashboard.
if ($statusDecision -and $statusDecision.ShouldStart) {
    $statusPort = [int]$statusDecision.Port
    $probe = [System.Net.Sockets.TcpClient]::new()
    $accepting = $false
    try {
        $iar = $probe.BeginConnect('127.0.0.1', $statusPort, $null, $null)
        $accepting = ($iar.AsyncWaitHandle.WaitOne(2000) -and $probe.Connected)
    } catch { Write-Verbose "status port probe: $($_.Exception.Message)" } finally { $probe.Dispose() }
    if ($accepting) {
        Write-Verbose "  Status service accepting on :$statusPort -- this host will appear under Extension hosts."
    } else {
        Write-Warning "Status service is not accepting on :$statusPort -- the pool-aggregator service cannot read host.registration.json over HTTP, so the Extension hosts row depends solely on the stash-service VM's own presence beacon (which the aggregator shows without the host's status baseUrl link). Run test/service/Start-StatusService.ps1 to diagnose."
    }
}

Write-Verbose ""
# "Complete" is claimed only where the daemon was actually observed serving. A
# guest that is still compiling has not completed anything yet -- it is a
# successful bring-up whose service is not up, and saying so is what stops the
# operator looking for a UI that does not answer.
if ($stashVerdict.Outcome -eq 'StillBuilding') {
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

# --- REGION: What actually got deployed
# --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
# The daemon is serving, so this is the first point where the framework it was
# built from can be answered from evidence rather than prediction.
if (-not (Assert-ServiceVmFrameworkSource -Address ([string]$stashVmIp) -Port 80 `
            -GuestKey 'guest.stash-service' -User 'stash-admin' `
            -Expected $frameworkExpected -ServiceLabel 'stash-service' `
            -AllowMirrorSource:$AllowMirrorSource)) {
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
Write-Verbose "(See https://yuruna.link/stash-guide.)"
Write-Verbose ""
Write-Output "Stop with: test/service/Stop-StashServiceVM.ps1"
exit $ExitOk
