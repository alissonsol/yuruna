<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e8b3c5-7f1a-4d62-9c40-6b2d3e4f5a61
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
    Host Config Service: serves NAS connection info + credentials over mutual
    TLS to ONLY the VMs running under this host.
.DESCRIPTION
    A small TcpListener + SslStream service (cross-platform: SslStream works
    identically on Windows/Linux/macOS, unlike HttpListener HTTPS which needs
    http.sys and is Windows-only). It presents a server leaf signed by this
    host's Config CA (Test.HostConfigCA.psm1) and REQUIRES a client certificate
    that chains to the same CA -- so only a VM this host created (and baked a
    client leaf into) can fetch. Credentials are resolved LIVE per request via
    Get-Password (the vault), so a rotated NAS password reaches a running VM on
    its next poll -- the fix for the bake-once staleness that breaks replication
    when a password changes.

    Routes (mTLS required on all):
      GET /healthz          -> "ok"
      GET /v1/nas/stash     -> ystash-nas connection info + credential (JSON)
      GET /v1/nas/pool      -> ypool-nas connection info + credential (JSON)

    Design: docs/design/host-config-service-and-extension-hosts.md. Posture
    (mTLS, TLS, EC P-256) is operator-approved; the NAS password keeps its
    existing vault storage (see feedback_no_unauthorized_security_changes).

    Launcher mode (default) mints the CA + server leaf, opens the host firewall
    (best-effort, Windows), then re-execs this script detached with -Serve and
    records config-server.pid. -Serve runs the blocking listener loop.
.PARAMETER Port
    TCP port to listen on. 0 (default) resolves configService.port from
    test.config.yml, falling back to 8443.
.PARAMETER Serve
    Internal: run the blocking listener loop in THIS process (the launcher
    re-execs itself with this switch, detached).
.PARAMETER Restart
    Force a kill + relaunch even when a healthy instance is already serving
    (e.g. after deploying new service code). Without it the launcher is a no-op
    when the service is already up -- so the runner can re-ensure it every cycle
    cheaply, and it self-heals after a host reboot or crash.
#>

param(
    [int]$Port = 0,
    [switch]$Serve,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
# Benign native non-zero exits (chmod on a tmpfs, a firewall-rule probe) must not
# abort under EAP=Stop (feedback_winget_self_upgrade_kills_running_pwsh class).
$PSNativeCommandUseErrorActionPreference = $false
# In the detached -Serve process, force PLAIN-TEXT rendering so the redirected
# stderr (config-server.err) is readable text, not ANSI/VT colour escapes that make
# the file look "binary" when a startup error is written. $PSStyle is PS 7.2+;
# guard for 7.0/7.1 where it does not exist.
if ($Serve -and (Get-Variable -Name PSStyle -ErrorAction Ignore)) {
    try { $PSStyle.OutputRendering = 'PlainText' } catch { $null = $_ }
}

# Seconds to wait for the detached service to accept on $Port before warning.
$script:ConfigServiceReadyTimeoutSeconds = 30
$script:ConfigServiceDefaultPort         = 8443

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
$TestRoot   = $paths.TestRoot
$ModulesDir = $paths.ModulesDir
# Test.YurunaDir owns Initialize-YurunaRuntimeDir (and $env:YURUNA_RUNTIME_DIR).
# The Prelude only returns the path bundle; it does not load this module, so it
# must be imported before the runtime-dir call below resolves.
Import-Module (Join-Path $ModulesDir 'Test.YurunaDir.psm1') -Global -Force
$null = Initialize-YurunaRuntimeDir
$RuntimeDir = $env:YURUNA_RUNTIME_DIR
$PidFile    = Join-Path $RuntimeDir 'config-server.pid'

# Module set: CA + storage-config + vault (authentication extension) + config reader.
Import-Module (Join-Path $ModulesDir 'Test.HostConfigCA.psm1') -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1')  -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1')       -Global -Force
Import-Module (Join-Path $ModulesDir 'Test.Extension.psm1')    -Global -Force
# Load the active authentication extension (exports Get-Password / Get-EffectiveUser
# / Test-VaultEntry). RequireSingle: exactly one authentication implementation.
$null = @(Import-Extension -Area 'authentication' -RequireSingle)

if ($Port -le 0) {
    $Port = $script:ConfigServiceDefaultPort
    $configPath = Join-Path $TestRoot 'test.config.yml'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            if ($cfg.configService -and $cfg.configService.port) { $Port = [int]$cfg.configService.port }
        } catch { Write-Verbose "configService.port parse failed: $($_.Exception.Message)" }
    }
}

# --- REGION: Shared helpers (used by the -Serve loop)

# Resolve the JSON payload for a NAS name, or $null when not configured. Reads
# test.config.yml + the vault FRESH each call so a rotated password / changed
# share is picked up live. Never mints a junk password: when the networkUser has
# no real vault entry (empty vaultKey AND no stored secret) it returns $null so
# the caller answers 503 rather than baking an auto-generated credential the NAS
# would reject.
function Resolve-YurunaNasPayload {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('stash', 'pool')][string]$Name,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
    $tc = $null
    try { $tc = Read-TestConfig -Path $ConfigPath } catch { Write-Verbose "Read-TestConfig: $($_.Exception.Message)"; return $null }
    if (-not $tc) { return $null }
    $nasCfg = if ($Name -eq 'stash') {
        Get-YurunaStashStorageConfig -Config $tc
    } else {
        Get-YurunaPoolStorageConfig -Config $tc -IgnoreReplicate
    }
    if (-not $nasCfg) { return $null }
    $user = [string]$nasCfg.NetworkUser
    if ([string]::IsNullOrWhiteSpace($user)) { return $null }
    # Gate exactly like New-VM / the host drain: only fetch when a real
    # credential exists (a non-empty vaultKey, or an already-stored entry).
    $hasReal = $false
    try {
        $eff = Get-EffectiveUser -LogicalUser $user
        $vaultKey = if ($eff -and $eff.vaultKey) { [string]$eff.vaultKey } else { $user }
        $hasReal = (-not [string]::IsNullOrWhiteSpace($eff.vaultKey)) -or (Test-VaultEntry -VaultKey $vaultKey)
    } catch { Write-Verbose "vault gate: $($_.Exception.Message)" }
    if (-not $hasReal) { return $null }
    $pw = $null
    try { $pw = Get-Password -Username $user } catch { Write-Verbose "Get-Password: $($_.Exception.Message)" }
    if ([string]::IsNullOrEmpty($pw)) { return $null }
    $verSrc = "$Name|$($nasCfg.NetworkPath)|$user|$pw"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $verBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($verSrc))
        $version  = (($verBytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
    return @{
        name        = $Name
        networkPath = $nasCfg.NetworkPath
        username    = $user
        password    = $pw
        localPath   = $nasCfg.LocalPath
        version     = $version
    }
}

# Read an HTTP request line + headers from the TLS stream (we ignore the body --
# all routes are GET). Returns @{ Method; Path } or $null on a malformed/empty
# request. Bounded to MaxHeaderBytes so a client cannot stream forever.
function Read-YurunaHttpRequest {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [int]$MaxHeaderBytes = 8192
    )
    $buf  = [System.Text.StringBuilder]::new()
    $one  = [byte[]]::new(1)
    $count = 0
    while ($count -lt $MaxHeaderBytes) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -le 0) { break }
        [void]$buf.Append([char]$one[0])
        $count++
        $s = $buf.ToString()
        if ($s.EndsWith("`r`n`r`n") -or $s.EndsWith("`n`n")) { break }
    }
    $text = $buf.ToString()
    $firstLine = ($text -split "`r?`n", 2)[0]
    if ([string]::IsNullOrWhiteSpace($firstLine)) { return $null }
    $parts = $firstLine.Trim() -split '\s+'
    if ($parts.Count -lt 2) { return $null }
    return @{ Method = $parts[0]; Path = $parts[1] }
}

# Write a minimal HTTP/1.1 response over the TLS stream and flush.
function Write-YurunaHttpResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$StatusText,
        [Parameter()][string]$Body = '',
        [Parameter()][string]$ContentType = 'application/json'
    )
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $head = "HTTP/1.1 $StatusCode $StatusText`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Content-Length: $($bodyBytes.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

# The blocking accept loop. One connection at a time (poll volume is tiny: one
# request per VM per hour). Each connection is fully isolated in try/catch +
# socket timeouts so a slow/hostile client cannot wedge the loop.
function Invoke-YurunaConfigServeLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $serverCert = New-YurunaConfigServerCertificate
    $caPublic   = Get-YurunaConfigCaPublicCertificate
    $tls = [System.Security.Authentication.SslProtocols]::Tls12 -bor [System.Security.Authentication.SslProtocols]::Tls13
    # No TLS-layer client-cert validation callback (null) -- the server accepts any
    # presented cert at the transport, then AUTHORIZES it POST-handshake on our own
    # thread via Test-YurunaConfigClientCertificate ("chains to THIS host's CA").
    # That sidesteps running a scriptblock delegate during the native handshake.

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $ListenPort)
    $listener.Start()
    Write-Information "Host Config Service listening (mTLS) on 0.0.0.0:$ListenPort" -InformationAction Continue
    try {
        while ($true) {
            $client = $null; $ssl = $null
            try {
                $client = $listener.AcceptTcpClient()
                $client.ReceiveTimeout = 10000
                $client.SendTimeout    = 10000
                $netStream = $client.GetStream()
                $ssl = [System.Net.Security.SslStream]::new($netStream, $false)
                $opts = [System.Net.Security.SslServerAuthenticationOptions]::new()
                $opts.ServerCertificate              = $serverCert
                $opts.ClientCertificateRequired      = $true
                $opts.EnabledSslProtocols            = $tls
                $opts.CertificateRevocationCheckMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
                $ssl.AuthenticateAsServer($opts)

                $clientOk = Test-YurunaConfigClientCertificate -Certificate $ssl.RemoteCertificate -CaCertificate $caPublic
                if (-not $clientOk) {
                    Write-YurunaHttpResponse -Stream $ssl -StatusCode 403 -StatusText 'Forbidden' -Body '{"ok":false,"error":"client certificate not issued by this host"}'
                    continue
                }

                $req = Read-YurunaHttpRequest -Stream $ssl
                if (-not $req) { continue }
                if ($req.Method -ne 'GET') {
                    Write-YurunaHttpResponse -Stream $ssl -StatusCode 405 -StatusText 'Method Not Allowed' -Body '{"ok":false,"error":"only GET is supported"}'
                    continue
                }
                $path = ($req.Path -split '\?', 2)[0]
                if ($path -eq '/healthz') {
                    Write-YurunaHttpResponse -Stream $ssl -StatusCode 200 -StatusText 'OK' -Body 'ok' -ContentType 'text/plain'
                    continue
                }
                if ($path -match '^/v1/nas/(stash|pool)$') {
                    $name = $Matches[1]
                    $payload = Resolve-YurunaNasPayload -Name $name -ConfigPath $ConfigPath
                    if (-not $payload) {
                        Write-YurunaHttpResponse -Stream $ssl -StatusCode 503 -StatusText 'Service Unavailable' -Body "{`"ok`":false,`"error`":`"$name NAS is not configured or its vault credential is unset`"}"
                        continue
                    }
                    $json = ($payload | ConvertTo-Json -Compress -Depth 4)
                    Write-YurunaHttpResponse -Stream $ssl -StatusCode 200 -StatusText 'OK' -Body $json
                    continue
                }
                Write-YurunaHttpResponse -Stream $ssl -StatusCode 404 -StatusText 'Not Found' -Body '{"ok":false,"error":"unknown route"}'
            } catch {
                Write-Verbose "config-service connection error: $($_.Exception.Message)"
            } finally {
                if ($ssl)    { try { $ssl.Dispose() }    catch { $null = $_ } }
                if ($client) { try { $client.Dispose() } catch { $null = $_ } }
            }
        }
    } finally {
        try { $listener.Stop() } catch { $null = $_ }
    }
}

# --- REGION: -Serve: run the loop in this (detached) process
if ($Serve) {
    $cfgPath = Join-Path $TestRoot 'test.config.yml'
    Invoke-YurunaConfigServeLoop -ListenPort $Port -ConfigPath $cfgPath
    return
}

# --- REGION: Launcher

# Non-blocking TCP connect probe (used for both skip-if-healthy and readiness).
function Test-YurunaConfigPortAccepting {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$ProbePort, [int]$TimeoutMs = 1000)
    $probe = [System.Net.Sockets.TcpClient]::new()
    try {
        $iar = $probe.BeginConnect('127.0.0.1', $ProbePort, $null, $null)
        return ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $probe.Connected)
    } catch { return $false } finally { $probe.Dispose() }
}

# Health marker the runner / status server / operator can read to see the service
# is alive (turns "silently down" into a visible state). Best-effort.
function Write-YurunaConfigHealth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort liveness breadcrumb; a single small write, no actionable -WhatIf.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Up, [Parameter(Mandatory)][int]$HealthPort)
    try {
        $h = [ordered]@{ up = $Up; port = $HealthPort; checkedUtc = ([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) }
        [System.IO.File]::WriteAllText((Join-Path $RuntimeDir 'config-server.health'), ($h | ConvertTo-Json -Compress), [System.Text.UTF8Encoding]::new($false))
    } catch { Write-Verbose "config health write: $($_.Exception.Message)" }
}

# Surface the detached serve process's captured stderr/stdout IN PLAIN TEXT in this
# window so a start-up failure is diagnosable without opening config-server.err --
# which can carry ANSI/VT escapes (a "binary"-looking file). Strips escape sequences
# and stray control bytes; prints whatever readable text remains.
function Show-YurunaConfigServerLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $shownAny = $false
    foreach ($entry in @(@('config-server.err', 'stderr'), @('config-server.out', 'stdout'))) {
        $logFile = Join-Path $RuntimeDir $entry[0]
        if (-not (Test-Path -LiteralPath $logFile)) { continue }
        $raw = ''
        try { $raw = [System.IO.File]::ReadAllText($logFile) } catch { continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $clean = [regex]::Replace($raw, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')          # ANSI CSI (colour/cursor)
        $clean = $clean -replace "\x1b", ''                                       # stray ESC introducers
        $clean = [regex]::Replace($clean, "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", '')  # control bytes (keep tab/CR/LF)
        $clean = $clean.Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        $shownAny = $true
        Write-Warning "  --- Host Config Service $($entry[1]) ($($entry[0])) ---"
        foreach ($line in ($clean -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Warning "    $($line.TrimEnd())" }
        }
    }
    if (-not $shownAny) {
        Write-Warning "  (no captured output yet -- the process may have died before writing, or the port closed after it started)"
    }
}

# Skip-if-healthy: the runner re-ensures this every cycle, so a no-op when an
# instance is already serving keeps it cheap + non-disruptive. -Restart forces a
# replace (deploying new service code). Either way, a host reboot / crash that
# leaves no live listener falls through to a fresh launch -- self-healing.
$existingPid = $null
if (Test-Path -LiteralPath $PidFile) { try { $existingPid = [int](Get-Content -Raw -LiteralPath $PidFile).Trim() } catch { $existingPid = $null } }
$existingProc = if ($existingPid) { Get-Process -Id $existingPid -ErrorAction SilentlyContinue } else { $null }
if (-not $Restart -and $existingProc -and (Test-YurunaConfigPortAccepting -ProbePort $Port)) {
    Write-Output "Host Config Service already running (pid $existingPid) on :$Port; no action."
    Write-YurunaConfigHealth -Up $true -HealthPort $Port
    return
}
if ($existingProc -and (Test-PidFileIdentity -PidFile $PidFile -Process $existingProc)) {
    Write-Output "Replacing Host Config Service (pid $existingPid)..."
    Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
} elseif ($existingProc) {
    # Confirm identity before a force-kill: the OS can recycle config-server.pid
    # onto an unrelated process on a long-uptime host, and killing that would
    # take down whatever now owns the PID. Not ours -> leave it, clear the stale file.
    Write-Warning "PID $existingPid is not the Host Config Service (started after the PID file -- recycled onto an unrelated process); leaving it running and clearing the stale PID file."
}
if (Test-Path -LiteralPath $PidFile) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }

# Mint (idempotent) the CA + server leaf NOW, in the launcher, so the detached
# serve process only loads them and any minting error surfaces here.
[void](Initialize-YurunaConfigCA -Confirm:$false)
[void](New-YurunaConfigServerCertificate -Confirm:$false)

# Best-effort: open the host firewall for the config port on Windows (the raw
# TcpListener needs no urlacl/sslcert, but Defender's inbound filter still
# applies). Start-CachingProxy already runs elevated. Idempotent.
if ($IsWindows) {
    try {
        $ruleName = 'Yuruna Host Config Service'
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
        Write-Verbose "Opened inbound firewall for TCP/$Port ($ruleName)."
    } catch { Write-Verbose "firewall rule for config port failed (non-fatal): $($_.Exception.Message)" }
}

# Detach a serve process that outlives this launcher (mirrors Start-StatusService).
$scriptPath = $PSCommandPath
# Set when the detached child is confirmed dead right after launch, so the
# readiness probe below is skipped rather than burning the full timeout waiting
# for a port a dead process will never open.
$launchFailedEarly = $false
if ($IsWindows) {
    $stdinSink = Join-Path $RuntimeDir 'stdin.empty'
    if (-not (Test-Path -LiteralPath $stdinSink)) { [System.IO.File]::WriteAllBytes($stdinSink, [byte[]]@()) }
    $outFile = Join-Path $RuntimeDir 'config-server.out'
    $errFile = Join-Path $RuntimeDir 'config-server.err'
    $quoted  = '"' + $scriptPath + '"'
    $proc = Start-Process -FilePath 'pwsh' `
        -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-File', $quoted, '-Serve', '-Port', "$Port" `
        -RedirectStandardInput  $stdinSink `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError  $errFile `
        -PassThru
    Set-Content -Path $PidFile -Value $proc.Id
} else {
    $errFile = Join-Path $RuntimeDir 'config-server.err'
    $outFile = Join-Path $RuntimeDir 'config-server.out'
    & bash -c "set -m; nohup pwsh -NoProfile -File '$scriptPath' -Serve -Port $Port </dev/null >'$outFile' 2>'$errFile' & echo `$!" |
        Set-Variable -Name bgPid
    # The child echoes its PID via `echo $!`. Verify that value parsed to an
    # integer AND the process is still alive right after launch: a serve process
    # that dies immediately (module-import error, port already bound) never opens
    # $Port, so without this check we would record a PID file pointing at a dead
    # process and then burn the full readiness timeout on a port that will never
    # accept. If it is already gone, surface the captured startup log now.
    $bgPidInt = 0
    if (-not [int]::TryParse("$bgPid".Trim(), [ref]$bgPidInt) -or
        -not (Get-Process -Id $bgPidInt -ErrorAction SilentlyContinue)) {
        Write-Warning "Detached config service did not survive launch (pid '$bgPid'). Captured output:"
        Show-YurunaConfigServerLog -RuntimeDir $RuntimeDir
        $launchFailedEarly = $true
    } else {
        Set-Content -Path $PidFile -Value $bgPidInt
    }
}

# --- REGION: Verify the service is accepting on $Port (TCP connect probe)
if ($launchFailedEarly) {
    Write-YurunaConfigHealth -Up $false -HealthPort $Port
    Write-Warning "Full logs: $(Join-Path $RuntimeDir 'config-server.err') (stderr), $(Join-Path $RuntimeDir 'config-server.out') (stdout)."
    return
}
$deadline = [DateTime]::UtcNow.AddSeconds($script:ConfigServiceReadyTimeoutSeconds)
$ready = $false
while ([DateTime]::UtcNow -lt $deadline) {
    if (Test-YurunaConfigPortAccepting -ProbePort $Port) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}
Write-YurunaConfigHealth -Up $ready -HealthPort $Port
if ($ready) {
    Write-Output "Host Config Service up on :$Port (mTLS; serves NAS creds to this host's VMs)."
} else {
    Write-Warning "Host Config Service process started but port $Port is not accepting after $script:ConfigServiceReadyTimeoutSeconds s."
    Write-Warning "Captured output from the detached service (plain text):"
    Show-YurunaConfigServerLog -RuntimeDir $RuntimeDir
    Write-Warning "Full logs: $(Join-Path $RuntimeDir 'config-server.err') (stderr), $(Join-Path $RuntimeDir 'config-server.out') (stdout)."
}
