<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42c6e83b-159d-4f27-8a0e-6b7d2c4901fa
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization localization publish gate regenerate
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
    Regenerate, verify and gate a tree that has just received a localization.
.DESCRIPTION
    Placing translated text is not the same as shipping it. The compiled
    per-runtime catalogs have to be rebuilt from the new sources, the browsers
    have to receive them, the whole-text inventory has to be regenerated, and
    every gate that protects the globalization tree has to be asked again.

    This runs the tools that already own each of those jobs. It does not
    reimplement any of them: a second implementation of catalog validation
    would diverge from the authoritative one, and only one of the two would be
    gating anything.

    The sequence is declared as data so a step cannot be quietly dropped. Each
    step names the tool it runs and whether it writes or only checks.
.PARAMETER Root
    Framework repository root. Defaults to the parent of this script.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree.
.PARAMETER SkipGate
    Stop after the regeneration and verification steps, without running the
    full cross-repository gate.
.PARAMETER ListOnly
    Report the declared sequence and exit without running anything.
.PARAMETER Quiet
    Report only the summary line and any failure.
.OUTPUTS
    One line per step. Exit 0 when every step passed, 2 when one failed.
.EXAMPLE
    pwsh tools/Publish-Localization.ps1
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Quiet is read by the private Write-Line helper; ScriptAnalyzer does not follow that dynamic script scope.')]
param(
    [string]$Root,
    [string]$ProjectRoot,
    [switch]$SkipGate,
    [switch]$ListOnly,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $Root) 'yuruna-project' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

$script:PowerShellPath = (Get-Process -Id $PID).Path

function Write-Line {
    param([string]$Text = '')
    if (-not $Quiet) { Write-Information $Text -InformationAction Continue }
}

# The published sequence. Regeneration comes first because every check below it
# reads what it produces; a check that ran against stale generated artifacts
# would pass on text nobody ships.
$script:Step = @(
    [ordered]@{ name = 'catalog-compile'; tool = 'tools/Invoke-CatalogCompile.ps1'; arguments = @('-Update'); writes = $true
        purpose = 'rebuild the per-runtime catalogs from the source catalogs'
    }
    [ordered]@{ name = 'catalog-embed'; tool = 'tools/Invoke-CatalogEmbed.ps1'; arguments = @(); writes = $true
        purpose = 'copy the kernel, locale data and default tables into every browser runtime'
    }
    [ordered]@{ name = 'domain-inventory'; tool = 'tools/Invoke-DomainInventory.ps1'; arguments = @('-Update'); writes = $true
        purpose = 'regenerate the whole-text inventory that any prose edit stales'
    }
    [ordered]@{ name = 'utf8-catalog'; tool = 'tools/Test-Utf8Catalog.ps1'; arguments = @(); writes = $false
        purpose = 'hold the globalization tree to normalized, BOM-less UTF-8'
    }
    [ordered]@{ name = 'terminology'; tool = 'tools/Test-Terminology.ps1'; arguments = @('-RequireApproved'); writes = $false
        purpose = 'prove the glossary and style guide are approved and content-bound'
    }
    [ordered]@{ name = 'doc-translation'; tool = 'tools/Test-DocTranslation.ps1'; arguments = @('-RequireReviewed'); writes = $false
        purpose = 'prove every mapped document is source-current and reviewed'
    }
    [ordered]@{ name = 'project-locale-map'; tool = 'tools/Invoke-ProjectLocaleMap.ps1'; arguments = @(); writes = $false
        purpose = 'validate the project display maps and their source hashes'
    }
    [ordered]@{ name = 'reference-fixture'; tool = 'tools/Invoke-ReferenceFixture.ps1'; arguments = @(); writes = $false
        purpose = 'prove the recorded English still matches what the producers emit'
    }
    [ordered]@{ name = 'cross-repo-gate'; tool = 'tools/Invoke-CrossRepoGate.ps1'; arguments = @('-Mode', 'full'); writes = $false
        purpose = 'run the authoritative aggregate over both repositories'
    }
)

function Get-PublishStep {
    <#
    .SYNOPSIS
        The declared sequence, so a caller can prove none of it was dropped.
    .OUTPUTS
        [object[]]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @($script:Step)
}

if ($ListOnly) {
    foreach ($step in $script:Step) {
        Write-Output ('{0,-20} {1,-40} {2}' -f [string]$step.name, [string]$step.tool,
            $(if ([bool]$step.writes) { 'writes' } else { 'checks' }))
    }
    exit 0
}

if (-not $PSCmdlet.ShouldProcess("$Root and $ProjectRoot", 'regenerate localization artifacts and run the owned gates')) { exit 0 }

$failed = [Collections.Generic.List[string]]::new()
$ran = 0
foreach ($step in $script:Step) {
    $name = [string]$step.name
    if ($SkipGate -and $name -ceq 'cross-repo-gate') {
        Write-Line ('skip   {0,-20} the full gate was not asked for' -f $name)
        continue
    }
    $path = Join-Path $Root ([string]$step.tool)
    if (-not [IO.File]::Exists($path)) {
        $failed.Add("${name}: its tool is missing at $path")
        continue
    }
    $arguments = [string[]]@('-NoProfile', '-File', $path) + [string[]]@($step.arguments)
    # Only the tools that read the paired checkout are told about it; the rest
    # would refuse an argument they do not declare.
    if ($name -in 'domain-inventory', 'doc-translation', 'project-locale-map', 'reference-fixture', 'cross-repo-gate') {
        $arguments += @('-ProjectRoot', $ProjectRoot)
    }
    $global:LASTEXITCODE = 0
    $output = (& $script:PowerShellPath @arguments 2>&1 | Out-String).Trim()
    $code = $LASTEXITCODE
    $ran++
    if ($step.writes -and $code -in @(0, 1)) {
        $verifyArguments = @($arguments | Where-Object { $_ -cne '-Update' }) + '-Check'
        $verification = (& $script:PowerShellPath @verifyArguments 2>&1 | Out-String).Trim()
        $code = $LASTEXITCODE
        if ($code -ne 0) { $output += "`n" + $verification }
    }
    if ($code -eq 0) {
        Write-Line ('ok     {0,-20} {1}' -f $name, [string]$step.purpose)
        continue
    }
    $failed.Add("${name}: exit $code")
    Write-Warning ('{0} failed (exit {1}):{2}{3}' -f $name, $code, [Environment]::NewLine, $output)
    break
}

foreach ($problem in $failed) { Write-Warning $problem }
Write-Output ('Publish-Localization: {0} step(s) ran, {1} failed.' -f $ran, $failed.Count)
if ($failed.Count -gt 0) { exit 2 }
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
