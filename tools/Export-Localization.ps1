<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42d38b1c-6e04-4f7a-9b25-c0a7f4e91d68
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization localization export request translator
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
    Write the folder that goes to the localization team.
.DESCRIPTION
    One command produces everything a translator and an independent reviewer
    need for a language: the glossary, the message catalogs, the operator
    documents, the official project scalars, and the recorded English of every
    reference surface as context.

    A row whose English has not moved since the round that answered it is
    carried forward already filled in and nobody is asked about it again. A row
    whose English moved travels with both spellings, so the reviewer sees the
    edit rather than a sentence with no history. A row nobody has answered is
    new. A round in which nothing changed says so and needs no correspondence.

    The request carries a digest over every row's English. The returned bundle
    repeats it, which is what lets the import prove that the answers in hand
    answer the question that was asked.
.PARAMETER Locale
    Locale tags to export. Defaults to every non-default, non-pseudo locale in
    the locale manifest.
.PARAMETER Root
    Framework repository root. Defaults to the parent of this script.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree.
.PARAMETER InputRoot
    Where the request folders are written.
    Default: dev-only/localization-input.
.PARAMETER OutputRoot
    Where the previous returns are read from, for carry-forward.
    Default: dev-only/localization-output.
.PARAMETER Format
    Spelling of the fillable rows. Defaults to the recorded interchange
    decision in globalization/manifests/tooling-decision.json, and to `Json`
    when nothing is recorded.
.PARAMETER Quiet
    Report only the summary line.
.OUTPUTS
    One summary line per locale. Exit 0 when a request was written or nothing
    changed, 2 when a locale could not be exported.
.EXAMPLE
    pwsh tools/Export-Localization.ps1 -Locale pt-BR
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Quiet is read by the private Write-Line helper; ScriptAnalyzer does not follow that dynamic script scope.')]
param(
    [string[]]$Locale,
    [string]$Root,
    [string]$ProjectRoot,
    [string]$InputRoot,
    [string]$OutputRoot,
    [ValidateSet('Json', 'Csv', 'Xliff')][string]$Format,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $Root) 'yuruna-project' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $InputRoot) { $InputRoot = Join-Path $Root 'dev-only/localization-input' }
if (-not $OutputRoot) { $OutputRoot = Join-Path $Root 'dev-only/localization-output' }
$InputRoot = [IO.Path]::GetFullPath($InputRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

# From this tool's own location, not from -Root: -Root names the tree being
# exchanged, which in a test is a fixture that ships no modules of its own.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'test/modules/Test.LocalizationExchange.psm1') `
    -Force -Global -DisableNameChecking

function Write-Line {
    param([string]$Text = '')
    if (-not $Quiet) { Write-Information $Text -InformationAction Continue }
}

function Resolve-RequestFormat {
    <#
    .SYNOPSIS
        The spelling this request is written in.
    .DESCRIPTION
        The interchange format belongs to the people who receive the work, so
        the recorded decision answers it rather than a default chosen here.

        A required spelling this tool cannot yet write is announced on every
        run instead of being silently substituted. Silence would let the
        obligation sit unnoticed until the round that needed it.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Requested)

    if ($Requested) { return $Requested }
    $path = Join-Path $Root 'globalization/manifests/tooling-decision.json'
    if (-not [IO.File]::Exists($path)) { return 'Json' }
    $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
    if (@($record.PSObject.Properties.Name) -notcontains 'xliff') { return 'Json' }
    if ([string]$record.xliff.decision -cne 'Required') { return 'Json' }
    $note = if ([bool]$record.xliff.provisional) { ' (provisional)' } else { '' }
    Write-Warning ('the recorded interchange decision requires XLIFF{0}, which this tool does not write yet; ' -f $note +
        'the request is written as Json. Pass -Format Xliff once that spelling ships.')
    return 'Json'
}

function Write-Utf8Json {
    <#
    .SYNOPSIS
        A value as normalized, BOM-less UTF-8 JSON with a trailing newline.
    .DESCRIPTION
        The whole globalization tree is held to that shape, and a request the
        team edits and returns has to survive the same encoding gate as
        anything else that lands in the repository.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only below the operator-owned exchange root, which the caller has already confirmed.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $json = ((ConvertTo-Json -InputObject $Value -Depth 30) -replace "`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-ExportLocale {
    <#
    .SYNOPSIS
        The locales a request can be written for.
    .DESCRIPTION
        The default locale is the source, and a pseudo-locale is generated from
        it, so neither is ever sent to a person. What remains is every locale
        the manifest says the product intends to support.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root 'globalization/locale-manifest.json')))
    $default = [string]$manifest.default
    $wanted = foreach ($tag in @($manifest.locales.PSObject.Properties.Name | Where-Object { $_ })) {
        if ($tag -ceq $default) { continue }
        if ([string]$manifest.locales.$tag.status -ceq 'pseudo') { continue }
        $tag
    }
    return [string[]]@($wanted)
}

function New-EntryRecord {
    <#
    .SYNOPSIS
        One fillable row as the team receives it.
    .OUTPUTS
        [ordered]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a value; changes nothing.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][Collections.IDictionary]$State)

    $known = $State[[string]$Row.id]
    $record = [ordered]@{
        id = [string]$Row.id
        state = [string]$known.state
        english = [string]$Row.english
    }
    if ([string]$Row.context) { $record['context'] = [string]$Row.context }
    if ([string]$known.state -ceq 'changed') { $record['previousEnglish'] = [string]$known.previousEnglish }
    $record['translation'] = [string]$known.previousTranslation
    return $record
}

function Write-RequestReadme {
    <#
    .SYNOPSIS
        The instruction sheet, generated from the rows it describes.
    .DESCRIPTION
        Written from the same registry that produced the folder, so the
        instructions cannot describe a bundle shape other than the one
        enclosed. A hand-maintained sheet drifts the first time a row kind is
        added, and the person reading it has no way to notice.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only below the operator-owned exchange root.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Digest
    )

    $counts = @{ carried = 0; changed = 0; new = 0 }
    foreach ($item in $Row) { $counts[[string]$State[[string]$item.id].state]++ }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# Localization request: $Tag")
    $lines.Add('')
    $lines.Add(('This folder holds {0} row(s): {1} new, {2} changed, and {3} carried forward from the previous round.' -f
            $Row.Count, $counts['new'], $counts['changed'], $counts['carried']))
    $lines.Add('')
    $lines.Add('## What to fill in')
    $lines.Add('')
    $lines.Add('Every fillable row has a `translation` field. Fill the rows marked `new` and')
    $lines.Add('`changed`. Rows marked `carried` already hold the translation you returned last')
    $lines.Add('time and their English has not moved; leave them as they are.')
    $lines.Add('')
    $lines.Add('A `changed` row also carries `previousEnglish`, so you can see what moved.')
    $lines.Add('')
    $lines.Add('Documents under `documents/` are whole files rather than fields. The folder')
    $lines.Add('under `documents/` is the repository the document belongs to: the same file')
    $lines.Add('name can appear in both, and they are different documents. Replace the English')
    $lines.Add('text in place and keep the path.')
    $lines.Add('')
    $lines.Add('## What not to change')
    $lines.Add('')
    $lines.Add('Leave `id`, `state`, `english`, `context` and `request.json` exactly as they are.')
    $lines.Add('Anything under `reference/` is context only; it is the recorded English of each')
    $lines.Add('surface as it renders, in a working and a failing state.')
    $lines.Add('')
    $lines.Add('## Signing')
    $lines.Add('')
    $lines.Add('Fill `attestation.json`. The translator and the independent reviewer are two')
    $lines.Add('different people, each with their own name and the calendar date they finished.')
    $lines.Add('Leave `requestDigest` as it is: it says which request these answers answer.')
    $lines.Add('')
    $lines.Add('## Returning the work')
    $lines.Add('')
    $lines.Add('Copy this whole folder, with the same structure, to')
    $lines.Add("`dev-only/localization-output/$Tag/`.")
    $lines.Add('')
    $lines.Add("Request digest: ``$Digest``")
    $lines.Add('')
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [IO.File]::WriteAllText($Path, (($lines -join "`n").TrimEnd() + "`n"), [Text.UTF8Encoding]::new($false))
}

$Format = Resolve-RequestFormat -Requested $Format

$tags = if ($Locale) { @($Locale) } else { @(Get-ExportLocale) }
if ($tags.Count -eq 0) {
    Write-Error 'no locale to export; the manifest names only the source and pseudo locales'
    exit 2
}

$failed = 0
foreach ($tag in $tags) {
    $rows = @(Get-LocalizationRow -Root $Root -ProjectRoot $ProjectRoot -Locale $tag)
    if ($rows.Count -eq 0) {
        Write-Warning ('{0}: no localizable row was found' -f $tag)
        $failed++
        continue
    }
    $digest = Get-LocalizationRequestDigest -Row $rows

    $previousBundle = Join-Path $OutputRoot $tag
    $previousRequestPath = Join-Path $previousBundle 'request.json'
    $previousRequest = if ([IO.File]::Exists($previousRequestPath)) {
        ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($previousRequestPath))
    } else { $null }
    $answers = Read-LocalizationAnswer -BundleRoot $previousBundle
    $state = Get-LocalizationRowState -Row $rows -PreviousRequest $previousRequest -Answer $answers

    $outstanding = @($rows | Where-Object { [string]$state[[string]$_.id].state -cne 'carried' })
    $destination = Join-Path $InputRoot $tag
    if (-not $PSCmdlet.ShouldProcess($destination, 'write the localization request')) { continue }

    if ([IO.Directory]::Exists($destination)) { Remove-Item -LiteralPath $destination -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $destination -Force

    # request.json is the index and the digest authority; the files beside it
    # are what a person edits. Keeping the English in both would let them
    # disagree, and only one of them would be the question that was asked.
    $requestRows = foreach ($row in $rows) {
        [ordered]@{
            id = [string]$row.id
            kind = [string]$row.kind
            file = [string]$row.file
            state = [string]$state[[string]$row.id].state
            sourceSha256 = [string]$row.sourceSha256
            english = [string]$row.english
        }
    }
    $schema = Get-LocalizationExchangeSchema
    Write-Utf8Json -Path (Join-Path $destination 'request.json') -Value ([ordered]@{
            schema = $schema.request
            locale = $tag
            sourceLocale = 'en-US'
            format = $Format
            releaseVersion = ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim()
            requestDigest = $digest
            rows = @($requestRows)
        })

    foreach ($group in ($rows | Group-Object { [string]$_.file })) {
        $relative = [string]$group.Name
        if ($relative -like 'documents/*') { continue }
        $entries = foreach ($row in $group.Group) { New-EntryRecord -Row $row -State $state }
        Write-Utf8Json -Path (Join-Path $destination $relative) -Value ([ordered]@{
                locale = $tag
                entries = @($entries)
            })
    }
    foreach ($row in ($rows | Where-Object { [string]$_.kind -ceq 'document' })) {
        $target = Join-Path $destination ([string]$row.file)
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        $known = $state[[string]$row.id]
        # A carried document ships the translation already returned; anything
        # else ships the English, which is what has to be worked from.
        $text = if ([string]$known.state -ceq 'carried') { [string]$known.previousTranslation } else { [string]$row.english }
        [IO.File]::WriteAllText($target, $text, [Text.UTF8Encoding]::new($false))
    }

    $referenceSource = Join-Path $Root 'globalization/fixtures/reference/en-US'
    if ([IO.Directory]::Exists($referenceSource)) {
        $referenceTarget = Join-Path $destination 'reference'
        $null = New-Item -ItemType Directory -Path $referenceTarget -Force
        foreach ($file in @(Get-ChildItem -LiteralPath $referenceSource -Filter '*.txt')) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $referenceTarget $file.Name) -Force
        }
    }

    Write-Utf8Json -Path (Join-Path $destination 'attestation.json') -Value ([ordered]@{
            schema = $schema.attestation
            locale = $tag
            requestDigest = $digest
            translator = [ordered]@{ approvedBy = ''; approvedAt = '' }
            independentReviewer = [ordered]@{ approvedBy = ''; approvedAt = '' }
        })
    Write-RequestReadme -Path (Join-Path $destination 'README.md') -Tag $tag -Row $rows -State $state `
        -Digest $digest.sha256

    $counts = @{ carried = 0; changed = 0; new = 0 }
    foreach ($row in $rows) { $counts[[string]$state[[string]$row.id].state]++ }
    if ($outstanding.Count -eq 0) {
        Write-Line ('{0}: every row is carried forward; the English has not moved and there is nothing to send.' -f $tag)
    } else {
        Write-Line ('{0}: {1} row(s) -- {2} new, {3} changed, {4} carried. Send {5}' -f
            $tag, $rows.Count, $counts['new'], $counts['changed'], $counts['carried'], $destination)
    }
}

if ($failed -gt 0) { exit 2 }
Write-Output ('Export-Localization: wrote {0} request(s) under {1}.' -f $tags.Count, $InputRoot)
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
