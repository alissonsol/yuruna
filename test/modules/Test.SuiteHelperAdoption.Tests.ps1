<#PSScriptInfo
.VERSION 2026.11.05
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

    The seventh rule covers the process environment. Suites put entries back by
    hand in a dozen forms (YURUNA_RUNTIME_DIR, PATH, HOME, GIT_* and retry and
    translation settings among them), and the forms disagreed: a teardown that
    removes the entry, or sets it to $null, drops a value the process held
    before the suite, and a restore guarded by "if it was set" leaves the
    test's value behind when it was not. Save-YurunaTestEnvironment and
    Restore-YurunaTestEnvironment keep the previous value, absent included, so
    a teardown (finally, AfterEach, AfterAll) changes the environment only
    through Restore-YurunaTestEnvironment. Setting an entry in setup or in a
    test is the test's own work and is not counted.

    The eighth rule covers temp folders. A suite that joins the temp folder with
    a GUID or random name builds a fixture folder by hand, and the copies
    disagreed on the name, on whether the folder existed before the test used
    it and on whether anything removed it. New-YurunaTestTempDir and
    Remove-YurunaTestTempDir make and remove one; a fixed name under the temp
    folder (an absent path, the folder a module is asserted to use) is not a
    fixture.

    The ninth rule covers loopback listeners. A suite that constructs a
    TcpListener or HttpListener, or accepts a connection, has copied a
    listener, and the copies disagreed on when the port was read, on whether a
    responder read the whole request and on whether its job was ever removed.
    New-YurunaTestTcpListener, Get-YurunaTestFreePort, New-YurunaTestSocketPair
    and Start-/Stop-YurunaTestHttpResponder do it once; a suite whose listener is
    the subject of its tests is listed with the reason.
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

    # A script block handed to a runspace of its own (AddScript, Start-Job,
    # Start-ThreadJob) changes that runspace's environment, not this process's.
    function Get-PrivateRunspaceBlock {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        @($Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and (
                        ($n.Parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Parent.Member.Value -eq 'AddScript') -or
                        ($n.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')) -or
                        ($n.Parent.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.Parent.GetCommandName() -in @('Start-Job', 'Start-ThreadJob')))
                }, $true))
    }

    # Whether a node sits inside one of the given blocks, by extent.
    $script:WithinBlock = {
        param($node, $blocks)
        foreach ($block in $blocks) {
            if ($node.Extent.StartOffset -ge $block.Extent.StartOffset -and $node.Extent.EndOffset -le $block.Extent.EndOffset) { return $true }
        }
        return $false
    }

    # The statements that change the process environment, each with the entry
    # names it writes when they are literal: an assignment to an $env: entry,
    # a Remove-Item, Set-Item or Clear-Item of Env:<entry> (one entry, or a
    # list of them), or [Environment]::SetEnvironmentVariable. A computed name
    # (a restore loop over saved names) is a write with no name.
    function Get-EnvironmentWrite {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $candidates = $Ast.FindAll({
                param($x)
                ($x -is [System.Management.Automation.Language.AssignmentStatementAst] -or
                $x -is [System.Management.Automation.Language.CommandAst] -or
                $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) -and
                $x.Extent.Text -match 'env:|EnvironmentVariable'
            }, $true)
        foreach ($n in $candidates) {
            $hit = $false
            $names = @()
            if ($n -is [System.Management.Automation.Language.AssignmentStatementAst]) {
                if ($n.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.DriveName -eq 'env') {
                    $hit = $true
                    $names = @($n.Left.VariablePath.UserPath -replace '^env:', '')
                }
            } elseif ($n -is [System.Management.Automation.Language.CommandAst]) {
                if ($n.GetCommandName() -in @('Remove-Item', 'ri', 'del', 'Set-Item', 'si', 'Clear-Item', 'cli')) {
                    foreach ($element in @($n.CommandElements | Select-Object -Skip 1)) {
                        foreach ($entry in @($element.FindAll({
                                        param($s)
                                        ($s -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                                        $s -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and $s.Value -match '^Env:'
                                    }, $true))) {
                            $hit = $true
                            if ($entry -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names += ($entry.Value -replace '^Env:\\?', '') }
                        }
                    }
                }
            } elseif ($n.Member.Value -eq 'SetEnvironmentVariable') {
                $hit = $true
                if ($n.Arguments.Count -ge 2 -and $n.Arguments[0] -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names = @($n.Arguments[0].Value) }
            }
            if ($hit) { [pscustomobject]@{ Node = $n; Name = @($names | Where-Object { $_ }) } }
        }
    }

    # A hand-made restore of the process environment: inside a finally,
    # AfterEach or AfterAll block, or inside a suite-local function such a
    # block calls, a write to an entry, whether the entry is named or computed.
    # Teardown is where a test puts the process back; Restore-YurunaTestEnvironment
    # does that from what Save-YurunaTestEnvironment recorded, including that
    # an entry was absent, where the hand copies cleared or dropped the outer
    # value. A restore moved into a function of its own is the same copy, one
    # call away, so a function a teardown calls (directly or through another)
    # is read as part of it. Setting an entry in setup or in a test is the
    # test's own work and is not counted, and neither is a block another
    # runspace runs.
    function Get-LocalEnvironmentRestoreCopy {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $private = Get-PrivateRunspaceBlock -Ast $Ast
        $teardown = @($Ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally) -or
                    ($n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and
                    $n.Parent -is [System.Management.Automation.Language.CommandAst] -and $n.Parent.GetCommandName() -in @('AfterEach', 'AfterAll'))
                }, $true) | ForEach-Object { if ($_ -is [System.Management.Automation.Language.TryStatementAst]) { $_.Finally } else { $_ } })
        $definitions = @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $grew = $teardown.Count -gt 0
        while ($grew) {
            $grew = $false
            $called = @($teardown | ForEach-Object { $_.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) } |
                    ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
            foreach ($definition in $definitions) {
                if ($definition.Name -in $called -and -not (& $script:WithinBlock $definition.Body $teardown)) {
                    $teardown += $definition.Body
                    $grew = $true
                }
            }
        }
        if ($teardown.Count -eq 0) { return @() }
        $found = [System.Collections.Generic.List[int]]::new()
        foreach ($write in @(Get-EnvironmentWrite -Ast $Ast)) {
            if ((& $script:WithinBlock $write.Node $teardown) -and -not (& $script:WithinBlock $write.Node $private)) { $found.Add($write.Node.Extent.StartLineNumber) }
        }
        @($found | Sort-Object -Unique)
    }

    # An entry a suite sets by a literal name that no Save-YurunaTestEnvironment
    # in the suite names, as '<line> <entry>'. A set with no restore leaks to
    # whatever runs next in the process, and the shared pair is how a restore
    # is proven: an entry the save names is put back by the restore. A save
    # the rule cannot read (-All, a name list held in a variable, or a shared
    # helper that saves on the suite's behalf) is taken to cover every entry;
    # a computed name is not judged, and neither is a block another runspace
    # runs.
    function Get-LocalEnvironmentUnsavedSet {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $saved = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($call in $Ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -in @('Save-YurunaTestEnvironment', 'Enter-TranslationTestEnvironment')
                }, $true)) {
            if ($call.GetCommandName() -ne 'Save-YurunaTestEnvironment') { return @() }
            foreach ($element in @($call.CommandElements | Select-Object -Skip 1)) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($element.ParameterName -eq 'All') { return @() }
                    continue
                }
                $literal = @($element.FindAll({ param($s) $s -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true))
                if ($literal.Count -eq 0) { return @() }
                foreach ($s in $literal) { [void]$saved.Add($s.Value) }
            }
        }
        $private = Get-PrivateRunspaceBlock -Ast $Ast
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($write in @(Get-EnvironmentWrite -Ast $Ast)) {
            if (& $script:WithinBlock $write.Node $private) { continue }
            foreach ($name in $write.Name) {
                if (-not $saved.Contains($name)) { $found.Add([pscustomobject]@{ Line = $write.Node.Extent.StartLineNumber; Name = $name }) }
            }
        }
        @($found | Sort-Object Line, Name -Unique | ForEach-Object { '{0} {1}' -f $_.Line, $_.Name })
    }

    # A temp path built by hand with a unique name: a temp-folder expression
    # ([IO.Path]::GetTempPath(), $env:TEMP, $env:TMP or $env:TMPDIR) in the same
    # statement as a unique-name token ([guid]::NewGuid(), New-Guid,
    # GetRandomFileName, Get-Random), or GetTempFileName, which is both. A part
    # in parentheses or in $() counts as the statement around it. That is the
    # shape of a fixture folder, which New-YurunaTestTempDir makes and
    # Remove-YurunaTestTempDir removes; the hand copies differed in the name,
    # in whether the folder existed before the test used it, and in whether
    # anything removed it. A fixed name under the temp folder (an absent path,
    # the folder a module is asserted to use, a listing of it) is not a fixture
    # and is not counted.
    function Get-LocalTempPathCopy {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $isUnique = {
            param($x)
            ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Static -and
            $x.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $x.Member.Value -in @('NewGuid', 'GetRandomFileName', 'GetTempFileName')) -or
            ($x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -in @('New-Guid', 'Get-Random'))
        }
        $sources = $Ast.FindAll({
                param($x)
                ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Static -and
                $x.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $x.Member.Value -in @('GetTempPath', 'GetTempFileName')) -or
                ($x -is [System.Management.Automation.Language.VariableExpressionAst] -and $x.VariablePath.UserPath -match '^env:(TEMP|TMP|TMPDIR)$')
            }, $true)
        $found = [System.Collections.Generic.List[int]]::new()
        foreach ($source in $sources) {
            $statement = $source.Parent
            while ($statement -and -not (
                    $statement -is [System.Management.Automation.Language.PipelineBaseAst] -and
                    $statement.Parent -isnot [System.Management.Automation.Language.ParenExpressionAst] -and
                    -not ($statement.Parent -is [System.Management.Automation.Language.StatementBlockAst] -and (
                            $statement.Parent.Parent -is [System.Management.Automation.Language.SubExpressionAst] -or
                            $statement.Parent.Parent -is [System.Management.Automation.Language.ArrayExpressionAst])))) {
                $statement = $statement.Parent
            }
            if (-not $statement) { continue }
            if (@($statement.FindAll($isUnique, $true)).Count -gt 0) { $found.Add($statement.Extent.StartLineNumber) }
        }
        @($found | Sort-Object -Unique)
    }

    # Suites that still build a uniquely named temp path by hand, each with why
    # the shared helper cannot serve it. An entry that stops applying fails the
    # stale-entry test below.
    $script:TempPathCopyAllowed = [ordered]@{}

    # A listening socket a suite opens itself: a TcpListener or HttpListener it
    # constructs ([...]::new or New-Object), or an accept it runs
    # (AcceptTcpClient, AcceptSocket, GetContext and their Async and Begin
    # forms). The copies disagreed on when the port was read (a stopped
    # listener reports port 0), on whether a responder read the whole request,
    # and on whether the job that served it was ever removed.
    # New-YurunaTestTcpListener, Get-YurunaTestFreePort, New-YurunaTestSocketPair
    # and Start-/Stop-YurunaTestHttpResponder do each of those once.
    function Get-LocalListenerCopy {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        $listenerType = '(^|\.)(TcpListener|HttpListener)$'
        @($Ast.FindAll({
                    param($x)
                    ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Static -and
                    $x.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                    $x.Expression.TypeName.FullName -match $listenerType -and
                    $x.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $x.Member.Value -eq 'new') -or
                    ($x -is [System.Management.Automation.Language.CommandAst] -and $x.GetCommandName() -eq 'New-Object' -and
                    @($x.CommandElements | Where-Object {
                            $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -match $listenerType
                        }).Count -gt 0) -or
                    ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and -not $x.Static -and
                    $x.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $x.Member.Value -in @('AcceptTcpClient', 'AcceptTcpClientAsync', 'BeginAcceptTcpClient', 'AcceptSocket',
                        'AcceptSocketAsync', 'BeginAcceptSocket', 'GetContext', 'GetContextAsync', 'BeginGetContext'))
                }, $true) | ForEach-Object { $_.Extent.StartLineNumber } | Sort-Object -Unique)
    }

    # Suites whose listener is the subject of the test rather than a stand-in,
    # each with the reason. An entry that stops applying fails the stale-entry
    # test below.
    $script:ListenerCopyAllowed = [ordered]@{
        'test/modules/Test.DownloadAgentService.Tests.ps1'    = 'a fake download agent answers the agent API from a plan the test changes as it runs (an ensure queue, Range requests, a first transfer cut short), which scripted replies cannot express'
        'test/modules/Test.PortOwner.Tests.ps1'               = 'the module under test probes a port with an HttpListener prefix bind, so the port it must find held is held by an HttpListener prefix'
        'test/modules/Test.StatusServiceRefreshSafe.Tests.ps1' = 'the test proves the listener that held the port still accepts after a refused start, so it accepts on that listener itself'
        'test/modules/Test.Transport.Tests.ps1'               = 'a fake VNC server speaks the RFB handshake and closes its end the way a stopping VM does, which is not HTTP'
        'test/modules/Test.UtmSerialConsole.Tests.ps1'        = 'a fake QEMU serial port and HMP monitor accept the connections the reader and the monitor capture open themselves, stream console bytes and prompts, and close the way a stopping VM does, which is not HTTP'
    }
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

Describe 'every suite restores the process environment through the shared helpers' {
    BeforeAll {
        $script:EnvironmentRestoreCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($line in (Get-LocalEnvironmentRestoreCopy -Ast (Get-SuiteAst -Relative $rel))) { '{0}:{1}' -f $rel, $line }
            })
    }

    It 'tells a hand-made restore from the shared helpers, a test that sets an entry, and a private runspace' {
        # The restore wrapped in a suite-local function (line 4 to 10) is the
        # shape a teardown reaches one call away; Reset-Marker is reached two
        # calls away, through Clear-Fixture. The list forms on lines 16 and 25
        # drop every entry they name, not only the first.
        $copy = @'
BeforeAll {
    $script:Prior = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = 'x'
    function Restore-FixtureEnvironment {
        param([hashtable]$Snapshot)
        foreach ($name in $Snapshot.Keys) {
            if ($null -eq $Snapshot[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, [string]$Snapshot[$name]) }
        }
    }
    function Reset-Marker { Remove-Item Env:FIXTURE_MARKER -ErrorAction SilentlyContinue }
    function Clear-Fixture { Reset-Marker }
}
AfterAll { $env:YURUNA_RUNTIME_DIR = $script:Prior; Clear-Fixture }
Describe 'a block' {
    AfterEach { Remove-Item Env:GIT_CONFIG_GLOBAL, Env:GIT_CONFIG_SYSTEM -ErrorAction SilentlyContinue }
    It 'restores by hand' {
        $saved = @{}
        foreach ($name in @('HOME')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try { $env:HOME = 'y' } finally { Restore-FixtureEnvironment -Snapshot $saved }
        try { $env:PATH = 'z' } finally { [Environment]::SetEnvironmentVariable('PATH', $null) }
        try { $env:NO_COLOR = '1' } finally { Remove-Item -LiteralPath "Env:NO_COLOR" }
        try { $env:OMP_THREAD_LIMIT = '1' } finally { Set-Item -LiteralPath Env:OMP_THREAD_LIMIT -Value '4' }
        try { $env:YURUNA_RETRY = '0' } finally { foreach ($name in $saved.Keys) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } }
        try { $env:GIT_AUTHOR_DATE = '1' } finally { Remove-Item -Path @('Env:GIT_AUTHOR_DATE', 'Env:GIT_COMMITTER_DATE') -ErrorAction SilentlyContinue }
    }
}
'@
        $shared = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'GIT_CONFIG_GLOBAL', 'PATH'
    $env:YURUNA_RUNTIME_DIR = 'x'
    function Set-Stub { param([hashtable]$Entry) foreach ($name in $Entry.Keys) { Set-Item -LiteralPath "Env:$name" -Value $Entry[$name] } }
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved }
Describe 'a block' {
    It 'sets and reads the entries as the test needs' {
        $env:GIT_CONFIG_GLOBAL = 'y'
        Remove-Item Env:GIT_CONFIG_GLOBAL, Env:PATH -ErrorAction SilentlyContinue
        Set-Stub -Entry @{ PATH = 'p' }
        $dir = $env:YURUNA_RUNTIME_DIR
        $job = Start-ThreadJob -ScriptBlock { try { $env:PATH = 'j' } finally { $env:PATH = $null } }
        $saved = Save-YurunaTestEnvironment -Name 'HOME'
        try { $env:HOME = 'z'; [Environment]::SetEnvironmentVariable('HOME', 'w') } finally { Restore-YurunaTestEnvironment -Saved $saved }
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        Assert-StringEqual '7,8,11,14,16,21,22,23,24,25' (@(Get-LocalEnvironmentRestoreCopy -Ast $copyAst) -join ',') `
            'an assignment, Remove-Item (bare, quoted, a list and an array), Set-Item and SetEnvironmentVariable (named and computed) in AfterAll, AfterEach and finally, and in a function a teardown calls directly or through another, are each reported, whatever the entry'
        Assert-Equal 0 (@(Get-LocalEnvironmentRestoreCopy -Ast $sharedAst).Count) `
            'the shared helpers, writes a test makes outside teardown (a list included), a function only a test calls, a read and a thread job are not hand-made restores'
    }

    It 'restores no process environment entry by hand in any suite' {
        Assert-True ($script:EnvironmentRestoreCopyFound.Count -eq 0) @"
these suites put a process environment entry back by hand in a teardown, or in
a function a teardown calls. Save the entries with Save-YurunaTestEnvironment
before the test changes them and put them back with
Restore-YurunaTestEnvironment (test/modules/Test.Assert.psm1), which also
removes an entry that was absent:
$($script:EnvironmentRestoreCopyFound -join "`n")
"@
    }
}

Describe 'every suite saves the process environment entries it sets' {
    BeforeAll {
        $script:EnvironmentUnsavedSetFound = @(foreach ($rel in $script:Suites) {
                foreach ($item in (Get-LocalEnvironmentUnsavedSet -Ast (Get-SuiteAst -Relative $rel))) { '{0}:{1}' -f $rel, $item }
            })
    }

    It 'tells an entry set with no save from one the shared helpers cover' {
        $copy = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
    $env:YURUNA_RUNTIME_DIR = 'x'
    $env:SystemDrive = 'C:'
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved }
Describe 'a block' {
    It 'sets entries nothing saved' {
        Set-Item -LiteralPath "Env:PROCESSOR_ARCHITECTURE" -Value 'ARM64'
        Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        [Environment]::SetEnvironmentVariable('NO_COLOR', '1')
        $job = Start-ThreadJob -ScriptBlock { $env:PATH = 'j' }
        foreach ($name in 'TMP', 'TEMP') { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    }
}
'@
        $all = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -All
    $env:SystemDrive = 'C:'
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved -RemoveOthers }
'@
        $opaque = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -Name $script:Names
    $env:SystemDrive = 'C:'
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved }
'@
        $shared = @'
BeforeAll {
    $script:Saved = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'GIT_CONFIG_GLOBAL', 'PATH'
    $env:YURUNA_RUNTIME_DIR = 'x'
}
AfterAll { Restore-YurunaTestEnvironment -Saved $script:Saved }
Describe 'a block' {
    It 'sets and reads the entries as the test needs' {
        $env:GIT_CONFIG_GLOBAL = 'y'
        Remove-Item Env:GIT_CONFIG_GLOBAL, Env:PATH -ErrorAction SilentlyContinue
        $job = Start-ThreadJob -ScriptBlock { $env:HOME = 'j' }
        $saved = Save-YurunaTestEnvironment -Name 'HOME'
        try { $env:HOME = 'z'; [Environment]::SetEnvironmentVariable('HOME', 'w') } finally { Restore-YurunaTestEnvironment -Saved $saved }
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        Assert-StringEqual '4 SystemDrive,9 PROCESSOR_ARCHITECTURE,10 GIT_AUTHOR_DATE,10 GIT_COMMITTER_DATE,11 NO_COLOR' (@(Get-LocalEnvironmentUnsavedSet -Ast $copyAst) -join ',') `
            'an assignment, Set-Item, a Remove-Item list and SetEnvironmentVariable naming an entry no save names are each reported; a thread job and a computed name are not'
        foreach ($case in @(@{ Name = 'a save of every entry'; Text = $all }, @{ Name = 'a save whose names the rule cannot read'; Text = $opaque }, @{ Name = 'saves naming every entry set'; Text = $shared })) {
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($case.Text, [ref]$null, [ref]$null)
            Assert-Equal 0 (@(Get-LocalEnvironmentUnsavedSet -Ast $ast).Count) "$($case.Name) leaves nothing to report"
        }
    }

    It 'saves every process environment entry it sets by name, in any suite' {
        Assert-True ($script:EnvironmentUnsavedSetFound.Count -eq 0) @"
these suites set a process environment entry that no Save-YurunaTestEnvironment
in the suite names, so nothing puts it back for whatever runs next in the
process. Save it before the first set and put it back with
Restore-YurunaTestEnvironment (test/modules/Test.Assert.psm1), or save every
entry with -All and restore with -RemoveOthers:
$($script:EnvironmentUnsavedSetFound -join "`n")
"@
    }
}

Describe 'every suite takes its uniquely named temp folders from the shared helper' {
    BeforeAll {
        $script:TempPathCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($line in (Get-LocalTempPathCopy -Ast (Get-SuiteAst -Relative $rel))) { [pscustomobject]@{ Suite = $rel; Line = $line } }
            })
    }

    It 'tells a hand-built unique temp path from the shared helper and from a fixed name under the temp folder' {
        $copy = @'
BeforeAll {
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('x-' + [guid]::NewGuid().ToString('N'))
}
Describe 'a block' {
    It 'builds its own' {
        $a = Join-Path ([IO.Path]::GetTempPath()) "y-$([guid]::NewGuid().ToString('N'))"
        $b = Join-Path $env:TMPDIR ([System.IO.Path]::GetRandomFileName())
        Mock Get-LogRoot { Join-Path $env:TEMP (New-Guid) }
        $c = @{ Root = Join-Path ([IO.Path]::GetTempPath()) ('z' + (Get-Random)) }
        $d = [System.IO.Path]::GetTempFileName()
    }
}
'@
        $shared = @'
BeforeAll {
    $script:Root = New-YurunaTestTempDir -Prefix 'x'
    $script:Id = [guid]::NewGuid().ToString('N')
}
AfterAll { Remove-YurunaTestTempDir $script:Root }
Describe 'a block' {
    It 'uses the helper and names fixed paths' {
        $absent = Join-Path ([IO.Path]::GetTempPath()) 'no-such-config.yml'
        $left = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'yuruna-*.pem').Count
        Assert-Equal (Join-Path ([System.IO.Path]::GetTempPath()) 'runner.state.json') (Get-RunnerStatePath)
        $mine = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
        $env:TEMP = $script:Root
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        Assert-StringEqual '2,6,7,8,9,10' (@(Get-LocalTempPathCopy -Ast $copyAst) -join ',') `
            'GetTempPath and the TEMP, TMP and TMPDIR entries beside NewGuid, GetRandomFileName, New-Guid and Get-Random, in parentheses, in $(), in a mock and in a hashtable, and GetTempFileName alone, are each reported'
        Assert-Equal 0 (@(Get-LocalTempPathCopy -Ast $sharedAst).Count) `
            'the shared helper, a fixed name under the temp folder, a listing of it, a unique name under a folder the helper made, and a GUID on its own are not hand-built temp paths'
    }

    It 'builds no uniquely named temp path by hand outside the listed suites' {
        $unlisted = @($script:TempPathCopyFound | Where-Object { $_.Suite -cnotin @($script:TempPathCopyAllowed.Keys) } | ForEach-Object { '{0}:{1}' -f $_.Suite, $_.Line })
        Assert-True ($unlisted.Count -eq 0) @"
these suites build a uniquely named temp path by hand. Take the folder from
New-YurunaTestTempDir and remove it with Remove-YurunaTestTempDir
(test/modules/Test.Assert.psm1); a file or a path that must not exist yet goes
under such a folder:
$($unlisted -join "`n")
"@
    }

    It 'lists no suite that has stopped building its own temp path' {
        $stale = @(@($script:TempPathCopyAllowed.Keys) | Where-Object { $_ -cnotin @($script:TempPathCopyFound.Suite) })
        Assert-True ($stale.Count -eq 0) @"
these entries of the remaining-copies list no longer build a unique temp path
by hand. Remove them, so a copy pasted back later is caught:
$($stale -join "`n")
"@
    }
}

Describe 'every suite opens its loopback listeners through the shared helpers' {
    BeforeAll {
        $script:ListenerCopyFound = @(foreach ($rel in $script:Suites) {
                foreach ($line in (Get-LocalListenerCopy -Ast (Get-SuiteAst -Relative $rel))) { [pscustomobject]@{ Suite = $rel; Line = $line } }
            })
    }

    It 'tells a hand-made listener or responder from the shared helpers' {
        $copy = @'
BeforeAll {
    function Get-LoopbackListener {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $listener
    }
}
Describe 'a block' {
    It 'opens its own' {
        $http = [Net.HttpListener]::new()
        $other = New-Object System.Net.Sockets.TcpListener ([Net.IPAddress]::Any, 0)
        $job = Start-ThreadJob -ArgumentList $listener -ScriptBlock { param($Listener) $client = $Listener.AcceptTcpClient() }
        $pending = $listener.AcceptTcpClientAsync()
        $context = $http.GetContext()
    }
}
'@
        $shared = @'
BeforeAll {
    $script:Port = Get-YurunaTestFreePort
}
Describe 'a block' {
    It 'uses the helpers' {
        $listener = New-YurunaTestTcpListener -AnyAddress
        $pair = New-YurunaTestSocketPair
        $responder = Start-YurunaTestHttpResponder -Reply (New-YurunaTestHttpReply -Body 'ok')
        try { $client = [System.Net.Sockets.TcpClient]::new(); $socket = [System.Net.Sockets.Socket]::new('InterNetwork', 'Stream', 'Tcp') }
        finally { $listener.Stop(); $pair.Client.Dispose(); $pair.Server.Dispose(); $requests = Stop-YurunaTestHttpResponder $responder }
    }
}
'@
        $copyAst = [System.Management.Automation.Language.Parser]::ParseInput($copy, [ref]$null, [ref]$null)
        $sharedAst = [System.Management.Automation.Language.Parser]::ParseInput($shared, [ref]$null, [ref]$null)
        Assert-StringEqual '3,10,11,12,13,14' (@(Get-LocalListenerCopy -Ast $copyAst) -join ',') `
            'a TcpListener and an HttpListener built with ::new or New-Object, and AcceptTcpClient, its Async form and GetContext, are each reported'
        Assert-Equal 0 (@(Get-LocalListenerCopy -Ast $sharedAst).Count) `
            'the shared helpers, a client and a plain socket are not hand-made listeners'
    }

    It 'opens no listener by hand outside the listed suites' {
        $unlisted = @($script:ListenerCopyFound | Where-Object { $_.Suite -cnotin @($script:ListenerCopyAllowed.Keys) } | ForEach-Object { '{0}:{1}' -f $_.Suite, $_.Line })
        Assert-True ($unlisted.Count -eq 0) @"
these suites open a listener or accept a connection themselves. Bind with
New-YurunaTestTcpListener or Get-YurunaTestFreePort, pair two ends with
New-YurunaTestSocketPair, and serve HTTP with Start-YurunaTestHttpResponder and
Stop-YurunaTestHttpResponder (test/modules/Test.Assert.psm1); a listener that is
the subject of the test is listed with its reason:
$($unlisted -join "`n")
"@
    }

    It 'lists no suite that has stopped opening its own listener' {
        $stale = @(@($script:ListenerCopyAllowed.Keys) | Where-Object { $_ -cnotin @($script:ListenerCopyFound.Suite) })
        Assert-True ($stale.Count -eq 0) @"
these entries of the listed-listener table no longer open a listener
themselves. Remove them, so a copy pasted back later is caught:
$($stale -join "`n")
"@
    }
}
