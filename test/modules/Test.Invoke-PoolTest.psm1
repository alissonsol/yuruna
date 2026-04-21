<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456715
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

Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

# ── Pool test extensions ─────────────────────────────────────────────────────

<#
.SYNOPSIS
    Discovers extension test scripts for a guest under the extensions/ directory.
.DESCRIPTION
    Naming convention:
      Test-Workload.guest.amazon.linux.ps1               (single test)
      Test-Workload.guest.amazon.linux.check-ssh.ps1     (named test)
    Returns an array of FileInfo objects, sorted alphabetically.
#>
function Get-GuestTestScript {
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

<#
.SYNOPSIS
    Runs all extension test scripts for a guest.
.DESCRIPTION
    Each script is executed as a child process and receives:
    -HostType, -GuestKey, -VMName.
    When ShowOutput is true, all child process output is streamed
    to the caller so progress is visible.
    Returns a hashtable: { success, skipped, errorMessage }
#>
function Invoke-PoolTest {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ExtensionsDir,
        [bool]$ShowOutput = $true
    )
    $scripts = Get-GuestTestScript -GuestKey $GuestKey -ExtensionsDir $ExtensionsDir
    if ($scripts.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }
    foreach ($s in $scripts) {
        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($s.Name)
        Write-Information "  Running: $displayName" -InformationAction Continue
        if ($ShowOutput) {
            & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName | ForEach-Object {
                # PROGRESS-MARKER-PARSER: keep in sync with Test.Install-OS.psm1
                $line = [string]$_
                $idx = $line.IndexOf('##YURUNA-PROGRESS##|')
                if ($idx -ge 0) {
                    $parts = $line.Substring($idx + 20).Split('|')
                    if ($parts.Count -ge 4) {
                        $pActivity = $parts[0]
                        $pStatus   = $parts[1]
                        $pPercent  = [int]$parts[2]
                        $pDone     = $parts[3] -eq '1'
                        if ($pDone) {
                            Write-Progress -Activity $pActivity -Completed
                        } elseif ($pPercent -ge 0) {
                            Write-Progress -Activity $pActivity -Status $pStatus -PercentComplete $pPercent
                        } else {
                            Write-Progress -Activity $pActivity -Status $pStatus
                        }
                    }
                } else {
                    # Indent VERBOSE one tab deeper than DEBUG/plain lines so the
                    # log gives verbose output a visibly subordinate position.
                    if ($line -match '^\s*(?:\x1b\[[0-9;]*m)?VERBOSE:') {
                        Write-Information "        $line" -InformationAction Continue
                    } else {
                        Write-Information "    $line" -InformationAction Continue
                    }
                }
            }
        } else {
            & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName *>$null
        }
        if ($LASTEXITCODE -ne 0) {
            $errMsg = "Test '$($s.Name)' failed (exit code $LASTEXITCODE)"
            # Read failure details written by Invoke-Sequence (if available)
            $logDir = Initialize-YurunaLogDir
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
        Write-Information "  ${displayName}: PASS" -InformationAction Continue
    }
    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-GuestTestScript, Invoke-PoolTest
