<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42b7e3a1-c8d9-4f56-ab12-3e4f5a6b7c8d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

param(
        [switch]$Force,
    # Quiet mode: suppress every Write-Status (host paths, per-VM file
    # listings, base-image keep-list, "Deleted: <file>" trail) so the
    # automated cycle-start sweep (Remove-TestVMFiles.ps1 -Quiet) emits
    # nothing from this script. Write-Warning / Write-Error remain
    # visible because they always represent an actual problem. Direct
    # invocation (no -Quiet) prints the full log.
    [switch]$Quiet
)

$script:QuietOutput = $Quiet.IsPresent

function Write-Status {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][string]$Message)
    process {
        if ($script:QuietOutput) { Write-Verbose $Message } else { Write-Output $Message }
    }
}

# === Warning ===
Write-Status ""
Write-Status "================================================================"
Write-Status "  WARNING: DESTRUCTIVE OPERATION"
Write-Status "================================================================"
Write-Status ""
Write-Status "  This script deletes files from your Hyper-V storage paths"
Write-Status "  that are NOT associated with any currently listed VM."
Write-Status ""
Write-Status "  This includes orphaned VHDX disks, ISOs, config files,"
Write-Status "  and any other files left behind by removed VMs."
Write-Status ""
Write-Status "  THIS CANNOT BE UNDONE."
Write-Status ""
Write-Status "================================================================"
Write-Status ""

# === Discover base image names from guest.* subfolders ===
# Base image filenames follow the legacy convention "host.<short>.guest.<name>"
# (e.g. host.windows.hyper-v.guest.amazon.linux.2023.vhdx). The script now lives at
# host/<short>/, so Split-Path -Leaf returns just <short>; prepend "host." to
# reconstruct the prefix that every guest's Get-Image.ps1 / New-VM.ps1 writes.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostFolder = "host.$(Split-Path -Leaf $ScriptDir)"
$guestFolders = Get-ChildItem -Path $ScriptDir -Directory -Filter "guest.*"
$baseImageNames = @()
foreach ($guest in $guestFolders) {
    $baseImageNames += "$hostFolder.$($guest.Name)"
}

# Shared Hyper-V / vmms precondition helper.
Import-Module -Name (Join-Path $ScriptDir 'modules/Yuruna.Host.psm1') -Force

# === Check prerequisites ===
Write-Status "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Status "Please run this script as Administrator."
    exit 1
}

# Hyper-V check via dism.exe (not Get-WindowsOptionalFeature) — the cmdlet
# fails with "Class not registered" on some fresh pwsh 7 sessions.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# === Scan for VM files ===
$vmHost = Get-VMHost
$vhdPath = $vmHost.VirtualHardDiskPath
$vmPath = $vmHost.VirtualMachinePath

Write-Status "Hyper-V VirtualHardDiskPath: $vhdPath"
Write-Status "Hyper-V VirtualMachinePath:  $vmPath"
Write-Status ""

# --- See https://yuruna.link/memory#why-orphaned-vm-cleanup-skips-hyper-vs-virtualmachinepath-root
$vmPathNormalized = $vmPath.TrimEnd('\', '/')
$hyperVVmDataPath = (Join-Path $vmPathNormalized 'Virtual Machines').TrimEnd('\', '/')
function Test-IsHyperVSystemPath {
    param([string]$Path)
    $p = $Path.TrimEnd('\', '/')
    # Only VirtualMachinePath entries are "system" candidates;
    # VirtualHardDiskPath content is user VHDX/ISO.
    if (-not $p.StartsWith($vmPathNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    # Under VirtualMachinePath, only "Virtual Machines\" contains user VM
    # data. Everything else (data.vmcx at root, Resource Types\*, the
    # *Cache / Planned / Snapshots / UndoLog / Persistent Tasks / Groups
    # placeholders) is vmms-owned state.
    if ($p -eq $vmPathNormalized) { return $false }  # dir itself isn't deletable anyway
    if ($p.StartsWith($hyperVVmDataPath, [System.StringComparison]::OrdinalIgnoreCase) -and
        ($p.Length -eq $hyperVVmDataPath.Length -or $p[$hyperVVmDataPath.Length] -eq '\')) {
        return $false
    }
    return $true
}

$scanPaths = @($vhdPath, $vmPath) | Sort-Object -Unique
foreach ($p in $scanPaths) {
    if (!(Test-Path -Path $p)) {
        Write-Status "Path does not exist: $p"
        exit 1
    }
}

$allFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($scanPath in $scanPaths) {
    $files = Get-ChildItem -Path $scanPath -Recurse -File -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        if (Test-IsHyperVSystemPath $file.FullName) { continue }
        [void]$allFiles.Add($file.FullName)
    }
}

if ($allFiles.Count -eq 0) {
    Write-Status "No files found under the Hyper-V storage paths."
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
    Write-Status "No VMs found in Hyper-V Manager."
} else {
    Write-Status "Currently listed VMs and their associated files:"
    Write-Status ""
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

    Write-Status "  $($vm.Name) [$($vm.State)]"
    if ($vmFiles.Count -eq 0) {
        Write-Status "    (no files found under scan paths)"
    } else {
        foreach ($f in ($vmFiles | Sort-Object)) {
            $fileInfo = Get-Item -Path $f -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
                Write-Status "    $f  ($sizeStr)"
            } else {
                Write-Status "    $f  (not on disk)"
            }
        }
    }
    Write-Status ""
}

# === Identify orphaned files (excluding base images) ===
$orphanedFiles = [System.Collections.Generic.List[string]]::new()
$protectedFiles = [System.Collections.Generic.List[string]]::new()

foreach ($f in $allFiles) {
    if ($claimedFiles.Contains($f)) { continue }

    # Match against base-image names (e.g. host.windows.hyper-v.guest.amazon.linux.2023.vhdx).
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
    Write-Status "The following base images are KEPT (not associated with any VM, but needed as base images):"
    Write-Status ""
    foreach ($filePath in ($protectedFiles | Sort-Object)) {
        $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
            Write-Status "  $filePath  ($sizeStr)"
        } else {
            Write-Status "  $filePath"
        }
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        $guestName = ($fileName -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-Status "    Reason: base image for $guestName. Update by rerunning Get-Image.ps1 in $guestName/"
    }
    Write-Status ""
}

# === Delete orphaned files ===
if ($orphanedFiles.Count -eq 0) {
    Write-Status "No orphaned files found. Nothing to clean up."
    exit 0
}

Write-Status "The following files are NOT associated with any current VM:"
Write-Status ""
$totalSize = 0
foreach ($filePath in ($orphanedFiles | Sort-Object)) {
    $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
    if ($fileInfo) {
        $totalSize += $fileInfo.Length
        $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
        Write-Status "  $filePath  ($sizeStr)"
    }
}
Write-Status ""
Write-Status ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-Status ""
Write-Status "Empty subfolders will also be removed after file deletion."
Write-Status ""

# Ask for confirmation (skip if -Force)
if ($Force) {
    Write-Status "Force mode enabled — skipping confirmation."
} else {
    $confirmation = Read-Host "Type YES to delete all listed items, or anything else to cancel"
    if ($confirmation -ne "YES") {
        Write-Status "Operation cancelled. No files were deleted."
        exit 0
    }
}

$errors = 0
foreach ($filePath in $orphanedFiles) {
    try {
        Remove-Item -Path $filePath -Force
        Write-Status "  Deleted: $filePath"
    } catch {
        Write-Warning "  Failed to delete: $filePath - $_"
        $errors++
    }
}

# Remove empty subfolders, deepest first so parents empty as children go.
# Hyper-V's system subdirs under VirtualMachinePath (Planned Virtual Machines,
# Snapshots Cache, Resource Types, ...) are normally empty on a no-VMs
# host but are part of vmms's expected layout — earlier logs showed
# "Removed empty folder: ..." for 15+ system dirs per cycle. Skip
# anything Test-IsHyperVSystemPath flags.
foreach ($scanPath in $scanPaths) {
    $dirs = Get-ChildItem -Path $scanPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        if (Test-IsHyperVSystemPath $dir.FullName) { continue }
        $remaining = Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $remaining -or $remaining.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Force
                Write-Status "  Removed empty folder: $($dir.FullName)"
            } catch {
                Write-Warning "  Failed to remove folder: $($dir.FullName) - $_"
                $errors++
            }
        }
    }
}

# === Cleanup result ===
Write-Status ""
if ($errors -eq 0) {
    Write-Status "Cleanup complete. All orphaned items deleted."
} else {
    Write-Status "Cleanup complete with $errors error(s). Some items could not be deleted."
}
