<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456760
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
    Brings up the Yuruna Stash Service VM (host.windows.hyper-v,
    host.ubuntu.kvm, host.macos.utm). See
    https://yuruna.link/stash-service for the full specification.

.PARAMETER VMName   Name for the stash VM. Default: yuruna-stash-service.
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
    exit 1
}

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$RepoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
# Same module set as Start-CachingProxy: Test.HostContract (for Get-HostType /
# Initialize-YurunaHost), Test.VMUtility (host-agnostic helpers),
# Test.CachingProxy reuse not needed here (stash VM is independent of
# the cache).
Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- stash storage pre-flight (design spec sections 2 and 3.1) -----------
# The Stash Service stores its files on its OWN, isolated stash share
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
Start-StashServer requires the stash storage to be configured (isolated from the pool):
set networkStorage.stashNetworkPath / stashNetworkUser / stashLocalPath in
test/test.config.yml and Set-Password the stashNetworkUser. See docs/test-config.md
and docs/design/stash-service.md (section 3.1).
"@
    exit 1
}
# Hard gate: a REAL password must already be stored for the stash SMB user.
# Test-PoolStorageVaultReady is too lenient here -- it also passes when only a
# vaultKey is MAPPED (no stored password), which makes the seed bake an
# AUTO-GENERATED junk password the NAS rejects (cifs mount error(13)). The SMB
# user authenticates to a PRE-EXISTING NAS account, so require a stored entry.
if (-not (Test-PoolStorageStoredCredential -Config $stashCfg)) {
    Write-Error @"
stash networkUser '$($stashCfg.NetworkUser)' has NO password stored in the vault.
The stash VM mounts the stash share with this account; without a stored credential the
VM seed bakes an auto-generated value the NAS rejects (cifs mount error(13)), so the
share never mounts. Store the real NAS password first, then re-run:
    Set-Password -Username '$($stashCfg.NetworkUser)' -NewPassword '<the real NAS password>'
See docs/test-config.md (networkStorage credentials).
"@
    exit 1
}
# Soft gate: a credential IS stored -- verify it actually AUTHENTICATES to the
# stash share (catches a stale/wrong stored password, which the read-only check
# above cannot). WARNING, not a hard stop: the daemon buffers locally when the
# share is offline (stash-service-ui.md section 8.4), and the NAS may merely be
# transiently unreachable. Connect-YurunaPoolStorage is bounded + best-effort and
# uses the SAME credential the seed will bake.
if (Connect-YurunaPoolStorage -Config $stashCfg -Confirm:$false) {
    Write-Output "stash storage pre-flight OK (networkUser='$($stashCfg.NetworkUser)'; credential authenticates)."
} else {
    Write-Warning @"
stash networkUser '$($stashCfg.NetworkUser)' has a stored credential, but it did NOT
authenticate to the stash share '$($stashCfg.NetworkPath)' just now (wrong/stale password,
or the NAS is unreachable). Bringing the VM up anyway: the daemon will START and BUFFER
uploads locally, but they will NOT persist to the stash share until this is fixed. If the
password is stale, update it and rebuild:
    Set-Password -Username '$($stashCfg.NetworkUser)' -NewPassword '<the real NAS password>'
"@
}

$hostFolder = Get-HostFolder $HostType
$guestDir   = Join-Path -Path $RepoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.stash-service'
$newVm      = Join-Path $guestDir 'New-VM.ps1'
if (-not (Test-Path -LiteralPath $newVm)) {
    Write-Error "New-VM.ps1 not found for $HostType at $newVm"
    exit 1
}

# Delegate to the per-host New-VM. Each script already runs Get-Image
# auto-fetch when the base image is missing, tears down any prior VM,
# creates the new one, and (Hyper-V + KVM) starts it. UTM only builds
# the bundle -- registration + start lives below.
Write-Output ""
Write-Output "== Bringing up '$VMName' on $HostType =="
& pwsh -NoProfile -File $newVm -VMName $VMName
$rc = $LASTEXITCODE
if ($rc -ne 0) {
    Write-Error "$newVm exited $rc -- aborting."
    exit $rc
}

# UTM-only: register the bundle and start the VM. Hyper-V and KVM
# already started the VM inside New-VM.ps1 (Hyper-V\Start-VM and
# virt-install --import respectively).
if ($HostType -eq 'host.macos.utm') {
    $UtmDir = "$HOME/yuruna/guest.nosync/$VMName.utm"
    if (-not (Test-Path $UtmDir)) {
        Write-Error "UTM bundle missing at $UtmDir after New-VM."
        exit 1
    }
    & utmctl status $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "Registering bundle with UTM (open $UtmDir)..."
        & /usr/bin/open $UtmDir
        $waitDeadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $waitDeadline) {
            & utmctl status $VMName 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 2
        }
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "UTM did not register '$VMName' within 60s. Open UTM manually, accept the bundle, then re-run."
            exit 1
        }
    }
    Write-Output "Starting '$VMName' via utmctl..."
    & utmctl start $VMName 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "utmctl start '$VMName' returned non-zero -- check UTM."
    }
}

# Advertise that THIS host actively runs a stash server, so the pool-aggregator
# lists it in the dashboard's Extension hosts table. The marker (stash-server.json)
# is folded into host.registration.json (activeExtensions + extensionTargets) by
# Write-HostRegistrationRecord; the aggregator -- already polling every pool host's
# registration -- reads it WITHOUT mounting ystash-nas or needing a Config Service on
# its own host. Stop-StashServer.ps1 removes the marker. Best-effort throughout;
# never fails the bring-up.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
$runtimeDir = $null
try {
    $runtimeDir = Initialize-YurunaRuntimeDir
    $marker = [ordered]@{
        active       = $true
        vmName       = $VMName
        hostType     = $HostType
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'stash-server.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    Write-Output "  Recorded stash-server marker -- this host will appear under Extension hosts."
} catch { Write-Verbose "stash-server marker write: $($_.Exception.Message)" }

# Resolve the stash VM's guest address into the marker (stashBaseUrl) so the
# dashboard's Extension cell deep-links to the stash UI. Best-effort + bounded: a
# Hyper-V External vSwitch can report the address minutes after boot, so poll
# briefly; if it is not up yet the link stays absent until a later refresh (the
# per-cycle runner call, or a re-run) populates it. Uses the host contract Get-VMIp
# wired by Initialize-YurunaHost above.
if ($runtimeDir) {
    try {
        $stashUrl = Update-StashServerMarkerAddress -RuntimeDir $runtimeDir -VMName $VMName -TimeoutSeconds 180
        if ($stashUrl) { Write-Output "  Stash VM address: $stashUrl (Extension cell deep-links here)." }
        else { Write-Output "  Stash VM address not resolved yet -- the Extension deep-link populates on a later refresh." }
    } catch { Write-Verbose "stash address resolve: $($_.Exception.Message)" }
}

# Publish the marker NOW: regenerate host.registration.json so the aggregator sees
# the active extension on its next poll, without waiting for a test cycle (the only
# other point Write-HostRegistrationRecord runs). It reads the runtime dir +
# $global:__YurunaHostId; Set-Variable -Scope Global keeps PSAvoidGlobalVars quiet.
try {
    Set-Variable -Name '__YurunaHostId' -Scope Global -Value (Get-YurunaHostId)
    Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force
    if (Write-HostRegistrationRecord -HostType $HostType -RepoRoot $RepoRoot) {
        Write-Output "  Refreshed host.registration.json (Extension hosts updates within one aggregator poll)."
    }
} catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }

# The aggregator can only READ that registration if a status server is serving
# /runtime/host.registration.json. A host that runs test cycles already has one up;
# a stash-only host would not, so ensure it here -- making "start the stash service"
# sufficient for the host to appear, no test runner required. Honors
# statusService.isEnabled + port; a healthy server is left running (compare-and-skip).
try {
    $statusScript = Join-Path $RepoRoot 'test/Start-StatusService.ps1'
    if ($tc -and (Test-Path -LiteralPath $statusScript)) {
        [void](Start-YurunaStatusServiceIfEnabled -Config $tc -StartScript $statusScript)
    }
} catch { Write-Verbose "status service ensure: $($_.Exception.Message)" }

Write-Output ""
Write-Output "== stash-service start: complete =="
Write-Output "  VM:       $VMName"
Write-Output "  Host:     $HostType"
Write-Output ""
Write-Output "Cloud-init mounts the stash share, fetches the framework, and runs the"
Write-Output "bring-up script that builds + launches the stash daemon under systemd."
Write-Output "Allow a few minutes after first boot; watch the VM's cloud-init-output.log."
Write-Output "(See https://yuruna.link/stash-service.)"
Write-Output ""
Write-Output "Stop with: ./Stop-StashServer.ps1"
exit 0
