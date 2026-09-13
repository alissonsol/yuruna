<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b6f7e1-08a5-4d37-b2c9-6f0a314e8d75
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization project utf8 encoding normalization gate
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
    Prove every inventoried project map and document is normalized UTF-8
    without a byte-order mark.
.DESCRIPTION
    ReadAllText accepts a BOM, replaces malformed input in common overloads,
    and says nothing about Unicode normalization.  Those defaults make two
    files that look identical produce different hashes and let a corrupt
    translation pass an ordinary content check.  This gate reads exact bytes
    with a throwing decoder, rejects a BOM, U+FFFD, and stray controls, and
    requires NFC.

    The paths come from the checked domain inventory.  Reachable project YAML
    is independently reverse-discovered from the tracked and untracked Git
    candidate so deleting an inventory row cannot make the gate check less and
    still pass before the next commit.
.PARAMETER ProjectRoot
    Project checkout to inspect. Defaults to the sibling yuruna-project.
.PARAMETER InventoryManifest
    Recorded domain inventory. Defaults to the framework copy.
.PARAMETER Quiet
    Print only findings and the summary.
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$InventoryManifest,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }
if (-not $InventoryManifest) {
    $InventoryManifest = Join-Path $RepoRoot 'globalization/manifests/domain-inventory.json'
}

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    Write-Output "Test-ProjectTextEncoding: project checkout not found at $ProjectRoot."
    exit 2
}
if (-not (Test-Path -LiteralPath $InventoryManifest -PathType Leaf)) {
    Write-Output "Test-ProjectTextEncoding: inventory not found at $InventoryManifest."
    exit 2
}

$manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($InventoryManifest))
if ($manifest.schema -ne 'yuruna.domain-inventory/v2') {
    Write-Output "FINDING: inventory schema '$($manifest.schema)' does not carry authoritative project paths."
    exit 1
}
$config = $manifest.domains | Where-Object domain -EQ 'project-config' | Select-Object -First 1
$docs = $manifest.domains | Where-Object domain -EQ 'project-docs' | Select-Object -First 1
if (-not $config -or -not $docs) {
    Write-Output 'FINDING: inventory does not contain both project-config and project-docs.'
    exit 1
}

$expectedSources = @(
    'README.md', 'template/README.md', 'example/README.md',
    'example/website/README.md', 'example/text-to-sql/README.md'
)
$expectedTargets = @(
    'docs/pt-BR/README.md', 'docs/pt-BR/template/README.md',
    'docs/pt-BR/example/README.md', 'docs/pt-BR/example/website/README.md',
    'docs/pt-BR/example/text-to-sql/README.md'
)

$findings = [Collections.Generic.List[string]]::new()
foreach ($required in $expectedSources) {
    if (@($docs.sourceDocuments) -cnotcontains $required) { $findings.Add("source document is not inventoried: $required") }
}
foreach ($required in $expectedTargets) {
    if (@($docs.translatedDocuments) -cnotcontains $required) { $findings.Add("translated document is not inventoried: $required") }
}

Push-Location $ProjectRoot
try { $trackedYaml = @(& git ls-files --cached --others --exclude-standard -- '*.yml' '*.yaml') } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) {
    Write-Output "Test-ProjectTextEncoding: git could not enumerate $ProjectRoot."
    exit 2
}
$reachableYaml = @($trackedYaml | Where-Object {
        $p = $_ -replace '\\', '/'
        $p -eq 'test/test.runner.yml' -or $p -eq 'test/test.runner.yaml' -or
        $p -match '^template/(config|test)/.+\.ya?ml$' -or
        ($p -match '^example/[^/]+/(config|test)/.+\.ya?ml$' -and $p -notmatch '^example/nested\.host/')
    } | ForEach-Object { $_ -replace '\\', '/' } | Sort-Object -Unique)
$recordedYaml = @($config.inventoryFiles | ForEach-Object { [string]$_ } | Sort-Object -Unique)
foreach ($path in $reachableYaml) {
    if ($recordedYaml -cnotcontains $path) { $findings.Add("reachable YAML is not inventoried: $path") }
}
foreach ($path in $recordedYaml) {
    if ($reachableYaml -cnotcontains $path) { $findings.Add("inventoried YAML is not a reachable candidate file: $path") }
}

$paths = @($recordedYaml + @($docs.inventoryFiles | ForEach-Object { [string]$_ }) | Sort-Object -Unique)
$decoder = [Text.UTF8Encoding]::new($false, $true)
foreach ($relative in $paths) {
    $full = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $findings.Add("inventoried text is missing: $relative")
        continue
    }
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $findings.Add("$relative starts with a UTF-8 BOM")
        continue
    }
    try { $text = $decoder.GetString($bytes) }
    catch [Text.DecoderFallbackException] {
        $findings.Add("$relative is not valid UTF-8: $($_.Exception.Message)")
        continue
    }
    if ($text.Contains([char]0xFFFD)) { $findings.Add("$relative contains the Unicode replacement character") }
    if (-not $text.IsNormalized([Text.NormalizationForm]::FormC)) {
        $findings.Add("$relative is not Unicode NFC-normalized")
    }
    for ($i = 0; $i -lt $text.Length; $i++) {
        $code = [int]$text[$i]
        if ($code -lt 0x20 -and $code -notin @(9, 10, 13)) {
            $findings.Add(("{0} contains control character U+{1:X4} at index {2}" -f `
                    $relative, $code, $i))
            break
        }
    }
}

if ($findings.Count -gt 0) {
    foreach ($finding in $findings) { Write-Output "FINDING: $finding" }
    Write-Output "Test-ProjectTextEncoding: $($findings.Count) finding(s) across $($paths.Count) inventoried file(s)."
    exit 1
}
if (-not $Quiet) {
    Write-Output "Test-ProjectTextEncoding: $($paths.Count) inventoried file(s) are clean normalized UTF-8 without BOM."
}
exit 0
