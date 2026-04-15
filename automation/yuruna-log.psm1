<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456791
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

# PSScriptAnalyzer suppressions — overriding built-in cmdlets and using a
# global variable are both intentional design choices for this proxy module.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
param()

<#
.SYNOPSIS
    Proxy module that overrides Write-Output, Write-Error, Write-Warning,
    Write-Debug, Write-Verbose, and Write-Information so that every message
    is also appended to a log file.

.DESCRIPTION
    Import this module AFTER setting $global:__YurunaLogFile to the desired
    log file path. Each proxy calls the real cmdlet (qualified with
    Microsoft.PowerShell.Utility\) and appends a tagged line to the
    log file. Remove-Module yuruna-log restores the original cmdlets.
#>

# ── Write-Output ────────────────────────────────────────────────────────────

function Write-Output {
    <#
    .SYNOPSIS
        Proxy for Write-Output that also appends to the active log file.
    #>
    [CmdletBinding(DefaultParameterSetName = 'NoEnumerate')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [System.Object[]]$InputObject,

        [Parameter()]
        [switch]$NoEnumerate
    )
    process {
        if ($global:__YurunaLogFile) {
            foreach ($item in $InputObject) {
                [System.Net.WebUtility]::HtmlEncode("$item") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
            }
        }
        Microsoft.PowerShell.Utility\Write-Output -InputObject $InputObject -NoEnumerate:$NoEnumerate
    }
}

# ── Write-Error ─────────────────────────────────────────────────────────────

function Write-Error {
    <#
    .SYNOPSIS
        Proxy for Write-Error that also appends to the active log file.
    #>
    [CmdletBinding(DefaultParameterSetName = 'NoException')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'NoException', ValueFromPipeline = $true)]
        [Parameter(ParameterSetName = 'WithException')]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message,

        [Parameter(ParameterSetName = 'WithException', Mandatory = $true)]
        [System.Exception]$Exception,

        [Parameter()]
        [System.Management.Automation.ErrorCategory]$Category = [System.Management.Automation.ErrorCategory]::NotSpecified,

        [Parameter()]
        [string]$ErrorId,

        [Parameter()]
        [System.Object]$TargetObject,

        [Parameter()]
        [string]$RecommendedAction,

        [Parameter()]
        [string]$CategoryActivity,

        [Parameter()]
        [string]$CategoryReason,

        [Parameter()]
        [string]$CategoryTargetName,

        [Parameter()]
        [string]$CategoryTargetType
    )
    process {
        if ($global:__YurunaLogFile) {
            $text = if ($Message) { $Message } elseif ($Exception) { $Exception.Message } else { '' }
            [System.Net.WebUtility]::HtmlEncode("ERROR: $text") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }
        $PSBoundParameters.Remove('InputObject') | Out-Null
        Microsoft.PowerShell.Utility\Write-Error @PSBoundParameters
    }
}

# ── Write-Warning ───────────────────────────────────────────────────────────

function Write-Warning {
    <#
    .SYNOPSIS
        Proxy for Write-Warning that also appends to the active log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile) {
            [System.Net.WebUtility]::HtmlEncode("WARNING: $Message") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }
        Microsoft.PowerShell.Utility\Write-Warning -Message $Message
    }
}

# ── Write-Debug ─────────────────────────────────────────────────────────────

function Write-Debug {
    <#
    .SYNOPSIS
        Proxy for Write-Debug that also appends to the active log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile) {
            [System.Net.WebUtility]::HtmlEncode("DEBUG: $Message") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }
        Microsoft.PowerShell.Utility\Write-Debug -Message $Message
    }
}

# ── Write-Verbose ───────────────────────────────────────────────────────────

function Write-Verbose {
    <#
    .SYNOPSIS
        Proxy for Write-Verbose that also appends to the active log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile) {
            # VERBOSE entries are indented one tab deeper than DEBUG entries
            # in the log file, making the log hierarchy easier to scan.
            [System.Net.WebUtility]::HtmlEncode("    VERBOSE: $Message") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }
        Microsoft.PowerShell.Utility\Write-Verbose -Message $Message
    }
}

# ── Write-Information ───────────────────────────────────────────────────────

function Write-Information {
    <#
    .SYNOPSIS
        Proxy for Write-Information that also appends to the active log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowNull()]
        [System.Object]$MessageData,

        [Parameter(Position = 1)]
        [string[]]$Tags
    )
    process {
        if ($global:__YurunaLogFile) {
            [System.Net.WebUtility]::HtmlEncode("INFO: $MessageData") | Out-File -FilePath $global:__YurunaLogFile -Append -ErrorAction SilentlyContinue
        }
        $params = @{ MessageData = $MessageData }
        if ($Tags) { $params['Tags'] = $Tags }
        Microsoft.PowerShell.Utility\Write-Information @params
    }
}

Export-ModuleMember -Function Write-Output, Write-Error, Write-Warning, Write-Debug, Write-Verbose, Write-Information
