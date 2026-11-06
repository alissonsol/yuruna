<#PSScriptInfo
.VERSION 2026.11.05
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
    Enable developer pseudo locales for the rebuilt service VM or the host-side
    daemon. Disabled by default.
.PARAMETER ForceRebuild
    Rebuild the VM even when the running one serves the current build or is
    still building it. Without it a re-run keeps such a VM (adopts it). VM path
    only.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$VMName = 'yuruna-pool-control-service',
    [switch]$HostSideProof,
    [int]$Port = 8090,
    [string]$AggregatorUrl = '',
    [switch]$AllowMirrorSource,
    [switch]$AllowPseudoLocale,
    [switch]$ForceRebuild
)

# --- REGION: Confirm the service operation
# See https://yuruna.link/42e220c4-0008
if ((-not $HostSideProof -or $WhatIfPreference) -and -not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }

# The VM bring-up is the shared Start-ExtensionService.ps1 pipeline; the
# host-side proof below is this service's alone.
if (-not $HostSideProof) {
    & (Join-Path $PSScriptRoot 'Start-ExtensionService.ps1') -VMName $VMName -ServiceKey 'pool-control' -Area 'pool-control-service' -CallerScript $PSCommandPath `
        -AllowMirrorSource:$AllowMirrorSource -AllowPseudoLocale:$AllowPseudoLocale -ForceRebuild:$ForceRebuild -Confirm:$false
    exit $LASTEXITCODE
}

$InformationPreference = 'Continue'

# --- REGION: Initialize service runtime
# See https://yuruna.link/42fffc2c-000b
# See https://yuruna.link/42162449-0004
# After the preference assignments above on purpose: an explicit level is the
# operator's choice and replaces this script's own default.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir
Import-Module (Join-Path $ModulesDir 'Test.ServiceVm.psm1') -Global -DisableNameChecking -Verbose:$false

# --- REGION: Initialize the runtime directory
# See https://yuruna.link/42e220c4-0008
# See https://yuruna.link/42f52e37-0020
# The host-side proof records its daemon's marker there.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Locale.psm1') -Global -Force
$runtimeDir = Initialize-YurunaRuntimeDir
if ([string]::IsNullOrWhiteSpace($runtimeDir)) { Write-Error 'No runtime dir (YURUNA_RUNTIME_DIR).'; exit $ExitFailure }

# --- REGION: Record the host-side start intent
# The host-side proof records its start and holds the service lock too: a Stop
# must not remove the marker of a daemon that is still being launched, and a
# host refresh must see that this service is a host process, not a guest.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.ServiceCensus.psm1') -Global -Force -DisableNameChecking
$serviceOp = Enter-YurunaServiceOperation -Key 'pool-control' -VMName $VMName -Operation Start -HostingMode 'host-process' -Script 'Start-PoolControlServiceVM.ps1' -Confirm:$false
if (-not $serviceOp.Proceed) {
    Write-Error $serviceOp.Message
    exit $ExitFailure
}
$serviceOpResult = 'failed'
try {

# --- REGION: Build and start the host-side service
# A quick proof / fallback that needs a local Go toolchain; the VM path above is
# the default.
$serverDir = Join-Path $repoRoot 'test/extension/pool-control-service/server'
$go = (Get-Command go -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source
if (-not $go) { Write-Error 'go toolchain not found on PATH; cannot build the pool-control service. Omit -HostSideProof to bring the service up on its own VM, which builds the daemon inside the guest (no host Go toolchain needed).'; exit $ExitFailure }
$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1)?.Source
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

# The configuration URL + host id come from config / the runtime identity.
$configurationGitUrl = ''
try {
    if ($env:YURUNA_CONFIG_PATH -and (Test-Path -LiteralPath $env:YURUNA_CONFIG_PATH) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        $cfg = Get-Content -Raw -LiteralPath $env:YURUNA_CONFIG_PATH | ConvertFrom-Yaml -Ordered
        if ($cfg -and $cfg['pool'] -and $cfg['pool']['configurationGitUrl']) { $configurationGitUrl = [string]$cfg['pool']['configurationGitUrl'] }
    }
} catch { Write-Verbose "configurationGitUrl lookup: $($_.Exception.Message)" }
$hostId = Get-YurunaHostId
Set-Variable -Name '__YurunaHostId' -Scope Global -Value $hostId
Import-Module (Join-Path $ModulesDir 'Test.HostDetection.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Capability.psm1') -Global -Force

# Read the same validated lab-wide language used to build a service-VM seed.
# Canonicalizing at this launcher boundary also keeps the native argument free
# of shell/path syntax; unsupported-but-well-formed tags remain a deliberate
# config lock and are refused by the daemon's compiled locale authority.
$hostStatusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
try { $poolControlLanguage = Resolve-SeedLanguageTag -Config $hostStatusSeed.Config }
catch { Write-Error $_; exit $ExitFailure }

$goArgs = @('--http-addr', "0.0.0.0:$Port", '--repo-dir', $repoRoot, '--pwsh', $pwshExe,
    '--language', $poolControlLanguage)
if ($configurationGitUrl)  { $goArgs += @('--configuration-git-url', $configurationGitUrl) }
if ($AggregatorUrl) { $goArgs += @('--aggregator-url', $AggregatorUrl) }
if ($hostId)        { $goArgs += @('--host-id', $hostId) }
if ($AllowPseudoLocale) { $goArgs += '--allow-pseudo-locale' }

# A stop published while the daemon was building wins: nothing is launched for
# a request that no longer stands (the finally reports the newer one).
if (-not (Test-YurunaServiceOperationCurrent -Context $serviceOp)) { exit $ExitFailure }

# --- REGION: Stop the previous host-side daemon
# A re-run would otherwise launch a second daemon beside the first and record
# only the new pid: the first keeps the port, and no Stop can find it again.
Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
$previousDaemon = Stop-ExtensionServiceHostProcess -Area 'pool-control-service' -Confirm:$false `
    -Deployment (Get-ExtensionServiceDeploymentIdentity -Area 'pool-control-service' -RuntimeDir $runtimeDir)
if ($previousDaemon.LeftRunning) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.service_hostproof_previous_running' -Arguments @{ pid = [string]$previousDaemon.ProcessId; reason = [string]$previousDaemon.Reason })
    exit $ExitFailure
}
if ($PSCmdlet.ShouldProcess($binPath, "launch pool-control-service on :$Port")) {
    $launch = [Diagnostics.ProcessStartInfo]::new($binPath)
    $launch.UseShellExecute = $false
    $launch.CreateNoWindow = $true
    foreach ($argument in $goArgs) { $launch.ArgumentList.Add([string]$argument) }
    $proc = [Diagnostics.Process]::Start($launch)
    Start-Sleep -Seconds 1
    # A daemon that could not bind its port exits at once; recording its pid
    # would advertise a service that is not there.
    if ($proc.HasExited) {
        [void](Remove-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir -Confirm:$false)
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.service_hostproof_exited' -Arguments @{ code = [string]$proc.ExitCode; port = [string]$Port })
        exit $ExitFailure
    }
    $localIp = try { [string](Get-BestHostIp) } catch { $null }
    if ([string]::IsNullOrWhiteSpace($localIp)) { $localIp = '127.0.0.1' }
    $localUrlHost = if ($localIp.Contains(':')) { "[$localIp]" } else { $localIp }
    Import-Module (Join-Path $ModulesDir 'Test.ExtensionService.psm1') -Global -Force
    # The start time lets a later Stop tell this daemon from an unrelated
    # process that inherited its pid.
    $procStartUnixMs = try { [DateTimeOffset]::new($proc.StartTime).ToUnixTimeMilliseconds() } catch { [long]0 }
    [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $runtimeDir `
        -Active $true -BaseUrl "http://${localUrlHost}:$Port" -HostingMode 'host-process' `
        -Extra ([ordered]@{ pid = $proc.Id; port = $Port; processStartUnixMs = $procStartUnixMs }))
    $serviceOpResult = 'confirmed'
    if (Get-Command Write-HostRegistrationRecord -ErrorAction SilentlyContinue) {
        try { Write-HostRegistrationRecord -HostType (Get-HostType) -RepoRoot $repoRoot | Out-Null } catch { Write-Verbose "registration refresh: $($_.Exception.Message)" }
    }
    Write-Verbose "Pool-control service running (pid $($proc.Id)) at http://${localUrlHost}:$Port  (UI: /, /hosts, /pools)."
}
exit $ExitOk
} finally {
    [void](Exit-YurunaServiceOperation -Context $serviceOp -Result $serviceOpResult -Confirm:$false)
}
