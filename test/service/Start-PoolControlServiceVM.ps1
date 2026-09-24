<#PSScriptInfo
.VERSION 2026.09.24
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
.PARAMETER AllowPseudoLocale
    Open expanded and mirrored pseudo locales for an explicit reference run.
    Disabled by default for both VM and host-side deployments.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'yuruna-pool-control-service',
    [switch]$HostSideProof,
    [int]$Port = 8090,
    [string]$AggregatorUrl = '',
    [switch]$AllowMirrorSource,
    [switch]$AllowPseudoLocale
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if ((-not $HostSideProof -or $WhatIfPreference) -and -not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }

$InformationPreference = 'Continue'

# --- REGION: Initialize service runtime
# See https://yuruna.link/42fffc2c-000b
# See https://yuruna.link/42162449-0004
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir

# --- REGION: https://yuruna.link/42e220c4-0008
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Locale.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

if (-not $HostSideProof) {
    # Mirrors Start-StashServiceVM / Start-CachingProxyServiceVM: pool-storage pre-flight, then
    # delegate to the per-host New-VM.ps1 whose cloud-init builds + launches the
    # daemon inside the guest. -HostSideProof (below) is the no-VM fallback.
    if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
        exit $ExitFailure
    }

    # --- REGION: https://yuruna.link/42e220c4-0008
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

    # --- REGION: Storage preflight
    # See https://yuruna.link/42e220c4-0008
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

    # --- REGION: Resolve the VM builder
    $hostFolder = Get-HostFolder $HostType
    $guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.pool-control-service'
    $newVm      = Join-Path $guestDir 'New-VM.ps1'
    if (-not (Test-Path -LiteralPath $newVm)) {
        Write-Error "New-VM.ps1 not found for $HostType at $newVm"
        exit $ExitFailure
    }

    # --- REGION: Start the host status service
    # See https://yuruna.link/42fffc2c-0013
    $statusDecision = $null
    try {
        $statusScript = Join-Path $repoRoot 'test/service/Start-StatusService.ps1'
        if ($tc -and (Test-Path -LiteralPath $statusScript)) {
            $statusResult = Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript
            $statusDecision = @($statusResult | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
        }
    } catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

    # --- REGION: Verify the framework source
    # See https://yuruna.link/42fffc2c-0013
    Import-Module (Join-Path $ModulesDir 'Test.FrameworkSource.psm1') -Global -Force
    $frameworkExpected = Get-FrameworkSourceSnapshot -RepoRoot $repoRoot
    if (-not (Assert-GuestFrameworkSource -RepoRoot $repoRoot -StatusDecision $statusDecision `
                -ServiceLabel 'pool-control-service' -AllowMirrorSource:$AllowMirrorSource)) {
        exit $ExitFailure
    }

    # --- REGION: Create the VM
    # Each New-VM runs Get-Image auto-fetch when the base image is missing, tears down any
    # prior VM, creates the new one, and (Hyper-V + KVM) starts it. UTM only builds the
    # bundle -- register + start below.
    Write-Information "== Bringing up '$VMName' on $HostType ==" -InformationAction Continue
    $newVmArgs = @('-NoProfile', '-File', $newVm, '-VMName', $VMName)
    if ($AllowPseudoLocale) { $newVmArgs += '-AllowPseudoLocale' }
    & pwsh @newVmArgs
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Error "$newVm exited $rc -- aborting."
        exit $rc
    }

    # --- REGION: Register and start the UTM VM
    # See https://yuruna.link/42e220c4-0008
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

    # --- REGION: Verify the VM state
    # See https://yuruna.link/42e220c4-0008
    if (-not (Wait-VMRunning -VMName $VMName -TimeoutSeconds 120)) {
        $observed = try { Get-VMState -VMName $VMName } catch { 'unknown' }
        Write-Error "VM '$VMName' did not reach 'running' (state: $observed); the pool-control service was NOT started. Nothing in the guest -- cloud-init, the go build, the pool NAS mount -- has run yet. Open the VM in the hypervisor UI and start it by hand to see why."
        exit $ExitFailure
    }

    # --- REGION: Configure Shared NAT forwarding
    # See https://yuruna.link/42e220c4-0008
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

    # --- REGION: Probe service readiness
    # See https://yuruna.link/42e220c4-0008
    Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
    Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
    # --- REGION: https://yuruna.link/42e220c4-0008
    $ipWaitStart = (Get-Date)
    $vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
    $ipWaitSeconds = [int]((Get-Date) - $ipWaitStart).TotalSeconds

    # --- REGION: https://yuruna.link/42e220c4-0008
    $readyTimeoutSeconds = Get-ExtensionServiceReadyTimeoutSeconds -Area 'pool-control-service'
    $readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)
    # How long a guest located by the last-resort route below gets to answer on
    # :80. Deliberately short: it runs only after the ordinary wait has already
    # spent its whole budget, and it is confirming a listener that either answers
    # within a few polls or was never there.
    $recoveryProbeSeconds = 60

    # --- REGION: https://yuruna.link/42e220c4-0008
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
    # --- REGION: https://yuruna.link/42e220c4-0008
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
        # --- REGION: https://yuruna.link/42e220c4-0008
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
        # --- REGION: https://yuruna.link/42e220c4-0008
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
                # --- REGION: https://yuruna.link/42e220c4-0008
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

    # --- REGION: Evaluate service readiness
    # See https://yuruna.link/42e220c4-0008
    $verdict = Get-ServiceVmReadinessVerdict -Endpoint $endpoint

    # --- REGION: https://yuruna.link/4220a755-0046
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
                    # --- REGION: https://yuruna.link/42e220c4-0008
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

    # --- REGION: https://yuruna.link/42fffc2c-0008
    # No trailing slash, which is not cosmetic: the service's own announce derives
    # its address from the connection it arrives on and so never carries one. The
    # aggregator keys a candidate on the exact target string, so the two spellings
    # of one address register as two candidates for the same host and area, and the
    # loser is reported as a supersededTarget. Probing already tolerates either
    # form, which is why nothing failed and the difference showed up only as a
    # duplicate. The sibling services advertise the bare form as well.
    $poolControlServiceBaseUrl = if (-not $daemonReady -or $listeningButUnreachable -or -not $vmIp) { '' }
                                 elseif ($vmIp -match ':') { "http://[$vmIp]" } else { "http://$vmIp" }
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
        # --- REGION: Report the deployed source
        # See https://yuruna.link/42fffc2c-0013
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

        # --- REGION: https://yuruna.link/42e220c4-0008
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
    # --- REGION: https://yuruna.link/42e220c4-0008
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
    Write-Verbose "========"
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
}

# --- REGION: Build and start the host-side service
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

# Read the same validated lab-wide language used to build a service-VM seed.
# Canonicalizing at this launcher boundary also keeps the native argument free
# of shell/path syntax; unsupported-but-well-formed tags remain a deliberate
# config lock and are refused by the daemon's compiled locale authority.
$hostStatusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
$languageRaw = [string](Get-TestConfigValue -Config $hostStatusSeed.Config -Path 'language')
$poolControlLanguage = if ([string]::IsNullOrWhiteSpace($languageRaw) -or $languageRaw -ieq 'auto') {
    'auto'
} else {
    ConvertTo-CanonicalLocaleTag -Tag $languageRaw
}
if (-not $poolControlLanguage) {
    Write-Error "Invalid language '$languageRaw' in test/test.config.yml."
    exit $ExitFailure
}

$goArgs = @('--http-addr', "0.0.0.0:$Port", '--repo-dir', $repoRoot, '--pwsh', $pwshExe,
    '--language', $poolControlLanguage)
if ($intentGitUrl)  { $goArgs += @('--intent-git-url', $intentGitUrl) }
if ($AggregatorUrl) { $goArgs += @('--aggregator-url', $AggregatorUrl) }
if ($hostId)        { $goArgs += @('--host-id', $hostId) }
if ($AllowPseudoLocale) { $goArgs += '--allow-pseudo-locale' }

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
