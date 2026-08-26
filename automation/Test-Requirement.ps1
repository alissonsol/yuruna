<#PSScriptInfo
.VERSION 2026.08.25
.GUID 421cce10-e006-4347-9b80-8e0984aa3c10
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
    .SYNOPSIS
    A developer toolset for cross-cloud Kubernetes-based applications - Test requirements.

    .DESCRIPTION
    Check if machine has all requirements.

    .PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default 'Error'.

    .INPUTS
    None.

    .OUTPUTS
    Requirements verification output.

    .EXAMPLE
    C:\PS> Test-Requirement.ps1
    Check if machine has all requirements.

    .LINK
    Online version: https://yuruna.com
#>

param (
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel='Error',
    # Report only these tools. An installer passes the set it manages, so a
    # missing cloud CLI it never installs does not bury a real problem.
    [Parameter()][string[]]$Tool,
    # Report problems and exit 0. An installer wants the operator TOLD, not
    # blocked: a package-manager hiccup mid-install should not end the run,
    # but it must not pass unmentioned either.
    [Parameter()][switch]$WarnOnly
)

# logLevel cascade: shared by every automation entrypoint (see Yuruna.LogLevel.psm1).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.LogLevel.psm1') -Global -Force
Set-YurunaLogLevel -LogLevel $logLevel

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
Set-Item -Path Env:yuruna_root -Value ${yuruna_root}
Write-Debug "yuruna_root is $yuruna_root"
Get-Module Yuruna.* | Remove-Module *>&1 | Write-Verbose
$requirementsModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Requirement.psm1"
Import-Module -Name $requirementsModulePath -Force

$transcriptFileName = [System.IO.Path]::GetTempFileName()
$null = Start-Transcript $transcriptFileName

# `pwsh -File` passes every argument as a STRING, so `-Tool a,b` arrives as one
# element "a,b" rather than two. Every caller of this script is a shell
# installer using -File, so splitting here is what makes the filter work at all
# -- without it the filter matches nothing and the check silently reports on no
# tools, which looks exactly like a clean run.
$toolFilter = @($Tool | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$confirmArgs = @{}
if ($toolFilter.Count) { $confirmArgs['Tool'] = $toolFilter }
$result = Confirm-RequirementList @confirmArgs

$null = Stop-Transcript
if ($WarnOnly) {
    # One machine-readable line per problem, for a shell installer collecting
    # them into its own end-of-run summary. Formatted from the result's Reason
    # rather than emitted inside Confirm-RequirementList: that function RETURNS
    # a value, so a Write-Output there would join its return instead of
    # reaching the console.
    if (-Not $result) {
        foreach ($line in ("$($result.Reason)" -split "`n")) {
            $text = $line.Trim()
            if ($text) { Write-Output "REQUIREMENT-ISSUE: $text" }
        }
        Write-Output $(Get-Content -Path $transcriptFileName)
    }
    exit 0
}
if (-Not $result) {
    Write-Output $result
    Write-Output $(Get-Content -Path $transcriptFileName)
    # Propagate the failure as a non-zero process exit so bash `set -e` wrappers see a
    # Confirm-RequirementList failure -- matching `yuruna.ps1 requirements` (its bool tail exits 1).
    exit 1
}
else {
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $transcriptFileName)"
}
