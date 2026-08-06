<#PSScriptInfo
.VERSION 2026.08.06
.GUID 421e5a04-9d3b-4c8e-b6a1-2f0d84e5c913
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host disable-test-automation
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
    Put this host's settings back the way Enable-TestAutomation found them.
.DESCRIPTION
    Host-neutral entry point, mirroring Enable-TestAutomation.ps1. Detects the
    host type and runs that host's Disable-TestAutomation.ps1 in a child pwsh
    rooted in its own folder; arguments are forwarded verbatim and the child's
    exit code is returned.

    What is restored comes from the capture Enable wrote before it changed
    anything (status/runtime/host.pre-automation.json). On a host enabled before
    that capture existed, only what is additive AND provably ours is reversed --
    the status-port firewall rule and the Yuruna ICMP rule. Everything else is
    printed as a command to run by hand rather than guessed at.

    Deliberately NOT reversed, and reported instead: installed packages, PSGallery
    modules, macOS TCC grants, the credential vault, cloned repos / VM images /
    history, the vmms and W32Time services, and everything the networkStorage
    questionnaire wrote (config keys, vaulted credential, mounts). Tearing down
    storage on a "disable settings" is a surprise, so it is offered as explicit
    commands.

        host/windows.hyper-v/Disable-TestAutomation.ps1   (needs Administrator)
        host/macos.utm/Disable-TestAutomation.ps1         (asks for sudo)
        host/ubuntu.kvm/Disable-TestAutomation.ps1        (asks for sudo)

    Idempotent: safe to re-run.
.PARAMETER RemainingArguments
    Anything not declared here is forwarded to the per-host script verbatim
    (-WhatIf and -StopServices among them), so a parameter added there needs no
    edit here.
.EXAMPLE
    pwsh test/Disable-TestAutomation.ps1
.EXAMPLE
    pwsh test/Disable-TestAutomation.ps1 -WhatIf
    Show what would be restored, without changing anything.
.EXAMPLE
    pwsh test/Disable-TestAutomation.ps1 -StopServices
    Also stop the caching-proxy, stash, pool-control and download-agent VMs
    this host runs.
#>

param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking

# The per-host script narrates each decision under -Verbose; -Verbose binds to
# this redirector as a common parameter and would otherwise stop here.
$extra = @()
if ($PSBoundParameters.ContainsKey('Verbose')) { $extra += '-Verbose' }

$forwarded = @(ConvertTo-HostScriptArgument `
    -BoundParameters $PSBoundParameters `
    -RemainingArguments $RemainingArguments `
    -Exclude 'RemainingArguments' `
    -ExtraArgument $extra)

Invoke-YurunaHostScript -ScriptName 'Disable-TestAutomation.ps1' -ArgumentList $forwarded

exit ([int]$LASTEXITCODE)
