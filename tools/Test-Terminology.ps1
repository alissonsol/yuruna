<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42d6b0f7-8b28-44dd-9e89-c3a26a7d82f1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate globalization terminology style-guide
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
    Validate the terminology and style-guide sources of every locale that has
    them.
.DESCRIPTION
    Each locale's terminology is derived from docs/definition.md and the four
    prose vocabulary rulings inside the pre-commit hook's retired-name block.
    This gate checks the shape of those sources and nothing about who wrote
    them: a terminology file carries no approval, and the commit that lands it
    is its record.

    Per locale it checks: both files against their schemas; the eleven
    required terms, each named once; every heading a term cites still present
    in docs/definition.md; a retained term carrying no second spelling; exactly
    the four protected rulings, each an exact pair of the hook's one
    retired_names block, so the hook's English search literals stay out of the
    translation fields; the required style rule ids, each named once; and a
    document manifest that maps either none of the locale's documents or the
    whole thirteen-document subset.

    Findings are prefixed with the locale tag.

    Exit codes:
        0  Every checked locale is valid.
        1  An artifact is missing or invalid, or a rule above is broken.
        2  An input needed to evaluate the artifacts is unavailable.
.PARAMETER Root
    Repository root. Defaults to the parent of this tool's directory.
.PARAMETER Locale
    Locale tags to check. Default: every tag for which
    globalization/terminology/<tag>.terms.json or <tag>.style-guide.json
    exists, in ordinal order; a tag with only one of the two is a finding.
.PARAMETER TerminologyPath
    One terminology artifact to check instead of the per-locale discovery,
    together with -StyleGuidePath. Relative paths are resolved from Root.
.PARAMETER StyleGuidePath
    The style-guide artifact paired with -TerminologyPath. Relative paths are
    resolved from Root.
.PARAMETER DefinitionPath
    English definition source. Relative paths are resolved from Root. Default:
    docs/definition.md.
.PARAMETER HookPath
    Hook carrying the retired-name vocabulary. Relative paths are resolved
    from Root. Default: tools/githooks/pre-commit.
.PARAMETER DocManifestPath
    The document translation manifest. Relative paths are resolved from Root.
    Default: globalization/manifests/doc-translations.json.
.PARAMETER Quiet
    Print only findings and the summary line, not one line per locale.

.EXAMPLE
    pwsh tools/Test-Terminology.ps1
    Checks every locale that has terminology files.

.EXAMPLE
    pwsh tools/Test-Terminology.ps1 -Locale pt-BR -Quiet
    Checks one locale and prints only the summary.
#>

[CmdletBinding()]
[OutputType([string])]
param(
    [string]$Root,
    [string[]]$Locale,
    [string]$TerminologyPath,
    [string]$StyleGuidePath,
    [string]$DefinitionPath,
    [string]$HookPath,
    [string]$DocManifestPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)

if (($TerminologyPath -or $StyleGuidePath) -and $Locale) {
    throw 'Give -Locale or explicit artifact paths, not both.'
}
# pwsh -File binds a comma-joined list as one string.
$Locale = [string[]]@($Locale | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

function Get-RootedPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)

    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Root $Path))
}

if (-not $DefinitionPath) { $DefinitionPath = 'docs/definition.md' }
if (-not $HookPath) { $HookPath = 'tools/githooks/pre-commit' }
if (-not $DocManifestPath) { $DocManifestPath = 'globalization/manifests/doc-translations.json' }

$DefinitionPath = Get-RootedPath -Path $DefinitionPath
$HookPath = Get-RootedPath -Path $HookPath
$DocManifestPath = Get-RootedPath -Path $DocManifestPath
$terminologyDirectory = Join-Path $Root 'globalization/terminology'
$terminologySchemaPath = Join-Path $Root 'globalization/schema/terminology.schema.json'
$styleGuideSchemaPath = Join-Path $Root 'globalization/schema/style-guide.schema.json'

# One pair per locale: the tag, its terms file and its style guide.
$pairs = [Collections.Generic.List[object]]::new()
if ($TerminologyPath -or $StyleGuidePath) {
    if (-not $TerminologyPath) { $TerminologyPath = 'globalization/terminology/pt-BR.terms.json' }
    if (-not $StyleGuidePath) { $StyleGuidePath = 'globalization/terminology/pt-BR.style-guide.json' }
    $TerminologyPath = Get-RootedPath -Path $TerminologyPath
    $pairs.Add([pscustomobject]@{
            Tag = ([IO.Path]::GetFileName($TerminologyPath) -replace '\.terms\.json$', '')
            Terms = $TerminologyPath
            Style = Get-RootedPath -Path $StyleGuidePath
        })
} else {
    if ($Locale.Count -eq 0 -and [IO.Directory]::Exists($terminologyDirectory)) {
        # Either file names the locale, so a half-written pair is reported as
        # the missing file rather than skipped unchecked.
        $found = [string[]]@([IO.Directory]::GetFiles($terminologyDirectory, '*.json') |
                ForEach-Object { [IO.Path]::GetFileName($_) } |
                Where-Object { $_ -match '^(?<tag>.+)\.(terms|style-guide)\.json$' } |
                ForEach-Object { $_ -replace '\.(terms|style-guide)\.json$', '' } |
                Select-Object -Unique)
        # Ordinal: the summary line is compared byte for byte by a reference
        # capture, and a culture-aware sort would order tags differently on
        # some hosts.
        [Array]::Sort($found, [StringComparer]::Ordinal)
        $Locale = $found
    }
    foreach ($tag in $Locale) {
        $pairs.Add([pscustomobject]@{
                Tag = $tag
                Terms = Join-Path $terminologyDirectory "$tag.terms.json"
                Style = Join-Path $terminologyDirectory "$tag.style-guide.json"
            })
    }
}

$evaluationInput = [ordered]@{
    'definition source' = $DefinitionPath
    'retired-name hook' = $HookPath
    'document manifest' = $DocManifestPath
    'terminology schema' = $terminologySchemaPath
    'style-guide schema' = $styleGuideSchemaPath
}
$unavailable = @($evaluationInput.GetEnumerator() | Where-Object {
        -not (Test-Path -LiteralPath $_.Value -PathType Leaf)
    })
if ($unavailable.Count -gt 0 -or $pairs.Count -eq 0) {
    foreach ($entry in $unavailable) {
        Write-Output "Test-Terminology: $($entry.Key) is unavailable: $($entry.Value)"
    }
    if ($pairs.Count -eq 0) {
        Write-Output "Test-Terminology: terminology directory is unavailable: $terminologyDirectory"
    }
    exit 2
}
if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) {
    Write-Output 'Test-Terminology: Test-Json is unavailable, so the artifact schemas cannot be evaluated.'
    exit 2
}

$script:Findings = [Collections.Generic.List[string]]::new()
$script:FindingPrefix = ''

function Add-Finding {
    param([Parameter(Mandatory)][string]$Message)
    $script:Findings.Add($script:FindingPrefix + $Message)
}

function Read-JsonArtifact {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$SchemaPath
    )

    try {
        $raw = [IO.File]::ReadAllText($Path)
        $value = ConvertFrom-Json -InputObject $raw
    } catch {
        Add-Finding "$Label is not valid JSON: $($_.Exception.Message)"
        return $null
    }
    try {
        if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
            Add-Finding "$Label does not satisfy $([IO.Path]::GetFileName($SchemaPath))"
            return $null
        }
    } catch {
        Add-Finding "$Label schema validation failed: $($_.Exception.Message)"
        return $null
    }
    return $value
}

function Get-RetiredNamePair {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)

    $text = [IO.File]::ReadAllText($Path)
    $blockMatches = [regex]::Matches($text, '(?ms)^retired_names=''' + "\r?\n" + '(?<body>.*?)^''' + "\r?$" )
    if ($blockMatches.Count -ne 1) {
        Add-Finding "retired-name hook has $($blockMatches.Count) retired_names blocks; expected exactly one"
        return $null
    }

    $pairs = [Collections.Generic.List[object]]::new()
    foreach ($line in @($blockMatches[0].Groups['body'].Value -split '\r?\n')) {
        if (-not $line) { continue }
        $separator = $line.IndexOf('|', [StringComparison]::Ordinal)
        if ($separator -le 0 -or $separator -eq $line.Length - 1 -or
            $line.IndexOf('|', $separator + 1) -ge 0) {
            Add-Finding "retired-name hook has a malformed pair: '$line'"
            continue
        }
        $pairs.Add([pscustomobject]@{
                retired = $line.Substring(0, $separator)
                current = $line.Substring($separator + 1)
            })
    }
    return , $pairs.ToArray()
}

$requiredTerms = @('host', 'guest', 'pool', 'cycle', 'workload', 'component', 'resource',
    'stash', 'pause', 'drain', 'cache')
$expectedRulings = @(
    [pscustomobject]@{ retired = 'status server'; current = 'status service' },
    [pscustomobject]@{ retired = 'stash appliance'; current = 'stash service' },
    [pscustomobject]@{ retired = 'HostConfigService'; current = 'ConfigService' },
    [pscustomobject]@{ retired = 'stash-server'; current = 'stash-service' }
)
$requiredRules = @('terminology', 'tone', 'punctuation-capitalization',
    'commands-files-identifiers', 'keyboard-shortcuts', 'numbers-dates-times-zones',
    'measurement-units', 'placeholders', 'inclusive-accessible-language',
    'machine-matched-literals')

$definitionText = [IO.File]::ReadAllText($DefinitionPath)
$retiredPairs = Get-RetiredNamePair -Path $HookPath
$docManifest = $null
try { $docManifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($DocManifestPath)) }
catch { Add-Finding "document manifest is not valid JSON: $($_.Exception.Message)" }
if ($docManifest -and $docManifest.schema -ne 'yuruna.doc-translations/v1') {
    Add-Finding "document manifest has unsupported schema '$($docManifest.schema)'"
}

$termTotal = $rulingTotal = $ruleTotal = 0
$detail = [Collections.Generic.List[string]]::new()
foreach ($pair in $pairs) {
    $tag = $pair.Tag
    $script:FindingPrefix = "${tag}: "
    $termCount = $rulingCount = $ruleCount = 0

    $present = $true
    foreach ($artifact in ([ordered]@{
            'terminology artifact' = $pair.Terms
            'style-guide artifact' = $pair.Style
        }).GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $artifact.Value -PathType Leaf)) {
            Add-Finding "$($artifact.Key) is missing: $($artifact.Value)"
            $present = $false
        }
    }
    if (-not $present) { continue }

    $terminology = Read-JsonArtifact -Path $pair.Terms -Label 'terminology artifact' -SchemaPath $terminologySchemaPath
    $styleGuide = Read-JsonArtifact -Path $pair.Style -Label 'style-guide artifact' -SchemaPath $styleGuideSchemaPath

    if ($terminology) {
        $termCount = @($terminology.terms).Count
        $rulingCount = @($terminology.retiredNameRulings).Count
        $sourceTerms = @($terminology.terms | ForEach-Object { [string]$_.sourceTerm })
        foreach ($required in $requiredTerms) {
            if ($sourceTerms -cnotcontains $required) {
                Add-Finding "required baseline term is missing: $required"
            }
        }
        foreach ($duplicate in @($sourceTerms | Group-Object | Where-Object Count -GT 1)) {
            Add-Finding "terminology source repeats term '$($duplicate.Name)'"
        }
        foreach ($term in @($terminology.terms)) {
            foreach ($heading in @($term.sourceHeadings)) {
                $pattern = '(?m)^#{1,6}\s+' + [regex]::Escape([string]$heading) + '\s*$'
                if ($definitionText -notmatch $pattern) {
                    Add-Finding "term '$($term.sourceTerm)' references a missing definition heading: $heading"
                }
            }
            if ($term.decision.status -eq 'retained' -and
                $term.decision.PSObject.Properties.Name -contains 'targetTerm') {
                Add-Finding "retained term '$($term.sourceTerm)' must inherit the exact source term, not carry a second spelling"
            }
        }

        if ($rulingCount -ne $expectedRulings.Count) {
            Add-Finding "terminology source must carry exactly $($expectedRulings.Count) retired-name prose rulings"
        } else {
            for ($i = 0; $i -lt $expectedRulings.Count; $i++) {
                $actual = $terminology.retiredNameRulings[$i]
                $expected = $expectedRulings[$i]
                if ([string]$actual.retired -cne $expected.retired -or
                    [string]$actual.current -cne $expected.current) {
                    Add-Finding "retired-name ruling $($i + 1) changed or moved; expected '$($expected.retired)|$($expected.current)'"
                }
                if ([string]$actual.translationPolicy -cne 'preserve-exact-english') {
                    Add-Finding "retired-name ruling '$($actual.retired)|$($actual.current)' no longer protects its exact English literals"
                }
                if ($null -ne $retiredPairs) {
                    $exists = @($retiredPairs | Where-Object {
                            $_.retired -ceq $expected.retired -and $_.current -ceq $expected.current
                        }).Count -eq 1
                    if (-not $exists) {
                        Add-Finding "retired-name ruling is not an exact hook pair: '$($expected.retired)|$($expected.current)'"
                    }
                }
            }
        }
    }

    if ($styleGuide) {
        $ruleIds = @($styleGuide.rules | ForEach-Object { [string]$_.id })
        $ruleCount = $ruleIds.Count
        foreach ($required in $requiredRules) {
            if ($ruleIds -cnotcontains $required) { Add-Finding "required style rule is missing: $required" }
        }
        foreach ($duplicate in @($ruleIds | Group-Object | Where-Object Count -GT 1)) {
            Add-Finding "style guide repeats rule '$($duplicate.Name)'"
        }
    }

    if ($docManifest) {
        $mapped = @($docManifest.documents | Where-Object { [string]$_.locale -ceq $tag }).Count
        if ($mapped -ne 0 -and $mapped -ne 13) {
            Add-Finding "document manifest maps $mapped documents; a locale maps either none or the 13-document subset"
        }
    }

    $termTotal += $termCount
    $rulingTotal += $rulingCount
    $ruleTotal += $ruleCount
    $detail.Add("Test-Terminology [$tag]: $termCount term(s), $rulingCount protected ruling(s), $ruleCount style rule(s).")
}

$tags = @($pairs | ForEach-Object Tag) -join ', '
$counts = "$termTotal term(s), $rulingTotal protected ruling(s), $ruleTotal style rule(s)."
if (-not $Quiet) {
    foreach ($line in $detail) { Write-Output $line }
}
if ($script:Findings.Count -gt 0) {
    foreach ($finding in $script:Findings) { Write-Output "FINDING: $finding" }
    Write-Output "Test-Terminology: $($script:Findings.Count) finding(s); $tags; $counts"
    exit 1
}
Write-Output "Test-Terminology: $tags; $counts"
exit 0
