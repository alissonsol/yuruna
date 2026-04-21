<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456718
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
    Exposes squid-cache VM ports on the host, cross-platform.

.DESCRIPTION
    Single API (Add-CachingProxyPortMap / Remove-CachingProxyPortMap /
    Get-BestHostIp) that dispatches internally per host OS. Callers in
    Invoke-TestRunner.ps1, Start-StatusServer.ps1, Start-CachingProxy.ps1
    etc. use these symbols without knowing the underlying mechanism.

    Windows (Hyper-V, the original):
      VMs on Hyper-V's Default Switch land on a private NAT subnet
      (172.25.x.x) reachable from the host but not the host's LAN. Ports
      are exposed via three steps per port:
        1. netsh interface portproxy delete (idempotency — netsh won't
           replace in place)
        2. netsh interface portproxy add v4tov4 listenport=P
           listenaddress=0.0.0.0 connectport=P connectaddress=$VMIp
        3. New-NetFirewallRule -DisplayName Yuruna-CachingProxy-Port-P
           -Direction Inbound -Protocol TCP -LocalPort P -Action Allow
      Requires administrator; non-elevated callers get a warning and a
      no-op (the cycle continues without port exposure).

    macOS (UTM / Apple Virtualization):
      Apple VZ's shared-NAT isolates guest↔guest traffic on
      192.168.64.0/24 and no built-in portproxy equivalent is exposed
      to userland. We run one detached pwsh TcpListener per port
      (Start-CachingProxyForwarder.ps1 under vde/host.macos.utm/) that binds
      on 0.0.0.0 and tunnels to the VM. No elevation needed — ports
      3128 and 3000 are both >=1024. State is the pidfile set under
      $HOME/virtual/squid-cache/, so Remove enumerates and terminates.

    Get-BestHostIp returns the LAN-routable IPv4 an operator can paste
    into a browser to reach an exposed port. On Windows it ranks via
    Get-NetIPAddress + Get-NetRoute; on macOS it reads the default-
    route interface from `/sbin/route -n get default` and asks
    `ipconfig getifaddr` for that interface's address.
#>

$script:StateFileName = 'caching-proxy-port-map.json'
$script:FirewallRulePrefix = 'Yuruna-CachingProxy-Port-'

# Test.TrackDir.psm1 owns $env:YURUNA_TRACK_DIR; import it here so
# Get-PortMapStatePath can resolve the state file even when a caller
# (Start-CachingProxy.ps1, Stop-CachingProxy.ps1) hasn't bootstrapped
# the full runner path.
Import-Module (Join-Path $PSScriptRoot 'Test.TrackDir.psm1') -Force

function Get-PortMapStatePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$TrackDir)

    if (-not $TrackDir) {
        $TrackDir = Initialize-YurunaTrackDir
    } elseif (-not (Test-Path $TrackDir)) {
        New-Item -ItemType Directory -Path $TrackDir -Force | Out-Null
    }
    return (Join-Path $TrackDir $script:StateFileName)
}

function Test-IsAdministrator {
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-SinglePortMap {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][int]$Port)

    if (-not $PSCmdlet.ShouldProcess("host:${Port}", 'Remove portproxy + firewall rule')) { return }

    # netsh delete prints "The requested operation requires elevation" if not
    # admin, but also returns an error line when the rule simply doesn't exist.
    # Either outcome is acceptable — we want the rule gone or absent. Pipe to
    # Out-Null so the noise doesn't reach the caller's console.
    & netsh interface portproxy delete v4tov4 listenport=$Port listenaddress=0.0.0.0 2>&1 | Out-Null

    $ruleName = "${script:FirewallRulePrefix}${Port}"
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Enumerate ports with an existing Yuruna-named firewall rule.
.DESCRIPTION
    netsh portproxy + firewall rules survive host reboots and process
    restarts (they live in the Windows registry, not on our state file).
    If the state file is ever lost — repo re-clone, disk cleanup, manual
    delete of status/log/ — the OS still carries stale Yuruna rules
    that would otherwise outlive the runner. We pick them back up by
    pattern-matching on the firewall rule display name, which is the
    predictable naming convention Add-CachingProxyPortMap writes with, so
    "I don't remember what I mapped" never means "orphan rules persist".
    Non-Yuruna rules are untouched.
.OUTPUTS
    int[] — port numbers for every Yuruna-CachingProxy-Port-<N> rule.
#>
function Get-YurunaMappedPortFromFirewall {
    [CmdletBinding()]
    # Both declared because the leading `,$ports` array-wrap makes static
    # analysis see Object[] even when every element is a runtime int.
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $ports = @()
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "${script:FirewallRulePrefix}*" } |
        ForEach-Object {
            if ($_.DisplayName -match "^$([regex]::Escape($script:FirewallRulePrefix))(\d+)$") {
                $ports += [int]$matches[1]
            }
        }
    return ,$ports
}

<#
.SYNOPSIS
    Remove every Yuruna caching proxy port mapping the host currently has.
.DESCRIPTION
    Union of two sources: ports listed in the state file (if readable),
    and ports discoverable from Yuruna-named firewall rules currently
    installed on the host. The union means neither a missing state file
    nor a missing firewall rule can hide a leftover mapping — whichever
    source knows about a port, the port gets torn down.
#>
function Clear-AllCachingProxyPortMapping {
    [CmdletBinding(SupportsShouldProcess)]
    # Both declared: runtime elements are ints, but the leading `,$unique`
    # array-wrap at the return trips the analyzer into seeing Object[].
    [OutputType([int[]], [System.Object[]])]
    param([string]$StatePath)

    $ports = @()

    if ($StatePath -and (Test-Path $StatePath)) {
        try {
            $prev = Get-Content -Raw $StatePath | ConvertFrom-Json
            foreach ($p in @($prev.ports)) {
                if ($p -is [int] -or $p -match '^\d+$') { $ports += [int]$p }
            }
        } catch {
            Write-Verbose "Clear-AllCachingProxyPortMapping: could not read state ($StatePath): $_"
        }
    }

    foreach ($p in (Get-YurunaMappedPortFromFirewall)) { $ports += $p }

    $unique = @($ports | Sort-Object -Unique)
    foreach ($p in $unique) {
        if ($PSCmdlet.ShouldProcess("host:${p}", 'Clear Yuruna port mapping')) {
            Remove-SinglePortMap -Port $p -Confirm:$false
        }
    }

    if ($StatePath -and (Test-Path $StatePath)) {
        Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue
    }

    return ,$unique
}

<#
.SYNOPSIS
    Expose squid-cache VM ports on the host via portproxy + firewall rule.

.PARAMETER VMIp
    IPv4 address of the running squid-cache VM (as returned by
    Test-CachingProxyAvailable / Get-WorkingCachingProxyUrl).

.PARAMETER Port
    One or more TCP ports to forward. Host port == VM port. Default: 3000
    (Grafana). Callers can pass @(3000, 9090) to also expose Prometheus,
    etc. — no config changes required elsewhere.

.PARAMETER TrackDir
    Directory to write the state file to. Defaults to $env:YURUNA_TRACK_DIR.

.OUTPUTS
    Path to the state file written (for logging / diagnostic use).
#>
function Add-CachingProxyPortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [int[]]$Port = @(3000),
        [string]$TrackDir
    )

    if ($VMIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Warning "Add-CachingProxyPortMap: VMIp '$VMIp' is not a valid IPv4 address — skipping."
        return $null
    }

    # macOS branch — delegate to the per-port forwarder primitives in
    # vde/host.macos.utm/VM.common.psm1. Each Start-CachingProxyForwarder does
    # its own per-port preflight (Stop-CachingProxyForwarder -Port $p) so
    # re-calling is idempotent AND leaves other-port forwarders alone.
    # We deliberately do NOT call Stop-AllCachingProxyForwarder first: when
    # Invoke-TestRunner refreshes :3000 mid-cycle, it MUST NOT disturb
    # the already-running :3128 forwarder guests depend on. State here
    # is the live pidfile set under $HOME/virtual/squid-cache/, NOT a
    # JSON file, so $TrackDir is ignored on this platform. Return a
    # sentinel string so callers that treat any non-null return as
    # success keep working uniformly across platforms.
    if ($IsMacOS) {
        $macModule = Resolve-MacVmCommonModule
        if (-not $macModule) {
            Write-Warning "Add-CachingProxyPortMap: macOS VM.common.psm1 not found — cannot start forwarders."
            return $null
        }
        Import-Module $macModule -Force
        # Privileged ports (<1024) on macOS can only be bound by root — a
        # user-scope pwsh TcpListener on :80 fails with EACCES. The CA-cert
        # Apache listener is on :80 by convention (and guest user-data hard-
        # codes /yuruna-squid-ca.crt without a port), so remote clients that
        # need HTTPS caching require :80 forwarded. If we're not root we
        # skip that port with a clear message and keep the unprivileged
        # forwarders (:3128, :3129, :3000) running — HTTP caching still
        # works, only HTTPS caching for remote clients is lost until the
        # operator re-runs Start-CachingProxy.ps1 under sudo.
        $isRoot = $false
        try { $isRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { $isRoot = $false }
        $launched = @()
        foreach ($p in $Port) {
            if ($p -lt 1024 -and -not $isRoot) {
                Write-Warning "Add-CachingProxyPortMap: port ${p} is privileged on macOS; skipping. Re-run under sudo to expose it to remote clients."
                continue
            }
            if (-not $PSCmdlet.ShouldProcess("0.0.0.0:${p} -> ${VMIp}:${p}", 'Launch macOS squid forwarder')) { continue }
            if (Start-CachingProxyForwarder -CacheIp $VMIp -Port $p) { $launched += $p }
        }
        if ($launched.Count -eq 0) { return $null }
        return "macos:forwarders=$($launched -join ',')"
    }

    if (-not $IsWindows) {
        Write-Verbose "Add-CachingProxyPortMap: unsupported platform — no-op."
        return $null
    }
    if (-not (Test-IsAdministrator)) {
        Write-Warning "Add-CachingProxyPortMap: admin privilege required. Skipping port exposure (netsh portproxy + New-NetFirewallRule both need elevation)."
        return $null
    }

    $statePath = Get-PortMapStatePath -TrackDir $TrackDir

    # Undo EVERY prior Yuruna mapping before adding the new set. Critical
    # in three scenarios the test runner routinely hits:
    #   (a) VM was rebuilt and has a new IP — a stale portproxy pointing
    #       at the old IP would silently black-hole traffic to the new VM.
    #   (b) The status server or the runner was restarted after a crash,
    #       leaving state on disk in one place and rules in another.
    #   (c) The status/log/ directory was wiped (repo re-clone, manual
    #       cleanup) so the state file is gone but netsh/firewall rules
    #       survive in the Windows registry across reboots.
    # Clear-AllCachingProxyPortMapping unions state-file ports with Yuruna-
    # named firewall rules, so whichever source has evidence of a prior
    # mapping — or both — the port gets torn down. The state file is then
    # deleted and we start the new write from scratch.
    [void](Clear-AllCachingProxyPortMapping -StatePath $statePath -Confirm:$false)

    foreach ($p in $Port) {
        if (-not $PSCmdlet.ShouldProcess("host:${p} -> ${VMIp}:${p}", 'Add port mapping')) { continue }

        # Step 1 — remove any stale portproxy on this listenport. netsh won't
        # overwrite an existing rule in place; `add` with the same listenport
        # returns "The object already exists" and leaves the old mapping.
        & netsh interface portproxy delete v4tov4 listenport=$p listenaddress=0.0.0.0 2>&1 | Out-Null

        # Step 2 — create the portproxy mapping.
        & netsh interface portproxy add v4tov4 listenport=$p listenaddress=0.0.0.0 connectport=$p connectaddress=$VMIp | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Add-CachingProxyPortMap: netsh portproxy add failed for port ${p} (exit $LASTEXITCODE)."
            continue
        }

        # Step 3 — open Windows Firewall. Delete-then-add keeps the rule
        # idempotent (no duplicates across repeated cycle starts).
        $ruleName = "${script:FirewallRulePrefix}${p}"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound `
            -Protocol TCP -LocalPort $p -Action Allow `
            -Description "Yuruna caching proxy: forward host :${p} to VM :${p}" `
            -ErrorAction SilentlyContinue | Out-Null

        Write-Output "  Port map added: host:${p} -> ${VMIp}:${p}"
    }

    $state = [ordered]@{
        vmIp      = $VMIp
        ports     = @($Port)
        createdAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    $tmp = "$statePath.tmp"
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding utf8
    Move-Item -Path $tmp -Destination $statePath -Force
    return $statePath
}

<#
.SYNOPSIS
    Remove all port mappings previously created by Add-CachingProxyPortMap.

.DESCRIPTION
    Clears every Yuruna-named portproxy + firewall rule, drawing from both
    the state file ($env:YURUNA_TRACK_DIR/caching-proxy-port-map.json) and
    the live list of Yuruna-CachingProxy-Port-* rules on the host. Safe to
    call when the state file is missing — rule-scanning still finds
    leftovers from a prior boot, a crashed run, or a wiped track dir.
    Also safe to call when no mappings exist at all; emits nothing then.

.PARAMETER TrackDir
    Directory the state file lives in. Defaults to $env:YURUNA_TRACK_DIR.

.OUTPUTS
    $true if anything was removed, $false if nothing was found.
#>
function Remove-CachingProxyPortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$TrackDir)

    if ($IsMacOS) {
        $macModule = Resolve-MacVmCommonModule
        if (-not $macModule) { return $false }
        Import-Module $macModule -Force
        if (-not $PSCmdlet.ShouldProcess('all caching proxy forwarders', 'Stop')) { return $false }
        $stopped = @(Stop-AllCachingProxyForwarder)
        return ($stopped.Count -gt 0)
    }

    if (-not $IsWindows) {
        Write-Verbose "Remove-CachingProxyPortMap: unsupported platform — no-op."
        return $false
    }

    if (-not (Test-IsAdministrator)) {
        # Rule-scanning runs even unelevated (Get-NetFirewallRule is read-only),
        # so decide whether there is actually something to clean before emitting
        # the elevation warning — non-admin callers with nothing to do stay silent.
        $pendingPorts = Get-YurunaMappedPortFromFirewall
        if ($pendingPorts.Count -gt 0) {
            Write-Warning "Remove-CachingProxyPortMap: admin privilege required to remove portproxy/firewall rules for ports: $($pendingPorts -join ', '). State left in place for a later elevated run."
        }
        return $false
    }

    $statePath = Get-PortMapStatePath -TrackDir $TrackDir
    $cleared = @(Clear-AllCachingProxyPortMapping -StatePath $statePath -Confirm:$false)
    foreach ($p in $cleared) {
        Write-Output "  Port map removed: host:${p}"
    }
    return ($cleared.Count -gt 0)
}

<#
.SYNOPSIS
    Return the host's "best" outbound IPv4 address for LAN advertising.

.DESCRIPTION
    When a port has been exposed via Add-CachingProxyPortMap, the URL an
    operator pastes into a browser needs an IP that is actually reachable
    from their machine — not a loopback, not a Hyper-V vEthernet NAT
    address, not a WellKnown (link-local / APIPA) stub. This picker
    filters those out and ranks what remains by:
      1. Interfaces that have a default-route (Get-NetRoute 0.0.0.0/0),
         i.e. a way off the host. Interfaces without one are punished by
         +1000 in the Priority sort key so they only win when nothing
         else is routable.
      2. Windows's own InterfaceMetric, which already reflects stable
         routing preferences (Ethernet beats Wi-Fi unless configured
         otherwise). Lower is better.

    Returns the highest-ranked IPv4 as a string, or $null on non-Windows
    hosts / when no candidate passes the filters. Callers should fall
    back (e.g. to the VM IP) when $null comes back.
#>
function Get-BestHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($IsMacOS) {
        # Use `/sbin/route -n get default` to find the interface that
        # carries the default route, then `ipconfig getifaddr <iface>` for
        # that interface's IPv4. Avoids a parser for `ifconfig` output and
        # naturally skips loopback / utun / VZ bridges (they have no default
        # route). Fully-qualified paths so PSScriptAnalyzer's alias-avoidance
        # rule can tell these apart from pwsh built-ins.
        $routeOut = & '/sbin/route' -n get default 2>$null
        $iface = $null
        foreach ($line in $routeOut) {
            if ($line -match 'interface:\s*(\S+)') { $iface = $matches[1]; break }
        }
        if (-not $iface) { return $null }
        $ip = (& '/usr/sbin/ipconfig' getifaddr $iface 2>$null).Trim()
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') { return $ip }
        return $null
    }

    if (-not $IsWindows) { return $null }

    $ranked = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        # Exclude loopback / link-local (169.254.x.x) — WellKnown covers both.
        # Exclude Hyper-V / other virtual switches by interface-alias match,
        # since even when they have a valid IP it isn't visible off-host.
        $_.PrefixOrigin -ne 'WellKnown' -and
        $_.InterfaceAlias -notmatch 'vEthernet|Pseudo'
    } | ForEach-Object {
        $ifaceIndex = $_.InterfaceIndex
        $interface  = Get-NetIPInterface -InterfaceIndex $ifaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $hasGateway = [bool](Get-NetRoute -InterfaceIndex $ifaceIndex -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue)
        [PSCustomObject]@{
            IPAddress     = $_.IPAddress
            InterfaceName = $_.InterfaceAlias
            Metric        = $interface.InterfaceMetric
            HasGateway    = $hasGateway
            Priority      = ($hasGateway ? 0 : 1000) + [int]($interface.InterfaceMetric)
        }
    } | Sort-Object Priority

    return ($ranked | Select-Object -ExpandProperty IPAddress -First 1)
}

<#
.SYNOPSIS
    Locate vde/host.macos.utm/VM.common.psm1 relative to this module.
.DESCRIPTION
    Test.PortMap.psm1 lives under test/modules/, so $PSScriptRoot's parent's
    parent is the repo root. Returns $null (not an error) if the macOS
    module is missing so callers on an unusual checkout layout can degrade
    gracefully with a warning instead of a hard failure.
#>
function Resolve-MacVmCommonModule {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $p = Join-Path $repoRoot 'vde/host.macos.utm/VM.common.psm1'
    if (Test-Path $p) { return $p }
    return $null
}

Export-ModuleMember -Function Add-CachingProxyPortMap, Remove-CachingProxyPortMap, Get-BestHostIp
