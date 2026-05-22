<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e98
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    Delete per-VM artifact directories under ~/yuruna/vms/ that are no
    longer associated with a registered libvirt domain.

.DESCRIPTION
    Sibling of host/macos.utm/Remove-OrphanedVMFiles.ps1 and
    host/windows.hyper-v/Remove-OrphanedVMFiles.ps1. On KVM each VM's
    on-disk state is a single directory:

      ~/yuruna/vms/<vmname>/<vmname>.qcow2
      ~/yuruna/vms/<vmname>/seed.iso
      ~/yuruna/vms/<vmname>/seed.src/

    Base images live under ~/yuruna/image/<guest>/, so this scan never
    needs a protected-image list -- only the vms/ tree is touched.

    A directory is orphaned iff `virsh list --all --name` does not list
    a domain by the same name. Registered VMs (running, stopped, paused)
    are left strictly alone.

.PARAMETER Force
    Skip the YES confirmation. Used by test/Remove-TestVMFiles.ps1.
#>

param(
    [switch]$Force
)

# Auto-relaunch under sg libvirt when this shell's running supplementary
# group set lacks libvirt. The virsh call at "Enumerate registered
# libvirt domains" below talks directly to /var/run/libvirt/libvirt-sock
# (no sudo), so a stale-group shell fails with "Permission denied".
# Helper lives in test/modules/Test.Host.psm1 (sibling tree); resolve it
# relative to this script's location since the host driver and the test
# harness don't share a CWD assumption.
$_repoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$_testHost   = Join-Path $_repoRoot 'test/modules/Test.Host.psm1'
if (Test-Path $_testHost) {
    Import-Module $_testHost -Force
    Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
}

# === Warning ===
Write-Output ""
Write-Output "================================================================"
Write-Output "  WARNING: DESTRUCTIVE OPERATION"
Write-Output "================================================================"
Write-Output ""
Write-Output "  This script deletes VM directories under ~/yuruna/vms/"
Write-Output "  that are NOT registered with libvirt."
Write-Output ""
Write-Output "  THIS CANNOT BE UNDONE."
Write-Output ""
Write-Output "================================================================"
Write-Output ""

$vmRoot = Join-Path $HOME 'yuruna/vms'
if (-not (Test-Path -LiteralPath $vmRoot)) {
    Write-Output "No VM directory at '$vmRoot'. Nothing to scan."
    exit 0
}

if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
    Write-Error "virsh not found. Install libvirt-clients (apt-get install libvirt-clients)."
    exit 1
}

$virshUri = 'qemu:///system'

# === Enumerate registered libvirt domains ===
$virshOutput = & virsh --connect $virshUri list --all --name 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "virsh list failed (is libvirtd running?). Output: $virshOutput"
    exit 1
}
$registered = @{}
foreach ($n in $virshOutput) {
    $name = "$n".Trim()
    if ($name) { $registered[$name] = $true }
}

Write-Output "libvirt registered VMs: $($registered.Count)"
Write-Output ""

if ($registered.Count -gt 0) {
    Write-Output "Currently registered VMs and their on-disk artifacts:"
    Write-Output ""
    foreach ($vmName in ($registered.Keys | Sort-Object)) {
        $vmDir = Join-Path $vmRoot $vmName
        Write-Output "  $vmName"
        if (Test-Path -LiteralPath $vmDir) {
            $files = Get-ChildItem -Path $vmDir -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in ($files | Sort-Object FullName)) {
                $sizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
                Write-Output "    $($f.FullName)  ($sizeStr)"
            }
        } else {
            Write-Output "    (no artifact directory under $vmRoot)"
        }
        Write-Output ""
    }
}

# === Identify orphaned per-VM directories ===
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()
$dirs = @(Get-ChildItem -LiteralPath $vmRoot -Directory -ErrorAction SilentlyContinue)
foreach ($d in $dirs) {
    if ($registered.ContainsKey($d.Name)) { continue }
    $sum = (Get-ChildItem -Path $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $size = if ($null -eq $sum) { 0 } else { [int64]$sum }
    $orphanedItems.Add(@{ Name = $d.Name; Path = $d.FullName; Size = $size })
}

if ($orphanedItems.Count -eq 0) {
    Write-Output "No orphaned VM directories found. Nothing to clean up."
    exit 0
}

Write-Output "The following directories are NOT associated with any registered libvirt domain:"
Write-Output ""
$totalSize = [int64]0
foreach ($item in $orphanedItems) {
    $totalSize += [int64]$item.Size
    $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
    Write-Output "  $($item.Path)  ($sizeStr)"
    $files = Get-ChildItem -Path $item.Path -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in ($files | Sort-Object FullName)) {
        $fSizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
        Write-Output "    $($f.FullName)  ($fSizeStr)"
    }
}
Write-Output ""
Write-Output ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-Output ""

if ($Force) {
    Write-Output "Force mode enabled -- skipping confirmation."
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
        # Belt-and-suspenders: make sure libvirt didn't pick up the domain
        # between the initial scan and the actual delete. `virsh dominfo`
        # exits non-zero when the domain is unknown -- that's the only
        # case where the directory is truly orphaned.
        $null = & virsh --connect $virshUri dominfo $item.Name 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Warning "  Skipped: $($item.Path) -- domain '$($item.Name)' is registered with libvirt. Remove it first."
            $errors++
            continue
        }
        Remove-Item -Path $item.Path -Recurse -Force -ErrorAction Stop
        Write-Output "  Deleted: $($item.Path)"
    } catch {
        Write-Warning "  Failed to delete: $($item.Path) - $_"
        $errors++
    }
}

Write-Output ""
if ($errors -eq 0) {
    Write-Output "Cleanup complete. All orphaned directories deleted."
} else {
    Write-Output "Cleanup complete with $errors error(s). Some items could not be deleted."
}
