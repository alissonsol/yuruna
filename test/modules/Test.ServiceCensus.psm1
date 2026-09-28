<#PSScriptInfo
.VERSION 2026.09.27
.GUID 422e4da5-c4d3-416f-8529-84b6ec995443
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna service census intent lock
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
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -DisableNameChecking

# The service census: what this host last knew about each managed service,
# which lifecycle operation an operator last asked for, and who may start or
# stop a service right now.
#
# Four things live here and nowhere else, all under the private state root
# ($HOME/.yuruna/host-refresh, never inside a served tree):
#
#   * service-census.record -- one checksummed, generation-numbered record
#     (Test.CriticalRecord) holding per-service evidence and the newest
#     explicit start/stop intent. Written only under service-census.lock.
#   * service-census.lock -- the short merge lock (rank CensusMerge). Never
#     held while waiting for a longer lock, so it cannot deadlock a service
#     operation.
#   * service-operation.<key>.lock -- one per logical service (rank
#     ServiceKey). Start and Stop scripts, the reboot sweep and the refresh
#     worker all take it, in ordinal key order, before touching a service.
#   * the capability table -- which uses of census evidence a platform has
#     earned, as a pure declaration.
#
# This module deliberately names no command that can raise an Apple Event,
# query hypervisor state through the control channel, or start or stop a
# guest: the beacon runs its tick every few seconds on a host whose control
# channel may be the thing that is wedged, and one blocked call there would
# stall the beacon's own announcements. Addresses come only from the
# platform's passive resolver (Get-VMPassiveAddressContext,
# Get-VMPassiveAddress, Get-PortMapTarget), resolved by name at call time,
# and from files. A static scan of this file pins the rule.
#
# Timestamps are authoritative as ...UnixMs numbers. Nothing here parses an
# ISO string back for a decision: ConvertFrom-Json turns those into local
# DateTime values, and a comparison of those drifts with the host's time zone
# (feedback_datetime-compare-is-timezone-sensitive.md).

$script:CensusSchemaVersion      = 1
$script:CensusRecordName         = 'service-census.record'
$script:CensusLockName           = 'service-census.lock'
$script:CensusRecordKind         = 'service-census'
# Positive evidence expires after a day: long enough to cover a control
# channel that stays wedged overnight, short enough that a guest address
# reused by another machine does not stay trusted.
$script:EvidenceLifetimeSeconds  = 86400
$script:ResolveIntervalMs        = 600000
$script:MutatorLockWaitMs        = 5000
$script:TickLockWaitMs           = 1000
$script:OperationWaitSeconds     = 30
$script:HistoryCap               = 8
$script:ServiceKeyPattern        = '^[a-z0-9][a-z0-9-]{0,62}$'
$script:VMNamePattern            = '^[a-zA-Z0-9._-]+$'
$script:WriteSuppressProbeMs     = 300000
$script:WriteSuppressAnswerMs    = 60000
$script:RootCacheMs              = 600000
$script:RootCache                = $null
# The last passive resolution attempted per root, service and guest, kept for
# the life of the process. The beacon is the one long-lived caller, and a
# resolution that found nothing (a lease-only match, an ARP miss, a stopped
# guest) leaves no address in the census to postpone the next one, so without
# this every tick would re-read the ARP table, the lease file and the
# interfaces.
$script:ResolveAttempt           = @{}
# One entry per host type. Flipping a capability is one edit here, made
# only after that platform has shown the evidence it stands for. Each
# withheld capability carries its own reason; the first one withheld, store
# before corroboration, is the reason the evidence cannot be used.
$script:CensusCapability = @{
    'host.ubuntu.kvm'      = @{ Store = $true;  StoreReason = ''; Corroboration = $false; CorroborationReason = 'no-passive-resolver' }
    'host.macos.utm'       = @{ Store = $false; StoreReason = 'lock-contention-unverified-on-macos'
        Corroboration = $false; CorroborationReason = 'passive-resolver-unverified-on-macos' }
    'host.windows.hyper-v' = @{ Store = $false; StoreReason = 'census-unqualified-on-windows'
        Corroboration = $false; CorroborationReason = 'census-unqualified-on-windows' }
}

function Get-ServiceCensusUtcNow {
    <#
    .SYNOPSIS
        The current UTC time in Unix milliseconds.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Get-ServiceCensusProcessStart {
    <#
    .SYNOPSIS
        This process's start time in Unix milliseconds, or 0 when unreadable.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    try {
        $start = (Get-Process -Id $PID -ErrorAction Stop).StartTime
        return [DateTimeOffset]::new($start).ToUnixTimeMilliseconds()
    } catch {
        return [long]0
    }
}

function Test-ServiceCensusPlainDirectory {
    <#
    .SYNOPSIS
        $true when Path is an existing directory that is not a link or
        reparse point.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $info = [System.IO.DirectoryInfo]::new($Path)
    if (-not $info.Exists) { return $false }
    if ($info.LinkTarget) { return $false }
    if ($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $false }
    return $true
}

function Resolve-ServiceCensusRoot {
    <#
    .SYNOPSIS
        The private state root the census lives in: {Resolved; Path; Reason}.
    .DESCRIPTION
        An explicit StateRoot is used as given once it is shown to be a plain
        directory; the refresh worker passes the root it already verified,
        and tests pass a private one. Otherwise the root comes from
        Get-YurunaPrivateStateRoot, observe-only for readers. A writer's
        successful resolution is cached for ten minutes, because the beacon
        ticks every few seconds and the full check reads owners and modes
        each time; the cached path is still re-checked for a link on every
        use.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$StateRoot,
        [switch]$ReadOnly
    )
    if (-not [string]::IsNullOrWhiteSpace($StateRoot)) {
        $full = [System.IO.Path]::GetFullPath($StateRoot)
        if (Test-ServiceCensusPlainDirectory -Path $full) {
            return [pscustomobject]@{ Resolved = $true; Path = $full; Reason = 'ok' }
        }
        $why = if ([System.IO.Directory]::Exists($full)) { 'reparse-point' } else { 'absent' }
        return [pscustomobject]@{ Resolved = $false; Path = $full; Reason = $why }
    }
    $now = [Environment]::TickCount64
    if ($script:RootCache -and $now -lt $script:RootCache.ExpiresTick -and
        (Test-ServiceCensusPlainDirectory -Path $script:RootCache.Path)) {
        return [pscustomobject]@{ Resolved = $true; Path = $script:RootCache.Path; Reason = 'ok' }
    }
    $rootArguments = @{}
    if ($ReadOnly) { $rootArguments.NoCreate = $true }
    $root = $null
    try { $root = Get-YurunaPrivateStateRoot @rootArguments } catch {
        Write-Verbose "Resolve-ServiceCensusRoot: $($_.Exception.Message)"
        return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'resolve-failed' }
    }
    if (-not $root.Resolved) {
        return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = [string]$root.Reason }
    }
    if (-not $ReadOnly) {
        $script:RootCache = [pscustomobject]@{ Path = [string]$root.Path; ExpiresTick = $now + $script:RootCacheMs }
    }
    return [pscustomobject]@{ Resolved = $true; Path = [string]$root.Path; Reason = 'ok' }
}

function ConvertTo-ServiceCensusLong {
    <#
    .SYNOPSIS
        A JSON number (or $null) as a [long], 0 when absent or unparseable.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return [long]0 }
    $parsed = [long]0
    if ([long]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    try { return [long][Math]::Floor([double]$Value) } catch { return [long]0 }
}

function ConvertTo-ServiceCensusIntent {
    <#
    .SYNOPSIS
        One intent record, normalized to its full field set, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()]$Intent)
    if ($null -eq $Intent -or -not ($Intent -is [System.Collections.IDictionary])) { return $null }
    $generation = ConvertTo-ServiceCensusLong -Value $Intent['generation']
    if ($generation -le 0) { return $null }
    return [ordered]@{
        generation           = $generation
        operation            = [string]$Intent['operation']
        result               = [string]$Intent['result']
        desiredState         = [string]$Intent['desiredState']
        baselineDesiredState = [string]$Intent['baselineDesiredState']
        vmName               = [string]$Intent['vmName']
        hostingMode          = [string]$Intent['hostingMode']
        publishedUnixMs      = ConvertTo-ServiceCensusLong -Value $Intent['publishedUnixMs']
        completedUnixMs      = ConvertTo-ServiceCensusLong -Value $Intent['completedUnixMs']
        script               = [string]$Intent['script']
        pid                  = [int](ConvertTo-ServiceCensusLong -Value $Intent['pid'])
        processStartUnixMs   = ConvertTo-ServiceCensusLong -Value $Intent['processStartUnixMs']
        finalState           = [string]$Intent['finalState']
    }
}

function Get-ServiceEffectiveDesiredState {
    <#
    .SYNOPSIS
        The desired state an intent leaves in force: stopped, running or ''.
    .DESCRIPTION
        An explicit stop stands whatever its result, because a failed stop is
        still an operator's request that the service stay down. A start
        changes the desired state only once it is confirmed; until then, or
        when it failed, the state before it stays in force. Desired state
        never expires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Intent)
    if ($null -eq $Intent) { return '' }
    if ((ConvertTo-ServiceCensusLong -Value $Intent['generation']) -le 0) { return '' }
    switch ([string]$Intent['operation']) {
        'stop'  { return 'stopped' }
        'start' {
            if ([string]$Intent['result'] -eq 'confirmed') { return 'running' }
            return [string]$Intent['baselineDesiredState']
        }
    }
    return ''
}

function New-ServiceCensusServiceRecord {
    <#
    .SYNOPSIS
        An empty per-service census record with every field present.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Key)
    return [ordered]@{
        key                            = $Key
        vmName                         = ''
        vmNameSource                   = ''
        source                         = ''
        hostingMode                    = ''
        healthPort                     = 0
        address                        = ''
        addressOrigin                  = 'none'
        addressResolvedUnixMs          = [long]0
        bundleMac                      = ''
        networkMode                    = ''
        macCorroborated                = $false
        lastAnsweredUnixMs             = [long]0
        lastAnsweredAddress            = ''
        lastAnsweredIdentity           = ''
        lastUncorroboratedAnswerUnixMs = [long]0
        lastProbeUnixMs                = [long]0
        lastProbeOutcome               = ''
        desiredState                   = ''
        intentGeneration               = [long]0
        intent                         = $null
        history                        = [object[]]@()
    }
}

function ConvertTo-ServiceCensusServiceRecord {
    <#
    .SYNOPSIS
        A per-service record read back from JSON, normalized to typed fields
        with history always an array.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Record
    )
    $out = New-ServiceCensusServiceRecord -Key $Key
    if ($null -eq $Record -or -not ($Record -is [System.Collections.IDictionary])) { return $out }
    foreach ($name in @('vmName', 'vmNameSource', 'source', 'hostingMode', 'address', 'addressOrigin', 'bundleMac',
            'networkMode', 'lastAnsweredAddress', 'lastAnsweredIdentity', 'lastProbeOutcome')) {
        if ($null -ne $Record[$name]) { $out[$name] = [string]$Record[$name] }
    }
    if ([string]::IsNullOrEmpty($out.addressOrigin)) { $out.addressOrigin = 'none' }
    foreach ($name in @('addressResolvedUnixMs', 'lastAnsweredUnixMs', 'lastUncorroboratedAnswerUnixMs', 'lastProbeUnixMs')) {
        $out[$name] = ConvertTo-ServiceCensusLong -Value $Record[$name]
    }
    $out.healthPort = [int](ConvertTo-ServiceCensusLong -Value $Record['healthPort'])
    $out.macCorroborated = [bool]$Record['macCorroborated']
    $out.intent = ConvertTo-ServiceCensusIntent -Intent $Record['intent']
    $history = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Record['history'])) {
        $normalized = ConvertTo-ServiceCensusIntent -Intent $entry
        if ($null -ne $normalized -and $history.Count -lt $script:HistoryCap) { $history.Add($normalized) }
    }
    $out.history = [object[]]$history.ToArray()
    $out.desiredState = Get-ServiceEffectiveDesiredState -Intent $out.intent
    $out.intentGeneration = if ($out.intent) { [long]$out.intent.generation } else { [long]0 }
    return $out
}

function ConvertTo-ServiceCensusState {
    <#
    .SYNOPSIS
        A census payload (hashtable from Read-YurunaCriticalRecord) as a
        mutable, normalized state, or a fresh empty one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()]$Payload)
    $state = [ordered]@{
        schemaVersion           = $script:CensusSchemaVersion
        intentCounter           = [long]0
        evidenceLifetimeSeconds = $script:EvidenceLifetimeSeconds
        evidenceLifetimeOrigin  = 'default'
        services                = [ordered]@{}
    }
    if ($null -eq $Payload -or -not ($Payload -is [System.Collections.IDictionary])) { return $state }
    $state.intentCounter = ConvertTo-ServiceCensusLong -Value $Payload['intentCounter']
    $lifetime = ConvertTo-ServiceCensusLong -Value $Payload['evidenceLifetimeSeconds']
    if ($lifetime -gt 0) {
        $state.evidenceLifetimeSeconds = [int][Math]::Min($lifetime, [long][int]::MaxValue)
        $origin = [string]$Payload['evidenceLifetimeOrigin']
        $state.evidenceLifetimeOrigin = if ($origin -in @('default', 'parameter')) { $origin } else { 'default' }
    }
    $services = $Payload['services']
    if ($services -is [System.Collections.IDictionary]) {
        foreach ($name in @($services.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
            if ($name -cnotmatch $script:ServiceKeyPattern) { continue }
            $state.services[$name] = ConvertTo-ServiceCensusServiceRecord -Key $name -Record $services[$name]
            $top = [long]$state.services[$name].intentGeneration
            if ($top -gt $state.intentCounter) { $state.intentCounter = $top }
        }
    }
    return $state
}

function Read-ServiceCensusState {
    <#
    .SYNOPSIS
        Read the census record under Root: {Status; Reason; Detail;
        Generation; State; Path}. Never creates anything.
    .DESCRIPTION
        An I/O failure or timeout is 'unreadable', not 'corrupt': it says
        nothing about the file's content, and a read taken a moment later
        may succeed. Damage, a link in the record's place or a record of
        another kind is 'corrupt', which stays until someone repairs it.
        Detail carries the record reader's own status either way.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        $Deadline
    )
    $path = Join-Path $Root $script:CensusRecordName
    $readArguments = @{ Path = $path; Kind = $script:CensusRecordKind }
    if ($Deadline) { $readArguments.Deadline = $Deadline }
    $read = Read-YurunaCriticalRecord @readArguments
    $record = [ordered]@{ Status = [string]$read.Status; Reason = 'ok'; Detail = ''; Generation = [long]$read.Generation; State = $null; Path = $path }
    switch ($read.Status) {
        'ok' {
            $payload = $read.Payload
            $version = ConvertTo-ServiceCensusLong -Value $payload['schemaVersion']
            if ($version -ne $script:CensusSchemaVersion) {
                $record.Reason = 'unsupported-version'
                return [pscustomobject]$record
            }
            $record.State = ConvertTo-ServiceCensusState -Payload $payload
        }
        'missing' {
            $record.Reason = 'absent'
            $record.State = ConvertTo-ServiceCensusState -Payload $null
        }
        'unsupported-version' { $record.Reason = 'unsupported-version'; $record.Detail = 'unsupported-version' }
        { $_ -in @('io-error', 'io-timeout') } { $record.Reason = 'unreadable'; $record.Detail = [string]$read.Status }
        default { $record.Reason = 'corrupt'; $record.Detail = [string]$read.Status }
    }
    return [pscustomobject]$record
}

function ConvertTo-ServiceCensusPayload {
    <#
    .SYNOPSIS
        The JSON-ready payload for a census state.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$State)
    $services = [ordered]@{}
    foreach ($name in @($State.services.Keys | Sort-Object)) {
        $svc = $State.services[$name]
        $copy = [ordered]@{}
        foreach ($field in $svc.Keys) { $copy[$field] = $svc[$field] }
        $copy.history = [object[]]@($svc.history | Select-Object -First $script:HistoryCap)
        $services[$name] = $copy
    }
    return [ordered]@{
        schemaVersion           = $script:CensusSchemaVersion
        intentCounter           = [long]$State.intentCounter
        evidenceLifetimeSeconds = [int]$State.evidenceLifetimeSeconds
        evidenceLifetimeOrigin  = [string]$State.evidenceLifetimeOrigin
        writtenUtc              = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        services                = $services
    }
}

function Invoke-ServiceCensusMutation {
    <#
    .SYNOPSIS
        Read-modify-write the census under its merge lock.
    .DESCRIPTION
        The mutation scriptblock is called as & $Mutation $State $Output $Argument
        and returns $true when it changed something worth writing; it may set
        $Output.Output to hand a value back. A census that cannot be read as
        a valid record is never overwritten: losing an operator's stop intent
        to a rewrite of an unreadable file is the failure this lock exists to
        prevent.
    .OUTPUTS
        [pscustomobject] @{ Reason ok|lock-busy|corrupt|unreadable|
        unsupported-version|write-failed|unchanged|deadline-exhausted; Detail;
        Wrote; Generation; Output }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [hashtable]$Argument = @{},
        [ValidateRange(0, 600000)][int]$LockWaitMilliseconds = 1000,
        $Deadline
    )
    $mutationResult = [ordered]@{ Reason = 'lock-busy'; Detail = ''; Wrote = $false; Generation = [long]0; Output = $null }
    $censusLockArguments = @{
        Path             = (Join-Path $Root $script:CensusLockName)
        Rank             = (Get-YurunaLockRank -Name CensusMerge)
        WaitMilliseconds = $LockWaitMilliseconds
        Metadata         = @{ purpose = 'service-census-merge' }
    }
    if ($Deadline) { $censusLockArguments.Deadline = $Deadline }
    $censusLock = Enter-YurunaSingleFlightLock @censusLockArguments
    if (-not $censusLock.Held) {
        Write-Verbose "Invoke-ServiceCensusMutation: census lock not taken ($($censusLock.Reason))."
        $mutationResult.Detail = [string]$censusLock.Reason
        return [pscustomobject]$mutationResult
    }
    try {
        $censusRead = Read-ServiceCensusState -Root $Root -Deadline $Deadline
        if ($null -eq $censusRead.State) {
            $mutationResult.Reason = $censusRead.Reason
            $mutationResult.Detail = [string]$censusRead.Detail
            return [pscustomobject]$mutationResult
        }
        $mutationResult.Generation = $censusRead.Generation
        $mutationOutput = [pscustomobject]@{ Output = $null }
        $mutationChanged = [bool](& $Mutation $censusRead.State $mutationOutput $Argument)
        $mutationResult.Output = $mutationOutput.Output
        if (-not $mutationChanged) {
            $mutationResult.Reason = 'unchanged'
            return [pscustomobject]$mutationResult
        }
        $censusWriteArguments = @{
            Path               = (Join-Path $Root $script:CensusRecordName)
            Kind               = $script:CensusRecordKind
            Payload            = (ConvertTo-ServiceCensusPayload -State $censusRead.State)
            ExpectedGeneration = [long]$censusRead.Generation
            Confirm            = $false
            WhatIf             = $false
        }
        if ($Deadline) { $censusWriteArguments.Deadline = $Deadline }
        $censusWrite = Write-YurunaCriticalRecord @censusWriteArguments
        if (-not $censusWrite.Committed) {
            Write-Verbose "Invoke-ServiceCensusMutation: census write not committed ($($censusWrite.Reason))."
            $mutationResult.Reason = if ($censusWrite.Reason -eq 'deadline-exhausted') { 'deadline-exhausted' } else { 'write-failed' }
            return [pscustomobject]$mutationResult
        }
        $mutationResult.Wrote = $true
        $mutationResult.Generation = [long]$censusWrite.Generation
        $mutationResult.Reason = 'ok'
        return [pscustomobject]$mutationResult
    } finally {
        Exit-YurunaSingleFlightLock -Lock $censusLock
    }
}

function Get-YurunaServiceCensusCapability {
    <#
    .SYNOPSIS
        Which uses of census evidence this host type has qualified.
    .DESCRIPTION
        Pure declaration, no I/O. StoreQualified means the census lock's
        two-process exclusion has been demonstrated on that platform;
        PassiveCorroborationQualified means the passive resolver's MAC
        corroboration has been observed on a live host of that type. A
        census positive becomes permission to restore an unknown guest only
        when both hold. The census is written everywhere regardless, since
        the evidence has to accumulate before it can qualify anything.
    .PARAMETER HostType
        host.macos.utm, host.ubuntu.kvm or host.windows.hyper-v. Defaults to
        Get-HostType when that command is loaded, else ''.
    .OUTPUTS
        [pscustomobject] @{ HostType; StoreQualified; PassiveCorroborationQualified;
        EvidenceUsableForRepair; UnavailableReason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$HostType)
    if (-not $PSBoundParameters.ContainsKey('HostType')) {
        $HostType = ''
        $detector = Get-Command -Name 'Get-HostType' -ErrorAction SilentlyContinue
        if ($detector) { try { $HostType = [string](& $detector) } catch { $HostType = '' } }
    }
    $entry = $script:CensusCapability[[string]$HostType]
    if ($null -eq $entry) {
        $entry = @{ Store = $false; StoreReason = 'unknown-host-type'; Corroboration = $false; CorroborationReason = 'unknown-host-type' }
    }
    $usable = [bool]($entry.Store -and $entry.Corroboration)
    $withheld = if ($usable) { '' } elseif (-not $entry.Store) { [string]$entry.StoreReason } else { [string]$entry.CorroborationReason }
    return [pscustomobject]@{
        PSTypeName                    = 'Yuruna.ServiceCensusCapability'
        HostType                      = [string]$HostType
        StoreQualified                = [bool]$entry.Store
        PassiveCorroborationQualified = [bool]$entry.Corroboration
        EvidenceUsableForRepair       = $usable
        UnavailableReason             = $withheld
    }
}

function Read-YurunaServiceCensus {
    <#
    .SYNOPSIS
        Read the service census without taking a lock or creating anything.
    .DESCRIPTION
        Lock-free: the record is only ever replaced atomically, so a reader
        sees one whole generation or the previous one. An absent census (or
        an absent private root) is a valid empty census; one that cannot be
        read is Valid $false, and every mutator refuses on it rather than
        overwriting what it cannot read. 'unreadable' (an I/O failure or
        timeout) is worth retrying; 'corrupt' is not until someone repairs
        it. Detail names the underlying status or root reason.

        Each service entry is the stored record plus three computed fields:
        evidenceAgeSeconds (seconds since the last corroborated answer, $null
        when none), evidenceFresh (that answer is inside the evidence
        lifetime) and effectiveDesiredState. Expired evidence is unknown,
        never "stopped"; desired state never expires.
    .PARAMETER StateRoot
        Private root to read from; defaults to the resolved private state
        root, observed without creating it.
    .PARAMETER NowUnixMs
        Clock for the evidence ages; defaults to the current UTC time.
    .PARAMETER EvidenceLifetimeSeconds
        Overrides the lifetime stored in the census (origin 'parameter').
    .PARAMETER Deadline
        Bounds the record read; defaults to the record reader's own bound.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceCensus: Present, Valid, Reason (ok,
        absent, corrupt, unreadable, unsupported-version, root-unavailable),
        Detail, Path, SchemaVersion, Generation, IntentCounter,
        EvidenceLifetimeSeconds, EvidenceLifetimeOrigin, Durability,
        Services [hashtable].
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$StateRoot,
        [long]$NowUnixMs,
        [ValidateRange(1, 31536000)][int]$EvidenceLifetimeSeconds,
        [psobject]$Deadline
    )
    if (-not $PSBoundParameters.ContainsKey('NowUnixMs')) { $NowUnixMs = Get-ServiceCensusUtcNow }
    $census = [ordered]@{
        PSTypeName              = 'Yuruna.ServiceCensus'
        Present                 = $false
        Valid                   = $false
        Reason                  = 'root-unavailable'
        Detail                  = ''
        Path                    = $null
        SchemaVersion           = $script:CensusSchemaVersion
        Generation              = [long]0
        IntentCounter           = [long]0
        EvidenceLifetimeSeconds = $script:EvidenceLifetimeSeconds
        EvidenceLifetimeOrigin  = 'default'
        Durability              = [string](Get-YurunaCriticalRecordDurability).Claim
        Services                = @{}
    }
    $root = Resolve-ServiceCensusRoot -StateRoot $StateRoot -ReadOnly
    if (-not $root.Resolved) {
        $census.Detail = [string]$root.Reason
        if ($root.Reason -eq 'absent') {
            $census.Valid = $true
            $census.Reason = 'absent'
        }
        if ($PSBoundParameters.ContainsKey('EvidenceLifetimeSeconds')) {
            $census.EvidenceLifetimeSeconds = $EvidenceLifetimeSeconds
            $census.EvidenceLifetimeOrigin = 'parameter'
        }
        return [pscustomobject]$census
    }
    $read = Read-ServiceCensusState -Root $root.Path -Deadline $Deadline
    $census.Path = $read.Path
    $census.Reason = $read.Reason
    $census.Detail = [string]$read.Detail
    if ($null -eq $read.State) { return [pscustomobject]$census }
    $census.Valid = $true
    $census.Present = ($read.Reason -eq 'ok')
    $census.Generation = $read.Generation
    $census.IntentCounter = [long]$read.State.intentCounter
    $census.EvidenceLifetimeSeconds = [int]$read.State.evidenceLifetimeSeconds
    $census.EvidenceLifetimeOrigin = [string]$read.State.evidenceLifetimeOrigin
    if ($PSBoundParameters.ContainsKey('EvidenceLifetimeSeconds')) {
        $census.EvidenceLifetimeSeconds = $EvidenceLifetimeSeconds
        $census.EvidenceLifetimeOrigin = 'parameter'
    }
    $lifetimeMs = [long]$census.EvidenceLifetimeSeconds * 1000
    $services = @{}
    foreach ($name in @($read.State.services.Keys)) {
        $svc = $read.State.services[$name]
        $answered = [long]$svc.lastAnsweredUnixMs
        if ($answered -gt 0) {
            # A clock behind the recorded answer counts as age zero rather
            # than a negative age; the evidence is not treated as newer.
            $ageMs = [Math]::Max([long]0, $NowUnixMs - $answered)
            $svc.evidenceAgeSeconds = [long][Math]::Floor($ageMs / 1000)
            $svc.evidenceFresh = ($ageMs -le $lifetimeMs)
        } else {
            $svc.evidenceAgeSeconds = $null
            $svc.evidenceFresh = $false
        }
        $svc.effectiveDesiredState = [string]$svc.desiredState
        $services[$name] = $svc
    }
    $census.Services = $services
    return [pscustomobject]$census
}

function Get-YurunaServiceIntent {
    <#
    .SYNOPSIS
        The newest explicit start/stop intent for one service and the desired
        state it leaves in force. Read-only.
    .DESCRIPTION
        The refresh worker reads this before each resume so a stop an
        operator issued after the recovery capture is honored.
    .PARAMETER Key
        Service key (caching-proxy, stash, pool-control, download-agent).
    .PARAMETER Census
        A Read-YurunaServiceCensus result to read from instead of the disk.
    .PARAMETER StateRoot
        Private root to read from when no Census is passed.
    .OUTPUTS
        [pscustomobject] @{ Key; Generation (0 = none); Operation; Result;
        DesiredState; VMName; HostingMode; PublishedUnixMs; CompletedUnixMs;
        Script; Pid; CensusReason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [AllowNull()][psobject]$Census,
        [AllowEmptyString()][string]$StateRoot
    )
    if ($null -eq $Census) { $Census = Read-YurunaServiceCensus -StateRoot $StateRoot }
    $record = [ordered]@{
        PSTypeName = 'Yuruna.ServiceIntent'
        Key = $Key; Generation = [long]0; Operation = ''; Result = ''; DesiredState = ''
        VMName = ''; HostingMode = ''; PublishedUnixMs = [long]0; CompletedUnixMs = [long]0
        Script = ''; Pid = 0; CensusReason = [string]$Census.Reason
    }
    $services = $Census.Services
    if ($services -and $services.ContainsKey($Key)) {
        $svc = $services[$Key]
        $intent = $svc.intent
        $record.DesiredState = [string]$svc.desiredState
        if ($intent) {
            $record.Generation      = [long]$intent.generation
            $record.Operation       = [string]$intent.operation
            $record.Result          = [string]$intent.result
            $record.VMName          = [string]$intent.vmName
            $record.HostingMode     = [string]$intent.hostingMode
            $record.PublishedUnixMs = [long]$intent.publishedUnixMs
            $record.CompletedUnixMs = [long]$intent.completedUnixMs
            $record.Script          = [string]$intent.script
            $record.Pid             = [int]$intent.pid
        }
    }
    return [pscustomobject]$record
}

function Merge-ServiceCensusObservation {
    <#
    .SYNOPSIS
        Fold one observation into a service record; $true when anything
        worth a write changed.
    .DESCRIPTION
        Monotonic: the last answer and the last probe only move forward, a
        failed or timed-out probe never clears an earlier positive, and an
        address is replaced only by a newer resolution. A change of VM name
        discards the evidence about the previous guest. Intent fields are
        never touched.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Observation,
        [long]$DefaultObservedUnixMs
    )
    $significant = $false
    # Bound to a local so the read below is visibly a use of the parameter.
    $observed = $Observation
    $get = {
        param([string]$Name)
        if ($observed -is [System.Collections.IDictionary]) { $observed[$Name] } else { $observed.$Name }
    }
    $vmName = [string](& $get 'VMName')
    if ($vmName -and $vmName -cne [string]$Record.vmName) {
        if ($Record.vmName) {
            # Evidence about another guest is not evidence about this one.
            $Record.address = ''; $Record.addressOrigin = 'none'; $Record.addressResolvedUnixMs = [long]0
            $Record.bundleMac = ''; $Record.networkMode = ''; $Record.macCorroborated = $false
            $Record.lastAnsweredUnixMs = [long]0; $Record.lastAnsweredAddress = ''; $Record.lastAnsweredIdentity = ''
            $Record.lastUncorroboratedAnswerUnixMs = [long]0
        }
        $Record.vmName = $vmName
        $significant = $true
    }
    foreach ($pair in @(@('VMNameSource', 'vmNameSource'), @('Source', 'source'), @('HostingMode', 'hostingMode'))) {
        $value = [string](& $get $pair[0])
        if ($value -and $value -cne [string]$Record[$pair[1]]) { $Record[$pair[1]] = $value; $significant = $true }
    }
    $port = [int](ConvertTo-ServiceCensusLong -Value (& $get 'HealthPort'))
    if ($port -gt 0 -and $port -ne [int]$Record.healthPort) { $Record.healthPort = $port; $significant = $true }

    $resolvedAt = ConvertTo-ServiceCensusLong -Value (& $get 'AddressResolvedUnixMs')
    $address = [string](& $get 'Address')
    if ($address -and $resolvedAt -gt [long]$Record.addressResolvedUnixMs) {
        if ($address -cne [string]$Record.address) { $significant = $true }
        $Record.address = $address
        $Record.addressOrigin = if (& $get 'AddressOrigin') { [string](& $get 'AddressOrigin') } else { 'none' }
        $Record.addressResolvedUnixMs = $resolvedAt
        $mac = [string](& $get 'BundleMac')
        if ($mac) { $Record.bundleMac = $mac }
        $mode = [string](& $get 'NetworkMode')
        if ($mode) { $Record.networkMode = $mode }
        $Record.macCorroborated = [bool](& $get 'MacCorroborated')
    }

    $observedAt = ConvertTo-ServiceCensusLong -Value (& $get 'ObservedUnixMs')
    if ($observedAt -le 0) { $observedAt = $DefaultObservedUnixMs }
    if ($observedAt -gt [long]$Record.lastProbeUnixMs) {
        $outcome = [string](& $get 'ProbeOutcome')
        if ($outcome -and $outcome -cne [string]$Record.lastProbeOutcome) { $significant = $true }
        if ($observedAt - [long]$Record.lastProbeUnixMs -ge $script:WriteSuppressProbeMs) { $significant = $true }
        $Record.lastProbeUnixMs = $observedAt
        if ($outcome) { $Record.lastProbeOutcome = $outcome }
    }
    if ([bool](& $get 'Answered') -and $observedAt -gt 0) {
        $identity = [string](& $get 'AnsweredIdentity')
        if ($identity -in @('mac-corroborated', 'host-process')) {
            if ($observedAt -gt [long]$Record.lastAnsweredUnixMs) {
                if ($observedAt - [long]$Record.lastAnsweredUnixMs -ge $script:WriteSuppressAnswerMs) { $significant = $true }
                $answeredAddress = [string](& $get 'AnsweredAddress')
                if ($answeredAddress -cne [string]$Record.lastAnsweredAddress -or $identity -cne [string]$Record.lastAnsweredIdentity) { $significant = $true }
                $Record.lastAnsweredUnixMs = $observedAt
                $Record.lastAnsweredAddress = $answeredAddress
                $Record.lastAnsweredIdentity = $identity
            }
        } elseif ($observedAt -gt [long]$Record.lastUncorroboratedAnswerUnixMs) {
            if ($observedAt - [long]$Record.lastUncorroboratedAnswerUnixMs -ge $script:WriteSuppressProbeMs) { $significant = $true }
            $Record.lastUncorroboratedAnswerUnixMs = $observedAt
        }
    }
    return $significant
}

function Update-YurunaServiceCensusObservation {
    <#
    .SYNOPSIS
        Merge observation rows into the census under its merge lock.
    .DESCRIPTION
        Read-modify-write under service-census.lock, waiting at most
        LockWaitMilliseconds; a busy lock skips the merge (the beacon retries
        on its next tick). The merge is monotonic and never touches intents
        (see the census record rules), so an observation computed from a
        read taken before a stop was published cannot erase that stop. A
        write is skipped when nothing changed except the probe clock moving
        less than five minutes and the answer clock less than one, which
        keeps a quiet host to about one write a minute. An unreadable census
        is never overwritten.
    .PARAMETER Observation
        Rows: Key; VMName; VMNameSource; Source; HostingMode; HealthPort;
        Address; AddressOrigin; AddressResolvedUnixMs; BundleMac; NetworkMode;
        MacCorroborated; Answered; AnsweredIdentity (mac-corroborated,
        host-process or ''); AnsweredAddress; ProbeOutcome; ObservedUnixMs.
    .PARAMETER StateRoot
        Private root; defaults to the resolved private state root.
    .PARAMETER LockWaitMilliseconds
        Longest wait for the merge lock.
    .PARAMETER NowUnixMs
        Clock used when a row carries no ObservedUnixMs.
    .PARAMETER Deadline
        Bounds the lock wait, the read and the write together.
    .OUTPUTS
        [pscustomobject] @{ Merged; Wrote; Reason ok|lock-busy|corrupt|
        unreadable|root-unavailable|write-failed|unchanged|preview; Generation }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Observation,
        [AllowEmptyString()][string]$StateRoot,
        [ValidateRange(0, 5000)][int]$LockWaitMilliseconds = 1000,
        [long]$NowUnixMs,
        [psobject]$Deadline
    )
    if (-not $PSBoundParameters.ContainsKey('NowUnixMs')) { $NowUnixMs = Get-ServiceCensusUtcNow }
    $result = [ordered]@{ Merged = $false; Wrote = $false; Reason = 'unchanged'; Generation = [long]0 }
    $rows = @($Observation | Where-Object { $null -ne $_ -and ([string]$_.Key) -cmatch $script:ServiceKeyPattern })
    if (-not $PSCmdlet.ShouldProcess($script:CensusRecordName, (Format-YurunaOperatorMessage -Key 'runner.service_census_update_should_process'))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $root = Resolve-ServiceCensusRoot -StateRoot $StateRoot
    if (-not $root.Resolved) {
        $result.Reason = 'root-unavailable'
        return [pscustomobject]$result
    }
    if ($rows.Count -eq 0) { return [pscustomobject]$result }
    $mutation = {
        param($State, $Output, $Argument)
        $changed = $false
        foreach ($row in $Argument.Rows) {
            $key = [string]$row.Key
            if (-not $State.services.Contains($key)) {
                $State.services[$key] = New-ServiceCensusServiceRecord -Key $key
                $changed = $true
            }
            if (Merge-ServiceCensusObservation -Record $State.services[$key] -Observation $row -DefaultObservedUnixMs $Argument.NowUnixMs) { $changed = $true }
        }
        $Output.Output = $changed
        return $changed
    }
    $mutationArguments = @{
        Root = $root.Path; Mutation = $mutation; LockWaitMilliseconds = $LockWaitMilliseconds
        Argument = @{ Rows = $rows; NowUnixMs = $NowUnixMs }
    }
    if ($Deadline) { $mutationArguments.Deadline = $Deadline }
    $mutated = Invoke-ServiceCensusMutation @mutationArguments
    $result.Generation = [long]$mutated.Generation
    switch ($mutated.Reason) {
        'ok'        { $result.Merged = $true; $result.Wrote = $true; $result.Reason = 'ok' }
        'unchanged' { $result.Merged = $true; $result.Reason = 'unchanged' }
        'lock-busy' { $result.Reason = 'lock-busy' }
        'corrupt'   { $result.Reason = 'corrupt' }
        'unsupported-version' { $result.Reason = 'corrupt' }
        'unreadable' { $result.Reason = 'unreadable' }
        default     { $result.Reason = 'write-failed' }
    }
    return [pscustomobject]$result
}

function Get-ServiceOperationLockPath {
    <#
    .SYNOPSIS
        The lock file of one service key under Root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Key
    )
    return (Join-Path $Root "service-operation.$Key.lock")
}

function Enter-YurunaServiceOperationLockSet {
    <#
    .SYNOPSIS
        Take the operation locks of several services, all or nothing, in
        ordinal key order.
    .DESCRIPTION
        One held-open lock per logical service key (rank ServiceKey). Taking
        them in one deterministic order is what keeps two callers that need
        overlapping sets from each holding a lock the other waits for; on any
        failure every lock already taken is released before returning. Age
        never evicts a holder, and a lock this process already holds is
        refused rather than silently shared: a nested helper inside one
        operation receives this context and checks it with
        Test-YurunaServiceOperationLockContext instead of acquiring again.
    .PARAMETER Key
        Service keys, lowercase letters, digits and hyphens.
    .PARAMETER Deadline
        Shared deadline; the wait never outlives it.
    .PARAMETER WaitMilliseconds
        Longest wait for each busy lock; 0 tries once.
    .PARAMETER Purpose
        Short label recorded in each lock's advisory metadata.
    .PARAMETER StateRoot
        Private root; defaults to the resolved private state root.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceOperationLockSet: Held; Keys (sorted);
        Locks [hashtable]; Token; Reason acquired|busy|root-unavailable|
        deadline|invalid-key|access-denied|error|preview; BusyKey; StateRoot;
        LockReason (the lock primitive's own reason for the key that failed,
        such as disk-full or lock-order-violation); RootReason (why the
        private root could not be resolved, such as absent or
        owner-mismatch).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Key,
        $Deadline,
        [ValidateRange(0, 600000)][int]$WaitMilliseconds = 0,
        [AllowEmptyString()][string]$Purpose = '',
        [AllowEmptyString()][string]$StateRoot
    )
    $sorted = [System.Collections.Generic.List[string]]::new()
    $invalid = $false
    foreach ($candidate in @($Key)) {
        $name = [string]$candidate
        if ($name -cnotmatch $script:ServiceKeyPattern) { $invalid = $true; continue }
        if (-not $sorted.Contains($name)) { $sorted.Add($name) }
    }
    $sorted.Sort([System.StringComparer]::Ordinal)
    $context = [ordered]@{
        PSTypeName = 'Yuruna.ServiceOperationLockSet'
        Held       = $false
        Keys       = [string[]]$sorted.ToArray()
        Locks      = @{}
        Token      = [Guid]::NewGuid().ToString('N')
        Reason     = 'error'
        BusyKey    = ''
        StateRoot  = ''
        LockReason = ''
        RootReason = ''
        Released   = $false
    }
    if ($invalid -or $sorted.Count -eq 0) {
        $context.Reason = 'invalid-key'
        return [pscustomobject]$context
    }
    if (-not $PSCmdlet.ShouldProcess(($sorted -join ', '), (Format-YurunaOperatorMessage -Key 'runner.service_lockset_should_process' -Arguments @{ keys = ($sorted -join ', ') }))) {
        $context.Reason = 'preview'
        return [pscustomobject]$context
    }
    $root = Resolve-ServiceCensusRoot -StateRoot $StateRoot
    if (-not $root.Resolved) {
        $context.Reason = 'root-unavailable'
        $context.RootReason = [string]$root.Reason
        return [pscustomobject]$context
    }
    $context.StateRoot = $root.Path
    $taken = [System.Collections.Generic.List[object]]::new()
    $failure = $null
    foreach ($name in $sorted) {
        $wait = [long]$WaitMilliseconds
        if ($Deadline) {
            $left = Get-YurunaDeadlineRemainingMs -Deadline $Deadline
            if ($left -le 0) { $failure = @{ Reason = 'deadline'; Key = $name }; break }
            $wait = [Math]::Min($wait, $left)
        }
        $lockArguments = @{
            Path             = (Get-ServiceOperationLockPath -Root $root.Path -Key $name)
            Rank             = (Get-YurunaLockRank -Name ServiceKey)
            WaitMilliseconds = [int]$wait
            Metadata         = @{ token = $context.Token; purpose = $Purpose; key = $name }
        }
        if ($Deadline) { $lockArguments.Deadline = $Deadline }
        $lock = Enter-YurunaSingleFlightLock @lockArguments
        if ($lock.Held) {
            $taken.Add([pscustomobject]@{ Key = $name; Lock = $lock })
            continue
        }
        $mapped = switch ($lock.Reason) {
            'held-elsewhere'       { 'busy' }
            'held-by-this-process' { 'busy' }
            'access-denied'        { 'access-denied' }
            default                { 'error' }
        }
        if ($mapped -eq 'busy' -and $Deadline -and (Test-YurunaDeadlineExpired -Deadline $Deadline)) { $mapped = 'deadline' }
        Write-Verbose "Enter-YurunaServiceOperationLockSet: '$name' not taken ($($lock.Reason))."
        $failure = @{ Reason = $mapped; Key = $name; LockReason = [string]$lock.Reason }
        break
    }
    if ($failure) {
        for ($i = $taken.Count - 1; $i -ge 0; $i--) { Exit-YurunaSingleFlightLock -Lock $taken[$i].Lock }
        $context.Reason = $failure.Reason
        $context.BusyKey = $failure.Key
        $context.LockReason = if ($failure.LockReason) { [string]$failure.LockReason } else { [string]$failure.Reason }
        return [pscustomobject]$context
    }
    foreach ($entry in $taken) { $context.Locks[$entry.Key] = $entry.Lock }
    $context.Held = $true
    $context.Reason = 'acquired'
    return [pscustomobject]$context
}

function Exit-YurunaServiceOperationLockSet {
    <#
    .SYNOPSIS
        Release a lock set in reverse order. Idempotent and $null-safe.
    .PARAMETER Context
        The object Enter-YurunaServiceOperationLockSet returned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Context)
    if ($null -eq $Context -or $null -eq $Context.PSObject.Properties['Locks']) { return }
    $keys = @($Context.Keys)
    for ($i = $keys.Count - 1; $i -ge 0; $i--) {
        $lock = $Context.Locks[[string]$keys[$i]]
        if ($lock) { Exit-YurunaSingleFlightLock -Lock $lock }
    }
    if ($Context.PSObject.Properties['Held']) { $Context.Held = $false }
    if ($Context.PSObject.Properties['Released']) { $Context.Released = $true }
}

function Test-YurunaServiceOperationLockContext {
    <#
    .SYNOPSIS
        $true when a lock-set context still holds the lock of one key.
    .DESCRIPTION
        Nested helpers inside one authorized operation receive the context
        rather than acquiring again, and validate it here before acting on
        the authority it represents: the set must be held, name the key, and
        its lock must still be a live handle this runspace owns on the same
        file.
    .PARAMETER Context
        A Yuruna.ServiceOperationLockSet.
    .PARAMETER Key
        The service key about to be acted on.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,
        [Parameter(Mandatory)][string]$Key
    )
    if ($null -eq $Context -or $null -eq $Context.PSObject.Properties['Locks']) { return $false }
    if (-not [bool]$Context.Held) { return $false }
    if (@($Context.Keys) -notcontains $Key) { return $false }
    $lock = $Context.Locks[$Key]
    if ($null -eq $lock) { return $false }
    $expected = Get-ServiceOperationLockPath -Root ([string]$Context.StateRoot) -Key $Key
    return [bool](Test-YurunaSingleFlightLockOwned -Lock $lock -Path $expected)
}

function Test-ServiceIntentOwnerAlive {
    <#
    .SYNOPSIS
        $true while the process that published an intent is still running.
    .DESCRIPTION
        A pid outlives its process and is handed to another one, so a
        recorded start time must match within two seconds. A start time
        that cannot be read counts as alive: nothing shows the owner gone.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [long]$ProcessId,
        [long]$ProcessStartUnixMs
    )
    if ($ProcessId -le 0 -or $ProcessId -gt [int]::MaxValue) { return $false }
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::GetProcessById([int]$ProcessId)
    } catch {
        return $false
    }
    try {
        if ($process.HasExited) { return $false }
        if ($ProcessStartUnixMs -le 0) { return $true }
        $started = [DateTimeOffset]::new($process.StartTime).ToUnixTimeMilliseconds()
        return ([Math]::Abs($started - $ProcessStartUnixMs) -le 2000)
    } catch {
        return $true
    } finally {
        $process.Dispose()
    }
}

function Format-ServiceOperationBusyDetail {
    <#
    .SYNOPSIS
        The newest pending operation recorded for a key other than Exclude,
        as token text for an operator message, or 'unrecorded'.
    .DESCRIPTION
        A held lock's own metadata cannot be read while it is held, so the
        census intent is the only record of who is working on the service.
        A pending intent whose process is gone is skipped: its script ended
        without recording a result, so it holds nothing now, and naming it
        would send the operator after a request that no longer runs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Record,
        [long]$Exclude = 0
    )
    if ($null -eq $Record) { return 'unrecorded' }
    foreach ($candidate in @(@($Record.intent) + @($Record.history))) {
        if ($null -eq $candidate) { continue }
        if ([long]$candidate.generation -eq $Exclude) { continue }
        if ([string]$candidate.result -ne 'pending') { continue }
        if (-not (Test-ServiceIntentOwnerAlive -ProcessId ([long]$candidate.pid) -ProcessStartUnixMs ([long]$candidate.processStartUnixMs))) { continue }
        return ('operation={0} script={1} pid={2}' -f $candidate.operation, $candidate.script, $candidate.pid)
    }
    return 'unrecorded'
}

function Publish-ServiceIntent {
    <#
    .SYNOPSIS
        Record a new pending intent for a key inside a census mutation.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][ValidateSet('stop', 'start')][string]$Operation,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$HostingMode,
        [AllowEmptyString()][string]$Script,
        [long]$NowUnixMs,
        [long]$ProcessStartUnixMs
    )
    if (-not $State.services.Contains($Key)) { $State.services[$Key] = New-ServiceCensusServiceRecord -Key $Key }
    $svc = $State.services[$Key]
    $previous = $svc.intent
    $baseline = Get-ServiceEffectiveDesiredState -Intent $previous
    $State.intentCounter = [long]$State.intentCounter + 1
    $generation = [long]$State.intentCounter
    if ($previous) {
        $svc.history = [object[]]@(@($previous) + @($svc.history) | Select-Object -First $script:HistoryCap)
    }
    $svc.intent = [ordered]@{
        generation           = $generation
        operation            = $Operation
        result               = 'pending'
        desiredState         = if ($Operation -eq 'stop') { 'stopped' } else { 'running' }
        baselineDesiredState = $baseline
        vmName               = $VMName
        hostingMode          = $HostingMode
        publishedUnixMs      = $NowUnixMs
        completedUnixMs      = [long]0
        script               = $Script
        pid                  = $PID
        processStartUnixMs   = $ProcessStartUnixMs
        finalState           = ''
    }
    if ($svc.vmName -and $svc.vmName -cne $VMName) {
        # The intent names another guest than the evidence was gathered for.
        $svc.address = ''; $svc.addressOrigin = 'none'; $svc.addressResolvedUnixMs = [long]0
        $svc.bundleMac = ''; $svc.networkMode = ''; $svc.macCorroborated = $false
        $svc.lastAnsweredUnixMs = [long]0; $svc.lastAnsweredAddress = ''; $svc.lastAnsweredIdentity = ''
        $svc.lastUncorroboratedAnswerUnixMs = [long]0
    }
    if ($svc.vmName -cne $VMName) {
        $svc.vmName = $VMName
        $svc.vmNameSource = 'intent'
    }
    $svc.hostingMode = $HostingMode
    $svc.desiredState = Get-ServiceEffectiveDesiredState -Intent $svc.intent
    $svc.intentGeneration = $generation
    return $generation
}

function Complete-ServiceIntent {
    <#
    .SYNOPSIS
        Record a result against the intent of one generation inside a census
        mutation: {Found; Result; NewerOperation}.
    .DESCRIPTION
        The result lands on that exact generation. When a newer intent was
        published meanwhile, the older one is closed as superseded and the
        newer one stands untouched.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][ValidateSet('confirmed', 'failed')][string]$Result,
        [AllowEmptyString()][string]$FinalState,
        [long]$NowUnixMs
    )
    if (-not $State.services.Contains($Key)) { return [pscustomobject]@{ Found = $false; Result = 'not-recorded'; NewerOperation = '' } }
    $svc = $State.services[$Key]
    if ($svc.intent -and [long]$svc.intent.generation -eq $Generation) {
        $svc.intent.result = $Result
        $svc.intent.completedUnixMs = $NowUnixMs
        $svc.intent.finalState = [string]$FinalState
        $svc.desiredState = Get-ServiceEffectiveDesiredState -Intent $svc.intent
        return [pscustomobject]@{ Found = $true; Result = $Result; NewerOperation = '' }
    }
    foreach ($entry in @($svc.history)) {
        if ($null -eq $entry -or [long]$entry.generation -ne $Generation) { continue }
        $entry.result = 'superseded'
        $entry.completedUnixMs = $NowUnixMs
        $entry.finalState = [string]$FinalState
        $newer = if ($svc.intent) { [string]$svc.intent.operation } else { '' }
        return [pscustomobject]@{ Found = $true; Result = 'superseded'; NewerOperation = $newer }
    }
    return [pscustomobject]@{ Found = $false; Result = 'not-recorded'; NewerOperation = '' }
}

function New-ServiceOperationContext {
    <#
    .SYNOPSIS
        A Yuruna.ServiceOperation record with every field present.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Key, [string]$VMName, [string]$Operation, [string]$HostingMode, [string]$Script
    )
    return [pscustomobject][ordered]@{
        PSTypeName     = 'Yuruna.ServiceOperation'
        Proceed        = $false
        Reason         = 'root-unavailable'
        Key            = $Key
        VMName         = $VMName
        Operation      = $Operation
        HostingMode    = $HostingMode
        Script         = $Script
        Generation     = [long]0
        LockSet        = $null
        NewerOperation = ''
        BusyDetail     = ''
        Detail         = ''
        CensusPath     = ''
        StateRoot      = ''
        Message        = ''
        Completed      = $false
    }
}

function ConvertTo-ServiceOperationCensusRefusal {
    <#
    .SYNOPSIS
        The operation refusal a census reason stands for: census-unreadable
        for a read that failed or timed out (worth retrying), census-corrupt
        for damage, Fallback for anything else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$CensusReason,
        [Parameter(Mandatory)][string]$Fallback
    )
    switch ($CensusReason) {
        'unreadable'          { return 'census-unreadable' }
        'corrupt'             { return 'census-corrupt' }
        'unsupported-version' { return 'census-corrupt' }
    }
    return $Fallback
}

function ConvertTo-ServiceOperationLockRefusal {
    <#
    .SYNOPSIS
        The operation refusal a lock-set failure stands for: operation-busy
        only when another holder has the lock, root-unavailable without a
        private root, and lock-unavailable for everything else (the lock
        file could not be opened, the disk is full or read-only, a lock was
        taken out of order), which no amount of waiting fixes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$LockSet)
    switch ([string]$LockSet.Reason) {
        'busy'             { return 'operation-busy' }
        'root-unavailable' { return 'root-unavailable' }
    }
    return 'lock-unavailable'
}

function Set-ServiceOperationRefusalMessage {
    <#
    .SYNOPSIS
        Fill the operator message of a refused operation context.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets a property on an in-memory record only.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $scriptName = if ($Context.Script) { [string]$Context.Script } else { 'service operation' }
    $operationName = ([string]$Context.Operation).ToLowerInvariant()
    $Context.Message = switch ($Context.Reason) {
        'operation-busy' {
            Format-YurunaOperatorMessage -Key 'runner.service_operation_busy' -Arguments @{
                script = $scriptName; key = [string]$Context.Key; detail = [string]$Context.BusyDetail }
        }
        'lock-unavailable' {
            $where = if ($Context.StateRoot) { [string]$Context.StateRoot } else { '$HOME/.yuruna/host-refresh' }
            Format-YurunaOperatorMessage -Key 'runner.service_operation_lock_unavailable' -Arguments @{
                script = $scriptName; key = [string]$Context.Key; reason = [string]$Context.Detail; path = $where }
        }
        'census-unreadable' {
            $where = if ($Context.CensusPath) { [string]$Context.CensusPath } elseif ($Context.StateRoot) { [string]$Context.StateRoot } else { '$HOME/.yuruna/host-refresh' }
            Format-YurunaOperatorMessage -Key 'runner.service_census_unreadable' -Arguments @{
                script = $scriptName; path = $where; reason = [string]$Context.Detail }
        }
        { $_ -in @('census-corrupt', 'root-unavailable') } {
            $where = if ($Context.CensusPath) { [string]$Context.CensusPath } elseif ($Context.StateRoot) { [string]$Context.StateRoot } else { '$HOME/.yuruna/host-refresh' }
            Format-YurunaOperatorMessage -Key 'runner.service_census_unusable' -Arguments @{
                script = $scriptName; path = $where; reason = [string]$Context.Reason }
        }
        default {
            Format-YurunaOperatorMessage -Key 'runner.service_operation_refused' -Arguments @{
                script = $scriptName; operation = $operationName; key = [string]$Context.Key; reason = [string]$Context.Reason }
        }
    }
}

function Enter-YurunaServiceOperation {
    <#
    .SYNOPSIS
        Publish a start or stop intent for one service and take its operation
        lock, before a Start/Stop script mutates anything.
    .DESCRIPTION
        Stop: the stop intent is published first, under the short census
        lock, so the request is on record (and suppresses automatic resume)
        even while another operation still holds the service; then the
        service lock is awaited for up to WaitSeconds. A stop that cannot
        take the lock is recorded as failed (an explicit wish to stay down
        all the same) and refused as operation-busy. A newer intent published
        while waiting supersedes this one before anything is changed.

        Start: the service lock is taken first, so a busy service writes no
        intent at all; then the start intent is published with the desired
        state it replaces as its baseline, which is what a failed start
        falls back to.

        Nothing is mutated when Proceed is $false: a census that cannot be
        read or written, or a private root that cannot be resolved, refuses
        the operation (fail closed), and Message carries the operator text.
        Only a lock held by another operation is operation-busy; a lock file
        that cannot be opened or written is lock-unavailable, and a census
        read that failed or timed out is census-unreadable, both naming the
        underlying reason in Detail. Every script calls
        Exit-YurunaServiceOperation in a finally block.
    .PARAMETER Key
        Service key (caching-proxy, stash, pool-control, download-agent).
    .PARAMETER VMName
        The VM the operation targets, custom names included.
    .PARAMETER Operation
        Stop or Start.
    .PARAMETER HostingMode
        vm, or host-process for a service running as a host process.
    .PARAMETER Script
        The calling script's file name, recorded and used in messages.
    .PARAMETER WaitSeconds
        Longest wait for the service lock.
    .PARAMETER StateRoot
        Private root; defaults to the resolved private state root.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceOperation: Proceed; Reason ok|
        operation-busy|lock-unavailable|intent-not-persisted|superseded|
        root-unavailable|census-corrupt|census-unreadable|preview; Key;
        VMName; Operation; Generation; LockSet; NewerOperation; BusyDetail;
        Detail; CensusPath; StateRoot; Message.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')][string]$Key,
        [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9._-]+$')][string]$VMName,
        [Parameter(Mandatory)][ValidateSet('Stop', 'Start')][string]$Operation,
        [ValidateSet('vm', 'host-process')][string]$HostingMode = 'vm',
        [AllowEmptyString()][string]$Script = '',
        [ValidateRange(0, 600)][int]$WaitSeconds = $script:OperationWaitSeconds,
        [AllowEmptyString()][string]$StateRoot
    )
    $operationName = $Operation.ToLowerInvariant()
    $context = New-ServiceOperationContext -Key $Key -VMName $VMName -Operation $Operation -HostingMode $HostingMode -Script $Script
    if (-not $PSCmdlet.ShouldProcess($Key, (Format-YurunaOperatorMessage -Key 'runner.service_operation_should_process' -Arguments @{ operation = $operationName; key = $Key }))) {
        $context.Reason = 'preview'
        return $context
    }
    $root = Resolve-ServiceCensusRoot -StateRoot $StateRoot
    if (-not $root.Resolved) {
        $context.Reason = 'root-unavailable'
        $context.Detail = [string]$root.Reason
        Set-ServiceOperationRefusalMessage -Context $context
        return $context
    }
    $context.StateRoot = $root.Path
    $context.CensusPath = Join-Path $root.Path $script:CensusRecordName
    $processStart = Get-ServiceCensusProcessStart
    $waitMs = [int]($WaitSeconds * 1000)

    $publishArgument = @{
        Key = $Key; Operation = $operationName; VMName = $VMName; HostingMode = $HostingMode
        Script = $Script; ProcessStartUnixMs = $processStart
    }
    $publishMutation = {
        param($State, $Output, $Argument)
        $Output.Output = Publish-ServiceIntent -State $State -Key $Argument.Key -Operation $Argument.Operation `
            -VMName $Argument.VMName -HostingMode $Argument.HostingMode -Script $Argument.Script `
            -NowUnixMs (Get-ServiceCensusUtcNow) -ProcessStartUnixMs $Argument.ProcessStartUnixMs
        return $true
    }
    $failMutation = {
        param($State, $Output, $Argument)
        $Output.Output = Format-ServiceOperationBusyDetail -Record $State.services[$Argument.Key] -Exclude $Argument.Generation
        $closed = Complete-ServiceIntent -State $State -Key $Argument.Key -Generation $Argument.Generation `
            -Result 'failed' -FinalState '' -NowUnixMs (Get-ServiceCensusUtcNow)
        return [bool]$closed.Found
    }
    $refuseOnCensus = {
        param($Mutated)
        $context.Reason = ConvertTo-ServiceOperationCensusRefusal -CensusReason ([string]$Mutated.Reason) -Fallback 'intent-not-persisted'
        $context.Detail = if ($Mutated.Detail) { [string]$Mutated.Detail } else { [string]$Mutated.Reason }
        Set-ServiceOperationRefusalMessage -Context $context
    }
    $refuseOnLock = {
        param($LockSet)
        $context.Reason = ConvertTo-ServiceOperationLockRefusal -LockSet $LockSet
        $context.Detail = switch ($context.Reason) {
            'root-unavailable' { [string]$LockSet.RootReason }
            'lock-unavailable' { if ($LockSet.LockReason) { [string]$LockSet.LockReason } else { [string]$LockSet.Reason } }
            default            { '' }
        }
        Set-ServiceOperationRefusalMessage -Context $context
    }
    $lockSetArguments = @{
        Key = @($Key); WaitMilliseconds = $waitMs; Purpose = "$operationName $Script"; StateRoot = $root.Path
        Confirm = $false; WhatIf = $false
    }

    if ($Operation -eq 'Stop') {
        $published = Invoke-ServiceCensusMutation -Root $root.Path -Mutation $publishMutation -Argument $publishArgument -LockWaitMilliseconds $script:MutatorLockWaitMs
        if ($published.Reason -ne 'ok') {
            & $refuseOnCensus $published
            return $context
        }
        $context.Generation = [long]$published.Output
        $lockSet = Enter-YurunaServiceOperationLockSet @lockSetArguments
        if (-not $lockSet.Held) {
            $recorded = Invoke-ServiceCensusMutation -Root $root.Path -Mutation $failMutation -LockWaitMilliseconds $script:MutatorLockWaitMs `
                -Argument @{ Key = $Key; Generation = $context.Generation }
            $context.BusyDetail = if ($recorded.Output) { [string]$recorded.Output } else { 'unrecorded' }
            & $refuseOnLock $lockSet
            return $context
        }
        $context.LockSet = $lockSet
        $current = Read-YurunaServiceCensus -StateRoot $root.Path
        $newestIntent = if ($current.Services.ContainsKey($Key)) { $current.Services[$Key].intent } else { $null }
        $newest = if ($newestIntent) { [long]$newestIntent.generation } else { [long]0 }
        if (-not $current.Valid -or $newest -ne $context.Generation) {
            $null = Invoke-ServiceCensusMutation -Root $root.Path -Mutation $failMutation -LockWaitMilliseconds $script:MutatorLockWaitMs `
                -Argument @{ Key = $Key; Generation = $context.Generation }
            $context.NewerOperation = if ($newestIntent) { [string]$newestIntent.operation } else { '' }
            Exit-YurunaServiceOperationLockSet -Context $lockSet
            $context.LockSet = $null
            if ($current.Valid) {
                $context.Reason = 'superseded'
            } else {
                $context.Reason = ConvertTo-ServiceOperationCensusRefusal -CensusReason ([string]$current.Reason) -Fallback 'census-corrupt'
                $context.Detail = if ($current.Detail) { [string]$current.Detail } else { [string]$current.Reason }
            }
            Set-ServiceOperationRefusalMessage -Context $context
            return $context
        }
        $context.Proceed = $true
        $context.Reason = 'ok'
        return $context
    }

    $lockSet = Enter-YurunaServiceOperationLockSet @lockSetArguments
    if (-not $lockSet.Held) {
        $census = Read-YurunaServiceCensus -StateRoot $root.Path
        $record = if ($census.Services.ContainsKey($Key)) { $census.Services[$Key] } else { $null }
        $context.BusyDetail = Format-ServiceOperationBusyDetail -Record $record
        & $refuseOnLock $lockSet
        return $context
    }
    $published = Invoke-ServiceCensusMutation -Root $root.Path -Mutation $publishMutation -Argument $publishArgument -LockWaitMilliseconds $script:MutatorLockWaitMs
    if ($published.Reason -ne 'ok') {
        Exit-YurunaServiceOperationLockSet -Context $lockSet
        & $refuseOnCensus $published
        return $context
    }
    $context.Generation = [long]$published.Output
    $context.LockSet = $lockSet
    $context.Proceed = $true
    $context.Reason = 'ok'
    return $context
}

function Test-YurunaServiceOperationCurrent {
    <#
    .SYNOPSIS
        $true while an operation still owns its service: its lock is held and
        its intent is still the newest one recorded for the key.
    .DESCRIPTION
        A Start script checks this immediately before its first VM mutation,
        so a stop published while the start was preparing wins instead of
        being overwritten by a start that no longer reflects what the
        operator wants.
    .PARAMETER Context
        A Yuruna.ServiceOperation from Enter-YurunaServiceOperation.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$Context)
    if ($null -eq $Context -or -not [bool]$Context.Proceed -or [bool]$Context.Completed) { return $false }
    if (-not (Test-YurunaServiceOperationLockContext -Context $Context.LockSet -Key ([string]$Context.Key))) { return $false }
    $census = Read-YurunaServiceCensus -StateRoot ([string]$Context.StateRoot)
    if (-not $census.Valid -or -not $census.Services.ContainsKey([string]$Context.Key)) { return $false }
    $intent = $census.Services[[string]$Context.Key].intent
    return [bool]($intent -and [long]$intent.generation -eq [long]$Context.Generation)
}

function Exit-YurunaServiceOperation {
    <#
    .SYNOPSIS
        Record the result of a service operation and release its lock.
    .DESCRIPTION
        The result lands on the operation's own intent generation. When a
        newer intent was published meanwhile the result is recorded as
        superseded, a warning says the newer request stands, and the newer
        intent is left untouched. The lock set is released in every case;
        a second call, a $null context and a refused context are no-ops.
    .PARAMETER Context
        A Yuruna.ServiceOperation from Enter-YurunaServiceOperation.
    .PARAMETER Result
        confirmed (a stop that left the VM absent, a start that left it
        running) or failed.
    .PARAMETER FinalState
        The state last observed, recorded for diagnosis.
    .OUTPUTS
        [pscustomobject] @{ Recorded; Result confirmed|failed|superseded|
        not-recorded; NewerOperation; Reason }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Context,
        [Parameter(Mandatory)][ValidateSet('confirmed', 'failed')][string]$Result,
        [AllowEmptyString()][string]$FinalState = ''
    )
    $outcome = [ordered]@{ Recorded = $false; Result = 'not-recorded'; NewerOperation = ''; Reason = 'no-operation' }
    if ($null -eq $Context -or $null -eq $Context.PSObject.Properties['Proceed']) { return [pscustomobject]$outcome }
    try {
        if (-not [bool]$Context.Proceed -or [bool]$Context.Completed) { return [pscustomobject]$outcome }
        $operationName = ([string]$Context.Operation).ToLowerInvariant()
        if (-not $PSCmdlet.ShouldProcess([string]$Context.Key, (Format-YurunaOperatorMessage -Key 'runner.service_operation_complete_should_process' -Arguments @{ operation = $operationName; key = [string]$Context.Key }))) {
            $outcome.Reason = 'preview'
            return [pscustomobject]$outcome
        }
        $Context.Completed = $true
        $key = [string]$Context.Key
        $completeMutation = {
            param($State, $Output, $Argument)
            $closed = Complete-ServiceIntent -State $State -Key $Argument.Key -Generation $Argument.Generation `
                -Result $Argument.Result -FinalState $Argument.FinalState -NowUnixMs (Get-ServiceCensusUtcNow)
            $Output.Output = $closed
            return [bool]$closed.Found
        }
        $mutated = Invoke-ServiceCensusMutation -Root ([string]$Context.StateRoot) -Mutation $completeMutation `
            -LockWaitMilliseconds $script:MutatorLockWaitMs `
            -Argument @{ Key = $key; Generation = [long]$Context.Generation; Result = $Result; FinalState = $FinalState }
        $scriptName = if ($Context.Script) { [string]$Context.Script } else { 'service operation' }
        if ($mutated.Reason -ne 'ok') {
            $outcome.Reason = [string]$mutated.Reason
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_operation_result_unrecorded' -Arguments @{
                    script = $scriptName; operation = $operationName; key = $key; reason = [string]$mutated.Reason })
            return [pscustomobject]$outcome
        }
        $closed = $mutated.Output
        $outcome.Recorded = $true
        $outcome.Result = [string]$closed.Result
        $outcome.NewerOperation = [string]$closed.NewerOperation
        $outcome.Reason = 'ok'
        if ($closed.Result -eq 'superseded') {
            $Context.NewerOperation = [string]$closed.NewerOperation
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_operation_superseded' -Arguments @{
                    script = $scriptName; newerOperation = [string]$closed.NewerOperation; key = $key; operation = $operationName })
        }
        return [pscustomobject]$outcome
    } finally {
        Exit-YurunaServiceOperationLockSet -Context $Context.LockSet
    }
}

function ConvertTo-ServiceCensusRosterKey {
    <#
    .SYNOPSIS
        The roster key a service VM name stands for ('yuruna-stash-service'
        -> 'stash'), or '' when the name has no such shape.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$VMName)
    if ($VMName -cmatch '^yuruna-([a-z0-9][a-z0-9-]*?)-service$') { return $Matches[1] }
    return ''
}

function Get-ServiceCensusRosterRow {
    <#
    .SYNOPSIS
        The union of the manifest roster and the hard-coded service VM
        names, one row per key, with the source of each and the
        disagreements between the two lists.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object[]]$Roster,
        [AllowNull()][string[]]$HardCodedName,
        [switch]$UseDefaultRoster,
        [switch]$UseDefaultHardCoded
    )
    $manifestRows = [System.Collections.Generic.List[object]]::new()
    if ($UseDefaultRoster) {
        foreach ($manifest in @(Get-ExtensionServiceManifestAll -WithVMOnly)) {
            if ($null -eq $manifest) { continue }
            $manifestRows.Add([pscustomobject]@{
                    Key         = ([string]$manifest.Area -replace '-service$', '')
                    Area        = [string]$manifest.Area
                    VMName      = [string]$manifest.VMName
                    DisplayName = [string]$manifest.DisplayName
                    HealthPort  = [int]$manifest.HealthPort
                    StartScript = [string]$manifest.StartScript
                    StopScript  = [string]$manifest.StopScript
                })
        }
    } else {
        foreach ($row in @($Roster | Where-Object { $null -ne $_ })) {
            $get = { param([string]$Name) if ($row -is [System.Collections.IDictionary]) { $row[$Name] } else { $row.$Name } }
            $key = [string](& $get 'Key')
            $area = [string](& $get 'Area')
            if (-not $area) { $area = "$key-service" }
            $manifestRows.Add([pscustomobject]@{
                    Key = $key; Area = $area; VMName = [string](& $get 'VMName'); DisplayName = [string](& $get 'DisplayName')
                    HealthPort = [int](ConvertTo-ServiceCensusLong -Value (& $get 'HealthPort'))
                    StartScript = [string](& $get 'StartScript'); StopScript = [string](& $get 'StopScript')
                })
        }
    }
    $hardCoded = if ($UseDefaultHardCoded) { @(Get-YurunaServiceVmName) } else { @($HardCodedName | Where-Object { $_ }) }
    $rows = [ordered]@{}
    $disagreement = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $manifestRows) {
        if ($row.Key -cnotmatch $script:ServiceKeyPattern -or $rows.Contains($row.Key)) {
            $disagreement.Add("manifest-key:$($row.Key)")
            continue
        }
        $source = if ($hardCoded -ccontains $row.VMName) { 'manifest+hard-coded' } else { 'manifest' }
        if ($source -eq 'manifest') { $disagreement.Add("manifest-only:$($row.VMName)") }
        $row | Add-Member -NotePropertyName Source -NotePropertyValue $source -Force
        $rows[$row.Key] = $row
    }
    foreach ($name in $hardCoded) {
        $known = @($manifestRows | Where-Object { $_.VMName -ceq $name })
        if ($known.Count -gt 0) { continue }
        $disagreement.Add("hard-coded-only:$name")
        $key = ConvertTo-ServiceCensusRosterKey -VMName $name
        if (-not $key -or $rows.Contains($key)) { continue }
        $rows[$key] = [pscustomobject]@{
            Key = $key; Area = "$key-service"; VMName = $name; DisplayName = $name; HealthPort = 0
            StartScript = ''; StopScript = ''; Source = 'hard-coded'
        }
    }
    return [pscustomobject]@{ Rows = [object[]]@($rows.Values); Disagreement = [string[]]$disagreement.ToArray() }
}

function Read-CachingProxyAdvertisedAddress {
    <#
    .SYNOPSIS
        The caching proxy's persisted ipAddress, read by line from
        <RuntimeDir>/yuruna-caching-proxy-service.yml, or ''.
    .DESCRIPTION
        A line read, not a YAML parse and not the caching-proxy module's own
        reader: that reader creates the runtime directory, and this runs in
        read-only capture paths.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$RuntimeDir)
    if ([string]::IsNullOrWhiteSpace($RuntimeDir)) { return '' }
    $path = Join-Path $RuntimeDir 'yuruna-caching-proxy-service.yml'
    if (-not [System.IO.File]::Exists($path)) { return '' }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if ($line -match '^ipAddress:\s*(.*)$') {
                return ($Matches[1].Trim().Trim('"', "'", ' '))
            }
        }
    } catch {
        Write-Verbose "Read-CachingProxyAdvertisedAddress: $($_.Exception.Message)"
    }
    return ''
}

function ConvertTo-ServiceCensusEndpoint {
    <#
    .SYNOPSIS
        An advertised base URL as {Address; Port; Url; Origin}.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$Url,
        [int]$DefaultPort,
        [string]$Origin
    )
    $empty = [pscustomobject]@{ Address = ''; Port = 0; Url = ''; Origin = 'none' }
    if ([string]::IsNullOrWhiteSpace($Url)) { return $empty }
    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $empty }
    $port = if ($uri.IsDefaultPort -and $DefaultPort -gt 0 -and $uri.Port -le 0) { $DefaultPort } else { [int]$uri.Port }
    return [pscustomobject]@{ Address = [string]$uri.Host.Trim('[', ']'); Port = $port; Url = $Url.Trim(); Origin = $Origin }
}

function Invoke-ServiceCensusTcpProbe {
    <#
    .SYNOPSIS
        Parallel TCP connects to a set of endpoints within one bounded wait.
    .DESCRIPTION
        Every connect starts at once and one wait covers them all, so the
        cost of a set is the slowest answer or the cap, never the sum. Every
        socket is disposed before returning; a connect still pending at the
        cap is 'timeout'.
    .OUTPUTS
        [hashtable] Id -> answered|refused|timeout|no-address
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Target,
        [Parameter(Mandatory)][ValidateRange(0, 600000)][int]$TimeoutMilliseconds
    )
    $outcome = @{}
    $pending = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($t in @($Target)) {
            $id = [string]$t.Id
            $address = [string]$t.Address
            $port = [int]$t.Port
            if ([string]::IsNullOrWhiteSpace($address) -or $port -le 0 -or $port -gt 65535) { $outcome[$id] = 'no-address'; continue }
            if ($TimeoutMilliseconds -le 0) { $outcome[$id] = 'timeout'; continue }
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $ip = $null
                $task = if ([System.Net.IPAddress]::TryParse($address, [ref]$ip)) { $client.ConnectAsync($ip, $port) } else { $client.ConnectAsync($address, $port) }
                $pending.Add([pscustomobject]@{ Id = $id; Client = $client; Task = $task })
            } catch {
                $outcome[$id] = 'refused'
                $client.Dispose()
            }
        }
        if ($pending.Count -gt 0) {
            $tasks = [System.Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Task })
            try { $null = [System.Threading.Tasks.Task]::WaitAll($tasks, $TimeoutMilliseconds) } catch { $null = $_ }
            foreach ($entry in $pending) {
                $status = $entry.Task.Status
                $outcome[$entry.Id] = if ($status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $entry.Client.Connected) { 'answered' }
                                      elseif ($entry.Task.IsCompleted) { 'refused' }
                                      else { 'timeout' }
            }
        }
    } finally {
        foreach ($entry in $pending) {
            try { $entry.Client.Dispose() } catch { $null = $_ }
            # A connect still in flight faults once its socket is gone; the
            # fault is observed here so it never surfaces as an unobserved
            # task exception later.
            try { $null = $entry.Task.Exception } catch { $null = $_ }
        }
    }
    return $outcome
}

function Get-ServiceCensusHostKind {
    <#
    .SYNOPSIS
        The provider kind of a host type: utm, libvirt, hyperv or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$HostType)
    switch ($HostType) {
        'host.macos.utm'       { return 'utm' }
        'host.ubuntu.kvm'      { return 'libvirt' }
        'host.windows.hyper-v' { return 'hyperv' }
    }
    return ''
}

function Get-YurunaServiceVmIdentitySet {
    <#
    .SYNOPSIS
        The deployed identity of every managed service: which key, which VM
        name, where it is hosted and what it advertises. Read-only.
    .DESCRIPTION
        The manifest roster is united with the hard-coded service VM name
        list, keeping the source of each name; a name in only one of them is
        a roster disagreement, which refresh refuses to disrupt past.
        Manifest names are defaults, not a deployed inventory: the runtime
        marker and the newest intent both record the name actually used, and
        a captured custom name is never re-resolved by key. When the marker
        and the intent disagree the row is conflicting-identity; a custom
        name equal to another service's default is duplicate-name; a name
        that is not a valid VM name is invalid-name.

        Pool-control can run as a host process. Its marker then carries the
        process id (and, from newer launchers, hostingMode and the process
        start time); the process is checked by name, start time and a
        loopback connect to its port before the row is called host-process.
        A dead process makes the row 'none'; one that cannot be established
        either way is 'unknown' with host-side-unverified.

        Advertised endpoints come from files only: the caching proxy's
        persisted ipAddress and the other markers' base URLs. With
        -ResolveProvider, the passive resolver fills the provider identity
        (bundle, MAC, network mode) and the forwarder table is captured;
        without a platform resolver ForwardersCaptured stays $false and the
        forwarders are unknown collateral. Nothing here creates, rotates or
        writes a file.
    .PARAMETER RuntimeDir
        Runtime directory holding the markers; defaults to
        $env:YURUNA_RUNTIME_DIR.
    .PARAMETER Census
        A Read-YurunaServiceCensus result; read from StateRoot when omitted.
    .PARAMETER StateRoot
        Private root for the census read.
    .PARAMETER HostType
        Host type; defaults to Get-HostType when loaded.
    .PARAMETER ResolveProvider
        Consult the passive resolver and the forwarder table.
    .PARAMETER Deadline
        Bounds the provider resolution; defaults to ten seconds.
    .PARAMETER Roster
        Test seam: manifest rows to use instead of the area manifests.
    .PARAMETER HardCodedName
        Test seam: the hard-coded name list to use.
    .PARAMETER ProcessLookup
        Test seam passed to Get-ExtensionServiceHostProcessState.
    .PARAMETER NowUnixMs
        Capture time; defaults to now.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceVmIdentitySet: SchemaVersion;
        CapturedUnixMs; RosterAgreement; RosterDisagreement [string[]]; Rows.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowNull()][psobject]$Census,
        [AllowEmptyString()][string]$StateRoot,
        [AllowEmptyString()][string]$HostType,
        [switch]$ResolveProvider,
        $Deadline,
        [AllowNull()][object[]]$Roster,
        [AllowNull()][string[]]$HardCodedName,
        [scriptblock]$ProcessLookup,
        [long]$NowUnixMs
    )
    if (-not $PSBoundParameters.ContainsKey('NowUnixMs')) { $NowUnixMs = Get-ServiceCensusUtcNow }
    if (-not $PSBoundParameters.ContainsKey('HostType')) {
        $HostType = ''
        $detector = Get-Command -Name 'Get-HostType' -ErrorAction SilentlyContinue
        if ($detector) { try { $HostType = [string](& $detector) } catch { $HostType = '' } }
    }
    if ($null -eq $Census) { $Census = Read-YurunaServiceCensus -StateRoot $StateRoot -NowUnixMs $NowUnixMs }
    $union = Get-ServiceCensusRosterRow -Roster $Roster -HardCodedName $HardCodedName `
        -UseDefaultRoster:(-not $PSBoundParameters.ContainsKey('Roster')) `
        -UseDefaultHardCoded:(-not $PSBoundParameters.ContainsKey('HardCodedName'))
    $defaultNames = @{}
    foreach ($row in $union.Rows) { $defaultNames[$row.Key] = [string]$row.VMName }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($base in $union.Rows) {
        $key = [string]$base.Key
        $identity = Get-ExtensionServiceDeploymentIdentity -Area ([string]$base.Area) -RuntimeDir $RuntimeDir
        $censusRecord = if ($Census -and $Census.Services -and $Census.Services.ContainsKey($key)) { $Census.Services[$key] } else { $null }
        $intent = if ($censusRecord) { $censusRecord.intent } else { $null }
        $markerName = if ($identity.MarkerPresent) { [string]$identity.VMName } else { '' }
        $intentName = if ($intent) { [string]$intent.vmName } else { '' }
        $ambiguity = ''
        $vmName = [string]$base.VMName
        $vmNameSource = 'manifest-default'
        if ($markerName) {
            $vmName = $markerName; $vmNameSource = 'marker'
            if ($intentName -and $intentName -cne $markerName) { $ambiguity = 'conflicting-identity' }
        } elseif ($intentName) {
            $vmName = $intentName; $vmNameSource = 'intent'
        }
        if ($vmName -cnotmatch $script:VMNamePattern) {
            $ambiguity = 'invalid-name'
        } elseif (-not $ambiguity -and $vmNameSource -ne 'manifest-default' -and $vmName -cne [string]$base.VMName) {
            foreach ($otherKey in $defaultNames.Keys) {
                if ($otherKey -ne $key -and $defaultNames[$otherKey] -ceq $vmName) { $ambiguity = 'duplicate-name'; break }
            }
        }

        $hostingMode = 'vm'
        $hostProcess = $null
        if ($identity.MarkerPresent -and $identity.HostingMode -eq 'host-process') {
            $state = $null
            if ($identity.Pid) {
                $stateArguments = @{ ProcessId = [int]$identity.Pid; ExpectedName = [string]$base.Area }
                if ($identity.ProcessStartUnixMs) { $stateArguments.ProcessStartUnixMs = [long]$identity.ProcessStartUnixMs }
                if ($ProcessLookup) { $stateArguments.ProcessLookup = $ProcessLookup }
                $state = Get-ExtensionServiceHostProcessState @stateArguments
            }
            $portAnswered = $false
            if ($state -and $state.IdentityVerified -and $identity.Port) {
                $probe = Invoke-ServiceCensusTcpProbe -Target @([pscustomobject]@{ Id = 'self'; Address = '127.0.0.1'; Port = [int]$identity.Port }) -TimeoutMilliseconds 1000
                $portAnswered = ($probe['self'] -eq 'answered')
            }
            $hostProcess = [pscustomobject]@{
                Pid                = if ($identity.Pid) { [int]$identity.Pid } else { 0 }
                Port               = if ($identity.Port) { [int]$identity.Port } else { 0 }
                ProcessStartUnixMs = if ($identity.ProcessStartUnixMs) { [long]$identity.ProcessStartUnixMs } else { [long]0 }
                Alive              = [bool]($state -and $state.Alive)
                NameMatches        = [bool]($state -and $state.NameMatches)
                StartTimeMatches   = if ($state) { $state.StartTimeMatches } else { $null }
                IdentityVerified   = [bool]($state -and $state.IdentityVerified)
                PortAnswered       = $portAnswered
                Verified           = [bool]($state -and $state.IdentityVerified -and $portAnswered)
            }
            if ($hostProcess.Verified) {
                $hostingMode = 'host-process'
            } elseif ($state -and $state.Reason -eq 'not-running') {
                $hostingMode = 'none'
            } else {
                $hostingMode = 'unknown'
                if (-not $ambiguity) { $ambiguity = 'host-side-unverified' }
            }
        } elseif ($identity.MarkerPresent -and $identity.HostingMode -eq 'unknown') {
            $hostingMode = 'unknown'
            if (-not $ambiguity) { $ambiguity = 'host-side-unverified' }
        }

        $advertised = [pscustomobject]@{ Address = ''; Port = 0; Url = ''; Origin = 'none' }
        if ($key -eq 'caching-proxy') {
            $cacheIp = Read-CachingProxyAdvertisedAddress -RuntimeDir $RuntimeDir
            if ($cacheIp) {
                $advertised = [pscustomobject]@{ Address = $cacheIp; Port = [int]$base.HealthPort; Url = ''; Origin = 'cp-state' }
            }
        } elseif ($identity.MarkerPresent -and $identity.BaseUrl) {
            $advertised = ConvertTo-ServiceCensusEndpoint -Url ([string]$identity.BaseUrl) -DefaultPort ([int]$base.HealthPort) -Origin 'marker'
        }

        $rows.Add([pscustomobject][ordered]@{
                Key                = $key
                Area               = [string]$base.Area
                VMName             = $vmName
                DisplayName        = [string]$base.DisplayName
                HealthPort         = [int]$base.HealthPort
                StartScript        = [string]$base.StartScript
                StopScript         = [string]$base.StopScript
                Source             = [string]$base.Source
                VMNameSource       = $vmNameSource
                HostingMode        = $hostingMode
                HostProcess        = $hostProcess
                Provider           = [pscustomobject]@{ Kind = (Get-ServiceCensusHostKind -HostType $HostType); BundlePath = ''; BundleMac = ''; NetworkMode = ''; Verified = $false }
                Advertised         = $advertised
                Forwarders         = [object[]]@()
                ForwardersCaptured = $false
                Ambiguity          = $ambiguity
                IntentGeneration   = if ($censusRecord) { [long]$censusRecord.intentGeneration } else { [long]0 }
                DesiredState       = if ($censusRecord) { [string]$censusRecord.desiredState } else { '' }
            })
    }

    if ($ResolveProvider) {
        $resolveDeadline = if ($Deadline) { $Deadline } else { New-YurunaDeadline -TotalMilliseconds 10000 }
        $contextCommand = Get-Command -Name 'Get-VMPassiveAddressContext' -ErrorAction SilentlyContinue
        $addressCommand = Get-Command -Name 'Get-VMPassiveAddress' -ErrorAction SilentlyContinue
        if ($contextCommand -and $addressCommand) {
            $passive = $null
            try { $passive = & $contextCommand -Deadline $resolveDeadline } catch { Write-Verbose "Get-YurunaServiceVmIdentitySet: passive context: $($_.Exception.Message)" }
            if ($passive) {
                foreach ($row in $rows) {
                    if ($row.HostingMode -ne 'vm' -or $row.Ambiguity -eq 'invalid-name') { continue }
                    if ((Get-YurunaDeadlineRemainingMs -Deadline $resolveDeadline) -lt 1000) { break }
                    try {
                        $found = & $addressCommand -VMName $row.VMName -Context $passive -Deadline $resolveDeadline
                        $row.Provider.BundlePath = [string]$found.BundlePath
                        $row.Provider.BundleMac = [string]$found.BundleMac
                        $row.Provider.NetworkMode = [string]$found.NetworkMode
                        $row.Provider.Verified = [bool]($found.BundlePath -and $found.BundleMac)
                    } catch {
                        Write-Verbose "Get-YurunaServiceVmIdentitySet: passive address for '$($row.VMName)': $($_.Exception.Message)"
                    }
                }
            }
        }
        $portMapCommand = Get-Command -Name 'Get-PortMapTarget' -ErrorAction SilentlyContinue
        if ($portMapCommand) {
            try {
                $forwarders = [object[]]@(& $portMapCommand -Deadline $resolveDeadline)
                foreach ($row in $rows) {
                    $row.Forwarders = $forwarders
                    $row.ForwardersCaptured = $true
                }
            } catch {
                Write-Verbose "Get-YurunaServiceVmIdentitySet: forwarder capture: $($_.Exception.Message)"
            }
        }
    }

    return [pscustomobject][ordered]@{
        PSTypeName         = 'Yuruna.ServiceVmIdentitySet'
        SchemaVersion      = 1
        CapturedUnixMs     = $NowUnixMs
        RosterAgreement    = ($union.Disagreement.Count -eq 0)
        RosterDisagreement = [string[]]$union.Disagreement
        Rows               = [object[]]$rows.ToArray()
    }
}

function Invoke-YurunaServiceCensusTick {
    <#
    .SYNOPSIS
        One passive census pass: probe every service's candidate address,
        corroborate answers by MAC, merge the observations. Never throws.
    .DESCRIPTION
        Runs beside the host-address beacon's announce tick, on the one
        long-lived host process that ticks every few seconds. Everything it
        does is bounded by one deadline (at most five seconds): addresses
        are re-resolved through the platform's passive resolver at most once
        per service per ten minutes, whether or not the last attempt found
        an address (a successful one is cached in the census, and every
        attempt is remembered by this process), all candidates are probed
        in parallel under one wait, and a busy merge lock or an exhausted
        budget skips the merge until the next tick.

        An answer counts as a positive only when an ARP read taken after the
        probe shows the answering address carrying the guest's bundle MAC,
        or when a verified host process answered its own port. A
        lease-only match, whose hardware field is a DHCP DUID rather than the
        MAC, and a TCP answer whose owner cannot be identified, only update
        lastUncorroboratedAnswerUnixMs.

        Refuses to run as root on Unix (the private root would end up owned
        by root and lock every later non-root reader out).
    .PARAMETER RuntimeDir
        Runtime directory with the markers; defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER StateRoot
        Private root; defaults to the resolved private state root.
    .PARAMETER BudgetMilliseconds
        The whole tick's bound.
    .PARAMETER ProbeTimeoutMilliseconds
        Cap for the parallel TCP probe.
    .PARAMETER ClockTicks
        Injected monotonic clock for tests.
    .PARAMETER NowUnixMs
        Observation time; defaults to now.
    .PARAMETER UserName
        Test seam: the account name to judge root by.
    .PARAMETER Roster
        Test seam passed to Get-YurunaServiceVmIdentitySet.
    .PARAMETER HardCodedName
        Test seam passed to Get-YurunaServiceVmIdentitySet.
    .OUTPUTS
        [pscustomobject] @{ Ran; Merged; Reason ok|lock-busy|root-unavailable|
        running-as-root|census-corrupt|census-unreadable|budget-exhausted|
        write-failed|unchanged|preview|error; ElapsedMs; Services [object[]] }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowEmptyString()][string]$StateRoot,
        [ValidateRange(500, 5000)][int]$BudgetMilliseconds = 5000,
        [ValidateRange(100, 5000)][int]$ProbeTimeoutMilliseconds = 1500,
        [scriptblock]$ClockTicks,
        [long]$NowUnixMs,
        [AllowEmptyString()][string]$UserName = [Environment]::UserName,
        [Parameter(DontShow)][AllowNull()][object[]]$Roster,
        [Parameter(DontShow)][AllowNull()][string[]]$HardCodedName
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ Ran = $false; Merged = $false; Reason = 'error'; ElapsedMs = [long]0; Services = [object[]]@() }
    $emit = {
        $result.ElapsedMs = $stopwatch.ElapsedMilliseconds
        [pscustomobject]$result
    }
    try {
        if (-not $PSBoundParameters.ContainsKey('NowUnixMs')) { $NowUnixMs = Get-ServiceCensusUtcNow }
        if (-not $IsWindows -and $UserName -eq 'root') {
            $result.Reason = 'running-as-root'
            return (& $emit)
        }
        if (-not $PSCmdlet.ShouldProcess($script:CensusRecordName, (Format-YurunaOperatorMessage -Key 'runner.service_census_tick_should_process'))) {
            $result.Reason = 'preview'
            return (& $emit)
        }
        # The record helper compiles once per process; paying that here keeps
        # it out of the tick's own budget.
        $null = Initialize-YurunaCriticalRecordIo
        $deadlineArguments = @{ TotalMilliseconds = $BudgetMilliseconds }
        if ($ClockTicks) { $deadlineArguments.ClockTicks = $ClockTicks }
        $deadline = New-YurunaDeadline @deadlineArguments
        $root = Resolve-ServiceCensusRoot -StateRoot $StateRoot
        if (-not $root.Resolved) {
            $result.Reason = 'root-unavailable'
            return (& $emit)
        }
        $census = Read-YurunaServiceCensus -StateRoot $root.Path -NowUnixMs $NowUnixMs -Deadline $deadline
        if (-not $census.Valid) {
            $result.Reason = ConvertTo-ServiceOperationCensusRefusal -CensusReason ([string]$census.Reason) -Fallback 'census-corrupt'
            return (& $emit)
        }
        $result.Ran = $true
        $identityArguments = @{ RuntimeDir = $RuntimeDir; Census = $census; NowUnixMs = $NowUnixMs }
        if ($PSBoundParameters.ContainsKey('Roster')) { $identityArguments.Roster = $Roster }
        if ($PSBoundParameters.ContainsKey('HardCodedName')) { $identityArguments.HardCodedName = $HardCodedName }
        $identity = Get-YurunaServiceVmIdentitySet @identityArguments
        $rows = @($identity.Rows | Where-Object { $_.HostingMode -in @('vm', 'host-process') -and $_.Ambiguity -ne 'invalid-name' })

        $contextCommand = Get-Command -Name 'Get-VMPassiveAddressContext' -ErrorAction SilentlyContinue
        $addressCommand = Get-Command -Name 'Get-VMPassiveAddress' -ErrorAction SilentlyContinue
        $resolverAvailable = [bool]($contextCommand -and $addressCommand)
        $resolved = @{}
        $resolvedAt = @{}
        $passive = $null
        # Only an address the passive resolver produced is a cache worth
        # keeping for ten minutes; an advertised one is re-read every tick
        # and never postpones a resolution.
        $resolvedOrigin = @('shared-lease', 'arp')
        $rootPath = [string]$root.Path
        $attemptKey = { param($Row) '{0}|{1}|{2}' -f $rootPath, $Row.Key, $Row.VMName }
        # An attempt outside the interval, or ahead of a clock that moved
        # back, no longer postpones anything.
        foreach ($expired in @($script:ResolveAttempt.Keys | Where-Object {
                    $attemptAge = $NowUnixMs - [long]$script:ResolveAttempt[$_].UnixMs
                    $attemptAge -lt 0 -or $attemptAge -ge $script:ResolveIntervalMs
                })) {
            $script:ResolveAttempt.Remove($expired)
        }
        $due = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            if ($row.HostingMode -ne 'vm') { continue }
            $stored = if ($census.Services.ContainsKey($row.Key)) { $census.Services[$row.Key] } else { $null }
            $storedCurrent = $stored -and $stored.address -and [string]$stored.addressOrigin -in $resolvedOrigin -and
                [string]$stored.vmName -ceq [string]$row.VMName -and
                ($NowUnixMs - [long]$stored.addressResolvedUnixMs) -lt $script:ResolveIntervalMs
            if ($storedCurrent) { continue }
            $attempt = $script:ResolveAttempt[(& $attemptKey $row)]
            if ($attempt) {
                # Attempted within the interval. An address it found that no
                # merge has stored yet is still this attempt's answer.
                $previous = $attempt.Result
                if ($previous -and [string]$previous.Reason -eq 'ok' -and $previous.Address) {
                    $resolved[$row.Key] = $previous
                    $resolvedAt[$row.Key] = [long]$attempt.UnixMs
                }
                continue
            }
            $due.Add($row)
        }
        if ($resolverAvailable -and $due.Count -gt 0) {
            $resolveDeadline = New-YurunaDeadline -Parent $deadline -ReserveMilliseconds 3000
            $contextAttempted = $false
            if ((Get-YurunaDeadlineRemainingMs -Deadline $resolveDeadline) -ge 1000) {
                $contextAttempted = $true
                try { $passive = & $contextCommand -Deadline $resolveDeadline } catch { Write-Verbose "Invoke-YurunaServiceCensusTick: passive context: $($_.Exception.Message)" }
            }
            if ($passive) {
                foreach ($row in $due) {
                    if ((Get-YurunaDeadlineRemainingMs -Deadline $resolveDeadline) -lt 1000) { break }
                    $found = $null
                    try {
                        $found = & $addressCommand -VMName $row.VMName -Context $passive -Deadline $resolveDeadline
                    } catch {
                        Write-Verbose "Invoke-YurunaServiceCensusTick: passive address for '$($row.VMName)': $($_.Exception.Message)"
                    }
                    $script:ResolveAttempt[(& $attemptKey $row)] = @{ UnixMs = $NowUnixMs; Result = $found }
                    if ($found) {
                        $resolved[$row.Key] = $found
                        $resolvedAt[$row.Key] = $NowUnixMs
                    }
                }
            } elseif ($contextAttempted) {
                # No context means no service could be resolved this time;
                # that is an attempt for each of them all the same.
                foreach ($row in $due) { $script:ResolveAttempt[(& $attemptKey $row)] = @{ UnixMs = $NowUnixMs; Result = $null } }
            }
        }

        $observations = [System.Collections.Generic.List[object]]::new()
        $targets = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $stored = if ($census.Services.ContainsKey($row.Key)) { $census.Services[$row.Key] } else { $null }
            $sameGuest = $stored -and ([string]$stored.vmName -ceq [string]$row.VMName)
            $observation = [ordered]@{
                Key = $row.Key; VMName = $row.VMName; VMNameSource = $row.VMNameSource; Source = $row.Source
                HostingMode = $row.HostingMode; HealthPort = $row.HealthPort
                Address = ''; AddressOrigin = 'none'; AddressResolvedUnixMs = [long]0
                BundleMac = if ($sameGuest) { [string]$stored.bundleMac } else { '' }
                NetworkMode = ''; MacCorroborated = $false
                Answered = $false; AnsweredIdentity = ''; AnsweredAddress = ''; ProbeOutcome = 'skipped'; ObservedUnixMs = $NowUnixMs
                CandidateAddress = ''; CandidatePort = [int]$row.HealthPort
            }
            if ($row.HostingMode -eq 'host-process' -and $row.HostProcess -and $row.HostProcess.Port) {
                $observation.CandidateAddress = '127.0.0.1'
                $observation.CandidatePort = [int]$row.HostProcess.Port
            } elseif ($resolved.ContainsKey($row.Key)) {
                $fresh = $resolved[$row.Key]
                if ($fresh.BundleMac) { $observation.BundleMac = [string]$fresh.BundleMac }
                $observation.NetworkMode = [string]$fresh.NetworkMode
                if ($fresh.Reason -eq 'ok' -and $fresh.Address) {
                    $observation.Address = [string]$fresh.Address
                    $observation.AddressOrigin = [string]$fresh.Origin
                    $observation.AddressResolvedUnixMs = [long]$resolvedAt[$row.Key]
                    $observation.MacCorroborated = [bool]$fresh.MacCorroborated
                    $observation.CandidateAddress = [string]$fresh.Address
                }
            }
            if (-not $observation.CandidateAddress -and $sameGuest -and $stored.address -and [string]$stored.addressOrigin -in $resolvedOrigin) {
                $observation.CandidateAddress = [string]$stored.address
            }
            if (-not $observation.CandidateAddress -and $row.Advertised -and $row.Advertised.Address) {
                # The advertised endpoint is probed where consumers dial it,
                # which for a forwarded service is a host port, not the
                # guest's health port.
                $observation.CandidateAddress = [string]$row.Advertised.Address
                if ([int]$row.Advertised.Port -gt 0) { $observation.CandidatePort = [int]$row.Advertised.Port }
                if (-not $observation.Address) {
                    $observation.Address = [string]$row.Advertised.Address
                    $observation.AddressOrigin = [string]$row.Advertised.Origin
                    $observation.AddressResolvedUnixMs = $NowUnixMs
                }
            }
            if ($observation.CandidateAddress) {
                $targets.Add([pscustomobject]@{ Id = $row.Key; Address = $observation.CandidateAddress; Port = $observation.CandidatePort })
            } else {
                $observation.ProbeOutcome = 'no-address'
            }
            $observations.Add([pscustomobject]$observation)
        }

        $probeBudget = [int][Math]::Min([long]$ProbeTimeoutMilliseconds, (Get-YurunaDeadlineRemainingMs -Deadline $deadline) - 2500)
        if ($targets.Count -gt 0 -and $probeBudget -lt 100) {
            $result.Reason = 'budget-exhausted'
            return (& $emit)
        }
        $answers = if ($targets.Count -gt 0) { Invoke-ServiceCensusTcpProbe -Target $targets.ToArray() -TimeoutMilliseconds $probeBudget } else { @{} }
        $anyGuestAnswer = $false
        foreach ($observation in $observations) {
            if (-not $answers.ContainsKey($observation.Key)) { continue }
            $observation.ProbeOutcome = [string]$answers[$observation.Key]
            if ($observation.ProbeOutcome -eq 'answered') {
                $observation.Answered = $true
                $observation.AnsweredAddress = $observation.CandidateAddress
                if ($observation.HostingMode -eq 'host-process') { $observation.AnsweredIdentity = 'host-process' } else { $anyGuestAnswer = $true }
            }
        }
        if ($anyGuestAnswer -and $resolverAvailable) {
            $arpDeadline = New-YurunaDeadline -Parent $deadline -ReserveMilliseconds 1500
            $arp = $null
            if ((Get-YurunaDeadlineRemainingMs -Deadline $arpDeadline) -ge 500) {
                $arpArguments = @{ Deadline = $arpDeadline; ArpOnly = $true }
                if ($passive -and $passive.SubnetEvidence) { $arpArguments.SubnetEvidence = $passive.SubnetEvidence }
                try { $arp = & $contextCommand @arpArguments } catch { Write-Verbose "Invoke-YurunaServiceCensusTick: ARP read: $($_.Exception.Message)" }
            }
            if ($arp -and $arp.ArpReason -in @('ok', 'injected') -and $arp.ArpMap) {
                foreach ($observation in $observations) {
                    if (-not $observation.Answered -or $observation.HostingMode -ne 'vm' -or -not $observation.BundleMac) { continue }
                    $seen = [string]$arp.ArpMap[[string]$observation.AnsweredAddress]
                    if ($seen -and [string]::Equals($seen, [string]$observation.BundleMac, [StringComparison]::OrdinalIgnoreCase)) {
                        $observation.AnsweredIdentity = 'mac-corroborated'
                    }
                }
            }
        }
        $services = [System.Collections.Generic.List[object]]::new()
        foreach ($observation in $observations) {
            $services.Add([pscustomobject]@{
                    Key = $observation.Key; VMName = $observation.VMName; Address = $observation.CandidateAddress
                    AddressOrigin = $observation.AddressOrigin; MacCorroborated = [bool]$observation.MacCorroborated
                    ProbeOutcome = $observation.ProbeOutcome
                    Positive = ($observation.Answered -and $observation.AnsweredIdentity -in @('mac-corroborated', 'host-process'))
                })
        }
        $result.Services = [object[]]$services.ToArray()

        # The merge needs its lock wait plus a second for the record write,
        # which refuses to start with less than that left.
        $remaining = Get-YurunaDeadlineRemainingMs -Deadline $deadline
        if ($remaining -lt 1500) {
            $result.Reason = 'budget-exhausted'
            return (& $emit)
        }
        $merge = Update-YurunaServiceCensusObservation -Observation $observations.ToArray() -StateRoot $root.Path -Deadline $deadline `
            -LockWaitMilliseconds ([int][Math]::Min([long]$script:TickLockWaitMs, $remaining - 1300)) -NowUnixMs $NowUnixMs -Confirm:$false -WhatIf:$false
        $result.Merged = [bool]$merge.Merged
        $result.Reason = switch ($merge.Reason) {
            'ok'        { 'ok' }
            'unchanged' { 'unchanged' }
            'lock-busy' { 'lock-busy' }
            'corrupt'   { 'census-corrupt' }
            'unreadable' { 'census-unreadable' }
            'root-unavailable' { 'root-unavailable' }
            default     { 'write-failed' }
        }
        return (& $emit)
    } catch {
        Write-Verbose "Invoke-YurunaServiceCensusTick: $($_.Exception.Message)"
        $result.Reason = 'error'
        return (& $emit)
    }
}

Export-ModuleMember -Function Get-YurunaServiceCensusCapability, Read-YurunaServiceCensus, Get-YurunaServiceIntent, `
    Update-YurunaServiceCensusObservation, Enter-YurunaServiceOperationLockSet, Exit-YurunaServiceOperationLockSet, `
    Test-YurunaServiceOperationLockContext, Enter-YurunaServiceOperation, Test-YurunaServiceOperationCurrent, `
    Exit-YurunaServiceOperation, Get-YurunaServiceVmIdentitySet, Invoke-YurunaServiceCensusTick
