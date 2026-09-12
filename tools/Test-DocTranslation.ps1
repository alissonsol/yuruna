<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42f3b71a-0d5c-46e8-9c02-8a41de6b7f35
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate globalization documentation translation drift
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
    Map each English operator document to its translation, and report the
    ones whose English source has changed since the translation was accepted.
.DESCRIPTION
    A translated document is a copy of something that keeps moving. The
    English source is edited, the translation is not, and nothing about the
    translated file looks wrong -- it is still fluent, still well formed, and
    now describes a step that no longer exists. That failure is invisible to
    every other gate in this repository, which is what this one is for.

    The mapping is deterministic: a source path becomes its localized path by
    prefixing `docs/<locale>/` and dropping a leading `docs/` segment when the
    source already lives there. So `README.md` maps to `docs/pt-BR/README.md`,
    `install/README.md` to `docs/pt-BR/install/README.md`, and
    `docs/operator.md` to `docs/pt-BR/operator.md`. Two repositories are
    covered, because the operator subset spans this one and the sibling
    project.

    Each entry records the SHA-256 of the English source as it stood when the
    translation was last accepted, plus a status: `draft` for a machine or
    unreviewed translation, `reviewed` once a native reviewer has signed it
    off. A source edit makes exactly that one entry stale and leaves every
    other entry alone.

    Advancing a hash is deliberate. Only -AcceptReview rewrites it, because a
    hash that any ordinary run could refresh would silently bless a
    translation nobody re-read -- which is the whole failure this gate exists
    to prevent.

    Exit codes follow the entry-point contract:
        0  Every translation is present and current.
        1  A translation is missing, or its English source changed after the
           recorded hash, or -RequireReviewed was asked for and a draft
           remains.
        2  An English source named by the map does not exist, the sibling
           repository is absent, so the map could not be evaluated, or
           -AcceptReview -Status reviewed was asked for while the terminology
           and style-guide approvals that a review depends on are pending.

.PARAMETER Locale
    The translation locale to check. Default: pt-BR.
.PARAMETER Manifest
    Where the per-document record lives. Default:
    globalization/manifests/doc-translations.json.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree. Defaults to the sibling
    yuruna-project; the publisher passes its private-stripped staged checkout.
.PARAMETER RepairLinks
    Rewrite relative link destinations in the translated files so they
    resolve from their own location. A translation copied out of `docs/`
    into `docs/<locale>/` inherits links written for the original
    directory, and every one of them points at nothing until it is rebased.
.PARAMETER AcceptReview
    Record the current English sources as the reviewed baseline. Pass
    -Path to accept specific documents; without it, every document is
    accepted, which is rarely what a reviewer means.
.PARAMETER Status
    The status to record with -AcceptReview: `reviewed` (default) once a
    native reviewer has signed off, or `draft` when registering a machine
    translation that still needs review. `reviewed` is refused while the
    terminology and style-guide approvals are pending, because there is then no
    approved vocabulary a review could have been made against.
.PARAMETER Path
    Restrict the run to source paths matching these values. Wildcards allowed.
    A value may be qualified with its repository -- 'yuruna:README.md' -- which
    is required when accepting a review for a name both repositories carry.
.PARAMETER RequireReviewed
    Fail on any document still marked `draft`. This is the release-mode
    question -- a first draft is a starting point, not a shipped translation.
.PARAMETER Quiet
    Print only problems and the summary.

.EXAMPLE
    pwsh tools/Test-DocTranslation.ps1
    Reports missing and stale translations; exits 0 / 1.

.EXAMPLE
    pwsh tools/Test-DocTranslation.ps1 -AcceptReview -Path 'docs/operator.md'
    Records that document's English source as reviewed at its current content.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([string])]
param(
    [string]$Locale = 'pt-BR',
    [string]$Manifest,
    [string]$ProjectRoot,
    [switch]$AcceptReview,
    [switch]$RepairLinks,
    [ValidateSet('reviewed', 'draft')]
    [string]$Status = 'reviewed',
    [string[]]$Path,
    [switch]$RequireReviewed,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SiblingRoot = if ($ProjectRoot) { $ProjectRoot } else { Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }
if (-not $Manifest) { $Manifest = Join-Path $RepoRoot 'globalization/manifests/doc-translations.json' }

# The operator subset. Each entry names the repository that owns the document,
# because the subset deliberately spans both and a drift gate that saw only
# one of them would report a clean tree while half the set rotted.
$Document = @(
    @{ Repo = 'yuruna'; Source = 'README.md' }
    @{ Repo = 'yuruna'; Source = 'install/README.md' }
    @{ Repo = 'yuruna'; Source = 'docs/operator.md' }
    @{ Repo = 'yuruna'; Source = 'docs/lab-operator.md' }
    @{ Repo = 'yuruna'; Source = 'docs/install.md' }
    @{ Repo = 'yuruna'; Source = 'docs/kubernetes.md' }
    @{ Repo = 'yuruna'; Source = 'docs/authentication.md' }
    @{ Repo = 'yuruna'; Source = 'docs/workarounds.md' }
    @{ Repo = 'yuruna-project'; Source = 'README.md' }
    @{ Repo = 'yuruna-project'; Source = 'template/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/website/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/text-to-sql/README.md' }
)

function Get-RepoRootFor {
    param([Parameter(Mandatory)][string]$Repo)
    if ($Repo -eq 'yuruna') { return $RepoRoot }
    return $SiblingRoot
}

# docs/operator.md -> docs/<locale>/operator.md; README.md -> docs/<locale>/README.md.
function Get-TranslatedPath {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Tag)
    $rest = $Source
    if ($rest.StartsWith('docs/')) { $rest = $rest.Substring(5) }
    return "docs/$Tag/$rest"
}

# A relative link in the English source is written from the source's own
# directory. The translation sits somewhere else -- `docs/<locale>/` and
# possibly deeper -- so copying the destination verbatim points it at nothing.
# Rewriting it against the translation's location makes it resolve to the same
# file the English link meant. Absolute URLs and bare fragments are already
# location-independent and are left alone.
function Get-RepairedLink {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$TranslatedDir
    )

    if ($Destination -match '^(https?:|mailto:|#|/)') { return $Destination }

    $fragment = ''
    $file = $Destination
    $hash = $Destination.IndexOf('#')
    if ($hash -ge 0) { $file = $Destination.Substring(0, $hash); $fragment = $Destination.Substring($hash) }
    if (-not $file) { return $Destination }

    $target = [IO.Path]::GetFullPath([IO.Path]::Combine($SourceDir, $file))
    $rebased = [IO.Path]::GetRelativePath($TranslatedDir, $target) -replace '\\', '/'
    return "$rebased$fragment"
}

function Get-LinkFinding {
    param([Parameter(Mandatory)][string]$TranslatedFull, [Parameter(Mandatory)][string]$Label)

    $findings = [Collections.Generic.List[string]]::new()
    $dir = Split-Path -Parent $TranslatedFull
    $text = [IO.File]::ReadAllText($TranslatedFull)
    foreach ($m in [regex]::Matches($text, '\]\(([^)\s]+)(?:\s+"[^"]*")?\)')) {
        $dest = $m.Groups[1].Value
        if ($dest -match '^(https?:|mailto:|#|/)') { continue }
        $file = ($dest -split '#')[0]
        if (-not $file) { continue }
        $resolved = [IO.Path]::GetFullPath([IO.Path]::Combine($dir, $file))
        if (-not (Test-Path -LiteralPath $resolved)) {
            $findings.Add("$Label links to '$dest', which does not resolve from the translation's location")
        }
    }
    return , $findings
}

function Get-Sha256File {
    param([Parameter(Mandatory)][string]$FullPath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [IO.File]::ReadAllBytes($FullPath)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

if (-not (Test-Path -LiteralPath $SiblingRoot -PathType Container)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "The sibling repository is not beside this one: $SiblingRoot. Five of the thirteen documents live there, so the map cannot be evaluated."
    exit 2
}

# `reviewed` means a native reviewer signed the translation off against an
# approved glossary and style guide. Without those approvals there is no agreed
# vocabulary to have reviewed it against, so the status would record a review
# that could not have happened -- and the recorded state is what every later
# handoff and release claim reads. Refuse it here, at the only place that writes
# the status, rather than leaving the contradiction to be discovered downstream.
# The approval predicate is not restated: Test-Terminology.ps1 owns it, so the
# two cannot drift into disagreeing about what "approved" means.
if ($AcceptReview -and $Status -eq 'reviewed') {
    $terminologyScript = Join-Path $PSScriptRoot 'Test-Terminology.ps1'
    $terminologyOutput = & pwsh -NoProfile -File $terminologyScript -RequireApproved -Quiet 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $ErrorActionPreference = 'Continue'
        # One exit code covers two states that need opposite work. A signature is
        # genuinely missing, or every signature is on file and a pinned source
        # moved underneath them. Only the first is answered by collecting
        # approvals; sending a reader after a role nobody is waiting on costs
        # them the search before they find the pin. The gate names the first
        # case in its own words, so read that rather than guessing from the code.
        $pendingApproval = $terminologyOutput -match 'baseline approval is incomplete'
        if ($pendingApproval) {
            Write-Error ("Terminology and style-guide approval is incomplete, so no document may be recorded as reviewed. " +
                "Run 'pwsh -NoProfile -File tools/Test-Terminology.ps1 -RequireApproved' for the pending roles, obtain the " +
                "native translator and independent reviewer approvals, then rerun this command. To register an unreviewed " +
                "translation meanwhile, pass -Status draft.")
        } else {
            Write-Error ("The terminology gate is not passing, so no document may be recorded as reviewed. No approval is " +
                "missing: a pinned source moved, and the pin is part of the approved content, so the approvals already on " +
                "file have to be renewed over the bytes that moved before any document can be recorded. Run " +
                "'pwsh -NoProfile -File tools/Test-Terminology.ps1' to see which pin drifted. To register an unreviewed " +
                "translation meanwhile, pass -Status draft.")
        }
        exit 2
    }
}

$record = @{}
if (Test-Path -LiteralPath $Manifest -PathType Leaf) {
    $loaded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Manifest))
    foreach ($e in @($loaded.documents)) { $record["$($e.repo)|$($e.source)|$($e.locale)"] = $e }
}

$selected = $Document
if ($Path -and $Path.Count -gt 0) {
    # A pattern may name its repository -- 'yuruna:README.md' -- because both
    # repositories have a README.md and a bare name selects them both. Accepting
    # a document review is the one operation where that matters: an operator
    # answering for one file would otherwise promote a translation in the other
    # that nobody read.
    $selected = $Document | Where-Object {
        $source = $_.Source
        $repo = $_.Repo
        @($Path | Where-Object {
            $pattern = [string]$_
            if ($pattern -match '^(?<repo>[A-Za-z0-9_.-]+):(?<source>.+)$') {
                $repo -ceq $Matches['repo'] -and $source -like $Matches['source']
            } else {
                $source -like $pattern
            }
        }).Count -gt 0
    }
    # A filter that selects nothing checked nothing. Reporting that as success
    # lets a caller that names one document -- a release close record asking
    # "is the first document reviewed?" -- pass on a typo, having proved
    # nothing at all.
    if (@($selected).Count -eq 0) {
        $ErrorActionPreference = 'Continue'
        Write-Error ("No mapped document matches: $($Path -join ', '). " +
            "The map names sources relative to their own repository, such as 'docs/operator.md', " +
            "and a name carried by both repositories can be qualified as 'yuruna:README.md'.")
        exit 2
    }
    # Accepting a review is per-document by design, so a bare name that reaches
    # two repositories has to be qualified rather than silently applied twice.
    if ($AcceptReview) {
        $ambiguous = @($selected | Group-Object Source | Where-Object { $_.Count -gt 1 })
        if ($ambiguous.Count -gt 0) {
            $ErrorActionPreference = 'Continue'
            Write-Error ("'$($ambiguous[0].Name)' names a document in more than one repository. " +
                "Qualify it, for example 'yuruna:$($ambiguous[0].Name)', so the review is recorded " +
                'against the translation that was actually read.')
            exit 2
        }
    }
}

$problem = [Collections.Generic.List[string]]::new()
$draft = [Collections.Generic.List[string]]::new()
$accepted = 0
$script:repairCount = 0

foreach ($doc in $selected) {
    $root = Get-RepoRootFor -Repo $doc.Repo
    $sourceFull = Join-Path $root ($doc.Source -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "English source named by the map is missing: $($doc.Repo)/$($doc.Source)"
        exit 2
    }

    $translatedRel = Get-TranslatedPath -Source $doc.Source -Tag $Locale
    $translatedFull = Join-Path $root ($translatedRel -replace '/', [IO.Path]::DirectorySeparatorChar)
    $currentHash = Get-Sha256File -FullPath $sourceFull
    $key = "$($doc.Repo)|$($doc.Source)|$Locale"
    $known = $record[$key]
    $label = "$($doc.Repo)/$($doc.Source)"

    if ($RepairLinks) {
        if (-not (Test-Path -LiteralPath $translatedFull -PathType Leaf)) {
            $problem.Add("$label has no $Locale translation at $translatedRel to repair")
            continue
        }
        $sourceDir = Split-Path -Parent $sourceFull
        $translatedDir = Split-Path -Parent $translatedFull
        $text = [IO.File]::ReadAllText($translatedFull)
        $changed = 0
        $rewritten = [regex]::Replace($text, '\]\(([^)\s]+)((?:\s+"[^"]*")?)\)', {
            param($m)
            $dest = $m.Groups[1].Value
            $title = $m.Groups[2].Value
            $fixed = Get-RepairedLink -Destination $dest -SourceDir $sourceDir -TranslatedDir $translatedDir
            if ($fixed -cne $dest) { $script:repairCount++ ; $changed++ }
            "]($fixed$title)"
        })
        if ($rewritten -cne $text) {
            if ($PSCmdlet.ShouldProcess($translatedRel, 'rebase relative links')) {
                [IO.File]::WriteAllText($translatedFull, $rewritten, [Text.UTF8Encoding]::new($false))
                $accepted++
                if (-not $Quiet) { Write-Output "REPAIR $label -> $translatedRel" }
            }
        } elseif (-not $Quiet) {
            Write-Output "ok     $label (no link needed rebasing)"
        }
        continue
    }

    if ($AcceptReview) {
        if (-not (Test-Path -LiteralPath $translatedFull -PathType Leaf)) {
            $problem.Add("$label has no $Locale translation at $translatedRel, so there is nothing to accept")
            continue
        }
        # The same link check the read path runs, before the record is written
        # rather than after. Accepting first would file a translation whose
        # relative links resolve to nothing, and the breakage would then surface
        # on some later unrelated run against a record that already claims the
        # document was read.
        # Enumerated the same way the read path enumerates it: the helper returns
        # its list as one object, so wrapping the call in @() would yield a
        # one-element array holding an empty list rather than no findings.
        $linkFinding = [Collections.Generic.List[string]]::new()
        foreach ($f in (Get-LinkFinding -TranslatedFull $translatedFull -Label $label)) { $linkFinding.Add($f) }
        if ($linkFinding.Count -gt 0) {
            foreach ($f in $linkFinding) { $problem.Add($f) }
            continue
        }
        if ($PSCmdlet.ShouldProcess($label, "record as $Status at the current source")) {
            $record[$key] = [ordered]@{
                repo = $doc.Repo; source = $doc.Source; locale = $Locale
                translated = $translatedRel; sourceHash = $currentHash; status = $Status
            }
            $accepted++
            if (-not $Quiet) { Write-Output "ACCEPT $label -> $Status" }
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $translatedFull -PathType Leaf)) {
        $problem.Add("$label has no $Locale translation at $translatedRel")
        continue
    }
    if (-not $known) {
        $problem.Add("$label has a $Locale translation that no reviewer has ever accepted; run -AcceptReview -Status draft to register it")
        continue
    }
    if ($known.sourceHash -cne $currentHash) {
        $problem.Add("$label changed since its $Locale translation was accepted; re-review $translatedRel")
        continue
    }
    foreach ($f in (Get-LinkFinding -TranslatedFull $translatedFull -Label $label)) { $problem.Add($f) }
    if ($known.status -ne 'reviewed') {
        $draft.Add("$label is a $($known.status), pending native review")
    }
    if (-not $Quiet) { Write-Output "ok     $label ($($known.status))" }
}

if ($RepairLinks) {
    foreach ($p in $problem) { Write-Output "  $p" }
    Write-Output ''
    Write-Output "Rebased $script:repairCount link(s) across $accepted file(s); $($problem.Count) problem(s)."
    if ($problem.Count -gt 0) { exit 1 }
    exit 0
}

if ($AcceptReview) {
    foreach ($p in $problem) { Write-Output "  $p" }
    if ($accepted -gt 0) {
        $ordered = @($record.Values | Sort-Object { $_.repo }, { $_.source }, { $_.locale })
        $json = ([ordered]@{
            schema    = 'yuruna.doc-translations/v1'
            documents = $ordered
        } | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd() + "`n"
        $dir = Split-Path -Parent $Manifest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($Manifest, $json, [Text.UTF8Encoding]::new($false))
    }
    Write-Output ''
    Write-Output "Recorded $accepted document(s) as $Status; $($problem.Count) could not be accepted."
    if ($problem.Count -gt 0) { exit 1 }
    exit 0
}

foreach ($p in $problem) { Write-Output "  $p" }
foreach ($d in $draft) { Write-Output "  $d" }

Write-Output ''
Write-Output ("Test-DocTranslation [{0}]: {1} document(s), {2} problem(s), {3} awaiting review." -f
    $Locale, @($selected).Count, $problem.Count, $draft.Count)

if ($problem.Count -gt 0) { exit 1 }
if ($RequireReviewed -and $draft.Count -gt 0) { exit 1 }
exit 0
