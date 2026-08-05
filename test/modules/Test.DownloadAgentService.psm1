<#PSScriptInfo
.VERSION 2026.08.05
.GUID 4239d599-3701-465c-b5ee-af4da9b7f14d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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
    Host-side logic for the download-agent service lifecycle: the runtime
    marker, the readiness probe, and the address the host publishes for the
    agent.
.DESCRIPTION
    Start-DownloadAgentServiceVM.ps1 and Stop-DownloadAgentServiceVM.ps1 run
    top-to-bottom with `exit` and heavy I/O (hypervisor calls, VM builds, SSH),
    so nothing in them can be reached by a test. Everything that has a decision
    in it lives here instead, where it is callable in isolation: what the marker
    contains, whether a port is accepting, how long to wait, and which address a
    peer should be told to use.

    The marker (runtime/download-agent-service.json) is the host's claim that it
    runs a download-agent service. Test.Capability folds it into
    host.registration.json, which the pool aggregator polls -- so `active` must
    carry the READINESS VERDICT rather than the fact that a bring-up ran, or the
    dashboard deep-links operators to a UI that is not serving.

    The marker functions here are thin wrappers over Test.ExtensionService, which
    every extension service now shares. They stay as named entry points because
    the callers and their tests are written against these names, and because the
    area slug is a detail the callers should not have to repeat.
#>

Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -Force -DisableNameChecking -Verbose:$false

# The extension area this module speaks for. Everything the marker layer needs
# beyond it -- the VM name, the per-service base-URL key -- is declared in that
# area's own manifest.
$script:Area = 'download-agent-service'

# The UTM Shared-NAT host port that forwards to the agent's :80. Peer hosts
# cannot route into the NAT segment, so a Shared-NAT agent is reachable only
# through the Mac's own LAN address on this port. 8082 keeps clear of the ports
# the sibling services already publish on a shared-services Mac (stash 2222,
# pool-control 8081, caching proxy 80).
$script:DownloadAgentServiceForwardedPort = 8082

# The daemon binds :80 in the guest (CAP_NET_BIND_SERVICE), matching the stash
# and pool-control services, so a bridged agent needs no port in its URL.
$script:DownloadAgentServicePort = 80

# A first boot installs the Go toolchain, builds the daemon, and mounts the pool
# share before anything binds :80. Minutes, not seconds -- and slower still when
# the apt traffic goes through a cold caching proxy: measured at roughly half an
# hour on an Apple Silicon UTM guest against a cold mirror, against the ten to
# fifteen a warm x86 host takes.
#
# Sized for the slow end rather than the typical one. The probe returns the
# instant :80 accepts, so a budget the fast host never spends costs it nothing,
# while one sized for the fast host fails the slow host over a build that was
# progressing normally. The wait extends itself past this while cloud-init
# reports it is still working, so this is the floor rather than the whole story.
$script:DownloadAgentServiceReadyTimeoutSeconds = 2700

function Get-DownloadAgentServiceMarkerPath {
    <#
    .SYNOPSIS
        Absolute path of the download-agent service runtime marker.
    .PARAMETER RuntimeDir
        Runtime directory holding the marker. Defaults to
        $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [string] absolute path, or '' when no runtime dir is known.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    return (Get-ExtensionServiceMarkerPath -Area $script:Area -RuntimeDir $RuntimeDir)
}

function Write-DownloadAgentServiceMarker {
    <#
    .SYNOPSIS
        Write runtime/download-agent-service.json, the host's claim that it runs
        a download-agent service.
    .DESCRIPTION
        Key order is fixed so the file is byte-stable across re-runs that change
        nothing: a marker rewritten with reshuffled keys looks like a change to
        every consumer that diffs or hashes it.

        -Active is the readiness verdict, not "the bring-up script ran". The
        aggregator paints the Extension-hosts row and its deep-link from this
        value; publishing $true for a daemon that never bound :80 sends
        operators to a dead URL and hides the actual failure.

        Written whole with WriteAllText (UTF-8, no BOM) because the aggregator
        polls the file: a partial write would be parsed as corrupt rather than
        retried.
    .PARAMETER RuntimeDir
        Runtime directory to write into. Defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER Active
        The readiness verdict.
    .PARAMETER VMName
        Name of the VM running the daemon.
    .PARAMETER HostType
        Host type that built the VM (host.windows.hyper-v, host.ubuntu.kvm,
        host.macos.utm).
    .PARAMETER BaseUrl
        Base URL peers should use for the agent's UI/API. '' when this host
        could not resolve one.
    .PARAMETER StartedAtUtc
        Timestamp to record. Defaults to now, in the Zulu form the sibling
        markers use.
    .OUTPUTS
        [string] the path written, or '' when there was no runtime dir.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [bool]$Active = $false,
        [string]$VMName = '',
        [string]$HostType = '',
        [AllowEmptyString()][string]$BaseUrl = '',
        [string]$StartedAtUtc = ''
    )
    return (Write-ExtensionServiceMarker -Area $script:Area -RuntimeDir $RuntimeDir `
        -Active $Active -VMName $VMName -HostType $HostType -BaseUrl $BaseUrl -StartedAtUtc $StartedAtUtc)
}

function Read-DownloadAgentServiceMarker {
    <#
    .SYNOPSIS
        Read runtime/download-agent-service.json.
    .DESCRIPTION
        Never throws: an absent, unreadable, or malformed marker is
        indistinguishable from "this host does not run the service" as far as
        every caller is concerned, and a discovery read must not be able to
        fail a bring-up or a teardown.
    .PARAMETER RuntimeDir
        Runtime directory holding the marker. Defaults to
        $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [pscustomobject] the parsed marker, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    return (Read-ExtensionServiceMarker -Area $script:Area -RuntimeDir $RuntimeDir)
}

function Remove-DownloadAgentServiceMarker {
    <#
    .SYNOPSIS
        Remove runtime/download-agent-service.json so this host stops claiming
        the area.
    .DESCRIPTION
        Runs BEFORE the VM teardown it accompanies. Between the two there is a
        window where the aggregator can poll, and a marker that still says
        active while the VM is being destroyed advertises an agent that is
        already gone -- the deep-link fails and hosts that trust the row waste a
        request budget on it. Removing first makes the worst case a host that
        looks agent-less slightly early.
    .PARAMETER RuntimeDir
        Runtime directory holding the marker. Defaults to
        $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [bool] $true when a marker was present and is now gone.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    $path = Get-DownloadAgentServiceMarkerPath -RuntimeDir $RuntimeDir
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    if (-not $PSCmdlet.ShouldProcess($path, 'Remove the download-agent-service marker')) { return $false }
    return (Remove-ExtensionServiceMarker -Area $script:Area -RuntimeDir $RuntimeDir -Confirm:$false)
}

function Get-DownloadAgentServiceReadyTimeoutSeconds {
    <#
    .SYNOPSIS
        How long a bring-up waits for the daemon to serve on :80.
    .DESCRIPTION
        Reads YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS, falling back
        to a generous default so a slow first build -- apt golang plus a go
        build, sometimes through a cold caching proxy -- is not mis-reported as
        a failure. The probe exits the moment :80 accepts, so a large budget
        costs nothing on a healthy host; the override exists for the opposite
        case, a quick re-check against a VM that is already up.

        A non-numeric or non-positive override is ignored rather than honored:
        an empty or fat-fingered value would otherwise turn the wait into an
        instant failure, which reads as "the daemon is broken" when the truth is
        "the environment is mistyped".
    .PARAMETER DefaultSeconds
        Timeout to use when the environment variable is absent or unusable.
    .OUTPUTS
        [int] seconds.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <name>Seconds so a bare number can never be read in the wrong unit (docs/design/naming.md), and the name mirrors the YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS override it reads.')]
    param([int]$DefaultSeconds = $script:DownloadAgentServiceReadyTimeoutSeconds)
    $value = $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultSeconds }
    $parsed = 0
    if ([int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    Write-Verbose "YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS='$value' is not a positive integer; using $DefaultSeconds."
    return $DefaultSeconds
}

function Test-DownloadAgentServicePort {
    <#
    .SYNOPSIS
        One TCP connect attempt against the daemon's listener.
    .DESCRIPTION
        A raw connect rather than an HTTP request: this is called in a tight
        poll while the guest is still building, when there is nothing to answer
        HTTP yet, and a bounded connect distinguishes "not listening" from
        "listening but slow" without an HttpClient's retry and redirect
        machinery in the way.

        BeginConnect plus a WaitOne bound rather than a plain Connect: the
        synchronous call inherits the OS connect timeout (tens of seconds on a
        dropped SYN), which would stretch each poll iteration far past the
        caller's tick cadence and make a bring-up look hung.
    .PARAMETER Address
        Host name or IP literal to connect to.
    .PARAMETER Port
        TCP port. Defaults to the daemon's :80.
    .PARAMETER TimeoutMilliseconds
        Per-attempt connect bound.
    .OUTPUTS
        [bool] $true when the connection was established.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Address,
        [int]$Port = $script:DownloadAgentServicePort,
        [int]$TimeoutMilliseconds = 1000
    )
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    $tcp = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $tcp.BeginConnect($Address, $Port, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds) -and $tcp.Connected)
    } catch {
        Write-Verbose "download-agent-service ${Address}:${Port} probe: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

function Resolve-DownloadAgentServiceBaseUrl {
    <#
    .SYNOPSIS
        The base URL this host publishes for its download-agent service.
    .DESCRIPTION
        On a bridged network the VM holds a LAN lease and every peer reaches it
        directly, so the VM's own address is the published one.

        UTM Shared NAT is the exception, and it is why this decision exists at
        all. vmnet cannot bridge a Wi-Fi uplink, so on a Wi-Fi Mac the VM is
        built on Shared NAT, where its address is inside a segment no peer can
        route to. The daemon's beacon cannot fix that: the aggregator derives
        the announcing address from the request's source IP, which NAT rewrites
        to the Mac's address without the port that reaches the guest. So the
        published endpoint has to come from HERE, where the forward that was
        just installed is known -- the Mac's LAN address plus the forwarded
        port.

        A Shared-NAT host whose own LAN address is unknown falls back to the VM
        address: locally correct, useless to peers, and still better than
        publishing nothing at all for an agent that is serving.

        An IPv6 literal is bracketed so the result is a legal URL authority.
    .PARAMETER VMIp
        The VM's address as the host contract reports it. '' when unresolved.
    .PARAMETER NetworkMode
        The bundle's network mode ('Shared' for UTM Shared NAT). Anything else
        -- including '' on Hyper-V and KVM -- is treated as directly routable.
    .PARAMETER HostAddress
        This host's own LAN address, used only in Shared-NAT mode.
    .PARAMETER ForwardedPort
        Host port forwarded to the guest's :80 in Shared-NAT mode.
    .OUTPUTS
        [string] base URL with a trailing slash, or '' when nothing is
        publishable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][string]$VMIp = '',
        [AllowEmptyString()][string]$NetworkMode = '',
        [AllowEmptyString()][string]$HostAddress = '',
        [int]$ForwardedPort = $script:DownloadAgentServiceForwardedPort
    )
    if ($NetworkMode -eq 'Shared' -and -not [string]::IsNullOrWhiteSpace($HostAddress)) {
        return ('http://{0}:{1}/' -f (Format-DownloadAgentServiceUrlHost -Address $HostAddress), $ForwardedPort)
    }
    if ([string]::IsNullOrWhiteSpace($VMIp)) { return '' }
    return ('http://{0}/' -f (Format-DownloadAgentServiceUrlHost -Address $VMIp))
}

function Format-DownloadAgentServiceUrlHost {
    <#
    .SYNOPSIS
        Render an address as a legal URL authority host.
    .DESCRIPTION
        An IPv6 literal must be bracketed or the surrounding URL does not parse,
        and its own colons are otherwise read as a port separator. A name or
        IPv4 literal contains no colon, so the bracketing only fires when it is
        required.
    .PARAMETER Address
        Host name or IP literal.
    .OUTPUTS
        [string] the authority host component.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Address)
    $value = "$Address".Trim()
    if ($value.Contains(':') -and -not $value.StartsWith('[')) { return "[$value]" }
    return $value
}

function Get-DownloadAgentServiceForwardedPort {
    <#
    .SYNOPSIS
        The UTM Shared-NAT host port forwarded to the agent's :80.
    .OUTPUTS
        [int] the host port.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:DownloadAgentServiceForwardedPort
}

Export-ModuleMember -Function Get-DownloadAgentServiceMarkerPath, Write-DownloadAgentServiceMarker,
    Read-DownloadAgentServiceMarker, Remove-DownloadAgentServiceMarker,
    Get-DownloadAgentServiceReadyTimeoutSeconds, Test-DownloadAgentServicePort,
    Resolve-DownloadAgentServiceBaseUrl, Format-DownloadAgentServiceUrlHost,
    Get-DownloadAgentServiceForwardedPort
