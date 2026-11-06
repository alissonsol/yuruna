<#PSScriptInfo
.VERSION 2026.11.05
.GUID 428e0703-5bdd-4015-97de-34d603a5a9ef
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lint pssa catch pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES PSScriptAnalyzer
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    The silent-catch analyzer rule: a catch block whose whole body discards
    the error is a finding in PowerShell outside the Pester suites, unless the
    file's allowance still covers it, and every allowance equals what its file
    holds.
.DESCRIPTION
    The rule cases analyze files of a disposable repository below TestDrive
    that carries a copy of tools/Analyzer.SilentCatch.psm1 beside allowance
    lists written for the case, so each case states the allowance it is judged
    against. The remaining cases read the real tree: the repository settings
    load the rule beside the default rules, and each allowance list names
    exactly the files that still hold such a catch, with the count each holds.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module PSScriptAnalyzer -ErrorAction Stop

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:RuleModule = Join-Path $script:RepoRoot 'tools/Analyzer.SilentCatch.psm1'
    $script:Settings = Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1'
    $script:RuleName = 'Measure-SilentCatch'
    $script:PublicList = 'tools/silent-catch.allowance.json'
    $script:PrivateList = 'dev-only/tools/silent-catch.allowance.json'
    $script:Utf8 = [Text.UTF8Encoding]::new($false)

    function New-RuleFixture {
        <#
        .SYNOPSIS
            A disposable repository holding a copy of the rule and the two
            allowance lists one case is judged against.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates only disposable files below TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([hashtable]$Allowance = @{}, [hashtable]$PrivateAllowance = @{})

        $root = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'tools'), (Join-Path $root 'dev-only/tools') -Force
        Copy-Item -LiteralPath $script:RuleModule -Destination (Join-Path $root 'tools/Analyzer.SilentCatch.psm1') -ErrorAction Stop
        foreach ($list in @(
                @{ Path = $script:PublicList; Files = $Allowance }
                @{ Path = $script:PrivateList; Files = $PrivateAllowance })) {
            $document = [ordered]@{ schemaVersion = 1; description = 'fixture'; files = $list.Files }
            [IO.File]::WriteAllText((Join-Path $root $list.Path), (ConvertTo-Json -InputObject $document -Depth 3), $script:Utf8)
        }
        return $root
    }

    function Invoke-FixtureRule {
        <#
        .SYNOPSIS
            Write one source file into a fixture repository and return what the
            rule reports for it.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory)][string]$Root,
            [Parameter(Mandatory)][string]$RelativePath,
            [Parameter(Mandatory)][string]$Text
        )

        $path = Join-Path $Root $RelativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
        [IO.File]::WriteAllText($path, $Text, $script:Utf8)
        $rule = Join-Path $Root 'tools/Analyzer.SilentCatch.psm1'
        return @(Invoke-ScriptAnalyzer -Path $path -CustomRulePath $rule -ErrorAction Stop |
            Where-Object RuleName -CEQ $script:RuleName)
    }

    function Read-AllowanceList {
        <#
        .SYNOPSIS
            The entries of one allowance list of the real tree, by exact path,
            or $null when the list is absent.
        #>
        [CmdletBinding()]
        [OutputType([Collections.Generic.Dictionary[string, object]])]
        param([Parameter(Mandatory)][string]$RelativePath)

        $path = Join-Path $script:RepoRoot $RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
        $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($property in (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))).files.PSObject.Properties) {
            $entries[$property.Name] = $property.Value
        }
        return $entries
    }
}

Describe 'the silent-catch rule' {
    It 'flags a catch whose only statement assigns $_ to $null, in any spacing or casing' {
        $root = New-RuleFixture
        $text = @(
            'try { Get-Item -LiteralPath ''a'' } catch { $null = $_ }'
            'try { Get-Item -LiteralPath ''b'' } catch {$NULL=$_}'
            'try { Get-Item -LiteralPath ''c'' }'
            'catch {'
            '    $Null   =   $_'
            '}'
            'try { Get-Item -LiteralPath ''d'' } catch [System.IO.IOException] { $null = $PSItem }'
        ) -join "`n"
        $found = Invoke-FixtureRule -Root $root -RelativePath 'src/silent.ps1' -Text $text
        @($found.Line | Sort-Object) | Should -Be @(1, 2, 4, 7)
        $found[0].Message | Should -Match 'only assigns \$_ to \$null'
        $found[0].Message | Should -Match 'src/silent\.ps1 holds 4 '
    }

    It 'flags an empty catch, including one that holds only a comment' {
        $root = New-RuleFixture
        $text = @(
            'try { Get-Item -LiteralPath ''a'' } catch { }'
            'try { Get-Item -LiteralPath ''b'' } catch {'
            '    # The item is optional.'
            '}'
        ) -join "`n"
        $found = Invoke-FixtureRule -Root $root -RelativePath 'src/empty.ps1' -Text $text
        @($found.Line | Sort-Object) | Should -Be @(1, 2)
        $found[0].Message | Should -Match 'is empty'
    }

    It 'leaves alone a catch that writes a reason, keeps the error or rethrows it' {
        $root = New-RuleFixture
        $text = @(
            'try { Get-Item -LiteralPath ''a'' } catch { Write-Verbose "a is optional: $($_.Exception.Message)" }'
            'try { Get-Item -LiteralPath ''b'' } catch { Write-Warning $_.Exception.Message }'
            'try { Get-Item -LiteralPath ''c'' } catch { $failure = $_ }'
            'try { Get-Item -LiteralPath ''d'' } catch { throw }'
            'try { Get-Item -LiteralPath ''e'' } catch { $null = $_; Write-Verbose ''e is optional'' }'
        ) -join "`n"
        Invoke-FixtureRule -Root $root -RelativePath 'src/handled.ps1' -Text $text | Should -BeNullOrEmpty
    }

    It 'never counts a catch inside a string: C# for Add-Type, JavaScript, or PowerShell text' {
        # A count over the text takes the empty catches of C# handed to Add-Type
        # for PowerShell ones; the rule reads the parsed script only.
        $root = New-RuleFixture
        $text = @(
            'Add-Type -TypeDefinition @'''
            'public static class SilentCatchProbe {'
            '    public static int Read() {'
            '        try { return int.Parse("1"); } catch { }'
            '        try { return int.Parse("2"); } catch (System.FormatException) { }'
            '        return 0;'
            '    }'
            '}'
            '''@'
            '$page = ''try { run(); } catch (e) { }'''
            '$snippet = ''try { 1 } catch { $null = $_ }'''
        ) -join "`n"
        Invoke-FixtureRule -Root $root -RelativePath 'src/strings.ps1' -Text $text | Should -BeNullOrEmpty
    }

    It 'exempts a Pester suite by its file name, not by its folder' {
        $root = New-RuleFixture
        $text = "try { 1 } catch { `$null = `$_ }`ntry { 2 } catch { }`n"
        Invoke-FixtureRule -Root $root -RelativePath 'test/Sample.Tests.ps1' -Text $text | Should -BeNullOrEmpty
        @(Invoke-FixtureRule -Root $root -RelativePath 'test/Sample.Helper.ps1' -Text $text).Count | Should -Be 2
    }

    It 'accepts a listed file that holds exactly its allowance' {
        $root = New-RuleFixture -Allowance @{ 'src/listed.ps1' = 2 }
        $text = "try { 1 } catch { `$null = `$_ }`ntry { 2 } catch { `$null = `$_ }`n"
        Invoke-FixtureRule -Root $root -RelativePath 'src/listed.ps1' -Text $text | Should -BeNullOrEmpty
    }

    It 'flags every such catch of a file that holds more than its allowance' {
        $root = New-RuleFixture -Allowance @{ 'src/listed.ps1' = 1 }
        $text = "try { 1 } catch { `$null = `$_ }`ntry { 2 } catch { `$null = `$_ }`n"
        $found = Invoke-FixtureRule -Root $root -RelativePath 'src/listed.ps1' -Text $text
        @($found.Line | Sort-Object) | Should -Be @(1, 2)
        $found[0].Message | Should -Match 'src/listed\.ps1 holds 2 .*tools/silent-catch\.allowance\.json allows 1'
    }

    It 'holds a file the list does not name to none' {
        $root = New-RuleFixture -Allowance @{ 'src/listed.ps1' = 5 }
        $found = Invoke-FixtureRule -Root $root -RelativePath 'src/other.ps1' -Text "try { 1 } catch { `$null = `$_ }`n"
        @($found).Count | Should -Be 1
        $found[0].Message | Should -Match 'allows 0'
    }

    It 'reads the allowance of a dev-only file from the private list alone' {
        $text = "try { 1 } catch { `$null = `$_ }`n"
        $root = New-RuleFixture -PrivateAllowance @{ 'dev-only/tools/tool.ps1' = 1 }
        Invoke-FixtureRule -Root $root -RelativePath 'dev-only/tools/tool.ps1' -Text $text | Should -BeNullOrEmpty
        $root = New-RuleFixture -Allowance @{ 'dev-only/tools/tool.ps1' = 1 }
        $found = Invoke-FixtureRule -Root $root -RelativePath 'dev-only/tools/tool.ps1' -Text $text
        @($found).Count | Should -Be 1
        $found[0].Message | Should -Match 'dev-only/tools/silent-catch\.allowance\.json allows 0'
    }

    It 'holds text without a file, such as an editor buffer, to none' {
        $root = New-RuleFixture -Allowance @{ 'src/listed.ps1' = 5 }
        # Text without -Settings also reads a PSScriptAnalyzerSettings.psd1 in
        # the current directory, which would load the repository's own copy of
        # the rule beside the fixture's.
        Push-Location -LiteralPath $root
        try {
            $found = @(Invoke-ScriptAnalyzer -ScriptDefinition "try { 1 } catch { `$null = `$_ }" `
                    -CustomRulePath (Join-Path $root 'tools/Analyzer.SilentCatch.psm1') -ErrorAction Stop |
                    Where-Object RuleName -CEQ $script:RuleName)
        } finally { Pop-Location }
        @($found).Count | Should -Be 1
    }
}

Describe 'the repository settings' {
    BeforeAll {
        $script:Probe = Join-Path $TestDrive 'settings-probe.ps1'
        [IO.File]::WriteAllText($script:Probe, "try { Write-Host 'probe' } catch { `$null = `$_ }`n", $script:Utf8)
    }

    It 'load the rule beside the default rules' {
        # The settings are used from the repository root, which is where
        # PSScriptAnalyzer looks for their relative CustomRulePath.
        Push-Location -LiteralPath $script:RepoRoot
        try { $found = @(Invoke-ScriptAnalyzer -Path $script:Probe -Settings $script:Settings -ErrorAction Stop) }
        finally { Pop-Location }
        $found.RuleName | Should -Contain $script:RuleName
        $found.RuleName | Should -Contain 'PSAvoidUsingWriteHost'
    }

    It 'never lint without the rule from another working directory' {
        # PSScriptAnalyzer resolves the settings' CustomRulePath against the
        # current location, not against the settings file. Elsewhere the call
        # must fail on the missing rule; linting on without it would read as
        # a clean result.
        $found = @()
        $failure = ''
        Push-Location -LiteralPath $TestDrive
        try { $found = @(Invoke-ScriptAnalyzer -Path $script:Probe -Settings $script:Settings -ErrorAction Stop) }
        catch { $failure = $_.Exception.Message }
        finally { Pop-Location }
        if ($failure) { $failure | Should -Match 'Analyzer\.SilentCatch\.psm1' }
        else { $found.RuleName | Should -Contain $script:RuleName }
    }

    It 'reach the rule through tools/Invoke-Lint.ps1 started from another working directory' {
        $lint = Join-Path $script:RepoRoot 'tools/Invoke-Lint.ps1'
        Push-Location -LiteralPath $TestDrive
        try {
            $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $lint -Path $script:Probe 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally { Pop-Location }
        $output | Should -Match "settings-probe\.ps1:1:\d+\s+$([regex]::Escape($script:RuleName))\s"
        $output | Should -Not -Match 'UNANALYZED'
        $code | Should -Be 1
    }
}

Describe 'the allowance lists' {
    BeforeAll {
        Import-Module $script:RuleModule -Force -ErrorAction Stop
        $script:Public = Read-AllowanceList -RelativePath $script:PublicList
        $script:Private = Read-AllowanceList -RelativePath $script:PrivateList
    }

    It 'name every file that holds such a catch, each with exactly the count it holds' {
        Assert-NotNull $script:Public "$script:PublicList is missing"
        $listed = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $malformed = foreach ($list in @($script:Public, $script:Private)) {
            if ($null -eq $list) { continue }
            foreach ($entry in $list.GetEnumerator()) {
                $listed[$entry.Key] = $entry.Value
                if ($entry.Value -isnot [long] -or $entry.Value -lt 1) {
                    "$($entry.Key): '$($entry.Value)' is not a whole number of at least 1; an entry that reaches 0 is removed"
                }
            }
        }
        Assert-NoFinding $malformed 'an allowance list holds an entry that is not a count'

        # The selector tools/Invoke-Lint.ps1 lints: tracked and new files that
        # .gitignore does not cover. The Pester suites are exempt from the rule.
        $files = @(& git -C $script:RepoRoot ls-files --cached --others --exclude-standard |
            Where-Object { $_ -match '\.(ps1|psm1|psd1)$' -and $_ -notlike '*.Tests.ps1' } |
            Where-Object { Test-Path -LiteralPath (Join-Path $script:RepoRoot $_) -PathType Leaf })
        Assert-Equal 0 $LASTEXITCODE 'git could not list the files of the repository'
        Assert-True ($files.Count -gt 100) 'the file listing is too short to be the repository'
        $held = InModuleScope -ModuleName Analyzer.SilentCatch -Parameters @{ Root = $script:RepoRoot; Files = $files } {
            param($Root, $Files)
            $counts = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
            foreach ($relative in $Files) {
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Root $relative), [ref]$null, [ref]$null)
                $count = @(Find-SilentCatchClause -Ast $ast).Count
                if ($count) { $counts[$relative] = $count }
            }
            $counts
        }

        $paths = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach ($path in @($listed.Keys) + @($held.Keys)) { $null = $paths.Add($path) }
        $mismatch = foreach ($path in $paths) {
            $allowed = if ($listed.ContainsKey($path)) { $listed[$path] } else { 0 }
            $holds = if ($held.ContainsKey($path)) { $held[$path] } else { 0 }
            if ($allowed -ne $holds) { "${path}: listed at $allowed, holds $holds" }
        }
        Assert-NoFinding $mismatch ('an allowance differs from what its file holds. A list only shrinks: lower ' +
            'the entry of a file whose catch was fixed, or remove it at 0, in the same change; fix a new ' +
            'catch instead of listing it')
    }

    It 'keep the dev-only files in the private list, which the release strips with them' {
        Assert-NotNull $script:Public "$script:PublicList is missing"
        $leaked = @($script:Public.Keys | Where-Object { $_.StartsWith('dev-only/', [StringComparison]::Ordinal) })
        Assert-NoFinding $leaked "$script:PublicList names a dev-only file, which the public tree does not carry"
        if ($null -ne $script:Private) {
            $strays = @($script:Private.Keys | Where-Object { -not $_.StartsWith('dev-only/', [StringComparison]::Ordinal) })
            Assert-NoFinding $strays "$script:PrivateList names a file outside dev-only/"
        }
    }
}
