<#PSScriptInfo
.VERSION 2026.09.27
.GUID 426c2f81-86df-422e-8db7-a94bd7ff61fe
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna service vm reboot recovery
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

# --- REGION: https://yuruna.link/42ad660e-0021
# Host-neutral by construction: every driver implements the same VM contract
# (Get-VMState / Start-VM / Get-VMIp), and those names are resolved at CALL
# time, so a caller that has not run Initialize-YurunaHost degrades to a
# reported no-op instead of an error.

# One TCP probe's cap. The service ports are on the local hypervisor network, so
# a live service answers in milliseconds; this bound only decides how fast a dead
# one is called dead.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:ServiceVmProbeTimeoutMs = 1500
# The longest a driver's full Get-VMIp can take where a passive resolver also
# exists. On macOS that chain is a guest-agent utmctl call, a bundle read, an
# ARP read, a state query and a subnet sweep, each under its own cap, and it
# takes no deadline; under a shared deadline it runs only when this much is
# left, and the passive resolver answers otherwise.
$script:ServiceVmFullAddressLookupMs = 75000
# Private-root reasons under which no root exists at all, so no census, no
# recorded intent and no operation lock can exist either. Any other reason is
# a root that may exist but cannot be trusted, and may hold an intent.
$script:ServiceVmRootAbsentReason = @('absent', 'no-home', 'create-failed')

# The extension half of the roster comes from the area manifests. Imported here
# rather than assumed in scope: this module is loaded on its own by the reboot
# sweep and by cleanup paths, and an empty roster is the one failure that
# matters -- it would leave a rebooted host's service VMs off and let a
# prefix-matching cleanup treat them as ordinary test VMs.
Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -Force -DisableNameChecking -Verbose:$false
# The census supplies intents, evidence and the per-service operation locks;
# Yuruna.Common supplies the shared deadline. Neither is forced: both are
# leaves this module only reads from, and a forced reload would move them out
# from under a caller that imported them first.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.ServiceCensus.psm1') -DisableNameChecking

function Get-YurunaServiceVmRoster {
    <#
    .SYNOPSIS
        The service VMs this framework builds, as records. Pure: no I/O, no
        host contract, no config.
    .DESCRIPTION
        The single source of truth for "which VMs are services". Without it the
        names would live only as parameter defaults inside their own
        Start-*ServiceVM.ps1, where nothing else could enumerate them -- the
        reboot sweep could not exist and no cleanup path could prove it would
        never sweep a service VM by prefix.

        Every service VM here is DISCOVERED from its own area manifest
        (test/extension/<area>/<area>.config.yml, `service:` block), so a new one
        joins the sweep by existing rather than by an edit here. That includes
        the caching proxy: listing it inline instead, on the grounds that it is
        the machine the pool services run ON rather than an area of its own, is
        true of the VM but leaves the one service nothing could ask a manifest
        about.

        HealthPort is what a CONSUMER connects to, deliberately, rather than
        whatever the guest happens to also listen on: :3128 is the squid port
        guests proxy through, and :80 is the /healthz the stash pre-flight and
        the pool-control UI are gated on. A VM that is 'running' but not
        answering that port is not yet a service. The caching proxy's
        management daemon listens elsewhere and reports its own liveness to the
        pool through its beacon, so this port stays squid's: it is the one a
        proxy VM can answer whether or not it has been rebuilt since the daemon
        was added.
    .PARAMETER Key
        Optional filter. Unknown keys yield nothing rather than throwing, so a
        caller can name a service this version does not have.
    .OUTPUTS
        pscustomobject[] -- Key, VMName, DisplayName, StartScript, HealthPort.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string[]]$Key)

    $all = @(Get-ExtensionServiceVmRoster)
    if (-not $Key -or @($Key | Where-Object { $_ }).Count -eq 0) { return [pscustomobject[]]$all }
    $wanted = @($Key | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
    return [pscustomobject[]]@($all | Where-Object { $wanted -contains $_.Key })
}

function Test-YurunaServiceVmPort {
    <#
    .SYNOPSIS
        $true when a TCP connect to Address:Port completes inside the cap.
        Never throws.
    .DESCRIPTION
        A connect, not a protocol exchange: the question here is only whether the
        service is up enough to be worth handing to its own probe. The
        authoritative verdicts still live where they were -- the caching-proxy
        gate and the stash pre-flight -- and this must not become a second,
        divergent opinion of what "healthy" means.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Address,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = $script:ServiceVmProbeTimeoutMs
    )
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($Address.Trim(), $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        # EndConnect is what surfaces a refusal; without it a completed-but-failed
        # handshake reads as connected.
        $client.EndConnect($async)
        return [bool]$client.Connected
    } catch {
        Write-Verbose "Test-YurunaServiceVmPort($Address`:$Port): $($_.Exception.Message)"
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { $null = $_ } }
    }
}

function Get-YurunaServiceVmAddress {
    <#
    .SYNOPSIS
        The address this host would dial to reach a service VM, or '' when none
        could be resolved. Never throws.
    .DESCRIPTION
        Resolved through the host driver's Get-VMIp, which is the same answer
        every consumer of a service is handed. Absence is a legitimate reading
        rather than an error: a Bridged UTM guest has no lease file and no guest
        agent, so a host can genuinely be unable to name a VM it is running.
        Callers decide what that means for them -- which is why it comes back as
        an empty string instead of a throw.

        Get-VMIp takes no deadline. Under -Deadline, a driver that also
        offers the passive resolver (Get-VMPassiveAddressContext and
        Get-VMPassiveAddress, which are bounded by it) is asked that way
        first, and its full Get-VMIp chain runs only while its whole worst
        case still fits in what is left; nothing is asked once the deadline
        is spent.
    .PARAMETER VMName
        The guest.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        $Deadline
    )
    if ($Deadline) {
        if ((Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -le 0) { return '' }
        $contextCommand = Get-Command -Name 'Get-VMPassiveAddressContext' -ErrorAction SilentlyContinue
        $addressCommand = Get-Command -Name 'Get-VMPassiveAddress' -ErrorAction SilentlyContinue
        if ($contextCommand -and $addressCommand) {
            if ((Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -ge 1000) {
                try {
                    $context = & $contextCommand -Deadline $Deadline
                    if ($context) {
                        $found = & $addressCommand -VMName $VMName -Context $context -Deadline $Deadline
                        if ($found -and [string]$found.Reason -eq 'ok' -and $found.Address) { return [string]$found.Address }
                    }
                } catch {
                    Write-Verbose "Get-YurunaServiceVmAddress('$VMName'): passive resolver: $($_.Exception.Message)"
                }
            }
            if ((Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt $script:ServiceVmFullAddressLookupMs) { return '' }
        }
    }
    if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return '' }
    try { return [string](Get-VMIp -VMName $VMName) } catch {
        Write-Verbose "Get-YurunaServiceVmAddress('$VMName'): $($_.Exception.Message)"
        return ''
    }
}

function Test-ServiceVmEndpointSet {
    <#
    .SYNOPSIS
        Parallel TCP connects to a set of endpoints under one bounded wait:
        Id -> $true (answered) or $false.
    .DESCRIPTION
        Every connect starts at once, so a set of silent endpoints costs one
        cap, not one cap each. Every socket is disposed before returning.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Target,
        [Parameter(Mandatory)][ValidateRange(0, 600000)][int]$TimeoutMilliseconds
    )
    $answered = @{}
    $pending = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($t in @($Target)) {
            $id = [string]$t.Id
            $answered[$id] = $false
            $address = [string]$t.Address
            $port = [int]$t.Port
            if ([string]::IsNullOrWhiteSpace($address) -or $port -le 0 -or $port -gt 65535 -or $TimeoutMilliseconds -le 0) { continue }
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $ip = $null
                $task = if ([System.Net.IPAddress]::TryParse($address, [ref]$ip)) { $client.ConnectAsync($ip, $port) } else { $client.ConnectAsync($address, $port) }
                $pending.Add([pscustomobject]@{ Id = $id; Client = $client; Task = $task })
            } catch {
                $client.Dispose()
            }
        }
        if ($pending.Count -gt 0) {
            $tasks = [System.Threading.Tasks.Task[]]@($pending | ForEach-Object { $_.Task })
            try { $null = [System.Threading.Tasks.Task]::WaitAll($tasks, $TimeoutMilliseconds) } catch { $null = $_ }
            foreach ($entry in $pending) {
                $answered[$entry.Id] = ($entry.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $entry.Client.Connected)
            }
        }
    } finally {
        foreach ($entry in $pending) {
            try { $entry.Client.Dispose() } catch { $null = $_ }
            try { $null = $entry.Task.Exception } catch { $null = $_ }
        }
    }
    return $answered
}

function ConvertTo-ServiceVmIdentityRow {
    <#
    .SYNOPSIS
        One identity row, from a capture (pscustomobject) or read back from
        JSON (hashtable), with every field the policy and restore read.
    .DESCRIPTION
        A row whose key or VM name does not have a valid shape is kept, with
        Ambiguity 'invalid-name', so the caller reports it instead of the
        row silently disappearing; nothing is ever run against such a name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Row)
    # Bound to a local so the read below is visibly a use of the parameter.
    $source = $Row
    # A verdict row (Test-YurunaServiceVmRunning Services, RecoverySet) carries
    # the captured identity row under Identity; the advertised endpoint and
    # forwarders live only there, so the identity row is what is normalized.
    $nested = if ($source -is [System.Collections.IDictionary]) { $source['Identity'] } elseif ($source.PSObject.Properties['Identity']) { $source.Identity } else { $null }
    if ($nested) {
        $nestedKey = if ($nested -is [System.Collections.IDictionary]) { $nested['Key'] } else { $nested.Key }
        if ($nestedKey) { $source = $nested }
    }
    $get = {
        param([string]$Name)
        if ($source -is [System.Collections.IDictionary]) { $source[$Name] } elseif ($source.PSObject.Properties[$Name]) { $source.$Name } else { $null }
    }
    $key = [string](& $get 'Key')
    $vmName = [string](& $get 'VMName')
    $ambiguity = [string](& $get 'Ambiguity')
    if ($key -cnotmatch '^[a-z0-9][a-z0-9-]{0,62}$' -or $vmName -cnotmatch '^[a-zA-Z0-9._-]+$') { $ambiguity = 'invalid-name' }
    $hostingMode = [string](& $get 'HostingMode')
    if ($hostingMode -notin @('vm', 'host-process', 'none', 'unknown')) { $hostingMode = if ($hostingMode) { 'unknown' } else { 'vm' } }
    $advertisedRaw = & $get 'Advertised'
    $advertised = [pscustomobject]@{ Address = ''; Port = 0; Url = ''; Origin = 'none' }
    if ($advertisedRaw) {
        $readAdvertised = {
            param([string]$Name)
            if ($advertisedRaw -is [System.Collections.IDictionary]) { $advertisedRaw[$Name] } else { $advertisedRaw.$Name }
        }
        $advertised = [pscustomobject]@{
            Address = [string](& $readAdvertised 'Address'); Port = [int](& $readAdvertised 'Port')
            Url = [string](& $readAdvertised 'Url'); Origin = if (& $readAdvertised 'Origin') { [string](& $readAdvertised 'Origin') } else { 'none' }
        }
    }
    $hostProcess = & $get 'HostProcess'
    $healthPort = 0
    [void][int]::TryParse([string](& $get 'HealthPort'), [ref]$healthPort)
    return [pscustomobject][ordered]@{
        Key                = $key
        Area               = [string](& $get 'Area')
        VMName             = $vmName
        DisplayName        = if (& $get 'DisplayName') { [string](& $get 'DisplayName') } else { $vmName }
        HealthPort         = $healthPort
        StartScript        = [string](& $get 'StartScript')
        Source             = if (& $get 'Source') { [string](& $get 'Source') } else { 'manifest' }
        VMNameSource       = if (& $get 'VMNameSource') { [string](& $get 'VMNameSource') } else { 'manifest-default' }
        HostingMode        = $hostingMode
        HostProcess        = $hostProcess
        Advertised         = $advertised
        Forwarders         = [object[]]@(& $get 'Forwarders' | Where-Object { $null -ne $_ })
        ForwardersCaptured = [bool](& $get 'ForwardersCaptured')
        Ambiguity          = $ambiguity
        IntentGeneration   = [long](& $get 'IntentGeneration')
        DesiredState       = [string](& $get 'DesiredState')
    }
}

function Get-ServiceVmStateObservation {
    <#
    .SYNOPSIS
        One VM's state through the host driver: {State; RawState; Reason;
        FromRecord}. Never throws.
    .DESCRIPTION
        The structured Get-VMStateRecord is used when the driver exports it
        (it carries the raw status word and a per-VM probe reason, and takes
        the shared deadline); otherwise Get-VMState, whose 'unknown' carries
        no reason ('unclassified'). Nothing is launched with under a second
        left on the deadline. Get-VMState takes no deadline; the drivers
        without the record answer it with one query under the driver's own
        cap, and holding it back for that whole cap would turn the usual
        millisecond answer into an unknown at the end of every wait.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        $Deadline
    )
    $emit = {
        param([string]$State, [string]$RawState, [string]$Reason, [bool]$FromRecord)
        [pscustomobject]@{ State = $State; RawState = $RawState; Reason = $Reason; FromRecord = $FromRecord }
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) { return (& $emit 'unknown' '' 'deadline-exhausted' $false) }
    $recordCommand = Get-Command -Name 'Get-VMStateRecord' -ErrorAction SilentlyContinue
    if ($recordCommand) {
        $arguments = @{ VMName = $VMName }
        if ($Deadline -and $recordCommand.Parameters.ContainsKey('Deadline')) { $arguments.Deadline = $Deadline }
        if ($Deadline -and $recordCommand.Parameters.ContainsKey('TimeoutSeconds')) {
            $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 20
            if ($null -eq $seconds) { return (& $emit 'unknown' '' 'deadline-exhausted' $false) }
            $arguments.TimeoutSeconds = [int]$seconds
        }
        try {
            $record = & $recordCommand @arguments
            $reason = [string]$record.Reason
            if (-not $reason) { $reason = if ([string]$record.State -eq 'unknown') { 'unclassified' } else { 'observed' } }
            return (& $emit ([string]$record.State) ([string]$record.RawState) $reason $true)
        } catch {
            Write-Verbose "Get-ServiceVmStateObservation('$VMName'): $($_.Exception.Message)"
            return (& $emit 'unknown' '' 'unclassified' $false)
        }
    }
    try {
        $state = [string](Get-VMState -VMName $VMName)
    } catch {
        Write-Verbose "Get-ServiceVmStateObservation('$VMName'): $($_.Exception.Message)"
        $state = 'unknown'
    }
    $reason = if ($state -eq 'unknown' -or -not $state) { 'unclassified' } else { 'observed' }
    if (-not $state) { $state = 'unknown' }
    return (& $emit $state $state $reason $false)
}

function ConvertTo-ServiceVmRereadState {
    <#
    .SYNOPSIS
        One per-VM reading (Get-ServiceVmStateObservation) as a restore row's
        state: {State; RawState; Reason}.
    .DESCRIPTION
        Used where the hypervisor probe found its app stopped and the row
        was stopped only by inference. A positive reading keeps the probe's
        reason (app-stopped), except a VM the hypervisor positively does not
        know (not-found); an unreadable one carries the read's own reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Observation,
        [AllowEmptyString()][string]$HostingMode
    )
    $raw = [string]$Observation.RawState
    $reason = [string]$Observation.Reason
    switch ([string]$Observation.State) {
        'running' { return [pscustomobject]@{ State = 'Running'; RawState = $raw; Reason = 'app-stopped' } }
        'absent' {
            $absentState = if ($HostingMode -eq 'none') { 'NotDeployed' } else { 'Absent' }
            $absentReason = if ($reason -eq 'not-found') { 'not-found' } else { 'app-stopped' }
            return [pscustomobject]@{ State = $absentState; RawState = $raw; Reason = $absentReason }
        }
        { $_ -in @('stopped', 'shutoff', 'off', 'paused', 'suspended', 'saved') } {
            $stoppedState = if ($raw.ToLowerInvariant() -in @('paused', 'suspended')) { 'Suspended' } else { 'Stopped' }
            return [pscustomobject]@{ State = $stoppedState; RawState = $raw; Reason = 'app-stopped' }
        }
    }
    if (-not $reason -or $reason -eq 'observed') { $reason = 'unclassified' }
    return [pscustomobject]@{ State = 'Unknown'; RawState = ''; Reason = $reason }
}

function Test-ServiceVmCensusReadable {
    <#
    .SYNOPSIS
        $true when a census read shows every intent there is to see: a valid
        census (an absent one included), or no private root at all.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Census)
    if ($null -eq $Census) { return $false }
    if ([bool]$Census.Valid) { return $true }
    return ([string]$Census.Reason -eq 'root-unavailable' -and [string]$Census.Detail -in $script:ServiceVmRootAbsentReason)
}

function Resolve-YurunaServiceVmPolicy {
    <#
    .SYNOPSIS
        Turn gathered service evidence into a verdict under the Preserve or
        the Repair policy. Pure: no I/O.
    .DESCRIPTION
        Preserve answers "could quitting the hypervisor now strand a running
        service?" and must never be less conservative than the installer's
        own gate (is_service_vm_running in install/macos.utm.sh): a row is
        preserved when its VM is running, paused or suspended, when its state
        could not be read, or when its advertised endpoint answered. A
        stopped reading on macOS that did not come from the structured state
        record is preserved too, since the raw status word behind it is
        unknown.

        Repair answers "may a disruptive repair proceed, and what must it
        restore?". Every managed service has to be accounted for: running
        guests are restore-required; positively stopped or suspended ones are
        left as they are unless the local operator selected them for
        restoration; an explicit stop intent is honored (intended-stopped);
        a host process is not a guest; an absent guest is not deployed. An
        unknown state becomes restore-required only on a fresh, corroborated
        census answer for the same VM name on a platform whose capability
        table allows that evidence, or by the local operator's selection;
        otherwise it is unresolved and the verdict refuses. Partial evidence
        for one service never satisfies the set, and an unexplained roster
        disagreement or an ambiguous identity refuses as well.
    .PARAMETER Evidence
        Gathered rows (see Test-YurunaServiceVmRunning).
    .PARAMETER Hypervisor
        {State; Reason; Probed; ElapsedMs} of the hypervisor probe.
    .PARAMETER UnknownMeans
        Preserve or Repair.
    .PARAMETER HostType
        host.macos.utm, host.ubuntu.kvm or host.windows.hyper-v.
    .PARAMETER Capability
        Get-YurunaServiceCensusCapability output.
    .PARAMETER RosterDisagreement
        Names present in only one of the manifest and hard-coded rosters.
    .PARAMETER CensusValid
        $false when the census could not be read.
    .PARAMETER RestoreServiceVmName
        Local operator selection: unknown or stopped guests to restore.
    .PARAMETER LeaveStoppedServiceVmName
        Local operator selection: guests to leave stopped.
    .PARAMETER AllowOperatorSelection
        Set only by the local channel; without it any selection refuses.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceVmVerdict (see Test-YurunaServiceVmRunning).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Evidence,
        [Parameter(Mandatory)][AllowNull()]$Hypervisor,
        [Parameter(Mandatory)][ValidateSet('Preserve', 'Repair')][string]$UnknownMeans,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostType,
        [Parameter(Mandatory)][AllowNull()]$Capability,
        [AllowNull()][string[]]$RosterDisagreement,
        [bool]$CensusValid = $true,
        [AllowNull()][string[]]$RestoreServiceVmName,
        [AllowNull()][string[]]$LeaveStoppedServiceVmName,
        [switch]$AllowOperatorSelection
    )
    $hypervisorRecord = [pscustomobject]@{
        State     = if ($Hypervisor) { [string]$Hypervisor.State } else { '' }
        Reason    = if ($Hypervisor) { [string]$Hypervisor.Reason } else { 'unclassified' }
        Probed    = if ($Hypervisor) { [bool]$Hypervisor.Probed } else { $false }
        ElapsedMs = if ($Hypervisor) { [long]$Hypervisor.ElapsedMs } else { [long]0 }
    }
    $usableForRepair = [bool]($Capability -and $Capability.EvidenceUsableForRepair)
    $restoreNames = @($RestoreServiceVmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
    $leaveNames = @($LeaveStoppedServiceVmName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ })
    $repair = ($UnknownMeans -eq 'Repair')
    $selectionRefusal = ''
    $selectionKeys = [System.Collections.Generic.List[string]]::new()
    if ($repair -and ($restoreNames.Count -gt 0 -or $leaveNames.Count -gt 0)) {
        $guests = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        foreach ($row in @($Evidence)) {
            if ([string]$row.HostingMode -ne 'host-process' -and [string]$row.Ambiguity -ne 'invalid-name') { $guests[[string]$row.VMName] = [string]$row.Key }
        }
        if (-not $AllowOperatorSelection) {
            $selectionRefusal = 'operator-selection-not-permitted'
        } else {
            foreach ($name in @($restoreNames + $leaveNames)) {
                if (-not $guests.ContainsKey($name)) { $selectionRefusal = 'operator-selection-invalid' }
                else { $selectionKeys.Add($guests[$name]) }
            }
            foreach ($name in $restoreNames) {
                if ($leaveNames -ccontains $name) { $selectionRefusal = 'operator-selection-invalid' }
            }
            if (@($restoreNames | Sort-Object -Unique -CaseSensitive).Count -ne $restoreNames.Count -or
                @($leaveNames | Sort-Object -Unique -CaseSensitive).Count -ne $leaveNames.Count) {
                $selectionRefusal = 'operator-selection-invalid'
            }
        }
    }
    $selectionApplies = $repair -and -not $selectionRefusal

    $services = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Evidence)) {
        $state = [string]$row.State
        $answeredService = ($row.ServiceAnswered -eq $true)
        $preserve = $false
        if ($state -in @('Running', 'Suspended', 'Unknown')) { $preserve = $true }
        if ($state -eq 'Stopped' -and $HostType -eq 'host.macos.utm' -and -not [bool]$row.StateFromRecord) { $preserve = $true }
        if ($answeredService -and $state -ne 'HostProcess') { $preserve = $true }

        $name = [string]$row.VMName
        $selectedRestore = $selectionApplies -and ($restoreNames -ccontains $name)
        $selectedLeave = $selectionApplies -and ($leaveNames -ccontains $name)
        $disposition = 'unresolved'
        $evidence = 'none'
        $ageSeconds = $null
        if ($state -eq 'HostProcess' -or [string]$row.HostingMode -eq 'host-process') {
            $disposition = 'not-a-guest'
        } elseif ([string]$row.Ambiguity) {
            $disposition = 'ambiguous'
        } elseif ([string]$row.DesiredState -eq 'stopped') {
            $disposition = 'intended-stopped'; $evidence = 'intent'
        } elseif ($selectedLeave) {
            $disposition = 'leave-stopped'; $evidence = 'operator-selection'
        } elseif ($state -eq 'Running') {
            $disposition = 'restore-required'; $evidence = 'state-probe'; $ageSeconds = 0
        } elseif ($state -in @('Suspended', 'Stopped')) {
            if ($selectedRestore) { $disposition = 'restore-required'; $evidence = 'operator-selection' }
            else { $disposition = 'leave-stopped'; $evidence = 'state-probe'; $ageSeconds = 0 }
        } elseif ($state -in @('Absent', 'NotDeployed')) {
            $disposition = 'not-deployed'; $evidence = 'state-probe'; $ageSeconds = 0
        } elseif ($selectedRestore) {
            $disposition = 'restore-required'; $evidence = 'operator-selection'
        } elseif ($repair -and $usableForRepair -and [bool]$row.CensusPositive) {
            $disposition = 'restore-required'; $evidence = 'census'; $ageSeconds = $row.CensusAgeSeconds
        }
        if ($evidence -eq 'none' -and $answeredService) { $evidence = 'service-response' }
        $services.Add([pscustomobject][ordered]@{
                Key                     = [string]$row.Key
                VMName                  = $name
                DisplayName             = [string]$row.DisplayName
                HealthPort              = [int]$row.HealthPort
                Source                  = [string]$row.Source
                VMNameSource            = [string]$row.VMNameSource
                HostingMode             = [string]$row.HostingMode
                State                   = $state
                RawState                = [string]$row.RawState
                Reason                  = [string]$row.Reason
                ServiceAnswered         = $row.ServiceAnswered
                Evidence                = $evidence
                EvidenceAgeSeconds      = $ageSeconds
                EvidenceLifetimeSeconds = [int]$row.EvidenceLifetimeSeconds
                EvidenceOrigin          = [string]$row.EvidenceOrigin
                DesiredState            = [string]$row.DesiredState
                IntentGeneration        = [long]$row.IntentGeneration
                IntentResult            = [string]$row.IntentResult
                Ambiguity               = [string]$row.Ambiguity
                CensusPositive          = [bool]$row.CensusPositive
                Preserve                = $preserve
                Disposition             = $disposition
                Identity                = $row.Identity
            })
    }

    $refusal = ''
    $refusalKeys = [System.Collections.Generic.List[string]]::new()
    if ($repair) {
        $unresolved = @($services | Where-Object { $_.Disposition -eq 'unresolved' })
        $ambiguous = @($services | Where-Object { $_.Disposition -eq 'ambiguous' })
        if ($selectionRefusal) {
            $refusal = $selectionRefusal
            foreach ($k in $selectionKeys) { if (-not $refusalKeys.Contains($k)) { $refusalKeys.Add($k) } }
        } elseif (-not $hypervisorRecord.Probed) {
            $refusal = 'hypervisor-probe-unavailable'
        } elseif (@($RosterDisagreement | Where-Object { $_ }).Count -gt 0) {
            $refusal = 'roster-disagreement'
            foreach ($s in $services) { if ($s.Source -ne 'manifest+hard-coded') { $refusalKeys.Add($s.Key) } }
        } elseif ($ambiguous.Count -gt 0) {
            $refusal = 'service-identity-ambiguous'
            foreach ($s in $ambiguous) { $refusalKeys.Add($s.Key) }
        } elseif (@($unresolved | Where-Object { $_.Reason -eq 'deadline-exhausted' }).Count -gt 0) {
            $refusal = 'deadline-exhausted'
            foreach ($s in $unresolved) { $refusalKeys.Add($s.Key) }
        } elseif (-not $CensusValid -and $unresolved.Count -gt 0) {
            $refusal = 'census-unavailable'
            foreach ($s in $unresolved) { $refusalKeys.Add($s.Key) }
        } elseif ($unresolved.Count -gt 0 -or $services.Count -eq 0) {
            $refusal = 'service-evidence-incomplete'
            foreach ($s in $unresolved) { $refusalKeys.Add($s.Key) }
        }
    }
    return [pscustomobject][ordered]@{
        PSTypeName      = 'Yuruna.ServiceVmVerdict'
        SchemaVersion   = 1
        Policy          = $UnknownMeans
        HostType        = $HostType
        Hypervisor      = $hypervisorRecord
        Preserve        = (@($services | Where-Object { $_.Preserve }).Count -gt 0)
        Satisfied       = ($refusal -eq '')
        Refusal         = $refusal
        RefusalKeys     = [string[]]$refusalKeys.ToArray()
        Services        = [object[]]$services.ToArray()
        RecoverySet     = [object[]]@($services | Where-Object { $_.Disposition -eq 'restore-required' })
        LeaveStoppedSet = [object[]]@($services | Where-Object { $_.Disposition -eq 'leave-stopped' })
        UnresolvedSet   = [object[]]@($services | Where-Object { $_.Disposition -in @('unresolved', 'ambiguous') })
    }
}

function Test-YurunaServiceVmRunning {
    <#
    .SYNOPSIS
        Gather per-service evidence and judge it under the Preserve or Repair
        policy: the one evidence interface for the reboot sweep, setup,
        refresh and the installer-parity tests.
    .DESCRIPTION
        The hypervisor is probed once (Test-VirtualizationResponsive, capped
        at twenty seconds and the shared deadline) unless the caller supplies
        a probe it already made. Per-VM state is read only when that probe is
        Responsive: a wedged or denied control channel answers 'absent',
        'stopped' or an empty listing for reasons that have nothing to do
        with the guests, so under any other probe outcome every row is
        Unknown with the probe's reason, never stopped. The one exception is
        a macOS probe that positively found no UTM process: no guest runs
        without it, so every row is Stopped. When the driver has no probe at
        all, a running reading is still taken as running, and everything
        else stays Unknown ('unclassified').

        The service probe (skipped with -NoServiceProbe) is one parallel TCP
        connect per advertised endpoint, capped at two seconds -- the same
        question the installer asks squid with `nc -G 2`.

        Census evidence, operator selections and intents are then applied by
        Resolve-YurunaServiceVmPolicy.
    .PARAMETER Identity
        Captured identity rows (Get-YurunaServiceVmIdentitySet), or the whole
        identity set. Captured custom names are used as given. Omitted: the
        identity is captured now. The whole set carries its roster
        disagreement; rows passed alone, without -RosterDisagreement, still
        carry the roster each came from, and a row that only one roster
        names is a disagreement the Repair policy refuses on.
    .PARAMETER UnknownMeans
        Preserve (default) or Repair.
    .PARAMETER HypervisorProbe
        A Test-VirtualizationResponsive record already taken by the caller.
    .PARAMETER Census
        A Read-YurunaServiceCensus result; read now when omitted.
    .PARAMETER StateRoot
        Private root for the census read.
    .PARAMETER RuntimeDir
        Runtime directory for identity capture.
    .PARAMETER HostType
        Defaults to Get-HostType when loaded.
    .PARAMETER RestoreServiceVmName
        Local operator selection (Repair, with -AllowOperatorSelection).
    .PARAMETER LeaveStoppedServiceVmName
        Local operator selection (Repair, with -AllowOperatorSelection).
    .PARAMETER AllowOperatorSelection
        Set only by the local channel.
    .PARAMETER NoServiceProbe
        Skip the service-endpoint connects.
    .PARAMETER Deadline
        Shared deadline; defaults to sixty seconds.
    .PARAMETER NowUnixMs
        Clock for evidence ages.
    .PARAMETER RosterDisagreement
        Disagreement captured with the identity rows, when rows (not the
        whole set) are passed.
    .PARAMETER EvidenceLifetimeSeconds
        Overrides the census evidence lifetime.
    .OUTPUTS
        [pscustomobject] Yuruna.ServiceVmVerdict: SchemaVersion; Policy;
        HostType; Hypervisor {State; Reason; Probed; ElapsedMs}; Preserve;
        Satisfied; Refusal; RefusalKeys; Services; RecoverySet;
        LeaveStoppedSet; UnresolvedSet. Each service row: Key, VMName,
        DisplayName, HealthPort, Source, VMNameSource, HostingMode, State
        (Running, Suspended, Stopped, Absent, Unknown, HostProcess,
        NotDeployed), RawState, Reason, ServiceAnswered, Evidence,
        EvidenceAgeSeconds, EvidenceLifetimeSeconds, EvidenceOrigin,
        DesiredState, IntentGeneration, IntentResult, Ambiguity, Preserve,
        Disposition, Identity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object[]]$Identity,
        [ValidateSet('Preserve', 'Repair')][string]$UnknownMeans = 'Preserve',
        [AllowNull()][psobject]$HypervisorProbe,
        [AllowNull()][psobject]$Census,
        [AllowEmptyString()][string]$StateRoot,
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowEmptyString()][string]$HostType,
        [AllowNull()][string[]]$RestoreServiceVmName,
        [AllowNull()][string[]]$LeaveStoppedServiceVmName,
        [switch]$AllowOperatorSelection,
        [switch]$NoServiceProbe,
        $Deadline,
        [long]$NowUnixMs,
        [AllowNull()][string[]]$RosterDisagreement,
        [ValidateRange(1, 31536000)][int]$EvidenceLifetimeSeconds
    )
    if (-not $PSBoundParameters.ContainsKey('NowUnixMs')) { $NowUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    if (-not $PSBoundParameters.ContainsKey('HostType')) {
        $HostType = ''
        $detector = Get-Command -Name 'Get-HostType' -ErrorAction SilentlyContinue
        if ($detector) { try { $HostType = [string](& $detector) } catch { $HostType = '' } }
    }
    if (-not $Deadline) { $Deadline = New-YurunaDeadline -TotalMilliseconds 60000 }
    if ($null -eq $Census) {
        $censusArguments = @{ StateRoot = $StateRoot; NowUnixMs = $NowUnixMs }
        if ($PSBoundParameters.ContainsKey('EvidenceLifetimeSeconds')) { $censusArguments.EvidenceLifetimeSeconds = $EvidenceLifetimeSeconds }
        $Census = Read-YurunaServiceCensus @censusArguments
    }
    $disagreement = @($RosterDisagreement | Where-Object { $_ })
    $rows = [System.Collections.Generic.List[object]]::new()
    $identityInput = @($Identity | Where-Object { $null -ne $_ })
    if (-not $PSBoundParameters.ContainsKey('Identity')) {
        $set = Get-YurunaServiceVmIdentitySet -RuntimeDir $RuntimeDir -Census $Census -StateRoot $StateRoot -HostType $HostType -NowUnixMs $NowUnixMs
        $identityInput = @($set.Rows)
        $disagreement = @($set.RosterDisagreement)
    } elseif ($identityInput.Count -eq 1 -and $identityInput[0].PSObject.Properties['Rows'] -and $identityInput[0].PSObject.Properties['RosterDisagreement']) {
        $disagreement = @($identityInput[0].RosterDisagreement | Where-Object { $_ })
        $identityInput = @($identityInput[0].Rows)
    } elseif (-not $PSBoundParameters.ContainsKey('RosterDisagreement')) {
        # Only a source the capture recorded counts: a row with none gets the
        # manifest default when normalized, which says nothing about the
        # hard-coded list. The labels match the capture's own.
        foreach ($candidate in $identityInput) {
            $capturedSource = if ($candidate -is [System.Collections.IDictionary]) { [string]$candidate['Source'] }
                              elseif ($candidate.PSObject.Properties['Source']) { [string]$candidate.Source } else { '' }
            $capturedName = if ($candidate -is [System.Collections.IDictionary]) { [string]$candidate['VMName'] } else { [string]$candidate.VMName }
            if ($capturedSource -ceq 'manifest') { $disagreement += "manifest-only:$capturedName" }
            elseif ($capturedSource -ceq 'hard-coded') { $disagreement += "hard-coded-only:$capturedName" }
        }
    }
    foreach ($candidate in $identityInput) { $rows.Add((ConvertTo-ServiceVmIdentityRow -Row $candidate)) }

    $hypervisor = [ordered]@{ State = ''; Reason = 'unclassified'; Probed = $false; ElapsedMs = [long]0 }
    if ($HypervisorProbe) {
        $hypervisor.State = [string]$HypervisorProbe.state
        $hypervisor.Reason = [string]$HypervisorProbe.reason
        $hypervisor.Probed = $true
        $hypervisor.ElapsedMs = [long]$HypervisorProbe.elapsedMs
    } else {
        $probeCommand = Get-Command -Name 'Test-VirtualizationResponsive' -ErrorAction SilentlyContinue
        if ($probeCommand) {
            $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 20
            if ($null -eq $seconds) {
                $hypervisor.State = 'Undetermined'
                $hypervisor.Reason = 'deadline-exhausted'
            } else {
                $probeArguments = @{ TimeoutSeconds = [int]$seconds }
                if ($probeCommand.Parameters.ContainsKey('Deadline')) { $probeArguments.Deadline = $Deadline }
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $probe = & $probeCommand @probeArguments
                    $hypervisor.State = [string]$probe.state
                    $hypervisor.Reason = [string]$probe.reason
                } catch {
                    Write-Verbose "Test-YurunaServiceVmRunning: hypervisor probe: $($_.Exception.Message)"
                    $hypervisor.State = 'Undetermined'
                    $hypervisor.Reason = 'invalid-response'
                }
                $hypervisor.Probed = $true
                $hypervisor.ElapsedMs = $stopwatch.ElapsedMilliseconds
            }
        }
    }
    $responsive = ($hypervisor.Probed -and $hypervisor.State -eq 'Responsive')
    $appStopped = ($hypervisor.Probed -and $hypervisor.State -eq 'Unresponsive' -and $hypervisor.Reason -eq 'app-stopped' -and $HostType -eq 'host.macos.utm')
    $canState = [bool](Get-Command -Name 'Get-VMState' -ErrorAction SilentlyContinue) -or [bool](Get-Command -Name 'Get-VMStateRecord' -ErrorAction SilentlyContinue)

    $answered = @{}
    if (-not $NoServiceProbe) {
        $targets = @($rows | Where-Object { $_.Advertised.Address -and $_.Advertised.Port -gt 0 } | ForEach-Object {
                [pscustomobject]@{ Id = $_.Key; Address = $_.Advertised.Address; Port = $_.Advertised.Port } })
        if ($targets.Count -gt 0) {
            $cap = [int][Math]::Min([long]2000, (Get-YurunaDeadlineRemainingMs -Deadline $Deadline))
            $answered = Test-ServiceVmEndpointSet -Target $targets -TimeoutMilliseconds $cap
        }
    }

    $lifetime = [int]$Census.EvidenceLifetimeSeconds
    $evidence = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $observation = $null
        if ($row.HostingMode -eq 'host-process') {
            $observation = [pscustomobject]@{ State = 'HostProcess'; RawState = ''; Reason = $(if ($hypervisor.Probed) { $hypervisor.Reason } else { 'unclassified' }); FromRecord = $false }
        } elseif ($row.Ambiguity -eq 'invalid-name') {
            $observation = [pscustomobject]@{ State = 'Unknown'; RawState = ''; Reason = 'unclassified'; FromRecord = $false }
        } elseif ($appStopped) {
            $observation = [pscustomobject]@{ State = 'Stopped'; RawState = ''; Reason = 'app-stopped'; FromRecord = $true }
        } elseif ($hypervisor.Probed -and -not $responsive) {
            $observation = [pscustomobject]@{ State = 'Unknown'; RawState = ''; Reason = $hypervisor.Reason; FromRecord = $false }
        } elseif (-not $hypervisor.Probed -and $hypervisor.Reason -eq 'deadline-exhausted') {
            $observation = [pscustomobject]@{ State = 'Unknown'; RawState = ''; Reason = 'deadline-exhausted'; FromRecord = $false }
        } elseif (-not $canState) {
            $observation = [pscustomobject]@{ State = 'Unknown'; RawState = ''; Reason = 'not-probed'; FromRecord = $false }
        } else {
            $read = Get-ServiceVmStateObservation -VMName $row.VMName -Deadline $Deadline
            $raw = ([string]$read.RawState).ToLowerInvariant()
            $mapped = 'Unknown'
            $reason = [string]$read.Reason
            switch ([string]$read.State) {
                'running' { $mapped = 'Running' }
                'absent'  { $mapped = 'Absent' }
                { $_ -in @('stopped', 'shutoff', 'off', 'paused', 'suspended', 'saved') } {
                    $mapped = if ($raw -in @('paused', 'suspended')) { 'Suspended' } else { 'Stopped' }
                }
            }
            if (-not $responsive -and $mapped -in @('Stopped', 'Absent')) {
                # Without a probe that answered, 'stopped' and 'absent' are
                # exactly what a denied or wedged control channel reports.
                $mapped = 'Unknown'
                $reason = 'unclassified'
            }
            if ($mapped -ne 'Unknown' -and $responsive) {
                $reason = if ([string]$read.Reason -eq 'not-found') { 'not-found' } else { 'responsive' }
            } elseif ($mapped -ne 'Unknown') {
                $reason = 'unclassified'
            } elseif (-not $reason -or $reason -eq 'observed') {
                $reason = 'unclassified'
            }
            if ($mapped -eq 'Absent' -and $row.HostingMode -eq 'none') { $mapped = 'NotDeployed' }
            $observation = [pscustomobject]@{ State = $mapped; RawState = [string]$read.RawState; Reason = $reason; FromRecord = [bool]$read.FromRecord }
        }

        $record = if ($Census.Services -and $Census.Services.ContainsKey($row.Key)) { $Census.Services[$row.Key] } else { $null }
        $desired = if ($record) { [string]$record.desiredState } else { [string]$row.DesiredState }
        $generation = if ($record) { [long]$record.intentGeneration } else { [long]$row.IntentGeneration }
        $intentResult = if ($record -and $record.intent) { [string]$record.intent.result } else { '' }
        $censusPositive = [bool]($record -and $record.evidenceFresh -and [string]$record.lastAnsweredIdentity -eq 'mac-corroborated' -and
            [string]$record.vmName -ceq [string]$row.VMName)
        $evidence.Add([pscustomobject]@{
                Key                     = $row.Key
                VMName                  = $row.VMName
                DisplayName             = $row.DisplayName
                HealthPort              = $row.HealthPort
                Source                  = $row.Source
                VMNameSource            = $row.VMNameSource
                HostingMode             = $row.HostingMode
                Ambiguity               = $row.Ambiguity
                State                   = $observation.State
                RawState                = $observation.RawState
                Reason                  = $observation.Reason
                StateFromRecord         = [bool]$observation.FromRecord
                ServiceAnswered         = if ($answered.ContainsKey($row.Key)) { [bool]$answered[$row.Key] } else { $null }
                CensusPositive          = $censusPositive
                CensusAgeSeconds        = if ($record) { $record.evidenceAgeSeconds } else { $null }
                EvidenceLifetimeSeconds = $lifetime
                EvidenceOrigin          = [string]$Census.EvidenceLifetimeOrigin
                DesiredState            = $desired
                IntentGeneration        = $generation
                IntentResult            = $intentResult
                Identity                = $row
            })
    }
    $policyArguments = @{
        Evidence                  = $evidence.ToArray()
        Hypervisor                = [pscustomobject]$hypervisor
        UnknownMeans              = $UnknownMeans
        HostType                  = $HostType
        Capability                = (Get-YurunaServiceCensusCapability -HostType $HostType)
        RosterDisagreement        = [string[]]$disagreement
        CensusValid               = [bool]$Census.Valid
        RestoreServiceVmName      = $RestoreServiceVmName
        LeaveStoppedServiceVmName = $LeaveStoppedServiceVmName
        AllowOperatorSelection    = $AllowOperatorSelection
    }
    return Resolve-YurunaServiceVmPolicy @policyArguments
}

function Get-ServiceVmRestoreRow {
    <#
    .SYNOPSIS
        The rows a restore pass works on: the captured identity rows when
        given, else the manifest roster (the reboot sweep's cheap default),
        else -- for an observe-only pass -- the identity captured now, so the
        endpoint it advertises can be checked.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][string[]]$Key,
        [AllowNull()][object[]]$Identity,
        [bool]$IdentityGiven,
        [bool]$ObserveOnly,
        [AllowEmptyString()][string]$RuntimeDir,
        [AllowNull()]$Census,
        [AllowEmptyString()][string]$StateRoot
    )
    $wanted = @($Key | Where-Object { $_ } | ForEach-Object { "$_".Trim() })
    $source = @()
    if ($IdentityGiven) {
        $source = @($Identity | Where-Object { $null -ne $_ })
        if ($source.Count -eq 1 -and $source[0].PSObject.Properties['Rows'] -and $source[0].PSObject.Properties['RosterDisagreement']) { $source = @($source[0].Rows) }
    } elseif ($ObserveOnly) {
        $source = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $RuntimeDir -Census $Census -StateRoot $StateRoot).Rows)
    } else {
        $source = @(Get-YurunaServiceVmRoster -Key $wanted | ForEach-Object {
                [pscustomobject]@{
                    Key = $_.Key; VMName = $_.VMName; DisplayName = $_.DisplayName; HealthPort = $_.HealthPort
                    StartScript = $_.StartScript; HostingMode = 'vm'; Source = 'manifest'; VMNameSource = 'manifest-default'
                }
            })
    }
    foreach ($candidate in $source) {
        $row = ConvertTo-ServiceVmIdentityRow -Row $candidate
        if ($wanted.Count -gt 0 -and $wanted -notcontains $row.Key) { continue }
        $row
    }
}

function New-ServiceVmRestoreRecord {
    <#
    .SYNOPSIS
        One Restore-YurunaServiceVM record with every field present.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$Outcome,
        [AllowEmptyString()][string]$StateBefore = 'unknown',
        [bool]$Healthy = $false,
        [AllowEmptyString()][string]$Message = '',
        [AllowEmptyString()][string]$ProbeReason = 'unclassified',
        [AllowEmptyString()][string]$HypervisorState = '',
        [AllowEmptyString()][string]$DesiredState = '',
        [long]$IntentGeneration = 0,
        [AllowEmptyString()][string]$Address = '',
        [AllowEmptyString()][string]$ConsumerEndpoint = '',
        [AllowEmptyString()][string]$ConsumerEndpointState = 'not-checked',
        [AllowEmptyString()][string]$Obligation = 'none',
        [long]$ElapsedMs = 0
    )
    return [pscustomobject][ordered]@{
        Key                   = [string]$Row.Key
        VMName                = [string]$Row.VMName
        DisplayName           = [string]$Row.DisplayName
        StateBefore           = $StateBefore
        Outcome               = $Outcome
        Healthy               = $Healthy
        Message               = $Message
        ProbeReason           = $ProbeReason
        HypervisorState       = $HypervisorState
        DesiredState          = $DesiredState
        IntentGeneration      = $IntentGeneration
        HostingMode           = [string]$Row.HostingMode
        Address               = $Address
        ConsumerEndpoint      = $ConsumerEndpoint
        ConsumerEndpointState = $ConsumerEndpointState
        Obligation            = $Obligation
        ElapsedMs             = $ElapsedMs
    }
}

function Wait-ServiceVmHealth {
    <#
    .SYNOPSIS
        Resolve a running guest's address and wait for its health port, both
        bounded by one deadline: {Address; Healthy}.
    .DESCRIPTION
        A guest that was just resumed may take a while to lease an address
        and reopen its listener, so both are retried on a three-second poll;
        the whole wait never outlives the deadline it is given, and the
        connect cap shrinks with it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$HealthPort,
        [Parameter(Mandatory)]$Deadline,
        [Parameter(Mandatory)][scriptblock]$Sleep,
        [switch]$Once
    )
    $address = ''
    $healthy = $false
    while ($true) {
        if (-not $address -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -gt 0) {
            $address = Get-YurunaServiceVmAddress -VMName $VMName -Deadline $Deadline
        }
        if ($address) {
            $cap = [int][Math]::Min([long]$script:ServiceVmProbeTimeoutMs, (Get-YurunaDeadlineRemainingMs -Deadline $Deadline))
            if ($cap -gt 0 -and (Test-YurunaServiceVmPort -Address $address -Port $HealthPort -TimeoutMs $cap)) { $healthy = $true; break }
        }
        if ($Once) { break }
        if (-not (Wait-YurunaDeadlineInterval -Deadline $Deadline -Milliseconds 3000 -Sleep $Sleep)) { break }
    }
    return [pscustomobject]@{ Address = $address; Healthy = $healthy }
}

function Test-ServiceVmConsumerEndpoint {
    <#
    .SYNOPSIS
        Whether the endpoint a service advertises reaches the guest that just
        answered: {State; Obligation; Endpoint}.
    .DESCRIPTION
        A guest re-leased after a relaunch can answer on its new address
        while every consumer still dials the advertised one. An advertised
        address that is neither the guest's fresh address nor explained by a
        captured forwarder pointing at it is stale, whatever answers there:
        a TCP answer from an old forwarder or another machine is not the
        service. Where the advertised address is this host's own and no
        forwarder table was captured, or the forwarder on the advertised
        port could not be tied to its owner, the mapping cannot be checked:
        an unverified forwarder may well be the one that points at the
        guest. Nothing is re-pointed here; a stale advertisement is reported
        as an obligation for the operator.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Row,
        [AllowEmptyString()][string]$FreshAddress,
        [Parameter(Mandatory)]$Deadline
    )
    $advertised = $Row.Advertised
    if (-not $advertised -or -not $advertised.Address) {
        return [pscustomobject]@{ State = 'not-advertised'; Obligation = 'none'; Endpoint = '' }
    }
    $port = if ([int]$advertised.Port -gt 0) { [int]$advertised.Port } else { [int]$Row.HealthPort }
    $endpoint = "$($advertised.Address):$port"
    $checkDeadline = $Deadline
    $answers = {
        $cap = [int][Math]::Min([long]$script:ServiceVmProbeTimeoutMs, (Get-YurunaDeadlineRemainingMs -Deadline $checkDeadline))
        ($cap -gt 0) -and (Test-YurunaServiceVmPort -Address ([string]$advertised.Address) -Port $port -TimeoutMs $cap)
    }
    $forwarder = @($Row.Forwarders | Where-Object { $null -ne $_ -and [int]$_.HostPort -eq $port -and [bool]$_.OwnerVerified }) | Select-Object -First 1
    if ($forwarder) {
        if ($forwarder.TargetAddress -and $FreshAddress -and [string]$forwarder.TargetAddress -ne $FreshAddress) {
            return [pscustomobject]@{ State = 'stale-advertisement'; Obligation = 'endpoint-repoint-required'; Endpoint = $endpoint }
        }
        if (& $answers) { return [pscustomobject]@{ State = 'verified'; Obligation = 'none'; Endpoint = $endpoint } }
        return [pscustomobject]@{ State = 'unanswered'; Obligation = 'endpoint-unverified'; Endpoint = $endpoint }
    }
    if ($FreshAddress -and [string]$advertised.Address -eq $FreshAddress) {
        if (& $answers) { return [pscustomobject]@{ State = 'verified'; Obligation = 'none'; Endpoint = $endpoint } }
        return [pscustomobject]@{ State = 'unanswered'; Obligation = 'endpoint-unverified'; Endpoint = $endpoint }
    }
    $hostOwn = $false
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse([string]$advertised.Address, [ref]$parsed)) {
        if ([System.Net.IPAddress]::IsLoopback($parsed)) { $hostOwn = $true }
        else {
            try {
                foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                    foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                        if ($unicast.Address.Equals($parsed)) { $hostOwn = $true }
                    }
                }
            } catch { Write-Verbose "Test-ServiceVmConsumerEndpoint: interface list unreadable: $($_.Exception.Message)" }
        }
    }
    if ($hostOwn) {
        $unverified = @($Row.Forwarders | Where-Object { $null -ne $_ -and [int]$_.HostPort -eq $port -and -not [bool]$_.OwnerVerified })
        if (-not [bool]$Row.ForwardersCaptured -or $unverified.Count -gt 0) {
            return [pscustomobject]@{ State = 'not-checked'; Obligation = 'endpoint-unverified'; Endpoint = $endpoint }
        }
    }
    return [pscustomobject]@{ State = 'stale-advertisement'; Obligation = 'endpoint-repoint-required'; Endpoint = $endpoint }
}

function Restore-YurunaServiceVM {
    <#
    .SYNOPSIS
        Start any service VM that is registered with the hypervisor but not
        running, and report what happened. Returns one record per service.
        Never throws; never rebuilds.
    .DESCRIPTION
        The reboot self-heal. Cheap on a healthy host -- one hypervisor probe
        and one state query per service -- so it is safe to call at every
        cycle start rather than only at boot, which also covers a service that
        died or was stopped mid-session.

        'absent' is NOT a failure and never triggers anything. A standalone host
        legitimately runs no stash service, and a host that never built the
        pool-control service must not have one conjured for it: absent means "not
        this host's job", and only a REGISTERED-but-stopped VM is something this
        host owns and failed to start.

        State comes from Test-YurunaServiceVmRunning under the Preserve policy.
        A service whose state could not be read is reported as state-unknown
        with the probe's reason and is never started: a denied or timed-out
        probe is not a registered-and-stopped VM, and starting from it would
        retry a wedged hypervisor on every cycle. When the probe found the
        hypervisor app itself stopped, every guest reads as stopped, so each
        one is read on its own before anything is started: absent stays
        absent. A service stopped by an explicit Stop request is
        intended-stopped, a host-process deployment is not-a-guest, and
        neither is ever started. A start takes that service's operation lock
        first (or validates the caller's), so it cannot race a Start or Stop
        script; a lock that cannot be taken for any reason other than another
        holder is lock-unavailable, and a census that cannot be read under
        the lock is state-unknown, since either may hide a stop request.

        Every wait is bounded by the shared deadline as well as its own cap.
        The health wait is best-effort and deliberately non-authoritative. A
        freshly resumed guest can take a while to re-open its listener, and the
        real gates (the caching-proxy probe, the stash pre-flight) run
        afterwards and own the verdict. Reporting a slow starter as failed here
        would only produce a scary line for a service that comes up seconds later.
    .PARAMETER Key
        Restrict to these roster keys. Default: every service.
    .PARAMETER Identity
        Captured identity rows to work on instead of the manifest roster;
        custom VM names are used as captured, never re-resolved by key.
    .PARAMETER StartTimeoutSeconds
        Budget for the VM to reach 'running' after Start-VM.
    .PARAMETER HealthTimeoutSeconds
        Additional budget for the service port to answer once the VM is running.
        0 skips the health wait entirely.
    .PARAMETER ProbeRunning
        Also probe the health port of a VM that was ALREADY running, and report
        Healthy from what answered.

        Off by default, and that default is what keeps the per-cycle sweep the
        cheap thing it is: on a healthy host it stays one state query per
        service, and the sweep's only job is to START what is off -- a VM that
        is already on is nothing for it to do either way.

        A caller deciding whether to REUSE that VM is asking a different
        question, and powered-on is not an answer to it. A bring-up that fails
        deliberately leaves its guest running so the evidence survives, so
        'running' is exactly the state a broken service is found in. Switching
        the probe on here rather than writing a second one at the call site is
        what keeps one definition of "this service is usable".
    .PARAMETER ObserveOnly
        Never starts anything. Implies -ProbeRunning. A host-refresh
        convergence check calls this after Resume-YurunaServiceVM has already
        done the one authorized start: it waits (bounded) for each guest to
        report running, lease an address and answer its health port, then
        checks that the advertised endpoint still reaches it.
    .PARAMETER Deadline
        Shared deadline for the whole pass.
    .PARAMETER HypervisorProbe
        A Test-VirtualizationResponsive record the caller already took.
    .PARAMETER OperationLock
        A Yuruna.ServiceOperationLockSet the caller holds; a start then runs
        only for keys it covers (operation-unowned otherwise).
    .PARAMETER StateRoot
        Private root for the census and the operation locks.
    .PARAMETER Census
        A Read-YurunaServiceCensus result to use instead of reading it.
    .PARAMETER RuntimeDir
        Runtime directory for identity capture.
    .PARAMETER ClockTicks
        Injected monotonic clock for the default deadline (tests).
    .PARAMETER SleepMilliseconds
        Injected sleeper taking milliseconds (tests).
    .OUTPUTS
        pscustomobject[] -- Key, VMName, DisplayName, StateBefore, Outcome,
        Healthy, Message, ProbeReason, HypervisorState, DesiredState,
        IntentGeneration, HostingMode, Address, ConsumerEndpoint,
        ConsumerEndpointState (verified, stale-advertisement, unanswered,
        not-advertised, not-checked), Obligation (none, state-unresolved,
        health-unverified, endpoint-repoint-required, endpoint-unverified),
        ElapsedMs. Outcome is one of: no-host-driver, absent, state-unknown,
        intended-stopped, not-a-guest, operation-busy, operation-unowned,
        lock-unavailable, deadline-exhausted, running, started, start-failed,
        start-timeout, or (only under -ObserveOnly) stopped.

        ProbeReason is 'responsive' for a state positively recognized in a
        responsive pass, the structured reason for state-unknown,
        'not-probed' for no-host-driver and 'unclassified' when the driver
        has no probe. Only 'timeout' is fault evidence for the automatic
        refresh trigger.

        Healthy on a 'running' record means "answered its health port" only when
        -ProbeRunning was passed; without it the port was not asked.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [string[]]$Key,
        [AllowNull()][object[]]$Identity,
        [int]$StartTimeoutSeconds  = 120,
        [int]$HealthTimeoutSeconds = 90,
        [switch]$ProbeRunning,
        [switch]$ObserveOnly,
        $Deadline,
        [AllowNull()][psobject]$HypervisorProbe,
        [AllowNull()][psobject]$OperationLock,
        [AllowEmptyString()][string]$StateRoot,
        [AllowNull()][psobject]$Census,
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [scriptblock]$ClockTicks,
        [scriptblock]$SleepMilliseconds
    )
    if ($ObserveOnly) { $ProbeRunning = $true }
    $startSeconds = [Math]::Max(1, $StartTimeoutSeconds)
    $healthSeconds = [Math]::Max(0, $HealthTimeoutSeconds)
    $sleep = if ($SleepMilliseconds) { $SleepMilliseconds } else { { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds } }
    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    # Resolved by name at call time: this module is imported by the entry-point
    # module set, which loads BEFORE Initialize-YurunaHost brings in the per-host
    # driver. Binding at import would leave every caller with a permanent no-op.
    $canState = [bool](Get-Command Get-VMState -ErrorAction SilentlyContinue)
    $canStart = [bool](Get-Command Start-VM   -ErrorAction SilentlyContinue)
    if (-not $canState -or (-not $canStart -and -not $ObserveOnly)) {
        $rosterRows = @(Get-ServiceVmRestoreRow -Key $Key -Identity $Identity -IdentityGiven:$PSBoundParameters.ContainsKey('Identity') `
                -ObserveOnly:$false -RuntimeDir $RuntimeDir -Census $null -StateRoot $StateRoot)
        foreach ($row in $rosterRows) {
            $results.Add((New-ServiceVmRestoreRecord -Row $row -Outcome 'no-host-driver' -StateBefore 'unknown' -ProbeReason 'not-probed' `
                        -Obligation 'state-unresolved' -Message (Format-YurunaOperatorMessage -Key 'runner.operator_6ce1157be9fb6a1c')))
        }
        return $results.ToArray()
    }

    if (-not $Deadline) {
        $perService = [long](($startSeconds + $healthSeconds) * 1000)
        $budget = [long]60000 + ($perService * 4)
        $deadlineArguments = @{ TotalMilliseconds = $budget }
        if ($ClockTicks) { $deadlineArguments.ClockTicks = $ClockTicks }
        $Deadline = New-YurunaDeadline @deadlineArguments
    }
    if ($null -eq $Census) { $Census = Read-YurunaServiceCensus -StateRoot $StateRoot }
    $rows = @(Get-ServiceVmRestoreRow -Key $Key -Identity $Identity -IdentityGiven:$PSBoundParameters.ContainsKey('Identity') `
            -ObserveOnly:([bool]$ObserveOnly) -RuntimeDir $RuntimeDir -Census $Census -StateRoot $StateRoot)
    if ($rows.Count -eq 0) { return $results.ToArray() }
    if (Test-YurunaDeadlineExpired -Deadline $Deadline) {
        foreach ($row in $rows) {
            $results.Add((New-ServiceVmRestoreRecord -Row $row -Outcome 'deadline-exhausted' -ProbeReason 'deadline-exhausted' -Obligation 'state-unresolved' `
                        -Message (Format-YurunaOperatorMessage -Key 'runner.service_restore_deadline_exhausted')))
        }
        return $results.ToArray()
    }

    $verdictArguments = @{
        Identity = $rows; UnknownMeans = 'Preserve'; NoServiceProbe = $true; Census = $Census
        StateRoot = $StateRoot; RuntimeDir = $RuntimeDir; Deadline = $Deadline
    }
    if ($HypervisorProbe) { $verdictArguments.HypervisorProbe = $HypervisorProbe }
    $verdict = Test-YurunaServiceVmRunning @verdictArguments
    $hypervisorState = [string]$verdict.Hypervisor.State

    foreach ($svc in @($verdict.Services)) {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $row = $svc.Identity
        $state = [string]$svc.State
        $rawState = [string]$svc.RawState
        $rowReason = [string]$svc.Reason
        if ($rowReason -eq 'app-stopped' -and $state -in @('Stopped', 'Suspended') -and [string]$svc.DesiredState -ne 'stopped' -and
            -not $svc.Ambiguity -and -not (Test-YurunaDeadlineExpired -Deadline $Deadline)) {
            # With the hypervisor app down every guest reads as stopped,
            # including one this host never built. Only this VM's own answer
            # tells a registered-and-stopped guest from an absent one, and
            # absent must never become a start. On macOS this read launches
            # UTM, which the start it may lead to would do anyway.
            $reread = ConvertTo-ServiceVmRereadState -Observation (Get-ServiceVmStateObservation -VMName $row.VMName -Deadline $Deadline) -HostingMode ([string]$row.HostingMode)
            $state = $reread.State
            $rawState = $reread.RawState
            $rowReason = $reread.Reason
        }
        $stateBefore = if ($rawState) { $rawState.ToLowerInvariant() } else { $state.ToLowerInvariant() }
        if ($state -eq 'Unknown') { $stateBefore = 'unknown' }
        $probeReason = if (-not $verdict.Hypervisor.Probed) { $rowReason }
                       elseif ($state -eq 'Unknown') { $rowReason }
                       elseif ($verdict.Hypervisor.State -eq 'Responsive') { 'responsive' }
                       elseif ($rowReason -eq 'not-found') { 'not-found' }
                       else { [string]$verdict.Hypervisor.Reason }
        $common = @{
            Row = $row; StateBefore = $stateBefore; ProbeReason = $probeReason; HypervisorState = $hypervisorState
            DesiredState = [string]$svc.DesiredState; IntentGeneration = [long]$svc.IntentGeneration
        }
        $emit = {
            param([hashtable]$Fields)
            $all = @{}
            foreach ($k in $common.Keys) { $all[$k] = $common[$k] }
            foreach ($k in $Fields.Keys) { $all[$k] = $Fields[$k] }
            $all.ElapsedMs = $stopwatch.ElapsedMilliseconds
            $results.Add((New-ServiceVmRestoreRecord @all))
        }

        if (Test-YurunaDeadlineExpired -Deadline $Deadline) {
            & $emit @{ Outcome = 'deadline-exhausted'; Obligation = 'state-unresolved'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_deadline_exhausted') }
            continue
        }
        if ($state -eq 'HostProcess') {
            $processId = if ($row.HostProcess -and $row.HostProcess.Pid) { [string]$row.HostProcess.Pid } else { '0' }
            & $emit @{ Outcome = 'not-a-guest'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_not_a_guest' -Arguments @{ pid = $processId }) }
            continue
        }
        if ($state -in @('Absent', 'NotDeployed')) {
            $absentObligation = if ($ObserveOnly) { 'state-unresolved' } else { 'none' }
            & $emit @{ Outcome = 'absent'; Obligation = $absentObligation; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_55110b53e7e30cf1') }
            continue
        }
        if ($state -eq 'Unknown') {
            $unknownMessage = if ($svc.Ambiguity) {
                Format-YurunaOperatorMessage -Key 'runner.service_restore_identity_ambiguous' -Arguments @{ ambiguity = [string]$svc.Ambiguity }
            } else { Format-YurunaOperatorMessage -Key 'runner.operator_5485e11b651f9377' }
            & $emit @{ Outcome = 'state-unknown'; Obligation = 'state-unresolved'; Message = $unknownMessage }
            continue
        }
        if ($state -eq 'Running') {
            $healthy = $true
            $address = ''
            $message = (Format-YurunaOperatorMessage -Key 'runner.operator_dea2daf647b24f47')
            $obligation = 'none'
            $endpointState = 'not-checked'
            $endpoint = ''
            if ($ProbeRunning) {
                # The sweep asks once: a VM that is already up has had all the
                # time it is going to get. An observe-only pass follows a
                # resume, so it waits (bounded) for a listener to reopen.
                $healthWindowMs = if ($ObserveOnly) { [long]$healthSeconds * 1000 } else { [long]5000 }
                $healthDeadline = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds $healthWindowMs
                $health = Wait-ServiceVmHealth -VMName $row.VMName -HealthPort $row.HealthPort -Deadline $healthDeadline -Sleep $sleep -Once:(-not $ObserveOnly)
                $address = [string]$health.Address
                $healthy = [bool]$health.Healthy
                if (-not $address) {
                    $message = if ($ObserveOnly) { Format-YurunaOperatorMessage -Key 'runner.service_restore_no_address' }
                               else { Format-YurunaOperatorMessage -Key 'runner.operator_572d9bbb6abf31cf' -Arguments @{ healthPort = [string]($row.HealthPort) } }
                    $obligation = 'health-unverified'
                } elseif ($healthy) {
                    $message = (Format-YurunaOperatorMessage -Key 'runner.operator_5cf6a67db15856c2' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address" })
                } else {
                    $message = if ($ObserveOnly) {
                        Format-YurunaOperatorMessage -Key 'runner.service_restore_health_unverified' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address"; seconds = "$healthSeconds" }
                    } else { Format-YurunaOperatorMessage -Key 'runner.operator_89c43538cc813c4a' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address" } }
                    $obligation = 'health-unverified'
                }
                if ($ObserveOnly -and $healthy) {
                    $check = Test-ServiceVmConsumerEndpoint -Row $row -FreshAddress $address -Deadline $Deadline
                    $endpointState = $check.State
                    $endpoint = $check.Endpoint
                    $obligation = $check.Obligation
                    if ($check.State -eq 'stale-advertisement') {
                        $message = Format-YurunaOperatorMessage -Key 'runner.service_restore_endpoint_stale' -Arguments @{ address = "$address"; advertised = "$endpoint" }
                    } elseif ($check.State -eq 'unanswered') {
                        $message = Format-YurunaOperatorMessage -Key 'runner.service_restore_endpoint_unanswered' -Arguments @{ address = "$address"; advertised = "$endpoint" }
                    }
                }
            }
            & $emit @{ Outcome = 'running'; Healthy = $healthy; Message = $message; Address = $address; Obligation = $obligation
                ConsumerEndpoint = $endpoint; ConsumerEndpointState = $endpointState }
            continue
        }
        # Positively stopped or suspended from here on.
        if ([string]$svc.DesiredState -eq 'stopped') {
            & $emit @{ Outcome = 'intended-stopped'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_intended_stopped' -Arguments @{ operation = 'stop' }) }
            continue
        }
        if ($svc.Ambiguity) {
            & $emit @{ Outcome = 'state-unknown'; Obligation = 'state-unresolved'
                Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_identity_ambiguous' -Arguments @{ ambiguity = [string]$svc.Ambiguity }) }
            continue
        }
        if ($ObserveOnly) {
            # Never Start-VM here: the one authorized start already happened.
            # A guest still coming up is given the health window to report
            # running, lease an address and answer.
            $observeDeadline = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds ([long]$healthSeconds * 1000)
            $nowRunning = $false
            while (Wait-YurunaDeadlineInterval -Deadline $observeDeadline -Milliseconds 3000 -Sleep $sleep) {
                $seen = Get-ServiceVmStateObservation -VMName $row.VMName -Deadline $observeDeadline
                if ($seen.State -eq 'running') { $nowRunning = $true; break }
            }
            if (-not $nowRunning) {
                & $emit @{ Outcome = 'stopped'; Obligation = 'health-unverified'
                    Message = (Format-YurunaOperatorMessage -Key 'runner.operator_1fa3b2464af15be3' -Arguments @{ state = "$stateBefore" }) }
                continue
            }
            $health = Wait-ServiceVmHealth -VMName $row.VMName -HealthPort $row.HealthPort -Deadline $observeDeadline -Sleep $sleep
            $address = [string]$health.Address
            if (-not $address) {
                & $emit @{ Outcome = 'running'; Obligation = 'health-unverified'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_no_address') }
                continue
            }
            if (-not $health.Healthy) {
                & $emit @{ Outcome = 'running'; Obligation = 'health-unverified'; Address = $address
                    Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_health_unverified' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address"; seconds = "$healthSeconds" }) }
                continue
            }
            $check = Test-ServiceVmConsumerEndpoint -Row $row -FreshAddress $address -Deadline $Deadline
            $message = (Format-YurunaOperatorMessage -Key 'runner.operator_5cf6a67db15856c2' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address" })
            if ($check.State -eq 'stale-advertisement') {
                $message = Format-YurunaOperatorMessage -Key 'runner.service_restore_endpoint_stale' -Arguments @{ address = "$address"; advertised = "$($check.Endpoint)" }
            } elseif ($check.State -eq 'unanswered') {
                $message = Format-YurunaOperatorMessage -Key 'runner.service_restore_endpoint_unanswered' -Arguments @{ address = "$address"; advertised = "$($check.Endpoint)" }
            }
            & $emit @{ Outcome = 'running'; Healthy = $true; Address = $address; Message = $message; Obligation = $check.Obligation
                ConsumerEndpoint = $check.Endpoint; ConsumerEndpointState = $check.State }
            continue
        }

        # Registered and not running: ours, and off. This is the reboot case.
        if (-not $PSCmdlet.ShouldProcess($row.VMName, (Format-YurunaOperatorMessage -Key 'runner.operator_e68cd14ab99489c3' -Arguments @{ displayName = "$($row.DisplayName)" }))) {
            & $emit @{ Outcome = 'start-failed'; Message = 'WhatIf'; Obligation = 'health-unverified' }
            continue
        }
        $ownedLock = $null
        if ($OperationLock) {
            if (-not (Test-YurunaServiceOperationLockContext -Context $OperationLock -Key $row.Key)) {
                & $emit @{ Outcome = 'operation-unowned'; Obligation = 'state-unresolved'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_operation_unowned') }
                continue
            }
        } else {
            $ownedLock = Enter-YurunaServiceOperationLockSet -Key @($row.Key) -Deadline $Deadline -WaitMilliseconds 0 -Purpose 'restore' -StateRoot $StateRoot -Confirm:$false -WhatIf:$false
            if (-not $ownedLock.Held) {
                if ($ownedLock.Reason -eq 'root-unavailable' -and [string]$ownedLock.RootReason -in $script:ServiceVmRootAbsentReason) {
                    # No private root exists, so no Start or Stop script can
                    # have recorded an intent or can take this lock (they
                    # refuse without the root): the sweep proceeds
                    # unserialized rather than never self-healing.
                    Write-Verbose "Restore-YurunaServiceVM: '$($row.Key)' has no private root ($($ownedLock.RootReason)); proceeding unserialized."
                    $ownedLock = $null
                } elseif ($ownedLock.Reason -eq 'busy') {
                    & $emit @{ Outcome = 'operation-busy'; Obligation = 'state-unresolved'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_operation_busy') }
                    continue
                } elseif ($ownedLock.Reason -eq 'deadline') {
                    & $emit @{ Outcome = 'deadline-exhausted'; Obligation = 'state-unresolved'; Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_deadline_exhausted') }
                    continue
                } else {
                    # A root that exists but cannot be trusted may hold a stop
                    # intent nobody can read now; a lock file that cannot be
                    # opened is not another operation. Neither is a start.
                    $lockReason = if ($ownedLock.Reason -eq 'root-unavailable') { [string]$ownedLock.RootReason }
                                  elseif ($ownedLock.LockReason) { [string]$ownedLock.LockReason } else { [string]$ownedLock.Reason }
                    $lockWhere = if ($ownedLock.StateRoot) { [string]$ownedLock.StateRoot } elseif ($StateRoot) { $StateRoot } else { '$HOME/.yuruna/host-refresh' }
                    & $emit @{ Outcome = 'lock-unavailable'; Obligation = 'state-unresolved'
                        Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_lock_unavailable' -Arguments @{ reason = $lockReason; path = $lockWhere }) }
                    continue
                }
            }
        }
        try {
            # A stop published after the evidence was read, and before this
            # lock was taken, wins over the start. A census that cannot be
            # read may hold such a stop, so it is not a start either.
            $censusNow = Read-YurunaServiceCensus -StateRoot $StateRoot
            if (-not (Test-ServiceVmCensusReadable -Census $censusNow)) {
                $censusReason = if ($censusNow.Detail) { [string]$censusNow.Detail } else { [string]$censusNow.Reason }
                & $emit @{ Outcome = 'state-unknown'; Obligation = 'state-unresolved'
                    Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_intent_unreadable' -Arguments @{ reason = $censusReason }) }
                continue
            }
            $intentNow = Get-YurunaServiceIntent -Key $row.Key -Census $censusNow
            if ($intentNow.DesiredState -eq 'stopped') {
                # Desired 'stopped' only ever comes from a stop request: a
                # pending or failed start leaves the state before it in
                # force, and that state is a stop's.
                & $emit @{ Outcome = 'intended-stopped'; DesiredState = 'stopped'; IntentGeneration = [long]$intentNow.Generation
                    Message = (Format-YurunaOperatorMessage -Key 'runner.service_restore_intended_stopped' -Arguments @{ operation = 'stop' }) }
                continue
            }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_27431929d461d016' -Arguments @{ displayName = "$($row.DisplayName)"; vMName = "$($row.VMName)"; state = "$stateBefore" }) -InformationAction Continue

            $startError = ''
            try {
                $r = Start-VM -VMName $row.VMName -Confirm:$false
                # Every driver returns @{ success; errorMessage }; tolerate a bare
                # boolean or $null so an out-of-contract driver cannot throw here.
                if ($r -is [System.Collections.IDictionary]) {
                    if (-not $r['success']) { $startError = [string]$r['errorMessage'] }
                } elseif ($r -is [bool] -and -not $r) {
                    $startError = 'Start-VM reported failure'
                }
            } catch {
                $startError = $_.Exception.Message
            }
            if ($startError) {
                & $emit @{ Outcome = 'start-failed'; Obligation = 'health-unverified'; Message = $startError }
                continue
            }

            $startDeadline = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds ([long]$startSeconds * 1000)
            $running = $false
            while (Wait-YurunaDeadlineInterval -Deadline $startDeadline -Milliseconds 2000 -Sleep $sleep) {
                $seen = Get-ServiceVmStateObservation -VMName $row.VMName -Deadline $startDeadline
                if ($seen.State -eq 'running') { $running = $true; break }
            }
            if (-not $running) {
                & $emit @{ Outcome = 'start-timeout'; Obligation = 'health-unverified'
                    Message = (Format-YurunaOperatorMessage -Key 'runner.operator_ce0d858e56345187' -Arguments @{ startTimeoutSeconds = "${startSeconds}" }) }
                continue
            }

            $healthy = $false
            $address = ''
            $message = 'started'
            if ($healthSeconds -gt 0) {
                $healthDeadline = New-YurunaDeadline -Parent $Deadline -TotalMilliseconds ([long]$healthSeconds * 1000)
                $health = Wait-ServiceVmHealth -VMName $row.VMName -HealthPort $row.HealthPort -Deadline $healthDeadline -Sleep $sleep
                $address = [string]$health.Address
                $healthy = [bool]$health.Healthy
                $message = if (-not $address) { (Format-YurunaOperatorMessage -Key 'runner.operator_482acc3cc0fb29aa') }
                           elseif ($healthy) { (Format-YurunaOperatorMessage -Key 'runner.operator_d671065a9abb598e' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address" }) }
                           else { (Format-YurunaOperatorMessage -Key 'runner.operator_6938c638981b508c' -Arguments @{ healthPort = "$($row.HealthPort)"; address = "$address"; healthTimeoutSeconds = "${healthSeconds}" }) }
            }
            $startObligation = if ($healthy -or $healthSeconds -eq 0) { 'none' } else { 'health-unverified' }
            & $emit @{ Outcome = 'started'; Healthy = $healthy; Message = $message; Address = $address; Obligation = $startObligation }
        } finally {
            if ($ownedLock) { Exit-YurunaServiceOperationLockSet -Context $ownedLock }
        }
    }
    return $results.ToArray()
}

function Write-YurunaServiceVmRestoreReport {
    <#
    .SYNOPSIS
        Print the outcomes worth an operator's attention. Silent when every
        service was already running or absent.
    .DESCRIPTION
        Silence on the healthy path is the point: this runs every cycle, and a
        line per service per cycle would bury the one cycle where something was
        actually restarted. A service whose state could not be confirmed is
        the exception: it was neither started nor rebuilt, and the probe
        reason is what tells a wedged hypervisor from a denied one. So is one
        whose operation lock could not be taken at all.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Result)

    foreach ($r in @($Result | Where-Object { $_ })) {
        switch ($r.Outcome) {
            'started' {
                if ($r.Healthy) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1d4e7f0d61957110' -Arguments @{ displayName = "$($r.DisplayName)"; message = "$($r.Message)" }) -InformationAction Continue }
                else { Write-Warning "$($r.DisplayName): $($r.Message)." }
            }
            'start-failed'  { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d11e9f40765785d8' -Arguments @{ displayName = "$($r.DisplayName)"; vMName = "$($r.VMName)"; message = "$($r.Message)"; startScript = "$((Get-YurunaServiceVmRoster -Key $r.Key).StartScript)" }) }
            'start-timeout' { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_47b0ccd4d36eff29' -Arguments @{ displayName = "$($r.DisplayName)"; vMName = "$($r.VMName)"; message = "$($r.Message)" }) }
            'state-unknown' {
                $reason = if ($r.PSObject.Properties['ProbeReason'] -and $r.ProbeReason) { [string]$r.ProbeReason } else { 'unclassified' }
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_restore_state_unknown' -Arguments @{ displayName = "$($r.DisplayName)"; vmName = "$($r.VMName)"; reason = $reason })
            }
            # Not another operation: the lock itself could not be taken, and
            # the sweep will keep failing the same way until someone looks.
            'lock-unavailable' {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.service_restore_lock_unavailable_report' -Arguments @{ displayName = "$($r.DisplayName)"; vmName = "$($r.VMName)"; message = "$($r.Message)" })
            }
            default { Write-Verbose "$($r.DisplayName): $($r.Outcome) -- $($r.Message)" }
        }
    }
}

Export-ModuleMember -Function Get-YurunaServiceVmRoster, Test-YurunaServiceVmPort, `
    Get-YurunaServiceVmAddress, Restore-YurunaServiceVM, Write-YurunaServiceVmRestoreReport, `
    Resolve-YurunaServiceVmPolicy, Test-YurunaServiceVmRunning
