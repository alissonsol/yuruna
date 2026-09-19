<#PSScriptInfo
.VERSION 2026.09.18
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
    Retained for CLI compatibility; source drift is always refused. Re-export
    changed source before collecting the corresponding review.
.PARAMETER NoPublish
    Stop after validated placement instead of running Publish-Localization.
    Compiler and document acceptance validation still run in the staged pair.
.PARAMETER ValidateOnly
    Validate and compile a disposable paired tree without applying source changes.
.PARAMETER RequireComplete
    Refuse a returned batch unless every current request row has an answer.
.PARAMETER EnableLocale
    Mark the accepted locale supported in the staged tree. Requires
    RequireComplete and an explicit pinned plural rule; the compiler verifies
    complete key coverage before anything is applied.
.PARAMETER DeferFullGate
    Run publication generation and its focused gates in the isolated pair,
    deferring only the full cross-repository gate to the finish controller.
.PARAMETER ReportPath
    Optional private JSON result outside both source trees. Records actual
    attestation identities, request digests, missing rows, and changed paths.
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
    [switch]$ValidateOnly,
    [switch]$RequireComplete,
    [switch]$EnableLocale,
    [switch]$DeferFullGate,
    [string]$ReportPath,
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
        return [pscustomobject]@{ Ok = $false; Detail = "Required schema or Test-Json validator is unavailable: $schema" }
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
        $target = Resolve-LocalizationPath -Root $targetDirectory -Relative ('{0}.json' -f $domain)
        $messages = [ordered]@{}
        if ([IO.File]::Exists($target)) {
            $existing = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($target))
            foreach ($property in $existing.messages.PSObject.Properties) { $messages[$property.Name] = $property.Value }
        }
        $touched = 0
        foreach ($code in (Get-OrdinalSortedName -Name @($catalog.messages.PSObject.Properties.Name | Where-Object { $_ }))) {
            $entry = $catalog.messages.$code
            $id = 'message:{0}:{1}' -f $domain, $code
            if (-not $Answer.Contains($id)) { continue }
            $text = [string]$Answer[$id]
            if (-not $text.Trim()) { continue }
            $names = @($entry.PSObject.Properties.Name)
            $record = [ordered]@{ sourceHash = Get-LocalizationMessageHash -Key $code -Message $entry }
            $kind = if ($names -contains 'plural') { 'plural' } elseif ($names -contains 'select') { 'select' } else { 'message' }
            if ($kind -ceq 'message') { $record['message'] = $text }
            else {
                $variants = ConvertFrom-Json -InputObject $text -AsHashtable
                if ($variants -isnot [Collections.IDictionary] -or -not $variants.Count) { throw "Variants must be a JSON object: $id" }
                foreach ($value in $variants.Values) { if ($value -isnot [string] -or -not $value.Trim()) { throw "Empty/nontext variant: $id" } }
                $record[$kind] = [ordered]@{ variants = $variants }
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
        $target = Resolve-LocalizationPath -Root $tree -Relative ([string]$document.translated)
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
    param([Parameter(Mandatory)][string]$Locale, [Parameter(Mandatory)][Collections.IDictionary]$Answer, [Parameter(Mandatory)]$Attestation)

    $path = Join-Path $ProjectRoot 'globalization/project-locale-source-hashes.json'
    $sourceRecord = Get-LocalizationProjectSource -ProjectRoot $ProjectRoot -Locale $Locale
    $record = if ([IO.File]::Exists($path)) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) } else { [pscustomobject]@{ schema = $sourceRecord.schema; hashAlgorithm = $sourceRecord.hashAlgorithm; entries = @() } }
    $existing = @{}; foreach ($entry in $record.entries) { $existing[[string]$entry.path + '|' + [string]$entry.fieldPath + '|' + [string]$entry.locale] = $true }
    foreach ($sourceEntry in $sourceRecord.entries) {
        $identity = $sourceEntry.path + '|' + $sourceEntry.fieldPath + '|' + $sourceEntry.locale
        $id = 'project-scalar:{0}:{1}' -f $sourceEntry.path, $sourceEntry.fieldPath
        if (-not $existing.ContainsKey($identity) -and $Answer.Contains($id)) { $record.entries += [pscustomobject]$sourceEntry }
    }
    $written = 0
    $yaml = @{}
    Assert-LocalizationYamlCodec
    foreach ($entry in @($record.entries)) {
        if ([string]$entry.locale -cne $Locale) { continue }
        $id = 'project-scalar:{0}:{1}' -f [string]$entry.path, [string]$entry.fieldPath
        if (-not $Answer.Contains($id)) { continue }
        if (-not ([string]$Answer[$id]).Trim()) { continue }
        if (-not $PSCmdlet.ShouldProcess($id, 'record the scalar review')) { continue }
        $yamlPath = Resolve-LocalizationPath -Root $ProjectRoot -Relative ([string]$entry.path)
        if (-not $yaml.ContainsKey($yamlPath)) { $yaml[$yamlPath] = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($yamlPath)) -Ordered }
        $english = Get-YamlPointerValue -Document $yaml[$yamlPath] -Pointer ([string]$entry.fieldPath)
        if (-not $english) { throw "Missing project source scalar: $id" }
        Set-LocalizationYamlValue -Document $yaml[$yamlPath] -Pointer ([string]$entry.fieldPath) -Locale $Locale -Text ([string]$Answer[$id])
        $entry.sourceHash = Get-TextSha256 -Text $english.Normalize([Text.NormalizationForm]::FormC)
        $entry.reviewStatus = 'reviewed'
        $entry | Add-Member -NotePropertyName reviewer -NotePropertyValue ([string]$Attestation.independentReviewer.approvedBy) -Force
        $entry | Add-Member -NotePropertyName reviewedAt -NotePropertyValue ([string]$Attestation.independentReviewer.approvedAt) -Force
        $written++
    }
    foreach ($yamlPath in $yaml.Keys) {
        $text = ConvertTo-Yaml -Data $yaml[$yamlPath]
        [IO.File]::WriteAllText($yamlPath, $text.Replace("`r`n", "`n").TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
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


function Get-ExchangeSnapshot {
    param([string]$Directory)
    $snapshot = @{}
    $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($Directory)
    while ($pending.Count) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
            if ($item.Name -in @('.git', '.agents', '.codex', 'node_modules', 'localization-input', 'localization-output')) { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked source path: $($item.FullName)" }
            if ($item.PSIsContainer) { $pending.Push($item.FullName); continue }
            $relative = [IO.Path]::GetRelativePath($Directory, $item.FullName).Replace('\', '/')
            $snapshot[$relative] = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
    }
    return $snapshot
}

function Invoke-ExchangeTool {
    param([string]$Path, [string[]]$Arguments)
    if (-not [IO.File]::Exists($Path)) { throw "Required localization tool is missing: $Path" }
    $output = & $script:PowerShellPath -NoProfile -File $Path @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Localization tool failed ($LASTEXITCODE): $Path`n$($output -join "`n")" }
}

function Test-ExchangeBundle {
    param([string]$Tag)
    if ($Tag -cnotmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { throw 'Invalid locale.' }
    $bundle = Resolve-LocalizationPath -Root $OutputRoot -Relative $Tag
    foreach ($name in @('request', 'attestation')) {
        $path = Resolve-LocalizationPath -Root $bundle -Relative ($name + '.json')
        if (-not [IO.File]::Exists($path)) { throw "$Tag`: missing $name.json" }
        $shape = Test-ExchangeDocument -Path $path -SchemaName ('localization-' + $name)
        if (-not $shape.Ok) { throw $shape.Detail }
    }
    $request = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $bundle 'request.json')))
    $attestation = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $bundle 'attestation.json')))
    if ($request.locale -cne $Tag -or $attestation.locale -cne $Tag -or $request.sourceLocale -cne 'en-US') { throw 'Bundle locale/source identity differs from its requested locale.' }
    $digest = Get-LocalizationRequestDigest -Row @($request.rows) -Format $request.format
    if ($digest.sha256 -cne $request.requestDigest.sha256) { throw 'The returned request does not hash to the digest it carries; its rows were edited.' }
    $verdict = Test-LocalizationAttestation -Attestation $attestation -RequestSha256 $digest.sha256
    if (-not $verdict.Ok) { throw $verdict.Detail }
    $current = @(Get-LocalizationRow -Root $Root -ProjectRoot $ProjectRoot -Locale $Tag)
    $currentDigest = Get-LocalizationRequestDigest -Row $current -Format $request.format
    if ($currentDigest.sha256 -cne $digest.sha256) {
        $known = @{}; foreach ($row in $request.rows) { $known[[string]$row.id] = [string]$row.sourceSha256 }
        $moved = @($current | Where-Object { -not $known.ContainsKey([string]$_.id) -or $known[[string]$_.id] -cne [string]$_.sourceSha256 } | ForEach-Object id)
        throw "The English moved since this request was sent: $($moved -join ', '). Re-export the source-frozen delta; source drift cannot be approved by an import switch."
    }
    $answers = Read-LocalizationAnswer -BundleRoot $bundle
    if (-not $answers.Count) { throw 'The bundle carries no answer.' }
    foreach ($ruling in @($current | Where-Object kind -CEQ 'ruling')) {
        if ($answers.ContainsKey([string]$ruling.id) -and $answers[[string]$ruling.id] -cne 'preserve-exact-english') { throw "Retired-name ruling must explicitly retain preserve-exact-english: $($ruling.id)" }
    }
    $missing = @($current | Where-Object { -not $answers.ContainsKey([string]$_.id) } | ForEach-Object { $_.id })
    if ($RequireComplete -and $missing.Count) { throw "Incomplete accepted batch: $($missing -join ', ')" }
    return @{ tag = $Tag; request = $request; attestation = $attestation; rows = $current; answers = $answers; missing = $missing }
}

$originalRoot = $Root; $originalProject = $ProjectRoot
$transaction = $null
$transactionLock = $null
$preserveTransaction = $false
$applied = [Collections.Generic.List[object]]::new()
$createdDirectories = [Collections.Generic.List[string]]::new()
$report = [ordered]@{ schema = 'yuruna.localization-import/v1'; valid = $false; applied = $false; locales = @(); changedPaths = @(); validatedOutputs = @(); problems = @() }
try {
    foreach ($first in @($Root, $ProjectRoot)) {
        $other = if ($first -ceq $Root) { $ProjectRoot } else { $Root }
        $relative = [IO.Path]::GetRelativePath($first, $other)
        if ($relative -ceq '.' -or ($relative -cne '..' -and -not $relative.StartsWith('../') -and -not $relative.StartsWith('..\'))) { throw 'Framework and project roots must be separate trees.' }
        if ($ReportPath) {
            $relative = [IO.Path]::GetRelativePath($first, [IO.Path]::GetFullPath($ReportPath))
            if ($relative -cne '..' -and -not $relative.StartsWith('../') -and -not $relative.StartsWith('..\')) { throw 'ReportPath must be outside both source trees.' }
        }
    }
    if ($EnableLocale -and -not $RequireComplete) { throw 'EnableLocale requires RequireComplete.' }
    if ($AllowSourceDrift) { throw 'AllowSourceDrift cannot record an approval over changed source. Export a new source-frozen request.' }
    $tags = if ($Locale) { @($Locale) } elseif ([IO.Directory]::Exists($OutputRoot)) {
        @(Get-ChildItem -LiteralPath $OutputRoot -Directory | Sort-Object Name | ForEach-Object Name)
    } else { @() }
    if (-not $tags.Count) { throw "No returned bundle was found under $OutputRoot" }
    $bundles = @($tags | ForEach-Object { Test-ExchangeBundle -Tag $_ })
    foreach ($bundle in $bundles) {
        $report.locales += @{ locale = $bundle.tag; requestDigest = $bundle.request.requestDigest; acceptedRows = @($bundle.answers.Keys | Sort-Object); missingRows = $bundle.missing; translator = $bundle.attestation.translator; independentReviewer = $bundle.attestation.independentReviewer; format = $bundle.request.format }
    }
    # WhatIf and declined confirmation exit before temporary files or subprocesses.
    if (-not $ValidateOnly -and -not $PSCmdlet.ShouldProcess("$Root and $ProjectRoot", 'validate and atomically apply the accepted localization bundles')) {
        Write-Output 'Import-Localization: preview only; no files or subprocesses changed.'
        exit 0
    }
    if ($WhatIfPreference) { Write-Output 'Import-Localization: preview only; no files or subprocesses changed.'; exit 0 }
    $lockName = 'yuruna-localization-' + (Get-TextSha256 -Text ($Root + "`n" + $ProjectRoot)) + '.lock'
    $lockPath = Resolve-LocalizationPath -Root ([IO.Path]::GetTempPath()) -Relative $lockName
    try { $transactionLock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another localization import owns this source pair.' }
    $transaction = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-localization-' + [guid]::NewGuid().ToString('n'))
    [void][IO.Directory]::CreateDirectory($transaction)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($transaction, [IO.UnixFileMode]448) }
    $Root = Join-Path $transaction 'framework'; $ProjectRoot = Join-Path $transaction 'project'
    $pairs = @(@{ original = $originalRoot; stage = $Root; name = 'framework' }, @{ original = $originalProject; stage = $ProjectRoot; name = 'project' })
    foreach ($pair in $pairs) {
        $pair.before = Get-ExchangeSnapshot $pair.original
        [void][IO.Directory]::CreateDirectory($pair.stage)
        foreach ($relative in $pair.before.Keys) {
            $target = Resolve-LocalizationPath -Root $pair.stage -Relative $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
            [IO.File]::Copy((Join-Path $pair.original $relative), $target)
        }
    }
    $release = ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim()
    foreach ($bundle in $bundles) {
        $tag = $bundle.tag; $answers = $bundle.answers; $attestation = $bundle.attestation
        $termsPath = Join-Path $Root "globalization/terminology/$tag.terms.json"
        $stylePath = Join-Path $Root "globalization/terminology/$tag.style-guide.json"
        $terminology = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($termsPath))
        $style = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($stylePath))
        $null = Set-TermDecision -Terminology $terminology -Answer $answers -Confirm:$false
        $null = Set-StyleRule -Style $style -Answer $answers -Confirm:$false
        $termMissing = @($bundle.rows | Where-Object { $_.kind -in @('term', 'ruling') -and -not $answers.ContainsKey([string]$_.id) })
        $styleMissing = @($bundle.rows | Where-Object { $_.kind -ceq 'style-rule' -and -not $answers.ContainsKey([string]$_.id) })
        if ($termMissing.Count) { $terminology.status = 'draft'; $terminology.approvals = [pscustomobject]@{} }
        else { $terminology.status = 'approved'; $terminology.approvals = New-ApprovalRecord -Artifact $terminology -Kind terminology -Attestation $attestation -ReleaseVersion $release }
        Write-Utf8Json -Path $termsPath -Value $terminology
        $style.terminologySource.sha256 = (Get-FileHash -LiteralPath $termsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($termMissing.Count -or $styleMissing.Count) { $style.status = 'draft'; $style.approvals = [pscustomobject]@{} }
        else { $style.status = 'approved'; $style.approvals = New-ApprovalRecord -Artifact $style -Kind style-guide -Attestation $attestation -ReleaseVersion $release }
        Write-Utf8Json -Path $stylePath -Value $style
        $null = Write-TargetCatalog -Locale $tag -Answer $answers -Confirm:$false
        $documents = @(Write-TranslatedDocument -Locale $tag -Answer $answers -Confirm:$false)
        $null = Set-ProjectScalarReview -Locale $tag -Answer $answers -Attestation $attestation -Confirm:$false
        foreach ($document in $documents) {
            Invoke-ExchangeTool -Path (Join-Path $Root 'tools/Test-DocTranslation.ps1') -Arguments @('-Locale', $tag, '-ProjectRoot', $ProjectRoot, '-AcceptReview', '-Status', 'reviewed', '-Path', $document, '-Quiet', '-Confirm:$false')
        }
    }
    if ($EnableLocale) {
        $localePath = Join-Path $Root 'globalization/locale-manifest.json'
        $localeManifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($localePath))
        foreach ($bundle in $bundles) {
            $entry = $localeManifest.locales.($bundle.tag)
            if (-not $entry -or -not $entry.pluralRule -or -not @($entry.pluralCategories).Count) { throw 'EnableLocale requires an explicit plural rule and categories.' }
            $entry.status = 'supported'
        }
        Write-Utf8Json -Path $localePath -Value $localeManifest
    }
    # Validation uses the production compiler in the disposable tree. Its first
    # update may return 1 for regeneration; a following check must return zero.
    $compiler = Join-Path $Root 'tools/Invoke-CatalogCompile.ps1'
    if (-not [IO.File]::Exists($compiler)) { throw "Required production compiler is missing: $compiler" }
    $compilerOutput = & $script:PowerShellPath -NoProfile -File $compiler -Root (Join-Path $Root 'globalization') -Update -Quiet 2>&1
    if ($LASTEXITCODE -notin @(0, 1)) { throw "Compiler validation failed: $($compilerOutput -join "`n")" }
    Invoke-ExchangeTool -Path $compiler -Arguments @('-Root', (Join-Path $Root 'globalization'), '-Check', '-Quiet')
    Invoke-ExchangeTool -Path (Join-Path $Root 'tools/Invoke-ProjectLocaleMap.ps1') -Arguments @('-ProjectRoot', $ProjectRoot, '-Quiet')
    if (-not $NoPublish) {
        $publicationArguments = @('-Root', $Root, '-ProjectRoot', $ProjectRoot, '-Quiet', '-Confirm:$false')
        if ($DeferFullGate) { $publicationArguments += '-SkipGate' }
        Invoke-ExchangeTool -Path (Join-Path $Root 'tools/Publish-Localization.ps1') -Arguments $publicationArguments
    }
    $report['fullGateDeferred'] = [bool]$DeferFullGate

    $changes = [Collections.Generic.List[object]]::new()
    $validatedOutputs = [Collections.Generic.List[object]]::new()
    $acceptedPaths = @{ framework = @{}; project = @{} }
    foreach ($relative in @('globalization/locale-manifest.json', 'globalization/manifests/doc-translations.json', 'globalization/manifests/catalog-set.json', 'globalization/manifests/inventory.json')) { $acceptedPaths.framework[$relative] = $true }
    $acceptedPaths.project['globalization/project-locale-source-hashes.json'] = $true
    $documentManifest = Get-Content -LiteralPath (Join-Path $Root 'globalization/manifests/doc-translations.json') -Raw | ConvertFrom-Json
    foreach ($bundle in $bundles) {
        $tag = $bundle.tag
        foreach ($relative in @("globalization/terminology/$tag.terms.json", "globalization/terminology/$tag.style-guide.json")) { $acceptedPaths.framework[$relative] = $true }
        foreach ($document in @($documentManifest.documents | Where-Object locale -CEQ $tag)) {
            $repository = if ($document.repo -ceq 'yuruna') { 'framework' } else { 'project' }
            $acceptedPaths[$repository][[string]$document.translated] = $true
        }
        foreach ($row in @($bundle.rows | Where-Object kind -EQ 'project-scalar')) { $acceptedPaths.project[[string]$row.context] = $true }
    }
    foreach ($pair in $pairs) {
        $after = Get-ExchangeSnapshot $pair.stage
        $now = Get-ExchangeSnapshot $pair.original
        if ((ConvertTo-CanonicalApprovalJson $now) -cne (ConvertTo-CanonicalApprovalJson $pair.before)) { throw 'Source files changed during localization validation; nothing applied.' }
        foreach ($relative in @($after.Keys | Sort-Object)) {
            # Compiler validation outputs belong to the later publication step.
            if ($NoPublish -and ($relative -like 'globalization/generated/*' -or $relative -in @('globalization/manifests/inventory.json', 'globalization/manifests/catalog-set.json'))) { continue }
            $changed = -not $pair.before.ContainsKey($relative) -or $pair.before[$relative] -cne $after[$relative]
            $accepted = $acceptedPaths[$pair.name].ContainsKey($relative)
            if ($pair.name -eq 'framework') {
                if ($relative -like 'globalization/generated/*') { $accepted = $true }
                foreach ($bundle in $bundles) { if ($relative -like "globalization/catalogs/$($bundle.tag)/*") { $accepted = $true } }
            }
            if ($accepted -or $changed) { $validatedOutputs.Add(@{ repository = $pair.name; path = $relative; sha256 = ([string]$after[$relative]).ToLowerInvariant() }) }
            if (-not $changed) { continue }
            $changes.Add(@{ repository = $pair.name; path = $relative; original = Join-Path $pair.original $relative; staged = Join-Path $pair.stage $relative; existed = $pair.before.ContainsKey($relative) })
        }
    }
    $report.validatedOutputs = @($validatedOutputs.ToArray())
    $report.changedPaths = @($changes | ForEach-Object { @{ repository = $_.repository; path = $_.path; sha256 = (Get-FileHash -LiteralPath $_.staged -Algorithm SHA256).Hash.ToLowerInvariant() } })
    $report.valid = $true
    $report['source'] = @{ framework = @{ root = $originalRoot; contentSha256 = Get-TextSha256 (ConvertTo-CanonicalApprovalJson $pairs[0].before) }; project = @{ root = $originalProject; contentSha256 = Get-TextSha256 (ConvertTo-CanonicalApprovalJson $pairs[1].before) } }
    if (-not $ValidateOnly) {
        foreach ($change in $changes) {
            $backup = Join-Path $transaction ('backup/' + $change.repository + '/' + $change.path)
            $change.backup = $backup
            if ($change.existed) { [void][IO.Directory]::CreateDirectory((Split-Path -Parent $backup)); [IO.File]::Copy($change.original, $backup) }
        }
        Write-Utf8Json -Path (Join-Path $transaction 'transaction.json') -Value @{ schema = 'yuruna.localization-transaction/v1'; state = 'applying'; framework = $originalRoot; project = $originalProject; changes = $changes.ToArray() }
        $preserveTransaction = $true
        foreach ($change in $changes) {
            $parent = Split-Path -Parent $change.original
            $missingParents = [Collections.Generic.List[string]]::new()
            while (-not [IO.Directory]::Exists($parent)) { $missingParents.Add($parent); $parent = Split-Path -Parent $parent }
            for ($i = $missingParents.Count - 1; $i -ge 0; $i--) { [void][IO.Directory]::CreateDirectory($missingParents[$i]); $createdDirectories.Add($missingParents[$i]) }
            $applied.Add($change)
            [IO.File]::Copy($change.staged, $change.original, $true)
        }
        $report.applied = $true
        $preserveTransaction = $false
    }
    if ($ReportPath) { Write-Utf8Json -Path $ReportPath -Value $report }
    Write-Output ('Import-Localization: validated {0} bundle(s), {1} changed path(s), applied={2}.' -f $bundles.Count, $changes.Count, $report.applied)
    exit 0
} catch {
    for ($i = $applied.Count - 1; $i -ge 0; $i--) {
        $change = $applied[$i]
        if ($change.existed) { [IO.File]::Copy($change.backup, $change.original, $true) }
        elseif ([IO.File]::Exists($change.original)) { [IO.File]::Delete($change.original) }
    }
    for ($i = $createdDirectories.Count - 1; $i -ge 0; $i--) { [IO.Directory]::Delete($createdDirectories[$i], $false) }
    $preserveTransaction = $false
    $report.valid = $false; $report.applied = $false; $report.problems = @($_.Exception.Message)
    if ($ReportPath -and -not $WhatIfPreference) { Write-Utf8Json -Path $ReportPath -Value $report }
    Write-Warning $_.Exception.Message
    exit 2
} finally {
    if ($transactionLock) { $transactionLock.Dispose() }
    if ($transaction -and [IO.Directory]::Exists($transaction)) {
        if ($preserveTransaction) { Write-Warning "Interrupted rollback; preserve transaction backups and journal: $transaction" }
        else { Remove-Item -LiteralPath $transaction -Recurse -Force }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
