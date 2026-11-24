<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42eb20ad-6a27-430a-ba01-796c50a077ed
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StepPhrase.psm1') -Global -Force -DisableNameChecking

function New-SequencePlannerException {
    <# .SYNOPSIS
        Create a localized planning failure with an invariant control identity.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Constructs an in-memory exception; no external state changes.')]
    [CmdletBinding()]
    [OutputType([InvalidOperationException])]
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Arguments = @{})
    $message = Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments
    $exception = [InvalidOperationException]::new('PlannerFatal: ' + $message)
    $exception.Data['YurunaFailureCode'] = 'sequence.plan_invalid'
    $exception.Data['YurunaMessageCode'] = $Key
    return $exception
}

function Test-SequencePlannerFailure {
    <# .SYNOPSIS
        Recognize planning failures through PowerShell and invocation wrappers.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$ErrorObject)
    $exception = if ($ErrorObject -is [Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    while ($exception -is [Exception]) {
        if ($exception.Data['YurunaFailureCode'] -ceq 'sequence.plan_invalid') { return $true }
        $exception = $exception.InnerException
    }
    return $false
}


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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_40552def8b1fec50')
    }
    if (-not $Sequence.Contains('resource')) { return $Sequence }   # orchestration / host-action
    if ($Sequence.Contains('steps')) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_ae41cdc2535f423f')
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
        Centralizes the powershell-yaml dependency for every sequence reader
        (Invoke-Sequence, Test.SequencePlanner, Debug-TestSequence). Uses
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
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_4ebab78c20241f2d' -Arguments @{ command = 'Install-Module -Name powershell-yaml -Scope CurrentUser' })
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
        if (-not $NoCache) {
            $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
            $mtime = (Get-Item -LiteralPath $resolved -ErrorAction Stop).LastWriteTimeUtc
        }
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if ($null -eq $parsed) { return $null }
        if (-not $NoCache) {
            $script:SequenceFileCache[$resolved] = @{ Mtime = $mtime; Parsed = $parsed }
        }
        return (Expand-SequenceSnippet -Sequence (ConvertTo-NormalizedSequence $parsed) -Path $Path)
    } catch {
        if (Test-SequencePlannerFailure -ErrorObject $_) { throw }
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
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_fc93013c47f0dff2' -Arguments @{ path = "$Path"; line = "${line}"; col = "${col}"; message = "$($synErr.Message)" })
        }
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_d661d09f953abb27' -Arguments @{ path = "$Path"; message = "$($err.Message)" })
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
    The flat-project lookup Resolve-SequencePath uses: scans every `test/` dir
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
        throw (New-SequencePlannerException -Key 'exceptions.runner_7b768110a092cc93' -Arguments @{ count = "$($hits.Count)"; fileName = "$FileName"; list = "$list" })
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

# --- REGION: Step-snippet library
# See https://yuruna.link/4213a0b3-0166

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

function Get-StepLeadAction {
    <#
    .SYNOPSIS
        The action a step actually leads with, reading through nested step lists.
    .DESCRIPTION
        A wrapper step (`retry`) does not act itself -- it runs an inner `steps`
        list -- so the action that reaches the guest first is that list's first
        step, recursively. Nesting is detected structurally, by the presence of a
        `steps` key, for the same reason snippet expansion walks it that way: a
        literal verb-name list silently drifts as verbs are added.

        Callers reason about what a step will do before running it -- whether the
        VM still needs starting, whether a step is a restore boundary a resume can
        rewind to -- and a wrapper's own name answers neither question. Rewinding
        or dispatching to a wrapper is sound precisely because entering it runs
        that first inner step.
    .OUTPUTS
        [string] the leading action name; the step's own action when it wraps
        nothing (an empty `steps` list is what the retry handler itself fails on,
        so `retry` is the honest answer there); $null past the nesting bound.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Step)
    $current = $Step
    # Bounded rather than "until a leaf": sequences are data, and a nesting depth
    # no author would write is a malformed file, not a run.
    for ($depth = 0; $depth -lt 8; $depth++) {
        # A missing 'steps' key yields @($null) -- one element that is not a step
        # -- so drop nulls before asking whether an inner list exists.
        $inner = @(@($current.steps) | Where-Object { $null -ne $_ })
        if ($inner.Count -lt 1) { return [string]$current.action }
        $current = $inner[0]
    }
    return $null
}

function Test-StepListNeedsExpansion {
    # True when $Steps (or a nested retry.steps / stepsAfterVmRestart list) holds
    # an entry that is not a plain action step: a `{snippet: ...}`, a sentence
    # (`step:`), an entry without `action`, or one that is not a map. Lets
    # Read-SequenceFile skip the clone-and-expand path entirely for a sequence of
    # plain action steps (zero overhead, returns the cached object); the expansion
    # path then reports the malformed entries.
    param($Steps)
    if ($null -eq $Steps) { return $false }
    foreach ($s in $Steps) {
        if ($s -isnot [System.Collections.IDictionary]) { return $true }
        if ($s.Contains('snippet') -or $s.Contains('step') -or -not $s.Contains('action')) { return $true }
        if ($s.Contains('steps') -and (Test-StepListNeedsExpansion $s['steps'])) { return $true }
        if ($s.Contains('stepsAfterVmRestart') -and (Test-StepListNeedsExpansion $s['stepsAfterVmRestart'])) { return $true }
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

function Get-SequenceLibraryPath {
    <#
    .SYNOPSIS
        Lists the library files named $LeafName visible to the sequence at
        $SequencePath: the framework one, then the project ones.
    .DESCRIPTION
        Shared by the snippet and the phrase libraries. Project holds every
        project test/ folder's file and the sequence's own folder's file when
        it is not already listed. FrameworkRootFound is true only when an
        ancestor folder holds test/sequences.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][string]$LeafName
    )
    $modeDir = Split-Path -Parent $SequencePath
    # Walk directory boundaries rather than matching a directory name inside
    # an absolute path: a checkout itself may have an ancestor named project.
    $repoRoot = $null
    $projectRootCandidate = $null
    $candidate = $modeDir
    while ($candidate) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'test/sequences') -PathType Container) {
            $repoRoot = $candidate
            break
        }
        $parent = Split-Path -Parent $candidate
        # Standalone project-only fixtures may omit the framework directory.
        # Keep this as a fallback; a real framework marker above it wins.
        if (-not $projectRootCandidate -and (Split-Path -Leaf $candidate) -eq 'project') { $projectRootCandidate = $parent }
        if ($parent -eq $candidate) { break }
        $candidate = $parent
    }
    $frameworkRootFound = [bool]$repoRoot
    if (-not $repoRoot) { $repoRoot = $projectRootCandidate }

    $frameworkLibs = New-Object System.Collections.Generic.List[string]
    $projectLibs   = New-Object System.Collections.Generic.List[string]
    if ($repoRoot) {
        $fw = Join-Path (Join-Path (Join-Path $repoRoot 'test') 'sequences') $LeafName
        if (Test-Path -LiteralPath $fw) { [void]$frameworkLibs.Add($fw) }
        foreach ($d in (Get-ProjectFlatTestSearchDir -RepoRoot $repoRoot)) {
            $pl = Join-Path $d $LeafName
            if (Test-Path -LiteralPath $pl) { [void]$projectLibs.Add($pl) }
        }
    }
    # Always consider the sequence's own dir (covers standalone temp dirs used by
    # tests and any layout the regexes above didn't recognize). De-dup against
    # the tiers already collected so a framework/project file isn't double-loaded.
    $localLib = Join-Path $modeDir $LeafName
    if (Test-Path -LiteralPath $localLib) {
        $localResolved = (Resolve-Path -LiteralPath $localLib).Path
        $known = @()
        foreach ($f in (@($frameworkLibs) + @($projectLibs))) { $known += (Resolve-Path -LiteralPath $f).Path }
        if ($localResolved -notin $known) { [void]$projectLibs.Add($localLib) }
    }
    return @{ Framework = [string[]]$frameworkLibs.ToArray(); Project = [string[]]$projectLibs.ToArray(); FrameworkRootFound = $frameworkRootFound }
}

function Get-SnippetMap {
    <#
    .SYNOPSIS
        Builds name -> @{Steps; File; Tier} for the snippet libraries visible to
        the sequence at $SequencePath.
    .DESCRIPTION
        Framework libraries load first (base); project libraries then override by
        name. Two PROJECT libraries defining the same name throw PlannerFatal (an
        ambiguous plan), mirroring Find-ProjectFlatSequenceFile's duplicate rule.
    #>
    param([Parameter(Mandatory)][string]$SequencePath)

    $libraries     = Get-SequenceLibraryPath -SequencePath $SequencePath -LeafName '_snippets.yml'
    $frameworkLibs = $libraries.Framework
    $projectLibs   = $libraries.Project

    $map = @{}
    foreach ($f in $frameworkLibs) {
        $doc = Get-SnippetLibraryFile -LibPath $f
        if ($doc -isnot [System.Collections.IDictionary]) { continue }
        foreach ($name in $doc.Keys) {
            $key = [string]$name
            if ($doc[$name] -isnot [System.Collections.IEnumerable] -or $doc[$name] -is [string]) {
                throw (New-SequencePlannerException -Key 'exceptions.runner_fc123b0e72bddd90' -Arguments @{ key = "$key"; f = "$f" })
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
                throw (New-SequencePlannerException -Key 'exceptions.runner_21cd8bca74cb4370' -Arguments @{ key = "$key"; p = "$p" })
            }
            if ($map.ContainsKey($key) -and $map[$key].Tier -eq 'project') {
                throw (New-SequencePlannerException -Key 'exceptions.runner_f68eed0750b170ae' -Arguments @{ key = "$key"; file = "$($map[$key].File)"; p = "$p" })
            }
            $map[$key] = @{ Steps = $doc[$name]; File = $p; Tier = 'project' }
        }
    }
    return $map
}

function Get-SequencePhraseLibrary {
    <#
    .SYNOPSIS
        Loads the phrase libraries visible to a sequence, or the framework one.
    .DESCRIPTION
        The framework library loads first; the project libraries and the one in
        the sequence's own folder follow, sorted together by path in ordinal
        order so the load order is the same on every file system. A sequence
        read from outside a framework checkout uses the library of the
        framework this module belongs to.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$SequencePath)
    $fallback = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../sequences/_phrases.yml'))
    $framework = @()
    $project = @()
    if ($SequencePath) {
        $libraries = Get-SequenceLibraryPath -SequencePath $SequencePath -LeafName '_phrases.yml'
        $framework = @($libraries.Framework)
        $project = @($libraries.Project)
        if (-not $libraries.FrameworkRootFound -and (Test-Path -LiteralPath $fallback -PathType Leaf)) { $framework = @($fallback) }
    } elseif (Test-Path -LiteralPath $fallback -PathType Leaf) {
        $framework = @($fallback)
    }
    $projectSorted = [string[]]$project
    [Array]::Sort($projectSorted, [StringComparer]::Ordinal)
    $source = @(
        foreach ($entry in $framework) { @{ Path = [string]$entry; Tier = 'framework' } }
        foreach ($entry in $projectSorted) { @{ Path = [string]$entry; Tier = 'project' } }
    )
    return (Get-StepPhraseLibrary -Source $source)
}

function Assert-SentenceStepForm {
    <#
    .SYNOPSIS
        Refuses a sentence step whose keys or values the schema would refuse.
    .DESCRIPTION
        Key spellings and the values of `on` are compared case-sensitively, as
        the schema does, although the parsed map's lookup ignores case.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Step,
        [Parameter(Mandatory)][string]$Location
    )
    # Bound to a local the refusal block below reads; the analyzer cannot see a
    # parameter used only inside a script block.
    $stepLocation = $Location
    $invalid = {
        param([string]$Reason, [string]$Detail)
        New-SequencePlannerException -Key 'runner.step_sentence_invalid' -Arguments @{ location = "$stepLocation"; reason = $Reason; detail = "$Detail" }
    }
    $unknown = [string[]]@($Step.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -cnotin 'step', 'on', 'timeoutSeconds', 'description', 'descriptionLocalized' })
    if ($unknown.Count -gt 0) {
        [Array]::Sort($unknown, [StringComparer]::Ordinal)
        throw (& $invalid 'unknown-key' ($unknown -join ', '))
    }
    $sentence = $Step['step']
    if ($sentence -isnot [string] -or [string]::IsNullOrWhiteSpace($sentence)) {
        $detail = if ($sentence -is [string] -or $null -eq $sentence) { 'blank' } else { $sentence.GetType().Name }
        throw (& $invalid 'sentence-not-text' $detail)
    }
    if ($Step.Contains('on') -and ($Step['on'] -isnot [string] -or $Step['on'] -cnotin 'screen', 'page')) {
        throw (& $invalid 'surface' ([string]$Step['on']))
    }
    if ($Step.Contains('timeoutSeconds') -and ($Step['timeoutSeconds'] -isnot [int] -or $Step['timeoutSeconds'] -lt 1)) {
        throw (& $invalid 'timeout' ([string]$Step['timeoutSeconds']))
    }
    if ($Step.Contains('description') -and $Step['description'] -isnot [string]) {
        $detail = if ($null -eq $Step['description']) { 'null' } else { $Step['description'].GetType().Name }
        throw (& $invalid 'description' $detail)
    }
    if ($Step.Contains('descriptionLocalized')) {
        $localized = $Step['descriptionLocalized']
        if ($localized -isnot [System.Collections.IDictionary]) { throw (& $invalid 'description-localized' 'not-a-map') }
        foreach ($locale in $localized.Keys) {
            if ($localized[$locale] -isnot [string]) { throw (& $invalid 'description-localized' ([string]$locale)) }
        }
        if (-not $Step.Contains('description') -or [string]::IsNullOrWhiteSpace([string]$Step['description'])) {
            throw (& $invalid 'description-localized' 'without-description')
        }
    }
}

function Expand-StepList {
    # Returns a NEW step array with every {snippet:name} replaced by that
    # snippet's (recursively expanded, deep-cloned) steps and every sentence
    # (`step:`) replaced by the action steps of its phrase. $Visiting guards
    # against snippet->snippet cycles; $Depth is a backstop ceiling. retry.steps
    # and stepsAfterVmRestart are walked so snippets and sentences work at any
    # depth. $Trail names the list in errors (`component`, `workload[3].steps`);
    # $Phrase (@{ DefaultSurface; Library; Allowed }) is one table shared by every
    # recursion, so a snippet's sentence takes the surface default and the
    # libraries of the sequence that uses it, and the libraries load once per read.
    # NOTE: $Steps / $Map / $Visiting are intentionally NOT [Parameter(Mandatory)]:
    # an empty collection (e.g. a fresh HashSet, or an empty step list) fails
    # mandatory binding with "Cannot bind argument ... empty collection".
    param(
        $Steps,
        [hashtable]$Map,
        [System.Collections.Generic.HashSet[string]]$Visiting,
        [Parameter(Mandatory)][string]$SeqPath,
        [int]$Depth = 0,
        [string]$Trail = 'steps',
        [hashtable]$Phrase
    )
    if ($Depth -gt 25) { throw (New-SequencePlannerException -Key 'exceptions.runner_d6c2daddc3ec9502' -Arguments @{ seqPath = "$SeqPath" }) }
    $out = New-Object System.Collections.Generic.List[object]
    $position = 0
    foreach ($step in $Steps) {
        $position++
        $location = "${SeqPath}: $Trail[$position]"
        $isMap = $step -is [System.Collections.IDictionary]
        $kinds = @(if ($isMap) { foreach ($kind in 'step', 'action', 'snippet') { if ($step.Contains($kind)) { $kind } } })
        if (-not $isMap -or $kinds.Count -ne 1) {
            $found = if (-not $isMap) { 'not a map' } elseif ($kinds.Count -eq 0) { 'none' } else { $kinds -join ', ' }
            throw (New-SequencePlannerException -Key 'runner.step_form_invalid' -Arguments @{ location = "$location"; found = "$found" })
        }
        if ($kinds[0] -ceq 'snippet') {
            $name = [string]$step['snippet']
            if (-not $Map.ContainsKey($name)) {
                $available = (($Map.Keys | Sort-Object) -join ', ')
                if (-not $available) { $available = '(no snippet libraries found)' }
                throw (New-SequencePlannerException -Key 'exceptions.runner_a01e6215c9b21e74' -Arguments @{ name = "$name"; seqPath = "$SeqPath"; available = "$available" })
            }
            if ($Visiting.Contains($name)) {
                throw (New-SequencePlannerException -Key 'exceptions.runner_870490a8a4454890' -Arguments @{ name = "$name"; seqPath = "$SeqPath" })
            }
            [void]$Visiting.Add($name)
            $inner = @(Expand-StepList -Steps $Map[$name].Steps -Map $Map -Visiting $Visiting -SeqPath $SeqPath -Depth ($Depth + 1) -Trail "$Trail[$position].snippet($name)" -Phrase $Phrase)
            [void]$Visiting.Remove($name)
            foreach ($e in $inner) { [void]$out.Add($e) }
        }
        elseif ($kinds[0] -ceq 'step') {
            if (-not $Phrase.Allowed) {
                throw (New-SequencePlannerException -Key 'runner.step_sentence_invalid' -Arguments @{ location = "$location"; reason = 'not-guest-sequence'; detail = 'resource' })
            }
            Assert-SentenceStepForm -Step $step -Location $location
            if ($null -eq $Phrase.Library) { $Phrase.Library = Get-SequencePhraseLibrary -SequencePath $SeqPath }
            $resolveArgument = @{
                Sentence       = [string]$step['step']
                Surface        = $(if ($step.Contains('on')) { [string]$step['on'] } else { [string]$Phrase.DefaultSurface })
                Library        = $Phrase.Library
                TimeoutSeconds = $(if ($step.Contains('timeoutSeconds')) { [int]$step['timeoutSeconds'] } else { 0 })
                Description    = $(if ($step.Contains('description')) { [string]$step['description'] } else { '' })
                Location       = $location
            }
            if ($step.Contains('descriptionLocalized')) { $resolveArgument.DescriptionLocalized = $step['descriptionLocalized'] }
            foreach ($generated in @(Resolve-StepPhrase @resolveArgument)) { [void]$out.Add($generated) }
        }
        elseif ($step.Contains('steps') -or $step.Contains('stepsAfterVmRestart')) {
            $clone = [ordered]@{}
            foreach ($k in $step.Keys) {
                if ($k -eq 'steps') { $clone['steps'] = @(Expand-StepList -Steps $step['steps'] -Map $Map -Visiting $Visiting -SeqPath $SeqPath -Depth ($Depth + 1) -Trail "$Trail[$position].steps" -Phrase $Phrase) }
                elseif ($k -eq 'stepsAfterVmRestart') { $clone['stepsAfterVmRestart'] = @(Expand-StepList -Steps $step['stepsAfterVmRestart'] -Map $Map -Visiting $Visiting -SeqPath $SeqPath -Depth ($Depth + 1) -Trail "$Trail[$position].stepsAfterVmRestart" -Phrase $Phrase) }
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
        library definition and every sentence (`step:`) replaced by the action
        steps of its phrase. A sequence of plain action steps is returned
        unchanged (the cached object, no clone).
    .DESCRIPTION
        Called by Read-SequenceFile after parse so the expansion is the single
        point every consumer flows through. Never mutates $Sequence: when a
        snippet or a sentence is present it returns a shallow top-level copy
        whose `steps` is a freshly built, deep-cloned, fully-expanded array.
        Throws PlannerFatal on an unknown snippet name, a duplicate project
        definition, a cycle, a step that is not exactly one of action, snippet
        and sentence, or a sentence that does not resolve. Sentences belong to
        guest sequences (a document with `resource`) only; `defaultSurface` is
        read there and nowhere else.
    #>
    param(
        [Parameter(Mandatory)]$Sequence,
        [Parameter(Mandatory)][string]$Path
    )
    if ($Sequence -isnot [System.Collections.IDictionary]) { return $Sequence }
    $isGuest = $Sequence.Contains('resource')
    if ($isGuest -and $Sequence.Contains('defaultSurface')) {
        $surface = $Sequence['defaultSurface']
        if ($surface -isnot [string] -or $surface -cnotin 'screen', 'page') {
            throw (New-SequencePlannerException -Key 'runner.step_sentence_invalid' -Arguments @{ location = "${Path}: defaultSurface"; reason = 'default-surface'; detail = "$([string]$surface)" })
        }
    }
    if (-not $Sequence.Contains('steps')) { return $Sequence }
    if (-not (Test-StepListNeedsExpansion $Sequence['steps'])) { return $Sequence }

    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_c959d88998b87c80' -Arguments @{ command = 'Install-Module -Name powershell-yaml -Scope CurrentUser' })
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }

    $phrase = @{
        DefaultSurface = $(if ($isGuest -and $Sequence.Contains('defaultSurface')) { [string]$Sequence['defaultSurface'] } else { 'screen' })
        Library        = $null
        Allowed        = $isGuest
    }
    $map      = Get-SnippetMap -SequencePath $Path
    $visiting = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($isGuest) {
        # Expanded per list so an error names `component[2]` rather than a
        # position in the merged list.
        $component = @(if ($Sequence.Contains('component') -and $Sequence['component']) { $Sequence['component'] })
        $workload  = @(if ($Sequence.Contains('workload') -and $Sequence['workload']) { $Sequence['workload'] })
        $expanded = @(Expand-StepList -Steps $component -Map $map -Visiting $visiting -SeqPath $Path -Depth 0 -Trail 'component' -Phrase $phrase) +
            @(Expand-StepList -Steps $workload -Map $map -Visiting $visiting -SeqPath $Path -Depth 0 -Trail 'workload' -Phrase $phrase)
    } else {
        $expanded = @(Expand-StepList -Steps $Sequence['steps'] -Map $map -Visiting $visiting -SeqPath $Path -Depth 0 -Trail 'steps' -Phrase $phrase)
    }

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

Export-ModuleMember -Function New-SequencePlannerException, Test-SequencePlannerFailure, Read-SequenceFile, ConvertTo-NormalizedSequence, Get-StepLeadAction, Get-ProjectFlatTestSearchDir, Find-ProjectFlatSequenceFile, Get-FlatSequenceCandidate, Resolve-SequencePath, Get-SequenceSearchPath, Expand-SequenceSnippet, Get-SnippetMap, Format-SequenceSearchList, Get-SequencePhraseLibrary
