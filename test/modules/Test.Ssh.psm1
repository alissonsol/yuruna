<#PSScriptInfo
.VERSION 2026.07.03
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
# Invoke-Sequence.psm1; selected by test.config.yml "keystrokeMechanism"
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

# Per-cycle overrides for Get-GuestSshUser. Populated by the runner
# (Invoke-TestInnerRunner / Test-Sequence) from the cycle plan's
# effectiveUsername so a workload's `variables.username:` cascade
# reaches every SSH callsite that goes through Get-GuestSshUser:
# Wait-SshReady, Invoke-GuestSsh, Save-GuestDiagnostic, the host
# driver Send-Text / Send-Key SSH-mode dispatchers, and the inner
# runner's fetchAndExecute SSH path. The alternative -- threading a
# -Username parameter through every public signature -- would touch
# every callsite (and the host contract) for the same outcome.
#
# Anchored in the global scope: Save-GuestDiagnostic and several
# host drivers -Force re-import Test.Ssh defensively. A module-scoped
# `$script:GuestSshUserOverrides = @{}` would be re-initialised on
# every re-import, wiping the cascade value Test-Sequence /
# Invoke-TestInnerRunner registered at plan-resolution time, falling
# SSH auth back to the per-guest default (e.g. yauser1) and breaking
# workloads whose `variables.username:` was meant to propagate down
# the chain. Same eviction-safe pattern Test.Output and the
# Test.Registry-based registries already use. Set-Variable
# / Get-Variable -Scope Global is used instead of `$global:` so PSSA's
# PSAvoidGlobalVars stays quiet for the rest of this large module.
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

    # Fallback path for standalone Test.Ssh use (no Yuruna.Host loaded).
    # Same lookups as the contract's Get-VMIp, kept here so SSH-client
    # users (Wait-SshReady / Invoke-GuestSsh) work even when callers
    # forget to call Initialize-YurunaHost first.
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
                $blocks = [regex]::Matches($content, '\{[^}]*\}')
                # Escape the VMName once; the original interpolated
                # $([regex]::Escape($VMName)) into the -match pattern on
                # every block, forcing a fresh regex compile per block.
                $vmNameEscaped = [regex]::Escape($VMName)
                $namePattern = "(?m)^\s*name=$vmNameEscaped\s*$"
                # A rebuilt VM reuses its hostname, so dhcpd_leases can hold
                # several name= blocks (live VM + stale deleted-predecessor
                # leases). Pick the largest `lease=` expiry: the live VM keeps
                # renewing while a dead VM's lease only ages. Returning the
                # first match would hand back a predecessor's dead IP.
                $bestIp = $null
                $bestLease = -1
                foreach ($b in $blocks) {
                    $text = $b.Value
                    if ($text -notmatch $namePattern) { continue }
                    if (($text -match "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") -and (Test-Ipv4Address $Matches[1])) {
                        $ip = [string]$Matches[1]
                        $leaseVal = 0
                        if ($text -match "(?m)^\s*lease=0x([0-9a-fA-F]+)\s*$") {
                            $leaseVal = [Convert]::ToInt64($Matches[1], 16)
                        }
                        if ($leaseVal -ge $bestLease) { $bestLease = $leaseVal; $bestIp = $ip }
                    }
                }
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
    map is already empty in practice. Test-Sequence (and any future
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
    # Per-probe wall-clock cap. ConnectTimeout=5 only bounds TCP setup; if
    # the SSH banner / kex_exchange_identification stalls (or the post-
    # handshake session goes half-dead -- TCP ESTABLISHED both ends, no
    # data flowing), ssh has no further timeout of its own. Running the
    # probe foreground in the runner runspace would then make the outer
    # `while ((Get-Date) -lt $deadline)` deadline useless: it is only
    # checked between iterations, so one stuck ssh would hold the loop
    # forever and saveSystemDiagnostic would blow past Save-GuestDiagnostic's
    # cap.
    #
    # In-process .NET Process.Start + WaitForExit(timeoutMs) gives a
    # hard per-probe cap WITHOUT the Start-Job / Wait-Job runspace cost
    # (~200-500 ms cold-start per iteration; ~18 iterations on a 90 s
    # boot is 4-9 s of pure overhead). On timeout the child ssh is
    # killed directly via Process.Kill($true) (entire process tree),
    # which also closes the leaked OS-level ssh that the prior Start-Job
    # implementation left behind. The ServerAlive options below shorten
    # the in-flight detection of a half-dead session to ~6 s so most
    # probes complete well under the cap on a healthy guest.
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
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('StrictHostKeyChecking=no')
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('UserKnownHostsFile=/dev/null')
        $psi.ArgumentList.Add('-o'); $psi.ArgumentList.Add('GlobalKnownHostsFile=/dev/null')
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
            $remainingSec = ($deadline - (Get-Date)).TotalSeconds
            if ($remainingSec -gt 0) { Start-Sleep -Seconds ([Math]::Min([double]$thisPollSeconds, $remainingSec)) }
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
        $remainingSec = ($deadline - (Get-Date)).TotalSeconds
        if ($remainingSec -gt 0) {
            Start-Sleep -Seconds ([Math]::Min([double]$thisPollSeconds, $remainingSec))
        }
    }

    # Failure path. Classify WHY before dumping diagnostics, so the dumps and
    # the operator guidance target the actual cause.
    $cause = Get-SshReadinessFailureCause -IpDiscovered $ipEverDiscovered -LastError $lastError
    Write-Warning "SSH did not become ready within ${TimeoutSeconds}s (${attempts} attempts): $user@$lastTarget"
    Write-Warning "  cause         : $cause (ipDiscovered=$ipEverDiscovered)"
    Write-Warning "  last ssh error: $lastError"
    Write-Warning "  private key   : $key"

    if ($cause -eq 'ip_not_discovered') {
        # Never resolved a guest IP and never reached sshd: a host-side
        # discovery wait (KVP integration services / DHCP lease / utmctl
        # ip-address still empty), not an sshd or auth fault. The pubkey / ACL
        # / verbose-handshake dumps below diagnose sshd+auth, so against the
        # bare VM-name fallback they would only echo DNS failures -- skip them
        # and point at the real fix instead.
        Write-Warning "  guest IP was never discovered within the budget -- the host-side"
        Write-Warning "  discovery layer (KVP / DHCP lease / utmctl) did not report an"
        Write-Warning "  address. This is a discovery wait, not an sshd/auth failure:"
        Write-Warning "  extend the budget or repair discovery (e.g. active ARP probe on a"
        Write-Warning "  Hyper-V External vSwitch) before debugging sshd."
    } else {
        # We reached (or could resolve) a host: dump the sshd/auth diagnostics.
        # 1. Local public key + fingerprint
        try {
            $pubPath = "$key.pub"
            if (Test-Path $pubPath) {
                $pubLine = (Get-Content -Raw $pubPath).Trim()
                Write-Warning "  local pubkey  : $pubLine"
                $fp = & ssh-keygen -lf $pubPath 2>&1
                Write-Warning "  fingerprint   : $fp"
            }
        } catch { Write-Warning "  pubkey dump failed: $_" }

        # 2. Private-key ACL (Windows OpenSSH strict-mode rejection diagnostic)
        if ($IsWindows) {
            try {
                $aclLines = (& icacls $key 2>&1) -split "`r?`n" | Where-Object { $_.Trim() }
                foreach ($l in $aclLines) { Write-Warning "  acl: $l" }
            } catch { Write-Warning "  icacls failed: $_" }
        }

        # 3. One verbose handshake so the actual reason is in the log. Bounded
        # by the same Process.Start + WaitForExit + Kill($true) harness as the
        # probe loop: `ssh -v` reintroduces a foreground ssh, so a guest that
        # accepts TCP then stalls in banner/kex would otherwise hang the runner
        # during the failure/diagnostics phase (saveDiagnostics is downstream --
        # the worst place to block).
        Write-Warning "  --- verbose handshake follows ---"
        try {
            $vpsi = [System.Diagnostics.ProcessStartInfo]::new()
            $vpsi.FileName = 'ssh'
            $vpsi.RedirectStandardOutput = $true
            $vpsi.RedirectStandardError  = $true
            $vpsi.UseShellExecute = $false
            foreach ($a in @('-v', '-i', $key,
                    '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=no',
                    '-o', 'UserKnownHostsFile=/dev/null',
                    '-o', 'GlobalKnownHostsFile=/dev/null',
                    '-o', 'ConnectTimeout=5',
                    "$user@$lastTarget", 'echo yuruna-ssh-ready')) {
                $vpsi.ArgumentList.Add($a)
            }
            $vproc = [System.Diagnostics.Process]::Start($vpsi)
            $voTask = $vproc.StandardOutput.ReadToEndAsync()
            $veTask = $vproc.StandardError.ReadToEndAsync()
            if ($vproc.WaitForExit($probeCapSeconds * 1000)) {
                foreach ($line in (($voTask.Result + $veTask.Result) -split "`r?`n")) {
                    if ($line.Trim()) { Write-Warning "    [ssh -v] $($line.TrimEnd())" }
                }
            } else {
                try { $vproc.Kill($true) } catch { Write-Verbose "verbose-dump Kill failed: $($_.Exception.Message)" }
                Write-Warning "    [ssh -v] verbose handshake exceeded ${probeCapSeconds}s (ssh hung post-TCP; killed)."
            }
            $vproc.Dispose()
        } catch { Write-Warning "  verbose dump failed: $($_.Exception.Message)" }
        Write-Warning "  --- end verbose handshake ---"
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
.OUTPUTS
System.Collections.Hashtable with keys: success (bool), exitCode (int), output (string).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$VMName,
        [string]$GuestKey,
        [string]$Command,
        [int]$TimeoutSeconds = 900
    )
    $user    = Get-GuestSshUser -GuestKey $GuestKey
    $keyPath = Get-YurunaSshPrivateKeyPath
    $address = Get-GuestAddress -VMName $VMName
    $target  = "$user@$address"
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
            '-o', 'BatchMode=yes',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'GlobalKnownHostsFile=/dev/null',
            '-o', 'ConnectTimeout=10',
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

Export-ModuleMember -Function Initialize-YurunaSshKey, Get-YurunaSshPublicKey, Get-YurunaSshPrivateKeyPath, Wait-SshReady, Get-SshReadinessFailureCause, Invoke-GuestSsh, Get-GuestSshUser, Set-GuestSshUserOverride, Clear-GuestSshUserOverride, Get-GuestAddress, Wait-GuestIp
