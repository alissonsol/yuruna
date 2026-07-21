<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42cd8b7a-e6f5-4a23-9081-3b4c5d6e7fa6
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
         pid, cycleId, runId.
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
        if ($PSCmdlet.ShouldProcess($dir, 'Create snapshot-manifest directory')) {
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
        Justification = 'Reads global:__YurunaCycleId + __YurunaRunId for manifest provenance.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [string]$HostType = '',
        [hashtable]$Extra
    )
    $path = Get-SnapshotManifestPath -VMName $VMName -SnapshotId $SnapshotId
    if (-not $PSCmdlet.ShouldProcess($path, 'Write snapshot manifest')) { return $null }
    $manifest = [ordered]@{
        vmName       = [string]$VMName
        snapshotId   = [string]$SnapshotId
        hostType     = [string]$HostType
        hostName     = [string]([System.Net.Dns]::GetHostName())
        takenAtUtc   = (Get-Date).ToUniversalTime().ToString('o')
        writerPid    = $PID
        cycleId      = if ($global:__YurunaCycleId) { [string]$global:__YurunaCycleId } else { $null }
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
    if (-not $PSCmdlet.ShouldProcess($path, 'Remove snapshot manifest')) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $path)
}

Export-ModuleMember -Function `
    Get-SnapshotManifestDir, Get-SnapshotManifestPath, `
    Write-SnapshotManifest, Get-SnapshotManifest, `
    Test-SnapshotManifestMatch, Remove-SnapshotManifest
