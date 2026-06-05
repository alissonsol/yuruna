<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42c0d1e2-f3a4-4b67-c890-1d2e3f4a5b68
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
    [string]$VMName = "windows11-01",
    # Shared = UTM NAT (default). Use Bridged when the Mac host runs a VPN.
    [ValidateSet("Shared", "Bridged")]
    [string]$NetworkMode = "Shared",
    # Physical interface to bridge to (e.g. en0, en1). Auto-detected when empty.
    [string]$BridgeInterface = ""
)

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$GuestDir = "$HOME/yuruna/guest.nosync"
New-Item -ItemType Directory -Force -Path $GuestDir | Out-Null
$UtmDir = "$GuestDir/$VMName.utm"
$DataDir = "$UtmDir/Data"
$downloadDir = "$HOME/yuruna/image/windows.env"

# ===== Environment checks =====

# Check macOS version (requires macOS 12 Monterey or later)
$macosVersion = & sw_vers -productVersion 2>$null
$macosMajor = [int]($macosVersion -split '\.')[0]
if ($macosMajor -lt 12) {
    Write-Error "macOS 12 Monterey or later is required (found macOS $macosVersion)."
    exit 1
}
Write-Verbose "macOS version: $macosVersion (OK)"

# Check Apple Silicon chip (requires M1 or later)
$chipName = (& system_profiler SPHardwareDataType 2>$null | Select-String "Chip" | ForEach-Object { $_ -replace '.*Chip:\s*', '' }).Trim()
if (-not $chipName) {
    Write-Error "Could not detect Apple Silicon chip. This script requires Apple Silicon (M1 or later)."
    exit 1
}
if ($chipName -notmatch 'Apple M\d') {
    Write-Error "Apple Silicon is required for Windows 11 ARM64 virtualization (found: $chipName)."
    exit 1
}
Write-Verbose "Chip: $chipName (OK)"

# Check UTM version (requires v4.0.0 or later for ConfigurationVersion 4 / QEMU backend)
$utmPlist = "/Applications/UTM.app/Contents/Info.plist"
if (-not (Test-Path $utmPlist)) {
    Write-Error "UTM not found at /Applications/UTM.app. Install with: brew install --cask utm"
    exit 1
}
$utmVersion = (& /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $utmPlist 2>$null)
if ($utmVersion) {
    $utmParts = $utmVersion -split '\.'
    $utmMajor = [int]$utmParts[0]
    if ($utmMajor -lt 4) {
        Write-Error "UTM v4.0.0 or later is required (found v$utmVersion)."
        Write-Error "Update with: brew upgrade --cask utm"
        exit 1
    }
    Write-Verbose "UTM version: $utmVersion (OK)"
} else {
    Write-Warning "Could not determine UTM version. Ensure UTM v4.0.0 or later is installed."
}

Write-Verbose "All requirements met."

# === Resolve network interface for Bridged mode ===
if ($NetworkMode -eq "Bridged") {
    if (-not $BridgeInterface) {
        $routeOut = & route get default 2>/dev/null
        $BridgeInterface = ($routeOut | Select-String 'interface:' |
            ForEach-Object { ($_ -split ':\s*', 2)[1] }).Trim()
        if (-not $BridgeInterface) {
            Write-Error "Could not auto-detect the default network interface."
            Write-Error "Specify it explicitly: -BridgeInterface en0"
            exit 1
        }
    }
    Write-Verbose "Network mode: Bridged (interface: $BridgeInterface)"
} else {
    Write-Verbose "Network mode: Shared (NAT)"
}
Write-Output ""

# === Seek the base image ===
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward. The Win11 ISO has
# no machine-fetchable URL -- the per-guest Get-Image.ps1 prints manual-
# download instructions in that case, exits non-zero, and the recheck
# below surfaces the actionable next step.
$baseImageName = "host.macos.utm.guest.windows.11"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (-not (Test-Path $baseImageFile)) {
    $getImageScript = Join-Path $PSScriptRoot 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Base image missing: $baseImageFile"
        Write-Output "Auto-running $getImageScript to fetch it..."
        & pwsh -NoProfile -File $getImageScript
        $getImageExit = $LASTEXITCODE
        if ($getImageExit -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $getImageExit. Cannot create VM."
            exit 1
        }
    }
    if (-not (Test-Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually and follow its instructions."
        exit 1
    }
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for operators reading the transcript. Emits
# "Provenance: <url>" when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# === Check UTM Guest Tools ISO exists (needed after installation, not during) ===
$spiceImageName = "host.macos.utm.guest.windows.11.spice.iso"
$spiceImageFile = Join-Path $downloadDir $spiceImageName
if (-not (Test-Path $spiceImageFile)) {
    Write-Warning "UTM Guest Tools ISO not found at '$spiceImageFile'. Run Get-Image.ps1 to download it."
    Write-Warning "You will need it after Windows installation to enable virtio-net-pci networking."
}

# === Create copies and files for VM ===

if (Test-Path -LiteralPath $UtmDir) { Remove-Item -LiteralPath $UtmDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# Copy base image ISO into the bundle (named after VM name)
$DestIso = "$DataDir/$VMName.iso"
Copy-Item -Path $baseImageFile -Destination $DestIso
Write-Verbose "Copied installer ISO as: $VMName.iso"

# Create blank disk for installation (512GB, qcow2 format for QEMU backend)
$DiskImage = "$DataDir/disk.qcow2"
Write-Verbose "Creating 512GB disk image (qcow2 format for QEMU backend)..."
& qemu-img create -f qcow2 "$DiskImage" 512G 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "qemu-img failed. Install QEMU tools with: brew install qemu"
    exit 1
}

# Generate autounattend seed ISO (Windows Setup scans all drives for autounattend.xml)
$SeedDir = Join-Path $downloadDir "seed_temp/$VMName"
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

$VmConfigDir = Join-Path $ScriptDir "vmconfig"
$AnswerFileTemplate = Join-Path $VmConfigDir "autounattend.xml"
if (-not (Test-Path $AnswerFileTemplate)) {
    Write-Error "autounattend.xml template not found at '$AnswerFileTemplate'."
    exit 1
}

# Replace placeholders in autounattend.xml
$AnswerFile = (Get-Content -Raw $AnswerFileTemplate) `
    -replace 'COMPUTERNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/autounattend.xml" -Value $AnswerFile -NoNewline

$SeedIso = "$DataDir/seed.iso"
Write-Verbose "Generating seed.iso with autounattend configuration..."
# OEMDRV volume label causes Windows Setup to automatically pick up autounattend.xml
& hdiutil makehybrid -o "$SeedIso" -joliet -iso -default-volume-name OEMDRV "$SeedDir" 2>&1 | ForEach-Object { Write-Verbose $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create seed.iso with hdiutil."
    exit 1
}

# Generate UTM config.plist from template (QEMU backend)
$TemplatePath = Join-Path $ScriptDir "config.plist.template"
if (-not (Test-Path $TemplatePath)) {
    Write-Error "Template not found at '$TemplatePath'."
    exit 1
}

# Generate UUIDs and MAC address for this VM
$VmUuid = [guid]::NewGuid().ToString().ToUpper()
$DiskId = [guid]::NewGuid().ToString().ToUpper()
$IsoId = [guid]::NewGuid().ToString().ToUpper()
$SeedId = [guid]::NewGuid().ToString().ToUpper()
$rng = [System.Random]::new()
$MacBytes = [byte[]]::new(6)
$rng.NextBytes($MacBytes)
$MacBytes[0] = ($MacBytes[0] -bor 0x02) -band 0xFE  # locally administered unicast
$MacAddress = ($MacBytes | ForEach-Object { $_.ToString("X2") }) -join ":"

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$PlistContent = (Get-Content -Raw $TemplatePath) `
    -replace '__VM_NAME__',         $VMName `
    -replace '__VM_UUID__',         $VmUuid `
    -replace '__MAC_ADDRESS__',     $MacAddress `
    -replace '__DISK_IDENTIFIER__', $DiskId `
    -replace '__DISK_IMAGE_NAME__', 'disk.qcow2' `
    -replace '__ISO_IDENTIFIER__',  $IsoId `
    -replace '__ISO_IMAGE_NAME__',  "$VMName.iso" `
    -replace '__SEED_IDENTIFIER__', $SeedId `
    -replace '__SEED_IMAGE_NAME__', 'seed.iso' `
    -replace '__CPU_COUNT__',       "$vmCores" `
    -replace '__MEMORY_SIZE__',     '16384'

Set-Content -Path "$UtmDir/config.plist" -Value $PlistContent

$lintOutput = & plutil -lint "$UtmDir/config.plist" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Generated config.plist failed plist validation: $lintOutput"
    Write-Error "Inspect the file at: $UtmDir/config.plist"
    exit 1
}
Write-Verbose "config.plist validated OK."

# Patch network mode to Bridged if requested
if ($NetworkMode -eq "Bridged") {
    & plutil -replace "Network.0.Mode" -string "Bridged" "$UtmDir/config.plist"
    & plutil -insert "Network.0.BridgedInterface" -string $BridgeInterface "$UtmDir/config.plist"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to patch config.plist for Bridged networking."
        exit 1
    }
    Write-Verbose "Network patched to Bridged (interface: $BridgeInterface)."
}

Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Verbose ""
Write-Verbose "== VM bundle created: $UtmDir =="
Write-Verbose ""
Write-Verbose "Network mode : $NetworkMode$(if ($NetworkMode -eq 'Bridged') { " ($BridgeInterface)" })"
Write-Verbose ""
Write-Verbose "Double-click '$VMName.utm' on your Desktop to import it into UTM and start the installation."
Write-Verbose "When the VM first starts, press any key when you see 'Press any key to boot from CD or DVD'."
Write-Verbose "The Windows installer will then run automatically. Default credentials: User / password"
Write-Verbose ""
Write-Verbose "After Windows installation completes (~15 min):"
Write-Verbose "  1. Open UTM settings for this VM (VM must be stopped)."
Write-Verbose "  2. Go to Drives and remove the two installer drives ($VMName.iso and seed.iso)."
Write-Verbose "  3. Still in Drives, add a new USB CD drive and import:"
Write-Verbose "     $spiceImageFile"
Write-Verbose "  4. Start the VM. Open File Explorer and run the UTM Guest Tools installer"
Write-Verbose "     from the CD drive. This installs SPICE and the virtio-net-pci network driver."
Write-Verbose "     Network will be available after the installer reboots the VM."
Write-Verbose "  5. After the reboot, stop the VM, remove the spice CD drive in UTM settings,"
Write-Verbose "     and start the VM normally."
Write-Verbose ""
Write-Verbose "If the VM has no network (or Windows reports a VPN blockage), re-run with:"
Write-Verbose "  pwsh ./New-VM.ps1 -VMName $VMName -NetworkMode Bridged"
