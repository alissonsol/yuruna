<#PSScriptInfo
.VERSION 2026.09.08
.GUID 424fcb83-70f8-4a61-899b-5252d0c26fea
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester fixtures scope drift
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
    Every suite in the repo keeps its fixtures where an It body can read them,
    under either way of invoking Pester.
.DESCRIPTION
    Pester 5 discovers and runs in two passes. A fixture assigned at file scope
    is bound during discovery and is gone by the time a test body executes, so
    the body sees an empty value and the failure surfaces as a parameter
    binding error far from its cause -- "Cannot bind argument ... because it is
    an empty string" -- rather than as a missing fixture.

    The standalone invocation (`pwsh -File <suite>`) happens to tolerate the
    file-scope form, which is what let three suites ship in that shape and stay
    broken under `Invoke-Pester -Path` without anyone noticing: 73 tests that
    reported green one way and failed the other. This guard is what makes the
    two invocations agree.

    The rule enforced here is structural: **every suite declares at least one
    BeforeAll.** That is deliberately a proxy for the real invariant rather
    than the invariant itself, and the reason is worth recording, because the
    obvious stricter rules are all measurably false against this repo:

      * "a suite must have a TOP-LEVEL BeforeAll" -- false. A BeforeAll nested
        in a Describe is correct; Pester shares it with that block's tests
        (Test.UtmGhostRegistration).
      * "no file-scope assignment after the first Describe" -- false. Those
        feed the discovery pass, e.g. `It ... -TestCases $cases`, which is
        evaluated while the statement is still in scope
        (Test.CachingProxyServiceStart).
      * "no It body may read a file-scope variable" -- false. Test.SetupAnswerFile
        does exactly that and passes under both invocations.

    What separated the three broken suites from the other 176 was simply that
    they declared no BeforeAll anywhere. That is what this checks. The exact
    invariant -- both invocations agree -- is enforced where it can be measured
    rather than inferred: tools/Invoke-TestSuite.ps1 runs every suite and
    compares counts against a tracked baseline.

    The second rule here is the assertion-helper one: no suite may declare its
    own Assert-*. The two belong together because both are forms of "the suite
    carries something that belongs in one shared place", and both regrow the
    same way -- by being copied from a neighbor. The Assert-* count went 234 ->
    296 over the period when nothing enforced it.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    # Discover the same way tools/Invoke-TestSuite.ps1 does, so the guard covers
    # exactly the set the gate runs -- a suite the runner sees but this file
    # does not would be unguarded.
    function Get-RepoSuite {
        Push-Location $repoRoot
        try {
            @(git ls-files --cached --others --exclude-standard |
                    Where-Object { $_ -match '\.Tests\.ps1$' } |
                    Where-Object { $_ -like 'test/modules/*' -or $_ -like 'host/modules/*' } |
                    Sort-Object -Unique)
        } finally { Pop-Location }
    }

    function Get-SuiteAst {
        param([string]$Relative)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot $Relative), [ref]$null, [ref]$errors)
        if ($errors) { throw "$Relative does not parse: $($errors[0].Message)" }
        $ast
    }

    $script:Suites = Get-RepoSuite
}

Describe 'every suite keeps its fixtures in a scope the tests can read' {
    It 'discovers the repo suite set' {
        Assert-True ($script:Suites.Count -gt 100) "expected the full suite set, found $($script:Suites.Count)"
    }

    It 'declares a BeforeAll in every suite' {
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($rel in $script:Suites) {
            $ast = Get-SuiteAst -Relative $rel
            $hasBeforeAll = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'BeforeAll'
                    }, $true)).Count -gt 0
            if (-not $hasBeforeAll) { $missing.Add($rel) }
        }
        Assert-True ($missing.Count -eq 0) @"
these suites declare no BeforeAll, so their fixtures live at file scope and
bind as empty inside an It under Invoke-Pester -Path:
$($missing -join "`n")
"@
    }

    It 'declares no local Assert-* helper in any suite' {
        # One vocabulary, in test/modules/Test.Assert.psm1. A local redefinition
        # shadows the shared one for that file only, which is how the suites
        # ended up with three incompatible meanings for Assert-Equal -- including
        # four that inverted its parameter order, so the same positional call
        # asserted the opposite of what it did everywhere else.
        $local = [Collections.Generic.List[string]]::new()
        foreach ($rel in $script:Suites) {
            $ast = Get-SuiteAst -Relative $rel
            foreach ($d in $ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        $n.Name -like 'Assert-*'
                    }, $true)) {
                $local.Add("$($rel):$($d.Extent.StartLineNumber)  $($d.Name)")
            }
        }
        Assert-True ($local.Count -eq 0) @"
these suites declare their own Assert-* instead of importing
test/modules/Test.Assert.psm1:
$($local -join "`n")
"@
    }
}
