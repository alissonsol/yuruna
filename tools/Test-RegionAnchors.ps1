<#PSScriptInfo
.VERSION 2026.08.16
.GUID 425a0170-ca9a-4ed5-a768-4cf3925b242a
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
    CI gate: every `# --- REGION: https://yuruna.link/<slug>#<anchor>` pointer
    resolves to a real heading in the document that slug names.
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
    # Runtime output, and the review-history records whose purpose is to
    # preserve anchor names as they were at the time -- both would report
    # states this gate is not meant to police.
    if ($rel -like 'test/status/*') { continue }
    if ($rel -like 'dev-only/review.history/*' -or $rel -like 'dev-only/simplification/*') { continue }
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

if (-not $Quiet) {
    Write-Output "Test-RegionAnchors: $checked pointer(s) checked against $($slugToDoc.Count) docs slug(s)."
}

foreach ($u in $unknown) {
    Write-Warning ("  UNRESOLVABLE  {0}:{1}" -f $u.file, $u.line)
    Write-Warning ("                slug '{0}' is not a docs/ target in the link map (external or sibling-repo target)" -f $u.slug)
}

if ($dangling.Count -eq 0) {
    Write-Output "Test-RegionAnchors: all in-repo pointers resolve."
    exit $ExitOk
}

Write-Warning "Test-RegionAnchors: $($dangling.Count) pointer(s) name a heading that does not exist:"
foreach ($d in ($dangling | Sort-Object { $_.doc }, { $_.anchor })) {
    Write-Warning ("  FAIL  {0}:{1}" -f $d.file, $d.line)
    Write-Warning ("        {0} has no heading slugging to '{1}'" -f $d.doc, $d.anchor)
}
exit $ExitFailure
