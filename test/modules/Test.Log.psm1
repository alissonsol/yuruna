<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456790
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

function Get-LogDir {
    <#
    .SYNOPSIS
        Returns the test/status/log directory path, creating it if needed.
    #>
    param([string]$TestRoot)
    $logDir = Join-Path -Path $TestRoot -ChildPath "status" -AdditionalChildPath "log"
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return $logDir
}

function Start-LogFile {
    <#
    .SYNOPSIS
        Starts a PowerShell transcript that captures all console output to a log file.
    .DESCRIPTION
        Uses Start-Transcript to tee Write-Output, Write-Debug, and Write-Information
        to a file under test/status/log named ${runId}.${hostname}.${gitCommit}.log.
        The transcript captures everything displayed on screen, so the existing
        debug_mode and verbose_mode preferences control what appears in the log.
    .OUTPUTS
        The full path to the log file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string]$TestRoot,
        [Parameter(Mandatory)] [string]$RunId,
        [Parameter(Mandatory)] [string]$Hostname,
        [Parameter(Mandatory)] [string]$GitCommit
    )
    $logDir = Get-LogDir -TestRoot $TestRoot
    # Sanitize RunId for use as a filename (replace colons from ISO timestamps)
    $safeRunId = $RunId -replace ':', '-'
    $logFile = Join-Path $logDir "${safeRunId}.${Hostname}.${GitCommit}.log"
    if ($PSCmdlet.ShouldProcess($logFile, 'Start transcript')) {
        Start-Transcript -Path $logFile -Append | Out-Null
    }
    return $logFile
}

function Stop-LogFile {
    <#
    .SYNOPSIS
        Stops the active transcript started by Start-LogFile.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('transcript', 'Stop transcript')) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            Write-Debug "No active transcript to stop: $_"
        }
    }
}

Export-ModuleMember -Function Start-LogFile, Stop-LogFile
