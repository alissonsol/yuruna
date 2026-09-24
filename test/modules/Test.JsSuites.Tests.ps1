<#PSScriptInfo
.VERSION 2026.09.24
.GUID 421d8999-cae4-4164-90cd-fd5cc6a6e28f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test javascript node pester
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
    Guards that tools/Invoke-JsTest.ps1 finds every JavaScript self-test and
    never reports a run it could not make as a pass.
.DESCRIPTION
    The *.test.js files carry real assertions about the browser assets, so the
    thing that can quietly lose them is discovery: a pathspec that stops
    matching a subdirectory drops those assertions from the gate while the
    summary still reads green. The tracked files are therefore named
    literally here rather than derived, so this suite disagrees with the runner
    when the runner stops seeing one.

    The second guard is the missing-toolchain path. node is not a build
    dependency of this repo and is absent on most hosts, so that path is the
    common one, and an "everything passed" summary from a host that ran nothing
    is worse than no gate at all: it is a false negative that hides whatever
    the JavaScript checks would have caught.

    A host that HAS node cannot be made to take that path without hiding node
    from the child process, and node commonly shares a directory with git,
    which the runner needs for discovery. So that case reports itself skipped
    rather than pretending to have checked -- the same distinction the runner
    itself is being held to.
    Run: pwsh -NoProfile -File test/modules/Test.JsSuites.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Runner   = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Invoke-JsTest.ps1'

# Every tracked JavaScript self-test, spelled out. Deriving this list the way
# the runner derives it would make the check agree with a broken pathspec.
$script:Expected = @(
    'test/extension/stash-service/server/internal/httpsrv/web/assets/common.test.js',
    'test/extension/stash-service/server/internal/httpsrv/web/assets/index.test.js',
    'test/extension/ui-pages.test.js',
    'test/status/globalization-pages.test.js',
    'test/status/performance.test.js',
    'test/status/status-badges.test.js',
    'test/status/yuruna.common.test.js'
)

$script:NodeAbsent = -not (Get-Command node -ErrorAction SilentlyContinue)

# A child pwsh, because the exit code is half of what is under test and only
# survives a process boundary.
$script:Output   = (& pwsh -NoProfile -File $script:Runner 2>&1 | Out-String)
$script:ExitCode = $LASTEXITCODE
}

Describe 'Invoke-JsTest discovery' {
    It 'names every tracked *.test.js in its report' {
        foreach ($file in $script:Expected) {
            Assert-Match -Pattern ([regex]::Escape($file)) -Actual $script:Output `
                -Because "$file is a tracked JavaScript self-test and must appear in the run report"
        }
    }

    It 'counts the files it reports' {
        Assert-Match -Pattern "$($script:Expected.Count) JavaScript test file\(s\)" -Actual $script:Output `
            -Because 'the summary count must match the files named above'
    }

    It 'finds an untracked candidate test but excludes ignored scratch output' {
        $root = Join-Path $TestDrive 'js-candidate'
        New-Item -ItemType Directory -Path (Join-Path $root 'test') -Force | Out-Null
        & git -C $root init --quiet
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "test/ignored.test.js`n")
        [IO.File]::WriteAllText((Join-Path $root 'test/candidate.test.js'),
            "'use strict';`nconsole.log('PASS candidate');`n")
        [IO.File]::WriteAllText((Join-Path $root 'test/ignored.test.js'),
            "throw new Error('ignored');`n")
        $output = & pwsh -NoProfile -File $script:Runner -Root $root 2>&1 | Out-String
        $code = $LASTEXITCODE
        Assert-Match -Pattern '1 JavaScript test file\(s\)' -Actual $output `
            'candidate discovery omitted the untracked test or included ignored output'
        Assert-Match -Pattern 'test/candidate\.test\.js' -Actual $output `
            'the untracked JavaScript test was not named'
        Assert-False ($output -match 'ignored\.test\.js') `
            'ignored scratch output entered the JavaScript gate'
        Assert-True ($code -in @(0, 2)) `
            "candidate discovery should either execute with node or report node unavailable; exit was $code"
    }
}

Describe 'Invoke-JsTest with node absent' {
    It 'reports SKIPPED with the reason, and never a pass' {
        if (-not $script:NodeAbsent) {
            Set-ItResult -Skipped -Because 'node is installed on this host, so the missing-toolchain path cannot be reached'
            return
        }

        Assert-Match -Pattern 'SKIPPED: node is not installed or not on PATH' -Actual $script:Output `
            -Because 'the reason a gate did not run has to be in its own output'
        Assert-Match -Pattern '0 run' -Actual $script:Output `
            -Because 'a skipped run must not claim to have executed anything'
        Assert-True (-not ($script:Output -match '(?m)^ok ')) `
            'no file may be reported as passing when none of them ran'
        Assert-True (-not ($script:Output -match '0 failed')) `
            'a zero-failure summary from a run that never happened is the false negative this guards'
    }

    It 'marks every discovered file SKIPPED' {
        if (-not $script:NodeAbsent) {
            Set-ItResult -Skipped -Because 'node is installed on this host, so the missing-toolchain path cannot be reached'
            return
        }

        foreach ($file in $script:Expected) {
            Assert-Match -Pattern "(?m)^SKIPPED $([regex]::Escape($file))$" -Actual $script:Output `
                -Because "$file was discovered but not run, and has to say so per file"
        }
    }

    It 'exits with the missing-toolchain code, distinct from success and from a test failure' {
        if (-not $script:NodeAbsent) {
            Set-ItResult -Skipped -Because 'node is installed on this host, so the missing-toolchain path cannot be reached'
            return
        }

        Assert-Equal -Expected 2 -Actual $script:ExitCode `
            -Because 'exit 0 would report green from a host that checked nothing, and exit 1 would claim a JavaScript assertion failed'
    }
}
