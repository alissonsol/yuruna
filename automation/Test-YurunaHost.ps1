<#PSScriptInfo
.VERSION 0.1
.GUID 42d4e5f6-a7b8-4c90-1d23-4e5f6a7b8c91
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    is what we expect ("yuruna-status-server"). If anything is wrong,
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
    Write-Output '    pwsh test/Start-StatusServer.ps1'
    Write-Output ''
    Write-Output 'Until the rebuild lands, fetch-and-execute.sh will silently fall'
    Write-Output 'back to https://raw.githubusercontent.com/alissonsol/yuruna/... -- i.e.'
    Write-Output 'iteration changes on the host will NOT be visible in this guest.'
}

# --- 1. host.env exists and parses ---
if (-not (Test-Path $HostEnvFile)) {
    Write-Result 'FAIL' "host.env not found at $HostEnvFile"
    Write-Result 'INFO' 'This guest was provisioned BEFORE the yuruna-host injection landed.'
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

# --- 2. /etc/hosts has the yuruna-host entry ---
$hostsFile = '/etc/hosts'
if (Test-Path $hostsFile) {
    $hostsLine = Select-String -Path $hostsFile -Pattern '\byuruna-host\b' -SimpleMatch:$false -ErrorAction SilentlyContinue
    if ($hostsLine) {
        Write-Result 'OK' "/etc/hosts contains yuruna-host: $($hostsLine.Line.Trim())"
    } else {
        Write-Result 'WARN' '/etc/hosts has no yuruna-host entry -- only IP-based URLs will work.'
    }
}

# --- 3. /livecheck probe ---
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

# --- 4. Validate the JSON looks like the yuruna status server ---
# A misdirected probe (someone else's HTTP server on :8080) would 200
# but the body wouldn't match. Distinguish by the `service` field.
try {
    $payload = $response.Content | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Result 'FAIL' "/livecheck returned 200 but body is not JSON: $($response.Content.Substring(0, [Math]::Min(120, $response.Content.Length)))"
    Show-Remediation
    exit 1
}

if ($payload.service -ne 'yuruna-status-server') {
    Write-Result 'FAIL' "/livecheck JSON does not identify as yuruna-status-server (service='$($payload.service)')"
    Show-Remediation
    exit 1
}

Write-Result 'OK' "yuruna-host is reachable. Server time: $($payload.time)"
exit 0
