<#PSScriptInfo
.VERSION 2026.09.01
.GUID 4287f46e-5ba2-4906-90c2-0552b5108eec
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
        Wrapper around Invoke-Expression that centralizes the PSScriptAnalyzer
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
