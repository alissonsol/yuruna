<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42d4e5f6-7a8b-49c0-8d1e-2f3a4b5c6d7e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-operation request intent lock
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

# See https://yuruna.link/4213a0b3-008c

$script:HostOperationJournalName     = 'host-operation.journal'
$script:HostOperationJournalKind     = 'host-operation.request-journal'
$script:HostOperationJournalSchema   = 2
$script:HostOperationJournalMaxBytes = 4194304
$script:HostOperationLockName        = 'host-operation.lock'
$script:HostOperationAdmissionName   = 'host-operation.admission.lock'
$script:HostRepairWorkDirName     = 'work'
$script:HostOperationGrantName       = 'automation-grant.record'
$script:HostOperationGrantKind       = 'automation-grant'
$script:HostOperationGrantCap        = 32
# An unclaimed click must not hold the host forever, but an interrupted claim
# keeps its obligations: only queued requests expire.
$script:HostOperationQueuedLifetimeMs = [long]1800000
# Tombstones outlive the longest a remote proof for the same id can stay
# valid (300 s lifetime plus 60 s skew) many times over, so a replayed id is
# answered from its stored outcome instead of being recreated.
$script:HostOperationTombstoneRetentionMs = [long]86400000
$script:HostOperationTombstoneCap         = 512
$script:HostOperationTerminalKeep         = 8
$script:HostOperationMaxAttempts          = 3
$script:HostOperationObservationCap       = 16
# Private copy of the request-id shape Test.HostRepairAuth exports: the spawn
# and admission paths must not depend on the authorization module, and a
# parity test pins the two patterns equal.
$script:HostOperationRequestIdPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'
$script:HostOperationGenerationPattern = '\A[0-9a-f]{32}\z'
# Rung names and orders, and the ceiling of each tier. Test.HostRepair owns
# the ladder declaration; this copy only normalizes a policy's ceiling name,
# and a parity test keeps the two identical.
$script:HostRepairRungOrder = [ordered]@{
    'probe' = 0; 'reclaim' = 1; 'start-if-stopped' = 2; 'restart-if-hung' = 3
    'restart-broker' = 4; 'reapply-settings' = 5; 'reinstall' = 6; 'reboot' = 7
}
$script:HostRepairTierCeiling = @{ restart = 4; full = 6 }
$script:HostRepairVerdictExitCode = @{
    'repaired' = 0; 'already-healthy' = 0; 'preview' = 0; 'disposed' = 0
    'refused' = 1; 'failed' = 1
    'partial' = 2; 'still-unresponsive' = 2; 'abandoned' = 2
}
$script:HostOperationTerminalState = @('completed', 'refused', 'abandoned')
# Test seam: a scratch home directory for the private root. $HOME is fixed at
# process start, so an in-process test cannot redirect it any other way; the
# real root checks still run against the scratch directory.
$script:HostOperationHomePath = $null
# A request row without a kind is a repair. A host update shares the requests
# list, so a process that loaded an older module still keeps the row through a
# rewrite and still blocks on its queued, running and recovery-pending states.
$script:HostRepairKind = 'host-repair'
$script:HostUpdateKind = 'host-update'
$script:HostUpdateBlockSchema = 1
$script:HostUpdateProtocolFile = 'host-update.protocol-version'
$script:HostUpdateControllerLockName = 'host-controller.lock'
$script:HostUpdateControllerDirName = 'host-controller'
$script:HostUpdatePhaseName = @('preflight', 'drain', 'stop_runner', 'update_source', 'install', 'upgrade_pwsh', 'enable', 'start_listener', 'start_runner',
    'restore', 'recover')
$script:HostUpdateVerdict = @('refused', 'drain_timeout', 'stop_failed', 'released', 'superseded', 'failed_restored', 'reboot_required',
    'updated_not_started', 'updated_with_remarks', 'updated')
$script:HostUpdateOperatorAction = @('end_one_shot', 'release_diagnostic_hold', 'provision_elevation', 'retry_or_drain_now', 'stop_runner_by_hand',
    'repair_checkout', 'act_at_host', 'release', 'read_remarks', 'start_runner', 'reboot_host', 'none')
$script:HostUpdateReason = @('lock_unqualified', 'home_unverified', 'runtime_unresolved', 'host_identity_unresolved', 'one_shot_active',
    'diagnostic_hold', 'runner_elevation_missing', 'launch_record_invalid', 'gate_busy', 'drain_timeout', 'runner_identity_unknown',
    'runner_survived', 'pull_failed', 'commit_mismatch', 'protocol_mismatch', 'request_expired', 'runner_start_failed',
    'runner_start_timeout', 'runner_exited', 'config_gate_failed', 'console_state_unknown', 'step_interrupted', 'scope_unavailable',
    'installer_unmarked', 'not_provisioned', 'not_elevated', 'runner_present', 'elevation_rule_refused', 'installer_failed', 'enable_failed',
    'clt_missing', 'session_unusable')
$script:HostUpdateRemark = @('runner_console_unavailable', 'ring_held', 'checkout_pinned', 'no_git_pull', 'listener_disabled',
    'install_issues', 'host_settings_unmet', 'pwsh_upgrade_failed', 'utm_upgrade_deferred', 'brew_update_failed')
# What is still armed at the end is debt, each with the action that settles it.
$script:HostUpdateDebtAction = @{ listener = 'start_listener'; elevation = 'remove_sudo_rule' }
# Only these scalar fields of a step's result file reach the journal: the
# rest of a result (detail, paths, output) stays in the private work folder.
$script:HostUpdateResultField = @('step', 'attempt', 'outcome', 'reason', 'operatorAction', 'protocol', 'runnerConsole', 'restartRequired',
    'pwshChanged', 'pwshUpgradePending', 'installerSha256')

# --- REGION: Private helpers
function Get-HostOperationClockValue {
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

function ConvertTo-HostOperationUtcText {
    <#
    .SYNOPSIS
        ISO-8601 UTC text for a Unix-millisecond instant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][long]$UnixMs)
    return [DateTimeOffset]::FromUnixTimeMilliseconds($UnixMs).UtcDateTime.ToString('o')
}

function ConvertTo-HostOperationList {
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

function ConvertTo-HostOperationStringArray {
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

function Test-HostOperationRequestIdShape {
    <#
    .SYNOPSIS
        True for a canonical lowercase 8-4-4-4-12 request id.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][AllowNull()][string]$RequestId)
    return ([string]$RequestId) -cmatch $script:HostOperationRequestIdPattern
}

function Get-HostOperationProcessStartTime {
    <#
    .SYNOPSIS
        A process's start time in Unix milliseconds, or $null when unreadable.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][int]$ProcessId)
    $start = Get-YurunaProcessStartUtc -ProcessId $ProcessId
    if ($null -eq $start) { return $null }
    return [long][DateTimeOffset]::new($start).ToUnixTimeMilliseconds()
}

function Get-HostOperationProcessLiveness {
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
    return Get-YurunaProcessIdentityLiveness -ProcessId $ProcessId -StartTimeUnixMs $StartTimeUnixMs
}

function Get-HostOperationPrivateFile {
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
    if ($script:HostOperationHomePath) { $arguments.HomePath = $script:HostOperationHomePath }
    $resolved = Get-YurunaPrivateStatePath @arguments
    if ($resolved.Resolved) { return [string]$resolved.Path }
    Write-Verbose "Get-HostOperationPrivateFile: '$Name' unavailable ($($resolved.Reason))."
    return $null
}

function Get-HostRepairPolicyRecord {
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
    if (-not $script:HostRepairTierCeiling.ContainsKey($tier)) { return $null }
    $ceiling = [int]$script:HostRepairTierCeiling[$tier]
    $maxRung = [string]$source['maxRung']
    if ($maxRung) {
        if (-not $script:HostRepairRungOrder.Contains($maxRung)) { return $null }
        $ceiling = [Math]::Min($ceiling, [int]$script:HostRepairRungOrder[$maxRung])
    }
    $ceilingName = @($script:HostRepairRungOrder.Keys | Where-Object { $script:HostRepairRungOrder[$_] -eq $ceiling })[0]
    $sorted = {
        param($Value)
        $names = [System.Collections.Generic.List[string]]::new()
        foreach ($name in (ConvertTo-HostOperationStringArray -Value $Value)) { if (-not $names.Contains($name)) { $names.Add($name) } }
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

function Get-HostRepairPolicyHash {
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

function New-HostOperationJournalDocument {
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
        schemaVersion = $script:HostOperationJournalSchema
        writtenUtc    = $null
        owner         = $null
        requests      = [System.Collections.Generic.List[object]]::new()
        reservations  = [System.Collections.Generic.List[object]]::new()
        tombstones    = [System.Collections.Generic.List[object]]::new()
    }
}

function ConvertTo-HostOperationJournal {
    <#
    .SYNOPSIS
        Normalize a parsed journal payload: every collection becomes a list,
        at every level the code later mutates.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Payload)
    $journal = New-HostOperationJournalDocument
    $journal.writtenUtc = $Payload['writtenUtc']
    if ($Payload['owner'] -is [System.Collections.IDictionary]) { $journal.owner = $Payload['owner'] }
    foreach ($request in (ConvertTo-HostOperationList -Value $Payload['requests'])) {
        if ($request -isnot [System.Collections.IDictionary]) { continue }
        $request['attempts'] = ConvertTo-HostOperationList -Value $request['attempts']
        foreach ($attempt in $request['attempts']) {
            if ($attempt -is [System.Collections.IDictionary]) {
                $attempt['reasonCodes'] = ConvertTo-HostOperationStringArray -Value $attempt['reasonCodes']
                $attempt['rungs'] = [object[]](ConvertTo-HostOperationList -Value $attempt['rungs']).ToArray()
            }
        }
        $request['obligations'] = ConvertTo-HostOperationList -Value $request['obligations']
        $request['reasonCodes'] = ConvertTo-HostOperationStringArray -Value $request['reasonCodes']
        if ($request['policy'] -is [System.Collections.IDictionary]) {
            $request['policy']['restoreServiceVmName'] = ConvertTo-HostOperationStringArray -Value $request['policy']['restoreServiceVmName']
            $request['policy']['leaveStoppedServiceVmName'] = ConvertTo-HostOperationStringArray -Value $request['policy']['leaveStoppedServiceVmName']
        }
        if ($request['recovery'] -is [System.Collections.IDictionary]) {
            $request['recovery']['observations'] = ConvertTo-HostOperationList -Value $request['recovery']['observations']
        }
        $journal.requests.Add($request)
    }
    foreach ($reservation in (ConvertTo-HostOperationList -Value $Payload['reservations'])) {
        if ($reservation -is [System.Collections.IDictionary]) { $journal.reservations.Add($reservation) }
    }
    foreach ($tombstone in (ConvertTo-HostOperationList -Value $Payload['tombstones'])) {
        if ($tombstone -is [System.Collections.IDictionary]) { $journal.tombstones.Add($tombstone) }
    }
    return $journal
}

function Read-HostOperationJournalCore {
    <#
    .SYNOPSIS
        Read and classify the journal record without any lock.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$JournalPath)
    $result = [ordered]@{ Status = 'unreadable'; Journal = $null; Generation = [long]0; Reason = $null }
    $record = Read-YurunaCriticalRecord -Path $JournalPath -Kind $script:HostOperationJournalKind -MaxBytes $script:HostOperationJournalMaxBytes
    switch ($record.Status) {
        'ok' {
            $payload = $record.Payload
            $schema = 0
            if ($payload -is [System.Collections.IDictionary]) { [void][int]::TryParse("$($payload['schemaVersion'])", [ref]$schema) }
            if ($schema -gt $script:HostOperationJournalSchema) {
                $result.Status = 'unknown-version'; $result.Reason = 'newer-schema'
            } elseif ($schema -ne $script:HostOperationJournalSchema) {
                $result.Status = 'corrupt'; $result.Reason = 'schema-mismatch'
            } else {
                $result.Journal = ConvertTo-HostOperationJournal -Payload $payload
                $result.Generation = [long]$record.Generation
                $result.Status = if ($record.Degraded) { 'recovered-previous' } else { 'ok' }
                $result.Reason = if ($record.Degraded) { [string]$record.CurrentReason } else { 'ok' }
            }
        }
        'missing' { $result.Status = 'absent'; $result.Reason = 'absent' }
        'unsupported-version' { $result.Status = 'unknown-version'; $result.Reason = 'unsupported-version' }
        'corrupt' { $result.Status = 'corrupt'; $result.Reason = 'corrupt' }
        'kind-mismatch' { $result.Status = 'corrupt'; $result.Reason = 'kind-mismatch' }
        default { $result.Status = 'unreadable'; $result.Reason = [string]$record.Status }
    }
    return [pscustomobject]$result
}

function Save-HostOperationJournal {
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
        schemaVersion = $script:HostOperationJournalSchema
        writtenUtc    = $Journal.writtenUtc
        owner         = $Journal.owner
        requests      = [object[]]@($Journal.requests)
        reservations  = [object[]]@($Journal.reservations)
        tombstones    = [object[]]@($Journal.tombstones)
    }
    $write = Write-YurunaCriticalRecord -Path $JournalPath -Kind $script:HostOperationJournalKind -Payload $payload `
        -ExpectedGeneration $ExpectedGeneration -MaxBytes $script:HostOperationJournalMaxBytes -Confirm:$false
    return [pscustomobject]@{
        Committed  = [bool]$write.Committed
        Durable    = ([bool]$write.Committed -and [bool]$write.FlushesConfirmed)
        Generation = [long]$write.Generation
        Reason     = [string]$write.Reason
    }
}

function Find-HostOperationRequest {
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

function Find-HostOperationTombstone {
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

function Get-HostOperationRequestKind {
    <#
    .SYNOPSIS
        The kind of a request row or tombstone; one that names none is a
        repair.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][System.Collections.IDictionary]$Record)
    if ($null -ne $Record -and [string]$Record['kind']) { return [string]$Record['kind'] }
    return $script:HostRepairKind
}

function Get-HostOperationGateHolderKind {
    <#
    .SYNOPSIS
        The kind of the request a closed gate names: its row, else its
        tombstone, else a repair.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Journal, [AllowNull()][AllowEmptyString()][string]$RequestId)
    if ($RequestId) {
        $row = Find-HostOperationRequest -Journal $Journal -RequestId $RequestId
        if ($row) { return (Get-HostOperationRequestKind -Record $row) }
        $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $RequestId
        if ($tombstone) { return (Get-HostOperationRequestKind -Record $tombstone) }
    }
    return $script:HostRepairKind
}

function Get-HostRepairLastAttempt {
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

function Get-HostOperationArmedObligation {
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

function Test-HostOperationRequestBlocking {
    <#
    .SYNOPSIS
        True when a request keeps any other request (and a start-cycle) out:
        an unexpired queued request, a queued one that took over armed
        obligations (it never expires), a running or recovery-pending one, or
        an abandoned one that still owes an obligation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request, [Parameter(Mandatory)][long]$NowUnixMs)
    switch ([string]$Request['state']) {
        'queued' {
            if (@(Get-HostOperationArmedObligation -Request $Request).Count -gt 0) { return $true }
            return (-not (Test-HostOperationQueuedExpired -Request $Request -NowUnixMs $NowUnixMs))
        }
        'running' { return $true }
        'recovery-pending' { return $true }
        'abandoned' { return (@(Get-HostOperationArmedObligation -Request $Request).Count -gt 0) }
        default { return $false }
    }
}

function Test-HostOperationQueuedExpired {
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
    return (($NowUnixMs - $created) -ge $script:HostOperationQueuedLifetimeMs)
}

function Get-HostOperationBlockingRequest {
    <#
    .SYNOPSIS
        The one request that blocks new work, or $null.
    .DESCRIPTION
        Every kind blocks new work of every kind; -Kind narrows the answer to
        rows of one kind, for a caller that may act only on its own.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][long]$NowUnixMs,
        [ValidateSet('any', 'host-repair', 'host-update')][string]$Kind = 'any'
    )
    foreach ($request in $Journal.requests) {
        if ($Kind -ne 'any' -and (Get-HostOperationRequestKind -Record $request) -cne $Kind) { continue }
        if (Test-HostOperationRequestBlocking -Request $request -NowUnixMs $NowUnixMs) { return $request }
    }
    return $null
}

function Get-HostOperationQueuedLaunchLiveness {
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
                (Get-HostOperationProcessLiveness -ProcessId $launch['launcherPid'] -StartTimeUnixMs $launch['launcherStartTimeUnixMs'])
            )
            if ($launch['workerPid']) {
                $states += (Get-HostOperationProcessLiveness -ProcessId $launch['workerPid'] -StartTimeUnixMs $launch['workerStartTimeUnixMs'])
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
            return (Get-HostOperationProcessLiveness -ProcessId $launch['requesterPid'] -StartTimeUnixMs $launch['requesterStartTimeUnixMs'])
        }
    }
}

function Get-HostOperationReservationLiveness {
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
        return (Get-HostOperationProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs'])
    }
    return (Get-HostOperationQueuedLaunchLiveness -Request $Reservation)
}

function Set-HostOperationRequestTerminal {
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
    $retainUntil = [long]$Clock.UnixMs + $script:HostOperationTombstoneRetentionMs
    for ($i = $Journal.tombstones.Count - 1; $i -ge 0; $i--) {
        if ([string]$Journal.tombstones[$i]['requestId'] -ceq [string]$Request['requestId']) { $Journal.tombstones.RemoveAt($i) }
    }
    $tombstone = [ordered]@{
        requestId         = [string]$Request['requestId']
        state             = $State
        verdict           = $Verdict
        policyHash        = [string]$Request['policyHash']
        terminalUtc       = $Clock.Utc
        terminalUnixMs    = $Clock.UnixMs
        retainUntilUtc    = (ConvertTo-HostOperationUtcText -UnixMs $retainUntil)
        retainUntilUnixMs = $retainUntil
    }
    # Every terminal path, housekeeping's expiry included, keeps the kind, so
    # a replayed id is answered by its own kind after the row is trimmed.
    if ([string]$Request['kind']) { $tombstone['kind'] = [string]$Request['kind'] }
    $Journal.tombstones.Add($tombstone)
    Limit-HostOperationTerminalRecord -Journal $Journal
}

function Limit-HostOperationTerminalRecord {
    <#
    .SYNOPSIS
        Keep the full records of only the newest terminal requests; their
        tombstones remain.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Journal)
    $terminal = @($Journal.requests | Where-Object {
            [string]$_['state'] -in $script:HostOperationTerminalState -and @(Get-HostOperationArmedObligation -Request $_).Count -eq 0
        } | Sort-Object { [long]$_['terminalUnixMs'] } -Descending)
    if ($terminal.Count -le $script:HostOperationTerminalKeep) { return }
    foreach ($old in $terminal[$script:HostOperationTerminalKeep..($terminal.Count - 1)]) { [void]$Journal.requests.Remove($old) }
}

function Update-HostOperationJournalHousekeeping {
    <#
    .SYNOPSIS
        Expire unclaimed queued requests, prune expired tombstones and clear
        start-cycle reservations whose owner is positively dead.
    .DESCRIPTION
        Runs inside every locked transaction. A clock behind a record's time
        never expires or prunes it. A queued request that took over armed
        obligations (a host update that superseded a recovering one) never
        expires: the gate it holds closed has no other owner, so it waits for
        a controller to claim it. Returns $true when anything changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates an in-memory journal only; the caller persists it under its own ShouldProcess.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)]$Clock)
    $changed = $false
    foreach ($request in @($Journal.requests)) {
        if ([string]$request['state'] -eq 'queued' -and (Test-HostOperationQueuedExpired -Request $request -NowUnixMs $Clock.UnixMs) -and
            @(Get-HostOperationArmedObligation -Request $request).Count -eq 0) {
            $request['reasonCodes'] = [string[]]@('request-expired')
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict 'refused' -Clock $Clock
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
        if ((Get-HostOperationReservationLiveness -Reservation $Journal.reservations[$i]) -eq 'dead') {
            $Journal.reservations.RemoveAt($i)
            $changed = $true
        }
    }
    return $changed
}

function Invoke-HostOperationJournalTransaction {
    <#
    .SYNOPSIS
        Run one read-modify-write of the journal under the admission lock.
    .DESCRIPTION
        Takes the admission lock (or validates a lock the caller already
        holds), reads the journal, runs the housekeeping sweep, then invokes
        Body with the journal and the clock.
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
    $txJournalPath = Get-HostOperationPrivateFile -Name $script:HostOperationJournalName
    $txLockPath = Get-HostOperationPrivateFile -Name $script:HostOperationAdmissionName
    if (-not $txJournalPath -or -not $txLockPath) { $txEnvelope.Reason = 'private-root-unavailable'; return [pscustomobject]$txEnvelope }
    $txOwnLock = $null
    if ($null -ne $AdmissionLock) {
        if (-not (Test-YurunaSingleFlightLockOwned -Lock $AdmissionLock -Path $txLockPath)) {
            $txEnvelope.Reason = 'admission-lock-not-held'
            return [pscustomobject]$txEnvelope
        }
    } else {
        $txOwnLock = Enter-YurunaSingleFlightLock -Path $txLockPath -WaitMilliseconds $AdmissionWaitMilliseconds `
            -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-operation-admission' }
        if (-not $txOwnLock.Held) {
            $txEnvelope.Reason = if ($txOwnLock.Reason -eq 'held-elsewhere') { 'admission-busy' } else { "admission-lock-$($txOwnLock.Reason)" }
            return [pscustomobject]$txEnvelope
        }
    }
    try {
        $txClock = Get-HostOperationClockValue -UtcNow $UtcNow
        $txRead = Read-HostOperationJournalCore -JournalPath $txJournalPath
        $txEnvelope.ReadStatus = $txRead.Status
        if ($txRead.Status -eq 'absent') {
            $txJournal = New-HostOperationJournalDocument
            $txGeneration = [long]0
        } elseif ($txRead.Status -in @('ok', 'recovered-previous')) {
            $txJournal = $txRead.Journal
            $txGeneration = [long]$txRead.Generation
        } else {
            $txEnvelope.Reason = "journal-$($txRead.Status)"
            return [pscustomobject]$txEnvelope
        }
        $txHousekeeping = Update-HostOperationJournalHousekeeping -Journal $txJournal -Clock $txClock
        $txOutcome = & $Body $txJournal $txClock $Arguments
        $txEnvelope.Ran = $true
        $txEnvelope.Result = $txOutcome.Result
        $txChanged = [bool]$txOutcome.Changed -or $txHousekeeping
        if ($txChanged) {
            $txSave = Save-HostOperationJournal -JournalPath $txJournalPath -Journal $txJournal -ExpectedGeneration $txGeneration -NowUtc $txClock.Utc -Confirm:$false
            $txEnvelope.Committed = $txSave.Committed
            $txEnvelope.Durable = $txSave.Durable
            if (-not $txSave.Committed) {
                $txEnvelope.Reason = "journal-write-$($txSave.Reason)"
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

function New-HostRepairAttemptRecord {
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

function New-HostRepairRequestRecord {
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
        expiresUnixMs = [long]$Clock.UnixMs + $script:HostOperationQueuedLifetimeMs
        policy        = $Policy
        policyHash    = (Get-HostRepairPolicyHash -Policy $Policy)
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

function Get-HostOperationOwnProcess {
    <#
    .SYNOPSIS
        This process's identity: pid and start time.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return [ordered]@{ pid = $PID; startTimeUnixMs = (Get-HostOperationProcessStartTime -ProcessId $PID) }
}

function Test-HostOperationSameRuntime {
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

function Get-HostOperationGateView {
    <#
    .SYNOPSIS
        The runner gate as admission needs it, resolved by name.
    .DESCRIPTION
        The gate lives in the runner-protocol module. When its reader is not
        loaded, admission cannot tell whether a handoff or a crashed repair
        still holds the runner, so it answers unavailable rather than guess.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RuntimeDir)
    $reader = Get-Command -Name 'Get-YurunaRunnerGateState' -CommandType Function -ErrorAction SilentlyContinue
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
        Write-Verbose "Get-HostOperationGateView: gate read failed: $($_.Exception.Message)"
        return [pscustomobject]@{ Known = $false; Open = $false; State = 'unknown'; RequestId = $null; Reason = 'gate-read-failed' }
    }
}

function Resolve-HostRepairAdmissionDecision {
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
    $policyHash = Get-HostRepairPolicyHash -Policy $Policy
    if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir'] -and
        -not (Test-HostOperationSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right $RuntimeDir)) {
        $decision.Reason = 'runtime-owner-mismatch'
        return [pscustomobject]$decision
    }
    $existing = Find-HostOperationRequest -Journal $Journal -RequestId $RequestId
    if ($existing) {
        $decision.State = [string]$existing['state']
        $decision.Verdict = $existing['verdict']
        $decision.Attempt = [int]$existing['attempt']
        $decision.Ceiling = [string]$existing['policy']['maxRung']
        # Channel and host are as immutable as the policy: the same id arriving
        # another way is a different request, never a replay.
        if ((Get-HostOperationRequestKind -Record $existing) -cne $script:HostRepairKind -or
            [string]$existing['policyHash'] -ne $policyHash -or [string]$existing['channel'] -ne $Channel -or
            [string]$existing['hostType'] -ne $HostType) {
            $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch'; return [pscustomobject]$decision
        }
        switch ([string]$existing['state']) {
            'completed' { $decision.Decision = 'completed'; $decision.Reason = 'completed' }
            'refused' { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
            'abandoned' { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
            'recovery-pending' { $decision.Decision = 'spawn'; $decision.Reason = 'recovery-pending'; $decision.Action = 'relaunch' }
            'queued' {
                $liveness = Get-HostOperationQueuedLaunchLiveness -Request $existing
                if ($liveness -eq 'dead') { $decision.Decision = 'spawn'; $decision.Reason = 'launch-not-running'; $decision.Action = 'relaunch' }
                else { $decision.Decision = 'already-claimed'; $decision.Reason = "launcher-$liveness" }
            }
            'running' {
                $last = Get-HostRepairLastAttempt -Request $existing
                $worker = if ($last) { $last['worker'] } else { $null }
                $liveness = if ($worker -is [System.Collections.IDictionary]) { Get-HostOperationProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs'] } else { 'unknown' }
                if ($liveness -eq 'dead') { $decision.Decision = 'spawn'; $decision.Reason = 'worker-dead'; $decision.Action = 'relaunch' }
                else { $decision.Decision = 'already-claimed'; $decision.Reason = "worker-$liveness" }
            }
            default { $decision.Reason = 'state-unknown' }
        }
        return [pscustomobject]$decision
    }
    $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $RequestId
    if ($tombstone) {
        $decision.State = [string]$tombstone['state']
        $decision.Verdict = $tombstone['verdict']
        if ((Get-HostOperationRequestKind -Record $tombstone) -cne $script:HostRepairKind -or [string]$tombstone['policyHash'] -ne $policyHash) {
            $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch'
        }
        elseif ([string]$tombstone['state'] -eq 'completed') { $decision.Decision = 'completed'; $decision.Reason = 'completed' }
        else { $decision.Decision = 'stored'; $decision.Reason = 'stored' }
        return [pscustomobject]$decision
    }
    foreach ($reservation in $Journal.reservations) {
        $decision.Decision = 'busy'; $decision.ActiveKind = 'start-cycle'
        $decision.ActiveRequestId = [string]$reservation['operationId']; $decision.Reason = 'start-cycle-active'
        return [pscustomobject]$decision
    }
    $blocking = Get-HostOperationBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
    if ($blocking) {
        $decision.Decision = 'busy'; $decision.ActiveKind = Get-HostOperationRequestKind -Record $blocking
        $decision.ActiveRequestId = [string]$blocking['requestId']; $decision.Reason = 'host-operation-active'
        $decision.State = [string]$blocking['state']
        return [pscustomobject]$decision
    }
    $gate = Get-HostOperationGateView -RuntimeDir $RuntimeDir
    if (-not $gate.Known) { $decision.Reason = $gate.Reason; if (-not $decision.Reason) { $decision.Reason = 'gate-unknown' }; return [pscustomobject]$decision }
    if (-not $gate.Open) {
        $decision.Decision = 'busy'; $decision.ActiveKind = Get-HostOperationGateHolderKind -Journal $Journal -RequestId $gate.RequestId
        $decision.ActiveRequestId = $gate.RequestId; $decision.Reason = "gate-$($gate.State)"
        return [pscustomobject]$decision
    }
    if ($Journal.tombstones.Count -ge $script:HostOperationTombstoneCap) { $decision.Reason = 'journal-full'; return [pscustomobject]$decision }
    $decision.Decision = 'spawn'; $decision.Reason = 'new-request'; $decision.Action = 'create'
    return [pscustomobject]$decision
}

function ConvertTo-HostRepairAdmissionRecord {
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

function Get-HostUpdatePolicyHash {
    <#
    .SYNOPSIS
        SHA-256 hex of a host update's request fields.
    .DESCRIPTION
        The text starts with the kind, so it never equals a repair's hash: a
        process that predates host updates answers a reused id as a policy
        mismatch instead of replaying it as a repair.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Drain,
        [Parameter(Mandatory)][int]$DrainSeconds,
        [AllowNull()][AllowEmptyString()][string]$ExpectCommit
    )
    $text = '{0}|{1}|{2}|{3}|{4}' -f $script:HostUpdateKind, $Scope, $Drain, $DrainSeconds.ToString([cultureinfo]::InvariantCulture), [string]$ExpectCommit
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
    return ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function New-HostUpdateRequestRecord {
    <#
    .SYNOPSIS
        A new queued host-update row for the journal.
    .DESCRIPTION
        The request lives in its own update block. Its policy names only the
        kind, so an older reader that indexes a repair policy key reads $null
        instead of failing.
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
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Drain,
        [Parameter(Mandatory)][int]$DrainSeconds,
        [AllowNull()][AllowEmptyString()][string]$ExpectCommit,
        [Parameter(Mandatory)]$Clock
    )
    $expect = if ($ExpectCommit) { $ExpectCommit } else { $null }
    return [ordered]@{
        requestId      = $RequestId
        kind           = $script:HostUpdateKind
        channel        = $Channel
        runtimeDir     = $RuntimeDir
        hostType       = $HostType
        createdUtc     = $Clock.Utc
        createdUnixMs  = $Clock.UnixMs
        expiresUnixMs  = [long]$Clock.UnixMs + $script:HostOperationQueuedLifetimeMs
        policy         = [ordered]@{ kind = $script:HostUpdateKind }
        policyHash     = (Get-HostUpdatePolicyHash -Scope $Scope -Drain $Drain -DrainSeconds $DrainSeconds -ExpectCommit $expect)
        context        = [ordered]@{ configPath = $null; callerOuter = $null; trigger = $null }
        state          = 'queued'
        attempt        = 0
        launch         = $null
        attempts       = [System.Collections.Generic.List[object]]::new()
        recovery       = $null
        obligations    = [System.Collections.Generic.List[object]]::new()
        callerAck      = $null
        verdict        = $null
        operatorAction = $null
        reasonCodes    = [string[]]@()
        terminalUtc    = $null
        terminalUnixMs = $null
        update         = [ordered]@{
            schemaVersion          = $script:HostUpdateBlockSchema
            request                = [ordered]@{ scope = $Scope; drain = $Drain; drainSeconds = $DrainSeconds; expectCommit = $expect }
            claimBlocked           = $null
            controller             = $null
            claimedUtc             = $null
            bootEpochMs            = $null
            phase                  = $null
            phases                 = [ordered]@{}
            drain                  = $null
            runnerPlan             = $null
            reclaimed              = [ordered]@{ outer = $null; cycle = $null; inner = $null }
            commit                 = [ordered]@{ before = $null; after = $null; resident = $null }
            runnerConsole          = $null
            consoleSeq             = 0
            remarks                = [string[]]@()
            debt                   = [object[]]@()
            mutated                = $false
            recovering             = $null
            release                = $null
            supersededBy           = $null
            inheritedFrom          = $null
            inheritedGateRequestId = $null
            verdict                = $null
            operatorAction         = $null
            reason                 = $null
            firstCycle             = $null
        }
    }
}

function Resolve-HostUpdateAdmissionDecision {
    <#
    .SYNOPSIS
        The pure host-update admission decision over a journal already read
        under the admission lock.
    .DESCRIPTION
        Every kind blocks every other: a host update is busy while a repair,
        a start-cycle or another host update holds the host or the gate is
        closed. The one exception is a host update that is recovering and
        nothing else holds the host: a new one takes it over (Takeover names
        the row), so a host whose runner will not start can be pressed again.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][hashtable]$Journal, [Parameter(Mandatory)][hashtable]$Arguments, [Parameter(Mandatory)]$Clock)
    $A = $Arguments
    $decision = [ordered]@{
        Decision = 'unavailable'; RequestId = $A.RequestId; State = $null; Verdict = $null; ActiveKind = ''; ActiveRequestId = $null
        SupersededId = $null; Reason = $null; Takeover = $null; GateRequestId = $null
    }
    # Ending a running cycle is for the host command alone, as a repair's
    # local-only switches are.
    if ($A.Drain -eq 'now' -and $A.Channel -ne 'local') { $decision.Decision = 'policy-invalid'; $decision.Reason = 'policy-invalid'; return [pscustomobject]$decision }
    if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir'] -and
        -not (Test-HostOperationSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right $A.RuntimeDir)) {
        $decision.Reason = 'runtime-owner-mismatch'
        return [pscustomobject]$decision
    }
    $existing = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
    if ($existing) {
        $decision.State = [string]$existing['state']
        $decision.Verdict = $existing['verdict']
        if ((Get-HostOperationRequestKind -Record $existing) -cne $script:HostUpdateKind -or [string]$existing['policyHash'] -ne $A.PolicyHash -or
            [string]$existing['channel'] -ne $A.Channel -or [string]$existing['hostType'] -ne $A.HostType) {
            $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch'
        } elseif ($decision.State -in @('queued', 'running', 'recovery-pending')) {
            $decision.Decision = 'already-active'; $decision.Reason = 'already-active'
        } elseif ($decision.State -in $script:HostOperationTerminalState) {
            $decision.Decision = 'completed'; $decision.Reason = 'completed'
        } else {
            $decision.Reason = 'state-unknown'
        }
        return [pscustomobject]$decision
    }
    $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId
    if ($tombstone) {
        $decision.State = [string]$tombstone['state']
        $decision.Verdict = $tombstone['verdict']
        if ((Get-HostOperationRequestKind -Record $tombstone) -cne $script:HostUpdateKind -or [string]$tombstone['policyHash'] -ne $A.PolicyHash) {
            $decision.Decision = 'policy-mismatch'; $decision.Reason = 'policy-mismatch'
        } else {
            $decision.Decision = 'completed'; $decision.Reason = 'completed'
        }
        return [pscustomobject]$decision
    }
    foreach ($reservation in $Journal.reservations) {
        $decision.Decision = 'busy'; $decision.ActiveKind = 'start-cycle'
        $decision.ActiveRequestId = [string]$reservation['operationId']; $decision.Reason = 'start-cycle-active'
        return [pscustomobject]$decision
    }
    $blocking = @($Journal.requests | Where-Object { Test-HostOperationRequestBlocking -Request $_ -NowUnixMs $Clock.UnixMs })
    if ($blocking.Count -gt 0) {
        $first = $blocking[0]
        if ($blocking.Count -eq 1 -and (Get-HostOperationRequestKind -Record $first) -ceq $script:HostUpdateKind -and [string]$first['state'] -eq 'recovery-pending') {
            $gate = Get-HostOperationGateView -RuntimeDir $A.RuntimeDir
            if (-not $gate.Known) { $decision.Reason = if ($gate.Reason) { $gate.Reason } else { 'gate-unknown' }; return [pscustomobject]$decision }
            # The gate may still name the row this one inherited from, until
            # its controller re-stamps it.
            $firstUpdate = if ($first['update'] -is [System.Collections.IDictionary]) { $first['update'] } else { @{} }
            $gateHolders = @(@([string]$first['requestId'], [string]$firstUpdate['inheritedGateRequestId']) | Where-Object { $_ })
            if ($gate.Open -or $gateHolders -ccontains [string]$gate.RequestId) {
                if ($Journal.tombstones.Count -ge $script:HostOperationTombstoneCap) { $decision.Reason = 'journal-full'; return [pscustomobject]$decision }
                $decision.Decision = 'taken-over'; $decision.Reason = 'taken-over'; $decision.State = 'queued'
                $decision.SupersededId = [string]$first['requestId']; $decision.Takeover = $first
                $decision.GateRequestId = if ($gate.Open) { [string]$first['requestId'] } else { [string]$gate.RequestId }
                return [pscustomobject]$decision
            }
        }
        $decision.Decision = 'busy'; $decision.ActiveKind = Get-HostOperationRequestKind -Record $first
        $decision.ActiveRequestId = [string]$first['requestId']; $decision.State = [string]$first['state']
        $decision.Reason = "$($decision.ActiveKind)-active"
        return [pscustomobject]$decision
    }
    $gate = Get-HostOperationGateView -RuntimeDir $A.RuntimeDir
    if (-not $gate.Known) { $decision.Reason = if ($gate.Reason) { $gate.Reason } else { 'gate-unknown' }; return [pscustomobject]$decision }
    if (-not $gate.Open) {
        $decision.Decision = 'busy'; $decision.ActiveKind = Get-HostOperationGateHolderKind -Journal $Journal -RequestId $gate.RequestId
        $decision.ActiveRequestId = $gate.RequestId; $decision.Reason = "gate-$($gate.State)"
        return [pscustomobject]$decision
    }
    if ($Journal.tombstones.Count -ge $script:HostOperationTombstoneCap) { $decision.Reason = 'journal-full'; return [pscustomobject]$decision }
    $decision.Decision = 'queued'; $decision.Reason = 'new-request'; $decision.State = 'queued'
    return [pscustomobject]$decision
}

function Get-HostUpdateBlock {
    <#
    .SYNOPSIS
        A host-update row's update block, created when a rewrite lost it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    if ($Request['update'] -isnot [System.Collections.IDictionary]) { $Request['update'] = [ordered]@{ schemaVersion = $script:HostUpdateBlockSchema } }
    return $Request['update']
}

function Add-HostUpdateToken {
    <#
    .SYNOPSIS
        A token list with new tokens appended once each, in order.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([AllowNull()]$Existing, [AllowNull()][string[]]$Token)
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($item in (ConvertTo-HostOperationStringArray -Value $Existing)) { if (-not $list.Contains($item)) { $list.Add($item) } }
    foreach ($item in @($Token)) { if ($item -and -not $list.Contains($item)) { $list.Add($item) } }
    return , [string[]]$list.ToArray()
}

function Add-HostUpdateDebt {
    <#
    .SYNOPSIS
        A debt list with a row for each named obligation, once each.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()]$Existing, [AllowNull()][string[]]$ObligationId)
    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.List[string]]::new()
    foreach ($row in (ConvertTo-HostOperationList -Value $Existing)) {
        if ($row -is [System.Collections.IDictionary] -and $row['obligation'] -and -not $seen.Contains([string]$row['obligation'])) {
            $seen.Add([string]$row['obligation']); $rows.Add($row)
        }
    }
    foreach ($id in @($ObligationId)) {
        if (-not $id -or $seen.Contains($id) -or -not $script:HostUpdateDebtAction.ContainsKey($id)) { continue }
        $seen.Add($id)
        $rows.Add([ordered]@{ obligation = $id; action = $script:HostUpdateDebtAction[$id] })
    }
    return , [object[]]$rows.ToArray()
}

function ConvertTo-HostUpdateIdentity {
    <#
    .SYNOPSIS
        { pid; startTimeUnixMs } from a recorded identity, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()]$Identity)
    if ($null -eq $Identity) { return $null }
    $processId = if ($Identity -is [System.Collections.IDictionary]) { $Identity['pid'] } else { $Identity.pid }
    $start = if ($Identity -is [System.Collections.IDictionary]) { $Identity['startTimeUnixMs'] } else { $Identity.startTimeUnixMs }
    $parsedPid = 0; $parsedStart = [long]0
    if (-not [int]::TryParse("$processId", [ref]$parsedPid) -or $parsedPid -le 0) { return $null }
    $startValue = if ([long]::TryParse("$start", [ref]$parsedStart)) { $parsedStart } else { $null }
    return [ordered]@{ pid = $parsedPid; startTimeUnixMs = $startValue }
}

function Complete-HostUpdateRow {
    <#
    .SYNOPSIS
        Write a host update's verdict into its row and make the row terminal.
    .DESCRIPTION
        refused ends in the state refused, every other verdict in completed,
        never abandoned: that state carries the repair's attempt cap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Journal,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Request,
        [Parameter(Mandatory)][string]$Verdict,
        [Parameter(Mandatory)][string]$OperatorAction,
        [AllowNull()][AllowEmptyString()][string]$Reason,
        [AllowNull()][string[]]$Remarks,
        [AllowNull()][string[]]$Debt,
        [Parameter(Mandatory)]$Clock
    )
    $update = Get-HostUpdateBlock -Request $Request
    $update['verdict'] = $Verdict
    $update['operatorAction'] = $OperatorAction
    $update['reason'] = if ($Reason) { $Reason } else { $null }
    if (@($Remarks | Where-Object { $_ }).Count -gt 0) { $update['remarks'] = Add-HostUpdateToken -Existing $update['remarks'] -Token $Remarks }
    if (@($Debt | Where-Object { $_ }).Count -gt 0) { $update['debt'] = Add-HostUpdateDebt -Existing $update['debt'] -ObligationId $Debt }
    $Request['operatorAction'] = $OperatorAction
    if ($Reason) { $Request['reasonCodes'] = [string[]]@($Reason) }
    $state = if ($Verdict -ceq 'refused') { 'refused' } else { 'completed' }
    Set-HostOperationRequestTerminal -Journal $Journal -Request $Request -State $state -Verdict $Verdict -Clock $Clock
}

function Invoke-HostUpdateRowChange {
    <#
    .SYNOPSIS
        One journal change on a host-update row in an allowed state, made
        only by the controller the row names.
    .DESCRIPTION
        Change is param($Journal, $Clock, $Arguments, $Request) and returns
        @{ Changed; Reason; Value } or @{ Refused = <reason> }. With
        -ControllerPid 0 the ownership check is skipped, for a caller that
        acts without a controller.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason; Value; Row }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][int]$ControllerPid,
        [Parameter(Mandatory)][scriptblock]$Change,
        [hashtable]$Arguments = @{},
        [string[]]$AllowedState = @('running', 'recovery-pending'),
        [scriptblock]$UtcNow
    )
    $bodyArguments = @{ RequestId = $RequestId; ControllerPid = $ControllerPid; Change = $Change; Inner = $Arguments; AllowedState = $AllowedState }
    $body = {
        param($Journal, $Clock, $A)
        $refusal = { param([string]$Why, $Row) @{ Changed = $false; Result = [pscustomobject]@{ Written = $false; Reason = $Why; Value = $null; Row = $Row } } }
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return (& $refusal 'no-request' $null) }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostUpdateKind) { return (& $refusal 'refused-other-kind' $null) }
        if ([string]$request['state'] -notin $A.AllowedState) { return (& $refusal 'state-mismatch' $request) }
        if ($A.ControllerPid -ne 0) {
            $controller = (Get-HostUpdateBlock -Request $request)['controller']
            if ($controller -isnot [System.Collections.IDictionary] -or "$($controller['pid'])" -cne "$($A.ControllerPid)") { return (& $refusal 'not-owner' $request) }
        }
        $outcome = & $A.Change $Journal $Clock $A.Inner $request
        if ($outcome.Refused) { return (& $refusal ([string]$outcome.Refused) $request) }
        @{ Changed = [bool]$outcome.Changed; Result = [pscustomobject]@{ Written = $true; Reason = [string]$outcome.Reason; Value = $outcome.Value; Row = $request } }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Written = $false; Reason = $run.Reason; Value = $null; Row = $null } }
    if (-not $run.Result.Written) { return $run.Result }
    if (-not $run.Committed) { return [pscustomobject]@{ Written = $false; Reason = $run.Reason; Value = $null; Row = $null } }
    return $run.Result
}

# --- REGION: Public: paths and ids
function Get-HostOperationPrivateRoot {
    <#
    .SYNOPSIS
        The private state root record every host-operation channel uses.
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
    if ($script:HostOperationHomePath) { $arguments.HomePath = $script:HostOperationHomePath }
    return (Get-YurunaPrivateStateRoot @arguments)
}

function Get-YurunaHostRepairRequestPath {
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
    return (Get-HostOperationPrivateFile -Name $script:HostOperationJournalName -NoCreate:$NoCreate)
}

function Get-YurunaHostOperationLockPath {
    <#
    .SYNOPSIS
        The lifetime host-operation lock path under the private state root.
    .PARAMETER NoCreate
        Observe only: $null when the root does not exist yet.
    .OUTPUTS
        [string] or $null when the root cannot be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    return (Get-HostOperationPrivateFile -Name $script:HostOperationLockName -NoCreate:$NoCreate)
}

function Get-YurunaHostOperationAdmissionLockPath {
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
    return (Get-HostOperationPrivateFile -Name $script:HostOperationAdmissionName -NoCreate:$NoCreate)
}

function Get-HostRepairPrivateWorkDir {
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
    $leaf = Get-HostOperationPrivateFile -Name 'stdin.empty' -Subdirectory $script:HostRepairWorkDirName -NoCreate:$NoCreate
    if (-not $leaf) { return $null }
    return [System.IO.Path]::GetDirectoryName($leaf)
}

function New-YurunaHostOperationRequestId {
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
function Read-HostOperationJournal {
    <#
    .SYNOPSIS
        Lock-free read of the request journal.
    .DESCRIPTION
        A reader never mutates anything.
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
        $root = Get-HostOperationPrivateRoot -NoCreate
        if (-not $root.Resolved) {
            $status = if ($root.Reason -eq 'absent') { 'absent' } else { 'unreadable' }
            return [pscustomobject]@{ Status = $status; Journal = $null; Generation = [long]0; Reason = [string]$root.Reason }
        }
        $JournalPath = Join-Path $root.Path $script:HostOperationJournalName
    }
    return (Read-HostOperationJournalCore -JournalPath $JournalPath)
}

function Read-YurunaHostRepairRequest {
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
    $read = if ($Path) { Read-HostOperationJournal -JournalPath $Path } else { Read-HostOperationJournal }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return $null }
    return (Find-HostOperationRequest -Journal $read.Journal -RequestId $RequestId)
}

function Get-HostOperationActiveRequest {
    <#
    .SYNOPSIS
        The one request that blocks new repair work, lock-free, or $null.
    .DESCRIPTION
        Only a repair row is returned by default: its callers resume,
        dispose or withdraw a repair, and must never act on a host update.
    .PARAMETER JournalPath
        Defaults to the private journal path.
    .PARAMETER UtcNow
        Injected clock.
    .PARAMETER Kind
        host-repair (the default), host-update or any.
    .OUTPUTS
        [hashtable] or $null
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$JournalPath, [scriptblock]$UtcNow, [ValidateSet('any', 'host-repair', 'host-update')][string]$Kind = 'host-repair')
    $read = if ($JournalPath) { Read-HostOperationJournal -JournalPath $JournalPath } else { Read-HostOperationJournal }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return $null }
    $clock = Get-HostOperationClockValue -UtcNow $UtcNow
    return (Get-HostOperationBlockingRequest -Journal $read.Journal -NowUnixMs $clock.UnixMs -Kind $Kind)
}

function Get-HostRepairResult {
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
    $read = Read-HostOperationJournal
    if ($read.Status -notin @('ok', 'recovered-previous')) { return [pscustomobject]$result }
    # A host update has its own result, read from its own row.
    $request = Find-HostOperationRequest -Journal $read.Journal -RequestId $RequestId
    if ($request -and (Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return [pscustomobject]$result }
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
        $result.OutstandingObligation = [string[]]@(Get-HostOperationArmedObligation -Request $request)
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
        if ($null -eq $result.ExitCode -and $result.Verdict -and $script:HostRepairVerdictExitCode.ContainsKey([string]$result.Verdict)) {
            $result.ExitCode = [int]$script:HostRepairVerdictExitCode[[string]$result.Verdict]
        }
        return [pscustomobject]$result
    }
    if ($Generation) { return [pscustomobject]$result }
    $tombstone = Find-HostOperationTombstone -Journal $read.Journal -RequestId $RequestId
    if ($tombstone -and (Get-HostOperationRequestKind -Record $tombstone) -ceq $script:HostRepairKind) {
        $result.Found = $true
        $result.State = [string]$tombstone['state']
        $result.Verdict = $tombstone['verdict']
        $result.CompletedUtc = $tombstone['terminalUtc']
        if ($result.Verdict -and $script:HostRepairVerdictExitCode.ContainsKey([string]$result.Verdict)) {
            $result.ExitCode = [int]$script:HostRepairVerdictExitCode[[string]$result.Verdict]
        }
    }
    return [pscustomobject]$result
}

# --- REGION: Public: admission
function Get-HostRepairAdmissionDecision {
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
        Get-YurunaHostOperationAdmissionLockPath).
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
    $policy = Get-HostRepairPolicyRecord -Policy @{ tier = $Tier; maxRung = $MaxRung } -Channel $Channel
    $bodyArguments = @{ RequestId = $RequestId; Channel = $Channel; Policy = $policy; RuntimeDir = $RuntimeDir; HostType = $HostType }
    $body = {
        param($Journal, $Clock, $A)
        $decision = Resolve-HostRepairAdmissionDecision -Journal $Journal -RequestId $A.RequestId -Channel $A.Channel -Policy $A.Policy -RuntimeDir $A.RuntimeDir -HostType $A.HostType -Clock $Clock
        @{ Changed = $false; Result = $decision }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionLock $AdmissionLock -UtcNow $UtcNow
    if (-not $run.Ran) {
        return (ConvertTo-HostRepairAdmissionRecord -Decision ([pscustomobject]@{
                    Decision = 'unavailable'; RequestId = $RequestId; ActiveRequestId = $null; ActiveKind = ''; State = $null
                    Verdict = $null; Attempt = 0; Ceiling = [string]$policy['maxRung']; Reason = $run.Reason
                }))
    }
    return (ConvertTo-HostRepairAdmissionRecord -Decision $run.Result)
}

function Request-HostRepairAdmission {
    <#
    .SYNOPSIS
        Admit, replay or refuse a repair request from the listener, a remote
        pool-control request or the automatic trigger.
    .DESCRIPTION
        Takes only the short admission lock (or validates one the caller
        holds) and never spawns: the caller launches on Decision spawn and
        records the launch with Set-HostRepairLaunchOutcome. A new request is
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
    $policy = Get-HostRepairPolicyRecord -Policy @{ tier = $Tier; maxRung = $MaxRung } -Channel $Channel
    $unavailable = {
        param([string]$Reason)
        ConvertTo-HostRepairAdmissionRecord -Decision ([pscustomobject]@{
                Decision = 'unavailable'; RequestId = $RequestId; ActiveRequestId = $null; ActiveKind = ''; State = $null
                Verdict = $null; Attempt = 0; Ceiling = [string]$policy['maxRung']; Reason = $Reason
            })
    }
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return (& $unavailable 'preview')
    }
    $requester = Get-HostOperationOwnProcess
    $bodyArguments = @{ RequestId = $RequestId; Channel = $Channel; Policy = $policy; RuntimeDir = $RuntimeDir; HostType = $HostType; Context = $Context; Requester = $requester }
    $body = {
        param($Journal, $Clock, $A)
        $decision = Resolve-HostRepairAdmissionDecision -Journal $Journal -RequestId $A.RequestId -Channel $A.Channel -Policy $A.Policy -RuntimeDir $A.RuntimeDir -HostType $A.HostType -Clock $Clock
        $changed = $false
        if ($decision.Decision -eq 'spawn') {
            $launch = [ordered]@{
                outcome = 'pending'; launcherPid = $null; launcherStartTimeUnixMs = $null; workerPid = $null; workerStartTimeUnixMs = $null
                hopAckPath = $null; requesterPid = $A.Requester.pid; requesterStartTimeUnixMs = $A.Requester.startTimeUnixMs; updatedUtc = $Clock.Utc
            }
            if ($decision.Action -eq 'create') {
                $request = New-HostRepairRequestRecord -RequestId $A.RequestId -Channel $A.Channel -RuntimeDir $A.RuntimeDir -HostType $A.HostType `
                    -Policy $A.Policy -Context $A.Context -State 'queued' -Clock $Clock
                $request['launch'] = $launch
                $Journal.requests.Add($request)
                $decision.State = 'queued'
                $changed = $true
            } elseif ($decision.Action -eq 'relaunch') {
                $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
                $request['launch'] = $launch
                $changed = $true
            }
        }
        @{ Changed = $changed; Result = $decision }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionLock $AdmissionLock -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) { return (& $unavailable $run.Reason) }
    if (-not $run.Committed) { return (& $unavailable 'journal-unwritable') }
    return (ConvertTo-HostRepairAdmissionRecord -Decision $run.Result)
}

function Set-HostRepairLaunchOutcome {
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
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Saved = $false; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Outcome = $Outcome; Launch = $Launch; LauncherPid = $LauncherPid; LauncherStartTimeUnixMs = $LauncherStartTimeUnixMs }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = 'refused-other-kind' } }
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'saved') { return [pscustomobject]@{ Saved = $false; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Stop-HostRepairQueuedRequest {
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
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Stopped = $false; State = $null }
    }
    $bodyArguments = @{ RequestId = $RequestId; Reason = $Reason; Detail = $Detail }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) {
            $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId
            return @{ Changed = $false; Result = [pscustomobject]@{ Stopped = $false; State = if ($tombstone) { [string]$tombstone['state'] } else { $null } } }
        }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind -or [string]$request['state'] -ne 'queued') {
            return @{ Changed = $false; Result = [pscustomobject]@{ Stopped = $false; State = [string]$request['state'] } }
        }
        $codes = [System.Collections.Generic.List[string]]::new()
        $codes.Add($A.Reason)
        if ($A.Detail) { $codes.Add($A.Detail) }
        $request['reasonCodes'] = [string[]]$codes.ToArray()
        Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict 'refused' -Clock $Clock
        @{ Changed = $true; Result = [pscustomobject]@{ Stopped = $true; State = 'refused' } }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran -or -not $run.Committed) { return [pscustomobject]@{ Stopped = $false; State = $null } }
    return $run.Result
}

# --- REGION: Public: worker claim and attempt lifecycle
function Confirm-HostRepairIntent {
    <#
    .SYNOPSIS
        Claim a request for this worker under the lifetime lock.
    .DESCRIPTION
        The worker holds the lifetime lock, so no other worker is running;
        this takes the admission lock inside it, registers the owning runtime
        on first use, expires unclaimed queued requests, and then:

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
        Get-YurunaHostOperationLockPath).
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
    if (-not $PSCmdlet.ShouldProcess("$RequestId", (Format-YurunaOperatorMessage -Key 'runner.host_repair_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return (& $refuse 'preview' $null $null)
    }
    $lockPath = Get-HostOperationPrivateFile -Name $script:HostOperationLockName
    if (-not $lockPath -or -not (Test-YurunaSingleFlightLockOwned -Lock $LifetimeLock -Path $lockPath)) {
        return (& $refuse 'refused-lifetime-lock-not-held' $null $null)
    }
    if ($RequestId -and -not (Test-HostOperationRequestIdShape -RequestId $RequestId)) { return (& $refuse 'refused-invalid-request-id' $null $null) }
    if ($Mode -ne 'Resume' -and -not $RequestId) { return (& $refuse 'refused-invalid-request-id' $null $null) }
    $newPolicy = $null
    if ($Mode -eq 'New') {
        $newPolicy = Get-HostRepairPolicyRecord -Policy $Policy -Channel 'local'
        if ($null -eq $newPolicy) { return (& $refuse 'refused-policy-invalid' $null $null) }
    }
    $bodyArguments = @{ Mode = $Mode; RequestId = $RequestId; NewPolicy = $newPolicy; Worker = $Worker; RuntimeDir = $RuntimeDir; RepoRoot = $RepoRoot; HostType = $HostType; Context = $Context }
    $body = {
        param($Journal, $Clock, $A)
        $result = [ordered]@{ Accepted = $false; Reason = $null; Request = $null; Attempt = 0; Generation = $null; RestorationOnly = $false; StoredVerdict = $null }
        $changed = $false
        # A repair worker never adopts a host update, in any mode and before
        # anything is written: the host update is continued by its controller
        # and ended by its own release command.
        if ($A.Mode -ne 'New' -and $A.RequestId) {
            $named = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
            if (-not $named) { $named = Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId }
            if ($named -and (Get-HostOperationRequestKind -Record $named) -cne $script:HostRepairKind) {
                $result.Reason = 'refused-other-kind'
                return @{ Changed = $false; Result = [pscustomobject]$result }
            }
        }
        if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir']) {
            if (-not (Test-HostOperationSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right $A.RuntimeDir)) {
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
            $request = Get-HostOperationBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs -Kind $script:HostRepairKind
            if (-not $request) { $result.Reason = 'refused-no-request'; return @{ Changed = $changed; Result = [pscustomobject]$result } }
            if ($A.RequestId -and [string]$request['requestId'] -cne $A.RequestId) {
                $result.Reason = 'refused-active-other-request'; $result.Request = $request
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
        } else {
            $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        }
        if ($A.Mode -eq 'New') {
            if ($request -or (Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId)) {
                $result.Reason = 'refused-request-exists'; $result.Request = $request
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            foreach ($reservation in $Journal.reservations) {
                $result.Reason = 'refused-start-cycle-active'
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            $blocking = Get-HostOperationBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
            if ($blocking) {
                $result.Reason = 'refused-active-other-request'; $result.Request = $blocking
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            if ($Journal.tombstones.Count -ge $script:HostOperationTombstoneCap) {
                $result.Reason = 'refused-journal-full'
                return @{ Changed = $changed; Result = [pscustomobject]$result }
            }
            $request = New-HostRepairRequestRecord -RequestId $A.RequestId -Channel 'local' -RuntimeDir $A.RuntimeDir -HostType $A.HostType `
                -Policy $A.NewPolicy -Context $A.Context -State 'running' -Clock $Clock
            $attempt = New-HostRepairAttemptRecord -Attempt 1 -Mode 'new' -Worker $A.Worker -Clock $Clock
            $request['attempt'] = 1
            $request['attempts'].Add($attempt)
            $Journal.requests.Add($request)
            $result.Accepted = $true; $result.Reason = 'accepted-new'; $result.Request = $request
            $result.Attempt = 1; $result.Generation = $attempt['generation']
            return @{ Changed = $true; Result = [pscustomobject]$result }
        }
        if (-not $request) {
            $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId
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
        if (-not (Test-HostOperationSameRuntime -Left ([string]$request['runtimeDir']) -Right $A.RuntimeDir)) {
            $result.Reason = 'refused-runtime-mismatch'
            return @{ Changed = $changed; Result = [pscustomobject]$result }
        }
        $armed = @(Get-HostOperationArmedObligation -Request $request)
        $next = [int]$request['attempt'] + 1
        if ($next -gt $script:HostOperationMaxAttempts) {
            $request['reasonCodes'] = [string[]]@('attempts-exhausted')
            if (-not $request['operatorAction']) { $request['operatorAction'] = if ($armed.Count -gt 0) { 'dispose-obligations' } else { $null } }
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'abandoned' -Verdict 'abandoned' -Clock $Clock
            $result.Reason = 'refused-attempts-exhausted'; $result.StoredVerdict = 'abandoned'
            return @{ Changed = $true; Result = [pscustomobject]$result }
        }
        $modeName = switch ($state) {
            'queued' { if ($A.Mode -eq 'Resume') { 'resume' } else { 'claim' } }
            default { if ($armed.Count -gt 0) { 'restoration' } elseif ($A.Mode -eq 'Resume') { 'resume' } else { 'claim' } }
        }
        $attempt = New-HostRepairAttemptRecord -Attempt $next -Mode $modeName -Worker $A.Worker -Clock $Clock
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
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

function Save-HostRepairRecoveryRecord {
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
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_repair_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = 'preview'; FirstCapture = $false }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; Recovery = $Recovery; Obligation = $Obligation }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = 'refused-other-kind' } }
        $last = Get-HostRepairLastAttempt -Request $request
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
            while ($observations.Count -gt $script:HostOperationObservationCap) { $observations.RemoveAt(0) }
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = $run.Reason; FirstCapture = $false } }
    if ($run.Result -notin @('captured', 'observation')) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = [string]$run.Result; FirstCapture = $false } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; Reason = if ($run.Committed) { [string]$run.Result } else { $run.Reason }; FirstCapture = ($run.Result -eq 'captured') }
}

function Set-HostRepairObligationState {
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
        service:<key>, endpoint:<key>, runner, listener, controls, gate or
        elevation.
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
        [Parameter(Mandatory)][ValidatePattern('^(service:[a-z0-9][a-z0-9-]{0,62}|endpoint:[a-z0-9][a-z0-9-]{0,62}|runner|listener|controls|gate|elevation)$')][string[]]$ObligationId,
        [Parameter(Mandatory)][ValidateSet('armed', 'discharged')][string]$State,
        [string]$Evidence,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_repair_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; ObligationId = $ObligationId; State = $State; Evidence = $Evidence }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = 'refused-other-kind' } }
        $last = Get-HostRepairLastAttempt -Request $request
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'saved') { return [pscustomobject]@{ Saved = $false; Durable = $false; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Set-HostRepairObligationDisposition {
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
        [Parameter(Mandatory)][ValidatePattern('^(service:[a-z0-9][a-z0-9-]{0,62}|endpoint:[a-z0-9][a-z0-9-]{0,62}|runner|listener|controls|gate|elevation)$')][string[]]$ObligationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Actor,
        [string]$RequestId,
        [scriptblock]$UtcNow
    )
    $empty = [pscustomobject]@{ Saved = $false; Disposed = [string[]]@(); Unknown = [string[]]$ObligationId; RemainingOutstanding = 0; State = $null; RequestId = $RequestId }
    if (-not $PSCmdlet.ShouldProcess("$RequestId", (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return $empty }
    $bodyArguments = @{ RequestId = $RequestId; ObligationId = $ObligationId; Actor = $Actor; Empty = $empty; Caller = (Get-HostOperationOwnProcess) }
    $body = {
        param($Journal, $Clock, $A)
        $request = $null
        if ($A.RequestId) { $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId }
        else {
            foreach ($candidate in $Journal.requests) {
                if ((Get-HostOperationRequestKind -Record $candidate) -cne $script:HostRepairKind) { continue }
                if (@(Get-HostOperationArmedObligation -Request $candidate).Count -gt 0) { $request = $candidate }
            }
        }
        # A host update's obligations are released by its own command.
        if (-not $request -or (Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = $A.Empty } }
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
        $remaining = @(Get-HostOperationArmedObligation -Request $request).Count
        $closable = ([string]$request['state'] -eq 'recovery-pending')
        if ([string]$request['state'] -eq 'running') {
            # Only a crashed worker's request closes here. The caller is never
            # treated as dead, even when its pid recycles a crashed worker's:
            # the request then stays running and a retry resolves it.
            $last = Get-HostRepairLastAttempt -Request $request
            $worker = if ($last -and $last['worker'] -is [System.Collections.IDictionary]) { $last['worker'] } else { $null }
            $isCaller = [bool]$worker -and "$($worker['pid'])" -eq "$($A.Caller.pid)"
            $closable = [bool]$worker -and -not $isCaller -and
                (Get-HostOperationProcessLiveness -ProcessId $worker['pid'] -StartTimeUnixMs $worker['startTimeUnixMs']) -eq 'dead'
        }
        if ($disposed.Count -gt 0 -and $remaining -eq 0 -and $closable) {
            $verdict = if ($request['verdict']) { [string]$request['verdict'] } else { 'partial' }
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'completed' -Verdict $verdict -Clock $Clock
        }
        $result = [pscustomobject]@{
            Saved = $true; Disposed = [string[]]$disposed.ToArray(); Unknown = [string[]]$unknown.ToArray()
            RemainingOutstanding = $remaining; State = [string]$request['state']; RequestId = [string]$request['requestId']
        }
        @{ Changed = ($disposed.Count -gt 0); Result = $result }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return $empty }
    $result = $run.Result
    if (-not $run.Committed) { $result.Saved = $false }
    return $result
}

function Complete-HostRepairAttempt {
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
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_repair_should_process_run' -Arguments @{ requestId = "$RequestId" }))) {
        return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = 'preview' }
    }
    $bodyArguments = @{ RequestId = $RequestId; Generation = $Generation; Verdict = $Verdict; Mutated = $Mutated; ReasonCode = $ReasonCode; RungResult = $RungResult; OperatorAction = $OperatorAction; FinalProbe = $FinalProbe; RunnerReadiness = $RunnerReadiness; Handoff = $Handoff; GateGeneration = $GateGeneration }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = 'no-request' } }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = 'refused-other-kind' } }
        $attempt = $null
        foreach ($candidate in $request['attempts']) { if ([string]$candidate['generation'] -ceq $A.Generation) { $attempt = $candidate } }
        if (-not $attempt) { return @{ Changed = $false; Result = 'generation-mismatch' } }
        $attempt['finishedUtc'] = $Clock.Utc
        $attempt['verdict'] = $A.Verdict
        $attempt['exitCode'] = [int]$script:HostRepairVerdictExitCode[$A.Verdict]
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
        $armed = @(Get-HostOperationArmedObligation -Request $request).Count
        $anyMutated = @($request['attempts'] | Where-Object { [bool]$_['mutated'] }).Count -gt 0
        if ($A.Verdict -eq 'abandoned') {
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'abandoned' -Verdict $A.Verdict -Clock $Clock
        } elseif ($A.Verdict -eq 'refused' -and -not $anyMutated -and $armed -eq 0) {
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'refused' -Verdict $A.Verdict -Clock $Clock
        } elseif ($armed -gt 0) {
            $request['state'] = 'recovery-pending'
        } else {
            Set-HostOperationRequestTerminal -Journal $Journal -Request $request -State 'completed' -Verdict $A.Verdict -Clock $Clock
        }
        @{ Changed = $true; Result = [string]$request['state'] }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = $run.Reason } }
    if ($run.Result -in @('no-request', 'generation-mismatch', 'refused-other-kind')) { return [pscustomobject]@{ Saved = $false; Durable = $false; State = $null; Reason = [string]$run.Result } }
    return [pscustomobject]@{ Saved = [bool]$run.Committed; Durable = [bool]$run.Durable; State = [string]$run.Result; Reason = if ($run.Committed) { 'saved' } else { $run.Reason } }
}

function Set-HostRepairCallerAck {
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
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return [pscustomobject]@{ Saved = $false } }
    $bodyArguments = @{ RequestId = $RequestId; Readiness = $Readiness; CallerPid = $CallerPid; CallerStartTimeUnixMs = $CallerStartTimeUnixMs; Reason = $Reason }
    $body = {
        param($Journal, $Clock, $A)
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request -or (Get-HostOperationRequestKind -Record $request) -cne $script:HostRepairKind) { return @{ Changed = $false; Result = $false } }
        $request['callerAck'] = [ordered]@{
            readiness = $A.Readiness; callerPid = $A.CallerPid; callerStartTimeUnixMs = $A.CallerStartTimeUnixMs
            reason = if ($A.Reason) { $A.Reason } else { $null }; updatedUtc = $Clock.Utc
        }
        @{ Changed = $true; Result = $true }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Saved = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

# --- REGION: Public: start-cycle reservation
function Request-StartCycleReservation {
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
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return (& $unavailable 'preview') }
    $requester = Get-HostOperationOwnProcess
    $bodyArguments = @{ OperationId = $OperationId; RuntimeDir = $RuntimeDir; Requester = $requester; Unavailable = $unavailable }
    $body = {
        param($Journal, $Clock, $A)
        $busy = { param([string]$Kind, $Active, [string]$Why) [pscustomobject]@{ Decision = 'busy'; Generation = $null; ActiveKind = $Kind; ActiveRequestId = $Active; Reason = $Why } }
        foreach ($reservation in $Journal.reservations) {
            return @{ Changed = $false; Result = (& $busy 'start-cycle' ([string]$reservation['operationId']) 'start-cycle-active') }
        }
        $blocking = Get-HostOperationBlockingRequest -Journal $Journal -NowUnixMs $Clock.UnixMs
        if ($blocking) { return @{ Changed = $false; Result = (& $busy (Get-HostOperationRequestKind -Record $blocking) ([string]$blocking['requestId']) 'host-operation-active') } }
        $gate = Get-HostOperationGateView -RuntimeDir $A.RuntimeDir
        if (-not $gate.Known) { return @{ Changed = $false; Result = (& $A.Unavailable $gate.Reason) } }
        if (-not $gate.Open) { return @{ Changed = $false; Result = (& $busy (Get-HostOperationGateHolderKind -Journal $Journal -RequestId $gate.RequestId) $gate.RequestId "gate-$($gate.State)") } }
        $generation = [Guid]::NewGuid().ToString('N')
        $Journal.reservations.Add([ordered]@{
                kind = 'start-cycle'; operationId = $A.OperationId; generation = $generation; state = 'queued'
                launch = [ordered]@{ outcome = 'pending'; launcherPid = $null; launcherStartTimeUnixMs = $null; workerPid = $null; workerStartTimeUnixMs = $null
                    requesterPid = $A.Requester.pid; requesterStartTimeUnixMs = $A.Requester.startTimeUnixMs; updatedUtc = $Clock.Utc }
                worker = $null; runtimeDir = $A.RuntimeDir; createdUtc = $Clock.Utc; createdUnixMs = $Clock.UnixMs
            })
        @{ Changed = $true; Result = [pscustomobject]@{ Decision = 'reserved'; Generation = $generation; ActiveKind = ''; ActiveRequestId = $null; Reason = 'reserved' } }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) { return (& $unavailable $run.Reason) }
    if (-not $run.Committed) { return (& $unavailable 'journal-unwritable') }
    return $run.Result
}

function Set-StartCycleLaunch {
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
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return [pscustomobject]@{ Saved = $false } }
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Saved = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

function Confirm-StartCycleReservation {
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
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Valid = $false; Reason = 'preview' }
    }
    $lockPath = Get-HostOperationPrivateFile -Name $script:HostOperationLockName
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Valid = $false; Reason = $run.Reason } }
    if ($run.Result -ne 'valid') { return [pscustomobject]@{ Valid = $false; Reason = [string]$run.Result } }
    if (-not $run.Committed) { return [pscustomobject]@{ Valid = $false; Reason = 'journal-unwritable' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'valid' }
}

function Complete-StartCycleReservation {
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
    if (-not $PSCmdlet.ShouldProcess($OperationId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return [pscustomobject]@{ Cleared = $false } }
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
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    return [pscustomobject]@{ Cleared = ([bool]$run.Ran -and [bool]$run.Result -and [bool]$run.Committed) }
}

# --- REGION: Public: host update
function Get-HostUpdateProtocolVersion {
    <#
    .SYNOPSIS
        The host-update protocol number a checkout or snapshot declares.
    .DESCRIPTION
        test/host-update.protocol-version is one ASCII line. Its number
        covers the step contract and the journal's update block: a
        controller compares its snapshot's number with the checkout's before
        it claims a request and after the source update.
    .PARAMETER RepoRoot
        The checkout or snapshot root.
    .OUTPUTS
        [int] the number, or -1 when the file is missing, unreadable or not
        a plain integer.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = [System.IO.Path]::Combine($RepoRoot, 'test', $script:HostUpdateProtocolFile)
    $text = $null
    try {
        if (-not [System.IO.File]::Exists($path)) { return -1 }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        if ($bytes.Length -gt 64) { return -1 }
        $text = [System.Text.Encoding]::ASCII.GetString($bytes).Trim()
    } catch {
        Write-Verbose "Get-HostUpdateProtocolVersion: '$path' unreadable: $($_.Exception.Message)"
        return -1
    }
    $version = 0
    if ($text -notmatch '^[0-9]{1,6}$' -or -not [int]::TryParse($text, [ref]$version)) { return -1 }
    return $version
}

function Get-HostUpdateControllerLockPath {
    <#
    .SYNOPSIS
        The host controller's lifetime lock path under the private state
        root.
    .PARAMETER NoCreate
        Observe only: $null when the root does not exist yet.
    .OUTPUTS
        [string] or $null when the root cannot be secured.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    return (Get-HostOperationPrivateFile -Name $script:HostUpdateControllerLockName -NoCreate:$NoCreate)
}

function Get-HostUpdateControllerRoot {
    <#
    .SYNOPSIS
        The host controller's private directory: shim, snapshots and work
        folders.
    .PARAMETER NoCreate
        Observe only: $null when the directory does not exist yet.
    .OUTPUTS
        [string] or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    if ($IsWindows) { return (Get-HostUpdateWindowsControllerRoot -NoCreate:$NoCreate) }
    $leaf = Get-HostOperationPrivateFile -Name 'current' -Subdirectory $script:HostUpdateControllerDirName -NoCreate:$NoCreate
    if (-not $leaf) { return $null }
    return [System.IO.Path]::GetDirectoryName($leaf)
}

function Get-HostUpdateInstallerCopyDirectory {
    <#
    .SYNOPSIS
        Where the install phase of a host update on Windows copies the
        installer for one attempt: a folder under %ProgramData%\yuruna, the
        only place the shim accepts an installer for the PowerShell upgrade.
    .PARAMETER RequestId
        The host update.
    .PARAMETER Attempt
        The install phase's attempt.
    .OUTPUTS
        [string] or $null off Windows or without ProgramData.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, 1000)][int]$Attempt
    )
    if (-not $IsWindows -or -not $env:ProgramData) { return $null }
    return [System.IO.Path]::Combine($env:ProgramData, 'yuruna', "host-update-$RequestId-$Attempt")
}

# The SIDs the Windows controller root may grant: Administrators and SYSTEM
# in full, and OWNER RIGHTS read only. The scheduled task starts the shim from
# this folder with an elevated token, so a write by anything less than an
# Administrator would be an elevation. OWNER RIGHTS is there because a Windows
# client makes the creator of a file its owner, and an owner may rewrite the
# file's access list even from an unelevated process unless an OWNER RIGHTS
# entry says what the owner gets.
$script:HostUpdateWindowsAdminSid = 'S-1-5-32-544'
$script:HostUpdateWindowsSystemSid = 'S-1-5-18'
$script:HostUpdateWindowsOwnerRightsSid = 'S-1-3-4'

function Test-HostUpdateWindowsAdminOnlyAcl {
    <#
    .SYNOPSIS
        Whether a folder's access list lets only Administrators and SYSTEM
        write it.
    .DESCRIPTION
        The list must be protected from inheritance, owned by Administrators
        or SYSTEM, and grant nothing but full control to those two and read
        and execute to OWNER RIGHTS. A deny entry is allowed: it can only
        take away.
    .PARAMETER Path
        The folder.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @($script:HostUpdateWindowsAdminSid, $script:HostUpdateWindowsSystemSid)) { return $false }
        $readOnly = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [System.Security.AccessControl.FileSystemRights]::Synchronize
        foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $rule.IdentityReference.Value
            if ($sid -in @($script:HostUpdateWindowsAdminSid, $script:HostUpdateWindowsSystemSid)) { continue }
            if ($sid -eq $script:HostUpdateWindowsOwnerRightsSid -and ($rule.FileSystemRights -band (-bnot $readOnly)) -eq 0) { continue }
            return $false
        }
        return $true
    } catch {
        Write-Verbose "Test-HostUpdateWindowsAdminOnlyAcl: '$Path' unreadable: $($_.Exception.Message)"
        return $false
    }
}

function New-HostUpdateWindowsAdminOnlyDirectory {
    <#
    .SYNOPSIS
        Create a folder under %ProgramData%\yuruna that only Administrators
        and SYSTEM can change: owned by Administrators, a protected access
        list with full control for those two and read and execute for OWNER
        RIGHTS, so the account that created it cannot rewrite the list from
        an unelevated process.
    .DESCRIPTION
        A linked parent is refused. The folder must not exist yet; it is
        checked with Test-HostUpdateWindowsAdminOnlyAcl once made.
    .PARAMETER Path
        The new folder.
    .OUTPUTS
        [bool] created and verified.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.host_update_elevation_action'))) { return $false }
    $parent = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetDirectoryName($Path))
    if ($parent.Exists -and $parent.LinkTarget) { return $false }
    if (-not $parent.Exists) { $null = [System.IO.Directory]::CreateDirectory($parent.FullName) }
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    foreach ($grant in @(@($script:HostUpdateWindowsAdminSid, 'FullControl'), @($script:HostUpdateWindowsSystemSid, 'FullControl'),
            @($script:HostUpdateWindowsOwnerRightsSid, 'ReadAndExecute'))) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                [System.Security.Principal.SecurityIdentifier]::new($grant[0]), [System.Security.AccessControl.FileSystemRights]$grant[1], $inherit, $none, 'Allow'))
    }
    $security.SetOwner([System.Security.Principal.SecurityIdentifier]::new($script:HostUpdateWindowsAdminSid))
    $null = [System.IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
    $info = [System.IO.DirectoryInfo]::new($Path)
    return ($info.Exists -and -not $info.LinkTarget -and (Test-HostUpdateWindowsAdminOnlyAcl -Path $Path))
}

function Get-HostUpdateWindowsControllerRoot {
    <#
    .SYNOPSIS
        %ProgramData%\yuruna\host-controller, created owned by Administrators
        and writable by Administrators and SYSTEM only.
    .DESCRIPTION
        A folder that exists with any other access list, or that is a link,
        is refused rather than repaired: something else made it, and its
        files cannot be trusted to run elevated.
    .PARAMETER NoCreate
        Observe only: $null when the folder does not exist yet.
    .OUTPUTS
        [string] or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$NoCreate)
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($base)) { return $null }
    $parent = [System.IO.Path]::Combine($base, 'yuruna')
    $path = [System.IO.Path]::Combine($parent, $script:HostUpdateControllerDirName)
    $info = [System.IO.DirectoryInfo]::new($path)
    if (-not $info.Exists) {
        if ($NoCreate) { return $null }
        try {
            if (-not (New-HostUpdateWindowsAdminOnlyDirectory -Path $path -Confirm:$false)) { return $null }
        } catch {
            Write-Verbose "Get-HostUpdateWindowsControllerRoot: '$path' not created: $($_.Exception.Message)"
            return $null
        }
        $info = [System.IO.DirectoryInfo]::new($path)
    }
    if ($info.LinkTarget -or -not (Test-HostUpdateWindowsAdminOnlyAcl -Path $path)) {
        Write-Verbose "Get-HostUpdateWindowsControllerRoot: '$path' is a link or not Administrators-only; refused."
        return $null
    }
    return $path
}

function Get-HostUpdateControllerLockState {
    <#
    .SYNOPSIS
        Whether a host controller is running, read from its lock.
    .DESCRIPTION
        Liveness is read from the lock handle, never from a timestamp, so a
        clock step cannot fake it. No private root yet reads as absent.
    .OUTPUTS
        [string] absent, free, held or unknown.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-HostUpdateControllerLockPath -NoCreate
    if (-not $path) { return 'absent' }
    return [string](Get-YurunaSingleFlightLockState -Path $path).State
}

function Get-HostUpdateConsoleHint {
    <#
    .SYNOPSIS
        Where an operator opens the console of a runner the host controller
        started: the tmux attach command on KVM and macOS, the console window
        on Windows.
    .PARAMETER Platform
        Windows or Posix; the current platform by default.
    .PARAMETER NoCreate
        Observe the controller root only; without it a missing root is
        created, as Get-HostUpdateControllerRoot does.
    .OUTPUTS
        [string] the command or the sentence; '-' when no controller root
        exists on KVM or macOS.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateSet('Windows', 'Posix')][string]$Platform = $(if ($IsWindows) { 'Windows' } else { 'Posix' }), [switch]$NoCreate)
    if ($Platform -eq 'Windows') { return (Format-YurunaOperatorMessage -Key 'runner.host_update_console_window') }
    $controllerRoot = Get-HostUpdateControllerRoot -NoCreate:$NoCreate
    if (-not $controllerRoot) { return '-' }
    return "tmux -S $([System.IO.Path]::Combine($controllerRoot, 'runner-console.sock')) attach"
}

function Format-HostUpdateGateRefusal {
    <#
    .SYNOPSIS
        The line an ordinary runner start prints when the host controller
        holds the runner gate.
    .DESCRIPTION
        While a controller holds its lock it continues the host update and
        starts the runner itself, so the line says where that runner's console
        appears. Otherwise no controller is running: on KVM and Windows the
        system service starts one within seconds, and the line names the
        release command for an operator who does not want to wait. On macOS
        nothing starts one but a runner start from the desktop session, so
        the line repeats what this start's controller step found and names
        both ways on. A step that found a controller running, or started one,
        while the lock reads free or absent a moment later saw a controller
        between two runs, which the shim in its session starts again: that
        line is not repeated after one saying no controller runs. When the
        lock cannot be read after such a step, nothing shows whether a
        controller still runs, so the line says that and names both ways on.
    .PARAMETER RequestId
        The request id the gate names.
    .PARAMETER LockState
        The controller lock's state; read when not given.
    .PARAMETER ControllerStart
        The result of Start-HostUpdateControllerSession for this start
        (macOS); its Line is repeated when no controller holds the lock.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$RequestId,
        [AllowEmptyString()][string]$LockState = (Get-HostUpdateControllerLockState),
        [AllowNull()][object]$ControllerStart
    )
    if ($LockState -ceq 'held') {
        return (Format-YurunaOperatorMessage -Key 'runner.host_update_gate_controller_running' -Arguments @{ requestId = $RequestId; attach = (Get-HostUpdateConsoleHint -NoCreate) })
    }
    $release = "pwsh test/lab/Invoke-HostUpdate.ps1 -Release $RequestId"
    if ($null -ne $ControllerStart -and [string]$ControllerStart.Result -cin @('running', 'started')) {
        $key = if ($LockState -cin @('free', 'absent')) { 'runner.host_update_gate_controller_restarting_macos' } else { 'runner.host_update_gate_controller_unknown_macos' }
        return (Format-YurunaOperatorMessage -Key $key -Arguments @{ requestId = $RequestId; release = $release })
    }
    if ($null -ne $ControllerStart) {
        return (Format-YurunaOperatorMessage -Key 'runner.host_update_gate_controller_absent_macos' -Arguments @{
            requestId = $RequestId; result = [string]$ControllerStart.Line; release = $release })
    }
    return (Format-YurunaOperatorMessage -Key 'runner.host_update_gate_controller_absent' -Arguments @{ requestId = $RequestId; release = $release })
}

function Request-HostUpdateAdmission {
    <#
    .SYNOPSIS
        Queue, replay or refuse a host update from the listener or the host
        command.
    .DESCRIPTION
        One transaction under the short admission lock; nothing is launched,
        the host controller claims the queued row. The same id with the same
        request replays its state; another request under that id, or a row of
        another kind, is a policy mismatch. A different id is busy while a
        repair, a start-cycle or another host update holds the host, or the
        runner gate is closed. A new host update over one that is recovering,
        with nothing else holding the host, takes over its obligations and
        runner plan, and the earlier one ends as superseded in the same
        transaction. Only the local channel may end a running cycle.
    .PARAMETER RequestId
        Canonical lowercase request id.
    .PARAMETER Channel
        listener (from this host's loopback), remote (with a verified update
        proof) or local (the host command).
    .PARAMETER Scope
        restart or full. The callers refuse a scope the host cannot run.
    .PARAMETER Drain
        after-cycle, or now (local only).
    .PARAMETER DrainSeconds
        How long to wait for the running cycle, 60 to 21600.
    .PARAMETER ExpectCommit
        Optional lowercase commit prefix the checkout must reach.
    .PARAMETER RuntimeDir
        The runtime directory the request is for.
    .PARAMETER HostType
        Long host type.
    .PARAMETER AdmissionWaitMilliseconds
        Wait for the admission lock.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Decision queued|taken-over|already-active|
        completed|busy|policy-mismatch|policy-invalid|unavailable; RequestId;
        State; Verdict; ActiveKind; ActiveRequestId; SupersededId; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', Options = 'None')][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('listener', 'remote', 'local')][string]$Channel,
        [ValidateSet('restart', 'full')][string]$Scope = 'restart',
        [ValidateSet('after-cycle', 'now')][string]$Drain = 'after-cycle',
        [ValidateRange(60, 21600)][int]$DrainSeconds = 7200,
        [ValidatePattern('^[0-9a-f]{7,40}$', Options = 'None')][string]$ExpectCommit,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$HostType,
        [ValidateRange(0, 600000)][int]$AdmissionWaitMilliseconds = 1000,
        [scriptblock]$UtcNow
    )
    $record = {
        param($Source)
        [pscustomobject][ordered]@{
            Decision = [string]$Source.Decision; RequestId = [string]$Source.RequestId; State = $Source.State; Verdict = $Source.Verdict
            ActiveKind = [string]$Source.ActiveKind; ActiveRequestId = $Source.ActiveRequestId; SupersededId = $Source.SupersededId; Reason = [string]$Source.Reason
        }
    }
    $unavailable = { param([string]$Reason) & $record ([pscustomobject]@{ Decision = 'unavailable'; RequestId = $RequestId; Reason = $Reason }) }
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return (& $unavailable 'preview')
    }
    $bodyArguments = @{
        RequestId = $RequestId; Channel = $Channel; Scope = $Scope; Drain = $Drain; DrainSeconds = $DrainSeconds; ExpectCommit = $ExpectCommit
        RuntimeDir = $RuntimeDir; HostType = $HostType
        PolicyHash = (Get-HostUpdatePolicyHash -Scope $Scope -Drain $Drain -DrainSeconds $DrainSeconds -ExpectCommit $ExpectCommit)
    }
    $body = {
        param($Journal, $Clock, $A)
        $decision = Resolve-HostUpdateAdmissionDecision -Journal $Journal -Arguments $A -Clock $Clock
        if ($decision.Decision -notin @('queued', 'taken-over')) { return @{ Changed = $false; Result = $decision } }
        $request = New-HostUpdateRequestRecord -RequestId $A.RequestId -Channel $A.Channel -RuntimeDir $A.RuntimeDir -HostType $A.HostType `
            -Scope $A.Scope -Drain $A.Drain -DrainSeconds $A.DrainSeconds -ExpectCommit $A.ExpectCommit -Clock $Clock
        if ($decision.Decision -eq 'taken-over') {
            # The earlier update's obligations and runner plan move to this
            # row unchanged, so nothing is restored by the wrong hands and
            # the start_runner phase still knows whether a runner is to be started.
            $old = $decision.Takeover
            $oldUpdate = Get-HostUpdateBlock -Request $old
            $newUpdate = $request['update']
            foreach ($obligation in @($old['obligations'])) {
                if ($obligation -isnot [System.Collections.IDictionary] -or [string]$obligation['status'] -ne 'armed') { continue }
                $request['obligations'].Add([ordered]@{
                        id = [string]$obligation['id']; kind = $script:HostUpdateKind; target = $obligation['target']; required = $true
                        status = 'armed'; armedGeneration = $null; updatedUtc = $Clock.Utc; disposedBy = $null; evidence = $null
                    })
                $obligation['status'] = 'disposed'
                $obligation['disposedBy'] = 'superseded'
                $obligation['updatedUtc'] = $Clock.Utc
            }
            if ($oldUpdate['runnerPlan'] -is [System.Collections.IDictionary]) { $newUpdate['runnerPlan'] = $oldUpdate['runnerPlan'] }
            if ($oldUpdate['reclaimed'] -is [System.Collections.IDictionary]) {
                foreach ($role in @('outer', 'cycle', 'inner')) { $newUpdate['reclaimed'][$role] = ConvertTo-HostUpdateIdentity -Identity $oldUpdate['reclaimed'][$role] }
            }
            $newUpdate['inheritedFrom'] = [string]$old['requestId']
            $newUpdate['inheritedGateRequestId'] = [string]$decision.GateRequestId
            $oldUpdate['supersededBy'] = $A.RequestId
            Complete-HostUpdateRow -Journal $Journal -Request $old -Verdict 'superseded' -OperatorAction 'none' -Clock $Clock
        }
        $Journal.requests.Add($request)
        @{ Changed = $true; Result = $decision }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -AdmissionWaitMilliseconds $AdmissionWaitMilliseconds -UtcNow $UtcNow
    if (-not $run.Ran) { return (& $unavailable $run.Reason) }
    if (-not $run.Committed) { return (& $unavailable 'journal-unwritable') }
    return (& $record $run.Result)
}

function Get-HostUpdateRequest {
    <#
    .SYNOPSIS
        One host-update row, lock-free, or $null (also for a repair's id).
    .PARAMETER RequestId
        The request id.
    .PARAMETER JournalPath
        Defaults to the private journal path.
    .OUTPUTS
        [hashtable] or $null
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RequestId, [string]$JournalPath)
    $read = if ($JournalPath) { Read-HostOperationJournal -JournalPath $JournalPath } else { Read-HostOperationJournal }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return $null }
    $request = Find-HostOperationRequest -Journal $read.Journal -RequestId $RequestId
    if ($request -and (Get-HostOperationRequestKind -Record $request) -ceq $script:HostUpdateKind) { return $request }
    return $null
}

function Get-HostUpdateQueue {
    <#
    .SYNOPSIS
        The host update a controller holds and the next one to claim,
        lock-free.
    .PARAMETER JournalPath
        Defaults to the private journal path.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Status (the journal read status); Claimed (a
        running or recovery-pending host update, or $null); Queued (the
        oldest queued host update that is unexpired or holds armed
        obligations, or $null) }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$JournalPath, [scriptblock]$UtcNow)
    $read = if ($JournalPath) { Read-HostOperationJournal -JournalPath $JournalPath } else { Read-HostOperationJournal }
    $result = [ordered]@{ Status = [string]$read.Status; Claimed = $null; Queued = $null }
    if ($read.Status -notin @('ok', 'recovered-previous')) { return [pscustomobject]$result }
    $clock = Get-HostOperationClockValue -UtcNow $UtcNow
    foreach ($request in $read.Journal.requests) {
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostUpdateKind) { continue }
        $state = [string]$request['state']
        if ($state -in @('running', 'recovery-pending')) { if (-not $result.Claimed) { $result.Claimed = $request } }
        elseif ($state -eq 'queued' -and (@(Get-HostOperationArmedObligation -Request $request).Count -gt 0 -or
                -not (Test-HostOperationQueuedExpired -Request $request -NowUnixMs $clock.UnixMs))) {
            if (-not $result.Queued -or [long]$request['createdUnixMs'] -lt [long]$result.Queued['createdUnixMs']) { $result.Queued = $request }
        }
    }
    return [pscustomobject]$result
}

function Get-HostUpdateCapability {
    <#
    .SYNOPSIS
        What the listener and the host command need to know before they
        admit a host update, read without creating anything.
    .DESCRIPTION
        The controller lock decides whether a controller runs; the journal
        whether a host update is active or recovering; the controller's
        published state which scopes it runs and whether its session can
        start a runner. A state file whose heartbeat is older than 30 s, or
        that cannot be read, counts as absent.
    .PARAMETER RepoRoot
        The checkout whose protocol number is reported.
    .PARAMETER RuntimeDir
        The runtime directory that holds host-controller.state.json.
    .PARAMETER JournalPath
        Defaults to the private journal path.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ LockState; JournalStatus; ControllerState
        (hashtable or $null); Protocol; UpdateState idle|active|recovering|
        unknown }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RepoRoot, [AllowEmptyString()][string]$RuntimeDir, [string]$JournalPath, [scriptblock]$UtcNow)
    $queueArguments = @{ UtcNow = $UtcNow }
    if ($JournalPath) { $queueArguments.JournalPath = $JournalPath }
    $queue = Get-HostUpdateQueue @queueArguments
    $updateState = if ($queue.Status -notin @('ok', 'absent', 'recovered-previous')) { 'unknown' }
    elseif ($queue.Claimed -and [string]$queue.Claimed['state'] -eq 'recovery-pending') { 'recovering' }
    elseif ($queue.Claimed -or $queue.Queued) { 'active' }
    else { 'idle' }
    $controllerState = $null
    if ($RuntimeDir) {
        $statePath = [System.IO.Path]::Combine($RuntimeDir, 'host-controller.state.json')
        try {
            $info = [System.IO.FileInfo]::new($statePath)
            if ($info.Exists -and $info.Length -le 65536) {
                $parsed = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable -Depth 4
                $heartbeat = [DateTimeOffset]::MinValue
                if ($parsed -is [System.Collections.IDictionary] -and
                    [DateTimeOffset]::TryParse([string]$parsed['heartbeatUtc'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$heartbeat)) {
                    $age = (Get-HostOperationClockValue -UtcNow $UtcNow).UnixMs - $heartbeat.ToUnixTimeMilliseconds()
                    if ($age -le 30000) { $controllerState = $parsed }
                }
            }
        } catch {
            Write-Verbose "Get-HostUpdateCapability: '$statePath' unreadable: $($_.Exception.Message)"
        }
    }
    return [pscustomobject]@{
        LockState = (Get-HostUpdateControllerLockState); JournalStatus = [string]$queue.Status; ControllerState = $controllerState
        Protocol = (Get-HostUpdateProtocolVersion -RepoRoot $RepoRoot); UpdateState = $updateState
    }
}

function Confirm-HostUpdateClaim {
    <#
    .SYNOPSIS
        Claim a queued host update for this controller, or continue one it
        or a dead controller had claimed, under the lifetime lock.
    .DESCRIPTION
        A claim moves the row from queued to running, names this controller
        and registers the owning runtime on first use. A continuation
        re-stamps the controller of a running or recovery-pending row when
        the recorded controller is this process or positively dead; a live
        or unknown one keeps it. Neither counts as an attempt: attempts are
        counted per phase inside the row.
    .PARAMETER RequestId
        The host update.
    .PARAMETER LifetimeLock
        The held lifetime lock (host-operation.lock).
    .PARAMETER ControllerPid
        This controller's pid.
    .PARAMETER ControllerStartTimeUnixMs
        This controller's start time.
    .PARAMETER Snapshot
        The 16-hex snapshot hash this controller runs.
    .PARAMETER RepoRoot
        The checkout, recorded as the owner's repository on first use.
    .PARAMETER Mode
        claim or continue.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Accepted; Reason; Row }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][AllowNull()]$LifetimeLock,
        [Parameter(Mandatory)][int]$ControllerPid,
        [Parameter(Mandatory)][long]$ControllerStartTimeUnixMs,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{16}$', Options = 'None')][string]$Snapshot,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('claim', 'continue')][string]$Mode,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'preview'; Row = $null }
    }
    $lockPath = Get-HostOperationPrivateFile -Name $script:HostOperationLockName
    if (-not $lockPath -or -not (Test-YurunaSingleFlightLockOwned -Lock $LifetimeLock -Path $lockPath)) {
        return [pscustomobject]@{ Accepted = $false; Reason = 'lifetime-lock-not-held'; Row = $null }
    }
    # The same definition as Test.SingleInstance's boot epoch, which this
    # module does not import.
    $bootEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [Environment]::TickCount64
    $bodyArguments = @{
        RequestId = $RequestId; Mode = $Mode; RepoRoot = $RepoRoot; BootEpochMs = $bootEpochMs
        Controller = [ordered]@{ pid = $ControllerPid; startTimeUnixMs = $ControllerStartTimeUnixMs; snapshot = $Snapshot }
    }
    $body = {
        param($Journal, $Clock, $A)
        $answer = { param([string]$Why, $Row, [bool]$Accepted = $false) [pscustomobject]@{ Accepted = $Accepted; Reason = $Why; Row = $Row } }
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if (-not $request) { return @{ Changed = $false; Result = (& $answer 'no-request' $null) } }
        if ((Get-HostOperationRequestKind -Record $request) -cne $script:HostUpdateKind) { return @{ Changed = $false; Result = (& $answer 'refused-other-kind' $null) } }
        $update = Get-HostUpdateBlock -Request $request
        $state = [string]$request['state']
        if ($A.Mode -eq 'claim') {
            if ($state -ne 'queued') { return @{ Changed = $false; Result = (& $answer 'not-queued' $request) } }
            if ($Journal.owner -is [System.Collections.IDictionary] -and $Journal.owner['runtimeDir']) {
                if (-not (Test-HostOperationSameRuntime -Left ([string]$Journal.owner['runtimeDir']) -Right ([string]$request['runtimeDir']))) {
                    return @{ Changed = $false; Result = (& $answer 'owner-mismatch' $request) }
                }
            } else {
                $Journal.owner = [ordered]@{
                    runtimeDir = [string]$request['runtimeDir']; repoRoot = $A.RepoRoot; ownerId = 'host-controller'
                    userName = [Environment]::UserName; registeredUtc = $Clock.Utc
                }
            }
            $request['state'] = 'running'
            $update['controller'] = $A.Controller
            $update['claimedUtc'] = $Clock.Utc
            $update['bootEpochMs'] = $A.BootEpochMs
            return @{ Changed = $true; Result = (& $answer 'accepted-claim' $request $true) }
        }
        if ($state -notin @('running', 'recovery-pending')) { return @{ Changed = $false; Result = (& $answer 'not-claimed' $request) } }
        $recorded = $update['controller']
        if ($recorded -is [System.Collections.IDictionary] -and "$($recorded['pid'])" -cne "$($A.Controller.pid)") {
            $liveness = Get-HostOperationProcessLiveness -ProcessId $recorded['pid'] -StartTimeUnixMs $recorded['startTimeUnixMs']
            if ($liveness -ne 'dead') { return @{ Changed = $false; Result = (& $answer 'controller-alive' $request) } }
        }
        $update['controller'] = $A.Controller
        @{ Changed = $true; Result = (& $answer 'accepted-continue' $request $true) }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments $bodyArguments -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Accepted = $false; Reason = $run.Reason; Row = $null } }
    if ($run.Result.Accepted -and -not $run.Committed) { return [pscustomobject]@{ Accepted = $false; Reason = 'journal-unwritable'; Row = $null } }
    return $run.Result
}

function Set-HostUpdatePhase {
    <#
    .SYNOPSIS
        Journal that a phase started or finished, with what it recorded.
    .DESCRIPTION
        Written before a phase acts (started) and after it (finished), so a
        controller that starts again continues from the journal. A start
        counts one attempt of that phase. The runner plan is recorded once;
        a later plan is ignored. Stopped identities merge: an entry is only
        ever replaced by a newer identity, never cleared. Only the
        controller the row names may write.
    .PARAMETER RequestId
        The host update.
    .PARAMETER ControllerPid
        The writing controller's pid.
    .PARAMETER Phase
        The phase or activity token.
    .PARAMETER State
        started or finished.
    .PARAMETER Outcome
        finished only: done, skipped, failed or interrupted.
    .PARAMETER Reason
        A reason token.
    .PARAMETER Remarks
        Remark tokens; they also join the update's remarks.
    .PARAMETER Result
        The step result; only its allow-listed scalar fields are kept.
    .PARAMETER Child
        The step child: pid, startTimeUnixMs, expiryTick, bootEpochMs.
    .PARAMETER Plan
        The runner plan: start, basis.
    .PARAMETER Reclaimed
        Stopped identities: outer, cycle, inner, each { pid; startTimeUnixMs }.
    .PARAMETER Commit
        Commits: before, after, resident. before is kept from the first
        write: a later source update attempt starts from the commit an
        earlier one already pulled.
    .PARAMETER Drain
        The drain record: startedUnixMs, kept from the first write.
    .PARAMETER RunnerConsole
        The console the started runner got: tmux, window or none.
    .PARAMETER Mutated
        The host was changed.
    .PARAMETER ChildOnly
        With -State started and -Child: record the step child of the phase
        that is already started, without counting another attempt. The
        attempt is journaled before its child is launched, so a rerun after
        an interruption gets a new attempt number and result file.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason; Attempts }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ControllerPid,
        [Parameter(Mandatory)][ValidateScript({ $_ -cin $script:HostUpdatePhaseName })][string]$Phase,
        [Parameter(Mandatory)][ValidateSet('started', 'finished')][string]$State,
        [switch]$ChildOnly,
        [ValidateSet('done', 'skipped', 'failed', 'interrupted')][string]$Outcome,
        [ValidateScript({ $_ -cin $script:HostUpdateReason })][string]$Reason,
        [ValidateScript({ $_ -cin $script:HostUpdateRemark })][string[]]$Remarks,
        [System.Collections.IDictionary]$Result,
        [System.Collections.IDictionary]$Child,
        [System.Collections.IDictionary]$Plan,
        [System.Collections.IDictionary]$Reclaimed,
        [System.Collections.IDictionary]$Commit,
        [System.Collections.IDictionary]$Drain,
        [ValidateSet('tmux', 'window', 'none')][string]$RunnerConsole,
        [switch]$Mutated,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Written = $false; Reason = 'preview'; Attempts = 0 }
    }
    if ($State -eq 'finished' -and -not $Outcome) { return [pscustomobject]@{ Written = $false; Reason = 'outcome-missing'; Attempts = 0 } }
    if ($ChildOnly -and ($State -ne 'started' -or -not $Child)) { return [pscustomobject]@{ Written = $false; Reason = 'child-missing'; Attempts = 0 } }
    $arguments = @{
        ChildOnly = [bool]$ChildOnly
        Phase = $Phase; State = $State; Outcome = $Outcome; Reason = $Reason; Remarks = [string[]]@($Remarks | Where-Object { $_ })
        Result = $Result; Child = $Child; Plan = $Plan; Reclaimed = $Reclaimed; Commit = $Commit; Drain = $Drain
        RunnerConsole = $RunnerConsole; Mutated = [bool]$Mutated; ResultField = $script:HostUpdateResultField
    }
    $change = {
        param($Journal, $Clock, $A, $Request)
        $null = $Journal
        $update = Get-HostUpdateBlock -Request $Request
        if ($update['phases'] -isnot [System.Collections.IDictionary]) { $update['phases'] = [ordered]@{} }
        $entry = $update['phases'][$A.Phase]
        if ($entry -isnot [System.Collections.IDictionary]) {
            $entry = [ordered]@{
                attempts = 0; state = $null; outcome = $null; reason = $null; remarks = [string[]]@(); startedUtc = $null; finishedUtc = $null
                child = $null; result = $null
            }
            $update['phases'][$A.Phase] = $entry
        }
        $child = if ($A.Child) {
            [ordered]@{ pid = $A.Child['pid']; startTimeUnixMs = $A.Child['startTimeUnixMs']; expiryTick = $A.Child['expiryTick']; bootEpochMs = $A.Child['bootEpochMs'] }
        } else { $null }
        if ($A.ChildOnly) {
            if ([string]$entry['state'] -ne 'started') { return @{ Refused = 'phase-not-started' } }
            $entry['child'] = $child
            return @{ Changed = $true; Reason = 'written'; Value = [int]$entry['attempts'] }
        }
        if ($A.State -eq 'started') {
            $entry['attempts'] = [int]$entry['attempts'] + 1
            $entry['state'] = 'started'; $entry['outcome'] = $null; $entry['reason'] = $null; $entry['remarks'] = [string[]]@()
            $entry['startedUtc'] = $Clock.Utc; $entry['finishedUtc'] = $null; $entry['child'] = $child; $entry['result'] = $null
            $update['phase'] = $A.Phase
        } else {
            $entry['state'] = 'finished'; $entry['outcome'] = $A.Outcome
            $entry['reason'] = if ($A.Reason) { $A.Reason } else { $null }
            $entry['remarks'] = [string[]]$A.Remarks
            $entry['finishedUtc'] = $Clock.Utc
            if ($child) { $entry['child'] = $child }
            if ($A.Result) {
                $kept = [ordered]@{}
                foreach ($name in $A.ResultField) {
                    $value = $A.Result[$name]
                    if ($null -eq $value) { continue }
                    if ($value -is [string]) { if ($value.Length -le 128) { $kept[$name] = $value } }
                    elseif ($value -is [bool] -or $value -is [int] -or $value -is [long]) { $kept[$name] = $value }
                }
                $entry['result'] = $kept
            }
        }
        if ($A.Remarks.Count -gt 0) { $update['remarks'] = Add-HostUpdateToken -Existing $update['remarks'] -Token $A.Remarks }
        if ($A.Plan -and $update['runnerPlan'] -isnot [System.Collections.IDictionary]) {
            $basis = [string]$A.Plan['basis']
            $update['runnerPlan'] = [ordered]@{
                start = [bool]$A.Plan['start']
                basis = if ($basis -cin @('resident-alive', 'unclean-exit', 'clean-exit', 'no-launch-record', 'inherited')) { $basis } else { $null }
                recordedUtc = $Clock.Utc
            }
        }
        if ($A.Reclaimed) {
            if ($update['reclaimed'] -isnot [System.Collections.IDictionary]) { $update['reclaimed'] = [ordered]@{ outer = $null; cycle = $null; inner = $null } }
            foreach ($role in @('outer', 'cycle', 'inner')) {
                $identity = ConvertTo-HostUpdateIdentity -Identity $A.Reclaimed[$role]
                if ($identity) { $update['reclaimed'][$role] = $identity }
            }
        }
        if ($A.Commit) {
            if ($update['commit'] -isnot [System.Collections.IDictionary]) { $update['commit'] = [ordered]@{ before = $null; after = $null; resident = $null } }
            foreach ($name in @('before', 'after', 'resident')) {
                if ($name -ceq 'before' -and $update['commit']['before']) { continue }
                $sha = [string]$A.Commit[$name]
                if ($sha -cmatch '^[0-9a-f]{7,64}$') { $update['commit'][$name] = $sha }
            }
        }
        if ($A.Drain -and $update['drain'] -isnot [System.Collections.IDictionary]) {
            $started = [long]0
            if ([long]::TryParse("$($A.Drain['startedUnixMs'])", [ref]$started)) { $update['drain'] = [ordered]@{ startedUnixMs = $started } }
        }
        if ($A.RunnerConsole) { $update['runnerConsole'] = $A.RunnerConsole }
        if ($A.Mutated) { $update['mutated'] = $true }
        @{ Changed = $true; Reason = 'written'; Value = [int]$entry['attempts'] }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid $ControllerPid -Change $change -Arguments $arguments -UtcNow $UtcNow
    return [pscustomobject]@{ Written = [bool]$write.Written; Reason = [string]$write.Reason; Attempts = if ($write.Written) { [int]$write.Value } else { 0 } }
}

function Set-HostUpdateObligation {
    <#
    .SYNOPSIS
        Arm, discharge or dispose one obligation of a host update.
    .DESCRIPTION
        Arm before taking something away, discharge once it is given back.
        An obligation is added when first armed; a disposed one never
        changes again. Discharging or disposing one that was never armed
        changes nothing and reads as absent.
    .PARAMETER RequestId
        The host update.
    .PARAMETER ControllerPid
        The writing controller's pid.
    .PARAMETER ObligationId
        gate, runner, listener or elevation.
    .PARAMETER State
        armed, discharged or disposed.
    .PARAMETER Evidence
        Short evidence token for a discharge or a disposal.
    .PARAMETER Actor
        Who disposed it.
    .PARAMETER ListenerExpectedBackUtc
        With the listener armed: when the listener the update stopped is
        expected to answer again, for a page that loses its host.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason written|unchanged|absent|disposed|... }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ControllerPid,
        [Parameter(Mandatory)][ValidateSet('gate', 'runner', 'listener', 'elevation')][string]$ObligationId,
        [Parameter(Mandatory)][ValidateSet('armed', 'discharged', 'disposed')][string]$State,
        [ValidatePattern('^[a-z0-9][a-z0-9_.-]{0,63}$')][string]$Evidence,
        [string]$Actor,
        [ValidatePattern('\A\d{4}-\d{2}-\d{2}T[0-9:.]+Z\z')][string]$ListenerExpectedBackUtc,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Written = $false; Reason = 'preview' }
    }
    $arguments = @{
        ObligationId = $ObligationId; State = $State; Evidence = $Evidence; Actor = if ($Actor) { $Actor } else { [Environment]::UserName }
        ListenerExpectedBackUtc = if ($ObligationId -eq 'listener' -and $State -eq 'armed') { $ListenerExpectedBackUtc } else { $null }
    }
    $change = {
        param($Journal, $Clock, $A, $Request)
        $null = $Journal
        $expected = $false
        if ($A.ListenerExpectedBackUtc) {
            $update = Get-HostUpdateBlock -Request $Request
            if ([string]$update['listenerExpectedBackUtc'] -cne $A.ListenerExpectedBackUtc) { $update['listenerExpectedBackUtc'] = $A.ListenerExpectedBackUtc; $expected = $true }
        } elseif ($A.ObligationId -ceq 'listener' -and $A.State -ne 'armed') {
            # A listener that answers again owes no time; a later stop sets
            # its own, so an old one never reappears.
            $update = Get-HostUpdateBlock -Request $Request
            if ($null -ne $update['listenerExpectedBackUtc']) { $update['listenerExpectedBackUtc'] = $null; $expected = $true }
        }
        $row = $null
        foreach ($candidate in @($Request['obligations'])) { if ($candidate -is [System.Collections.IDictionary] -and [string]$candidate['id'] -ceq $A.ObligationId) { $row = $candidate } }
        if (-not $row) {
            if ($A.State -ne 'armed') { return @{ Changed = $false; Reason = 'absent' } }
            $row = [ordered]@{
                id = $A.ObligationId; kind = $script:HostUpdateKind; target = $null; required = $true; status = 'pending'
                armedGeneration = $null; updatedUtc = $null; disposedBy = $null; evidence = $null
            }
            if ($Request['obligations'] -isnot [System.Collections.IList] -or $Request['obligations'].IsFixedSize) {
                $Request['obligations'] = ConvertTo-HostOperationList -Value $Request['obligations']
            }
            $Request['obligations'].Add($row)
        }
        if ([string]$row['status'] -eq 'disposed') { return @{ Changed = $false; Reason = if ($A.State -eq 'disposed') { 'unchanged' } else { 'disposed' } } }
        if ([string]$row['status'] -eq $A.State) { return @{ Changed = $expected; Reason = if ($expected) { 'written' } else { 'unchanged' } } }
        $row['status'] = $A.State
        $row['updatedUtc'] = $Clock.Utc
        if ($A.State -eq 'discharged') { $row['evidence'] = if ($A.Evidence) { $A.Evidence } else { 'verified' } }
        if ($A.State -eq 'disposed') {
            $row['disposedBy'] = $A.Actor
            if ($A.Evidence) { $row['evidence'] = $A.Evidence }
        }
        @{ Changed = $true; Reason = 'written' }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid $ControllerPid -Change $change -Arguments $arguments -UtcNow $UtcNow
    if ($write.Written -and $write.Reason -eq 'disposed') { return [pscustomobject]@{ Written = $false; Reason = 'disposed' } }
    return [pscustomobject]@{ Written = [bool]$write.Written; Reason = [string]$write.Reason }
}

function Set-HostUpdateRecovering {
    <#
    .SYNOPSIS
        Mark a host update recovering: its runner is to be started and is
        not running, and the controller keeps trying.
    .PARAMETER RequestId
        The host update.
    .PARAMETER ControllerPid
        The writing controller's pid.
    .PARAMETER OperatorAction
        repair_checkout, act_at_host or release.
    .PARAMETER Reason
        The reason token of the failed start.
    .PARAMETER NextUnixMs
        When the next attempt is due.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ControllerPid,
        [Parameter(Mandatory)][ValidateSet('repair_checkout', 'act_at_host', 'release')][string]$OperatorAction,
        [Parameter(Mandatory)][ValidateScript({ $_ -cin $script:HostUpdateReason })][string]$Reason,
        [Parameter(Mandatory)][long]$NextUnixMs,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Written = $false; Reason = 'preview' }
    }
    $arguments = @{ OperatorAction = $OperatorAction; Reason = $Reason; NextUnixMs = $NextUnixMs }
    $change = {
        param($Journal, $Clock, $A, $Request)
        $null = $Journal
        $update = Get-HostUpdateBlock -Request $Request
        $Request['state'] = 'recovery-pending'
        $update['verdict'] = 'recovering'
        $update['operatorAction'] = $A.OperatorAction
        $update['reason'] = $A.Reason
        $recover = if ($update['phases'] -is [System.Collections.IDictionary]) { $update['phases']['recover'] } else { $null }
        $attempts = if ($recover -is [System.Collections.IDictionary]) { [int]$recover['attempts'] } else { 0 }
        $since = if ($update['recovering'] -is [System.Collections.IDictionary] -and $update['recovering']['sinceUtc']) { $update['recovering']['sinceUtc'] } else { $Clock.Utc }
        $update['recovering'] = [ordered]@{ sinceUtc = $since; attempts = $attempts; nextUnixMs = $A.NextUnixMs; operatorAction = $A.OperatorAction }
        @{ Changed = $true; Reason = 'written' }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid $ControllerPid -Change $change -Arguments $arguments -UtcNow $UtcNow
    return [pscustomobject]@{ Written = [bool]$write.Written; Reason = [string]$write.Reason }
}

function Complete-HostUpdate {
    <#
    .SYNOPSIS
        Write a host update's verdict and close its row.
    .DESCRIPTION
        A refused update ends in the state refused, every other verdict in
        completed; the tombstone keeps the kind and the verdict. No verdict
        is written while the gate obligation is armed: the runner's
        acknowledgment, or the controller itself, opens the gate first.
    .PARAMETER RequestId
        The host update.
    .PARAMETER ControllerPid
        The writing controller's pid.
    .PARAMETER Verdict
        The verdict token.
    .PARAMETER OperatorAction
        The operator action token.
    .PARAMETER Reason
        A reason token.
    .PARAMETER Remarks
        Remark tokens added to the update's remarks.
    .PARAMETER Debt
        Obligations still armed at the end: listener, elevation.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason; State }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$ControllerPid,
        [Parameter(Mandatory)][ValidateScript({ $_ -cin $script:HostUpdateVerdict })][string]$Verdict,
        [Parameter(Mandatory)][ValidateScript({ $_ -cin $script:HostUpdateOperatorAction })][string]$OperatorAction,
        [ValidateScript({ $_ -cin $script:HostUpdateReason })][string]$Reason,
        [ValidateScript({ $_ -cin $script:HostUpdateRemark })][string[]]$Remarks,
        [ValidateSet('listener', 'elevation')][string[]]$Debt,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Written = $false; Reason = 'preview'; State = $null }
    }
    $arguments = @{ Verdict = $Verdict; OperatorAction = $OperatorAction; Reason = $Reason; Remarks = [string[]]@($Remarks | Where-Object { $_ }); Debt = [string[]]@($Debt | Where-Object { $_ }) }
    $change = {
        param($Journal, $Clock, $A, $Request)
        if (@(Get-HostOperationArmedObligation -Request $Request) -ccontains 'gate') { return @{ Refused = 'gate-armed' } }
        Complete-HostUpdateRow -Journal $Journal -Request $Request -Verdict $A.Verdict -OperatorAction $A.OperatorAction -Reason $A.Reason -Remarks $A.Remarks -Debt $A.Debt -Clock $Clock
        @{ Changed = $true; Reason = 'written'; Value = [string]$Request['state'] }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid $ControllerPid -Change $change -Arguments $arguments -UtcNow $UtcNow
    return [pscustomobject]@{ Written = [bool]$write.Written; Reason = [string]$write.Reason; State = if ($write.Written) { [string]$write.Value } else { $null } }
}

function Set-HostUpdateClaimBlocked {
    <#
    .SYNOPSIS
        Mark a queued host update that this controller cannot claim.
    .DESCRIPTION
        The row stays queued and housekeeping expires it as it expires every
        unclaimed request; the mark lets the public state name the cause.
    .PARAMETER RequestId
        The queued host update.
    .PARAMETER Reason
        protocol_mismatch.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason written|unchanged|... }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('protocol_mismatch')][string]$Reason,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Written = $false; Reason = 'preview' }
    }
    $change = {
        param($Journal, $Clock, $A, $Request)
        $null = $Journal, $Clock
        $update = Get-HostUpdateBlock -Request $Request
        if ([string]$update['claimBlocked'] -ceq $A.Reason) { return @{ Changed = $false; Reason = 'unchanged' } }
        $update['claimBlocked'] = $A.Reason
        @{ Changed = $true; Reason = 'written' }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid 0 -Change $change -Arguments @{ Reason = $Reason } -AllowedState @('queued') -UtcNow $UtcNow
    return [pscustomobject]@{ Written = [bool]$write.Written; Reason = [string]$write.Reason }
}

function Request-HostUpdateRelease {
    <#
    .SYNOPSIS
        Ask the running controller to release a claimed host update.
    .DESCRIPTION
        Sets a release mark on a running or recovery-pending row in one
        transaction; the controller honors it at its next check. A mark
        already set is kept.
    .PARAMETER RequestId
        The host update.
    .PARAMETER Actor
        Who asked.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Decision marked|not-found|terminal|
        not-releasable|unavailable; Row; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Actor,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Decision = 'unavailable'; Row = $null; Reason = 'preview' }
    }
    $body = {
        param($Journal, $Clock, $A)
        $answer = { param([string]$Decision, $Row) [pscustomobject]@{ Decision = $Decision; Row = $Row; Reason = $Decision } }
        $request = Find-HostOperationRequest -Journal $Journal -RequestId $A.RequestId
        if ($request -and (Get-HostOperationRequestKind -Record $request) -cne $script:HostUpdateKind) { $request = $null }
        if (-not $request) {
            $tombstone = Find-HostOperationTombstone -Journal $Journal -RequestId $A.RequestId
            $decision = if ($tombstone -and (Get-HostOperationRequestKind -Record $tombstone) -ceq $script:HostUpdateKind) { 'terminal' } else { 'not-found' }
            return @{ Changed = $false; Result = (& $answer $decision $null) }
        }
        $state = [string]$request['state']
        if ($state -in $script:HostOperationTerminalState) { return @{ Changed = $false; Result = (& $answer 'terminal' $request) } }
        if ($state -notin @('running', 'recovery-pending')) { return @{ Changed = $false; Result = (& $answer 'not-releasable' $request) } }
        $update = Get-HostUpdateBlock -Request $request
        if ($update['release'] -is [System.Collections.IDictionary]) { return @{ Changed = $false; Result = (& $answer 'marked' $request) } }
        $update['release'] = [ordered]@{ requestedUtc = $Clock.Utc; by = $A.Actor }
        @{ Changed = $true; Result = (& $answer 'marked' $request) }
    }
    $run = Invoke-HostOperationJournalTransaction -Body $body -Arguments @{ RequestId = $RequestId; Actor = $Actor } -UtcNow $UtcNow
    if (-not $run.Ran) { return [pscustomobject]@{ Decision = 'unavailable'; Row = $null; Reason = $run.Reason } }
    if (-not $run.Committed) { return [pscustomobject]@{ Decision = 'unavailable'; Row = $null; Reason = 'journal-unwritable' } }
    return $run.Result
}

function Complete-HostUpdateRelease {
    <#
    .SYNOPSIS
        Release a claimed host update that no controller is running.
    .DESCRIPTION
        For the host command, which holds the controller lock and the
        lifetime lock and has already opened the gate: the gate and runner
        obligations are disposed by the actor, and the row ends as released
        with every obligation still armed listed as debt.
    .PARAMETER RequestId
        The host update.
    .PARAMETER Actor
        Who released it.
    .PARAMETER LifetimeLock
        The held lifetime lock (host-operation.lock).
    .PARAMETER ElevationCleared
        The command removed the temporary sudo rule and ended the transient
        units: the elevation obligation is discharged, not debt.
    .PARAMETER UtcNow
        Injected clock.
    .OUTPUTS
        [pscustomobject] @{ Released; Reason; Debt }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Actor,
        [Parameter(Mandatory)][AllowNull()]$LifetimeLock,
        [switch]$ElevationCleared,
        [scriptblock]$UtcNow
    )
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) {
        return [pscustomobject]@{ Released = $false; Reason = 'preview'; Debt = [string[]]@() }
    }
    $lockPath = Get-HostOperationPrivateFile -Name $script:HostOperationLockName
    if (-not $lockPath -or -not (Test-YurunaSingleFlightLockOwned -Lock $LifetimeLock -Path $lockPath)) {
        return [pscustomobject]@{ Released = $false; Reason = 'lifetime-lock-not-held'; Debt = [string[]]@() }
    }
    $change = {
        param($Journal, $Clock, $A, $Request)
        foreach ($obligation in @($Request['obligations'])) {
            if ($obligation -is [System.Collections.IDictionary] -and [string]$obligation['status'] -eq 'armed' -and [string]$obligation['id'] -cin @('gate', 'runner')) {
                $obligation['status'] = 'disposed'; $obligation['disposedBy'] = $A.Actor; $obligation['updatedUtc'] = $Clock.Utc
            }
            if ($A.ElevationCleared -and $obligation -is [System.Collections.IDictionary] -and [string]$obligation['status'] -eq 'armed' -and [string]$obligation['id'] -ceq 'elevation') {
                $obligation['status'] = 'discharged'; $obligation['evidence'] = 'rule-removed'; $obligation['updatedUtc'] = $Clock.Utc
            }
        }
        $debt = [string[]]@(Get-HostOperationArmedObligation -Request $Request)
        $update = Get-HostUpdateBlock -Request $Request
        if ($update['release'] -isnot [System.Collections.IDictionary]) { $update['release'] = [ordered]@{ requestedUtc = $Clock.Utc; by = $A.Actor } }
        Complete-HostUpdateRow -Journal $Journal -Request $Request -Verdict 'released' -OperatorAction 'none' -Debt $debt -Clock $Clock
        @{ Changed = $true; Reason = 'released'; Value = $debt }
    }
    $write = Invoke-HostUpdateRowChange -RequestId $RequestId -ControllerPid 0 -Change $change -Arguments @{ Actor = $Actor; ElevationCleared = [bool]$ElevationCleared } -UtcNow $UtcNow
    return [pscustomobject]@{
        Released = [bool]$write.Written; Reason = [string]$write.Reason
        Debt = if ($write.Written) { [string[]]@($write.Value) } else { [string[]]@() }
    }
}

# --- REGION: Public: macOS automation grant evidence
function Get-YurunaHostRepairAutomationSubject {
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
    $path = Get-HostOperationPrivateFile -Name $script:HostOperationGrantName -NoCreate
    if (-not $path) { return }
    $record = Read-YurunaCriticalRecord -Path $path -Kind $script:HostOperationGrantKind
    if ($record.Status -ne 'ok' -or $record.Payload -isnot [System.Collections.IDictionary]) { return }
    foreach ($row in (ConvertTo-HostOperationList -Value $record.Payload['subjects'])) {
        if ($row -is [System.Collections.IDictionary] -and $row['subject']) { [string]$row['subject'] }
    }
}

function Add-YurunaHostRepairAutomationSubject {
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
    if (-not $PSCmdlet.ShouldProcess($Subject, (Format-YurunaOperatorMessage -Key 'runner.host_operation_should_process_admission'))) { return [pscustomobject]@{ Saved = $false; Reason = 'preview' } }
    $path = Get-HostOperationPrivateFile -Name $script:HostOperationGrantName
    $lockPath = Get-HostOperationPrivateFile -Name $script:HostOperationAdmissionName
    if (-not $path -or -not $lockPath) { return [pscustomobject]@{ Saved = $false; Reason = 'private-root-unavailable' } }
    $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds 5000 -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-repair-automation-grant' }
    if (-not $lock.Held) { return [pscustomobject]@{ Saved = $false; Reason = "lock-$($lock.Reason)" } }
    try {
        $clock = Get-HostOperationClockValue -UtcNow $UtcNow
        $read = Read-YurunaCriticalRecord -Path $path -Kind $script:HostOperationGrantKind
        if ($read.Status -notin @('ok', 'missing')) { return [pscustomobject]@{ Saved = $false; Reason = "record-$($read.Status)" } }
        $rows = [System.Collections.Generic.List[object]]::new()
        if ($read.Status -eq 'ok' -and $read.Payload -is [System.Collections.IDictionary]) {
            foreach ($row in (ConvertTo-HostOperationList -Value $read.Payload['subjects'])) {
                if ($row -is [System.Collections.IDictionary] -and $row['subject'] -and [string]$row['subject'] -cne $Subject) { $rows.Add($row) }
            }
        }
        $rows.Add([ordered]@{ subject = $Subject; observedUtc = $clock.Utc })
        while ($rows.Count -gt $script:HostOperationGrantCap) { $rows.RemoveAt(0) }
        $write = Write-YurunaCriticalRecord -Path $path -Kind $script:HostOperationGrantKind -Payload ([ordered]@{ schemaVersion = 1; subjects = [object[]]$rows.ToArray() }) `
            -ExpectedGeneration ([long]$read.Generation) -Confirm:$false
        return [pscustomobject]@{ Saved = [bool]$write.Committed; Reason = [string]$write.Reason }
    } finally {
        Exit-YurunaSingleFlightLock -Lock $lock
    }
}

Export-ModuleMember -Function Get-HostOperationPrivateRoot, Get-YurunaHostRepairRequestPath, Get-YurunaHostOperationLockPath, `
    Get-YurunaHostOperationAdmissionLockPath, Get-HostRepairPrivateWorkDir, New-YurunaHostOperationRequestId, `
    Read-HostOperationJournal, Read-YurunaHostRepairRequest, Get-HostOperationActiveRequest, Get-HostRepairResult, `
    Get-HostRepairAdmissionDecision, Request-HostRepairAdmission, Set-HostRepairLaunchOutcome, Stop-HostRepairQueuedRequest, `
    Confirm-HostRepairIntent, Save-HostRepairRecoveryRecord, Set-HostRepairObligationState, Set-HostRepairObligationDisposition, `
    Complete-HostRepairAttempt, Set-HostRepairCallerAck, `
    Request-StartCycleReservation, Set-StartCycleLaunch, Confirm-StartCycleReservation, `
    Complete-StartCycleReservation, Get-YurunaHostRepairAutomationSubject, Add-YurunaHostRepairAutomationSubject, `
    Get-HostUpdateProtocolVersion, Get-HostUpdateControllerLockPath, Get-HostUpdateControllerRoot, Get-HostUpdateConsoleHint, Get-HostUpdateControllerLockState, `
    Format-HostUpdateGateRefusal, Request-HostUpdateAdmission, Get-HostUpdateRequest, Get-HostUpdateQueue, Get-HostUpdateCapability, Confirm-HostUpdateClaim, Set-HostUpdatePhase, `
    Set-HostUpdateObligation, Set-HostUpdateRecovering, Complete-HostUpdate, Set-HostUpdateClaimBlocked, Request-HostUpdateRelease, `
    Complete-HostUpdateRelease, Get-HostUpdateInstallerCopyDirectory, New-HostUpdateWindowsAdminOnlyDirectory, Test-HostUpdateWindowsAdminOnlyAcl
