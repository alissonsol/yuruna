<#PSScriptInfo
.VERSION 0.1
.GUID 422c9a3d-41bb-4e8c-9b64-5f7a1d0c9a12
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
#>

#requires -version 7

# Test.Ssh -- SSH-based guest driver for yuruna test harness.
#
# Parallel path to the keystroke-injection flow in Invoke-Sequence.psm1.
# Selected via the "keystrokeMechanism" flag in test/test-config.json:
#   "GUI" (default) -- type characters into the VM console
#   "SSH"           -- run commands over SSH
# Comparisons are case-insensitive; the canonical form stored in
# test-config.json is uppercase (normalized by the test-config validator).
#
# A single per-host ed25519 key pair is generated on first use and stored
# under test/.ssh/. The public key is injected into each guest's cloud-init
# user-data at VM creation time (see SSH_AUTHORIZED_KEY_PLACEHOLDER).

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
Default Switch or UTM on macOS, so `ssh user@vm-name` fails with "could not
resolve hostname". This helper asks the host's virtualization stack for the
VM's current IPv4 and returns it.

  Hyper-V (Windows)  -> Get-VMNetworkAdapter integration-services query
  UTM    (macOS)     -> utmctl ip-address <VMName>

If no address is reported yet (integration services still coming up, or
the VM has just booted), falls back to VMName so the caller's retry loop
can try again shortly.
.PARAMETER VMName
The yuruna VM name (the hostname assigned by cloud-init).
.OUTPUTS
System.String. An IPv4 address if one was discovered, otherwise the VMName.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName)

    if ($IsWindows -and (Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) {
        try {
            $addrs = (Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop).IPAddresses
            $ipv4  = $addrs | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            if ($ipv4) { return [string]$ipv4 }
        } catch {
            Write-Debug "Get-VMNetworkAdapter failed for ${VMName}: $_"
        }
    }

    if ($IsMacOS -and (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        # utmctl ip-address emits one address per line. On Apple Virtualization
        # backend it reports the guest IP as soon as integration services are up.
        # Filter to IPv4 and skip loopback / link-local / UTM internal ranges.
        try {
            $output = & utmctl ip-address $VMName 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ipv4 = ($output -split "`r?`n") |
                    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
                    Where-Object { $_ -notmatch '^(127\.|169\.254\.)' } |
                    Select-Object -First 1
                if ($ipv4) { return [string]$ipv4 }
            }
        } catch {
            Write-Debug "utmctl ip-address failed for ${VMName}: $_"
        }
    }

    # macOS Apple Virtualization fallback: the built-in DHCP server for the
    # shared network writes leases to /var/db/dhcpd_leases. cloud-init sets
    # the guest hostname to VMName, so the lease's name= field matches.
    if ($IsMacOS) {
        $leaseFile = '/var/db/dhcpd_leases'
        if (Test-Path $leaseFile) {
            try {
                $content = Get-Content $leaseFile -Raw -ErrorAction Stop
                # Split into per-VM blocks delimited by { ... }
                $blocks = [regex]::Matches($content, '\{[^}]*\}')
                foreach ($b in $blocks) {
                    $text = $b.Value
                    if ($text -match "(?m)^\s*name=$([regex]::Escape($VMName))\s*$") {
                        if ($text -match "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") {
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
.PARAMETER GuestKey
The guest identifier used throughout the harness (e.g. guest.ubuntu.desktop).
.OUTPUTS
System.String. Username to log in as over SSH.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$GuestKey)
    switch ($GuestKey) {
        "guest.ubuntu.desktop" { return "ubuntu" }
        "guest.amazon.linux"   { return "ec2-user" }
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Command',
        Justification = 'Consumed via $using:Command inside Start-Job scriptblock.')]
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

    # Run ssh in a background job so TimeoutSeconds bounds total runtime, not
    # just TCP setup. ConnectTimeout still guards the handshake phase.
    $job = Start-Job -ScriptBlock {
        $out = & ssh -i $using:keyPath `
            -o BatchMode=yes `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
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

Export-ModuleMember -Function Initialize-YurunaSshKey, Get-YurunaSshPublicKey, Get-YurunaSshPrivateKeyPath, Wait-SshReady, Invoke-GuestSsh, Get-GuestSshUser, Get-GuestAddress
