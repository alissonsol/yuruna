<#PSScriptInfo
.VERSION 2026.09.08
.GUID 429d4a61-8f23-43b6-b470-31e2d9f875ac
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization project utf8 normalization pester
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
    Hold project globalization inputs to exact, normalized UTF-8 bytes.

    Run: Invoke-Pester -Path test/modules/Test.ProjectTextEncoding.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-ProjectTextEncoding.ps1'

function New-EncodingFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable test repository under TestDrive.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $sources = @('README.md', 'template/README.md', 'example/README.md',
        'example/website/README.md', 'example/text-to-sql/README.md')
    $targets = @('docs/pt-BR/README.md', 'docs/pt-BR/template/README.md',
        'docs/pt-BR/example/README.md', 'docs/pt-BR/example/website/README.md',
        'docs/pt-BR/example/text-to-sql/README.md')
    $all = @($sources + $targets + 'docs/pt-BR/index.md' + 'test/test.runner.yml')
    foreach ($relative in $all) {
        $full = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force | Out-Null
        [IO.File]::WriteAllText($full, "text`n", [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText((Join-Path $root 'test/test.runner.yml'),
        "testSets:`n  smoke:`n    displayName: Smoke test`n", [Text.UTF8Encoding]::new($false))
    & git -C $root init -q
    & git -C $root add -A

    $manifest = [ordered]@{
        schema = 'yuruna.domain-inventory/v2'
        domains = @(
            [ordered]@{ domain = 'project-config'; inventoryFiles = @('test/test.runner.yml') }
            [ordered]@{
                domain = 'project-docs'; sourceDocuments = $sources; translatedDocuments = $targets
                inventoryFiles = @($sources + $targets + 'docs/pt-BR/index.md')
            }
        )
    }
    $manifestPath = Join-Path $root 'inventory.json'
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 8),
        [Text.UTF8Encoding]::new($false))
    return @{ Root = $root; Manifest = $manifestPath }
}

function Invoke-EncodingGate {
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $output = & pwsh -NoProfile -File $script:Tool -Quiet `
        -ProjectRoot $Fixture.Root -InventoryManifest $Fixture.Manifest 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}
}

Describe 'project globalization text has one byte representation' {

    It 'accepts valid NFC UTF-8 without a BOM' {
        $fixture = New-EncodingFixture -Name 'good'
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'rejects a UTF-8 BOM' {
        $fixture = New-EncodingFixture -Name 'bom'
        $path = Join-Path $fixture.Root 'README.md'
        [IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF, 0x78, 0x0A))
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code 'a BOM changes hashes and must not pass'
        Assert-Match -Pattern 'BOM' -Actual $run.Output 'the finding does not identify the byte-order mark'
    }

    It 'rejects malformed UTF-8 instead of replacing it' {
        $fixture = New-EncodingFixture -Name 'invalid'
        [IO.File]::WriteAllBytes((Join-Path $fixture.Root 'README.md'), [byte[]](0xC3, 0x28))
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code 'a forgiving decoder hid malformed bytes'
        Assert-Match -Pattern 'not valid UTF-8' -Actual $run.Output 'the malformed byte is not named'
    }

    It 'rejects canonically equivalent but non-NFC text' {
        $fixture = New-EncodingFixture -Name 'nfd'
        $decomposed = "Cafe$([char]0x0301)`n"
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'README.md'), $decomposed,
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code 'two normalization forms cannot share one source hash'
        Assert-Match -Pattern 'NFC' -Actual $run.Output 'the normalization failure is not named'
    }

    It 'rejects invisible control characters' {
        $fixture = New-EncodingFixture -Name 'control'
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'README.md'), "visible$([char]7)text`n",
            [Text.UTF8Encoding]::new($false))
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code 'an invisible control changes rendering and must not pass'
        Assert-Match -Pattern 'control character U\+0007' -Actual $run.Output `
            'the unsafe control is not identified'
    }

    It 'rejects untracked reachable YAML missing from the inventory' {
        $fixture = New-EncodingFixture -Name 'gap'
        $path = Join-Path $fixture.Root 'example/website/test/new.yml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, "description: New display row`n", [Text.UTF8Encoding]::new($false))
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code 'an untracked display file escaped the encoding gate'
        Assert-Match -Pattern 'not inventoried' -Actual $run.Output 'the missing inventory row is not named'
    }

    It 'treats a zero-display-field project config as reachable text' {
        $fixture = New-EncodingFixture -Name 'config-gap'
        $path = Join-Path $fixture.Root 'template/config/localhost/components.yml'
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, "components: {}`n", [Text.UTF8Encoding]::new($false))
        & git -C $fixture.Root add -A
        $run = Invoke-EncodingGate -Fixture $fixture
        Assert-Equal -Expected 1 -Actual $run.Code `
            'a reachable map escaped byte validation because it has no display field yet'
        Assert-Match -Pattern 'not inventoried' -Actual $run.Output `
            'the unprotected zero-field map is not named'
    }
}
