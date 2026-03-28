<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456716
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
    Returns a hashtable: { success, skipped, errorMessage }
#>
function Invoke-StartTest {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ExtensionsDir
    )
    $scripts = Get-StartTestScript -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir
    if ($scripts.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $scripts) {
        Write-Output "Running start test: $($s.Name)"
        & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName
        if ($LASTEXITCODE -ne 0) {
            return @{ success=$false; skipped=$false; errorMessage="Start test '$($s.Name)' failed (exit code $LASTEXITCODE)" }
        }
        Write-Output "  $($s.Name): PASS"
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
    if (Test-Path $expectedFile) { return $expectedFile }
    return $null
}

Export-ModuleMember -Function Get-StartTestScript, Invoke-StartTest, Get-VerifyScreenshot
