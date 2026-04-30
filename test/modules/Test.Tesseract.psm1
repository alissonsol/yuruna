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
    Invoke-TestSequence, and the OCR-engine dispatcher (Test.OcrEngine).
    Works on Windows, macOS, and Linux.
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

    # --psm 4 = single column of text of variable sizes. VM screens are
    # column layouts (terminal output, installer dialogs, login prompts);
    # the default --psm 3 (fully automatic) tries to detect multi-column
    # layouts and occasionally re-orders lines or merges adjacent UI
    # regions, producing OCR text that doesn't match what waitForText
    # is grepping for.
    $output = & $tesseractExe $absPath stdout --psm 4 2>$null
    if ($LASTEXITCODE -ne 0) {
        $errOutput = & $tesseractExe $absPath stdout --psm 4 2>&1 |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
        $errMsg = ($errOutput | ForEach-Object { "$_" }) -join "`n"
        throw "Tesseract failed with exit code $LASTEXITCODE.`n$errMsg"
    }

    $text = ($output | Where-Object { $_ -is [string] }) -join "`n"
    return $text
}

function Get-TesseractWordBox {
    <#
    .SYNOPSIS
        Runs Tesseract OCR in TSV mode and returns per-word bounding boxes.
    .DESCRIPTION
        Uses tesseract's `tsv` output config (standard in every modern install)
        to get level/x/y/w/h/conf/text rows. We filter to level=5 (word) and
        skip empty-text rows. Coordinates are in the image's pixel space,
        origin top-left — the same space the caller captured the screenshot in.
    .PARAMETER ImagePath
        Path to a PNG or image file to OCR.
    .OUTPUTS
        System.Collections.Hashtable[]. Each entry: @{ text; x; y; w; h; conf }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImagePath
    )

    $tesseractExe = Find-Tesseract
    if (-not $tesseractExe) { throw (Get-TesseractInstallGuidance) }
    $absPath = (Resolve-Path $ImagePath).Path

    # `tesseract <img> stdout tsv` prints TSV with columns:
    #   level page_num block_num par_num line_num word_num left top width height conf text
    # --psm 4 matches Invoke-TesseractOcr above so word boxes line up with
    # the text output (otherwise word ordering and line grouping diverge).
    $output = & $tesseractExe $absPath stdout --psm 4 tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Tesseract TSV mode failed with exit code $LASTEXITCODE."
    }

    $boxes = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in $output) {
        $s = "$line"
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s.StartsWith('level')) { continue }       # header row
        $cols = $s -split "`t"
        if ($cols.Count -lt 12) { continue }
        # level 5 = word; ignore page/block/paragraph/line aggregates
        if ([int]$cols[0] -ne 5) { continue }
        $text = $cols[11]
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $boxes.Add(@{
            text = $text
            x    = [int]$cols[6]
            y    = [int]$cols[7]
            w    = [int]$cols[8]
            h    = [int]$cols[9]
            conf = [int]$cols[10]
        })
    }
    return $boxes.ToArray()
}

Export-ModuleMember -Function Find-Tesseract, Get-TesseractInstallGuidance, Assert-TesseractInstalled, Invoke-TesseractOcr, Get-TesseractWordBox
