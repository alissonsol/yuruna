<#PSScriptInfo
.VERSION 2026.10.11.1
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

    The third rule covers the scaffolds beside the assertions: the AST loaders,
    the function lookup, the command-call counters and the temp-directory
    makers. A suite may keep its own name for one of them, as a wrapper over the
    shared helper, so its It bodies need no change. It may not keep the work.
    Copies drift apart where it matters: a loader that tolerates a parse error
    or a missing file hands back an empty tree, and a guard asserting that
    something is absent passes against it.
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

    # The scaffold names the suites copied from one another. Each has a shared
    # counterpart in Test.Assert.psm1.
    $script:ScaffoldName = @('Get-FunctionAst', 'Get-ModuleAst', 'Get-FileAst', 'Get-ScriptAst', 'Test-AstCallsCommand',
        'Get-CommandCallCount', 'Get-CommandInvokeCount', 'New-TempDir', 'New-ScratchDir')

    # A function under one of those names is a copy when it does the work
    # itself: parses a file, searches an AST, or picks the temp root. Those are
    # the calls the shared helpers are built from, so a wrapper has none of them
    # and a helper with a purpose of its own (a directory under a base the suite
    # tracks for cleanup) has none either.
    function Get-LocalScaffoldCopy {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $names = $script:ScaffoldName
        foreach ($definition in $Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names
                }, $true)) {
            $own = @($definition.Body.FindAll({
                        param($n)
                        ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                        $n.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                        $n.Member.Value -in @('ParseFile', 'FindAll', 'Find', 'GetTempPath')) -or
                        ($n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                        $n.VariablePath.UserPath -match '^env:(TEMP|TMP|TMPDIR)$')
                    }, $true))
            if ($own.Count -gt 0) { $definition.Name }
        }
    }

    # The copies that remain, one entry per helper as '<suite path>::<helper>'.
    # An entry is removed when its helper becomes a wrapper; one that has
    # stopped applying fails the last test below, so the list cannot go stale.
    # A helper that has to do the work itself, for a reason the shared one
    # cannot serve, belongs here with that reason beside it.
    $script:ScaffoldCopyAllowed = @()
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

Describe 'every suite takes its scaffolds from Test.Assert.psm1' {
    BeforeAll {
        $script:ScaffoldCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($name in (Get-LocalScaffoldCopy -Ast (Get-SuiteAst -Relative $rel))) { '{0}::{1}' -f $rel, $name }
            })
    }

    It 'tells a suite-local copy from a wrapper over the shared helper' {
        # A detector that reports nothing reads exactly like a repo with nothing
        # to report, so it is shown one of each before its verdict is trusted.
        # The fixtures define their helpers inside a BeforeAll, where every suite
        # defines them, and use each of the nine names: a name missing from the
        # rule or a search that stops at the block boundary would otherwise pass
        # for a repo without copies.
        $copy = @'
BeforeAll {
    function Get-FileAst {
        param([string]$Path)
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in $Path" }
        return $ast
    }
    function Get-ModuleAst { return [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$null) }
    function Get-ScriptAst { param([string]$Path) [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null) }
    function Get-FunctionAst {
        param($RootAst, [string]$FunctionName)
        return $RootAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName }, $true)
    }
    function Test-AstCallsCommand {
        param($Ast, [string]$CommandName)
        return (@($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName }, $true)).Count -gt 0)
    }
    function Get-CommandCallCount {
        param($Ast, [string]$Name)
        @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $Name }, $true)).Count
    }
    function Get-CommandInvokeCount { param($Ast, [string]$Name) @($Ast.FindAll({ param($n) $n.GetCommandName() -eq $Name }, $true)).Count }
    function New-TempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ('x-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $d
        return $d
    }
    function New-ScratchDir { return (Join-Path $env:TEMP 'x') }
    function Get-UnrelatedAst { return [System.Management.Automation.Language.Parser]::ParseFile($args[0], [ref]$null, [ref]$null) }
}
Describe 'a block of its own' {
    BeforeAll {
        function New-TempDir { return (Join-Path $env:TMP 'x') }
        function New-ScratchDir { return (Join-Path $env:TMPDIR 'x') }
    }
}
'@
        $wrapper = @'
BeforeAll {
    function Get-FileAst { param([string]$Path) return Get-YurunaTestFileAst -Path $Path }
    function Get-ModuleAst { return Get-YurunaTestFileAst -Path $modPath }
    function Get-ScriptAst { param([string]$Path) return Get-YurunaTestFileAst -Path $Path }
    function Get-FunctionAst {
        param($RootAst, [string]$FunctionName)
        $found = Get-YurunaTestFunctionAst -Ast $RootAst -Name $FunctionName
        if (-not $found) { throw "Function $FunctionName not found" }
        return $found
    }
    function Test-AstCallsCommand { param($Ast, [string]$CommandName) return ((Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $CommandName) -gt 0) }
    function Get-CommandCallCount { param($Ast, [string]$Name) return (Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $Name) }
    function Get-CommandInvokeCount { param($Ast, [string]$Name) return (Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $Name) }
    function New-TempDir { return New-YurunaTestTempDir -Prefix 'x' }
    function New-ScratchDir {
        $dir = Join-Path $script:ScratchBase ('x-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $script:Created.Add($dir)
        $dir
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$null, [ref]$null)
        $reported = 'Get-FileAst,Get-ModuleAst,Get-ScriptAst,Get-FunctionAst,Test-AstCallsCommand,Get-CommandCallCount,' +
            'Get-CommandInvokeCount,New-TempDir,New-ScratchDir,New-TempDir,New-ScratchDir'
        Assert-StringEqual $reported (@(Get-LocalScaffoldCopy -Ast $copyAst) -join ',') `
            'each helper that does the work itself is reported, under every one of the nine names; a helper under another name is outside this rule'
        Assert-Equal 0 (@(Get-LocalScaffoldCopy -Ast $wrapperAst).Count) `
            'a wrapper, with or without its own not-found throw, and a tracked scratch directory are not copies'
    }

    It 'keeps no copy of a shared scaffold in a suite' {
        $unlisted = @($script:ScaffoldCopyFound | Where-Object { $_ -cnotin $script:ScaffoldCopyAllowed })
        Assert-True ($unlisted.Count -eq 0) @"
these suites define a scaffold helper that does the work itself. Make it a
wrapper over the shared helper in test/modules/Test.Assert.psm1
(Get-YurunaTestFileAst, Get-YurunaTestFunctionAst,
Get-YurunaTestCommandCallCount, New-YurunaTestTempDir), or call that directly:
$($unlisted -join "`n")
"@
    }

    It 'lists no remaining copy that has stopped being one' {
        $stale = @($script:ScaffoldCopyAllowed | Where-Object { $_ -cnotin $script:ScaffoldCopyFound })
        Assert-True ($stale.Count -eq 0) @"
these entries of the remaining-copies list no longer match a suite-local copy.
Remove them, so a copy pasted back later is caught:
$($stale -join "`n")
"@
    }
}
