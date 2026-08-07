<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42e7c3b1-9d64-4a52-8f0e-7c1b3a9d6e50
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna setup root sudo cleanup
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

# Finds and clears the durable state a `sudo` run of the entry points leaves
# behind. Unix-only: an elevated Windows run writes files the operator's
# account can still modify, so there is no equivalent trap to sweep.
# --- REGION: https://yuruna.link/install/explained#root-artifact-sweep--what-a-sudo-run-leaves-behind

$script:RootArtifactProcessTimeoutSeconds = 20

function Invoke-RootArtifactProcess {
    <#
    .SYNOPSIS
        Run a native command bounded by a wall-clock cap with stdin closed.
        Returns @{ ExitCode; StdOut; StdErr }. Never throws, never prompts.
    .DESCRIPTION
        stdin is redirected and closed immediately so a `sudo` that WOULD ask for
        a password gets EOF and fails fast instead of stalling a preflight. Both
        output streams are drained, because an un-drained pipe deadlocks a chatty
        child. ExitCode is 124 on timeout and -1 when the process could not start.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][int]$TimeoutSeconds = $script:RootArtifactProcessTimeoutSeconds
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message }
    }
    try {
        $proc.StandardInput.Close()
        # Read to end BEFORE waiting: reading drains the pipes, so a child that
        # outruns the buffer cannot block on a full pipe while we wait on exit.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill($true) } catch { $null = $_ }
            return @{ ExitCode = 124; StdOut = ''; StdErr = "timeout ${TimeoutSeconds}s" }
        }
        return @{ ExitCode = $proc.ExitCode; StdOut = [string]$outTask.Result; StdErr = [string]$errTask.Result }
    } catch {
        return @{ ExitCode = -1; StdOut = ''; StdErr = $_.Exception.Message }
    } finally {
        if ($proc) { $proc.Dispose() }
    }
}

function Get-YurunaRootHomePath {
    <#
    .SYNOPSIS
        Root's home directory on this platform, or '' where the concept does not
        apply. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return '' }
    if ($IsMacOS)   { return '/var/root' }
    return '/root'
}

function Test-RootArtifactSudoAnswered {
    <#
    .SYNOPSIS
        $true when a `sudo -n` result is a real answer rather than a refusal to
        run without a password. Pure (classifies text + exit code).
    .DESCRIPTION
        `sudo -n test -d X` exits non-zero both when X is absent and when sudo
        will not run unprompted -- the same code for "no" and "I cannot tell you".
        Reading the second as the first would report a clean machine on any host
        whose sudo credential is not cached, which is the opposite of the error
        this sweep exists to avoid. Only stderr separates them.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][int]$ExitCode = 0,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$StdErr
    )
    if ($ExitCode -eq 124 -or $ExitCode -eq -1) { return $false }
    if ([string]::IsNullOrWhiteSpace($StdErr)) { return $true }
    return -not ($StdErr -match '(?i)(a password is required|a terminal is required|no tty present|may not run|not allowed to execute|no askpass)')
}

function New-RootArtifactRecord {
    <#
    .SYNOPSIS
        Build one finding record. Pure: constructs an object and changes nothing.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure in-memory factory for the finding record; it touches no system state, so -WhatIf would gate nothing. Clear-YurunaRootArtifact is where the state changes and it does support ShouldProcess.')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][bool]$Blocking,
        [Parameter(Mandatory)][string]$Summary,
        [Parameter()][string[]]$Detail = @(),
        [Parameter()][string[]]$Remedy = @(),
        [Parameter()][object[]]$Items = @(),
        # The single path a whole-tree action applies to, where the Items list is
        # a SAMPLE rather than the work. Only repo-file uses it: a root run keeps
        # writing while the scan runs, so the fix has to cover the tree, not the
        # filenames that happened to be seen.
        [Parameter()][string]$Target = ''
    )
    return [pscustomobject]@{
        Kind = $Kind; Blocking = $Blocking; Summary = $Summary
        Detail = @($Detail); Remedy = @($Remedy); Items = @($Items); Target = $Target
    }
}

function Get-YurunaRootOwnedRepoFile {
    <#
    .SYNOPSIS
        Files owned by uid 0 in the repo directories a normal run writes to,
        one record per directory. Empty when there are none.
    .DESCRIPTION
        `find -uid 0` rather than a PowerShell walk: owner uid is not exposed on
        FileSystemInfo across the versions this has to run on, and find is present
        on every macOS and Linux host and reads the whole tree in one pass.

        BLOCKING. These are the files that break the next run rather than merely
        wasting space, and an in-place overwrite of a root-owned file fails for
        the operator no matter how writable its directory is.

        Both directories an unprivileged run writes into are scanned, because a
        clean report for one of them is not a clean report for the machine:
        test/status carries the json + yml a cycle rewrites every pass, and
        install/ carries the answer file a guided run saves on its way out. A
        scan narrower than what the run writes hands back an all-clear that the
        very next permission error contradicts.

        One record per directory, so each carries the chown that clears it.
    .OUTPUTS
        pscustomobject[] -- empty when nothing is root-owned.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $records = [System.Collections.Generic.List[pscustomobject]]::new()
    $find = (Get-Command -CommandType Application -Name 'find' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $find) { return $records.ToArray() }
    $user = Get-RootArtifactCurrentUser

    foreach ($relative in @('test/status', 'install')) {
        $dir = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $r = Invoke-RootArtifactProcess -FilePath $find -ArgumentList @($dir, '-uid', '0')
        if ($r.ExitCode -ne 0 -and -not $r.StdOut) { continue }
        $paths = @(($r.StdOut -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($paths.Count -eq 0) { continue }

        # Shown truncated: a root run can touch thousands of cycle files and the
        # list is evidence, not a worklist -- the count plus a sample is what an
        # operator reads, and the remedy covers all of them either way.
        $sample = @($paths | Select-Object -First 8)
        $detail = @($sample | ForEach-Object { "    $_" })
        if ($paths.Count -gt $sample.Count) { $detail += "    ... and $($paths.Count - $sample.Count) more" }
        [void]$records.Add((New-RootArtifactRecord -Kind 'repo-file' -Blocking $true `
            -Summary "$($paths.Count) file(s) under $relative are owned by root" `
            -Detail $detail `
            -Remedy @("sudo chown -R ${user}: '$dir'") `
            -Items $paths -Target $dir))
    }
    return $records.ToArray()
}

function Get-YurunaRootOwnedListener {
    <#
    .SYNOPSIS
        Records for service ports held by an owner this user cannot see -- the
        signature of a root-owned listener. Empty when every port is free or
        visibly ours.
    .DESCRIPTION
        BLOCKING, and the one that stops a run outright: a bring-up refuses on a
        port it cannot bind, and an unprivileged lsof shows nothing, so the
        operator is sent hunting a holder that does not appear to exist.

        The signature is a bind that fails while no PID is visible. A holder this
        user CAN see is somebody else's problem to report (the port-owner module
        already names it), so it is not swept here.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][int[]]$Port)

    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not (Get-Command Test-PortListenerFree -ErrorAction SilentlyContinue)) { return $out.ToArray() }
    foreach ($p in ($Port | Sort-Object -Unique)) {
        if (Test-PortListenerFree -Port $p) { continue }
        $visible = @()
        try { $visible = @(Get-PortListenerPid -Port $p) } catch { Write-Verbose "Get-PortListenerPid($p): $($_.Exception.Message)" }
        if ($visible.Count -gt 0) { continue }
        $out.Add((New-RootArtifactRecord -Kind 'listener' -Blocking $true `
            -Summary "port $p is held by a listener this account cannot see (a root-owned service)" `
            -Detail @(
                "    nothing binds :$p, and 'lsof' as this user reports no holder --"
                "    the signature of a socket owned by another account, normally a"
                "    status or config service left running by an earlier sudo run."
            ) `
            -Remedy @("sudo lsof -nP -iTCP:$p -sTCP:LISTEN") `
            -Items @($p)))
    }
    return $out.ToArray()
}

function Get-YurunaRootHomeArtifact {
    <#
    .SYNOPSIS
        A record for root's own yuruna tree (base images + VM bundles), or $null.
    .DESCRIPTION
        ADVISORY, not blocking. Nothing later fails because this exists -- the
        operator's own tree is used instead. It is reported because it is
        invisible (root's home is mode 700, so it does not show up in anything an
        operator would normally look at) and expensive: cloud images and VM
        bundles run to tens of GB that no hypervisor on this machine can reach.

        Probed with `sudo -n`, which never prompts. When sudo will not answer
        without a password the class is reported as UNKNOWN rather than absent --
        silently calling it clean on every host with an uncached credential would
        defeat the check.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $rootHome = Get-YurunaRootHomePath
    if (-not $rootHome) { return $null }
    $target = "$rootHome/yuruna"
    # Unprivileged first: on a host where root's home is traversable this answers
    # without involving sudo at all.
    #
    # -ErrorAction SilentlyContinue because a DENIED probe is an expected answer
    # here, not a fault. macOS keeps /var/root at 0700, so an unprivileged
    # Test-Path returns $false AND writes a red "Access to the path is denied"
    # error to the caller's console -- during setup, in the middle of the step
    # list, on a check that goes on to succeed by asking sudo instead. The
    # sudo-backed probe below is the one that decides; this branch is only the
    # shortcut for hosts where the answer is free.
    if (Test-Path -LiteralPath $target -ErrorAction SilentlyContinue) {
        return New-RootArtifactRecord -Kind 'root-home' -Blocking $false `
            -Summary "root's own yuruna tree exists at $target" `
            -Detail @('    Base images and VM bundles a previous sudo run wrote into root''s home.',
                      '    The hypervisor runs as you and cannot reach them, so they are dead weight.') `
            -Remedy @("sudo du -sh '$target'", "sudo rm -rf '$target'") `
            -Items @($target)
    }
    $sudo = (Get-Command -CommandType Application -Name 'sudo' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $sudo) { return $null }
    $r = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'test', '-d', $target)
    if (-not (Test-RootArtifactSudoAnswered -ExitCode $r.ExitCode -StdErr $r.StdErr)) {
        return New-RootArtifactRecord -Kind 'root-home' -Blocking $false `
            -Summary "could not check whether root has its own yuruna tree at $target" `
            -Detail @('    root''s home is not readable by this account and sudo declined to answer',
                      '    without a password. Harmless if no sudo run ever happened here.') `
            -Remedy @("sudo test -d '$target' && sudo du -sh '$target'") `
            -Items @()
    }
    if ($r.ExitCode -ne 0) { return $null }
    return New-RootArtifactRecord -Kind 'root-home' -Blocking $false `
        -Summary "root's own yuruna tree exists at $target" `
        -Detail @('    Base images and VM bundles a previous sudo run wrote into root''s home.',
                  '    The hypervisor runs as you and cannot reach them, so they are dead weight.') `
        -Remedy @("sudo du -sh '$target'", "sudo rm -rf '$target'") `
        -Items @($target)
}

function Select-RootArtifactMountLine {
    <#
    .SYNOPSIS
        Mount points under root's home, from `mount` output. Pure + testable:
        lines in, mount points out.
    .DESCRIPTION
        Anchored on the mount POINT being inside root's home, not on the share
        name. A mount the operator cannot see the point of is a mount they cannot
        unmount by hand, and on macOS any mount of a share blocks a second mount
        of that same share elsewhere -- so which share it is does not change what
        has to happen to it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][string[]]$MountLine,
        [Parameter(Mandatory)][string]$RootHome
    )
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not $MountLine) { return $out.ToArray() }
    foreach ($line in $MountLine) {
        $s = [string]$line
        $sep = $s.IndexOf(' on ')
        if ($sep -lt 0) { continue }
        $tail = $s.Substring($sep + 4)
        $tIdx = $tail.IndexOf(' type ')              # Linux: "/mnt/x type cifs (...)"
        $point = if ($tIdx -ge 0) { $tail.Substring(0, $tIdx) } else {
            $pIdx = $tail.LastIndexOf(' (')          # macOS: "/var/root/Shares/x (smbfs, ...)"
            if ($pIdx -ge 0) { $tail.Substring(0, $pIdx) } else { $tail }
        }
        $point = $point.Trim()
        if (-not $point) { continue }
        # macOS reports /var through its /private symlink, so both spellings of
        # root's home have to match.
        foreach ($prefix in @($RootHome, "/private$RootHome")) {
            if ($point.StartsWith("$prefix/", [StringComparison]::Ordinal)) {
                if ($out -notcontains $point) { [void]$out.Add($point) }
                break
            }
        }
    }
    return $out.ToArray()
}

function Get-YurunaRootOwnedMount {
    <#
    .SYNOPSIS
        A record for SMB mounts standing under root's home, or $null.
    .DESCRIPTION
        BLOCKING on macOS, where the kernel refuses a second mount of a share it
        already holds with "File exists" -- and the mount path reports that as a
        credential failure, which sends the operator to reset a password that was
        correct. `mount` lists every mount regardless of owner, so this needs no
        elevation to SEE, only to clear.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $rootHome = Get-YurunaRootHomePath
    if (-not $rootHome) { return $null }
    $mountExe = (Get-Command -CommandType Application -Name 'mount' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $mountExe) { return $null }
    $r = Invoke-RootArtifactProcess -FilePath $mountExe -ArgumentList @()
    if (-not $r.StdOut) { return $null }
    $points = @(Select-RootArtifactMountLine -MountLine (($r.StdOut -split "`n")) -RootHome $rootHome)
    if ($points.Count -eq 0) { return $null }
    return New-RootArtifactRecord -Kind 'mount' -Blocking $true `
        -Summary "$($points.Count) share(s) are mounted under root's home" `
        -Detail (@("    Mounted by an earlier sudo run, under a home you cannot reach:") +
                 @($points | ForEach-Object { "    $_" }) +
                 @("    On macOS these block your own mount of the same share with 'File exists'.")) `
        -Remedy @($points | ForEach-Object { "sudo umount '$_'" }) `
        -Items $points
}

function Get-RootArtifactCurrentUser {
    <#
    .SYNOPSIS
        The current account name for a chown target. Falls back to the
        environment when `id` is unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $idExe = (Get-Command -CommandType Application -Name 'id' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ($idExe) {
        $r = Invoke-RootArtifactProcess -FilePath $idExe -ArgumentList @('-un')
        $name = "$($r.StdOut)".Trim()
        if ($name) { return $name }
    }
    if ($env:USER) { return $env:USER }
    return [Environment]::UserName
}

function Get-YurunaRootArtifact {
    <#
    .SYNOPSIS
        Every trace a previous root/sudo run left on this machine, as records.
        Empty on Windows and on a clean machine. Never prompts, never elevates,
        never throws.
    .PARAMETER RepoRoot
        Repository root, for the ownership scan of the directories a run writes.
    .PARAMETER Port
        Service ports to check for a foreign listener. Callers pass the CONFIGURED
        statusService/configService ports so a checkout on a non-default port is
        not checked against the wrong one.
    .OUTPUTS
        pscustomobject[] with Kind, Blocking, Summary, Detail, Remedy, Items.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter()][int[]]$Port = @()
    )
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    if ($IsWindows) { return $out.ToArray() }
    # Get-YurunaRootOwnedRepoFile returns one record per scanned directory; the
    # array subexpression flattens that in alongside the single-record probes.
    foreach ($record in @(
        (Get-YurunaRootOwnedRepoFile -RepoRoot $RepoRoot),
        (Get-YurunaRootOwnedMount),
        (Get-YurunaRootHomeArtifact))) {
        if ($record) { [void]$out.Add($record) }
    }
    if ($Port.Count -gt 0) {
        foreach ($record in @(Get-YurunaRootOwnedListener -Port $Port)) { [void]$out.Add($record) }
    }
    return $out.ToArray()
}

function Write-YurunaRootArtifactReport {
    <#
    .SYNOPSIS
        Print the findings, blocking ones first, each with the commands that
        clear it. Returns nothing.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object[]]$Artifact)
    $items = @($Artifact | Where-Object { $_ })
    if ($items.Count -eq 0) { return }
    Write-Information '' -InformationAction Continue
    Write-Information 'A previous run of these scripts under sudo left state behind on this machine:' -InformationAction Continue
    foreach ($a in ($items | Sort-Object -Property @{ Expression = { -not $_.Blocking } })) {
        $tag = if ($a.Blocking) { 'BLOCKS' } else { 'waste ' }
        Write-Information '' -InformationAction Continue
        Write-Information "  [$tag] $($a.Summary)" -InformationAction Continue
        foreach ($d in $a.Detail) { Write-Information $d -InformationAction Continue }
        if ($a.Remedy.Count -gt 0) {
            Write-Information '    Clears with:' -InformationAction Continue
            foreach ($c in $a.Remedy) { Write-Information "      $c" -InformationAction Continue }
        }
    }
}

function Clear-YurunaRootArtifact {
    <#
    .SYNOPSIS
        Clear ONE finding, elevating for just that operation. Returns $true when
        the machine no longer carries it.
    .DESCRIPTION
        Elevates, so every path through here is gated: the caller asks, and
        ShouldProcess gates again. Each kind has one narrow action rather than a
        general "run the remedy strings", because those strings are written to be
        read by an operator and running arbitrary text as root is a different
        thing entirely.

        The listener case is the one with a real safety rule: it kills a process
        owned by another account, so the process is identified through `sudo lsof`
        and killed ONLY when its command name looks like a PowerShell host. A port
        this harness cannot recognise the holder of is left alone and reported --
        an unrelated root daemon that happens to sit on 8080 must survive a yuruna
        setup run.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Artifact)

    if ($IsWindows) { return $false }
    $sudo = (Get-Command -CommandType Application -Name 'sudo' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $sudo) {
        Write-Warning 'sudo is not available, so root-owned state cannot be cleared from here.'
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Artifact.Summary, 'Clear root-owned state (elevates)')) { return $false }

    switch ($Artifact.Kind) {
        'repo-file' {
            # chown the whole tree (the record's Target), not the listed files:
            # Items is a sample, and the fix has to cover everything the scan
            # truncated as well as anything written since.
            $target = [string]$Artifact.Target
            if (-not $target) {
                Write-Warning 'the finding carries no target directory to take ownership of.'
                return $false
            }
            $user = Get-RootArtifactCurrentUser
            $r = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'chown', '-R', "${user}:", $target) -TimeoutSeconds 120
            if ($r.ExitCode -ne 0) {
                Write-Warning "could not take ownership of $target (sudo chown rc=$($r.ExitCode)): $($r.StdErr.Trim())"
                return $false
            }
            return $true
        }
        'mount' {
            $allOk = $true
            foreach ($point in $Artifact.Items) {
                $r = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'umount', [string]$point) -TimeoutSeconds 60
                if ($r.ExitCode -ne 0) {
                    Write-Warning "could not unmount $point (rc=$($r.ExitCode)): $($r.StdErr.Trim())"
                    $allOk = $false
                }
            }
            return $allOk
        }
        'root-home' {
            $allOk = $true
            foreach ($path in $Artifact.Items) {
                $r = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'rm', '-rf', [string]$path) -TimeoutSeconds 300
                if ($r.ExitCode -ne 0) {
                    Write-Warning "could not remove $path (rc=$($r.ExitCode)): $($r.StdErr.Trim())"
                    $allOk = $false
                }
            }
            return $allOk
        }
        'listener' {
            $port = [int]@($Artifact.Items)[0]
            $lsof = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'lsof', '-t', '-nP', "-iTCP:$port", '-sTCP:LISTEN')
            if ($lsof.ExitCode -ne 0 -and -not $lsof.StdOut) {
                Write-Warning "could not identify the holder of port $port (sudo lsof rc=$($lsof.ExitCode)): $($lsof.StdErr.Trim())"
                return $false
            }
            $pids = @(($lsof.StdOut -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
            if ($pids.Count -eq 0) { return $false }
            $killed = $false
            foreach ($holderPid in $pids) {
                # Name the process before killing it. Anything that is not a
                # PowerShell host is not ours to stop, whatever it is sitting on.
                $ps = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'ps', '-o', 'comm=', '-p', $holderPid)
                $comm = "$($ps.StdOut)".Trim()
                if ($comm -notmatch '(?i)pwsh|powershell') {
                    Write-Warning "port $port is held by PID $holderPid ($comm), which is not a PowerShell host -- refusing to stop it. Stop it yourself or move statusService.port."
                    continue
                }
                $k = Invoke-RootArtifactProcess -FilePath $sudo -ArgumentList @('-n', 'kill', $holderPid)
                if ($k.ExitCode -eq 0) { $killed = $true }
                else { Write-Warning "could not stop PID $holderPid (rc=$($k.ExitCode)): $($k.StdErr.Trim())" }
            }
            if (-not $killed) { return $false }
            # The socket is released asynchronously; give it a moment before the
            # caller re-checks and calls the port still held.
            if (Get-Command Test-PortListenerFree -ErrorAction SilentlyContinue) {
                return [bool](Test-PortListenerFree -Port $port -BudgetMs 5000)
            }
            return $true
        }
        default { return $false }
    }
}

Export-ModuleMember -Function Get-YurunaRootArtifact, Get-YurunaRootOwnedRepoFile, Get-YurunaRootOwnedListener, `
    Get-YurunaRootHomeArtifact, Get-YurunaRootOwnedMount, Get-YurunaRootHomePath, Select-RootArtifactMountLine, `
    Test-RootArtifactSudoAnswered, Write-YurunaRootArtifactReport, Clear-YurunaRootArtifact, Get-RootArtifactCurrentUser
