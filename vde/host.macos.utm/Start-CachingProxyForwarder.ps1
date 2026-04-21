<#PSScriptInfo
.VERSION 0.1
.GUID 42c0ffee-a0de-4e1f-a2b3-c4d5e6f7aa02
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
    TCP forwarder that bridges the Mac host's :3128 to the squid-cache VM.

.DESCRIPTION
    Apple Virtualization.framework's shared-NAT attachment (VZNATNetwork-
    DeviceAttachment) isolates guest-to-guest traffic: guests on
    192.168.64.0/24 reach the gateway (192.168.64.1 = the host) and the
    internet but NOT each other (ARP between guests is not forwarded;
    connect() to another guest fails with EHOSTUNREACH).

    Normally guests would point their apt proxy at the squid VM directly
    (e.g. 192.168.64.3:3128). That works on Hyper-V's real vswitch but
    not on macOS VZ. This forwarder binds :3128 on the host and tunnels
    every connection to the squid VM, so guests use
    http://192.168.64.1:3128 -- always reachable via the VZ gateway.

    Pure PowerShell (TcpListener + runspace pool per connection) so there
    is no brew/socat dependency.

    Typically launched detached by Start-CachingProxy.ps1 (via
    VM.common.psm1's Start-CachingProxyForwarder) and killed by
    Stop-CachingProxy.ps1. PID is written to -PidFile so the stopper can
    find it without pgrep.

.PARAMETER CacheIp
    IP of the squid-cache VM on the VZ shared-NAT subnet (typically
    192.168.64.X for some X).

.PARAMETER Port
    TCP port to listen on AND connect to on the cache (default 3128).
    Same port on both sides because apt/cloud-init assume :3128 on
    both ends.

.PARAMETER BindAddress
    Interface to bind on. Default "0.0.0.0" (all interfaces) picks up
    the VZ bridge IP (192.168.64.1) without enumerating interfaces.

.PARAMETER PidFile
    Optional path to write this process's PID for the stopper to read.

.PARAMETER LogFile
    Optional path to append per-connection log lines (accepted/
    forwarded/closed). Stdout is still written either way.

.EXAMPLE
    pwsh Start-CachingProxyForwarder.ps1 -CacheIp 192.168.64.3

.EXAMPLE
    # How Start-CachingProxy.ps1 launches it (detached):
    Start-Process pwsh -ArgumentList @(
        '-NoProfile','-File', $forwarderScript,
        '-CacheIp', '192.168.64.3',
        '-PidFile', "$HOME/virtual/squid-cache/forwarder.pid",
        '-LogFile', "$HOME/virtual/squid-cache/forwarder.log"
    )
#>

param(
    [Parameter(Mandatory)][string]$CacheIp,
    [int]$Port = 3128,
    [string]$BindAddress = "0.0.0.0",
    [string]$PidFile,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"

# Pin log path to script scope so Write-ForwarderLog accesses it
# explicitly (and PSScriptAnalyzer's PSReviewUnusedParameter sees
# $LogFile as consumed — the helper function is invisible to that check).
$script:ForwarderLogFile = $LogFile

function Write-ForwarderLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Output $line
    if ($script:ForwarderLogFile) {
        try { Add-Content -LiteralPath $script:ForwarderLogFile -Value $line } catch {
            # Best-effort: stdout already got the line; a disk-full or
            # permission blip must NOT take down the forwarder.
            $null = $_
        }
    }
}

if ($PidFile) {
    try { $PID | Out-File -FilePath $PidFile -Encoding ascii -Force } catch {
        Write-Warning "Could not write PID file '$PidFile': $($_.Exception.Message)"
    }
}

$bindIp = [System.Net.IPAddress]::Parse($BindAddress)
$listener = [System.Net.Sockets.TcpListener]::new($bindIp, $Port)
try {
    $listener.Start()
} catch {
    Write-ForwarderLog "FATAL: could not bind ${BindAddress}:${Port} -- $($_.Exception.Message)"
    exit 1
}
Write-ForwarderLog "listening on ${BindAddress}:${Port} -> ${CacheIp}:${Port} (pid $PID)"

# Runspace pool: each forwarded connection on its own thread without
# PowerShell-job startup cost. 64 concurrent tunnels covers apt/cloud-init.
$pool = [RunspaceFactory]::CreateRunspacePool(1, 64)
$pool.Open()

# Per-connection worker: accept client socket + upstream target, open
# matching TcpClient, shuttle bytes both ways until either end closes.
$workerScript = {
    param($client, $targetHost, $targetPort)
    $upstream = $null
    try {
        $upstream = [System.Net.Sockets.TcpClient]::new()
        $upstream.Connect($targetHost, $targetPort)
        $cs = $client.GetStream()
        $us = $upstream.GetStream()
        # WaitAny returns when either side of the bidirectional copy
        # finishes (EOF/reset/timeout); tear the pair down.
        $t1 = $cs.CopyToAsync($us)
        $t2 = $us.CopyToAsync($cs)
        [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
    } catch {
        # Connection errors are routine (e.g. upstream reset on long
        # CONNECT tunnels). Swallow; the listener keeps running.
        $null = $_
    } finally {
        if ($client)   { try { $client.Close()   } catch { $null = $_ } }
        if ($upstream) { try { $upstream.Close() } catch { $null = $_ } }
    }
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($workerScript).
                AddArgument($client).
                AddArgument($CacheIp).
                AddArgument($Port)
        [void]$ps.BeginInvoke()
    }
} finally {
    # Shutdown-path cleanup: best-effort. Errors here are irrelevant —
    # the process is exiting and the OS reclaims sockets/fds.
    try { $listener.Stop() } catch { $null = $_ }
    try { $pool.Close(); $pool.Dispose() } catch { $null = $_ }
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        try { Remove-Item -LiteralPath $PidFile -Force } catch { $null = $_ }
    }
    Write-ForwarderLog "shutting down"
}
