<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42c7f1a9-3e60-4b2d-9a55-1f0c8b6d24ae
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host metrics prometheus exporter firewall
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

<#
.SYNOPSIS
    Converge the Windows host-metrics exporter: the per-host Prometheus
    endpoint that publishes memory (committed bytes and the commit limit),
    CPU, disk and Hyper-V VM state.
.DESCRIPTION
    A Hyper-V host can refuse a VM's memory allocation while nothing on the
    host is at fault for more than a few seconds: the commit charge spikes
    while a departing guest's worker process is still releasing, the page file
    has not finished growing, and the next request is granted. Reconstructing
    that after the fact is impossible from the harness's own artifacts -- the
    only host-side evidence is an Information-level Windows event nothing
    collects. A continuously scraped commit limit and commit charge is what
    turns that class of refusal from undetermined into measured, so the
    exporter is host infrastructure, not a dashboard nicety.

    Everything here is best-effort and NEVER throws: it is called from the
    elevated host-setup path, where a metrics endpoint that could not be
    brought up must not stop the settings that make unattended testing
    possible, and from the unattended cycle path, where it must not become a
    new reason for a host to stop testing. The cycle path stops at a service
    lookup on any host that already has the exporter, which is why re-deriving
    the whole configuration every cycle is still not done -- see
    Set-YurunaHostMetricsExporter for why the scrape itself is the watchdog.

    Acquisition is part of the job, not a prerequisite left to whoever set the
    host up: a host with no exporter package records nothing at all, and the
    class of failure this endpoint exists to explain is exactly the class that
    nobody thinks to instrument for until after it has happened. So this module
    owns everything that has to stay true about the endpoint -- that the package
    exists, and then that the service publishes the right collector set on the
    right port, starts with the host, and is reachable from the host that
    scrapes it. Every one of those is best-effort; none is a prerequisite.
#>

# The exporter's listen port. A constant rather than a configuration key: the
# scrape side has to name the same number, and a per-host port that the
# monitoring host cannot discover is a target that silently never scrapes.
$script:HostMetricsPort = 9182

# The Windows service name the exporter's own installer registers.
$script:HostMetricsServiceName = 'windows_exporter'

# The collectors this host must publish, and why each one is on the list:
#   memory       -- committed bytes and the commit limit, the pair that
#                   explains a refused allocation; nothing else exposes them.
#   os           -- host identity and operating-system information.
#   cpu          -- per-core time, to separate a stalled host from a busy one.
#   logical_disk -- free space, which fails a guest's disk creation the same
#                   silent way a commit ceiling fails its memory.
#   hyperv       -- per-VM state, so a host's VM census at an incident is a
#                   recorded series rather than a memory of what was running.
# Kept deliberately short: every collector is scraped on every interval, and
# the exporter's defaults differ between releases, so the set is stated rather
# than inherited.
$script:HostMetricsCollector = @('cpu', 'hyperv', 'logical_disk', 'memory', 'os')

# The package the exporter is acquired as. Named here rather than only in the
# command an operator is shown, because the same identifier now drives an
# unattended acquisition and the two must not be able to drift apart.
$script:HostMetricsPackageId = 'Prometheus.WindowsExporter'

# How long one unattended install attempt may run before it is stopped, and the
# only place that number is written. The work behind it is a package download of
# a few tens of megabytes and a service registration, so three minutes is
# several times what it costs -- reaching this bound is evidence that something
# is wrong rather than slow. It is a ceiling on what a cycle can lose to
# telemetry it does not need in order to run, which is the only reason it is
# bounded at all. Callers do not carry a second copy of it: two owners of one
# bound is how a bound stops being enforced without anybody noticing.
$script:HostMetricsInstallTimeoutSec = 180

# How long a FAILED attempt stays quiet. The failures that do not clear on
# their own -- a package source this host is not allowed to reach, an installer
# a policy refuses -- would otherwise pay the bound above every cycle for the
# same answer, and cycles are minutes apart. Six hours holds a host that cannot
# install to a handful of attempts a day while still letting one that was only
# offline recover the same working day, unattended. A host start cancels the
# interval outright, because a restart is where an operator's fix lands.
$script:HostMetricsInstallRetryHours = 6

function Get-YurunaHostMetricsPort {
    <#
    .SYNOPSIS
        The TCP port the host-metrics exporter listens on.
    .OUTPUTS
        [int]
    .EXAMPLE
        Get-YurunaHostMetricsPort
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:HostMetricsPort
}

function Get-YurunaHostMetricsServiceName {
    <#
    .SYNOPSIS
        The Windows service name the exporter registers.
    .OUTPUTS
        [string]
    .EXAMPLE
        Get-YurunaHostMetricsServiceName
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:HostMetricsServiceName
}

function Get-YurunaHostMetricsCollector {
    <#
    .SYNOPSIS
        The collector names this host publishes, in canonical order.
    .OUTPUTS
        [string[]]
    .EXAMPLE
        Get-YurunaHostMetricsCollector
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]$script:HostMetricsCollector
}

function Get-YurunaHostMetricsFirewallRuleName {
    <#
    .SYNOPSIS
        The Windows Defender Firewall rule DisplayName for the exporter port.
    .DESCRIPTION
        Single source of truth for the DisplayName so the setup path that
        creates the rule and the teardown path that removes it address the
        very same rule.
    .PARAMETER Port
        The exporter's TCP port.
    .OUTPUTS
        [string]
    .EXAMPLE
        Get-YurunaHostMetricsFirewallRuleName -Port 9182
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Port)
    "Yuruna: Allow inbound TCP :$Port (Host metrics)"
}

function Get-YurunaHostMetricsScrapeSource {
    <#
    .SYNOPSIS
        The remote addresses allowed to reach the exporter port.
    .DESCRIPTION
        Host metrics name the host's processes, disks and guests, so the port
        is opened to the address that scrapes it rather than to every profile
        the way a status page is. The monitoring stack runs on the
        caching-proxy service, which the harness already addresses by IP, so
        that address -- from configuration, from the session override, or both
        -- is the scope.

        A candidate that is not a literal IP address is discarded rather than
        passed to the firewall: an unparseable value there does not fail, it
        widens. When nothing usable remains the scope falls back to
        LocalSubnet, which is narrower than Any on a routed lab and is the
        most that can be asserted without knowing where the scrape comes from.
    .PARAMETER ConfigIp
        The configured caching-proxy address (vmStart.cachingProxyIp).
    .PARAMETER EnvIp
        The session override (YURUNA_CACHING_PROXY_SERVICE_IP).
    .OUTPUTS
        [string[]] addresses for -RemoteAddress, never empty.
    .EXAMPLE
        Get-YurunaHostMetricsScrapeSource -ConfigIp '192.0.2.42' -EnvIp ''
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$ConfigIp,
        [string]$EnvIp
    )
    $addresses = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($ConfigIp, $EnvIp)) {
        $text = "$candidate".Trim()
        if (-not $text) { continue }
        $parsed = [System.Net.IPAddress]::Any
        if (-not [System.Net.IPAddress]::TryParse($text, [ref]$parsed)) { continue }
        $normalized = $parsed.ToString()
        if ($addresses -notcontains $normalized) { $addresses.Add($normalized) }
    }
    if ($addresses.Count -eq 0) { return [string[]]@('LocalSubnet') }
    return [string[]]$addresses
}

function Split-YurunaServiceCommandLine {
    <#
    .SYNOPSIS
        Split a service command line into tokens, keeping quoted runs whole.
    .DESCRIPTION
        A service PathName holds an executable that usually lives under a path
        with a space in it, and flags whose values may be quoted for the same
        reason. Splitting on whitespace alone tears both apart, and the
        rewrite that follows would then hand the service a truncated path.
    .PARAMETER CommandLine
        The raw Win32_Service PathName.
    .OUTPUTS
        [string[]]
    .EXAMPLE
        Split-YurunaServiceCommandLine -CommandLine '"C:\a b\x.exe" --flag=1'
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$CommandLine)
    if (-not "$CommandLine".Trim()) { return [string[]]@() }
    return [string[]]@([regex]::Matches($CommandLine, '(?:[^\s"]+|"[^"]*")+') |
        ForEach-Object { $_.Value })
}

function Resolve-YurunaHostMetricsCommandLine {
    <#
    .SYNOPSIS
        The command line the exporter service must run, and whether the one it
        already runs is equivalent.
    .DESCRIPTION
        The exporter's collector set and listen address are service command-line
        flags, which is also how its own installer writes them -- so a package
        upgrade can reset them to that release's defaults, and the defaults have
        never included the memory collector on every release. Converging the
        command line is therefore the only form of this setting that survives an
        upgrade.

        Equivalence is semantic, not textual: collectors are compared as a set
        so a reordered list is not a reason to rewrite and restart a healthy
        service, and a listen address is compared on its port so the wildcard
        and the explicit-any forms agree. Every other flag already on the line
        (event-log routing, a configuration file) is preserved in place --
        this owns two flags and inherits the rest.
    .PARAMETER CurrentCommandLine
        The service's current PathName. An empty value yields no executable and
        Matches false, which the caller reports rather than acts on.
    .PARAMETER Collector
        The collector names to publish.
    .PARAMETER Port
        The TCP port to listen on.
    .OUTPUTS
        [pscustomobject] Executable, Desired, Matches, Reason.
    .EXAMPLE
        Resolve-YurunaHostMetricsCommandLine -CurrentCommandLine $p -Collector @('cpu') -Port 9182
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$CurrentCommandLine,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$Collector,
        [Parameter(Mandatory)][int]$Port
    )
    $result = [pscustomobject]@{ Executable = ''; Desired = ''; Matches = $false; Reason = '' }
    # @(...) is load-bearing: a bare executable with no flags is a ONE-element
    # return, which unrolls to a scalar string, and indexing a string yields a
    # [char] that has no .Trim -- the shortest command line would be the one
    # shape this could not read.
    $tokens = @(Split-YurunaServiceCommandLine -CommandLine $CurrentCommandLine)
    if ($tokens.Count -eq 0) {
        $result.Reason = 'the service has no command line to read'
        return $result
    }
    $result.Executable = $tokens[0].Trim('"')

    $wantCollector = @($Collector | ForEach-Object { "$_".Trim().ToLowerInvariant() } |
        Where-Object { $_ } | Sort-Object -Unique)
    $collectorFlag = '--collectors.enabled'
    $listenFlag    = '--web.listen-address'

    # Walk the flags once: keep what is not ours, and record what ours already
    # say so the comparison below reads values rather than text.
    $kept       = [System.Collections.Generic.List[string]]::new()
    $haveList   = $null
    $haveListen = $null
    for ($i = 1; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        $name  = $token
        $value = $null
        $split = $token.IndexOf('=')
        if ($split -gt 0) {
            $name  = $token.Substring(0, $split)
            $value = $token.Substring($split + 1).Trim('"')
        }
        if ($name -ne $collectorFlag -and $name -ne $listenFlag) {
            $kept.Add($token)
            continue
        }
        # The space-separated form puts the value in the next token. Consume it
        # only when it is not itself a flag, so a value-less trailing flag does
        # not swallow the one after it.
        if ($null -eq $value -and ($i + 1) -lt $tokens.Count -and -not $tokens[$i + 1].StartsWith('-')) {
            $value = $tokens[$i + 1].Trim('"')
            $i++
        }
        if ($name -eq $collectorFlag) { $haveList = $value } else { $haveListen = $value }
    }

    $desiredList   = ($wantCollector -join ',')
    $desiredListen = ":$Port"
    $rebuilt = [System.Collections.Generic.List[string]]::new()
    $rebuilt.Add('"' + $result.Executable + '"')
    foreach ($token in $kept) { $rebuilt.Add($token) }
    $rebuilt.Add("$collectorFlag=$desiredList")
    $rebuilt.Add("$listenFlag=$desiredListen")
    $result.Desired = ($rebuilt -join ' ')

    $haveSet = @("$haveList".Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Where-Object { $_ } | Sort-Object -Unique)
    $collectorsAgree = ($haveSet.Count -eq $wantCollector.Count) -and
        (-not (Compare-Object -ReferenceObject $wantCollector -DifferenceObject $haveSet -SyncWindow 0))
    # ':9182', '0.0.0.0:9182' and '[::]:9182' all bind every interface on this
    # port; only the port is load-bearing, so only the port is compared.
    $listenPort = if ("$haveListen" -match ':(\d+)$') { [int]$Matches[1] } else { 0 }
    $listenAgrees = ($listenPort -eq $Port)

    if ($collectorsAgree -and $listenAgrees) {
        $result.Matches = $true
        $result.Reason  = 'the service already publishes this collector set on this port'
        return $result
    }
    $missing = @($wantCollector | Where-Object { $haveSet -notcontains $_ })
    $result.Reason = if (-not $collectorsAgree -and $missing.Count -gt 0) {
        "the service does not publish: $($missing -join ', ')"
    } elseif (-not $collectorsAgree) {
        'the service publishes collectors this host does not ask for'
    } else {
        "the service does not listen on port $Port"
    }
    return $result
}

function Test-YurunaHostMetricsPayload {
    <#
    .SYNOPSIS
        Whether a scraped exposition carries the metric families this host is
        instrumented for.
    .DESCRIPTION
        The collector flag says what was ASKED for; only the exposition says
        what arrived. Families are matched by name prefix rather than by exact
        metric, because individual metric names are renamed between exporter
        releases while the family prefix is the stable part -- and a check that
        breaks on an upgrade would be read as "the exporter is broken".
    .PARAMETER Payload
        The scraped text.
    .OUTPUTS
        [pscustomobject] Ok, Missing.
    .EXAMPLE
        Test-YurunaHostMetricsPayload -Payload $body
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Payload)
    # Each entry is a family that one of the requested collectors must produce.
    # The commit pair is named exactly because it is the reason this endpoint
    # exists; the rest are prefixes.
    $required = [ordered]@{
        'memory (commit limit)'   = '(?m)^windows_memory_commit_limit'
        'memory (commit charge)'  = '(?m)^windows_memory_committed_bytes'
        'cpu'                     = '(?m)^windows_cpu_'
        'logical_disk'            = '(?m)^windows_logical_disk_'
        'os'                      = '(?m)^windows_os_'
        'hyperv'                  = '(?m)^windows_hyperv_'
    }
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required.Keys) {
        if ("$Payload" -notmatch $required[$name]) { $missing.Add($name) }
    }
    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = [string[]]$missing }
}

function Get-YurunaHostMetricsRetentionRegex {
    <# .SYNOPSIS
        The curated pool-host metric filter shared by the seed and live-monitor sync.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return 'up|scrape_.*|windows_memory_.*|windows_cpu_time_total|windows_logical_disk_.*|windows_os_(info|hostname)|windows_exporter_(build_info|collector_success|collector_duration_seconds|scrape_collector_success|scrape_duration_seconds)|windows_hyperv_hypervisor_(logical_processor_(time_total|total_run_time_total|context_switches_total)|root_virtual(_processor)?_(time_total|cpu_wait_time_per_dispatch_total)|virtual_processor_((mode_)?time_total|(total_)?run_time_total|cpu_wait_time_per_dispatch_total))'
}

function Get-YurunaHostMetricsCapability {
    <#
    .SYNOPSIS
        Describe observed CPU metric capabilities separately from exporter readiness.
    .DESCRIPTION
        Guest series do not exist on an idle host. A missing running-VM census is
        unknown, not proof that a guest is absent. Stock dispatch-wait counters
        remain raw evidence; the host sampler records PDH-formatted averages.
    .PARAMETER Payload
        Local exporter exposition, including its build-info sample.
    .PARAMETER RunningVmCount
        Number of running VMs, or null when VM enumeration failed.
    #>
    [CmdletBinding()]
    param([string]$Payload, [Nullable[int]]$RunningVmCount)
    $samples = @("$Payload" -split "`r?`n" | Where-Object { $_ -match '^windows_[a-zA-Z0-9_]+(?:\{[^}]*\})?\s+[-+0-9.eE]+(?:\s|$)' })
    $checks = [ordered]@{
        GuestRuntime = '^windows_hyperv_hypervisor_virtual_processor_(?:mode_)?time_total\{[^}]*state="guest"'
        GuestHypervisorRuntime = '^windows_hyperv_hypervisor_virtual_processor_(?:mode_)?time_total\{[^}]*state="hypervisor"'
        LogicalProcessorRuntime = '^windows_hyperv_hypervisor_logical_processor_time_total\{'
        RootProcessorRuntime = '^windows_hyperv_hypervisor_root_virtual_processor_time_total\{'
        VirtualProcessorSwitches = '^windows_hyperv_hypervisor_logical_processor_context_switches_total\{'
        RawDispatchWait = '^windows_hyperv_hypervisor_virtual_processor_cpu_wait_time_per_dispatch_total\{'
    }
    $capabilities = [ordered]@{}
    foreach ($name in $checks.Keys) {
        $guestOnly = $name -in @('GuestRuntime','GuestHypervisorRuntime','RawDispatchWait')
        $matched = @($samples | Where-Object { $_ -match $checks[$name] })
        $status = if ($guestOnly -and $null -ne $RunningVmCount -and $RunningVmCount -eq 0) { 'not-applicable' } elseif ($matched.Count) { 'present' } else { 'absent' }
        $capabilities[$name] = [pscustomobject]@{ Status=$status; SeriesCount=$matched.Count; Reason=if ($status -eq 'not-applicable') { 'No running VM.' } elseif ($status -eq 'absent') { 'No matching sample; capability is unavailable, not zero.' } else { '' } }
    }
    [pscustomobject]@{
        Status = if ($samples.Count) { 'present' } else { 'absent' }
        Readiness = Test-YurunaHostMetricsPayload -Payload $Payload
        RunningVmCount = $RunningVmCount
        BuildInfo = @($samples | Where-Object { $_ -match '^windows_exporter_build_info(?:\{|\s)' })
        Capabilities = [pscustomobject]$capabilities
    }
}

function Get-YurunaHostMetricsServiceCommandLine {
    # Thin wrapper over the CIM read so tests have one direct-call seam to mock
    # instead of standing up a fake CIM provider. Windows-only; the caller
    # guards on $IsWindows.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ServiceName)
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    if (-not $service) { return '' }
    return "$($service.PathName)"
}

function Set-YurunaHostMetricsServiceCommandLine {
    # sc.exe is how a service's binary path is rewritten, and 'binPath=' must
    # stay a separate argument from its value -- sc.exe parses the trailing
    # space, not the equals sign. Kept as its own seam so the rewrite is
    # mockable and the converger below reads as intent.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][string]$CommandLine
    )
    if (-not $PSCmdlet.ShouldProcess($ServiceName, 'Set the service binary path')) { return 0 }
    $scExe = Join-Path $env:WINDIR 'System32\sc.exe'
    & $scExe config $ServiceName binPath= $CommandLine | Out-Null
    return $LASTEXITCODE
}

function Invoke-YurunaHostMetricsProbe {
    <#
    .SYNOPSIS
        Scrape the existing exporter over loopback with a bounded request.
    .DESCRIPTION
        Endpoint readiness does not establish firewall reachability from the monitor.
    .PARAMETER Port
        Existing exporter listen port.
    .PARAMETER TimeoutSec
        Maximum duration of the local HTTP request.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 10
    )
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/metrics" -UseBasicParsing -TimeoutSec $TimeoutSec
        return "$($response.Content)"
    } catch {
        Write-Verbose "host-metrics probe failed: $($_.Exception.Message)"
        return ''
    }
}

function Set-YurunaHostMetricsFirewallRule {
    <#
    .SYNOPSIS
        Allow inbound TCP on the exporter port from the scraping host only.
    .DESCRIPTION
        Idempotent, best-effort, and never throws. Unlike the status page,
        which is meant to be opened from any browser on the LAN, this endpoint
        enumerates the host's processes, disks and guests, so the rule carries
        a RemoteAddress scope and is rebuilt whenever the live rule's shape or
        scope has drifted from it.
    .PARAMETER Port
        The exporter's TCP port.
    .PARAMETER RemoteAddress
        The addresses allowed to scrape.
    .OUTPUTS
        [pscustomobject] Ensured, Changed, Message.
    .EXAMPLE
        Set-YurunaHostMetricsFirewallRule -Port 9182 -RemoteAddress @('192.0.2.42')
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$RemoteAddress
    )
    $result = [pscustomobject]@{ Ensured = $false; Changed = $false; Message = '' }
    if (-not $IsWindows) {
        $result.Message = 'the host-metrics exporter is a Windows host component.'
        return $result
    }
    try {
        $ruleName = Get-YurunaHostMetricsFirewallRuleName -Port $Port
        $scope = @($RemoteAddress | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        # An empty scope is the one value that would widen the rule to Any, so
        # it becomes the narrowest thing still meaningful instead.
        if ($scope.Count -eq 0) { $scope = @('LocalSubnet') }
        $desc = "Allow the monitoring host to scrape http://<host>:$Port/metrics. Scoped to $($scope -join ', ') because host metrics enumerate this host's processes, disks and guests. Created by Yuruna (test/modules/Test.HostMetricsExporter.psm1)."
        $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        $filter = if ($existing) { Get-YurunaMetricsRulePortFilter -Rule $existing } else { $null }
        $address = if ($existing) { Get-YurunaMetricsRuleAddressFilter -Rule $existing } else { $null }
        $liveScope = @(if ($address) { @($address.RemoteAddress) } else { @() })
        $scopeCorrect = ($liveScope.Count -eq $scope.Count) -and
            (-not (Compare-Object -ReferenceObject $scope -DifferenceObject $liveScope -SyncWindow 0))
        $shapeCorrect = $filter -and ($filter.Protocol -eq 'TCP') -and ($filter.LocalPort -eq "$Port") -and
            ($existing.Direction -eq 'Inbound') -and ($existing.Action -eq 'Allow') -and $scopeCorrect
        if ($shapeCorrect -and $existing.Enabled -eq 'True') {
            $result.Ensured = $true
            $result.Message = "Windows Firewall rule '$ruleName' already present, scoped and enabled."
            Write-Verbose $result.Message
            return $result
        }
        if ($existing) {
            if ($PSCmdlet.ShouldProcess($ruleName, "Rebuild inbound TCP :$Port allow rule scoped to the monitoring host")) {
                Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
                $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                    -RemoteAddress $scope -Profile Any
                $result.Changed = $true
            }
        } else {
            if ($PSCmdlet.ShouldProcess($ruleName, "Create inbound TCP :$Port allow rule scoped to the monitoring host")) {
                $null = New-NetFirewallRule -DisplayName $ruleName -Description $desc `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port `
                    -RemoteAddress $scope -Profile Any
                $result.Changed = $true
            }
        }
        $result.Ensured = $true
        $result.Message = if ($result.Changed) { "Ensured Windows Firewall rule '$ruleName' for $($scope -join ', ')." }
                          else { "Windows Firewall rule '$ruleName' not applied (WhatIf)." }
        Write-Information $result.Message
    } catch {
        $result.Message = "Set-YurunaHostMetricsFirewallRule: $($_.Exception.Message)"
        Write-Verbose $result.Message
    }
    return $result
}

function Get-YurunaMetricsRulePortFilter {
    # Wrapper over the pipeline read '$rule | Get-NetFirewallPortFilter' so tests
    # have a direct-call seam to mock: a module-scoped Mock does not reliably
    # intercept a piped cmdlet call.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    return ($Rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)
}

function Get-YurunaMetricsRuleAddressFilter {
    # The scope half of the same read, for the same reason.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Rule)
    return ($Rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue)
}

function Get-YurunaHostMetricsPackageId {
    <#
    .SYNOPSIS
        The package identifier the exporter is acquired under.
    .DESCRIPTION
        Named once so the command printed in a warning, the command actually
        run, and the command an operator is told to undo the install with can
        never drift apart.
    .OUTPUTS
        [string]
    .EXAMPLE
        Get-YurunaHostMetricsPackageId
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:HostMetricsPackageId
}

function Get-YurunaHostMetricsInstallArgument {
    <#
    .SYNOPSIS
        The exact argument list the package manager is invoked with.
    .DESCRIPTION
        Pure, and its own function rather than an inline list, because the one
        property that makes an unattended install safe at all is a property of
        this list: nothing in it can stop and ask a question. A loop waiting on
        a prompt nobody is present to answer is a hang, not a slow cycle, so
        "cannot prompt" has to be something a test can assert rather than
        something a reader has to re-derive from a spawn call.

        What each group is carrying:
          * the id, --exact and an explicit --source pin the one package, since
            an inexact query can resolve to something else entirely;
          * --silent, both agreement flags and --disable-interactivity are what
            remove every question the package manager could ask. A package
            manager too old to know the last flag fails the command outright,
            which is the safe direction: one bounded failed attempt, recorded
            and spaced, rather than a cycle stopped at a prompt;
          * --no-upgrade means this call can only ever CREATE the package, never
            replace a running service underneath a cycle that is using it;
          * --scope machine is what registers a machine-wide service rather than
            something private to one profile, which would register no service at
            all;
          * --log is the diagnostic, and the only one -- see
            Invoke-YurunaWingetInstall for why no stream is redirected.
    .PARAMETER PackageId
        The package to install.
    .PARAMETER LogPath
        Where the package manager writes its own transcript. Empty omits it.
    .OUTPUTS
        [string[]]
    .EXAMPLE
        Get-YurunaHostMetricsInstallArgument -PackageId 'Prometheus.WindowsExporter' -LogPath ''
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageId,
        [AllowEmptyString()][string]$LogPath = ''
    )
    $argument = [System.Collections.Generic.List[string]]::new()
    $argument.AddRange([string[]]@(
        'install', '--id', $PackageId, '--exact', '--source', 'winget',
        '--scope', 'machine', '--silent', '--no-upgrade',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    ))
    if ("$LogPath".Trim()) { $argument.AddRange([string[]]@('--log', $LogPath)) }
    return $argument.ToArray()
}

function Get-YurunaWingetPath {
    # Resolving the executable rather than calling the name is what makes the
    # install attempt honest about the one context it cannot run in. winget
    # ships as a per-user app execution alias, so it exists for accounts that
    # have the package registered and does not exist for a service identity --
    # and an unresolvable name would otherwise surface as a generic command-not-
    # found several layers away from the reason. Returns '' rather than throwing.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $command = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command -and $command.Source) { return "$($command.Source)" }
        # The alias directory is on PATH for an interactive logon and can be
        # missing from an elevated shell that inherited a trimmed environment;
        # naming it directly recovers that case without changing which binary
        # runs.
        if ($env:LOCALAPPDATA) {
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $alias) { return $alias }
        }
    } catch {
        Write-Verbose "winget lookup failed: $($_.Exception.Message)"
    }
    return ''
}

function Test-YurunaHostMetricsElevated {
    # Registering a machine-wide service is an Administrator operation, and the
    # answer differs between the two callers of this module, so it is asked
    # rather than assumed.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]'Administrator')
    } catch {
        Write-Verbose "elevation check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-YurunaHostLastBootTime {
    # A seam over the CIM read so the throttle's boot-reset branch is testable
    # without a reboot. Returns $null when the read fails, which the caller
    # treats as "no boot information", not as "never rebooted".
    [CmdletBinding()]
    [OutputType([datetime])]
    param()
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os -and $os.LastBootUpTime) { return ([datetime]$os.LastBootUpTime).ToUniversalTime() }
    } catch {
        Write-Verbose "last boot time read failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-YurunaHostMetricsInstallStatePath {
    <#
    .SYNOPSIS
        Where a failed install attempt is remembered, or '' when nothing should
        remember one.
    .DESCRIPTION
        The record exists to keep an unattended loop from spending part of every
        cycle on an install that is not going to work, so it lives beside the
        loop's other runtime state and is keyed to that directory. No runtime
        directory means no unattended loop to protect: an operator running host
        setup by hand is present for the attempt, is waiting on it, and must not
        be told that the last failure bought a silence they never asked for --
        so that caller gets '' and every run attempts.

        This is the only record of its kind, and deliberately so. A caller that
        kept a second one would be a second policy on the same decision, and the
        composite of two intervals is neither one's stated interval.
    .OUTPUTS
        [string] full path, or '' when no attempt should be recorded.
    .EXAMPLE
        Get-YurunaHostMetricsInstallStatePath
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = "$env:YURUNA_RUNTIME_DIR".Trim()
    if (-not $dir) { return '' }
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    return (Join-Path $dir 'host-metrics.install.json')
}

function Get-YurunaHostMetricsInstallLogPath {
    # winget writes its own transcript when handed a location, which is the
    # capture this module can afford: see Invoke-YurunaWingetInstall for why the
    # streams themselves are deliberately not redirected. One file, overwritten
    # per attempt -- attempts are rare by construction, so a history would be a
    # directory of near-identical failures nobody reads.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($candidate in @($env:YURUNA_LOG_DIR, $env:YURUNA_RUNTIME_DIR)) {
        $dir = "$candidate".Trim()
        if ($dir -and (Test-Path -LiteralPath $dir)) {
            return (Join-Path $dir 'host-metrics.install.winget.log')
        }
    }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'host-metrics.install.winget.log')
}

function Get-YurunaHostMetricsInstallAttempt {
    # Reads the attempt record. An absent, unreadable or unparseable file is
    # reported as $null -- "no record" -- because the only consequence is one
    # more attempt, and a throttle that fails toward trying again is the safe
    # direction for a record whose whole purpose is to suppress work.
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if (-not "$Path".Trim()) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $record = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $record -or -not $record.lastAttemptUtc) { return $null }
        $stamp = $record.lastAttemptUtc
        # ConvertFrom-Json recognizes a round-trip timestamp and hands back a
        # [datetime], already carrying the right instant and Kind. Formatting
        # that back into a string to re-parse it is what breaks: the default
        # format drops the zone marker, so the re-parse reads a UTC instant as a
        # local one and the record lands one whole UTC offset away -- which on a
        # host west of the meridian reads as an attempt in the FUTURE and
        # cancels the interval, and east of it silences the install for hours
        # longer than intended. So the typed value is used as the typed value,
        # and only a value that really is text is parsed as text.
        if ($stamp -is [datetime]) { return ([datetime]$stamp).ToUniversalTime() }
        return ([datetimeoffset]::Parse("$stamp", [cultureinfo]::InvariantCulture)).UtcDateTime
    } catch {
        Write-Verbose "host-metrics install record at $Path unreadable: $($_.Exception.Message)"
        return $null
    }
}

function Set-YurunaHostMetricsInstallAttempt {
    # Writes the attempt record. A plain write rather than the atomic sidecar
    # pattern: one writer, and a torn read is indistinguishable from no record,
    # which costs a single extra attempt.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        [AllowNull()][object]$ExitCode
    )
    if (-not "$Path".Trim()) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Record the host-metrics install attempt')) { return $false }
    try {
        $payload = [ordered]@{
            lastAttemptUtc = [datetime]::UtcNow.ToString('o')
            reason         = "$Reason"
            exitCode       = $ExitCode
        }
        [System.IO.File]::WriteAllText($Path, ($payload | ConvertTo-Json -Compress),
            [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Verbose "host-metrics install record write to $Path failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-YurunaHostMetricsInstallDue {
    <#
    .SYNOPSIS
        Whether an install attempt is allowed now, given when the last one
        failed and when the host last started.
    .DESCRIPTION
        An attempt costs a package download and a service registration inside a
        cycle's budget, and the failures that do not clear on their own -- a
        package manager this identity cannot reach, a source the host is not
        allowed to fetch from, an installer a policy refuses -- would otherwise
        pay that cost every cycle forever for the same answer. So a failed
        attempt buys a quiet interval.

        Only a real attempt buys one. The interval is measured from work that
        was actually done, never from a pass that decided to do nothing, or a
        host that failed once would walk its own interval outward on cycles
        where nothing was tried.

        Two things end it early, and both are events where the reason may have
        changed rather than clocks running out. A host that has started since
        the last attempt is a host somebody worked on -- a reboot is where a
        policy edit, a network change or a hand-run setup lands -- and holding
        the interval across it would delay the very recovery the reboot was for.
        Deleting the record is the operator's own way of saying the same thing.

        Pure, so the interval is exercised as arithmetic rather than by waiting.
    .PARAMETER LastAttemptUtc
        When the last attempt failed. $null means no attempt is on record.
    .PARAMETER BootTimeUtc
        When the host last started. $null means the boot time is unknown, which
        must not be read as "has not rebooted": an unknown boot time leaves the
        interval in force rather than canceling it.
    .PARAMETER NowUtc
        The current time.
    .PARAMETER RetryHours
        The quiet interval a failed attempt buys.
    .OUTPUTS
        [pscustomobject] Due, Reason.
    .EXAMPLE
        Test-YurunaHostMetricsInstallDue -LastAttemptUtc $t -BootTimeUtc $b -NowUtc ([datetime]::UtcNow) -RetryHours 6
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][Nullable[datetime]]$LastAttemptUtc,
        [AllowNull()][Nullable[datetime]]$BootTimeUtc,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [Parameter(Mandatory)][ValidateRange(1, 168)][int]$RetryHours
    )
    if ($null -eq $LastAttemptUtc) {
        return [pscustomobject]@{ Due = $true; Reason = 'no install attempt is on record for this host' }
    }
    $last = ([datetime]$LastAttemptUtc)
    # A record stamped in the future is a clock that moved, not a recent
    # attempt; leaving it in force would silence the install until the clock
    # caught up, which on a badly set host is never.
    if ($last -gt $NowUtc) {
        return [pscustomobject]@{ Due = $true; Reason = 'the recorded attempt is in the future, so the interval cannot be measured' }
    }
    if ($null -ne $BootTimeUtc -and ([datetime]$BootTimeUtc) -gt $last) {
        return [pscustomobject]@{ Due = $true; Reason = 'the host has started since the last attempt' }
    }
    $elapsed = $NowUtc - $last
    if ($elapsed.TotalHours -ge $RetryHours) {
        return [pscustomobject]@{ Due = $true; Reason = "the last attempt was $([int]$elapsed.TotalHours) hours ago" }
    }
    $wait = [int][math]::Ceiling($RetryHours - $elapsed.TotalHours)
    return [pscustomobject]@{
        Due    = $false
        Reason = "an install attempt failed less than $RetryHours hours ago; the next one is about $wait hours away, or at the host's next start"
    }
}

function Invoke-YurunaWingetInstall {
    # The install call itself, kept as its own seam so every caller above can be
    # exercised without a package manager. The argument list it runs -- and the
    # reason nothing in that list can lead to a prompt -- is
    # Get-YurunaHostMetricsInstallArgument.
    #
    # The streams are deliberately NOT redirected, and neither -Wait nor the
    # parameterless WaitForExit() is used. Redirecting any stream turns on
    # handle inheritance for the whole subtree, which is how a descendant that
    # outlives this call pins the pipe an enclosing process is reading and hangs
    # it with no output and no timeout (see feedback_windows-detached-grandchild-
    # pins-pipe). Passing no streams makes this a ShellExecute spawn, which
    # hands down no inheritable handles at all; the timed WaitForExit overload
    # waits on this process alone; and the package manager's own log file is
    # where the diagnostic goes instead.
    #
    # Killing on the deadline stops this process waiting -- it does not stop an
    # installer already handed to the operating system's own installer service.
    # That is why the caller decides the outcome by looking for the service
    # afterward rather than by trusting the exit code: an install that lands a
    # minute after the deadline is found by the next cycle's presence check.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WingetPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PackageId,
        [Parameter(Mandatory)][ValidateRange(10, 3600)][int]$TimeoutSec,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogPath
    )
    $outcome = [pscustomobject]@{ Started = $false; TimedOut = $false; ExitCode = $null; Message = '' }
    if (-not $PSCmdlet.ShouldProcess($PackageId, 'Install the package with winget')) {
        $outcome.Message = 'the install was not run'
        return $outcome
    }
    $argument = Get-YurunaHostMetricsInstallArgument -PackageId $PackageId -LogPath $LogPath
    try {
        $process = Start-Process -FilePath $WingetPath -ArgumentList $argument `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        $outcome.Message = "winget did not start: $($_.Exception.Message)"
        return $outcome
    }
    if (-not $process) {
        $outcome.Message = 'winget did not start and reported no error'
        return $outcome
    }
    $outcome.Started = $true
    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        $outcome.TimedOut = $true
        $outcome.Message = "winget did not finish within $TimeoutSec seconds and was stopped"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        return $outcome
    }
    try { $outcome.ExitCode = [int]$process.ExitCode } catch {
        Write-Verbose "winget exit code unreadable: $($_.Exception.Message)"
    }
    $outcome.Message = "winget exited $($outcome.ExitCode)"
    return $outcome
}

function Install-YurunaHostMetricsExporter {
    <#
    .SYNOPSIS
        Bring the host-metrics exporter into existence when the host has none,
        or say precisely why this host is not going to get one.
    .DESCRIPTION
        The converger below can only fix a service that exists. On a host that
        never had one there is nothing to converge, and until the package is
        present the memory evidence that explains a refused allocation is not
        being recorded at all -- so acquiring it is part of the same job.

        NEVER THROWS AND NEVER COSTS A CONVERGED HOST ANYTHING. The first thing
        asked is whether the service is already registered, which is a local
        query and the answer on every host after the first time; nothing beyond
        that runs until the answer is no. The two conditions that make an
        install impossible rather than merely unlucky -- no Administrator
        rights, no package manager for this identity -- are both free to check
        and are checked before anything is spent, so neither consumes an
        attempt.

        The service, not the binary on disk, is what decides "already present":
        the converger operates on a service, a package whose service was
        unregistered is not something a fresh install repairs, and treating a
        stray executable as an install would leave the host permanently
        reported as instrumented while publishing nothing.

        Bounded on both axes, and this function owns both bounds. One attempt
        is bounded in time by -TimeoutSec, so a cycle can lose that much and no
        more; attempts are bounded in frequency by the record
        Test-YurunaHostMetricsInstallDue reads, so a host where the install
        cannot work loses that much a handful of times a day rather than every
        cycle. Callers pass neither and keep no copy of either: a bound with two
        owners is a bound that stops being enforced the moment the two disagree,
        and nothing about the failure looks like a bound. Neither bound can fail
        anything -- every path here returns a result, and the caller treats an
        absent exporter as a warning.
    .PARAMETER TimeoutSec
        How long one attempt may run before it is stopped. The default is
        several times what the download and a service registration cost, which
        makes reaching it evidence that something is wrong rather than slow --
        and a cycle must not spend more of itself on telemetry than that.
    .PARAMETER RetryHours
        The quiet interval a failed attempt buys.
    .OUTPUTS
        [pscustomobject] Installed, Changed, Outcome, Reason, ExitCode.
        Outcome is one of: not-applicable, already-present, installed,
        skipped-throttled, skipped-whatif, unavailable, failed.
    .EXAMPLE
        Install-YurunaHostMetricsExporter
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(10, 3600)][int]$TimeoutSec = $script:HostMetricsInstallTimeoutSec,
        [ValidateRange(1, 168)][int]$RetryHours = $script:HostMetricsInstallRetryHours
    )
    $result = [pscustomobject]@{
        Installed = $false; Changed = $false
        Outcome   = 'not-applicable'; Reason = ''; ExitCode = $null
    }
    if (-not $IsWindows) {
        $result.Reason = 'the host-metrics exporter is a Windows host component.'
        return $result
    }
    $serviceName = Get-YurunaHostMetricsServiceName
    $packageId = Get-YurunaHostMetricsPackageId
    # Resolved above the try, and the flag set the moment the package manager is
    # handed the job, because a spent attempt that leaves no record is an
    # attempt the next cycle repeats in full. A throw between the invocation and
    # the presence check is exactly that case: the acquisition already cost what
    # it costs, and only the bookkeeping is missing.
    $statePath = ''
    $attemptSpent = $false
    try {
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            $result.Installed = $true
            $result.Outcome = 'already-present'
            $result.Reason = "the $serviceName service is already registered on this host"
            return $result
        }
        if (-not (Test-YurunaHostMetricsElevated)) {
            $result.Outcome = 'unavailable'
            $result.Reason = "registering the $serviceName service needs Administrator rights, which this session does not hold"
            return $result
        }
        $winget = Get-YurunaWingetPath
        if (-not $winget) {
            $result.Outcome = 'unavailable'
            $result.Reason = 'winget is not available to this account, so the exporter package cannot be acquired from here'
            return $result
        }
        $statePath = Get-YurunaHostMetricsInstallStatePath
        $due = Test-YurunaHostMetricsInstallDue -LastAttemptUtc (Get-YurunaHostMetricsInstallAttempt -Path $statePath) `
            -BootTimeUtc (Get-YurunaHostLastBootTime) -NowUtc ([datetime]::UtcNow) -RetryHours $RetryHours
        if (-not $due.Due) {
            $result.Outcome = 'skipped-throttled'
            $result.Reason = $due.Reason
            return $result
        }
        if (-not $PSCmdlet.ShouldProcess($packageId, "Install the host-metrics exporter (up to $TimeoutSec seconds)")) {
            $result.Outcome = 'skipped-whatif'
            $result.Reason = 'the install was not run'
            return $result
        }
        $logPath = Get-YurunaHostMetricsInstallLogPath
        # Said before the blocking call, not after: an unexplained multi-minute
        # gap reads as a wedged runner, which is the thing an operator is
        # trained to go and kill. On the information stream so that a caller
        # capturing this function's value cannot pick the line up as data, and
        # forced to Continue because that stream is silent at the runner's
        # default preference -- an announcement nobody sees is not one.
        Write-Information "Host metrics: no $serviceName service on this host; installing $packageId ($($due.Reason)). Up to $TimeoutSec seconds, then this cycle continues either way." -InformationAction Continue
        $attemptSpent = $true
        $run = Invoke-YurunaWingetInstall -WingetPath $winget -PackageId $packageId -TimeoutSec $TimeoutSec -LogPath $logPath
        $result.ExitCode = $run.ExitCode
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            $result.Installed = $true
            $result.Changed = $true
            $result.Outcome = 'installed'
            $result.Reason = "installed $packageId and the $serviceName service is now registered"
            # The record only exists to hold off a repeat of something that did
            # not work; an install that worked must not leave one behind for the
            # next host state that needs an attempt.
            if ($statePath -and (Test-Path -LiteralPath $statePath)) {
                Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            }
            return $result
        }
        $result.Outcome = 'failed'
        $result.Reason = if ($run.TimedOut) {
            "$($run.Message); the $serviceName service is not registered yet. If the installer finished on its own afterward, the next pass finds it."
        } elseif (-not $run.Started) {
            $run.Message
        } else {
            "$($run.Message) but no $serviceName service was registered. The package manager's log is at $logPath."
        }
        $null = Set-YurunaHostMetricsInstallAttempt -Path $statePath -Reason $result.Reason -ExitCode $result.ExitCode -Confirm:$false
    } catch {
        # A throw before the package manager ran costs nothing and must not
        # silence the next cycle, so only an attempt that reached the
        # invocation is recorded. Recording it here is what stops a fault
        # between the invocation and the presence check -- a service query that
        # throws, say -- from buying a full reinstall on every cycle for as
        # long as the fault lasts.
        $result.Outcome = 'failed'
        $result.Reason = "Install-YurunaHostMetricsExporter: $($_.Exception.Message)"
        if ($attemptSpent) {
            $null = Set-YurunaHostMetricsInstallAttempt -Path $statePath -Reason $result.Reason -ExitCode $result.ExitCode -Confirm:$false
        }
    }
    return $result
}

function Set-YurunaHostMetricsExporter {
    <#
    .SYNOPSIS
        Bring the host-metrics exporter to the state this host needs, or say
        why it could not be.
    .DESCRIPTION
        Idempotent and safe to run on every host-setup pass: it detects an
        existing install rather than reinstalling, and rewrites the service
        only when the collector set or listen port it is actually running
        disagrees with the one this host publishes.

        NOT A PREREQUISITE. Nothing here is allowed to fail a setup run or a
        test cycle, and an absent exporter is reported as a warning with the
        command that installs it -- never as an unmet condition. An endpoint
        that only records why a host failed must not become a new reason for
        one to fail, and a host marked degraded over missing telemetry, on a
        machine that runs its guests perfectly, teaches operators to ignore the
        degraded state that matters.

        Not called per cycle. Initialize-WindowsHostMetricsExporter is what the
        cycle path calls, and it reaches this function only on the one cycle
        that installed the service. After that the exporter is a service: once
        it is running with the right flags it stays that way across reboots,
        and the
        scrape is its own watchdog -- a stopped exporter shows as a target
        down in the monitoring stack within one interval, which is a better
        signal than a per-cycle check that costs every cycle a service query
        and reports to a log nobody reads.

        The command-line rewrite reverts itself. A flag this release of the
        exporter does not understand makes the service fail to start, which
        would take away metrics that were working; so the previous command
        line is restored and the service restarted whenever the rewritten one
        does not come up and answer.
    .PARAMETER ConfigIp
        The configured caching-proxy address, used to scope the firewall rule.
    .PARAMETER EnvIp
        The session override for the same address.
    .PARAMETER SkipInstall
        Converge only what is already there. Acquiring an absent exporter is the
        default because an absent one is the largest deviation from the state
        this function exists to establish, and every bound that keeps the
        acquisition safe lives inside it rather than in the callers. This switch
        is for the caller that wants a reading of the host rather than a change
        to it, and for the caller that has just installed the exporter itself
        and is now only configuring it.
    .OUTPUTS
        [pscustomobject] Installed, Running, Ensured, Changed, Message.
    .EXAMPLE
        Set-YurunaHostMetricsExporter -ConfigIp '192.0.2.42'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$ConfigIp,
        [string]$EnvIp,
        [switch]$SkipInstall
    )
    $result = [pscustomobject]@{ Installed = $false; Running = $false; Ensured = $false; Changed = $false; Message = '' }
    if (-not $IsWindows) {
        $result.Message = 'the host-metrics exporter is a Windows host component.'
        return $result
    }
    $serviceName = Get-YurunaHostMetricsServiceName
    $port = Get-YurunaHostMetricsPort
    try {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $acquisition = ''
        if (-not $service -and -not $SkipInstall) {
            $install = Install-YurunaHostMetricsExporter
            $acquisition = "$($install.Reason)"
            if ($install.Changed) { $result.Changed = $true }
            # Re-read rather than trust the flag: the service the rest of this
            # function operates on has to be the live object, and an install
            # that landed is only useful if this pass can go on to configure it.
            if ($install.Installed) { $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue }
        }
        if (-not $service) {
            $detail = if ($acquisition) { "Installing it did not get there: $acquisition." }
                      else { 'Installing it was not attempted on this pass.' }
            $result.Message = @"
No host-metrics exporter on this host, so nothing records its memory, CPU, disk
or VM state. A refused allocation here cannot be explained afterward.
$detail
To put it there by hand, from an elevated prompt on the host:
  winget install --id $(Get-YurunaHostMetricsPackageId) --exact --source winget --silent
"@
            Write-Warning $result.Message
            return $result
        }
        $result.Installed = $true

        # Start type first: a service that only runs until the next reboot
        # leaves a gap exactly where an overnight run would have needed it.
        if ($service.StartType -ne 'Automatic') {
            if ($PSCmdlet.ShouldProcess($serviceName, 'Set start type to Automatic')) {
                Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
                $result.Changed = $true
            }
        }

        $current = Get-YurunaHostMetricsServiceCommandLine -ServiceName $serviceName
        $plan = Resolve-YurunaHostMetricsCommandLine -CurrentCommandLine $current `
            -Collector (Get-YurunaHostMetricsCollector) -Port $port
        if (-not $plan.Matches -and $plan.Executable) {
            Write-Information "Host metrics: $($plan.Reason); rewriting the exporter service command line."
            if ($PSCmdlet.ShouldProcess($serviceName, 'Publish the collector set this host needs')) {
                $code = Set-YurunaHostMetricsServiceCommandLine -ServiceName $serviceName -CommandLine $plan.Desired
                if ($code -ne 0) {
                    Write-Warning "Could not rewrite the $serviceName service command line (sc.exe exit $code); it keeps the collectors it had."
                } else {
                    $result.Changed = $true
                    Restart-Service -Name $serviceName -ErrorAction SilentlyContinue
                    if (-not (Test-YurunaHostMetricsAnswering -Port $port)) {
                        # The rewrite is the only thing that changed, so the
                        # rewrite is what goes back.
                        Write-Warning "The $serviceName service did not answer after the collector rewrite; restoring the command line it had."
                        $null = Set-YurunaHostMetricsServiceCommandLine -ServiceName $serviceName -CommandLine $current
                        Restart-Service -Name $serviceName -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne 'Running') {
            if ($PSCmdlet.ShouldProcess($serviceName, 'Start the service')) {
                Start-Service -Name $serviceName -ErrorAction SilentlyContinue
                $result.Changed = $true
            }
        }
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        $result.Running = ($service -and $service.Status -eq 'Running')

        $scope = Get-YurunaHostMetricsScrapeSource -ConfigIp $ConfigIp -EnvIp $EnvIp
        $firewall = Set-YurunaHostMetricsFirewallRule -Port $port -RemoteAddress $scope
        if ($firewall.Changed) { $result.Changed = $true }

        # Only the exposition proves the host is instrumented; the flags and the
        # service state are what was asked for, not what arrived.
        $payload = Invoke-YurunaHostMetricsProbe -Port $port
        $check = Test-YurunaHostMetricsPayload -Payload $payload
        if ($check.Ok) {
            $result.Ensured = $true
            $result.Message = "Host metrics: http://<host>:$port/metrics publishes $((Get-YurunaHostMetricsCollector) -join ', ') to $($scope -join ', ')."
            Write-Information $result.Message
        } elseif (-not $payload) {
            $result.Message = "Host metrics: the $serviceName service is present but http://127.0.0.1:$port/metrics did not answer, so this host's memory and VM state are not being recorded."
            Write-Warning $result.Message
        } else {
            $result.Message = "Host metrics: http://127.0.0.1:$port/metrics answers but is missing $($check.Missing -join ', '). Reinstall the exporter with those collectors enabled."
            Write-Warning $result.Message
        }
    } catch {
        $result.Message = "Set-YurunaHostMetricsExporter: $($_.Exception.Message)"
        Write-Warning $result.Message
    }
    return $result
}

function Test-YurunaHostMetricsAnswering {
    # A restarted service binds its port a moment after the restart returns, so
    # the question is asked on a wall-clock deadline rather than once.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 20
    )
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        if ((Invoke-YurunaHostMetricsProbe -Port $Port -TimeoutSec 5)) { return $true }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadlineUtc)
    return $false
}

Export-ModuleMember -Function Set-YurunaHostMetricsExporter, Set-YurunaHostMetricsFirewallRule,
    Get-YurunaHostMetricsFirewallRuleName, Get-YurunaHostMetricsPort, Get-YurunaHostMetricsServiceName,
    Get-YurunaHostMetricsCollector, Get-YurunaHostMetricsScrapeSource,
    Resolve-YurunaHostMetricsCommandLine, Split-YurunaServiceCommandLine, Test-YurunaHostMetricsPayload,
    Install-YurunaHostMetricsExporter, Get-YurunaHostMetricsPackageId,
    Get-YurunaHostMetricsInstallArgument, Get-YurunaHostMetricsInstallStatePath,
    Test-YurunaHostMetricsInstallDue, Get-YurunaHostMetricsCapability, Invoke-YurunaHostMetricsProbe, Get-YurunaHostMetricsRetentionRegex
