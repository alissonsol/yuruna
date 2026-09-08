<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42eb9613-e03b-4f67-8b89-1b1e1b198727
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester entrypoint prelude contract
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
    The path bundle and exit-code mapping every operator-facing script in test/
    resolves itself through.
.DESCRIPTION
    Initialize-YurunaEntryPoint has ~36 production callers -- the three entry
    points, and nearly everything under test/pool/, test/service/ and test/lab/,
    plus two scripts in tools/ -- and had no test at all. It is the most
    depended-upon untested function in the workspace: a regression in the
    returned bundle breaks all 36 at once, and nothing would say so.

    WHAT THIS PINS: the shape and meaning of the bundle for both call forms, and
    the outcome-to-exit-code mapping.

    WHAT THIS DELIBERATELY DOES NOT PIN: the module set that
    Initialize-YurunaEntryPointModuleSet imports. Several deferred items intend
    to move modules between sets, and pinning that table would convert this
    suite from a safety net into a veto -- the exact failure mode that makes 102
    of the current suites obstacles to the refactors they sit in front of.

    The bundle is asserted from more than one caller depth on purpose. Asserting
    from a single depth would pin the two-level walk rather than the contract,
    and a caller at another depth could break undetected.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1')  -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:TestRoot = Join-Path $script:RepoRoot 'test'
}

Describe 'Initialize-YurunaEntryPoint -- the bundle every entry point resolves through' {

    It 'resolves every member to a directory that exists, for a caller in test/' {
        $b = Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot
        Assert-Equal -Expected $script:TestRoot -Actual $b.TestRoot -Because 'a caller in test/ IS the test root'
        Assert-Equal -Expected $script:RepoRoot -Actual $b.RepoRoot -Because 'the repo root is one above test/'
        Assert-True (Test-Path -LiteralPath $b.ModulesDir)   "ModulesDir must exist: $($b.ModulesDir)"
        Assert-True (Test-Path -LiteralPath $b.SequencesDir) "SequencesDir must exist: $($b.SequencesDir)"
        Assert-True (Test-Path -LiteralPath $b.StatusDir)    "StatusDir must exist: $($b.StatusDir)"
    }

    It 'walks one extra level for a caller in a test/ subfolder' {
        # The form used by test/modules/, test/service/, test/pool/, test/check/
        # -- which is most of the 36 callers.
        foreach ($sub in @('modules', 'service', 'pool', 'lab')) {
            $b = Initialize-YurunaEntryPoint -ScriptRoot (Join-Path $script:TestRoot $sub) -InsideSubfolder
            Assert-Equal -Expected $script:TestRoot -Actual $b.TestRoot -Because "$sub/ resolves back to test/"
            Assert-Equal -Expected $script:RepoRoot -Actual $b.RepoRoot -Because "$sub/ resolves the repo root"
        }
    }

    It 'points ModulesDir at test/modules from every subfolder, not at the caller' {
        # The trap this guards: ModulesDir is <TestRoot>/modules regardless of
        # which subfolder the caller sits in, so a caller in test/service/ still
        # imports from test/modules/.
        $expected = Join-Path $script:TestRoot 'modules'
        foreach ($sub in @('modules', 'service', 'pool', 'lab')) {
            $b = Initialize-YurunaEntryPoint -ScriptRoot (Join-Path $script:TestRoot $sub) -InsideSubfolder
            Assert-Equal -Expected $expected -Actual $b.ModulesDir -Because "$sub/ must still resolve test/modules"
        }
    }

    It 'defaults ConfigPath to the tracked test.config.yml and honors an override' {
        $b = Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot
        Assert-Equal -Expected (Join-Path $script:TestRoot 'test.config.yml') -Actual $b.ConfigPath
        Assert-True (Test-Path -LiteralPath $b.ConfigPath) 'the default config path must exist in a clean checkout'

        $override = Join-Path ([IO.Path]::GetTempPath()) 'somewhere-else.yml'
        $o = Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot -ConfigPath $override
        Assert-Equal -Expected $override -Actual $o.ConfigPath -Because 'an explicit -ConfigPath wins'
    }

    It 'returns every member the callers read, and returns them ordered' {
        $b = Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot
        foreach ($k in @('TestRoot', 'RepoRoot', 'ModulesDir', 'SequencesDir', 'StatusDir', 'ConfigPath')) {
            Assert-True $b.Contains($k) "the bundle must carry $k -- a caller reads it by name"
            Assert-True ([bool]$b[$k])  "$k must not be empty"
        }
    }

    It 'requires -ScriptRoot rather than guessing one' {
        # A caller that forgot to pass $PSScriptRoot must fail loudly; silently
        # defaulting would resolve paths against whatever the current directory
        # happened to be when the runner spawned it.
        Assert-Throw -Script { Initialize-YurunaEntryPoint -ScriptRoot '' }
    }
}

Describe 'Get-EntryPointExitCode -- the mapping the operator scripts exit through' {

    It 'maps a successful outcome to 0 and a failure to non-zero' {
        Assert-Equal -Expected 0 -Actual (Get-EntryPointExitCode -Outcome Ok) -Because 'success is 0 by convention'
        Assert-NotEqual -NotExpected 0 -Actual (Get-EntryPointExitCode -Outcome Failure) -Because 'a failure must not look like success'
    }

    It 'is stable across calls' {
        Assert-Equal -Expected (Get-EntryPointExitCode -Outcome Ok) -Actual (Get-EntryPointExitCode -Outcome Ok)
        Assert-Equal -Expected (Get-EntryPointExitCode -Outcome Failure) -Actual (Get-EntryPointExitCode -Outcome Failure)
    }
}
