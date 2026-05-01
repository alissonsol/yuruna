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
      (172.25.x.x) reachable from the host but not the host's LAN.
      Per port, two stacks coexist:
        * netsh portproxy (kernel-mode IP Helper service) — used for
          80, 3000, 8022. Source IP is NAT'd by the kernel.
        * userspace pwsh forwarder (Start-CachingProxyForwarder.ps1) —
          used for ports passed via -ProxyProtocolPort (3128, 3129) so
          a HAProxy PROXY v1 header can preserve the real client IP
          for squid's accept-proxy-protocol listener.
      Both stacks teardown-then-add for idempotency, and both get a
      Yuruna-CachingProxy-Port-P firewall rule (port-scope, -Profile Any).
      The userspace path additionally gets a Yuruna-CachingProxy-Pwsh-P
      rule (per-program Allow for pwsh.exe) — without it, Windows
      Defender Firewall's per-program inbound filter on Public-profile
      networks silently drops LAN traffic to user-mode listeners even
      when the port-scope rule is in place. Kernel-mode netsh portproxy
      is not subject to that filter, which is why 80/3000 worked
      remotely while 3128/3129 didn't until both rules were added.
      Firewall rules go in BEFORE the listener binds. Requires admin;
      non-elevated callers get a warning and a no-op.

    macOS (UTM / Apple Virtualization):
      Apple VZ's shared-NAT isolates guest↔guest traffic on
      192.168.64.0/24 and no built-in portproxy equivalent is exposed
      to userland. We run one detached pwsh TcpListener per port
      (Start-CachingProxyForwarder.ps1 under virtual/host.macos.utm/) that binds
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
# Per-program (pwsh.exe) firewall-rule prefix. Used ONLY for ports served
# by the userspace pwsh forwarder (-ProxyProtocolPort), where Windows
# Defender Firewall applies per-program inbound filtering on top of the
# port-scope rule. Kernel-mode netsh portproxy (the path used for 80/3000/
# 8022) is not subject to this and skips this rule. Without this rule,
# remote LAN clients see :3128 / :3129 silently dropped while the local
# host (which probes the cache VM's Default-Switch IP directly, bypassing
# the forwarder entirely) reports green — the exact regression introduced
# by the "Proxy protocol" commit when 3128/3129 moved off netsh portproxy.
$script:FirewallProgramRulePrefix = 'Yuruna-CachingProxy-Pwsh-'

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

    # Also kill any pwsh forwarder pidfile for this port (used when the
    # port is in -ProxyProtocolPort, which bypasses netsh portproxy in
    # favor of a userspace forwarder that prepends a PROXY v1 header).
    Stop-WindowsCachingProxyForwarder -Port $Port -Quiet

    # Remove BOTH the port-scope rule and the per-program rule (pwsh.exe).
    # The program rule is only created for -ProxyProtocolPort ports, but
    # the cleanup is unconditional and idempotent — Get-NetFirewallRule
    # for a non-existent name is a no-op via -ErrorAction SilentlyContinue,
    # so 80/3000/8022 lose nothing they had.
    foreach ($prefix in @($script:FirewallRulePrefix, $script:FirewallProgramRulePrefix)) {
        $ruleName = "${prefix}${Port}"
        Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Cross-platform path to the userspace TCP forwarder script.
.DESCRIPTION
    Forwarder script lives under virtual/host.macos.utm/ for historical
    reasons — it was first written for macOS where netsh portproxy isn't
    available. The script itself is pure PowerShell (TcpListener +
    runspace pool) so it runs anywhere pwsh runs; both the macOS
    Start-CachingProxyForwarder primitive (VM.common.psm1) and the
    Windows-side launcher below reference it from this single location.
#>
function Get-CachingProxyForwarderScriptPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    return (Join-Path $repoRoot 'virtual/host.macos.utm/Start-CachingProxyForwarder.ps1')
}

<#
.SYNOPSIS
    Best-guess pwsh.exe path for a Defender per-program firewall rule —
    used as the pre-spawn placeholder; the post-spawn loaded path wins.
.DESCRIPTION
    Returns whatever Get-Command resolves first on PATH. On a clean MSI
    install of PowerShell that's the real binary at
    `C:\Program Files\PowerShell\7\pwsh.exe` and the firewall rule's
    -Program filter matches the loaded process exactly.

    GOTCHA — Microsoft Store / App Execution Aliases: when the user
    has both an MSI install AND the Microsoft Store version (or only
    the Store version), Get-Command can return the App Execution Alias
    stub at `C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\pwsh.exe`.
    The alias is a zero-byte filesystem reparse point that Windows
    redirects through to the real binary under
    `C:\Program Files\WindowsApps\Microsoft.PowerShell_<ver>_x64__<id>\pwsh.exe`
    AT EXEC TIME. Defender's WFP filter enforces -Program against the
    POST-RESOLUTION binary path, so a rule pinned to the alias stub
    silently fails to match — Get-NetFirewallRule shows the rule in
    place, the listener is bound, and inbound LAN traffic is dropped.
    This was the actual cause of the Windows source-IP-preservation
    revert; resolving the post-exec path from the running process
    instead is what makes the rule reliable.

    Caller flow: pre-install with this best-guess path so a rule is
    in place before bind(); after Start-WindowsCachingProxyForwarder
    returns, compare against the loaded binary's .Path and rewrite
    the rule if they differ. Idempotent on hosts where the guess is
    already correct (the common case).

    Returns $null if pwsh is not on PATH at all; caller logs and
    proceeds without the per-program rule (port-scope rule still in
    place — sufficient for kernel-mode netsh portproxy ports, NOT
    for user-mode pwsh listeners).
#>
function Get-PwshExePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

<#
.SYNOPSIS
    Install the Windows Defender Firewall rules for one caching-proxy port.
.DESCRIPTION
    Two rules per ProxyProtocol port (one rule for the others):

      Yuruna-CachingProxy-Port-<N>  : port-scope Allow, -Profile Any.
                                      Required for any inbound listener.
                                      Matches the working precedent in
                                      Test.Host.psm1's status-server rule
                                      (which calls out the same Defender
                                      "drops inbound on non-loopback"
                                      behavior this rule resolves).

      Yuruna-CachingProxy-Pwsh-<N>  : per-program Allow for pwsh.exe,
                                      -Profile Any. Created only when
                                      -IncludeProgram is set (i.e. a
                                      ProxyProtocol port served by the
                                      userspace forwarder). Defender's
                                      per-program inbound filter on
                                      Public-profile networks otherwise
                                      drops LAN traffic to the user-mode
                                      listener even with the port-scope
                                      Allow rule in place — the symptom
                                      that motivated this whole helper.

    Both rules are delete-then-add so re-runs stay idempotent. -Profile is
    set explicitly to Any to match the Test.Host.psm1 status-server
    precedent and to remove any default-profile ambiguity across Windows
    versions / domain-vs-public LAN classifications.

    Caller MUST install the rules BEFORE binding the listener — Defender
    cleanly applies a new Allow rule when the program first calls bind(),
    avoiding any first-bind hostile-default state. The order matters more
    for the user-mode forwarder path; for kernel-mode netsh portproxy
    it's harmless either way.
#>
function Add-CachingProxyFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Description,
        [switch]$IncludeProgram,
        # Override Get-PwshExePath. Pass the spawned forwarder's actual
        # loaded binary path (Get-Process -Id <pid> -> .Path) so the rule
        # matches what Defender filters on. See Get-PwshExePath docs for
        # the App Execution Alias trap that makes this matter.
        [string]$ProgramPath
    )
    if (-not $IsWindows) { return }

    # Port-scope rule.
    $portRule = "${script:FirewallRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($portRule, 'Install port-scope Allow rule')) {
        Get-NetFirewallRule -DisplayName $portRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        New-NetFirewallRule -DisplayName $portRule -Direction Inbound `
            -Protocol TCP -LocalPort $Port -Action Allow `
            -Profile Any `
            -Description $Description `
            -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $IncludeProgram) { return }

    # Per-program rule (pwsh.exe).
    $programRule = "${script:FirewallProgramRulePrefix}${Port}"
    if ($PSCmdlet.ShouldProcess($programRule, 'Install per-program Allow rule for pwsh.exe')) {
        Get-NetFirewallRule -DisplayName $programRule -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
        $pwshPath = if ($ProgramPath) { $ProgramPath } else { Get-PwshExePath }
        if (-not $pwshPath) {
            Write-Warning "No pwsh.exe path available — skipping ${programRule}. LAN clients may see :${Port} silently dropped by Windows Defender Firewall (the port-scope rule alone does not always override Defender's per-program inbound filter on Public profile)."
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
    Pidfile path for a Windows-side userspace forwarder on a given host port.
.DESCRIPTION
    Mirrors the macOS layout under $HOME/virtual/squid-cache/ so a single
    glob (`forwarder.*.pid`) finds every live forwarder regardless of OS.
    PowerShell's $HOME resolves to $env:USERPROFILE on Windows.
#>
function Get-WindowsForwarderPidPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    $stateDir = Join-Path $HOME 'virtual\squid-cache'
    return (Join-Path $stateDir "forwarder.$Port.pid")
}

<#
.SYNOPSIS
    Stop a Windows pwsh-based forwarder for a given host port.
.DESCRIPTION
    Reads the pidfile, verifies the process is actually pwsh.exe before
    signalling, and removes the pidfile. Sister of the macOS
    Stop-CachingProxyForwarder in VM.common.psm1; kept here so Test.PortMap
    can manage Windows lifecycle without dragging in the macOS module.
#>
function Stop-WindowsCachingProxyForwarder {
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
        # Sanity-check before killing: the pid must look like a pwsh/powershell
        # process so we never terminate a user shell that happened to recycle
        # the pid number after a previous forwarder exited.
        if ($proc.ProcessName -match '^(pwsh|powershell)$') {
            if ($PSCmdlet.ShouldProcess("pid $forwarderPid (port :${Port})", 'Stop forwarder process')) {
                if (-not $Quiet) { Write-Output "  Stopping forwarder (pid $forwarderPid, port :${Port})..." }
                Stop-Process -Id ([int]$forwarderPid) -Force -ErrorAction SilentlyContinue
            }
        } elseif (-not $Quiet) {
            Write-Warning "Pid $forwarderPid is not pwsh/powershell (is: $($proc.ProcessName)) — leaving alone, removing stale pidfile."
        }
    }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    return $true
}

<#
.SYNOPSIS
    Launch a detached pwsh forwarder on the host (Windows-side primitive).
.DESCRIPTION
    Cross-platform Test.PortMap dispatch: when -ProxyProtocolPort is set,
    the Windows branch of Add-CachingProxyPortMap calls this instead of
    netsh portproxy. The forwarder binds host:<Port>, dials cache:<VMPort>,
    optionally writes a PROXY v1 header, and shuttles bytes — preserving
    the real client IP so squid (with `accept-proxy-protocol`) logs the
    LAN client rather than the host's NAT-side IP.
#>
function Start-WindowsCachingProxyForwarder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$CacheIp,
        [Parameter(Mandatory)][int]$Port,
        [int]$VMPort = 0,
        [switch]$PrependProxyV1
    )
    # Return shape:
    #   @{ Success = $bool; Pid = $int; PwshPath = $string }
    # PwshPath is the post-resolution loaded binary path (read from
    # Get-Process .Path on the running PID), which is what Defender's
    # WFP filter enforces against. Caller uses it to install / fix the
    # per-program firewall rule's -Program filter so the rule actually
    # matches the running process. $null on failure or if Get-Process
    # could not read the path (rare: process exited, ACL).
    if (-not $IsWindows) {
        Write-Warning "Start-WindowsCachingProxyForwarder called on non-Windows host — no-op."
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    if ($VMPort -eq 0) { $VMPort = $Port }

    $forwarderScript = Get-CachingProxyForwarderScriptPath
    if (-not (Test-Path $forwarderScript)) {
        Write-Warning "Forwarder script not found: $forwarderScript"
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }

    $stateDir = Join-Path $HOME 'virtual\squid-cache'
    if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $pidFile = Get-WindowsForwarderPidPath -Port $Port
    $logFile = Join-Path $stateDir "forwarder.$Port.log"
    $stdoutLog = Join-Path $stateDir "forwarder.$Port.stdout.log"
    $stderrLog = Join-Path $stateDir "forwarder.$Port.stderr.log"

    # Tear down any stale forwarder for THIS port before spawning. Other
    # ports' forwarders are untouched (per-port pidfile = independent
    # lifecycle, same pattern as the macOS branch).
    Stop-WindowsCachingProxyForwarder -Port $Port -Quiet

    $proxyTag = if ($PrependProxyV1) { ' [PROXY v1]' } else { '' }
    $action   = "0.0.0.0:${Port} -> ${CacheIp}:${VMPort}${proxyTag}"
    if (-not $PSCmdlet.ShouldProcess($action, 'Launch detached pwsh TCP forwarder')) {
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }
    Write-Output "  Launching userspace forwarder: ${action}"

    $procArgs = @(
        '-NoProfile','-NoLogo','-File', $forwarderScript,
        '-CacheIp', $CacheIp,
        '-Port', $Port,
        '-VMPort', $VMPort,
        '-PidFile', $pidFile,
        '-LogFile', $logFile
    )
    if ($PrependProxyV1) { $procArgs += '-PrependProxyV1' }

    try {
        $proc = Start-Process -FilePath 'pwsh' `
            -ArgumentList $procArgs `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError  $stderrLog `
            -WindowStyle Hidden `
            -PassThru
    } catch {
        Write-Warning "Failed to spawn forwarder: $($_.Exception.Message)"
        return [PSCustomObject]@{ Success = $false; Pid = $null; PwshPath = $null }
    }

    # Confirm the listener bound. 3s budget covers pwsh startup +
    # TcpListener.Start(); typically sub-second. A bind failure (port in
    # use, missing privileges) leaves the child dead and the connect
    # below times out — surface that to the caller rather than silently
    # claiming success.
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        try {
            $h = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
            if ($h.AsyncWaitHandle.WaitOne(150) -and $tcp.Connected) {
                $tcp.Close()
                $actualPid = if (Test-Path $pidFile) { [int]((Get-Content $pidFile -Raw).Trim()) } else { [int]$proc.Id }
                # Resolve the loaded binary path. Get-Process .Path
                # returns the resolved on-disk binary even when the
                # spawn went through a Microsoft Store App Execution
                # Alias — that's the path Defender filters on, and the
                # one the per-program rule needs to match exactly.
                # Best-effort: a process that already exited (race) or
                # an ACL denial both produce $null, in which case the
                # caller falls back to Get-PwshExePath's PATH lookup.
                $loadedPath = $null
                try { $loadedPath = (Get-Process -Id $actualPid -ErrorAction Stop).Path } catch { $null = $_ }
                Write-Output "  Forwarder up (pid $actualPid): ${action}"
                if ($loadedPath) { Write-Output "    loaded binary: $loadedPath" }
                return [PSCustomObject]@{ Success = $true; Pid = $actualPid; PwshPath = $loadedPath }
            }
        } catch { $null = $_ } finally { $tcp.Close() }
        Start-Sleep -Milliseconds 100
    }
    Write-Warning "Forwarder launched (pid $($proc.Id)) but :${Port} did not answer within 3s — see $stderrLog."
    return [PSCustomObject]@{ Success = $false; Pid = [int]$proc.Id; PwshPath = $null }
}

<#
.SYNOPSIS
    Enumerate Windows ports that have a live pwsh forwarder pidfile.
.DESCRIPTION
    Sister of Get-YurunaMappedPortFromFirewall: clears stale state on a
    fresh elevated run even if the JSON state file is missing. Returns
    host ports for which `$HOME/virtual/squid-cache/forwarder.<port>.pid`
    exists and is parseable as an int. Caller verifies the pid is alive.
#>
function Get-WindowsForwarderPidPort {
    [CmdletBinding()]
    [OutputType([int[]], [System.Object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $stateDir = Join-Path $HOME 'virtual\squid-cache'
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
    # Pick up BOTH naming conventions. A port that has only the program
    # rule installed (e.g. interrupted Add-CachingProxyPortMap mid-cycle)
    # still gets cleaned up; without this branch, the orphan rule would
    # outlive the next cycle and accumulate over time.
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
    # Also catch any pwsh forwarder pidfiles that survived a previous run —
    # if the firewall rule was deleted manually but the forwarder process
    # is still bound to its port, we want Stop-WindowsCachingProxyForwarder
    # called on it during cleanup. (The firewall-rule scan misses this
    # because the rule is already gone; the state file might too.)
    foreach ($p in (Get-WindowsForwarderPidPort)) { $ports += $p }

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
    One or more TCP ports to forward where host port == VM port. Default:
    3000 (Grafana). Callers can pass @(3000, 9090) to also expose
    Prometheus, etc. — no config changes required elsewhere.

.PARAMETER PortRemap
    Hashtable of host-port -> VM-port pairs for ports that DIFFER on each
    side (e.g. @{8022 = 22} forwards host :8022 to VM :22 for SSH on a
    non-standard host port to avoid colliding with the host's own sshd).
    Keys and values are coerced to int. Pairs are merged with -Port into
    a single list; a host port appearing in both wins from -PortRemap.

.PARAMETER ProxyProtocolPort
    Host ports for which to use a userspace pwsh forwarder that prepends
    a HAProxy PROXY v1 header — instead of netsh portproxy on Windows
    (which would NAT the source IP and lose the real client). Squid's
    `accept-proxy-protocol` http_port option must be set on the
    corresponding VM-side port for this to work.

    Typical usage for the squid-cache: -ProxyProtocolPort @(3128, 3129)
    paired with -PortRemap @{3128 = 3138; 3129 = 3139} so host :3128
    forwards to cache :3138 (which is configured in squid.conf with
    accept-proxy-protocol). Other ports stay on netsh portproxy because
    PROXY v1 is meaningless for them (SSH, Apache CA cert, Grafana).

    On macOS, all ports already use the userspace forwarder; this list
    just toggles -PrependProxyV1 on the same forwarder instance.

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
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @(),
        [string]$TrackDir
    )
    $proxyProtoSet = @{}
    foreach ($p in $ProxyProtocolPort) { $proxyProtoSet[[int]$p] = $true }

    if ($VMIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
        Write-Warning "Add-CachingProxyPortMap: VMIp '$VMIp' is not a valid IPv4 address — skipping."
        return $null
    }

    # Normalize -Port + -PortRemap into a single list of [HostPort, VMPort]
    # pairs. -PortRemap entries override matching -Port entries on the same
    # host port (so a caller can pass `-Port @(22) -PortRemap @{22=22}`
    # without duplicates).
    $remapHostPorts = @{}
    foreach ($k in $PortRemap.Keys) { $remapHostPorts[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if ($remapHostPorts.ContainsKey([int]$p)) { continue }
        $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
    }
    foreach ($k in $remapHostPorts.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remapHostPorts[$k] }
    }

    # macOS branch — delegate to the per-port forwarder primitives in
    # virtual/host.macos.utm/VM.common.psm1. Each Start-CachingProxyForwarder does
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
        # Privileged ports (<1024) are handled inside Start-CachingProxyForwarder
        # via `sudo -E pwsh` — the caller (Start-CachingProxy.ps1) pre-caches
        # credentials with `sudo -v` before reaching here.
        $launched = @()
        foreach ($m in $mappings) {
            $useProxy = $proxyProtoSet.ContainsKey([int]$m.HostPort)
            $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
            if (-not $PSCmdlet.ShouldProcess("0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)${proxyTag}", 'Launch macOS squid forwarder')) { continue }
            $started = if ($useProxy) {
                Start-CachingProxyForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort -PrependProxyV1
            } else {
                Start-CachingProxyForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort
            }
            if ($started) { $launched += $m.HostPort }
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

    foreach ($m in $mappings) {
        $hostPort = $m.HostPort; $vmPort = $m.VMPort
        $useProxy = $proxyProtoSet.ContainsKey([int]$hostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}", 'Add port mapping')) { continue }

        $desc = "Yuruna caching proxy: forward host :${hostPort} to VM :${vmPort}${proxyTag}"

        # Tear down any prior listener for THIS port (both stacks — netsh
        # portproxy and pwsh forwarder), regardless of which mode this
        # cycle uses. Switching modes between cycles (e.g. operator added
        # a port to -ProxyProtocolPort) would otherwise race the old
        # listener for the bind. netsh delete is no-op if the rule is
        # absent; Stop-WindowsCachingProxyForwarder is no-op if no pidfile.
        & netsh interface portproxy delete v4tov4 listenport=$hostPort listenaddress=0.0.0.0 2>&1 | Out-Null
        Stop-WindowsCachingProxyForwarder -Port $hostPort -Quiet

        # Install firewall rules BEFORE binding the listener. For the
        # user-mode pwsh forwarder path, Windows Defender Firewall applies
        # both a port-scope rule AND a per-program rule for pwsh.exe; the
        # latter is the one that allows LAN traffic on Public-profile
        # networks (the port-scope rule alone is consistently insufficient
        # — that was the regression behind 3128/3129 working locally on
        # the Default-Switch IP yet failing for remote LAN clients while
        # 80/3000 on netsh portproxy continued to work). Kernel-mode netsh
        # portproxy is not subject to per-program filtering, so -IncludeProgram
        # is gated to ProxyProtocol ports — adding it for 80/3000 would
        # be noise. Rules are written before the listener binds so
        # Defender's WFP filters are in place at bind time.
        Add-CachingProxyFirewallRule -Port $hostPort -Description $desc -IncludeProgram:$useProxy -Confirm:$false

        if ($useProxy) {
            # PROXY-protocol path: netsh portproxy NATs the source IP, so
            # squid would log every connection as the host. The userspace
            # pwsh forwarder writes a HAProxy PROXY v1 header before the
            # byte stream — squid (with require-proxy-header on the
            # VM-side port) parses it and restores the real client IP
            # for ACLs and access.log.
            $spawn = Start-WindowsCachingProxyForwarder -CacheIp $VMIp -Port $hostPort -VMPort $vmPort -PrependProxyV1
            if (-not $spawn.Success) {
                Write-Warning "Add-CachingProxyPortMap: pwsh forwarder failed for host ${hostPort} -> ${VMIp}:${vmPort} (PROXY v1)."
                continue
            }
            # Self-heal the per-program rule if Get-PwshExePath's pre-spawn
            # guess didn't match the binary that actually loaded. On a host
            # where a Microsoft Store App Execution Alias is first on PATH,
            # the pre-spawn rule was pinned to the alias stub — Defender
            # filters on the post-resolution path under WindowsApps and
            # silently drops everything. Reading .Path from the running
            # process and rewriting the rule is what closes that gap. No-op
            # on hosts where the guess was already correct (MSI install).
            if ($spawn.PwshPath) {
                $existingProgramPath = $null
                try {
                    $existingProgramPath = (Get-NetFirewallRule -DisplayName "$($script:FirewallProgramRulePrefix)${hostPort}" -ErrorAction Stop |
                                            Get-NetFirewallApplicationFilter -ErrorAction Stop).Program
                } catch { $null = $_ }
                if ($existingProgramPath -ne $spawn.PwshPath) {
                    if ($existingProgramPath) {
                        Write-Output "  Pwsh path resolved to '$($spawn.PwshPath)' (rule had '$existingProgramPath') — rewriting per-program firewall rule."
                    } else {
                        Write-Output "  Installing per-program firewall rule with resolved pwsh path '$($spawn.PwshPath)'."
                    }
                    Add-CachingProxyFirewallRule -Port $hostPort -Description $desc -IncludeProgram -ProgramPath $spawn.PwshPath -Confirm:$false
                }
            }
        } else {
            # netsh won't overwrite an existing rule in place — `add` with
            # the same listenport returns "The object already exists" and
            # leaves the old mapping. The pre-loop delete above keeps this
            # path idempotent.
            & netsh interface portproxy add v4tov4 listenport=$hostPort listenaddress=0.0.0.0 connectport=$vmPort connectaddress=$VMIp | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Add-CachingProxyPortMap: netsh portproxy add failed for host ${hostPort} -> ${VMIp}:${vmPort} (exit $LASTEXITCODE)."
                continue
            }
        }

        Write-Output "  Port map added: host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}"
    }

    # State file: `ports` stays as host-port-only list for cleanup
    # (Clear-AllCachingProxyPortMapping reads it that way). `mappings` is
    # the canonical record including VM ports and per-port proxy-protocol
    # flag — for diagnostics and to surface non-matching pairs (e.g.
    # 8022->22) when an operator inspects the file. Old state files
    # (pre-PortRemap, with `ports` only) still cleanup correctly because
    # cleanup never needed VM ports.
    $state = [ordered]@{
        vmIp      = $VMIp
        ports     = @($mappings | ForEach-Object { $_.HostPort })
        mappings  = @($mappings | ForEach-Object {
            [ordered]@{
                hostPort      = $_.HostPort
                vmPort        = $_.VMPort
                proxyProtocol = $proxyProtoSet.ContainsKey([int]$_.HostPort)
            }
        })
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
        $ip = "$( & '/usr/sbin/ipconfig' getifaddr $iface 2>$null )".Trim()
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
    Locate virtual/host.macos.utm/VM.common.psm1 relative to this module.
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
    $p = Join-Path $repoRoot 'virtual/host.macos.utm/VM.common.psm1'
    if (Test-Path $p) { return $p }
    return $null
}

Export-ModuleMember -Function Add-CachingProxyPortMap, Remove-CachingProxyPortMap, Get-BestHostIp
