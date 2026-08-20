<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42236bc2-fc6c-4607-abaa-81fea9bc8e86
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester assert scaffold
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
    Test.Assert.psm1 -- every assertion's PASS path and, more importantly, its
    FAIL path.
.DESCRIPTION
    An assertion helper that cannot fail is the one defect that would invalidate
    every other suite in the repo at once: ~2,800 call sites would report green
    while asserting nothing, and no other test could detect it. So each helper
    is checked both ways here, and the fail path is checked by asserting that a
    throw actually happens -- using PowerShell's own try/catch rather than the
    module under test, so the check does not depend on the thing it is checking.

    The alias cases are not decoration. Aliases are what let ~2,800 existing
    call sites keep their historical spellings through the migration, so a
    dropped alias would break suites in bulk; each one is pinned.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    # Deliberately NOT written with the module under test: a helper that never
    # throws would otherwise make its own fail-path tests pass.
    function Test-Throw {
        param([scriptblock]$Script)
        try { & $Script; return $false } catch { return $true }
    }
}

Describe 'Assert-True / Assert-False' {
    It 'passes on the condition it names' {
        Assert-True $true
        Assert-False $false
    }
    It 'throws on the condition it denies' {
        (Test-Throw { Assert-True $false })  | Should -BeTrue
        (Test-Throw { Assert-False $true })  | Should -BeTrue
    }
    It 'carries the reason into the failure message' {
        try { Assert-True $false 'the reason'; throw 'unreachable' }
        catch { $_.Exception.Message | Should -Match 'the reason' }
    }
}

Describe 'Assert-Equal compares by VALUE' {
    It 'passes on equal values' {
        Assert-Equal -Expected 1 -Actual 1
        Assert-Equal -Expected 'a' -Actual 'a'
    }
    It 'throws on unequal values' {
        (Test-Throw { Assert-Equal -Expected 1 -Actual 2 }) | Should -BeTrue
    }
    It 'agrees with string comparison on the easy coercions' {
        # `1 -ne '1'` is FALSE: PowerShell coerces the right operand to the left
        # operand's type, so the two semantics agree here. Pinned because the
        # obvious intuition -- that value comparison is stricter about types --
        # is wrong, and a future "simplification" to one helper would lean on it.
        Assert-Equal -Expected 1 -Actual '1'
        Assert-Equal -Expected $true -Actual 'True'
    }

    It 'diverges from string comparison exactly where it matters' {
        # The real gap between the two semantics, and why the coercing suites
        # move to Assert-StringEqual rather than being folded in:
        #   leading zeros / whitespace / float rendering -- value says equal
        Assert-Equal -Expected 1 -Actual '01'
        Assert-Equal -Expected 1.0 -Actual '1.0'
        (Test-Throw { Assert-StringEqual -Expected 1 -Actual '01' }) | Should -BeTrue
        #   null against empty string -- value says DIFFERENT, string says same
        (Test-Throw { Assert-Equal -Expected $null -Actual '' }) | Should -BeTrue
        Assert-StringEqual -Expected $null -Actual ''
    }

    It 'throws on two identical arrays, which string comparison accepts' {
        # The sharpest edge in the whole migration. `-ne` on arrays filters
        # rather than compares, so a value-comparing Assert-Equal REJECTS two
        # equal arrays. Any coercing suite passing arrays would have started
        # failing had it been folded into value semantics instead of moved to
        # Assert-StringEqual.
        (Test-Throw { Assert-Equal -Expected @(1, 2) -Actual @(1, 2) }) | Should -BeTrue
        Assert-StringEqual -Expected @(1, 2) -Actual @(1, 2)
    }
    It 'names both sides in the failure message' {
        try { Assert-Equal -Expected 'want' -Actual 'got'; throw 'unreachable' }
        catch {
            $_.Exception.Message | Should -Match 'want'
            $_.Exception.Message | Should -Match 'got'
        }
    }
}

Describe 'Assert-StringEqual compares renderings' {
    It 'accepts an int against its string rendering' {
        Assert-StringEqual -Expected 1 -Actual '1'
    }
    It 'still throws when the renderings differ' {
        (Test-Throw { Assert-StringEqual -Expected 'a' -Actual 'b' }) | Should -BeTrue
    }
}

Describe 'Assert-NotEqual' {
    It 'passes when the values differ and throws when they match' {
        Assert-NotEqual -NotExpected 1 -Actual 2
        (Test-Throw { Assert-NotEqual -NotExpected 1 -Actual 1 }) | Should -BeTrue
    }
    It 'accepts the historical -Expected spelling as an alias' {
        Assert-NotEqual -Expected 1 -Actual 2
        (Test-Throw { Assert-NotEqual -Expected 1 -Actual 1 }) | Should -BeTrue
    }
}

Describe 'Assert-Null / Assert-NotNull' {
    It 'passes and throws on each side' {
        Assert-Null -Actual $null
        Assert-NotNull -Actual 'x'
        (Test-Throw { Assert-Null -Actual 'x' })    | Should -BeTrue
        (Test-Throw { Assert-NotNull -Actual $null }) | Should -BeTrue
    }
    It 'accepts the historical -Value spelling as an alias' {
        Assert-Null -Value $null
        (Test-Throw { Assert-Null -Value 'x' }) | Should -BeTrue
    }
}

Describe 'Assert-Match' {
    It 'passes on a match and throws on a miss' {
        Assert-Match -Pattern '^ab' -Actual 'abc'
        (Test-Throw { Assert-Match -Pattern '^zz' -Actual 'abc' }) | Should -BeTrue
    }
}

Describe 'Assert-Throw' {
    It 'passes when the scriptblock throws' {
        Assert-Throw -Script { throw 'boom' }
    }
    It 'throws when the scriptblock does NOT throw' {
        (Test-Throw { Assert-Throw -Script { 'quiet' } }) | Should -BeTrue
    }
    It 'enforces the message pattern when one is given' {
        Assert-Throw -Script { throw 'boom' } -Match 'boom'
        (Test-Throw { Assert-Throw -Script { throw 'boom' } -Match 'nope' }) | Should -BeTrue
    }
    It 'accepts the historical -Action spelling as an alias' {
        Assert-Throw -Action { throw 'boom' }
    }
}

Describe 'Assert-NoFinding' {
    It 'passes on an empty or null list' {
        Assert-NoFinding -Finding @()
        Assert-NoFinding -Finding $null
    }
    It 'throws listing every finding' {
        try { Assert-NoFinding -Finding @('first', 'second') 'header'; throw 'unreachable' }
        catch {
            $_.Exception.Message | Should -Match 'first'
            $_.Exception.Message | Should -Match 'second'
            $_.Exception.Message | Should -Match 'header'
        }
    }
    It 'accepts the historical -Findings spelling as an alias' {
        Assert-NoFinding -Findings @()
        (Test-Throw { Assert-NoFinding -Findings @('x') }) | Should -BeTrue
    }
}

Describe 'the scaffolds' {
    It 'resolves the repo root from a suite directory' {
        $root = Get-YurunaTestRepoRoot -SuiteDirectory (Split-Path -Parent $PSCommandPath)
        (Test-Path -LiteralPath (Join-Path $root 'test/modules')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $root 'tools'))        | Should -BeTrue
    }

    It 'matches the two spellings the suites already use' {
        # Both forms appear ~30 times each across the suites; they must agree,
        # or migrating one to the other would silently repoint every path.
        $hereDir = Split-Path -Parent $PSCommandPath
        $a = (Resolve-Path (Join-Path -Path $hereDir -ChildPath '..' -AdditionalChildPath '..')).Path
        $b = Split-Path -Parent (Split-Path -Parent $hereDir)
        Get-YurunaTestRepoRoot -SuiteDirectory $hereDir | Should -Be $a
        Get-YurunaTestRepoRoot -SuiteDirectory $hereDir | Should -Be $b
    }

    It 'hands out a fresh empty directory each call, and removes it' {
        $a = New-YurunaTestTempDir
        $b = New-YurunaTestTempDir
        try {
            $a | Should -Not -Be $b
            (Test-Path -LiteralPath $a) | Should -BeTrue
            @(Get-ChildItem -LiteralPath $a).Count | Should -Be 0
        } finally {
            Remove-YurunaTestTempDir $a
            Remove-YurunaTestTempDir $b
        }
        (Test-Path -LiteralPath $a) | Should -BeFalse
    }

    It 'never throws while cleaning up a path that is already gone' {
        # Cleanup runs in finally blocks, where a throw would mask the real
        # failure the test was reporting.
        Remove-YurunaTestTempDir (Join-Path ([IO.Path]::GetTempPath()) 'yuruna-absent-xyz')
        Remove-YurunaTestTempDir $null
    }

    It 'parses a file to an AST and names a file that will not parse' {
        $dir = New-YurunaTestTempDir
        try {
            $good = Join-Path $dir 'good.ps1'
            Set-Content -LiteralPath $good -Value 'function Alpha { 1 }' -Encoding utf8NoBOM
            (Get-YurunaTestFileAst -Path $good) | Should -Not -BeNullOrEmpty

            $bad = Join-Path $dir 'bad.ps1'
            Set-Content -LiteralPath $bad -Value 'function Alpha { ' -Encoding utf8NoBOM
            try { $null = Get-YurunaTestFileAst -Path $bad; throw 'unreachable' }
            catch { $_.Exception.Message | Should -Match 'does not parse' }
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'finds a named function and returns null for an absent one' {
        $dir = New-YurunaTestTempDir
        try {
            $f = Join-Path $dir 'mod.ps1'
            Set-Content -LiteralPath $f -Value "function Alpha { 1 }`nfunction Beta { 2 }" -Encoding utf8NoBOM
            (Get-YurunaTestFunctionAst -Path $f -Name 'Beta').Name | Should -Be 'Beta'
            (Get-YurunaTestFunctionAst -Path $f -Name 'Missing')   | Should -BeNullOrEmpty
        } finally { Remove-YurunaTestTempDir $dir }
    }
}
