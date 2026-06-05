<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456791
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = '$global:__YurunaLogFile is the cross-module log-file handle this proxy module reads inside every Write-* override to mirror console output to the per-cycle HTML transcript.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
    Justification = 'Intentionally overrides Write-Output / Write-Error / Write-Warning / Write-Debug / Write-Verbose / Write-Information so each call forwards to Microsoft.PowerShell.Utility\Write-* AND appends an HTML-encoded copy to the per-cycle log. Module is loaded by the runner; Remove-Module restores the originals.')]
param()

<#
.SYNOPSIS
    Proxy module that overrides Write-Output/Error/Warning/Debug/Verbose/Information
    so every message is also appended to a log file.

.DESCRIPTION
    Import this module AFTER setting $global:__YurunaLogFile to the desired
    log file path. Each proxy calls the real cmdlet (qualified with
    Microsoft.PowerShell.Utility\) and appends a tagged line to the log.
    Remove-Module Yuruna.Log restores the original cmdlets.

    One of THREE Yuruna logger modules with disjoint responsibilities --
    see test/modules/README.md "Three loggers, three jobs" before adding
    helpers here. Sibling modules: Test.Log (cycle-filesystem owner) and
    Test.Output (per-script PASS/FAIL tally). This module owns ONLY the
    tee mechanism; don't add Start-* / Write-Pass / cycle-folder helpers
    here -- they belong in the other two.
#>

function Write-Output {
    <#
    .SYNOPSIS
        Proxy for Write-Output that also appends each object to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Output and writes an
        HTML-encoded copy of each $InputObject to $global:__YurunaLogFile.
    .PARAMETER InputObject
        Objects to emit to the pipeline and log.
    .PARAMETER NoEnumerate
        Passed through to the underlying Write-Output.
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
            # AppendAllText preserves Out-File's open/write/close per-call
            # durability without paying the PowerShell pipeline + Out-File
            # cmdlet overhead. The thousands of Write-* calls per cycle add up.
            foreach ($item in $InputObject) {
                try {
                    [System.IO.File]::AppendAllText(
                        $global:__YurunaLogFile,
                        [System.Net.WebUtility]::HtmlEncode("$item") + [Environment]::NewLine)
                } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
            }
        }
        Microsoft.PowerShell.Utility\Write-Output -InputObject $InputObject -NoEnumerate:$NoEnumerate
    }
}

function Write-Error {
    <#
    .SYNOPSIS
        Proxy for Write-Error that also appends the error text to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Error and writes the
        HTML-encoded message text (no level prefix) to $global:__YurunaLogFile.
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
            try {
                [System.IO.File]::AppendAllText(
                    $global:__YurunaLogFile,
                    [System.Net.WebUtility]::HtmlEncode($text) + [Environment]::NewLine)
            } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
        }
        $PSBoundParameters.Remove('InputObject') | Out-Null
        Microsoft.PowerShell.Utility\Write-Error @PSBoundParameters
    }
}

function Write-Warning {
    <#
    .SYNOPSIS
        Proxy for Write-Warning that also appends the message to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Warning and writes the
        HTML-encoded message text (no level prefix) to $global:__YurunaLogFile
        -- but only when $WarningPreference is anything other than
        SilentlyContinue, so the transcript mirrors the console (Information /
        Verbose / Debug follow the same gating).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile -and $global:WarningPreference -ne 'SilentlyContinue') {
            try {
                [System.IO.File]::AppendAllText(
                    $global:__YurunaLogFile,
                    [System.Net.WebUtility]::HtmlEncode($Message) + [Environment]::NewLine)
            } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
        }
        Microsoft.PowerShell.Utility\Write-Warning -Message $Message
    }
}

function Write-Debug {
    <#
    .SYNOPSIS
        Proxy for Write-Debug that also appends the message to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Debug and writes the
        HTML-encoded message text (no level prefix) to $global:__YurunaLogFile
        -- but only when $DebugPreference is anything other than
        SilentlyContinue (see Write-Warning for the rationale).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile -and $global:DebugPreference -ne 'SilentlyContinue') {
            try {
                [System.IO.File]::AppendAllText(
                    $global:__YurunaLogFile,
                    [System.Net.WebUtility]::HtmlEncode($Message) + [Environment]::NewLine)
            } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
        }
        Microsoft.PowerShell.Utility\Write-Debug -Message $Message
    }
}

function Write-Verbose {
    <#
    .SYNOPSIS
        Proxy for Write-Verbose that also appends the message to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Verbose and writes the
        HTML-encoded message text (no level prefix) to $global:__YurunaLogFile
        -- but only when $VerbosePreference is anything other than
        SilentlyContinue (see Write-Warning for the rationale).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile -and $global:VerbosePreference -ne 'SilentlyContinue') {
            try {
                [System.IO.File]::AppendAllText(
                    $global:__YurunaLogFile,
                    [System.Net.WebUtility]::HtmlEncode($Message) + [Environment]::NewLine)
            } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
        }
        Microsoft.PowerShell.Utility\Write-Verbose -Message $Message
    }
}

function Write-Information {
    <#
    .SYNOPSIS
        Proxy for Write-Information that also appends the message to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Information and writes
        the HTML-encoded message text (no level prefix) to
        $global:__YurunaLogFile -- but only when $InformationPreference is
        anything other than SilentlyContinue, so the transcript mirrors the
        console (Verbose / Debug follow the same gating).
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
        if ($global:__YurunaLogFile -and $global:InformationPreference -ne 'SilentlyContinue') {
            try {
                [System.IO.File]::AppendAllText(
                    $global:__YurunaLogFile,
                    [System.Net.WebUtility]::HtmlEncode("$MessageData") + [Environment]::NewLine)
            } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
        }
        $params = @{ MessageData = $MessageData }
        if ($Tags) { $params['Tags'] = $Tags }
        Microsoft.PowerShell.Utility\Write-Information @params
    }
}

Export-ModuleMember -Function Write-Output, Write-Error, Write-Warning, Write-Debug, Write-Verbose, Write-Information
