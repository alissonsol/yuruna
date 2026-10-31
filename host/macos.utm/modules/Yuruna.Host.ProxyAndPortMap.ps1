<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42c9a53a-2f6e-4b3f-9f81-3316fd505899
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver proxy portmap forwarder
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
# networksetup is sudo-only for writes. Read paths don't need sudo, so the
# backup capture can happen before the sudo check and surface a clearer
# error if sudo is missing. Marker file at $HOME/.yuruna/host-proxy.managed
# flags "this state was set by yuruna" -- same role as the WinINet
# YurunaProxyManaged registry value.

function Get-MacProxyMarkerPath {
    <#
    .SYNOPSIS
        Return the path of the yuruna-managed macOS proxy marker file.
    #>
        $stateDir = Join-Path $HOME '.yuruna'
    return (Join-Path $stateDir 'host-proxy.managed')
}

<#
.SYNOPSIS
    Returns true if the marker file says yuruna set the macOS proxy.
#>
function Test-MacProxyIsYurunaManaged {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return (Test-Path -LiteralPath (Get-MacProxyMarkerPath))
}

<#
.SYNOPSIS
    Return the macOS network service for the default-route interface.
#>
function Get-MacDefaultRouteInterface {
    <#
    .SYNOPSIS
        Reads the default route interface with DNS disabled and a bounded probe.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $result = Invoke-BoundedNativeCommand -FilePath '/sbin/route' -ArgumentList @('-n', 'get', 'default') -TimeoutSeconds 5
    if (-not $result.Started -or $result.TimedOut -or $result.ExitCode -ne 0 -or $result.DrainTimedOut -or $result.OutputTruncated) { return $null }
    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^\s*interface:\s*(\S+)\s*$') { return $matches[1] }
    }
    return $null
}

function Get-MacActiveNetworkService {
    <# .SYNOPSIS
        Resolves the network service for the bounded default-route interface.
    #>
    # `route -n get default` -> default-route interface (en0).
    # `networksetup -listnetworkserviceorder` pairs service names to
    # Device: entries; we match en0 back to "Wi-Fi" / "Ethernet" / etc.
    try {
        $iface = Get-MacDefaultRouteInterface
        if (-not $iface) { return $null }
        $orderOut = & networksetup -listnetworkserviceorder 2>$null
        $lastService = $null
        foreach ($line in $orderOut) {
            if ($line -match '^\(\d+\)\s+(.+?)\s*$') { $lastService = $matches[1]; continue }
            if ($line -match '^\(Hardware Port:.*Device:\s*([^\)]+)\)') {
                if ($matches[1].Trim() -eq $iface) { return $lastService }
            }
        }
    } catch {
        Write-Verbose "Get-MacActiveNetworkService failed: $($_.Exception.Message)"
    }
    return $null
}

<#
.SYNOPSIS
    Read current macOS networksetup proxy state into a backup hashtable.
#>
function Read-MacProxyState {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$NetworkService)
    if (Test-MacProxyIsYurunaManaged) {
        return @{
            platform            = 'macos'
            networkService      = $NetworkService
            webProxy            = @{ Enabled = 'No'; Server = $null; Port = $null }
            secureWebProxy      = @{ Enabled = 'No'; Server = $null; Port = $null }
            bypassDomains       = @()
            yurunaResetSnapshot = $true
        }
    }
    <#
    .SYNOPSIS
        ConvertFrom-NetworksetupBlock.
    #>
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
    $webOut = & networksetup -getwebproxy       $NetworkService 2>$null
    $sslOut = & networksetup -getsecurewebproxy $NetworkService 2>$null
    $bypOut = & networksetup -getproxybypassdomains $NetworkService 2>$null
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

<#
.SYNOPSIS
    Cache sudo credentials when the current user is not root.
#>
function Invoke-MacElevationIfNeeded {
    if ((Get-UtmCurrentUid) -eq '0') { return }
    # Ask the machine before asking a person: an already-warm credential needs
    # neither the notice nor the prompt, and `sudo -n -v` refreshes it
    # silently. Bounded, so a sudo stuck on name or account lookup reads as
    # "not warm" instead of holding the caller.
    $warm = Invoke-UtmHostTool -Tool 'sudo' -ArgumentList @('-n', '-v') -TimeoutSeconds 10
    if ((Test-UtmBoundedResultComplete -Result $warm) -and $warm.ExitCode -eq 0) { return }
    # sudo reads its password from /dev/tty, which neither a closed stdin nor
    # -NonInteractive can redirect. The proxy teardown paths call this
    # unconditionally and run inside children whose console belongs to a parent,
    # so a bare `sudo -v` there raises a prompt nothing displays and nothing
    # answers, and the step waits forever. Fail with the remedy instead.
    if (-not (Test-YurunaCanPrompt)) {
        throw ((Format-YurunaOperatorMessage -Key 'exceptions.host_ce186b06237fbe4d'))
    }
    Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_b5a36047ba736ed1') -InformationAction Continue
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_674dd7c6c0448e92')
    }
}

<#
.SYNOPSIS
    Run networksetup with sudo iff not already root.
#>
function Invoke-MacNetworksetup {
    param([string[]]$Arguments)
    if ((Get-UtmCurrentUid) -eq '0') {
        & networksetup @Arguments | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_653d228ea35c1f2c' -Arguments @{ join = "$($Arguments -join ' ')"; lASTEXITCODE = "$LASTEXITCODE" }) }
        return
    }
    # -n, because Invoke-MacElevationIfNeeded has already established that root
    # is reachable and every caller runs a short sequence of these. If the
    # timestamp expires mid-sequence the honest outcome is an exit code: a
    # password prompt here lands on a console the caller may not own, and the
    # operator was told they would be asked once.
    & sudo -n networksetup @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d13b1c09a5291094' -Arguments @{ join = "$($Arguments -join ' ')"; lASTEXITCODE = "$LASTEXITCODE" }) }
}

<#
.SYNOPSIS
    Apply the proxy via networksetup and write the yuruna marker.
#>
function Set-MacHostProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][hashtable]$ProxyParts,
        [Parameter(Mandatory)][string]$NetworkService
    )
    $h = $ProxyParts.Host; $p = $ProxyParts.Port
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_79c77d5e8acb27cf' -Arguments @{ networkService = "$NetworkService" }), (Format-YurunaOperatorMessage -Key 'host.operator_ed3c547320b2c6d6' -Arguments @{ h = "${h}"; p = "${p}" }))) {
        return
    }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, $h, [string]$p)
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'on')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'localhost', '127.0.0.1', '*.local', '169.254/16', '192.168.64.*')
    $markerPath = Get-MacProxyMarkerPath
    $markerDir  = Split-Path -Parent $markerPath
    if (-not (Test-Path -LiteralPath $markerDir)) { New-Item -ItemType Directory -Path $markerDir -Force | Out-Null }
    Set-Content -LiteralPath $markerPath -Value $NetworkService -NoNewline -Encoding ascii
}

<#
.SYNOPSIS
    Restore macOS networksetup proxy state from the backup hashtable.
#>
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
    if ($State.bypassDomains -and $State.bypassDomains.Count -gt 0) {
        Invoke-MacNetworksetup (@('-setproxybypassdomains', $svc) + @($State.bypassDomains))
    } else {
        Invoke-MacNetworksetup @('-setproxybypassdomains', $svc, 'Empty')
    }
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Turn web and securewebproxy off without restoring backup.
#>
function Disable-MacHostProxy {
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

<#
.SYNOPSIS
    Aggressively wipe networksetup proxy state and the marker file.
#>
function Remove-MacHostProxy {
    # --- REGION: https://yuruna.link/42d69dfa-0021
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Module-private helper; public Remove-HostProxy gates ShouldProcess.')]
    [CmdletBinding()]
    param([string]$NetworkService)
    if (-not $NetworkService) { $NetworkService = Get-MacActiveNetworkService }
    if (-not $NetworkService) { return }
    Invoke-MacNetworksetup @('-setwebproxy',            $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setsecurewebproxy',      $NetworkService, '0.0.0.0', '0')
    Invoke-MacNetworksetup @('-setproxybypassdomains',  $NetworkService, 'Empty')
    Invoke-MacNetworksetup @('-setwebproxystate',       $NetworkService, 'off')
    Invoke-MacNetworksetup @('-setsecurewebproxystate', $NetworkService, 'off')
    $markerPath = Get-MacProxyMarkerPath
    if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
}

# --- REGION: Port-map helpers
# --- REGION: Start-CachingProxyServiceForwarder
function Start-CachingProxyServiceForwarder {
    <#
    .SYNOPSIS
        Launches (or stops) the caching-proxy-service TCP forwarder on the Mac host.

    .DESCRIPTION
        Exposes the Shared-NAT caching-proxy-service VM to REMOTE LAN hosts: it binds
        a cache port on the host's LAN IP and tunnels to $CacheIp on the
        192.168.64.0/24 vmnet subnet, so machines elsewhere on the LAN can use
        the cache. Same-Mac UTM guests do NOT need this -- on macOS 26 every
        vmnet-shared VM joins one bridge (192.168.64.1) and guests reach a
        sibling VM's 192.168.64.x IP directly. (An older belief that shared-NAT
        blocks guest-to-guest ARP on 192.168.64.0/24 did not reproduce there.)

        Start-CachingProxyServiceForwarder spawns Start-CachingProxyServiceForwarder.ps1
        as a detached `pwsh` subprocess that binds :3128 on the host and
        tunnels to $CacheIp:3128. Detached so the forwarder outlives
        Start-CachingProxyServiceVM.ps1 (it survives the launcher exiting -- it is
        reparented to launchd -- but any Remove-PortMap still tears it down).

        PID is written to $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid.
        Stop-CachingProxyServiceForwarder reads it and sends SIGTERM.
        Get-CachingProxyServiceForwarder reports liveness without signaling.

        Returns $true when the forwarder is verified listening (Start),
        terminated (Stop), or currently running (Get).

    .PARAMETER CacheIp
        IP of the caching-proxy-service VM (Start-CachingProxyServiceForwarder only). Typically
        192.168.64.X discovered by Start-CachingProxyServiceVM.ps1's subnet probe.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # 0 sentinel -- when unspecified, host port == VM port (the common case;
    # proxy/Grafana/etc.). Split ports kick in for SSH (8022 -> 22) and any
    # other future host:VM remap. Pidfile name uses HOST port (predictable;
    # what `lsof -i :<host>` would show).
    if ($VMPort -eq 0) { $VMPort = $Port }
    # Forwarder script lives at host/macos.utm/Start-CachingProxyServiceForwarder.ps1.
    # Use $script:HostFolder (set at module load) instead of $PSScriptRoot:
    # the module-scoped variable is anchored to the .psm1's directory, so
    # the lookup is independent of how the function is dispatched.
    $forwarderScript = Join-Path $script:HostFolder "Start-CachingProxyServiceForwarder.ps1"
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e22e1a85f32b3a0b' -Arguments @{ forwarderScript = "$forwarderScript" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${Port} -> ${CacheIp}:${VMPort}", (Format-YurunaOperatorMessage -Key 'host.operator_67195d8019562611'))) {
        return $false
    }
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Pidfile/log are PER PORT so concurrent forwarders (squid :3128,
    # Grafana :3000, etc.) never fight over the same path. Port-named
    # files make discovery and selective teardown trivial.
    $pidFile = Join-Path $stateDir "forwarder.$Port.pid"
    $logFile = Join-Path $stateDir "forwarder.$Port.log"

    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_c22cbc5129006aa6' -Arguments @{ port = "${Port}"; cacheIp = "${CacheIp}"; vMPort = "${VMPort}"; proxyTag = "${proxyTag}" }) -InformationAction Continue
    # RedirectStandard* is required: without them pwsh inherits the
    # parent TTY and dies when Start-CachingProxyServiceVM.ps1 exits. The
    # forwarder's own log gets live traffic; stdout/stderr go to files.
    $forwarderParams = @{ CacheIp = $CacheIp; Port = $Port; VMPort = $VMPort; PidFile = $pidFile; LogFile = $logFile }
    if ($PrependProxyV1) { $forwarderParams.PrependProxyV1 = $true }
    $parameterJson = ConvertTo-Json -InputObject $forwarderParams -Compress
    $parameterBlob = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parameterJson))
    $escapedScript = $forwarderScript -replace "['\u2018\u2019]", '$0$0'
    $command = '$p = ConvertFrom-Json -AsHashtable -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''{0}''))); & ''{1}'' @p' -f $parameterBlob, $escapedScript
    $procArgs = @('-NoProfile', '-NoLogo', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    # See https://yuruna.link/42e220c4-0004
    $isRoot = ((Get-UtmCurrentUid) -eq '0')
    $needsSudo = ($Port -lt 1024) -and (-not $isRoot)

    # If the privileged forwarder is already running (root-owned, started by
    # Start-CachingProxyServiceVM.ps1 which called `sudo -v` first), leave it alone.
    # Killing a root process requires sudo credentials that the caller
    # (e.g. Start-TestRunner) may not have cached -- and the correct CacheIp
    # is already baked into the running process. Only restart if crashed.
    if ($needsSudo -and (Get-CachingProxyServiceForwarder -Port $Port)) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_fac89af7ceb85a93' -Arguments @{ port = "${Port}" }) -InformationAction Continue
        return $true
    }

    # A failed stop retains the pidfile and must not start a second listener.
    if (-not (Stop-CachingProxyServiceForwarder -Port $Port -Quiet)) { return $false }

    # -n on the sudo spawn: this is a DETACHED process whose stdout and stderr
    # are redirected to files, so a password prompt would be written to a log
    # and the forwarder would sit there unbound until something noticed. With -n
    # a missing credential fails immediately and the bind wait below reports it.
    $spawnFile = if ($needsSudo) { 'sudo' } else { 'pwsh' }
    $spawnArgs = if ($needsSudo) { @('-n', '-E', 'pwsh') + $procArgs } else { $procArgs }

    try {
        $proc = Start-Process -FilePath $spawnFile `
            -ArgumentList $spawnArgs `
            -RedirectStandardOutput "$stateDir/forwarder.$Port.stdout.log" `
            -RedirectStandardError  "$stateDir/forwarder.$Port.stderr.log" `
            -PassThru
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_368bbdea275958b3' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    # Wait briefly for the listener to bind and the pidfile to be written.
    # 3s is generous; pwsh startup + TcpListener.Start() is sub-second.
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect("127.0.0.1", $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { (Get-Content $pidFile -Raw).Trim() } else { $proc.Id }
                $upMsg = if ($Port -eq $VMPort) {
                    "Forwarder up (pid $actualPid). Guests should use http://192.168.64.1:${Port}"
                } else {
                    "Forwarder up (pid $actualPid): host :${Port} -> ${CacheIp}:${VMPort}"
                }
                Write-Information "  $upMsg" -InformationAction Continue
                return $true
            }
        } catch {
            # Expected while the child is still booting (pwsh startup +
            # TcpListener.Start). Retry until the deadline.
            $null = $_
        } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9b8f576034f602fb' -Arguments @{ id = "$($proc.Id)"; port = "${Port}" })
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0b768b57cdd33d5e' -Arguments @{ stateDir = "$stateDir" })
    # A non-answering child may still be half-bound (listener up, connect
    # racing) or wedged. Tear it down so it is not orphaned holding the
    # port past our return. Prefer the pidfile-driven, identity-verified
    # stop (matches Start-CachingProxyServiceForwarder.ps1, honors root ownership);
    # if the child never wrote its pidfile, signal the spawned pid directly.
    if (Test-Path $pidFile) {
        [void](Stop-CachingProxyServiceForwarder -Port $Port -Quiet)
    } else {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop }
        catch { Write-Verbose "Could not stop orphaned forwarder pid $($proc.Id): $_" }
    }
    return $false
}

<#
.SYNOPSIS
    Terminates the host-side caching-proxy-service TCP forwarder if it is running.

.DESCRIPTION
    Reads $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid and verifies the
    PID belongs to Start-CachingProxyServiceForwarder.ps1 (via /bin/ps -o
    command=) before signaling -- a stale pidfile pointing at an
    unrelated process must NOT be killed. Sends SIGTERM and waits up to
    2s; escalates to SIGKILL if no response. The pidfile is removed on
    every success path and on stale-pidfile detection so the next Start
    call is clean.

.PARAMETER Quiet
    Suppress the informational Write-Output lines. Start-CachingProxyServiceForwarder
    passes this when preflight-stopping a stale forwarder so the happy
    path stays quiet.

.OUTPUTS
    [bool] $true on any exit where the pidfile is in a coherent state
    (process stopped or never running); $false when the recorded pid could
    not be read within its time limit, in which case the pidfile is kept and
    nothing was signaled.
#>
function Stop-CachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [int]$Port = $(Get-CachingProxyServicePort -Scheme http),
        [switch]$Quiet
    )
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) {
        if (-not $Quiet) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_51cfbd5426e42f8d') -InformationAction Continue }
        return $true
    }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2b5a075a69fb02ea' -Arguments @{ pidFile = "$pidFile"; forwarderPid = "$forwarderPid" }) }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    # Verify the process looks like our forwarder before killing.
    # -o command= prints full argv so we can match
    # Start-CachingProxyServiceForwarder.ps1 and avoid killing an unrelated pid
    # that matches a stale pidfile. Bounded: a read that did not finish proves
    # nothing either way, so the pidfile is kept and nothing is signaled.
    $identity = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'command=') -TimeoutSeconds 5
    if (-not (Test-UtmBoundedResultComplete -Result $identity)) {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.forwarder_identity_unverified' -Arguments @{ forwarderPid = "$forwarderPid" }) }
        return $false
    }
    $cmd = "$($identity.StdOut)".Trim()
    if ($identity.ExitCode -ne 0 -or -not $cmd) {
        if (-not $Quiet) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_7934de6bf4f9bbe6' -Arguments @{ forwarderPid = "$forwarderPid" }) -InformationAction Continue }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if ($cmd -notmatch 'Start-CachingProxyServiceForwarder\.ps1') {
        if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5c93ad943c43270c' -Arguments @{ forwarderPid = "$forwarderPid"; cmd = "$cmd" }) }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess("pid $forwarderPid (Start-CachingProxyServiceForwarder.ps1)", (Format-YurunaOperatorMessage -Key 'host.operator_378bec0a86550e8e'))) {
        return $false
    }
    if (-not $Quiet) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_0dbaee5477554260' -Arguments @{ forwarderPid = "$forwarderPid" }) -InformationAction Continue }
    # /bin/kill sends SIGTERM (default). PowerShell 7's Stop-Process on
    # Unix maps to Process.Kill() == SIGKILL unconditionally, bypassing
    # graceful shutdown -- hence the external binary for TERM-then-KILL.
    # Port 80's forwarder is root-owned (spawned via sudo); a regular user
    # cannot signal it -- detect and escalate via sudo kill if needed.
    $owner     = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'user=') -TimeoutSeconds 5
    $procOwner = "$($owner.StdOut)".Trim()
    $meIsRoot  = ((Get-UtmCurrentUid) -eq '0')
    $useSudo   = ($procOwner -eq 'root') -and (-not $meIsRoot)
    # Every signal is bounded. Through sudo it always carries -n: this runs
    # inside teardown paths whose console belongs to a caller, and sudo takes
    # its password from /dev/tty regardless of how stdin was set up -- so a
    # cold credential here would stall the teardown on a prompt nobody sees,
    # rather than reporting that root was unavailable.
    $sendSignal = {
        param([string[]]$SignalArgument)
        if ($useSudo) {
            return (Invoke-UtmHostTool -Tool 'sudo' -ArgumentList (@('-n', [string]$script:UtmHostTool['kill']) + $SignalArgument + @("$forwarderPid")) -TimeoutSeconds 5)
        }
        return (Invoke-UtmHostTool -Tool 'kill' -ArgumentList ($SignalArgument + @("$forwarderPid")) -TimeoutSeconds 5)
    }
    $term = & $sendSignal @()
    if ($useSudo -and -not ((Test-UtmBoundedResultComplete -Result $term) -and $term.ExitCode -eq 0) -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7bbd97967255a376' -Arguments @{ forwarderPid = "$forwarderPid" })
    }
    $exitWait = New-YurunaDeadline -TotalMilliseconds 2000
    while (Wait-UtmInterval -Milliseconds 100 -Deadline $exitWait) {
        $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
        if ((Test-UtmBoundedResultComplete -Result $alive) -and $alive.ExitCode -ne 0) {
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    if (-not $Quiet) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fd3a364b69ecd8d4' -Arguments @{ forwarderPid = "$forwarderPid" }) }
    $kill = & $sendSignal @('-9')
    if ($useSudo -and -not ((Test-UtmBoundedResultComplete -Result $kill) -and $kill.ExitCode -eq 0) -and -not $Quiet) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_157f9a28bfef1ebf' -Arguments @{ forwarderPid = "$forwarderPid" })
    }
    Start-Sleep -Milliseconds 200
    $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
    if (-not (Test-UtmBoundedResultComplete -Result $alive) -or $alive.ExitCode -eq 0) {
        return $false
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Reports whether the host-side caching-proxy-service TCP forwarder is running.

.DESCRIPTION
    Pure observer -- never signals, never removes files. Returns $true
    iff $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid exists, parses as
    an int, and refers to a live process (via /bin/ps). Does NOT verify
    the process is actually our forwarder; Stop-CachingProxyServiceForwarder
    handles that stricter identity check on the write path.

.OUTPUTS
    [bool] $true if the pidfile points at a live process, $false
    otherwise (missing pidfile, malformed content, or dead pid).
#>
function Get-CachingProxyServiceForwarder {
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$Port = $(Get-CachingProxyServicePort -Scheme http))
    $pidFile = Join-Path $HOME "yuruna/image/caching-proxy-service/forwarder.$Port.pid"
    if (-not (Test-Path $pidFile)) { return $false }
    $forwarderPid = (Get-Content $pidFile -Raw).Trim()
    if (-not ($forwarderPid -as [int])) { return $false }
    $alive = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$forwarderPid", '-o', 'pid=') -TimeoutSeconds 5
    return [bool]((Test-UtmBoundedResultComplete -Result $alive) -and $alive.ExitCode -eq 0)
}

<#
.SYNOPSIS
    Stop every caching-proxy-service port forwarder the host currently has.

.DESCRIPTION
    Enumerates $HOME/yuruna/image/caching-proxy-service/forwarder.<Port>.pid entries
    and sends SIGTERM to each (SIGKILL escalation per port via
    Stop-CachingProxyServiceForwarder). Missing directory / no pidfiles is a
    no-op; safe to call even when nothing is running.

    The host-contract `Add-PortMap` / `Remove-PortMap` (declared in
    host/Yuruna.Host.Contract.psm1, implemented per platform) dispatch to
    Start-CachingProxyServiceForwarder + this function on macOS.

.OUTPUTS
    [int[]] -- ports whose forwarder was stopped (may be empty).
#>
function Stop-AllCachingProxyServiceForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int[]], [System.Object[]])]
    param([switch]$Quiet)
    $stateDir = Join-Path $HOME "yuruna/image/caching-proxy-service"
    if (-not (Test-Path $stateDir)) { return @() }
    $stopped = @()
    # Glob forwarder.<N>.pid; BaseName strips ".pid" so the regex only
    # needs the middle token.
    Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            if ($_.BaseName -match '^forwarder\.(\d+)$') {
                $portInt = [int]$matches[1]
                if ($PSCmdlet.ShouldProcess("port $portInt", (Format-YurunaOperatorMessage -Key 'host.operator_36b84d687b0706c6'))) {
                    if (Stop-CachingProxyServiceForwarder -Port $portInt -Quiet:$Quiet) { $stopped += $portInt }
                }
            }
        }
    return ,$stopped
}

<#
.SYNOPSIS
    The host port forwarders this driver started, as recorded by their
    pidfiles: host port, target address and port, and whether the pid is
    verified to still be that forwarder.
.DESCRIPTION
    Read-only. Each forwarder.<Port>.pid is read, and the recorded pid's
    command line is read back through one bounded `ps`; OwnerVerified is
    $true only when that command line is the forwarder script, which is also
    where the target address and port are read from. A pidfile whose pid
    cannot be read or no longer runs the forwarder is still reported, with
    OwnerVerified $false, because an unverified mapping is collateral a
    caller must account for rather than silently drop.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline) bounding the reads.
.OUTPUTS
    [pscustomobject] per pidfile: HostPort, TargetAddress, TargetPort,
    OwnerPid, OwnerVerified, Origin ('forwarder-pidfile').
#>
function Get-PortMapTarget {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $stateDir = Join-Path $HOME 'yuruna/image/caching-proxy-service'
    if (-not [System.IO.Directory]::Exists($stateDir)) { return }
    foreach ($file in @([System.IO.Directory]::GetFiles($stateDir, 'forwarder.*.pid') | Sort-Object)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($file)
        if ($name -notmatch '^forwarder\.(\d+)$') { continue }
        $hostPort = [int]$Matches[1]
        $ownerPid = 0
        $pidText = ''
        try { $pidText = [System.IO.File]::ReadAllText($file).Trim() } catch { $pidText = '' }
        [void][int]::TryParse($pidText, [ref]$ownerPid)
        $targetAddress = ''
        $targetPort = 0
        $verified = $false
        if ($ownerPid -gt 0) {
            $read = Invoke-UtmHostTool -Tool 'ps' -ArgumentList @('-p', "$ownerPid", '-o', 'command=') -TimeoutSeconds 5 -Deadline $Deadline
            $command = if ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { "$($read.StdOut)".Trim() } else { '' }
            if ($command -match 'Start-CachingProxyServiceForwarder\.ps1') {
                $verified = $true
                if ($command -match '-CacheIp\s+(\S+)') { $targetAddress = $Matches[1] }
                if ($command -match '-VMPort\s+(\d+)') { $targetPort = [int]$Matches[1] }
                elseif ($command -match '-Port\s+(\d+)') { $targetPort = [int]$Matches[1] }
            }
        }
        [pscustomobject]@{
            PSTypeName    = 'Yuruna.PortMapTarget'
            HostPort      = $hostPort
            TargetAddress = $targetAddress
            TargetPort    = $targetPort
            OwnerPid      = $ownerPid
            OwnerVerified = $verified
            Origin        = 'forwarder-pidfile'
        }
    }
}
