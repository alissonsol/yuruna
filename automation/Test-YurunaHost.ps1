<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42d4e5f6-a7b8-4c90-1d23-4e5f6a7b8c91
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
    From inside a guest VM, verify whether the yuruna status server on
    the host is reachable.

.DESCRIPTION
    The dev iteration loop relies on each guest knowing the host's IP
    and port for the status server. Those are baked into
    /etc/yuruna/host.env at VM-provision time by New-VM.ps1. On
    Hyper-V Default Switch the host IP changes across host reboots, so
    a guest provisioned today and used tomorrow may have stale
    coordinates and silently fall back to GitHub for every fetch.

    This script runs IN THE GUEST. It reads /etc/yuruna/host.env, hits
    /livecheck on the host, and reports whether the in-guest
    yuruna-host name resolves and whether the JSON the server returns
    is what we expect ("yuruna-status-service"). If anything is wrong,
    the script exits non-zero and prints the documented remediation
    (rebuild the guest VM via host-side New-VM.ps1).

.PARAMETER HostEnvFile
    Path to host.env. Default /etc/yuruna/host.env. Override useful
    for unit-testing the script outside a real guest.

.PARAMETER TimeoutSec
    HTTP timeout for the /livecheck probe. Default 3.

.OUTPUTS
    Exit code 0 on reachable, 1 on any failure. Verbose progress on
    stdout regardless.
#>

param(
    [string]$HostEnvFile = '/etc/yuruna/host.env',
    [int]$TimeoutSec = 3
)

$ErrorActionPreference = 'Continue'

function Write-Result {
    param([string]$Tag, [string]$Message)
    # Tag is one of: OK, WARN, FAIL, INFO. Plain text so the line lands
    # cleanly in `script` transcripts and OCR captures.
    Write-Output "[$Tag] $Message"
}

function Show-Remediation {
    Write-Output ''
    Write-Output '--- Remediation ---'
    Write-Output 'The yuruna-host coordinates baked into this guest are stale or the'
    Write-Output 'host status server is not reachable. The supported fix is to rebuild'
    Write-Output 'the guest VM from the host:'
    Write-Output ''
    Write-Output '  macOS / UTM:'
    Write-Output '    pwsh host/macos.utm/<guest>/New-VM.ps1'
    Write-Output ''
    Write-Output '  Windows / Hyper-V:'
    Write-Output '    pwsh host\windows.hyper-v\<guest>\New-VM.ps1'
    Write-Output ''
    Write-Output 'Make sure the status server is running on the host first:'
    Write-Output '    pwsh test/Start-StatusService.ps1'
    Write-Output ''
    Write-Output 'Until the rebuild lands, fetch-and-execute.sh will silently fall'
    Write-Output 'back to https://raw.githubusercontent.com/alissonsol/yuruna/... -- i.e.'
    Write-Output 'iteration changes on the host will NOT be visible in this guest.'
}

# --- REGION: 1. host.env exists and parses
if (-not (Test-Path $HostEnvFile)) {
    Write-Result 'FAIL' "host.env not found at $HostEnvFile"
    Write-Result 'INFO' 'This guest does not have the yuruna-host configuration.'
    Show-Remediation
    exit 1
}

$envMap = @{}
foreach ($line in (Get-Content $HostEnvFile -ErrorAction Stop)) {
    $entry = $line.Trim()
    if (-not $entry -or $entry.StartsWith('#')) { continue }
    if ($entry -match '^([A-Z_][A-Z0-9_]*)=(.*)$') {
        $envMap[$Matches[1]] = $Matches[2].Trim()
    }
}

$hostIp   = $envMap['YURUNA_HOST_IP']
$hostPort = $envMap['YURUNA_HOST_PORT']

if (-not $hostIp) {
    Write-Result 'FAIL' "YURUNA_HOST_IP missing or empty in $HostEnvFile"
    Show-Remediation
    exit 1
}
if (-not $hostPort) {
    Write-Result 'FAIL' "YURUNA_HOST_PORT missing or empty in $HostEnvFile"
    Show-Remediation
    exit 1
}

Write-Result 'INFO' "host.env: YURUNA_HOST_IP=$hostIp YURUNA_HOST_PORT=$hostPort"

# --- REGION: 2. /etc/hosts maps yuruna-host to YURUNA_HOST_IP
# Parse the mapped IP (first field of the "<ip> <name>..." line) and compare it
# to host.env: a stale mapping resolves the name to the wrong host even though
# IP-based URLs still work. Commented lines are skipped.
$hostsFile = '/etc/hosts'
$hostsNameMapsHostIp = $false
if (Test-Path $hostsFile) {
    $hostsLine = @(Get-Content -LiteralPath $hostsFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -notmatch '^\s*#' -and $_ -match '\byuruna-host\b' }) | Select-Object -First 1
    if ($hostsLine) {
        $mappedIp = ($hostsLine.Trim() -split '\s+')[0]
        if ($mappedIp -eq $hostIp) {
            Write-Result 'OK' "/etc/hosts maps yuruna-host to $mappedIp (matches YURUNA_HOST_IP)."
            $hostsNameMapsHostIp = $true
        } else {
            Write-Result 'WARN' "/etc/hosts maps yuruna-host to $mappedIp but YURUNA_HOST_IP is $hostIp -- stale name->IP mapping; name-based URLs will hit the wrong host."
        }
    } else {
        Write-Result 'WARN' '/etc/hosts has no yuruna-host entry -- only IP-based URLs will work.'
    }
}

# --- REGION: 3. /livecheck probe
$livecheckUrl = "http://${hostIp}:${hostPort}/livecheck"
Write-Result 'INFO' "Probing $livecheckUrl (timeout ${TimeoutSec}s) ..."

$response = $null
try {
    $response = Invoke-WebRequest -Uri $livecheckUrl -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Result 'FAIL' "Probe failed: $($_.Exception.Message)"
    Show-Remediation
    exit 1
}

if ($response.StatusCode -ne 200) {
    Write-Result 'FAIL' "/livecheck returned HTTP $($response.StatusCode)"
    Show-Remediation
    exit 1
}

# --- REGION: 4. Validate the JSON looks like the yuruna status server
# A misdirected probe (someone else's HTTP server on :8080) would 200
# but the body wouldn't match. Distinguish by the `service` field.
try {
    $payload = $response.Content | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Result 'FAIL' "/livecheck returned 200 but body is not JSON: $($response.Content.Substring(0, [Math]::Min(120, $response.Content.Length)))"
    Show-Remediation
    exit 1
}

if ($payload.service -ne 'yuruna-status-service') {
    Write-Result 'FAIL' "/livecheck JSON does not identify as yuruna-status-service (service='$($payload.service)')"
    Show-Remediation
    exit 1
}

# --- REGION: 5. Exercise the name->IP path
# A broken /etc/hosts mapping surfaces here (the IP probe above bypasses name
# resolution). Advisory: the IP path is authoritative, so a name-path problem
# is a WARN, not a failure.
if ($hostsNameMapsHostIp) {
    $nameUrl = "http://yuruna-host:${hostPort}/livecheck"
    try {
        $nameResp = Invoke-WebRequest -Uri $nameUrl -TimeoutSec $TimeoutSec -UseBasicParsing -ErrorAction Stop
        if ($nameResp.StatusCode -eq 200) {
            Write-Result 'OK' "yuruna-host name resolves and $nameUrl is reachable."
        } else {
            Write-Result 'WARN' "$nameUrl returned HTTP $($nameResp.StatusCode) (IP path works; name path degraded)."
        }
    } catch {
        Write-Result 'WARN' "$nameUrl failed ($($_.Exception.Message)); the name->IP path is broken though the IP path works."
    }
}

Write-Result 'OK' "yuruna-host is reachable. Server time: $($payload.time)"
exit 0
