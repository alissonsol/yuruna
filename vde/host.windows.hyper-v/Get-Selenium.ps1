<#PSScriptInfo
.VERSION 0.1
.GUID 423c8d4e-f5a6-4b89-0c1d-2e3f4a5b6c7d
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# Inform and check for elevation
Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
	Write-Output "Please run this script as Administrator."
	Write-Output "Be careful."
	exit 1
}

# === Configuration ===
# Local folder for the ChromeDriver (relative to this script)
$seleniumDir = Join-Path $PSScriptRoot "selenium"
$driverExe = Join-Path $seleniumDir "chromedriver.exe"

# === Step 1: Selenium PowerShell Module ===
# Only install/update stable releases to avoid type-data conflicts between versions.

# Clean up: if multiple Selenium versions are installed (e.g. a prerelease was installed
# alongside a stable release), remove all and reinstall cleanly. Multiple versions cause
# persistent TypeData conflicts ("The member DefaultDisplayPropertySet is already present").
$allVersions = Get-Module -ListAvailable -Name Selenium
if (($allVersions | Measure-Object).Count -gt 1) {
    Write-Output "Multiple Selenium module versions detected. Cleaning up to fix TypeData conflicts..."
    foreach ($mod in $allVersions) {
        Write-Output "  Removing Selenium $($mod.Version) from $($mod.ModuleBase)..."
        try {
            Uninstall-Module -Name Selenium -RequiredVersion $mod.Version -Force -AllVersions -ErrorAction SilentlyContinue
        } catch {
            # If Uninstall-Module fails, remove the folder directly
            if (Test-Path $mod.ModuleBase) {
                Remove-Item -Path $mod.ModuleBase -Recurse -Force -ErrorAction SilentlyContinue
                Write-Output "  Removed folder: $($mod.ModuleBase)"
            }
        }
    }
    # Clear any cached module state in this session
    Remove-Module -Name Selenium -Force -ErrorAction SilentlyContinue
    $allVersions = Get-Module -ListAvailable -Name Selenium
}

$existingModule = $allVersions | Sort-Object Version -Descending | Select-Object -First 1
if ($existingModule) {
    Write-Output "Selenium module installed: version $($existingModule.Version)"
    Write-Output "Checking for updates..."
    try {
        $latestModule = Find-Module -Name Selenium -ErrorAction Stop
        if ([version]$latestModule.Version -gt $existingModule.Version) {
            Write-Output "Updating Selenium module: $($existingModule.Version) -> $($latestModule.Version)"
            Update-Module -Name Selenium -Force
            Write-Output "Selenium module updated."
        } else {
            Write-Output "Selenium module is up to date."
        }
    } catch {
        Write-Warning "Could not check for Selenium module updates: $_"
    }
} else {
    Write-Output "Installing Selenium PowerShell module..."
    Install-Module -Name Selenium -Force -Scope AllUsers
    Write-Output "Selenium module installed."
}

# Import the module. The Selenium module's internal Add-Type calls produce non-fatal
# errors if the session already has those types loaded (e.g. from a previous import).
# Redirect all error output to suppress these harmless "type already exists" messages.
Remove-Module -Name Selenium -Force -ErrorAction SilentlyContinue
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
Import-Module Selenium 2>$null
$ErrorActionPreference = $savedErrorActionPreference
$moduleLoaded = Get-Module -Name Selenium
if (-not $moduleLoaded) {
    Write-Error "Failed to load Selenium module."
    exit 1
}
Write-Output "Selenium module loaded successfully."

# === Step 2: Detect installed Google Chrome version ===
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chromePath = $null
foreach ($p in $chromePaths) {
    if (Test-Path $p) {
        $chromePath = $p
        break
    }
}
if (-not $chromePath) {
    Write-Error "Google Chrome not found. Chrome is required for Selenium browser automation."
    Write-Output "Expected locations:"
    foreach ($p in $chromePaths) { Write-Output "  $p" }
    exit 1
}

$chromeVersion = (Get-Item $chromePath).VersionInfo.FileVersion
$chromeMajor = ($chromeVersion -split '\.')[0]
Write-Output "Installed Chrome version: $chromeVersion (major: $chromeMajor)"

# === Step 3: Check existing ChromeDriver ===
$needsDriver = $true
if (Test-Path $driverExe) {
    try {
        $driverOutput = & $driverExe --version 2>&1
        # Output format: "ChromeDriver X.Y.Z.W (hash)"
        $driverVersionMatch = [regex]::Match($driverOutput, '(\d+\.\d+\.\d+\.\d+)')
        if ($driverVersionMatch.Success) {
            $driverVersion = $driverVersionMatch.Groups[1].Value
            $driverMajor = ($driverVersion -split '\.')[0]
            Write-Output "Installed ChromeDriver version: $driverVersion (major: $driverMajor)"
            if ($driverMajor -eq $chromeMajor) {
                Write-Output "ChromeDriver major version matches Chrome browser. OK."
                $needsDriver = $false
            } else {
                Write-Output "Major version mismatch: Chrome=$chromeMajor, Driver=$driverMajor. Updating..."
            }
        }
    } catch {
        Write-Output "Could not determine existing driver version. Re-downloading..."
    }
}

# === Step 4: Download ChromeDriver (win64) ===
# Uses the Chrome for Testing JSON endpoints to find the right driver version.
if ($needsDriver) {
    if (!(Test-Path $seleniumDir)) {
        New-Item -ItemType Directory -Path $seleniumDir -Force | Out-Null
    }

    $driverZipFile = Join-Path $seleniumDir "chromedriver-win64.zip"
    $downloaded = $false

    # --- Strategy 1: Chrome for Testing JSON API (preferred) ---
    Write-Output "Strategy 1 - Chrome for Testing JSON API..."
    try {
        $knownVersionsUrl = "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json"
        Write-Output "  Fetching known good versions..."
        $knownVersions = Invoke-RestMethod -Uri $knownVersionsUrl -UseBasicParsing -ErrorAction Stop

        # Find the latest version matching our Chrome major version
        $matchingVersions = $knownVersions.versions |
            Where-Object { ($_.version -split '\.')[0] -eq $chromeMajor } |
            Where-Object { $_.downloads.chromedriver } |
            Sort-Object { [version]$_.version } -Descending

        $bestMatch = $matchingVersions | Select-Object -First 1
        if ($bestMatch) {
            $driverDownload = $bestMatch.downloads.chromedriver | Where-Object { $_.platform -eq "win64" }
            if ($driverDownload) {
                $url = $driverDownload.url
                Write-Output "  Found ChromeDriver $($bestMatch.version) for win64"
                Write-Output "  URL: $url"
                Invoke-WebRequest -Uri $url -OutFile $driverZipFile -UseBasicParsing -ErrorAction Stop
                $downloaded = $true
                Write-Output "  Download succeeded."
            }
        } else {
            Write-Output "  No matching version found for Chrome major $chromeMajor."
        }
    } catch {
        Write-Warning "  Failed: $($_.Exception.Message)"
    }

    # --- Strategy 2: LATEST_RELEASE endpoint ---
    if (-not $downloaded) {
        Write-Output "Strategy 2 - LATEST_RELEASE for major version $chromeMajor..."
        try {
            $latestVersion = (Invoke-WebRequest -Uri "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_$chromeMajor" -UseBasicParsing -ErrorAction Stop).Content.Trim()
            Write-Output "  Found version: $latestVersion"
            $url = "https://storage.googleapis.com/chrome-for-testing-public/$latestVersion/win64/chromedriver-win64.zip"
            Write-Output "  URL: $url"
            Invoke-WebRequest -Uri $url -OutFile $driverZipFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
            Write-Output "  Download succeeded."
        } catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
    }

    # --- Strategy 3: Direct URL with exact Chrome version ---
    if (-not $downloaded) {
        Write-Output "Strategy 3 - direct URL with exact version $chromeVersion..."
        $url = "https://storage.googleapis.com/chrome-for-testing-public/$chromeVersion/win64/chromedriver-win64.zip"
        Write-Output "  URL: $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $driverZipFile -UseBasicParsing -ErrorAction Stop
            $downloaded = $true
            Write-Output "  Download succeeded."
        } catch {
            Write-Warning "  Failed: $($_.Exception.Message)"
        }
    }

    if (-not $downloaded) {
        Write-Error "Could not download ChromeDriver from any source."
        Write-Output "Download it manually from:"
        Write-Output "  https://googlechromelabs.github.io/chrome-for-testing/"
        Write-Output "Place chromedriver.exe in: $seleniumDir"
        exit 1
    }

    # Extract chromedriver.exe from the zip (overwrite existing)
    Write-Output "Extracting chromedriver.exe..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($driverZipFile)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq "chromedriver.exe" }
        if (-not $entry) {
            Write-Error "chromedriver.exe not found inside the downloaded zip."
            exit 1
        }
        $stream = $entry.Open()
        try {
            $outStream = [System.IO.File]::Open($driverExe, [System.IO.FileMode]::Create)
            try {
                $stream.CopyTo($outStream)
            } finally {
                $outStream.Close()
            }
        } finally {
            $stream.Close()
        }
    } finally {
        $zip.Dispose()
    }

    Remove-Item $driverZipFile -Force -ErrorAction SilentlyContinue
    Write-Output "ChromeDriver installed: $driverExe"

    # Verify the downloaded driver
    $verifyOutput = & $driverExe --version 2>&1
    Write-Output "Verified: $verifyOutput"
}

# === Step 5: Add selenium folder to PATH for the current machine ===
# This makes chromedriver.exe available to all future PowerShell sessions.
$machinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
if ($machinePath -split ";" | Where-Object { $_ -eq $seleniumDir }) {
    Write-Output "Selenium folder already in system PATH."
} else {
    Write-Output "Adding selenium folder to system PATH: $seleniumDir"
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$seleniumDir", [EnvironmentVariableTarget]::Machine)
    Write-Output "PATH updated. New PowerShell sessions will find chromedriver.exe automatically."
}

# Also update the current session PATH
if (-not ($env:Path -split ";" | Where-Object { $_ -eq $seleniumDir })) {
    $env:Path = "$env:Path;$seleniumDir"
}

Write-Output ""
Write-Output "=== Setup complete ==="
Write-Output "  Selenium module: $((Get-Module -ListAvailable -Name Selenium | Sort-Object Version -Descending | Select-Object -First 1).Version)"
Write-Output "  ChromeDriver:    $driverExe"
Write-Output "  Chrome browser:  $chromeVersion"
Write-Output ""
Write-Output "You can now run Get-Image.ps1 from any PowerShell session (as Administrator)."
