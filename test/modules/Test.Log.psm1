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

# The global variable is the cross-module communication channel with yuruna-log.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '')]
param()

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
        Starts logging all Write-* output to a log file.
    .DESCRIPTION
        Sets $global:__YurunaLogFile so the yuruna-log proxy module
        (automation/yuruna-log.psm1) begins appending all Write-* output
        to the log file. The proxy module should be imported early by the
        calling script; this function just activates file logging by
        setting the path. If the proxy is not yet loaded, it will be
        imported here as a fallback.
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
    $logFile = Join-Path $logDir "${safeRunId}.${Hostname}.${GitCommit}.txt"
    if ($PSCmdlet.ShouldProcess($logFile, 'Start log file')) {
        $global:__YurunaLogFile = $logFile
        # Fallback: import the proxy module if not already loaded
        if (-not (Get-Module yuruna-log)) {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $TestRoot)
            $logModule = Join-Path -Path $repoRoot -ChildPath "automation" -AdditionalChildPath "yuruna-log.psm1"
            if (Test-Path $logModule) {
                Import-Module $logModule -Global -Force -Verbose:$false
            }
        }
    }
    return $logFile
}

function Stop-LogFile {
    <#
    .SYNOPSIS
        Stops file logging by clearing the log file path.
    .DESCRIPTION
        Clears $global:__YurunaLogFile so the yuruna-log proxy stops
        appending to the log file. The proxy module remains loaded so
        it can be reactivated by the next Start-LogFile call.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('log file', 'Stop logging')) {
        $global:__YurunaLogFile = $null
    }
}

Export-ModuleMember -Function Start-LogFile, Stop-LogFile
