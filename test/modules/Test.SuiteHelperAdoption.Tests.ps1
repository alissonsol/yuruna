<#PSScriptInfo
.VERSION 2026.10.30
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

    The fourth rule covers fixture git repositories. A suite that names the
    user.email key builds its own, and the hand-built ones disagreed on commit
    signing, the initial branch, line endings and hooks, so a fixture commit
    could prompt or fail on a machine whose global git configuration differs.
    New-YurunaTestGitRepository and Set-YurunaTestGitIdentity set all of it
    once; a suite that has to build its own is listed with the reason.

    The fifth rule covers the git runners beside them. A suite may keep its own
    Invoke-*Git name for the calls its It bodies make, as a wrapper over
    Invoke-YurunaTestGit. It may not run git itself: the copies disagreed on
    whether a failure threw and what came back, and one that discards a failure
    lets a half-built fixture reach an assertion.

    The sixth rule covers the $global:__Yuruna* channels the entry points
    publish to the modules (host id, run id, cycle folder, log file, cycle
    start). Suites set them by hand in four forms and most never put the
    previous value back, so a later block ran with an earlier test's cycle
    folder or host id. Save-YurunaTestGlobal, Set-YurunaTestGlobal and
    Restore-YurunaTestGlobal are the one way a suite changes them; a script
    block handed to a runspace of its own (AddScript, Start-Job,
    Start-ThreadJob) sets them there and is not counted.

    The seventh rule covers the process environment entries that point a test
    at its runtime and log folders, YURUNA_RUNTIME_DIR and YURUNA_LOG_DIR. Suites
    put them back by hand in a dozen forms, and the forms disagreed: a teardown
    that removes the entry, or sets it to $null, drops a value the process held
    before the suite, and a restore guarded by "if it was set" leaves the test's
    folder behind when it was not. Save-YurunaTestEnvironment and
    Restore-YurunaTestEnvironment keep the previous value, absent included, so a
    teardown (finally, AfterEach, AfterAll) changes these entries only through
    Restore-YurunaTestEnvironment; a suite that names them restores computed
    entry names the same way. Setting an entry in setup or in a test is the
    test's own work and is not counted.
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

    # A suite that names a git identity key builds its own fixture repository:
    # `config user.email ...`, `-c user.email=...`, or the key inside an argument
    # array. The shared New-YurunaTestGitRepository and Set-YurunaTestGitIdentity
    # set it once, with signing, line endings and hooks pinned beside it, so a
    # suite that uses them never names the key.
    function Get-LocalGitIdentityLine {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        @($Ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
                    $n.Value -match '^user\.email(=|$)'
                }, $true) | ForEach-Object { $_.Extent.StartLineNumber } | Sort-Object -Unique)
    }

    # Suites that still set a fixture identity by hand, each with why it has not
    # moved to the shared helper yet. An entry that stops applying fails the
    # stale-entry test below.
    $script:GitFixtureCopyAllowed = @()

    # A suite-local git runner that runs git itself instead of wrapping
    # Invoke-YurunaTestGit. Matched by name, the shape all nine runners had.
    function Get-LocalGitRunnerCopy {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        foreach ($definition in $Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '^Invoke-\w*Git$'
                }, $true)) {
            $own = @($definition.Body.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'git'
                    }, $true))
            if ($own.Count -gt 0) { $definition.Name }
        }
    }

    # Writes to a $global:__Yuruna* channel outside the shared helpers: an
    # assignment, or Set-/New-/Remove-/Clear-Variable naming one. A write inside
    # a script block another runspace runs stays in that runspace.
    function Get-LocalGlobalChannelWrite {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $private = @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and (
                        ($n.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Parent.Member.Value -eq 'AddScript') -or
                        ($n.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')) -or
                        ($n.Parent -is [System.Management.Automation.Language.CommandParameterAst] -and $n.Parent.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')) -or
                        ($n.Parent.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')))
                }, $true))
        $insidePrivate = {
            param($node)
            foreach ($block in $private) {
                if ($node.Extent.StartOffset -ge $block.Extent.StartOffset -and $node.Extent.EndOffset -le $block.Extent.EndOffset) { return $true }
            }
            return $false
        }
        @($Ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $n.Left.VariablePath.UserPath -match '^global:__Yuruna') -or
                    ($n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Set-Variable', 'New-Variable', 'Remove-Variable', 'Clear-Variable') -and
                    @($n.CommandElements | Where-Object {
                            $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -match '^__Yuruna'
                        }).Count -gt 0)
                }, $true) | Where-Object { -not (& $insidePrivate $_) } | ForEach-Object { $_.Extent.StartLineNumber } | Sort-Object -Unique)
    }

    # A hand-made restore of the process environment: inside a finally,
    # AfterEach or AfterAll block, an assignment to a guarded $env: entry, a
    # Remove-Item of Env:<entry>, or [Environment]::SetEnvironmentVariable on it,
    # and, in a suite that names a guarded entry, a SetEnvironmentVariable or
    # Remove-Item Env: whose entry name is computed (a restore loop over saved
    # names). Teardown is where a test puts
    # the process back; Restore-YurunaTestEnvironment does that from what
    # Save-YurunaTestEnvironment recorded, including that an entry was absent,
    # where the hand copies cleared or dropped the outer value. Setting an entry
    # in setup or in a test is the test's own work and is not counted, and
    # neither is a block another runspace runs.
    function Get-LocalEnvironmentRestoreCopy {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Name is read inside the script blocks the AST searches run, which the rule does not follow.')]
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast, [Parameter(Mandatory)][string[]]$Name)
        $private = @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and (
                        ($n.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Parent.Member.Value -eq 'AddScript') -or
                        ($n.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')) -or
                        ($n.Parent.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')))
                }, $true))
        $teardown = @($Ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally) -or
                    ($n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                    $n.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.GetCommandName() -in @('AfterEach', 'AfterAll'))
                }, $true) | ForEach-Object { if ($_ -is [System.Management.Automation.Language.TryStatementAst]) { $_.Finally } else { $_ } })
        if ($teardown.Count -eq 0) { return @() }
        $within = {
            param($node, $blocks)
            foreach ($block in $blocks) {
                if ($node.Extent.StartOffset -ge $block.Extent.StartOffset -and $node.Extent.EndOffset -le $block.Extent.EndOffset) { return $true }
            }
            return $false
        }
        $guarded = { param($entry) $Name -ccontains $entry }
        # A computed entry name counts only in a suite that names a guarded entry,
        # as the list a save-and-restore loop walks.
        $namesGuarded = @($Ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $Name -ccontains $x.Value }, $true)).Count -gt 0
        $found = [System.Collections.Generic.List[int]]::new()
        $candidates = $Ast.FindAll({
                param($x)
                ($x -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $x -is [System.Management.Automation.Language.CommandAst] -or
                $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
                $x.Extent.Text -match 'env:|EnvironmentVariable'
            }, $true)
        foreach ($n in $candidates) {
            $hit = $false
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                $hit = $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.DriveName -eq 'env' -and
                    (& $guarded ($n.Left.VariablePath.UserPath -replace '^env:'))
            } elseif ($n -is [System.Management.Automation.Language.CommandAst]) {
                if ($n.GetCommandName() -in @('Remove-Item', 'ri', 'del')) {
                    foreach ($element in @($n.CommandElements | Select-Object -Skip 1)) {
                        if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $element.Value -match '^Env:\\?(.+)$' -and (& $guarded $Matches[1])) { $hit = $true }
                        if ($namesGuarded -and $element -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $element.Value -match '^Env:') { $hit = $true }
                    }
                }
            } elseif ($n.Member.Value -eq 'SetEnvironmentVariable' -and $n.Arguments.Count -ge 1) {
                $first = $n.Arguments[0]
                $hit = ($namesGuarded -and -not ($first -is [System.Management.Automation.Language.StringConstantExpressionAst])) -or
                    ($first -is [System.Management.Automation.Language.StringConstantExpressionAst] -and (& $guarded $first.Value))
            }
            if ($hit -and (& $within $n $teardown) -and -not (& $within $n $private)) { $found.Add($n.Extent.StartLineNumber) }
        }
        @($found | Sort-Object -Unique)
    }
    $script:GuardedEnvironmentEntry = @('YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR')
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

Describe 'every suite builds its fixture repositories with the shared helper' {
    BeforeAll {
        $script:GitFixtureCopyFound = @(foreach ($rel in $script:Suites) {
                if (@(Get-LocalGitIdentityLine -Ast (Get-SuiteAst -Relative $rel)).Count -gt 0) { $rel }
            })
    }

    It 'tells a hand-built fixture repository from one the shared helper builds' {
        $copy = @'
BeforeAll {
    function New-Fixture {
        $dir = New-YurunaTestTempDir -Prefix 'x'
        & git -C $dir init --quiet
        & git -C $dir config user.email fixture@example.invalid
        return $dir
    }
}
Describe 'a block' {
    It 'commits with an identity of its own' {
        & git -C $repo -c user.email=t@example.invalid -c user.name=t commit -qm seed
        $null = Invoke-FixtureGit $remote @('config', 'user.email', 'fixture@example.invalid')
        & git -C $repo -c "user.email=$mail" commit -qm next
    }
}
'@
        $shared = @'
BeforeAll {
    function New-Fixture { return New-YurunaTestGitRepository -Prefix 'x' -File @{ VERSION = '1' } -CommitMessage 'seed' }
}
Describe 'a block' {
    It 'commits on the shared identity' {
        Set-YurunaTestGitIdentity -Path $clone
        & git -C $clone commit --quiet --allow-empty -m next
        Write-Output 'the helper sets user.email so a suite never has to'
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        Assert-StringEqual '5,11,12,13' (@(Get-LocalGitIdentityLine -Ast $copyAst) -join ',') `
            'the config key, the -c form, the argument array and an expandable -c are each reported, inside a BeforeAll and an It'
        Assert-Equal 0 (@(Get-LocalGitIdentityLine -Ast $sharedAst).Count) `
            'the shared helpers and a sentence that mentions the key are not hand-built fixtures'
    }

    It 'builds no fixture repository by hand outside the listed suites' {
        $unlisted = @($script:GitFixtureCopyFound | Where-Object { $_ -cnotin $script:GitFixtureCopyAllowed })
        Assert-True ($unlisted.Count -eq 0) @"
these suites set a git identity for a fixture repository by hand. Build it with
New-YurunaTestGitRepository (or Set-YurunaTestGitIdentity on a clone) from
test/modules/Test.Assert.psm1, which also pins signing, line endings and hooks:
$($unlisted -join "`n")
"@
    }

    It 'lists no suite that has stopped building its own fixture repository' {
        $stale = @($script:GitFixtureCopyAllowed | Where-Object { $_ -cnotin $script:GitFixtureCopyFound })
        Assert-True ($stale.Count -eq 0) @"
these entries of the remaining hand-built fixture list no longer set an identity.
Remove them, so a copy pasted back later is caught:
$($stale -join "`n")
"@
    }
}

Describe 'every suite runs fixture git through Invoke-YurunaTestGit' {
    BeforeAll {
        $script:GitRunnerCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($name in (Get-LocalGitRunnerCopy -Ast (Get-SuiteAst -Relative $rel))) { '{0}::{1}' -f $rel, $name }
            })
    }

    It 'tells a git runner that runs git itself from a wrapper' {
        $copy = @'
BeforeAll {
    function Invoke-FixtureGit {
        param([string]$Path, [string[]]$Arguments)
        $output = @(& git -C $Path @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "failed: $output" }
        return ($output -join "`n").Trim()
    }
}
Describe 'a block' {
    BeforeAll {
        function Invoke-RingGit { param($Directory, $Arguments) git -C $Directory @Arguments }
    }
}
'@
        $wrapper = @'
BeforeAll {
    function Invoke-FixtureGit {
        param([string]$Path, [string[]]$Arguments)
        return ((Invoke-YurunaTestGit -Path $Path -Argument $Arguments) -join "`n").Trim()
    }
    function Invoke-RelayGit { param([string[]]$Arguments) Invoke-BoundedNativeCommand -FilePath git -ArgumentList $Arguments }
    function Invoke-HookCommit { & git -C $root commit -q -m change }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $wrapperAst = [System.Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$null, [ref]$null)
        Assert-StringEqual 'Invoke-FixtureGit,Invoke-RingGit' (@(Get-LocalGitRunnerCopy -Ast $copyAst) -join ',') `
            'a runner that calls git, with or without the call operator and in any block, is reported'
        Assert-Equal 0 (@(Get-LocalGitRunnerCopy -Ast $wrapperAst).Count) `
            'a wrapper over the shared runner, a bounded network call and an operation under test are not copies'
    }

    It 'keeps no git runner of its own that runs git in a suite' {
        Assert-True ($script:GitRunnerCopyFound.Count -eq 0) @"
these suites define an Invoke-*Git runner that runs git itself. Make it a
wrapper over Invoke-YurunaTestGit from test/modules/Test.Assert.psm1, which
throws with git's output on a failure and returns its lines:
$($script:GitRunnerCopyFound -join "`n")
"@
    }
}

Describe 'every suite changes the $global:__Yuruna* channels through the shared helpers' {
    BeforeAll {
        $script:GlobalChannelWriteFound = @(foreach ($rel in $script:Suites) {
                foreach ($line in (Get-LocalGlobalChannelWrite -Ast (Get-SuiteAst -Relative $rel))) { '{0}:{1}' -f $rel, $line }
            })
    }

    It 'tells a hand-made write from one through the helpers or in a private runspace' {
        $copy = @'
BeforeAll {
    function Set-Anchor { param($Path) $global:__YurunaCycleFolder = $Path }
}
Describe 'a block' {
    It 'writes the channels by hand' {
        Set-Variable -Name __YurunaHostId -Scope Global -Value 'x'
        Remove-Variable __YurunaRunId -Scope Global -ErrorAction SilentlyContinue
        Set-Variable -Name '__YurunaLogFile' -Scope Global -Value $null -Force
    }
}
'@
        $shared = @'
BeforeAll {
    $script:Saved = Save-YurunaTestGlobal -Name '__YurunaCycleFolder'
    function Set-Anchor { param($Path) Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $Path } }
}
AfterAll { Restore-YurunaTestGlobal -Saved $script:Saved }
Describe 'a block' {
    It 'reads a channel and sets one in a runspace of its own' {
        $folder = $global:__YurunaCycleFolder
        $shell = [PowerShell]::Create()
        $null = $shell.AddScript({ Set-Variable -Name __YurunaHostId -Scope Global -Value 'x'; $global:__YurunaRunId = 'r' }).Invoke()
        $job = Start-ThreadJob -ScriptBlock { $global:__YurunaCycleFolder = 'y' }
        $other = 'Set-Variable -Name __YurunaHostId is how it was done'
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        Assert-StringEqual '2,6,7,8' (@(Get-LocalGlobalChannelWrite -Ast $copyAst) -join ',') `
            'an assignment and Set-/Remove-Variable with a bare or quoted name are each reported, in a BeforeAll and an It'
        Assert-Equal 0 (@(Get-LocalGlobalChannelWrite -Ast $sharedAst).Count) `
            'the shared helpers, a read, a private runspace, a thread job and a sentence that names the channel are not hand-made writes'
    }

    It 'writes no $global:__Yuruna* channel by hand in any suite' {
        Assert-True ($script:GlobalChannelWriteFound.Count -eq 0) @"
these suites change a `$global:__Yuruna* channel by hand. Save it with
Save-YurunaTestGlobal, set it with Set-YurunaTestGlobal and put it back with
Restore-YurunaTestGlobal (test/modules/Test.Assert.psm1), which also removes a
channel that was absent before the test:
$($script:GlobalChannelWriteFound -join "`n")
"@
    }
}

Describe 'every suite restores the runtime and log folder entries through the shared helpers' {
    BeforeAll {
        $script:EnvironmentRestoreCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($line in (Get-LocalEnvironmentRestoreCopy -Ast (Get-SuiteAst -Relative $rel) -Name $script:GuardedEnvironmentEntry)) { '{0}:{1}' -f $rel, $line }
            })
    }

    It 'tells a hand-made restore from the shared helpers, a test that sets an entry, and a private runspace' {
        $copy = @'
BeforeAll {
    $script:Prior = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = 'x'
}
AfterAll { $env:YURUNA_RUNTIME_DIR = $script:Prior }
Describe 'a block' {
    AfterEach { Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue }
    It 'restores by hand' {
        $saved = @{}
        foreach ($name in @('YURUNA_RUNTIME_DIR')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try { $env:YURUNA_LOG_DIR = 'y' }
        finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        try { $env:YURUNA_RUNTIME_DIR = 'z' } finally { [Environment]::SetEnvironmentVariable('YURUNA_RUNTIME_DIR', $null) }
        try { $env:YURUNA_LOG_DIR = 'w' } finally { Remove-Item -LiteralPath "Env:YURUNA_LOG_DIR" }
    }
}
'@
        $shared = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
    $env:YURUNA_RUNTIME_DIR = 'x'
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved }
Describe 'a block' {
    It 'sets and reads the entries as the test needs' {
        $env:YURUNA_LOG_DIR = 'y'
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        $dir = $env:YURUNA_RUNTIME_DIR
        $job = Start-ThreadJob -ScriptBlock { try { $env:YURUNA_RUNTIME_DIR = 'j' } finally { $env:YURUNA_RUNTIME_DIR = $null } }
        try { $env:OTHER_SETTING = '1' } finally { Remove-Item Env:OTHER_SETTING -ErrorAction SilentlyContinue }
    }
}
'@
        $unguarded = @'
Describe 'a block' {
    It 'restores entries this rule does not cover' {
        $saved = @{ OTHER = [Environment]::GetEnvironmentVariable('OTHER') }
        try { $env:OTHER = '1' } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
    }
}
'@
        $names = @('YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR')
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        $unguardedAst = [System.Management.Automation.Language.Parser]::ParseInput($unguarded, [ref]$null, [ref]$null)
        Assert-StringEqual '5,7,12,13,14' (@(Get-LocalEnvironmentRestoreCopy -Ast $copyAst -Name $names) -join ',') `
            'an assignment, a Remove-Item (bare and quoted) and SetEnvironmentVariable (named and computed) in AfterAll, AfterEach and finally are each reported'
        Assert-Equal 0 (@(Get-LocalEnvironmentRestoreCopy -Ast $sharedAst -Name $names).Count) `
            'the shared helpers, writes a test makes outside teardown, a read, a thread job and an unguarded entry are not hand-made restores'
        Assert-Equal 0 (@(Get-LocalEnvironmentRestoreCopy -Ast $unguardedAst -Name $names).Count) `
            'a computed restore in a suite that names no guarded entry is outside this rule'
    }

    It 'restores no runtime or log folder entry by hand in any suite' {
        Assert-True ($script:EnvironmentRestoreCopyFound.Count -eq 0) @"
these suites put YURUNA_RUNTIME_DIR or YURUNA_LOG_DIR back by hand in a
teardown. Save them with Save-YurunaTestEnvironment before the test changes
them and put them back with Restore-YurunaTestEnvironment
(test/modules/Test.Assert.psm1), which also removes an entry that was absent:
$($script:EnvironmentRestoreCopyFound -join "`n")
"@
    }
}
