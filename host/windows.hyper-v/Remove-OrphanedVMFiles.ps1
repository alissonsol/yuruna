<#PSScriptInfo
.VERSION 2026.09.24
.GUID 420effcb-c2e1-4c95-b3b0-ddb550aecce4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows hyper-v cleanup
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

<#
.SYNOPSIS
    Delete files under the Hyper-V storage paths that no longer belong to a
    registered VM.

.DESCRIPTION
    Sibling of host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1 and
    host/macos.utm/Remove-OrphanedVMFiles.ps1. Scans VirtualHardDiskPath and
    VirtualMachinePath, keeps every file claimed by a registered VM or matching
    a base-image name, and deletes the rest plus the subfolders that empty out.
    vmms-owned state under VirtualMachinePath is never a candidate.

    Needs Administrator: Get-VMHost, Get-VM and Get-VMHardDiskDrive all do.

.PARAMETER Force
    Skip the YES confirmation. Used by test/Remove-TestVMFiles.ps1.

.PARAMETER Quiet
    Suppress the per-file cleanup log; warnings and errors still print.
#>

param(
    [switch]$Force,
    # Suppress every Write-CleanupMessage so the automated cycle-start sweep
    # (Remove-TestVMFiles.ps1 -Quiet) emits nothing from this script. Warnings
    # and errors still print: they always mean something the operator needs.
    # The routing contract is Set-VMCleanupQuiet in
    # host/modules/Yuruna.VMCleanup.psm1.
    [switch]$Quiet
)

# --- REGION: Elevation gate
# Every path below needs Administrator (Get-VMHost, Get-VM, Get-VMHardDiskDrive),
# so refuse HERE -- ahead of the destructive-operation banner and the base-image
# scan -- rather than after the operator has read "THIS CANNOT BE UNDONE" for a
# run that cannot proceed. Write-Warning, not Write-CleanupMessage: the module is
# not imported yet, and -Quiet must not swallow the reason for exit 1. Neither
# Write-Error nor '#requires -RunAsAdministrator' would do: Remove-TestVMFiles.ps1
# invokes this in-process under $ErrorActionPreference='Stop', where either would
# abort the parent teardown instead of returning a graceful exit 1.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_364385267309aa5b')
    exit 1
}

# Write-CleanupMessage + base-image discovery live in
# host/modules/Yuruna.VMCleanup.psm1 so a future tweak to the routing
# contract (or a new piece of cleanup state) lands in one place rather
# than three.
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.VMCleanup.psm1') -Force
Set-VMCleanupQuiet -Quiet $Quiet.IsPresent

# --- REGION: Warning
Write-CleanupMessage ""
Write-CleanupMessage "========"
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_f3adc201e5fa38f4')
Write-CleanupMessage "========"
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_55ad2133fb65eb83')
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_e29eba4500369d0f')
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_39d8e7a5850aacaf')
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_85ac66690dafb784')
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d506f23d4fcc7fa4')
Write-CleanupMessage ""
Write-CleanupMessage "========"
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
# Hyper-V check via dism.exe (not Get-WindowsOptionalFeature) -- the cmdlet
# fails with "Class not registered" on some fresh pwsh 7 sessions.
if (-not (Assert-HyperVEnabled)) { exit 1 }

# --- REGION: Scan for VM artifacts
$vmHost = Get-VMHost
$vhdPath = $vmHost.VirtualHardDiskPath
$vmPath = $vmHost.VirtualMachinePath

Write-CleanupMessage "Hyper-V VirtualHardDiskPath: $vhdPath"
Write-CleanupMessage "Hyper-V VirtualMachinePath:  $vmPath"
Write-CleanupMessage ""

# --- REGION: https://yuruna.link/42d69dfa-001c
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
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_89af27dbbf79e963' -Arguments @{ p = "$p" })
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
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_3de170cc1071d586')
    exit 0
}

# --- REGION: Enumerate registered VMs
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
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_924d989240c982fe')
} else {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_5788f4c3cbc5c5cb')
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
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_78f1a083d6efc936')
    } else {
        foreach ($f in ($vmFiles | Sort-Object)) {
            $fileInfo = Get-Item -Path $f -ErrorAction SilentlyContinue
            if ($fileInfo) {
                $sizeStr = "{0:N2} MB" -f ($fileInfo.Length / 1MB)
                Write-CleanupMessage "    $f  ($sizeStr)"
            } else {
                Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_3cc328e8993a6376' -Arguments @{ f = "$f" })
            }
        }
    }
    Write-CleanupMessage ""
}

# --- REGION: Identify orphaned VM artifacts
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
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_54bfa469abe90720')
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
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_91b0a35a1dfecdc4' -Arguments @{ guestName = "$guestName" })
    }
    Write-CleanupMessage ""
}

# --- REGION: Strip stale per-VM ACEs from kept base images
# See https://yuruna.link/429f3d06-0093
# Runs every invocation, before the deletion prompt -- safe maintenance that
# only removes access for VMs that no longer exist.
foreach ($filePath in $protectedFiles) {
    try {
        $prunedAce = Remove-OrphanedVMFileAccess -Path $filePath
        if ($prunedAce -gt 0) {
            Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_1d352ef4cfa86c55' -Arguments @{ prunedAce = "$prunedAce"; filePath = "$filePath" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a2a687435a04d1fc' -Arguments @{ filePath = "$filePath"; value = "$_" })
    }
}

# --- REGION: Delete orphaned VM artifacts
if ($orphanedFiles.Count -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_516e847dc1888e9f')
    exit 0
}

Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_bda747e61af2936d')
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
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_3e2337ab67132732' -FormatValues (($totalSize / 1GB)) -FormatBindings @{ gB = '0:N2' })
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d4cd1463d5f4d184')
Write-CleanupMessage ""

if ($Force) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_7fe1c2acfba18375')
} else {
    $confirmation = Read-Host (Format-YurunaOperatorMessage -Key 'host.operator_67b2df91dc3bcc59')
    if ($confirmation -ne "YES") {
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_ac15f0cb601d9a5f')
        exit 0
    }
}

$errors = 0
foreach ($filePath in $orphanedFiles) {
    try {
        Remove-Item -Path $filePath -Force
        Write-CleanupMessage "  Deleted: $filePath"
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a77fd89b921c3ab7' -Arguments @{ filePath = "$filePath"; value = "$_" })
        $errors++
    }
}

# Remove empty subfolders, deepest first so parents empty as children go.
# Hyper-V's system subdirs under VirtualMachinePath (Planned Virtual Machines,
# Snapshots Cache, Resource Types, ...) are normally empty on a no-VMs
# host but are part of vmms's expected layout -- without a guard the
# empty-folder sweep removes 15+ vmms system dirs on every run, only for
# vmms to recreate them. Skip anything Test-IsHyperVSystemPath flags.
foreach ($scanPath in $scanPaths) {
    $dirs = Get-ChildItem -Path $scanPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending
    foreach ($dir in $dirs) {
        if (Test-IsHyperVSystemPath $dir.FullName) { continue }
        $remaining = Get-ChildItem -Path $dir.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $remaining -or $remaining.Count -eq 0) {
            try {
                Remove-Item -Path $dir.FullName -Force
                Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_3a3fdfb4b32c1839' -Arguments @{ fullName = "$($dir.FullName)" })
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2823da5e63119e42' -Arguments @{ fullName = "$($dir.FullName)"; value = "$_" })
                $errors++
            }
        }
    }
}

# --- REGION: Cleanup result
Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_a0a6b2ff7f34905f')
} else {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_42dbc0a404948dc9' -Arguments @{ errors = "$errors" })
}
