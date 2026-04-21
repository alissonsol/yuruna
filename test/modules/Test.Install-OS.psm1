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

Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false

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
        $displayName = [System.IO.Path]::GetFileNameWithoutExtension($s.Name)
        Write-Information "  Running: $displayName" -InformationAction Continue
        if ($ShowOutput) {
            # Stream child stdout line-by-line via Information stream. The child's
            # Write-Progress cannot render because its ConsoleHost goes
            # non-interactive when stdout is piped, so Invoke-Sequence emits
            # "##YURUNA-PROGRESS##|Activity|Status|Percent|Completed" marker lines
            # via $Host.UI.WriteLine. We detect those here and call Write-Progress
            # in the parent's interactive host, where the bar actually renders.
            & pwsh -NoProfile -File $s.FullName -HostType $HostType -GuestKey $GuestKey -VMName $VMName | ForEach-Object {
                # PROGRESS-MARKER-PARSER: keep in sync with Test.Invoke-PoolTest.psm1
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
            $errMsg = "Start test '$($s.Name)' failed (exit code $LASTEXITCODE)"
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

Export-ModuleMember -Function Get-StartTestScript, Invoke-StartTest
