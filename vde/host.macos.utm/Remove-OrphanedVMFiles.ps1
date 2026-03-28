<#PSScriptInfo
.VERSION 0.1
.GUID 42a8d3f2-e5b6-4c71-9a04-2f3d4e5a6b7c
.AUTHOR Alisson Sol
.COMPANYNAME None
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
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostFolder = Split-Path -Leaf $ScriptDir
$guestFolders = Get-ChildItem -Path $ScriptDir -Directory -Filter "guest.*"
$baseImageNames = @()
foreach ($guest in $guestFolders) {
    $baseImageNames += "$hostFolder.$($guest.Name)"
}

# === Check prerequisites ===
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

# Get all UTM-registered VMs via utmctl
$utmOutput = & utmctl list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
    exit 1
}

# Parse utmctl list output (format: "UUID  Name  Status")
$registeredVMs = @{}
$registeredUUIDs = @{}
foreach ($line in $utmOutput) {
    $line = "$line".Trim()
    if (-not $line -or $line -match '^-+$') { continue }
    $parts = $line -split '\s{2,}'
    if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$') {
        $vmUuid = $parts[0].Trim()
        $vmName = $parts[1].Trim()
        $vmStatus = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "unknown" }
        $registeredVMs[$vmName] = $vmStatus
        $registeredUUIDs[$vmUuid] = $vmName
    }
}

# Helper: read the VM UUID from a .utm bundle's config.plist.
# utmctl list may only return running VMs; UUID-based checks via utmctl status
# work for stopped VMs as well.
function Get-UTMBundleUUID {
    param([string]$BundlePath)
    $configPlist = Join-Path $BundlePath "config.plist"
    if (-not (Test-Path $configPlist)) { return $null }
    try {
        $json = & plutil -convert json -o - $configPlist 2>&1
        $config = $json | ConvertFrom-Json -ErrorAction Stop
        foreach ($key in @('_id', 'uuid', 'UUID', 'id')) {
            if ($config.PSObject.Properties[$key]) {
                $val = "$($config.$key)".Trim()
                if ($val -match '^[0-9A-Fa-f-]{36}$') { return $val }
            }
        }
    } catch {}
    return $null
}

Write-Output "UTM registered VMs: $($registeredVMs.Count)"
Write-Output ""

# Find all .utm bundles in the scan path
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

    # Check by UUID to catch stopped VMs that utmctl list may not return by name.
    # utmctl status <uuid> succeeds (exit 0) for any registered VM regardless of state.
    $bundleUUID = Get-UTMBundleUUID -BundlePath $bundlePath
    if ($bundleUUID) {
        if ($registeredUUIDs.ContainsKey($bundleUUID)) { continue }
        $null = & utmctl status $bundleUUID 2>&1
        if ($LASTEXITCODE -eq 0) { continue }
    }

    $bundleSize = (Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $itemSize = if ($bundleSize) { $bundleSize } else { 0 }

    # Check if this bundle name matches a base image name
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

# Ask for confirmation (skip if -Force)
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
