<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4215b6d6-9540-4f18-ba33-7b04aa95cf51
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu.kvm driver service guest
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

# --- REGION: Remove-KvmDomainDefinition
function Remove-KvmDomainDefinition {
    <#
    .SYNOPSIS
        Remove a previous domain definition without deleting its disk artifacts.
    .DESCRIPTION
        The builder that calls this replaces the files in the VM's directory by
        name, so the directory must not hold another domain's disks: a snapshot
        promotion interrupted before its storage move leaves the promoted
        domain's disks there. Such a rename is finished first, and a directory
        that something still uses, or whose use cannot be read, THROWS before
        the builder touches a file in it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove existing domain definition')) { return }
    foreach ($arguments in @(@('destroy', $VMName), @('undefine', '--nvram', '--managed-save', '--snapshots-metadata', '--checkpoints-metadata', $VMName))) {
        $result = Invoke-VirshBounded -VirshArgs $arguments -TimeoutSeconds 30
        Write-Verbose ("virsh {0}: {1}" -f ($arguments -join ' '), ($result | ConvertTo-Json -Compress))
    }
    $listing = Invoke-VirshBounded -VirshArgs @('list', '--all', '--name')
    $names = @(Get-BoundedNativeOutputLine -Result $listing)
    if (-not (Test-DriverNativeResultComplete -Result $listing) -or $listing.ExitCode -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_d43d0cab95add9be' -Arguments @{ vMName = "$VMName"; join = "$($names -join '; ')" })
    }
    if ($names | Where-Object { $_.Trim() -ceq $VMName }) {
        $info = Invoke-VirshBounded -VirshArgs @('dominfo', $VMName)
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9174df31c5ee6350' -Arguments @{ vMName = "$VMName"; dominfo = "$(Get-BoundedNativeOutputLine -Result $info | Out-String)" })
    }
    $vmDir = Join-Path $script:VmRootDir $VMName
    if ((Test-Path -LiteralPath $vmDir) -and -not (Test-KvmDirectoryFreeToDelete -Directory $vmDir)) {
        throw (Format-YurunaOperatorMessage -Key 'host.vm_build_storage_in_use' -Arguments @{ vMName = "$VMName"; vmDir = "$vmDir" })
    }
}

# --- REGION: Resolve-KvmOsVariant
function Resolve-KvmOsVariant {
    <#
    .SYNOPSIS
        Select the first supported guest variant or the generic Linux fallback.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Candidates)
    $result = Invoke-BoundedNativeCommand -FilePath 'virt-install' -ArgumentList @('--osinfo', 'list') -TimeoutSeconds 20
    if ((Test-DriverNativeResultComplete -Result $result) -and $result.ExitCode -eq 0) {
        $ids = @(Get-BoundedNativeOutputLine -Result $result | ForEach-Object { (($_.Trim() -split '[\s,]', 2)[0] -replace ',$', '').Trim() })
        foreach ($candidate in $Candidates) { if ($ids -contains $candidate) { return $candidate } }
    }
    Write-Verbose "osinfo-db lacks a requested guest variant; using linux2022."
    return 'linux2022'
}

# --- REGION: New-KvmServiceDomain
function New-KvmServiceDomain {
    <#
    .SYNOPSIS
        Create a Linux service domain with consistent CPU, disk, network and reboot policy.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$DiskPath,
        [Parameter(Mandatory)][string]$SeedPath, [Parameter(Mandatory)][string]$NetworkName,
        [int]$MemoryMb = 2048, [string]$MacAddress)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Create service domain')) { return $false }
    $virshUri = $script:VirshUri
    $diskImg = $DiskPath
    $seedImg = $SeedPath
    $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ($arch -eq 'Arm64') { $arch = 'aarch64' }
    $osVariant = Resolve-KvmOsVariant -Candidates @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04')
    $hostCores = [int](& nproc --all)
    if ($hostCores -lt 4) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
        return $false
    }
    $vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

    # --- REGION: https://yuruna.link/4220a755-000a
    $YurunaGuestMac = if ($MacAddress) { $MacAddress } else { Get-YurunaGuestMacAddress -VMName $VMName }
    Write-Verbose "Deterministic guest MAC for '$VMName': $YurunaGuestMac"

    $installArgs = @(
        '--connect',    $virshUri,
        '--name',       $VMName,
        '--memory',     "$MemoryMb",
        '--vcpus',      "$vmCores",
        '--cpu',        'host-passthrough',
        '--os-variant', $osVariant,
        '--disk',       "path=$diskImg,format=qcow2,bus=virtio",
        '--disk',       "path=$seedImg,device=cdrom",
        '--network',    "network=$networkName,model=virtio,mac=$YurunaGuestMac",
        '--graphics',   'vnc,listen=127.0.0.1',
        '--channel',    'unix,target_type=virtio,name=org.qemu.guest_agent.0',
        '--events',     'on_reboot=restart',
        '--noautoconsole',
        '--import'
    )
    if ($arch -eq 'aarch64') {
        $installArgs += @('--machine', 'virt', '--boot', 'uefi')
    }

    Write-Verbose "virt-install $($installArgs -join ' ')"
    $installed = Invoke-BoundedNativeCommand -FilePath 'virt-install' -ArgumentList $installArgs -TimeoutSeconds 300
    $virtInstallOutput = @(Get-BoundedNativeOutputLine -Result $installed)
    $virtInstallExit = if (Test-DriverNativeResultComplete -Result $installed) { $installed.ExitCode } else { -1 }
    $virtInstallOutput | ForEach-Object { Write-Verbose "$_" }
    if ($virtInstallExit -ne 0) {
        $virtInstallOutput | ForEach-Object { Write-Information "$_" -InformationAction Continue }
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_d74692e9db12304f' -Arguments @{ virtInstallExit = "$virtInstallExit" })
        return $false
    }
    return $true
}
