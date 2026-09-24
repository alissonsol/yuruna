<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42717e9e-cb41-455c-9848-aef41009bf87
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization documentation translation accept pester
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
    The paths that WRITE the translation record, rather than the drift report
    that reads it.
.DESCRIPTION
    Every other check here reads the record. -AcceptReview is the only thing
    that rewrites a source hash and a status, and a hash advanced by mistake
    silently blesses a translation nobody read -- the exact failure the record
    exists to prevent -- so its refusals are worth more coverage than its
    success path.

    Two of them are proven here. A -Path that matches no mapped document must
    not report success: a release close record asks this tool one document-shaped
    question, and answering "0 documents, 0 problems, exit 0" to a typo would
    close that record having proved nothing. And a translation whose relative
    links resolve to nothing must not be recorded as read, because the record
    would then assert a review of a document whose navigation is broken, and the
    breakage would surface on some later unrelated run.

    The mutations run against a disposable sibling project under TestDrive
    rather than the real checkout, so a killed run cannot leave a repository
    document edited. The framework half of the map is untouched, which is why
    every case names a project-only document.

    Run: Invoke-Pester -Path test/modules/Test.DocTranslationAccept.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-DocTranslation.ps1'
$script:PowerShell = (Get-Process -Id $PID).Path
# A project-only entry: a bare 'README.md' would match the framework's document
# too, and the mutation is supposed to reach exactly one repository.
$script:ProjectOnlyDocument = 'template/README.md'

# The two files the map needs from the sibling for one project document, plus a
# neighbor for the translation to link at. Anything else in that repository is
# irrelevant to the entry under test and is left out so a failure names this
# fixture rather than the real checkout.
function New-SiblingFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable project tree under TestDrive.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TranslatedBody
    )
    $root = Join-Path $TestDrive $Name
    foreach ($relative in @('template/README.md', 'docs/pt-BR/template/README.md', 'docs/pt-BR/vizinho.md')) {
        $target = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $root 'template/README.md'), "# Template`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'docs/pt-BR/vizinho.md'), "# Vizinho`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $root 'docs/pt-BR/template/README.md'), $TranslatedBody, $utf8)
    return $root
}

function New-RecordFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Copies the tracked record into a disposable TestDrive file.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $TestDrive "$Name.json"
    Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'globalization/manifests/doc-translations.json') `
        -Destination $path
    return $path
}

function Invoke-DocTranslation {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Argument)
    $output = & $script:PowerShell @(@('-NoProfile', '-File', $script:Tool) + $Argument) 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}
}

Describe 'recording a translation as read' {

    It 'refuses a path filter that matches no mapped document' {
        $manifest = New-RecordFixture -Name 'unmatched-path'
        $before = [IO.File]::ReadAllText($manifest)

        $run = Invoke-DocTranslation -Argument @('-Path', 'docs/oparator.md', '-RequireReviewed',
            '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 2 -Actual $run.Code 'a filter that selected nothing reported success'
        Assert-Match -Pattern 'docs/oparator\.md' -Actual $run.Output `
            'the refusal does not name the pattern that matched nothing'
        Assert-StringEqual -Expected $before -Actual ([IO.File]::ReadAllText($manifest)) `
            'a refused run still rewrote the record'
    }

    It 'records a project document whose translated links resolve' {
        $sibling = New-SiblingFixture -Name 'links-resolve' `
            -TranslatedBody "# Modelo`n`n[vizinho](../vizinho.md)`n"
        $manifest = New-RecordFixture -Name 'links-resolve'

        $run = Invoke-DocTranslation -Argument @('-AcceptReview', '-Status', 'draft',
            '-Path', $script:ProjectOnlyDocument, '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $recorded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))
        $entry = @($recorded.documents | Where-Object {
                $_.repo -eq 'yuruna-project' -and $_.source -eq $script:ProjectOnlyDocument
            })
        Assert-Equal -Expected 1 -Actual $entry.Count 'the accepted document left the record'
        Assert-StringEqual -Expected 'draft' -Actual $entry[0].status 'the recorded status is not the one asked for'
    }

    It 'refuses to record a translation whose relative links resolve to nothing' {
        $sibling = New-SiblingFixture -Name 'links-broken' `
            -TranslatedBody "# Modelo`n`n[quebrado](nao-existe-em-lugar-nenhum.md)`n"
        $manifest = New-RecordFixture -Name 'links-broken'
        $before = [IO.File]::ReadAllText($manifest)

        $run = Invoke-DocTranslation -Argument @('-AcceptReview', '-Status', 'draft',
            '-Path', $script:ProjectOnlyDocument, '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.Code 'a translation with an unresolvable link was recorded as read'
        Assert-Match -Pattern 'nao-existe-em-lugar-nenhum\.md' -Actual $run.Output `
            'the refusal does not name the destination that resolves to nothing'
        Assert-StringEqual -Expected $before -Actual ([IO.File]::ReadAllText($manifest)) `
            'a refused run still rewrote the record'
    }
}
