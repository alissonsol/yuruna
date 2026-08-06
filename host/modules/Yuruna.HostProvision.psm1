<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42b8e6a4-3d17-4c92-8f05-6a1b9d2e7c40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host provisioning new-vm get-image
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

# Shared per-guest provisioning helpers for the host drivers. Scope split,
# the CommandInfo/scriptblock injection rule, and why this module owns its own
# imports: docs/guest-image-setup.md#per-guest-provisioning-yurunahostprovisionpsm1
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1')       -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.CachingProxyService.psm1') -DisableNameChecking -ErrorAction SilentlyContinue
# Verify the by-name dependencies resolved at LOAD time, so a broken/moved module surfaces here
# instead of on the one caching-proxy-service probe per cycle (where it looks like a cache outage).
foreach ($dep in @('Get-CachingProxyServicePort', 'Test-IpAddress', 'Format-IpUrlHost', 'Read-CachingProxyServiceState')) {
    if (-not (Get-Command -Name $dep -ErrorAction SilentlyContinue)) {
        Write-Warning "Yuruna.HostProvision: required command '$dep' is not available after importing Yuruna.Common / Test.CachingProxyService -- the caching-proxy-service probe will fail. Verify those modules loaded correctly."
    }
}

function Invoke-PerGuestNewVm {
    <#
    .SYNOPSIS
        Run a guest's per-host New-VM.ps1 as a child process and map its exit
        code to a { success; errorMessage } result.
    .DESCRIPTION
        The host subdirectory under <RepoRoot>/ (e.g. 'host\windows.hyper-v',
        'host/ubuntu.kvm', 'host/macos.utm') is the SOLE platform variable, so
        it is a plain -HostSubdir string param rather than an injected
        scriptblock; each driver's New-VM wrapper supplies its constant value.

        -CachingProxyServiceUrl, -Username, -Hostname, -MemoryStartupBytes and -Cores
        are forwarded to the per-guest script only when (a) the caller bound them
        AND (b) the target script declares them -- this lets the contract grow
        new pass-through arguments without breaking guests (e.g. windows.11,
        caching-proxy-service, macos.26) that do not consume them. A bound argument the
        script does not declare is surfaced on the Verbose stream so the operator
        notices a dropped planner cascade.
    .OUTPUTS
        [hashtable] @{ success = [bool]; errorMessage = [string] }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostSubdir,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyServiceUrl,
        [string]$Username,
        [string]$Hostname,
        # Planner-cascaded VM sizing (variables.memoryStartupBytes /
        # variables.cores). Strings here (the cascade is string-valued); the
        # per-guest New-VM.ps1 parses + applies them. Forwarded under the same
        # declare-or-drop rule as -Username/-Hostname.
        [string]$MemoryStartupBytes,
        [string]$Cores
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create VM ($GuestKey)")) { return @{ success = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path $HostSubdir (Join-Path $GuestKey 'New-VM.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; errorMessage = "New-VM.ps1 not found at: $scriptPath" }
    }
    $childArgs = @('-VMName', $VMName)
    $scriptAcceptsProxy    = $false
    $scriptAcceptsUsername = $false
    $scriptAcceptsHostname = $false
    $scriptAcceptsMemory   = $false
    $scriptAcceptsCores    = $false
    try {
        $cmdInfo = Get-Command -Name $scriptPath -ErrorAction Stop
        if ($cmdInfo.Parameters) {
            $scriptAcceptsProxy    = [bool]$cmdInfo.Parameters.ContainsKey('CachingProxyServiceUrl')
            $scriptAcceptsUsername = [bool]$cmdInfo.Parameters.ContainsKey('Username')
            $scriptAcceptsHostname = [bool]$cmdInfo.Parameters.ContainsKey('Hostname')
            $scriptAcceptsMemory   = [bool]$cmdInfo.Parameters.ContainsKey('MemoryStartupBytes')
            $scriptAcceptsCores    = [bool]$cmdInfo.Parameters.ContainsKey('Cores')
        }
    } catch {
        $scriptAcceptsProxy    = $false
        $scriptAcceptsUsername = $false
        $scriptAcceptsHostname = $false
        $scriptAcceptsMemory   = $false
        $scriptAcceptsCores    = $false
    }
    if ($PSBoundParameters.ContainsKey('CachingProxyServiceUrl') -and $scriptAcceptsProxy) {
        $childArgs += @('-CachingProxyServiceUrl', $CachingProxyServiceUrl)
    }
    if ($PSBoundParameters.ContainsKey('Username') -and $Username -and $scriptAcceptsUsername) {
        $childArgs += @('-Username', $Username)
    } elseif ($PSBoundParameters.ContainsKey('Username') -and $Username -and -not $scriptAcceptsUsername) {
        Write-Verbose "Cascaded -Username '$Username' NOT forwarded: $scriptPath does not declare a -Username parameter."
    }
    if ($PSBoundParameters.ContainsKey('Hostname') -and $Hostname -and $scriptAcceptsHostname) {
        $childArgs += @('-Hostname', $Hostname)
    } elseif ($PSBoundParameters.ContainsKey('Hostname') -and $Hostname -and -not $scriptAcceptsHostname) {
        Write-Verbose "Cascaded -Hostname '$Hostname' NOT forwarded: $scriptPath does not declare a -Hostname parameter."
    }
    if ($PSBoundParameters.ContainsKey('MemoryStartupBytes') -and $MemoryStartupBytes -and $scriptAcceptsMemory) {
        $childArgs += @('-MemoryStartupBytes', $MemoryStartupBytes)
    } elseif ($PSBoundParameters.ContainsKey('MemoryStartupBytes') -and $MemoryStartupBytes -and -not $scriptAcceptsMemory) {
        Write-Verbose "Cascaded -MemoryStartupBytes '$MemoryStartupBytes' NOT forwarded: $scriptPath does not declare a -MemoryStartupBytes parameter."
    }
    if ($PSBoundParameters.ContainsKey('Cores') -and $Cores -and $scriptAcceptsCores) {
        $childArgs += @('-Cores', $Cores)
    } elseif ($PSBoundParameters.ContainsKey('Cores') -and $Cores -and -not $scriptAcceptsCores) {
        Write-Verbose "Cascaded -Cores '$Cores' NOT forwarded: $scriptPath does not declare a -Cores parameter."
    }
    Write-Verbose "Running: $scriptPath $($childArgs -join ' ')"
    $output = & pwsh -NoProfile -File $scriptPath @childArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Information $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success = $false; errorMessage = "New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success = $true; errorMessage = $null }
}

function Write-GetImageLine {
    <#
    .SYNOPSIS
        Echo a Get-Image progress line to the console and, when a per-cycle HTML
        log is open, append its HTML-encoded copy to that log.
    .DESCRIPTION
        The console write is unconditional. The HTML-log append happens only
        while global:__YurunaLogFile holds the runner's per-cycle log handle;
        the line is HtmlEncode'd first so guest output containing <, >, or &
        cannot break the surrounding log markup, and the append is best-effort
        (a transient file error does not fail the caller).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaLogFile is the per-cycle HTML log handle, set/cleared by the runner; intentionally process-wide.')]
    [CmdletBinding()]
    param([string]$Line)
    Microsoft.PowerShell.Utility\Write-Host $Line
    if ($global:__YurunaLogFile) {
        [System.Net.WebUtility]::HtmlEncode($Line) |
            Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    }
}

function Invoke-WaitVmIp {
    <#
    .SYNOPSIS
        Poll the driver's IP resolver until an address is discovered or the
        timeout expires.
    .DESCRIPTION
        -ResolveVmIp is the driver's Get-VMIp passed as a CommandInfo (the
        driver runs Get-Command Get-VMIp in ITS scope). The discovery is
        driver-private and unresolvable by name from this module's session
        state, so it must be injected rather than called directly.

        The FIRST address a booting guest is seen at is frequently not the one
        it keeps. A guest's DHCP client identity is derived from its machine-id
        and hostname by default, and cloud-init changes both -- so
        systemd-networkd re-requests under a new identity, the server treats it
        as a different client, and the guest moves to another address, two or
        three times within the first seconds. Returning on the first answer
        therefore hands the caller an address the guest is about to abandon, and
        every artifact built from it (a port-forwarder, a probe target, a
        published URL) is wrong for the rest of the run.

        So a candidate has to hold still before it is returned: once one is
        seen, resolution keeps going for -StableForSeconds, and any change
        restarts that window. The cost is bounded and small next to a guest boot;
        the whole settle stays inside the caller's -TimeoutSeconds budget, and a
        budget too small for it degrades to the old first-answer behavior rather
        than overrunning.
    .PARAMETER StableForSeconds
        How long a candidate must stay unchanged before it is trusted. 0 returns
        the first answer, which is what a caller wants only when it re-resolves
        on its own afterwards.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3,
        [int]$StableForSeconds = 8,
        [Parameter(Mandatory)]$ResolveVmIp
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = & $ResolveVmIp -VMName $VMName
        if ($candidate) {
            $settled = [string]$candidate
            if ($StableForSeconds -le 0) { return $settled }
            $settleUntil = (Get-Date).AddSeconds($StableForSeconds)
            while ((Get-Date) -lt $settleUntil -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($PollSeconds, $StableForSeconds)))
                $again = & $ResolveVmIp -VMName $VMName
                # Only a DIFFERENT address restarts the window. A resolver that
                # momentarily returns nothing is not evidence the guest moved --
                # it is the lease file being rewritten under us -- so an empty
                # answer leaves the current candidate and its window alone.
                if ($again -and [string]$again -ne $settled) {
                    Write-Verbose "Invoke-WaitVmIp: '$VMName' moved $settled -> $again; restarting the ${StableForSeconds}s settle window."
                    $settled = [string]$again
                    $settleUntil = (Get-Date).AddSeconds($StableForSeconds)
                }
            }
            return $settled
        }
        # The resolver call itself can be slow (a Get-VMIp that waits on KVP/ARP);
        # re-check the deadline before sleeping so we neither nap a full PollSeconds
        # past an already-expired budget nor spin one extra resolver call past it.
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    }
    Write-Verbose "Invoke-WaitVmIp: no IP for '$VMName' within ${TimeoutSeconds}s (resolver returned no address)."
    return $null
}

function Invoke-GetImage {
    <#
    .SYNOPSIS
        Run a guest's per-host Get-Image.ps1 to download or refresh the base
        image, mapping its exit code to a { success; skipped; errorMessage }
        result.
    .DESCRIPTION
        -HostSubdir is the driver's constant host subdirectory under
        <RepoRoot>/. -ResolveImagePath is the driver's Get-ImagePath as a
        CommandInfo: the image-path table is platform-specific and lives in the
        driver, so it is injected (a bare name would resolve in this module's
        scope, not the driver's). -WriteLine is an optional log-line writer
        CommandInfo; when omitted the in-module Write-GetImageLine is used
        (win/mac), and the kvm driver passes Write-Information instead.
    .OUTPUTS
        [hashtable] @{ success = [bool]; skipped = [bool]; errorMessage = [string] }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostSubdir,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force,
        [Parameter(Mandatory)]$ResolveImagePath,
        $WriteLine
    )
    $writer = if ($WriteLine) { $WriteLine } else { Get-Command Write-GetImageLine }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, 'Download / refresh base image')) { return @{ success = $false; skipped = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path $HostSubdir (Join-Path $GuestKey 'Get-Image.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 not found at: $scriptPath" }
    }
    if (-not $Force) {
        $imagePath = & $ResolveImagePath -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            & $writer "Image exists, skipping download: $imagePath"
            return @{ success = $true; skipped = $true; errorMessage = $null }
        }
    }
    & $writer "Running: $scriptPath"
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object {
        & $writer ([string]$_)
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 exited with code $code" }
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

function Test-TcpConnectWithin {
    <#
    .SYNOPSIS
        True when a TCP connect to $IpAddress:$Port completes within
        $TimeoutMs; $false on timeout, refusal, or any socket error.
    .DESCRIPTION
        BeginConnect starts an async connect and WaitOne bounds it, so a
        black-holed IP times out at $TimeoutMs instead of blocking on the OS
        default connect timeout (~20s+). On a completed connect EndConnect is
        called to finish the async operation cleanly before the socket is torn
        down -- leaving it pending abandons the operation and leaks the handle.
        The TcpClient is disposed in a finally so both the success and timeout
        paths release the socket deterministically.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    # Thin bool wrapper over Test-TcpConnectOutcome: one socket implementation,
    # so a caller that only needs yes/no cannot drift from one that needs to
    # know refused-versus-timeout.
    $result = Test-TcpConnectOutcome -IpAddress $IpAddress -Port $Port -TimeoutMs $TimeoutMs
    if (-not $result.Reachable) {
        Write-Verbose (Get-TcpOutcomeExplanation -Outcome $result -Endpoint "${IpAddress}:${Port}")
    }
    return [bool]$result.Reachable
}

function Invoke-CachingProxyServiceAvailableProbe {
    <#
    .SYNOPSIS
        Resolve the steady-state caching-proxy-service URL (YURUNA_CACHING_PROXY_SERVICE_IP
        override, else the recorded local cache IP), or $null when no cache
        answers. Returns the proxy URL string.
    .DESCRIPTION
        -VerifyHint is the platform-specific operator command template embedded
        in the final unreachable-cache warning (Test-NetConnection on Windows,
        nc on macOS/kvm); it is a {0}/{1} format string filled with the cache IP
        and HTTP port.

        -NoBracketHost returns bare-IP proxy URLs (skips the Format-IpUrlHost
        IPv6 bracketing). The kvm driver sets it so returned URLs keep the
        bare-IP shape its guests/consumers parse; win/mac use the default
        bracketed shape. For IPv4 the two are identical (Format-IpUrlHost only
        brackets IPv6), so this only affects a would-be IPv6 cache.

        -ConnectAttempts / -ConnectBackoffMs add a bounded connect retry for a
        cache reached over an extra hop (the kvm host's systemd socket-proxy
        forwarder into libvirt NAT, used when the 'yuruna-external' bridge could
        not be built). Default 1 (single shot) preserves the win/mac probe
        exactly; the kvm driver passes 3. A healthy cache answers on the first
        attempt, so the extra attempts run only on failure.

        -Quiet drops every "no cache" diagnostic below to the verbose stream and
        returns $null exactly as before. It is for callers that merely DECORATE
        with the cache URL when one happens to exist -- the status service's
        dashboard banner, and any bring-up that is itself about to create the
        cache. For them "no cache is recorded yet" is the normal state, and
        warning about it (worse, telling them to set
        YURUNA_CACHING_PROXY_SERVICE_IP) describes a problem they do not have.
        The runner's own per-cycle bootstrap probe deliberately does NOT pass it:
        there, a missing cache silently sends the whole cycle's guests direct to
        the internet, so the warning is the only place that "why" appears.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VerifyHint,
        [switch]$NoBracketHost,
        [int]$ConnectAttempts = 1,
        [int]$ConnectBackoffMs = 200,
        [switch]$Quiet
    )
    # One spelling of "report that no cache answered", so a -Quiet caller cannot
    # be left a diagnostic that a later edit adds on the loud stream only.
    $noCacheIsNews = -not $Quiet
    $reportNoCache = {
        param([string]$Message)
        if ($noCacheIsNews) { Write-Warning $Message } else { Write-Verbose $Message }
    }
    $httpPort = Get-CachingProxyServicePort -Scheme http
    # External cache override -- $Env:YURUNA_CACHING_PROXY_SERVICE_IP short-circuits
    # local discovery and points at a remote squid. If the remote doesn't
    # answer, return $null (do NOT fall back to local) so misconfiguration
    # surfaces as "no cache" instead of silently flipping target.
    if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
        if (-not (Test-IpAddress $externIp)) {
            & $reportNoCache "YURUNA_CACHING_PROXY_SERVICE_IP='$externIp' is not a valid IPv4 or IPv6 address -- ignoring."
            return $null
        }
        # 3s/attempt cap, not 1s: on the EXTERNAL/remote proxy path a cross-host
        # cache (a UTM/macOS squid over bridged networking, or a kvm cache behind
        # the host's systemd socket-proxy forwarder into libvirt NAT) routinely
        # takes 600ms-1s+ to ACCEPT, so a 1s cap makes the runner report a healthy
        # remote cache as "did not answer." The cap is free for a fast cache
        # (connect returns on accept); it only delays a genuinely-down verdict.
        $lastOutcome = $null
        for ($attempt = 1; $attempt -le $ConnectAttempts; $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Milliseconds $ConnectBackoffMs }
            $lastOutcome = Test-TcpConnectOutcome -IpAddress $externIp -Port $httpPort -TimeoutMs 3000
            if ($lastOutcome.Reachable) {
                return "http://$(if ($NoBracketHost) { $externIp } else { Format-IpUrlHost $externIp }):${httpPort}"
            }
        }
        # Say which failure it was. "Did not answer" reads as a network problem
        # and sends the operator to the uplink; a refusal in tens of ms is the
        # cache VM answering that its proxy is not running -- a different search
        # entirely, and the common one right after a cache rebuild.
        & $reportNoCache "YURUNA_CACHING_PROXY_SERVICE_IP=${externIp} set but the cache did not accept: $(Get-TcpOutcomeExplanation -Outcome $lastOutcome -Endpoint "${externIp}:${httpPort}")"
        return $null
    }

    # Local cache: probe only the IP recorded at the last
    # Start-CachingProxyServiceVM.ps1. Empty state -> no cache (the explicit
    # contract after Stop-CachingProxyServiceVM.ps1). State-set-but-unreachable
    # warns loudly because the inner runner's bootstrap detection runs ONCE per
    # cycle: a silently-failed probe sends the whole cycle's guests direct to the
    # internet under a bare "Caching-proxy service: not detected" headline in
    # Invoke-TestRunner output, with no "why" beside it.
    $stateIp = (Read-CachingProxyServiceState).ipAddress
    if (-not $stateIp -or -not (Test-IpAddress $stateIp)) {
        & $reportNoCache "Test-CachingProxyServiceAvailable: state.ipAddress is empty -- no locally-owned cache. Set `$Env:YURUNA_CACHING_PROXY_SERVICE_IP to point at a remote cache, or run Start-CachingProxyServiceVM.ps1."
        return $null
    }
    # 1500 ms matches test/Test-CachingProxyService.ps1's CLI probe so a
    # cache that answers the standalone smoke test also answers here.
    # Tighter timeouts (~500 ms) leave a window where a momentarily
    # busy squid (cold start, big cidata fetch) misses the runner's
    # single bootstrap probe and silently strands the whole inner cycle.
    for ($attempt = 1; $attempt -le $ConnectAttempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds $ConnectBackoffMs }
        if (Test-TcpConnectWithin -IpAddress $stateIp -Port $httpPort -TimeoutMs 1500) {
            return "http://$(if ($NoBracketHost) { $stateIp } else { Format-IpUrlHost $stateIp }):${httpPort}"
        }
    }
    # Name the CAUSE when the host can be asked for it. The generic "re-run
    # Start-CachingProxyServiceVM.ps1 (a new DHCP lease)" guess fits only a
    # running VM; after a host reboot the VM is registered and POWERED OFF, fixed
    # by starting it in seconds with the warm squid cache intact rather than by
    # the ~15-minute rebuild that hint implies. Every host driver implements
    # Get-VMState, resolved by name so a caller with no driver loaded still gets
    # the generic text.
    $cause = " If not, re-run Start-CachingProxyServiceVM.ps1 (the VM may have restarted with a new DHCP lease)."
    if (Get-Command Get-VMState -ErrorAction SilentlyContinue) {
        $cacheVmName = 'yuruna-caching-proxy-service'
        if (Get-Command Get-YurunaServiceVmRoster -ErrorAction SilentlyContinue) {
            $entry = @(Get-YurunaServiceVmRoster -Key 'caching-proxy')
            if ($entry.Count -gt 0 -and $entry[0].VMName) { $cacheVmName = [string]$entry[0].VMName }
        }
        $vmState = ''
        try { $vmState = [string](Get-VMState -VMName $cacheVmName) } catch {
            Write-Verbose "Test-CachingProxyServiceAvailable: Get-VMState('$cacheVmName'): $($_.Exception.Message)"
        }
        switch ($vmState) {
            'stopped' {
                $cause = " CAUSE: VM '$cacheVmName' is registered but POWERED OFF -- the signature of a host reboot, which leaves every service VM registered and stopped. Start it rather than rebuilding (a rebuild costs ~15 min and discards the warm cache): the next runner cycle starts it automatically, or run 'Start-CachingProxyServiceVM.ps1' now."
            }
            'absent' {
                $cause = " CAUSE: no VM named '$cacheVmName' is registered on this host, so the recorded address belongs to a cache that no longer exists here. Run Start-CachingProxyServiceVM.ps1 to build one, or point at a remote cache with `$Env:YURUNA_CACHING_PROXY_SERVICE_IP."
            }
            'running' {
                $cause = " CAUSE: VM '$cacheVmName' IS running, so this is an address or networking problem rather than a stopped service -- the recorded address is most likely stale (a new DHCP lease). Re-run Start-CachingProxyServiceVM.ps1 to re-record it."
            }
        }
    }
    & $reportNoCache "Test-CachingProxyServiceAvailable: state.ipAddress=${stateIp} did not answer :${httpPort} within 1500 ms; treating cache as unavailable. Verify with '$($VerifyHint -f $stateIp, $httpPort)'; if it answers, the cache is running and the next runner cycle will pick it up.$cause"
    return $null
}

<#
.SYNOPSIS
    True when the given IP literal is one of THIS host's own addresses
    (loopback, or assigned to any local network interface).
.DESCRIPTION
    Lets the caching-proxy-service port-map dispatchers recognize a
    $Env:YURUNA_CACHING_PROXY_SERVICE_IP that names the local host itself. On the
    NAT-fallback topology the host's own LAN IP fronts the cache VM through
    host-managed forwarders, so treating that IP as an external cache --
    whose handling tears the local port map down as a stale leftover --
    would sever the very path the probe just validated. Read-only: no sudo,
    no platform commands; System.Net.NetworkInformation works on Windows,
    macOS, and Linux alike.
#>
function Test-HostOwnIpAddress {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$IpAddress)
    return ((Get-HostOwnIpVerdict -IpAddress $IpAddress) -eq 'local')
}

<#
.SYNOPSIS
    Tri-state ownership verdict for an IP literal: 'local', 'nonlocal',
    or 'unknown' when NIC enumeration could not give a complete answer.
.DESCRIPTION
    The boolean Test-HostOwnIpAddress collapses "definitely not one of
    this host's addresses" and "could not enumerate every NIC" into the
    same $false -- and on hosts that start/stop guest VMs each cycle,
    interface churn makes transient enumeration failures routine. A
    caller deciding whether to TEAR DOWN this host's own port forwarders
    must not act on that ambiguity: a wrong 'nonlocal' severs the
    guest-facing proxy ports (self-teardown), while a wrong 'local'
    merely re-asserts a port map. 'unknown' lets teardown decisions land
    on the safe side. An unparseable literal is also 'unknown' for the
    same reason.
#>
function Get-HostOwnIpVerdict {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$IpAddress)
    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($IpAddress.Trim(), [ref]$parsed)) { return 'unknown' }
    if ([System.Net.IPAddress]::IsLoopback($parsed)) { return 'local' }
    $enumerationIncomplete = $false
    $nics = $null
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    } catch {
        Write-Debug "Get-HostOwnIpVerdict: NIC enumeration failed: $($_.Exception.Message)"
        return 'unknown'
    }
    foreach ($nic in $nics) {
        try {
            foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.Equals($parsed)) { return 'local' }
            }
        } catch {
            # A NIC that cannot report its addresses (driver quirk, hot
            # unplug race) might be the one owning the probed IP, so the
            # negative answer below is no longer trustworthy.
            Write-Debug "Get-HostOwnIpVerdict: $($nic.Name): $($_.Exception.Message)"
            $enumerationIncomplete = $true
        }
    }
    if ($enumerationIncomplete) { return 'unknown' }
    return 'nonlocal'
}

Export-ModuleMember -Function Invoke-PerGuestNewVm, Write-GetImageLine, Invoke-WaitVmIp, Invoke-GetImage, Invoke-CachingProxyServiceAvailableProbe, Test-HostOwnIpAddress, Get-HostOwnIpVerdict
