<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42c7d3a9-5e1b-4f80-9a2c-6d8e3f1b0a47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Sequence-file reading and search-path resolution. Read-SequenceFile parses a
# YAML sequence into an OrderedDictionary; Resolve-SequencePath /
# Get-SequenceSearchPath / Get-ProjectFlatTestSearchDir /
# Find-ProjectFlatSequenceFile build the flat candidate paths.
# Read-SequenceFile imports powershell-yaml on demand, so this module
# carries no engine $script: state.

function ConvertTo-NormalizedSequence {
    <#
    .SYNOPSIS
        Loads the resource/component/workload guest-sequence shape into the
        engine's internal representation, rejecting the removed legacy shape.
    .DESCRIPTION
        The sequence contract is: a guest sequence declares a
        `keystrokeMechanism` (gui|ssh, default gui), a `resource:` prerequisite
        map, and ordered `component:` + `workload:` action lists. The legacy
        `baseline:` key and top-level `steps:` list are NO LONGER accepted --
        either one on a guest sequence is a hard error pointing at the migration.

        Internally the engine still consumes `baseline` (the prereq chain) and a
        single flat `steps` list, so this loader synthesizes those from
        `resource` and `component` ++ `workload` and defaults a missing
        `keystrokeMechanism` to `gui`. Pure: an orchestration sequence
        (InvokeTestSequence `steps:`, no `resource:`) or a host-action sequence
        (`host:` block) is returned untouched; a guest sequence returns a SHALLOW
        COPY with the synthesized keys, never mutating the mtime-cached parse.
    #>
    param($Sequence)
    if ($Sequence -isnot [System.Collections.IDictionary]) { return $Sequence }
    # Reject the removed legacy shape. Every legacy guest sequence carried a
    # `baseline:`; an orchestration/host sequence never did, so keying the guest
    # rejection on `baseline` cannot misfire on the untouched shapes.
    if ($Sequence.Contains('baseline')) {
        throw "Legacy 'baseline:' is no longer supported -- rename it to 'resource:'. See docs/test-sequences.md (resource/component/workload)."
    }
    if (-not $Sequence.Contains('resource')) { return $Sequence }   # orchestration / host-action
    if ($Sequence.Contains('steps')) {
        throw "A guest sequence must not use top-level 'steps:' -- split its actions into 'component:' and 'workload:'. See docs/test-sequences.md."
    }
    $out = [ordered]@{}
    foreach ($k in $Sequence.Keys) { $out[$k] = $Sequence[$k] }
    if (-not $out.Contains('keystrokeMechanism')) { $out['keystrokeMechanism'] = 'gui' }
    $out['baseline'] = $Sequence['resource']
    $merged = New-Object System.Collections.Generic.List[object]
    if ($Sequence.Contains('component') -and $Sequence['component']) { foreach ($s in @($Sequence['component'])) { [void]$merged.Add($s) } }
    if ($Sequence.Contains('workload')  -and $Sequence['workload'])  { foreach ($s in @($Sequence['workload']))  { [void]$merged.Add($s) } }
    $out['steps'] = $merged.ToArray()
    return $out
}

function Read-SequenceFile {
    <#
    .SYNOPSIS
        Parses a YAML sequence file into an OrderedDictionary.
    .DESCRIPTION
        Centralises the powershell-yaml dependency for every sequence reader
        (Invoke-Sequence, Test.SequencePlanner, Test-Sequence). Uses
        -Ordered so the steps array and the variables map preserve their
        on-disk order. The returned object is an [OrderedDictionary]; callers
        must use .Keys / .Contains() rather than .PSObject.Properties, since
        the YAML parser does not produce PSCustomObject.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        # Bypass the mtime-keyed cache for diagnostic / probe call
        # sites that need a guaranteed fresh read.
        [switch]$NoCache
    )
    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "powershell-yaml is required to read sequence files. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    # Mtime-keyed parse cache, parallel to Test.Config's pattern.
    # The planner walks every sequence in the chain once per Resolve-
    # CyclePlan call; without a cache that's 50+ YAML parses per cycle
    # (~300-500 ms). Cache key is absolute path + LastWriteTimeUtc.
    if (-not $script:SequenceFileCache) { $script:SequenceFileCache = @{} }
    if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
        try {
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
            if ($script:SequenceFileCache.ContainsKey($resolved)) {
                $entry = $script:SequenceFileCache[$resolved]
                if ($entry.Mtime -eq $mtime) { return (Expand-SequenceSnippet -Sequence (ConvertTo-NormalizedSequence $entry.Parsed) -Path $Path) }
            }
        } catch {
            # A mid-cycle rename/delete between the Test-Path above and Resolve-Path here would
            # throw a TERMINATING error outside the main try/catch below; swallow it and fall
            # through to the guarded read, which surfaces the real not-found/parse error cleanly.
            Write-Verbose "Read-SequenceFile: cache probe of '$Path' raced a rename/delete: $($_.Exception.Message)"
        }
    }
    try {
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
            $script:SequenceFileCache[$resolved] = @{ Mtime = $mtime; Parsed = $parsed }
        }
        return (Expand-SequenceSnippet -Sequence (ConvertTo-NormalizedSequence $parsed) -Path $Path)
    } catch {
        # YamlDotNet's SyntaxErrorException carries Start/End marks with
        # Line/Column, but powershell-yaml wraps it in a generic
        # MethodInvocationException whose message just says "Exception
        # calling 'Load' with '1' argument(s): <inner>". Walk the
        # InnerException chain to find the SyntaxErrorException, pull the
        # marks, and re-throw with file path + line:col so the operator
        # doesn't have to bisect the sequence tree by hand.
        $err = $_.Exception
        $synErr = $null
        $probe = $err
        while ($probe) {
            if ($probe.GetType().FullName -eq 'YamlDotNet.Core.SyntaxErrorException') {
                $synErr = $probe; break
            }
            $probe = $probe.InnerException
        }
        if ($synErr) {
            $line = $synErr.Start.Line
            $col  = $synErr.Start.Column
            throw "YAML parse error in $Path at line ${line}:${col}: $($synErr.Message)"
        }
        throw "YAML parse error in $Path`: $($err.Message)"
    }
}

# Sequences are flat and select gui vs ssh by their own `keystrokeMechanism`
# and by the `.ssh` name segment -- there is no machine-global mode and no
# gui/ssh subfolder resolution.

<#
.SYNOPSIS
    Flat-shape project search dirs: every directory named `test` beneath the
    project clone (e.g. project/example/website/test/, project/poc/test/).
.DESCRIPTION
    The flat project shape keeps each sequence directly in its `test/` parent
    (no gui/ssh subfolders), with the ssh variant carrying a `.ssh` name
    segment instead of an ssh/ subfolder. This returns those `test/` dirs so
    Resolve-SequencePath can find a project sequence by exact name.
    Cached by RepoRoot + project-root mtime.
#>
function Get-ProjectFlatTestSearchDir {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $projectRoot = Join-Path $RepoRoot 'project'
    if (-not (Test-Path $projectRoot)) { return @() }
    if (-not $script:ProjectFlatSearchDirCache) { $script:ProjectFlatSearchDirCache = @{} }
    $rootMtime = (Get-Item -LiteralPath $projectRoot -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($script:ProjectFlatSearchDirCache.ContainsKey($RepoRoot)) {
        $entry = $script:ProjectFlatSearchDirCache[$RepoRoot]
        if ($entry.Mtime -eq $rootMtime) { return $entry.Dirs }
    }
    $dirs = @(
        Get-ChildItem -Path $projectRoot -Directory -Recurse -Filter 'test' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
    $script:ProjectFlatSearchDirCache[$RepoRoot] = @{ Mtime = $rootMtime; Dirs = $dirs }
    return $dirs
}

<#
.SYNOPSIS
    Returns the single flat-project match for $FileName under any test/ folder.
.DESCRIPTION
    Flat-shape counterpart of Find-ProjectSequenceFile: scans every `test/` dir
    from Get-ProjectFlatTestSearchDir for an exact $FileName. Returns the full
    path on a single hit, $null on none, and throws PlannerFatal on >=2 hits
    (an ambiguous plan the operator must resolve), mirroring the mode-folder rule.
#>
function Find-ProjectFlatSequenceFile {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$FileName
    )
    $hits = @(
        foreach ($d in (Get-ProjectFlatTestSearchDir -RepoRoot $RepoRoot)) {
            $candidate = Join-Path $d $FileName
            if (Test-Path -LiteralPath $candidate) { $candidate }
        }
    )
    if ($hits.Count -gt 1) {
        $list = Format-SequenceSearchList -Item $hits
        throw "PlannerFatal: $($hits.Count) project sequence files named '$FileName' found under flat test/ folders:`n$list`nKeep only one so the planner can resolve a single sequence file."
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

function Get-FlatSequenceCandidate {
    <#
    .SYNOPSIS
        Ordered flat-shape filename candidates for a sequence name.
    .DESCRIPTION
        Resolution is by exact name. A host-specific variant
        (`$Name.$HostShort.yml`) precedes the unsuffixed `$Name.yml`. The ssh
        variant of a sequence is a distinct `$Name.ssh.yml` file selected by its
        own explicit `.ssh` name (which arrives here as part of `$Name`), so
        there is no machine-global mode preference.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$HostShort
    )
    $names = New-Object System.Collections.Generic.List[string]
    if ($HostShort) { [void]$names.Add("$Name.$HostShort.yml") }
    [void]$names.Add("$Name.yml")
    return $names.ToArray()
}

<#
.SYNOPSIS
    Resolves a sequence name to a flat sequence file, project-then-framework.
.DESCRIPTION
    Flat exact-name resolution:
      1. Project tree: project/<...>/test/<Name>.[<host-short>.]yml
      2. Framework:    <SequencesDir>/<Name>.[<host-short>.]yml
    A project match wins so a project can override a framework sequence of the
    same name; a host-specific variant wins over the plain file. The ssh variant
    of a sequence is a distinct `<Name>.ssh.yml` selected by its explicit name.
    Returns $null when nothing matches -- pair with Get-SequenceSearchPath to
    report the probed locations rather than inventing a "resolved" path.
.PARAMETER SequencesDir
    Path to the framework sequences root (e.g. test/sequences).
.PARAMETER Name
    Sequence basename without extension, e.g. "workload.guest.ubuntu.server.24"
    or "workload.guest.ubuntu.server.24.ssh".
.PARAMETER HostType
    Optional. When supplied, host-specific variants (<Name>.<host-short>.yml)
    are tried before the unsuffixed file.
.PARAMETER RepoRoot
    Optional. When supplied, project-tree dirs (project/<...>/test/) are searched
    first. Omit for framework-only resolution.
#>
function Resolve-SequencePath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    # When a HostType is provided, prefer a host-specific sequence file
    # (filename suffix == HostType minus the 'host.' prefix). This lets a single
    # GuestKey ship divergent sequences across hosts. When $HostType is
    # null/empty the host-specific candidate is skipped.
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }

    # Default RepoRoot to parent of SequencesDir's parent (test/sequences -> test -> repo).
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    $flatNames = Get-FlatSequenceCandidate -Name $Name -HostShort $hostShort
    # Project tree wins. -LiteralPath throughout so a $Name with wildcard
    # metacharacters ([ ] * ?) is probed literally, not glob-expanded.
    if ($RepoRoot) {
        foreach ($fn in $flatNames) {
            $hit = Find-ProjectFlatSequenceFile -RepoRoot $RepoRoot -FileName $fn
            if ($hit) { return $hit }
        }
    }
    foreach ($fn in $flatNames) {
        $flatFwPath = Join-Path $SequencesDir $fn
        if (Test-Path -LiteralPath $flatFwPath) { return $flatFwPath }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the ordered list of paths Resolve-SequencePath would attempt for $Name.
.DESCRIPTION
    Mirrors the flat search order of Resolve-SequencePath without touching the
    filesystem -- project test/ dirs then the framework SequencesDir, each with
    the host-suffix and plain candidates -- so callers can show the operator
    exactly which locations were checked when nothing matched. Use this in
    "sequence not found" diagnostics instead of printing the last-attempted path.
#>
function Get-SequenceSearchPath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    $paths = New-Object System.Collections.Generic.List[string]
    $flatNames = Get-FlatSequenceCandidate -Name $Name -HostShort $hostShort
    if ($RepoRoot) {
        foreach ($d in (Get-ProjectFlatTestSearchDir -RepoRoot $RepoRoot)) {
            foreach ($fn in $flatNames) { [void]$paths.Add((Join-Path $d $fn)) }
        }
    }
    foreach ($fn in $flatNames) { [void]$paths.Add((Join-Path $SequencesDir $fn)) }
    return $paths.ToArray()
}

# -- Step-snippet library -----------------------------------------------------
# A snippet is a named, reusable list of steps spliced into a sequence wherever
# a `{ snippet: <name> }` step appears (including inside retry.steps), so common
# preambles like the cold-agetty login prime live in one place instead of being
# copied across every workload sequence. Libraries are `_snippets.yml` files (a
# map of name -> step-array) living beside the sequences: framework
# `test/sequences/_snippets.yml` and project `project/<...>/test/_snippets.yml`.
# Project entries override framework ones of the same name (mirrors
# Resolve-SequencePath's project-wins layering);
# two PROJECT libraries defining the same name is a fatal ambiguity. Expansion
# runs inside Read-SequenceFile so every consumer (executor, planner, perf, step
# windows) sees the already-spliced steps with no per-call-site wiring.

function Copy-YamlNode {
    # Deep-clones a powershell-yaml node (OrderedDictionary / list / scalar) so a
    # spliced snippet step never shares a reference with the mtime-cached library
    # parse -- a downstream in-place edit must not poison the cache or bleed into
    # another sequence that reuses the same snippet.
    param($Node)
    if ($Node -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($k in $Node.Keys) { $copy[$k] = Copy-YamlNode $Node[$k] }
        return $copy
    }
    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Node) { [void]$list.Add((Copy-YamlNode $item)) }
        return ,($list.ToArray())
    }
    return $Node
}

function Test-StepHasSnippet {
    # True when $Steps (or any nested retry.steps) contains a `{snippet: ...}`
    # element. Lets Read-SequenceFile skip the clone-and-expand path entirely for
    # the common snippet-free sequence (zero overhead, returns the cached object).
    param($Steps)
    if ($null -eq $Steps) { return $false }
    foreach ($s in $Steps) {
        if ($s -is [System.Collections.IDictionary]) {
            if ($s.Contains('snippet')) { return $true }
            if ($s.Contains('steps') -and (Test-StepHasSnippet $s['steps'])) { return $true }
        }
    }
    return $false
}

function Get-SnippetLibraryFile {
    # Parses one _snippets.yml into an OrderedDictionary, cached by abs-path +
    # mtime (parallel to Read-SequenceFile's own cache) so the planner's repeated
    # reads don't re-parse, yet a library edit is picked up on the next call.
    param([Parameter(Mandatory)][string]$LibPath)
    if (-not (Test-Path -LiteralPath $LibPath)) { return $null }
    if (-not $script:SnippetFileCache) { $script:SnippetFileCache = @{} }
    $resolved = (Resolve-Path -LiteralPath $LibPath).Path
    $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
    if ($script:SnippetFileCache.ContainsKey($resolved)) {
        $entry = $script:SnippetFileCache[$resolved]
        if ($entry.Mtime -eq $mtime) { return $entry.Parsed }
    }
    $parsed = Get-Content -Raw -LiteralPath $resolved | ConvertFrom-Yaml -Ordered
    $script:SnippetFileCache[$resolved] = @{ Mtime = $mtime; Parsed = $parsed }
    return $parsed
}

function Get-SnippetMap {
    <#
    .SYNOPSIS
        Builds name -> @{Steps; File; Tier} for the snippet libraries visible to
        the sequence at $SequencePath.
    .DESCRIPTION
        Framework libraries load first (base); project libraries then override by
        name. Two PROJECT libraries defining the same name throw PlannerFatal (an
        ambiguous plan), mirroring Find-ProjectSequenceFile's duplicate rule.
    #>
    param([Parameter(Mandatory)][string]$SequencePath)

    $norm    = ($SequencePath -replace '\\', '/')
    $modeDir = Split-Path -Parent $SequencePath
    # Locate the repo root from the flat sequence path: framework
    # test/sequences/<file> or project project/<...>/test/<file>.
    $repoRoot = $null
    if     ($norm -match '(?i)/project/.+/test/[^/]+$') { $repoRoot = ($norm -replace '(?i)/project/.+$', '') }
    elseif ($norm -match '(?i)/test/sequences/[^/]+$')  { $repoRoot = ($norm -replace '(?i)/test/sequences/[^/]+$', '') }

    $frameworkLibs = New-Object System.Collections.Generic.List[string]
    $projectLibs   = New-Object System.Collections.Generic.List[string]
    if ($repoRoot) {
        $fw = Join-Path (Join-Path (Join-Path $repoRoot 'test') 'sequences') '_snippets.yml'
        if (Test-Path -LiteralPath $fw) { [void]$frameworkLibs.Add($fw) }
        foreach ($d in (Get-ProjectFlatTestSearchDir -RepoRoot $repoRoot)) {
            $pl = Join-Path $d '_snippets.yml'
            if (Test-Path -LiteralPath $pl) { [void]$projectLibs.Add($pl) }
        }
    }
    # Always consider the sequence's own dir (covers standalone temp dirs used by
    # tests and any layout the regexes above didn't recognise). De-dup against
    # the tiers already collected so a framework/project file isn't double-loaded.
    $localLib = Join-Path $modeDir '_snippets.yml'
    if (Test-Path -LiteralPath $localLib) {
        $localResolved = (Resolve-Path -LiteralPath $localLib).Path
        $known = @()
        foreach ($f in (@($frameworkLibs) + @($projectLibs))) { $known += (Resolve-Path -LiteralPath $f).Path }
        if ($localResolved -notin $known) { [void]$projectLibs.Add($localLib) }
    }

    $map = @{}
    foreach ($f in $frameworkLibs) {
        $doc = Get-SnippetLibraryFile -LibPath $f
        if ($doc -isnot [System.Collections.IDictionary]) { continue }
        foreach ($name in $doc.Keys) {
            $key = [string]$name
            if ($doc[$name] -isnot [System.Collections.IEnumerable] -or $doc[$name] -is [string]) {
                throw "PlannerFatal: snippet '$key' in $f is not a list of steps."
            }
            $map[$key] = @{ Steps = $doc[$name]; File = $f; Tier = 'framework' }
        }
    }
    foreach ($p in $projectLibs) {
        $doc = Get-SnippetLibraryFile -LibPath $p
        if ($doc -isnot [System.Collections.IDictionary]) { continue }
        foreach ($name in $doc.Keys) {
            $key = [string]$name
            if ($doc[$name] -isnot [System.Collections.IEnumerable] -or $doc[$name] -is [string]) {
                throw "PlannerFatal: snippet '$key' in $p is not a list of steps."
            }
            if ($map.ContainsKey($key) -and $map[$key].Tier -eq 'project') {
                throw "PlannerFatal: snippet '$key' is defined in two project libraries:`n    $($map[$key].File)`n    $p`nKeep only one so the reference resolves unambiguously."
            }
            $map[$key] = @{ Steps = $doc[$name]; File = $p; Tier = 'project' }
        }
    }
    return $map
}

function Expand-StepList {
    # Returns a NEW step array with every {snippet:name} replaced by that
    # snippet's (recursively expanded, deep-cloned) steps. $Visiting guards
    # against snippet->snippet cycles; $Depth is a backstop ceiling. retry.steps
    # (and any other nested `steps`) are walked so snippets work at any depth.
    # NOTE: $Steps / $Map / $Visiting are intentionally NOT [Parameter(Mandatory)]:
    # an empty collection (e.g. a fresh HashSet, or an empty step list) fails
    # mandatory binding with "Cannot bind argument ... empty collection".
    param(
        $Steps,
        [hashtable]$Map,
        [System.Collections.Generic.HashSet[string]]$Visiting,
        [Parameter(Mandatory)][string]$SeqPath,
        [int]$Depth = 0
    )
    if ($Depth -gt 25) { throw "PlannerFatal: snippet expansion exceeded depth 25 in $SeqPath (cyclic or pathological nesting)." }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($step in $Steps) {
        if ($step -is [System.Collections.IDictionary] -and $step.Contains('snippet')) {
            $name = [string]$step['snippet']
            if (-not $Map.ContainsKey($name)) {
                $available = (($Map.Keys | Sort-Object) -join ', ')
                if (-not $available) { $available = '(no snippet libraries found)' }
                throw "PlannerFatal: snippet '$name' referenced by $SeqPath was not found. Available snippets: $available."
            }
            if ($Visiting.Contains($name)) {
                throw "PlannerFatal: snippet cycle detected at '$name' (referenced from $SeqPath)."
            }
            [void]$Visiting.Add($name)
            $inner = @(Expand-StepList -Steps $Map[$name].Steps -Map $Map -Visiting $Visiting -SeqPath $SeqPath -Depth ($Depth + 1))
            [void]$Visiting.Remove($name)
            foreach ($e in $inner) { [void]$out.Add($e) }
        }
        elseif ($step -is [System.Collections.IDictionary] -and $step.Contains('steps')) {
            $clone = [ordered]@{}
            foreach ($k in $step.Keys) {
                if ($k -eq 'steps') { $clone['steps'] = @(Expand-StepList -Steps $step['steps'] -Map $Map -Visiting $Visiting -SeqPath $SeqPath -Depth ($Depth + 1)) }
                else                { $clone[$k] = Copy-YamlNode $step[$k] }
            }
            [void]$out.Add($clone)
        }
        else {
            [void]$out.Add((Copy-YamlNode $step))
        }
    }
    # Return a plain array; every caller wraps the call in @() so a single-element
    # result is rebuilt as a 1-element array rather than unrolled to a scalar.
    return $out.ToArray()
}

function Expand-SequenceSnippet {
    <#
    .SYNOPSIS
        Returns the sequence with every {snippet:name} step spliced out to its
        library definition. Snippet-free sequences are returned unchanged (the
        cached object, no clone).
    .DESCRIPTION
        Called by Read-SequenceFile after parse so the expansion is the single
        point every consumer flows through. Never mutates $Sequence: when a
        snippet is present it returns a shallow top-level copy whose `steps` is a
        freshly built, deep-cloned, fully-expanded array. Throws PlannerFatal on
        an unknown snippet name, a duplicate project definition, or a cycle.
    #>
    param(
        [Parameter(Mandatory)]$Sequence,
        [Parameter(Mandatory)][string]$Path
    )
    if ($Sequence -isnot [System.Collections.IDictionary]) { return $Sequence }
    if (-not $Sequence.Contains('steps')) { return $Sequence }
    if (-not (Test-StepHasSnippet $Sequence['steps'])) { return $Sequence }

    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "powershell-yaml is required to expand sequence snippets. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }

    $map      = Get-SnippetMap -SequencePath $Path
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $expanded = @(Expand-StepList -Steps $Sequence['steps'] -Map $map -Visiting $visiting -SeqPath $Path -Depth 0)

    # Shallow-copy the top-level dict (non-steps keys are read-only downstream so
    # sharing them by reference is safe) and swap in the expanded step array, so
    # the mtime-cached raw parse object is never mutated.
    $out = [ordered]@{}
    foreach ($k in $Sequence.Keys) {
        if ($k -eq 'steps') { $out['steps'] = $expanded }
        else                { $out[$k] = $Sequence[$k] }
    }
    return $out
}

function Format-SequenceSearchList {
    <#
    .SYNOPSIS
        Format a list of candidate/found sequence-file paths for a not-found or
        ambiguity diagnostic message.
    .DESCRIPTION
        Indents each entry four spaces and joins them with newlines. One formatter
        so the resolution-miss diagnostics stay uniform across the planner, the
        resolver, and the sequence engine. Exported because the sibling modules
        import Test.SequenceResolve -Global and call it directly.
    .PARAMETER Item
        The list of paths (or string-coercible values) to render, one per line.
    .OUTPUTS
        [string] the indented, newline-joined list (empty string for an empty list).
    #>
    param($Item)
    return ($Item | ForEach-Object { "    $_" }) -join "`n"
}

Export-ModuleMember -Function Read-SequenceFile, ConvertTo-NormalizedSequence, Get-ProjectFlatTestSearchDir, Find-ProjectFlatSequenceFile, Get-FlatSequenceCandidate, Resolve-SequencePath, Get-SequenceSearchPath, Expand-SequenceSnippet, Get-SnippetMap, Format-SequenceSearchList