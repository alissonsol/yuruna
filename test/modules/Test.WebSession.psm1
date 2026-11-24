<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4206b90b-0499-4c5a-a0ea-3f4bfcca6942
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test web session browser
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

# The web session of a guest: a headless browser the launcher
# (automation/yuruna-web-browser.sh) starts in the guest, the SSH tunnel that
# holds it and reaches its debugging port, and the table of live sessions, one
# per VM. A session is data and .NET objects only: a script block or a class
# instance belongs to the module instance that made it, and this module and
# Test.Ssh.psm1 are imported again with -Force during a run. Both stores are
# global for the same reason, so a re-import finds every session it left, and
# no OnRemove handler closes anything. The same file holds the DevTools
# protocol client the page verbs drive through the tunnel: the connection, the
# page reader, the locator and the page operations.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Cross-module-eviction-safe anchor; the only reliable way to keep live web sessions across -Force re-imports.')]
param()

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

$script:WebSessionRegistry = New-YurunaRegistry -Name 'GuestWebSession' `
    -AnchorVar 'YurunaGuestWebSessions' -Comparer 'OrdinalIgnoreCase'
$script:WebSessionCounter = New-YurunaRegistry -Name 'GuestWebSessionCounter' `
    -AnchorVar 'YurunaGuestWebSessionCounter' -Comparer 'Ordinal'
if (-not (& $script:WebSessionCounter.Has 'Generation')) {
    & $script:WebSessionCounter.Register 'Generation' 0
}

# The launcher text as base64, read once per module load.
$script:WebBrowserLauncherB64 = $null

# --- REGION: Launcher command
function Get-GuestWebBrowserCommand {
    <#
    .SYNOPSIS
        The remote command that runs one verb of the browser launcher in the guest.
    .DESCRIPTION
        The launcher is never installed: its text travels in the command, so a
        guest restored from an old snapshot still runs the current one. It runs
        as `bash -c <text>`, not through `bash -s`, which would take the script
        from standard input; `hold` needs the session's standard input as the
        tie to its owner. Each parameter is validated so that no value can break
        the quoting.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'hold', 'stop')][string]$Verb,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]{1,16}$')][string]$Id,
        [ValidatePattern('^[1-9][0-9]{0,4},[1-9][0-9]{0,4}$')][string]$Window = '1280,800',
        [ValidateRange(1, 999)][int]$ReadySeconds = 30
    )
    if (-not $script:WebBrowserLauncherB64) {
        # test/modules -> test -> repository root -> automation/
        $launcherPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'automation' -AdditionalChildPath 'yuruna-web-browser.sh'
        $script:WebBrowserLauncherB64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($launcherPath))
    }
    $text = "bash -c `"`$(printf '%s' '$($script:WebBrowserLauncherB64)' | base64 -d)`" yuruna-web-browser $Verb --id '$Id'"
    if ($Verb -eq 'start') {
        $text += " --window '$Window' --ready-seconds $ReadySeconds"
    }
    return $text
}

function ConvertFrom-GuestWebBrowserReport {
    <#
    .SYNOPSIS
        The last result line of the browser launcher in some output, parsed.
    .OUTPUTS
        System.Collections.Hashtable, or $null when no line matches or the last
        one does not parse.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Output)
    $json = $null
    foreach ($line in ([string]$Output -split "\r?\n")) {
        $match = [regex]::Match($line, '^YURUNA_WEB_BROWSER (\{.*\})\s*$')
        if ($match.Success) { $json = $match.Groups[1].Value }
    }
    if ($null -eq $json) { return $null }
    try {
        $report = ConvertFrom-Json -InputObject $json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "ConvertFrom-GuestWebBrowserReport: the last launcher line does not parse: $($_.Exception.Message)"
        return $null
    }
    if ($report -isnot [System.Collections.IDictionary]) { return $null }
    return $report
}

# --- REGION: Session table
function Open-GuestWebSession {
    <#
    .SYNOPSIS
        Start a browser in the guest, hold it through an SSH tunnel and register
        the session under the VM name.
    .DESCRIPTION
        An earlier session of the VM is closed first. The launcher starts the
        browser and reports its debugging port; the tunnel runs the launcher's
        `hold` and forwards a free loopback port to that port; /json/version
        through the tunnel proves the endpoint. The whole open stays inside the
        lesser of StartupTimeoutSeconds and DeadlineUtc, except one bounded
        cleanup call when a browser may run with nothing holding it.
    .PARAMETER OwnerId
        The SequenceInvocationId of the step that opens the session; the
        sequence's end closes the sessions it owns.
    .PARAMETER Effect
        The effect table of the calling step: Dispatched is set while the
        launcher call may have changed the guest.
    .OUTPUTS
        System.Collections.Hashtable: Ok, Session, Kind (the page failure kind),
        Code, Detail, LauncherKind, BrowserStartIssued.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$GuestKey,
        [AllowEmptyString()][string]$OwnerId = '',
        [ValidatePattern('^[1-9][0-9]{0,4},[1-9][0-9]{0,4}$')][string]$Window = '1280,800',
        [datetime]$DeadlineUtc,
        [ValidateRange(1, 600)][int]$StartupTimeoutSeconds = 60,
        [hashtable]$Effect
    )
    if (-not (Get-Command Start-GuestSshTunnel -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Global -DisableNameChecking }
    $began = [System.Diagnostics.Stopwatch]::StartNew()
    $outcome = @{
        Ok                 = $false
        Session            = $null
        Kind               = ''
        Code               = ''
        Detail             = ''
        LauncherKind       = ''
        BrowserStartIssued = $false
    }
    if (& $script:WebSessionRegistry.Has $VMName) {
        [void](Close-GuestWebSession -VMName $VMName -Reason 'reopened')
    }

    $allowedMs = [double]$StartupTimeoutSeconds * 1000
    if ($PSBoundParameters.ContainsKey('DeadlineUtc')) {
        $allowedMs = [Math]::Min($allowedMs, ($DeadlineUtc.ToUniversalTime() - [datetime]::UtcNow).TotalMilliseconds)
    }
    $openDeadline = New-YurunaDeadline -TotalMilliseconds ([long][Math]::Max(0, [Math]::Floor($allowedMs)))
    $secondsLeft = { [int][Math]::Floor((Get-YurunaDeadlineRemainingMs -Deadline $openDeadline) / 1000) }
    $failed = {
        param([string]$Kind, [string]$Code, [string]$Detail)
        $outcome.Kind = $Kind
        $outcome.Code = $Code
        $outcome.Detail = $Detail
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.web_session_open_failed' -Arguments @{ vmName = "$VMName"; code = "$Code"; detail = "$Detail" })
        return $outcome
    }
    if ((& $secondsLeft) -lt 1) {
        return (& $failed 'transport' 'no-time-left' 'less than one second was left to open the browser session')
    }

    $id = 'w' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $left = & $secondsLeft
    $readyLimit = [int][Math]::Min(30, [Math]::Max(5, $left - 10))
    if ($Effect) { $Effect['Dispatched'] = $true }
    # The address wait of Invoke-GuestSsh runs before its timeout starts, so the
    # two together are kept inside the time allowed.
    $launch = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey `
        -Command (Get-GuestWebBrowserCommand -Verb start -Id $id -Window $Window -ReadySeconds $readyLimit) `
        -TimeoutSeconds ([int][Math]::Max(1, [Math]::Min($readyLimit + 15, $left))) `
        -AddressWaitSeconds ([int][Math]::Max(0, [Math]::Min(20, $left - $readyLimit - 15)))
    $exitCode = [int]$launch.exitCode
    if ($exitCode -eq -2) {
        if ($Effect) { $Effect['Dispatched'] = $false }
    } else {
        $outcome.BrowserStartIssued = $true
    }
    $launchOutput = [string]$launch.output
    $started = ConvertFrom-GuestWebBrowserReport -Output $launchOutput
    $launchTail = if ($launchOutput.Length -gt 500) { $launchOutput.Substring($launchOutput.Length - 500) } else { $launchOutput }
    # Without a report a browser may be running with nothing holding it.
    $stopUnheld = {
        $stopped = Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey `
            -Command (Get-GuestWebBrowserCommand -Verb stop -Id $id) -TimeoutSeconds 20 -AddressWaitSeconds 0
        Write-Verbose "Open-GuestWebSession: stop of browser $id in ${VMName}: exit $($stopped.exitCode) $($stopped.output)"
    }
    if ($exitCode -eq -2) {
        return (& $failed 'address_unresolved' 'address-unresolved' $launchTail)
    }
    $port = 0
    $isStarted = $null -ne $started -and $started['ok'] -eq $true -and [string]$started['event'] -eq 'started' -and
        [int]::TryParse([string]$started['port'], [ref]$port) -and $port -ge 1 -and $port -le 65535
    if (-not $isStarted) {
        if ($null -ne $started -and $started['ok'] -eq $false) {
            $outcome.LauncherKind = [string]$started['kind']
            return (& $failed 'browser_unavailable' 'launcher-refused' ('{0}: {1}' -f $started['kind'], $started['detail']))
        }
        $noReportDetail = ('exit {0}: {1}' -f $exitCode, $launchTail).Trim()
        & $stopUnheld
        if ($exitCode -eq 255 -or $launch.transportLost -or $launch.timedOut) {
            return (& $failed 'transport' 'launcher-transport' $noReportDetail)
        }
        return (& $failed 'browser_unavailable' 'launcher-no-report' $noReportDetail)
    }

    $tunnelSeconds = [int][Math]::Max(1, [Math]::Min(600, (& $secondsLeft)))
    $tunnelResult = Start-GuestSshTunnel -VMName $VMName -GuestKey $GuestKey -RemotePort $port `
        -RemoteCommand (Get-GuestWebBrowserCommand -Verb hold -Id $id) `
        -ReadyPattern '^YURUNA_WEB_BROWSER \{.*"event":"holding"' -ProbePath '/json/version' `
        -Deadline $openDeadline -StartupTimeoutSeconds $tunnelSeconds
    if (-not $tunnelResult.Ok) {
        $held = ConvertFrom-GuestWebBrowserReport -Output (@($tunnelResult.OutputLines) -join "`n")
        $tunnelKind = if ($null -ne $held -and $held['ok'] -eq $false) {
            $outcome.LauncherKind = [string]$held['kind']
            'browser_unavailable'
        } elseif ($tunnelResult.Code -eq 'address-unresolved') {
            'address_unresolved'
        } else {
            'transport'
        }
        # A tunnel that attached releases the browser when it stops; one that
        # never attached leaves the started browser to this stop.
        if (-not $tunnelResult.Attached) { & $stopUnheld }
        return (& $failed $tunnelKind ('tunnel-' + $tunnelResult.Code) ([string]$tunnelResult.Detail))
    }

    $tunnel = $tunnelResult.Tunnel
    $version = $null
    try {
        $version = ConvertFrom-Json -InputObject ([string]$tunnel.ProbeBody) -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Open-GuestWebSession: /json/version of $VMName does not parse: $($_.Exception.Message)"
    }
    if ($version -isnot [System.Collections.IDictionary]) {
        [void](Stop-GuestSshTunnel -Tunnel $tunnel)
        $body = [string]$tunnel.ProbeBody
        if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
        return (& $failed 'protocol' 'endpoint-not-json' "/json/version answered: $body")
    }

    & $script:WebSessionCounter.Register 'Generation' ([int](& $script:WebSessionCounter.Get 'Generation') + 1)
    $generation = [int](& $script:WebSessionCounter.Get 'Generation')
    $product = [string]$version['Browser']
    $session = @{
        VMName        = $VMName
        GuestKey      = $GuestKey
        Generation    = $generation
        OwnerId       = [string]$OwnerId
        RunId         = [string]$global:__YurunaRunId
        CycleIdentity = [string]$global:__YurunaCycleIdentity
        State         = 'open'
        OpenedUtc     = [datetime]::UtcNow
        ClosedUtc     = $null
        CloseReason   = ''
        Browser       = $started
        Tunnel        = $tunnel
        LocalPort     = [int]$tunnel.LocalPort
        Version       = $version
        Product       = $product
        Cdp           = $null
    }
    & $script:WebSessionRegistry.Register $VMName $session
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
        Send-CycleEventSafely -EventRecord @{
            timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event      = 'web_session_opened'
            vmName     = [string]$VMName
            guestKey   = [string]$GuestKey
            generation = $generation
            browser    = $product
            localPort  = [int]$tunnel.LocalPort
            remotePort = [int]$port
            durationMs = [int]$began.ElapsedMilliseconds
        }
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.web_session_opened' -Arguments @{ generation = "$generation"; vmName = "$VMName"; browser = "$product"; remotePort = "$port"; localPort = "$($tunnel.LocalPort)" }) -InformationAction Continue
    $outcome.Ok = $true
    $outcome.Session = $session
    return $outcome
}

function Get-GuestWebSession {
    <#
    .SYNOPSIS
        The live web session of a VM, or $null.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    return (& $script:WebSessionRegistry.Get $VMName)
}

function Get-GuestWebSessionList {
    <#
    .SYNOPSIS
        Every live web session of this process.
    .DESCRIPTION
        Returned as one array, so that a single entry is not unrolled into the
        session hashtable, whose Count is its number of keys.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return ,@($script:WebSessionRegistry.Store[0].Values)
}

function Test-GuestWebSession {
    <#
    .SYNOPSIS
        Whether a web session is still open and its tunnel still runs, and if
        not, whether the browser or the tunnel ended it.
    .OUTPUTS
        System.Collections.Hashtable: Alive, Code, Detail.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$Session)
    if (-not (Get-Command Start-GuestSshTunnel -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Global -DisableNameChecking }
    if ($Session['State'] -eq 'open' -and (Test-GuestSshTunnel -Tunnel $Session['Tunnel'])) {
        return @{ Alive = $true; Code = ''; Detail = '' }
    }
    # The tunnel has exited, so this only collects what it printed.
    $stop = Stop-GuestSshTunnel -Tunnel $Session['Tunnel']
    $report = ConvertFrom-GuestWebBrowserReport -Output ([string]$stop.StdOut)
    $code = if ($null -ne $report -and [string]$report['event'] -eq 'browser-exited') { 'browser-exited' } else { 'tunnel-exited' }
    return @{ Alive = $false; Code = $code; Detail = ('exit {0}: {1}' -f $stop.ExitCode, $stop.StdErr).Trim() }
}

function Close-GuestWebSession {
    <#
    .SYNOPSIS
        Close web sessions by VM, by VM and generation, by owner, or all of them.
    .DESCRIPTION
        Each selected entry leaves the table first, so a second close of the same
        session finds nothing. The page connection closes before the tunnel;
        closing the tunnel's input makes the launcher's `hold` stop the browser
        and remove its profile. Without a selector, or with an empty OwnerId,
        nothing is selected. Never throws.
    .PARAMETER Generation
        With VMName: close only when the live session has this generation, so an
        old reference never closes a newer session.
    .PARAMETER Reason
        The close reason, a lower-case code such as sequence-end or vm-stop.
    .OUTPUTS
        System.Int32, the number of sessions closed.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$VMName = '',
        [int]$Generation,
        [AllowEmptyString()][string]$OwnerId = '',
        [switch]$All,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{1,40}$')][string]$Reason
    )
    if (-not (Get-Command Start-GuestSshTunnel -ErrorAction SilentlyContinue)) { Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Global -DisableNameChecking }
    $store = $script:WebSessionRegistry.Store[0]
    $keys = @($store.Keys)
    $selected = [System.Collections.Generic.List[string]]::new()
    if ($All) {
        foreach ($key in $keys) { $selected.Add([string]$key) }
    } elseif ($VMName) {
        foreach ($key in $keys) {
            if ([string]::Equals([string]$key, $VMName, [StringComparison]::OrdinalIgnoreCase)) {
                if (-not $PSBoundParameters.ContainsKey('Generation') -or [int]$store[$key]['Generation'] -eq $Generation) {
                    $selected.Add([string]$key)
                }
            }
        }
    } elseif ($OwnerId) {
        foreach ($key in $keys) {
            if ([string]::Equals([string]$store[$key]['OwnerId'], $OwnerId, [StringComparison]::Ordinal)) { $selected.Add([string]$key) }
        }
    }
    $closed = 0
    foreach ($key in $selected) {
        $s = $store[$key]
        try {
            $store.Remove($key)
            $s['State'] = 'closing'
            if ($s['Cdp'] -and (Get-Command Close-WebCdp -ErrorAction SilentlyContinue)) {
                try {
                    Close-WebCdp -Connection $s['Cdp']
                } catch {
                    Write-Verbose "Close-GuestWebSession: the page connection of $key did not close: $($_.Exception.Message)"
                }
            }
            $stop = Stop-GuestSshTunnel -Tunnel $s['Tunnel']
            $s['State'] = 'closed'
            $s['ClosedUtc'] = [datetime]::UtcNow
            $s['CloseReason'] = $Reason
            $closed++
            if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) {
                Send-CycleEventSafely -EventRecord @{
                    timestamp  = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                    event      = 'web_session_closed'
                    vmName     = [string]$s['VMName']
                    guestKey   = [string]$s['GuestKey']
                    generation = [int]$s['Generation']
                    reason     = $Reason
                    forced     = [bool]$stop.Forced
                    durationMs = [int][Math]::Min([int]::MaxValue, ([datetime]::UtcNow - [datetime]$s['OpenedUtc']).TotalMilliseconds)
                }
            }
            Write-Verbose "Close-GuestWebSession: closed session $($s['Generation']) of $key ($Reason); exit $($stop.ExitCode), forced $($stop.Forced)."
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.web_session_close_incomplete' -Arguments @{ vmName = "$key"; reason = "$Reason"; detail = "$($_.Exception.Message)" })
        }
    }
    return $closed
}

# --- REGION: Protocol limits
# The protocol client keeps no live object in a $script: variable: everything a
# connection holds lives in its own hashtable, which the web session entry keeps
# in Cdp, so a forced re-import leaves a live connection usable. The tables below
# are fixed data. The client waits only inside Read-WebCdpTransport, never with
# Start-Sleep, and passes no CancellationToken but None: a canceled receive
# aborts the socket. Deadlines are DateTime values compared with Get-WebCdpNow,
# so a suite drives every wait through the connection's Clock.
$script:WebLimit = [ordered]@{
    MaxMessageBytes    = 33554432
    ReceiveBufferBytes = 65536
    MaxQueuedEvents    = 500
    MaxAbandonedIds    = 256
    ConnectLimitMs     = 10000
    EndpointLimitMs    = 5000
    SendLimitMs        = 5000
    ReplyLimitMs       = 10000
    CleanupLimitMs     = 2000
    PumpSliceMs        = 50
    PollIntervalMs     = 100
    StableGapMs        = 50
    SettleQuietMs      = 500
    SettleCapMs        = 10000
    VerifyLimitMs      = 2000
    MaxFrameDepth      = 8
    MaxForestEntries   = 20000
    MaxCssMatches      = 50
    MaxCandidates      = 10
    ViewportWidth      = 1280
    ViewportHeight     = 800
}

# Accessibility roles that render inside a line of text: they add no space
# around their content in the page text.
$script:WebInlineRole = @('strong', 'emphasis', 'code', 'subscript', 'superscript', 'insertion', 'deletion', 'time', 'Abbr', 'mark', 'link')
# Roles whose content is a field value, which the page text leaves out.
$script:WebTextControlRole = @('textbox', 'searchbox', 'spinbutton', 'combobox')

# The keys webPress sends, by the step's key name (looked up without regard to
# case). Enter carries a carriage return as text: only then does it submit a form.
$script:WebKey = @{
    'Enter'  = @{ Key = 'Enter'; Code = 'Enter'; VirtualKey = 13; Down = 'keyDown'; Text = "`r" }
    'Tab'    = @{ Key = 'Tab'; Code = 'Tab'; VirtualKey = 9; Down = 'rawKeyDown'; Text = $null }
    'Space'  = @{ Key = ' '; Code = 'Space'; VirtualKey = 32; Down = 'keyDown'; Text = ' ' }
    'Escape' = @{ Key = 'Escape'; Code = 'Escape'; VirtualKey = 27; Down = 'rawKeyDown'; Text = $null }
    'Up'     = @{ Key = 'ArrowUp'; Code = 'ArrowUp'; VirtualKey = 38; Down = 'rawKeyDown'; Text = $null }
    'Down'   = @{ Key = 'ArrowDown'; Code = 'ArrowDown'; VirtualKey = 40; Down = 'rawKeyDown'; Text = $null }
    'Left'   = @{ Key = 'ArrowLeft'; Code = 'ArrowLeft'; VirtualKey = 37; Down = 'rawKeyDown'; Text = $null }
    'Right'  = @{ Key = 'ArrowRight'; Code = 'ArrowRight'; VirtualKey = 39; Down = 'rawKeyDown'; Text = $null }
}
foreach ($functionKey in 1..12) {
    $script:WebKey["F$functionKey"] = @{ Key = "F$functionKey"; Code = "F$functionKey"; VirtualKey = 111 + $functionKey; Down = 'rawKeyDown'; Text = $null }
}

# The one script this module runs in a page: it selects an option of a native
# select by its label. The label reaches it only as the bound argument.
$script:WebSelectFunction = @'
function (label) {
  var view = this.ownerDocument && this.ownerDocument.defaultView;
  if (!view || !(this instanceof view.HTMLSelectElement)) { return { ok: false, reason: 'not-a-select' }; }
  if (this.multiple) { return { ok: false, reason: 'multiple' }; }
  var norm = function (s) { return String(s).replace(/\s+/g, ' ').trim().toLowerCase(); };
  var want = norm(label), matches = [], off = 0, seen = [];
  for (var i = 0; i < this.options.length; i++) {
    var o = this.options[i];
    if (seen.length < 20) { seen.push(String(o.label).replace(/\s+/g, ' ').trim()); }
    if (norm(o.label) !== want) { continue; }
    var group = o.parentNode;
    if (o.disabled || (group instanceof view.HTMLOptGroupElement && group.disabled)) { off++; } else { matches.push(o); }
  }
  if (matches.length === 0) { return { ok: false, reason: off ? 'option-disabled' : 'no-option', options: seen, count: this.options.length }; }
  if (matches.length > 1) { return { ok: false, reason: 'ambiguous-option', options: seen, count: matches.length }; }
  if (matches[0].selected) { return { ok: true, changed: false, index: matches[0].index }; }
  matches[0].selected = true;
  this.dispatchEvent(new view.Event('input', { bubbles: true, composed: true }));
  this.dispatchEvent(new view.Event('change', { bubbles: true }));
  return { ok: true, changed: true, index: matches[0].index };
}
'@

# ConvertFrom-Json turns a text that looks like a date into a DateTime unless
# told not to (-DateKind String, PowerShell 7.5 and later).
$script:WebJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:WebJsonOption.DateKind = 'String' }

function Get-WebLimit {
    <#
    .SYNOPSIS
        The limits of the protocol client, as a copy.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    $copy = [ordered]@{}
    foreach ($name in $script:WebLimit.Keys) { $copy[$name] = $script:WebLimit[$name] }
    return $copy
}

# --- REGION: Failure signal
function New-WebFailureException {
    <#
    .SYNOPSIS
        The one exception shape that carries a page failure upward.
    .DESCRIPTION
        Returned, not thrown: callers write throw (New-WebFailureException ...).
        Kind is one of the page failure kinds of Get-WebFailureKind; Detail is a
        short machine text, never a typed value.
    .PARAMETER Retryable
        Nothing was sent that changes the page, and trying again may succeed.
    .PARAMETER DeadlineCut
        The step deadline came before the reply limit, so the browser was not
        proven silent.
    .OUTPUTS
        System.InvalidOperationException
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an exception object; nothing outside it changes.')]
    [CmdletBinding()]
    [OutputType([System.InvalidOperationException])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Detail = '',
        [switch]$Retryable,
        [switch]$DeadlineCut,
        [AllowNull()][AllowEmptyCollection()][object[]]$Candidates = @(),
        [int]$MatchCount = -1
    )
    $exception = [System.InvalidOperationException]::new("${Kind}: $Detail")
    $exception.Data['YurunaWebFailure'] = @{
        Kind        = $Kind
        Detail      = [string]$Detail
        Retryable   = [bool]$Retryable
        DeadlineCut = [bool]$DeadlineCut
        Candidates  = [object[]]@($Candidates | Where-Object { $null -ne $_ })
        MatchCount  = $MatchCount
    }
    return $exception
}

function Get-WebFailureData {
    <#
    .SYNOPSIS
        The page failure an error record carries, or $null for any other error.
    .OUTPUTS
        System.Collections.Hashtable: Kind, Detail, Retryable, DeadlineCut,
        Candidates, MatchCount.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if ($exception.Data -and $exception.Data.Contains('YurunaWebFailure')) { return $exception.Data['YurunaWebFailure'] }
        $exception = $exception.InnerException
    }
    return $null
}

# --- REGION: Transport
function New-WebCdpSocketTransport {
    <#
    .SYNOPSIS
        A transport over a connected WebSocket.
    .PARAMETER MaxMessageBytes
        The longest message kept; a longer reply is answered as error -32099.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record around a socket the caller opened.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Net.WebSockets.WebSocket]$Socket,
        [ValidateRange(64, [long]::MaxValue)][long]$MaxMessageBytes = 33554432
    )
    return @{
        Kind            = 'socket'
        Socket          = $Socket
        Pending         = $null
        Buffer          = [byte[]]::new($script:WebLimit.ReceiveBufferBytes)
        Stream          = [System.IO.MemoryStream]::new()
        MaxMessageBytes = $MaxMessageBytes
        Discarding      = $false
        Head            = ''
        Closed          = $false
        Oversize        = 0L
    }
}

function Read-WebCdpTransport {
    <#
    .SYNOPSIS
        One whole message from a transport, or $null when none arrived in time.
    .DESCRIPTION
        One receive may be pending at a time. It is waited on with Task.Wait and
        kept for the next call when nothing arrived: canceling it would abort
        the socket.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Transport,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    if ($Transport.Kind -eq 'scripted') { return (& $Transport.Receive $TimeoutMs) }
    if ($Transport.Closed) { throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed') }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if ($null -eq $Transport.Pending) {
            $Transport.Pending = $Transport.Socket.ReceiveAsync([ArraySegment[byte]]::new($Transport.Buffer), [System.Threading.CancellationToken]::None)
        }
        $remainingMs = [int][Math]::Max(0, $TimeoutMs - $watch.ElapsedMilliseconds)
        $arrived = $false
        try {
            $arrived = $Transport.Pending.Wait($remainingMs)
        } catch {
            $Transport.Closed = $true
            $Transport.Pending = $null
            throw (New-WebFailureException -Kind 'transport' -Detail ([string]$_.Exception.GetBaseException().Message))
        }
        if (-not $arrived) { return $null }
        $received = $Transport.Pending.Result
        $Transport.Pending = $null
        if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            $Transport.Closed = $true
            throw (New-WebFailureException -Kind 'transport' -Detail 'close frame')
        }
        if (-not $Transport.Discarding) {
            $Transport.Stream.Write($Transport.Buffer, 0, $received.Count)
            if ($Transport.Stream.Length -gt $Transport.MaxMessageBytes) {
                $headLength = [int][Math]::Min(64, $Transport.Stream.Length)
                $Transport.Head = [System.Text.Encoding]::ASCII.GetString($Transport.Stream.GetBuffer(), 0, $headLength)
                $Transport.Stream.SetLength(0)
                $Transport.Discarding = $true
                $Transport.Oversize++
            }
        }
        if ($received.EndOfMessage) {
            if ($Transport.Discarding) {
                $Transport.Discarding = $false
                $head = [regex]::Match($Transport.Head, '^\{"id":(\d+),')
                $Transport.Head = ''
                if ($head.Success) {
                    return ('{{"id":{0},"error":{{"code":-32099,"message":"reply larger than {1} bytes"}}}}' -f $head.Groups[1].Value, $Transport.MaxMessageBytes)
                }
                continue
            }
            $text = [System.Text.Encoding]::UTF8.GetString($Transport.Stream.GetBuffer(), 0, [int]$Transport.Stream.Length)
            $Transport.Stream.SetLength(0)
            return $text
        }
    }
}

function Write-WebCdpTransport {
    <#
    .SYNOPSIS
        Send one message text on a transport.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Transport,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    if ($Transport.Kind -eq 'scripted') {
        $null = & $Transport.Send $Text
        return
    }
    if ($Transport.Closed) { throw (New-WebFailureException -Kind 'transport' -Detail 'socket closed') }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sent = $false
    $reason = 'timed out'
    try {
        # The ArraySegment selects the overload that returns a Task; a bare
        # byte[] can bind the ReadOnlyMemory overload, whose ValueTask has no Wait.
        $sent = $Transport.Socket.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true, [System.Threading.CancellationToken]::None).Wait($TimeoutMs)
    } catch {
        $reason = [string]$_.Exception.GetBaseException().Message
    }
    if (-not $sent) {
        try {
            $Transport.Socket.Abort()
        } catch {
            Write-Verbose "Write-WebCdpTransport: aborting the socket failed: $($_.Exception.Message)"
        }
        $Transport.Closed = $true
        throw (New-WebFailureException -Kind 'transport' -Detail "send: $reason")
    }
}

function Close-WebCdpTransport {
    <#
    .SYNOPSIS
        Close a transport. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Transport)
    if ($Transport.Kind -eq 'scripted') {
        if ($Transport.Close) {
            try {
                $null = & $Transport.Close
            } catch {
                Write-Verbose "Close-WebCdpTransport: the scripted close failed: $($_.Exception.Message)"
            }
        }
        $Transport.Closed = $true
        return
    }
    try {
        if (-not $Transport.Closed) { $Transport.Socket.Abort() }
    } catch {
        Write-Verbose "Close-WebCdpTransport: aborting the socket failed: $($_.Exception.Message)"
    }
    try {
        $Transport.Socket.Dispose()
    } catch {
        Write-Verbose "Close-WebCdpTransport: disposing the socket failed: $($_.Exception.Message)"
    }
    try {
        $Transport.Stream.Dispose()
    } catch {
        Write-Verbose "Close-WebCdpTransport: disposing the buffer failed: $($_.Exception.Message)"
    }
    $Transport.Pending = $null
    $Transport.Closed = $true
}

# --- REGION: Connection and events
function New-WebCdpConnection {
    <#
    .SYNOPSIS
        A protocol connection over a transport: data only, so a forced import of
        this module leaves it usable.
    .PARAMETER Clock
        @{ Now = <DateTime> } for a suite; the real clock when omitted.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record around a transport the caller holds.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Transport,
        [hashtable]$Clock
    )
    return @{
        Transport     = $Transport
        Clock         = $Clock
        NextId        = 0
        Abandoned     = [System.Collections.Generic.HashSet[int]]::new()
        Events        = [System.Collections.Generic.Queue[object]]::new()
        EventSeq      = 0L
        DroppedEvents = 0L
        Closed        = $false
        Browser       = @{}
        Page          = $null
        InDialog      = $false
    }
}

function Get-WebCdpNow {
    <#
    .SYNOPSIS
        The connection's clock: its Clock.Now when set, else the UTC time.
    .OUTPUTS
        System.DateTime
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][hashtable]$Connection)
    if ($Connection.Clock) { return [datetime]$Connection.Clock.Now }
    return [datetime]::UtcNow
}

function Update-WebCdpPageState {
    <#
    .SYNOPSIS
        Record what one event says about the owned page. Sends nothing.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the in-memory page record of a connection.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Message
    )
    $page = $Connection.Page
    if ($null -eq $page) { return }
    $method = [string]$Message['method']
    $params = if ($Message['params'] -is [System.Collections.IDictionary]) { $Message['params'] } else { @{} }
    $seq = [long]$Message['Seq']
    $onPage = [bool]$page.SessionId -and ([string]$Message['sessionId'] -ceq [string]$page.SessionId)
    $frameId = if ($params.Contains('frameId')) { [string]$params['frameId'] } elseif ($params['frame'] -is [System.Collections.IDictionary]) { [string]$params['frame']['id'] } else { '' }
    $onMain = $onPage -and [bool]$frameId -and ($frameId -ceq [string]$page.MainFrameId)
    $targetInfo = if ($params['targetInfo'] -is [System.Collections.IDictionary]) { $params['targetInfo'] } else { @{} }
    $touch = $false
    if ($method -ceq 'Page.frameStartedLoading') {
        if ($onMain) { $page.Loading = $true; $touch = $true }
    } elseif ($method -ceq 'Page.frameStoppedLoading') {
        if ($onMain) { $page.Loading = $false; $touch = $true }
    } elseif ($method -ceq 'Page.frameNavigated') {
        if ($onMain) {
            $frame = $params['frame']
            $page.Url = [string]$frame['url']
            $page.UnreachableUrl = if ($frame.Contains('unreachableUrl')) { [string]$frame['unreachableUrl'] } else { '' }
            $page.CommitSeq = $seq
            $page.Generation++
            $page.Crashed = $false
            $touch = $true
        }
    } elseif ($method -ceq 'Page.navigatedWithinDocument') {
        if ($onMain) { $page.Url = [string]$params['url']; $touch = $true }
    } elseif ($method -cin @('Page.frameRequestedNavigation', 'Page.frameScheduledNavigation', 'Page.frameStartedNavigating', 'Page.frameClearedScheduledNavigation')) {
        if ($onMain) { $touch = $true }
    } elseif ($method -ceq 'Page.javascriptDialogOpening') {
        if ($onPage) {
            $dialogText = [string]$params['message']
            if ($dialogText.Length -gt 200) { $dialogText = $dialogText.Substring(0, 200) }
            $page.Dialog = @{ Type = [string]$params['type']; Message = $dialogText; Seq = $seq }
        }
    } elseif ($method -ceq 'Page.javascriptDialogClosed') {
        if ($onPage) { $page.Dialog = $null }
    } elseif ($method -ceq 'Inspector.targetCrashed') {
        if ($onPage) { $page.Crashed = $true }
    } elseif ($method -ceq 'Inspector.targetReloadedAfterCrash') {
        if ($onPage) { $page.Crashed = $false }
    } elseif ($method -ceq 'Inspector.detached') {
        if ($onPage) { $page.Gone = "detached: $([string]$params['reason'])" }
    } elseif ($method -ceq 'Target.targetCrashed') {
        if ([string]$params['targetId'] -ceq [string]$page.TargetId) { $page.Crashed = $true }
    } elseif ($method -ceq 'Target.targetDestroyed') {
        $targetId = [string]$params['targetId']
        if ($targetId -ceq [string]$page.TargetId) {
            $page.Gone = 'target closed'
        } else {
            foreach ($popup in @($page.Popups)) {
                if ([string]$popup.TargetId -ceq $targetId) { [void]$page.Popups.Remove($popup) }
            }
        }
    } elseif ($method -ceq 'Target.targetCreated') {
        if ([string]$targetInfo['type'] -ceq 'page' -and [string]$targetInfo['openerId'] -ceq [string]$page.TargetId -and [string]$page.TargetId) {
            $page.Popups.Add(@{ TargetId = [string]$targetInfo['targetId']; Url = [string]$targetInfo['url']; Seq = $seq })
        }
    } elseif ($method -ceq 'Target.attachedToTarget') {
        if ([string]$targetInfo['type'] -ceq 'iframe') {
            $page.Children[[string]$targetInfo['targetId']] = @{
                SessionId       = [string]$params['sessionId']
                ParentSessionId = [string]$Message['sessionId']
                AutoAttach      = $false
            }
        }
    } elseif ($method -ceq 'Target.detachedFromTarget') {
        $detached = [string]$params['sessionId']
        if ($detached -and $detached -ceq [string]$page.SessionId) {
            $page.Gone = 'session detached'
        } else {
            foreach ($childFrame in @($page.Children.Keys)) {
                if ([string]$page.Children[$childFrame].SessionId -ceq $detached) { $page.Children.Remove($childFrame) }
            }
        }
    } elseif ($method -ceq 'Browser.downloadWillBegin') {
        $page.DownloadSeq = $seq
    }
    if ($touch) {
        $page.NavigationSeq = $seq
        $page.NavigationUtc = Get-WebCdpNow -Connection $Connection
    }
}

function Read-WebCdpMessage {
    <#
    .SYNOPSIS
        Read at most one message: a reply is returned; an event is reduced,
        queued, and $null is returned.
    .DESCRIPTION
        A caller tells "nothing arrived" from "an event arrived" by EventSeq.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    $text = Read-WebCdpTransport -Transport $Connection.Transport -TimeoutMs ([Math]::Max(0, $TimeoutMs))
    if ($null -eq $text) { return $null }
    $message = $null
    try {
        $jsonOption = $script:WebJsonOption
        $message = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 512 -ErrorAction Stop @jsonOption
    } catch {
        throw (New-WebFailureException -Kind 'protocol' -Detail 'unparseable message')
    }
    if ($message -isnot [System.Collections.IDictionary]) { throw (New-WebFailureException -Kind 'protocol' -Detail 'unparseable message') }
    if ($message.Contains('id')) { return $message }
    if ($message.Contains('method')) {
        $Connection.EventSeq++
        $message['Seq'] = $Connection.EventSeq
        $message['At'] = Get-WebCdpNow -Connection $Connection
        Update-WebCdpPageState -Connection $Connection -Message $message
        $Connection.Events.Enqueue($message)
        while ($Connection.Events.Count -gt $script:WebLimit.MaxQueuedEvents) {
            [void]$Connection.Events.Dequeue()
            $Connection.DroppedEvents++
        }
    }
    return $null
}

function Receive-WebCdpStrayReply {
    <#
    .SYNOPSIS
        Account for a reply nobody waits for: a late reply to an abandoned id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Reply
    )
    $id = [int]$Reply['id']
    if (-not $Connection.Abandoned.Remove($id)) {
        Write-Verbose "Receive-WebCdpStrayReply: a reply to id $id arrived with no command waiting for it."
    }
}

function Sync-WebCdpEvent {
    <#
    .SYNOPSIS
        Read every message already waiting, without waiting for more.
    .DESCRIPTION
        Nothing reads the socket between two steps, so every page operation
        calls this first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Connection)
    for ($read = 0; $read -lt 500; $read++) {
        $before = $Connection.EventSeq
        $reply = Read-WebCdpMessage -Connection $Connection -TimeoutMs 0
        if ($null -ne $reply) {
            Receive-WebCdpStrayReply -Connection $Connection -Reply $reply
            continue
        }
        if ($Connection.EventSeq -eq $before) { break }
    }
}

function Wait-WebCdpIdle {
    <#
    .SYNOPSIS
        Read messages for a time on the connection's clock.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$Milliseconds
    )
    $end = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($Milliseconds)
    while ($true) {
        $leftMs = ($end - (Get-WebCdpNow -Connection $Connection)).TotalMilliseconds
        if ($leftMs -le 0) { return }
        # [double] first: with an [int] first argument PowerShell picks
        # Min(int, int) and rounds a sub-millisecond remainder to a 0 ms read,
        # which never moves a test clock.
        $reply = Read-WebCdpMessage -Connection $Connection -TimeoutMs ([int][Math]::Ceiling([Math]::Min([double]$script:WebLimit.PumpSliceMs, $leftMs)))
        if ($null -ne $reply) { Receive-WebCdpStrayReply -Connection $Connection -Reply $reply }
    }
}

# --- REGION: Commands
function Add-WebCdpAbandonedId {
    <#
    .SYNOPSIS
        Remember a command id given up on, so its late reply is dropped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$Id
    )
    if ($Connection.Abandoned.Count -ge $script:WebLimit.MaxAbandonedIds) { $Connection.Abandoned.Clear() }
    [void]$Connection.Abandoned.Add($Id)
}

function Send-WebCdpCommand {
    <#
    .SYNOPSIS
        Send one command and return its id. Only Invoke-WebCdp calls it.
    .OUTPUTS
        System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params,
        [string]$SessionId
    )
    if ($Connection.Closed) { throw (New-WebFailureException -Kind 'transport' -Detail 'connection closed') }
    $Connection.NextId++
    $id = [int]$Connection.NextId
    $message = [ordered]@{ id = $id; method = $Method }
    if ($null -ne $Params) { $message['params'] = $Params }
    if ($SessionId) { $message['sessionId'] = $SessionId }
    Write-WebCdpTransport -Transport $Connection.Transport -Text (ConvertTo-Json -InputObject $message -Depth 16 -Compress) -TimeoutMs $script:WebLimit.SendLimitMs
    return $id
}

function Wait-WebCdpReply {
    <#
    .SYNOPSIS
        Wait for the reply to one command, watching the page while it waits.
    .DESCRIPTION
        A dialog withholds every reply on its page, so it is handled here: a
        leave-page prompt is accepted when the caller asked for that, and any
        other dialog is dismissed and fails the command as unsupported. A
        crashed or gone page fails at once. At the earlier of the deadline and
        the reply limit the id is abandoned, so its late reply is dropped.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][int]$Id,
        [Parameter(Mandatory)][string]$Method,
        [string]$SessionId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [int]$ReplyLimitMs = 10000,
        [switch]$AcceptBeforeUnload
    )
    $start = Get-WebCdpNow -Connection $Connection
    $limitAt = $start.AddMilliseconds($ReplyLimitMs)
    $cutByDeadline = $DeadlineUtc -lt $limitAt
    $endAt = if ($cutByDeadline) { $DeadlineUtc } else { $limitAt }
    $watchPage = $false
    $page = $Connection.Page
    if ($page -and $SessionId) {
        if ($SessionId -ceq [string]$page.SessionId) {
            $watchPage = $true
        } else {
            foreach ($child in @($page.Children.Values)) {
                if ([string]$child.SessionId -ceq $SessionId) { $watchPage = $true }
            }
        }
    }
    while ($true) {
        $page = $Connection.Page
        if ($watchPage -and -not $Connection.InDialog -and $page) {
            if ($page.Dialog) {
                $dialogType = [string]$page.Dialog.Type
                if ($AcceptBeforeUnload -and $dialogType -ceq 'beforeunload') {
                    Resolve-WebCdpDialog -Connection $Connection -Accept
                    continue
                }
                Add-WebCdpAbandonedId -Connection $Connection -Id $Id
                Resolve-WebCdpDialog -Connection $Connection
                throw (New-WebFailureException -Kind 'unsupported' -Detail "dialog: $dialogType")
            }
            if ($page.Crashed -and $Method -cne 'Page.navigate') {
                Add-WebCdpAbandonedId -Connection $Connection -Id $Id
                throw (New-WebFailureException -Kind 'page_lost' -Detail 'crashed')
            }
            if ($page.Gone) {
                Add-WebCdpAbandonedId -Connection $Connection -Id $Id
                throw (New-WebFailureException -Kind 'page_lost' -Detail ([string]$page.Gone))
            }
        }
        $now = Get-WebCdpNow -Connection $Connection
        if ($now -ge $endAt) {
            Add-WebCdpAbandonedId -Connection $Connection -Id $Id
            throw (New-WebFailureException -Kind 'page_lost' -Detail "no reply to $Method" -Retryable -DeadlineCut:$cutByDeadline)
        }
        # [double] first, as in Wait-WebCdpIdle: never a 0 ms slice before the end.
        $sliceMs = [int][Math]::Ceiling([Math]::Min([double]$script:WebLimit.PumpSliceMs, ($endAt - $now).TotalMilliseconds))
        $reply = Read-WebCdpMessage -Connection $Connection -TimeoutMs $sliceMs
        if ($null -ne $reply) {
            if ([int]$reply['id'] -eq $Id) { return $reply }
            Receive-WebCdpStrayReply -Connection $Connection -Reply $reply
        }
    }
}

function Resolve-WebCdpDialog {
    <#
    .SYNOPSIS
        Accept or dismiss the dialog open on the page.
    .DESCRIPTION
        A dialog that closed on its own answers -32602, which counts as handled.
        A dialog the browser does not answer for leaves the page gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [switch]$Accept
    )
    $page = $Connection.Page
    $Connection.InDialog = $true
    try {
        $deadline = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.CleanupLimitMs)
        try {
            $null = Invoke-WebCdp -Connection $Connection -Method 'Page.handleJavaScriptDialog' -Params @{ accept = [bool]$Accept } `
                -SessionId ([string]$page.SessionId) -DeadlineUtc $deadline -AllowError -32602, -32000
        } catch {
            $failure = Get-WebFailureData -ErrorRecord $_
            if ($failure -and $failure.Kind -eq 'page_lost' -and $failure.Detail -ceq 'no reply to Page.handleJavaScriptDialog') {
                $page.Gone = 'dialog not handled'
            } else {
                throw
            }
        }
        $page.Dialog = $null
    } finally {
        $Connection.InDialog = $false
    }
}

function Invoke-WebCdp {
    <#
    .SYNOPSIS
        Send a command, wait for its reply and return its result.
    .DESCRIPTION
        The only caller of Send-WebCdpCommand and Wait-WebCdpReply: every
        command goes through here, so the dialog check of the wait applies to
        all of them. An error code in AllowError is returned as
        @{ ErrorCode; ErrorMessage }; -32000 (a stale node) fails as a retryable
        page_lost, -32001 as a closed session, -32099 as unsupported, and any
        other code as protocol.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Method,
        [System.Collections.IDictionary]$Params,
        [string]$SessionId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [int]$ReplyLimitMs = 10000,
        [int[]]$AllowError = @(),
        [switch]$AcceptBeforeUnload
    )
    $sendArguments = @{ Connection = $Connection; Method = $Method }
    if ($PSBoundParameters.ContainsKey('Params')) { $sendArguments['Params'] = $Params }
    if ($SessionId) { $sendArguments['SessionId'] = $SessionId }
    $id = Send-WebCdpCommand @sendArguments
    $reply = Wait-WebCdpReply -Connection $Connection -Id $id -Method $Method -SessionId $SessionId -DeadlineUtc $DeadlineUtc `
        -ReplyLimitMs $ReplyLimitMs -AcceptBeforeUnload:$AcceptBeforeUnload
    if ($reply.Contains('error')) {
        $errorPart = if ($reply['error'] -is [System.Collections.IDictionary]) { $reply['error'] } else { @{} }
        $code = 0
        [void][int]::TryParse([string]$errorPart['code'], [ref]$code)
        $message = [string]$errorPart['message']
        if ($code -in $AllowError) { return @{ ErrorCode = $code; ErrorMessage = $message } }
        if ($code -eq -32000) {
            throw (New-WebFailureException -Kind 'page_lost' -Detail "${Method}: $message" -Retryable)
        }
        if ($code -eq -32001) {
            $page = $Connection.Page
            if ($page -and $SessionId -and $SessionId -cne [string]$page.SessionId) {
                foreach ($childFrame in @($page.Children.Keys)) {
                    if ([string]$page.Children[$childFrame].SessionId -ceq $SessionId) { $page.Children.Remove($childFrame) }
                }
                throw (New-WebFailureException -Kind 'page_lost' -Detail "${Method}: $message" -Retryable)
            }
            if ($page -and $SessionId) { $page.Gone = 'session closed' }
            throw (New-WebFailureException -Kind 'page_lost' -Detail "${Method}: $message")
        }
        if ($code -eq -32099) { throw (New-WebFailureException -Kind 'unsupported' -Detail "${Method}: $message") }
        throw (New-WebFailureException -Kind 'protocol' -Detail "${Method}: $code $message")
    }
    if ($reply['result'] -is [System.Collections.IDictionary]) { return $reply['result'] }
    return @{}
}

# --- REGION: Connecting and the owned page
function Get-WebCdpVersionDocument {
    <#
    .SYNOPSIS
        GET /json/version at 127.0.0.1 on a port, without any proxy.
    .DESCRIPTION
        Always the literal 127.0.0.1, never a host name. A proxy named by the
        host's environment would otherwise receive the loopback request.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(1, 600000)][int]$TimeoutMs
    )
    $handler = $null
    $client = $null
    $response = $null
    $body = $null
    $reason = ''
    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $client = [System.Net.Http.HttpClient]::new($handler, $false)
        $client.Timeout = [TimeSpan]::FromMilliseconds($TimeoutMs)
        $response = $client.GetAsync("http://127.0.0.1:$Port/json/version").GetAwaiter().GetResult()
        if ($response.IsSuccessStatusCode) {
            $body = [string]$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        } else {
            $reason = "HTTP $([int]$response.StatusCode)"
        }
    } catch {
        $reason = [string]$_.Exception.GetBaseException().Message
    } finally {
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($handler) { $handler.Dispose() }
    }
    if ($null -eq $body) { throw (New-WebFailureException -Kind 'transport' -Detail "endpoint: $reason") }
    $document = $null
    try {
        $jsonOption = $script:WebJsonOption
        $document = ConvertFrom-Json -InputObject $body -AsHashtable -ErrorAction Stop @jsonOption
    } catch {
        throw (New-WebFailureException -Kind 'transport' -Detail "endpoint: $($_.Exception.Message)")
    }
    if ($document -isnot [System.Collections.IDictionary]) { throw (New-WebFailureException -Kind 'transport' -Detail 'endpoint: not a JSON object') }
    return $document
}

function ConvertTo-WebCdpSocketUri {
    <#
    .SYNOPSIS
        The WebSocket address of the browser at 127.0.0.1 on the local port.
    .DESCRIPTION
        Only the path of the reported URL is taken: the browser copies the Host
        header it was asked with into that URL, and the port it names is the
        guest's, not the tunnel's.
    .OUTPUTS
        System.Uri
    #>
    [CmdletBinding()]
    [OutputType([uri])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$VersionDocument,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )
    $reported = [string]$VersionDocument['webSocketDebuggerUrl']
    if (-not $reported) { throw (New-WebFailureException -Kind 'protocol' -Detail 'no webSocketDebuggerUrl') }
    $parsed = $null
    if (-not [System.Uri]::TryCreate($reported, [System.UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -cne 'ws') {
        throw (New-WebFailureException -Kind 'protocol' -Detail 'webSocketDebuggerUrl is not a ws URL')
    }
    $path = $parsed.AbsolutePath
    if ($path -cnotmatch '^/devtools/browser/[0-9A-Za-z-]{1,64}$') {
        throw (New-WebFailureException -Kind 'protocol' -Detail 'webSocketDebuggerUrl does not name the browser')
    }
    return [uri]"ws://127.0.0.1:$Port$path"
}

function Connect-WebCdp {
    <#
    .SYNOPSIS
        Connect to the browser's DevTools endpoint at 127.0.0.1 on a local port.
    .DESCRIPTION
        The socket uses no proxy and sends no Origin header (the browser refuses
        a handshake that carries one). The connection watches page targets and
        refuses downloads.
    .OUTPUTS
        System.Collections.Hashtable, the connection.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [hashtable]$Clock
    )
    $now = if ($Clock) { [datetime]$Clock.Now } else { [datetime]::UtcNow }
    $leftMs = ($DeadlineUtc - $now).TotalMilliseconds
    if ($leftMs -lt 1) { throw (New-WebFailureException -Kind 'transport' -Detail 'no time left to connect') }
    $document = Get-WebCdpVersionDocument -Port $Port -TimeoutMs ([int][Math]::Min($leftMs, $script:WebLimit.EndpointLimitMs))
    $uri = ConvertTo-WebCdpSocketUri -VersionDocument $document -Port $Port
    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.Proxy = $null
    $now = if ($Clock) { [datetime]$Clock.Now } else { [datetime]::UtcNow }
    $connectMs = [int][Math]::Max(1, [Math]::Min(($DeadlineUtc - $now).TotalMilliseconds, $script:WebLimit.ConnectLimitMs))
    $connected = $false
    $reason = 'timed out'
    try {
        $connected = $socket.ConnectAsync($uri, [System.Threading.CancellationToken]::None).Wait($connectMs)
    } catch {
        $reason = [string]$_.Exception.GetBaseException().Message
    }
    if (-not $connected) {
        try {
            $socket.Abort()
            $socket.Dispose()
        } catch {
            Write-Verbose "Connect-WebCdp: releasing the socket failed: $($_.Exception.Message)"
        }
        throw (New-WebFailureException -Kind 'transport' -Detail "connect: $reason")
    }
    $connectionArguments = @{ Transport = (New-WebCdpSocketTransport -Socket $socket) }
    if ($Clock) { $connectionArguments['Clock'] = $Clock }
    $connection = New-WebCdpConnection @connectionArguments
    try {
        $version = Invoke-WebCdp -Connection $connection -Method 'Browser.getVersion' -DeadlineUtc $DeadlineUtc
        $connection.Browser['product'] = [string]$version['product']
        $connection.Browser['protocolVersion'] = [string]$version['protocolVersion']
        $null = Invoke-WebCdp -Connection $connection -Method 'Target.setDiscoverTargets' `
            -Params @{ discover = $true; filter = @(@{ type = 'page' }) } -DeadlineUtc $DeadlineUtc
        $downloads = Invoke-WebCdp -Connection $connection -Method 'Browser.setDownloadBehavior' `
            -Params @{ behavior = 'deny'; eventsEnabled = $true } -DeadlineUtc $DeadlineUtc -AllowError -32601, -32602, -32000
        if ($downloads.Contains('ErrorCode')) {
            Write-Verbose "Connect-WebCdp: the browser refused to deny downloads: $($downloads.ErrorCode) $($downloads.ErrorMessage)"
        }
    } catch {
        Close-WebCdp -Connection $connection
        throw
    }
    return $connection
}

function Open-WebCdpPage {
    <#
    .SYNOPSIS
        Create the one page this connection owns and attach to it.
    .DESCRIPTION
        Only the Page domain is enabled; the accessibility and DOM reads answer
        without their domains. Cross-site frames attach as child sessions. A
        failure after the target exists closes it and the connection, so a
        half-opened page is never left behind as open.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $created = Invoke-WebCdp -Connection $Connection -Method 'Target.createTarget' -Params @{ url = 'about:blank' } -DeadlineUtc $DeadlineUtc
    $Connection.Page = @{
        TargetId       = [string]$created['targetId']
        SessionId      = ''
        MainFrameId    = ''
        Url            = 'about:blank'
        UnreachableUrl = ''
        Loading        = $false
        CommitSeq      = 0L
        NavigationSeq  = 0L
        NavigationUtc  = [datetime]::MinValue
        Generation     = 0
        Dialog         = $null
        Crashed        = $false
        Gone           = ''
        Popups         = [System.Collections.Generic.List[object]]::new()
        DownloadSeq    = 0L
        Children       = @{}
    }
    try {
        $attached = Invoke-WebCdp -Connection $Connection -Method 'Target.attachToTarget' `
            -Params ([ordered]@{ targetId = $Connection.Page.TargetId; flatten = $true }) -DeadlineUtc $DeadlineUtc
        $sessionId = [string]$attached['sessionId']
        $Connection.Page.SessionId = $sessionId
        $null = Invoke-WebCdp -Connection $Connection -Method 'Page.enable' -SessionId $sessionId -DeadlineUtc $DeadlineUtc
        $tree = Invoke-WebCdp -Connection $Connection -Method 'Page.getFrameTree' -SessionId $sessionId -DeadlineUtc $DeadlineUtc
        $Connection.Page.MainFrameId = [string]$tree['frameTree']['frame']['id']
        $null = Invoke-WebCdp -Connection $Connection -Method 'Target.setAutoAttach' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
            -Params ([ordered]@{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true; filter = @(@{ type = 'iframe' }) })
        $null = Invoke-WebCdp -Connection $Connection -Method 'Emulation.setFocusEmulationEnabled' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
            -Params @{ enabled = $true } -AllowError -32601
        $null = Invoke-WebCdp -Connection $Connection -Method 'Emulation.setDeviceMetricsOverride' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
            -Params ([ordered]@{ width = $script:WebLimit.ViewportWidth; height = $script:WebLimit.ViewportHeight; deviceScaleFactor = 1; mobile = $false })
    } catch {
        Close-WebCdp -Connection $Connection
        throw
    }
}

function Close-WebCdp {
    <#
    .SYNOPSIS
        Close the popups and the page this connection owns, then its transport.
    .DESCRIPTION
        Never throws and may be called twice. The closes share one cleanup limit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Connection)
    if ($null -eq $Connection -or $Connection.Closed) { return }
    try {
        $page = $Connection.Page
        if ($page -and -not $Connection.Transport.Closed) {
            $deadline = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.CleanupLimitMs)
            $targets = [System.Collections.Generic.List[string]]::new()
            foreach ($popup in @($page.Popups)) { $targets.Add([string]$popup.TargetId) }
            if (-not $page.Gone -and $page.TargetId) { $targets.Add([string]$page.TargetId) }
            foreach ($targetId in $targets) {
                try {
                    $null = Invoke-WebCdp -Connection $Connection -Method 'Target.closeTarget' -Params @{ targetId = $targetId } `
                        -DeadlineUtc $deadline -AllowError -32602, -32000, -32001
                } catch {
                    Write-Verbose "Close-WebCdp: target $targetId did not close: $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Verbose "Close-WebCdp: closing the page targets failed: $($_.Exception.Message)"
    }
    Close-WebCdpTransport -Transport $Connection.Transport
    $Connection.Closed = $true
    $Connection.Page = $null
}

function Test-WebCdpOpen {
    <#
    .SYNOPSIS
        $true while a connection and its page can take commands.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Connection)
    if ($null -eq $Connection -or $Connection.Closed) { return $false }
    if ($null -eq $Connection.Transport -or $Connection.Transport.Closed) { return $false }
    $page = $Connection.Page
    return [bool]($page -and $page.SessionId -and -not $page.Gone)
}

# --- REGION: Reading the page
function ConvertTo-WebName {
    <#
    .SYNOPSIS
        A name or text as the locator compares it: Unicode form C, without
        zero-width spaces and soft hyphens, white space runs as one space, trimmed.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return '' }
    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormC)
    $normalized = $normalized.Replace([string][char]0x200B, '').Replace([string][char]0x00AD, '')
    return ([regex]::Replace($normalized, '\s+', ' ')).Trim()
}

function Close-WebPagePopup {
    <#
    .SYNOPSIS
        Close every window the page opened. A close that gets no reply leaves its
        entry in the list; the others are still closed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Connection)
    $page = $Connection.Page
    foreach ($popup in @($page.Popups)) {
        try {
            $null = Invoke-WebCdp -Connection $Connection -Method 'Target.closeTarget' -Params @{ targetId = [string]$popup.TargetId } `
                -DeadlineUtc ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.CleanupLimitMs)) -AllowError -32602
            [void]$page.Popups.Remove($popup)
        } catch {
            $failure = Get-WebFailureData -ErrorRecord $_
            if ($failure -and $failure.Kind -eq 'page_lost' -and $failure.Detail -ceq 'no reply to Target.closeTarget') {
                Write-Verbose "Close-WebPagePopup: window $($popup.TargetId) did not answer its close."
            } else {
                throw
            }
        }
    }
}

function Assert-WebPageUsable {
    <#
    .SYNOPSIS
        Fail when the page shows a dialog, opened a window, crashed or is gone;
        a dialog is dismissed and windows are closed first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Connection)
    $page = $Connection.Page
    if ($null -eq $page) { throw (New-WebFailureException -Kind 'page_lost' -Detail 'no page') }
    if ($page.Dialog) {
        $dialogType = [string]$page.Dialog.Type
        Resolve-WebCdpDialog -Connection $Connection
        throw (New-WebFailureException -Kind 'unsupported' -Detail "dialog: $dialogType")
    }
    if ($page.Popups.Count -gt 0) {
        Close-WebPagePopup -Connection $Connection
        throw (New-WebFailureException -Kind 'unsupported' -Detail 'popup')
    }
    if ($page.Crashed) { throw (New-WebFailureException -Kind 'page_lost' -Detail 'crashed') }
    if ($page.Gone) { throw (New-WebFailureException -Kind 'page_lost' -Detail ([string]$page.Gone)) }
}

function Read-WebFrameTree {
    <#
    .SYNOPSIS
        Append the entries and text of one frame to a forest under construction.
    .DESCRIPTION
        Walks the accessibility tree from its root over childIds with an
        explicit stack: the nodes array is not in document order. A frame's
        content is read where its iframe stands, so forest order is document
        order across frames.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'Node ids are keyed ordinally; a literal hashtable compares keys without regard to case.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SessionId,
        [AllowEmptyString()][string]$FrameId = '',
        [int]$Depth = 0,
        [AllowEmptyCollection()][object[]]$Owners = @(),
        [int]$FrameDepth = 0,
        [bool]$InTextControl = $false
    )
    $axParams = if ($FrameId) { @{ frameId = $FrameId } } else { @{} }
    $tree = Invoke-WebCdp -Connection $Connection -Method 'Accessibility.getFullAXTree' -Params $axParams -SessionId $SessionId `
        -DeadlineUtc $State.DeadlineUtc -AllowError -32602, -32000
    if ($tree.Contains('ErrorCode')) {
        $State.Incomplete = $true
        return
    }
    $byId = [hashtable]::new([StringComparer]::Ordinal)
    $root = $null
    foreach ($node in @($tree['nodes'])) {
        if ($node -isnot [System.Collections.IDictionary]) { continue }
        $byId[[string]$node['nodeId']] = $node
        if ($null -eq $root -and -not $node.Contains('parentId')) { $root = $node }
    }
    if ($null -eq $root) { return }
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Node = $root; Depth = $Depth; InText = $InTextControl; Leave = $false })
    while ($stack.Count -gt 0) {
        if ($State.Truncated) { return }
        $item = $stack.Pop()
        if ($item.Leave) {
            [void]$State.Text.Append(' ')
            continue
        }
        $node = $item.Node
        $role = if ($node['role'] -is [System.Collections.IDictionary]) { [string]$node['role']['value'] } else { '' }
        if ($role -ceq 'InlineTextBox') { continue }
        $childNodes = [System.Collections.Generic.List[object]]::new()
        foreach ($childId in @($node['childIds'])) {
            if ($null -eq $childId) { continue }
            $childNode = $byId[[string]$childId]
            if ($null -ne $childNode) { $childNodes.Add($childNode) }
        }
        if ([bool]$node['ignored']) {
            for ($i = $childNodes.Count - 1; $i -ge 0; $i--) {
                $stack.Push(@{ Node = $childNodes[$i]; Depth = $item.Depth; InText = $item.InText; Leave = $false })
            }
            continue
        }
        if ($State.Entries.Count -ge $script:WebLimit.MaxForestEntries) {
            $State.Truncated = $true
            return
        }
        $name = if ($node['name'] -is [System.Collections.IDictionary]) { [string]$node['name']['value'] } else { '' }
        $props = @{}
        foreach ($property in @($node['properties'])) {
            if ($property -isnot [System.Collections.IDictionary]) { continue }
            $props[[string]$property['name']] = if ($property['value'] -is [System.Collections.IDictionary]) { $property['value']['value'] } else { $null }
        }
        $value = if ($node['value'] -is [System.Collections.IDictionary]) { $node['value']['value'] } else { $null }
        $backend = 0
        if ($node.Contains('backendDOMNodeId')) { [void][int]::TryParse([string]$node['backendDOMNodeId'], [ref]$backend) }
        $State.Entries.Add(@{
            Role          = $role
            Name          = $name
            Norm          = ConvertTo-WebName -Text $name
            Depth         = $item.Depth
            Props         = $props
            Value         = $value
            InTextControl = [bool]$item.InText
            Address       = @{ SessionId = $SessionId; BackendNodeId = $backend; Owners = [object[]]@($Owners) }
        })
        if ($role -ceq 'StaticText') {
            if (-not $item.InText) { [void]$State.Text.Append($name) }
            continue
        }
        if ($role -ceq 'LineBreak') {
            [void]$State.Text.Append(' ')
            continue
        }
        $inline = $role -cin $script:WebInlineRole
        if (-not $inline) {
            [void]$State.Text.Append(' ')
            $stack.Push(@{ Leave = $true })
        }
        if ($role -ceq 'Iframe' -or $role -ceq 'IframePresentational') {
            if ($backend -gt 0) {
                $described = Invoke-WebCdp -Connection $Connection -Method 'DOM.describeNode' -Params ([ordered]@{ backendNodeId = $backend; depth = 0 }) `
                    -SessionId $SessionId -DeadlineUtc $State.DeadlineUtc -AllowError -32000
                if ($described.Contains('ErrorCode')) {
                    $State.Incomplete = $true
                } elseif ($FrameDepth -ge $script:WebLimit.MaxFrameDepth) {
                    $State.Incomplete = $true
                } else {
                    $childFrameId = if ($described['node'] -is [System.Collections.IDictionary]) { [string]$described['node']['frameId'] } else { '' }
                    $children = $Connection.Page.Children
                    if (-not $childFrameId) {
                        $State.Incomplete = $true
                    } elseif ($children.ContainsKey($childFrameId)) {
                        $owner = @{ SessionId = $SessionId; BackendNodeId = $backend }
                        Read-WebFrameTree -Connection $Connection -State $State -SessionId ([string]$children[$childFrameId].SessionId) -FrameId '' `
                            -Depth ($item.Depth + 1) -Owners ([object[]](@($Owners) + , $owner)) -FrameDepth ($FrameDepth + 1) -InTextControl ([bool]$item.InText)
                    } else {
                        Read-WebFrameTree -Connection $Connection -State $State -SessionId $SessionId -FrameId $childFrameId `
                            -Depth ($item.Depth + 1) -Owners $Owners -FrameDepth ($FrameDepth + 1) -InTextControl ([bool]$item.InText)
                    }
                }
            }
            continue
        }
        $childInText = [bool]$item.InText -or ($role -cin $script:WebTextControlRole)
        for ($i = $childNodes.Count - 1; $i -ge 0; $i--) {
            $stack.Push(@{ Node = $childNodes[$i]; Depth = $item.Depth + 1; InText = $childInText; Leave = $false })
        }
    }
}

function Read-WebPageForest {
    <#
    .SYNOPSIS
        The page as its accessibility tree shows it, across frames: entries in
        document order, the page text, the title, the URL.
    .DESCRIPTION
        Fails first when the page shows a dialog (dismissed), opened a window
        (closed), crashed or is gone. Text of hidden content is absent, runs of
        one line join without a space, blocks join with one space, and field
        values are not part of the text.
    .OUTPUTS
        System.Collections.Hashtable: Entries, Text, Title, Url, Generation,
        Incomplete, Truncated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    Sync-WebCdpEvent -Connection $Connection
    Assert-WebPageUsable -Connection $Connection
    $page = $Connection.Page
    foreach ($childFrame in @($page.Children.Keys)) {
        $child = $page.Children[$childFrame]
        if ($null -eq $child -or $child.AutoAttach) { continue }
        $answer = Invoke-WebCdp -Connection $Connection -Method 'Target.setAutoAttach' -SessionId ([string]$child.SessionId) -DeadlineUtc $DeadlineUtc `
            -Params ([ordered]@{ autoAttach = $true; waitForDebuggerOnStart = $false; flatten = $true; filter = @(@{ type = 'iframe' }) }) -AllowError -32001, -32601
        if ($answer.Contains('ErrorCode') -and [int]$answer.ErrorCode -eq -32001) {
            $page.Children.Remove($childFrame)
        } else {
            $child.AutoAttach = $true
        }
    }
    $state = @{
        Entries    = [System.Collections.Generic.List[object]]::new()
        Text       = [System.Text.StringBuilder]::new()
        Incomplete = $false
        Truncated  = $false
        DeadlineUtc = $DeadlineUtc
    }
    Read-WebFrameTree -Connection $Connection -State $state -SessionId ([string]$page.SessionId)
    $title = ''
    foreach ($entry in $state.Entries) {
        if ($entry.Role -ceq 'RootWebArea') {
            $title = $entry.Norm
            break
        }
    }
    $page = $Connection.Page
    return @{
        Entries    = [object[]]$state.Entries.ToArray()
        Text       = ConvertTo-WebName -Text $state.Text.ToString()
        Title      = $title
        Url        = if ($page) { [string]$page.Url } else { '' }
        Generation = if ($page) { [int]$page.Generation } else { 0 }
        Incomplete = [bool]$state.Incomplete
        Truncated  = [bool]$state.Truncated
    }
}

function ConvertTo-WebSnapshotTagValue {
    <#
    .SYNOPSIS
        A property value as a snapshot tag writes it: a boolean in lower case,
        anything else as its text.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    return [string]$Value
}

function Add-WebSnapshotTextRun {
    <#
    .SYNOPSIS
        Add a finished text run to the display entries, unless it is empty,
        lies in a text control, or the shown node above it already names it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Display,
        [Parameter(Mandatory)][hashtable]$Run
    )
    $runName = ConvertTo-WebName -Text $Run.Text.ToString()
    if (-not $runName -or $Run.InText) { return }
    $owner = $Run.Parent
    if ($null -ne $owner -and ([string]$owner.Norm).IndexOf($runName, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return }
    $Display.Add(@{ Kind = 'text'; Indent = $Run.Indent; Role = 'StaticText'; Name = $runName; Tags = [string[]]@(); Address = $null })
}

function Get-WebPageSnapshotEntry {
    <#
    .SYNOPSIS
        The display entries of a page snapshot, from a page forest.
    .DESCRIPTION
        Pure. An entry's ancestors are the nearest earlier forest entries of
        smaller depth. The document root and list markers are never shown;
        unnamed wrappers and unnamed inline roles other than link are
        transparent, and their children take their place. StaticText and
        LineBreak entries merge into text runs, joined by the rule that builds
        the page text: a space where a block stands between two pieces of
        text or their nearest block ancestors differ. A run ends at the next
        shown node or a change of shown ancestor; it is left out when it is
        empty, lies in a text control, or the shown node above it already
        names it.
    .OUTPUTS
        System.Object[]: hashtables Kind (node or text), Indent, Role, Name,
        Tags, Address.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Forest)
    $neverShown = @('RootWebArea', 'ListMarker')
    $transparent = @('generic', 'none', 'presentation', 'LabelText', 'paragraph', 'MenuListPopup') +
        @($script:WebInlineRole | Where-Object { $_ -cne 'link' })
    $valueRole = @('textbox', 'searchbox', 'spinbutton', 'combobox', 'slider')
    $display = [System.Collections.Generic.List[object]]::new()
    # Ancestors of the current entry, outermost first: @{ Entry; Shown }.
    $ancestors = [System.Collections.Generic.List[object]]::new()
    $run = $null
    foreach ($entry in @($Forest.Entries)) {
        if ($null -eq $entry) { continue }
        $depth = [int]$entry.Depth
        while ($ancestors.Count -gt 0 -and [int]$ancestors[$ancestors.Count - 1].Entry.Depth -ge $depth) { $ancestors.RemoveAt($ancestors.Count - 1) }
        $shownAbove = @($ancestors | Where-Object { $_.Shown })
        $parent = if ($shownAbove.Count -gt 0) { $shownAbove[$shownAbove.Count - 1].Entry } else { $null }
        $role = [string]$entry.Role
        if ($role -ceq 'StaticText' -or $role -ceq 'LineBreak') {
            if ($null -ne $run -and -not [object]::ReferenceEquals($run.Parent, $parent)) {
                Add-WebSnapshotTextRun -Display $display -Run $run
                $run = $null
            }
            if ($null -eq $run) {
                $run = @{ Parent = $parent; Indent = $shownAbove.Count; Text = [System.Text.StringBuilder]::new(); InText = $false
                    HasText = $false; Separated = $false; Block = $null }
            }
            if ([bool]$entry.InTextControl) { $run.InText = $true }
            if ($role -ceq 'LineBreak') {
                [void]$run.Text.Append(' ')
                $run.Separated = $true
            } else {
                $block = $null
                for ($i = $ancestors.Count - 1; $i -ge 0; $i--) {
                    if ([string]$ancestors[$i].Entry.Role -cnotin $script:WebInlineRole) {
                        $block = $ancestors[$i].Entry
                        break
                    }
                }
                if ($run.HasText -and ($run.Separated -or -not [object]::ReferenceEquals($run.Block, $block))) { [void]$run.Text.Append(' ') }
                [void]$run.Text.Append([string]$entry.Name)
                $run.HasText = $true
                $run.Separated = $false
                $run.Block = $block
            }
            $ancestors.Add(@{ Entry = $entry; Shown = $false })
            continue
        }
        $norm = [string]$entry.Norm
        $shown = ($role -cnotin $neverShown) -and -not (($role -cin $transparent) -and -not $norm)
        if (-not $shown) {
            if ($null -ne $run -and $role -cnotin $script:WebInlineRole) { $run.Separated = $true }
            $ancestors.Add(@{ Entry = $entry; Shown = $false })
            continue
        }
        if ($null -ne $run) { Add-WebSnapshotTextRun -Display $display -Run $run }
        $run = $null
        $props = if ($entry.Props -is [System.Collections.IDictionary]) { $entry.Props } else { @{} }
        $tags = [System.Collections.Generic.List[string]]::new()
        if ($role -ceq 'heading' -and $props.Contains('level') -and $null -ne $props['level']) { $tags.Add("level=$([int]$props['level'])") }
        if ($props.Contains('checked') -and $null -ne $props['checked']) { $tags.Add('checked=' + (ConvertTo-WebSnapshotTagValue -Value $props['checked'])) }
        if ($props['disabled'] -eq $true) { $tags.Add('disabled=true') }
        if ($props.Contains('expanded') -and $null -ne $props['expanded']) { $tags.Add('expanded=' + (ConvertTo-WebSnapshotTagValue -Value $props['expanded'])) }
        if ($props['selected'] -eq $true) { $tags.Add('selected=true') }
        if ($props.Contains('pressed') -and $null -ne $props['pressed']) { $tags.Add('pressed=' + (ConvertTo-WebSnapshotTagValue -Value $props['pressed'])) }
        if ($role -cin $valueRole) {
            $fieldValue = ConvertTo-WebName -Text ([string]$entry.Value)
            if ($fieldValue) {
                if ($fieldValue.Length -gt 80) { $fieldValue = $fieldValue.Substring(0, 80) }
                $tags.Add('value="' + $fieldValue.Replace('\', '\\').Replace('"', '\"') + '"')
            }
        }
        $address = $null
        if ($entry.Address -is [System.Collections.IDictionary] -and [int]$entry.Address.BackendNodeId -gt 0) { $address = $entry.Address }
        $display.Add(@{ Kind = 'node'; Indent = $shownAbove.Count; Role = $role; Name = $norm; Tags = [string[]]$tags.ToArray(); Address = $address })
        $ancestors.Add(@{ Entry = $entry; Shown = $true })
    }
    if ($null -ne $run) { Add-WebSnapshotTextRun -Display $display -Run $run }
    return , $display.ToArray()
}

# --- REGION: Locator
function Find-WebElement {
    <#
    .SYNOPSIS
        The forest entries with a role and a name, in document order.
    .DESCRIPTION
        The role is compared exactly (img is read as image); the name, after
        ConvertTo-WebName, as a whole or, with -Match contains, as a part,
        without regard to case. Only entries backed by a DOM node are returned.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Forest,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [ValidateSet('exact', 'contains')][string]$Match = 'exact'
    )
    $want = ConvertTo-WebName -Text $Name
    $wantRole = if ($Role -ceq 'img') { 'image' } else { $Role }
    $found = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Forest.Entries)) {
        if ($null -eq $entry -or [int]$entry.Address.BackendNodeId -le 0) { continue }
        if ([string]$entry.Role -cne $wantRole) { continue }
        $hit = if ($Match -eq 'contains') {
            ([string]$entry.Norm).IndexOf($want, [StringComparison]::OrdinalIgnoreCase) -ge 0
        } else {
            [string]::Equals([string]$entry.Norm, $want, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($hit) { $found.Add($entry) }
    }
    return , $found.ToArray()
}

function Test-WebPageText {
    <#
    .SYNOPSIS
        Whether the page text holds a text, without regard to case and white space.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Forest,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    return ([string]$Forest.Text).IndexOf((ConvertTo-WebName -Text $Text), [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-WebQuadArea {
    <#
    .SYNOPSIS
        The area of a four-corner quad (shoelace formula).
    .OUTPUTS
        System.Double
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Quad)
    if ($null -eq $Quad -or $Quad.Count -lt 8) { return 0.0 }
    $sum = 0.0
    for ($i = 0; $i -lt 4; $i++) {
        $j = ($i + 1) % 4
        $sum += ([double]$Quad[2 * $i] * [double]$Quad[2 * $j + 1]) - ([double]$Quad[2 * $j] * [double]$Quad[2 * $i + 1])
    }
    return [Math]::Abs($sum) / 2.0
}

function Get-WebBoxQuad {
    <#
    .SYNOPSIS
        The first content quad of a node whose area is 1 or more, or $null.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$BackendNodeId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [int[]]$AllowError = @()
    )
    $answer = Invoke-WebCdp -Connection $Connection -Method 'DOM.getContentQuads' -Params @{ backendNodeId = $BackendNodeId } `
        -SessionId $SessionId -DeadlineUtc $DeadlineUtc -AllowError $AllowError
    if ($answer.Contains('ErrorCode')) { return $null }
    foreach ($quad in @($answer['quads'])) {
        if ($null -eq $quad) { continue }
        $corners = [object[]]@($quad)
        if ((Get-WebQuadArea -Quad $corners) -ge 1) { return , $corners }
    }
    return $null
}

function ConvertTo-WebAxEntry {
    <#
    .SYNOPSIS
        A forest entry for one accessibility node of the top document.
    .OUTPUTS
        System.Collections.Hashtable
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Node,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$BackendNodeId
    )
    $name = if ($Node['name'] -is [System.Collections.IDictionary]) { [string]$Node['name']['value'] } else { '' }
    $props = @{}
    foreach ($property in @($Node['properties'])) {
        if ($property -isnot [System.Collections.IDictionary]) { continue }
        $props[[string]$property['name']] = if ($property['value'] -is [System.Collections.IDictionary]) { $property['value']['value'] } else { $null }
    }
    return @{
        Role          = if ($Node['role'] -is [System.Collections.IDictionary]) { [string]$Node['role']['value'] } else { '' }
        Name          = $name
        Norm          = ConvertTo-WebName -Text $name
        Depth         = 0
        Props         = $props
        Value         = if ($Node['value'] -is [System.Collections.IDictionary]) { $Node['value']['value'] } else { $null }
        InTextControl = $false
        Address       = @{ SessionId = $SessionId; BackendNodeId = $BackendNodeId; Owners = [object[]]@() }
    }
}

function Find-WebCssElement {
    <#
    .SYNOPSIS
        The visible elements a CSS selector matches in the page's top document,
        in document order. Frames and shadow roots are not entered.
    .OUTPUTS
        System.Object[]
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Selector,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $sessionId = [string]$Connection.Page.SessionId
    # Every call: a later DOM.getDocument makes earlier node ids stale.
    $document = Invoke-WebCdp -Connection $Connection -Method 'DOM.getDocument' -Params @{ depth = 0 } -SessionId $sessionId -DeadlineUtc $DeadlineUtc
    $rootId = [int]$document['root']['nodeId']
    $selected = Invoke-WebCdp -Connection $Connection -Method 'DOM.querySelectorAll' -Params ([ordered]@{ nodeId = $rootId; selector = $Selector }) `
        -SessionId $sessionId -DeadlineUtc $DeadlineUtc -AllowError -32000
    if ($selected.Contains('ErrorCode')) { throw (New-WebFailureException -Kind 'invalid_step' -Detail "css: $($selected.ErrorMessage)") }
    $found = [System.Collections.Generic.List[object]]::new()
    $examined = 0
    foreach ($nodeId in @($selected['nodeIds'])) {
        if ($null -eq $nodeId) { continue }
        if ($examined -ge $script:WebLimit.MaxCssMatches) { break }
        $examined++
        $described = Invoke-WebCdp -Connection $Connection -Method 'DOM.describeNode' -Params ([ordered]@{ nodeId = [int]$nodeId; depth = 0 }) `
            -SessionId $sessionId -DeadlineUtc $DeadlineUtc -AllowError -32000
        if ($described.Contains('ErrorCode')) { continue }
        $backend = [int]$described['node']['backendNodeId']
        $partial = Invoke-WebCdp -Connection $Connection -Method 'Accessibility.getPartialAXTree' -Params ([ordered]@{ backendNodeId = $backend; fetchRelatives = $false }) `
            -SessionId $sessionId -DeadlineUtc $DeadlineUtc -AllowError -32000
        if ($partial.Contains('ErrorCode')) { continue }
        $axNode = @($partial['nodes'])[0]
        if ($axNode -isnot [System.Collections.IDictionary]) { continue }
        $hidden = $false
        foreach ($reason in @($axNode['ignoredReasons'])) {
            if ($reason -is [System.Collections.IDictionary] -and [string]$reason['name'] -cin @('notRendered', 'notVisible')) { $hidden = $true }
        }
        if ($hidden) { continue }
        $quad = Get-WebBoxQuad -Connection $Connection -SessionId $sessionId -BackendNodeId $backend -DeadlineUtc $DeadlineUtc -AllowError -32000
        if ($null -eq $quad) { continue }
        $found.Add((ConvertTo-WebAxEntry -Node $axNode -SessionId $sessionId -BackendNodeId $backend))
    }
    return , $found.ToArray()
}

function Get-WebLocatorNth {
    <#
    .SYNOPSIS
        The nth of a locator as an integer, 0 when absent.
    .OUTPUTS
        System.Int32
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Locator)
    $nth = 0
    if ($null -ne $Locator['nth']) { [void][int]::TryParse([string]$Locator['nth'], [ref]$nth) }
    return $nth
}

function Find-WebTarget {
    <#
    .SYNOPSIS
        One attempt to find the element a locator names.
    .DESCRIPTION
        Target is the nth match, or the one match without nth. Two or more
        matches without nth fail at once as ambiguous. An incomplete forest
        without a target gives Target $null, so the caller polls again.
    .OUTPUTS
        System.Collections.Hashtable: Forest, Matches, Target.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $nth = Get-WebLocatorNth -Locator $Locator
    $forest = $null
    if ($Locator['css']) {
        $found = Find-WebCssElement -Connection $Connection -Selector ([string]$Locator['css']) -DeadlineUtc $DeadlineUtc
    } else {
        $forest = Read-WebPageForest -Connection $Connection -DeadlineUtc $DeadlineUtc
        $matchMode = if ($Locator['match']) { [string]$Locator['match'] } else { 'exact' }
        $found = Find-WebElement -Forest $forest -Role ([string]$Locator['role']) -Name ([string]$Locator['name']) -Match $matchMode
    }
    $target = $null
    if ($nth -gt 0) {
        if ($found.Count -ge $nth) { $target = $found[$nth - 1] }
    } elseif ($found.Count -eq 1) {
        $target = $found[0]
    } elseif ($found.Count -gt 1) {
        $listed = @($found | Select-Object -First $script:WebLimit.MaxCandidates | ForEach-Object { @{ role = [string]$_.Role; name = [string]$_.Name } })
        throw (New-WebFailureException -Kind 'ambiguous' -Detail "$($found.Count) matches" -Candidates $listed -MatchCount $found.Count)
    }
    return @{ Forest = $forest; Matches = $found; Target = $target }
}

# --- REGION: Where to click
function Get-WebPagePoint {
    <#
    .SYNOPSIS
        The page viewport point of a node: the center of its first content quad
        plus the content origin of each owner frame, and those origins.
    .OUTPUTS
        System.Collections.Hashtable: X, Y, Origins.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Address,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $quad = Get-WebBoxQuad -Connection $Connection -SessionId ([string]$Address.SessionId) -BackendNodeId ([int]$Address.BackendNodeId) -DeadlineUtc $DeadlineUtc
    if ($null -eq $quad) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'no box' -Retryable) }
    $x = ([double]$quad[0] + [double]$quad[2] + [double]$quad[4] + [double]$quad[6]) / 4.0
    $y = ([double]$quad[1] + [double]$quad[3] + [double]$quad[5] + [double]$quad[7]) / 4.0
    $owners = @($Address.Owners)
    $origins = [object[]]::new($owners.Count)
    for ($i = $owners.Count - 1; $i -ge 0; $i--) {
        $box = Invoke-WebCdp -Connection $Connection -Method 'DOM.getBoxModel' -Params @{ backendNodeId = [int]$owners[$i].BackendNodeId } `
            -SessionId ([string]$owners[$i].SessionId) -DeadlineUtc $DeadlineUtc
        $content = @($box['model']['content'])
        $origin = @{ X = [double]$content[0]; Y = [double]$content[1] }
        $origins[$i] = $origin
        $x += $origin.X
        $y += $origin.Y
    }
    return @{ X = $x; Y = $y; Origins = $origins }
}

function Get-WebNodeLabel {
    <#
    .SYNOPSIS
        A node as <NODENAME id=<id> class=<class>>, cut at 80 characters inside
        the brackets.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$BackendNodeId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $described = Invoke-WebCdp -Connection $Connection -Method 'DOM.describeNode' -Params ([ordered]@{ backendNodeId = $BackendNodeId; depth = 0 }) `
        -SessionId $SessionId -DeadlineUtc $DeadlineUtc
    $node = $described['node']
    $label = [string]$node['nodeName']
    $attributes = @($node['attributes'])
    foreach ($wanted in 'id', 'class') {
        for ($i = 0; $i + 1 -lt $attributes.Count; $i += 2) {
            if ([string]$attributes[$i] -ceq $wanted) {
                $label += " $wanted=$([string]$attributes[$i + 1])"
                break
            }
        }
    }
    if ($label.Length -gt 80) { $label = $label.Substring(0, 80) }
    return "<$label>"
}

function Test-WebNodeInSubtree {
    <#
    .SYNOPSIS
        Whether a node lies in the subtree of another, shadow roots and pseudo
        elements included.
    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][int]$BackendNodeId,
        [Parameter(Mandatory)][int]$CandidateNodeId,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $described = Invoke-WebCdp -Connection $Connection -Method 'DOM.describeNode' -Params ([ordered]@{ backendNodeId = $BackendNodeId; depth = -1; pierce = $true }) `
        -SessionId $SessionId -DeadlineUtc $DeadlineUtc
    $pending = [System.Collections.Generic.Stack[object]]::new()
    if ($described['node'] -is [System.Collections.IDictionary]) { $pending.Push($described['node']) }
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($node.Contains('backendNodeId') -and [int]$node['backendNodeId'] -eq $CandidateNodeId) { return $true }
        foreach ($member in 'children', 'shadowRoots', 'pseudoElements') {
            foreach ($inner in @($node[$member])) {
                if ($inner -is [System.Collections.IDictionary]) { $pending.Push($inner) }
            }
        }
    }
    return $false
}

function Resolve-WebClickPoint {
    <#
    .SYNOPSIS
        Where a click reaches an element: a point in page viewport coordinates
        that is steady, inside the viewport and not covered.
    .DESCRIPTION
        The hit test runs down the owner chain, each session asked in whole
        document coordinates of its own root frame. A failure is a retryable
        not_actionable (moving, no box, outside viewport, covered by <...>,
        nothing at point); a stale node is a retryable page_lost.
    .OUTPUTS
        System.Collections.Hashtable: X, Y.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Address,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $targetSession = [string]$Address.SessionId
    $targetNode = [int]$Address.BackendNodeId
    $null = Invoke-WebCdp -Connection $Connection -Method 'DOM.scrollIntoViewIfNeeded' -Params @{ backendNodeId = $targetNode } `
        -SessionId $targetSession -DeadlineUtc $DeadlineUtc
    $first = Get-WebPagePoint -Connection $Connection -Address $Address -DeadlineUtc $DeadlineUtc
    Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.StableGapMs
    $point = Get-WebPagePoint -Connection $Connection -Address $Address -DeadlineUtc $DeadlineUtc
    if ([Math]::Abs($point.X - $first.X) -gt 1 -or [Math]::Abs($point.Y - $first.Y) -gt 1) {
        throw (New-WebFailureException -Kind 'not_actionable' -Detail 'moving' -Retryable)
    }
    $pageSession = [string]$Connection.Page.SessionId
    $metrics = Invoke-WebCdp -Connection $Connection -Method 'Page.getLayoutMetrics' -SessionId $pageSession -DeadlineUtc $DeadlineUtc
    $viewport = $metrics['cssLayoutViewport']
    if ($point.X -lt 0 -or $point.Y -lt 0 -or $point.X -ge [double]$viewport['clientWidth'] -or $point.Y -ge [double]$viewport['clientHeight']) {
        throw (New-WebFailureException -Kind 'not_actionable' -Detail 'outside viewport' -Retryable)
    }
    $owners = @($Address.Owners)
    $count = $owners.Count
    $offsetX = 0.0
    $offsetY = 0.0
    for ($i = 0; $i -le $count; $i++) {
        $session = if ($i -lt $count) { [string]$owners[$i].SessionId } else { $targetSession }
        if ($i -gt 0) {
            $offsetX += [double]$point.Origins[$i - 1].X
            $offsetY += [double]$point.Origins[$i - 1].Y
        }
        $local = Invoke-WebCdp -Connection $Connection -Method 'Page.getLayoutMetrics' -SessionId $session -DeadlineUtc $DeadlineUtc
        $layout = $local['cssLayoutViewport']
        $hitParams = [ordered]@{
            x                         = [int][Math]::Floor($point.X - $offsetX + [double]$layout['pageX'])
            y                         = [int][Math]::Floor($point.Y - $offsetY + [double]$layout['pageY'])
            includeUserAgentShadowDOM = $false
            ignorePointerEventsNone   = $false
        }
        $hit = Invoke-WebCdp -Connection $Connection -Method 'DOM.getNodeForLocation' -Params $hitParams -SessionId $session `
            -DeadlineUtc $DeadlineUtc -AllowError -32000
        if ($hit.Contains('ErrorCode')) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'nothing at point' -Retryable) }
        $hitNode = [int]$hit['backendNodeId']
        $expected = if ($i -lt $count) { [int]$owners[$i].BackendNodeId } else { $targetNode }
        if ($hitNode -eq $expected) { continue }
        if ($i -eq $count) {
            if (Test-WebNodeInSubtree -Connection $Connection -SessionId $session -BackendNodeId $targetNode -CandidateNodeId $hitNode -DeadlineUtc $DeadlineUtc) { continue }
        }
        $cover = Get-WebNodeLabel -Connection $Connection -SessionId $session -BackendNodeId $hitNode -DeadlineUtc $DeadlineUtc
        throw (New-WebFailureException -Kind 'not_actionable' -Detail "covered by $cover" -Retryable)
    }
    return @{ X = $point.X; Y = $point.Y }
}

# --- REGION: Input
function Send-WebMouseClick {
    <#
    .SYNOPSIS
        One left click at a page viewport point: move, press, release.
    .DESCRIPTION
        Dispatched is set before the first event and Acknowledged after the
        reply to the release, so a click whose delivery is unknown reads as
        uncertain and is never repeated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][double]$X,
        [Parameter(Mandatory)][double]$Y,
        [Parameter(Mandatory)][hashtable]$Effect,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $sessionId = [string]$Connection.Page.SessionId
    $Effect.Dispatched = $true
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchMouseEvent' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
        -Params ([ordered]@{ type = 'mouseMoved'; x = $X; y = $Y; button = 'none'; buttons = 0 })
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchMouseEvent' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
        -Params ([ordered]@{ type = 'mousePressed'; x = $X; y = $Y; button = 'left'; buttons = 1; clickCount = 1 })
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchMouseEvent' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
        -Params ([ordered]@{ type = 'mouseReleased'; x = $X; y = $Y; button = 'left'; buttons = 0; clickCount = 1 })
    $Effect.Acknowledged = $true
}

function Send-WebKey {
    <#
    .SYNOPSIS
        Press and release one key of the webPress table on whatever has focus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][hashtable]$Effect,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $row = $script:WebKey[$Key]
    if ($null -eq $row) { throw (New-WebFailureException -Kind 'invalid_step' -Detail "key $Key") }
    $sessionId = [string]$Connection.Page.SessionId
    # No nativeVirtualKeyCode: Chrome runs its own shortcuts on a key event that carries
    # one (F5 reloads the page), and a page step presses keys for the page only.
    $down = [ordered]@{ type = $row.Down; key = $row.Key; code = $row.Code; windowsVirtualKeyCode = $row.VirtualKey }
    if ($null -ne $row.Text) {
        $down['text'] = $row.Text
        $down['unmodifiedText'] = $row.Text
    }
    $up = [ordered]@{ type = 'keyUp'; key = $row.Key; code = $row.Code; windowsVirtualKeyCode = $row.VirtualKey }
    $Effect.Dispatched = $true
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchKeyEvent' -Params $down -SessionId $sessionId -DeadlineUtc $DeadlineUtc
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchKeyEvent' -Params $up -SessionId $sessionId -DeadlineUtc $DeadlineUtc
    $Effect.Acknowledged = $true
}

function Send-WebSelectAll {
    <#
    .SYNOPSIS
        Select the whole content of the focused field, as Ctrl+A does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $sessionId = [string]$Connection.Page.SessionId
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchKeyEvent' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
        -Params ([ordered]@{ type = 'rawKeyDown'; key = 'a'; code = 'KeyA'; windowsVirtualKeyCode = 65; modifiers = 2; commands = @('selectAll') })
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.dispatchKeyEvent' -SessionId $sessionId -DeadlineUtc $DeadlineUtc `
        -Params ([ordered]@{ type = 'keyUp'; key = 'a'; code = 'KeyA'; windowsVirtualKeyCode = 65; modifiers = 2 })
}

# --- REGION: Settling
function Wait-WebPageSettled {
    <#
    .SYNOPSIS
        Wait until the page stopped loading and stayed quiet after an input.
    .DESCRIPTION
        A dialog, a new window or a download the input caused fails as
        unsupported; an unreachable commit fails as navigation. A step that does
        not navigate costs the quiet time; waiting for the application beyond
        that belongs to the next step.
    .PARAMETER MarkSeq
        EventSeq read before the first input command of the step.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][long]$MarkSeq,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $start = Get-WebCdpNow -Connection $Connection
    while ($true) {
        $leftMs = ($DeadlineUtc - (Get-WebCdpNow -Connection $Connection)).TotalMilliseconds
        $reply = Read-WebCdpMessage -Connection $Connection -TimeoutMs ([int][Math]::Ceiling([Math]::Max([double]0, [Math]::Min([double]$script:WebLimit.PumpSliceMs, $leftMs))))
        if ($null -ne $reply) { Receive-WebCdpStrayReply -Connection $Connection -Reply $reply }
        $page = $Connection.Page
        if ($null -eq $page) { throw (New-WebFailureException -Kind 'page_lost' -Detail 'no page') }
        if ($page.Dialog) {
            $dialogType = [string]$page.Dialog.Type
            Resolve-WebCdpDialog -Connection $Connection
            throw (New-WebFailureException -Kind 'unsupported' -Detail "dialog: $dialogType")
        }
        $newPopup = $false
        foreach ($popup in @($page.Popups)) { if ([long]$popup.Seq -gt $MarkSeq) { $newPopup = $true } }
        if ($newPopup) {
            Close-WebPagePopup -Connection $Connection
            throw (New-WebFailureException -Kind 'unsupported' -Detail 'popup')
        }
        if ([long]$page.DownloadSeq -gt $MarkSeq) { throw (New-WebFailureException -Kind 'unsupported' -Detail 'download') }
        if ($page.Crashed) { throw (New-WebFailureException -Kind 'page_lost' -Detail 'crashed') }
        if ($page.Gone) { throw (New-WebFailureException -Kind 'page_lost' -Detail ([string]$page.Gone)) }
        $now = Get-WebCdpNow -Connection $Connection
        $navigated = [long]$page.NavigationSeq -gt $MarkSeq
        $lastActivity = $start
        if ($navigated -and [datetime]$page.NavigationUtc -gt $lastActivity) { $lastActivity = [datetime]$page.NavigationUtc }
        if (-not $page.Loading -and ($now - $lastActivity).TotalMilliseconds -ge $script:WebLimit.SettleQuietMs) {
            if ([long]$page.CommitSeq -gt $MarkSeq -and $page.UnreachableUrl) {
                throw (New-WebFailureException -Kind 'navigation' -Detail "unreachable: $($page.UnreachableUrl)")
            }
            return @{ Navigated = $navigated; Url = [string]$page.Url }
        }
        if ($now -ge $DeadlineUtc) {
            if ($page.Loading) { throw (New-WebFailureException -Kind 'navigation' -Detail 'load did not finish') }
            return @{ Navigated = $navigated; Url = [string]$page.Url }
        }
        if (-not $page.Loading -and ($now - $start).TotalMilliseconds -ge $script:WebLimit.SettleCapMs) {
            return @{ Navigated = $navigated; Url = [string]$page.Url }
        }
    }
}

# --- REGION: Page operations
function Resolve-WebReadyTarget {
    <#
    .SYNOPSIS
        Resolve a locator until its element is ready, polling until the deadline.
    .DESCRIPTION
        Each poll finds the target once and runs the operation's ready checks on
        it; a check that is not met throws a retryable failure, and the loop
        tries again. A non-retryable failure ends the loop at once. At the
        deadline the last failure is thrown, not retryable; a not_found lists
        the elements that carry the wanted name under another role.
    .PARAMETER Ready
        The ready checks: param($Found); returns what the operation needs next.
    .OUTPUTS
        System.Collections.Hashtable: Found, Ready.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][scriptblock]$Ready
    )
    $last = @{ Kind = 'not_found'; Detail = '' }
    $lastForest = $null
    $nth = Get-WebLocatorNth -Locator $Locator
    while ($true) {
        try {
            $found = Find-WebTarget -Connection $Connection -Locator $Locator -DeadlineUtc $DeadlineUtc
            if ($found.Forest) { $lastForest = $found.Forest }
            if ($null -ne $found.Target) {
                $readyResult = & $Ready $found
                return @{ Found = $found; Ready = $readyResult }
            }
            $last = @{ Kind = 'not_found'; Detail = $(if ($nth -gt 0) { "nth $nth of $($found.Matches.Count)" } else { '' }) }
        } catch {
            $failure = Get-WebFailureData -ErrorRecord $_
            if ($null -eq $failure -or -not $failure.Retryable) { throw }
            if (-not $failure.DeadlineCut) { $last = @{ Kind = $failure.Kind; Detail = $failure.Detail } }
        }
        if ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.PollIntervalMs) -ge $DeadlineUtc) {
            if ($last.Kind -eq 'not_found') {
                $listed = [System.Collections.Generic.List[object]]::new()
                if ($lastForest -and -not $Locator['css']) {
                    $want = ConvertTo-WebName -Text ([string]$Locator['name'])
                    $wantRole = if ([string]$Locator['role'] -ceq 'img') { 'image' } else { [string]$Locator['role'] }
                    foreach ($entry in @($lastForest.Entries)) {
                        if ($listed.Count -ge $script:WebLimit.MaxCandidates) { break }
                        if ([string]$entry.Role -cne $wantRole -and [string]::Equals([string]$entry.Norm, $want, [StringComparison]::OrdinalIgnoreCase)) {
                            $listed.Add(@{ role = [string]$entry.Role; name = [string]$entry.Name })
                        }
                    }
                }
                throw (New-WebFailureException -Kind 'not_found' -Detail $last.Detail -Candidates $listed.ToArray() -MatchCount 0)
            }
            throw (New-WebFailureException -Kind $last.Kind -Detail $last.Detail)
        }
        Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.PollIntervalMs
    }
}

function Read-WebNodeProperty {
    <#
    .SYNOPSIS
        One accessibility node of an element, read again: its properties and
        value, or $null when the node is stale or ignored.
    .OUTPUTS
        System.Collections.Hashtable: Props, Value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][hashtable]$Address,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $partial = Invoke-WebCdp -Connection $Connection -Method 'Accessibility.getPartialAXTree' `
        -Params ([ordered]@{ backendNodeId = [int]$Address.BackendNodeId; fetchRelatives = $false }) `
        -SessionId ([string]$Address.SessionId) -DeadlineUtc $DeadlineUtc -AllowError -32000
    if ($partial.Contains('ErrorCode')) { return $null }
    $node = @($partial['nodes'])[0]
    if ($node -isnot [System.Collections.IDictionary] -or [bool]$node['ignored']) { return $null }
    $entry = ConvertTo-WebAxEntry -Node $node -SessionId ([string]$Address.SessionId) -BackendNodeId ([int]$Address.BackendNodeId)
    return @{ Props = $entry.Props; Value = $entry.Value }
}

function ConvertTo-WebCheckedText {
    <#
    .SYNOPSIS
        A checked state as the text the accessibility tree uses.
    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    return [string]$Value
}

function Invoke-WebPageOpen {
    <#
    .SYNOPSIS
        Navigate the page to a URL and wait until it settled.
    .DESCRIPTION
        A leave-page prompt is accepted. A download is unsupported, never a
        navigation failure: the URL was reached. A URL the browser cannot parse
        changes nothing, so Dispatched goes back to its value on entry.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][hashtable]$Effect
    )
    Sync-WebCdpEvent -Connection $Connection
    $page = $Connection.Page
    if ($null -eq $page) { throw (New-WebFailureException -Kind 'page_lost' -Detail 'no page') }
    $markSeq = [long]$Connection.EventSeq
    $dispatchedOnEntry = $Effect.Dispatched
    $Effect.Dispatched = $true
    $remainingMs = [int][Math]::Max(1, [Math]::Min([int]::MaxValue, ($DeadlineUtc - (Get-WebCdpNow -Connection $Connection)).TotalMilliseconds))
    try {
        $navigation = Invoke-WebCdp -Connection $Connection -Method 'Page.navigate' -Params @{ url = $Url } -SessionId ([string]$page.SessionId) `
            -DeadlineUtc $DeadlineUtc -ReplyLimitMs $remainingMs -AcceptBeforeUnload -AllowError -32000
    } catch {
        $failure = Get-WebFailureData -ErrorRecord $_
        if ($failure -and $failure.Kind -eq 'page_lost' -and $failure.Detail -ceq 'no reply to Page.navigate') {
            throw (New-WebFailureException -Kind 'navigation' -Detail 'no response')
        }
        throw
    }
    if ($navigation.Contains('ErrorCode')) {
        $Effect.Dispatched = $dispatchedOnEntry
        throw (New-WebFailureException -Kind 'navigation' -Detail ([string]$navigation.ErrorMessage))
    }
    $Effect.Acknowledged = $true
    $errorText = if ($navigation.Contains('errorText')) { [string]$navigation['errorText'] } else { '' }
    if (-not $errorText) { $page.Crashed = $false }
    if ($navigation['isDownload'] -eq $true) { throw (New-WebFailureException -Kind 'unsupported' -Detail 'download') }
    Sync-WebCdpEvent -Connection $Connection
    if ([long]$page.DownloadSeq -gt $markSeq) { throw (New-WebFailureException -Kind 'unsupported' -Detail 'download') }
    if ($errorText) { throw (New-WebFailureException -Kind 'navigation' -Detail $errorText) }
    return (Wait-WebPageSettled -Connection $Connection -MarkSeq $markSeq -DeadlineUtc $DeadlineUtc)
}

function Invoke-WebPageClick {
    <#
    .SYNOPSIS
        Click the element a locator names once it is ready, then settle.
    .PARAMETER Checked
        The state a check box should end in: an element already in that state is
        left alone, and the state is read back after the click.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
        [bool]$Checked,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][hashtable]$Effect
    )
    Sync-WebCdpEvent -Connection $Connection
    $wantChecked = if ($PSBoundParameters.ContainsKey('Checked')) { if ($Checked) { 'true' } else { 'false' } } else { '' }
    $resolved = Resolve-WebReadyTarget -Connection $Connection -Locator $Locator -DeadlineUtc $DeadlineUtc -Ready {
        param($Found)
        $props = $Found.Target.Props
        if ($wantChecked) {
            if (-not $props.ContainsKey('checked')) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'no checked state' -Retryable) }
            if ((ConvertTo-WebCheckedText -Value $props['checked']) -ceq $wantChecked) { return @{ Done = $true } }
        }
        if ($props['disabled'] -eq $true) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'disabled' -Retryable) }
        $clickPoint = Resolve-WebClickPoint -Connection $Connection -Address $Found.Target.Address -DeadlineUtc $DeadlineUtc
        return @{ Done = $false; Point = $clickPoint }
    }
    if ($resolved.Ready.Done) { return @{ Navigated = $false; Url = [string]$Connection.Page.Url } }
    $target = $resolved.Found.Target
    $markSeq = [long]$Connection.EventSeq
    Send-WebMouseClick -Connection $Connection -X $resolved.Ready.Point.X -Y $resolved.Ready.Point.Y -Effect $Effect -DeadlineUtc $DeadlineUtc
    $settled = Wait-WebPageSettled -Connection $Connection -MarkSeq $markSeq -DeadlineUtc $DeadlineUtc
    if (-not $wantChecked) { return $settled }
    $verifyEnd = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.VerifyLimitMs)
    if ($DeadlineUtc -lt $verifyEnd) { $verifyEnd = $DeadlineUtc }
    $lastState = 'none'
    while ($true) {
        $state = $null
        $read = Read-WebNodeProperty -Connection $Connection -Address $target.Address -DeadlineUtc $DeadlineUtc
        if ($null -ne $read) {
            if ($read.Props.ContainsKey('checked')) { $state = ConvertTo-WebCheckedText -Value $read.Props['checked'] }
        } else {
            try {
                $again = Find-WebTarget -Connection $Connection -Locator $Locator -DeadlineUtc $DeadlineUtc
                if ($null -ne $again.Target -and $again.Target.Props.ContainsKey('checked')) { $state = ConvertTo-WebCheckedText -Value $again.Target.Props['checked'] }
            } catch {
                $failure = Get-WebFailureData -ErrorRecord $_
                if ($null -eq $failure -or -not $failure.Retryable) { throw }
                Write-Verbose "Invoke-WebPageClick: reading the checked state again failed: $($failure.Detail)"
            }
        }
        if ($null -ne $state -and $state -ne '') {
            $lastState = $state
            if ($state -ceq $wantChecked) { return $settled }
        }
        if ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.PollIntervalMs) -gt $verifyEnd) { break }
        Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.PollIntervalMs
    }
    throw (New-WebFailureException -Kind 'expectation' -Detail "checked is $lastState")
}

function Invoke-WebPageFill {
    <#
    .SYNOPSIS
        Replace the value of an editable element and read it back.
    .DESCRIPTION
        Focus, select all and insert the text. The text goes only into the
        insertText command: no stream, detail or label carries it, and a value
        that reads back changed is reported by its lengths. A password field is
        compared by length, because it shows one bullet per character.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][hashtable]$Effect
    )
    Sync-WebCdpEvent -Connection $Connection
    $resolved = Resolve-WebReadyTarget -Connection $Connection -Locator $Locator -DeadlineUtc $DeadlineUtc -Ready {
        param($Found)
        $props = $Found.Target.Props
        $address = $Found.Target.Address
        if ($props['disabled'] -eq $true) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'disabled' -Retryable) }
        $editable = [string]$props['editable']
        if (($editable -cne 'plaintext' -and $editable -cne 'richtext') -or $props['readonly'] -eq $true) {
            throw (New-WebFailureException -Kind 'not_actionable' -Detail 'not editable' -Retryable)
        }
        $null = Invoke-WebCdp -Connection $Connection -Method 'DOM.scrollIntoViewIfNeeded' -Params @{ backendNodeId = [int]$address.BackendNodeId } `
            -SessionId ([string]$address.SessionId) -DeadlineUtc $DeadlineUtc
        $box = Get-WebBoxQuad -Connection $Connection -SessionId ([string]$address.SessionId) -BackendNodeId ([int]$address.BackendNodeId) -DeadlineUtc $DeadlineUtc
        if ($null -eq $box) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'no box' -Retryable) }
        $mark = [long]$Connection.EventSeq
        $Effect.Dispatched = $true
        $focus = Invoke-WebCdp -Connection $Connection -Method 'DOM.focus' -Params @{ backendNodeId = [int]$address.BackendNodeId } `
            -SessionId ([string]$address.SessionId) -DeadlineUtc $DeadlineUtc -AllowError -32000
        if ($focus.Contains('ErrorCode')) {
            $Effect.Dispatched = $false
            throw (New-WebFailureException -Kind 'not_actionable' -Detail 'not focusable' -Retryable)
        }
        return @{ MarkSeq = $mark }
    }
    $target = $resolved.Found.Target
    $markSeq = [long]$resolved.Ready.MarkSeq
    Send-WebSelectAll -Connection $Connection -DeadlineUtc $DeadlineUtc
    $null = Invoke-WebCdp -Connection $Connection -Method 'Input.insertText' -Params @{ text = $Text } `
        -SessionId ([string]$Connection.Page.SessionId) -DeadlineUtc $DeadlineUtc
    $Effect.Acknowledged = $true
    $described = Invoke-WebCdp -Connection $Connection -Method 'DOM.describeNode' -Params ([ordered]@{ backendNodeId = [int]$target.Address.BackendNodeId; depth = 0 }) `
        -SessionId ([string]$target.Address.SessionId) -DeadlineUtc $DeadlineUtc -AllowError -32000
    $isPassword = $false
    if (-not $described.Contains('ErrorCode') -and $described['node'] -is [System.Collections.IDictionary] -and [string]$described['node']['nodeName'] -ceq 'INPUT') {
        $attributes = @($described['node']['attributes'])
        for ($i = 0; $i + 1 -lt $attributes.Count; $i += 2) {
            if ([string]$attributes[$i] -eq 'type' -and [string]$attributes[$i + 1] -eq 'password') { $isPassword = $true }
        }
    }
    $verifyEnd = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.VerifyLimitMs)
    if ($DeadlineUtc -lt $verifyEnd) { $verifyEnd = $DeadlineUtc }
    $readLength = 0
    $agrees = $false
    while ($true) {
        $read = Read-WebNodeProperty -Connection $Connection -Address $target.Address -DeadlineUtc $DeadlineUtc
        if ($null -ne $read) {
            $shown = if ($null -ne $read.Value) { [string]$read.Value } else { '' }
            $readLength = $shown.Length
            $agrees = if ($isPassword) { $shown.Length -eq $Text.Length } else { [string]::Equals($shown, $Text, [StringComparison]::Ordinal) }
            if ($agrees) { break }
        }
        if ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.PollIntervalMs) -gt $verifyEnd) { break }
        Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.PollIntervalMs
    }
    if (-not $agrees) {
        throw (New-WebFailureException -Kind 'expectation' -Detail "value differs: wanted $($Text.Length) characters, read $readLength")
    }
    if ([long]$Connection.Page.NavigationSeq -gt $markSeq) {
        return (Wait-WebPageSettled -Connection $Connection -MarkSeq $markSeq -DeadlineUtc $DeadlineUtc)
    }
    return @{ Navigated = $false; Url = [string]$Connection.Page.Url }
}

function Invoke-WebPageSelect {
    <#
    .SYNOPSIS
        Select an option of a native select element by its label.
    .DESCRIPTION
        Runs the fixed function of this module on the element, with the label as
        its bound argument; no step field reaches the page any other way.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Locator,
        [Parameter(Mandatory)][string]$Option,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][hashtable]$Effect
    )
    Sync-WebCdpEvent -Connection $Connection
    $resolved = Resolve-WebReadyTarget -Connection $Connection -Locator $Locator -DeadlineUtc $DeadlineUtc -Ready {
        param($Found)
        $props = $Found.Target.Props
        $address = $Found.Target.Address
        $sessionId = [string]$address.SessionId
        if ($props['disabled'] -eq $true) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'disabled' -Retryable) }
        $box = Get-WebBoxQuad -Connection $Connection -SessionId $sessionId -BackendNodeId ([int]$address.BackendNodeId) -DeadlineUtc $DeadlineUtc
        if ($null -eq $box) { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'no box' -Retryable) }
        $handle = Invoke-WebCdp -Connection $Connection -Method 'DOM.resolveNode' -Params ([ordered]@{ backendNodeId = [int]$address.BackendNodeId; objectGroup = 'yuruna-web' }) `
            -SessionId $sessionId -DeadlineUtc $DeadlineUtc
        $mark = [long]$Connection.EventSeq
        $Effect.Dispatched = $true
        try {
            $call = Invoke-WebCdp -Connection $Connection -Method 'Runtime.callFunctionOn' -SessionId $sessionId -DeadlineUtc $DeadlineUtc -Params ([ordered]@{
                objectId            = [string]$handle['object']['objectId']
                functionDeclaration = $script:WebSelectFunction
                arguments           = @(@{ value = $Option })
                returnByValue       = $true
                awaitPromise        = $false
            })
        } finally {
            try {
                $null = Invoke-WebCdp -Connection $Connection -Method 'Runtime.releaseObjectGroup' -Params @{ objectGroup = 'yuruna-web' } `
                    -SessionId $sessionId -DeadlineUtc $DeadlineUtc -AllowError -32000, -32001, -32601, -32602
            } catch {
                Write-Verbose "Invoke-WebPageSelect: releasing the element handle failed: $($_.Exception.Message)"
            }
        }
        if ($call.Contains('exceptionDetails')) { throw (New-WebFailureException -Kind 'protocol' -Detail 'select function threw') }
        $outcome = if ($call['result'] -is [System.Collections.IDictionary]) { $call['result']['value'] } else { $null }
        if ($outcome -isnot [System.Collections.IDictionary]) { throw (New-WebFailureException -Kind 'protocol' -Detail 'select function returned no value') }
        if ($outcome['ok'] -ne $true) {
            $Effect.Dispatched = $false
            $reason = [string]$outcome['reason']
            switch -CaseSensitive ($reason) {
                'no-option' { throw (New-WebFailureException -Kind 'not_found' -Detail 'option' -Retryable) }
                'option-disabled' { throw (New-WebFailureException -Kind 'not_actionable' -Detail 'option disabled' -Retryable) }
                'ambiguous-option' {
                    $labels = @(@($outcome['options']) | Select-Object -First $script:WebLimit.MaxCandidates | ForEach-Object { @{ role = 'option'; name = [string]$_ } })
                    throw (New-WebFailureException -Kind 'ambiguous' -Detail 'option' -Candidates $labels -MatchCount ([int]$outcome['count']))
                }
                default { throw (New-WebFailureException -Kind 'not_actionable' -Detail $reason) }
            }
        }
        return @{ MarkSeq = $mark; Changed = [bool]$outcome['changed'] }
    }
    if (-not $resolved.Ready.Changed) {
        $Effect.Dispatched = $false
        return @{ Navigated = $false; Url = [string]$Connection.Page.Url }
    }
    $Effect.Acknowledged = $true
    $target = $resolved.Found.Target
    $settled = Wait-WebPageSettled -Connection $Connection -MarkSeq ([long]$resolved.Ready.MarkSeq) -DeadlineUtc $DeadlineUtc
    $want = ConvertTo-WebName -Text $Option
    $verifyEnd = (Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.VerifyLimitMs)
    if ($DeadlineUtc -lt $verifyEnd) { $verifyEnd = $DeadlineUtc }
    while ($true) {
        $read = Read-WebNodeProperty -Connection $Connection -Address $target.Address -DeadlineUtc $DeadlineUtc
        if ($null -ne $read -and [string]::Equals((ConvertTo-WebName -Text ([string]$read.Value)), $want, [StringComparison]::OrdinalIgnoreCase)) { return $settled }
        if ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.PollIntervalMs) -gt $verifyEnd) { break }
        Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.PollIntervalMs
    }
    throw (New-WebFailureException -Kind 'expectation' -Detail 'selection differs')
}

function Invoke-WebPagePress {
    <#
    .SYNOPSIS
        Press one key on whatever has focus, then settle.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [Parameter(Mandatory)][hashtable]$Effect
    )
    if (-not $script:WebKey.ContainsKey($Key)) { throw (New-WebFailureException -Kind 'invalid_step' -Detail "key $Key") }
    Sync-WebCdpEvent -Connection $Connection
    Assert-WebPageUsable -Connection $Connection
    $markSeq = [long]$Connection.EventSeq
    Send-WebKey -Connection $Connection -Key $Key -Effect $Effect -DeadlineUtc $DeadlineUtc
    return (Wait-WebPageSettled -Connection $Connection -MarkSeq $markSeq -DeadlineUtc $DeadlineUtc)
}

function Invoke-WebPageExpect {
    <#
    .SYNOPSIS
        Wait until the page shows a text or an element, or with -Gone until it
        no longer does.
    .DESCRIPTION
        Sends no input and never settles. Several matches are not an error here.
        An incomplete forest never proves absence. A page that stopped answering
        ends the step as page_lost, not as an expectation that did not hold.
    .OUTPUTS
        System.Collections.Hashtable: Navigated, Url.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Connection,
        [System.Collections.IDictionary]$Locator,
        [AllowEmptyString()][string]$Text,
        [switch]$Gone,
        [Parameter(Mandatory)][datetime]$DeadlineUtc
    )
    $byText = $PSBoundParameters.ContainsKey('Text')
    Sync-WebCdpEvent -Connection $Connection
    $last = @{ Kind = 'expectation'; Detail = 'found 0'; Count = 0 }
    $nth = if ($Locator) { Get-WebLocatorNth -Locator $Locator } else { 0 }
    while ($true) {
        try {
            $incomplete = $false
            if ($byText) {
                $forest = Read-WebPageForest -Connection $Connection -DeadlineUtc $DeadlineUtc
                $incomplete = [bool]$forest.Incomplete
                $present = Test-WebPageText -Forest $forest -Text $Text
                $count = if ($present) { 1 } else { 0 }
            } else {
                if ($Locator['css']) {
                    $found = Find-WebCssElement -Connection $Connection -Selector ([string]$Locator['css']) -DeadlineUtc $DeadlineUtc
                } else {
                    $forest = Read-WebPageForest -Connection $Connection -DeadlineUtc $DeadlineUtc
                    $incomplete = [bool]$forest.Incomplete
                    $matchMode = if ($Locator['match']) { [string]$Locator['match'] } else { 'exact' }
                    $found = Find-WebElement -Forest $forest -Role ([string]$Locator['role']) -Name ([string]$Locator['name']) -Match $matchMode
                }
                $count = $found.Count
                $present = $count -ge [Math]::Max(1, $nth)
            }
            if ($Gone) {
                if (-not $present -and -not $incomplete) { return @{ Navigated = $false; Url = [string]$Connection.Page.Url } }
            } elseif ($present) {
                return @{ Navigated = $false; Url = [string]$Connection.Page.Url }
            }
            $last = @{ Kind = 'expectation'; Detail = "found $count"; Count = $count }
        } catch {
            $failure = Get-WebFailureData -ErrorRecord $_
            if ($null -eq $failure -or -not $failure.Retryable) { throw }
            if (-not $failure.DeadlineCut) { $last = @{ Kind = $failure.Kind; Detail = $failure.Detail; Count = $last.Count } }
        }
        if ((Get-WebCdpNow -Connection $Connection).AddMilliseconds($script:WebLimit.PollIntervalMs) -ge $DeadlineUtc) {
            throw (New-WebFailureException -Kind $last.Kind -Detail $last.Detail -MatchCount $last.Count)
        }
        Wait-WebCdpIdle -Connection $Connection -Milliseconds $script:WebLimit.PollIntervalMs
    }
}

Export-ModuleMember -Function Open-GuestWebSession, Get-GuestWebSession, Get-GuestWebSessionList, Test-GuestWebSession, Close-GuestWebSession,
    Connect-WebCdp, Open-WebCdpPage, Close-WebCdp, Test-WebCdpOpen, Invoke-WebCdp, Get-WebCdpVersionDocument,
    New-WebFailureException, Get-WebFailureData, Read-WebPageForest, Find-WebElement, Test-WebPageText, ConvertTo-WebName, Get-WebLimit,
    Get-WebPageSnapshotEntry, Invoke-WebPageOpen, Invoke-WebPageClick, Invoke-WebPageFill, Invoke-WebPageSelect, Invoke-WebPagePress, Invoke-WebPageExpect
