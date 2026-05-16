<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345677a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
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
    if (-not (Test-Path $path)) {
        throw "Prereq sequence not found: $SequenceName (resolved path: $path)"
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
        if (-not (Test-Path $topPath)) {
            Write-Warning "Cycle baseline references missing sequence: $topName (resolved to $topPath)"
            continue
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
                Write-Warning "Skipping $topName / $osKey - $($_.Exception.Message)"
                continue
            }
            $startSeqs = New-Object System.Collections.Generic.List[string]
            $workSeqs  = New-Object System.Collections.Generic.List[string]
            foreach ($s in $chain) {
                if ($s -match '^start\.') { [void]$startSeqs.Add($s) } else { [void]$workSeqs.Add($s) }
            }
            $entries.Add([pscustomobject]@{
                topLevel          = $topName
                guestKey          = $guestKey
                fullChain         = @($chain.ToArray())
                startSequences    = @($startSeqs.ToArray())
                workloadSequences = @($workSeqs.ToArray())
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
    foreach ($e in $Plan) {
        if ($e.guestKey -ne $GuestKey) { continue }
        foreach ($s in $e.fullChain) {
            if (-not $seen.Add($s)) { continue }
            if ($s -match '^start\.') { [void]$start.Add($s) } else { [void]$work.Add($s) }
        }
    }
    return @{
        startSequences    = @($start.ToArray())
        workloadSequences = @($work.ToArray())
    }
}

Export-ModuleMember -Function Get-CycleConfigPath, Get-CycleConfig, Resolve-CyclePlan, Get-CyclePlanGuestList, Get-CyclePlanSequencesForGuest
