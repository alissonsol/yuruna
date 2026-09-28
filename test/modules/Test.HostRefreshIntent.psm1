<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42d4e5f6-7a8b-49c0-8d1e-2f3a4b5c6d7e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh request intent lock
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
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1') -DisableNameChecking

# The private request journal for host refresh: who asked for a repair, with
# which immutable policy, what each attempt did, what it disrupted and still
# owes, and which request ids are closed for good.
#
#   * Everything lives under the private state root ($HOME/.yuruna/host-refresh),
#     which is outside every tree the status service serves; the public
#     progress file in the runtime directory is a projection and never
#     authoritative.
#   * One checksummed, generation-numbered record (Test.CriticalRecord) holds
#     the whole journal, and every read-modify-write happens under one short
#     admission lock. The lock order is the lifetime repair lock, then the
#     admission lock, and never the reverse: a worker claims under both, the
#     listener and the outer runner take only the admission lock.
#   * Age never evicts anything alive. Liveness is decided by process identity
#     (pid plus start time); an identity that cannot be read is unknown, and
#     unknown is treated as alive.
#   * A request that disrupted something keeps its obligations until they are
#     verified or explicitly disposed by a local operator; no verdict silently
#     discharges them.

$script:HostRefreshJournalName     = 'host-refresh.journal'
$script:HostRefreshJournalKind     = 'host-refresh.request-journal'
$script:HostRefreshJournalSchema   = 2
$script:HostRefreshJournalMaxBytes = 4194304
$script:HostRefreshLegacyName      = 'host-refresh.request.json'
$script:HostRefreshLegacyV1Name    = 'host-refresh.request.v1.json'
$script:HostRefreshLockName        = 'host-refresh.lock'
$script:HostRefreshAdmissionName   = 'host-refresh.admission.lock'
$script:HostRefreshWorkDirName     = 'work'
$script:HostRefreshGrantName       = 'automation-grant.record'
$script:HostRefreshGrantKind       = 'automation-grant'
$script:HostRefreshGrantCap        = 32
# An unclaimed click must not hold the host forever, but an interrupted claim
# keeps its obligations: only queued requests expire.
$script:HostRefreshQueuedLifetimeMs = [long]1800000
# Tombstones outlive the longest a remote proof for the same id can stay
# valid (300 s lifetime plus 60 s skew) many times over, so a replayed id is
# answered from its stored outcome instead of being recreated.
$script:HostRefreshTombstoneRetentionMs = [long]86400000
$script:HostRefreshTombstoneCap         = 512
$script:HostRefreshTerminalKeep         = 8
$script:HostRefreshMaxAttempts          = 3
$script:HostRefreshObservationCap       = 16
$script:HostRefreshIdentityToleranceMs  = [long]2000
# Private copy of the request-id shape Test.HostRefreshAuth exports: the spawn
# and admission paths must not depend on the authorization module, and a
# parity test pins the two patterns equal.
$script:HostRefreshRequestIdPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:HostRefreshGenerationPattern = '\A[0-9a-f]{32}\z'
# Rung names and orders, and the ceiling of each tier. Test.HostRefresh owns
# the ladder declaration; this copy only normalizes a policy's ceiling name,
# and a parity test keeps the two identical.
$script:HostRefreshRungOrder = [ordered]@{
    'probe' = 0; 'reclaim' = 1; 'start-if-stopped' = 2; 'restart-if-hung' = 3
    'restart-broker' = 4; 'reapply-settings' = 5; 'reinstall' = 6; 'reboot' = 7
}
$script:HostRefreshTierCeiling = @{ restart = 4; full = 6 }
$script:HostRefreshVerdictExitCode = @{
    'repaired' = 0; 'already-healthy' = 0; 'preview' = 0; 'disposed' = 0
    'refused' = 1; 'failed' = 1
    'partial' = 2; 'still-unresponsive' = 2; 'abandoned' = 2
}
$script:HostRefreshTerminalState = @('completed', 'refused', 'abandoned')
# Test seam: a scratch home directory for the private root. $HOME is fixed at
# process start, so an in-process test cannot redirect it any other way; the
# real root checks still run against the scratch directory.
$script:HostRefreshHomePath = $null

# --- REGION: Private helpers
function Get-HostRefreshClockValue {
    <#
    .SYNOPSIS
        The current UTC instant as Unix milliseconds plus its ISO-8601 text.
    .DESCRIPTION
        Unix milliseconds are the authoritative form every decision compares;
        the text is display only. An injected clock may return a DateTime or a
        DateTimeOffset; an unspecified DateTime kind is read as UTC so a test
        clock never shifts with the host's time zone.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([scriptblock]$UtcNow)
    $value = if ($UtcNow) { & $UtcNow } else { [DateTimeOffset]::UtcNow }
    if ($value -is [DateTime]) {
        $dt = [DateTime]$value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
        $value = [DateTimeOffset]::new($dt.ToUniversalTime())
    }
    $offset = [DateTimeOffset]$value
    [pscustomobject]@{ UnixMs = [long]$offset.ToUnixTimeMilliseconds(); Utc = $offset.UtcDateTime.ToString('o') }
}

function ConvertTo-HostRefreshUtcText {
    <#
    .SYNOPSIS
        ISO-8601 UTC text for a Unix-millisecond instant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][long]$UnixMs)
    return [DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs).UtcDateTime.ToString('o')
}

function ConvertTo-HostRefreshList {
    <#
    .SYNOPSIS
        A mutable list from a parsed JSON collection, dropping nulls.
    .DESCRIPTION
        A one-element JSON array can arrive as a bare element, and @($null)
        has one element; both would otherwise become phantom rows.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[object]], [object[]])]
    param([AllowNull()]$Value)
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Value) { return , $list }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [string]) { $list.Add($Value); return , $list }
    foreach ($item in $Value) { if ($null -ne $item) { $list.Add($item) } }
    return , $list
}

function ConvertTo-HostRefreshStringArray {
    <#
    .SYNOPSIS
        A string array from a parsed JSON value, dropping nulls and blanks.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()]$Value)
    $items = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Value) {
        if ($Value -is [string]) { if ($Value) { $items.Add($Value) } }
        else { foreach ($item in $Value) { if ($null -ne $item -and "$item" -ne '') { $items.Add("$item") } } }
    }
    return , [string[]]$items.ToArray()
}

function Test-HostRefreshRequestIdShape {
    <#
    .SYNOPSIS
        True for a canonical lowercase 8-4-4-4-12 request id.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$RequestId)
    return ([string]$RequestId) -cmatch $script:HostRefreshRequestIdPattern
}

function Get-HostRefreshProcessStartTime {
    <#
    .SYNOPSIS
        A process's start time in Unix milliseconds, or $null when unreadable.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        return [long][DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds()
    } catch {
        return $null
    }
}

function Get-HostRefreshProcessLiveness {
    <#
    .SYNOPSIS
        alive, dead or unknown for a recorded process identity, without
        launching anything.
    .DESCRIPTION
        A pid alone is never identity: a live process whose start time differs
        from the record by more than the tolerance is a recycled pid, so the
        recorded process is dead. A live pid whose start time cannot be read,
        or a record without a start time, is unknown -- and callers treat
        unknown as alive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$ProcessId,
        [AllowNull()]$StartTimeUnixMs
    )
    $processNumber = 0
    if ($null -eq $ProcessId -or -not [int]::TryParse("$ProcessId", [ref]$processNumber) -or $processNumber -le 0) { return 'unknown' }
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($processNumber)
    } catch [System.ArgumentException] {
        return 'dead'
    } catch {
        return 'unknown'
    }
    $live = $null
    try { $live = [long][DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds() } catch { $live = $null }
    $recorded = [long]0
    if ($null -eq $StartTimeUnixMs -or -not [long]::TryParse("$StartTimeUnixMs", [ref]$recorded) -or $recorded -le 0) { return 'unknown' }
    if ($null -eq $live) { return 'unknown' }
    if ([Math]::Abs($live - $recorded) -le $script:HostRefreshIdentityToleranceMs) { return 'alive' }
    return 'dead'
}

function Get-HostRefreshPrivateFile {
    <#
    .SYNOPSIS
        A leaf path under the private root (optionally in one subdirectory),
        or $null when the root cannot be secured or, with -NoCreate, is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$Subdirectory,
        [switch]$NoCreate
    )
    $arguments = @{ Name = $Name; NoCreate = [bool]$NoCreate }
    if ($Subdirectory) { $arguments.Subdirectory = $Subdirectory }
    if ($script:HostRefreshHomePath) { $arguments.HomePath = $script:HostRefreshHomePath }
    $resolved = Get-YurunaPrivateStatePath @arguments
    if ($resolved.Resolved) { return [string]$resolved.Path }
    Write-Verbose "Get-HostRefreshPrivateFile: '$Name' unavailable ($($resolved.Reason))."
    return $null
}

function Get-HostRefreshPolicyRecord {
    <#
    .SYNOPSIS
        Normalize a policy to the stored shape: tier, effective ceiling name,
        the two local switches and the two sorted selections.
    .DESCRIPTION
        The ceiling is stored as the effective rung name (a MaxRung above the
        tier clamps to the tier), so an omitted MaxRung and an explicit one
        equal to the tier ceiling are the same policy. Returns $null for a
        policy a non-local channel may not carry.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][string]$Channel
    )
    $source = if ($Policy) { $Policy } else { @{} }
    $tier = if ($source['tier']) { ([string]$source['tier']).ToLowerInvariant() } else { 'restart' }
    if (-not $script:HostRefreshTierCeiling.ContainsKey($tier)) { return $null }
    $ceiling = [int]$script:HostRefreshTierCeiling[$tier]
    $maxRung = [string]$source['maxRung']
    if ($maxRung) {
        if (-not $script:HostRefreshRungOrder.Contains($maxRung)) { return $null }
        $ceiling = [Math]::Min($ceiling, [int]$script:HostRefreshRungOrder[$maxRung])
    }
    $ceilingName = @($script:HostRefreshRungOrder.Keys | Where-Object { $script:HostRefreshRungOrder[$_] -eq $ceiling })[0]
    $sorted = {
        param($Value)
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($name in (ConvertTo-HostRefreshStringArray -Value $Value)) { if (-not $names.Contains($name)) { $names.Add($name) } }
        $array = $names.ToArray()
        [Array]::Sort($array, [StringComparer]::Ordinal)
        , [string[]]$array
    }
    $record = [ordered]@{
        tier                      = $tier
        maxRung                   = [string]$ceilingName
        force                     = [bool]$source['force']
        allowHardStop             = [bool]$source['allowHardStop']
        restoreServiceVmName      = (& $sorted $source['restoreServiceVmName'])
        leaveStoppedServiceVmName = (& $sorted $source['leaveStoppedServiceVmName'])
    }
    if ($Channel -ne 'local') {
        if ($record.tier -ne 'restart' -or $record.force -or $record.allowHardStop -or
            $record.restoreServiceVmName.Count -gt 0 -or $record.leaveStoppedServiceVmName.Count -gt 0) { return $null }
    }
    return $record
}

function Get-HostRefreshPolicyHash {
    <#
    .SYNOPSIS
        SHA-256 hex of the key-sorted, compressed JSON of a normalized policy.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Policy)
    $sortedPolicy = [ordered]@{}
    foreach ($key in @($Policy.Keys | Sort-Object { [string]$_ } -CaseSensitive)) { $sortedPolicy[[string]$key] = $Policy[$key] }
    $json = ConvertTo-Json -InputObject $sortedPolicy -Compress -Depth 4
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    return ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function New-HostRefreshJournalDocument {
    <#
    .SYNOPSIS
        An empty schema-2 journal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        schemaVersion = $script:HostRefreshJournalSchema
        writtenUtc    = $null
        owner         = $null
        requests      = [System.Collections.Generic.List[object]]::new()
        reservations  = [System.Collections.Generic.List[object]]::new()
        tombstones    = [System.Collections.Generic.List[object]]::new()
    }
}

function ConvertTo-HostRefreshJournal {
    <#
    .SYNOPSIS
        Normalize a parsed journal payload: every collection becomes a list,
        at every level the code later mutates.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)
    $journal = New-HostRefreshJournalDocument
    $journal.writtenUtc = $Payload['writtenUtc']
    if ($Payload['owner'] -is [System.Collections.IDictionary]) { $journal.owner = $Payload['owner'] }
    foreach ($request in (ConvertTo-HostRefreshList -Value $Payload['requests'])) {
        if ($request -isnot [System.Collections.IDictionary]) { continue }
        $request['attempts'] = ConvertTo-HostRefreshList -Value $request['attempts']
        foreach ($attempt in $request['attempts']) {
            if ($attempt -is [System.Collections.IDictionary]) {
                $attempt['reasonCodes'] = ConvertTo-HostRefreshStringArray -Value $attempt['reasonCodes']
                $attempt['rungs'] = [object[]](ConvertTo-HostRefreshList -Value $attempt['rungs']).ToArray()
            }
        }
        $request['obligations'] = ConvertTo-HostRefreshList -Value $request['obligations']
        $request['reasonCodes'] = ConvertTo-HostRefreshStringArray -Value $request['reasonCodes']
        if ($request['policy'] -is [System.Collections.IDictionary]) {
            $request['policy']['restoreServiceVmName'] = ConvertTo-HostRefreshStringArray -Value $request['policy']['restoreServiceVmName']
            $request['policy']['leaveStoppedServiceVmName'] = ConvertTo-HostRefreshStringArray -Value $request['policy']['leaveStoppedServiceVmName']
        }
        if ($request['recovery'] -is [System.Collections.IDictionary]) {
            $request['recovery']['observations'] = ConvertTo-HostRefreshList -Value $request['recovery']['observations']
        }
        $journal.requests.Add($request)
    }
    foreach ($reservation in (ConvertTo-HostRefreshList -Value $Payload['reservations'])) {
        if ($reservation -is [System.Collections.IDictionary]) { $journal.reservations.Add($reservation) }
    }
    foreach ($tombstone in (ConvertTo-HostRefreshList -Value $Payload['tombstones'])) {
        if ($tombstone -is [System.Collections.IDictionary]) { $journal.tombstones.Add($tombstone) }
    }
    return $journal
}

function Read-HostRefreshJournalCore {
    <#
    .SYNOPSIS
        Read and classify the journal record without any lock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$JournalPath)
    $result = [ordered]@{ Status = 'unreadable'; Journal = $null; Generation = [long]0; Reason = $null }
    $record = Read-YurunaCriticalRecord -Path $JournalPath -Kind $script:HostRefreshJournalKind -MaxBytes $script:HostRefreshJournalMaxBytes
    switch ($record.Status) {
        'ok' {
            $payload = $record.Payload
            $schema = 0
            if ($payload -is [System.Collections.IDictionary]) { [void][int]::TryParse("$($payload['schemaVersion'])", [ref]$schema) }
            if ($schema -gt $script:HostRefreshJournalSchema) {
                $result.Status = 'unknown-version'; $result.Reason = 'newer-schema'
            } elseif ($schema -ne $script:HostRefreshJournalSchema) {
                $result.Status = 'corrupt'; $result.Reason = 'schema-mismatch'
            } else {
                $result.Journal = ConvertTo-HostRefreshJournal -Payload $payload
                $result.Generation = [long]$record.Generation
                $result.Status = if ($record.Degraded) { 'recovered-previous' } else { 'ok' }
                $result.Reason = if ($record.Degraded) { [string]$record.CurrentReason } else { 'ok' }
            }
        }
        'missing' {
            $result.Status = 'absent'
            $legacy = Join-Path ([System.IO.Path]::GetDirectoryName($JournalPath)) $script:HostRefreshLegacyName
            $result.Reason = if ([System.IO.File]::Exists($legacy)) { 'legacy-unimported' } else { 'absent' }
        }
        'unsupported-version' { $result.Status = 'unknown-version'; $result.Reason = 'unsupported-version' }
        'corrupt' { $result.Status = 'corrupt'; $result.Reason = 'corrupt' }
        'kind-mismatch' { $result.Status = 'corrupt'; $result.Reason = 'kind-mismatch' }
        default { $result.Status = 'unreadable'; $result.Reason = [string]$record.Status }
    }
    return [pscustomobject]$result
}

function Save-HostRefreshJournal {
    <#
    .SYNOPSIS
        Write the journal as the next generation of its critical record.
    .DESCRIPTION
        The caller holds the admission lock and passes the generation it read.
        Committed $false means the change was not persisted and the operation
        it guards must not proceed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][long]$ExpectedGeneration,
        [Parameter(Mandatory)][string]$NowUtc
    )
    if (-not $PSCmdlet.ShouldProcess($JournalPath, (Format-YurunaOperatorMessage -Key 'runner.operator_ae404c37892f11d1'))) {
        return [pscustomobject]@{ Committed = $false; Durable = $false; Generation = $ExpectedGeneration; Reason = 'preview' }
    }
    $Journal.writtenUtc = $NowUtc
    $payload = [ordered]@{
        schemaVersion = $script:HostRefreshJournalSchema
        writtenUtc    = $Journal.writtenUtc
        owner         = $Journal.owner
        requests      = [object[]]@($Journal.requests)
        reservations  = [object[]]@($Journal.reservations)
        tombstones    = [object[]]@($Journal.tombstones)
    }
    $write = Write-YurunaCriticalRecord -Path $JournalPath -Kind $script:HostRefreshJournalKind -Payload $payload `
        -ExpectedGeneration $ExpectedGeneration -MaxBytes $script:HostRefreshJournalMaxBytes -Confirm:$false
    return [pscustomobject]@{
        Committed  = [bool]$write.Committed
        Durable    = ([bool]$write.Committed -and [bool]$write.FlushesConfirmed)
        Generation = [long]$write.Generation
        Reason     = [string]$write.Reason
    }
}

function Find-HostRefreshRequest {
    <#
    .SYNOPSIS
        The full request record for an id, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)][string]$RequestId)
    foreach ($request in $Journal.requests) {
        if ([string]::Equals([string]$request['requestId'], $RequestId, [StringComparison]::Ordinal)) { return $request }
    }
    return $null
}

function Find-HostRefreshTombstone {
    <#
    .SYNOPSIS
        The tombstone for an id, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)][string]$RequestId)
    foreach ($tombstone in $Journal.tombstones) {
        if ([string]::Equals([string]$tombstone['requestId'], $RequestId, [StringComparison]::Ordinal)) { return $tombstone }
    }
    return $null
}

function Get-HostRefreshLastAttempt {
    <#
    .SYNOPSIS
        The newest attempt of a request, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    $attempts = $Request['attempts']
    if ($null -eq $attempts -or $attempts.Count -eq 0) { return $null }
    return $attempts[$attempts.Count - 1]
}

function Get-HostRefreshArmedObligation {
    <#
    .SYNOPSIS
        Ids of the obligations still armed (disrupted, not yet verified or
        disposed).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    foreach ($obligation in @($Request['obligations'])) {
        if ($obligation -is [System.Collections.IDictionary] -and [string]$obligation['status'] -eq 'armed') { [string]$obligation['id'] }
    }
}

function Test-HostRefreshRequestBlocking {
    <#
    .SYNOPSIS
        True when a request keeps any other request (and a start-cycle) out:
        an unexpired queued request, a running or recovery-pending one, or an
        abandoned one that still owes an obligation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request, [Parameter(Mandatory)][long]$NowUnixMs)
    switch ([string]$Request['state']) {
        'queued' { return (-not (Test-HostRefreshQueuedExpired -Request $Request -NowUnixMs $NowUnixMs)) }
        'running' { return $true }
        'recovery-pending' { return $true }
        'abandoned' { return (@(Get-HostRefreshArmedObligation -Request $Request).Count -gt 0) }
        default { return $false }
    }
}

function Test-HostRefreshQueuedExpired {
    <#
    .SYNOPSIS
        True once an unclaimed queued request is past its lifetime. A clock
        behind the creation time counts as age zero.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request, [Parameter(Mandatory)][long]$NowUnixMs)
    $created = [long]0
    [void][long]::TryParse("$($Request['createdUnixMs'])", [ref]$created)
    if ($NowUnixMs -lt $created) { return $false }
    return (($NowUnixMs - $created) -ge $script:HostRefreshQueuedLifetimeMs)
}

function Get-HostRefreshBlockingRequest {
    <#
    .SYNOPSIS
        The one request that blocks new work, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)][long]$NowUnixMs)
    foreach ($request in $Journal.requests) {
        if (Test-HostRefreshRequestBlocking -Request $request -NowUnixMs $NowUnixMs) { return $request }
    }
    return $null
}

function Get-HostRefreshQueuedLaunchLiveness {
    <#
    .SYNOPSIS
        Whether a queued request's launch can still produce a worker: alive,
        dead or unknown.
    .DESCRIPTION
        A recorded launch failure is dead. With a started launch, the launcher
        and any recorded worker must both be positively dead. A Windows hop
        without a recorded worker identity is unknown, since the hop exits as
        soon as it starts that worker. With no launch recorded yet, the process that created the request must be positively
        dead (it was the one about to launch). Anything unreadable is unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    $launch = $Request['launch']
    if ($launch -isnot [System.Collections.IDictionary]) { return 'unknown' }
    switch ([string]$launch['outcome']) {
        'launch-failed' { return 'dead' }
        'started' {
            $states = @(
                (Get-HostRefreshProcessLiveness -ProcessId $launch['launcherPid'] -StartTimeUnixMs $launch['launcherStartTimeUnixMs'])
            )
            if ($launch['workerPid']) {
                $states += (Get-HostRefreshProcessLiveness -ProcessId $launch['workerPid'] -StartTimeUnixMs $launch['workerStartTimeUnixMs'])
            }
            if ($states -contains 'alive') { return 'alive' }
            if ($states -contains 'unknown') { return 'unknown' }
            # A dead Windows hop says nothing about the child it detached.
            # Older records carry no platform; their journal stays on this host.
            if (-not $launch['workerPid'] -and
                ($launch['platform'] -eq 'Windows' -or (-not $launch['platform'] -and $IsWindows))) {
                return 'unknown'
            }
            return 'dead'
        }
        default {
            if (-not $launch['requesterPid']) { return 'unknown' }
            return (Get-HostRefreshProcessLiveness -ProcessId $launch['requesterPid'] -StartTimeUnixMs $launch['requesterStartTimeUnixMs'])
        }
    }
}

function Get-HostRefreshReservationLiveness {
    <#
    .SYNOPSIS
        Whether a start-cycle reservation still has a live owner: alive, dead
        or unknown. Identity only; age never clears a reservation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Reservation)
    $worker = $Reservation['worker']
    if ([string]$Reservation['state'] -eq 'running' -and $worker -is [System.Collections.IDictionary]) {
        return (Get-HostRefreshProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs'])
    }
    return (Get-HostRefreshQueuedLaunchLiveness -Request $Reservation)
}

function Set-HostRefreshRequestTerminal {
    <#
    .SYNOPSIS
        Move a request to a terminal state, record its tombstone and keep only
        the newest full terminal records.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory journal only; the caller persists it under its own ShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Request,
        [Parameter(Mandatory)][ValidateSet('completed', 'refused', 'abandoned')][string]$State,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)]$Clock
    )
    $Request['state'] = $State
    $Request['verdict'] = $Verdict
    $Request['terminalUtc'] = $Clock.Utc
    $Request['terminalUnixMs'] = $Clock.UnixMs
    $retainUntil = [long]$Clock.UnixMs + $script:HostRefreshTombstoneRetentionMs
    for ($i = $Journal.tombstones.Count - 1; $i -ge 0; $i--) {
        if ([string]$Journal.tombstones[$i]['requestId'] -ceq [string]$Request['requestId']) { $Journal.tombstones.RemoveAt($i) }
    }
    $Journal.tombstones.Add([ordered]@{
            requestId         = [string]$Request['requestId']
            state             = $State
            verdict           = $Verdict
            policyHash        = [string]$Request['policyHash']
            terminalUtc       = $Clock.Utc
            terminalUnixMs    = $Clock.UnixMs
            retainUntilUtc    = (ConvertTo-HostRefreshUtcText -UnixMs $retainUntil)
            retainUntilUnixMs = $retainUntil
        })
    Limit-HostRefreshTerminalRecord -Journal $Journal
}

function Limit-HostRefreshTerminalRecord {
    <#
    .SYNOPSIS
        Keep the full records of only the newest terminal requests; their
        tombstones remain.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Journal)
    $terminal = @($Journal.requests | Where-Object {
            [string]$_['state'] -in $script:HostRefreshTerminalState -and @(Get-HostRefreshArmedObligation -Request $_).Count -eq 0
        } | Sort-Object { [long]$_['terminalUnixMs'] } -Descending)
    if ($terminal.Count -le $script:HostRefreshTerminalKeep) { return }
    foreach ($old in $terminal[$script:HostRefreshTerminalKeep..($terminal.Count - 1)]) { [void]$Journal.requests.Remove($old) }
}

function Update-HostRefreshJournalHousekeeping {
    <#
    .SYNOPSIS
        Expire unclaimed queued requests, prune expired tombstones and clear
        start-cycle reservations whose owner is positively dead.
    .DESCRIPTION
        Runs inside every locked transaction. A clock behind a record's time
        never expires or prunes it. Returns $true when anything changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory journal only; the caller persists it under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)]$Clock)
    $changed = $false
    foreach ($request in @($Journal.requests)) {
        if ([string]$request['state'] -eq 'queued' -and (Test-HostRefreshQueuedExpired -Request $request -NowUnixMs $Clock.UnixMs)) {
            $request['reasonCodes'] = [string[]]@('request-expired')
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict 'refused' -Clock $Clock
            $changed = $true
        }
    }
    for ($i = $Journal.tombstones.Count - 1; $i -ge 0; $i--) {
        $tombstone = $Journal.tombstones[$i]
        $terminalAt = [long]0; $retainUntil = [long]0
        [void][long]::TryParse("$($tombstone['terminalUnixMs'])", [ref]$terminalAt)
        [void][long]::TryParse("$($tombstone['retainUntilUnixMs'])", [ref]$retainUntil)
        if ($Clock.UnixMs -ge $terminalAt -and $retainUntil -gt 0 -and $Clock.UnixMs -gt $retainUntil) {
            $Journal.tombstones.RemoveAt($i)
            $changed = $true
        }
    }
    for ($i = $Journal.reservations.Count - 1; $i -ge 0; $i--) {
        if ((Get-HostRefreshReservationLiveness -Reservation $Journal.reservations[$i]) -eq 'dead') {
            $Journal.reservations.RemoveAt($i)
            $changed = $true
        }
    }
    return $changed
}

function Import-HostRefreshLegacyRequest {
    <#
    .SYNOPSIS
        Import a pre-journal request file as a tombstone.
    .DESCRIPTION
        The earlier probe-and-report entry point never mutated anything, so
        its one request is closed as completed with its stored verdict. The
        file is renamed after the journal commits, never deleted. Returns the
        rename to perform, or $null when there is no legacy file.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory journal only; the caller persists it and renames the file under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)][string]$JournalPath, [Parameter(Mandatory)]$Clock)
    $directory = [System.IO.Path]::GetDirectoryName($JournalPath)
    $legacy = Join-Path $directory $script:HostRefreshLegacyName
    if (-not [System.IO.File]::Exists($legacy)) { return $null }
    if ([System.IO.FileInfo]::new($legacy).LinkTarget) { return $null }
    $record = $null
    try {
        $info = [System.IO.FileInfo]::new($legacy)
        if ($info.Length -le 1048576) {
            $record = [System.IO.File]::ReadAllText($legacy) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
    } catch {
        Write-Verbose "Import-HostRefreshLegacyRequest: '$legacy' unreadable: $($_.Exception.Message)"
        $record = $null
    }
    if ($record -is [System.Collections.IDictionary] -and $record['RequestId']) {
        $requestId = ([string]$record['RequestId']).ToLowerInvariant()
        $policyText = if ($record['Policy']) { ConvertTo-Json -InputObject $record['Policy'] -Compress -Depth 4 } else { '{}' }
        $policyHash = ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.UTF8Encoding]::new($false).GetBytes($policyText)))).ToLowerInvariant()
        if ($null -eq (Find-HostRefreshTombstone -Journal $Journal -RequestId $requestId)) {
            $retainUntil = [long]$Clock.UnixMs + $script:HostRefreshTombstoneRetentionMs
            $verdict = if ($record['Verdict']) { [string]$record['Verdict'] } else { 'partial' }
            $Journal.tombstones.Add([ordered]@{
                    requestId         = $requestId
                    state             = 'completed'
                    verdict           = $verdict
                    policyHash        = $policyHash
                    terminalUtc       = $Clock.Utc
                    terminalUnixMs    = $Clock.UnixMs
                    retainUntilUtc    = (ConvertTo-HostRefreshUtcText -UnixMs $retainUntil)
                    retainUntilUnixMs = $retainUntil
                    legacy            = $true
                })
        }
    }
    $target = Join-Path $directory $script:HostRefreshLegacyV1Name
    if ([System.IO.File]::Exists($target)) { $target = Join-Path $directory ("host-refresh.request.v1.{0}.json" -f $Clock.UnixMs) }
    return [pscustomobject]@{ Source = $legacy; Target = $target }
}

function Invoke-HostRefreshJournalTransaction {
    <#
    .SYNOPSIS
        Run one read-modify-write of the journal under the admission lock.
    .DESCRIPTION
        Takes the admission lock (or validates a lock the caller already
        holds), reads the journal, imports a legacy request file, runs the
        housekeeping sweep, then invokes Body with the journal and the clock.
        Body is param($Journal, $Clock, $Arguments) and returns
        @{ Changed = [bool]; Result = <record> }; it reads its inputs only
        from Arguments, never from the caller's scope. A changed journal is
        written as the next generation; a write that does not commit sets
        Committed $false on the returned envelope.
    .OUTPUTS
        [pscustomobject] @{ Ran; Reason; ReadStatus; Committed; Durable; Result }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [hashtable]$Arguments = @{},
        [AllowNull()]$AdmissionLock,
        [ValidateRange(0, 600000)][int]$AdmissionWaitMilliseconds = 5000,
        [scriptblock]$UtcNow
    )
    $txEnvelope = [ordered]@{ Ran = $false; Reason = $null; ReadStatus = $null; Committed = $false; Durable = $false; Result = $null }
    $txJournalPath = Get-HostRefreshPrivateFile -Name $script:HostRefreshJournalName
    $txLockPath = Get-HostRefreshPrivateFile -Name $script:HostRefreshAdmissionName
    if (-not $txJournalPath -or -not $txLockPath) { $txEnvelope.Reason = 'private-root-unavailable'; return [pscustomobject]$txEnvelope }
    $txOwnLock = $null
    if ($null -ne $AdmissionLock) {
        if (-not (Test-YurunaSingleFlightLockOwned -Lock $AdmissionLock -Path $txLockPath)) {
            $txEnvelope.Reason = 'admission-lock-not-held'
            return [pscustomobject]$txEnvelope
        }
    } else {
        $txOwnLock = Enter-YurunaSingleFlightLock -Path $txLockPath -WaitMilliseconds $AdmissionWaitMilliseconds `
            -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-refresh-admission' }
        if (-not $txOwnLock.Held) {
            $txEnvelope.Reason = if ($txOwnLock.Reason -eq 'held-elsewhere') { 'admission-busy' } else { "admission-lock-$($txOwnLock.Reason)" }
            return [pscustomobject]$txEnvelope
        }
    }
    try {
        $txClock = Get-HostRefreshClockValue -UtcNow $UtcNow
        $txRead = Read-HostRefreshJournalCore -JournalPath $txJournalPath
        $txEnvelope.ReadStatus = $txRead.Status
        if ($txRead.Status -eq 'absent') {
            $txJournal = New-HostRefreshJournalDocument
            $txGeneration = [long]0
        } elseif ($txRead.Status -in @('ok', 'recovered-previous')) {
            $txJournal = $txRead.Journal
            $txGeneration = [long]$txRead.Generation
        } else {
            $txEnvelope.Reason = "journal-$($txRead.Status)"
            return [pscustomobject]$txEnvelope
        }
        $txRename = Import-HostRefreshLegacyRequest -Journal $txJournal -JournalPath $txJournalPath -Clock $txClock
        $txHousekeeping = Update-HostRefreshJournalHousekeeping -Journal $txJournal -Clock $txClock
        $txOutcome = & $Body $txJournal $txClock $Arguments
        $txEnvelope.Ran = $true
        $txEnvelope.Result = $txOutcome.Result
        $txChanged = [bool]$txOutcome.Changed -or $txHousekeeping -or ($null -ne $txRename)
        if ($txChanged) {
            $txSave = Save-HostRefreshJournal -JournalPath $txJournalPath -Journal $txJournal -ExpectedGeneration $txGeneration -NowUtc $txClock.Utc -Confirm:$false
            $txEnvelope.Committed = $txSave.Committed
            $txEnvelope.Durable = $txSave.Durable
            if (-not $txSave.Committed) {
                $txEnvelope.Reason = "journal-write-$($txSave.Reason)"
            } elseif ($txRename) {
                try {
                    [System.IO.File]::Move($txRename.Source, $txRename.Target, $false)
                } catch {
                    Write-Verbose "Invoke-HostRefreshJournalTransaction: legacy rename failed: $($_.Exception.Message)"
                }
            }
        } else {
            $txEnvelope.Committed = $true
            $txEnvelope.Durable = $true
        }
        if (-not $txEnvelope.Reason) { $txEnvelope.Reason = 'ok' }
        return [pscustomobject]$txEnvelope
    } finally {
        if ($null -ne $txOwnLock) { Exit-YurunaSingleFlightLock -Lock $txOwnLock }
    }
}

function New-HostRefreshAttemptRecord {
    <#
    .SYNOPSIS
        One attempt entry for the journal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Worker,
        [Parameter(Mandatory)]$Clock
    )
    return [ordered]@{
        attempt        = $Attempt
        generation     = [Guid]::NewGuid().ToString('N')
        mode           = $Mode
        worker         = [ordered]@{
            pid             = $Worker['pid']
            startTimeUnixMs = $Worker['startTimeUnixMs']
            ownerId         = $Worker['ownerId']
            parent          = $Worker['parent']
        }
        budget         = if ($Worker['budget'] -is [System.Collections.IDictionary]) { $Worker['budget'] } else { $null }
        claimedUtc     = $Clock.Utc
        claimedUnixMs  = $Clock.UnixMs
        finishedUtc    = $null
        verdict        = $null
        exitCode       = $null
        mutated        = $false
        reasonCodes    = [string[]]@()
        rungs          = [object[]]@()
        finalProbe     = $null
        gateGeneration = $null
        runnerReadiness = $null
        handoff        = $null
    }
}

function New-HostRefreshRequestRecord {
    <#
    .SYNOPSIS
        A new request entry for the journal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk changes.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Channel,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Policy,
        [AllowNull()][System.Collections.IDictionary]$Context,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)]$Clock
    )
    $contextRecord = [ordered]@{ configPath = $null; callerOuter = $null; trigger = $null }
    if ($Context) {
        if ($Context['configPath']) { $contextRecord.configPath = [string]$Context['configPath'] }
        foreach ($name in @('callerOuter', 'trigger')) {
            if ($Context[$name] -is [System.Collections.IDictionary]) { $contextRecord[$name] = $Context[$name] }
        }
    }
    return [ordered]@{
        requestId     = $RequestId
        channel       = $Channel
        runtimeDir    = $RuntimeDir
        hostType      = $HostType
        createdUtc    = $Clock.Utc
        createdUnixMs = $Clock.UnixMs
        expiresUnixMs = [long]$Clock.UnixMs + $script:HostRefreshQueuedLifetimeMs
        policy        = $Policy
        policyHash    = (Get-HostRefreshPolicyHash -Policy $Policy)
        context       = $contextRecord
        state         = $State
        attempt       = 0
        launch        = $null
        attempts      = [System.Collections.Generic.List[object]]::new()
        recovery      = $null
        obligations   = [System.Collections.Generic.List[object]]::new()
        callerAck     = $null
        verdict       = $null
        operatorAction = $null
        reasonCodes   = [string[]]@()
        terminalUtc   = $null
        terminalUnixMs = $null
    }
}

function Get-HostRefreshOwnProcess {
    <#
    .SYNOPSIS
        This process's identity: pid and start time.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{ pid = $PID; startTimeUnixMs = (Get-HostRefreshProcessStartTime -ProcessId $PID) }
}

function Test-HostRefreshSameRuntime {
    <#
    .SYNOPSIS
        True when two runtime directory spellings name the same directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    if (-not $Left -or -not $Right) { return $false }
    $a = Resolve-YurunaCanonicalPath -Path $Left
    $b = Resolve-YurunaCanonicalPath -Path $Right
    $leftPath = if ($a.Resolved) { $a.Path } else { [System.IO.Path]::GetFullPath($Left) }
    $rightPath = if ($b.Resolved) { $b.Path } else { [System.IO.Path]::GetFullPath($Right) }
    $comparison = if ($IsLinux) { [StringComparison]::Ordinal } else { [StringComparison]::OrdinalIgnoreCase }
    return [string]::Equals($leftPath.TrimEnd('/', '\'), $rightPath.TrimEnd('/', '\'), $comparison)
}

function Get-HostRefreshGateView {
    <#
    .SYNOPSIS
        The runner refresh gate as admission needs it, resolved by name.
    .DESCRIPTION
        The gate lives in the runner-protocol module. When its reader is not
        loaded, admission cannot tell whether a handoff or a crashed repair
        still holds the runner, so it answers unavailable rather than guess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RuntimeDir)
    $reader = Get-Command -Name 'Get-YurunaRefreshGateState' -CommandType Function -ErrorAction SilentlyContinue
    if (-not $reader) { return [pscustomobject]@{ Known = $false; Open = $false; State = 'unknown'; RequestId = $null; Reason = 'gate-reader-missing' } }
    try {
        $arguments = @{}
        if ($RuntimeDir) { $arguments.RuntimeDir = $RuntimeDir }
        $gate = & $reader @arguments
        $state = [string]$gate.State
        return [pscustomobject]@{
            Known = ($state -ne 'unknown'); Open = ($state -eq 'open'); State = $state
            RequestId = [string]$gate.RequestId; Reason = [string]$gate.Reason
        }
    } catch {
        Write-Verbose "Get-HostRefreshGateView: gate read failed: $($_.Exception.Message)"
        return [pscustomobject]@{ Known = $false; Open = $false; State = 'unknown'; RequestId = $null; Reason = 'gate-read-failed' }
    }
}

function Resolve-HostRefreshAdmissionDecision {
    <#
    .SYNOPSIS
        The pure admission decision over a journal already read under the
        admission lock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Channel,
        [AllowNull()][System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)]$Clock
    )
    $decision = [ordered]@{
        Decision = 'unavailable'; RequestId = $RequestId; ActiveRequestId = $null; ActiveKind = ''
        State = $null; Verdict = $null; Attempt = 0; Ceiling = $null; Reason = $null; Action = 'none'
    }
    if ($null -eq $Policy) { $decision.Reason = 'policy-invalid'; return [pscustomobject]$decision }
    $decision.Ceiling = [string]$Policy['maxRung']
    $policyHash = Get-HostRefreshPolicyHash -Policy $Policy
    if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir'] -and
        -not (Test-HostRefreshSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right $RuntimeDir)) {
        $decision.Reason = 'runtime-owner-mismatch'
        return [pscustomobject]$decision
    }
    $existing = Find-HostRefreshRequest -Journal $Journal -RequestId $RequestId
    if ($existing) {
        $decision.State = [string]$existing['state']
        $decision.Verdict = $existing['verdict']
        $decision.Attempt = [int]$existing['attempt']
        $decision.Ceiling = [string]$existing['policy']['maxRung']
        # Channel and host are as immutable as the policy: the same id arriving
        # another way is a different request, never a replay.
        if ([string]$existing['policyHash'] -ne $policyHash -or [string]$existing['channel'] -ne $Channel -or
            [string]$existing['hostType'] -ne $HostType) {
            $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch'; return [pscustomobject]$decision
        }
        switch ([string]$existing['state']) {
            'completed' { $decision.Decision = 'completed'; $decision.Reason = 'completed' }
            'refused' { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
            'abandoned' { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
            'recovery-pending' { $decision.Decision = 'spawn'; $decision.Reason = 'recovery-pending'; $decision.Action = 'relaunch' }
            'queued' {
                $liveness = Get-HostRefreshQueuedLaunchLiveness -Request $existing
                if ($liveness -eq 'dead') { $decision.Decision = 'spawn'; $decision.Reason = 'launch-not-running'; $decision.Action = 'relaunch' }
                else { $decision.Decision = 'already-claimed'; $decision.Reason = "launcher-$liveness" }
            }
            'running' {
                $last = Get-HostRefreshLastAttempt -Request $existing
                $worker = if ($last) { $last['worker'] } else { $null }
                $liveness = if ($worker -is [System.Collections.IDictionary]) { Get-HostRefreshProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs'] } else { 'unknown' }
                if ($liveness -eq 'dead') { $decision.Decision = 'spawn'; $decision.Reason = 'worker-dead'; $decision.Action = 'relaunch' }
                else { $decision.Decision = 'already-claimed'; $decision.Reason = "worker-$liveness" }
            }
            default { $decision.Reason = 'state-unknown' }
        }
        return [pscustomobject]$decision
    }
    $tombstone = Find-HostRefreshTombstone -Journal $Journal -RequestId $RequestId
    if ($tombstone) {
        $decision.State = [string]$tombstone['state']
        $decision.Verdict = $tombstone['verdict']
        if ([string]$tombstone['policyHash'] -ne $policyHash) { $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch' }
        elseif ([string]$tombstone['state'] -eq 'completed') { $decision.Decision = 'completed'; $decision.Reason = 'completed' }
        else { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
        return [pscustomobject]$decision
    }
    foreach ($reservation in $Journal.reservations) {
        $decision.Decision = 'busy'; $decision.ActiveKind = 'start-cycle'
        $decision.ActiveRequestId = [string]$reservation['operationId']; $decision.Reason = 'start-cycle-active'
        return [pscustomobject]$decision
    }
    $blocking = Get-HostRefreshBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
    if ($blocking) {
        $decision.Decision = 'busy'; $decision.ActiveKind = 'host-refresh'
        $decision.ActiveRequestId = [string]$blocking['requestId']; $decision.Reason = 'host-refresh-active'
        $decision.State = [string]$blocking['state']
        return [pscustomobject]$decision
    }
    $gate = Get-HostRefreshGateView -RuntimeDir $RuntimeDir
    if (-not $gate.Known) { $decision.Reason = $gate.Reason; if (-not $decision.Reason) { $decision.Reason = 'gate-unknown' }; return [pscustomobject]$decision }
    if (-not $gate.Open) {
        $decision.Decision = 'busy'; $decision.ActiveKind = 'host-refresh'
        $decision.ActiveRequestId = $gate.RequestId; $decision.Reason = "gate-$($gate.State)"
        return [pscustomobject]$decision
    }
    if ($Journal.tombstones.Count -ge $script:HostRefreshTombstoneCap) { $decision.Reason = 'journal-full'; return [pscustomobject]$decision }
    $decision.Decision = 'spawn'; $decision.Reason = 'new-request'; $decision.Action = 'create'
    return [pscustomobject]$decision
}

function ConvertTo-HostRefreshAdmissionRecord {
    <#
    .SYNOPSIS
        The public admission record (without the internal action field).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Decision)
    [pscustomobject][ordered]@{
        Decision        = [string]$Decision.Decision
        RequestId       = [string]$Decision.RequestId
        ActiveRequestId = $Decision.ActiveRequestId
        ActiveKind      = [string]$Decision.ActiveKind
        State           = $Decision.State
        Verdict         = $Decision.Verdict
        Attempt         = [int]$Decision.Attempt
        Ceiling         = $Decision.Ceiling
        Reason          = [string]$Decision.Reason
    }
}

# --- REGION: Public: paths and ids
function Get-HostRefreshPrivateRoot {
    <#
    .SYNOPSIS
        The private state root record every refresh channel uses.
    .DESCRIPTION
        A thin pass-through to Get-YurunaPrivateStateRoot, so every caller of
        this area resolves the same root and honors the same checks.
    .PARAMETER NoCreate
        Observe only; nothing is created or re-moded.
    .PARAMETER VerifyHome
        Compare $HOME with the account database's home directory.
    .PARAMETER ServedRoot
        Directories an HTTP server exposes; the root must be outside them.
    .OUTPUTS
        [pscustomobject] the Get-YurunaPrivateStateRoot record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([switch]$NoCreate, [switch]$VerifyHome, [string[]]$ServedRoot)
    $arguments = @{ NoCreate = [bool]$NoCreate; VerifyHome = [bool]$VerifyHome }
    if ($PSBoundParameters.ContainsKey('ServedRoot')) { $arguments.ServedRoot = $ServedRoot }
    if ($script:HostRefreshHomePath) { $arguments.HomePath = $script:HostRefreshHomePath }
    return (Get-YurunaPrivateStateRoot @arguments)
}

function Get-YurunaHostRefreshRequestPath {
    <#
    .SYNOPSIS
        The private request journal path under the private state root.
    .PARAMETER NoCreate
        Observe only: $null when the root does not exist yet.
    .OUTPUTS
        [string] or $null when the root cannot be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    return (Get-HostRefreshPrivateFile -Name $script:HostRefreshJournalName -NoCreate:$NoCreate)
}

function Get-YurunaHostRefreshLockPath {
    <#
    .SYNOPSIS
        The lifetime repair lock path under the private state root.
    .PARAMETER NoCreate
        Observe only: $null when the root does not exist yet.
    .OUTPUTS
        [string] or $null when the root cannot be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    return (Get-HostRefreshPrivateFile -Name $script:HostRefreshLockName -NoCreate:$NoCreate)
}

function Get-YurunaHostRefreshAdmissionLockPath {
    <#
    .SYNOPSIS
        The short admission lock path under the private state root.
    .DESCRIPTION
        Serializes every read-modify-write of the request journal. Held for
        milliseconds, never while waiting for a longer-lived lock.
    .PARAMETER NoCreate
        Observe only: $null when the root does not exist yet.
    .OUTPUTS
        [string] or $null when the root cannot be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    return (Get-HostRefreshPrivateFile -Name $script:HostRefreshAdmissionName -NoCreate:$NoCreate)
}

function Get-HostRefreshPrivateWorkDir {
    <#
    .SYNOPSIS
        The private directory for worker transcripts, handshakes and the
        stdin sentinel.
    .DESCRIPTION
        Lives under the private root, never in the served runtime or log
        directories, so transcripts are never published.
    .PARAMETER NoCreate
        Observe only: $null when the directory does not exist yet.
    .OUTPUTS
        [string] or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    $leaf = Get-HostRefreshPrivateFile -Name 'stdin.empty' -Subdirectory $script:HostRefreshWorkDirName -NoCreate:$NoCreate
    if (-not $leaf) { return $null }
    return [System.IO.Path]::GetDirectoryName($leaf)
}

function New-YurunaHostRefreshRequestId {
    <#
    .SYNOPSIS
        A fresh canonical request identity.
    .DESCRIPTION
        One spelling on every channel -- lowercase 8-4-4-4-12 -- so a retry of
        the same request can never become a second request.
    .OUTPUTS
        [string]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Generates an in-memory value only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [Guid]::NewGuid().ToString('D').ToLowerInvariant()
}

# --- REGION: Public: lock-free reads
function Read-HostRefreshJournal {
    <#
    .SYNOPSIS
        Lock-free read of the request journal.
    .DESCRIPTION
        A reader never mutates: a legacy request file with no journal reads as
        absent with Reason legacy-unimported; it is imported by the next
        locked write.
    .PARAMETER JournalPath
        Defaults to the private journal path (never creating the root).
    .OUTPUTS
        [pscustomobject] @{ Status ok|absent|recovered-previous|corrupt|
        unknown-version|unreadable; Journal; Generation; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$JournalPath)
    if (-not $JournalPath) {
        $root = Get-HostRefreshPrivateRoot -NoCreate
        if (-not $root.Resolved) {
            $status = if ($root.Reason -eq 'absent') { 'absent' } else { 'unreadable' }
            return [pscustomobject]@{ Status = $status; Journal = $null; Generation = [long]0; Reason = [string]$root.Reason }
        }
        $JournalPath = Join-Path $root.Path $script:HostRefreshJournalName
    }
    return (Read-HostRefreshJournalCore -JournalPath $JournalPath)
}

function Read-YurunaHostRefreshRequest {
    <#
    .SYNOPSIS
        One request's full record, lock-free, or $null.
    .PARAMETER RequestId
        The request id.
    .PARAMETER Path
        The journal path; defaults to the private journal.
    .OUTPUTS
        [hashtable] or $null
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [string]$Path
    )
    $read = if ($Path) { Read-HostRefreshJournal -JournalPath $Path } else { Read-HostRefreshJournal }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return $null }
    return (Find-HostRefreshRequest -Journal $read.Journal -RequestId $RequestId)
}

function Get-HostRefreshActiveRequest {
    <#
    .SYNOPSIS
        The one request that blocks new repair work, lock-free, or $null.
    .PARAMETER JournalPath
        Defaults to the private journal path.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [hashtable] or $null
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$JournalPath, [scriptblock]$UtcNow)
    $read = if ($JournalPath) { Read-HostRefreshJournal -JournalPath $JournalPath } else { Read-HostRefreshJournal }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return $null }
    $clock = Get-HostRefreshClockValue -UtcNow $UtcNow
    return (Get-HostRefreshBlockingRequest -Journal $read.Journal -NowUnixMs $clock.UnixMs)
}

function Get-HostRefreshResult {
    <#
    .SYNOPSIS
        The stored outcome of one request, lock-free.
    .DESCRIPTION
        A caller that launched a worker reads its verdict here, keyed by
        request id and generation, rather than trusting an exit code.
    .PARAMETER RequestId
        The request id.
    .PARAMETER Generation
        An attempt generation; the newest attempt when omitted.
    .OUTPUTS
        [pscustomobject] @{ Found; RequestId; Channel; Generation; Attempt; State;
        Verdict; ExitCode; Mutated; FinalProbeState; RunnerReadiness; Handoff;
        CompletedUtc; LastAttemptEndedUtc; OutstandingObligation; OperatorAction }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [string]$Generation
    )
    $result = [ordered]@{
        Found = $false; RequestId = $RequestId; Channel = $null; Generation = $null; Attempt = 0; State = $null
        Verdict = $null; ExitCode = $null; Mutated = $false; FinalProbeState = $null; RunnerReadiness = 'unknown'
        Handoff = $null; CompletedUtc = $null; LastAttemptEndedUtc = $null; OutstandingObligation = [string[]]@(); OperatorAction = $null
    }
    $read = Read-HostRefreshJournal
    if ($read.Status -notin @('ok', 'recovered-previous')) { return [pscustomobject]$result }
    $request = Find-HostRefreshRequest -Journal $read.Journal -RequestId $RequestId
    if ($request) {
        $attempt = $null
        foreach ($candidate in @($request['attempts'])) {
            if ($Generation) { if ([string]$candidate['generation'] -ceq $Generation) { $attempt = $candidate } }
            else { $attempt = $candidate }
        }
        if ($Generation -and -not $attempt) { return [pscustomobject]$result }
        $result.Found = $true
        $result.Channel = [string]$request['channel']
        $result.State = [string]$request['state']
        $result.Attempt = [int]$request['attempt']
        $result.OperatorAction = $request['operatorAction']
        $result.CompletedUtc = $request['terminalUtc']
        $result.OutstandingObligation = [string[]]@(Get-HostRefreshArmedObligation -Request $request)
        $result.Mutated = [bool](@($request['attempts'] | Where-Object { [bool]$_['mutated'] }).Count -gt 0)
        if ($attempt) {
            $result.Generation = [string]$attempt['generation']
            $result.Verdict = $attempt['verdict']
            $result.ExitCode = $attempt['exitCode']
            $result.LastAttemptEndedUtc = $attempt['finishedUtc']
            if ($attempt['finalProbe'] -is [System.Collections.IDictionary]) { $result.FinalProbeState = [string]$attempt['finalProbe']['state'] }
            if ($attempt['runnerReadiness']) { $result.RunnerReadiness = [string]$attempt['runnerReadiness'] }
            $result.Handoff = $attempt['handoff']
        }
        if (-not $result.Verdict -and $request['verdict']) { $result.Verdict = $request['verdict'] }
        if ($null -eq $result.ExitCode -and $result.Verdict -and $script:HostRefreshVerdictExitCode.ContainsKey([string]$result.Verdict)) {
            $result.ExitCode = [int]$script:HostRefreshVerdictExitCode[[string]$result.Verdict]
        }
        return [pscustomobject]$result
    }
    if ($Generation) { return [pscustomobject]$result }
    $tombstone = Find-HostRefreshTombstone -Journal $read.Journal -RequestId $RequestId
    if ($tombstone) {
        $result.Found = $true
        $result.State = [string]$tombstone['state']
        $result.Verdict = $tombstone['verdict']
        $result.CompletedUtc = $tombstone['terminalUtc']
        if ($result.Verdict -and $script:HostRefreshVerdictExitCode.ContainsKey([string]$result.Verdict)) {
            $result.ExitCode = [int]$script:HostRefreshVerdictExitCode[[string]$result.Verdict]
        }
    }
    return [pscustomobject]$result
}

# --- REGION: Public: admission
function Get-HostRefreshAdmissionDecision {
    <#
    .SYNOPSIS
        The admission decision for a request, computed under an admission lock
        the caller already holds, writing nothing.
    .DESCRIPTION
        For a caller that must order other durable work (the automatic
        trigger's daily reservation) between the decision and the request.
    .PARAMETER RequestId
        Canonical lowercase request id.
    .PARAMETER Channel
        listener, remote or automatic.
    .PARAMETER Tier
        Only restart is admitted on these channels.
    .PARAMETER MaxRung
        Optional ceiling; it only lowers the tier ceiling.
    .PARAMETER RuntimeDir
        The runtime directory the request is for.
    .PARAMETER HostType
        Long host type.
    .PARAMETER AdmissionLock
        The held admission lock (Enter-YurunaSingleFlightLock on
        Get-YurunaHostRefreshAdmissionLockPath).
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Decision spawn|already-claimed|completed|busy|
        policy-mismatch|stored|unavailable; RequestId; ActiveRequestId;
        ActiveKind; State; Verdict; Attempt; Ceiling; Reason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('listener', 'remote', 'automatic')][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('restart')][string]$Tier,
        [ValidateSet('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')][string]$MaxRung,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][AllowNull()]$AdmissionLock,
        [scriptblock]$UtcNow
    )
    $policy = Get-HostRefreshPolicyRecord -Policy @{ tier = $Tier; maxRung = $MaxRung } -Channel $Channel
    $bodyArguments = @{ RequestId = $RequestId; Channel = $Channel; Policy = $policy; RuntimeDir = $RuntimeDir; HostType = $HostType }
    $body = {
        param($Journal, $Clock, $A)
        $decision = Resolve-HostRefreshAdmissionDecision -Journal $Journal -RequestId $A.RequestId -Channel $A.Channel -Policy $A.Policy -RuntimeDir $A.RuntimeDir -HostType $A.HostType -Clock $Clock
        @{ Changed = $false; Result = $decision }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionLock $AdmissionLock -UtcNow $UtcNow
    if (-not $run.Ran) {
        return (ConvertTo-HostRefreshAdmissionRecord -Decision ([pscustomobject]@{
                    Decision = 'unavailable'; RequestId = $RequestId; ActiveRequestId = $null; ActiveKind = ''; State = $null
                    Verdict = $null; Attempt = 0; Ceiling = [string]$policy['maxRung']; Reason = $run.Reason
                }))
    }
    return (ConvertTo-HostRefreshAdmissionRecord -Decision $run.Result)
}

function Request-HostRefreshAdmission {
    <#
    .SYNOPSIS
        Admit, replay or refuse a repair request from the listener, a remote
        pool-control request or the automatic trigger.
    .DESCRIPTION
        Takes only the short admission lock (or validates one the caller
        holds) and never spawns: the caller launches on Decision spawn and
        records the launch with Set-HostRefreshLaunchOutcome. A new request is
        created queued with its immutable policy; the same id with the same
        policy replays its state; a different policy is a mismatch even after
        completion; a different id is busy while any request is unresolved,
        a start-cycle holds a reservation, or the runner gate is not open.
        The automatic channel's policy is fixed: restart tier, no force, no
        hard stop, no service selections.
    .PARAMETER RequestId
        Canonical lowercase request id.
    .PARAMETER Channel
        listener, remote or automatic.
    .PARAMETER Tier
        Only restart is admitted on these channels.
    .PARAMETER MaxRung
        Optional ceiling; it only lowers the tier ceiling.
    .PARAMETER RuntimeDir
        The runtime directory the request is for.
    .PARAMETER HostType
        Long host type.
    .PARAMETER Context
        Optional: configPath, callerOuter @{ pid; startTimeUnixMs } and a
        trigger record, stored with the request.
    .PARAMETER AdmissionLock
        An admission lock the caller already holds.
    .PARAMETER AdmissionWaitMilliseconds
        Wait for the admission lock when none is passed.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Decision; RequestId; ActiveRequestId; ActiveKind;
        State; Verdict; Attempt; Ceiling; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('listener', 'remote', 'automatic')][string]$Channel,
        [Parameter(Mandatory)][ValidateSet('restart')][string]$Tier,
        [ValidateSet('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')][string]$MaxRung,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$HostType,
        [System.Collections.IDictionary]$Context,
        [AllowNull()]$AdmissionLock,
        [Alias('AdmissionTimeoutMilliseconds')][ValidateRange(0, 600000)][int]$AdmissionWaitMilliseconds = 1000,
        [scriptblock]$UtcNow
    )
    $policy = Get-HostRefreshPolicyRecord -Policy @{ tier = $Tier; maxRung = $MaxRung } -Channel $Channel
    $unavailable = {
        param([string]$Reason)
        ConvertTo-HostRefreshAdmissionRecord -Decision ([pscustomobject]@{
                Decision = 'unavailable'; RequestId = $RequestId; ActiveRequestId = $null; ActiveKind = ''; State = $null
                Verdict = $null; Attempt = 0; Ceiling = [string]$policy['maxRung']; Reason = $Reason
            })
    }
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) {
        return (& $unavailable 'preview')
    }
    $requester = Get-HostRefreshOwnProcess
    $bodyArguments = @{ RequestId = $RequestId; Channel = $Channel; Policy = $policy; RuntimeDir = $RuntimeDir; HostType = $HostType; Context = $Context; Requester = $requester }
    $body = {
        param($Journal, $Clock, $A)
        $decision = Resolve-HostRefreshAdmissionDecision -Journal $Journal -RequestId $A.RequestId -Channel $A.Channel -Policy $A.Policy -RuntimeDir $A.RuntimeDir -HostType $A.HostType -Clock $Clock
        $changed = $false
        if ($decision.Decision -eq 'spawn') {
            $launch = [ordered]@{
                outcome = 'pending'; launcherPid = $null; launcherStartTimeUnixMs = $null; workerPid = $null; workerStartTimeUnixMs = $null
                hopAckPath = $null; requesterPid = $A.Requester.pid; requesterStartTimeUnixMs = $A.Requester.startTimeUnixMs; updatedUtc = $Clock.Utc
            }
            if ($decision.Action -eq 'create') {
                $request = New-HostRefreshRequestRecord -RequestId $A.RequestId -Channel $A.Channel -RuntimeDir $A.RuntimeDir -HostType $A.HostType `
                    -Policy $A.Policy -Context $A.Context -State 'queued' -Clock $Clock
                $request['launch'] = $launch
                $Journal.requests.Add($request)
                $decision.State = 'queued'
                $changed = $true
            } elseif ($decision.Action -eq 'relaunch') {
                $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
                $request['launch'] = $launch
                $changed = $true
            }
        }
        @{ Changed = $changed; Result = $decision }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionLock $AdmissionLock -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) { return (& $unavailable $run.Reason) }
    if (-not $run.Committed) { return (& $unavailable 'journal-unwritable') }
    return (ConvertTo-HostRefreshAdmissionRecord -Decision $run.Result)
}

function Set-HostRefreshLaunchOutcome {
    <#
    .SYNOPSIS
        Record whether the launcher of an admitted request started.
    .DESCRIPTION
        A launch failure leaves the request queued and retryable with the same
        id; the identities of a started launch are what later decide whether
        its worker is still alive.
    .PARAMETER RequestId
        The admitted request.
    .PARAMETER Outcome
        started or launch-failed.
    .PARAMETER Launch
        The Start-YurunaDetachedProcess result (LauncherPid,
        LauncherStartTimeUnixMs, FinalPid, FinalStartTimeUnixMs).
    .PARAMETER LauncherPid
        Launcher pid when no Launch record is passed.
    .PARAMETER LauncherStartTimeUnixMs
        Launcher start time when no Launch record is passed.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('started', 'launch-failed')][string]$Outcome,
        $Launch,
        [int]$LauncherPid,
        [long]$LauncherStartTimeUnixMs,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) {
        return [pscustomobject]@{ Saved = $false; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Outcome = $Outcome; Launch = $Launch; LauncherPid = $LauncherPid; LauncherStartTimeUnixMs = $LauncherStartTimeUnixMs }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        if ([string]$request['state'] -ne 'queued') { return @{ Changed = $false; Result = 'not-queued' } }
        $record = if ($request['launch'] -is [System.Collections.IDictionary]) { $request['launch'] } else { [ordered]@{} }
        $record['outcome'] = $A.Outcome
        if ($A.Launch -and $A.Launch.Platform) { $record['platform'] = [string]$A.Launch.Platform }
        $record['launcherPid'] = if ($A.Launch -and $A.Launch.LauncherPid) { [int]$A.Launch.LauncherPid } elseif ($A.LauncherPid) { $A.LauncherPid } else { $null }
        $record['launcherStartTimeUnixMs'] = if ($A.Launch -and $A.Launch.LauncherStartTimeUnixMs) { [long]$A.Launch.LauncherStartTimeUnixMs } elseif ($A.LauncherStartTimeUnixMs) { $A.LauncherStartTimeUnixMs } else { $null }
        if ($A.Launch -and $A.Launch.FinalPid) { $record['workerPid'] = [int]$A.Launch.FinalPid }
        if ($A.Launch -and $A.Launch.FinalStartTimeUnixMs) { $record['workerStartTimeUnixMs'] = [long]$A.Launch.FinalStartTimeUnixMs }
        if ($A.Launch -and $A.Launch.Handshake -and $A.Launch.Handshake.Path) { $record['hopAckPath'] = [string]$A.Launch.Handshake.Path }
        $record['updatedUtc'] = $Clock.Utc
        $request['launch'] = $record
        @{ Changed = $true; Result = 'saved' }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'saved') { return [pscustomobject]@{ Saved = $false; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Stop-HostRefreshQueuedRequest {
    <#
    .SYNOPSIS
        Close a queued request that no worker has claimed.
    .DESCRIPTION
        Acts only on a queued request: a claimed one keeps its obligations
        and can only be resumed or disposed. The closed id keeps a tombstone.
    .PARAMETER RequestId
        The queued request.
    .PARAMETER Reason
        request-expired, pool-drain, operator-canceled, or worker-refused when
        the launched worker refused before claiming it.
    .PARAMETER Detail
        Optional reason code recorded with a worker refusal.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Stopped; State }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('request-expired', 'pool-drain', 'operator-canceled', 'worker-refused')][string]$Reason,
        [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,63}$')][string]$Detail,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) {
        return [pscustomobject]@{ Stopped = $false; State = $null }
    }
    $bodyArguments = @{ RequestId = $RequestId; Reason = $Reason; Detail = $Detail }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) {
            $tombstone = Find-HostRefreshTombstone -Journal $Journal -RequestId $A.RequestId
            return @{ Changed = $false; Result = [pscustomobject]@{ Stopped = $false; State = if ($tombstone) { [string]$tombstone['state'] } else { $null } } }
        }
        if ([string]$request['state'] -ne 'queued') { return @{ Changed = $false; Result = [pscustomobject]@{ Stopped = $false; State = [string]$request['state'] } } }
        $codes = [System.Collections.Generic.List[string]]::new()
        $codes.Add($A.Reason)
        if ($A.Detail) { $codes.Add($A.Detail) }
        $request['reasonCodes'] = [string[]]$codes.ToArray()
        Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict 'refused' -Clock $Clock
        @{ Changed = $true; Result = [pscustomobject]@{ Stopped = $true; State = 'refused' } }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran -or -not $run.Committed) { return [pscustomobject]@{ Stopped = $false; State = $null } }
    return $run.Result
}

# --- REGION: Public: worker claim and attempt lifecycle
function Confirm-HostRefreshIntent {
    <#
    .SYNOPSIS
        Claim a request for this worker under the lifetime repair lock.
    .DESCRIPTION
        The worker holds the lifetime lock, so no other worker is running;
        this takes the admission lock inside it, registers the owning runtime
        on first use, imports a legacy request file, expires unclaimed queued
        requests, and then:

          * New: a new local request with its immutable policy, refused while
            any other request is unresolved or a start-cycle holds a
            reservation.
          * Claim: the queued request the launcher admitted, or a retry of a
            running request whose worker died, or a recovery-pending one.
          * Resume: the one unresolved request, with its stored policy.

        A retry keeps the request id, policy and recovery record and
        increments the attempt before any new mutation; a retry with an armed
        obligation is restoration-only. More than three attempts abandons the
        request, keeping its obligations. A terminal request is never
        replayed: its stored verdict is returned instead. The claim is a
        critical write; when it does not commit the worker must not proceed.
    .PARAMETER LifetimeLock
        The held lifetime lock (Enter-YurunaSingleFlightLock on
        Get-YurunaHostRefreshLockPath).
    .PARAMETER Mode
        New, Claim or Resume.
    .PARAMETER RequestId
        The request id (New: the new id; Claim: the admitted id; Resume:
        optional, must match the unresolved request).
    .PARAMETER Policy
        New only: tier, maxRung, force, allowHardStop, restoreServiceVmName,
        leaveStoppedServiceVmName.
    .PARAMETER Worker
        @{ pid; startTimeUnixMs; ownerId; parent }
    .PARAMETER RuntimeDir
        The owning runtime directory.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER HostType
        Long host type.
    .PARAMETER Context
        New only: configPath and caller context stored with the request.
    .PARAMETER AdmissionWaitMilliseconds
        Wait for the admission lock.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Accepted; Reason; Request; Attempt; Generation;
        RestorationOnly; StoredVerdict }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$LifetimeLock,
        [Parameter(Mandatory)][ValidateSet('New', 'Claim', 'Resume')][string]$Mode,
        [string]$RequestId,
        [System.Collections.IDictionary]$Policy,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Worker,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$HostType,
        [System.Collections.IDictionary]$Context,
        [ValidateRange(0, 600000)][int]$AdmissionWaitMilliseconds = 5000,
        [scriptblock]$UtcNow
    )
    $refuse = {
        param([string]$Reason, $Request, $StoredVerdict)
        [pscustomobject]@{ Accepted = $false; Reason = $Reason; Request = $Request; Attempt = 0; Generation = $null; RestorationOnly = $false; StoredVerdict = $StoredVerdict }
    }
    if (-not $PSCmdlet.ShouldProcess("$RequestId", (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return (& $refuse 'preview' $null $null)
    }
    $lockPath = Get-HostRefreshPrivateFile -Name $script:HostRefreshLockName
    if (-not $lockPath -or -not (Test-YurunaSingleFlightLockOwned -Lock $LifetimeLock -Path $lockPath)) {
        return (& $refuse 'refused-lifetime-lock-not-held' $null $null)
    }
    if ($RequestId -and -not (Test-HostRefreshRequestIdShape -RequestId $RequestId)) { return (& $refuse 'refused-invalid-request-id' $null $null) }
    if ($Mode -ne 'Resume' -and -not $RequestId) { return (& $refuse 'refused-invalid-request-id' $null $null) }
    $newPolicy = $null
    if ($Mode -eq 'New') {
        $newPolicy = Get-HostRefreshPolicyRecord -Policy $Policy -Channel 'local'
        if ($null -eq $newPolicy) { return (& $refuse 'refused-policy-invalid' $null $null) }
    }
    $bodyArguments = @{ Mode = $Mode; RequestId = $RequestId; NewPolicy = $newPolicy; Worker = $Worker; RuntimeDir = $RuntimeDir; RepoRoot = $RepoRoot; HostType = $HostType; Context = $Context }
    $body = {
        param($Journal, $Clock, $A)
        $result = [ordered]@{ Accepted = $false; Reason = $null; Request = $null; Attempt = 0; Generation = $null; RestorationOnly = $false; StoredVerdict = $null }
        $changed = $false
        if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir']) {
            if (-not (Test-HostRefreshSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right $A.RuntimeDir)) {
                $result.Reason = 'refused-owner-mismatch'
                return @{ Changed = $false; Result = [pscustomobject]$result }
            }
        } else {
            $Journal.owner = [ordered]@{
                runtimeDir = $A.RuntimeDir; repoRoot = $A.RepoRoot; ownerId = $A.Worker['ownerId']
                userName = [Environment]::UserName; registeredUtc = $Clock.Utc
            }
            $changed = $true
        }
        $request = $null
        if ($A.Mode -eq 'Resume') {
            $request = Get-HostRefreshBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
            if (-not $request) { $result.Reason = 'refused-no-request'; return @{ Changed = $changed; Result = [pscustomobject]$result } }
            if ($A.RequestId -and [string]$request['requestId'] -cne $A.RequestId) {
                $result.Reason = 'refused-active-other-request'; $result.Request = $request
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
        } else {
            $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        }
        if ($A.Mode -eq 'New') {
            if ($request -or (Find-HostRefreshTombstone -Journal $Journal -RequestId $A.RequestId)) {
                $result.Reason = 'refused-request-exists'; $result.Request = $request
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            foreach ($reservation in $Journal.reservations) {
                $result.Reason = 'refused-start-cycle-active'
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            $blocking = Get-HostRefreshBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
            if ($blocking) {
                $result.Reason = 'refused-active-other-request'; $result.Request = $blocking
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            if ($Journal.tombstones.Count -ge $script:HostRefreshTombstoneCap) {
                $result.Reason = 'refused-journal-full'
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            $request = New-HostRefreshRequestRecord -RequestId $A.RequestId -Channel 'local' -RuntimeDir $A.RuntimeDir -HostType $A.HostType `
                -Policy $A.NewPolicy -Context $A.Context -State 'running' -Clock $Clock
            $attempt = New-HostRefreshAttemptRecord -Attempt 1 -Mode 'new' -Worker $A.Worker -Clock $Clock
            $request['attempt'] = 1
            $request['attempts'].Add($attempt)
            $Journal.requests.Add($request)
            $result.Accepted = $true; $result.Reason = 'accepted-new'; $result.Request = $request
            $result.Attempt = 1; $result.Generation = $attempt['generation']
            return @{ Changed = $true; Result = [pscustomobject]$result }
        }
        if (-not $request) {
            $tombstone = Find-HostRefreshTombstone -Journal $Journal -RequestId $A.RequestId
            if ($tombstone) {
                $result.Reason = 'refused-terminal'; $result.StoredVerdict = $tombstone['verdict']
            } else {
                $result.Reason = 'refused-no-request'
            }
            return @{ Changed = $changed; Result = [pscustomobject]$result }
        }
        $result.Request = $request
        $state = [string]$request['state']
        if ($state -eq 'completed' -or $state -eq 'refused' -or ($state -eq 'abandoned' -and $A.Mode -ne 'Resume')) {
            $result.Reason = if ($state -eq 'refused' -and @($request['reasonCodes']) -contains 'request-expired') { 'refused-request-expired' } else { 'refused-terminal' }
            $result.StoredVerdict = $request['verdict']
            return @{ Changed = $changed; Result = [pscustomobject]$result }
        }
        if ($state -eq 'abandoned') {
            $result.Reason = 'refused-attempts-exhausted'; $result.StoredVerdict = $request['verdict']
            return @{ Changed = $changed; Result = [pscustomobject]$result }
        }
        if (-not (Test-HostRefreshSameRuntime -Left ([string]$request['runtimeDir']) -Right $A.RuntimeDir)) {
            $result.Reason = 'refused-runtime-mismatch'
            return @{ Changed = $changed; Result = [pscustomobject]$result }
        }
        $armed = @(Get-HostRefreshArmedObligation -Request $request)
        $next = [int]$request['attempt'] + 1
        if ($next -gt $script:HostRefreshMaxAttempts) {
            $request['reasonCodes'] = [string[]]@('attempts-exhausted')
            if (-not $request['operatorAction']) { $request['operatorAction'] = if ($armed.Count -gt 0) { 'dispose-obligations' } else { $null } }
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'abandoned' -Verdict 'abandoned' -Clock $Clock
            $result.Reason = 'refused-attempts-exhausted'; $result.StoredVerdict = 'abandoned'
            return @{ Changed = $true; Result = [pscustomobject]$result }
        }
        $modeName = switch ($state) {
            'queued' { if ($A.Mode -eq 'Resume') { 'resume' } else { 'claim' } }
            default { if ($armed.Count -gt 0) { 'restoration' } elseif ($A.Mode -eq 'Resume') { 'resume' } else { 'claim' } }
        }
        $attempt = New-HostRefreshAttemptRecord -Attempt $next -Mode $modeName -Worker $A.Worker -Clock $Clock
        $request['attempt'] = $next
        $request['attempts'].Add($attempt)
        $request['state'] = 'running'
        if ($request['launch'] -is [System.Collections.IDictionary]) {
            $request['launch']['workerPid'] = $A.Worker['pid']
            $request['launch']['workerStartTimeUnixMs'] = $A.Worker['startTimeUnixMs']
            $request['launch']['updatedUtc'] = $Clock.Utc
        }
        $result.Accepted = $true
        $result.Attempt = $next
        $result.Generation = $attempt['generation']
        $result.RestorationOnly = ($armed.Count -gt 0)
        $result.Reason = if ($state -eq 'queued') { 'accepted-claim' } elseif ($armed.Count -gt 0) { 'accepted-restoration-retry' } else { 'accepted-retry' }
        @{ Changed = $true; Result = [pscustomobject]$result }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) {
        $reason = switch -Wildcard ($run.Reason) {
            'admission-busy' { 'refused-admission-timeout' }
            'journal-corrupt' { 'refused-journal-corrupt' }
            'journal-unknown-version' { 'refused-journal-version' }
            default { 'refused-journal-unavailable' }
        }
        return (& $refuse $reason $null $null)
    }
    if (-not $run.Committed) { return (& $refuse 'refused-journal-unavailable' $null $null) }
    return $run.Result
}

function Save-HostRefreshRecoveryRecord {
    <#
    .SYNOPSIS
        Persist what a repair must restore, before its first disruption.
    .DESCRIPTION
        The first capture stores the recovery record and its obligations as
        pending. A later attempt of the same request only appends an
        observation: the original service recovery set and control snapshot
        are never replaced, so an already-stopped guest is never recaptured
        as originally stopped. A write that does not commit refuses the
        mutation it was meant to cover.
    .PARAMETER RequestId
        The running request.
    .PARAMETER Generation
        The current attempt's generation.
    .PARAMETER Recovery
        The recovery record.
    .PARAMETER Obligation
        Obligation rows: @{ id; kind; target; required }.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Durable; Reason; FirstCapture }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Recovery,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Obligation,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = 'preview'; FirstCapture = $false }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; Recovery = $Recovery; Obligation = $Obligation }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        $last = Get-HostRefreshLastAttempt -Request $request
        if ([string]$request['state'] -ne 'running' -or -not $last -or [string]$last['generation'] -cne $A.Generation) { return @{ Changed = $false; Result = 'generation-mismatch' } }
        if ($request['recovery'] -is [System.Collections.IDictionary]) {
            $observations = $request['recovery']['observations']
            if ($observations -isnot [System.Collections.IList]) { $observations = [System.Collections.Generic.List[object]]::new() }
            $observations.Add([ordered]@{
                    generation  = $A.Generation
                    capturedUtc = $Clock.Utc
                    probe       = $A.Recovery['probe']
                    services    = $A.Recovery['servicesSummary']
                })
            while ($observations.Count -gt $script:HostRefreshObservationCap) { $observations.RemoveAt(0) }
            $request['recovery']['observations'] = $observations
            return @{ Changed = $true; Result = 'observation' }
        }
        $record = [ordered]@{}
        foreach ($key in $A.Recovery.Keys) { $record[[string]$key] = $A.Recovery[$key] }
        $record['capturedUtc'] = $Clock.Utc
        $record['capturedGeneration'] = $A.Generation
        $record['observations'] = [System.Collections.Generic.List[object]]::new()
        $request['recovery'] = $record
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $A.Obligation) {
            if ($row -isnot [System.Collections.IDictionary] -or -not $row['id']) { continue }
            $list.Add([ordered]@{
                    id = [string]$row['id']; kind = [string]$row['kind']; target = [string]$row['target']
                    required = if ($row.Contains('required')) { [bool]$row['required'] } else { $true }
                    status = 'pending'; armedGeneration = $null; updatedUtc = $Clock.Utc; disposedBy = $null; evidence = $null
                })
        }
        $request['obligations'] = $list
        @{ Changed = $true; Result = 'captured' }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = $run.Reason; FirstCapture = $false } }
    if ($run.Result -notin @('captured', 'observation')) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = [string]$run.Result; FirstCapture = $false } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; Reason = if ($run.Committed) { [string]$run.Result } else { $run.Reason }; FirstCapture = ($run.Result -eq 'captured') }
}

function Set-HostRefreshObligationState {
    <#
    .SYNOPSIS
        Arm obligations immediately before the mutation that could disrupt
        them, or discharge them once verified.
    .DESCRIPTION
        Arming is a critical write: when it does not commit, the rung that
        would have disrupted the obligation must not run. An obligation not
        in the captured list is added when armed. Disposed obligations are
        never changed here.
    .PARAMETER RequestId
        The running request.
    .PARAMETER Generation
        The current attempt's generation.
    .PARAMETER ObligationId
        service:<key>, endpoint:<key>, runner, listener or controls.
    .PARAMETER State
        armed or discharged.
    .PARAMETER Evidence
        Short evidence token for a discharge.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Durable; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][ValidatePattern('^(service:[a-z0-9][a-z0-9-]{0,62}|endpoint:[a-z0-9][a-z0-9-]{0,62}|runner|listener|controls)$')][string[]]$ObligationId,
        [Parameter(Mandatory)][ValidateSet('armed', 'discharged')][string]$State,
        [string]$Evidence,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; ObligationId = $ObligationId; State = $State; Evidence = $Evidence }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        $last = Get-HostRefreshLastAttempt -Request $request
        if ([string]$request['state'] -ne 'running' -or -not $last -or [string]$last['generation'] -cne $A.Generation) { return @{ Changed = $false; Result = 'generation-mismatch' } }
        $obligations = $request['obligations']
        foreach ($id in $A.ObligationId) {
            $row = $null
            foreach ($candidate in $obligations) { if ([string]$candidate['id'] -ceq $id) { $row = $candidate } }
            if (-not $row) {
                $kind = ($id -split ':', 2)[0]
                $target = if ($id -match ':') { ($id -split ':', 2)[1] } else { $id }
                $row = [ordered]@{ id = $id; kind = $kind; target = $target; required = $true; status = 'pending'; armedGeneration = $null; updatedUtc = $null; disposedBy = $null; evidence = $null }
                $obligations.Add($row)
            }
            if ([string]$row['status'] -eq 'disposed') { continue }
            $row['status'] = $A.State
            $row['updatedUtc'] = $Clock.Utc
            if ($A.State -eq 'armed') { $row['armedGeneration'] = $A.Generation }
            else { $row['evidence'] = if ($A.Evidence) { $A.Evidence } else { 'verified' } }
        }
        @{ Changed = $true; Result = 'saved' }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'saved') { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Set-HostRefreshObligationDisposition {
    <#
    .SYNOPSIS
        Record, with the actor, that outstanding obligations were handled
        outside the repair.
    .DESCRIPTION
        Local and audited: each disposed obligation records who disposed it
        and when. Only armed obligations can be disposed; any other id is
        reported as unknown and changes nothing. When none remain, a
        recovery-pending request, or a running one whose worker is positively
        dead, is closed as completed, and an abandoned one stops blocking new
        work. A running request whose worker is this process, alive, or of
        unknown liveness stays running: that worker is mid-attempt, still
        writes under its generation, and derives the final state itself when
        it completes the attempt.
    .PARAMETER ObligationId
        The ids to dispose.
    .PARAMETER Actor
        Who disposed them (an account name, or an automatic cause such as
        superseded-by-operator-intent).
    .PARAMETER RequestId
        The request; defaults to the one unresolved request.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Disposed [string[]]; Unknown [string[]];
        RemainingOutstanding [int]; State; RequestId }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^(service:[a-z0-9][a-z0-9-]{0,62}|endpoint:[a-z0-9][a-z0-9-]{0,62}|runner|listener|controls)$')][string[]]$ObligationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Actor,
        [string]$RequestId,
        [scriptblock]$UtcNow
    )
    $empty = [pscustomobject]@{ Saved = $false; Disposed = [string[]]@(); Unknown = [string[]]$ObligationId; RemainingOutstanding = 0; State = $null; RequestId = $RequestId }
    if (-not $PSCmdlet.ShouldProcess("$RequestId", (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return $empty }
    $bodyArguments = @{ RequestId = $RequestId; ObligationId = $ObligationId; Actor = $Actor; Empty = $empty; Caller = (Get-HostRefreshOwnProcess) }
    $body = {
        param($Journal, $Clock, $A)
        $request = $null
        if ($A.RequestId) { $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId }
        else {
            foreach ($candidate in $Journal.requests) {
                if (@(Get-HostRefreshArmedObligation -Request $candidate).Count -gt 0) { $request = $candidate }
            }
        }
        if (-not $request) { return @{ Changed = $false; Result = $A.Empty } }
        $disposed = [System.Collections.Generic.List[string]]::new()
        $unknown = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $A.ObligationId) {
            $row = $null
            foreach ($candidate in $request['obligations']) { if ([string]$candidate['id'] -ceq $id -and [string]$candidate['status'] -eq 'armed') { $row = $candidate } }
            if (-not $row) { $unknown.Add($id); continue }
            $row['status'] = 'disposed'
            $row['disposedBy'] = $A.Actor
            $row['updatedUtc'] = $Clock.Utc
            $disposed.Add($id)
        }
        $remaining = @(Get-HostRefreshArmedObligation -Request $request).Count
        $closable = ([string]$request['state'] -eq 'recovery-pending')
        if ([string]$request['state'] -eq 'running') {
            # Only a crashed worker's request closes here. The caller is never
            # treated as dead, even when its pid recycles a crashed worker's:
            # the request then stays running and a retry resolves it.
            $last = Get-HostRefreshLastAttempt -Request $request
            $worker = if ($last -and $last['worker'] -is [System.Collections.IDictionary]) { $last['worker'] } else { $null }
            $isCaller = [bool]$worker -and "$($worker['pid'])" -eq "$($A.Caller.pid)"
            $closable = [bool]$worker -and -not $isCaller -and
                (Get-HostRefreshProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs']) -eq 'dead'
        }
        if ($disposed.Count -gt 0 -and $remaining -eq 0 -and $closable) {
            $verdict = if ($request['verdict']) { [string]$request['verdict'] } else { 'partial' }
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'completed' -Verdict $verdict -Clock $Clock
        }
        $result = [pscustomobject]@{
            Saved = $true; Disposed = [string[]]$disposed.ToArray(); Unknown = [string[]]$unknown.ToArray()
            RemainingOutstanding = $remaining; State = [string]$request['state']; RequestId = [string]$request['requestId']
        }
        @{ Changed = ($disposed.Count -gt 0); Result = $result }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return $empty }
    $result = $run.Result
    if (-not $run.Committed) { $result.Saved = $false }
    return $result
}

function Complete-HostRefreshAttempt {
    <#
    .SYNOPSIS
        Record an attempt's verdict; the request's state is derived, never
        chosen by the caller.
    .DESCRIPTION
        Called for every verdict, including partial ones. The state is
        refused for a refusal with nothing mutated and nothing armed,
        abandoned for an abandoned verdict, recovery-pending while any
        obligation is still armed, and completed otherwise. A terminal
        request keeps a tombstone.
    .PARAMETER RequestId
        The request.
    .PARAMETER Generation
        The attempt generation.
    .PARAMETER Verdict
        The attempt verdict.
    .PARAMETER Mutated
        Whether this attempt changed anything.
    .PARAMETER ReasonCode
        Private reason tokens.
    .PARAMETER RungResult
        Rung rows { name; order; outcome; reason }.
    .PARAMETER OperatorAction
        The operator action token, if any.
    .PARAMETER FinalProbe
        The final probe record (state and reason are kept).
    .PARAMETER RunnerReadiness
        caller-parked, restarted-ready, not-ready, not-needed or unknown.
    .PARAMETER Handoff
        @{ tokenId; purpose } when a runner handoff was issued.
    .PARAMETER GateGeneration
        The runner gate generation this attempt left behind.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Durable; State; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][ValidateSet('repaired', 'already-healthy', 'refused', 'failed', 'partial', 'still-unresponsive', 'abandoned')][string]$Verdict,
        [Parameter(Mandatory)][bool]$Mutated,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ReasonCode,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$RungResult,
        [string]$OperatorAction,
        $FinalProbe,
        [ValidateSet('caller-parked', 'restarted-ready', 'not-ready', 'not-needed', 'unknown')][string]$RunnerReadiness = 'unknown',
        [System.Collections.IDictionary]$Handoff,
        [string]$GateGeneration,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; Verdict = $Verdict; Mutated = $Mutated; ReasonCode = $ReasonCode; RungResult = $RungResult; OperatorAction = $OperatorAction; FinalProbe = $FinalProbe; RunnerReadiness = $RunnerReadiness; Handoff = $Handoff; GateGeneration = $GateGeneration }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        $attempt = $null
        foreach ($candidate in $request['attempts']) { if ([string]$candidate['generation'] -ceq $A.Generation) { $attempt = $candidate } }
        if (-not $attempt) { return @{ Changed = $false; Result = 'generation-mismatch' } }
        $attempt['finishedUtc'] = $Clock.Utc
        $attempt['verdict'] = $A.Verdict
        $attempt['exitCode'] = [int]$script:HostRefreshVerdictExitCode[$A.Verdict]
        $attempt['mutated'] = $A.Mutated
        $attempt['reasonCodes'] = [string[]]@($A.ReasonCode)
        $attempt['rungs'] = [object[]]@($A.RungResult | ForEach-Object {
                [ordered]@{ name = [string]$_.name; order = [int]$_.order; outcome = [string]$_.outcome; reason = [string]$_.reason }
            })
        if ($A.FinalProbe) { $attempt['finalProbe'] = [ordered]@{ state = [string]$A.FinalProbe.state; reason = [string]$A.FinalProbe.reason } }
        $attempt['runnerReadiness'] = $A.RunnerReadiness
        if ($A.Handoff) { $attempt['handoff'] = [ordered]@{ tokenId = [string]$A.Handoff['tokenId']; purpose = [string]$A.Handoff['purpose'] } }
        if ($A.GateGeneration) { $attempt['gateGeneration'] = $A.GateGeneration }
        $request['verdict'] = $A.Verdict
        $request['operatorAction'] = if ($A.OperatorAction) { $A.OperatorAction } else { $null }
        $request['reasonCodes'] = [string[]]@($A.ReasonCode)
        $armed = @(Get-HostRefreshArmedObligation -Request $request).Count
        $anyMutated = @($request['attempts'] | Where-Object { [bool]$_['mutated'] }).Count -gt 0
        if ($A.Verdict -eq 'abandoned') {
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'abandoned' -Verdict $A.Verdict -Clock $Clock
        } elseif ($A.Verdict -eq 'refused' -and -not $anyMutated -and $armed -eq 0) {
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict $A.Verdict -Clock $Clock
        } elseif ($armed -gt 0) {
            $request['state'] = 'recovery-pending'
        } else {
            Set-HostRefreshRequestTerminal -Journal $Journal -Request $request -State 'completed' -Verdict $A.Verdict -Clock $Clock
        }
        @{ Changed = $true; Result = [string]$request['state'] }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = $run.Reason } }
    if ($run.Result -in @('no-request', 'generation-mismatch')) { return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; State = [string]$run.Result; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Set-HostRefreshCallerAck {
    <#
    .SYNOPSIS
        Record the resident outer runner's own readiness after it verified an
        automatic repair's handoff.
    .PARAMETER RequestId
        The request.
    .PARAMETER Readiness
        ready or failed.
    .PARAMETER CallerPid
        The outer runner's pid.
    .PARAMETER CallerStartTimeUnixMs
        The outer runner's start time.
    .PARAMETER Reason
        Optional reason token.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('ready', 'failed')][string]$Readiness,
        [Parameter(Mandatory)][int]$CallerPid,
        [Parameter(Mandatory)][long]$CallerStartTimeUnixMs,
        [string]$Reason,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return [pscustomobject]@{ Saved = $false } }
    $bodyArguments = @{ RequestId = $RequestId; Readiness = $Readiness; CallerPid = $CallerPid; CallerStartTimeUnixMs = $CallerStartTimeUnixMs; Reason = $Reason }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostRefreshRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = $false } }
        $request['callerAck'] = [ordered]@{
            readiness = $A.Readiness; callerPid = $A.CallerPid; callerStartTimeUnixMs = $A.CallerStartTimeUnixMs
            reason = if ($A.Reason) { $A.Reason } else { $null }; updatedUtc = $Clock.Utc
        }
        @{ Changed = $true; Result = $true }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Saved = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

# --- REGION: Public: start-cycle reservation
function Request-HostRefreshStartCycleReservation {
    <#
    .SYNOPSIS
        Reserve the host for a start-cycle operation, or report busy.
    .DESCRIPTION
        A reservation and a repair exclude each other under the admission
        lock: while one is held the other is busy. Busy also while the runner
        gate is not open, so a start-cycle never wakes a runner a repair is
        holding. The reservation carries the requesting process's identity,
        so a crash before launch is cleared by identity, never by age.
    .PARAMETER OperationId
        Canonical lowercase operation id.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER AdmissionWaitMilliseconds
        Wait for the admission lock.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Decision reserved|busy|unavailable; Generation;
        ActiveKind; ActiveRequestId; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$OperationId,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Alias('AdmissionTimeoutMilliseconds')][ValidateRange(0, 600000)][int]$AdmissionWaitMilliseconds = 1000,
        [scriptblock]$UtcNow
    )
    $unavailable = { param([string]$Reason) [pscustomobject]@{ Decision = 'unavailable'; Generation = $null; ActiveKind = ''; ActiveRequestId = $null; Reason = $Reason } }
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return (& $unavailable 'preview') }
    $requester = Get-HostRefreshOwnProcess
    $bodyArguments = @{ OperationId = $OperationId; RuntimeDir = $RuntimeDir; Requester = $requester; Unavailable = $unavailable }
    $body = {
        param($Journal, $Clock, $A)
        $busy = { param([string]$Kind, $Active, [string]$Why) [pscustomobject]@{ Decision = 'busy'; Generation = $null; ActiveKind = $Kind; ActiveRequestId = $Active; Reason = $Why } }
        foreach ($reservation in $Journal.reservations) {
            return @{ Changed = $false; Result = (& $busy 'start-cycle' ([string]$reservation['operationId']) 'start-cycle-active') }
        }
        $blocking = Get-HostRefreshBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
        if ($blocking) { return @{ Changed = $false; Result = (& $busy 'host-refresh' ([string]$blocking['requestId']) 'host-refresh-active') } }
        $gate = Get-HostRefreshGateView -RuntimeDir $A.RuntimeDir
        if (-not $gate.Known) { return @{ Changed = $false; Result = (& $A.Unavailable $gate.Reason) } }
        if (-not $gate.Open) { return @{ Changed = $false; Result = (& $busy 'host-refresh' $gate.RequestId "gate-$($gate.State)") } }
        $generation = [Guid]::NewGuid().ToString('N')
        $Journal.reservations.Add([ordered]@{
                kind = 'start-cycle'; operationId = $A.OperationId; generation = $generation; state = 'queued'
                launch = [ordered]@{ outcome = 'pending'; launcherPid = $null; launcherStartTimeUnixMs = $null; workerPid = $null; workerStartTimeUnixMs = $null
                    requesterPid = $A.Requester.pid; requesterStartTimeUnixMs = $A.Requester.startTimeUnixMs; updatedUtc = $Clock.Utc }
                worker = $null; runtimeDir = $A.RuntimeDir; createdUtc = $Clock.Utc; createdUnixMs = $Clock.UnixMs
            })
        @{ Changed = $true; Result = [pscustomobject]@{ Decision = 'reserved'; Generation = $generation; ActiveKind = ''; ActiveRequestId = $null; Reason = 'reserved' } }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) { return (& $unavailable $run.Reason) }
    if (-not $run.Committed) { return (& $unavailable 'journal-unwritable') }
    return $run.Result
}

function Set-HostRefreshStartCycleLaunch {
    <#
    .SYNOPSIS
        Record a start-cycle worker's launch; a failed launch removes the
        reservation, since nothing was mutated and a leftover reservation
        would block every repair.
    .PARAMETER OperationId
        The reserved operation.
    .PARAMETER Generation
        The reservation generation.
    .PARAMETER Outcome
        started or launch-failed.
    .PARAMETER Launch
        The Start-YurunaDetachedProcess result.
    .PARAMETER LauncherPid
        Launcher pid when no Launch record is passed.
    .PARAMETER LauncherStartTimeUnixMs
        Launcher start time when no Launch record is passed.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][ValidateSet('started', 'launch-failed')][string]$Outcome,
        $Launch,
        [int]$LauncherPid,
        [long]$LauncherStartTimeUnixMs,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return [pscustomobject]@{ Saved = $false } }
    $bodyArguments = @{ OperationId = $OperationId; Generation = $Generation; Outcome = $Outcome; Launch = $Launch; LauncherPid = $LauncherPid; LauncherStartTimeUnixMs = $LauncherStartTimeUnixMs }
    $body = {
        param($Journal, $Clock, $A)
        for ($i = 0; $i -lt $Journal.reservations.Count; $i++) {
            $reservation = $Journal.reservations[$i]
            if ([string]$reservation['operationId'] -cne $A.OperationId -or [string]$reservation['generation'] -cne $A.Generation) { continue }
            if ($A.Outcome -eq 'launch-failed') {
                $Journal.reservations.RemoveAt($i)
                return @{ Changed = $true; Result = $true }
            }
            $launchRecord = $reservation['launch']
            if ($launchRecord -isnot [System.Collections.IDictionary]) { $launchRecord = [ordered]@{} }
            $launchRecord['outcome'] = 'started'
            if ($A.Launch -and $A.Launch.Platform) { $launchRecord['platform'] = [string]$A.Launch.Platform }
            $launchRecord['launcherPid'] = if ($A.Launch -and $A.Launch.LauncherPid) { [int]$A.Launch.LauncherPid } elseif ($A.LauncherPid) { $A.LauncherPid } else { $null }
            $launchRecord['launcherStartTimeUnixMs'] = if ($A.Launch -and $A.Launch.LauncherStartTimeUnixMs) { [long]$A.Launch.LauncherStartTimeUnixMs } elseif ($A.LauncherStartTimeUnixMs) { $A.LauncherStartTimeUnixMs } else { $null }
            if ($A.Launch -and $A.Launch.FinalPid) { $launchRecord['workerPid'] = [int]$A.Launch.FinalPid }
            if ($A.Launch -and $A.Launch.FinalStartTimeUnixMs) { $launchRecord['workerStartTimeUnixMs'] = [long]$A.Launch.FinalStartTimeUnixMs }
            $launchRecord['updatedUtc'] = $Clock.Utc
            $reservation['launch'] = $launchRecord
            return @{ Changed = $true; Result = $true }
        }
        @{ Changed = $false; Result = $false }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Saved = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

function Confirm-HostRefreshStartCycleReservation {
    <#
    .SYNOPSIS
        Claim a start-cycle reservation for its worker under the lifetime
        lock.
    .DESCRIPTION
        Records the worker's identity on the reservation and marks it
        running, so the reservation is cleared by that identity, never by
        age. A preview claims nothing and returns Reason preview.
    .PARAMETER OperationId
        The reserved operation.
    .PARAMETER Generation
        The reservation generation.
    .PARAMETER LifetimeLock
        The held lifetime lock.
    .PARAMETER Worker
        @{ pid; startTimeUnixMs }
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Generation,
        [Parameter(Mandatory)][AllowNull()]$LifetimeLock,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Worker,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) {
        return [pscustomobject]@{ Valid = $false; Reason = 'preview' }
    }
    $lockPath = Get-HostRefreshPrivateFile -Name $script:HostRefreshLockName
    if (-not $lockPath -or -not (Test-YurunaSingleFlightLockOwned -Lock $LifetimeLock -Path $lockPath)) {
        return [pscustomobject]@{ Valid = $false; Reason = 'lifetime-lock-not-held' }
    }
    $bodyArguments = @{ OperationId = $OperationId; Generation = $Generation; Worker = $Worker }
    $body = {
        param($Journal, $Clock, $A)
        foreach ($reservation in $Journal.reservations) {
            if ([string]$reservation['operationId'] -cne $A.OperationId -or [string]$reservation['generation'] -cne $A.Generation) { continue }
            $reservation['state'] = 'running'
            $reservation['worker'] = [ordered]@{ pid = $A.Worker['pid']; startTimeUnixMs = $A.Worker['startTimeUnixMs']; claimedUtc = $Clock.Utc }
            return @{ Changed = $true; Result = 'valid' }
        }
        @{ Changed = $false; Result = 'reservation-lost' }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Valid = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'valid') { return [pscustomobject]@{ Valid = $false; Reason = [string]$run.Result } }
    if (-not $run.Committed) { return [pscustomobject]@{ Valid = $false; Reason = 'journal-unwritable' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'valid' }
}

function Complete-HostRefreshStartCycleReservation {
    <#
    .SYNOPSIS
        Clear a start-cycle reservation of the matching generation only.
    .PARAMETER OperationId
        The reserved operation.
    .PARAMETER Generation
        The reservation generation.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Cleared }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$Generation,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return [pscustomobject]@{ Cleared = $false } }
    $bodyArguments = @{ OperationId = $OperationId; Generation = $Generation }
    $body = {
        param($Journal, $Clock, $A)
        $null = $Clock
        for ($i = 0; $i -lt $Journal.reservations.Count; $i++) {
            $reservation = $Journal.reservations[$i]
            if ([string]$reservation['operationId'] -ceq $A.OperationId -and [string]$reservation['generation'] -ceq $A.Generation) {
                $Journal.reservations.RemoveAt($i)
                return @{ Changed = $true; Result = $true }
            }
        }
        @{ Changed = $false; Result = $false }
    }
    $run = Invoke-HostRefreshJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Cleared = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

# --- REGION: Public: macOS automation grant evidence
function Get-YurunaHostRefreshAutomationSubject {
    <#
    .SYNOPSIS
        The automation subjects a responsive UTM probe has been observed
        under.
    .DESCRIPTION
        A control timeout only qualifies for a UTM restart when the sending
        subject is known to hold the Automation grant; each responsive probe
        records its subject here. An unreadable record yields none, which
        keeps timeouts undetermined.
    .OUTPUTS
        [string[]] (elements)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-HostRefreshPrivateFile -Name $script:HostRefreshGrantName -NoCreate
    if (-not $path) { return }
    $record = Read-YurunaCriticalRecord -Path $path -Kind $script:HostRefreshGrantKind
    if ($record.Status -ne 'ok' -or $record.Payload -isnot [System.Collections.IDictionary]) { return }
    foreach ($row in (ConvertTo-HostRefreshList -Value $record.Payload['subjects'])) {
        if ($row -is [System.Collections.IDictionary] -and $row['subject']) { [string]$row['subject'] }
    }
}

function Add-YurunaHostRefreshAutomationSubject {
    <#
    .SYNOPSIS
        Record an automation subject a responsive probe ran under.
    .DESCRIPTION
        A subject whose uid could not be read is never recorded: it can never
        match a later subject, so it would only add noise. The record keeps
        the newest 32 subjects.
    .PARAMETER Subject
        The subject string the probe reported.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Saved; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Subject,
        [scriptblock]$UtcNow
    )
    if ($Subject.StartsWith('uid=unknown;', [StringComparison]::Ordinal)) { return [pscustomobject]@{ Saved = $false; Reason = 'subject-unverified' } }
    if (-not $PSCmdlet.ShouldProcess($Subject, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_should_process_admission'))) { return [pscustomobject]@{ Saved = $false; Reason = 'preview' } }
    $path = Get-HostRefreshPrivateFile -Name $script:HostRefreshGrantName
    $lockPath = Get-HostRefreshPrivateFile -Name $script:HostRefreshAdmissionName
    if (-not $path -or -not $lockPath) { return [pscustomobject]@{ Saved = $false; Reason = 'private-root-unavailable' } }
    $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 5000 -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-refresh-automation-grant' }
    if (-not $lock.Held) { return [pscustomobject]@{ Saved = $false; Reason = "lock-$($lock.Reason)" } }
    try {
        $clock = Get-HostRefreshClockValue -UtcNow $UtcNow
        $read = Read-YurunaCriticalRecord -Path $path -Kind $script:HostRefreshGrantKind
        if ($read.Status -notin @('ok', 'missing')) { return [pscustomobject]@{ Saved = $false; Reason = "record-$($read.Status)" } }
        $rows = [System.Collections.Generic.List[object]]::new()
        if ($read.Status -eq 'ok' -and $read.Payload -is [System.Collections.IDictionary]) {
            foreach ($row in (ConvertTo-HostRefreshList -Value $read.Payload['subjects'])) {
                if ($row -is [System.Collections.IDictionary] -and $row['subject'] -and [string]$row['subject'] -cne $Subject) { $rows.Add($row) }
            }
        }
        $rows.Add([ordered]@{ subject = $Subject; observedUtc = $clock.Utc })
        while ($rows.Count -gt $script:HostRefreshGrantCap) { $rows.RemoveAt(0) }
        $write = Write-YurunaCriticalRecord -Path $path -Kind $script:HostRefreshGrantKind -Payload ([ordered]@{ schemaVersion = 1; subjects = [object[]]$rows.ToArray() }) `
            -ExpectedGeneration ([long]$read.Generation) -Confirm:$false
        return [pscustomobject]@{ Saved = [bool]$write.Committed; Reason = [string]$write.Reason }
    } finally {
        Exit-YurunaSingleFlightLock -Lock $lock
    }
}

Export-ModuleMember -Function Get-HostRefreshPrivateRoot, Get-YurunaHostRefreshRequestPath, Get-YurunaHostRefreshLockPath, `
    Get-YurunaHostRefreshAdmissionLockPath, Get-HostRefreshPrivateWorkDir, New-YurunaHostRefreshRequestId, `
    Read-HostRefreshJournal, Read-YurunaHostRefreshRequest, Get-HostRefreshActiveRequest, Get-HostRefreshResult, `
    Get-HostRefreshAdmissionDecision, Request-HostRefreshAdmission, Set-HostRefreshLaunchOutcome, Stop-HostRefreshQueuedRequest, `
    Confirm-HostRefreshIntent, Save-HostRefreshRecoveryRecord, Set-HostRefreshObligationState, Set-HostRefreshObligationDisposition, `
    Complete-HostRefreshAttempt, Set-HostRefreshCallerAck, `
    Request-HostRefreshStartCycleReservation, Set-HostRefreshStartCycleLaunch, Confirm-HostRefreshStartCycleReservation, `
    Complete-HostRefreshStartCycleReservation, Get-YurunaHostRefreshAutomationSubject, Add-YurunaHostRefreshAutomationSubject
