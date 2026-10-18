<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42e03341-f0d3-4396-bca9-3bd6fa75426d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test json schema pester
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
    Get-YurunaJsonSchemaError names the location of a JSON Schema violation
    on every PowerShell, including one whose Test-Json reports nothing for a
    violation nested below the document's first level.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.LocalizationExchange.psm1') -Force -Global -DisableNameChecking
    $script:Schema = Join-Path $TestDrive 'nested.schema.json'
    [IO.File]::WriteAllText($script:Schema, '{"type":"object","required":["entries"],"properties":{"entries":{"type":"array","items":{"type":"object","properties":{"path":{"type":"string"}},"additionalProperties":false}}},"additionalProperties":false}')
}

Describe 'Get-YurunaJsonSchemaError' {
    It 'answers nothing for a document that satisfies the schema' {
        Get-YurunaJsonSchemaError -Json '{"entries":[{"path":"a"}]}' -SchemaFile $script:Schema | Should -BeNullOrEmpty
    }

    It 'names the location of a violation nested below the first level' {
        # A property the schema forbids inside an array entry is the case
        # PowerShell 7.6.7 answers with $false and no error record.
        $found = Get-YurunaJsonSchemaError -Json '{"entries":[{"path":"a","reviewer":"x"}]}' -SchemaFile $script:Schema
        $found | Should -Match "^The JSON is not valid with the schema: .* at '/entries/0/reviewer'$"
    }

    It 'names the same nested location from schema text as from the schema file' {
        $text = [IO.File]::ReadAllText($script:Schema)
        Get-YurunaJsonSchemaError -Json '{"entries":[{"path":"a"}]}' -Schema $text | Should -BeNullOrEmpty
        $found = Get-YurunaJsonSchemaError -Json '{"entries":[{"path":"a","reviewer":"x"}]}' -Schema $text
        $found | Should -Match "^The JSON is not valid with the schema: .* at '/entries/0/reviewer'$"
    }

    It 'names a first-level violation the way Test-Json reports it' {
        $found = Get-YurunaJsonSchemaError -Json '{"other":1}' -SchemaFile $script:Schema
        $found | Should -Match '^The JSON is not valid with the schema: '
        $found | Should -Match "at '"
    }

    It 'reports a schema file that cannot be read' {
        Get-YurunaJsonSchemaError -Json '{}' -SchemaFile (Join-Path $TestDrive 'missing.schema.json') | Should -Match 'missing\.schema\.json'
    }

    It 'reports a document that is not JSON' {
        Get-YurunaJsonSchemaError -Json '{not json' -SchemaFile $script:Schema | Should -Not -BeNullOrEmpty
    }
}
