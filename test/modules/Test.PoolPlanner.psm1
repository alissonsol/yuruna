<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42d4e5f6-a7b8-4c90-9123-4d5e6f7a8b9c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool planner test-set guest compatibility
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Pool planner: turn a pool's assigned test-sets into a cycle plan THIS
# host can run. Decentralized -- there is no central dispatch: each runner
# autonomously keeps only the guests it can run (folder present + capability
# supported + guest<->hypervisor compatible) and skips the rest, trusting another
# pool host to cover them. Strictly additive + best-effort: any missing/malformed
# input degrades to $null so the inner runner falls back to its single-host
# test.runner.yml plan (it never throws or halts the loop). cycleStrategy=all and
# provisioning.betweenSets=none are the runtime-active values; other enum values
# are validated then run as all/none with a warning (not yet implemented).

# Map a host type to its hypervisor token (host.windows.hyper-v -> hyper-v,
# host.ubuntu.kvm -> kvm, host.macos.utm -> utm) -- the same derivation the host
# registration record uses, so guests.compatibility.yml rules and the registration
# agree on the token.
function Get-PoolHostHypervisor {
    <#
    .SYNOPSIS
    Derives the hypervisor token (hyper-v, kvm, utm) from a host.<os>.<hv> host type string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$HostType)
    return ($HostType -replace '^host\.[^.]+\.', '')
}

# Get-CompatibleHypervisorList returns the hypervisor list a guest is allowed on per
# guests.compatibility.yml, or $null when there is NO rule for the guest (the
# caller treats $null as "permit": compatibility is advisory; folder + capability
# still gate). Pure.
function Get-CompatibleHypervisorList {
    <#
    .SYNOPSIS
    Returns the array of hypervisors a guest is allowed on per the compatibility rules, or $null when no rule matches the guest.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter()][AllowNull()]$Compatibility, [Parameter(Mandatory)][string]$GuestKey)
    if (-not ($Compatibility -is [System.Collections.IDictionary]) -or -not $Compatibility.Contains('rules')) { return $null }
    foreach ($rule in @($Compatibility['rules'])) {
        if (($rule -is [System.Collections.IDictionary]) -and ([string]$rule['guestKey'] -eq $GuestKey)) {
            # Unary comma so a single-hypervisor rule stays a (one-element) array
            # rather than unwrapping to a scalar string on return.
            return , ([string[]]@($rule['hypervisors']))
        }
    }
    return $null   # no rule -> permit
}

# Test-GuestCompatibleWithHost: is $GuestKey allowed on this host's hypervisor?
# PERMISSIVE when the guest has no rule (or no compatibility file) -- a missing
# rule never silently drops a guest the host can otherwise run. Pure.
function Test-GuestCompatibleWithHost {
    <#
    .SYNOPSIS
    Tests whether a guest is allowed on this host's hypervisor, returning $true when the guest has no compatibility rule.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Compatibility,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$HostType
    )
    $allowed = Get-CompatibleHypervisorList -Compatibility $Compatibility -GuestKey $GuestKey
    if ($null -eq $allowed) { return $true }   # advisory: no rule -> permit
    $hv = Get-PoolHostHypervisor -HostType $HostType
    return ($allowed -contains $hv)
}

# Select-RunnableGuestList is the PURE host filter: from the candidate guests, keep
# the ones this host can run -- folder present AND capability supported AND
# hypervisor compatible -- in stable (candidate) order. The caller supplies the
# folder + capability booleans (they require I/O); compatibility is evaluated here
# from the rules. Unit-testable without any disk.
function Select-RunnableGuestList {
    <#
    .SYNOPSIS
    Filters candidate guests to those this host can run (folder present, capability supported, hypervisor compatible), preserving candidate order.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CandidateGuests,
        [Parameter(Mandatory)][hashtable]$FolderPresent,
        [Parameter(Mandatory)][hashtable]$CapabilitySupported,
        [Parameter()][AllowNull()]$Compatibility,
        [Parameter(Mandatory)][string]$HostType
    )
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($g in $CandidateGuests) {
        if (-not ($FolderPresent.ContainsKey($g) -and $FolderPresent[$g]))         { continue }
        if (-not ($CapabilitySupported.ContainsKey($g) -and $CapabilitySupported[$g])) { continue }
        if (-not (Test-GuestCompatibleWithHost -Compatibility $Compatibility -GuestKey $g -HostType $HostType)) { continue }
        $out.Add($g)
    }
    # Unary comma so a single runnable guest stays a (one-element) array.
    return , ([string[]]@($out))
}

# --- REGION: I/O readers (best-effort; $null on any miss so the caller degrades)

# Read-YurunaPoolManifest reads runtime/pool.manifest.json (written by the outer
# loop's Sync-YurunaPoolIntent). $null when absent/unparseable (the inner then
# runs single-host).
function Read-YurunaPoolManifest {
    <#
    .SYNOPSIS
    Reads runtime/pool.manifest.json into a hashtable, returning $null when the file is absent or unparseable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return $null }
    $path = Join-Path $RuntimeDir 'pool.manifest.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $obj = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [System.Collections.IDictionary]) { return $obj }
    } catch { Write-Verbose "Read-YurunaPoolManifest: $($_.Exception.Message)" }
    return $null
}

# Resolve the project test dir (where test.runner.yml / test-sets/ /
# guests.compatibility.yml live) from the cycle-config path.
function Get-PoolProjectTestDir {
    <#
    .SYNOPSIS
    Resolves the project test directory for a repo root, using the cycle-config path when available and a default subpath otherwise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    if (Get-Command Get-CycleConfigPath -ErrorAction SilentlyContinue) {
        return (Split-Path -Parent (Get-CycleConfigPath -RepoRoot $RepoRoot))
    }
    return (Join-Path $RepoRoot (Join-Path 'project' 'test'))
}

# Read-YurunaGuestCompatibility reads project/test/guests.compatibility.yml.
# $null when absent -> the compatibility gate is permissive (open-decision policy).
function Read-YurunaGuestCompatibility {
    <#
    .SYNOPSIS
    Reads project/test/guests.compatibility.yml into an ordered dictionary, returning $null when absent or unparseable.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { return $null }
    $path = Join-Path (Get-PoolProjectTestDir -RepoRoot $RepoRoot) 'guests.compatibility.yml'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered
        if ($doc -is [System.Collections.IDictionary]) { return $doc }
    } catch { Write-Warning "pool: guests.compatibility.yml parse failed ($($_.Exception.Message)); treating compatibility as permissive." }
    return $null
}

# Read-YurunaTestSetManifest reads project/test/test-sets/<Name>.yml. $null when
# absent/malformed or schemaVersion!=1 -> the caller SKIPS that one set (other
# sets still run) and never throws.
function Read-YurunaTestSetManifest {
    <#
    .SYNOPSIS
    Reads a named test-set manifest from project/test/test-sets, returning $null when it is absent, malformed, or not schemaVersion 1.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$Name)
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { return $null }
    $path = Join-Path (Join-Path (Get-PoolProjectTestDir -RepoRoot $RepoRoot) 'test-sets') ("$Name.yml")
    if (-not (Test-Path -LiteralPath $path)) { Write-Warning "pool: test-set manifest not found: $path"; return $null }
    try {
        $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered
    } catch { Write-Warning "pool: test-set '$Name' parse failed ($($_.Exception.Message)); skipping it."; return $null }
    if (-not ($doc -is [System.Collections.IDictionary])) { return $null }
    if ([int]$doc['schemaVersion'] -ne 1) { Write-Warning "pool: test-set '$Name' schemaVersion is not 1; skipping it."; return $null }
    return $doc
}

# --- REGION: Orchestrator

# Resolve-PoolCyclePlan builds the cycle plan for a pooled host from its pool
# manifest: iterate the assigned test-sets (ordered by `order`), resolve each into
# plan entries, drop the guests this host can't run, and concatenate
# (cycleStrategy=all). Returns the combined plan, or $null when nothing is runnable
# (the inner runner then falls back to single-host). Best-effort; never throws
# except PlannerFatal (a sequence typo must still abort, like the single-host path).
function Resolve-PoolCyclePlan {
    <#
    .SYNOPSIS
    Builds the combined cycle plan for a pooled host from its manifest's assigned test-sets, keeping only the guests this host can run, or $null when nothing is runnable.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest
    )
    $testSets = @($Manifest['testSets'])
    if ($testSets.Count -eq 0) { return $null }
    # Stable order by `order` (default 0), then declaration order.
    $ordered = $testSets | Where-Object { $_ -is [System.Collections.IDictionary] } |
        Sort-Object -Stable { if ($_.Contains('order')) { [int]$_['order'] } else { 0 } }
    $compat = Read-YurunaGuestCompatibility -RepoRoot $RepoRoot
    $all = New-Object System.Collections.Generic.List[Object]
    foreach ($ts in $ordered) {
        $name = [string]$ts['name']
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $strategy = if ($ts.Contains('cycleStrategy')) { [string]$ts['cycleStrategy'] } else { 'all' }
        if ($strategy -and $strategy -ne 'all') {
            Write-Warning "pool: test-set '$name' cycleStrategy='$strategy' not yet implemented; running 'all'."
        }
        $body = Read-YurunaTestSetManifest -RepoRoot $RepoRoot -Name $name
        if (-not $body) { continue }   # missing/malformed -> skip this set
        $between = if (($body['provisioning'] -is [System.Collections.IDictionary]) -and $body['provisioning'].Contains('betweenSets')) { [string]$body['provisioning']['betweenSets'] } else { 'none' }
        if ($between -and $between -ne 'none') {
            Write-Warning "pool: test-set '$name' provisioning.betweenSets='$between' not yet implemented; treating as 'none'."
        }
        $seqs = [string[]]@($body['sequences'])
        if ($seqs.Count -eq 0) { Write-Warning "pool: test-set '$name' has no sequences; skipping."; continue }
        # Assignment (NOT @(...)) -- Resolve-TestSetCyclePlan returns ,@(...); wrapping
        # the call in @() would nest the entries one level deep.
        $setPlan = Resolve-TestSetCyclePlan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType `
            -Sequences $seqs -SetName $name -PerGuestOverrides $body['perGuestOverrides']
        if (@($setPlan).Count -eq 0) { continue }
        # Per-host filter: keep only guests this host can run (assignment, same reason).
        $candidates = Get-CyclePlanGuestList -Plan $setPlan
        $folderOk = @{}; $capOk = @{}
        foreach ($g in $candidates) {
            $folderOk[$g] = [bool](Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $g)
            # Capability: run the existing whole-plan checker on this guest's sub-plan
            # so a host that lacks the actions' HostIO/OCR skips the guest (rather than
            # hard-failing the cycle-level capability gate downstream).
            $cap = $true
            try {
                $sub = @($setPlan | Where-Object { $_.guestKey -eq $g })
                $r = Test-CyclePlanCapabilityFromPlan -Plan $sub -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
                if ($r -is [System.Collections.IDictionary] -and $r.Contains('supported')) { $cap = [bool]$r['supported'] }
            } catch { Write-Verbose "pool: capability probe for $g threw: $($_.Exception.Message)" }
            $capOk[$g] = $cap
        }
        $runnable = Select-RunnableGuestList -CandidateGuests $candidates -FolderPresent $folderOk -CapabilitySupported $capOk -Compatibility $compat -HostType $HostType
        if ($runnable.Count -eq 0) {
            Write-Warning "pool: no runnable guest for test-set '$name' on this host ($HostType); skipping it."
            continue
        }
        foreach ($e in $setPlan) {
            if ($runnable -contains $e.guestKey) { $all.Add($e) }
        }
    }
    if ($all.Count -eq 0) { return $null }
    return ,@($all.ToArray())
}

Export-ModuleMember -Function `
    Get-PoolHostHypervisor, Get-CompatibleHypervisorList, Test-GuestCompatibleWithHost, Select-RunnableGuestList, `
    Read-YurunaPoolManifest, Get-PoolProjectTestDir, Read-YurunaGuestCompatibility, Read-YurunaTestSetManifest, `
    Resolve-PoolCyclePlan
