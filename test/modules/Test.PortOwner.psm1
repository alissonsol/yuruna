<#PSScriptInfo
.VERSION 2026.07.21
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

# Port-ownership diagnostics. Shared by harness components
# (Start-StatusService, Stop-StatusService, Test-CachingProxy,
# future health-checks) so the Windows HTTP.sys / netsh + Unix
# lsof dispatch lives in one place.
#
# Functions:
#
#   Get-PortListenerPid     -- pure: PID(s) holding a TCP port. Cross-platform:
#                             netsh on Windows (because HTTP.sys hides the real
#                             owner from Get-NetTCPConnection), lsof on
#                             macOS/Linux. Empty when the holder is owned by
#                             another user (lsof/netsh hide it without elevation).
#   Test-PortListenerFree   -- pure: $true when THIS process can bind
#                             http://*:$Port/. The OS-agnostic source of truth:
#                             a holder owned by another user still makes it
#                             $false even when no PID is resolvable.
#   Test-PortPrivilegeBlocked -- pure: $true when that bind failed only because
#                             this process may not RESERVE the wildcard URL, and
#                             the port is in fact empty. Wanting the bind and
#                             being allowed to ask for it are different questions,
#                             and a failed bind alone cannot tell them apart.
#   Get-ProcessOwnerName    -- pure: best-effort OS user owning a PID.
#   Get-PortHolderServiceInfo -- pure: best-effort identity of a Yuruna status
#                             service already answering on the port.
#   Resolve-PortOrphan      -- opinionated: reclaim an orphan pwsh holder THIS
#                             user owns; otherwise classify the port as a
#                             'Conflict', or as 'PrivilegeRequired' when nothing
#                             holds it and the wildcard reservation was simply
#                             refused. Both refuse to start -- the status server
#                             binds the same prefix and would fail the same way --
#                             but only one of them has a holder to go and stop.
#                             Returns a structured result and never
#                             exits/throws -- the caller (Start-StatusService)
#                             decides how to refuse, so the refusal can
#                             propagate and abort the cycle rather than letting
#                             it run blind without a status server.

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
        proof that the detached status server will be able to start.
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

        Two signals separate the cases, and both are checked because they fail on
        different platforms:

          * The HttpListenerException error code. Windows answers 183
            (ERROR_ALREADY_EXISTS, "conflicts with an existing registration")
            when a registration genuinely holds the port, and 5
            (ERROR_ACCESS_DENIED) when the caller simply may not reserve it.
          * A bind of `http://localhost:<port>/`, which carries no reservation
            requirement and therefore succeeds ONLY when the port is really free.
            This is what makes the answer hold on macOS/Linux, where the managed
            HttpListener is not HTTP.sys and the error codes do not apply.

        Deliberately NOT folded into Test-PortListenerFree: that function answers
        "can the status server bind here", and the answer stays $false in this
        case -- the server binds the same wildcard prefix and fails identically.
        Only the explanation differs, so only the explanation is computed here.
    .OUTPUTS
        [bool] $true only when the port is provably free AND the wildcard
        reservation was refused for want of privilege.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][int]$Port)

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
            $psCmd = Get-Command ps -CommandType Application -ErrorAction SilentlyContinue
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

function Resolve-PortOrphan {
    <#
    .SYNOPSIS
        Try to free $Port for THIS user's status server, distinguishing a
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
        'Conflict'  : the port is held by something this user must not (or
                      cannot) take over. The cycle must refuse to start.
        'PrivilegeRequired' : the port is EMPTY, but this process may not reserve
                      the wildcard prefix (elevation, or a standing urlacl). The
                      cycle must still refuse -- the status server binds the same
                      prefix and would fail identically -- but there is no holder
                      to hunt, so it is reported apart from 'Conflict' rather than
                      being described as a port that is "in use".
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Function already declares SupportsShouldProcess; PSSA may flag the inner Stop-Process call site that we wrap in $PSCmdlet.ShouldProcess.')]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$PidFile
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
        # at all. Both refuse to start -- the status server binds the same prefix
        # and would fail the same way -- but they send the operator to opposite
        # places, and the port-is-empty case has no holder to go looking for.
        if (Test-PortPrivilegeBlocked -Port $Port) {
            $lines = @(
                "Status-service port $Port is FREE, but this process may not reserve http://*:$Port/."
                "  That is an HTTP.sys URL reservation: making one needs elevation. Nothing is holding"
                "  the port -- this is a privilege problem, not a port conflict."
                "  Refusing to start: the status server binds the same wildcard prefix (so that guests"
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
        # this is the signature of a listener owned by a DIFFERENT USER. Treat
        # it as a hard conflict: a bind failure with no reclaimable owner means
        # this user cannot host a status server here, and proceeding would run
        # the cycle blind (no dashboard, no breakpoint controls).
        $ownerLine = if ($svcClause) { "  $svcClause" }
                     else { "  The holder is owned by another user (its socket is hidden from lsof/netsh without elevation)." }
        $lines = @(
            "Status-service port $Port is in use but no owning PID is visible to this user."
            $ownerLine
            "  Refusing to start: a second status server cannot bind the same port, and running the"
            "  cycle without one hides the live dashboard / breakpoint controls (a hard-to-debug state)."
            "  Resolve by ONE of:"
            "    - stop the other owner's status service (it may belong to another user account); or"
            "    - give this checkout its own port in test/test.config.yml (statusService.port) and rerun."
            "  Diagnostic: $diag"
        )
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
            $ownerStr = if ($owner) { " owned by '$owner'" } else { '' }
            $whyLine  = if ($svcClause) { "  $svcClause" }
                        else { "  Refusing to commandeer a listener this harness does not own." }
            $lines = @(
                "Status-service port $Port is held by PID $holderPid ($($proc.ProcessName))$ownerStr."
                $whyLine
                "  Refusing to start so the cycle does not run without its status dashboard / breakpoint controls."
                "  Resolve by stopping that process (it may belong to another user), or set a different"
                "  statusService.port in test/test.config.yml and rerun."
            )
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
    # to reclaim (e.g. another user's pwsh that Stop-Process could not touch).
    $stillLines = @(
        "Status-service port $Port is still held after stopping the orphan pwsh holder(s) ($($holderPids -join ', '))."
    )
    if ($svcClause) { $stillLines += "  $svcClause" }
    $stillLines += "  Refusing to start. Inspect with 'lsof -iTCP:$Port -sTCP:LISTEN' (or 'netsh http show servicestate'),"
    $stillLines += "  free the port, or set a different statusService.port in test/test.config.yml and rerun."
    return @{ Status = 'Conflict'; Port = $Port; Pids = $holderPids; Owner = ''; Service = $service; Message = ($stillLines -join [Environment]::NewLine) }
}

Export-ModuleMember -Function Get-PortListenerPid, Test-PortListenerFree, Test-PortPrivilegeBlocked, Get-ProcessOwnerName, Get-PortHolderServiceInfo, Resolve-PortOrphan
