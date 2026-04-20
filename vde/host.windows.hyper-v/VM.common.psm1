<#PSScriptInfo
.VERSION 0.1
.GUID 42c0ffee-a0de-4e1f-a2b3-c4d5e6f7a8b9
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# --- Define Oscdimg Path (adjust '10' for your ADK version if necessary) ---
$OscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\Oscdimg.exe"

# CreateIso: build an ISO from a source directory using Oscdimg
function CreateIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$VolumeId = "cidata"
    )

    # Resolve current working directory
    $cwd = (Get-Location).ProviderPath

    # Make SourceDir absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw "SourceDir not found: $SourceDir"
    }

    # Make OutputFile absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path $cwd $OutputFile
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    # Ensure output directory exists
    $outDir = Split-Path -Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $OscdimgPath)) {
        Throw "Oscdimg.exe not found at path: $OscdimgPath. Install the Windows ADK Deployment Tools or set ``-OscdimgPath`` to the proper location."
    }

    Write-Information "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId"

    Write-Output "ISO created successfully at: $OutputFile"
}

# --- squid-cache IP discovery (shared by producer + consumers) --------------
# Prior state had the same KVP+ARP dual-strategy copy-pasted across
# guest.squid-cache/New-VM.ps1, guest.ubuntu.server/New-VM.ps1,
# guest.ubuntu.desktop/New-VM.ps1, and a KVP-only variant in
# test/Start-SquidCache.ps1. The variants drifted — Start-SquidCache's
# KVP-only summary would print "(discovery failed)" even when the ARP
# path inside the inner New-VM.ps1 had already succeeded and the cache
# was serving. These three functions are the single source of truth so
# a host-side answer here matches what any guest will see next.

function Get-CacheVmCandidateIp {
    <#
    .SYNOPSIS
        Candidate IPv4 addresses for a running Hyper-V VM.
    .DESCRIPTION
        Combines two lookups; duplicates removed, KVP-preferred order:
          1. Hyper-V KVP (Get-VMNetworkAdapter.IPAddresses) — requires
             hv_kvp_daemon inside the guest; empty until the guest has
             installed hyperv-daemons and the daemon is running.
          2. Default-Switch ARP cache (Get-NetNeighbor filtered by the
             VM's MAC and the Default-Switch InterfaceIndex) — works as
             soon as the guest sends any packet, independent of guest
             agents. Stale 'Permanent' entries across VM rebuilds can
             make the same MAC map to multiple IPs; all are returned so
             the caller's :3128 TCP probe can pick the live one.
    .OUTPUTS
        System.String[] — zero or more IPv4 addresses, KVP entries first.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        $VM
    )

    $kvpIps = @($VM | Get-VMNetworkAdapter |
        ForEach-Object { $_.IPAddresses } |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })

    $arpIps = @()
    $hostAdapter = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like '*Default Switch*' } | Select-Object -First 1
    $vmMac = ($VM | Get-VMNetworkAdapter | Select-Object -First 1).MacAddress
    if ($hostAdapter -and $vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
        $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
        $arpIps = @(Get-NetNeighbor -AddressFamily IPv4 -InterfaceIndex $hostAdapter.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LinkLayerAddress -eq $vmMacDashed -and
                $_.IPAddress -match '^\d+\.\d+\.\d+\.\d+$' -and
                $_.State -ne 'Unreachable'
            } | ForEach-Object { $_.IPAddress })
    }

    # Emit individual strings into the pipeline. Callers that need a
    # guaranteed array wrap with @(); foreach and -join handle scalar/
    # $null/array inputs uniformly.
    #
    # Three traps this shape specifically avoids:
    # 1. Do NOT add a leading `,` array-wrap. It made the function emit
    #    ONE String[] object, which @(Get-CacheVmCandidateIp ...) at a
    #    call site then wrapped into Object[1] whose sole element was
    #    the array — breaking downstream `foreach ($ip in ...)` with
    #    "Cannot convert value to type System.String".
    # 2. Do NOT use `[string[]](pipeline)` as the return expression. On
    #    an empty input the cast emits a single $null into the pipeline
    #    instead of zero items, so callers end up with a ghost element.
    # 3. Do NOT wrap in an outer `@(...)`. PSScriptAnalyzer statically
    #    infers the return type as System.Array from the @-subexpression
    #    even when the runtime contents are strings — tripping
    #    PSUseOutputTypeCorrectly. The bare pipeline below emits strings
    #    directly; static analysis sees System.String emission matching
    #    the [OutputType] above.
    ($kvpIps + $arpIps) | Select-Object -Unique
}

function Test-SquidPort {
    <#
    .SYNOPSIS
        Non-blocking TCP probe returning $true iff the port accepts a
        connection within $TimeoutMs.
    .DESCRIPTION
        Synchronous TcpClient.Connect() can block ~20s on a filtered or
        silently-dropped port, which starves outer progress loops; the
        async BeginConnect + WaitOne pattern caps the wait predictably.
    #>
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [int]$Port = 3128,
        [int]$TimeoutMs = 500
    )
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        return ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected)
    } catch {
        Write-Verbose "probe ${IpAddress}:${Port} failed: $($_.Exception.Message)"
        return $false
    } finally {
        $tcp.Close()
    }
}

function Get-WorkingSquidProxyUrl {
    <#
    .SYNOPSIS
        "http://<ip>:3128" of a squid-cache VM that actually answers on
        port 3128, or $null if none of the candidate IPs respond.
    .DESCRIPTION
        One-shot helper for consumers (ubuntu guests) and the
        Start-SquidCache.ps1 summary. Does NOT wait for the cache VM to
        boot or for squid to come up — callers expect the VM to already
        be running and squid listening. The producer side
        (guest.squid-cache/New-VM.ps1) uses Get-CacheVmCandidateIp
        directly because it provisions the cache itself and must poll
        while cloud-init is running.
    .OUTPUTS
        System.String or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [string]$VMName = "squid-cache",
        [int]$ProbeTimeoutMs = 500
    )

    $cacheVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $cacheVM -or $cacheVM.State -ne 'Running') { return $null }

    foreach ($ip in (Get-CacheVmCandidateIp -VM $cacheVM)) {
        if (Test-SquidPort -IpAddress $ip -TimeoutMs $ProbeTimeoutMs) {
            return "http://${ip}:3128"
        }
    }
    return $null
}

function Assert-HyperVEnabled {
    <#
    .SYNOPSIS
        Returns $true when Hyper-V is enabled AND vmms is running; $false
        with a diagnostic Write-Output otherwise.

    .DESCRIPTION
        Verifies the Hyper-V preconditions every New-VM and tear-down
        script depends on. Bypasses Get-WindowsOptionalFeature deliberately:
        that cmdlet dispatches to the DISM provider through a COM shim
        (CompatiblePSEdition proxy in pwsh 7) that, on fresh Windows 11
        installs or immediately after Enable-WindowsOptionalFeature
        completes, can fail with "Class not registered" (HRESULT
        0x80040154) even when Hyper-V is actually enabled and healthy.
        The failure was seen on the very first post-install run of
        Start-SquidCache -> guest.squid-cache/New-VM.ps1. dism.exe is a
        plain Win32 tool that the cmdlet itself wraps; calling it directly
        sidesteps the COM failure and is the same workaround used by
        install/windows-install.ps1.

        Home editions: if Microsoft-Hyper-V-All is not present on the SKU
        at all, dism.exe emits error 0x800f080c / "Feature name ... is
        unknown." We surface that as a distinct message so the operator
        knows the issue is the edition, not a transient state.

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
    if (-not (Test-Path $dismExe)) {
        Write-Output "dism.exe not found at $dismExe. Cannot verify Hyper-V state."
        return $false
    }
    $infoOut = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
    $infoExit = $LASTEXITCODE
    if ($infoExit -ne 0) {
        if ($infoOut -match '0x800f080c' -or $infoOut -match 'Feature name .* is unknown') {
            Write-Output 'Microsoft-Hyper-V-All feature not available on this SKU (Home edition?). Hyper-V VMs cannot run here.'
        } else {
            Write-Output "dism.exe /Get-FeatureInfo exited $infoExit."
            Write-Output ($infoOut -join [Environment]::NewLine)
        }
        return $false
    }

    $state = 'Unknown'
    foreach ($line in $infoOut) {
        if ($line -match '^State\s*:\s*(\S+)') { $state = $Matches[1]; break }
    }
    if ($state -ne 'Enabled') {
        Write-Output "Hyper-V is not enabled (state: $state). Run install\windows-install.ps1 and reboot, then retry."
        return $false
    }

    $service = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Output "Hyper-V Virtual Machine Management service (vmms) not found. Hyper-V likely needs a reboot after enabling."
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Output "Hyper-V Virtual Machine Management service (vmms) is not running (status: $($service.Status)). Try: Start-Service vmms"
        return $false
    }

    return $true
}
