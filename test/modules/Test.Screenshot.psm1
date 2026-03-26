<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456714
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

# ── Screenshot capture ───────────────────────────────────────────────────────

# Captures a screenshot of a VM window.
# UTM:     uses screencapture (macOS) targeting the UTM window.
# Hyper-V: uses Get-VMVideo / vmconnect bitmap capture.
# Returns the path to the saved PNG, or $null on failure.
function Get-VMScreenshot {
    param(
        [string]$HostType,
        [string]$VMName,
        [string]$OutputPath
    )
    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    switch ($HostType) {
        "host.macos.utm" {
            return Get-UtmScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        "host.windows.hyper-v" {
            return Get-HyperVScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        default {
            Write-Error "Unknown host type for screenshot: $HostType"
            return $null
        }
    }
}

function Get-UtmScreenshot {
    param([string]$VMName, [string]$OutputPath)
    # Use screencapture with window selection by name
    # First, find the UTM window for this VM
    $script = @"
tell application "System Events"
    set wmList to {}
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$VMName" then
                set end of wmList to id of w
            end if
        end repeat
    end tell
end tell
if (count of wmList) > 0 then
    return item 1 of wmList
else
    return 0
end if
"@
    $windowId = & osascript -e $script 2>&1
    if ($LASTEXITCODE -ne 0 -or "$windowId" -eq "0") {
        Write-Warning "Could not find UTM window for VM '$VMName'. Capturing full screen."
        & screencapture -x "$OutputPath" 2>&1 | Out-Null
    } else {
        & screencapture -x -l "$windowId" "$OutputPath" 2>&1 | Out-Null
    }
    if (Test-Path $OutputPath) {
        Write-Output "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

function Get-HyperVScreenshot {
    param([string]$VMName, [string]$OutputPath)
    try {
        # Hyper-V provides Get-VMVideo for screen capture
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        $video = Get-VMVideo -VMName $VMName -ErrorAction Stop
        # Use the thumbnail path from Hyper-V and copy as our screenshot
        $thumbPath = $video.ImagePath
        if ($thumbPath -and (Test-Path $thumbPath)) {
            Copy-Item -Path $thumbPath -Destination $OutputPath -Force
        } else {
            # Fallback: generate bitmap via vmconnect screenshot
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen
            $bitmap = [System.Drawing.Bitmap]::new($screen.Bounds.Width, $screen.Bounds.Height)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($screen.Bounds.Location, [System.Drawing.Point]::Empty, $screen.Bounds.Size)
            $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        if (Test-Path $OutputPath) {
            Write-Output "Screenshot saved: $OutputPath"
            return $OutputPath
        }
    } catch {
        Write-Warning "Hyper-V screenshot failed: $_"
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

# ── Screenshot comparison ────────────────────────────────────────────────────

# Compares two PNG images and returns a similarity score (0.0 to 1.0).
# Uses pixel-level comparison. Returns 1.0 for identical images.
function Compare-Screenshots {
    param(
        [string]$ReferencePath,
        [string]$ActualPath,
        [double]$Threshold = 0.85
    )
    if (-not (Test-Path $ReferencePath)) {
        Write-Error "Reference screenshot not found: $ReferencePath"
        return @{ match=$false; similarity=0.0; error="Reference not found" }
    }
    if (-not (Test-Path $ActualPath)) {
        Write-Error "Actual screenshot not found: $ActualPath"
        return @{ match=$false; similarity=0.0; error="Actual not found" }
    }

    try {
        Add-Type -AssemblyName System.Drawing
        $ref = [System.Drawing.Bitmap]::new($ReferencePath)
        $act = [System.Drawing.Bitmap]::new($ActualPath)

        # Resize actual to match reference if dimensions differ
        if ($ref.Width -ne $act.Width -or $ref.Height -ne $act.Height) {
            $resized = [System.Drawing.Bitmap]::new($act, $ref.Width, $ref.Height)
            $act.Dispose()
            $act = $resized
        }

        $totalPixels = $ref.Width * $ref.Height
        $matchingPixels = 0

        # Sample pixels (every 4th pixel for performance)
        $step = 4
        $sampled = 0
        for ($y = 0; $y -lt $ref.Height; $y += $step) {
            for ($x = 0; $x -lt $ref.Width; $x += $step) {
                $sampled++
                $rp = $ref.GetPixel($x, $y)
                $ap = $act.GetPixel($x, $y)
                $diff = [Math]::Abs([int]$rp.R - [int]$ap.R) +
                        [Math]::Abs([int]$rp.G - [int]$ap.G) +
                        [Math]::Abs([int]$rp.B - [int]$ap.B)
                # Allow per-pixel tolerance of 30 (out of 765 max diff)
                if ($diff -lt 30) { $matchingPixels++ }
            }
        }

        $similarity = if ($sampled -gt 0) { [Math]::Round($matchingPixels / $sampled, 4) } else { 0.0 }

        $ref.Dispose()
        $act.Dispose()

        $isMatch = $similarity -ge $Threshold
        Write-Output "Screenshot comparison: similarity=$similarity threshold=$Threshold match=$isMatch"
        return @{ match=$isMatch; similarity=$similarity; error=$null }
    } catch {
        Write-Error "Screenshot comparison failed: $_"
        return @{ match=$false; similarity=0.0; error="$_" }
    }
}

# ── Schedule management ──────────────────────────────────────────────────────

# Reads the screenshot schedule JSON for a guest.
# Returns an array of checkpoints: @( @{ name; delaySeconds; threshold } )
# Returns empty array if no schedule file exists.
function Get-ScreenshotSchedule {
    param([string]$GuestKey, [string]$ScreenshotsDir)
    $scheduleFile = Join-Path $ScreenshotsDir "$GuestKey/schedule.json"
    if (-not (Test-Path $scheduleFile)) { return @() }
    try {
        $schedule = Get-Content -Raw $scheduleFile | ConvertFrom-Json
        return @($schedule.checkpoints)
    } catch {
        Write-Warning "Failed to read screenshot schedule: $scheduleFile — $_"
        return @()
    }
}

# Executes all screenshot checkpoints for a running VM.
# Waits the specified delay, captures, and compares with reference.
# Returns a hashtable: { success, skipped, errorMessage }
function Invoke-ScreenshotTests {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ScreenshotsDir
    )
    $schedule = Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir
    if ($schedule.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }

    $guestDir   = Join-Path $ScreenshotsDir $GuestKey
    $captureDir = Join-Path $guestDir "captures"
    if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Force -Path $captureDir | Out-Null }

    foreach ($cp in $schedule) {
        $cpName    = $cp.name
        $delay     = [int]$cp.delaySeconds
        $threshold = if ($cp.threshold) { [double]$cp.threshold } else { 0.85 }
        $refFile   = Join-Path $guestDir "reference/$cpName.png"

        if (-not (Test-Path $refFile)) {
            return @{ success=$false; skipped=$false; errorMessage="Reference screenshot missing: $refFile. Run Train-Screenshots.ps1 -GuestKey $GuestKey first." }
        }

        Write-Output "  Screenshot checkpoint '$cpName': waiting ${delay}s..."
        Start-Sleep -Seconds $delay

        $capFile = Join-Path $captureDir "$cpName.png"
        $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $capFile
        if (-not $captured) {
            return @{ success=$false; skipped=$false; errorMessage="Failed to capture screenshot for checkpoint '$cpName'" }
        }

        $result = Compare-Screenshots -ReferencePath $refFile -ActualPath $capFile -Threshold $threshold
        if (-not $result.match) {
            $msg = "Screenshot '$cpName' mismatch: similarity=$($result.similarity) threshold=$threshold"
            if ($result.error) { $msg += " error=$($result.error)" }
            return @{ success=$false; skipped=$false; errorMessage=$msg }
        }
        Write-Output "  Screenshot checkpoint '$cpName': PASS (similarity=$($result.similarity))"
    }

    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-VMScreenshot, Compare-Screenshots, Get-ScreenshotSchedule, Invoke-ScreenshotTests
