<#PSScriptInfo
.VERSION 2026.09.18
.GUID 429b56f1-0d8f-43a6-a6dc-445eb58c952f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host ubuntu kvm cleanup
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

.PARAMETER Quiet
    Suppress the per-directory cleanup log; warnings and errors still print.
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

# Write-CleanupMessage lives in host/modules/Yuruna.VMCleanup.psm1 so
# all three Remove-OrphanedVMFiles.ps1 scripts share one routing path
# and one quiet-flag contract (Set-VMCleanupQuiet) -- a change to how
# -Quiet is honored lands in one place rather than three.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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

# --- REGION: Warning
Write-CleanupMessage ""
Write-CleanupMessage "========"
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_f3adc201e5fa38f4')
Write-CleanupMessage "========"
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_cc667d1ef7c4306b')
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_184c1b1b54f3870b')
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d506f23d4fcc7fa4')
Write-CleanupMessage ""
Write-CleanupMessage "========"
Write-CleanupMessage ""

# --- REGION: Scan for VM artifacts
$vmRoot = Join-Path $HOME 'yuruna/vms'
if (-not (Test-Path -LiteralPath $vmRoot)) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_20ed766361c51090' -Arguments @{ vmRoot = "$vmRoot" })
    exit 0
}

# --- REGION: Check prerequisites
if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6f88583aeb61d648')
    exit 1
}

$virshUri = 'qemu:///system'

# --- REGION: Enumerate registered VMs
$virshOutput = & virsh --connect $virshUri list --all --name 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_477902afa81ff4c0' -Arguments @{ virshOutput = "$virshOutput" })
    exit 1
}
$registered = @{}
foreach ($n in $virshOutput) {
    $name = "$n".Trim()
    if ($name) { $registered[$name] = $true }
}

Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d081eb7e3c3452a0' -Arguments @{ count = "$($registered.Count)" })
Write-CleanupMessage ""

# --- REGION: List registered VMs and their associated files
if ($registered.Count -gt 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_309174d61e003200')
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
            Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_47829d777dc4fff8' -Arguments @{ vmRoot = "$vmRoot" })
        }
        Write-CleanupMessage ""
    }
}

# --- REGION: Identify orphaned VM artifacts
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()
$dirs = @(Get-ChildItem -LiteralPath $vmRoot -Directory -ErrorAction SilentlyContinue)
foreach ($d in $dirs) {
    if ($registered.ContainsKey($d.Name)) { continue }
    $sum = (Get-ChildItem -Path $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $size = if ($null -eq $sum) { 0 } else { [int64]$sum }
    $orphanedItems.Add(@{ Name = $d.Name; Path = $d.FullName; Size = $size })
}

# --- REGION: Delete orphaned VM artifacts
if ($orphanedItems.Count -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_0b8ee65b79a09973')
    exit 0
}

Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_91c56ae74ac1dc10')
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
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_3e2337ab67132732' -FormatValues (($totalSize / 1GB)) -FormatBindings @{ gB = '0:N2' })
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
foreach ($item in $orphanedItems) {
    try {
        # Belt-and-suspenders: make sure libvirt didn't pick up the domain
        # between the initial scan and the actual delete.
        # The not-found signature below is gettext text, so the words have to be
        # pinned or the check never matches on a host in another language --
        # which does not delete anything it should not, but does refuse every
        # cleanup and leaves the operator with a warning per orphan and no way
        # to act on it. LC_ALL is cleared for the call because it outranks
        # LC_MESSAGES.
        $priorAll = $env:LC_ALL
        $priorMessages = $env:LC_MESSAGES
        try {
            $env:LC_ALL = $null
            $env:LC_MESSAGES = 'C'
            $dominfoOutput = & virsh --connect $virshUri dominfo $item.Name 2>&1
            $dominfoExit   = $LASTEXITCODE
        } finally {
            $env:LC_ALL = $priorAll
            $env:LC_MESSAGES = $priorMessages
        }
        if ($dominfoExit -eq 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7a41071119739fdb' -Arguments @{ path = "$($item.Path)"; name = "$($item.Name)" })
            $errors++
            continue
        }
        # Only a genuine "unknown domain" confirms the directory is orphaned. Any OTHER non-zero
        # exit (libvirtd down, socket/permission, transient) must NOT be read as orphaned -- deleting
        # then would destroy a live VM's disk. Require the not-found signature before deleting.
        $dominfoText = ($dominfoOutput | Out-String)
        if ($dominfoText -notmatch 'Domain not found|failed to get domain') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_725ce223025976c2' -Arguments @{ path = "$($item.Path)"; name = "$($item.Name)"; dominfoExit = "${dominfoExit}"; trim = "$($dominfoText.Trim())" })
            $errors++
            continue
        }
        Remove-Item -Path $item.Path -Recurse -Force -ErrorAction Stop
        Write-CleanupMessage "  Deleted: $($item.Path)"
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_33915575638287d2' -Arguments @{ path = "$($item.Path)"; value = "$_" })
        $errors++
    }
}

# --- REGION: Cleanup result
Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_4d6f149ebebc1e87')
} else {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_42dbc0a404948dc9' -Arguments @{ errors = "$errors" })
}
