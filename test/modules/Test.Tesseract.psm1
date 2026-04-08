<#PSScriptInfo
.VERSION 0.1
.GUID 42a7b8c9-d0e1-4f23-a4b5-6c7d8e9f0a1b
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Test.Tesseract
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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
    Common Tesseract OCR utilities: locate the executable, guide installation, and run OCR.

.DESCRIPTION
    Provides shared functions for Tesseract OCR used by Invoke-TestRunner,
    Invoke-TestSequence, and Get-NewText. Works on Windows, macOS, and Linux.
#>

# --- Locate Tesseract ---

function Find-Tesseract {
    <#
    .SYNOPSIS
        Locates the tesseract executable on the current platform.
    .OUTPUTS
        System.String. Full path to the tesseract executable, or $null if not found.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    # Check PATH first
    $cmd = Get-Command tesseract -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # Windows: check common install locations (winget / Chocolatey / manual)
    if ($IsWindows) {
        $searchPaths = @(
            "C:\Program Files\Tesseract-OCR"
            "C:\Program Files (x86)\Tesseract-OCR"
            "$env:LOCALAPPDATA\Programs\Tesseract-OCR"
        )
        foreach ($dir in $searchPaths) {
            $candidate = Join-Path $dir "tesseract.exe"
            if (Test-Path $candidate) { return $candidate }
        }
    }

    # macOS: check Homebrew locations
    if ($IsMacOS) {
        foreach ($candidate in @("/usr/local/bin/tesseract", "/opt/homebrew/bin/tesseract")) {
            if (Test-Path $candidate) { return $candidate }
        }
    }

    return $null
}

# --- Installation guidance ---

function Get-TesseractInstallGuidance {
    <#
    .SYNOPSIS
        Returns a multi-line string with platform-appropriate install instructions.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    $lines = @(
        "Tesseract not found in PATH or common install locations."
        ""
        "Install via one of:"
        "  winget install UB-Mannheim.TesseractOCR   (Windows)"
        "  choco install tesseract                    (Windows)"
        "  scoop install tesseract                    (Windows)"
        "  brew install tesseract                     (macOS)"
        "  sudo apt install tesseract-ocr             (Linux)"
        ""
        "After installing, ensure 'tesseract' is available in your PATH,"
        "or restart your shell so the updated PATH takes effect."
    )
    return ($lines -join "`n")
}

function Assert-TesseractInstalled {
    <#
    .SYNOPSIS
        Checks that Tesseract is installed. Writes guidance and returns $false if not found.
    .OUTPUTS
        System.Boolean. $true if Tesseract is available, $false otherwise.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param()

    $exe = Find-Tesseract
    if ($exe) {
        Write-Verbose "Tesseract found: $exe"
        return $true
    }

    Write-Warning (Get-TesseractInstallGuidance)
    return $false
}

# --- Run OCR ---

function Invoke-TesseractOcr {
    <#
    .SYNOPSIS
        Runs Tesseract OCR on the given image file and returns the recognised text.
    .PARAMETER ImagePath
        Path to a PNG or image file to OCR.
    .OUTPUTS
        System.String. The text recognised by Tesseract.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImagePath
    )

    $tesseractExe = Find-Tesseract
    if (-not $tesseractExe) {
        throw (Get-TesseractInstallGuidance)
    }

    $absPath = (Resolve-Path $ImagePath).Path

    # tesseract <image> stdout  -- outputs recognised text to stdout
    $output = & $tesseractExe $absPath stdout 2>$null
    if ($LASTEXITCODE -ne 0) {
        $errOutput = & $tesseractExe $absPath stdout 2>&1 |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
        $errMsg = ($errOutput | ForEach-Object { "$_" }) -join "`n"
        throw "Tesseract failed with exit code $LASTEXITCODE.`n$errMsg"
    }

    $text = ($output | Where-Object { $_ -is [string] }) -join "`n"
    return $text
}

Export-ModuleMember -Function Find-Tesseract, Get-TesseractInstallGuidance, Assert-TesseractInstalled, Invoke-TesseractOcr
