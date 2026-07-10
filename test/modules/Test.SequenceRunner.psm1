<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42f2c5e4-b9a0-4367-cd15-4e6f9b3c2d51
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

# Chain planning + chain execution helpers for Test-Sequence.ps1.
# Two functions:
#
#   Resolve-TestSequencePlan  -- Build the $ChainEntries list (name,
#                                path, sequence, stepCount, globalStart)
#                                and detect a warm-path requiresSnapshot.
#                                Returns @{ chainEntries; chainPlan;
#                                effectiveUser; chainTotalSteps;
#                                requiredSnapshotId; warmPath; resolveFailed }.
#
#   Invoke-TestSequenceChain  -- Run the requested step range across the
#                                planned chain. Returns @{ ok; finishedVmName }
#                                so the caller can update its outer
#                                $VMName when a mid-chain saveDiskSnapshot
#                                renamed the VM.
#
# Each function takes its inputs by parameter (no script-scope reads)
# so a test harness can call them with fixture data. The host-driver-
# resolved $VMName and Invoke-Sequence's $ShowSensitive switch are
# passed through verbatim.

function Resolve-TestSequencePlan {
    <#
    .SYNOPSIS
        Build the chain plan + entries for Test-Sequence and detect a
        warm-path requiresSnapshot.
    .DESCRIPTION
        Walks the named sequence's baseline chain via
        Resolve-NamedSequenceChain, reads
        each entry's YAML, computes per-entry stepCount + globalStart,
        and -- when the top-level declares requiresSnapshot.id with a
        persisted snapshot already on the host -- drops every prereq so
        the truncated chain runs only the top-level entry against the
        persisted VM (warm path).
    .PARAMETER RepoRoot
        Repo root (the parent of test/).
    .PARAMETER SequencesDir
        sequences/ dir under the framework tree.
    .PARAMETER HostType
        host.windows.hyper-v / host.macos.utm / host.ubuntu.kvm.
    .PARAMETER SequenceName
        Base name of the top-level sequence (no .yml).
    .PARAMETER OsKey
        Guest OS key (the GuestKey with the leading "guest." stripped),
        used by Resolve-NamedSequenceChain to partition the baseline
        graph.
    .PARAMETER SequencePathOverride
        When the user passed a path (not a name), forwards the top-level
        file directly to the planner via -TopLevelPath. Prereqs still
        resolve via the standard search.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true)][string]$RepoRoot,
        [Parameter(Mandatory=$true)][string]$SequencesDir,
        [Parameter(Mandatory=$true)][string]$HostType,
        [Parameter(Mandatory=$true)][string]$SequenceName,
        [Parameter(Mandatory=$true)][string]$OsKey,
        [string]$SequencePathOverride = $null
    )

    $plannerArgs = @{
        RepoRoot     = $RepoRoot
        SequencesDir = $SequencesDir
        HostType     = $HostType
        SequenceName = $SequenceName
        OsKey        = $OsKey
    }
    if ($SequencePathOverride) { $plannerArgs.TopLevelPath = $SequencePathOverride }
    $ChainPlan = Resolve-NamedSequenceChain @plannerArgs
    $effectiveUser = $ChainPlan.effectiveUsername

    # Build (name, path, sequence, stepCount, globalStart) per chain entry
    # using the planner's chainPaths map. Re-reading the YAML here (vs.
    # returning parsed sequences from the planner) keeps the planner's
    # return type simple; YAML parse cost is trivial next to running steps.
    $ChainEntries = New-Object System.Collections.Generic.List[object]
    $globalCount = 0
    foreach ($name in $ChainPlan.fullChain) {
        $path = $ChainPlan.chainPaths[$name]
        if (-not $path) {
            $searched = Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $name -HostType $HostType -RepoRoot $RepoRoot
            Write-Error "Chain prereq not found: $name (referenced via baseline of $SequenceName)"
            # Status via Write-Information, never Write-Output: this function's
            # return value is captured (`$plan = Resolve-TestSequencePlan`), so a
            # Write-Output string would join the returned hashtable into an array
            # (the pipeline-pollution trap). A later `$plan.chainEntries` member
            # access would then enumerate and unwrap a single warm-path entry to a
            # bare object, failing the chain runner's [IList] binding.
            Write-Information "Searched (no match):" -InformationAction Continue
            foreach ($p in $searched) { Write-Information "  $p" -InformationAction Continue }
            return @{
                chainEntries       = $null
                chainPlan          = $ChainPlan
                effectiveUser      = $effectiveUser
                chainTotalSteps    = 0
                requiredSnapshotId = $null
                warmPath           = $false
                resolveFailed      = $true
            }
        }
        $seq = Read-SequenceFile -Path $path
        $count = @($seq.steps).Count
        $ChainEntries.Add([pscustomobject]@{
            name        = $name
            path        = $path
            sequence    = $seq
            stepCount   = $count
            globalStart = ($globalCount + 1)
        })
        $globalCount += $count
    }
    $ChainTotalSteps = $globalCount

    if ($ChainPlan.fullChain.Count -gt 1) {
        Write-Information "Chain: $($ChainPlan.fullChain -join ' -> ')" -InformationAction Continue
    } else {
        Write-Information "Chain: $($ChainPlan.fullChain[0]) (no baseline prereqs declared)" -InformationAction Continue
    }

    # === requiresSnapshot warm-path probe =======================================
    # When the top-level sequence declares `requiresSnapshot: { id: <X> }`,
    # the chain ends in a saveDiskSnapshot that renames `test-<guestKey>`
    # -> <X>. Two paths:
    #
    #   WARM: persisted VM <X> exists AND already has snapshot <X> on disk.
    #         Skip every prereq sequence and run only the top-level against
    #         <X>. The top-level's first loadDiskSnapshot reverts the disk.
    #
    #   COLD: snapshot not present. Walk the full chain. The build VM is
    #         created with the test-<guestKey> name (so Remove-TestVMFiles
    #         can sweep a failed cold build); saveDiskSnapshot renames it
    #         to <X> mid-chain, and subsequent entries operate on <X>. The
    #         per-entry loop below detects the rename and updates $VMName.
    $requiredSnapshotId = $null
    $warmPath           = $false
    $topLevelEntry      = $ChainEntries[$ChainEntries.Count - 1]
    if ($topLevelEntry.sequence.requiresSnapshot -is [System.Collections.IDictionary] -and
        $topLevelEntry.sequence.requiresSnapshot.Contains('id') -and
        $topLevelEntry.sequence.requiresSnapshot.id) {
        $requiredSnapshotId = [string]$topLevelEntry.sequence.requiresSnapshot.id
    }
    if ($requiredSnapshotId) {
        # Distinguish "snapshot absent" (a normal cold-path build) from "could
        # not determine" (a probe error). Treating a query failure as absent
        # would trigger a full cold rebuild whose saveDiskSnapshot renames a
        # build VM onto <X> -- clobbering a snapshot that may in fact exist.
        # Retry briefly to ride out a transient hypervisor blip; if the probe
        # still cannot answer, fail the plan loudly rather than silently
        # rebuilding on an unconfirmed "absent".
        $snapPresent     = $false
        $probeDetermined = $false
        $probeError      = $null
        for ($probeAttempt = 1; $probeAttempt -le 3 -and -not $probeDetermined; $probeAttempt++) {
            try {
                $snapPresent     = [bool](Test-VMDiskSnapshot -VMName $requiredSnapshotId -Id $requiredSnapshotId)
                $probeDetermined = $true
            } catch {
                $probeError = $_.Exception.Message
                if ($probeAttempt -lt 3) { Start-Sleep -Milliseconds (250 * $probeAttempt) }
            }
        }
        if (-not $probeDetermined) {
            Write-Warning "requiresSnapshot: could not determine whether snapshot '$requiredSnapshotId' exists after 3 probe attempts ($probeError). Failing the plan rather than risk a cold rebuild that clobbers an existing snapshot."
            return @{
                chainEntries       = $null
                chainPlan          = $ChainPlan
                effectiveUser      = $effectiveUser
                chainTotalSteps    = 0
                requiredSnapshotId = $requiredSnapshotId
                warmPath           = $false
                resolveFailed      = $true
            }
        }
        if ($snapPresent) {
            Write-Information "requiresSnapshot: snapshot '$requiredSnapshotId' present on persisted VM '$requiredSnapshotId' -- skipping baseline chain (warm path)." -InformationAction Continue
            $warmPath = $true
            # Drop every prereq; keep only the top-level entry and rebase its
            # globalStart to 1 so -StartStep / -StopStep index into the
            # truncated step list naturally.
            $topLevelEntry.globalStart = 1
            $ChainEntries = New-Object System.Collections.Generic.List[object]
            [void]$ChainEntries.Add($topLevelEntry)
            $ChainTotalSteps = $topLevelEntry.stepCount
        } else {
            Write-Information "requiresSnapshot: snapshot '$requiredSnapshotId' not on host -- running full baseline chain (cold path; VM will be renamed to '$requiredSnapshotId' at saveDiskSnapshot)." -InformationAction Continue
        }
    }

    return @{
        chainEntries       = $ChainEntries
        chainPlan          = $ChainPlan
        effectiveUser      = $effectiveUser
        chainTotalSteps    = $ChainTotalSteps
        requiredSnapshotId = $requiredSnapshotId
        warmPath           = $warmPath
        resolveFailed      = $false
    }
}

function Invoke-TestSequenceChain {
    <#
    .SYNOPSIS
        Run the requested step range across the planned chain entries.
    .DESCRIPTION
        For each chain entry, intersects its global step range with the
        operator's requested range and runs that local step window against
        the entry's real file via Invoke-Sequence -StartStep / -StopStep
        (no temp-YAML slicing -- Invoke-Sequence windows the steps itself
        through Select-SequenceStepWindow). Passes the chain plan's
        effectiveVariables, detects mid-chain saveDiskSnapshot renames, and
        returns the final VM name so the caller can update its outer $VMName.
    .PARAMETER ChainEntries
        Planner-built entries: each a [pscustomobject] with name, path,
        sequence, stepCount, globalStart.
    .PARAMETER ChainPlan
        The whole plan hashtable from Resolve-TestSequencePlan; this
        function reads chainPlan.effectiveVariables and
        chainPlan.fullChain.Count for the completion banner.
    .PARAMETER StartStep
        1-based start step in the concatenated chain (caller-validated).
    .PARAMETER EffectiveStop
        1-based inclusive stop step in the concatenated chain (caller-
        validated; equals $StopStep when set, else $ChainTotalSteps).
    .PARAMETER StopStep
        The operator's -StopStep, used only to format the trailing
        "left running for inspection" vs. "Chain completed" banner.
    .PARAMETER ChainTotalSteps
        Total step count across the entire planned chain.
    .PARAMETER HostType
        Forwarded to Invoke-Sequence.
    .PARAMETER GuestKey
        Forwarded to Invoke-Sequence.
    .PARAMETER VMName
        Initial VM name. Updated locally on a mid-chain rename, picked up from
        Get-SequenceFinishedVMName after each entry.
    .PARAMETER ShowSensitive
        Forwarded to Invoke-Sequence verbatim.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$ChainEntries,

        # Resolve-NamedSequenceChain returns a [pscustomobject], which a
        # [hashtable] constraint here would reject at coercion. [psobject]
        # accepts both shapes, and all access below is via `.` member
        # access which works equivalently for either.
        [Parameter(Mandatory=$true)]
        [psobject]$ChainPlan,

        [Parameter(Mandatory=$true)][int]$StartStep,
        [Parameter(Mandatory=$true)][int]$EffectiveStop,
        [Parameter(Mandatory=$true)][int]$StopStep,
        [Parameter(Mandatory=$true)][int]$ChainTotalSteps,

        [Parameter(Mandatory=$true)][string]$HostType,
        [Parameter(Mandatory=$true)][string]$GuestKey,
        [Parameter(Mandatory=$true)][string]$VMName,

        [string]$SequenceName = '',

        [switch]$ShowSensitive
    )

    # Progress goes through Write-Information, never Write-Output: the caller
    # captures this function's return (`$result = Invoke-TestSequenceChain`), so a
    # Write-Output string would join the returned hashtable into an array (the
    # pipeline-pollution trap) -- `$result.ok` then survives only by member-
    # enumeration luck and the operator loses the progress lines into `$result`.
    Write-Information "Running steps $StartStep to $EffectiveStop..." -InformationAction Continue
    Write-Information "" -InformationAction Continue

    foreach ($entry in $ChainEntries) {
        $thisStart = $entry.globalStart
        $thisEnd   = $thisStart + $entry.stepCount - 1

        # Intersect this entry's global range with the requested range.
        $sliceStart = [Math]::Max($StartStep, $thisStart)
        $sliceEnd   = [Math]::Min($EffectiveStop, $thisEnd)
        if ($sliceStart -gt $sliceEnd) {
            Write-Information "Skipping (no steps in requested range): $($entry.name)" -InformationAction Continue
            continue
        }

        # Convert global -> local 1-based indices for this entry's window.
        $localStart = $sliceStart - $thisStart + 1
        $localEnd   = $sliceEnd   - $thisStart + 1

        Write-Information "" -InformationAction Continue
        Write-Information "--- $($entry.name): local steps $localStart-$localEnd of $($entry.stepCount) (global $sliceStart-$sliceEnd) ---" -InformationAction Continue

        # Run the entry's real file with the local step window. Invoke-Sequence
        # slices internally (Select-SequenceStepWindow), so there is no temp YAML
        # to write or sweep, and the perf row + SSH-variant resolution see the
        # real sequence path instead of a random temp name. -ShowSensitive
        # defaults OFF to match Invoke-TestRunner's masking; the operator opts in
        # for cleartext during local debugging.
        $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $entry.path -EffectiveVariables $ChainPlan.effectiveVariables -ShowSensitive:$ShowSensitive -StartStep $localStart -StopStep $localEnd
        if ($ok -ne $true) {
            Write-Warning "Sequence failed: $($entry.name)"
            Write-Information "" -InformationAction Continue
            Write-Information "To reproduce with full diagnostics:" -InformationAction Continue
            Write-Information "  pwsh test/Test-Sequence.ps1 -SequenceName `"$SequenceName`" -StartStep $sliceStart -logLevel Debug" -InformationAction Continue
            return @{ ok = $false; finishedVmName = $VMName }
        }

        # Pick up a mid-chain saveDiskSnapshot rename (test-X -> <id>) the engine
        # performed: Invoke-Sequence's $VMName update is scriptblock-local, so it
        # surfaces the final name via Get-SequenceFinishedVMName. Reading it here
        # -- the same mechanism the inner runner's Start-Guest* loops use -- keeps
        # subsequent entries on the renamed VM instead of the now-absent original.
        $finishedVmName = Get-SequenceFinishedVMName
        if ($finishedVmName -and $finishedVmName -ne $VMName) {
            Write-Information "VM renamed mid-chain: '$VMName' -> '$finishedVmName'; subsequent entries will target '$finishedVmName'." -InformationAction Continue
            $VMName = $finishedVmName
        }
    }

    Write-Information "" -InformationAction Continue
    if ($StopStep -ne 0 -and $EffectiveStop -lt $ChainTotalSteps) {
        Write-Information "Chain stopped after step $EffectiveStop of $ChainTotalSteps. VM '$VMName' left running for inspection." -InformationAction Continue
    } else {
        Write-Information "Chain completed successfully ($ChainTotalSteps step(s) across $($ChainPlan.fullChain.Count) sequence(s))." -InformationAction Continue
    }

    return @{ ok = $true; finishedVmName = $VMName }
}

Export-ModuleMember -Function Resolve-TestSequencePlan, Invoke-TestSequenceChain
