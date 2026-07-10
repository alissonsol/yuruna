<#PSScriptInfo
.VERSION 2026.07.10
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
    # Quiet mode: suppress every Write-CleanupMessage (host paths, per-VM file
    # listings, base-image keep-list, "Deleted: <file>" trail) so the
    # automated cycle-start sweep (Remove-TestVMFiles.ps1 -Quiet) emits
    # nothing from this script. Write-Warning / Write-Error remain
    # visible because they always represent an actual problem. Direct
    # invocation (no -Quiet) prints the full log.
    [switch]$Quiet
)

# Write-CleanupMessage + base-image discovery live in
# host/modules/Yuruna.VMCleanup.psm1 so a future tweak to the routing
# contract (or a new piece of cleanup state) lands in one place rather
# than three.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.VMCleanup.psm1') -Force
Set-VMCleanupQuiet -Quiet $Quiet.IsPresent

# --- REGION: Warning
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage "  WARNING: DESTRUCTIVE OPERATION"
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""
Write-CleanupMessage "  This script deletes files from your Hyper-V storage paths"
Write-CleanupMessage "  that are NOT associated with any currently listed VM."
Write-CleanupMessage ""
Write-CleanupMessage "  This includes orphaned VHDX disks, ISOs, config files,"
Write-CleanupMessage "  and any other files left behind by removed VMs."
Write-CleanupMessage ""
Write-CleanupMessage "  THIS CANNOT BE UNDONE."
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""

# Base image filenames follow the legacy convention "host.<short>.guest.<name>"
# (e.g. host.windows.hyper-v.guest.amazon.linux.2023.vhdx). Resolve-BaseImageName
# walks guest.* subfolders and reconstructs the prefix every Get-Image.ps1 /
# New-VM.ps1 writes.
$nameInfo       = Resolve-BaseImageName -HostScriptDir $ScriptDir
$hostFolder     = $nameInfo.HostFolder
$baseImageNames = $nameInfo.BaseImageNames

# Shared Hyper-V / vmms precondition helper.
Import-Module -Name (Join-Path $ScriptDir 'modules/Yuruna.Host.psm1') -Force

# --- REGION: Check prerequisites
Write-CleanupMessage "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-CleanupMessage "Please run this script as Administrator."
    exit 1
}

# Hyper-V check via dism.exe (not Get-WindowsOptionalFeature) -- the cmdlet
# fails with "Class not registered" on some fresh pwsh 7 sessions.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# --- REGION: Scan for VM files
$vmHost = Get-VMHost
$vhdPath = $vmHost.VirtualHardDiskPath
$vmPath = $vmHost.VirtualMachinePath

Write-CleanupMessage "Hyper-V VirtualHardDiskPath: $vhdPath"
Write-CleanupMessage "Hyper-V VirtualMachinePath:  $vmPath"
Write-CleanupMessage ""

# --- REGION: https://yuruna.link/memory#why-orphaned-vm-cleanup-skips-hyper-vs-virtualmachinepath-root
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
        Write-CleanupMessage "Path does not exist: $p"
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
    Write-CleanupMessage "No files found under the Hyper-V storage paths."
    exit 0
}

# --- REGION: Identify files claimed by active VMs
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

# --- REGION: List registered VMs and their associated files
if ($allVMs.Count -eq 0) {
    Write-CleanupMessage "No VMs found in Hyper-V Manager."
} else {
    Write-CleanupMessage "Currently registered VMs and their associated files:"
    Write-CleanupMessage ""
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

    Write-CleanupMessage "  $($vm.Name) [$($vm.State)]"
    if ($vmFiles.Count -eq 0) {
        Write-CleanupMessage "    (no files found under scan paths)"
    } else {
        foreach ($f in ($vmFiles | Sort-Object)) {
            $fileInfo = Get-Item -Path $f -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
                Write-CleanupMessage "    $f  ($sizeStr)"
            } else {
                Write-CleanupMessage "    $f  (not on disk)"
            }
        }
    }
    Write-CleanupMessage ""
}

# --- REGION: Identify orphaned files (excluding base images)
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

# --- REGION: List protected base images
if ($protectedFiles.Count -gt 0) {
    Write-CleanupMessage "The following base images are KEPT (not associated with any VM, but needed as base images):"
    Write-CleanupMessage ""
    foreach ($filePath in ($protectedFiles | Sort-Object)) {
        $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
        if ($fileInfo) {
            $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
            Write-CleanupMessage "  $filePath  ($sizeStr)"
        } else {
            Write-CleanupMessage "  $filePath"
        }
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        $guestName = ($fileName -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-CleanupMessage "    Reason: base image for $guestName. Update by rerunning Get-Image.ps1 in $guestName/"
    }
    Write-CleanupMessage ""
}

# --- REGION: Strip stale per-VM ACEs from kept base images
# A SHARED base image (e.g. a base install ISO reused for every VM creation)
# gathers one per-VM access ACE per VM created against it; Hyper-V never
# revokes them on Remove-VM, so the DACL grows until it hits the ~64 KB ACL
# limit and the next Add-VMDvdDrive fails with 0x8007053C. Prune the ACEs of
# VMs that no longer exist here. No-op on base VHDX images (those are copied
# per-VM and never attached directly, so they accumulate nothing). Runs every
# invocation, before the deletion prompt, because it is safe maintenance --
# it only removes access for VMs that no longer exist. See
# docs/hyperv-iso-ace-bloat.md.
foreach ($filePath in $protectedFiles) {
    try {
        $prunedAce = Remove-OrphanedVMFileAccess -Path $filePath
        if ($prunedAce -gt 0) {
            Write-CleanupMessage "  Pruned $prunedAce stale per-VM ACE(s) from base image: $filePath"
        }
    } catch {
        Write-Warning "  Could not prune stale ACEs from $filePath - $_"
    }
}

# --- REGION: Delete orphaned files
if ($orphanedFiles.Count -eq 0) {
    Write-CleanupMessage "No orphaned files found. Nothing to clean up."
    exit 0
}

Write-CleanupMessage "The following files are NOT associated with any current VM:"
Write-CleanupMessage ""
$totalSize = 0
foreach ($filePath in ($orphanedFiles | Sort-Object)) {
    $fileInfo = Get-Item -Path $filePath -ErrorAction SilentlyContinue
    if ($fileInfo) {
        $totalSize += $fileInfo.Length
        $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
        Write-CleanupMessage "  $filePath  ($sizeStr)"
    }
}
Write-CleanupMessage ""
Write-CleanupMessage ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-CleanupMessage ""
Write-CleanupMessage "Empty subfolders will also be removed after file deletion."
Write-CleanupMessage ""

# Ask for confirmation (skip if -Force)
if ($Force) {
    Write-CleanupMessage "Force mode enabled -- skipping confirmation."
} else {
    $confirmation = Read-Host "Type YES to delete all listed items, or anything else to cancel"
    if ($confirmation -ne "YES") {
        Write-CleanupMessage "Operation cancelled. No files were deleted."
        exit 0
    }
}

$errors = 0
foreach ($filePath in $orphanedFiles) {
    try {
        Remove-Item -Path $filePath -Force
        Write-CleanupMessage "  Deleted: $filePath"
    } catch {
        Write-Warning "  Failed to delete: $filePath - $_"
        $errors++
    }
}

# Remove empty subfolders, deepest first so parents empty as children go.
# Hyper-V's system subdirs under VirtualMachinePath (Planned Virtual Machines,
# Snapshots Cache, Resource Types, ...) are normally empty on a no-VMs
# host but are part of vmms's expected layout -- earlier logs showed
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
                Write-CleanupMessage "  Removed empty folder: $($dir.FullName)"
            } catch {
                Write-Warning "  Failed to remove folder: $($dir.FullName) - $_"
                $errors++
            }
        }
    }
}

# --- REGION: Cleanup result
Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage "Cleanup complete. All orphaned files deleted."
} else {
    Write-CleanupMessage "Cleanup complete with $errors error(s). Some items could not be deleted."
}
