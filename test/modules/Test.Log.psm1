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
        [Parameter(Mandatory)] [string]$CycleId,
        [Parameter(Mandatory)] [string]$Hostname,
        [Parameter(Mandatory)] [string]$GitCommit
    )
    $logDir = Get-LogDir -TestRoot $TestRoot
    # Sanitize CycleId for use as a filename (replace colons from ISO timestamps)
    $safeCycleId = $CycleId -replace ':', '-'
    $logFile = Join-Path $logDir "${safeCycleId}.${Hostname}.${GitCommit}.html"
    if ($PSCmdlet.ShouldProcess($logFile, 'Start log file')) {
        # HTML preamble with cache-control meta tags so the log expires in
        # the browser after 30s and a hard reload always fetches fresh
        # content. Status server already sends
        # `Cache-Control: no-store, no-cache, must-revalidate` as HTTP
        # headers, but browsers still serve stale pages from bfcache
        # (back/forward navigation) and some proxies ignore response
        # headers. Meta tags are advisory but bake the directive into the
        # file itself so it survives download / mirroring / direct
        # file:// opens as well.
        $preamble = @'
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta http-equiv="Cache-Control" content="max-age=30, must-revalidate">
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="0">
<title>Yuruna test-runner log</title>
</head><body><pre>
'@
        $preamble | Microsoft.PowerShell.Utility\Out-File -FilePath $logFile -Encoding utf8 -ErrorAction SilentlyContinue
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
        if ($global:__YurunaLogFile) {
            "</pre></body></html>" | Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
        }
        $global:__YurunaLogFile = $null
    }
}

Export-ModuleMember -Function Start-LogFile, Stop-LogFile
