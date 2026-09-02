<#PSScriptInfo
.VERSION 2026.09.01
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
    CI gate for the two comment-shaped tokens this repo parses: every
    `# --- REGION: https://yuruna.link/<slug>#<anchor>` pointer resolves to a
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
    replace spaces with hyphens.

    Only targets inside this repository's `docs/` tree can be checked. A slug
    pointing at an external site, or at a file in a sibling repository, is
    reported as unresolvable rather than failed -- this gate cannot see it.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  Every in-repo pointer resolves.
        1  At least one pointer names a heading that does not exist.

.PARAMETER Path
    Roots to scan for REGION pointers. Default: the repository root.
.PARAMETER LinkMap
    Path to `yuruna.link.json`. Default: the sibling `yuruna.link` checkout
    beside this repository. When it is absent the gate reports and exits 0,
    because a missing sibling clone is an environment gap, not a defect in
    this repository.
.PARAMETER Quiet
    Print only failures and the final summary.

.EXAMPLE
    pwsh tools/Test-RegionAnchors.ps1
    # Whole repo; exits 0 / 1.

.EXAMPLE
    pwsh tools/Test-RegionAnchors.ps1 -Path automation -Quiet
    # Just the guest-facing scripts.
#>

[CmdletBinding()]
param(
    [string[]]$Path,
    [string]$LinkMap,
    [switch]$Quiet
)

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ToolRoot

Import-Module (Join-Path $RepoRoot 'test/modules/Test.Prelude.psm1') -Global -Force
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure

if (-not $Path -or $Path.Count -eq 0) { $Path = @($RepoRoot) }
if (-not $LinkMap) {
    $LinkMap = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna.link/yuruna.link.json'
}

if (-not (Test-Path -LiteralPath $LinkMap -PathType Leaf)) {
    Write-Warning "Test-RegionAnchors: link map not found at '$LinkMap'; nothing checked."
    exit $ExitOk
}

# Slug -> repo-relative docs path, for every entry whose target is a docs file
# in this repository. Entries carry either a bare slug or an array of aliases,
# and either a single URL or an array; every alias resolves to the same target.
$slugToDoc = @{}
foreach ($entry in (Get-Content -LiteralPath $LinkMap -Raw | ConvertFrom-Json)) {
    $slugs = @($entry[0])
    $urls  = @($entry[2])
    foreach ($url in $urls) {
        $m = [regex]::Match([string]$url, '/blob/main/(docs/[^#\s]+\.md)')
        if (-not $m.Success) { continue }
        foreach ($s in $slugs) { if (-not $slugToDoc.ContainsKey($s)) { $slugToDoc[$s] = $m.Groups[1].Value } }
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

    $t = $Heading
    # Inline markup contributes its text, not its punctuation.
    $t = [regex]::Replace($t, '`([^`]*)`', '$1')
    $t = [regex]::Replace($t, '\*\*?([^*]*)\*\*?', '$1')
    $t = [regex]::Replace($t, '\[([^\]]*)\]\([^)]*\)', '$1')
    $t = $t.ToLowerInvariant()
    $t = [regex]::Replace($t, '[^\p{L}\p{Nd}_ -]', '')
    return $t.Replace(' ', '-')
}

$anchorCache = @{}
function Get-DocAnchorSet {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    param([Parameter(Mandatory)][string]$DocRelativePath)

    if ($anchorCache.ContainsKey($DocRelativePath)) { return $anchorCache[$DocRelativePath] }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $full = Join-Path $RepoRoot $DocRelativePath
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $text = Get-Content -LiteralPath $full -Raw
        # Fenced blocks can contain '#' lines that are not headings.
        $text = [regex]::Replace($text, '(?s)```.*?```', '')
        foreach ($m in [regex]::Matches($text, '(?m)^#{1,6}\s+(.*)$')) {
            $null = $set.Add((Get-HeadingSlug -Heading $m.Groups[1].Value))
        }
    }
    $anchorCache[$DocRelativePath] = $set
    return $set
}

# Tracked text files only: the working tree also holds build output and runtime
# state whose contents are not ours to police.
Push-Location $RepoRoot
try { $tracked = @(& git ls-files) } finally { Pop-Location }

$roots = @($Path | ForEach-Object { (Resolve-Path -LiteralPath $_ -ErrorAction SilentlyContinue).Path } | Where-Object { $_ })
$pointer = [regex]'yuruna\.link/([A-Za-z0-9._/-]+?)#([A-Za-z0-9._-]+)'

$dangling   = New-Object System.Collections.Generic.List[hashtable]
$unknown    = New-Object System.Collections.Generic.List[hashtable]
$checked    = 0

foreach ($rel in $tracked) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    # Runtime output and historical records deliberately preserve anchor
    # names as they were at the time -- both would report
    # states this gate is not meant to police.
    if ($rel -like 'test/status/*') { continue }
    if ($rel -like 'dev-only/review.history/*') { continue }
    if (-not ($roots | Where-Object { $full.StartsWith($_, [StringComparison]::Ordinal) })) { continue }

    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) { continue }
    # A NUL in the first block means binary; skip rather than mangle.
    if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min(2048, $bytes.Length)) -ge 0) { continue }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch 'yuruna\.link/') { continue }

    $lineNo = 0
    foreach ($line in ($text -split "`n")) {
        $lineNo++
        foreach ($m in $pointer.Matches($line)) {
            $checked++
            $slug   = $m.Groups[1].Value
            $anchor = $m.Groups[2].Value.ToLowerInvariant()
            if (-not $slugToDoc.ContainsKey($slug)) {
                $unknown.Add(@{ file = $rel; line = $lineNo; slug = $slug; anchor = $anchor })
                continue
            }
            $doc = $slugToDoc[$slug]
            if (-not (Get-DocAnchorSet -DocRelativePath $doc).Contains($anchor)) {
                $dangling.Add(@{ file = $rel; line = $lineNo; slug = $slug; anchor = $anchor; doc = $doc })
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
    Write-Output "Test-RegionAnchors: $checked pointer(s) checked against $($slugToDoc.Count) docs slug(s)."
    Write-Output "Test-RegionAnchors: overlay anchors checked across $seedsSeen cloud-init seed(s)."
}

foreach ($o in ($overlayBad | Sort-Object { $_.file }, { $_.key })) {
    Write-Warning ("  FAIL  {0}" -f $o.file)
    Write-Warning ("        YURUNA_OVERLAY_{0} {1}" -f $o.key, $o.why)
}

foreach ($u in $unknown) {
    Write-Warning ("  UNRESOLVABLE  {0}:{1}" -f $u.file, $u.line)
    Write-Warning ("                slug '{0}' is not a docs/ target in the link map (external or sibling-repo target)" -f $u.slug)
}

if ($dangling.Count -eq 0 -and $overlayBad.Count -eq 0) {
    Write-Output "Test-RegionAnchors: all in-repo pointers resolve; every overlay anchor pairs."
    exit $ExitOk
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
