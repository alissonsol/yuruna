<#PSScriptInfo
.VERSION 2026.09.24
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
    Host-neutral entry point. Detects the host type and runs that host's
    Enable-TestAutomation.ps1 in a child pwsh rooted in its own folder; this
    shell stays in test/. Arguments are forwarded verbatim and the child's exit
    code is returned.

    What actually gets configured -- display sleep, screen lock, the hypervisor
    service, host firewall rules -- differs per host and is documented and owned
    by the per-host script:

        host/windows.hyper-v/Enable-TestAutomation.ps1   (needs Administrator)
        host/macos.utm/Enable-TestAutomation.ps1         (asks for sudo)
        host/ubuntu.kvm/Enable-TestAutomation.ps1        (asks for sudo)

    Idempotent, because they are: safe to re-run.
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
# The per-host Enable-TestAutomation.ps1 is an advanced script and narrates
# each decision under -Verbose, so pass the switch on when it was asked for;
# it binds to this redirector as a common parameter and would otherwise stop
# here. A level of Verbose or Debug asks for the same narration by another
# name, and the switch is what the child binds -- the env var alone would only
# reach the per-host script's own preferences, not its -Verbose-gated output.
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
