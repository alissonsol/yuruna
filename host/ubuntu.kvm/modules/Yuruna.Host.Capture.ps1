<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42ebdaa1-65a7-4e54-8cc9-fecf31d96805
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu.kvm driver capture dhcp
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

# --- REGION: DHCP evidence capture
# See https://yuruna.link/4220a755-000e
# Mark this boot's DHCP journal window; capture packets only without elevation.

# The one armed capture, if any. Session state, not durable state: it says only
# that THIS process armed a window for that VM.
$script:YurunaDhcpCapture = $null
$script:YurunaDhcpExitJob = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    [void](Yuruna.Host\Stop-VMDhcpCapture -Reason 'arming process exiting')
}
$ExecutionContext.SessionState.Module.OnRemove = {
    [void](Stop-VMDhcpCapture -Reason 'host module unloaded')
    if ($script:YurunaDhcpExitJob) {
        Get-EventSubscriber | Where-Object { $_.Action -eq $script:YurunaDhcpExitJob } |
            Unregister-Event -ErrorAction SilentlyContinue
        Remove-Job -Job $script:YurunaDhcpExitJob -Force -ErrorAction SilentlyContinue
    }
}

# See https://yuruna.link/42e5cdfd-001f
$script:YurunaDhcpTrail = ''

# tcpdump needs CAP_NET_RAW to open a bridge. The grant is per-binary and
# survives upgrades of nothing, so it is named here rather than assumed.
$script:YurunaDhcpCaptureGrant = 'sudo setcap cap_net_raw,cap_net_admin=eip $(command -v tcpdump)'

# Why the refusal is remembered: whether this account may open a bridge does not
# change inside one runner process, and finding out costs a spawn and a settle
# on every VM start. Remembered as the REASON, so the artifact still explains
# itself on the guest that fails rather than only on the first guest of the run.
$script:YurunaDhcpWireRefusal = ''

# Gaps already reported, so a host that cannot capture at all says so once
# instead of once per guest per cycle. The window is armed on every Start-VM,
# and a missing capability does not change inside a run.
$script:YurunaDhcpGapReported = @{}

# See https://yuruna.link/42e5cdfd-001f
function Write-YurunaDhcpGap {
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Reason, [string]$VMName = '')
    if ($script:YurunaDhcpGapReported.ContainsKey($Reason)) { return }
    $script:YurunaDhcpGapReported[$Reason] = $true
    $subject = if ($VMName) { " for '$VMName'" } else { '' }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_072eb8558b8e4f3a' -Arguments @{ subject = "${subject}"; reason = "$Reason" })
    # Resolved by name behind a guard so this driver still imports standalone,
    # which is how the suites load it.
    if (Get-Command Send-YurunaDegradation -ErrorAction SilentlyContinue) {
        Send-YurunaDegradation -Dependency 'dhcp-capture' -Primary 'armed-window' -Fallback 'none' `
            -Reason $Reason
    }
}

<#
.SYNOPSIS
    Resolve the bridge (and libvirt network, if any) a domain's NIC attaches to.
.DESCRIPTION
    domiflist reports the SOURCE, which is a network name for a NAT/routed
    guest and a bridge name for a bridged one. Only the bridge can be captured
    on, so a network source is resolved one step further through net-info.
#>
function Get-YurunaGuestBridge {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    $found = @{ Bridge = ''; Network = '' }
    $rows = Invoke-Virsh -VirshArgs @('domiflist', $VMName)
    if ($LASTEXITCODE -ne 0) { return $found }
    foreach ($row in @($rows)) {
        # Interface Type Source Model MAC. The header and its underline carry
        # no MAC, so requiring one is what skips them without matching on the
        # column titles, which are localized.
        if ("$row" -match '^\s*\S+\s+(network|bridge)\s+(\S+)\s+\S+\s+[0-9a-fA-F:]{17}') {
            if ($Matches[1] -eq 'bridge') { $found.Bridge = $Matches[2]; break }
            $found.Network = $Matches[2]
            foreach ($line in @(Invoke-Virsh -VirshArgs @('net-info', $found.Network))) {
                if ("$line" -match '^\s*Bridge:\s*(\S+)') { $found.Bridge = $Matches[1] }
            }
            break
        }
    }
    return $found
}

<#
.SYNOPSIS
    Read the dnsmasq DHCP journal from an armed instant, or explain why not.
.DESCRIPTION
    Unprivileged first: a journal read works for any member of 'adm' or
    'systemd-journal', which is the common case here. Elevation is the
    fallback and is non-interactive, so a runner cycle can never be parked at
    a password prompt. The window opens at the armed instant rather than at a
    duration, because a duration drifts with how long the failing step took
    and would either miss the first transaction or drag in the previous guest's.
#>
function Get-YurunaDnsmasqJournal {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][long]$SinceEpochSecond)
    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) {
        return [string[]]@('(journalctl is not present on this host)')
    }
    $journalArg = @('-t', 'dnsmasq-dhcp', '-t', 'dnsmasq', '--since', "@$SinceEpochSecond", '--no-pager')
    # journalctl answers an empty window with a placeholder line rather than
    # with nothing, and a placeholder counts as a read that found nothing --
    # otherwise the elevated retry never runs and the caller reports "the
    # server logged this much" while showing the marker for having logged none.
    $out = @(& journalctl @journalArg 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^-- No entries --' })
    if ($out.Count -eq 0) {
        $out = @(& sudo -n journalctl @journalArg 2>$null | ForEach-Object { "$_" } | Where-Object { $_ -notmatch '^-- No entries --' })
    }
    if ($out.Count -eq 0) {
        return [string[]]@('(no dnsmasq entries in the window -- no guest asked for a lease here,',
                           ' dnsmasq does not log to this journal, or this account cannot read it)')
    }
    return [string[]]$out
}

<#
.SYNOPSIS
    Arm a DHCP evidence window for one guest VM.
.OUTPUTS
    [bool] $true when a window is armed (with or without a wire capture).
#>
function Start-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic capture: records a timestamp and reads packets, changes no durable system state, and must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        # One window at a time. A start that inherits a live capture from the
        # previous guest would leave that guest's tcpdump running against a
        # bridge nobody is collecting from, and its temp file behind it.
        if ($script:YurunaDhcpCapture) { [void](Stop-VMDhcpCapture -Reason "superseded when '$VMName' was started") }
        # Stamped before anything else is looked up: a DISCOVER sent while this
        # is still resolving the bridge has to fall inside the window, and one
        # second of slack absorbs the journal's own clock rounding.
        $armed = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
        $iface = Get-YurunaGuestBridge -VMName $VMName
        $mac = $null
        try { $mac = Get-VMMac -VMName $VMName } catch { $mac = $null }
        $capture = @{
            VMName    = $VMName
            ArmedUtc  = $armed
            Mac       = $mac
            Bridge    = $iface.Bridge
            Network   = $iface.Network
            PcapPath  = ''
            Process   = $null
            WireNote  = ''
        }
        if (-not $iface.Bridge) {
            $capture.WireNote = 'no bridge resolved for this domain; wire capture not started'
        } elseif (-not (Get-Command tcpdump -ErrorAction SilentlyContinue)) {
            $capture.WireNote = 'tcpdump is not installed; journal evidence only'
        } elseif (-not (Get-Command timeout -ErrorAction SilentlyContinue)) {
            $capture.WireNote = 'timeout is not installed; journal evidence only'
        } elseif ($script:YurunaDhcpWireRefusal) {
            $capture.WireNote = $script:YurunaDhcpWireRefusal
        } else {
            $pcap = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-dhcp-{0}.pcap" -f $VMName)
            $errPath = "$pcap.err"
            Remove-Item -LiteralPath $pcap -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
            # Packet-count bound rather than a file-size one: -C renames the
            # output behind our back, while a count keeps one predictable path
            # and 500 DHCP frames is far more than one cycle of one guest.
            $tcpdumpArg = @('-i', $iface.Bridge, '-n', '-s', '0', '-U', '-c', '500',
                            '-w', $pcap, 'port', '67', 'or', 'port', '68')
            # A quiet bridge may never reach the packet bound. The independent
            # wall-clock bound also survives an abrupt parent process exit.
            $captureArg = @('--signal=TERM', '--kill-after=5s', '300s', 'tcpdump') + $tcpdumpArg
            # Start-Process rejects identical input/output paths, even /dev/null.
            $inputPath = "$pcap.stdin"
            [System.IO.File]::WriteAllText($inputPath, '')
            try {
                $proc = Start-Process -FilePath 'timeout' -ArgumentList $captureArg -PassThru -NoNewWindow `
                    -RedirectStandardInput $inputPath -RedirectStandardOutput '/dev/null' `
                    -RedirectStandardError $errPath -ErrorAction SilentlyContinue
            } finally { Remove-Item -LiteralPath $inputPath -Force -ErrorAction SilentlyContinue }
            # tcpdump reports a refused capture and exits immediately, so a
            # short settle separates "running" from "already dead" without
            # polling. Reported either way: a capture believed to be running
            # that never was is worse than none.
            Start-Sleep -Milliseconds 400
            if ($proc -and -not $proc.HasExited) {
                $capture.PcapPath = $pcap
                $capture.Process  = $proc
                $capture.WireNote = "tcpdump running on $($iface.Bridge)"
            } else {
                $why = ''
                if (Test-Path -LiteralPath $errPath) {
                    $why = (@(Get-Content -LiteralPath $errPath -ErrorAction SilentlyContinue) |
                        Where-Object { $_ } | Select-Object -First 1)
                }
                if (-not $why) { $why = 'tcpdump exited immediately' }
                $script:YurunaDhcpWireRefusal = "no wire capture: $why -- enable with: $script:YurunaDhcpCaptureGrant"
                $capture.WireNote = $script:YurunaDhcpWireRefusal
                Remove-Item -LiteralPath $pcap -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue
        }
        $script:YurunaDhcpCapture = $capture
        $script:YurunaDhcpTrail = "a window was armed for '$VMName' at @$armed"
        Write-Verbose "DHCP evidence armed for '$VMName' at @$armed ($($capture.WireNote))."
        return $true
    } catch {
        Write-YurunaDhcpGap -Reason "the window could not be armed: $($_.Exception.Message)" -VMName $VMName
        return $false
    }
}

<#
.SYNOPSIS
    Drop the armed window and any wire capture with it (the no-failure path).
.OUTPUTS
    [bool] $true when nothing is left running or on disk.
#>
function Stop-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic teardown: stops a packet capture and deletes its temp file; must never prompt inside a runner cycle.')]
    param(
        # What is discarding the window, in words, for the trail a later gap
        # reports. Optional so a caller with nothing to add still clears
        # cleanly; the default names no cause because there is none to name.
        [string]$Reason = 'discarded'
    )
    try {
        $capture = $script:YurunaDhcpCapture
        $script:YurunaDhcpCapture = $null
        if (-not $capture) { return $true }
        $script:YurunaDhcpTrail = "the window armed for '$($capture.VMName)' at @$($capture.ArmedUtc) was $Reason"
        if ($capture.Process -and -not $capture.Process.HasExited) {
            $capture.Process.Kill($true)
            [void]$capture.Process.WaitForExit(2000)
        }
        if ($capture.PcapPath) {
            Remove-Item -LiteralPath $capture.PcapPath -Force -ErrorAction SilentlyContinue
        }
        return $true
    } catch {
        Write-Verbose "Stop-VMDhcpCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Land the DHCP evidence for one guest beside its failure diagnostics.
.DESCRIPTION
    Written as text because the useful part is a correlation a reader makes by
    eye: the guest's MAC, the window its boot occupies, what the server logged
    inside that window, and what the lease table holds now. The pcap is copied
    beside it when one was taken; it carries the payloads (client identity,
    transaction id) for the same packets.
.OUTPUTS
    [bool] $true when the evidence file landed in OutputDirectory.
#>
function Save-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: stops a packet capture and copies artifacts; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    # Set once this call owns the capture, so the finally below removes the
    # pcap on every path out and never touches another VM's window.
    $claimed = $null
    try {
        $capture = $script:YurunaDhcpCapture
        if (-not $capture -or $capture.VMName -ne $VMName) {
            # See https://yuruna.link/42e5cdfd-001f
            $held = if ($capture) {
                "the armed window belongs to '$($capture.VMName)'"
            } elseif ($script:YurunaDhcpTrail) {
                "no window is armed -- $script:YurunaDhcpTrail"
            } else {
                'no window was armed, and nothing in this process ever armed one'
            }
            Write-YurunaDhcpGap -Reason "nothing to save for '$VMName' -- $held" -VMName $VMName
            return $false
        }
        $script:YurunaDhcpCapture = $null
        $script:YurunaDhcpTrail = "the window armed for '$VMName' was saved"
        $claimed = $capture
        if ($capture.Process -and -not $capture.Process.HasExited) {
            $capture.Process.Kill($true)
            [void]$capture.Process.WaitForExit(2000)
            # tcpdump flushes on SIGTERM; without a moment to do it the file is
            # truncated at whatever was still buffered.
            Start-Sleep -Milliseconds 300
        }
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        $armedText = [DateTimeOffset]::FromUnixTimeSeconds($capture.ArmedUtc).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $body = [System.Collections.Generic.List[string]]::new()
        $body.Add("vmName:   $VMName")
        $body.Add("guestMac: $(if ($capture.Mac) { $capture.Mac } else { '(unresolved)' })")
        $body.Add("bridge:   $(if ($capture.Bridge) { $capture.Bridge } else { '(unresolved)' })")
        $body.Add("network:  $(if ($capture.Network) { $capture.Network } else { '(not a libvirt-managed network)' })")
        $body.Add("armedUtc: $armedText")
        $body.Add("savedUtc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))")
        $body.Add("wire:     $($capture.WireNote)")
        $body.Add('')
        $body.Add('reading:  a DISCOVER from the MAC above with an OFFER after it means the')
        $body.Add('          server answered and the guest did not take it up; a DISCOVER with')
        $body.Add('          nothing after it means the server saw the ask and would not answer')
        $body.Add('          it; no line at all for that MAC means the ask never reached the')
        $body.Add('          server, and the guest-side client state in the console capture is')
        $body.Add('          where that is settled. The client identity dnsmasq keys the lease')
        $body.Add('          on is the last column of the lease table below.')
        $body.Add('')
        $body.Add('--- dnsmasq DHCP transactions since this guest was started ---')
        foreach ($line in @(Get-YurunaDnsmasqJournal -SinceEpochSecond $capture.ArmedUtc)) { $body.Add([string]$line) }
        if ($capture.Network) {
            $body.Add('')
            $body.Add("--- leases held by network '$($capture.Network)' now ---")
            foreach ($line in @(Invoke-Virsh -VirshArgs @('net-dhcp-leases', $capture.Network))) { $body.Add([string]$line) }
        }
        $target = Join-Path $OutputDirectory 'dhcp.capture.txt'
        Set-Content -LiteralPath $target -Encoding utf8NoBOM -Value $body
        if ($capture.PcapPath -and (Test-Path -LiteralPath $capture.PcapPath)) {
            $pcapItem = Get-Item -LiteralPath $capture.PcapPath -ErrorAction SilentlyContinue
            if ($pcapItem -and $pcapItem.Length -gt 0) {
                Copy-Item -LiteralPath $capture.PcapPath -Destination (Join-Path $OutputDirectory 'dhcp.capture.pcap') -Force
            }
        }
        return $true
    } catch {
        Write-Verbose "Save-VMDhcpCapture failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($claimed -and $claimed.PcapPath) { Remove-Item -LiteralPath $claimed.PcapPath -Force -ErrorAction SilentlyContinue }
    }
}
