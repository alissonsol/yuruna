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

# === Detect platform and architecture ===
if ($IsWindows) {
    $platform = "windows"
} elseif ($IsMacOS) {
    $platform = "macos"
} else {
    Write-Error "Unsupported platform. Only Windows and macOS are supported."
    exit 1
}

$arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLower()
# Map to Chrome for Testing platform names
switch ("$platform-$arch") {
    "windows-x64"   { $cftPlatform = "win64";     $zipSubdir = "chromedriver-win64" }
    "windows-arm64" { $cftPlatform = "win64";     $zipSubdir = "chromedriver-win64" }   # Chrome/driver on Windows ARM uses win64 emulation
    "macos-x64"     { $cftPlatform = "mac-x64";   $zipSubdir = "chromedriver-mac-x64" }
    "macos-arm64"   { $cftPlatform = "mac-arm64";  $zipSubdir = "chromedriver-mac-arm64" }
    default {
        Write-Error "Unsupported platform/architecture: $platform-$arch"
        exit 1
    }
}
Write-Output "Platform: $platform  Architecture: $arch  Chrome for Testing platform: $cftPlatform"

# === Elevation check (Windows only) ===
if ($IsWindows) {
    Write-Output "This script requires elevation (Run as Administrator) on Windows."
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Output "Please run this script as Administrator."
        exit 1
    }
}

# === Configuration ===
$seleniumDir = Join-Path $PSScriptRoot "selenium"
$driverName  = if ($IsWindows) { "chromedriver.exe" } else { "chromedriver" }
$driverExe   = Join-Path $seleniumDir $driverName

# === Step 1: Selenium PowerShell Module (Windows only) ===
if ($IsWindows) {
    $allVersions = Get-Module -ListAvailable -Name Selenium
    if (($allVersions | Measure-Object).Count -gt 1) {
        Write-Output "Multiple Selenium module versions detected. Cleaning up to fix TypeData conflicts..."
        foreach ($mod in $allVersions) {
            Write-Output "  Removing Selenium $($mod.Version) from $($mod.ModuleBase)..."
            try {
                Uninstall-Module -Name Selenium -RequiredVersion $mod.Version -Force -AllVersions -ErrorAction SilentlyContinue
            } catch {
                if (Test-Path $mod.ModuleBase) {
                    Remove-Item -Path $mod.ModuleBase -Recurse -Force -ErrorAction SilentlyContinue
                    Write-Output "  Removed folder: $($mod.ModuleBase)"
                }
            }
        }
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
}

# === Step 2: Detect installed Google Chrome version ===
if ($IsWindows) {
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chromePath = $null
    foreach ($p in $chromePaths) {
        if (Test-Path $p) { $chromePath = $p; break }
    }
    if (-not $chromePath) {
        Write-Error "Google Chrome not found. Chrome is required for Selenium browser automation."
        Write-Output "Expected locations:"
        foreach ($p in $chromePaths) { Write-Output "  $p" }
        exit 1
    }
    $chromeVersion = (Get-Item $chromePath).VersionInfo.FileVersion
} elseif ($IsMacOS) {
    $chromeAppPath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if (-not (Test-Path $chromeAppPath)) {
        Write-Error "Google Chrome not found at $chromeAppPath."
        exit 1
    }
    $chromeVersion = (& "$chromeAppPath" --version 2>&1) -replace '[^0-9.]', ''
}

$chromeMajor = ($chromeVersion -split '\.')[0]
Write-Output "Installed Chrome version: $chromeVersion (major: $chromeMajor)"

# === Step 3: Check existing ChromeDriver ===
$needsDriver = $true
if (Test-Path $driverExe) {
    try {
        $driverOutput = & $driverExe --version 2>&1
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

# === Step 4: Download ChromeDriver ===
if ($needsDriver) {
    if (!(Test-Path $seleniumDir)) {
        New-Item -ItemType Directory -Path $seleniumDir -Force | Out-Null
    }

    $zipExt = ".zip"
    $driverZipFile = Join-Path $seleniumDir "chromedriver-$cftPlatform$zipExt"
    $downloaded = $false

    # --- Strategy 1: Chrome for Testing JSON API (preferred) ---
    Write-Output "Strategy 1 - Chrome for Testing JSON API..."
    try {
        $knownVersionsUrl = "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json"
        Write-Output "  Fetching known good versions..."
        $knownVersions = Invoke-RestMethod -Uri $knownVersionsUrl -UseBasicParsing -ErrorAction Stop

        $matchingVersions = $knownVersions.versions |
            Where-Object { ($_.version -split '\.')[0] -eq $chromeMajor } |
            Where-Object { $_.downloads.chromedriver } |
            Sort-Object { [version]$_.version } -Descending

        $bestMatch = $matchingVersions | Select-Object -First 1
        if ($bestMatch) {
            $driverDownload = $bestMatch.downloads.chromedriver | Where-Object { $_.platform -eq $cftPlatform }
            if ($driverDownload) {
                $url = $driverDownload.url
                Write-Output "  Found ChromeDriver $($bestMatch.version) for $cftPlatform"
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
            $url = "https://storage.googleapis.com/chrome-for-testing-public/$latestVersion/$cftPlatform/$zipSubdir.zip"
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
        $url = "https://storage.googleapis.com/chrome-for-testing-public/$chromeVersion/$cftPlatform/$zipSubdir.zip"
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
        Write-Output "Place $driverName in: $seleniumDir"
        exit 1
    }

    # Extract chromedriver from the zip (overwrite existing)
    Write-Output "Extracting $driverName..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($driverZipFile)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -eq $driverName }
        if (-not $entry) {
            Write-Error "$driverName not found inside the downloaded zip."
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

    # Make executable on macOS
    if ($IsMacOS) {
        & chmod +x $driverExe
    }

    Write-Output "ChromeDriver installed: $driverExe"

    # Verify the downloaded driver
    $verifyOutput = & $driverExe --version 2>&1
    Write-Output "Verified: $verifyOutput"
}

# === Step 5: Add selenium folder to PATH ===
if ($IsWindows) {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
    if ($machinePath -split ";" | Where-Object { $_ -eq $seleniumDir }) {
        Write-Output "Selenium folder already in system PATH."
    } else {
        Write-Output "Adding selenium folder to system PATH: $seleniumDir"
        [Environment]::SetEnvironmentVariable("Path", "$machinePath;$seleniumDir", [EnvironmentVariableTarget]::Machine)
        Write-Output "PATH updated. New PowerShell sessions will find chromedriver.exe automatically."
    }
    if (-not ($env:Path -split ";" | Where-Object { $_ -eq $seleniumDir })) {
        $env:Path = "$env:Path;$seleniumDir"
    }
} elseif ($IsMacOS) {
    # On macOS, add to current session; user should add to shell profile for persistence
    if (-not ($env:PATH -split ":" | Where-Object { $_ -eq $seleniumDir })) {
        $env:PATH = "$env:PATH`:$seleniumDir"
        Write-Output "Added selenium folder to session PATH: $seleniumDir"
        Write-Output "For persistence, add to your shell profile: export PATH=`"`$PATH:$seleniumDir`""
    } else {
        Write-Output "Selenium folder already in session PATH."
    }
}

Write-Output ""
Write-Output "=== Setup complete ==="
if ($IsWindows) {
    Write-Output "  Selenium module: $((Get-Module -ListAvailable -Name Selenium | Sort-Object Version -Descending | Select-Object -First 1).Version)"
}
Write-Output "  ChromeDriver:    $driverExe"
Write-Output "  Chrome browser:  $chromeVersion"
Write-Output "  Platform:        $cftPlatform ($arch)"
