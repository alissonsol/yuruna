<#PSScriptInfo
.VERSION 2026.07.15
.GUID 42e8f0a1-b2c3-4d45-9678-0a1b2c3d4e5f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna caching-proxy squid migration
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
    Hands a warm squid cache from an old caching-proxy VM to its
    replacement via a temporary parent-child cache hierarchy, then
    retires the old VM. Operator guide: docs/caching-proxy.md#migrating-to-a-replacement-cache-vm
    (https://yuruna.link/caching-proxy-migration).

.DESCRIPTION
    -Start wires the NEW cache VM up as a squid child of the OLD cache
    VM: misses on the new cache are fetched from the old cache's warm
    store at LAN speed, so the new cache fills with exactly the objects
    clients actually use. Both sides are configured through a single
    drop-in file (/etc/squid/conf.d/yuruna-migration.conf); squid.conf
    and yuruna.conf are never touched, every change is validated with
    `squid -k parse` before `squid -k reconfigure`, and a failed parse
    restores the previous state. When the old cache has the ssl-bump CA
    pair, the peer link is TLS (:3130) so ssl-bumped https objects warm
    up too; otherwise the script falls back to a plain :3128 peer and
    says so.

    -End removes the drop-in from the new cache (it goes direct from
    then on, keeping everything it cached), removes the drop-in from
    the old cache, and stops + disables squid there so the old VM is
    ready to be powered off at its host.

    Both phases are idempotent: re-running -Start rewrites the same
    drop-ins; re-running -End is a no-op on the parts already done.
    Each phase ends with printed operator guidance -- after -Start, how
    to repoint clients at the new cache; after -End, how to deactivate
    the old VM at its host.

.PARAMETER Start
    Begin the copy cycle: configure old (parent) and new (child) and
    print the client-switch guidance. Exactly one of -Start/-End.

.PARAMETER End
    End the copy cycle: detach the new cache from the old one, stop and
    disable squid on the old VM, and print the deactivation guidance.

.PARAMETER OldAddress
    IP or hostname of the OLD (source) caching-proxy VM.

.PARAMETER OldUser
    SSH login user on the old VM. Default: yuruna.

.PARAMETER OldPassword
    Password for OldUser. Prompted (masked) when omitted.

.PARAMETER NewAddress
    IP or hostname of the NEW (replacement) caching-proxy VM.

.PARAMETER NewUser
    SSH login user on the new VM. Default: yuruna.

.PARAMETER NewPassword
    Password for NewUser. Prompted (masked) when omitted.

.EXAMPLE
    pwsh test/Move-CachingProxy.ps1 -Start -OldAddress 192.168.68.13 -NewAddress 192.168.68.60
    # Prompts for both passwords, builds the hierarchy, prints how to
    # repoint clients at 192.168.68.60.

.EXAMPLE
    pwsh test/Move-CachingProxy.ps1 -End -OldAddress 192.168.68.13 -NewAddress 192.168.68.60
    # Detaches the new cache, disables squid on the old VM, prints how
    # to power the old VM off at its host.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
    Justification = 'Operator-facing migration tool for throwaway lab-VM credentials; masked prompts cover the interactive path. See docs/caching-proxy.md#migrating-to-a-replacement-cache-vm.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'OldPassword',
    Justification = 'Throwaway lab-VM credential; masked Read-Host prompt when omitted.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'NewPassword',
    Justification = 'Throwaway lab-VM credential; masked Read-Host prompt when omitted.')]
param(
    [switch]$Start,
    [switch]$End,

    # Required, but deliberately NOT [Parameter(Mandatory)]: Mandatory
    # makes PowerShell prompt for values before the script body runs a
    # single line, so a bare invocation would collect addresses and only
    # then report a missing -Start/-End. All requiredness is enforced
    # together in the usage check below, before any prompt.
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$OldAddress,

    [ValidatePattern('^[A-Za-z0-9._][A-Za-z0-9._-]*$')]
    [string]$OldUser = 'yuruna',

    [string]$OldPassword,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
    [string]$NewAddress,

    [ValidatePattern('^[A-Za-z0-9._][A-Za-z0-9._-]*$')]
    [string]$NewUser = 'yuruna',

    [string]$NewPassword
)

# Single well-known drop-in on BOTH VMs. Ubuntu's stock squid.conf
# includes /etc/squid/conf.d/* just before its final http_access rules,
# so an allow here lands ahead of deny-all, and removal restores the
# exact pre-migration configuration.
$script:DropInPath = '/etc/squid/conf.d/yuruna-migration.conf'
$script:TlsPeerPort = 3130

function Write-Ok   { param([string]$Message) Write-Output "  [ OK ] $Message" }
function Write-Note { param([string]$Message) Write-Output "  [note] $Message" }

function Initialize-AskpassHelper {
<#
.SYNOPSIS
    Builds a per-run SSH_ASKPASS helper so ssh can take a password
    non-interactively (no sshpass on Windows; pattern captured in the
    ssh-password-from-windows feedback memory). The password lives in a
    tightly-ACLed temp file read by the helper, never on a command line.
.OUTPUTS
    Hashtable: Directory (to delete when done), Command (SSH_ASKPASS value).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Secret)

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-move-cache-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if ($IsWindows) {
        # Lock the directory to the current user BEFORE the secret lands in it.
        & icacls $dir /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" 2>&1 | Out-Null
    } else {
        & chmod 700 $dir 2>&1 | Out-Null
    }
    $secretPath = Join-Path $dir 'secret.txt'
    Set-Content -LiteralPath $secretPath -Value $Secret -NoNewline

    if ($IsWindows) {
        $helperPath = Join-Path $dir 'askpass.cmd'
        Set-Content -LiteralPath $helperPath -Value "@echo off`r`ntype `"$secretPath`"`r`n" -NoNewline
    } else {
        $helperPath = Join-Path $dir 'askpass.sh'
        Set-Content -LiteralPath $helperPath -Value "#!/bin/sh`ncat '$secretPath'`n" -NoNewline
        & chmod 700 $helperPath 2>&1 | Out-Null
    }
    return @{ Directory = $dir; Command = $helperPath }
}

function Clear-AskpassHelper {
<#
.SYNOPSIS
    Deletes an askpass helper directory (and the secret inside it).
    Best-effort: a leftover directory is confined to the current user
    by its ACL, but the secret should not outlive the run.
#>
    [CmdletBinding()]
    param([hashtable]$Helper)
    if ($null -eq $Helper -or -not $Helper.Directory) { return }
    try {
        Remove-Item -LiteralPath $Helper.Directory -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Could not remove askpass temp dir $($Helper.Directory): $($_.Exception.Message). Delete it manually."
    }
}

function Invoke-VmSsh {
<#
.SYNOPSIS
    Runs one command on a VM over password SSH, bounded by a hard
    wall-clock cap (ssh's ConnectTimeout only bounds TCP setup; a
    half-dead session would otherwise hang the run). Mirrors the
    bounded Process.Start technique used by Test.Ssh's Invoke-GuestSsh.
.DESCRIPTION
    The three host-key options are mandatory for this repo's VMs: cache
    VMs are recreated on recycled DHCP addresses, so a replacement VM
    routinely presents a new host key on an address that had another --
    and this script's whole purpose is talking to such a replacement.
.OUTPUTS
    Hashtable: success (bool), exitCode (int), output (stdout+stderr).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        [Parameter(Mandatory)][string]$Command,
        [string]$StdinText,
        [int]$TimeoutSeconds = 90
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = 'ssh'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # SSH_ASKPASS_REQUIRE=force (OpenSSH 8.4+) makes ssh consult the
    # helper even with a TTY attached; DISPLAY just has to be non-empty.
    $psi.Environment['SSH_ASKPASS']         = [string]$Vm.Askpass
    $psi.Environment['SSH_ASKPASS_REQUIRE'] = 'force'
    $psi.Environment['DISPLAY']             = 'yuruna:0'
    foreach ($sshArg in @(
            '-o', 'PreferredAuthentications=password,keyboard-interactive',
            '-o', 'PubkeyAuthentication=no',
            '-o', 'NumberOfPasswordPrompts=1',
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'GlobalKnownHostsFile=/dev/null',
            '-o', 'ConnectTimeout=10',
            '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=2',
            '-o', 'LogLevel=ERROR',
            "$($Vm.User)@$($Vm.Address)",
            $Command)) {
        $psi.ArgumentList.Add($sshArg)
    }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ success = $false; exitCode = -1; output = "Process.Start('ssh') failed: $($_.Exception.Message)" }
    }
    try {
        if ($StdinText) { $proc.StandardInput.Write($StdinText) }
        $proc.StandardInput.Close()
    } catch {
        Write-Verbose "stdin hand-off to ssh failed: $($_.Exception.Message)"
    }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { Write-Verbose "Process.Kill failed: $($_.Exception.Message)" }
        $proc.Dispose()
        return @{ success = $false; exitCode = -1; output = "ssh timed out after ${TimeoutSeconds}s: $($Vm.User)@$($Vm.Address)" }
    }
    $outputText = $stdoutTask.Result + $stderrTask.Result
    $exit = [int]$proc.ExitCode
    $proc.Dispose()
    return @{ success = ($exit -eq 0); exitCode = $exit; output = $outputText.TrimEnd() }
}

function Invoke-VmRoot {
<#
.SYNOPSIS
    Runs one command as root on a VM, via NOPASSWD sudo when available
    or password-on-stdin sudo otherwise (never the command line).
.DESCRIPTION
    The command is wrapped in `sh -c "<command>"`, so it must not
    contain double quotes, dollar signs, backslashes, or backticks --
    the guard below turns an unsafe command into a loud internal error
    instead of a silently mangled remote invocation.
.OUTPUTS
    Hashtable: success (bool), exitCode (int), output (stdout+stderr).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutSeconds = 90
    )
    if ($Command -match '["$\\`]') {
        throw "Internal error: root command may not contain double quotes, `$, backslash, or backtick: $Command"
    }
    if ($Vm.SudoMode -eq 'nopasswd') {
        return Invoke-VmSsh -Vm $Vm -Command ('sudo -n sh -c "' + $Command + '"') -TimeoutSeconds $TimeoutSeconds
    }
    return Invoke-VmSsh -Vm $Vm -Command ("sudo -S -p '' sh -c " + '"' + $Command + '"') -StdinText ($Vm.Password + "`n") -TimeoutSeconds $TimeoutSeconds
}

function Connect-VmSession {
<#
.SYNOPSIS
    Proves SSH login and sudo on a VM before anything is changed, with
    retries for transient network faults and a fast, explicit failure
    for a wrong password. Sets the VM's SudoMode for Invoke-VmRoot.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Vm)

    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        $probe = Invoke-VmSsh -Vm $Vm -Command 'echo yuruna-move-cache-ready' -TimeoutSeconds 45
        if ($probe.success -and $probe.output -match 'yuruna-move-cache-ready') { break }
        if ($probe.output -match 'Permission denied') {
            throw "$($Vm.Label): SSH authentication failed for $($Vm.User)@$($Vm.Address) -- wrong password, or password authentication is disabled on the VM. ssh said: $($probe.output)"
        }
        if ($i -eq $attempts) {
            throw "$($Vm.Label): cannot reach $($Vm.User)@$($Vm.Address) over SSH after $attempts attempts. Last error (ssh exit $($probe.exitCode)): $($probe.output)"
        }
        Write-Note "$($Vm.Label): SSH attempt $i failed (ssh exit $($probe.exitCode): $($probe.output)); retrying..."
        Start-Sleep -Seconds 5
    }

    $sudoProbe = Invoke-VmSsh -Vm $Vm -Command 'sudo -n true >/dev/null 2>&1 && echo sudo=nopasswd || echo sudo=needpass' -TimeoutSeconds 45
    if ($sudoProbe.output -match 'sudo=nopasswd') {
        $Vm.SudoMode = 'nopasswd'
    } else {
        $stdinProbe = Invoke-VmSsh -Vm $Vm -Command "sudo -S -p '' true >/dev/null 2>&1 && echo sudo=stdin || echo sudo=denied" -StdinText ($Vm.Password + "`n") -TimeoutSeconds 45
        if ($stdinProbe.output -notmatch 'sudo=stdin') {
            throw "$($Vm.Label): user $($Vm.User) cannot sudo on $($Vm.Address) (tried NOPASSWD and password-on-stdin). Output: $($stdinProbe.output)"
        }
        $Vm.SudoMode = 'stdin'
    }
    Write-Ok "$($Vm.Label): SSH session established as $($Vm.User)@$($Vm.Address) (sudo: $($Vm.SudoMode))"
}

function Get-VmSquidFact {
<#
.SYNOPSIS
    Collects the facts the phases branch on: conf.d present, ssl-bump
    CA pair present, squid installed, squid active.
.OUTPUTS
    Hashtable of booleans: ConfD, TlsCert, SquidBin, SquidActive.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Vm)
    $cmd = '[ -d /etc/squid/conf.d ] && echo confd=yes || echo confd=no; ' +
        '[ -f /etc/squid/ssl_cert/ca.pem ] && [ -f /etc/squid/ssl_cert/ca.key ] && echo tlscert=yes || echo tlscert=no; ' +
        'command -v squid >/dev/null 2>&1 && echo squidbin=yes || echo squidbin=no; ' +
        'systemctl is-active squid >/dev/null 2>&1 && echo squidactive=yes || echo squidactive=no'
    $result = Invoke-VmRoot -Vm $Vm -Command $cmd -TimeoutSeconds 45
    if (-not $result.success) {
        throw "$($Vm.Label): squid fact probe failed: $($result.output)"
    }
    return @{
        ConfD       = ($result.output -match 'confd=yes')
        TlsCert     = ($result.output -match 'tlscert=yes')
        SquidBin    = ($result.output -match 'squidbin=yes')
        SquidActive = ($result.output -match 'squidactive=yes')
    }
}

function Get-MigrationDropIn {
<#
.SYNOPSIS
    Reads the migration drop-in currently on a VM, as base64.
.OUTPUTS
    Base64 string when the file exists (empty string for an empty
    file), $null when absent -- the exact input Restore-MigrationDropIn
    needs to put things back.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Vm)
    $cmd = "if [ -f $script:DropInPath ]; then echo state=present; base64 -w0 $script:DropInPath; echo; else echo state=absent; fi"
    $result = Invoke-VmRoot -Vm $Vm -Command $cmd -TimeoutSeconds 45
    if (-not $result.success) {
        throw "$($Vm.Label): reading $script:DropInPath failed: $($result.output)"
    }
    if ($result.output -match 'state=absent') { return $null }
    $b64 = $result.output -split "`r?`n" |
        Where-Object { $_ -and $_ -ne 'state=present' } |
        Select-Object -First 1
    return [string]$b64
}

function Install-MigrationDropIn {
<#
.SYNOPSIS
    Writes the migration drop-in on a VM (content travels as base64, so
    no remote-quoting hazards) and marks it world-readable like every
    other squid config file.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        [Parameter(Mandatory)][string]$Content
    )
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
    $cmd = "printf '%s' '$b64' | base64 -d > $script:DropInPath && chmod 0644 $script:DropInPath"
    $result = Invoke-VmRoot -Vm $Vm -Command $cmd -TimeoutSeconds 45
    if (-not $result.success) {
        throw "$($Vm.Label): writing $script:DropInPath failed: $($result.output)"
    }
}

function Restore-MigrationDropIn {
<#
.SYNOPSIS
    Puts the migration drop-in back to a prior state captured by
    Get-MigrationDropIn ($null removes the file). Best-effort by
    design: used on rollback paths where the primary error must not be
    masked by a rollback error.
.OUTPUTS
    Boolean: $true when the restore command succeeded.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        # Deliberately untyped: a [string] constraint would coerce $null
        # (meaning "the file was absent -- remove it") into '' (meaning
        # "the file existed empty -- recreate it").
        [AllowNull()]$PriorBase64
    )
    if ($null -eq $PriorBase64) {
        $cmd = "rm -f $script:DropInPath"
    } else {
        $cmd = "printf '%s' '$PriorBase64' | base64 -d > $script:DropInPath && chmod 0644 $script:DropInPath"
    }
    $result = Invoke-VmRoot -Vm $Vm -Command $cmd -TimeoutSeconds 45
    if (-not $result.success) {
        Write-Warning "$($Vm.Label): rollback of $script:DropInPath failed: $($result.output)"
    }
    return [bool]$result.success
}

function Test-SquidConfig {
<#
.SYNOPSIS
    Validates the on-disk squid configuration with `squid -k parse`.
    A FATAL config error fed to `squid -k reconfigure` can kill the
    running squid, so every write is parse-gated first.
.OUTPUTS
    Hashtable: success (bool), exitCode, output (the parse report).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Vm)
    return Invoke-VmRoot -Vm $Vm -Command 'squid -k parse' -TimeoutSeconds 60
}

function Invoke-SquidReconfigure {
<#
.SYNOPSIS
    Applies the on-disk configuration to the running squid.
#>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Vm)
    $result = Invoke-VmRoot -Vm $Vm -Command 'squid -k reconfigure' -TimeoutSeconds 60
    if (-not $result.success) {
        throw "$($Vm.Label): squid -k reconfigure failed: $($result.output)"
    }
}

function Wait-RemotePortListening {
<#
.SYNOPSIS
    Polls (on the VM itself) until a local TCP port is listening, up to
    ~10 seconds -- squid reopens listening ports asynchronously after a
    reconfigure.
.OUTPUTS
    Boolean: $true when the port is listening.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        [Parameter(Mandatory)][int]$Port,
        [int]$Attempts = 10
    )
    $loop = (@(1..$Attempts) -join ' ')
    $cmd = "for i in $loop; do ss -ltn 'sport = :$Port' 2>/dev/null | grep -q $Port && break; sleep 1; done; " +
        "ss -ltn 'sport = :$Port' 2>/dev/null | grep -q $Port && echo port=up || echo port=down"
    $result = Invoke-VmRoot -Vm $Vm -Command $cmd -TimeoutSeconds ($Attempts + 35)
    return ($result.output -match 'port=up')
}

function Confirm-MigrationParentRelay {
<#
.SYNOPSIS
    Fail-closed gate: prove the child serves a cache-MISS through the parent on
    both the plain (:3128) and, in TLS mode, the ssl-bump (:3129) path before the
    hierarchy is declared live. Throws on persistent failure so the -Start caller
    rolls both VMs back.
.DESCRIPTION
    A parent link that completes a TCP/TLS handshake but cannot relay a forwarded
    request (e.g. a squid-version peer-TLS incompatibility) would otherwise go
    live and 503 every miss -- misses are pinned to the parent by prefer_direct
    off / nonhierarchical_direct off, and a parent squid never marks "dead" leaves
    no direct fallback. A plain :3128 probe alone is not enough: a CONNECT tunnel
    there succeeds even when the ssl-bump relay is broken, so the bump path is
    probed on its own. Retried to ride out a transient egress blip on the old
    cache rather than roll back a healthy migration.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Vm,
        [switch]$TlsMode,
        [int]$Attempts = 4
    )
    $probes = @(
        [pscustomobject]@{ Port = 3128; Bump = $false; Label = 'plain :3128'; Url = 'http://archive.ubuntu.com/ubuntu/dists/noble/Release' }
    )
    if ($TlsMode) {
        $probes += [pscustomobject]@{ Port = 3129; Bump = $true; Label = 'ssl-bump :3129'; Url = 'https://security.ubuntu.com/ubuntu/dists/noble-security/Release' }
    }
    foreach ($p in $probes) {
        if ($p.Bump) {
            # Trust the parent-minted bump CA when the guest has fetched it; fall
            # back to -k rather than fail on a CA the probe cannot locate.
            $cmd = "if [ -f /var/www/html/yuruna-squid-ca.crt ]; then curl -s -m 25 -o /dev/null -w '%{http_code}' --cacert /var/www/html/yuruna-squid-ca.crt -x http://127.0.0.1:$($p.Port) '$($p.Url)'; else curl -s -m 25 -o /dev/null -w '%{http_code}' -k -x http://127.0.0.1:$($p.Port) '$($p.Url)'; fi"
        } else {
            $cmd = "curl -s -m 25 -o /dev/null -w '%{http_code}' -x http://127.0.0.1:$($p.Port) '$($p.Url)'"
        }
        $code = ''
        for ($i = 1; $i -le $Attempts; $i++) {
            $code = (Invoke-VmSsh -Vm $Vm -Command $cmd -TimeoutSeconds 60).output.Trim()
            if ($code -match '^[23][0-9][0-9]$') { break }
            if ($i -lt $Attempts) { Start-Sleep -Seconds 3 }
        }
        if ($code -match '^[23][0-9][0-9]$') {
            Write-Ok "new cache: cache-miss served through the parent on $($p.Label) (HTTP $code)"
        } else {
            throw "new cache: a cache-miss through the parent on $($p.Label) returned '$code' (expected 2xx/3xx) after $Attempts tries -- the parent link connects but cannot relay, which would 503 every guest miss. Rolling back; check the old cache's :$($p.Port) peer port and both squids' cache.log."
        }
    }
}

# ======================= parameter validation ===========================

# All usage problems are collected and reported together, before ANY
# interactive prompt.
$usageErrors = @()
if ($Start -eq $End) {
    $usageErrors += 'specify exactly one of -Start (begin the copy cycle) or -End (finish it and retire the old cache)'
}
if (-not $OldAddress) { $usageErrors += '-OldAddress <ip-or-hostname> (the old cache VM) is required' }
if (-not $NewAddress) { $usageErrors += '-NewAddress <ip-or-hostname> (the new cache VM) is required' }
if ($usageErrors.Count -gt 0) {
    foreach ($usageError in $usageErrors) { Write-Error "Move-CachingProxy: $usageError" }
    @(
        'Usage:'
        '  pwsh test/Move-CachingProxy.ps1 -Start -OldAddress <old> -NewAddress <new> [-OldUser yuruna] [-OldPassword ...] [-NewUser yuruna] [-NewPassword ...]'
        '  pwsh test/Move-CachingProxy.ps1 -End   -OldAddress <old> -NewAddress <new> [-OldUser yuruna] [-OldPassword ...] [-NewUser yuruna] [-NewPassword ...]'
        'Passwords are prompted (masked) when omitted.'
        'Guide: https://yuruna.link/caching-proxy-migration'
    ) | Write-Output
    exit 1
}
$OldAddress = $OldAddress.Trim()
$NewAddress = $NewAddress.Trim()
if ($OldAddress -ieq $NewAddress) {
    Write-Error "OldAddress and NewAddress are both '$OldAddress' -- the migration needs two different cache VMs."
    exit 1
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Error 'OpenSSH client (ssh) not found on PATH. Install the OpenSSH client feature and retry.'
    exit 1
}
# SSH_ASKPASS_REQUIRE=force needs OpenSSH 8.4+; without it ssh silently
# falls back to prompting on the TTY and the run hangs on a hidden prompt.
$sshVersionText = ((& ssh -V 2>&1) | Out-String).Trim()
# [^0-9]* absorbs vendor infixes ('OpenSSH_for_Windows_9.5p2').
if ($sshVersionText -match 'OpenSSH[^0-9]*([0-9]+)\.([0-9]+)') {
    $sshMajor = [int]$Matches[1]
    $sshMinor = [int]$Matches[2]
    if (($sshMajor -lt 8) -or ($sshMajor -eq 8 -and $sshMinor -lt 4)) {
        Write-Error "OpenSSH 8.4+ is required for non-interactive password login (found: $sshVersionText)."
        exit 1
    }
} else {
    Write-Warning "Could not parse ssh version from '$sshVersionText'; continuing -- if the run stalls at login, upgrade to OpenSSH 8.4+."
}

if (-not $OldPassword) { $OldPassword = Read-Host -MaskInput "Password for $OldUser@$OldAddress (old cache)" }
if (-not $NewPassword) { $NewPassword = Read-Host -MaskInput "Password for $NewUser@$NewAddress (new cache)" }
if (-not $OldPassword -or -not $NewPassword) {
    Write-Error 'Both VM passwords are required.'
    exit 1
}

# The old cache's allow ACL needs the child's IPv4 (squid `acl ... src`
# wants an address, not a name). A resolution miss is survivable: the
# stock yuruna squid ACL already admits RFC1918 sources, so the explicit
# ACL is belt-and-suspenders and is skipped with a warning.
$script:NewAclIp = $null
$parsedIp = $null
if ([System.Net.IPAddress]::TryParse($NewAddress, [ref]$parsedIp) -and $parsedIp.AddressFamily -eq 'InterNetwork') {
    $script:NewAclIp = $NewAddress
} else {
    try {
        $script:NewAclIp = ([System.Net.Dns]::GetHostAddresses($NewAddress) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1).IPAddressToString
    } catch {
        Write-Verbose "DNS lookup for $NewAddress failed: $($_.Exception.Message)"
    }
    if (-not $script:NewAclIp) {
        Write-Warning "Could not resolve '$NewAddress' to an IPv4 address; the explicit child ACL on the old cache will be skipped (the stock RFC1918 allow still admits LAN clients)."
    }
}

# ============================ main =======================================

# Strict from here on: past validation, any unhandled cmdlet error must
# abort into the catch (which reports and exits 1), never limp onward.
$ErrorActionPreference = 'Stop'

$old = @{ Label = 'old cache'; Address = $OldAddress; User = $OldUser; Password = $OldPassword; Askpass = $null; SudoMode = $null }
$new = @{ Label = 'new cache'; Address = $NewAddress; User = $NewUser; Password = $NewPassword; Askpass = $null; SudoMode = $null }
$oldHelper = $null
$newHelper = $null
$failed = $false

try {
    $oldHelper = Initialize-AskpassHelper -Secret $OldPassword
    $newHelper = Initialize-AskpassHelper -Secret $NewPassword
    $old.Askpass = $oldHelper.Command
    $new.Askpass = $newHelper.Command

    if ($Start) {
        Write-Output "== Move-CachingProxy: START copy cycle ($OldAddress -> $NewAddress) =="

        Connect-VmSession -Vm $new
        Connect-VmSession -Vm $old

        $newFact = Get-VmSquidFact -Vm $new
        $oldFact = Get-VmSquidFact -Vm $old
        foreach ($pair in @(@($old, $oldFact), @($new, $newFact))) {
            $vm = $pair[0]; $fact = $pair[1]
            if (-not $fact.SquidBin -or -not $fact.ConfD) {
                throw "$($vm.Label) ($($vm.Address)): squid or /etc/squid/conf.d not found -- this does not look like a yuruna caching-proxy VM."
            }
            if (-not $fact.SquidActive) {
                throw "$($vm.Label) ($($vm.Address)): squid is not active. Start it first (sudo systemctl start squid) and re-run."
            }
        }
        Write-Ok 'both VMs run an active squid with a conf.d include directory'

        # The child fetches from the parent directly, so the parent must be
        # reachable VM-to-VM -- host-side port forwards do not help here.
        $reach = Invoke-VmSsh -Vm $new -Command "timeout 5 bash -c 'echo > /dev/tcp/$OldAddress/3128' 2>/dev/null && echo reach=yes || echo reach=no" -TimeoutSeconds 45
        if ($reach.output -notmatch 'reach=yes') {
            throw ("new cache cannot reach ${OldAddress}:3128 directly. Both cache VMs must sit on routable addresses " +
                '(bridged/LAN, e.g. the yuruna-external / Yuruna-External network); a cache behind host NAT (Hyper-V ' +
                'Default Switch, libvirt default) is invisible to the other VM even when its host forwards :3128.')
        }
        Write-Ok "new cache reaches ${OldAddress}:3128"

        $priorOld = Get-MigrationDropIn -Vm $old
        $priorNew = Get-MigrationDropIn -Vm $new
        if ($null -ne $priorOld -or $null -ne $priorNew) {
            Write-Note 'a migration drop-in already exists (earlier -Start run?); it will be rewritten -- the operation is idempotent'
        }

        $tlsMode = [bool]$oldFact.TlsCert
        if ($tlsMode -and ($null -eq $priorOld)) {
            # :3130 must be free before squid is asked to bind it; if some
            # other service owns the port, parse would pass but the bind
            # would fail quietly inside squid's reconfigure.
            if (Wait-RemotePortListening -Vm $old -Port $script:TlsPeerPort -Attempts 1) {
                throw "old cache: TCP :$script:TlsPeerPort is already in use by another service; free it or remove the conflict, then re-run."
            }
        }
        if (-not $tlsMode) {
            Write-Warning 'old cache has no ssl-bump CA pair (/etc/squid/ssl_cert/ca.pem+key); peering falls back to plain :3128 -- only plain-HTTP objects warm from the old cache, ssl-bumped HTTPS objects re-fetch direct.'
        }

        $deployedOld = $false
        $deployedNew = $false
        try {
            # ---- old cache: accept the child, optionally open the TLS peer port
            $oldBaseLines = @(
                '# Yuruna cache-migration drop-in, managed by test/Move-CachingProxy.ps1.'
                "# This VM is the PARENT: the replacement cache at $NewAddress warms up"
                '# from this cache before taking over. -End removes this file. Manual'
                '# removal is also safe: delete it, then run: squid -k reconfigure'
            )
            if ($script:NewAclIp) {
                $oldBaseLines += @(
                    "acl yuruna_migration_child src $script:NewAclIp"
                    'http_access allow yuruna_migration_child'
                )
            } else {
                $oldBaseLines += '# child ACL omitted (address did not resolve to IPv4); the stock RFC1918 allow admits LAN clients'
            }
            $oldTlsLines = @(
                '# TLS proxy port for the child: squid refuses to relay ssl-bumped'
                '# https requests over a plaintext peer link, so the child connects'
                '# here over TLS; the same link carries plain-http misses too. The'
                '# ssl-bump CA pair doubles as the server certificate.'
                "https_port $script:TlsPeerPort tls-cert=/etc/squid/ssl_cert/ca.pem tls-key=/etc/squid/ssl_cert/ca.key"
            )
            $oldLines = if ($tlsMode) { $oldBaseLines + $oldTlsLines } else { $oldBaseLines }
            Install-MigrationDropIn -Vm $old -Content (($oldLines -join "`n") + "`n")
            $deployedOld = $true
            $oldParse = Test-SquidConfig -Vm $old
            if (-not $oldParse.success) {
                throw "old cache: squid -k parse rejected the migration drop-in; rolling back. Parse output: $($oldParse.output)"
            }
            Invoke-SquidReconfigure -Vm $old
            Write-Ok 'old cache: child allowed in'

            if ($tlsMode) {
                if (Wait-RemotePortListening -Vm $old -Port $script:TlsPeerPort) {
                    Write-Ok "old cache: TLS peer port :$script:TlsPeerPort is listening"
                } else {
                    # Parse passed but the port never opened (e.g. a squid build
                    # without TLS server support). Fall back rather than fail:
                    # a plain :3128 parent still warms every plain-HTTP object.
                    Write-Warning "old cache: :$script:TlsPeerPort did not come up after reconfigure; falling back to plain :3128 peering (ssl-bumped HTTPS objects will re-fetch direct)."
                    $tlsMode = $false
                    Install-MigrationDropIn -Vm $old -Content (($oldBaseLines -join "`n") + "`n")
                    $oldParse = Test-SquidConfig -Vm $old
                    if (-not $oldParse.success) {
                        throw "old cache: fallback drop-in failed squid -k parse: $($oldParse.output)"
                    }
                    Invoke-SquidReconfigure -Vm $old
                }
            }

            # ---- new cache: point at the parent
            $newLines = @(
                '# Yuruna cache-migration drop-in, managed by test/Move-CachingProxy.ps1.'
                "# This VM is the CHILD: cache misses are fetched from the old cache at"
                "# $OldAddress (parent) at LAN speed until this cache is warm. -End"
                '# removes this file. Manual removal is also safe: delete it, then run:'
                '# squid -k reconfigure'
            )
            if ($tlsMode) {
                $newLines += @(
                    '# tls: bumped https misses only relay over a TLS parent link. The'
                    '# parent presents its self-minted squid CA as the server cert, so'
                    '# peer/domain verification is off -- both ends are lab VMs on a'
                    '# LAN-internal link that exists only for the life of the migration.'
                    "cache_peer $OldAddress parent $script:TlsPeerPort 0 no-query default tls tls-flags=DONT_VERIFY_PEER,DONT_VERIFY_DOMAIN connect-fail-limit=3 connect-timeout=10 name=yuruna_migration_parent"
                )
            } else {
                $newLines += "cache_peer $OldAddress parent 3128 0 no-query default connect-fail-limit=3 connect-timeout=10 name=yuruna_migration_parent"
            }
            $newLines += @(
                '# Route misses through the parent instead of going direct, including'
                '# requests squid would normally classify as non-hierarchical, so the'
                '# warm old cache is actually used. connect-fail-limit (on the peer'
                '# above) marks a parent that stops answering DEAD after a few'
                '# failures, at which point squid falls back to direct rather than'
                '# 503-ing every miss; and -Start refuses to go live at all unless a'
                '# real miss serves through the parent (Confirm-MigrationParentRelay),'
                '# so a parent that handshakes but cannot relay never strands the child.'
                'prefer_direct off'
                'nonhierarchical_direct off'
            )
            Install-MigrationDropIn -Vm $new -Content (($newLines -join "`n") + "`n")
            $deployedNew = $true
            $newParse = Test-SquidConfig -Vm $new
            if (-not $newParse.success) {
                throw "new cache: squid -k parse rejected the migration drop-in; rolling back both VMs. Parse output: $($newParse.output)"
            }
            Invoke-SquidReconfigure -Vm $new
            Write-Ok "new cache: parent link configured ($(if ($tlsMode) { "tls :$script:TlsPeerPort" } else { 'plain :3128' }))"

            # Fail-closed before declaring the hierarchy live: a parent that
            # handshakes but cannot relay a miss would 503 every guest cache-miss.
            # A throw here lands in the rollback below, leaving both VMs as found.
            Confirm-MigrationParentRelay -Vm $new -TlsMode:$tlsMode
        } catch {
            # Leave both VMs exactly as found -- a half-built hierarchy is
            # worse than none. Rollback is best-effort; the original error
            # stays the one that surfaces.
            if ($deployedNew) {
                if (Restore-MigrationDropIn -Vm $new -PriorBase64 $priorNew) {
                    try { Invoke-SquidReconfigure -Vm $new } catch { Write-Warning "new cache: rollback reconfigure failed: $($_.Exception.Message)" }
                }
            }
            if ($deployedOld) {
                if (Restore-MigrationDropIn -Vm $old -PriorBase64 $priorOld) {
                    try { Invoke-SquidReconfigure -Vm $old } catch { Write-Warning "old cache: rollback reconfigure failed: $($_.Exception.Message)" }
                }
            }
            throw
        }

        # End-to-end miss-through-parent on both the plain and ssl-bump paths was
        # already proven fatally inside the try above (Confirm-MigrationParentRelay);
        # the remaining probe is informational and warn-only.
        if ($script:NewAclIp) {
            $logProbe = Invoke-VmRoot -Vm $old -Command "tail -n 400 /var/log/squid/access.log 2>/dev/null | grep -Fc '$script:NewAclIp' || true" -TimeoutSeconds 45
            $hits = 0
            [void][int]::TryParse($logProbe.output.Trim(), [ref]$hits)
            if ($hits -gt 0) {
                Write-Ok "old cache access.log already shows $hits request(s) from the new cache -- hierarchy confirmed live"
            } else {
                Write-Note 'no requests from the new cache in the old access.log yet; it fills as soon as clients use the new cache (warn only)'
            }
        }

        @(
            ''
            '== Cache warm-up hierarchy is LIVE =='
            "   client -> new cache ($NewAddress) -> miss -> old cache ($OldAddress) -> hit or origin"
            ''
            'Next steps -- go to the CLIENTS and point them at the new cache VM:'
            '  1. Machines using the yuruna harness: update vmStart.cachingProxyIP'
            "     in test/test.config.yml (or the status page's Edit config) to"
            "     $NewAddress -- it is probed FIRST at cycle start, and while the"
            '     old cache is still up a stale value there keeps winning. Only'
            '     hosts with an empty config value can switch via the env var:'
            "       Windows:      `$Env:YURUNA_CACHING_PROXY_IP = '$NewAddress'"
            "       macOS/Linux:  export YURUNA_CACHING_PROXY_IP=$NewAddress"
            '  2. Anything wired by hand (DNS names, DHCP options, WPAD, apt proxy'
            "     files): repoint ${OldAddress}:3128 -> ${NewAddress}:3128 and"
            "     ${OldAddress}:3129 -> ${NewAddress}:3129."
            '  3. Validate from a client machine:'
            "       pwsh test/Test-CachingProxy.ps1 -CacheIp $NewAddress"
            '  4. Watch the old cache drain (its hit rate decays over a few days):'
            "       ssh $OldUser@$OldAddress   then:   sudo tail -f /var/log/squid/access.log"
            '  5. When old-cache traffic is negligible, finish the migration:'
            "       pwsh test/Move-CachingProxy.ps1 -End -OldAddress $OldAddress -NewAddress $NewAddress"
            ''
            'Full guide: https://yuruna.link/caching-proxy-migration'
        ) | Write-Output
    }

    if ($End) {
        Write-Output "== Move-CachingProxy: END copy cycle ($OldAddress -> $NewAddress) =="

        # New side first: once the child forgets the parent, the old cache
        # has no remaining consumer and deactivating it is safe.
        Connect-VmSession -Vm $new
        $priorNew = Get-MigrationDropIn -Vm $new
        if ($null -ne $priorNew) {
            Restore-MigrationDropIn -Vm $new -PriorBase64 $null | Out-Null
            $newParse = Test-SquidConfig -Vm $new
            if (-not $newParse.success) {
                # The parse failure cannot come from the file we just removed;
                # put it back so the VM is exactly as found, and surface the
                # independent config problem instead of reconfiguring into it.
                Restore-MigrationDropIn -Vm $new -PriorBase64 $priorNew | Out-Null
                throw "new cache: squid -k parse fails even after removing the migration drop-in -- its config is broken independently of this migration. Fix that first. Parse output: $($newParse.output)"
            }
            Invoke-SquidReconfigure -Vm $new
            if (Wait-RemotePortListening -Vm $new -Port 3128) {
                Write-Ok 'new cache: migration drop-in removed; squid reconfigured and serving :3128 standalone'
            } else {
                Write-Warning 'new cache: :3128 not listening after reconfigure -- check sudo systemctl status squid on the new VM.'
            }
        } else {
            Write-Note 'new cache: no migration drop-in present (already detached)'
        }
        $directProbe = Invoke-VmSsh -Vm $new -Command "curl -s -m 25 -o /dev/null -w '%{http_code}' -x http://127.0.0.1:3128 http://archive.ubuntu.com/ubuntu/dists/noble/Release" -TimeoutSeconds 60
        $directCode = $directProbe.output.Trim()
        if ($directCode -match '^[23][0-9][0-9]$') {
            Write-Ok "new cache fetches direct: probe returned $directCode"
        } else {
            Write-Warning "direct-fetch probe through the new cache returned '$directCode' (expected 2xx/3xx). (warn only)"
        }

        # Old side: best-effort. An unreachable old VM usually means it was
        # already powered off -- that must not block detaching the new cache.
        $oldDeactivated = $false
        try {
            Connect-VmSession -Vm $old
            Restore-MigrationDropIn -Vm $old -PriorBase64 $null | Out-Null
            $disable = Invoke-VmRoot -Vm $old -Command 'systemctl disable --now squid' -TimeoutSeconds 90
            if (-not $disable.success) {
                throw "old cache: systemctl disable --now squid failed: $($disable.output)"
            }
            $status = Invoke-VmRoot -Vm $old -Command 'systemctl is-active squid >/dev/null 2>&1 && echo squid=active || echo squid=stopped; systemctl is-enabled squid >/dev/null 2>&1 && echo squidboot=enabled || echo squidboot=disabled' -TimeoutSeconds 45
            if ($status.output -match 'squid=stopped' -and $status.output -match 'squidboot=disabled') {
                Write-Ok 'old cache: squid stopped and disabled -- the VM is ready to power off'
                $oldDeactivated = $true
            } else {
                Write-Warning "old cache: squid state after disable is unexpected: $($status.output)"
            }
        } catch {
            Write-Warning "old cache at $OldAddress could not be deactivated ($($_.Exception.Message)). If the VM is already powered off, nothing is left to do there; otherwise re-run -End once it is reachable."
        }

        @(
            ''
            '== Migration COMPLETE -- the old cache is out of the path =='
            "   The new cache ($NewAddress) now serves and fetches on its own."
            $(if ($oldDeactivated) { "   squid on the old VM ($OldAddress) is stopped and disabled (survives reboots)." }
              else { "   NOTE: the old VM ($OldAddress) was NOT confirmed deactivated -- see warning above." })
            ''
            'Next steps -- go to the OLD cache VM host and deactivate the VM'
            '(default VM name: yuruna-caching-proxy):'
            '  1. Power the VM off on its host:'
            '       Hyper-V:     Stop-VM -Name yuruna-caching-proxy'
            '       Ubuntu KVM:  virsh shutdown yuruna-caching-proxy'
            '       macOS UTM:   utmctl stop yuruna-caching-proxy'
            '  2. On that same host, tear down host-side plumbing that pointed at'
            '     it (port forwards, host-proxy promotion):'
            '       pwsh test/Stop-CachingProxy.ps1'
            '  3. Keep the powered-off VM for a grace period in case of rollback'
            '     (boot it, then: sudo systemctl enable --now squid). Delete the'
            '     VM and its disk once the new cache has proven itself.'
            ''
            'Full guide: https://yuruna.link/caching-proxy-migration'
        ) | Where-Object { $null -ne $_ } | Write-Output
    }
} catch {
    # -ErrorAction Continue: under the strict preference above, a bare
    # Write-Error would itself terminate and skip the clean exit-code path.
    Write-Error "Move-CachingProxy aborted: $($_.Exception.Message)" -ErrorAction Continue
    $failed = $true
} finally {
    Clear-AskpassHelper -Helper $oldHelper
    Clear-AskpassHelper -Helper $newHelper
}

if ($failed) { exit 1 }
exit 0
