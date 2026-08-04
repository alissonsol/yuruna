<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42e5f6a7-b8c9-4d01-8234-5f6a7b8c9d0e
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
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'yuruna-pool-control-service',
    [switch]$HostSideProof,
    [int]$Port = 8090,
    [string]$AggregatorUrl = ''
)

$InformationPreference = 'Continue'

# $ErrorActionPreference is deliberately left at its inherited 'Continue', and
# must stay that way. A script-scoped 'Stop' is not scoped to the script: an
# advanced function invoked from here runs under it too, so every helper this
# bring-up calls would have its NON-terminating errors promoted to terminating
# ones. Several of the steps below are built on exactly that tolerance -- the
# pool-storage soft gate warns and proceeds when the share does not answer,
# because the daemon degrades to no persistence rather than failing, and the UTM
# port-forward and pool-intent alias steps are reported-never-fatal. Under 'Stop'
# each of those designed outcomes ends the bring-up instead, and its reason is
# left on a console that is gone by the time anyone reads the run log. The
# sibling service bring-ups (stash, caching proxy) run at 'Continue' for the same
# reason. Where a condition really must stop this script, it says so itself with
# an explicit Write-Error + exit, as the pre-flight hard gates below do.

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

# Initialize-YurunaEntryPoint returns only paths -- it imports no modules -- so
# pull in Test.YurunaDir explicitly for Initialize-YurunaRuntimeDir /
# Get-YurunaHostId. Initialize-YurunaRuntimeDir DEFAULTS + creates
# <testRoot>/status/runtime when $env:YURUNA_RUNTIME_DIR is unset, so the marker
# always has a home on a fresh shell instead of depending on an inherited env var.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

if (-not $HostSideProof) {
    # --- REGION: default -- bring the service up on its OWN VM (guest.pool-control-service)
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
    Write-Information "Host type: $HostType" -InformationAction Continue
    [void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

    # --- REGION: pool storage pre-flight
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
        try { $poolCfg = Get-YurunaPoolStorageConfig -Config $tc -IgnoreReplicate } catch { Write-Verbose "pool storage config: $($_.Exception.Message)" }
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
        Write-Information "pool storage pre-flight OK (networkUser='$($poolCfg.NetworkUser)'; credential authenticates)." -InformationAction Continue
    } else {
        Write-Warning @"
pool networkUser '$($poolCfg.NetworkUser)' has a stored credential, but it did NOT
authenticate to the pool share '$($poolCfg.NetworkPath)' just now (wrong/stale password,
or the NAS is unreachable). Bringing the VM up anyway: the daemon will START but persist
NOTHING until this is fixed. If the password is stale, update it and rebuild:
    Set-Password -Username '$($poolCfg.NetworkUser)' -NewPassword '<the real NAS password>'
"@
    }

    # --- REGION: resolve the per-host New-VM
    $hostFolder = Get-HostFolder $HostType
    $guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.pool-control-service'
    $newVm      = Join-Path $guestDir 'New-VM.ps1'
    if (-not (Test-Path -LiteralPath $newVm)) {
        Write-Error "New-VM.ps1 not found for $HostType at $newVm"
        exit $ExitFailure
    }

    # --- REGION: host status service (serves the local repo to the guest) -- BEFORE the build
    # Mirrors Start-StashServiceVM / Start-CachingProxyServiceVM: the pool-control-service guest's cloud-init
    # fetches the framework from http://<host>:<port>/yuruna-archive.tar.gz at first boot,
    # and falls back to a public github clone when that server is down -- so it must be up
    # BEFORE New-VM bakes and boots the guest, not after (a server started later is one the
    # guest never saw). Best-effort; honors statusService.enabled + port.
    try {
        $statusScript = Join-Path $repoRoot 'test/Start-StatusService.ps1'
        if ($tc -and (Test-Path -LiteralPath $statusScript)) {
            [void](Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript)
        }
    } catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

    # --- REGION: delegate to the per-host New-VM (build + start the VM)
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

    # --- REGION: post-boot readiness probe on :80 + on-failure guest diagnostics
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

    # Generous default so a slow first build (golang + pwsh install + go build over
    # the caching-proxy service) is not mis-reported as a failure; exits early the moment
    # :80 accepts. YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS overrides (e.g. a short value
    # for a quick re-check on a VM that is already up).
    $readyTimeoutSeconds = 900
    if ($env:YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS) {
        $parsed = 0
        if ([int]::TryParse($env:YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS, [ref]$parsed) -and $parsed -gt 0) { $readyTimeoutSeconds = $parsed }
    }
    $readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)

    $daemonReady = $false
    if ($vmIp) {
        Write-Information "VM '$VMName' is at $vmIp. Waiting up to $readyTimeoutMinutes min for the pool-control-service daemon to serve on :80 (first boot builds it in-guest)..." -InformationAction Continue
        $readyDeadline = (Get-Date).AddSeconds($readyTimeoutSeconds)
        $probeStart    = Get-Date
        $nextTick      = 30
        # Two very different faults look identical from out here -- a daemon
        # still building in-guest, and a daemon that has been serving for
        # minutes on an address this host cannot reach. Waiting helps the first
        # and can never help the second, so once the guest is far enough along
        # to answer SSH, ask IT whether anything is listening. Deferred to
        # $reachabilityCheckAfterSeconds because sshd is not up instantly and an
        # early no-answer would prove nothing.
        $reachabilityCheckAfterSeconds = 120
        $reachabilityChecked = $false
        $listeningButUnreachable = $false
        while ((Get-Date) -lt $readyDeadline) {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            try {
                $async = $tcp.BeginConnect($vmIp, 80, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) { $daemonReady = $true; break }
            } catch { Write-Verbose "pool-control-service :80 probe: $($_.Exception.Message)" }
            finally { $tcp.Close() }
            $elapsed = [int]((Get-Date) - $probeStart).TotalSeconds
            if ($elapsed -ge $nextTick) {
                # Floor, not [int]: the cast rounds half-to-even, so 90s printed
                # as "02m30s" and the tick sequence read as though it went
                # backwards (04m30s before 04m00s).
                Write-Information ("  [{0:D2}m{1:D2}s / {2}m] still waiting for the daemon on :80..." -f [int][math]::Floor($elapsed / 60), ($elapsed % 60), $readyTimeoutMinutes) -InformationAction Continue
                $nextTick += 30
            }
            if (-not $reachabilityChecked -and $elapsed -ge $reachabilityCheckAfterSeconds -and
                (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
                $inGuest = $null
                try {
                    $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.pool-control-service' `
                        -User 'pool-control-service-admin' -TimeoutSeconds 30 `
                        -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
                } catch { Write-Verbose "pool-control-service in-guest listener probe: $($_.Exception.Message)" }
                # Only a completed answer settles anything. SSH that did not
                # connect means the guest is still coming up, so leave the check
                # unmade and let a later pass ask again.
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
The pool-control-service daemon IS serving on :80 inside the guest, but this host
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
                       "address discovery, not a boot failure. The :80 readiness probe never ran -- going straight to guest diagnostics.")
    }

    # Publish the marker + refresh registration (mirrors Start-StashServiceVM's publish
    # step): write runtime/pool-control-service.json, then regenerate host.registration.json
    # so the aggregator lists this host under Extension hosts on its next poll --
    # not only after the next test cycle. poolControlServiceBaseUrl gives the Extension
    # cell a deep-link even before the daemon's first beacon; an IPv6 literal is
    # bracketed for the URL authority. The registration refresh is best-effort
    # telemetry and must never fail the bring-up. Write-HostRegistrationRecord reads
    # $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
    # active tracks the READINESS VERDICT, not the fact that this script ran: a
    # bring-up that ends at the failure exit below would otherwise advertise a
    # pool-control service that is not serving, and the dashboard would deep-link
    # operators to a dead UI.
    $poolControlServiceBaseUrl = if (-not $vmIp) { '' } elseif ($vmIp -match ':') { "http://[$vmIp]/" } else { "http://$vmIp/" }
    Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
    [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir `
        -Active $daemonReady -VMName $VMName -HostType $HostType -BaseUrl $poolControlServiceBaseUrl)
    try {
        Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
        Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
        [void](Write-HostRegistrationRecord -HostType $HostType -RepoRoot $repoRoot)
    } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

    if ($daemonReady) {
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
                Write-Information "  Proxy: /pool-intent.git now serves the pool NAS store (runners pull what this UI writes)." -InformationAction Continue
            } elseif (-not $aliasSync.Ok) {
                Write-Warning "pool-intent alias not reconciled on the caching-proxy service: $($aliasSync.Message). Runners may still pull the proxy's older local store; the pool-control service UI is unaffected."
            } else {
                Write-Verbose "pool-intent alias: $($aliasSync.Message)"
            }
        } catch { Write-Verbose "pool-intent alias sync: $($_.Exception.Message)" }

        Write-Information "" -InformationAction Continue
        Write-Information "== pool-control-service is READY (daemon serving on :80) ==" -InformationAction Continue
        Write-Information "  VM:   $VMName ($HostType)" -InformationAction Continue
        Write-Information "  UI:   $poolControlServiceBaseUrl  (Assign / Pools / Test sets)" -InformationAction Continue
        Write-Information "  SSH:  ssh pool-control-service-admin@$vmIp  (harness key authorized)" -InformationAction Continue
        Write-Information "  Stop: test/Stop-PoolControlServiceVM.ps1" -InformationAction Continue
        exit $ExitOk
    }

    # Not serving. Collect the in-guest build log + service state over the harness
    # key (pool-control-service-admin, NOPASSWD sudo) so the operator sees the actual failure
    # instead of a dead URL. -User pins the account the cloud-init seed created:
    # it is the only login this VM has, and Get-GuestSshUser would otherwise return
    # a per-cycle cascade override that an earlier run in this same shell session
    # left registered for guest.pool-control-service.
    # Says what ACTUALLY happened, not what the budget allowed. Two different
    # failures reach this line -- an address that never appeared, and an address
    # that never answered -- and quoting the nominal timeout for the first
    # describes a wait that did not occur.
    $failureDetail = if ($vmIp) {
        "is NOT serving on :80 (VM $vmIp) after $readyTimeoutMinutes min"
    } else {
        "never got an address (no IP after ${ipWaitSeconds}s), so :80 was never probed"
    }
    Write-Warning "pool-control-service daemon $failureDetail. Collecting in-guest diagnostics over the harness SSH key..."
    $diagCmd = @(
        'echo "=== cloud-init status ==="; cloud-init status --long 2>&1 | head -n 20',
        'echo "=== systemctl status pool-control-service.service ==="; systemctl --no-pager --full status pool-control-service.service 2>&1 | head -n 25',
        'echo "=== journalctl -u pool-control-service.service (last 40) ==="; sudo journalctl -u pool-control-service.service --no-pager -n 40 2>&1',
        'echo "=== listening on :80? ==="; ss -ltn 2>/dev/null | grep -E ":80\b" || echo "(nothing listening on :80)"',
        'echo "=== /var/log/cloud-init-output.log (tail 120) ==="; sudo tail -n 120 /var/log/cloud-init-output.log 2>&1'
    ) -join "`n"
    $diag = $null
    if ($vmIp -and (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue)) {
        try { $diag = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.pool-control-service' -User 'pool-control-service-admin' -Command $diagCmd -TimeoutSeconds 120 }
        catch { Write-Verbose "guest diagnostics ssh: $($_.Exception.Message)" }
    }
    Write-Information "" -InformationAction Continue
    Write-Information "================= pool-control-service guest diagnostics =================" -InformationAction Continue
    if ($diag -and -not [string]::IsNullOrWhiteSpace([string]$diag.output)) {
        foreach ($line in ([string]$diag.output -split "`r?`n")) { Write-Information "  $line" -InformationAction Continue }
        if (-not $diag.success) {
            Write-Information "  (ssh ended with exit=$($diag.exitCode); the capture above is what completed before it did)" -InformationAction Continue
        }
    } else {
        Write-Information "  Could not reach the VM over SSH (sshd may still be starting, or networking is broken)." -InformationAction Continue
        if ($vmIp) { Write-Information "  Try manually:  ssh pool-control-service-admin@$vmIp 'sudo tail -n 120 /var/log/cloud-init-output.log'" -InformationAction Continue }
    }
    Write-Information "==================================================================" -InformationAction Continue
    Write-Information "" -InformationAction Continue
    Write-Information "The pool-control-service daemon did not come up on :80. Reading the capture above:" -InformationAction Continue
    Write-Information "  * cloud-init status 'running'  -> the in-guest build (go/pwsh) is still going; wait, then" -InformationAction Continue
    Write-Information "                                    re-run to re-check (or raise YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS)." -InformationAction Continue
    Write-Information "  * a 'go build' / apt error     -> a package or source problem; the log tail shows the line." -InformationAction Continue
    Write-Information "  * 'NAS mount failed'           -> pool NAS unreachable; re-check the pool storage credential." -InformationAction Continue
    if ($vmIp) { Write-Information "Re-check any time:  ssh pool-control-service-admin@$vmIp 'systemctl status pool-control-service.service'" -InformationAction Continue }
    Write-Information "See https://yuruna.link/pool-control-service." -InformationAction Continue
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
    Write-Information "Pool-control service running (pid $($proc.Id)) at http://${localIp}:$Port/  (UI: /, /pools, /test-sets)." -InformationAction Continue
}
exit $ExitOk
