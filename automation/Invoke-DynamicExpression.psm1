<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42d4e5f6-a7b8-4c90-d1e2-3f4a5b6c7d8e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Invoke-DynamicExpression
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

function Invoke-DynamicExpression {
    <#
    .SYNOPSIS
        Wrapper around Invoke-Expression that centralises the PSScriptAnalyzer
        suppression so callers don't each trigger PSAvoidUsingInvokeExpression.
    .PARAMETER Command
        The command string to execute.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
        Justification = 'The function''s purpose is to invoke a dynamically constructed expression string; Invoke-Expression is the intended mechanism.')]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )
    Invoke-Expression $Command
}

Export-ModuleMember -Function Invoke-DynamicExpression
