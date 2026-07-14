<#PSScriptInfo
.VERSION 2026.07.14
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
        Names that exist in $Parameters but must NOT be forwarded -- e.g.
        outer-only switches like -NoConfigGate that the inner does not
        accept.
    .OUTPUTS
        [string[]] -- pass with @ splatting to `& $pwshExe`.
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
    .DESCRIPTION
        Resolution order, most reliable first:
          1. [Environment]::ProcessPath - the real executable image that
             started this process (macOS _NSGetExecutablePath, Linux
             /proc/self/exe, Windows post-alias-resolution path, so it
             never hands back the zero-byte WindowsApps app-execution-alias
             stub -- see feedback_windows_appalias_firewall_trap.md). Absent
             on PS 7.0/7.1 (.NET below 6); the try/catch keeps it null there
             (even under Set-StrictMode) instead of throwing, so resolution
             falls through.
          2. (Get-Process -Id $PID).Path - it equals MainModule.FileName,
             which is null/empty on macOS (no /proc; libproc only best-effort
             populates MainModule) and can throw on protected processes, so it
             is wrapped too. This is the value the rest of the chain exists to
             survive.
          3. $PSHOME/pwsh[.exe] - the install dir of the running runtime,
             always populated under #requires -version 7. Test-Path before
             use so a stale path is never handed to the & call operator.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $exe = $null
    try { $exe = [Environment]::ProcessPath } catch { $exe = $null }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        try { $exe = (Get-Process -Id $PID).Path } catch { $exe = $null }
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        $leaf      = $IsWindows ? 'pwsh.exe' : 'pwsh'
        $candidate = Join-Path $PSHOME $leaf
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    return $exe
}

Export-ModuleMember -Function New-InnerRunnerArgList, Get-PwshExePath
