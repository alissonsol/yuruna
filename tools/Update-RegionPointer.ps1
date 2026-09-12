<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42e1904b-8c57-4d3a-b06f-5719ca82dd41
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization documentation anchors migration
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
    Rewrite REGION pointers from the slug form to the language-neutral
    anchor id form.
.DESCRIPTION
    The slug form -- the short link, a document slug, then `#` and a slug made
    from the heading's own words -- addresses a heading by what it says, so it
    can only ever reach the English text: the Portuguese heading slugs
    differently, and a fragment that matches nothing scrolls to the top of the
    document without saying so.

    The id form addresses the same heading through the short link followed by
    an id shaped `<file>-<anchor>`, which was injected above that heading in
    every language, so the pointer resolves wherever the reader is sent.
    (Written without the host here on purpose: a complete pointer in this
    help text would be read as a real one by the gate that checks them.)

    The rewrite is mechanical and reversible from the manifest: every id maps
    back to a file and the heading text it names, which is what makes an
    opaque pointer readable again when someone needs to know where it goes.

    A pointer whose target is not in the anchor manifest is LEFT ALONE. Those
    are the slugs that resolve to a document outside the anchored set, or to
    a site this repository does not own, and inventing an id for them would
    be worse than leaving a form that still works.

    Exit codes follow the entry-point contract:
        0  Nothing needed rewriting.
        1  Pointers were rewritten (-Update), or would be (default).
        2  A manifest needed for the mapping is missing.

.PARAMETER Update
    Rewrite the files. Without it, the run only reports.
.PARAMETER Path
    Restrict to tracked files matching these values. Wildcards allowed.
.PARAMETER Quiet
    Print only the summary and anything unresolvable.

.EXAMPLE
    pwsh tools/Update-RegionPointer.ps1
    Reports what would change.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([string])]
param(
    [switch]$Update,
    [string[]]$Path,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LinkMap = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna.link/yuruna.link.json'
$AnchorManifest = Join-Path $RepoRoot 'globalization/manifests/doc-anchors.json'

foreach ($needed in @($LinkMap, $AnchorManifest)) {
    if (-not (Test-Path -LiteralPath $needed -PathType Leaf)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "Required for the mapping and not found: $needed"
        exit 2
    }
}

# slug -> repo-relative docs path, the same shape the anchor gate reads.
$slugToDoc = @{}
$parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($LinkMap))
$entries = if ($parsed -is [System.Collections.IList] -and $parsed.Count -gt 0 -and
                $parsed[0] -is [System.Collections.IList]) { $parsed } else { , $parsed }
foreach ($entry in $entries) {
    foreach ($url in @($entry[2])) {
        $m = [regex]::Match([string]$url, '/blob/main/(docs/[^#\s]+\.md)')
        if (-not $m.Success) { continue }
        foreach ($s in @($entry[0])) { if (-not $slugToDoc.ContainsKey($s)) { $slugToDoc[$s] = $m.Groups[1].Value } }
    }
}

# (docs path, heading slug) -> anchor id.
$idBySlug = @{}
$anchorData = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($AnchorManifest))
foreach ($f in @($anchorData.files)) {
    if ($f.repo -ne 'yuruna') { continue }
    foreach ($a in @($f.anchors)) { $idBySlug["$($f.source)|$($a.slug)"] = $a.id }
}

Push-Location $RepoRoot
try { $tracked = @(& git ls-files) } finally { Pop-Location }

$pointer = [regex]'yuruna\.link/([A-Za-z0-9._/-]+?)#([A-Za-z0-9._-]+)'
$rewritten = 0
$filesTouched = 0
$left = [Collections.Generic.List[string]]::new()

foreach ($rel in $tracked) {
    if ($Path -and $Path.Count -gt 0) {
        if (-not (@($Path | Where-Object { $rel -like $_ }).Count -gt 0)) { continue }
    }
    # The same exclusion the anchor gate applies: a closed review record keeps
    # the names it had when it was written. Runtime output needs no exclusion,
    # because it is gitignored and never enumerated.
    if ($rel -like 'dev-only/review.history/*') { continue }

    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) { continue }
    if ([Array]::IndexOf($bytes, [byte]0, 0, [Math]::Min(2048, $bytes.Length)) -ge 0) { continue }
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch 'yuruna\.link/') { continue }

    $fileChanges = 0
    $updated = $pointer.Replace($text, {
        param($m)
        $slug = $m.Groups[1].Value
        $anchor = $m.Groups[2].Value.ToLowerInvariant()
        if (-not $slugToDoc.ContainsKey($slug)) { return $m.Value }
        $key = "$($slugToDoc[$slug])|$anchor"
        if (-not $idBySlug.ContainsKey($key)) {
            $script:leftBehind = $true
            return $m.Value
        }
        $script:fileChangeCount++
        return "yuruna.link/$($idBySlug[$key])"
    })

    # Count by comparing, because the callback runs in its own scope.
    $before = $pointer.Matches($text).Count
    $after = $pointer.Matches($updated).Count
    $fileChanges = $before - $after
    if ($fileChanges -le 0) { continue }

    $rewritten += $fileChanges
    $filesTouched++
    if ($Update) {
        if ($PSCmdlet.ShouldProcess($rel, "rewrite $fileChanges pointer(s) to id form")) {
            [IO.File]::WriteAllText($full, $updated, [Text.UTF8Encoding]::new($false))
        }
    }
    if (-not $Quiet) { Write-Output ("{0}  {1}  {2} pointer(s)" -f ($(if ($Update) { 'REWROTE' } else { 'WOULD  ' })), $rel, $fileChanges) }
}

Write-Output ''
Write-Output ("Update-RegionPointer: {0} pointer(s) in {1} file(s) {2}." -f
    $rewritten, $filesTouched, $(if ($Update) { 'rewritten' } else { 'would be rewritten' }))
if ($left.Count -gt 0) {
    Write-Output "Left in slug form (target not in the anchor manifest): $($left.Count)"
}
if ($rewritten -gt 0) { exit 1 }
exit 0
