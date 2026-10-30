<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42a6e74d-4368-4d9b-a0ce-cba6aa95de8b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver proxy portmap
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

# --- REGION: Host proxy helpers
# Registry keys and marker semantics: https://yuruna.link/42fa6f45-000e

$script:WinInetRegPath    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:WinInetMarkerName = 'YurunaProxyManaged'
$script:EnvMarkerName     = 'YURUNA_PROXY_MANAGED'

<#
.SYNOPSIS
Indicate whether the current host proxy state was set by Yuruna.

.DESCRIPTION
Returns $true when either the WinINet YurunaProxyManaged DWORD or the
HKCU\Environment YURUNA_PROXY_MANAGED variable equals 1. The marker
prevents a re-promotion across a missing snapshot file from capturing
our own proxy URL as if it were the user's original setting.
#>
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

<#
.SYNOPSIS
Snapshot the current Windows host proxy state for later restore.

.DESCRIPTION
Reads HKCU\...\Internet Settings (ProxyEnable / ProxyServer /
ProxyOverride) and the user-scope HTTP_PROXY / HTTPS_PROXY / NO_PROXY
environment variables and returns them as a hashtable suitable for
Restore-WindowsHostProxy. When the marker reports the state is already
yuruna-managed it returns a sentinel "reset" snapshot
(yurunaResetSnapshot=$true) so callers can avoid re-capturing our own
proxy URL.
#>
function Read-WindowsProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if (Test-WindowsProxyIsYurunaManaged) {
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

<#
.SYNOPSIS
Broadcast WinINet INTERNET_OPTION_SETTINGS_CHANGED + REFRESH.

.DESCRIPTION
Notifies already-running WinINet clients (Edge, Invoke-WebRequest,
etc.) to reload proxy settings from the registry without restarting
the user session. Adds a small Add-Type once per session for the
wininet.dll P/Invoke and is a no-op on non-Windows hosts when the
type compiles (the runtime call simply returns $false).
#>
function Invoke-WinInetRefresh {
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
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][YurunaWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

<#
.SYNOPSIS
Point the Windows host at a Yuruna-managed HTTP proxy.

.DESCRIPTION
Writes ProxyEnable=1, ProxyServer=$ProxyParts.HostPort, and a
localhost+<local> bypass list into HKCU WinINet, then mirrors the
values into HKCU\Environment as HTTP_PROXY / HTTPS_PROXY / NO_PROXY
via setx and updates the current process Env: drive. Also stamps the
YurunaProxyManaged DWORD and YURUNA_PROXY_MANAGED env marker so a
later Read-WindowsProxyState knows the state belongs to us, then
broadcasts an Invoke-WinInetRefresh so live clients pick it up.
#>
function Set-WindowsHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)][hashtable]$ProxyParts)
    $hostPort   = $ProxyParts.HostPort
    $proxyUrl   = $ProxyParts.Url
    $bypassWi   = 'localhost;127.0.0.1;<local>'
    $bypassEnv  = 'localhost,127.0.0.1,::1'
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_bee8709211e28c63'), (Format-YurunaOperatorMessage -Key 'host.operator_87e79790981d47af' -Arguments @{ proxyUrl = "$proxyUrl" }))) {
        return
    }
    if (-not (Test-Path -LiteralPath $script:WinInetRegPath)) {
        New-Item -Path $script:WinInetRegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable'   -Value 1          -Type DWord
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -Value $hostPort  -Type String
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -Value $bypassWi  -Type String
    Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name $script:WinInetMarkerName -Value 1 -Type DWord
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

<#
.SYNOPSIS
Restore Windows host proxy state from a Read-WindowsProxyState snapshot.

.DESCRIPTION
Replays the WinINet ProxyEnable / ProxyServer / ProxyOverride values
from $State.winInet, restores the user-scope HTTP_PROXY / HTTPS_PROXY
/ NO_PROXY env vars from $State.envVars (clearing those that were
absent), strips the YurunaProxyManaged + YURUNA_PROXY_MANAGED markers,
and broadcasts Invoke-WinInetRefresh so live clients reload. Used by
the test harness to undo a prior Set-WindowsHostProxy.
#>
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

<#
.SYNOPSIS
Turn the Windows host proxy off without losing the user's proxy URL.

.DESCRIPTION
Sets WinINet ProxyEnable to 0; if the marker says yuruna owns the
state it also clears ProxyServer and ProxyOverride so a stale Yuruna
URL isn't left behind. Always strips the YurunaProxyManaged DWORD,
clears HTTP_PROXY / HTTPS_PROXY / NO_PROXY in user scope and the
current process, drops the YURUNA_PROXY_MANAGED env marker, and
broadcasts Invoke-WinInetRefresh.
#>
function Disable-WindowsHostProxy {
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

<#
.SYNOPSIS
Aggressively wipe Windows host proxy state regardless of marker.

.DESCRIPTION
Module-private helper invoked by the contract Remove-HostProxy entry
point: zeroes ProxyEnable and unconditionally removes ProxyServer +
ProxyOverride, the YurunaProxyManaged DWORD, and the user/process
HTTP_PROXY / HTTPS_PROXY / NO_PROXY values plus the
YURUNA_PROXY_MANAGED env marker, then broadcasts Invoke-WinInetRefresh.
ShouldProcess is intentionally suppressed because the public
Remove-HostProxy already gates the prompt; calling it here would
double-prompt the user.
#>
function Remove-WindowsHostProxy {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Module-private helper; public Remove-HostProxy gates ShouldProcess.')]
    [CmdletBinding()]
    param()
    if (Test-Path -LiteralPath $script:WinInetRegPath) {
        Set-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyEnable' -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyServer'   -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $script:WinInetRegPath -Name 'ProxyOverride' -ErrorAction SilentlyContinue
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

# --- REGION: Port-map helpers
$script:FirewallRulePrefix        = 'Yuruna-CachingProxyService-Port-'
$script:FirewallProgramRulePrefix = 'Yuruna-CachingProxyService-Pwsh-'

<#
.SYNOPSIS
Return the path to the shared caching-proxy-service TCP forwarder script.

.DESCRIPTION
Resolves host/macos.utm/Start-CachingProxyServiceForwarder.ps1 against the
repository root inferred from $PSScriptRoot. The forwarder script
lives under host/macos.utm/ as the canonical copy but is pure
PowerShell and runs unchanged on Windows.
#>
function Get-CachingProxyServiceForwarderScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # $PSScriptRoot is host/windows.hyper-v/modules, so three levels up is repo root.
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    return (Join-Path $repoRoot 'host/macos.utm/Start-CachingProxyServiceForwarder.ps1')
}

<#
.SYNOPSIS
Return the path to pwsh.exe for use in firewall per-program rules.

.DESCRIPTION
Best-guess via Get-Command -CommandType Application. The result may
point at the WindowsApps App Execution Alias stub (a zero-byte
reparse point); Defender filters on the post-resolution path so the
caller should re-read Get-Process .Path after spawning the forwarder
and rewrite the rule when the loaded binary differs. Returns $null
when pwsh.exe is not on PATH.
#>
function Get-PwshExePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    Import-Module (Join-Path $repoRoot 'test/modules/Test.InnerSpawn.psm1') -Global -DisableNameChecking
    return (Test.InnerSpawn\Get-PwshExePath)
}

<#
.SYNOPSIS
Return the pidfile path for the per-port caching-proxy-service forwarder.

.DESCRIPTION
Composes ~/virtual/caching-proxy-service/forwarder.<Port>.pid. The pidfile is
the canonical handle Stop-WindowsCachingProxyServiceForwarder uses to find
and kill the detached pwsh worker that owns a given listen port.
#>
function Get-WindowsForwarderPidPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
    return (Join-Path $stateDir "forwarder.$Port.pid")
}

<#
.SYNOPSIS
Stop a detached pwsh caching-proxy-service forwarder by listen port.

.DESCRIPTION
Reads ~/virtual/caching-proxy-service/forwarder.<Port>.pid, validates the pid
belongs to a pwsh/powershell process, and calls Stop-Process -Force.
Removes the pidfile in all cases (including missing pid, non-pwsh
owner, or successful kill) so a stale file doesn't trip later starts.
No-op on non-Windows hosts; -Quiet suppresses the per-port summary
line.
#>
function Stop-WindowsCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port, [switch]$Quiet)
    if (-not $IsWindows) { return $true }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    if (-not (Test-Path $pidFile)) { return $true }
    $forwarderPid = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not ($forwarderPid -as [int])) {
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    $proc = Get-Process -Id ([int]$forwarderPid) -ErrorAction SilentlyContinue
    if ($proc) {
        if ($proc.ProcessName -match '^(pwsh|powershell)$') {
            if ($PSCmdlet.ShouldProcess("pid $forwarderPid (port :${Port})", (Format-YurunaOperatorMessage -Key 'host.operator_8681ed98b32ff086'))) {
                if (-not $Quiet) { Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_e9d71dbc40aa4cf9' -Arguments @{ forwarderPid = "$forwarderPid"; port = "${Port}" }) }
                Stop-Process -Id ([int]$forwarderPid) -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $Quiet) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1eec727cf63db6d8' -Arguments @{ forwarderPid = "$forwarderPid"; processName = "$($proc.ProcessName)" })
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
Launch a detached pwsh TCP forwarder for the squid caching-proxy service.

.DESCRIPTION
Stops any prior forwarder for the same $Port, then spawns
Start-CachingProxyServiceForwarder.ps1 hidden, wired to redirect stdout /
stderr to per-port logs under ~/virtual/caching-proxy-service/. Polls
127.0.0.1:$Port for up to 3 s; on success returns a PSCustomObject
@{ Success=$true; Pid; PwshPath } where PwshPath is the post-spawn
loaded binary (used by callers to rewrite the Defender per-program
firewall rule when the WindowsApps alias differs). $VMPort defaults
to $Port. -PrependProxyV1 forwards a HAProxy v1 PROXY header so the
upstream cache can see the original LAN client IP.
#>
function Start-WindowsCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    if (-not $IsWindows) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1e70ed145bb5ab5f')
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    if ($VMPort -eq 0) { $VMPort = $Port }
    $forwarderScript = Get-CachingProxyServiceForwarderScriptPath
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7055bf70ab553d9b' -Arguments @{ forwarderScript = "$forwarderScript" })
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    $logFile = Join-Path $stateDir "forwarder.$Port.log"
    $stdoutLog = Join-Path $stateDir "forwarder.$Port.stdout.log"
    $stderrLog = Join-Path $stateDir "forwarder.$Port.stderr.log"
    Stop-WindowsCachingProxyServiceForwarder -Port $Port -Quiet
    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    $action   = "0.0.0.0:${Port} -> ${CacheIp}:${VMPort}${proxyTag}"
    if (-not $PSCmdlet.ShouldProcess($action, (Format-YurunaOperatorMessage -Key 'host.operator_872f663e1444d15e'))) {
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_20be2f035272a5ea' -Arguments @{ action = "${action}" })
    # Start-Process joins arguments without quoting; quote paths containing spaces.
    # See https://yuruna.link/42e220c4-0004
    $forwarderScriptQuoted = '"' + $forwarderScript + '"'
    $pidFileQuoted         = '"' + $pidFile + '"'
    $logFileQuoted         = '"' + $logFile + '"'
    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScriptQuoted,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFileQuoted,
        '-LogFile', $logFileQuoted
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }
    try {
        # See https://yuruna.link/42e5cdfd-002a
        $stdinSink = Join-Path $stateDir 'stdin.empty'
        if (-not (Test-Path -LiteralPath $stdinSink)) {
            [System.IO.File]::WriteAllBytes($stdinSink, [byte[]]@())
        }
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList $procArgs `
            -RedirectStandardInput  $stdinSink `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError  $stderrLog `
            -WindowStyle Hidden `
            -PassThru
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_368bbdea275958b3' -Arguments @{ message = "$($_.Exception.Message)" })
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { [int]((Get-Content $pidFile -Raw).Trim()) } else { [int]$proc.Id }
                $loadedPath = $null
                try { $loadedPath = (Get-Process -Id $actualPid -ErrorAction Stop).Path } catch { $null = $_ }
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_da31f377a43264d3' -Arguments @{ actualPid = "$actualPid"; action = "${action}" })
                if ($loadedPath) { Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_39c802c10067031a' -Arguments @{ loadedPath = "$loadedPath" }) }
                return [PSCustomObject]@{ Success = $true; Pid = $actualPid; PwshPath = $loadedPath }
            }
        } catch { $null = $_ } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_957af0b7e5a09c03' -Arguments @{ id = "$($proc.Id)"; port = "${Port}"; stderrLog = "$stderrLog" })
    return [PSCustomObject]@{ Success = $false; Pid = [int]$proc.Id; PwshPath = $null }
}

<#
.SYNOPSIS
Install Yuruna-tagged inbound firewall rules for a caching-proxy-service port.

.DESCRIPTION
Removes any existing rules with the Yuruna-CachingProxyService-Port-<Port>
display name, then creates a fresh Allow rule on that TCP port across
all profiles. When -IncludeProgram is set it also (re)creates a
Yuruna-CachingProxyService-Pwsh-<Port> per-program rule scoped to
$ProgramPath (or Get-PwshExePath when omitted). The per-program rule
guards against Defender silently dropping LAN traffic when the
WindowsApps App Execution Alias resolves to a different binary than
the loaded pwsh.exe; if no path is resolvable the rule is skipped
with a warning.
#>
function Add-CachingProxyServiceFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Description,
        [switch]$IncludeProgram,
        [string]$ProgramPath
    )
    if (-not $IsWindows) { return }
    $portRule = "${script:FirewallRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($portRule, (Format-YurunaOperatorMessage -Key 'host.operator_a9163573316af907'))) {
        Get-NetFirewallRule -DisplayName $portRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $portRule -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Any `
            -Description $Description `
            -ErrorAction SilentlyContinue | Out-Null
    }
    if (-not $IncludeProgram) { return }
    $programRule = "${script:FirewallProgramRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($programRule, (Format-YurunaOperatorMessage -Key 'host.operator_a6547fddd359850a'))) {
        Get-NetFirewallRule -DisplayName $programRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $pwshPath = if ($ProgramPath) { $ProgramPath } else { Get-PwshExePath }
        if (-not $pwshPath) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b21a8288b21cbc12' -Arguments @{ programRule = "${programRule}"; port = "${Port}" })
            return
        }
        New-NetFirewallRule -DisplayName $programRule -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Any `
            -Program $pwshPath `
            -Description "${Description} (per-program: $pwshPath)" `
            -ErrorAction SilentlyContinue | Out-Null
    }
}

<#
.SYNOPSIS
List ports that currently have a forwarder pidfile on disk.

.DESCRIPTION
Walks ~/virtual/caching-proxy-service/ for forwarder.<port>.pid files and
returns the parsed integer port numbers as an array (always wrapped
with the unary comma so a single-element result still flows as an
array). Empty array on non-Windows hosts or when the state directory
is missing.
#>
function Get-WindowsForwarderPidPort {
    [CmdletBinding()]
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $stateDir = Join-Path $HOME 'virtual\caching-proxy-service'
    if (-not (Test-Path $stateDir)) { return @() }
    $ports = @()
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') { $ports += [int]$matches[1] }
        }
    return ,$ports
}

<#
.SYNOPSIS
Discover Yuruna caching-proxy-service ports from existing firewall rules.

.DESCRIPTION
Scans Get-NetFirewallRule for display names that begin with
Yuruna-CachingProxyService-Port- or Yuruna-CachingProxyService-Pwsh- and returns
the parsed integer ports, sorted and de-duplicated. Port-map changes use it
(Get-HyperVPortMapPort) to find forwarders the port-map record does not
name, such as rules left behind when the record was deleted out of band.
#>
function Get-YurunaMappedPortFromFirewall {
    [CmdletBinding()]
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $ports = @()
    $prefixPattern = '^(?:' +
        [regex]::Escape($script:FirewallRulePrefix) + '|' +
        [regex]::Escape($script:FirewallProgramRulePrefix) +
        ')(\d+)$'
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -like "${script:FirewallRulePrefix}*" -or
            $_.DisplayName -like "${script:FirewallProgramRulePrefix}*"
        } |
        ForEach-Object {
            if ($_.DisplayName -match $prefixPattern) {
                $ports += [int]$matches[1]
            }
        }
    return ,($ports | Sort-Object -Unique)
}

<#
.SYNOPSIS
Remove the portproxy, forwarder, and firewall rules for one port.

.DESCRIPTION
Deletes the netsh interface portproxy v4tov4 entry on 0.0.0.0:$Port,
stops the matching detached pwsh forwarder, and removes both the
Yuruna-CachingProxyService-Port-<Port> and Yuruna-CachingProxyService-Pwsh-<Port>
firewall rules if present. Idempotent: missing pieces are silently
skipped so callers can issue a blanket sweep.
#>
function Remove-SinglePortMap {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Port)
    if (-not $PSCmdlet.ShouldProcess("host:${Port}", (Format-YurunaOperatorMessage -Key 'host.operator_4ad9fc4774e8be4d'))) { return }
    & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>&1 | Out-Null
    $null = Stop-WindowsCachingProxyServiceForwarder -Port $Port -Quiet
    foreach ($prefix in @($script:FirewallRulePrefix, $script:FirewallProgramRulePrefix)) {
        $ruleName = "${prefix}${Port}"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
The host ports that have a Yuruna forwarder installed: a firewall rule the
forwarder setup created, or a live forwarder pidfile.
#>
function Get-HyperVPortMapPort {
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    return [int[]]@(@(Get-YurunaMappedPortFromFirewall) + @(Get-WindowsForwarderPidPort) | Sort-Object -Unique)
}
