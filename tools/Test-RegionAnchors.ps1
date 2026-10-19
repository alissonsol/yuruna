<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 427a25a9-d3c8-4ce6-b877-b396666875b0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate docs anchors region
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
    CI gate for the two comment-shaped tokens the workspace parses: every
    `# --- REGION: https://yuruna.link/42xxxxxx-yyyy` pointer resolves to a
    real heading, and every `# === YURUNA_OVERLAY_<KEY> ===` anchor pairs
    between a cloud-init base seed and its per-host overlays.
.DESCRIPTION
    Load-bearing rationale lives in `docs/`, and source files point at it with a
    one-line REGION comment instead of carrying the explanation inline. That
    split only works while the pointer resolves: a heading that is reworded,
    moved or never written turns the comment into a dead end, and nothing at
    build time notices -- the source still compiles, the doc still renders, and
    the reader follows a link to the top of a page that does not answer them.

    Resolution follows what a browser actually does. `yuruna.link.json` maps the
    slug to a GitHub blob URL; `redirect.js` forwards an incoming fragment
    verbatim, overriding any fragment on the target, so the anchor is matched
    against the target document rather than the link entry. Headings are
    slugified the way GitHub does it: lowercase, drop every character that is
    not `[a-z0-9_ -]` (which removes backticks, periods and parentheses), then
    replace spaces with hyphens. Explicit HTML anchors retain their exact case.
    A Grafana ${__value.raw} fragment is checked against documented destinations
    sharing its static prefix and suffix; runtime values require consumer tests.

    Markdown targets in every inventoried workspace checkout can be checked. A
    slug pointing at an external site is reported as unresolvable rather than
    failed -- this gate cannot see it.

    Nonlocalized SBOM documents remain outside the generated anchor manifest.
    Their published file-id rows identify the local document; an id must match
    that file prefix and occur outside fenced examples in the target.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  Every in-repo pointer resolves.
        1  At least one pointer names a heading that does not exist.
        2  The link map is missing, so nothing could be checked.

.PARAMETER Path
    Roots to scan for REGION pointers. Default: all existing workspace source
    checkouts and any AdditionalSourceRoot. A supplied root filters that inventory.
.PARAMETER ProjectRoot
    Project checkout whose tracked and untracked, non-ignored sources are
    scanned beside the framework. Defaults to the sibling yuruna-project.
.PARAMETER AdditionalSourceRoot
    Other Git checkouts whose tracked and untracked, non-ignored sources are
    scanned. The default inventory includes sibling yuruna.link and amisad.dev
    checkouts, with alius-git/amisad.dev as a fallback. Their local Markdown
    targets are checked through the same published catalog as the framework.
.PARAMETER AnchorManifest
    Path to the generated anchor index that says which ids exist. Default:
    globalization/manifests/doc-anchors.json. Pointing it at a different
    index is how this gate's own suite proves it still rejects an id that
    names no heading.
.PARAMETER LinkMap
    Path to `yuruna.link.json`. Default: the sibling `yuruna.link` checkout
    beside this repository. When it is absent the gate exits 2: it has
    checked nothing, and reporting that as success would let every pointer
    in the repository rot behind a green run. A caller that genuinely
    cannot supply the map has to say so, rather than being told the
    pointers are fine.
.PARAMETER Quiet
    Print only failures and the final summary.

.EXAMPLE
    pwsh tools/Test-RegionAnchors.ps1
    # Existing workspace checkouts; exits 0 / 1.

.EXAMPLE
    pwsh tools/Test-RegionAnchors.ps1 -Path automation -Quiet
    # Just the guest-facing scripts.
#>

[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$ProjectRoot,
    [string[]]$AdditionalSourceRoot,
    [string]$LinkMap,
    [string]$AnchorManifest,
    [switch]$Quiet
)

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolRoot
$projectRootWasExplicit = $PSBoundParameters.ContainsKey('ProjectRoot')
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }

Import-Module (Join-Path $RepoRoot 'test/modules/Test.Prelude.psm1') -Global -Force
Import-Module (Join-Path $ToolRoot 'Markdown.LocalAnchors.psm1') -Global -Force
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
$ExitCannotRun = Get-EntryPointExitCode -Outcome CannotRun

if ($projectRootWasExplicit -and -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    Write-Warning "Test-RegionAnchors: project checkout not found at '$ProjectRoot'; nothing checked."
    exit $ExitCannotRun
}
if (Test-Path -LiteralPath $ProjectRoot -PathType Container) {
    $ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
}
$repositories = [Collections.Generic.List[object]]::new()
$repositories.Add([pscustomobject]@{ Name = 'yuruna'; Root = $RepoRoot })
if (Test-Path -LiteralPath $ProjectRoot -PathType Container) {
    $repositories.Add([pscustomobject]@{ Name = 'yuruna-project'; Root = $ProjectRoot })
}
$workspaceRoot = Split-Path -Parent $RepoRoot
$amisadRoot = Join-Path $workspaceRoot 'amisad.dev'
if (-not (Test-Path -LiteralPath $amisadRoot -PathType Container)) {
    $amisadRoot = Join-Path $workspaceRoot 'alius-git/amisad.dev'
}
foreach ($source in @(
        @{ Name = 'yuruna.link'; Root = (Join-Path $workspaceRoot 'yuruna.link') },
        @{ Name = 'amisad.dev'; Root = $amisadRoot })) {
    $sourceRoot = $source.Root
    if (Test-Path -LiteralPath $sourceRoot -PathType Container) {
        $repositories.Add([pscustomobject]@{
                Name = $source.Name
                Root = (Resolve-Path -LiteralPath $sourceRoot).Path
            })
    }
}
foreach ($sourceRoot in $AdditionalSourceRoot) {
    $candidate = if ([IO.Path]::IsPathRooted($sourceRoot)) { $sourceRoot } else { Join-Path $RepoRoot $sourceRoot }
    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        Write-Warning "Test-RegionAnchors: additional source checkout not found at '$candidate'; nothing checked."
        exit $ExitCannotRun
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    if (@($repositories | Where-Object { $_.Root -eq $resolved }).Count -eq 0) {
        $repositories.Add([pscustomobject]@{ Name = Split-Path -Leaf $resolved; Root = $resolved })
    }
}
$repositoryRoots = @{}
foreach ($repository in $repositories) {
    if (-not $repositoryRoots.ContainsKey($repository.Name)) {
        $repositoryRoots[$repository.Name] = $repository.Root
    }
}
if (-not $Path -or $Path.Count -eq 0) {
    $Path = @($repositories | ForEach-Object { $_.Root })
}
if (-not $LinkMap) {
    $LinkMap = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna.link/yuruna.link.json'
}

if (-not (Test-Path -LiteralPath $LinkMap -PathType Leaf)) {
    Write-Warning ("Test-RegionAnchors: link map not found at '$LinkMap'; nothing checked. " +
        'Clone the yuruna.link repository beside this one, or pass -LinkMap.')
    exit $ExitCannotRun
}

# Slug -> repository + relative Markdown path for every entry whose target is
# visible in the workspace inventory. Entries carry either a bare
# slug or an array of aliases, and either a single URL or an array; every alias
# resolves to the same target.
$slugToDoc = @{}
$publishedFileIdUrls = @{}
$parsedMap = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $LinkMap -Raw)
# A map holding one entry parses to a single inner array, and enumerating that
# yields its three fields instead of one entry -- which reads as a map full of
# unusable rows rather than as an error. Wrap it back into a one-entry list.
$mapEntries = [System.Collections.Generic.List[object]]::new()
if ($parsedMap -is [System.Collections.IList] -and $parsedMap.Count -gt 0 -and
    $parsedMap[0] -is [System.Collections.IList]) {
    foreach ($e in $parsedMap) { $mapEntries.Add($e) }
} else {
    $mapEntries.Add($parsedMap)
}
foreach ($entry in $mapEntries) {
    $slugs = @($entry[0])
    $urls  = @($entry[2])
    foreach ($slug in $slugs) {
        if ([string]$slug -cnotmatch '^42[0-9a-f]{6}$') { continue }
        if (-not $publishedFileIdUrls.ContainsKey($slug)) {
            $publishedFileIdUrls[$slug] = [Collections.Generic.List[string]]::new()
        }
        foreach ($url in $urls) { $publishedFileIdUrls[$slug].Add([string]$url) }
    }
    foreach ($url in $urls) {
        $m = [regex]::Match([string]$url,
            '^https://github\.com/[^/]+/([^/]+)/blob/main/([^?#\s]+\.md)(?:\?[^#\s]*)?(?:#[^\s]*)?$')
        if (-not $m.Success -or -not $repositoryRoots.ContainsKey($m.Groups[1].Value)) { continue }
        $target = [pscustomobject]@{ Repo = $m.Groups[1].Value; Path = $m.Groups[2].Value }
        foreach ($s in $slugs) { if (-not $slugToDoc.ContainsKey($s)) { $slugToDoc[$s] = $target } }
    }
}

function Get-HeadingSlug {
    <#
    .SYNOPSIS
        Slugify heading text the way GitHub does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Heading)
    return (Get-GitHubHeadingSlug -Heading $Heading)
}

$anchorCache = @{}
function Get-DocAnchorSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma preserves one HashSet object on the PowerShell pipeline.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$DocRelativePath
    )

    $cacheKey = "$Repo`:$DocRelativePath"
    if ($anchorCache.ContainsKey($cacheKey)) { return ,$anchorCache[$cacheKey] }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $documentRoot = $repositoryRoots[$Repo]
    $full = Join-Path $documentRoot $DocRelativePath
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $text = Get-Content -LiteralPath $full -Raw
        $fenceCharacter = ''
        $fenceLength = 0
        $inComment = $false
        foreach ($line in ($text -split '\r\n|\n|\r')) {
            # Both fence styles can quote headings and explicit anchor examples.
            if ($fenceCharacter) {
                $closing = '^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
                if ($line -match $closing) { $fenceCharacter = '' }
                continue
            }
            $fence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$')
            if (-not $inComment -and $fence.Success -and -not ($fence.Groups[1].Value[0] -eq '`' -and
                    $fence.Groups[2].Value.Contains('`'))) {
                $fenceCharacter = [string]$fence.Groups[1].Value[0]
                $fenceLength = $fence.Groups[1].Length
                continue
            }
            # A comment opener inside code is literal text. Scan in document
            # order so it cannot hide real destinations later in the document.
            $prose = [Text.StringBuilder]::new()
            $rendered = [Text.StringBuilder]::new()
            $position = 0
            while ($position -lt $line.Length) {
                if ($inComment) {
                    $end = $line.IndexOf('-->', $position, [StringComparison]::Ordinal)
                    if ($end -lt 0) { break }
                    $inComment = $false
                    $position = $end + 3
                    continue
                }
                $token = [regex]::Match($line.Substring($position), '(?<!`)(`+)(?!`)(.*?)\1(?!`)|<!--')
                $length = if ($token.Success) { $token.Index } else { $line.Length - $position }
                [void]$prose.Append($line.Substring($position, $length))
                [void]$rendered.Append($line.Substring($position, $length))
                $position += $length
                if (-not $token.Success) { break }
                if ($token.Value -eq '<!--') { $inComment = $true }
                else { [void]$prose.Append($token.Value) }
                $position += $token.Length
            }
            $heading = [regex]::Match($prose.ToString(), '^#{1,6}\s+(.*)$')
            if ($heading.Success) { $null = $set.Add((Get-HeadingSlug -Heading $heading.Groups[1].Value)) }
            foreach ($anchor in [regex]::Matches($rendered.ToString(), '(?i)<a\b[^>]*?\sid\s*=\s*(["''])([^"'']+)\1[^>]*>')) {
                $null = $set.Add($anchor.Groups[2].Value)
            }
        }
    }
    $anchorCache[$cacheKey] = $set
    return ,$set
}

# Git excludes ignored output and runtime state while checking new pointers
# before commit in every inventoried source checkout.
$roots = @($Path | ForEach-Object {
        $candidate = if ([IO.Path]::IsPathRooted($_)) { $_ } else { Join-Path $RepoRoot $_ }
        (Resolve-Path -LiteralPath $candidate -ErrorAction SilentlyContinue).Path
    } | Where-Object { $_ } | Sort-Object -Unique)
if ($roots.Count -eq 0) {
    Write-Warning 'Test-RegionAnchors: none of the requested scan roots exists; nothing checked.'
    exit $ExitCannotRun
}
$candidateFiles = [Collections.Generic.List[object]]::new()
foreach ($repository in $repositories) {
    $tracked = @(& git -C $repository.Root ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Test-RegionAnchors: git could not enumerate $($repository.Name) at '$($repository.Root)'; nothing checked."
        exit $ExitCannotRun
    }
    foreach ($rel in @($tracked | Sort-Object -Unique)) {
        $full = Join-Path $repository.Root $rel
        $inScope = @($roots | Where-Object {
                $rootPath = $_.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                $full -eq $rootPath -or $full.StartsWith(
                    $rootPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)
            }).Count -gt 0
        if (-not $inScope) { continue }
        $candidateFiles.Add([pscustomobject]@{
                Repo = $repository.Name
                Relative = [string]$rel
                FullName = $full
                Display = "$($repository.Name)/$(([string]$rel).Replace('\', '/'))"
            })
    }
}
$pointer = [regex]'yuruna\.link/([A-Za-z0-9._/-]+?)#([A-Za-z0-9._${}-]+)'

# The identity form: yuruna.link/<file>-<anchor>, where the id names a heading
# directly instead of describing it. A slug pointer can only ever address the
# English text, because a slug is made of the words in the heading; an id is
# injected above the same heading in every translation, so one pointer resolves
# in every language. Both forms are checked, because a tree mid-migration
# carries both.
$idPointer = [regex]'yuruna\.link/(42[0-9a-f]{6}-[0-9a-f]{4})(?![0-9a-zA-Z-])'
$anchorIds = [System.Collections.Generic.HashSet[string]]::new()
$anchorDoc = @{}
if (-not $AnchorManifest) {
    $AnchorManifest = Join-Path $RepoRoot 'globalization/manifests/doc-anchors.json'
}
if (Test-Path -LiteralPath $AnchorManifest -PathType Leaf) {
    $anchorData = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($AnchorManifest))
    foreach ($f in @($anchorData.files)) {
        foreach ($a in @($f.anchors)) {
            [void]$anchorIds.Add([string]$a.id)
            $anchorDoc[[string]$a.id] = @{ Repo = [string]$f.repo; Source = [string]$f.source }
        }
    }
}

# SBOM documents keep local anchors without joining the localization manifest.
# Only a published file-id target supplies their document authority.
$localSbomAnchors = @{}
foreach ($prefix in $publishedFileIdUrls.Keys) {
    $target = $slugToDoc[$prefix]
    if (-not $target -or $target.Path -cnotmatch '^docs/sbom/.+\.md$') { continue }
    $set = [Collections.Generic.HashSet[string]]::new()
    $localSbomAnchors[$prefix] = $set
    $matchesTarget = $true
    foreach ($url in $publishedFileIdUrls[$prefix]) {
        $published = [regex]::Match($url,
            '^https://github\.com/[^/]+/([^/]+)/blob/main/([^?#\s]+\.md)(?:#[^\s]*)?$')
        if (-not $published.Success -or $published.Groups[1].Value -cne $target.Repo -or
            $published.Groups[2].Value -cne $target.Path) { $matchesTarget = $false; break }
    }
    if (-not $matchesTarget) { continue }
    $documentRoot = $repositoryRoots[$target.Repo]
    $sbomRoot = [IO.Path]::GetFullPath((Join-Path $documentRoot 'docs/sbom')) + [IO.Path]::DirectorySeparatorChar
    $full = [IO.Path]::GetFullPath((Join-Path $documentRoot $target.Path))
    if (-not $full.StartsWith($sbomRoot, [StringComparison]::Ordinal) -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    foreach ($id in @(Get-LocalSbomAnchorId -LiteralPath $full)) {
        if ($id.StartsWith($prefix + '-', [StringComparison]::Ordinal)) { [void]$set.Add($id) }
    }
}

# Whether the document itself still carries that anchor. The manifest is
# generated FROM the documents, so checking a pointer against the manifest
# alone only proves the generator ran -- a heading deleted and its id later
# reissued to different text would still look valid. The document is what a
# reader actually lands on, so the document is what has to be asked.
$anchorPresence = @{}
function Test-AnchorInDocument {
    param([Parameter(Mandatory)][string]$Id)

    if ($anchorPresence.ContainsKey($Id)) { return $anchorPresence[$Id] }
    $known = $anchorDoc[$Id]
    if (-not $known) { $anchorPresence[$Id] = $false; return $false }
    $root = $repositoryRoots[$known.Repo]
    if (-not $root) { $anchorPresence[$Id] = $false; return $false }
    $full = Join-Path $root ($known.Source -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $anchorPresence[$Id] = $false; return $false }
    $present = ([System.IO.File]::ReadAllText($full)).Contains('<a id="' + $Id + '"></a>')
    $anchorPresence[$Id] = $present
    return $present
}

$dangling   = New-Object System.Collections.Generic.List[hashtable]
$unknown    = New-Object System.Collections.Generic.List[hashtable]
$unknownId  = New-Object System.Collections.Generic.List[hashtable]
$checked    = 0
$templates  = 0

foreach ($candidateFile in $candidateFiles) {
    $rel = $candidateFile.Relative
    $full = $candidateFile.FullName
    $display = $candidateFile.Display
    if (-not [IO.File]::Exists($full)) { continue }
    # A closed review record states what was true when it was written, so its
    # pointers are history rather than something to keep working.
    #
    # The harness runtime output under test/status/ is NOT excluded here, and
    # does not need to be: every runtime subdirectory (runtime/, log/, perf/,
    # extension/, captures/, ssh/) is gitignored, so candidate enumeration
    # never sees one. Excluding the path instead hid the ten
    # shipped sources that DO live there -- the status pages and the shared
    # stylesheet and runtime -- and the pointers in them went unchecked.
    if ($candidateFile.Repo -eq 'yuruna' -and $rel -like 'dev-only/review.history/*') { continue }

    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) { continue }
    # A NUL in the first block means binary; skip rather than mangle.
    if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min(2048, $bytes.Length)) -ge 0) { continue }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch 'yuruna\.link/') { continue }

    $lineNo = 0
    foreach ($line in ($text -split "`n")) {
        $lineNo++
        if (-not $line.Contains('yuruna.link/', [StringComparison]::Ordinal)) { continue }
        foreach ($m in $pointer.Matches($line)) {
            $checked++
            $slug   = $m.Groups[1].Value
            $anchor = $m.Groups[2].Value
            if (-not $slugToDoc.ContainsKey($slug)) {
                $unknown.Add(@{ file = $display; line = $lineNo; slug = $slug; anchor = $anchor })
                continue
            }
            $target = $slugToDoc[$slug]
            $destinations = Get-DocAnchorSet -Repo $target.Repo -DocRelativePath $target.Path
            $present = $destinations.Contains($anchor)
            if ($anchor -match '[$}{]') {
                # Do not truncate a template into a static fragment or accept an
                # arbitrary interpolation. Its consumer owns the value domain.
                $template = [regex]::Match($anchor, '^([A-Za-z0-9._-]+)\$\{__value\.raw\}([A-Za-z0-9._-]*)$')
                $present = $false
                if ($template.Success) {
                    $pattern = '^' + [regex]::Escape($template.Groups[1].Value) +
                        '[A-Za-z0-9._-]+' + [regex]::Escape($template.Groups[2].Value) + '$'
                    foreach ($destination in $destinations) {
                        if ([regex]::IsMatch($destination, $pattern)) { $present = $true; break }
                    }
                    if ($present) { $templates++ }
                }
            }
            if (-not $present) {
                $dangling.Add(@{
                        file = $display; line = $lineNo; slug = $slug; anchor = $anchor
                        doc = "$($target.Repo)/$($target.Path)"
                    })
            }
        }
        foreach ($m in $idPointer.Matches($line)) {
            $checked++
            $id = $m.Groups[1].Value
            $prefix = $id.Substring(0, 8)
            if ($localSbomAnchors.ContainsKey($prefix)) {
                if (-not $localSbomAnchors[$prefix].Contains($id)) {
                    $unknownId.Add(@{ file = $display; line = $lineNo; id = $id })
                }
            } elseif (-not $anchorIds.Contains($id)) {
                # An id that names no heading is fatal, not merely
                # unresolvable: unlike a slug, an id can only ever have come
                # from this repository's own generator.
                $unknownId.Add(@{ file = $display; line = $lineNo; id = $id })
            } elseif (-not (Test-AnchorInDocument -Id $id)) {
                $unknownId.Add(@{ file = $display; line = $lineNo; id = $id })
            }
        }
    }
}

# Second check: the cloud-init overlay anchors.
#
# `# === YURUNA_OVERLAY_<KEY> ===` looks like a comment but is a parsed token.
# Merge-CloudInitUserData matches it with a case-sensitive regex and throws when
# a base anchors a key its overlay does not define, or an overlay defines a key
# the base never anchors. That throw lands at VM-creation time, on a host,
# mid-cycle -- so a comment restyle that drops or reflows one of these lines
# evades static parsing and fails only at the first guest bring-up. The
# same pairing is cheap to check here, where a wrong edit is still a diff.
$anchorRe    = [regex]'^\s*#\s*===\s*YURUNA_OVERLAY_([A-Z0-9_]+)\s*===\s*$'
$overlayBad  = New-Object System.Collections.Generic.List[hashtable]
$seedsSeen   = 0
$vmconfigDir = Join-Path $RepoRoot 'host/vmconfig'

function Get-OverlayAnchorName {
    <#
    .SYNOPSIS
        Anchor keys named by a base seed or defined by an overlay, in file order.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Path)
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $m = $anchorRe.Match($line)
        if ($m.Success) { $keys.Add($m.Groups[1].Value) }
    }
    return [string[]]$keys.ToArray()
}

if ((Test-Path -LiteralPath $vmconfigDir -PathType Container) -and
    ($roots | Where-Object { $vmconfigDir.StartsWith($_, [StringComparison]::Ordinal) })) {
    foreach ($base in (Get-ChildItem -LiteralPath $vmconfigDir -Filter '*.base.user-data' -File | Sort-Object Name)) {
        $seedsSeen++
        $stem      = $base.Name -replace '\.base\.user-data$', ''
        $anchored  = @(Get-OverlayAnchorName -Path $base.FullName)
        foreach ($overlay in (Get-ChildItem -LiteralPath $vmconfigDir -Filter "$stem.*.overlay.yml" -File | Sort-Object Name)) {
            $defined = @(Get-OverlayAnchorName -Path $overlay.FullName)
            $dupe    = @($defined | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            foreach ($k in $dupe) {
                $overlayBad.Add(@{ file = $overlay.Name; key = $k; why = 'defined twice in the overlay -- the later payload silently wins' })
            }
            foreach ($k in ($anchored | Where-Object { $defined -notcontains $_ })) {
                $overlayBad.Add(@{ file = $overlay.Name; key = $k; why = "anchored by $($base.Name) but this overlay defines no such section" })
            }
            foreach ($k in ($defined | Where-Object { $anchored -notcontains $_ })) {
                $overlayBad.Add(@{ file = $overlay.Name; key = $k; why = "defined here but $($base.Name) anchors no such key -- the section is never emitted" })
            }
        }
    }
}

if (-not $Quiet) {
    Write-Output "Test-RegionAnchors: $checked pointer(s) checked against $($slugToDoc.Count) local Markdown slug(s)."
    Write-Output "Test-RegionAnchors: overlay anchors checked across $seedsSeen cloud-init seed(s)."
}

foreach ($o in ($overlayBad | Sort-Object { $_.file }, { $_.key })) {
    Write-Warning ("  FAIL  {0}" -f $o.file)
    Write-Warning ("        YURUNA_OVERLAY_{0} {1}" -f $o.key, $o.why)
}

foreach ($u in $unknown) {
    Write-Warning ("  UNRESOLVABLE  {0}:{1}" -f $u.file, $u.line)
    Write-Warning ("                slug '{0}' is not a local workspace Markdown target in the link map" -f $u.slug)
}

foreach ($u in ($unknownId | Sort-Object { $_.file }, { $_.line })) {
    Write-Warning ("  FAIL  {0}:{1}" -f $u.file, $u.line)
    Write-Warning ("        id '{0}' names no heading in the anchor manifest or its published local SBOM target" -f $u.id)
}

if ($dangling.Count -eq 0 -and $overlayBad.Count -eq 0 -and $unknownId.Count -eq 0) {
    if ($templates -gt 0) {
        Write-Output "Test-RegionAnchors: $templates template pointer(s) match documented destinations; runtime values require consumer validation."
    }
    Write-Output 'Test-RegionAnchors: all static in-repo pointers resolve; every overlay anchor pairs.'
    exit $ExitOk
}

if ($unknownId.Count -gt 0) {
    Write-Warning "Test-RegionAnchors: $($unknownId.Count) pointer(s) name an anchor id that does not exist."
}

if ($overlayBad.Count -gt 0) {
    Write-Warning "Test-RegionAnchors: $($overlayBad.Count) overlay anchor(s) do not pair -- the merge would throw at VM creation."
}
if ($dangling.Count -eq 0) { exit $ExitFailure }


Write-Warning "Test-RegionAnchors: $($dangling.Count) pointer(s) name a heading that does not exist:"
foreach ($d in ($dangling | Sort-Object { $_.doc }, { $_.anchor })) {
    Write-Warning ("  FAIL  {0}:{1}" -f $d.file, $d.line)
    Write-Warning ("        {0} has no heading slugging to '{1}'" -f $d.doc, $d.anchor)
}
exit $ExitFailure
