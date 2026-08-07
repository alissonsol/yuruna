<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42311df0-0dfd-4fd8-ad78-0a91997848c5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service pester
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
    Pester coverage for Test.DownloadAgentService.psm1 (the runtime marker
    round-trip, the readiness verdict the marker carries, and the address the
    host publishes on UTM Shared NAT versus a bridged network) and for the
    host-side client host/modules/Yuruna.DownloadAgent.psm1.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Uses an isolated $env:YURUNA_RUNTIME_DIR so the tests write into a
    throwaway directory instead of a live runtime dir.

    The client half runs against a real in-process HTTP server on a loopback
    port -- a fake agent speaking the daemon's routes -- rather than against
    mocked cmdlets. What is being tested is a wire protocol (an ensure that
    answers localCurrent, a 202 that becomes ready, a Range resume, a hash that
    does not match), and a mock of Invoke-WebRequest would only prove that the
    module calls the cmdlet the test told it to expect.
    Run: pwsh -File test/modules/Test.DownloadAgentService.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath

# The throwaway runtime dir is named from $PID, and the name is held in an
# unqualified (not $script:-qualified) file-scope variable. Both details are
# load-bearing:
#
#   * This file's body is executed during Pester's DISCOVERY pass -- and, when the
#     file is run as the entry script, once more before that. $env:YURUNA_RUNTIME_DIR
#     is process-global, so the last body execution wins, while the It blocks read
#     their $AgentTestRuntime from the first. A per-execution GUID would therefore
#     point the module at one directory and the assertions at another. A
#     $PID-derived name is identical in every pass, so they cannot diverge.
#   * An It block runs in a fresh script scope: a `$script:`-qualified read from a
#     test resolves to THAT scope and comes back $null even though the file assigned
#     the name. Only an unqualified name walks the scope chain out to the file's own
#     variables.
$AgentTestRuntime = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-dlagent-$PID"
$env:YURUNA_RUNTIME_DIR = $AgentTestRuntime
Remove-Item -LiteralPath $AgentTestRuntime -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $AgentTestRuntime | Out-Null
Import-Module (Join-Path $here 'Test.DownloadAgentService.psm1') -Force -DisableNameChecking

# Same unqualified-file-scope rule as $AgentTestRuntime above: It blocks read
# these by walking the scope chain, so they must not be $script:-qualified.
$AgentRepoRoot     = Split-Path -Parent (Split-Path -Parent $here)
$AgentClientModule = Join-Path $AgentRepoRoot 'host' -AdditionalChildPath 'modules', 'Yuruna.DownloadAgent.psm1'

Import-Module $AgentClientModule -Force -DisableNameChecking
# The real 4-line sentinel writer and reader. The metadata quadruple the client
# hands back is only useful if it round-trips through THESE, so the interop is
# tested against the shipping implementation rather than a restatement of it.
Import-Module (Join-Path $AgentRepoRoot 'host' -AdditionalChildPath 'modules', 'Yuruna.HostDownload.psm1') -Force -DisableNameChecking

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected', got '$Actual'. $Because" }
}

function Get-DownloadAgentScratchDir {
    <#
    .SYNOPSIS
        Throwaway directory for staging paths and sentinels, created on demand.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-dlagent-client-$PID"
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Get-FakeAgentPlan {
    <#
    .SYNOPSIS
        Mutable script for one fake agent: what /healthz answers, the ensure
        responses in order, the artifact bytes, and the request log.
    .DESCRIPTION
        Synchronized because the listener loop runs on a thread job in this same
        process: the test writes the plan, the responder reads it, and the test
        reads the request log back afterwards.
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $plan = [hashtable]::Synchronized(@{})
    $plan.HealthStatus = 200
    # Consumed front to back; the last entry repeats, so a poll loop keeps
    # getting the terminal answer instead of falling off the end.
    $plan.EnsureQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $plan.MetadataStatus = 404
    $plan.MetadataJson = '{"ok":false,"error":"no pool entry"}'
    $plan.FileBytes = [byte[]]@()
    # Serve only the first half of the artifact on the first non-ranged fetch,
    # which is the deterministic stand-in for a stream that dies mid-body: both
    # leave a short file, and both are answered by asking for the rest.
    $plan.TruncateFirstFileResponse = $false
    $plan.OriginLastModified = ''
    $plan.Requests = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    $plan.LastEnsureBody = ''
    return $plan
}

function Get-FakeAgent {
    <#
    .SYNOPSIS
        Start a fake download-agent service on a loopback port and return
        @{ BaseUrl; Listener; Job }.
    .PARAMETER Plan
        The plan from Get-FakeAgentPlan.
    .PARAMETER Port
        Bind this exact port instead of a free one (the aggregator's 9400).
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'Both values reach the responder through -ArgumentList into its param() block; the analyzer does not follow that path.')]
    param(
        [Parameter(Mandatory)][hashtable]$Plan,
        [int]$Port = 0
    )

    $listener = $null
    $attempts = if ($Port -gt 0) { @($Port) } else { 1..40 | ForEach-Object { Get-Random -Minimum 20000 -Maximum 60000 } }
    foreach ($candidatePort in $attempts) {
        $candidate = [System.Net.HttpListener]::new()
        $candidate.Prefixes.Add("http://127.0.0.1:$candidatePort/")
        try {
            $candidate.Start()
            $listener = $candidate
            break
        } catch {
            Write-Verbose "Get-FakeAgent: port $candidatePort unusable ($($_.Exception.Message))."
            $candidate.Close()
        }
    }
    if ($null -eq $listener) {
        if ($Port -gt 0) { return $null }
        throw 'Could not bind a loopback HttpListener for the fake download agent.'
    }

    $job = Start-ThreadJob -ScriptBlock {
        param($Listener, $Plan)
        while ($Listener.IsListening) {
            $context = $null
            try { $context = $Listener.GetContext() } catch { break }
            try {
                $request = $context.Request
                $response = $context.Response
                $path = $request.Url.AbsolutePath
                [void]$Plan.Requests.Add("$($request.HttpMethod) $($request.Url.PathAndQuery)")

                $status = 404
                $contentType = 'application/json'
                $payload = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"no route"}')

                if ($path -eq '/healthz') {
                    $status = [int]$Plan.HealthStatus
                    $contentType = 'text/plain'
                    $payload = [System.Text.Encoding]::UTF8.GetBytes("ok`n")
                } elseif ($request.HttpMethod -eq 'POST' -and $path.EndsWith('/ensure')) {
                    $reader = [System.IO.StreamReader]::new($request.InputStream)
                    $Plan.LastEnsureBody = $reader.ReadToEnd()
                    $reader.Dispose()
                    if ($Plan.EnsureQueue.Count -gt 0) {
                        $step = $Plan.EnsureQueue[0]
                        if ($Plan.EnsureQueue.Count -gt 1) { $Plan.EnsureQueue.RemoveAt(0) }
                        $status = [int]$step.Status
                        $payload = [System.Text.Encoding]::UTF8.GetBytes([string]$step.Json)
                    } else {
                        $status = 503
                        $payload = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"state":"unavailable","reason":"pool-unavailable"}')
                    }
                } elseif ($path -match '/file/') {
                    $bytes = [byte[]]$Plan.FileBytes
                    $offset = 0
                    $rangeHeader = [string]$request.Headers['Range']
                    if ($rangeHeader -match 'bytes=(\d+)-') { $offset = [int]$Matches[1] }
                    $contentType = 'application/octet-stream'
                    if ($offset -ge $bytes.Length) {
                        $status = 416
                        $payload = [byte[]]@()
                    } elseif ($offset -gt 0) {
                        $status = 206
                        $payload = [byte[]]($bytes[$offset..($bytes.Length - 1)])
                        $response.AddHeader('Content-Range', "bytes $offset-$($bytes.Length - 1)/$($bytes.Length)")
                    } elseif ($Plan.TruncateFirstFileResponse) {
                        $Plan.TruncateFirstFileResponse = $false
                        $status = 200
                        $payload = [byte[]]($bytes[0..([int]($bytes.Length / 2) - 1)])
                    } else {
                        $status = 200
                        $payload = $bytes
                    }
                } elseif ($path.StartsWith('/origin/')) {
                    # Stands in for the publisher: what the host-side skip guard
                    # HEADs when it reads the sentinel back.
                    $status = 200
                    $contentType = 'application/octet-stream'
                    if ($Plan.OriginLastModified) { $response.AddHeader('Last-Modified', [string]$Plan.OriginLastModified) }
                    $payload = [byte[]]$Plan.FileBytes
                } elseif ($request.HttpMethod -eq 'GET' -and $path -match '^/api/v1/extension-hosts$') {
                    $status = [int]$Plan.MetadataStatus
                    $payload = [System.Text.Encoding]::UTF8.GetBytes([string]$Plan.MetadataJson)
                } elseif ($request.HttpMethod -eq 'GET' -and $path -match '^/api/v1/images/[^/]+/[^/]+$') {
                    $status = [int]$Plan.MetadataStatus
                    $payload = [System.Text.Encoding]::UTF8.GetBytes([string]$Plan.MetadataJson)
                }

                $response.StatusCode = $status
                $response.ContentType = $contentType
                $response.ContentLength64 = $payload.Length
                if ($request.HttpMethod -ne 'HEAD' -and $payload.Length -gt 0) {
                    $response.OutputStream.Write($payload, 0, $payload.Length)
                }
                $response.OutputStream.Close()
            } catch {
                Write-Verbose "fake agent: $($_.Exception.Message)"
                try { $context.Response.Abort() } catch { Write-Verbose 'fake agent: abort failed' }
            }
        }
    } -ArgumentList $listener, $Plan

    return @{
        BaseUrl  = ($listener.Prefixes | Select-Object -First 1).TrimEnd('/')
        Listener = $listener
        Job      = $job
    }
}

function Close-FakeAgent {
    <#
    .SYNOPSIS
        Stop a fake agent's listener and reap its responder job.
    .PARAMETER Agent
        The record Get-FakeAgent returned, or $null.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([AllowNull()][hashtable]$Agent)
    if ($null -eq $Agent) { return }
    try { $Agent.Listener.Stop() } catch { Write-Verbose "Close-FakeAgent: stop failed ($($_.Exception.Message))." }
    try { $Agent.Listener.Close() } catch { Write-Verbose "Close-FakeAgent: close failed ($($_.Exception.Message))." }
    if ($Agent.Job) { $Agent.Job | Remove-Job -Force -ErrorAction SilentlyContinue }
}

function Get-FakeArtifactByte {
    <#
    .SYNOPSIS
        Deterministic artifact bytes for the fake pool.
    .PARAMETER Length
        Byte count.
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([int]$Length = 8192)
    $bytes = [byte[]]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) { $bytes[$i] = [byte](($i * 7 + 13) % 251) }
    return $bytes
}

function Get-FakeArtifactHash {
    <#
    .SYNOPSIS
        Lowercase hex SHA-256 of a byte array, matching what the agent records.
    .PARAMETER Bytes
        The artifact.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]]$Bytes)
    return ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::HashData($Bytes)) -replace '-', '').ToLowerInvariant()
}

function Get-FakeEnsureJson {
    <#
    .SYNOPSIS
        One ensure response body, in the daemon's shape.
    .PARAMETER State
        'ready', 'downloading' or 'failed'.
    .PARAMETER Image
        Catalog entry to embed, or $null.
    .PARAMETER LocalCurrent
        Answer the host's fingerprint as matching the current pointer.
    .PARAMETER Stale
        Mark the entry past its freshness window.
    .PARAMETER RefreshInFlight
        Report a refresh already running.
    .PARAMETER BytesDone
        Progress numerator.
    .PARAMETER BytesTotal
        Progress denominator.
    .PARAMETER ErrorText
        Failure string for state 'failed'.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$State,
        [AllowNull()]$Image = $null,
        [switch]$LocalCurrent,
        [switch]$Stale,
        [switch]$RefreshInFlight,
        [int64]$BytesDone = 0,
        [int64]$BytesTotal = 0,
        [string]$ErrorText = ''
    )
    $body = [ordered]@{
        ok              = ($State -ne 'failed')
        state           = $State
        localCurrent    = [bool]$LocalCurrent
        stale           = [bool]$Stale
        refreshInFlight = [bool]$RefreshInFlight
        bytesDone       = $BytesDone
        bytesTotal      = $BytesTotal
        image           = $Image
    }
    if ($ErrorText) { $body['error'] = $ErrorText }
    return ($body | ConvertTo-Json -Depth 6 -Compress)
}

function Get-FakeCatalogEntry {
    <#
    .SYNOPSIS
        A catalog entry for the fake pool, keyed the way the pool tree is.
    .PARAMETER BaseUrl
        The fake agent's base URL; the origin route hangs off it.
    .PARAMETER Filename
        Upstream filename.
    .PARAMETER ByteCount
        Origin Content-Length.
    .PARAMETER Sha256
        Artifact hash.
    .PARAMETER LastModified
        Origin Last-Modified.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Filename,
        [Parameter(Mandatory)][int64]$ByteCount,
        [Parameter(Mandatory)][string]$Sha256,
        [string]$LastModified = 'Thu, 23 Jul 2026 09:14:02 GMT'
    )
    $generation = "$Filename.$($Sha256.Substring(0, 12))"
    return [ordered]@{
        hostType         = 'ubuntu.kvm'
        imageKey         = 'guest.ubuntu.server.26'
        arch             = 'amd64'
        variant          = 'stable'
        state            = 'fresh'
        supported        = $true
        upstreamFilename = $Filename
        generation       = $generation
        # Query-less by design: the byte route is keyed by (hostType, imageKey,
        # generation) and 400s on an arch parameter, so the client must use this
        # verbatim rather than recomposing it.
        fileUrl          = "/api/v1/images/ubuntu.kvm/guest.ubuntu.server.26/file/$generation"
        sourceUrl        = "$BaseUrl/origin/$Filename"
        sha256           = $Sha256
        checksumVerdict  = 'verified'
        byteCount        = $ByteCount
        lastModified     = $LastModified
        currentBytes     = $ByteCount
        previousBytes    = 0
        generationCount  = 1
        downloadedAt     = '2026-08-03T14:11:07Z'
        lastVerifiedAt   = '2026-08-03T14:11:07Z'
    }
}

Describe 'Test.DownloadAgentService marker' {
    # Cleanup belongs in AfterAll, not at the end of the file: file-level code runs
    # during discovery, BEFORE any It, so a trailing Remove-Item would delete the
    # directory the tests are about to write into rather than clean up after them.
    # The path is re-read from the process-global env var (which the file body
    # pointed at the throwaway dir) because a run-phase block cannot rely on seeing
    # the file's own variables; the name check keeps this off a real runtime dir.
    AfterAll {
        $dir = $env:YURUNA_RUNTIME_DIR
        if ($dir -and (Split-Path -Leaf $dir) -like 'yrn-dlagent-*') {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'round-trips every field the aggregator reads, under the fixed file name' {
        $dir  = $env:YURUNA_RUNTIME_DIR
        $path = Write-DownloadAgentServiceMarker -RuntimeDir $dir -Active $true `
            -VMName 'yuruna-download-agent-service' -HostType 'host.ubuntu.kvm' `
            -BaseUrl 'http://192.168.1.42/' -StartedAtUtc '2026-08-03T14:11:07Z'
        Assert-Equal 'download-agent-service.json' (Split-Path -Leaf $path) -Because 'the marker file name is the area slug'
        Assert-Equal $path (Get-DownloadAgentServiceMarkerPath -RuntimeDir $dir) -Because 'the path helper agrees with the writer'

        $marker = Read-DownloadAgentServiceMarker -RuntimeDir $dir
        Assert-True ($null -ne $marker) 'the marker reads back'
        Assert-True ([bool]$marker.active) 'active round-trips'
        Assert-Equal 'yuruna-download-agent-service' $marker.vmName -Because 'vmName round-trips'
        Assert-Equal 'host.ubuntu.kvm' $marker.hostType -Because 'hostType round-trips'
        Assert-Equal 'http://192.168.1.42/' $marker.downloadAgentServiceBaseUrl -Because 'the deep-link round-trips'

        # The timestamp is asserted against the FILE, not the parsed object:
        # ConvertFrom-Json coerces an ISO-8601 string into a [datetime] and the
        # Zulu form is lost on the way out. The aggregator reads the bytes, so
        # the bytes are what has to carry the timezone-unambiguous form.
        $raw = Get-Content -Raw -LiteralPath $path
        Assert-True ($raw -match '"startedAtUtc":\s*"2026-08-03T14:11:07Z"') "startedAtUtc is stored in Zulu form; file said: $raw"
    }

    It 'writes the marker without a BOM (the aggregator parses the bytes as-is)' {
        $dir  = $env:YURUNA_RUNTIME_DIR
        $path = Write-DownloadAgentServiceMarker -RuntimeDir $dir -Active $true -VMName 'v' -HostType 'h' -BaseUrl ''
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        Assert-True (-not $hasBom) 'no UTF-8 BOM ahead of the JSON'
    }

    It 'carries the readiness verdict into active, not the fact that a bring-up ran' {
        $dir = $env:YURUNA_RUNTIME_DIR
        foreach ($verdict in @($true, $false)) {
            [void](Write-DownloadAgentServiceMarker -RuntimeDir $dir -Active $verdict `
                -VMName 'yuruna-download-agent-service' -HostType 'host.windows.hyper-v' -BaseUrl 'http://10.0.0.9/')
            $marker = Read-DownloadAgentServiceMarker -RuntimeDir $dir
            Assert-Equal $verdict ([bool]$marker.active) -Because "a readiness verdict of $verdict is what the marker publishes"
        }
    }

    It 'removes the marker and reports nothing to remove the second time' {
        $dir = $env:YURUNA_RUNTIME_DIR
        [void](Write-DownloadAgentServiceMarker -RuntimeDir $dir -Active $true -VMName 'v' -HostType 'h' -BaseUrl '')
        Assert-True (Remove-DownloadAgentServiceMarker -RuntimeDir $dir -Confirm:$false) 'the present marker is removed'
        Assert-True ($null -eq (Read-DownloadAgentServiceMarker -RuntimeDir $dir)) 'an absent marker reads back as $null'
        Assert-True (-not (Remove-DownloadAgentServiceMarker -RuntimeDir $dir -Confirm:$false)) 'a second removal reports $false, not an error'
    }

    It 'treats an unreadable marker as no claim at all' {
        $dir = $env:YURUNA_RUNTIME_DIR
        [System.IO.File]::WriteAllText((Get-DownloadAgentServiceMarkerPath -RuntimeDir $dir), 'not json {')
        Assert-True ($null -eq (Read-DownloadAgentServiceMarker -RuntimeDir $dir)) 'a malformed marker is $null, never a throw'
        [void](Remove-DownloadAgentServiceMarker -RuntimeDir $dir -Confirm:$false)
    }

    It 'is a no-op when there is no runtime dir to write into' {
        Assert-Equal '' (Get-DownloadAgentServiceMarkerPath -RuntimeDir '') -Because 'no runtime dir means no path'
        Assert-Equal '' (Write-DownloadAgentServiceMarker -RuntimeDir '' -Active $true -VMName 'v' -HostType 'h' -BaseUrl '') -Because 'the writer declines rather than guessing a location'
        Assert-True ($null -eq (Read-DownloadAgentServiceMarker -RuntimeDir '')) 'the reader declines too'
    }
}

Describe 'Test.DownloadAgentService published address' {
    It 'publishes the VM address on a directly routable network' {
        Assert-Equal 'http://192.168.1.42/' (Resolve-DownloadAgentServiceBaseUrl -VMIp '192.168.1.42' -NetworkMode 'Bridged' -HostAddress '10.0.0.9') -Because 'bridged peers reach the VM itself'
        Assert-Equal 'http://192.168.1.42/' (Resolve-DownloadAgentServiceBaseUrl -VMIp '192.168.1.42') -Because 'Hyper-V / KVM report no network mode at all'
    }

    It 'publishes the host forward on UTM Shared NAT, where the VM address is unroutable' {
        Assert-Equal 'http://10.0.0.9:8082/' (Resolve-DownloadAgentServiceBaseUrl -VMIp '192.168.64.7' -NetworkMode 'Shared' -HostAddress '10.0.0.9') -Because 'peers reach the Mac, not the NAT segment'
        Assert-Equal 8082 (Get-DownloadAgentServiceForwardedPort) -Because 'the forwarded port is the one the start script maps'
    }

    It 'falls back to the VM address when a Shared-NAT host cannot name itself' {
        Assert-Equal 'http://192.168.64.7/' (Resolve-DownloadAgentServiceBaseUrl -VMIp '192.168.64.7' -NetworkMode 'Shared' -HostAddress '') -Because 'locally usable beats publishing nothing'
    }

    It 'publishes nothing when no address resolved at all' {
        Assert-Equal '' (Resolve-DownloadAgentServiceBaseUrl -VMIp '' -NetworkMode '' -HostAddress '') -Because 'an unresolved VM yields no deep-link'
        Assert-Equal '' (Resolve-DownloadAgentServiceBaseUrl -VMIp '' -NetworkMode 'Bridged' -HostAddress '10.0.0.9') -Because 'a bridged host address is not the agent address'
    }

    It 'brackets an IPv6 literal so the URL authority parses' {
        Assert-Equal 'http://[fd00::1]/' (Resolve-DownloadAgentServiceBaseUrl -VMIp 'fd00::1')
        Assert-Equal 'http://[fd00::5]:8082/' (Resolve-DownloadAgentServiceBaseUrl -VMIp '192.168.64.7' -NetworkMode 'Shared' -HostAddress 'fd00::5')
        Assert-Equal '[fd00::1]' (Format-DownloadAgentServiceUrlHost -Address 'fd00::1')
        Assert-Equal '[fd00::1]' (Format-DownloadAgentServiceUrlHost -Address '[fd00::1]') -Because 'an already-bracketed literal is left alone'
        Assert-Equal '192.168.1.42' (Format-DownloadAgentServiceUrlHost -Address '192.168.1.42') -Because 'an IPv4 literal is never bracketed'
    }
}

Describe 'Test.DownloadAgentService readiness' {
    It 'defaults the readiness budget to the slow-first-build value and honors a sane override' {
        $saved = $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS
        try {
            $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = ''
            Assert-Equal 2700 (Get-DownloadAgentServiceReadyTimeoutSeconds) -Because 'a first boot installs a Go toolchain and compiles the daemon in-guest, which runs to roughly half an hour on a slow arch against a cold mirror'
            $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = '120'
            Assert-Equal 120 (Get-DownloadAgentServiceReadyTimeoutSeconds) -Because 'a quick re-check can shorten the wait'
        } finally {
            $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = $saved
        }
    }

    It 'ignores an override that is not a positive integer instead of failing instantly' {
        $saved = $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS
        try {
            foreach ($bad in @('abc', '0', '-30', '90s')) {
                $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = $bad
                Assert-Equal 2700 (Get-DownloadAgentServiceReadyTimeoutSeconds) -Because "'$bad' is not a usable budget, so the default stands"
            }
        } finally {
            $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = $saved
        }
    }

    It 'reports a listener as reachable and a closed port as not, without blocking' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        # Read the bound port while the listener is still up: LocalEndpoint is
        # only meaningful on a started listener.
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        try {
            Assert-True (Test-DownloadAgentServicePort -Address '127.0.0.1' -Port $port -TimeoutMilliseconds 2000) 'an accepting listener probes true'
        } finally {
            $listener.Stop()
        }
        # The listener is stopped, so the same port now refuses -- a refusal, not
        # a timeout, which is what the poll loop sees while the guest builds.
        Assert-True (-not (Test-DownloadAgentServicePort -Address '127.0.0.1' -Port $port -TimeoutMilliseconds 2000)) 'a closed port probes false'
        Assert-True (-not (Test-DownloadAgentServicePort -Address '' -Port 80)) 'an unresolved VM address probes false without a connect attempt'
    }
}

Describe 'Yuruna.DownloadAgent endpoint ladder' {

    It 'exports exactly the three client functions, and nothing that could evict a driver wrapper' {
        $exported = @((Get-Module Yuruna.DownloadAgent).ExportedFunctions.Keys | Sort-Object)
        Assert-Equal 'Get-DownloadAgentImageMetadata,Request-DownloadAgentImage,Resolve-DownloadAgentEndpoint' ($exported -join ',') `
            -Because 'exporting a fourth name is how a shared helper starts shadowing a driver wrapper'
        foreach ($forbidden in @('Save-CachedHttpUri', 'Test-DownloadAlreadyCurrent', 'Write-ImageSentinel')) {
            Assert-True ($exported -notcontains $forbidden) "$forbidden must never be re-exported by the agent client"
        }
    }

    It 'takes the operator pin ahead of anything it could discover' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $agent.BaseUrl
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
            Assert-Equal $agent.BaseUrl (Resolve-DownloadAgentEndpoint -Refresh) -Because 'the pin is the operator escape hatch and must win'
            Assert-True (@($plan.Requests) -contains 'GET /healthz') 'the pinned candidate is proved with a /healthz probe, not believed'
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
            Close-FakeAgent -Agent $agent
        }
    }

    It 'accepts a bare address and a published non-default port alike' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        try {
            # A Shared-NAT Mac publishes http://<mac-lan-ip>:8082/, so the port
            # has to survive normalisation; a driver's Get-VMIp hands over a bare
            # address, which has to acquire a scheme.
            $port = ([System.Uri]$agent.BaseUrl).Port
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = "http://127.0.0.1:$port/"
            Assert-Equal "http://127.0.0.1:$port" (Resolve-DownloadAgentEndpoint -Refresh) -Because 'a trailing slash is trimmed, the port is kept'
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            Close-FakeAgent -Agent $agent
        }
    }

    It 'discards a candidate that does not pass /healthz' {
        $plan = Get-FakeAgentPlan
        $plan.HealthStatus = 503
        $agent = Get-FakeAgent -Plan $plan
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $agent.BaseUrl
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
            # Something IS listening there -- it just is not a working agent.
            # Believing the address anyway is how a cycle spends its timeouts on
            # a service that cannot answer.
            Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because 'a listening socket is not an agent'
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
            Close-FakeAgent -Agent $agent
        }
    }

    It 'collapses every failure shape to an empty string instead of throwing' {
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''

            # Nothing pinned, no driver loaded, no proxy known: every rung is
            # absent, which is a supported state and not an error.
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = ''
            Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because 'no rung resolves anything'

            # A pin that outlived its service: bind a port only to learn the
            # address, then release it.
            $dead = Get-FakeAgent -Plan (Get-FakeAgentPlan)
            $deadUrl = $dead.BaseUrl
            Close-FakeAgent -Agent $dead
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $deadUrl
            Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because 'a refused connection is no agent'

            foreach ($garbage in @('not a url at all', 'ftp://10.0.0.9', 'nonsense://x', '://')) {
                $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $garbage
                Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because "'$garbage' cannot become an endpoint, and must not become an exception either"
            }

            # A proxy claim pointing at nothing: the aggregator lookup fails and
            # the ladder simply runs out of rungs.
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = ''
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = '127.0.0.1'
            Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because 'an aggregator that is not there contributes nothing'
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
        }
    }

    It 'memoizes the answer for the process and re-walks the ladder only on -Refresh' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $agent.BaseUrl
            Assert-Equal $agent.BaseUrl (Resolve-DownloadAgentEndpoint -Refresh)
            $probes = @($plan.Requests | Where-Object { $_ -eq 'GET /healthz' }).Count

            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = ''
            Assert-Equal $agent.BaseUrl (Resolve-DownloadAgentEndpoint) -Because 'a Get-Image run asks once per family and must not re-walk the ladder each time'
            Assert-Equal $probes (@($plan.Requests | Where-Object { $_ -eq 'GET /healthz' }).Count) -Because 'the memoized answer costs no probe'

            Assert-Equal '' (Resolve-DownloadAgentEndpoint -Refresh) -Because '-Refresh is what re-resolves'
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
            Close-FakeAgent -Agent $agent
        }
    }

    It 'honours the address the pool advertises, port and all' {
        # The pool rung needs the aggregator on its fixed port, so this binds
        # 9400 on loopback. A machine already using that port cannot host the
        # test; say so rather than asserting nothing.
        $agentPlan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $agentPlan
        $aggregatorPlan = Get-FakeAgentPlan
        $aggregatorPlan.MetadataStatus = 200
        $aggregatorPlan.MetadataJson = (@{
            area   = 'download-agent-service'
            host   = '127.0.0.1'
            target = "$($agent.BaseUrl)/"
            source = 'announce'
        } | ConvertTo-Json -Compress)
        $aggregator = Get-FakeAgent -Plan $aggregatorPlan -Port 9400
        $savedPin = $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE
        $savedCache = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            if ($null -eq $aggregator) {
                Write-Warning 'Port 9400 is already in use on this machine; the pool rung of the ladder was not exercised.'
                return
            }
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = ''
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = '127.0.0.1'
            # The advertised target carries the port; assuming :80 would reach
            # nothing on a Shared-NAT Mac, which publishes :8082.
            Assert-Equal $agent.BaseUrl (Resolve-DownloadAgentEndpoint -Refresh) -Because 'the advertised target is used verbatim'
            Assert-True (@($aggregatorPlan.Requests) -contains 'GET /api/v1/extension-hosts?area=download-agent-service') `
                "the pool is asked by area; saw: $(@($aggregatorPlan.Requests) -join ' | ')"
        } finally {
            $env:YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE = $savedPin
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = $savedCache
            Close-FakeAgent -Agent $aggregator
            Close-FakeAgent -Agent $agent
        }
    }
}

Describe 'Yuruna.DownloadAgent metadata read' {

    It 'returns the catalog entry the agent published' {
        $bytes = Get-FakeArtifactByte -Length 4096
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $sha
            $plan.MetadataStatus = 200
            $plan.MetadataJson = (@{ ok = $true; image = $entry } | ConvertTo-Json -Depth 6 -Compress)

            # 'host.ubuntu.kvm' on purpose: Get-HostType answers the prefixed
            # form and a caller may hand over either vocabulary.
            $meta = Get-DownloadAgentImageMetadata -BaseUrl $agent.BaseUrl -HostType 'host.ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64'
            Assert-True ($null -ne $meta) 'a 200 with an image yields the entry'
            Assert-Equal 'ubuntu-26.04.1-live-server-amd64.iso' $meta.upstreamFilename
            Assert-Equal $sha $meta.sha256
            Assert-True (@($plan.Requests) -contains 'GET /api/v1/images/ubuntu.kvm/guest.ubuntu.server.26?arch=amd64&variant=stable') `
                "the request carries the stripped host type plus arch and variant; saw: $(@($plan.Requests) -join ' | ')"
        } finally { Close-FakeAgent -Agent $agent }
    }

    It 'answers nothing at all for every shape that is not an entry, without throwing' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        try {
            $plan.MetadataStatus = 404
            Assert-True ($null -eq (Get-DownloadAgentImageMetadata -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64')) 'a 404 is no entry'
            $plan.MetadataStatus = 503
            Assert-True ($null -eq (Get-DownloadAgentImageMetadata -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64')) 'an unmounted pool is no entry'
            Assert-True ($null -eq (Get-DownloadAgentImageMetadata -BaseUrl '' -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64')) 'no endpoint is no entry'
            Assert-True ($null -eq (Get-DownloadAgentImageMetadata -BaseUrl $agent.BaseUrl -HostType 'freebsd.bhyve' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64')) 'a host type the pool cannot be keyed by is refused before the wire'
        } finally { Close-FakeAgent -Agent $agent }
    }
}

Describe 'Yuruna.DownloadAgent image request' {

    AfterAll {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-dlagent-client-$PID"
        if ((Split-Path -Leaf $dir) -like 'yrn-dlagent-client-*') {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'skips when the agent says the local copy IS the current artifact' {
        $bytes = Get-FakeArtifactByte -Length 4096
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'skip.iso'
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $sha
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry -LocalCurrent) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' `
                -LocalFilename 'ubuntu-26.04.1-live-server-amd64.iso' -LocalByteCount $bytes.Length `
                -StagingPath $staging

            Assert-Equal 'skipped' $result.outcome -Because 'matching bytes are never re-fetched'
            Assert-True (-not (Test-Path -LiteralPath $staging)) 'a skip moves no bytes at all'
            Assert-True (@($plan.Requests | Where-Object { $_ -match '/file/' }).Count -eq 0) 'the byte route is never touched on a skip'
            # The fingerprint deliberately carries no hash: the 4-line sentinel
            # has none, and hashing a multi-GB local artifact to ask a question
            # costs more than the download the question avoids.
            $sent = $plan.LastEnsureBody | ConvertFrom-Json
            Assert-Equal 'ubuntu-26.04.1-live-server-amd64.iso' $sent.filename
            Assert-Equal $bytes.Length $sent.byteCount
            Assert-Equal '' ([string]$sent.sha256) -Because 'filename + byte count is exactly the agent fallback comparison'
        } finally { Close-FakeAgent -Agent $agent }
    }

    It 'still skips when the entry is stale and a refresh is already running' {
        $bytes = Get-FakeArtifactByte -Length 4096
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'stale-skip.iso'
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $sha
            $entry['state'] = 'stale'
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry -LocalCurrent -Stale -RefreshInFlight) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' `
                -LocalFilename 'ubuntu-26.04.1-live-server-amd64.iso' -LocalByteCount $bytes.Length `
                -StagingPath $staging

            # The skip condition is "these ARE the current bytes", deliberately
            # independent of freshness age: a host must never wait on -- or
            # re-download after -- a refresh of bytes it already holds. It picks
            # the new generation up on its next start.
            Assert-Equal 'skipped' $result.outcome -Because 'staleness must not force a host to wait on a refresh'
            Assert-True (-not (Test-Path -LiteralPath $staging)) 'a stale skip moves no bytes either'
            Assert-True (@($plan.Requests | Where-Object { $_ -match '/file/' }).Count -eq 0) 'no byte fetch on a stale skip'
        } finally { Close-FakeAgent -Agent $agent }
    }

    It 'polls a 202 until it turns ready, then fetches and verifies the bytes' {
        $bytes = Get-FakeArtifactByte -Length 65536
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'polled.iso'
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $sha
            [void]$plan.EnsureQueue.Add(@{ Status = 202; Json = (Get-FakeEnsureJson -State 'downloading' -RefreshInFlight -BytesDone 0 -BytesTotal $bytes.Length) })
            [void]$plan.EnsureQueue.Add(@{ Status = 202; Json = (Get-FakeEnsureJson -State 'downloading' -RefreshInFlight -BytesDone ([int64]($bytes.Length / 2)) -BytesTotal $bytes.Length) })
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 120

            Assert-Equal 'downloaded' $result.outcome -Because "expected a completed fetch, error was: $($result.error)"
            Assert-True (Test-Path -LiteralPath $staging) 'the bytes land at the staging path the caller named'
            Assert-Equal $bytes.Length ((Get-Item -LiteralPath $staging).Length)
            Assert-Equal $sha ((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash.ToLowerInvariant())
            Assert-True (@($plan.Requests | Where-Object { $_ -match '/ensure' }).Count -ge 3) 'the client polls rather than giving up on the first 202'
            # The byte route takes no query parameters; recomposing the URL with
            # an arch would 400 every fetch.
            Assert-True (@($plan.Requests) -contains "GET $($entry.fileUrl)") `
                "the advertised fileUrl is used verbatim; saw: $(@($plan.Requests) -join ' | ')"
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }

    It 'resumes a short transfer with a Range request instead of starting over' {
        $bytes = Get-FakeArtifactByte -Length 65536
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $plan.TruncateFirstFileResponse = $true
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'resumed.iso'
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $sha
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 120

            # Restarting a multi-GB artifact because the last 10% went missing is
            # the failure this avoids: the second request asks only for the rest.
            Assert-Equal 'downloaded' $result.outcome -Because "expected a resumed fetch, error was: $($result.error)"
            Assert-Equal $sha ((Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash.ToLowerInvariant()) `
                -Because 'the resumed halves join into the original artifact, not two spliced copies'
            Assert-Equal 2 (@($plan.Requests | Where-Object { $_ -match '/file/' }).Count) -Because 'exactly one resume, not a restart loop'
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }

    It 'refuses bytes whose hash does not match the metadata, and leaves nothing behind' {
        $bytes = Get-FakeArtifactByte -Length 8192
        $wrongSha = Get-FakeArtifactHash -Bytes (Get-FakeArtifactByte -Length 8191)
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'mismatch.iso'
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' -ByteCount $bytes.Length -Sha256 $wrongSha
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 120

            Assert-True ($result.outcome -ne 'downloaded') "unverified bytes are never reported as downloaded; got '$($result.outcome)'"
            Assert-Equal 'failed' $result.outcome -Because 'a hash that does not match is a definite negative verdict, not an absent agent'
            # A caller that only tests for the file would otherwise promote it.
            Assert-True (-not (Test-Path -LiteralPath $staging)) 'the bogus artifact is deleted rather than left for the promote path'
            Assert-True ($result.error -match 'SHA-256 mismatch') "the error names the mismatch; got '$($result.error)'"
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }

    It 'reports unavailable for a pool that is not mounted and for an image it does not serve' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'unavailable.iso'
        try {
            [void]$plan.EnsureQueue.Add(@{ Status = 503; Json = '{"ok":false,"state":"unavailable","reason":"pool-unavailable"}' })
            $unmounted = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 30
            Assert-Equal 'unavailable' $unmounted.outcome -Because 'a 503 sends the caller back to the path it already had'
            Assert-True ($unmounted.error -match 'pool-unavailable') "the machine-readable reason is carried through; got '$($unmounted.error)'"

            $plan.EnsureQueue.Clear()
            [void]$plan.EnsureQueue.Add(@{ Status = 404; Json = '{"ok":false,"state":"unsupported","reason":"unsupported-image"}' })
            $unsupported = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.windows.11' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 30
            Assert-Equal 'unavailable' $unsupported.outcome -Because 'a family the agent has no resolver for is not a failure'

            Assert-Equal 'unavailable' (Request-DownloadAgentImage -BaseUrl '' -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging).outcome -Because 'no endpoint is the commonest case of all'
            Assert-True (-not (Test-Path -LiteralPath $staging)) 'nothing was staged on any of those paths'
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }

    It 'reports a failed agent download as failed, not as an absent agent' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'failed.iso'
        try {
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'failed' -ErrorText 'origin probe releases.ubuntu.com: dial tcp i/o timeout') })
            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 30
            Assert-Equal 'failed' $result.outcome
            Assert-True ($result.error -match 'i/o timeout') "the agent's own error is surfaced; got '$($result.error)'"
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }

    It 'gives up on a deadline instead of throwing when a 202 never turns ready' {
        $plan = Get-FakeAgentPlan
        $agent = Get-FakeAgent -Plan $plan
        $staging = Join-Path (Get-DownloadAgentScratchDir) 'deadline.iso'
        try {
            [void]$plan.EnsureQueue.Add(@{ Status = 202; Json = (Get-FakeEnsureJson -State 'downloading' -RefreshInFlight -BytesDone 1 -BytesTotal 100) })
            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 3
            Assert-Equal 'unavailable' $result.outcome -Because 'an exhausted budget sends the caller to the fallback, it does not fail the cycle'
            Assert-True ($result.error -match 'still downloading') "the error says what ran out; got '$($result.error)'"
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }
}

Describe 'Yuruna.DownloadAgent sentinel interop' {

    It 'hands back an origin quadruple that Test-DownloadAlreadyCurrent accepts on the next run' {
        # The interop that matters most: a host that took agent bytes must write
        # the SAME 4-line sentinel it would have written from its own download,
        # or the no-agent fallback re-downloads everything on the next run.
        $bytes = Get-FakeArtifactByte -Length 16384
        $sha = Get-FakeArtifactHash -Bytes $bytes
        $lastModified = 'Thu, 23 Jul 2026 09:14:02 GMT'
        $plan = Get-FakeAgentPlan
        $plan.FileBytes = $bytes
        $plan.OriginLastModified = $lastModified
        $agent = Get-FakeAgent -Plan $plan
        $scratch = Get-DownloadAgentScratchDir
        $staging = Join-Path $scratch 'downloaded.iso'
        $baseImage = Join-Path $scratch 'ubuntu.server.26.iso'
        $sentinel = Join-Path $scratch 'ubuntu.server.26.txt'
        try {
            $entry = Get-FakeCatalogEntry -BaseUrl $agent.BaseUrl -Filename 'ubuntu-26.04.1-live-server-amd64.iso' `
                -ByteCount $bytes.Length -Sha256 $sha -LastModified $lastModified
            [void]$plan.EnsureQueue.Add(@{ Status = 200; Json = (Get-FakeEnsureJson -State 'ready' -Image $entry) })

            $result = Request-DownloadAgentImage -BaseUrl $agent.BaseUrl -HostType 'ubuntu.kvm' `
                -ImageKey 'guest.ubuntu.server.26' -Arch 'amd64' -StagingPath $staging -DeadlineSeconds 120
            Assert-Equal 'downloaded' $result.outcome -Because "expected bytes, error was: $($result.error)"

            # Exactly the promote path a Get-Image script runs today.
            Move-Item -LiteralPath $staging -Destination $baseImage -Force
            Write-ImageSentinel -SourceUrl $result.sourceUrl -OriginFile $sentinel `
                -SizeBytes $result.byteCount -LastModified $result.lastModified -Confirm:$false

            $lines = @(Get-Content -LiteralPath $sentinel)
            Assert-Equal 4 $lines.Count -Because 'the 4-line format is what the reader requires'
            Assert-Equal $result.filename $lines[0].Trim() -Because 'the agent upstreamFilename and the URL-derived filename must agree'
            Assert-Equal $result.sourceUrl $lines[1].Trim()
            Assert-Equal $result.byteCount $lines[2].Trim()
            Assert-Equal $result.lastModified $lines[3].Trim()

            # The real reader, HEADing the real (fake) origin: the quadruple has
            # to survive the round trip or the next run downloads again.
            Assert-True (Test-DownloadAlreadyCurrent -SourceUrl $result.sourceUrl -BaseImageFile $baseImage -OriginFile $sentinel) `
                'the sentinel written from agent metadata satisfies the skip guard'
        } finally {
            Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $baseImage -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $sentinel -Force -ErrorAction SilentlyContinue
            Close-FakeAgent -Agent $agent
        }
    }
}

Describe 'Yuruna.DownloadAgent import precedence' {

    It 'never takes the command-table slot the driver cache wrapper owns' {
        # Loading a whole platform driver has process-wide effects, so the check
        # runs in a child pwsh: import the driver, then this module, and prove
        # Save-CachedHttpUri still resolves to the driver's 2-parameter wrapper.
        # If it resolved to the shared 3-parameter implementation instead, the
        # cache-discovery closure would be dropped and every image download
        # would go direct, with no error anywhere.
        $driverFolder = if ($IsWindows) { 'windows.hyper-v' } elseif ($IsMacOS) { 'macos.utm' } else { 'ubuntu.kvm' }
        $driver = Join-Path $AgentRepoRoot 'host' -AdditionalChildPath $driverFolder, 'modules', 'Yuruna.Host.psm1'
        Assert-True (Test-Path -LiteralPath $driver) "the $driverFolder driver is present at $driver"

        $probe = Join-Path (Get-DownloadAgentScratchDir) 'precedence-probe.ps1'
        $body = @(
            "Import-Module '$driver' -DisableNameChecking -WarningAction SilentlyContinue -ErrorAction Stop",
            "Import-Module '$AgentClientModule' -DisableNameChecking -ErrorAction Stop",
            '$command = Get-Command Save-CachedHttpUri -ErrorAction SilentlyContinue',
            'if ($null -eq $command) { "MISSING"; exit 0 }',
            '"$($command.ModuleName)|$($command.Parameters.ContainsKey(''ResolveCacheHostIp''))"'
        )
        Set-Content -LiteralPath $probe -Value $body
        try {
            $pwsh = (Get-Process -Id $PID).Path
            $out = @(& $pwsh -NoProfile -NonInteractive -File $probe 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            $verdict = @($out | Where-Object { $_ -match '^[\w.]+\|(True|False)$' -or $_ -eq 'MISSING' }) | Select-Object -Last 1
            Assert-True ($verdict -ne 'MISSING') 'Save-CachedHttpUri must still be on the command table after both imports'
            Assert-Equal 'Yuruna.Host|False' $verdict `
                -Because "the driver wrapper (which has no -ResolveCacheHostIp of its own) must keep the slot; the child said: $($out -join ' / ')"
        } finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Download-agent pins agree across languages' {
    # These constants are duplicated by necessity: the Go daemon cannot read a
    # PowerShell literal and the host scripts cannot read a Go one. Drift is
    # silent rather than loud -- a host would simply install whichever artifact
    # the agent pinned, so two KVM hosts (one with an agent, one without) would
    # end up with different driver bundles and the agentless one would
    # re-download once after every switch. Nothing else compares them.

    It 'pins the same virtio-win build in the KVM script and the Go resolver' {
        $kvm = Get-Content -Raw -LiteralPath (Join-Path $AgentRepoRoot 'host/ubuntu.kvm/guest.windows.11/Get-Image.ps1')
        $go  = Get-Content -Raw -LiteralPath (Join-Path $AgentRepoRoot 'test/extension/download-agent-service/server/internal/imagestore/resolve.go')
        $rx  = 'https://fedorapeople\.org/[^\s''"]*?virtio-win-[0-9.]+\.iso'
        $kvmUrl = ([regex]::Match($kvm, $rx)).Value
        $goUrl  = ([regex]::Match($go,  $rx)).Value
        Assert-True ([bool]$kvmUrl) 'the KVM script still pins a versioned virtio-win URL'
        Assert-True ([bool]$goUrl)  'the Go resolver still pins a versioned virtio-win URL'
        Assert-Equal $kvmUrl $goUrl -Because 'a host served by the agent would otherwise get a different driver bundle than the same host without one'
    }

    It 'pins the same Fido release and hash in the host scripts and the agent seed' {
        $sites = @(
            'host/windows.hyper-v/guest.windows.11/Get-Image.ps1',
            'host/macos.utm/guest.windows.11/Get-Image.ps1',
            'host/vmconfig/download-agent-service.base.user-data'
        )
        $tags = @(); $hashes = @()
        foreach ($s in $sites) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $AgentRepoRoot $s)
            $tags   += ([regex]::Match($text, 'Fido/(v[0-9.]+)/Fido\.ps1')).Groups[1].Value
            $hashes += ([regex]::Match($text, '[0-9a-f]{64}')).Value
        }
        Assert-True (($tags | Where-Object { $_ }).Count -eq $sites.Count) "every site names a pinned Fido tag; got: $($tags -join ',')"
        Assert-Equal 1 (@($tags   | Sort-Object -Unique).Count) -Because "the agent must vendor the same Fido release the hosts run; got: $($tags -join ', ')"
        Assert-Equal 1 (@($hashes | Sort-Object -Unique).Count) -Because "a hash that differs from the pinned release would refuse to install, silently disabling the Windows family"
    }
}
