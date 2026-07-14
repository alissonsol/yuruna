<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345677a
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

<#
.SYNOPSIS
    Builds the per-cycle execution plan from project/test/test.runner.yml
    and the per-sequence baseline fields.

.DESCRIPTION
    The runner config (project/test/test.runner.yml) lists top-level
    sequence names. Each sequence has a baseline field keyed by guest OS,
    pointing at one or more prerequisite sequences. Walking the prereq
    graph depth-first produces an ordered chain ending in the top-level
    sequence; partitioning by name prefix yields the start (Start-GuestOS)
    and workload (Start-GuestWorkload) lists per (top-level, guest) pair.

    A guest can appear in multiple chains (one per top-level it serves).
    The runner currently merges all sequences for the same guest into a
    single VM lifecycle to preserve the existing one-init-per-cycle
    contract; future revisions can switch to per-chain initialization
    when that becomes useful.
#>

# Pull in Resolve-SequencePath and Read-SequenceFile from the engine module
# so prereqs resolve the same way Invoke-Sequence does.
#
# -Global is required: -Force without -Global yanks the engine module out of
# the global session (see the module-force-evict trap in repo memory). The
# runner imports Invoke-Sequence at startup; if any later -Force import here
# evicts it, every caller that built a function reference to e.g.
# Invoke-SequenceByName / Read-SequenceFile loses visibility.
$script:EngineModule = Join-Path $PSScriptRoot "Invoke-Sequence.psm1"
if (Test-Path $script:EngineModule) {
    Import-Module $script:EngineModule -Force -Global -Verbose:$false -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Returns the path to project/test/test.runner.yml under the cloned project root.
#>
function Get-CycleConfigPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot "project/test/test.runner.yml")
}

<#
.SYNOPSIS
    Reads project/test/test.runner.yml and returns the parsed object.
.DESCRIPTION
    Throws when the file is missing or has no `sequences` array, since the
    cycle has no work to do without one. Callers can wrap in try/catch
    and degrade to legacy guestSequence if they want fallback behavior.

    Uses Read-SequenceFile (exported by Invoke-Sequence.psm1) as the
    centralised powershell-yaml loader -- it parses any YAML file, not
    just sequence files, and keeps the dependency check in one place.
#>
function Get-CycleConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-CycleConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path $path)) {
        throw "Runner config not found: $path (set test.config.yml's repositories.projectUrl, or place the file under <repo>/project/test/)"
    }
    $cfg = Read-SequenceFile -Path $path
    if (-not $cfg.sequences -or $cfg.sequences.Count -eq 0) {
        throw "Runner config has no 'sequences' entries: $path"
    }
    return $cfg
}

# Internal helper: depth-first walk of a sequence's prereq chain for a
# specific guest OS. Adds each visited sequence to $Chain in dependency
# order (deepest prereqs first) and uses $Visited to skip duplicates.
function Add-CyclePrereqChainEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SequenceName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType,
        [Parameter(Mandatory)][string]$OsKey,
        [Parameter(Mandatory)]$Chain,
        [Parameter(Mandatory)]$Visited
    )
    if ($Visited.Contains($SequenceName)) { return }
    $path = Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
    if (-not $path) {
        # PlannerFatal so the runner's Resolve-CyclePlan catch hits the
        # banner branch instead of degrading to legacy guestSequence on a
        # silent typo. List the actual searched locations so the operator
        # sees every probed path -- a single "resolved path: <X>" naming
        # the last-attempted file would be misleading.
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
        $list = Format-SequenceSearchList -Item $searched
        throw "PlannerFatal: prereq sequence not found: $SequenceName (referenced by an entry in project/test/test.runner.yml)`nSearched (no match):`n$list"
    }
    $seq = Read-SequenceFile -Path $path
    if ($seq.baseline -and $seq.baseline.Contains($OsKey)) {
        foreach ($prereq in $seq.baseline[$OsKey]) {
            Add-CyclePrereqChainEntry -SequenceName $prereq -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $OsKey -Chain $Chain -Visited $Visited
        }
    }
    [void]$Visited.Add($SequenceName)
    [void]$Chain.Add($SequenceName)
}

<#
.SYNOPSIS
Merges one chain member's variables into the running cascade map in place, applying the top-of-chain-wins rules: skip a key already set (a higher level won), skip a $null value, and skip a whitespace-only string. Mutates $Target (an [ordered]@{}) by reference. $Target is NOT [Mandatory] because it is legitimately empty on the first chain member, and [Mandatory] rejects an empty collection.
#>
function Merge-SequenceVariableCascade {
    [CmdletBinding()]
    param(
        [Parameter()][System.Collections.Specialized.OrderedDictionary]$Target,
        [Parameter()]$Variables
    )
    if (-not $Variables) { return }
    foreach ($vk in $Variables.Keys) {
        if ($Target.Contains($vk)) { continue }   # higher level already won
        $vv = $Variables[$vk]
        if ($null -eq $vv) { continue }
        if ($vv -is [string] -and -not $vv.Trim()) { continue }
        $Target[$vk] = $vv
    }
}

# Shared per-top-level entry builder for Resolve-CyclePlan (legacy) AND
# Resolve-TestSetCyclePlan (pool). Resolves one top-level sequence into
# one (topLevel, guestKey, chain, cascade) entry per supported guest OS and
# appends them to $Entries. The two callers differ only in the SOURCE of the
# top-level list and in the optional pool args:
#   -PerGuestOverrides: per-guestKey {keystrokeMechanism, username, variables}
#       layered ON TOP of the chain cascade (override wins); keystrokeMechanism is
#       tagged on the entry for the runner to thread per guest.
#   -RestrictGuests: when set, only guestKeys in this list are emitted (the
#       pool-planner host filter -- a host skips guests it cannot run).
# A missing top-level throws PlannerFatal (a typo must abort, not silently skip);
# an unresolvable prereq is warned + skipped. Keeping ONE code path means the
# variable cascade, PlannerFatal propagation, and entry shape never drift between
# the single-host and pool planners.
function Add-CyclePlanEntriesForTopLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[Object]]$Entries,
        [Parameter(Mandatory)][string]$TopName,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType,
        [string]$SourceLabel = '',
        [AllowNull()]$PerGuestOverrides,
        [AllowNull()][string[]]$RestrictGuests
    )
    $topPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $TopName -HostType $HostType -RepoRoot $RepoRoot
    if (-not $topPath) {
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $TopName -HostType $HostType -RepoRoot $RepoRoot
        $list = Format-SequenceSearchList -Item $searched
        throw "PlannerFatal: missing sequence '$TopName'$(if ($SourceLabel) { " $SourceLabel" })`nSearched (no match):`n$list"
    }
    $topSeq = Read-SequenceFile -Path $topPath
    if (-not $topSeq.baseline) {
        Write-Warning "Top-level sequence has no baseline (no supported guest OS declared): $TopName"
        return
    }
    foreach ($osKey in $topSeq.baseline.Keys) {
        $guestKey = "guest.$osKey"
        # Pool-planner host filter: a host emits only the guests it can run.
        if ($null -ne $RestrictGuests -and ($RestrictGuests -notcontains $guestKey)) { continue }
        $chain   = New-Object System.Collections.Generic.List[string]
        $visited = [System.Collections.Generic.HashSet[string]]::new()
        try {
            Add-CyclePrereqChainEntry -SequenceName $TopName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $osKey -Chain $chain -Visited $visited
        } catch {
            # PlannerFatal (duplicate project sequence file) MUST propagate.
            if ($_.Exception.Message -like 'PlannerFatal:*') { throw }
            Write-Warning "Skipping $TopName / $osKey - $($_.Exception.Message)"
            continue
        }
        $startSeqs = New-Object System.Collections.Generic.List[string]
        $workSeqs  = New-Object System.Collections.Generic.List[string]
        foreach ($s in $chain) {
            if ($s -match '^start\.') { [void]$startSeqs.Add($s) } else { [void]$workSeqs.Add($s) }
        }
        # Cascade variables top-down across the chain (first non-empty from the top wins).
        $effectiveVars = [ordered]@{}
        for ($i = $chain.Count - 1; $i -ge 0; $i--) {
            $sName = $chain[$i]
            $sPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $sName -HostType $HostType -RepoRoot $RepoRoot
            if (-not $sPath) {
                # This member IS in the chain, so it resolved earlier; not resolving now (e.g. a
                # mid-cycle rename) is an inconsistency. Surface it -- silently dropping its
                # variables lets the chain run with missing vars instead of failing visibly.
                Write-Warning "Cascade: chain member '$sName' no longer resolves to a path; its variables are dropped from the cascade."
                continue
            }
            try { $sSeq = Read-SequenceFile -Path $sPath } catch {
                Write-Warning "Cascade: chain member '$sName' ($sPath) failed to re-read ($($_.Exception.Message)); its variables are dropped from the cascade."
                continue
            }
            Merge-SequenceVariableCascade -Target $effectiveVars -Variables $sSeq.variables
        }
        # Per-guest overrides layer ON TOP of the cascade (override wins).
        # keystrokeMechanism is tagged on the entry (not a variable) so the runner
        # can switch the dispatch mode for this guest's VM lifecycle.
        $guestKsm = $null
        if ($PerGuestOverrides -is [System.Collections.IDictionary] -and $PerGuestOverrides.Contains($guestKey)) {
            $ov = $PerGuestOverrides[$guestKey]
            if ($ov -is [System.Collections.IDictionary]) {
                if ($ov.Contains('variables') -and $ov['variables'] -is [System.Collections.IDictionary]) {
                    foreach ($vk in $ov['variables'].Keys) { $effectiveVars[$vk] = $ov['variables'][$vk] }
                }
                if ($ov.Contains('username') -and -not [string]::IsNullOrWhiteSpace([string]$ov['username'])) {
                    $effectiveVars['username'] = [string]$ov['username']
                }
                if ($ov.Contains('keystrokeMechanism') -and -not [string]::IsNullOrWhiteSpace([string]$ov['keystrokeMechanism'])) {
                    $guestKsm = ([string]$ov['keystrokeMechanism']).ToUpperInvariant()
                }
            }
        }
        $effectiveUsername = if ($effectiveVars.Contains('username')) { [string]$effectiveVars['username'] } else { '' }
        $Entries.Add([pscustomobject]@{
            topLevel            = $TopName
            guestKey            = $guestKey
            fullChain           = @($chain.ToArray())
            startSequences      = @($startSeqs.ToArray())
            workloadSequences   = @($workSeqs.ToArray())
            effectiveVariables  = $effectiveVars
            effectiveUsername   = $effectiveUsername
            keystrokeMechanism  = $guestKsm
        })
    }
}

<#
.SYNOPSIS
    Resolves the cycle baseline into ordered (topLevel, guestKey, fullChain) entries.
.DESCRIPTION
    For each top-level sequence in the project/test/test.runner.yml sequences
    list, iterates the supported guest OSes (keys of the sequence's own baseline
    field) and produces one entry per (top-level, OS) pair. Each entry
    carries:
      - topLevel:          the top-level sequence name from the cycle config
      - guestKey:          "guest.<os>"
      - fullChain:         dependency-ordered sequence names (start* first, top-level last)
      - startSequences:    chain entries matching ^start\. (run during Start-GuestOS)
      - workloadSequences: every other chain entry (run during Start-GuestWorkload)

    A missing top-level or unresolvable prereq is logged and skipped -- the
    rest of the plan still runs. The runner is responsible for handling
    cases where the same guest appears in multiple entries (currently it
    merges them for a single VM lifecycle).
#>
function Resolve-CyclePlan {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType
    )
    $cycleCfg = Get-CycleConfig -RepoRoot $RepoRoot
    $entries = New-Object System.Collections.Generic.List[Object]
    $srcLabel = "(referenced in the runner sequences list at $(Get-CycleConfigPath -RepoRoot $RepoRoot))"
    foreach ($raw in $cycleCfg.sequences) {
        # Accept entries written with or without an extension. Older project
        # configs sometimes spell sequences as `<name>.json`; the migration
        # to `.yml` shouldn't break those clones.
        $topName = ([string]$raw) -replace '\.(ya?ml|json)$',''
        Add-CyclePlanEntriesForTopLevel -Entries $entries -TopName $topName -RepoRoot $RepoRoot `
            -SequencesDir $SequencesDir -HostType $HostType -SourceLabel $srcLabel
    }
    # Wrap in @() at return so a single entry doesn't unwrap to scalar.
    return ,@($entries.ToArray())
}

<#
.SYNOPSIS
    Phase 4: resolve a POOL test-set manifest's sequences[] into the same cycle-plan
    entry shape Resolve-CyclePlan produces, applying per-guest overrides + the
    pool-planner host filter.
.DESCRIPTION
    The pool counterpart of Resolve-CyclePlan: instead of the single
    test.runner.yml sequences list, it iterates a test-set manifest's
    `sequences[]`. Each entry carries the same fields (plus `keystrokeMechanism`
    from perGuestOverrides). -PerGuestOverrides layers {keystrokeMechanism,
    username, variables} on top of the chain cascade (override wins).
    -RestrictGuests limits emitted guests to those the host can run (the
    pool-planner filter, computed by the caller). Reuses every Resolve-CyclePlan
    building block via Add-CyclePlanEntriesForTopLevel, so the variable cascade,
    PlannerFatal propagation, and entry shape never drift from the single-host path.
#>
function Resolve-TestSetCyclePlan {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Sequences,
        [string]$SetName = '',
        [AllowNull()]$PerGuestOverrides,
        [AllowNull()][string[]]$RestrictGuests
    )
    $entries = New-Object System.Collections.Generic.List[Object]
    $srcLabel = "(referenced in test-set '$SetName')"
    foreach ($raw in $Sequences) {
        $topName = ([string]$raw) -replace '\.(ya?ml|json)$',''
        Add-CyclePlanEntriesForTopLevel -Entries $entries -TopName $topName -RepoRoot $RepoRoot `
            -SequencesDir $SequencesDir -HostType $HostType -SourceLabel $srcLabel `
            -PerGuestOverrides $PerGuestOverrides -RestrictGuests $RestrictGuests
    }
    return ,@($entries.ToArray())
}

<#
.SYNOPSIS
    Returns the deduplicated guest list from a cycle plan, in first-appearance order.
.DESCRIPTION
    The runner uses this for pre-flight folder checks, image refresh, and
    VM-name allocation -- places that operate per unique guest rather than
    per plan entry. The relative order matches the order entries appear in
    the plan, which is itself the order top-level sequences appear in
    the project/test/test.runner.yml sequences list.
#>
function Get-CyclePlanGuestList {
    param([Parameter(Mandatory)]$Plan)
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($e in $Plan) {
        if ($seen.Add($e.guestKey)) { [void]$list.Add($e.guestKey) }
    }
    return ,@($list.ToArray())
}

<#
.SYNOPSIS
    Returns the cycle plan's top-level sequences with their guest(s), in runner-list order.
.DESCRIPTION
    The dashboard renders one card per top-level sequence (the entries listed
    in project/test/test.runner.yml), nesting the guest(s) each sequence
    drives. This produces that ordered mapping from the resolved plan: one
    entry per distinct topLevel in first-appearance order (= the order the
    sequences appear in test.runner.yml, since Resolve-CyclePlan iterates that
    list), each carrying the guestKeys it expands to (also first-appearance
    order). The same guest can appear under more than one sequence when
    multiple top-levels depend on it.

    Each emitted entry is an ordered hashtable @{ name = <topLevel>;
    guests = @(<guestKey>...) } so it serializes straight into status.json's
    `sequences` array. The Dictionary uses an ordinal comparer so two
    sequence names differing only by case stay distinct (mirrors the
    case-sensitive HashSet dedup in Get-CyclePlanGuestList).
#>
function Get-CyclePlanSequenceList {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([Parameter(Mandatory)]$Plan)
    $order  = New-Object System.Collections.Generic.List[string]
    $guests = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::Ordinal)
    foreach ($e in $Plan) {
        $name = [string]$e.topLevel
        $gk   = [string]$e.guestKey
        if (-not $guests.ContainsKey($name)) {
            $guests[$name] = New-Object System.Collections.Generic.List[string]
            [void]$order.Add($name)
        }
        if (-not $guests[$name].Contains($gk)) { [void]$guests[$name].Add($gk) }
    }
    $list = New-Object System.Collections.Generic.List[Object]
    foreach ($name in $order) {
        $list.Add([ordered]@{ name = $name; guests = @($guests[$name].ToArray()) })
    }
    # Wrap in @() at return so a single entry doesn't unwrap to scalar.
    return ,@($list.ToArray())
}

<#
.SYNOPSIS
    Returns the merged sequence chain for a single guest across all plan entries.
.DESCRIPTION
    When the same guest appears in multiple plan entries (because two
    top-level workloads both depend on it), the runner currently runs a
    single VM lifecycle and concatenates the chains in plan order, with
    duplicate sequence names suppressed. Returns a hashtable with
    startSequences and workloadSequences arrays for the runner to feed
    into Start-GuestOS and Start-GuestWorkload.
#>
function Get-CyclePlanSequencesForGuest {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$GuestKey
    )
    $seen   = [System.Collections.Generic.HashSet[string]]::new()
    $start  = New-Object System.Collections.Generic.List[string]
    $work   = New-Object System.Collections.Generic.List[string]
    # Merge cascaded variables across all plan entries hitting this guest.
    # When two top-levels both depend on the same guest, the FIRST entry's
    # effectiveVariables win for keys they share (plan order = order top-
    # levels appear in project/test/test.runner.yml). Other entries fill
    # in keys the first one didn't declare. The 'username' shortcut is
    # surfaced separately because every guest needs one for New-VM.
    $mergedVars     = [ordered]@{}
    $mergedUsername = ''
    # Per-guest keystrokeMechanism (set only on pool/test-set plans). First
    # non-null across this guest's entries wins -- same first-appearance rule as
    # effectiveUsername. $null on the legacy single-host path (the field is absent
    # or null there), so the runner inherits the global default.
    $mergedKsm      = $null
    foreach ($e in $Plan) {
        if ($e.guestKey -ne $GuestKey) { continue }
        foreach ($s in $e.fullChain) {
            if (-not $seen.Add($s)) { continue }
            if ($s -match '^start\.') { [void]$start.Add($s) } else { [void]$work.Add($s) }
        }
        if ($e.effectiveVariables) {
            foreach ($vk in $e.effectiveVariables.Keys) {
                if (-not $mergedVars.Contains($vk)) {
                    $mergedVars[$vk] = $e.effectiveVariables[$vk]
                }
            }
        }
        if (-not $mergedUsername -and $e.effectiveUsername) { $mergedUsername = $e.effectiveUsername }
        if (-not $mergedKsm -and ($e.PSObject.Properties.Name -contains 'keystrokeMechanism') -and $e.keystrokeMechanism) { $mergedKsm = $e.keystrokeMechanism }
    }
    return @{
        startSequences      = @($start.ToArray())
        workloadSequences   = @($work.ToArray())
        effectiveVariables  = $mergedVars
        effectiveUsername   = $mergedUsername
        keystrokeMechanism  = $mergedKsm
    }
}

<#
.SYNOPSIS
    Walks the baseline chain of a single named sequence (Test-Sequence helper).
.DESCRIPTION
    Resolve-CyclePlan keys off project/test/test.runner.yml, which the
    runner consumes but Test-Sequence does not. This sibling takes a top-
    level sequence NAME directly (the same name a Test-Sequence operator
    types) and produces the same per-entry shape Resolve-CyclePlan would
    have emitted for that sequence:
      topLevel / guestKey / fullChain / startSequences / workloadSequences
      / effectiveVariables / effectiveUsername / chainPaths

    When the named sequence has no `baseline:` block (rare -- the framework
    convention is that every workload declares the prereq it needs), the
    chain degenerates to the sequence itself.

    -OsKey is optional; absent, the first key of the sequence's own
    `baseline:` map is used. Pass it explicitly when a sequence supports
    more than one OS and the caller wants a specific one (Test-Sequence
    derives it from the resolved GuestKey, stripping the "guest." prefix).

    -TopLevelPath is the path-override escape hatch for Test-Sequence dev
    setups where the project repo is NOT cloned under <RepoRoot>/project/
    (e.g. yuruna-project as a sibling working tree). When provided, the
    walker uses that path verbatim for the top-level sequence -- but still
    walks its `baseline:` chain via Resolve-SequencePath, so prereqs that
    live in the framework tree (test/sequences/) resolve normally.
    Prereqs outside both standard search paths still fail with the usual
    PlannerFatal error.
#>
function Resolve-NamedSequenceChain {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType,
        [Parameter(Mandatory)][string]$SequenceName,
        [string]$OsKey,
        [string]$TopLevelPath
    )
    # Top-level: prefer the explicit override (Test-Sequence path-form),
    # fall back to Resolve-SequencePath for the name form.
    $topPath = if ($TopLevelPath) { $TopLevelPath } else {
        Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
    }
    if (-not $topPath -or -not (Test-Path -LiteralPath $topPath)) {
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
        $list = Format-SequenceSearchList -Item $searched
        throw "Sequence file not found: $SequenceName`nSearched (no match):`n$list"
    }
    $topSeq = Read-SequenceFile -Path $topPath

    # Resolve the OS key once. Sequences without a baseline are run
    # standalone (no prereq chain); the operator sees just the named
    # sequence in the printed plan, matching the pre-cascade behavior.
    if (-not $OsKey) {
        if ($topSeq.baseline -and $topSeq.baseline.Keys.Count -gt 0) {
            $OsKey = @($topSeq.baseline.Keys)[0]
        }
    }

    $guestKey = if ($OsKey) { "guest.$OsKey" } else { '' }

    # No-baseline degenerate chain: just the top-level. chainPaths is
    # still populated so callers can use one lookup path.
    if (-not $OsKey) {
        $vars = if ($topSeq.variables) { $topSeq.variables } else { [ordered]@{} }
        $uname = if ($vars -is [System.Collections.IDictionary] -and $vars.Contains('username')) { [string]$vars['username'] } else { '' }
        $paths = [ordered]@{ $SequenceName = $topPath }
        return [pscustomobject]@{
            topLevel            = $SequenceName
            guestKey            = ''
            fullChain           = @($SequenceName)
            startSequences      = @()
            workloadSequences   = @($SequenceName)
            effectiveVariables  = $vars
            effectiveUsername   = $uname
            chainPaths          = $paths
        }
    }

    # Walk the top-level's prereqs depth-first; append the top-level
    # ourselves at the end. This avoids handing the entry-point name to
    # Add-CyclePrereqChainEntry, whose first call is `Resolve-SequencePath`
    # -- which would override $TopLevelPath if the named sequence happens
    # to be resolvable by some other lookup tier (and would fail outright
    # when the project tree is not under <RepoRoot>/project/).
    $chain   = New-Object System.Collections.Generic.List[string]
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    if ($topSeq.baseline -and $topSeq.baseline.Contains($OsKey)) {
        foreach ($prereq in $topSeq.baseline[$OsKey]) {
            Add-CyclePrereqChainEntry -SequenceName $prereq -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $OsKey -Chain $chain -Visited $visited
        }
    }
    [void]$visited.Add($SequenceName)
    [void]$chain.Add($SequenceName)

    # Build name -> path map. Top-level uses the resolved/overridden
    # $topPath; every other entry uses Resolve-SequencePath (which the
    # recursive walker already validated, so misses here are unexpected
    # but recorded as $null for defensive checks downstream).
    $paths = [ordered]@{}
    foreach ($s in $chain) {
        if ($s -eq $SequenceName) {
            $paths[$s] = $topPath
        } else {
            $paths[$s] = Resolve-SequencePath -SequencesDir $SequencesDir -Name $s -HostType $HostType -RepoRoot $RepoRoot
        }
    }

    $startSeqs = New-Object System.Collections.Generic.List[string]
    $workSeqs  = New-Object System.Collections.Generic.List[string]
    foreach ($s in $chain) {
        if ($s -match '^start\.') { [void]$startSeqs.Add($s) } else { [void]$workSeqs.Add($s) }
    }

    # Cascade variables top-down: chain is dependency-ordered (deepest
    # prereqs first, top-level last), so walking high index -> low index
    # = top-of-chain -> baseline. First non-empty value wins per key.
    # Use $paths (not Resolve-SequencePath) so the top-level entry reads
    # from $TopLevelPath when supplied.
    $effectiveVars = [ordered]@{}
    for ($i = $chain.Count - 1; $i -ge 0; $i--) {
        $sName = $chain[$i]
        $sPath = $paths[$sName]
        if (-not $sPath) { continue }
        try { $sSeq = Read-SequenceFile -Path $sPath } catch { continue }
        Merge-SequenceVariableCascade -Target $effectiveVars -Variables $sSeq.variables
    }
    $effectiveUsername = if ($effectiveVars.Contains('username')) { [string]$effectiveVars['username'] } else { '' }

    return [pscustomobject]@{
        topLevel            = $SequenceName
        guestKey            = $guestKey
        fullChain           = @($chain.ToArray())
        startSequences      = @($startSeqs.ToArray())
        workloadSequences   = @($workSeqs.ToArray())
        effectiveVariables  = $effectiveVars
        effectiveUsername   = $effectiveUsername
        chainPaths          = $paths
    }
}

Export-ModuleMember -Function Get-CycleConfigPath, Get-CycleConfig, Resolve-CyclePlan, Resolve-TestSetCyclePlan, Get-CyclePlanGuestList, Get-CyclePlanSequenceList, Get-CyclePlanSequencesForGuest, Resolve-NamedSequenceChain
