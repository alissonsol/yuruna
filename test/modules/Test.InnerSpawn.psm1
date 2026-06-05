<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456722
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

# Canonical builder for the pwsh argv list that launches a fresh child
# pwsh running a single PowerShell script with typed parameters.
# Why -Command (not -File):
#   pwsh's -File parameter binder coerces every argv token to [string],
#   which breaks [bool]/[int] inner parameters. -Command parses the line
#   as PowerShell so $true/$false/0/1 keep their types.
# Why -NoProfile:
#   $PROFILE in the launching shell can re-set YURUNA_* env vars in the
#   child AFTER the parent's snapshot pinned the right values.
# Why a helper module:
#   The same single-quote escaping + -Command construction lived in both
#   Invoke-TestRunner.ps1 and Test-Project.ps1; a quoting-edge-case fix in
#   one wouldn't reach the other.

function New-InnerRunnerArgList {
    <#
    .SYNOPSIS
        Build the @('-NoLogo','-NoProfile','-Command', "& '<script>' -A 'b' ...") array used to spawn a child pwsh that runs $ScriptPath with typed parameters.
    .DESCRIPTION
        Escapes single quotes by doubling them. Preserves [bool] / [int] /
        [double] / [SwitchParameter] types by emitting the appropriate
        literal form. The caller invokes pwsh with the returned array:
            & $pwshExe @argList
    .PARAMETER ScriptPath
        Absolute path to the .ps1 to run.
    .PARAMETER Parameters
        Hashtable or IDictionary of parameter name -> value. Switch
        parameters are emitted only when present (and IsPresent=$true).
        Bool / int / double values are emitted as PowerShell literals so
        the binder preserves the type.
    .PARAMETER ExcludeParameter
        Names that exist in $Parameters but must NOT be forwarded — e.g.
        outer-only switches like -NoConfigGate that the inner does not
        accept.
    .OUTPUTS
        [string[]] — pass with @ splatting to `& $pwshExe`.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Pure builder; no externally observable state change.')]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Parameters,
        [string[]]$ExcludeParameter = @()
    )
    $escapedScript = $ScriptPath -replace "'", "''"
    $cmdParts = @("& '$escapedScript'")
    foreach ($k in $Parameters.Keys) {
        if ($ExcludeParameter -contains $k) { continue }
        $v = $Parameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $cmdParts += "-$k" }
        } elseif ($v -is [bool]) {
            $cmdParts += "-$k"
            $cmdParts += $(if ($v) { '$true' } else { '$false' })
        } elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) {
            $cmdParts += "-$k"
            $cmdParts += "$v"
        } else {
            $escaped = ("$v") -replace "'", "''"
            $cmdParts += "-$k"
            $cmdParts += "'$escaped'"
        }
    }
    return @('-NoLogo', '-NoProfile', '-Command', ($cmdParts -join ' '))
}

function Get-PwshExePath {
    <#
    .SYNOPSIS
        Returns the path of the currently running pwsh binary so a child
        spawn uses the same edition (PS 7.x) as the parent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Get-Process -Id $PID).Path
}

Export-ModuleMember -Function New-InnerRunnerArgList, Get-PwshExePath
