<#PSScriptInfo
.VERSION 0.1
.GUID 42f1b2c3-d4e5-4f67-8901-a2b3c4d5e6f7
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
    Creates (or recreates) the apt-cacher-ng cache VM on Hyper-V.

.DESCRIPTION
    Builds a lightweight Ubuntu Server cloud-image VM that runs apt-cacher-ng
    on port 3142. Guest VMs that set their apt proxy to this VM's IP will
    download each .deb only once; subsequent installs are served from the
    local cache.

    The VM is named "apt-cache" by default. Run Get-Image.ps1 first to
    download the base cloud image.

    After creation the script starts the VM, waits for cloud-init to finish
    and apt-cacher-ng to listen on port 3142, then prints the IP address
    that guest VMs should use as their apt proxy.

.PARAMETER VMName
    Name of the Hyper-V VM. Default: apt-cache

.EXAMPLE
    .\Get-Image.ps1
    .\New-VM.ps1
#>

param(
    [Parameter(Position = 0)]
    [string]$VMName = "apt-cache"
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

# Check Hyper-V
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hypervFeature.State -ne 'Enabled') {
    Write-Output "Hyper-V is not enabled."
    exit 1
}
$service = Get-Service -Name vmms -ErrorAction SilentlyContinue
if (!$service -or $service.Status -ne 'Running') {
    Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running."
    exit 1
}

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
$baseImageName = "host.windows.hyper-v.guest.apt-cache"
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
Copy-Item -Path (Join-Path $vmConfigDir "user-data") -Destination "$SeedDir/user-data"

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Output "Generating seed.iso with cloud-init configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

# === Create and configure Hyper-V VM ===
# 2 GB RAM, 4 vCPU — sized for parallel apt-cacher-ng streams.
# subiquity opens 4-8 concurrent .deb downloads per guest install; with
# 1 vCPU + 512 MB the cache became a bottleneck (it had to receive,
# disk-write, and forward simultaneously on a single core), making
# proxied installs slower than direct downloads. 4 cores cover the
# parallel streams; 2 GB gives apt-cacher-ng enough page cache to keep
# hot .deb files in memory between back-to-back guest installs.
Write-Output "Creating new VM '$VMName'..."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 2GB -SwitchName "Default Switch" -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 2GB -MemoryMinimumBytes 2GB -MemoryMaximumBytes 2GB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null
Set-VMProcessor -VMName $VMName -Count 4 | Out-Null

# === Cleanup temporary folders ===
Remove-Item -Recurse -Force $SeedDir -ErrorAction SilentlyContinue

# === Start VM and wait for apt-cacher-ng ===
Write-Output "Starting VM '$VMName'..."
Start-VM -Name $VMName

Write-Output "Waiting for VM to obtain an IP address..."
Write-Output "  (first boot runs cloud-init: apt update + install apt-cacher-ng + hyperv-daemons;"
Write-Output "   this can take 5-15 minutes on a slow connection — be patient)"

# Discover the cache VM's IP. Two strategies, checked each iteration:
#   1. ARP lookup by VM MAC (Get-NetNeighbor) — works as soon as the guest
#      sends any packet (DHCP request is enough), independent of guest agents.
#   2. Hyper-V KVP via Get-VMNetworkAdapter — requires hv_kvp_daemon inside
#      the guest, which only runs after cloud-init finishes installing
#      hyperv-daemons. Kept as a confirmation path.
#
# The previous subnet-scan strategy assumed a hardcoded /28 (host.2–.14)
# but the Default Switch is actually a /20 (~4094 hosts) on Windows 11, so
# any DHCP lease outside the first 14 addresses was never found.
$cacheIp = $null
$maxIterations = 240  # 240 * 5s = 20 minutes

# Find the Default Switch interface — we scope ARP lookups to this interface
# to avoid false matches from other virtual adapters (VMware, VirtualBox, WSL,
# etc.) that may have stale neighbor entries on unrelated subnets.
$hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
$defaultSwitchIfIndex = $null
if ($hostAdapter) {
    $defaultSwitchIfIndex = $hostAdapter.InterfaceIndex
    Write-Output "  Default Switch host: $($hostAdapter.IPAddress)/$($hostAdapter.PrefixLength) (ifIndex $defaultSwitchIfIndex)"
} else {
    Write-Warning "  Could not locate 'Default Switch' adapter — ARP discovery will fall back to KVP only"
}

# VM MAC is read inside the loop: Hyper-V assigns it asynchronously after
# Start-VM (initial value is 000000000000 for the first few seconds).
$vmMacLogged = $false

# Re-enable Write-Progress for the wait loop (the script-level default is
# SilentlyContinue so web-download progress doesn't spam non-interactive shells).
$ProgressPreference = 'Continue'
$activity  = "Waiting for '$VMName' cloud-init (apt-cacher-ng install)"
$startTime = Get-Date
$baselineSizeMB = [math]::Round((Get-Item $vhdxFile).Length / 1MB, 0)

for ($i = 0; $i -lt $maxIterations; $i++) {
    Start-Sleep -Seconds 5

    # Strategy 1: ARP cache lookup by VM MAC (fast, guest-agent-independent).
    # Re-read the MAC each iteration — Hyper-V assigns a dynamic MAC a few
    # seconds after Start-VM, so the first few reads return "000000000000".
    $vmMac = (Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1).MacAddress
    if ($defaultSwitchIfIndex -and $vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
        $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
        if (-not $vmMacLogged) {
            Write-Output "  VM MAC: $vmMacDashed (matching against Default Switch ARP cache)"
            $vmMacLogged = $true
        }
        $neighbor = Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $defaultSwitchIfIndex -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -eq $vmMacDashed -and
                $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and
                $_.State -ne 'Unreachable'
            } |
            Select-Object -First 1
        if ($neighbor) {
            $cacheIp = $neighbor.IPAddress
            Write-Output "  Discovered IP via ARP (MAC $vmMacDashed): $cacheIp"
            break
        }
    }

    # Strategy 2: Hyper-V KVP (only works after hyperv-daemons is installed)
    $adapters = Get-VMNetworkAdapter -VMName $VMName
    $ips = $adapters | ForEach-Object { $_.IPAddresses } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    if ($ips) {
        $cacheIp = $ips[0]
        Write-Output "  Discovered IP via Hyper-V KVP: $cacheIp"
        break
    }

    # Single-line progress: elapsed, VM CPU%, and VHDX size growth
    # (VHDX is dynamic — it grows as cloud-init apt-installs packages,
    # so a rising size means the install is actually making progress).
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

if (-not $cacheIp) {
    Write-Warning "Could not determine IP for '$VMName' after 20 minutes."
    Write-Warning "The VM is running — connect a console via Hyper-V Manager and check:"
    Write-Warning "  - 'ip a' inside the guest shows a DHCP address"
    Write-Warning "  - 'systemctl status apt-cacher-ng' reports active"
    Write-Warning "  - 'systemctl status hv-kvp-daemon' reports active"
    Write-Warning "If cloud-init is still running (check 'cloud-init status'), wait longer."
    Write-Output "VM '$VMName' created."
    exit 0
}

Write-Output "Cache VM IP: $cacheIp"
Write-Output "Waiting for apt-cacher-ng to listen on port 3142..."

$portActivity = "Waiting for apt-cacher-ng on ${cacheIp}:3142"
$portMaxIterations = 60  # 60 * 5s = 5 minutes
$portStartTime = Get-Date

for ($i = 0; $i -lt $portMaxIterations; $i++) {
    # Non-blocking TCP probe with 1s timeout (synchronous Connect() can block
    # ~20s on filtered/unreachable ports and starves our progress updates).
    $tcp = New-Object System.Net.Sockets.TcpClient
    $connected = $false
    try {
        $async = $tcp.BeginConnect($cacheIp, 3142, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1000) -and $tcp.Connected) {
            $connected = $true
        }
    } catch {
        Write-Verbose "TCP probe to ${cacheIp}:3142 failed: $($_.Exception.Message)"
    }
    finally { $tcp.Close() }

    if ($connected) {
        Write-Progress -Activity $portActivity -Completed
        Write-Output ""
        Write-Output "=== apt-cacher-ng is ready ==="
        Write-Output "  VM:    $VMName"
        Write-Output "  IP:    $cacheIp"
        Write-Output "  Proxy: http://${cacheIp}:3142"
        Write-Output ""
        Write-Output "Guest VMs will use this proxy automatically when"
        Write-Output "the cache VM is running at New-VM time."
        exit 0
    }

    # Progress: elapsed, VM CPU%, and total VHDX growth since script start.
    # Rising VHDX / non-zero CPU means cloud-init is still apt-installing.
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
Write-Warning "apt-cacher-ng not responding on ${cacheIp}:3142 after 5 minutes."
Write-Warning "Cloud-init may still be running. Check the VM console (vmconnect localhost $VMName)."
Write-Warning "Inside the guest, run: cloud-init status --long ; systemctl status apt-cacher-ng"
Write-Output "VM '$VMName' created and running at $cacheIp."
