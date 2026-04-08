<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456716
.AUTHOR Alisson Sol
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

#requires -version 7

Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue

# ── Test-Start extension discovery ───────────────────────────────────────────

<#
.SYNOPSIS
    Discovers Test-Start scripts for a guest under the extensions/ directory.
.DESCRIPTION
    Naming convention: Test-Start.guest.<key>.ps1
    Returns an array of FileInfo objects, sorted alphabetically.
#>
function Get-StartTestScript {
    param([string]$GuestKey, [string]$ExtensionsDir)
    if (-not (Test-Path $ExtensionsDir)) { return @() }
    $prefix = "Test-Start.$GuestKey"
    $exact  = Join-Path $ExtensionsDir "$prefix.ps1"
    $extra  = Get-ChildItem -Path $ExtensionsDir -Filter "$prefix.*.ps1" -ErrorAction SilentlyContinue
    $scripts = @()
    if (Test-Path $exact) { $scripts += Get-Item $exact }
    if ($extra)           { $scripts += @($extra) }
    return @($scripts | Sort-Object Name)
}

<#
.SYNOPSIS
    Runs all Test-Start scripts for a guest.
.DESCRIPTION
    Each script is executed as a child process and receives:
    -HostType, -GuestKey, -VMName.
    When ShowOutput is true, all child process output (stdout, stderr,
    information) is streamed to the caller so progress is visible.
    Returns a hashtable: { success, skipped, errorMessage }
#>
function Invoke-StartTest {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ExtensionsDir,
        [bool]$ShowOutput = $true
    )
    $scripts = Get-StartTestScript -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir
    if ($scripts.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $scripts) {
        Write-Information "  Running: $($s.Name)" -InformationAction Continue
        if ($ShowOutput) {
            # Stream child output line-by-line to the console via Information stream.
            # Information stream (6) is NOT captured by $r = Invoke-StartTest, so
            # these lines appear in the runner output without polluting the return value.
            & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName *>&1 | ForEach-Object {
                Write-Information "    $_" -InformationAction Continue
            }
        } else {
            & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName *>$null
        }
        if ($LASTEXITCODE -ne 0) {
            $errMsg = "Start test '$($s.Name)' failed (exit code $LASTEXITCODE)"
            # Read failure details written by Invoke-Sequence (if available)
            $logDir = Get-YurunaLogDir
            $failFile = Join-Path $logDir "last_failure.json"
            if (Test-Path $failFile) {
                try {
                    $failInfo = Get-Content -Raw $failFile | ConvertFrom-Json
                    $errMsg = "Step [$($failInfo.stepNumber)/$($failInfo.totalSteps)] $($failInfo.action) — $($failInfo.description) (test: $($s.Name))"
                } catch {
                    Write-Verbose "Could not parse failure details: $_"
                }
            }
            return @{ success=$false; skipped=$false; errorMessage=$errMsg }
        }
        Write-Information "  $($s.Name): PASS" -InformationAction Continue
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

# ── Post-install verification via screenshot ─────────────────────────────────

<#
.SYNOPSIS
    Checks if a verification screenshot exists for the given host+guest pair.
.DESCRIPTION
    Files are named <hostType>.<guestKey>.png under verify/expected/.
    Returns the path to the expected screenshot, or $null if none exists.
#>
function Get-VerifyScreenshot {
    param([string]$HostType, [string]$GuestKey, [string]$VerifyDir)
    $fileName = "$HostType.$GuestKey.png"
    $expectedFile = Join-Path $VerifyDir "expected/$fileName"
    if (-not (Test-Path $expectedFile)) { return $null }
    # Skip placeholder files (1x1 pixel PNGs shipped as defaults)
    $fileSize = (Get-Item $expectedFile).Length
    if ($fileSize -lt 200) { return $null }
    return $expectedFile
}

Export-ModuleMember -Function Get-StartTestScript, Invoke-StartTest, Get-VerifyScreenshot
