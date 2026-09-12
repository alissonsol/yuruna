<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42a7c30b-91d4-4f6e-8b02-5e6cb7d9a114
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization locale config template mutation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Prove the shipped `language: auto` seed cannot quietly disappear or become a
    lock, and that reconciliation carries it to a host.

    Run: Invoke-Pester -Path test/modules/Test.ConfigLocaleSeed.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.ConfigSync.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Locale.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-ConfigLocaleSeed.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path
$script:TemplatePath = Join-Path $script:RepoRoot 'test/test.config.yml.template'
$script:ReferencePath = Join-Path $script:RepoRoot 'docs/test-config.md'

# Each mutation runs against copies, so a failing run cannot leave the tracked
# template or reference edited behind it.
function New-SeedFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only disposable fixture files below Pester TestDrive.')]
    param([scriptblock]$EditTemplate, [scriptblock]$EditReference)

    $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $template = [IO.File]::ReadAllText($script:TemplatePath)
    $reference = [IO.File]::ReadAllText($script:ReferencePath)
    if ($EditTemplate) { $template = & $EditTemplate $template }
    if ($EditReference) { $reference = & $EditReference $reference }

    $fixture = @{
        Template = Join-Path $root 'test.config.yml.template'
        Reference = Join-Path $root 'test-config.md'
    }
    [IO.File]::WriteAllText($fixture.Template, $template, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($fixture.Reference, $reference, [Text.UTF8Encoding]::new($false))
    return $fixture
}

function ConvertTo-PlainDetail {
    # A gate writes warnings through the host, which colors them with ANSI
    # escapes. Those are control characters, and a control character inside a
    # failure message makes the run's own NUnit file unparseable -- the suite
    # then reports "produced no result file" instead of the assertion.
    param([string]$Text)
    return (($Text -replace "`e\[[0-9;]*m", '') -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
}

function Invoke-SeedGate {
    param([string]$Template, [string]$Reference)
    $arguments = @('-NoProfile', '-File', $script:Tool, '-Root', $script:RepoRoot, '-Quiet')
    if ($Template) { $arguments += @('-TemplatePath', $Template) }
    if ($Reference) { $arguments += @('-ReferencePath', $Reference) }
    $output = & $script:Pwsh @arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = (ConvertTo-PlainDetail -Text $output) }
}
}

Describe 'the shipped runner template seeds the language knob' {
    It 'passes against the tracked template and reference' {
        $run = Invoke-SeedGate
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'carries language: auto as a top-level scalar' {
        $template = Get-Content -Raw -LiteralPath $script:TemplatePath | ConvertFrom-Yaml -Ordered
        Assert-True $template.Contains('language') 'the template must name the language knob so a host config can carry it'
        Assert-StringEqual -Expected 'auto' -Actual ([string]$template['language']) `
            -Because 'the shipped default is the absence of a lock, not a language'
    }

    It 'fails when the key is deleted' {
        $fixture = New-SeedFixture -EditTemplate { param($t) $t -replace '(?m)^language: auto\r?\n', '' }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'no top-level' $run.Output 'the gate must name the missing key, not just fail'
    }

    It 'fails when the default becomes a real language' {
        $fixture = New-SeedFixture -EditTemplate { param($t) $t -replace '(?m)^language: auto$', 'language: pt-BR' }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'locks every newly reconciled host' $run.Output 'the gate must say what a seeded tag does'
    }

    It 'is not satisfied by a comment that mentions the key' {
        $fixture = New-SeedFixture -EditTemplate {
            param($t) $t -replace '(?m)^language: auto$', '# language: auto'
        }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
    }

    It 'reports a missing template as unable to reach a verdict, not as a pass' {
        $absent = Join-Path $TestDrive 'no-such-template.yml'
        $run = Invoke-SeedGate -Template $absent
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }
}

Describe 'reconciliation carries the seed to a host' {
    It 'adds the key to a configuration that predates it' {
        $template = Get-Content -Raw -LiteralPath $script:TemplatePath | ConvertFrom-Yaml -Ordered
        $merged = ConvertTo-MergedHashtable -Template $template -Current ([ordered]@{ logLevel = 'Information' })
        Assert-True $merged.Contains('language') 'a host that never had the key must gain it on the next reconcile'
        Assert-StringEqual -Expected 'auto' -Actual ([string]$merged['language']) `
            -Because 'the added key must arrive unlocked'
    }

    It 'leaves an operator lock alone' {
        $template = Get-Content -Raw -LiteralPath $script:TemplatePath | ConvertFrom-Yaml -Ordered
        $merged = ConvertTo-MergedHashtable -Template $template -Current ([ordered]@{ language = 'pt-BR' })
        Assert-StringEqual -Expected 'pt-BR' -Actual ([string]$merged['language']) `
            -Because 'reconciliation adds what the schema gained; it does not overrule a chosen value'
    }

    It 'renders the template comment into the documented file' {
        $templateText = [IO.File]::ReadAllText($script:TemplatePath)
        $rendered = ConvertTo-DocumentedConfigYaml -TemplateText $templateText `
            -Config ($templateText | ConvertFrom-Yaml -Ordered)
        Assert-Match '(?m)^language: auto$' $rendered 'the rendered file must carry the key itself'
        Assert-Match 'a lock: each reader' ($rendered -replace '\s+', ' ') `
            -Because 'the operator reads the template comment in their own file, so it has to survive rendering'
    }
}

Describe 'the seeded value means the same thing the absent key meant' {
    It 'resolves auto to no configuration lock' {
        $manifest = Get-LocaleManifest
        $locked = New-LocaleContext -ConfigLanguage 'auto' -Manifest $manifest
        Assert-NotEqual -Expected 'config' -Actual ([string]$locked['Source']) `
            -Because 'auto is the absence of a lock; a config source would mean the seed itself decided'
    }

    It 'resolves an absent value the same way' {
        $manifest = Get-LocaleManifest
        $absent = New-LocaleContext -Manifest $manifest
        $auto = New-LocaleContext -ConfigLanguage 'auto' -Manifest $manifest
        Assert-StringEqual -Expected ([string]$absent['ResolvedTag']) -Actual ([string]$auto['ResolvedTag']) `
            -Because 'adding the seed to a template must not change what an existing host resolves'
        Assert-StringEqual -Expected ([string]$absent['Source']) -Actual ([string]$auto['Source']) `
            -Because 'the seed records no decision of its own'
    }

    It 'still honors a real lock' {
        $manifest = Get-LocaleManifest
        $locked = New-LocaleContext -ConfigLanguage 'pt-BR' -Manifest $manifest
        Assert-StringEqual -Expected 'config' -Actual ([string]$locked['Source']) `
            -Because 'a tag in the file is the lab-wide lock the seed exists to make reachable'
    }
}

Describe 'the configuration reference documents the knob' {
    It 'fails when the key leaves the top-level section list' {
        $fixture = New-SeedFixture -EditReference { param($r) $r -replace '`language`, ', '' }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'top-level sections' $run.Output 'the gate must say which list lost the key'
    }

    It 'fails when the section itself is removed' {
        $fixture = New-SeedFixture -EditReference {
            param($r) $r -replace '(?m)^## language\b.*$', '## something else'
        }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'no section documenting' $run.Output 'the gate must name the missing section'
    }

    It 'fails when the section never explains the default it ships with' {
        $fixture = New-SeedFixture -EditReference { param($r) $r -replace '`auto`', 'the default' }
        $run = Invoke-SeedGate -Template $fixture.Template -Reference $fixture.Reference
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Match 'never explains' $run.Output 'naming the key is not documenting what its value does'
    }

    It 'reports a missing reference as unable to reach a verdict' {
        $run = Invoke-SeedGate -Reference (Join-Path $TestDrive 'no-such-reference.md')
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }
}
