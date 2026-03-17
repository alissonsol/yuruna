<#PSScriptInfo
.VERSION 0.1
.GUID 42b7e3a1-c8d9-4f56-ab12-3e4f5a6b7c8d
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

# Inform and check for elevation
Write-Output ""
Write-Output "================================================================"
Write-Output "  WARNING: DESTRUCTIVE OPERATION"
Write-Output "================================================================"
Write-Output ""
Write-Output "  This script deletes files from your Hyper-V storage paths"
Write-Output "  that are NOT associated with any currently listed VM."
Write-Output ""
Write-Output "  This includes orphaned VHDX disks, ISOs, config files,"
Write-Output "  and any other files left behind by removed VMs."
Write-Output ""
Write-Output "  THIS CANNOT BE UNDONE."
Write-Output ""
Write-Output "================================================================"
Write-Output ""
Write-Output "This script requires elevation (Run as Administrator)."

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# Check if Hyper-V services are installed and running
$hypervFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
if ($hypervFeature.State -ne 'Enabled') {
    Write-Output "Hyper-V is not enabled. Please enable Hyper-V from Windows Features."
    exit 1
}

$service = Get-Service -Name vmms -ErrorAction SilentlyContinue
if (!$service -or $service.Status -ne 'Running') {
    Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running."
    exit 1
}

# Get Hyper-V storage paths
$vmHost = Get-VMHost
$vhdPath = $vmHost.VirtualHardDiskPath
$vmPath = $vmHost.VirtualMachinePath

Write-Output "Hyper-V VirtualHardDiskPath: $vhdPath"
Write-Output "Hyper-V VirtualMachinePath:  $vmPath"
Write-Output ""

# Collect all paths to scan (deduplicate if both point to the same location)
$scanPaths = @($vhdPath, $vmPath) | Sort-Object -Unique
foreach ($p in $scanPaths) {
    if (!(Test-Path -Path $p)) {
        Write-Output "Path does not exist: $p"
        exit 1
    }
}

# Enumerate all files under the scan paths
$allFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($scanPath in $scanPaths) {
    $files = Get-ChildItem -Path $scanPath -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        [void]$allFiles.Add($file.FullName)
    }
}

if ($allFiles.Count -eq 0) {
    Write-Output "No files found under the Hyper-V storage paths."
    exit 0
}

# For each VM, collect associated files and remove them from the set
$allVMs = Get-VM
$claimedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Helper: claim all files under a directory that exist in our file set
function Claim-FilesUnderDir {
    param([string]$DirPath)
    if (-not $DirPath) { return }
    $normalizedDir = $DirPath.TrimEnd('\', '/')
    foreach ($f in $allFiles) {
        if ($f.StartsWith($normalizedDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$claimedFiles.Add($f)
        }
    }
}

if ($allVMs.Count -eq 0) {
    Write-Output "No VMs found in Hyper-V Manager."
} else {
    Write-Output "Currently listed VMs and their associated files:"
    Write-Output ""
}

foreach ($vm in $allVMs) {
    $vmFiles = [System.Collections.Generic.List[string]]::new()

    # VM configuration, state, and snapshot directories — claim all files within
    foreach ($dir in @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation)) {
        if ($dir) {
            Claim-FilesUnderDir $dir
            $normalizedDir = $dir.TrimEnd('\', '/')
            foreach ($f in $allFiles) {
                if ($f.StartsWith($normalizedDir + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not $vmFiles.Contains($f)) {
                    $vmFiles.Add($f)
                }
            }
        }
    }

    # Hard disk drives
    $hdds = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($hdd in $hdds) {
        if ($hdd.Path) {
            [void]$claimedFiles.Add($hdd.Path)
            if (-not $vmFiles.Contains($hdd.Path)) { $vmFiles.Add($hdd.Path) }
        }
    }

    # DVD drives
    $dvds = Get-VMDvdDrive -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($dvd in $dvds) {
        if ($dvd.Path) {
            [void]$claimedFiles.Add($dvd.Path)
            if (-not $vmFiles.Contains($dvd.Path)) { $vmFiles.Add($dvd.Path) }
        }
    }

    # Checkpoints
    $checkpoints = Get-VMCheckpoint -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($cp in $checkpoints) {
        if ($cp.Path) {
            Claim-FilesUnderDir $cp.Path
            $normalizedDir = $cp.Path.TrimEnd('\', '/')
            foreach ($f in $allFiles) {
                if ($f.StartsWith($normalizedDir + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not $vmFiles.Contains($f)) {
                    $vmFiles.Add($f)
                }
            }
        }
        $cpHdds = Get-VMHardDiskDrive -VMCheckpoint $cp -ErrorAction SilentlyContinue
        foreach ($hdd in $cpHdds) {
            if ($hdd.Path) {
                [void]$claimedFiles.Add($hdd.Path)
                if (-not $vmFiles.Contains($hdd.Path)) { $vmFiles.Add($hdd.Path) }
            }
        }
    }

    Write-Output "  $($vm.Name) [$($vm.State)]"
    if ($vmFiles.Count -eq 0) {
        Write-Output "    (no files found under scan paths)"
    } else {
        foreach ($f in ($vmFiles | Sort-Object)) {
            $fileInfo = Get-Item -Path $f -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
                Write-Output "    $f  ($sizeStr)"
            } else {
                Write-Output "    $f  (not on disk)"
            }
        }
    }
    Write-Output ""
}

# Orphaned files = all files minus claimed files
$orphanedFiles = [System.Collections.Generic.List[string]]::new()
foreach ($f in $allFiles) {
    if (-not $claimedFiles.Contains($f)) {
        $orphanedFiles.Add($f)
    }
}

if ($orphanedFiles.Count -eq 0) {
    Write-Output "No orphaned files found. Nothing to clean up."
    exit 0
}

# Present orphaned files
Write-Output "The following files are NOT associated with any current VM:"
Write-Output ""
$totalSize = 0
foreach ($filePath in ($orphanedFiles | Sort-Object)) {
    $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
    if ($fileInfo) {
        $totalSize += $fileInfo.Length
        $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
        Write-Output "  $filePath  ($sizeStr)"
    }
}
Write-Output ""
Write-Output ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-Output ""
Write-Output "Empty subfolders will also be removed after file deletion."
Write-Output ""

# Ask for confirmation
$confirmation = Read-Host "Type YES to delete all listed items, or anything else to cancel"
if ($confirmation -ne "YES") {
    Write-Output "Operation cancelled. No files were deleted."
    exit 0
}

# Delete orphaned files
$errors = 0
foreach ($filePath in $orphanedFiles) {
    try {
        Remove-Item -Path $filePath -Force
        Write-Output "  Deleted: $filePath"
    } catch {
        Write-Warning "  Failed to delete: $filePath - $_"
        $errors++
    }
}

# Remove empty subfolders (deepest first so parents become empty after children are removed)
foreach ($scanPath in $scanPaths) {
    $dirs = Get-ChildItem -Path $scanPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        $remaining = Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $remaining -or $remaining.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Force
                Write-Output "  Removed empty folder: $($dir.FullName)"
            } catch {
                Write-Warning "  Failed to remove folder: $($dir.FullName) - $_"
                $errors++
            }
        }
    }
}

Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned items deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
