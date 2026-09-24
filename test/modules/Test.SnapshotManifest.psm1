<#PSScriptInfo
.VERSION 2026.09.24
.GUID 421a4d8a-ef0d-4f12-ab3c-235c0e8c3732
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna snapshot manifest sidecar
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


<#
.SYNOPSIS
    Snapshot manifest sidecars. Co-located metadata + integrity check
    around the per-hypervisor `Save-VMDiskSnapshot` / `Restore-VMDiskSnapshot`
    primitives so a restore can refuse a snapshot it doesn't recognize.

.DESCRIPTION
    The `loadDiskSnapshot` and `recoverFromSnapshot` handlers run an
    existence check (Test-VMDiskSnapshot) that catches "the snapshot
    id doesn't exist on this VM" -- but not "this snapshot exists,
    but it was taken by a different runner / different VM definition /
    before a host-IO change that would make restore unsafe."

    The manifest sidecar closes the rest of the surface:

      1. saveDiskSnapshot writes a manifest at the moment the
         hypervisor confirms the save succeeded. Payload: vmName,
         snapshotId, takenAtUtc, hostName, platform (HostType),
         pid, cycleStartUtc, runId.
      2. loadDiskSnapshot / recoverFromSnapshot read the manifest
         before invoking the hypervisor restore. If the manifest is
         missing, vmName / snapshotId don't match, or the platform
         changed (e.g. snapshot taken on host.windows.hyper-v but
         restore attempt on host.ubuntu.kvm), the handler emits a
         `snapshot_manifest_mismatch` NDJSON event and refuses the
         restore -- the snapshot binary may still exist, but Yuruna
         no longer trusts it.

    Manifest lives at
    `<runtimeDir>/snapshots/<vmName>__<snapshotId>.manifest.json`,
    written atomically via the Write-YurunaStateFileJson helper.
    The subdirectory persists across cycles -- snapshots outlive
    the cycle that took them, so their manifests do too.

    Policy: a MISSING manifest does NOT auto-fail the restore --
    snapshots taken on older Yuruna builds won't have one, and the
    operator's expectation is "warn, don't abort" for pre-existing
    state. The restore handler logs a Write-Warning + emits a
    `snapshot_manifest_missing` NDJSON event and proceeds. A
    manifest that EXISTS but doesn't match the expected (vmName,
    snapshotId) IS a hard refuse: that's identity drift, not just
    a missing record.
#>

Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -DisableNameChecking -Global

function Get-SnapshotManifestDir {
    <#
    .SYNOPSIS
        Returns the directory under runtime where manifests live.
        Creates it on first use.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Wraps New-Item which is gated by ShouldProcess below.')]
    param()
    # $env:TEMP is Windows-only -- POSIX PowerShell never defines it, so on a
    # macos.utm / ubuntu.kvm host this fallback yields $null and Join-Path throws
    # on a null -Path, taking every manifest write, read, and restore-gate check
    # with it. [IO.Path]::GetTempPath() resolves on every platform.
    $base = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'snapshots'
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, (Format-YurunaOperatorMessage -Key 'runner.operator_243e5b6d3c10c824'))) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    return $dir
}

function Get-SnapshotManifestPath {
    <#
    .SYNOPSIS
        Returns the canonical manifest path for (VMName, SnapshotId).
    .DESCRIPTION
        Format: `<runtimeDir>/snapshots/<vmName>__<snapshotId>.manifest.json`.
        Double-underscore separator makes the file name regex-greppable
        without ambiguity (single VM name segments may contain '.', '-').
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId
    )
    return (Join-Path (Get-SnapshotManifestDir) "${VMName}__${SnapshotId}.manifest.json")
}

function Write-SnapshotManifest {
    <#
    .SYNOPSIS
        Persist a snapshot manifest sidecar right after a successful
        Save-VMDiskSnapshot. Atomic temp+rename via the state-file
        helper.
    .PARAMETER VMName
        The VM the snapshot was taken on.
    .PARAMETER SnapshotId
        Hypervisor-level snapshot id (Hyper-V checkpoint name, virsh
        snapshot name, UTM bundle name).
    .PARAMETER HostType
        Platform identifier (host.windows.hyper-v, host.macos.utm,
        host.ubuntu.kvm). Captured so a future cross-host restore
        attempt can detect the mismatch.
    .PARAMETER Extra
        Optional extra fields to merge into the manifest (e.g.
        cycleHostInfoSha from the cycle that took it).
    .OUTPUTS
        [string] absolute path of the manifest written. $null on failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads global:__YurunaCycleStartUtc + __YurunaRunId for manifest provenance.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$HostType = '',
        [hashtable]$Extra
    )
    $path = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_e296050a160cc903'))) { return $null }
    $manifest = [ordered]@{
        vmName       = [string]$VMName
        snapshotId   = [string]$SnapshotId
        hostType     = [string]$HostType
        hostName     = [string]([System.Net.Dns]::GetHostName())
        takenAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        writerPid    = $PID
        cycleStartUtc      = if ($global:__YurunaCycleStartUtc) { [string]$global:__YurunaCycleStartUtc } else { $null }
        runId        = if ($global:__YurunaRunId)   { [string]$global:__YurunaRunId }   else { $null }
        manifestVersion = 1
    }
    if ($Extra) {
        foreach ($k in $Extra.Keys) { $manifest[$k] = $Extra[$k] }
    }
    $ok = Write-YurunaStateFileJson -Path $path -InputObject $manifest -Confirm:$false
    if (-not $ok) { return $null }
    return $path
}

function Get-SnapshotManifest {
    <#
    .SYNOPSIS
        Read the manifest for (VMName, SnapshotId), or $null when
        the file is missing / unparseable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId
    )
    $path = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $raw = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return $null }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -is [System.Collections.IDictionary]) { return [hashtable]$obj }
        return $null
    } catch {
        Write-Verbose "Get-SnapshotManifest: parse failed at $path : $($_.Exception.Message)"
        return $null
    }
}

function Test-SnapshotManifestMatch {
    <#
    .SYNOPSIS
        Validate that a manifest matches the expected (VMName,
        SnapshotId, HostType) tuple. Returns a result hashtable with
        Status (`ok`, `missing`, `mismatch`) and Violations (array
        of strings for `mismatch`).
    .DESCRIPTION
        Three outcomes a caller should distinguish:

          - `ok`        manifest present + every field matches.
          - `missing`   no manifest file. Caller policy: log + proceed
                        (pre-existing snapshots from older builds).
          - `mismatch`  manifest present but at least one field differs.
                        Caller policy: REFUSE the restore -- identity
                        drift, not legacy state.

        HostType comparison is case-insensitive. A manifest written
        without HostType (early adopters) is treated as a missing
        field and skipped; only an actively-different HostType
        triggers a mismatch.
    .OUTPUTS
        [hashtable] @{ Status; ManifestPath; Manifest; Violations }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$HostType = ''
    )
    $manifestPath = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    $manifest = Get-SnapshotManifest -VMName $VMName -SnapshotId $SnapshotId
    if (-not $manifest) {
        return @{
            Status       = 'missing'
            ManifestPath = $manifestPath
            Manifest     = $null
            Violations   = @()
        }
    }
    $violations = @()
    if ($manifest.Contains('vmName') -and ([string]$manifest['vmName'] -ne [string]$VMName)) {
        $violations += "vmName mismatch (manifest='$($manifest['vmName'])', requested='$VMName')"
    }
    if ($manifest.Contains('snapshotId') -and ([string]$manifest['snapshotId'] -ne [string]$SnapshotId)) {
        $violations += "snapshotId mismatch (manifest='$($manifest['snapshotId'])', requested='$SnapshotId')"
    }
    if ($HostType -and $manifest.Contains('hostType') -and $manifest['hostType']) {
        if ([string]$manifest['hostType'] -ine [string]$HostType) {
            $violations += "hostType mismatch (manifest='$($manifest['hostType'])', current='$HostType')"
        }
    }
    return @{
        Status       = if ($violations.Count -eq 0) { 'ok' } else { 'mismatch' }
        ManifestPath = $manifestPath
        Manifest     = $manifest
        Violations   = $violations
    }
}

function Remove-SnapshotManifest {
    <#
    .SYNOPSIS
        Delete a snapshot's manifest. Called by a future
        Remove-VMDiskSnapshot path; today's only caller is a test
        fixture cleaning up. Returns $true when a file was removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId
    )
    $path = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_ba76b397e425c192'))) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $path)
}

# --- REGION: https://yuruna.link/428e4df6
function Get-SnapshotSourceIdentity {
    <#
    .SYNOPSIS
        Fingerprint declared baseline inputs and checkout revisions without storing credentials.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [System.Collections.IDictionary]$Variables = @{}
    )
    $root = [IO.Path]::GetFullPath($RepoRoot)
    $files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($pattern in @($Policy.sourceFiles)) {
        if (-not $pattern -or [IO.Path]::IsPathRooted($pattern) -or $pattern -match '(^|[/\\])\.\.([/\\]|$)') {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_054c6e454d434969')
        }
        $sourceFiles = @(Get-ChildItem -Path (Join-Path $root $pattern) -File -ErrorAction Stop)
        if ($sourceFiles.Count -eq 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_f3da34207d2a8685' -Arguments @{ pattern = "$pattern" }) }
        foreach ($file in $sourceFiles) {
            $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
            $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    if ($files.Count -eq 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_a038a1eea843a737') }
    $revisions = [ordered]@{}
    foreach ($name in @('framework', 'project')) {
        $directory = if ($name -eq 'framework') { $root } else { Join-Path $root 'project' }
        $revision = $null
        if ((Test-Path -LiteralPath (Join-Path $directory '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $value = & git -C $directory rev-parse --verify HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and "$value" -match '^[0-9a-f]{40,64}$') { $revision = [string]$value }
        }
        $revisions[$name] = $revision
    }
    $identity = [ordered]@{
        schema = 'yuruna.snapshot-source/v1'
        guestKey = $GuestKey
        username = [string]$Variables.username
        hostname = [string]$Variables.hostname
        memoryStartupBytes = [string]$Variables.memoryStartupBytes
        cores = [string]$Variables.cores
        exposeVirtualizationExtensions = [string]$Variables.exposeVirtualizationExtensions
        revisions = $revisions
        files = @($files.GetEnumerator() | ForEach-Object { [ordered]@{ path = $_.Key; sha256 = $_.Value } })
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($identity | ConvertTo-Json -Depth 8 -Compress))
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $identity.identitySha256 = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    return [hashtable]$identity
}

function Test-SnapshotReusePolicy {
    <#
    .SYNOPSIS
        Distinguish reusable, stale owned, and unrecognized snapshots before a restore or rebuild.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceIdentity,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $maximumAge = [double]$Policy.maxAgeHours
    if ([double]::IsNaN($maximumAge) -or [double]::IsInfinity($maximumAge) -or $maximumAge -le 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_9b97bf35e35de969')
    }
    $check = Test-SnapshotManifestMatch -VMName $VMName -SnapshotId $SnapshotId -HostType $HostType
    $m = $check.Manifest
    if ($check.Status -ne 'ok' -or -not $m -or $m.managedBaseline -ne $true -or
        $m.vmName -ne $VMName -or $m.snapshotId -ne $SnapshotId -or
        $m.hostType -ne $HostType -or $m.hostName -ne [Net.Dns]::GetHostName()) {
        return @{ Status = 'refused'; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_b4188041c1c0989b') }
    }
    # ConvertFrom-Json already turns the stored ISO-8601 text into a [datetime],
    # and casting that back to [string] renders it in the current culture
    # WITHOUT its UTC designator. Re-parsing that text reads it as local time,
    # which moves the baseline by the host's offset: on a machine west of UTC a
    # fresh baseline looks like it was taken in the future and is refused, while
    # an expired one looks young enough to reuse. Only a host actually on UTC
    # hides it, so take the typed value as the UTC instant it already is.
    $takenAtValue = $m.takenAtUtc
    $takenAt = [datetimeoffset]::MinValue
    $parsed = if ($takenAtValue -is [datetime]) {
        $takenAt = [datetimeoffset]::new([datetime]::SpecifyKind($takenAtValue, [DateTimeKind]::Utc))
        $true
    } else {
        [datetimeoffset]::TryParse([string]$takenAtValue, [cultureinfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal,
            [ref]$takenAt)
    }
    if (-not $parsed -or $takenAt.UtcDateTime -gt $NowUtc.AddMinutes(5)) {
        return @{ Status = 'refused'; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_00396d785ef635da') }
    }
    if (-not $m.sourceIdentity -or $m.sourceIdentity.identitySha256 -ne $SourceIdentity.identitySha256) {
        return @{ Status = 'stale'; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_f1b830d931bbb3a1') }
    }
    if (($NowUtc - $takenAt.UtcDateTime).TotalHours -ge $maximumAge) {
        return @{ Status = 'stale'; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_e0c7de4cb1e0c6c4') }
    }
    return @{ Status = 'reusable'; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_7c9da2bef57c6aa4') }
}

function Remove-StaleManagedSnapshot {
    <#
    .SYNOPSIS
        Remove an explicitly managed stale baseline so its resource chain can rebuild it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SourceIdentity
    )
    $check = Test-SnapshotReusePolicy -VMName $SnapshotId -SnapshotId $SnapshotId `
        -HostType $HostType -Policy $Policy -SourceIdentity $SourceIdentity
    if ($check.Status -ne 'stale' -or $Policy.rebuildOnMismatch -ne $true) { return $false }
    if (-not $PSCmdlet.ShouldProcess($SnapshotId, (Format-YurunaOperatorMessage -Key 'runner.operator_9dbd3892b869c8bd'))) { return $false }
    $state = Get-VMState -VMName $SnapshotId
    if ($state -notin @('stopped', 'absent')) {
        if (-not (Stop-VMForce -VMName $SnapshotId -Confirm:$false)) { return $false }
    }
    if ($state -ne 'absent' -and -not (Remove-VM -VMName $SnapshotId -Confirm:$false)) { return $false }
    if ((Get-VMState -VMName $SnapshotId) -ne 'absent') { return $false }
    $null = Remove-SnapshotManifest -VMName $SnapshotId -SnapshotId $SnapshotId -Confirm:$false
    return $true
}

Export-ModuleMember -Function `
    Get-SnapshotManifestDir, Get-SnapshotManifestPath, `
    Write-SnapshotManifest, Get-SnapshotManifest, `
    Test-SnapshotManifestMatch, Remove-SnapshotManifest, `
    Get-SnapshotSourceIdentity, Test-SnapshotReusePolicy, Remove-StaleManagedSnapshot
