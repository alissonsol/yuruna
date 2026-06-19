<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e98
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
        [switch]$Force,
    # Quiet mode: suppress every Write-CleanupMessage (host paths, per-VM file
    # listings, base-image keep-list, "Deleted: <file>" trail) so the
    # automated cycle-start sweep (Remove-TestVMFiles.ps1 -Quiet) emits
    # nothing from this script. Write-Warning / Write-Error remain
    # visible because they always represent an actual problem. Direct
    # invocation (no -Quiet) prints the full log.
    [switch]$Quiet
)

# Write-CleanupMessage lives in host/modules/Yuruna.VMCleanup.psm1 so
# all three Remove-OrphanedVMFiles.ps1 scripts share one routing path
# (per-copy implementations drift on the quiet flag -- this script
# references $Quiet directly where the other two reference
# $script:QuietOutput).
$_repoRoot      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$_vmCleanupMod  = Join-Path $_repoRoot 'host/modules/Yuruna.VMCleanup.psm1'
Import-Module -Name $_vmCleanupMod -Force
Set-VMCleanupQuiet -Quiet $Quiet.IsPresent

# Auto-relaunch under sg libvirt when this shell's running supplementary
# group set lacks libvirt. The virsh call at "Enumerate registered
# libvirt domains" below talks directly to /var/run/libvirt/libvirt-sock
# (no sudo), so a stale-group shell fails with "Permission denied".
# Helper lives in test/modules/Test.HostContract.psm1 (sibling tree); resolve it
# relative to this script's location since the host driver and the test
# harness don't share a CWD assumption.
$_testHost   = Join-Path $_repoRoot 'test/modules/Test.HostContract.psm1'
if (Test-Path $_testHost) {
    Import-Module $_testHost -Force
    Invoke-LibvirtGroupReExecIfNeeded -HostType (Get-HostType) -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
}

# === Warning ===
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage "  WARNING: DESTRUCTIVE OPERATION"
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""
Write-CleanupMessage "  This script deletes VM directories under ~/yuruna/vms/"
Write-CleanupMessage "  that are NOT registered with libvirt."
Write-CleanupMessage ""
Write-CleanupMessage "  THIS CANNOT BE UNDONE."
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""

$vmRoot = Join-Path $HOME 'yuruna/vms'
if (-not (Test-Path -LiteralPath $vmRoot)) {
    Write-CleanupMessage "No VM directory at '$vmRoot'. Nothing to scan."
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

Write-CleanupMessage "libvirt registered VMs: $($registered.Count)"
Write-CleanupMessage ""

if ($registered.Count -gt 0) {
    Write-CleanupMessage "Currently registered VMs and their on-disk artifacts:"
    Write-CleanupMessage ""
    foreach ($vmName in ($registered.Keys | Sort-Object)) {
        $vmDir = Join-Path $vmRoot $vmName
        Write-CleanupMessage "  $vmName"
        if (Test-Path -LiteralPath $vmDir) {
            $files = Get-ChildItem -Path $vmDir -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in ($files | Sort-Object FullName)) {
                $sizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
                Write-CleanupMessage "    $($f.FullName)  ($sizeStr)"
            }
        } else {
            Write-CleanupMessage "    (no artifact directory under $vmRoot)"
        }
        Write-CleanupMessage ""
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
    Write-CleanupMessage "No orphaned VM directories found. Nothing to clean up."
    exit 0
}

Write-CleanupMessage "The following directories are NOT associated with any registered libvirt domain:"
Write-CleanupMessage ""
$totalSize = [int64]0
foreach ($item in $orphanedItems) {
    $totalSize += [int64]$item.Size
    $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
    Write-CleanupMessage "  $($item.Path)  ($sizeStr)"
    $files = Get-ChildItem -Path $item.Path -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in ($files | Sort-Object FullName)) {
        $fSizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
        Write-CleanupMessage "    $($f.FullName)  ($fSizeStr)"
    }
}
Write-CleanupMessage ""
Write-CleanupMessage ("Total size to be freed: {0:N2} GB" -f ($totalSize / 1GB))
Write-CleanupMessage ""

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
        Write-CleanupMessage "  Deleted: $($item.Path)"
    } catch {
        Write-Warning "  Failed to delete: $($item.Path) - $_"
        $errors++
    }
}

Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage "Cleanup complete. All orphaned directories deleted."
} else {
    Write-CleanupMessage "Cleanup complete with $errors error(s). Some items could not be deleted."
}
