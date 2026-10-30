<#PSScriptInfo
.VERSION 2026.10.30
.GUID 429609dc-4bd8-4362-b3b3-a6e4d5d706f6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver service bundle
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

# --- REGION: Write-UtmBundleConfiguration
function Write-UtmBundleConfiguration {
    <#
    .SYNOPSIS
        Render literal XML values and validate one UTM bundle configuration.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][hashtable]$Replacement, [string]$NetworkMode, [string]$BridgeInterface)
    if (-not $PSCmdlet.ShouldProcess($BundlePath, 'Write UTM configuration')) { return }
    $content = Get-Content -LiteralPath $TemplatePath -Raw -ErrorAction Stop
    foreach ($entry in $Replacement.GetEnumerator()) {
        $content = $content.Replace([string]$entry.Key, [Security.SecurityElement]::Escape([string]$entry.Value))
    }
    if ($NetworkMode -eq 'Shared') {
        $content = $content -replace "(?m)^[ \t]*<key>BridgedInterface</key>\r?\n[ \t]*<string>__BRIDGE_INTERFACE__</string>\r?\n", ''
    } elseif ($NetworkMode) {
        $content = $content.Replace('__BRIDGE_INTERFACE__', [Security.SecurityElement]::Escape($BridgeInterface))
    }
    $path = Join-Path $BundlePath 'config.plist'
    [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
    $result = Invoke-UtmHostTool -Tool 'plutil' -ArgumentList @('-lint', $path) -TimeoutSeconds 10
    if (-not (Test-UtmBoundedResultComplete -Result $result) -or $result.ExitCode -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'host.operator_1f3a41b9c5302d96' -Arguments @{ lintOutput = "$(Get-BoundedNativeOutputLine -Result $result | Out-String)" })
    }
    Write-Verbose "config.plist validated OK: $path"
}

# --- REGION: New-UtmServiceBundleConfiguration
function New-UtmServiceBundleConfiguration {
    <#
    .SYNOPSIS
        Build the common Linux service UTM bundle with service-specific memory and identity.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TemplatePath, [Parameter(Mandatory)][string]$BundlePath,
        [Parameter(Mandatory)][string]$VMName, [Parameter(Mandatory)][string]$NetworkMode,
        [int]$MemoryMb = 2048, [string]$MacAddress)
    if (-not $PSCmdlet.ShouldProcess($BundlePath, 'Configure service bundle')) { return }
    $hostCores = [int](& /usr/sbin/sysctl -n hw.physicalcpu)
    if ($hostCores -lt 4) { throw (Format-YurunaOperatorMessage -Key 'host.operator_b35de16dca777b44' -Arguments @{ hostCores = "$hostCores" }) }
    $bridge = Get-MacDefaultRouteInterface
    if (-not $bridge) { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_15685f8ad1d8fea6'); $bridge = 'en0' }
    $mac = if ($MacAddress) { $MacAddress } else { Get-YurunaGuestMacAddress -VMName $VMName }
    $display = Get-VncDisplayForVm -VMName $VMName
    $values = @{
        '__VM_NAME__' = $VMName; '__VM_UUID__' = [guid]::NewGuid().ToString().ToUpperInvariant()
        '__DISK_IDENTIFIER__' = [guid]::NewGuid().ToString().ToUpperInvariant(); '__DISK_IMAGE_NAME__' = 'disk.qcow2'
        '__SEED_IDENTIFIER__' = [guid]::NewGuid().ToString().ToUpperInvariant(); '__SEED_IMAGE_NAME__' = 'seed.iso'
        '__MAC_ADDRESS__' = $mac; '__NETWORK_MODE__' = $NetworkMode; '__VNC_DISPLAY__' = $display
        '__CPU_COUNT__' = [math]::Max(4, [math]::Floor($hostCores / 2)); '__MEMORY_SIZE__' = $MemoryMb
    }
    Write-UtmBundleConfiguration -TemplatePath $TemplatePath -BundlePath $BundlePath -Replacement $values -NetworkMode $NetworkMode -BridgeInterface $bridge -Confirm:$false
}
