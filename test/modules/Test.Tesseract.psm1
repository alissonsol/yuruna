<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42570333-9ac2-4031-a0fd-695d1459461e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Test.Tesseract
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# Resolve-OcrImagePath / Clear-OcrImagePath: tesseract is a native binary and
# cannot open a path past the Windows long-path ceiling, so every image handed
# to it goes through the shared leaf helper first.
Import-Module (Join-Path $PSScriptRoot 'Test.OcrPath.psm1') -Global -Force

<#
.SYNOPSIS
    Common Tesseract OCR utilities: locate the executable, guide installation, and run OCR.

.DESCRIPTION
    Provides shared functions for Tesseract OCR used by Start-TestRunner,
    Debug-TestSequence, and the OCR-engine dispatcher (Test.OcrEngine).
    Works on Windows, macOS, and Linux.
#>

# --- REGION: Locate Tesseract
# Module-scoped cache for Find-Tesseract. tesseract's install location is
# stable across an entire cycle (and usually across the host's lifetime),
# but Invoke-TesseractOcr / Get-TesseractWordBox call Find-Tesseract on
# every OCR invocation. With ~1000+ OCR calls per cycle on a busy host the
# `Get-Command tesseract` + Test-Path probes add up to several seconds of
# pure path-lookup overhead. We cache the resolved path and defensively
# re-probe when the cached file has disappeared (uninstall mid-run).
$script:CachedTesseractPath = $null

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

    # Cache hit: re-validate the cached path exists; if it does, return it
    # without going through Get-Command / Test-Path again.
    if ($script:CachedTesseractPath -and (Test-Path $script:CachedTesseractPath)) {
        return $script:CachedTesseractPath
    }
    $script:CachedTesseractPath = $null

    # Check PATH first
    $cmd = Get-Command tesseract -ErrorAction SilentlyContinue
    if ($cmd) {
        $script:CachedTesseractPath = $cmd.Source
        return $cmd.Source
    }

    # Windows: check common install locations (winget / Chocolatey / manual)
    if ($IsWindows) {
        $searchPaths = @(
            "C:\Program Files\Tesseract-OCR"
            "C:\Program Files (x86)\Tesseract-OCR"
            "$env:LOCALAPPDATA\Programs\Tesseract-OCR"
        )
        foreach ($dir in $searchPaths) {
            $candidate = Join-Path $dir "tesseract.exe"
            if (Test-Path $candidate) {
                $script:CachedTesseractPath = $candidate
                return $candidate
            }
        }
    }

    # macOS: check Homebrew locations
    if ($IsMacOS) {
        foreach ($candidate in @("/usr/local/bin/tesseract", "/opt/homebrew/bin/tesseract")) {
            if (Test-Path $candidate) {
                $script:CachedTesseractPath = $candidate
                return $candidate
            }
        }
    }

    # Linux: check standard package-manager and snap locations, so a tesseract
    # present on disk but absent from a stripped-down PATH (e.g. a non-login
    # service shell) is still found, matching the Windows/macOS filesystem
    # fallbacks above.
    if ($IsLinux) {
        foreach ($candidate in @("/usr/bin/tesseract", "/usr/local/bin/tesseract", "/snap/bin/tesseract")) {
            if (Test-Path $candidate) {
                $script:CachedTesseractPath = $candidate
                return $candidate
            }
        }
    }

    return $null
}

# --- REGION: Installation guidance
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

# The OCR process gets its own OpenMP budget. Changing $env: in the runner
# would race other children and override an operator's explicit tuning.
function Invoke-TesseractNative {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ImagePath,
        [switch]$WordBoxes
    )
    if (-not (Get-Command Invoke-BoundedNativeCommand -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -Verbose:$false
    }
    $childEnvironment = @{}
    if ($null -eq [Environment]::GetEnvironmentVariable('OMP_THREAD_LIMIT') -and
        $null -eq [Environment]::GetEnvironmentVariable('OMP_NUM_THREADS')) {
        $childEnvironment.OMP_THREAD_LIMIT = '2'
    }
    $arguments = @($ImagePath, 'stdout', '--psm', '6')
    if ($WordBoxes) { $arguments += 'tsv' }
    # Slow ARM hosts retain a generous allowance. An incomplete capture must
    # fail rather than become an empty screen or a cached partial OCR result.
    $result = Invoke-BoundedNativeCommand -FilePath $FilePath -ArgumentList $arguments -TimeoutSeconds 300 `
        -Environment $childEnvironment -MaxCapturedChars 4194304 -StreamEncoding ([Console]::OutputEncoding)
    $complete = $result.Started -eq $true -and $result.TimedOut -eq $false -and
        $result.DrainTimedOut -eq $false -and $result.OutputTruncated -eq $false -and $result.KillFailed -eq $false
    $exitCode = if ($complete) { $result.ExitCode } else { -1 }
    $stderr = [string]$result.StdErr
    if (-not $complete) {
        $stderr += " [Started=$($result.Started); TimedOut=$($result.TimedOut); DrainTimedOut=$($result.DrainTimedOut); OutputTruncated=$($result.OutputTruncated); KillFailed=$($result.KillFailed); StartError=$($result.StartError)]"
    }
    # PowerShell's native pipeline removes one final line terminator and joins
    # the remaining lines with LF. Preserve that text/TSV contract here.
    $stdout = [string]$result.StdOut -replace "`r`n|`r", "`n"
    if ($stdout.EndsWith("`n")) { $stdout = $stdout.Substring(0, $stdout.Length - 1) }
    $stderr = $stderr -replace "`r`n|`r", "`n"
    if ($stderr.EndsWith("`n")) { $stderr = $stderr.Substring(0, $stderr.Length - 1) }
    return @{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
}

# --- REGION: Run OCR
function Invoke-TesseractOcr {
    <#
    .SYNOPSIS
        Runs Tesseract OCR on the given image file and returns the recognized text.
    .PARAMETER ImagePath
        Path to a PNG or image file to OCR.
    .OUTPUTS
        System.String. The text recognized by Tesseract.
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

    # A path tesseract cannot open reads as an empty screen rather than an
    # error to everything downstream, so the handle is resolved before the run
    # and released in the finally below whether the run throws or not.
    $pathHandle = Resolve-OcrImagePath -ImagePath $ImagePath
    $absPath = [string]$pathHandle.Path

    try {
        $result = Invoke-TesseractNative -FilePath $tesseractExe -ImagePath $absPath
        $exitCode = $result.ExitCode
        if ($exitCode -ne 0) {
            $errMsg = $result.StdErr
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_a6e757fc71fd4874' -Arguments @{ exitCode = "$exitCode"; errMsg = "$errMsg" })
        }
        $text = $result.StdOut
    } finally {
        Clear-OcrImagePath -Handle $pathHandle
    }

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
        origin top-left -- the same space the caller captured the screenshot in.
    .PARAMETER ImagePath
        Path to a PNG or image file to OCR.
    .OUTPUTS
        System.Collections.Hashtable[]. Each entry: @{ text; x; y; w; h; conf }.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable[]], [object[]])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImagePath
    )

    $tesseractExe = Find-Tesseract
    if (-not $tesseractExe) { throw (Get-TesseractInstallGuidance) }
    # Same long-path ceiling as the text path above: word boxes read off an
    # image tesseract could not open would come back as an empty box set.
    $pathHandle = Resolve-OcrImagePath -ImagePath $ImagePath
    $absPath = [string]$pathHandle.Path

    try {
        $result = Invoke-TesseractNative -FilePath $tesseractExe -ImagePath $absPath -WordBoxes
        $exitCode = $result.ExitCode
        if ($exitCode -ne 0) {
            $errMsg = $result.StdErr
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_073ccaf1b0a8e98d' -Arguments @{ exitCode = "$exitCode"; errMsg = "$errMsg" })
        }
        $output = $result.StdOut -split "`n"
    } finally {
        Clear-OcrImagePath -Handle $pathHandle
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
    return ,$boxes.ToArray()
}

Export-ModuleMember -Function Find-Tesseract, Get-TesseractInstallGuidance, Assert-TesseractInstalled, Invoke-TesseractOcr, Get-TesseractWordBox
