<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42abb186-f4b8-4269-9bed-8d5f24f258e5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host cleanup
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
    Delete VM files on THIS host that no longer belong to a registered VM.
.DESCRIPTION
    Host-neutral entry point. Detects the host type and runs that host's
    Remove-OrphanedVMFiles.ps1 in a child pwsh rooted in its own folder; this
    shell stays in test/. Arguments are forwarded verbatim and the child's exit
    code is returned.

    What counts as orphaned differs per host and is owned by the per-host
    script:

        host/windows.hyper-v/Remove-OrphanedVMFiles.ps1  (needs Administrator)
        host/macos.utm/Remove-OrphanedVMFiles.ps1
        host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1

    DESTRUCTIVE, and it prompts for confirmation unless -Force is given.

    This only sweeps FILES left behind by VMs that are already gone. To tear
    down the test VMs themselves and then sweep, use Remove-TestVMFiles.ps1 in
    this folder -- it stops and unregisters every VM matching the test prefix
    and calls this same per-host script afterwards.
.PARAMETER Force
    Skip the confirmation prompt.
.PARAMETER Quiet
    Suppress the per-file cleanup log and this script's own banner. Warnings and
    errors are still shown: they always mean something the operator needs.
.PARAMETER RemainingArguments
    Anything not declared here is forwarded to the per-host script verbatim, so
    a parameter added there needs no edit here.
.NOTES
    -Verbose has no effect here, unlike the Enable/Disable-TestAutomation
    redirectors in this folder. Those relay the switch because their per-host
    scripts narrate each decision; the per-host Remove-OrphanedVMFiles.ps1
    scripts emit no verbose stream, so there is nothing to turn on. -Verbose
    still binds -- declaring RemainingArguments makes this an advanced script --
    it simply does not reach the child. Use -Quiet to go the other way and
    suppress the per-file cleanup log.
.EXAMPLE
    pwsh test/lab/Remove-OrphanedVMFiles.ps1
.EXAMPLE
    pwsh test/lab/Remove-OrphanedVMFiles.ps1 -Force -Quiet
#>

param(
    [switch]$Force,
    [switch]$Quiet,

    [Parameter(ValueFromRemainingArguments)]
    [string[]]$RemainingArguments
)

$ErrorActionPreference = 'Stop'

# --- REGION: Shared bootstrap
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking

# --- REGION: Delegate to the per-host script
$forwarded = @(ConvertTo-HostScriptArgument `
    -BoundParameters $PSBoundParameters `
    -RemainingArguments $RemainingArguments `
    -Exclude 'RemainingArguments')

# -Quiet also silences the redirector's own banner, so an automated caller gets
# the per-host script's output and nothing else.
Invoke-YurunaHostScript -ScriptName 'Remove-OrphanedVMFiles.ps1' -ArgumentList $forwarded -Quiet:$Quiet

exit ([int]$LASTEXITCODE)
