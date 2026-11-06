<#PSScriptInfo
.VERSION 2026.11.05
.GUID 425e6973-60a5-43b1-90b8-194b4331c1f8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows hyperv
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for Windows + Hyper-V. Implements the Yuruna.Host
    driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

# ZLibStream in the capture encoder is .NET 6, which arrives with PowerShell 7.2.
#requires -version 7.2

<#
.SYNOPSIS
    Yuruna host driver for Windows + Hyper-V.

.DESCRIPTION
    Self-contained host driver: contract surface plus the Hyper-V /
    Windows helpers it consumes. Cross-host helpers live in
    automation/Yuruna.Common.psm1 and test/modules/Test.Ssh.psm1, imported below.

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
$script:HostTag        = 'host.windows.hyper-v'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test\modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host\windows.hyper-v'

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
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.windows.hyper-v' }
    return $script:HostTag
}

# See https://yuruna.link/42e5cdfd-0002
Import-Module (Join-Path $script:RepoRoot 'automation\Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global
# --- REGION: Shared host modules
# See https://yuruna.link/42ec97cd-0018
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Get-Image discovers the agent by name, so its import must be global.
# See https://yuruna.link/42ec97cd-001a
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.DownloadAgent.psm1') -Force -DisableNameChecking -Global
# See https://yuruna.link/42ec97cd-0017
Import-Module (Join-Path $script:RepoRoot 'host\modules\Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global
# --- REGION: Hyper-V host helpers
# Cap for a Hyper-V lifecycle cmdlet. Each one waits on a WMI call into the
# virtual machine management service, and a service that accepted the call
# and never answers would otherwise hold the verb until the step watchdog
# ends the whole cycle. A healthy host starts a VM in seconds.
$script:HyperVLifecycleTimeoutSeconds = 180
# How long a new checkpoint that the call taking it did not list back is waited
# for in the module's listing, which the snapshot verification and the restore
# that follows both read by name; Hyper-V's own record is read beside it.
# Polled every 2 s.
$script:HyperVCheckpointListSettleSeconds = 30
# See https://yuruna.link/42e5cdfd-0026
$script:OscdimgToolsRoot = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools"

function Resolve-OscdimgPath {
    <#
    .SYNOPSIS
        Full path to the ADK's Oscdimg.exe for this host, native build first.
    .OUTPUTS
        [string] -- an existing path, or the native candidate so a caller that
        finds nothing can name the directory the operator should be looking at.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # OSArchitecture, not $env:PROCESSOR_ARCHITECTURE: an x64 pwsh running
    # under emulation on an ARM64 host reports AMD64 in that variable, which
    # would pick the emulated build on the one host class that has a native one.
    $native = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { 'arm64' }
        default { 'amd64' }
    }
    # See https://yuruna.link/42e5cdfd-0027
    $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)
    if (-not $isWindowsHost) {
        return "$script:OscdimgToolsRoot\$native\Oscdimg\Oscdimg.exe"
    }

    $nativePath = Join-Path $script:OscdimgToolsRoot "$native\Oscdimg\Oscdimg.exe"
    foreach ($archDir in (@($native, 'amd64', 'x86') | Select-Object -Unique)) {
        $candidate = Join-Path $script:OscdimgToolsRoot "$archDir\Oscdimg\Oscdimg.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $nativePath
}

$OscdimgPath = Resolve-OscdimgPath

<#
.SYNOPSIS
Build an ISO image from a directory tree using Oscdimg.exe.

.DESCRIPTION
Wraps the Windows ADK Oscdimg utility to package $SourceDir into a
single-track ISO at $OutputFile with the supplied volume id (default
"cidata", used for cloud-init NoCloud seed disks). Resolves relative
paths against the current location, creates the output directory if
needed, and throws if Oscdimg.exe is missing.
#>
function CreateIso {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [string]$VolumeId = "cidata"
    )

    $cwd = (Get-Location).ProviderPath

    if (-not [System.IO.Path]::IsPathRooted($SourceDir)) {
        $SourceDir = Join-Path $cwd $SourceDir
    }
    $SourceDir = [System.IO.Path]::GetFullPath($SourceDir)

    if (-not (Test-Path -Path $SourceDir)) {
        Throw (Format-YurunaOperatorMessage -Key 'exceptions.host_34a5ef05cab6ab38' -Arguments @{ sourceDir = "$SourceDir" })
    }

    if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
        $OutputFile = Join-Path $cwd $OutputFile
    }
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    $outDir = Split-Path -Path $OutputFile -Parent
    if ($outDir -and -not (Test-Path -Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    if (-not (Test-Path -Path $OscdimgPath)) {
        Throw (Format-YurunaOperatorMessage -Key 'exceptions.host_ba52b7b4134e8e12' -Arguments @{ oscdimgPath = "$OscdimgPath" })
    }

    Write-Verbose "Creating ISO `nfrom '$SourceDir' `nto '$OutputFile' `nwith Volume ID '$VolumeId'..."
    # Capture oscdimg's chatty banner+progress so it's silent at logLevel
    # Information; replay each line via Write-Verbose so logLevel Verbose
    # still gets the full transcript.
    $oscOutput = & $OscdimgPath "$SourceDir" "$OutputFile" -n -h -m -l"$VolumeId" 2>&1
    $oscExit = $LASTEXITCODE
    if ($oscExit -ne 0 -or -not (Test-Path -LiteralPath $OutputFile)) {
        throw ("ISO creation failed (exit {0}) for '{1}': {2}" -f $oscExit, $OutputFile, ($oscOutput -join ' '))
    }
    foreach ($line in $oscOutput) {
        $text = "$line".TrimEnd()
        if ($text) { Write-Verbose $text }
    }

    Write-Verbose "ISO created successfully at: $OutputFile"
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.CacheDiscovery.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.LifecycleHelpers.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.ProxyAndPortMap.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.Screenshot.ps1')

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
        # Nested virtualization remains opt-in and Hyper-V validates host support.
        [string]$ExposeVirtualizationExtensions
    )
    # Preserve bound overrides and -WhatIf/-Confirm in the shared runner.
    # See https://yuruna.link/42ec97cd-0017
    Invoke-PerGuestNewVm -HostSubdir 'host\windows.hyper-v' @PSBoundParameters
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
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_5115fc3aa0fb34ef'))) { return @{ success = $false; errorMessage = 'WhatIf' } }
    # A reader left from the previous boot retries its connection every two
    # seconds, so it would take the new boot's COM1 pipe the moment the worker
    # creates it, only to be stopped as the new reader is armed. Ending it first
    # leaves the guest's UART one client from the start.
    [void](Stop-VMSerialCapture -VMName $VMName)
    $result = Start-HyperVVM -VMName $VMName -Confirm:$false
    # Arm the DHCP wire capture the moment the guest exists on the switch:
    # its first DISCOVER lands seconds after firmware, before any sequence
    # step runs, so no later hook could catch it. Armed on every start
    # because whether THIS boot's lease goes wrong is not knowable up front;
    # the capture is discarded unless a failure collects it.
    if ($result -and $result.success) {
        [void](Start-VMDhcpCapture -VMName $VMName)
        [void](Start-VMSerialCapture -VMName $VMName)
    }
    return $result
}

# --- REGION: Stop-VM
function Stop-VM {
    <#
    .SYNOPSIS
        Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
    .DESCRIPTION
        -ShutdownTimeoutSeconds bounds the graceful request (0 keeps the driver
        default). -NoForce returns $false when the guest ignores the request
        instead of turning it off, so a caller can record what the guest was
        doing before deciding to force it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force,
        [int]$ShutdownTimeoutSeconds = 0,
        [switch]$NoForce
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? (Format-YurunaOperatorMessage -Key 'host.operator_872a5355019f83c5') : (Format-YurunaOperatorMessage -Key 'host.operator_156e139837bd477d')))) { return $false }
    if ($Force) {
        return [bool](Stop-HyperVVMForce -VMName $VMName -Confirm:$false)
    }
    $graceful = @{ VMName = $VMName; NoForce = $NoForce }
    if ($ShutdownTimeoutSeconds -gt 0) { $graceful.ShutdownTimeoutSeconds = $ShutdownTimeoutSeconds }
    return [bool](Stop-HyperVVM @graceful -Confirm:$false)
}

# --- REGION: Stop-VMForce
function Stop-VMForce {
    <#
    .SYNOPSIS
        Force-stop a guest VM, escalating to vmwp.exe kill on Windows when graceful stop hangs.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_c6326e5af9fb01ff'))) { return $false }
    return [bool](Stop-HyperVVMForce -VMName $VMName -StopTimeoutSeconds $StopTimeoutSeconds -Confirm:$false)
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
    # Discard only a capture this VM owns: the cycle-start sweep removes
    # leftover VMs by prefix, and an unowned discard there would kill the
    # capture just armed for the guest actually under test. A failure path
    # collects (and clears) the capture before removal, so this fires only
    # on the no-failure teardown.
    if ($script:YurunaDhcpCapture -and $script:YurunaDhcpCapture.VMName -eq $VMName) {
        [void](Stop-VMDhcpCapture)
    }
    [void](Stop-VMSerialCapture -VMName $VMName)
    return [bool](Remove-HyperVTestVM -VMName $VMName -Confirm:$false)
}

# --- REGION: Rename-VM
function Rename-VM {
    <#
    .SYNOPSIS
        Rename a stopped VM and relocate its on-disk storage to a folder
        matching the new name.
    .DESCRIPTION
        Hyper-V's Rename-VM only renames the registry entry; the VHDX files
        stay at <vhdPath>\<oldName>\. Leaving them there would let
        Remove-OrphanedVMFiles.ps1 reclaim the directory on the next cycle
        because the dir name no longer matches any registered VM, killing
        the persisted snapshot. Move-VMStorage relocates VHDX + .vmcx +
        snapshot data into a fresh <vhdPath>\<NewName>\ tree so the new
        name owns the disk layout.

        Requires the VM to be stopped; the caller (Save-VMDiskSnapshot) is
        responsible for the stop. Returns $false on rename or storage-move
        failure -- a partial rename (registry succeeded, move failed) is
        surfaced rather than swallowed so the operator sees the broken state.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_e9e1683d4b60f469' -Arguments @{ newName = "$NewName" }))) { return $false }
    if ($VMName -eq $NewName) { return $true }
    # The source must be positively present and stopped, and the destination
    # positively absent. Hyper-V allows duplicate names, so a destination that
    # only reads as missing because the provider failed would create one, and
    # an ambiguous source could rename the wrong VM; the storage move that
    # follows is only safe for a guest that is not running.
    $source = Resolve-HyperVVM -VMName $VMName
    if ($source.Presence -eq 'absent') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5104cefeb7625d7d' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    if ($source.Presence -ne 'present') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_state_unknown' -Arguments @{ operation = 'Rename-VM'; vMName = "$VMName" })
        return $false
    }
    if ([string]$source.VM.State -notin @('Off', 'Saved', 'OffCritical')) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_rename_source_not_stopped' -Arguments @{ vMName = "$VMName"; state = "$($source.VM.State)" })
        return $false
    }
    $destination = Resolve-HyperVVM -VMName $NewName
    if ($destination.Presence -eq 'present') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f69adb6b2f614a13' -Arguments @{ newName = "$NewName" })
        return $false
    }
    if ($destination.Presence -ne 'absent') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_vm_state_unknown' -Arguments @{ operation = 'Rename-VM'; vMName = "$NewName" })
        return $false
    }
    # See https://yuruna.link/42f52e37-0021
    # A destination that would fail the storage move, or that cannot be read, is
    # refused here, while the registration still carries the old name.
    try {
        $renameRoot = (Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMHost' -VMName $NewName -ScriptBlock { Hyper-V\Get-VMHost -ErrorAction SilentlyContinue } | Select-Object -First 1).VirtualHardDiskPath
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_08e327b03f39d8c6' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    if ($renameRoot) {
        $renameDir = Join-Path $renameRoot $NewName
        if (Test-Path -LiteralPath $renameDir) {
            $occupied = $true
            $storageExtension = @('.vhd', '.vhdx', '.avhd', '.avhdx', '.vhds', '.vmcx', '.vmgs', '.vmrs')
            $storageFolder = @('Virtual Hard Disks', 'Virtual Machines', 'Snapshots')
            try {
                $occupied = @(Get-ChildItem -LiteralPath $renameDir -Recurse -File -Force -ErrorAction Stop | Where-Object {
                        $_.Extension -in $storageExtension -or
                        ([IO.Path]::GetRelativePath($renameDir, $_.FullName) -split '[\\/]')[0] -in $storageFolder
                    }).Count -gt 0
            } catch { $occupied = $true }
            if ($occupied) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_rename_destination_dir_occupied' -Arguments @{ newName = "$NewName"; newDir = "$renameDir" })
                return $false
            }
        }
    }
    try {
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Rename-VM' -VMName $VMName -ArgumentList @($VMName, $NewName) -ScriptBlock {
            param($Name, $NewName)
            Hyper-V\Rename-VM -Name $Name -NewName $NewName -Confirm:$false -ErrorAction Stop
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_08e327b03f39d8c6' -Arguments @{ message = "$($_.Exception.Message)" })
        return $false
    }
    # --- REGION: https://yuruna.link/4220a755-000a
    # See https://yuruna.link/42e5cdfd-002c
    $renameAdapter = $null
    try {
        $renameAdapter = Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMNetworkAdapter' -VMName $NewName -ArgumentList @($NewName) -ScriptBlock {
            param($Name)
            Hyper-V\Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop
        } | Select-Object -First 1
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9828b6c9013ab31e' -Arguments @{ newName = "$NewName"; message = "$($_.Exception.Message)" })
    }
    if ($renameAdapter) {
        $renameMacBefore = [string]$renameAdapter.MacAddress
        $renameMac = Resolve-YurunaRenameMac -MacAddress $renameMacBefore -VMName $VMName -NewName $NewName
        if ($renameMac) {
            try {
                # The adapter read above is a copy; the call reads the first
                # adapter again to set it.
                $null = Invoke-HyperVLifecycleCmdlet -Verb 'Set-VMNetworkAdapter' -VMName $NewName -ArgumentList @($NewName, $renameMac) -ScriptBlock {
                    param($Name, $renameMac)
                    Hyper-V\Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop | Select-Object -First 1 |
                        Hyper-V\Set-VMNetworkAdapter -StaticMacAddress ($renameMac -replace ':', '') -ErrorAction Stop
                }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_73ba8ba1e410fa99' -Arguments @{ newName = "$NewName"; vMName = "$VMName"; message = "$($_.Exception.Message)" })
                return $false
            }
        }
        Register-YurunaRenameMac -VMName $VMName -NewName $NewName -Before $renameMacBefore -After $(if ($renameMac) { $renameMac } else { $renameMacBefore })
    }
    # Relocate storage so the on-disk dir-name matches the new VM-name.
    # Without this, Remove-OrphanedVMFiles' "dir name with no matching
    # VM" sweep would later wipe the persisted snapshot's files.
    try {
        $vhdRoot = (Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMHost' -VMName $NewName -ScriptBlock { Hyper-V\Get-VMHost -ErrorAction SilentlyContinue } | Select-Object -First 1).VirtualHardDiskPath
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e69fb2b8940dab5a' -Arguments @{ newName = "$NewName"; destDir = "<vhdPath>\$NewName"; message = "$($_.Exception.Message)"; vMName = "$VMName" })
        return $false
    }
    if ($vhdRoot) {
        $destDir = Join-Path $vhdRoot $NewName
        try {
            $null = Invoke-HyperVLifecycleCmdlet -Verb 'Move-VMStorage' -VMName $NewName -ArgumentList @($NewName, $destDir) -ScriptBlock {
                param($Name, $Destination)
                Hyper-V\Move-VMStorage -VMName $Name -DestinationStoragePath $Destination -Confirm:$false -ErrorAction Stop
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e69fb2b8940dab5a' -Arguments @{ newName = "$NewName"; destDir = "$destDir"; message = "$($_.Exception.Message)"; vMName = "$VMName" })
            return $false
        }
    }
    return $true
}

# --- REGION: Get-VMState
function Get-VMState {
    <#
    .SYNOPSIS
        Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
    .DESCRIPTION
        Presence comes from Resolve-HyperVVM, which proves absence from a
        successful inventory rather than from the text of a lookup failure, so the
        answer does not depend on the host's display language. A provider fault
        (VMMS unreachable, a denied call, a busy host) and a duplicate name are
        'unknown', never 'absent': callers treat 'absent' as permission to build or
        reuse a name. A present VM maps Running/Saving to 'running',
        Off/Saved/OffCritical to 'stopped', and every transitional or unrecognized
        state to 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $resolved = Resolve-HyperVVM -VMName $VMName
    if ($resolved.Presence -ne 'present') { return [string]$resolved.Presence }
    switch ([string]$resolved.VM.State) {
        'Running'      { return 'running' }
        'Saving'       { return 'running' }
        'Off'          { return 'stopped' }
        'Saved'        { return 'stopped' }
        'OffCritical'  { return 'stopped' }
        default        { return 'unknown' }
    }
}

# --- REGION: Get-VMCreationTime
function Get-VMCreationTime {
    <#
    .SYNOPSIS
        When Hyper-V created the VM, in UTC, or $null when the VM is absent,
        ambiguous or unreadable.
    .DESCRIPTION
        Every boot of a VM follows its creation, so the time since then bounds
        how long any boot of it can have run, across resets. The VM's uptime
        bounds only the current boot: Hyper-V restarts it at every reset, the
        guest's own reboots included. Presence comes from Resolve-HyperVVM, so
        a duplicate name answers $null rather than another VM's time.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        $resolved = Resolve-HyperVVM -VMName $VMName
        if ($resolved.Presence -ne 'present') { return $null }
        $created = $resolved.VM.CreationTime
        if ($created -isnot [datetime] -or $created -eq [datetime]::MinValue) { return $null }
        return $created.ToUniversalTime()
    } catch {
        Write-Verbose "Get-VMCreationTime: '$VMName' unreadable: $($_.Exception.Message)"
        return $null
    }
}

# --- REGION: VM inventory
# --- REGION: Get-VMName
function Get-VMName {
    <#
    .SYNOPSIS
        Return the names of every Hyper-V VM, optionally filtered to those
        starting with one of $Prefix.
    .DESCRIPTION
        Host-neutral inventory call (see the contract's VM inventory block).
        Every registered VM is returned regardless of run state, so a caller
        sweeping by prefix removes stopped leftovers as well as running ones.

        THROWS when Hyper-V itself cannot be queried rather than returning an
        empty list: without elevation (or with vmms down) Get-VM fails, and a
        caller that read that as "nothing registered" would report a clean
        host and let the orphan-file pass delete VHDX directories that are
        still in use.
    .PARAMETER Prefix
        Zero or more name prefixes. A VM is returned when its name starts
        with any of them. Omit to return every VM.
    .OUTPUTS
        [string[]] matching VM names; empty when none match.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    try {
        # Module-qualified: the unqualified Get-VM resolves to this
        # driver's contract surface, which exposes Get-VMState instead.
        # Under the lifecycle cap: an inventory that does not answer throws
        # like one that was refused and never reads as an empty host.
        $all = @(Invoke-HyperVLifecycleCmdlet -Verb 'Get-VM' -VMName '*' -ScriptBlock {
            Hyper-V\Get-VM -ErrorAction Stop | ForEach-Object { $_.Name }
        })
    } catch {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_de8cc2205b118bfb' -Arguments @{ message = "$($_.Exception.Message)" })
    }
    return Select-NameByPrefix -Name $all -Prefix $Prefix
}

# --- REGION: Disk snapshots
# --- REGION: Save-VMDiskSnapshot
function Save-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Save a disk-only checkpoint of the VM as the persisted VM named $Id,
        through the shared transactional save (Invoke-YurunaDiskSnapshotSave).
    .DESCRIPTION
        Hyper-V's Checkpoint-VM captures runtime state by default. For a
        disk-only point the VM is stopped first (graceful, then Stop-VMForce
        on graceful timeout); with no RAM to checkpoint, the resulting .avhdx
        differencing disk + .vmrs pair is effectively a disk-only point. The
        VM is left stopped on return so the caller's sequence decides when to
        restart -- mirrors KVM and UTM, where the underlying tool requires an
        offline VM.

        Rename-VM moves the VM's storage into <vhdPath>\<Id>\ so the next
        cycle's Remove-TestVMFiles.ps1 (which sweeps every name matching the
        test-* prefix) leaves the persisted VM and its checkpoint alone. The
        sequence engine points its later steps at $Id after a successful
        saveDiskSnapshot step.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_dd94ac62ae57701c' -Arguments @{ id = "$Id" }))) { return $false }
    return [bool](Invoke-YurunaDiskSnapshotSave -VMName $VMName -Id $Id -Confirm:$false -Primitive @{
        State         = { param($Name) Get-VMState -VMName $Name }
        SnapshotState = { param($Name, $SnapshotId) Get-VMDiskSnapshotState -VMName $Name -Id $SnapshotId }
        Stop          = { param($Name) Stop-HyperVVMForSnapshot -VMName $Name -Id $Id }
        Rename        = { param($Name, $NewName) Rename-VM -VMName $Name -NewName $NewName -Confirm:$false }
        Remove        = { param($Name) Remove-VM -VMName $Name -Confirm:$false }
        Snapshot      = { param($Name, $SnapshotId) New-HyperVDiskSnapshot -VMName $Name -Id $SnapshotId }
    })
}

<#
.SYNOPSIS
    Stop a VM for a checkpoint and confirm Hyper-V reports it Off.
    See https://yuruna.link/42e220c4-0004
#>
function Stop-HyperVVMForSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    $state = Resolve-HyperVVM -VMName $VMName
    if ($state.Presence -ne 'present') { return $false }
    if ([string]$state.VM.State -in @('Off', 'OffCritical')) { return $true }
    if (-not (Stop-VM -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f14a8d0740e60f7c' -Arguments @{ vMName = "$VMName"; id = "$Id" })
        if (-not (Stop-VMForce -VMName $VMName)) { return $false }
    }
    $state = Resolve-HyperVVM -VMName $VMName
    return ($state.Presence -eq 'present' -and [string]$state.VM.State -in @('Off', 'OffCritical'))
}

<#
.SYNOPSIS
    Create checkpoint $Id on the stopped VM $VMName, replacing one of the same
    name.
#>
function New-HyperVDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    try {
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Remove-VMCheckpoint' -VMName $VMName -ArgumentList @($VMName, $Id) -ScriptBlock {
            param($Name, $SnapshotId)
            $existing = Hyper-V\Get-VMCheckpoint -VMName $Name -Name $SnapshotId -ErrorAction SilentlyContinue
            if ($existing) { Hyper-V\Remove-VMCheckpoint -VMName $Name -Name $SnapshotId -Confirm:$false -ErrorAction Stop }
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b9f3935d5cddbc4' -Arguments @{ id = "$Id"; message = "$($_.Exception.Message)" })
        return $false
    }
    try {
        $made = @(Invoke-HyperVLifecycleCmdlet -Verb 'Checkpoint-VM' -VMName $VMName -ArgumentList @($VMName, $Id) -ScriptBlock {
            param($Name, $SnapshotId)
            $created = @(Hyper-V\Checkpoint-VM -Name $Name -SnapshotName $SnapshotId -Passthru -Confirm:$false -ErrorAction Stop)
            [pscustomobject]@{
                Made   = @($created | ForEach-Object { '{0} ({1})' -f [string]$_.Name, [string]$_.Id }) -join '; '
                Listed = @(Hyper-V\Get-VMCheckpoint -VMName $Name -ErrorAction Stop | ForEach-Object { [string]$_.Name })
            }
        }) | Select-Object -Last 1
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_653d2c6949f53ff7' -Arguments @{ vMName = "$VMName"; id = "$Id"; message = "$($_.Exception.Message)" })
        return $false
    }
    $listed = @($made.Listed)
    if ($listed -contains $Id) { return $true }
    # Not listed by the call that took it: keep reading, bounded, both the
    # module's listing, which the verification that follows and the next
    # restore read by name, and the checkpoints Hyper-V records for the VM's Id,
    # so the warning that ends the wait can tell a checkpoint that was missing,
    # one under another name, and one that only reached the listing late.
    # The wait is bounded by its polls, and a record read that fails or reaches
    # its cap is not repeated.
    $waited = [Diagnostics.Stopwatch]::StartNew()
    $resolved = Resolve-HyperVVM -VMName $VMName
    $vmId = if ($resolved.Presence -eq 'present') { $resolved.VM.Id } else { $null }
    $held = if ($vmId) { Get-HyperVCheckpointRecord -VMId $vmId -TimeoutSeconds $script:HyperVCheckpointListSettleSeconds } else { $null }
    $recordReadable = $null -ne $held
    $listing = 'absent'
    for ($poll = 0; $poll -lt [Math]::Ceiling($script:HyperVCheckpointListSettleSeconds / 2); $poll++) {
        Start-Sleep -Seconds 2
        $listing = Get-VMDiskSnapshotState -VMName $VMName -Id $Id
        if ($listing -eq 'present') { return $true }
        if ($listing -eq 'unknown') { break }
        if ($recordReadable -and @($held | Where-Object { $_.Name -eq $Id }).Count -eq 0) {
            $again = Get-HyperVCheckpointRecord -VMId $vmId -TimeoutSeconds $script:HyperVCheckpointListSettleSeconds
            if ($null -eq $again) { $recordReadable = $false } else { $held = $again }
        }
    }
    $seconds = "$([int][Math]::Round($waited.Elapsed.TotalSeconds))"
    $heldText = if ($null -eq $held) { '?' } else { (@($held | ForEach-Object { '{0} [{1}]' -f $_.Name, $_.Type }) -join '; ') }
    if ($listing -eq 'unknown') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_checkpoint_listing_unanswered' -Arguments @{ vMName = "$VMName"; id = "$Id"; seconds = $seconds; held = "$heldText" })
        return $false
    }
    if (@($held | Where-Object { $_.Name -eq $Id }).Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_checkpoint_listing_lagged' -Arguments @{ vMName = "$VMName"; id = "$Id"; seconds = $seconds })
        return $false
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.hyperv_checkpoint_not_listed' -Arguments @{
            vMName = "$VMName"; id = "$Id"; made = "$($made.Made)"; listed = ($listed -join '; '); held = "$heldText" })
    return $false
}

# --- REGION: Restore-VMDiskSnapshot
function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Restore $VMName to Hyper-V checkpoint $Id.
    .DESCRIPTION
        Verifies the checkpoint exists first so a typo'd Id does not
        bounce a healthy guest, stops the VM if it is running, then
        calls Hyper-V\Restore-VMCheckpoint. Returns the apply status as
        a bool so callers can branch on success.
    .OUTPUTS
        [bool] $true on success; $false on missing checkpoint or restore failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_122c73a3a2052796' -Arguments @{ id = "$Id" }))) { return $false }
    # The same bounded listing the save verifies with: a listing that fails or
    # reaches its cap reads as not present, and the restore is refused.
    if ((Get-VMDiskSnapshotState -VMName $VMName -Id $Id) -ne 'present') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b45c917f03c9cba3' -Arguments @{ id = "$Id"; vMName = "$VMName" })
        return $false
    }
    # Rollback discards current writes; force-stop and confirm power-off first.
    # See https://yuruna.link/42e220c4-0004
    $state = Resolve-HyperVVM -VMName $VMName
    if ($state.Presence -ne 'present') { return $false }
    if ([string]$state.VM.State -notin @('Off', 'OffCritical')) {
        if (-not (Stop-VMForce -VMName $VMName)) { return $false }
        $state = Resolve-HyperVVM -VMName $VMName
        if ($state.Presence -ne 'present' -or [string]$state.VM.State -notin @('Off', 'OffCritical')) { return $false }
    }
    try {
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Restore-VMCheckpoint' -VMName $VMName -ArgumentList @($VMName, $Id) -ScriptBlock {
            param($Name, $SnapshotId)
            Hyper-V\Restore-VMCheckpoint -VMName $Name -Name $SnapshotId -Confirm:$false -ErrorAction Stop
        }
        return $true
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1b2ab5d91cb086fd' -Arguments @{ vMName = "$VMName"; id = "$Id"; message = "$($_.Exception.Message)" })
        return $false
    }
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
    # Every checkpoint name, matched here, rather than a -Name lookup whose miss
    # and whose failure are both errors: an existing VM with none lists nothing.
    # The listing runs in a bounded call, as the calls that create and remove
    # checkpoints do; a listing that fails or reaches the cap reads as unknown,
    # never as absent. When a new checkpoint is not listed at once,
    # New-HyperVDiskSnapshot reads Hyper-V's own record beside it.
    try {
        $names = @(Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMCheckpoint' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            Hyper-V\Get-VMCheckpoint -VMName $Name -ErrorAction Stop | ForEach-Object { [string]$_.Name }
        })
    } catch { return 'unknown' }
    if (@($names | Where-Object { $_ -eq $Id }).Count -gt 0) { return 'present' }
    return 'absent'
}

# --- REGION: Test-VMDiskSnapshot
function Test-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Returns $true when checkpoint $Id is present on $VMName, $false when
        it is absent (including when the VM does not exist), and throws when
        Hyper-V could not answer. Used by Debug-TestSequence.ps1's
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
    # vmconnect's window title contains the VM name. A best-effort check;
    # Test.SequenceEngine.psm1's Send-ClickHyperV uses similar logic.
    $proc = Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Select-Object -First 1
    return [bool]$proc
}

# --- REGION: Restart-VMConsole
function Restart-VMConsole {
    <#
    .SYNOPSIS
        Refresh or re-open the host-side console window for the given VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_fd6bea70e855e2b8'))) { return $false }
    return [bool](Restart-HyperVConnect -VMName $VMName -Confirm:$false)
}

# --- REGION: Set-VMInstallerMediaFirstBoot
function Set-VMInstallerMediaFirstBoot {
    <#
    .SYNOPSIS
        Put a stopped guest's installer DVD back at the head of its firmware boot order.
    .DESCRIPTION
        New-UbuntuServerVM.ps1 makes the installer DVD the first boot device,
        but curtin's bootloader step registers the target disk in the guest's
        UEFI NVRAM ahead of it. A guest cut off after that step and before the
        installer's late-commands would otherwise boot a target that is missing
        the late-command changes (the expired first-login password among them),
        so a power-cycle meant to restart the install must reselect the DVD.
        The seed ISO is the other DVD and is never the installer. Returns
        $false unless exactly one installer DVD is attached and Hyper-V
        accepted it as the first boot device.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Boot the installer DVD first')) { return $false }
    try {
        $installerDvd = @(Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMDvdDrive' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            Hyper-V\Get-VMDvdDrive -VMName $Name -ErrorAction Stop
        } | Where-Object { $_.Path -and (Split-Path -Leaf $_.Path) -ne 'seed.iso' })
        if ($installerDvd.Count -ne 1) {
            Write-Verbose "Set-VMInstallerMediaFirstBoot: '$VMName' has $($installerDvd.Count) installer DVD candidates; expected 1."
            return $false
        }
        # The drive read above is a copy, and -FirstBootDevice takes the drive
        # itself, so the call finds it again by its place on its controller.
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Set-VMFirmware' -VMName $VMName -ArgumentList @($VMName, [int]$installerDvd[0].ControllerNumber, [int]$installerDvd[0].ControllerLocation) -ScriptBlock {
            param($Name, $ControllerNumber, $ControllerLocation)
            $dvd = Hyper-V\Get-VMDvdDrive -VMName $Name -ControllerNumber $ControllerNumber -ControllerLocation $ControllerLocation -ErrorAction Stop
            Hyper-V\Set-VMFirmware -VMName $Name -FirstBootDevice $dvd -ErrorAction Stop
        }
        return $true
    } catch {
        Write-Verbose "Set-VMInstallerMediaFirstBoot: '$VMName' boot order unchanged: $($_.Exception.Message)"
        return $false
    }
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
    # Thin wrapper over the shared runner; the host subdir is the only platform
    # variable and Get-ImagePath (the per-platform image table) is injected as a
    # CommandInfo resolved in THIS driver's scope so the shared body binds ours.
    Invoke-GetImage -HostSubdir 'host\windows.hyper-v' -ResolveImagePath (Get-Command Get-ImagePath) @PSBoundParameters
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
    $fileNames = @{
        'guest.amazon.linux.2023'    = 'host.windows.hyper-v.guest.amazon.linux.2023.vhdx'
        'guest.ubuntu.server.24'   = 'host.windows.hyper-v.guest.ubuntu.server.24.iso'
        'guest.ubuntu.server.26'   = 'host.windows.hyper-v.guest.ubuntu.server.26.iso'
        'guest.windows.11'      = 'host.windows.hyper-v.guest.windows.11.iso'
    }
    $fileName = $fileNames[$GuestKey]
    if (-not $fileName) { return $null }
    try {
        $vhdPath = (Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMHost' -VMName $GuestKey -ScriptBlock { Hyper-V\Get-VMHost -ErrorAction Stop } | Select-Object -First 1).VirtualHardDiskPath
        return Join-Path $vhdPath $fileName
    } catch { $null = $_; return $null }
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
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on Hyper-V." }
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
    # See https://yuruna.link/42e220c4-0004
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse. When the outer loop already loaded Invoke-Sequence -Global we must
        # NOT re-import per call: a -Force re-import evicts/reinitializes the global module (and its
        # nested modules + $script: state) the outer loop still calls, and doing it on every
        # keystroke is pure overhead.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
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
    # Defer to Invoke-Sequence's host-aware dispatcher (same reasoning as
    # Send-Text above -- Send-KeyHyperV is private to Invoke-Sequence and
    # not resolvable from this module's scope).
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, never -Force per call -- same trap as Send-Text
        # above.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
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
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse, never -Force per call -- same trap as Send-Text
        # above.
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        return [bool](Test.SequenceEngine\Send-Click -HostType (Resolve-HostTag) -VMName $VMName -X $X -Y $Y)
    }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0c2172f8af698467' -Arguments @{ sequenceEngine = "$sequenceEngine" })
    return $false
}

# --- REGION: Get-VMScreenshot
function Get-VMScreenshot {
    <#
    .SYNOPSIS
        Capture a PNG of the VM display from frame or window source.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateSet('frame','window')][string]$Source = 'frame',
        [string]$OutFile
    )
    if (-not $OutFile) {
        $tmp = [System.IO.Path]::GetTempFileName()
        $OutFile = [System.IO.Path]::ChangeExtension($tmp, '.png')
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    if ($Source -eq 'window') {
        return Get-HyperVWindowScreenshot -VMName $VMName -OutputPath $OutFile
    }
    # 'frame' source: WMI GetVirtualSystemThumbnailImage, with vmconnect PrintWindow fallback (Get-HyperVScreenshot).
    return Get-HyperVScreenshot -VMName $VMName -OutputPath $OutFile
}

# --- REGION: Get-VMConsoleHandle
function Get-VMConsoleHandle {
    <#
    .SYNOPSIS
        Return a host-specific handle for the VM console window.
    #>
    [CmdletBinding()]
    [OutputType([System.IntPtr])]
    param([Parameter(Mandatory)][string]$VMName)
    $proc = Get-Process -Name 'vmconnect' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -match [regex]::Escape($VMName) } |
        Select-Object -First 1
    if (-not $proc) { return [System.IntPtr]::Zero }
    return $proc.MainWindowHandle
}

<#
.SYNOPSIS
    Read the guest framebuffer twice through WMI and say whether it changed.
.DESCRIPTION
    A wait that exhausts its console-reconnect repairs ends on one ambiguous
    fact: every captured frame was byte-identical. That has two causes with
    opposite owners -- a guest whose framebuffer is truly static, and a
    capture pipeline that lost the live feed while the guest kept drawing.
    The capture path cannot arbitrate its own suspects (its viewer window and
    its PrintWindow capture are the parts in question), so this reads the
    framebuffer through GetVirtualSystemThumbnailImage alone -- no vmconnect,
    no PrintWindow fallback -- twice, a few seconds apart. Differing bytes
    mean the guest is still drawing and the capture path is at fault;
    identical bytes mean the guest side is static too. A blinking cursor can
    vanish in thumbnail downscaling, so an identical pair is reported as what
    was observed, never as proof the guest is dead.
.OUTPUTS
    [pscustomobject] Verdict 'guest-static' | 'guest-live' | 'unavailable', Detail.
#>
function Get-VMConsoleSecondOpinion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$IntervalSeconds = 5
    )
    try {
        $readFrame = { Get-HyperVThumbnailByte -VMName $VMName -Width 640 -Height 480 }
        $first = & $readFrame
        if (-not $first) {
            return [pscustomobject]@{ Verdict = 'unavailable'; Detail = (Format-YurunaOperatorMessage -Key 'host.operator_540894cbcc3a0f70') }
        }
        Start-Sleep -Seconds $IntervalSeconds
        $second = & $readFrame
        if (-not $second) {
            return [pscustomobject]@{ Verdict = 'unavailable'; Detail = (Format-YurunaOperatorMessage -Key 'host.operator_020a57eb5b872e90') }
        }
        $cpu = $null
        try { $cpu = (Hyper-V\Get-VM -Name $VMName -ErrorAction Stop).CPUUsage } catch { $cpu = $null }
        $cpuText = if ($null -ne $cpu) { "VM CPU ${cpu}%" } else { 'VM CPU unreadable' }
        if ([System.Linq.Enumerable]::SequenceEqual([byte[]]$first, [byte[]]$second)) {
            return [pscustomobject]@{
                Verdict = 'guest-static'
                Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_fc02650ed15d14f2' -Arguments @{ intervalSeconds = "${IntervalSeconds}"; cpuText = "$cpuText" })
            }
        }
        return [pscustomobject]@{
            Verdict = 'guest-live'
            Detail  = (Format-YurunaOperatorMessage -Key 'host.operator_e5ac91fd2fb33378' -Arguments @{ intervalSeconds = "${IntervalSeconds}"; cpuText = "$cpuText" })
        }
    } catch {
        return [pscustomobject]@{ Verdict = 'unavailable'; Detail = $_.Exception.Message }
    }
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.Capture.ps1')

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

# --- REGION: Get-VMIp
function Get-VMIp {
    <#
    .SYNOPSIS
        Return the guest's host-side IPv4, or null if not yet discoverable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # Read KVP first, then the VM's MAC-filtered neighbor entries without probing.
    # See https://yuruna.link/42e220c4-0004
    try {
        # Under the lifecycle cap: the address poll that calls this ends at its
        # own deadline only when each read it makes does.
        $vmAdapter = Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMNetworkAdapter' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            Hyper-V\Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop
        }
        $addrs = $vmAdapter.IPAddresses
        # See https://yuruna.link/42e220c4-0004
        $ipv4 = Select-YurunaRoutableAddress -Address @($addrs | Where-Object { Test-Ipv4Address $_ })
        if ($ipv4) { return [string]$ipv4 }

        # KVP empty -- try the host's ARP cache for an entry matching
        # this VM's MAC. Format-conversion mirrors Get-CacheVmCandidateIp
        # (KVP MAC is bare hex; Get-NetNeighbor returns dash-separated).
        $vmMac = ($vmAdapter | Select-Object -First 1).MacAddress
        if ($vmMac -match '^[0-9A-Fa-f]{12}$' -and $vmMac -ne '000000000000') {
            $vmMacDashed = (($vmMac -replace '(..)(?!$)', '$1-')).ToUpper()
            # The MAC and the NUD state are this stage's own conditions; which of
            # the surviving addresses is usable is the shared rule's.
            $arpCandidate = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.LinkLayerAddress -eq $vmMacDashed -and
                    $_.State -ne 'Unreachable'
                } |
                ForEach-Object { [string]$_.IPAddress })
            $arpIp = Select-YurunaRoutableAddress -Address $arpCandidate
            if ($arpIp) { return [string]$arpIp }
        }

        # Reached only when no v4 qualified above, so the shared selector's
        # v4-first preference is a no-op here and it returns the v6 answer.
        $ipv6 = Select-YurunaRoutableAddress -Address @($addrs)
        if ($ipv6) { return [string]$ipv6 }
    } catch {
        Write-Debug "Get-VMIp: Get-VMNetworkAdapter failed for ${VMName}: $_"
    }
    return $null
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
    # One bounded read for both lookups: a VM that is absent and a management
    # service that does not answer are both "not available", never a wait.
    $mac = $null
    try {
        $mac = Invoke-HyperVLifecycleCmdlet -Verb 'Get-VMNetworkAdapter' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            $vm = Hyper-V\Get-VM -Name $Name -ErrorAction SilentlyContinue
            if ($vm) { ($vm | Hyper-V\Get-VMNetworkAdapter | Select-Object -First 1).MacAddress }
        } | Select-Object -First 1
    } catch {
        Write-Verbose "Get-VMMac: '$VMName' unreadable: $($_.Exception.Message)"
        return $null
    }
    if (-not $mac) { return $null }
    # Canonical form for the whole harness, so a MAC read on one host compares
    # equal to the same MAC read on another. Platform-native notations are
    # produced at the point of use, never stored.
    $canonical = if ($mac) { ConvertTo-YurunaMacAddress -MacAddress $mac } else { $null }
    if ($canonical) { return $canonical }
    return $mac
}

# --- REGION: Neighbor cache refresh
# --- REGION: Update-GuestNeighborCache
function Update-GuestNeighborCache {
    <#
    .SYNOPSIS
        Refresh the host neighbor cache so a passive MAC lookup can succeed.
    .DESCRIPTION
        Contract verb; on this host it is the existing External-vSwitch ARP sweep
        under the shared name. Hyper-V's own discovery leans on KVP first, so the
        sweep is the second stage rather than the only one -- but a caller that
        needs the neighbor cache warm should not have to know that.
    .PARAMETER VMName
        Accepted for contract symmetry. The sweep covers the whole switch subnet,
        so it warms the cache for every guest at once rather than per VM.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$CooldownSeconds = 60
    )
    $null = $VMName
    $null = $CooldownSeconds
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_c287504e62bbfb0e'), (Format-YurunaOperatorMessage -Key 'host.operator_c75b8ce6370d1e89'))) {
        return $false
    }
    Invoke-YurunaExternalArpProbe
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
    # Don't create -- just discover. Get-OrCreateYurunaExternalSwitch's
    # internal logic checks "preferred name" then "any External vSwitch"
    # before creation; we emulate the no-create variant here by passing
    # -WhatIf, which skips ShouldProcess and returns $null on the create
    # branch.
    return Get-OrCreateYurunaExternalSwitch -WhatIf 2>$null
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
    if (-not $PSCmdlet.ShouldProcess('Yuruna-External', (Format-YurunaOperatorMessage -Key 'host.operator_17b5ae6b7de1d3d8'))) { return $null }
    return Get-OrCreateYurunaExternalSwitch
}

# --- REGION: Test-CacheVMOnExternalNetwork
function Test-CacheVMOnExternalNetwork {
    <#
    .SYNOPSIS
        Returns true if the caching-proxy-service VM is on an External-type network.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    return [bool](Test-CacheVmOnYurunaExternalSwitch -VMName $VMName)
}

# --- REGION: Port mapping
# --- REGION: Add-PortMap
function Add-PortMap {
    <#
    .SYNOPSIS
        Install host to VM port forwarders for -Owner's service.
    .DESCRIPTION
        The host's port-map record (Get-PortMapStatePath) says which owner
        holds each host port: this call replaces only its owner's forwarders,
        and refuses a port another owner holds.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$Owner,
        [int[]]$Port = @(3000),
        [hashtable]$PortRemap = @{},
        [int[]]$ProxyProtocolPort = @(),
        [string]$RuntimeDir
    )
    if (-not $PSCmdlet.ShouldProcess($VMIp, (Format-YurunaOperatorMessage -Key 'host.operator_768bdece9805bfb7' -Arguments @{ join = "$($Port -join ',')" }))) { return $false }
    if (-not (Test-Ipv4Address $VMIp)) {
        # Hyper-V Add-PortMap uses netsh portproxy v4tov4. v6 inputs (which
        # Test-IpAddress accepts elsewhere as operator-facing values) are
        # rejected here because the underlying mechanism is v4-only.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0ecd062994307300' -Arguments @{ vMIp = "$VMIp" })
        return $false
    }
    if (-not (Test-IsAdministrator)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e91e5d5a5d4ac989')
        return $false
    }
    $proxyProtoSet = @{}
    foreach ($p in $ProxyProtocolPort) { $proxyProtoSet[[int]$p] = $true }
    $remapHostPorts = @{}
    foreach ($k in $PortRemap.Keys) { $remapHostPorts[[int]$k] = [int]$PortRemap[$k] }
    $mappings = @()
    foreach ($p in $Port) {
        if ($remapHostPorts.ContainsKey([int]$p)) { continue }
        $mappings += [PSCustomObject]@{ HostPort = [int]$p; VMPort = [int]$p }
    }
    foreach ($k in $remapHostPorts.Keys) {
        $mappings += [PSCustomObject]@{ HostPort = [int]$k; VMPort = [int]$remapHostPorts[$k] }
    }
    $statePath = Get-PortMapStatePath -RuntimeDir $RuntimeDir
    # Replace this owner's earlier forwarders; another owner's are left alone.
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners (Read-YurunaPortMapLedger -Path $statePath) `
        -HostPort @($mappings | ForEach-Object { $_.HostPort }) -Discovered (Get-HyperVPortMapPort)
    foreach ($conflict in $plan.Conflict) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.portmap_port_held' -Arguments @{ owner = "$Owner"; port = "$($conflict.HostPort)"; holder = "$($conflict.Owner)" })
    }
    if ($plan.Conflict.Count -gt 0) { return $false }
    foreach ($releasePort in $plan.Release) { Remove-SinglePortMap -Port $releasePort -Confirm:$false }
    # Track which host ports actually came up so the state file records only live mappings and
    # the caller can detect (and re-drive) a partial setup instead of trusting a complete state.
    $launched = [System.Collections.Generic.List[int]]::new()
    $failed   = [System.Collections.Generic.List[int]]::new()
    foreach ($m in $mappings) {
        $hostPort = $m.HostPort; $vmPort = $m.VMPort
        $useProxy = $proxyProtoSet.ContainsKey([int]$hostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("host:${hostPort} -> ${VMIp}:${vmPort}${proxyTag}", (Format-YurunaOperatorMessage -Key 'host.operator_33e4bdda661323b1'))) { continue }
        $desc = "Yuruna ${Owner}: forward host :${hostPort} to VM :${vmPort}${proxyTag}"
        & netsh interface portproxy delete v4tov4 listenport=$hostPort listenaddress=0.0.0.0 2>&1 | Out-Null
        $null = Stop-WindowsCachingProxyServiceForwarder -Port $hostPort -Quiet
        Add-CachingProxyServiceFirewallRule -Port $hostPort -Description $desc -IncludeProgram:$useProxy -Confirm:$false
        if ($useProxy) {
            $spawn = Start-WindowsCachingProxyServiceForwarder -CacheIp $VMIp -Port $hostPort -VMPort $vmPort -PrependProxyV1
            if (-not $spawn.Success) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b038c339b5d9669a' -Arguments @{ hostPort = "${hostPort}"; vMIp = "${VMIp}"; vmPort = "${vmPort}" })
                $failed.Add($hostPort)
                continue
            }
            # Self-heal the per-program rule if Get-PwshExePath's pre-spawn
            # guess didn't match the binary the OS actually loaded (Microsoft
            # Store App Execution Alias trap).
            if ($spawn.PwshPath) {
                $existingProgramPath = $null
                try {
                    $existingProgramPath = (Get-NetFirewallRule -DisplayName "Yuruna-CachingProxyService-Pwsh-${hostPort}" -ErrorAction Stop |
                                            Get-NetFirewallApplicationFilter -ErrorAction Stop).Program
                } catch { $null = $_ }
                if ($existingProgramPath -ne $spawn.PwshPath) {
                    if ($existingProgramPath) {
                        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_297025349b1d260e' -Arguments @{ pwshPath = "$($spawn.PwshPath)"; existingProgramPath = "$existingProgramPath" })
                    } else {
                        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_9ad65918bbd86e4f' -Arguments @{ pwshPath = "$($spawn.PwshPath)" })
                    }
                    Add-CachingProxyServiceFirewallRule -Port $hostPort -Description $desc -IncludeProgram -ProgramPath $spawn.PwshPath -Confirm:$false
                }
            }
        } else {
            & netsh interface portproxy add v4tov4 listenport=$hostPort listenaddress=0.0.0.0 connectport=$vmPort connectaddress=$VMIp | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_122a7f5c9946bd10' -Arguments @{ hostPort = "${hostPort}"; vMIp = "${VMIp}"; vmPort = "${vmPort}"; lASTEXITCODE = "$LASTEXITCODE" })
                $failed.Add($hostPort)
                continue
            }
        }
        $launched.Add($hostPort)
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_906168be03f0bc02' -Arguments @{ hostPort = "${hostPort}"; vMIp = "${VMIp}"; vmPort = "${vmPort}"; proxyTag = "${proxyTag}" })
    }
    # Record ONLY the ports that actually came up, so a later reader / self-heal never treats a
    # partially-installed map as complete.
    $liveMappings = @($mappings | Where-Object { $launched -contains $_.HostPort } | ForEach-Object {
            [pscustomobject]@{ HostPort = $_.HostPort; VMPort = $_.VMPort; ProxyProtocol = $proxyProtoSet.ContainsKey([int]$_.HostPort) }
        })
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -VMIp $VMIp -Mapping $liveMappings -Confirm:$false
    if ($failed.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_681c2451182fe9d4' -Arguments @{ count = "$($failed.Count)"; count2 = "$($mappings.Count)"; join = "$($failed -join ', ')" })
        return $false
    }
    return $true
}

# --- REGION: Remove-PortMap
function Remove-PortMap {
    <#
    .SYNOPSIS
        Tear down the port forwarders -Owner holds.
    .DESCRIPTION
        Another owner's forwarders are left alone. A forwarder no owner
        records was installed before owners were recorded, and goes too, as it
        did when this removed every forwarder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$Owner,
        [string]$RuntimeDir
    )
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_e5138cdd99be5619'), (Format-YurunaOperatorMessage -Key 'host.operator_eb750dccc700903d'))) { return $false }
    if (-not (Test-IsAdministrator)) {
        $pendingPorts = Get-YurunaMappedPortFromFirewall
        if ($pendingPorts.Count -gt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9fd9951d4cc1a81d' -Arguments @{ join = "$($pendingPorts -join ', ')" })
        }
        return $false
    }
    $statePath = Get-PortMapStatePath -RuntimeDir $RuntimeDir
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners (Read-YurunaPortMapLedger -Path $statePath) -Discovered (Get-HyperVPortMapPort) -Removing
    foreach ($p in $plan.Release) {
        Remove-SinglePortMap -Port $p -Confirm:$false
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_4730b007bba5b6f7' -Arguments @{ p = "${p}" })
    }
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -Confirm:$false
    return ($plan.Release.Count -gt 0)
}

# --- REGION: Get-BestHostIp
function Get-BestHostIp {
    <#
    .SYNOPSIS
        Return the host's best LAN-routable IPv4 -- for browser-facing URLs, and
        for the address this host publishes to the pool directory.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # See https://yuruna.link/42e5cdfd-002e
    $externalVnic = @()
    try {
        $externalVnic = @(Get-VMSwitch -ErrorAction Stop |
            Where-Object { $_.SwitchType -eq 'External' } |
            ForEach-Object { "vEthernet ($($_.Name))" })
    } catch {
        Write-Verbose "Get-BestHostIp: could not enumerate External vSwitches ($($_.Exception.Message)); using the default route alone to tell a LAN vEthernet from an internal one."
    }

    # Resolved once rather than per address: the same answer for every
    # candidate, and it decides both the filter and the ranking below.
    $gatewayIndex = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        Select-Object -ExpandProperty InterfaceIndex -Unique)

    # PrefixOrigin 'WellKnown' drops loopback and APIPA together; an adapter
    # sitting at 169.254 has not been answered by DHCP, so its address is the
    # absence of one rather than a worse one.
    $ranked = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.PrefixOrigin -ne 'WellKnown' -and
        $_.InterfaceAlias -notmatch 'Pseudo' -and
        ($_.InterfaceAlias -notmatch 'vEthernet' -or
         $externalVnic -contains $_.InterfaceAlias -or
         $gatewayIndex -contains $_.InterfaceIndex)
    } | ForEach-Object {
        $interface      = Get-NetIPInterface -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $hasGateway     = $gatewayIndex -contains $_.InterfaceIndex
        $isExternalVnic = $externalVnic -contains $_.InterfaceAlias
        # See https://yuruna.link/42e5cdfd-002e
        [PSCustomObject]@{
            IPAddress     = $_.IPAddress
            InterfaceName = $_.InterfaceAlias
            Metric        = $interface.InterfaceMetric
            HasGateway    = $hasGateway
            Priority      = ($hasGateway ? 0 : 100000) + ($isExternalVnic ? 0 : 10000) + [int]($interface.InterfaceMetric)
        }
    } | Sort-Object Priority
    return ($ranked | Select-Object -ExpandProperty IPAddress -First 1)
}

# --- REGION: Get-GuestReachableHostIp
function Get-GuestReachableHostIp {
    <#
    .SYNOPSIS
        Returns the host's IPv4 reachable from a guest VM, picked by the
        guest's vSwitch attachment.

    .DESCRIPTION
        Two distinct topologies need two distinct answers:

        * Default Switch (NAT-mode internal): the host has an auto-assigned
          IPv4 on `vEthernet (Default Switch)` (e.g. 172.26.176.1). That's
          the gateway the guest reaches the host at. Caveat: the IP CHANGES
          across host reboots (Microsoft regenerates it from a 172.x.x.x
          pool). A VM provisioned today and reused tomorrow may end up with
          a stale IP baked into /etc/yuruna/host.env -- run
          Test-YurunaHost.ps1 inside the guest to detect; remediation is to
          rebuild the guest VM.

        * External vSwitch (LAN-bridged): the guest gets a real LAN IP via
          DHCP from the LAN router, so `vEthernet (Default Switch)`'s
          172.x.x.x is unreachable from the guest -- it sees the host only
          at the host's LAN IP (e.g. 192.168.7.13). Returning the Default
          Switch IP for an External-attached guest is the bug behind the
          "guest hammers 172.26.176.1:8080" symptom.

        Pass -SwitchName to opt into the right answer. With no parameter,
        legacy callers continue to receive the Default Switch IP for
        backward compatibility.

        An External switch that yields no host IPv4 returns $null rather
        than the Default Switch address: the two are on segments that do not
        route to each other, so the substitute is not a degraded answer but
        a wrong one, and it is wrong in a way the guest can only discover
        after it has booted with it burned into its seed. $null lets the
        caller fall back to its off-LAN source instead.

    .PARAMETER SwitchName
        Hyper-V vSwitch name the guest will be attached to. 'Default Switch'
        returns the Default-Switch host IP; any other name is looked up via
        Get-VMSwitch and the host IPv4 on that switch's segment is returned
        for External-type switches. Falls back to Default-Switch behavior
        for unknown switches so a typo can't strand a guest with $null.

    .PARAMETER SettleTimeoutSeconds
        How long an External-switch lookup keeps polling for a host IPv4
        before reporting none. Covers the address-less window while a
        freshly bridged NIC re-DHCPs.

    .OUTPUTS
        [string] IPv4 address, or $null if no candidate adapter is found.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [int]$SettleTimeoutSeconds = 30
    )

    # Default Switch path (also the legacy no-arg path).
    $isDefault = (-not $SwitchName) -or ($SwitchName -eq 'Default Switch')
    if (-not $isDefault) {
        # Resolve switch type. Unknown switch -> fall back to Default
        # Switch logic so a stale name in a New-VM script doesn't bake
        # an empty value into the seed.iso.
        $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if ($switch -and $switch.SwitchType -eq 'External') {
            # Polls, because a switch bridged moments ago leaves the host
            # briefly address-less while `vEthernet (<switch>)` re-DHCPs.
            $lanIp = Wait-ExternalSwitchHostIpv4 -SwitchName $SwitchName -TimeoutSeconds $SettleTimeoutSeconds
            if ($lanIp) { return $lanIp }
            # Host really is off the LAN. The Default Switch's 172.x.x.x
            # sits on an internal NAT segment this guest holds no route
            # to, so offering it would hand back an address that cannot
            # work rather than admitting there is none.
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_90aa079d7950671d' -Arguments @{ switchName = "$SwitchName"; settleTimeoutSeconds = "${SettleTimeoutSeconds}" })
            return $null
        }
        # See https://yuruna.link/42e220c4-0004
        if ($switch) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f20ec6dc25a27749' -Arguments @{ switchName = "$SwitchName"; switchType = "$($switch.SwitchType)" })
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_eb80b57d92f969a7' -Arguments @{ switchName = "$SwitchName" })
        }
    }

    $defaultSwitchIp = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -like '*Default Switch*' } |
        Select-Object -First 1
    if ($defaultSwitchIp) { return [string]$defaultSwitchIp.IPAddress }
    return $null
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
             IP written by Start-CachingProxyServiceVM.ps1 (our own VM).

        No Hyper-V VM enumeration, no KVP/ARP discovery. Get-CacheVmCandidateIp
        and Get-WorkingCachingProxyServiceUrl still exist for use by the producer
        (guest.caching-proxy-service/New-VM.ps1) and Start-CachingProxyServiceVM.ps1 itself
        while the cache VM is being brought up -- they are not part of the
        steady-state discovery path. LAN-wide cache discovery is a separate
        future feature.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Quiet)
    # Keep platform-specific verification advice in the shared discovery probe.
    # See https://yuruna.link/42e220c4-0004
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'Test-NetConnection {0} -Port {1}' -Quiet:$Quiet
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
    # A host-forwarded URL is not the guest address needed by port mapping.
    # See https://yuruna.link/42e220c4-0004
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-Ipv4Address $ip)) { return $ip }
    return $null
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
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_5657b68f115e9443'), (Format-YurunaOperatorMessage -Key 'host.operator_1d67149dffd75755' -Arguments @{ proxyUrl = "$ProxyUrl" }))) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    Save-YurunaHostProxyBackup -Path $backupPath -ReadState { Read-WindowsProxyState } -PromotedTo $parts.Url
    Set-WindowsHostProxy -ProxyParts $parts -Confirm:$false
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_31ab5c2f0d63be27' -Arguments @{ url = "$($parts.Url)" })
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
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_5657b68f115e9443'), (Format-YurunaOperatorMessage -Key 'host.operator_1bb9777911767c4b'))) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = Read-YurunaHostProxyBackup -Path $backupPath
    if ($state) {
        Restore-WindowsHostProxy -State $state
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_eaa6f26f6eccca85')
    } else {
        Disable-WindowsHostProxy
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_0a0e99400cdc89b7')
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
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_f95b24ace7630162'), (Format-YurunaOperatorMessage -Key 'host.operator_0b42b69cacf83715'))) { return $false }
    Remove-WindowsHostProxy
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_06397ff6173863e8')
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
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
    # Yuruna.Common.psm1's Get-HostProxyBackupPath is the authoritative
    # implementation -- same path on every host. Module-qualified call
    # avoids re-entering OUR function.
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
    return [bool](Assert-HyperVEnabled)
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.VirtualizationRepair.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.ServiceGuest.ps1')

# --- REGION: Exports
Export-ModuleMember -Function Remove-HyperVGuestDefinition, Repair-VMStorageLocation, Resolve-HyperVGuestSwitch, New-HyperVServiceGuest, Wait-HyperVServiceGuestAddress, `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, Test-VirtualizationResponsive, Start-VirtualizationServiceIfStopped, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, Get-VMDiskSnapshotState, `
    Test-VMConsoleOpen, Restart-VMConsole, Set-VMInstallerMediaFirstBoot, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, Update-GuestNeighborCache, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, Repair-YurunaExternalSwitch, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    `
    CreateIso, Get-CacheVmCandidateIp, `
    Get-OrCreateYurunaExternalSwitch, Test-WindowsUplinkNotBridgeable, Test-YurunaExternalSwitchUplink, Test-CachingProxyServicePort, Invoke-YurunaExternalArpProbe, `
    Test-CacheVmOnYurunaExternalSwitch, Get-WorkingCachingProxyServiceUrl, `
    Test-DownloadAlreadyCurrent, Resolve-CacheHostIp, `
    Save-CachedHttpUri, Assert-HyperVEnabled, Get-HyperVFeatureState, Get-HyperVServiceEvidence, Resolve-HyperVVM, `
    Confirm-HyperVVMCreated, Stop-HyperVVMForce, Remove-HyperVTestVM, `
    Start-HyperVVM, Stop-HyperVVM, Request-HyperVVMShutdown, Confirm-HyperVVMStarted, `
    Get-HostMemoryStatus, Format-HostMemoryStatus, Test-HostResourceExhaustionError, Wait-HostMemoryHeadroom, Get-HyperVVMStartupMemory, `
    Test-VMStorageCapacity, `
    Resolve-VMConnectAnotherUserDialog, Restart-HyperVConnect, `
    Test-WindowsProxyIsYurunaManaged, Read-WindowsProxyState, Invoke-WinInetRefresh, `
    Set-WindowsHostProxy, Restore-WindowsHostProxy, Disable-WindowsHostProxy, Remove-WindowsHostProxy, `
    Get-CachingProxyServiceForwarderScriptPath, Get-WindowsForwarderPidPath, `
    Stop-WindowsCachingProxyServiceForwarder, Start-WindowsCachingProxyServiceForwarder, Add-CachingProxyServiceFirewallRule, `
    Get-WindowsForwarderPidPort, Get-YurunaMappedPortFromFirewall, `
    Remove-SinglePortMap, `
    Get-HyperVScreenshot, Get-HyperVWindowScreenshot, Get-VMConsoleSecondOpinion, `
    Start-VMDhcpCapture, Save-VMDhcpCapture, Stop-VMDhcpCapture, `
    Start-VMSerialCapture, Save-VMSerialCapture, Stop-VMSerialCapture, Read-VMSerialCapture, Get-VMCreationTime, Save-VMNetworkState, Save-VMStorageState, `
    Remove-OrphanedVMFileAccess, Disable-HyperVHeartbeatForLinuxGuest, Limit-HyperVLinuxGuestCoreCount, Set-HyperVArm64LinuxGuestProcessorCount, `
    Invoke-HyperVGuestBuildCmdlet

# --- REGION: Contract coverage
# Validate actual exports against the common contract after publishing them.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'windows.hyper-v' `
    -Module $ExecutionContext.SessionState.Module -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot','Get-VMDiskSnapshotState',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac','Update-GuestNeighborCache',
    'Get-ExternalNetwork','New-ExternalNetwork','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization',
    'Test-VirtualizationResponsive','Start-VirtualizationServiceIfStopped'
)

# The driver wrapper must retain cache discovery when shared modules load.
# See https://yuruna.link/42e220c4-0003
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_d190e255da2d0044')
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_92893d28632002d2')
}
