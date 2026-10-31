<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42ab6d19-74c3-4f80-9e25-3d0c81af57b6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization documentation anchors identity generate
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
    Give every documentation heading a permanent, language-neutral anchor
    id, and record what each id points at.
.DESCRIPTION
    A heading slug is not an address. It is derived from the words in the
    heading, so it changes when the heading is reworded, and it changes
    completely when the heading is translated -- which means a link written
    against the English text finds nothing in the Portuguese file and, worse,
    says nothing about it: a fragment that matches no element scrolls to the
    top of the document in silence.

    So each heading gets an id that is not derived from its words:

        <a id="42f31111-0111"></a>

        ## Section A: Quickstart

    The left half names the file, the right half names the heading within it.
    Both are opaque on purpose. The same id is injected above the same
    heading in every translation of that document, so one link resolves in
    every language, and rewording a heading -- in any language -- does not
    move it.

    THE DOCUMENT IS THE REGISTRY. An id, once written above a heading, is
    read back on the next run and kept. That is what makes it permanent
    through a rename, a reorder, or an insertion: the id travels with the
    heading because it is stored next to it, not computed from it. Only a
    heading with no id gets one, and the ids already used in that file are
    never reissued.

    The generated manifest is an index, not the source of truth. It exists so
    a reader can find out what an opaque id points at, and so the link
    redirector can resolve an id to a file in a chosen language.

    Translations are matched to their source by heading ORDER, and a
    mismatch in heading count is refused rather than guessed at: pairing the
    wrong heading would attach an id to the wrong section, which is worse
    than having no id at all.

    Exit codes follow the entry-point contract:
        0  Every heading has its id and the manifest is current.
        1  A heading is missing an id, or the manifest is stale (-Check), or
           files were rewritten (-Update).
        2  A translation's heading count does not match its source, or an id
           collision makes the mapping ambiguous.

.PARAMETER Check
    Report what is missing or stale without writing. The default.
.PARAMETER Update
    Inject the missing anchors and rewrite the manifest.
.PARAMETER Path
    Restrict the run to source paths matching these values. Wildcards allowed.
.PARAMETER Manifest
    Where the index lives. Default globalization/manifests/doc-anchors.json.
.PARAMETER Quiet
    Print only problems and the summary.
.PARAMETER HeadingRegion
    Also report each heading whose source pointer sits in a region the heading
    does not name. A heading names its home either as `## <path>: <region>` or
    as a heading followed by a backticked `<repo>/<path>` line; a pointer is
    judged only when it sits in the comment block directly under a named
    `--- REGION:` marker. The report does not change the exit code.

.EXAMPLE
    pwsh tools/Invoke-DocAnchor.ps1 -Update
    Injects anchors into every registered document and its translations.
.EXAMPLE
    pwsh tools/Invoke-DocAnchor.ps1 -Check -HeadingRegion -Path docs/framework-implementation-notes.md
    Lists the implementation-note headings that name a region other than the
    one their pointer sits in.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [switch]$Check,
    [switch]$Update,
    [string[]]$Path,
    [string]$Manifest,
    [switch]$Quiet,
    [switch]$HeadingRegion
)

Import-Module (Join-Path $PSScriptRoot '../test/modules/Test.Prelude.psm1') -DisableNameChecking

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$SiblingRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project'
if (-not $Manifest) { $Manifest = Join-Path $RepoRoot 'globalization/manifests/doc-anchors.json' }
if (-not $Update) { $Check = $true }

$AnchorPattern = '^<a id="(42[0-9a-f]{6})-([0-9a-f]{4})"></a>\r?$'

function Get-RepoRootFor {
    param([Parameter(Mandatory)][string]$Repo)
    if ($Repo -eq 'yuruna') { return $RepoRoot }
    return $SiblingRoot
}

# Every documentation file that can be linked into, plus the ones outside
# docs/ that already have translations. A file with no id cannot be a link
# target in any language but English.
#
# Individual design records remain outside this registry. The design
# overview and the ontology guide are enrolled explicitly because their
# published links need stable heading addresses; the other records remain
# unchanged.
function Get-SourceDocument {
    $list = [Collections.Generic.List[hashtable]]::new()
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'docs') -Filter '*.md' -File | Sort-Object Name)) {
        $list.Add(@{ Repo = 'yuruna'; Source = "docs/$($f.Name)" })
    }
    foreach ($extra in @('README.md', 'install/README.md', 'docs/design/README.md', 'docs/ontology/README.md',
                         'docs/ontology/2026/10/README.md')) {
        $list.Add(@{ Repo = 'yuruna'; Source = $extra })
    }
    foreach ($extra in @('README.md', 'template/README.md', 'example/README.md',
                         'example/website/README.md', 'example/text-to-sql/README.md',
                         'example/website/components/frontend/website/README.md', 'docs/globalization.md')) {
        $list.Add(@{ Repo = 'yuruna-project'; Source = $extra })
    }
    # The complete SBOM subtree is exempt from globalization and localization,
    # including anchor registration if another document is added here later.
    return , @($list | Where-Object { $_.Source -notmatch '^docs/sbom/' })
}

# docs/operator.md -> docs/<locale>/operator.md. Dropping the leading docs/
# segment keeps the common case readable, but it is not injective on its own:
# README.md and docs/README.md would both land on docs/<locale>/README.md and
# one document would be paired against the other's translation. So a path
# already claimed by an earlier document falls back to mirroring the source
# in full, which cannot collide. Claims are made in a fixed order, so the
# answer is the same on every run.
function Get-TranslatedPath {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][hashtable]$Claimed,
        [Parameter(Mandatory)][string]$Repo
    )
    $short = $Source
    if ($short.StartsWith('docs/')) { $short = $short.Substring(5) }
    $candidate = "docs/$Tag/$short"
    $key = "$Repo|$candidate"
    if (-not $Claimed.ContainsKey($key) -or $Claimed[$key] -eq $Source) {
        $Claimed[$key] = $Source
        return $candidate
    }
    $mirrored = "docs/$Tag/$Source"
    $Claimed["$Repo|$mirrored"] = $Source
    return $mirrored
}

# Heading lines, ignoring anything inside a fenced block: a shell comment in
# a code sample looks exactly like a heading and is not one.
function Get-HeadingIndex {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line)

    $indices = [Collections.Generic.List[int]]::new()
    $inFence = $false
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -match '^\s*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($Line[$i] -match '^#{1,6}\s+\S') { $indices.Add($i) }
    }
    return , $indices
}

# Existing anchors normally precede their heading. A document may put its
# title anchor immediately below the first H1 so its first visible line and
# first source line are both the title.
function Get-ExistingAnchor {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line, [Parameter(Mandatory)][int]$HeadingIndex)

    $probe = $HeadingIndex - 1
    # Legacy heading aliases can sit between the stable id and its heading.
    # Skip only blank lines and standalone aliases, never intervening content.
    while ($probe -ge 0) {
        if ($Line[$probe] -match $AnchorPattern) {
            return @{ Index = $probe; File = $Matches[1]; Anchor = $Matches[2] }
        }
        if ($Line[$probe].Trim() -ne '' -and
            $Line[$probe] -notmatch '^\s*<a id="[^"<>]+"></a>\s*$') { break }
        $probe--
    }
    if ($HeadingIndex -eq 0 -and $Line[0] -match '^#\s+\S') {
        $probe = 1
        while ($probe -lt $Line.Count -and $Line[$probe].Trim() -eq '') { $probe++ }
        if ($probe -lt $Line.Count -and $Line[$probe] -match $AnchorPattern) {
            $fileId = $Matches[1]
            $anchorId = $Matches[2]
            $after = $probe + 1
            while ($after -lt $Line.Count -and ($Line[$after].Trim() -eq '' -or
                    $Line[$after] -match '^\s*<a id="[^"<>]+"></a>\s*$')) { $after++ }
            # An anchor immediately before another heading belongs to that
            # heading, even when the document has no introduction.
            if ($after -eq $Line.Count -or $Line[$after] -notmatch '^#{1,6}\s+\S') {
                return @{ Index = $probe; File = $fileId; Anchor = $anchorId }
            }
        }
    }
    return $null
}

function Get-Sha256Text {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

# GitHub's slug, kept only so the manifest can show what a heading looked
# like. Nothing resolves through it.
function Get-HeadingSlug {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)
    return (Get-GitHubHeadingSlug -Heading $Heading)
}

# Inject the given ids above the headings that lack one, leaving every other
# byte of the file alone.
function Get-AnchoredText {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line,
        [Parameter(Mandatory)][int[]]$HeadingIndex,
        [Parameter(Mandatory)][hashtable]$IdByHeadingIndex
    )

    $out = [Collections.Generic.List[string]]::new()
    $inject = @{}
    foreach ($i in $HeadingIndex) { if ($IdByHeadingIndex.ContainsKey($i)) { $inject[$i] = $IdByHeadingIndex[$i] } }

    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($inject.ContainsKey($i)) {
            # A blank line before the anchor keeps it its own paragraph, which
            # is what makes the rendered id addressable.
            if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -ne '') { $out.Add('') }
            $out.Add('<a id="' + $inject[$i] + '"></a>')
            $out.Add('')
        }
        $out.Add($Line[$i])
    }
    return ($out -join "`n")
}

# --- REGION: Heading homes
# Implementation-note headings say where the code they explain lives, and the
# code points back with a link under a REGION marker. When the code is
# reorganized the pointer moves with its block and the heading keeps the old
# region's name, so the reader lands on a section titled for code that is
# elsewhere. Only a pointer directly under a named marker is judged: a pointer
# inside a function body, or under a marker that is itself a link, says
# nothing about which region a heading should name.
$RegionMarkerPattern = '^\s*(?:#|//|--|;|<!--|/\*|\*)\s*--- REGION:\s*(.+?)\s*(?:-->|\*/)?\s*$'
$CommentLinePattern = '^\s*(?:#|//|--|;|<!--|<#|/\*|\*)'

function Get-HeadingHome {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line, [Parameter(Mandatory)][int]$HeadingIndex)

    $text = ($Line[$HeadingIndex] -replace '^#{1,6}\s+', '').Trim()
    if ($text -match '^(?<path>[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+|[A-Za-z0-9_-]+\.[A-Za-z0-9]+):\s+(?<name>\S.*)$') {
        return @{ Repo = $null; Path = $Matches['path']; Name = $Matches['name'].Trim() }
    }
    for ($i = $HeadingIndex + 1; $i -lt $Line.Count -and $i -le $HeadingIndex + 4; $i++) {
        $candidate = $Line[$i].Trim()
        if ($candidate -eq '') { continue }
        if ($candidate -match '^`(?<repo>yuruna(?:-project)?)/(?<path>[^`\s]+)`$') {
            return @{ Repo = $Matches['repo']; Path = $Matches['path']; Name = $text }
        }
        break
    }
    return $null
}

function Get-PointerRegion {
    param([Parameter(Mandatory)][AllowEmptyString()][string[]]$Line, [Parameter(Mandatory)][int]$Index)

    if ($Line[$Index] -notmatch $CommentLinePattern) { return $null }
    for ($i = $Index - 1; $i -ge 0; $i--) {
        if ($Line[$i] -match $RegionMarkerPattern) {
            $name = $Matches[1]
            if ($name -match '^https://yuruna\.link/') { return $null }
            return $name
        }
        if ($Line[$i].Trim() -eq '' -or $Line[$i] -notmatch $CommentLinePattern) { return $null }
    }
    return $null
}

function Find-HeadingRegionMismatch {
    # A section cited from regions in several places (one rationale shared by a
    # family of scripts) cannot name them all, so only an id whose judged
    # pointers agree on one file and region is held to its heading.
    param(
        [Parameter(Mandatory)][hashtable]$HomeById,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pointer
    )
    $homesById = @{}
    foreach ($p in $Pointer) {
        if (-not $homesById.ContainsKey($p.Id)) { $homesById[$p.Id] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        [void]$homesById[$p.Id].Add("$($p.Repo)|$($p.Path)|$($p.Region)")
    }
    foreach ($p in $Pointer) {
        if (-not $HomeById.ContainsKey($p.Id) -or $homesById[$p.Id].Count -gt 1) { continue }
        $headingHome = $HomeById[$p.Id]
        $repo = if ($headingHome.Repo) { $headingHome.Repo } else { $headingHome.DocRepo }
        if ($p.Repo -eq $repo -and $p.Path -eq $headingHome.Path -and $p.Region -ceq $headingHome.Name) { continue }
        [pscustomobject]@{
            Id = $p.Id; Label = $headingHome.Label; Heading = $headingHome.Heading
            Pointer = "$($p.Repo)/$($p.Path):$($p.Line)"; Region = $p.Region
        }
    }
}

function Get-RegionPointer {
    param([Parameter(Mandatory)][hashtable]$Root)

    $pointerPattern = [regex]'yuruna\.link/(42[0-9a-f]{6}-[0-9a-f]{4})'
    foreach ($repo in $Root.Keys) {
        $listing = & git -C $Root[$repo] ls-files -co --exclude-standard 2>$null
        if ($LASTEXITCODE -ne 0) { continue }
        foreach ($rel in $listing) {
            if (-not $rel -or $rel -match '\.(png|jpg|jpeg|gif|ico|pdf|zip|gz|tgz|iso|woff2?|ttf|pfx|der)$') { continue }
            $full = Join-Path $Root[$repo] $rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = $null
            try { $text = [IO.File]::ReadAllText($full) } catch { continue }
            if ($text.IndexOf([char]0) -ge 0 -or $text.IndexOf('yuruna.link/42') -lt 0) { continue }
            $lines = $text -split "`r?`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                foreach ($m in $pointerPattern.Matches($lines[$i])) {
                    $region = Get-PointerRegion -Line $lines -Index $i
                    if ($null -eq $region) { continue }
                    [pscustomobject]@{ Id = $m.Groups[1].Value; Repo = $repo; Path = $rel; Line = $i + 1; Region = $region }
                }
            }
        }
    }
}

# --- REGION: Main
try {

$existingManifest = @{}
if (Test-Path -LiteralPath $Manifest -PathType Leaf) {
    $loaded = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Manifest))
    foreach ($f in @($loaded.files)) {
        # Do not preserve old registrations for the excluded SBOM subtree.
        if ($f.source -match '^docs/sbom/') { continue }
        $existingManifest["$($f.repo)|$($f.source)"] = $f
    }
}

$documents = Get-SourceDocument
if ($Path -and $Path.Count -gt 0) {
    $documents = $documents | Where-Object {
        $candidate = $_.Source
        @($Path | Where-Object { $candidate -like $_ }).Count -gt 0
    }
}

$problem = [Collections.Generic.List[string]]::new()
$fileIdSeen = @{}
# Seed the claims from the translation gate's own record, so a document that
# already HAS a translation keeps the path that translation actually lives at.
# Without this the claim order decides ownership, and a document processed
# earlier can take a path that belongs to a translation someone already wrote.
$claimedPath = @{}
$translationManifest = Join-Path $RepoRoot 'globalization/manifests/doc-translations.json'
if (Test-Path -LiteralPath $translationManifest -PathType Leaf) {
    $known = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($translationManifest))
    foreach ($e in @($known.documents)) {
        $claimedPath["$($e.repo)|$($e.translated)"] = $e.source
    }
}
$manifestFiles = [Collections.Generic.List[object]]::new()
$written = 0
$injected = 0
$homeById = @{}

foreach ($doc in $documents) {
    $root = Get-RepoRootFor -Repo $doc.Repo
    $sourceFull = Join-Path $root ($doc.Source -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) { continue }
    $label = "$($doc.Repo)/$($doc.Source)"

    # A file keeps the id it was first given; a new file derives one from its
    # path and then keeps that.
    $key = "$($doc.Repo)|$($doc.Source)"
    $fileId = $null
    if ($existingManifest.ContainsKey($key)) { $fileId = [string]$existingManifest[$key].id }
    if (-not $fileId) { $fileId = '42' + (Get-Sha256Text -Text $key).Substring(0, 6) }
    if ($fileIdSeen.ContainsKey($fileId)) {
        $problem.Add("$label and $($fileIdSeen[$fileId]) both claim file id $fileId")
        continue
    }
    $fileIdSeen[$fileId] = $label

    $text = [IO.File]::ReadAllText($sourceFull)
    $lines = $text -split "`n"
    $headings = Get-HeadingIndex -Line $lines

    # Ids already written into this file are kept and never reissued.
    #
    # An id stays retired once issued, even after the heading it named is
    # deleted. Seeding this only from the ids currently in the file would free
    # the deleted one and hand it to the next new heading, and every published
    # link to it would then land on unrelated text -- silently, because the
    # link still resolves. The manifest records what has ever been issued for
    # this file, so it is read back here too and those suffixes stay spent.
    $used = [Collections.Generic.HashSet[string]]::new()
    if ($existingManifest.ContainsKey($key)) {
        foreach ($pastId in @($existingManifest[$key].anchors.id) + @($existingManifest[$key].retiredAnchorIds)) {
            $suffix = ([string]$pastId) -replace '^42[0-9a-f]{6}-', ''
            if ($suffix) { [void]$used.Add($suffix) }
        }
    }
    $idByHeading = @{}
    $explicitAnchorLines = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    $needing = [Collections.Generic.List[int]]::new()
    foreach ($h in $headings) {
        $existing = Get-ExistingAnchor -Line $lines -HeadingIndex $h
        if ($existing) {
            $explicitId = "$($existing.File)-$($existing.Anchor)"
            if ($explicitAnchorLines.ContainsKey($explicitId)) {
                throw "$label headings at lines $($explicitAnchorLines[$explicitId]) and $($h + 1) repeat explicit anchor id $explicitId"
            }
            $explicitAnchorLines[$explicitId] = $h + 1
            if ($existing.File -ne $fileId) {
                $problem.Add("$label heading at line $($h + 1) carries an id for a different file ($($existing.File))")
            }
            [void]$used.Add($existing.Anchor)
            $idByHeading[$h] = "$fileId-$($existing.Anchor)"
        } else {
            $needing.Add($h)
        }
    }

    $next = 1
    $toInject = @{}
    foreach ($h in $needing) {
        while ($used.Contains(('{0:x4}' -f $next))) { $next++ }
        $anchor = '{0:x4}' -f $next
        [void]$used.Add($anchor)
        $toInject[$h] = "$fileId-$anchor"
        $idByHeading[$h] = "$fileId-$anchor"
        $next++
    }

    if ($toInject.Count -gt 0) {
        $injected += $toInject.Count
        if ($Update) {
            $newText = Get-AnchoredText -Line $lines -HeadingIndex $headings -IdByHeadingIndex $toInject
            [IO.File]::WriteAllText($sourceFull, $newText, [Text.UTF8Encoding]::new($false))
            $written++
            if (-not $Quiet) { Write-Output "ANCHOR $label (+$($toInject.Count))" }
            $lines = $newText -split "`n"
            $headings = Get-HeadingIndex -Line $lines
            # Re-read the ids from the rewritten file so the manifest records
            # what is actually on disk.
            $idByHeading = @{}
            foreach ($h in $headings) {
                $e = Get-ExistingAnchor -Line $lines -HeadingIndex $h
                if ($e) { $idByHeading[$h] = "$($e.File)-$($e.Anchor)" }
            }
        } else {
            $problem.Add("$label has $($toInject.Count) heading(s) with no anchor id")
        }
    } elseif (-not $Quiet) {
        Write-Output "ok     $label"
    }

    $anchorRows = [Collections.Generic.List[object]]::new()
    foreach ($h in $headings) {
        if (-not $idByHeading.ContainsKey($h)) { continue }
        $anchorRows.Add([ordered]@{
            id      = $idByHeading[$h]
            heading = ($lines[$h] -replace '^#{1,6}\s+', '').Trim()
            slug    = Get-HeadingSlug -Heading $lines[$h]
        })
        if ($HeadingRegion) {
            $headingHome = Get-HeadingHome -Line $lines -HeadingIndex $h
            if ($headingHome) {
                $headingHome.DocRepo = $doc.Repo
                $headingHome.Label = $label
                $headingHome.Heading = ($lines[$h] -replace '^#{1,6}\s+', '').Trim()
                $homeById[$idByHeading[$h]] = $headingHome
            }
        }
    }

    # Translations take the SAME ids, paired by heading order. A count
    # mismatch means the pairing would be wrong somewhere, and a wrong id is
    # worse than none.
    $translations = [ordered]@{}
    foreach ($tag in @('pt-BR')) {
        $tRel = Get-TranslatedPath -Source $doc.Source -Tag $tag -Claimed $claimedPath -Repo $doc.Repo
        $tFull = Join-Path $root ($tRel -replace '/', [IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $tFull -PathType Leaf)) { continue }
        $translations[$tag] = $tRel

        $tText = [IO.File]::ReadAllText($tFull)
        $tLines = $tText -split "`n"
        $tHeadings = Get-HeadingIndex -Line $tLines
        if ($tHeadings.Count -ne $headings.Count) {
            $problem.Add("$tRel has $($tHeadings.Count) heading(s) but its source has $($headings.Count); the pairing would be wrong")
            continue
        }

        $tInject = @{}
        $tExplicitAnchorLines = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        for ($k = 0; $k -lt $tHeadings.Count; $k++) {
            $want = $idByHeading[$headings[$k]]
            if (-not $want) { continue }
            $e = Get-ExistingAnchor -Line $tLines -HeadingIndex $tHeadings[$k]
            if ($e) {
                $explicitId = "$($e.File)-$($e.Anchor)"
                if ($tExplicitAnchorLines.ContainsKey($explicitId)) {
                    throw "$tRel headings at lines $($tExplicitAnchorLines[$explicitId]) and $($tHeadings[$k] + 1) repeat explicit anchor id $explicitId"
                }
                $tExplicitAnchorLines[$explicitId] = $tHeadings[$k] + 1
                if ("$($e.File)-$($e.Anchor)" -ne $want) {
                    $problem.Add("$tRel heading $($k + 1) carries id $($e.File)-$($e.Anchor) but its source says $want")
                }
                continue
            }
            $tInject[$tHeadings[$k]] = $want
        }
        if ($tInject.Count -gt 0) {
            $injected += $tInject.Count
            if ($Update) {
                $newT = Get-AnchoredText -Line $tLines -HeadingIndex $tHeadings -IdByHeadingIndex $tInject
                [IO.File]::WriteAllText($tFull, $newT, [Text.UTF8Encoding]::new($false))
                $written++
                if (-not $Quiet) { Write-Output "ANCHOR $tRel (+$($tInject.Count))" }
            } else {
                $problem.Add("$tRel has $($tInject.Count) heading(s) with no anchor id")
            }
        }
    }

    $entry = [ordered]@{
        id           = $fileId
        repo         = $doc.Repo
        source       = $doc.Source
        translations = $translations
        anchors      = @($anchorRows)
    }
    $activeIds = @($anchorRows | ForEach-Object { $_.id })
    $retiredIds = @($used | ForEach-Object { "$fileId-$_" } | Where-Object { $_ -notin $activeIds } | Sort-Object)
    if ($retiredIds.Count -gt 0) { $entry.retiredAnchorIds = $retiredIds }
    $manifestFiles.Add($entry)
}

# A scoped run owns only the records it processed. Preserve records for
# filtered documents and unavailable sibling repositories, including retired ids.
$processedKeys = @{}
foreach ($entry in $manifestFiles) { $processedKeys["$($entry.repo)|$($entry.source)"] = $true }
foreach ($key in $existingManifest.Keys) {
    if (-not $processedKeys.ContainsKey($key)) { $manifestFiles.Add($existingManifest[$key]) }
}

$manifestJson = ([ordered]@{
    schema = 'yuruna.doc-anchors/v1'
    files  = @($manifestFiles | Sort-Object { $_.repo }, { $_.source })
} | ConvertTo-Json -Depth 8).Replace("`r`n", "`n").TrimEnd() + "`n"

$currentManifest = if (Test-Path -LiteralPath $Manifest -PathType Leaf) { [IO.File]::ReadAllText($Manifest) } else { $null }
if ($currentManifest -cne $manifestJson) {
    if ($Update) {
        $dir = Split-Path -Parent $Manifest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($Manifest, $manifestJson, [Text.UTF8Encoding]::new($false))
        $written++
        if (-not $Quiet) { Write-Output "WROTE  $([IO.Path]::GetRelativePath($RepoRoot, $Manifest) -replace '\\', '/')" }
    } else {
        $problem.Add('the anchor manifest is stale')
    }
}

} catch {
    $ErrorActionPreference = 'Continue'
    Write-Error $_.Exception.Message
    exit 2
}

foreach ($p in $problem) { Write-Output "  $p" }
if ($HeadingRegion) {
    $pointerRoot = @{ 'yuruna' = $RepoRoot }
    if (Test-Path -LiteralPath $SiblingRoot -PathType Container) { $pointerRoot['yuruna-project'] = $SiblingRoot }
    $mismatch = @(Find-HeadingRegionMismatch -HomeById $homeById -Pointer @(Get-RegionPointer -Root $pointerRoot))
    foreach ($m in $mismatch) {
        Write-Output "  heading $($m.Label) $($m.Id) '$($m.Heading)': its pointer $($m.Pointer) sits in region '$($m.Region)'"
    }
    Write-Output "Heading check: $($mismatch.Count) heading pointer(s) sit in a region the heading does not name (reported only)."
}
Write-Output ''
if ($Update) {
    Write-Output "Injected $injected anchor(s); wrote $written file(s); $($problem.Count) problem(s)."
    if ($problem.Count -gt 0) { exit 2 }
    if ($written -gt 0) { exit 1 }
    exit 0
}
Write-Output "Checked $(@($documents).Count) document(s); $($problem.Count) problem(s)."
if ($problem.Count -gt 0) { exit 1 }
exit 0
