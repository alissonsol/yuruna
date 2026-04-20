<#PSScriptInfo
.VERSION 0.1
.GUID 42b7e3a1-c8d9-4f56-ab12-3e4f5a6b7c8d
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

# === Discover base image names from guest.* subfolders ===
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostFolder = Split-Path -Leaf $ScriptDir
$guestFolders = Get-ChildItem -Path $ScriptDir -Directory -Filter "guest.*"
$baseImageNames = @()
foreach ($guest in $guestFolders) {
    $baseImageNames += "$hostFolder.$($guest.Name)"
}

# Shared Hyper-V / vmms precondition helper.
Import-Module -Name (Join-Path $ScriptDir 'VM.common.psm1') -Force

# === Check prerequisites ===
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    exit 1
}

# Hyper-V check via dism.exe (not Get-WindowsOptionalFeature) — the cmdlet
# fails with "Class not registered" on some fresh pwsh 7 sessions.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# === Scan for VM files ===
$vmHost = Get-VMHost
$vhdPath = $vmHost.VirtualHardDiskPath
$vmPath = $vmHost.VirtualMachinePath

Write-Output "Hyper-V VirtualHardDiskPath: $vhdPath"
Write-Output "Hyper-V VirtualMachinePath:  $vmPath"
Write-Output ""

# Hyper-V's VirtualMachinePath root contains service-owned metadata that
# vmms keeps open for the lifetime of the service: data.vmcx at the root,
# Resource Types\<GUID>.vmcx (one per registered resource provider), plus
# a set of empty placeholder subdirs for planned/snapshot/undo state.
# Earlier, this script walked the whole tree, found those files "unclaimed"
# on a machine with no registered VMs, and tried to delete them -- vmms
# refused every delete with "file in use", producing ~26 warnings per
# cycle on a fresh Windows install. Never surface those paths as
# candidates, and never touch them during the empty-folder sweep below.
# The canonical VM-data subtree under VirtualMachinePath is "Virtual
# Machines\" -- that stays in scope along with all of VirtualHardDiskPath.
$vmPathNormalized = $vmPath.TrimEnd('\', '/')
$hyperVVmDataPath = (Join-Path $vmPathNormalized 'Virtual Machines').TrimEnd('\', '/')
function Test-IsHyperVSystemPath {
    param([string]$Path)
    $p = $Path.TrimEnd('\', '/')
    # Only paths under VirtualMachinePath are candidates for "system".
    # Anything under VirtualHardDiskPath is user VHDX/ISO data.
    if (-not $p.StartsWith($vmPathNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    # Under VirtualMachinePath, only the "Virtual Machines\" subtree
    # contains user VM data. Everything else (data.vmcx at the root,
    # Resource Types\*, the *Cache / Planned / Snapshots / UndoLog /
    # Persistent Tasks / Groups placeholders) is vmms-owned state.
    if ($p -eq $vmPathNormalized) { return $false }  # the dir itself isn't deletable anyway
    if ($p.StartsWith($hyperVVmDataPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($p.Length -eq $hyperVVmDataPath.Length -or $p[$hyperVVmDataPath.Length] -eq '\')) {
        return $false
    }
    return $true
}

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
        if (Test-IsHyperVSystemPath $file.FullName) { continue }
        [void]$allFiles.Add($file.FullName)
    }
}

if ($allFiles.Count -eq 0) {
    Write-Output "No files found under the Hyper-V storage paths."
    exit 0
}

# === Identify files claimed by active VMs ===
$allVMs = Get-VM
$claimedFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Add-ClaimedFilesUnderDir {
    param([string]$DirPath)
    if (-not $DirPath) { return }
    $normalizedDir = $DirPath.TrimEnd('\', '/')
    foreach ($f in $allFiles) {
        if ($f.StartsWith($normalizedDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            [void]$claimedFiles.Add($f)
        }
    }
}

# === List registered VMs and their associated files ===
if ($allVMs.Count -eq 0) {
    Write-Output "No VMs found in Hyper-V Manager."
} else {
    Write-Output "Currently listed VMs and their associated files:"
    Write-Output ""
}

foreach ($vm in $allVMs) {
    $vmFiles = [System.Collections.Generic.List[string]]::new()

    foreach ($dir in @($vm.Path, $vm.ConfigurationLocation, $vm.SnapshotFileLocation)) {
        if ($dir) {
            Add-ClaimedFilesUnderDir $dir
            $normalizedDir = $dir.TrimEnd('\', '/')
            foreach ($f in $allFiles) {
                if ($f.StartsWith($normalizedDir + '\', [System.StringComparison]::OrdinalIgnoreCase) -and
                    -not $vmFiles.Contains($f)) {
                    $vmFiles.Add($f)
                }
            }
        }
    }

    $hdds = Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($hdd in $hdds) {
        if ($hdd.Path) {
            [void]$claimedFiles.Add($hdd.Path)
            if (-not $vmFiles.Contains($hdd.Path)) { $vmFiles.Add($hdd.Path) }
        }
    }

    $dvds = Get-VMDvdDrive -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($dvd in $dvds) {
        if ($dvd.Path) {
            [void]$claimedFiles.Add($dvd.Path)
            if (-not $vmFiles.Contains($dvd.Path)) { $vmFiles.Add($dvd.Path) }
        }
    }

    $checkpoints = Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($cp in $checkpoints) {
        if ($cp.Path) {
            Add-ClaimedFilesUnderDir $cp.Path
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

# === Identify orphaned files (excluding base images) ===
$orphanedFiles = [System.Collections.Generic.List[string]]::new()
$protectedFiles = [System.Collections.Generic.List[string]]::new()

foreach ($f in $allFiles) {
    if ($claimedFiles.Contains($f)) { continue }

    # Check if this file matches a base image name (e.g., host.windows.hyper-v.guest.amazon.linux.vhdx)
    $fileName = [System.IO.Path]::GetFileNameWithoutExtension($f)
    $isBaseImage = $false
    foreach ($baseImageName in $baseImageNames) {
        if ($fileName -eq $baseImageName) {
            $isBaseImage = $true
            break
        }
    }

    if ($isBaseImage) {
        $protectedFiles.Add($f)
    } else {
        $orphanedFiles.Add($f)
    }
}

# === List protected base images ===
if ($protectedFiles.Count -gt 0) {
    Write-Output "The following base images are KEPT (not associated with any VM, but needed as base images):"
    Write-Output ""
    foreach ($filePath in ($protectedFiles | Sort-Object)) {
        $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
            Write-Output "  $filePath  ($sizeStr)"
        } else {
            Write-Output "  $filePath"
        }
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        $guestName = ($fileName -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-Output "    Reason: base image for $guestName. Update by rerunning Get-Image.ps1 in $guestName/"
    }
    Write-Output ""
}

# === Delete orphaned files ===
if ($orphanedFiles.Count -eq 0) {
    Write-Output "No orphaned files found. Nothing to clean up."
    exit 0
}

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
foreach ($filePath in $orphanedFiles) {
    try {
        Remove-Item -Path $filePath -Force
        Write-Output "  Deleted: $filePath"
    } catch {
        Write-Warning "  Failed to delete: $filePath - $_"
        $errors++
    }
}

# Remove empty subfolders (deepest first so parents become empty after children are removed).
# Hyper-V's system subdirs under VirtualMachinePath (Planned Virtual Machines,
# Snapshots Cache, Resource Types, ...) are normally empty on a no-VMs host
# but are part of vmms's expected directory layout -- removing them showed
# up in earlier logs as "Removed empty folder: ..." for 15+ Hyper-V system
# dirs per cycle. Skip anything Test-IsHyperVSystemPath flags so we don't
# mess with Hyper-V's internal layout.
foreach ($scanPath in $scanPaths) {
    $dirs = Get-ChildItem -Path $scanPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        if (Test-IsHyperVSystemPath $dir.FullName) { continue }
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

# === Cleanup result ===
Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned items deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
