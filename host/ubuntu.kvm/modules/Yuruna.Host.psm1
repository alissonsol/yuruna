<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e8f
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
    (Windows Hyper-V). Same 36-function contract on all three; the
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

$script:HostTag        = 'host.ubuntu.kvm'
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:TestModulesDir = Join-Path $script:RepoRoot 'test/modules'
$script:HostFolder     = Join-Path $script:RepoRoot 'host/ubuntu.kvm'
$script:VirshUri       = 'qemu:///system'
$script:VmRootDir      = Join-Path $HOME 'yuruna/vms'
$script:PortMapDir     = Join-Path $HOME 'yuruna/portmap'

# These dependency modules are imported -Global: Yuruna.Host is -Force re-imported
# mid-cycle, and a bare -Force import here lands in Yuruna.Host's nested scope and
# EVICTS the global copy other modules call via qualified names (e.g.
# Test.Ssh\Invoke-GuestSsh) -- feedback_module_force_import_evicts_global.
Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.Ssh.psm1')          -Force -DisableNameChecking -Global
Import-Module (Join-Path $script:TestModulesDir 'Test.CachingProxy.psm1') -Force -DisableNameChecking -Global
# Shared squid download / TLS-bump stack -- single source of truth across host
# drivers. The X509 chain-validation callback lives there verbatim; this driver's
# cache-host discovery is injected via the -ResolveCacheHostIp scriptblock (see the
# Save-CachedHttpUri wrapper below). This also puts Test-DownloadAlreadyCurrent /
# Write-ImageSentinel on the table for the per-guest Get-Image.ps1 scripts.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking -Global
# Shared per-guest provisioning helper (the New-VM.ps1 child-runner) common to
# all three drivers.
Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking -Global

# Per-guest base image paths -- single table keeps Get-ImagePath, Get-Image,
# and the per-guest Get-Image.ps1 scripts in agreement. A typo or new guest
# fails loud here instead of silently composing the wrong path.
$script:ImagePathTable = @{
    'guest.amazon.linux.2023'  = "$HOME/yuruna/image/amazon.linux.2023/host.ubuntu.kvm.guest.amazon.linux.2023.qcow2"
    'guest.ubuntu.server.24' = "$HOME/yuruna/image/ubuntu.env/host.ubuntu.kvm.guest.ubuntu.server.24.iso"
    'guest.windows.11'    = "$HOME/yuruna/image/windows.11/host.ubuntu.kvm.guest.windows.11.iso"
}

# --- REGION: Private helpers

<#
.SYNOPSIS
    Run virsh and return its stdout/stderr lines as an array; never throws.
#>
function Invoke-Virsh {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param([Parameter(Mandatory)][string[]]$VirshArgs)
    $output = & virsh --connect $script:VirshUri @VirshArgs 2>&1
    if (-not $output) { return @() }
    return @($output | ForEach-Object { "$_" })
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

# --- REGION: VM lifecycle

<#
.SYNOPSIS
    Create a guest VM by running the per-guest New-VM.ps1 script.
#>
function New-VM {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-PerGuestNewVm, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$VMName,
        [string]$CachingProxyUrl,
        # Planner-cascaded username override; forwarded only when the
        # per-guest script declares -Username (introspected below).
        [string]$Username,
        # Planner-cascaded guest hostname (variables.hostname); same
        # declare-or-drop forwarding rule as -Username.
        [string]$Hostname
    )
    # Thin wrapper over the shared per-guest runner; the host subdir is the
    # only platform variable. Splatting $PSBoundParameters preserves the
    # conditional -CachingProxyUrl/-Username/-Hostname forwarding (the runner
    # checks ContainsKey) and propagates -WhatIf/-Confirm to its ShouldProcess.
    Invoke-PerGuestNewVm -HostSubdir 'host/ubuntu.kvm' @PSBoundParameters
}

<#
.SYNOPSIS
    Start a guest VM previously created by New-VM.
#>
function Start-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Start VM')) {
        return @{ success = $false; errorMessage = 'WhatIf' }
    }
    # Idempotent: a VM already running is success.
    $state = Get-VirshDomState -VMName $VMName
    if ($state -eq 'running') {
        return @{ success = $true; errorMessage = $null; alreadyRunning = $true }
    }
    if (-not $state) {
        return @{ success = $false; errorMessage = "VM '$VMName' is not defined to libvirt." }
    }
    $output = Invoke-Virsh -VirshArgs @('start', $VMName)
    if ($LASTEXITCODE -ne 0) {
        return @{ success = $false; errorMessage = "virsh start failed: $($output -join '; ')" }
    }
    return @{ success = $true; errorMessage = $null }
}

<#
.SYNOPSIS
    Stop a running guest VM (graceful by default; -Force uses Stop-VMForce).
#>
function Stop-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [switch]$Force
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, ($Force ? 'Force-stop VM' : 'Stop VM'))) { return $false }
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state -or $state -eq 'shut off') { return $true }   # already stopped
    if ($Force) { return [bool](Stop-VMForce -VMName $VMName -Confirm:$false) }
    Invoke-Virsh -VirshArgs @('shutdown', $VMName) | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }
    # virsh shutdown is asynchronous (ACPI shutdown signal); poll up to ~30s
    # for the OS to follow through.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VirshDomState -VMName $VMName) -in @('shut off', '')) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

<#
.SYNOPSIS
    Force-stop a guest VM via virsh destroy, escalating to a qemu pid kill when destroy fails.
#>
function Stop-VMForce {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$StopTimeoutSeconds = 20
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Force-stop VM (virsh destroy)')) { return $false }
    Invoke-Virsh -VirshArgs @('destroy', $VMName) | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # Last-resort escalation: find the qemu pid via libvirt's pidfile.
    # /var/run/libvirt/qemu/<vm>.pid is the canonical location on Ubuntu.
    $pidFile = "/var/run/libvirt/qemu/$VMName.pid"
    if (Test-Path -LiteralPath $pidFile) {
        try {
            $qpid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
            if ($qpid -gt 0) {
                # Absolute path makes this unambiguously the Linux 'kill'
                # binary, not PowerShell's Stop-Process alias.
                & sudo /bin/kill -9 $qpid 2>$null | Out-Null
                Start-Sleep -Seconds 1
                $deadline = (Get-Date).AddSeconds($StopTimeoutSeconds)
                while ((Get-Date) -lt $deadline) {
                    if ((Get-VirshDomState -VMName $VMName) -in @('shut off', '')) { return $true }
                    Start-Sleep -Seconds 1
                }
            }
        } catch {
            Write-Warning "Stop-VMForce: kill of pid in $pidFile failed: $($_.Exception.Message)"
        }
    }
    return $false
}

<#
.SYNOPSIS
    Remove a guest VM and its on-disk artifacts.
#>
function Remove-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Remove VM')) { return $false }

    # Force-stop first; ignore errors (VM may be absent or already stopped).
    Invoke-Virsh -VirshArgs @('destroy', $VMName) | Out-Null

    # --- REGION: https://yuruna.link/memory#why-remove-vm-on-kvm-omits-remove-all-storage
    Invoke-Virsh -VirshArgs @('undefine', '--nvram', $VMName) | Out-Null

    # Per-VM artifact directory (qcow2, seed.iso, autounattend.iso, nvram).
    # New-VM.ps1 places everything under ~/yuruna/vms/<vmname>/. This is
    # what actually deletes the per-VM disk; the virsh undefine above
    # only drops the libvirt domain definition + tracked NVRAM file.
    $vmDir = Join-Path $script:VmRootDir $VMName
    if (Test-Path -LiteralPath $vmDir) {
        try { Remove-Item -LiteralPath $vmDir -Recurse -Force -ErrorAction Stop }
        catch { Write-Warning "Remove-VM: could not delete '$vmDir' ($($_.Exception.Message))." }
    }
    return $true
}

<#
.SYNOPSIS
    Returns 'absent', 'stopped', 'running', or 'unknown' for the given VM.
#>
function Get-VMState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not (Get-Command virsh -ErrorAction SilentlyContinue)) { return 'absent' }
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state) { return 'absent' }
    switch -Regex ($state) {
        '^running$'                 { return 'running' }
        '^(shut off|crashed)$'      { return 'stopped' }
        '^(paused|in shutdown)$'    { return 'stopped' }
        '^(idle|pmsuspended)$'      { return 'stopped' }
        default                     { return 'unknown' }
    }
}

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

    Requires the domain to be stopped; the caller (Save-VMDiskSnapshot)
    handles the stop. Returns $false on any sub-step failure.
#>
function Rename-VM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Rename to '$NewName' and relocate storage")) { return $false }
    if ($VMName -eq $NewName) { return $true }
    if ((Get-VMState -VMName $VMName) -eq 'absent') {
        Write-Warning "Rename-VM: source domain '$VMName' not defined."
        return $false
    }
    if ((Get-VMState -VMName $NewName) -ne 'absent') {
        Write-Warning "Rename-VM: destination name '$NewName' already exists."
        return $false
    }
    # virsh domrename is libvirt >= 1.2.19; ubuntu 18.04+ has it. We do
    # not implement the older dumpxml/undefine/define fallback because
    # the supported KVM baseline (ubuntu.server.24/26) ships >= 9.x.
    Invoke-Virsh -VirshArgs @('domrename', $VMName, $NewName) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Rename-VM: virsh domrename '$VMName' -> '$NewName' failed."
        return $false
    }
    # Move the per-VM artifact dir. The qcow2 and seed.iso inside still
    # carry the old basename; rename them too so the on-disk layout is
    # self-consistent (handy when an operator goes looking with `ls`).
    $oldDir = Join-Path $script:VmRootDir $VMName
    $newDir = Join-Path $script:VmRootDir $NewName
    if (Test-Path -LiteralPath $oldDir) {
        try {
            Rename-Item -LiteralPath $oldDir -NewName $NewName -ErrorAction Stop
        } catch {
            Write-Warning "Rename-VM: domain renamed to '$NewName' but moving '$oldDir' -> '$newDir' failed: $($_.Exception.Message). Domain XML still references old paths; restore-snapshot may fail."
            return $false
        }
        foreach ($f in (Get-ChildItem -LiteralPath $newDir -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -like "$VMName*") {
                $renamed = $NewName + $f.Name.Substring($VMName.Length)
                try { Rename-Item -LiteralPath $f.FullName -NewName $renamed -ErrorAction Stop }
                catch { Write-Warning "Rename-VM: could not rename '$($f.FullName)' -> '$renamed' ($($_.Exception.Message))." }
            }
        }
    }
    # Rewrite XML disk paths. virsh domrename only touches <name>; disk
    # sources still point at the old dir + old basename. dumpxml ->
    # sed-replace -> define is the idiomatic libvirt way; we keep the
    # destination scope narrow by only replacing $oldDir occurrences.
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $NewName)
    if ($LASTEXITCODE -eq 0 -and $xml) {
        $xmlText = ($xml -join "`n")
        # Replace path AND the leaf basename when it was derived from $VMName.
        # The escape on $oldDir is so a name with regex metachars (unlikely
        # but possible: '.' in 'ubuntu.server.24' is fine literal but a
        # plain Replace is safer than a regex here).
        $newXmlText = $xmlText.Replace($oldDir, $newDir).Replace("$VMName.", "$NewName.")
        if ($newXmlText -ne $xmlText) {
            $tmpXml = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-rename-{0}.xml" -f [Guid]::NewGuid())
            try {
                Set-Content -LiteralPath $tmpXml -Value $newXmlText -Encoding utf8 -NoNewline -Force
                Invoke-Virsh -VirshArgs @('define', $tmpXml) 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Rename-VM: virsh define with rewritten XML failed; domain renamed but disk paths still point at old dir."
                    return $false
                }
            } finally {
                Remove-Item -LiteralPath $tmpXml -Force -ErrorAction SilentlyContinue
            }
        }
    }
    return $true
}

<#
.SYNOPSIS
    Save a disk-only snapshot of the VM, then rename the VM (and
    relocate its storage) so it persists across test-cycle cleanup.
.DESCRIPTION
    Uses libvirt's `virsh snapshot-create-as --atomic` against an
    offline domain. With the guest stopped there is no runtime state
    to capture, so the snapshot is purely a disk-level point. The
    --atomic flag rolls back partially-created snapshots on failure.

    After a successful snapshot, the domain is renamed to $Id (via
    Rename-VM, which also relocates ~/yuruna/vms/<old> -> .../<Id>
    and rewrites the XML disk sources) so the next cycle's
    Remove-TestVMFiles.ps1 leaves the persisted domain alone.
#>
function Save-VMDiskSnapshot {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Save disk snapshot '$Id' and rename to '$Id'")) { return $false }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    # Idempotent overwrite: drop any prior snapshot with the same name
    # before creating a new one. Failure here (no such snapshot) is
    # expected on the common path and intentionally ignored.
    Invoke-Virsh -VirshArgs @('snapshot-delete', $VMName, '--snapshotname', $Id) 2>&1 | Out-Null
    $out = Invoke-Virsh -VirshArgs @('snapshot-create-as', '--domain', $VMName, '--name', $Id, '--atomic')
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Save-VMDiskSnapshot: virsh snapshot-create-as failed for '$VMName/$Id': $($out -join '; ')"
        return $false
    }
    if ($VMName -ne $Id) {
        if (-not (Rename-VM -VMName $VMName -NewName $Id -Confirm:$false)) {
            Write-Warning "Save-VMDiskSnapshot: snapshot '$Id' saved but rename '$VMName' -> '$Id' failed; domain will be wiped on next cycle cleanup."
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Returns $true when snapshot $Id is present on $VMName, $false
    otherwise (including when the domain does not exist). Used by
    Test-Sequence.ps1's requiresSnapshot warm-path probe before
    deciding whether to walk the baseline chain.
#>
function Test-VMDiskSnapshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if ((Get-VMState -VMName $VMName) -eq 'absent') { return $false }
    Invoke-Virsh -VirshArgs @('snapshot-info', '--domain', $VMName, '--snapshotname', $Id) 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Restore-VMDiskSnapshot {
    <#
    .SYNOPSIS
        Revert $VMName to libvirt snapshot $Id via `virsh snapshot-revert`.
    .DESCRIPTION
        Verifies the snapshot exists with `snapshot-info` first so a
        typo'd Id does not bounce a healthy guest, stops the VM if it
        is running, then runs `snapshot-revert`. Returns the virsh exit
        status as a bool so callers can branch on success.
    .OUTPUTS
        [bool] $true on success; $false on missing snapshot or virsh failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Id
    )
    if (-not $PSCmdlet.ShouldProcess($VMName, "Restore disk snapshot '$Id'")) { return $false }
    # Verify the snapshot exists before stopping the VM, so a typo'd Id
    # doesn't bounce a healthy guest for nothing.
    Invoke-Virsh -VirshArgs @('snapshot-info', '--domain', $VMName, '--snapshotname', $Id) 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Restore-VMDiskSnapshot: no snapshot '$Id' on '$VMName'."
        return $false
    }
    if ((Get-VMState -VMName $VMName) -eq 'running') {
        if (-not (Stop-VM -VMName $VMName)) {
            [void](Stop-VMForce -VMName $VMName)
        }
    }
    $out = Invoke-Virsh -VirshArgs @('snapshot-revert', '--domain', $VMName, '--snapshotname', $Id)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Restore-VMDiskSnapshot: virsh snapshot-revert failed for '$VMName/$Id': $($out -join '; ')"
        return $false
    }
    return $true
}

<#
.SYNOPSIS
    Returns true when a console window is open for the given VM.
#>
function Test-VMConsoleOpen {
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
function Restart-VMConsole {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    if (-not $PSCmdlet.ShouldProcess($VMName, 'Restart console window')) { return $false }
    if (-not (Get-Command virt-viewer -ErrorAction SilentlyContinue)) {
        Write-Verbose "Restart-VMConsole: virt-viewer not installed; skipping."
        return $false
    }
    & pkill -f "virt-viewer.*$([regex]::Escape($VMName))" 2>$null | Out-Null
    Start-Sleep -Milliseconds 200
    & bash -c "setsid -f env GDK_BACKEND=x11 virt-viewer --connect '$($script:VirshUri)' '$VMName' </dev/null >/dev/null 2>&1" 2>$null
    Write-Verbose "    Reconnected virt-viewer for '$VMName'"
    return $true
}

# --- REGION: Image

<#
.SYNOPSIS
    Run the per-guest Get-Image.ps1 to download or refresh the base image.
#>
function Get-Image {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is delegated to Invoke-GetImage, which declares SupportsShouldProcess and calls it; -WhatIf/-Confirm propagate via the splatted PSBoundParameters.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Force
    )
    # Thin wrapper over the shared runner. The host subdir and the image-path
    # table (Get-ImagePath, injected as a CommandInfo resolved in THIS driver's
    # scope) are the platform variables. Unlike win/mac, this driver logs via
    # the bare Information stream rather than Write-GetImageLine, so the writer
    # is injected too -- `& (Get-Command Write-Information) $line` binds $line to
    # -MessageData positionally, identical to an inline `Write-Information $line`.
    Invoke-GetImage -HostSubdir 'host/ubuntu.kvm' -ResolveImagePath (Get-Command Get-ImagePath) -WriteLine (Get-Command Write-Information) @PSBoundParameters
}

<#
.SYNOPSIS
    Return the expected on-disk path of the base image for a guest.
#>
function Get-ImagePath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$GuestKey)
    return $script:ImagePathTable[$GuestKey]
}

# --- REGION: VM I/O

<#
.SYNOPSIS
    Type text into the guest VM via gui or ssh mechanism.
#>
function Send-Text {
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
    # (SSH and the Invoke-Sequence GUI dispatcher) do not yet honour it.
    if ($Sensitive) { Write-Debug "Send-Text: -Sensitive set on '$VMName'; log redaction not yet implemented on KVM." }
    if ($Mechanism -eq 'ssh') {
        if (-not $GuestKey) {
            Write-Warning "Send-Text -Mechanism ssh requires -GuestKey to determine the SSH login user."
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
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        # Import only when the dispatcher isn't already resolvable, so the
        # steady-state path (module already loaded by the outer loop) is a
        # no-op. -Global on the cold path: a bare -Force import evicts the
        # global Invoke-Sequence (and its nested modules) the outer loop
        # still calls (feedback_module_force_import_evicts_global); refresh
        # it in place instead.
        if (-not (Get-Command 'Invoke-Sequence\Send-Text' -ErrorAction SilentlyContinue)) {
            Import-Module $invokeSequence -Force -DisableNameChecking -Global
        }
        return [bool](Invoke-Sequence\Send-Text -HostType $script:HostTag -VMName $VMName -Text $Text -CharDelayMs $CharDelayMs)
    }
    Write-Warning "Send-Text -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a named key to the guest VM via gui or ssh mechanism.
#>
function Send-Key {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$Key,
        [ValidateSet('gui','ssh')][string]$Mechanism = 'gui'
    )
    if ($Mechanism -eq 'ssh') {
        Write-Warning "Send-Key -Mechanism ssh: not meaningful for SSH (use Send-Text with the typed command)."
        return $false
    }
    # Defer to Invoke-Sequence's host-aware dispatcher rather than mapping key
    # names here. A local map holds only single keycodes, so a modifier chord
    # (which `virsh send-key` expresses as several positional keycodes pressed
    # together) degrades silently to one keypress -- Ctrl-U arriving as a bare
    # 'u' typed into the guest. The dispatcher's Send-KeyKvm backend owns both
    # the chord table and the splat.
    $invokeSequence = Join-Path $script:TestModulesDir 'Invoke-Sequence.psm1'
    if (Test-Path $invokeSequence) {
        # Import only when the dispatcher isn't already resolvable: a -Force
        # import evicts the global Invoke-Sequence (and its nested modules)
        # the outer loop still calls
        # (feedback_module_force_import_evicts_global).
        if (-not (Get-Command 'Invoke-Sequence\Send-Key' -ErrorAction SilentlyContinue)) {
            Import-Module $invokeSequence -Force -DisableNameChecking -Global
        }
        return [bool](Invoke-Sequence\Send-Key -HostType $script:HostTag -VMName $VMName -KeyName $Key)
    }
    Write-Warning "Send-Key -Mechanism gui: Invoke-Sequence.psm1 not found at '$invokeSequence'."
    return $false
}

<#
.SYNOPSIS
    Send a mouse click at the given pixel coordinate.
#>
function Send-Click {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y
    )
    Write-Warning "Send-Click on host.ubuntu.kvm: not implemented (Hyper-V-only today). Use SSH-mode workloads on KVM. (vm='$VMName' ignored x=$X y=$Y)"
    return $false
}

<#
.SYNOPSIS
    Capture a PNG of the VM display from frame or window source.
#>
function Get-VMScreenshot {
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
    $ppm = [System.IO.Path]::ChangeExtension($OutFile, '.ppm')
    Invoke-Virsh -VirshArgs @('screenshot', $VMName, $ppm) | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $ppm)) {
        Write-Warning "Get-VMScreenshot: virsh screenshot failed for '$VMName'."
        return $null
    }
    if (Get-Command convert -ErrorAction SilentlyContinue) {
        & convert $ppm $OutFile 2>$null | Out-Null
    } elseif (Get-Command pamtopng -ErrorAction SilentlyContinue) {
        & pamtopng $ppm > $OutFile 2>$null
    } else {
        Write-Warning "Get-VMScreenshot: neither 'convert' (imagemagick) nor 'pamtopng' (netpbm) found; leaving raw PPM at $ppm."
        return $ppm
    }
    Remove-Item -LiteralPath $ppm -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $OutFile) { return $OutFile }
    return $null
}

<#
.SYNOPSIS
    Return a host-specific handle for the VM console window.
#>
function Get-VMConsoleHandle {
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

# --- REGION: Discovery

<#
.SYNOPSIS
    Poll Get-VMIp until an IPv4 address is discovered or timeout expires.
#>
function Wait-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [int]$TimeoutSeconds = 30,
        [int]$PollSeconds    = 3
    )
    # Get-Command runs in THIS driver's scope, so the shared poller resolves
    # our Get-VMIp; a bare name would resolve in the shared module's scope.
    Invoke-WaitVmIp @PSBoundParameters -ResolveVmIp (Get-Command Get-VMIp)
}

<#
.SYNOPSIS
    Return the guest's host-side IPv4, or null if not yet discoverable.
#>
function Get-VMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    # `virsh domifaddr` queries libvirt's lease database (dnsmasq for the
    # 'default' network). Three sources to try, in order of reliability:
    #   1) lease  -- the default; works for libvirt-managed networks
    #   2) agent  -- needs qemu-guest-agent installed in the guest
    #   3) arp    -- last resort; passive ARP cache scan
    # Two-pass per source: prefer routable v4, fall back to routable v6.
    # Downstream Add-PortMap uses pwsh forwarders that today bind v4
    # sockets, so v4 stays preferred; v6 is returned only when no v4 is
    # available so v6-only guests don't surface as $null.
    foreach ($source in @('lease', 'agent', 'arp')) {
        $lines = Invoke-Virsh -VirshArgs @('domifaddr', $VMName, '--source', $source)
        if ($LASTEXITCODE -ne 0) { continue }
        # Output rows look like:
        #   vnet0      52:54:00:1a:b2:c3    ipv4         192.168.122.42/24
        #   vnet0      52:54:00:1a:b2:c3    ipv6         2001:db8::1234/64
        foreach ($l in $lines) {
            if ($l -match '^\s*\S+\s+\S+\s+ipv4\s+(\d+\.\d+\.\d+\.\d+)/\d+') {
                $ip = $Matches[1]
                if ((Test-Ipv4Address $ip) -and ($ip -notmatch '^(127\.|169\.254\.)')) { return $ip }
            }
        }
        foreach ($l in $lines) {
            if ($l -match '^\s*\S+\s+\S+\s+ipv6\s+([0-9A-Fa-f:]+)/\d+') {
                $ip = $Matches[1]
                if ((Test-Ipv6Address $ip) -and ($ip -inotmatch '^(::1$|fe80:)')) { return $ip }
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Return the guest's MAC address, or null if not available.
#>
function Get-VMMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0 -or -not $xml) { return $null }
    $joined = [string]::Join("`n", $xml)
    # First <interface ...><mac address='xx:xx:..'/> wins -- harness VMs
    # have a single NIC by convention.
    if ($joined -match "<mac\s+address='([0-9a-fA-F:]{17})'") {
        return $Matches[1].ToLower()
    }
    return $null
}

# --- REGION: Networking

<#
.SYNOPSIS
    Return the name of the host-side External-type vSwitch or network.
#>
function Get-ExternalNetwork {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # libvirt convention: a bridged 'external' network ($env:YURUNA_EXTERNAL_NETWORK
    # or 'yuruna-external' if defined) is preferred when present; otherwise
    # fall back to the built-in NAT 'default' network. Callers compare the
    # returned name to the cache VM's interface in Test-CacheVMOnExternalNetwork.
    #
    # Only ACTIVE networks qualify: virt-install refuses an inactive
    # network at create time, and a failed bridge build can leave
    # 'yuruna-external' defined but deliberately stopped (see
    # New-YurunaExternalNetwork's rebuild-failure branch). Attaching a
    # guest to that network would strand it with no DHCP, so a candidate
    # that is defined but inactive is skipped with a pointer at the fix.
    $candidates = @()
    if ($Env:YURUNA_EXTERNAL_NETWORK) { $candidates += $Env:YURUNA_EXTERNAL_NETWORK }
    $candidates += @('yuruna-external', 'default')
    $active  = Invoke-Virsh -VirshArgs @('net-list', '--name')
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    foreach ($c in $candidates) {
        if ($active -contains $c) { return $c }
        if ($defined -contains $c) {
            Write-Warning "libvirt network '$c' is defined but not active -- skipping it. Start it with 'virsh -c qemu:///system net-start $c', or re-run test/Start-CachingProxy.ps1 to rebuild/heal it."
        }
    }
    return 'default'
}

<#
.SYNOPSIS
    Create the host-side External-type vSwitch or network if missing.
#>
function New-ExternalNetwork {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $PSCmdlet.ShouldProcess('libvirt default network', 'Ensure default network is up + autostart')) { return $null }
    # libvirt's default network ships with the daemon; nothing to create
    # here -- just ensure it's started and on autostart so guests find it.
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if (-not ($running -contains 'default')) {
        Invoke-Virsh -VirshArgs @('net-start', 'default') | Out-Null
    }
    Invoke-Virsh -VirshArgs @('net-autostart', 'default') | Out-Null
    return 'default'
}

# --- REGION: helpers for New-YurunaExternalNetwork
# Internal. Returns the interface name carrying the default IPv4 route, or
# $null if none. Filters out the NIC if it's already a bridge port whose
# master is the one we're about to (re-)create; matches "what's the WAN-
# facing physical NIC of this host" semantically.
function Get-YurunaDefaultRouteIface {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $jsonLines = & ip -j -4 route show default 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $jsonLines) { return $null }
    try {
        $routes = ($jsonLines -join "`n") | ConvertFrom-Json -ErrorAction Stop
    } catch { $null = $_; return $null }
    $first = @($routes) | Where-Object { $_.dev } | Select-Object -First 1
    if (-not $first) { return $null }
    return [string]$first.dev
}

# Internal. True iff $Iface is a wireless (802.11) interface. The kernel
# exposes /sys/class/net/<iface>/wireless for Wi-Fi NICs; the presence
# of the directory is a stable signal across drivers.
function Test-YurunaIfaceIsWifi {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Iface)
    return (Test-Path "/sys/class/net/$Iface/wireless")
}

# Internal. The reason $Iface cannot serve as a bridge's uplink port,
# or '' when it can. Only plain wired Ethernet works: bond/vlan/tunnel
# devices need their own netplan sections (declaring them under
# ethernets: misrenders or is rejected), and a name with characters
# outside the safe set would inject into the generated netplan yaml.
# Wi-Fi is checked separately by callers (it has its own operator-facing
# message).
function Get-YurunaIfaceBridgeBlocker {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    if ($Iface -notmatch '^[A-Za-z0-9_.-]+$') {
        return "its name contains characters that are unsafe to embed in netplan/nmcli configuration"
    }
    $typePath = "/sys/class/net/$Iface/type"
    if (Test-Path -LiteralPath $typePath) {
        $ifType = "$(Get-Content -LiteralPath $typePath -ErrorAction SilentlyContinue | Select-Object -First 1)".Trim()
        # ARPHRD_ETHER == 1; anything else (tun/wireguard/ppp/...) cannot
        # be a bridge port.
        if ($ifType -ne '1') { return "it is not an Ethernet-framed interface (ARPHRD type $ifType)" }
    }
    if (Test-Path -LiteralPath "/sys/class/net/$Iface/bonding") {
        return "it is a bond master (bonds need their own netplan 'bonds:' section)"
    }
    $ueventPath = "/sys/class/net/$Iface/uevent"
    if (Test-Path -LiteralPath $ueventPath) {
        $devtype = @(Get-Content -LiteralPath $ueventPath -ErrorAction SilentlyContinue) |
            Where-Object { $_ -match '^DEVTYPE=(.+)$' } | Select-Object -First 1
        if ($devtype -match '^DEVTYPE=(vlan|bond)$') {
            return "it is a $($matches[1]) device (declare it in its own netplan section, not as a plain NIC)"
        }
    }
    return ''
}

# Internal. If $Iface is already a slave of a Linux bridge, return the
# bridge name; otherwise $null. /sys/class/net/<iface>/master is the
# canonical kernel pointer for bridge membership.
function Get-YurunaIfaceBridgeMaster {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    $masterLink = "/sys/class/net/$Iface/master"
    if (-not (Test-Path $masterLink)) { return $null }
    $target = & readlink -f $masterLink 2>$null
    if (-not $target) { return $null }
    $candidate = Split-Path -Leaf $target
    # Confirm it actually IS a bridge (vs other master types like bond).
    if (Test-Path "/sys/class/net/$candidate/bridge") { return $candidate }
    return $null
}

# Internal. The MAC address currently on $Iface, or '' when unreadable.
# /sys/class/net/<iface>/address is the kernel's canonical view.
function Get-YurunaNicMac {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Iface)
    $macPath = "/sys/class/net/$Iface/address"
    if (-not (Test-Path -LiteralPath $macPath)) { return '' }
    $mac = (Get-Content -LiteralPath $macPath -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $mac) { return '' }
    return "$mac".Trim()
}

# Internal. The Linux bridge name a libvirt network is backed by
# (its <bridge name='...'/> element), or $null when the network has no
# bridge element or virsh cannot dump it.
function Get-YurunaLibvirtNetworkBridge {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkName)
    $xmlLines = Invoke-Virsh -VirshArgs @('net-dumpxml', $NetworkName)
    foreach ($line in $xmlLines) {
        if ($line -match "<bridge\s+name='([^']+)'") { return $matches[1] }
    }
    return $null
}

# Internal. True iff the libvirt network attaches guests to a HOST
# bridge (<forward mode='bridge'/>). NAT/routed/isolated networks also
# carry a <bridge name='virbrN'/> element, but that bridge is
# libvirt-owned and legitimately has no physical uplink -- libvirt's own
# dnsmasq serves DHCP on it directly -- so bridge-health probes and
# rebuilds must never touch it.
function Test-YurunaLibvirtNetworkIsBridgeMode {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$NetworkName)
    $xmlLines = Invoke-Virsh -VirshArgs @('net-dumpxml', $NetworkName)
    foreach ($line in $xmlLines) {
        if ($line -match "<forward\s+mode='bridge'") { return $true }
    }
    return $false
}

# Internal. The name of the NM connection currently ACTIVE on $Nic, or
# $Nic itself when none is found (best-effort fallback so operator
# recipes always show something actionable). Stock profiles are rarely
# named after the device ("Wired connection 1", "netplan-eno1"), and a
# recipe pointing at a nonexistent profile fails at the exact moment
# the operator is disconnected.
function Get-YurunaNicActiveProfileName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Nic)
    if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $Nic }
    $activeName = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                   Where-Object { $_ -match "^([^:]+):$([regex]::Escape($Nic))`$" } |
                   ForEach-Object { ($_ -split ':', 2)[0] } |
                   Select-Object -First 1)
    if ($activeName) { return $activeName }
    return $Nic
}

# Internal, pure. The operator rollback recipe for a (half-)built
# bridge. Ordered so connectivity is RESTORED before artifacts are torn
# down: an operator following it over SSH must not lose the session at
# step 1 with the restoring steps still unrun (activating the NIC's own
# profile detaches it from the bridge, so the later deletes are safe).
function Get-YurunaBridgeRollbackRecipe {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$BridgeName,
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$NicProfile
    )
    return @"
Rollback (run ALL of these, in this order -- connectivity first, so an
SSH session survives; each is a no-op when its artifact is absent):
  sudo nmcli device set '$Nic' managed yes
  sudo nmcli connection modify '$NicProfile' connection.autoconnect yes
  sudo nmcli connection up '$NicProfile'
  sudo nmcli connection delete '$BridgeName' '$BridgeName-slave-$Nic'
  sudo rm -f /etc/netplan/99-yuruna-external.yaml && sudo netplan apply
  sudo ip link delete '$BridgeName'
"@
}

# Internal. Stop (never undefine) $NetworkName when it is running --
# called when its backing host bridge is unusable and was not rebuilt.
# Get-ExternalNetwork only offers ACTIVE networks to guests, so stopping
# is what actually steers them to the NAT 'default' fallback instead of
# stranding them on a bridge that can never DHCP.
function Stop-YurunaUnusableExternalNetwork {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork''s failure paths; the public caller already gates via SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$NetworkName)
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if ($running -contains $NetworkName) {
        Invoke-Virsh -VirshArgs @('net-destroy', $NetworkName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Warning "Stopped libvirt network '$NetworkName' (its host bridge is unusable). Guests fall back to NAT 'default' until a re-run rebuilds the bridge."
        } else {
            Write-Warning "Could not stop libvirt network '$NetworkName' (virsh net-destroy exit $LASTEXITCODE) -- it stays ACTIVE on an unusable bridge, and guests attached to it will not get DHCP."
        }
    } else {
        Write-Warning "libvirt network '$NetworkName' remains defined but inactive; guests fall back to NAT 'default' until a re-run rebuilds the bridge."
    }
}

# Internal. True iff NetworkManager is installed AND running. Two checks
# rather than one: `command -v nmcli` can be present without NM active
# (the binary survives an `apt purge network-manager-runtime`), and a
# running NM is what we need to actually create+activate the bridge.
function Test-YurunaNetworkManagerActive {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $false }
    $state = & nmcli -t -f RUNNING general 2>$null
    return ("$state".Trim() -eq 'running')
}

# Internal. True iff NetworkManager actually MANAGES $Nic -- not merely that
# the NM daemon is running. On Ubuntu Server the netplan renderer defaults to
# systemd-networkd, so NM can be RUNNING yet manage zero devices: every NIC
# shows STATE 'unmanaged' in `nmcli device status`. Building a bridge with
# nmcli then adds the connection profiles fine but `nmcli connection up
# <bridge>` fails with "Failed to find a compatible device for this
# connection", and the cache silently falls back to NAT. So the bridge-backend
# choice must key off management of the target NIC, not the daemon's presence.
# The $StatusLines seam lets the classification be unit-tested without a live
# nmcli; omitted, it queries `nmcli -t -f DEVICE,STATE device status` live.
function Test-YurunaNicManagedByNetworkManager {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter()][AllowNull()][string[]]$StatusLines
    )
    if ($null -eq $StatusLines) {
        if (-not (Get-Command nmcli -ErrorAction SilentlyContinue)) { return $false }
        $StatusLines = @(& nmcli -t -f DEVICE,STATE device status 2>$null)
    }
    # Terse rows are 'DEVICE:STATE' (e.g. 'eno1:connected', 'eno1:unmanaged').
    $line = @($StatusLines) | Where-Object { $_ -match "^$([regex]::Escape($Nic)):" } | Select-Object -First 1
    if (-not $line) { return $false }          # NM doesn't list it -> NM doesn't manage it
    # Every NM device state EXCEPT 'unmanaged' (unavailable/disconnected/
    # connecting/connected/...) means NM will bind + build on the NIC.
    return ($line -notmatch ':unmanaged(\b|$)')
}

function Test-NetworkManagerCrashedRecently {
    <#
    .SYNOPSIS
        Returns $true if NetworkManager core-dumped within the last
        $WithinMinutes minutes. Read-only -- queries the systemd journal
        only (no sudo; journal read works for any 'adm'/'systemd-journal'
        group member).
    .DESCRIPTION
        NetworkManager 1.54.x can hit an internal settings-layer
        assertion (nm:ERROR:.../nm-settings-utils.c: assertion failed)
        while a Linux bridge is being created via nmcli, and then SIGABRT
        itself (systemd records 'code=dumped, status=6/ABRT'). That
        crash is what raises Ubuntu's apport "system problem detected"
        dialog. Once it has happened, re-running the same nmcli sequence
        just crashes NM again. Callers use this to SKIP the nmcli bridge
        path and fall back to libvirt NAT instead of re-triggering the
        crash + another apport report.
    .PARAMETER WithinMinutes
        Look-back window. Default 60. Use a short window (~3) right after
        an nmcli call to attribute a just-now failure to a NM crash.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([int]$WithinMinutes = 60)
    if (-not (Get-Command journalctl -ErrorAction SilentlyContinue)) { return $false }
    $hits = & journalctl -u NetworkManager --since "-${WithinMinutes}min" --no-pager 2>$null |
        Select-String -Pattern 'code=dumped|core-dump|nm-settings-utils\.c.*assertion'
    return (@($hits).Count -gt 0)
}

function Write-YurunaNmcliFailure {
    <#
    .SYNOPSIS
        Emit the right diagnosis for a failed nmcli call: distinguish a
        NetworkManager crash (its own bug -- the apport-dialog source)
        from a plain rejected request, and surface the verbatim nmcli
        output either way.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [object[]]$NmcliOutput = @()
    )
    if (Test-NetworkManagerCrashedRecently -WithinMinutes 3) {
        Write-Warning "NetworkManager CRASHED while trying to $Operation."
        Write-Warning "  This is an upstream NetworkManager bug (an internal assertion in"
        Write-Warning "  nm-settings-utils.c, then SIGABRT) -- NOT a Yuruna fault -- and it"
        Write-Warning "  is what raised the Ubuntu 'system problem detected' dialog."
        Write-Warning "  The cache VM will fall back to libvirt NAT 'default' (host-only)."
        Write-Warning "  To stop this recurring: re-run with YURUNA_EXTERNAL_BRIDGE_SKIP=1,"
        Write-Warning "  upgrade NetworkManager, or define 'yuruna-external' manually"
        Write-Warning "  (see host/ubuntu.kvm/guest.caching-proxy/README.md)."
    } else {
        Write-Warning "nmcli: failed to $Operation. nmcli reported:"
        foreach ($l in @($NmcliOutput)) {
            if ("$l".Trim()) { Write-Warning "    $l" }
        }
    }
}

# Internal. Remove every stranded artifact a failed bridge bring-up can
# leave behind, so the next build starts from a truly clean slate. A
# half-built bridge strands THREE kinds of state, each from a different
# backend, and any one of them makes the next attempt fail in a new way:
#   * NM connection profiles ('$BridgeName' / '$BridgeName-slave-*'):
#     re-adding on top of them errors out, and feeding NM conflicting
#     profiles can trigger its nm-settings-utils.c assertion crash.
#   * the netplan file (99-yuruna-external.yaml): systemd-networkd keeps
#     claiming the bridge + NIC, and netplan's generated udev rule marks
#     them NM_UNMANAGED -- which makes `nmcli connection up <bridge>`
#     fail with "Failed to find a compatible device for this connection".
#   * the kernel bridge device itself: deleting the NM profile or the
#     netplan file does NOT remove an already-created device, and a
#     same-named device NM does not manage also produces that same
#     "no compatible device" nmcli failure.
# Callers invoke this ONLY when $Nic is not enslaved to $BridgeName, so
# nothing removed here can be carrying the host's connectivity: an
# uplink-less bridge forwards no traffic by construction.
function Clear-YurunaExternalBridgeResidue {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork''s build path, which already gates via SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    # Safety latches, not just comments: never sweep anything that could
    # be carrying the host's connectivity.
    #   * $Nic enslaved to $BridgeName: that bridge IS the host's uplink.
    #   * $Nic is itself a bridge: the caller mis-resolved (a leftover
    #     netplan bridge holding the default route after a reboot lands
    #     here if the reuse checks were skipped) -- deleting it would cut
    #     the host off with nothing left to restore it.
    #   * $BridgeName has some OTHER physical port, or holds the default
    #     route: it is somebody's live bridge (e.g. the default route
    #     moved to a second NIC between runs while the bridge still
    #     enslaves the first) -- not residue.
    if ((Get-YurunaIfaceBridgeMaster -Iface $Nic) -eq $BridgeName) {
        Write-Warning "Residue sweep skipped: '$Nic' is currently enslaved to '$BridgeName' (the bridge is live)."
        return
    }
    if (Test-Path -LiteralPath "/sys/class/net/$Nic/bridge") {
        Write-Warning "Residue sweep skipped: '$Nic' is itself a bridge device, not a NIC. Refusing to touch host bridges."
        return
    }
    if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
        if (Test-YurunaBridgeHasUplink -BridgeName $BridgeName) {
            Write-Warning "Residue sweep skipped: bridge '$BridgeName' has a physical port that is not '$Nic' -- it looks live, not stale. Inspect 'ls /sys/class/net/$BridgeName/brif' and remove it manually if it really is residue."
            return
        }
        $defRouteDev = Get-YurunaDefaultRouteIface
        if ($defRouteDev -eq $BridgeName) {
            Write-Warning "Residue sweep skipped: bridge '$BridgeName' holds the host's default route -- it looks live, not stale."
            return
        }
    }

    # 1. Stale NM profiles (a previous nmcli attempt, either as the picked
    #    backend or as the pre-fallback half of a previous run).
    if (Get-Command nmcli -ErrorAction SilentlyContinue) {
        $staleConns = @(& nmcli -t -f NAME connection show 2>$null) |
            Where-Object { $_ -eq $BridgeName -or $_ -like "$BridgeName-slave-*" }
        foreach ($sc in $staleConns) {
            Write-Information "  Residue sweep: deleting stale NetworkManager connection '$sc'."
            & sudo nmcli connection delete $sc 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
    }

    # 2. Stale netplan definition. Moving the file aside (netplan only
    #    reads *.yaml, so a .bak is inert -- and it preserves any hand
    #    edits an operator made) and regenerating drops systemd-networkd's
    #    on-disk claim AND the udev NM_UNMANAGED rules netplan generated.
    #    `netplan generate` only rewrites files under /run, though --
    #    the RUNNING daemons keep their old view until udev re-evaluates
    #    the devices and networkd reloads, so trigger both explicitly.
    $netplanPath = '/etc/netplan/99-yuruna-external.yaml'
    $sweptNetplan = $false
    if ((Test-Path -LiteralPath $netplanPath) -and (Get-Command netplan -ErrorAction SilentlyContinue)) {
        Write-Information "  Residue sweep: moving stale netplan file '$netplanPath' to '$netplanPath.bak'."
        & sudo mv -f $netplanPath "$netplanPath.bak" 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo netplan generate 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo udevadm control --reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo udevadm trigger --subsystem-match=net --action=change 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Get-Command networkctl -ErrorAction SilentlyContinue) {
            & sudo networkctl reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
        $sweptNetplan = $true
    }

    # 3. Stale kernel bridge device. The latches above guarantee this
    #    device carries no host traffic; any taps still attached belong
    #    to guests that have no connectivity anyway. Neither `netplan
    #    apply` nor networkd removes a netdev whose definition vanished,
    #    so an explicit delete is the only way to clear it.
    if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
        Write-Information "  Residue sweep: deleting stale kernel bridge device '$BridgeName'."
        & sudo ip link delete $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
            Write-Warning "  Residue sweep: 'ip link delete $BridgeName' did not remove the device -- the coming build may fail. Check 'ip -d link show $BridgeName'."
        }
    }

    # 4. Give the NIC back to NetworkManager when OUR netplan residue is
    #    what had unmanaged it. Scoped on purpose: if any REMAINING
    #    netplan file references the NIC (Ubuntu Server's cloud-init
    #    config, an operator file), networkd is its rightful owner and
    #    forcing NM onto it would start the exact two-daemon fight the
    #    sweep exists to end. `nmcli device set managed` is runtime-only
    #    state, but a previous run's 'managed no' survives for the rest
    #    of the boot and would silently pin the backend choice to
    #    netplan on hosts that should use nmcli.
    if ($sweptNetplan -and (Test-YurunaNetworkManagerActive)) {
        $nicState = @(& nmcli -t -f DEVICE,STATE device status 2>$null) |
            Where-Object { $_ -match "^$([regex]::Escape($Nic)):unmanaged(\b|$)" }
        if ($nicState) {
            $nicInOtherYaml = $false
            $otherYamls = @(Get-ChildItem -Path '/etc/netplan' -Filter '*.yaml' -ErrorAction SilentlyContinue)
            foreach ($f in $otherYamls) {
                $hit = & sudo grep -l -- $Nic $f.FullName 2>$null
                if ($hit) { $nicInOtherYaml = $true; break }
            }
            if (-not $nicInOtherYaml) {
                Write-Information "  Residue sweep: returning '$Nic' to NetworkManager management (only our removed netplan file had claimed it)."
                & sudo nmcli device set $Nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
        }
    }
}

# Internal. True iff $BridgeName has at least one physical (non-tap)
# port. Tap ports (vnetN/tapN) are guest-side only; without a physical
# port the bridge has no path to the upstream LAN/DHCP server.
function Test-YurunaBridgeHasUplink {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$BridgeName)
    $brifDir = "/sys/class/net/$BridgeName/brif"
    if (-not (Test-Path -LiteralPath $brifDir)) { return $false }
    $ports = @(Get-ChildItem -LiteralPath $brifDir -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -notmatch '^(vnet|tap)\d+$' })
    return ($ports.Count -gt 0)
}

# Internal. Wait until $BridgeName has a physical uplink port -- or, when
# -Nic is given, until that specific NIC is enslaved. $true on success.
# Wall-clock deadline (not an iteration count): the per-iteration probes
# add their own latency, so a counted loop would stretch past the budget.
function Wait-YurunaBridgeUplink {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$BridgeName,
        [string]$Nic,
        [int]$TimeoutSeconds = 10
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        if ($Nic) {
            if (Test-Path -LiteralPath "/sys/class/net/$BridgeName/brif/$Nic") { return $true }
        } elseif (Test-YurunaBridgeHasUplink -BridgeName $BridgeName) {
            return $true
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Milliseconds 500
    }
}

# --- REGION: https://yuruna.link/memory#why-the-libvirt-bridge-self-heal-probes-brif-and-activates-the-slave
function Repair-YurunaExternalBridgeSlave {
    <#
    .SYNOPSIS
        Probe the host bridge behind a libvirt network; heal a missing
        physical uplink, or report that the caller must rebuild.
    .DESCRIPTION
        A previous bring-up can leave the bridge half-built regardless of
        backend: the NM bridge connection up but the slave never
        activated, or the netplan definition applied but the NIC never
        released by NetworkManager. Either way the libvirt network looks
        fine to virsh while guests on it never get DHCP leases, because
        the bridge has no path to the upstream DHCP server. This probes
        /sys/class/net/<bridge>/brif for a physical (non-tap) port and,
        when it is missing, heals with the backend that owns the bridge:
          * netplan definition present -> release the NIC from
            NetworkManager if it still holds it, re-run `netplan apply`,
            and wait for enslavement;
          * otherwise -> activate the NM bridge-slave connection(s)
            whose connection.master is the bridge.
        Healing may briefly flap the host's LAN session (the NIC migrates
        onto the bridge), same as the original build.
    .OUTPUTS
        [string] 'healthy' (uplink present), 'healed' (uplink restored),
        or 'rebuild' (bridge device missing, or uplink unrecoverable --
        the caller must rebuild the bridge from scratch).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper invoked from New-YurunaExternalNetwork only when its idempotency branch detects a half-built bridge. The user-facing caller (Start-CachingProxy.ps1) already opted in to network-changing behavior via New-YurunaExternalNetwork''s SupportsShouldProcess. Adding ShouldProcess here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkName)

    # Only <forward mode='bridge'/> networks are backed by a host bridge
    # this module owns. NAT/routed/isolated networks also carry a
    # <bridge name='virbrN'/> element, but that bridge is libvirt's own
    # (dnsmasq serves DHCP on it; no physical uplink by design) --
    # probing or rebuilding it would tear a WORKING network down.
    if (-not (Test-YurunaLibvirtNetworkIsBridgeMode -NetworkName $NetworkName)) { return 'healthy' }

    $bridgeName = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
    if (-not $bridgeName) { return 'healthy' }   # no bridge element; nothing to probe

    if (-not (Test-Path -LiteralPath "/sys/class/net/$bridgeName/brif")) {
        Write-Warning "Bridge '$bridgeName' (referenced by libvirt network '$NetworkName') does not exist on the host -- it must be rebuilt."
        return 'rebuild'
    }
    if (Test-YurunaBridgeHasUplink -BridgeName $bridgeName) { return 'healthy' }

    Write-Warning "Bridge '$bridgeName' has no physical uplink (only tap ports attached). Self-healing..."

    # Heal 1: the bridge is netplan-declared. The usual reason the uplink
    # is missing here is that NetworkManager never released the NIC to
    # systemd-networkd, so release it explicitly, then re-apply. The
    # netplan file is root-owned 600 -- read it via sudo.
    $netplanPath = '/etc/netplan/99-yuruna-external.yaml'
    if ((Test-Path -LiteralPath $netplanPath) -and (Get-Command netplan -ErrorAction SilentlyContinue)) {
        $netplanText = (& sudo cat $netplanPath 2>$null) -join "`n"
        if ($netplanText -match [regex]::Escape($bridgeName)) {
            $nic = $null
            if ($netplanText -match 'interfaces:\s*\[\s*([^\]\s,]+)') { $nic = $matches[1] }
            # A MAC pin in the yaml only applies when the device is
            # CREATED ([NetDev] MACAddress is not retro-fitted), so a
            # bridge that already exists with a generated MAC would keep
            # it after a re-apply and the host would renumber. Rebuild
            # instead: the sweep deletes the device and the fresh build
            # pins the NIC's MAC at creation.
            if ($nic) {
                $nicMac = Get-YurunaNicMac -Iface $nic
                $brMac  = Get-YurunaNicMac -Iface $bridgeName
                if ($nicMac -and $brMac -and ($nicMac -ne $brMac)) {
                    Write-Warning "Self-heal: bridge '$bridgeName' carries MAC $brMac while its uplink NIC '$nic' has $nicMac -- healing in place would leave the host renumbered. Rebuilding the bridge instead."
                    return 'rebuild'
                }
            }
            $released = $false
            if ($nic -and (Test-YurunaNicManagedByNetworkManager -Nic $nic)) {
                Write-Information "Self-heal: releasing '$nic' from NetworkManager (the netplan definition gives it to systemd-networkd)."
                & sudo nmcli device set $nic managed no 2>&1 | ForEach-Object { Write-Verbose "$_" }
                $released = $true
            }
            Write-Information "Self-heal: re-applying '$netplanPath' (brief outage possible)."
            & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if (Wait-YurunaBridgeUplink -BridgeName $bridgeName -Nic $nic) {
                Write-Information "Self-heal: bridge '$bridgeName' has its LAN uplink again; guests on libvirt network '$NetworkName' will DHCP normally."
                return 'healed'
            }
            # The failed re-apply just put the NIC under the stale
            # definition (dhcp off, bridge member) without delivering
            # the uplink -- undo it BEFORE handing back 'rebuild', or
            # the host sits addressless and the caller's rebuild path
            # cannot even resolve the default-route NIC. Moving the
            # yaml aside + re-applying restores whatever the surviving
            # netplan files declare for the NIC.
            Write-Warning "Self-heal via netplan did not restore the uplink. Undoing the attempt, then rebuilding the bridge from scratch."
            & sudo mv -f $netplanPath "$netplanPath.bak" 2>&1 | ForEach-Object { Write-Verbose "$_" }
            & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if ($released) {
                & sudo nmcli device set $nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
                & sudo nmcli device connect $nic 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
            # Give the restored config a moment to bring the default
            # route back, so the rebuild path can resolve the NIC.
            $routeDeadline = (Get-Date).AddSeconds(20)
            while (((Get-Date) -lt $routeDeadline) -and -not (Get-YurunaDefaultRouteIface)) {
                Start-Sleep -Seconds 1
            }
            return 'rebuild'
        }
    }

    # Heal 2: NM-built bridge -- activate the bridge-slave connection(s)
    # whose connection.master equals our bridge. `nmcli -g
    # connection.master c show <name>` returns just the value (empty for
    # non-slaves), avoiding colon-escaping issues in NAME fields.
    if (Test-YurunaNetworkManagerActive) {
        $slaveConns = @()
        $allNames = @(& nmcli -g NAME c show 2>$null | Where-Object { $_ })
        foreach ($n in $allNames) {
            $master = (& nmcli -g connection.master c show $n 2>$null | Select-Object -First 1)
            if ($master -and ("$master".Trim() -eq $bridgeName)) {
                $slaveConns += $n
            }
        }
        foreach ($slave in $slaveConns) {
            & sudo nmcli connection up $slave 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if (($LASTEXITCODE -eq 0) -and (Wait-YurunaBridgeUplink -BridgeName $bridgeName)) {
                Write-Information "Self-heal: activated bridge-slave '$slave'. Bridge '$bridgeName' now has a LAN uplink; guests on libvirt network '$NetworkName' will DHCP normally."
                return 'healed'
            }
            Write-Warning "Self-heal: 'sudo nmcli connection up $slave' did not restore the uplink. Trying any remaining slave candidates..."
        }
    }

    Write-Warning "No heal path restored the uplink of '$bridgeName' -- it will be rebuilt from scratch."
    return 'rebuild'
}

<#
.SYNOPSIS
    Create a host-side Linux bridge + matching libvirt network so a guest
    on this network DHCPs onto the host's LAN and is reachable by remote
    LAN clients (mirrors the Hyper-V Yuruna-External vSwitch role).

.DESCRIPTION
    Idempotent. If $NetworkName is already defined in libvirt, ensures
    it's active + autostart, then runs Repair-YurunaExternalBridgeSlave
    to self-heal a half-built host bridge (uplink NIC never enslaved --
    DHCP loops, guests get no lease). The self-heal is a no-op on a
    healthy bridge; on a broken one it re-attaches the uplink through
    whichever backend owns the bridge (netplan re-apply or NM slave
    activation), which may briefly flap the host's LAN session -- and
    when even that is impossible it falls THROUGH to rebuild the bridge
    from scratch. Otherwise (network not yet defined):

      1. Resolves the host's default-route NIC.
      2. Refuses Wi-Fi (most APs filter frames for the bridge-side MAC).
      3. Detects whether the NIC is already a bridge port -- reuses
         that bridge if so (no host networking change).
      4. Else sweeps the residue of any previous half-built attempt
         (stale NM profiles, stale netplan file, stale bridge device --
         each makes a fresh build fail differently), then creates a new
         bridge ($BridgeName) and moves the NIC onto it via nmcli
         (preferred) or netplan (fallback). THIS CAUSES A BRIEF NETWORK
         OUTAGE while DHCP migrates IP from the NIC to the bridge --
         callers running over SSH on this NIC should expect their
         session to drop and require reconnect.
      5. Defines + starts a libvirt network of type bridge.

    On failure the function returns $null after rolling back the
    half-built bridge state, and -- when the network was already
    defined -- stops the network so guests fall back to NAT 'default'
    instead of being attached to a bridge with no uplink.

.OUTPUTS
    The libvirt network name on success ($NetworkName), or $null.
#>
function Get-YurunaExternalNetworkPlan {
    <#
    .SYNOPSIS
        Read-only preview of what New-YurunaExternalNetwork WOULD do, so a
        caller can explain the host-networking impact to the operator
        up front -- before any change is made -- and decide whether to
        proceed. Has NO side effects: only queries virsh + the host's
        network interface state.
    .DESCRIPTION
        Mirrors steps 1-3 of New-YurunaExternalNetwork (idempotency
        check, default-route NIC resolution, already-bridged check)
        without performing step 4 (the actual bridge build). Lets
        Start-CachingProxy.ps1 print the brief-network-outage warning at
        the very start of the run instead of mid-way, and proceed in one
        shot with no ShouldProcess prompt.
    .OUTPUTS
        [hashtable] with keys:
          Action      'reuse-network' | 'reuse-bridge' | 'create-bridge'
                      | 'fallback-nat'
          NetworkName libvirt network name
          BridgeName  Linux bridge name (existing or to-be-created)
          Nic         default-route interface, or $null
          WillChangeHostNetworking  $true only for 'create-bridge'
          CanBridge   $false when a LAN-routable bridge is impossible
                      (no default route, or Wi-Fi NIC) -- the cache VM
                      then falls back to NAT 'default' (host-only),
                      which is degraded but NOT a hard failure
          Explanation operator-facing multi-line description
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    $plan = @{
        Action                   = $null
        NetworkName               = $NetworkName
        BridgeName                = $BridgeName
        Nic                       = $null
        WillChangeHostNetworking  = $false
        CanBridge                 = $true
        Explanation               = $null
    }

    # Step 1: libvirt network already defined?
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    if ($defined -contains $NetworkName) {
        $plan.Action = 'reuse-network'
        # Probe the backing bridge so the plan is truthful about whether
        # the run will flap host networking (heal/rebuild) or not. Only
        # <forward mode='bridge'/> networks are host-bridge-backed --
        # NAT/routed networks own their virbrN bridge (no physical
        # uplink by design; dnsmasq serves DHCP on it) and are reused
        # as-is.
        if (-not (Test-YurunaLibvirtNetworkIsBridgeMode -NetworkName $NetworkName)) {
            $plan.Explanation = "libvirt network '$NetworkName' already exists (not host-bridge-backed) -- it will be (re)started and set to autostart. No host networking change."
            return $plan
        }
        $xmlBridge = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridge) { $plan.BridgeName = $xmlBridge }
        if (-not $xmlBridge -or (Test-YurunaBridgeHasUplink -BridgeName $xmlBridge)) {
            $plan.Explanation = "libvirt network '$NetworkName' already exists (bridge uplink verified) -- it will be (re)started and set to autostart. No host networking change."
        } else {
            $plan.WillChangeHostNetworking = $true
            $plan.Nic = Get-YurunaDefaultRouteIface
            $recipe = if ($plan.Nic) {
                Get-YurunaBridgeRollbackRecipe -BridgeName $plan.BridgeName -Nic $plan.Nic -NicProfile (Get-YurunaNicActiveProfileName -Nic $plan.Nic)
            } else {
                'Rollback recipe: see the Rollback section of host/ubuntu.kvm/guest.caching-proxy/README.md.'
            }
            $plan.Explanation = @"
libvirt network '$NetworkName' already exists but its backing bridge
('$($plan.BridgeName)') is missing or has NO LAN uplink -- this run will heal
or rebuild it, causing a brief network outage like the original build.

$recipe
"@
        }
        return $plan
    }

    # Step 2: default-route NIC.
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "No IPv4 default route on the host -- a bridged LAN network cannot be built. The cache VM will use libvirt's NAT 'default' network and be reachable from THIS host only."
        return $plan
    }
    $plan.Nic = $nic

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "Default-route NIC '$nic' is Wi-Fi. Linux bridges don't work over 802.11 STA mode (APs drop frames for MACs the radio didn't authenticate), so a bridged network is impossible here. The cache VM will use NAT 'default' (host-only). Use a wired connection for LAN exposure."
        return $plan
    }

    # Step 3: NIC already a bridge itself, or a bridge port?
    if (Test-Path -LiteralPath "/sys/class/net/$nic/bridge") {
        if (-not (Test-YurunaBridgeHasUplink -BridgeName $nic)) {
            $plan.Action      = 'fallback-nat'
            $plan.CanBridge   = $false
            $plan.Explanation = "Default-route interface '$nic' is a Linux bridge with NO physical uplink (stale route on a dead bridge). Roll it back per host/ubuntu.kvm/guest.caching-proxy/README.md, then re-run. Until then the cache VM will use NAT 'default' (host-only)."
            return $plan
        }
        $plan.Action      = 'reuse-bridge'
        $plan.BridgeName  = $nic
        $plan.Explanation = "Default-route interface '$nic' is itself a Linux bridge -- it will be reused as-is. No host networking change."
        return $plan
    }
    $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
    if ($existingBridge) {
        $plan.Action      = 'reuse-bridge'
        $plan.BridgeName  = $existingBridge
        $plan.Explanation = "NIC '$nic' is already a port of bridge '$existingBridge' -- it will be reused as-is. No host networking change."
        return $plan
    }

    # Step 3.5: only plain wired Ethernet can back the bridge.
    $blocker = Get-YurunaIfaceBridgeBlocker -Iface $nic
    if ($blocker) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = "Default-route NIC '$nic' cannot back a bridge: $blocker. The cache VM will use NAT 'default' (host-only)."
        return $plan
    }

    # Step 4: the bridge would have to be built. Before committing to
    # that, check whether NetworkManager has crashed recently -- if it
    # has, the nmcli bridge-build sequence is what crashed it (upstream
    # NM assertion bug), and re-running it just crashes NM again plus
    # raises another apport "system problem" dialog. Degrade to NAT.
    if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
        $plan.Action      = 'fallback-nat'
        $plan.CanBridge   = $false
        $plan.Explanation = @"
NetworkManager has core-dumped recently on this host (visible in its
journal -- an internal NM assertion in nm-settings-utils.c, triggered by
nmcli bridge creation). That crash is what raised the Ubuntu 'system
problem detected' dialog.

Re-running the bridge build would just crash NetworkManager again, so it
will be SKIPPED. The cache VM will use libvirt's NAT 'default' network
(reachable from this host only) -- which is fully functional for guests
on this same host.

For LAN exposure despite the NM bug, either:
  * upgrade NetworkManager (the assertion is an upstream NM defect), or
  * define the 'yuruna-external' bridge manually (netplan) -- see
    host/ubuntu.kvm/guest.caching-proxy/README.md
"@
        return $plan
    }

    # The bridge would have to be built -- this is the only branch that
    # perturbs host networking. The rollback recipe names the NIC's REAL
    # active profile ("Wired connection 1", "netplan-eno1", ...): stock
    # profiles are rarely named after the device, and a recipe pointing
    # at a nonexistent profile fails at the exact moment the operator is
    # disconnected.
    $nicProfile = Get-YurunaNicActiveProfileName -Nic $nic
    $plan.Action                  = 'create-bridge'
    $plan.WillChangeHostNetworking = $true
    $plan.Explanation = @"
The host's default-route NIC ($nic) will be moved onto a new Linux bridge
($BridgeName). The bridge clones the NIC's MAC and requests a DHCP lease in
its place -- normally the SAME IP comes back -- causing a brief network
outage (typically 1-5 s on a responsive DHCP server). An SSH session over
$nic will likely drop and reconnect once the lease arrives. Leftovers from
any previous half-built attempt (NetworkManager profiles, the netplan file,
a stale '$BridgeName' device) are swept first.

$(Get-YurunaBridgeRollbackRecipe -BridgeName $BridgeName -Nic $nic -NicProfile $nicProfile)
"@
    return $plan
}

<#
.SYNOPSIS
    Define a libvirt bridged network ($NetworkName, default 'yuruna-external')
    backed by a host bridge ($BridgeName, default 'yuruna-br0') over the
    default-route NIC, so cache and test guests are reachable from the LAN.
.DESCRIPTION
    Idempotent and self-healing. On a host where the libvirt network is
    already defined, returns the network name immediately AFTER checking
    that its backing bridge has a working LAN uplink (a previous bring-up
    can leave the bridge half-built -- uplink NIC never enslaved -- and
    guests on it never get DHCP leases). If the bridge is half-built,
    Repair-YurunaExternalBridgeSlave re-attaches the uplink via the
    backend that owns the bridge; if the bridge is unrecoverable it is
    rebuilt from scratch under the same name.

    On a clean host:
      1. Resolves the default-route NIC (refuses Wi-Fi; bridges over Wi-Fi
         don't work for guest traffic the way they do over Ethernet).
      2. Sweeps stale residue from previous attempts, then builds the
         Linux bridge via NetworkManager (nmcli) or netplan -- picked by
         which backend manages the NIC. Brief LAN flap (1-5 s) while
         DHCP migrates from the bare NIC onto the bridge (the bridge
         clones the NIC's MAC, so the same IP normally comes back).
      3. Defines the libvirt network as a forward-mode=bridge interface
         pointing at the new host bridge, sets it autostart, starts it.

    All diagnostics are emitted via Write-Information / Write-Warning /
    Write-Error so the function's only success output stays the single
    network name string -- callers can safely assign with
    `$x = New-YurunaExternalNetwork`. A stray Write-Output would turn $x
    into a string[] and break downstream consumers (Get-ExternalNetwork
    compares against the exact name).
.PARAMETER NetworkName
    libvirt network name. Default 'yuruna-external'.
.PARAMETER BridgeName
    Host bridge interface name. Default 'yuruna-br0'.
.OUTPUTS
    [string] The network name on success (existing OR freshly created),
    $null when the operator opted out via -WhatIf or when the bridge
    build failed.
#>
function New-YurunaExternalNetwork {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    [OutputType([string])]
    param(
        [string]$NetworkName = 'yuruna-external',
        [string]$BridgeName = 'yuruna-br0'
    )

    # IMPORTANT: this function's only pipeline output is a single string
    # (network name) or $null. All diagnostics MUST go through
    # Write-Information / Write-Warning / Write-Error so callers can
    # safely assign with `$x = New-YurunaExternalNetwork`. A stray
    # Write-Output would turn $x into a string[] and break downstream
    # consumers (Get-ExternalNetwork compares against this exact name).

    # --- REGION: Step 1: idempotency
    # Fast-return when the libvirt network is already defined -- but
    # NOT before verifying the backing host bridge actually has a LAN
    # uplink. A previous bring-up can leave the bridge half-built
    # (bridge NM connection up, slave never activated; or a netplan
    # definition NetworkManager never let converge): the libvirt network
    # looks fine to virsh, but guests on it never get DHCP leases because
    # the bridge has no path to the upstream DHCP server.
    # Repair-YurunaExternalBridgeSlave detects + self-heals that state;
    # when it reports 'rebuild' (bridge device gone, or uplink
    # unrecoverable) fall THROUGH to the build steps below instead of
    # returning a network that strands its guests.
    $defined = Invoke-Virsh -VirshArgs @('net-list', '--all', '--name')
    $netDefined = $defined -contains $NetworkName
    if ($netDefined) {
        Write-Information "libvirt network '$NetworkName' already defined."
        # Under -WhatIf report the network as-is BEFORE any mutation:
        # even (re)starting it counts -- a previous failed run may have
        # deliberately stopped it so guests fall back to NAT 'default',
        # and a preview must not re-arm a dead network.
        if ($WhatIfPreference) { return $NetworkName }
        $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
        if (-not ($running -contains $NetworkName)) {
            Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        }
        Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
        $repair = Repair-YurunaExternalBridgeSlave -NetworkName $NetworkName
        if ($repair -ne 'rebuild') { return $NetworkName }
        # Rebuild the bridge under the SAME name the network XML already
        # references, so the existing definition stays valid.
        $xmlBridge = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridge) { $BridgeName = $xmlBridge }
        Write-Information "Rebuilding host bridge '$BridgeName' for the existing libvirt network '$NetworkName'."
    }

    # --- REGION: Step 2: resolve default-route NIC
    # Every failure exit from here to the build must stop an
    # already-defined network (Stop-YurunaUnusableExternalNetwork):
    # the reuse branch above (re)started it BEFORE the bridge proved
    # unusable, and leaving it active would hand guests a bridge that
    # can never DHCP them -- the exact wedge the rebuild flow exists to
    # clear.
    $nic = Get-YurunaDefaultRouteIface
    if (-not $nic) {
        Write-Warning "No IPv4 default route on the host. Cannot create '$NetworkName' bridge -- connect a NIC to the LAN first."
        if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
        return $null
    }
    Write-Information "Default-route interface: $nic"

    if (Test-YurunaIfaceIsWifi -Iface $nic) {
        Write-Warning "Default-route NIC '$nic' is Wi-Fi. Linux bridges over Wi-Fi don't work in 802.11 STA mode -- most APs drop frames for any MAC the radio didn't authenticate, so the cache VM's DHCP request will be silently dropped. Run this on a wired connection."
        if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
        return $null
    }

    # --- REGION: Step 3: maybe the NIC is already bridged
    # If the operator (or a previous run) already put the WAN NIC on a
    # bridge, reuse it. This keeps the host networking change to zero:
    # we only need to define the libvirt network pointing at the existing
    # bridge. $BridgeName becomes a no-op suggestion in that case.
    # The default-route interface can also BE a bridge already (a
    # netplan-built bridge holds the route after a reboot) -- reuse it
    # directly; treating it as a NIC to enslave would try to put a
    # bridge inside itself.
    if (Test-Path -LiteralPath "/sys/class/net/$nic/bridge") {
        # Only a bridge that actually has its uplink is worth reusing. A
        # dead bridge can still hold a STALE default route (the kernel
        # keeps routes until the old lease ages out), and reusing it
        # would attach guests to a bridge that can never DHCP them --
        # while its real uplink NIC cannot be derived from the route.
        if (-not (Test-YurunaBridgeHasUplink -BridgeName $nic)) {
            Write-Warning "Default-route interface '$nic' is a Linux bridge with NO physical uplink (its route is stale). Cannot determine the real uplink NIC. Roll the bridge back per host/ubuntu.kvm/guest.caching-proxy/README.md, then re-run."
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }
        $existingBridge = $nic
        Write-Information "Default-route interface '$nic' is itself a Linux bridge. Reusing it (no host networking change)."
    } else {
        $existingBridge = Get-YurunaIfaceBridgeMaster -Iface $nic
        if ($existingBridge) {
            Write-Information "Interface '$nic' is already a port of bridge '$existingBridge'. Reusing it (no host networking change)."
        }
    }
    if ($existingBridge) {
        $BridgeName = $existingBridge
    } else {
        # --- REGION: Step 4: build the bridge
        # Guard: if NetworkManager has core-dumped recently AND NM is the
        # active backend, the nmcli bridge build is almost certainly what
        # crashed it (upstream NM assertion bug in nm-settings-utils.c).
        # Re-running it just crashes NM again and raises another apport
        # "system problem" dialog -- skip straight to NAT fallback. The
        # netplan backend (NM not active) is unaffected, so this guard is
        # scoped to the NM-active case only.
        if ((Test-YurunaNetworkManagerActive) -and (Test-NetworkManagerCrashedRecently)) {
            Write-Warning "NetworkManager has core-dumped recently on this host (see its journal)."
            Write-Warning "  The nmcli bridge build is what crashes it -- an upstream NM bug, not a"
            Write-Warning "  Yuruna fault. Skipping bridge creation to avoid crashing NM again."
            Write-Warning "  Cache VM will use libvirt NAT 'default' (host-only). For LAN exposure,"
            Write-Warning "  upgrade NetworkManager or define 'yuruna-external' manually."
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }

        # The full brief-network-outage warning + rollback recipe is
        # surfaced UP FRONT by the caller via Get-YurunaExternalNetworkPlan
        # (Start-CachingProxy.ps1's plan phase), so it isn't repeated here.
        # ShouldProcess is kept so a standalone or -Confirm caller still
        # gets a gate; Start-CachingProxy passes -Confirm:$false because it
        # already explained the impact and planned the run.
        Write-Information "Building Linux bridge '$BridgeName' on NIC '$nic' (brief network outage; rollback recipe: the Step 0 plan above, or the Rollback section of host/ubuntu.kvm/guest.caching-proxy/README.md)."

        # Only plain wired Ethernet can be enslaved; bond/vlan/tunnel
        # devices (or a hostile interface name) would produce a broken
        # netplan yaml or an unactivatable nmcli slave profile.
        $blocker = Get-YurunaIfaceBridgeBlocker -Iface $nic
        if ($blocker) {
            Write-Warning "Default-route NIC '$nic' cannot back the bridge: $blocker. Cache VM will use NAT 'default' (host-only)."
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }

        if (-not $PSCmdlet.ShouldProcess("$nic + $BridgeName", "Move '$nic' onto new Linux bridge '$BridgeName' (brief network outage)")) {
            Write-Warning "Bridge creation not confirmed. Cache VM will fall back to libvirt's NAT 'default' network (host-only)."
            if ($netDefined) {
                Write-Warning "NOTE: libvirt network '$NetworkName' stays as-is (its bridge is unusable); stop it with 'virsh -c qemu:///system net-destroy $NetworkName' or re-run and confirm the rebuild."
            }
            return $null
        }

        # Refresh the sudo timestamp BEFORE the outage window opens: the
        # build and its rollbacks issue sudo calls while host networking
        # flaps, where an expired timestamp would hang an unattended run
        # on an invisible password prompt. (Start-CachingProxy primes the
        # cache up-front; this covers standalone callers and long gaps.)
        & sudo -v 2>&1 | Out-Null

        # Sweep the residue of any previous half-built attempt FIRST --
        # stale NM profiles, a stale netplan definition, and the stale
        # kernel bridge device each make a fresh build fail in its own
        # way (see Clear-YurunaExternalBridgeResidue). Safe here by
        # construction: $nic is not enslaved (checked above), so nothing
        # the sweep removes carries the host's connectivity.
        Clear-YurunaExternalBridgeResidue -Nic $nic -BridgeName $BridgeName

        # Pick the bridge backend by whether NetworkManager actually MANAGES the
        # NIC -- not merely whether the NM daemon is running. On Ubuntu Server the
        # default netplan renderer is systemd-networkd, so NM can be running yet
        # manage no devices; nmcli then builds the bridge PROFILES but
        # `nmcli connection up` fails with "Failed to find a compatible device for
        # this connection" and the cache silently drops to NAT (the exact failure
        # this branch now avoids). netplan (systemd-networkd) is the native backend
        # there. When NM does manage the NIC (desktop / NM-rendered hosts) nmcli is
        # correct; fall back to netplan if it fails anyway so a plugin/version quirk
        # doesn't cost the LAN exposure + pool dashboard.
        $ok = $false
        if ((Test-YurunaNetworkManagerActive) -and (Test-YurunaNicManagedByNetworkManager -Nic $nic)) {
            $ok = New-YurunaBridgeViaNmcli -Nic $nic -BridgeName $BridgeName
            if (-not $ok) {
                Write-Warning "  nmcli bridge build failed; falling back to the netplan (systemd-networkd) path."
                $ok = New-YurunaBridgeViaNetplan -Nic $nic -BridgeName $BridgeName
            }
        } else {
            if (Test-YurunaNetworkManagerActive) {
                Write-Information "NetworkManager is running but does not manage '$nic' (systemd-networkd/netplan renderer) -- using the netplan path."
            } else {
                Write-Information "NetworkManager not active -- trying netplan path."
            }
            $ok = New-YurunaBridgeViaNetplan -Nic $nic -BridgeName $BridgeName
        }
        if (-not $ok) {
            Write-Warning "Bridge creation failed. The host's original NIC config was restored by the failing backend's rollback. See messages above for the specific tool error."
            if ($netDefined) { Stop-YurunaUnusableExternalNetwork -NetworkName $NetworkName }
            return $null
        }
    }

    # --- REGION: Step 5: define + start the libvirt network
    # libvirt's <forward mode='bridge'/> with a <bridge name='...'/> tells
    # qemu to attach guests directly to the named bridge via a tap; the
    # guest's MAC is visible on the LAN and gets its own DHCP lease.
    # In the rebuild flow the network is usually already defined and only
    # needs its definition refreshed when the backing bridge name changed
    # (the NIC turned up enslaved to a different bridge in Step 3).
    $needsDefine = -not $netDefined
    if ($netDefined) {
        $xmlBridgeNow = Get-YurunaLibvirtNetworkBridge -NetworkName $NetworkName
        if ($xmlBridgeNow -ne $BridgeName) {
            $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
            if ($running -contains $NetworkName) {
                Invoke-Virsh -VirshArgs @('net-destroy', $NetworkName) | Out-Null
            }
            Invoke-Virsh -VirshArgs @('net-undefine', $NetworkName) | Out-Null
            $needsDefine = $true
        }
    }
    if ($needsDefine) {
        $xmlContent = @"
<network>
  <name>$NetworkName</name>
  <forward mode='bridge'/>
  <bridge name='$BridgeName'/>
</network>
"@
        $xmlPath = New-TemporaryFile
        try {
            Set-Content -LiteralPath $xmlPath.FullName -Value $xmlContent -NoNewline
            Invoke-Virsh -VirshArgs @('net-define', $xmlPath.FullName) | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "virsh net-define '$NetworkName' failed (exit $LASTEXITCODE)."
                return $null
            }
        } finally {
            Remove-Item -LiteralPath $xmlPath.FullName -Force -ErrorAction SilentlyContinue
        }
    }
    $running = Invoke-Virsh -VirshArgs @('net-list', '--name')
    if (-not ($running -contains $NetworkName)) {
        Invoke-Virsh -VirshArgs @('net-start', $NetworkName) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "virsh net-start '$NetworkName' failed (exit $LASTEXITCODE). Try: sudo virsh -c qemu:///system net-start $NetworkName"
            return $null
        }
    }
    Invoke-Virsh -VirshArgs @('net-autostart', $NetworkName) | Out-Null
    Write-Information "libvirt network '$NetworkName' bridged on '$BridgeName' is ready."
    return $NetworkName
}

# Internal. Build $BridgeName via NetworkManager, with $Nic as a slave.
# Returns $true on success. Side effect: the active connection on $Nic
# is brought down and replaced by the bridge connection.
function New-YurunaBridgeViaNmcli {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    $slaveConn = "$BridgeName-slave-$Nic"
    # Stale profiles/devices from previous attempts were already removed
    # by Clear-YurunaExternalBridgeResidue in the caller's build path.

    # Clone $Nic's MAC onto the bridge IN THE ADD COMMAND, for two
    # reasons. DHCP identity: with the cloned MAC the bridge takes
    # $Nic's place in the DHCP server's lease table and the same IP
    # comes back, so the operator's SSH session and DNS A records
    # survive the migration. Activation determinism: a later
    # `connection modify` of the MAC races NM's handling of the
    # just-added profile -- if NM has already created the device with a
    # random MAC, re-activating a profile whose MAC no longer matches
    # the device fails with "Failed to find a compatible device for
    # this connection". Best-effort: if the MAC is unreadable we build
    # without the pin and warn (the bridge still works, just with a
    # fresh IP).
    $nicMac = Get-YurunaNicMac -Iface $Nic
    if (-not $nicMac) {
        Write-Warning "Could not read /sys/class/net/$Nic/address -- not cloning MAC onto bridge. DHCP may return a different IP than '$Nic' currently holds."
    }

    # nmcli connection add type bridge -- creates the bridge connection
    # profile. autoconnect=no on BOTH profiles: this build activates each
    # profile explicitly, in order (bridge, then slave), instead of
    # letting NM race ahead the moment a profile is added; autoconnect is
    # switched on at the end, once the bridge verifiably holds its
    # uplink. stp=no avoids the 30 s spanning-tree forwarding delay (we
    # have exactly one physical NIC under this bridge; loops are
    # impossible). ipv4.method=auto + ipv6.method=auto let the bridge
    # DHCP independently after $Nic's original IP lease is dropped.
    # nmcli output is captured (not piped to Write-Verbose) so
    # Write-YurunaNmcliFailure can surface the verbatim error -- or
    # diagnose a NetworkManager crash -- on failure.
    $addArgs = @('connection', 'add', 'type', 'bridge',
        'ifname', $BridgeName, 'con-name', $BridgeName,
        'autoconnect', 'no',
        'bridge.stp', 'no',
        'ipv4.method', 'auto',
        'ipv6.method', 'auto')
    if ($nicMac) { $addArgs += @('bridge.mac-address', $nicMac) }
    $addOut = & sudo nmcli @addArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge connection '$BridgeName'" -NmcliOutput $addOut
        return $false
    }

    # Attach $Nic as a bridge-slave. This profile is the one NM will
    # auto-activate at boot to keep the bridge populated (autoconnect is
    # enabled at the end of the build).
    $slaveOut = & sudo nmcli connection add type bridge-slave ifname $Nic master $BridgeName `
        con-name $slaveConn autoconnect no 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "add bridge-slave connection for '$Nic'" -NmcliOutput $slaveOut
        # Delete the orphan bridge profile so a retry (or the netplan
        # fallback) starts clean.
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        return $false
    }

    # Record which profile currently holds $Nic -- needed twice: the
    # success epilogue disables its autoconnect (so on reboot the bridge
    # activates, not the bare NIC re-grabbing the LAN IP and starving
    # the bridge of carrier), and the failure paths re-activate it so a
    # failed build NEVER strands the host without networking. It is NOT
    # modified before activation: the explicit slave 'up' below already
    # overrides a competing active profile, and touching autoconnect
    # early opens a window where a failure (or crash) leaves the NIC
    # with no profile that will ever reconnect it.
    $oldConn = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                Where-Object { $_ -match "^([^:]+):$Nic`$" } |
                ForEach-Object { ($_ -split ':', 2)[0] } |
                Select-Object -First 1)
    if ($oldConn -and ($oldConn -eq $slaveConn -or $oldConn -eq $BridgeName)) { $oldConn = $null }
    $restoreNic = {
        Write-Warning "  Re-activating '$Nic's original connection so the host keeps its networking."
        if ($oldConn) {
            & sudo nmcli connection up $oldConn 2>&1 | ForEach-Object { Write-Verbose "$_" }
        } else {
            & sudo nmcli device connect $Nic 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
    }

    # Activate the bridge profile. This creates the kernel bridge
    # interface under NM's control but does NOT yet take $Nic's
    # carrier -- contrary to a tempting reading, `nmcli c up <bridge>`
    # does not auto-enslave member ports. The bridge sits up with no
    # uplink until the slave is brought up below; DHCP on the bridge
    # will start, time out at ~45 s with `ip-config-unavailable`, and
    # loop -- which is exactly the failure mode that strands the cache
    # VM with no IP if this branch is skipped.
    Write-Information "  Activating bridge '$BridgeName'..."
    $brUpOut = & sudo nmcli connection up $BridgeName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "bring up bridge '$BridgeName'" -NmcliOutput $brUpOut
        Write-Warning "  Removing the half-built bridge so the netplan fallback (or a re-run) starts clean."
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        return $false
    }

    # Critical: explicitly activate the slave so $Nic actually gets
    # enslaved to the bridge. The slave profile's autoconnect alone
    # is NOT sufficient when another profile (netplan-<nic>, "Wired
    # connection N", etc.) currently holds $Nic -- NM will not
    # auto-deactivate a competing active profile to satisfy a slave's
    # autoconnect. A user-initiated `nmcli c up $slaveConn` overrides
    # that policy: NM deactivates the conflicting profile, binds $Nic
    # to the slave, the bridge sees new carrier, and DHCP succeeds.
    # This is the moment SSH sessions over $Nic flap; with the cloned
    # MAC above the new DHCP lease should be the same IP and SSH
    # reconnects within a few seconds.
    Write-Information "  Enslaving '$Nic' to bridge '$BridgeName' (brief outage now)..."
    $slUpOut = & sudo nmcli connection up $slaveConn 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-YurunaNmcliFailure -Operation "enslave '$Nic' to bridge '$BridgeName'" -NmcliOutput $slUpOut
        Write-Warning "  Bridge came up but '$Nic' would not enslave -- guests would never get DHCP."
        Write-Warning "  Removing the half-built bridge so the netplan fallback (or a re-run) starts clean."
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        & $restoreNic
        return $false
    }

    # Trust /sys, not nmcli's exit code, for the state that actually
    # matters: $Nic present in the bridge's port list.
    if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic)) {
        Write-Warning "  '$Nic' is not in '$BridgeName's port list even though nmcli reported success."
        Write-Warning "  Removing the half-built bridge so the netplan fallback (or a re-run) starts clean."
        Clear-YurunaExternalBridgeResidue -Nic $Nic -BridgeName $BridgeName
        & $restoreNic
        return $false
    }

    # The bridge verifiably holds its uplink -- NOW make the layout
    # boot-persistent: both profiles autoconnect, the bridge pulls its
    # port up with it (autoconnect-slaves), and the old NIC profile
    # stops autoconnecting (it would otherwise re-grab the LAN IP at
    # boot and starve the bridge of its port).
    & sudo nmcli connection modify $BridgeName connection.autoconnect yes connection.autoconnect-slaves 1 2>&1 |
        ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Could not enable autoconnect on '$BridgeName' -- the bridge works now but will not self-assemble after a reboot ('sudo nmcli connection up $BridgeName' recovers it)."
    }
    & sudo nmcli connection modify $slaveConn connection.autoconnect yes 2>&1 |
        ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  Could not enable autoconnect on '$slaveConn' -- after a reboot run 'sudo nmcli connection up $slaveConn'."
    }
    if ($oldConn) {
        & sudo nmcli connection modify $oldConn connection.autoconnect no 2>&1 | Out-Null
    }

    # Wait up to 30 s for the bridge to DHCP. nmcli connection up
    # returns when the connection is "activated" -- which can be before
    # DHCP completes. A bridge with no IP is still useless for the
    # libvirt network we are about to define, so block here briefly.
    # Wall-clock deadline (not an iteration count): the per-iteration `ip`
    # probe adds its own latency, so a counted loop would stretch the 30 s
    # budget past the advertised timeout.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information "  Bridge '$BridgeName' DHCP-leased: $($brIp -replace '^\s+|\s+$','')"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning "Bridge '$BridgeName' holds its uplink but has no IPv4 lease after 30 s. Guests on it can still DHCP (their requests bridge straight onto the LAN); only host->guest reachability is degraded. Check 'ip -4 addr show $BridgeName' and your DHCP server."
    return $true
}

# Internal, pure (no side effects): the netplan yaml that moves $Nic
# onto $BridgeName. Three identity/ownership pins make this yaml behave
# the same on every host:
#   * renderer: networkd on each stanza -- a global 'renderer:
#     NetworkManager' (standard on Ubuntu Desktop) would otherwise turn
#     these definitions into NM keyfiles, and the build's explicit
#     NIC handoff to systemd-networkd would then fight the very config
#     it wrote.
#   * macaddress: pins the bridge's MAC to the NIC's, so the upstream
#     DHCP server re-issues the SAME lease the NIC held -- the host
#     keeps its IP and the operator's SSH session reconnects. Without
#     the pin, systemd's default MACAddressPolicy=persistent hands the
#     bridge a generated MAC: the host's IP changes, and MAC-filtering
#     DHCP setups issue nothing at all. NOTE: [NetDev] MACAddress only
#     applies at device CREATION -- the bridge device must not already
#     exist when this yaml is first applied.
#   * dhcp-identifier: mac -- networkd's DHCPv4 client defaults to a
#     machine-id-derived DUID, so even with the cloned MAC a server
#     that keys leases on client-id would renumber the host.
function Get-YurunaBridgeNetplanYaml {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName,
        [AllowEmptyString()][string]$Mac = ''
    )
    $macLine = if ($Mac) { "`n      macaddress: $Mac" } else { '' }
    return @"
network:
  version: 2
  ethernets:
    ${Nic}:
      renderer: networkd
      dhcp4: no
      dhcp6: no
  bridges:
    ${BridgeName}:
      renderer: networkd
      interfaces: [${Nic}]$macLine
      dhcp4: yes
      dhcp-identifier: mac
      dhcp6: yes
      parameters:
        stp: false
"@
}

# Internal. Build $BridgeName via netplan, with $Nic as the only port.
# Returns $true on success. Side effect: writes a new file under
# /etc/netplan/ and runs `netplan apply`, which renews the lease for the
# bridge in place of $Nic. On failure the netplan change is rolled back,
# keeping the "returns $false => host NIC config unchanged" contract the
# caller advertises.
function New-YurunaBridgeViaNetplan {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private helper; the public New-YurunaExternalNetwork caller already gates via SupportsShouldProcess (see the "Move $nic onto new Linux bridge" ShouldProcess call). Adding a nested gate here would double-prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Nic,
        [Parameter(Mandatory)][string]$BridgeName
    )
    # Stale profiles/devices from previous attempts were already removed
    # by Clear-YurunaExternalBridgeResidue in the caller's build path.

    # If NetworkManager currently manages the NIC (this path also runs as
    # the fallback after a failed nmcli build on an NM host), hand the
    # NIC off BEFORE apply. netplan's generated udev NM_UNMANAGED rule
    # only takes effect on the next device event, and in the window
    # between `netplan apply` restarting systemd-networkd and NM noticing,
    # both daemons configure the NIC: networkd tries to enslave it while
    # NM re-activates its profile on it -- and the bridge ends up
    # uplink-less, so guests never see a DHCP offer. `nmcli device set
    # managed no` releases the device immediately (runtime-only; the udev
    # rule makes it stick), and autoconnect off on the bound profile
    # stops NM re-grabbing it at its next restart.
    $handedOff = $false
    $oldConn = $null
    if (Test-YurunaNicManagedByNetworkManager -Nic $Nic) {
        $oldConn = (& nmcli -t -f NAME,DEVICE connection show --active 2>$null |
                    Where-Object { $_ -match "^([^:]+):$Nic`$" } |
                    ForEach-Object { ($_ -split ':', 2)[0] } |
                    Select-Object -First 1)
        if ($oldConn) {
            & sudo nmcli connection modify $oldConn connection.autoconnect no 2>&1 | Out-Null
        }
        Write-Information "  Releasing '$Nic' from NetworkManager (systemd-networkd takes it over on apply)."
        & sudo nmcli device set $Nic managed no 2>&1 | ForEach-Object { Write-Verbose "$_" }
        $handedOff = $true
    }

    # Local rollback: put the host back exactly as it was, so a $false
    # return never leaves a half-applied netplan layout behind (a stale
    # one is what makes the NEXT run's nmcli path fail with "no
    # compatible device"). `netplan apply` -- not merely generate -- is
    # load-bearing: generate only rewrites files under /run, and the
    # RUNNING systemd-networkd keeps the ingested bridge-slave/no-DHCP
    # view of the NIC until told to re-read. On a pure-networkd host
    # (the primary audience of this backend) apply is the only thing
    # that re-hands the NIC to the surviving original netplan config and
    # restores its DHCP; without it a failed build leaves the host
    # addressless until a manual apply or reboot.
    $netplanPath = "/etc/netplan/99-yuruna-external.yaml"
    $rollback = {
        & sudo rm -f $netplanPath 2>&1 | ForEach-Object { Write-Verbose "$_" }
        & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (Test-Path -LiteralPath "/sys/class/net/$BridgeName") {
            & sudo ip link delete $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        }
        if ($handedOff) {
            & sudo nmcli device set $Nic managed yes 2>&1 | ForEach-Object { Write-Verbose "$_" }
            if ($oldConn) {
                & sudo nmcli connection modify $oldConn connection.autoconnect yes 2>&1 | Out-Null
                & sudo nmcli connection up $oldConn 2>&1 | ForEach-Object { Write-Verbose "$_" }
            }
        }
    }

    # The yaml pins `renderer: networkd` on both stanzas (rationale in
    # Get-YurunaBridgeNetplanYaml's header): without the pin, a global
    # 'renderer: NetworkManager' -- standard on Ubuntu Desktop -- would
    # turn these definitions into NM keyfiles, and the NIC handoff above
    # would then fight the very config this path just wrote.
    $yaml = Get-YurunaBridgeNetplanYaml -Nic $Nic -BridgeName $BridgeName -Mac (Get-YurunaNicMac -Iface $Nic)
    # netplan files are root-owned 600; write via sudo+tee.
    $yaml | & sudo tee $netplanPath > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not write '$netplanPath'. Are you in the sudo group?"
        if ($handedOff) { & $rollback }
        return $false
    }
    & sudo chmod 600 $netplanPath 2>&1 | Out-Null

    # netplan validates the rendered config before applying. A parse
    # error here means our yaml is wrong; bail BEFORE running apply so
    # the operator's networking stays untouched.
    & sudo netplan generate 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "netplan generate failed -- the yaml at $netplanPath was rejected. Rolling it back."
        & $rollback
        return $false
    }

    Write-Information "  Applying netplan (brief outage now)..."
    & sudo netplan apply 2>&1 | ForEach-Object { Write-Verbose "$_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "netplan apply failed. Rolling the netplan change back."
        & $rollback
        return $false
    }

    # netplan apply returns before systemd-networkd finishes reassembling
    # the link set, and enslavement of $Nic is what actually makes the
    # bridge usable -- so verify it in /sys instead of trusting the exit
    # code. networkd enslaves in well under a second once it owns the
    # NIC; the wait is generous to ride out a slow daemon restart.
    if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic)) {
        # One forced attempt: enslaving by hand matches exactly what the
        # netplan config declares, so this cannot fight networkd -- it
        # only wins the race networkd just lost (usually against a
        # NetworkManager that had not fully released the NIC yet).
        Write-Warning "  '$Nic' did not enslave to '$BridgeName' after netplan apply. Forcing enslavement (ip link set)..."
        & sudo ip link set $Nic master $BridgeName 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if (-not (Wait-YurunaBridgeUplink -BridgeName $BridgeName -Nic $Nic -TimeoutSeconds 3)) {
            Write-Warning "Bridge '$BridgeName' has NO uplink port ('$Nic' will not enslave) -- guests on it would never get a DHCP offer. Rolling the netplan change back."
            & $rollback
            return $false
        }
    }

    # Wait up to 30 s for the bridge to DHCP. Same wall-clock deadline
    # rationale as the nmcli path: a counted loop would overrun the 30 s
    # budget because the per-iteration `ip` probe has its own latency.
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $brIp = & ip -4 -o addr show dev $BridgeName 2>$null | Select-String -Pattern 'inet '
        if ($brIp) {
            Write-Information "  Bridge '$BridgeName' DHCP-leased: $($brIp -replace '^\s+|\s+$','')"
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Warning "Bridge '$BridgeName' holds its uplink but has no IPv4 lease after 30 s. Guests on it can still DHCP (their requests bridge straight onto the LAN); only host->guest reachability is degraded. Check 'ip -4 addr show $BridgeName' and your DHCP server."
    return $true
}

<#
.SYNOPSIS
    Returns true if the caching-proxy VM is on a bridged libvirt network
    (LAN-routable IP, no host portproxy needed).
#>
function Test-CacheVMOnExternalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$VMName = 'yuruna-caching-proxy')
    # Matches the Hyper-V contract semantic: true iff the cache VM has
    # its own LAN-routable IP -- consumers on the LAN can hit it
    # directly with no host-side portproxy in the path. On KVM this is
    # equivalent to "VM's <source network='...'/> is NOT the NAT
    # 'default' network". 'yuruna-external' (bridge), any user-defined
    # YURUNA_EXTERNAL_NETWORK, or a custom bridge all qualify; only the
    # built-in NAT 'default' (192.168.122/24, host-only without a port
    # forwarder) does not.
    $state = Get-VirshDomState -VMName $VMName
    if (-not $state) { return $false }
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $VMName)
    if ($LASTEXITCODE -ne 0) { return $false }
    $joined = [string]::Join("`n", $xml)
    # Pull the first source network name from the dumpxml output.
    # Domains may have multiple interfaces; the first one is what the
    # cache VM lands on per our New-VM.ps1 (only one --network spec).
    if ($joined -notmatch "<source\s+network='([^']+)'") { return $false }
    $srcNet = $Matches[1]
    return ($srcNet -ne 'default')
}

<#
.SYNOPSIS
    Expose the caching-proxy VM's ports on the host's LAN IP so LAN
    clients reach the NAT-networked cache at http://<host-lan-ip>:<port>.
.DESCRIPTION
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
.OUTPUTS
    [bool] $true when at least one forwarder socket is listening.
#>
function Add-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMIp,
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
        Write-Warning "Add-PortMap: VMIp '$VMIp' is not a valid IPv4 address -- skipping LAN exposure."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMIp, "Install systemd socket-proxy forwarders for ports $($Port -join ',')")) { return $false }

    # systemd-socket-proxyd: Ubuntu ships it under /usr/lib/systemd;
    # older layouts use /lib/systemd. The unit's ExecStart needs an
    # absolute path, so resolve it now and bail clearly if absent.
    $proxyd = @('/usr/lib/systemd/systemd-socket-proxyd','/lib/systemd/systemd-socket-proxyd') |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $proxyd) {
        Write-Warning "Add-PortMap: systemd-socket-proxyd not found -- cannot expose the cache on the host LAN IP."
        return $false
    }

    # Build the hostPort -> vmPort mapping list. Straight ports map 1:1;
    # a PortRemap entry (e.g. 8022 -> 22) overrides that hostPort. This
    # is a plain array of objects ON PURPOSE -- NOT [ordered]@{}: an
    # OrderedDictionary keyed by integers indexes POSITIONALLY when the
    # index is an [int], so `$map[3128]` is an out-of-range positional
    # lookup ("argument out of range, Parameter 'index'"), not the key
    # lookup it looks like. An object array sidesteps that trap.
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

    # Clear any prior yuruna-cacheproxy units first: on a re-run the cache
    # VM's NAT IP can differ, and a stale forwarder would point LAN
    # clients at a dead address.
    [void](Remove-PortMap -Confirm:$false)

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
Description=Yuruna caching-proxy forward :$hostPort -> ${VMIp}:$vmPort

[Socket]
ListenStream=0.0.0.0:$hostPort

[Install]
WantedBy=sockets.target
"@
        $serviceBody = @"
[Unit]
Description=Yuruna caching-proxy socket-proxy :$hostPort -> ${VMIp}:$vmPort
Requires=$base.socket
After=$base.socket

[Service]
ExecStart=$proxyd ${VMIp}:$vmPort
"@
        $socketBody  | & sudo tee "/etc/systemd/system/$base.socket"  > $null 2>&1
        $okSocket = ($LASTEXITCODE -eq 0)
        $serviceBody | & sudo tee "/etc/systemd/system/$base.service" > $null 2>&1
        $okService = ($LASTEXITCODE -eq 0)
        if ($okSocket -and $okService) {
            $written++
        } else {
            Write-Warning "  Could not write systemd units for port $hostPort -- skipping it."
        }
    }
    if ($written -eq 0) {
        Write-Warning "Add-PortMap: no forwarder units could be written (sudo / disk issue?)."
        return $false
    }

    & sudo systemctl daemon-reload 2>&1 | ForEach-Object { Write-Verbose "$_" }
    $up = 0
    foreach ($m in $mappings) {
        $sock = "yuruna-cacheproxy-p$($m.HostPort).socket"
        & sudo systemctl enable --now $sock 2>&1 | ForEach-Object { Write-Verbose "$_" }
        if ($LASTEXITCODE -eq 0) {
            Write-Information "  Forwarder listening: 0.0.0.0:$($m.HostPort) -> ${VMIp}:$($m.VMPort)"
            $up++
        } else {
            Write-Warning "  systemctl enable --now $sock failed -- port $($m.HostPort) not exposed."
        }
    }
    return ($up -gt 0)
}

<#
.SYNOPSIS
    Tear down every yuruna caching-proxy forwarder: the systemd
    socket-proxy units, plus any legacy pwsh Start-Process forwarders.
    Idempotent -- "nothing installed" is still success.
#>
function Remove-PortMap {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('yuruna-cacheproxy forwarders', 'Stop + remove')) { return $false }

    # Current mechanism: systemd socket-proxy units. Disable+stop the
    # .socket (drops it from sockets.target and closes the listener),
    # stop the .service, delete the unit files, reload systemd.
    $units = @(Get-ChildItem -LiteralPath '/etc/systemd/system' -Filter 'yuruna-cacheproxy-*' -ErrorAction SilentlyContinue)
    if ($units.Count -gt 0) {
        foreach ($u in ($units | Where-Object { $_.Name -like '*.socket' })) {
            & sudo systemctl disable --now $u.Name 2>&1 | Out-Null
        }
        foreach ($u in ($units | Where-Object { $_.Name -like '*.service' })) {
            & sudo systemctl stop $u.Name 2>&1 | Out-Null
        }
        & sudo rm -f @($units | ForEach-Object { $_.FullName }) 2>&1 | Out-Null
        & sudo systemctl daemon-reload 2>&1 | Out-Null
    }

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

# There is deliberately no pwsh Start-Process TcpListener forwarder here: it
# cannot bind privileged ports (:80) as a non-root user, and its detached
# processes do not survive a host reboot. Add-PortMap installs systemd
# socket-activated forwarders instead -- see its .DESCRIPTION above.

<#
.SYNOPSIS
    Return the host's best LAN-routable IPv4 for browser-facing URLs.
#>
function Get-BestHostIp {
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

<#
.SYNOPSIS
    Return the host IP a guest reaches the host at (per SwitchName).
#>
function Get-GuestReachableHostIp {
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
    (and the caching-proxy) must land on the SAME network as the cache, and
    must reach the host's status server at an address routable from that
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

# --- REGION: Caching proxy

<#
.SYNOPSIS
    Probe and return the caching-proxy URL, or null if none is reachable.
.DESCRIPTION
    Discovery is intentionally narrow -- only caches this host owns,
    or a remote cache the operator explicitly named, are returned:
      1. $Env:YURUNA_CACHING_PROXY_IP -- explicit remote cache override.
      2. State file (Read-CachingProxyState).ipAddress -- the cache VM's
         IP recorded by Start-CachingProxy.ps1 (our own VM).

    No libvirt enumeration, no loopback-forwarder fallback. Get-Caching-
    ProxyVMIp still exposes the recorded IP for direct callers that need
    it, and falls back to a live libvirt query for the by-name VM, but
    that fallback is no longer part of the discovery contract surfaced
    through Test-CachingProxyAvailable. LAN-wide cache discovery is a
    separate future feature.
#>
function Test-CachingProxyAvailable {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Thin wrapper over the shared probe (same as the win/mac drivers).
    #   -NoBracketHost      return bare-IP URLs -- KVM guests/consumers parse the
    #                       unbracketed form (no Format-IpUrlHost IPv6 bracketing).
    #   -ConnectAttempts 3  a cache reached over the host's systemd socket-proxy
    #                       forwarder into libvirt NAT (the 'yuruna-external'
    #                       bridge fallback) can take >1s to ACCEPT while it is
    #                       busy pre-warming or the local runner contends for
    #                       host CPU/IO; retries keep that healthy cache from
    #                       being false-negatived, which would otherwise drop the
    #                       whole inner cycle's guests to direct-from-internet
    #                       downloads.
    Invoke-CachingProxyAvailableProbe -VerifyHint 'nc -z {0} {1}' -NoBracketHost -ConnectAttempts 3
}

<#
.SYNOPSIS
    Return the cache VM's real IP for downstream port-forwarder setup.
#>
function Get-CachingProxyVMIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # Prefer the recorded IP from Start-CachingProxy.ps1 (matches macOS / Windows).
    $ip = (Read-CachingProxyState).ipAddress
    if ($ip -and (Test-IpAddress $ip)) { return $ip }
    # Live discovery via libvirt: ask the VM.
    return (Get-VMIp -VMName 'yuruna-caching-proxy')
}

<#
.SYNOPSIS
    Returns the IP of a reachable caching-proxy VM (probed on the squid HTTP
    port), or $null when no cache is currently usable. Injected as the
    -ResolveCacheHostIp closure into the shared Save-CachedHttpUri so KVM image
    downloads route through the squid cache.
.DESCRIPTION
    Discovery order (same shape as the macOS / Hyper-V drivers):
      1. $Env:YURUNA_CACHING_PROXY_IP -- explicit remote-cache override.
      2. Get-CachingProxyVMIp -- the cache VM's recorded IP (state file written
         by Start-CachingProxy.ps1), or a live libvirt domifaddr query for the
         by-name VM.
    The chosen IP is returned only if it answers the squid HTTP port, so a stale
    state entry or a stopped cache VM falls through to $null and the caller
    downloads direct. The host reaches the cache VM's libvirt-NAT (192.168.122.x)
    or bridged-LAN address directly, so the same IP also serves :80 (CA fetch)
    and the SSL-bump port for the HTTPS path -- no loopback forwarder is needed
    here (unlike macOS, where Apple Virtualization NAT requires one).
.OUTPUTS
    [string] IPv4 like '192.168.122.42', or $null.
#>
function Resolve-CacheHostIp {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $httpPort = Get-CachingProxyPort -Scheme http
    if ($Env:YURUNA_CACHING_PROXY_IP) {
        $externIp = $Env:YURUNA_CACHING_PROXY_IP.Trim()
        if ((Test-IpAddress $externIp) -and (Test-CachingProxyPort -IpAddress $externIp -Port $httpPort -TimeoutMs 500)) {
            return $externIp
        }
        return $null
    }
    $ip = Get-CachingProxyVMIp
    if ($ip -and (Test-IpAddress $ip) -and (Test-CachingProxyPort -IpAddress $ip -Port $httpPort -TimeoutMs 500)) {
        return $ip
    }
    return $null
}

<#
.SYNOPSIS
    Download $Uri to $OutFile through the KVM caching proxy, falling back to
    a direct fetch when no cache is reachable.
.DESCRIPTION
    Thin driver-local wrapper over the shared download stack. The closure binds
    this driver's Resolve-CacheHostIp (libvirt/state-file cache discovery) so the
    shared module stays platform-agnostic while still reaching KVM-specific lookup.
#>
function Save-CachedHttpUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Yuruna.HostDownload\Save-CachedHttpUri -Uri $Uri -OutFile $OutFile -ResolveCacheHostIp { Resolve-CacheHostIp }
}

# --- REGION: Host config

<#
.SYNOPSIS
    Promote a proxy URL to the machine-wide host proxy with backup.
#>
function Set-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ProxyUrl)
    if (-not $PSCmdlet.ShouldProcess('Linux host (apt + /etc/environment)', "Set proxy = $ProxyUrl")) { return $false }
    $parts = ConvertTo-ProxyHostPort -Url $ProxyUrl
    $backupPath = Get-HostProxyBackupPath
    # Idempotent backup: only snapshot BEFORE the first apply, so a
    # repeat Set-HostProxy doesn't overwrite the backup with the
    # squid-promoted state.
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $state = Read-LinuxProxyState
        $state['timestamp']  = (Get-Date).ToUniversalTime().ToString('o')
        $state['promotedTo'] = $parts.Url
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        Write-Information "  Host proxy: backup written to $backupPath"
    } else {
        Write-Information "  Host proxy: existing backup at $backupPath preserved (still apply)"
    }
    Set-LinuxHostProxy -ProxyUrl $parts.Url
    Write-Information "  Host proxy: /etc/environment + /etc/apt/apt.conf.d/99yuruna-host-proxy set to $($parts.Url)"
    return $true
}

<#
.SYNOPSIS
    Restore the host proxy from the saved backup, or disable if none.
#>
function Clear-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Linux host', 'Disable proxy / restore backup')) { return $false }
    $backupPath = Get-HostProxyBackupPath
    $state = $null
    if (Test-Path -LiteralPath $backupPath) {
        try {
            $state = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json -AsHashtable
        } catch {
            Write-Warning "Host proxy: could not parse backup '$backupPath' ($($_.Exception.Message)). Falling back to disable-only."
            $state = $null
        }
    }
    if ($state -and $state.previousUrl) {
        Set-LinuxHostProxy -ProxyUrl $state.previousUrl
        Write-Information "  Host proxy: restored to $($state.previousUrl)"
    } else {
        Disable-LinuxHostProxy
        Write-Information "  Host proxy: cleared (no prior URL to restore)"
    }
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

<#
.SYNOPSIS
    Aggressively wipe every host-proxy reference and the backup file.
#>
function Remove-HostProxy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    if (-not $PSCmdlet.ShouldProcess('Linux host', 'Wipe host proxy state')) { return $false }
    Disable-LinuxHostProxy
    $backupPath = Get-HostProxyBackupPath
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
    Write-Information "  Host proxy: wiped (apt config removed; /etc/environment proxy lines stripped)"
    return $true
}

<#
.SYNOPSIS
    Read current Linux host proxy state into a backup hashtable.
#>
function Read-LinuxProxyState {
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
    $script = @"
set -e
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment 2>/dev/null || true
printf 'http_proxy="%s"\nhttps_proxy="%s"\nHTTP_PROXY="%s"\nHTTPS_PROXY="%s"\n' '$ProxyUrl' '$ProxyUrl' '$ProxyUrl' '$ProxyUrl' >> /etc/environment
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99yuruna-host-proxy <<EOF
Acquire::http::Proxy "$ProxyUrl";
Acquire::https::Proxy "$ProxyUrl";
EOF
chmod 0644 /etc/apt/apt.conf.d/99yuruna-host-proxy
"@
    & sudo bash -c $script
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
sed -i.yuruna-bak '/^[Hh][Tt][Tt][Pp][Ss]\?_proxy\s*=/d' /etc/environment 2>/dev/null || true
rm -f /etc/apt/apt.conf.d/99yuruna-host-proxy 2>/dev/null || true
'@
    & sudo bash -c $script
}

<#
.SYNOPSIS
    Return the path of the host-proxy backup JSON.
#>
function Get-HostProxyBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return Yuruna.Common\Get-HostProxyBackupPath
}

<#
.SYNOPSIS
    Returns true if the host hypervisor is installed and ready.
#>
function Assert-Virtualization {
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
        Write-Verbose "Assert-Virtualization: libvirtd is not active (state=$active)."
        return $false
    }
    # libvirtd being active is not the same as THIS process being able to
    # reach it. A user added to 'libvirt' via usermod -aG only gets the
    # group in their effective set after a re-login -- and on systemd-
    # logind systems with user lingering, even a desktop logout/login
    # often does NOT refresh existing terminal sessions. Without this
    # check, the runner cruises past Assert-Virtualization, spends ~8
    # minutes downloading ISOs, and only THEN crashes inside New-VM.ps1
    # with the verbatim libvirt-sock "Permission denied" line.
    & virsh --connect $script:VirshUri list --name >$null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Verbose "Assert-Virtualization: virsh list failed (exit $LASTEXITCODE) -- this process cannot reach $script:VirshUri."
        return $false
    }
    return $true
}

# --- REGION: Exports

Export-ModuleMember -Function `
    New-VM, Start-VM, Stop-VM, Stop-VMForce, Remove-VM, Rename-VM, Get-VMState, `
    Save-VMDiskSnapshot, Restore-VMDiskSnapshot, Test-VMDiskSnapshot, `
    Test-VMConsoleOpen, Restart-VMConsole, `
    Get-Image, Get-ImagePath, `
    Send-Text, Send-Key, Send-Click, Get-VMScreenshot, Get-VMConsoleHandle, `
    Wait-VMIp, Get-VMIp, Get-VMMac, `
    Get-ExternalNetwork, New-ExternalNetwork, New-YurunaExternalNetwork, Get-YurunaExternalNetworkPlan, Test-CacheVMOnExternalNetwork, `
    Add-PortMap, Remove-PortMap, Get-BestHostIp, Get-GuestReachableHostIp, Resolve-GuestHostBinding, `
    Test-CachingProxyAvailable, Get-CachingProxyVMIp, `
    Test-DownloadAlreadyCurrent, Test-CachingProxyPort, Resolve-CacheHostIp, Save-CachedHttpUri, `
    Set-HostProxy, Clear-HostProxy, Remove-HostProxy, Get-HostProxyBackupPath, Assert-Virtualization

# Contract-coverage assertion: warns at load time if the export block
# above drifts away from the canonical Yuruna.Host contract. See
# host/Yuruna.Host.Contract.psm1 for the verb list and rationale.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath '..', 'Yuruna.Host.Contract.psm1') -Force -DisableNameChecking
$null = Assert-YurunaHostContractCoverage -HostType 'ubuntu.kvm' -ExportedFunction @(
    'New-VM','Start-VM','Stop-VM','Stop-VMForce','Remove-VM','Rename-VM','Get-VMState',
    'Save-VMDiskSnapshot','Restore-VMDiskSnapshot','Test-VMDiskSnapshot',
    'Test-VMConsoleOpen','Restart-VMConsole',
    'Get-Image','Get-ImagePath',
    'Send-Text','Send-Key','Send-Click','Get-VMScreenshot','Get-VMConsoleHandle',
    'Wait-VMIp','Get-VMIp','Get-VMMac',
    'Get-ExternalNetwork','New-ExternalNetwork','New-YurunaExternalNetwork','Get-YurunaExternalNetworkPlan','Test-CacheVMOnExternalNetwork',
    'Add-PortMap','Remove-PortMap','Get-BestHostIp','Get-GuestReachableHostIp',
    'Test-CachingProxyAvailable','Get-CachingProxyVMIp',
    'Set-HostProxy','Clear-HostProxy','Remove-HostProxy','Get-HostProxyBackupPath','Assert-Virtualization'
)

# Load-time guard for the cache-download wrapper precedence. The image helpers
# (Save-ImageWithChecksum / Save-UbuntuServerImage) feature-detect Save-CachedHttpUri
# BY NAME and invoke it with only -Uri/-OutFile, so this driver's 2-param wrapper
# must win the command-table slot over the shared 3-param
# Yuruna.HostDownload\Save-CachedHttpUri. If an import-order change flips that
# precedence the cache-discovery closure is dropped and downloads silently bypass
# the squid cache (direct, no error) -- surface that regression loudly here.
$__yurunaCacheDownloadCmd = Get-Command -Name Save-CachedHttpUri -ErrorAction SilentlyContinue
if (-not $__yurunaCacheDownloadCmd) {
    Write-Warning "Yuruna.Host (ubuntu.kvm): Save-CachedHttpUri is not on the command table after load; image downloads cannot route through the squid cache."
} elseif ($__yurunaCacheDownloadCmd.Parameters.ContainsKey('ResolveCacheHostIp')) {
    Write-Warning "Yuruna.Host (ubuntu.kvm): Save-CachedHttpUri resolves to the shared Yuruna.HostDownload implementation (mandatory -ResolveCacheHostIp), not this driver's cache-injecting wrapper; image downloads will silently bypass the squid cache. Check module import order."
}
