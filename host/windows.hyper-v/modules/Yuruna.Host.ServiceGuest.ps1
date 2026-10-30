<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42bfb844-2da5-4372-8912-d611d68edee6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver service guest
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

# --- REGION: Remove-HyperVGuestDefinition
function Remove-HyperVGuestDefinition {
    <#
    .SYNOPSIS
        Replace a known VM definition while leaving disk cleanup to the builder.
    .DESCRIPTION
        The builder that calls this replaces the files in the VM's directory by
        name, so the directory must not hold another VM's disks: a snapshot
        promotion interrupted before its storage move leaves the promoted VM's
        disks there, whether or not a VM of this name still exists. Such a
        rename is finished first, and a directory that something still uses, or
        whose use cannot be read, THROWS before the builder touches a file in it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$VMName)
    $existing = Resolve-HyperVVM -VMName $VMName
    if ($existing.Presence -eq 'unknown') { throw "Cannot determine whether VM '$VMName' exists; no VM or disk changes were made." }
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove existing VM definition')) { return }
    if ($existing.Presence -eq 'present') {
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_96658c0e8ad547f3' -Arguments @{ vMName = "$VMName" }) -InformationAction Continue
        # The resolved VM object, not the name: a name with wildcard
        # characters would match others.
        $null = Invoke-HyperVBoundedCall -ArgumentList @($existing.VM) -ScriptBlock {
            param($Vm)
            Hyper-V\Stop-VM -VM $Vm -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
        }
        try {
            $null = Invoke-HyperVLifecycleCmdlet -Verb 'Remove-VM' -VMName $VMName -ArgumentList @($existing.VM) -ScriptBlock {
                param($Vm)
                Hyper-V\Remove-VM -VM $Vm -Force -ErrorAction Stop
            }
        } catch {
            $diag = $existing.VM | Format-List Name, State, Status, Generation, Path | Out-String
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_1c714189825ec0e2' -Arguments @{ vMName = "$VMName"; message = "$($_.Exception.Message)"; diag = "$diag" })
        }
        $after = Resolve-HyperVVM -VMName $VMName
        if ($after.Presence -ne 'absent') {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.host_634b857addaa8df5' -Arguments @{ vMName = "$VMName" })
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_86f314067f7955de' -Arguments @{ vMName = "$VMName" }) -InformationAction Continue
    }
    $vhdRoot = (Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath
    if ($vhdRoot) {
        $vmDir = Join-Path $vhdRoot $VMName
        if ((Test-Path -LiteralPath $vmDir) -and -not (Test-HyperVDirectoryFreeToDelete -Directory $vmDir)) {
            throw (Format-YurunaOperatorMessage -Key 'host.vm_build_storage_in_use' -Arguments @{ vMName = "$VMName"; vmDir = "$vmDir" })
        }
    }
}

# --- REGION: Resolve-HyperVGuestSwitch
function Resolve-HyperVGuestSwitch {
    <#
    .SYNOPSIS
        Resolve a usable external switch or an existing fallback.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $name = Get-OrCreateYurunaExternalSwitch
    if ($name) { return $name }
    $name = 'Default Switch'
    if (-not (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue)) {
        $fallback = Get-VMSwitch -ErrorAction SilentlyContinue | Sort-Object @{ Expression = { $_.SwitchType -eq 'External' } }, Name | Select-Object -First 1
        if (-not $fallback) { throw 'No Hyper-V switch is available for the guest.' }
        $name = $fallback.Name
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_38edbb4cc8da6eb6' -Arguments @{ switchName = "$name" })
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_6ec7fa5a08a2eb27' -Arguments @{ switchName = "$name" })
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_9bb7f114ca4530e9')
    return $name
}

# --- REGION: New-HyperVServiceGuest
function New-HyperVServiceGuest {
    <#
    .SYNOPSIS
        Configure the fixed-memory Linux service guest before its first boot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$DiskPath, [Parameter(Mandatory)][string]$SeedPath,
        [Parameter(Mandatory)][int]$HostCores, [int]$MemoryMb = 2048, [string]$MacAddress)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Create Linux service VM')) { return }
    $memory = [int64]$MemoryMb * 1MB
    $mac = if ($MacAddress) { $MacAddress } else { Get-YurunaGuestMacAddress -VMName $VMName }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_b0bde9c66516dc8a' -Arguments @{ vMName = "$VMName"; switchName = "$SwitchName" }) -InformationAction Continue
    Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $memory -SwitchName $SwitchName -VHDPath $DiskPath | Out-Null
    Hyper-V\Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress ($mac -replace ':', '')
    Set-VM -Name $VMName -MemoryStartupBytes $memory -MemoryMinimumBytes $memory -MemoryMaximumBytes $memory -AutomaticCheckpointsEnabled $false | Out-Null
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null
    $null = Disable-HyperVHeartbeatForLinuxGuest -VMName $VMName -Confirm:$false
    Add-VMDvdDrive -VMName $VMName -Path $SeedPath | Out-Null
    $cores = Limit-HyperVLinuxGuestCoreCount -RequestedCores ([math]::Max(4, [math]::Floor($HostCores / 2)))
    Set-VMProcessor -VMName $VMName -Count $cores | Out-Null
}

# --- REGION: Wait-HyperVServiceGuestAddress
function Wait-HyperVServiceGuestAddress {
    <#
    .SYNOPSIS
        Poll KVP and bridge neighbors for service guest addresses on a wall-clock deadline.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$SwitchName,
        [int]$TimeoutSeconds = 600, [string]$Activity, [scriptblock]$ProgressDetail)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $activityText = if ($Activity) { $Activity } else { "Waiting for '$VMName' to obtain an IP" }
    $external = ((Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue).SwitchType -eq 'External')
    $announced = $false
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $record = Resolve-HyperVVM -VMName $VMName
            $vm = $record.VM
            if ($vm) {
                $adapter = $vm | Get-VMNetworkAdapter -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($external -and $adapter.SwitchName -eq $SwitchName -and $clock.Elapsed.TotalSeconds -ge 30) {
                    if (-not $announced) {
                        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_86ae3482cd8932d7' -Arguments @{ switchName = "$SwitchName" }) -InformationAction Continue
                        $announced = $true
                    }
                    Invoke-YurunaExternalArpProbe -SwitchName $SwitchName
                }
                $addresses = @(Get-CacheVmCandidateIp -VM $vm)
                if ($addresses.Count -gt 0) {
                    $mac = [string]$adapter.MacAddress
                    $mac = if ($mac -match '^[0-9A-Fa-f]{12}$') { ($mac -replace '(..)(?!$)', '$1-').ToUpperInvariant() } else { '(unknown)' }
                    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_711aec356a249726' -Arguments @{ vmMacDashed = "$mac" }) -InformationAction Continue
                    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_c31ff5024871e3cc' -Arguments @{ vMName = "$VMName"; join = "$($addresses -join ', ')" }) -InformationAction Continue
                    return $addresses
                }
            }
            $elapsed = [int]$clock.Elapsed.TotalSeconds
            $status = if ($ProgressDetail) { & $ProgressDetail $elapsed $vm } else { "elapsed ${elapsed}s" }
            Write-Progress -Activity $activityText -Status $status -PercentComplete ([math]::Min(100, $elapsed * 100 / $TimeoutSeconds)) -SecondsRemaining ([math]::Max(0, $TimeoutSeconds - $elapsed))
            Start-Sleep -Milliseconds ([int][math]::Min(5000, [math]::Max(1, ($TimeoutSeconds - $clock.Elapsed.TotalSeconds) * 1000)))
        }
        return @()
    } finally { Write-Progress -Activity $activityText -Completed }
}
