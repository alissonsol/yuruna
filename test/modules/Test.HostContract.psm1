<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42a04c70-e7da-4354-977e-5dd4778e74a0
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

# See https://yuruna.link/4213a0b3-007b

# See https://yuruna.link/4213a0b3-007c
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking

$siblingModules = @(
    'Test.HostDetection.psm1',
    'Test.HostCondition.psm1',
    'Test.HostGit.psm1',
    'Test.HostBootstrap.psm1'
)
foreach ($mod in $siblingModules) {
    $p = Join-Path $PSScriptRoot $mod
    if (Test-Path $p) {
        Import-Module $p -Global -Force -DisableNameChecking
    }
}

function Stop-ConcurrentVM {
    <#
    .SYNOPSIS
        Stop every running VM the cycle is not allowed to share the host
        with. Returns $true when none remain running.
    .DESCRIPTION
        A leftover guest from a cycle that died before its teardown keeps
        running, and the next cycle cannot use the host until it is gone.
        Telling the operator to stop it by hand turns one failed cycle into
        an indefinite outage: the sweep that would clear it only runs once a
        cycle starts, and the cycle refuses to start while it is running.
        This breaks that loop by issuing the stop the operator would have
        typed.

        Stops, never deletes. A running VM this function does not recognize
        may be something the operator cares about; a stop is recoverable and
        a delete is not. Guests that are the framework's own to discard are
        removed by name prefix in the cycle sweep (Remove-TestVMFiles.ps1),
        where the prefix is what proves they are disposable.

        Host-neutral: enumeration and lifecycle both go through the host
        contract, so this behaves the same on UTM, Hyper-V and libvirt.
    .PARAMETER AlwaysAllow
        VM names that may keep running. The service VMs are infrastructure the
        cycle CONSUMES, not competitors for the host: the caching proxy serves
        every guest install, the stash service receives the build's binaries, and
        the pool-control service serves the intent store, and the download
        agent supplies base images. Stopping one at cycle
        start does not free the host for the cycle, it removes something the
        cycle is about to require -- the stash service in particular fails the
        very first orchestration step, which refuses to provision when nothing
        answers /healthz.

        A service VM stopped this way is also stopped WITHOUT its marker being
        cleared (Stop-StashServiceVM.ps1 owns that), so the dashboard keeps
        advertising a service that is no longer running.

        The defaults are the four shipped service VM names. An operator who
        renames one with -VMName passes the new name here.
    .PARAMETER ExceptVmName
        A VM to leave alone -- the dev loop where an operator re-runs a
        sequence against a guest they left up on purpose.
    .OUTPUTS
        [bool] $true when it enumerated the host and nothing disallowed is
        still running; $false when a VM would not stop, or when the host could
        not be enumerated (no driver loaded, or the inventory failed). It does
        not decide whether a cycle may start -- Get-VmAdmission does, from a
        fresh read -- and its return never claims a clean host it did not see.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [string[]]$AlwaysAllow = (Get-YurunaServiceVmName),
        [string]$ExceptVmName
    )
    if (-not (Get-Command Get-VMName -ErrorAction SilentlyContinue)) {
        Write-Verbose "Stop-ConcurrentVM: no host driver loaded; nothing was enumerated."
        return $false
    }
    try {
        $all = @(Get-VMName)
    } catch {
        # "Could not ask the host" is not "nothing is running". Report it and
        # say so in the return value; the admission check that follows decides
        # whether a cycle may start on a host that could not be read.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2cf896e3e62bdec5' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    $stillRunning = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $all) {
        if ($AlwaysAllow -contains $name) { continue }
        if ($ExceptVmName -and $name -eq $ExceptVmName) { continue }
        if ((Get-VMState -VMName $name) -ne 'running') { continue }
        if (-not $PSCmdlet.ShouldProcess($name, (Format-YurunaOperatorMessage -Key 'runner.operator_984c43950954554c'))) { continue }
        # Progress goes to the information stream, never the success stream:
        # this function's output IS its return value, so a Write-Output here
        # would make it return an array whose truthiness is always $true --
        # a caller testing `-not (Stop-ConcurrentVM)` would then never refuse.
        Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'runner.operator_56c32c1062db2379' -Arguments @{ name = "$name" }) -InformationAction Continue
        try {
            [void](Stop-VMForce -VMName $name -Confirm:$false)
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c28697ef783ec9f0' -Arguments @{ name = "$name"; message = "$($_.Exception.Message)" })
        }
        if ((Get-VMState -VMName $name) -eq 'running') { [void]$stillRunning.Add($name) }
    }
    if ($stillRunning.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e10e72b69afe78cd' -Arguments @{ join = "$($stillRunning -join ', ')" })
        return $false
    }
    return $true
}

function Get-VmAdmission {
    <#
    .SYNOPSIS
        One answer to "is the host free of VMs a cycle may not share it with?":
        clear, occupied or unknown.
    .DESCRIPTION
        Two cycles on one VM set corrupt each other, so a cycle may start only on
        a host it has positively found empty of other guests. That is a three-way
        question, not a boolean:

          clear     the inventory was read and nothing outside the allow-list is
                    running.
          occupied  at least one VM outside the allow-list is running.
          unknown   the inventory could not be read, or the state of some VM could
                    not be determined, on every attempt. Nothing was seen
                    running, and nothing was shown not to be.

        "Could not ask the host" is never "nothing is running". A host contract
        driver throws when its inventory fails, and reports a VM whose state it
        cannot determine as 'unknown'; both land here as unknown, after a bounded
        number of re-reads, because a CLI that is merely slow answers the second
        time and one that is wedged does not. A VM seen running decides the answer
        immediately, whatever else could not be read.
    .PARAMETER AlwaysAllow
        VM names that may keep running: the service VMs, which are infrastructure
        the cycle consumes (see Stop-ConcurrentVM).
    .PARAMETER ExceptVmName
        A VM to leave out of the question -- the dev loop where an operator
        re-runs a sequence against a guest they left up on purpose.
    .PARAMETER MaxProbes
        How many times the inventory is read before the answer is unknown.
    .PARAMETER ProbeDelaySeconds
        Pause between reads.
    .OUTPUTS
        [pscustomobject] State (clear | occupied | unknown), Reason (ok |
        running-vm | no-host-driver | inventory-failed | state-unverified),
        Occupants (the running VMs), Probes (reads made), Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$AlwaysAllow = (Get-YurunaServiceVmName),
        [string]$ExceptVmName,
        [ValidateRange(1, 10)][int]$MaxProbes = 3,
        [ValidateRange(0, 60)][int]$ProbeDelaySeconds = 3
    )
    $verdict = {
        param([string]$State, [string]$Reason, [string[]]$Occupants, [int]$Probes, [string]$Detail)
        [pscustomobject]@{ State = $State; Reason = $Reason; Occupants = @($Occupants); Probes = $Probes; Detail = $Detail }
    }
    if (-not (Get-Command Get-VMName -ErrorAction SilentlyContinue) -or -not (Get-Command Get-VMState -ErrorAction SilentlyContinue)) {
        return (& $verdict 'unknown' 'no-host-driver' @() 0 'the host driver functions Get-VMName and Get-VMState are not loaded')
    }
    $reason = 'inventory-failed'
    $detail = ''
    for ($probe = 1; $probe -le $MaxProbes; $probe++) {
        $running = [System.Collections.Generic.List[string]]::new()
        $unverified = [System.Collections.Generic.List[string]]::new()
        $failure = ''
        $names = @()
        try { $names = @(Get-VMName) } catch { $failure = "the inventory failed: $($_.Exception.Message)" }
        if (-not $failure) {
            foreach ($name in $names) {
                if ($AlwaysAllow -contains $name) { continue }
                if ($ExceptVmName -and $name -eq $ExceptVmName) { continue }
                $state = 'unknown'
                try { $state = [string](Get-VMState -VMName $name) } catch { $state = 'unknown' }
                if ($state -eq 'running') { [void]$running.Add($name) }
                elseif ($state -notin @('stopped', 'absent')) { [void]$unverified.Add($name) }
            }
        }
        if ($running.Count -gt 0) { return (& $verdict 'occupied' 'running-vm' $running.ToArray() $probe '') }
        if (-not $failure -and $unverified.Count -eq 0) { return (& $verdict 'clear' 'ok' @() $probe '') }
        $reason = if ($failure) { 'inventory-failed' } else { 'state-unverified' }
        $detail = if ($failure) { $failure } else { "the state of $($unverified -join ', ') could not be determined" }
        if ($probe -lt $MaxProbes -and $ProbeDelaySeconds -gt 0) { Start-Sleep -Seconds $ProbeDelaySeconds }
    }
    return (& $verdict 'unknown' $reason @() $MaxProbes $detail)
}

function Write-VmAdmissionRecord {
    <#
    .SYNOPSIS
        Records the cycle-start admission verdict beside the other runtime
        sidecars, so the runner that spawned this process can say WHY the cycle
        did not run.
    .DESCRIPTION
        The refusing process exits with a bare code, and a bare code reads as
        "the tests failed". The outer runner picks this record up (when it is
        newer than the cycle it just ran) to name the fault for what it is: a
        host that could not show it was free of other guests. Written on every
        verdict, a clear one included, so a later cycle's record replaces an
        older refusal instead of leaving it to be read as current.
    .OUTPUTS
        [bool] $true when the record was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Admission,
        [string]$HostType,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    if ([string]::IsNullOrWhiteSpace($RuntimeDir) -or -not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) { return $false }
    if (-not (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)) {
        $stateModule = Join-Path $PSScriptRoot 'Test.StateFile.psm1'
        if (Test-Path -LiteralPath $stateModule) { Import-Module $stateModule -Global -ErrorAction SilentlyContinue }
        if (-not (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue)) { return $false }
    }
    $path = Join-Path $RuntimeDir 'vm-admission.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'Record the VM admission verdict')) { return $false }
    $record = [ordered]@{
        schemaVersion = 1
        state         = [string]$Admission.State
        reason        = [string]$Admission.Reason
        occupants     = @($Admission.Occupants)
        probes        = [int]$Admission.Probes
        detail        = [string]$Admission.Detail
        hostType      = [string]$HostType
        observedUtc   = (Get-Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    return [bool](Write-YurunaStateFileJson -Path $path -InputObject $record -Depth 4 -Confirm:$false)
}

function Invoke-HostVmAdmission {
    <#
    .SYNOPSIS
        The cycle-start check every entry point runs: stop what is left over,
        then require the host to be provably free of other guests.
    .DESCRIPTION
        One implementation for the runner, the project run and the sequence
        runner, so the three cannot disagree about what a host must look like
        before a cycle starts. A leftover guest from a cycle that died before its
        teardown is the common case, and refusing over it strands the host (the
        sweep that would remove it only runs once a cycle starts), so a running
        guest is stopped first and the host asked again. What is left decides:

          clear     proceed.
          occupied  refuse. A guest would not stop, or is not the framework's to
                    stop; the message names it.
          unknown   refuse. The host could not show it was free. Proceeding on a
                    guess is how two cycles end up on one VM set; refusing costs
                    one cycle on a host whose hypervisor CLI is wedged, and says
                    so.

        The verdict is recorded (Write-VmAdmissionRecord) whatever it is. The
        caller exits on anything but 'clear': 1 for occupied, 2 (cannot run) for
        unknown, so the two read differently to whoever looks at the exit code.
    .PARAMETER HostType
        The host type string; on macOS UTM an occupied host also gets that
        driver's explanation of why concurrent guests split the vmnet bridge.
    .PARAMETER ExceptVmName
        A VM to leave alone (the dev loop's target).
    .OUTPUTS
        [pscustomobject] the Get-VmAdmission verdict of the final read.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$HostType,
        [string]$ExceptVmName,
        [ValidateRange(1, 10)][int]$MaxProbes = 3,
        [ValidateRange(0, 60)][int]$ProbeDelaySeconds = 3,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    $admission = Get-VmAdmission -ExceptVmName $ExceptVmName -MaxProbes $MaxProbes -ProbeDelaySeconds $ProbeDelaySeconds
    if ($admission.State -eq 'occupied') {
        $null = Stop-ConcurrentVM -ExceptVmName $ExceptVmName
        $admission = Get-VmAdmission -ExceptVmName $ExceptVmName -MaxProbes $MaxProbes -ProbeDelaySeconds $ProbeDelaySeconds
    }
    switch ($admission.State) {
        'occupied' {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.vm_admission_occupied' -Arguments @{ occupants = "$($admission.Occupants -join ', ')" })
            if ($HostType -eq 'host.macos.utm' -and (Get-Command Assert-NoConcurrentUtmVm -ErrorAction SilentlyContinue)) {
                $null = Assert-NoConcurrentUtmVm -ExceptVmName $ExceptVmName
            }
        }
        'unknown' {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.vm_admission_unknown' -Arguments @{ probes = "$($admission.Probes)"; reason = "$($admission.Reason)"; detail = "$($admission.Detail)" })
        }
    }
    $null = Write-VmAdmissionRecord -Admission $admission -HostType $HostType -RuntimeDir $RuntimeDir -Confirm:$false
    return $admission
}

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Initialize-YurunaHost, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Test-HostRequirement, Assert-HostConditionSet, Initialize-SudoCache, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Set-MacHostConditionSet, Set-MacUtmctlLink, Get-MacUtmctlRemediation, Set-MacScreenLockState, Get-MacScreenLockManualCommand, Get-MacScreenLockIssue, Get-MacSessionKind, Get-MacTccSubjectName, Get-MacOperatorGrant, Get-MacOperatorGrantState, Get-MacOperatorGrantInstruction, Assert-MacOperatorGrant, Invoke-MacOperatorGrantAssist, Set-WindowsHostConditionSet, Invoke-GitPull, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone, Test-GitRemoteAuthFailure, Write-GitAuthRefreshBanner, Stop-ConcurrentVM, Get-VmAdmission, Write-VmAdmissionRecord, Invoke-HostVmAdmission, Get-MacDisplayScaleProfile, Get-MacDisplayScaleIssue, Get-WindowsDisplayScaleSetting, Get-WindowsDisplayScaleIssue
