<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42838215-f18d-437d-93b0-d343742cd5d5
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
    From inside a guest VM, verify whether the yuruna status service on
    the host is reachable.

.DESCRIPTION
    The dev iteration loop relies on each guest knowing the host's IP
    and port for the status service. Those are baked into
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

.PARAMETER TimeoutSeconds
    HTTP timeout for the /livecheck probe. Default 3.

.OUTPUTS
    Exit code 0 on reachable, 1 on any failure. Verbose progress on
    stdout regardless.
#>

param(
    [string]$HostEnvFile = '/etc/yuruna/host.env',
    [int]$TimeoutSeconds = 3
)

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
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
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_9becc4a51e2efe4f')
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_74cd64678d9ced5d')
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_b4b7d067da09b239')
    Write-Output ''
    Write-Output '  macOS / UTM:'
    Write-Output '    pwsh host/macos.utm/<guest>/New-VM.ps1'
    Write-Output ''
    Write-Output '  Windows / Hyper-V:'
    Write-Output '    pwsh host\windows.hyper-v\<guest>\New-VM.ps1'
    Write-Output ''
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_657d36ac7fd4580a')
    Write-Output '    pwsh test/service/Start-StatusService.ps1'
    Write-Output ''
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_2dfbf02a6050f367')
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_93f5be3ae63d7cac')
    Write-Output (Format-YurunaOperatorMessage -Key 'automation.operator_57118242879db9a9')
}

# --- REGION: 1. host.env exists and parses
if (-not (Test-Path $HostEnvFile)) {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_4f68be4909fd3297' -Arguments @{ hostEnvFile = "$HostEnvFile" })
    Write-Result 'INFO' (Format-YurunaOperatorMessage -Key 'automation.operator_92cf51282b025cb1')
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

$hostIp   = $envMap['YURUNA_STATUS_SERVICE_IP']
$hostPort = $envMap['YURUNA_STATUS_SERVICE_PORT']

if (-not $hostIp) {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_3a9c0f6767b77dc5' -Arguments @{ hostEnvFile = "$HostEnvFile" })
    Show-Remediation
    exit 1
}
if (-not $hostPort) {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_83e94a134a825b6e' -Arguments @{ hostEnvFile = "$HostEnvFile" })
    Show-Remediation
    exit 1
}

Write-Result 'INFO' (Format-YurunaOperatorMessage -Key 'automation.operator_3afa1715b4f04e1b' -Arguments @{ hostIp = "$hostIp"; hostPort = "$hostPort" })

# --- REGION: 2. /etc/hosts maps yuruna-host to YURUNA_STATUS_SERVICE_IP
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
            Write-Result 'OK' (Format-YurunaOperatorMessage -Key 'automation.operator_80503e4a3d349cc5' -Arguments @{ mappedIp = "$mappedIp" })
            $hostsNameMapsHostIp = $true
        } else {
            Write-Result 'WARN' (Format-YurunaOperatorMessage -Key 'automation.operator_545f599c8329b23f' -Arguments @{ mappedIp = "$mappedIp"; hostIp = "$hostIp" })
        }
    } else {
        Write-Result 'WARN' (Format-YurunaOperatorMessage -Key 'automation.operator_63e3af676d098fb9')
    }
}

# --- REGION: 3. /livecheck probe
$livecheckUrl = "http://${hostIp}:${hostPort}/livecheck"
Write-Result 'INFO' "Probing $livecheckUrl (timeout ${TimeoutSeconds}s) ..."

$response = $null
try {
    $response = Invoke-WebRequest -Uri $livecheckUrl -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
} catch {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_08adaa87a2f693da' -Arguments @{ message = "$($_.Exception.Message)" })
    Show-Remediation
    exit 1
}

if ($response.StatusCode -ne 200) {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_dcdd159b73d02608' -Arguments @{ statusCode = "$($response.StatusCode)" })
    Show-Remediation
    exit 1
}

# --- REGION: 4. Validate the JSON looks like the yuruna status service
# A misdirected probe (someone else's HTTP server on :8080) would 200
# but the body wouldn't match. Distinguish by the `service` field.
try {
    $payload = $response.Content | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_d58761741eae9025' -Arguments @{ length = "$($response.Content.Substring(0, [Math]::Min(120, $response.Content.Length)))" })
    Show-Remediation
    exit 1
}

if ($payload.service -ne 'yuruna-status-service') {
    Write-Result 'FAIL' (Format-YurunaOperatorMessage -Key 'automation.operator_55a6da533049c54d' -Arguments @{ service = "$($payload.service)" })
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
        $nameResp = Invoke-WebRequest -Uri $nameUrl -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        if ($nameResp.StatusCode -eq 200) {
            Write-Result 'OK' (Format-YurunaOperatorMessage -Key 'automation.operator_fbfc5171f0719513' -Arguments @{ nameUrl = "$nameUrl" })
        } else {
            Write-Result 'WARN' (Format-YurunaOperatorMessage -Key 'automation.operator_a379553e78e3f321' -Arguments @{ nameUrl = "$nameUrl"; statusCode = "$($nameResp.StatusCode)" })
        }
    } catch {
        Write-Result 'WARN' (Format-YurunaOperatorMessage -Key 'automation.operator_659703929bd102c5' -Arguments @{ nameUrl = "$nameUrl"; message = "$($_.Exception.Message)" })
    }
}

Write-Result 'OK' (Format-YurunaOperatorMessage -Key 'automation.operator_6335eb75973bfc19' -Arguments @{ time = "$($payload.time)" })
exit 0
