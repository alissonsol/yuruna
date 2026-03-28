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

<#
.SYNOPSIS
    Captures a screenshot of a VM window.
.DESCRIPTION
    UTM:     uses screencapture (macOS) targeting the UTM window.
    Hyper-V: uses Get-VMVideo / vmconnect bitmap capture.
    Returns the path to the saved PNG, or $null on failure.
#>
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
        # Find the vmconnect window for this VM and capture it.
        # This works in basic mode without Enhanced Session or guest tools.
        Add-Type -AssemblyName System.Drawing
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Drawing;
public class WindowCapture {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static IntPtr FindWindow(string titleContains) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().Contains(titleContains)) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static Bitmap CaptureWindow(IntPtr hWnd) {
        RECT rect;
        GetWindowRect(hWnd, out rect);
        int w = rect.Right - rect.Left;
        int h = rect.Bottom - rect.Top;
        if (w <= 0 || h <= 0) return null;
        var bmp = new Bitmap(w, h);
        using (var g = Graphics.FromImage(bmp)) {
            IntPtr hdc = g.GetHdc();
            PrintWindow(hWnd, hdc, 2);
            g.ReleaseHdc(hdc);
        }
        return bmp;
    }
}
"@ -ErrorAction SilentlyContinue

        $hWnd = [WindowCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'."
            return $null
        }
        $bmp = [WindowCapture]::CaptureWindow($hWnd)
        if ($bmp) {
            $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
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

<#
.SYNOPSIS
    Compares two PNG images and returns a similarity score (0.0 to 1.0).
.DESCRIPTION
    Uses pixel-level comparison. Returns 1.0 for identical images.
#>
function Compare-Screenshot {
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

<#
.SYNOPSIS
    Reads the screenshot schedule JSON for a guest.
.DESCRIPTION
    Returns an array of checkpoints: @( @{ name; delaySeconds; threshold } )
    Returns empty array if no schedule file exists.
#>
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

<#
.SYNOPSIS
    Executes all screenshot checkpoints for a running VM.
.DESCRIPTION
    Waits the specified delay, captures, and compares with reference.
    Returns a hashtable: { success, skipped, errorMessage }
#>
function Invoke-ScreenshotTest {
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

        $result = Compare-Screenshot -ReferencePath $refFile -ActualPath $capFile -Threshold $threshold
        if (-not $result.match) {
            $msg = "Screenshot '$cpName' mismatch: similarity=$($result.similarity) threshold=$threshold"
            if ($result.error) { $msg += " error=$($result.error)" }
            return @{ success=$false; skipped=$false; errorMessage=$msg }
        }
        Write-Output "  Screenshot checkpoint '$cpName': PASS (similarity=$($result.similarity))"
    }

    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-VMScreenshot, Compare-Screenshot, Get-ScreenshotSchedule, Invoke-ScreenshotTest
