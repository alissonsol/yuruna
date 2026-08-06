<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42d5a90b-16c7-4e83-b0f2-5c9a7e34d118
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

# --- REGION: the service VMs, and bringing them back after a reboot
# A host reboot does not damage anything: it leaves every service VM registered
# with the hypervisor and powered off. Nothing then turns them back on, and the
# two consequences are not alike --
#
#   * the caching proxy merely degrades (guests download direct, slowly), while
#   * the stash service is FATAL to a cycle: the warm-up resolves it, finds
#     nothing, and every workload stage is skipped.
#
# So a rebooted host keeps burning cycles that can never pass, until an operator
# notices and starts the VMs by hand. The fix is the cheap one: START what is
# already built. A rebuild costs ~15 minutes and throws away a warm squid cache;
# a start costs seconds and preserves it. Rebuilding stays the escalation for a
# VM that will not come up, never the first response to one that is merely off.
#
# Host-neutral by construction. Every driver implements the same VM contract
# (Get-VMState / Start-VM / Get-VMIp), so this needs no per-host branch -- and
# because it resolves those by name at CALL time, a caller that has not run
# Initialize-YurunaHost degrades to a reported no-op instead of an error.

# One TCP probe's cap. The service ports are on the local hypervisor network, so
# a live service answers in milliseconds; this bound only decides how fast a dead
# one is called dead.
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

        The extension services are DISCOVERED from their own area manifests
        (test/extension/<area>/<area>.config.yml, `service:` block), so a new one
        joins the sweep by existing rather than by an edit here. The caching
        proxy is listed inline because it is not an extension area: it is the
        machine the pool services run ON.

        HealthPort is what a CONSUMER connects to, deliberately, rather than
        whatever the guest happens to also listen on: :3128 is the squid port
        guests proxy through, and :80 is the /healthz the stash pre-flight and
        the pool-control UI are gated on. A VM that is 'running' but not
        answering that port is not yet a service.
    .PARAMETER Key
        Optional filter. Unknown keys yield nothing rather than throwing, so a
        caller can name a service this version does not have.
    .OUTPUTS
        pscustomobject[] -- Key, VMName, DisplayName, StartScript, HealthPort.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string[]]$Key)

    $all = @(
        [pscustomobject]@{
            Key         = 'caching-proxy'
            VMName      = 'yuruna-caching-proxy-service'
            DisplayName = 'caching-proxy service'
            StartScript = 'Start-CachingProxyServiceVM.ps1'
            HealthPort  = 3128
        }
    )
    $all += @(Get-ExtensionServiceVmRoster)
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
    .OUTPUTS
        pscustomobject[] -- Key, VMName, DisplayName, StateBefore, Outcome,
        Healthy, Message. Outcome is one of: no-host-driver, absent, running,
        started, start-failed, start-timeout.

        Healthy on a 'running' record means "answered its health port" only when
        -ProbeRunning was passed; without it the port was not asked.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject[]])]
    param(
        [string[]]$Key,
        [int]$StartTimeoutSeconds  = 120,
        [int]$HealthTimeoutSeconds = 90,
        [switch]$ProbeRunning
    )
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
                Message = 'the per-host VM contract is not loaded (Initialize-YurunaHost has not run), so service VMs were not checked'
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
                Message = 'not built on this host'
            })
            continue
        }
        if ($state -eq 'running') {
            $healthy = $true
            $message = 'already running'
            if ($ProbeRunning) {
                # One connect, no retry loop. A VM that is already up has had all
                # the time it is going to get; waiting again here would only make
                # a caller pay a fresh budget for a service that has been silent
                # since whenever it was started.
                $address = Get-YurunaServiceVmAddress -VMName $svc.VMName
                if (-not $address) {
                    $healthy = $false
                    $message = 'running, but no address could be resolved for it, so :' + $svc.HealthPort + ' could not be probed'
                } elseif (Test-YurunaServiceVmPort -Address $address -Port $svc.HealthPort) {
                    $message = "already running; :$($svc.HealthPort) answering at $address"
                } else {
                    $healthy = $false
                    $message = "running, but :$($svc.HealthPort) did not answer at $address"
                }
            }
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'running'; Healthy = $healthy
                Message = $message
            })
            continue
        }

        # Registered and not running: ours, and off. This is the reboot case.
        if (-not $PSCmdlet.ShouldProcess($svc.VMName, "Start the $($svc.DisplayName) VM")) {
            $results.Add([pscustomobject]@{
                Key = $svc.Key; VMName = $svc.VMName; DisplayName = $svc.DisplayName
                StateBefore = $state; Outcome = 'start-failed'; Healthy = $false
                Message = 'WhatIf'
            })
            continue
        }
        Write-Information "  $($svc.DisplayName): VM '$($svc.VMName)' is $state -- starting it (a reboot leaves service VMs registered and powered off)." -InformationAction Continue

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
                Message = "did not reach 'running' within ${StartTimeoutSeconds}s"
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
                $message = if ($healthy) { "started; :$($svc.HealthPort) answering at $address" }
                           else { "started, but :$($svc.HealthPort) did not answer at $address within ${HealthTimeoutSeconds}s (it may still be coming up)" }
            } else {
                $message = 'started; no address could be resolved yet, so its service port was not probed'
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
                if ($r.Healthy) { Write-Information "  $($r.DisplayName): recovered after a restart -- $($r.Message)." -InformationAction Continue }
                else { Write-Warning "$($r.DisplayName): $($r.Message)." }
            }
            'start-failed'  { Write-Warning "$($r.DisplayName): VM '$($r.VMName)' is registered but would not start: $($r.Message). Rebuild it with $((Get-YurunaServiceVmRoster -Key $r.Key).StartScript) if it stays down." }
            'start-timeout' { Write-Warning "$($r.DisplayName): VM '$($r.VMName)' $($r.Message). Consumers of it will fail until it is up." }
            default { Write-Verbose "$($r.DisplayName): $($r.Outcome) -- $($r.Message)" }
        }
    }
}

Export-ModuleMember -Function Get-YurunaServiceVmRoster, Test-YurunaServiceVmPort, `
    Get-YurunaServiceVmAddress, Restore-YurunaServiceVM, Write-YurunaServiceVmRestoreReport
