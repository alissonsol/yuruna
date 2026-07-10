<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f2a3b4-c5d6-4e78-f901-2a3b4c5d6e79
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
    Creates a UTM VM and restores the macOS 26 IPSW into it (Apple
    Virtualization backend).

.DESCRIPTION
    macOS-on-macOS guests are only supported by the Apple
    Virtualization framework. The pipeline is:

      1. Verify the host: macOS 15+, Apple M4+, UTM 4.6+, Xcode CLT
         (swift on PATH for the embedded VZ helper).
      2. Allocate the UTM bundle layout (Data/disk.img, Data/aux.img,
         config.plist).
      3. Drive `VZMacOSInstaller.install` from an embedded Swift helper:
         load the IPSW, pick the most-featureful supported configuration,
         generate a fresh `VZMacMachineIdentifier`, create a
         `VZMacAuxiliaryStorage` next to a raw disk, restore the IPSW
         into the disk.
      4. Emit the hardware-model + machine-identifier base64 blobs so we
         can patch the UTM `MacPlatform` section of the bundle's plist.
      5. Validate the plist with plutil.

    macOS has no cloud-init equivalent, so first boot lands at Setup
    Assistant -- the test sequence side of this guest is TBD. The script
    intentionally stops short of starting the VM; the operator double-
    clicks the bundle in Finder when ready.

.PARAMETER VMName
    Name of the VM bundle under ~/yuruna/guest.nosync/. Defaults to
    "macos-26-01" so a Get-TestVMName-derived name from the runner
    ("test-macos-26-01") slots in cleanly.
.PARAMETER CpuCount
    vCPU count exposed to the guest. When omitted (or set to 0),
    defaults to the yuruna VM core-count policy:
    max(4, floor(hostCores / 2)). See
    https://yuruna.link/definition#defining-the-vm-core-count-policy
.PARAMETER MemoryMb
    Guest RAM in MiB. Defaults to 8192.
.PARAMETER DiskSizeGb
    Sparse disk image size in GiB. Defaults to 128. The IPSW restore
    consumes ~25 GB so anything below 64 GB risks running out of room
    on a first system update.
#>

param(
    [string]$VMName = "macos-26-01",
    [int]$CpuCount = 0,
    [int]$MemoryMb = 8192,
    [int]$DiskSizeGb = 128
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsMacOS) {
    Write-Error "New-VM.ps1 for guest.macos.26 only runs on macOS (Apple Virtualization required)."
    exit 1
}

# --- REGION: https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($CpuCount -eq 0) {
    $CpuCount = [math]::Max(4, [math]::Floor($hostCores / 2))
}
if ($hostCores -lt 4 -or $CpuCount -lt 4) {
    Write-Error "Host has $hostCores physical cores, -CpuCount=$CpuCount; Yuruna requires at least 4 cores on the host AND at least 4 vCPU assigned. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuestDir    = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir      = "$GuestDir/$VMName.utm"
$DataDir     = "$UtmDir/Data"
$downloadDir = "$HOME/yuruna/image/macos.env"

# --- REGION: Environment checks

# macOS 15+ host. VZ's macOS-guest surface is moving fast (new
# VZMacOSInstaller flags every release); pinning to 15 keeps this
# script aligned with the same API the IPSW it just restored expects
# back at runtime.
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor   = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 15) {
    Write-Error "macOS 15 Sequoia or later is required to host a macOS 26 guest (found macOS $macosVersion)."
    exit 1
}
Write-Verbose "Host macOS version: $macosVersion (OK)"

# Apple M4+ -- yuruna pins to M4 across the macos.utm guest set so the
# chip floor is uniform with the nested-virt-requiring Linux guests.
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error "Could not detect Apple Silicon chip. macOS 26 guests require Apple M4 or later."
    exit 1
}
if ($chipName -notmatch 'Apple M([4-9]|[1-9]\d)') {
    Write-Error "Apple Silicon M4 or later is required for guest.macos.26 (found: $chipName)."
    Write-Error "M1/M2/M3 hosts are not supported for this guest."
    exit 1
}
Write-Verbose "Host chip: $chipName (OK)"

# UTM 4.6+ for ConfigurationVersion 4 + macOS Apple backend.
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    $utmMinor = $utmParts.Count -gt 1 ? [int]$utmParts[1] : 0
    if ($utmMajor -lt 4 -or ($utmMajor -eq 4 -and $utmMinor -lt 6)) {
        Write-Error "UTM v4.6.0 or later is required for guest.macos.26 (found v$utmVersion)."
        Write-Error "Update with: brew upgrade --cask utm"
        exit 1
    }
    Write-Verbose "UTM version: $utmVersion (OK)"
} else {
    Write-Warning "Could not determine UTM version. Ensure UTM v4.6.0 or later is installed."
}

# Swift on PATH -- the embedded VZ helper needs it. Xcode CLT is the
# usual provider on a yuruna host (Set-MacHostConditionSet already
# leans on it for EFI variable store creation).
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    Write-Error "swift not found on PATH. Install Xcode command line tools: xcode-select --install"
    exit 1
}

Write-Verbose "All host prerequisites met."
Write-Output ""

# --- REGION: Seek the base IPSW
# Auto-run Get-Image.ps1 once if the base IPSW is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.macos.utm.guest.macos.26"
$baseImageFile = Join-Path $downloadDir "$baseImageName.ipsw"
if (-not (Test-Path $baseImageFile)) {
    $getImageScript = Join-Path $PSScriptRoot 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Base IPSW missing: $baseImageFile"
        Write-Output "Auto-running $getImageScript to fetch it..."
        & pwsh -NoProfile -File $getImageScript
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $LASTEXITCODE. Cannot create VM."
            exit 1
        }
    }
    if (-not (Test-Path $baseImageFile)) {
        Write-Error "Base IPSW not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

Write-Verbose "Creating VM '$VMName' from IPSW: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
$RepoRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Build the UTM bundle skeleton
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) "modules/Yuruna.Host.psm1") -Force
Import-Module (Join-Path $RepoRoot "test/modules/Test.VMUtility.psm1") -Force -DisableNameChecking

if (-not (Remove-UtmBundleWithRetry -Path $UtmDir)) {
    Write-Error "Could not remove existing UTM bundle at '$UtmDir' after retries. Aborting."
    exit 1
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$DiskImage = Join-Path $DataDir 'disk.img'
$AuxImage  = Join-Path $DataDir 'aux.img'
$IdsOut    = Join-Path $DataDir 'mac-platform.txt'

# --- REGION: Drive VZMacOSInstaller via an embedded Swift helper
#
# The helper:
#   1. Loads the IPSW (VZMacOSRestoreImage.load(from:)).
#   2. Picks `mostFeaturefulSupportedConfiguration` (the maximally-
#      capable hardwareModel for THIS host bucket -- VZ rejects an
#      install if you request a hardwareModel the host can't run).
#   3. Sanity-checks the host's CPU/memory request against
#      configuration.minimumSupportedCPUCount / minimumSupportedMemorySize.
#   4. Creates a fresh VZMacMachineIdentifier.
#   5. Creates VZMacAuxiliaryStorage at aux.img.
#   6. Creates a sparse raw disk at disk.img (via Foundation's truncate).
#   7. Builds a minimal VZVirtualMachineConfiguration -- just the bits
#      the installer needs (graphics/network are deferred to UTM at
#      runtime via the config.plist we'll generate after restore).
#   8. Restores the IPSW with VZMacOSInstaller.install and prints
#      progress to stderr every few percent.
#   9. Emits "MAC_PLATFORM<TAB>{hardwareModel-base64}<TAB>{machineId-base64}"
#      so PowerShell can stuff those into the UTM plist.
#
# `defer { sema.signal() }` patterns keep the wait deterministic in
# every code path; an unhandled crash inside the install handler would
# otherwise hang forever.
$swiftSrc = @"
import Foundation
import Virtualization

guard CommandLine.arguments.count >= 6 else {
    FileHandle.standardError.write(Data("Error: usage: <ipsw-path> <disk-path> <aux-path> <cpu-count> <memory-mb> <disk-size-gb>\n".utf8))
    exit(1)
}
let ipswPath   = CommandLine.arguments[1]
let diskPath   = CommandLine.arguments[2]
let auxPath    = CommandLine.arguments[3]
guard let cpuCount   = Int(CommandLine.arguments[4]),
      let memoryMb   = UInt64(CommandLine.arguments[5]),
      let diskSizeGb = UInt64(CommandLine.arguments[6]) else {
    FileHandle.standardError.write(Data("Error: cpu-count, memory-mb, disk-size-gb must be integers\n".utf8))
    exit(1)
}

func die(_ s: String) -> Never {
    FileHandle.standardError.write(Data("Error: \(s)\n".utf8))
    exit(1)
}

// ---- 1. Load IPSW ---------------------------------------------------------
let loadSema = DispatchSemaphore(value: 0)
var restoreImage: VZMacOSRestoreImage?
var loadError: String?
VZMacOSRestoreImage.load(from: URL(fileURLWithPath: ipswPath)) { result in
    defer { loadSema.signal() }
    switch result {
    case .success(let img): restoreImage = img
    case .failure(let err): loadError = err.localizedDescription
    }
}
loadSema.wait()
if let e = loadError { die("VZMacOSRestoreImage.load: \(e)") }
guard let img = restoreImage else { die("VZMacOSRestoreImage.load returned no image") }

guard let mostFeatureful = img.mostFeaturefulSupportedConfiguration else {
    die("This host cannot run the IPSW. VZMacOSConfigurationRequirements.mostFeaturefulSupportedConfiguration was nil.")
}
let hardwareModel = mostFeatureful.hardwareModel
if !hardwareModel.isSupported {
    die("Resolved hardwareModel is not supported by this host. Requires a newer macOS host or different chip.")
}

// ---- 2. Resource sanity checks -------------------------------------------
if cpuCount < mostFeatureful.minimumSupportedCPUCount {
    die("Requested CPU count \(cpuCount) below minimum \(mostFeatureful.minimumSupportedCPUCount) for this IPSW.")
}
let memBytes = memoryMb * 1024 * 1024
if memBytes < mostFeatureful.minimumSupportedMemorySize {
    die("Requested memory \(memoryMb)MB below minimum \(mostFeatureful.minimumSupportedMemorySize / (1024*1024))MB for this IPSW.")
}

// ---- 3. Aux storage ------------------------------------------------------
try? FileManager.default.removeItem(atPath: auxPath)
do {
    _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: URL(fileURLWithPath: auxPath),
        hardwareModel: hardwareModel,
        options: [])
} catch {
    die("VZMacAuxiliaryStorage: \(error.localizedDescription)")
}

// ---- 4. Disk image -------------------------------------------------------
try? FileManager.default.removeItem(atPath: diskPath)
FileManager.default.createFile(atPath: diskPath, contents: nil)
do {
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: diskPath))
    try handle.truncate(atOffset: diskSizeGb * 1024 * 1024 * 1024)
    try handle.close()
} catch {
    die("disk truncate(\(diskSizeGb)GB): \(error.localizedDescription)")
}

// ---- 5. Machine identifier (fresh, unique per VM) ------------------------
let machineId = VZMacMachineIdentifier()

// ---- 6. VM configuration --------------------------------------------------
let platform = VZMacPlatformConfiguration()
platform.hardwareModel = hardwareModel
platform.machineIdentifier = machineId
// VZMacAuxiliaryStorage(contentsOf:) is non-throwing -- it just opens a
// reference to the file created above; no `try` / catch needed.
platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: URL(fileURLWithPath: auxPath))

let bootloader = VZMacOSBootLoader()
let cfg = VZVirtualMachineConfiguration()
cfg.platform = platform
cfg.bootLoader = bootloader
cfg.cpuCount = cpuCount
cfg.memorySize = memBytes

let diskAttach: VZDiskImageStorageDeviceAttachment
do {
    diskAttach = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: diskPath), readOnly: false)
} catch {
    die("VZDiskImageStorageDeviceAttachment: \(error.localizedDescription)")
}
cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttach)]

do {
    try cfg.validate()
} catch {
    die("VZVirtualMachineConfiguration.validate: \(error.localizedDescription)")
}

let vm = VZVirtualMachine(configuration: cfg)

// ---- 7. Run the installer ------------------------------------------------
//
// `vm` was created with VZVirtualMachine(configuration:) and no explicit
// queue, so it is bound to the MAIN dispatch queue. VZMacOSInstaller
// delivers BOTH its progress KVO updates and its completion handler on
// that queue. Blocking the main thread here (e.g. `sema.wait()`) would
// stall the main queue and deadlock the install before it writes a
// single byte -- the completion handler could never run. Instead we hand
// the thread to dispatchMain() and let the completion handler exit the
// process.
let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: URL(fileURLWithPath: ipswPath))

let progress = installer.progress
let observer = progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
    let pct = Int(p.fractionCompleted * 100)
    FileHandle.standardError.write(Data("Restore progress: \(pct)%\n".utf8))
}

installer.install { result in
    observer.invalidate()
    switch result {
    case .success:
        // ---- 8. Emit MacPlatform identifiers -----------------------------
        let hwB64 = hardwareModel.dataRepresentation.base64EncodedString()
        let idB64 = machineId.dataRepresentation.base64EncodedString()
        print("MAC_PLATFORM\t\(hwB64)\t\(idB64)")
        exit(0)
    case .failure(let err):
        die("VZMacOSInstaller.install: \(err.localizedDescription)")
    }
}

// Service the main dispatch queue so the installer's callbacks can fire.
// Never returns -- the completion handler above calls exit().
dispatchMain()
"@

Write-Output "Restoring IPSW into UTM bundle (this can take 15-25 min)..."
# VZMacOSInstaller only reaches the system installation service when the
# helper binary carries the com.apple.security.virtualization entitlement;
# Invoke-EntitledSwift compiles + self-signs it before running. The helper
# prints "Restore progress: N%" to stderr every few percent; -LineHandler
# routes those into a PowerShell progress bar live, and the merged output
# is still returned so we can recover the final MAC_PLATFORM tuple.
$restoreActivity = "Restoring macOS 26 IPSW into '$VMName'"
$onRestoreLine = {
    param([string]$Line)
    if ($Line -match 'Restore progress:\s*(\d+)\s*%') {
        $pct = [math]::Min(100, [int]$Matches[1])
        Write-Progress -Activity $restoreActivity -Status "$pct% complete" -PercentComplete $pct
    } else {
        # Non-progress lines (e.g. a die() "Error: ..." on failure) -- keep
        # them out of the progress bar; they also come back in $installerOut.
        Write-Verbose $Line
    }
}
$installerOut = Invoke-EntitledSwift -Source $swiftSrc -LineHandler $onRestoreLine -ArgumentList @(
    $baseImageFile, $DiskImage, $AuxImage, "$CpuCount", "$MemoryMb", "$DiskSizeGb")
Write-Progress -Activity $restoreActivity -Completed
if ($LASTEXITCODE -ne 0) {
    Write-Error ("IPSW restore failed: " + ($installerOut -join "`n"))
    exit 1
}

# Echo progress + the final tuple line into the transcript.
foreach ($line in $installerOut) { Write-Verbose $line }

$tupleLine = ($installerOut -split "`n" |
    Where-Object { $_ -match '^MAC_PLATFORM\b' } |
    Select-Object -Last 1)
if (-not $tupleLine) {
    Write-Error "Swift helper did not emit MAC_PLATFORM line. Stdout/stderr was:`n$($installerOut -join "`n")"
    exit 1
}
$tupleFields = $tupleLine -split "`t"
if ($tupleFields.Count -lt 3) {
    Write-Error "MAC_PLATFORM line malformed (need 3 tab-separated fields): $tupleLine"
    exit 1
}
$HardwareModelB64     = $tupleFields[1].Trim()
$MachineIdentifierB64 = $tupleFields[2].Trim()
Write-Verbose "hardwareModel (base64): $HardwareModelB64"
Write-Verbose "machineIdentifier (base64): $MachineIdentifierB64"

# Record the resolved hardware-model / machine-id pair next to the
# bundle so re-runs of the script (or operators inspecting the bundle)
# can correlate the binary blobs with the human-readable identifiers
# stored in the plist.
Set-Content -Path $IdsOut -Value @(
    "hardwareModel.base64=$HardwareModelB64",
    "machineIdentifier.base64=$MachineIdentifierB64"
)

# --- REGION: config.plist (Apple Virtualization backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',             $VMName `
    -replace '__VM_UUID__',             $VmUuid `
    -replace '__MAC_ADDRESS__',         $MacAddress `
    -replace '__DISK_IDENTIFIER__',     $DiskId `
    -replace '__DISK_IMAGE_NAME__',     'disk.img' `
    -replace '__HARDWARE_MODEL__',      $HardwareModelB64 `
    -replace '__MACHINE_IDENTIFIER__',  $MachineIdentifierB64 `
    -replace '__CPU_COUNT__',           "$CpuCount" `
    -replace '__MEMORY_SIZE__',         "$MemoryMb"

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

# Validate the generated plist is well-formed -- catches a stray
# unsubstituted __TOKEN__ before UTM does at open time.
$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK."

Write-Output ""
Write-Output "== VM bundle created: $UtmDir =="
Write-Output ""

# Reveal the freshly-built bundle in Finder, with '$VMName.utm' selected,
# so the operator can double-click it straight away instead of navigating
# to ~/yuruna/guest.nosync/ by hand.
& open -R $UtmDir
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not open Finder at '$UtmDir' (open exited $LASTEXITCODE). Navigate there manually."
}

Write-Output "Next steps:"
Write-Output "  1. A Finder window has opened with '$VMName.utm' selected."
Write-Output "     Double-click it to import the VM into UTM."
Write-Output "  2. Start the VM. macOS 26 first-boot lands at Setup Assistant"
Write-Output "     (region, keyboard, Wi-Fi, Apple ID, account). Walk through"
Write-Output "     it manually -- there is no autoinstall equivalent yet."
Write-Output "  3. After Setup Assistant completes the test harness can drive"
Write-Output "     the guest via the shared GUI/SSH sequences once those land"
Write-Output "     under test/sequences/gui/start.guest.macos.26.yml."
