<#PSScriptInfo
.VERSION 2026.09.30
.GUID 423c7308-8393-45aa-a74f-97c52bf1c3df
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
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:EngineModule = Join-Path $PSScriptRoot "Test.SequenceEngine.psm1"
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

    Uses Read-SequenceFile (exported by Test.SequenceEngine.psm1) as the
    centralized powershell-yaml loader -- it parses any YAML file, not
    just sequence files, and keeps the dependency check in one place.
#>
function Get-CycleConfig {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-CycleConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path $path)) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_b6abddc95da1d271' -Arguments @{ path = "$path" })
    }
    $cfg = Read-SequenceFile -Path $path
    if (-not $cfg.sequences -or $cfg.sequences.Count -eq 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_037f5a478339db90' -Arguments @{ path = "$path" })
    }
    return $cfg
}

<#
.SYNOPSIS
    A project's label for a reader's language, or the English scalar when the
    project offers none.
.DESCRIPTION
    The contract is additive on purpose. `description:` stays exactly what it
    always was -- a scalar, in English -- and a project may add a sibling map
    keyed by locale tag:

        description: Deploy and verify the website
        descriptionLocalized:
          pt-BR: Implantar e verificar o site

    That shape survives all three pairings the project boundary has to keep
    working. A framework older than this ignores a key it does not know and
    reads the scalar. A project older than this ships no map and the scalar is
    all there is. Only when both are new does the map decide, and even then the
    scalar is the fallback for a locale the project did not translate.

    Publishing validates the complete map, its bounds and source-hash sidecar.
    The live reader remains total: it accepts only the exact canonical resolved
    tag it was handed and otherwise returns the scalar. A malformed optional
    map can therefore fail a release gate without stopping an unrelated cycle.
.OUTPUTS
    System.String -- the localized label, or the scalar, or ''.
#>
function Resolve-ProjectLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Entry,
        [Parameter(Mandatory)][string]$ScalarKey,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Locale
    )

    if ($null -eq $Entry -or $Entry -isnot [System.Collections.IDictionary]) { return '' }
    $scalarValue = $Entry[$ScalarKey]
    $scalar = if ($scalarValue -is [string]) { $scalarValue.Trim() } else { '' }

    $mapKey = $ScalarKey + 'Localized'
    if (-not $Locale -or -not $Entry.Contains($mapKey)) { return $scalar }
    # A LocaleContext hands this function an already resolved canonical tag.
    # Refusing a noncanonical caller value is safer than teaching this product
    # boundary a second locale matcher that can drift from the shared one.
    if ($Locale.Length -gt 35 -or
        ($Locale -cne 'qps-Plocm' -and
            $Locale -cnotmatch '^[a-z]{2,3}(?:-(?:[A-Z]{2}|[A-Z][a-z]{3}|[0-9][a-z0-9]{3}|[a-z0-9]{3}|[a-z0-9]{5,8}))*$')) {
        return $scalar
    }
    if ($Locale -ceq 'en-US') { return $scalar }
    $map = Get-ProjectLabelMap -Entry $Entry -ScalarKey $ScalarKey
    foreach ($tag in $map.Keys) {
        if ([string]::Equals("$tag", $Locale, [StringComparison]::Ordinal)) { return [string]$map[$tag] }
    }
    return $scalar
}

function Get-ProjectLabelMap {
    <#
    .SYNOPSIS
        The bounded, canonical locale map of one project label, or an empty map.
    .DESCRIPTION
        The publisher is authoritative and fails malformed project metadata.
        This live projection remains total: one bad optional entry makes the
        map unavailable, not the cycle.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Entry,
        [Parameter(Mandatory)][ValidateSet('displayName', 'description')][string]$ScalarKey
    )

    $result = [ordered]@{}
    if ($Entry -isnot [System.Collections.IDictionary]) { return $result }
    $mapKey = $ScalarKey + 'Localized'
    if (-not $Entry.Contains($mapKey)) { return $result }
    $map = $Entry[$mapKey]
    if ($map -isnot [System.Collections.IDictionary] -or @($map.Keys).Count -lt 1 -or @($map.Keys).Count -gt 16) {
        return $result
    }
    $max = if ($ScalarKey -eq 'displayName') { 160 } else { 2000 }
    foreach ($tag in @($map.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
        if ($tag -ceq 'en-US') { return [ordered]@{} }
        if ($tag.Length -gt 35 -or
            ($tag -cne 'qps-Plocm' -and
                $tag -cnotmatch '^[a-z]{2,3}(?:-(?:[A-Z]{2}|[A-Z][a-z]{3}|[0-9][a-z0-9]{3}|[a-z0-9]{3}|[a-z0-9]{5,8}))*$')) {
            return [ordered]@{}
        }
        $value = $map[$tag]
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) {
            return [ordered]@{}
        }
        $normalizedValue = $value.Normalize([Text.NormalizationForm]::FormC)
        $scalarCount = 0
        foreach ($rune in $normalizedValue.EnumerateRunes()) { $scalarCount++ }
        if ($scalarCount -gt $max) { return [ordered]@{} }
        $result[$tag] = $normalizedValue
    }
    return $result
}

# Internal helper: $true when a parsed sequence is an orchestration sequence
# (no `baseline:`, a non-empty `steps:`, first step action InvokeTestSequence).
# Inlined mirror of Test.Orchestrator\Test-IsOrchestrationSequence so the planner
# classifies entries without a runtime dependency on Test.Orchestrator (keeps this
# module unit-testable in isolation). Keep in sync with that canonical predicate.
function Test-PlannerSequenceIsOrchestration {
    param([Parameter(Mandatory)]$Sequence)
    if ($Sequence -isnot [System.Collections.IDictionary]) { return $false }
    if ($Sequence.Contains('baseline')) { return $false }
    if (-not $Sequence.Contains('steps') -or -not $Sequence['steps']) { return $false }
    $first = @($Sequence['steps'])[0]
    if ($first -isnot [System.Collections.IDictionary] -or -not $first.Contains('action')) { return $false }
    return ([string]$first['action'] -eq 'InvokeTestSequence')
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
        [Parameter(Mandatory)]$Visited,
        [string[]]$Visiting = @()
    )
    if ($SequenceName -in $Visiting) {
        $cycle = (@($Visiting) + $SequenceName) -join ' -> '
        $exception = [InvalidOperationException]::new("PlannerFatal: cyclic sequence prerequisites: $cycle")
        $exception.Data['YurunaFailureCode'] = 'sequence.plan_invalid'
        throw $exception
    }
    if ($Visited.Contains($SequenceName)) { return }
    $Visiting = @($Visiting) + $SequenceName
    $path = Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
    if (-not $path) {
        # PlannerFatal so the runner's Resolve-CyclePlan catch hits the
        # banner branch instead of degrading to legacy guestSequence on a
        # silent typo. List the actual searched locations so the operator
        # sees every probed path -- a single "resolved path: <X>" naming
        # the last-attempted file would be misleading.
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
        $list = Format-SequenceSearchList -Item $searched
        throw (New-SequencePlannerException -Key 'exceptions.runner_f1bde95b1f050137' -Arguments @{ sequenceName = "$SequenceName"; list = "$list" })
    }
    $seq = Read-SequenceFile -Path $path
    if ($seq.baseline -and $seq.baseline.Contains($OsKey)) {
        foreach ($prereq in $seq.baseline[$OsKey]) {
            Add-CyclePrereqChainEntry -SequenceName $prereq -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $OsKey -Chain $Chain -Visited $Visited -Visiting $Visiting
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

function Get-SequenceChainContext {
    <# .SYNOPSIS
    Splits dependency order and applies the same visible variable cascade for every planner entry.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Chain, [Parameter(Mandatory)][Collections.IDictionary]$Paths)
    $start = [Collections.Generic.List[string]]::new()
    $work = [Collections.Generic.List[string]]::new()
    foreach ($name in $Chain) { if ($name -match '^start\.') { $start.Add($name) } else { $work.Add($name) } }
    $variables = [ordered]@{}
    for ($index = $Chain.Count - 1; $index -ge 0; $index--) {
        $name = $Chain[$index]; $path = $Paths[$name]
        if (-not $path) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6d53b6631053aee8' -Arguments @{ sName = "$name" })
            continue
        }
        try { $sequence = Read-SequenceFile -Path $path } catch {
            if (Test-SequencePlannerFailure -ErrorObject $_) { throw }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ee13b7d44127b862' -Arguments @{ sName = "$name"; sPath = "$path"; message = $_.Exception.Message })
            continue
        }
        Merge-SequenceVariableCascade -Target $variables -Variables $sequence.variables
    }
    return @{ Start = $start; Work = $work; Variables = $variables }
}

function Get-SequenceEffectiveField {
    <# .SYNOPSIS
    Projects the chain's canonical guest identity and hardware fields after overrides.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][Collections.IDictionary]$Variables)
    $fields = @{}
    foreach ($name in 'username', 'hostname', 'memoryStartupBytes', 'cores', 'exposeVirtualizationExtensions') {
        $fields[$name] = if ($Variables.Contains($name)) { [string]$Variables[$name] } else { '' }
    }
    return $fields
}

function Add-CyclePlanEntriesForTopLevel {
    <#
    .SYNOPSIS
        Builds one plan entry per supported guest OS for a top-level sequence.
    .DESCRIPTION
        If supplied, PerGuestOverrides layers over the chain cascade and
        RestrictGuests limits the emitted guest keys. The current
        Resolve-CyclePlan caller supplies neither. A missing top-level throws
        PlannerFatal, while an unresolvable prerequisite is warned and skipped.
        One entry builder keeps cascade, failure handling and entry shape the
        same across plans.
    #>
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
        throw (New-SequencePlannerException -Key 'exceptions.runner_d72dd7b3536de5e5' -Arguments @{ topName = "$TopName"; sourceLabel = "$(if ($SourceLabel) { " $SourceLabel" })"; list = "$list" })
    }
    $topSeq = Read-SequenceFile -Path $topPath
    if (-not $topSeq.baseline) {
        # Orchestration sequences (InvokeTestSequence steps, no resource:/
        # baseline) are valid top-level entries -- the runner dispatches them via
        # Get-CycleOrchestrationList + Invoke-OrchestrationSequence, not the
        # per-guest chain planner -- so they contribute no guest plan entries and
        # must not warn. Anything else with no baseline is a genuine misconfig.
        if (-not (Test-PlannerSequenceIsOrchestration -Sequence $topSeq)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_45a07fd31e96a1d6' -Arguments @{ topName = "$TopName" })
        }
        return
    }
    foreach ($osKey in $topSeq.baseline.Keys) {
        $guestKey = "guest.$osKey"
        # Host filter: a host emits only the guests it can run.
        if ($null -ne $RestrictGuests -and ($RestrictGuests -notcontains $guestKey)) { continue }
        $chain   = New-Object System.Collections.Generic.List[string]
        $visited = [System.Collections.Generic.HashSet[string]]::new()
        try {
            Add-CyclePrereqChainEntry -SequenceName $TopName -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -OsKey $osKey -Chain $chain -Visited $visited
        } catch {
            # PlannerFatal (duplicate project sequence file) MUST propagate.
            if (Test-SequencePlannerFailure -ErrorObject $_) { throw }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bfce497ec631d602' -Arguments @{ topName = "$TopName"; osKey = "$osKey"; message = "$($_.Exception.Message)" })
            continue
        }
        $paths = [ordered]@{}
        foreach ($name in $chain) { $paths[$name] = Resolve-SequencePath -SequencesDir $SequencesDir -Name $name -HostType $HostType -RepoRoot $RepoRoot }
        $context = Get-SequenceChainContext -Chain $chain -Paths $paths
        $startSeqs = $context.Start; $workSeqs = $context.Work; $effectiveVars = $context.Variables
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
        $fields = Get-SequenceEffectiveField -Variables $effectiveVars
        $Entries.Add([pscustomobject]@{
            topLevel            = $TopName
            guestKey            = $guestKey
            fullChain           = @($chain.ToArray())
            startSequences      = @($startSeqs.ToArray())
            workloadSequences   = @($workSeqs.ToArray())
            effectiveVariables  = $effectiveVars
            effectiveUsername   = $fields.username
            effectiveHostname   = $fields.hostname
            effectiveMemoryStartupBytes = $fields.memoryStartupBytes
            effectiveCores      = $fields.cores
            effectiveExposeVirtualizationExtensions = $fields.exposeVirtualizationExtensions
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
    Returns the project/test/test.runner.yml entries that are ORCHESTRATION
    sequences (InvokeTestSequence steps, no resource:/baseline), each as
    [pscustomobject]@{ name; path }. Empty when there are none.
.DESCRIPTION
    Orchestration sequences own their own status cycle + transcript via
    Invoke-OrchestrationSequence (Test.Orchestrator); they are NOT per-guest
    chains, so Resolve-CyclePlan emits no plan entries for them. The runner reads
    this companion list to detect an orchestration cycle and delegate to the
    orchestrator instead of the per-guest VM lifecycle. Guest-sequence entries are
    absent here (handled by Resolve-CyclePlan). Reads the same test.runner.yml and
    resolves each entry the same way; a name that does not resolve is skipped here
    (the miss surfaces via Resolve-CyclePlan's PlannerFatal, one authority for it).
#>
function Get-CycleOrchestrationList {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType
    )
    $cycleCfg = Get-CycleConfig -RepoRoot $RepoRoot
    $list = New-Object System.Collections.Generic.List[Object]
    foreach ($raw in $cycleCfg.sequences) {
        $name = ([string]$raw) -replace '\.(ya?ml|json)$',''
        $path = Resolve-SequencePath -SequencesDir $SequencesDir -Name $name -HostType $HostType -RepoRoot $RepoRoot
        if (-not $path) { continue }
        $seq = Read-SequenceFile -Path $path
        if (Test-PlannerSequenceIsOrchestration -Sequence $seq) {
            $list.Add([pscustomobject]@{ name = $name; path = $path })
        }
    }
    return ,@($list.ToArray())
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
    # in keys the first one didn't declare. The 'username' and 'hostname'
    # shortcuts are surfaced separately because both feed New-VM directly
    # (the cloud-init account and the guest's local-hostname).
    $mergedVars     = [ordered]@{}
    $mergedUsername = ''
    $mergedHostname = ''
    # VM sizing overrides merge under the same first-appearance rule as username.
    $mergedMemoryStartupBytes = ''
    $mergedCores    = ''
    $mergedExposeVirtualizationExtensions = ''
    # Per-guest keystrokeMechanism (set only when a plan entry was built with
    # -PerGuestOverrides). First non-null across this guest's entries wins --
    # same first-appearance rule as effectiveUsername. $null when the field is
    # absent or null, so the runner inherits the global default.
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
        if (-not $mergedHostname -and ($e.PSObject.Properties.Name -contains 'effectiveHostname') -and $e.effectiveHostname) { $mergedHostname = $e.effectiveHostname }
        if (-not $mergedMemoryStartupBytes -and ($e.PSObject.Properties.Name -contains 'effectiveMemoryStartupBytes') -and $e.effectiveMemoryStartupBytes) { $mergedMemoryStartupBytes = $e.effectiveMemoryStartupBytes }
        if (-not $mergedCores -and ($e.PSObject.Properties.Name -contains 'effectiveCores') -and $e.effectiveCores) { $mergedCores = $e.effectiveCores }
        if (-not $mergedExposeVirtualizationExtensions -and ($e.PSObject.Properties.Name -contains 'effectiveExposeVirtualizationExtensions') -and $e.effectiveExposeVirtualizationExtensions) { $mergedExposeVirtualizationExtensions = $e.effectiveExposeVirtualizationExtensions }
        if (-not $mergedKsm -and ($e.PSObject.Properties.Name -contains 'keystrokeMechanism') -and $e.keystrokeMechanism) { $mergedKsm = $e.keystrokeMechanism }
    }
    return @{
        startSequences      = @($start.ToArray())
        workloadSequences   = @($work.ToArray())
        effectiveVariables  = $mergedVars
        effectiveUsername   = $mergedUsername
        effectiveHostname   = $mergedHostname
        effectiveMemoryStartupBytes = $mergedMemoryStartupBytes
        effectiveCores      = $mergedCores
        effectiveExposeVirtualizationExtensions = $mergedExposeVirtualizationExtensions
        keystrokeMechanism  = $mergedKsm
    }
}

<#
.SYNOPSIS
    Walks the baseline chain of a single named sequence (Debug-TestSequence helper).
.DESCRIPTION
    Resolve-CyclePlan keys off project/test/test.runner.yml, which the
    runner consumes but Debug-TestSequence does not. This sibling takes a top-
    level sequence NAME directly (the same name a Debug-TestSequence operator
    types) and produces the same per-entry shape Resolve-CyclePlan would
    have emitted for that sequence:
      topLevel / guestKey / fullChain / startSequences / workloadSequences
      / effectiveVariables / effectiveUsername / effectiveHostname
      / effectiveMemoryStartupBytes / effectiveCores
      / effectiveExposeVirtualizationExtensions / chainPaths

    When the named sequence has no `baseline:` block (rare -- the framework
    convention is that every workload declares the prereq it needs), the
    chain degenerates to the sequence itself.

    -OsKey is optional; absent, the first key of the sequence's own
    `baseline:` map is used. Pass it explicitly when a sequence supports
    more than one OS and the caller wants a specific one (Debug-TestSequence
    derives it from the resolved GuestKey, stripping the "guest." prefix).

    -TopLevelPath is the path-override escape hatch for Debug-TestSequence dev
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
    # Top-level: prefer the explicit override (Debug-TestSequence path-form),
    # fall back to Resolve-SequencePath for the name form.
    $topPath = if ($TopLevelPath) { $TopLevelPath } else {
        Resolve-SequencePath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
    }
    if (-not $topPath -or -not (Test-Path -LiteralPath $topPath)) {
        $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $SequenceName -HostType $HostType -RepoRoot $RepoRoot
        $list = Format-SequenceSearchList -Item $searched
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_6c293b52d562e7c0' -Arguments @{ sequenceName = "$SequenceName"; list = "$list" })
    }
    $topSeq = Read-SequenceFile -Path $topPath

    # Resolve the OS key once. Sequences without a baseline are run
    # standalone (no prereq chain); the operator sees just the named
    # sequence in the printed plan.
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
        $hname = if ($vars -is [System.Collections.IDictionary] -and $vars.Contains('hostname')) { [string]$vars['hostname'] } else { '' }
        $mem   = if ($vars -is [System.Collections.IDictionary] -and $vars.Contains('memoryStartupBytes')) { [string]$vars['memoryStartupBytes'] } else { '' }
        $cores = if ($vars -is [System.Collections.IDictionary] -and $vars.Contains('cores')) { [string]$vars['cores'] } else { '' }
        $exposeVirt = if ($vars -is [System.Collections.IDictionary] -and $vars.Contains('exposeVirtualizationExtensions')) { [string]$vars['exposeVirtualizationExtensions'] } else { '' }
        $paths = [ordered]@{ $SequenceName = $topPath }
        return [pscustomobject]@{
            topLevel            = $SequenceName
            guestKey            = ''
            fullChain           = @($SequenceName)
            startSequences      = @()
            workloadSequences   = @($SequenceName)
            effectiveVariables  = $vars
            effectiveUsername   = $uname
            effectiveHostname   = $hname
            effectiveMemoryStartupBytes = $mem
            effectiveCores      = $cores
            effectiveExposeVirtualizationExtensions = $exposeVirt
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

    $context = Get-SequenceChainContext -Chain $chain -Paths $paths
    $startSeqs = $context.Start; $workSeqs = $context.Work; $effectiveVars = $context.Variables
    $fields = Get-SequenceEffectiveField -Variables $effectiveVars

    return [pscustomobject]@{
        topLevel            = $SequenceName
        guestKey            = $guestKey
        fullChain           = @($chain.ToArray())
        startSequences      = @($startSeqs.ToArray())
        workloadSequences   = @($workSeqs.ToArray())
        effectiveVariables  = $effectiveVars
        effectiveUsername   = $fields.username
        effectiveHostname   = $fields.hostname
        effectiveMemoryStartupBytes = $fields.memoryStartupBytes
        effectiveCores      = $fields.cores
        effectiveExposeVirtualizationExtensions = $fields.exposeVirtualizationExtensions
        chainPaths          = $paths
    }
}

Export-ModuleMember -Function Resolve-ProjectLabel, Get-ProjectLabelMap, Get-CycleConfigPath, Get-CycleConfig, Resolve-CyclePlan, Get-CycleOrchestrationList, Get-CyclePlanGuestList, Get-CyclePlanSequenceList, Get-CyclePlanSequencesForGuest, Resolve-NamedSequenceChain
