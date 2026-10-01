<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42b8932c-aa15-4760-a06d-b3037804847c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool planner manifest guest compatibility
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

# Pool planner: Read-YurunaPoolManifest reads runtime/pool.manifest.json (the
# pool's framework and project repositories) for the inner runner. The
# guests.compatibility.yml helpers below evaluate a project's per-guest
# hypervisor rules. The runner does not call them, because every pool member
# runs its project's whole plan; Test.PoolPlanner.Tests.ps1 is their only
# caller, and Test-PoolIntent.ps1 validates the store's copy of that file
# through Test.PoolAdmin instead. See ../../docs/pool-admin.md#what-a-pool-is
# for the decentralized, best-effort model. -- Test.PoolPlanner.psm1

# Map a host type to its hypervisor token (host.windows.hyper-v -> hyper-v,
# host.ubuntu.kvm -> kvm, host.macos.utm -> utm) -- the same derivation the host
# registration record uses, so guests.compatibility.yml rules and the registration
# agree on the token.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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

# Resolve the project test dir (where test.runner.yml and
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
    } catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bbfd1d495162fdc3' -Arguments @{ message = "$($_.Exception.Message)" }) }
    return $null
}

Export-ModuleMember -Function `
    Get-PoolHostHypervisor, Get-CompatibleHypervisorList, Test-GuestCompatibleWithHost, Select-RunnableGuestList, `
    Read-YurunaPoolManifest, Get-PoolProjectTestDir, Read-YurunaGuestCompatibility
