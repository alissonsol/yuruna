<#PSScriptInfo
.VERSION 2026.05.15
.GUID 422c9a3d-41bb-4e8c-9b64-5f7a1d0c9a12
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
#>

#requires -version 7

# Test.Ssh -- SSH-based guest driver for yuruna test harness.
#
# Parallel path to the keystroke-injection flow in Invoke-Sequence.psm1.
# Selected via the "keystrokeMechanism" flag in test/test.config.yml:
#   "GUI" (default) -- type characters into the VM console
#   "SSH"           -- run commands over SSH
# Comparisons are case-insensitive; the canonical form stored in
# test.config.yml is uppercase (normalized by the test-config validator).
#
# A single per-host ed25519 key pair is generated on first use and stored
# under test/.ssh/. The public key is injected into each guest's cloud-init
# user-data at VM creation time (see SSH_AUTHORIZED_KEY_PLACEHOLDER).
#
# === SSH host-key policy ===================================================
# Yuruna destroys and recreates guest VMs constantly, and each fresh guest
# regenerates its own SSH host key on first boot. Because VM name + IP are
# reused across cycles (libvirt's NAT pool hands out the same 192.168.122.x
# slot to the next VM with the same MAC seed, KVP/utmctl/dhcpd_leases all
# do the same), each cycle's guest presents a DIFFERENT host key under an
# address that previously had a different key. OpenSSH's stock behaviour
# is to print "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" on the
# first mismatch and (with StrictHostKeyChecking=ask) refuse to connect.
#
# Every yuruna ssh call site therefore passes these three options together,
# which collectively make ssh treat each fresh guest as if it were never
# seen before:
#   -o StrictHostKeyChecking=no       accept any host key without prompting
#   -o UserKnownHostsFile=/dev/null   don't read or write ~/.ssh/known_hosts
#   -o GlobalKnownHostsFile=/dev/null don't read /etc/ssh/ssh_known_hosts
#                                     (closes the "operator once ran
#                                      ssh-keyscan into the system file"
#                                      regression path)
#
# OpenSSH on Windows accepts /dev/null verbatim (Microsoft's port special-
# cases the literal string), so the same line works on every host. New ssh
# call sites in this module / Test.Diagnostic MUST include all three.

# -Global: Test.Ssh is loaded transitively by Invoke-Sequence (line 2411)
# during Start-GuestOS. Without -Global, -Force evicts the existing -Global
# Test.VM.common from the process and reloads it into Test.Ssh's private
# scope -- so the runner's global session loses Wait-VMRunning and the
# next New-VM.Resource step crashes with "Wait-VMRunning is not recognized".
# Test.Host.psm1's module-load self-heal only fires at cycle start, not
# mid-cycle after Start-GuestOS triggers this eviction.
Import-Module (Join-Path $PSScriptRoot 'Test.VM.common.psm1') -Force -DisableNameChecking -Global

$script:SshKeyDir  = Join-Path (Split-Path -Parent $PSScriptRoot) ".ssh"
$script:SshKeyPath = Join-Path $script:SshKeyDir "yuruna_ed25519"
$script:SshPubPath = "$script:SshKeyPath.pub"

function Initialize-YurunaSshKey {
<#
.SYNOPSIS
Ensures the per-host yuruna SSH key pair exists and returns the private key path.
.DESCRIPTION
Creates test/.ssh/yuruna_ed25519 (and .pub) on first call via ssh-keygen, tightens
permissions so ssh will accept it, and is a no-op on subsequent calls.
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

    # If a key already exists, verify it can be loaded with an EMPTY passphrase.
    # Earlier versions of this module passed -N '""' to ssh-keygen, which under
    # PowerShell native-command quoting becomes the literal 2-character string
    # "" -- encrypting the key with that as a passphrase. Such keys cannot be
    # used under BatchMode=yes, and ssh fails silently after "Server accepts key".
    # If we detect an unreadable existing key, delete and regenerate.
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
        # -N "" = empty passphrase so the runner can connect non-interactively.
        # PowerShell 7 with the default Standard argument-passing mode DOES pass
        # an empty string as a real empty arg to native commands, so "" is correct.
        & $sshKeygen -t ed25519 -f $script:SshKeyPath -N "" -C "yuruna-test-harness@$env:COMPUTERNAME" -q 2>&1 | Out-Null
        if (-not (Test-Path $script:SshKeyPath -PathType Leaf)) {
            throw "ssh-keygen failed to create key at $script:SshKeyPath"
        }
        # Verify the freshly generated key can be loaded with an empty passphrase.
        # Catches future regressions of the same quoting bug immediately at creation.
        $probe = & $sshKeygen -y -P '' -f $script:SshKeyPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Newly generated key is not loadable with empty passphrase. ssh-keygen output: $($probe | Out-String)"
        }
    }

    # Enforce strict private-key permissions on EVERY call (not just on creation).
    # Windows OpenSSH refuses keys whose ACL lets unauthorized principals read,
    # and a prior loose ACL from an earlier run would silently break authentication.
    if ($IsWindows) {
        # Full reset: remove inheritance, strip every non-owner ACL, grant owner only.
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
.OUTPUTS
System.String. Absolute path to the private key file.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Initialize-YurunaSshKey | Out-Null
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

After the Yuruna.Host refactor, the authoritative IP-discovery logic
lives in the host driver's `Get-VMIp` (host/<host>/modules/Yuruna.Host.psm1).
This function delegates there when available; otherwise it falls back
to the inline host-conditional probe so standalone Test.Ssh consumers
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
                foreach ($b in $blocks) {
                    $text = $b.Value
                    if ($text -match $namePattern) {
                        if (($text -match "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") -and (Test-Ipv4Address $Matches[1])) {
                            return [string]$Matches[1]
                        }
                    }
                }
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
Returns the harness's greppable per-guest test user. The 'y[aw]user1'
pattern keeps the name unique enough to grep cleanly out of OS logs
while encoding the guest family in the second character:
  guest.amazon.linux   -> yauser1   (seeded on top of the cloud-image
                                     default 'ec2-user')
  guest.ubuntu.server  -> yuuser1   (replaces the cloud-image default
                                     'ubuntu' via autoinstall)
  guest.windows.11     -> ywuser1   (created by autounattend.xml)
The username for each guest must match the `username:` variable in
the corresponding test/sequences/**/*.<guest>.yml file.
.PARAMETER GuestKey
The guest identifier used throughout the harness (e.g. guest.ubuntu.server).
.OUTPUTS
System.String. Username to log in as over SSH.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$GuestKey)
    switch ($GuestKey) {
        "guest.ubuntu.server"  { return "yuuser1" }
        "guest.amazon.linux"   { return "yauser1" }
        "guest.windows.11"     { return "ywuser1" }
        default { return "root" }
    }
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
Guest identifier (e.g. guest.amazon.linux); determines the SSH login user.
.PARAMETER TimeoutSeconds
Maximum total seconds to keep retrying. Default 300.
.PARAMETER PollSeconds
Seconds between connection attempts. Default 5.
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
    while ((Get-Date) -lt $deadline) {
        $attempts++
        # Re-resolve each iteration: on Hyper-V the IP may not be reported
        # until integration services come up a few seconds into boot.
        $target = Get-GuestAddress -VMName $VMName
        if ($target -ne $lastTarget) {
            Write-Debug "  sshWaitReady target: $user@$target (from VMName '$VMName')"
            $lastTarget = $target
        }
        $result = & ssh -i $key `
            -o BatchMode=yes `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o GlobalKnownHostsFile=/dev/null `
            -o ConnectTimeout=5 `
            -o LogLevel=ERROR `
            "$user@$target" "echo yuruna-ssh-ready" 2>&1
        if ($LASTEXITCODE -eq 0 -and "$result" -match "yuruna-ssh-ready") {
            Write-Debug "SSH ready after $attempts attempt(s): $user@$target"
            return $true
        }
        $lastError = ($result | Out-String).Trim()
        Start-Sleep -Seconds $PollSeconds
    }

    # Failure path: dump everything we can for diagnostics.
    Write-Warning "SSH did not become ready within ${TimeoutSeconds}s (${attempts} attempts): $user@$lastTarget"
    Write-Warning "  last ssh error: $lastError"
    Write-Warning "  private key   : $key"

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

    # 3. One verbose handshake so the actual reason is in the log.
    Write-Warning "  --- verbose handshake follows ---"
    try {
        $vout = & ssh -v -i $key `
            -o BatchMode=yes `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o GlobalKnownHostsFile=/dev/null `
            -o ConnectTimeout=5 `
            "$user@$lastTarget" "echo yuruna-ssh-ready" 2>&1
        foreach ($line in (($vout | Out-String) -split "`r?`n")) {
            if ($line.Trim()) { Write-Warning "    [ssh -v] $($line.TrimEnd())" }
        }
    } catch { Write-Warning "  verbose dump failed: $_" }
    Write-Warning "  --- end verbose handshake ---"

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
Guest identifier (e.g. guest.amazon.linux); determines the SSH login user.
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

    # Run ssh in a background job so TimeoutSeconds bounds total runtime, not
    # just TCP setup. ConnectTimeout still guards the handshake phase.
    $job = Start-Job -ScriptBlock {
        $out = & ssh -i $using:keyPath `
            -o BatchMode=yes `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o GlobalKnownHostsFile=/dev/null `
            -o ConnectTimeout=10 `
            -o ServerAliveInterval=30 `
            -o LogLevel=ERROR `
            $using:target $using:Command 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Write-Warning "Invoke-GuestSsh timed out after ${TimeoutSeconds}s: $user@$VMName"
        Stop-Job  -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{
            success  = $false
            exitCode = -1
            output   = "Timed out after ${TimeoutSeconds}s"
        }
    }

    $jobResult = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $exit = [int]$jobResult.ExitCode
    return @{
        success  = ($exit -eq 0)
        exitCode = $exit
        output   = ("$($jobResult.Output)").TrimEnd()
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

Export-ModuleMember -Function Initialize-YurunaSshKey, Get-YurunaSshPublicKey, Get-YurunaSshPrivateKeyPath, Wait-SshReady, Invoke-GuestSsh, Get-GuestSshUser, Get-GuestAddress, Wait-GuestIp
