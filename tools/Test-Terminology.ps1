<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42d6b0f7-8b28-44dd-9e89-c3a26a7d82f1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate globalization terminology style-guide review
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
    Validate the authoritative pt-BR terminology and style-guide sources.
.DESCRIPTION
    The terminology source is derived from docs/definition.md and the four
    prose vocabulary rulings inside the pre-commit hook's retired-name block.
    This gate pins both source forms, verifies every referenced definition
    heading, and keeps the hook's exact English search literals out of the
    translation fields.

    Draft content is valid engineering input, but it is not approval. Both
    artifacts carry separate translator and independent-reviewer records.
    Pending records cannot carry a person's name, date, or evidence, while an
    approved record must carry all three. The evidence is the release the
    approval was given for, and nothing else: the record an approver worked
    from is not published, so hashing a published copy of it would only pin a
    file that says less than the date does. A recorded release this tree has
    not reached is rejected, because an approval cannot have been given for a
    release that does not exist. An earlier one is left standing -- the field
    is a historical stamp, not a claim about the current version, and a
    routine version bump does not send two people back for a second signature.
    Until the whole baseline is approved, this gate also rejects a pt-BR
    document manifest that promotes any mapped draft to reviewed.

    Exit codes:
        0  The sources and metadata are valid. Approval may still be pending
           unless -RequireApproved was supplied.
        1  An artifact is missing or invalid, a pinned source drifted, a
           protected literal changed, or required approval is incomplete.
        2  A source/schema needed to evaluate the artifacts is unavailable.
.PARAMETER Root
    Repository root. Defaults to the parent of this tool's directory.
.PARAMETER TerminologyPath
    Terminology artifact. Relative paths are resolved from Root. Default:
    globalization/terminology/pt-BR.terms.json.
.PARAMETER StyleGuidePath
    Style-guide artifact. Relative paths are resolved from Root. Default:
    globalization/terminology/pt-BR.style-guide.json.
.PARAMETER DefinitionPath
    English definition source. Relative paths are resolved from Root. Default:
    docs/definition.md.
.PARAMETER HookPath
    Hook carrying the retired-name vocabulary. Relative paths are resolved
    from Root. Default: tools/githooks/pre-commit.
.PARAMETER DocManifestPath
    The 13-document review-status manifest. Relative paths are resolved from
    Root. Default: globalization/manifests/doc-translations.json.
.PARAMETER VersionPath
    The calendar version this tree has reached, which bounds the release an
    approval may name. Relative paths are resolved from Root. Default: VERSION.
.PARAMETER RequireApproved
    Require both artifacts, every term decision, the translator, and the
    independent reviewer to be approved. Normal engineering checks omit this;
    release/handoff checks supply it.
.PARAMETER Quiet
    Print only findings and the summary.

.EXAMPLE
    pwsh tools/Test-Terminology.ps1
    Validates the draft source without claiming that a person approved it.

.EXAMPLE
    pwsh tools/Test-Terminology.ps1 -RequireApproved
    Fails until the translator and independent reviewer evidence is complete.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string]$Root,
    [string]$TerminologyPath,
    [string]$StyleGuidePath,
    [string]$DefinitionPath,
    [string]$HookPath,
    [string]$DocManifestPath,
    [string]$VersionPath,
    [switch]$RequireApproved,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

function Get-RootedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Root $Path))
}

if (-not $TerminologyPath) { $TerminologyPath = 'globalization/terminology/pt-BR.terms.json' }
if (-not $StyleGuidePath) { $StyleGuidePath = 'globalization/terminology/pt-BR.style-guide.json' }
if (-not $DefinitionPath) { $DefinitionPath = 'docs/definition.md' }
if (-not $HookPath) { $HookPath = 'tools/githooks/pre-commit' }
if (-not $DocManifestPath) { $DocManifestPath = 'globalization/manifests/doc-translations.json' }
if (-not $VersionPath) { $VersionPath = 'VERSION' }

$TerminologyPath = Get-RootedPath -Path $TerminologyPath
$StyleGuidePath = Get-RootedPath -Path $StyleGuidePath
$DefinitionPath = Get-RootedPath -Path $DefinitionPath
$HookPath = Get-RootedPath -Path $HookPath
$DocManifestPath = Get-RootedPath -Path $DocManifestPath
$VersionPath = Get-RootedPath -Path $VersionPath
$terminologySchemaPath = Join-Path $Root 'globalization/schema/terminology.schema.json'
$styleGuideSchemaPath = Join-Path $Root 'globalization/schema/style-guide.schema.json'

$evaluationInput = [ordered]@{
    'definition source' = $DefinitionPath
    'retired-name hook' = $HookPath
    'document manifest' = $DocManifestPath
    'release version' = $VersionPath
    'terminology schema' = $terminologySchemaPath
    'style-guide schema' = $styleGuideSchemaPath
}
$unavailable = @($evaluationInput.GetEnumerator() | Where-Object {
        -not (Test-Path -LiteralPath $_.Value -PathType Leaf)
    })
if ($unavailable.Count -gt 0) {
    foreach ($entry in $unavailable) {
        Write-Output "Test-Terminology: $($entry.Key) is unavailable: $($entry.Value)"
    }
    exit 2
}
if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
    Write-Output 'Test-Terminology: Test-Json is unavailable, so the artifact schemas cannot be evaluated.'
    exit 2
}

$script:Findings = [Collections.Generic.List[string]]::new()

function Add-Finding {
    param([Parameter(Mandatory)][string]$Message)
    $script:Findings.Add($Message)
}

function Get-Sha256Digest {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-Sha256File {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    return Get-Sha256Digest -Bytes ([IO.File]::ReadAllBytes($Path))
}

function Read-JsonArtifact {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$SchemaPath
    )

    try {
        $raw = [IO.File]::ReadAllText($Path)
        $value = ConvertFrom-Json -InputObject $raw
    } catch {
        Add-Finding "$Label is not valid JSON: $($_.Exception.Message)"
        return $null
    }
    try {
        if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
            Add-Finding "$Label does not satisfy $([IO.Path]::GetFileName($SchemaPath))"
            return $null
        }
    } catch {
        Add-Finding "$Label schema validation failed: $($_.Exception.Message)"
        return $null
    }
    return $value
}

function Get-RetiredNameSource {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path)
    $blockMatches = [regex]::Matches($text, '(?ms)^retired_names=''' + "\r?\n" + '(?<body>.*?)^''' + "\r?$" )
    if ($blockMatches.Count -ne 1) {
        Add-Finding "retired-name hook has $($blockMatches.Count) retired_names blocks; expected exactly one"
        return $null
    }

    $pairs = [Collections.Generic.List[object]]::new()
    foreach ($line in @($blockMatches[0].Groups['body'].Value -split '\r?\n')) {
        if (-not $line) { continue }
        $separator = $line.IndexOf('|', [StringComparison]::Ordinal)
        if ($separator -le 0 -or $separator -eq $line.Length - 1 -or
            $line.IndexOf('|', $separator + 1) -ge 0) {
            Add-Finding "retired-name hook has a malformed pair: '$line'"
            continue
        }
        $pairs.Add([pscustomobject]@{
                retired = $line.Substring(0, $separator)
                current = $line.Substring($separator + 1)
            })
    }
    $canonical = (@($pairs | ForEach-Object { "$($_.retired)|$($_.current)" }) -join "`n") + "`n"
    return @{
        Pairs = $pairs.ToArray()
        Hash = Get-Sha256Digest -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    }
}

function Get-CalendarVersion {
    [CmdletBinding()]
    [OutputType([version])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    # Version syntax alone accepts '2026.13.01', which names no day of any year,
    # so the first three components are parsed as a date before anything else
    # trusts them to order two releases.
    $shape = [regex]::Match($Value, '^(?<date>[0-9]{4}\.[0-9]{2}\.[0-9]{2})(\.[0-9]+)?$')
    if (-not $shape.Success) { return $null }
    $day = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($shape.Groups['date'].Value, 'yyyy.MM.dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$day)) {
        return $null
    }
    $parsed = [version]::new(0, 0)
    if (-not [version]::TryParse($Value, [ref]$parsed)) { return $null }
    return $parsed
}

function Test-ApprovalEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Artifact,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentVersionText
    )

    $current = Get-CalendarVersion -Value $CurrentVersionText
    foreach ($role in @('translator', 'independentReviewer')) {
        $approval = $Artifact.approvals.$role
        if ($approval.status -ne 'approved') { continue }

        $approvedAt = [datetime]::MinValue
        if (-not [datetime]::TryParseExact([string]$approval.approvedAt, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$approvedAt)) {
            Add-Finding "$Label $role approval is dated '$($approval.approvedAt)', which is no day of any year"
        }

        $recordedText = [string]$approval.evidence.releaseVersion
        $recorded = Get-CalendarVersion -Value $recordedText
        if (-not $recorded) {
            Add-Finding "$Label $role approval names release '$recordedText', which is not a calendar version"
            continue
        }
        if ($current -and $recorded -gt $current) {
            Add-Finding ("$Label $role approval names release $recordedText, which this tree has not " +
                "reached; VERSION is $CurrentVersionText")
        }
    }

    $translator = $Artifact.approvals.translator
    $reviewer = $Artifact.approvals.independentReviewer
    if ($translator.status -eq 'approved' -and $reviewer.status -eq 'approved' -and
        [string]$translator.approvedBy -ieq [string]$reviewer.approvedBy) {
        Add-Finding "$Label translator and independent reviewer must be different people"
    }
}

foreach ($artifact in ([ordered]@{
        'terminology artifact' = $TerminologyPath
        'style-guide artifact' = $StyleGuidePath
    }).GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $artifact.Value -PathType Leaf)) {
        Add-Finding "$($artifact.Key) is missing: $($artifact.Value)"
    }
}
if ($script:Findings.Count -gt 0) {
    foreach ($finding in $script:Findings) { Write-Output "FINDING: $finding" }
    Write-Output "Test-Terminology: $($script:Findings.Count) finding(s); required artifacts are incomplete."
    exit 1
}

$terminology = Read-JsonArtifact -Path $TerminologyPath -Label 'terminology artifact' `
    -SchemaPath $terminologySchemaPath
$styleGuide = Read-JsonArtifact -Path $StyleGuidePath -Label 'style-guide artifact' `
    -SchemaPath $styleGuideSchemaPath
$retiredSource = Get-RetiredNameSource -Path $HookPath
$currentVersionText = ([IO.File]::ReadAllText($VersionPath)).Trim()
if (-not (Get-CalendarVersion -Value $currentVersionText)) {
    Add-Finding "this tree's VERSION is not a calendar version: '$currentVersionText'"
}

$definitionText = [IO.File]::ReadAllText($DefinitionPath)
if ($terminology) {
    $definitionHash = Get-Sha256File -Path $DefinitionPath
    if ($definitionHash -cne [string]$terminology.sources.definitions.sha256) {
        Add-Finding "docs/definition.md changed after the terminology source was derived (expected $($terminology.sources.definitions.sha256), actual $definitionHash)"
    }

    if ($retiredSource) {
        if ($retiredSource.Hash -cne [string]$terminology.sources.retiredNames.sha256) {
            Add-Finding "the pre-commit retired-name block changed after the terminology source was derived (expected $($terminology.sources.retiredNames.sha256), actual $($retiredSource.Hash))"
        }
        if ($retiredSource.Pairs.Count -ne [int]$terminology.sources.retiredNames.entryCount) {
            Add-Finding "the terminology source records $($terminology.sources.retiredNames.entryCount) retired names but the hook contains $($retiredSource.Pairs.Count)"
        }
    }

    $requiredTerms = @('host', 'guest', 'pool', 'cycle', 'workload', 'component', 'resource',
        'stash', 'pause', 'drain', 'cache')
    $sourceTerms = @($terminology.terms | ForEach-Object { [string]$_.sourceTerm })
    foreach ($required in $requiredTerms) {
        if ($sourceTerms -cnotcontains $required) {
            Add-Finding "required baseline term is missing: $required"
        }
    }
    foreach ($duplicate in @($sourceTerms | Group-Object | Where-Object Count -GT 1)) {
        Add-Finding "terminology source repeats term '$($duplicate.Name)'"
    }
    foreach ($term in @($terminology.terms)) {
        foreach ($heading in @($term.sourceHeadings)) {
            $pattern = '(?m)^#{1,6}\s+' + [regex]::Escape([string]$heading) + '\s*$'
            if ($definitionText -notmatch $pattern) {
                Add-Finding "term '$($term.sourceTerm)' references a missing definition heading: $heading"
            }
        }
        if ($term.ptBRDecision.status -eq 'retained' -and
            $term.ptBRDecision.PSObject.Properties.Name -contains 'targetTerm') {
            Add-Finding "retained term '$($term.sourceTerm)' must inherit the exact source term, not carry a second spelling"
        }
    }

    $expectedRulings = @(
        [pscustomobject]@{ retired = 'status server'; current = 'status service' },
        [pscustomobject]@{ retired = 'stash appliance'; current = 'stash service' },
        [pscustomobject]@{ retired = 'HostConfigService'; current = 'ConfigService' },
        [pscustomobject]@{ retired = 'stash-server'; current = 'stash-service' }
    )
    if (@($terminology.retiredNameRulings).Count -ne $expectedRulings.Count) {
        Add-Finding "terminology source must carry exactly $($expectedRulings.Count) retired-name prose rulings"
    } else {
        for ($i = 0; $i -lt $expectedRulings.Count; $i++) {
            $actual = $terminology.retiredNameRulings[$i]
            $expected = $expectedRulings[$i]
            if ([string]$actual.retired -cne $expected.retired -or
                [string]$actual.current -cne $expected.current) {
                Add-Finding "retired-name ruling $($i + 1) changed or moved; expected '$($expected.retired)|$($expected.current)'"
            }
            if ([string]$actual.translationPolicy -cne 'preserve-exact-english') {
                Add-Finding "retired-name ruling '$($actual.retired)|$($actual.current)' no longer protects its exact English literals"
            }
            if ($retiredSource) {
                $exists = @($retiredSource.Pairs | Where-Object {
                        $_.retired -ceq $expected.retired -and $_.current -ceq $expected.current
                    }).Count -eq 1
                if (-not $exists) {
                    Add-Finding "retired-name ruling is not an exact hook pair: '$($expected.retired)|$($expected.current)'"
                }
            }
        }
    }
    Test-ApprovalEvidence -Artifact $terminology -Label 'terminology artifact' `
        -CurrentVersionText $currentVersionText
}

if ($styleGuide) {
    $terminologyHash = Get-Sha256File -Path $TerminologyPath
    if ($terminologyHash -cne [string]$styleGuide.terminologySource.sha256) {
        Add-Finding "the terminology source changed after the style guide was derived (expected $($styleGuide.terminologySource.sha256), actual $terminologyHash)"
    }
    $requiredRules = @('terminology', 'tone', 'punctuation-capitalization',
        'commands-files-identifiers', 'keyboard-shortcuts', 'numbers-dates-times-zones',
        'measurement-units', 'placeholders', 'inclusive-accessible-language',
        'machine-matched-literals')
    $ruleIds = @($styleGuide.rules | ForEach-Object { [string]$_.id })
    foreach ($required in $requiredRules) {
        if ($ruleIds -cnotcontains $required) { Add-Finding "required pt-BR style rule is missing: $required" }
    }
    foreach ($duplicate in @($ruleIds | Group-Object | Where-Object Count -GT 1)) {
        Add-Finding "style guide repeats rule '$($duplicate.Name)'"
    }
    Test-ApprovalEvidence -Artifact $styleGuide -Label 'style-guide artifact' `
        -CurrentVersionText $currentVersionText
}

$docManifest = $null
try { $docManifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($DocManifestPath)) }
catch { Add-Finding "document manifest is not valid JSON: $($_.Exception.Message)" }

$approvalComplete = $false
if ($terminology -and $styleGuide) {
    $termDecisionsComplete = @($terminology.terms | Where-Object {
            $_.ptBRDecision.status -eq 'pending'
        }).Count -eq 0
    $approvalComplete = $terminology.status -eq 'approved' -and $styleGuide.status -eq 'approved' -and
        $terminology.approvals.translator.status -eq 'approved' -and
        $terminology.approvals.independentReviewer.status -eq 'approved' -and
        $styleGuide.approvals.translator.status -eq 'approved' -and
        $styleGuide.approvals.independentReviewer.status -eq 'approved' -and
        $termDecisionsComplete
}

if ($docManifest) {
    if ($docManifest.schema -ne 'yuruna.doc-translations/v1') {
        Add-Finding "document manifest has unsupported schema '$($docManifest.schema)'"
    }
    $documents = @($docManifest.documents)
    if ($documents.Count -ne 13) {
        Add-Finding "document manifest contains $($documents.Count) mappings; expected the 13-document subset"
    }
    if (-not $approvalComplete) {
        foreach ($document in @($documents | Where-Object status -NE 'draft')) {
            Add-Finding "$($document.repo)/$($document.source) is '$($document.status)' before terminology/style-guide approval; it must remain draft"
        }
    }
}

if ($RequireApproved -and -not $approvalComplete) {
    $pending = [Collections.Generic.List[string]]::new()
    if ($terminology) {
        if ($terminology.status -ne 'approved') { $pending.Add("terminology artifact=$($terminology.status)") }
        foreach ($role in @('translator', 'independentReviewer')) {
            if ($terminology.approvals.$role.status -ne 'approved') {
                $pending.Add("terminology $role=$($terminology.approvals.$role.status)")
            }
        }
        $termPending = @($terminology.terms | Where-Object { $_.ptBRDecision.status -eq 'pending' }).Count
        if ($termPending -gt 0) { $pending.Add("term decisions pending=$termPending") }
    }
    if ($styleGuide) {
        if ($styleGuide.status -ne 'approved') { $pending.Add("style guide=$($styleGuide.status)") }
        foreach ($role in @('translator', 'independentReviewer')) {
            if ($styleGuide.approvals.$role.status -ne 'approved') {
                $pending.Add("style guide $role=$($styleGuide.approvals.$role.status)")
            }
        }
    }
    Add-Finding "baseline approval is incomplete: $($pending -join '; ')"
}

$termCount = if ($terminology) { @($terminology.terms).Count } else { 0 }
$rulingCount = if ($terminology) { @($terminology.retiredNameRulings).Count } else { 0 }
$ruleCount = if ($styleGuide) { @($styleGuide.rules).Count } else { 0 }
$state = if ($approvalComplete) { 'approved' } else { 'approval pending' }

if ($script:Findings.Count -gt 0) {
    foreach ($finding in $script:Findings) { Write-Output "FINDING: $finding" }
    Write-Output "Test-Terminology: $($script:Findings.Count) finding(s); $termCount term(s), $rulingCount protected ruling(s), $ruleCount style rule(s); $state."
    exit 1
}
if (-not $Quiet) {
    Write-Output "Test-Terminology: definitions and the retired-name block match their recorded hashes."
}
Write-Output "Test-Terminology: $termCount term(s), $rulingCount protected ruling(s), $ruleCount style rule(s); $state."
exit 0
