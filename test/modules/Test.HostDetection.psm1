<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a7b8c9-d0e1-4f23-9456-7e8f9a0b1c20
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host
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

# Host detection + per-host preflight: identifies the platform
# (host.macos.utm / host.windows.hyper-v / host.ubuntu.kvm),
# maps host type to repo folder, derives test VM names, asserts
# the minimum runtime requirements (elevation on Windows, /dev/kvm
# on Linux, UTM bundle on macOS), and handles the libvirt-group
# re-exec dance for fresh Ubuntu installs. Deliberately excludes
# anything that mutates host configuration (Set-*HostConditionSet
# lives in Test.HostCondition.psm1) or that imports host drivers
# (Initialize-YurunaHost lives in Test.HostBootstrap.psm1).

# Module-level self-healing: re-import Test.VMUtility.psm1 with -Global
# every time Test.HostContract is loaded. The runner's cycle re-import block
# reloads Test.HostContract every cycle; doing the -Global import here keeps
# Wait-VMRunning / Test-IpAddress / Format-IpUrlHost (and the other
# cross-host helpers) in the runner's session even when something
# mid-cycle has wiped the global module table -- e.g. a sequence step
# calling `Get-Module | Remove-Module`, or a transitive Import-Module
# without -Global. Without this, a long-running macOS in-process runner
# could lose Wait-VMRunning at an unrelated moment and crash at the
# next New-VM.Resource step. -ErrorAction SilentlyContinue: a missing sibling
# is non-fatal here; Initialize-YurunaHost still fails loudly later if
# truly broken.
$vmCommonPath = Join-Path $PSScriptRoot 'Test.VMUtility.psm1'
if (Test-Path $vmCommonPath) {
    Import-Module $vmCommonPath -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
}

function Get-HostType {
    <#
    .SYNOPSIS
    Returns "host.macos.utm", "host.windows.hyper-v", or "host.ubuntu.kvm"
    based on the current platform.
    #>
    # Platform is invariant for the process lifetime; cache the first
    # detection so the per-cycle ~7+ callers don't each pay the
    # Get-Service vmms / Test-Path /dev/kvm cost. As a side benefit the
    # warning fires at most once per process instead of per call.
    if ($script:CachedHostType) { return $script:CachedHostType }
    if ($IsMacOS) {
        if (-not (Test-Path "/Applications/UTM.app")) {
            Write-Warning "Running on macOS but UTM not found at /Applications/UTM.app."
        }
        $script:CachedHostType = "host.macos.utm"
        return $script:CachedHostType
    }
    if ($IsWindows) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Running on Windows but Hyper-V service (vmms) not found."
        }
        $script:CachedHostType = "host.windows.hyper-v"
        return $script:CachedHostType
    }
    if ($IsLinux) {
        # Ubuntu / Debian + KVM/libvirt is the only Linux flavor wired into
        # the harness today. Warn (don't fail) if libvirt isn't installed
        # yet -- the installer (install/ubuntu.kvm.sh) creates the missing
        # bits and a fresh install legitimately runs Get-HostType before
        # libvirtd is up.
        if (-not (Test-Path '/dev/kvm')) {
            Write-Warning "Running on Linux but /dev/kvm missing (kvm.ko not loaded or VT-x/SVM disabled)."
        }
        $script:CachedHostType = "host.ubuntu.kvm"
        return $script:CachedHostType
    }
    Write-Error "Unsupported platform. Only macOS (UTM), Windows (Hyper-V), and Linux (KVM/libvirt) are supported."
    return $null
}

function Get-HostFolder {
    <#
    .SYNOPSIS
    Maps a HostType identifier to its repo-relative folder path.
    .DESCRIPTION
    HostType is the stable identifier (e.g. "host.windows.hyper-v") used by
    test sequences and extension scripts. The on-disk layout is
    "host/<short-name>/" -- strip the "host." prefix and join under "host/".
    #>
    param([Parameter(Mandatory)] [string]$HostType)
    return "host/$($HostType -replace '^host\.','')"
}

function Invoke-LibvirtGroupReExecIfNeeded {
    <#
    .SYNOPSIS
    On host.ubuntu.kvm, auto-relaunch the calling script under
    `sg libvirt -c "..."` when the parent shell's running supplementary
    group set lacks 'libvirt'. Returns silently when no re-exec is
    needed; calls exit and never returns when it does re-exec.

    .DESCRIPTION
    `sudo usermod -aG libvirt $USER` updates /etc/group but does NOT
    refresh the parent shell's effective group set; on systemd-logind
    systems with user lingering, even a desktop logout/login often
    doesn't either. Without libvirt in the effective set, every
    virsh / virt-install call fails with "Permission denied" on
    /var/run/libvirt/libvirt-sock. `sg libvirt -c "..."` spawns a
    subshell that calls initgroups() fresh -- libvirt is then in the
    effective set, and any pwsh child processes (Start-Process pwsh in
    Invoke-TestRunner, virt-install in New-VM, etc.) inherit it
    naturally. install/ubuntu.kvm.sh uses the same trick when invoking
    Remove-TestVMFiles.ps1 from the installer; this function brings
    the same recovery to standalone operator invocations of every
    libvirt-touching script.

    Short-circuits when ANY of:
      * not on host.ubuntu.kvm (other hosts don't have this group issue)
      * caller already inside an sg subshell (YURUNA_SG_RELAUNCH=1)
      * libvirt already in the running supplementary group set
      * user not in libvirt per /etc/group (re-exec wouldn't help;
        Assert-HostConditionSet / Test-HostRequirement will report the
        actual install-time error)
      * sg binary not present (no automatic recovery available)

    YURUNA_SG_RELAUNCH is passed INLINE inside the `sg -c "..."` shell
    command so it lives only in the sg subshell. Setting
    `$env:YURUNA_SG_RELAUNCH = '1'` here would mutate the CURRENT
    pwsh process's environment, which then leaks back to the
    operator's interactive `PS> ` prompt -- every subsequent
    invocation in the same pwsh session would skip the re-exec and
    fail on libvirt-sock again. (Discovered the hard way: the original
    inline implementation in Remove-TestVMFiles.ps1 worked on the first
    call but failed every call after that until the session was closed.)

    .PARAMETER HostType
        Result of Get-HostType. Helper short-circuits when not Ubuntu KVM.

    .PARAMETER ScriptPath
        Full path to the running script -- caller passes $PSCommandPath
        (or $MyInvocation.MyCommand.Path on older pwsh). Forwarded to
        the re-exec'd pwsh via `-File`.

    .PARAMETER BoundParameters
        $PSBoundParameters from the calling script. Forwarded verbatim
        so explicit args survive the relaunch. Supported types in the
        affected scripts: [string], [int], [double], [switch] -- no
        complex types (arrays/hashtables) appear in any current entry
        point's param block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{}
    )

    if ($HostType -ne 'host.ubuntu.kvm')                       { return }
    if ($env:YURUNA_SG_RELAUNCH)                               { return }
    $activeGroups = (& id -nG 2>$null) -split '\s+'
    if ($activeGroups -contains 'libvirt')                     { return }
    $libvirtLine    = & getent group libvirt 2>$null
    $libvirtMembers = if ($libvirtLine) { (($libvirtLine -split ':',4)[3]) -split ',' } else { @() }
    if ($libvirtMembers -notcontains $env:USER)                { return }
    if (-not (Get-Command sg -ErrorAction SilentlyContinue))   { return }

    $scriptName = Split-Path -Leaf $ScriptPath
    Write-Output "This shell's group set predates 'libvirt' membership -- re-launching '$scriptName' under 'sg libvirt'."

    # Build the forwarded-args string for bash. Single-quote each value
    # and escape internal single quotes via the classic bash idiom
    # 'foo' + \' + 'bar' (a closing quote, an escaped quote, a reopening
    # quote). Switches emit "-Name" only when .IsPresent.
    $argParts = @()
    foreach ($key in $BoundParameters.Keys) {
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { $argParts += "-$key" }
        } else {
            $escaped = "$val" -replace "'", "'\''"
            $argParts += "-$key '$escaped'"
        }
    }
    $argString     = if ($argParts.Count -gt 0) { ' ' + ($argParts -join ' ') } else { '' }
    $scriptEscaped = $ScriptPath -replace "'", "'\''"

    & sg libvirt -c "YURUNA_SG_RELAUNCH=1 pwsh -NoLogo -NoProfile -File '$scriptEscaped'$argString"
    exit $LASTEXITCODE
}


function Get-GuestList {
    <#
    .SYNOPSIS
    Returns the ordered list of guest keys from $Config.guestSequence.
    .DESCRIPTION
    Returns verbatim — whether a guest is implemented on the current
    host is decided at runtime by Test-GuestFolder; the runner logs a
    per-guest failure for missing folders. Replaces the old hardcoded
    allow-list. Empty/missing guestSequence returns an empty list with a warning.
    #>
    param([System.Collections.IDictionary]$Config = @{})

    if ($Config.guestSequence -and $Config.guestSequence.Count -gt 0) {
        return @($Config.guestSequence)
    }

    Write-Warning "test.config.yml has no 'guestSequence' entries — nothing to run."
    return @()
}

function Test-GuestFolder {
    <#
    .SYNOPSIS
    Returns $true when the guest's scripts folder exists for a host.
    .DESCRIPTION
    Layout: <repo>/host/<short-host>/<guestKey>/ holds Get-Image.ps1 and
    New-VM.ps1 for that host+guest. Guest is available on a host iff
    the folder exists. guestSequence can legitimately name host-specific
    guests; callers treat missing folder as a per-guest failure, not a
    config error.
    #>
    param(
        [Parameter(Mandatory)] [string]$RepoRoot,
        [Parameter(Mandatory)] [string]$HostType,
        [Parameter(Mandatory)] [string]$GuestKey
    )
    $folder = Join-Path $RepoRoot (Join-Path (Get-HostFolder $HostType) $GuestKey)
    return (Test-Path -Path $folder -PathType Container)
}

function Get-TestVMName {
    <#
    .SYNOPSIS
    Derives the test VM name from guest key + prefix.
    .DESCRIPTION
    Strip "guest.", replace remaining dots with hyphens, append "-01",
    add the prefix. Examples with prefix "test-":
        guest.ubuntu.server.24  →  test-ubuntu-server-01
        guest.amazon.linux.2023   →  test-amazon-linux-01
        guest.windows.11     →  test-windows-11-01
    Any guest key produces a deterministic VM name without code changes.
    Migration note: pre-2026-04 harness used "test-amazon-linux01",
    "test-windows11-01". VMs from the old convention are orphaned
    (Remove-TestVM keys off the new name); clean them up once with
    `Get-VM test-* | Remove-VM` on Hyper-V or `utmctl list | grep test-`
    on UTM.
    #>
    param(
        [Parameter(Mandatory)] [string]$GuestKey,
        [string]$Prefix = "test-",
        [string]$HostId
    )
    $stem = ($GuestKey -replace '^guest\.', '') -replace '\.', '-'
    # Pool (Phase 4): an 8-hex HostId segment scopes the VM name to this host so
    # multiple pool members on a SHARED store never collide. ABSENT (legacy /
    # single-host) -> byte-identical to the old name. The segment is alphanumeric,
    # satisfying the per-host New-VM.ps1 name validator.
    if ([string]::IsNullOrWhiteSpace($HostId)) { return "${Prefix}${stem}-01" }
    $h = ($HostId -replace '[^0-9A-Za-z]', '')
    if ($h.Length -gt 8) { $h = $h.Substring(0, 8) }
    return "${Prefix}${stem}-${h}-01"
}

function Test-ElevationRequired {
    <#
    .SYNOPSIS
    Returns $true if the host type requires Administrator / root
    elevation. Reads the RequiresElevation flag from the host-condition
    registry (Test.HostCondition.psm1).
    .DESCRIPTION
    Conservative default ($false) when the registry isn't loaded yet
    -- the runner imports Test.HostCondition before this is meaningfully
    queried, so the early-call window is small.
    #>
    param([string]$HostType)
    if (-not (Get-Command Get-HostConditionProvider -ErrorAction SilentlyContinue)) {
        return $false
    }
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider) { return $false }
    return [bool]$provider.RequiresElevation
}

function Assert-Elevation {
    <#
    .SYNOPSIS
    Checks elevation if required. Returns $false and writes an error if elevation is needed but absent.
    #>
    param([string]$HostType)
    if (-not (Test-ElevationRequired -HostType $HostType)) { return $true }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "host.windows.hyper-v requires elevation. Re-run Invoke-TestRunner.ps1 as Administrator."
        return $false
    }
    return $true
}

function Test-HostRequirement {
    <#
    .SYNOPSIS
        Fast, run-anywhere pre-flight. Returns $true only when the
        absolute minimum needed to call this host's VM cmdlets is in
        place (Administrator on Windows + vmms running, virsh + /dev/kvm
        on Ubuntu, utmctl + UTM.app on macOS). On failure, prints
        Write-Warning lines explaining what is missing and how to fix
        it, and ALWAYS surfaces a Write-Information pointer to
        Test-Config.ps1 for a deeper host-health report.
    .DESCRIPTION
        Called at the top of every operator-facing helper that touches
        host VMs (Remove-TestVMFiles.ps1, ...) so an elevation-missing
        run on Hyper-V fails fast with an actionable message instead of
        dying inside the first cmdlet with the bare "You do not have
        the required permission..." that Hyper-V\Get-VM emits. The
        actual failure observed on ALIUS-ALIEN01 was a non-elevated
        run of Remove-TestVMFiles.ps1: Hyper-V\Get-VM at line 67 threw
        before any user-friendly check had been reached.
        Intentionally lighter than Assert-HostConditionSet (which also
        fails on display-sleep / screen-lock settings); those checks
        belong to the long-running test runner, not to cleanup helpers
        that an operator may legitimately invoke during a maintenance
        window with the screen unlocked.
    .OUTPUTS
        [bool] -- $true when the minimum is met, $false otherwise.
        Never throws; the caller decides whether to exit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        # Quiet mode: suppress the trailing "There may be more host-health
        # recommendations available..." pointer. Existing failure
        # Write-Warning lines are NEVER quieted -- a missing requirement
        # is always shown. The pointer is the only banner this switch
        # silences; an automated caller (Remove-TestVMFiles.ps1 -Quiet)
        # passes -Quiet so the cycle teardown emits no host-health noise.
        # The inner Write-Information's hardcoded -InformationAction
        # Continue otherwise overrides any caller -InformationAction
        # SilentlyContinue, which is why an explicit switch is needed.
        [switch]$Quiet
    )

    $ok = $true

    # Registry-backed dispatch: each platform sibling
    # (Test.HostCondition.{Mac,Windows,Linux}.psm1) registers a
    # Test-*HostMinimum scriptblock that runs the quick check below.
    # Adding a new host is one Register-HostConditionProvider call;
    # nothing here changes.
    if (-not (Get-Command Get-HostConditionProvider -ErrorAction SilentlyContinue)) {
        Write-Warning "Test.HostCondition not loaded -- skipping requirements check for '$HostType'."
    } else {
        $provider = Get-HostConditionProvider -HostType $HostType
        if (-not $provider) {
            Write-Warning "Unknown host type '$HostType' -- skipping requirements check."
        } elseif ($provider.AssertMinimum) {
            $ok = [bool](& $provider.AssertMinimum)
        }
    }

    # Surface the pointer so an operator running a one-off helper learns
    # there is a richer health report available, even when the quick
    # check just passed. -InformationAction Continue so the line shows
    # without the caller having to set $InformationPreference. -Quiet
    # skips the pointer entirely so the cycle-teardown sweep (called via
    # Remove-TestVMFiles.ps1 -Quiet) doesn't repeat this advice every
    # cycle.
    if (-not $Quiet) {
        Write-Information "There may be more host-health recommendations available. For a deeper report (config files, transports, framework/project staleness, RAM/CPU, host-specific feature state) run: pwsh test/Test-Config.ps1" -InformationAction Continue
    }

    return $ok
}

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Invoke-LibvirtGroupReExecIfNeeded, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Assert-Elevation, Test-HostRequirement