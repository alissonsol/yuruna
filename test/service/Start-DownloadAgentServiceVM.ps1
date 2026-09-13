<#PSScriptInfo
.VERSION 2026.09.13
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

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if (-not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }

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

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit $ExitFailure
}

# --- REGION: https://yuruna.link/42e220c4-0008
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

# --- REGION: https://yuruna.link/42e220c4-0008
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

# --- REGION: Resolve the VM builder
$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.download-agent-service'
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
            -ServiceLabel 'download-agent-service' -AllowMirrorSource:$AllowMirrorSource)) {
    exit $ExitFailure
}

# --- REGION: Create the VM
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
    Write-Error "VM '$VMName' did not reach 'running' (state: $observed); the download-agent service was NOT started. Nothing in the guest -- cloud-init, the go build, the pool share mount -- has run yet. Open the VM in the hypervisor UI and start it by hand to see why."
    exit $ExitFailure
}

Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1') -Global -Force
# --- REGION: https://yuruna.link/42e220c4-0008
$ipDeadline = (Get-Date)
$vmIp = try { Wait-VMIp -VMName $VMName -TimeoutSeconds 120 } catch { Write-Verbose "Wait-VMIp: $($_.Exception.Message)"; $null }
$ipWaitSeconds = [int]((Get-Date) - $ipDeadline).TotalSeconds

# --- REGION: Configure Shared NAT forwarding
# See https://yuruna.link/42e220c4-0008
$bundleMode  = ''
$hostAddress = ''
if ($HostType -eq 'host.macos.utm') {
    $bundleMode = [string](Get-UtmNetworkModeFromBundle -VMName $VMName)
    $uplinkMode = Resolve-UtmNetworkMode
    if ($bundleMode -and $uplinkMode -and $bundleMode -ne $uplinkMode) {
        Write-Warning "'$VMName' was built for '$bundleMode' networking but this host's uplink now wants '$uplinkMode' (Wi-Fi and Ethernet differ). The VM's baked addresses are for the old topology; rebuild it (Stop-DownloadAgentServiceVM.ps1 then re-run this script)."
    }
    # --- REGION: https://yuruna.link/42e220c4-0008
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

# --- REGION: Probe service readiness
# See https://yuruna.link/42e220c4-0008
$readyTimeoutSeconds = Get-DownloadAgentServiceReadyTimeoutSeconds
$readyTimeoutMinutes = [int]($readyTimeoutSeconds / 60)
# How long a guest located by the last-resort route below gets to answer on :80.
# Deliberately short: it runs only after the ordinary wait has already spent its
# whole budget, and it is confirming a listener that either answers within a few
# polls or was never there.
$recoveryProbeSeconds = 60

# --- REGION: https://yuruna.link/42e220c4-0008
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
# --- REGION: https://yuruna.link/42e220c4-0008
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
    # --- REGION: https://yuruna.link/42e220c4-0008
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
    # --- REGION: https://yuruna.link/42e220c4-0008
    Write-Warning ("Could not resolve the VM's IP after waiting ${ipWaitSeconds}s (Wait-VMIp); the VM IS running, so this is address " +
                   "discovery, not a boot failure. Asking the guest itself whether the daemon is up.")
    # --- REGION: https://yuruna.link/42e220c4-0008
    if (Get-Command Invoke-GuestSsh -ErrorAction SilentlyContinue) {
        $inGuest = $null
        try {
            $inGuest = Invoke-GuestSsh -VMName $VMName -GuestKey 'guest.download-agent-service' `
                -User 'download-agent-service-admin' -TimeoutSeconds 30 `
                -Command 'ss -ltn 2>/dev/null | grep -qE "(^|[^0-9]):80\b" && echo YURUNA_LISTENING || echo YURUNA_NOT_LISTENING'
        } catch { Write-Verbose "download-agent-service in-guest listener probe: $($_.Exception.Message)" }
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
                # --- REGION: https://yuruna.link/42e220c4-0008
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

# --- REGION: https://yuruna.link/42fffc2c-0008
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
    # --- REGION: Report the deployed source
    # See https://yuruna.link/42fffc2c-0013
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
# --- REGION: https://yuruna.link/42e220c4-0008
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
Write-Verbose "========"
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
