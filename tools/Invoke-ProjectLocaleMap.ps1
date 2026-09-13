<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42d9c4d7-98cf-45ca-b32b-026a805da91a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization project locale map source hash reviewer
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Validate project-authored display locale maps and their source hashes.
.DESCRIPTION
    The normal mode is read-only. It finds displayNameLocalized and
    descriptionLocalized beside their required English scalars, validates a
    normalized record with the checked-in JSON Schema, requires canonical
    bounded locale tags and values, and compares each translation with the
    scalar hash recorded by path, field path and locale.

    A source edit cannot bless its own translation. The only write mode is
    -AcceptReviewedTranslation, which requires an exact path/field/locale,
    reviewer and review date and advances only that sidecar row.
.PARAMETER ProjectRoot
    Project checkout or staged public project tree.
.PARAMETER AcceptReviewedTranslation
    Explicitly accept one translation against its current English scalar.
.PARAMETER PseudoFixturePath
    Write a deterministic test-only fixture whose qps-Ploc and qps-Plocm map
    values are derived from the current official English scalars. The fixture
    is written only after the maps and source-hash sidecar pass validation; it
    never copies or promotes an unreviewed translation.
.EXAMPLE
    pwsh tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot ../yuruna-project -Quiet
.EXAMPLE
    pwsh tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot ../yuruna-project
      -AcceptReviewedTranslation -ProjectPath test/test.runner.yml
      -FieldPath /testSets/name=smoke/displayName -Locale pt-BR
      -Reviewer 'Reviewer name' -ReviewedAt 2026-09-03
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Check')]
param(
    [string]$ProjectRoot,
    [string]$SidecarPath,
    [switch]$Quiet,
    [Parameter(ParameterSetName = 'Check')][string]$PseudoFixturePath,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][switch]$AcceptReviewedTranslation,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][string]$ProjectPath,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][string]$FieldPath,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][string]$Locale,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][string]$Reviewer,
    [Parameter(Mandatory, ParameterSetName = 'Accept')][ValidatePattern('^[0-9]{4}-[0-9]{2}-[0-9]{2}$')][string]$ReviewedAt
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }
if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    Write-Output "Invoke-ProjectLocaleMap: project root not found: $ProjectRoot"
    exit 2
}
if (-not $SidecarPath) { $SidecarPath = Join-Path $ProjectRoot 'globalization/project-locale-source-hashes.json' }

$mapSchema = Join-Path $RepoRoot 'globalization/schema/project-locale-map.schema.json'
$sidecarSchema = Join-Path $RepoRoot 'globalization/schema/project-locale-source-hashes.schema.json'
foreach ($required in @($mapSchema, $sidecarSchema)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-Output "Invoke-ProjectLocaleMap: required schema not found: $required"
        exit 2
    }
}

if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    try { Import-Module powershell-yaml -ErrorAction Stop }
    catch {
        Write-Output 'Invoke-ProjectLocaleMap: powershell-yaml is unavailable; project YAML cannot be validated.'
        exit 2
    }
}

$script:Finding = [Collections.Generic.List[string]]::new()
$script:Map = [Collections.Generic.List[object]]::new()
$script:Expected = [ordered]@{}

function Add-MapFinding {
    param([Parameter(Mandatory)][string]$Message)
    $script:Finding.Add($Message)
}

function Test-Dictionary {
    param([AllowNull()]$Value)
    return $Value -is [System.Collections.IDictionary]
}

function Get-DictionaryValue {
    param([Parameter(Mandatory)]$Dictionary, [Parameter(Mandatory)][string]$Key)
    if ($Dictionary -is [System.Collections.IDictionary]) { return $Dictionary[$Key] }
    return $null
}

function Test-DictionaryKey {
    param([Parameter(Mandatory)]$Dictionary, [Parameter(Mandatory)][string]$Key)
    return ($Dictionary -is [System.Collections.IDictionary] -and $Dictionary.Contains($Key))
}

function Get-ProjectUnicodeScalarCount {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $count = 0
    foreach ($rune in $Text.EnumerateRunes()) { $count++ }
    return $count
}

function ConvertTo-CanonicalProjectTag {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Tag)
    $text = $Tag.Trim() -replace '_', '-'
    if (-not $text -or $text.Length -gt 35 -or $text -cnotmatch '^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$') { return '' }
    $parts = $text.Split('-')
    $out = $parts[0].ToLowerInvariant()
    for ($i = 1; $i -lt $parts.Count; $i++) {
        if ($parts[$i].Length -eq 2) { $out += '-' + $parts[$i].ToUpperInvariant() }
        elseif ($parts[$i].Length -eq 4) {
            $out += '-' + $parts[$i].Substring(0, 1).ToUpperInvariant() + $parts[$i].Substring(1).ToLowerInvariant()
        } else { $out += '-' + $parts[$i].ToLowerInvariant() }
    }
    return $out
}

function ConvertTo-PointerSegment {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return $Value.Replace('~', '~0').Replace('/', '~1')
}

function Get-ScalarSourceHash {
    param([Parameter(Mandatory)][string]$Scalar)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Scalar.Normalize([Text.NormalizationForm]::FormC))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$script:PseudoMap = @{
    'a' = ([char]0x00E1).ToString(); 'b' = ([char]0x0180).ToString(); 'c' = ([char]0x00E7).ToString()
    'd' = ([char]0x010F).ToString(); 'e' = ([char]0x00E9).ToString(); 'f' = ([char]0x0192).ToString()
    'g' = ([char]0x011F).ToString(); 'h' = ([char]0x0127).ToString(); 'i' = ([char]0x00ED).ToString()
    'j' = ([char]0x0135).ToString(); 'k' = ([char]0x0137).ToString(); 'l' = ([char]0x013C).ToString()
    'm' = ([char]0x0271).ToString(); 'n' = ([char]0x00F1).ToString(); 'o' = ([char]0x00F3).ToString()
    'p' = ([char]0x01A5).ToString(); 'q' = ([char]0x02A0).ToString(); 'r' = ([char]0x0159).ToString()
    's' = ([char]0x0161).ToString(); 't' = ([char]0x0163).ToString(); 'u' = ([char]0x00FA).ToString()
    'v' = ([char]0x1E7D).ToString(); 'w' = ([char]0x0175).ToString(); 'x' = ([char]0x1E8B).ToString()
    'y' = ([char]0x00FD).ToString(); 'z' = ([char]0x017E).ToString()
}

$script:PseudoProtected = [regex]::new(
    '^(?:\{[A-Za-z][A-Za-z0-9]*\}|<[^>]+>|https?://[^\s]+|(?:Ctrl|Alt|Shift|Cmd|Command|Option)(?:\+[A-Za-z0-9]+)+|(?:[A-Za-z0-9_-]+\.)+[A-Za-z0-9_-]+|/[A-Za-z0-9_./-]+)',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant)

function ConvertTo-ProjectPseudoText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [switch]$Mirrored)

    $out = [Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $protected = $script:PseudoProtected.Match($Text.Substring($i))
        if ($protected.Success) {
            [void]$out.Append($protected.Value)
            $i += $protected.Length
            continue
        }
        $character = [string]$Text[$i]
        $lower = $character.ToLowerInvariant()
        if ($script:PseudoMap.ContainsKey($lower)) {
            $mapped = $script:PseudoMap[$lower]
            if ($character -cne $lower) { $mapped = $mapped.ToUpperInvariant() }
            [void]$out.Append($mapped)
        } else {
            [void]$out.Append($character)
        }
        $i++
    }

    $pad = '~' * [Math]::Max(1, [int][Math]::Ceiling($Text.Length * 0.4))
    if ($Mirrored) { return "[!$([char]0x202E)$out$([char]0x202C) $pad]" }
    return "[$out $pad]"
}

function Add-NormalizedMap {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ObjectPath,
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][ValidateSet('displayName', 'description')][string]$ScalarField
    )

    $mapKey = $ScalarField + 'Localized'
    if (-not (Test-DictionaryKey -Dictionary $Node -Key $mapKey)) { return }
    $fieldPath = $ObjectPath + '/' + (ConvertTo-PointerSegment $ScalarField)
    $label = "$RelativePath#$fieldPath"
    if (-not (Test-DictionaryKey -Dictionary $Node -Key $ScalarField)) {
        Add-MapFinding "$label has $mapKey without its required English scalar"
        return
    }
    $scalarValue = Get-DictionaryValue -Dictionary $Node -Key $ScalarField
    if ($scalarValue -isnot [string] -or [string]::IsNullOrWhiteSpace($scalarValue)) {
        Add-MapFinding "$label English scalar is not a non-empty string"
        return
    }
    $max = if ($ScalarField -eq 'displayName') { 160 } else { 2000 }
    $scalar = $scalarValue.Normalize([Text.NormalizationForm]::FormC)
    if ((Get-ProjectUnicodeScalarCount -Text $scalar) -gt $max) {
        Add-MapFinding "$label English scalar exceeds the $max Unicode-scalar bound"
        return
    }
    $localized = Get-DictionaryValue -Dictionary $Node -Key $mapKey
    if (-not (Test-Dictionary -Value $localized)) {
        Add-MapFinding "$label $mapKey is not a locale map"
        return
    }
    $keys = @($localized.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    if ($keys.Count -lt 1 -or $keys.Count -gt 16) {
        Add-MapFinding "$label $mapKey has $($keys.Count) entries; the bound is 1..16"
        return
    }
    $normalized = [ordered]@{}
    foreach ($tag in $keys) {
        $canonical = ConvertTo-CanonicalProjectTag -Tag $tag
        if (-not $canonical) {
            Add-MapFinding "$label locale '$tag' is not a bounded BCP 47 tag"
            continue
        }
        if ($tag -cne $canonical) {
            Add-MapFinding "$label locale '$tag' is not canonical; write '$canonical'"
            continue
        }
        if ($canonical -ceq 'en-US') {
            Add-MapFinding "$label declares en-US in the map; English belongs only in the scalar"
            continue
        }
        $value = Get-DictionaryValue -Dictionary $localized -Key $tag
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            Add-MapFinding "$label locale '$tag' is not a non-empty string within $max characters"
            continue
        }
        $normalizedValue = $value.Normalize([Text.NormalizationForm]::FormC)
        if ((Get-ProjectUnicodeScalarCount -Text $normalizedValue) -gt $max) {
            Add-MapFinding "$label locale '$tag' is not a non-empty string within $max Unicode scalars"
            continue
        }
        $normalized[$canonical] = $normalizedValue
        $identity = "$RelativePath|$fieldPath|$canonical"
        if ($script:Expected.Contains($identity)) {
            Add-MapFinding "$label locale '$canonical' has duplicate path/field/locale identity"
            continue
        }
        $script:Expected[$identity] = [ordered]@{
            path = $RelativePath
            fieldPath = $fieldPath
            locale = $canonical
            sourceHash = Get-ScalarSourceHash -Scalar $scalar
        }
    }

    $record = [ordered]@{
        schema = 'yuruna.project-locale-map/v1'
        path = $RelativePath
        fieldPath = $fieldPath
        scalarField = $ScalarField
        scalar = $scalar
        localized = $normalized
    }
    try {
        $json = $record | ConvertTo-Json -Depth 10 -Compress
        if (-not (Test-Json -Json $json -SchemaFile $mapSchema -ErrorAction Stop)) {
            Add-MapFinding "$label does not satisfy project-locale-map.schema.json"
        }
    } catch {
        Add-MapFinding "$label does not satisfy project-locale-map.schema.json: $($_.Exception.Message)"
    }
    $script:Map.Add($record)
}

function Find-ProjectMap {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ObjectPath,
        [AllowNull()]$Node
    )

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($field in @('displayName', 'description')) {
            Add-NormalizedMap -RelativePath $RelativePath -ObjectPath $ObjectPath -Node $Node -ScalarField $field
        }
        foreach ($key in @($Node.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            if ($key -in @('displayNameLocalized', 'descriptionLocalized')) { continue }
            $child = $Node[$key]
            $path = $ObjectPath + '/' + (ConvertTo-PointerSegment $key)
            Find-ProjectMap -RelativePath $RelativePath -ObjectPath $path -Node $child
        }
        return
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $index = 0
        foreach ($child in @($Node)) {
            $segment = [string]$index
            if ($child -is [System.Collections.IDictionary] -and $child.Contains('name') -and $child['name']) {
                $segment = 'name=' + (ConvertTo-PointerSegment ([string]$child['name']))
            }
            Find-ProjectMap -RelativePath $RelativePath -ObjectPath ($ObjectPath + '/' + $segment) -Node $child
            $index++
        }
    }
}

$yamlFiles = @()
$gitDir = Join-Path $ProjectRoot '.git'
if (Test-Path -LiteralPath $gitDir) {
    Push-Location $ProjectRoot
    try {
        # A pre-commit gate must see the candidate a contributor has not added
        # yet. --exclude-standard still honors the project's explicit ignored
        # and generated-file policy, while -Unique prevents a staged/working
        # path from being visited twice.
        $yamlFiles = @(& git ls-files --cached --others --exclude-standard -- '*.yml' '*.yaml' |
            Sort-Object -Unique)
    }
    finally { Pop-Location }
} else {
    $yamlFiles = @(Get-ChildItem -LiteralPath $ProjectRoot -Recurse -File -Include '*.yml', '*.yaml' |
        Sort-Object FullName | ForEach-Object { ([IO.Path]::GetRelativePath($ProjectRoot, $_.FullName)) -replace '\\', '/' })
}

foreach ($relative in $yamlFiles) {
    $full = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $text = [IO.File]::ReadAllText($full)
    # Some tracked YAML is a Helm template rather than a standalone YAML
    # document. Parse every candidate map, including quoted YAML keys, while
    # leaving unrelated template sources to their own renderer/validator.
    if ($text -notmatch '(?m)(?:^\s*|[,{]\s*)(?:["'']?(?:displayName|description)Localized["'']?)\s*:') { continue }
    try {
        $document = ConvertFrom-Yaml -Yaml $text -Ordered
        Find-ProjectMap -RelativePath ($relative -replace '\\', '/') -ObjectPath '' -Node $document
    } catch {
        Add-MapFinding "$relative cannot be parsed as YAML: $($_.Exception.Message)"
    }
}

$sidecar = $null
$acceptedSidecarJson = ''
$acceptedIdentity = ''
if (-not (Test-Path -LiteralPath $SidecarPath -PathType Leaf)) {
    if ($script:Expected.Count -gt 0) {
        Add-MapFinding "required source-hash sidecar is missing: $SidecarPath"
    } else {
        $sidecar = [ordered]@{
            schema = 'yuruna.project-locale-source-hashes/v1'
            hashAlgorithm = 'sha256-utf8-nfc-scalar-v1'
            entries = @()
        }
    }
} else {
    try {
        $sidecarText = [IO.File]::ReadAllText($SidecarPath)
        if (-not (Test-Json -Json $sidecarText -SchemaFile $sidecarSchema -ErrorAction Stop)) {
            Add-MapFinding 'the source-hash sidecar does not satisfy its schema'
        }
        $sidecar = ConvertFrom-Json -InputObject $sidecarText -AsHashtable
    } catch {
        Add-MapFinding "source-hash sidecar is invalid: $($_.Exception.Message)"
    }
}

if ($AcceptReviewedTranslation) {
    $ProjectPath = $ProjectPath -replace '\\', '/'
    $canonicalLocale = ConvertTo-CanonicalProjectTag -Tag $Locale
    if ($canonicalLocale -cne $Locale) {
        Add-MapFinding "accept locale '$Locale' is not canonical"
    }
    $identity = "$ProjectPath|$FieldPath|$canonicalLocale"
    if (-not $script:Expected.Contains($identity)) {
        Add-MapFinding "no project translation has identity $identity"
    } elseif (-not $sidecar) {
        Add-MapFinding 'the sidecar could not be read, so no review can be accepted'
    } elseif ($Reviewer.Trim().Length -eq 0) {
        Add-MapFinding 'a reviewer name is required'
    } else {
        $replacement = [ordered]@{
            path = $ProjectPath
            fieldPath = $FieldPath
            locale = $canonicalLocale
            sourceHash = $script:Expected[$identity].sourceHash
            reviewStatus = 'reviewed'
            reviewer = $Reviewer.Trim()
            reviewedAt = $ReviewedAt
        }
        $newEntries = [Collections.Generic.List[object]]::new()
        $replaced = $false
        foreach ($entry in @($sidecar.entries)) {
            $entryIdentity = "$($entry.path)|$($entry.fieldPath)|$($entry.locale)"
            if ($entryIdentity -eq $identity) {
                $newEntries.Add($replacement)
                $replaced = $true
            } else { $newEntries.Add($entry) }
        }
        if (-not $replaced) { $newEntries.Add($replacement) }
        $sidecar.entries = @($newEntries | Sort-Object { $_.path }, { $_.fieldPath }, { $_.locale })
        $json = ($sidecar | ConvertTo-Json -Depth 10).Replace("`r`n", "`n").TrimEnd() + "`n"
        try {
            if (-not (Test-Json -Json $json -SchemaFile $sidecarSchema -ErrorAction Stop)) {
                Add-MapFinding 'the candidate source-hash sidecar does not satisfy its schema'
            }
        } catch {
            Add-MapFinding "the candidate source-hash sidecar does not satisfy its schema: $($_.Exception.Message)"
        }
        if ($script:Finding.Count -eq 0) {
            # Hold the candidate in memory until the complete-sidecar pass
            # below proves uniqueness, no orphans, no missing rows and no stale
            # sibling. A failed acceptance must leave the authority bytes alone.
            $acceptedSidecarJson = $json
            $acceptedIdentity = $identity
        }
    }
}

if ($sidecar) {
    $seen = @{}
    foreach ($entry in @($sidecar.entries)) {
        $identity = "$($entry.path)|$($entry.fieldPath)|$($entry.locale)"
        if ($seen.ContainsKey($identity)) {
            Add-MapFinding "source-hash sidecar repeats $identity"
            continue
        }
        $seen[$identity] = $true
        if (-not $script:Expected.Contains($identity)) {
            Add-MapFinding "source-hash sidecar has no matching project map for $identity"
            continue
        }
        $expectedHash = [string]$script:Expected[$identity].sourceHash
        if ([string]$entry.sourceHash -cne $expectedHash) {
            Add-MapFinding "$identity is stale; expected sourceHash $expectedHash"
        }
    }
    foreach ($identity in $script:Expected.Keys) {
        if (-not $seen.ContainsKey($identity)) {
            Add-MapFinding "source-hash sidecar has no row for $identity"
        }
    }
}

if ($acceptedSidecarJson -and $script:Finding.Count -eq 0 -and
    $PSCmdlet.ShouldProcess($acceptedIdentity, 'accept translation against current English scalar')) {
    $parent = Split-Path -Parent $SidecarPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$SidecarPath.tmp"
    [IO.File]::WriteAllText($temp, $acceptedSidecarJson, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $SidecarPath -Force
    if (-not $Quiet) { Write-Output "ACCEPTED $acceptedIdentity" }
}

if ($PseudoFixturePath -and $script:Finding.Count -eq 0) {
    $fixtureEntries = [Collections.Generic.List[object]]::new()
    foreach ($mapRecord in @($script:Map | Sort-Object { $_.path }, { $_.fieldPath })) {
        $localized = [ordered]@{
            'qps-Ploc' = ConvertTo-ProjectPseudoText -Text ([string]$mapRecord.scalar)
            'qps-Plocm' = ConvertTo-ProjectPseudoText -Text ([string]$mapRecord.scalar) -Mirrored
        }
        $normalized = [ordered]@{
            schema = 'yuruna.project-locale-map/v1'
            path = [string]$mapRecord.path
            fieldPath = [string]$mapRecord.fieldPath
            scalarField = [string]$mapRecord.scalarField
            scalar = [string]$mapRecord.scalar
            localized = $localized
        }
        try {
            $normalizedJson = $normalized | ConvertTo-Json -Depth 10 -Compress
            if (-not (Test-Json -Json $normalizedJson -SchemaFile $mapSchema -ErrorAction Stop)) {
                Add-MapFinding "$($mapRecord.path)#$($mapRecord.fieldPath) produced an invalid pseudo locale map"
                continue
            }
        } catch {
            Add-MapFinding "$($mapRecord.path)#$($mapRecord.fieldPath) produced an invalid pseudo locale map: $($_.Exception.Message)"
            continue
        }
        $fixtureEntries.Add([ordered]@{
            path = $normalized.path
            fieldPath = $normalized.fieldPath
            scalarField = $normalized.scalarField
            scalar = $normalized.scalar
            sourceHash = Get-ScalarSourceHash -Scalar $normalized.scalar
            localized = $normalized.localized
        })
    }

    if ($script:Finding.Count -eq 0) {
        $fixture = [ordered]@{
            schema = 'yuruna.project-locale-pseudo-fixture/v1'
            hashAlgorithm = 'sha256-utf8-nfc-scalar-v1'
            locales = @('qps-Ploc', 'qps-Plocm')
            entries = @($fixtureEntries)
        }
        $fixtureJson = ($fixture | ConvertTo-Json -Depth 10).Replace("`r`n", "`n").TrimEnd() + "`n"
        if ($PSCmdlet.ShouldProcess($PseudoFixturePath, 'write ephemeral project pseudo-locale fixture')) {
            $fixtureParent = Split-Path -Parent $PseudoFixturePath
            if ($fixtureParent -and -not (Test-Path -LiteralPath $fixtureParent)) {
                New-Item -ItemType Directory -Path $fixtureParent -Force | Out-Null
            }
            $fixtureTemp = "$PseudoFixturePath.tmp"
            [IO.File]::WriteAllText($fixtureTemp, $fixtureJson, [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $fixtureTemp -Destination $PseudoFixturePath -Force
            if (-not $Quiet) { Write-Output "WROTE $PseudoFixturePath" }
        }
    }
}

foreach ($finding in $script:Finding) { Write-Output "FINDING: $finding" }
Write-Output "Invoke-ProjectLocaleMap: $($script:Map.Count) map(s), $($script:Expected.Count) translation(s), $($script:Finding.Count) finding(s)."
if ($script:Finding.Count -gt 0) { exit 1 }
exit 0
