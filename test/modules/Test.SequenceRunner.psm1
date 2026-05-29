<#PSScriptInfo
.VERSION 2026.05.29
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

# Chain planning + chain execution lifted out of Test-Sequence.ps1.
# Two functions:
#
#   Resolve-TestSequencePlan  -- Build the $ChainEntries list (name,
#                                path, sequence, stepCount, globalStart)
#                                and detect a warm-path requiresSnapshot.
#                                Returns @{ chainEntries; chainPlan;
#                                effectiveUser; chainTotalSteps;
#                                requiredSnapshotId; warmPath }.
#
#   Invoke-TestSequenceChain  -- Run the requested step range across the
#                                planned chain. Returns @{ ok; finishedVmName }
#                                so the caller can update its outer
#                                $VMName when a mid-chain saveDiskSnapshot
#                                renamed the VM.
#
# Sized for unit-testable extraction: each function takes its inputs by
# parameter (no script-scope reads) so a future test harness can call
# them with fixture data. The host-driver-resolved $VMName and Invoke-
# Sequence's $ShowSensitive switch are passed through verbatim.

function Resolve-TestSequencePlan {
    <#
    .SYNOPSIS
        Build the chain plan + entries for Test-Sequence and detect a
        warm-path requiresSnapshot.
    .DESCRIPTION
        Mirror of the inline "Build chain plan" + "requiresSnapshot warm-
        path probe" blocks from Test-Sequence.ps1. Walks the named
        sequence's baseline chain via Resolve-NamedSequenceChain, reads
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
            Write-Output "Searched (no match):"
            foreach ($p in $searched) { Write-Output "  $p" }
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
        Write-Output "Chain: $($ChainPlan.fullChain -join ' -> ')"
    } else {
        Write-Output "Chain: $($ChainPlan.fullChain[0]) (no baseline prereqs declared)"
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
        $snapPresent = $false
        try {
            $snapPresent = [bool](Test-VMDiskSnapshot -VMName $requiredSnapshotId -Id $requiredSnapshotId)
        } catch {
            Write-Verbose "Test-VMDiskSnapshot threw ($($_.Exception.Message)); assuming cold path."
        }
        if ($snapPresent) {
            Write-Output "requiresSnapshot: snapshot '$requiredSnapshotId' present on persisted VM '$requiredSnapshotId' -- skipping baseline chain (warm path)."
            $warmPath = $true
            # Drop every prereq; keep only the top-level entry and rebase its
            # globalStart to 1 so -StartStep / -StopStep index into the
            # truncated step list naturally.
            $topLevelEntry.globalStart = 1
            $ChainEntries = New-Object System.Collections.Generic.List[object]
            [void]$ChainEntries.Add($topLevelEntry)
            $ChainTotalSteps = $topLevelEntry.stepCount
        } else {
            Write-Output "requiresSnapshot: snapshot '$requiredSnapshotId' not on host -- running full baseline chain (cold path; VM will be renamed to '$requiredSnapshotId' at saveDiskSnapshot)."
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
        Mirror of the inline "Run each chain entry" foreach block in
        Test-Sequence.ps1. For each chain entry, intersects its global
        step range with the operator's requested range, slices the
        entry's steps list, writes a temp YAML containing only the slice
        + the entry's other top-level keys (variables, requiresSnapshot,
        ...), and calls Invoke-Sequence with the chain plan's
        effectiveVariables. Detects mid-chain saveDiskSnapshot renames
        and returns the final VM name so the caller can update its
        outer $VMName.

        $tempFiles cleanup is the caller's responsibility -- the caller
        owns the finally{} that also stops the transcript.
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
        Initial VM name. Updated locally on mid-chain rename.
    .PARAMETER RequiredSnapshotId
        From Resolve-TestSequencePlan; used to detect mid-chain
        saveDiskSnapshot renames.
    .PARAMETER TempFiles
        Caller-owned IList<string> that this function appends slice
        temp-file paths to. The caller's finally{} sweeps the list.
    .PARAMETER ShowSensitive
        Forwarded to Invoke-Sequence verbatim.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$ChainEntries,

        # Resolve-NamedSequenceChain returns a [pscustomobject]; older
        # call sites typed this parameter as [hashtable] and never tripped
        # the coercion because the older filename-based GuestKey path
        # bailed out before this function was reached. [psobject] accepts
        # both shapes, and all access below is via `.` member access which
        # works equivalently for either.
        [Parameter(Mandatory=$true)]
        [psobject]$ChainPlan,

        [Parameter(Mandatory=$true)][int]$StartStep,
        [Parameter(Mandatory=$true)][int]$EffectiveStop,
        [Parameter(Mandatory=$true)][int]$StopStep,
        [Parameter(Mandatory=$true)][int]$ChainTotalSteps,

        [Parameter(Mandatory=$true)][string]$HostType,
        [Parameter(Mandatory=$true)][string]$GuestKey,
        [Parameter(Mandatory=$true)][string]$VMName,

        [string]$RequiredSnapshotId = $null,

        [Parameter(Mandatory=$true)]
        [System.Collections.IList]$TempFiles,

        [string]$SequenceName = '',

        [switch]$ShowSensitive
    )

    Write-Output "Running steps $StartStep to $EffectiveStop..."
    Write-Output ""

    foreach ($entry in $ChainEntries) {
        $thisStart = $entry.globalStart
        $thisEnd   = $thisStart + $entry.stepCount - 1

        # Intersect this entry's global range with the requested range.
        $sliceStart = [Math]::Max($StartStep, $thisStart)
        $sliceEnd   = [Math]::Min($EffectiveStop, $thisEnd)
        if ($sliceStart -gt $sliceEnd) {
            Write-Output "Skipping (no steps in requested range): $($entry.name)"
            continue
        }

        # Convert global -> local 1-based indices for this entry's slice.
        $localStart = $sliceStart - $thisStart + 1
        $localEnd   = $sliceEnd   - $thisStart + 1

        $allSteps   = @($entry.sequence.steps)
        $slicedSteps = $allSteps[($localStart - 1)..($localEnd - 1)]

        # Same top-level-keys-except-steps copy the original did; chain
        # entries are each their own sequence dictionary.
        $trimmedSequence = [ordered]@{}
        foreach ($key in $entry.sequence.Keys) {
            if ($key -ne 'steps') { $trimmedSequence[$key] = $entry.sequence[$key] }
        }
        $trimmedSequence['steps'] = $slicedSteps

        $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.yml'
        $trimmedSequence | ConvertTo-Yaml | Set-Content -Path $tempFile -Encoding UTF8
        [void]$TempFiles.Add($tempFile)

        Write-Output ""
        Write-Output "--- $($entry.name): local steps $localStart-$localEnd of $($entry.stepCount) (global $sliceStart-$sliceEnd) ---"

        # -ShowSensitive defaults OFF to match Invoke-TestRunner's masking;
        # the operator opts in with the switch when local debugging actually
        # needs the cleartext values rendered.
        $ok = Invoke-Sequence -HostType $HostType -GuestKey $GuestKey -VMName $VMName -SequencePath $tempFile -EffectiveVariables $ChainPlan.effectiveVariables -ShowSensitive:$ShowSensitive
        if ($ok -ne $true) {
            Write-Warning "Sequence failed: $($entry.name)"
            Write-Output ""
            Write-Output "To reproduce with full diagnostics:"
            Write-Output "  pwsh test/Test-Sequence.ps1 -SequenceName `"$SequenceName`" -StartStep $sliceStart -logLevel Debug"
            return @{ ok = $false; finishedVmName = $VMName }
        }

        # Detect a mid-chain saveDiskSnapshot rename. The engine updates
        # its internal $VMName when Save-VMDiskSnapshot succeeds (test-X
        # -> <id>), but this script's outer $VMName is passed by value
        # and is now stale. Without this swap the next entry would target
        # the old, now-absent VM. Only fires when requiresSnapshot was
        # declared, so non-snapshot chains keep their existing behavior.
        if ($RequiredSnapshotId -and $VMName -ne $RequiredSnapshotId) {
            if ((Get-VMState -VMName $VMName) -eq 'absent' -and
                (Get-VMState -VMName $RequiredSnapshotId) -ne 'absent') {
                Write-Output "VM renamed mid-chain: '$VMName' -> '$RequiredSnapshotId'; subsequent entries will target '$RequiredSnapshotId'."
                $VMName = $RequiredSnapshotId
            }
        }
    }

    Write-Output ""
    if ($StopStep -ne 0 -and $EffectiveStop -lt $ChainTotalSteps) {
        Write-Output "Chain stopped after step $EffectiveStop of $ChainTotalSteps. VM '$VMName' left running for inspection."
    } else {
        Write-Output "Chain completed successfully ($ChainTotalSteps step(s) across $($ChainPlan.fullChain.Count) sequence(s))."
    }

    return @{ ok = $true; finishedVmName = $VMName }
}

Export-ModuleMember -Function Resolve-TestSequencePlan, Invoke-TestSequenceChain
