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
    DeviceAttachment) isolates guest-to-guest traffic: two guests on
    192.168.64.0/24 can each reach the gateway (192.168.64.1 = the host)
    and the internet, but NOT each other. ARP between guests is not
    forwarded, so `connect()` to another guest's IP fails with
    EHOSTUNREACH.

    The yuruna squid-cache architecture normally has new guests point
    their apt proxy at the squid VM directly (e.g. 192.168.64.3:3128).
    On Hyper-V's real vswitch this works; on macOS VZ it cannot. This
    forwarder plugs the gap: it binds :3128 on the host and tunnels
    every connection to the squid VM. Guests then use
    http://192.168.64.1:3128 -- always reachable via the VZ gateway.

    Pure PowerShell implementation (TcpListener + runspace pool per
    connection) so there is no brew/socat dependency.

    Typically launched as a detached subprocess by Start-SquidCache.ps1
    (via VM.common.psm1's Start-SquidForwarder) and killed by
    Stop-SquidCache.ps1. The PID is written to -PidFile so the stopper
    can find it without pgrep.

.PARAMETER CacheIp
    IP of the squid-cache VM on the VZ shared-NAT subnet (typically
    192.168.64.X for some X).

.PARAMETER Port
    TCP port to listen on AND connect to on the cache (default 3128).
    Listen and upstream ports are the same because apt / cloud-init
    assume :3128 on both ends.

.PARAMETER BindAddress
    Interface to bind the listener on. Default "0.0.0.0" (all
    interfaces) -- picks up the VZ bridge IP (192.168.64.1)
    automatically without having to enumerate interfaces.

.PARAMETER PidFile
    Optional path to write this process's PID for the stopper to read.

.PARAMETER LogFile
    Optional path to append per-connection log lines (accepted /
    forwarded / closed). Stdout is still written either way.

.EXAMPLE
    pwsh Start-SquidForwarder.ps1 -CacheIp 192.168.64.3

.EXAMPLE
    # How Start-SquidCache.ps1 launches it (detached):
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

# Pin the log path to script scope so Write-ForwarderLog accesses it
# explicitly rather than via dynamic scope. Also makes PSScriptAnalyzer's
# lexical-scope review see $LogFile as consumed in the main body (the
# helper function below is invisible to PSReviewUnusedParameter).
$script:ForwarderLogFile = $LogFile

function Write-ForwarderLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Output $line
    if ($script:ForwarderLogFile) {
        try { Add-Content -LiteralPath $script:ForwarderLogFile -Value $line } catch {
            # Log append is best-effort -- stdout already received the line,
            # and a disk-full / permission blip on the log file must NOT
            # take down the forwarder. Keep running.
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

# Runspace pool so each forwarded connection runs on its own thread
# without paying PowerShell job startup cost. Upper bound of 64
# concurrent tunnels is plenty for apt / cloud-init traffic.
$pool = [RunspaceFactory]::CreateRunspacePool(1, 64)
$pool.Open()

# Per-connection worker: given the accepted client socket plus the
# upstream target, open a matching TcpClient and shuttle bytes in both
# directions until either end closes.
$workerScript = {
    param($client, $targetHost, $targetPort)
    $upstream = $null
    try {
        $upstream = [System.Net.Sockets.TcpClient]::new()
        $upstream.Connect($targetHost, $targetPort)
        $cs = $client.GetStream()
        $us = $upstream.GetStream()
        # CopyToAsync returns a Task; WaitAny returns when either side
        # of the bidirectional copy finishes (EOF / reset / timeout),
        # at which point we tear the pair down.
        $t1 = $cs.CopyToAsync($us)
        $t2 = $us.CopyToAsync($cs)
        [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
    } catch {
        # Connection-level errors are routine (e.g. upstream reset on
        # long CONNECT tunnels). Swallow; the listener keeps running.
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
    # Shutdown-path cleanup: all best-effort. Errors here are irrelevant
    # because the process is exiting; the OS reclaims sockets/fds either way.
    try { $listener.Stop() } catch { $null = $_ }
    try { $pool.Close(); $pool.Dispose() } catch { $null = $_ }
    if ($PidFile -and (Test-Path -LiteralPath $PidFile)) {
        try { Remove-Item -LiteralPath $PidFile -Force } catch { $null = $_ }
    }
    Write-ForwarderLog "shutting down"
}
