<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42519b0c-19ed-4527-9de3-a35ad1449acb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching proxy grafana dashboard pool
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
    Push the repo's canonical Yuruna hosts dashboard onto a RUNNING
    caching-proxy service VM, so a dashboard correction lands without a VM
    rebuild.
.DESCRIPTION
    test/extension/pool-aggregator-service/grafana-pool-dashboard.json is the
    canonical dashboard. The proxy VM does not read it: cloud-init carries a
    byte-identical inline copy and writes it once, at build time, to
    /var/lib/grafana/dashboards/pool.json. A correction to the canonical file
    therefore reaches a running proxy only by rebuilding the VM -- which costs
    roughly a quarter hour and takes the cache, the aggregator, Grafana, Loki
    and Prometheus down with it, all to replace one JSON file.

    This runs from the HOST, not from the proxy: the host already holds the
    harness SSH key, while a guest carries only an authorized PUBLIC key. Doing
    it guest-side would mean baking a private key that grants sudo-capable
    access to the proxy into the VM it administers.

    Three things the push has to get right, because the baked copy gets them
    right and a naive `scp` would not:

      * The dashboard ships with the literal AGGREGATOR_BASE_PLACEHOLDER in its
        `aggregator` variable. Cloud-init rewrites it to http://<vm-ip>:9400
        after the VM has an address. The same rewrite runs here, in the guest,
        from the guest's own `hostname -I` -- so the address is the one the VM
        actually has, not one this host guessed.
      * Grafana's file provider re-reads the dashboards directory every 30 s
        (updateIntervalSeconds), so a replaced file is picked up on its own.
        Nothing is restarted: a restart would blank every panel for the length
        of a Grafana start to achieve what a provisioner poll achieves anyway.
      * yuruna-fit-pool-dashboard.timer owns the three per-host panels'
        gridPos.h on the proxy -- it sizes them to the live host count, and the
        canonical file's heights are only pre-collector defaults. An overwrite
        resets them, and the timer would not correct that for up to 5 minutes.
        The fitter is therefore run once, immediately, right after the push.

    Idempotent: the candidate is compared against what the proxy already serves
    with the fitter-owned geometry (the three per-host panels and the row
    panels) taken from the live file, so a proxy that is already current is
    left untouched instead of being rewritten into a re-fit every run.

    Safe to re-run, and non-destructive on failure: the new file is written to
    a temporary path in the dashboards directory and moved into place only
    after it parses as JSON in the guest, so a truncated transfer never
    replaces a working dashboard.
.PARAMETER ProxyAddress
    Proxy host/IP to push to. Omitted, the address is resolved the way the rest
    of the harness resolves it (Resolve-CachingProxyServiceEndpoint over
    vmStart.cachingProxyIp and $env:YURUNA_CACHING_PROXY_SERVICE_IP), falling
    back to the address this host persisted when it provisioned a proxy of its
    own.
.PARAMETER User
    SSH login on the proxy. Defaults to the seed-created service account.
.PARAMETER TimeoutSeconds
    Total budget for the in-guest work.
.EXAMPLE
    pwsh test/Sync-PoolDashboardOnProxy.ps1
    # Resolve the proxy, push the canonical dashboard, re-fit the panels.
.EXAMPLE
    pwsh test/Sync-PoolDashboardOnProxy.ps1 -WhatIf
    # Say which proxy would be written to and what would be sent; change nothing.
.EXAMPLE
    pwsh test/Sync-PoolDashboardOnProxy.ps1 -ProxyAddress 192.168.7.150
    # Skip resolution and push to a known address.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$ProxyAddress,
    [string]$User = 'caching-proxy-service-admin',
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script. After the line above on purpose: an explicit
# level is the operator's choice and replaces this script's own default.
# $InformationPreference is then re-read from the global the cascade writes,
# because the script-scoped assignment above shadows it for the rest of this
# file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

$repoRoot   = $paths.RepoRoot
$ModulesDir = $paths.ModulesDir

# CachingProxyService kind loads Test.VMUtility (Test-IpAddress,
# Get-CachingProxyServicePort, Format-IpUrlHost) + Test.CachingProxyService
# (the probe + state helpers) + Test.HostContract with -Global -Force.
Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $ModulesDir
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Ssh.psm1')    -Global -Force -DisableNameChecking

$DashboardPath = Join-Path $repoRoot 'test/extension/pool-aggregator-service/grafana-pool-dashboard.json'
$GuestPath     = '/var/lib/grafana/dashboards/pool.json'

# --- REGION: read + validate the canonical dashboard
if (-not (Test-Path -LiteralPath $DashboardPath)) {
    Write-Error "The canonical dashboard is missing at $DashboardPath. Nothing to push."
    exit $ExitFailure
}
# Read as bytes and normalize CRLF: the proxy's baked copy comes out of a YAML
# block scalar and is LF-only, so shipping LF keeps the two copies comparable
# byte for byte rather than differing on every line.
$dashboardText = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($DashboardPath)).Replace("`r`n", "`n")
try {
    $null = $dashboardText | ConvertFrom-Json
} catch {
    Write-Error "The canonical dashboard at $DashboardPath is not valid JSON ($($_.Exception.Message)). Refusing to push a file the proxy could not load."
    exit $ExitFailure
}
if ($dashboardText -notmatch 'AGGREGATOR_BASE_PLACEHOLDER') {
    # The placeholder is what the guest rewrites into a working aggregator URL.
    # A file that has already been substituted would pin whatever address it was
    # substituted for, and every /go/* link on the proxy would point there.
    Write-Error "The canonical dashboard carries no AGGREGATOR_BASE_PLACEHOLDER. It looks like an already-substituted copy, which would bake one lab's aggregator address into another's dashboard."
    exit $ExitFailure
}

# gzip before base64: the raw dashboard is ~30 KB, whose base64 is ~40 KB --
# past the Windows command-line ceiling the ssh invocation has to fit inside.
# Compressed it is ~9 KB, which fits with room to spare on every platform.
$plainBytes = [System.Text.Encoding]::UTF8.GetBytes($dashboardText)
$buffer = [System.IO.MemoryStream]::new()
$gzip   = [System.IO.Compression.GZipStream]::new($buffer, [System.IO.Compression.CompressionLevel]::SmallestSize, $true)
try {
    $gzip.Write($plainBytes, 0, $plainBytes.Length)
} finally {
    $gzip.Dispose()
}
$payload = [Convert]::ToBase64String($buffer.ToArray())
$buffer.Dispose()

# --- REGION: resolve the proxy
if ([string]::IsNullOrWhiteSpace($ProxyAddress)) {
    $configIp = ''
    $tcPath = Join-Path $repoRoot 'test/test.config.yml'
    if (Test-Path -LiteralPath $tcPath) {
        try {
            $tc = Read-TestConfig -Path $tcPath
            if ($tc -and $tc.vmStart -is [System.Collections.IDictionary] -and $tc.vmStart.Contains('cachingProxyIp')) {
                $configIp = "$($tc.vmStart.cachingProxyIp)".Trim()
            }
        } catch { Write-Verbose "test.config.yml read: $($_.Exception.Message)" }
    }
    $resolved = Resolve-CachingProxyServiceEndpoint -EnvIp "$($env:YURUNA_CACHING_PROXY_SERVICE_IP)" -ConfigIp $configIp
    foreach ($line in $resolved.Lines) { Write-Information $line -InformationAction Continue }
    $ProxyAddress = [string]$resolved.EffectiveIp
    if ([string]::IsNullOrWhiteSpace($ProxyAddress)) {
        # The operator-facing sources answered nothing. A host that provisioned a
        # proxy of its own still records the address it built, and that is a real
        # claim the shared resolver never consults -- it is deliberately limited
        # to the two keys an operator edits.
        try {
            $state = Read-CachingProxyServiceState
            if ($state -and $state.ipAddress) { $ProxyAddress = ([string]$state.ipAddress).Trim() }
        } catch { Write-Verbose "caching-proxy-service state: $($_.Exception.Message)" }
        if ($ProxyAddress) {
            Write-Information "Using the caching-proxy address this host persisted when it provisioned one: $ProxyAddress" -InformationAction Continue
        }
    }
}
if ([string]::IsNullOrWhiteSpace($ProxyAddress)) {
    Write-Error @"
No caching-proxy service address is known on this host, so there is nothing to push to.
Any one of these gives the script a target:
  * pass it directly:  pwsh test/Sync-PoolDashboardOnProxy.ps1 -ProxyAddress <ip>
  * set vmStart.cachingProxyIp in test/test.config.yml (persistent), or
  * export YURUNA_CACHING_PROXY_SERVICE_IP=<ip> for this session, or
  * build a proxy here with test/Start-CachingProxyServiceVM.ps1.
"@
    exit $ExitFailure
}
# The address lands inside a shell command on the proxy; a quote or whitespace
# in it would break out of that command and run as code.
if ($ProxyAddress -match "['`"\s]") {
    Write-Error "Refusing a proxy address containing quotes or whitespace: '$ProxyAddress'."
    exit $ExitFailure
}

Write-Information '' -InformationAction Continue
Write-Information "== pool dashboard push ==" -InformationAction Continue
Write-Information "  Source: $DashboardPath ($($plainBytes.Length) bytes)" -InformationAction Continue
Write-Information "  Target: ${User}@${ProxyAddress}:$GuestPath" -InformationAction Continue

if (-not $PSCmdlet.ShouldProcess("${User}@${ProxyAddress}", "Replace $GuestPath with the canonical dashboard and re-fit its panels")) {
    Write-Information '' -InformationAction Continue
    Write-Information "WhatIf: nothing was sent. A real run would:" -InformationAction Continue
    Write-Information "  1. copy the canonical dashboard into the guest ($($payload.Length) base64 chars, gzip-compressed)," -InformationAction Continue
    Write-Information "  2. rewrite AGGREGATOR_BASE_PLACEHOLDER to http://<the VM's own IP>:9400, exactly as cloud-init does," -InformationAction Continue
    Write-Information "  3. skip the write entirely if the proxy already serves this dashboard," -InformationAction Continue
    Write-Information "  4. otherwise move it over $GuestPath after it parses as JSON in the guest, and" -InformationAction Continue
    Write-Information "  5. run yuruna-fit-pool-dashboard.service once so the per-host panel heights are right immediately." -InformationAction Continue
    Write-Information "  Grafana is never restarted: its file provider re-reads that directory every 30 s." -InformationAction Continue
    exit $ExitOk
}

# --- REGION: push
# Single-quoted here-string: every $ below is a SHELL variable and PowerShell
# must not touch it. The payload is injected by literal replace.
$script = @'
set -u
DASH=/var/lib/grafana/dashboards/pool.json
DIR=$(dirname "$DASH")
if [ ! -d "$DIR" ]; then
  if command -v grafana-server >/dev/null 2>&1; then
    echo "FAILED: grafana is installed but $DIR does not exist; this proxy has no provisioned dashboard directory" >&2
  else
    echo "FAILED: grafana is not installed on this host, so there is no dashboard to replace" >&2
  fi
  exit 3
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAILED: python3 is missing, so the pushed dashboard cannot be validated before it replaces a working one" >&2
  exit 4
fi
WORK=$(mktemp -d) || exit 5
trap 'rm -rf "$WORK"' EXIT
printf '%s' '__PAYLOAD__' | base64 -d 2>/dev/null | gunzip > "$WORK/cand.json" 2>/dev/null
if [ ! -s "$WORK/cand.json" ]; then
  echo "FAILED: the transferred dashboard did not decode (empty after base64+gunzip)" >&2
  exit 6
fi
# The same rewrite cloud-init performs, from the guest's own address: the
# dashboard's /go/* links and its aggregator variable resolve through it.
AGG_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$AGG_IP" ] || AGG_IP=127.0.0.1
sed -i "s#AGGREGATOR_BASE_PLACEHOLDER#http://${AGG_IP}:9400#g" "$WORK/cand.json"
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/cand.json" 2>/dev/null; then
  echo "FAILED: the transferred dashboard is not valid JSON after the aggregator rewrite; $DASH untouched" >&2
  exit 7
fi
# Already current? Compare against what is served, with the geometry the fitter
# owns taken from the live file -- otherwise every run would look like a change
# and rewrite a dashboard whose panels are correctly sized.
python3 - "$WORK/cand.json" "$DASH" <<'PY'
import json, sys

FITTED = {6, 7, 17}   # the per-host panels yuruna-fit-pool-dashboard.py sizes

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        cand = json.load(fh)
    with open(sys.argv[2], encoding="utf-8") as fh:
        live = json.load(fh)
except (OSError, ValueError):
    sys.exit(1)   # nothing comparable in place: push

live_panels = {p.get("id"): p for p in live.get("panels", [])}
for panel in cand.get("panels", []):
    pid = panel.get("id")
    if pid in live_panels and (pid in FITTED or panel.get("type") == "row"):
        panel["gridPos"] = live_panels[pid].get("gridPos", panel.get("gridPos"))
sys.exit(0 if cand == live else 1)
PY
if [ $? -eq 0 ]; then
  echo "UNCHANGED: $DASH already serves this dashboard"
  exit 0
fi
# Stage inside the dashboards directory so the move is a same-filesystem rename:
# Grafana's provisioner never sees a partially written file.
STAGE="$DIR/.pool.json.push"
sudo cp "$WORK/cand.json" "$STAGE" || { echo "FAILED: could not stage the new dashboard in $DIR" >&2; exit 8; }
sudo chown root:root "$STAGE" 2>/dev/null || true
sudo chmod 0644 "$STAGE"
sudo mv -f "$STAGE" "$DASH" || { echo "FAILED: could not move the new dashboard over $DASH" >&2; sudo rm -f "$STAGE"; exit 9; }
echo "PUSHED: $DASH replaced (aggregator http://${AGG_IP}:9400)"
# Panel heights: the canonical file carries pre-collector defaults, so run the
# fitter now rather than leaving the panels wrong-sized until its timer fires.
if systemctl cat yuruna-fit-pool-dashboard.service >/dev/null 2>&1; then
  if sudo systemctl start yuruna-fit-pool-dashboard.service >/dev/null 2>&1; then
    echo "FITTED: per-host panel heights recomputed for the live host count"
  else
    echo "FIT-SKIPPED: yuruna-fit-pool-dashboard.service did not run cleanly; the timer refits within 5 minutes" >&2
  fi
else
  echo "FIT-ABSENT: this proxy has no yuruna-fit-pool-dashboard.service, so panel heights stay at the file's defaults"
fi
# Verify what is actually on disk now, not what was sent.
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DASH" 2>/dev/null; then
  echo "FAILED: $DASH is not valid JSON after the push" >&2
  exit 10
fi
if grep -q 'AGGREGATOR_BASE_PLACEHOLDER' "$DASH"; then
  echo "FAILED: $DASH still carries AGGREGATOR_BASE_PLACEHOLDER; its links would not resolve" >&2
  exit 11
fi
if grep -q 'Download-agent service' "$DASH" && grep -q 'Open extension service UI' "$DASH"; then
  echo "LABELS-OK: the Extension column maps download-agent-service and the hover link reads 'Open extension service UI'"
else
  echo "LABELS-MISSING: the pushed dashboard does not carry the corrected Extension labels" >&2
fi
exit 0
'@.Replace('__PAYLOAD__', $payload)

$result = $null
try {
    $result = Invoke-GuestSsh -VMName $ProxyAddress -GuestKey 'guest.caching-proxy-service' -User $User -Command $script -TimeoutSeconds $TimeoutSeconds
} catch {
    Write-Error @"
SSH to ${User}@${ProxyAddress} failed: $($_.Exception.Message)
The push needs the harness SSH key to reach the proxy. Check that the VM is running and
that this host is the one that built it (a proxy built elsewhere authorized that host's key).
"@
    exit $ExitFailure
}
$output = if ($result) { [string]$result.output } else { '' }
foreach ($line in ($output -split "`r?`n")) {
    if ($line) { Write-Information "  $line" -InformationAction Continue }
}

if (-not $result -or -not $result.success) {
    if ($result -and $result.exitCode -eq -1) {
        Write-Error "No answer from ${User}@${ProxyAddress} within ${TimeoutSeconds}s. The VM may be down, or unreachable from this host; nothing on the proxy was changed."
    } else {
        Write-Error "The dashboard push to ${User}@${ProxyAddress} failed (ssh exit $($result.exitCode)). The proxy still serves the dashboard it had; the message above says why."
    }
    exit $ExitFailure
}

Write-Information '' -InformationAction Continue
if ($output -match 'UNCHANGED:') {
    Write-Information "The proxy at $ProxyAddress already serves the canonical dashboard. Nothing was written." -InformationAction Continue
    exit $ExitOk
}
if ($output -match 'LABELS-OK:') {
    Write-Information "The proxy at $ProxyAddress now serves the canonical dashboard, and the Extension column will render 'Download-agent service' with the 'Open extension service UI' hover link." -InformationAction Continue
} else {
    Write-Warning "The dashboard was replaced on $ProxyAddress, but the corrected Extension labels were not found in the file that landed. Compare it against $DashboardPath before trusting the panel."
}
if ($output -notmatch 'FITTED:') {
    Write-Information "Per-host panel heights are the file's defaults until yuruna-fit-pool-dashboard.timer runs (within 5 minutes)." -InformationAction Continue
}
Write-Information "Grafana's file provider re-reads the dashboards directory every 30 s, so reload the browser tab after about half a minute." -InformationAction Continue
exit $ExitOk

# Copyright (c) 2019-2026 by Alisson Sol et al.
