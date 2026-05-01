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
    Cross-platform userspace TCP forwarder for the squid-cache VM.

.DESCRIPTION
    Originally written for macOS UTM (Apple Virtualization shared-NAT
    isolates guest-to-guest traffic so guests can't reach a sibling VM
    directly), this is now also used on Windows when source-IP
    preservation matters — e.g. for squid:3128/3129 with PROXY protocol,
    where netsh portproxy would lose the real client IP at the NAT hop.
    Pure PowerShell (TcpListener + runspace pool per connection) — no
    brew/socat/HAProxy dependency, runs anywhere pwsh runs.

    On macOS: typically launched detached by Start-CachingProxy.ps1 to
    let UTM guests reach squid via http://192.168.64.1:3128.

    On Windows: launched by Test.PortMap.psm1's Add-CachingProxyPortMap
    when -ProxyProtocolPort lists a port; -PrependProxyV1 then makes
    the forwarder write a HAProxy PROXY v1 header before the byte
    stream so squid (with `accept-proxy-protocol`) sees the real
    client IP/port instead of the host's NAT-side IP.

    Typically launched detached by Start-CachingProxy.ps1 (via
    VM.common.psm1's Start-CachingProxyForwarder) and killed by
    Stop-CachingProxy.ps1. PID is written to -PidFile so the stopper can
    find it without pgrep.

.PARAMETER CacheIp
    IP of the squid-cache VM on the VZ shared-NAT subnet (typically
    192.168.64.X for some X).

.PARAMETER Port
    TCP port to listen on (the HOST-side port). Default 3128.

.PARAMETER VMPort
    TCP port to connect to on the cache VM. Defaults to -Port (same on
    both sides — the common case for proxy/Grafana/etc.). Set explicitly
    when the host port differs from the VM port (e.g. 8022 on the host
    forwarding to 22 on the VM for SSH, to avoid colliding with the
    host's own sshd on :22).

.PARAMETER PrependProxyV1
    Send a HAProxy PROXY v1 header to upstream before the bidirectional
    byte copy starts: `PROXY TCP4 <client_ip> <bind_ip> <client_port> <bind_port>\r\n`.
    Squid with `accept-proxy-protocol` on the listening http_port reads
    this first and uses the supplied client IP for ACLs and access.log.
    Without this, when the forwarder runs on a NAT host, squid sees only
    the host's NAT-side IP for every forwarded connection.

    Only enable this against an upstream that explicitly speaks PROXY
    protocol — sending the header to a vanilla TCP listener corrupts
    the stream (squid without accept-proxy-protocol will reply with
    400 Bad Request and close).

    IPv6 clients fall back to `PROXY UNKNOWN\r\n` (squid still accepts
    the connection, but no source IP is supplied).

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
    # SSH on a non-standard host port:
    pwsh Start-CachingProxyForwarder.ps1 -CacheIp 192.168.64.3 -Port 8022 -VMPort 22

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
    [int]$VMPort = 0,
    [switch]$PrependProxyV1,
    [string]$BindAddress = "0.0.0.0",
    [string]$PidFile,
    [string]$LogFile
)

# 0 sentinel (instead of `[int]$VMPort = $Port`, which doesn't work because
# parameter defaults can't reference other parameters): when unset, mirror
# host port. Most callers don't pass it; only split-port mappings do.
if ($VMPort -eq 0) { $VMPort = $Port }

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
Write-ForwarderLog "listening on ${BindAddress}:${Port} -> ${CacheIp}:${VMPort} (pid $PID)"

# Runspace pool: each forwarded connection on its own thread without
# PowerShell-job startup cost. 64 concurrent tunnels covers apt/cloud-init.
$pool = [RunspaceFactory]::CreateRunspacePool(1, 64)
$pool.Open()

# Per-connection worker: accept client socket + upstream target, open
# matching TcpClient, optionally send a HAProxy PROXY v1 header so the
# upstream sees the real client IP/port (otherwise it sees the
# forwarder's source IP), then shuttle bytes both ways until either end
# closes.
$workerScript = {
    param($client, $targetHost, $targetPort, $sendProxyV1)
    $upstream = $null
    try {
        $upstream = [System.Net.Sockets.TcpClient]::new()
        $upstream.Connect($targetHost, $targetPort)
        $cs = $client.GetStream()
        $us = $upstream.GetStream()
        # PROXY v1: text line, must be the FIRST bytes on the upstream
        # connection (before any TLS handshake or HTTP request line).
        # Format: `PROXY TCP4 <src_ip> <dst_ip> <src_port> <dst_port>\r\n`
        # IPv6 clients fall back to `PROXY UNKNOWN\r\n` — squid still
        # accepts but doesn't get a source-IP override.
        if ($sendProxyV1) {
            try {
                $remote = $client.Client.RemoteEndPoint
                $local  = $client.Client.LocalEndPoint
                $fam = $remote.AddressFamily
                $hdr = if ($fam -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                    "PROXY TCP4 $($remote.Address) $($local.Address) $($remote.Port) $($local.Port)`r`n"
                } elseif ($fam -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                    "PROXY TCP6 $($remote.Address) $($local.Address) $($remote.Port) $($local.Port)`r`n"
                } else {
                    "PROXY UNKNOWN`r`n"
                }
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($hdr)
                $us.Write($bytes, 0, $bytes.Length)
                $us.Flush()
            } catch {
                # If the header write fails the upstream is unusable —
                # let the catch below tear the pair down.
                throw
            }
        }
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
                AddArgument($VMPort).
                AddArgument($PrependProxyV1.IsPresent)
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
