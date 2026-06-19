<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42a8d3f2-e5b6-4c71-9a04-2f3d4e5a6b7c
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

# === Warning ===
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage "  WARNING: DESTRUCTIVE OPERATION"
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""
Write-CleanupMessage "  This script deletes UTM VM bundles (.utm) from ~/Desktop"
Write-CleanupMessage "  that are NOT registered in UTM."
Write-CleanupMessage ""
Write-CleanupMessage "  THIS CANNOT BE UNDONE."
Write-CleanupMessage ""
Write-CleanupMessage "================================================================"
Write-CleanupMessage ""

# Base image filenames follow the legacy convention "host.<short>.guest.<name>"
# (e.g. host.macos.utm.guest.amazon.linux.2023.qcow2). Resolve-BaseImageName
# walks guest.* subfolders and reconstructs the prefix every Get-Image.ps1 /
# New-VM.ps1 writes.
$nameInfo       = Resolve-BaseImageName -HostScriptDir $ScriptDir
$hostFolder     = $nameInfo.HostFolder
$baseImageNames = $nameInfo.BaseImageNames

if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
    Write-Error "utmctl not found. Ensure UTM is installed and utmctl is in your PATH."
    Write-Error "UTM.app ships utmctl at: /Applications/UTM.app/Contents/MacOS/utmctl"
    exit 1
}

# === Scan for VM bundles ===
$scanPath = "$HOME/yuruna/guest.nosync"
if (-not (Test-Path $scanPath)) {
    Write-CleanupMessage "No yuruna/guest.nosync folder found at '$scanPath'. Nothing to scan."
    exit 0
}

$utmOutput = & utmctl list 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
    exit 1
}

# utmctl exits 0 even when Apple Events are denied (typical from SSH,
# launchd, or any non-Automation-entitled host process). It just emits
# the error to stderr and prints the header with zero data rows. This
# script then would treat EVERY bundle as orphaned and -- with -Force --
# delete them all even though UTM still has the VMs registered. Bail
# loudly instead so the operator can launch from a Terminal session
# with Automation -> System Events access.
$utmText = ($utmOutput | ForEach-Object { "$_" }) -join "`n"
if ($utmText -match 'OSStatus error -1743|utmctl does not work from SSH') {
    Write-Error @"
utmctl could not reach UTM (Apple Events permission denied):
$utmText

Refusing to proceed -- a permission-denied utmctl would mis-classify
every registered VM as orphaned and -Force would delete the bundles.
Run from a Terminal/iTerm session (NOT SSH), after UTM.app is launched
and a user is logged in graphically. If prompted, grant pwsh access in
System Settings -> Privacy & Security -> Automation -> pwsh -> UTM.
"@
    exit 1
}

# --- See https://yuruna.link/memory#why-utmctl-list-needs-a-uuid-anchored-parser
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
# without this, a stopped service VM (e.g. caching-proxy) is misclassified
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

Write-CleanupMessage "UTM registered VMs: $($registeredVMs.Count)"
Write-CleanupMessage ""

$utmBundles = Get-ChildItem -Path $scanPath -Directory -Filter "*.utm" -ErrorAction SilentlyContinue
$bundleMap = @{}
foreach ($bundle in $utmBundles) {
    $vmName = $bundle.Name -replace '\.utm$', ''
    $bundleMap[$vmName] = $bundle.FullName
}

# === List registered VMs and their associated files ===
if ($registeredVMs.Count -gt 0) {
    Write-CleanupMessage "Currently registered VMs and their associated Desktop files:"
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
        Write-CleanupMessage "    (no bundle found on Desktop)"
    }
    Write-CleanupMessage ""
}

# === Identify orphaned bundles (excluding base images) ===
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

# === List protected base images ===
if ($protectedItems.Count -gt 0) {
    Write-CleanupMessage "The following base images are KEPT (not associated with a registered VM, but needed as base images):"
    Write-CleanupMessage ""
    foreach ($item in $protectedItems) {
        $sizeStr = "{0:N2} GB" -f ($item.Size / 1GB)
        Write-CleanupMessage "  $($item.Path)  ($sizeStr)"
        $guestName = ($item.Name -replace "^$([regex]::Escape($hostFolder))\.", '')
        Write-CleanupMessage "    Reason: base image for $($guestName). Update by rerunning Get-Image.ps1 in $($guestName)/"
    }
    Write-CleanupMessage ""
}

# === Delete orphaned bundles ===
if ($orphanedItems.Count -eq 0) {
    Write-CleanupMessage "No orphaned VM bundles found. Nothing to clean up."
    exit 0
}

Write-CleanupMessage "The following .utm bundles are NOT associated with any registered UTM VM:"
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
        # Verify no longer registered before removing files.
        $stillRegistered = $false
        if ($bundleUUID) {
            $null = & utmctl status $bundleUUID 2>&1
            if ($LASTEXITCODE -eq 0) { $stillRegistered = $true }
        }
        if ($stillRegistered) {
            Write-Warning "  Skipped: $($item.Path) -- VM still registered in UTM. Remove it from UTM first."
            $errors++
            continue
        }
        Remove-Item -Path $item.Path -Recurse -Force
        Write-CleanupMessage "  Deleted: $($item.Path)"
    } catch {
        Write-Warning "  Failed to delete: $($item.Path) - $_"
        $errors++
    }
}

# === Cleanup result ===
Write-CleanupMessage ""
if ($errors -eq 0) {
    Write-CleanupMessage "Cleanup complete. All orphaned bundles deleted."
} else {
    Write-CleanupMessage "Cleanup complete with $errors error(s). Some items could not be deleted."
}
