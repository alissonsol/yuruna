<#PSScriptInfo
.VERSION 2026.09.27
.GUID 421e2d93-7e74-4a5d-90d5-4a730e5dc48f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization terminology style-guide pester
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
    Prove terminology sources keep their shape: required terms, the definition
    headings they cite, the protected retired-name rulings, the required style
    rules, and no field that records who approved them.

    Run: Invoke-Pester -Path test/modules/Test.Terminology.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-Terminology.ps1'
$script:TermsSchema = Join-Path $script:RepoRoot 'globalization/schema/terminology.schema.json'
$script:PowerShell = (Get-Process -Id $PID).Path

function New-TerminologyFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable terminology tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $root = Join-Path $TestDrive $Name
    $paths = @(
        'docs/definition.md',
        'tools/githooks/pre-commit',
        'globalization/manifests/doc-translations.json',
        'globalization/schema/terminology.schema.json',
        'globalization/schema/style-guide.schema.json',
        'globalization/terminology/pt-BR.terms.json',
        'globalization/terminology/pt-BR.style-guide.json'
    )
    foreach ($relative in $paths) {
        $target = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot $relative) -Destination $target
    }
    return $root
}

function Add-FixtureLocale {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Adds a synthetic locale to a disposable terminology tree under TestDrive.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tag)

    $terms = Read-FixtureJson -Root $Root -RelativePath 'globalization/terminology/pt-BR.terms.json'
    $terms.locale = $Tag
    Write-FixtureJson -Root $Root -RelativePath "globalization/terminology/$Tag.terms.json" -Value $terms
    $style = Read-FixtureJson -Root $Root -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
    $style.locale = $Tag
    Write-FixtureJson -Root $Root -RelativePath "globalization/terminology/$Tag.style-guide.json" -Value $style
}

function Read-FixtureJson {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    return ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root $RelativePath)))
}

function Write-FixtureJson {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates a disposable JSON fixture under TestDrive.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][pscustomobject]$Value
    )
    $json = ConvertTo-Json -InputObject $Value -Depth 20
    [IO.File]::WriteAllText((Join-Path $Root $RelativePath), "$json`n", [Text.UTF8Encoding]::new($false))
}

function Invoke-TerminologyGate {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string[]]$Arguments = @()
    )
    $all = @('-NoProfile', '-File', $script:Tool, '-Root', $Root, '-Quiet') + $Arguments
    $output = & $script:PowerShell @all 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}
}

Describe 'the locale terminology and style-guide sources' {

    It 'reports the tracked baseline in the summary' {
        $terms = Read-FixtureJson -Root $script:RepoRoot -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $style = Read-FixtureJson -Root $script:RepoRoot -RelativePath 'globalization/terminology/pt-BR.style-guide.json'
        $run = Invoke-TerminologyGate -Root $script:RepoRoot -Arguments @('-Locale', 'pt-BR')
        Assert-Equal -Expected 0 -Actual $run.Code 'the tracked pt-BR sources failed the gate'
        Assert-Match -Pattern ("Test-Terminology: pt-BR; $(@($terms.terms).Count) term\(s\), " +
            "$(@($terms.retiredNameRulings).Count) protected ruling\(s\), $(@($style.rules).Count) style rule\(s\)\.") `
            -Actual $run.Output 'the summary does not name the checked locale and its counts'
    }

    It 'fails closed when either required artifact is deleted' -ForEach @(
        @{ Relative = 'globalization/terminology/pt-BR.terms.json'; Label = 'terminology artifact' },
        @{ Relative = 'globalization/terminology/pt-BR.style-guide.json'; Label = 'style-guide artifact' }
    ) {
        $root = New-TerminologyFixture -Name "missing-$($Relative.GetHashCode())"
        Remove-Item -LiteralPath (Join-Path $root $Relative)
        $run = Invoke-TerminologyGate -Root $root -Arguments @('-Locale', 'pt-BR')
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting an authoritative artifact did not fail validation'
        Assert-Match -Pattern "pt-BR: $([regex]::Escape($Label)) is missing" -Actual $run.Output `
            'the deleted authority is not identified'
    }

    It 'returns unavailable only when an evaluation source is absent' {
        $root = New-TerminologyFixture -Name 'missing-source'
        Remove-Item -LiteralPath (Join-Path $root 'docs/definition.md')
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 2 -Actual $run.Code 'a missing source cannot be evaluated as an ordinary finding'
        Assert-Match -Pattern 'definition source is unavailable' -Actual $run.Output `
            'the unavailable source is not identified'
    }

    It 'exits 2 when no terminology directory exists' {
        $root = New-TerminologyFixture -Name 'no-terminology'
        Remove-Item -LiteralPath (Join-Path $root 'globalization/terminology') -Recurse
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 2 -Actual $run.Code 'a tree with no terminology passed or failed as a finding'
        Assert-Match -Pattern 'terminology directory is unavailable' -Actual $run.Output `
            'the missing terminology directory is not named'
    }

    It 'a missing definition heading is a finding' {
        $root = New-TerminologyFixture -Name 'missing-heading'
        $terms = Read-FixtureJson -Root $root -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $heading = [string]$terms.terms[0].sourceHeadings[0]
        $path = Join-Path $root 'docs/definition.md'
        $text = [regex]::Replace([IO.File]::ReadAllText($path), '(?m)^(#{1,6}\s+)' + [regex]::Escape($heading) + '\s*$',
            '${1}Renamed heading')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a term cited a heading the definition no longer has'
        Assert-Match -Pattern ("pt-BR: term '$([regex]::Escape([string]$terms.terms[0].sourceTerm))' references a " +
            "missing definition heading: $([regex]::Escape($heading))") -Actual $run.Output `
            'the vanished heading is not named'
    }

    It 'invalidates terminology when a machine-matched hook literal changes' {
        $root = New-TerminologyFixture -Name 'hook-drift'
        $path = Join-Path $root 'tools/githooks/pre-commit'
        $text = [IO.File]::ReadAllText($path).Replace('status server|status service',
            'servidor de status|servico de status')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'translated hook search keys passed the terminology gate'
        Assert-Match -Pattern 'not an exact hook pair' -Actual $run.Output `
            'the protected prose ruling is not checked against the hook'
    }

    It 'a ruling missing from the hook block is a finding' {
        $root = New-TerminologyFixture -Name 'ruling-missing-from-hook'
        $path = Join-Path $root 'tools/githooks/pre-commit'
        $text = [regex]::Replace([IO.File]::ReadAllText($path), '(?m)^stash-server\|stash-service\r?\n', '')
        [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a ruling with no hook pair passed the gate'
        Assert-Match -Pattern "pt-BR: retired-name ruling is not an exact hook pair: 'stash-server\|stash-service'" `
            -Actual $run.Output 'the ruling without a hook pair is not named'
    }

    It 'rejects translation fields on protected retired-name rulings' {
        $root = New-TerminologyFixture -Name 'translated-ruling'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.retiredNameRulings[0] | Add-Member -NotePropertyName targetTerm `
            -NotePropertyValue 'servidor de status'
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a translated machine search key passed validation'
        Assert-Match -Pattern 'does not satisfy terminology\.schema\.json' -Actual $run.Output `
            'the protected ruling schema did not reject a translation field'
    }

    It 'requires every baseline concept' {
        $root = New-TerminologyFixture -Name 'missing-term'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.terms = @($terms.terms | Where-Object sourceTerm -NE 'drain')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting a named baseline concept left the source complete'
        Assert-Match -Pattern 'required baseline term is missing: drain' -Actual $run.Output `
            'the deleted baseline concept is not named'
    }

    It 'holds retired-name prose rulings in one stable order' {
        $root = New-TerminologyFixture -Name 'ruling-order'
        $relative = 'globalization/terminology/pt-BR.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $first = $terms.retiredNameRulings[0]
        $terms.retiredNameRulings[0] = $terms.retiredNameRulings[1]
        $terms.retiredNameRulings[1] = $first
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'reordering protected rulings passed as deterministic'
        Assert-Match -Pattern 'ruling 1 changed or moved' -Actual $run.Output `
            'the unstable ruling order is not identified'
    }

    It 'requires the style topics needed by later translation handoffs' {
        $root = New-TerminologyFixture -Name 'missing-style-rule'
        $relative = 'globalization/terminology/pt-BR.style-guide.json'
        $style = Read-FixtureJson -Root $root -RelativePath $relative
        $style.rules = @($style.rules | Where-Object id -NE 'machine-matched-literals')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $style
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'deleting the protected-literal rule left the guide complete'
        Assert-Match -Pattern 'pt-BR: required style rule is missing: machine-matched-literals' `
            -Actual $run.Output 'the missing style topic is not identified'
    }

    It 'validates a terms file for any locale tag' {
        $terms = Read-FixtureJson -Root $script:RepoRoot -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $terms.locale = 'yy-YY'
        $json = ConvertTo-Json -InputObject $terms -Depth 20
        Assert-True -Condition (Test-Json -Json $json -SchemaFile $script:TermsSchema -ErrorAction SilentlyContinue) `
            -Because 'the terminology schema is bound to one locale'
    }

    It 'refuses the retired per-locale decision field' {
        $terms = Read-FixtureJson -Root $script:RepoRoot -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $terms.terms[0] | Add-Member -NotePropertyName ptBRDecision -NotePropertyValue ([pscustomobject]@{ status = 'retained' })
        $json = ConvertTo-Json -InputObject $terms -Depth 20
        Assert-False -Condition (Test-Json -Json $json -SchemaFile $script:TermsSchema -ErrorAction SilentlyContinue) `
            -Because 'a per-locale decision member would let two spellings of one decision coexist'
    }

    It 'refuses every person or approval field: <Field>' -ForEach @(
        @{ Field = 'approvals' }, @{ Field = 'approvedBy' }, @{ Field = 'approvedAt' },
        @{ Field = 'status' }, @{ Field = 'releaseVersion' }, @{ Field = 'sources' }
    ) {
        $terms = Read-FixtureJson -Root $script:RepoRoot -RelativePath 'globalization/terminology/pt-BR.terms.json'
        $terms | Add-Member -NotePropertyName $Field -NotePropertyValue 'x'
        $json = ConvertTo-Json -InputObject $terms -Depth 20
        Assert-False -Condition (Test-Json -Json $json -SchemaFile $script:TermsSchema -ErrorAction SilentlyContinue) `
            -Because "the terminology schema accepted '$Field'; the commit that lands a file is its only record"
    }

    It 'checks every locale that has a terms file and prefixes findings with the tag' {
        $root = New-TerminologyFixture -Name 'two-locales'
        Add-FixtureLocale -Root $root -Tag 'yy-YY'
        $relative = 'globalization/terminology/yy-YY.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.terms = @($terms.terms | Where-Object sourceTerm -NE 'cache')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a broken second locale passed the gate'
        Assert-Match -Pattern 'yy-YY: required baseline term is missing: cache' -Actual $run.Output `
            'the finding does not name the locale it belongs to'
        Assert-False -Condition ($run.Output -match 'pt-BR: required baseline term') `
            -Because 'the intact locale was blamed for the broken one'
        Assert-Match -Pattern 'Test-Terminology: 1 finding\(s\); pt-BR, yy-YY;' -Actual $run.Output `
            'the summary does not list both checked locales'
    }

    It 'reports a locale that carries only one of its two files' {
        $root = New-TerminologyFixture -Name 'half-pair'
        Copy-Item -LiteralPath (Join-Path $root 'globalization/terminology/pt-BR.terms.json') `
            -Destination (Join-Path $root 'globalization/terminology/yy-YY.terms.json')
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a terms file without its style guide was skipped'
        Assert-Match -Pattern 'yy-YY: style-guide artifact is missing' -Actual $run.Output `
            'the missing half of the pair is not named'
    }

    It 'checks only the requested locale with -Locale' {
        $root = New-TerminologyFixture -Name 'requested-locale'
        Add-FixtureLocale -Root $root -Tag 'yy-YY'
        $relative = 'globalization/terminology/yy-YY.terms.json'
        $terms = Read-FixtureJson -Root $root -RelativePath $relative
        $terms.terms = @($terms.terms | Where-Object sourceTerm -NE 'cache')
        Write-FixtureJson -Root $root -RelativePath $relative -Value $terms
        $run = Invoke-TerminologyGate -Root $root -Arguments @('-Locale', 'pt-BR')
        Assert-Equal -Expected 0 -Actual $run.Code 'a locale that was not requested was checked'
        Assert-Match -Pattern 'Test-Terminology: pt-BR;' -Actual $run.Output 'the requested locale is not the one reported'
    }

    It 'applies the document-count rule per locale' {
        $root = New-TerminologyFixture -Name 'document-count'
        Add-FixtureLocale -Root $root -Tag 'yy-YY'
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 0 -Actual $run.Code 'thirteen pt-BR rows and no yy-YY rows is a valid manifest'

        $relative = 'globalization/manifests/doc-translations.json'
        $manifest = Read-FixtureJson -Root $root -RelativePath $relative
        $manifest.documents = @($manifest.documents | Select-Object -Skip 1)
        Write-FixtureJson -Root $root -RelativePath $relative -Value $manifest
        $run = Invoke-TerminologyGate -Root $root
        Assert-Equal -Expected 1 -Actual $run.Code 'a locale mapping twelve of the thirteen documents passed'
        Assert-Match -Pattern 'pt-BR: document manifest maps 12 documents; a locale maps either none or the 13-document subset' `
            -Actual $run.Output 'the partial document set is not named with its locale'
        Assert-False -Condition ($run.Output -match 'yy-YY: document manifest') `
            -Because 'a locale with no documents is valid'
    }
}
