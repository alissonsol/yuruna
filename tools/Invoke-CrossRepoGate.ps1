<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42c1f5b8-9a37-4e02-b6d4-5081e7c3a9f6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization gates cross-repository project
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
    Run the gates that apply to the project repository, and say which of this
    repository's gates do not reach it.
.DESCRIPTION
    A lab runs a framework and a project from two separate repositories on two
    separate release cadences, and every gate in this tree stops at its own
    edge. The project has no suite of its own -- it ships configuration, a few
    scripts and its documentation -- so nothing has ever checked it except the
    three documentation tools that already cross the boundary.

    That is the gap this closes, and the honest half of closing it is naming
    what still does not apply. A gate that cannot reach the project is not a
    gate the project passes; reporting it as N/A with a reason is the
    difference between coverage and the appearance of it.

    Nothing here fails the project for the framework's conventions. A project
    is somebody else's repository: its script analyzer settings are its own,
    and this reports what they say rather than imposing this tree's.
.PARAMETER ProjectRoot
    The project checkout. Defaults to the sibling yuruna-project.
.PARAMETER Mode
    changed-domain runs only the checks that cross into the project and is the
    fast contributor path. full adds every cheap deterministic framework gate.
    release adds paired staged-tree hash authority to full mode.
.PARAMETER Release
    Backward-compatible alias for -Mode release. Used by the publisher after it
    has mirrored and stripped both trees.
.PARAMETER FrameworkTreeHash
    Expected staged framework tree hash in release mode.
.PARAMETER ProjectTreeHash
    Expected staged project tree hash in release mode.
.PARAMETER LinkMap
    yuruna.link.json used by the region-anchor gate. Defaults as usual outside
    release mode; the publisher supplies its read-only support checkout.
.PARAMETER EvidencePath
    Optional no-BOM JSON report containing both tree hashes and every row.
.PARAMETER Quiet
    Print only the summary and any findings.
.EXAMPLE
    pwsh -File tools/Invoke-CrossRepoGate.ps1
.EXAMPLE
    pwsh -File tools/Invoke-CrossRepoGate.ps1 -Mode full
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [ValidateSet('changed-domain', 'full', 'release')][string]$Mode = 'changed-domain',
    [switch]$Release,
    [string]$FrameworkTreeHash,
    [string]$ProjectTreeHash,
    [string]$LinkMap,
    [string]$EvidencePath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = Join-Path (Split-Path -Parent $RepoRoot) 'yuruna-project' }
if ($Release) {
    if ($PSBoundParameters.ContainsKey('Mode') -and $Mode -ne 'release') {
        throw '-Release is an alias for -Mode release and cannot be combined with another mode.'
    }
    $Mode = 'release'
}
$isRelease = $Mode -eq 'release'
$runFramework = $Mode -in @('full', 'release')

if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    Write-Output "Invoke-CrossRepoGate: no project checkout at $ProjectRoot; nothing to run."
    # Exit 2 means "could not run", which a caller must not read as a pass.
    exit 2
}

function Get-GateRemediation {
    <#
    .SYNOPSIS
        Map a gate row that did not pass to a repair code and the commands that
        close it.
    .DESCRIPTION
        A row carrying only a state and a tool's raw output leaves the reader to
        rediscover which tool owns the check, which of that tool's several
        details they are looking at, and what to type. That is the answer this
        table holds, kept beside the rows so it cannot drift into a document
        nobody opens.

        Codes are shared where the repair is one job -- the two lint rows, the
        staged-tree rows, every focused Pester slice -- so the deduplicated list
        of next steps stays as short as the work actually is.

        The function reads nothing outside its parameters and keeps no state, so
        it can be lifted out of this file and exercised on its own.
    .PARAMETER Gate
        The row's gate name, matched exactly.
    .PARAMETER State
        The row's state. A passing row never carries a repair.
    .PARAMETER Detail
        The row's detail, matched against a candidate's regex where it has one.
    .OUTPUTS
        A [pscustomobject] carrying Code and Action, or $null for a passing row.
    .EXAMPLE
        Get-GateRemediation -Gate 'catalog-compile' -State 'fail' -Detail ''
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Gate,
        [string]$State,
        [string]$Detail
    )

    if ($State -eq 'pass') { return $null }

    # First match wins. Match is a regex over the detail; an empty Match takes
    # any state that is not a pass, which is what a gate whose details all lead
    # to the same repair needs.
    $table = @(
        @{ Gate = 'doc-translation'; Match = ''; Code = 'doc-source-drift'
            Action = 'An English source moved after its pt-BR translation was accepted. If the only ' +
                'change is the review footer or the verified-download tag, run: pwsh -NoProfile ' +
                '-File tools/Update-VersionDerivedPin.ps1 -ProjectRoot ../yuruna-project . ' +
                'It advances a recorded hash only when the accepted bytes reproduce the current ' +
                'file under those two edits alone, and it names every document it refuses with a ' +
                'diff. If the prose changed, re-translate and run: pwsh -NoProfile -File ' +
                'tools/Test-DocTranslation.ps1 -AcceptReview -Status reviewed -Path ''<source>'' -- ' +
                'one -Path per document, because a bare run accepts all thirteen. Commit and push ' +
                'both private repositories; a working-tree fix is invisible to a release. (Detail ' +
                '''has no <locale> translation at <path>'' instead means the document is ' +
                'unregistered: accept it as -Status draft. Detail ''does not resolve'' means a ' +
                'relative link is broken: fix the link, or run tools/Test-DocTranslation.ps1 ' +
                '-RepairLinks.)' }
        @{ Gate = 'region-anchors'; Match = ''; Code = 'region-anchors'
            Action = 'A documentation region anchor or a public short-link target no longer resolves. ' +
                'Re-run pwsh -NoProfile -File tools/Test-RegionAnchors.ps1 -ProjectRoot <project ' +
                'checkout> -LinkMap <yuruna.link.json>; the detail names the anchor and the file. ' +
                'Fix the heading or the link-map entry it names -- do not rename or merge the ' +
                'document, because a published short link 404s when its slug moves.' }
        @{ Gate = 'project-lint'; Match = ''; Code = 'lint'
            Action = 'The detail lists ''<file>:<line> <rule>'' entries in the project checkout. Fix each ' +
                'one and re-run pwsh -NoProfile -File tools/Invoke-CrossRepoGate.ps1 -Mode ' +
                'changed-domain -ProjectRoot <project checkout>. Detail ''PSScriptAnalyzer is not ' +
                'installed on this host'' is a prerequisite gap, not a defect: Install-Module ' +
                'PSScriptAnalyzer. Detail ''the project ships no PowerShell'' is not-applicable and ' +
                'needs nothing.' }
        @{ Gate = 'project-shellcheck'; Match = ''; Code = 'shellcheck'
            Action = 'The detail lists the failing project shell scripts by relative path. Run ' +
                'shellcheck on each and fix the findings. Detail ''shellcheck is not installed on ' +
                'this host'' is a prerequisite gap: install shellcheck and re-run. Detail ''the ' +
                'project ships no shell scripts'' is not-applicable and needs nothing.' }
        @{ Gate = 'project-locale-map'; Match = ''; Code = 'locale-map'
            Action = 'The project locale map no longer matches the project''s own localized surface. Run ' +
                'pwsh -NoProfile -File tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot <project ' +
                'checkout> and follow what it reports, then commit what it writes in the project ' +
                'repository.' }
        @{ Gate = 'project-utf8'; Match = ''; Code = 'text-encoding'
            Action = 'A project text file is not valid UTF-8 or carries a BOM. Run pwsh -NoProfile -File ' +
                'tools/Test-ProjectTextEncoding.ps1 -ProjectRoot <project checkout>; it names the ' +
                'file. Re-save it as UTF-8 without a BOM.' }
        @{ Gate = 'affected-slice-map'; Match = ''; Code = 'affected-slice-map'
            Action = 'The affected-slice artifact is not byte-current with the code registry it is ' +
                'derived from. Run pwsh -NoProfile -File tools/Invoke-AffectedSliceMap.ps1 -Update ' +
                'and commit globalization/generated/affected-slice-map.json. Detail ''the ' +
                'affected-slice authority tool is missing'' means the tree does not carry ' +
                'tools/Invoke-AffectedSliceMap.ps1 at all -- restore it before anything else, ' +
                'because both seed rows and W2-OPEN read its output.' }
        @{ Gate = 'staged-framework-hash'; Match = ''; Code = 'staged-tree-moved'
            Action = 'The framework staged index does not match the hash the release measured. Something ' +
                'wrote into the staged tree after it was measured, or the work path is stale. ' +
                'Rebuild from a clean work path and do not edit anything under it while the gate ' +
                'runs. Detail ''staged hash unavailable'' means git write-tree itself failed: the ' +
                'detail carries git''s message.' }
        @{ Gate = 'staged-project-hash'; Match = ''; Code = 'staged-tree-moved'
            Action = 'The project staged index does not match the hash the release measured. Same cause ' +
                'and same repair as the framework row: rebuild from a clean work path and leave it ' +
                'alone while the gate runs.' }
        @{ Gate = 'framework-gate-set'; Match = ''; Code = 'staged-tree-moved'
            Action = 'Not a failure of its own: the seventeen framework gates and the five focused slices ' +
                'were never executed because the supplied staged pair did not match the candidate ' +
                'indexes. Fix the two staged-*-hash rows first; until then this run carries no ' +
                'framework result at all, so do not read the absence of framework failures as a ' +
                'pass.' }
        @{ Gate = 'preflight'; Match = ''; Code = 'preflight'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-Preflight.ps1 -Release ; the detail is that ' +
                'tool''s full output and names the failing precondition.' }
        @{ Gate = 'framework-lint'; Match = ''; Code = 'lint'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-Lint.ps1 ; the detail lists each finding as ' +
                '''<file>:<line> <rule>''. Fix them at the source; do not add a suppression without a ' +
                'justification string.' }
        @{ Gate = 'framework-shellcheck'; Match = ''; Code = 'shellcheck'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-ShellCheck.ps1 ; the detail names the ' +
                'failing scripts. Install shellcheck if the detail says it is not present on this ' +
                'host.' }
        @{ Gate = 'ascii-no-bom'; Match = ''; Code = 'ascii-no-bom'
            Action = 'A tracked file carries a non-ASCII byte or a BOM. Run pwsh -NoProfile -File ' +
                'tools/Test-AsciiNoBom.ps1 ; it names the file and the offset. Re-save as ASCII ' +
                'without a BOM. Take care with curly quotes inside single-quoted PowerShell or ' +
                'JavaScript string literals: replacing them changes the string, not just the ' +
                'encoding.' }
        @{ Gate = 'suite-baseline'; Match = ''; Code = 'suite-baseline'
            Action = 'The tracked suite baseline and the runner''s discovery disagree. Detail ' +
                '''<suite> runs but is not in the baseline'': a suite exists that nothing protects, ' +
                'so deleting it again would fail no check. Detail ''<suite> is in the baseline but ' +
                'no longer discovered'': a suite was removed or renamed. Either way, run the full ' +
                'suite and re-record from that run: pwsh -NoProfile -File ' +
                'tools/Invoke-TestSuite.ps1 -UpdateBaseline . Record it from a PASSING run -- a ' +
                'baseline written over a failing one protects the failure. Detail ''the recorded ' +
                '<n> total ...'' means the totals block was edited apart from the per-suite ' +
                'entries it is meant to sum.' }
        @{ Gate = 'config-locale-seed'; Match = ''; Code = 'config-locale-seed'
            Action = 'The lab-wide language knob is not reachable from a host configuration. ' +
                'test/test.config.yml.template must carry a top-level ''language: auto'' -- ' +
                'reconciliation can only fill keys the template contains, so a missing one means ' +
                'no host file ever mentions the language and the config editor has nothing to ' +
                'offer. A real tag there is worse: it would lock every newly reconciled host to ' +
                'one language silently. docs/test-config.md must list the key among its top-level ' +
                'sections and carry a section saying what ''auto'' means. Re-run pwsh -NoProfile ' +
                '-File tools/Test-ConfigLocaleSeed.ps1 ; it names which of the three is missing.' }
        @{ Gate = 'domain-inventory'; Match = ''; Code = 'domain-inventory'
            Action = 'The translation-surface census is stale. Run pwsh -NoProfile -File ' +
                'tools/Invoke-DomainInventory.ps1 -Update -ProjectRoot ../yuruna-project and commit ' +
                'globalization/manifests/domain-inventory.json. Run it only from a CLEAN tree with ' +
                'the project checkout present: it counts untracked, non-ignored files and records ' +
                'whether the sibling was there, so a dirty tree bakes local scratch state into a ' +
                'committed artifact. -Update always exits 0, even when it wrote.' }
        @{ Gate = 'catalog-compile'; Match = ''; Code = 'catalog-compile'
            Action = 'The compiled catalog artifacts do not match their sources. Run pwsh -NoProfile ' +
                '-File tools/Invoke-CatalogCompile.ps1 -Update and commit what it writes. It exits ' +
                '1 when it SUCCESSFULLY WROTE and 0 only when nothing changed; only exit 2 is a ' +
                'failure, so do not wrap it in a plain non-zero throw.' }
        @{ Gate = 'catalog-embed'; Match = ''; Code = 'catalog-embed'
            Action = 'A runtime copy no longer matches the catalog sources. Compile FIRST, then run pwsh ' +
                '-NoProfile -File tools/Invoke-CatalogEmbed.ps1 (writing is the default; there is ' +
                'no -Update, and it exits 0 after writing). Regenerating the embed alone can never ' +
                'settle a stale compile, because the embed hashes catalog-set.json into every ' +
                'runtime it writes.' }
        @{ Gate = 'utf8-catalog'; Match = ''; Code = 'utf8-catalog'
            Action = 'A catalog source or generated catalog is not valid UTF-8. Run pwsh -NoProfile ' +
                '-File tools/Test-Utf8Catalog.ps1 ; it names the file. Re-save it as UTF-8 and then ' +
                'recompile and re-embed, in that order.' }
        @{ Gate = 'globalization-authority'; Match = ''; Code = 'globalization-authority'
            Action = 'A user-visible string bypasses the catalog. Run pwsh -NoProfile -File ' +
                'tools/Test-GlobalizationAuthority.ps1 ; the detail names the file and the literal. ' +
                'Route the string through the catalog rather than hard-coding it, then recompile ' +
                'and re-embed.' }
        @{ Gate = 'terminology'; Match = ''; Code = 'terminology'
            Action = 'A terminology pin no longer matches its source. Detail ''docs/definition.md changed ' +
                'after the terminology source was derived'': if the only change is the review ' +
                'footer, run pwsh -NoProfile -File tools/Update-VersionDerivedPin.ps1 -Update ; it ' +
                'rewrites sources.definitions.sha256 and then repins the style guide over the ' +
                'terminology bytes it just wrote, in that order. A real definition edit needs the ' +
                'approval walk, not a repin. Detail ''the terminology source changed after the style ' +
                'guide was derived'': that pin is a pure derivation over the terminology file''s ' +
                'bytes, but repin it ONLY in the same operation that legitimately wrote those bytes ' +
                '-- repinning it over an unexplained terminology edit blesses that edit. Detail ' +
                '''names release <r>, which this tree has not reached'': an approval record was ' +
                'rewritten forward; restore the release the approver actually signed. That field is ' +
                'a historical stamp, an earlier value passes by design, and a version bump must ' +
                'never move it. Detail ''baseline approval is incomplete'': a native translator and a ' +
                'different independent reviewer must each complete their approval record; no tool ' +
                'can supply that.' }
        @{ Gate = 'perf-baseline'; Match = ''; Code = 'perf-baseline'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-PerfBaseline.ps1 ; the detail names the ' +
                'measurement that regressed against the recorded baseline. Either fix the ' +
                'regression or re-record the baseline deliberately, never silently. (A ' +
                'not-applicable row means the project serves no page.)' }
        @{ Gate = 'js-test'; Match = ''; Code = 'js-test'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-JsTest.ps1 ; the detail is that tool''s ' +
                'output and names the failing case.' }
        @{ Gate = 'go-build'; Match = ''; Code = 'go-build'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-GoTest.ps1 ; the detail names the module ' +
                'that does not build. A nested service module needs the SDK staged beside it before ' +
                'it will build from a bare checkout, and a new transitive SDK import breaks the ' +
                'guest build even while the direct-import guard still passes. (A not-applicable row ' +
                'means the project ships no Go.)' }
        @{ Gate = 'accessibility'; Match = ''; Code = 'accessibility'
            Action = 'Run pwsh -NoProfile -File tools/Invoke-A11yCheck.ps1 ; the detail names the page ' +
                'and the violated rule. Fix the markup rather than suppressing the rule.' }
        @{ Gate = 'doc-reachability'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.DocReachability.Tests.ps1 directly under Pester 5; the ' +
                'detail names the failing test and its first error line. Detail ''required test file ' +
                'is missing'' means the tree does not carry that file. Detail ''Pester 5.0 or newer ' +
                'is not installed'' is a prerequisite gap: install Pester 5 and re-run. A skipped or ' +
                'not-run count makes this cannot-run, not pass.' }
        @{ Gate = 'code-registry-contract'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.CodeRegistry.Tests.ps1 directly under Pester 5; the detail ' +
                'names the failing test. The code registry feeds the affected-slice artifact, so ' +
                'fix this before regenerating that map. Same prerequisite notes as the other ' +
                'focused slices.' }
        @{ Gate = 'status-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.StatusServiceLocale.Tests.ps1 and ' +
                'test/modules/Test.StatusPauseSlice.Tests.ps1 directly under Pester 5; the detail ' +
                'names the failing test and container. This row is also the matrix gate for ' +
                'SEED-OPEN(status), so its failure closes that seed and W2-OPEN as well.' }
        @{ Gate = 'pool-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.PoolGlobalizationSlice.Tests.ps1 directly under Pester 5; ' +
                'the detail names the failing test. This row is the matrix gate for ' +
                'SEED-OPEN(pool), so its failure closes that seed and W2-OPEN as well.' }
        @{ Gate = 'reference-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.ReferenceSliceMatrix.Tests.ps1 directly under Pester 5; the ' +
                'detail names the failing test. It is a member of the shared prerequisite list, so ' +
                'its failure closes both seeds and W2-OPEN.' }
    )

    foreach ($candidate in $table) {
        if ([string]$candidate.Gate -cne $Gate) { continue }
        if ($candidate.Match -and $Detail -notmatch [string]$candidate.Match) { continue }
        return [pscustomobject]@{ Code = [string]$candidate.Code; Action = [string]$candidate.Action }
    }

    # A gate added to this run without an entry above must still say something
    # actionable, and its code carries its own name so one unmapped gate cannot
    # absorb another where the codes are deduplicated.
    $slug = (([string]$Gate) -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
    if (-not $slug) { $slug = 'unnamed' }
    return [pscustomobject]@{
        Code = "unmapped-$slug"
        Action = ('No repair is recorded for gate ''{0}''. Its detail is the output of the tool ' +
            'that owns the check: re-run that tool from tools/ and fix what it names, then give ' +
            'the gate an entry in Get-GateRemediation so the next reader is not sent here.') -f $Gate
    }
}

$rows = [Collections.Generic.List[object]]::new()
function Add-Row {
    param([string]$Gate, [string]$State, [string]$Detail,
        [string]$RemediationCode = '', [string]$Remediation = '')
    # Derive the repair centrally. Every call site that only reports a state
    # keeps working unchanged, and no new one can add a row that fails without
    # telling the reader what to do about it. Both fields are advisory: a
    # consumer that knows only gate/state/detail keeps reading rows as before.
    if (-not $Remediation -and $State -in @('fail', 'cannot-run')) {
        $fix = Get-GateRemediation -Gate $Gate -State $State -Detail $Detail
        if ($fix) { $RemediationCode = $fix.Code; $Remediation = $fix.Action }
    }
    $rows.Add([pscustomobject]@{
            Gate = $Gate; State = $State; Detail = $Detail
            RemediationCode = $RemediationCode; Remediation = $Remediation
        })
}

# Every stage below runs a child process and captures its output, so a release
# run spends minutes printing nothing between the first gate and the summary and
# reads as hung. Report the stage that is running on the progress stream: stdout
# is a parsed contract here (-Quiet exists to keep the rows off it), and a
# progress bar must never become part of it.
$script:StageIndex = 0
$script:StageTotal = 0
$script:StageClock = [Diagnostics.Stopwatch]::StartNew()

# A drawn bar needs a console to draw on, and the publisher runs this gate under
# Start-Transcript. That redirects stdout for the whole process tree, the host
# then reports no console, and Write-Progress renders absolutely nothing -- in
# the one run that most needs it. Where the bar cannot be drawn, print one line
# per stage instead: it reaches the console, and the transcript keeps it as a
# record of what each stage cost. -Quiet suppresses the gate rows, not the
# operator's only sign that a six-minute stage is progressing.
$script:StageBarDrawn = -not [Console]::IsOutputRedirected
function Write-GateProgress {
    param([Parameter(Mandatory)][string]$Stage)
    $script:StageIndex++
    $status = '{0}/{1} {2} -- {3}s elapsed' -f $script:StageIndex, $script:StageTotal, $Stage,
        [int]$script:StageClock.Elapsed.TotalSeconds
    if (-not $script:StageBarDrawn) {
        Write-Information "  gate $status" -InformationAction Continue
        return
    }
    $percent = 0
    if ($script:StageTotal -gt 0) {
        $percent = [int](100 * [Math]::Min($script:StageIndex - 1, $script:StageTotal) / $script:StageTotal)
    }
    Write-Progress -Id 1 -Activity "Cross-repository gate ($Mode)" -PercentComplete $percent -Status $status
}

function Get-GitCandidatePath {
    <#
    .SYNOPSIS
        List tracked and untracked, non-ignored candidate files by glob.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$Include
    )

    $paths = @(& git -C $Root ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw "git could not enumerate candidate files in $Root" }
    return [string[]]@($paths | Where-Object {
            $path = [string]$_
            @($Include | Where-Object { $path -like $_ }).Count -gt 0
        } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
}

function Invoke-FocusedPesterGate {
    <#
    .SYNOPSIS
        Run one named, fixed test slice without recursing into the full suite.
    .DESCRIPTION
        Full/release authority needs a few shipped-builder and documentation
        assertions that have no standalone tool. A fixed file list keeps that
        boundary reviewable. A missing file, skipped test, or container that
        never ran is reported separately from a clean result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][string[]]$RelativePath
    )
    Write-GateProgress -Stage $Gate

    $paths = @($RelativePath | ForEach-Object { Join-Path $RepoRoot $_ })
    $missing = @($paths | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        Add-Row -Gate $Gate -State 'cannot-run' -Detail ('required test file is missing: ' + ($missing -join ', '))
        return
    }
    if (-not (Get-Module -ListAvailable -Name Pester | Where-Object Version -GE ([version]'5.0'))) {
        Add-Row -Gate $Gate -State 'cannot-run' -Detail 'Pester 5.0 or newer is not installed'
        return
    }
    try {
        Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
        $result = Invoke-Pester -Path $paths -Output None -PassThru
        $failed = [int]$result.FailedCount + [int]$result.FailedBlocksCount + [int]$result.FailedContainersCount
        $incomplete = [int]$result.SkippedCount + [int]$result.NotRunCount
        $detail = ("{0} passed, {1} failed, {2} skipped/not-run across {3} focused file(s)" -f `
            [int]$result.PassedCount, $failed, $incomplete, $paths.Count)
        if ($failed -gt 0) {
            # Name AND reason. The marker rows downstream reduce this row to
            # "<gate> failed", so a detail that carries only test names leaves an
            # operator with no way to tell a real slice regression from a
            # prerequisite that could not run, and the only route to the reason
            # is re-running the slice by hand.
            $failedNames = @($result.Tests | Where-Object Result -EQ 'Failed' |
                ForEach-Object {
                    $reason = ([string]($_.ErrorRecord | Select-Object -First 1)) -split "`r?`n" |
                        Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
                    if ($reason) { "$($_.ExpandedPath) -- $($reason.Trim())" } else { [string]$_.ExpandedPath }
                } | Where-Object { $_ } | Sort-Object -Unique)
            # A container that fails before its tests run produces no failed test
            # at all, so counting it without rendering it is how a row reports
            # more failures than it can name. Only a container carrying its OWN
            # error is rendered: one marked failed merely because a test inside
            # it failed is already named above.
            $failedNames += @($result.Containers | Where-Object Result -EQ 'Failed' |
                ForEach-Object {
                    $reason = ([string]($_.ErrorRecord | Select-Object -First 1)) -split "`r?`n" |
                        Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
                    if ($reason) { "container $([IO.Path]::GetFileName([string]$_.Item)) -- $($reason.Trim())" }
                } | Where-Object { $_ })
            if ($failedNames.Count -gt 0) { $detail += '; failed: ' + ($failedNames -join ', ') }
        }
        Add-Row -Gate $Gate `
            -State $(if ($failed -gt 0) { 'fail' } elseif ($incomplete -gt 0) { 'cannot-run' } else { 'pass' }) `
            -Detail $detail
    } catch {
        Add-Row -Gate $Gate -State 'fail' -Detail "focused Pester slice failed to execute: $($_.Exception.Message)"
    }
}

function Get-EngineeringOpenRow {
    <#
    .SYNOPSIS
        Derive SEED-OPEN and W2-OPEN from checked gate and slice evidence.
    .DESCRIPTION
        This function records no owner verdict and accepts no waiver. Its only
        inputs are the rows this invocation actually ran and the deterministic
        affected-slice artifact whose byte-current check is one of those rows.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$GateRows,
        [Parameter()][AllowNull()]$SliceEvidence
    )

    $byGate = @{}
    foreach ($row in $GateRows) { $byGate[[string]$row.Gate] = $row }
    $common = @(
        'doc-translation', 'region-anchors', 'project-lint', 'project-shellcheck',
        'project-locale-map', 'project-utf8', 'affected-slice-map', 'preflight',
        'framework-lint', 'framework-shellcheck', 'ascii-no-bom',
        'suite-baseline', 'config-locale-seed',
        'domain-inventory', 'catalog-compile', 'catalog-embed', 'utf8-catalog',
        'globalization-authority', 'locale-support', 'terminology',
        'perf-baseline', 'js-test', 'go-build', 'accessibility',
        'doc-reachability', 'code-registry-contract', 'reference-slice-matrix'
    )
    $classify = {
        param([Parameter(Mandatory)][string[]]$Names)
        $failures = [Collections.Generic.List[string]]::new()
        $unavailable = [Collections.Generic.List[string]]::new()
        $codes = [Collections.Generic.List[string]]::new()
        foreach ($name in $Names) {
            if (-not $byGate.ContainsKey($name)) { $unavailable.Add("$name is missing"); continue }
            $state = [string]$byGate[$name].State
            if ($state -eq 'fail') { $failures.Add("$name failed") }
            elseif ($state -ne 'pass') { $unavailable.Add("$name is $state") }
            else { continue }
            # Carry the prerequisite's own repair code upward. A roll-up that
            # repeats which gate closed it tells the reader nothing they cannot
            # already see; the code points at the command that reopens it. A
            # row built by hand carries no code at all, so read the property
            # only where it exists.
            $code = ''
            if ($byGate[$name].PSObject.Properties.Name -contains 'RemediationCode') {
                $code = [string]$byGate[$name].RemediationCode
            }
            if ($code -and -not $codes.Contains($code)) { $codes.Add($code) }
        }
        return [pscustomobject]@{
            State = if ($failures.Count) { 'fail' } elseif ($unavailable.Count) { 'cannot-run' } else { 'pass' }
            Failures = $failures.ToArray()
            Unavailable = $unavailable.ToArray()
            Codes = $codes.ToArray()
        }
    }

    $seedRows = [Collections.Generic.List[object]]::new()
    $seedCodes = [Collections.Generic.List[string]]::new()
    foreach ($sliceConfig in @(
            @{ Label = 'status'; Id = 'status-pause-generated'; Matrix = 'status-slice-matrix'
                Tail = 'Its detail names each contributing gate; every one of them is a row in ' +
                    'this same report with its own remediation. Note that a prerequisite ' +
                    'reported as not-applicable also closes this seed -- it counts as ' +
                    'unavailable, not as a pass.' }
            @{ Label = 'pool'; Id = 'pool-repository-project'; Matrix = 'pool-slice-matrix'
                Tail = 'Its detail names each contributing gate. A detail entry of the form ' +
                    '''reachable C blocker(s): <ids>'' is not a gate failure at all: it comes ' +
                    'from the affected-slice artifact and means those blockers must be closed ' +
                    'or reclassified before the seed can open.' })) {
        $checked = & $classify -Names @($common + $sliceConfig.Matrix)
        $failures = [Collections.Generic.List[string]]::new()
        $unavailable = [Collections.Generic.List[string]]::new()
        $codes = [Collections.Generic.List[string]]::new()
        foreach ($item in @($checked.Failures)) { $failures.Add($item) }
        foreach ($item in @($checked.Unavailable)) { $unavailable.Add($item) }
        foreach ($item in @($checked.Codes)) {
            if ($item -and -not $codes.Contains([string]$item)) { $codes.Add([string]$item) }
            if ($item -and -not $seedCodes.Contains([string]$item)) { $seedCodes.Add([string]$item) }
        }

        $slice = if ($SliceEvidence) {
            @($SliceEvidence.slices | Where-Object id -CEQ $sliceConfig.Id) | Select-Object -First 1
        } else { $null }
        if (-not $slice) {
            $unavailable.Add("affected-slice evidence has no '$($sliceConfig.Id)' row")
        } elseif (-not [bool]$slice.seedOpen) {
            $open = @($slice.openBlockers | ForEach-Object { [string]$_ })
            $failures.Add("reachable C blocker(s): " + $(if ($open.Count) { $open -join ', ' } else { 'unclassified' }))
        }

        $state = if ($failures.Count) { 'fail' } elseif ($unavailable.Count) { 'cannot-run' } else { 'pass' }
        $detail = if ($state -eq 'pass') {
            'all checked A/B, shipped-builder matrix, and affected-slice prerequisites pass'
        } else { @($failures.ToArray() + $unavailable.ToArray()) -join '; ' }
        # A marker is a roll-up, not a defect, so it carries no code of its own
        # and creates no entry of its own in the list of next steps: it points
        # at the codes of the prerequisites that closed it.
        $remediation = ''
        if ($state -ne 'pass') {
            $remediation = 'This row is a roll-up of prerequisites, not a defect of its own.'
            if ($codes.Count) {
                $remediation += ' Fix the causes listed under actions: ' + ($codes.ToArray() -join ', ') + '.'
            }
            $remediation += ' ' + [string]$sliceConfig.Tail
        }
        $seedRows.Add([pscustomobject]@{ Gate = "SEED-OPEN($($sliceConfig.Label))"; State = $state; Detail = $detail
                RemediationCode = ''; Remediation = $remediation })
    }

    $w2Failures = [Collections.Generic.List[string]]::new()
    $w2Unavailable = [Collections.Generic.List[string]]::new()
    foreach ($seed in $seedRows) {
        if ($seed.State -eq 'fail') { $w2Failures.Add("$($seed.Gate) failed") }
        elseif ($seed.State -ne 'pass') { $w2Unavailable.Add("$($seed.Gate) is $($seed.State)") }
    }
    if (-not $SliceEvidence -or -not $SliceEvidence.summary -or
        $SliceEvidence.summary.PSObject.Properties.Name -notcontains 'openBlockerCount') {
        $w2Unavailable.Add('affected-slice evidence has no total open-blocker count')
    } elseif ([int]$SliceEvidence.summary.openBlockerCount -ne 0) {
        $w2Failures.Add("affected-slice evidence has $($SliceEvidence.summary.openBlockerCount) open C blocker(s)")
    }
    $w2State = if ($w2Failures.Count) { 'fail' } elseif ($w2Unavailable.Count) { 'cannot-run' } else { 'pass' }
    $w2Detail = if ($w2State -eq 'pass') {
        'both seeded slices and all checked A-C engineering prerequisites pass'
    } else { @($w2Failures.ToArray() + $w2Unavailable.ToArray()) -join '; ' }
    # Resolve through the seeds to the gates underneath them. Restating that a
    # seed failed only sends the reader one row up to read the same thing again.
    $w2Remediation = ''
    if ($w2State -ne 'pass') {
        $w2Remediation = 'This row is a roll-up of the two seeds, not a defect of its own.'
        if ($seedCodes.Count) {
            $w2Remediation += ' Fix the causes listed under actions: ' + ($seedCodes.ToArray() -join ', ') + '.'
        }
        $w2Remediation += ' A detail entry ''affected-slice evidence has N open C blocker(s)'' means ' +
            'the slice artifact itself still records open blockers; ''affected-slice evidence has no ' +
            'total open-blocker count'' means that artifact is missing or unparseable -- regenerate it ' +
            'with tools/Invoke-AffectedSliceMap.ps1 -Update.'
    }
    $seedRows.Add([pscustomobject]@{ Gate = 'W2-OPEN'; State = $w2State; Detail = $w2Detail
            RemediationCode = ''; Remediation = $w2Remediation })
    return $seedRows.ToArray()
}

# --- REGION: Execution plan
# Hoisted so the progress bar can report a fraction instead of a spinner. The
# lists stay the execution order; the loops below consume them where the gates
# actually run.
$localeSupportArguments = @('-Quiet', '-ProjectRoot', $ProjectRoot)
if ($isRelease) { $localeSupportArguments += @('-FrameworkTreeHash', $FrameworkTreeHash, '-ProjectTreeHash', $ProjectTreeHash) }
$frameworkGates = @(
    @{ Name = 'preflight'; Script = 'Invoke-Preflight.ps1'; Args = @('-Release', '-Quiet') }
    @{ Name = 'framework-lint'; Script = 'Invoke-Lint.ps1'; Args = @() }
    @{ Name = 'framework-shellcheck'; Script = 'Invoke-ShellCheck.ps1'; Args = @() }
    @{ Name = 'ascii-no-bom'; Script = 'Test-AsciiNoBom.ps1'; Args = @('-Quiet') }
    @{ Name = 'suite-baseline'; Script = 'Test-SuiteBaseline.ps1'; Args = @('-Quiet') }
    @{ Name = 'config-locale-seed'; Script = 'Test-ConfigLocaleSeed.ps1'; Args = @('-Quiet') }
    @{ Name = 'domain-inventory'; Script = 'Invoke-DomainInventory.ps1'; Args = @('-Check', '-Quiet', '-ProjectRoot', $ProjectRoot) }
    @{ Name = 'catalog-compile'; Script = 'Invoke-CatalogCompile.ps1'; Args = @('-Check', '-Quiet') }
    @{ Name = 'catalog-embed'; Script = 'Invoke-CatalogEmbed.ps1'; Args = @('-Check', '-Quiet') }
    @{ Name = 'utf8-catalog'; Script = 'Test-Utf8Catalog.ps1'; Args = @('-Quiet') }
    @{ Name = 'globalization-authority'; Script = 'Test-GlobalizationAuthority.ps1'; Args = @('-Quiet') }
    @{ Name = 'locale-support'; Script = 'Test-LocaleSupport.ps1'; Args = $localeSupportArguments }
    @{ Name = 'terminology'; Script = 'Test-Terminology.ps1'; Args = @('-Quiet') }
    @{ Name = 'perf-baseline'; Script = 'Invoke-PerfBaseline.ps1'; Args = @('-Quiet') }
    @{ Name = 'js-test'; Script = 'Invoke-JsTest.ps1'; Args = @('-Quiet') }
    @{ Name = 'go-build'; Script = 'Invoke-GoTest.ps1'; Args = @('-Quiet') }
    @{ Name = 'accessibility'; Script = 'Invoke-A11yCheck.ps1'; Args = @() })

$focusedGates = @(
    @{ Gate = 'doc-reachability'; RelativePath = @('test/modules/Test.DocReachability.Tests.ps1') }
    @{ Gate = 'code-registry-contract'; RelativePath = @('test/modules/Test.CodeRegistry.Tests.ps1') }
    @{ Gate = 'status-slice-matrix'; RelativePath = @(
            'test/modules/Test.StatusServiceLocale.Tests.ps1'
            'test/modules/Test.StatusPauseSlice.Tests.ps1') }
    @{ Gate = 'pool-slice-matrix'; RelativePath = @('test/modules/Test.PoolGlobalizationSlice.Tests.ps1') }
    @{ Gate = 'reference-slice-matrix'; RelativePath = @('test/modules/Test.ReferenceSliceMatrix.Tests.ps1') })

$plannedStages = [Collections.Generic.List[string]]::new()
$plannedStages.AddRange([string[]]@('doc-translation', 'region-anchors', 'project-lint',
        'project-shellcheck', 'project-locale-map', 'project-utf8', 'affected-slice-map'))
if ($isRelease) { $plannedStages.Add('staged-tree-hashes') }
if ($runFramework) {
    $plannedStages.AddRange([string[]]@($frameworkGates | ForEach-Object { $_.Name }))
    $plannedStages.AddRange([string[]]@($focusedGates | ForEach-Object { $_.Gate }))
}
$script:StageTotal = $plannedStages.Count

# --- REGION: Cross-repository gates
# Translated documents. This one already reads both trees, which is why the
# project's pt-BR drafts have been drift-checked all along.
Write-GateProgress -Stage 'doc-translation'
$doc = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-DocTranslation.ps1') `
    -ProjectRoot $ProjectRoot -Quiet 2>&1 | Out-String
$docCode = $LASTEXITCODE
Add-Row -Gate 'doc-translation' `
    -State $(if ($docCode -eq 0) { 'pass' } elseif ($docCode -eq 2) { 'cannot-run' } else { 'fail' }) `
    -Detail $doc.Trim()

# Documentation anchors and the public link map, which span both repositories.
Write-GateProgress -Stage 'region-anchors'
$anchorArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-RegionAnchors.ps1'),
    '-ProjectRoot', $ProjectRoot)
if ($LinkMap) { $anchorArgs += @('-LinkMap', $LinkMap) }
$anchors = & pwsh @anchorArgs 2>&1 | Out-String
$anchorCode = $LASTEXITCODE
Add-Row -Gate 'region-anchors' `
    -State $(if ($anchorCode -eq 0) { 'pass' } elseif ($anchorCode -eq 2) { 'cannot-run' } else { 'fail' }) `
    -Detail $anchors.Trim()

# --- REGION: Project script validation
Write-GateProgress -Stage 'project-lint'
$settings = Join-Path $ProjectRoot 'PSScriptAnalyzerSettings.psd1'
$scripts = @()
$scriptDiscoveryFailed = $false
try { $scripts = @(Get-GitCandidatePath -Root $ProjectRoot -Include @('*.ps1', '*.psm1')) }
catch {
    $scriptDiscoveryFailed = $true
    Add-Row -Gate 'project-lint' -State 'cannot-run' -Detail $_.Exception.Message
}
if (-not $scriptDiscoveryFailed) {
    if ($scripts.Count -eq 0) {
        Add-Row -Gate 'project-lint' -State 'not-applicable' -Detail 'the project ships no PowerShell'
    } elseif (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
        Add-Row -Gate 'project-lint' -State 'cannot-run' -Detail 'PSScriptAnalyzer is not installed on this host'
    } else {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        $found = @()
        foreach ($rel in $scripts) {
            $full = Join-Path $ProjectRoot $rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            # Not $args: that is an automatic variable, and shadowing it is a trap
            # even where it happens to work.
            $analyzerArgs = @{ Path = $full; Severity = @('Error', 'Warning') }
            if (Test-Path -LiteralPath $settings -PathType Leaf) { $analyzerArgs['Settings'] = $settings }
            foreach ($r in @(Invoke-ScriptAnalyzer @analyzerArgs)) { $found += "${rel}:$($r.Line) $($r.RuleName)" }
        }
        Add-Row -Gate 'project-lint' -State $(if ($found.Count -eq 0) { 'pass' } else { 'fail' }) `
            -Detail $(if ($found.Count -eq 0) { "$($scripts.Count) script(s) clean under the project's own settings" } else { $found -join '; ' })
    }
}

# Shell scripts the project ships into guests.
Write-GateProgress -Stage 'project-shellcheck'
$shell = @()
$shellDiscoveryFailed = $false
try { $shell = @(Get-GitCandidatePath -Root $ProjectRoot -Include @('*.sh')) }
catch {
    $shellDiscoveryFailed = $true
    Add-Row -Gate 'project-shellcheck' -State 'cannot-run' -Detail $_.Exception.Message
}
if (-not $shellDiscoveryFailed) {
    if ($shell.Count -eq 0) {
        Add-Row -Gate 'project-shellcheck' -State 'not-applicable' -Detail 'the project ships no shell scripts'
    } elseif (-not (Get-Command shellcheck -ErrorAction SilentlyContinue)) {
        Add-Row -Gate 'project-shellcheck' -State 'cannot-run' -Detail 'shellcheck is not installed on this host'
    } else {
        $bad = @()
        foreach ($rel in $shell) {
            $full = Join-Path $ProjectRoot $rel
            $null = & shellcheck --severity=error --format=gcc $full 2>&1
            if ($LASTEXITCODE -ne 0) { $bad += $rel }
        }
        Add-Row -Gate 'project-shellcheck' -State $(if ($bad.Count -eq 0) { 'pass' } else { 'fail' }) `
            -Detail $(if ($bad.Count -eq 0) { "$($shell.Count) script(s) clean" } else { $bad -join '; ' })
    }
}

# Parse and validate the complete additive project-map contract through its one
# authoritative tool.  A regex here would silently disagree on quoted keys,
# nested maps, canonical locale tags, bounds, or source-hash provenance.
Write-GateProgress -Stage 'project-locale-map'
$map = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-ProjectLocaleMap.ps1') `
    -ProjectRoot $ProjectRoot -Quiet 2>&1 | Out-String
$mapCode = $LASTEXITCODE
Add-Row -Gate 'project-locale-map' `
    -State $(if ($mapCode -eq 0) { 'pass' } elseif ($mapCode -eq 2) { 'cannot-run' } else { 'fail' }) `
    -Detail $map.Trim()

# Exact bytes, not ReadAllText's forgiving default. The recorded inventory is
# also reverse-checked here so removing one project path cannot shrink the gate.
Write-GateProgress -Stage 'project-utf8'
$encoding = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Test-ProjectTextEncoding.ps1') `
    -ProjectRoot $ProjectRoot -Quiet 2>&1 | Out-String
$encodingCode = $LASTEXITCODE
Add-Row -Gate 'project-utf8' `
    -State $(if ($encodingCode -eq 0) { 'pass' } elseif ($encodingCode -eq 2) { 'cannot-run' } else { 'fail' }) `
    -Detail $encoding.Trim()

# Changed-domain mode is useful only if every newly discovered boundary can be
# attributed to an owned slice.  Run this in all three modes: it is cheap, its
# output is deterministic, and a stale/missing map must block the seed rather
# than disappear merely because the broader framework gates were not selected.
Write-GateProgress -Stage 'affected-slice-map'
$sliceTool = Join-Path $PSScriptRoot 'Invoke-AffectedSliceMap.ps1'
if (-not (Test-Path -LiteralPath $sliceTool -PathType Leaf)) {
    Add-Row -Gate 'affected-slice-map' -State 'cannot-run' `
        -Detail 'the affected-slice authority tool is missing'
} else {
    $slice = & pwsh -NoProfile -File $sliceTool -Check -Quiet 2>&1 | Out-String
    $sliceCode = $LASTEXITCODE
    Add-Row -Gate 'affected-slice-map' `
        -State $(if ($sliceCode -eq 0) { 'pass' } elseif ($sliceCode -eq 2) { 'cannot-run' } else { 'fail' }) `
        -Detail $slice.Trim()
}

# The private-stripped trees are a distinct release artifact. Run the cheap
# deterministic framework gates from THAT framework checkout, not from the
# developer tree that happened to launch the publisher, and bind the result to
# both exact staged tree hashes.
if ($isRelease) {
    Write-GateProgress -Stage 'staged-tree-hashes'
    function Get-StagedHash {
        param([Parameter(Mandatory)][string]$Root)
        $output = & git -C $Root write-tree 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return @{ Code = $LASTEXITCODE; Hash = ''; Output = $output.Trim() } }
        return @{ Code = 0; Hash = $output.Trim(); Output = '' }
    }
    $frameworkHash = Get-StagedHash -Root $RepoRoot
    $projectHash = Get-StagedHash -Root $ProjectRoot
    foreach ($hashRow in @(
            @{ Name = 'framework'; Actual = $frameworkHash; Expected = $FrameworkTreeHash }
            @{ Name = 'project'; Actual = $projectHash; Expected = $ProjectTreeHash })) {
        $detail = ''
        $state = 'pass'
        if ($hashRow.Actual.Code -ne 0) {
            $state = 'cannot-run'; $detail = "$($hashRow.Name) staged hash unavailable: $($hashRow.Actual.Output)"
        } elseif (-not $hashRow.Expected) {
            $state = 'fail'; $detail = "$($hashRow.Name) expected staged hash was not supplied"
        } elseif ($hashRow.Actual.Hash -cne $hashRow.Expected) {
            $state = 'fail'; $detail = "$($hashRow.Name) staged hash $($hashRow.Actual.Hash) does not match $($hashRow.Expected)"
        } else {
            $detail = "$($hashRow.Name) staged tree $($hashRow.Actual.Hash)"
        }
        Add-Row -Gate "staged-$($hashRow.Name)-hash" -State $state -Detail $detail
    }

}

$releaseHashesPass = -not $isRelease -or
    @($rows | Where-Object { $_.Gate -like 'staged-*-hash' -and $_.State -eq 'pass' }).Count -eq 2
$executeFramework = $runFramework -and $releaseHashesPass
if ($runFramework -and -not $executeFramework) {
    Add-Row -Gate 'framework-gate-set' -State 'not-applicable' `
        -Detail 'not executed because the supplied staged tree pair did not match the candidate indexes'
}

if ($executeFramework) {
    foreach ($gate in $frameworkGates) {
        Write-GateProgress -Stage $gate.Name
        $tool = Join-Path $PSScriptRoot $gate.Script
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            Add-Row -Gate $gate.Name -State 'cannot-run' -Detail "staged tool is missing: $($gate.Script)"
            continue
        }
        $gateArguments = @('-NoProfile', '-File', $tool) + @($gate.Args)
        $gateOutput = & pwsh @gateArguments 2>&1 | Out-String
        $gateCode = $LASTEXITCODE
        Add-Row -Gate $gate.Name `
            -State $(if ($gateCode -eq 0) { 'pass' } elseif ($gateCode -eq 2) { 'cannot-run' } else { 'fail' }) `
            -Detail $gateOutput.Trim()
    }

    foreach ($focused in $focusedGates) {
        Invoke-FocusedPesterGate -Gate $focused.Gate -RelativePath $focused.RelativePath
    }

    $sliceEvidencePath = Join-Path $RepoRoot 'globalization/generated/affected-slice-map.json'
    $sliceEvidence = $null
    if (Test-Path -LiteralPath $sliceEvidencePath -PathType Leaf) {
        try { $sliceEvidence = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sliceEvidencePath)) }
        catch { $sliceEvidence = $null }
    }
    foreach ($engineeringRow in @(Get-EngineeringOpenRow -GateRows $rows.ToArray() `
            -SliceEvidence $sliceEvidence)) {
        Add-Row -Gate $engineeringRow.Gate -State $engineeringRow.State -Detail $engineeringRow.Detail `
            -Remediation $engineeringRow.Remediation
    }
}

# --- REGION: External validation limits
foreach ($na in @(
        @{ Gate = 'catalog-compile';  Why = 'catalogs live in the framework; full/release mode separately checks the framework tree' }
        @{ Gate = 'perf-baseline';    Why = 'the project serves no page; full/release mode separately checks the framework tree' }
        @{ Gate = 'go-build';         Why = 'the project ships no Go' }
        )) {
    if ($executeFramework -and $na.Gate -in @('catalog-compile', 'perf-baseline', 'go-build')) { continue }
    Add-Row -Gate $na.Gate -State 'not-applicable' -Detail $na.Why
}

# One deduplicated list of what to do next, in the order the gates ran, built
# from the rows themselves so a gate cannot be reported without one. It feeds
# both the evidence file and the console block below.
#
# Nothing here may throw. This script runs with $ErrorActionPreference = 'Stop',
# so a fault while assembling advisory text would end the run with no summary
# and no evidence file at all -- which a caller cannot tell apart from a gate
# that failed.
$actions = @()
try {
    $actionByCode = [ordered]@{}
    foreach ($actionRow in $rows) {
        $actionCode = [string]$actionRow.RemediationCode
        if (-not $actionCode) { continue }
        $actionGate = [string]$actionRow.Gate
        if (-not $actionGate) { $actionGate = '(unnamed gate)' }
        if (-not $actionByCode.Contains($actionCode)) {
            $actionByCode[$actionCode] = [ordered]@{
                code = $actionCode
                gates = [Collections.Generic.List[string]]::new()
                action = [string]$actionRow.Remediation
            }
        }
        if (-not $actionByCode[$actionCode].gates.Contains($actionGate)) {
            $actionByCode[$actionCode].gates.Add($actionGate)
        }
    }
    # One failing gate is the common case, so the single-element path is the one
    # that ships: an unwrapped collection of one unrolls to a scalar on its way
    # into ConvertTo-Json and serializes as an object where a reader expects an
    # array. Both @() here are load bearing.
    $actions = @($actionByCode.Values | ForEach-Object {
            [ordered]@{ code = $_.code; gates = @($_.gates); action = $_.action }
        })
} catch {
    $actions = @()
}

if ($EvidencePath) {
    $evidence = [ordered]@{
        schema = 'yuruna.cross-repo-gate/v1'
        mode = $Mode
        release = [bool]$isRelease
        frameworkTree = if ($isRelease -and $frameworkHash) { $frameworkHash.Hash } else { '' }
        projectTree = if ($isRelease -and $projectHash) { $projectHash.Hash } else { '' }
        # Before the rows: an operator opening this file is looking for what to
        # do, and the rows are long enough to bury it.
        actions = @($actions)
        rows = @($rows | ForEach-Object {
                [ordered]@{ gate = $_.Gate; state = $_.State; detail = $_.Detail
                    remediationCode = $_.RemediationCode; remediation = $_.Remediation }
            })
    }
    $json = ((ConvertTo-Json -InputObject $evidence -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n"
    [IO.File]::WriteAllText($EvidencePath, $json, [Text.UTF8Encoding]::new($false))
}

if ($script:StageBarDrawn) { Write-Progress -Id 1 -Activity "Cross-repository gate ($Mode)" -Completed }

if (-not $Quiet) {
    foreach ($r in $rows) {
        Write-Output ("{0,-20} {1,-16} {2}" -f $r.Gate, $r.State, $r.Detail)
    }
}

$failed = @($rows | Where-Object State -EQ 'fail')
$blocked = @($rows | Where-Object State -EQ 'cannot-run')
Write-Output ("Invoke-CrossRepoGate [{0}]: {1} gate(s) -- {2} pass, {3} fail, {4} cannot run, {5} not applicable." -f
    $Mode, $rows.Count,
    @($rows | Where-Object State -EQ 'pass').Count,
    $failed.Count, $blocked.Count,
    @($rows | Where-Object State -EQ 'not-applicable').Count)

# stdout is a parsed contract, and -Quiet exists to keep even the rows off it.
# The repair list goes to the information stream instead -- the same one the
# stage lines use, which the publisher's transcript captures -- so it reaches
# the operator in a quiet release run without joining the parsed output.
if ($actions.Count -gt 0) {
    Write-Information 'HOW TO FIX:' -InformationAction Continue
    foreach ($action in $actions) {
        Write-Information ("  [{0}] ({1}) {2}" -f $action.code, ($action.gates -join ', '), $action.action) `
            -InformationAction Continue
    }
}

if ($failed.Count -gt 0) { exit 1 }
# A gate that could not run is not a gate that passed, and a release run has to
# tell those apart. Exit 2 says so without claiming a failure in the project.
if ($blocked.Count -gt 0) { exit 2 }
exit 0
