<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456715
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

# ── Pool test extensions ─────────────────────────────────────────────────────

# Discovers extension test scripts for a guest under the extensions/ directory.
# Naming convention:
#   Test-Workload.guest.amazon.linux.ps1               (single test)
#   Test-Workload.guest.amazon.linux.check-ssh.ps1     (named test)
# Returns an array of FileInfo objects, sorted alphabetically.
function Get-GuestTestScripts {
    param([string]$GuestKey, [string]$ExtensionsDir)
    if (-not (Test-Path $ExtensionsDir)) { return @() }
    $prefix   = "Test-Workload.$GuestKey"
    $exact    = Join-Path $ExtensionsDir "$prefix.ps1"
    $extra    = Get-ChildItem -Path $ExtensionsDir -Filter "$prefix.*.ps1" -ErrorAction SilentlyContinue
    $scripts  = @()
    if (Test-Path $exact) { $scripts += Get-Item $exact }
    if ($extra)           { $scripts += @($extra) }
    return @($scripts | Sort-Object Name)
}

# Runs all extension test scripts for a guest.
# Each script is executed as a child process and receives:
#   -HostType, -GuestKey, -VMName
# Returns a hashtable: { success, skipped, errorMessage }
function Invoke-PoolTest {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ExtensionsDir
    )
    $scripts = Get-GuestTestScripts -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir
    if ($scripts.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $scripts) {
        Write-Output "Running test: $($s.Name)"
        & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName
        if ($LASTEXITCODE -ne 0) {
            return @{ success=$false; skipped=$false; errorMessage="Test '$($s.Name)' failed (exit code $LASTEXITCODE)" }
        }
        Write-Output "  $($s.Name): PASS"
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-GuestTestScripts, Invoke-PoolTest
