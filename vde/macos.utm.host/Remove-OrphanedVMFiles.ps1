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
Write-Output "  This script deletes UTM VM bundles (.utm.nosync) and their"
Write-Output "  symlinks (.utm) from ~/Desktop that are NOT registered"
Write-Output "  in UTM."
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

# The New-VM.ps1 scripts create VM bundles under ~/Desktop
$ScanPath = "$HOME/Desktop"
if (-not (Test-Path $ScanPath)) {
    Write-Error "Desktop folder not found at '$ScanPath'."
    exit 1
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

# Find all .utm.nosync bundles on the Desktop
$utmBundles = Get-ChildItem -Path $ScanPath -Directory -Filter "*.utm.nosync" -ErrorAction SilentlyContinue
# Find all .utm symlinks on the Desktop
$utmSymlinks = Get-ChildItem -Path $ScanPath -Filter "*.utm" -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }

# Build a map of Desktop bundles: VMName -> bundle path
$desktopBundles = @{}
foreach ($bundle in $utmBundles) {
    # Extract VM name: remove .utm.nosync suffix
    $vmName = $bundle.Name -replace '\.utm\.nosync$', ''
    $desktopBundles[$vmName] = $bundle.FullName
}

# Build a map of Desktop symlinks: VMName -> symlink path
$desktopSymlinks = @{}
foreach ($symlink in $utmSymlinks) {
    $vmName = $symlink.Name -replace '\.utm$', ''
    $desktopSymlinks[$vmName] = $symlink.FullName
}

# All VM names found on Desktop (union of bundles and symlinks)
$allDesktopVMs = @($desktopBundles.Keys) + @($desktopSymlinks.Keys) | Sort-Object -Unique

# ===== List registered VMs and their associated files =====
if ($registeredVMs.Count -gt 0) {
    Write-Output "Currently registered VMs and their associated Desktop files:"
    Write-Output ""
}

foreach ($vmName in ($registeredVMs.Keys | Sort-Object)) {
    $status = $registeredVMs[$vmName]
    Write-Output "  $vmName [$status]"

    $hasFiles = $false

    # Check for .utm.nosync bundle
    if ($desktopBundles.ContainsKey($vmName)) {
        $bundlePath = $desktopBundles[$vmName]
        $bundleFiles = Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in ($bundleFiles | Sort-Object FullName)) {
            $sizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
            Write-Output "    $($f.FullName)  ($sizeStr)"
        }
        $hasFiles = $true
    }

    # Check for .utm symlink
    if ($desktopSymlinks.ContainsKey($vmName)) {
        $symlinkPath = $desktopSymlinks[$vmName]
        $target = (Get-Item $symlinkPath).Target
        Write-Output "    $symlinkPath  (symlink -> $target)"
        $hasFiles = $true
    }

    if (-not $hasFiles) {
        Write-Output "    (no files found on Desktop)"
    }
    Write-Output ""
}

# ===== Find orphaned bundles and symlinks =====
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vmName in $allDesktopVMs) {
    if ($registeredVMs.ContainsKey($vmName)) { continue }

    # This VM has files on Desktop but is not registered in UTM
    if ($desktopBundles.ContainsKey($vmName)) {
        $bundlePath = $desktopBundles[$vmName]
        $bundleSize = (Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $orphanedItems.Add(@{
            Type = "bundle"
            Name = $vmName
            Path = $bundlePath
            Size = if ($bundleSize) { $bundleSize } else { 0 }
        })
    }
    if ($desktopSymlinks.ContainsKey($vmName)) {
        $orphanedItems.Add(@{
            Type = "symlink"
            Name = $vmName
            Path = $desktopSymlinks[$vmName]
            Size = 0
        })
    }
}

# Also find broken .utm symlinks (pointing to nonexistent targets)
foreach ($vmName in $desktopSymlinks.Keys) {
    if ($registeredVMs.ContainsKey($vmName)) { continue }
    # Already covered above if the VM name is in allDesktopVMs
}

if ($orphanedItems.Count -eq 0) {
    Write-Output "No orphaned VM files found. Nothing to clean up."
    exit 0
}

# Present orphaned items
Write-Output "The following items are NOT associated with any registered UTM VM:"
Write-Output ""
$totalSize = 0
foreach ($item in $orphanedItems) {
    $totalSize += $item.Size
    if ($item.Type -eq "bundle") {
        $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
        Write-Output "  $($item.Path)  ($sizeStr)"
        # List files within the bundle
        $bundleFiles = Get-ChildItem -Path $item.Path -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in ($bundleFiles | Sort-Object FullName)) {
            $fSizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
            Write-Output "    $($f.FullName)  ($fSizeStr)"
        }
    } else {
        Write-Output "  $($item.Path)  (symlink)"
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

# Delete orphaned items (symlinks first, then bundles)
$errors = 0
foreach ($item in ($orphanedItems | Sort-Object { $_.Type })) {
    try {
        if ($item.Type -eq "symlink") {
            Remove-Item -Path $item.Path -Force
            Write-Output "  Deleted symlink: $($item.Path)"
        } else {
            Remove-Item -Path $item.Path -Recurse -Force
            Write-Output "  Deleted bundle: $($item.Path)"
        }
    } catch {
        Write-Warning "  Failed to delete: $($item.Path) - $_"
        $errors++
    }
}

Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned items deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
