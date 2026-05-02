<#PSScriptInfo
.VERSION 0.1
.GUID 42a8d3f2-e5b6-4c71-9a04-2f3d4e5a6b7c
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

param(
    [switch]$Force
)

# === Warning ===
Write-Output ""
Write-Output "================================================================"
Write-Output "  WARNING: DESTRUCTIVE OPERATION"
Write-Output "================================================================"
Write-Output ""
Write-Output "  This script deletes UTM VM bundles (.utm) from ~/Desktop"
Write-Output "  that are NOT registered in UTM."
Write-Output ""
Write-Output "  THIS CANNOT BE UNDONE."
Write-Output ""
Write-Output "================================================================"
Write-Output ""

# === Discover base image names from guest.* subfolders ===
# Base image filenames follow the legacy convention "host.<short>.guest.<name>"
# (e.g. host.macos.utm.guest.amazon.linux.qcow2). The script now lives at
# host/<short>/, so Split-Path -Leaf returns just <short>; prepend "host." to
# reconstruct the prefix that every guest's Get-Image.ps1 / New-VM.ps1 writes.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostFolder = "host.$(Split-Path -Leaf $ScriptDir)"
$guestFolders = Get-ChildItem -Path $ScriptDir -Directory -Filter "guest.*"
$baseImageNames = @()
foreach ($guest in $guestFolders) {
    $baseImageNames += "$hostFolder.$($guest.Name)"
}

if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
    Write-Error "utmctl not found. Ensure UTM is installed and utmctl is in your PATH."
    Write-Error "UTM.app ships utmctl at: /Applications/UTM.app/Contents/MacOS/utmctl"
    exit 1
}

# === Scan for VM bundles ===
$machineName = $(hostname -s)
$scanPath = "$HOME/Desktop/Yuruna.VDE/$machineName.nosync"
if (-not (Test-Path $scanPath)) {
    Write-Output "No Yuruna.VDE folder found at '$scanPath'. Nothing to scan."
    exit 0
}

$utmOutput = & utmctl list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
    exit 1
}

# Parse utmctl list (format: "UUID  Name  Status")
$registeredVMs = @{}
$registeredUUIDs = @{}
foreach ($line in $utmOutput) {
    $line = "$line".Trim()
    if (-not $line -or $line -match '^-+$') { continue }
    $parts = $line -split '\s{2,}'
    if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$') {
        $vmUuid = $parts[0].Trim()
        $vmName = $parts[1].Trim()
        $vmStatus = $parts.Count -ge 3 ? $parts[2].Trim() : "unknown"
        $registeredVMs[$vmName] = $vmStatus
        $registeredUUIDs[$vmUuid] = $vmName
    }
}

# Read VM UUID from a bundle's config.plist. utmctl list may only return
# running VMs; UUID-based `utmctl status` works for stopped VMs too —
# without this, a stopped service VM (e.g. squid-cache) is misclassified
# as orphaned and deleted by the -Force cleanup path.
#
# `plutil -extract Information.UUID raw` (not `-convert json`):
#   * UTM stores the UUID at Information.UUID, not a top-level key.
#   * `-convert json` fails outright on these bundles because config.plist
#     contains a <data> blob (MachineIdentifier) that JSON can't represent
#     — plutil exits 1 and ConvertFrom-Json throws, so the whole function
#     used to silently return $null and the orphan check fell through.
function Get-UTMBundleUUID {
    param([string]$BundlePath)
    $configPlist = Join-Path $BundlePath "config.plist"
    if (-not (Test-Path $configPlist)) { return $null }
    $val = & plutil -extract "Information.UUID" raw -o - $configPlist 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $val = "$val".Trim()
    if ($val -match '^[0-9A-Fa-f-]{36}$') { return $val }
    return $null
}

Write-Output "UTM registered VMs: $($registeredVMs.Count)"
Write-Output ""

$utmBundles = Get-ChildItem -Path $scanPath -Directory -Filter "*.utm" -ErrorAction SilentlyContinue
$bundleMap = @{}
foreach ($bundle in $utmBundles) {
    $vmName = $bundle.Name -replace '\.utm$', ''
    $bundleMap[$vmName] = $bundle.FullName
}

# === List registered VMs and their associated files ===
if ($registeredVMs.Count -gt 0) {
    Write-Output "Currently registered VMs and their associated Desktop files:"
    Write-Output ""
}

foreach ($vmName in ($registeredVMs.Keys | Sort-Object)) {
    $vmStatus = $registeredVMs[$vmName]
    Write-Output "  $vmName [$vmStatus]"

    if ($bundleMap.ContainsKey($vmName)) {
        $bundlePath = $bundleMap[$vmName]
        $bundleFiles = Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in ($bundleFiles | Sort-Object FullName)) {
            $sizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
            Write-Output "    $($f.FullName)  ($sizeStr)"
        }
    } else {
        Write-Output "    (no bundle found on Desktop)"
    }
    Write-Output ""
}

# === Identify orphaned bundles (excluding base images) ===
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()
$protectedItems = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vmName in $bundleMap.Keys) {
    if ($registeredVMs.ContainsKey($vmName)) { continue }

    $bundlePath = $bundleMap[$vmName]

    # UUID check catches stopped VMs utmctl list may omit by name;
    # `utmctl status <uuid>` exits 0 for any registered VM.
    $bundleUUID = Get-UTMBundleUUID -BundlePath $bundlePath
    if ($bundleUUID) {
        if ($registeredUUIDs.ContainsKey($bundleUUID)) { continue }
        $null = & utmctl status $bundleUUID 2>&1
        if ($LASTEXITCODE -eq 0) { continue }
    }

    $bundleSize = (Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $itemSize = $bundleSize ?? 0

    $isBaseImage = $false
    foreach ($baseImageName in $baseImageNames) {
        if ($vmName -eq $baseImageName) {
            $isBaseImage = $true
            break
        }
    }

    if ($isBaseImage) {
        $protectedItems.Add(@{ Name = $vmName; Path = $bundlePath; Size = $itemSize })
    } else {
        $orphanedItems.Add(@{ Name = $vmName; Path = $bundlePath; Size = $itemSize })
    }
}

# === List protected base images ===
if ($protectedItems.Count -gt 0) {
    Write-Output "The following base images are KEPT (not associated with a registered VM, but needed as base images):"
    Write-Output ""
    foreach ($item in $protectedItems) {
        $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
        Write-Output "  $($item.Path)  ($sizeStr)"
        $guestName = ($item.Name -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-Output "    Reason: base image for $($guestName). Update by rerunning Get-Image.ps1 in $($guestName)/"
    }
    Write-Output ""
}

# === Delete orphaned bundles ===
if ($orphanedItems.Count -eq 0) {
    Write-Output "No orphaned VM bundles found. Nothing to clean up."
    exit 0
}

Write-Output "The following .utm bundles are NOT associated with any registered UTM VM:"
Write-Output ""
$totalSize = 0
foreach ($item in $orphanedItems) {
    $totalSize += $item.Size
    $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
    Write-Output "  $($item.Path)  ($sizeStr)"
    $bundleFiles = Get-ChildItem -Path $item.Path -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in ($bundleFiles | Sort-Object FullName)) {
        $fSizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
        Write-Output "    $($f.FullName)  ($fSizeStr)"
    }
}
Write-Output ""
Write-Output ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-Output ""

if ($Force) {
    Write-Output "Force mode enabled — skipping confirmation."
} else {
    $confirmation = Read-Host "Type YES to delete all listed items, or anything else to cancel"
    if ($confirmation -ne "YES") {
        Write-Output "Operation cancelled. No files were deleted."
        exit 0
    }
}

$errors = 0
foreach ($item in $orphanedItems) {
    try {
        # Deregister from UTM first (by UUID if available, else by name).
        $bundleUUID = Get-UTMBundleUUID -BundlePath $item.Path
        $deregistered = $false
        if ($bundleUUID) {
            & utmctl delete $bundleUUID 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $deregistered = $true }
        }
        if (-not $deregistered) {
            & utmctl delete $item.Name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $deregistered = $true }
        }
        # Verify no longer registered before removing files.
        $stillRegistered = $false
        if ($bundleUUID) {
            $null = & utmctl status $bundleUUID 2>&1
            if ($LASTEXITCODE -eq 0) { $stillRegistered = $true }
        }
        if ($stillRegistered) {
            Write-Warning "  Skipped: $($item.Path) — VM still registered in UTM. Remove it from UTM first."
            $errors++
            continue
        }
        Remove-Item -Path $item.Path -Recurse -Force
        Write-Output "  Deleted: $($item.Path)"
    } catch {
        Write-Warning "  Failed to delete: $($item.Path) - $_"
        $errors++
    }
}

# === Cleanup result ===
Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned bundles deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
