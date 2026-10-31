<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42bd906d-30b3-44f2-9020-fea9dbf0805f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos utm
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.RELEASENOTES
    Yuruna host driver for macOS + UTM. Implements the Yuruna.Host
    driver contract defined in host/Yuruna.Host.Contract.psm1 (rationale in docs/host-io.md).
#>

#requires -version 7

<#
.SYNOPSIS
    Yuruna host driver for macOS + UTM (Apple Silicon and Intel).

.DESCRIPTION
    Self-contained host driver: contract surface plus the UTM/macOS
    helpers it consumes. Cross-host helpers live in
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
$script:HostTag        = 'host.macos.utm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/macos.utm'

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
    if ([string]::IsNullOrWhiteSpace($script:HostTag)) { $script:HostTag = 'host.macos.utm' }
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
# See https://yuruna.link/42e220c4-0004
Import-Module (Join-Path $script:TestModulesDir 'Test.HostCondition.Mac.psm1') -Global -DisableNameChecking
$macSessionCommand = Get-Command -Name 'Get-MacSessionKind' -CommandType Function -ErrorAction SilentlyContinue
if (-not (Get-Command -Name 'Get-MacUtmctlBundlePath' -CommandType Function -ErrorAction SilentlyContinue) -or
    -not ($macSessionCommand -and $macSessionCommand.Parameters.ContainsKey('TimeoutSeconds'))) {
    Import-Module (Join-Path $script:TestModulesDir 'Test.HostCondition.Mac.psm1') -Global -Force -DisableNameChecking
}
Remove-Variable -Name 'macSessionCommand' -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot 'Yuruna.Host.UtmHelpers.ps1')

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
    $ip = (Read-CachingProxyServiceState).ipAddress
    if ($ip -and (Test-IpAddress $ip) -and (Test-CachingProxyServicePort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    if (Test-CachingProxyServicePort -IpAddress '127.0.0.1' -Port $httpPort -TimeoutMs 500) {
        return '127.0.0.1'
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
        # UTM currently has no per-VM nested-virtualization setting.
        [string]$ExposeVirtualizationExtensions
    )
    # Preserve bound overrides and -WhatIf/-Confirm in the shared runner.
    # See https://yuruna.link/42ec97cd-0017
    Invoke-PerGuestNewVm -HostSubdir 'host/macos.utm' @PSBoundParameters
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
    return Start-UtmVM -VMName $VMName -Confirm:$false
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
        # When set, confirms the VM reports stopped within this many seconds
        # after the power-off request; 0 reports only that the request was sent.
        [int]$ShutdownTimeoutSeconds = 0,
        # Accepted for contract parity: this driver never escalates on its own.
        [switch]$NoForce
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? (Format-YurunaOperatorMessage -Key 'host.operator_872a5355019f83c5') : (Format-YurunaOperatorMessage -Key 'host.operator_156e139837bd477d')))) { return $false }
    if ($NoForce) { Write-Verbose 'Stop-VM: -NoForce is the default on UTM; the power-off request is never escalated here.' }
    if ($Force) { return [bool](Stop-VMForce -VMName $VMName -Confirm:$false) }
    $requested = [bool](Stop-UtmVM -VMName $VMName -Confirm:$false)
    if (-not $requested -or $ShutdownTimeoutSeconds -le 0) { return $requested }
    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VMState -VMName $VMName) -in @('stopped', 'absent')) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# --- REGION: Stop-VMForce
function Stop-VMForce {
    <#
    .SYNOPSIS
        Force-stop a UTM VM via `utmctl stop --kill`, bounded by -StopTimeoutSeconds.
    .DESCRIPTION
        --kill hard-kills the VM process instead of sending the power-off event,
        so the qcow2 write lock is released without waiting on an ACPI shutdown
        that a busy or mid-reboot guest may ignore. The whole call is bounded by
        -StopTimeoutSeconds (and by -Deadline when one is given). $true only for
        a call that completed, exited 0 and printed no Apple Event failure:
        utmctl exits 0 on a denial, so the exit code alone would report a kill
        that never reached UTM.
    .PARAMETER StopTimeoutSeconds
        Cap for the whole call, clamped to 1..600. The dialog-watchdog stop that
        precedes the kill gets a short slice of it -- two seconds at most, half
        the cap at most -- and the kill the whole seconds that remain, never
        fewer than one: a kill that is never attempted helps nobody, so the call
        can end up to a fraction of a second past the cap, not twice the cap.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20,
        $Deadline
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_8ba70db3f3e461cb'))) { return $false }
    $cap = [Math]::Max(1, [Math]::Min(600, $StopTimeoutSeconds))
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Stop-UtmDialogWatchdog -Deadline (Get-UtmChildDeadline -Milliseconds ([Math]::Min([long]2000, [long]$cap * 500)) -Parent $Deadline)
    $killCap = [int][Math]::Max(1, $cap - [Math]::Floor($stopwatch.ElapsedMilliseconds / 1000.0))
    $kill = Invoke-UtmctlLifecycle -Verb 'stop' -VMName $VMName -Kill -TimeoutSeconds $killCap -Deadline $Deadline
    return [bool]($kill.OutcomeKnown -and $kill.ExitCode -eq 0 -and $kill.FailureKind -eq 'none')
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
    return [bool](Remove-UtmTestVM -VMName $VMName -Confirm:$false)
}

# --- REGION: Rename-VM
function Rename-VM {
    <#
    .SYNOPSIS
        Rename a stopped UTM VM by editing its .utm bundle and UTM's Registry
        plist while UTM.app is quit.
    .DESCRIPTION
        UTM exposes no rename verb in utmctl, and macOS 26 builds mark the
        AppleScript `name` property of `virtual machine` as read-only
        (osascript fails with -10006). The reliable workaround is on-disk
        surgery while UTM is offline:

          1. Quit UTM.app through Stop-UtmApplication (UTM and its QEMUHelper
             children, this user only) so cfprefsd flushes the in-memory
             Registry to its plist on disk, then flush cfprefsd's cache so our
             subsequent edits aren't clobbered.
          2. Rename `<guest.nosync>/<VMName>.utm` -> `<guest.nosync>/<NewName>.utm`.
             The qcow2 disks (including snapshots written by Save-VMDiskSnapshot)
             move with the bundle.
          3. PlistBuddy: set `:Information:Name` in the new bundle's
             config.plist to NewName.
          4. PlistBuddy: set `:Registry:<UUID>:Name` and
             `:Registry:<UUID>:Package:Path` inside
             `~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist`.
          5. Relaunch through Start-UtmApplication, flushing cfprefsd first so
             UTM re-reads our edited plist.
          6. Resume the service VMs that step 1 took down (see below), then poll
             until the new name surfaces.

        Step 1 is not free for the rest of the host. UTM saves the state of
        every VM still running as it terminates, so any service VM that was up
        -- the caching proxy, the stash service, pool-control -- returns as
        `suspended` and stays there. Guests consume those services for the
        whole cycle, so the running set is captured before the quit and
        resumed after the relaunch, exactly once on every path out of this
        function that follows the quit. The capture must be a listing that was
        actually read: when it cannot be read, UTM is not quit at all, because
        quitting with an empty capture would strand every service suspended.
        Services are resumed only after a CONFIRMED relaunch (the launch was
        acknowledged and UTM observed for this user); an unconfirmed relaunch
        names the services left suspended and the commands that resume them.

        The stop passes -AllowHardStop: UTM and helpers that ignore the quit
        are signaled, UTM first and helpers last, each identity revalidated
        right before its signal. A stop that still is not confirmed ends the
        rename before any edit.

        The Package.Bookmark blob is left untouched: macOS file bookmarks
        resolve via catalog inode + volume UUID, so a directory rename within
        the same volume continues to resolve to the new path.

        Requires the VM to be stopped (UTM holds an exclusive lock on the
        bundle while running). Caller (Save-VMDiskSnapshot) handles the stop.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_6d832084f2cb44cf' -Arguments @{ newName = "$NewName" }))) { return $false }
    if ($VMName -eq $NewName) { return $true }
    if ($VMName -match '[/"\\]' -or $NewName -match '[/"\\]') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b3adfc0d608ac6e8' -Arguments @{ vMName = "$VMName"; newName = "$NewName" })
        return $false
    }
    # A positive 'stopped' source and a positive 'absent' destination, never
    # merely "not the value we are refusing on": a denied or timed-out probe
    # reads as 'unknown', not 'absent', so requiring the positive state on
    # both sides -- and refusing outright on 'unknown' -- is what keeps an
    # unanswered probe from reaching the mutation further down.
    $srcState = Get-VMState -VMName $VMName
    if ($srcState -ne 'stopped') {
        switch ($srcState) {
            'absent'  { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_524e2803f12e1efa' -Arguments @{ vMName = "$VMName" }) }
            'running' { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_697963516e07c1d1' -Arguments @{ vMName = "$VMName" }) }
            default   { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_476ac9f4728142ba' -Arguments @{ vMName = "$VMName" }) }
        }
        return $false
    }
    $dstState = Get-VMState -VMName $NewName
    if ($dstState -ne 'absent') {
        if ($dstState -eq 'unknown') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8325345b98bdf237' -Arguments @{ newName = "$NewName" })
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f69adb6b2f614a13' -Arguments @{ newName = "$NewName" })
        }
        return $false
    }

    $guestDir  = "$HOME/yuruna/guest.nosync"
    $srcBundle = Join-Path $guestDir "$VMName.utm"
    $dstBundle = Join-Path $guestDir "$NewName.utm"
    $srcConfig = Join-Path $srcBundle 'config.plist'
    if (-not (Test-Path -LiteralPath $srcConfig)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_15b9626a689d8633' -Arguments @{ srcConfig = "$srcConfig" })
        return $false
    }
    if (Test-Path -LiteralPath $dstBundle) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b89811c24b571c30' -Arguments @{ dstBundle = "$dstBundle" })
        return $false
    }

    # UUID is the only stable key in UTM's Registry; read it from the
    # bundle's own config.plist rather than parsing `defaults` output.
    $uuidRead = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', 'Print :Information:UUID', $srcConfig) -TimeoutSeconds 10
    $uuid = "$($uuidRead.StdOut)$($uuidRead.StdErr)".Trim()
    if (-not (Test-UtmBoundedResultComplete -Result $uuidRead) -or $uuidRead.ExitCode -ne 0 -or $uuid -notmatch '^[0-9A-Fa-f-]{36}$') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5e409de2ac1c55b7' -Arguments @{ srcConfig = "$srcConfig"; uuid = "$uuid" })
        return $false
    }

    $utmPrefs = "$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist"
    if (-not (Test-Path -LiteralPath $utmPrefs)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_76727d9ff6fe99e5' -Arguments @{ utmPrefs = "$utmPrefs" })
        return $false
    }

    # See https://yuruna.link/42e5cdfd-0007
    $inventory = Get-UtmRunningVmInventory
    if (-not $inventory.Listed) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_inventory_unavailable' -Arguments @{ reason = "$($inventory.Reason)"; vmName = "$VMName" })
        return $false
    }
    $serviceVmName = @(Get-YurunaServiceVmName)
    $serviceVmToResume = @($inventory.Name | Where-Object { $serviceVmName -contains $_ })

    # Quit UTM so cfprefsd flushes the Registry to disk before our edits;
    # the flush afterwards drops cfprefsd's cache so PlistBuddy reads and
    # writes go straight to the plist file.
    $stop = Stop-UtmApplication -QuitWaitSeconds $script:UtmRenameQuitWaitSeconds -AllowHardStop -FlushPreferenceCache -Confirm:$false
    if ($stop.Outcome -in @('refused', 'deadline-exhausted', 'preview')) {
        # The quit was never sent: UTM is exactly as it was, so there is
        # nothing to relaunch and nothing to resume.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_stop_unconfirmed' -Arguments @{ outcome = "$($stop.Outcome)"; vmName = "$VMName" })
        return $false
    }

    # From here on the quit was sent, so every exit relaunches UTM and resumes
    # the captured services exactly once -- in the finally below, which is
    # scoped to the code after the quit. The preference cache is flushed
    # before the relaunch only once plist edits exist to be re-read.
    $flushOnRelaunch = $false
    $renamed = $false
    try {
        if (-not $stop.Stopped) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_stop_unconfirmed' -Arguments @{ outcome = "$($stop.Outcome)"; vmName = "$VMName" })
            return $false
        }

        try {
            Rename-Item -LiteralPath $srcBundle -NewName "$NewName.utm" -ErrorAction Stop
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5c039b0b7884d16b' -Arguments @{ srcBundle = "$srcBundle"; dstBundle = "$dstBundle"; message = "$($_.Exception.Message)" })
            return $false
        }

        $dstConfig = Join-Path $dstBundle 'config.plist'
        $nameSet = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Information:Name $NewName", $dstConfig) -TimeoutSeconds 10
        if (-not (Test-UtmBoundedResultComplete -Result $nameSet) -or $nameSet.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b6e0da77ab1ba6b5' -Arguments @{ dstConfig = "$dstConfig" })
            try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
            catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
            return $false
        }

        $registryName = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Registry:${uuid}:Name $NewName", $utmPrefs) -TimeoutSeconds 10
        $regExitName = if (Test-UtmBoundedResultComplete -Result $registryName) { [int]$registryName.ExitCode } else { -1 }
        $registryPath = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Registry:${uuid}:Package:Path $dstBundle", $utmPrefs) -TimeoutSeconds 10
        $regExitPath = if (Test-UtmBoundedResultComplete -Result $registryPath) { [int]$registryPath.ExitCode } else { -1 }
        if ($regExitName -ne 0 -or $regExitPath -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_50978cbbff00be18' -Arguments @{ uuid = "$uuid"; regExitName = "$regExitName"; regExitPath = "$regExitPath" })
            # Best-effort revert: undo plist Name + bundle rename so the
            # next cycle sees a coherent state. The Registry may already hold
            # a partial edit, so the relaunch re-reads it from disk.
            $null = Invoke-UtmHostTool -Tool 'plistbuddy' -ArgumentList @('-c', "Set :Information:Name $VMName", $dstConfig) -TimeoutSeconds 10
            try { Rename-Item -LiteralPath $dstBundle -NewName "$VMName.utm" -ErrorAction Stop }
            catch { Write-Debug "Rename-VM revert: bundle rename back failed: $_" }
            $flushOnRelaunch = $true
            return $false
        }

        # See https://yuruna.link/42e5cdfd-0007
        $bundleMac = [string]((Get-UtmBundleNetwork -VMName $NewName).MacAddress)
        $renameMac = Resolve-YurunaRenameMac -MacAddress $bundleMac -VMName $VMName -NewName $NewName
        $renameMacAfter = $bundleMac
        if ($renameMac) {
            if (Set-GuestMacInBundle -VMName $NewName -MacAddress $renameMac -Confirm:$false) {
                $renameMacAfter = $renameMac
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fc7e4d718a95d1a2' -Arguments @{ vMName = "$VMName"; newName = "$NewName" })
            }
        }
        Register-YurunaRenameMac -VMName $VMName -NewName $NewName -Before $bundleMac -After $renameMacAfter

        # See https://yuruna.link/42e5cdfd-0007
        $wantDisplay = Find-FreeVncDisplay `
            -Preferred (Get-VncDisplayForVm -VMName $NewName) `
            -ExcludeDisplays (Get-ClaimedVncDisplay -ExcludeVMName $NewName)
        if ($wantDisplay -lt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_844a212ddde38874' -Arguments @{ newName = "$NewName"; newName2 = "$(Get-VncDisplayFromBundle -VMName $NewName)" })
        } elseif ((Get-VncDisplayFromBundle -VMName $NewName) -ne $wantDisplay) {
            if (Set-VncDisplayInBundle -VMName $NewName -Display $wantDisplay -Confirm:$false) {
                Write-Verbose "Rename-VM: VNC display for '$NewName' set to $wantDisplay (port $(5900 + $wantDisplay))."
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8e1418fef79d70dd' -Arguments @{ newName = "$NewName"; newName2 = "$(Get-VncDisplayFromBundle -VMName $NewName)" })
            }
        }

        # Force cfprefsd to reload from our edited file on the relaunch.
        $flushOnRelaunch = $true
        $renamed = $true
    } finally {
        $relaunch = Start-UtmApplication -LaunchWaitSeconds $script:UtmRenameLaunchWaitSeconds -FlushPreferenceCache:$flushOnRelaunch -Confirm:$false
        if ($relaunch.Started) {
            # See https://yuruna.link/42e5cdfd-0007
            $resumeFailed = @(Resume-YurunaServiceVM -VMName $serviceVmToResume -Confirm:$false)
            if ($renamed -and $resumeFailed.Count -gt 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_84987470d9b561d8' -Arguments @{ newName = "$NewName"; count = "$($resumeFailed.Count)"; join = "$($resumeFailed -join ', ')"; join2 = "$(($resumeFailed | ForEach-Object { "utmctl start '$_'" }) -join '; ')" })
            }
        } elseif ($serviceVmToResume.Count -gt 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.rename_vm_relaunch_unconfirmed' -Arguments @{ outcome = "$($relaunch.Outcome)"; names = "$($serviceVmToResume -join ', ')"; commands = "$(($serviceVmToResume | ForEach-Object { "utmctl start '$_'" }) -join '; ')" })
        }
    }

    # Only the completed rename reaches here: every failure path returned
    # from inside the try after its relaunch and resume ran. The services
    # were resumed above whether or not the new name surfaces, because the
    # quit took them down either way.
    $surfaceDeadline = New-YurunaDeadline -TotalMilliseconds $script:UtmRenameSurfaceWaitMilliseconds
    $surfaced = $false
    while (-not (Test-YurunaDeadlineExpired -Deadline $surfaceDeadline)) {
        # Only a positive valid state counts as surfaced: an 'unknown' read
        # here (UTM still ingesting, or a denied probe) must keep polling,
        # not be read as "not there yet" and then time out looking identical
        # to a rename that never took.
        $polled = Get-VMState -VMName $NewName
        if ($polled -eq 'running' -or $polled -eq 'stopped') { $surfaced = $true; break }
        $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $surfaceDeadline
    }
    if ($surfaced) { return $true }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_20dac0c25f3fe7a9' -Arguments @{ newName = "$NewName" })
    return $false
}

<#
.SYNOPSIS
    Bring the named service VMs back to `started` after UTM.app has been
    quit and relaunched. Returns the names that did NOT come back.

.DESCRIPTION
    UTM saves the state of every running VM on its way out, so a VM that
    was `started` before UTM was quit is `suspended` when UTM returns --
    and it stays that way, because nothing resumes it automatically. For
    the service VMs that is not a cosmetic difference: guests take their
    packages through the caching proxy, the build uploads to the stash
    service, and the configuration store is served by pool-control, so every one
    of those consumers fails for as long as the service sits suspended.

    `utmctl start` is also the resume verb -- on a suspended VM it
    restores the saved state instead of cold-booting -- so a caller can
    restore the pre-quit set without having to know whether UTM chose to
    suspend or to fully stop each one. That is the only start issued here:
    never Start-UtmVM or Start-VM, which delete the saved state to force a
    cold boot, and nothing here touches the bundle's saved state.

    A start is issued only from a positive 'stopped' reading; 'absent' and
    'unknown' are waited through and then reported, never started.

    Best-effort by design. A caller reaches this only after its own work
    is done, and a service that refuses to come back is something for the
    operator to see, not a reason to report that work as failed.

.PARAMETER VMName
    Names captured (while UTM was still up) as `started`. Empty is fine.

.PARAMETER TimeoutSeconds
    Per-VM budget covering re-registration, the start and its settle.

.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline) for the whole set: each
    VM gets the smaller of -TimeoutSeconds and what remains of it, so
    several services draw on one reserve instead of each adding its own.

.PARAMETER NoDialogWatchdog
    Do not start the UTM dialog watchdog around each start. A caller that
    must not auto-click dialogs passes it; a dialog that then blocks the
    start leaves the service unresolved.

.PARAMETER Detailed
    Emit one record per VM instead of the failed names.

.OUTPUTS
    [string[]] the names that did not return to `started`; empty on full
    success. Callers must normalize with `@(...)`. With -Detailed, one
    [pscustomobject] per VM: VMName, Outcome ('running' | 'resumed' |
    'absent' | 'unknown' | 'start-failed' | 'unresolved' |
    'deadline-exhausted'), Reason, Attempts.
#>
function Resume-YurunaServiceVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]], [pscustomobject])]
    param(
        [string[]]$VMName,
        [int]$TimeoutSeconds = 90,
        $Deadline,
        [switch]$NoDialogWatchdog,
        [switch]$Detailed
    )
    $names = @($VMName | Where-Object { $_ })
    if ($names.Count -eq 0) { return }
    $failed = New-Object System.Collections.Generic.List[string]
    $records = New-Object System.Collections.Generic.List[object]
    $note = {
        param([string]$Name, [string]$Outcome, [string]$Reason, [int]$Attempts)
        $records.Add([pscustomobject]@{ PSTypeName = 'Yuruna.ServiceVmResume'; VMName = $Name; Outcome = $Outcome; Reason = $Reason; Attempts = $Attempts })
        if ($Outcome -notin @('running', 'resumed')) { [void]$failed.Add($Name) }
    }
    foreach ($name in $names) {
        if (-not $PSCmdlet.ShouldProcess($name, (Format-YurunaOperatorMessage -Key 'host.operator_87abce329e878b18'))) { continue }
        if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.utm_resume_deadline_exhausted' -Arguments @{ name = "$name" })
            & $note $name 'deadline-exhausted' 'deadline-exhausted' 0
            continue
        }
        # One deadline per VM, never later than the shared one: registration,
        # the start and its settle all draw on it.
        $vmDeadline = New-YurunaDeadline -TotalMilliseconds ([long][Math]::Max(0, $TimeoutSeconds) * 1000)
        if ($Deadline) { $vmDeadline = Get-UtmChildDeadline -Milliseconds ([long][Math]::Max(0, $TimeoutSeconds) * 1000) -Parent $Deadline }
        # See https://yuruna.link/42e5cdfd-0006
        $reading = $null
        while (-not (Test-YurunaDeadlineExpired -Deadline $vmDeadline)) {
            $next = Get-VMStateRecord -VMName $name -Deadline $vmDeadline
            if (-not $reading -or $next.Reason -ne 'deadline-exhausted') { $reading = $next }
            if ($reading.State -eq 'running' -or $reading.State -eq 'stopped') { break }
            $null = Wait-UtmInterval -Milliseconds $script:UtmStatePollMilliseconds -Deadline $vmDeadline
        }
        $state  = if ($reading) { [string]$reading.State } else { 'unknown' }
        $reason = if ($reading) { [string]$reading.Reason } else { 'deadline-exhausted' }
        if ($state -eq 'running') { & $note $name 'running' $reason 0; continue }
        if ($state -eq 'absent') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_a986b71028c74af3' -Arguments @{ name = "$name"; timeoutSeconds = "$TimeoutSeconds" })
            & $note $name 'absent' $reason 0
            continue
        }
        if ($state -ne 'stopped') {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_dbd4e4ba20849958' -Arguments @{ name = "$name"; timeoutSeconds = "$TimeoutSeconds" })
            & $note $name 'unknown' $reason 0
            continue
        }
        # See https://yuruna.link/42e5cdfd-0006
        if (-not $NoDialogWatchdog) { Start-UtmDialogWatchdog }
        try {
            # The retry budget is spread ACROSS the VM's deadline rather than
            # added on top of it, so a caller's timeout still means what it
            # says while a momentary refusal can use up to three attempts.
            $remainingMs   = Get-YurunaDeadlineRemainingMs -Deadline $vmDeadline
            $settleSeconds = [Math]::Max(1, [Math]::Min([int]($TimeoutSeconds / 3), [int]($remainingMs / 1000)))
            $start = Invoke-UtmVMStartWithRetry -VMName $name -Confirm:$false `
                -SettleSeconds $settleSeconds -Deadline $vmDeadline
        } finally {
            if (-not $NoDialogWatchdog) { Stop-UtmDialogWatchdog }
        }
        if ($start.success) {
            Write-Verbose "Resume-YurunaServiceVM: '$name' is running again (attempt $($start.attempts))."
            & $note $name 'resumed' 'started' ([int]$start.attempts)
        } else {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_126a49ca0c55779b' -Arguments @{ name = "$name"; errorMessage = "$($start.errorMessage)" })
            $outcome = if ($start.kind -eq 'unresolved') { 'unresolved' } else { 'start-failed' }
            & $note $name $outcome ([string]$start.kind) ([int]$start.attempts)
        }
    }
    if ($Detailed) { return $records.ToArray() }
    return $failed.ToArray()
}

# --- REGION: Get-VMState
function Get-VMState {
    <#
    .SYNOPSIS
        Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
    .DESCRIPTION
        'unknown' covers everything that is not a positively recognized answer:
        no utmctl on PATH or in the UTM bundle, a launch failure, a timeout, a
        denied Apple Event, "does not work from SSH", output that did not finish
        draining, or any other unrecognized answer. Only a completed response
        that names the VM as not found is 'absent'. Callers treat 'absent' as
        license to build or reuse a name (Start-CachingProxyServiceVM.ps1,
        Debug-TestSequence.ps1, Test.Orchestrator, Test.SnapshotManifest,
        Rename-VM's preconditions, Remove-UtmVMRegistration) and
        Restore-YurunaServiceVM treats it as "not built on this host" -- a probe
        UTM merely refused to answer must never produce that, least of all on a
        host whose UTM has stopped answering. Get-VMStateRecord returns the same
        answer with its reason.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    return [string](Get-VMStateRecord -VMName $VMName).State
}

<#
.SYNOPSIS
    The VM's state as a record: the state Get-VMState returns, the raw
    status word, registration evidence and the reason.
.DESCRIPTION
    One bounded `utmctl status` call, classified by
    ConvertFrom-UtmctlStatusResult; Get-VMState and
    Get-UtmVMRegistrationState are both read from this record, so the state
    and the registration can never disagree about one answer. With -Deadline
    the call gets at most what the deadline has left, and nothing is
    launched when under one second remains.
.PARAMETER VMName
    The VM to read.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.PARAMETER TimeoutSeconds
    This call's own cap.
.OUTPUTS
    [pscustomobject] VMName, State ('running' | 'stopped' | 'absent' |
    'unknown'), RawState, Registration ('Registered' | 'Absent' | 'Unknown'),
    Reason ('observed' | 'not-found' | 'missing-client' | 'timeout' |
    'permission-denied' | 'no-session' | 'provider-error' | 'invalid-response'
    | 'deadline-exhausted'), ExitCode, ElapsedMs.
#>
function Get-VMStateRecord {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        $Deadline,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $resolver = Resolve-UtmctlExecutable
    $probe = if ($resolver.Source -eq 'missing') {
        @{ ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $false; DeadlineExhausted = $false }
    } else {
        Invoke-UtmctlProbe -Arguments @('status', $VMName) -TimeoutSeconds $TimeoutSeconds -UtmctlPath $resolver.Path -Deadline $Deadline
    }
    $classified = ConvertFrom-UtmctlStatusResult -Result $probe
    return [pscustomobject]@{
        PSTypeName   = 'Yuruna.UtmVMState'
        VMName       = $VMName
        State        = $classified.State
        RawState     = $classified.RawState
        Registration = $classified.Registration
        Reason       = $classified.Reason
        ExitCode     = [int]$probe['ExitCode']
        ElapsedMs    = $stopwatch.ElapsedMilliseconds
    }
}

# --- REGION: VM inventory
# --- REGION: Get-VMName
function Get-VMName {
    <#
    .SYNOPSIS
        Return the names of every VM registered with UTM, optionally filtered
        to those starting with one of $Prefix.
    .DESCRIPTION
        Host-neutral inventory call (see the contract's VM inventory block).
        Every VM UTM knows about is returned regardless of run state, so a
        caller sweeping by prefix removes stopped leftovers as well as
        running ones.

        THROWS when utmctl cannot reach UTM.app rather than returning an
        empty list. utmctl exits 0 and prints its error to stderr when Apple
        Events are denied (OSStatus -1743, typical from an SSH session or a
        process without Automation access), when a request times out (-1712),
        and for other Apple Event faults besides -- so an exit-code check alone
        reads "cannot ask" as "nothing registered". A sweep that accepted that
        empty list would report a clean host, and the orphan-file pass behind
        it would delete bundles UTM still has registered.

        Matched on ANY Apple Event wording the driver recognizes -- any OSStatus
        code, a denial, a timeout, an SSH session -- rather than an enumerated
        few. The set that can appear here is open, the consequence of missing one
        is deleting a VM's disk, and there is no OSStatus value whose correct
        reading is "believe the empty list". A listing that did not finish
        draining or was cut at the capture cap is incomplete and throws too.
    .PARAMETER Prefix
        Zero or more name prefixes. A VM is returned when its name starts
        with any of them. Omit (or pass none) to return every VM.
    .OUTPUTS
        [string[]] matching VM names; empty when none match.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string[]]$Prefix)
    $resolver = Resolve-UtmctlExecutable
    if ($resolver.Source -eq 'missing') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_81fb05f8b6924bce')
    }
    $listing = Invoke-UtmctlProbe -Arguments @('list') -UtmctlPath $resolver.Path
    $text = "$($listing.StdOut)`n$($listing.StdErr)".Trim()
    if ($listing.TimedOut) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_76bccb579d55bc73')
    }
    if (-not $listing.Started -or $listing.ExitCode -ne 0 -or $listing.DrainTimedOut -or $listing.OutputTruncated -or
        (Get-UtmStartFailureKind -Text $text) -ne 'none') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_7c4b552da601ab61' -Arguments @{ text = "$text" })
    }
    $parsed = ConvertFrom-UtmctlListResult -Result $listing
    if (-not $parsed.Recognized) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_7c4b552da601ab61' -Arguments @{ text = "$text" })
    }
    return Select-NameByPrefix -Name @($parsed.Row | ForEach-Object { $_.Name }) -Prefix $Prefix
}

# --- REGION: Disk snapshots
# --- REGION: Save-VMDiskSnapshot
function Save-VMDiskSnapshot {
    <# .SYNOPSIS
        Save a snapshot on every disk of the stopped UTM bundle as the
        persisted VM named $Id, through the shared transactional save
        (Invoke-YurunaDiskSnapshotSave).
    .PARAMETER VMName
        The bundle name.
    .PARAMETER Id
        Snapshot identifier.
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
        Stop          = { param($Name) Stop-UtmVMForSnapshot -VMName $Name }
        Rename        = { param($Name, $NewName) Rename-VM -VMName $Name -NewName $NewName -Confirm:$false }
        Remove        = { param($Name) Remove-VM -VMName $Name -Confirm:$false }
        Snapshot      = { param($Name, $SnapshotId) New-UtmDiskSnapshot -VMName $Name -Id $SnapshotId }
    })
}

<#
.SYNOPSIS
    Stop a UTM VM for a snapshot and wait until its QEMU helper has released
    the disks.
.DESCRIPTION
    A snapshot created while the QEMU helper still holds the qcow2 open races
    its in-memory metadata: qemu-img -c either fails to lock ("Failed to lock
    byte 100") or captures an inconsistent disk.
#>
function Stop-UtmVMForSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleDisk = Get-UtmBundleDisk -VMName $VMName
    if (-not $bundleDisk.Ready) {
        $key = switch ($bundleDisk.Reason) { 'missing-directory' { 'host.operator_5e237b9eea6b9490' } 'missing-disk' { 'host.operator_13cb024dfb19c946' } default { 'host.operator_06786a3211f6200f' } }
        Write-Warning (Format-YurunaOperatorMessage -Key $key -Arguments @{ dataDir = "$($bundleDisk.DataDir)" })
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_ceeff55becfc6e28' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Create snapshot $Id on every disk of the stopped bundle $VMName, replacing
    one of the same name.
#>
function New-UtmDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Called only by Save-VMDiskSnapshot, which owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    $bundleDisk = Get-UtmBundleDisk -VMName $VMName
    if (-not $bundleDisk.Ready) { return $false }
    foreach ($disk in @($bundleDisk.Disk)) {
        $null = Invoke-UtmHostTool -Tool 'qemu-img' -ArgumentList @('snapshot', '-d', $Id, $disk.FullName) -TimeoutSeconds 60
        $snapshotResult = Invoke-UtmHostTool -Tool 'qemu-img' -ArgumentList @('snapshot', '-c', $Id, $disk.FullName) -TimeoutSeconds 60
        if (-not (Test-BoundedNativeResultComplete -Result $snapshotResult) -or $snapshotResult.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4e18f285f91cd947' -Arguments @{ name = "$($disk.Name)"; lASTEXITCODE = "$($snapshotResult.ExitCode)" })
            return $false
        }
    }
    return $true
}

# --- REGION: Restore-VMDiskSnapshot
function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Restore every *.qcow2 disk under the UTM VM bundle to snapshot $Id.
    .DESCRIPTION
        Verifies the snapshot exists on every disk first so a typo'd Id
        does not bounce a healthy guest, stops the VM if it is running,
        then applies `qemu-img snapshot -a $Id` per disk. Multi-disk VMs
        must have the snapshot on all disks to stay coherent.
    .OUTPUTS
        [bool] $true on success; $false on any precondition or apply failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_122c73a3a2052796' -Arguments @{ id = "$Id" }))) { return $false }
    $bundleDisk = Get-UtmBundleDisk -VMName $VMName
    $utmBundle = $bundleDisk.Bundle; $dataDir = $bundleDisk.DataDir; $disks = @($bundleDisk.Disk)
    if (-not $bundleDisk.Ready) {
        $key = switch ($bundleDisk.Reason) { 'missing-directory' { 'host.operator_dec3b9d961011af3' } 'missing-disk' { 'host.operator_2443a2232e97400d' } default { 'host.operator_67f1fe22f87fb1a8' } }
        Write-Warning (Format-YurunaOperatorMessage -Key $key -Arguments @{ dataDir = "$dataDir" })
        return $false
    }
    if ((Get-VMDiskSnapshotState -VMName $VMName -Id $Id) -ne 'present') { return $false }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # See https://yuruna.link/42e5cdfd-0008
    if (-not (Wait-UtmVMPoweredOff -VMName $VMName)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c66ee6ced9fa2d77' -Arguments @{ vMName = "$VMName" })
        return $false
    }
    # Removing vmstate at this point mirrors Start-UtmVM's cold-boot
    # prep -- the saved RAM (if any) belongs to the post-snapshot
    # universe and would collide with the reverted disk on next start.
    $vmstatePath = Join-Path $utmBundle 'Data/vmstate'
    if (Test-Path -LiteralPath $vmstatePath) {
        Remove-Item -LiteralPath $vmstatePath -Force -ErrorAction SilentlyContinue
    }
    foreach ($disk in $disks) {
        $snapshotResult = Invoke-UtmHostTool -Tool 'qemu-img' -ArgumentList @('snapshot', '-a', $Id, $disk.FullName) -TimeoutSeconds 60
        if (-not (Test-BoundedNativeResultComplete -Result $snapshotResult) -or $snapshotResult.ExitCode -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_3566f32ac9581467' -Arguments @{ name = "$($disk.Name)"; lASTEXITCODE = "$($snapshotResult.ExitCode)" })
            return $false
        }
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
    $bundleDisk = Get-UtmBundleDisk -VMName $VMName
    if (-not $bundleDisk.Ready) {
        # No bundle, or a bundle with no disk, holds no snapshot; a missing
        # qemu-img is a host that cannot look.
        if ($bundleDisk.Reason -in @('missing-directory', 'missing-disk')) { return 'absent' }
        return 'unknown'
    }
    foreach ($disk in @($bundleDisk.Disk)) {
        $diskState = Get-UtmDiskSnapshotState -Disk $disk.FullName -Id $Id
        if ($diskState -ne 'present') { return $diskState }
    }
    return 'present'
}

# --- REGION: Test-VMDiskSnapshot
function Test-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Returns $true when snapshot $Id is present on every qcow2 disk of
        the UTM bundle for $VMName, $false when the bundle or any disk lacks
        it, and throws when qemu-img could not answer. Used by
        Debug-TestSequence's requiresSnapshot warm-path probe before deciding
        whether to walk the baseline chain.
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

<#
.SYNOPSIS
    Save a disk-only snapshot of each qcow2 disk in the UTM bundle,
    then attempt to rename the VM (best-effort) so it persists across
    test-cycle cleanup.
.DESCRIPTION
    UTM owns its QEMU process and does not expose a stable QMP/CLI
    snapshot verb, so this contract drops to qemu-img with the VM
    offline. The .utm bundle lives at $HOME/yuruna/guest.nosync/<vm>.utm
    and disks are *.qcow2 under <bundle>/Data/. For multi-disk VMs the
    same Id is written into every qcow2 -- Restore-VMDiskSnapshot
    reverts the same set as a group so the disks stay coherent.

    After a successful snapshot, Rename-VM renames the VM to $Id by
    on-disk surgery (bundle dir + config.plist + UTM Registry) so the
    snapshot survives the next cycle's Remove-TestVMFiles sweep. If the
    rename fails, the qcow2 snapshot is still on disk and can be
    restored manually from the original bundle path.
#>
function Get-UtmBundleDisk {
    <#
    .SYNOPSIS
        Resolves bundle disks and the common snapshot prerequisites.
    .PARAMETER VMName
        The UTM bundle name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$VMName)
    $bundle = "$HOME/yuruna/guest.nosync/$VMName.utm"
    $data = Join-Path $bundle 'Data'
    $disks = @(Get-ChildItem -LiteralPath $data -Filter '*.qcow2' -File -ErrorAction SilentlyContinue)
    $reason = if (-not (Test-Path -LiteralPath $data)) { 'missing-directory' } elseif ($disks.Count -eq 0) { 'missing-disk' } elseif (-not (Get-Command qemu-img -ErrorAction SilentlyContinue)) { 'missing-tool' } else { '' }
    return @{ Ready = -not $reason; Reason = $reason; Bundle = $bundle; DataDir = $data; Disk = $disks }
}

function Test-UtmDiskHasSnapshot {
    <#
    .SYNOPSIS
        Verifies snapshot metadata with a bounded, complete qemu-img read.
    .PARAMETER Disk
        The qcow2 disk path.
    .PARAMETER Id
        The exact snapshot identifier.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Disk, [string]$Id)
    return ((Get-UtmDiskSnapshotState -Disk $Disk -Id $Id) -eq 'present')
}

function Get-UtmDiskSnapshotState {
    <#
    .SYNOPSIS
        Whether one qcow2 disk carries snapshot $Id: 'present', 'absent', or
        'unknown' when the bounded qemu-img read did not complete.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Disk, [string]$Id)
    $probe = Invoke-UtmHostTool -Tool 'qemu-img' -ArgumentList @('snapshot', '-l', '-U', $Disk) -TimeoutSeconds 10
    if (-not (Test-BoundedNativeResultComplete -Result $probe) -or $probe.ExitCode -ne 0) { return 'unknown' }
    if ([regex]::IsMatch($probe.StdOut, '(?m)^\s*\d+\s+' + [regex]::Escape($Id) + '\s')) { return 'present' }
    return 'absent'
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
    # UTM does not expose per-VM window state today; "console open" is
    # approximated by "UTM app process running." VMName is accepted for
    # cross-host parity and surfaced in the debug stream.
    Write-Debug "Test-VMConsoleOpen on host.macos.utm: VMName '$VMName' resolved to UTM-process check (no per-VM window detection)."
    return [bool](Get-Process -Name 'UTM' -ErrorAction SilentlyContinue)
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
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_6e0202c4ffd01c8a'))) { return $false }
    return [bool](Restart-UtmConsole -VMName $VMName -Confirm:$false)
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
    Invoke-GetImage -HostSubdir 'host/macos.utm' -ResolveImagePath (Get-Command Get-ImagePath) @PSBoundParameters
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
    # Per-guest paths under $HOME/yuruna/image/ -- not a single-dir pattern;
    # subdir names are part of the legacy convention (amazon.linux.2023,
    # ubuntu.env, windows.env). Keep the explicit table so a typo or new
    # guest fails loud instead of silently composing the wrong path.
    $paths = @{
        'guest.amazon.linux.2023'    = "$HOME/yuruna/image/amazon.linux.2023/host.macos.utm.guest.amazon.linux.2023.qcow2"
        'guest.ubuntu.server.24'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.24.iso"
        'guest.macos.26' = "$HOME/yuruna/image/macos.env/host.macos.utm.guest.macos.26.ipsw"
        'guest.ubuntu.server.26'   = "$HOME/yuruna/image/ubuntu.env/host.macos.utm.guest.ubuntu.server.26.iso"
        'guest.windows.11'      = "$HOME/yuruna/image/windows.env/host.macos.utm.guest.windows.11.iso"
    }
    return $paths[$GuestKey]
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
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on UTM." }
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
    # GUI: Test.SequenceEngine.psm1 has the cross-platform dispatcher and the
    # macOS-specific Send-TextVNC / Send-TextUTM helpers. We import it on
    # demand here (it ships in test/modules/ and the runner already loads
    # it for sequence execution).
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # See https://yuruna.link/42e5cdfd-0009
        if (-not (Get-Module -Name Test.SequenceEngine)) { Import-Module $sequenceEngine -DisableNameChecking -Global }
        # Module-qualified call avoids re-entering OUR Send-Text.
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
    # See https://yuruna.link/42e5cdfd-000a
    $sequenceEngine = Join-Path $script:TestModulesDir 'Test.SequenceEngine.psm1'
    if (Test-Path $sequenceEngine) {
        # Import once and reuse: a -Force re-import evicts the global
        # Invoke-Sequence (and its nested modules + $script: state) that the
        # outer loop still calls, and paying that on every keystroke is pure
        # overhead.
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
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_bf613f7460bae519' -Arguments @{ vMName = "$VMName"; x = "$X"; y = "$Y" })
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
        return Get-UtmWindowScreenshot -VMName $VMName -OutputPath $OutFile
    }
    return Get-UtmScreenshot -VMName $VMName -OutputPath $OutFile
}

# --- REGION: Get-VMConsoleHandle
function Get-VMConsoleHandle {
    <#
    .SYNOPSIS
        Return a host-specific handle for the VM console window.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$VMName)
    # macOS UTM exposes one app-level console; we return the UTM PID and
    # surface the requested VMName in the debug stream until per-VM window
    # handles are wired up.
    Write-Debug "Get-VMConsoleHandle on host.macos.utm: returning UTM app PID for '$VMName' (no per-VM window handle today)."
    $proc = Get-Process -Name 'UTM' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { return $null }
    return $proc.Id
}

<#
.SYNOPSIS
    Return the pid of the QEMU process serving the named VM, or 0 when it
    cannot be identified.
.DESCRIPTION
    UTM runs every VM in its own QEMULauncher process and publishes no
    name-to-pid mapping, so the emulator has to be recognized by something
    only that VM owns. The VNC display in the bundle is exactly that:
    Find-FreeVncDisplay refuses to hand one display to two bundles, so
    whoever holds that listening port is that VM's emulator. Matching on
    the process name instead would be ambiguous the moment two VMs run at
    once -- the normal case for a cycle that keeps the service VMs up.
#>
function Get-UtmVMProcessId {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) { return 0 }
    $port = Get-VncPortForVm -VMName $VMName
    if ($port -le 0) { return 0 }
    $listenerPid = & lsof -nP "-iTCP:$port" -sTCP:LISTEN -t 2>$null
    foreach ($line in @($listenerPid)) {
        $candidate = 0
        if ([int]::TryParse("$line".Trim(), [ref]$candidate) -and $candidate -gt 0) { return $candidate }
    }
    return 0
}

<#
.SYNOPSIS
    Say whether a console that never changed was the guest's doing or the
    capture path's.
.DESCRIPTION
    A wait that exhausts its console-reconnect repairs ends on one
    ambiguous fact: every captured frame was byte-identical. That has two
    causes with opposite owners -- a guest that stopped drawing, and a
    capture path that lost the live feed while the guest kept drawing.

    Here the two are separated by reading the emulator rather than the
    screen. Get-VncScreenshot dials QEMU's own VNC server on a fresh
    connection and asks for a non-incremental full-frame update, so it
    holds nothing that could go stale; Get-UtmScreenshot's screencapture
    fallback, which serves whatever the UTM window last painted, can. A
    pair of direct VNC reads that differ therefore means the guest is
    drawing and the wait's frames came from that fallback.

    A matching pair leaves the guest side, and the emulator's CPU time
    then says which kind: a halted guest consumes almost nothing, while
    one wedged mid-boot keeps burning cores against a screen that never
    advances. Those need opposite responses -- restart the VM versus
    capture the guest's state before anything clears it -- so they are
    reported as separate verdicts instead of one 'static'.

    A blinking cursor makes an idle console differ frame to frame, so a
    matching pair is reported as what was observed, never as proof the
    guest is dead.
.OUTPUTS
    [pscustomobject] Verdict 'guest-static' | 'guest-wedged' | 'guest-live'
    | 'unavailable', Detail.
#>
function Get-VMConsoleSecondOpinion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$IntervalSeconds = 5
    )
    # See https://yuruna.link/428e4df6-001c
    # Percent of one core, sustained across the sample window, that counts as
    # "still executing": an idle QEMU answering VNC polls sits in low single
    # digits, a guest spinning on a wedged boot holds a core or more.
    $executingPercent = 25
    $observation = [ordered]@{
        Verdict = 'unavailable'; Detail = ''; ObservedAtUtc = [DateTime]::UtcNow.ToString('o')
        VMName = $VMName; VMState = ''; QemuPid = $null; VncPort = $null
        IntervalSeconds = $IntervalSeconds; FirstFrameSha256 = $null; SecondFrameSha256 = $null
        FramesChanged = $null; FirstCpuSeconds = $null; SecondCpuSeconds = $null; CpuPercent = $null
    }
    try {
        $state = Get-VMState -VMName $VMName
        $observation.VMState = [string]$state
        if ($state -eq 'absent' -or $state -eq 'unknown') {
            $observation.Detail = Format-YurunaOperatorMessage -Key 'host.operator_b7d0860a322acd62' -Arguments @{ state = "$state"; vMName = "$VMName" }
            return [pscustomobject]$observation
        }
        if ($state -ne 'running') {
            $observation.Verdict = 'guest-static'
            $observation.Detail = Format-YurunaOperatorMessage -Key 'host.operator_9ea0a8c951ae7be7' -Arguments @{ state = "$state" }
            return [pscustomobject]$observation
        }

        $qemuPid = Get-UtmVMProcessId -VMName $VMName
        $port    = Get-VncPortForVm -VMName $VMName
        if ($qemuPid -gt 0) { $observation.QemuPid = $qemuPid }
        if ($port -gt 0) { $observation.VncPort = $port }
        $readFrame = {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-second-opinion-$PID-$([guid]::NewGuid().ToString('N')).png"
            try {
                if (-not (Get-VncScreenshot -OutputPath $tmp -Port $port)) { return $null }
                return (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
            } catch {
                Write-Debug "Get-VMConsoleSecondOpinion: direct VNC read on $port failed: $($_.Exception.Message)"
                return $null
            } finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
        $readCpu = {
            if ($qemuPid -le 0) { return $null }
            $proc = Get-Process -Id $qemuPid -ErrorAction SilentlyContinue
            if (-not $proc) { return $null }
            return [double]$proc.CPU
        }

        # Frame first, then CPU, so the CPU window is the sleep alone and the
        # percentage is not diluted by the time a framebuffer read costs.
        $firstFrame = & $readFrame
        $firstCpu   = & $readCpu
        Start-Sleep -Seconds $IntervalSeconds
        $secondCpu   = & $readCpu
        $secondFrame = & $readFrame
        $observation.FirstFrameSha256 = $firstFrame
        $observation.SecondFrameSha256 = $secondFrame
        if ($firstFrame -and $secondFrame) { $observation.FramesChanged = ($firstFrame -ne $secondFrame) }
        $observation.FirstCpuSeconds = $firstCpu
        $observation.SecondCpuSeconds = $secondCpu

        $cpuPercent = $null
        $cpuText    = 'the emulator CPU was unreadable'
        if ($null -ne $firstCpu -and $null -ne $secondCpu -and $IntervalSeconds -gt 0) {
            # A pid reused inside the window reads as a negative delta. Drop
            # it rather than publish a percentage taken from two processes.
            $delta = $secondCpu - $firstCpu
            if ($delta -ge 0) {
                $cpuPercent = [math]::Round(($delta / $IntervalSeconds) * 100, 1)
                $observation.CpuPercent = $cpuPercent
                $cpuText    = "the emulator burned ${cpuPercent}% of one core across the same window"
            }
        }

        if ($firstFrame -and $secondFrame -and $firstFrame -ne $secondFrame) {
            $observation.Verdict = 'guest-live'
            $observation.Detail = Format-YurunaOperatorMessage -Key 'host.operator_689d94eae42f4fe8' -Arguments @{ port = "$port"; intervalSeconds = "${IntervalSeconds}"; cpuText = "$cpuText" }
            return [pscustomobject]$observation
        }
        $frameText = if ($firstFrame -and $secondFrame) {
            "direct VNC reads on port $port ${IntervalSeconds}s apart are byte-identical"
        } else {
            "direct VNC reads on port $port were unavailable"
        }
        if ($null -ne $cpuPercent -and $cpuPercent -ge $executingPercent) {
            $observation.Verdict = 'guest-wedged'
            $observation.Detail = Format-YurunaOperatorMessage -Key 'host.operator_912d123572f4b9c5' -Arguments @{ frameText = "$frameText"; cpuText = "$cpuText" }
            return [pscustomobject]$observation
        }
        $observation.Verdict = 'guest-static'
        $observation.Detail = Format-YurunaOperatorMessage -Key 'host.operator_7b4448d951dc6b7c' -Arguments @{ frameText = "$frameText"; cpuText = "$cpuText" }
        return [pscustomobject]$observation
    } catch {
        $observation.Verdict = 'unavailable'
        $observation.Detail = $_.Exception.Message
        return [pscustomobject]$observation
    }
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

# --- REGION: Get-VMIp
function Get-VMIp {
    <#
    .SYNOPSIS
        Return the guest's host-side IPv4, or null if not yet discoverable.

    .DESCRIPTION
        Three rungs, cheapest first. Each answers for a different class of
        guest, and the order is part of the contract: a rung runs only when
        every rung above it declined, so a Shared-NAT guest -- which the lease
        file answers for in milliseconds -- never pays for the LAN sweep a
        bridged guest needs.

          1. utmctl ip-address -- the guest's own report, via qemu-guest-agent.
             Free when it answers and silent for every guest this repo seeds,
             because the seeds do not install the agent.
          2. /var/db/dhcpd_leases -- the lease file of the macOS SHARED-NAT
             DHCP server. Authoritative for a Shared guest, and structurally
             blind to a bridged one, which leases from the LAN router and
             never appears in it.
          3. The bundle's MAC in the host ARP table. The only rung that can see
             a bridged guest, and the reason this chain has three rungs: with
             just the first two, a healthy bridged guest serving traffic is
             indistinguishable from a VM that does not exist, and every caller
             waits out its whole budget against $null.

        Each decline is narrated to the verbose stream naming the rung and why
        it could not answer. Three sources that all return $null otherwise
        report "no address yet" in exactly the same words as "no such VM",
        which is the difference between a 30-second diagnosis and a 30-minute
        one when a run is examined afterwards.

        Safe to call from a polling loop, which is what rung 3 is shaped
        around. A guest that is up and has exchanged traffic with the host
        answers from the ARP table in well under a second; a guest that is
        not running is declined for the cost of one state query; and the ICMP
        sweep -- the only part measured in seconds -- runs at most once per
        minute per VM, so no caller can turn its poll interval into a sweep
        interval.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $ip = Get-UtmAgentReportedIp -VMName $VMName
    if ($ip) { return $ip }
    # Read the bundle once and hand it to both rungs that need it: each
    # would otherwise shell out to plutil for the same file.
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    $ip = Get-UtmSharedLeaseIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    $ip = Get-UtmBridgedGuestIp -VMName $VMName -BundleNetwork $bundleNetwork
    if ($ip) { return $ip }
    Write-Verbose "Get-VMIp: all three rungs declined for '$VMName' (guest agent, shared-NAT lease file, bundle MAC in ARP); each said why above."
    return $null
}

<#
.SYNOPSIS
    Rung 1: the address the guest reports through utmctl, or $null.
.PARAMETER UtmctlLine
    Pre-captured `utmctl ip-address` output. The live command is run when
    this is not bound; supplying it keeps the parsing testable with no VM.
#>
function Get-UtmAgentReportedIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyCollection()][string[]]$UtmctlLine
    )
    $output = $UtmctlLine
    if (-not $PSBoundParameters.ContainsKey('UtmctlLine')) {
        $resolver = Resolve-UtmctlExecutable
        if ($resolver.Source -eq 'missing') {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl is neither on PATH nor in the UTM bundle."
            return $null
        }
        try {
            $probe  = Invoke-UtmctlProbe -Arguments @('ip-address', $VMName) -UtmctlPath $resolver.Path
            $output = @(Get-BoundedNativeOutputLine -Result $probe -IncludeError)
            if ($probe.TimedOut) {
                Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address did not answer within its time limit."
                return $null
            }
            # utmctl exits 0 even when the guest has no agent to ask, writing
            # its complaint to stderr, so the exit code cannot be the test for
            # "an address came back" -- only the parse below can be.
            if ($probe.ExitCode -ne 0) {
                Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address exited $($probe.ExitCode)."
                return $null
            }
        } catch {
            Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl ip-address failed: $($_.Exception.Message)"
            return $null
        }
    }
    # Accept either IPv4 or IPv6; exclude loopback (127., ::1)
    # and link-local (169.254., fe80:) for both families. v4 is
    # preferred only by output ordering -- utmctl emits the v4
    # row first today, so callers that expect a connectable
    # address still get one. If only v6 is present, take it.
    $ipPick = ($output -split "`r?`n") |
        ForEach-Object { $_.Trim() } |
        Where-Object { Test-IpAddress $_ } |
        Where-Object { $_ -notmatch '^(127\.|169\.254\.)' -and $_ -inotmatch '^(::1$|fe80:)' } |
        Select-Object -First 1
    if ($ipPick) { return [string]$ipPick }
    Write-Verbose "Get-VMIp rung 'guest agent' declined for '$VMName': utmctl reported no usable address (the seeds do not install qemu-guest-agent, so this is the normal answer)."
    return $null
}

<#
.SYNOPSIS
    Rung 2: the guest's address in the macOS shared-NAT lease file, or $null.
.DESCRIPTION
    The DHCP server keys each block on the name the GUEST sent, which is the
    VM name only when no sequence pinned variables.hostname; a pinned hostname
    makes the guest register under that instead. A VM-name lookup therefore
    does not come back empty when a hostname is pinned -- it matches leftover
    blocks filed under the VM name by predecessors and hands back a dead
    address, often on a subnet the host no longer serves, which costs a full
    SSH connect-timeout budget per attempt. Both keys are tried, pinned
    hostname first, and Select-DhcpLeaseIpAddress discards any candidate that
    is not on a live host-interface subnet.

    A guest whose bundle says Bridged is skipped outright. This file belongs
    to the shared-NAT DHCP server; a bridged guest takes its lease from the
    LAN router and cannot legitimately appear here, so any block bearing its
    name is a predecessor's from when the name was last built on Shared NAT.
    Those blocks parse, sit on-link while the vmnet bridge is up, and look
    exactly like a good answer -- returning one would hide the guest's real
    LAN address behind a dead 192.168.64.x for the rest of the run.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER LeaseText
    Pre-captured lease-file text. The live file is read when this is not
    bound; supplying it keeps the selection testable with no guests running.
.PARAMETER OnLinkVerdict
    Forwarded to Select-DhcpLeaseIpAddress, which judges each candidate
    against the host's live interface subnets by default. Supplying a
    verdict fixes that judgment, so a lease fixture reads the same on a
    host that serves the vmnet subnet and on one that does not.
#>
function Get-UtmSharedLeaseIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        [scriptblock]$OnLinkVerdict
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if ($BundleNetwork -and $BundleNetwork.Mode -eq 'Bridged') {
        Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': the bundle is Bridged, so its lease comes from the LAN router and any block under this name belongs to a predecessor."
        return $null
    }
    $content = $LeaseText
    if (-not $PSBoundParameters.ContainsKey('LeaseText')) {
        $leaseFile = '/var/db/dhcpd_leases'
        if (-not (Test-Path $leaseFile)) {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': $leaseFile does not exist (no guest has ever taken a shared-NAT lease on this host)."
            return $null
        }
        try {
            $content = Get-Content $leaseFile -Raw -ErrorAction Stop
        } catch {
            Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': could not read $leaseFile`: $($_.Exception.Message)"
            return $null
        }
    }
    $pinnedHostname = Get-UtmGuestSeedHostname -VMName $VMName
    $leaseNames = @($pinnedHostname)
    if ($pinnedHostname -ne $VMName) { $leaseNames += $VMName }
    $selectArgs = @{ LeaseText = $content; Name = $leaseNames }
    if ($PSBoundParameters.ContainsKey('OnLinkVerdict')) { $selectArgs['OnLinkVerdict'] = $OnLinkVerdict }
    $bestIp = Select-DhcpLeaseIpAddress @selectArgs
    if ($bestIp) { return [string]$bestIp }
    Write-Verbose "Get-VMIp rung 'shared-NAT lease file' declined for '$VMName': no on-link lease filed under $($leaseNames -join ' or ')."
    return $null
}

<#
.SYNOPSIS
    Rung 3: the guest's bundle MAC matched in the host ARP table, or $null.

.DESCRIPTION
    The rung a bridged guest depends on. It sits on the host's LAN with an
    address from the LAN's own DHCP server, so neither the guest agent nor
    the shared-NAT lease file can name it -- but it answers ARP, and the
    bundle's MAC identifies it unambiguously among everything else on that
    LAN, including a sibling host's identically-named VM.

    Two passes, and the order is the whole reason this is affordable in a
    hot path. The passive pass reads `arp -an` and matches: ~20 ms, and it
    is what steady state costs, because a guest that has exchanged any
    traffic with the host is already in the table. Only when the table has
    nothing does the ICMP sweep run -- a full /24 at 32-way parallelism is
    SECONDS (measured at ~8 s on a 253-address subnet), which is why it is
    one attempt with no retry loop: Get-VMIp is called per cycle by the
    runner and inside Wait-VMIp's poll loop, and a rung that blocked for
    minutes there would be worse than the discovery hole it closes. The
    poll loop is the retry.

    Two further guards bound what the sweep can cost a REPEAT caller, because
    the passive pass only protects a guest that is already on the LAN:

      * a VM that is not RUNNING is never swept for. Nothing powered off
        answers ICMP, so the sweep could only come back empty -- and this is
        the common shape, not an edge case: a bundle outlives its guest, so
        every lookup for a service whose VM is down would otherwise pay full
        price to learn what one state query already knows;
      * an empty sweep is remembered briefly, so a caller polling every few
        seconds through a guest's boot sweeps on a cadence of its own rather
        than once per poll. A found address retires the memo at once, and the
        memo suppresses only the ESCALATION -- the passive read still runs on
        every call, so a guest that appears mid-cooldown is picked up by the
        very next poll at ~20 ms.

    A guest whose bundle says Shared is skipped: it lives on the vmnet
    subnet, not the host's LAN, so the sweep could not match it and rung 2
    already answered for it. A bundle with no readable mode still gets both
    passes -- an unreadable mode is not evidence the guest is on NAT.
.PARAMETER BundleNetwork
    The bundle's network descriptor (Get-UtmBundleNetwork). Read here when
    not supplied; Get-VMIp supplies it so one plist read serves the chain.
.PARAMETER SubnetPrefix
    The dot-terminated /24 to match and, if needed, sweep. Derived from the
    host's own default-route interface when not supplied -- a bridged guest
    is on the host's LAN by construction, so that is where it must be
    looked for, on whatever subnet this host happens to sit on.
.PARAMETER HostIp
    The host's address on that subnet, skipped by the sweep. Derived
    alongside -SubnetPrefix when not supplied.
.PARAMETER ArpLine
    Pre-captured `arp -an` output. The live table is read when this is not
    bound; supplying it keeps the match testable with no guests running.
#>
# How long an empty sweep suppresses the next one, per VM. Long enough that a
# 3-second poll loop cannot turn every poll into a /24 of ICMP, short enough
# that a guest finishing its DHCP exchange is swept for again while the caller
# that wants it is still waiting.
$script:UtmBridgedSweepCooldownSeconds = 60
$script:UtmBridgedSweepMiss = @{}

function Get-UtmBridgedGuestIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [string]$SubnetPrefix,
        [string]$HostIp,
        [AllowEmptyCollection()][string[]]$ArpLine
    )
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName }
    if (-not $BundleNetwork) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': no readable .utm bundle on this host, so there is no MAC to match."
        return $null
    }
    if ($BundleNetwork.Mode -eq 'Shared') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle is on Shared NAT, which the lease file answers for; this rung looks on the host's LAN."
        return $null
    }
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $BundleNetwork.MacAddress
    if (-not $macNeedle) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the bundle carries no usable MacAddress."
        return $null
    }
    if (-not ($PSBoundParameters.ContainsKey('SubnetPrefix') -and $PSBoundParameters.ContainsKey('HostIp'))) {
        # One default-route read answers both. Get-HostLanPrefix is
        # Get-BestHostIp plus a regex, so resolving them independently spawns
        # `route` and `ipconfig` twice per call on a path Wait-VMIp polls --
        # and lets the prefix and the host address come from different uplinks
        # when the default route changes between the two reads.
        $lanIp = Get-BestHostIp
        if (-not $PSBoundParameters.ContainsKey('HostIp'))       { $HostIp = $lanIp }
        if (-not $PSBoundParameters.ContainsKey('SubnetPrefix')) { $SubnetPrefix = Get-HostLanPrefix -HostIp $lanIp }
    }
    if (-not $SubnetPrefix) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': this host has no default-route IPv4, so there is no LAN to look on."
        return $null
    }
    if (-not $PSBoundParameters.ContainsKey('ArpLine')) {
        $ArpLine = @(Get-BoundedNativeOutputLine -Result (Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5))
    }
    $ip = Select-ArpIpByMac -ArpLine $ArpLine -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
    if ($ip) {
        # A hit retires any memo: whatever kept the guest off the LAN is over,
        # and the next call must be free to escalate again the moment it is not.
        $script:UtmBridgedSweepMiss.Remove($VMName)
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' resolved '$VMName' to $ip from the host's existing ARP table."
        return [string]$ip
    }

    # Everything below escalates. The guards are ordered by what they cost:
    # the memo is a hashtable read, the state query one utmctl call, the sweep
    # seconds -- so the cheapest thing that can rule the sweep out runs first.
    $lastMiss = $script:UtmBridgedSweepMiss[$VMName]
    if ($lastMiss -and ((Get-Date) - $lastMiss).TotalSeconds -lt $script:UtmBridgedSweepCooldownSeconds) {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': a sweep of ${SubnetPrefix}0/24 found nothing $([int]((Get-Date) - $lastMiss).TotalSeconds)s ago and the host's ARP table still has no entry, so another one now would cost seconds to learn the same thing."
        return $null
    }
    $state = Get-VMState -VMName $VMName
    if ($state -ne 'running') {
        Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the VM is '$state', not running -- a guest that is not up answers no ICMP, so there is nothing for a sweep to find."
        return $null
    }

    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP': MAC $($BundleNetwork.MacAddress) is not in the host's ARP table yet; sweeping ${SubnetPrefix}0/24 ONCE to populate it (seconds)."
    $swept = Resolve-UtmGuestIpByMac -PlistPath $BundleNetwork.PlistPath -SubnetPrefix $SubnetPrefix -HostIp $HostIp -MaxAttempt 1
    if ($swept) {
        $script:UtmBridgedSweepMiss.Remove($VMName)
        return [string]$swept
    }
    $script:UtmBridgedSweepMiss[$VMName] = Get-Date
    Write-Verbose "Get-VMIp rung 'bundle MAC in ARP' declined for '$VMName': the sweep of ${SubnetPrefix}0/24 matched no entry carrying MAC $($BundleNetwork.MacAddress). The guest is running but not on this LAN yet; the next $($script:UtmBridgedSweepCooldownSeconds)s of calls read the ARP table without re-sweeping."
    return $null
}

# --- REGION: Get-VMMac
function Get-VMMac {
    <#
    .SYNOPSIS
        Return the guest's MAC address, or null if not available.
    .DESCRIPTION
        utmctl exposes no MAC, so the bundle is the source: it is where UTM
        records the address the VM boots with, and it is readable whether or
        not the VM is running.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $bundleNetwork = Get-UtmBundleNetwork -VMName $VMName
    if (-not $bundleNetwork -or -not $bundleNetwork.MacAddress) {
        Write-Verbose "Get-VMMac on host.macos.utm: no MacAddress in the bundle for '$VMName'."
        return $null
    }
    # Canonical form for the whole harness, so a MAC read on one host compares
    # equal to the same MAC read on another. The `arp -an` notation this host
    # needs is produced at the point of use by ConvertTo-ArpMacNeedle.
    $canonical = ConvertTo-YurunaMacAddress -MacAddress ([string]$bundleNetwork.MacAddress)
    if ($canonical) { return $canonical }
    return ([string]$bundleNetwork.MacAddress).ToUpperInvariant()
}

# --- REGION: Neighbor cache refresh
# --- REGION: Update-GuestNeighborCache
function Update-GuestNeighborCache {
    <#
    .SYNOPSIS
        Refresh the host neighbor cache so a passive MAC lookup can succeed.
    .DESCRIPTION
        Contract verb, and deliberately a no-op here. This driver's bridged rung
        already escalates to its own ICMP sweep from inside Get-VMIp, where the
        cooldown memo and the running-state check bound it. Sweeping again from
        outside would duplicate that work while bypassing both guards, so the
        honest implementation is to decline and say why.
    .PARAMETER VMName
        Accepted for contract symmetry; unused.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$CooldownSeconds = 60
    )
    $null = $CooldownSeconds
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_80e0ecef6307a2d3'))) { return $false }
    Write-Verbose "Update-GuestNeighborCache on host.macos.utm: no external sweep -- Get-VMIp's bridged rung runs its own bounded, memoized sweep for '$VMName'."
    return $false
}

<#
.SYNOPSIS
    Normalize a MAC to the form `arp -an` prints it, or $null when the
    input is not six hex octets.
.DESCRIPTION
    macOS prints ARP entries lowercase with the leading zero of each octet
    stripped ('0F' -> 'f'), while the bundle stores the canonical
    'E6:01:BC:6D:21:CD'. Comparing the two forms directly never matches, so
    every ARP lookup normalizes through here rather than carrying its own
    copy of the rule.
#>
function ConvertTo-ArpMacNeedle {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $null }
    $octets = @($MacAddress -split ':')
    if ($octets.Count -ne 6) { return $null }
    try {
        return (($octets | ForEach-Object { ([Convert]::ToInt32($_, 16)).ToString('x') }) -join ':')
    } catch {
        Write-Debug "ConvertTo-ArpMacNeedle: '$MacAddress' is not six hex octets: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Return the IPv4 in $SubnetPrefix whose ARP entry carries $MacNeedle,
    or $null when the table holds no such entry.
.DESCRIPTION
    The match is required to be IN the given subnet, not just any ARP entry
    carrying that MAC. `arp -an` lists EVERY interface, so a stale or
    foreign entry with the same MAC (a recreated bundle MAC still cached on
    another NIC) printed first would otherwise be selected -- and, since
    the first match wins, re-selected on every poll, wedging a caller
    against the wrong address until its timeout.

    $SubnetPrefix is dot-terminated (e.g. '192.168.64.'), so the prefix test
    cannot false-match a sibling /24 like 192.168.640.x.
.PARAMETER ArpLine
    Lines as `arp -an` prints them.
#>
function Select-ArpIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArpLine,
        [Parameter(Mandatory)][string]$MacNeedle,
        [Parameter(Mandatory)][string]$SubnetPrefix
    )
    foreach ($line in $ArpLine) {
        if ($line -match '^\? \(([\d.]+)\) at (\S+)' -and
            $matches[2] -eq $MacNeedle -and
            $matches[1].StartsWith($SubnetPrefix)) {
            return [string]$matches[1]
        }
    }
    return $null
}

<#
.SYNOPSIS
    A MAC in canonical 'AA:BB:CC:DD:EE:FF' form, or $null. Accepts the
    zero-stripped lowercase octets `arp -an` prints as well as the bundle's
    two-digit form, so the two compare equal.
#>
function ConvertTo-UtmCanonicalMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$MacAddress)
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $null }
    $octets = @($MacAddress.Trim() -split '[:-]')
    if ($octets.Count -ne 6) { return $null }
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($octet in $octets) {
        if ($octet -notmatch '^[0-9A-Fa-f]{1,2}$') { return $null }
        $parts.Add(([Convert]::ToInt32($octet, 16)).ToString('X2'))
    }
    return ($parts -join ':')
}

<#
.SYNOPSIS
    `arp -an` lines as a map of IPv4 address to canonical MAC.
.DESCRIPTION
    An address listed with two different MACs (on two interfaces) cannot
    identify either guest, so it is left out of the map and named in
    Conflict instead; incomplete entries are skipped.
#>
function ConvertFrom-UtmArpLine {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Line)
    $map = @{}
    $conflict = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($entry in @($Line)) {
        if ("$entry" -notmatch '^\?\s+\(([\d.]+)\)\s+at\s+(\S+)') { continue }
        $address = $Matches[1]
        $mac = ConvertTo-UtmCanonicalMac -MacAddress $Matches[2]
        if (-not $mac -or -not (Test-Ipv4Address $address)) { continue }
        if ($map.ContainsKey($address) -and $map[$address] -ne $mac) { [void]$conflict.Add($address); continue }
        $map[$address] = $mac
    }
    foreach ($address in $conflict) { $map.Remove($address) }
    return [pscustomobject]@{ Map = $map; Conflict = [string[]]@($conflict) }
}

<#
.SYNOPSIS
    The host ARP table, read once through the bounded runner.
.OUTPUTS
    [pscustomobject] Captured, Line [string[]], Reason ('captured' |
    'failed' | 'timeout' | 'deadline-exhausted').
#>
function Get-UtmArpTable {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $read = Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5 -Deadline $Deadline
    $reason = if ($read.DeadlineExhausted) { 'deadline-exhausted' }
              elseif ($read.TimedOut) { 'timeout' }
              elseif ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { 'captured' }
              else { 'failed' }
    $lines = if ($reason -eq 'captured') { [string[]]@(Get-BoundedNativeOutputLine -Result $read) } else { [string[]]@() }
    return [pscustomobject]@{ Captured = ($reason -eq 'captured'); Line = $lines; Reason = $reason }
}

<#
.SYNOPSIS
    This host's IPv4 subnets from one bounded ifconfig read, with a verdict
    closure for on-link tests.
.DESCRIPTION
    The shared subnet parser runs a bare ifconfig when it is not handed the
    text; this reads it once, bounded, and hands it over, so a caller testing
    many candidates makes one bounded call instead of one hidden call each.
    Without a capture the verdict is always 'unknown', never 'offlink'.
.OUTPUTS
    [pscustomobject] Captured, Subnet [object[]], OnLinkVerdict
    ([scriptblock] taking an IPv4 and returning 'onlink' | 'offlink' |
    'unknown'), Reason ('captured' | 'failed' | 'timeout' | 'deadline-exhausted').
#>
function Get-UtmHostSubnetEvidence {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param($Deadline)
    $read = Invoke-UtmHostTool -Tool 'ifconfig' -TimeoutSeconds 5 -Deadline $Deadline
    $reason = if ($read.DeadlineExhausted) { 'deadline-exhausted' }
              elseif ($read.TimedOut) { 'timeout' }
              elseif ((Test-UtmBoundedResultComplete -Result $read) -and $read.ExitCode -eq 0) { 'captured' }
              else { 'failed' }
    $subnet = [object[]]@()
    # Assigned, not wrapped in @(): the parser returns its table comma-wrapped,
    # and @() around the call would nest it one level deep.
    if ($reason -eq 'captured') {
        $parsed = Get-HostIpv4Subnet -IfconfigText ([string]$read.StdOut)
        $subnet = [object[]]@($parsed | Where-Object { $_ })
    }
    $verdict = if ($reason -eq 'captured') {
        { param([string]$IpAddress) Get-Ipv4OnLinkVerdict -IpAddress $IpAddress -Subnet $subnet }.GetNewClosure()
    } else {
        { param([string]$IpAddress) $null = $IpAddress; 'unknown' }
    }
    return [pscustomobject]@{ Captured = ($reason -eq 'captured'); Subnet = [object[]]$subnet; OnLinkVerdict = $verdict; Reason = $reason }
}

<#
.SYNOPSIS
    The macOS shared-NAT DHCP lease file's text, read without any native call.
.OUTPUTS
    [pscustomobject] Captured, Text, Reason ('captured' | 'no-file' | 'read-failed').
#>
function Get-UtmSharedLeaseText {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $path = [string]$script:UtmSharedLeasePath
    if (-not $path -or -not [System.IO.File]::Exists($path)) {
        return [pscustomobject]@{ Captured = $false; Text = ''; Reason = 'no-file' }
    }
    try {
        return [pscustomobject]@{ Captured = $true; Text = [System.IO.File]::ReadAllText($path); Reason = 'captured' }
    } catch {
        Write-Verbose "Get-UtmSharedLeaseText: could not read $path`: $($_.Exception.Message)"
        return [pscustomobject]@{ Captured = $false; Text = ''; Reason = 'read-failed' }
    }
}

<#
.SYNOPSIS
    The one address in an ARP map carrying a MAC, preferring on-link rows.
.DESCRIPTION
    Rows judged 'offlink' are dropped: `arp -an` lists every interface, and
    a MAC cached on another interface's subnet is not where the guest is.
    One distinct address wins; several are narrowed to the 'onlink' ones,
    and anything still plural is ambiguous rather than a guess.
.OUTPUTS
    [pscustomobject] Address ($null unless exactly one), Reason ('matched' |
    'no-match' | 'ambiguous').
#>
function Select-ArpIpByMacOnLink {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][hashtable]$ArpMap,
        [Parameter(Mandatory)][string]$MacAddress,
        [scriptblock]$OnLinkVerdict
    )
    $candidates = @()
    if ($ArpMap) { $candidates = @($ArpMap.Keys | Where-Object { $ArpMap[$_] -eq $MacAddress } | Sort-Object) }
    $judged = @(foreach ($address in $candidates) {
        $verdict = if ($OnLinkVerdict) { "$(& $OnLinkVerdict $address)" } else { 'unknown' }
        if ($verdict -ne 'offlink') { [pscustomobject]@{ Address = $address; Verdict = $verdict } }
    })
    if ($judged.Count -eq 0) { return [pscustomobject]@{ Address = $null; Reason = 'no-match' } }
    if ($judged.Count -eq 1) { return [pscustomobject]@{ Address = [string]$judged[0].Address; Reason = 'matched' } }
    $onLink = @($judged | Where-Object { $_.Verdict -eq 'onlink' })
    if ($onLink.Count -eq 1) { return [pscustomobject]@{ Address = [string]$onLink[0].Address; Reason = 'matched' } }
    return [pscustomobject]@{ Address = $null; Reason = 'ambiguous' }
}

<#
.SYNOPSIS
    Resolve a guest's address from passive evidence only: its bundle, the
    shared-NAT lease text and the host ARP table.
.DESCRIPTION
    Sends no Apple Event and probes nothing: no utmctl, no guest-agent
    query, no VM state read, no ICMP sweep. The bundle is read through the
    bounded plist reader; the lease text and ARP lines are what the caller
    captured (the ARP table is read here, bounded, only when neither
    -ArpMap nor -ArpLine is given and -ArpUnavailable is not set).

    A lease match is only a candidate: the lease's hardware field is a DHCP
    DUID, not the bundle MAC, so it does not prove which guest holds the
    address. An address is returned only when an ARP row carries the bundle
    MAC; a lease candidate the ARP table agrees with is 'lease-corroborated',
    and one it does not is reported with Address $null.
.PARAMETER VMName
    The guest.
.PARAMETER BundleNetwork
    Get-UtmBundleNetwork output; read here when not supplied.
.PARAMETER ArpLine
    `arp -an` lines already captured.
.PARAMETER ArpMap
    An address-to-MAC map already built (ConvertFrom-UtmArpLine).
.PARAMETER ArpUnavailable
    The caller's ARP capture failed; do not read the table here.
.PARAMETER LeaseText
    The shared-NAT lease file text; without it no lease candidate is formed.
.PARAMETER OnLinkVerdict
    Scriptblock judging an IPv4 'onlink' | 'offlink' | 'unknown'.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [pscustomobject] VMName, Address, Source ('arp-mac' |
    'lease-corroborated' | 'lease-candidate' | 'none'), LeaseCandidate,
    MacAddress, MacCorroborated, Mode, Reason ('resolved' | 'no-bundle' |
    'bundle-unreadable' | 'no-mac' | 'lease-uncorroborated' | 'ambiguous-arp'
    | 'arp-unavailable' | 'not-found' | 'deadline-exhausted'), ElapsedMs.
#>
function Resolve-UtmGuestAddressPassive {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [psobject]$BundleNetwork,
        [AllowEmptyCollection()][string[]]$ArpLine,
        [hashtable]$ArpMap,
        [switch]$ArpUnavailable,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        [scriptblock]$OnLinkVerdict,
        $Deadline
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $facts = @{ Mode = ''; Mac = ''; Lease = $null }
    $emit = {
        param($Address, [string]$Source, [bool]$Corroborated, [string]$Reason)
        [pscustomobject]@{
            PSTypeName = 'Yuruna.UtmPassiveAddress'
            VMName = $VMName; Address = $Address; Source = $Source; LeaseCandidate = $facts.Lease
            MacAddress = $facts.Mac; MacCorroborated = $Corroborated; Mode = $facts.Mode; Reason = $Reason
            ElapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) { return (& $emit $null 'none' $false 'deadline-exhausted') }
    if (-not $PSBoundParameters.ContainsKey('BundleNetwork')) { $BundleNetwork = Get-UtmBundleNetwork -VMName $VMName -Deadline $Deadline }
    if (-not $BundleNetwork) { return (& $emit $null 'none' $false 'no-bundle') }
    if ($BundleNetwork.PSObject.Properties['Readable'] -and -not $BundleNetwork.Readable) { return (& $emit $null 'none' $false 'bundle-unreadable') }
    $facts.Mode = [string]$BundleNetwork.Mode
    $mac = ConvertTo-UtmCanonicalMac -MacAddress ([string]$BundleNetwork.MacAddress)
    if (-not $mac) { return (& $emit $null 'none' $false 'no-mac') }
    $facts.Mac = $mac
    $verdict = if ($OnLinkVerdict) { $OnLinkVerdict } else { { param([string]$IpAddress) $null = $IpAddress; 'unknown' } }
    if ($PSBoundParameters.ContainsKey('LeaseText') -and $LeaseText -and $facts.Mode -ne 'Bridged') {
        $facts.Lease = Get-UtmSharedLeaseIp -VMName $VMName -BundleNetwork $BundleNetwork -LeaseText $LeaseText -OnLinkVerdict $verdict
    }
    $map = $null
    if ($ArpUnavailable) { $map = $null }
    elseif ($PSBoundParameters.ContainsKey('ArpMap')) { $map = $ArpMap }
    elseif ($PSBoundParameters.ContainsKey('ArpLine')) { $map = (ConvertFrom-UtmArpLine -Line $ArpLine).Map }
    else {
        $table = Get-UtmArpTable -Deadline $Deadline
        if ($table.Captured) { $map = (ConvertFrom-UtmArpLine -Line $table.Line).Map }
    }
    if ($null -eq $map) {
        if ($facts.Lease) { return (& $emit $null 'lease-candidate' $false 'lease-uncorroborated') }
        return (& $emit $null 'none' $false 'arp-unavailable')
    }
    $selected = Select-ArpIpByMacOnLink -ArpMap $map -MacAddress $mac -OnLinkVerdict $verdict
    if ($selected.Address) {
        $source = if ($facts.Lease -and $facts.Lease -eq $selected.Address) { 'lease-corroborated' } else { 'arp-mac' }
        return (& $emit $selected.Address $source $true 'resolved')
    }
    if ($selected.Reason -eq 'ambiguous') { return (& $emit $null 'none' $false 'ambiguous-arp') }
    if ($facts.Lease) { return (& $emit $null 'lease-candidate' $false 'lease-uncorroborated') }
    return (& $emit $null 'none' $false 'not-found')
}

<#
.SYNOPSIS
    Capture, once per pass, the passive evidence Get-VMPassiveAddress
    resolves guests against: the ARP table, the shared-NAT lease text and
    this host's subnets.
.DESCRIPTION
    No Apple Event and no probe: one bounded `arp -an`, one file read, one
    bounded ifconfig. Each piece can be injected instead (tests, or a caller
    that already holds it), and each reports how it was obtained.
.PARAMETER Deadline
    Shared deadline (New-YurunaDeadline) bounding the captures.
.PARAMETER ArpOnly
    Skip the lease text.
.PARAMETER ArpLine
    Use these `arp -an` lines instead of reading the table.
.PARAMETER LeaseText
    Use this lease text instead of reading the file.
.PARAMETER SubnetEvidence
    Use this Get-UtmHostSubnetEvidence record instead of reading ifconfig.
.OUTPUTS
    [pscustomobject] PSTypeName 'Yuruna.PassiveAddressContext': ArpMap
    ([hashtable] IPv4 -> 'AA:BB:CC:DD:EE:FF'), ArpConflict [string[]],
    ArpReason ('ok' | 'timeout' | 'tool-failed' | 'deadline-exhausted' |
    'injected'), LeaseText, LeaseReason ('captured' | 'no-file' |
    'read-failed' | 'injected' | 'skipped'), SubnetEvidence, ObservedUnixMs.
#>
function Get-VMPassiveAddressContext {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Deadline,
        [switch]$ArpOnly,
        [AllowEmptyCollection()][string[]]$ArpLine,
        [AllowEmptyString()][AllowNull()][string]$LeaseText,
        $SubnetEvidence
    )
    $arpMap = @{}
    $arpConflict = [string[]]@()
    if ($PSBoundParameters.ContainsKey('ArpLine')) {
        $parsed = ConvertFrom-UtmArpLine -Line $ArpLine
        $arpMap = $parsed.Map; $arpConflict = $parsed.Conflict; $arpReason = 'injected'
    } else {
        $table = Get-UtmArpTable -Deadline $Deadline
        $arpReason = switch ($table.Reason) { 'captured' { 'ok' } 'timeout' { 'timeout' } 'deadline-exhausted' { 'deadline-exhausted' } default { 'tool-failed' } }
        if ($table.Captured) { $parsed = ConvertFrom-UtmArpLine -Line $table.Line; $arpMap = $parsed.Map; $arpConflict = $parsed.Conflict }
    }
    $leaseReason = 'skipped'
    $leaseValue = ''
    if ($PSBoundParameters.ContainsKey('LeaseText')) {
        $leaseValue = [string]$LeaseText; $leaseReason = 'injected'
    } elseif (-not $ArpOnly) {
        $lease = Get-UtmSharedLeaseText
        $leaseValue = [string]$lease.Text; $leaseReason = [string]$lease.Reason
    }
    if (-not $PSBoundParameters.ContainsKey('SubnetEvidence') -or -not $SubnetEvidence) {
        $SubnetEvidence = Get-UtmHostSubnetEvidence -Deadline $Deadline
    }
    return [pscustomobject]@{
        PSTypeName     = 'Yuruna.PassiveAddressContext'
        ArpMap         = $arpMap
        ArpConflict    = [string[]]$arpConflict
        ArpReason      = $arpReason
        LeaseText      = $leaseValue
        LeaseReason    = $leaseReason
        SubnetEvidence = $SubnetEvidence
        ObservedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }
}

<#
.SYNOPSIS
    One guest's address from a passive evidence context, with no Apple Event.
.DESCRIPTION
    Resolves against a Get-VMPassiveAddressContext record: the bundle is
    read (bounded), everything else comes from the context. Never calls
    utmctl, osascript, Get-VMState, the guest-agent rung, the bridged-guest
    rung or its ICMP sweep. A lease match with no ARP row carrying the
    bundle MAC is 'lease-only' with Address $null: the lease names a
    candidate, not the guest.
.PARAMETER VMName
    The guest.
.PARAMETER Context
    Get-VMPassiveAddressContext output.
.PARAMETER Deadline
    Shared deadline (New-YurunaDeadline) bounding the bundle read.
.OUTPUTS
    [pscustomobject] VMName, Address, Origin ('shared-lease' | 'arp' |
    'none'), BundlePath, BundleMac, NetworkMode ('Shared' | 'Bridged' | ''),
    MacCorroborated, Reason ('ok' | 'no-bundle' | 'no-mac' | 'lease-only' |
    'arp-miss' | 'ambiguous-arp' | 'deadline-exhausted' | 'tool-failed'),
    ElapsedMs.
#>
function Get-VMPassiveAddress {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][AllowNull()]$Deadline
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $bundle = $null
    if (-not $Deadline -or (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -ge 1000) {
        $bundle = Get-UtmBundleNetwork -VMName $VMName -Deadline $Deadline
    }
    $resolveArgs = @{ VMName = $VMName; BundleNetwork = $bundle; Deadline = $Deadline }
    if ($Context.ArpReason -in @('ok', 'injected')) { $resolveArgs['ArpMap'] = [hashtable]$Context.ArpMap } else { $resolveArgs['ArpUnavailable'] = $true }
    if ($Context.LeaseReason -in @('captured', 'injected')) { $resolveArgs['LeaseText'] = [string]$Context.LeaseText }
    if ($Context.SubnetEvidence -and $Context.SubnetEvidence.OnLinkVerdict) { $resolveArgs['OnLinkVerdict'] = $Context.SubnetEvidence.OnLinkVerdict }
    $resolved = if ($Deadline -and (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -lt 1000) {
        [pscustomobject]@{ Address = $null; Source = 'none'; MacCorroborated = $false; Mode = ''; MacAddress = ''; Reason = 'deadline-exhausted' }
    } else {
        Resolve-UtmGuestAddressPassive @resolveArgs
    }
    $origin = switch ($resolved.Source) { 'lease-corroborated' { 'shared-lease' } 'arp-mac' { 'arp' } default { 'none' } }
    # An ARP table the context never read because its deadline ran out is a
    # deadline outcome, not a tool failure: the caller's remedy differs.
    $arpMissing = if ($Context.ArpReason -eq 'deadline-exhausted') { 'deadline-exhausted' } else { 'tool-failed' }
    $reason = switch ($resolved.Reason) {
        'resolved'             { 'ok' }
        'lease-uncorroborated' { 'lease-only' }
        'not-found'            { 'arp-miss' }
        'arp-unavailable'      { $arpMissing }
        'bundle-unreadable'    { 'tool-failed' }
        default                { [string]$resolved.Reason }
    }
    return [pscustomobject]@{
        PSTypeName      = 'Yuruna.PassiveAddress'
        VMName          = $VMName
        Address         = $(if ($reason -eq 'ok') { [string]$resolved.Address } else { $null })
        Origin          = $(if ($reason -eq 'ok') { $origin } else { 'none' })
        BundlePath      = $(if ($bundle) { [string]$bundle.PlistPath } else { '' })
        BundleMac       = [string]$resolved.MacAddress
        NetworkMode     = [string]$resolved.Mode
        MacCorroborated = [bool]$resolved.MacCorroborated
        Reason          = $reason
        ElapsedMs       = $stopwatch.ElapsedMilliseconds
    }
}

<#
.SYNOPSIS
    Resolve a freshly-built UTM bundle's current IPv4 by matching its
    config.plist MAC against the host ARP table -- the reliable identity
    signal for both Shared-NAT and bridged VMs.

.DESCRIPTION
    The bundle's MAC (random per build, written to config.plist) is the
    ONLY stable identity for a just-created VM. Discovery by DHCP hostname
    is unsafe: a rebuilt VM reuses the same hostname, so /var/db/dhcpd_leases
    accumulates stale same-named blocks from deleted predecessors, and the
    lease's hw_address is a DHCP DUID (not the link MAC), so it can't
    disambiguate -- a name lookup that runs before THIS VM has DHCP'd locks
    onto a dead predecessor's IP. Matching the MAC in `arp -an` instead
    always returns the live VM, immune to the DHCP race and stale leases.

    Populates the ARP cache by ICMP-sweeping the subnet in parallel (the VM
    answers ICMP from cloud-init early, before squid binds), then matches
    OUR MAC. When -ProbePort > 0, the candidate must also answer that TCP
    port before it is accepted, so the returned IP is one squid is already
    serving on. Polls until found, until -TimeoutMinutes elapses, or until
    -MaxAttempt sweeps have been made.

.PARAMETER PlistPath
    Path to the bundle's config.plist (holds <key>MacAddress</key>).

.PARAMETER SubnetPrefix
    The /24 to sweep, e.g. '192.168.64.' (Shared-NAT) or the host's LAN
    prefix (bridged). Octets 2..254 are pinged.

.PARAMETER HostIp
    Address to skip in the sweep (the host's own IP on that subnet).

.PARAMETER ProbePort
    If > 0, require this TCP port to answer on the MAC-matched IP before
    accepting it (e.g. squid's 3128). 0 = accept on MAC match alone.

.PARAMETER MaxAttempt
    Cap on sweep-and-match rounds. 0 (the default) means "as many as
    -TimeoutMinutes allows" -- the bring-up scripts wait out a whole guest
    boot that way. 1 makes this a single bounded probe that returns in the
    time one sweep takes, which is what a caller in a per-cycle path needs:
    for it the surrounding poll loop is the retry, and blocking here for
    minutes would cost far more than the answer is worth.

.OUTPUTS
    [string] the matched IPv4, or $null on timeout / missing-MAC.
#>
function Resolve-UtmGuestIpByMac {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$PlistPath,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [string]$HostIp,
        [int]$ProbePort = 0,
        [int]$TimeoutMinutes = 15,
        [int]$PollSeconds = 5,
        [int]$MaxAttempt = 0
    )
    if (-not (Test-Path -LiteralPath $PlistPath)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1db4026c87e87900' -Arguments @{ plistPath = "$PlistPath" })
        return $null
    }
    $plistText = Get-Content -Raw -LiteralPath $PlistPath
    if ($plistText -notmatch '<key>MacAddress</key>\s*<string>([0-9A-Fa-f:]+)</string>') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_acad3d911acdf65d' -Arguments @{ plistPath = "$PlistPath" })
        return $null
    }
    $ourMacRaw = $matches[1]
    $macNeedle = ConvertTo-ArpMacNeedle -MacAddress $ourMacRaw
    if (-not $macNeedle) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_355f6d92ffafef75' -Arguments @{ ourMacRaw = "$ourMacRaw"; plistPath = "$PlistPath" })
        return $null
    }
    Write-Verbose "Resolve-UtmGuestIpByMac: matching MAC $ourMacRaw (needle '$macNeedle') on ${SubnetPrefix}0/24."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $found = $null
    $attempt = 0
    # A do-loop, so one round always happens: -MaxAttempt 1 has to mean
    # "sweep once and answer", and a while-first shape would decide the
    # deadline had passed before ever looking.
    do {
        $attempt++
        # ICMP-sweep the /24 in parallel to populate the host ARP cache.
        # -t 1 keeps packets on-LAN (TTL 1); -W 200 caps per-host wait at
        # 200 ms; ThrottleLimit 32 holds a 253-address sweep to seconds --
        # measured at ~8 s, so this is never on a path that cannot spare it.
        2..254 |
            Where-Object { "$SubnetPrefix$_" -ne $HostIp } |
            ForEach-Object -Parallel {
                $c = "$using:SubnetPrefix$_"
                try { & /sbin/ping -c 1 -W 200 -t 1 $c *>$null } catch { $null = $_ }
            } -ThrottleLimit 32 | Out-Null

        $candidateIp = Select-ArpIpByMac -ArpLine @(Get-BoundedNativeOutputLine -Result (Invoke-UtmHostTool -Tool 'arp' -ArgumentList @('-an') -TimeoutSeconds 5)) `
            -MacNeedle $macNeedle -SubnetPrefix $SubnetPrefix
        if ($candidateIp) {
            if ($ProbePort -le 0) { $found = $candidateIp; break }
            $tcp = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $tcp.BeginConnect($candidateIp, $ProbePort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(500) -and $tcp.Connected) {
                    $found = $candidateIp
                    break
                }
            } catch {
                Write-Verbose "Resolve-UtmGuestIpByMac: probe ${candidateIp}:${ProbePort} failed: $($_.Exception.Message)"
            } finally { $tcp.Close() }
            Write-Verbose "Resolve-UtmGuestIpByMac: MAC match at $candidateIp but :$ProbePort not listening yet -- waiting."
        }
        if ($MaxAttempt -gt 0 -and $attempt -ge $MaxAttempt) {
            Write-Verbose "Resolve-UtmGuestIpByMac: no match after $attempt attempt(s); the caller asked for at most $MaxAttempt."
            break
        }
        # Sleep only when another round will follow, so a run that is out of
        # budget returns now instead of one poll interval from now.
        if ((Get-Date).AddSeconds($PollSeconds) -ge $deadline) { break }
        Start-Sleep -Seconds $PollSeconds
    } while ((Get-Date) -lt $deadline)
    return $found
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
    # macOS UTM uses VMnet shared / VZ NAT; there's no operator-managed
    # 'external network' to pick by name. Return the conventional value
    # so callers can compare without branching on host.
    return 'vmnet-shared'
}

<#
.SYNOPSIS
    True when the host's default-route uplink cannot carry a bridged
    guest MAC -- on macOS that is the Wi-Fi hardware port.
.DESCRIPTION
    QEMU bridged networking is unreliable over Wi-Fi: the access point
    commonly drops frames from the VM's locally-administered MAC, so a
    bridged guest never gets a LAN DHCP lease. Callers use this to fall
    back to UTM Shared NAT (192.168.64.x) + host port-forwarders on Wi-Fi-
    only hosts. Returns $false when the default route is Ethernet/USB-
    Ethernet, or when there is no default route at all (the caller surfaces
    the missing-route error on its own bridged path).

    macOS counterpart of host.windows.hyper-v Test-WindowsUplinkNotBridgeable,
    but the criteria differ by hypervisor: vmnet bridges USB Ethernet fine
    (it is plain wired Ethernet here), so only Wi-Fi is rejected -- whereas
    Hyper-V's External vSwitch also rejects USB NICs.
.OUTPUTS
    [bool]
#>
function Test-MacUplinkNotBridgeable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $iface = Get-MacDefaultRouteInterface
    if (-not $iface) { return $false }
    # See https://yuruna.link/42e220c4-0004
    $wifiDevices = [System.Collections.Generic.List[string]]::new()
    $portIsWifi  = $false
    foreach ($line in (& '/usr/sbin/networksetup' -listallhardwareports 2>$null)) {
        if ($line -match '^Hardware Port:\s*(.+?)\s*$') {
            $portIsWifi = ($matches[1] -match 'Wi-?Fi')
            continue
        }
        if ($portIsWifi -and $line -match '^Device:\s*(\S+)') {
            $wifiDevices.Add($matches[1])
            $portIsWifi = $false
        }
    }
    return ($wifiDevices -contains $iface)
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
    if (-not $PSCmdlet.ShouldProcess('vmnet-shared', (Format-YurunaOperatorMessage -Key 'host.operator_0da6776e773e7f47'))) { return $null }
    return 'vmnet-shared'
}

# --- REGION: Test-CacheVMOnExternalNetwork
function Test-CacheVMOnExternalNetwork {
    <#
    .SYNOPSIS
        Returns true if the caching-proxy-service VM is on an External-type network.
    .DESCRIPTION
        Inspect the built VM's network attachment. Shared NAT needs host
        forwarders even when the host's current default route is Ethernet.
        Missing or unreadable bundle configuration cannot prove LAN access.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy-service')
    # See https://yuruna.link/42e220c4-0004
    $network = Get-UtmBundleNetwork -VMName $VMName
    return [bool]($network -and $network.Readable -and $network.Mode -eq 'Bridged')
}

# --- REGION: Port mapping
# --- REGION: Add-PortMap
function Add-PortMap {
    <#
    .SYNOPSIS
        Install host to VM port forwarders for -Owner's service.
    .DESCRIPTION
        Additive: each port gets its own forwarder and pidfile, so a caller
        that re-maps a subset (the per-cycle re-map asks for fewer ports than
        the cache's start installed) leaves its owner's other forwarders
        running. The host's port-map record (Get-PortMapStatePath) says which
        owner holds each host port; this call refuses a port another owner
        holds, and Remove-PortMap stops its owner's forwarders alone.
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
    if (-not $PSCmdlet.ShouldProcess($VMIp, (Format-YurunaOperatorMessage -Key 'host.operator_0c74b58906c540e7' -Arguments @{ join = "$($Port -join ',')" }))) { return $false }
    if (-not (Test-Ipv4Address $VMIp)) {
        # macOS Add-PortMap drives the host-side pwsh forwarders that bind
        # IPv4 sockets to the cache VM. v6 inputs (which Test-IpAddress
        # accepts as operator-facing values elsewhere) are rejected here
        # because the forwarder mechanism currently targets v4.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_88bea28586a2663a' -Arguments @{ vMIp = "$VMIp" })
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
    $statePath = Get-PortMapStatePath
    $owners = Read-YurunaPortMapLedger -Path $statePath
    $hostPorts = @($mappings | ForEach-Object { $_.HostPort })
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners $owners -HostPort $hostPorts
    foreach ($conflict in $plan.Conflict) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.portmap_port_held' -Arguments @{ owner = "$Owner"; port = "$($conflict.HostPort)"; holder = "$($conflict.Owner)" })
    }
    if ($plan.Conflict.Count -gt 0) { return $false }
    # Apple VZ shared-NAT path: per-port pwsh TcpListener via Yuruna.Host.psm1's
    # Start-CachingProxyServiceForwarder. Each call is idempotent per port and
    # leaves OTHER ports' forwarders alone -- mid-cycle :3000 refresh
    # MUST NOT disturb the running :3128 forwarder.
    $launched = @()
    $failed = @()
    $attempted = 0
    foreach ($m in $mappings) {
        $useProxy = $proxyProtoSet.ContainsKey([int]$m.HostPort)
        $proxyTag = if ($useProxy) { ' [PROXY v1]' } else { '' }
        if (-not $PSCmdlet.ShouldProcess("0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)${proxyTag}", (Format-YurunaOperatorMessage -Key 'host.operator_832575bbe1b2f32f'))) { continue }
        $attempted++
        $started = if ($useProxy) {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort -PrependProxyV1
        } else {
            Start-CachingProxyServiceForwarder -CacheIp $VMIp -Port $m.HostPort -VMPort $m.VMPort
        }
        if ($started) { $launched += $m.HostPort } else { $failed += $m.HostPort }
    }
    if ($failed.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_68cc3422228bb646' -Arguments @{ join = "$($failed -join ', ')" })
    }
    # The record keeps the owner's forwarders on ports this call did not ask
    # for, which are still running.
    $kept = @(@($owners[$Owner].mappings) | Where-Object { $_ -and $hostPorts -notcontains [int]$_.hostPort } | ForEach-Object {
            [pscustomobject]@{ HostPort = [int]$_.hostPort; VMPort = [int]$_.vmPort; ProxyProtocol = [bool]$_.proxyProtocol }
        })
    $live = @($mappings | Where-Object { $launched -contains $_.HostPort } | ForEach-Object {
            [pscustomobject]@{ HostPort = $_.HostPort; VMPort = $_.VMPort; ProxyProtocol = $proxyProtoSet.ContainsKey([int]$_.HostPort) }
        })
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -VMIp $VMIp -Mapping @($kept + $live) -Confirm:$false
    # Report success only when EVERY attempted forwarder launched. A partial launch reported as
    # success hides a missing forwarder (e.g. :3128 / :3129 / SSH) so downstream guest fetches
    # silently bypass or fail against the cache with no recovery triggered.
    return ($attempted -gt 0 -and $launched.Count -eq $attempted)
}

# --- REGION: Remove-PortMap
function Remove-PortMap {
    <#
    .SYNOPSIS
        Tear down the port forwarders -Owner holds.
    .DESCRIPTION
        Another owner's forwarders are left alone. A forwarder no owner
        records was started before owners were recorded, and goes too, as it
        did when this stopped every forwarder.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$Owner)
    if (-not $PSCmdlet.ShouldProcess('pwsh forwarders', (Format-YurunaOperatorMessage -Key 'host.operator_f3f37ca41e1f0e2f'))) { return $false }
    $statePath = Get-PortMapStatePath
    $plan = Get-YurunaPortMapPlan -Owner $Owner -Owners (Read-YurunaPortMapLedger -Path $statePath) -Discovered (Get-UtmPortMapPort) -Removing
    $stopped = @(foreach ($p in $plan.Release) { if (Stop-CachingProxyServiceForwarder -Port $p -Quiet) { $p } })
    $null = Set-YurunaPortMapOwner -Path $statePath -Owner $Owner -Confirm:$false
    return ($stopped.Count -gt 0)
}

<#
.SYNOPSIS
    The host ports that have a forwarder pidfile.
#>
function Get-UtmPortMapPort {
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    $stateDir = Join-Path $HOME 'yuruna/image/caching-proxy-service'
    return [int[]]@(Get-ChildItem -LiteralPath $stateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue |
        ForEach-Object { if ($_.BaseName -match '^forwarder\.(\d+)$') { [int]$Matches[1] } })
}

# --- REGION: Get-BestHostIp
function Get-BestHostIp {
    <#
    .SYNOPSIS
        Return the host's best LAN-routable IPv4 for browser-facing URLs.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # `route -n get default` -> default-route interface, then
    # `ipconfig getifaddr <iface>` for that interface's IPv4. Skips
    # loopback / utun / VZ bridges (no default route).
    $iface = Get-MacDefaultRouteInterface
    if (-not $iface) { return $null }
    $ip = "$( & '/usr/sbin/ipconfig' getifaddr $iface 2>$null )".Trim()
    if (Test-Ipv4Address $ip) { return $ip }
    return $null
}

<#
.SYNOPSIS
    Hands artifacts written by a root-run build back to the operator who
    invoked sudo. Returns $true when ownership was restored. No-op off macOS,
    when not running as root, or when sudo did not name an invoking user.

.DESCRIPTION
    A UTM bundle created under sudo is root-owned, and UTM.app runs as the
    operator -- it cannot open, start, or later delete such a bundle. The
    parents matter as much as the bundle: removing a directory needs write
    permission on the directory ABOVE it, and ~/yuruna/guest.nosync is shared by
    every macOS builder, so one root-run build blocks every later rebuild.
    Restoring the whole tree is therefore the fix; restoring the bundle alone
    repairs this run and breaks the next.

    This is a GUARD, not a license to run these scripts under sudo: root has no
    Aqua session, so `open`, `utmctl` and the osascript dialog watchdog fail
    before ownership is ever reached. The supported invocation is unelevated --
    the scripts request sudo per operation.
#>
function Restore-SudoUserOwnership {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Path)
    if (-not $IsMacOS) { return $false }
    $sudoUser = "$env:SUDO_USER".Trim()
    if (-not $sudoUser -or $sudoUser -eq 'root') { return $false }
    if ((Get-UtmCurrentUid) -ne '0') { return $false }

    # Plain `sudo` (without -E) resets HOME to /var/root, so a build launched
    # that way put every artifact in root's home, where chown cannot help --
    # the operator cannot traverse into it. Say so instead of silently
    # "succeeding" on a tree they will never see.
    $homeRead = Invoke-UtmHostTool -Tool 'dscl' -ArgumentList @('.', '-read', "/Users/$sudoUser", 'NFSHomeDirectory') -TimeoutSeconds 10
    $sudoUserHome = ''
    if ((Test-UtmBoundedResultComplete -Result $homeRead) -and $homeRead.ExitCode -eq 0) {
        $sudoUserHome = ("$($homeRead.StdOut)" -replace '^NFSHomeDirectory:\s*', '').Trim()
    }
    if ($sudoUserHome -and $HOME -and -not $HOME.StartsWith($sudoUserHome)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_82599fffc9de7081' -Arguments @{ hOME = "$HOME"; sudoUserHome = "$sudoUserHome"; sudoUser = "$sudoUser" })
    }

    $restored = $false
    foreach ($p in $Path) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if (-not $PSCmdlet.ShouldProcess($p, (Format-YurunaOperatorMessage -Key 'host.operator_06c9287f29190c68' -Arguments @{ sudoUser = "$sudoUser" }))) { continue }
        & /usr/sbin/chown -R "$sudoUser" $p 2>$null
        if ($LASTEXITCODE -eq 0) { $restored = $true }
        else { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_372aa49990c2bacc' -Arguments @{ p = "$p"; sudoUser = "$sudoUser" }) }
    }
    if ($restored) { Write-Information -MessageData (Format-YurunaOperatorMessage -Key 'host.operator_89f0c1507d2b052b' -Arguments @{ sudoUser = "$sudoUser" }) -InformationAction Continue }
    return $restored
}

<#
.SYNOPSIS
    Returns the network mode a UTM service VM must be built with on this host:
    'Bridged' on an Ethernet default route, 'Shared' on a Wi-Fi one.

.DESCRIPTION
    The mode and the address a guest reaches the host at are a matched pair --
    the address only works from the network it was derived for -- so both are
    resolved from this one verdict. Bridged is preferred: the VM takes a LAN
    DHCP lease and peers reach its services at <vm-lan-ip> directly. vmnet
    cannot bridge a Wi-Fi uplink (the AP drops frames from the VM's
    locally-administered MAC), so a Wi-Fi default route falls back to UTM
    Shared NAT and the caller forwards host ports for LAN reach.

    USB Ethernet bridges fine here (it is plain wired Ethernet to vmnet),
    unlike Hyper-V -- so a dongle turns a Wi-Fi laptop into the Bridged case.

.OUTPUTS
    [string] 'Bridged' or 'Shared'.
#>
function Resolve-UtmNetworkMode {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-MacUplinkNotBridgeable) { return 'Shared' }
    return 'Bridged'
}

# --- REGION: Get-GuestReachableHostIp
function Get-GuestReachableHostIp {
    <#
    .SYNOPSIS
        Returns the host IP a UTM guest reaches the host at, for the network mode
        that guest is attached to.

    .DESCRIPTION
        On Apple Virtualization shared NAT -- the mode every install guest uses,
        and the default here -- guests always reach the host at 192.168.64.1, the
        VZ gateway IP set by the framework and not configurable per VM.

        A Bridged guest sits on the LAN instead and cannot reach that gateway at
        all, so it reaches the host at the host's own LAN address. Callers that
        build Bridged VMs (the service VMs, via Resolve-UtmNetworkMode) must pass
        -NetworkMode Bridged or they bake an address the guest cannot route to.
        Returns $null when Bridged is asked for and the host has no LAN address:
        there is no correct answer to fall back to, and an empty value makes the
        caller degrade honestly rather than bake the wrong gateway.

    .PARAMETER SwitchName
        Accepted for cross-host contract parity (Hyper-V uses it to choose
        Default Switch vs. External vSwitch); unused on macOS.

    .PARAMETER NetworkMode
        The mode the consuming guest is attached to. Defaults to 'Shared', which
        is what every caller that does not build a Bridged VM wants.

    .OUTPUTS
        [string] the VZ gateway address, the host's LAN IPv4, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$SwitchName,
        [ValidateSet('Shared', 'Bridged')][string]$NetworkMode = 'Shared'
    )
    # macOS has no Default Switch / External vSwitch concepts; SwitchName
    # is accepted for cross-host parity and the mode decides the answer.
    if ($SwitchName) { Write-Debug "Get-GuestReachableHostIp on host.macos.utm: -SwitchName '$SwitchName' ignored; the network mode selects the address." }
    if ($NetworkMode -eq 'Bridged') {
        $lanIp = Get-BestHostIp
        if ($lanIp) { return $lanIp }
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_133c681126464a2b')
        return $null
    }
    return '192.168.64.1'
}

# --- REGION: Get-HostLanPrefix
function Get-HostLanPrefix {
    <#
    .SYNOPSIS
        Returns the host's LAN /24 prefix (e.g. '192.168.7.') based on the
        default-route interface, or $null when the host has no default route.
    .DESCRIPTION
        This is the /24 a bridged guest is looked for on: it sits on the host's
        LAN by construction, so the host's own default-route subnet is where its
        address must be. (It is NOT consulted by
        Test-CachingProxyServiceAvailable, which is restricted to state-file +
        YURUNA_CACHING_PROXY_SERVICE_IP discovery.) Returns the first three
        octets with a trailing dot so the caller can append "$prefix$octet"
        without further string surgery. /24 is an assumption -- it matches the
        home/office DHCP setups the repo targets; a /23 LAN would silently miss
        half the address space. Acceptable trade-off given the alternative is
        parsing the netmask from `ifconfig` output for what is, in practice, a
        /24 99% of the time.
    .PARAMETER HostIp
        The host address to take the prefix from. Resolved with Get-BestHostIp
        when not supplied; a caller that already has it passes it so the
        default-route lookup (two process spawns) is not repeated.
    .OUTPUTS
        [string] e.g. '192.168.7.' (with trailing dot), or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][AllowNull()][string]$HostIp)
    if (-not $PSBoundParameters.ContainsKey('HostIp')) { $HostIp = Get-BestHostIp }
    if (-not $HostIp) { return $null }
    if ($HostIp -notmatch '^(\d+\.\d+\.\d+)\.(\d+)$') { return $null }
    return ($matches[1] + '.')
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
             LAN IP written by Start-CachingProxyServiceVM.ps1 Step 4 (our own VM).

        No LAN scan, no ARP discovery. The previous /24 subnet scan would
        happily lock onto a sibling host's yuruna-caching-proxy-service on the same
        LAN and even persist its IP back into the state file, so Stop-
        CachingProxyService could not actually take the local host out of the
        "cache available" state when a peer was still serving on :3128.
        LAN-wide cache discovery is a separate future feature.

        Returns the cache VM's LAN URL directly -- no host-side forwarder
        layer to fail in between, no VZ-gateway URL gymnastics. This is the
        macOS equivalent of the Hyper-V Yuruna-External vSwitch path: squid
        sees real client IPs at TCP level, remote operators set
        YURUNA_CACHING_PROXY_SERVICE_IP=<cache-lan-ip> and reach the cache directly,
        and other UTM guests on shared-NAT reach the LAN IP through the
        VMnet outbound NAT (same path they use to reach Ubuntu mirrors).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Quiet)
    # Keep platform-specific verification advice in the shared discovery probe.
    # See https://yuruna.link/42e220c4-0004
    Invoke-CachingProxyServiceAvailableProbe -VerifyHint 'nc -G 2 -z {0} {1}' -Quiet:$Quiet
}

# --- REGION: Get-CachingProxyServiceVmIp
function Get-CachingProxyServiceVmIp {
    <#
    .SYNOPSIS
        Return the cache VM's recorded IPv4, or $null when none is valid.
    .DESCRIPTION
        The saved guest address is the port-forwarder target for Shared NAT
        and remains useful for directly bridged guests.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
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
    param(
        [Parameter(Mandatory)][string]$ProxyUrl,
        [string]$NetworkService
    )
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b8a5ce8d9003b608'), (Format-YurunaOperatorMessage -Key 'host.operator_1d67149dffd75755' -Arguments @{ proxyUrl = "$ProxyUrl" }))) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9a18fc9562c73b34')
    }
    # Idempotent backup: only snapshot BEFORE the first apply, so a
    # repeat Set-HostProxy doesn't overwrite the backup with the
    # squid-promoted state.
    Save-YurunaHostProxyBackup -Path $backupPath -ReadState { Read-MacProxyState -NetworkService $svc } -PromotedTo $parts.Url
    Set-MacHostProxy -ProxyParts $parts -NetworkService $svc -Confirm:$false
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_ba4025ead45708af' -Arguments @{ svc = "$svc"; url = "$($parts.Url)" })
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
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_b8a5ce8d9003b608'), (Format-YurunaOperatorMessage -Key 'host.operator_ca5c5716704ce8c4'))) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = Read-YurunaHostProxyBackup -Path $backupPath
    if ($state) {
        Invoke-MacElevationIfNeeded
        Restore-MacHostProxy -State $state
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_1b177181d83a9078' -Arguments @{ networkService = "$($state.networkService)" })
    } else {
        try { Invoke-MacElevationIfNeeded } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_62b64e15fd55e2e0' -Arguments @{ message = "$($_.Exception.Message)" })
            return $false
        }
        Disable-MacHostProxy
        Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_2ddcdf5273a49efa')
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
    param([string]$NetworkService)
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'host.operator_49b535bc8f7577f0'), (Format-YurunaOperatorMessage -Key 'host.operator_0b42b69cacf83715'))) { return $false }
    Invoke-MacElevationIfNeeded
    $svc = if ($NetworkService) { $NetworkService } else { Get-MacActiveNetworkService }
    if (-not $svc) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_fac07fa116ddd338')
        return $false
    }
    Remove-MacHostProxy -NetworkService $svc
    # Verify the wipe actually took. networksetup silently ignores invalid
    # service names and `-setwebproxy` re-enables state as a side-effect, so
    # the log line below has to be earned, not asserted. Parse the live
    # state and refuse to claim "wiped" if web/secure web is still Enabled.
    $webProbe = ''
    $sslProbe = ''
    try {
        $webProbe = (& networksetup -getwebproxy        $svc) 2>&1 | Out-String
        $sslProbe = (& networksetup -getsecurewebproxy  $svc) 2>&1 | Out-String
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f32f219fa4e39d9e' -Arguments @{ message = "$($_.Exception.Message)"; svc = "$svc" })
    }
    $webEnabled = ($webProbe -match '(?m)^Enabled:\s*Yes')
    $sslEnabled = ($sslProbe -match '(?m)^Enabled:\s*Yes')
    if ($webEnabled -or $sslEnabled) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_172e01672f44afab' -FormatValues ($svc, $webEnabled, $sslEnabled, $webProbe.TrimEnd(), $sslProbe.TrimEnd()) -FormatBindings @{ svc = '0'; webEnabled = '1'; sslEnabled = '2'; trimEnd = '3'; trimEnd2 = '4' })
        return $false
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.operator_d4f53d6a06fdcc8f' -Arguments @{ svc = "$svc" })
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
    # There is no separate framework probe: host enablement runs through
    # Enable-TestAutomation.ps1 -> Set-MacHostConditionSet, not a module
    # function. UTM's presence + Apple Virtualization availability is
    # the practical signal here.
    return [bool](Test-Path '/Applications/UTM.app')
}

. (Join-Path $PSScriptRoot 'Yuruna.Host.VirtualizationRepair.ps1')

. (Join-Path $PSScriptRoot 'Yuruna.Host.ServiceBundle.ps1')

# --- REGION: Exports
Export-ModuleMember -Function Write-UtmBundleConfiguration, New-UtmServiceBundleConfiguration, Get-MacDefaultRouteInterface, `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, Get-VMName, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, Get-VMDiskSnapshotState, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, Get-VMConsoleSecondOpinion, `
    Wait-VMIp, Get-VMIp, Get-VMMac, Update-GuestNeighborCache, Resolve-UtmGuestIpByMac, `
    Get-ExternalNetwork, New-ExternalNetwork, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, `
    Test-CachingProxyServiceAvailable, Get-CachingProxyServiceVmIp, Get-HostLanPrefix, Test-MacUplinkNotBridgeable, Resolve-UtmNetworkMode, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization, `
    Test-VirtualizationResponsive, Start-VirtualizationServiceIfStopped, `
    `
    Remove-UtmBundleWithRetry, Invoke-EntitledSwift, `
    Start-CachingProxyServiceForwarder, Stop-CachingProxyServiceForwarder, Get-CachingProxyServiceForwarder, Stop-AllCachingProxyServiceForwarder, `
    Test-DownloadAlreadyCurrent, Test-CachingProxyServicePort, Resolve-CacheHostIp, `
    Save-CachedHttpUri, `
    Stop-UtmDialogWatchdog, Start-UtmDialogWatchdog, `
    Confirm-UtmVMCreated, Remove-UtmTestVM, Test-UtmVMRegistered, Get-UtmVMRegistrationState, Remove-UtmVMRegistration, Start-UtmVM, Stop-UtmVM, Confirm-UtmVMStarted, Wait-UtmVMPoweredOff, Restart-UtmConsole, `
    Get-RunningVmName, Test-UtmctlResponsive, Invoke-UtmctlProbe, Assert-NoConcurrentUtmVm, Resume-YurunaServiceVM, `
    Resolve-UtmctlExecutable, Invoke-UtmctlLifecycle, Get-VMStateRecord, Get-UtmRunningVmInventory, `
    Get-UtmApplicationState, Get-UtmControlPrerequisite, Stop-UtmApplication, Start-UtmApplication, Restart-UtmApplication, Save-UtmControlSnapshot, `
    Get-UtmBundleNetwork, Get-UtmArpTable, Get-UtmHostSubnetEvidence, Get-UtmSharedLeaseText, Resolve-UtmGuestAddressPassive, `
    Get-VMPassiveAddressContext, Get-VMPassiveAddress, Get-PortMapTarget, `
    Get-MacProxyMarkerPath, Test-MacProxyIsYurunaManaged, Get-MacActiveNetworkService, Read-MacProxyState, `
    Invoke-MacElevationIfNeeded, Invoke-MacNetworksetup, `
    Set-MacHostProxy, Restore-MacHostProxy, Disable-MacHostProxy, Remove-MacHostProxy, `
    Get-UtmNetworkModeFromBundle, Restore-SudoUserOwnership, `
    Get-VncDisplayForVm, Get-VncPortForVm, Get-VncDisplayFromBundle, Set-VncDisplayInBundle, Test-VncPortFree, Find-FreeVncDisplay, Get-ClaimedVncDisplay, Get-VncScreenshot, Get-UtmScreenshot, Get-UtmWindowScreenshot, Get-UtmVMProcessId, `
    Set-GuestMacInBundle

# --- REGION: Contract coverage
# Validate actual exports against the common contract after publishing them.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'macos.utm' `
    -Module $ExecutionContext.SessionState.Module -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState','Get-VMName',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot','Get-VMDiskSnapshotState',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac','Update-GuestNeighborCache',
    'Get-ExternalNetwork','New-ExternalNetwork','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyServiceAvailable','Get-CachingProxyServiceVmIp','Get-HostLanPrefix',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization',
    'Test-VirtualizationResponsive','Start-VirtualizationServiceIfStopped'
)

# The driver wrapper must retain cache discovery when shared modules load.
# See https://yuruna.link/42e220c4-0003
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_9cd70c93af7ab7e6')
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_1f268a9fcff06a4e')
}
