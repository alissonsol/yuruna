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

# Inform about the destructive nature of this operation
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

# Check that utmctl is available
if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
    Write-Error "utmctl not found. Ensure UTM is installed and utmctl is in your PATH."
    Write-Error "UTM.app ships utmctl at: /Applications/UTM.app/Contents/MacOS/utmctl"
    exit 1
}

# The New-VM.ps1 scripts create VM bundles under ~/Desktop/Yuruna.VDE/<hostname>/
$MachineName = $(hostname -s)
$ScanPath = "$HOME/Desktop/Yuruna.VDE/$MachineName"
if (-not (Test-Path $ScanPath)) {
    Write-Output "No Yuruna.VDE folder found at '$ScanPath'. Nothing to scan."
    exit 0
}

# Get all UTM-registered VMs via utmctl
$utmOutput = & utmctl list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
    exit 1
}

# Parse utmctl list output (format: "UUID  Name  Status")
# Skip header line if present
$registeredVMs = @{}
foreach ($line in $utmOutput) {
    $line = "$line".Trim()
    if (-not $line -or $line -match '^-+$') { continue }
    # utmctl list output columns are separated by whitespace
    # Format: UUID    Name    Status
    $parts = $line -split '\s{2,}'
    if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$') {
        $vmName = $parts[1].Trim()
        $vmStatus = if ($parts.Count -ge 3) { $parts[2].Trim() } else { "unknown" }
        $registeredVMs[$vmName] = $vmStatus
    }
}

Write-Output "UTM registered VMs: $($registeredVMs.Count)"
Write-Output ""

# Find all .utm bundles on the Desktop
$utmBundles = Get-ChildItem -Path $ScanPath -Directory -Filter "*.utm" -ErrorAction SilentlyContinue

# Build a map of Desktop bundles: VMName -> bundle path
$desktopBundles = @{}
foreach ($bundle in $utmBundles) {
    $vmName = $bundle.Name -replace '\.utm$', ''
    $desktopBundles[$vmName] = $bundle.FullName
}

# ===== List registered VMs and their associated files =====
if ($registeredVMs.Count -gt 0) {
    Write-Output "Currently registered VMs and their associated Desktop files:"
    Write-Output ""
}

foreach ($vmName in ($registeredVMs.Keys | Sort-Object)) {
    $status = $registeredVMs[$vmName]
    Write-Output "  $vmName [$status]"

    if ($desktopBundles.ContainsKey($vmName)) {
        $bundlePath = $desktopBundles[$vmName]
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

# ===== Find orphaned bundles =====
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vmName in $desktopBundles.Keys) {
    if ($registeredVMs.ContainsKey($vmName)) { continue }

    $bundlePath = $desktopBundles[$vmName]
    $bundleSize = (Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $orphanedItems.Add(@{
        Name = $vmName
        Path = $bundlePath
        Size = if ($bundleSize) { $bundleSize } else { 0 }
    })
}

if ($orphanedItems.Count -eq 0) {
    Write-Output "No orphaned VM bundles found. Nothing to clean up."
    exit 0
}

# Present orphaned items
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

# Ask for confirmation
$confirmation = Read-Host "Type YES to delete all listed items, or anything else to cancel"
if ($confirmation -ne "YES") {
    Write-Output "Operation cancelled. No files were deleted."
    exit 0
}

# Delete orphaned bundles
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

Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned bundles deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
