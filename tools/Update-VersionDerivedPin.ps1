<#PSScriptInfo
.VERSION 2026.09.08
.GUID 424bcbb1-3cf7-435e-a14d-52551096340a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization documentation hash pin release version
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
    Advance the hash pins that a release version bump moves, and only where
    the pinned file can be proved to have changed in nothing else.
.DESCRIPTION
    Three records pin documentation by the SHA-256 of its exact bytes:
    globalization/manifests/doc-translations.json pins each English source a
    translation was accepted against, globalization/terminology/pt-BR.terms.json
    pins the definitions document, and pt-BR.style-guide.json pins the bytes of
    the terminology file itself.

    A version bump rewrites two things inside those pinned files: the
    `Last review:` footer, and the release tag in the verified-download URL in
    install/README.md. Every pin recorded over the old bytes goes stale at once,
    for a reason no reviewer needs to look at -- and the tempting repair, hashing
    the file again, is exactly the failure the pins exist to prevent. Re-hashing
    blesses whatever the file says now, including a paragraph nobody read.

    THE PROOF. For a stale pin this recovers the bytes the pin was actually
    recorded over -- by walking the commits that touched the path and taking the
    first blob whose SHA-256 equals the recorded value. The hash match IS the
    proof of identity; no commit message, author or date is trusted, and no
    ordering assumption is made. It then applies exactly two anchored edits to
    those recovered bytes, with the new version read from the VERSION file:

        the review footer   `Last review: <calver>` on its own line
        the release tag     `alissonsol/yuruna/refs/tags/<calver>`

    and advances the pin if and only if the result is byte-for-byte the file on
    disk. Byte equality after only the declared edits means those edits are the
    ONLY difference in the whole file: no insertion, deletion, reordering or
    reworded sentence can survive the comparison. Anything else is refused, with
    a unified diff of the residual so the operator sees the real change.

    Both edits match a full calendar version including the optional fourth
    component, so neither can fire inside a patch tag. No edit is made by
    version SHAPE: a bare calendar version somewhere in prose is a sentence
    about history, and rewriting it turns a true statement into a false one --
    which is precisely what a refusal is for.

    Nothing is committed or pushed. The working tree is left for review.

    Exit codes follow the entry-point contract:
        0  Every pin is current, or was advanced under proof.
        1  At least one pin was refused: the file changed in something other
           than the two declared edits, and a person has to look at it.
        2  The state could not be evaluated -- a pinned source or record is
           missing, the paired project checkout is absent, or the bytes a pin
           was recorded over exist in no commit. Nothing is written in this
           case, including for the pins that would have been advanceable.

.PARAMETER Root
    Repository root. Defaults to the parent of this script's directory.
.PARAMETER ProjectRoot
    Project checkout paired with this framework tree, which owns five of the
    pinned documents. Defaults to the sibling project repository.
.PARAMETER Update
    Write the advanced pins. Without it the run only reports and touches
    nothing.
.PARAMETER Quiet
    Print only refusals, anything that could not be evaluated, and the summary.

.EXAMPLE
    pwsh -NoProfile -File tools/Update-VersionDerivedPin.ps1
    Reports which pins the proof accepts, which it refuses, and why.

.EXAMPLE
    pwsh -NoProfile -File tools/Update-VersionDerivedPin.ps1 -Update
    Advances the accepted pins and leaves the refused ones untouched.
#>

[CmdletBinding(SupportsShouldProcess)]
[OutputType([string])]
param(
    [string]$Root,
    [string]$ProjectRoot,
    [switch]$Update,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $Root) 'yuruna-project' }

$Locale = 'pt-BR'
$ManifestPath   = Join-Path $Root 'globalization/manifests/doc-translations.json'
$TermsPath      = Join-Path $Root 'globalization/terminology/pt-BR.terms.json'
$StyleGuidePath = Join-Path $Root 'globalization/terminology/pt-BR.style-guide.json'
$VersionPath    = Join-Path $Root 'VERSION'

# The calendar version shape a release stamps, including the optional fourth
# component a patch release adds. A word boundary must never guard it: \b
# matches between the last digit and the following dot, so a \b-guarded
# 2026.09.08 also fires inside the patch tag 2026.09.08.1 and rewrites half of
# it. Both patterns below consume the whole version instead, so a longer one
# cannot be partially matched.
$script:CalVer = '\d{4}\.\d{2}\.\d{2}(?:\.\d+)?'

# Anchored to the start and end of its own line, so it can only ever reach the
# footer and never a version mentioned inside a sentence.
$script:ReviewFooterPattern = '(?m)^(Last review: )' + $script:CalVer + '$'

# Character for character the edit tools/Update-YurunaReleasePins.ps1 makes to
# the verified-download URL. Keeping the two spellings identical is what stops
# the proof and the tool that performs the edit from drifting into disagreeing
# about what a release pin is.
$script:ReleaseTagPattern = '(alissonsol/yuruna/)refs/tags/' + $script:CalVer

# What both sides of the comparison collapse to at a version site. It is not a
# CalVer, so a document that somehow contained this literal still cannot be made
# to look like a version site that moved.
$script:VersionSentinel = '<version>'

# The operator subset, named per repository because it deliberately spans both.
$Document = @(
    @{ Repo = 'yuruna'; Source = 'README.md' }
    @{ Repo = 'yuruna'; Source = 'install/README.md' }
    @{ Repo = 'yuruna'; Source = 'docs/operator.md' }
    @{ Repo = 'yuruna'; Source = 'docs/lab-operator.md' }
    @{ Repo = 'yuruna'; Source = 'docs/install.md' }
    @{ Repo = 'yuruna'; Source = 'docs/kubernetes.md' }
    @{ Repo = 'yuruna'; Source = 'docs/authentication.md' }
    @{ Repo = 'yuruna'; Source = 'docs/workarounds.md' }
    @{ Repo = 'yuruna-project'; Source = 'README.md' }
    @{ Repo = 'yuruna-project'; Source = 'template/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/website/README.md' }
    @{ Repo = 'yuruna-project'; Source = 'example/text-to-sql/README.md' }
)

# --- REGION: hashing and history

function Get-Sha256Byte {
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Byte)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Byte)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-Sha256File {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FullPath)

    return Get-Sha256Byte -Byte ([IO.File]::ReadAllBytes($FullPath))
}

function Get-GitOutput {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string[]]$Argument)

    # The blob has to come off the raw stream. Letting PowerShell decode a
    # command's output re-encodes the text and normalizes its line endings, so
    # the digest of what comes back can never equal the digest recorded over the
    # bytes on disk, and every document would be declined for what reads like
    # corruption.
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in $Argument) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = $null
    try { $process = [Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ ExitCode = -1; Byte = [byte[]]::new(0) } }

    try {
        # Drained on its own task: a full error pipe blocks the child while this
        # side is still copying standard output, and the pair deadlocks.
        $drain = $process.StandardError.ReadToEndAsync()
        $buffer = [IO.MemoryStream]::new()
        $process.StandardOutput.BaseStream.CopyTo($buffer)
        $process.WaitForExit()
        $null = $drain.GetAwaiter().GetResult()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Byte = $buffer.ToArray() }
    } finally { if ($process) { $process.Dispose() } }
}

function Get-AcceptedByte {
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Sha256
    )

    # Identity is established by the digest alone. Walking the commits that
    # touched the path is only a way to enumerate candidate blobs; which commit
    # a match comes from, who wrote it and when carry no weight, so a rewritten
    # history or an out-of-order date cannot mislead this.
    $listed = Get-GitOutput -Argument @('-C', $RepoRoot, 'rev-list', 'HEAD', '--', $RelativePath)
    if ($listed.ExitCode -ne 0) { return $null }

    foreach ($commit in ([Text.Encoding]::ASCII.GetString($listed.Byte) -split "`n")) {
        $id = $commit.Trim()
        if (-not $id) { continue }
        $blob = Get-GitOutput -Argument @('-C', $RepoRoot, 'show', ($id + ':' + $RelativePath))
        if ($blob.ExitCode -ne 0) { continue }
        if ((Get-Sha256Byte -Byte $blob.Byte) -ceq $Sha256) { return , $blob.Byte }
    }
    return $null
}

# --- REGION: the two declared transforms

function Get-VersionNormalized {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Byte,
        [switch]$SkipReleaseTag
    )

    $encoding = [Text.UTF8Encoding]::new($false)
    $text = $encoding.GetString($Byte)

    # A byte that is not valid UTF-8 decodes to a replacement character and does
    # not survive the trip back, which would make the comparison below meaningless
    # rather than false. Prove the round trip before trusting the string form.
    $faithful = (Get-Sha256Byte -Byte $encoding.GetBytes($text)) -ceq (Get-Sha256Byte -Byte $Byte)

    # Both sides are reduced to the same sentinel rather than one side being
    # rewritten to the other's version. The two writers of these sites are
    # independent: the release-pin tool moves the tag, while the review footer
    # moves only when a person restamps it. Rewriting one side to a single
    # expected version would demand they move in lockstep and would refuse the
    # file whenever they did not, even though nothing but a version token
    # differs. Reducing both sides accepts either site moving, or neither,
    # and still refuses any other difference.
    $footer = [regex]::Replace($text, $script:ReviewFooterPattern, '${1}' + $script:VersionSentinel)
    $tagged = $footer
    if (-not $SkipReleaseTag) {
        $tagged = [regex]::Replace($footer, $script:ReleaseTagPattern,
            '${1}refs/tags/' + $script:VersionSentinel)
    }

    return [pscustomobject]@{
        Byte           = $encoding.GetBytes($tagged)
        Faithful       = $faithful
        FooterSite     = ($footer -cne $text)
        ReleaseTagSite = ($tagged -cne $footer)
    }
}

# --- REGION: the residual diff a refusal reports

function Get-DiffOperation {
    [OutputType([Collections.Generic.List[pscustomobject]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Actual
    )

    $ops = [Collections.Generic.List[pscustomobject]]::new()
    $countA = $Expected.Count
    $countB = $Actual.Count

    # Matching runs at both ends are settled by comparison, which leaves only the
    # genuinely different middle for the quadratic part below. On these documents
    # that middle is a handful of lines.
    $prefix = 0
    while ($prefix -lt $countA -and $prefix -lt $countB -and $Expected[$prefix] -ceq $Actual[$prefix]) { $prefix++ }
    $suffix = 0
    while (($prefix + $suffix) -lt $countA -and ($prefix + $suffix) -lt $countB -and
        $Expected[$countA - 1 - $suffix] -ceq $Actual[$countB - 1 - $suffix]) { $suffix++ }

    for ($i = 0; $i -lt $prefix; $i++) { $ops.Add([pscustomobject]@{ Op = ' '; Text = $Expected[$i] }) }

    $midA = [Collections.Generic.List[string]]::new()
    for ($i = $prefix; $i -lt ($countA - $suffix); $i++) { $midA.Add($Expected[$i]) }
    $midB = [Collections.Generic.List[string]]::new()
    for ($i = $prefix; $i -lt ($countB - $suffix); $i++) { $midB.Add($Actual[$i]) }

    if (($midA.Count * $midB.Count) -gt 250000) {
        # Past this size a line-by-line alignment costs more than the result is
        # worth reading, and the answer is the same either way: refuse.
        foreach ($lineText in $midA) { $ops.Add([pscustomobject]@{ Op = '-'; Text = $lineText }) }
        foreach ($lineText in $midB) { $ops.Add([pscustomobject]@{ Op = '+'; Text = $lineText }) }
    } else {
        $la = $midA.Count
        $lb = $midB.Count
        $table = [int[,]]::new($la + 1, $lb + 1)
        for ($i = $la - 1; $i -ge 0; $i--) {
            for ($j = $lb - 1; $j -ge 0; $j--) {
                if ($midA[$i] -ceq $midB[$j]) { $table[$i, $j] = $table[($i + 1), ($j + 1)] + 1 }
                else { $table[$i, $j] = [Math]::Max($table[($i + 1), $j], $table[$i, ($j + 1)]) }
            }
        }
        $i = 0
        $j = 0
        while ($i -lt $la -and $j -lt $lb) {
            if ($midA[$i] -ceq $midB[$j]) {
                $ops.Add([pscustomobject]@{ Op = ' '; Text = $midA[$i] }); $i++; $j++
            } elseif ($table[($i + 1), $j] -ge $table[$i, ($j + 1)]) {
                $ops.Add([pscustomobject]@{ Op = '-'; Text = $midA[$i] }); $i++
            } else {
                $ops.Add([pscustomobject]@{ Op = '+'; Text = $midB[$j] }); $j++
            }
        }
        while ($i -lt $la) { $ops.Add([pscustomobject]@{ Op = '-'; Text = $midA[$i] }); $i++ }
        while ($j -lt $lb) { $ops.Add([pscustomobject]@{ Op = '+'; Text = $midB[$j] }); $j++ }
    }

    for ($i = $countA - $suffix; $i -lt $countA; $i++) { $ops.Add([pscustomobject]@{ Op = ' '; Text = $Expected[$i] }) }
    return , $ops
}

function Get-UnifiedDiffLine {
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Expected,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Actual,
        [int]$Context = 2,
        [int]$MaxLine = 60
    )

    $ops = Get-DiffOperation -Expected $Expected -Actual $Actual
    $numberA = [int[]]::new($ops.Count)
    $numberB = [int[]]::new($ops.Count)
    $seenA = 0
    $seenB = 0
    $changed = [Collections.Generic.List[int]]::new()
    for ($k = 0; $k -lt $ops.Count; $k++) {
        if ($ops[$k].Op -ne '+') { $seenA++ }
        if ($ops[$k].Op -ne '-') { $seenB++ }
        $numberA[$k] = $seenA
        $numberB[$k] = $seenB
        if ($ops[$k].Op -ne ' ') { $changed.Add($k) }
    }

    $rendered = [Collections.Generic.List[string]]::new()
    if ($changed.Count -eq 0) { return , $rendered.ToArray() }

    $group = [Collections.Generic.List[int[]]]::new()
    $start = $changed[0]
    $stop = $changed[0]
    for ($g = 1; $g -lt $changed.Count; $g++) {
        if (($changed[$g] - $stop) -le (2 * $Context + 1)) { $stop = $changed[$g] }
        else { $group.Add(@($start, $stop)); $start = $changed[$g]; $stop = $changed[$g] }
    }
    $group.Add(@($start, $stop))

    $truncated = $false
    foreach ($span in $group) {
        if ($truncated) { break }
        $from = [Math]::Max(0, $span[0] - $Context)
        $to = [Math]::Min($ops.Count - 1, $span[1] + $Context)
        $spanA = 0
        $spanB = 0
        for ($k = $from; $k -le $to; $k++) {
            if ($ops[$k].Op -ne '+') { $spanA++ }
            if ($ops[$k].Op -ne '-') { $spanB++ }
        }
        $beforeA = if ($from -gt 0) { $numberA[$from - 1] } else { 0 }
        $beforeB = if ($from -gt 0) { $numberB[$from - 1] } else { 0 }
        $startA = if ($spanA -gt 0) { $beforeA + 1 } else { $beforeA }
        $startB = if ($spanB -gt 0) { $beforeB + 1 } else { $beforeB }
        # Parenthesized as a whole: inside a method call the commas would
        # otherwise split the format arguments into further method arguments.
        $rendered.Add(('    @@ -{0},{1} +{2},{3} @@' -f $startA, $spanA, $startB, $spanB))
        for ($k = $from; $k -le $to; $k++) {
            if ($rendered.Count -ge $MaxLine) {
                $rendered.Add('    ... residual diff truncated; the pin was refused, so nothing was written')
                $truncated = $true
                break
            }
            $rendered.Add('    ' + $ops[$k].Op + $ops[$k].Text)
        }
    }
    return , $rendered.ToArray()
}

# --- REGION: the proof

function Test-VersionOnlyChange {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RecordedHash,
        [switch]$SkipReleaseTag
    )

    $fullPath = Join-Path $RepoRoot ($RelativePath -replace '/', [IO.Path]::DirectorySeparatorChar)
    $currentByte = [IO.File]::ReadAllBytes($fullPath)
    $currentHash = Get-Sha256Byte -Byte $currentByte

    if ($currentHash -ceq $RecordedHash) {
        return [pscustomobject]@{ State = 'Current'; Hash = $currentHash; Reason = 'pin current'; Diff = @() }
    }

    $acceptedByte = Get-AcceptedByte -RepoRoot $RepoRoot -RelativePath $RelativePath -Sha256 $RecordedHash
    if ($null -eq $acceptedByte) {
        return [pscustomobject]@{
            State  = 'Declined'; Hash = $currentHash; Diff = @()
            Reason = 'no commit holds the bytes the pin was recorded over, so there is nothing to compare'
        }
    }

    $accepted = Get-VersionNormalized -Byte $acceptedByte -SkipReleaseTag:$SkipReleaseTag
    $current = Get-VersionNormalized -Byte $currentByte -SkipReleaseTag:$SkipReleaseTag
    if (-not $accepted.Faithful -or -not $current.Faithful) {
        return [pscustomobject]@{
            State  = 'Declined'; Hash = $currentHash; Diff = @()
            Reason = 'the bytes are not valid UTF-8, so the declared sites cannot be located in them'
        }
    }

    if ((Get-Sha256Byte -Byte $accepted.Byte) -ceq (Get-Sha256Byte -Byte $current.Byte)) {
        $sites = [Collections.Generic.List[string]]::new()
        if ($accepted.FooterSite -or $current.FooterSite) { $sites.Add('review footer') }
        if ($accepted.ReleaseTagSite -or $current.ReleaseTagSite) { $sites.Add('release tag') }
        $reason = if ($sites.Count -gt 0) { $sites -join ', ' } else { 'no version site present' }
        return [pscustomobject]@{ State = 'Advance'; Hash = $currentHash; Reason = $reason; Diff = @() }
    }

    $encoding = [Text.UTF8Encoding]::new($false)
    $diff = Get-UnifiedDiffLine -Expected ($encoding.GetString($accepted.Byte) -split "`n") `
        -Actual ($encoding.GetString($current.Byte) -split "`n")
    if (@($diff).Count -eq 0) {
        $diff = @('    the residual is not on any line: the file differs in its encoding or its final byte')
    }
    return [pscustomobject]@{
        State  = 'Refuse'; Hash = $currentHash; Diff = $diff
        Reason = 'content changed outside the declared edits'
    }
}

# --- REGION: writing

function Save-JsonArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][int]$Depth
    )

    # The byte shape these artifacts already have: LF, no BOM, exactly one
    # trailing newline. Any other shape is a whole-file diff, and the terminology
    # file's own bytes are pinned by the style guide, so a reformatting difference
    # would silently move that second pin.
    $json = (ConvertTo-Json -InputObject $Value -Depth $Depth).Replace("`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

# --- REGION: preconditions

if (-not (Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "The VERSION file is not there: $VersionPath. It names the version the declared edits write, so nothing can be proved without it."
    exit 2
}
$NewVersion = ([IO.File]::ReadAllText($VersionPath)).Trim()
if ($NewVersion -notmatch ('^' + $script:CalVer + '$')) {
    $ErrorActionPreference = 'Continue'
    Write-Error "VERSION reads '$NewVersion', which is not a calendar version. The declared edits write that value verbatim, so it has to be one."
    exit 2
}

foreach ($required in @($ManifestPath, $TermsPath, $StyleGuidePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "A record holding one of the pins is missing: $required"
        exit 2
    }
}

$manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ManifestPath))
$terms = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($TermsPath))
$styleGuide = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($StyleGuidePath))

$record = @{}
foreach ($entry in @($manifest.documents)) { $record["$($entry.repo)|$($entry.source)|$($entry.locale)"] = $entry }

# The paired checkout is only needed when a document that lives there is pinned,
# which on a complete manifest is always. Asking for it before the first line of
# report keeps a half-finished run from looking like a result.
$needProject = @($Document | Where-Object { $_.Repo -ne 'yuruna' -and $record.ContainsKey("$($_.Repo)|$($_.Source)|$Locale") }).Count -gt 0
if ($needProject -and -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "The paired project checkout is not beside this one: $ProjectRoot. Five of the pinned documents live there, so the pins cannot be evaluated."
    exit 2
}

# --- REGION: evaluate

$report = [Collections.Generic.List[pscustomobject]]::new()
$advanceCount = 0
$refuseCount = 0
$declineCount = 0
$currentCount = 0

$script:QuietReport = [bool]$Quiet

function Write-Verdict {
    param(
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyCollection()][string[]]$Diff = @()
    )

    # A verdict that needs a person is never suppressed: a quiet run that
    # printed nothing has to mean there is nothing to act on.
    $loud = $Verb -cin @('REFUSE', 'DECLINE')
    if ($script:QuietReport -and -not $loud) { return }
    Write-Output ('{0,-7} {1} ({2})' -f $Verb, $Label, $Reason)
    foreach ($d in $Diff) { Write-Output $d }
}

foreach ($doc in $Document) {
    $label = "$($doc.Repo)/$($doc.Source)"
    $key = "$($doc.Repo)|$($doc.Source)|$Locale"
    $entry = $record[$key]
    if (-not $entry) {
        Write-Verdict -Verb 'skip' -Label $label -Reason 'no recorded pin, so there is nothing to advance'
        continue
    }

    $repoRoot = if ($doc.Repo -eq 'yuruna') { $Root } else { $ProjectRoot }
    $fullPath = Join-Path $repoRoot ($doc.Source -replace '/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $ErrorActionPreference = 'Continue'
        Write-Error "A pinned document named by the record is missing: $label"
        exit 2
    }

    $result = Test-VersionOnlyChange -RepoRoot $repoRoot -RelativePath $doc.Source `
        -RecordedHash $entry.sourceHash

    switch ($result.State) {
        'Current' { $currentCount++; Write-Verdict -Verb 'ok' -Label $label -Reason $result.Reason }
        'Advance' {
            $advanceCount++
            $report.Add([pscustomobject]@{ Entry = $entry; Hash = $result.Hash; Label = $label })
            Write-Verdict -Verb 'ADVANCE' -Label $label -Reason $result.Reason
        }
        'Refuse' {
            $refuseCount++
            Write-Verdict -Verb 'REFUSE' -Label $label -Reason $result.Reason -Diff $result.Diff
        }
        default {
            $declineCount++
            Write-Verdict -Verb 'DECLINE' -Label $label -Reason $result.Reason -Diff $result.Diff
        }
    }
}

# The definitions document, pinned by the terminology file. Only the review
# footer is declared for it: it carries no verified-download URL, so widening
# the proof to a second edit would only widen what can pass unread.
$definitionRelative = if ($terms.sources -and $terms.sources.definitions) { [string]$terms.sources.definitions.path } else { '' }
$definitionLabel = "yuruna/$definitionRelative"
if (-not $definitionRelative) {
    $ErrorActionPreference = 'Continue'
    Write-Error "The terminology record names no definitions source, so its pin cannot be evaluated: $TermsPath"
    exit 2
}
$definitionFull = Join-Path $Root ($definitionRelative -replace '/', [IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $definitionFull -PathType Leaf)) {
    $ErrorActionPreference = 'Continue'
    Write-Error "The definitions source named by the terminology record is missing: $definitionLabel"
    exit 2
}

$definitionResult = Test-VersionOnlyChange -RepoRoot $Root -RelativePath $definitionRelative `
    -RecordedHash ([string]$terms.sources.definitions.sha256) -SkipReleaseTag

switch ($definitionResult.State) {
    'Current' { $currentCount++; Write-Verdict -Verb 'ok' -Label $definitionLabel -Reason $definitionResult.Reason }
    'Advance' { $advanceCount++; Write-Verdict -Verb 'ADVANCE' -Label $definitionLabel -Reason $definitionResult.Reason }
    'Refuse' { $refuseCount++; Write-Verdict -Verb 'REFUSE' -Label $definitionLabel -Reason $definitionResult.Reason -Diff $definitionResult.Diff }
    default { $declineCount++; Write-Verdict -Verb 'DECLINE' -Label $definitionLabel -Reason $definitionResult.Reason }
}

# The style guide pins the terminology file's bytes. That is a pure derivation,
# but recomputing it whenever it is stale would bless whatever edit made it
# stale -- a changed term, a changed approval -- as if someone had approved it.
# It is repinned only in the same run that legitimately rewrote the terminology
# file, and otherwise reported for a person to settle.
$styleLabel = 'yuruna/globalization/terminology/pt-BR.style-guide.json'
$termsHashOnDisk = Get-Sha256File -FullPath $TermsPath

# The pin has to already describe the terminology bytes as they sit on disk
# before this run is allowed to move it. When it does, the only edit the new pin
# can cover is the definitions hash written below, which the proof settled.
# When it does not, some other edit is already outstanding in that file, and
# repinning would fold that edit into a hash that reads as reviewed.
$styleGuidePinWasCurrent = (([string]$styleGuide.terminologySource.sha256) -ceq $termsHashOnDisk)
$repinStyleGuide = ($definitionResult.State -eq 'Advance') -and $styleGuidePinWasCurrent
if ($repinStyleGuide) {
    $advanceCount++
    $reason = if ($Update) { 'repinned over the terminology bytes this run writes' }
    else { 'would be repinned over the terminology bytes this run would write' }
    Write-Verdict -Verb 'ADVANCE' -Label $styleLabel -Reason $reason
} elseif ($styleGuidePinWasCurrent) {
    $currentCount++
    Write-Verdict -Verb 'ok' -Label $styleLabel -Reason 'pin current'
} else {
    $refuseCount++
    Write-Verdict -Verb 'REFUSE' -Label $styleLabel -Reason 'the terminology file changed outside the declared edits; that change needs approval, not a repin'
}

# --- REGION: write, in the one order that leaves no pin describing bytes that moved under it

$wrote = [Collections.Generic.List[string]]::new()
if ($Update -and $declineCount -eq 0) {
    # The terminology file goes first because the style guide pins its bytes,
    # and the style guide is then recomputed over what actually landed rather
    # than over the value held in memory, so the second pin can never describe a
    # write that was refused, skipped or altered on its way to disk.
    $termsWritten = $false
    # The pair can move only while the style pin still proves the terminology
    # bytes. Updating either file after that proof was refused would cover an
    # unrelated terminology or approval edit with a freshly recorded hash.
    if ($repinStyleGuide) {
        if ($PSCmdlet.ShouldProcess($TermsPath, "advance sources.definitions.sha256 to $($definitionResult.Hash)")) {
            $terms.sources.definitions.sha256 = $definitionResult.Hash
            Save-JsonArtifact -Path $TermsPath -Value $terms -Depth 12
            $termsWritten = $true
            $wrote.Add('globalization/terminology/pt-BR.terms.json')
        }
    }

    if ($termsWritten) {
        $freshTermsHash = Get-Sha256File -FullPath $TermsPath
        if ($PSCmdlet.ShouldProcess($StyleGuidePath, "repin terminologySource.sha256 to $freshTermsHash")) {
            $styleGuide.terminologySource.sha256 = $freshTermsHash
            Save-JsonArtifact -Path $StyleGuidePath -Value $styleGuide -Depth 12
            $wrote.Add('globalization/terminology/pt-BR.style-guide.json')
        }
    }

    if ($report.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($ManifestPath, "advance $($report.Count) document pin(s)")) {
            # Each entry is the object the document array already holds, so setting
            # the hash here edits the array in place and every other field, the
            # review status above all, keeps the value it came in with.
            foreach ($advanced in $report) { $advanced.Entry.sourceHash = $advanced.Hash }
            $value = [ordered]@{ schema = $manifest.schema; documents = @($manifest.documents) }
            Save-JsonArtifact -Path $ManifestPath -Value $value -Depth 6
            $wrote.Add('globalization/manifests/doc-translations.json')
        }
    }

    # Read back what landed instead of trusting what was sent. A pin that does
    # not describe the bytes on disk is worse than a stale one, because every
    # later gate reads it as proof that someone looked.
    $problem = [Collections.Generic.List[string]]::new()
    if ($wrote.Contains('globalization/terminology/pt-BR.terms.json')) {
        $verifyTerms = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($TermsPath))
        if (([string]$verifyTerms.sources.definitions.sha256) -cne (Get-Sha256File -FullPath $definitionFull)) {
            $problem.Add("sources.definitions.sha256 does not describe $definitionLabel after the write")
        }
    }
    if ($wrote.Contains('globalization/terminology/pt-BR.style-guide.json')) {
        $verifyStyle = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($StyleGuidePath))
        if (([string]$verifyStyle.terminologySource.sha256) -cne (Get-Sha256File -FullPath $TermsPath)) {
            $problem.Add('terminologySource.sha256 does not describe the terminology file after the write')
        }
    }
    if ($wrote.Contains('globalization/manifests/doc-translations.json')) {
        $verifyManifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($ManifestPath))
        $verified = @{}
        foreach ($e in @($verifyManifest.documents)) { $verified["$($e.repo)|$($e.source)|$($e.locale)"] = [string]$e.sourceHash }
        foreach ($advanced in $report) {
            $k = "$($advanced.Entry.repo)|$($advanced.Entry.source)|$($advanced.Entry.locale)"
            if ($verified[$k] -cne $advanced.Hash) {
                $problem.Add("$($advanced.Label) does not carry its advanced hash after the write")
            }
        }
    }
    if ($problem.Count -gt 0) {
        $ErrorActionPreference = 'Continue'
        foreach ($p in $problem) { Write-Error $p }
        exit 2
    }
}

# --- REGION: summary

$total = $advanceCount + $refuseCount + $declineCount + $currentCount
$verb = if ($Update) { 'advanced' } else { 'advanceable' }
Write-Output ''
Write-Output ("Update-VersionDerivedPin [{0}]: {1} pin(s), {2} {3}, {4} refused, {5} declined, {6} current." -f
    $NewVersion, $total, $advanceCount, $verb, $refuseCount, $declineCount, $currentCount)

if ($declineCount -gt 0) {
    Write-Output 'Nothing was written: a pin records bytes that are in no commit, so it cannot be proved either way.'
    exit 2
}
if (-not $Update) {
    if ($advanceCount -gt 0) { Write-Output 'Nothing was written. Rerun with -Update to advance the pins the proof accepts.' }
} elseif ($wrote.Count -gt 0) {
    Write-Output ("Wrote: {0}" -f ($wrote -join ', '))
}
if ($refuseCount -gt 0) {
    Write-Output 'A refused pin was left exactly as it was. Read the residual diff, decide whether the change is wanted, and record the review through the translation gate.'
    exit 1
}
exit 0
