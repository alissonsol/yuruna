<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42334b95-2008-4677-826c-ab608200e5bf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation teardown pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Guards the teardown contract between Set-Resource and Clear-Configuration:
    resources.output.yml carries one top-level key per deployed resource, and
    teardown must enumerate exactly those keys.
.DESCRIPTION
    Set-Resource writes resources.output.yml as a `globalVariables` map plus one
    `<expandedResourceName>: <tofu outputs>` block per resource it created. It
    never writes a `resources:` list -- that shape belongs to the forward
    resources.yml. Selecting `$yaml.resources` here therefore always yields null,
    which makes Clear-Configuration report a clean teardown while destroying
    nothing and leaving the real cloud resources running: a silent no-op that
    costs money and looks like success.

    The fixtures below build resources.output.yml through the same
    ConvertTo-Yaml calls Yuruna.Resource.psm1 uses, so a change to the writer's
    shape breaks these tests rather than silently re-opening the no-op.
    No work folders are created, so no `tofu` invocation is reached and the test
    needs no provider on PATH. Runs under Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'

Import-Module (Join-Path $autoDir 'Import.Yaml.psm1') -Force
Import-Module (Join-Path $autoDir 'Yuruna.Clear.psm1') -Force

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Build a project whose resources.output.yml matches what Set-Resource emits.
function New-ResourceOutputFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway temp project the calling It block deletes in its finally.')]
    [CmdletBinding()] [OutputType([string])] param([string[]]$ResourceName)

    $projectRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-clear-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'config/localhost')
    $outFile = Join-Path $projectRoot 'config/localhost/resources.output.yml'
    $null = New-Item -Path $outFile -ItemType File -Force

    Add-Content -Path $outFile -Value (ConvertTo-Yaml @{ globalVariables = [ordered]@{ projectName = 'demo' } })
    foreach ($name in $ResourceName) {
        $tuple = @{ }
        $tuple."$name" = @{ clusterName = @{ value = "value-$name"; type = 'string' } }
        Add-Content -Path $outFile -Value (ConvertTo-Yaml $tuple)
    }
    return $projectRoot
}

# Clear-Configuration reports progress on the Information and Debug streams;
# capture both so the assertions can see which resources it walked. The
# preferences must be set at global scope: a called module resolves
# $DebugPreference against its own scope and then the global one, never the
# caller's local scope, so a function-local assignment would silently leave the
# Debug stream empty.
function Get-ClearMessage {
    param([string]$ProjectRoot)

    $previousDebug = $global:DebugPreference
    $previousInfo  = $global:InformationPreference
    $global:DebugPreference = 'Continue'
    $global:InformationPreference = 'Continue'
    try {
        $records = Clear-Configuration $ProjectRoot 'localhost' 5>&1 6>&1 3>$null
    }
    finally {
        $global:DebugPreference = $previousDebug
        $global:InformationPreference = $previousInfo
    }
    return @($records | ForEach-Object { [string]$_ })
}

Describe 'clear-resource-enumeration' {

    It 'walks every deployed resource key in resources.output.yml' {
        $projectRoot = New-ResourceOutputFixture -ResourceName @('yrn42cluster', 'yrn42registry')
        try {
            $messages = Get-ClearMessage -ProjectRoot $projectRoot
            $joined = $messages -join "`n"
            foreach ($name in @('yrn42cluster', 'yrn42registry')) {
                Assert-True ($joined -match [regex]::Escape($name)) `
                    "teardown must name deployed resource '$name'; it only reported: $joined"
            }
            Assert-True ($joined -notmatch 'No deployed resources') `
                "teardown found no resources in a file that declares two: $joined"
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports nothing to destroy when only globalVariables were written' {
        $projectRoot = New-ResourceOutputFixture -ResourceName @()
        try {
            $joined = (Get-ClearMessage -ProjectRoot $projectRoot) -join "`n"
            Assert-True ($joined -match 'No deployed resources') `
                "a resources.output.yml holding only globalVariables has nothing to destroy: $joined"
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'excludes the globalVariables map from the resource set' {
        $projectRoot = New-ResourceOutputFixture -ResourceName @('yrn42cluster')
        try {
            $joined = (Get-ClearMessage -ProjectRoot $projectRoot) -join "`n"
            Assert-True ($joined -notmatch 'resources/globalVariables') `
                "globalVariables is the shared variable map, not a resource work folder: $joined"
        }
        finally {
            Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'does not select a resources list, which this file never carries' {
        $src = Get-Content -LiteralPath (Join-Path $autoDir 'Yuruna.Clear.psm1') -Raw
        Assert-True ($src -notmatch '\$yaml\.resources') `
            'resources.output.yml has no resources: list; selecting one silently destroys nothing'
    }
}
