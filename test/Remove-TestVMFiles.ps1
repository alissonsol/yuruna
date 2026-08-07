<#PSScriptInfo
.VERSION 2026.08.07
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

<#
.SYNOPSIS
    Stop and remove VMs (by name prefix) and their leftover files.
.DESCRIPTION
    Operator entry point, also invoked by the cycle-start sweep in
    Invoke-TestRunnerInnerLoop. Resolves the VM-name prefixes from -Prefix, then
    test.config.yml, and removes the matching VMs and their orphaned files.

    Host-neutral throughout: enumeration goes through the contract's
    Get-VMName and each VM is stopped and removed with Stop-VMForce /
    Remove-VM, so a project that names its VMs outside the test-VM prefix
    is swept the same way on every hypervisor.
.PARAMETER Prefix
    One or more VM-name prefixes selecting which VMs to remove. A VM is
    removed when its name starts with any of them. When omitted, the
    prefixes come from test.config.yml (vmStart.cleanupVmNamePrefixes,
    else vmStart.testVmNamePrefix) so a manual invocation matches what the
    runner used; falls back to "test-".

    Prefixes are matched literally, never as wildcards. Passing an empty
    string is refused rather than treated as "everything": a sweep that
    matched every VM would take the caching-proxy service and any unrelated VM on
    the host with it.
.PARAMETER Quiet
    Suppress per-step "Stopping ... Removed ..." chatter and the
    host-recommendation block so an automated caller gets a single visible
    line: "Running orphaned VM file cleanup: <path>". Routine status lines
    flip to Write-Verbose; Write-Warning and Write-Error remain visible
    because they always represent an actual problem the operator needs to
    see. -Quiet alone DOES NOT bypass any destructive confirmation.
.EXAMPLE
    ./Remove-TestVMFiles.ps1 -Prefix test-
#>

param(
    [string[]]$Prefix,
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
# vmStart.cleanupVmNamePrefixes, then vmStart.testVmNamePrefix, then the
# "test-" fallback. Reading the config matters when the operator runs this
# script directly after a stopped runner -- the runner passes -Prefix from
# the same config, so a manual invocation that fell back to "test-" would
# miss VMs whenever the operator had customized the prefixes.
if (-not $ExplicitPrefix) {
    $configPath = Join-Path $TestRoot 'test.config.yml'
    if (Test-Path $configPath) {
        try {
            Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
            Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Force -Global -ErrorAction Stop
            $cfg = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            $Prefix = Resolve-CleanupVmNamePrefix -VmStart $cfg.vmStart
        } catch {
            Write-Verbose "Could not read the cleanup prefixes from $configPath`: $_"
        }
    }
}
if (-not $Prefix) { $Prefix = @('test-') }

# Normalize and refuse an empty prefix. An empty string matches every VM,
# which would sweep the caching-proxy service and any unrelated VM sharing the
# host -- a far larger blast radius than any caller intends, and one that
# only shows up once it has already deleted something.
$Prefix = @($Prefix | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
if ($Prefix.Count -eq 0) {
    Write-Error "No usable VM-name prefix: -Prefix resolved to nothing. Pass an explicit prefix (an empty prefix would match every VM on the host)."
    exit 1
}

# --- REGION: Import Test.HostContract (needed for Get-HostType on every platform)
# -Global is load-bearing: when this script is invoked via the call operator
# from inside a module (the cycle runner calls it for the VM sweep), a -Force
# import without -Global pulls Test.HostContract (and its host-contract exports)
# out of the global table for unrelated modules (the legacy-eviction regression
# class). -Global keeps the contract globally resolvable for every caller.
$hostModPath = Join-Path $ModulesDir "Test.HostContract.psm1"
if (-not (Test-Path $hostModPath)) { Write-Error "Module not found: $hostModPath"; exit 1 }
Import-Module -Name $hostModPath -Force -Global

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
# minimum (Administrator on Hyper-V, virsh/utmctl reachable on KVM/UTM).
# Without this gate the enumeration below fails with the hypervisor's own
# raw message -- "You do not have the required permission..." names the
# computer but not the fix.
if (-not (Test-HostRequirement -HostType $HostType -Quiet:$Quiet)) { exit 1 }

# Wire the host driver so the contract (Get-VMName, Stop-VMForce,
# Remove-VM, ...) is available. Enumeration is the only host-specific part
# of a prefix sweep, and Get-VMName covers it, so this script names no
# hypervisor at all: a fix to the removal logic lands on all three hosts at
# once instead of needing three parallel edits.
[void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)

# --- REGION: Stop and remove every matching VM
$prefixLabel = ($Prefix -join "', '")
Write-Status "Stopping VMs with prefix '$prefixLabel'..."
Write-Status ""

# Track every VM we attempted, with a final disposition. Per-VM ops MUST
# NOT abort the whole loop: on a long-running host, a single stuck VM
# (locked .vhdx, wedged vmms, UTM helper holding a file handle) would
# otherwise throw under $ErrorActionPreference='Stop' and skip every later
# matching VM, so survivors accumulate cycle after cycle. Each VM is wrapped
# in try/catch with its own continue-on-failure path; survivors are reported
# at the end and the orphan-file cleanup still runs so we reclaim disk
# even when one VM resists deletion.
$survivors = [System.Collections.Generic.List[string]]::new()
$removedCount = 0

# Get-VMName throws when the host cannot be queried at all (utmctl denied
# Apple Events, libvirtd down, Hyper-V unelevated). That must stay fatal:
# treating "cannot ask" as "nothing matched" would report a clean host and
# let the orphan-file sweep below delete files still claimed by a live VM.
try {
    $targets = @(Get-VMName -Prefix $Prefix)
} catch {
    Write-Error "Could not enumerate VMs on '$HostType': $($_.Exception.Message)"
    exit 1
}

if ($targets.Count -eq 0) {
    Write-Status "  No VMs found matching '$prefixLabel'."
}
foreach ($vmName in $targets) {
    $state = Get-VMState -VMName $vmName
    Write-Status "  Stopping $vmName [$state]..."
    try {
        if ($state -notin @('stopped', 'absent')) {
            # Stop-VMForce escalates past a graceful stop (kill vmwp.exe /
            # virsh destroy + SIGKILL / utmctl stop --kill) so one wedged
            # guest cannot block the rest of the sweep.
            if (Stop-VMForce -VMName $vmName -StopTimeoutSeconds 20 -Confirm:$false) {
                Write-Status "    Stopped."
            } else {
                Write-Warning "    Stop-VMForce returned `$false for $vmName; Remove-VM may fail."
            }
        } else {
            Write-Status "    Already stopped."
        }
        # Remove-VM wraps each host's destroy-and-cleanup path: Hyper-V
        # unregisters then drops the VHDX dir, libvirt undefines with
        # --nvram --remove-all-storage, UTM deletes and removes the bundle.
        $removedOk = Remove-VM -VMName $vmName -Confirm:$false
        $finalState = Get-VMState -VMName $vmName
        if (-not $removedOk -or $finalState -ne 'absent') {
            Write-Warning "    Remove-VM did not fully remove '$vmName' (state: $finalState)."
            $survivors.Add("$vmName [$finalState]")
        } else {
            Write-Status "    Removed."
            $removedCount++
        }
    } catch {
        Write-Warning "    Failed to remove '$vmName': $_"
        $finalState = Get-VMState -VMName $vmName
        $survivors.Add("$vmName$(if ($finalState -and $finalState -ne 'absent') { " [$finalState]" })")
    }
}

Write-Status ""

# Re-scan to catch survivors the per-VM block missed (e.g. a VM that
# flipped to a transitional state while the loop was iterating).
# Belt-and-suspenders against the very symptom this script exists to fix:
# VMs surviving across cycles on a long-running host. A rescan that cannot
# reach the host is reported, not silently read as "no survivors".
try {
    $remaining = @(Get-VMName -Prefix $Prefix)
    if ($remaining.Count -gt 0) {
        Write-Warning "  $($remaining.Count) VM(s) still match '$prefixLabel' after cleanup:"
        foreach ($n in $remaining) { Write-Warning "    $n [$(Get-VMState -VMName $n)]" }
    }
} catch {
    Write-Warning "  Rescan skipped: could not enumerate VMs ($($_.Exception.Message))"
}

Write-Status ""
Write-Status "Removed $removedCount VM(s); $($survivors.Count) survivor(s)."
if ($survivors.Count -gt 0) {
    foreach ($s in $survivors) { Write-Warning "  Survivor: $s" }
}
Write-Status ""

# Release the per-cycle display surface this host attaches for screen-capture
# (the Hyper-V usbmmidd virtual display). The cycle-start path attaches it via
# Initialize-HostDisplay; tearing it down here cleans up a stale/duplicate
# monitor left by a mid-cycle KVM switch so it doesn't linger once the machine
# stops running tests. Dispatcher no-ops on hosts that attach nothing
# (macOS/Linux) and never throws.
Write-Status "Releasing host virtual display (if attached)..."
Remove-HostDisplay -HostType $HostType
Write-Status ""

$cleanupScript = Join-Path -Path $RepoRoot -ChildPath (Get-HostFolder $HostType) -AdditionalChildPath "Remove-OrphanedVMFiles.ps1"

if (-not (Test-Path $cleanupScript)) {
    Write-Error "Cleanup script not found: $cleanupScript"
    exit 1
}

# Always run the orphan-file sweep -- even if some VMs survived the
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

# Surface incomplete cleanup to an automated caller. Survivors are VMs that
# resisted registry removal; their on-disk files stay claimed so the orphan
# sweep above intentionally skips them. A caller (the cycle-start sweep) needs
# a non-zero exit to retry or alert instead of treating a partial teardown as
# clean. Run the orphan sweep first so the reclaimable files are always freed.
if ($survivors.Count -gt 0) {
    exit 1
}
