<#PSScriptInfo
.VERSION 2026.10.11.1
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

.PARAMETER CacheIp
    Probe this IP instead, bypassing the runner's
    config/env/local resolution order.
.PARAMETER SetHostProxy
    On success, promote to host proxy (Windows:
    user WinINet; macOS: networksetup, needs sudo).
    Wipes any stale WinINet ProxyServer + proxy
    env vars BEFORE writing the new state, so a
    single `-SetHostProxy` run is enough to fix
    a stale-proxy WARN.
.PARAMETER NetworkService
    macOS: override auto-detected network service.
#>

param(
    [string]$CacheIp,
    [switch]$SetHostProxy,
    [string]$NetworkService
)

# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }

Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

# See https://yuruna.link/42010605-0002
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

# --- REGION: Write-Pass
function Write-Pass { param([string]$msg) Write-Output "  [PASS] $msg"; $script:PassCount++ }
# --- REGION: Write-Fail
function Write-Fail { param([string]$msg) Write-Output "  [FAIL] $msg"; $script:FailCount++ }
# --- REGION: Write-Warn
function Write-Warn { param([string]$msg) Write-Output "  [WARN] $msg"; $script:WarnCount++ }

# --- REGION: Resolve the cache IP
# See https://yuruna.link/42010605-0002

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_cd8ce1605493d871')

# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002

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
# See https://yuruna.link/42010605-0002

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
# See https://yuruna.link/42010605-0002
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
# See https://yuruna.link/42010605-0002

if ($SetHostProxy) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a84aa3e0623290e1')
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.HostContract.psm1') -Force
    [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $PSScriptRoot))
    try {
        $removeParams = @{}
        if ($NetworkService) { $removeParams.NetworkService = $NetworkService }
        $null = Remove-HostProxy @removeParams
        $resolvedHost = Format-IpUrlHost $resolvedIp
        $setParams = @{ ProxyUrl = "http://${resolvedHost}:${httpPort}" }
        if ($NetworkService) { $setParams.NetworkService = $NetworkService }
        if (-not (Set-HostProxy @setParams)) { throw 'The host proxy could not be applied.' }
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
