<#PSScriptInfo
.VERSION 2026.05.29
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
# Two functions:
#
#   Get-PortListenerPid   — pure: returns the PID(s) holding a TCP port.
#                           Cross-platform: netsh on Windows (because
#                           HTTP.sys hides the real owner from
#                           Get-NetTCPConnection), lsof on macOS/Linux.
#   Resolve-PortOrphan    — opinionated: free the port by stopping orphan
#                           pwsh holders. Refuses to kill anything that
#                           isn't pwsh. Calls `exit 1` if the port stays
#                           held — this preserves the original semantics
#                           of Start-StatusService's pre-flight, which is
#                           the only legitimate caller today.

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
    # the only reliable source for url-group → PID mapping. Output is
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

function Resolve-PortOrphan {
    <#
    .SYNOPSIS
        Free $Port by stopping orphan pwsh listeners. Refuses to kill
        anything that isn't pwsh. Probes the port via HttpListener with
        a 5-second budget BEFORE falling through to the kill path —
        HTTP.sys release is asynchronous after Stop-Process so a brief
        transient must not look like an unresolvable conflict.
    .DESCRIPTION
        Exits the calling SCRIPT with code 1 on the unresolvable path
        (port held by a non-pwsh process, or still held after the kill).
        This matches Start-StatusService's pre-flight semantics; future
        callers that want graceful degradation should call
        Get-PortListenerPid directly and decide for themselves.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Function already declares SupportsShouldProcess; PSSA may flag the inner call sites that we wrap in $PSCmdlet.ShouldProcess.')]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$PidFile
    )

    # Cheapest test that the detached launch will succeed: attempt the
    # same HttpListener it will use. On Windows, HTTP.sys releases the URL
    # reservation asynchronously after a Stop-Process'd pwsh exits -- the
    # -Restart branch above already gave it 1s and netsh shows the URL
    # registration gone, but HttpListener.Start still throws "conflicts
    # with an existing registration" for a few hundred ms beyond that.
    # Poll the probe until it succeeds or 5s elapses BEFORE falling
    # through to the orphan-PID lookup: a transient HTTP.sys GC delay
    # should not look like an unresolvable port conflict.
    # 20 iter * 250ms = 5s budget; the happy path is usually 1-2 iters.
    $portFree = $false
    for ($i = 0; $i -lt 20; $i++) {
        $probe = [System.Net.HttpListener]::new()
        $probe.Prefixes.Add("http://*:$Port/")
        try {
            $probe.Start(); $probe.Stop(); $probe.Close()
            $portFree = $true
            break
        } catch {
            try { $probe.Close() } catch { Write-Debug $_ }
        }
        Start-Sleep -Milliseconds 250
    }
    if ($portFree) { return }

    $diag = ''
    $holderPids = @(Get-PortListenerPid -Port $Port -Diagnostic ([ref]$diag))
    if (-not $holderPids.Count) {
        Write-Warning "Port $Port is in use but the OS did not expose a PID (netsh/lsof unavailable or empty)."
        if ($diag) { Write-Warning "  Diagnostic: $diag" }
        Write-Warning "Stop the conflicting listener manually and rerun:"
        Write-Warning "  Windows: netsh http show servicestate"
        Write-Warning "  Unix:    lsof -iTCP:$Port -sTCP:LISTEN  (or: sudo lsof -nP -iTCP:$Port)"
        exit 1
    }

    foreach ($holderPid in $holderPids) {
        $proc = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if (-not $proc) { continue }   # exited since the OS query
        if ($proc.ProcessName -notmatch '^(pwsh|PowerShell|powershell)$') {
            Write-Warning "Port $Port is held by PID $holderPid ($($proc.ProcessName)) — not a pwsh process."
            Write-Warning "Refusing to kill an unrelated listener. Stop it manually (Stop-Process -Id $holderPid) and rerun."
            exit 1
        }
        if (-not $PSCmdlet.ShouldProcess("PID $holderPid", 'Stop orphan pwsh holder')) { continue }
        Write-Output "Port $Port held by orphan pwsh PID $holderPid (started $($proc.StartTime)). Stopping it."
        Stop-Process -Id $holderPid -Force -ErrorAction SilentlyContinue
    }

    # HTTP.sys releases the URL reservation async after the owner exits;
    # poll briefly until the probe succeeds.
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 300
        $probe = [System.Net.HttpListener]::new()
        $probe.Prefixes.Add("http://*:$Port/")
        try {
            $probe.Start(); $probe.Stop(); $probe.Close()
            if ($PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
            return
        } catch {
            try { $probe.Close() } catch { Write-Debug $_ }
        }
    }
    Write-Warning "Port $Port is still held after stopping the orphan pwsh holder(s)."
    Write-Warning "Inspect with 'netsh http show servicestate' (or 'lsof -iTCP:$Port -sTCP:LISTEN') and retry."
    exit 1
}

Export-ModuleMember -Function Get-PortListenerPid, Resolve-PortOrphan
