<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc01234567a0
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
#>

#requires -version 7

<#
.SYNOPSIS
    Promote the yuruna squid caching proxy to a machine-wide host proxy, and
    restore the previous state on teardown.

.DESCRIPTION
    Thin cross-platform wrapper around the OS-native proxy settings so that
    `Test-CachingProxy.ps1 -SetHostProxy` can, after a successful probe,
    point everything on the host at the squid cache -- not just the yuruna
    harness. That covers:

      * Invoke-WebRequest (honors HKCU WinINet on Windows PS 7)
      * curl / wget / git / qemu-img (honor HTTP_PROXY / HTTPS_PROXY env vars)
      * Edge / Chrome / Store apps (honor HKCU WinINet / networksetup)

    Design note -- "safer" semantics: Set-HostProxy snapshots the previous
    proxy state to $HOME/.yuruna/host-proxy.backup.json BEFORE writing any
    new values; Clear-HostProxy restores from that snapshot. If the user
    already had an unrelated proxy configured (corp VPN, Burp, etc.), Stop-
    CachingProxy.ps1 won't silently wipe it.

    Scope: user-scope only.
      * Windows: HKCU WinINet + user HKCU\Environment (setx). No admin
        needed. Admin-only machine scope is intentionally NOT supported --
        yuruna's caching proxy is a developer convenience, not an
        infrastructure change.
      * macOS: networksetup against the auto-detected active network
        service. Write calls require root. When invoked as a regular user,
        Set-HostProxy and Clear-HostProxy cache credentials once via
        `sudo -v` and then issue each networksetup mutation as
        `sudo networksetup ...`, so the caller does not need to re-exec
        the entire script under sudo.

    Idempotent: calling Set-HostProxy twice does not re-capture the backup
    (the existing snapshot is preserved, so a double-apply followed by
    Clear-HostProxy still restores the ORIGINAL state, not the squid one).

    Yuruna-managed marker: alongside the proxy state, Set-HostProxy writes
    a sentinel (HKCU\Internet Settings\YurunaProxyManaged on Windows;
    $HOME/.yuruna/host-proxy.managed file on macOS). When the backup file
    is missing -- e.g. it was lost between sessions -- the next Set-HostProxy
    detects the marker and synthesizes a CLEAN snapshot rather than capturing
    the leftover yuruna proxy as the user's "original." Without this guard,
    Stop-CachingProxy + Test-CachingProxy -SetHostProxy would loop, each
    Stop restoring the contaminated snapshot.

.EXAMPLE
    # After Test-CachingProxy.ps1 -SetHostProxy succeeds
    Import-Module ./test/modules/Test.HostProxy.psm1 -Force
    Set-HostProxy -Url 'http://192.168.1.50:3128'

.EXAMPLE
    # Symmetric teardown (called automatically by Stop-CachingProxy.ps1)
    Import-Module ./test/modules/Test.HostProxy.psm1 -Force
    Clear-HostProxy
#>

$ErrorActionPreference = 'Stop'

# ---- Backup location ------------------------------------------------------
# $HOME/.yuruna/ is a yuruna-owned state dir outside the repo. The single
# backup file contains the previous proxy state as a JSON blob and is the
# source of truth for Clear-HostProxy's restore. Its existence is also the
# "are we currently promoted?" flag -- Clear-HostProxy with no backup file
# just no-ops the restore step and still performs an unconditional disable
# (so a partial prior run can still be cleaned up).

function Get-HostProxyBackupPath {
    <#
    .SYNOPSIS
        Return the absolute path of the host-proxy backup JSON file, creating
        its parent state directory if it doesn't already exist.
    .DESCRIPTION
        $HOME/.yuruna/host-proxy.backup.json is the source of truth for
        Clear-HostProxy's restore; its mere existence is also the "are we
        currently promoted?" flag used by Stop-CachingProxy.ps1 to decide
        whether to hard-fail without sudo on macOS.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $stateDir = Join-Path $HOME '.yuruna'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    return (Join-Path $stateDir 'host-proxy.backup.json')
}

# ---- URL parsing ----------------------------------------------------------
# Accept http://host:port or http://host:port/ ; extract host + port for
# callers that need them separately (WinINet ProxyServer takes "host:port",
# macOS networksetup takes server + port as separate args).

function ConvertTo-ProxyHostPort {
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -notmatch '^https?://([^:/]+):(\d+)/?$') {
        throw "Set-HostProxy -Url '$Url' is not a valid http://host:port URL."
    }
    return @{
        Host = $matches[1]
        Port = [int]$matches[2]
        HostPort = "$($matches[1]):$($matches[2])"
        Url = "http://$($matches[1]):$($matches[2])/"
    }
}

# =========================================================================
# Windows implementation
# =========================================================================
# WinINet (HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings)
#   ProxyEnable   DWORD  0|1
#   ProxyServer   REG_SZ "host:port" (or scheme=host:port;scheme=host:port)
#   ProxyOverride REG_SZ semicolon-separated bypass list. "<local>" is a
#                        WinINet-specific token that bypasses plain hostnames.
# HKCU\Environment
#   HTTP_PROXY    REG_SZ http://host:port/
#   HTTPS_PROXY   REG_SZ http://host:port/
#   NO_PROXY      REG_SZ comma-separated bypass list
#
# After writing HKCU\Environment, Windows broadcasts WM_SETTINGCHANGE; we
# don't bother calling SendMessageTimeout ourselves because setx already
# does. We DO need to nudge WinINet via InternetSetOption so already-running
# apps (Edge, Invoke-WebRequest) pick up the new HKCU settings without a
# session restart.

$script:WinInetRegPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:WinInetRegPathRaw = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# Marker that Set-WindowsHostProxy writes alongside ProxyEnable/ProxyServer to
# flag "this proxy state was set by yuruna." Read-WindowsProxyState uses it so
# a re-promotion across a lost backup file doesn't capture the prior yuruna IP
# as if it were the user's original setting -- which previously turned every
# Stop-CachingProxy / Test-CachingProxy -SetHostProxy cycle into a self-loop
# (Stop restored the contaminated snapshot, the next probe re-warned).
$script:WinInetMarkerName = 'YurunaProxyManaged'
$script:EnvMarkerName     = 'YURUNA_PROXY_MANAGED'

function Test-WindowsProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        try {
            $val = Get-ItemPropertyValue -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction Stop
            if ([int]$val -eq 1) { return $true }
        } catch {
            Write-Verbose "WinINet marker not present: $($_.Exception.Message)"
        }
    }
    $envMarker = [Environment]::GetEnvironmentVariable($script:EnvMarkerName, 'User')
    return ($envMarker -eq '1')
}

function Read-WindowsProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (Test-WindowsProxyIsYurunaManaged) {
        # Current state is a leftover yuruna promotion (from a cycle whose
        # backup file was deleted or never written). Capturing it as the
        # "original" would re-stamp the stale value back on Clear-HostProxy.
        # Synthesize a clean (no-proxy) snapshot instead.
        return @{
            platform            = 'windows'
            winInet             = @{ ProxyEnable = 0; ProxyServer = $null; ProxyOverride = $null }
            envVars             = @{ HTTP_PROXY  = $null; HTTPS_PROXY = $null; NO_PROXY = $null }
            yurunaResetSnapshot = $true
        }
    }
    $wi = @{ ProxyEnable = 0; ProxyServer = $null; ProxyOverride = $null }
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        $props = Get-ItemProperty -LiteralPath $script:WinInetRegPath -ErrorAction SilentlyContinue
        if ($props) {
            if ($null -ne $props.ProxyEnable)   { $wi.ProxyEnable   = [int]$props.ProxyEnable }
            if ($null -ne $props.ProxyServer)   { $wi.ProxyServer   = [string]$props.ProxyServer }
            if ($null -ne $props.ProxyOverride) { $wi.ProxyOverride = [string]$props.ProxyOverride }
        }
    }
    $env = @{
        HTTP_PROXY  = [Environment]::GetEnvironmentVariable('HTTP_PROXY',  'User')
        HTTPS_PROXY = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'User')
        NO_PROXY    = [Environment]::GetEnvironmentVariable('NO_PROXY',    'User')
    }
    return @{ platform = 'windows'; winInet = $wi; envVars = $env }
}

function Invoke-WinInetRefresh {
    # Broadcast "settings changed" + "refresh" so already-running WinINet
    # clients reload ProxyEnable/ProxyServer without the user having to
    # sign out. IntPtr.Zero for hInternet means "every process" at the
    # OS level. Add-Type is idempotent via -PassThru + a unique type name.
    $sig = @'
using System;
using System.Runtime.InteropServices;
public static class YurunaWinInet {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
}
'@
    if (-not ('YurunaWinInet' -as [type])) {
        Add-Type -TypeDefinition $sig -Language CSharp | Out-Null
    }
    # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Set-WindowsHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][hashtable]$ProxyParts   # from ConvertTo-ProxyHostPort
    )
    $hostPort   = $ProxyParts.HostPort
    $proxyUrl   = $ProxyParts.Url
    $bypassWi   = 'localhost;127.0.0.1;<local>'
    $bypassEnv  = 'localhost,127.0.0.1,::1'

    if (-not $PSCmdlet.ShouldProcess("HKCU WinINet + HKCU\Environment", "Set host proxy to $proxyUrl")) {
        return
    }

    if (-not (Test-Path -LiteralPath $script:WinInetRegPath)) {
        New-Item -Path $script:WinInetRegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable'   -Value 1          -Type DWord
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -Value $hostPort  -Type String
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -Value $bypassWi  -Type String
    # Marker: the next Read-WindowsProxyState will recognize this state as
    # yuruna-managed and snapshot it as clean instead of capturing it as
    # the user's "original" if backup.json is missing.
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -Value 1 -Type DWord

    # setx persists into HKCU\Environment AND broadcasts WM_SETTINGCHANGE.
    # NEW processes (including qemu-img, curl, git) will see the variables;
    # the CURRENT session gets them via the $env:* assignments below.
    & setx HTTP_PROXY  $proxyUrl  | Out-Null
    & setx HTTPS_PROXY $proxyUrl  | Out-Null
    & setx NO_PROXY    $bypassEnv | Out-Null
    & setx $script:EnvMarkerName 1 | Out-Null
    $env:HTTP_PROXY  = $proxyUrl
    $env:HTTPS_PROXY = $proxyUrl
    $env:NO_PROXY    = $bypassEnv
    Set-Item "Env:$($script:EnvMarkerName)" -Value '1'

    Invoke-WinInetRefresh
}

function Restore-WindowsHostProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $wi  = $State.winInet
    $env = $State.envVars

    if (-not (Test-Path -LiteralPath $script:WinInetRegPath)) {
        New-Item -Path $script:WinInetRegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value ([int]$wi.ProxyEnable) -Type DWord
    if ($null -ne $wi.ProxyServer) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer' -Value $wi.ProxyServer -Type String
    } else {
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer' -ErrorAction SilentlyContinue
    }
    if ($null -ne $wi.ProxyOverride) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -Value $wi.ProxyOverride -Type String
    } else {
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
    }
    Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction SilentlyContinue

    # setx CAN'T set an empty value (it interprets "" as "delete and show
    # usage"), so for null/empty restore we reach into the registry via
    # [Environment]::SetEnvironmentVariable which supports $null to delete.
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        $val = $env[$name]
        if ([string]::IsNullOrEmpty($val)) {
            [Environment]::SetEnvironmentVariable($name, $null, 'User')
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($name, $val, 'User')
            Set-Item "Env:$name" -Value $val
        }
    }
    [Environment]::SetEnvironmentVariable($script:EnvMarkerName, $null, 'User')
    Remove-Item "Env:$($script:EnvMarkerName)" -ErrorAction SilentlyContinue

    Invoke-WinInetRefresh
}

function Disable-WindowsHostProxy {
    # Fallback for Clear-HostProxy when no backup exists. Drops our env vars
    # and clears the yuruna marker. When the marker is present we ALSO clear
    # ProxyServer / ProxyOverride (yuruna wrote them, so removing them is
    # safe); without the marker we touch only ProxyEnable, since the strings
    # might pre-date yuruna.
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        $yurunaManaged = Test-WindowsProxyIsYurunaManaged
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        if ($yurunaManaged) {
            Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
        }
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -ErrorAction SilentlyContinue
    }
    foreach ($name in 'HTTP_PROXY','HTTPS_PROXY','NO_PROXY') {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    [Environment]::SetEnvironmentVariable($script:EnvMarkerName, $null, 'User')
    Remove-Item "Env:$($script:EnvMarkerName)" -ErrorAction SilentlyContinue
    Invoke-WinInetRefresh
}

# =========================================================================
# macOS implementation
# =========================================================================
# networksetup is sudo-only for writes. For each "active" network service
# (auto-detected), we set webproxy (http) + securewebproxy (https) +
# proxybypassdomains, then toggle the per-protocol enable flag. Read paths
# DON'T need sudo, so the backup capture can happen before the sudo check
# and surface a clearer error if sudo is missing.

function Get-MacProxyMarkerPath {
    # Marker file written by Set-MacHostProxy and removed by Restore- /
    # Disable-. Same role as the Windows registry marker: lets a re-promotion
    # across a missing backup file recognize that the current networksetup
    # state is yuruna's own, not the user's, and snapshot it as clean.
    $stateDir = Join-Path $HOME '.yuruna'
    return (Join-Path $stateDir 'host-proxy.managed')
}

function Test-MacProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Test-Path -LiteralPath (Get-MacProxyMarkerPath))
}

function Get-MacActiveNetworkService {
    # `route -n get default` yields the default-route interface (e.g. en0).
    # `networksetup -listnetworkserviceorder` pairs service names to
    # Device: entries -- so we match en0 back to "Wi-Fi" / "Ethernet" / etc.
    # Returns $null when no default route exists (e.g. airplane mode),
    # which is caller-handled.
    try {
        $routeOut = & route -n get default 2>$null
        $iface = $null
        foreach ($line in $routeOut) {
            if ($line -match 'interface:\s+(\S+)') { $iface = $matches[1]; break }
        }
        if (-not $iface) { return $null }

        $orderOut = & networksetup -listnetworkserviceorder 2>$null
        $lastService = $null
        foreach ($line in $orderOut) {
            if ($line -match '^\(\d+\)\s+(.+?)\s*$') {
                $lastService = $matches[1]
                continue
            }
            if ($line -match '^\(Hardware Port:.*Device:\s*([^\)]+)\)') {
                if ($matches[1].Trim() -eq $iface) { return $lastService }
            }
        }
    } catch {
        Write-Verbose "Get-MacActiveNetworkService failed: $($_.Exception.Message)"
    }
    return $null
}

function Read-MacProxyState {
    param([Parameter(Mandatory)][string]$NetworkService)
    if (Test-MacProxyIsYurunaManaged) {
        # Same idea as the Windows path: leftover yuruna promotion, capture
        # as clean instead of the stale yuruna IP.
        return @{
            platform            = 'macos'
            networkService      = $NetworkService
            webProxy            = @{ Enabled = 'No'; Server = $null; Port = $null }
            secureWebProxy      = @{ Enabled = 'No'; Server = $null; Port = $null }
            bypassDomains       = @()
            yurunaResetSnapshot = $true
        }
    }
    function ConvertFrom-NetworksetupBlock {
        param([string[]]$Lines)
        $h = @{}
        foreach ($line in $Lines) {
            if ($line -match '^\s*(Enabled|Server|Port|Authenticated|Username):\s*(.*)$') {
                $h[$matches[1]] = $matches[2].Trim()
            }
        }
        return $h
    }
    $webOut  = & networksetup -getwebproxy       $NetworkService 2>$null
    $sslOut  = & networksetup -getsecurewebproxy $NetworkService 2>$null
    $bypOut  = & networksetup -getproxybypassdomains $NetworkService 2>$null
    # `-getproxybypassdomains` prints either a list of domains one per line
    # or the literal string "There aren't any bypass domains set on <svc>.".
    $bypassList = @()
    if ($bypOut -and -not ($bypOut -is [string] -and $bypOut -match "aren't any")) {
        foreach ($line in @($bypOut)) {
            if ($line -match "aren't any") { $bypassList = @(); break }
            $t = "$line".Trim()
            if ($t) { $bypassList += $t }
        }
    }
    return @{
        platform       = 'macos'
        networkService = $NetworkService
        webProxy       = ConvertFrom-NetworksetupBlock -Lines $webOut
        secureWebProxy = ConvertFrom-NetworksetupBlock -Lines $sslOut
        bypassDomains  = $bypassList
    }
}

function Invoke-MacElevationIfNeeded {
    if ((& '/usr/bin/id' -u).Trim() -eq '0') { return }
    Write-Output "  macOS networksetup requires root — caching sudo credentials (you may be prompted for your password)..."
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw "sudo -v failed — cannot obtain root for networksetup. Check your sudo configuration."
    }
}

function Invoke-MacNetworksetup {
    param([string[]]$Arguments)
    if ((& '/usr/bin/id' -u).Trim() -eq '0') {
        & networksetup @Arguments | Out-Null
    } else {
        & sudo networksetup @Arguments | Out-Null
    }
}

function Set-MacHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][hashtable]$ProxyParts,
        [Parameter(Mandatory)][string]$NetworkService
    )
    $h = $ProxyParts.Host; $p = $ProxyParts.Port
    if (-not $PSCmdlet.ShouldProcess("macOS networksetup service '$NetworkService'", "Set web/securewebproxy to ${h}:${p} and enable")) {
        return
    }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'localhost', '127.0.0.1', '*.local', '169.254/16', '192.168.64.*')
    # Marker so the next Read-MacProxyState recognizes this as yuruna-managed.
    $markerPath = Get-MacProxyMarkerPath
    $markerDir  = Split-Path -Parent $markerPath
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    Set-Content -LiteralPath $markerPath -Value $NetworkService -NoNewline -Encoding ascii
}

function Restore-MacHostProxy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)
    $svc = [string]$State.networkService
    if (-not $svc) { return }
    $web = $State.webProxy
    $ssl = $State.secureWebProxy

    if ($web.Server -and $web.Port) {
        Invoke-MacNetworksetup @('-setwebproxy', $svc, [string]$web.Server, [string]$web.Port)
    }
    if ($ssl.Server -and $ssl.Port) {
        Invoke-MacNetworksetup @('-setsecurewebproxy', $svc, [string]$ssl.Server, [string]$ssl.Port)
    }
    $webOn = ($web.Enabled -match '^(Yes|On)$')
    $sslOn = ($ssl.Enabled -match '^(Yes|On)$')
    Invoke-MacNetworksetup @('-setwebproxystate',       $svc, ($webOn ? 'on' : 'off'))
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $svc, ($sslOn ? 'on' : 'off'))

    # Restore bypass list. `-setproxybypassdomains` with "Empty" as its sole
    # argument clears the list (that's the networksetup convention).
    if ($State.bypassDomains -and $State.bypassDomains.Count -gt 0) {
        Invoke-MacNetworksetup (@('-setproxybypassdomains', $svc) + @($State.bypassDomains))
    } else {
        Invoke-MacNetworksetup @('-setproxybypassdomains', $svc, 'Empty')
    }
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

function Disable-MacHostProxy {
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

# =========================================================================
# Public API
# =========================================================================

function Set-HostProxy {
    <#
    .SYNOPSIS
        Promote the given proxy URL to the machine-wide host proxy (user scope).
    .PARAMETER Url
        http://host:port -- typically "http://$resolvedIp:3128" from
        Test-CachingProxy.ps1.
    .PARAMETER NetworkService
        macOS only: override the auto-detected active network service name
        (e.g. "Wi-Fi", "Ethernet"). Ignored on Windows.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$NetworkService
    )
    $parts = ConvertTo-ProxyHostPort -Url $Url
    $backupPath = Get-HostProxyBackupPath

    if ($IsWindows) {
        if (-not $PSCmdlet.ShouldProcess("Windows host (HKCU)", "Promote host proxy to $($parts.Url)")) {
            return
        }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            # Idempotency safeguard -- only snapshot BEFORE the first apply,
            # so a repeat Set-HostProxy doesn't overwrite the backup with
            # the squid-promoted state.
            $state = Read-WindowsProxyState
            $state['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
            $state['promotedTo'] = $parts.Url
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
            Write-Output "  Host proxy: backup written to $backupPath"
        } else {
            Write-Output "  Host proxy: existing backup at $backupPath preserved (still apply)"
        }
        Set-WindowsHostProxy -ProxyParts $parts
        Write-Output "  Host proxy: Windows HKCU WinINet + HTTP_PROXY/HTTPS_PROXY/NO_PROXY set to $($parts.Url)"
        return
    }

    if ($IsMacOS) {
        Invoke-MacElevationIfNeeded
        $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
        if (-not $svc) {
            throw "Could not auto-detect the active macOS network service. Pass -NetworkService 'Wi-Fi' (or the name of your active service)."
        }
        if (-not $PSCmdlet.ShouldProcess("macOS network service '$svc'", "Promote host proxy to $($parts.Url)")) {
            return
        }
        if (-not (Test-Path -LiteralPath $backupPath)) {
            $state = Read-MacProxyState -NetworkService $svc
            $state['timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
            $state['promotedTo'] = $parts.Url
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
            Write-Output "  Host proxy: backup written to $backupPath"
        } else {
            Write-Output "  Host proxy: existing backup at $backupPath preserved (still apply)"
        }
        Set-MacHostProxy -ProxyParts $parts -NetworkService $svc
        Write-Output "  Host proxy: macOS networksetup on service '$svc' set to $($parts.Url)"
        return
    }

    throw "Set-HostProxy supports Windows and macOS only."
}

function Clear-HostProxy {
    <#
    .SYNOPSIS
        Restore the previous host proxy state from backup, or disable yuruna's
        proxy settings if no backup exists.
    #>
    [CmdletBinding()]
    param()
    $backupPath = Get-HostProxyBackupPath
    $state = $null
    if (Test-Path -LiteralPath $backupPath) {
        try {
            # JSON round-trip deserializes into PSCustomObject by default.
            # Clear-HostProxy's Restore-* helpers treat the state as a
            # hashtable, so re-hydrate via -AsHashtable (pwsh 7+).
            $state = Get-Content -LiteralPath $backupPath -Raw |
                     ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Host proxy: could not parse backup '$backupPath' ($($_.Exception.Message)). Falling back to disable-only."
            $state = $null
        }
    }

    if ($IsWindows) {
        if ($state) {
            Restore-WindowsHostProxy -State $state
            Write-Output "  Host proxy: Windows proxy state restored from backup"
        } else {
            Disable-WindowsHostProxy
            Write-Output "  Host proxy: Windows proxy disabled (no backup to restore)"
        }
    } elseif ($IsMacOS) {
        if ($state) {
            Invoke-MacElevationIfNeeded
            Restore-MacHostProxy -State $state
            Write-Output "  Host proxy: macOS proxy state restored on service '$($state.networkService)'"
        } else {
            try { Invoke-MacElevationIfNeeded } catch {
                Write-Warning "  Host proxy: no backup found and could not get sudo ($($_.Exception.Message)); skipping macOS disable."
                return
            }
            Disable-MacHostProxy
            Write-Output "  Host proxy: macOS proxy disabled (no backup to restore)"
        }
    } else {
        Write-Warning "Clear-HostProxy: unsupported platform; nothing to do."
    }

    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Set-HostProxy, Clear-HostProxy, Get-HostProxyBackupPath
