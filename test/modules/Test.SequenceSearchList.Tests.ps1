<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42f0a1b2-3c4d-4e5f-8a6b-7c8d9e0f1a2b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence resolve pester
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
    Structural Pester guard: the sequence resolution-miss list formatter (indent
    each candidate path four spaces, join with newlines) lives in one shared
    Format-SequenceSearchList helper, not copy-pasted across the sequence modules.
.DESCRIPTION
    The one-liner ($paths | ForEach-Object { "    $_" }) -join "`n" was repeated
    at five miss/ambiguity-diagnostic sites across Invoke-Sequence,
    Test.SequencePlanner, and Test.SequenceResolve. These guards assert the helper
    is defined and exported in Test.SequenceResolve (imported -Global by the
    siblings), all three modules delegate to it, and the raw indent one-liner now
    appears exactly once (inside the helper). Source-text only. Runs under Pester
    4.10.1 (script-scoped throw helper).
#>

$here    = Split-Path -Parent $PSCommandPath
$resolve = Get-Content (Join-Path $here 'Test.SequenceResolve.psm1') -Raw
$invoke  = Get-Content (Join-Path $here 'Invoke-Sequence.psm1') -Raw
$planner = Get-Content (Join-Path $here 'Test.SequencePlanner.psm1') -Raw
$all     = $resolve + "`n" + $invoke + "`n" + $planner
$oneLiner = 'ForEach-Object { "    $_" }'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'sequence-search-list -- the resolution-miss list formatter is shared' {
    It 'defines a Format-SequenceSearchList helper in Test.SequenceResolve' {
        Assert-True ($resolve -match '(?m)^function Format-SequenceSearchList\b') `
            'the duplicated indent/join one-liner must collapse into one helper'
    }
    It 'exports Format-SequenceSearchList from Test.SequenceResolve (for the -Global importers)' {
        $exportLine = ($resolve -split "`n" | Where-Object { $_ -match 'Export-ModuleMember' }) -join "`n"
        Assert-True ($exportLine -match '\bFormat-SequenceSearchList\b') 'the shared formatter must be exported so the sibling modules can call it'
    }
    It 'all three sequence modules delegate to Format-SequenceSearchList' {
        Assert-True ($resolve -match 'Format-SequenceSearchList -Item') 'Test.SequenceResolve must use the shared formatter'
        Assert-True ($invoke  -match 'Format-SequenceSearchList -Item') 'Invoke-Sequence must use the shared formatter'
        Assert-True ($planner -match 'Format-SequenceSearchList -Item') 'Test.SequencePlanner must use the shared formatter'
    }
    It 'the raw indent/join one-liner now appears exactly once (inside the helper)' {
        $count = ([regex]::Matches($all, [regex]::Escape($oneLiner))).Count
        Assert-True ($count -eq 1) "expected exactly one indent/join one-liner after dedup, found $count"
    }
}
