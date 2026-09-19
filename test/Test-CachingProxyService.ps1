<#PSScriptInfo
.VERSION 2026.09.18
.GUID 429d2507-81f3-45bf-89aa-1a0471f4641c
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
    Smoke-tests a caching-proxy-service (local or remote) before Start-TestRunner.
    Probes :3128, :3129, :80, :3000 and GETs /yuruna-squid-ca.crt, PASS/
    FAIL/WARN per check. See the operator reference in docs/caching.md for the full story.
    Resolves the cache in the SAME order Start-TestRunner does at cycle
    start: vmStart.cachingProxyIp (test.config.yml) first, then
    $Env:YURUNA_CACHING_PROXY_SERVICE_IP, then local discovery -- so the IP this
    script probes is the IP the runner will actually pick.

.PARAMETER CacheIp         Probe this IP instead, bypassing the runner's
                           config/env/local resolution order.
.PARAMETER SetHostProxy    On success, promote to host proxy (Windows:
                           user WinINet; macOS: networksetup, needs sudo).
                           Wipes any stale WinINet ProxyServer + proxy
                           env vars BEFORE writing the new state, so a
                           single `-SetHostProxy` run is enough to fix
                           a stale-proxy WARN.
.PARAMETER NetworkService  macOS: override auto-detected network service.
#>

param(
    [string]$CacheIp,
    [switch]$SetHostProxy,
    [string]$NetworkService
)

Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

# Canonical path bundle + CachingProxyService module kind. Loads the trio
# (Test.VMUtility, Test.CachingProxyService, Test.HostContract) shared by the four
# caching-proxy-service scripts:
#   * Test.VMUtility -- Get-CachingProxyServicePort / Test-IpAddress, used by the
#     port-probe block below and the env-var / -CacheIp branches that
#     bypass Test-CachingProxyServiceAvailable's transitive imports.
#   * Test.CachingProxyService -- Invoke-CachingProxyServiceProbe (shared with the cycle-
#     start gate in Invoke-TestRunnerInnerLoop.ps1).
#   * Test.HostContract -- Invoke-LibvirtGroupReExecIfNeeded + Initialize-YurunaHost.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$ModulesDir = $paths.ModulesDir
Initialize-YurunaEntryPointModuleSet -For CachingProxyService -ModulesDir $ModulesDir

# Auto-relaunch under sg libvirt on host.ubuntu.kvm when this shell's
# group set is stale -- the local-discovery branch (no -CacheIp / env
# override) calls into Yuruna.Host which uses virsh to find the cache
# VM's IP. No-op on other hosts / fresh shells / when -CacheIp short-
# circuits the libvirt path.
Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

function Write-Pass { param([string]$msg) Write-Output "  [PASS] $msg"; $script:PassCount++ }
function Write-Fail { param([string]$msg) Write-Output "  [FAIL] $msg"; $script:FailCount++ }
function Write-Warn { param([string]$msg) Write-Output "  [WARN] $msg"; $script:WarnCount++ }

# --- REGION: Resolve the cache IP
# Priority mirrors Start-TestRunner's cycle-start resolution:
#   -CacheIp parameter            (explicit override, this script only)
#   vmStart.cachingProxyIp        (test/test.config.yml, probed first)
#   $Env:YURUNA_CACHING_PROXY_SERVICE_IP  (probed when config absent/unreachable)
#   local discovery via Test-CachingProxyServiceAvailable
# The config/env legs run through Resolve-CachingProxyServiceEndpoint -- the SAME
# resolver Invoke-TestRunnerInnerLoop.ps1 and Debug-TestSequence.ps1 use -- so the
# acceptance policy (first source whose HTTP proxy port answers) cannot
# drift from the runner's. Two differences, both deliberate: this
# diagnostic never publishes the winner into $env:YURUNA_CACHING_PROXY_SERVICE_IP
# (read-only probe, no session mutation), and a rejected source is
# surfaced as a WARN before falling back to local discovery exactly as
# the runner would.

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_cd8ce1605493d871')

# -SetHostProxy ends this script with Remove-HostProxy then Set-HostProxy, both
# of which reach Invoke-MacElevationIfNeeded and prompt for a password -- after
# the port probes and CA fetch have already burned a minute or more. The
# requirement is knowable from the parameter binding alone, so surface it here.
# Idempotent and silent when already root (sudo -E), when the sudo timestamp is
# warm, or on Windows, where Set-HostProxy writes per-user WinINet and needs no
# elevation. A run without -SetHostProxy is a read-only probe and never prompts.
if ($SetHostProxy -and $IsMacOS) {
    [void](Initialize-SudoCache -Reasons @('reset the macOS system HTTP/HTTPS proxy (networksetup)'))
}

$resolvedIp   = $null
$resolvedFrom = $null

if ($CacheIp) {
    if (-not (Test-IpAddress $CacheIp)) {
        Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_7fc4b0d3401fc82b' -Arguments @{ cacheIp = "$CacheIp" })
        exit 1
    }
    $resolvedIp   = $CacheIp
    $resolvedFrom = "-CacheIp parameter"
} else {
    # Same source extraction as Invoke-TestRunnerInnerLoop.ps1: env var
    # trimmed, config key read defensively (file or key may be absent --
    # Read-TestConfig returns $null on a missing/broken file).
    $envCacheIp    = if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP) { $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { '' }
    $configCacheIp = ''
    Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -Force
    $cpConfig = Read-TestConfig -Path (Join-Path $PSScriptRoot 'test.config.yml')
    if ($cpConfig -and $cpConfig.vmStart -is [System.Collections.IDictionary] -and $cpConfig.vmStart.Contains('cachingProxyIp')) {
        $configCacheIp = "$($cpConfig.vmStart.cachingProxyIp)".Trim()
    }
    if ($envCacheIp -or $configCacheIp) {
        $endpoint = Resolve-CachingProxyServiceEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
        foreach ($line in $endpoint.Lines) { Write-Output $line }
        Write-Output ""
        if ($endpoint.EffectiveIp) {
            $resolvedIp   = $endpoint.EffectiveIp
            # Config credit when both sources name the winning IP -- same
            # precedence the resolver applied.
            $resolvedFrom = if ($resolvedIp -eq $configCacheIp) {
                "vmStart.cachingProxyIp (test.config.yml)"
            } else {
                "`$Env:YURUNA_CACHING_PROXY_SERVICE_IP"
            }
        } else {
            Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_a78ad4d51643c788')
        }
    }
    if (-not $resolvedIp) {
        # Local discovery via the Yuruna.Host contract. The host driver knows
        # the per-platform quirks (Hyper-V ARP+KVP, UTM 192.168.64.1 gateway
        # rewrite) -- no point duplicating them here.
        Import-Module (Join-Path $PSScriptRoot 'modules/Test.HostContract.psm1') -Force
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        try {
            [void](Initialize-YurunaHost -RepoRoot $RepoRoot)
        } catch {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_976e93edcdcf9ee9' -Arguments @{ value = "$_" })
            exit 1
        }
        $proxyUrl = Test-CachingProxyServiceAvailable
        if (-not $proxyUrl) {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_dcfd0bcfa41c2f11')
            exit 1
        }
        if ($proxyUrl -match '^http://([0-9.]+):') {
            $resolvedIp   = $matches[1]
            $resolvedFrom = "Test-CachingProxyServiceAvailable ($proxyUrl)"
        } else {
            Write-Fail (Format-YurunaOperatorMessage -Key 'runner.operator_9a3cb55db2a4a2a2' -Arguments @{ proxyUrl = "$proxyUrl" })
            exit 1
        }
    }
}

Write-Output "  Target: $resolvedIp  (source: $resolvedFrom)"
Write-Output ""

# --- REGION: Port probes + CA cert fetch
# Shared with the cycle-start gate in Invoke-TestRunnerInnerLoop.ps1 via
# Invoke-CachingProxyServiceProbe in Test.CachingProxyService.psm1 -- both callers see
# the same PASS/WARN/FAIL classification:
#   :3128 / :3129 / :3000 -- FAIL on unreachable (hard requirements)
#   :80, CA cert          -- WARN (HTTPS caching disabled on guests but
#                            HTTP still works)
# Lines and counters are folded back into this script's $script:* state
# so the Summary line and exit code match the cycle-start gate's
# PASS/WARN/FAIL classification (single source of truth in
# Invoke-CachingProxyServiceProbe).

# Re-import so Invoke-CachingProxyServiceProbe resolves after the local-discovery
# branch above ran Initialize-YurunaHost:
# docs/workarounds.md#nested-non-global-import-evicts-a-callers-view-of-a-module
# No-op for the -CacheIp and env-var branches, which never load the host module.
Import-Module (Join-Path $ModulesDir 'Test.CachingProxyService.psm1') -Global -Force -Verbose:$false
$probe = Invoke-CachingProxyServiceProbe -CacheIp $resolvedIp
foreach ($line in $probe.Lines) { Write-Output $line }
$script:PassCount += $probe.PassCount
$script:WarnCount += $probe.WarnCount
$script:FailCount += $probe.FailCount
$httpPort  = $probe.HttpPort

# --- REGION: Host system-proxy check
# A stale system proxy (e.g. a previous -SetHostProxy promotion
# against an IP that has since moved) will silently redirect every
# Invoke-WebRequest / curl in Start-TestRunner. .NET on macOS reads
# networksetup; .NET on Windows reads WinINet per-user (what the
# driver's Set-WindowsHostProxy writes) and WinHTTP machine-wide. Env vars are
# only consulted as a fallback, which is why a stale system setting
# doesn't show up by dumping env vars alone.

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_72ff9744d8398906')

if ($IsMacOS) {
    try {
        $scText = (& scutil --proxy 2>&1) -join "`n"
        Write-Output "  scutil --proxy:"
        foreach ($line in ($scText -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
    } catch {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4de7942157cfd862' -Arguments @{ message = "$($_.Exception.Message)" })
    }
} elseif ($IsWindows) {
    try {
        $nwText = (& netsh winhttp show proxy 2>&1) -join "`n"
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4ac977c303f1ed0e')
        foreach ($line in ($nwText -split "`n")) { if ($line) { Write-Output ("    " + $line.TrimEnd()) } }
    } catch {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_fff1ea06a82dafb8' -Arguments @{ message = "$($_.Exception.Message)" })
    }
    try {
        $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d168a5486eb59de2')
        Write-Output ("    ProxyEnable   = " + $is.ProxyEnable)
        Write-Output ("    ProxyServer   = " + $is.ProxyServer)
        Write-Output ("    ProxyOverride = " + $is.ProxyOverride)
    } catch {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0d11ff94c7f25814' -Arguments @{ message = "$($_.Exception.Message)" })
    }
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_9c87c921239516dc')
}

# --- REGION: Effective proxy for outbound calls
# Read process env vars DIRECTLY rather than asking
# [System.Net.WebRequest]::DefaultWebProxy.GetProxy(). DefaultWebProxy
# is a per-AppDomain singleton -- HttpEnvironmentProxy gets constructed
# from env vars on the FIRST .NET HTTP call and is then cached for the
# life of the process, with no refresh path. So once Test-CachingProxyService.ps1
# (or any earlier script in the same pwsh) has touched .NET HTTP, the
# singleton is stuck at whatever HTTP_PROXY said at that moment, even
# after Set-WindowsHostProxy updates $env:HTTP_PROXY in the same session.
# That is why two consecutive -SetHostProxy runs in one pwsh kept warning
# despite the underlying state being correct.
#
# Reading env vars directly reflects what NEW child processes will
# inherit (Start-TestRunner spawns fresh pwsh per cycle on Windows;
# child gets the parent's process env block at fork time, builds its
# own DefaultWebProxy from THOSE values). $env: hits the live process
# env block on every read.
$envHttp  = $env:HTTP_PROXY
$envHttps = $env:HTTPS_PROXY
$envNo    = $env:NO_PROXY
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8bb3b2dde85b45eb')
Write-Output ("    HTTP_PROXY    = " + ($(if ($envHttp)  { $envHttp }  else { '(not set)' })))
Write-Output ("    HTTPS_PROXY   = " + ($(if ($envHttps) { $envHttps } else { '(not set)' })))
Write-Output ("    NO_PROXY      = " + ($(if ($envNo)    { $envNo }    else { '(not set)' })))

# Hint: HKCU env (User scope) drives what fresh-from-explorer pwsh sees;
# Process scope drives what children of THIS pwsh see. They diverge when
# the parent shell predates the most recent setx -- informational, no WARN.
if ($IsWindows) {
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY') {
        $procVal = [Environment]::GetEnvironmentVariable($name, 'Process')
        $userVal = [Environment]::GetEnvironmentVariable($name, 'User')
        if (($procVal -or $userVal) -and ($procVal -ne $userVal)) {
            $shown = if ($userVal) { $userVal } else { '(not set)' }
            Write-Output ((Format-YurunaOperatorMessage -Key 'runner.operator_17b7093853e8e1e1' -Arguments @{ name = "$name"; shown = "$shown" }))
        }
    }
}

# HTTPS_PROXY wins for HTTPS targets (cdimage.ubuntu.com is the canonical
# probe URL); fall back to HTTP_PROXY when only that is set.
$effProxy = if ($envHttps) { $envHttps } else { $envHttp }
$effHost = $null; $effPort = $null
if ($effProxy -and $effProxy -match '^https?://([^:/]+):(\d+)/?') {
    $effHost = $matches[1]
    $effPort = [int]$matches[2]
}

if (-not $effHost) {
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_298414de14ec9357')
} elseif ($effHost -eq $resolvedIp -and $effPort -eq $httpPort) {
    Write-Pass (Format-YurunaOperatorMessage -Key 'runner.operator_e14b9d7f8cc09904' -Arguments @{ effHost = "${effHost}"; effPort = "${effPort}" })
} else {
    Write-Warn (Format-YurunaOperatorMessage -Key 'runner.operator_c4a7a6bd503e6bb6' -Arguments @{ effHost = "${effHost}"; effPort = "${effPort}"; resolvedIp = "${resolvedIp}"; httpPort = "${httpPort}" })
    Write-Output ""
    if ($SetHostProxy) {
        # The promotion below wipes process env (Remove-HostProxy) and
        # writes the new yuruna proxy. Single-step recovery: once this
        # run completes the WARN above is cleared.
        Write-Output "==== FIX ===="
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_681ba60a8c0d8255' -Arguments @{ resolvedIp = "${resolvedIp}"; httpPort = "${httpPort}" })
    } else {
        $isElev    = if ($IsMacOS) { 'sudo -E ' } else { '' }
        $promoteCmd= "${isElev}pwsh test/Test-CachingProxyService.ps1 -SetHostProxy"
        Write-Output "==== FIX ===="
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c6e93dc84c9fac48')
        Write-Output "  promotes ${resolvedIp}:${httpPort}:"
        Write-Output "    $promoteCmd"
    }
}

# --- REGION: Summary
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d044061ad149a912' -Arguments @{ passCount = "$script:PassCount"; warnCount = "$script:WarnCount"; failCount = "$script:FailCount" })

if ($script:FailCount -gt 0) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_bc870d8db66eadde')
    exit 1
}

# --- REGION: Optional: promote to machine-wide host proxy
# Only runs when every FAIL-level check passed -- WARN-level (missing :80 /
# missing CA cert) is compatible with a working HTTP proxy, so we don't
# block promotion on it.
#
# Auto-wipe before promotion: Remove-HostProxy unconditionally clears any
# leftover WinINet ProxyServer string and HTTP_PROXY/HTTPS_PROXY/NO_PROXY
# env vars BEFORE Set-HostProxy writes the new ones. The snapshot-and-restore
# alternative preserves whatever proxy state was on the host when the FIRST
# Set-HostProxy ran -- which on a host that had a pre-existing (or older-cycle)
# HTTP_PROXY env var means Stop-CachingProxyServiceVM faithfully restores it,
# leaking a stale IP into every subsequent Test-CachingProxyService probe.
# Wiping first means each promotion lands on a guaranteed-clean baseline;
# Stop-CachingProxyServiceVM similarly wipes definitively rather than restoring.
# No user-action -ClearHostProxy required.

if ($SetHostProxy) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a84aa3e0623290e1')
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
    try {
        $removeParams = @{}
        if ($NetworkService) { $removeParams.NetworkService = $NetworkService }
        Remove-HostProxy @removeParams
        $resolvedHost = Format-IpUrlHost $resolvedIp
        $setParams = @{ ProxyUrl = "http://${resolvedHost}:${httpPort}" }
        if ($NetworkService) { $setParams.NetworkService = $NetworkService }
        Set-HostProxy @setParams
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_56e751c4c8b4a591' -Arguments @{ resolvedHost = "${resolvedHost}"; httpPort = "${httpPort}" })
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_70961e1633f5b455')
    } catch {
        Write-Output ""
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_12e2dd1dd8779580' -Arguments @{ message = "$($_.Exception.Message)" })
        exit 1
    }
}

exit 0
