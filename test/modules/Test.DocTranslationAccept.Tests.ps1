<#PSScriptInfo
.VERSION 2026.09.27
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
    Every other check here reads the record. -Accept is the only thing that
    rewrites a source hash and the machine-draft marker, and a hash advanced by
    mistake silently blesses a translation nobody rewrote -- the exact failure
    the record exists to prevent -- so its refusals are worth more coverage
    than its success path. The hash is taken over the English with its version
    sites normalized, so the cases below also prove which edits stale a row
    and which do not.

    Two of those refusals are proven here. A -Path that matches no mapped
    document must not report success: a caller that names one document would
    pass on a typo with "0 documents, 0 problems, exit 0", having proved
    nothing. And a translation whose relative
    links resolve to nothing must not be recorded, because the record would
    then vouch for a document whose navigation is broken, and the breakage would
    surface on some later unrelated run.

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
        [Parameter(Mandatory)][string]$TranslatedBody,
        [string]$SourceBody = "# Template`n"
    )
    $root = Join-Path $TestDrive $Name
    foreach ($relative in @('template/README.md', 'docs/pt-BR/template/README.md', 'docs/pt-BR/vizinho.md')) {
        $target = Join-Path $root $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $root 'template/README.md'), $SourceBody, $utf8)
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

# One project document recorded at its current English, then the English
# edited by the caller's script block, then checked. Only the edited document
# is selected, so the framework half of the map plays no part.
function Invoke-EditedSourceCheck {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourceBody,
        [Parameter(Mandatory)][scriptblock]$Edit
    )
    $sibling = New-SiblingFixture -Name $Name -TranslatedBody "# Modelo`n" -SourceBody $SourceBody
    $manifest = New-RecordFixture -Name $Name
    $accept = Invoke-DocTranslation -Argument @('-Accept', '-Locale', 'pt-BR', '-Path', $script:ProjectOnlyDocument,
        '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
    if ($accept.Code -ne 0) { throw "the fixture document could not be recorded: $($accept.Output)" }
    $source = Join-Path $sibling 'template/README.md'
    [IO.File]::WriteAllText($source, (& $Edit ([IO.File]::ReadAllText($source))), [Text.UTF8Encoding]::new($false))
    return Invoke-DocTranslation -Argument @('-Locale', 'pt-BR', '-Path', $script:ProjectOnlyDocument,
        '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
}
}

Describe 'accepting a translation against its English source' {

    It 'refuses a path filter that matches no mapped document' {
        $manifest = New-RecordFixture -Name 'unmatched-path'
        $before = [IO.File]::ReadAllText($manifest)

        $run = Invoke-DocTranslation -Argument @('-Path', 'docs/oparator.md', '-Accept',
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

        $run = Invoke-DocTranslation -Argument @('-Accept', '-Locale', 'pt-BR',
            '-Path', $script:ProjectOnlyDocument, '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $recorded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))
        $entry = @($recorded.documents | Where-Object {
                $_.repo -eq 'yuruna-project' -and $_.source -eq $script:ProjectOnlyDocument
            })
        Assert-Equal -Expected 1 -Actual $entry.Count 'the accepted document left the record'
        Assert-False -Condition (@($entry[0].PSObject.Properties.Name) -contains 'origin') `
            -Because 'an accepted translation carries no machine-draft marker'
        Assert-False -Condition (@($entry[0].PSObject.Properties.Name) -contains 'status') `
            -Because 'a row records the source it was written against, not a review state'
    }

    It 'refuses to record a translation whose relative links resolve to nothing' {
        $sibling = New-SiblingFixture -Name 'links-broken' `
            -TranslatedBody "# Modelo`n`n[quebrado](nao-existe-em-lugar-nenhum.md)`n"
        $manifest = New-RecordFixture -Name 'links-broken'
        $before = [IO.File]::ReadAllText($manifest)

        $run = Invoke-DocTranslation -Argument @('-Accept', '-Locale', 'pt-BR',
            '-Path', $script:ProjectOnlyDocument, '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 1 -Actual $run.Code 'a translation with an unresolvable link was recorded'
        Assert-Match -Pattern 'nao-existe-em-lugar-nenhum\.md' -Actual $run.Output `
            'the refusal does not name the destination that resolves to nothing'
        Assert-StringEqual -Expected $before -Actual ([IO.File]::ReadAllText($manifest)) `
            'a refused run still rewrote the record'
    }

    It 'a locale with no mapped documents has nothing to check' {
        $manifest = New-RecordFixture -Name 'unmapped-locale'
        $run = Invoke-DocTranslation -Argument @('-Locale', 'zz-ZZ', '-Manifest', $manifest, '-Quiet')
        Assert-Equal -Expected 0 -Actual $run.Code 'a locale that maps no documents failed the document gate'
        Assert-Match -Pattern 'Test-DocTranslation \[zz-ZZ\]: 0 document\(s\), 0 problem\(s\)' -Actual $run.Output `
            'the unmapped locale is not reported as checked'
    }

    It 'a footer-only edit leaves the row current' {
        $run = Invoke-EditedSourceCheck -Name 'footer-only' -SourceBody "# Template`n`nLast review: 2026.09.27`n" `
            -Edit { param($text) $text.Replace('Last review: 2026.09.27', 'Last review: 2026.10.04') }
        Assert-Equal -Expected 0 -Actual $run.Code 'a review-footer sweep made the translation look stale'
    }

    It 'a release-tag-only edit leaves the row current' {
        $body = "# Template`n`nhttps://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.27/install/ubuntu.kvm.sh`n"
        $run = Invoke-EditedSourceCheck -Name 'tag-only' -SourceBody $body `
            -Edit { param($text) $text.Replace('refs/tags/2026.09.27/', 'refs/tags/2026.09.27.1/') }
        Assert-Equal -Expected 0 -Actual $run.Code 'a release-tag sweep made the translation look stale'
    }

    It 'a prose edit stales the row' {
        $run = Invoke-EditedSourceCheck -Name 'prose-edit' -SourceBody "# Template`n`nLast review: 2026.09.27`n" `
            -Edit { param($text) $text + "A new sentence the translation does not have.`n" }
        Assert-Equal -Expected 1 -Actual $run.Code 'an English prose edit left the translation current'
        Assert-Match -Pattern 'changed since' -Actual $run.Output 'the stale document is not named'
    }

    It '-Accept -Machine writes origin machine and -Accept removes it' {
        $sibling = New-SiblingFixture -Name 'machine-marker' -TranslatedBody "# Modelo`n"
        $manifest = New-RecordFixture -Name 'machine-marker'
        $common = @('-Locale', 'pt-BR', '-Path', $script:ProjectOnlyDocument, '-ProjectRoot', $sibling, '-Manifest', $manifest, '-Quiet')

        $run = Invoke-DocTranslation -Argument (@('-Accept', '-Machine') + $common)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $entry = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))).documents | Where-Object {
                $_.repo -eq 'yuruna-project' -and $_.source -eq $script:ProjectOnlyDocument })
        Assert-StringEqual -Expected 'machine' -Actual ([string]$entry[0].origin) 'a machine acceptance did not mark the row'
        $check = Invoke-DocTranslation -Argument $common
        Assert-Equal -Expected 0 -Actual $check.Code 'a current machine draft is not a problem'
        Assert-Match -Pattern '1 machine draft\(s\)' -Actual $check.Output 'the machine draft is not counted'

        $run = Invoke-DocTranslation -Argument (@('-Accept') + $common)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        $entry = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($manifest))).documents | Where-Object {
                $_.repo -eq 'yuruna-project' -and $_.source -eq $script:ProjectOnlyDocument })
        Assert-False -Condition (@($entry[0].PSObject.Properties.Name) -contains 'origin') `
            -Because 'accepting the translation did not remove the machine-draft marker'
    }
}
