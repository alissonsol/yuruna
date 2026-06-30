<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42b8e6a4-3d17-4c92-8f05-6a1b9d2e7c40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host provisioning new-vm get-image
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

# Shared per-guest provisioning helpers for the host drivers. The three
# Yuruna.Host drivers carried byte-identical copies of the New-VM child-
# process runner -- the only platform variable was the host subdirectory
# string literal -- and the Windows and macOS drivers carried byte-identical
# copies of the Get-Image console + HTML-log line writer. They live here once
# now so a fix to the child-arg forwarding, the %-complete line filter, or the
# log-line HTML encoding lands in one place instead of drifting across drivers.
#
# Each driver imports this module (non-Global) into its own scope: New-VM
# becomes a thin wrapper that passes its constant host subdir, and Get-Image
# calls the imported Write-GetImageLine directly. The driver-private pieces a
# shared body cannot see -- Get-VMIp (Invoke-WaitVmIp), Get-ImagePath
# (Invoke-GetImage), and the kvm-only Write-Information log writer -- are
# injected as CommandInfo/scriptblocks because a name typed in THIS module
# resolves in this module's session state, not the importing driver's; a
# bare-name call to a driver-private command would silently fail to bind
# (see feedback_closure_foreign_module_command_resolution.md).
#
# The caching-proxy probe's cross-module dependencies (Get-CachingProxyPort,
# Test-IpAddress, Format-IpUrlHost from Test.VMUtility; Read-CachingProxyState
# from Test.CachingProxy) are called by name, so this module owns those imports
# itself (below) rather than assuming a driver imported them into a visible
# scope -- mirroring the Yuruna.HostDownload.psm1 self-import pattern.
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.VMUtility.psm1')    -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.CachingProxy.psm1') -DisableNameChecking -ErrorAction SilentlyContinue

function Invoke-PerGuestNewVm {
    <#
    .SYNOPSIS
        Run a guest's per-host New-VM.ps1 as a child process and map its exit
        code to a { success; errorMessage } result.
    .DESCRIPTION
        The host subdirectory under <RepoRoot>/ (e.g. 'host\windows.hyper-v',
        'host/ubuntu.kvm', 'host/macos.utm') is the SOLE platform variable, so
        it is a plain -HostSubdir string param rather than an injected
        scriptblock; each driver's New-VM wrapper supplies its constant value.

        -CachingProxyUrl and -Username are forwarded to the per-guest script
        only when (a) the caller bound them AND (b) the target script declares
        them -- this lets the contract grow new pass-through arguments without
        breaking guests (e.g. windows.11, caching-proxy, macos.26) that do not
        consume them. A bound -Username the script does not declare is surfaced
        on the Verbose stream so the operator notices a dropped planner cascade.
    .OUTPUTS
        [hashtable] @{ success = [bool]; errorMessage = [string] }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostSubdir,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyUrl,
        [string]$Username
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Create VM ($GuestKey)")) { return @{ success = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path $HostSubdir (Join-Path $GuestKey 'New-VM.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; errorMessage = "New-VM.ps1 not found at: $scriptPath" }
    }
    $childArgs = @('-VMName', $VMName)
    $scriptAcceptsProxy    = $false
    $scriptAcceptsUsername = $false
    try {
        $cmdInfo = Get-Command -Name $scriptPath -ErrorAction Stop
        if ($cmdInfo.Parameters) {
            $scriptAcceptsProxy    = [bool]$cmdInfo.Parameters.ContainsKey('CachingProxyUrl')
            $scriptAcceptsUsername = [bool]$cmdInfo.Parameters.ContainsKey('Username')
        }
    } catch {
        $scriptAcceptsProxy    = $false
        $scriptAcceptsUsername = $false
    }
    if ($PSBoundParameters.ContainsKey('CachingProxyUrl') -and $scriptAcceptsProxy) {
        $childArgs += @('-CachingProxyUrl', $CachingProxyUrl)
    }
    if ($PSBoundParameters.ContainsKey('Username') -and $Username -and $scriptAcceptsUsername) {
        $childArgs += @('-Username', $Username)
    } elseif ($PSBoundParameters.ContainsKey('Username') -and $Username -and -not $scriptAcceptsUsername) {
        Write-Verbose "Cascaded -Username '$Username' NOT forwarded: $scriptPath does not declare a -Username parameter."
    }
    Write-Verbose "Running: $scriptPath $($childArgs -join ' ')"
    $output = & pwsh -NoProfile -File $scriptPath @childArgs 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        $text = "$line".TrimEnd()
        if ($text -ne '' -and $text -notmatch '^\s*\d+%\s+complete') {
            Write-Information $text
        }
    }
    if ($exitCode -ne 0) {
        return @{ success = $false; errorMessage = "New-VM.ps1 exited with code $exitCode" }
    }
    return @{ success = $true; errorMessage = $null }
}

function Write-GetImageLine {
    <#
    .SYNOPSIS
        Echo a Get-Image progress line to the console and, when a per-cycle HTML
        log is open, append its HTML-encoded copy to that log.
    .DESCRIPTION
        The console write is unconditional. The HTML-log append happens only
        while global:__YurunaLogFile holds the runner's per-cycle log handle;
        the line is HtmlEncode'd first so guest output containing <, >, or &
        cannot break the surrounding log markup, and the append is best-effort
        (a transient file error does not fail the caller).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaLogFile is the per-cycle HTML log handle, set/cleared by the runner; intentionally process-wide.')]
    [CmdletBinding()]
    param([string]$Line)
    Microsoft.PowerShell.Utility\Write-Host $Line
    if ($global:__YurunaLogFile) {
        [System.Net.WebUtility]::HtmlEncode($Line) |
            Microsoft.PowerShell.Utility\Out-File -FilePath $global:__YurunaLogFile -Append -Encoding utf8 -ErrorAction SilentlyContinue
    }
}

function Invoke-WaitVmIp {
    <#
    .SYNOPSIS
        Poll the driver's IP resolver until an address is discovered or the
        timeout expires.
    .DESCRIPTION
        -ResolveVmIp is the driver's Get-VMIp passed as a CommandInfo (the
        driver runs Get-Command Get-VMIp in ITS scope). The discovery is
        driver-private and unresolvable by name from this module's session
        state, so it must be injected rather than called directly.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3,
        [Parameter(Mandatory)]$ResolveVmIp
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidate = & $ResolveVmIp -VMName $VMName
        if ($candidate) { return [string]$candidate }
        Start-Sleep -Seconds $PollSeconds
    }
    return $null
}

function Invoke-GetImage {
    <#
    .SYNOPSIS
        Run a guest's per-host Get-Image.ps1 to download or refresh the base
        image, mapping its exit code to a { success; skipped; errorMessage }
        result.
    .DESCRIPTION
        -HostSubdir is the driver's constant host subdirectory under
        <RepoRoot>/. -ResolveImagePath is the driver's Get-ImagePath as a
        CommandInfo: the image-path table is platform-specific and lives in the
        driver, so it is injected (a bare name would resolve in this module's
        scope, not the driver's). -WriteLine is an optional log-line writer
        CommandInfo; when omitted the in-module Write-GetImageLine is used
        (win/mac), and the kvm driver passes Write-Information instead.
    .OUTPUTS
        [hashtable] @{ success = [bool]; skipped = [bool]; errorMessage = [string] }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostSubdir,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force,
        [Parameter(Mandatory)]$ResolveImagePath,
        $WriteLine
    )
    $writer = if ($WriteLine) { $WriteLine } else { Get-Command Write-GetImageLine }
    if (-not $PSCmdlet.ShouldProcess($GuestKey, 'Download / refresh base image')) { return @{ success = $false; skipped = $false; errorMessage = 'WhatIf' } }
    $scriptPath = Join-Path $RepoRoot (Join-Path $HostSubdir (Join-Path $GuestKey 'Get-Image.ps1'))
    if (-not (Test-Path $scriptPath)) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 not found at: $scriptPath" }
    }
    if (-not $Force) {
        $imagePath = & $ResolveImagePath -GuestKey $GuestKey
        if ($imagePath -and (Test-Path $imagePath)) {
            & $writer "Image exists, skipping download: $imagePath"
            return @{ success = $true; skipped = $true; errorMessage = $null }
        }
    }
    & $writer "Running: $scriptPath"
    & pwsh -NoProfile -File $scriptPath 2>&1 | ForEach-Object {
        & $writer ([string]$_)
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        return @{ success = $false; skipped = $false; errorMessage = "Get-Image.ps1 exited with code $code" }
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

function Invoke-CachingProxyAvailableProbe {
    <#
    .SYNOPSIS
        Resolve the steady-state caching-proxy URL (YURUNA_CACHING_PROXY_IP
        override, else the recorded local cache IP), or $null when no cache
        answers. Returns the proxy URL string.
    .DESCRIPTION
        -VerifyHint is the platform-specific operator command template embedded
        in the final unreachable-cache warning (Test-NetConnection on Windows,
        nc on macOS); it is a {0}/{1} format string filled with the cache IP and
        HTTP port. The kvm driver keeps its own probe (it omits the
        Format-IpUrlHost IPv6-bracketing the guests rely on), so this shared
        body covers win + mac only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VerifyHint
    )
    $httpPort = Get-CachingProxyPort -Scheme http
    # External cache override -- $Env:YURUNA_CACHING_PROXY_IP short-circuits
    # local discovery and points at a remote squid. If the remote doesn't
    # answer, return $null (do NOT fall back to local) so misconfiguration
    # surfaces as "no cache" instead of silently flipping target.
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if (-not (Test-IpAddress $externIp)) {
            Write-Warning "YURUNA_CACHING_PROXY_IP='$externIp' is not a valid IPv4 or IPv6 address -- ignoring."
            return $null
        }
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $tcp.BeginConnect($externIp, $httpPort, $null, $null)
            # 3s cap, not 1s: this is the EXTERNAL/remote proxy path. A cross-host
            # cache (e.g. a UTM/macOS-hosted squid over bridged networking) routinely
            # takes 600ms-1s+ to ACCEPT a TCP connection, so a 1s cap false-negatives
            # and the runner reports a healthy remote cache as "did not answer." The
            # cap is free for a fast cache (connect returns on accept); it only delays
            # the verdict for a genuinely-down one.
            if ($async.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected) {
                return "http://$(Format-IpUrlHost $externIp):${httpPort}"
            }
        } catch {
            Write-Verbose "external caching proxy probe to ${externIp}:${httpPort} failed: $($_.Exception.Message)"
        } finally {
            $tcp.Close()
        }
        Write-Warning "YURUNA_CACHING_PROXY_IP=${externIp} set but ${externIp}:${httpPort} did not answer within 3s."
        return $null
    }

    # Local cache: probe only the IP we recorded ourselves at the last
    # Start-CachingProxy.ps1. Empty state -> no cache (the explicit
    # contract after Stop-CachingProxy.ps1). State-set-but-unreachable
    # is loud (Write-Warning) because the inner runner's bootstrap
    # detection runs ONCE per cycle -- a silently-failed probe means
    # the whole cycle's guests download direct from the internet, and
    # we want the operator to see "why" alongside the headline
    # "Caching proxy: not detected" line in Invoke-TestRunner output.
    $stateIp = (Read-CachingProxyState).ipAddress
    if (-not $stateIp -or -not (Test-IpAddress $stateIp)) {
        Write-Warning "Test-CachingProxyAvailable: state.ipAddress is empty -- no locally-owned cache. Set `$Env:YURUNA_CACHING_PROXY_IP to point at a remote cache, or run Start-CachingProxy.ps1."
        return $null
    }
    # 1500 ms matches test/Test-CachingProxy.ps1's CLI probe so a
    # cache that answers the standalone smoke test also answers here.
    # Tighter timeouts (~500 ms) leave a window where a momentarily
    # busy squid (cold start, big cidata fetch) misses the runner's
    # single bootstrap probe and silently strands the whole inner cycle.
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($stateIp, $httpPort, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne(1500) -and $tcp.Connected) {
            return "http://$(Format-IpUrlHost $stateIp):${httpPort}"
        }
    } catch {
        Write-Verbose "cache probe ${stateIp}:${httpPort} failed: $($_.Exception.Message)"
    } finally {
        $tcp.Close()
    }
    Write-Warning "Test-CachingProxyAvailable: state.ipAddress=${stateIp} did not answer :${httpPort} within 1500 ms; treating cache as unavailable. Verify with '$($VerifyHint -f $stateIp, $httpPort)'; if it answers, the cache is running and the next runner cycle will pick it up. If not, re-run Start-CachingProxy.ps1 (the VM may have restarted with a new DHCP lease)."
    return $null
}

Export-ModuleMember -Function Invoke-PerGuestNewVm, Write-GetImageLine, Invoke-WaitVmIp, Invoke-GetImage, Invoke-CachingProxyAvailableProbe
