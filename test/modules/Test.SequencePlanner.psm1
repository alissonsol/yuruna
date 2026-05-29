<#PSScriptInfo
.VERSION 2026.05.29
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
    Builds the per-cycle execution plan from project/test/test.sequence.yml
    and the per-sequence baseline fields.

.DESCRIPTION
    The cycle config (project/test/test.sequence.yml) lists top-level
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
    Returns the path to project/test/test.sequence.yml under the cloned project root.
#>
function Get-CycleConfigPath {
    param([Parameter(Mandatory)][string]$RepoRoot)
    return (Join-Path $RepoRoot "project/test/test.sequence.yml")
}

<#
.SYNOPSIS
    Reads project/test/test.sequence.yml and returns the parsed object.
.DESCRIPTION
    Throws when the file is missing or has no `baseline` array, since the
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
        throw "Cycle config not found: $path (set test.config.yml's repositories.projectUrl, or place the file under <repo>/project/test/)"
    }
    $cfg = Read-SequenceFile -Path $path
    if (-not $cfg.baseline -or $cfg.baseline.Count -eq 0) {
        throw "Cycle config has no 'baseline' entries: $path"
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
        $list = ($searched | ForEach-Object { "    $_" }) -join "`n"
        throw "PlannerFatal: prereq sequence not found: $SequenceName (referenced by an entry in project/test/test.sequence.yml)`nSearched (no match):`n$list"
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
    Resolves the cycle baseline into ordered (topLevel, guestKey, fullChain) entries.
.DESCRIPTION
    For each top-level sequence in project/test/test.sequence.yml baseline,
    iterates the supported guest OSes (keys of the sequence's own baseline
    field) and produces one entry per (top-level, OS) pair. Each entry
    carries:
      - topLevel:          the top-level sequence name from the cycle config
      - guestKey:          "guest.<os>"
      - fullChain:         dependency-ordered sequence names (start* first, top-level last)
      - startSequences:    chain entries matching ^start\. (run during Start-GuestOS)
      - workloadSequences: every other chain entry (run during Start-GuestWorkload)

    A missing top-level or unresolvable prereq is logged and skipped — the
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
    foreach ($raw in $cycleCfg.baseline) {
        # Accept entries written with or without an extension. Older project
        # configs sometimes spell sequences as `<name>.json`; the migration
        # to `.yml` shouldn't break those clones.
        $topName = ([string]$raw) -replace '\.(ya?ml|json)$',''
        $topPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $topName -HostType $HostType -RepoRoot $RepoRoot
        if (-not $topPath) {
            # Throw PlannerFatal so the runner aborts the cycle (via the
            # !!!!! banner branch in Invoke-TestInnerRunner.ps1's catch)
            # instead of warn-and-continue with a fake "resolved to <last
            # attempted path>" pointer. A typo in the baseline used to
            # silently skip the entry, leaving operators chasing an empty
            # cycle; now the searched locations are spelled out and the
            # cycle stops on the spot.
            $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $topName -HostType $HostType -RepoRoot $RepoRoot
            $list = ($searched | ForEach-Object { "    $_" }) -join "`n"
            throw "PlannerFatal: cycle baseline references missing sequence: $topName (in $(Get-CycleConfigPath -RepoRoot $RepoRoot))`nSearched (no match):`n$list"
        }
        $topSeq = Read-SequenceFile -Path $topPath
        if (-not $topSeq.baseline) {
            Write-Warning "Top-level sequence has no baseline (no supported guest OS declared): $topName"
            continue
        }
        foreach ($osKey in $topSeq.baseline.Keys) {
            $guestKey = "guest.$osKey"
            $chain   = New-Object System.Collections.Generic.List[string]
            $visited = [System.Collections.Generic.HashSet[string]]::new()
            try {
                Add-CyclePrereqChainEntry -SequenceName $topName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $osKey -Chain $chain -Visited $visited
            } catch {
                # PlannerFatal (duplicate project sequence file) MUST propagate.
                # Per the message-prefix marker pattern, every intervening catch
                # has to re-throw or the cycle keeps running on an ambiguous plan.
                if ($_.Exception.Message -like 'PlannerFatal:*') { throw }
                Write-Warning "Skipping $topName / $osKey - $($_.Exception.Message)"
                continue
            }
            $startSeqs = New-Object System.Collections.Generic.List[string]
            $workSeqs  = New-Object System.Collections.Generic.List[string]
            foreach ($s in $chain) {
                if ($s -match '^start\.') { [void]$startSeqs.Add($s) } else { [void]$workSeqs.Add($s) }
            }
            # --- Cascade variables top-down across the chain --------------
            # `effectiveVariables` is a flattened {key: value} map computed
            # by walking the chain from TOP (the workload sequence; last
            # entry of $chain because the chain is dependency-ordered
            # deepest-first) down to the baseline. For each key declared
            # under any sequence's `variables:` block, the FIRST non-empty
            # value encountered from the top wins -- so a workload's
            # `username: webuser` overrides the baseline's `username:
            # yuuser26` end-to-end, and the same propagation applies to
            # any other variable a workload chooses to redefine.
            #
            # The runner injects this map as the sequence's variable scope
            # when running each sequence in the chain (overriding the
            # sequence-local `variables:` block); the planner also exposes
            # `effectiveUsername` as a convenience shortcut for the
            # `New-VM -Username` call site, which needs the OS account
            # name BEFORE any sequence runs.
            $effectiveVars = [ordered]@{}
            for ($i = $chain.Count - 1; $i -ge 0; $i--) {
                $sName = $chain[$i]
                $sPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $sName -HostType $HostType -RepoRoot $RepoRoot
                if (-not $sPath) { continue }
                try { $sSeq = Read-SequenceFile -Path $sPath } catch { continue }
                if (-not $sSeq.variables) { continue }
                foreach ($vk in $sSeq.variables.Keys) {
                    if ($effectiveVars.Contains($vk)) { continue }   # higher level already won
                    $vv = $sSeq.variables[$vk]
                    if ($null -eq $vv) { continue }
                    if ($vv -is [string] -and -not $vv.Trim()) { continue }
                    $effectiveVars[$vk] = $vv
                }
            }
            $effectiveUsername = if ($effectiveVars.Contains('username')) { [string]$effectiveVars['username'] } else { '' }
            $entries.Add([pscustomobject]@{
                topLevel            = $topName
                guestKey            = $guestKey
                fullChain           = @($chain.ToArray())
                startSequences      = @($startSeqs.ToArray())
                workloadSequences   = @($workSeqs.ToArray())
                effectiveVariables  = $effectiveVars
                effectiveUsername   = $effectiveUsername
            })
        }
    }
    # Wrap in @() at return so a single entry doesn't unwrap to scalar.
    return ,@($entries.ToArray())
}

<#
.SYNOPSIS
    Returns the deduplicated guest list from a cycle plan, in first-appearance order.
.DESCRIPTION
    The runner uses this for pre-flight folder checks, image refresh, and
    VM-name allocation — places that operate per unique guest rather than
    per plan entry. The relative order matches the order entries appear in
    the plan, which is itself the order top-level sequences appear in
    project/test/test.sequence.yml baseline.
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
    # levels appear in project/test/test.sequence.yml). Other entries fill
    # in keys the first one didn't declare. The 'username' shortcut is
    # surfaced separately because every guest needs one for New-VM.
    $mergedVars     = [ordered]@{}
    $mergedUsername = ''
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
    }
    return @{
        startSequences      = @($start.ToArray())
        workloadSequences   = @($work.ToArray())
        effectiveVariables  = $mergedVars
        effectiveUsername   = $mergedUsername
    }
}

<#
.SYNOPSIS
    Walks the baseline chain of a single named sequence (Test-Sequence helper).
.DESCRIPTION
    Resolve-CyclePlan keys off project/test/test.sequence.yml, which the
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
        $list = ($searched | ForEach-Object { "    $_" }) -join "`n"
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
        if (-not $sSeq.variables) { continue }
        foreach ($vk in $sSeq.variables.Keys) {
            if ($effectiveVars.Contains($vk)) { continue }
            $vv = $sSeq.variables[$vk]
            if ($null -eq $vv) { continue }
            if ($vv -is [string] -and -not $vv.Trim()) { continue }
            $effectiveVars[$vk] = $vv
        }
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

Export-ModuleMember -Function Get-CycleConfigPath, Get-CycleConfig, Resolve-CyclePlan, Get-CyclePlanGuestList, Get-CyclePlanSequencesForGuest, Resolve-NamedSequenceChain
