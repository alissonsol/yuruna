<#PSScriptInfo
.VERSION 2026.08.21
.GUID 421a21ac-638b-4121-a908-7c26df6a9e86
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

<#
.SYNOPSIS
    Bring up the Pool control service on THIS host by building + launching it on
    its OWN VM, and publish its marker.
.DESCRIPTION
    Like Start-CachingProxyServiceVM / Start-StashServiceVM, the default path brings the
    service up on a dedicated VM (guest.pool-control-service): it runs the pool-storage
    pre-flight, then delegates to the per-host New-VM.ps1, whose cloud-init fetches
    the framework and runs the bring-up script that builds the Go daemon, installs
    pwsh + the pool-admin CLIs, CIFS-mounts the pool NAS for its state dir, and
    launches the daemon under systemd (UI + API on :80) INSIDE the guest -- no Go
    toolchain is needed on the host.

    Writes runtime/pool-control-service.json (the marker Test.Capability folds into
    host.registration.json so the service shows up in the Extension hosts table)
    and refreshes the registration record so the host appears within one
    aggregator poll. The Go service also self-announces to the aggregator via its
    beacon, so the Extension-hosts row appears by marker AND by beacon
    independently.
.PARAMETER VMName
    Name of the pool-control-service VM. Default: yuruna-pool-control-service.
.PARAMETER HostSideProof
    Build the Go binary from test/extension/pool-control-service/server and run it
    directly on THIS host (no VM), serving the UI/API on -Port. This needs a local
    Go toolchain and is a quick proof / fallback for when a VM is unavailable. Omit
    it to use the default VM path.
.PARAMETER Port
    UI/API port for -HostSideProof only (the VM serves on :80). Default 8090 (kept
    clear of the status service's 8080).
.PARAMETER AggregatorUrl
    Pool-aggregator service base URL for the beacon, -HostSideProof only (the VM reads its
    aggregator URL from config via the seed). Optional (empty disables the beacon;
    the marker path still works).
.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
    Without it, a bring-up whose guest could not fetch this host's framework --
    or one whose daemon turns out to have been built from another snapshot -- is
    refused rather than deploying code older than the operator is working in.
    Legitimate off-LAN, where the mirror is the only source there is. VM path
    only; -HostSideProof builds from this enlistment by definition.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'yuruna-pool-control-service',
    [switch]$HostSideProof,
    [int]$Port = 8090,
    [string]$AggregatorUrl = '',
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

# Initialize-YurunaEntryPoint returns only paths -- it imports no modules -- so
# pull in Test.YurunaDir explicitly for Initialize-YurunaRuntimeDir /
# Get-YurunaHostId. Initialize-YurunaRuntimeDir DEFAULTS + creates
# <testRoot>/status/runtime when $env:YURUNA_RUNTIME_DIR is unset, so the marker
# always has a home on a fresh shell instead of depending on an inherited env var.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

if (-not $HostSideProof) {
    # --- REGION: Default -- bring the service up on its OWN VM (guest.pool-control-service)
    # Mirrors Start-StashServiceVM / Start-CachingProxyServiceVM: pool-storage pre-flight, then
    # delegate to the per-host New-VM.ps1 whose cloud-init builds + launches the
    # daemon inside the guest. -HostSideProof (below) is the no-VM fallback.
    if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
        exit $ExitFailure
    }

    # Windows has no mid-run elevation: the Hyper-V guest.pool-control-service
    # New-VM.ps1 refuses without Administrator -- but only after the pool-NAS
    # mount pre-flight and the status-service start have already run. Check NOW,
    # while nothing has changed. Inside the -not $HostSideProof branch on
    # purpose: the host-side proof binds port 8090 and needs no elevation at all.
    # Windows only -- neither the UTM nor the KVM New-VM.ps1 has such a gate.
    if ($IsWindows -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Output ""
        Write-Output "This script requires elevation (Run as Administrator)."
        Write-Output "Start-PoolControlServiceVM needs an elevated session to:"
        Write-Output "  * query Hyper-V for the VHD folder (Get-VMHost)"
        Write-Output "  * create and remove the '$VMName' VM and its disk"
        Write-Output "Re-launch PowerShell as Administrator, or use -HostSideProof (no VM, no elevation)."
        Write-Error "Start-PoolControlServiceVM requires Administrator on Windows. Nothing was changed."
        exit $ExitFailure
    }

    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
    Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

    $HostType = Get-HostType
    if (-not $HostType) { exit $ExitFailure }
    Write-Verbose "Host type: $HostType"
    [void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

    # --- REGION: Pool storage pre-flight
    # The pool-control-service daemon persists its audit log + status.json under the pool
    # NAS (poolStorageNetworkPath/pool-control-service/). Refuse to bring up a VM that would have
    # nowhere durable to write: fail fast HERE, before the long VM build, when the
    # pool storage is unconfigured or its NAS credential is not stored.
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
Start-PoolControlServiceVM requires the pool storage to be configured:
set networkStorage.poolStorageNetworkPath / poolStorageNetworkUser / poolStorageLocalPath in
test/test.config.yml and Set-Password the poolStorageNetworkUser. See docs/test-config.md
and the Pool control service section of docs/pool-admin.md.
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
The pool-control-service VM mounts the pool NAS with this account; without a stored credential
the VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
state dir never mounts. Store the real NAS password first, then re-run:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
        exit $ExitFailure
    }
    # Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
    # pool share. WARNING, not a hard stop: the daemon degrades to no persistence
    # when the share is offline, and the NAS may merely be transiently unreachable.
    if (Connect-YurunaPoolStorage -Config $poolCfg -Confirm:$false) {
        Write-Verbose "pool storage pre-flight OK (networkUser='$($poolCfg.NetworkUser)'; credential authenticates)."
    } else {
        # Report the reason the mount RECORDED, and prescribe from it. A mount
        # that sudo refused never reaches the NAS, so naming the credential there
        # sends the operator to reset a password that was never wrong -- and to
        # rebuild the VM for it -- while the actual fault stays in place.
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
Bringing the VM up anyway: the daemon will START but persist NOTHING until this is fixed.
$remedy
"@
    }

    # --- REGION: Resolve the per-host New-VM
    $hostFolder = Get-HostFolder $HostType
    $guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.pool-control-service'
    $newVm      = Join-Path $guestDir 'New-VM.ps1'
    if (-not (Test-Path -LiteralPath $newVm)) {
        Write-Error "New-VM.ps1 not found for $HostType at $newVm"
        exit $ExitFailure
    }

    # --- REGION: Host status service (serves the local repo to the guest) -- BEFORE the build
    # --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
    # Best-effort; honors statusService.enabled + port. The {ShouldStart; Port}
    # record is kept rather than discarded: the framework-source gate below
    # probes the port THIS decision resolved, so it cannot disagree with the
    # config reading that started the server.
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
    # build and a service nobody has reason to re-examine. The snapshot is
    # captured for the post-boot check too, which is the half that can prove what
    # got deployed.
    Import-Module (Join-Path $ModulesDir 'Test.FrameworkSource.psm1') -Global -Force
    $frameworkExpected = Get-FrameworkSourceSnapshot -RepoRoot $repoRoot
    if (-not (Assert-GuestFrameworkSource -RepoRoot $repoRoot -StatusDecision $statusDecision `
                -ServiceLabel 'pool-control-service' -AllowMirrorSource:$AllowMirrorSource)) {
        exit $ExitFailure
    }

    # --- REGION: Delegate to the per-host New-VM (build + start the VM)
    # Each New-VM runs Get-Image auto-fetch when the base image is missing, tears down any
    # prior VM, creates the new one, and (Hyper-V + KVM) starts it. UTM only builds the
    # bundle -- register + start below.
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
    # to cloud-init, the go build, or the NAS -- none of which ran -- and the host
    # advertises a pool-control service that does not exist.
    if (-not (Wait-VMRunning -VMName $VMName -TimeoutSeconds 120)) {
        $observed = try { Get-VMState -VMName $VMName } catch { 'unknown' }
        Write-Error "VM '$VMName' did not reach 'running' (state: $observed); the pool-control service was NOT started. Nothing in the guest -- cloud-init, the go build, the pool NAS mount -- has run yet. Open the VM in the hypervisor UI and start it by hand to see why."
        exit $ExitFailure
    }

    # --- REGION: Shared NAT -> forward a host port so peers can still reach the UI
    # A Bridged VM takes a LAN lease and peers reach the UI at <vm-lan-ip>:80.
    # vmnet cannot bridge a Wi-Fi uplink, so on a Wi-Fi host New-VM builds this VM
    # on UTM Shared NAT instead, where it is invisible to the LAN -- the host's own
    # LAN address is the only way in. The bundle is the source of truth for which
    # mode the VM is actually on: a host that has since moved between Wi-Fi and
    # Ethernet needs a rebuild, not a different guess here.
    if ($HostType -eq 'host.macos.utm') {
        $bundleMode = Get-UtmNetworkModeFromBundle -VMName $VMName
        $uplinkMode = Resolve-UtmNetworkMode
        if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
            Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; re-run this script with -ForceRebuild to rebuild it."
        }
        # Host port 8081, not 80: on a shared-services machine the caching-proxy
        # already forwards host :80 (its CA-cert endpoint), and asking for the
        # same port would attach to that forwarder -- publishing the CACHE at
        # the URL this script then prints for the pool-control UI.
        if ($bundleMode -eq 'Shared') {
            $pcVmIp = try { Get-VMIp -VMName $VMName } catch { Write-Verbose "Get-VMIp: $($_.Exception.Message)"; $null }
            if ($pcVmIp) {
                $mapped = Add-PortMap -VMIp $pcVmIp -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false
                if ($mapped) { Write-Information "  Shared NAT: peers reach the pool-control service UI at http://$(Get-BestHostIp):8081/ (forwarded to ${pcVmIp}:80), not at the VM's address." -InformationAction Continue }
                else { Write-Warning "Shared NAT: could not forward host port 8081 to ${pcVmIp}:80; the pool-control service UI is reachable from this host only." }
            } else {
                Write-Warning "Shared NAT: '$VMName' has no address yet, so no host port was forwarded; re-run once it has booted to publish the UI to the LAN."
            }
        }
    }

    # --- REGION: Post-boot readiness probe on :80 + on-failure guest diagnostics
    # New-VM confirmed the VM has an IP, but the daemon still has to build INSIDE
    # the guest (apt golang + pwsh, go build, systemd start), which takes several
    # minutes on first boot -- so an IP alone is NOT "the service is up". Probe :80
    # until it actually serves before declaring success. If it never comes up, pull
    # the in-guest build log + cloud-init status + service journal over the harness
    # SSH key so the operator sees WHY without SSHing in blind. pool-control-service-admin
    # has NOPASSWD sudo in the seed, so `sudo tail` reads
    # /var/log/cloud-init-output.log (root-only -- a plain `tail` as
    # pool-control-service-admin returns Permission denied).
    Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
    # Wait-VMIp, not a single Get-VMIp. A guest that has just been started has no
    # address for the first several seconds -- on UTM Shared NAT it appears only
    # once DHCP completes -- and a one-shot call there returns empty, which skips
    # the readiness probe entirely and reports the service as failed seconds after
    # the VM booted. "No address yet" and "daemon still building" are the same
    # wait to an operator, so this draws from the same readiness budget as the
    # port probe rather than being a separate, invisible give-up.
    $ipWaitStart = (Get-Date)
    $vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
    $ipWaitSeconds = [int]((Get-Date) - $ipWaitStart).TotalSeconds

    # Sized for the SLOW end, not the typical one: a first build (golang + pwsh
    # install + go build over the caching-proxy service) runs to roughly half an
    # hour on an Apple Silicon guest against a cold mirror. The probe returns the
    # instant :80 accepts, so a budget the fast host never spends costs it
    # nothing, while one sized for the fast host fails the slow host over a build
    # that was progressing normally. The wait extends itself past this while
    # cloud-init reports it is still working, so this is the floor rather than
    # the whole story. YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS
    # overrides (e.g. a short value for a quick re-check on a VM already up).
    # Same contract as Get-DownloadAgentServiceReadyTimeoutSeconds, kept inline
    # here; test/service/README.md records the divergence.
    $readyTimeoutSeconds = 2700
    if ($env:YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS) {
        $parsed = 0
        if ([int]::TryParse($env:YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) { $readyTimeoutSeconds = $parsed }
    }
    $readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)
    # How long a guest located by the last-resort route below gets to answer on
    # :80. Deliberately short: it runs only after the ordinary wait has already
    # spent its whole budget, and it is confirming a listener that either answers
    # within a few polls or was never there.
    $recoveryProbeSeconds = 60

    # ONE readiness verdict for the whole script, and it starts $false: every
    # path that never confirmed a listener -- including the paths that never got
    # far enough to probe one -- must publish an INACTIVE marker rather than an
    # optimistic one. The aggregator paints the Extension-hosts row and its
    # deep-link from this value, so a marker that says "active" because the
    # script merely ran deep-links operators to a UI that is not serving.
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
    # The wait resolves the guest's address on EVERY poll rather than trusting
    # the one resolved above: a guest re-requests DHCP under a changed client
    # identity while cloud-init runs, so the address discovered at boot is
    # frequently one the guest abandons seconds later. Following it also keeps
    # the host-side forwarder pointed at the live address instead of leaving it
    # dialing an abandoned one -- a forwarder that accepts and cannot connect is
    # worse than one that is down, because callers hang for a full timeout
    # instead of failing fast.
    if ($vmIp) {
        Write-Verbose "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the pool-control-service daemon to serve on :80 (first boot builds it in-guest)."
        Write-Verbose "  The wait extends itself while the guest reports it is still building; progress is printed as it happens."
        Write-Verbose "  Override the budget with YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS."
        $repointForwarder = {
            param($newAddress)
            $script:vmIp = $newAddress
            if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
                if (Add-PortMap -VMIp $newAddress -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false) {
                    Write-Verbose "  Re-pointed host :8081 -> ${newAddress}:80."
                }
            }
        }
        # Wait-YurunaServiceVmDaemon rather than the wait underneath it: the wait
        # takes a FIXED progress label and prints it unchanged for the whole
        # budget, so a guest sitting at a login prompt with cloud-init dead reads
        # identically to one mid-compile -- and the operator waits out the full
        # budget on the strength of a line nothing measured. This one paints from
        # what was actually observed of the guest.
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
        # The VM is confirmed RUNNING by the state gate above, so this is a
        # host-side address-discovery gap, not a VM that failed to start. On UTM
        # a Bridged guest has no dhcpd lease and no guest agent, so this is the
        # normal path there rather than an anomaly.
        #
        # The elapsed wait is named because the number is the diagnosis: seconds
        # means address lookup is unsupported for this networking mode, the full
        # budget means DHCP never completed. Quoting the nominal readiness
        # timeout for a probe that never ran describes a wait that did not happen.
        Write-Warning ("Could not resolve the VM's IP after waiting ${ipWaitSeconds}s (Wait-VMIp); the VM IS running, so this is " +
                       "address discovery, not a boot failure. Asking the guest itself whether the daemon is up.")
        # Address discovery failing is not the same as the service failing, and
        # the two must not share a verdict. SSH resolves the guest by NAME
        # through its own path, so it can still get in where the lease lookup
        # found nothing -- and the daemon's answer is the fact that matters.
        if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
            $inGuest = $null
            try {
                $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.pool-control-service' `
                    -User 'pool-control-service-admin' -TimeoutSeconds 30 `
                    -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
            } catch { Write-Verbose "pool-control-service in-guest listener probe: $($_.Exception.Message)" }
            if ($inGuest -and "$($inGuest.output)" -match 'YURUNA_LISTENING') {
                # The guest's own answer IS this path's readiness record. No wait
                # ran, so there is nothing else to hand the verdict below, and
                # "bound inside the guest, unreachable from here" is precisely
                # what the Unreachable outcome names. Shaping it like the wait's
                # record keeps one decision function for both paths instead of a
                # second opinion that can disagree with the first.
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
    # The script routes on that decision instead of each site judging for
    # itself. A readiness timeout is a FAILURE: a run that records PASS for a
    # daemon that never started sends the operator looking for the fault in
    # whatever breaks next, which is the most expensive place to look for it.
    $verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint

    # --- REGION: https://yuruna.link/network#why-a-mac-sweep-is-spent-only-on-a-failed-bring-up
    # Spent here and nowhere else: the sweep costs about two minutes, and this
    # is the one place where the alternative is calling a healthy daemon failed.
    $recoveredIp = ''
    if ($verdict.IsFailure) {
        $recoveredIp = Resolve-GuestDiagnosticAddress -VMName $VMName
        if ($recoveredIp -and $recoveredIp -ne [string]$vmIp) {
            Write-Warning "Located '$VMName' at $recoveredIp -- an address the readiness wait never probed. Re-checking :80 there before failing the bring-up."
            # Bounded by the wall clock rather than an iteration count: the
            # bound that matters to the operator is a duration, and each probe's
            # own timeout stretches under load -- so a counted loop silently
            # becomes an unbounded one exactly when the host is busiest.
            $readyDeadline = (Get-Date).AddSeconds($recoveryProbeSeconds)
            while (-not $daemonReady -and (Get-Date) -lt $readyDeadline) {
                if (Test-TcpEndpointOpen -Address $recoveredIp -Port 80 -TimeoutMilliseconds 1000) {
                    $daemonReady = $true
                } else {
                    Start-Sleep -Seconds 3
                }
            }
            if ($daemonReady) {
                Write-Verbose "  The daemon IS serving at ${recoveredIp}:80 -- the wait was probing an address this guest never had."
                $vmIp = $recoveredIp
                # Re-decided through the same helper rather than set by hand:
                # two ways of producing a verdict are two verdicts that can
                # disagree with each other.
                $endpoint = [pscustomobject]@{
                    Ready         = $true
                    Unreachable   = $false
                    StillBuilding = $false
                    Address       = $recoveredIp
                    WaitedSeconds = $(if ($endpoint) { $endpoint.WaitedSeconds } else { $ipWaitSeconds })
                    # Names the route, not the rung. The last-resort lookup
                    # tries the ordinary resolver before it reaches the bundle
                    # MAC, so which one answered is not knowable from here --
                    # and a record that asserts a mechanism which may not have
                    # run is the same false lead as a probe that never happened.
                    ObservedState = 'located by the last-resort guest discovery once the readiness wait had no address for it, then confirmed serving on :80'
                }
                $verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint
                # The forwarder has to follow, or peers keep dialing an address
                # that accepts on this host and then cannot connect -- which
                # hangs every caller for a full timeout instead of failing fast,
                # strictly worse than no forwarder at all.
                if ($HostType -eq 'host.macos.utm' -and $bundleMode -eq 'Shared') {
                    if (Add-PortMap -VMIp $recoveredIp -Port @() -PortRemap @{ 8081 = 80 } -Confirm:$false) {
                        Write-Verbose "  Re-pointed host :8081 -> ${recoveredIp}:80."
                    }
                }
            } else {
                Write-Warning "${recoveredIp}:80 did not answer within ${recoveryProbeSeconds}s either, so the guest was found but its daemon is not serving."
            }
        }
    }

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

    # Publish the marker + refresh registration: write
    # runtime/pool-control-service.json, then regenerate host.registration.json
    # so the aggregator lists this host under Extension hosts on its next poll --
    # not only after the next test cycle. poolControlServiceBaseUrl gives the Extension
    # cell a deep-link even before the daemon's first beacon; an IPv6 literal is
    # bracketed for the URL authority. The registration refresh is best-effort
    # telemetry and must never fail the bring-up. Write-HostRegistrationRecord reads
    # $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
    #
    # --- REGION: https://yuruna.link/extensions-api#3-the-host-side-module--the-runtime-marker
    #
    # Here the readiness verdict decides whether the dashboard deep-links
    # operators to a UI that is not serving -- so `active` carries the verdict,
    # never "the bring-up script ran".
    #
    # A URL is published only where THIS host opened the port itself. The
    # degraded tier -- the guest confirmed the daemon bound, this host has no
    # route to it -- stays advertised as active with no URL: the service exists
    # and peers reach it through its own announce, while a link only this host
    # cannot follow would send every reader to a dead endpoint.
    $poolControlServiceBaseUrl = if (-not $daemonReady -or $listeningButUnreachable -or -not $vmIp) { '' }
                                 elseif ($vmIp -match ':') { "http://[$vmIp]/" } else { "http://$vmIp/" }
    Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
    [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir `
        -Active $daemonReady -VMName $VMName -HostType $HostType -BaseUrl $poolControlServiceBaseUrl)
    try {
        Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
        Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
        [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
    } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

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
        # --- REGION: What actually got deployed
        # --- REGION: https://yuruna.link/extensions-api#which-framework-snapshot-a-service-vm-is-built-from
        # The daemon is serving, so this is the first point where the framework
        # it was built from can be answered from evidence rather than prediction.
        #
        # Ahead of the proxy alias sync below, deliberately. That reconfigures a
        # shared serving path on the caching-proxy service, and a build this
        # script is about to reject should not leave that behind.
        if (-not (Assert-ServiceVmFrameworkSource -Address ([string]$vmIp) -Port 80 `
                    -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' `
                    -Expected $frameworkExpected -ServiceLabel 'pool-control-service' `
                    -AllowMirrorSource:$AllowMirrorSource)) {
            Write-Verbose ""
            Write-Verbose "== pool-control-service start: FAILED (deployed an obsolete framework snapshot) =="
            Write-Verbose "  VM:   $VMName ($HostType)"
            Write-Information "  The VM is up and the daemon is serving -- it is running the WRONG BUILD, not nothing." -InformationAction Continue
            Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
            exit $ExitFailure
        }

        # The guest seeds its intent store on the pool NAS; point the proxy's
        # read-only /pool-intent.git route at that same store so runners pull
        # exactly what this UI writes. Runs HERE, on the host, because the host
        # holds the harness SSH key -- a guest carries only an authorized public
        # key, so doing it from the VM would mean baking a private key with
        # sudo-capable proxy access into a web-facing guest. Reported, never
        # fatal: a serving-path optimization must not fail a successful bring-up.
        try {
            Import-Module (Join-Path $ModulesDir 'Test.CachingProxyService.psm1') -Global -Force
            $aliasSync = Sync-PoolIntentAliasOnProxy -Confirm:$false
            if ($aliasSync.Changed) {
                Write-Verbose "  Proxy: /pool-intent.git now serves the pool NAS store (runners pull what this UI writes)."
            } elseif (-not $aliasSync.Ok) {
                Write-Warning "pool-intent alias not reconciled on the caching-proxy service: $($aliasSync.Message). Runners may still pull the proxy's older local store; the pool-control service UI is unaffected."
            } else {
                Write-Verbose "pool-intent alias: $($aliasSync.Message)"
            }
        } catch { Write-Verbose "pool-intent alias sync: $($_.Exception.Message)" }

        Write-Verbose ""
        if ($listeningButUnreachable) {
            Write-Verbose "== pool-control-service is RUNNING (daemon serving on :80 in-guest; not reachable from this host) =="
        } else {
            Write-Verbose "== pool-control-service is READY (daemon serving on :80) =="
        }
        Write-Verbose "  VM:   $VMName ($HostType)"
        if ($poolControlServiceBaseUrl) {
            Write-Verbose "  UI:   $poolControlServiceBaseUrl  (Assign / Pools / Test sets)"
        } else {
            Write-Verbose "  UI:   not published -- this host cannot reach the daemon, so no URL is advertised. The pool still"
            Write-Verbose "        resolves the service from its own announce; the Yuruna hosts dashboard links it there."
        }
        if ($vmIp) { Write-Information "  SSH:  ssh pool-control-service-admin@$vmIp  (harness key authorized)" -InformationAction Continue }
        Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
        exit $ExitOk
    }

    # --- REGION: The daemon never served -- gather the evidence, then FAIL
    # --- REGION: https://yuruna.link/extensions-api#a-service-that-never-served-fails-loudly
    # -User pins the account the cloud-init seed created: Get-GuestSshUser would
    # otherwise return a per-cycle cascade override that an earlier run in this
    # same shell session left registered for guest.pool-control-service.
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

    # The console frame answers what SSH cannot reach to answer. A guest that
    # stopped at a failed cifs mount, or sits at a login prompt with cloud-init
    # dead, shows exactly that on screen while every host-side probe can only
    # report silence.
    try {
        $logDir = Initialize-YurunaLogDir
        if ($logDir -and (Get-Command Get-VMScreenshot -ErrorAction SilentlyContinue)) {
            $consolePng = Join-Path $logDir "pool-control-service-console_${VMName}.png"
            $captured = Get-VMScreenshot -VMName $VMName -OutFile $consolePng
            # Get-VMScreenshot can report truthy without writing the file, so the
            # path is advertised only once it is on disk.
            if ($captured -and (Test-Path -LiteralPath $consolePng)) {
                Write-Verbose "  Guest console captured: $consolePng"
            } else {
                Write-Information "  Guest console could not be captured (the hypervisor returned no frame)." -InformationAction Continue
            }
        }
    } catch { Write-Verbose "pool-control-service console capture: $($_.Exception.Message)" }

    $diagCmd = @(
        # First, because it is the fact that settles the most common confusion
        # here: when the guest's own address differs from the one this host
        # probed, the daemon was never the problem. Printing both side by side
        # names that immediately instead of leaving it to be inferred.
        "echo `"=== guest addresses (this host probed: $(if ($diagIp) { $diagIp } else { '<none resolved>' })) ===`"; ip -4 -o addr show scope global 2>&1 | awk '{print `$2, `$4}'",
        'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
        'echo "=== systemctl status pool-control-service.service ==="; systemctl --no-pager --full status pool-control-service.service 2>&1 | head -n 25',
        'echo "=== journalctl -u pool-control-service.service (last 40) ==="; sudo journalctl -u pool-control-service.service --no-pager -n 40 2>&1',
        'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
        'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
    ) -join "`n"
    $diag = $null
    # Not gated on an address: SSH resolves the guest by name through its own
    # path, so it often gets in when the lease lookup found nothing -- and "no
    # address" is exactly the failure whose diagnosis lives inside the guest.
    # Dialed at the address discovered above whenever there is one:
    # Invoke-GuestSsh hands a literal address straight back, so a name and an
    # address are equally acceptable to it, but passing the NAME here would
    # re-run the very lookup that already came back empty and discard the only
    # thing that located the guest.
    $sshTarget = if ($diagIp) { $diagIp } else { $VMName }
    if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
        try { $diag = Invoke-GuestSsh -VMName $sshTarget -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' -Command $diagCmd -TimeoutSeconds 120 }
        catch { Write-Verbose "guest diagnostics ssh: $($_.Exception.Message)" }
    }
    Write-Verbose ""
    Write-Information "================= pool-control-service guest diagnostics =================" -InformationAction Continue
    if ($diag -and -not [string]::IsNullOrWhiteSpace([string]$diag.output)) {
        foreach ($line in ([string]$diag.output -split "`r?`n")) { Write-Information "  $line" -InformationAction Continue }
        if (-not $diag.success) {
            Write-Verbose "  (ssh ended with exit=$($diag.exitCode); the capture above is what completed before it did)"
        }
    } else {
        Write-Information "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)." -InformationAction Continue
        # Never an ssh line with a hole where the host should be: an address this
        # host never learned makes the command unrunnable AND hides the fact that
        # is actually blocking the reader.
        foreach ($hintLine in ((Format-GuestSshDiagnosticHint -User 'pool-control-service-admin' -Address $diagIp -VMName $VMName `
                    -Command 'sudo tail -n 120 /var/log/cloud-init-output.log') -split "`r?`n")) {
            Write-Verbose "  $hintLine"
        }
    }
    Write-Verbose "=================================================================="
    Write-Verbose ""
    Write-Information "The pool-control-service daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
    Write-Information "  * cloud-init status 'running'  -> the in-guest build (go/pwsh) is still going; wait, then" -InformationAction Continue
    Write-Verbose "                                    re-run to re-check (or raise YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS)."
    Write-Information "  * 'cifs_mount failed' / -111   -> the pool NAS did not mount, so cloud-init stopped before the daemon" -InformationAction Continue
    Write-Verbose "                                    was ever built. The console capture above shows this when SSH cannot."
    Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
    Write-Information "  * 'NAS mount failed'           -> pool NAS unreachable; re-check the pool storage credential." -InformationAction Continue
    Write-Information "  * nothing at all over SSH      -> the console capture above is the remaining evidence." -InformationAction Continue
    Write-Verbose "See https://yuruna.link/pool-control-service."
    Write-Verbose ""
    Write-Verbose "== pool-control-service start: FAILED (the daemon never served on :80) =="
    Write-Verbose "  VM:   $VMName"
    Write-Verbose "  Host: $HostType"
    Write-Verbose "  Stop: test/service/Stop-PoolControlServiceVM.ps1"
    exit $ExitFailure
}

# --- REGION: -HostSideProof -- build + run the daemon directly on THIS host (no VM)
# A quick proof / fallback that needs a local Go toolchain; the VM path above is
# the default.
$serverDir = Join-Path $repoRoot 'test/extension/pool-control-service/server'
$go = (Get-Command go -ErrorAction SilentlyContinue)?.Source
if (-not $go) { Write-Error 'go toolchain not found on PATH; cannot build the pool-control service. Omit -HostSideProof to bring the service up on its own VM, which builds the daemon inside the guest (no host Go toolchain needed).'; exit $ExitFailure }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshExe) { $pwshExe = 'pwsh' }

$binName = if ($IsWindows) { 'pool-control-service.exe' } else { 'pool-control-service' }
$binPath = Join-Path $serverDir $binName
if ($PSCmdlet.ShouldProcess($binPath, 'go build pool-control-service')) {
    Push-Location $serverDir
    try {
        & $go build -o $binName . 2>&1 | ForEach-Object { Write-Verbose $_ }
        if ($LASTEXITCODE -ne 0) { Write-Error "go build failed (exit $LASTEXITCODE)."; exit $ExitFailure }
    } finally { Pop-Location }
}

# The intent URL + host id come from config / the runtime identity.
$intentGitUrl = ''
try {
    if ($env:YURUNA_CONFIG_PATH -and (Test-Path -LiteralPath $env:YURUNA_CONFIG_PATH) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        $cfg = Get-Content -Raw -LiteralPath $env:YURUNA_CONFIG_PATH | ConvertFrom-Yaml -Ordered
        if ($cfg -and $cfg['pool'] -and $cfg['pool']['intentGitUrl']) { $intentGitUrl = [string]$cfg['pool']['intentGitUrl'] }
    }
} catch { Write-Verbose "intentGitUrl lookup: $($_.Exception.Message)" }
# Get-Variable -Scope Global reads the cross-host identity channel without a
# $global: reference (keeps PSAvoidGlobalVars quiet); absent -> $null.
$hostId = [string](Get-Variable -Name '__YurunaHostId' -Scope Global -ValueOnly -ErrorAction SilentlyContinue)

$goArgs = @('--http-addr', "0.0.0.0:$Port", '--repo-dir', $repoRoot, '--pwsh', $pwshExe)
if ($intentGitUrl)  { $goArgs += @('--intent-git-url', $intentGitUrl) }
if ($AggregatorUrl) { $goArgs += @('--aggregator-url', $AggregatorUrl) }
if ($hostId)        { $goArgs += @('--host-id', $hostId) }

if ($PSCmdlet.ShouldProcess($binPath, "launch pool-control-service on :$Port")) {
    $proc = Start-Process -FilePath $binPath -ArgumentList $goArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 1
    $localIp = try { (Test-Connection -TargetName ([System.Net.Dns]::GetHostName()) -Count 1 -ErrorAction SilentlyContinue).Address.IPAddressToString } catch { $null }
    if ([string]::IsNullOrWhiteSpace($localIp)) { $localIp = '127.0.0.1' }
    Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
    [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir `
        -Active $true -BaseUrl "http://${localIp}:$Port/" `
        -Extra ([ordered]@{ pid = $proc.Id; port = $Port }))
    if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
        try { Write-HostRegistrationRecord -HostType (Get-HostType) | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
    }
    Write-Verbose "Pool-control service running (pid $($proc.Id)) at http://${localIp}:$Port/  (UI: /, /pools, /test-sets)."
}
exit $ExitOk
