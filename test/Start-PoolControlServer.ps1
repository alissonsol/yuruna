<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42e5f6a7-b8c9-4d01-8234-5f6a7b8c9d0e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool control extension service
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
    Build + launch the Pool control service on THIS host and publish its marker.
.DESCRIPTION
    The host-side ("runs first") variant of the Pool control extension: builds the
    Go binary from test/extension/pool-control/server and starts it in the
    background, serving the 3-page UI + API. Writes runtime/pool-control.json (the
    marker Test.Capability folds into host.registration.json so the service shows
    up in the Extension hosts table) and refreshes the registration record. The
    Go service also self-announces to the aggregator via its beacon, so the
    Extension-hosts row appears by marker AND by beacon independently. N9 moves
    this to a dedicated VM (systemd); this launcher is for the host-side proof.
.PARAMETER Port
    UI/API port. Default 8090 (kept clear of the status server's 8080).
.PARAMETER AggregatorUrl
    Pool aggregator base URL for the beacon. Optional (empty disables the beacon;
    the marker path still works).
.PARAMETER Vm
    Bring the service up on its OWN VM (guest.pool-control chain) instead of the
    host-side proof. Mirrors Start-StashServer: pool-storage pre-flight, then
    delegate to the per-host New-VM.ps1. Default OFF preserves the host-side path.
.PARAMETER VMName
    Name of the pool-control VM when -Vm is passed. Default: yuruna-pool-control.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [int]$Port = 8090,
    [string]$AggregatorUrl = '',
    [switch]$Vm,
    [string]$VMName = 'yuruna-pool-control'
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$null        = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = Split-Path -Parent $PSScriptRoot
$serverDir  = Join-Path $repoRoot 'test/extension/pool-control/server'
$runtimeDir = if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) { Initialize-YurunaRuntimeDir } else { $env:YURUNA_RUNTIME_DIR }
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

# --- REGION: -Vm delegation (bring up on its own VM; mirrors Start-StashServer)
# Default OFF leaves the host-side proof below untouched. When -Vm is passed,
# run the pool-storage pre-flight, then delegate to the per-host New-VM.ps1.
if ($Vm) {
    if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
        Write-Error "Invalid VMName '$VMName'. Only alphanumeric, dot, hyphen, and underscore are allowed."
        exit $ExitFailure
    }
    $ModulesDir = Join-Path $PSScriptRoot 'modules'
    Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Global -Force
    Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

    $HostType = Get-HostType
    if (-not $HostType) { exit $ExitFailure }
    Write-Information "Host type: $HostType" -InformationAction Continue
    [void](Initialize-YurunaHost -RepoRoot $repoRoot -HostType $HostType)

    # --- REGION: pool storage pre-flight
    # The pool-control daemon persists its audit log + status.json under the pool
    # NAS (poolNetworkPath/pool-control/). Refuse to bring up a VM that would have
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
Start-PoolControlServer -Vm requires the pool storage to be configured:
set networkStorage.poolNetworkPath / poolNetworkUser / poolLocalPath in
test/test.config.yml and Set-Password the poolNetworkUser. See docs/test-config.md
and docs/pool-control.md.
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
The pool-control VM mounts the pool NAS with this account; without a stored credential
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

    $hostFolder = Get-HostFolder $HostType
    $guestDir   = Join-Path -Path $repoRoot -ChildPath $hostFolder -AdditionalChildPath 'guest.pool-control'
    $newVm      = Join-Path $guestDir 'New-VM.ps1'
    if (-not (Test-Path -LiteralPath $newVm)) {
        Write-Error "New-VM.ps1 not found for $HostType at $newVm"
        exit $ExitFailure
    }

    # Delegate to the per-host New-VM. Each script runs Get-Image auto-fetch when
    # the base image is missing, tears down any prior VM, creates the new one, and
    # (Hyper-V + KVM) starts it. UTM only builds the bundle -- register + start below.
    Write-Information "== Bringing up '$VMName' on $HostType ==" -InformationAction Continue
    & pwsh -NoProfile -File $newVm -VMName $VMName
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        Write-Error "$newVm exited $rc -- aborting."
        exit $rc
    }

    # UTM-only: register the bundle and start the VM. Hyper-V and KVM already
    # started the VM inside New-VM.ps1.
    if ($HostType -eq 'host.macos.utm') {
        $UtmDir = "$HOME/yuruna/guest.nosync/$VMName.utm"
        if (-not (Test-Path $UtmDir)) {
            Write-Error "UTM bundle missing at $UtmDir after New-VM."
            exit $ExitFailure
        }
        & utmctl status $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Information "Registering bundle with UTM (open $UtmDir)..." -InformationAction Continue
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
                exit $ExitFailure
            }
        }
        Write-Information "Starting '$VMName' via utmctl..." -InformationAction Continue
        & utmctl start $VMName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "utmctl start '$VMName' returned non-zero -- check UTM."
        }
    }

    # Write the pool-control marker for the VM (Test.Capability folds it into
    # host.registration.json so the Extension hosts table lists this host).
    $marker = [ordered]@{
        active       = $true
        vmName       = $VMName
        hostType     = $HostType
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'pool-control.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
        try { Write-HostRegistrationRecord -HostType $HostType | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
    }
    Write-Information "== pool-control VM start: complete (VM '$VMName' on $HostType) ==" -InformationAction Continue
    Write-Information "Cloud-init fetches the framework and runs the bring-up script that builds + launches the daemon on :80. Watch the VM's cloud-init-output.log; see https://yuruna.link/pool-control." -InformationAction Continue
    exit $ExitOk
}

$go = (Get-Command go -ErrorAction SilentlyContinue)?.Source
if (-not $go) { Write-Error 'go toolchain not found on PATH; cannot build the pool-control service.'; exit $ExitFailure }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)?.Source
if (-not $pwshExe) { $pwshExe = 'pwsh' }

# Build the binary.
$binName = if ($IsWindows) { 'pool-control.exe' } else { 'pool-control' }
$binPath = Join-Path $serverDir $binName
if ($PSCmdlet.ShouldProcess($binPath, 'go build pool-control')) {
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
# Get-Variable -Scope Global reads the cross-host identity channel the entry
# point set without a $global: reference (keeps PSAvoidGlobalVars quiet); absent
# -> $null, matching the prior read.
$hostId = [string](Get-Variable -Name '__YurunaHostId' -Scope Global -ValueOnly -ErrorAction SilentlyContinue)

$goArgs = @('--http-addr', "0.0.0.0:$Port", '--repo-dir', $repoRoot, '--pwsh', $pwshExe)
if ($intentGitUrl)  { $goArgs += @('--intent-git-url', $intentGitUrl) }
if ($AggregatorUrl) { $goArgs += @('--aggregator-url', $AggregatorUrl) }
if ($hostId)        { $goArgs += @('--host-id', $hostId) }

if ($PSCmdlet.ShouldProcess($binPath, "launch pool-control on :$Port")) {
    $proc = Start-Process -FilePath $binPath -ArgumentList $goArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 1
    $localIp = try { (Test-Connection -TargetName ([System.Net.Dns]::GetHostName()) -Count 1 -ErrorAction SilentlyContinue).Address.IPAddressToString } catch { $null }
    if ([string]::IsNullOrWhiteSpace($localIp)) { $localIp = '127.0.0.1' }
    $marker = [ordered]@{
        active            = $true
        pid               = $proc.Id
        port              = $Port
        poolControlBaseUrl = "http://${localIp}:$Port/"
        startedAtUtc      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'pool-control.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
    if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
        try { Write-HostRegistrationRecord -HostType (Get-HostType) | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
    }
    Write-Information "Pool control running (pid $($proc.Id)) at http://${localIp}:$Port/  (UI: /, /pools, /test-sets)." -InformationAction Continue
}
exit $ExitOk
