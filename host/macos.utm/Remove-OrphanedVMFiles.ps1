<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42944d84-a340-428d-8b14-0273934cf4fc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos utm cleanup
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
    Delete .utm bundles under ~/yuruna/guest.nosync that are no longer
    registered in UTM.

.DESCRIPTION
    Sibling of host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1 and
    host/windows.hyper-v/Remove-OrphanedVMFiles.ps1. A bundle is orphaned iff
    neither its name nor the UUID in its config.plist is known to utmctl. Base
    images are kept. Refuses to run when utmctl cannot reach UTM, because an
    empty answer there would classify every registered VM as orphaned.

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

# Write-CleanupMessage + base-image discovery live in
# host/modules/Yuruna.VMCleanup.psm1 so a future tweak to the routing
# contract (or a new piece of cleanup state) lands in one place rather
# than three.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module -Name (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.VMCleanup.psm1') -Force
Set-VMCleanupQuiet -Quiet $Quiet.IsPresent

# --- REGION: Warning
Write-CleanupMessage ""
Write-CleanupMessage "========"
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_f3adc201e5fa38f4')
Write-CleanupMessage "========"
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_2c990e0b39de5483')
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d36c28967dd8572f')
Write-CleanupMessage ""
Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_d506f23d4fcc7fa4')
Write-CleanupMessage ""
Write-CleanupMessage "========"
Write-CleanupMessage ""

# Base image filenames follow the legacy convention "host.<short>.guest.<name>"
# (e.g. host.macos.utm.guest.amazon.linux.2023.qcow2). Resolve-BaseImageName
# walks guest.* subfolders and reconstructs the prefix every Get-Image.ps1 /
# New-VM.ps1 writes.
$nameInfo       = Resolve-BaseImageName -HostScriptDir $ScriptDir
$hostFolder     = $nameInfo.HostFolder
$baseImageNames = $nameInfo.BaseImageNames

# --- REGION: Check prerequisites
if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6c671ec7d3b6b0d2')
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1a34f423edf48db4')
    exit 1
}

# --- REGION: Scan for VM artifacts
$scanPath = "$HOME/yuruna/guest.nosync"
if (-not (Test-Path $scanPath)) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_a2880f954215ada2' -Arguments @{ scanPath = "$scanPath" })
    exit 0
}

# --- REGION: Enumerate registered VMs
$utmOutput = & utmctl list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6d45ba53c1de42dd' -Arguments @{ utmOutput = "$utmOutput" })
    exit 1
}

# utmctl exits 0 even when it could not ask UTM anything -- Apple Events
# denied (typical from SSH, launchd, or any non-Automation-entitled host
# process), a request that timed out, or any other Apple Event fault. It
# just emits the error to stderr and prints the header with zero data
# rows. This script would then treat EVERY bundle as orphaned and -- with
# -Force -- delete them all even though UTM still has the VMs registered.
# Bail loudly instead.
#
# Matched on ANY OSStatus code rather than an enumerated few: the set that
# can appear here is open, the cost of missing one is a deleted VM disk,
# and no OSStatus value has "believe the empty list" as its right reading.
$utmText = ($utmOutput | ForEach-Object { "$_" }) -join "`n"
if ($utmText -match 'OSStatus error|couldn.t be completed|utmctl does not work from SSH') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_2bb96dc39812d94e' -Arguments @{ utmText = "$utmText" })
    exit 1
}

# --- REGION: https://yuruna.link/42d69dfa-001d
$registeredVMs = @{}
$registeredUUIDs = @{}
foreach ($line in $utmOutput) {
    $line = "$line".Trim()
    if (-not $line -or $line -match '^-+$') { continue }
    if ($line -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
        $vmUuid   = $matches[1]
        $vmStatus = $matches[2]
        $vmName   = $matches[3].Trim()
        $registeredVMs[$vmName] = $vmStatus
        $registeredUUIDs[$vmUuid] = $vmName
    }
}

# Read VM UUID from a bundle's config.plist. utmctl list may only return
# running VMs; UUID-based `utmctl status` works for stopped VMs too --
# without this, a stopped service VM (e.g. caching-proxy-service) is misclassified
# as orphaned and deleted by the -Force cleanup path.
#
# `plutil -extract Information.UUID raw` (not `-convert json`):
#   * UTM stores the UUID at Information.UUID, not a top-level key.
#   * `-convert json` fails outright on these bundles because config.plist
#     contains a <data> blob (MachineIdentifier) that JSON can't represent
#     -- plutil exits 1 and ConvertFrom-Json throws, which would make the
#     whole function silently return $null and let the orphan check fall
#     through, misclassifying a live VM as orphaned.
function Get-UTMBundleUUID {
    param([string]$BundlePath)
    $configPlist = Join-Path $BundlePath "config.plist"
    if (-not (Test-Path $configPlist)) { return $null }
    $val = & plutil -extract "Information.UUID" raw -o - $configPlist 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $val = "$val".Trim()
    if ($val -match '^[0-9A-Fa-f-]{36}$') { return $val }
    return $null
}

Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_2a896884b1a21323' -Arguments @{ count = "$($registeredVMs.Count)" })
Write-CleanupMessage ""

$utmBundles = Get-ChildItem -Path $scanPath -Directory -Filter "*.utm" -ErrorAction SilentlyContinue
$bundleMap = @{}
foreach ($bundle in $utmBundles) {
    $vmName = $bundle.Name -replace '\.utm$', ''
    $bundleMap[$vmName] = $bundle.FullName
}

# --- REGION: List registered VMs and their associated files
if ($registeredVMs.Count -gt 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_23aa4a8fe6d65a18')
    Write-CleanupMessage ""
}

foreach ($vmName in ($registeredVMs.Keys | Sort-Object)) {
    $vmStatus = $registeredVMs[$vmName]
    Write-CleanupMessage "  $vmName [$vmStatus]"

    if ($bundleMap.ContainsKey($vmName)) {
        $bundlePath = $bundleMap[$vmName]
        $bundleFiles = Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue
        foreach ($f in ($bundleFiles | Sort-Object FullName)) {
            $sizeStr = "{0:N2} MB" -f ($f.Length / 1MB)
            Write-CleanupMessage "    $($f.FullName)  ($sizeStr)"
        }
    } else {
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_a2099ea8e59df16f')
    }
    Write-CleanupMessage ""
}

# --- REGION: Identify orphaned VM artifacts
$orphanedItems = [System.Collections.Generic.List[hashtable]]::new()
$protectedItems = [System.Collections.Generic.List[hashtable]]::new()

foreach ($vmName in $bundleMap.Keys) {
    if ($registeredVMs.ContainsKey($vmName)) { continue }

    $bundlePath = $bundleMap[$vmName]

    # UUID check catches stopped VMs utmctl list may omit by name;
    # `utmctl status <uuid>` exits 0 for any registered VM.
    $bundleUUID = Get-UTMBundleUUID -BundlePath $bundlePath
    if ($bundleUUID) {
        if ($registeredUUIDs.ContainsKey($bundleUUID)) { continue }
        $null = & utmctl status $bundleUUID 2>&1
        if ($LASTEXITCODE -eq 0) { continue }
    }

    $bundleSize = (Get-ChildItem -Path $bundlePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $itemSize = $bundleSize ?? 0

    $isBaseImage = $false
    foreach ($baseImageName in $baseImageNames) {
        if ($vmName -eq $baseImageName) {
            $isBaseImage = $true
            break
        }
    }

    if ($isBaseImage) {
        $protectedItems.Add(@{ Name = $vmName; Path = $bundlePath; Size = $itemSize })
    } else {
        $orphanedItems.Add(@{ Name = $vmName; Path = $bundlePath; Size = $itemSize })
    }
}

# --- REGION: List protected base images
if ($protectedItems.Count -gt 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_fe45a4bdfe18d51e')
    Write-CleanupMessage ""
    foreach ($item in $protectedItems) {
        $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
        Write-CleanupMessage "  $($item.Path)  ($sizeStr)"
        $guestName = ($item.Name -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_a601ce2317e589b6' -Arguments @{ guestName = "$($guestName)" })
    }
    Write-CleanupMessage ""
}

# --- REGION: Delete orphaned VM artifacts
if ($orphanedItems.Count -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_b912b4ce68796c85')
    exit 0
}

Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_17be5c98af6eef11')
Write-CleanupMessage ""
$totalSize = 0
foreach ($item in $orphanedItems) {
    $totalSize += $item.Size
    $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
    Write-CleanupMessage "  $($item.Path)  ($sizeStr)"
    $bundleFiles = Get-ChildItem -Path $item.Path -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in ($bundleFiles | Sort-Object FullName)) {
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
        # Deregister from UTM first (by UUID if available, else by name).
        $bundleUUID = Get-UTMBundleUUID -BundlePath $item.Path
        $deregistered = $false
        if ($bundleUUID) {
            & utmctl delete $bundleUUID 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $deregistered = $true }
        }
        if (-not $deregistered) {
            & utmctl delete $item.Name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $deregistered = $true }
        }
        # Verify no longer registered before removing files. Prefer the UUID
        # (unambiguous); otherwise re-query by NAME, because a name-based
        # `utmctl delete` can silently fail -- and without a probe a UUID-less
        # bundle would be removed while its VM is still registered in UTM,
        # deleting the on-disk state of a live registration.
        $stillRegistered = $false
        $probeTarget = if ($bundleUUID) { $bundleUUID } else { $item.Name }
        $null = & utmctl status $probeTarget 2>&1
        if ($LASTEXITCODE -eq 0) { $stillRegistered = $true }
        if ($stillRegistered) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0f6134c653d7783e' -Arguments @{ path = "$($item.Path)"; probeTarget = "$probeTarget" })
            $errors++
            continue
        }
        Remove-Item -Path $item.Path -Recurse -Force
        Write-CleanupMessage "  Deleted: $($item.Path)"
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_33915575638287d2' -Arguments @{ path = "$($item.Path)"; value = "$_" })
        $errors++
    }
}

# --- REGION: Cleanup result
Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_048665fc498f2dc3')
} else {
    Write-CleanupMessage (Format-YurunaOperatorMessage -Key 'host.operator_42dbc0a404948dc9' -Arguments @{ errors = "$errors" })
}
