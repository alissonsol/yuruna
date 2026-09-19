<#PSScriptInfo
.VERSION 2026.09.18
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

# The extension half of the roster comes from the area manifests. Imported here
# rather than assumed in scope: this module is loaded on its own by the reboot
# sweep and by cleanup paths, and an empty roster is the one failure that
# matters -- it would leave a rebooted host's service VMs off and let a
# prefix-matching cleanup treat them as ordinary test VMs.
Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -Force -DisableNameChecking -Verbose:$false

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
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command Get-VMIp -ErrorAction SilentlyContinue)) { return '' }
    try { return [string](Get-VMIp -VMName $VMName) } catch {
        Write-Verbose "Get-YurunaServiceVmAddress('$VMName'): $($_.Exception.Message)"
        return ''
    }
}

function Restore-YurunaServiceVM {
    <#
    .SYNOPSIS
        Start any service VM that is registered with the hypervisor but not
        running, and report what happened. Returns one record per service.
        Never throws; never rebuilds.
    .DESCRIPTION
        The reboot self-heal. Cheap on a healthy host -- one state query per
        service and nothing else -- so it is safe to call at every cycle start
        rather than only at boot, which also covers a service that died or was
        stopped mid-session.

        'absent' is NOT a failure and never triggers anything. A standalone host
        legitimately runs no stash service, and a host that never built the
        pool-control service must not have one conjured for it: absent means "not
        this host's job", and only a REGISTERED-but-stopped VM is something this
        host owns and failed to start.

        The health wait is best-effort and deliberately non-authoritative. A
        freshly resumed guest can take a while to re-open its listener, and the
        real gates (the caching-proxy probe, the stash pre-flight) run
        afterwards and own the verdict. Reporting a slow starter as failed here
        would only produce a scary line for a service that comes up seconds later.
    .PARAMETER Key
        Restrict to these roster keys. Default: every service.
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
        done the one authorized start, to verify VM state and service health
        without a second start path.
    .OUTPUTS
        pscustomobject[] -- Key, VMName, DisplayName, StateBefore, Outcome,
        Healthy, Message. Outcome is one of: no-host-driver, absent,
        state-unknown, running, started, start-failed, start-timeout, or (only
        under -ObserveOnly) the raw confirmed state (currently always
        'stopped', since absent/unknown/running are reported before reaching
        that branch).

        Healthy on a 'running' record means "answered its health port" only when
        -ProbeRunning was passed; without it the port was not asked.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [string[]]$Key,
        [int]$StartTimeoutSeconds  = 120,
        [int]$HealthTimeoutSeconds = 90,
        [switch]$ProbeRunning,
        # ObserveOnly implies health verification (equivalent to -ProbeRunning)
        # and prohibits Start-VM, configuration edits, or rebuilds; it may wait
        # boundedly for VM/address/service readiness through the same health
        # wait a normal call uses, but never mutates. A convergence check after
        # a resume/relaunch calls this instead of a second start path.
        [switch]$ObserveOnly
    )
    if ($ObserveOnly) { $ProbeRunning = $true }
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $roster = @(Get-YurunaServiceVmRoster -Key $Key)
    if ($roster.Count -eq 0) { return $results.ToArray() }

    # Resolved by name at call time: this module is imported by the entry-point
    # module set, which loads BEFORE Initialize-YurunaHost brings in the per-host
    # driver. Binding at import would leave every caller with a permanent no-op.
    $canState = [bool](Get-Command Get-VMState -ErrorAction SilentlyContinue)
    $canStart = [bool](Get-Command Start-VM   -ErrorAction SilentlyContinue)
    if (-not $canState -or -not $canStart) {
        foreach ($svc in $roster) {
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = 'unknown'; Outcome = 'no-host-driver'; Healthy = $false
                Message = (Format-YurunaOperatorMessage -Key 'runner.operator_6ce1157be9fb6a1c')
            })
        }
        return $results.ToArray()
    }

    foreach ($svc in $roster) {
        $state = 'unknown'
        try { $state = [string](Get-VMState -VMName $svc.VMName) } catch {
            Write-Verbose "Restore-YurunaServiceVM: Get-VMState('$($svc.VMName)'): $($_.Exception.Message)"
            $state = 'unknown'
        }
        if ($state -eq 'absent') {
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'absent'; Healthy = $false
                Message = (Format-YurunaOperatorMessage -Key 'runner.operator_55110b53e7e30cf1')
            })
            continue
        }
        if ($state -eq 'unknown') {
            # A denied or timed-out probe, not a registered-and-stopped VM: the
            # prior code fell through this case into the start branch below,
            # which would call Start-VM against a hypervisor that simply would
            # not answer -- on every cycle, since nothing here would ever
            # resolve it. Report it as its own outcome instead, carrying the
            # structured probe reason once section 3's Test-VirtualizationResponsive
            # is wired in as this sweep's own precondition; for now the reason
            # is not yet distinguishable beyond "not positively any other
            # state".
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'state-unknown'; Healthy = $false
                Message = (Format-YurunaOperatorMessage -Key 'runner.operator_5485e11b651f9377')
            })
            continue
        }
        if ($state -eq 'running') {
            $healthy = $true
            $message = (Format-YurunaOperatorMessage -Key 'runner.operator_dea2daf647b24f47')
            if ($ProbeRunning) {
                # One connect, no retry loop. A VM that is already up has had all
                # the time it is going to get; waiting again here would only make
                # a caller pay a fresh budget for a service that has been silent
                # since whenever it was started.
                $address = Get-YurunaServiceVmAddress -VMName $svc.VMName
                if (-not $address) {
                    $healthy = $false
                    $message = (Format-YurunaOperatorMessage -Key 'runner.operator_572d9bbb6abf31cf' -Arguments @{ healthPort = [string]($svc.HealthPort) })
                } elseif (Test-YurunaServiceVmPort -Address $address -Port $svc.HealthPort) {
                    $message = (Format-YurunaOperatorMessage -Key 'runner.operator_5cf6a67db15856c2' -Arguments @{ healthPort = "$($svc.HealthPort)"; address = "$address" })
                } else {
                    $healthy = $false
                    $message = (Format-YurunaOperatorMessage -Key 'runner.operator_89c43538cc813c4a' -Arguments @{ healthPort = "$($svc.HealthPort)"; address = "$address" })
                }
            }
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'running'; Healthy = $healthy
                Message = $message
            })
            continue
        }

        if ($ObserveOnly) {
            # Only 'stopped' can reach here (absent/unknown/running all
            # continued above): a positive, confirmed non-running state that
            # ObserveOnly reports without ever calling Start-VM.
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = $state; Healthy = $false
                Message = (Format-YurunaOperatorMessage -Key 'runner.operator_1fa3b2464af15be3' -Arguments @{ state = "$state" })
            })
            continue
        }
        # Registered and not running: ours, and off. This is the reboot case.
        if (-not $PSCmdlet.ShouldProcess($svc.VMName, (Format-YurunaOperatorMessage -Key 'runner.operator_e68cd14ab99489c3' -Arguments @{ displayName = "$($svc.DisplayName)" }))) {
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'start-failed'; Healthy = $false
                Message = 'WhatIf'
            })
            continue
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_27431929d461d016' -Arguments @{ displayName = "$($svc.DisplayName)"; vMName = "$($svc.VMName)"; state = "$state" }) -InformationAction Continue

        $startError = ''
        try {
            $r = Start-VM -VMName $svc.VMName -Confirm:$false
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
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'start-failed'; Healthy = $false
                Message = $startError
            })
            continue
        }

        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $StartTimeoutSeconds))
        $running = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $now = 'unknown'
            try { $now = [string](Get-VMState -VMName $svc.VMName) } catch { $now = 'unknown' }
            if ($now -eq 'running') { $running = $true; break }
        }
        if (-not $running) {
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'start-timeout'; Healthy = $false
                Message = (Format-YurunaOperatorMessage -Key 'runner.operator_ce0d858e56345187' -Arguments @{ startTimeoutSeconds = "${StartTimeoutSeconds}" })
            })
            continue
        }

        $healthy = $false
        $message = 'started'
        if ($HealthTimeoutSeconds -gt 0) {
            $address = Get-YurunaServiceVmAddress -VMName $svc.VMName
            if ($address) {
                $healthDeadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
                while ((Get-Date) -lt $healthDeadline) {
                    if (Test-YurunaServiceVmPort -Address $address -Port $svc.HealthPort) { $healthy = $true; break }
                    Start-Sleep -Seconds 3
                }
                $message = if ($healthy) { (Format-YurunaOperatorMessage -Key 'runner.operator_d671065a9abb598e' -Arguments @{ healthPort = "$($svc.HealthPort)"; address = "$address" }) }
                           else { (Format-YurunaOperatorMessage -Key 'runner.operator_6938c638981b508c' -Arguments @{ healthPort = "$($svc.HealthPort)"; address = "$address"; healthTimeoutSeconds = "${HealthTimeoutSeconds}" }) }
            } else {
                $message = (Format-YurunaOperatorMessage -Key 'runner.operator_482acc3cc0fb29aa')
            }
        }
        $results.Add([pscustomobject]@{
            Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
            StateBefore = $state; Outcome = 'started'; Healthy = $healthy; Message = $message
        })
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
        actually restarted.
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
            default { Write-Verbose "$($r.DisplayName): $($r.Outcome) -- $($r.Message)" }
        }
    }
}

Export-ModuleMember -Function Get-YurunaServiceVmRoster, Test-YurunaServiceVmPort, `
    Get-YurunaServiceVmAddress, Restore-YurunaServiceVM, Write-YurunaServiceVmRestoreReport
