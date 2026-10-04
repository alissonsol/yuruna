<#PSScriptInfo
.VERSION 2026.10.04
.GUID 42d5c7e8-3b19-4a62-8f04-6c2ae91b73d5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization documentation links redirector generate
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
    Publish one link-catalog row per anchored document, carrying the URL of
    that document in every language it has been translated into.
.DESCRIPTION
    A REGION pointer now names a heading by an id shaped `<file>-<anchor>`.
    The left half is the document, so the redirector can resolve
    the link without a slug -- but only if it knows which file the id belongs
    to, and where that file lives in the reader's language. (The id is written
    without its host here: a complete pointer in this help text would be read
    as a real one by the gate that checks them.)

    This writes those rows into the sibling redirector's catalog, keyed by the
    file half of the id. Each row carries the English URL in the position
    every existing row uses, and a fourth element mapping a locale tag to the
    URL of that document's translation. A row with no translation simply has
    no fourth element, and the redirector serves English.

    Published rows outside the anchor manifest are preserved, including
    nonlocalized SBOM documents whose anchors are checked locally. Generated
    rows can refresh titles and translations, but an existing key cannot
    silently change its document target. Hand-written slug rows are preserved.

    Exit codes follow the entry-point contract:
        0  The catalog already carries the current rows.
        1  Rows were written, or would be (default).
        2  Required input is missing, or a published identity is invalid.

.PARAMETER Update
    Write the catalog. Without it, the run only reports.
.PARAMETER Catalog
    Path to yuruna.link.json. Default: the sibling checkout.

.EXAMPLE
    pwsh tools/Update-LinkCatalog.ps1 -Update
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([string])]
param(
    [switch]$Update,
    [string]$Catalog
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Parent = Split-Path -Parent $RepoRoot
if (-not $Catalog) { $Catalog = Join-Path $Parent 'yuruna.link/yuruna.link.json' }
$AnchorManifest = Join-Path $RepoRoot 'globalization/manifests/doc-anchors.json'

foreach ($needed in @($Catalog, $AnchorManifest)) {
    if (-not (Test-Path -LiteralPath $needed -PathType Leaf)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "Required and not found: $needed"
        exit 2
    }
}

# The public tree each repository is served from.
$RepoUrl = @{
    'yuruna'         = 'https://github.com/alissonsol/yuruna/blob/main/'
    'yuruna-project' = 'https://github.com/alissonsol/yuruna-project/blob/main/'
}

function Get-LocalSbomAnchorId {
    <#
    .SYNOPSIS
        Read stable anchors from a nonlocalized document, excluding fenced examples.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $ids = [Collections.Generic.List[string]]::new()
    $fenceCharacter = ''
    $fenceLength = 0
    foreach ($line in [IO.File]::ReadAllLines($LiteralPath)) {
        if ($fenceCharacter) {
            $closing = '^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
            if ($line -match $closing) { $fenceCharacter = '' }
            continue
        }
        $fence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$')
        if ($fence.Success -and -not ($fence.Groups[1].Value[0] -eq '`' -and
                $fence.Groups[2].Value.Contains('`'))) {
            $fenceCharacter = [string]$fence.Groups[1].Value[0]
            $fenceLength = $fence.Groups[1].Length
            continue
        }
        $anchor = [regex]::Match($line, '^[ \t]*<a id="(42[0-9a-f]{6}-[0-9a-f]{4})"></a>[ \t]*$')
        if ($anchor.Success) { $ids.Add($anchor.Groups[1].Value) }
    }
    return [string[]]$ids.ToArray()
}

$anchorData = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($AnchorManifest))

$idRows = [Collections.Generic.List[object]]::new()
foreach ($f in @($anchorData.files)) {
    $base = $RepoUrl[[string]$f.repo]
    if (-not $base) { continue }
    $row = [Collections.Generic.List[object]]::new()
    $row.Add([string]$f.id)
    # The title is what the redirector shows while it forwards, so it names
    # the document a reader is about to land on.
    $title = if ($f.anchors -and @($f.anchors).Count -gt 0) { [string](@($f.anchors)[0].heading) } else { [string]$f.source }
    $row.Add($title)
    $row.Add($base + [string]$f.source)
    $byLocale = [ordered]@{}
    foreach ($p in $f.translations.PSObject.Properties) {
        $byLocale[$p.Name] = $base + [string]$p.Value
    }
    if ($byLocale.Count -gt 0) { $row.Add([pscustomobject]$byLocale) }
    $idRows.Add(@($row))
}

$existing = ConvertFrom-Json -NoEnumerate -InputObject ([IO.File]::ReadAllText($Catalog))
$parsedRows = [Collections.Generic.List[object]]::new()
if ($existing -is [System.Collections.IList] -and $existing.Count -gt 0 -and $existing[0] -is [System.Collections.IList]) {
    foreach ($entry in $existing) { $parsedRows.Add($entry) }
} else { $parsedRows.Add($existing) }

$generatedById = @{}
foreach ($r in $idRows) {
    $key = [string]$r[0]
    if ($generatedById.ContainsKey($key)) {
        Write-Error "Anchor manifest repeats file id '$key'." -ErrorAction Continue
        exit 2
    }
    $generatedById[$key] = $r
}

# Published ids absent from the localized index remain public addresses.
# Validate before writing so a collision cannot delete or retarget a key.
$kept = [Collections.Generic.List[object]]::new()
$publishedById = @{}
try {
    foreach ($r in $parsedRows) {
        $keys = @($r[0])
        $fileIds = @($keys | Where-Object { [string]$_ -cmatch '^42[0-9a-f]{6}$' })
        $generated = $null
        foreach ($key in $fileIds) {
            if ($publishedById.ContainsKey($key)) { throw "Catalog repeats published file id '$key'." }
            $publishedById[$key] = $r
            if ($generatedById.ContainsKey($key)) {
                $generated = $generatedById[$key]
                $urls = @($r[2])
                if ($urls.Count -ne 1 -or [string]$urls[0] -cne [string]$generated[2]) {
                    throw "Published file id '$key' would change its document target to '$($generated[2])'."
                }
                if ($fileIds.Count -ne 1) { throw "Published row '$key' aliases multiple file ids." }
                $generated[0] = $r[0]
            }
            foreach ($url in @($r[2])) {
                $target = [regex]::Match([string]$url,
                    '^https://github\.com/[^/]+/(yuruna|yuruna-project)/blob/main/(docs/sbom/[^?#\s]+\.md)(?:#[^\s]*)?$')
                if (-not $target.Success) { continue }
                foreach ($otherUrl in @($r[2])) {
                    $otherTarget = [regex]::Match([string]$otherUrl,
                        '^https://github\.com/[^/]+/(yuruna|yuruna-project)/blob/main/(docs/sbom/[^?#\s]+\.md)(?:#[^\s]*)?$')
                    if (-not $otherTarget.Success -or
                        $otherTarget.Groups[1].Value -cne $target.Groups[1].Value -or
                        $otherTarget.Groups[2].Value -cne $target.Groups[2].Value) {
                        throw "Published SBOM file id '$key' has conflicting document targets."
                    }
                }
                $documentRoot = if ($target.Groups[1].Value -eq 'yuruna') { $RepoRoot } else { Join-Path $Parent 'yuruna-project' }
                $sbomRoot = [IO.Path]::GetFullPath((Join-Path $documentRoot 'docs/sbom')) + [IO.Path]::DirectorySeparatorChar
                $full = [IO.Path]::GetFullPath((Join-Path $documentRoot $target.Groups[2].Value))
                if (-not $full.StartsWith($sbomRoot, [StringComparison]::Ordinal) -or
                    -not (Test-Path -LiteralPath $full -PathType Leaf)) {
                    throw "Published SBOM file id '$key' has no local document at '$($target.Groups[2].Value)'."
                }
                $ids = @(Get-LocalSbomAnchorId -LiteralPath $full)
                if ($ids.Count -eq 0 -or @($ids | Where-Object {
                            -not $_.StartsWith($key + '-', [StringComparison]::Ordinal) }).Count -gt 0) {
                    throw "Published SBOM file id '$key' has missing or mismatched local anchors."
                }
            }
        }
        if (-not $generated) { $kept.Add($r) }
    }
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 2
}

$merged = [Collections.Generic.List[object]]::new()
foreach ($r in $idRows) { $merged.Add($r) }
foreach ($r in $kept) { $merged.Add($r) }

# One row per line is the shape the file already has, and it keeps a diff
# readable when a single URL changes.
$lines = [Collections.Generic.List[string]]::new()
foreach ($r in ($merged | Sort-Object { $key = if (@($_[0]).Count -gt 1) { [string](@($_[0])[0]) } else { [string]$_[0] }; $key })) {
    $lines.Add((ConvertTo-Json -InputObject $r -Depth 6 -Compress))
}
$json = "[`n" + ($lines -join ",`n") + "`n]`n"

$current = [IO.File]::ReadAllText($Catalog)
if ($current -ceq $json) {
    Write-Output "Update-LinkCatalog: catalog already carries $($idRows.Count) id row(s)."
    exit 0
}

if ($Update) {
    if ($PSCmdlet.ShouldProcess($Catalog, "write $($idRows.Count) id row(s)")) {
        [IO.File]::WriteAllText($Catalog, $json, [Text.UTF8Encoding]::new($false))
    }
    Write-Output "Update-LinkCatalog: wrote $($idRows.Count) id row(s) beside $($kept.Count) existing row(s)."
    exit 1
}

Write-Output "Update-LinkCatalog: would write $($idRows.Count) id row(s) beside $($kept.Count) existing row(s)."
exit 1
