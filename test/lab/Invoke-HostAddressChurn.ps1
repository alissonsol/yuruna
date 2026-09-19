<#PSScriptInfo
.VERSION 2026.09.18
.GUID 425762d1-bc4e-40e3-b368-b17d66f8461a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test network churn canary
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
    Force this host's bridge to take a fresh DHCP lease on an interval, so a
    cycle can be shown to survive a known number of address changes.

.DESCRIPTION
    A canary host proves nothing on a quiet network. Waiting for the site
    router to renumber the host makes the evidence a matter of luck: the lease
    is what it is, the changes fall where they fall, and a green cycle may
    simply have run through a calm half hour. This drives the renumbering
    instead, so "the cycle passed through N address changes" is a statement
    about the harness rather than about the router's mood.

    Each tick asks NetworkManager to re-run DHCP on the bridge. Whether the
    address actually changes is still the server's decision -- this cannot
    manufacture a new address, only a new lease negotiation -- so the script
    reports what it observed rather than what it intended, and a server that
    hands back the same address produces an honest "no change" line rather than
    a silent success.

    --- REGION: https://yuruna.link/4220a755-0048

.PARAMETER IntervalSeconds
    Seconds between renewals. The default puts three or more changes inside a
    typical ~50-minute AmisAd cycle without sitting on top of the cycle's own
    boot windows.

.PARAMETER Count
    How many renewals to force before exiting. 0 runs until stopped, which is
    what a sidecar for the whole cycle wants.

.PARAMETER BridgeName
    The bridge to renew. Defaults to the yuruna bridge.

.PARAMETER RuntimeDir
    Where to write the injector's own log. Defaults to test/status/runtime.

.EXAMPLE
    pwsh test/lab/Invoke-HostAddressChurn.ps1 -WhatIf
    Show what would be renewed, and confirm the privilege check passes, without
    touching the network.

.EXAMPLE
    pwsh test/lab/Invoke-HostAddressChurn.ps1 -IntervalSeconds 900 -Count 3
    Force three renewals fifteen minutes apart, then exit.

.NOTES
    Bringing a connection up is a privileged operation. Where polkit does not
    already permit it for the operator, grant it once rather than running the
    whole harness elevated -- the runner is deliberately not root, and this
    script is designed to be the only part that needs the right.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(60, 3600)][int]$IntervalSeconds = 780,
    [ValidateRange(0, 1000)][int]$Count = 0,
    [string]$BridgeName = 'yuruna-br0',
    [string]$RuntimeDir = ''
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_35395d2bfd4fe058')
    exit 1
}
if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_982ebcf70e8a5981')
    exit 1
}

if (-not $RuntimeDir) {
    $RuntimeDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'status' -AdditionalChildPath 'runtime'
}
if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
}
$logPath = Join-Path $RuntimeDir 'hostaddress.churn.log'

function Write-ChurnLine {
    param([Parameter(Mandatory)][string]$Message)
    $stamped = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"), $Message
    Write-Information $stamped -InformationAction Continue
    try { [System.IO.File]::AppendAllText($logPath, "$stamped`n") } catch { Write-Verbose "churn log: $($_.Exception.Message)" }
}

function Get-BridgeAddress {
    param([Parameter(Mandatory)][string]$Device)
    $line = & nmcli -g IP4.ADDRESS device show $Device 2>$null | Select-Object -First 1
    if (-not $line) { return '' }
    return ([string]$line).Split('/')[0].Trim()
}

$before = Get-BridgeAddress -Device $BridgeName
if (-not $before) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_6429336f3cab2361' -Arguments @{ bridgeName = "$BridgeName" })
    exit 1
}
Write-ChurnLine "churn injector: bridge '$BridgeName' currently at $before; interval ${IntervalSeconds}s; count $(if ($Count -eq 0) { 'unbounded' } else { $Count })"

# --- REGION: https://yuruna.link/4220a755-0049
# Probe the privilege NOW rather than discovering it is missing at the first
# tick. A sidecar that starts cleanly and then silently fails to renew for the
# whole cycle is worse than one that refuses to start: the cycle would pass and
# be recorded as evidence of surviving churn that never happened.
$probe = & nmcli -t connection show $BridgeName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c99a6c2b38ea775d' -Arguments @{ bridgeName = "$BridgeName"; probe = "$probe" })
    exit 1
}
# Activating a connection is privileged. The runner is deliberately not root,
# so this asks through sudo and expects a rule narrow enough to grant exactly
# this one command -- see test/lab/yuruna-churn.sudoers. -n so a missing rule
# fails here, loudly, instead of blocking on a password prompt nobody is
# present to answer.
& sudo -n nmcli --version *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Error ((Format-YurunaOperatorMessage -Key 'runner.operator_7e8f2822a7e563d4'))
    exit 1
}

if (-not $PSCmdlet.ShouldProcess($BridgeName, (Format-YurunaOperatorMessage -Key 'runner.operator_93931ea4b90643f7' -Arguments @{ intervalSeconds = "${IntervalSeconds}" }))) {
    Write-ChurnLine "churn injector: -WhatIf; would renew '$BridgeName' every ${IntervalSeconds}s. Privilege probe passed."
    return
}

$tick = 0
$changes = 0
while ($Count -eq 0 -or $tick -lt $Count) {
    Start-Sleep -Seconds $IntervalSeconds
    $tick++
    $pre = Get-BridgeAddress -Device $BridgeName
    # `connection up` re-runs the DHCP client on the profile. It is the least
    # disruptive of the options that actually produce a DISCOVER: taking the
    # connection down first would drop the bridge out from under every running
    # guest, which is a harsher event than the renumber this is meant to model.
    $out = & sudo -n nmcli connection up $BridgeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-ChurnLine "churn injector: tick $tick FAILED to renew '$BridgeName' -- $out"
        Write-ChurnLine "churn injector: the operator running this needs permission to activate the connection; without it no churn is being injected and a passing cycle is NOT evidence."
        continue
    }
    Start-Sleep -Seconds 5
    $post = Get-BridgeAddress -Device $BridgeName
    if ($post -and $post -ne $pre) {
        $changes++
        Write-ChurnLine "churn injector: tick $tick renewed '$BridgeName' $pre -> $post (change $changes)"
    } else {
        # Reported, not retried. The server returning the same address is a
        # legitimate outcome and one the harness should survive too; quietly
        # hammering until the address moves would misrepresent how much churn
        # the cycle actually saw.
        Write-ChurnLine "churn injector: tick $tick renewed '$BridgeName' but the server returned the same address ($post); no change injected."
    }
}
Write-ChurnLine "churn injector: finished after $tick tick(s); $changes address change(s) injected."
