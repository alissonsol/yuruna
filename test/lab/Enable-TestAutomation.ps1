<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42c12fdb-b2fc-4001-bd06-428aef0695a7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host enable-test-automation
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

<#
.SYNOPSIS
    Prepare THIS host to run yuruna automated VM tests, whatever host it is.
.DESCRIPTION
    See https://yuruna.link/42010605-0003.
.PARAMETER RemainingArguments
    Anything not declared here is forwarded to the per-host script verbatim
    (-WhatIf among them), so a parameter added there needs no edit here.
.EXAMPLE
    pwsh test/lab/Enable-TestAutomation.ps1
.EXAMPLE
    pwsh test/lab/Enable-TestAutomation.ps1 -WhatIf
    Show what the per-host script would change, without changing it.
#>

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

# --- REGION: Log level from environment
# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1). See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv

# --- REGION: Shared bootstrap
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking

# --- REGION: Common-parameter relay
# See https://yuruna.link/42010605-0003
$extra = @()
if ($PSBoundParameters.ContainsKey('Verbose') -or $VerbosePreference -eq 'Continue') { $extra += '-Verbose' }

# --- REGION: Delegate to the per-host script
$forwarded = @(ConvertTo-HostScriptArgument `
    -BoundParameters $PSBoundParameters `
    -RemainingArguments $RemainingArguments `
    -Exclude 'RemainingArguments' `
    -ExtraArgument $extra)

Invoke-YurunaHostScript -ScriptName 'Enable-TestAutomation.ps1' -ArgumentList $forwarded

exit ([int]$LASTEXITCODE)
