<#PSScriptInfo
.VERSION 2026.09.13
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

    Rows the redirector already had are preserved untouched, and the file
    stays sorted the way its README says it is kept. Only rows whose key is
    a file id are this script's to own; a hand-written slug row is never
    rewritten or removed.

    Exit codes follow the entry-point contract:
        0  The catalog already carries the current rows.
        1  Rows were written, or would be (default).
        2  The anchor manifest or the sibling catalog is missing.

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

$existing = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Catalog))
$parsedRows = if ($existing -is [System.Collections.IList] -and $existing.Count -gt 0 -and
                   $existing[0] -is [System.Collections.IList]) { $existing } else { , $existing }

# Everything that is not a file-id row stays exactly as it was.
$kept = [Collections.Generic.List[object]]::new()
foreach ($r in $parsedRows) {
    $key = if (@($r[0]).Count -gt 1) { [string](@($r[0])[0]) } else { [string]$r[0] }
    if ($key -match '^42[0-9a-f]{6}$') { continue }
    $kept.Add($r)
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
