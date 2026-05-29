<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42c3d4e5-f6a7-4b89-0c12-de3f4a5b6c7d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

param(
    [string]$Prefix,
    # Quiet mode: suppress per-step "Stopping ... Removed ..." chatter and
    # the host-recommendation block so an automated caller (the cycle-start
    # sweep in Invoke-TestInnerRunner) gets a single visible line:
    #   "Running orphaned VM file cleanup: <path>"
    # Routine status lines flip to Write-Verbose; Write-Warning and
    # Write-Error remain visible because they always represent an actual
    # problem the operator needs to see. The Force flag below is the only
    # destructive-confirmation suppression; -Quiet alone DOES NOT bypass
    # any confirmation. Direct invocation (no -Quiet) prints the full log.
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$ExplicitPrefix = $PSBoundParameters.ContainsKey('Prefix')
$TestRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $TestRoot
$ModulesDir = Join-Path $TestRoot "modules"

function Write-Status {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][string]$Message)
    process {
        if ($Quiet) { Write-Verbose $Message } else { Write-Output $Message }
    }
}

# Resolve $Prefix: explicit -Prefix wins, then test.config.yml's
# vmStart.testVmNamePrefix, then the "test-" fallback. Reading the
# config matters when the operator runs this script directly after a stopped
# runner -- the runner passes -Prefix from $Config.vmStart.testVmNamePrefix,
# so a manual invocation that fell back to "test-" without reading the
# config would miss VMs whenever the operator had customized the prefix
# in test.config.yml.
if (-not $ExplicitPrefix) {
    $configPath = Join-Path $TestRoot 'test.config.yml'
    if (Test-Path $configPath) {
        try {
            Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
            $cfg = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            if ($cfg -is [System.Collections.IDictionary] -and $cfg.vmStart -is [System.Collections.IDictionary] -and $cfg.vmStart.Contains('testVmNamePrefix') -and $cfg.vmStart.testVmNamePrefix) {
                $Prefix = [string]$cfg.vmStart.testVmNamePrefix
            }
        } catch {
            Write-Verbose "Could not read vmStart.testVmNamePrefix from $configPath`: $_"
        }
    }
}
if (-not $Prefix) { $Prefix = 'test-' }

# === Import Test.Host (needed for Get-HostType on every platform) ===
$hostModPath = Join-Path $ModulesDir "Test.Host.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force

$HostType = Get-HostType
if (-not $HostType) { exit 1 }

# On host.ubuntu.kvm: auto-relaunch under `sg libvirt -c "..."` when this
# shell's running group set lacks libvirt (otherwise every virsh call
# below would hit "Permission denied" on /var/run/libvirt/libvirt-sock).
# Helper is a no-op on macOS/Windows and on already-fresh shells.
Invoke-LibvirtGroupReExecIfNeeded -HostType $HostType -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters

Write-Status "Host type: $HostType"
Write-Status ""

# Fast pre-flight: refuse to call host VM cmdlets without the absolute
# minimum (Administrator on Hyper-V, virsh/utmctl reachable on
# KVM/UTM). Without this gate, Hyper-V\Get-VM dies inside the switch
# below with a raw "You do not have the required permission..." that
# names the computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType -Quiet:$Quiet)) { exit 1 }

# Wire the host driver so the contract (Stop-VMForce, Remove-VM, ...) is
# available on every host. The HostType switch below stays because the
# enumeration step (find every test-* VM on the host) is host-specific
# and the contract does not yet include a "list-VMs-by-prefix" call --
# add Get-VMNames -Prefix to host/<x>/modules/Yuruna.Host.psm1 to drop
# the switch entirely. The contract's Get-VMState / Stop-VMForce /
# Remove-VM are used inside each branch so per-VM cleanup is uniform.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# === Stop all test-* VMs ===
Write-Status "Stopping VMs with prefix '$Prefix'..."
Write-Status ""

# Track every VM we attempted, with a final disposition. Per-VM ops MUST
# NOT abort the whole loop: on a long-running host, a single stuck VM
# (locked .vhdx, wedged vmms, UTM helper holding a file handle) used to
# throw under $ErrorActionPreference='Stop' and skip every later test-*
# VM, so survivors accumulated cycle after cycle. Each VM is now wrapped
# in try/catch with its own continue-on-failure path; survivors are
# reported at the end and the orphan-file cleanup still runs so we
# reclaim disk even when one VM resists deletion.
$survivors = [System.Collections.Generic.List[string]]::new()
$removedCount = 0

switch ($HostType) {
    "host.windows.hyper-v" {
        # Module-qualified Hyper-V\Get-VM avoids our Yuruna.Host's shadowed
        # Get-VM (which doesn't exist anyway -- we expose Get-VMState instead).
        $testVMs = @(Hyper-V\Get-VM | Where-Object { $_.Name -like "${Prefix}*" })
        if ($testVMs.Count -eq 0) {
            Write-Status "  No Hyper-V VMs found matching '${Prefix}*'."
        }
        foreach ($vm in $testVMs) {
            $vmName = $vm.Name
            Write-Status "  Stopping $vmName [$($vm.State)]..."
            try {
                if ((Get-VMState -VMName $vmName) -ne 'stopped') {
                    # Stop-VMForce (Yuruna.Host) escalates to killing vmwp.exe
                    # when graceful Stop-VM cannot bring the VM to 'Off' within
                    # the timeout -- avoids a stuck 'Stopping' VM blocking the
                    # whole cleanup loop. -Confirm:$false: automated harness
                    # must not prompt.
                    $stopped = Stop-VMForce -VMName $vmName -StopTimeoutSeconds 20 -Confirm:$false
                    if ($stopped) {
                        Write-Status "    Stopped."
                    } else {
                        Write-Warning "    Stop-VMForce returned `$false for $vmName; Remove-VM may fail."
                    }
                } else {
                    Write-Status "    Already stopped."
                }
                # Remove-VM (Yuruna.Host) wraps the host's destroy-and-cleanup
                # path; on Hyper-V it removes the VHDX directory after the
                # vmms unregister.
                $removedOk = Remove-VM -VMName $vmName -Confirm:$false
                if (-not $removedOk -or (Get-VMState -VMName $vmName) -ne 'absent') {
                    $finalState = Get-VMState -VMName $vmName
                    Write-Warning "    Remove-VM did not fully remove '$vmName' (state: $finalState)."
                    $survivors.Add("$vmName [$finalState]")
                } else {
                    Write-Status "    Removed from Hyper-V."
                    $removedCount++
                }
            } catch {
                Write-Warning "    Failed to remove '$vmName': $_"
                $finalState = Get-VMState -VMName $vmName
                $survivors.Add("$vmName$(if ($finalState -and $finalState -ne 'absent') { " [$finalState]" })")
            }
        }
    }
    "host.ubuntu.kvm" {
        # `virsh list --all --name` enumerates every defined libvirt domain
        # (running, stopped, paused) one name per line. The `--connect` URI
        # matches what Yuruna.Host (host/ubuntu.kvm) talks to.
        $virshOutput = & virsh --connect qemu:///system list --all --name 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to query libvirt VMs. Is libvirtd running? Output: $virshOutput"
            exit 1
        }
        $testVMs = @(
            $virshOutput |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ -and ($_ -like "${Prefix}*") }
        )
        if ($testVMs.Count -eq 0) {
            Write-Status "  No libvirt VMs found matching '${Prefix}*'."
        }
        foreach ($vmName in $testVMs) {
            $state = Get-VMState -VMName $vmName
            Write-Status "  Stopping $vmName [$state]..."
            try {
                if ($state -notin @('stopped','absent')) {
                    # Stop-VMForce (Yuruna.Host) issues `virsh destroy` and
                    # falls back to SIGKILL on the qemu pid if destroy hangs.
                    $stopped = Stop-VMForce -VMName $vmName -StopTimeoutSeconds 20 -Confirm:$false
                    if ($stopped) {
                        Write-Status "    Stopped."
                    } else {
                        Write-Warning "    Stop-VMForce returned `$false for $vmName; Remove-VM may fail."
                    }
                } else {
                    Write-Status "    Already stopped."
                }
                # Remove-VM on KVM does undefine --nvram --remove-all-storage
                # and removes ~/yuruna/vms/<vmname>/.
                $removedOk = Remove-VM -VMName $vmName -Confirm:$false
                if (-not $removedOk -or (Get-VMState -VMName $vmName) -ne 'absent') {
                    $finalState = Get-VMState -VMName $vmName
                    Write-Warning "    Remove-VM did not fully remove '$vmName' (state: $finalState)."
                    $survivors.Add("$vmName [$finalState]")
                } else {
                    Write-Status "    Removed from libvirt."
                    $removedCount++
                }
            } catch {
                Write-Warning "    Failed to remove '$vmName': $_"
                $finalState = Get-VMState -VMName $vmName
                $survivors.Add("$vmName$(if ($finalState -and $finalState -ne 'absent') { " [$finalState]" })")
            }
        }
    }
    "host.macos.utm" {
        $utmOutput = & utmctl list 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to query UTM VMs. Is UTM running? Output: $utmOutput"
            exit 1
        }
        # utmctl exits 0 even when it can't reach UTM (Apple Events
        # permission denied -- typical from SSH or a non-Automation-
        # entitled host process). It just prints the error to stderr
        # and emits an empty list. Without this guard, every test-* VM
        # would look "absent" and the orphan-file sweep would delete
        # the bundles even though UTM still has them registered.
        $utmText = ($utmOutput | ForEach-Object { "$_" }) -join "`n"
        if ($utmText -match 'OSStatus error -1743|utmctl does not work from SSH') {
            Write-Error "utmctl could not reach UTM (Apple Events permission denied). Run this script from a Terminal session with Automation -> System Events access for pwsh, after UTM.app is launched and a user is logged in graphically. Output:`n$utmText"
            exit 1
        }
        $found = $false
        foreach ($line in $utmOutput) {
            $line = "$line".Trim()
            if (-not $line -or $line -match '^-+$') { continue }
            # utmctl list is fixed-column-width, NOT 2+-space-delimited.
            # Layout (UTM 4.x): UUID col is 37 chars (36-char UUID + 1
            # space padding), Status col is 9 chars (longest enum
            # 'starting'/'stopping' is 8 chars). So between UUID and
            # Status there is exactly ONE space -- splitting on \s{2,}
            # used to merge them into a 44-char parts[0] that never
            # matched the 36-char UUID regex, so the prefix match
            # silently scored zero hits on every line and every test-*
            # VM was skipped while staying registered + on disk.
            # Status enum from UTM.sdef: stopped, starting, started,
            # pausing, paused, resuming, stopping -- all <= 8 chars,
            # so the (\S+)\s+ grab is safe.
            if ($line -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
                $vmUuid = $matches[1]
                $vmName = $matches[3].Trim()
                if ($vmName -like "${Prefix}*") {
                    $found = $true
                    Write-Status "  Stopping $vmName..."
                    try {
                        & utmctl stop "$vmName" 2>&1 | Out-Null
                        # Wait for the VM to fully stop before deleting
                        $waited = 0
                        while ($waited -lt 30) {
                            Start-Sleep -Seconds 2
                            $waited += 2
                            $status = & utmctl status "$vmName" 2>&1
                            if ($status -match "stopped|shutdown") { break }
                        }
                        # Delete by UUID (more reliable than by name)
                        $deleted = $false
                        & utmctl delete "$vmUuid" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) { $deleted = $true }
                        if (-not $deleted) {
                            Write-Warning "    utmctl delete by UUID failed for '$vmName'. Retrying by name..."
                            Start-Sleep -Seconds 3
                            & utmctl delete "$vmName" 2>&1 | Out-Null
                            if ($LASTEXITCODE -eq 0) { $deleted = $true }
                        }
                        # Verify removal from UTM registry
                        if ($deleted) {
                            $null = & utmctl status "$vmUuid" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-Warning "    VM '$vmName' still present in UTM after delete."
                                $deleted = $false
                            }
                        }
                        if ($deleted) {
                            Write-Status "    Removed from UTM."
                            $removedCount++
                        } else {
                            Write-Warning "    Could not remove '$vmName' from UTM registry. Files will not be cleaned to avoid stale entries."
                            $survivors.Add($vmName)
                        }
                    } catch {
                        Write-Warning "    Failed to remove '$vmName': $_"
                        $survivors.Add($vmName)
                    }
                }
            }
        }
        if (-not $found) {
            Write-Status "  No UTM VMs found matching '${Prefix}*'."
        }
    }
    default {
        Write-Error "Unsupported host type: $HostType"
        exit 1
    }
}

Write-Status ""

# Re-scan to catch survivors that the per-VM block missed (e.g. a VM
# that flipped to OffCritical while the loop was iterating). Belt-and-
# suspenders against the very symptom this script exists to fix:
# test-* VMs surviving across cycles on a long-running host.
switch ($HostType) {
    "host.windows.hyper-v" {
        $remaining = @(Hyper-V\Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "${Prefix}*" })
        if ($remaining.Count -gt 0) {
            Write-Warning "  $($remaining.Count) Hyper-V VM(s) still match '${Prefix}*' after cleanup:"
            foreach ($vm in $remaining) {
                Write-Warning "    $($vm.Name) [$($vm.State)]"
            }
        }
    }
    "host.ubuntu.kvm" {
        $reList = & virsh --connect qemu:///system list --all --name 2>&1
        if ($LASTEXITCODE -eq 0) {
            $remaining = @(
                $reList |
                    ForEach-Object { "$_".Trim() } |
                    Where-Object { $_ -and ($_ -like "${Prefix}*") }
            )
            if ($remaining.Count -gt 0) {
                Write-Warning "  $($remaining.Count) libvirt VM(s) still match '${Prefix}*' after cleanup:"
                foreach ($n in $remaining) {
                    $st = Get-VMState -VMName $n
                    Write-Warning "    $n [$st]"
                }
            }
        }
    }
    "host.macos.utm" {
        $reList = & utmctl list 2>&1
        if ($LASTEXITCODE -eq 0) {
            $reText = ($reList | ForEach-Object { "$_" }) -join "`n"
            # Same Apple-Events-denial trap as the main parse block --
            # if the rescan can't talk to UTM, skip it rather than
            # mis-reporting "0 survivors" and continuing into the
            # orphan-file sweep.
            if ($reText -match 'OSStatus error -1743|utmctl does not work from SSH') {
                Write-Warning "  Rescan skipped: utmctl could not reach UTM (Apple Events permission denied)."
            } else {
                $remaining = @()
                foreach ($line in $reList) {
                    $line = "$line".Trim()
                    if (-not $line -or $line -match '^-+$') { continue }
                    # See main block: UUID-anchored regex, not \s{2,} split.
                    if ($line -match '^([0-9A-Fa-f-]{36})\s+(\S+)\s+(\S.*)$') {
                        $reName = $matches[3].Trim()
                        if ($reName -like "${Prefix}*") { $remaining += $reName }
                    }
                }
                if ($remaining.Count -gt 0) {
                    Write-Warning "  $($remaining.Count) UTM VM(s) still match '${Prefix}*' after cleanup:"
                    foreach ($n in $remaining) { Write-Warning "    $n" }
                }
            }
        }
    }
}

Write-Status ""
Write-Status "Removed $removedCount VM(s); $($survivors.Count) survivor(s)."
if ($survivors.Count -gt 0) {
    foreach ($s in $survivors) { Write-Warning "  Survivor: $s" }
}
Write-Status ""

$cleanupScript = Join-Path -Path $RepoRoot -ChildPath (Get-HostFolder $HostType) -AdditionalChildPath "Remove-OrphanedVMFiles.ps1"

if (-not (Test-Path $cleanupScript)) {
    Write-Error "Cleanup script not found: $cleanupScript"
    exit 1
}

# Always run the orphan-file sweep — even if some VMs survived the
# registry-removal step. Their on-disk files are still claimed by the
# surviving registration so the orphan script will skip them, but
# files left over from earlier failures (the actual symptom on
# long-running hosts) get reclaimed. The "Running orphaned VM file
# cleanup: <path>" line stays Write-Output (unconditional) so an
# automated caller running with -Quiet still sees a single line that
# proves the orphan sweep was attempted; -Quiet propagates down so
# Remove-OrphanedVMFiles itself emits no chatter.
Write-Output "Running orphaned VM file cleanup: $cleanupScript"
Write-Status ""
$orphanArgs = @{ Force = $true }
if ($Quiet) { $orphanArgs['Quiet'] = $true }
& $cleanupScript @orphanArgs
