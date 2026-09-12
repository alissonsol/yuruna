<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42a9f7d0-38c1-4e56-b7a4-1d2e05c9b8f3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization localization import attestation approval
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
    Place a returned localization bundle into the code, and record who approved it.
.DESCRIPTION
    The team returns the folder it was sent, filled in, under
    dev-only/localization-output/<locale>/. This reads it back and puts every
    answer where the code expects to find it: term decisions into the
    terminology source, style guidance into the style guide, messages into a
    target catalog, documents into each repository's translated tree, and the
    project scalars' review state into the project map.

    Nothing is placed until the bundle is proven to answer the request that was
    sent. The returned attestation repeats the request digest; the request in
    the bundle has to hash to that same value, so a bundle cannot vouch for
    itself after being edited; and the tree has to still ask the same question,
    because an approval that covers superseded English is worse than no
    approval at all.

    The approval digest is recomputed from the bytes that were actually placed
    rather than the ones that were sent. An approval therefore covers the text
    in the tree.
.PARAMETER Locale
    Locale tags to import. Defaults to every locale with a returned bundle.
.PARAMETER Root
    Framework repository root. Defaults to the parent of this script.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree.
.PARAMETER OutputRoot
    Where the returned bundles are read from.
    Default: dev-only/localization-output.
.PARAMETER AllowSourceDrift
    Place a bundle whose request no longer matches the tree. The rows that
    moved are named either way; without this they stop the import.
.PARAMETER NoPublish
    Stop after placement instead of running Publish-Localization.
.PARAMETER Quiet
    Report only the summary line.
.OUTPUTS
    A summary line per locale. Exit 0 when every bundle was placed, 2 when one
    was refused or a downstream step failed.
.EXAMPLE
    pwsh tools/Import-Localization.ps1 -Locale pt-BR
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Quiet is read by the private Write-Line helper; ScriptAnalyzer does not follow that dynamic script scope.')]
param(
    [string[]]$Locale,
    [string]$Root,
    [string]$ProjectRoot,
    [string]$OutputRoot,
    [switch]$AllowSourceDrift,
    [switch]$NoPublish,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $Root) 'yuruna-project' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $OutputRoot) { $OutputRoot = Join-Path $Root 'dev-only/localization-output' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

# From this tool's own location, not from -Root: -Root names the tree being
# exchanged, which in a test is a fixture that ships no modules of its own.
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'test/modules/Test.LocalizationExchange.psm1') `
    -Force -Global -DisableNameChecking

$script:PowerShellPath = (Get-Process -Id $PID).Path

function Write-Line {
    param([string]$Text = '')
    if (-not $Quiet) { Write-Information $Text -InformationAction Continue }
}

function Write-Utf8Json {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes a tracked artifact the caller has already confirmed.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)

    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $json = ((ConvertTo-Json -InputObject $Value -Depth 30) -replace "`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Test-ExchangeDocument {
    <#
    .SYNOPSIS
        Whether a returned file still has the shape it was sent with.
    .DESCRIPTION
        The bundle crosses an organization boundary and comes back edited by
        hand or by a tool nobody here chose. A missing field or a renamed one
        should say so plainly, rather than surfacing later as a null somewhere
        that has already written half an artifact.
    .OUTPUTS
        [pscustomobject] Ok, Detail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SchemaName)

    # From this tool's own location: the schema describes the exchange format,
    # which is this tool's contract rather than a property of the tree being
    # exchanged.
    $schema = Join-Path (Split-Path -Parent $PSScriptRoot) ('globalization/schema/{0}.schema.json' -f $SchemaName)
    if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue) -or -not [IO.File]::Exists($schema)) {
        return [pscustomobject]@{ Ok = $true; Detail = '' }
    }
    $raw = [IO.File]::ReadAllText($Path)
    $failure = ''
    try {
        if (Test-Json -Json $raw -SchemaFile $schema -ErrorAction Stop) {
            return [pscustomobject]@{ Ok = $true; Detail = '' }
        }
    } catch {
        $failure = [string]$_.Exception.Message
    }
    $name = Split-Path -Leaf $Path
    return [pscustomobject]@{ Ok = $false; Detail = "$name does not match ${SchemaName}: $failure" }
}

function Get-DecisionPropertyName {
    <#
    .SYNOPSIS
        The per-locale decision field on a term, found by what it is not.
    .DESCRIPTION
        The field is named for the locale it belongs to. Spelling it out here
        would be a second place to change when a language is added, and the one
        nobody would remember.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Term)

    $known = @('sourceTerm', 'meaning', 'sourceHeadings')
    $candidate = @($Term.PSObject.Properties.Name | Where-Object { $known -notcontains $_ })
    if ($candidate.Count -ne 1) {
        throw "A term carries $($candidate.Count) decision fields; exactly one is expected."
    }
    return $candidate[0]
}

function Set-TermDecision {
    <#
    .SYNOPSIS
        Write the returned term decisions into the terminology source.
    .DESCRIPTION
        A decision that repeats the source term is a decision to keep the
        English word, which the terminology source records as retained and
        without a target term. Anything else is a translation.
    .OUTPUTS
        [int] decisions written
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]$Terminology,
        [Parameter(Mandatory)][Collections.IDictionary]$Answer
    )

    $written = 0
    foreach ($term in @($Terminology.terms)) {
        $source = [string]$term.sourceTerm
        $id = 'term:{0}' -f $source
        if (-not $Answer.Contains($id)) { continue }
        $target = ([string]$Answer[$id]).Trim()
        if (-not $target) { continue }
        if (-not $PSCmdlet.ShouldProcess($source, 'record the term decision')) { continue }
        $property = Get-DecisionPropertyName -Term $term
        $decision = if ([string]::Equals($target, $source, [StringComparison]::Ordinal)) {
            [pscustomobject]@{ status = 'retained' }
        } else {
            [pscustomobject]@{ status = 'translated'; targetTerm = $target }
        }
        $term.$property = $decision
        $written++
    }
    return $written
}

function Set-StyleRule {
    <#
    .SYNOPSIS
        Replace style guidance the reviewer rewrote.
    .OUTPUTS
        [int] rules written
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)]$Style, [Parameter(Mandatory)][Collections.IDictionary]$Answer)

    $written = 0
    foreach ($rule in @($Style.rules)) {
        $id = 'style-rule:{0}' -f [string]$rule.id
        if (-not $Answer.Contains($id)) { continue }
        $text = ([string]$Answer[$id]).Trim()
        if (-not $text) { continue }
        if (-not $PSCmdlet.ShouldProcess([string]$rule.id, 'record the style rule')) { continue }
        $rule.guidance = $text
        $written++
    }
    return $written
}

function Write-TargetCatalog {
    <#
    .SYNOPSIS
        Write the target-locale message catalogs from the returned answers.
    .DESCRIPTION
        The source catalog is the shape; only the words move. Descriptions,
        placeholders and lifecycle stay exactly as authored, because they are
        the contract the runtime and the gates read rather than anything a
        translator decides.
    .OUTPUTS
        [int] messages written
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][Collections.IDictionary]$Answer,
        [string]$SourceLocale = 'en-US'
    )

    $written = 0
    $sourceDirectory = Join-Path $Root ('globalization/catalogs/{0}' -f $SourceLocale)
    if (-not [IO.Directory]::Exists($sourceDirectory)) { return 0 }
    $targetDirectory = Join-Path $Root ('globalization/catalogs/{0}' -f $Locale)
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceDirectory -Filter '*.json' | Sort-Object -Property Name)) {
        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($file.FullName))
        $domain = [string]$catalog.domain
        $messages = [ordered]@{}
        $touched = 0
        foreach ($code in (Get-OrdinalSortedName -Name @($catalog.messages.PSObject.Properties.Name | Where-Object { $_ }))) {
            $entry = $catalog.messages.$code
            $id = 'message:{0}:{1}' -f $domain, $code
            if (-not $Answer.Contains($id)) { continue }
            $text = ([string]$Answer[$id]).Trim()
            if (-not $text) { continue }
            $names = @($entry.PSObject.Properties.Name)
            $record = [ordered]@{}
            if ($names -contains 'plural') {
                $variants = [ordered]@{}
                foreach ($line in @($text -split "`n")) {
                    if ($line -match '^(?<name>[a-z]+)=(?<value>.*)$') { $variants[$Matches['name']] = $Matches['value'] }
                }
                $record['plural'] = [ordered]@{ selector = [string]$entry.plural.selector; variants = $variants }
            } else {
                $record['message'] = $text
            }
            foreach ($carry in 'description', 'lifecycle', 'placeholders') {
                if ($names -contains $carry) { $record[$carry] = $entry.$carry }
            }
            $messages[$code] = $record
            $touched++
        }
        if ($touched -eq 0) { continue }
        $target = Join-Path $targetDirectory ('{0}.json' -f $domain)
        if (-not $PSCmdlet.ShouldProcess($target, 'write the target catalog')) { continue }
        Write-Utf8Json -Path $target -Value ([ordered]@{
                schema = [string]$catalog.schema
                domain = $domain
                locale = $Locale
                messages = $messages
            })
        $written += $touched
    }
    return $written
}

function Write-TranslatedDocument {
    <#
    .SYNOPSIS
        Place each returned document in the repository that owns it.
    .OUTPUTS
        [string[]] the repository-qualified documents placed
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][Collections.IDictionary]$Answer)

    $placed = [Collections.Generic.List[string]]::new()
    $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
            (Join-Path $Root 'globalization/manifests/doc-translations.json')))
    foreach ($document in @($manifest.documents)) {
        if ([string]$document.locale -cne $Locale) { continue }
        $repo = [string]$document.repo
        $source = [string]$document.source
        $id = 'document:{0}:{1}' -f $repo, $source
        if (-not $Answer.Contains($id)) { continue }
        $text = [string]$Answer[$id]
        if (-not $text.Trim()) { continue }
        $tree = if ($repo -ceq 'yuruna') { $Root } else { $ProjectRoot }
        $target = Join-Path $tree ([string]$document.translated)
        if (-not $PSCmdlet.ShouldProcess($target, 'place the translated document')) { continue }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        [IO.File]::WriteAllText($target, ($text.TrimEnd() + "`n"), [Text.UTF8Encoding]::new($false))
        # Parenthesized: inside a method call the comma would separate
        # arguments rather than feed the format string.
        $placed.Add(('{0}:{1}' -f $repo, $source))
    }
    return $placed.ToArray()
}

function Set-ProjectScalarReview {
    <#
    .SYNOPSIS
        Advance the review state of each answered project scalar.
    .OUTPUTS
        [int] entries advanced
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][Collections.IDictionary]$Answer)

    $path = Join-Path $ProjectRoot 'globalization/project-locale-source-hashes.json'
    if (-not [IO.File]::Exists($path)) { return 0 }
    $record = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
    $written = 0
    foreach ($entry in @($record.entries)) {
        if ([string]$entry.locale -cne $Locale) { continue }
        $id = 'project-scalar:{0}:{1}' -f [string]$entry.path, [string]$entry.fieldPath
        if (-not $Answer.Contains($id)) { continue }
        if (-not ([string]$Answer[$id]).Trim()) { continue }
        if (-not $PSCmdlet.ShouldProcess($id, 'record the scalar review')) { continue }
        $entry.reviewStatus = 'reviewed'
        $written++
    }
    if ($written -gt 0) { Write-Utf8Json -Path $path -Value $record }
    return $written
}

function New-ApprovalRecord {
    <#
    .SYNOPSIS
        The approval block for one artifact, bound to what it now holds.
    .DESCRIPTION
        The digest is taken after the artifact is written, so it covers the
        text that landed rather than the text that was returned. Those are the
        same only when nothing went wrong, and an approval is exactly the
        record that has to be right when something did.
    .OUTPUTS
        [ordered]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a value; the caller writes it.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][ValidateSet('terminology', 'style-guide')][string]$Kind,
        [Parameter(Mandatory)]$Attestation,
        [Parameter(Mandatory)][string]$ReleaseVersion
    )

    $digest = Get-ApprovableContentDigest -Artifact $Artifact -Kind $Kind
    $record = [ordered]@{}
    foreach ($role in 'translator', 'independentReviewer') {
        $record[$role] = [ordered]@{
            status = 'approved'
            approvedBy = [string]$Attestation.$role.approvedBy
            approvedAt = [string]$Attestation.$role.approvedAt
            evidence = [ordered]@{
                releaseVersion = $ReleaseVersion
                approvedContent = [ordered]@{ algorithm = $digest.algorithm; sha256 = $digest.sha256 }
            }
        }
    }
    return $record
}

$tags = if ($Locale) {
    @($Locale)
} elseif ([IO.Directory]::Exists($OutputRoot)) {
    @(Get-ChildItem -LiteralPath $OutputRoot -Directory | Sort-Object -Property Name | ForEach-Object { $_.Name })
} else { @() }

if ($tags.Count -eq 0) {
    Write-Error "no returned bundle was found under $OutputRoot"
    exit 2
}

$release = ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim()
$refused = 0
$imported = [Collections.Generic.List[string]]::new()

foreach ($tag in $tags) {
    $bundle = Join-Path $OutputRoot $tag
    $requestPath = Join-Path $bundle 'request.json'
    $attestationPath = Join-Path $bundle 'attestation.json'
    if (-not [IO.File]::Exists($requestPath) -or -not [IO.File]::Exists($attestationPath)) {
        Write-Warning ('{0}: the bundle has no request.json and attestation.json pair' -f $tag)
        $refused++
        continue
    }

    $shape = @(
        (Test-ExchangeDocument -Path $requestPath -SchemaName 'localization-request'),
        (Test-ExchangeDocument -Path $attestationPath -SchemaName 'localization-attestation')
    ) | Where-Object { -not $_.Ok }
    if (@($shape).Count -gt 0) {
        foreach ($problem in @($shape)) { Write-Warning ('{0}: {1}' -f $tag, $problem.Detail) }
        $refused++
        continue
    }

    $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($requestPath))
    # The bundle's own request has to hash to the digest it publishes, or a
    # bundle edited after it was sent would vouch for itself.
    $selfDigest = Get-LocalizationRequestDigest -Row @($request.rows)
    if (-not [string]::Equals($selfDigest.sha256, [string]$request.requestDigest.sha256, [StringComparison]::Ordinal)) {
        Write-Warning ('{0}: the returned request does not hash to the digest it carries; its rows were edited' -f $tag)
        $refused++
        continue
    }

    $attestation = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($attestationPath))
    $verdict = Test-LocalizationAttestation -Attestation $attestation -RequestSha256 $selfDigest.sha256
    if (-not $verdict.Ok) {
        Write-Warning ('{0}: {1}' -f $tag, $verdict.Detail)
        $refused++
        continue
    }

    $current = @(Get-LocalizationRow -Root $Root -ProjectRoot $ProjectRoot -Locale $tag)
    $currentDigest = Get-LocalizationRequestDigest -Row $current
    if (-not [string]::Equals($currentDigest.sha256, $selfDigest.sha256, [StringComparison]::Ordinal)) {
        $known = @{}
        foreach ($entry in @($request.rows)) { $known[[string]$entry.id] = [string]$entry.sourceSha256 }
        $moved = foreach ($row in $current) {
            $id = [string]$row.id
            if (-not $known.ContainsKey($id)) { "$id (new)" }
            elseif (-not [string]::Equals($known[$id], [string]$row.sourceSha256, [StringComparison]::Ordinal)) { $id }
        }
        $detail = '{0}: the English moved since this request was sent -- {1}' -f $tag, (@($moved) -join ', ')
        if (-not $AllowSourceDrift) {
            Write-Warning ("$detail. Re-export and re-send those rows, or pass -AllowSourceDrift.")
            $refused++
            continue
        }
        Write-Warning $detail
    }

    $answers = Read-LocalizationAnswer -BundleRoot $bundle
    if ($answers.Count -eq 0) {
        Write-Warning ('{0}: the bundle carries no answer' -f $tag)
        $refused++
        continue
    }

    $termsPath = Join-Path $Root ('globalization/terminology/{0}.terms.json' -f $tag)
    $stylePath = Join-Path $Root ('globalization/terminology/{0}.style-guide.json' -f $tag)
    $terminology = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($termsPath))
    $style = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($stylePath))

    $termCount = Set-TermDecision -Terminology $terminology -Answer $answers
    $ruleCount = Set-StyleRule -Style $style -Answer $answers

    # The status moves before the digest is taken: the digest covers the
    # approvable projection, and the artifact has to be in its final shape
    # before anything attests to it.
    $terminology.status = 'approved'
    $style.status = 'approved'
    $terminology.approvals = New-ApprovalRecord -Artifact $terminology -Kind 'terminology' `
        -Attestation $attestation -ReleaseVersion $release
    Write-Utf8Json -Path $termsPath -Value $terminology

    # The style guide pins the terminology bytes it was written against, so the
    # pin is refreshed before its own digest is taken. Taking them in the other
    # order would stale every style-guide approval the moment it was granted.
    $style.terminologySource.sha256 = (Get-FileHash -LiteralPath $termsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $style.approvals = New-ApprovalRecord -Artifact $style -Kind 'style-guide' `
        -Attestation $attestation -ReleaseVersion $release
    Write-Utf8Json -Path $stylePath -Value $style

    $messageCount = Write-TargetCatalog -Locale $tag -Answer $answers
    $documents = @(Write-TranslatedDocument -Locale $tag -Answer $answers)
    $scalarCount = Set-ProjectScalarReview -Locale $tag -Answer $answers

    $recorded = 0
    foreach ($document in $documents) {
        $arguments = [string[]]@('-NoProfile', '-File', (Join-Path $Root 'tools/Test-DocTranslation.ps1'),
            '-Locale', $tag, '-ProjectRoot', $ProjectRoot, '-AcceptReview', '-Status', 'reviewed',
            '-Path', $document, '-Quiet')
        $global:LASTEXITCODE = 0
        $output = (& $script:PowerShellPath @arguments 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) { $recorded++; continue }
        Write-Warning ('{0}: could not record {1} reviewed (exit {2}): {3}' -f $tag, $document, $LASTEXITCODE, $output)
    }

    Write-Line ('{0}: {1} term(s), {2} style rule(s), {3} message(s), {4} document(s) placed and {5} recorded reviewed, {6} project scalar(s).' -f
        $tag, $termCount, $ruleCount, $messageCount, $documents.Count, $recorded, $scalarCount)
    $imported.Add($tag)
}

if ($imported.Count -gt 0 -and -not $NoPublish) {
    $arguments = [string[]]@('-NoProfile', '-File', (Join-Path $Root 'tools/Publish-Localization.ps1'),
        '-Root', $Root, '-ProjectRoot', $ProjectRoot)
    if ($Quiet) { $arguments += '-Quiet' }
    $global:LASTEXITCODE = 0
    & $script:PowerShellPath @arguments
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('Import-Localization: placed {0} bundle(s); publishing failed.' -f $imported.Count)
        exit 2
    }
}

Write-Output ('Import-Localization: placed {0} bundle(s), refused {1}.' -f $imported.Count, $refused)
if ($refused -gt 0) { exit 2 }
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
