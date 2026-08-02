<#PSScriptInfo
.VERSION 2026.08.02
.GUID 421f0c84-2d77-4a19-9f3e-5c8a41d02e77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner elevation sudo unattended
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
    Launch-time elevation contract for the unattended test runner: ask once,
    while an operator is still at the console, or refuse to start.
.DESCRIPTION
    The runner spawns its inner with the call operator, so the inner inherits
    the launch terminal. A `sudo` password prompt raised mid-cycle therefore
    blocks the whole host with nobody present to answer -- and because
    runner.heartbeat is written by a threadpool timer that keeps ticking
    through a blocked runspace, the dashboard stays GREEN while nothing
    advances. Remote repair is impossible in that state, and so is remote
    DIAGNOSIS.

    The contract is therefore:

      * Elevation is resolved ONCE, at launch, before the eternal loop --
        the only moment a human is known to be watching.
      * If passwordless sudo already covers every command the cycle needs,
        nothing prompts, ever.
      * If it does not, this is the one place a prompt is allowed. With an
        operator present we install an /etc/sudoers.d drop-in so the NEXT
        launch is silent too (sudo's timestamp expires in ~5 min and every
        cycle is a fresh pwsh, so a cached credential alone would not last).
      * With no operator (-NonInteractive, or stdin not a terminal) the
        runner REFUSES TO START and says what to run on the console. That is
        the right failure: a host that needs a password needs hands on it,
        and so would a host with a broken network.

    Deliberately scoped to the per-cycle runner path. Setup-time elevation
    (bridge construction via nmcli/netplan in Enable-TestAutomation, the
    poolStorage mount drop-in via Set-PoolStorageSudoers) belongs to the
    interactive scripts that own it and is not re-litigated here.

    Windows is a no-op: elevation there is an Administrator token the runner
    already asserts up front (Yuruna.HostRedirect refuses and instructs rather
    than raising UAC mid-run), so there is nothing to prime.
#>

# Per-host-type command manifest for the PER-CYCLE path. A host driver may take
# ownership by exporting Get-HostElevationCommand (resolved first, below); until
# one does, this table is the single place the list lives, so a new sudo call
# site in the cycle path has exactly one place to register itself.
#
# ubuntu.kvm: the caching-proxy port map (Add-PortMap / Remove-PortMap) writes
# and removes /etc/systemd/system/yuruna-cacheproxy-p<port>.{socket,service} and
# reloads systemd. That is the whole per-cycle elevation surface on KVM.
$script:ElevationManifest = @{
    'host.ubuntu.kvm' = @(
        @{ Command = '/usr/bin/systemctl'; Why = 'enable/disable/stop the yuruna-cacheproxy forwarder units and daemon-reload' }
        @{ Command = '/usr/bin/tee';       Why = 'write the yuruna-cacheproxy unit files under /etc/systemd/system' }
        @{ Command = '/usr/bin/rm';        Why = 'remove those unit files when the cache moves or goes external' }
    )
    # macOS binds privileged port 80 for the CA-cert page during a
    # caching-proxy bring-up, which is not part of a normal cycle; the per-cycle
    # forwarders are unprivileged. Nothing to assert.
    'host.macos.utm'  = @()
    # Windows: Administrator token, asserted elsewhere. No sudo.
    'host.windows.hyper-v' = @()
}

function Get-RunnerElevationCommand {
    <#
    .SYNOPSIS
        The fully-qualified commands the per-cycle runner may need to run under
        sudo on this host type, each with the reason shown to the operator.
    .DESCRIPTION
        Prefers a host driver's own Get-HostElevationCommand when one is
        exported (the list is driver knowledge, and a driver that grows a new
        elevated call site should be able to say so without editing this
        module); falls back to the manifest above.

        sudoers matches the command sudo resolves through secure_path, so the
        paths must be FULLY QUALIFIED and must match reality on the host -- a
        rule written against the wrong path silently never matches. Resolve each
        name against the live filesystem and keep the manifest path only as the
        fallback, mirroring Get-PoolStorageSudoCommandPath.
    .OUTPUTS
        [hashtable[]] each @{ Command; Why }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][string]$HostType)

    if (Get-Command Get-HostElevationCommand -ErrorAction SilentlyContinue) {
        try {
            $fromDriver = @(Get-HostElevationCommand)
            if ($fromDriver.Count -gt 0) { return [hashtable[]]$fromDriver }
        } catch {
            Write-Verbose "Get-HostElevationCommand failed; using the built-in manifest: $($_.Exception.Message)"
        }
    }
    $entries = @($script:ElevationManifest[$HostType])
    if (-not $entries) { return [hashtable[]]@() }

    return [hashtable[]]@(foreach ($e in $entries) {
        $leaf = Split-Path -Leaf $e.Command
        $live = (Get-Command -CommandType Application -Name $leaf -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        @{ Command = $(if ($live) { $live } else { $e.Command }); Why = $e.Why }
    })
}

function Test-RunnerElevationReady {
    <#
    .SYNOPSIS
        True when passwordless sudo is ALREADY in effect for every supplied
        command, so an unattended cycle can never be stopped by a prompt.
    .DESCRIPTION
        `sudo -n -l <cmd>` exits 0 when the invoking user may run <cmd> and,
        because of -n, never prompts -- safe on the unattended path as well as
        the interactive one. Biased toward $false: anything that is not a clean
        0 reports "not ready", because a false "already configured" leaves the
        runner exactly as stoppable as before while a redundant re-install only
        costs one prompt.

        An empty command list is READY: a host type with no per-cycle elevation
        surface (macOS, Windows) has nothing to assert.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyCollection()][hashtable[]]$Command = @())

    if (-not ($IsLinux -or $IsMacOS)) { return $true }
    if (@($Command).Count -eq 0) { return $true }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return $false }
    try {
        # Assigned first rather than inlined in the comparison: PSSA reads
        # "$(... 2>$null)" inside a comparison as a possible mistyped
        # redirection operator, and the repo's analyzer run is expected clean.
        $uid = "$(& '/usr/bin/id' -u 2>$null)".Trim()
        if ($uid -eq '0') { return $true }   # root needs no sudo
    } catch { Write-Verbose 'id unavailable; assuming non-root.' }

    foreach ($c in $Command) {
        if ([string]::IsNullOrWhiteSpace($c.Command)) { continue }
        & sudo -n -l $c.Command 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "Elevation not ready for '$($c.Command)' (sudo -n -l exit $LASTEXITCODE)."
            return $false
        }
    }
    return $true
}

function Get-RunnerSudoersSpec {
    <#
    .SYNOPSIS
        The /etc/sudoers.d drop-in path and NOPASSWD rule granting the supplied
        commands to one account.
    .OUTPUTS
        [hashtable] @{ User; File; Rule; Commands }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # AllowEmptyString so the guard below can handle a blank account
        # gracefully. Without it, binding rejects '' and Assert-RunnerElevation
        # throws while building its refusal banner -- turning "here is the rule
        # to install" into an unhandled exception on precisely the host that
        # most needs the instructions. A host where `id -un` fails is unusual
        # but it is exactly the degraded case this path exists to report.
        [Parameter(Mandatory)][AllowEmptyString()][string]$User,
        [Parameter()][AllowEmptyCollection()][hashtable[]]$Command = @(),
        [Parameter()][string]$DropInName = 'yuruna-runner'
    )
    $file = "/etc/sudoers.d/$DropInName"
    $cmds = @(@($Command) | ForEach-Object { $_.Command } | Where-Object { $_ } | Select-Object -Unique)
    if ([string]::IsNullOrWhiteSpace($User) -or $cmds.Count -eq 0) {
        return @{ User = $User; File = $file; Rule = ''; Commands = @() }
    }
    return @{
        User     = $User
        File     = $file
        Rule     = "$User ALL=(root) NOPASSWD: $($cmds -join ', ')"
        Commands = $cmds
    }
}

function Get-RunnerElevationHint {
    <#
    .SYNOPSIS
        The exact commands an operator must run ON THE CONSOLE to make this host
        runnable unattended. Printed whenever the runner refuses to start.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][hashtable]$Spec)
    if (-not $Spec.Rule) { return @() }
    return @(
        "  echo '$($Spec.Rule)' | sudo tee $($Spec.File) >/dev/null"
        "  sudo chmod 0440 $($Spec.File) && sudo visudo -cf $($Spec.File)"
    )
}

function Install-RunnerSudoers {
    <#
    .SYNOPSIS
        Idempotently install the runner's passwordless-sudo drop-in, prompting
        the operator ONCE. Interactive path only.
    .DESCRIPTION
        Mirrors Set-PoolStorageSudoers: write via `sudo tee`, chmod 0440,
        validate with `visudo -cf`, and REMOVE the file again if validation
        fails -- an invalid drop-in can break sudo for every command on the
        host, which is far worse than the prompt it was meant to remove.

        sudo is invoked so its one password prompt reaches the operator's
        terminal; the cached timestamp then carries the chmod and visudo.
    .OUTPUTS
        [hashtable] @{ Action = unsupported|present|installed|failed; Message; Spec }.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = '"sudoers" is the singular domain term for the sudo policy system (/etc/sudoers, /etc/sudoers.d); it is not a plural of "sudoer".')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive operator flow: this text accompanies sudo''s own password prompt on the terminal the operator is watching, and must not be capturable into a variable by a caller.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Command,
        [Parameter()][string]$User
    )
    if (-not $IsLinux) {
        return @{ Action = 'unsupported'; Message = 'the runner sudoers drop-in applies to Linux hosts only.'; Spec = $null }
    }
    if ([string]::IsNullOrWhiteSpace($User)) {
        try { $User = "$(& '/usr/bin/id' -un 2>$null)".Trim() } catch { $User = '' }
        if ([string]::IsNullOrWhiteSpace($User)) { $User = "$($env:USER)".Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($User)) {
        return @{ Action = 'failed'; Message = 'could not determine the current user to grant passwordless sudo to.'; Spec = $null }
    }

    $spec = Get-RunnerSudoersSpec -User $User -Command $Command
    if (-not $spec.Rule) {
        return @{ Action = 'present'; Message = 'no elevated commands are needed on this host type.'; Spec = $spec }
    }
    if (Test-RunnerElevationReady -Command $Command) {
        return @{ Action = 'present'; Message = "passwordless sudo is already configured for '$User'."; Spec = $spec }
    }
    if (-not $PSCmdlet.ShouldProcess($spec.File, "Install the runner's passwordless-sudo drop-in for '$User'")) {
        return @{ Action = 'failed'; Message = 'declined.'; Spec = $spec }
    }

    Write-Host "Yuruna runner: installing $($spec.File) so unattended cycles never need a password (sudo may prompt once)..."
    try {
        $spec.Rule | & sudo tee $spec.File | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return @{ Action = 'failed'; Message = "could not write $($spec.File) (sudo tee exit $LASTEXITCODE)."; Spec = $spec }
        }
        & sudo chmod 0440 $spec.File | Out-Null
        $chmodRc   = $LASTEXITCODE
        $visudoOut = (& sudo visudo -cf $spec.File 2>&1 | Out-String).Trim()
        $visudoRc  = $LASTEXITCODE
        if ($chmodRc -ne 0 -or $visudoRc -ne 0) {
            & sudo rm -f $spec.File | Out-Null
            return @{ Action = 'failed'; Message = "the drop-in failed validation (chmod $chmodRc, visudo ${visudoRc}: $visudoOut) and was removed."; Spec = $spec }
        }
        return @{ Action = 'installed'; Message = "installed $($spec.File): '$User' may now run the runner's elevated commands without a password."; Spec = $spec }
    } catch {
        return @{ Action = 'failed'; Message = "install threw: $($_.Exception.Message)"; Spec = $spec }
    }
}

function Assert-RunnerElevation {
    <#
    .SYNOPSIS
        Resolve the runner's elevation contract at launch. Returns $true when
        the host can run unattended; $false means DO NOT START.
    .DESCRIPTION
        Order of resolution:
          1. Nothing to assert (Windows, macOS, root, no manifest) -> ready.
          2. Already passwordless for every command -> ready, silently.
          3. An operator is present -> offer to install the drop-in, once.
          4. No operator -> refuse, printing the console commands to run.

        Returning $false is a REFUSAL TO START, not a warning. Starting anyway
        would produce the failure this whole contract exists to prevent: a
        password prompt mid-cycle on a terminal nobody is watching.
    .PARAMETER NonInteractive
        Never prompt or install; report and fail. Set this for service /
        cron / CI launches.
    .OUTPUTS
        [bool] $true when the runner may start.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Launch-time operator gate: the refusal and its remediation commands must reach the console beside sudo''s own prompt, and must not be swallowed by a caller redirecting the success stream.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [switch]$NonInteractive
    )
    if (-not $IsLinux) { return $true }

    $commands = @(Get-RunnerElevationCommand -HostType $HostType)
    if ($commands.Count -eq 0) { return $true }
    if (Test-RunnerElevationReady -Command $commands) { return $true }

    # An operator is present only if this process actually has a terminal to
    # prompt on. Redirected stdin means a service/cron launch, where a prompt
    # would read EOF and a "cancelled" answer would be indistinguishable from a
    # real refusal.
    $interactive = -not $NonInteractive
    if ($interactive) {
        try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { $interactive = $false }
    }

    if ($interactive) {
        $result = Install-RunnerSudoers -Command $commands -Confirm:$false
        if ($result.Action -in @('present', 'installed')) {
            Write-Host "Yuruna runner: elevation ready -- $($result.Message)"
            return $true
        }
        Write-Warning "Yuruna runner: could not configure passwordless sudo -- $($result.Message)"
    }

    $user = try { "$(& '/usr/bin/id' -un 2>$null)".Trim() } catch { '' }
    if (-not $user) { $user = "$($env:USER)".Trim() }
    # A placeholder beats a blank in the printed rule: the operator can still
    # see the shape of the command and substitute their own account, whereas
    # "ALL=(root) NOPASSWD:" with no user reads as a broken instruction.
    $specUser = if ($user) { $user } else { '<your-account>' }
    $spec = Get-RunnerSudoersSpec -User $specUser -Command $commands
    Write-Host ''
    Write-Host '================================================================'
    Write-Host '  RUNNER NOT STARTED -- elevation required'
    Write-Host '================================================================'
    Write-Host ''
    Write-Host "  Host type: $HostType"
    Write-Host "  Account:   $(if ($user) { $user } else { '(could not be determined)' })"
    Write-Host ''
    Write-Host '  This host needs passwordless sudo for the commands below. Without'
    Write-Host '  it a cycle would stop mid-run on a password prompt that nobody is'
    Write-Host '  present to answer, and the status page would keep reporting the'
    Write-Host '  last cycle as healthy.'
    Write-Host ''
    foreach ($c in $commands) { Write-Host "    * $($c.Command) -- $($c.Why)" }
    Write-Host ''
    Write-Host '  Fix (needs onsite / console access -- this cannot be repaired'
    Write-Host '  remotely, for the same reason a network fault cannot):'
    Write-Host ''
    foreach ($line in (Get-RunnerElevationHint -Spec $spec)) { Write-Host $line }
    Write-Host ''
    Write-Host '  Then re-run: pwsh test/Invoke-TestRunner.ps1'
    Write-Host '================================================================'
    Write-Host ''
    return $false
}

Export-ModuleMember -Function Get-RunnerElevationCommand, Test-RunnerElevationReady,
    Get-RunnerSudoersSpec, Get-RunnerElevationHint, Install-RunnerSudoers, Assert-RunnerElevation
