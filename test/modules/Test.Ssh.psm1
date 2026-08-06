<#PSScriptInfo
.VERSION 2026.08.06
.GUID 422c9a3d-41bb-4e8c-9b64-5f7a1d0c9a12
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

# SSH-based guest driver. Parallel to the GUI keystroke flow in
# Test.SequenceEngine.psm1; selected by test.config.yml "keystrokeMechanism"
# ("GUI"|"SSH", case-insensitive, normalized uppercase by the validator).
# A per-host ed25519 key pair lives under test/status/ssh/ (runtime,
# gitignored) and is injected into each guest's cloud-init user-data via
# SSH_AUTHORIZED_KEY_PLACEHOLDER.
#
# Host-key policy: yuruna recreates guests constantly and reuses VM names
# and NAT-assigned IPs, so every fresh guest presents a different host
# key on an address that previously had a different one. Every ssh call
# site MUST pass all three of:
#   -o StrictHostKeyChecking=no
#   -o UserKnownHostsFile=/dev/null
#   -o GlobalKnownHostsFile=/dev/null   (closes the ssh-keyscan-into-
#                                        /etc/ssh/ssh_known_hosts trap)
# Microsoft's OpenSSH port accepts /dev/null verbatim, so one line works
# on every host.

# -Global is load-bearing: without it, -Force evicts Test.VMUtility from
# the runner's session mid-cycle (Start-GuestOS triggers this re-import)
# and the next New-VM.Resource step crashes on missing Wait-VMRunning.
Import-Module (Join-Path $PSScriptRoot 'Test.VMUtility.psm1') -Force -DisableNameChecking -Global

# test/modules/Test.Ssh.psm1 -> test/ is one Split-Path up; the SSH key
# pair lives under test/status/ssh/ so it sits with the rest of the
# harness runtime state (gitignored, wiped together by status/ cleanup).
$script:SshKeyDir  = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'status' -AdditionalChildPath 'ssh'
$script:SshKeyPath = Join-Path $script:SshKeyDir "yuruna_ed25519"
$script:SshPubPath = "$script:SshKeyPath.pub"
# Set to $script:SshKeyPath after the first successful Initialize-YurunaSshKey.
# Get-YurunaSshPrivateKeyPath short-circuits the full re-init (ssh-keygen
# probe + icacls) when the cached path still resolves to an on-disk file.
$script:CachedSshKey = $null

# --- REGION: https://yuruna.link/memory#why-the-guest-ssh-user-overrides-are-anchored-in-the-global-scope
# Per-cycle overrides for Get-GuestSshUser. Global scope survives the defensive
# -Force re-imports that would otherwise wipe the cascade mid-cycle.
if (-not (Get-Variable -Name 'YurunaGuestSshUserOverrides' -Scope Global -ErrorAction SilentlyContinue)) {
    Set-Variable -Name 'YurunaGuestSshUserOverrides' -Scope Global -Value @{}
}
$script:GuestSshUserOverrides = Get-Variable -Name 'YurunaGuestSshUserOverrides' -Scope Global -ValueOnly

function Initialize-YurunaSshKey {
<#
.SYNOPSIS
Ensures the per-host yuruna SSH key pair exists and returns the private key path.
.DESCRIPTION
Creates test/status/ssh/yuruna_ed25519 (and .pub) on first call via ssh-keygen,
tightens permissions so ssh will accept it, and is a no-op on subsequent calls.
Throws if ssh-keygen is not on PATH or key creation fails.
.OUTPUTS
System.String. Absolute path to the private key file.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Test-Path $script:SshKeyDir)) {
        New-Item -ItemType Directory -Path $script:SshKeyDir -Force | Out-Null
    }

    $sshKeygen = (Get-Command ssh-keygen -ErrorAction SilentlyContinue)?.Source
    if (-not $sshKeygen) {
        throw "ssh-keygen not found on PATH. Install OpenSSH client."
    }

    # Reject keys carrying the legacy-quoting regression: -N '""' passed
    # to ssh-keygen on Windows PowerShell encrypts the key with the
    # literal 2-char passphrase "", which fails silently under
    # BatchMode=yes after "Server accepts key". If the existing key won't
    # load with an empty passphrase, regenerate.
    if (Test-Path $script:SshKeyPath -PathType Leaf) {
        $probe = & $sshKeygen -y -P '' -f $script:SshKeyPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Existing yuruna SSH key is not usable with empty passphrase (legacy passphrase-quoting bug). Regenerating."
            Write-Warning "  ssh-keygen probe output: $($probe | Out-String)"
            Remove-Item -Force $script:SshKeyPath -ErrorAction SilentlyContinue
            Remove-Item -Force "$script:SshKeyPath.pub" -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $script:SshKeyPath -PathType Leaf)) {
        # -N "" = empty passphrase (PowerShell 7 passes "" as a real empty arg).
        & $sshKeygen -t ed25519 -f $script:SshKeyPath -N "" -C "yuruna-test-harness@$env:COMPUTERNAME" -q 2>&1 | Out-Null
        if (-not (Test-Path $script:SshKeyPath -PathType Leaf)) {
            throw "ssh-keygen failed to create key at $script:SshKeyPath"
        }
        # Probe the just-created key: catches the legacy quoting regression at creation.
        $probe = & $sshKeygen -y -P '' -f $script:SshKeyPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Newly generated key is not loadable with empty passphrase. ssh-keygen output: $($probe | Out-String)"
        }
    }

    # Enforce strict private-key permissions on EVERY call: Windows OpenSSH
    # rejects keys readable by other principals, and a prior loose ACL would
    # silently break authentication.
    if ($IsWindows) {
        & icacls $script:SshKeyPath /inheritance:r 2>&1 | Out-Null
        foreach ($principal in @('Authenticated Users','Users','Everyone','BUILTIN\Users','BUILTIN\Administrators','Administrators','NT AUTHORITY\SYSTEM','SYSTEM')) {
            & icacls $script:SshKeyPath /remove:g "$principal" 2>&1 | Out-Null
        }
        & icacls $script:SshKeyPath /grant:r "${env:USERNAME}:F" 2>&1 | Out-Null
    } else {
        & chmod 600 $script:SshKeyPath 2>&1 | Out-Null
    }
    return $script:SshKeyPath
}

function Get-YurunaSshPublicKey {
<#
.SYNOPSIS
Returns the yuruna test-harness SSH public key as a single-line string.
.DESCRIPTION
Used by per-host New-VM.ps1 scripts to substitute SSH_AUTHORIZED_KEY_PLACEHOLDER
in cloud-init user-data. Generates the key pair on first call.
.OUTPUTS
System.String. The public key (ssh-ed25519 ...) with any trailing newline trimmed.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Initialize-YurunaSshKey | Out-Null
    return (Get-Content -Raw $script:SshPubPath).Trim()
}

function Get-YurunaSshPrivateKeyPath {
<#
.SYNOPSIS
Returns the absolute path to the yuruna test-harness SSH private key.
.DESCRIPTION
Generates the key pair on first call. Returned path is suitable for `ssh -i`.
Subsequent calls in the same process skip the Initialize-YurunaSshKey re-probe
(ssh-keygen + icacls) when the cached path still resolves to an on-disk file;
the cache is invalidated automatically if the file is deleted.
.OUTPUTS
System.String. Absolute path to the private key file.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:CachedSshKey -and (Test-Path -LiteralPath $script:CachedSshKey -PathType Leaf)) {
        return $script:CachedSshKey
    }
    Initialize-YurunaSshKey | Out-Null
    $script:CachedSshKey = $script:SshKeyPath
    return $script:SshKeyPath
}

function Get-YurunaSshHostKeyOption {
<#
.SYNOPSIS
Returns the three host-key ssh -o options every yuruna ssh call site must pass.
.DESCRIPTION
yuruna recreates guests constantly and reuses VM names and NAT-assigned IPs, so
every fresh guest presents a different host key on an address that previously had
a different one. Skipping any one of these would trip a "REMOTE HOST
IDENTIFICATION HAS CHANGED" refusal (or a ssh-keyscan-into-ssh_known_hosts trap
for the global file). Returned as a flat -o/value sequence so it drops straight
into a ProcessStartInfo.ArgumentList or a native-ssh argument array; divergent
per-call options (ConnectTimeout / ServerAlive / LogLevel) stay caller-appended.
.OUTPUTS
System.String[]. Six elements: -o StrictHostKeyChecking=no -o
UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@(
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'GlobalKnownHostsFile=/dev/null'
    )
}

function Get-GuestAddress {
<#
.SYNOPSIS
Resolves a yuruna VM name to an address that ssh can actually reach.
.DESCRIPTION
VM names are not registered in the host's DNS resolver on either Hyper-V
Default Switch or UTM on macOS, so `ssh user@vm-name` fails with "could
not resolve hostname". This helper returns an IPv4 when discoverable,
or the VMName as a fallback so the caller's retry loop can try again.

The authoritative IP-discovery logic lives in the host driver's
`Get-VMIp` (host/<host>/modules/Yuruna.Host.psm1). This function
delegates there when available; otherwise it falls back to the
inline host-conditional probe so standalone Test.Ssh consumers
still work without a fully-initialized Yuruna.Host session.
.OUTPUTS
System.String. An IPv4 address if one was discovered, otherwise the VMName.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName)

    # Prefer the host driver's Get-VMIp -- it has the most up-to-date
    # discovery (External-vSwitch ARP probes, dhcpd_leases fallback, etc.).
    if (Get-Command Get-VMIp -ErrorAction SilentlyContinue) {
        try {
            $ip = Get-VMIp -VMName $VMName
            if ($ip) { return [string]$ip }
        } catch {
            Write-Debug "Get-VMIp failed for ${VMName}: $_"
        }
    }

    # Fallback path for standalone Test.Ssh use (no Yuruna.Host loaded),
    # so SSH-client users (Wait-SshReady / Invoke-GuestSsh) work even when
    # callers forget to call Initialize-YurunaHost first.
    #
    # Deliberately only the CHEAP lookups, and therefore weaker than the
    # driver's Get-VMIp: a bridged UTM guest is invisible to both of them
    # (no agent, and the shared-NAT lease file cannot hold its lease) and
    # is found only by matching the bundle MAC in the host ARP table --
    # which needs an ICMP sweep, and is host-driver work this module has
    # no business duplicating. A caller that must resolve a bridged guest
    # has to have the driver in scope; without it the VM name is returned
    # and ssh's own resolution is the last route left.
    if ($IsWindows -and (Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) {
        try {
            $addrs = (Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop).IPAddresses
            # Accept v4 or v6 from KVP. SSH happily handles either; the
            # link-local/loopback exclusion drops fe80: and ::1 even
            # though Hyper-V rarely emits those in the KVP list.
            $ipPick = $addrs |
                Where-Object { Test-IpAddress $_ } |
                Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' } |
                Select-Object -First 1
            if ($ipPick) { return [string]$ipPick }
        } catch {
            Write-Debug "Get-VMNetworkAdapter failed for ${VMName}: $_"
        }
    }
    if ($IsMacOS -and (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        try {
            $output = & utmctl ip-address $VMName 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ipPick = ($output -split "`r?`n") |
                    ForEach-Object { $_.Trim() } |
                    Where-Object { Test-IpAddress $_ } |
                    Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' } |
                    Select-Object -First 1
                if ($ipPick) { return [string]$ipPick }
            }
        } catch {
            Write-Debug "utmctl ip-address failed for ${VMName}: $_"
        }
    }
    if ($IsMacOS) {
        $leaseFile = '/var/db/dhcpd_leases'
        if (Test-Path $leaseFile) {
            try {
                $content = Get-Content $leaseFile -Raw -ErrorAction Stop
                # The DHCP server keys each block on the name the GUEST sent.
                # A sequence that pins variables.hostname makes that differ
                # from the VM name, and blocks still filed under the VM name
                # then belong to predecessors -- they match and return a dead
                # address rather than missing. Try the seeded hostname first,
                # then the VM name; the shared selector applies the
                # live-subnet and lease-expiry rules to both.
                $pinnedHostname = Get-UtmGuestSeedHostname -VMName $VMName
                $leaseNames = @($pinnedHostname)
                if ($pinnedHostname -ne $VMName) { $leaseNames += $VMName }
                $bestIp = Select-DhcpLeaseIpAddress -LeaseText $content -Name $leaseNames
                if ($bestIp) { return $bestIp }
            } catch {
                Write-Debug "dhcpd_leases lookup failed for ${VMName}: $_"
            }
        }
    }

    return $VMName
}

function Get-GuestSshUser {
<#
.SYNOPSIS
Maps a yuruna guest key to its default SSH login user.
.DESCRIPTION
Returns the harness's greppable per-guest test user. Names are unique
enough to grep cleanly out of OS logs; ubuntu guests carry the major
version in the suffix so 24.04 and 26.04 don't collide in shared logs:
  guest.amazon.linux.2023   -> yauser1   (seeded on top of the cloud-image
                                     default 'ec2-user')
  guest.ubuntu.server.24  -> yuuser24  (replaces the cloud-image default
                                     'ubuntu' via autoinstall)
  guest.ubuntu.server.26  -> yuuser26  (replaces the cloud-image default
                                     'ubuntu' via autoinstall)
  guest.windows.11     -> ywuser1   (created by autounattend.xml)
The service VMs the harness brings up on a host each get their OWN
administrator, so their vault entries stay independent -- one shared name
means one vault password, and the most recently built VM invalidates the
console credential of the others:
  guest.caching-proxy-service  -> caching-proxy-service-admin
  guest.pool-control-service   -> pool-control-service-admin
  guest.stash-service  -> stash-admin
  guest.download-agent-service -> download-agent-service-admin
The username for each guest must match the `username:` variable in
the corresponding test/sequences/**/*.<guest>.yml file.
.PARAMETER GuestKey
The guest identifier used throughout the harness (e.g. guest.ubuntu.server.24).
.OUTPUTS
System.String. Username to log in as over SSH.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$GuestKey)
    # Per-cycle cascade override wins over the per-guest default.
    # Set by Set-GuestSshUserOverride at cycle-plan resolution time.
    if ($GuestKey -and $script:GuestSshUserOverrides.ContainsKey($GuestKey)) {
        return [string]$script:GuestSshUserOverrides[$GuestKey]
    }
    switch ($GuestKey) {
        "guest.ubuntu.server.24"  { return "yuuser24" }
        "guest.ubuntu.server.26"  { return "yuuser26" }
        "guest.amazon.linux.2023"   { return "yauser1" }
        "guest.windows.11"     { return "ywuser1" }
        "guest.caching-proxy-service"  { return "caching-proxy-service-admin" }
        "guest.pool-control-service"   { return "pool-control-service-admin" }
        "guest.stash-service"  { return "stash-admin" }
        "guest.download-agent-service" { return "download-agent-service-admin" }
        default { return "root" }
    }
}

function Set-GuestSshUserOverride {
<#
.SYNOPSIS
    Registers a per-cycle SSH-user override for one guest. Get-GuestSshUser
    returns the override (if set) before falling through to the per-guest
    hardcoded default.
.DESCRIPTION
    Called from the runner immediately after the cycle plan is resolved,
    once per guest present in the plan. The Username argument is the
    cascade-walked `variables.username:` value the planner already
    computed (effectiveUsername on each plan entry), so this function
    just files it where every downstream SSH lookup can see it.

    An empty Username drops the override for that GuestKey -- useful for
    a test harness that registers conditionally.
.PARAMETER GuestKey
    The guest identifier whose lookup should be overridden
    (e.g. guest.ubuntu.server.24).
.PARAMETER Username
    The cascaded login user. Empty value removes the override.
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'In-memory hashtable mutation in a runtime-only registration helper; operator has no -WhatIf intent here. Same justification as Test.Prelude\Initialize-YurunaEntryPointModuleSet.')]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [string]$Username
    )
    if ([string]::IsNullOrEmpty($Username)) {
        $script:GuestSshUserOverrides.Remove($GuestKey)
        return
    }
    if ($script:GuestSshUserOverrides.ContainsKey($GuestKey) -and
        $script:GuestSshUserOverrides[$GuestKey] -eq $Username) {
        return
    }
    $script:GuestSshUserOverrides[$GuestKey] = $Username
    Write-Verbose "Get-GuestSshUser override: ${GuestKey} -> ${Username}"
}

function Clear-GuestSshUserOverride {
<#
.SYNOPSIS
    Drops every registered SSH-user override. Used at the top of a new
    cycle so a fresh plan resolution starts from a known empty state.
.DESCRIPTION
    The Inner runner is spawned fresh per cycle, so the script-scoped
    map is already empty in practice. Invoke-TestSequence (and any future
    long-lived runner) re-uses the same process across multiple plans,
    so an explicit reset prevents a prior run's override from leaking
    into the next one.
#>
    [CmdletBinding()]
    param()
    if ($script:GuestSshUserOverrides.Count -gt 0) {
        Write-Verbose "Clearing $($script:GuestSshUserOverrides.Count) Get-GuestSshUser override(s)."
        $script:GuestSshUserOverrides.Clear()
    }
}

function Get-SshReadinessFailureCause {
<#
.SYNOPSIS
Classifies why Wait-SshReady exhausted its budget into one discriminator the
operator (and any remediator) can route on, instead of a single generic
network_timeout.
.DESCRIPTION
Pure: derives the cause from the final probe error text and whether a real
guest IP was ever discovered. "Reached-sshd" evidence in the error (Permission
denied / Connection refused / host-key) ranks ABOVE the IP-discovery signal:
on a host where the bare VM name resolves, ssh reaches sshd without
Get-GuestAddress ever returning a discovered IP, so there the auth/refused
reason is the true cause -- not "ip_not_discovered".
.PARAMETER IpDiscovered
$true if Get-GuestAddress returned a real, validated IPv4 during the wait.
.PARAMETER LastError
The final probe's combined stdout+stderr (or the probe-timeout note).
.OUTPUTS
System.String -- one of: auth_denied, connection_refused, host_key_changed,
probe_timeout, ip_not_discovered, name_unresolved, network_unreachable,
handshake_failed.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [bool]$IpDiscovered,
        [string]$LastError
    )
    $e = if ($LastError) { $LastError } else { '' }
    # 1. Evidence we reached sshd -- the true cause regardless of IP discovery.
    if ($e -match 'Permission denied|publickey|Too many authentication')     { return 'auth_denied' }
    if ($e -match 'Connection refused')                                      { return 'connection_refused' }
    if ($e -match 'Host key verification failed|REMOTE HOST IDENTIFICATION') { return 'host_key_changed' }
    # A probe timeout is a genuine post-TCP hang (probe_timeout) only when a real
    # IP was discovered. With no discovered IP the ssh probe stalled on the
    # unresolved bare-VMName fallback, so the true cause is the discovery-lateness
    # class below, not a generic probe timeout.
    if ($IpDiscovered -and $e -match 'probe timed out')                      { return 'probe_timeout' }
    # 2. Never reached sshd. No discovered IP => the host-side discovery layer
    #    (KVP integration services / DHCP lease / utmctl ip-address) never
    #    answered -- the recoverable lateness class, distinct from an sshd or
    #    auth fault (feedback_get_guestaddress_no_polling,
    #    feedback_hyperv_external_vswitch_arp_discovery).
    if (-not $IpDiscovered)                                                  { return 'ip_not_discovered' }
    # 3. A real IP, but the network path to it never came up.
    if ($e -match 'Could not resolve|Name or service not known|nodename nor servname') { return 'name_unresolved' }
    if ($e -match 'No route to host|Connection timed out|Operation timed out|timed out') { return 'network_unreachable' }
    return 'handshake_failed'
}

function Wait-SshReady {
<#
.SYNOPSIS
Polls a guest VM until it accepts an SSH connection with the yuruna harness key.
.DESCRIPTION
Handshakes all the way to an authenticated shell (not just TCP/22) by running a
trivial `echo` and matching its output. Returns $false if the deadline elapses.
.PARAMETER VMName
Hostname or IP the VM is reachable by from this host.
.PARAMETER GuestKey
Guest identifier (e.g. guest.amazon.linux.2023); determines the SSH login user.
.PARAMETER TimeoutSeconds
Maximum total seconds to keep retrying. Default 300.
.PARAMETER PollSeconds
Seconds between connection attempts. Default 5. The first 3 attempts use a
1-second backoff regardless of this value, so a sshd that comes up in its
typical 1-2 s window is caught without waiting the full poll interval.
.OUTPUTS
System.Boolean. $true if SSH became ready, $false on timeout.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$VMName,
        [string]$GuestKey,
        [int]$TimeoutSeconds = 300,
        [int]$PollSeconds = 5
    )
    $user = Get-GuestSshUser -GuestKey $GuestKey
    $key  = Get-YurunaSshPrivateKeyPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError  = ''
    $attempts   = 0
    $lastTarget = ''
    # Did host-side discovery ever hand us a real IP? Separates the recoverable
    # "KVP/DHCP/utmctl never reported an address" wait from a genuine sshd/auth
    # fault when the gate fails (drives Get-SshReadinessFailureCause below).
    $ipEverDiscovered = $false
    # Per-probe wall-clock cap; ssh has no timeout of its own past TCP setup.
    # --- REGION: https://yuruna.link/memory#why-the-ssh-readiness-probe-runs-in-process-with-its-own-wall-clock-cap
    $probeCapSeconds = 15
    # Adaptive backoff: first 3 attempts at 1 s catch the typical sshd-
    # becomes-ready window (1-2 s on a healthy guest) without sleeping
    # through it. After that the configured $PollSeconds takes over for
    # the longer wait on a slow guest.
    $earlyPollSeconds = 1
    $earlyAttemptThreshold = 3
    while ((Get-Date) -lt $deadline) {
        $attempts++
        $thisPollSeconds = if ($attempts -le $earlyAttemptThreshold) { $earlyPollSeconds } else { $PollSeconds }
        # Re-resolve each iteration: on Hyper-V the IP may not be reported
        # until integration services come up a few seconds into boot.
        $target = Get-GuestAddress -VMName $VMName
        if ($target -ne $lastTarget) {
            Write-Debug "  sshWaitReady target: $user@$target (from VMName '$VMName')"
            $lastTarget = $target
        }
        # A real discovered IP (not the Get-GuestAddress VMName fallback).
        if (-not $ipEverDiscovered -and $target -and $target -ne $VMName -and (Test-IpAddress $target)) {
            $ipEverDiscovered = $true
        }
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName               = 'ssh'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        # ArgumentList (.NET 5+) handles per-arg quoting -- no shell
        # interpolation, no double-quote-inside-double-quote hazard for
        # paths with spaces in $key.
        $psi.ArgumentList.Add('-i'); $psi.ArgumentList.Add($key)
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('BatchMode=yes')
        foreach ($hk in (Get-YurunaSshHostKeyOption)) { $psi.ArgumentList.Add($hk) }
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('ConnectTimeout=5')
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('ServerAliveInterval=3')
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('ServerAliveCountMax=2')
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('LogLevel=ERROR')
        $psi.ArgumentList.Add("$user@$target")
        $psi.ArgumentList.Add('echo yuruna-ssh-ready')

        $proc = $null
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
        } catch {
            $lastError = "Process.Start('ssh') threw: $($_.Exception.Message)"
            $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
            if ($remainingSeconds -gt 0) { Start-Sleep -Seconds ([Math]::Min([double]$thisPollSeconds, $remainingSeconds)) }
            continue
        }
        # Read both streams asynchronously to avoid the classic "child
        # blocks on a full pipe while we wait for it to exit" deadlock.
        # ReadToEndAsync returns a Task; we read .Result AFTER WaitForExit
        # confirms the streams are closed.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        # Cap this probe at the smaller of the fixed per-probe cap and the time
        # left to the overall deadline, so the final probe cannot push past
        # TimeoutSeconds -- WaitForExit is otherwise a flat probeCapSeconds no
        # matter how little budget remains. Doubles throughout so [Math]::Min/Max
        # never bind the (int,int) overload on a large millisecond value.
        $probeMs    = [int][Math]::Max([double]0, [Math]::Min([double]($probeCapSeconds * 1000), ($deadline - (Get-Date)).TotalMilliseconds))
        $completed  = $proc.WaitForExit($probeMs)
        $stdoutText = ''
        $stderrText = ''
        $exit       = -1
        if ($completed) {
            $stdoutText = $stdoutTask.Result
            $stderrText = $stderrTask.Result
            $exit       = [int]$proc.ExitCode
        } else {
            # Hung probe -- kill the process tree so the leaked ssh
            # doesn't accumulate across iterations. .Kill($true) is
            # the .NET 5+ "kill entire process tree" call.
            try { $proc.Kill($true) } catch { Write-Verbose "Process.Kill failed: $($_.Exception.Message)" }
            $probeSeconds = [Math]::Round($probeMs / 1000.0, 1)
            # A full-cap timeout is a genuine post-TCP hang; a short cap means the
            # overall deadline was reached mid-probe, so name that case accurately.
            # Either way keep the "probe timed out" token Get-SshReadinessFailureCause matches on.
            $probeReason = if ($probeMs -ge $probeCapSeconds * 1000) { 'ssh hung post-TCP' } else { 'deadline reached mid-probe' }
            $lastError = "probe timed out after ${probeSeconds}s ($probeReason; process killed)"
        }
        $proc.Dispose()
        if ($completed) {
            $resultText = ($stdoutText + $stderrText)
            if ($exit -eq 0 -and $resultText -match "yuruna-ssh-ready") {
                Write-Debug "SSH ready after $attempts attempt(s): $user@$target"
                return $true
            }
            $lastError = $resultText.Trim()
        }
        # Poll before the next attempt, but never sleep past the deadline:
        # TimeoutSeconds is a hard wall-clock bound, so clamp the sleep to the
        # time left (and skip it entirely once the budget is spent).
        $remainingSeconds = ($deadline - (Get-Date)).TotalSeconds
        if ($remainingSeconds -gt 0) {
            Start-Sleep -Seconds ([Math]::Min([double]$thisPollSeconds, $remainingSeconds))
        }
    }

    # Failure path. Classify WHY before dumping diagnostics, so the dumps and
    # the operator guidance target the actual cause.
    # The whole dump is Verbose: readiness failure is soft (callers fall back to
    # the console rung and the cycle still passes), and the same multi-line block
    # repeats for every diagnostic capture on a guest whose sshd is unreachable.
    # The structured ssh_handshake_failed event below is the durable signal;
    # raise the log level when actually debugging a handshake.
    $cause = Get-SshReadinessFailureCause -IpDiscovered $ipEverDiscovered -LastError $lastError
    Write-Verbose "SSH did not become ready within ${TimeoutSeconds}s (${attempts} attempts): $user@$lastTarget"
    Write-Verbose "  cause         : $cause (ipDiscovered=$ipEverDiscovered)"
    Write-Verbose "  last ssh error: $lastError"
    Write-Verbose "  private key   : $key"

    if ($cause -eq 'ip_not_discovered') {
        # Never resolved a guest IP and never reached sshd: a host-side
        # discovery wait (KVP integration services / DHCP lease / utmctl
        # ip-address still empty), not an sshd or auth fault. The pubkey / ACL
        # / verbose-handshake dumps below diagnose sshd+auth, so against the
        # bare VM-name fallback they would only echo DNS failures -- skip them
        # and point at the real fix instead.
        Write-Verbose "  guest IP was never discovered within the budget -- the host-side"
        Write-Verbose "  discovery layer (KVP / DHCP lease / utmctl) did not report an"
        Write-Verbose "  address. This is a discovery wait, not an sshd/auth failure:"
        Write-Verbose "  extend the budget or repair discovery (e.g. active ARP probe on a"
        Write-Verbose "  Hyper-V External vSwitch) before debugging sshd."
    } else {
        # We reached (or could resolve) a host: dump the sshd/auth diagnostics.
        # 1. Local public key + fingerprint
        try {
            $pubPath = "$key.pub"
            if (Test-Path $pubPath) {
                $pubLine = (Get-Content -Raw $pubPath).Trim()
                Write-Verbose "  local pubkey  : $pubLine"
                $fp = & ssh-keygen -lf $pubPath 2>&1
                Write-Verbose "  fingerprint   : $fp"
            }
        } catch { Write-Verbose "  pubkey dump failed: $_" }

        # 2. Private-key ACL (Windows OpenSSH strict-mode rejection diagnostic)
        if ($IsWindows) {
            try {
                $aclLines = (& icacls $key 2>&1) -split "`r?`n" | Where-Object { $_.Trim() }
                foreach ($l in $aclLines) { Write-Verbose "  acl: $l" }
            } catch { Write-Verbose "  icacls failed: $_" }
        }

        # 3. One verbose handshake so the actual reason is in the log. Bounded
        # by the same Process.Start + WaitForExit + Kill($true) harness as the
        # probe loop: `ssh -v` reintroduces a foreground ssh, so a guest that
        # accepts TCP then stalls in banner/kex would otherwise hang the runner
        # during the failure/diagnostics phase (saveDiagnostics is downstream --
        # the worst place to block).
        Write-Verbose "  --- verbose handshake follows ---"
        try {
            $vpsi = [System.Diagnostics.ProcessStartInfo]::new()
            $vpsi.FileName = 'ssh'
            $vpsi.RedirectStandardOutput = $true
            $vpsi.RedirectStandardError  = $true
            $vpsi.UseShellExecute = $false
            foreach ($a in @('-v', '-i', $key,
                    '-o', 'BatchMode=yes') +
                    (Get-YurunaSshHostKeyOption) +
                    @('-o', 'ConnectTimeout=5',
                    "$user@$lastTarget", 'echo yuruna-ssh-ready')) {
                $vpsi.ArgumentList.Add($a)
            }
            $vproc = [System.Diagnostics.Process]::Start($vpsi)
            $voTask = $vproc.StandardOutput.ReadToEndAsync()
            $veTask = $vproc.StandardError.ReadToEndAsync()
            if ($vproc.WaitForExit($probeCapSeconds * 1000)) {
                foreach ($line in (($voTask.Result + $veTask.Result) -split "`r?`n")) {
                    if ($line.Trim()) { Write-Verbose "    [ssh -v] $($line.TrimEnd())" }
                }
            } else {
                try { $vproc.Kill($true) } catch { Write-Verbose "verbose-dump Kill failed: $($_.Exception.Message)" }
                Write-Verbose "    [ssh -v] verbose handshake exceeded ${probeCapSeconds}s (ssh hung post-TCP; killed)."
            }
            $vproc.Dispose()
        } catch { Write-Verbose "  verbose dump failed: $($_.Exception.Message)" }
        Write-Verbose "  --- end verbose handshake ---"
    }

    # Surface the failure as a structured NDJSON event so an autonomous
    # remediator routes on `event=ssh_handshake_failed` without having to
    # regex-parse the Write-Warning stream. `cause` is the granular
    # discriminator (ip_not_discovered vs auth_denied vs connection_refused
    # ...) whose remediations differ; `ipDiscovered` says whether the wait
    # ever saw a real address. lastError carries the final probe output;
    # attempts / timeout pin down whether the gate was time- or attempt-bounded.
    Send-CycleEventSafely -EventRecord @{
        timestamp        = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        event            = 'ssh_handshake_failed'
        target           = [string]$lastTarget
        user             = [string]$user
        privateKey       = [string]$key
        attempts         = [int]$attempts
        timeoutSeconds   = [int]$TimeoutSeconds
        pollSeconds      = [int]$PollSeconds
        probeCapSeconds  = [int]$probeCapSeconds
        lastError        = [string]$lastError
        cause            = [string]$cause
        ipDiscovered     = [bool]$ipEverDiscovered
        failureClass     = 'network_timeout'
        severity         = 'soft'
    }
    return $false
}

function Invoke-GuestSsh {
<#
.SYNOPSIS
Runs a command on a guest VM over SSH, bounded by a total-runtime timeout.
.DESCRIPTION
Executes the command in a background job so the whole call can be killed if it
exceeds TimeoutSeconds (ssh's own ConnectTimeout only bounds TCP setup, not the
command itself). On timeout, the job is stopped and exitCode is set to -1.
.PARAMETER VMName
Hostname or IP the VM is reachable by from this host.
.PARAMETER GuestKey
Guest identifier (e.g. guest.amazon.linux.2023); determines the SSH login user.
.PARAMETER Command
Shell command to run on the guest. Passed as a single argument to ssh.
.PARAMETER TimeoutSeconds
Maximum total seconds to let the command run. Default 900.
.PARAMETER User
Login user to force, bypassing the Get-GuestSshUser lookup. Empty (the
default) keeps the lookup. Use this for a guest whose account was created by
its cloud-init seed rather than by a sequence's `variables.username:` -- the
seed account is the only one that exists, so a per-cycle cascade override
registered for that guest key would send the login to an account the VM never
had. The overrides live in the global scope and outlive the module re-import a
standalone bring-up script performs, so an earlier cycle in the same shell
session can otherwise leak its username into this call.
.OUTPUTS
System.Collections.Hashtable with keys: success (bool), exitCode (int), output (string).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$VMName,
        [string]$GuestKey,
        [string]$Command,
        [int]$TimeoutSeconds = 900,
        [string]$User
    )
    # Not $user: PowerShell variable names are case-insensitive, so that would
    # be the same storage as the $User parameter and read as a self-assignment.
    $loginUser = if ($User) { $User } else { Get-GuestSshUser -GuestKey $GuestKey }
    $keyPath = Get-YurunaSshPrivateKeyPath
    $address = Get-GuestAddress -VMName $VMName
    $target  = "$loginUser@$address"
    Write-Debug "Invoke-GuestSsh: target=$target command=$Command timeout=${TimeoutSeconds}s"

    # Run ssh via an in-process .NET Process with a hard WaitForExit cap so TimeoutSeconds
    # bounds TOTAL runtime, not just TCP setup (ssh's ConnectTimeout only guards the
    # handshake). On timeout the child ssh is killed directly with Process.Kill($true) (whole
    # process tree): a Start-ThreadJob Stop-Job cannot terminate the native ssh child, so those
    # processes leaked and accumulated across a run, and a half-dead session kept consuming the
    # target. This mirrors the bounded-probe technique in Wait-SshReady.
    $cmd = [string]$Command
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    foreach ($sshArg in @(
            '-i', $keyPath,
            '-o', 'BatchMode=yes') +
            (Get-YurunaSshHostKeyOption) +
            @('-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=30',
            '-o', 'LogLevel=ERROR',
            $target, $cmd)) {
        $psi.ArgumentList.Add($sshArg)
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Warning "Invoke-GuestSsh: Process.Start('ssh') threw: $($_.Exception.Message)"
        return @{ success = $false; exitCode = -1; output = "Process.Start('ssh') failed: $($_.Exception.Message)" }
    }
    # Read both streams asynchronously to avoid the classic full-pipe deadlock; read .Result
    # only after WaitForExit confirms the streams are closed.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $completed  = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $completed) {
        Write-Warning "Invoke-GuestSsh timed out after ${TimeoutSeconds}s: $target"
        try { $proc.Kill($true) } catch { Write-Verbose "Invoke-GuestSsh Process.Kill failed: $($_.Exception.Message)" }
        $proc.Dispose()
        return @{
            success  = $false
            exitCode = -1
            output   = "Timed out after ${TimeoutSeconds}s"
        }
    }
    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    $exit       = [int]$proc.ExitCode
    $proc.Dispose()
    return @{
        success  = ($exit -eq 0)
        exitCode = $exit
        output   = ("$stdoutText$stderrText").TrimEnd()
    }
}

function Wait-GuestIp {
<#
.SYNOPSIS
Polls the host's virtualization stack for a guest VM's IPv4 address.
.DESCRIPTION
Wraps Get-GuestAddress with a bounded poll loop. Get-GuestAddress falls
back to returning $VMName when no host-side discovery answers (KVP
integration services not yet running on Hyper-V, utmctl ip-address still
empty on UTM, dhcpd_leases not yet written) -- that sentinel becomes
"keep waiting" here rather than "address found". Returns the IPv4 string
when discovered, or $null on timeout so callers can print "(pending)"
instead of guessing whether the VMName is real or fallback.
.PARAMETER VMName
Guest VM name as registered with the host hypervisor / cloud-init.
.PARAMETER TimeoutSeconds
Total time budget. Default 30 covers a warm-cache boot but bails before
the runner's own New-VM.Resource step starts so the cycle isn't double-blocked.
.PARAMETER PollSeconds
Interval between probes. Default 3 -- Get-GuestAddress is cheap on both
hosts, so polling more often than every couple of seconds adds noise
without improving latency.
.OUTPUTS
System.String IPv4 on success, $null on timeout.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-GuestAddress -VMName $VMName
        if ($candidate -and $candidate -ne $VMName -and (Test-IpAddress $candidate)) {
            return [string]$candidate
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

function Get-ServiceVmObservedState {
<#
.SYNOPSIS
Describes what is actually being OBSERVED of a service guest right now, or says
plainly that nothing is observable yet.
.DESCRIPTION
While a readiness wait runs, its progress line is the only thing an operator
has. Anything that line claims therefore has to be something a probe measured.
A fixed label such as "building the daemon" is a claim no probe supports: a
guest idling at a login prompt with cloud-init dead prints exactly the same text
as one mid-compile, so the whole budget is spent believing the second while the
first is what is on screen. A line that says only what was measured -- and says
"nothing observed yet" when that is the truth -- costs the operator nothing and
never sends them the wrong way.

Pure, so every state's wording is testable without a VM. The branches are
ordered by how much the evidence settles: the guest's own cloud-init answer
outranks a TCP probe from this host, which outranks having no address at all.
.PARAMETER Address
The address currently being probed. Empty means host-side discovery has not
answered yet, which is itself one of the states worth reporting.
.PARAMETER Port
The service port being waited on.
.PARAMETER ProbePort
The port used to ask "is this guest answering anything at all" (sshd's).
.PARAMETER Reachability
'reachable' / 'unreachable' from that probe, or 'unknown' when it has not run.
.PARAMETER CloudInitStatus
cloud-init's own status word, as the guest reported it over SSH.
.PARAMETER LastProgress
The last line cloud-init printed, as the guest reported it over SSH.
.OUTPUTS
System.String. One clause, suitable for appending to a progress line.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$Address = '',
        [int]$Port = 80,
        [int]$ProbePort = 22,
        [ValidateSet('unknown', 'reachable', 'unreachable')][string]$Reachability = 'unknown',
        [AllowEmptyString()][string]$CloudInitStatus = '',
        [AllowEmptyString()][string]$LastProgress = ''
    )
    if ([string]::IsNullOrWhiteSpace($Address)) {
        return 'no guest address discovered yet, so nothing has been probed'
    }
    if (-not [string]::IsNullOrWhiteSpace($CloudInitStatus)) {
        $tail = if ($LastProgress) { " (last step: $LastProgress)" } else { '' }
        switch -Regex ($CloudInitStatus) {
            '^(running|not started)$' { return "guest $Address says cloud-init is $CloudInitStatus$tail" }
            '^done$'                  { return "guest $Address says cloud-init FINISHED and nothing is listening on :$Port$tail" }
            '^error$'                 { return "guest $Address says cloud-init ERRORED and nothing is listening on :$Port$tail" }
            default                   { return "guest $Address reports cloud-init '$CloudInitStatus'; nothing on :$Port yet$tail" }
        }
    }
    switch ($Reachability) {
        'reachable'   { return "guest $Address accepts :$ProbePort but nothing is serving :$Port yet" }
        'unreachable' { return "guest $Address is not accepting :$ProbePort or :$Port from this host" }
        default       { return "guest $Address found; nothing observed from it yet" }
    }
}

function Get-ServiceVmReadinessVerdict {
<#
.SYNOPSIS
Turns a service VM readiness result into the bring-up's verdict, and states
which verdicts are failures.
.DESCRIPTION
A wait that ends with the daemon unbound, the guest not building and cloud-init
no longer running is a FAILED bring-up. Reporting it as a success is worse than
never waiting: the run summary then lists a working service, and the next thing
to break names a layer that never ran. So the verdict lives in one place, and
the entry point routes on it rather than each site deciding for itself.

Not every non-Ready outcome is a failure, and the difference is evidence the
guest supplied:
  * the guest confirmed the daemon is BOUND and only this host cannot open a
    socket to it -- the service is running and reaches the pool through its own
    announce, so the bring-up succeeded in every way the daemon controls;
  * cloud-init is still running -- the build is progressing and finishes on its
    own, so the honest report is "not yet", not "broken".
Everything else -- including a wait that never ran -- is a failure. A verdict
that was never taken is not a pass: nothing confirmed the daemon, so nothing
may claim it.
.PARAMETER Endpoint
The record returned by Wait-YurunaServiceVmDaemon / Wait-YurunaServiceVmEndpoint,
or $null when the wait did not run at all.
.OUTPUTS
[pscustomobject] Outcome (Ready|Unreachable|StillBuilding|NotServing),
IsFailure [bool], Summary [string].
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([psobject]$Endpoint)

    if (-not $Endpoint) {
        return [pscustomobject]@{
            Outcome   = 'NotServing'
            IsFailure = $true
            Summary   = 'the readiness wait never ran, so nothing confirmed the daemon'
        }
    }
    if ($Endpoint.Ready) {
        return [pscustomobject]@{
            Outcome   = 'Ready'
            IsFailure = $false
            Summary   = 'the daemon answered from this host'
        }
    }
    if ($Endpoint.Unreachable) {
        return [pscustomobject]@{
            Outcome   = 'Unreachable'
            IsFailure = $false
            Summary   = 'the guest confirmed the daemon is bound; only this host cannot reach it'
        }
    }
    if ($Endpoint.StillBuilding) {
        return [pscustomobject]@{
            Outcome   = 'StillBuilding'
            IsFailure = $false
            Summary   = 'cloud-init is still running, so the build is progressing'
        }
    }
    return [pscustomobject]@{
        Outcome   = 'NotServing'
        IsFailure = $true
        Summary   = 'the budget ran out with the daemon unbound and the guest not building'
    }
}

function Format-GuestSshDiagnosticHint {
<#
.SYNOPSIS
An ssh command line the operator can paste -- or, when the guest's address is
unknown, how to find it instead of a command with a hole in it.
.DESCRIPTION
`ssh stash-admin@ 'sudo tail ...'` is not a diagnostic. Interpolating an address
that was never resolved yields a command whose only effect is to send the reader
hunting for a typo in the message, and it hides the fact that is actually
blocking them: this host does not know where the guest is. Naming that, plus the
two lookups that answer it, gets them moving; a broken command does not.
.PARAMETER User
Guest login account.
.PARAMETER Address
The resolved guest address. Empty (or equal to -VMName, which is what address
resolution falls back to when it discovers nothing) selects the "unknown" text.
.PARAMETER Command
The remote command to run.
.PARAMETER VMName
The VM name, used both to recognise the resolution fallback and to build the
lookup hints.
.OUTPUTS
System.String. Either one runnable ssh line, or a short block naming the guest
as unresolved and how to resolve it.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$User,
        [AllowEmptyString()][string]$Address = '',
        [Parameter(Mandatory)][string]$Command,
        [AllowEmptyString()][string]$VMName = ''
    )
    $addr = ([string]$Address).Trim()
    if ($addr -and $addr -ne $VMName) {
        return "ssh $User@$addr '$Command'"
    }
    $vm = if ($VMName) { $VMName } else { '<vm-name>' }
    $lines = @(
        "This host never resolved an address for '$vm', so there is no ssh command to give you."
        'Find it, then ssh to it:'
    )
    if ($IsMacOS) {
        # The bundle MAC is the guest's only stable identity on this host: the
        # DHCP lease file is keyed on a name a rebuilt VM reuses, so it hands
        # back predecessors' addresses, while an ARP entry carrying the bundle's
        # MAC is this VM and no other. `arp -an` prints each octet with leading
        # zeros stripped, so the two forms are compared by eye, not by grep.
        $lines += "  utmctl ip-address '$vm'       # answers only for guests running UTM integration services"
        $lines += "  plutil -extract MacAddress raw ~/yuruna/guest.nosync/$vm.utm/config.plist"
        $lines += '  arp -an                       # the entry with that MAC (leading zeros dropped per octet) is the guest'
    } elseif ($IsWindows) {
        $lines += "  Get-VMNetworkAdapter -VMName '$vm' | Select-Object -ExpandProperty IPAddresses"
    } else {
        $lines += "  virsh -c qemu:///system domifaddr --source arp '$vm'"
    }
    $lines += "  ssh $User@<the-address-you-found> '$Command'"
    return ($lines -join [Environment]::NewLine)
}

function Resolve-GuestDiagnosticAddress {
<#
.SYNOPSIS
Last-resort address discovery for a guest whose ordinary lookup came back empty:
match the VM bundle's MAC against the host ARP table.
.DESCRIPTION
Ordinary discovery -- Get-GuestAddress, i.e. guest agent, DHCP lease file,
hypervisor KVP -- can stay silent for a guest that is demonstrably on the
network. A bridged UTM guest has no lease on this host and no agent, and a lease
keyed on a name that a rebuilt VM reuses is discarded rather than trusted. The
bundle's MAC is the identity that stays true through all of that: it is written
into the bundle at build time and is what the guest puts on the wire, so an ARP
entry carrying it is this VM and no other.

Deliberately a DIAGNOSTIC path, not a poll: identifying the guest costs an ICMP
sweep of each candidate /24, which is far too expensive to repeat every few
seconds. It runs once, when a bring-up has already failed and the alternative is
handing the operator an ssh command with no host in it.

Returns an empty string -- never the VM name -- when the guest cannot be found,
so a caller can tell "unknown" apart from a resolvable name.
.PARAMETER VMName
The VM to locate.
.PARAMETER BundlePath
Path to the UTM bundle. Defaults to the harness location for this VM name.
.PARAMETER TimeoutMinutes
Outer bound per candidate subnet. Each subnet is swept ONCE regardless, so on a
host where the guest is absent this returns in the time the sweeps take rather
than spending the budget -- see the -MaxAttempt note at the call below.
.OUTPUTS
System.String. An IPv4 address, or '' when the guest could not be identified.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$BundlePath = '',
        [int]$TimeoutMinutes = 1
    )
    # The cheap lookups first; the sweep below is only worth its cost when they
    # have nothing. Get-GuestAddress hands back the VM NAME when it discovers
    # no address, which is useful to ssh and useless as an answer here.
    $address = ''
    try { $address = [string](Get-GuestAddress -VMName $VMName) } catch { Write-Verbose "Resolve-GuestDiagnosticAddress: Get-GuestAddress: $($_.Exception.Message)" }
    if ($address -and $address -ne $VMName) { return $address }

    # Identifying a guest by bundle MAC is host-driver work and already exists
    # there; a second implementation here would be a second thing to keep
    # correct. Absent driver (non-UTM host, or Initialize-YurunaHost never ran)
    # simply means this rung is unavailable.
    $byMac = Get-Command Resolve-UtmGuestIpByMac -ErrorAction SilentlyContinue
    if (-not $byMac) { return '' }
    if (-not $BundlePath) { $BundlePath = "$HOME/yuruna/guest.nosync/$VMName.utm" }
    $plistPath = Join-Path $BundlePath 'config.plist'
    if (-not (Test-Path -LiteralPath $plistPath)) {
        Write-Verbose "Resolve-GuestDiagnosticAddress: no bundle plist at $plistPath."
        return ''
    }

    # Both networking modes are tried because the bundle decides which one this
    # VM is on, and a failed bring-up is exactly the case where that is not
    # already known here: the host LAN /24 covers a Bridged guest, UTM's own
    # 192.168.64.0/24 covers Shared NAT.
    $hostIp = ''
    if (Get-Command Get-BestHostIp -ErrorAction SilentlyContinue) {
        try { $hostIp = [string](Get-BestHostIp) } catch { Write-Verbose "Resolve-GuestDiagnosticAddress: Get-BestHostIp: $($_.Exception.Message)" }
    }
    $prefixes = @()
    if ($hostIp -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)\d{1,3}$') { $prefixes += $Matches[1] }
    if ($prefixes -notcontains '192.168.64.') { $prefixes += '192.168.64.' }

    foreach ($prefix in $prefixes) {
        $found = ''
        try {
            # ONE sweep per subnet. Left uncapped, the resolver polls until its
            # whole -TimeoutMinutes elapses, and this is the FAILURE path: the
            # caller is already past its readiness budget and every second here
            # is added to a bring-up that has finished waiting. A guest that did
            # not answer the first sweep is not going to answer a re-sweep
            # seconds later either -- it is either not on this subnet or not up.
            $found = [string](& $byMac -PlistPath $plistPath -SubnetPrefix $prefix -HostIp $hostIp `
                -TimeoutMinutes ([Math]::Max(1, $TimeoutMinutes)) -PollSeconds 5 -MaxAttempt 1)
        } catch { Write-Verbose "Resolve-GuestDiagnosticAddress: MAC match on ${prefix}0/24: $($_.Exception.Message)" }
        if ($found) { return $found }
    }
    return ''
}

function Confirm-ServiceVmAtRecoveredAddress {
<#
.SYNOPSIS
Second chance for a service bring-up whose readiness wait timed out: locate the
guest by a route the wait could not use, and probe the daemon's port THERE
before the bring-up is called failed.
.DESCRIPTION
The failure this exists for is a false negative, not a slow service. When the
wait probed an address the guest never had -- or never resolved one at all --
the daemon can be serving perfectly the whole time, and the bring-up reports it
dead. Finding the guest afterwards and printing where it is does not settle
that; only re-probing the port at the recovered address does.

Deliberately the failure path only. Locating a guest this way costs an ICMP
sweep per candidate subnet, far too much to repeat inside a poll loop, and the
question it answers -- "is the daemon actually serving somewhere this host never
looked?" -- only arises once the ordinary wait has given up.

The probe is a short wall-clock loop rather than a single connect: a guest whose
address only just became discoverable is frequently seconds away from binding,
and one refused connection is not evidence of a dead daemon.

Reports what it OBSERVED, never what it assumes. When no new address turns up,
or the port stays shut at the one that does, the record says so and the caller
fails the bring-up as it would have anyway.
.PARAMETER VMName
The service VM whose bring-up is about to be failed.
.PARAMETER Port
The daemon port to re-probe.
.PARAMETER KnownAddress
The address the readiness wait was already probing, if any. A recovered address
equal to this one is not a second chance -- it is the same probe again -- so it
is reported as Probed = $false rather than being re-tested.
.PARAMETER TimeoutSeconds
Wall-clock budget for the re-probe at the recovered address.
.PARAMETER PollSeconds
Gap between connect attempts inside that budget.
.PARAMETER TestPortOpen
The port probe, injectable so the loop can be exercised with no guest. Defaults
to Test-TcpEndpointOpen with a 1 s connect timeout, which is the same probe the
readiness wait uses -- sharing it is what keeps "the daemon answers" from
meaning two different things either side of this call.
.OUTPUTS
[pscustomobject] Address (the recovered address, or ''), Probed [bool] (whether
a re-probe actually happened), Ready [bool] (the daemon answered there),
Summary [string].
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$Port = 80,
        [AllowEmptyString()][AllowNull()][string]$KnownAddress = '',
        [int]$TimeoutSeconds = 60,
        [int]$PollSeconds = 3,
        [scriptblock]$TestPortOpen
    )
    if (-not $TestPortOpen) { $TestPortOpen = { param($addr, $p) Test-TcpEndpointOpen -Address $addr -Port $p -TimeoutMilliseconds 1000 } }
    $result = [ordered]@{ Address = ''; Probed = $false; Ready = $false; Summary = '' }

    $recovered = ''
    try { $recovered = [string](Resolve-GuestDiagnosticAddress -VMName $VMName) }
    catch { Write-Verbose "Confirm-ServiceVmAtRecoveredAddress: $($_.Exception.Message)" }
    if (-not $recovered) {
        $result.Summary = "'$VMName' could not be located by any discovery route this host has"
        return [pscustomobject]$result
    }
    $result.Address = $recovered
    if ($KnownAddress -and $recovered -eq $KnownAddress) {
        $result.Summary = "'$VMName' is at $recovered, the address the wait already probed -- nothing new to try"
        return [pscustomobject]$result
    }

    $result.Probed = $true
    Write-Warning ("Located '$VMName' at $recovered -- an address the readiness wait never probed. " +
                   "Re-checking :$Port there before failing the bring-up.")
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    while ((Get-Date) -lt $deadline) {
        $open = $false
        try { $open = [bool](& $TestPortOpen $recovered $Port) }
        catch { Write-Verbose "Confirm-ServiceVmAtRecoveredAddress: probe ${recovered}:${Port}: $($_.Exception.Message)" }
        if ($open) {
            $result.Ready   = $true
            $result.Summary = "the daemon IS serving at ${recovered}:$Port -- the wait was probing an address this guest never had"
            return [pscustomobject]$result
        }
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
    }
    $result.Summary = "${recovered}:$Port did not answer within ${TimeoutSeconds}s either, so the guest was found but its daemon is not serving"
    return [pscustomobject]$result
}

# Observation shared between a readiness wait's injected hooks and the progress
# line that reports it. Module-scoped rather than captured into the hooks: they
# run inside Wait-YurunaServiceVmEndpoint's call chain, where a local of the same
# name in that function would shadow a dynamically-scoped capture without a
# sound, and $script: resolves in THIS module regardless of who is calling.
$script:ServiceVmObservation = $null

function Wait-YurunaServiceVmDaemon {
<#
.SYNOPSIS
Wait for a service guest's daemon to answer, reporting on every poll what is
actually observed of the guest rather than asserting what it is doing.
.DESCRIPTION
Wraps Wait-YurunaServiceVmEndpoint, which takes a fixed -ProgressLabel and
prints it unchanged for the whole wait. That label is the one part of the wait
that is not measured, and it is the part the operator reads: a guest idle at a
login prompt with cloud-init dead prints the same "building the daemon" as one
mid-compile, for as long as the budget lasts, and the operator waits it out.

So the fixed label is suppressed and this function paints the line from the
observations the wait already makes -- which address resolved, whether the guest
accepts TCP at all, and, once SSH answers, cloud-init's own status and last
printed step. When none of that is available the line says exactly that.

The observations come from the SAME hooks the wait uses for its own decisions
(-ResolveAddress, -InvokeInGuest) rather than from extra probes of this
function's own. Two independent opinions about where the guest is and what it is
doing would eventually disagree, and a progress line that contradicts the
verdict is worse than no progress line.

One extra probe does exist -- a bounded TCP connect to sshd -- because nothing
else can tell "the guest is up and the daemon is not ready" from "the guest is
not answering at all", and those two need different actions. It is throttled:
against a dead address every attempt costs its full timeout.
.PARAMETER ServiceLabel
How the daemon is named in the progress line, e.g. 'stash-service daemon'.
.PARAMETER SshPort
Port used for the reachability probe. sshd's, because it is the one port a
service guest is expected to answer before its own daemon exists.
.PARAMETER ReachabilityEverySeconds
Minimum seconds between reachability probes.
.PARAMETER InGuestCheckAfterSeconds
.PARAMETER InGuestCheckEverySeconds
When the guest is first asked about itself over SSH, and how often afterwards.
Forwarded to the wait, which owns the round trip.
.PARAMETER ResolveAddress
.PARAMETER TestPortOpen
.PARAMETER InvokeInGuest
    The three outside effects -- resolve, probe, ask the guest -- as injectable
    scriptblocks, defaulting to the real ones and forwarded to the wait so both
    layers observe the same guest. Same reason Wait-YurunaServiceVmEndpoint takes
    them: they are the only parts that need a running VM, so injecting them is
    what lets the wording and the verdict be tested without one.
.OUTPUTS
[pscustomobject] Wait-YurunaServiceVmEndpoint's record, plus ObservedState (the
final observation, in words) and Reachability.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$Port = 80,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [int]$MaxTimeoutSeconds = 0,
        [AllowEmptyString()][string]$Address = '',
        [AllowEmptyString()][string]$GuestKey = '',
        [AllowEmptyString()][string]$User = '',
        [string]$ServiceLabel = 'daemon',
        [int]$SshPort = 22,
        [int]$ReachabilityEverySeconds = 15,
        [int]$InGuestCheckAfterSeconds = 120,
        [int]$InGuestCheckEverySeconds = 60,
        [int]$PollSeconds = 3,
        [ValidateSet('auto', 'inplace', 'lines', 'none')][string]$ProgressMode = 'auto',
        [scriptblock]$OnAddressChanged,
        [scriptblock]$ResolveAddress,
        [scriptblock]$TestPortOpen,
        [scriptblock]$InvokeInGuest
    )
    if (-not $ResolveAddress) { $ResolveAddress = { param($name) [string](Get-GuestAddress -VMName $name) } }
    if (-not $TestPortOpen)   { $TestPortOpen   = { param($addr, $p) Test-TcpEndpointOpen -Address $addr -Port $p -TimeoutMilliseconds 1000 } }
    if (-not $InvokeInGuest)  { $InvokeInGuest  = { param($name, $key, $account, $cmd) Invoke-GuestSsh -VMName $name -GuestKey $key -User $account -TimeoutSeconds 30 -Command $cmd } }
    # Same normalization the wait applies, computed here too because the progress
    # line quotes the cap: a line promising a ceiling the wait does not honor is
    # the class of claim this function exists to remove.
    $capSeconds = if ($MaxTimeoutSeconds -le 0) { $TimeoutSeconds * 2 }
                  elseif ($MaxTimeoutSeconds -lt $TimeoutSeconds) { $TimeoutSeconds }
                  else { $MaxTimeoutSeconds }
    $script:ServiceVmObservation = @{
        VMName          = $VMName
        Address         = [string]$Address
        Reachability    = 'unknown'
        CloudInitStatus = ''
        LastProgress    = ''
        State           = ''
        LastReachCheck  = [datetime]::MinValue
        StartedAt       = Get-Date
        Port            = $Port
        SshPort         = $SshPort
        ReachEvery      = [Math]::Max(1, $ReachabilityEverySeconds)
        CapMinutes      = [int][Math]::Ceiling($capSeconds / 60)
        Label           = $ServiceLabel
        ProgressMode    = $ProgressMode
        Resolve         = $ResolveAddress
        PortOpen        = $TestPortOpen
        InGuest         = $InvokeInGuest
    }

    $paint = {
        $o = $script:ServiceVmObservation
        if (-not $o -or $o.ProgressMode -eq 'none') { return }
        $o.State = Get-ServiceVmObservedState -Address $o.Address -Port $o.Port -ProbePort $o.SshPort `
            -Reachability $o.Reachability -CloudInitStatus $o.CloudInitStatus -LastProgress $o.LastProgress
        $mode = $o.ProgressMode
        if ($mode -eq 'auto') { $mode = if (Test-YurunaProgressLineSupported) { 'inplace' } else { 'lines' } }
        $elapsed = [int]((Get-Date) - $o.StartedAt).TotalSeconds
        # Second resolution on a terminal is the liveness signal -- the line is
        # rewritten in place, so it costs nothing. Into a log it is noise: nobody
        # reading a file afterwards needs the seconds, and a minute-resolution
        # clock keeps consecutive entries legible next to each other.
        $clock = if ($mode -eq 'inplace') {
            '{0:D2}m{1:D2}s' -f [int][Math]::Floor($elapsed / 60), ($elapsed % 60)
        } else {
            "$([int][Math]::Floor($elapsed / 60))m"
        }
        # The OBSERVATION is the identity, not the rendered line: into a log this
        # emits the moment what is being reported changes, and otherwise once per
        # throttle interval however the clock moves underneath it. The wait's own
        # start time is in the key because the throttle state is module-scoped --
        # without it, a later wait whose first observation matches an earlier
        # wait's last one would print nothing at all until the interval elapsed.
        Write-YurunaWaitProgress -Mode $mode `
            -Message "$clock / up to $($o.CapMinutes)m  waiting for the $($o.Label) on :$($o.Port) -- $($o.State)" `
            -IdentityKey "$($o.VMName)|$($o.StartedAt.Ticks)|$($o.Label)|$($o.State)"
    }

    $resolveHook = {
        param($name)
        $o = $script:ServiceVmObservation
        $addr = ''
        try { $addr = [string](& $o.Resolve $name) } catch { Write-Verbose "Wait-YurunaServiceVmDaemon: address resolve: $($_.Exception.Message)" }
        # The VM-name fallback is not an address; passing it on would have the
        # wait dial a name that does not resolve.
        if ($addr -eq $name) { $addr = '' }
        # An empty answer is not a discovery that the guest has no address. The
        # wait keeps probing the last address it held -- including the one the
        # caller seeded from the hypervisor -- so forgetting it here would put
        # "no guest address discovered yet, so nothing has been probed" on screen
        # while a probe runs against a known address every poll. That is the same
        # unmeasured claim this wrapper exists to remove, merely inverted. It
        # would also make the line flip text on every poll whenever discovery is
        # intermittent, which is what floods a log. Only a NEW address replaces
        # the one in hand.
        if ($addr -and $addr -ne $o.Address) {
            $o.Address = $addr
            # A reading taken against the address the guest left proves nothing
            # about the one it moved to.
            $o.Reachability = 'unknown'
            $o.LastReachCheck = [datetime]::MinValue
        }
        # Probes the address in USE, which is the seeded one until discovery
        # answers differently. Gating this on the per-poll answer instead leaves
        # reachability 'unknown' for the whole wait on every host that seeds an
        # address, and reachability is the only thing separating "guest up,
        # daemon not ready" from "guest answering nothing".
        if ($o.Address -and ((Get-Date) - $o.LastReachCheck).TotalSeconds -ge $o.ReachEvery) {
            $o.LastReachCheck = Get-Date
            $reachable = $false
            try { $reachable = [bool](& $o.PortOpen $o.Address $o.SshPort) } catch { Write-Verbose "Wait-YurunaServiceVmDaemon: reachability probe: $($_.Exception.Message)" }
            $o.Reachability = if ($reachable) { 'reachable' } else { 'unreachable' }
        }
        & $paint
        return $addr
    }

    $inGuestHook = {
        param($name, $key, $account, $cmd)
        $o = $script:ServiceVmObservation
        $answer = $null
        try {
            $answer = & $o.InGuest $name $key $account $cmd
        } catch { Write-Verbose "Wait-YurunaServiceVmDaemon: in-guest probe: $($_.Exception.Message)" }
        # The wait parses this same output for its own decisions, but keeps the
        # readings to itself. Reading them again here is what lets the progress
        # line quote the guest instead of guessing at it.
        if ($answer) {
            $text = [string]$answer.output
            if ($text -match 'YURUNA_CLOUDINIT=(.*)') { $o.CloudInitStatus = $Matches[1].Trim() }
            if ($text -match 'YURUNA_PROGRESS=(.*)')  { $o.LastProgress    = $Matches[1].Trim() }
            if ($text -match 'YURUNA_(NOT_)?LISTENING') {
                # SSH completing IS reachability, measured more strongly than a
                # bare TCP connect could measure it.
                $o.Reachability   = 'reachable'
                $o.LastReachCheck = Get-Date
            }
        }
        return $answer
    }

    $waitArgs = @{
        VMName                   = $VMName
        Port                     = $Port
        TimeoutSeconds           = $TimeoutSeconds
        MaxTimeoutSeconds        = $capSeconds
        Address                  = $Address
        GuestKey                 = $GuestKey
        User                     = $User
        InGuestCheckAfterSeconds = $InGuestCheckAfterSeconds
        InGuestCheckEverySeconds = $InGuestCheckEverySeconds
        PollSeconds              = $PollSeconds
        # Empty on purpose: the fixed label is the thing this wrapper replaces,
        # and an empty one is what silences the wait's own painting so the two
        # do not both draw. -ProgressMode is still forwarded, so a caller that
        # asked for silence gets it from both layers rather than from this one
        # only.
        ProgressLabel            = ''
        ProgressMode             = $ProgressMode
        ResolveAddress           = $resolveHook
        TestPortOpen             = $TestPortOpen
        InvokeInGuest            = $inGuestHook
    }
    if ($OnAddressChanged) { $waitArgs.OnAddressChanged = $OnAddressChanged }

    try {
        $result = Wait-YurunaServiceVmEndpoint @waitArgs
        $o = $script:ServiceVmObservation
        # The returned record is the authority on what the wait concluded; the
        # running observation only fills the gaps it does not carry.
        if ($result) {
            if ($result.Address)         { $o.Address         = [string]$result.Address }
            if ($result.CloudInitStatus) { $o.CloudInitStatus = [string]$result.CloudInitStatus }
            if ($result.LastProgress)    { $o.LastProgress    = [string]$result.LastProgress }
            if ($result.Ready)           { $o.Reachability    = 'reachable' }
        }
        $finalState = if ($result -and $result.Ready) {
            "guest $($o.Address) is serving :$Port"
        } else {
            Get-ServiceVmObservedState -Address $o.Address -Port $Port -ProbePort $SshPort `
                -Reachability $o.Reachability -CloudInitStatus $o.CloudInitStatus -LastProgress $o.LastProgress
        }
        if ($result) {
            $result | Add-Member -NotePropertyName 'ObservedState' -NotePropertyValue $finalState -Force
            $result | Add-Member -NotePropertyName 'Reachability'  -NotePropertyValue $o.Reachability -Force
        }
        return $result
    } finally {
        Close-YurunaWaitProgress
        $script:ServiceVmObservation = $null
    }
}

Export-ModuleMember -Function Initialize-YurunaSshKey, Get-YurunaSshPublicKey, Get-YurunaSshPrivateKeyPath, Get-YurunaSshHostKeyOption, Wait-SshReady, Get-SshReadinessFailureCause, Invoke-GuestSsh, Get-GuestSshUser, Set-GuestSshUserOverride, Clear-GuestSshUserOverride, Get-GuestAddress, Wait-GuestIp, Get-ServiceVmObservedState, Get-ServiceVmReadinessVerdict, Format-GuestSshDiagnosticHint, Resolve-GuestDiagnosticAddress, Confirm-ServiceVmAtRecoveredAddress, Wait-YurunaServiceVmDaemon
