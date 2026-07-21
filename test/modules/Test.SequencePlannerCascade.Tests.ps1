<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b90938-32c4-4c5c-91d0-c52eb3049b5d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence planner cascade variables pester
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
    Structural Pester guard on test/modules/Test.SequencePlanner.psm1: the
    subtle chain variable-cascade merge rules live in ONE helper
    (Merge-SequenceVariableCascade), not copy-pasted between the two planners.
.DESCRIPTION
    Add-CyclePlanEntriesForTopLevel and Resolve-NamedSequenceChain both merged
    each chain member's variables into an ordered map with the same 'skip a key
    already set, skip null, skip a whitespace-only string' rules. That subtle
    inner loop was byte-identical in both (only the outer path-resolution and its
    warnings differ, which stay per-site). These guards assert the merge rules
    now exist once, in the helper, and both planners delegate to it. Source-text
    only. Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here = Split-Path -Parent $PSCommandPath
$src  = Get-Content (Join-Path $here 'Test.SequencePlanner.psm1') -Raw

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'sequenceplanner-cascade -- the variable-merge rules are shared by one helper' {
    It 'defines a Merge-SequenceVariableCascade helper' {
        Assert-True ($src -match '(?m)^function Merge-SequenceVariableCascade\b') `
            'the duplicated cascade-merge loop must collapse into one helper'
    }
    It 'the whitespace-only-skip rule appears exactly once (only in the helper)' {
        $n = ([regex]::Matches($src, [regex]::Escape('-not $vv.Trim()'))).Count
        Assert-True ($n -eq 1) "expected one whitespace-skip after dedup, found $n"
    }
    It 'both planners delegate to Merge-SequenceVariableCascade' {
        $n = ([regex]::Matches($src, [regex]::Escape('Merge-SequenceVariableCascade -Target $effectiveVars -Variables $sSeq.variables'))).Count
        Assert-True ($n -eq 2) "expected both planners to delegate, found $n"
    }
}
