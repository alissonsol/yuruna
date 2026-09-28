<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42a15892-c9f1-4438-9c35-d19e6ba7c2cc
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
# every time this module is loaded. The runner's cycle re-import block
# reloads Test.HostContract every cycle, which re-imports this sibling;
# the -Global import here keeps Wait-VMRunning / Test-IpAddress /
# Format-IpUrlHost (and the other cross-host helpers) in the runner's
# session even when something mid-cycle has wiped the global module table
# -- e.g. a sequence step calling `Get-Module | Remove-Module`, or a
# transitive Import-Module without -Global. Without this, a long-running
# macOS in-process runner could lose Wait-VMRunning at an unrelated moment
# and crash at the next New-VM.Resource step. This module (not the
# Test.HostContract facade) owns the self-heal so it also fires for the
# callers that import Test.HostDetection directly. -ErrorAction
# SilentlyContinue: a missing sibling is non-fatal here;
# Initialize-YurunaHost still fails loudly later if truly broken.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2fce8fc42e5b8f1f')
        }
        $script:CachedHostType = "host.macos.utm"
        return $script:CachedHostType
    }
    if ($IsWindows) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8790664687f108a2')
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b6ebfede650f03bc')
        }
        $script:CachedHostType = "host.ubuntu.kvm"
        return $script:CachedHostType
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_ddf3d89de65f28bb')
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

function Test-LibvirtGroupReExecNeeded {
    <#
    .SYNOPSIS
    Decide, without relaunching anything, whether this process must be
    relaunched under `sg libvirt` to reach the libvirt socket.
    .DESCRIPTION
    The decision half of Invoke-LibvirtGroupReExecIfNeeded, so a preview can
    report a missing group without starting a child process. No relaunch
    is needed when ANY of:
      * not on host.ubuntu.kvm (other hosts don't have this group issue)
      * the caller is already inside an sg subshell (YURUNA_SG_RELAUNCH=1)
      * libvirt is already in the running supplementary group set
      * the user is not in libvirt per the group database (a relaunch
        would not help; Assert-HostConditionSet / Test-HostRequirement
        report the actual install-time error)
      * the sg binary is not present (no automatic recovery available)
    The group probes are bounded: `id`/`getent` normally answer from local
    files in microseconds, but either can be backed by NSS modules (LDAP,
    NIS, sssd) that hang on a wedged directory service, and this runs
    before any caller has had a chance to place a deadline around it. A
    probe that does not answer is 'probe-failed', never a guess.
    .PARAMETER HostType
    Result of Get-HostType (long form, e.g. host.ubuntu.kvm).
    .PARAMETER TimeoutSeconds
    Cap for each group probe.
    .OUTPUTS
    [pscustomobject] @{ Needed; Reason not-kvm|already-relaunched|
    in-active-set|not-member|no-sg|probe-failed|relaunch-required }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 5
    )
    $verdict = { param([bool]$Needed, [string]$Reason) [pscustomobject]@{ Needed = $Needed; Reason = $Reason } }
    if ($HostType -ne 'host.ubuntu.kvm') { return (& $verdict $false 'not-kvm') }
    if ($env:YURUNA_SG_RELAUNCH) { return (& $verdict $false 'already-relaunched') }
    # Partial output (truncated, drained short, or from a child whose kill
    # was not confirmed) is not an answer: a group list cut before 'libvirt'
    # would otherwise read as "not in the set".
    $idResult = Invoke-BoundedNativeCommand -FilePath 'id' -ArgumentList @('-nG') -TimeoutSeconds $TimeoutSeconds
    if (-not (Test-BoundedNativeResultComplete -Result $idResult) -or $idResult.ExitCode -ne 0) {
        return (& $verdict $false 'probe-failed')
    }
    $activeGroups = @(([string]$idResult.StdOut).Trim() -split '\s+')
    if ($activeGroups -contains 'libvirt') { return (& $verdict $false 'in-active-set') }
    $getentResult = Invoke-BoundedNativeCommand -FilePath 'getent' -ArgumentList @('group', 'libvirt') -TimeoutSeconds $TimeoutSeconds
    if (-not (Test-BoundedNativeResultComplete -Result $getentResult)) {
        return (& $verdict $false 'probe-failed')
    }
    # getent exits 2 when the group does not exist at all: nobody is a
    # member, which is a definite answer rather than a failed probe.
    if ($getentResult.ExitCode -eq 2) { return (& $verdict $false 'not-member') }
    if ($getentResult.ExitCode -ne 0) { return (& $verdict $false 'probe-failed') }
    $libvirtLine = ([string]$getentResult.StdOut).Trim()
    $fields = $libvirtLine -split ':', 4
    $libvirtMembers = if ($fields.Count -ge 4 -and $fields[3]) { @($fields[3] -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
    $userName = if ($env:USER) { $env:USER } else { [Environment]::UserName }
    if ($libvirtMembers -notcontains $userName) { return (& $verdict $false 'not-member') }
    if (-not (Get-Command -CommandType Application -Name 'sg' -ErrorAction SilentlyContinue)) { return (& $verdict $false 'no-sg') }
    return (& $verdict $true 'relaunch-required')
}

function ConvertTo-LibvirtRelaunchArgument {
    <#
    .SYNOPSIS
    Render bound parameters as PowerShell command-line text for the sg
    relaunch, refusing any value that would not survive the round trip.
    .DESCRIPTION
    Values are quoted PowerShell-side (single quotes, internal ' doubled),
    a collection becomes a comma-joined quoted list (an empty one @()), a
    [bool] becomes -Name:$true/-Name:$false (a quoted 'False' would not
    bind to [bool]), and a switch is present or absent. A dictionary or an
    object with properties -- a hashtable, a deadline object -- has no
    faithful text form, so it is refused rather than flattened into its
    type name; process boundaries carry only scalars and string arrays.
    .PARAMETER BoundParameters
    $PSBoundParameters from the calling script, or a copy with computed
    values added.
    .OUTPUTS
    [string] one element per forwarded parameter.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$BoundParameters)
    $quote = { param($Value) "'" + ("$Value" -replace "'", "''") + "'" }
    foreach ($key in @($BoundParameters.Keys)) {
        $name = [string]$key
        # The name is written into command text unquoted, so anything beyond
        # a plain identifier could inject code into the relaunched command.
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_libvirt_relaunch_parameter_name_invalid' -Arguments @{ name = "$name" })
        }
        $val = $BoundParameters[$key]
        if ($val -is [System.Management.Automation.SwitchParameter]) {
            if ($val.IsPresent) { "-$name" }
        } elseif ($val -is [bool]) {
            if ($val) { "-${name}:`$true" } else { "-${name}:`$false" }
        } elseif ($null -eq $val) {
            continue
        } elseif ($val -is [string] -or $val -is [char] -or $val -is [ValueType]) {
            "-$name $(& $quote $val)"
        } elseif ($val -is [System.Collections.IDictionary] -or $val -isnot [System.Collections.IEnumerable]) {
            throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_libvirt_relaunch_parameter_unsupported' -Arguments @{ name = "$name"; valueType = "$($val.GetType().FullName)" })
        } else {
            $items = @(foreach ($item in $val) {
                    if ($item -is [System.Collections.IDictionary] -or -not ($item -is [string] -or $item -is [ValueType])) {
                        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_libvirt_relaunch_parameter_unsupported' -Arguments @{ name = "$name"; valueType = "$($item.GetType().FullName)" })
                    }
                    & $quote $item
                })
            if ($items.Count -eq 0) { "-$name @()" } else { "-$name $($items -join ',')" }
        }
    }
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
    Start-TestRunner, virt-install in New-VM, etc.) inherit it
    naturally. install/ubuntu.kvm.sh uses the same trick when invoking
    Remove-TestVMFiles.ps1 from the installer; this function brings
    the same recovery to standalone operator invocations of every
    libvirt-touching script. Test-LibvirtGroupReExecNeeded makes the
    decision; this function only acts on it.

    The child is `pwsh -NoLogo -NoProfile -NonInteractive -Command`: an
    unattended relaunch must fail a prompt instead of waiting on a console
    nobody watches. It inherits this process's environment, and this
    process waits for it and then exits with its exit code, so code after
    the call never runs in the parent while the parent's own finally
    blocks still do. One relaunch line is written to the success stream
    before sg runs, so a caller reads the relaunched script's verdict from
    its exit code and state files, never by parsing this process's stdout.

    YURUNA_SG_RELAUNCH is passed INLINE inside the `sg -c "..."` shell
    command so it lives only in the sg subshell. Setting
    `$env:YURUNA_SG_RELAUNCH = '1'` here would mutate the CURRENT
    pwsh process's environment, which then leaks back to the
    operator's interactive `PS> ` prompt -- every subsequent
    invocation in the same pwsh session would skip the re-exec and
    fail on libvirt-sock again: the first call works and every later
    one fails until the session is closed.

    Call it from the entry script's own scope: inside a module function
    $PSCommandPath is the module file and $PSBoundParameters that
    function's, so nothing of the script would be forwarded.

    .PARAMETER HostType
        Result of Get-HostType. Helper short-circuits when not Ubuntu KVM.

    .PARAMETER ScriptPath
        Full path to the running script -- caller passes $PSCommandPath
        (or $MyInvocation.MyCommand.Path on older pwsh). The relaunched
        pwsh invokes it with the call operator inside its -Command text.

    .PARAMETER BoundParameters
        $PSBoundParameters from the calling script, or a copy with computed
        values (such as a deadline tick) added. Forwarded as PowerShell
        command text so explicit args survive the relaunch: strings,
        numbers including [long] values above the Int32 range, [bool],
        [switch] and string arrays (multi-value parameters such as
        Remove-TestVMFiles' -Prefix keep their element boundaries). A
        hashtable or other object value is refused with an error before
        anything is relaunched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{}
    )

    $decision = Test-LibvirtGroupReExecNeeded -HostType $HostType
    if (-not $decision.Needed) {
        Write-Verbose "Invoke-LibvirtGroupReExecIfNeeded: no relaunch ($($decision.Reason))."
        return
    }

    # Build the relaunch as a PowerShell command line, not a `pwsh -File`
    # argument list: -File binds every token as a plain string, so a
    # multi-value parameter (-Prefix a,b) arrives as the single literal
    # "a,b" -- a prefix that matches no VM, reported as a clean sweep.
    # Rendered before the relaunch line is written, so an unsupported
    # value fails here with nothing started.
    $argParts = @(ConvertTo-LibvirtRelaunchArgument -BoundParameters $BoundParameters)

    $scriptName = Split-Path -Leaf $ScriptPath
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7abda1d6d5b469e1' -Arguments @{ scriptName = "$scriptName" })

    $invocation = (@("& '$($ScriptPath -replace "'", "''")'") + $argParts) -join ' '
    # -Command reports its own success, not the script's: without the
    # trailing exit the relaunched script's exit code is flattened to 0/1
    # and a caller that branches on it (the cycle sweep treats non-zero as
    # "VMs survived") reads a failed sweep as clean. The catch keeps a
    # terminating error at exit 1, which is what -File would have returned.
    $psCommand = "`$global:LASTEXITCODE = 0; try { $invocation; if (-not `$?) { if (`$LASTEXITCODE) { exit `$LASTEXITCODE }; exit 1 } } catch { Write-Error `$_; exit 1 }; exit 0"

    # The whole pwsh command line is one bash word, so it is single-quoted
    # for bash with the classic 'foo' + \' + 'bar' escape (a closing quote,
    # an escaped quote, a reopening quote) around any internal quote.
    $bashEscaped = $psCommand -replace "'", "'\''"
    & sg libvirt -c "YURUNA_SG_RELAUNCH=1 pwsh -NoLogo -NoProfile -NonInteractive -Command '$bashEscaped'"
    exit $LASTEXITCODE
}


function Get-GuestList {
    <#
    .SYNOPSIS
    Returns the ordered list of guest keys from $Config.guestSequence.
    .DESCRIPTION
    Returns verbatim -- whether a guest is implemented on the current
    host is decided at runtime by Test-GuestFolder; the runner logs a
    per-guest failure for missing folders. Empty/missing guestSequence
    returns an empty list with a warning.
    #>
    param([System.Collections.IDictionary]$Config = @{})

    if ($Config.guestSequence -and $Config.guestSequence.Count -gt 0) {
        return @($Config.guestSequence)
    }

    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_9ca518212e68fc8a')
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
    The guest key rides through VERBATIM -- prefix, then the key exactly as it
    appears in guestSequence and on disk, then the "-01" ordinal. Examples with
    prefix "test-":
        guest.ubuntu.server.24    ->  test-guest.ubuntu.server.24-01
        guest.amazon.linux.2023   ->  test-guest.amazon.linux.2023-01
        guest.windows.11          ->  test-guest.windows.11-01
    Reading the guest key straight off a VM name is the point: an operator
    listing VMs on a hypervisor sees which guest folder each one came from,
    with no transform to undo. Every hypervisor the harness drives (Hyper-V,
    KVM/libvirt, UTM) accepts dots in a domain/VM name.
    #>
    param(
        [Parameter(Mandatory)] [string]$GuestKey,
        [string]$Prefix = "test-",
        [string]$HostId
    )
    $stem = $GuestKey
    # Pool: an 8-hex HostId segment scopes the VM name to this host so
    # multiple pool members on a SHARED store never collide. ABSENT (legacy /
    # single-host) -> byte-identical to the old name. The segment is alphanumeric,
    # satisfying the per-host New-VM.ps1 name validator.
    if ([string]::IsNullOrWhiteSpace($HostId)) {
        $vmName = "${Prefix}${stem}-01"
    }
    else {
        $h = ($HostId -replace '[^0-9A-Za-z]', '')
        if ($h.Length -gt 8) { $h = $h.Substring(0, 8) }
        $vmName = "${Prefix}${stem}-${h}-01"
    }
    # Shell-safety guard at the composition ingest point. The VM name flows
    # into interpolated commands downstream -- a KVM `bash -c` virt-viewer
    # invocation and hypervisor CLIs on every platform. The HostId segment is
    # reduced to [A-Za-z0-9] above, but neither the operator-configurable prefix
    # (vmStart.testVmNamePrefix) nor the guest key is: either one carrying a
    # space or shell metacharacter would ride through the interpolation. Reject
    # here so a metacharacter name can never reach a command string, whichever
    # host type ends up running it.
    if ($vmName -notmatch '^[A-Za-z0-9._-]+$') {
        throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_e80a19e94ca9be85' -Arguments @{ vmName = "$vmName"; prefix = "$Prefix" })
    }
    return $vmName
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
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_29205489a1013ab0')
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
        the required permission..." that Hyper-V\Get-VM emits: in a
        non-elevated run of Remove-TestVMFiles.ps1, Hyper-V\Get-VM
        throws before any user-friendly check is reached.
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f8d1cb83d65d4046' -Arguments @{ hostType = "$HostType" })
    } else {
        $provider = Get-HostConditionProvider -HostType $HostType
        if (-not $provider) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_dc293f36919f189f' -Arguments @{ hostType = "$HostType" })
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
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0761d2ab1dce11c3') -InformationAction Continue
    }

    return $ok
}

Export-ModuleMember -Function Get-HostType, Get-HostFolder, Test-LibvirtGroupReExecNeeded, ConvertTo-LibvirtRelaunchArgument, Invoke-LibvirtGroupReExecIfNeeded, Get-GuestList, Test-GuestFolder, Get-TestVMName, Test-ElevationRequired, Assert-Elevation, Test-HostRequirement
