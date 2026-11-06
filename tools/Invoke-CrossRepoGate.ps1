<#PSScriptInfo
.VERSION 2026.11.05
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
.PARAMETER GateThrottleLimit
    Maximum gates running at once. Every gate runs in a process of its own:
    the four project and amisad.dev stages one after another, then every other
    gate, focused Pester slices included, from one pool. Default: half the
    logical processors, at least 2 and at most 12; use 1 for serial execution.
.PARAMETER StageTimeoutSeconds
    The ceiling of every stage. A stage still running after this many seconds
    is stopped together with every process it started, and its row fails with
    a detail that says so. Default 1800. The longest healthy stage is the
    accessibility check: about 280 s of a five-minute full gate on a 32-thread
    host, where it loads 16 pages at once. It loads half as many pages at once
    for every halving of the logical processors, so an 8-thread host needs
    about 1100 s; 1800 s covers that with room and still turns a wedged
    browser, interpreter or suite into a failed row within half an hour.
    Raise it on a host where a healthy stage needs longer.
.PARAMETER SerialStage
    Internal: run one of the four serial stages (project-lint,
    project-shellcheck, project-tests, amisad-tests) in this process and print
    its rows on one YURUNA_GATE_STAGE line. The gate starts itself this way
    for each of them, so the ceiling can stop a stage with everything it
    started.
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
    [ValidateRange(1, 64)][int]$GateThrottleLimit = [Math]::Clamp([int][Math]::Floor([Environment]::ProcessorCount / 2), 2, 12),
    [ValidateRange(1, 86400)][int]$StageTimeoutSeconds = 1800,
    [Parameter(DontShow)][ValidateSet('project-lint', 'project-shellcheck', 'project-tests', 'amisad-tests')]
    [string]$SerialStage,
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
    .PARAMETER TimedOut
        The row's stage was stopped at the gate's ceiling.
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
        [string]$Detail,
        [switch]$TimedOut
    )

    if ($State -eq 'pass') { return $null }

    # A stage stopped at the ceiling has one repair whatever tool it ran, and
    # that tool's own entry below would send the reader after a defect the
    # stage never got far enough to report.
    if ($TimedOut) {
        return [pscustomobject]@{
            Code = 'stage-timeout'
            Action = 'A stage ran past the gate''s ceiling and was stopped together with every process it ' +
                'started; the detail says after how many seconds and ends with what the stage printed until ' +
                'then. Run the tool the row names on its own to tell a hang from a slow host: a tool that ' +
                'hangs needs its own wait bounded, and a host where a healthy stage needs longer runs the ' +
                'gate with -StageTimeoutSeconds <seconds> (default 1800).'
        }
    }

    # First match wins. Match is a regex over the detail; an empty Match takes
    # any state that is not a pass, which is what a gate whose details all lead
    # to the same repair needs.
    $table = @(
        @{ Gate = 'doc-translation'; Match = ''; Code = 'doc-source-drift'
            Action = 'An English document changed after its translation was last written, or a ' +
                'translation is missing. Version footers and release tags never stale a row. ' +
                'Maintainers draft the translation with the drafter''s Documents scope (pwsh ' +
                '-NoProfile -File dev-only/New-Translation.ps1 -Fill -Scope Documents -Locale <tag>) ' +
                'or import a professional return through the maintainers'' exchange; both record ' +
                'the row. Commit and push both private repositories; a working-tree fix is ' +
                'invisible to a release. Detail ''does not resolve'' means a relative link is ' +
                'broken: fix that link in the translation, or, when the translation''s links were ' +
                'copied verbatim from its English source, run tools/Test-DocTranslation.ps1 ' +
                '-RepairLinks -Locale <tag> -Path <source> (it rebases every relative link of the ' +
                'files it selects).' }
        @{ Gate = 'region-anchors'; Match = ''; Code = 'region-anchors'
            Action = 'A documentation region anchor or a public short-link target no longer resolves, or an ' +
                'implementation-note heading names a region other than the one its source pointer sits in. ' +
                'Re-run pwsh -NoProfile -File tools/Test-RegionAnchors.ps1 -HeadingRegion -ProjectRoot ' +
                '<project checkout> -LinkMap <yuruna.link.json>; the detail names the anchor and the file. ' +
                'Fix the heading or the link-map entry it names -- do not rename or merge the ' +
                'document, because a published short link 404s when its slug moves. Detail ''sits in ' +
                'region'' means the code moved under another REGION marker: rename the heading, and its ' +
                'translation, to the region its pointer now sits in and run pwsh -NoProfile -File ' +
                'tools/Invoke-DocAnchor.ps1 -Update; the anchor id stays, so published links keep working.' }
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
        @{ Gate = 'project-tests'; Match = ''; Code = 'project-tests'
            Action = 'The detail names each failing project test program and the last lines it printed. ' +
                'Run it from its own folder (python3 -B -m unittest <module> for test_*.py, python3 -B ' +
                '<file> for *_contracts.py, node <file> for *.test.js) and fix what it reports in the ' +
                'project repository. Detail ''python3 is not installed'' or ''node is not installed'' ' +
                'is a prerequisite gap: install the interpreter and re-run.' }
        @{ Gate = 'amisad-tests'; Match = ''; Code = 'amisad-tests'
            Action = 'The amisad.dev regression suite beside this checkout failed or produced no result. ' +
                'Run pwsh -NoProfile -File tools/_InvokeOneSuite.ps1 -Suite <amisad.dev>/test/' +
                'AmisAd.Regression.Tests.ps1 -Xml <file> and fix the failing cases in amisad.dev. ' +
                'Detail ''no amisad.dev checkout'' is not-applicable and needs nothing.' }
        @{ Gate = 'project-locale-map'; Match = ''; Code = 'locale-map'
            Action = 'The project locale map no longer matches the project''s own localized surface. Run ' +
                'pwsh -NoProfile -File tools/Invoke-ProjectLocaleMap.ps1 -ProjectRoot <project ' +
                'checkout> and follow what it reports, then commit what it writes in the project ' +
                'repository.' }
        @{ Gate = 'project-utf8'; Match = ''; Code = 'text-encoding'
            Action = 'A project text file is not valid UTF-8 or carries a BOM. Run pwsh -NoProfile -File ' +
                'tools/Test-ProjectTextEncoding.ps1 -ProjectRoot <project checkout>; it names the ' +
                'file. Re-save it as UTF-8 without a BOM.' }
        @{ Gate = 'source-metadata'; Match = ''; Code = 'source-metadata'
            Action = 'A code or manifest file in one of the four workspace repositories lacks its license ' +
                'pointer, copyright line or 42-prefixed GUID, two files declare the same GUID, or an entry ' +
                'of tools/source-metadata.exemptions.json no longer matches what it exempts. Run pwsh ' +
                '-NoProfile -File tools/Test-SourceMetadata.ps1 -All -Detail -Root <framework>,<project>,' +
                '<yuruna.link>,<amisad.dev> ; each finding names the file, the rule and the lines to add ' +
                '(CONTRIBUTING.md, Source metadata). Add the header it shows, or declare a generated or ' +
                'vendored path in the exemptions file with its reason. Detail ''is not usable'' means the ' +
                'exemptions file itself is invalid, and the lines after it say why.' }
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
            Action = 'Not a failure of its own: the seventeen framework gates and the six focused slices ' +
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
            Action = 'The compiled catalog artifacts do not match their sources, or a source is invalid. ' +
                'Run pwsh -NoProfile -File tools/Invoke-CatalogCompile.ps1 -Update and commit what it ' +
                'writes. -Update exits 0 when it is done, whether or not it wrote; 1 means a source ' +
                'is invalid (it names the problems), 2 that it could not run, and the check exits 3 ' +
                'for stale artifacts.' }
        @{ Gate = 'catalog-embed'; Match = ''; Code = 'catalog-embed'
            Action = 'A runtime copy no longer matches the catalog sources. Compile FIRST, then run pwsh ' +
                '-NoProfile -File tools/Invoke-CatalogEmbed.ps1 (writing is the default; there is ' +
                'no -Update, and it exits 0 after writing; the check exits 3 for a copy that would ' +
                'change and 1 for one that cannot be embedded). Regenerating the embed alone can never ' +
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
            Action = 'The glossary or style guide no longer matches its sources. Detail ''references ' +
                'a missing definition heading'': docs/definition.md lost a heading a term points at; ' +
                'restore the heading or update the term''s sourceHeadings. Detail ''retired-name ' +
                'ruling is not an exact hook pair'': the retired_names block in ' +
                'tools/githooks/pre-commit and the rulings in ' +
                'globalization/terminology/<tag>.terms.json disagree; make them identical. Detail ' +
                '''does not satisfy'': the file carries a field the schema does not define (a status, ' +
                'a source pin, a sign-off record or a person name); remove it.' }
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
            Action = 'Run test/modules/Test.DocReachability.Tests.ps1 directly under Pester 6; the ' +
                'detail names the failing test and its first error line. Detail ''required test file ' +
                'is missing'' means the tree does not carry that file. Detail ''Pester 6.x ' +
                'is not installed'' is a prerequisite gap: install Pester 6 and re-run. A skipped or ' +
                'not-run count makes this cannot-run, not pass.' }
        @{ Gate = 'code-registry-contract'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.CodeRegistry.Tests.ps1 directly under Pester 6; the detail ' +
                'names the failing test. The code registry feeds the affected-slice artifact, so ' +
                'fix this before regenerating that map. Same prerequisite notes as the other ' +
                'focused slices.' }
        @{ Gate = 'status-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.StatusServiceLocale.Tests.ps1 and ' +
                'test/modules/Test.StatusPauseSlice.Tests.ps1 directly under Pester 6; the detail ' +
                'names the failing test and container. This row is also the matrix gate for ' +
                'SEED-OPEN(status), so its failure closes that seed and W2-OPEN as well.' }
        @{ Gate = 'pool-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.PoolGlobalizationSlice.Tests.ps1 directly under Pester 6; ' +
                'the detail names the failing test. This row is the matrix gate for ' +
                'SEED-OPEN(pool), so its failure closes that seed and W2-OPEN as well.' }
        @{ Gate = 'reference-slice-matrix'; Match = ''; Code = 'focused-suite'
            Action = 'Run test/modules/Test.ReferenceSliceMatrix.Tests.ps1 directly under Pester 6; the ' +
                'detail names the failing test. It is a member of the shared prerequisite list, so ' +
                'its failure closes both seeds and W2-OPEN.' }
        @{ Gate = 'zot-qualification'; Match = ''; Code = 'focused-suite'
            Action = 'The caching-proxy seed pins a zot release, configuration or probe list that no live sync ' +
                'has qualified. Run python3 tools/Test-ZotRelease.py on a machine with internet access: it ' +
                'syncs the probe images through the pinned release and writes ' +
                'host/vmconfig/caching-proxy-service.zot-qualified.json; commit that record. When it reports ' +
                'that the release does not qualify, follow its instructions (usually an http.compat mode to add, ' +
                'or keeping the previously qualified release) instead of editing the record.' }
        @{ Gate = 'git-mirror-contract'; Match = ''; Code = 'focused-suite'
            Action = 'Run Test.GitMirrorQualification.Tests.ps1 with the documented suite runner; restore missing discovery or count-floor coverage before release.' }
        @{ Gate = 'host-git-mirror'; Match = ''; Code = 'focused-suite'
            Action = 'Run Test.HostGitMirror.Tests.ps1 with the documented suite runner and inspect its real worker/receipt fixtures.' }
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
function Invoke-ToolGateBatch {
    <#
    .SYNOPSIS
        Run independent tools in isolated processes and retain every outcome.
    .DESCRIPTION
        Every tool runs under the same ceiling. One still running when it
        expires is stopped together with every process it started -- a
        browser, an interpreter, a suite -- and its result says so, so a wedged
        tool costs the gate its ceiling instead of the whole run. Both output
        streams are drained while the tool runs: a tool that fills a pipe
        nobody reads would otherwise stall until the ceiling.
    .PARAMETER Work
        One item per tool: its Name and its Arguments, which run under this
        gate's own pwsh with -NonInteractive added, or under FilePath when the
        item carries one.
    .PARAMETER TimeoutSeconds
        The ceiling of each tool.
    .PARAMETER ResultOnly
        Return one result per tool (Name, Code, Output, Seconds, TimedOut)
        instead of recording rows, for a caller that judges some results itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Work,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int]$ThrottleLimit,
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds,
        [switch]$ResultOnly
    )
    $gatePowerShell = (Get-Process -Id $PID).Path
    # A process started here inherits the process's directory, not the
    # session's location, which is where a relative path given to the gate
    # was meant from.
    $location = (Get-Location -PSProvider FileSystem).ProviderPath
    # Parallel records use the parent's preference when forwarded to the host.
    $InformationPreference = 'Continue'
    $results = @($Work | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $ErrorActionPreference = 'Stop'
        $item = $_
        $limit = $using:TimeoutSeconds
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $timedOut = $false
        $process = $null
        try {
            if ($item.PSObject.Properties['FilePath']) {
                $start = [Diagnostics.ProcessStartInfo]::new([string]$item.FilePath)
            } else {
                $start = [Diagnostics.ProcessStartInfo]::new($using:gatePowerShell)
                $start.ArgumentList.Add('-NonInteractive')
            }
            foreach ($argument in [string[]]$item.Arguments) { $start.ArgumentList.Add($argument) }
            $start.UseShellExecute = $false
            $start.WorkingDirectory = $using:location
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $process = [Diagnostics.Process]::Start($start)
            $streams = @($process.StandardOutput.ReadToEndAsync(), $process.StandardError.ReadToEndAsync())
            $stopped = 'it was stopped with every process it started'
            if (-not $process.WaitForExit($limit * 1000)) {
                $timedOut = $true
                try { $process.Kill($true) } catch { $stopped = "stopping it failed: $($_.Exception.Message)" }
                $null = $process.WaitForExit(5000)
            }
            $code = if ($timedOut) { 124 } else { $process.ExitCode }
            # A process the tool left behind can hold a pipe open after the
            # tool is gone. Its output is not waited for past a short grace.
            $output = @($streams | ForEach-Object {
                    if ($_.Wait(5000)) { $_.Result.TrimEnd() } else { '[output still held open by a process the tool left behind]' }
                } | Where-Object { $_ }) -join "`n"
            if ($timedOut) {
                $output = "timed out after $limit s, the gate's ceiling for one stage; $stopped`n$output".TrimEnd()
            }
        } catch {
            $code = 2
            $output = $_.Exception.Message
        } finally {
            if ($process) { $process.Dispose() }
        }
        if ($timedOut) {
            Write-Information ("Stopped {0} at the {1}s ceiling" -f $item.Name, $limit) -InformationAction Continue
        } else {
            Write-Information ("Completed {0} in {1:n1}s (exit {2})" -f $item.Name, $clock.Elapsed.TotalSeconds, $code) -InformationAction Continue
        }
        [pscustomobject]@{
            Name = $item.Name; Code = $code; Output = $output.Trim()
            Seconds = $clock.Elapsed.TotalSeconds; TimedOut = $timedOut
        }
    })
    if ($ResultOnly) { return $results }
    foreach ($item in $Work) {
        $result = @($results | Where-Object Name -CEQ $item.Name)
        if ($result.Count -ne 1) {
            Add-Row -Gate $item.Name -State 'cannot-run' -Detail 'the tool worker did not return exactly one result'
            continue
        }
        $row = $result[0]
        Add-Row -Gate $item.Name -State $(if ($row.Code -eq 0) { 'pass' } elseif ($row.Code -eq 2) { 'cannot-run' } else { 'fail' }) `
            -Detail $row.Output -Seconds $row.Seconds -TimedOut:$row.TimedOut
    }
}

function Add-Row {
    param([string]$Gate, [string]$State, [string]$Detail,
        [string]$RemediationCode = '', [string]$Remediation = '', [Nullable[double]]$Seconds = $null,
        [switch]$TimedOut)
    # Derive the repair centrally. Every call site that only reports a state
    # keeps working unchanged, and no new one can add a row that fails without
    # telling the reader what to do about it. Both fields are advisory: a
    # consumer that knows only gate/state/detail keeps reading rows as before.
    if (-not $Remediation -and $State -in @('fail', 'cannot-run')) {
        $fix = Get-GateRemediation -Gate $Gate -State $State -Detail $Detail -TimedOut:$TimedOut
        if ($fix) { $RemediationCode = $fix.Code; $Remediation = $fix.Action }
    }
    $rows.Add([pscustomobject]@{
            Gate = $Gate; State = $State; Detail = $Detail
            RemediationCode = $RemediationCode; Remediation = $Remediation
            Seconds = if ($null -ne $Seconds) { [Math]::Round($Seconds, 3) } else { $null }
        })
}

function Add-SerialStageRow {
    <#
    .SYNOPSIS
        Run one serial stage in a process of its own and record the rows it reports.
    .DESCRIPTION
        The stage process prints its rows on one YURUNA_GATE_STAGE line. A stage
        stopped at the ceiling, or one that ends without that line, still
        leaves a failing row under its own name, so a stage cannot drop out of
        the gate's census.
    .PARAMETER Name
        The stage, which names its row when the stage reports none.
    .PARAMETER Arguments
        What the gate's pwsh runs for the stage.
    .PARAMETER TimeoutSeconds
        The ceiling of the stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSeconds
    )
    $outcome = @(Invoke-ToolGateBatch -Work @([pscustomobject]@{ Name = $Name; Arguments = $Arguments }) `
            -ThrottleLimit 1 -TimeoutSeconds $TimeoutSeconds -ResultOnly)
    if ($outcome.Count -ne 1) {
        Add-Row -Gate $Name -State 'cannot-run' -Detail 'the stage worker did not return exactly one result'
        return
    }
    $result = $outcome[0]
    if ($result.TimedOut) {
        Add-Row -Gate $Name -State 'fail' -Detail $result.Output -Seconds $result.Seconds -TimedOut
        return
    }
    $marker = 'YURUNA_GATE_STAGE '
    $line = @(([string]$result.Output) -split "`r?`n" | Where-Object { $_.StartsWith($marker) }) | Select-Object -Last 1
    $reported = @()
    $why = 'it printed no YURUNA_GATE_STAGE line'
    if ($line) {
        try { $reported = @(ConvertFrom-Json -InputObject $line.Substring($marker.Length)) }
        catch { $why = "its YURUNA_GATE_STAGE line does not parse: $($_.Exception.Message)" }
    }
    if ($reported.Count -eq 0) {
        Add-Row -Gate $Name -State $(if ($result.Code -eq 2) { 'cannot-run' } else { 'fail' }) -Seconds $result.Seconds `
            -Detail ("the stage reported no row (exit {0}): {1}`n{2}" -f $result.Code, $why, $result.Output).TrimEnd()
        return
    }
    foreach ($stageRow in $reported) {
        Add-Row -Gate ([string]$stageRow.gate) -State ([string]$stageRow.state) -Detail ([string]$stageRow.detail) `
            -Seconds $result.Seconds
    }
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

function Get-SourceMetadataRoot {
    <#
    .SYNOPSIS
        The four workspace checkouts the source-metadata row compares, and the
        ones that are not there.
    .DESCRIPTION
        The rules hold the framework's own repositories, so the project the
        gate was given counts only when it is a yuruna-project checkout, a
        staged clone or snapshot named so; a lab's own project is somebody
        else's repository and is never held to these headers, and the
        yuruna-project beside the framework is compared instead. yuruna.link
        sits beside the framework, and amisad.dev beside it or, cloned under
        its organization, at alius-git/amisad.dev: the places the region-anchor
        row reads them from. The publisher's work path holds its public clones
        and its two read-only checkouts side by side in the same way.
    .OUTPUTS
        [pscustomobject] carrying Root (the checkouts found, in that order) and
        Absent (the names of the ones that are not there).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$ProjectRoot
    )
    $workspace = Split-Path -Parent $FrameworkRoot
    $project = if ((Split-Path -Leaf $ProjectRoot.TrimEnd('/', '\')) -eq 'yuruna-project') { $ProjectRoot }
    else { Join-Path $workspace 'yuruna-project' }
    $found = [Collections.Generic.List[string]]::new()
    $found.Add($FrameworkRoot)
    $absent = [Collections.Generic.List[string]]::new()
    foreach ($sibling in @(
            @{ Name = 'yuruna-project'; Candidate = @($project) }
            @{ Name = 'yuruna.link'; Candidate = @(Join-Path $workspace 'yuruna.link') }
            @{ Name = 'amisad.dev'; Candidate = @((Join-Path $workspace 'amisad.dev'), (Join-Path $workspace 'alius-git/amisad.dev')) })) {
        $checkout = @($sibling.Candidate | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) | Select-Object -First 1
        if ($checkout) { $found.Add($checkout) } else { $absent.Add($sibling.Name) }
    }
    return [pscustomobject]@{ Root = $found.ToArray(); Absent = $absent.ToArray() }
}

function Get-FocusedPesterCompleteness {
    <#
    .SYNOPSIS
        Detect empty discovery, omitted files, lost cases and incomplete results.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string[]]$RequiredPath,
        [Parameter(Mandatory)][hashtable]$Counts,
        [Parameter(Mandatory)][hashtable]$Floors,
        [int]$IncompleteCount
    )
    foreach ($path in $RequiredPath) {
        if (-not $Counts.ContainsKey($path) -or [int]$Counts[$path] -lt 1) {
            "No tests discovered for required suite: $path"
        } elseif (-not $Floors.ContainsKey($path) -or [int]$Floors[$path] -lt 1) {
            "No recorded positive count floor for required suite: $path"
        } elseif ([int]$Counts[$path] -lt [int]$Floors[$path]) {
            "Required suite lost tests: $path ($($Counts[$path]) < $($Floors[$path]))"
        }
    }
    if ($IncompleteCount -gt 0) { "$IncompleteCount required tests were skipped or not run." }
}

function Add-FocusedPesterRow {
    <#
    .SYNOPSIS
        Record one focused slice from what tools/Invoke-FocusedPesterSlice.ps1 reported.
    .DESCRIPTION
        Full/release authority needs a few shipped-builder and documentation
        assertions that have no standalone tool. A fixed file list keeps that
        boundary reviewable. A missing file, skipped test, or container that
        never ran is reported separately from a clean result. The slice runs in
        a process of its own beside the other gates; this judges what it found.
    .PARAMETER Code
        The slice tool's exit code: 0 ran, 2 Pester 6.x missing, other failed to run.
    .PARAMETER Output
        Everything the slice tool printed; its facts are on the YURUNA_FOCUSED_SLICE line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Gate,
        [Parameter(Mandatory)][string[]]$RelativePath,
        [Parameter(Mandatory)][int]$Code,
        [AllowEmptyString()][string]$Output
    )
    if ($Code -eq 2) { Add-Row -Gate $Gate -State 'cannot-run' -Detail $Output.Trim(); return }
    $line = @(([string]$Output) -split "`r?`n" | Where-Object { $_.StartsWith('YURUNA_FOCUSED_SLICE ') }) | Select-Object -Last 1
    if ($Code -ne 0 -or -not $line) {
        $why = if ($Output.Trim()) { $Output.Trim() } else { "the slice exited $Code without reporting what it found" }
        if ($why -notlike 'focused Pester slice failed to execute*') { $why = "focused Pester slice failed to execute: $why" }
        Add-Row -Gate $Gate -State 'fail' -Detail $why
        return
    }
    try {
        $facts = ConvertFrom-Json -InputObject $line.Substring('YURUNA_FOCUSED_SLICE '.Length) -AsHashtable
        $failed = [int]$facts.failed
        $incomplete = [int]$facts.incomplete
        $baseline = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'test/modules/suite-baseline.json') | ConvertFrom-Json -AsHashtable
        $counts, $floors = @{}, @{}
        $platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
        foreach ($relative in $RelativePath) {
            if ($facts.counts.ContainsKey($relative)) { $counts[$relative] = [int]$facts.counts[$relative] }
            if ($baseline.suites.ContainsKey($relative)) {
                $record = $baseline.suites[$relative]
                $floors[$relative] = if ($record.ContainsKey('platformTotal') -and $record.platformTotal.ContainsKey($platform)) {
                    [int]$record.platformTotal[$platform]
                } else { [int]$record.total }
            }
        }
        $completeness = @(Get-FocusedPesterCompleteness -RequiredPath $RelativePath -Counts $counts -Floors $floors -IncompleteCount $incomplete)
        $detail = ("{0} passed, {1} failed, {2} skipped/not-run across {3} focused file(s)" -f `
            [int]$facts.passed, $failed, $incomplete, $RelativePath.Count)
        if ($completeness.Count) { $detail += '; ' + ($completeness -join '; ') }
        # Name AND reason. The marker rows downstream reduce this row to
        # "<gate> failed", so a detail that carries only test names leaves an
        # operator with no way to tell a real slice regression from a
        # prerequisite that could not run, and the only route to the reason is
        # re-running the slice by hand.
        $failedNames = @($facts.failedNames | Where-Object { $_ })
        if ($failed -gt 0 -and $failedNames.Count -gt 0) { $detail += '; failed: ' + ($failedNames -join ', ') }
        Add-Row -Gate $Gate `
            -State $(if ($failed -gt 0 -or $completeness.Count -gt 0) { 'fail' } elseif ($incomplete -gt 0) { 'cannot-run' } else { 'pass' }) `
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
    @{ Gate = 'reference-slice-matrix'; RelativePath = @('test/modules/Test.ReferenceSliceMatrix.Tests.ps1') }
    @{ Gate = 'zot-qualification'; RelativePath = @('test/modules/Test.ZotQualification.Tests.ps1') }
    @{ Gate = 'git-mirror-contract'; RelativePath = @('test/modules/Test.GitMirrorQualification.Tests.ps1') }
    @{ Gate = 'host-git-mirror'; RelativePath = @('test/modules/Test.HostGitMirror.Tests.ps1') })

$plannedStages = [Collections.Generic.List[string]]::new()
$plannedStages.AddRange([string[]]@('doc-translation', 'region-anchors', 'project-lint',
        'project-shellcheck', 'project-tests', 'amisad-tests', 'project-locale-map', 'project-utf8',
        'source-metadata', 'affected-slice-map'))
if ($isRelease) { $plannedStages.Add('staged-tree-hashes') }
if ($runFramework) {
    $plannedStages.AddRange([string[]]@($frameworkGates | ForEach-Object { $_.Name }))
    $plannedStages.AddRange([string[]]@($focusedGates | ForEach-Object { $_.Gate }))
}
# Progress counts what runs one after another: the four serial stages, the
# release tree hashes, and the pool as one stage.
$script:StageTotal = 5 + [int]$isRelease

# --- REGION: Cross-repository gates
# Every gate below reads the trees and writes nothing another gate reads, so
# after the four serial stages and the release tree hashes they all run in one
# pool of processes: the slow browser and Go checks beside the quick ones, and
# each focused Pester slice in a process of its own. Their rows are put back in
# the planned order before anything reads them.
$pool = [Collections.Generic.List[object]]::new()

# --- REGION: Project script validation
if ($SerialStage -eq 'project-lint') {
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
}

# Shell scripts the project ships into guests.
if ($SerialStage -eq 'project-shellcheck') {
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
            $shellPaths = [string[]]@($shell | ForEach-Object { Join-Path $ProjectRoot $_ })
            $shellOutput = & shellcheck --severity=error --format=gcc -- @shellPaths 2>&1 | Out-String
            $shellCode = $LASTEXITCODE
            Add-Row -Gate 'project-shellcheck' -State $(if ($shellCode -eq 0) { 'pass' } else { 'fail' }) `
                -Detail $(if ($shellCode -eq 0) { "$($shell.Count) script(s) clean" } else { "shellcheck exit ${shellCode}: $($shellOutput.Trim())" })
        }
    }
}

# --- REGION: Project test programs
# The project's tests are Python and Node programs that no runner of the
# project starts, so they run here beside its other checks, each from its own
# folder as its author runs it.
if ($SerialStage -eq 'project-tests') {
    $testPrograms = @()
    $testDiscoveryFailed = $false
    try { $testPrograms = @(Get-GitCandidatePath -Root $ProjectRoot -Include @('test_*.py', '*/test_*.py', '*_contracts.py', '*.test.cjs', '*.test.js')) }
    catch {
        $testDiscoveryFailed = $true
        Add-Row -Gate 'project-tests' -State 'cannot-run' -Detail $_.Exception.Message
    }
    if (-not $testDiscoveryFailed) {
        $python = Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($testPrograms.Count -eq 0) {
            Add-Row -Gate 'project-tests' -State 'not-applicable' -Detail 'the project ships no test programs'
        } elseif (@($testPrograms | Where-Object { $_ -like '*.py' }).Count -and -not $python) {
            Add-Row -Gate 'project-tests' -State 'cannot-run' -Detail 'python3 is not installed on this host'
        } elseif (@($testPrograms | Where-Object { $_ -notlike '*.py' }).Count -and -not $node) {
            Add-Row -Gate 'project-tests' -State 'cannot-run' -Detail 'node is not installed on this host'
        } else {
            $failedPrograms = [Collections.Generic.List[string]]::new()
            foreach ($rel in $testPrograms) {
                $full = Join-Path $ProjectRoot $rel
                $leaf = Split-Path -Leaf $full
                Push-Location -LiteralPath (Split-Path -Parent $full)
                try {
                    $programOutput = if ($leaf -like 'test_*.py') { & $python.Source -B -m unittest ([IO.Path]::GetFileNameWithoutExtension($leaf)) 2>&1 }
                        elseif ($leaf -like '*.py') { & $python.Source -B $leaf 2>&1 }
                        else { & $node.Source $leaf 2>&1 }
                    if ($LASTEXITCODE -ne 0) {
                        $failedPrograms.Add("$rel exit ${LASTEXITCODE}: $((@($programOutput) | Select-Object -Last 3) -join ' ')")
                    }
                } finally { Pop-Location }
            }
            Add-Row -Gate 'project-tests' -State $(if ($failedPrograms.Count -eq 0) { 'pass' } else { 'fail' }) `
                -Detail $(if ($failedPrograms.Count -eq 0) { "$($testPrograms.Count) program(s) passed" } else { $failedPrograms -join '; ' })
        }
    }
}

# --- REGION: amisad.dev regression suite
# amisad.dev is deployed by this framework and tested by its own Pester suite,
# which its hook does not run; where its checkout sits beside this one, it runs
# here through the same suite shim as every framework suite.
if ($SerialStage -eq 'amisad-tests') {
    $amisadRoot = Join-Path (Split-Path -Parent $RepoRoot) 'amisad.dev'
    $amisadSuite = Join-Path $amisadRoot 'test/AmisAd.Regression.Tests.ps1'
    if (-not (Test-Path -LiteralPath $amisadSuite -PathType Leaf)) {
        Add-Row -Gate 'amisad-tests' -State 'not-applicable' -Detail 'no amisad.dev checkout beside this one'
    } else {
        $amisadXml = Join-Path ([IO.Path]::GetTempPath()) ('amisad-regression-' + [guid]::NewGuid().ToString('N') + '.xml')
        try {
            $null = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $RepoRoot 'tools/_InvokeOneSuite.ps1') `
                -Suite $amisadSuite -Xml $amisadXml 2>&1
            if (-not (Test-Path -LiteralPath $amisadXml)) {
                Add-Row -Gate 'amisad-tests' -State 'fail' -Detail 'the suite produced no result file'
            } else {
                $results = ([xml](Get-Content -LiteralPath $amisadXml -Raw)).'test-results'
                $total = [int]$results.total
                $broken = [int]$results.failures + [int]$results.errors
                Add-Row -Gate 'amisad-tests' -State $(if ($total -gt 0 -and $broken -eq 0) { 'pass' } else { 'fail' }) `
                    -Detail "$total test(s), $broken failed, $([int]$results.skipped + [int]$results.'not-run' + [int]$results.ignored) skipped"
            }
        } catch {
            Add-Row -Gate 'amisad-tests' -State 'cannot-run' -Detail $_.Exception.Message
        } finally {
            Remove-Item -LiteralPath $amisadXml -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- REGION: Serial stages
# The four stages above run one after another, each in a process of its own:
# this script started again with -SerialStage. A check run inside this process
# could not be stopped at the ceiling, and the analyzer, interpreters and suite
# those stages start can hang. The stage process prints its rows on one line
# and ends there; the gate reads that line back into its own rows.
if ($SerialStage) {
    Write-Output ('YURUNA_GATE_STAGE ' + (ConvertTo-Json -Compress -Depth 3 -InputObject @($rows | ForEach-Object {
                    [ordered]@{ gate = $_.Gate; state = $_.State; detail = $_.Detail } })))
    exit 0
}
foreach ($serialStage in @('project-lint', 'project-shellcheck', 'project-tests', 'amisad-tests')) {
    Write-GateProgress -Stage $serialStage
    Add-SerialStageRow -Name $serialStage -TimeoutSeconds $StageTimeoutSeconds `
        -Arguments @('-NoProfile', '-File', $PSCommandPath, '-ProjectRoot', $ProjectRoot, '-SerialStage', $serialStage)
}

# The private-stripped trees are a distinct release artifact. Run the cheap
# deterministic framework gates from THAT framework checkout, not from the
# developer tree that happened to launch the publisher, and bind the result to
# both exact staged tree hashes.
if ($isRelease) {
    Write-GateProgress -Stage 'staged-tree-hashes'
    # Both trees at once, under the ceiling of one stage.
    $hashResults = @(Invoke-ToolGateBatch -ThrottleLimit 2 -TimeoutSeconds $StageTimeoutSeconds -ResultOnly -Work @(
            [pscustomobject]@{ Name = 'framework'; FilePath = 'git'; Arguments = @('-C', $RepoRoot, 'write-tree') }
            [pscustomobject]@{ Name = 'project'; FilePath = 'git'; Arguments = @('-C', $ProjectRoot, 'write-tree') }))
    function Get-StagedHash {
        param([Parameter(Mandatory)][string]$Name)
        $result = @($hashResults | Where-Object Name -CEQ $Name)
        if ($result.Count -ne 1) {
            return @{ Code = 2; Hash = ''; Output = 'the tool worker did not return exactly one result'; TimedOut = $false }
        }
        if ($result[0].Code -ne 0) {
            return @{ Code = $result[0].Code; Hash = ''; Output = $result[0].Output; TimedOut = $result[0].TimedOut }
        }
        return @{ Code = 0; Hash = $result[0].Output.Trim(); Output = ''; TimedOut = $false }
    }
    $frameworkHash = Get-StagedHash -Name 'framework'
    $projectHash = Get-StagedHash -Name 'project'
    foreach ($hashRow in @(
            @{ Name = 'framework'; Actual = $frameworkHash; Expected = $FrameworkTreeHash }
            @{ Name = 'project'; Actual = $projectHash; Expected = $ProjectTreeHash })) {
        $detail = ''
        $state = 'pass'
        if ($hashRow.Actual.TimedOut) {
            $state = 'fail'; $detail = $hashRow.Actual.Output
        } elseif ($hashRow.Actual.Code -ne 0) {
            $state = 'cannot-run'; $detail = "$($hashRow.Name) staged hash unavailable: $($hashRow.Actual.Output)"
        } elseif (-not $hashRow.Expected) {
            $state = 'fail'; $detail = "$($hashRow.Name) expected staged hash was not supplied"
        } elseif ($hashRow.Actual.Hash -cne $hashRow.Expected) {
            $state = 'fail'; $detail = "$($hashRow.Name) staged hash $($hashRow.Actual.Hash) does not match $($hashRow.Expected)"
        } else {
            $detail = "$($hashRow.Name) staged tree $($hashRow.Actual.Hash)"
        }
        Add-Row -Gate "staged-$($hashRow.Name)-hash" -State $state -Detail $detail -TimedOut:$hashRow.Actual.TimedOut
    }

}

$releaseHashesPass = -not $isRelease -or
    @($rows | Where-Object { $_.Gate -like 'staged-*-hash' -and $_.State -eq 'pass' }).Count -eq 2
$executeFramework = $runFramework -and $releaseHashesPass
if ($runFramework -and -not $executeFramework) {
    Add-Row -Gate 'framework-gate-set' -State 'not-applicable' `
        -Detail 'not executed because the supplied staged tree pair did not match the candidate indexes'
}

# Translated documents. This one already reads both trees, which is why the
# project's pt-BR drafts have been drift-checked all along.
$pool.Add([pscustomobject]@{ Name = 'doc-translation'
        Arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-DocTranslation.ps1'), '-ProjectRoot', $ProjectRoot, '-Quiet') })

# Documentation anchors and the public link map, which span both repositories,
# and the heading check: a pointer whose heading names a region other than the
# one the pointer sits in fails this row.
$anchorArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-RegionAnchors.ps1'), '-HeadingRegion',
    '-ProjectRoot', $ProjectRoot)
if ($LinkMap) { $anchorArgs += @('-LinkMap', $LinkMap) }
$pool.Add([pscustomobject]@{ Name = 'region-anchors'; Arguments = $anchorArgs })

# Parse and validate the complete additive project-map contract through its one
# authoritative tool.  A regex here would silently disagree on quoted keys,
# nested maps, canonical locale tags, bounds, or source-hash provenance.
$pool.Add([pscustomobject]@{ Name = 'project-locale-map'
        Arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-ProjectLocaleMap.ps1'), '-ProjectRoot', $ProjectRoot, '-Quiet') })

# Exact bytes, not ReadAllText's forgiving default. The recorded inventory is
# also reverse-checked here so removing one project path cannot shrink the gate.
$pool.Add([pscustomobject]@{ Name = 'project-utf8'
        Arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-ProjectTextEncoding.ps1'), '-ProjectRoot', $ProjectRoot, '-Quiet') })

# License headers and GUIDs across the four workspace repositories, with any
# finding a failure, so a GUID stays unique across all of them at every run and
# at release. These are the framework's own repositories: a project of another
# name is not held to their headers (Get-SourceMetadataRoot). Compared without one of them, a GUID that only the absent one
# shares would pass, so an absent checkout makes the row not applicable, the
# state the amisad.dev suite row gives a checkout that is not there.
$metadataRoot = Get-SourceMetadataRoot -FrameworkRoot $RepoRoot -ProjectRoot $ProjectRoot
if ($metadataRoot.Absent.Count -gt 0) {
    Add-Row -Gate 'source-metadata' -State 'not-applicable' `
        -Detail ('no {0} checkout in this workspace, so the four repositories are not compared' -f ($metadataRoot.Absent -join ' or '))
} else {
    $pool.Add([pscustomobject]@{ Name = 'source-metadata'
            Arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Test-SourceMetadata.ps1'), '-All', '-FailOnDebt',
                '-Root', ($metadataRoot.Root -join ',')) })
}

# Changed-domain mode is useful only if every newly discovered boundary can be
# attributed to an owned slice.  Run this in all three modes: it is cheap, its
# output is deterministic, and a stale/missing map must block the seed rather
# than disappear merely because the broader framework gates were not selected.
$sliceTool = Join-Path $PSScriptRoot 'Invoke-AffectedSliceMap.ps1'
if (-not (Test-Path -LiteralPath $sliceTool -PathType Leaf)) {
    Add-Row -Gate 'affected-slice-map' -State 'cannot-run' `
        -Detail 'the affected-slice authority tool is missing'
} else {
    $pool.Add([pscustomobject]@{ Name = 'affected-slice-map'; Arguments = @('-NoProfile', '-File', $sliceTool, '-Check', '-Quiet') })
}

if ($executeFramework) {
    foreach ($gate in $frameworkGates) {
        $tool = Join-Path $PSScriptRoot $gate.Script
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
            Add-Row -Gate $gate.Name -State 'cannot-run' -Detail "staged tool is missing: $($gate.Script)"
            continue
        }
        $pool.Add([pscustomobject]@{ Name = $gate.Name; Arguments = @('-NoProfile', '-File', $tool) + @($gate.Args) })
    }
    $focusedTool = Join-Path $PSScriptRoot 'Invoke-FocusedPesterSlice.ps1'
    foreach ($focused in $focusedGates) {
        $missing = @($focused.RelativePath | ForEach-Object { Join-Path $RepoRoot $_ } |
            Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
        if ($missing.Count -gt 0) {
            Add-Row -Gate $focused.Gate -State 'cannot-run' -Detail ('required test file is missing: ' + ($missing -join ', '))
            continue
        }
        if (-not (Test-Path -LiteralPath $focusedTool -PathType Leaf)) {
            Add-Row -Gate $focused.Gate -State 'cannot-run' -Detail 'staged tool is missing: Invoke-FocusedPesterSlice.ps1'
            continue
        }
        $pool.Add([pscustomobject]@{ Name = $focused.Gate; Focused = [string[]]$focused.RelativePath
                Arguments = @('-NoProfile', '-File', $focusedTool, '-RelativePath', (@($focused.RelativePath) -join ';')) })
    }
}

Write-GateProgress -Stage "$($pool.Count) gates in parallel, at most $GateThrottleLimit at once"
$poolResults = @(Invoke-ToolGateBatch -Work $pool.ToArray() -ThrottleLimit $GateThrottleLimit `
        -TimeoutSeconds $StageTimeoutSeconds -ResultOnly)
foreach ($item in $pool) {
    $result = @($poolResults | Where-Object Name -CEQ $item.Name)
    if ($result.Count -ne 1) {
        Add-Row -Gate $item.Name -State 'cannot-run' -Detail 'the tool worker did not return exactly one result'
        continue
    }
    $outcome = $result[0]
    if ($outcome.TimedOut) {
        Add-Row -Gate $item.Name -State 'fail' -Detail $outcome.Output -Seconds $outcome.Seconds -TimedOut
    } elseif ($item.PSObject.Properties['Focused']) {
        Add-FocusedPesterRow -Gate $item.Name -RelativePath $item.Focused -Code $outcome.Code -Output $outcome.Output
    } else {
        Add-Row -Gate $item.Name -State $(if ($outcome.Code -eq 0) { 'pass' } elseif ($outcome.Code -eq 2) { 'cannot-run' } else { 'fail' }) `
            -Detail $outcome.Output -Seconds $outcome.Seconds
    }
}

if ($executeFramework) {
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

# --- REGION: Row order
# The pool finishes in any order. Rows are reported in the planned gate order;
# a row outside the plan keeps the place it was added in, after the planned ones.
$plannedOrder = @{}
for ($stageNumber = 0; $stageNumber -lt $plannedStages.Count; $stageNumber++) { $plannedOrder[$plannedStages[$stageNumber]] = $stageNumber }
$rowNumber = 0
$orderedRows = @($rows | ForEach-Object { [pscustomobject]@{ Row = $_; Added = $rowNumber++ } } |
    Sort-Object -Property @{ Expression = {
            $name = [string]$_.Row.Gate
            if ($name -like 'staged-*-hash') { $name = 'staged-tree-hashes' }
            if ($plannedOrder.ContainsKey($name)) { $plannedOrder[$name] } else { [int]::MaxValue }
        } }, Added | ForEach-Object Row)
$rows.Clear()
foreach ($orderedRow in $orderedRows) { $rows.Add($orderedRow) }

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
                    remediationCode = $_.RemediationCode; remediation = $_.Remediation; seconds = $_.Seconds }
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
