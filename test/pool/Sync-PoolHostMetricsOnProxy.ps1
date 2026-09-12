<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42208271-79d6-4f13-84cb-51fe46e67ef4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool prometheus metrics sync
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Update the host-metric filter on a running proxy without rebuilding its services.
.DESCRIPTION
    Preserves every other Prometheus setting. Validates the candidate with promtool,
    replaces it atomically, sends SIGHUP, and verifies reload metrics. An unsuccessful
    reload restores and reloads the previous configuration. Requires the harness SSH
    key and noninteractive sudo on the proxy. See https://yuruna.link/429f3d06-0046.
.PARAMETER ProxyAddress
    Proxy address; defaults to the configured or persisted caching-proxy endpoint.
.PARAMETER User
    Proxy SSH user.
.PARAMETER TimeoutSeconds
    Total remote-operation budget, including rollback.
.EXAMPLE
    pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1 -WhatIf
.EXAMPLE
    pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1 -ProxyAddress 192.168.7.150
#>
[CmdletBinding(SupportsShouldProcess)]
param([string]$ProxyAddress, [string]$User = 'caching-proxy-service-admin', [ValidateRange(120,600)][int]$TimeoutSeconds = 180)
$ErrorActionPreference = 'Stop'
$modules = Join-Path $PSScriptRoot '../modules'
$callerWhatIf = $WhatIfPreference
try {
    # Registry initialization changes only process state; it must run during preview.
    $WhatIfPreference = $false
    Import-Module (Join-Path $modules 'Test.Prelude.psm1') -Force
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
    Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $paths.ModulesDir
    Import-Module (Join-Path $modules 'Test.Config.psm1') -Force
    Import-Module (Join-Path $modules 'Test.Ssh.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $modules 'Test.HostMetricsExporter.psm1') -Force
} finally { $WhatIfPreference = $callerWhatIf }

# --- REGION: Resolve the proxy address
if (-not $ProxyAddress) {
    $configIp = ''
    $configPath = Join-Path $PSScriptRoot '../test.config.yml'
    if (Test-Path -LiteralPath $configPath) {
        $config = Read-TestConfig -Path $configPath
        if ($config.vmStart) { $configIp = [string]$config.vmStart.cachingProxyIp }
    }
    $endpoint = Resolve-CachingProxyServiceEndpoint -ConfigIp $configIp -EnvIp "$env:YURUNA_CACHING_PROXY_SERVICE_IP"
    $ProxyAddress = [string]$endpoint.EffectiveIp
    if (-not $ProxyAddress) { $ProxyAddress = [string](Read-CachingProxyServiceState).ipAddress }
}
if (-not $ProxyAddress -or $ProxyAddress -match "['`"\s]") { throw 'A proxy address without whitespace or quotes is required.' }

# --- REGION: Validate the source
$helper = Join-Path $PSScriptRoot 'sync_host_metrics.py'
if (-not (Test-Path -LiteralPath $helper)) { throw "Missing synchronization helper: $helper" }
$payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($helper))
$retention = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-YurunaHostMetricsRetentionRegex)))
if (-not $PSCmdlet.ShouldProcess("${User}@${ProxyAddress}", 'Validate, atomically update and reload the pool-host Prometheus metric filter')) { return }

# --- REGION: Apply and verify
$command = @'
set -eu
command -v python3 >/dev/null
command -v promtool >/dev/null
sudo -n true
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf '%s' '__PAYLOAD__' | base64 -d > "$WORK/sync.py"
sudo -n python3 "$WORK/sync.py" '__RETENTION__'
'@.Replace('__PAYLOAD__', $payload).Replace('__RETENTION__', $retention)
$result = Invoke-GuestSsh -VMName $ProxyAddress -GuestKey 'guest.caching-proxy-service' -User $User -Command $command -TimeoutSeconds $TimeoutSeconds
if ($result.output) { Write-Output $result.output }
if (-not $result.success) { throw "Host-metric sync did not complete (SSH exit $($result.exitCode)); inspect its rollback result before retrying." }
