<#PSScriptInfo
.VERSION 0.1
.GUID 42c3d4e5-f6a7-4b89-0c12-de3f4a5b6c7d
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

param(
    [string]$Prefix = "test-"
)

$ErrorActionPreference = "Stop"
$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot
$ModulesDir = Join-Path $TestRoot "modules"

# === Import Test.Host module for Get-HostType ===
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force

# === Detect host type ===
$HostType = Get-HostType
if (-not $HostType) { exit 1 }
Write-Output "Host type: $HostType"
Write-Output ""

# === Stop all test-* VMs ===
Write-Output "Stopping VMs with prefix '$Prefix'..."
Write-Output ""

$savedProgress = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'

switch ($HostType) {
    "host.windows.hyper-v" {
        $testVMs = Get-VM | Where-Object { $_.Name -like "${Prefix}*" }
        if ($testVMs.Count -eq 0) {
            Write-Output "  No Hyper-V VMs found matching '${Prefix}*'."
        }
        foreach ($vm in $testVMs) {
            Write-Output "  Stopping $($vm.Name) [$($vm.State)]..."
            if ($vm.State -ne 'Off') {
                Stop-VM -Name $vm.Name -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                Write-Output "    Stopped."
            } else {
                Write-Output "    Already off."
            }
            Remove-VM -Name $vm.Name -Force
            Write-Output "    Removed from Hyper-V."
        }
    }
    "host.macos.utm" {
        $utmOutput = & utmctl list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
            exit 1
        }
        $found = $false
        foreach ($line in $utmOutput) {
            $line = "$line".Trim()
            if (-not $line -or $line -match '^-+$') { continue }
            $parts = $line -split '\s{2,}'
            if ($parts.Count -ge 2 -and $parts[0] -match '^[0-9A-Fa-f-]{36}$') {
                $vmName = $parts[1].Trim()
                if ($vmName -like "${Prefix}*") {
                    $found = $true
                    Write-Output "  Stopping $vmName..."
                    & utmctl stop "$vmName" 2>&1 | Out-Null
                    Start-Sleep -Seconds 2
                    & utmctl delete "$vmName" 2>&1 | Out-Null
                    Write-Output "    Removed from UTM."
                }
            }
        }
        if (-not $found) {
            Write-Output "  No UTM VMs found matching '${Prefix}*'."
        }
    }
    default {
        Write-Error "Unsupported host type: $HostType"
        exit 1
    }
}

$global:ProgressPreference = $savedProgress

Write-Output ""

# === Run Remove-OrphanedVMFiles.ps1 with -Force ===
$vdeDir = Join-Path $RepoRoot "vde"
$cleanupScript = Join-Path -Path $vdeDir -ChildPath "$HostType" -AdditionalChildPath "Remove-OrphanedVMFiles.ps1"

if (-not (Test-Path $cleanupScript)) {
    Write-Error "Cleanup script not found: $cleanupScript"
    exit 1
}

Write-Output "Running orphaned VM file cleanup: $cleanupScript"
Write-Output ""
& $cleanupScript -Force
