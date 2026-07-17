<#PSScriptInfo
.VERSION 2026.07.17
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

# Append one already-stringified line to the per-cycle transcript. AppendAllText
# preserves Out-File's open/write/close per-call durability without paying the
# PowerShell pipeline + Out-File cmdlet overhead -- the thousands of Write-* calls
# per cycle add up. A failed append is non-fatal (swallowed to Verbose) so logging
# never breaks the caller. The catch uses the fully-qualified
# Microsoft.PowerShell.Utility\Write-Verbose to bypass this module's own override.
#
# Severity is stamped as a CSS class on a wrapping <span> so the same transcript
# is both eye-scannable (a stylesheet can colour errors/warnings) and machine-
# filterable (a reader can select `.log-error` / `.log-warning` records) without
# reparsing free text. Only the message body is HtmlEncode'd; the span markup is
# emitted verbatim so it renders as an element rather than as escaped angle
# brackets inside the <pre>. An unknown/empty severity degrades to the neutral
# 'log-output' class rather than dropping the record -- the tag is additive and
# never gates whether a line is written.
function Add-YurunaLogLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('output', 'error', 'warning', 'information', 'verbose', 'debug')]
        [string]$Severity = 'output'
    )
    if (-not $global:__YurunaLogFile) { return }
    try {
        $encoded = [System.Net.WebUtility]::HtmlEncode($Text)
        $line = "<span class=`"log-$Severity`">$encoded</span>" + [Environment]::NewLine
        [System.IO.File]::AppendAllText($global:__YurunaLogFile, $line)
    } catch { Microsoft.PowerShell.Utility\Write-Verbose "Yuruna.Log append failed (non-fatal): $($_.Exception.Message)" }
}

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
            foreach ($item in $InputObject) {
                Add-YurunaLogLine "$item" -Severity 'output'
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
            Add-YurunaLogLine $text -Severity 'error'
        }
        # Splat the caller's own bound parameters straight through. This proxy's
        # parameter sets mirror Write-Error's (NoException = Message,
        # WithException = Exception [+ optional Message]), so $PSBoundParameters
        # is always a valid Write-Error invocation and never a Message+Exception
        # combination Write-Error rejects. Forwarding it verbatim also preserves
        # the common parameters (-ErrorAction, -ErrorVariable, ...) that an
        # explicit per-set reconstruction would silently drop. (There is no
        # InputObject parameter here to strip -- this is Write-Error, not the
        # Write-Output proxy.)
        Microsoft.PowerShell.Utility\Write-Error @PSBoundParameters
    }
}

function Write-Warning {
    <#
    .SYNOPSIS
        Proxy for Write-Warning that also appends the message to the log file.
    .DESCRIPTION
        Forwards to Microsoft.PowerShell.Utility\Write-Warning and writes the
        HTML-encoded message text (tagged with the log-warning class) to
        $global:__YurunaLogFile. The transcript append is UNCONDITIONAL: a
        warning is durable evidence of something the operator needs to see, so
        it must persist in the HTML transcript even when the console is quiet
        (WarningPreference=SilentlyContinue at a low logLevel). Gating the
        mirror on console verbosity would silently erase warnings from the very
        artifact kept for post-hoc triage. The Information / Verbose / Debug
        proxies still gate on their preferences -- those streams are chatty
        progress noise, not evidence -- but a warning always reaches the file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Message
    )
    process {
        if ($global:__YurunaLogFile) {
            Add-YurunaLogLine $Message -Severity 'warning'
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
            Add-YurunaLogLine $Message -Severity 'debug'
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
            Add-YurunaLogLine $Message -Severity 'verbose'
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
            Add-YurunaLogLine "$MessageData" -Severity 'information'
        }
        $params = @{ MessageData = $MessageData }
        if ($Tags) { $params['Tags'] = $Tags }
        Microsoft.PowerShell.Utility\Write-Information @params
    }
}

Export-ModuleMember -Function Write-Output, Write-Error, Write-Warning, Write-Debug, Write-Verbose, Write-Information
