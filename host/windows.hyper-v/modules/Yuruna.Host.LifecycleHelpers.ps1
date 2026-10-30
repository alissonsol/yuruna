<#PSScriptInfo
.VERSION 2026.10.30
.GUID 420a31b4-d92e-47d9-a33f-d600f3b83a22
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver lifecycle storage
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

# --- REGION: VM lifecycle helpers
# Hyper-V-internal helpers consumed by Yuruna.Host's contract entry points
# below. Not part of the test-facing host driver contract; test code
# calls the contract verbs (New-VM / Start-VM / ...) which delegate here.

function Resolve-HyperVVM {
    <#
    .SYNOPSIS
    Decide whether a Hyper-V VM is present, absent, or cannot be established,
    without reading the text of any exception.

    .DESCRIPTION
    `Hyper-V\Get-VM -Name` fails the same way for a VM that does not exist and for
    a provider that could not answer (VMMS down, a denied call, a busy host), and
    its message is localized. So a failed or empty name lookup is never read as
    absence on its own: a full inventory is taken, and only an inventory that
    succeeds and does not list the name proves the VM is absent. An inventory that
    lists the name after the lookup missed it, or an inventory that fails, is
    'unknown'. Hyper-V allows duplicate names, so two exact matches are 'unknown'
    as well -- acting on one of them could touch the other. A name holding a
    wildcard or escape character ([ ] * ? `) skips the -Name lookup and is decided
    by an exact match against the inventory alone.

    Presence 'absent' is what callers treat as permission to build, reuse a name
    or delete files, which is why every doubtful case answers 'unknown'.

    .OUTPUTS
    [pscustomobject] @{ Presence = present|absent|unknown; VM; Cause = ok|
    missing-client|ambiguous|lookup-failed|inventory-failed }
    #>
        [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command -Name 'Hyper-V\Get-VM' -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'missing-client' }
    }
    # See https://yuruna.link/42e220c4-0004
    $lookupByName = $VMName -notmatch '[\[\]*?`]'
    if ($lookupByName) {
        $candidates = @()
        try {
            $candidates = @(Hyper-V\Get-VM -Name $VMName -ErrorAction Stop)
        } catch {
            Write-Verbose "Resolve-HyperVVM: lookup of '$VMName' failed; deciding from the inventory: $($_.Exception.Message)"
            $candidates = @()
        }
        $exact = @($candidates | Where-Object { $null -ne $_ -and [string]$_.Name -eq $VMName })
        if ($exact.Count -eq 1) { return [pscustomobject]@{ Presence = 'present'; VM = $exact[0]; Cause = 'ok' } }
        if ($exact.Count -gt 1) { return [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'ambiguous' } }
    }
    $listed = @()
    try {
        $listed = @(Hyper-V\Get-VM -ErrorAction Stop | Where-Object { $null -ne $_ -and [string]$_.Name -eq $VMName })
    } catch {
        Write-Verbose "Resolve-HyperVVM: inventory failed: $($_.Exception.Message)"
        return [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'inventory-failed' }
    }
    if ($listed.Count -gt 1) { return [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'ambiguous' } }
    if ($listed.Count -eq 1) {
        if (-not $lookupByName) { return [pscustomobject]@{ Presence = 'present'; VM = $listed[0]; Cause = 'ok' } }
        return [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'lookup-failed' }
    }
    return [pscustomobject]@{ Presence = 'absent'; VM = $null; Cause = 'ok' }
}

<#
.SYNOPSIS
Verify that a Hyper-V VM with the given name is registered.

.DESCRIPTION
Returns $true and writes a verification line when Hyper-V\Get-VM finds
the VM (in any state); returns $false and writes an error otherwise.
Used by the test harness right after New-VM to fail fast when the VM
did not actually register.
#>
function Confirm-HyperVVMCreated {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_352afab56bf6c9c5' -Arguments @{ vMName = "$VMName"; state = "$($vm.State)" })
        return $true
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fb588d98fea5af35' -Arguments @{ vMName = "$VMName" })
    return $false
}

<#
.SYNOPSIS
Force a Hyper-V VM to the 'Off' state, escalating to a vmwp.exe kill if
Stop-VM -TurnOff doesn't take effect.

.DESCRIPTION
Stop-VM -TurnOff can hang indefinitely on a stuck VM (any transient
state where vmms can't complete the transition). Each running VM is
hosted by a `vmwp.exe` worker process whose command line contains the
VM's Id GUID; killing that process deallocates the VM and lets
Remove-VM proceed.

Presence comes from Resolve-HyperVVM: a VM positively absent is already
stopped, and one whose presence cannot be established is never reported
stopped -- the function returns $false before touching anything, and a poll
that reads 'unknown' keeps waiting rather than counting it as Off.

Returns $true when the VM is gone or 'Off'; $false when even the
vmwp.exe kill didn't clear it, or when its state is unknown.
#>
function Stop-HyperVVMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    $resolved = Resolve-HyperVVM -VMName $VMName
    if ($resolved.Presence -eq 'absent') { return $true }
    if ($resolved.Presence -ne 'present') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_state_unknown' -Arguments @{ operation = 'Stop-VMForce'; vMName = "$VMName" })
        return $false
    }
    $vm = $resolved.VM
    if ($vm.State -in @('Off', 'Saved', 'OffCritical')) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_53198937e6a2855f'))) {
        return $false
    }

    # First attempt: graceful-ish TurnOff in a background job so a hung
    # vmms can't block us.
    $stopJob = Start-Job -ScriptBlock {
        Hyper-V\Stop-VM -Name $using:VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $poll = Resolve-HyperVVM -VMName $VMName
        if ($poll.Presence -eq 'absent' -or ($poll.Presence -eq 'present' -and $poll.VM.State -eq 'Off')) {
            Stop-Job   -Job $stopJob -ErrorAction SilentlyContinue
            Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue
            return $true
        }
        if ($poll.Presence -eq 'present') { $vm = $poll.VM }
        Start-Sleep -Milliseconds 500
    }
    Stop-Job   -Job $stopJob -ErrorAction SilentlyContinue
    Remove-Job -Job $stopJob -Force -ErrorAction SilentlyContinue

    # Escalate: kill the vmwp.exe worker process hosting this VM.
    $vmId = $vm.Id.Guid
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_79b3a3b71b34f01c' -Arguments @{ vMName = "$VMName"; stopTimeoutSeconds = "${StopTimeoutSeconds}"; state = "$($vm.State)"; vmId = "$vmId" })
    # vmwp.exe workers run under the per-VM virtual account 'NT VIRTUAL MACHINE\<vmId>', so
    # Win32_Process.CommandLine is frequently empty (the process is owned by another account)
    # and a CommandLine-only match silently skips the worker, defeating the force-stop. Match on
    # the command line when it is readable, and otherwise on the owning account, whose user name
    # is the VM GUID.
    $workers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.CommandLine -and ($_.CommandLine -match [regex]::Escape($vmId))) -or
            (($_ | Invoke-CimMethod -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq $vmId)
        })
    if (-not $workers) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_631642be837a8711' -Arguments @{ vmId = "$vmId" })
        $retryJob = Start-Job -ScriptBlock {
            Hyper-V\Stop-VM -Name $using:VMName -Force -TurnOff -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        Wait-Job   -Job $retryJob -Timeout 10 | Out-Null
        Stop-Job   -Job $retryJob -ErrorAction SilentlyContinue
        Remove-Job -Job $retryJob -Force -ErrorAction SilentlyContinue
    } else {
        foreach ($w in $workers) {
            try {
                Stop-Process -Id $w.ProcessId -Force -ErrorAction Stop
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_60cb175cc471b1fe' -Arguments @{ processId = "$($w.ProcessId)"; vMName = "$VMName" })
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c00f98d8832e6542' -Arguments @{ processId = "$($w.ProcessId)"; value = "$_" })
            }
        }
    }

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        $poll = Resolve-HyperVVM -VMName $VMName
        if ($poll.Presence -eq 'absent' -or ($poll.Presence -eq 'present' -and $poll.VM.State -eq 'Off')) { return $true }
        Start-Sleep -Milliseconds 500
    }

    $final = Resolve-HyperVVM -VMName $VMName
    $finalState = if ($final.Presence -eq 'present') { [string]$final.VM.State } else { [string]$final.Presence }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_23fb4d89d4ecb64b' -Arguments @{ vMName = "$VMName"; finalState = "$finalState" })
    return $false
}

# --- REGION: Storage references
function Get-HyperVDirectoryDiskOwner {
    <#
    .SYNOPSIS
        The registered VMs that use a virtual disk under a directory, their
        checkpoints included, as @{ VMName; Path } rows. THROWS when Hyper-V
        cannot be queried.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][string]$Directory)
    $root = $Directory.TrimEnd('\', '/') + '\'
    $owners = foreach ($vm in @(Hyper-V\Get-VM -ErrorAction Stop)) {
        $paths = @(Hyper-V\Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction Stop | ForEach-Object { $_.Path })
        foreach ($checkpoint in @(Hyper-V\Get-VMSnapshot -VMName $vm.Name -ErrorAction Stop)) {
            $paths += @(Hyper-V\Get-VMHardDiskDrive -VMCheckpoint $checkpoint -ErrorAction Stop | ForEach-Object { $_.Path })
        }
        foreach ($path in $paths) {
            if ($path -and ([string]$path).StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { @{ VMName = [string]$vm.Name; Path = [string]$path } }
        }
    }
    return [hashtable[]]@($owners)
}

function Get-HyperVCheckpointRecord {
    <#
    .SYNOPSIS
        The checkpoints Hyper-V itself records for a VM, as rows of
        @{ Name; Type; Created }, or $null when the query fails or does not
        answer within the cap (TimeoutSeconds, the lifecycle cap by default).
    .DESCRIPTION
        Read from the virtualization provider's Msvm_VirtualSystemSettingData by
        the VM's Id, which a rename and a storage move leave unchanged, rather
        than through the Hyper-V module's listing, so a checkpoint that listing
        does not show can be told apart from one Hyper-V does not hold. An empty
        array means Hyper-V holds no checkpoint for the VM.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Unary comma keeps an empty answer distinct from a failed one.')]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][guid]$VMId,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = $script:HyperVLifecycleTimeoutSeconds
    )
    $filter = "VirtualSystemIdentifier='{0}' AND VirtualSystemType LIKE 'Microsoft:Hyper-V:Snapshot:%'" -f $VMId.ToString().ToUpperInvariant()
    $call = Invoke-HyperVBoundedCall -TimeoutSeconds $TimeoutSeconds -ArgumentList @($filter) -ScriptBlock {
        param($Filter)
        Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter $Filter -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Name = [string]$_.ElementName; Type = [string]$_.VirtualSystemType; Created = $_.CreationTime }
        }
    }
    if ($call.TimedOut -or $call.Error) { return $null }
    return , @($call.Output)
}

function Repair-HyperVVMStorageLocation {
    <#
    .SYNOPSIS
        Finish an interrupted rename for a VM whose disks still live under
        another name's directory below VirtualHardDiskPath. $true when its
        storage is under its own name afterwards (or already was).
    .DESCRIPTION
        Rename-VM renames the registration first and moves the storage last, so
        a failure or kill between the two leaves the renamed VM's VHDX under
        <VirtualHardDiskPath>\<old name>. That directory then looks like the
        remains of a removed VM. The state to resume is read from Hyper-V itself:
        the first path segment of the VM's disks names the rename that did not
        finish. The NIC is re-pinned under the same guard Rename-VM uses (only
        an address derived from the vacated name moves, and only while the VM is
        off), then the storage is moved. Refused while the old directory also
        holds another VM's disks, because then it is not this rename's to move.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
    if (-not $vhdRoot) { return $true }
    $prefix = ([string]$vhdRoot).TrimEnd('\', '/') + '\'
    $foreign = $null
    foreach ($path in @(Hyper-V\Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop | ForEach-Object { [string]$_.Path })) {
        if (-not $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $leaf = $path.Substring($prefix.Length).Split([char[]]@('\', '/'))[0]
        if ($leaf -and -not [string]::Equals($leaf, $VMName, [System.StringComparison]::OrdinalIgnoreCase)) { $foreign = $leaf; break }
    }
    if (-not $foreign) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocate_action' -Arguments @{ fromName = "$foreign" }))) { return $false }
    $others = @(Get-HyperVDirectoryDiskOwner -Directory ($prefix + $foreign) | Where-Object { -not [string]::Equals($_.VMName, $VMName, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($others.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocation_failed' -Arguments @{ vMName = "$VMName"; fromName = "$foreign"; reason = "also used by $(@($others | ForEach-Object { $_.VMName } | Select-Object -Unique) -join ', ')" })
        return $false
    }
    try {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction Stop
        if ([string]$vm.State -eq 'Off') {
            $adapter = Hyper-V\Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop | Select-Object -First 1
            if ($adapter -and (Test-YurunaGuestMacMatchesName -MacAddress ([string]$adapter.MacAddress) -VMName $foreign)) {
                $adapter | Hyper-V\Set-VMNetworkAdapter -StaticMacAddress ((Get-YurunaGuestMacAddress -VMName $VMName) -replace ':', '') -ErrorAction Stop
            }
        }
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Move-VMStorage' -VMName $VMName -ArgumentList @($VMName, ($prefix + $VMName)) -ScriptBlock {
            param($Name, $Destination)
            Hyper-V\Move-VMStorage -VMName $Name -DestinationStoragePath $Destination -Confirm:$false -ErrorAction Stop
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocation_failed' -Arguments @{ vMName = "$VMName"; fromName = "$foreign"; reason = "$($_.Exception.Message)" })
        return $false
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocated' -Arguments @{ vMName = "$VMName"; fromName = "$foreign" }) -InformationAction Continue
    return $true
}

function Test-HyperVDirectoryFreeToDelete {
    <#
    .SYNOPSIS
        $true when no registered VM uses a disk under a VM directory, after
        finishing any interrupted rename that left one there.
    .DESCRIPTION
        A directory named after a VM that no longer exists is not proof that its
        disks are abandoned; see Repair-HyperVVMStorageLocation. Owners are
        repaired first; anything still referenced, or a reference check that
        cannot be answered, keeps the directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)
    try {
        $owners = @(Get-HyperVDirectoryDiskOwner -Directory $Directory)
        foreach ($owner in @($owners | ForEach-Object { $_.VMName } | Select-Object -Unique)) {
            $null = Repair-HyperVVMStorageLocation -VMName $owner -Confirm:$false
        }
        if ($owners.Count -gt 0) { $owners = @(Get-HyperVDirectoryDiskOwner -Directory $Directory) }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_reference_unknown' -Arguments @{ vmDir = "$Directory"; message = "$($_.Exception.Message)" })
        return $false
    }
    if ($owners.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_delete_refused' -Arguments @{ vmDir = "$Directory"; owners = "$(@($owners | ForEach-Object { $_.VMName } | Select-Object -Unique) -join ', ')" })
        return $false
    }
    return $true
}

# --- REGION: Repair-VMStorageLocation
function Repair-VMStorageLocation {
    <#
    .SYNOPSIS
        Finish every rename an interrupted snapshot promotion left half done,
        before a sweep, a build or a delete reaches the directory it vacated.
    .DESCRIPTION
        Repair-HyperVVMStorageLocation for each registered VM, so the repair no
        longer waits for a delete to reach the old directory. The state comes
        from Hyper-V, as for one VM: a disk under another name's directory below
        VirtualHardDiskPath names the rename that did not finish. A VM that
        cannot be repaired now (its old directory is shared, its move fails, or
        its disks cannot be read) keeps its storage, is warned about and named in
        the result, and the next call tries again. THROWS when the VM list
        cannot be read.
    .OUTPUTS
        [string[]] the VMs whose storage is still under another name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param()
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
    if (-not $vhdRoot) { return [string[]]@() }
    if (-not $PSCmdlet.ShouldProcess($vhdRoot, (Format-YurunaOperatorMessage -Key 'host.vm_storage_reconcile_action'))) { return [string[]]@() }
    $unrepaired = foreach ($vm in @(Hyper-V\Get-VM -ErrorAction Stop)) {
        $name = [string]$vm.Name
        try {
            if (-not (Repair-HyperVVMStorageLocation -VMName $name -Confirm:$false)) { $name }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_repair_unknown' -Arguments @{ vMName = "$name"; message = "$($_.Exception.Message)" })
            $name
        }
    }
    return [string[]]@($unrepaired)
}

<#
.SYNOPSIS
Force-stop and delete a Hyper-V VM along with its disk directory.

.DESCRIPTION
Brings the VM to Off via Stop-HyperVVMForce, closes any vmconnect
viewer attached to the VM (deleting a VM with its viewer open leaves a
modal "has been deleted" dialog that blocks until dismissed by hand),
calls Remove-VM, and then removes the per-VM subdirectory under
Get-VMHost.VirtualHardDiskPath.

Presence comes from Resolve-HyperVVM. When it cannot be established the
function removes nothing -- not the registration and not the disk directory
-- and returns $false. After Remove-VM the VM must read positively 'absent';
a VM still listed, or one whose presence is again unknown, counts as not
removed. The disk directory is deleted only once the registration is
positively gone: files deleted from under a VM that still exists would leave
a registered VM that can never boot, and the next run would find it "already
there". Returns $true only when the VM is positively not registered;
disk-cleanup failures are warned but do not flip the result.
#>
function Remove-HyperVTestVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_12924e738438f274'))) { return $false }
    $resolved = Resolve-HyperVVM -VMName $VMName
    if ($resolved.Presence -eq 'unknown') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_state_unknown' -Arguments @{ operation = 'Remove-VM'; vMName = "$VMName" })
        return $false
    }
    $registryRemoved = $true
    if ($resolved.Presence -eq 'present') {
        $null = Stop-HyperVVMForce -VMName $VMName -Confirm:$false
        # See https://yuruna.link/42e220c4-0004
        Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
            Stop-Process -Force -ErrorAction SilentlyContinue
        try {
            $null = Invoke-HyperVLifecycleCmdlet -Verb 'Remove-VM' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
                param($Name)
                Hyper-V\Remove-VM -Name $Name -Force -Confirm:$false -ErrorAction Stop 6>$null
            }
            $after = Resolve-HyperVVM -VMName $VMName
            if ($after.Presence -eq 'absent') {
                Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_9c763f8a46614503' -Arguments @{ vMName = "$VMName" })
            } elseif ($after.Presence -eq 'present') {
                $registryRemoved = $false
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d660ea14d5a1e764' -Arguments @{ vMName = "$VMName" })
            } else {
                $registryRemoved = $false
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_removal_unconfirmed' -Arguments @{ vMName = "$VMName" })
            }
        } catch {
            $registryRemoved = $false
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_be96c470ac033b2c' -Arguments @{ vMName = "$VMName"; value = "$_" })
        }
    }
    if (-not $registryRemoved) { return $false }
    $vhdPath = (Hyper-V\Get-VMHost -ErrorAction SilentlyContinue).VirtualHardDiskPath
    if ($vhdPath) {
        $vmDir = Join-Path $vhdPath $VMName
        # The directory is deleted only when no registered VM still uses a disk
        # in it; see Test-HyperVDirectoryFreeToDelete.
        if ((Test-Path $vmDir) -and (Test-HyperVDirectoryFreeToDelete -Directory $vmDir)) {
            try {
                Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction Stop 6>$null
                Write-Verbose "Removed VM disk directory: $vmDir"
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_06870ad7a1059861' -Arguments @{ vmDir = "$vmDir"; value = "$_" })
            }
        }
    }
    return $registryRemoved
}

<#
.SYNOPSIS
This host's memory position: physical memory available now, plus the system
commit charge and the limit that charge is drawn against.

.DESCRIPTION
A VM's startup memory is charged against the SYSTEM COMMIT LIMIT -- physical
memory plus the current size of the page file -- and not against free physical
memory, so commit is the quantity that decides whether a start is admitted.
With a system-managed page file that limit is not a constant: Windows grows and
shrinks the file as the total charge moves, and while a growth is in flight the
limit is momentarily too low to admit a fresh multi-gigabyte reservation. That
is why a start can be refused for want of system resources at the very moment
free physical memory is at its highest: the two readings answer different
questions, and only one of them is the question the hypervisor asked.

Win32_OperatingSystem is the primary source because it answers whenever WMI
does, and it states the whole position on its own: TotalVirtualMemorySize IS
the commit limit and FreeVirtualMemory IS the headroom under it, both in KB.
Win32_PerfRawData_PerfOS_Memory is consulted only when that query fails -- it
is served by the performance-counter subsystem, which can be broken on a host
whose WMI is healthy.

The four value keys are named for the quantity rather than for this platform's
counters, so another host driver can fill the same shape from its own source
(on Linux, /proc/meminfo MemAvailable / Committed_AS / CommitLimit) and a
failure record keeps one meaning whichever driver wrote it.

Never throws. $null means "not knowable on this host", and a caller must carry
that through as an absent reading rather than substituting zeros -- a fabricated
memory figure in a failure record is worse than none, because it reads as a
measurement.

.OUTPUTS
[hashtable] with availableMb, committedBytes, commitLimitBytes,
commitAvailableBytes and source; $null when the host will not answer.
#>
function Get-HostMemoryStatus {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ($os -and ([int64]$os.TotalVirtualMemorySize) -gt 0) {
            $limit = [int64]$os.TotalVirtualMemorySize * 1KB
            $free  = [int64]$os.FreeVirtualMemory * 1KB
            return @{
                availableMb          = [int64]([int64]$os.FreePhysicalMemory / 1KB)
                committedBytes       = $limit - $free
                commitLimitBytes     = $limit
                commitAvailableBytes = $free
                source               = 'Win32_OperatingSystem'
            }
        }
    } catch {
        Write-Verbose "Get-HostMemoryStatus: Win32_OperatingSystem did not answer: $($_.Exception.Message)"
    }
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        if ($perf -and ([int64]$perf.CommitLimit) -gt 0) {
            return @{
                availableMb          = [int64]$perf.AvailableMBytes
                committedBytes       = [int64]$perf.CommittedBytes
                commitLimitBytes     = [int64]$perf.CommitLimit
                commitAvailableBytes = [int64]$perf.CommitLimit - [int64]$perf.CommittedBytes
                source               = 'Win32_PerfRawData_PerfOS_Memory'
            }
        }
    } catch {
        Write-Verbose "Get-HostMemoryStatus: performance counters did not answer: $($_.Exception.Message)"
    }
    return $null
}

<#
.SYNOPSIS
One line describing a memory reading, for a log an operator reads at a glance.

.DESCRIPTION
Commit is stated first because commit is what admits or refuses a start, and
physical last because it is the figure that misleads when read on its own.

.OUTPUTS
[string]
#>
function Format-HostMemoryStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][hashtable]$Status)
    if (-not $Status) { return 'host memory position unreadable' }
    return ('commit {0:N1} of {1:N1} GB charged, {2:N1} GB uncharged; {3:N1} GB physical available' -f `
        ($Status.committedBytes / 1GB), ($Status.commitLimitBytes / 1GB),
        ($Status.commitAvailableBytes / 1GB), ($Status.availableMb / 1KB))
}

<#
.SYNOPSIS
True when a failure is the host refusing an allocation for want of system
resources, rather than anything about the VM being started.

.DESCRIPTION
ERROR_NO_SYSTEM_RESOURCES surfaces as HRESULT 0x800705AA, which is -2147023446
as a signed Int32 -- the value the numeric checks compare against, taken from
HResult anywhere in the exception chain and from NativeErrorCode on a
Win32Exception, whichever wrapper the failing call happened to produce.

The rendered text is the LAST resort and is matched on the hex literal alone.
Every word around that literal is translated on a localized host, so a match on
the English sentence would quietly stop recognizing the condition on exactly
the machines least likely to be watched; the digits are not translated. A
refusal stating neither the code nor the literal is simply not recognized, and
the caller then treats it as it treats any other start failure -- the narrow
match can cost a retry, never a misclassification.

.OUTPUTS
[bool]
#>
function Test-HostResourceExhaustionError {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$ErrorRecord)
    if (-not $ErrorRecord) { return $false }
    $noSystemResources = -2147023446
    $text = ''
    $ex   = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $text = "$ErrorRecord"
        $ex   = $ErrorRecord.Exception
    } else {
        $ex = $ErrorRecord -as [System.Exception]
    }
    # Depth-bounded: an exception whose InnerException chain loops back on
    # itself would otherwise hang the classifier inside a failure path.
    $depth = 0
    while ($ex -and $depth -lt 8) {
        if ($ex.HResult -eq $noSystemResources) { return $true }
        if (($ex -is [System.ComponentModel.Win32Exception]) -and ($ex.NativeErrorCode -eq 1450)) { return $true }
        $text += " $($ex.Message)"
        $ex = $ex.InnerException
        $depth++
    }
    return ($text -match '0x800705AA')
}

<#
.SYNOPSIS
The startup memory, in bytes, that starting the named VM will charge the host.

.DESCRIPTION
Read from the VM definition rather than passed in by the caller: the size is
set by the per-guest builder and by the planner's sizing override, and a second
statement of it here would drift from whichever one actually shaped the VM.
Dynamic memory changes what a running guest keeps, not what its start has to
find, so startup memory is the figure either way.

0 when the VM cannot be read; the caller treats that as "size unknown" and
skips the arithmetic that would need it rather than guessing at a size.

.OUTPUTS
[int64] bytes, or 0.
#>
function Get-HyperVVMStartupMemory {
    [CmdletBinding()]
    [OutputType([int64])]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction Stop
        if ($vm) { return [int64]$vm.MemoryStartup }
    } catch {
        Write-Verbose "Get-HyperVVMStartupMemory: '$VMName' did not answer: $($_.Exception.Message)"
    }
    return [int64]0
}

<#
.SYNOPSIS
Wait -- briefly, and only while the host is actually giving memory back -- for
the uncharged commit to cover an allocation that is about to be made.

.DESCRIPTION
A teardown returns from Remove-VM before the departing VM worker process has
exited and handed its commit back, so "the previous VM is no longer running" is
not the same fact as "its memory is available again". The gap between the two
runs to tens of seconds on a loaded host, and a start issued inside that gap is
the one that gets refused.

Two hosts can fail the same predicate for opposite reasons, and they deserve
opposite treatment. A host mid-teardown is RELEASING: its uncharged commit
climbs in gigabyte steps as the departing worker exits, and waiting there is
productive because the request is usually met within seconds. A host that is
simply over-subscribed is releasing nothing, its reading does not climb, and no
amount of waiting will satisfy the request -- there a wait is pure cost, paid
on every start, forever. So the budget is not what ends this wait in the common
case: the absence of upward movement is. While the reading keeps climbing the
wait runs on toward the budget; once it has failed to climb for a few
consecutive polls the host is taken to be releasing nothing and the wait
returns.

"Climbing" has to clear a floor, because uncharged commit on a live host is
never still. It moves by hundreds of megabytes between polls as ordinary
processes allocate and release, and with a system-managed page file the LIMIT
itself steps as Windows resizes the file, which moves the headroom with no
allocation changing at all. So progress is measured against the HIGHEST reading
seen so far, never against the previous one -- a dip followed by a recovery is
not progress and must not ratchet the wait forward -- and only a gain of at
least ProgressBytes counts. The floor sits well above the churn a busy host
shows while it is releasing nothing, and well below what any guest teardown
hands back, so a real release is unmissable and ordinary noise is invisible.

Neither a stall nor a timeout is a failure, and neither may ever become one.
The wait returns Satisfied = $false and the caller proceeds with the start it
was going to make anyway: the hypervisor's own answer is the authoritative one
and the only one that carries a diagnosable error, and a synthetic preemptive
failure would replace it with a guess about a start nobody attempted. The same
holds when the counters stop answering, and the whole body is guarded so that
even an unforeseen fault in here ends the wait instead of the start. The only
thing this function can do to a start is delay it; it can never prevent one.

Bounded twice over -- each poll sleep is clipped to what is left of the budget
-- so the worst case is the budget plus one reading however the host behaves.

.OUTPUTS
[hashtable] with Satisfied, WaitedSeconds, Reason and Status (the last reading,
or $null when the host stopped answering). Reason is one of 'satisfied',
'no-predicate', 'unreadable', 'stalled' or 'timeout', and is what tells an
operator whether a short wait meant a healthy host or a saturated one.
#>
function Wait-HostMemoryHeadroom {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int64]$RequiredBytes,
        [string]$Label = '',
        [int]$TimeoutSeconds = 20,
        [int]$PollSeconds = 2,
        # A gigabyte is well above the poll-to-poll movement a busy host shows
        # while it is releasing nothing, and well below what a multi-gigabyte
        # guest hands back when its worker exits. A smaller floor reads ordinary
        # churn as a teardown in flight and keeps waiting on a host that is
        # merely full, which is the cost this early exit exists to avoid.
        [int64]$ProgressBytes = 1GB,
        # Three polls, not one: a departing worker can hold flat for a beat
        # before its pages are reclaimed. Being wrong in this direction costs a
        # few seconds; being wrong in the other costs the whole budget on every
        # start for the life of the host.
        [int]$StallPolls = 3
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Guarded as a whole. This function exists to spare a start a refusal it
    # would otherwise take, so the one outcome it must never produce is a start
    # that never happened: any fault in here -- a counter source that throws
    # instead of returning nothing, a host stating a value in an unexpected
    # shape -- ends the wait and leaves the attempt to the caller.
    try {
        $status = Get-HostMemoryStatus
        $result = @{ Satisfied = $true; WaitedSeconds = 0; Reason = 'satisfied'; Status = $status }
        # No predicate, no wait: an unreadable host or an unknown allocation size
        # gives nothing to wait FOR, and such a wait can only spend its budget.
        if (-not $status) { $result.Reason = 'unreadable'; return $result }
        if ($RequiredBytes -le 0) { $result.Reason = 'no-predicate'; return $result }
        if ($status.commitAvailableBytes -ge $RequiredBytes) { return $result }
        Write-Information -MessageData ((Format-YurunaOperatorMessage -Key 'host.operator_5a62ca9dd9977b94' -Arguments @{ label = "$Label"; status = "$(Format-HostMemoryStatus -Status $status)"; timeoutSeconds = "${TimeoutSeconds}" } -FormatValues @(($RequiredBytes / 1GB)) -FormatBindings @{ requiredGB = '0:N1' })) -InformationAction Continue
        $bestSeenBytes = [int64]$status.commitAvailableBytes
        $flatPolls = 0
        $exitReason = 'timeout'
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $remaining = $TimeoutSeconds - $sw.Elapsed.TotalSeconds
            Start-Sleep -Milliseconds ([int]([Math]::Min([double]$PollSeconds, $remaining) * 1000))
            $status = Get-HostMemoryStatus
            $result.Status = $status
            if (-not $status) { $exitReason = 'unreadable'; break }
            if ($status.commitAvailableBytes -ge $RequiredBytes) {
                $result.WaitedSeconds = [int]$sw.Elapsed.TotalSeconds
                Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_04fd116620ef7962' -Arguments @{ label = "$Label"; waitedSeconds = "$($result.WaitedSeconds)"; status = "$(Format-HostMemoryStatus -Status $status)" }) -InformationAction Continue
                return $result
            }
            if ([int64]$status.commitAvailableBytes -ge ($bestSeenBytes + $ProgressBytes)) {
                $bestSeenBytes = [int64]$status.commitAvailableBytes
                $flatPolls = 0
            } else {
                $flatPolls++
                if ($flatPolls -ge $StallPolls) { $exitReason = 'stalled'; break }
            }
        }
        $result.Satisfied     = $false
        $result.Reason        = $exitReason
        $result.WaitedSeconds = [int]$sw.Elapsed.TotalSeconds
        $why = switch ($exitReason) {
            'stalled'    { 'the host handed nothing back while this watched, so it is over-subscribed rather than mid-teardown' }
            'unreadable' { 'the host stopped stating its memory position' }
            default      { 'the headroom never arrived' }
        }
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_dbb1034060435dc0' -Arguments @{ label = "$Label"; waitedSeconds = "$($result.WaitedSeconds)"; why = "$why"; status = "$(Format-HostMemoryStatus -Status $status)" }) -InformationAction Continue
        return $result
    } catch {
        Write-Verbose "Wait-HostMemoryHeadroom: the host's memory position could not be watched: $($_.Exception.Message)"
        return @{ Satisfied = $true; WaitedSeconds = [int]$sw.Elapsed.TotalSeconds; Reason = 'unreadable'; Status = $null }
    }
}

function Initialize-HyperVStorageNativeLibrary {
    <#
    .SYNOPSIS
    Loads the Windows volume and allocated-file-size readers.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Loads process-local interop declarations; changes no host configuration.')]
    param()
    if ('Yuruna.HyperVStorageNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Yuruna {
    public static class HyperVStorageNative {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool GetVolumePathNameW(string path, StringBuilder volume, uint length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool GetVolumeNameForVolumeMountPointW(string mount, StringBuilder volume, uint length);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool GetDiskFreeSpaceExW(string path, out ulong available, out ulong total, out ulong free);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetCompressedFileSizeW(string path, out uint high);
        public static ulong AllocatedBytes(string path) {
            uint high;
            uint low = GetCompressedFileSizeW(path, out high);
            int error = Marshal.GetLastWin32Error();
            if (low == UInt32.MaxValue && error != 0) throw new Win32Exception(error);
            return ((ulong)high << 32) | low;
        }
    }
}
'@ -ErrorAction Stop
}

function Get-HyperVStorageVolume {
    <#
    .SYNOPSIS
    Reads available bytes on the volume backing a VM path.
    .DESCRIPTION
    Resolve the closest existing directory, including volume mount points and
    junctions. A drive-letter or machine-wide sum can report space on a different
    volume. Available bytes honor the caller's quota. A failed probe stays unknown.

    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $result = @{ known = $false; path = $Path; volume = ''; mountPath = ''; freeBytes = $null; totalBytes = $null; reason = ''; source = 'GetDiskFreeSpaceExW' }
    try {
        if (-not $IsWindows) { throw 'Windows storage APIs are unavailable on this platform.' }
        Initialize-HyperVStorageNativeLibrary
        $directory = $Path
        while (-not [IO.Directory]::Exists($directory)) {
            $parent = [IO.Path]::GetDirectoryName($directory.TrimEnd('\', '/'))
            if (-not $parent -or $parent -eq $directory) { throw "No accessible parent directory for '$Path'." }
            $directory = $parent
        }
        $directory = $directory.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        $mount = [Text.StringBuilder]::new(32768)
        if (-not [Yuruna.HyperVStorageNative]::GetVolumePathNameW($directory, $mount, $mount.Capacity)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $result.mountPath = $mount.ToString()
        $volume = [Text.StringBuilder]::new(32768)
        $result.volume = if ([Yuruna.HyperVStorageNative]::GetVolumeNameForVolumeMountPointW($result.mountPath, $volume, $volume.Capacity)) { $volume.ToString() } else { $result.mountPath }
        [uint64]$available = 0; [uint64]$total = 0; [uint64]$free = 0
        if (-not [Yuruna.HyperVStorageNative]::GetDiskFreeSpaceExW($directory, [ref]$available, [ref]$total, [ref]$free)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $result.freeBytes = [int64]$available
        $result.totalBytes = [int64]$total
        $result.known = $true
    } catch { $result.reason = $_.Exception.Message }
    return $result
}

function Get-HyperVStorageFile {
    <#
    .SYNOPSIS
    Distinguishes missing, allocated, and unreadable VM storage files.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $result = @{ path = $Path; known = $false; exists = $null; logicalBytes = $null; allocatedBytes = $null; reason = '' }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        $result.exists = $true
        $result.logicalBytes = [int64]$file.Length
        if (-not $IsWindows) { throw 'Windows allocated-file-size API is unavailable on this platform.' }
        Initialize-HyperVStorageNativeLibrary
        # Length is insufficient for a sparse VMRS: logical size does not mean
        # the space is already reserved. This API reports allocated storage.
        $result.allocatedBytes = [int64][Yuruna.HyperVStorageNative]::AllocatedBytes($file.FullName)
        $result.known = $true
    } catch {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') {
            $result.exists = $false
            $result.logicalBytes = [int64]0
            $result.allocatedBytes = [int64]0
            $result.known = $true
        } else { $result.reason = $_.Exception.Message }
    }
    return $result
}

function Get-HyperVVMStorageRequirement {
    <#
    .SYNOPSIS
    Describes one VM's additional runtime allocation and bounded disk evidence.
    .DESCRIPTION
    Existing VMs use their own configuration location and VM identifier, never
    the host's default or the VHD volume. Prospective persisted VMs use the
    builder's VHD root: Save-VMDiskSnapshot moves their configuration there.
    Explicit startup zero describes a disk-only VM that this topology will not
    start. Disk growth is budgeted separately by Test-VMStorageCapacity.

    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName, [hashtable]$StartupMemoryBytes = @{})
    $row = @{ vmName = $VMName; known = $false; state = 'unknown'; runtimePath = ''; storagePath = ''; startupBytes = $null; allocatedBytes = $null; additionalBytes = $null; footprint = @(); reason = ''; source = 'Hyper-V' }
    try {
        $resolved = Resolve-HyperVVM -VMName $VMName
        if ($resolved.Presence -eq 'unknown') { throw "VM inventory is unavailable ($($resolved.Cause))." }
        if ($resolved.Presence -eq 'absent') {
            if (-not $StartupMemoryBytes.ContainsKey($VMName)) { throw 'The absent VM has no declared startup-memory requirement.' }
            [int64]$expected = $StartupMemoryBytes[$VMName]
            if ($expected -lt 0) { throw 'Startup memory must be nonnegative.' }
            $root = [string](Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
            if (-not $root) { throw 'The Hyper-V virtual-hard-disk path is unavailable.' }
            $row.storagePath = Join-Path $root $VMName
            $row.runtimePath = Join-Path (Join-Path $row.storagePath 'Virtual Machines') "$VMName.vmrs"
            $row.state = 'absent'
            $row.startupBytes = $expected
            $row.allocatedBytes = [int64]0
            $row.additionalBytes = $expected
            $row.known = $true
            $row.source = 'declared-topology'
            return $row
        }
        $vm = $resolved.VM
        $row.state = [string]$vm.State
        $row.startupBytes = [int64]$vm.MemoryStartup
        $configuration = [string]$vm.ConfigurationLocation
        $id = [string]$vm.Id
        if (-not $configuration -or -not $id) { throw 'The VM configuration location or identifier is unavailable.' }
        $row.runtimePath = Join-Path (Join-Path $configuration 'Virtual Machines') "$id.vmrs"
        $runtime = Get-HyperVStorageFile -Path $row.runtimePath
        $row.allocatedBytes = $runtime.allocatedBytes
        $files = [Collections.Generic.List[hashtable]]::new()
        $files.Add($runtime)
        # Enumerate only attached disks and their parent chain, not a recursive
        # host-wide scan. Snapshot history is already represented by that chain.
        try {
            $disks = @(Hyper-V\Get-VMHardDiskDrive -VMName $VMName -ErrorAction Stop)
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($disk in $disks) {
                $path = [string]$disk.Path
                if (-not $row.storagePath -and $path) { $row.storagePath = Split-Path -Parent $path }
                for ($depth = 0; $path -and $depth -lt 32 -and $seen.Add($path); $depth++) {
                    $files.Add((Get-HyperVStorageFile -Path $path))
                    $path = [string](Hyper-V\Get-VHD -Path $path -ErrorAction Stop).ParentPath
                }
            }
        } catch { $row.footprintError = $_.Exception.Message }
        $row.footprint = @($files.ToArray())
        $diskOnly = $StartupMemoryBytes.ContainsKey($VMName) -and [int64]$StartupMemoryBytes[$VMName] -eq 0
        if ($row.state -eq 'Running' -or $diskOnly) {
            $row.additionalBytes = [int64]0
            $row.known = $true
        } elseif ($runtime.known -and $row.startupBytes -gt 0) {
            $row.additionalBytes = [int64][Math]::Max([int64]0, [int64]($row.startupBytes - $runtime.allocatedBytes))
            $row.known = $true
        } else { $row.reason = 'Runtime allocation or startup memory is unavailable.' }
    } catch { $row.reason = $_.Exception.Message }
    return $row
}

function Test-VMStorageCapacity {
    <#
    .SYNOPSIS
    Checks additional runtime and declared disk growth on each actual volume.
    .DESCRIPTION
    A topology is admitted only against its own volumes. Existing runtime
    allocation is credited once; a reserve is charged once per volume needing
    growth. Unknown readings remain unknown and permit the hypervisor to decide.
    AdditionalStorageBytes is an explicit per-VM disk/checkpoint-growth budget,
    not the virtual disk's maximum size or a claim about measured usage.
    ProvisioningMemoryBytes describes the peak sequential builder runtime before
    persisted VMs move to the VHD root. The initial and final runtime phases do
    not overlap, so a shared volume needs their maximum, not their sum.

    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$VMName,
        [hashtable]$StartupMemoryBytes = @{},
        [hashtable]$AdditionalStorageBytes = @{},
        [ValidateRange(0, [long]::MaxValue)][int64]$ReserveBytes = 2GB,
        [ValidateRange(0, [long]::MaxValue)][int64]$ProvisioningMemoryBytes = 0
    )
    $result = @{ allowed = $true; status = 'ready'; timestamp = [DateTime]::UtcNow.ToString('o'); source = 'Hyper-V VM storage admission'; errorCode = ''; reason = ''; volumes = @(); vms = @() }
    $groups = @{}
    $rows = [Collections.Generic.List[hashtable]]::new()
    $unknown = $false
    foreach ($name in @($VMName | Select-Object -Unique)) {
        $row = Get-HyperVVMStorageRequirement -VMName $name -StartupMemoryBytes $StartupMemoryBytes
        $rows.Add($row)
        if (-not $row.known) { $unknown = $true }
        [int64]$growth = 0
        if ($AdditionalStorageBytes.ContainsKey($name)) {
            if (-not [int64]::TryParse([string]$AdditionalStorageBytes[$name], [ref]$growth) -or $growth -lt 0) { throw "The additional storage budget for '$name' must be a nonnegative Int64 byte count." }
        }
        $row.additionalStorageBytes = $growth
        $requests = @(@{ path = $row.runtimePath; bytes = $row.additionalBytes; known = $row.known; purpose = 'runtime' })
        if ($growth -gt 0) { $requests += @{ path = $row.storagePath; bytes = $growth; known = [bool]$row.storagePath; purpose = 'disk-growth' } }
        foreach ($request in $requests) {
            $probe = if ($request.path) { Get-HyperVStorageVolume -Path $request.path } else { @{ known = $false; volume = ''; freeBytes = $null; reason = 'VM storage location is unavailable.' } }
            $key = if ($probe.volume) { [string]$probe.volume } else { "$name/$($request.purpose)" }
            if (-not $groups.ContainsKey($key)) {
                $groups[$key] = @{ volume = [string]$probe.volume; path = [string]$request.path; freeBytes = $probe.freeBytes; additionalBytes = [int64]0; runtimeBytes = [int64]0; provisioningBytes = [int64]0; requiredBytes = [int64]0; reserveBytes = [int64]0; known = [bool]$probe.known; vmNames = @(); reason = [string]$probe.reason }
            }
            $group = $groups[$key]
            # Repeated observations of a shared volume use the lower headroom.
            if (-not $probe.known) { $group.known = $false; $group.freeBytes = $null }
            elseif ($group.known) { $group.freeBytes = [Math]::Min([int64]$group.freeBytes, [int64]$probe.freeBytes) }
            if ($group.vmNames -notcontains $name) { $group.vmNames += $name }
            if ($request.known) {
                $sum = [decimal]$group.additionalBytes + [decimal]$request.bytes
                if ($sum -gt [int64]::MaxValue - $ReserveBytes) { throw 'The combined VM storage budget exceeds Int64 capacity.' }
                $group.additionalBytes = [int64]$sum
                if ($request.purpose -eq 'runtime') { $group.runtimeBytes += [int64]$request.bytes }
            } else { $unknown = $true }
            if (-not $probe.known) { $unknown = $true }
        }
    }
    if ($ProvisioningMemoryBytes -gt 0) {
        $configurationPath = ''
        try {
            $configurationPath = [string](Hyper-V\Get-VMHost -ErrorAction Stop).VirtualMachinePath
            if (-not $configurationPath) { throw 'The default Hyper-V configuration path is unavailable.' }
            $probe = Get-HyperVStorageVolume -Path $configurationPath
        } catch { $probe = @{ known = $false; volume = ''; freeBytes = $null; reason = $_.Exception.Message } }
        $result.provisioning = @{ path = $configurationPath; memoryBytes = $ProvisioningMemoryBytes; source = 'Hyper-V default configuration path' }
        $key = if ($probe.volume) { [string]$probe.volume } else { 'provisioning' }
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{ volume = [string]$probe.volume; path = $configurationPath; freeBytes = $probe.freeBytes; additionalBytes = [int64]0; runtimeBytes = [int64]0; provisioningBytes = [int64]0; requiredBytes = [int64]0; reserveBytes = [int64]0; known = [bool]$probe.known; vmNames = @(); reason = [string]$probe.reason }
        }
        $group = $groups[$key]
        $group.provisioningBytes = $ProvisioningMemoryBytes
        if (-not $probe.known) { $group.known = $false; $group.freeBytes = $null; $unknown = $true }
        elseif ($group.known) { $group.freeBytes = [Math]::Min([int64]$group.freeBytes, [int64]$probe.freeBytes) }
        $group.vmNames += '(sequential provisioning)'
    }
    $messages = [Collections.Generic.List[string]]::new()
    foreach ($group in $groups.Values) {
        $additional = [decimal]$group.additionalBytes - $group.runtimeBytes + [Math]::Max([int64]$group.runtimeBytes, [int64]$group.provisioningBytes)
        if ($additional -gt [int64]::MaxValue - $ReserveBytes) { throw 'The combined VM storage budget exceeds Int64 capacity.' }
        $group.additionalBytes = [int64]$additional
        if ($group.additionalBytes -gt 0) { $group.reserveBytes = $ReserveBytes }
        $group.requiredBytes = $group.additionalBytes + $group.reserveBytes
        if ($group.known -and $group.freeBytes -lt $group.requiredBytes) {
            $result.allowed = $false
            $messages.Add(("VM storage volume '{0}' for {1} has {2:N2} GiB available; {3:N2} GiB additional capacity is required including {4:N2} GiB reserve." -f $group.path, ($group.vmNames -join ', '), ($group.freeBytes / 1GB), ($group.requiredBytes / 1GB), ($group.reserveBytes / 1GB)))
        }
    }
    $result.vms = @($rows.ToArray())
    $result.volumes = @($groups.Values | Sort-Object path)
    if (-not $result.allowed) { $result.status = 'insufficient'; $result.errorCode = '0x80070070'; $result.reason = $messages -join ' ' }
    elseif ($unknown) { $result.status = 'unknown'; $result.reason = 'One or more VM storage locations or capacity readings are unavailable; Hyper-V will decide the start.' }
    return $result
}

function Get-HyperVStorageErrorCode {
    <#
    .SYNOPSIS
    Recognizes disk-full errors by numeric identity, including wrapped/localized errors.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$ErrorRecord)
    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord -as [Exception] }
    $text = [string]$ErrorRecord
    for ($depth = 0; $exception -and $depth -lt 8; $depth++) {
        if ($exception.HResult -eq -2147024784 -or (($exception -is [ComponentModel.Win32Exception]) -and $exception.NativeErrorCode -eq 112)) { return '0x80070070' }
        if ($exception.HResult -eq -2147024857 -or (($exception -is [ComponentModel.Win32Exception]) -and $exception.NativeErrorCode -eq 39)) { return '0x80070027' }
        $text += " $($exception.Message)"
        $exception = $exception.InnerException
    }
    if ($text -match '(?i)0x800700(70|27)\b') { return $Matches[0].ToUpperInvariant().Replace('0X', '0x') }
    return ''
}

<#
.SYNOPSIS
    Run one Hyper-V cmdlet call in a thread job under a wall-clock cap.
.DESCRIPTION
    Returns @{ TimedOut; Error; Output }. Error is the call's own ErrorRecord,
    kept intact (a thread job shares this process, so nothing is serialized),
    so a caller can rethrow it into the classification it already does. A
    call that reaches the cap is reported as timed out once its job is stopped;
    the stop is synchronous, so a call that does not honor PowerShell's stop
    request still holds the caller until it returns. The script block receives
    -ArgumentList and must stop on its own errors (-ErrorAction Stop) for them
    to reach Error. A job that ends without the answer object its body always
    emits never ran that body to the end, so it reports an Error naming the
    job's state, not an empty success that reads like a call which found
    nothing.
#>
function Invoke-HyperVBoundedCall {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = $script:HyperVLifecycleTimeoutSeconds
    )
    # The block travels as text: a script block is bound to the runspace that
    # created it, and invoking it from the job's thread would queue it back
    # onto this one, which is blocked waiting for the job.
    $job = Start-ThreadJob -ArgumentList (@($ScriptBlock.ToString()) + $ArgumentList) -ScriptBlock {
        $call = [scriptblock]::Create($args[0])
        $rest = @($args | Select-Object -Skip 1)
        try { [pscustomobject]@{ Ok = $true; Output = @(& $call @rest); Error = $null } }
        catch { [pscustomobject]@{ Ok = $false; Output = @(); Error = $_ } }
    }
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            return @{ TimedOut = $true; Error = $null; Output = @() }
        }
        $answer = Receive-Job -Job $job | Select-Object -Last 1
        if (-not $answer) {
            $reason = if ($job.JobStateInfo.Reason) { [string]$job.JobStateInfo.Reason.Message } else { '' }
            $message = Format-YurunaOperatorMessage -Key 'host.hyperv_bounded_call_no_answer' -Arguments @{ state = "$($job.State)"; reason = "$reason" }
            $noAnswer = [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new($message), 'HyperVBoundedCallNoAnswer',
                [Management.Automation.ErrorCategory]::InvalidResult, $null)
            return @{ TimedOut = $false; Error = $noAnswer; Output = @() }
        }
        return @{ TimedOut = $false; Error = $answer.Error; Output = @($answer.Output) }
    } finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Run one Hyper-V lifecycle cmdlet under the lifecycle cap, as if it had
    been called directly: its output is returned and its error is rethrown.
.DESCRIPTION
    A call that reaches the cap throws host.hyperv_lifecycle_unanswered, so
    the caller's existing catch reports it like any refusal, with a message
    that says the management service did not answer.
#>
function Invoke-HyperVLifecycleCmdlet {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Verb,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    $call = Invoke-HyperVBoundedCall -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    if ($call.TimedOut) {
        throw (Format-YurunaOperatorMessage -Key 'host.hyperv_lifecycle_unanswered' -Arguments @{ verb = "$Verb"; vMName = "$VMName"; seconds = "$script:HyperVLifecycleTimeoutSeconds" })
    }
    if ($call.Error) { throw $call.Error }
    return $call.Output
}

<#
.SYNOPSIS
    Run one Hyper-V cmdlet for a test-guest builder under the lifecycle cap,
    record the New-VM stage's failure kind, and return the cmdlet's output.
.DESCRIPTION
    The builders run as their own process and talk to the virtual machine
    management service directly, so each of their Hyper-V calls goes through
    the same cap as the driver's lifecycle verbs. -Command names the cmdlet
    module-qualified, because the call runs in a thread job that sees only
    modules it can load by name; -Parameter is splatted onto it. A call that
    does not answer records 'unresponsive' (hypervisor_unresponsive) and throws
    host.hyperv_lifecycle_unanswered; a refusal records 'tool' and rethrows the
    cmdlet's own error. With -Optional a refusal returns nothing instead, for a
    lookup whose absence is itself the answer; an unanswered call still throws.
#>
function Invoke-HyperVGuestBuildCmdlet {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidatePattern('^Hyper-V\\[A-Za-z]+-[A-Za-z]+$')][string]$Command,
        [hashtable]$Parameter = @{},
        [switch]$Optional
    )
    $call = Invoke-HyperVBoundedCall -ScriptBlock { param($Name, $Splat) & $Name @Splat -ErrorAction Stop } -ArgumentList $Command, $Parameter
    if ($call.TimedOut) {
        $message = Format-YurunaOperatorMessage -Key 'host.hyperv_lifecycle_unanswered' -Arguments @{ verb = "$Command"; vMName = "$VMName"; seconds = "$script:HyperVLifecycleTimeoutSeconds" }
        Write-YurunaProvisionResult -Kind 'unresponsive' -Message $message
        throw $message
    }
    if ($call.Error) {
        if ($Optional) {
            Write-Verbose "Invoke-HyperVGuestBuildCmdlet: $Command for '$VMName' refused: $($call.Error.Exception.Message)"
            return
        }
        $message = "${Command}: $($call.Error.Exception.Message)"
        # A refusal for want of system resources names the guest's size and
        # nothing about the host, and the figure a reader reaches for next,
        # free physical memory, misleads: the start was charged against the
        # commit limit, which a leaking parent partition exhausts with
        # gigabytes of physical memory still free. State the commit position
        # with the refusal, read before anything else moves.
        if (Test-HostResourceExhaustionError -ErrorRecord $call.Error) {
            $message += "; $(Format-HostMemoryStatus -Status (Get-HostMemoryStatus))"
        }
        Write-YurunaProvisionResult -Kind 'tool' -Message $message
        throw $call.Error
    }
    return $call.Output
}

<#
.SYNOPSIS
Start a Hyper-V VM and open a vmconnect window in basic mode.

.DESCRIPTION
Waits -- briefly, and only while the host is still handing memory back -- for
the host to hold the commit this guest is about to charge, calls
Hyper-V\Start-VM, then launches vmconnect.exe against localhost\$VMName
so screenshots and keystroke delivery work without guest integration tools.
After spawn it dismisses the "Another user is connected" dialog if vmconnect
raises it.

A start refused for want of system resources is retried ONCE, after a further
bounded wait, and ONLY that error is retried: the condition is transient by
nature -- the host is between releasing one guest's reservation and being able
to grant the next -- while every other start failure is a standing fault that a
second attempt merely delays the report of.

Checks the VM's actual runtime-state volume after the memory wait. A known
storage shortage refuses the start without a memory retry; an unavailable
storage probe preserves its unknown status and leaves the decision to Hyper-V.

Returns a hashtable @{ success; errorMessage; hostMemory; hostStorage; kind;
errorCode } so callers retain the resource evidence and numeric disk-full cause.
hostMemory
is the reading taken immediately before the attempt that decided the outcome,
so a failure record can state what the machine held at the instant it refused;
it is $null when the host would not state it. Read it with the indexer
($result['hostMemory']) rather than as a property -- the other host drivers do
not set the key, and under StrictMode a missing key read as a property throws.
#>
function Start-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$MemoryWaitSeconds = 20
    )
    # A VM costs the host more than the guest's own RAM: the worker process,
    # device emulation and the virtualization stack's own pages are charged
    # alongside it. Asking for the guest size alone would clear a preflight that
    # the start then fails; the margin only ever costs a wait that ends in a
    # start either way.
    $overheadBytes = 512MB
    $memory = $null
    $storage = $null
    $storageError = ''
    try {
        if ($PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_a3da8d2bcc4b8ff7'))) {
            # A VM that is already running holds its commit and a start against
            # it is a no-op, so there is nothing to wait for; asking anyway would
            # spend the whole budget before a call that was always going to
            # return immediately.
            $required = [int64]0
            try {
                if ((Get-VMState -VMName $VMName) -ne 'running') {
                    $required = Get-HyperVVMStartupMemory -VMName $VMName
                    if ($required -gt 0) { $required += $overheadBytes }
                }
            } catch {
                # Sizing the preflight is an optimization and nothing more. If
                # the VM will not state its size, there is simply nothing to
                # wait for -- the start still goes ahead and the hypervisor
                # still gets to state the outcome.
                Write-Verbose "Start-HyperVVM: '$VMName' would not state a size for the memory preflight: $($_.Exception.Message)"
                $required = [int64]0
            }
            $attempt = 0
            while ($true) {
                $null   = Wait-HostMemoryHeadroom -RequiredBytes $required -Label "'$VMName'" -TimeoutSeconds $MemoryWaitSeconds
                # Read both resource positions after any wait, before the
                # admission decision and the attempt they describe.
                $memory = Get-HostMemoryStatus
                $storage = Test-VMStorageCapacity -VMName $VMName
                if (-not $storage.allowed) {
                    return @{ success = $false; errorMessage = $storage.reason; hostMemory = $memory; hostStorage = $storage; kind = 'storage-capacity'; errorCode = $storage.errorCode }
                }
                try {
                    $call = Invoke-HyperVBoundedCall -ArgumentList @($VMName) -ScriptBlock {
                        param($Name)
                        Hyper-V\Start-VM -Name $Name -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
                    }
                    if ($call.TimedOut) {
                        $message = Format-YurunaOperatorMessage -Key 'host.hyperv_lifecycle_unanswered' -Arguments @{ verb = 'Start-VM'; vMName = "$VMName"; seconds = "$script:HyperVLifecycleTimeoutSeconds" }
                        return @{ success = $false; errorMessage = $message; hostMemory = $memory; hostStorage = $storage; kind = 'unresponsive'; errorCode = ''
                                  failureClass = [string](New-YurunaHostResult -Kind unresponsive).failureClass }
                    }
                    if ($call.Error) { throw $call.Error }
                    break
                } catch {
                    $storageError = Get-HyperVStorageErrorCode -ErrorRecord $_
                    if ($storageError -or $attempt -ge 1 -or -not (Test-HostResourceExhaustionError -ErrorRecord $_)) { throw }
                    $attempt++
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4c797db53595bac6' -Arguments @{ vMName = "$VMName"; memory = "$(Format-HostMemoryStatus -Status $memory)" })
                    # A fixed pause before the wait re-reads: the refusal can
                    # arrive before the host's own accounting has caught up, and
                    # a reading taken in that same instant looks healthy enough
                    # to end the wait immediately and retry into the same state.
                    Start-Sleep -Seconds 5
                }
            }
            # Open a vmconnect window in basic mode for screenshots / keystroke
            # delivery without requiring guest integration tools.
            $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
            if (Test-Path $vmconnect) {
                Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
                # No blind sleep here: the poll below already tolerates a
                # vmconnect that has not started yet (an empty Get-Process
                # match is just a 'pending' observation).
                [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
            }
        }
        return @{ success = $true; errorMessage = $null; hostMemory = $memory; hostStorage = $storage; kind = 'none'; errorCode = '' }
    } catch {
        # The reading from just before the failed attempt is the one that
        # describes the refusal; the fallback covers only a throw raised before
        # any attempt was made.
        if (-not $memory) { $memory = Get-HostMemoryStatus }
        if (-not $storageError) { $storageError = Get-HyperVStorageErrorCode -ErrorRecord $_ }
        if ($storage -and $storageError) { $storage.errorCode = $storageError }
        return @{ success = $false; errorMessage = (Format-YurunaOperatorMessage -Key 'host.operator_b97fb4abbfde180c' -Arguments @{ vMName = "$VMName"; value = "$_" }); hostMemory = $memory; hostStorage = $storage; kind = $(if ($storageError) { 'storage-capacity' } else { 'error' }); errorCode = $storageError }
    }
}

<#
.SYNOPSIS
Ask the guest OS to shut itself down, and wait for the VM to reach Off.

.DESCRIPTION
Hyper-V's Stop-VM WITHOUT -TurnOff is served by the Shutdown integration
component, so the guest unmounts and flushes before the disk stops
changing. -Force here only suppresses the logged-on-user confirmation
prompt; it does NOT turn the semantics into a power cut.

That distinction is load-bearing whenever the stop is followed by a
checkpoint. A -TurnOff is a virtual power cut: an ext4 guest with delayed
allocation loses every write still inside its writeback window (30s by
default), and files created in that window come back with their metadata
intact and size 0 -- while the same files' data blocks were never
allocated. Those zero-length files are then baked into the checkpoint and
reappear on every later restore. A 0-byte file with the +x bit still
executes as an empty script under bash (exit 0, no output), so a truncated
tool can survive a whole provisioning run without anything complaining.

The shutdown request runs in a background job so a hung vmms cannot block
the caller. A guest that cannot answer (no integration services, stuck at a
firmware prompt) makes Stop-VM return quickly without ever reaching Off; the
job-completed check below stops waiting out the full timeout in that case.

Returns $true when the VM is positively gone or reached Off, $false when the
guest did not follow through or its presence could not be established -- the
caller decides whether to escalate.
#>
function Request-HyperVVMShutdown {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$ShutdownTimeoutSeconds = 120
    )
    # A VM whose presence cannot be established is not stopped: returning
    # $false sends the caller to its escalation, which refuses the same way.
    $resolved = Resolve-HyperVVM -VMName $VMName
    if ($resolved.Presence -eq 'absent') { return $true }
    if ($resolved.Presence -ne 'present') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_state_unknown' -Arguments @{ operation = 'Stop-VM'; vMName = "$VMName" })
        return $false
    }
    $vm = $resolved.VM
    if ($vm.State -in @('Off', 'Saved', 'OffCritical')) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_8cb88c0dfdc75d37'))) { return $false }

    $shutdownJob = Start-Job -ScriptBlock {
        Hyper-V\Stop-VM -Name $using:VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
    try {
        $deadline    = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
        $jobDoneAt   = $null
        # Grace after the request returns: Stop-VM can hand back before the VM's
        # state has settled to Off, so a completed job is not by itself a refusal.
        $graceSeconds = 5
        while ((Get-Date) -lt $deadline) {
            $poll = Resolve-HyperVVM -VMName $VMName
            if ($poll.Presence -eq 'absent' -or ($poll.Presence -eq 'present' -and $poll.VM.State -eq 'Off')) { return $true }
            if ($poll.Presence -eq 'present') { $vm = $poll.VM }
            if ($shutdownJob.State -notin @('NotStarted', 'Running')) {
                if ($null -eq $jobDoneAt) { $jobDoneAt = Get-Date }
                elseif (((Get-Date) - $jobDoneAt).TotalSeconds -gt $graceSeconds) {
                    Write-Verbose "Request-HyperVVMShutdown: shutdown request for '$VMName' completed but the VM is '$($vm.State)'; the guest is not honoring it."
                    return $false
                }
            }
            Start-Sleep -Milliseconds 500
        }
    } finally {
        Stop-Job   -Job $shutdownJob -ErrorAction SilentlyContinue
        Remove-Job -Job $shutdownJob -Force -ErrorAction SilentlyContinue
    }
    return $false
}

<#
.SYNOPSIS
Stop a Hyper-V VM cleanly and close any matching vmconnect window.

.DESCRIPTION
Asks the guest to shut itself down first (Request-HyperVVMShutdown) so its
filesystem is flushed and consistent, and only escalates to
Stop-HyperVVMForce -- a -TurnOff plus vmwp.exe kill -- when the guest does
not reach Off in time. Callers that genuinely want the power cut (teardown,
where the disk is about to be deleted) call Stop-HyperVVMForce directly.

Then kills any vmconnect process whose window title references this VM so
the desktop doesn't accumulate stale viewer windows. Returns whether the VM
actually reached Off.
#>
function Stop-HyperVVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$ShutdownTimeoutSeconds = 120,
        [switch]$NoForce
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_1809ac610f9f348c'))) { return $true }
    $stopped = $false
    try {
        $stopped = [bool](Request-HyperVVMShutdown -VMName $VMName -ShutdownTimeoutSeconds $ShutdownTimeoutSeconds -Confirm:$false)
        # -NoForce: the guest ignored the request and the caller wants to look
        # at it before it is turned off, so the viewer is left in place too.
        if (-not $stopped -and $NoForce) {
            Write-Verbose "Stop-HyperVVM: '$VMName' did not stop within ${ShutdownTimeoutSeconds}s; -NoForce leaves it running."
            return $false
        }
        if (-not $stopped) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f3ac8c54b3ef36d7' -Arguments @{ vMName = "$VMName"; shutdownTimeoutSeconds = "${ShutdownTimeoutSeconds}" })
            $stopped = [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds 20 -Confirm:$false)
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_57c0e651cba9b6ec' -Arguments @{ vMName = "$VMName"; value = "$_" })
        $stopped = $false
    }
    Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($stopped) {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_f62df16b646f2313' -Arguments @{ vMName = "$VMName" })
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_df85cfa2ce176e71' -Arguments @{ vMName = "$VMName" })
    }
    return $stopped
}

<#
.SYNOPSIS
Wait for a Hyper-V VM to reach the Running state.

.DESCRIPTION
Polls Hyper-V\Get-VM every 5 seconds for up to $TimeoutSeconds
(default 120) and returns $true when State is Running. On timeout it
writes an error and returns $false so the caller can decide whether
to retry, stop the VM, or treat this as a fatal harness failure.
#>
function Confirm-HyperVVMStarted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName, [int]$TimeoutSeconds = 120)
    # See https://yuruna.link/42e220c4-0004
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -eq 'Running') {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_651f84ee3d7b34f4' -Arguments @{ vMName = "$VMName"; state = "$($vm.State)" })
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_df84c7ed1226f405' -Arguments @{ vMName = "$VMName"; timeoutSeconds = "${TimeoutSeconds}" })
    return $false
}

# See https://yuruna.link/42e220c4-0004
$script:VMConnectSettleSeconds = 3.0

<#
.SYNOPSIS
    Auto-dismiss vmconnect's "Another user is connected" prompt.
.DESCRIPTION
    Polls for the dialog and posts WM_COMMAND IDYES so the runner
    stays unattended. Returns $true if a dialog was dismissed,
    $false if none appeared (the healthy path).
#>
function Resolve-VMConnectAnotherUserDialog {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 8
    )
    if (-not $IsWindows) { return $false }
    if (-not ('YurunaVMConnectDialog' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class YurunaVMConnectDialog {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hParent, EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    const uint WM_COMMAND = 0x0111;
    const uint BM_CLICK   = 0x00F5;
    const int IDOK  = 1;
    const int IDYES = 6;

    private static string ChildText(IntPtr hWnd) {
        StringBuilder agg = new StringBuilder();
        EnumChildWindows(hWnd, (h, lp) => {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            agg.Append(sb.ToString()); agg.Append('\n');
            return true;
        }, IntPtr.Zero);
        return agg.ToString();
    }

    public static IntPtr FindDialog(uint[] vmconnectPids, string vmName) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            bool ours = false;
            for (int i = 0; i < vmconnectPids.Length; i++) {
                if (vmconnectPids[i] == pid) { ours = true; break; }
            }
            if (!ours) return true;
            var cls = new StringBuilder(64);
            GetClassName(hWnd, cls, 64);
            if (cls.ToString() != "#32770") return true;
            if (ChildText(hWnd).IndexOf(vmName, StringComparison.OrdinalIgnoreCase) >= 0) {
                found = hWnd; return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IsMainWindowReady(uint[] vmconnectPids, string vmName) {
        bool ready = false;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd) || IsIconic(hWnd) || !IsWindowEnabled(hWnd)) return true;
            uint pid; GetWindowThreadProcessId(hWnd, out pid);
            bool ours = false;
            for (int i = 0; i < vmconnectPids.Length; i++) {
                if (vmconnectPids[i] == pid) { ours = true; break; }
            }
            if (!ours) return true;
            var sb = new StringBuilder(512);
            GetWindowText(hWnd, sb, 512);
            if (sb.ToString().IndexOf(vmName, StringComparison.OrdinalIgnoreCase) >= 0) {
                ready = true; return false;
            }
            return true;
        }, IntPtr.Zero);
        return ready;
    }

    public static bool Dismiss(IntPtr hWnd) {
        SetForegroundWindow(hWnd);
        System.Threading.Thread.Sleep(120);
        SendMessage(hWnd, WM_COMMAND, (IntPtr)IDYES, IntPtr.Zero);
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            SendMessage(hWnd, WM_COMMAND, (IntPtr)IDOK, IntPtr.Zero);
        }
        System.Threading.Thread.Sleep(200);
        if (IsWindowVisible(hWnd)) {
            EnumChildWindows(hWnd, (h, lp) => {
                var cls = new StringBuilder(64);
                GetClassName(h, cls, 64);
                if (string.Equals(cls.ToString(), "Button", StringComparison.OrdinalIgnoreCase)) {
                    var t = new StringBuilder(128);
                    GetWindowText(h, t, 128);
                    string text = t.ToString();
                    if (text.IndexOf("Yes",     StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("Connect", StringComparison.OrdinalIgnoreCase) >= 0 ||
                        text.IndexOf("OK",      StringComparison.OrdinalIgnoreCase) >= 0) {
                        SendMessage(h, BM_CLICK, IntPtr.Zero, IntPtr.Zero);
                    }
                }
                return true;
            }, IntPtr.Zero);
        }
        return true;
    }
}
"@
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $readyStreak = 0
    $neededStreak = [Math]::Ceiling($script:VMConnectSettleSeconds / 0.25)
    while ((Get-Date) -lt $deadline) {
        $observation = Get-VMConnectWindowState -VMName $VMName
        if ($observation.State -eq 'dialog') {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_94dcd74cd5ca1780' -Arguments @{ vMName = "$VMName" })
            [void][YurunaVMConnectDialog]::Dismiss($observation.Handle)
            Start-Sleep -Milliseconds 600
            return $true
        }
        if ($observation.State -eq 'ready') {
            $readyStreak++
            # A dialog can still appear after the main window first settles; a
            # streak (not a one-shot check) is what step 1's measured/fallback D
            # is sized against, so this must count observations, not stop early.
            if ($readyStreak -ge $neededStreak) { return $false }
        } else {
            $readyStreak = 0
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-VMConnectWindowState {
<#
.SYNOPSIS
    One observation of the vmconnect viewer for $VMName: a dialog (with its
    handle), a settled main window, or neither yet.
.DESCRIPTION
    Separated from Resolve-VMConnectAnotherUserDialog's wait loop so the
    settle streak can be driven by a scripted sequence of states without a
    desktop.
.OUTPUTS
    [pscustomobject] State ('dialog' | 'ready' | 'pending'), Handle (IntPtr,
    set only for 'dialog').
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    $vmconnectPids = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
        ForEach-Object { [uint32]$_.Id })
    if ($vmconnectPids.Count -eq 0) { return [pscustomobject]@{ State = 'pending'; Handle = [IntPtr]::Zero } }
    $hWnd = [YurunaVMConnectDialog]::FindDialog([uint32[]]$vmconnectPids, $VMName)
    if ($hWnd -ne [IntPtr]::Zero) { return [pscustomobject]@{ State = 'dialog'; Handle = $hWnd } }
    if ([YurunaVMConnectDialog]::IsMainWindowReady([uint32[]]$vmconnectPids, $VMName)) {
        return [pscustomobject]@{ State = 'ready'; Handle = [IntPtr]::Zero }
    }
    return [pscustomobject]@{ State = 'pending'; Handle = [IntPtr]::Zero }
}

<#
.SYNOPSIS
Close and re-open the vmconnect viewer for a Hyper-V VM.

.DESCRIPTION
Closes any vmconnect.exe whose main window title matches $VMName
(graceful CloseMainWindow, then Stop-Process -Force after a 3-second
wait), then re-launches vmconnect against localhost\$VMName and
auto-dismisses the "Another user is connected" prompt. Used to refresh
a stalled viewer mid-run when keystroke delivery or screenshot capture
starts failing.
#>
function Restart-HyperVConnect {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vmconnect = "$env:SystemRoot\System32\vmconnect.exe"
    if (-not (Test-Path $vmconnect)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_00df328f839cec6c'))) { return $false }
    $existing = @(Get-Process -Name "vmconnect" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) })
    foreach ($p in $existing) {
        try { [void]$p.CloseMainWindow() } catch { Write-Verbose "CloseMainWindow failed for vmconnect pid $($p.Id): $_" }
    }
    foreach ($p in $existing) {
        if (-not $p.WaitForExit(3000)) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { Write-Verbose "Force-kill of vmconnect pid $($p.Id) failed: $_" }
        }
    }
    if ($existing.Count -gt 0) { Start-Sleep -Seconds 3 }
    Start-Process -FilePath $vmconnect -ArgumentList "localhost", $VMName
    # No blind sleep here either: see the matching comment at the other call site.
    [void](Resolve-VMConnectAnotherUserDialog -VMName $VMName -TimeoutSeconds 8)
    Write-Verbose "    Reconnected vmconnect for '$VMName'"
    return $true
}
