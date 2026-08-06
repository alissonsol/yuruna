<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456729
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

# --- REGION: https://yuruna.link/memory#why-port-ownership-diagnostics-live-in-one-module
# Shared port-ownership diagnostics: the Windows HTTP.sys / netsh vs Unix lsof
# dispatch, and the classification Start-StatusService refuses to start on.
# Each function's contract is in its own .SYNOPSIS block below.

# Test-YurunaCanPrompt: the one predicate for "can a question reach a person",
# which decides whether the elevated takeover below may ask for a password or
# must report instead. -Global -Force matches every other consumer of this
# module (a nested non-global import evicts a caller's view of it).
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking

function Get-PortListenerPid {
    <#
    .SYNOPSIS
        PID(s) holding $Port. Returns @() when no holder is detected
        OR the OS does not expose ownership (netsh / lsof missing or
        access-restricted).
    .PARAMETER Diagnostic
        Caller passes [ref]$diag to collect a human-readable description
        of what was attempted when no PID is resolved, so the "unavailable
        or empty" warning at the call site can point the operator at the
        real cause (missing lsof, an access-restricted owner, a non-LISTEN
        holder, etc.).
    #>
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [ref]$Diagnostic
    )

    if ($PSVersionTable.Platform -eq 'Unix') {
        # lsof is standard on macOS and most Linux.
        if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) {
            if ($Diagnostic) { $Diagnostic.Value = 'lsof not found in PATH' }
            return @()
        }

        # Primary: LISTEN-only, PID-only output. Capture stderr so that a
        # permission failure or an lsof-internal error is visible rather than
        # silently collapsed into "empty".
        $errFile = [System.IO.Path]::GetTempFileName()
        try {
            $listenOut = & lsof -nP -iTCP:$Port -sTCP:LISTEN -Fp 2>$errFile
        } finally {
            $lsofStderr = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) -as [string]
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        }
        $listenPids = @($listenOut | Where-Object { $_ -like 'p*' } | ForEach-Object { [int]$_.Substring(1) } | Select-Object -Unique)
        if ($listenPids.Count) { return $listenPids }

        # Fallback: any TCP state on this port. macOS lsof without sudo can
        # miss listeners owned by other users, and a half-closed socket that
        # still holds :$Port shows up under states other than LISTEN.
        $anyOut  = & lsof -nP -iTCP:$Port -Fp 2>$null
        $anyPids = @($anyOut | Where-Object { $_ -like 'p*' } | ForEach-Object { [int]$_.Substring(1) } | Select-Object -Unique)
        if ($anyPids.Count) {
            if ($Diagnostic) {
                $Diagnostic.Value = "lsof -sTCP:LISTEN returned no pids, but lsof (any state) found pid(s) $($anyPids -join ','); treating as holder"
            }
            return $anyPids
        }

        if ($Diagnostic) {
            $trimErr = if ($lsofStderr) { $lsofStderr.Trim() } else { '' }
            $parts   = @("lsof -nP -iTCP:$Port -sTCP:LISTEN -> empty", "lsof -nP -iTCP:$Port (any state) -> empty")
            if ($trimErr) { $parts += "lsof stderr: $trimErr" }
            $parts += "holder may be owned by another user; retry with: sudo lsof -nP -iTCP:$Port"
            $Diagnostic.Value = $parts -join '; '
        }
        return @()
    }

    # Windows: HTTP.sys hides the real owner from Get-NetTCPConnection
    # (OwningProcess reports 4, the System kernel account), so netsh is
    # the only reliable source for url-group -> PID mapping. Output is
    # grouped per "Request queue name:" block; within a block,
    # `Processes: ID: <pid>` lists user-mode PIDs and `Registered URLs:`
    # lists URL prefixes. Flush a block's PIDs to the result set when
    # its URL list contains :$Port. The regex matches both
    # "HTTP://*:8080/" and the rarer "HTTP://127.0.0.1:8080:127.0.0.1/"
    # host-binding form.
    $raw = @(netsh http show servicestate 2>$null)
    if (-not $raw) {
        if ($Diagnostic) { $Diagnostic.Value = 'netsh http show servicestate returned no output' }
        return @()
    }

    $pids           = [System.Collections.Generic.HashSet[int]]::new()
    $blockPids      = [System.Collections.Generic.List[int]]::new()
    $blockPortMatch = $false
    foreach ($line in $raw) {
        if ($line -match '^\s*Request queue name:') {
            if ($blockPortMatch) { foreach ($p in $blockPids) { [void]$pids.Add($p) } }
            $blockPids.Clear(); $blockPortMatch = $false
        } elseif ($line -match '^\s*ID:\s*(\d+)\b') {
            [void]$blockPids.Add([int]$Matches[1])
        } elseif ($line -match "^\s*HTTPS?://[^\s]*:${Port}(?:[:/]|$)") {
            $blockPortMatch = $true
        }
    }
    if ($blockPortMatch) { foreach ($p in $blockPids) { [void]$pids.Add($p) } }
    if ($pids.Count -eq 0 -and $Diagnostic) {
        $Diagnostic.Value = "netsh http show servicestate: no url-group block registered :$Port"
    }
    return @($pids)
}

function Test-PortListenerFree {
    <#
    .SYNOPSIS
        $true when THIS process can bind http://*:$Port/ -- the OS-agnostic
        proof that the detached status service will be able to start.
    .DESCRIPTION
        The single source of truth across host environments. HttpListener
        binds a real reservation, so a holder owned by ANOTHER USER (which
        lsof/netsh cannot reveal without elevation) still makes this return
        $false. -BudgetMs polls the bind until it succeeds or the budget
        elapses: on Windows HTTP.sys releases a URL reservation asynchronously
        after a Stop-Process'd pwsh exits, so a GC delay must not look like an
        unresolvable conflict. BudgetMs 0 is a single immediate attempt.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [int]$BudgetMs = 0,
        [int]$PollMs = 250
    )
    # Drive off a wall-clock deadline, not an iteration count: each bind attempt itself takes
    # time, so counting iterations would let the real elapsed time overrun BudgetMs several-fold.
    $deadline = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(0, $BudgetMs))
    while ($true) {
        $probe = [System.Net.HttpListener]::new()
        $probe.Prefixes.Add("http://*:$Port/")
        try {
            $probe.Start(); $probe.Stop(); $probe.Close()
            return $true
        } catch {
            try { $probe.Close() } catch { Write-Debug $_ }
        }
        # BudgetMs 0 => a single immediate attempt; otherwise stop once the next poll would
        # cross the deadline.
        if ([DateTime]::UtcNow.AddMilliseconds($PollMs) -ge $deadline) { break }
        Start-Sleep -Milliseconds $PollMs
    }
    return $false
}

function Test-PortPrivilegeBlocked {
    <#
    .SYNOPSIS
        $true when the port is FREE but this process may not reserve the wildcard
        prefix Test-PortListenerFree probes with.
    .DESCRIPTION
        A failed wildcard bind has two completely different causes, and treating
        them alike produces a confidently wrong diagnosis. `http://*:<port>/` is
        an HTTP.sys URL reservation on Windows, and reserving one needs elevation
        (or a standing `netsh http add urlacl`). So an ordinary shell is refused
        the bind whether or not anything is actually listening -- and reporting
        "the port is in use, stop the other owner" to someone whose port is empty
        sends them hunting a holder that does not exist.

        WINDOWS ONLY, and the platform gate is load-bearing rather than a
        shortcut. A URL reservation is an HTTP.sys concept: on macOS and Linux
        the managed HttpListener is an ordinary socket, and binding a port above
        1024 needs no privilege at all -- so on those platforms a refused
        wildcard bind is ALWAYS a real holder, never a privilege problem, and
        answering $true there can only produce a wrong diagnosis.

        The localhost cross-check cannot substitute for that gate, because it
        does not mean the same thing on BSD. With SO_REUSEADDR set (which the
        managed listener sets), macOS lets a bind to a SPECIFIC address succeed
        while another process holds the WILDCARD on the same port. So a
        status service left behind by a different user -- the `sudo` run whose
        root-owned listener is also invisible to an unprivileged `lsof` -- makes
        the wildcard bind fail and the localhost bind succeed: exactly the
        signature this function was reading as "free, but unprivileged". The
        caller then printed HTTP.sys and `netsh` remedies on a Mac and refused
        to start, while the true cause (another user holds the port, retry the
        diagnostic with sudo) is what the caller's NEXT branch already says.

        On Windows the two cases are separated by the HttpListenerException
        error code: 183 (ERROR_ALREADY_EXISTS, "conflicts with an existing
        registration") when a registration genuinely holds the port, and 5
        (ERROR_ACCESS_DENIED) when the caller simply may not reserve it. The
        localhost probe stays as a second signal there, where a specific-address
        bind does not coexist with a wildcard holder.

        Deliberately NOT folded into Test-PortListenerFree: that function answers
        "can the status service bind here", and the answer stays $false in this
        case -- the server binds the same wildcard prefix and fails identically.
        Only the explanation differs, so only the explanation is computed here.
    .OUTPUTS
        [bool] $true only when the port is provably free AND the wildcard
        reservation was refused for want of privilege. Always $false off Windows.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)

    if (-not $IsWindows) { return $false }

    $code  = 0
    $probe = [System.Net.HttpListener]::new()
    try {
        $probe.Prefixes.Add("http://*:$Port/")
        $probe.Start()
        $probe.Stop()
        return $false   # the wildcard bound: nothing to explain
    } catch [System.Net.HttpListenerException] {
        $code = $_.Exception.ErrorCode
    } catch {
        return $false
    } finally {
        try { $probe.Close() } catch { Write-Debug $_ }
    }

    # ERROR_ALREADY_EXISTS: a real registration holds the port. Not a privilege
    # problem, and the localhost probe below must not get a chance to soften it.
    if ($code -eq 183) { return $false }

    $local = [System.Net.HttpListener]::new()
    try {
        $local.Prefixes.Add("http://localhost:$Port/")
        $local.Start()
        $local.Stop()
        return $true    # port is empty; the wildcard refusal was about privilege
    } catch {
        return $false   # something holds it after all
    } finally {
        try { $local.Close() } catch { Write-Debug $_ }
    }
}

function Get-ProcessOwnerName {
    <#
    .SYNOPSIS
        Best-effort OS user that owns process $Id. Empty string when it cannot
        be determined (process gone, or the query is access-restricted).
    .DESCRIPTION
        Used only to (a) refuse to commandeer a status-port listener owned by a
        DIFFERENT user and (b) name that owner in the conflict banner. Ownership
        only ever blocks a kill, never authorizes one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Id)
    try {
        if ($PSVersionTable.Platform -eq 'Unix') {
            # -First 1 on the COMMAND, not just on its output: a host with both
            # /usr/bin/ps and /bin/ps returns two Application matches, and
            # $psCmd.Source then stringifies to "/usr/bin/ps /bin/ps" -- a path
            # that does not exist, so every owner silently came back empty.
            $psCmd = Get-Command ps -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($psCmd) {
                $u = & $psCmd.Source -o user= -p $Id 2>$null | Select-Object -First 1
                if ($u) { return ([string]$u).Trim() }
            }
            return ''
        }
        # Windows: the owner is not exposed on Get-Process; Win32_Process
        # GetOwner is the reliable source.
        $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -ErrorAction SilentlyContinue
        if ($cim) {
            $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction SilentlyContinue
            if ($owner -and $owner.User) {
                if ($owner.Domain) { return "$($owner.Domain)\$($owner.User)" }
                return [string]$owner.User
            }
        }
        return ''
    } catch {
        Write-Verbose "Get-ProcessOwnerName($Id): $($_.Exception.Message)"
        return ''
    }
}

# Internal: the OS user this process runs as. Not exported -- only the
# ownership comparison below consumes it.
function Get-CurrentUserName {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($candidate in @($env:USER, $env:USERNAME)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    try { return [System.Environment]::UserName } catch { return '' }
}

# Internal: $true only when $Owner is provably the current user. An unknown
# ($null/empty) owner returns $false so an unidentified holder is never treated
# as ours.
function Test-OwnedByCurrentUser {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Owner)
    if ([string]::IsNullOrWhiteSpace($Owner)) { return $false }
    $me   = Get-CurrentUserName
    $leaf = ($Owner -split '[\\/]')[-1]
    return ($leaf -and $me -and $leaf.Equals($me, [System.StringComparison]::OrdinalIgnoreCase))
}

function Get-PortHolderServiceInfo {
    <#
    .SYNOPSIS
        Best-effort identity of a Yuruna status service already answering on
        $Port -- the "go deeper" probe so the conflict banner can name WHICH
        host/service (and thus, usually, which user) already owns the port.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][int]$Port)
    $empty = @{ IsYuruna = $false; Hostname = ''; Host = ''; HostId = '' }
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Port/runtime/status.json" -TimeoutSec 2 `
                    -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
        $doc = $resp.Content | ConvertFrom-Json -ErrorAction Stop
        if ($doc) {
            $names = @($doc.PSObject.Properties.Name)
            # Require the field COMBINATION a Yuruna status.json always emits, not
            # any single common key: schemaVersion + overallStatus together are a
            # Yuruna signature present in EVERY served doc (both live per-cycle docs
            # and the bootstrap status.json.template the server answers with before
            # the first cycle), whereas 'host' / 'hostname' / 'schemaVersion' alone
            # appear in plenty of unrelated JSON and would misclassify a foreign
            # service on this port as ours. hostId is deliberately NOT required: the
            # bootstrap template omits it, so requiring it would drop the owner name
            # from the conflict banner for a peer that has just launched.
            $isYurunaDoc = ($names -contains 'schemaVersion') -and
                           ($names -contains 'overallStatus')
            if ($isYurunaDoc) {
                return @{
                    IsYuruna = $true
                    Hostname = [string]$doc.hostname
                    Host     = [string]$doc.host
                    HostId   = [string]$doc.hostId
                }
            }
        }
    } catch {
        Write-Verbose "Get-PortHolderServiceInfo($Port): $($_.Exception.Message)"
    }
    return $empty
}

# Internal: PIDs of every ancestor of $ProcessId, walked through ps(1). The
# elevated takeover below must never stop the shell that launched this run --
# with root behind the kill there is nothing left to refuse it, and the symptom
# (the operator's terminal dies mid-bring-up) reads as a crash, not as a
# deliberate act. Bounded hop count: a ppid cycle is not possible on a healthy
# system, but a bounded walk cannot hang on an unhealthy one.
function Get-ProcessAncestorId {
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param([Parameter(Mandatory)][int]$ProcessId)
    $ids = [System.Collections.Generic.List[int]]::new()
    if ($PSVersionTable.Platform -ne 'Unix') {
        # 'ps' is an ALIAS for Get-Process on Windows, so the ps(1) argv below
        # would bind as cmdlet parameters and fail. .Parent walks the same chain.
        $current = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        for ($hop = 0; $hop -lt 32; $hop++) {
            try { $current = $current.Parent } catch { break }
            if (-not $current) { break }
            $ids.Add([int]$current.Id)
        }
        return @($ids)
    }
    # Resolved as an Application so the Windows alias can never be reached even
    # if this branch is entered on a host that reports itself oddly, and -First 1
    # because a host carrying both /usr/bin/ps and /bin/ps returns two matches
    # whose joined .Source is not a path.
    $psCmd = Get-Command ps -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $psCmd) { return @() }
    $current = $ProcessId
    for ($hop = 0; $hop -lt 32; $hop++) {
        $parent = ''
        try { $parent = ((& $psCmd.Source -o ppid= -p $current 2>$null) | Out-String).Trim() } catch { break }
        if ($parent -notmatch '^\d+$') { break }
        $parentId = [int]$parent
        # 1 (init/launchd) is protected unconditionally by the caller, and a
        # parent of 0 means the walk ran off the top of the tree.
        if ($parentId -le 1) { break }
        $ids.Add($parentId)
        $current = $parentId
    }
    return @($ids)
}

# Internal: "PID 1234 (root pwsh)" -- who is about to be stopped, in the words
# the operator can check with ps themselves. An elevated kill the operator did
# not ask for by name is indistinguishable from the harness misbehaving, so the
# takeover names every target before it acts.
function Get-PortHolderDescription {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$ProcessId)
    $detail = ''
    if ($PSVersionTable.Platform -eq 'Unix') {
        # Application, not the bare name: 'ps' is a Get-Process alias on Windows.
        # -First 1: two matches (/usr/bin/ps, /bin/ps) join into a bogus path.
        $psCmd = Get-Command ps -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($psCmd) {
            try { $detail = ((& $psCmd.Source -o user=,comm= -p $ProcessId 2>$null) | Out-String).Trim() -replace '\s+', ' ' } catch {
                Write-Verbose "Get-PortHolderDescription($ProcessId): ps failed"
            }
        }
    } else {
        $proc  = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        $owner = Get-ProcessOwnerName -Id $ProcessId
        if ($proc) { $detail = (@($owner, $proc.ProcessName) | Where-Object { $_ }) -join ' ' }
    }
    if ($detail) { return "PID $ProcessId ($detail)" }
    return "PID $ProcessId"
}

# Internal: a live sudo authorization for the takeover, or $false.
#
# sudo reads its password from /dev/tty, NOT from stdin -- so a prompt raised
# from a run whose output is captured (every service bring-up called through
# Start-YurunaStatusServiceIfEnabled, every runner cycle) prints into a log
# nobody is watching and then waits for a keystroke nobody knows to press. The
# probe is therefore always `-n`, and the one place that may actually ask is
# gated on Test-YurunaCanPrompt: a person who can both SEE the question and
# ANSWER it. Everywhere else this returns $false and the caller reports instead.
function Request-PortReclaimElevation {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)
    # Pinned locally: a cold sudo timestamp EXITS NON-ZERO, and that exit code is
    # the answer this function returns. Under the caller's $ErrorActionPreference
    # = 'Stop' the native-command preference would turn it into a throw, so the
    # probe written to keep a bring-up moving would abort it instead.
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return $false }
    & sudo -n true 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    if (-not (Test-YurunaCanPrompt)) { return $false }
    Write-Information ("Port $Port is held by a process this account cannot stop. Freeing it needs root " +
                       "(you may be prompted for your password)...") -InformationAction Continue
    & sudo -v
    & sudo -n true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Internal: holders of $Port as ROOT sees them. An unprivileged lsof cannot see
# sockets owned by other users, which is exactly the case that brings a caller
# here -- so the same query is re-run with the authorization already obtained.
function Get-ElevatedPortListenerPid {
    [CmdletBinding()]
    [OutputType([int[]], [object[]])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [switch]$AsRoot
    )
    if (-not (Get-Command lsof -ErrorAction SilentlyContinue)) { return @() }
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($stateArgs in @(@('-sTCP:LISTEN'), @())) {
        # LISTEN first, then any TCP state: a half-closed socket still holds the
        # port and still has to go, but it must not be the first thing matched.
        $lsofArgs = @('-nP', "-iTCP:$Port") + $stateArgs + @('-Fp')
        $out = if ($AsRoot) { & lsof @lsofArgs 2>$null } else { & sudo -n lsof @lsofArgs 2>$null }
        $found = @($out | Where-Object { $_ -like 'p*' } | ForEach-Object { [int]$_.Substring(1) } | Select-Object -Unique)
        if ($found.Count) { return $found }
    }
    return @()
}

# Internal: SIGTERM/SIGKILL the given PIDs, with root behind it when this
# process is not already root.
function Stop-ProcessWithElevation {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'The single ShouldProcess gate for the whole takeover lives in Invoke-PortTakeover, its only caller. A second gate here would ask the operator again per signal (TERM, then KILL) about a decision already made.')]
    param(
        [Parameter(Mandatory)][int[]]$ProcessId,
        [Parameter(Mandatory)][ValidateSet('TERM', 'KILL')][string]$Signal,
        [switch]$AsRoot
    )
    $PSNativeCommandUseErrorActionPreference = $false
    if ($AsRoot) { & kill "-$Signal" @ProcessId 2>$null | Out-Null }
    else         { & sudo -n kill "-$Signal" @ProcessId 2>$null | Out-Null }
}

function Invoke-PortTakeover {
    <#
    .SYNOPSIS
        Free $Port by stopping whatever holds it -- escalating to root only for
        the holder ordinary privileges cannot reach.
    .DESCRIPTION
        The reclaim inside Resolve-PortOrphan handles exactly one shape: a
        detached pwsh THIS user owns. Everything else it can only describe --
        the stale non-pwsh listener left by some other tool, and the server an
        earlier `sudo` run of this same harness left as ROOT, invisible to this
        user's lsof and immune to this user's Stop-Process. Describing those
        hands the operator a chore the harness has everything it needs to
        finish: it knows the port, it can find the holder as root, and the
        bring-up that calls it is already asking for sudo. So it finishes it.

        TWO PHASES, cheapest first.
          1. Ordinary privileges: Stop-Process every visible holder. This alone
             clears the same-user cases and asks for NO elevation, which is what
             keeps a plain `Start-StatusService.ps1` from turning into a
             password prompt.
          2. Elevated: only if the port is STILL held (or nothing was visible at
             all, the signature of a root-owned listener). Re-runs the lookup as
             root -- which is the only way to see that holder -- and signals it
             with sudo. SIGTERM first, SIGKILL only if the port is still held,
             so a status service that traps the signal closes its listener and
             releases its runtime files cleanly.

        WHAT IS NEVER STOPPED: pid 1, this process, and every ancestor of this
        process. With root behind the kill there is nothing left to refuse it,
        and stopping the shell that launched the run reads as a crash. Every
        other holder is fair game and is NAMED (user and command) as it goes,
        because a kill nobody can account for afterwards is worse than the
        conflict it resolved.

        Phase 2 is Unix-only: sudo has no meaning on Windows, where the
        equivalent is an elevated shell or a standing `netsh http add urlacl`,
        which the PrivilegeRequired banner already spells out. Phase 1 runs
        everywhere.
    .PARAMETER KnownPid
        Holders the caller already resolved, unioned with what each phase finds
        -- a holder visible to the caller must not be missed because a later
        lookup raced its exit.
    .PARAMETER Enabled
        Bound from the caller's -Elevate. $false makes this a no-op returning
        Attempted=$false, so the decision to take the port lives at the call site.
    .OUTPUTS
        [hashtable] @{
            Attempted = [bool]    # a takeover was actually tried
            Freed     = [bool]    # the port is bindable now
            Stopped   = [int[]]   # PIDs signalled
            Detail    = [string]  # why it did not free the port, for the banner
        }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [int[]]$KnownPid = @(),
        [switch]$Enabled
    )
    $result = @{ Attempted = $false; Freed = $false; Stopped = @(); Detail = '' }
    if (-not $Enabled) { return $result }
    $result.Attempted = $true

    # pid 1, this process, and its ancestors are off limits in BOTH phases.
    $protected = @(1, $PID) + @(Get-ProcessAncestorId -ProcessId $PID)
    $stopped   = [System.Collections.Generic.List[int]]::new()

    # Chooses targets, announces them, and stops them with $StopAction. Shared by
    # both phases so the protection filter and the "who is being stopped" line
    # cannot drift between the unprivileged and the elevated path.
    $stopHolders = {
        param([int[]]$Candidate, [string]$Why, [scriptblock]$StopAction)
        $targets = @($Candidate | Select-Object -Unique | Where-Object { $protected -notcontains $_ })
        if (-not $targets.Count) { return @() }
        foreach ($target in $targets) {
            Write-Information "Port $Port is held by $(Get-PortHolderDescription -ProcessId $target) -- stopping it$Why so the status service can bind." -InformationAction Continue
        }
        if (-not $PSCmdlet.ShouldProcess("PID(s) $($targets -join ', ')", "Stop port $Port holder")) { return @() }
        & $StopAction $targets
        foreach ($target in $targets) { if (-not $stopped.Contains($target)) { $stopped.Add($target) } }
        return $targets
    }

    # --- Phase 1: ordinary privileges.
    $visible = @($KnownPid)
    if (-not $visible.Count) { $visible = @(Get-PortListenerPid -Port $Port) }
    $phase1 = @(& $stopHolders $visible '' {
        param([int[]]$Target)
        foreach ($t in $Target) { Stop-Process -Id $t -Force -ErrorAction SilentlyContinue }
    })
    if ($phase1.Count) {
        $result.Stopped = @($stopped)
        if (Test-PortListenerFree -Port $Port -BudgetMs 5000) {
            $result.Freed = $true
            return $result
        }
    }

    # --- Phase 2: elevated. Reached when phase 1 saw nothing (a holder hidden
    # from this user's lsof) or could not stop what it saw (another user's).
    if ($IsWindows) {
        $result.Detail = 'no elevated takeover on Windows -- run the shell as Administrator, or add a urlacl for this port'
        return $result
    }
    $PSNativeCommandUseErrorActionPreference = $false
    $isRoot = $false
    try { $isRoot = ("$(& '/usr/bin/id' -u 2>$null)".Trim() -eq '0') } catch {
        Write-Verbose 'Invoke-PortTakeover: id unavailable -- assuming not root.'
    }
    if (-not $isRoot -and -not (Request-PortReclaimElevation -Port $Port)) {
        $result.Detail = "the holder is out of this account's reach and elevation was unavailable -- sudo has no live authorization and this run cannot ask for one (run 'sudo -v', then re-run)"
        return $result
    }

    $rootVisible = @(Get-ElevatedPortListenerPid -Port $Port -AsRoot:$isRoot) + $visible
    $phase2 = @(& $stopHolders $rootVisible ' with elevation' {
        param([int[]]$Target)
        Stop-ProcessWithElevation -ProcessId $Target -Signal TERM -AsRoot:$isRoot
    })
    $result.Stopped = @($stopped)
    if (-not $phase2.Count) {
        $result.Detail = 'even a root-level lsof found no holder that may be stopped for this port'
        return $result
    }
    if (Test-PortListenerFree -Port $Port -BudgetMs 5000) {
        $result.Freed = $true
        return $result
    }
    Write-Information "Port $Port still held after SIGTERM -- sending SIGKILL to $($phase2 -join ', ')." -InformationAction Continue
    Stop-ProcessWithElevation -ProcessId $phase2 -Signal KILL -AsRoot:$isRoot
    if (Test-PortListenerFree -Port $Port -BudgetMs 3000) {
        $result.Freed = $true
        return $result
    }
    $result.Detail = "stopped holder(s) $($phase2 -join ', ') with elevation, but the port is still not bindable"
    return $result
}

function Resolve-PortOrphan {
    <#
    .SYNOPSIS
        Try to free $Port for THIS user's status service, distinguishing a
        reclaimable orphan (our own detached pwsh holder) from an unrecoverable
        conflict (port owned by another user, a non-pwsh process, or a holder
        this user cannot even see). Returns a structured result; never exits or
        throws -- the caller decides how to refuse.
    .DESCRIPTION
        Returns a classification rather than calling `exit`: Start-StatusService.ps1
        runs under a call-operator invocation (`& $StartScript` from the shared
        gate), and `exit` inside a `&`-invoked script only sets $LASTEXITCODE in
        the parent -- it does NOT abort it. A conflict reported that way would let
        the parent cycle run on with the live dashboard and breakpoint controls
        silently absent. Returning the classification lets the caller throw a
        tagged, propagating error that actually aborts the cycle.
    .OUTPUTS
        [hashtable] @{
            Status  = 'Free' | 'Recovered' | 'Conflict' | 'PrivilegeRequired'
            Port    = [int]
            Pids    = [int[]]
            Owner   = [string]    # owner of a foreign holder, when known
            Service = [hashtable] # Get-PortHolderServiceInfo result, when held
            Message = [string]    # operator banner; set on Conflict and PrivilegeRequired
        }
        'Free'      : the port is bindable now (nothing held it, or a transient
                      HTTP.sys reservation cleared within budget).
        'Recovered' : an orphan pwsh THIS user owns was stopped; port now free.
        'Conflict'  : the port is held by something this user could not take
                      over -- including, when -Elevate was passed, after the
                      elevated attempt. The cycle must refuse to start.
        'PrivilegeRequired' : WINDOWS ONLY -- the port is EMPTY, but this process may not reserve
                      the wildcard prefix (elevation, or a standing urlacl). The
                      cycle must still refuse -- the status service binds the same
                      prefix and would fail identically -- but there is no holder
                      to hunt, so it is reported apart from 'Conflict' rather than
                      being described as a port that is "in use".
    .PARAMETER Elevate
        Before refusing, try once to free the port WITH ELEVATION
        (Invoke-PortTakeover): find the holder as root and stop it. The
        status service passes this, because the holder it cannot reclaim
        unprivileged is nearly always a root-owned server from an earlier `sudo`
        run of this same harness -- an obstacle the harness put there itself,
        and one the operator gains nothing by clearing by hand. Off by default,
        so a caller that only wants a classification never signals anything.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Function already declares SupportsShouldProcess; PSSA may flag the inner Stop-Process call site that we wrap in $PSCmdlet.ShouldProcess.')]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$PidFile,
        [switch]$Elevate
    )

    # HTTP.sys releases a URL reservation asynchronously after a Stop-Process'd
    # pwsh exits, so give the bind probe a 5 s budget before treating "cannot
    # bind" as a real conflict -- a GC delay must not look like a collision.
    if (Test-PortListenerFree -Port $Port -BudgetMs 5000) {
        return @{ Status = 'Free'; Port = $Port; Pids = @(); Owner = ''; Service = $null; Message = '' }
    }

    $diag       = ''
    $holderPids = @(Get-PortListenerPid -Port $Port -Diagnostic ([ref]$diag))
    $service    = Get-PortHolderServiceInfo -Port $Port

    # "Who owns it" clause, reused by every conflict message.
    $svcClause = ''
    if ($service.IsYuruna) {
        $who = @()
        if ($service.Hostname) { $who += "hostname '$($service.Hostname)'" }
        if ($service.Host)     { $who += "host '$($service.Host)'" }
        $suffix = if ($who.Count) { " ($($who -join ', '))" } else { '' }
        $svcClause = "A Yuruna status service is already answering on port $Port$suffix -- started by another checkout or user."
    }

    if (-not $holderPids.Count) {
        # Before concluding "held by a user we cannot see", rule out the other
        # reason a wildcard bind fails: not being allowed to make the reservation
        # at all. Both refuse to start -- the status service binds the same prefix
        # and would fail the same way -- but they send the operator to opposite
        # places, and the port-is-empty case has no holder to go looking for.
        if (Test-PortPrivilegeBlocked -Port $Port) {
            $lines = @(
                "Status-service port $Port is FREE, but this process may not reserve http://*:$Port/."
                "  That is an HTTP.sys URL reservation: making one needs elevation. Nothing is holding"
                "  the port -- this is a privilege problem, not a port conflict."
                "  Refusing to start: the status service binds the same wildcard prefix (so that guests"
                "  can reach it on the host's LAN IP, not just localhost) and would fail identically."
                "  Resolve by ONE of:"
                "    - run this shell as Administrator; or"
                "    - reserve the URL once, then rerun unelevated:"
                "        netsh http add urlacl url=http://*:$Port/ user=$env:USERDOMAIN\$env:USERNAME"
                "  Diagnostic: $diag"
            )
            return @{ Status = 'PrivilegeRequired'; Port = $Port; Pids = @(); Owner = ''; Service = $service; Message = ($lines -join [Environment]::NewLine) }
        }

        # The port is provably held (bind failed) but no PID is visible. On
        # macOS and Linux lsof without elevation cannot see sockets owned by
        # OTHER users, and on Windows HTTP.sys hides a foreign url-group -- so
        # this is the signature of a listener owned by a DIFFERENT USER, and in
        # practice most often by root, from an earlier sudo run of this harness.
        # That one is ours to clear, so take it over rather than describing it.
        $takeover = Invoke-PortTakeover -Port $Port -Enabled:$Elevate -Confirm:$false
        if ($takeover.Freed) {
            if ($PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
            return @{ Status = 'Recovered'; Port = $Port; Pids = $takeover.Stopped; Owner = ''; Service = $null; Message = '' }
        }
        # Still held: a bind failure with no reclaimable owner means this user
        # cannot host a status service here, and proceeding would run the cycle
        # blind (no dashboard, no breakpoint controls).
        $ownerLine = if ($svcClause) { "  $svcClause" }
                     else { "  The holder is owned by another user (its socket is hidden from lsof/netsh without elevation)." }
        $lines = @(
            "Status-service port $Port is in use but no owning PID is visible to this user."
            $ownerLine
            "  Refusing to start: a second status service cannot bind the same port, and running the"
            "  cycle without one hides the live dashboard / breakpoint controls (a hard-to-debug state)."
            $(if ($takeover.Attempted) { "  Elevated takeover was tried first and did not free it: $($takeover.Detail)" })
            $(if (-not $IsWindows) {
                "  Most often this is a status service left running as ROOT by an earlier sudo run of a" +
                [Environment]::NewLine +
                "  setup or runner script. Confirm and clear it with:" +
                [Environment]::NewLine +
                "        sudo lsof -nP -iTCP:$Port -sTCP:LISTEN      # names the root-owned holder" +
                [Environment]::NewLine +
                "        sudo pwsh test/Stop-StatusService.ps1       # stops it the way it was started"
            })
            "  Resolve by ONE of:"
            "    - stop the other owner's status service (it may belong to another user account); or"
            "    - give this checkout its own port in test/test.config.yml (statusService.port) and rerun."
            "  Diagnostic: $diag"
        ) | Where-Object { $null -ne $_ }
        return @{ Status = 'Conflict'; Port = $Port; Pids = @(); Owner = ''; Service = $service; Message = ($lines -join [Environment]::NewLine) }
    }

    # We have PID(s). Reclaim ONLY orphan pwsh holders THIS user owns; never touch
    # another user's process or a non-pwsh listener. Classify EVERY holder before
    # stopping any: a single pass that killed as it went would Stop-Process an owned
    # pwsh and THEN hit a foreign holder later in the list and return Conflict,
    # leaving partial state. Two passes make the decision order-independent -- if any
    # holder is unreclaimable, nothing is stopped.
    $reclaimable = @()
    foreach ($holderPid in $holderPids) {
        $proc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }   # exited since the OS query
        $owner     = Get-ProcessOwnerName -Id $holderPid
        $isPwsh    = $proc.ProcessName -match '^(pwsh|PowerShell|powershell)$'
        $ownedByUs = Test-OwnedByCurrentUser -Owner $owner

        if (-not $isPwsh -or ($owner -and -not $ownedByUs)) {
            # A holder this user may not stop. Under -Elevate the port is claimed
            # anyway, with the holder named on the way out: the caller asked for a
            # working service on this port, and half of that (a report naming a
            # PID the operator must go kill) is a chore, not an answer.
            $takeover = Invoke-PortTakeover -Port $Port -KnownPid $holderPids -Enabled:$Elevate -Confirm:$false
            if ($takeover.Freed) {
                if ($PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
                return @{ Status = 'Recovered'; Port = $Port; Pids = $takeover.Stopped; Owner = ''; Service = $null; Message = '' }
            }
            $ownerStr = if ($owner) { " owned by '$owner'" } else { '' }
            $whyLine  = if ($svcClause) { "  $svcClause" }
                        else { "  Refusing to commandeer a listener this harness does not own." }
            $lines = @(
                "Status-service port $Port is held by PID $holderPid ($($proc.ProcessName))$ownerStr."
                $whyLine
                $(if ($takeover.Attempted) { "  Elevated takeover was tried first and did not free it: $($takeover.Detail)" })
                "  Refusing to start so the cycle does not run without its status dashboard / breakpoint controls."
                "  Resolve by stopping that process (it may belong to another user), or set a different"
                "  statusService.port in test/test.config.yml and rerun."
            ) | Where-Object { $null -ne $_ }
            return @{ Status = 'Conflict'; Port = $Port; Pids = $holderPids; Owner = $owner; Service = $service; Message = ($lines -join [Environment]::NewLine) }
        }
        $reclaimable += [pscustomobject]@{ HolderPid = $holderPid; Proc = $proc }
    }

    # Every visible holder is a reclaimable orphan pwsh THIS user owns -> stop them.
    foreach ($r in $reclaimable) {
        if (-not $PSCmdlet.ShouldProcess("PID $($r.HolderPid)", 'Stop orphan pwsh holder')) { continue }
        # Write-Information, not Write-Output: this function has a singular
        # hashtable return contract, so a status line on the output stream would
        # be captured alongside the result (Write-Output pipeline pollution).
        Write-Information "Port $Port held by orphan pwsh PID $($r.HolderPid) (started $($r.Proc.StartTime)). Stopping it." -InformationAction Continue
        Stop-Process -Id $r.HolderPid -Force -ErrorAction SilentlyContinue
    }

    # HTTP.sys releases the reservation async after the owner exits; poll the
    # bind probe briefly before declaring success or an unresolvable conflict.
    if (Test-PortListenerFree -Port $Port -BudgetMs 3000) {
        if ($PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        return @{ Status = 'Recovered'; Port = $Port; Pids = $holderPids; Owner = ''; Service = $null; Message = '' }
    }

    # Stopped what we could but the port is still held -- the holder was not ours
    # to reclaim (e.g. another user's pwsh that Stop-Process could not touch), or
    # a second holder was hidden behind the one that just exited. One elevated
    # attempt before refusing, same as the branches above.
    $takeover = Invoke-PortTakeover -Port $Port -KnownPid $holderPids -Enabled:$Elevate -Confirm:$false
    if ($takeover.Freed) {
        if ($PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
        return @{ Status = 'Recovered'; Port = $Port; Pids = @($holderPids + $takeover.Stopped | Select-Object -Unique); Owner = ''; Service = $null; Message = '' }
    }

    $stillLines = @(
        "Status-service port $Port is still held after stopping the orphan pwsh holder(s) ($($holderPids -join ', '))."
    )
    if ($svcClause) { $stillLines += "  $svcClause" }
    if ($takeover.Attempted) { $stillLines += "  Elevated takeover was tried too and did not free it: $($takeover.Detail)" }
    $stillLines += "  Refusing to start. Inspect with 'lsof -iTCP:$Port -sTCP:LISTEN' (or 'netsh http show servicestate'),"
    $stillLines += "  free the port, or set a different statusService.port in test/test.config.yml and rerun."
    return @{ Status = 'Conflict'; Port = $Port; Pids = $holderPids; Owner = ''; Service = $service; Message = ($stillLines -join [Environment]::NewLine) }
}

Export-ModuleMember -Function Get-PortListenerPid, Test-PortListenerFree, Test-PortPrivilegeBlocked, Get-ProcessOwnerName, Get-PortHolderServiceInfo, Invoke-PortTakeover, Resolve-PortOrphan
