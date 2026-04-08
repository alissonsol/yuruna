<#PSScriptInfo
.VERSION 0.1
.GUID 42d4e5f6-a7b8-4c90-d1e2-3f4a5b6c7d8e
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Invoke-DynamicExpression
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

function Invoke-DynamicExpression {
    <#
    .SYNOPSIS
        Wrapper around Invoke-Expression that centralises the PSScriptAnalyzer suppression.
    .DESCRIPTION
        Executes a string as a PowerShell command. This thin wrapper exists so that
        every call site in the automation folder does not individually trigger the
        PSAvoidUsingInvokeExpression rule. The suppression is applied once here.
    .PARAMETER Command
        The command string to execute.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '')]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )
    Invoke-Expression $Command
}

Export-ModuleMember -Function Invoke-DynamicExpression
