<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42ee0946-820e-4d0f-9db6-e2edc4b0eea3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization gates registry performance pester
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
    Hold the generated catalogs, runtime copies and boundary maps to the
    sources they are generated from, and the gates that read the project to
    the project.
.DESCRIPTION
    Part of the globalization gate suites: Test.GlobalizationGates.Tests.ps1
    holds their setup and says what they protect.

    Run through tools/_InvokeOneSuite.ps1 and inspect its NUnit result file.
#>

BeforeAll {
    # Split from Test.GlobalizationGates.Tests.ps1 so the files run at once. The
    # setup is that file's own block, run as that file, so every case here sets
    # up the way it did there.
    $suite = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.GlobalizationGates.Tests.ps1'), [ref]$null, [ref]$null)
    $script:SharedBlock = @{}
    foreach ($statement in @($suite.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.PipelineAst] })) {
        $command = $statement.PipelineElements[0]
        if ($command -is [Management.Automation.Language.CommandAst] -and $command.GetCommandName() -in 'BeforeAll', 'AfterAll') {
            $script:SharedBlock[$command.GetCommandName()] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    . $script:SharedBlock['BeforeAll']

    # One run of the cross-repository gate answers both cases that read it: its
    # exit code, and the coverage table it prints whatever that code is. Each
    # run executes every project-crossing gate, so a second run would only
    # repeat them. The run is kept whatever it returned, so a failing gate
    # costs one run too.
    function Get-CrossRepoGateRun {
        if (-not (Get-Variable -Name CrossRepoGateRun -Scope Script -ErrorAction SilentlyContinue)) {
            $output = & $script:PowerShell -NoProfile -File (Join-Path $script:RepoRoot 'tools/Invoke-CrossRepoGate.ps1') 2>&1 | Out-String
            $script:CrossRepoGateRun = @{ Code = $LASTEXITCODE; Output = $output }
        }
        return $script:CrossRepoGateRun
    }
}

Describe 'the generated artifacts match their sources' {

    It 'keeps every boundary consumer mapped to an owned affected slice' {
        $result = Invoke-Gate -Script 'tools/Invoke-AffectedSliceMap.ps1' `
            -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "the affected-slice evidence is stale or has an unmapped blocker:`n$($result.Output)"
    }

    It 'holds converted literals and machine boundaries to their ratchets' {
        $result = Invoke-Gate -Script 'tools/Test-GlobalizationAuthority.ps1' -Arguments @('-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "converted prose or a message-shaped protocol escaped its gate:`n$($result.Output)"
    }

    It 'reports the compiled catalogs as current' {
        $result = Invoke-Gate -Script 'tools/Invoke-CatalogCompile.ps1' -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "run tools/Invoke-CatalogCompile.ps1 -Update:`n$($result.Output)"
    }

    It 'reports every runtime copy as current' {
        # Browser runtimes and Go modules both carry copies of what the compiler
        # produced. A copy diverges the moment someone edits the near one.
        $result = Invoke-Gate -Script 'tools/Invoke-CatalogEmbed.ps1' -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "run tools/Invoke-CatalogEmbed.ps1:`n$($result.Output)"
    }

    It 'globalization acceptance: all translated documents source current and reachable' {
        # This gate had no automated caller: the project's own gate table listed
        # it while nothing ran it, so a commit that edited an English source
        # left every check green and the drift was caught only when a person
        # remembered to type the command.
        #
        # Exit 2 is "could not run" -- the sibling checkout is absent -- which
        # is not a drift finding and must not be reported as one. It is not a
        # skip either: six of the documents live in that checkout, and
        # documents nobody compared would count as current.
        Confirm-SiblingCheckout -Name 'yuruna-project'
        $result = Invoke-Gate -Script 'tools/Test-DocTranslation.ps1' -Arguments @('-Quiet')
        Assert-False ($result.Code -eq 2) "the document gate could not run:`n$($result.Output)"
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a translated document has drifted from the English it was translated from:`n$($result.Output)"
    }

    It 'runs the gates that reach the project repository' {
        # Every gate in this tree stops at its own edge, and a lab runs a
        # framework and a project from two repositories on two release
        # cadences. Nothing checked the project except the documentation tools
        # that already crossed the boundary.
        #
        # Exit 2 is "a gate could not run" -- no project checkout, or a missing
        # tool -- which is not a pass and must not be reported as one. It is
        # not a skip either: the gates are the subject here, and one that did
        # not run has checked nothing.
        Confirm-SiblingCheckout -Name 'yuruna-project', 'yuruna.link'
        $result = Get-CrossRepoGateRun
        Assert-False ($result.Code -eq 2) `
            "a cross-repository gate could not run on this host; its output names the gate and the repair:`n$($result.Output)"
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a gate failed against the project repository:`n$($result.Output)"
    }

    It 'says which gates in this tree do not reach the project' {
        # The honest half. A gate that cannot reach the project is not a gate
        # the project passes, and reporting it as N/A with a reason is the
        # difference between coverage and the appearance of it.
        #
        # The table is printed whatever the gates in it answer, so only the
        # project checkout is needed here: without one the tool stops before
        # it has a table to print.
        Confirm-SiblingCheckout -Name 'yuruna-project'
        $result = Get-CrossRepoGateRun
        foreach ($gate in @('catalog-compile', 'perf-baseline', 'go-build')) {
            Assert-True ($result.Output -match [regex]::Escape($gate)) "the report does not mention $gate at all"
        }
        Assert-True ($result.Output -match 'not-applicable') `
            'nothing is reported as inapplicable, which would mean every gate reaches a repository it cannot see'
    }

    It 'keeps the private development repository out of every generated artifact' {
        # See https://yuruna.link/42e220c4-0014
        $private = 'yurunadev'
        $offender = [Collections.Generic.List[string]]::new()
        foreach ($dir in @('globalization/manifests', 'globalization/catalogs', 'globalization/generated')) {
            $full = Join-Path $script:RepoRoot $dir
            if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
            foreach ($file in [IO.Directory]::EnumerateFiles($full, '*', [IO.SearchOption]::AllDirectories)) {
                $text = [IO.File]::ReadAllText($file)
                if (-not $text.Contains($private)) { continue }
                $relative = [IO.Path]::GetRelativePath($script:RepoRoot, $file) -replace '\\', '/'
                foreach ($origin in @(Get-PrivateNameOrigin -Text $text -Token $private)) {
                    $offender.Add("$relative carries it from $origin")
                }
            }
        }
        Assert-Equal -Expected 0 -Actual $offender.Count `
            ("a generated artifact names the private development repository:`n  " +
            (@($offender) -join "`n  "))
    }
}
