<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a7b8c9-d0e1-4f23-9456-78a9b0c1d2e3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host bootstrap enable-test-automation
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
    Shared bootstrap for every host-platform Enable-TestAutomation.ps1.
.DESCRIPTION
    Three platform scripts ([host/windows.hyper-v/Enable-TestAutomation.ps1](../host/windows.hyper-v/Enable-TestAutomation.ps1),
    [host/macos.utm/Enable-TestAutomation.ps1](../host/macos.utm/Enable-TestAutomation.ps1),
    [host/ubuntu.kvm/Enable-TestAutomation.ps1](../host/ubuntu.kvm/Enable-TestAutomation.ps1))
    otherwise each hand-roll the same 10-line bootstrap: locate Test.HostContract.psm1
    two folders up, suppress -Verbose echo during the import, then install
    powershell-yaml + PSScriptAnalyzer so the cycle planner and the lint
    gate can resolve their dependencies. A new prerequisite would then need
    three identical edits. This module collapses the bootstrap into a single
    call so a new prerequisite is one edit.

    Linux callers also need to prime sudo BEFORE the long
    `Install-PowerShellYamlIfMissing` step so the password prompt fires
    early (with reason banner) instead of after a silent 30-second wait
    -- the `-SudoCacheReason` parameter wires that in without forcing
    every caller to know about Initialize-SudoCache.
#>

function Initialize-HostSetupModule {
    <#
    .SYNOPSIS
        Import Test.HostContract.psm1, optionally prime sudo, then install
        powershell-yaml and PSScriptAnalyzer.
    .PARAMETER RepoRoot
        Absolute path to the repository root. Callers compute this as
        `Split-Path -Parent (Split-Path -Parent $PSScriptRoot)` because
        every Enable-TestAutomation.ps1 lives at
        host/&lt;short&gt;/Enable-TestAutomation.ps1.
    .PARAMETER BoundParameters
        Caller's $PSBoundParameters. Forwarded to Install-* helpers so
        -WhatIf reaches the install step (otherwise -WhatIf on the entry
        point script wouldn't suppress the actual Install-Module call).
    .PARAMETER SudoCacheReason
        When set, Initialize-SudoCache runs after the contract import and
        before the install pair. The reasons list shows in the prompt
        banner so the operator sees WHAT will need sudo before they
        consent. Linux only; pass on the others and Initialize-SudoCache
        becomes a no-op anyway, but the explicit guard documents intent.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Forwards to Install-* helpers that gate writes via their own ShouldProcess.')]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [hashtable]$BoundParameters = @{},
        [string[]]$SudoCacheReason
    )
    if (-not $PSCmdlet.ShouldProcess('Yuruna host bootstrap', 'Import Test.HostContract + install powershell-yaml + PSScriptAnalyzer')) {
        return
    }
    $modulePath = Join-Path $RepoRoot (Join-Path 'test' (Join-Path 'modules' 'Test.HostContract.psm1'))
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw "Test.HostContract.psm1 not found at: $modulePath"
    }
    # The contract facade re-imports four siblings with -Global; without
    # silencing -Verbose here, each one prints "Importing module..." and
    # buries Enable-TestAutomation's per-setting action lines under
    # framework noise.
    $savedVerbose = $global:VerbosePreference
    $global:VerbosePreference = 'SilentlyContinue'
    try {
        Import-Module -Name $modulePath -Force
    } finally {
        $global:VerbosePreference = $savedVerbose
    }
    if ($SudoCacheReason -and $SudoCacheReason.Count -gt 0) {
        if (Get-Command Initialize-SudoCache -ErrorAction SilentlyContinue) {
            [void](Initialize-SudoCache -Reasons $SudoCacheReason)
        }
    }
    # Cycle planner reads project/test/test.runner.yml + every per-
    # sequence baseline via powershell-yaml. Missing it -> Resolve-CyclePlan
    # throws -> inner runner falls back to legacy guestSequence -> Start-
    # GuestOS runs with an empty sequence list and is recorded as
    # "skipped" with no log trace. PSScriptAnalyzer is the pre-commit
    # lint gate so the same enable step bootstraps both runtime and CI.
    [void](Install-PowerShellYamlIfMissing @BoundParameters)
    [void](Install-PSScriptAnalyzerIfMissing @BoundParameters)
}

Export-ModuleMember -Function Initialize-HostSetupModule
