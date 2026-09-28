<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4264541c-67da-418e-bf26-a11eb9662af8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host linux kvm libvirt
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

# Linux / KVM sibling of Test.HostCondition.psm1. Mirrors the per-platform
# layout that Mac and Windows already follow: Set/Assert pair (used by
# the registry dispatcher) plus Test-LinuxHostMinimum (the quick check
# Test-HostRequirement runs from one-off operator helpers). The
# diagnostic logic for Assert lives here, not in the facade, so the
# facade stays pure dispatch and a future libvirt-side check has an
# obvious home.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
# Invoke-BoundedNativeCommand bounds the group reads below. Imported -Global and
# without -Force so an already-loaded copy, whose commands other modules hold,
# is reused instead of being evicted into this module's private scope.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
function Read-LibvirtGroupFact {
    <#
    .SYNOPSIS
        One bounded identity read for Get-LibvirtGroupState: the trimmed stdout
        and whether the read is a complete answer.
    .DESCRIPTION
        The read's cap is whatever remains of the caller's budget, so several
        reads in sequence share one bound instead of each taking the full
        allowance. With less than one whole second left nothing is launched
        and the read is reported as not attempted.

        Complete requires a launched process that finished inside the cap
        with both streams drained, nothing truncated or left unkilled, and an
        exit code listed in CompleteExitCode; anything less is not evidence
        about group membership.
    .PARAMETER Deadline
        The budget all reads of one Get-LibvirtGroupState call share.
    .PARAMETER Ceiling
        Upper bound on this one read, in seconds.
    .PARAMETER CompleteExitCode
        Exit codes that are a finished answer for this tool. getent exits 2
        for a key that does not exist, which is an answer, not a failure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgument = @(),
        [Parameter(Mandatory)][ValidateNotNull()][psobject]$Deadline,
        [ValidateRange(1, 60)][int]$Ceiling = 5,
        [int[]]$CompleteExitCode = @(0)
    )
    $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling $Ceiling
    if ($null -eq $cap) {
        return [pscustomobject]@{ Attempted = $false; Complete = $false; ExitCode = -1; Text = '' }
    }
    $result = Invoke-BoundedNativeCommand -FilePath $Tool -ArgumentList $ToolArgument -TimeoutSeconds $cap -Deadline $Deadline
    $complete = (Test-BoundedNativeResultComplete -Result $result) -and ([int]$result.ExitCode -in $CompleteExitCode)
    return [pscustomobject]@{
        Attempted = $true
        Complete  = [bool]$complete
        ExitCode  = [int]$result.ExitCode
        Text      = ([string]$result.StdOut).Trim()
    }
}

function Get-LibvirtGroupState {
    <#
    .SYNOPSIS
        Reads the libvirt group picture two callers both need: the
        calling process's RUNNING supplementary group set and the
        libvirt group's membership per /etc/group.
    .DESCRIPTION
        Returns a hashtable with:
          ActiveGroups   -- the running shell's supplementary group set
                            (from `id -nG`), always an array; what actually
                            governs socket access, and what a stale
                            `usermod -aG` does NOT refresh.
          LibvirtMembers -- the libvirt group's members per `getent group
                            libvirt`, always an array. getent joins members
                            with commas and no spaces; the last token can
                            carry a trailing newline, so each token is
                            trimmed and empties dropped -- otherwise a
                            `-contains $user` test can miss the last,
                            newline-suffixed member. A libvirt group that
                            does not exist (getent exit 2) is a complete
                            answer with no members.
          CurrentUser    -- the process's real user name (`id -un`), or ''
                            when it could not be read. $env:USER is not a
                            substitute: under sg/newgrp/sudo/systemd the
                            inherited value can be empty or name someone else.
          Resolved       -- $true only when all three reads launched,
                            finished inside the budget with fully drained
                            output and a recognized exit code. A caller
                            classifying a permission fault treats anything
                            else as unknown rather than as "not a member".
        The ActiveGroups-vs-LibvirtMembers gap is the classic
        "member in /etc/group but not in the live group set" case that
        makes libvirt-sock return Permission denied until the group set
        is refreshed (sg / newgrp / reboot).

        Each read runs through Invoke-BoundedNativeCommand: getent consults
        NSS, which on a host joined to a directory service can block on the
        network, and a hypervisor probe that reuses this diagnosis must stay
        inside its own deadline. A read that fails contributes an empty value
        and clears Resolved; once the budget is spent the remaining reads are
        skipped.
    .PARAMETER TimeoutSeconds
        Budget for all three reads together, not for each one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([ValidateRange(1, 60)][int]$TimeoutSeconds = 5)
    $budget = New-YurunaDeadline -TotalMilliseconds ([long]$TimeoutSeconds * 1000)
    $reads = [ordered]@{
        groups = @{ Tool = 'id'; ToolArgument = @('-nG'); CompleteExitCode = @(0) }
        user   = @{ Tool = 'id'; ToolArgument = @('-un'); CompleteExitCode = @(0) }
        entry  = @{ Tool = 'getent'; ToolArgument = @('group', 'libvirt'); CompleteExitCode = @(0, 2) }
    }
    $fact = @{}
    foreach ($name in @($reads.Keys)) {
        $read = $reads[$name]
        $fact[$name] = Read-LibvirtGroupFact -Tool $read.Tool -ToolArgument $read.ToolArgument `
            -CompleteExitCode $read.CompleteExitCode -Deadline $budget -Ceiling $TimeoutSeconds
        if (-not $fact[$name].Attempted) { break }
    }
    $resolved = $true
    foreach ($name in @($reads.Keys)) {
        if (-not $fact.ContainsKey($name) -or -not $fact[$name].Complete) { $resolved = $false }
    }
    # Assigned inside a statement, never from an if-expression: the pipeline
    # an if-expression returns unrolls a one-group set to a bare string and an
    # empty one to $null.
    $activeGroups = @()
    if ($fact.ContainsKey('groups') -and $fact.groups.Complete -and $fact.groups.Text) {
        $activeGroups = @($fact.groups.Text -split '\s+' | Where-Object { $_ })
    }
    $currentUser = ''
    if ($fact.ContainsKey('user') -and $fact.user.Complete) { $currentUser = $fact.user.Text }
    $libvirtMembers = @()
    if ($fact.ContainsKey('entry') -and $fact.entry.Complete -and $fact.entry.ExitCode -eq 0) {
        $fields = $fact.entry.Text -split ':', 4
        if ($fields.Count -eq 4) {
            $libvirtMembers = @($fields[3] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        } else {
            $resolved = $false
        }
    }
    return @{
        ActiveGroups   = $activeGroups
        LibvirtMembers = $libvirtMembers
        CurrentUser    = $currentUser
        Resolved       = $resolved
    }
}

function Sync-LinuxHostClock {
    <#
    .SYNOPSIS
        Put the host clock back under NTP discipline via timedatectl.
        Returns @{ Succeeded; Message }.
    .DESCRIPTION
        libvirt seeds each guest's clock from this host at power-on. What a
        drifted clock then does to a guest:
        https://yuruna.link/42d38664-001a

        `timedatectl set-ntp true` is the durable half. Restarting the
        active sync daemon afterwards is the immediate half: enabling NTP
        does not itself step a clock that is already hours out, and
        systemd-timesyncd only steps on start.

        Reports rather than throws, and never prompts (`sudo -n`): a
        scripted host-prep run blocked on a hidden password prompt is a
        hang, not a failed clock sync. An interactive caller that wants
        the sync to succeed primes the credential cache first
        (Initialize-SudoCache), which asks once and visibly.
    .OUTPUTS
        [hashtable] Succeeded (bool), Message (string).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param()

    if (-not $IsLinux) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_2cabc360ec407ae8') }
    }
    if (-not (Get-Command timedatectl -ErrorAction SilentlyContinue)) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_55f10ef5009ca033') }
    }
    $manual = (Format-YurunaOperatorMessage -Key 'runner.operator_fc482441ba59283e')
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_ab78290b0162b326'), (Format-YurunaOperatorMessage -Key 'runner.operator_5b2ab60cf43c713c'))) {
        return @{ Succeeded = $false; Message = 'Skipped (WhatIf).' }
    }

    $ntpOut = & sudo -n timedatectl set-ntp true 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Succeeded = $false; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_1bf17ab0244b3137' -Arguments @{ trim = "$(($ntpOut | Out-String).Trim())"; manual = "$manual" }) }
    }
    $steps = @('NTP enabled')

    # Whichever daemon this host actually runs -- chrony steps on demand,
    # timesyncd only on start. A host with neither still counts as synced:
    # set-ntp succeeded, so something is disciplining the clock.
    # Coerce before .Trim(): a missing unit makes (& ...) return $null, and
    # $null.Trim() throws (same guard as Assert-LinuxHostConditionSet).
    $chronyRaw   = & systemctl is-active chrony 2>$null
    $chronydRaw  = & systemctl is-active chronyd 2>$null
    $timesyncRaw = & systemctl is-active systemd-timesyncd 2>$null
    $chronyState   = if ($chronyRaw)   { "$chronyRaw".Trim() }   else { '' }
    $chronydState  = if ($chronydRaw)  { "$chronydRaw".Trim() }  else { '' }
    $timesyncState = if ($timesyncRaw) { "$timesyncRaw".Trim() } else { '' }
    if ($chronyState -eq 'active' -or $chronydState -eq 'active') {
        $stepOut = & sudo -n chronyc makestep 2>&1
        if ($LASTEXITCODE -eq 0) { $steps += 'chrony stepped' }
        else { Write-Verbose "chronyc makestep: $(($stepOut | Out-String).Trim())" }
    } elseif ($timesyncState -eq 'active') {
        $restartOut = & sudo -n systemctl restart systemd-timesyncd 2>&1
        if ($LASTEXITCODE -eq 0) { $steps += 'timesyncd restarted' }
        else { Write-Verbose "systemctl restart systemd-timesyncd: $(($restartOut | Out-String).Trim())" }
    }
    return @{ Succeeded = $true; Message = (Format-YurunaOperatorMessage -Key 'runner.operator_e8c769a3703de6a4' -Arguments @{ join = "$($steps -join ', ')" }) }
}

function Assert-LinuxHostConditionSet {
    <#
    .SYNOPSIS
        Single gate for Linux / KVM prerequisites: virsh round-trip,
        /dev/kvm character device, libvirtd active (or its activation
        socket listening), current shell's supplementary group set
        includes libvirt.
    .DESCRIPTION
        Returns $true on non-Linux (the registry only dispatches to
        this for the matching HostType, but the guard keeps the
        function safe to call directly) or when all conditions pass;
        $false with diagnostics on failure. Diagnostics distinguish
        the four common failure modes so the operator gets actionable
        steps, not a generic "permission denied".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    if ($HostType -ne 'host.ubuntu.kvm') { return $true }
    # --- REGION: https://yuruna.link/42d38664-001a
    # Warn-only and once per cycle: the repair needs a privilege this process
    # cannot ask for, so a drifted host runs and says so rather than refusing
    # every cycle until an operator notices.
    Write-HostClockDriftWarning -HostType $HostType
    # The runner calls Initialize-YurunaHost before invoking this
    # function; that imports host/ubuntu.kvm/modules/Yuruna.Host.psm1
    # for host.ubuntu.kvm, so Assert-Virtualization is in scope here.
    if (Get-Command Assert-Virtualization -ErrorAction SilentlyContinue) {
        if (Assert-Virtualization) { return $true }
    }
    # --- REGION: Diagnose which precondition failed
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_43e66f1b323df1ce')
        return $false
    }
    # Coerce before .Trim(): a missing systemctl / empty output makes (& ...) return $null, and
    # $null.Trim() throws "cannot call a method on a null-valued expression".
    $raw = & systemctl is-active libvirtd 2>$null
    $active = if ($raw) { "$raw".Trim() } else { '' }
    if ($active -ne 'active') {
        # libvirtd runs with an idle timeout under socket activation: with no
        # client and no running domain it exits, and the listening socket
        # starts it again on the next connection. An inactive service behind an
        # active socket is therefore healthy, and the diagnosis continues to
        # the group checks below instead of blaming the daemon.
        $socketRaw = & systemctl is-active libvirtd.socket 2>$null
        $socketActive = if ($socketRaw) { "$socketRaw".Trim() } else { '' }
        if ($socketActive -ne 'active') {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5bd775f79ee13443' -Arguments @{ active = "$active" })
            return $false
        }
    }
    # libvirtd up, /dev/kvm present, but the round-trip failed -- the
    # by-far most common cause is a stale supplementary group set on
    # the calling shell. Detect that case specifically so the operator
    # gets actionable steps, not a generic "permission denied".
    $groupState     = Get-LibvirtGroupState
    # An unfinished group read leaves the member list empty, and reading that
    # as "not in the libvirt group" would send the operator to re-run the
    # installer for a membership that may well be in place.
    if (-not $groupState.Resolved) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_71200c53c662e070')
        return $false
    }
    $activeGroups   = $groupState.ActiveGroups
    $libvirtMembers = $groupState.LibvirtMembers
    # Use the process's REAL identity, not $env:USER: under sg/newgrp/sudo/systemd
    # the inherited USER can be empty or wrong, which would select the wrong
    # remediation branch -- the opposite of the actionable diagnostics intended.
    # A failed read already returned above; $env:USER only covers an `id -un`
    # that finished but printed nothing.
    $me = [string]$groupState.CurrentUser
    if (-not $me) { $me = $env:USER }
    $me = ([string]$me).Trim()
    if ($libvirtMembers -contains $me -and $activeGroups -notcontains 'libvirt') {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_6086c8f7e49eae24' -Arguments @{ me = "$me" })
        return $false
    }
    if ($libvirtMembers -notcontains $me) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_af9331d7fcad1b25' -Arguments @{ me = "$me" })
        return $false
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_71200c53c662e070')
    return $false
}

function Test-LinuxHostMinimum {
    <#
    .SYNOPSIS
        KVM quick-check for [Test-HostRequirement] (virsh on PATH +
        /dev/kvm present). Emits actionable warnings on failure and
        returns $false; emits nothing and returns $true when both
        conditions are met.
    .DESCRIPTION
        Lighter than Assert-LinuxHostConditionSet (which also gates
        on libvirtd-active + libvirt-group membership) -- this exists
        for one-off operator helpers (Remove-OrphanedVMFiles.ps1 etc.)
        where the libvirtd / group checks would be confusing during
        interactive maintenance run via sudo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $ok = $true
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
        # Package names match install/ubuntu.kvm.sh. 'qemu-kvm' is only a
        # transitional shim on current Ubuntu -- naming the real qemu-system-*
        # package keeps this hint working as the shim is retired.
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1a3ffa06ec11b7a6')
        $ok = $false
    }
    if (-not (Test-Path '/dev/kvm')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7fa56a2704d96ae2')
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Get-LibvirtGroupState, Assert-LinuxHostConditionSet, Test-LinuxHostMinimum, Sync-LinuxHostClock
