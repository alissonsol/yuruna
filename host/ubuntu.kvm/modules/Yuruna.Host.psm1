<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42539052-a22b-452d-ad7f-0bbf053904ff
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host kvm libvirt
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for Ubuntu KVM/libvirt hosts. Implements the
    Yuruna.Host driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for Ubuntu KVM/libvirt hosts.

.DESCRIPTION
    Drives guest VMs on a Linux host running libvirt + KVM. Sibling
    implementations live at host/macos.utm/modules/Yuruna.Host.psm1
    (macOS UTM) and host/windows.hyper-v/modules/Yuruna.Host.psm1
    (Windows Hyper-V). Same driver contract
    (host/Yuruna.Host.Contract.psm1) on all three; the
    test harness is host-agnostic.

    All libvirt calls go through `qemu:///system` (the system
    daemon, libvirtd). The user is expected to be in the `libvirt`
    group so virsh / virt-install run without sudo for VM ops; some
    operations (apt, /etc/environment, systemctl) call sudo
    explicitly.

    Module-qualified calls (e.g. `Yuruna.HostDownload\Save-CachedHttpUri`) appear
    where an external helper shares its name with the contract function
    -- without the qualifier the call would re-enter our own definition
    and recurse.
#>

# --- REGION: Module setup
# Code with one responsibility lives in a part file beside this module
# (Yuruna.Host.<Part>.ps1), dot-sourced at the place it runs from, so it runs in
# this module's scope and order; the exports stay at the end of this file.
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$script:HostTag        = 'host.ubuntu.kvm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/ubuntu.kvm'
$script:VirshUri       = 'qemu:///system'
$script:VmRootDir      = Join-Path $HOME 'yuruna/vms'
$script:PortMapDir     = Join-Path $HOME 'yuruna/portmap'
# Last neighbor-cache sweep per VM. Module-scoped so a polling caller cannot
# turn its poll interval into a sweep interval; see Update-GuestNeighborCache.
$script:NeighborSweepMemo = @{}
# The last IPv4 prefix this host held. Kept so the neighbor sweep still has a
# subnet to work with during the seconds between leases, when the live lookup
# has nothing to report.
$script:LastKnownHostPrefix = $null
# Cap for a single bounded virsh query (Get-VMState and the lookups the rung-2
# network step makes). A libvirtd that stops answering must turn into an
# 'unknown' answer inside this window instead of holding the caller; a healthy
# daemon answers these queries in well under a second.
$script:VirshQueryTimeoutSeconds = 20
# Cap for any other virsh call. Every call is bounded: a daemon that accepts
# the connection and then never answers would otherwise hold a lifecycle verb,
# and the cycle with it, until the step watchdog ends the whole cycle.
$script:VirshCallTimeoutSeconds = 120
# Snapshot create and revert copy disk state and can take minutes on a large
# disk; they get a longer cap of their own.
$script:VirshSnapshotTimeoutSeconds = 900
# Whether the last Invoke-Virsh call went unanswered; see
# Test-VirshLastCallUnanswered.
$script:VirshLastCallUnanswered = $false
# libvirt's per-domain pidfile directory for the system connection. Force-stop
# reads the qemu process id from here when libvirtd itself cannot destroy the
# domain; it is a variable so a test can point it at a private directory.
$script:KvmQemuRunDir = '/var/run/libvirt/qemu'
# Process table root that force-stop reads a candidate's command line from
# before signaling it; a variable for the same reason as the pidfile directory.
$script:KvmProcRoot = '/proc'

# --- REGION: Resolve-HostTag
function Resolve-HostTag {
    <#
    .SYNOPSIS
        Returns this driver's host tag, repairing it if module state was lost.
    .DESCRIPTION
        Uses the driver's literal tag when a retained function reference has
        lost its module state after a forced re-import.
    .LINK
        https://yuruna.link/42e5cdfd-0002
    #>
    [OutputType([string])]
    param()
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.ubuntu.kvm' }
    return $script:HostTag
}

# See https://yuruna.link/42e5cdfd-0002
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global
# --- REGION: Shared host modules
# See https://yuruna.link/42ec97cd-0018
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Get-Image discovers the agent by name, so its import must be global.
# See https://yuruna.link/42ec97cd-001a
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.DownloadAgent.psm1') -Force -DisableNameChecking -Global
# See https://yuruna.link/42ec97cd-0017
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global

# Per-guest base image paths -- single table keeps Get-ImagePath, Get-Image,
# and the per-guest Get-Image.ps1 scripts in agreement. A typo or new guest
# fails loud here instead of silently composing the wrong path.
$script:ImagePathTable = @{
    'guest.amazon.linux.2023'  = "$HOME/yuruna/image/amazon.linux.2023/host.ubuntu.kvm.guest.amazon.linux.2023.qcow2"
    'guest.ubuntu.server.24' = "$HOME/yuruna/image/ubuntu.env/host.ubuntu.kvm.guest.ubuntu.server.24.iso"
    'guest.ubuntu.server.26' = "$HOME/yuruna/image/ubuntu.env/host.ubuntu.kvm.guest.ubuntu.server.26.iso"
    'guest.windows.11'    = "$HOME/yuruna/image/windows.11/host.ubuntu.kvm.guest.windows.11.iso"
}

# --- REGION: KVM host helpers
# --- REGION: Invoke-Virsh
function Invoke-Virsh {
    <#
    .SYNOPSIS
        Run virsh under a wall-clock cap and return its stdout and stderr lines
        as an array; never throws.
    .DESCRIPTION
        $LASTEXITCODE carries virsh's exit code. A call that did not finish
        with a complete answer inside -TimeoutSeconds (the process tree is
        killed at the cap) sets 124, and a virsh that could not be started
        sets 127. Test-VirshLastCallUnanswered then tells the caller whether a
        failure was the hypervisor not answering rather than a refusal, which
        is what lets a lifecycle verb report hypervisor_unresponsive.
    .PARAMETER TimeoutSeconds
        Cap for the call; the driver's general cap when omitted.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)][string[]]$VirshArgs,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = $script:VirshCallTimeoutSeconds
    )
    # See https://yuruna.link/42e5cdfd-000f
    $result = Invoke-VirshBounded -VirshArgs $VirshArgs -TimeoutSeconds $TimeoutSeconds
    $complete = Test-DriverNativeResultComplete -Result $result
    $script:VirshLastCallUnanswered = [bool]$result.Started -and -not $complete
    $global:LASTEXITCODE = if ($complete) { [int]$result.ExitCode } elseif ($result.Started) { 124 } else { 127 }
    if ($script:VirshLastCallUnanswered) {
        Write-Verbose "Invoke-Virsh: 'virsh $($VirshArgs -join ' ')' gave no complete answer within ${TimeoutSeconds}s."
    }
    return @(Get-BoundedNativeOutputLine -Result $result -IncludeError)
}

<#
.SYNOPSIS
    $true when the last Invoke-Virsh call reached its cap, or ended without a
    complete answer, instead of answering.
#>
function Test-VirshLastCallUnanswered {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]$script:VirshLastCallUnanswered
}

<#
.SYNOPSIS
    The failure record a KVM lifecycle verb returns: the class says whether the
    hypervisor stopped answering or refused.
#>
function New-KvmVerbFailure {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a record; changes no state.')]
    param([Parameter(Mandatory)][string]$Message)
    $kind = if (Test-VirshLastCallUnanswered) { 'unresponsive' } else { 'tool' }
    return @{ success = $false; errorMessage = $Message; failureClass = [string](New-YurunaHostResult -Kind $kind).failureClass }
}

<#
.SYNOPSIS
    Returns the libvirt domstate string for a VM, or '' on lookup failure.
#>
function Get-VirshDomState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $lines = Invoke-Virsh -VirshArgs @('domstate', $VMName)
    if ($LASTEXITCODE -ne 0) { return '' }
    $first = ($lines | Where-Object { "$_" -ne '' } | Select-Object -First 1)
    return "$first".Trim()
}

<#
.SYNOPSIS
    Run one virsh query under a wall-clock cap, with the same connection and
    locale pin as Invoke-Virsh, and return the bounded-command result.
.DESCRIPTION
    Invoke-Virsh is a bare `& virsh`: a libvirtd that accepts the connection and
    then never answers holds its caller indefinitely. Callers that decide
    something from the answer on a repair path (the responsiveness probe,
    Get-VMState, force-stop, the rung-2 network step) use this instead.

    The connection is always $script:VirshUri: omitting it lets virsh pick
    qemu:///session for an unprivileged user, a different daemon with a
    different inventory. LC_MESSAGES=C with LC_ALL cleared keeps state words
    and error text in English for the classifiers, exactly as Invoke-Virsh
    does, while encoding stays on the operator's locale.
.PARAMETER VirshArgs
    The virsh subcommand and its arguments, without --connect.
.PARAMETER TimeoutSeconds
    Cap for the whole call.
.OUTPUTS
    [hashtable] The Invoke-BoundedNativeCommand result.
#>
function Invoke-VirshBounded {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$VirshArgs,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20
    )
    $argumentList = @('--connect', $script:VirshUri) + @($VirshArgs)
    return Invoke-BoundedNativeCommand -FilePath 'virsh' -ArgumentList $argumentList `
        -Environment @{ LC_MESSAGES = 'C'; LC_ALL = '' } -TimeoutSeconds $TimeoutSeconds
}

<#
.SYNOPSIS
    $true when a bounded-command result is a complete answer: the process
    launched and none of TimedOut, DrainTimedOut, OutputTruncated or KillFailed
    is set. A missing key counts as not set.
.DESCRIPTION
    An exit code read from an incomplete result can describe a process whose
    output was cut, so nothing positive (responsive, absent, stopped) is ever
    concluded from one.
#>
function Test-DriverNativeResultComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Result)
    return (Test-BoundedNativeResultComplete -Result $Result)
}

<#
.SYNOPSIS
    Reduce captured native output to a single private diagnostic line of at most
    1024 characters, with ANSI sequences and control characters removed.
.DESCRIPTION
    The probe and rung records carry this for the worker's private log only.
    Stripping control characters keeps a hostile or garbled tool from writing
    terminal escapes or forged log lines through it.
#>
function Format-VirtualizationProbeDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    return (Format-YurunaVirtualizationProbeDiagnostic @PSBoundParameters)
}

# --- REGION: Caching-proxy service IP discovery
# --- REGION: Resolve-CacheHostIp
function Resolve-CacheHostIp {
    <#
    .SYNOPSIS
        Returns a reachable caching-proxy-service IP, or $null when unavailable.
    .DESCRIPTION
        Honors the explicit remote-cache override before local discovery.
        An unreachable override returns $null rather than using a local cache.
    .OUTPUTS
        [string] Reachable cache IP address, or $null.
    .LINK
        https://yuruna.link/42ec97cd-0018
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyServicePort -Scheme http
    if ($Env:YURUNA_CACHING_PROXY_SERVICE_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim()
        if ((Test-IpAddress $externIp) -and (Test-CachingProxyServicePort -IpAddress $externIp -Port $httpPort -TimeoutMs 500)) {
            return $externIp
        }
        return $null
    }
    $ip = Get-CachingProxyServiceVmIp
    if ($ip -and (Test-IpAddress $ip) -and (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    return $null
}

# --- REGION: Save-CachedHttpUri
function Save-CachedHttpUri {
    <#
    .SYNOPSIS
        Downloads $Uri to $OutFile through the cache, with a direct fallback.
    .DESCRIPTION
        Binds this driver's cache discovery to the shared download pipeline.
    .LINK
        https://yuruna.link/42ec97cd-0018
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Yuruna.HostDownload\Save-CachedHttpUri -Uri $Uri -OutFile $OutFile -ResolveCacheHostIp { Resolve-CacheHostIp }
}

# --- REGION: Host proxy helpers
function Read-LinuxProxyState {
    <#
    .SYNOPSIS
        Read current Linux host proxy state into a backup hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $state = @{ previousUrl = $null; aptConfigPresent = $false }
    if (Test-Path -LiteralPath '/etc/environment') {
        $env = Get-Content -LiteralPath /etc/environment -ErrorAction SilentlyContinue
        foreach ($line in $env) {
            if ($line -match '^(?:HTTPS?|https?)_proxy\s*=\s*"?([^"]+?)"?\s*$') {
                $state['previousUrl'] = $Matches[1]; break
            }
        }
    }
    $state['aptConfigPresent'] = (Test-Path -LiteralPath '/etc/apt/apt.conf.d/99yuruna-host-proxy')
    return $state
}

<#
.SYNOPSIS
    Apply the proxy via /etc/environment + /etc/apt/apt.conf.d (sudo).
#>
function Set-LinuxHostProxy {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public Set-HostProxy/Clear-HostProxy callers already gate via SupportsShouldProcess.')]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    # /etc/environment: clean any prior yuruna-managed lines first, then
    # write the new ones. Match upper-case + lower-case forms.
    if ($ProxyUrl -match '[\x00-\x1f\x7f]') { throw 'Proxy URL contains a control character.' }
    $script = @'
set -e
proxy=$1
proxy=${proxy//\\/\\\\}
proxy=${proxy//\"/\\\"}
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment
printf 'http_proxy="%s"\nhttps_proxy="%s"\nHTTP_PROXY="%s"\nHTTPS_PROXY="%s"\n' "$proxy" "$proxy" "$proxy" "$proxy" >> /etc/environment
mkdir -p /etc/apt/apt.conf.d
printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$proxy" "$proxy" > /etc/apt/apt.conf.d/99yuruna-host-proxy
chmod 0644 /etc/apt/apt.conf.d/99yuruna-host-proxy
'@
    & sudo bash -c $script _ $ProxyUrl | Out-Null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
    Disable the Linux host proxy (rm apt config + strip /etc/environment).
#>
function Disable-LinuxHostProxy {
    [CmdletBinding()]
    param()
    $script = @'
set -e
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment
rm -f /etc/apt/apt.conf.d/99yuruna-host-proxy
'@
    & sudo bash -c $script | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# --- REGION: VM lifecycle
# --- REGION: New-VM
function New-VM {
    <#
    .SYNOPSIS
        Create a guest VM by running the per-guest New-VM.ps1 script.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-PerGuestNewVm, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyServiceUrl,
        # Forward bound overrides only when the per-guest script declares them.
        # See https://yuruna.link/42ec97cd-0017
        [string]$Username,
        [string]$Hostname,
        [string]$MemoryStartupBytes,
        [string]$Cores,
        # KVM nested virtualization is configured on the host kernel module.
        [string]$ExposeVirtualizationExtensions
    )
    # Preserve bound overrides and -WhatIf/-Confirm in the shared runner.
    # See https://yuruna.link/42ec97cd-0017
    $result = Invoke-PerGuestNewVm -HostSubdir 'host/ubuntu.kvm' @PSBoundParameters
    # See https://yuruna.link/42e5cdfd-0010
    $newVmExitCode = $LASTEXITCODE
    if ($result -and $result.success -and (Get-VirshDomState -VMName $VMName) -eq 'running') {
        [void](Start-VMDhcpCapture -VMName $VMName)
    }
    if ($null -ne $newVmExitCode) { $global:LASTEXITCODE = $newVmExitCode }
    return $result
}

# --- REGION: Start-VM
function Start-VM {
    <#
    .SYNOPSIS
        Start a guest VM previously created by New-VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef'))) {
        return @{ success = $false; errorMessage = 'WhatIf' }
    }
    # Idempotent: a VM already running is success.
    $state = Get-VirshDomState -VMName $VMName
    if ($state -eq 'running') {
        return @{ success = $true; errorMessage = $null; alreadyRunning = $true }
    }
    if (-not $state) {
        return (New-KvmVerbFailure -Message (Format-YurunaOperatorMessage -Key 'host.operator_b336377014884ff4' -Arguments @{ vMName = "$VMName" }))
    }
    $output = Invoke-Virsh -VirshArgs @('start', $VMName)
    if ($LASTEXITCODE -ne 0) {
        return (New-KvmVerbFailure -Message (Format-YurunaOperatorMessage -Key 'host.operator_f5d119c4d88afb7b' -Arguments @{ join = "$($output -join '; ')" }))
    }
    # See https://yuruna.link/42e5cdfd-0011
    $startExitCode = $LASTEXITCODE
    [void](Start-VMDhcpCapture -VMName $VMName)
    if ($null -ne $startExitCode) { $global:LASTEXITCODE = $startExitCode }
    return @{ success = $true; errorMessage = $null }
}

# --- REGION: Stop-VM
function Stop-VM {
    <#
    .SYNOPSIS
        Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force,
        # Bounds the poll after the ACPI request; 0 keeps the 30 s default.
        [int]$ShutdownTimeoutSeconds = 0,
        # Accepted for contract parity: this driver never escalates on its own.
        [switch]$NoForce
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? (Format-YurunaOperatorMessage -Key 'host.operator_872a5355019f83c5') : (Format-YurunaOperatorMessage -Key 'host.operator_156e139837bd477d')))) { return $false }
    if ($NoForce) { Write-Verbose 'Stop-VM: -NoForce is the default on KVM; the ACPI request is never escalated here.' }
    $state = Get-KvmDomainState -VMName $VMName
    if ($state.State -eq 'absent' -or $state.Raw -in @('shut off', 'crashed')) { return $true }
    if ($state.State -eq 'unknown') { return $false }
    if ($Force) { return [bool](Stop-VMForce -VMName $VMName -Confirm:$false) }
    Invoke-Virsh -VirshArgs @('shutdown', $VMName) | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    # virsh shutdown is asynchronous (ACPI shutdown signal); poll up to ~30s
    # for the OS to follow through.
    $deadline = (Get-Date).AddSeconds($(if ($ShutdownTimeoutSeconds -gt 0) { $ShutdownTimeoutSeconds } else { 30 }))
    while ((Get-Date) -lt $deadline) {
        $state = Get-KvmDomainState -VMName $VMName
        if ($state.State -eq 'absent' -or $state.Raw -in @('shut off', 'crashed')) { return $true }
        if ($state.State -eq 'unknown') { return $false }
        Start-Sleep -Seconds 1
    }
    return $false
}

<#
.SYNOPSIS
    Read a process's argv from the process table, telling a vanished process
    apart from one whose command line could not be read.
.DESCRIPTION
    State is 'gone' when the process directory does not exist, 'unreadable'
    when it exists but its cmdline could not be read, and 'present' otherwise.
    A present process with an empty argv is a zombie or kernel thread, which
    holds no guest.
.OUTPUTS
    [pscustomobject] @{ State; Argv }
#>
function Get-KvmProcessCommandLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][int]$ProcessId)
    $procDir = Join-Path $script:KvmProcRoot "$ProcessId"
    if (-not [IO.Directory]::Exists($procDir)) {
        return [pscustomobject]@{ State = 'gone'; Argv = [string[]]@() }
    }
    $bytes = $null
    try {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $procDir 'cmdline'))
    } catch [System.IO.DirectoryNotFoundException], [System.IO.FileNotFoundException] {
        return [pscustomobject]@{ State = 'gone'; Argv = [string[]]@() }
    } catch {
        Write-Verbose "Get-KvmProcessCommandLine: cmdline of $ProcessId unreadable: $($_.Exception.Message)"
        return [pscustomobject]@{ State = 'unreadable'; Argv = [string[]]@() }
    }
    $argv = [System.Collections.Generic.List[string]]::new()
    foreach ($part in ([Text.Encoding]::UTF8.GetString($bytes)).Split([char]0)) { [void]$argv.Add($part) }
    while ($argv.Count -gt 0 -and $argv[$argv.Count - 1] -eq '') { $argv.RemoveAt($argv.Count - 1) }
    return [pscustomobject]@{ State = 'present'; Argv = [string[]]$argv.ToArray() }
}

<#
.SYNOPSIS
    Decide whether a process id is the qemu process of a given libvirt domain.
.DESCRIPTION
    A pidfile can outlive its process, and a process id can be reused by an
    unrelated process in the meantime, so the id alone never justifies a kill.
    Identity 'match' requires argv[0]'s leaf to be qemu-system-* or qemu-kvm
    and one argument to carry the domain name the way libvirt passes it with
    -name: 'guest=<name>' alone or followed by ',<options>', where a comma
    inside the name is doubled. 'mismatch' is a live process that is something
    else, 'gone' a process that no longer exists (or holds no command line),
    and 'unknown' a command line that could not be read.
.OUTPUTS
    [pscustomobject] @{ Identity; ProcessId }
#>
function Get-KvmQemuProcessIdentity {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$VMName
    )
    $read = Get-KvmProcessCommandLine -ProcessId $ProcessId
    $identity = switch ($read.State) {
        'gone'       { 'gone' }
        'unreadable' { 'unknown' }
        default {
            $argv = @($read.Argv)
            if ($argv.Count -eq 0) { 'gone'; break }
            $leaf = [IO.Path]::GetFileName([string]$argv[0])
            if ($leaf -notmatch '^qemu-system-' -and $leaf -ne 'qemu-kvm') { 'mismatch'; break }
            $named = $false
            foreach ($argument in $argv) {
                $m = [regex]::Match([string]$argument, '^guest=(?<name>(?:[^,]|,,)*)(?:,(?!,)|$)')
                if ($m.Success -and ($m.Groups['name'].Value -replace ',,', ',') -ceq $VMName) { $named = $true; break }
            }
            if ($named) { 'match' } else { 'mismatch' }
        }
    }
    return [pscustomobject]@{ Identity = [string]$identity; ProcessId = $ProcessId }
}

<#
.SYNOPSIS
    $true when a bounded state read positively shows the domain gone or powered
    off ('absent', or a raw libvirt state of 'shut off' or 'crashed').
.DESCRIPTION
    Returns $false without launching anything when less than one second of
    the deadline remains.
#>
function Test-KvmDomainPoweredOff {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)]$Deadline
    )
    $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling $script:VirshQueryTimeoutSeconds
    if ($null -eq $cap) { return $false }
    $read = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $cap
    return ($read.State -eq 'absent' -or $read.Raw -in @('shut off', 'crashed'))
}

# --- REGION: Stop-VMForce
function Stop-VMForce {
    <#
    .SYNOPSIS
        Force-stop a guest VM via virsh destroy, escalating to a verified qemu
        process kill when libvirtd cannot destroy it.
    .DESCRIPTION
        StopTimeoutSeconds bounds the whole call. The destroy gets two thirds of
        it; the state reads, the escalation and the wait for the process to go
        share the rest, and each native call is capped by what remains, so a
        wedged libvirtd costs at most the budget rather than an unbounded wait.

        Escalation reads the domain's qemu process id from libvirt's pidfile and
        signals it only after revalidating, immediately before the signal, that
        the id still names that domain's qemu process: a stale pidfile or a reused
        id must never kill an unrelated process. The signal goes through
        `sudo -n /bin/kill -9`, which fails at once instead of waiting on a
        password prompt nobody can answer; a refusal is reported with the exact
        remedy. The absolute /bin/kill path keeps the call away from PowerShell's
        own kill alias.

        Success means libvirt reports the domain absent, 'shut off' or 'crashed',
        or the verified process no longer exists -- the latter proves the guest is
        down even while libvirtd itself is too wedged to say so.
    .PARAMETER StopTimeoutSeconds
        Wall-clock budget for the whole call.
    .OUTPUTS
        [bool] $true when the domain is positively stopped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(1, 600)][int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_44b8aa9af404e9b3'))) { return $false }
    $deadline = New-YurunaDeadline -TotalMilliseconds ([long]$StopTimeoutSeconds * 1000)
    $destroyCap = [Math]::Max(1, [int][Math]::Floor($StopTimeoutSeconds * 2 / 3))
    $destroy = Invoke-VirshBounded -VirshArgs @('destroy', $VMName) -TimeoutSeconds $destroyCap
    if ($destroy.Started -and -not $destroy.TimedOut -and $destroy.ExitCode -eq 0) { return $true }
    if (Test-KvmDomainPoweredOff -VMName $VMName -Deadline $deadline) { return $true }

    # Last-resort escalation through libvirt's own pidfile for the domain. A
    # name that is not a plain file-name component cannot name a pidfile here.
    $pidLeaf = "$VMName.pid"
    if ([IO.Path]::GetFileName($pidLeaf) -ne $pidLeaf) { return $false }
    $pidFile = Join-Path $script:KvmQemuRunDir $pidLeaf
    if (-not [IO.File]::Exists($pidFile)) { return $false }
    $pidText = $null
    try {
        $pidText = [IO.File]::ReadAllText($pidFile)
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_30ca216f8c140b13' -Arguments @{ pidFile = "$pidFile"; message = "$($_.Exception.Message)" })
        return $false
    }
    $qpid = 0
    if (-not [int]::TryParse("$pidText".Trim(), [ref]$qpid) -or $qpid -le 1 -or $qpid -eq $PID) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_force_stop_pidfile_invalid' -Arguments @{ pidFile = "$pidFile" })
        return $false
    }
    $killCap = Get-YurunaDeadlineBoundedSeconds -Deadline $deadline -Ceiling 60
    if ($null -eq $killCap) {
        Write-Verbose "Stop-VMForce: no time left to signal qemu process $qpid of '$VMName'."
        return $false
    }
    # Revalidated here, after the destroy and the state read, because those can
    # take seconds -- long enough for the process to exit and its id to be reused.
    $identity = Get-KvmQemuProcessIdentity -ProcessId $qpid -VMName $VMName
    if ($identity.Identity -eq 'gone') {
        Write-Verbose "Stop-VMForce: process $qpid from '$pidFile' is already gone; libvirt has not confirmed '$VMName' stopped."
        return $false
    }
    if ($identity.Identity -ne 'match') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_force_stop_pid_unverified' -Arguments @{ processId = "$qpid"; pidFile = "$pidFile"; vMName = "$VMName" })
        return $false
    }
    $kill = Invoke-BoundedNativeCommand -FilePath 'sudo' -ArgumentList @('-n', '/bin/kill', '-9', "$qpid") -TimeoutSeconds $killCap
    if (-not $kill.Started) {
        Write-Verbose "Stop-VMForce: sudo could not be launched to signal qemu process $qpid."
        return $false
    }
    if (-not $kill.TimedOut -and $kill.ExitCode -ne 0) {
        if (Test-YurunaSudoRefusal -Output "$($kill.StdOut)`n$($kill.StdErr)") {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_force_stop_signal_refused' -Arguments @{ processId = "$qpid"; vMName = "$VMName" })
            return $false
        }
        # Anything else (typically "No such process") is settled by the
        # postcondition below rather than by the exit code.
        Write-Verbose "Stop-VMForce: kill of $qpid exited $($kill.ExitCode)."
    }
    while ($true) {
        $after = Get-KvmQemuProcessIdentity -ProcessId $qpid -VMName $VMName
        if ($after.Identity -in @('gone', 'mismatch')) { return $true }
        if (Test-KvmDomainPoweredOff -VMName $VMName -Deadline $deadline) { return $true }
        $remaining = Get-YurunaDeadlineRemainingMs -Deadline $deadline
        if ($remaining -le 0) { return $false }
        Start-Sleep -Milliseconds ([int][Math]::Min(1000, $remaining))
    }
}

# --- REGION: Remove-VM
function Remove-VM {
    <#
    .SYNOPSIS
        Remove a guest VM and its on-disk artifacts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_12924e738438f274'))) { return $false }

    # Discard only a window this VM owns: the cycle-start sweep removes
    # leftover VMs by prefix, and an unowned discard there would throw away the
    # evidence just armed for the guest actually under test. A failure path
    # saves (and clears) the window before removal, so this fires only on the
    # teardown that had nothing to explain.
    if ($script:YurunaDhcpCapture -and $script:YurunaDhcpCapture.VMName -eq $VMName) {
        [void](Stop-VMDhcpCapture -Reason "discarded when '$VMName' was removed")
    }

    # Force-stop first; ignore errors (VM may be absent or already stopped).
    Invoke-Virsh -VirshArgs @('destroy', $VMName) | Out-Null

    # --- REGION: https://yuruna.link/42d69dfa-001e
    # See https://yuruna.link/42e5cdfd-0012
    $undefineArgs = @('undefine', '--nvram', '--managed-save',
                      '--snapshots-metadata', '--checkpoints-metadata', $VMName)
    $undefineOut = Invoke-Virsh -VirshArgs $undefineArgs
    # --- REGION: https://yuruna.link/42e220c4-0004
    # Undefine can succeed while a failed stop leaves an active transient domain.
    # Only a successful full inventory proving absence permits disk deletion.
    try {
        $domainNames = @(Get-VMName)
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b63de47809d76147' -Arguments @{ vMName = "$VMName"; message = "$($_.Exception.Message)" })
        return $false
    }
    $undefined = ($domainNames -cnotcontains $VMName)
    if (-not $undefined) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_94ae6ac85570e806' -Arguments @{ vMName = "$VMName"; join = "$($undefineOut -join '; ')" })
    }

    # See https://yuruna.link/42e5cdfd-0012
    $filesRemoved = $true
    $vmDir = Join-Path $script:VmRootDir $VMName
    if ($undefined -and (Test-Path -LiteralPath $vmDir)) {
        $filesRemoved = Test-KvmDirectoryFreeToDelete -Directory $vmDir
    }
    if ($undefined -and $filesRemoved -and (Test-Path -LiteralPath $vmDir)) {
        try { Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction Stop }
        catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_235282ccbea4652f' -Arguments @{ vmDir = "$vmDir"; message = "$($_.Exception.Message)" })
            $filesRemoved = $false
        }
    }
    return ($undefined -and $filesRemoved)
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.Storage.ps1')

# --- REGION: Rename-VM
function Rename-VM {
    <#
    .SYNOPSIS
        Rename a stopped libvirt domain and relocate its on-disk artifacts.
    .DESCRIPTION
        libvirt 1.2.19+ ships `virsh domrename` which mutates the domain
        name atomically in the registry; that's the fast path. We follow up
        by renaming the per-VM artifact directory (~/yuruna/vms/<old> ->
        ~/yuruna/vms/<new>) and rewriting the XML's <disk source file=...>
        paths to point at the new dir, then re-defining the domain so the
        new XML is canonical. Without the dir+XML rewrite the qcow2 still
        lives under the old path and the next cycle's
        Remove-OrphanedVMFiles.ps1 would reclaim it on the
        "directory-named-after-an-absent-VM" heuristic.

        The same rewrite moves the NIC address, but only for a domain still
        sitting on the address the OLD name derives: that one belongs to the
        name being vacated, and the next build under it is refused outright
        while a domain still holds it. A domain on any other address was
        pinned at build time to the identity its guest keeps for life and is
        left alone -- see Set-GuestMacInDomainXml.

        Requires the domain to be positively powered off (virsh domstate
        'shut off') and the destination name positively absent; the caller
        (Save-VMDiskSnapshot) handles the stop. Returns $false on any sub-step
        failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_e9e1683d4b60f469' -Arguments @{ newName = "$NewName" }))) { return $false }
    if ($VMName -eq $NewName) { return $true }
    # See https://yuruna.link/42e220c4-0004
    $source = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if ($source.State -eq 'absent') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0ef104304974ce38' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    if ($source.State -ne 'stopped' -or $source.Raw -ne 'shut off') {
        $sourceWord = if ($source.Raw) { [string]$source.Raw } else { [string]$source.State }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_rename_source_not_stopped' -Arguments @{ vMName = "$VMName"; state = "$sourceWord" })
        return $false
    }
    if ((Get-VMState -VMName $NewName) -ne 'absent') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f69adb6b2f614a13' -Arguments @{ newName = "$NewName" })
        return $false
    }
    # Checked before the first mutation: a rename that fails after domrename
    # leaves the domain with its disks under the old name.
    $destinationDir = Join-Path $script:VmRootDir $NewName
    if (Test-Path -LiteralPath $destinationDir) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_rename_destination_dir_exists' -Arguments @{ newName = "$NewName"; newDir = "$destinationDir" })
        return $false
    }
    # virsh domrename is libvirt >= 1.2.19; ubuntu 18.04+ has it. We do
    # not implement the older dumpxml/undefine/define fallback because
    # the supported KVM baseline (ubuntu.server.24/26) ships >= 9.x.
    Invoke-Virsh -VirshArgs @('domrename', $VMName, $NewName) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c041d9cc53c27c36' -Arguments @{ vMName = "$VMName"; newName = "$NewName" })
        return $false
    }
    return (Complete-KvmDomainRename -VMName $VMName -NewName $NewName -Confirm:$false)
}

<#
.SYNOPSIS
    Return $DomainXml with its first NIC address set to the deterministic
    MAC for $VMName. Input is returned unchanged when there is no NIC.
.DESCRIPTION
    See https://yuruna.link/4220a755-000a
    for the address itself. A domain is normally pinned at BUILD time to the
    identity its guest keeps for life, and then this rewrite is never needed.
    It exists for the domain that was pinned to the per-kind slot name instead
    (a guest whose sequence declares no hostname of its own): that address
    belongs to the slot, and a promoted domain sitting on it makes the NEXT
    build of the slot ask for an address already in use. Two domains holding
    one MAC is not a slow leak like the random-address churn this scheme
    replaced: virt-install refuses the second build outright ("in use by
    another virtual machine"), and a hypervisor that does not refuse puts two
    live NICs with one address on the same segment.

    The caller decides whether the rewrite applies -- see Rename-VM, which asks
    Get-GuestMacFromDomainXml what the NIC currently holds first. Moving a
    domain that is already on its own identity re-DHCPs a running guest whose
    state may record the address it was built on. -MacAddress writes a given
    address instead of the one $VMName derives: a rename that undoes an earlier
    one restores the address the domain had under its old name.

    Only the first <mac address=.../> is rewritten. A domain with a second
    interface needs a second DISTINCT address, and giving it this one twice
    would recreate on one guest exactly what the rewrite exists to prevent.
#>
function Set-GuestMacInDomainXml {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns rewritten XML; nothing is changed until the caller defines it.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$DomainXml,
        [Parameter(Mandatory)][string]$VMName,
        [string]$MacAddress = ''
    )
    if ([string]::IsNullOrEmpty($DomainXml)) { return $DomainXml }
    # libvirt writes the address lowercase in dumpxml; match its casing so an
    # unchanged domain compares equal and no needless redefine is attempted.
    $mac = if ($MacAddress) { $MacAddress.ToLowerInvariant() } else { (Get-YurunaGuestMacAddress -VMName $VMName).ToLowerInvariant() }
    return ([regex]"(?<=<mac address=')[0-9A-Fa-f:]{17}(?=')").Replace($DomainXml, $mac, 1)
}

<#
.SYNOPSIS
    The address on the first NIC in $DomainXml, or '' when there is none.
.DESCRIPTION
    The read half of Set-GuestMacInDomainXml, matching the same first
    <mac address=.../> that rewrite would target, so a caller comparing before
    writing is comparing the value it is about to replace.
.OUTPUTS
    [string] the address as libvirt wrote it, or '' when the domain has no NIC.
#>
function Get-GuestMacFromDomainXml {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DomainXml)
    if ([string]::IsNullOrEmpty($DomainXml)) { return '' }
    $m = [regex]::Match($DomainXml, "(?<=<mac address=')[0-9A-Fa-f:]{17}(?=')")
    if (-not $m.Success) { return '' }
    return $m.Value
}

# --- REGION: Get-VMState
function Get-VMState {
    <#
    .SYNOPSIS
        Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
    .DESCRIPTION
        A bounded read through Get-KvmDomainState, capped at
        $script:VirshQueryTimeoutSeconds, so a wedged libvirtd answers 'unknown'
        instead of holding the caller. Only a completed response naming the domain
        as not found is 'absent': a missing client, a timeout, truncated output,
        denied permission or any unrecognized failure is 'unknown'. That precedence
        matters because callers (Restore-YurunaServiceVM among them) treat 'absent'
        as permission to build or reuse a name, and a provider fault read that way
        would rebuild over a VM that still exists.

        Get-VirshDomState keeps its raw-passthrough-or-empty contract for the call
        sites and mocks that depend on it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    return [string](Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds).State
}

<#
.SYNOPSIS
    One bounded libvirt domain-state read, with the reason behind the answer.
.DESCRIPTION
    Precedence, first match wins:
      1. No launchable virsh, a timeout, or output that was not fully drained
         or was truncated -> 'unknown'. None of these is an answer.
      2. A nonzero exit whose text is a connection, permission or policy
         failure -> 'unknown': libvirt never got to look the domain up.
      3. A nonzero exit whose text says the domain lookup failed -> 'absent'.
         virsh reports a missing domain as "failed to get domain" (or "domain
         not found" / "no domain with") once it is connected and authorized.
      4. Any other nonzero exit -> 'unknown'.
      5. Exit 0 -> the first non-empty line mapped to running/stopped, and an
         empty or unrecognized line -> 'unknown'.
    'absent' is what callers read as permission to build or reuse a name, so it
    is produced only by a completed, recognized not-found answer.
.OUTPUTS
    [pscustomobject] @{ State = running|stopped|absent|unknown; Raw; Reason }
    Raw is the first libvirt state line ('' when none). Reason is one of
    observed, not-found, missing-client, timeout, invalid-response,
    permission-denied, provider-error.
#>
function Get-KvmDomainState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 20
    )
    $emit = {
        param([string]$State, [string]$Raw, [string]$Reason)
        [pscustomobject]@{ State = $State; Raw = $Raw; Reason = $Reason }
    }
    $result = Invoke-VirshBounded -VirshArgs @('domstate', $VMName) -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Started) { return (& $emit 'unknown' '' 'missing-client') }
    if ($result.TimedOut) { return (& $emit 'unknown' '' 'timeout') }
    if (-not (Test-DriverNativeResultComplete -Result $result)) { return (& $emit 'unknown' '' 'invalid-response') }
    if ($result.ExitCode -ne 0) {
        $text = "$($result.StdOut)`n$($result.StdErr)"
        if ($text -match '(?i)permission denied|authentication (failed|unavailable)|access denied|not authorized|polkit') {
            return (& $emit 'unknown' '' 'permission-denied')
        }
        if ($text -match '(?i)failed to connect') { return (& $emit 'unknown' '' 'provider-error') }
        if ($text -match 'failed to get domain|domain not found|no domain with') { return (& $emit 'absent' '' 'not-found') }
        return (& $emit 'unknown' '' 'provider-error')
    }
    $lines = @(Get-BoundedNativeOutputLine -Result $result)
    $raw = "$($lines | Where-Object { "$_".Trim() -ne '' } | Select-Object -First 1)".Trim()
    $state = switch -Regex ($raw) {
        '^running$'              { 'running'; break }
        '^(shut off|crashed)$'   { 'stopped'; break }
        '^(paused|in shutdown)$' { 'stopped'; break }
        '^(idle|pmsuspended)$'   { 'stopped'; break }
        default                  { 'unknown' }
    }
    $reason = if ($state -eq 'unknown') { 'invalid-response' } else { 'observed' }
    return (& $emit $state $raw $reason)
}

# --- REGION: VM inventory
# --- REGION: Get-VMName
function Get-VMName {
    <#
    .SYNOPSIS
        Return the names of every defined libvirt domain, optionally filtered
        to those starting with one of $Prefix.
    .DESCRIPTION
        Host-neutral inventory call (see the contract's VM inventory block).
        `list --all` covers running, paused and shut-off domains, so a caller
        sweeping by prefix removes stopped leftovers as well as running ones.

        THROWS when virsh cannot be reached rather than returning an empty
        list: a missing binary, a stopped libvirtd, or a shell whose group set
        lacks libvirt all fail the query, and a caller that read that as
        "nothing defined" would report a clean host and let the orphan-file
        pass delete storage still owned by a defined domain.
    .PARAMETER Prefix
        Zero or more name prefixes. A domain is returned when its name starts
        with any of them. Omit to return every domain.
    .OUTPUTS
        [string[]] matching domain names; empty when none match.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_6ce33651bd210b55')
    }
    $output = Invoke-Virsh -VirshArgs @('list', '--all', '--name')
    if ($LASTEXITCODE -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_a6a18006853361cb' -Arguments @{ join = "$($output -join '; ')" })
    }
    # `--name` prints one name per line and a trailing blank line; the
    # blank entries are dropped by the shared prefix filter.
    $all = @($output | ForEach-Object { "$_".Trim() })
    return Select-NameByPrefix -Name $all -Prefix $Prefix
}

# --- REGION: Disk snapshots
# --- REGION: Save-VMDiskSnapshot
function Save-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Save a disk-only snapshot of the VM as the persisted VM named $Id,
        through the shared transactional save (Invoke-YurunaDiskSnapshotSave).
    .DESCRIPTION
        The shared save renames the VM to $Id before the snapshot, which KVM
        requires: libvirt freezes a full copy of the domain XML inside the
        snapshot metadata, and neither `virsh domrename` nor a later `virsh
        define` rewrites that frozen copy. A snapshot taken under the old name
        keeps the old <name> and <disk source file=...> paths, and a later
        `snapshot-revert` tries to reinstate disks the rename already moved,
        failing with "An error occurred, but the cause is unknown".

        Rename-VM moves ~/yuruna/vms/<old> to .../<Id> and rewrites the disk
        sources, so the next cycle's Remove-TestVMFiles.ps1 leaves the
        persisted domain alone. The snapshot itself is `virsh
        snapshot-create-as --atomic` against the offline domain: with the guest
        stopped there is no runtime state, so it is a disk-level point, and
        --atomic rolls back a partially created snapshot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_cf6c53f788458edb' -Arguments @{ id = "$Id" }))) { return $false }
    return [bool](Invoke-YurunaDiskSnapshotSave -VMName $VMName -Id $Id -Confirm:$false -Primitive @{
        State         = { param($Name) Get-VMState -VMName $Name }
        SnapshotState = { param($Name, $SnapshotId) Get-VMDiskSnapshotState -VMName $Name -Id $SnapshotId }
        Stop          = { param($Name) Stop-KvmVMForSnapshot -VMName $Name }
        Rename        = { param($Name, $NewName) Rename-VM -VMName $Name -NewName $NewName -Confirm:$false }
        Remove        = { param($Name) Remove-VM -VMName $Name -Confirm:$false }
        Snapshot      = { param($Name, $SnapshotId) New-KvmDiskSnapshot -VMName $Name -Id $SnapshotId }
    })
}

<#
.SYNOPSIS
    Stop a domain for a snapshot and confirm libvirt reports it 'shut off'.
.DESCRIPTION
    Normalized stopped states (paused, in shutdown, crashed) can still hold
    QEMU and its disk locks, so only the raw 'shut off' counts.
    See https://yuruna.link/42e220c4-0004
#>
function Stop-KvmVMForSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param([Parameter(Mandatory)][string]$VMName)
    $state = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if ($state.State -in @('absent', 'unknown')) { return $false }
    if ($state.Raw -eq 'shut off') { return $true }
    if (-not (Stop-VM -VMName $VMName)) {
        if (-not (Stop-VMForce -VMName $VMName)) { return $false }
    }
    $state = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    return ($state.State -eq 'stopped' -and $state.Raw -eq 'shut off')
}

<#
.SYNOPSIS
    Create libvirt snapshot $Id on the stopped domain $VMName, replacing one of
    the same name.
#>
function New-KvmDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    # A missing snapshot of that name is the common case, so a failed delete
    # is ignored; the create below is what must succeed.
    $null = Invoke-Virsh -VirshArgs @('snapshot-delete', $VMName, '--snapshotname', $Id) -TimeoutSeconds $script:VirshSnapshotTimeoutSeconds
    $out = Invoke-Virsh -VirshArgs @('snapshot-create-as', '--domain', $VMName, '--name', $Id, '--atomic') -TimeoutSeconds $script:VirshSnapshotTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d055b300ffe84fec' -Arguments @{ id = "$Id"; join = "$($out -join '; ')" })
        return $false
    }
    return $true
}

# --- REGION: Restore-VMDiskSnapshot
function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Revert $VMName to libvirt snapshot $Id via `virsh snapshot-revert`.
    .DESCRIPTION
        Verifies the snapshot exists with `snapshot-info` first so a
        typo'd Id does not bounce a healthy guest, force-stops any active
        domain, then confirms it is powered off before `snapshot-revert`.
        Returns the virsh exit status as a bool so callers can branch on success.
    .OUTPUTS
        [bool] $true on success; $false on missing snapshot, unconfirmed
        power-off or virsh failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_122c73a3a2052796' -Arguments @{ id = "$Id" }))) { return $false }
    # Verify the snapshot exists before stopping the VM, so a typo'd Id
    # doesn't bounce a healthy guest for nothing.
    Invoke-Virsh -VirshArgs @('snapshot-info', '--domain', $VMName, '--snapshotname', $Id) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_22ea2e011669030a' -Arguments @{ id = "$Id"; vMName = "$VMName" })
        return $false
    }
    $state = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if ($state.State -in @('absent', 'unknown')) { return $false }
    # Rollback discards the current guest's disk contents, so waiting for a
    # graceful flush adds latency without preserving any data. Snapshot saves
    # retain their graceful shutdown policy. Use the raw state here: paused,
    # in-shutdown and crashed domains can still retain QEMU and hold the disk.
    if ($state.Raw -ne 'shut off') {
        if (-not (Stop-VMForce -VMName $VMName -Confirm:$false)) { return $false }
        $state = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
        if ($state.Raw -ne 'shut off') { return $false }
    }
    $out = Invoke-Virsh -VirshArgs @('snapshot-revert', '--domain', $VMName, '--snapshotname', $Id) -TimeoutSeconds $script:VirshSnapshotTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1bf94e57cf95ae30' -Arguments @{ vMName = "$VMName"; id = "$Id"; join = "$($out -join '; ')" })
        return $false
    }
    return $true
}

# --- REGION: Get-VMDiskSnapshotState
function Get-VMDiskSnapshotState {
    <#
    .SYNOPSIS
        Whether snapshot $Id exists on $VMName: 'present', 'absent', or
        'unknown' when the hypervisor could not answer.
    .DESCRIPTION
        A probe that cannot answer is not an absence: read as one, it rebuilds a
        baseline over a snapshot that may exist, or skips a restore that would
        have worked. Only a VM that does not exist, or an answer that lists no
        such snapshot, is 'absent'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if ((Get-VMState -VMName $VMName) -eq 'absent') { return 'absent' }
    # The list, not snapshot-info's error text: libvirt localizes its messages,
    # and only the list says "no such snapshot" in a form that does not vary.
    $names = @(Invoke-Virsh -VirshArgs @('snapshot-list', '--domain', $VMName, '--name') 2>$null)
    if ($LASTEXITCODE -ne 0) { return 'unknown' }
    if (@($names | ForEach-Object { ([string]$_).Trim() }) -ccontains $Id) { return 'present' }
    return 'absent'
}

# --- REGION: Test-VMDiskSnapshot
function Test-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Returns $true when snapshot $Id is present on $VMName, $false when it
        is absent (including when the domain does not exist), and throws when
        libvirt could not answer. Used by Debug-TestSequence.ps1's
        requiresSnapshot warm-path probe before deciding whether to walk the
        baseline chain.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    $state = Get-VMDiskSnapshotState -VMName $VMName -Id $Id
    # A probe that could not answer throws, so a caller's indeterminate branch
    # runs instead of reading the blip as a missing snapshot.
    if ($state -eq 'unknown') { throw (Format-YurunaOperatorMessage -Key 'host.snapshot_state_unknown' -Arguments @{ id = "$Id"; vMName = "$VMName" }) }
    return ($state -eq 'present')
}

# --- REGION: VM console
# --- REGION: Test-VMConsoleOpen
function Test-VMConsoleOpen {
    <#
    .SYNOPSIS
        Returns true when a console window is open for the given VM.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    # virt-viewer / remote-viewer are the canonical console clients on
    # Linux. pgrep -f matches the VMName argument that virt-viewer
    # carries on its command line.
    if (-not (Get-Command pgrep -ErrorAction SilentlyContinue)) { return $false }
    $hits = & pgrep -f "(virt-viewer|remote-viewer).*$([regex]::Escape($VMName))" 2>$null
    return ($LASTEXITCODE -eq 0 -and "$hits".Trim() -ne '')
}

# --- REGION: Restart-VMConsole
function Restart-VMConsole {
    <#
    .SYNOPSIS
        Refresh or re-open the host-side console window for the given VM.
    .DESCRIPTION
        Mirrors the Hyper-V `Restart-HyperVConnect` behavior: kill any
        existing viewer for THIS VM, then launch a fresh one. The operator
        sees a console window for every guest under test, same as on
        Hyper-V's vmconnect and on macOS UTM's display window.

        Detachment: a naive `Start-Process virt-viewer` inherits the parent
        pwsh's stdout/stderr FDs, so the test harness's upstream
        `ForEach-Object` pipe never EOFs after the sequence parent exits and
        the harness hangs indefinitely after "Sequence complete." We invoke
        virt-viewer through `setsid -f` with </dev/null >/dev/null 2>&1 so
        the child runs in its own session with no inherited stdio FDs --
        closing the harness's pipe behaves the same as on the other hosts.

        GDK_BACKEND=x11: forces virt-viewer (a GTK app) to use the X11
        backend even on Wayland sessions, so it goes through XWayland and
        grabs the keyboard via the legacy XGrabKeyboard API instead of the
        Wayland xdg-desktop-portal Inhibit interface. The portal path
        triggers GNOME's "Allow inhibiting shortcuts? [Allow] [Deny]" modal
        on every fresh viewer launch -- which would block the test runner
        every cycle. XWayland keyboard grab is silent, has no side effects
        on the rest of the desktop session, and the per-process env var
        leaves other GTK apps on the host untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_71b92b0d0881c6c9'))) { return $false }
    if (-not (Get-Command virt-viewer -ErrorAction SilentlyContinue)) {
        Write-Verbose "Restart-VMConsole: virt-viewer not installed; skipping."
        return $false
    }
    & pkill -f "virt-viewer.*$([regex]::Escape($VMName))" 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    & bash -c "setsid -f env GDK_BACKEND=x11 virt-viewer --connect '$($script:VirshUri)' '$VMName' </dev/null >/dev/null 2>&1" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    # setsid acknowledges its fork before the viewer runs. A successful
    # launcher alone therefore cannot prove that the console client exists.
    for ($probe = 0; $probe -lt 20; $probe++) {
        Start-Sleep -Milliseconds 250
        if (Test-VMConsoleOpen -VMName $VMName) {
            Write-Verbose "    Reconnected virt-viewer for '$VMName'"
            return $true
        }
    }
    return $false
}

# --- REGION: Image
# --- REGION: Get-Image
function Get-Image {
    <#
    .SYNOPSIS
        Run the per-guest Get-Image.ps1 to download or refresh the base image.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-GetImage, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    # See https://yuruna.link/42e220c4-0004
    Invoke-GetImage -HostSubdir 'host/ubuntu.kvm' -ResolveImagePath (Get-Command Get-ImagePath) -WriteLine (Get-Command Write-Information) @PSBoundParameters
}

# --- REGION: Get-ImagePath
function Get-ImagePath {
    <#
    .SYNOPSIS
        Return the expected on-disk path of the base image for a guest.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    return $script:ImagePathTable[$GuestKey]
}

# --- REGION: VM I/O
# --- REGION: Send-Text
function Send-Text {
    <#
    .SYNOPSIS
        Type text into the guest VM via gui or ssh mechanism.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Text,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui',
        # Required when -Mechanism ssh: maps to the SSH login user via
        # Test.Ssh\Get-GuestSshUser (per-guest test user, ec2-user, root, ...).
        [string]$GuestKey,
        [int]$CharDelayMs = 10,
        [switch]$Sensitive
    )
    # Sensitive is part of the contract for log redaction; current paths
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honor it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on KVM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f4a1977247ebda51')
            return $false
        }
        # Test.Ssh\Invoke-GuestSsh resolves both the user (from GuestKey)
        # and the address (from VMName) internally; surface .success, not the
        # hashtable itself -- [bool] of a non-null hashtable is always $true
        # (truthy-hashtable trap).
        $r = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey -Command $Text
        return [bool]$r.success
    }
    # GUI: defer to Invoke-Sequence's host-aware dispatcher (same pattern
    # as the macOS impl). Sequence-driven runs go through there; manual
    # Send-Text calls should usually use -Mechanism ssh on Linux guests.
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # See https://yuruna.link/42e220c4-0004
        if (-not (Get-Command 'Test.SequenceEngine\Send-Text' -ErrorAction SilentlyContinue)) {
            Import-Module $sequenceEngine -Force -DisableNameChecking -Global
        }
        return [bool](Test.SequenceEngine\Send-Text -HostType (Resolve-HostTag) -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1e2f99261b1a1683' -Arguments @{ sequenceEngine = "$sequenceEngine" })
    return $false
}

# --- REGION: Send-Key
function Send-Key {
    <#
    .SYNOPSIS
        Send a named key to the guest VM via gui or ssh mechanism.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4ffbf7056dde8493')
        return $false
    }
    # See https://yuruna.link/42e220c4-0004
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import only when the dispatcher isn't already resolvable: a -Force
        # import evicts the global Invoke-Sequence (and its nested modules)
        # the outer loop still calls.
        if (-not (Get-Command 'Test.SequenceEngine\Send-Key' -ErrorAction SilentlyContinue)) {
            Import-Module $sequenceEngine -Force -DisableNameChecking -Global
        }
        return [bool](Test.SequenceEngine\Send-Key -HostType (Resolve-HostTag) -VMName $VMName -KeyName $Key)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c53432cf9b294e69' -Arguments @{ sequenceEngine = "$sequenceEngine" })
    return $false
}

# --- REGION: Send-Click
function Send-Click {
    <#
    .SYNOPSIS
        Send a mouse click at the given pixel coordinate.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_00de7e0959068c8c' -Arguments @{ vMName = "$VMName"; x = "$X"; y = "$Y" })
    return $false
}

# --- REGION: Get-VMScreenshot
function Get-VMScreenshot {
    <#
    .SYNOPSIS
        Capture a PNG of the VM display from frame or window source.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    # KVM only exposes the guest framebuffer (virsh screenshot); the
    # window-vs-frame distinction maps to the same op here. Document the
    # collapse in the debug stream so a 'window' caller can see why it
    # got a frame.
    if ($Source -eq 'window') {
        Write-Debug "Get-VMScreenshot on host.ubuntu.kvm: -Source 'window' falls back to framebuffer capture."
    }
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    # virsh screenshot writes PPM by default; convert to PNG via
    # ImageMagick (`convert`) if available, else netpbm (`pamtopng`),
    # else write the PPM next to the requested .png path with a warning.
    # Both steps run inside the OCR poll loop, so each is bounded: a libvirtd
    # or a converter that stops answering costs one frame, not the whole cycle
    # to the step watchdog.
    $ppm = [System.IO.Path]::ChangeExtension($OutFile, '.ppm')
    $shot = Invoke-VirshBounded -VirshArgs @('screenshot', $VMName, $ppm) -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if (-not (Test-DriverNativeResultComplete -Result $shot) -or $shot.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $ppm)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ba1882e41aac59a1' -Arguments @{ vMName = "$VMName" })
        # A failed virsh call can still leave a partial PPM behind.
        Remove-Item -LiteralPath $ppm -Force -ErrorAction SilentlyContinue
        return $null
    }
    if (Get-Command convert -ErrorAction SilentlyContinue) {
        # Date/time chunks change even when every pixel is identical. Exclude
        # those volatile fields so OCR's exact-frame cache can reuse its answer;
        # retain color profiles, gamma and all image data.
        $converted = Invoke-BoundedNativeCommand -FilePath 'convert' -ArgumentList @($ppm, '-define', 'png:exclude-chunk=date,time', $OutFile) `
            -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    } elseif (Get-Command pamtopng -ErrorAction SilentlyContinue) {
        # pamtopng writes the PNG to stdout. The shell redirect keeps those
        # bytes binary, which a captured output stream would not.
        $converted = Invoke-BoundedNativeCommand -FilePath 'sh' -ArgumentList @('-c', 'exec pamtopng "$1" > "$2"', 'sh', $ppm, $OutFile) `
            -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_6d9c4686b08fcf2a' -Arguments @{ ppm = "$ppm" })
        return $ppm
    }
    # A converter stopped at its cap may have written part of a PNG; a partial
    # frame must never reach OCR as a whole one.
    if (-not (Test-DriverNativeResultComplete -Result $converted)) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $ppm -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutFile) { return $OutFile }
    return $null
}

# --- REGION: Get-VMConsoleHandle
function Get-VMConsoleHandle {
    <#
    .SYNOPSIS
        Return a host-specific handle for the VM console window.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Return the libvirt-managed qemu pid as a stable handle. Callers
    # use this only as an opaque identity check; not as something
    # they pass to a Win32 API.
    $pidFile = "/var/run/libvirt/qemu/$VMName.pid"
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $qpid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
            if ($qpid -gt 0) { return $qpid }
        } catch { Write-Debug $_ }
    }
    return $null
}

# --- REGION: Wait-KvmGuestIp
function Wait-KvmGuestIp {
    <#
    .SYNOPSIS
        Wait for a provisioned KVM guest address with disk-growth progress and source diagnostics.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$DiskPath,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 1200,
        [ValidateRange(1, 30)][int]$PollSeconds = 5
    )
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $baselineSizeMB = [math]::Round((Get-Item -LiteralPath $DiskPath).Length / 1MB, 0)
    $nextProgress = 30
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $address = Get-VMIp -VMName $VMName
        if ($address) { return $address }
        $remainingMs = [int][math]::Max(0, ($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000)
        if ($remainingMs -eq 0) { break }
        Start-Sleep -Milliseconds ([math]::Min($PollSeconds * 1000, $remainingMs))
        if ($clock.Elapsed.TotalSeconds -ge $nextProgress) {
            $elapsed = [int]$clock.Elapsed.TotalSeconds
            $sizeMB = [math]::Round((Get-Item -LiteralPath $DiskPath).Length / 1MB, 0)
            $min = [int][math]::Floor($elapsed / 60)
            $sec = $elapsed % 60
            $totalMinutes = [int][math]::Ceiling($TimeoutSeconds / 60)
            Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_ab6af692ee9143e8' -FormatValues ($min, $sec, $totalMinutes, $sizeMB, ($sizeMB - $baselineSizeMB)) -FormatBindings @{ min = '0:D2'; sec = '1:D2'; totalMinutes = '2'; sizeMB = '3'; deltaMB = '4' }) -InformationAction Continue
            $nextProgress += 30
        }
    }
    Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_c89f111266a03848') -InformationAction Continue
    foreach ($source in @('lease', 'agent', 'arp')) {
        $probe = (Invoke-Virsh -VirshArgs @('domifaddr', $VMName, '--source', $source) 2>&1 | Out-String).Trim()
        Write-Information -MessageData "--source ${source}: $probe" -InformationAction Continue
    }
    return $null
}

# --- REGION: Discovery
# --- REGION: Wait-VMIp
function Wait-VMIp {
    <#
    .SYNOPSIS
        Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3,
        # Forwarded so a caller can widen or waive the shared poller's settle
        # window; its default applies when this is not bound.
        [int]$StableForSeconds = 8
    )
    # Get-Command runs in THIS driver's scope, so the shared poller resolves
    # our Get-VMIp; a bare name would resolve in the shared module's scope.
    Invoke-WaitVmIp @PSBoundParameters -ResolveVmIp (Get-Command Get-VMIp)
}

<#
.SYNOPSIS
    Return this host's own IPv4 and its prefix length, or $null.
.DESCRIPTION
    The prefix bounds the neighbor sweep below. It is read rather than
    assumed because a sweep is only defensible on a /24: at /16 it is 65k
    probes against the operator's LAN, which is a scan, not a lookup.
.PARAMETER AddrLine
    Pre-captured `ip -o -4 addr show` text. The live command runs when this is
    not bound; supplying it keeps the parsing testable with no host state.
#>
function Get-HostIpv4Prefix {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$AddrLine)
    $hostIp = Get-BestHostIp
    if (-not $hostIp) { return $null }
    if (-not $PSBoundParameters.ContainsKey('AddrLine')) {
        $AddrLine = @(& ip -o -4 addr show 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
    }
    foreach ($line in @($AddrLine)) {
        if ($line -match '\binet\s+(\d+\.\d+\.\d+\.\d+)/(\d+)' -and $Matches[1] -eq $hostIp) {
            return @{
                Address = $hostIp
                Length  = [int]$Matches[2]
                Prefix  = ($hostIp -replace '\.\d+$', '')
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Pick the best address out of `virsh domifaddr` rows, or $null.
.DESCRIPTION
    Selection order matters as much as the parse. libvirt reports EVERY
    interface the source knows about, and on a Kubernetes node that includes
    the CNI bridge, the flannel overlay device and the docker bridge -- all of
    them routable-looking, none of them reachable from this host. Taking the
    first row would hand back 10.244.x or 172.17.0.1 and convert a loud
    resolution failure into a silent connect timeout, which is strictly worse
    to diagnose.

    So: rows whose MAC is the domain's own NIC win outright, then rows on this
    host's subnet, then first-match as the legacy behavior. v4 before v6
    throughout, because the port-map forwarders bind v4 sockets; v6 is returned
    only when no v4 exists, so a v6-only guest still resolves.
.PARAMETER Line
    `virsh domifaddr` output rows.
.PARAMETER Mac
    The domain's NIC MAC, lowercase colon-separated. Optional: when absent the
    MAC-affinity pass is skipped and the remaining preferences still apply.
.PARAMETER HostPrefix
    First three octets of this host's IPv4, e.g. '192.168.7'.
#>
function Select-VirshDomifaddrIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Line,
        [string]$Mac,
        [string]$HostPrefix
    )
    # See https://yuruna.link/42e220c4-0004
    $rows = @()
    $currentMac = ''
    foreach ($l in @($Line)) {
        if ($l -match '^\s*(\S+)\s+(\S+)\s+(ipv4|ipv6)\s+(\S+)/\d+') {
            $rowMac = $Matches[2]
            if ($rowMac -ne '-') { $currentMac = $rowMac.ToLowerInvariant() }
            $rows += @{
                Mac    = $currentMac
                Family = $Matches[3]
                Ip     = $Matches[4]
            }
        }
    }
    if (-not $rows.Count) { return $null }

    $wantMac = if ($Mac) { $Mac.ToLowerInvariant() } else { '' }
    # Whether a single address is usable is the shared rule's call, so this
    # driver cannot drift from the other two on loopback/link-local. The family
    # loop below stays here because THIS site also has to apply MAC affinity and
    # host-subnet preference within a family, which the shared helper knows
    # nothing about.
    $isUsable = { param($r) [bool](Select-YurunaRoutableAddress -Address @($r.Ip)) }
    foreach ($family in @('ipv4', 'ipv6')) {
        $candidates = @($rows | Where-Object { $_.Family -eq $family -and (& $isUsable $_) })
        if (-not $candidates.Count) { continue }
        if ($wantMac) {
            $byMac = @($candidates | Where-Object { $_.Mac -eq $wantMac })
            if ($byMac.Count) { $candidates = $byMac }
        }
        if ($family -eq 'ipv4' -and $HostPrefix) {
            $onSubnet = @($candidates | Where-Object { $_.Ip.StartsWith("$HostPrefix.") })
            if ($onSubnet.Count) { return [string]$onSubnet[0].Ip }
        }
        return [string]$candidates[0].Ip
    }
    return $null
}

<#
.SYNOPSIS
    Pick the address whose lease is the LIVE one out of `virsh net-dhcp-leases`
    rows, or $null.
.DESCRIPTION
    `virsh domifaddr --source lease` answers with every lease libvirt still
    holds for a domain's MAC and no way to tell them apart. One MAC accumulates
    several: a guest built from a fresh image identifies itself to DHCP by a
    client-id derived from a machine-id that is new on every build, so the
    server hands out a new address each time and keeps the earlier ones until
    they expire. Taking the first row then reports an address from a previous
    build of the same guest -- present, unexpired, and answering nothing.

    Expiry is what separates them, and only this view carries it. The live
    guest keeps RENEWING while a dead one's lease only ages, so the latest
    expiry is the live one; the same rule the macOS driver already applies to
    its own lease file.

    Rows look like:
      Expiry Time         MAC address        Protocol  IP address          ...
      2026-01-02 03:04:05 52:54:00:1a:b2:c3  ipv4      192.168.122.118/24  ...
    The header carries no MAC, so requiring one is what skips it without
    matching on column titles that a localized virsh renames.
.OUTPUTS
    System.String. The address, or $null when no row qualifies.
#>
function Select-VirshNetLeaseIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string[]]$Line,
        [string]$Mac
    )
    $wantMac = if ($Mac) { $Mac.ToLowerInvariant() } else { '' }
    $rows = @()
    foreach ($l in @($Line)) {
        if ("$l" -match '^\s*(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2})\s+([0-9a-fA-F:]{17})\s+(ipv4|ipv6)\s+(\S+?)/\d+') {
            $expiry = [datetime]::MinValue
            # An unparseable stamp must not win by accident, so it sorts oldest
            # rather than being dropped: a row that is the only candidate is
            # still the answer.
            $null = [datetime]::TryParse($Matches[1], [ref]$expiry)
            $rows += @{
                Expiry = $expiry
                Mac    = $Matches[2].ToLowerInvariant()
                Family = $Matches[3]
                Ip     = $Matches[4]
            }
        }
    }
    if (-not $rows.Count) { return $null }

    foreach ($family in @('ipv4', 'ipv6')) {
        $candidates = @($rows | Where-Object {
            $_.Family -eq $family -and [bool](Select-YurunaRoutableAddress -Address @($_.Ip))
        })
        # See https://yuruna.link/42e220c4-0004
        if ($wantMac) {
            $candidates = @($candidates | Where-Object { $_.Mac -eq $wantMac })
        }
        if (-not $candidates.Count) { continue }
        return [string](@($candidates | Sort-Object -Property Expiry -Descending)[0].Ip)
    }
    return $null
}

<#
.SYNOPSIS
    Read this host's neighbor table for an entry matching a guest MAC.
.DESCRIPTION
    The direct analog of the Hyper-V driver's MAC-keyed neighbor stage, and
    the reason it exists here: `virsh domifaddr --source arp` asks libvirt to
    match the same table, but libvirt sees an entry only while the kernel is
    publishing a link-layer address for it. FAILED and INCOMPLETE entries carry
    no lladdr, so a guest that is up and serving traffic disappears from that
    source for as long as the entry sits in either state. Reading the table
    here lets STALE -- which is a valid, resolvable entry, merely unverified --
    keep answering, and confines the rejection to the two states that genuinely
    carry no address.
.PARAMETER Mac
    Guest MAC, any case, colon-separated.
.PARAMETER NeighborLine
    Pre-captured `ip -4 neigh show` text; the live command runs when unbound.
#>
function Get-KvmNeighborIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Mac,
        [string[]]$NeighborLine
    )
    if (-not $Mac) { return $null }
    if (-not $PSBoundParameters.ContainsKey('NeighborLine')) {
        $NeighborLine = @(& ip -4 neigh show 2>$null)
        if ($LASTEXITCODE -ne 0) { return $null }
    }
    $wantMac = $Mac.ToLowerInvariant()
    # NUD states that carry a usable lladdr. FAILED and INCOMPLETE are excluded
    # because the kernel has no address for them; PERMANENT/NOARP are included
    # because a statically configured entry is as good as a probed one.
    $usableState = @('REACHABLE', 'STALE', 'DELAY', 'PROBE', 'PERMANENT', 'NOARP')
    # --- REGION: https://yuruna.link/4220a755-0043
    # See https://yuruna.link/42e5cdfd-0013
    $rank = @{ 'REACHABLE' = 0; 'PERMANENT' = 1; 'NOARP' = 1; 'DELAY' = 2; 'PROBE' = 2; 'STALE' = 3; '' = 4 }
    $candidate = [System.Collections.Generic.List[object]]::new()
    foreach ($line in @($NeighborLine)) {
        if ($line -notmatch '^\s*(\d+\.\d+\.\d+\.\d+)\s') { continue }
        $ip = $Matches[1]
        if (-not (Test-Ipv4Address $ip) -or $ip -match '^(127\.|169\.254\.)') { continue }
        if ($line -notmatch '(?i)\blladdr\s+([0-9a-f:]{17})\b') { continue }
        if ($Matches[1].ToLowerInvariant() -ne $wantMac) { continue }
        $state = if ($line -match '\b(INCOMPLETE|REACHABLE|STALE|DELAY|PROBE|FAILED|PERMANENT|NOARP)\b') { $Matches[1] } else { '' }
        if ($state -and $usableState -notcontains $state) { continue }
        $candidate.Add([pscustomobject]@{ Ip = [string]$ip; State = $state; Rank = $rank[$state] })
    }
    if ($candidate.Count -eq 0) { return $null }
    $ordered = @($candidate | Sort-Object -Property Rank)
    if ($ordered.Count -eq 1 -or $ordered[0].Rank -lt $ordered[1].Rank) {
        return [string]$ordered[0].Ip
    }
    # Two or more entries share the best rank -- necessarily a stale-vs-stale
    # tie, since the kernel keeps at most one REACHABLE entry per address. Ask
    # which one answers rather than guessing.
    foreach ($tied in @($ordered | Where-Object { $_.Rank -eq $ordered[0].Rank })) {
        & ping -c 1 -W 1 -n $tied.Ip *> $null
        if ($LASTEXITCODE -eq 0) { return [string]$tied.Ip }
    }
    return [string]$ordered[0].Ip
}

# --- REGION: Get-VMIp
function Get-VMIp {
    <#
    .SYNOPSIS
        Return the guest's host-side IPv4, or null if not yet discoverable.
    .DESCRIPTION
        Rungs are tried cheapest-first and every decline is narrated, because a
        silent $null here is indistinguishable at the call site from "this guest
        does not exist" -- and the caller turns that into an ssh target built from
        the VM name, which fails as a name-resolution error naming nothing about
        the real cause.

        Which rungs can answer is a property of the host's configuration, not of
        this code: `lease` needs libvirt to be the DHCP server, so it is silent for
        a guest on a bridge-forward network with no <dhcp> element; `agent` needs
        qemu-guest-agent inside the guest. Where both are silent the arp and
        neighbor rungs are the whole of discovery, and they are passive reads of a
        cache that decays -- hence the active refresh as the last resort.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # virsh runs several times below and each call rewrites $LASTEXITCODE.
    # Restoring it keeps this lookup from changing the meaning of a caller's
    # own exit-code check further down its script.
    $entryExitCode = $LASTEXITCODE
    try {
        $mac = Get-VMMac -VMName $VMName
        if (-not $mac) {
            Write-Verbose "Get-VMIp: no MAC in the domain XML for '$VMName'; MAC-affinity and the neighbor rung are unavailable for this lookup."
        }
        $prefixInfo = Get-HostIpv4Prefix
        $hostPrefix = if ($prefixInfo) { $prefixInfo.Prefix } else { '' }

        # See https://yuruna.link/42e5cdfd-0015
        $state = @{ Mac = $mac; HostPrefix = $hostPrefix }
        # See https://yuruna.link/42e5cdfd-0015
        $netLeaseProbe = {
            param($vm, $s)
            if (-not $s.Mac) { return $null }
            $iface = Get-YurunaGuestBridge -VMName $vm
            if (-not $iface.Network) { return $null }
            $lines = Invoke-Virsh -VirshArgs @('net-dhcp-leases', $iface.Network)
            if ($LASTEXITCODE -ne 0) { return $null }
            Select-VirshNetLeaseIp -Line $lines -Mac $s.Mac
        }
        $virshProbe = {
            param($vm, $s, $source)
            $lines = Invoke-Virsh -VirshArgs @('domifaddr', $vm, '--source', $source)
            $rc = $LASTEXITCODE
            if ($rc -ne 0) {
                # Separating this from "answered, but with nothing usable" is the
                # whole point: a non-zero exit means the question could not be
                # asked -- libvirtd refusing, the domain gone -- and the captured
                # text is the only evidence of which. Thrown so the runner
                # narrates the reason instead of recording a bare decline.
                throw "virsh exit $rc -- $((@($lines) -join ' | '))"
            }
            Select-VirshDomifaddrIp -Line $lines -Mac $s.Mac -HostPrefix $s.HostPrefix
        }
        # --- REGION: https://yuruna.link/4220a755-0045
        # See https://yuruna.link/42e5cdfd-0015
        $rungs = @(
            @{ Name = 'virsh agent'; Probe = { param($vm, $s) & $s.VirshProbe $vm $s 'agent' } }
            @{ Name = 'virsh net lease'; Probe = { param($vm, $s) & $s.NetLeaseProbe $vm $s } }
            @{ Name = 'virsh lease'; Probe = { param($vm, $s) & $s.VirshProbe $vm $s 'lease' } }
            @{ Name = 'virsh arp';   Probe = { param($vm, $s) & $s.VirshProbe $vm $s 'arp' } }
            @{ Name = 'host neighbor table'; Probe = { param($vm, $s) $null = $vm; Get-KvmNeighborIp -Mac $s.Mac } }
            # Last, and the only rung that costs anything: warm the cache, then
            # read it again. Update-GuestNeighborCache applies its own cooldown,
            # running-state and prefix-width guards, so a repeated lookup does
            # not repeat the sweep.
            @{ Name = 'neighbor table after refresh'; Probe = {
                    param($vm, $s)
                    if (-not (Update-GuestNeighborCache -VMName $vm)) { return $null }
                    Get-KvmNeighborIp -Mac $s.Mac
                } }
        )
        $state['VirshProbe'] = $virshProbe
        $state['NetLeaseProbe'] = $netLeaseProbe
        return Invoke-ResolveVmIp -VMName $VMName -Rung $rungs -State $state -Context $script:HostTag
    } finally {
        # Only restore a value that existed. Writing $null into $LASTEXITCODE
        # when nothing had run yet would invent a state the shell never had.
        if ($null -ne $entryExitCode) { $global:LASTEXITCODE = $entryExitCode }
    }
}

# --- REGION: Get-VMMac
function Get-VMMac {
    <#
    .SYNOPSIS
        Return the guest's MAC address, or null if not available.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0 -or -not $xml) { return $null }
    $joined = [string]::Join("`n", $xml)
    # First <interface ...><mac address='xx:xx:..'/> wins -- harness VMs
    # have a single NIC by convention.
    if ($joined -match "<mac\s+address='([0-9a-fA-F:]{17})'") {
        # Canonical form for the whole harness, so a MAC read on one host
        # compares equal to the same MAC read on another. Consumers that need a
        # platform notation (the kernel's lowercase neighbor table here)
        # normalize at the point of comparison, not in storage.
        $canonical = ConvertTo-YurunaMacAddress -MacAddress $Matches[1]
        if ($canonical) { return $canonical }
        return $Matches[1].ToLower()
    }
    return $null
}

# --- REGION: Neighbor cache refresh
# --- REGION: Update-GuestNeighborCache
function Update-GuestNeighborCache {
    <#
    .SYNOPSIS
        Refresh the host neighbor cache so a passive MAC lookup can succeed.
    .DESCRIPTION
        Contract verb. `--source arp` and the neighbor rung above are both passive
        reads: they answer only for addresses the kernel already has an entry for,
        and nothing in a normal cycle makes a guest talk to this host often enough
        to keep one alive. This is the active half -- one bounded ICMP sweep of the
        host's own subnet, which populates the cache for everything answering on it.

        Three guards, in cost order, because the sweep is the expensive thing here:
        a per-VM cooldown so a polling caller cannot turn its poll interval into a
        sweep interval; a running-state check so a stopped or absent domain never
        pays for one; and a /24 ceiling, since a wider prefix turns this from a
        lookup into a scan of the operator's network.
    .PARAMETER VMName
        Guest whose cooldown slot this sweep consumes.
    .PARAMETER CooldownSeconds
        Minimum gap between sweeps for one VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$CooldownSeconds = 60
    )
    $now  = Get-Date
    $last = $script:NeighborSweepMemo[$VMName]
    if ($last -and ($now - $last).TotalSeconds -lt $CooldownSeconds) {
        Write-Verbose "Update-GuestNeighborCache: '$VMName' swept $([int]($now - $last).TotalSeconds)s ago; inside the ${CooldownSeconds}s cooldown, skipping."
        return $false
    }
    $state = Get-VMState -VMName $VMName
    if ($state -ne 'running') {
        Write-Verbose "Update-GuestNeighborCache: '$VMName' is '$state', not running; no sweep."
        return $false
    }
    # --- REGION: https://yuruna.link/4220a755-0044
    # See https://yuruna.link/42e5cdfd-0014
    $prefix = Get-HostIpv4Prefix
    if ($prefix) {
        $script:LastKnownHostPrefix = $prefix
    } elseif ($script:LastKnownHostPrefix) {
        $prefix = $script:LastKnownHostPrefix
        Write-Verbose "Update-GuestNeighborCache: this host has no default-route IPv4 right now; sweeping the last prefix it held ($($prefix.Prefix).0/$($prefix.Length))."
    }
    if (-not $prefix) {
        Write-Verbose 'Update-GuestNeighborCache: this host has no default-route IPv4 and none was seen earlier; no sweep.'
        return $false
    }
    if ($prefix.Length -lt 24) {
        Write-Verbose "Update-GuestNeighborCache: host subnet is /$($prefix.Length), wider than /24; refusing to sweep $([Math]::Pow(2, 32 - $prefix.Length)) addresses."
        return $false
    }
    if (-not (Get-Command ping -ErrorAction SilentlyContinue)) {
        Write-Verbose 'Update-GuestNeighborCache: ping is not installed; no sweep.'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess("$($prefix.Prefix).0/$($prefix.Length)", (Format-YurunaOperatorMessage -Key 'host.operator_c75b8ce6370d1e89'))) {
        return $false
    }
    $script:NeighborSweepMemo[$VMName] = $now
    Write-Verbose "Update-GuestNeighborCache: sweeping $($prefix.Prefix).0/$($prefix.Length) for '$VMName'."
    # One echo request per address, one second of patience, 64 in flight. The
    # replies are irrelevant -- the point is the ARP exchange each probe forces,
    # which is what lands in the neighbor table.
    $sweepPrefix = $prefix.Prefix
    1..254 | ForEach-Object -Parallel {
        $null = & ping -c 1 -W 1 "$using:sweepPrefix.$_" 2>$null
    } -ThrottleLimit 64
    return $true
}

# --- REGION: Networking
# --- REGION: Get-ExternalNetwork
function Get-ExternalNetwork {
    <#
    .SYNOPSIS
        Return the name of the host-side External-type vSwitch or network.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # See https://yuruna.link/42e5cdfd-0016
    $candidates = @()
    if ($Env:YURUNA_EXTERNAL_NETWORK) { $candidates += $Env:YURUNA_EXTERNAL_NETWORK }
    $candidates += @('yuruna-external', 'default')
    $active  = Invoke-Virsh -VirshArgs @('net-list', '--name')
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    foreach ($c in $candidates) {
        if ($active -contains $c) { return $c }
        if ($defined -contains $c) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9a26d7342217e270' -Arguments @{ c = "$c" })
        }
    }
    return 'default'
}

# --- REGION: New-ExternalNetwork
function New-ExternalNetwork {
    <#
    .SYNOPSIS
        Create the host-side External-type vSwitch or network if missing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_797508abfaab1ff7'), (Format-YurunaOperatorMessage -Key 'host.operator_418659719eacc4c3'))) { return $null }
    # libvirt's default network ships with the daemon; nothing to create
    # here -- just ensure it's started and on autostart so guests find it.
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if (-not ($running -contains 'default')) {
        Invoke-Virsh -VirshArgs @('net-start', 'default') | Out-Null
    }
    Invoke-Virsh -VirshArgs @('net-autostart', 'default') | Out-Null
    return 'default'
}

# --- REGION: Test-CacheVMOnExternalNetwork
function Test-CacheVMOnExternalNetwork {
    <#
    .SYNOPSIS
        Returns true if the caching-proxy-service VM is on a bridged libvirt network
        (LAN-routable IP, no host portproxy needed).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    # See https://yuruna.link/42e5cdfd-001d
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state) { return $false }
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0) { return $false }
    # The configured first NIC determines exposure, not the network's name.
    # See https://yuruna.link/42e220c4-0004
    try {
        $domain = [xml]([string]::Join("`n", @($xml)))
        $interface = @($domain.domain.devices.interface)[0]
        if (-not $interface) { return $false }
        if ($interface.type -eq 'bridge') { return [bool]$interface.source.bridge }
        if ($interface.type -ne 'network' -or -not $interface.source.network) { return $false }
        return (Test-YurunaLibvirtNetworkIsBridgeMode -NetworkName $interface.source.network)
    } catch {
        Write-Debug "Test-CacheVMOnExternalNetwork: could not read '$VMName': $($_.Exception.Message)"
        return $false
    }
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.ExternalNetwork.ps1')

# --- REGION: Port mapping
# --- REGION: Add-PortMap
function Add-PortMap {
    <#
    .SYNOPSIS
        Install host to VM port forwarders for -Owner's service.
    .DESCRIPTION
        Exposes the service VM's ports on the host's LAN IP so LAN clients reach
        the NAT-networked VM at http://<host-lan-ip>:<port>.

        The cache VM sits on libvirt's NAT 'default' network, so its
        192.168.122/24 address is reachable from this host only. To make it
        LAN-reachable WITHOUT reconfiguring host networking or NetworkManager,
        this installs one socket-activated systemd unit pair per port:

          yuruna-cacheproxy-p<hostport>.socket   ListenStream=0.0.0.0:<hostport>
          yuruna-cacheproxy-p<hostport>.service  systemd-socket-proxyd <vmip>:<vmport>

        Why socket-activated forwarding and not nftables DNAT: a DNAT rule
        into the NAT subnet is dropped by libvirt's OWN forward chain --
        libvirt installs an `oifname virbr0 ... reject` rule for unsolicited
        inbound traffic to its guests. Making DNAT work means overriding
        libvirt's firewall rules, which is firewall-backend-specific and is
        regenerated every time libvirt restarts. systemd-socket-proxyd
        instead connects to the VM as a host-LOCAL process; host<->guest
        traffic is not subject to that forward filtering, so it works
        regardless of libvirt's backend. systemd runs the proxy as root (so
        a privileged :80 bind succeeds) and the enabled .socket units are
        restored on boot -- fixing both fatal flaws of the previous pwsh
        Start-Process forwarders, which could not bind :80 and did not
        survive a reboot.

        -Owner names the service the forwarders belong to. The host's port-map
        record (Get-PortMapStatePath) says which owner holds each host port:
        this call replaces only its owner's forwarders, and refuses a port
        another owner holds.
    .OUTPUTS
        [bool] $true when at least one forwarder socket is listening.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$Owner,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @()
    )
    # PROXY-protocol prefixing is a macOS shared-NAT-only mitigation;
    # accepted for cross-host contract parity, surfaced as a debug line.
    if ($ProxyProtocolPort.Count -gt 0) {
        Write-Debug "Add-PortMap on host.ubuntu.kvm: -ProxyProtocolPort $($ProxyProtocolPort -join ',') ignored; uses systemd-socket-proxyd."
    }
    if (-not (Test-Ipv4Address $VMIp)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9d16111c7f988de8' -Arguments @{ vMIp = "$VMIp" })
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMIp, (Format-YurunaOperatorMessage -Key 'host.operator_d143cf357a0454e0' -Arguments @{ join = "$($Port -join ',')" }))) { return $false }

    # systemd-socket-proxyd: Ubuntu ships it under /usr/lib/systemd;
    # older layouts use /lib/systemd. The unit's ExecStart needs an
    # absolute path, so resolve it now and bail clearly if absent.
    $proxyd = @('/usr/lib/systemd/systemd-socket-proxyd','/lib/systemd/systemd-socket-proxyd') |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $proxyd) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0093ac9c0edd7d9f')
        return $false
    }

    # See https://yuruna.link/42e220c4-0004
    $remap = @{}
    foreach ($k in $PortRemap.Keys) { $remap[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if (-not $remap.ContainsKey([int]$p)) {
            $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
        }
    }
    foreach ($k in $remap.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remap[$k] }
    }

    # Replace this owner's earlier units first: on a re-run the VM's NAT IP
    # can differ, and a stale forwarder would point LAN clients at a dead
    # address. Another owner's units are left alone.
    $statePath = Get-PortMapStatePath
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners (Read-YurunaPortMapLedger -Path $statePath) `
        -HostPort @($mappings | ForEach-Object { $_.HostPort }) -Discovered (Get-KvmPortMapPort)
    foreach ($conflict in $plan.Conflict) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.portmap_port_held' -Arguments @{ owner = "$Owner"; port = "$($conflict.HostPort)"; holder = "$($conflict.Owner)" })
    }
    if ($plan.Conflict.Count -gt 0) { return $false }
    foreach ($releasePort in $plan.Release) { Remove-KvmPortForwarder -Port $releasePort }

    $written = 0
    foreach ($m in $mappings) {
        $hostPort = $m.HostPort
        $vmPort   = $m.VMPort
        $base     = "yuruna-cacheproxy-p$hostPort"
        # No PartOf= on the socket: the .socket must keep listening when
        # the socket-activated .service recycles (systemd-socket-proxyd
        # exits when idle and is re-activated on the next connection).
        # Tying the socket to the service via PartOf would tear the
        # listener down on every idle cycle.
        $socketBody = @"
[Unit]
Description=Yuruna $Owner forward :$hostPort -> ${VMIp}:$vmPort

[Socket]
ListenStream=0.0.0.0:$hostPort

[Install]
WantedBy=sockets.target
"@
        $serviceBody = @"
[Unit]
Description=Yuruna $Owner socket-proxy :$hostPort -> ${VMIp}:$vmPort
Requires=$base.socket
After=$base.socket

[Service]
ExecStart=$proxyd ${VMIp}:$vmPort
"@
        # Invoke-YurunaSudo adds -n on the runner's unattended path and throws
        # with the sudoers rule to install if sudo wants a password there, so a
        # misconfigured host fails fast and legibly instead of stalling the
        # cycle on a prompt read from the inherited terminal.
        $okSocket  = (Invoke-YurunaSudo -Argument @('tee', "/etc/systemd/system/$base.socket")  -InputText $socketBody).ExitCode  -eq 0
        $okService = (Invoke-YurunaSudo -Argument @('tee', "/etc/systemd/system/$base.service") -InputText $serviceBody).ExitCode -eq 0
        if ($okSocket -and $okService) {
            $written++
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fbda1bdab1fd89aa' -Arguments @{ hostPort = "$hostPort" })
        }
    }
    if ($written -eq 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_97d3ec722b0257fc')
        $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -Confirm:$false
        return $false
    }

    Write-Verbose "$((Invoke-YurunaSudo -Argument @('systemctl', 'daemon-reload')).Output)"
    $live = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $mappings) {
        $sock = "yuruna-cacheproxy-p$($m.HostPort).socket"
        $enable = Invoke-YurunaSudo -Argument @('systemctl', 'enable', '--now', $sock)
        Write-Verbose "$($enable.Output)"
        if ($enable.ExitCode -eq 0) {
            Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_2d2328e8a847d429' -Arguments @{ hostPort = "$($m.HostPort)"; vMIp = "${VMIp}"; vMPort = "$($m.VMPort)" })
            $live.Add($m)
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_127df62fba83d1e0' -Arguments @{ sock = "$sock"; hostPort = "$($m.HostPort)" })
        }
    }
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -VMIp $VMIp -Mapping $live.ToArray() -Confirm:$false
    return ($live.Count -gt 0)
}

# --- REGION: Remove-PortMap
function Remove-PortMap {
    <#
    .SYNOPSIS
        Tear down the port forwarders -Owner holds.
    .DESCRIPTION
        Removes the owner's systemd socket-proxy units, plus any legacy pwsh
        Start-Process forwarders. Idempotent -- "nothing installed" is still
        success.

        Another owner's units are left alone. A unit no owner records was
        installed before owners were recorded, and goes too, as it did when
        this removed every unit.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$Owner)
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_f297da4003f2a69b'), 'Stop + remove')) { return $false }

    # See https://yuruna.link/42e220c4-0004
    $statePath = Get-PortMapStatePath
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners (Read-YurunaPortMapLedger -Path $statePath) -Discovered (Get-KvmPortMapPort) -Removing
    foreach ($releasePort in $plan.Release) { Remove-KvmPortForwarder -Port $releasePort }
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -Confirm:$false

    # Legacy pwsh Start-Process forwarders (pre-systemd mechanism): kill
    # any survivors tracked by portmap-*.pid, then clear the staging dir.
    if (Test-Path -LiteralPath $script:PortMapDir) {
        foreach ($pidFile in Get-ChildItem -LiteralPath $script:PortMapDir -Filter 'portmap-*.pid' -ErrorAction SilentlyContinue) {
            try {
                $fpid = [int]((Get-Content -LiteralPath $pidFile.FullName -Raw).Trim())
                if ($fpid -gt 0) { & /bin/kill -9 $fpid 2>$null | Out-Null }
            } catch { Write-Debug "Remove-PortMap legacy: $($_.Exception.Message)" }
        }
        Remove-Item -LiteralPath $script:PortMapDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    The host ports that have a yuruna socket-proxy unit installed.
#>
function Get-KvmPortMapPort {
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    return [int[]]@(Get-ChildItem -LiteralPath '/etc/systemd/system' -Filter 'yuruna-cacheproxy-p*.socket' -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.Name -match '^yuruna-cacheproxy-p(\d+)\.socket$') { [int]$Matches[1] } })
}

<#
.SYNOPSIS
    Stop and remove the socket-proxy unit pair for one host port.
#>
function Remove-KvmPortForwarder {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Add-PortMap and Remove-PortMap, which own the confirmation.')]
    param([Parameter(Mandatory)][int]$Port)
    $base = "/etc/systemd/system/yuruna-cacheproxy-p$Port"
    if (-not (Test-Path -LiteralPath "$base.socket") -and -not (Test-Path -LiteralPath "$base.service")) { return }
    [void](Invoke-YurunaSudo -Argument @('systemctl', 'disable', '--now', "yuruna-cacheproxy-p$Port.socket"))
    [void](Invoke-YurunaSudo -Argument @('systemctl', 'stop', "yuruna-cacheproxy-p$Port.service"))
    [void](Invoke-YurunaSudo -Argument @('rm', '-f', "$base.socket", "$base.service"))
    [void](Invoke-YurunaSudo -Argument @('systemctl', 'daemon-reload'))
}

# There is deliberately no pwsh Start-Process TcpListener forwarder here: it
# cannot bind privileged ports (:80) as a non-root user, and its detached
# processes do not survive a host reboot. Add-PortMap installs systemd
# socket-activated forwarders instead -- see its .DESCRIPTION above.

# --- REGION: Get-BestHostIp
function Get-BestHostIp {
    <#
    .SYNOPSIS
        Return the host's best LAN-routable IPv4 for browser-facing URLs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # `ip route get 1.1.1.1` resolves the default-route iface + the source
    # IP the kernel would use; that's the LAN-facing address even when
    # multiple NICs / VPNs are present. iproute2 ships with every Ubuntu.
    $out = & ip -4 route get 1.1.1.1 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in @($out)) {
        if (($line -match 'src\s+(\d+\.\d+\.\d+\.\d+)') -and (Test-Ipv4Address $Matches[1])) {
            return $Matches[1]
        }
    }
    return $null
}

# --- REGION: Get-GuestReachableHostIp
function Get-GuestReachableHostIp {
    <#
    .SYNOPSIS
        Return the host IP a guest reaches the host at (per SwitchName).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$SwitchName)
    # The libvirt 'default' network always uses 192.168.122.0/24 with the
    # host on .1. SwitchName is reserved for parity with Hyper-V; on KVM
    # the libvirt bridge is implied. If a custom external bridge is in
    # play, the operator should override via $env:YURUNA_GUEST_REACHABLE_HOST_IP.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.ubuntu.kvm: -SwitchName '$SwitchName' ignored; libvirt bridge implied." }
    if ($Env:YURUNA_GUEST_REACHABLE_HOST_IP) { return $Env:YURUNA_GUEST_REACHABLE_HOST_IP }
    return '192.168.122.1'
}

<#
.SYNOPSIS
    Resolve the libvirt network a guest attaches to plus the host IPv4 it
    reaches back on, as one matched pair.
.DESCRIPTION
    Single source of truth for guest network binding. Every install guest
    (and the caching-proxy-service) must land on the SAME network as the cache, and
    must reach the host's status service at an address routable from that
    network. Get the two from here so they can never drift apart.

    Returns a hashtable:
      NetworkName -- libvirt network for `--network network=<name>`.
                     Get-ExternalNetwork prefers the bridged 'yuruna-external'
                     when defined, else the NAT 'default'.
      HostIp      -- host address the guest reaches, matched to NetworkName:
                     NAT 'default' -> the libvirt gateway (192.168.122.1);
                     bridged -> the host's LAN IP (Get-BestHostIp).

    The pairing is load-bearing: a guest on the NAT 'default' net cannot
    route to a bridged cache's LAN IP (and vice-versa), so a guest pinned
    to one network while handed the other network's host/proxy address
    bakes an unreachable coordinate -- apt's in-target kernel fetch then
    fails with "Network is unreachable". $env:YURUNA_GUEST_REACHABLE_HOST_IP
    overrides HostIp on both paths.
#>
function Resolve-GuestHostBinding {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $networkName = Get-ExternalNetwork
    if ($Env:YURUNA_GUEST_REACHABLE_HOST_IP) {
        $hostIp = $Env:YURUNA_GUEST_REACHABLE_HOST_IP
    } elseif ($networkName -eq 'default') {
        $hostIp = Get-GuestReachableHostIp   # NAT 'default': libvirt gateway
    } else {
        $hostIp = Get-BestHostIp             # bridged 'yuruna-external': host LAN IP
    }
    if (-not $hostIp) { $hostIp = '' }
    return @{ NetworkName = $networkName; HostIp = $hostIp }
}

# --- REGION: Caching-proxy service
# --- REGION: Test-CachingProxyServiceAvailable
function Test-CachingProxyServiceAvailable {
    <#
    .SYNOPSIS
        Probe and return the caching-proxy-service URL, or null if none is reachable.
    .DESCRIPTION
        Discovery is intentionally narrow -- only caches this host owns,
        or a remote cache the operator explicitly named, are returned:
          1. $Env:YURUNA_CACHING_PROXY_SERVICE_IP -- explicit remote cache override.
          2. State file (Read-CachingProxyServiceState).ipAddress -- the cache VM's
             IP recorded by Start-CachingProxyServiceVM.ps1 (our own VM).

        No libvirt enumeration, no loopback-forwarder fallback.
        Get-CachingProxyServiceVmIp still exposes the recorded IP for direct callers that need
        it, and falls back to a live libvirt query for the by-name VM, but
        that fallback is no longer part of the discovery contract surfaced
        through Test-CachingProxyServiceAvailable. LAN-wide cache discovery is a
        separate future feature.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Quiet)
    # Keep KVM's bare-IP URL, bounded proxy retries, and optional quiet output.
    # See https://yuruna.link/42e220c4-0004
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'nc -z {0} {1}' -NoBracketHost -ConnectAttempts 3 -Quiet:$Quiet
}

# --- REGION: Get-CachingProxyServiceVmIp
function Get-CachingProxyServiceVmIp {
    <#
    .SYNOPSIS
        Return the cache VM's real IP for downstream port-forwarder setup.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Prefer the recorded IP from Start-CachingProxyServiceVM.ps1 (matches macOS / Windows).
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-IpAddress $ip)) { return $ip }
    return (Get-VMIp -VMName 'yuruna-caching-proxy-service')
}

# --- REGION: Host configuration
# --- REGION: Set-HostProxy
function Set-HostProxy {
    <#
    .SYNOPSIS
        Promote a proxy URL to the machine-wide host proxy with backup.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_3ecc49e6648c527c'), (Format-YurunaOperatorMessage -Key 'host.operator_1d67149dffd75755' -Arguments @{ proxyUrl = "$ProxyUrl" }))) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    # Idempotent backup: only snapshot BEFORE the first apply, so a
    # repeat Set-HostProxy doesn't overwrite the backup with the
    # squid-promoted state.
    Save-YurunaHostProxyBackup -Path $backupPath -ReadState { Read-LinuxProxyState } -PromotedTo $parts.Url
    if (-not (Set-LinuxHostProxy -ProxyUrl $parts.Url)) { return $false }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_3f5727a91dcab9f6' -Arguments @{ url = "$($parts.Url)" })
    return $true
}

# --- REGION: Clear-HostProxy
function Clear-HostProxy {
    <#
    .SYNOPSIS
        Restore the host proxy from the saved backup, or disable if none.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b336eaad209fac7c'), (Format-YurunaOperatorMessage -Key 'host.operator_ca5c5716704ce8c4'))) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = Read-YurunaHostProxyBackup -Path $backupPath
    if ($state -and $state.previousUrl) {
        if (-not (Set-LinuxHostProxy -ProxyUrl $state.previousUrl)) { return $false }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_44e3bf492036c774' -Arguments @{ previousUrl = "$($state.previousUrl)" })
    } else {
        if (-not (Disable-LinuxHostProxy)) { return $false }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_730bab99bcf2735f')
    }
    Remove-YurunaHostProxyBackup -Path $backupPath -Confirm:$false
    return $true
}

# --- REGION: Remove-HostProxy
function Remove-HostProxy {
    <#
    .SYNOPSIS
        Aggressively wipe every host-proxy reference and the backup file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b336eaad209fac7c'), (Format-YurunaOperatorMessage -Key 'host.operator_0b42b69cacf83715'))) { return $false }
    if (-not (Disable-LinuxHostProxy)) { return $false }
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_b1305c31540ab9a6')
    return $true
}

# --- REGION: Get-HostProxyBackupPath
function Get-HostProxyBackupPath {
    <#
    .SYNOPSIS
        Return the path of the host-proxy backup JSON.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Yuruna.Common\Get-HostProxyBackupPath
}

# --- REGION: Assert-Virtualization
function Assert-Virtualization {
    <#
    .SYNOPSIS
        Returns true if the host hypervisor is installed and ready.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # /dev/kvm is the kernel signal that hardware virt is enabled and
    # exposed; libvirtd being active is the userspace signal. Both
    # required for guests to actually run with KVM acceleration.
    if (-not (Test-Path -LiteralPath '/dev/kvm')) {
        Write-Verbose "Assert-Virtualization: /dev/kvm missing (kvm.ko not loaded or VT-x/SVM disabled in firmware)."
        return $false
    }
    $active = & systemctl is-active libvirtd 2>$null
    if ("$active".Trim() -ne 'active') {
        # Under socket activation libvirtd runs with an idle timeout: with no
        # client and no running domain it exits, and libvirtd.socket starts it
        # again on the next connection. An inactive service behind a listening
        # socket is healthy, so the virsh round trip below decides.
        $socketActive = & systemctl is-active libvirtd.socket 2>$null
        if ("$socketActive".Trim() -ne 'active') {
            Write-Verbose "Assert-Virtualization: libvirtd is not active (state=$active) and libvirtd.socket is not listening (state=$socketActive)."
            return $false
        }
        Write-Verbose "Assert-Virtualization: libvirtd is idle (state=$active); libvirtd.socket is listening."
    }
    # See https://yuruna.link/42e5cdfd-001e
    $null = Invoke-Virsh -VirshArgs @('list', '--name') -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Assert-Virtualization: virsh list failed (exit $LASTEXITCODE) -- this process cannot reach $script:VirshUri."
        return $false
    }
    return $true
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.VirtualizationRepair.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.Capture.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.ServiceGuest.ps1')

# --- REGION: Exports
Export-ModuleMember -Function Remove-KvmDomainDefinition, Resolve-KvmOsVariant, New-KvmServiceDomain, Repair-VMStorageLocation, `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, Test-VirtualizationResponsive, Start-VirtualizationServiceIfStopped, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, Get-VMDiskSnapshotState, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Start-VMDhcpCapture, Save-VMDhcpCapture, Stop-VMDhcpCapture, `
    Wait-VMIp, Wait-KvmGuestIp, Get-VMIp, Get-VMMac, Update-GuestNeighborCache, `
    Get-ExternalNetwork, New-ExternalNetwork, New-YurunaExternalNetwork, Get-YurunaExternalNetworkPlan, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, Resolve-GuestHostBinding, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, `
    Test-DownloadAlreadyCurrent, Test-CachingProxyServicePort, Resolve-CacheHostIp, Save-CachedHttpUri, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization

# --- REGION: Contract coverage
# Validate actual exports against the common contract after publishing them.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'ubuntu.kvm' `
    -Module $ExecutionContext.SessionState.Module -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot','Get-VMDiskSnapshotState',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac','Update-GuestNeighborCache',
    'Get-ExternalNetwork','New-ExternalNetwork','New-YurunaExternalNetwork','Get-YurunaExternalNetworkPlan','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization',
    'Test-VirtualizationResponsive','Start-VirtualizationServiceIfStopped'
)

# The driver wrapper must retain cache discovery when shared modules load.
# See https://yuruna.link/42e220c4-0003
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_905958f7fa20b7bf')
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_71d7daffdb4db566')
}
