<#PSScriptInfo
.VERSION 2026.08.23
.GUID 424f40c7-7c46-41e1-bd5e-d9b72a02a026
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

# Default stash-service extension. The Go daemon (SCP sink-mode wire-protocol
# handler, SQLite metadata index, on-disk storage layout) lives under
# [server/](server/); user guide: https://yuruna.link/stash-guide.
#
# Get-StashServiceInfo is a status stub returning a uniform hashtable in the
# host-side cmdlet vocabulary; host-side status probing (querying a running
# stash-service VM) is not wired yet, so the flags stay $false until that lands.
#
# Resolve-Host is the runtime stash-address discovery a sequence's `variables:`
# block consumes via ${ext:stash-service.ResolveHost(<vm>)}, so the stash IP is
# a discovered artifact instead of a hard-coded literal: the same live Get-VMIp
# lookup the caching-proxy-service/edge discovery uses, then the address a cycle
# published in <runtime>/stash-host.txt, then whatever the framework's
# Get-ExtensionHostAddress can find for the area -- the last of which answers
# for a lab whose stash runs on another host entirely.
#
# Test-StashServiceHost + Publish-StashServiceHost are the writer half: a
# cycle's warm-up resolves the stash ONCE, up front, confirms it answers
# /healthz, and publishes the address. Doing it there rather than per sequence
# means an unreachable stash stops the cycle before its long provisioning
# stages instead of after them, and later scenarios resolve the address without
# re-deriving it from a VM this host may not run at all. What the warm-up
# cannot settle is the REST of the cycle: it proves the address once, and a
# cycle runs for tens of minutes, so Resolve-Host re-probes what was published
# before handing it out and republishes whatever it falls through to.

function Get-StashServiceInfo {
    <#
    .SYNOPSIS
        Returns the stash-service extension's current status as a
        uniform hashtable, matching the host-side cmdlet vocabulary
        shape used elsewhere in the extension areas.
    .OUTPUTS
        @{ supported = $false; installed = $false; running = $false;
           message = '...'; daemonVersion = $null }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        supported     = $false
        installed     = $false
        running       = $false
        message       = 'stash-service: daemon source under server/; host-side status probing not wired yet. See https://yuruna.link/stash-guide.'
        daemonVersion = $null
    }
}

function Get-StashHostPath {
    <#
    .SYNOPSIS
        Absolute path of the file a cycle publishes its resolved stash
        address into: <runtime-dir>/stash-host.txt.
    .DESCRIPTION
        Runtime dir is $env:YURUNA_RUNTIME_DIR, defaulting to
        <repoRoot>/test/status/runtime -- the same location the rest of the
        per-cycle sidecar state lives in, git-ignored with it. Creates the
        directory on demand so writers don't have to Test-Path-and-mkdir.
    .OUTPUTS
        [string] absolute path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) {
        # This module sits at test/extension/stash-service/, so two levels up
        # is test/ -- the same default Initialize-YurunaRuntimeDir derives.
        $testRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $runtimeDir = Join-Path -Path $testRoot -ChildPath 'status' -AdditionalChildPath 'runtime'
    }
    if (-not (Test-Path -LiteralPath $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    return (Join-Path -Path $runtimeDir -ChildPath 'stash-host.txt')
}

function Get-PublishedStashServiceHost {
    <#
    .SYNOPSIS
        The stash address published for this cycle, or '' when nothing
        published one.
    .DESCRIPTION
        A lab whose stash is a fixed-address service rather than a VM on
        this host can never be answered by Get-VMIp, so the address is
        resolved once at the start of a cycle -- confirmed to answer
        /healthz there -- and written by Publish-StashServiceHost. Reading it makes
        every later ${ext:stash-service.ResolveHost(<vm>)} expansion agree
        with the address that pre-flight accepted, at no discovery cost and
        without each sequence re-reporting an absent VM.

        The file is per-cycle state, not a cache: the pre-flight rewrites it
        on success and clears it on failure, so a stash that moved between
        cycles never leaves a stale address behind for the next one. Within a
        cycle the same guarantee is Resolve-Host's, which probes this value
        before returning it and rewrites the file when it has to fall through
        -- so a stash that moves mid-cycle does not strand the rest of it
        either.
    .OUTPUTS
        [string] address, or '' when none is published.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $file = Get-StashHostPath
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    try {
        return ([string](Get-Content -LiteralPath $file -Raw -ErrorAction Stop)).Trim()
    } catch {
        Write-Verbose "stash-service.ResolveHost: reading '$file' failed: $($_.Exception.Message)"
        return ''
    }
}

function Test-StashServiceHost {
    <#
    .SYNOPSIS
        Reachability probe for a stash service: GET http://<address>/healthz.
    .DESCRIPTION
        HTTP :80 answering is exactly the gate the guest workloads apply
        before they upload to (or download from) the stash, and it stands in
        for scp :22 on the same host -- so a candidate that passes here is a
        candidate the guests will be able to use.

        The request retries instead of being given one wide deadline: over
        Wi-Fi the connect latency has a fat tail (a radio waking from
        power-save, ARP over the air, an AP retransmit or roam) that turns a
        single-shot probe into a spurious miss on a service that is up. The
        first attempt warms ARP and wakes the radio; a follow-up answers in
        milliseconds. A wired host passes on attempt 1 so the retries cost
        nothing there, and a stash that is genuinely down misses every
        attempt. See feedback_wifi-connect-timeout-tail.md.

        -NoProxy is deliberate: the stash sits on the lab LAN and the host
        may have a caching-proxy service in its environment that would neither reach
        it nor be meant to.
    .PARAMETER Address
        Host name, IP literal, or host:port authority of the stash service. A
        bare address is probed on the daemon's default port (80); an authority
        that already carries a port -- the UTM Shared-NAT forward, for
        instance -- is used verbatim.
    .PARAMETER Attempts
        Number of probe attempts before reporting unreachable (>=1).
    .PARAMETER TimeoutSeconds
        Per-attempt request deadline.
    .PARAMETER BackoffMs
        Delay before each retry (not applied before the first attempt).
    .OUTPUTS
        [bool] $true when any attempt got HTTP 200 from /healthz.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$Attempts = 3,
        [int]$TimeoutSeconds = 10,
        [int]$BackoffMs = 500
    )
    $target = "$Address".Trim()
    if (-not $target) { return $false }
    # An IPv6 literal has to be bracketed to be a legal URL authority. A name or
    # IPv4 literal never contains a colon, and an already-bracketed authority
    # (with or without a :port suffix) is left alone, so this only fires on a
    # bare IPv6 literal.
    if ($target.Contains(':') -and -not $target.StartsWith('[') -and ($target -split ':').Count -gt 2) {
        $target = "[$target]"
    }
    $url = "http://$target/healthz"
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Start-Sleep -Milliseconds $BackoffMs }
        try {
            $resp = Invoke-WebRequest -Uri $url -NoProxy -TimeoutSec $TimeoutSeconds -ErrorAction Stop
            if ([int]$resp.StatusCode -eq 200) { return $true }
            Write-Verbose "stash-service.TestStashServiceHost: $url attempt $attempt returned HTTP $([int]$resp.StatusCode)."
        } catch {
            Write-Verbose "stash-service.TestStashServiceHost: $url attempt $attempt failed: $($_.Exception.Message)"
        }
    }
    return $false
}

function Publish-StashServiceHost {
    <#
    .SYNOPSIS
        Records the stash address this cycle resolved, for every later
        ${ext:stash-service.ResolveHost(<vm>)} expansion to read back.
    .DESCRIPTION
        Written atomically (write .tmp + Move-Item) so a sequence expanding
        the variable concurrently never reads a half-written file. An empty
        Address CLEARS the record rather than publishing a blank: a cycle
        whose stash pre-flight found nothing must not leave the previous
        cycle's address in place for the guests to trust.
    .PARAMETER Address
        Resolved stash address, or '' to clear the record.
    .OUTPUTS
        [string] the address that was published, or '' when cleared.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    $path  = Get-StashHostPath
    $value = "$Address".Trim()
    if (-not $value) {
        if ($PSCmdlet.ShouldProcess($path, 'Clear the published stash address')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return ''
    }
    if (-not $PSCmdlet.ShouldProcess($path, "Publish stash address '$value'")) { return '' }
    $tmp = "$path.tmp"
    Set-Content -LiteralPath $tmp -Value $value -Encoding ascii -NoNewline
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $value
}

function Get-DiscoveredStashServiceHost {
    <#
    .SYNOPSIS
        The first stash address the framework can discover for this host, or ''
        when nothing knows of a live stash service.
    .DESCRIPTION
        Thin, failure-tolerant wrapper over the framework's
        Get-ExtensionHostAddress so the stash resolver has one call to make and
        every "nothing to ask" shape -- no framework module, no caching-proxy service,
        no aggregator, an aggregator that does not answer, an area nobody
        serves -- collapses to the same empty string rather than an error the
        caller must sort out.

        The local VM source is switched off (-VMName ''): Resolve-Host already
        asked the host contract, and a stash on this host is nearer than any
        discovered answer. What is left is the operator pin and the pool's own
        record -- exactly the sources that can answer for a stash living
        somewhere else.
    .OUTPUTS
        [string] address, or ''.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not (Get-Command Get-ExtensionHostAddress -ErrorAction SilentlyContinue)) {
        # test/extension/stash-service/ -> test/modules/
        $framework = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules' |
            Join-Path -ChildPath 'Test.Extension.psm1'
        if (-not (Test-Path -LiteralPath $framework)) { return '' }
        try { Import-Module $framework -Global -Force -DisableNameChecking -Verbose:$false }
        catch {
            Write-Verbose "stash-service: the extension framework module is not loadable: $($_.Exception.Message)"
            return ''
        }
    }
    try {
        $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '')
        if ($addresses.Count -eq 0) { return '' }
        return [string]$addresses[0]
    } catch {
        Write-Verbose "stash-service: the extension-host lookup failed: $($_.Exception.Message)"
        return ''
    }
}

function Resolve-Host {
    <#
    .SYNOPSIS
        Resolves the current address of the stash service, for a
        sequence's `variables:` block to consume via
        ${ext:stash-service.ResolveHost(<vm>)}.
    .DESCRIPTION
        Three sources, nearest first:

        1. Live host-contract lookup (Get-VMIp) -- the same mechanism the
           caching-proxy-service and edge VMs are discovered by -- so a stash-service VM on this
           host is always found at its current address, never a hard-coded
           literal.
        2. The address published for this cycle (Get-PublishedStashServiceHost),
           re-probed before it is handed out: the one the pre-flight proved
           answers /healthz, so a sequence agrees with the cycle instead of
           re-deriving it -- for as long as it still answers. The pre-flight
           runs once and a cycle runs for tens of minutes, so on a lab whose
           service addresses come from DHCP the published address can stop
           being the stash's address while the cycle that published it is still
           running. Trusting it unprobed hands a guest an address nothing is
           listening on, tens of minutes into a chain, with the pool already
           holding the right one; the probe costs one /healthz and converts
           that into a fall-through.
        3. Whatever the framework can discover for the area
           (Get-ExtensionHostAddress 'stash-service'): an operator pin, and the
           pool's record of where it sees the service announcing itself right
           now. This is what answers for a stash that lives on ANOTHER host --
           the common case, and the one the first two cannot reach. It costs one
           LAN call and only runs when the cheaper sources came up empty.

        With none of the three, returns '' and warns; the consuming guest script
        keeps a degraded-mode default (STASH_HOST="${STASH_HOST:-...}"), so an
        empty expansion falls back rather than failing the step.
    .PARAMETER VMName
        Stash VM name. Defaults to 'yuruna-stash-service' (the name
        Start-StashServiceVM.ps1 creates).
    .OUTPUTS
        [string] address, or '' when it cannot be resolved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$VMName = 'yuruna-stash-service')
    $ip = ''
    if (Get-Command Get-VMIp -ErrorAction SilentlyContinue) {
        try { $ip = [string](Get-VMIp -VMName $VMName) } catch {
            Write-Verbose "stash-service.ResolveHost: Get-VMIp '$VMName' failed: $($_.Exception.Message)"
        }
    } else {
        Write-Verbose "stash-service.ResolveHost: host contract has no Get-VMIp; cannot discover '$VMName'."
    }
    if ($ip) { return $ip }
    $published = Get-PublishedStashServiceHost
    if ($published) {
        if (Test-StashServiceHost -Address $published) {
            Write-Verbose "stash-service.ResolveHost: using the address published for this cycle ($published)."
            return $published
        }
        Write-Warning "stash-service.ResolveHost: the address published for this cycle ($published) no longer answers /healthz; asking the pool for the stash's current address."
    }
    $discovered = Get-DiscoveredStashServiceHost
    if ($discovered) {
        Write-Verbose "stash-service.ResolveHost: using the discovered address ($discovered)."
        # Republish so the rest of the cycle resolves the address that answered
        # rather than each expansion paying for the same rediscovery -- and so a
        # later expansion cannot go back to the dead one this call just rejected.
        $null = Publish-StashServiceHost -Address $discovered
        return $discovered
    }
    $publishedNote = if ($published) { "the address published for this cycle ($published) no longer answers" } else { 'no address published for this cycle' }
    Write-Warning "stash-service.ResolveHost: no IPv4 for '$VMName' (is it running?), $publishedNote, and nothing -- operator pin or pool -- reports a live stash service."
    return ''
}

Export-ModuleMember -Function Get-StashServiceInfo, Resolve-Host, Test-StashServiceHost, Publish-StashServiceHost, Get-DiscoveredStashServiceHost
