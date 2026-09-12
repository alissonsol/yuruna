<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42c1f7a0-6b2e-4d55-9f18-3ac6d0e41b72
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna ci-gate locale config template
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
    CI gate: the runner template ships `language: auto`, reconciliation carries
    it, and the configuration reference explains it.
.DESCRIPTION
    The locale resolver already treats an absent value, an empty value and
    `auto` as the same thing -- no lab-wide lock. That equivalence is what makes
    the missing key easy to dismiss, and it is why this gate exists: the seed is
    not about runtime behavior, it is about whether the knob can be reached.

    Reconciliation fills a host's file from the template, and it can only fill
    keys the template contains. A template without `language` therefore produces
    hosts whose configuration cannot mention the language at all -- the
    status-page editor renders the keys in the file, so there is nothing to
    render, and an operator has no way to discover that the lock exists. The key
    has to ship set to its own default rather than left out.

    The default has to be `auto` specifically. A template that seeded a real tag
    would lock every new host to one language on first run, and would do it
    silently, because a lock is indistinguishable from a preference until
    someone asks for a second language.

    Three things are checked:

      1. The tracked template carries a top-level `language` scalar and its
         value is `auto`. Read from the parsed document, so a commented-out key
         does not satisfy it.
      2. Reconciliation adds that key to a configuration that lacks it, and
         leaves an operator's own lock alone. This runs the real merge over the
         real template rather than restating what the merge is believed to do.
      3. The configuration reference documents the key, in its enumeration of
         top-level sections and in a section of its own that explains what
         `auto` means.

    Exit codes follow the entry-point contract (Get-EntryPointExitCode):
        0  The seed, the reconciliation behavior and the documentation agree.
        1  At least one of them is missing or wrong.
        2  The gate could not reach a verdict -- a missing template, reference
           or reconciliation module, or a template that does not parse.
.PARAMETER Root
    Repository root. Default: the parent of this script's directory. The
    reconciliation module is always loaded from here.
.PARAMETER TemplatePath
    The runner template to read instead of the tracked one. For mutation tests,
    which point the gate at a deliberately broken copy; the shipped template is
    the default and the only thing a gate run means anything about.
.PARAMETER ReferencePath
    The configuration reference to read instead of the tracked one. Same reason.
.PARAMETER Quiet
    Print only the summary line. Findings still print.
.EXAMPLE
    pwsh tools/Test-ConfigLocaleSeed.ps1
    # Checks the shipped template and reference; exits 0 / 1 / 2.
#>

[CmdletBinding()]
[OutputType([void])]
param(
    [string]$Root,
    [string]$TemplatePath,
    [string]$ReferencePath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $ToolRoot }

Import-Module (Join-Path $Root 'test/modules/Test.Prelude.psm1') -Global -Force
$ExitOk        = Get-EntryPointExitCode -Outcome Ok
$ExitFailure   = Get-EntryPointExitCode -Outcome Failure
$ExitCannotRun = Get-EntryPointExitCode -Outcome CannotRun

if (-not $TemplatePath) { $TemplatePath = Join-Path $Root 'test/test.config.yml.template' }
if (-not $ReferencePath) { $ReferencePath = Join-Path $Root 'docs/test-config.md' }
$SyncModule = Join-Path $Root 'test/modules/Test.ConfigSync.psm1'

$findings = [Collections.Generic.List[string]]::new()
function Add-Finding { param([Parameter(Mandatory)][string]$Text) $findings.Add($Text) }

# The key and its only acceptable seed value, named once so a reader sees the
# contract without reading the checks.
$LocaleKey  = 'language'
$AutoValue  = 'auto'

foreach ($required in @(
        @{ Path = $TemplatePath;  What = 'the runner configuration template' }
        @{ Path = $ReferencePath; What = 'the runner configuration reference' }
        @{ Path = $SyncModule;    What = 'the configuration reconciliation module' })) {
    if (-not (Test-Path -LiteralPath $required.Path -PathType Leaf)) {
        # Written rather than thrown: $ErrorActionPreference is Stop here, and a
        # thrown error leaves through the engine's own exit 1 -- which is the
        # verdict "the seed is wrong", not "the seed could not be read".
        Write-Error -ErrorAction Continue `
            -Message ("Cannot evaluate the locale seed: {0} is missing at {1}" -f $required.What, $required.Path)
        exit $ExitCannotRun
    }
}

Import-Module $SyncModule -Global -Force
if (-not (Get-Command -Name 'ConvertTo-MergedHashtable' -ErrorAction SilentlyContinue)) {
    Write-Error -ErrorAction Continue `
        -Message 'Cannot evaluate the locale seed: the reconciliation module exposes no ConvertTo-MergedHashtable.'
    exit $ExitCannotRun
}

$template = $null
try { $template = Get-Content -Raw -LiteralPath $TemplatePath | ConvertFrom-Yaml -Ordered }
catch {
    Write-Error -ErrorAction Continue `
        -Message ("Cannot evaluate the locale seed: the template does not parse as YAML: {0}" -f $_.Exception.Message)
    exit $ExitCannotRun
}
if ($template -isnot [System.Collections.IDictionary]) {
    Write-Error -ErrorAction Continue `
        -Message 'Cannot evaluate the locale seed: the template did not parse into a mapping.'
    exit $ExitCannotRun
}

# --- REGION: Validate seed
$seedValue = $null
if (-not $template.Contains($LocaleKey)) {
    Add-Finding ("test/test.config.yml.template has no top-level '{0}' key, so reconciliation cannot " -f $LocaleKey +
        'seed one and no host configuration can name a language')
} else {
    $seedValue = $template[$LocaleKey]
    if ($seedValue -is [System.Collections.IDictionary] -or $seedValue -is [System.Collections.IList]) {
        Add-Finding ("the template's '{0}' key is not a scalar; the lock is one tag or the word '{1}'" -f $LocaleKey, $AutoValue)
        $seedValue = $null
    } elseif (-not [string]::Equals([string]$seedValue, $AutoValue, [StringComparison]::OrdinalIgnoreCase)) {
        Add-Finding ("the template seeds '{0}: {1}', which locks every newly reconciled host to one language " -f $LocaleKey, $seedValue +
            ("on first run; the shipped default is '{0}'" -f $AutoValue))
    }
}

# --- REGION: Validate reconciliation
# The merge runs over the real template, so a template that regressed in shape
# fails here as well as above rather than being described from memory.
if ($template.Contains($LocaleKey)) {
    $addedTo = ConvertTo-MergedHashtable -Template $template -Current ([ordered]@{})
    if (-not ($addedTo -is [System.Collections.IDictionary]) -or -not $addedTo.Contains($LocaleKey)) {
        Add-Finding ("reconciling a configuration that lacks '{0}' did not add it; the seed is present but unreachable" -f $LocaleKey)
    } elseif (-not [string]::Equals([string]$addedTo[$LocaleKey], [string]$seedValue, [StringComparison]::Ordinal)) {
        Add-Finding ("reconciliation added '{0}' as '{1}' rather than the template's '{2}'" -f $LocaleKey, $addedTo[$LocaleKey], $seedValue)
    }

    # An operator's own lock is a value they chose. Reconciliation exists to add
    # what the schema gained, never to argue with what they set.
    $lockedTag = 'pt-BR'
    $preserved = ConvertTo-MergedHashtable -Template $template -Current ([ordered]@{ $LocaleKey = $lockedTag })
    if (-not ($preserved -is [System.Collections.IDictionary]) -or
        -not [string]::Equals([string]$preserved[$LocaleKey], $lockedTag, [StringComparison]::Ordinal)) {
        Add-Finding ("reconciliation overwrote an operator's '{0}: {1}' lock with the template default" -f $LocaleKey, $lockedTag)
    }
}

# --- REGION: Validate reference
$reference = [IO.File]::ReadAllText($ReferencePath)

# The enumeration of top-level sections is a whole-text list: a key missing from
# it reads as a key that does not exist.
$sectionList = [regex]::Match($reference, '(?s)Top-level sections:.*?\.\s')
if (-not $sectionList.Success) {
    Add-Finding 'docs/test-config.md no longer enumerates its top-level sections, so the seed cannot be listed among them'
} elseif ($sectionList.Value -notmatch ('`{0}`' -f [regex]::Escape($LocaleKey))) {
    Add-Finding ("docs/test-config.md does not list '{0}' among its top-level sections" -f $LocaleKey)
}

# A named section, and a body that says what the default means. The key name
# alone documents nothing: `auto` is the part an operator has to understand
# before they can decide whether to replace it.
$section = [regex]::Match($reference, ('(?m)^##\s+{0}\b.*?$' -f [regex]::Escape($LocaleKey)))
if (-not $section.Success) {
    Add-Finding ("docs/test-config.md has no section documenting '{0}'" -f $LocaleKey)
} else {
    $rest = $reference.Substring($section.Index)
    $next = [regex]::Match($rest.Substring($section.Length), '(?m)^##\s')
    $body = if ($next.Success) { $rest.Substring(0, $section.Length + $next.Index) } else { $rest }
    if ($body -notmatch ('`{0}`' -f [regex]::Escape($AutoValue))) {
        Add-Finding ("the '{0}' section of docs/test-config.md never explains '{1}', the value it ships with" -f $LocaleKey, $AutoValue)
    }
}

# --- REGION: Result
if ($findings.Count -eq 0) {
    if (-not $Quiet) {
        Write-Output ("PASS  test/test.config.yml.template seeds {0}: {1}" -f $LocaleKey, $seedValue)
        Write-Output 'PASS  reconciliation adds the seed and preserves an operator lock'
        Write-Output 'PASS  docs/test-config.md lists and explains the key'
    }
    Write-Output ("Test-ConfigLocaleSeed: the '{0}' seed, reconciliation and reference agree." -f $LocaleKey)
    exit $ExitOk
}

Write-Warning ("Test-ConfigLocaleSeed: {0} finding(s):" -f $findings.Count)
foreach ($finding in $findings) { Write-Warning ("  FINDING: {0}" -f $finding) }
Write-Warning ''
Write-Warning ("Fix: keep '{0}: {1}' as a top-level key in test/test.config.yml.template and keep" -f $LocaleKey, $AutoValue)
Write-Warning "  docs/test-config.md listing it among the top-level sections with a section that says"
Write-Warning ("  what '{0}' means. Reconciliation can only offer a key the template carries." -f $AutoValue)
exit $ExitFailure
