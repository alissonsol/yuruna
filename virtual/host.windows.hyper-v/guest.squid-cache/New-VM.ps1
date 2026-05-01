<#PSScriptInfo
.VERSION 0.1
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e6f8
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
    Creates (or recreates) the squid HTTP-caching proxy VM on Hyper-V.

.DESCRIPTION
    Builds a lightweight Ubuntu Server cloud-image VM that runs Squid on
    port 3128. Guest VMs that set their HTTP proxy to this VM's IP will
    transparently cache every cacheable HTTP response — including the
    .deb packages the Ubuntu installer fetches during its kernel install
    step, which was previously uncached and caused intermittent 429
    failures from security.ubuntu.com.

    The VM is named "squid-cache" by default. Run Get-Image.ps1 first to
    download the base cloud image.

    After creation the script starts the VM, waits for cloud-init to finish
    and squid to listen on port 3128, then prints the proxy URL that guest
    VMs should use.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: squid-cache

.EXAMPLE
    .\Get-Image.ps1
    .\New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "squid-cache"
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$global:InformationPreference = "Continue"
$global:ProgressPreference    = "SilentlyContinue"

$commonModulePath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "VM.common.psm1"
Import-Module -Name $commonModulePath -Force

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# Assert-HyperVEnabled (VM.common.psm1) calls dism.exe directly instead
# of Get-WindowsOptionalFeature — avoids the "Class not registered" COM
# failure that breaks first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# Remove existing VM
$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    Remove-VM -Name $VMName -Force
    Write-Output "VM '$VMName' deleted."
}

# === Locate base image ===
$downloadDir = (Get-VMHost).VirtualHardDiskPath
$baseImageName = "host.windows.hyper-v.guest.squid-cache"
$baseImageFile = Join-Path $downloadDir "$baseImageName.vhdx"

if (!(Test-Path -Path $baseImageFile)) {
    Write-Output "Base image not found at '$baseImageFile'. Run Get-Image.ps1 first."
    exit 1
}

# === Create VM disk (copy of base image) ===
$vmDir = Join-Path $downloadDir $VMName
if (-not (Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
Write-Output "Creating VHDX for '$VMName' by copying base image..."
Copy-Item -Path $baseImageFile -Destination $vhdxFile -Force

# === Generate cloud-init seed ISO ===
$vmConfigDir = Join-Path $PSScriptRoot "vmconfig"
$SeedDir = Join-Path $env:TEMP "seed_$VMName"
if (Test-Path $SeedDir) { Remove-Item -Recurse -Force $SeedDir }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

Copy-Item -Path (Join-Path $vmConfigDir "meta-data") -Destination "$SeedDir/meta-data"

# Load the yuruna test-harness SSH public key — same module the Ubuntu
# Desktop guest uses; one keypair grants passwordless access to every VM
# (including this cache VM, for debugging squid/cloud-init).
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Random 10-char alphanumeric password for the 'yuruna' user. Fresh per
# rebuild (not a constant 'password') stops browsers caching / auto-
# suggesting it when opening cachemgr.cgi, which was triggering password-
# manager popups. ASCII alphanumerics only: no YAML-escape surprises, no
# shell-special chars during ssh.
$pwChars = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
$YurunaPassword = -join (1..10 | ForEach-Object {
    $pwChars[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $pwChars.Length)]
})

# Stash the password next to the VHDX so users can retrieve it after
# console output has scrolled away. Plaintext — VirtualHardDiskPath is
# not multi-user readable by default, and this is a dev-only credential
# with RFC1918-only reachability.
$PasswordFile = Join-Path $vmDir "squid-cache-password.txt"
Set-Content -Path $PasswordFile -Value $YurunaPassword -NoNewline

# Substitute SSH key and password placeholders. .Replace() (literal)
# rather than -replace (regex) because keys can contain regex-special
# chars (ssh-rsa base64 usually doesn't — cheap insurance).
$UserData = (Get-Content -Raw (Join-Path $vmConfigDir "user-data")).
    Replace('SSH_AUTHORIZED_KEY_PLACEHOLDER', $SshAuthorizedKey).
    Replace('PASSWORD_PLACEHOLDER', $YurunaPassword)
Set-Content -Path "$SeedDir/user-data" -Value $UserData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# Surface credentials BEFORE the long VM-create/boot/cloud-init wait.
# If anything in those 20-35 minutes fails (cloud-init stall, apt rate-
# limit, yuruna.conf parse error), the operator needs to console-login
# via vmconnect — without the password they'd have to dig seed.iso off
# disk. The final "ready" banner reprints the same credentials.
Write-Output ""
Write-Output "=== squid-cache console/SSH login (available NOW) ==="
Write-Output "  user:     yuruna"
Write-Output "  password: $YurunaPassword"
Write-Output "  saved at: $PasswordFile"
Write-Output "  If the wait below stalls or fails, open 'vmconnect localhost $VMName'"
Write-Output "  and log in with the credentials above to inspect cloud-init state."
Write-Output ""

# === Pick a vSwitch ===
# Prefer the Yuruna External vSwitch (bridged to the host's primary
# physical NIC) so the cache VM gets a real LAN IP via DHCP and remote
# LAN clients reach it directly — squid sees the actual client IP at
# TCP level with no host-side forwarder in the path. Fall back to the
# built-in Default Switch when no External vSwitch can be created
# (no LAN, Wi-Fi-only host, etc.); cache still works for local
# Default-Switch guests, but LAN clients will see the host's vEthernet
# IP for every request (the documented netsh-portproxy gap).
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Output "WARNING: External vSwitch unavailable — falling back to 'Default Switch'."
    Write-Output "  Cache VM will not be reachable from LAN by its own IP, and remote"
    Write-Output "  clients routed via netsh portproxy will appear as the host's"
    Write-Output "  vEthernet IP in squid's access.log (see docs/caching.md)."
    $switchName = 'Default Switch'
}

# === Create and configure Hyper-V VM ===
# 4 GB RAM, 4 vCPU — sized for parallel squid streams. subiquity opens
# 4-8 concurrent .deb downloads per guest install; with 1 vCPU + 512 MB
# the old apt-cacher-ng cache bottlenecked on a single core (receive +
# disk-write + forward). 4 GB (up from 2 GB) covers squid's in-memory
# index as the on-disk cache grows to 128 GB (~400 bytes per object).
Write-Output "Creating new VM '$VMName' on switch '$switchName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 4GB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 4GB -MemoryMinimumBytes 4GB -MemoryMaximumBytes 4GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
Set-VMProcessor -VMName $VMName -Count 4 | Out-Null

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Start VM and wait for squid ===
Write-Output "Starting VM '$VMName'..."
Start-VM -Name $VMName

Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (first boot runs cloud-init: apt update + install squid + hyperv-daemons;"
Write-Output "   this can take 5-15 minutes on a slow connection — be patient)"

# Discover the cache VM's IP via Get-CacheVmCandidateIp (VM.common.psm1,
# KVP+ARP). Same primitive called by consumers (ubuntu guests) and
# Start-CachingProxy.ps1's summary, so producer and consumers never see
# different answers about which IPs belong to this VM.
#
# No :3128 probe in this loop — squid isn't listening yet (cloud-init is
# what we're waiting for). A later loop ("Waiting for squid to listen on
# port 3128") takes $cacheCandidateIps and tiebreaks stale vs live ARP
# entries by picking whichever answers squid.
$cacheIp = $null
$cacheCandidateIps = @()
$maxIterations = 240  # 240 * 5s = 20 minutes
$vmDiscoveryLogged = $false

# Re-enable Write-Progress for the wait loop (script default is
# SilentlyContinue so web-download progress doesn't spam non-interactive shells).
$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' cloud-init (squid install)"
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)

for ($i = 0; $i -lt $maxIterations; $i++) {
    Start-Sleep -Seconds 5

    # Hyper-V assigns MAC + leases an IP asynchronously after Start-VM;
    # first few iterations normally return an empty candidate list.
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        $cacheCandidateIps = @(Get-CacheVmCandidateIp -VM $vm)
        if ($cacheCandidateIps) {
            if (-not $vmDiscoveryLogged) {
                $vmMac = ($vm | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
                $vmMacDashed = if ($vmMac -match '^[0-9A-Fa-f]{12}$') {
                    (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
                } else { '(unknown)' }
                Write-Output "  VM MAC: $vmMacDashed"
                Write-Output "  Discovered IP(s) for ${VMName}: $($cacheCandidateIps -join ', ')"
                $vmDiscoveryLogged = $true
            }
            break
        }
    }

    # Single-line progress: elapsed, CPU%, VHDX size. VHDX is dynamic
    # and grows as cloud-init apt-installs, so rising size means real
    # progress.
    $elapsed  = [int]((Get-Date) - $startTime).TotalSeconds
    $pct      = [math]::Min(100, [math]::Round(($elapsed / ($maxIterations * 5)) * 100))
    $cpu      = (Get-VM -Name $VMName -ErrorAction SilentlyContinue).CPUUsage
    if ($null -eq $cpu) { $cpu = 0 }
    $sizeMB   = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)
    $deltaMB  = $sizeMB - $baselineSizeMB
    $min      = [math]::Floor($elapsed / 60)
    $sec      = $elapsed % 60
    $status   = "elapsed ${min}m${sec}s | CPU ${cpu}% | VHDX ${sizeMB} MB (+${deltaMB} MB since boot)"
    Write-Progress -Activity $activity -Status $status -PercentComplete $pct -SecondsRemaining (($maxIterations * 5) - $elapsed)
}

Write-Progress -Activity $activity -Completed

if (-not $cacheCandidateIps) {
    $detail = @"

=========================================================================
ERROR: squid-cache VM '$VMName' did not obtain an IP address within 20 minutes.
=========================================================================

The VM is running but never showed up in the host's ARP cache and
never reported an IP via Hyper-V KVP. Exiting with failure so guest
installs won't silently fall back to direct CDN access and 429.

If the VM is on the Yuruna-External vSwitch and the host is on Wi-Fi:
the AP probably refused to forward the cache VM's DHCP request — this
is a known Hyper-V-on-Wi-Fi limitation. Use a wired connection, or
remove the Yuruna-External vSwitch (Remove-VMSwitch -Name 'Yuruna-External')
to fall back to Default Switch on the next New-VM.ps1 run.

Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              login:    yuruna
              password: $YurunaPassword
              (also saved at $PasswordFile;
               cloud-init sets it from user-data; does NOT expire.)
  * SSH:      not available until the VM has a reachable IP -- that's
              what failed here, so console is the only path.

Diagnostic steps inside the VM:
  1. Check network:          ip -br a   # should show eth0 with an IPv4
  2. Check cloud-init:       cloud-init status --long
  3. Check squid:            systemctl status squid
  4. Check KVP daemon:       systemctl status hv-kvp-daemon
  5. View cloud-init logs:   sudo journalctl -u cloud-init -n 200

If cloud-init is still running (package install is slow or the mirror
is throttled), re-run .\New-VM.ps1 after it finishes -- the script is
idempotent and will rebuild the VM cleanly.
=========================================================================
"@
    $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
    exit 1
}

Write-Output "Cache VM candidate IP(s): $($cacheCandidateIps -join ', ')"
Write-Output "Waiting for squid to listen on port 3128 (up to 15 minutes)..."
Write-Output "  (cloud-init installs squid + apache2 + squid-cgi, then pre-warms"
Write-Output "   the cache by pulling linux-firmware through the local proxy —"
Write-Output "   squid binds :3128 before pre-warm starts, so port response"
Write-Output "   usually happens 3-5 minutes in on a responsive mirror.)"

$portActivity = "Waiting for squid on :3128 (candidates: $($cacheCandidateIps -join ', '))"
$portMaxIterations = 180  # 180 * 5s = 15 minutes — matches the cloud-init budget we advertise
$portStartTime = Get-Date

for ($i = 0; $i -lt $portMaxIterations; $i++) {
    # Probe each candidate on :3128. When ARP returned stale + live IPs
    # for one MAC, only the live one answers; whichever responds first
    # becomes the authoritative $cacheIp. Test-CachingProxyPort
    # (VM.common.psm1) is the shared non-blocking probe; 1000 ms rides
    # over momentary scheduler stalls during heavy apt-install.
    $connected = $false
    foreach ($ip in $cacheCandidateIps) {
        if (Test-CachingProxyPort -IpAddress $ip -TimeoutMs 1000) {
            $cacheIp = $ip
            $connected = $true
            break
        }
    }

    if ($connected) {
        Write-Progress -Activity $portActivity -Completed
        Write-Output ""
        Write-Output "=== squid-cache is READY ==="
        Write-Output "  VM:        $VMName"
        Write-Output "  IP:        $cacheIp"
        Write-Output "  Proxy:     http://${cacheIp}:3128"
        Write-Output "  Monitor:   http://${cacheIp}/cgi-bin/cachemgr.cgi"
        Write-Output ""
        Write-Output "  Console/SSH login:"
        Write-Output "    user:     yuruna"
        Write-Output "    password: $YurunaPassword"
        Write-Output "    (saved also at: $PasswordFile,"
        Write-Output "     and embedded in the seed.iso's user-data — chpasswd)"
        Write-Output ""
        Write-Output "Pre-warm may still be running in the background (pulling"
        Write-Output "linux-firmware and the HWE kernel meta through the local"
        Write-Output "proxy). Confirm completion by opening the Monitor URL"
        Write-Output "above -> 'storedir' and checking cache occupancy > 0."
        Write-Output ""
        Write-Output "Guest VMs will auto-detect squid at port 3128 when their"
        Write-Output "New-VM.ps1 runs. Keep the VM running across cycles."
        exit 0
    }

    # Progress: elapsed, CPU%, VHDX growth since script start.
    # Rising VHDX / non-zero CPU = cloud-init still apt-installing.
    $elapsed = [int]((Get-Date) - $portStartTime).TotalSeconds
    $pct     = [math]::Min(100, [math]::Round(($elapsed / ($portMaxIterations * 5)) * 100))
    $cpu     = (Get-VM -Name $VMName -ErrorAction SilentlyContinue).CPUUsage
    if ($null -eq $cpu) { $cpu = 0 }
    $sizeMB  = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)
    $deltaMB = $sizeMB - $baselineSizeMB
    $min     = [math]::Floor($elapsed / 60)
    $sec     = $elapsed % 60
    $status  = "elapsed ${min}m${sec}s | CPU ${cpu}% | VHDX ${sizeMB} MB (+${deltaMB} MB since boot)"
    Write-Progress -Activity $portActivity -Status $status -PercentComplete $pct -SecondsRemaining (($portMaxIterations * 5) - $elapsed)

    Start-Sleep -Seconds 4  # 1s WaitOne + 4s sleep = 5s per iteration
}

Write-Progress -Activity $portActivity -Completed
$candidateList = $cacheCandidateIps -join ', '
$detail = @"

=========================================================================
ERROR: squid did not start listening on :3128 within 15 minutes.
  Candidate IPs probed: $candidateList
=========================================================================

The VM is running and has an IP, but port 3128 never accepted a TCP
connection. Exiting with failure so subsequent guest installs can't
silently fall back to direct CDN access and hit 429 rate limits.

Accessing the VM for debugging:
  * Console:  vmconnect localhost $VMName
              login:    yuruna
              password: $YurunaPassword
              (also saved at $PasswordFile;
               cloud-init sets it from user-data; does NOT expire.)
  * SSH:      ssh yuruna@<candidate>    (try each of: $candidateList)
              (uses the yuruna harness key at test\.ssh\yuruna_ed25519 --
               same key the Ubuntu Desktop guests use; passwordless)

=== Step 1: find the actual apt / cloud-init error ===
'cloud-init status --long' only SHOWS the fact that something failed;
the REAL error is in the output log. Run this first -- it's the single
most useful diagnostic:

  sudo grep -E 'E:|429 |Hash Sum|Failed to fetch|Unable to locate|Exit code' /var/log/cloud-init-output.log | head -40

Or dump the whole tail:

  sudo tail -n 300 /var/log/cloud-init-output.log

Common patterns you'll see there:
  * '429 Too Many Requests'    -> Ubuntu's CDN is rate-limiting this
                                  host's public IP. Wait 15-30 min and
                                  re-run .\New-VM.ps1 (idempotent -- it
                                  rebuilds the VM cleanly).
  * 'Unable to locate package' -> a package name changed on the mirror;
                                  report the specific name so it can be
                                  fixed in vmconfig/user-data.
  * 'Could not resolve'        -> DNS broken inside the VM. Check
                                  'resolvectl status' and netplan config.
  * Nothing obvious            -> run the fuller diagnostic block below.

=== Step 2: deeper diagnostics (only if step 1 is inconclusive) ===
  systemctl status squid                # 'could not be found' = install failed
  ss -ltn 'sport = :3128'               # port bound? who's listening?
  sudo ufw status ; sudo iptables -L -n # guest-side firewall
  ip -br a                              # IP matches one of: $candidateList ?

Recovery options:
  * Retry:   re-run .\New-VM.ps1 (idempotent rebuild).
  * Manual:  ssh in, fix (e.g. wait for rate-limit, then
             'sudo cloud-init clean --logs && sudo cloud-init init').
  * Probe:   Test-NetConnection -Port 3128 -ComputerName <candidate>   # each of: $candidateList
=========================================================================
"@
$Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
exit 1
