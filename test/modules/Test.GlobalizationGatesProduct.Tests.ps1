<#PSScriptInfo
.VERSION 2026.10.25
.GUID 42e406f2-c772-4e8c-8d63-9009ff3ddc04
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
    Run the complete product matrix for every enabled production locale and
    hold the generated catalog bytes unchanged around it.
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
}

Describe 'enabled production locales use the complete product matrix' {
    It 'globalization acceptance: full converted domain and matrix coverage' {
        foreach ($tool in @('tools/Invoke-CatalogCompile.ps1', 'tools/Invoke-CatalogEmbed.ps1')) {
            $result = Invoke-Gate -Script $tool -Arguments @('-Check', '-Quiet')
            Assert-Equal 0 $result.Code $result.Output
        }
        Invoke-EnabledProductMatrix
    }

    It 'globalization acceptance: all locales cultures runtimes states and pairing rows' {
        # The manifest selects the locales in the production PS, JS and Go
        # fixtures. Enabling another complete catalog adds its rows directly.
        # Native PowerShell and Safari observations have separate producers.
        Invoke-EnabledProductMatrix
    }

    It 'globalization acceptance: pt-BR zero fallback immutable bytes bounded caches and budgets' {
        # The same checks run before and after Portuguese enablement. Catalog
        # completion and approval are separately required before it is served.
        $generatedRoot = Join-Path $script:RepoRoot 'globalization/generated'
        $before = @{}
        foreach ($file in (Get-ChildItem -LiteralPath $generatedRoot -File -Recurse)) {
            $before[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        Assert-True ($before.Count -gt 0) 'there are no generated production catalog bytes'
        Invoke-EnabledProductMatrix
        Assert-True ($script:ProductMatrixImmutableEvidence.Count -gt 0) 'immutable evidence must surround actual product rendering'
        foreach ($file in $before.Keys) {
            Assert-StringEqual $before[$file] (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash `
                "runtime rendering mutated $file"
        }
        foreach ($tool in @('tools/Invoke-PerfBaseline.ps1', 'tools/Test-Utf8Catalog.ps1')) {
            $result = Invoke-Gate -Script $tool -Arguments @('-Quiet')
            Assert-Equal 0 $result.Code $result.Output
        }
    }
}
