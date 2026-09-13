<#PSScriptInfo
.VERSION 2026.09.13
.GUID 4213717a-c9d8-4963-a773-bbe6c4201235
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization reference fixture parity en-US
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
    Capture and compare the stable en-US text of every reference surface.
.DESCRIPTION
    Translation begins by freezing what the English actually says. Without a
    recorded reference, an edit to a message reaches the translated catalogs as
    a silent divergence: the pt-BR text still renders, still passes its schema,
    and now answers a question the English no longer asks.

    This records one normalized capture per row and compares later runs against
    it. Every row comes from a shipping producer -- the real tools, the real
    generated-page exporter, the real message adapter -- so a fixture cannot
    drift from the code by being a transcription of it.

    Normalization removes only what changes between two runs of unchanged
    code: clock readings, host names and addresses, absolute paths, generated
    identifiers, terminal color, and line endings. It deliberately does not
    touch words. A value becomes a token; a sentence stays a sentence, so a
    reworded message is drift and is reported as drift.

    Row ordering inside a capture is preserved unless the row declares
    `sortLines`, which is for producers whose output order is a scheduling
    accident rather than content.
.PARAMETER Root
    The framework repository root. Defaults to the parent of this script.
.PARAMETER ProjectRoot
    The paired project checkout. Defaults to the sibling yuruna-project.
.PARAMETER Id
    Limit the run to these row identifiers. Every row runs by default.
.PARAMETER Update
    Rewrite the recorded captures from the current producers instead of
    comparing against them.
.PARAMETER FixtureRoot
    Where the recorded captures live. Defaults to the tracked location; a copy
    elsewhere lets a caller test the comparison itself.
.PARAMETER Quiet
    Report only the summary line and any drift.
.OUTPUTS
    A summary line. Exit 0 when every row matches, 2 on drift or a missing
    capture, 1 when a producer could not run.
.EXAMPLE
    pwsh tools/Invoke-ReferenceFixture.ps1
.EXAMPLE
    pwsh tools/Invoke-ReferenceFixture.ps1 -Update
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
    Justification = 'Quiet is read by the private Write-Line helper; ScriptAnalyzer does not follow that dynamic script scope.')]
param(
    [string]$Root,
    [string[]]$Id,
    [switch]$Update,
    [string]$FixtureRoot,
    [switch]$Quiet,
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $Root) 'yuruna-project' }
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
if (-not $FixtureRoot) { $FixtureRoot = Join-Path $Root 'globalization/fixtures/reference' }
$FixtureRoot = [IO.Path]::GetFullPath($FixtureRoot)

$script:ManifestPath = Join-Path $FixtureRoot 'manifest.json'
$script:PowerShellPath = (Get-Process -Id $PID).Path
$script:Problem = [Collections.Generic.List[string]]::new()

function Write-Line {
    param([string]$Text = '')
    if (-not $Quiet) { Write-Information $Text -InformationAction Continue }
}

function ConvertTo-NormalizedFixtureText {
    <#
    .SYNOPSIS
        One producer's output, with everything that varies between two runs of
        unchanged code replaced by a token.
    .DESCRIPTION
        The substitutions are value-shaped, never word-shaped: a clock reading,
        an address, a generated identifier, a filesystem root. Prose is left
        exactly as the producer emitted it, which is the whole point -- a
        normalizer that could absorb a reworded sentence would certify English
        nobody has read.

        Known roots are replaced before the general patterns and longest first,
        so a nested path cannot be half-tokenized by its own parent.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Collections.IDictionary]$Root = @{},
        [switch]$SortLines
    )

    $value = $Text.Replace("`r`n", "`n").Replace("`r", "`n")

    # Terminal color is a property of the terminal, not of the message, and it
    # also corrupts the XML a test runner writes its results into.
    $value = [regex]::Replace($value, "$([char]27)\[[0-9;?]*[ -/]*[@-~]", '')

    foreach ($literal in @($Root.Keys | Sort-Object -Property Length -Descending)) {
        if (-not $literal) { continue }
        $value = $value.Replace([string]$literal, [string]$Root[$literal])
    }

    $value = [regex]::Replace($value, '\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?', '<timestamp>')
    $value = [regex]::Replace($value, '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}', '<datetime>')
    $value = [regex]::Replace($value, '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '<id>')
    $value = [regex]::Replace($value, '\b[0-9a-f]{64}\b', '<sha256>')
    $value = [regex]::Replace($value, '\b[0-9a-f]{32}\b', '<id>')
    $value = [regex]::Replace($value, '\b(?:\d{1,3}\.){3}\d{1,3}\b', '<address>')

    $lines = @($value -split "`n" | ForEach-Object { $_.TrimEnd() })
    if ($SortLines) { $lines = @(Get-OrdinalSortedLine -Line $lines) }
    return (($lines -join "`n").TrimEnd() + "`n")
}

function Get-OrdinalSortedLine {
    <#
    .SYNOPSIS
        Lines in ordinal order, whatever culture the host is running in.
    .DESCRIPTION
        Sort-Object collates by culture even with -CaseSensitive, so the same
        capture would order differently on a Turkish or Swedish host and every
        comparison against it would report drift that is not there.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    # A capture has blank lines in it, and a mandatory string array rejects an
    # empty element unless it is told not to.
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Line)

    $sorted = [string[]]::new($Line.Length)
    [Array]::Copy($Line, $sorted, $Line.Length)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    # Emitted rather than wrapped: every caller re-collects this, and a wrapper
    # would make the declared element type a lie.
    return $sorted
}

function Get-CatalogMessage {
    <#
    .SYNOPSIS
        One en-US catalog entry, rendered with the arguments a caller supplies.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$Code,
        [Collections.IDictionary]$Argument = @{}
    )

    $path = Join-Path $Root ('globalization/catalogs/en-US/{0}.json' -f $Domain)
    $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
    $names = @($catalog.messages.PSObject.Properties.Name)
    if ($names -notcontains $Code) { throw "the en-US $Domain catalog has no '$Code'" }
    $entry = $catalog.messages.$Code
    $text = if (@($entry.PSObject.Properties.Name) -contains 'message') { [string]$entry.message } else { '' }
    foreach ($name in @($Argument.Keys)) {
        $text = $text.Replace(('{0}{1}{2}' -f '{', $name, '}'), [string]$Argument[$name])
    }
    return $text
}

function Get-RowCapture {
    <#
    .SYNOPSIS
        The raw text one row's producer emits, before normalization.
    .DESCRIPTION
        Each producer kind runs the code that ships. The command rows run the
        real tools; the page rows read what the generated-page exporter wrote
        from the shipping constants and templates; the envelope rows build a
        real message through the shipping adapter and render it from the
        checked-in en-US catalog.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][Collections.IDictionary]$Context
    )

    switch ([string]$Row.producer) {
        'command' {
            $arguments = [Collections.Generic.List[string]]::new()
            $arguments.Add('-NoProfile')
            $arguments.Add('-File')
            $arguments.Add((Join-Path $Root ([string]$Row.tool)))
            foreach ($argument in @($Row.arguments)) {
                $text = [string]$argument
                foreach ($token in @($Context.Keys)) {
                    $text = $text.Replace(('{0}{1}{2}' -f '{', $token, '}'), [string]$Context[$token])
                }
                $arguments.Add($text)
            }
            $global:LASTEXITCODE = 0
            $output = (& $script:PowerShellPath @arguments 2>&1 | Out-String)
            $code = $LASTEXITCODE
            $expected = [int]$Row.exitCode
            if ($code -ne $expected) {
                $script:Problem.Add(('{0}: the producer exited {1}, and the row records {2}' -f
                    $Row.id, $code, $expected))
            }
            return ("exit: {0}`n{1}" -f $expected, $output)
        }
        'generated-page' {
            $path = Join-Path $Context['generatedPages'] ([string]$Row.file)
            if (-not [IO.File]::Exists($path)) { throw "the exporter wrote no $([string]$Row.file)" }
            return [IO.File]::ReadAllText($path)
        }
        'message-envelope' {
            $spec = $Row.envelope
            $names = @($spec.PSObject.Properties.Name)
            $arguments = @{}
            $types = @{}
            if ($names -contains 'arguments') {
                # An object with no members yields a single null name rather
                # than an empty set, so the loop has to reject it by value.
                foreach ($name in @($spec.arguments.PSObject.Properties.Name | Where-Object { $_ })) {
                    $arguments[$name] = $spec.arguments.$name
                    $types[$name] = [string]$spec.argumentTypes.$name
                }
            }
            # The envelope carries the machine value and the rendered text
            # carries the formatted English. A duration travels as milliseconds
            # and reads as a phrase, and only the phrase is what a translator
            # ever sees, so both belong in the recorded shape.
            $renderArguments = $arguments
            if ($names -contains 'renderArguments') {
                $renderArguments = @{}
                foreach ($name in @($spec.renderArguments.PSObject.Properties.Name | Where-Object { $_ })) {
                    $renderArguments[$name] = $spec.renderArguments.$name
                }
            }
            $catalogPath = Join-Path $Root ('globalization/catalogs/en-US/{0}.json' -f [string]$spec.domain)
            $catalogHash = (Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $rendered = @{
                text = Get-CatalogMessage -Domain ([string]$spec.domain) -Code ([string]$spec.code) -Argument $renderArguments
                messageKey = [string]$spec.code
                locale = 'en-US'
                # The provenance hash covers the whole catalog file, so an edit
                # to any description would move it. Normalization tokenizes it
                # and the rendered text carries the prose this row is about.
                catalogHash = $catalogHash
            }
            $envelopeArguments = @{
                Code = [string]$spec.code
                Arguments = $arguments
                ArgumentTypes = $types
                Rendered = $rendered
            }
            if ($names -contains 'detailText') {
                $envelopeArguments['DetailText'] = [string]$spec.detailText
                $envelopeArguments['DetailSource'] = [string]$spec.detailSource
            }
            $envelope = New-MessageEnvelope @envelopeArguments
            return ((ConvertTo-Json -InputObject $envelope -Depth 20) + "`n")
        }
        default { throw "row '$($Row.id)' declares an unknown producer '$($Row.producer)'" }
    }
}

if (-not [IO.File]::Exists($script:ManifestPath)) {
    Write-Error "the reference-fixture registry is missing: $script:ManifestPath"
    exit 2
}
$manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:ManifestPath))
$rows = @($manifest.rows)
if ($Id) { $rows = @($rows | Where-Object { $Id -contains [string]$_.id }) }
if ($rows.Count -eq 0) {
    Write-Error 'no reference-fixture row matched'
    exit 2
}

Import-Module (Join-Path $Root 'test/modules/Test.Message.psm1') -Force -Global -DisableNameChecking

$work = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-reference-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $work -Force
$work = (Resolve-Path -LiteralPath $work).Path
$captureRoot = Join-Path $FixtureRoot ([string]$manifest.locale)
$drift = [Collections.Generic.List[string]]::new()
$written = 0
$matched = 0

try {
    # Every row's setup is built once, so a run captures one consistent state
    # rather than a different one per row.
    $emptyRoot = Join-Path $work 'empty-root'
    $null = New-Item -ItemType Directory -Path $emptyRoot -Force
    $manifestCopy = Join-Path $work 'doc-translations.json'
    [IO.File]::Copy((Join-Path $Root 'globalization/manifests/doc-translations.json'), $manifestCopy, $true)
    $generated = Join-Path $work 'generated'
    $null = & (Join-Path $Root 'tools/Export-GeneratedPages.ps1') -OutputDirectory $generated -Quiet

    $context = @{
        emptyRoot = $emptyRoot
        manifestCopy = $manifestCopy
        projectRoot = $ProjectRoot
        generatedPages = $generated
    }
    # Longest first is handled inside the normalizer; these are the roots whose
    # spelling differs per host and would otherwise be recorded as content.
    $rootToken = [ordered]@{}
    $rootToken[$work] = '<work>'
    $rootToken[$Root] = '<root>'
    $rootToken[[string]$context['projectRoot']] = '<project>'
    $rootToken[([IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar))] = '<temp>'
    $rootToken[[Environment]::GetFolderPath('UserProfile')] = '<home>'
    $rootToken[[Environment]::MachineName] = '<host>'

    if ($Update) { $null = New-Item -ItemType Directory -Path $captureRoot -Force }

    foreach ($row in $rows) {
        $rowId = [string]$row.id
        $raw = Get-RowCapture -Row $row -Context $context
        $sort = (@($row.PSObject.Properties.Name) -contains 'sortLines') -and [bool]$row.sortLines
        $text = ConvertTo-NormalizedFixtureText -Text $raw -Root $rootToken -SortLines:$sort
        $path = Join-Path $captureRoot ($rowId + '.txt')

        if ($Update) {
            [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
            $written++
            Write-Line ('recorded  {0,-40} {1} {2}' -f $rowId, $row.surface, $row.outcome)
            continue
        }
        if (-not [IO.File]::Exists($path)) {
            $drift.Add("${rowId}: no recorded capture; run -Update after reviewing the new surface")
            continue
        }
        $recorded = [IO.File]::ReadAllText($path).Replace("`r`n", "`n")
        if ([string]::Equals($recorded, $text, [StringComparison]::Ordinal)) {
            $matched++
            Write-Line ('ok        {0,-40} {1} {2}' -f $rowId, $row.surface, $row.outcome)
            continue
        }
        $recordedLine = @($recorded -split "`n")
        $currentLine = @($text -split "`n")
        $limit = [Math]::Max($recordedLine.Count, $currentLine.Count)
        $first = ''
        for ($index = 0; $index -lt $limit; $index++) {
            $was = if ($index -lt $recordedLine.Count) { $recordedLine[$index] } else { '<end of capture>' }
            $now = if ($index -lt $currentLine.Count) { $currentLine[$index] } else { '<end of capture>' }
            if (-not [string]::Equals($was, $now, [StringComparison]::Ordinal)) {
                $first = "line $($index + 1): recorded '$was' but produced '$now'"
                break
            }
        }
        $drift.Add("${rowId}: $first")
    }
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($problem in $script:Problem) { Write-Warning $problem }
if ($Update) {
    Write-Output ('Invoke-ReferenceFixture: recorded {0} row(s) for {1}.' -f $written, $manifest.locale)
    if ($script:Problem.Count -gt 0) { exit 2 }
    exit 0
}
foreach ($entry in $drift) { Write-Warning $entry }
Write-Output ('Invoke-ReferenceFixture: {0} row(s), {1} matched, {2} drifted.' -f
    $rows.Count, $matched, $drift.Count)
if ($drift.Count -gt 0 -or $script:Problem.Count -gt 0) { exit 2 }
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
