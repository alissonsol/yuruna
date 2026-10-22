<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42e4327a-7096-4725-be4a-7aa76f2b35c0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation yaml conversion pester
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
    Holds automation/Import.Yaml.psm1 to its contract: what reaches the YAML
    parser, what a host without the parser module is told, how often the module
    is looked for, and which commands the module exports.
.DESCRIPTION
    Every resources, components and workloads file the automation reads goes
    through ConvertFrom-File, up to five times per entry point. Each lookup of
    the parser module searches the module path on disk again, so the module
    remembers a positive answer for as long as it stays loaded. A negative
    answer is never remembered: an operator who installs the module and
    retries in the same session must not be told it is still missing.

    Nothing here loads powershell-yaml. The module resolves ConvertFrom-Yaml and
    Get-Module by name when a conversion runs, so a parser stand-in defined in
    the module's own scope and a mocked Get-Module replace both, and the same
    tests run on a host that has the gallery module and on one that does not.

    Each test imports the module with -Force first. That is also how an
    automation entry point gets its copy, and it is what forgets a remembered
    answer.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ModulePath = Join-Path $script:RepoRoot 'automation/Import.Yaml.psm1'
    $script:MissingModuleKey = 'automation.operator_4eeea39bff48dea5'

    function Import-YamlModuleUnderTest {
        Import-Module $script:ModulePath -Force
        # A function in the module's own scope wins name resolution there, so the
        # module never reaches (or auto-loads) the gallery parser. It throws unless
        # a test mocks it, which keeps an unexpected parse from passing silently.
        & (Get-Module -Name Import.Yaml) {
            function script:ConvertFrom-Yaml {
                param([Parameter(Position = 0)]$Yaml, [switch]$Ordered)
                throw "The parser stand-in ran without a mock (Ordered=$Ordered): $Yaml"
            }
        }
    }

    function Get-ThrownMessage {
        param([Parameter(Mandatory)][scriptblock]$Script)
        try { $null = & $Script } catch { return $_.Exception.Message }
        return $null
    }
}

Describe 'Import.Yaml hands the parser the text it was given' {
    BeforeEach {
        Import-YamlModuleUnderTest
        Mock -ModuleName Import.Yaml Get-Module { [pscustomobject]@{ Name = 'powershell-yaml' } }
        Mock -ModuleName Import.Yaml ConvertFrom-Yaml { [ordered]@{ parsed = $Yaml } }
    }

    It 'joins a typed string array with line feeds and asks for an ordered result' {
        $expectedText = "first: 1`nsecond: 2"
        $result = ConvertFrom-Content ([string[]]@('first: 1', 'second: 2'))
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter {
            $Ordered -and $Yaml -is [string] -and $Yaml -ceq $expectedText
        }
        Assert-True ($result -is [System.Collections.Specialized.OrderedDictionary]) 'the parser result must come back as the parser produced it'
        Assert-True ($result['parsed'] -ceq $expectedText) 'the caller must receive the parsed document'
    }

    It 'passes a single string through unchanged, carriage returns included' {
        $expectedText = "first: 1`r`nsecond: 2`r`n"
        $null = ConvertFrom-Content $expectedText
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter {
            $Ordered -and $Yaml -ceq $expectedText
        }
    }

    It 'leaves an untyped array of lines for the parser to judge' {
        # Only [string[]] is joined. A captured command's output is [object[]], and
        # joining it here would change what the parser is asked to accept.
        $lines = @('first: 1', 'second: 2')
        $null = ConvertFrom-Content $lines
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter {
            $Ordered -and $Yaml -is [object[]] -and $Yaml.Count -eq 2 -and $Yaml[0] -ceq 'first: 1' -and $Yaml[1] -ceq 'second: 2'
        }
    }

    It 'reads a file as one raw string and delegates to ConvertFrom-Content' {
        $expectedText = "first: 1`nsecond: 2`n"
        $file = Join-Path $TestDrive 'document.yml'
        [IO.File]::WriteAllText($file, $expectedText)
        Mock -ModuleName Import.Yaml ConvertFrom-Content { 'delegated' }

        $result = ConvertFrom-File $file

        Assert-True ($result -ceq 'delegated') 'ConvertFrom-File must return what ConvertFrom-Content returned'
        Should -Invoke ConvertFrom-Content -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter {
            $Content -is [string] -and $Content -ceq $expectedText
        }
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 0 -Exactly
    }
}

Describe 'Import.Yaml looks for powershell-yaml before it converts' {
    BeforeEach {
        Import-YamlModuleUnderTest
        Mock -ModuleName Import.Yaml ConvertFrom-Yaml { [ordered]@{ parsed = $Yaml } }
    }

    It 'asks whether the powershell-yaml module is installed' {
        Mock -ModuleName Import.Yaml Get-Module { [pscustomobject]@{ Name = 'powershell-yaml' } }
        $null = ConvertFrom-Content 'first: 1'
        Should -Invoke Get-Module -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter {
            $ListAvailable -and @($Name).Count -eq 1 -and $Name[0] -ceq 'powershell-yaml'
        }
    }

    It 'looks once however many conversions follow' {
        Mock -ModuleName Import.Yaml Get-Module { [pscustomobject]@{ Name = 'powershell-yaml' } }
        $file = Join-Path $TestDrive 'repeated.yml'
        [IO.File]::WriteAllText($file, "first: 1`n")

        foreach ($index in 1..5) { $null = ConvertFrom-Content "index: $index" }
        foreach ($index in 1..3) { $null = ConvertFrom-File $file }

        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 8 -Exactly
        Should -Invoke Get-Module -ModuleName Import.Yaml -Times 1 -Exactly
    }

    It 'throws the cataloged message for its key instead of reaching the parser' {
        $expectedKey = $script:MissingModuleKey
        Mock -ModuleName Import.Yaml Get-Module { }
        Mock -ModuleName Import.Yaml Format-YurunaOperatorMessage { "rendered:$Key" }

        $message = Get-ThrownMessage { ConvertFrom-Content 'first: 1' }

        Assert-True ($message -ceq "rendered:$expectedKey") "expected the message rendered for $expectedKey, got '$message'"
        Should -Invoke Format-YurunaOperatorMessage -ModuleName Import.Yaml -Times 1 -Exactly -ParameterFilter { $Key -ceq $expectedKey }
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 0 -Exactly
    }

    It 'throws exactly what the operator catalog renders for that key' {
        Mock -ModuleName Import.Yaml Get-Module { }
        $expectedText = & (Get-Module -Name Import.Yaml) { param($MessageKey) Format-YurunaOperatorMessage -Key $MessageKey } $script:MissingModuleKey
        Assert-True (-not [string]::IsNullOrWhiteSpace($expectedText)) 'the catalog must render a message for the key'

        $fromContent = Get-ThrownMessage { ConvertFrom-Content 'first: 1' }
        $file = Join-Path $TestDrive 'missing-parser.yml'
        [IO.File]::WriteAllText($file, "first: 1`n")
        $fromFile = Get-ThrownMessage { ConvertFrom-File $file }

        Assert-True ($fromContent -ceq $expectedText) "ConvertFrom-Content threw '$fromContent'"
        Assert-True ($fromFile -ceq $expectedText) "ConvertFrom-File threw '$fromFile'"
    }

    It 'never remembers that the module was missing' {
        Mock -ModuleName Import.Yaml Get-Module { }

        $first = Get-ThrownMessage { ConvertFrom-Content 'first: 1' }
        $second = Get-ThrownMessage { ConvertFrom-Content 'second: 2' }

        Assert-NotNull $first 'a missing module must stop the conversion'
        Assert-True ($second -ceq $first) 'every call must report the missing module the same way'
        Should -Invoke Get-Module -ModuleName Import.Yaml -Times 2 -Exactly
        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 0 -Exactly
    }

    It 'converts once the module appears, and only then stops looking' {
        # The answer changes between calls the way it does when an operator
        # installs the module and retries without restarting the session.
        $script:ProbeAnswer = $null
        Mock -ModuleName Import.Yaml Get-Module { $script:ProbeAnswer }

        Assert-NotNull (Get-ThrownMessage { ConvertFrom-Content 'first: 1' }) 'the first call must report the missing module'
        $script:ProbeAnswer = [pscustomobject]@{ Name = 'powershell-yaml' }
        Assert-Null (Get-ThrownMessage { ConvertFrom-Content 'second: 2' }) 'a module that has appeared must be found on the next call'
        $script:ProbeAnswer = $null
        Assert-Null (Get-ThrownMessage { ConvertFrom-Content 'third: 3' }) 'a module that was found must not be looked for again'

        Should -Invoke ConvertFrom-Yaml -ModuleName Import.Yaml -Times 2 -Exactly
        Should -Invoke Get-Module -ModuleName Import.Yaml -Times 2 -Exactly
    }

    It 'forgets a remembered answer when the module is imported again' {
        $expectedKey = $script:MissingModuleKey
        Mock -ModuleName Import.Yaml Get-Module { [pscustomobject]@{ Name = 'powershell-yaml' } }
        $null = ConvertFrom-Content 'first: 1'

        Import-YamlModuleUnderTest
        Mock -ModuleName Import.Yaml Get-Module { }
        Mock -ModuleName Import.Yaml Format-YurunaOperatorMessage { "rendered:$Key" }

        $message = Get-ThrownMessage { ConvertFrom-Content 'second: 2' }
        Assert-True ($message -ceq "rendered:$expectedKey") "a freshly imported module must look for the parser again; got '$message'"
    }
}

Describe 'Import.Yaml exports' {
    BeforeAll {
        Import-Module $script:ModulePath -Force
        $script:Exported = [string[]]@((Get-Module -Name Import.Yaml).ExportedCommands.Keys)
        [Array]::Sort($script:Exported, [StringComparer]::Ordinal)
    }

    It 'exports the two conversion commands' {
        foreach ($command in @('ConvertFrom-Content', 'ConvertFrom-File')) {
            Assert-True ($script:Exported -ccontains $command) "$command must be exported; the exports are: $($script:Exported -join ', ')"
        }
    }

    It 'passes on the operator-message commands its importers resolve through it' {
        # Yuruna.Validation and Yuruna.Requirement import this module after
        # Yuruna.Globalization, so these three names resolve to this module's
        # re-export in their scope. Narrowing the export moves that ownership.
        foreach ($command in @('Format-YurunaOperatorMessage', 'Get-YurunaOperatorLocale', 'Resolve-YurunaOperatorProjectLabel')) {
            Assert-True ($script:Exported -ccontains $command) "$command must be exported; the exports are: $($script:Exported -join ', ')"
        }
    }

    It 'exports nothing else' {
        $expected = 'ConvertFrom-Content, ConvertFrom-File, Format-YurunaOperatorMessage, Get-YurunaOperatorLocale, Resolve-YurunaOperatorProjectLabel'
        Assert-True (($script:Exported -join ', ') -ceq $expected) "the exports are: $($script:Exported -join ', ')"
    }
}
