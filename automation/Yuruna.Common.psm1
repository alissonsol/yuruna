<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42fcd8c5-0a6a-4e17-b89b-9c4d030faa8e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Common
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

# Neutral leaf: dependency-free helpers shared across the automation / host / test
# layers so a single definition cannot drift between hand-copied blocks. Each
# consumer imports it -Global -Force at its top (the same pattern the operation
# modules use for Yuruna.Result / Yuruna.VariableExpansion), so the helpers resolve
# at operation time and the module holds no per-run state of its own.

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
function New-YurunaTimestampedBackup {
    <#
    .SYNOPSIS
        Copy a source .yml into <WorkFolder>/<Prefix>.<yyyy-MM-dd-HH-mm-ss>.yml as a
        best-effort timestamped backup.
    .DESCRIPTION
        The one timestamped-backup step the component/resource/workload publishers
        share. The caller keeps ownership of the work-folder lifecycle
        (New-Item / Resolve-Path) because it reuses that folder for other artifacts;
        only the timestamp + copy + retention + verbose line live here so the
        timestamp format cannot drift between publishers. Best-effort by contract:
        -ErrorAction SilentlyContinue on the copy and the retention sweep, and
        nothing is emitted to the pipeline so a publisher's singular
        result-manifest return stays clean.

        Retention: only the newest $KeepCount backups per prefix are kept. The
        publishers run every cycle, so without a cap the dated copies accumulate
        without bound. The timestamp format sorts lexicographically ==
        chronologically, so the sweep needs no date parsing.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort backup copy of a config file (-ErrorAction SilentlyContinue by contract); ShouldProcess would not fit a publisher prelude step that never blocks on the copy result.')]
    param(
        [Parameter(Mandatory)][string]$SourceFile,
        [Parameter(Mandatory)][string]$WorkFolder,
        [Parameter(Mandatory)][string]$Prefix,
        [int]$KeepCount = 20
    )
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}', (Get-Date)))
    $backupFile = Join-Path -Path $WorkFolder -ChildPath "$Prefix.$dtTime.yml"
    Copy-Item "$SourceFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $SourceFile copied to: $backupFile"
    if ($KeepCount -gt 0) {
        # The name filter is deliberately narrow (exact prefix + the dated-yml
        # shape) so the sweep can never touch the live config or any
        # non-backup artifact sharing the work folder.
        $stale = @(Get-ChildItem -LiteralPath $WorkFolder -File -Filter "$Prefix.*.yml" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match ('^' + [regex]::Escape($Prefix) + '\.\d{4}(-\d{2}){5}\.yml$') } |
            Sort-Object -Property Name -Descending |
            Select-Object -Skip $KeepCount)
        foreach ($old in $stale) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-HostProxyBackupPath {
<#
.SYNOPSIS
    Return the absolute path of the host-proxy backup JSON file, creating
    its parent state directory if it doesn't already exist.
.DESCRIPTION
    $HOME/.yuruna/host-proxy.backup.json is the source of truth for
    Clear-HostProxy's restore; its mere existence is also the "are we
    currently promoted?" flag. Same path on every host -- this lives in the
    cross-host Yuruna.Common leaf rather than per-host Yuruna.Host.psm1.
.OUTPUTS
    System.String
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $stateDir = Join-Path $HOME '.yuruna'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    return (Join-Path $stateDir 'host-proxy.backup.json')
}

function ConvertTo-ProxyHostPort {
<#
.SYNOPSIS
    Parse "http://host:port" into separate host / port fields.
.DESCRIPTION
    WinINet ProxyServer takes "host:port", macOS networksetup takes
    server + port as separate args -- callers consume different
    fragments of the URL.
.OUTPUTS
    [hashtable] @{ Host; Port; HostPort; Url }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Url)
    if ($Url -notmatch '^https?://([^:/]+):(\d+)/?$') {
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_cfcb46f2db95508a' -Arguments @{ url = "$Url" })
    }
    return @{
        Host     = $matches[1]
        Port     = [int]$matches[2]
        HostPort = "$($matches[1]):$($matches[2])"
        Url      = "http://$($matches[1]):$($matches[2])/"
    }
}

# Get-PortMapStatePath's no-`-RuntimeDir` branch calls Initialize-YurunaRuntimeDir
# (owned by test/modules/Test.YurunaDir.psm1). That is a soft, call-time
# dependency resolved from the caller's session, NOT imported here: this leaf
# stays dependency-free, and every host/status caller passes -RuntimeDir so the
# branch is never taken outside the test harness (which imports Test.YurunaDir).
function Get-PortMapStatePath {
<#
.SYNOPSIS
    Return the path of the port-map state JSON. Cross-host: same name
    in $env:YURUNA_RUNTIME_DIR / status/runtime on every platform.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RuntimeDir)
    if (-not $RuntimeDir) {
        $RuntimeDir = Initialize-YurunaRuntimeDir
    } elseif (-not (Test-Path $RuntimeDir)) {
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    }
    return (Join-Path $RuntimeDir 'caching-proxy-service-port-map.json')
}

function Test-IsAdministrator {
<#
.SYNOPSIS
    Returns $true on Windows when the current process is elevated; $false
    on every other host (admin is a Windows-specific concept).
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not $IsWindows) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PwshApplicationPath {
<#
.SYNOPSIS
    Absolute path of the pwsh EXECUTABLE to hand another program, or 'pwsh'
    when it cannot be resolved from PATH.
.DESCRIPTION
    Deliberately resolved through PATH (Get-Command -CommandType Application)
    rather than [Environment]::ProcessPath. On a Homebrew PowerShell those are
    different files: PATH finds brew's wrapper, which exports DOTNET_ROOT before
    exec'ing the runtime, while ProcessPath is the libexec apphost the wrapper
    exec'd -- launching THAT directly is how a nested pwsh ends up unable to
    find libhostfxr. Never use ProcessPath to re-launch pwsh.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $resolved = Get-Command -Name 'pwsh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($resolved -and $resolved.Source) { return $resolved.Source }
    return 'pwsh'
}

function Get-SudoPwshArgumentList {
<#
.SYNOPSIS
    Builds the argument vector for running a PowerShell script under sudo:
    @([-n] [-E] <pwsh> -NoProfile -File <script> <script args...>). Pure apart
    from the PATH lookup for pwsh.
.DESCRIPTION
    Two things have to be right or the child never reaches the script.

    The environment. macOS PowerShell installed from the Homebrew FORMULA is
    framework-dependent on brew's dotnet and finds its runtime through
    DOTNET_ROOT, exported by the wrapper on PATH. sudo's env_reset drops that
    variable, so the child starts, fails to locate libhostfxr, and exits 131 --
    before reading a line of the script, and with an error that names .NET
    rather than the caller. -E preserves it.

    -E is macOS-only on purpose. Linux ships a self-contained
    /opt/microsoft/powershell/7 that needs nothing preserved, and a sudoers rule
    carrying NOSETENV there REJECTS -E outright -- so adding it unconditionally
    would break the hosts that work today. The durable machine-wide fix on macOS
    is /etc/dotnet/install_location_<arch>; install/macos.utm.sh writes it.

    The interpreter. Passed as an absolute path from Get-PwshApplicationPath so
    the child is the same PowerShell the caller is using.
.PARAMETER ScriptPath
    Script for pwsh to run with -File.
.PARAMETER ScriptArgument
    Arguments appended after the script path.
.PARAMETER NonInteractive
    Adds sudo -n, so a cold sudo timestamp fails immediately instead of blocking
    on a password prompt no one is watching.
.PARAMETER Prompt
    Replaces sudo's default prompt (sudo -p). Supply one whenever the elevation
    interrupts a run that has been talking about OTHER credentials.

    sudo's bare "Password:" names neither the account nor the reason, and these
    runs surface it in the worst possible context: seconds after lines about
    vault keys, tokens, and storage-account credentials fetched from another
    host. The password it wants is none of those -- it is the operator's own
    login password on this machine -- and an operator who reads the prompt as
    continuous with what came before answers with the credential the output was
    just discussing. Every attempt is then rejected by a system that is working
    exactly as designed, which is the least diagnosable way to fail.

    sudo expands %u to the invoking user, so a prompt built with it stays right
    on a host where the account differs from whoever wrote the caller.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [switch]$NonInteractive,
        [string]$Prompt = ''
    )
    $sudoOption = @()
    if ($NonInteractive) { $sudoOption += '-n' }
    if ($IsMacOS)        { $sudoOption += '-E' }
    # After -n: a prompt is pointless when -n guarantees there will not be one,
    # but harmless, and ordering the option list this way keeps the vector
    # readable in a transcript.
    if ($Prompt)         { $sudoOption += @('-p', $Prompt) }
    return [string[]]@($sudoOption + @((Get-PwshApplicationPath), '-NoProfile', '-File', $ScriptPath) + $ScriptArgument)
}

function Test-YurunaSudoRefusal {
<#
.SYNOPSIS
    $true when sudo's output is sudo REFUSING to run the command, rather than the
    command running and failing. Pure (classifies text).
.DESCRIPTION
    The exit code cannot separate the two -- sudo exits 1 for "wrong password",
    "no tty" and "not permitted" alike, and so do plenty of ordinary commands --
    so only the text distinguishes an elevation problem from a work problem, and
    the two need opposite responses: one needs an /etc/sudoers.d rule and hands on
    the host, the other needs the command looked at.

    The wording depends on WHICH sudo is installed, and both spellings must be
    recognized on every host because the same code runs on all of them:
      * sudo (C)    "a password is required", "a terminal is required",
                    "no tty present", "may not run", "is not in the sudoers file"
      * sudo-rs     "interactive authentication is required"
    Ubuntu ships sudo-rs as the default sudo from 25.10 on. A matcher that knows
    only the C wording does not fail loudly as hosts upgrade -- it quietly stops
    recognizing refusals, and every caller then reports something else as the
    cause.
.PARAMETER Output
    Combined stdout+stderr from the sudo invocation; empty and $null are accepted.
.OUTPUTS
    [bool] $true when sudo refused.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }
    return [bool]("$Output" -match '(?i)(a password is required|a terminal is required|no tty present|interactive authentication is required|may not run|is not in the sudoers file|not allowed to execute|no askpass)')
}

function Invoke-YurunaSudo {
<#
.SYNOPSIS
    Run one command under sudo, adding -n on the unattended path so a cold sudo
    timestamp fails immediately instead of blocking on a password prompt.
.DESCRIPTION
    THE PROBLEM THIS SOLVES. The test runner spawns its inner cycle with the
    call operator, so the inner inherits the launch terminal. sudo reads the
    password from /dev/tty, NOT from stdin -- redirecting or closing stdin does
    nothing. A bare `& sudo ...` anywhere in the cycle therefore parks the whole
    host on a prompt nobody is present to answer, while runner.heartbeat (a
    threadpool timer) keeps ticking and the dashboard keeps showing the last
    cycle's green. Passing -n turns that indefinite stall into an immediate,
    attributable failure.

    WHEN -n IS ADDED. Whenever $env:YURUNA_NONINTERACTIVE is '1' -- set by the
    outer runner around every inner spawn, and by the inner on itself. An
    operator running a host script by hand has no such variable, keeps the
    interactive behavior, and can still be prompted once, which is correct:
    they are watching.

    WHEN IT THROWS. If sudo reports that it needs a password (or a terminal, or
    that the account may not run the command), that is not a transient error:
    every later elevated call this cycle fails the same way, and the host needs
    hands on it. Throwing once, with the exact /etc/sudoers.d rule to install,
    beats twenty silent no-ops that leave the cycle "green but wrong". Pass
    -TolerateBlocked for a caller that genuinely wants to continue degraded.
.PARAMETER Argument
    The command and its arguments, e.g. @('systemctl','daemon-reload').
.PARAMETER InputText
    Text piped to the command's stdin. This is how root-owned files get written
    across the codebase (`$body | sudo tee /etc/...`), and it is why the stdin
    of the child cannot simply be closed: tee needs it for the payload, while
    sudo takes the password from /dev/tty regardless.
.PARAMETER TolerateBlocked
    Return the result instead of throwing when sudo says it needs a password.
.OUTPUTS
    [hashtable] @{ ExitCode; Output; Blocked }.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$Argument,
        [string]$InputText,
        [switch]$TolerateBlocked
    )
    # Pinned locally so THIS function's exit-code contract governs regardless of
    # the caller's preferences. A non-zero sudo is the NORMAL path here -- it is
    # what "the timestamp is cold" and "this account may not run that" both look
    # like -- and with $PSNativeCommandUseErrorActionPreference true it becomes a
    # terminating error instead, thrown before the refusal below is recognized.
    # The caller then gets "Program sudo ended with non-zero exit code" in place
    # of the /etc/sudoers.d rule that repairs the host.
    $PSNativeCommandUseErrorActionPreference = $false
    $unattended = ($env:YURUNA_NONINTERACTIVE -eq '1')
    $sudoArgs = @()
    if ($unattended) { $sudoArgs += '-n' }
    $sudoArgs += $Argument

    $raw = if ($PSBoundParameters.ContainsKey('InputText')) {
        $InputText | & sudo @sudoArgs 2>&1
    } else {
        & sudo @sudoArgs 2>&1
    }
    $rc  = $LASTEXITCODE
    $out = (@($raw) | ForEach-Object { "$_" }) -join "`n"

    $blocked = ($rc -ne 0) -and (Test-YurunaSudoRefusal -Output $out)
    $result = @{ ExitCode = $rc; Output = $out; Blocked = $blocked }
    if (-not $blocked) { return $result }

    # The command sudo was asked to run is the first element that is not one of
    # sudo's OWN options. Callers legitimately lead with them --
    # Get-SudoPwshArgumentList emits '-E' on macOS -- and taking element 0 blindly
    # names a flag as the command, so the remedy below prints a sudoers rule
    # granting NOPASSWD on '-E'. That rule repairs nothing and, pasted, teaches
    # the operator the message is noise.
    $argv = @($Argument)
    $cmd = ''
    for ($i = 0; $i -lt $argv.Count; $i++) {
        $token = "$($argv[$i])"
        if ($token -notlike '-*') { $cmd = $token; break }
        # These carry a value in the NEXT token; skipping only the flag would
        # mistake that value for the command name.
        if ($token -in @('-u', '-g', '-p', '-C', '-r', '-t', '-h')) { $i++ }
    }
    if (-not $cmd) { $cmd = "$($argv[0])" }
    $who  = try { "$(& '/usr/bin/id' -un 2>$null)".Trim() } catch { "$($env:USER)".Trim() }
    $full = (Get-Command -CommandType Application -Name (Split-Path -Leaf "$cmd") -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $full) { $full = $cmd }
    $msg = @(
        "Elevation required and no operator is present: sudo refused '$cmd'."
        "  Account: $who"
        "  sudo:    $($out.Trim())"
        '  This cannot be repaired remotely -- it needs onsite/console access:'
        "    echo '$who ALL=(root) NOPASSWD: $full' | sudo tee /etc/sudoers.d/yuruna-runner >/dev/null"
        '    sudo chmod 0440 /etc/sudoers.d/yuruna-runner && sudo visudo -cf /etc/sudoers.d/yuruna-runner'
    ) -join [Environment]::NewLine

    if ($TolerateBlocked) {
        Write-Warning $msg
        return $result
    }
    throw $msg
}

function Test-YurunaCanPrompt {
<#
.SYNOPSIS
    Whether a question asked from this process can actually reach a person who is
    able to answer it.
.DESCRIPTION
    THE PROBLEM THIS SOLVES. Three incompatible spellings of this one question are
    otherwise in circulation -- an environment variable, a console probe, and a
    -Force/-NonInteractive parameter -- and a call site that picks the wrong one
    for its calling context looks exactly like a correct one on review. This is the
    single spelling; each clause below has on its own been the whole reason a run
    stalled.

    ORDER MATTERS. The environment contract is checked FIRST. A parent that has
    taken the run's one authorization publishes that nothing after it may ask, and
    that answer stays correct on a console which still looks interactive -- which
    is precisely the case a redirect probe alone gets wrong.

    Redirected OUTPUT disqualifies as firmly as redirected input. A prompt whose
    text lands in a captured log while stdin is still the keyboard is a run waiting
    on a keystroke nobody knows to press, and that is a worse outcome than an
    honest failure because nothing on screen says what it is waiting for.

    On macOS and Linux [Environment]::UserInteractive is unconditionally $true, so
    the redirect probes and the environment contract carry the whole decision
    there; the UserInteractive clause earns its keep on Windows.
.OUTPUTS
    [bool] -- $true only when a real operator can both SEE the question and ANSWER it.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($env:YURUNA_NONINTERACTIVE -eq '1') { return $false }
    try {
        if ([Console]::IsInputRedirected)        { return $false }
        if ([Console]::IsOutputRedirected)       { return $false }
        if (-not [Environment]::UserInteractive) { return $false }
    } catch {
        # A host with no console object at all (a service, a bare remoting
        # runspace) throws rather than answering. There is nobody there either way.
        return $false
    }
    return $true
}

function Assert-YurunaPromptable {
<#
.SYNOPSIS
    Throw -- naming the parameter or config key that answers the question in
    advance -- when a question cannot reach anybody.
.DESCRIPTION
    A caller that cannot ask has two honest options: fail, or invent an answer.
    Inventing one is never safe here. Defaulting a consent gate is a silent yes,
    and defaulting a path creates real accounts, shares and mounts somewhere no
    operator chose. So this throws, and the message carries the fix: a remote
    operator repairs the run in one round trip instead of reading source to work
    out which switch suppresses which prompt.

    No parameter is mandatory on purpose. A mandatory parameter is itself a prompt,
    and a guard that can stall the run it exists to keep from stalling is worthless.
.PARAMETER Question
    The question that cannot be asked, quoted back so the message says what is
    actually missing.
.PARAMETER ParameterName
    The switch or parameter that supplies the answer up front, e.g. '-Root'.
.PARAMETER ConfigKey
    The configuration key that supplies the answer up front, for callers whose
    answer lives in a file rather than on the command line.
#>
    [CmdletBinding()]
    param(
        [string]$Question,
        [string]$ParameterName,
        [string]$ConfigKey
    )
    if (Test-YurunaCanPrompt) { return }
    $what = if ([string]::IsNullOrWhiteSpace($Question)) { 'A question' } else { $Question.Trim() }
    $how = @()
    if ($ParameterName) { $how += "pass $ParameterName" }
    if ($ConfigKey)     { $how += "set $ConfigKey" }
    $tail = if ($how.Count) { " Answer it in advance: $($how -join ', or ')." } else { '' }
    throw "$what -- this run cannot ask: no operator can see the question or answer it.$tail"
}

function Get-CachingProxyServicePort {
<#
.SYNOPSIS
    Resolve the client-facing caching-proxy-service port for one of the supported
    schemes (http / https / ftp), honoring per-scheme env-var overrides
    with squid-style defaults.
.DESCRIPTION
    Reads `$env:YURUNA_CACHING_PROXY_SERVICE_<SCHEME>_PORT`. Empty / missing /
    non-integer values fall through to the squid defaults: 3128 for HTTP,
    3129 for HTTPS, 3128 for FTP. The FTP knob is reserved for callers
    extending the harness (squid handles FTP via HTTP CONNECT today, so
    out-of-the-box code uses 3128 -- same value as HTTP).

    Companion to YURUNA_CACHING_PROXY_SERVICE_IP: clients that need to point at
    a non-default external squid (different IP AND/OR different port)
    set both knobs together.
.OUTPUTS
    [int]
.EXAMPLE
    Get-CachingProxyServicePort                       # 3128 (or override)
    Get-CachingProxyServicePort -Scheme https         # 3129 (or override)
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [ValidateSet('http','https','ftp')]
        [string]$Scheme = 'http'
    )
    $envVar = "YURUNA_CACHING_PROXY_SERVICE_$($Scheme.ToUpperInvariant())_PORT"
    $val = [System.Environment]::GetEnvironmentVariable($envVar)
    if ($val) {
        $parsed = 0
        if ([int]::TryParse($val, [ref]$parsed) -and $parsed -gt 0 -and $parsed -lt 65536) {
            return $parsed
        }
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_baf284244c809741' -Arguments @{ envVar = "${envVar}"; val = "$val" })
    }
    switch ($Scheme) {
        'http'  { return 3128 }
        'https' { return 3129 }
        'ftp'   { return 3128 }
    }
}

function Test-Ipv4Address {
<#
.SYNOPSIS
    Strict IPv4 dotted-quad validator.
.DESCRIPTION
    Returns $true iff the input is a canonical decimal IPv4 address:
    exactly four dot-separated octets, each octet is digits-only with no
    leading zero (except the lone digit '0'), and each numeric value is
    in 0..255. Rejects "999.999.999.999", "01.2.3.4", "1.2.3", "1.2.3.4 ",
    null, empty, and shortened forms.

    Provided here because the loose regex '^\d+\.\d+\.\d+\.\d+$' accepts
    out-of-range octets and gives false confidence (downstream TCP
    connect fails, but only after we've already passed validation).
    [System.Net.IPAddress]::TryParse is not strict enough either -- it
    accepts shortened/hex/octal forms.
.OUTPUTS
    [bool]
.EXAMPLE
    Test-Ipv4Address '192.168.1.1'        # True
    Test-Ipv4Address '999.999.999.999'    # False
    Test-Ipv4Address '01.2.3.4'           # False (leading zero)
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
        $parts = $Address -split '\.'
        if ($parts.Count -ne 4) { return $false }
        foreach ($p in $parts) {
            if ($p -notmatch '^(?:0|[1-9]\d{0,2})$') { return $false }
            if ([int]$p -gt 255) { return $false }
        }
        return $true
    }
}

function Test-Ipv6Address {
<#
.SYNOPSIS
    Strict IPv6 validator.
.DESCRIPTION
    Returns $true iff the input parses as a canonical IPv6 address.
    Accepts the standard hex-colon forms ("::1", "fe80::1", full
    "2001:db8:0:0:0:0:0:1"), the IPv4-mapped form ("::ffff:192.0.2.1"),
    and a trailing zone-id ("fe80::1%en0", "fe80::1%3" -- RFC 4007/6874);
    the zone is host-local, stripped before parsing.

    Implementation uses [System.Net.IPAddress]::TryParse and then
    requires AddressFamily=InterNetworkV6 so an IPv4 input ("1.2.3.4")
    that TryParse happily accepts is rejected here. URL-bracket forms
    ("[::1]", "[::1]:8080") are rejected because brackets are URL
    syntax, not part of the address.
.OUTPUTS
    [bool]
.EXAMPLE
    Test-Ipv6Address '::1'                      # True
    Test-Ipv6Address 'fe80::1%en0'              # True
    Test-Ipv6Address 'gggg::1'                  # False
    Test-Ipv6Address '1.2.3.4'                  # False (v4, not v6)
    Test-Ipv6Address '[::1]'                    # False (URL brackets)
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
        # Reject URL-bracket forms ("[::1]", "[::1]:8080"). .NET 7+'s
        # IPAddress.TryParse silently accepts them, but brackets are URL
        # syntax, not part of the address itself.
        if ($Address -match '[\[\]]') { return $false }
        # RFC 4007 zone-id is not part of the address; strip before parse.
        $candidate = $Address
        $pct = $candidate.IndexOf('%')
        if ($pct -ge 0) { $candidate = $candidate.Substring(0, $pct) }
        # Reject any whitespace inside the address (TryParse may tolerate
        # leading/trailing whitespace in some runtimes).
        if ($candidate -match '\s') { return $false }
        $ip = $null
        if (-not [System.Net.IPAddress]::TryParse($candidate, [ref]$ip)) { return $false }
        return $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6
    }
}

function Format-IpUrlHost {
<#
.SYNOPSIS
    Returns the input wrapped in square brackets when it is a valid
    IPv6 address; otherwise returns it unchanged.
.DESCRIPTION
    Used when embedding an IP into a URL host component (RFC 3986 /
    6874). IPv6 needs to be bracketed so the URL's colon-prefixed
    port doesn't get glued onto the address; IPv4 addresses and DNS
    hostnames are passed through verbatim.
.OUTPUTS
    [string]
.EXAMPLE
    Format-IpUrlHost '192.168.1.1'        # 192.168.1.1
    Format-IpUrlHost '2001:db8::1'        # [2001:db8::1]
    Format-IpUrlHost 'host.local'         # host.local
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0, Mandatory, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string]$Address
    )
    process {
        if (Test-Ipv6Address $Address) { return "[$Address]" }
        return $Address
    }
}

function Test-IpAddress {
<#
.SYNOPSIS
    True if input is a valid IPv4 OR IPv6 address.
.DESCRIPTION
    Convenience wrapper for callsites that legitimately accept either
    family -- operator-set env vars, parameters, files written by the
    harness. Internally combines Test-Ipv4Address and Test-Ipv6Address;
    rejects the same edge cases each does (out-of-range octets, garbage
    hex, URL-bracket forms, shortened-IPv4 forms, etc.).
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    process {
        return ((Test-Ipv4Address $Address) -or (Test-Ipv6Address $Address))
    }
}

function Select-YurunaRoutableAddress {
<#
.SYNOPSIS
    Pick the address a host should actually dial out of a candidate list.
.DESCRIPTION
    One definition of "an address worth returning", because guest address
    discovery asks the same question from many places -- three sources in the
    libvirt driver, two stages in the Hyper-V driver, the standalone fallbacks
    in the SSH module -- and every copy of the rule is another place for it to
    drift. Drift here is not cosmetic: an unfiltered answer hands a caller
    169.254.x or ::1 as though it were the guest, and the connect failure that
    follows names the address rather than the discovery that produced it.

    The rule has two halves. IPv4 is preferred over IPv6 whenever both are
    offered, because the port-map forwarders bind v4 sockets -- but a v6 address
    is still returned when no v4 exists, so a v6-only guest resolves rather than
    reading as absent. And loopback and link-local are rejected in both
    families: they are syntactically fine and provably not the guest.

    Order within a family is preserved, so a caller that has already sorted its
    candidates by preference keeps that ordering.
.PARAMETER Address
    Candidate addresses, in the caller's own preference order. Blanks and
    non-addresses are ignored rather than rejected, so a caller can pass raw
    parse output without pre-cleaning it.
.OUTPUTS
    [string] the chosen address, or $null when no candidate qualifies.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][AllowNull()][string[]]$Address)
    if (-not $Address) { return $null }
    $v4 = @()
    $v6 = @()
    foreach ($candidate in $Address) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $trimmed = $candidate.Trim()
        if (Test-Ipv4Address $trimmed) {
            if ($trimmed -notmatch '^(127\.|169\.254\.)') { $v4 += $trimmed }
            continue
        }
        if (Test-Ipv6Address $trimmed) {
            if ($trimmed -inotmatch '^(::1$|fe80:)') { $v6 += $trimmed }
        }
    }
    if ($v4.Count) { return [string]$v4[0] }
    if ($v6.Count) { return [string]$v6[0] }
    return $null
}

function ConvertTo-Sha512CryptHash {
<#
.SYNOPSIS
    Returns the SHA-512 ($6$) crypt hash for a plaintext password.
    Cross-host helper for guest user-data / autoinstall password fields.
.DESCRIPTION
    Wraps `openssl passwd -6` with two non-negotiable guarantees:

    1. The plaintext is passed AFTER the `--` end-of-options marker.
       A plaintext may legitimately begin with `-` (an operator-supplied
       vault password, for one). Without `--`,
       `openssl passwd -6 -4aWj*CRw` parses `-4aWj*CRw` as an unknown
       option flag, prints `passwd: Use -help for summary` to stderr,
       returns nothing on stdout, and exits non-zero. The cycle then
       writes a malformed (or empty) HASH_PLACEHOLDER into cloud-init
       user-data and the guest comes up with no working password.
       Any future password-handling consumer should pass plaintext
       AFTER `--` (or via stdin) for the same reason.

    2. The shape of the result is validated (`$6$...`) before return.
       Older openssl builds lack `-6`; we surface a clear error rather
       than substituting a bogus hash.

    Platform-specific binary probe (Git for Windows paths, Homebrew
    paths, PATH fallback on Linux) lives here, shared by the three
    parallel per-host New-VM.ps1 scripts so the path logic stays in one
    place instead of drifting across copies.

    The plaintext is briefly visible in the openssl process's argv
    while it runs (process listings). This is acceptable in the
    repo's threat model: vault.yml itself stores plaintext on disk
    (see test/extension/authentication/default.psm1 -- Set-Password
    docstring), and the harness runs in a private dev context.
    `-stdin` is the stricter alternative but introduces a CRLF/encoding
    surface on Windows pwsh that the `--` form sidesteps.
.PARAMETER Plaintext
    The plaintext password to hash. Must be non-empty.
.PARAMETER OpenSslPath
    Optional explicit path to an openssl binary, bypassing the probe.
    Mostly useful for tests.
.OUTPUTS
    [string] -- the `$6$<salt>$<hash>` crypt string.
#>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Plaintext IS the input; this function exists to convert it to a hash. Vault context is plaintext-on-disk by design.')]
    param(
        [Parameter(Mandatory)][string]$Plaintext,
        [string]$OpenSslPath
    )
    if (-not $Plaintext) { throw (Format-YurunaOperatorMessage -Key 'automation.operator_e89fa5a7953b2b69') }

    $candidates = @()
    if ($OpenSslPath) {
        $candidates += $OpenSslPath
    } else {
        if ($IsWindows) {
            $candidates += @(
                "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
                "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe",
                "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe"
            )
        } elseif ($IsMacOS) {
            $candidates += @(
                '/opt/homebrew/opt/openssl@3/bin/openssl',
                '/opt/homebrew/opt/openssl/bin/openssl',
                '/usr/local/opt/openssl@3/bin/openssl',
                '/usr/local/opt/openssl/bin/openssl'
            )
        }
        $candidates += 'openssl'
    }

    foreach ($p in $candidates) {
        if ($p -ne 'openssl' -and -not (Test-Path -LiteralPath $p)) { continue }
        try {
            # `--` MUST stay -- a leading dash in $Plaintext would
            # otherwise be parsed as an option. See function description.
            $raw = (& $p passwd -6 -- $Plaintext 2>$null)
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $hash = ([string]$raw).Trim()
                if ($hash.StartsWith('$6$')) {
                    Write-Verbose "ConvertTo-Sha512CryptHash: hashed via '$p'"
                    return $hash
                }
            }
        } catch {
            Write-Verbose "ConvertTo-Sha512CryptHash: '$p' not usable: $($_.Exception.Message)"
        }
    }
    throw (Format-YurunaOperatorMessage -Key 'automation.operator_d8870f8f0c55a665' -Arguments @{ join = "$($candidates -join ', ')" })
}

function ConvertTo-YurunaMacAddress {
<#
.SYNOPSIS
    Normalize and validate a MAC address to canonical AA:BB:CC:DD:EE:FF.
.DESCRIPTION
    Accepts the three common notations -- colon-separated, dash-separated,
    and bare 12-hex-digit -- and returns the canonical uppercase
    colon-separated form. Callers reformat from the canonical form to
    their platform's native notation (Hyper-V StaticMacAddress takes bare
    hex; virt-install and UTM config.plist take colons).

    Returns $null (with a Warning naming the reason) when the input is
    not a usable unicast MAC:
      * not 12 hex digits after separator removal, or mixed separators;
      * multicast (first octet's least-significant bit set) -- DHCP
        cannot lease to a multicast source address;
      * all-zeros -- rejected by every hypervisor.

    Additionally warns (but still returns the MAC) when the
    locally-administered bit (0x02 of the first octet) is NOT set: a
    globally-unique OUI address can collide with real hardware on the
    LAN. Pick from the x2/x6/xA/xE second-hex-digit ranges to stay safe.
.OUTPUTS
    [string] canonical MAC, or $null when invalid.
.EXAMPLE
    ConvertTo-YurunaMacAddress '02-11-22-33-44-55'   # '02:11:22:33:44:55'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$MacAddress)

    $trimmed = $MacAddress.Trim()
    # One notation at a time: colon-separated, dash-separated, or bare.
    # A permissive strip-all-separators pass would accept mixed forms
    # like '02:11-22...' that are more likely typos than intent.
    if ($trimmed -notmatch '^([0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{2}(-[0-9A-Fa-f]{2}){5}|[0-9A-Fa-f]{12})$') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_3c501632d2ed2862' -Arguments @{ macAddress = "$MacAddress" })
        return $null
    }
    $bare = ($trimmed -replace '[:-]', '').ToUpperInvariant()
    if ($bare -eq '000000000000') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_a6692253a1a34a18' -Arguments @{ macAddress = "$MacAddress" })
        return $null
    }
    $firstOctet = [Convert]::ToInt32($bare.Substring(0, 2), 16)
    if ($firstOctet -band 0x01) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_5d063be800d28f8d' -Arguments @{ macAddress = "$MacAddress" })
        return $null
    }
    if (-not ($firstOctet -band 0x02)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_951861044b696fe1' -Arguments @{ macAddress = "$MacAddress" })
    }
    return (($bare -split '(..)' | Where-Object { $_ }) -join ':')
}

function Get-YurunaHostMacSeed {
<#
.SYNOPSIS
    The stable per-host string the guest MAC derivation is keyed on.
.DESCRIPTION
    Prefers this host's Yuruna id (runtime/host.uuid) -- opaque, stable across
    reboots, and preserved by the reimage-reclaim flow, so a rebuilt host keeps
    handing its guests the same MACs and therefore the same DHCP leases.

    Falls back to the machine's hostname when no id exists yet (a host that has
    never completed a cycle). The fallback is deliberately NOT a random value: a
    random seed would give every guest a new MAC on every build, which is the
    behavior this whole mechanism exists to remove.
.OUTPUTS
    [string] a non-empty seed.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][string]$HostId = '')

    if (-not [string]::IsNullOrWhiteSpace($HostId)) { return $HostId.Trim() }
    foreach ($dir in @($env:YURUNA_RUNTIME_DIR, (Join-Path (Split-Path -Parent $PSScriptRoot) 'test/status/runtime'))) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $uuidFile = Join-Path $dir 'host.uuid'
        if (Test-Path -LiteralPath $uuidFile) {
            try {
                $uuid = (Get-Content -Raw -LiteralPath $uuidFile -ErrorAction Stop).Trim()
                if (-not [string]::IsNullOrWhiteSpace($uuid)) { return $uuid }
            } catch { Write-Verbose "Get-YurunaHostMacSeed: unreadable $uuidFile" }
        }
    }
    try { $name = [System.Net.Dns]::GetHostName() } catch { $name = '' }
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        Write-Verbose "Get-YurunaHostMacSeed: no host.uuid yet; keying guest MACs on hostname '$name'."
        return $name.Trim()
    }
    return 'yuruna-unidentified-host'
}

function Get-YurunaGuestMacAddress {
<#
.SYNOPSIS
    The deterministic MAC for one (Yuruna host, VM name) pair: the same host
    rebuilding the same guest always gets the same address back.
.DESCRIPTION
    See ../docs/network.md#defining-deterministic-guest-mac-addresses for why
    this exists and the 42:HH:HH:VV:VV:VV layout it produces.
.PARAMETER VMName
    The name to key on. Callers building a guest pass the identity that guest
    will keep for its whole life -- its cloud-init hostname where the sequence
    declares one, the VM name otherwise -- NOT necessarily the name the VM
    carries at the moment of the call. A guest is built in a per-kind slot and
    promoted out of it, and keying on the transient name would move its address
    mid-life; see Test-YurunaGuestMacMatchesName for what that costs.
.PARAMETER HostId
    Override the host seed. Omitted, it is resolved from runtime/host.uuid.
.OUTPUTS
    [string] canonical uppercase MAC, e.g. '42:A3:F1:9C:22:0B'.
.EXAMPLE
    Get-YurunaGuestMacAddress -VMName 'test-guest.ubuntu.server.24-01'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter()][AllowEmptyString()][string]$HostId = ''
    )
    $seed = Get-YurunaHostMacSeed -HostId $HostId
    # Case- and whitespace-insensitive: an operator retyping a VM name with
    # different casing must not produce a second MAC for the same slot.
    $seedKey = $seed.Trim().ToLowerInvariant()
    $vmKey   = "$seedKey|$($VMName.Trim().ToLowerInvariant())"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hostHash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($seedKey))
        $vmHash   = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($vmKey))
    } finally { $sha.Dispose() }

    $octets = @('42') +
              @($hostHash[0..1] | ForEach-Object { $_.ToString('X2') }) +
              @($vmHash[0..2]   | ForEach-Object { $_.ToString('X2') })
    $mac = $octets -join ':'
    # Round-trip through the validator so this function can never emit something
    # the platform writers would reject; it also normalizes the casing.
    $checked = ConvertTo-YurunaMacAddress -MacAddress $mac
    if (-not $checked) { throw "Get-YurunaGuestMacAddress produced an invalid MAC '$mac' for VM '$VMName'." }
    return $checked
}

function Test-YurunaGuestMacMatchesName {
<#
.SYNOPSIS
    Is this NIC still carrying the address that $VMName derives?
.DESCRIPTION
    The question a rename has to answer before it touches a NIC. A guest is
    built in a per-kind slot and promoted out of it, and the address it carries
    tells you which of the two it belongs to:

      * derived from the name being left behind -- the address belongs to the
        NAME, not the guest. Leaving it there strands the slot's address on a VM
        that no longer answers to that name, and the next build of the slot asks
        for one already in use. It has to move with the rename.
      * anything else -- the guest was pinned to its own durable identity at
        build time and has been running on that address ever since. Moving it
        re-DHCPs a guest whose own state may already record its address (a
        kubeadm control plane pins one into certificates, etcd URLs and every
        kubeconfig), which no reboot recovers from.

    Comparison is notation-insensitive: hypervisors report the NIC in whichever
    of the three forms they prefer (Hyper-V bare hex, libvirt lowercase colons,
    UTM uppercase colons), and all three must compare equal to the canonical
    derived value.
.PARAMETER MacAddress
    The address the NIC currently carries, in any notation
    ConvertTo-YurunaMacAddress accepts. Empty or unparseable returns $false --
    an address that could not be read is not evidence of a match.
.PARAMETER VMName
    The name to derive the comparison address from.
.PARAMETER HostId
    Override the host seed. Omitted, it is resolved from runtime/host.uuid.
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$MacAddress,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter()][AllowEmptyString()][string]$HostId = ''
    )
    if ([string]::IsNullOrWhiteSpace($MacAddress)) { return $false }
    # Normalize by hand rather than through ConvertTo-YurunaMacAddress: this is
    # a question, not an assertion, and a NIC carrying something unparseable is
    # a legitimate "no" that must not print a warning on the way out.
    $bare = ($MacAddress.Trim() -replace '[:-]', '').ToUpperInvariant()
    if ($bare -notmatch '^[0-9A-F]{12}$') { return $false }
    $derived = (Get-YurunaGuestMacAddress -VMName $VMName -HostId $HostId) -replace ':', ''
    return ($bare -eq $derived)
}

function ConvertTo-Ipv4UInt32 {
<#
.SYNOPSIS
    Convert a dotted-quad IPv4 string to its 32-bit numeric value.
.DESCRIPTION
    Folds the four octets by hand rather than going through
    [System.Net.IPAddress]::GetAddressBytes() + [BitConverter]::ToUInt32.
    GetAddressBytes returns network (big-endian) order, and BitConverter
    reads host order, so on a little-endian machine that pair silently
    reverses the octets. The reversed value still compares cleanly against
    another reversed value, but NOT against a mask -- the bug surfaces only
    as a wrong subnet verdict, never as an exception. Manual folding has no
    endianness to get wrong.

    Returns $null when the input is not a strict dotted-quad, so callers
    can treat "unparseable" and "out of range" identically.
.OUTPUTS
    [System.Nullable[uint32]] the numeric address, or $null.
.EXAMPLE
    ConvertTo-Ipv4UInt32 '192.168.64.2'   # 3232251906
#>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Position = 0)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Address
    )
    if (-not (Test-Ipv4Address $Address)) { return $null }
    $o = $Address -split '\.'
    return [uint32](([uint32]$o[0] * 16777216) + ([uint32]$o[1] * 65536) + ([uint32]$o[2] * 256) + [uint32]$o[3])
}

function Get-HostIpv4Subnet {
<#
.SYNOPSIS
    Enumerate the live IPv4 subnets the host is directly attached to.
.DESCRIPTION
    Returns one object per usable IPv4 interface address, carrying the
    numeric address, numeric mask and numeric network so callers can do
    membership tests without re-parsing.

    Parses `/sbin/ifconfig` on macOS rather than using
    [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
    or `ipconfig getiflist`. Both of those OMIT the vmnet bridge (bridge100)
    that every UTM guest is attached to, so a membership test built on them
    rejects every legitimate guest address. `ifconfig` with no arguments is
    the only enumeration on macOS that lists it.

    macOS prints the netmask in HEX (`netmask 0xffffff00`), not dotted-quad.
    Code that parses it as an address yields a mask of 0, which makes every
    candidate compare as on-link -- a guard that looks like it works and
    silently permits nothing. The hex form is required here.

    Loopback (127.0.0.0/8) and link-local (169.254.0.0/16) addresses are
    excluded: a candidate must never be judged reachable because it happens
    to share a subnet with lo0 or an autoconfigured stub.

    On a non-macOS host, or when the enumeration yields nothing, an EMPTY
    array is returned. Callers must treat empty as "unknown", never as
    "nothing is on-link" -- see Get-Ipv4OnLinkVerdict.
.PARAMETER IfconfigText
    Pre-captured `ifconfig` output to parse instead of invoking it. Lets
    callers and tests exercise the parser against a fixed interface table.
.OUTPUTS
    [pscustomobject[]] with Address, AddressValue, MaskValue, NetworkValue,
    PrefixLength.
#>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$IfconfigText)

    $text = $IfconfigText
    if (-not $PSBoundParameters.ContainsKey('IfconfigText')) {
        if (-not $IsMacOS) { return @() }
        try {
            $text = (& /sbin/ifconfig 2>$null) -join "`n"
        } catch {
            Write-Debug "Get-HostIpv4Subnet: ifconfig enumeration failed: $($_.Exception.Message)"
            return @()
        }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $result = @()
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -notmatch '^\s+inet (\d+\.\d+\.\d+\.\d+)\s+netmask\s+0x([0-9a-fA-F]{8})') { continue }
        $addr = $Matches[1]
        $maskHex = $Matches[2]
        if ($addr -match '^(127\.|169\.254\.)') { continue }
        $addrVal = ConvertTo-Ipv4UInt32 $addr
        if ($null -eq $addrVal) { continue }
        $maskVal = [uint32][Convert]::ToUInt32($maskHex, 16)
        # A zero mask would make every candidate on-link. Treat it as an
        # unusable entry rather than an all-permitting one.
        if ($maskVal -eq [uint32]0) { continue }
        $prefix = 0
        for ($bit = 31; $bit -ge 0; $bit--) {
            if (($maskVal -shr $bit) -band [uint32]1) { $prefix++ } else { break }
        }
        $result += [pscustomobject]@{
            Address      = $addr
            AddressValue = $addrVal
            MaskValue    = $maskVal
            NetworkValue = [uint32]($addrVal -band $maskVal)
            PrefixLength = $prefix
        }
    }
    return , ([pscustomobject[]]$result)
}

function Test-TcpConnectOutcome {
<#
.SYNOPSIS
    Connect to $IpAddress:$Port within $TimeoutMs and report WHAT happened, not
    merely whether it worked.
.DESCRIPTION
    A failed TCP connect carries two opposite diagnoses and a bool cannot hold
    either of them:

      * 'refused' -- the peer sent an RST. The host is up and the path to it
        works; nothing is listening on that port. A service is down, restarting,
        or was never started. It comes back in milliseconds.
      * 'timeout' -- nothing answered before the deadline. Now the PATH is the
        suspect: a peer that vanished, a bridge that stopped forwarding, an
        uplink that roamed, or a peer too loaded to accept.

    Collapsing those into "did not answer within Ns" sends the reader hunting
    through the network for a fault that is entirely inside the peer, and throws
    away the tell that distinguishes them -- the elapsed time. Tens of
    milliseconds against a 3000 ms budget is not a timeout, it is a refusal.

    ElapsedMs is returned for exactly that reason: a caller that prints it makes
    the distinction legible even to a reader who does not know these outcomes
    exist.
.PARAMETER TimeoutMs
    Deadline for the connect. Bounds only the 'timeout' verdict; a refusal
    returns as fast as the peer answers.
.OUTPUTS
    [hashtable] @{
        Outcome   = 'reachable' | 'refused' | 'timeout' | 'unreachable' | 'error'
        Reachable = [bool] Outcome -eq 'reachable'
        ElapsedMs = [int]
        Detail    = socket error text, '' when there was none
    }
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 3000
    )
    $sw      = [System.Diagnostics.Stopwatch]::StartNew()
    $tcp     = New-Object System.Net.Sockets.TcpClient
    $outcome = 'timeout'
    $detail  = ''
    try {
        $async = $tcp.BeginConnect($IpAddress, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            # The wait completing means the operation FINISHED, not that it
            # succeeded -- a refusal completes it just as much as a connect
            # does. EndConnect is what surfaces which, and calling it is also
            # what releases the async operation instead of abandoning it.
            try {
                $tcp.EndConnect($async)
                $outcome = if ($tcp.Connected) { 'reachable' } else { 'refused' }
            } catch {
                $detail = $_.Exception.Message
                # The SocketException can arrive wrapped; walk to it rather
                # than matching on message text, which is localized.
                $ex = $_.Exception
                while ($ex -and -not ($ex -is [System.Net.Sockets.SocketException])) { $ex = $ex.InnerException }
                switch ("$(if ($ex) { $ex.SocketErrorCode })") {
                    'ConnectionRefused'  { $outcome = 'refused' }
                    'HostUnreachable'    { $outcome = 'unreachable' }
                    'NetworkUnreachable' { $outcome = 'unreachable' }
                    'HostDown'           { $outcome = 'unreachable' }
                    'TimedOut'           { $outcome = 'timeout' }
                    default              { $outcome = 'error' }
                }
            }
        }
    } catch {
        $detail  = $_.Exception.Message
        $outcome = 'error'
    } finally {
        $tcp.Close()
        $sw.Stop()
    }
    return @{
        Outcome   = $outcome
        Reachable = ($outcome -eq 'reachable')
        ElapsedMs = [int]$sw.ElapsedMilliseconds
        Detail    = $detail
    }
}

function Get-TcpOutcomeExplanation {
<#
.SYNOPSIS
    One sentence saying what a Test-TcpConnectOutcome result means and where to
    go looking. Shared so every caller phrases the same finding the same way.
.PARAMETER Outcome
    A Test-TcpConnectOutcome hashtable.
.PARAMETER Endpoint
    How to name the target in the sentence, e.g. "192.168.64.4:3128".
.OUTPUTS
    [string]
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Outcome,
        [Parameter(Mandatory)][string]$Endpoint
    )
    $ms = [int]$Outcome.ElapsedMs
    switch ([string]$Outcome.Outcome) {
        'reachable'   { return "$Endpoint accepted in ${ms} ms." }
        'refused'     { return "$Endpoint REFUSED the connection in ${ms} ms -- the host answered, so the network path is fine and nothing is listening on that port. The service is down, restarting, or was never started." }
        'timeout'     { return "$Endpoint did not answer within ${ms} ms -- nothing responded at all, so the path is the suspect: the peer is gone, a bridge stopped forwarding, the uplink roamed, or the peer is too loaded to accept." }
        'unreachable' { return "$Endpoint is unreachable after ${ms} ms -- the network rejected the route before any peer was contacted (no interface, no route, or a host that is down)." }
        default       { return "$Endpoint could not be probed after ${ms} ms: $($Outcome.Detail)" }
    }
}

function Get-Ipv4OnLinkVerdict {
<#
.SYNOPSIS
    Decide whether an IPv4 address sits on a subnet the host is attached to.
.DESCRIPTION
    Returns one of three values:
      'onlink'  -- the address is inside a live host interface's subnet;
      'offlink' -- host subnets are known and the address is in none of them;
      'unknown' -- no host subnet could be enumerated, or the address is
                   unparseable.

    The tri-state is deliberate. An address that is not on any live subnet
    can only leave the host by the default route, where nothing answers for
    it -- rejecting it converts a long connect-timeout into an immediate
    "not found" and lets the caller keep looking. But an enumeration that
    comes back empty proves nothing, and collapsing that to 'offlink' would
    reject every address and turn a working discovery into a hard failure.
    Callers must act only on 'offlink' and let 'unknown' pass through.

    Membership is exact netmask arithmetic, not a leading-octet string
    compare: a /20 or /23 bridge is common enough that a hardcoded /24
    assumption both admits and rejects the wrong addresses.
.PARAMETER IpAddress
    The candidate IPv4 address.
.PARAMETER Subnet
    Pre-enumerated host subnets from Get-HostIpv4Subnet. Supplied by
    callers that test many candidates against one table, and by tests that
    need a fixed table.
.OUTPUTS
    [string] 'onlink' | 'offlink' | 'unknown'
.EXAMPLE
    Get-Ipv4OnLinkVerdict -IpAddress '192.168.65.42'   # 'offlink' when the
                                                       # host has no such NIC
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$IpAddress,
        [pscustomobject[]]$Subnet
    )
    $candidate = ConvertTo-Ipv4UInt32 $IpAddress
    if ($null -eq $candidate) { return 'unknown' }
    $table = $Subnet
    if (-not $PSBoundParameters.ContainsKey('Subnet')) { $table = Get-HostIpv4Subnet }
    if (-not $table -or $table.Count -eq 0) { return 'unknown' }
    foreach ($s in $table) {
        if (([uint32]($candidate -band $s.MaskValue)) -eq $s.NetworkValue) { return 'onlink' }
    }
    return 'offlink'
}

function Get-PoolFacingIpv4Segment {
<#
.SYNOPSIS
    The IPv4 network this host reaches the rest of the lab over, or $null
    when it cannot be determined.
.DESCRIPTION
    A host runs two kinds of guest network: the LAN it shares with every
    other machine, and a hypervisor-private one only it can see (the macOS
    shared vmnet, a Hyper-V Default Switch, libvirt's virbr0). Both look
    identical from the host -- an RFC 1918 address on a live interface,
    answering probes -- so a service VM on the private one is confirmed by
    its own host and then unreachable for everyone else.

    Telling them apart needs the routing table, not the address: the
    network carrying the route OFF this machine is the one other machines
    are on. A UDP socket "connected" to an address that is not local
    performs exactly that route lookup and nothing else -- UDP connect
    sends no packet -- and its local endpoint is the address the kernel
    would source from. The interface owning that address supplies the
    mask.

    Returns $null on any inconclusive step (no route, no matching
    interface, no mask available). Callers MUST treat $null as "unknown"
    and permit, never as "nothing is on the segment" -- the same tri-state
    discipline as Get-Ipv4OnLinkVerdict.
.PARAMETER ReferenceAddress
    An address to resolve the route toward. Defaults to a documentation
    address (RFC 5737 TEST-NET-1), which is unallocated and therefore
    guaranteed to resolve through the DEFAULT route rather than a local
    one; nothing is ever sent to it. Pass a real lab address (the caching
    proxy) when the pool is reached over a route other than the default.
.OUTPUTS
    [pscustomobject] with Address, AddressValue, MaskValue, NetworkValue,
    PrefixLength -- the same shape Get-HostIpv4Subnet emits -- or $null.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$ReferenceAddress = '192.0.2.1')

    $local = $null
    $socket = $null
    try {
        $reference = $null
        if (-not [System.Net.IPAddress]::TryParse($ReferenceAddress, [ref]$reference)) { return $null }
        if ($reference.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }
        $socket = [System.Net.Sockets.Socket]::new(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        # Port 9 (discard). Connect on a datagram socket only binds the local
        # end to the route's source address; no datagram is sent.
        $socket.Connect($reference, 9)
        $endpoint = [System.Net.IPEndPoint]$socket.LocalEndPoint
        if ($endpoint) { $local = $endpoint.Address.ToString() }
    } catch {
        Write-Debug "Get-PoolFacingIpv4Segment: route lookup toward '$ReferenceAddress' failed: $($_.Exception.Message)"
        return $null
    } finally {
        if ($socket) { $socket.Dispose() }
    }
    if (-not (Test-Ipv4Address $local)) { return $null }

    $addrVal = ConvertTo-Ipv4UInt32 $local
    if ($null -eq $addrVal) { return $null }
    try {
        foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                if ($unicast.Address.ToString() -ne $local) { continue }
                # IPv4Mask is not implemented on every platform/interface; a
                # missing or zero mask would make every address compare as
                # on-segment, so it is treated as unknown instead.
                $maskVal = ConvertTo-Ipv4UInt32 ([string]$unicast.IPv4Mask)
                if ($null -eq $maskVal -or $maskVal -eq [uint32]0) { continue }
                $prefix = 0
                for ($bit = 31; $bit -ge 0; $bit--) {
                    if (($maskVal -shr $bit) -band [uint32]1) { $prefix++ } else { break }
                }
                return [pscustomobject]@{
                    Address      = $local
                    AddressValue = $addrVal
                    MaskValue    = $maskVal
                    NetworkValue = [uint32]($addrVal -band $maskVal)
                    PrefixLength = $prefix
                }
            }
        }
    } catch {
        Write-Debug "Get-PoolFacingIpv4Segment: interface enumeration failed: $($_.Exception.Message)"
    }
    # macOS fallback: .NET's enumeration is the portable path, but the mask it
    # reports is not available on every platform/interface. Get-HostIpv4Subnet
    # reads the same interfaces out of ifconfig, where the mask always is.
    foreach ($subnet in (Get-HostIpv4Subnet)) {
        if ($subnet.Address -ne $local) { continue }
        return $subnet
    }
    return $null
}

function Get-Ipv4PoolSegmentVerdict {
<#
.SYNOPSIS
    Decide whether an IPv4 address is one the REST OF THE LAB could reach,
    or one that exists only inside this host.
.DESCRIPTION
    Returns one of three values:
      'onsegment'  -- the address shares this host's pool-facing network;
      'offsegment' -- the pool-facing network is known and the address is
                      not on it (the signature of a guest sitting on a
                      hypervisor-private network: the macOS shared vmnet,
                      a Hyper-V Default Switch, libvirt's virbr0);
      'unknown'    -- the pool-facing network could not be determined, or
                      the address is unparseable.

    The tri-state is deliberate, and callers must act ONLY on 'offsegment'.
    An address on another routed subnet of a larger lab is 'offsegment'
    here as well, so this is a reason to stop ADVERTISING an address to
    other hosts -- something only its own host can be wrong about -- never
    a reason to stop using it locally, and never the last word: a service
    that is genuinely reachable still registers through its own announce,
    which the pool confirms by probing it.
.PARAMETER Address
    The candidate IPv4 address.
.PARAMETER Segment
    Pre-resolved pool-facing segment from Get-PoolFacingIpv4Segment.
    Supplied by callers testing several addresses against one answer, and
    by tests that need a fixed one.
.OUTPUTS
    [string] 'onsegment' | 'offsegment' | 'unknown'
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][AllowNull()][string]$Address,
        [pscustomobject]$Segment
    )
    $candidate = ConvertTo-Ipv4UInt32 $Address
    if ($null -eq $candidate) { return 'unknown' }
    $seg = $Segment
    if (-not $PSBoundParameters.ContainsKey('Segment')) { $seg = Get-PoolFacingIpv4Segment }
    if (-not $seg) { return 'unknown' }
    if (([uint32]($candidate -band $seg.MaskValue)) -eq $seg.NetworkValue) { return 'onsegment' }
    return 'offsegment'
}

function Select-DhcpLeaseIpAddress {
<#
.SYNOPSIS
    Pick the live guest IPv4 out of macOS `/var/db/dhcpd_leases` text.
.DESCRIPTION
    The macOS shared-NAT DHCP server files each lease as a `{ ... }` block
    keyed by the name the guest sent, and NEVER prunes blocks for guests
    that no longer exist. Two things follow, and both have bitten:

    1. The name is the guest's own hostname, which is the VM name only when
       no sequence pinned `variables.hostname`. When one is pinned the guest
       registers under THAT name, and every block still filed under the VM
       name belongs to a predecessor. Those blocks match, so a VM-name
       lookup does not come back empty -- it comes back with a dead address,
       frequently on a subnet the host has since stopped serving. Callers
       pass -Name in priority order (pinned hostname first, VM name second)
       so the guest is found whichever name it registered under.

    2. Several blocks can carry the same name: the live guest plus stale
       leases from deleted predecessors that reused the name. The lease's
       hw_address is a DHCP DUID rather than the bundle's link MAC, so it
       cannot disambiguate. The live guest keeps RENEWING while a dead one's
       lease only ages, so the largest `lease=` expiry is the live one. A
       block with no parseable `lease=` cannot prove it is renewing and is
       skipped outright rather than allowed to displace one that can.

    Candidates are additionally filtered by -OnLinkVerdict. Only an explicit
    'offlink' rejects; 'unknown' is accepted, because an empty interface
    enumeration proves nothing and must not collapse into rejecting every
    candidate -- when the host subnets cannot be enumerated, selection falls
    back to the lease-expiry tie-break alone.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Name
    Names to try, most specific first. The first name that yields an
    acceptable address wins; later names are not consulted.
.PARAMETER OnLinkVerdict
    Scriptblock taking one IPv4 string and returning 'onlink' | 'offlink' |
    'unknown'. Defaults to Get-Ipv4OnLinkVerdict against the live host.
.OUTPUTS
    [string] the selected IPv4, or $null when no name yields one.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [Parameter(Mandatory)][string[]]$Name,
        [scriptblock]$OnLinkVerdict
    )
    if ([string]::IsNullOrWhiteSpace($LeaseText)) { return $null }
    if (-not $OnLinkVerdict) {
        # Enumerate once for the whole scan; Get-VMIp runs inside polling
        # loops, and shelling out per candidate block would be a real cost.
        $subnetTable = Get-HostIpv4Subnet
        $OnLinkVerdict = { param($ip) Get-Ipv4OnLinkVerdict -IpAddress $ip -Subnet $subnetTable }.GetNewClosure()
    }
    $blocks = [regex]::Matches($LeaseText, '\{[^}]*\}')
    foreach ($candidateName in $Name) {
        if ([string]::IsNullOrWhiteSpace($candidateName)) { continue }
        # Compile the name pattern once per name; building it inside the
        # block loop forces a fresh regex compile for every block.
        $namePattern = "(?m)^\s*name=$([regex]::Escape($candidateName))\s*$"
        $bestIp = $null
        $bestLease = [int64]-1
        foreach ($b in $blocks) {
            $text = $b.Value
            if ($text -notmatch $namePattern) { continue }
            if ($text -notmatch "(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$") { continue }
            $ip = [string]$Matches[1]
            if (-not (Test-Ipv4Address $ip)) { continue }
            if ($text -notmatch "(?m)^\s*lease=0x([0-9a-fA-F]+)\s*$") { continue }
            $leaseVal = [Convert]::ToInt64($Matches[1], 16)
            if ((& $OnLinkVerdict $ip) -eq 'offlink') {
                Write-Debug "Select-DhcpLeaseIpAddress: rejecting lease $ip for '$candidateName' -- not on any live host interface subnet, so it is unreachable except by the default route."
                continue
            }
            # Strict -gt so an equal or lower expiry block later in the file
            # cannot displace a more recently renewed one already recorded.
            if ($leaseVal -gt $bestLease) { $bestLease = $leaseVal; $bestIp = $ip }
        }
        if ($bestIp) { return $bestIp }
    }
    return $null
}

function Select-StaleDhcpLeaseBlock {
<#
.SYNOPSIS
    Pick the lease blocks in macOS `/var/db/dhcpd_leases` that a name lookup
    could mistake for a live guest, and that provably are not one.
.DESCRIPTION
    macOS files each lease under the name the guest sent and never prunes, so
    a VM name that is rebuilt accumulates one block per incarnation. Only the
    newest is real; the rest are indistinguishable from it to a name lookup
    except by expiry, which is the whole reason Select-DhcpLeaseIpAddress has
    to guess at all. During the seconds a freshly built guest has not yet
    taken its lease, that guess necessarily lands on a predecessor.

    Removing the predecessors removes the guess. What is selected:

      * only names carrying MORE than one block -- a name with a single block
        is the only answer a lookup can give for it, right or wrong, and
        deleting it changes nothing except to lose history;
      * never the largest-expiry block of a name, which is the live guest by
        the same rule Select-DhcpLeaseIpAddress selects it by;
      * never a block whose address is confirmed to be in use, whatever the
        expiry says. -InUseVerdict is the caller's reachability test, and it
        is the veto: an address that answers belongs to something running, and
        an expiry-based heuristic does not get to overrule an observation.
        Its 'unknown' is not a veto -- a probe that could not be run proves
        nothing, and treating that as in-use would select nothing on a host
        where probing is unavailable.

    Blocks with no parseable name, address, or expiry are left alone: they
    cannot be shown stale, and this is a file the DHCP server owns.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Name
    Restrict to these guest names. Empty (the default) considers every name.
.PARAMETER InUseVerdict
    Scriptblock taking one IPv4 string, returning 'inuse' | 'free' | 'unknown'.
    Defaults to treating everything as 'unknown' -- a caller that wants the
    veto passes a real probe.
.OUTPUTS
    Zero or more [pscustomobject] @{ Name; IpAddress; LeaseExpiry; Text },
    newest-expiry first within each name. Callers must normalize with @().
#>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [string[]]$Name = @(),
        [scriptblock]$InUseVerdict
    )
    if ([string]::IsNullOrWhiteSpace($LeaseText)) { return }
    if (-not $InUseVerdict) { $InUseVerdict = { 'unknown' } }
    $wanted = @($Name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $parsed = New-Object System.Collections.Generic.List[pscustomobject]
    foreach ($b in [regex]::Matches($LeaseText, '\{[^}]*\}')) {
        $text = $b.Value
        if ($text -notmatch '(?m)^\s*name=(.+?)\s*$') { continue }
        $blockName = [string]$Matches[1]
        if ($wanted.Count -gt 0 -and $wanted -notcontains $blockName) { continue }
        if ($text -notmatch '(?m)^\s*ip_address=(\d+\.\d+\.\d+\.\d+)\s*$') { continue }
        $ip = [string]$Matches[1]
        if (-not (Test-Ipv4Address $ip)) { continue }
        if ($text -notmatch '(?m)^\s*lease=0x([0-9a-fA-F]+)\s*$') { continue }
        [void]$parsed.Add([pscustomobject]@{
            Name        = $blockName
            IpAddress   = $ip
            LeaseExpiry = [Convert]::ToInt64($Matches[1], 16)
            Text        = $text
        })
    }

    foreach ($group in ($parsed | Group-Object -Property Name)) {
        if ($group.Count -le 1) { continue }
        # Sort once and drop the head: the largest expiry is the live guest,
        # by the same rule the resolver picks it. Ties keep both -- two blocks
        # with one expiry cannot be told apart, so neither is provably stale.
        $ordered = @($group.Group | Sort-Object -Property LeaseExpiry -Descending)
        $keepExpiry = $ordered[0].LeaseExpiry
        foreach ($block in $ordered) {
            if ($block.LeaseExpiry -eq $keepExpiry) { continue }
            $verdict = 'unknown'
            try { $verdict = [string](& $InUseVerdict $block.IpAddress) }
            catch { Write-Debug "Select-StaleDhcpLeaseBlock: the in-use probe for $($block.IpAddress) failed: $_" }
            if ($verdict -eq 'inuse') {
                Write-Debug "Select-StaleDhcpLeaseBlock: keeping $($block.IpAddress) for '$($block.Name)' -- it answers, so the expiry is not the whole story."
                continue
            }
            $block
        }
    }
}

function Remove-DhcpLeaseBlockText {
<#
.SYNOPSIS
    Return `$LeaseText` with the given blocks removed, or the text unchanged
    when none of them are present.
.DESCRIPTION
    Works on the exact block strings Select-StaleDhcpLeaseBlock captured, so
    the caller never re-parses and cannot drift from what it decided to
    remove. A block that is no longer found is skipped rather than treated as
    an error: the DHCP server rewrites this file whenever a lease moves, and
    a block that vanished under us is already gone.

    Only whole `{ ... }` blocks and the newline that follows them are cut, so
    the surviving text stays exactly the shape the DHCP server wrote.
.PARAMETER LeaseText
    Full text of the lease file.
.PARAMETER Block
    Objects carrying a .Text property holding the verbatim block.
.OUTPUTS
    [string] the resulting file text.
#>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string transform: returns new text and touches nothing. The caller that writes the lease file is the one carrying ShouldProcess.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$LeaseText,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Block
    )
    $text = [string]$LeaseText
    foreach ($b in @($Block)) {
        $blockText = [string]$b.Text
        if ([string]::IsNullOrEmpty($blockText)) { continue }
        $index = $text.IndexOf($blockText, [System.StringComparison]::Ordinal)
        if ($index -lt 0) { continue }
        $end = $index + $blockText.Length
        # Take the block's trailing newline with it so removals do not leave a
        # growing run of blank lines behind.
        if ($end -lt $text.Length -and $text[$end] -eq "`r") { $end++ }
        if ($end -lt $text.Length -and $text[$end] -eq "`n") { $end++ }
        $text = $text.Remove($index, $end - $index)
    }
    return $text
}

function Get-UtmGuestSeedHostname {
<#
.SYNOPSIS
    Read the hostname a UTM guest was seeded with, or fall back to the VM name.
.DESCRIPTION
    A sequence can pin `variables.hostname`, which the per-guest New-VM
    substitutes into the cloud-init meta-data as `local-hostname:` before
    baking the seed ISO. The guest then DHCP-registers under that name, not
    under the VM name, so anything keyed on the VM name is looking for the
    wrong string.

    The baked seed at <bundle>/Data/seed.iso is the only durable record of
    that value on the host: the staging directory under
    $HOME/yuruna/image/<image>/seed_temp/ is deleted at the end of New-VM.
    ISO9660 stores the file uncompressed, so the raw bytes can be searched
    directly -- no `hdiutil attach` and no mount point to clean up.

    Degrades to $VMName and never throws. Guests whose meta-data hardcodes
    a hostname, guests with no cloud-init seed at all, and a bundle that has
    not been built yet must all keep working; a missing seed means "no
    hostname was pinned", which is exactly the VM-name case.
.PARAMETER VMName
    The VM name, used both to locate the bundle and as the fallback.
.PARAMETER BundleRoot
    Directory holding the `<VMName>.utm` bundles.
.OUTPUTS
    [string] the pinned hostname, or $VMName.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$BundleRoot = (Join-Path $HOME 'yuruna/guest.nosync')
    )
    try {
        $seedPath = Join-Path $BundleRoot "$VMName.utm" -AdditionalChildPath 'Data', 'seed.iso'
        if (-not (Test-Path -LiteralPath $seedPath)) { return $VMName }
        # Latin1 round-trips every byte to a char, so a binary image can be
        # regexed without a decoder rejecting or substituting anything.
        $bytes = [System.IO.File]::ReadAllBytes($seedPath)
        $text = [System.Text.Encoding]::Latin1.GetString($bytes)
        if ($text -match '(?m)^local-hostname:\s*(\S+)\s*$') {
            $pinned = $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($pinned)) { return [string]$pinned }
        }
    } catch {
        Write-Debug "Get-UtmGuestSeedHostname: seed read failed for ${VMName}: $($_.Exception.Message)"
    }
    return $VMName
}

function ConvertTo-MemoryStartupBytes {
<#
.SYNOPSIS
    Parse a memory size (plain bytes, or a KB/MB/GB/TB-suffixed number) into an
    [int64] byte count.
.DESCRIPTION
    Normalizes the value of a sequence `variables.memoryStartupBytes` for the
    per-guest New-VM.ps1 scripts, so an author can write `34359738368`,
    `32768MB`, or `32GB` interchangeably. Suffixes are binary (1 KB = 1024
    bytes), matching PowerShell's own `1MB`/`1GB` literals -- so `32GB` yields
    the same 34359738368 the scripts would get from a raw `32GB` literal.

    Empty / whitespace / null returns 0 -- the "unset; keep the per-guest
    default" sentinel every caller checks with `-gt 0`. A non-numeric value, a
    bad suffix, or a non-positive size throws so a typo fails the build loudly
    instead of silently reverting to the default.
.PARAMETER Value
    The raw sequence-variable value (already stringified by the planner cascade).
.OUTPUTS
    [int64] byte count, or 0 when unset.
#>
    [OutputType([int64])]
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The noun mirrors the memoryStartupBytes sequence variable it parses and the Hyper-V MemoryStartupBytes property it feeds; a singular rename would break that one-to-one mapping with the field name authors write.')]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [int64]0 }
    $t = $Value.Trim()
    $m = [regex]::Match($t, '^(?<num>\d+)\s*(?<unit>KB|MB|GB|TB|KiB|MiB|GiB|TiB|B)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) {
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_c8d5acba93bb94a2' -Arguments @{ value = "$Value" })
    }
    $num  = [int64]$m.Groups['num'].Value
    $unit = $m.Groups['unit'].Value.ToUpperInvariant()
    # PowerShell's 1KB/1MB/1GB/1TB literals are binary multipliers; reuse them so
    # a suffixed value and the equivalent bare literal agree to the byte.
    $mult = switch ($unit) {
        'KB'  { 1KB } 'KIB' { 1KB }
        'MB'  { 1MB } 'MIB' { 1MB }
        'GB'  { 1GB } 'GIB' { 1GB }
        'TB'  { 1TB } 'TIB' { 1TB }
        default { 1 }   # bytes / explicit 'B' / no suffix
    }
    $bytes = [int64]$num * [int64]$mult
    if ($bytes -le 0) {
        throw (Format-YurunaOperatorMessage -Key 'automation.operator_4e2d63d457a25a3e' -Arguments @{ value = "$Value" })
    }
    return $bytes
}

# Service-VM sizing/overhead methodology: see
# ../docs/architecture.md#service-vm-memory-budget -- Yuruna.Common.psm1
$script:ServiceVmResidentOverheadFactor = 1.24

# See ../docs/architecture.md#service-vm-memory-budget for why this reserve is
# fixed rather than a fraction of installed memory. -- Yuruna.Common.psm1
$script:HostMemoryReserveMb = 8192

function Get-GuestBuilderMemoryMb {
<#
.SYNOPSIS
    The guest memory size, in MiB, that a per-guest New-VM.ps1 states as a
    literal. 0 when it states none.
.DESCRIPTION
    The builders ARE the source of truth for how large a service guest is, so
    this reads them rather than keeping a second copy of the numbers that would
    then have to be kept in step by hand. Each host writes the size in its own
    hypervisor's terms, so all three shapes are recognized:

      * UTM       -- the config.plist placeholder substituted with an MB count;
      * libvirt   -- virt-install's --memory, also MiB;
      * Hyper-V   -- -MemoryStartupBytes / -MemoryMaximumBytes, in bytes, written
                     as a PowerShell size literal.

    A builder that computes its size from a parameter (the general-purpose
    guests take -MemoryStartupBytes from the sequence) states no literal, and
    that reads as 0 -- "not knowable from the source" -- never as a guess. A
    caller must treat 0 as unknown and say so, because a wrong number here would
    be spent in an arithmetic an operator is asked to trust.

    The LARGEST of several statements wins: a builder that creates a VM and then
    pins the same size names it more than once, and if those ever disagree the
    bigger one is what the host has to carry.
.PARAMETER Text
    The builder's source text.
.OUTPUTS
    [int] MiB, or 0.
#>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 0 }
    $sizes = [System.Collections.Generic.List[int64]]::new()
    foreach ($m in [regex]::Matches($Text, "__MEMORY_SIZE__'\s*,\s*'(\d+)'")) {
        [void]$sizes.Add([int64]$m.Groups[1].Value)
    }
    # A builder whose size is a parameter still states it, as that parameter's
    # default -- and that default is what a run which passes nothing will
    # commit. Reading it keeps the arithmetic honest for the builders that took
    # a sizing parameter without turning their number into a guess: a parameter
    # with no literal default still yields nothing here.
    foreach ($m in [regex]::Matches($Text, '\[int\]\$MemoryMb\s*=\s*(\d+)')) {
        [void]$sizes.Add([int64]$m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($Text, "'--memory'\s*,\s*'(\d+)'")) {
        [void]$sizes.Add([int64]$m.Groups[1].Value)
    }
    foreach ($m in [regex]::Matches($Text, '-Memory(?:Startup|Maximum)Bytes\s+(\d+(?:KB|MB|GB|TB)?)\b',
                                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        # Reuses the sequence-variable parser so '12GB' here and '12GB' in a
        # sequence resolve to the same byte count.
        $bytes = 0
        try { $bytes = ConvertTo-MemoryStartupBytes $m.Groups[1].Value } catch { $bytes = 0 }
        if ($bytes -gt 0) { [void]$sizes.Add([int64]($bytes / 1MB)) }
    }
    if ($sizes.Count -eq 0) { return 0 }
    return [int](($sizes | Measure-Object -Maximum).Maximum)
}

function Get-CachingProxyMemoryProfile {
<#
.SYNOPSIS
    The cache VM's RAM and squid cache_mem, as one inseparable pair.
.DESCRIPTION
    These two numbers may never be chosen independently. Swap is masked inside
    the guest, so an over-subscribed cache_mem is an unrecoverable OOM rather
    than a slowdown, and squid's resident set runs about a gigabyte above
    cache_mem for sslcrtd children, connection buffers and in-RAM hot objects.
    Returning them together is what stops one being tuned without the other.

    The smaller pairing is the default, because the host that runs the cache
    beside the stash, the download agent and its own test guests is the ordinary
    case, and every gigabyte here is one those guests cannot have. It is also
    the safer direction to be wrong in: a cache sized for a shared beacon on a
    machine that is not one takes memory from the guests under test, while a
    beacon sized as an ordinary host only shrinks its in-RAM hot set -- the
    on-disk cache_dir is untouched, so a memory miss still lands on local disk
    instead of the network.

    What both pairings hold constant is the headroom above squid, not a
    proportion of the VM: cache_mem + the ~1 GB of resident set above it leaves
    4 GB either way, which is the 2 GB zot needs plus 2 GB for the rest of the
    stack. That is the arithmetic a third pairing has to satisfy -- 3 GB in
    8 GB and 7 GB in 12 GB are 37 % and 58 % of their VMs, so a proportion
    carried across would land in the wrong place.

    -Lab opts into the larger pairing, for a beacon whose cache answers every
    machine in the pool and whose hot set is therefore worth more of the host:
    7 GB cache_mem inside 12 GB leaves roughly 2 GB for the zot registry and
    2 GB for the rest of the stack.
.PARAMETER Lab
    Size for a shared lab beacon rather than a host that runs tests itself.
.OUTPUTS
    [hashtable] VmMemoryMb, SquidCacheMem (a squid size string).
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([switch]$Lab)
    if ($Lab) { return @{ VmMemoryMb = 12288; SquidCacheMem = '7 GB' } }
    return @{ VmMemoryMb = 8192;  SquidCacheMem = '3 GB' }
}

function Get-ServiceVmMemoryMb {
<#
.SYNOPSIS
    The guest memory a service VM will be built with on this host, in MiB.
    0 when the builder is absent or states no literal size.
.DESCRIPTION
    Locates the per-host builder for one service and reads its size out of it.
    The directory is <RepoRoot>/host/<HostFolder>/guest.<Key>-service, which is
    the same path the Start-*ServiceVM.ps1 scripts hand to the host driver: the
    roster key is the extension area's slug with '-service' dropped, so putting
    it back names the area's guest directory.

    Never throws. An unreadable or missing builder is reported as 0 -- unknown --
    so a preflight can say which service it could not size instead of failing on
    a host layout it does not recognize.
.PARAMETER RepoRoot
    Repository root.
.PARAMETER HostFolder
    Host driver folder name, e.g. 'macos.utm' (no 'host/' prefix).
.PARAMETER Key
    Service roster key: caching-proxy, stash, pool-control, download-agent.
.OUTPUTS
    [int] MiB, or 0.
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$HostFolder,
        [Parameter(Mandatory)][string]$Key
    )
    try {
        $builder = Join-Path $RepoRoot 'host' -AdditionalChildPath $HostFolder, "guest.$Key-service", 'New-VM.ps1'
        if (-not (Test-Path -LiteralPath $builder)) { return 0 }
        return (Get-GuestBuilderMemoryMb -Text (Get-Content -Raw -LiteralPath $builder))
    } catch {
        Write-Debug "Get-ServiceVmMemoryMb($HostFolder/$Key): $($_.Exception.Message)"
        return 0
    }
}

function Select-SetupServiceVmKey {
<#
.SYNOPSIS
    The service VMs a setup run will actually bring up, as roster keys, in
    bring-up order.
.DESCRIPTION
    Only what THIS run starts. The four services are not a fixed set: shared
    storage is what the stash and the download agent write to, so a host that
    declined storage entirely never builds either of them, and the pool-control
    service exists only for a lab. Charging a standalone host for services it
    will not start would raise an alarm about memory it is never going to spend.

    The caching proxy is unconditional -- it is the machine the pool services run
    on, and every guest install goes through it. A standalone host's default set
    stops there plus the stash: every further gigabyte a service VM holds is one
    the test guests on the same machine cannot have, so the download agent joins
    only when the config asks for it (a lab runs it by default -- its whole point
    is sharing images across the pool's hosts).
.PARAMETER StorageKind
    The resolved storage.kind. Anything other than 'none' means the shares exist,
    including the empty string: unknown must not read as "no storage", which is
    the answer that hides two services.
.PARAMETER Lab
    This run is setting up a lab.
.PARAMETER DownloadAgentEnabled
    downloadAgentService.enabled as the config states it: $true/$false when the
    operator said so, $null when the key is absent. Unstated resolves by mode --
    on for a lab, off for a standalone host (start it by hand with
    Start-DownloadAgentServiceVM.ps1 when wanted).
.OUTPUTS
    [string[]] roster keys.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyString()][AllowNull()][string]$StorageKind = '',
        [switch]$Lab,
        [AllowNull()][nullable[bool]]$DownloadAgentEnabled = $null
    )
    $keys = [System.Collections.Generic.List[string]]::new()
    [void]$keys.Add('caching-proxy')
    $hasStorage = ("$StorageKind".Trim() -ne 'none')
    if ($hasStorage) { [void]$keys.Add('stash') }
    $agentOn = if ($null -ne $DownloadAgentEnabled) { [bool]$DownloadAgentEnabled } else { [bool]$Lab }
    if ($hasStorage -and $agentOn) { [void]$keys.Add('download-agent') }
    if ($Lab) { [void]$keys.Add('pool-control') }
    return [string[]]$keys.ToArray()
}

function Get-ServiceVmMemoryVerdict {
<#
.SYNOPSIS
    Whether this host can carry the service VMs a run is about to start, with
    the arithmetic that says so.
.DESCRIPTION
    Three levels, and only one of them is an opinion:

      'ok'      -- the host keeps its reserve once the service VMs are resident;
      'warn'    -- it does not, and the message names what it would be left with;
      'unknown' -- either the host's memory or every service's size could not be
                   read, so there is no arithmetic to report.

    WARN, never a hard stop. The configured size is what the hypervisor commits,
    not what the guest touches, and every platform here overcommits: a host whose
    sum exceeds installed memory can still complete a build, slowly, by
    compressing and paging. There is no measurement that says a given
    over-commitment CANNOT work, so refusing to run would block hosts that work
    today, and a preflight that stops a working host is worse than a run that
    finishes with a warning in its report.

    What it counts is what this run brings up. A service VM left running by an
    earlier setup that this one no longer starts still holds its memory, and is
    not in this sum -- the figure is about the plan, not a snapshot of the host.
.PARAMETER Service
    One row per service to be started, with Name (roster key) and MemoryMb.
    MemoryMb of 0 means the size could not be read; those rows are named in the
    message and make the total a floor rather than being guessed at.
.PARAMETER HostMemoryMb
    Installed physical memory, from Get-HostPhysicalMemoryMb. 0 when unknown.
.OUTPUTS
    [pscustomobject] Level, CommittedMb, ResidentMb, HostMemoryMb, RemainingMb,
    ReserveMb, NeededMb, Message, Summary.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][pscustomobject[]]$Service,
        [Parameter(Mandatory)][int]$HostMemoryMb
    )
    $rows      = @($Service | Where-Object { $_ -and $_.Name })
    $known     = @($rows | Where-Object { [int]$_.MemoryMb -gt 0 })
    $unsized   = @($rows | Where-Object { [int]$_.MemoryMb -le 0 } | ForEach-Object { [string]$_.Name })
    $committed = 0
    foreach ($row in $known) { $committed += [int]$row.MemoryMb }
    $resident  = [int][Math]::Round($committed * $script:ServiceVmResidentOverheadFactor)
    $reserve   = [int]$script:HostMemoryReserveMb
    $remaining = [int]$HostMemoryMb - $resident
    $needed    = $resident + $reserve
    $gb        = { param($mb) Format-YurunaOperatorMessage -Key 'automation.memory_size' -FormatValues ([double]$mb / 1024) -FormatBindings @{ size = '0:0.0' } }

    # The per-service breakdown is what makes the total checkable by hand -- and
    # is dropped for a single service, where it would only restate the total.
    $list = if ($known.Count -gt 1) {
        ' (' + (($known | ForEach-Object { '{0} {1}' -f $_.Name, (& $gb ([int]$_.MemoryMb)) }) -join ', ') + ')'
    } else { '' }
    # Named, not folded into the total. A service whose builder could not be read
    # still starts, so the figures are a floor and the operator is told which
    # service is missing from them rather than being handed a guess.
    $floorNote = if ($unsized.Count -gt 0 -and $known.Count -gt 0) {
        Format-YurunaOperatorMessage -Key 'automation.memory_unsized_floor' -Arguments @{ count = $unsized.Count; names = ($unsized -join ', ') }
    } else { '' }

    $verdict = [ordered]@{
        Level        = 'unknown'
        CommittedMb  = $committed
        ResidentMb   = $resident
        HostMemoryMb = [int]$HostMemoryMb
        RemainingMb  = $remaining
        ReserveMb    = $reserve
        NeededMb     = $needed
        Message      = ''
        Summary      = ''
    }
    if ($known.Count -eq 0 -or $HostMemoryMb -le 0) {
        $missing = if ($rows.Count -eq 0) { (Format-YurunaOperatorMessage -Key 'automation.operator_41fce0708182b250') }
                   elseif ($known.Count -eq 0) { (Format-YurunaOperatorMessage -Key 'automation.operator_1fde11cd758abf02' -Arguments @{ join = "$($unsized -join ', ')" }) }
                   else { (Format-YurunaOperatorMessage -Key 'automation.operator_00010ebe540ede32') }
        $verdict.Message = (Format-YurunaOperatorMessage -Key 'automation.operator_77e3426b7eb34748' -Arguments @{ missing = "$missing"; floorNote = "$floorNote" })
        $verdict.Summary = (Format-YurunaOperatorMessage -Key 'automation.operator_d984bd8b6c4ca252')
        return [pscustomobject]$verdict
    }

    # 'sized' appears only when something could not be read, so the count in the
    # sentence always matches the services the total is actually made of.
    $plan = if ($unsized.Count -gt 0) {
        Format-YurunaOperatorMessage -Key 'automation.memory_sized_plan' -Arguments @{ count = $known.Count }
    } else {
        Format-YurunaOperatorMessage -Key 'automation.memory_plan' -Arguments @{ count = $known.Count }
    }
    if ($remaining -ge $reserve) {
        $verdict.Level   = 'ok'
        $verdict.Message = (Format-YurunaOperatorMessage -Key 'automation.operator_4aff59adcc34fceb' -Arguments @{ count = $known.Count } -FormatValues ((& $gb $HostMemoryMb), $plan, $known.Count, (& $gb $committed), $list,
                            (& $gb $resident), (& $gb $remaining), $floorNote) -FormatBindings @{ hostMemoryMb = '0'; plan = '1'; committed = '3'; list = '4'; resident = '5'; remaining = '6'; floorNote = '7' })
        # Phrased without an article in front of the host size: the figure is
        # formatted at run time and '8.0 GB' would need 'an' where '32.0 GB'
        # needs 'a'.
        $verdict.Summary = (Format-YurunaOperatorMessage -Key 'automation.operator_11aa67846cf16f87' -FormatValues ((& $gb $committed), (& $gb $HostMemoryMb), (& $gb $remaining)) -FormatBindings @{ committed = '0'; hostMemoryMb = '1'; remaining = '2' })
        return [pscustomobject]$verdict
    }

    # What this operator can actually change, taken from the plan itself. A lever
    # that does not apply to the run in front of them costs the whole sentence its
    # credibility: a lab may not set storage.kind = none -- the stash and the
    # intent store both need the shares -- so a lab is never offered it.
    #
    # Read off EVERY planned row, not only the sized ones: a service whose builder
    # could not be read is still a service this run starts, and still a service the
    # operator can decline.
    $names  = @($rows | ForEach-Object { [string]$_.Name })
    $isLab  = $names -contains 'pool-control'
    $lever  = [System.Collections.Generic.List[string]]::new()
    $shared = @($rows | Where-Object { $_.Name -in @('stash', 'download-agent') })
    if (-not $isLab -and $shared.Count -gt 0) {
        $sharedMb = 0
        foreach ($row in $shared) { $sharedMb += [int][Math]::Max(0, [int]$row.MemoryMb) }
        $sharedSize = if ($sharedMb -gt 0) { " ($(& $gb $sharedMb))" } else { '' }
        # Named off the PLAN, not off the pair the setting is capable of dropping.
        # A run whose download agent is already switched off would otherwise be
        # told it saves that guest too, while the size beside the sentence counts
        # only the stash -- and a lever whose name and figure disagree is the one
        # sentence here an operator can catch being wrong.
        $sharedNames = if ($shared.Count -eq 2) { Format-YurunaOperatorMessage -Key 'automation.memory_service_names' -Arguments @{ first = [string]$shared[0].Name; second = [string]$shared[1].Name } } else { [string]$shared[0].Name }
        [void]$lever.Add((Format-YurunaOperatorMessage -Key 'automation.operator_a07107e65b3dc315' -Arguments @{ sharedNames = "$sharedNames"; count = $shared.Count; sharedSize = "$sharedSize" }))
    }
    if ($names -contains 'download-agent') {
        $daMb = [int][Math]::Max(0, [int](@($rows | Where-Object { $_.Name -eq 'download-agent' })[0].MemoryMb))
        $daSize = if ($daMb -gt 0) { " ($(& $gb $daMb))" } else { '' }
        [void]$lever.Add((Format-YurunaOperatorMessage -Key 'automation.operator_2cf639068f11200e' -Arguments @{ daSize = "$daSize" }))
    }
    $levers = if ($lever.Count -gt 0) { Format-YurunaOperatorMessage -Key 'automation.memory_reclaim' -Arguments @{ options = ($lever -join '; ') } }
              elseif ($isLab) { (Format-YurunaOperatorMessage -Key 'automation.operator_cb7cb002c87ecc4f') }
              else { (Format-YurunaOperatorMessage -Key 'automation.operator_912a7349029915c6') }

    $shortfall = if ($remaining -ge 0) {
        (Format-YurunaOperatorMessage -Key 'automation.operator_44b14d5da1878689' -FormatValues ((& $gb $remaining)) -FormatBindings @{ value = '0' })
    } else {
        (Format-YurunaOperatorMessage -Key 'automation.operator_7564908a891ca5fd' -FormatValues ((& $gb $resident), (& $gb $HostMemoryMb), (& $gb ([Math]::Abs($remaining)))) -FormatBindings @{ resident = '0'; hostMemoryMb = '1'; remaining = '2' })
    }
    $verdict.Level   = 'warn'
    $verdict.Message = (Format-YurunaOperatorMessage -Key 'automation.operator_d79ea1202ce9e895' -Arguments @{ count = $known.Count } -FormatValues ($shortfall, (& $gb $HostMemoryMb), $plan, $known.Count, (& $gb $committed), $list,
                        (& $gb $resident), (& $gb $reserve), (& $gb $needed), $levers, $floorNote) -FormatBindings @{ shortfall = '0'; hostMemoryMb = '1'; plan = '2'; committed = '4'; list = '5'; resident = '6'; reserve = '7'; needed = '8'; levers = '9'; floorNote = '10' })
    $verdict.Summary = if ($remaining -ge 0) {
        (Format-YurunaOperatorMessage -Key 'automation.operator_c61cf155a222f155' -FormatValues ((& $gb $committed), (& $gb $HostMemoryMb), (& $gb $remaining), (& $gb $reserve)) -FormatBindings @{ committed = '0'; hostMemoryMb = '1'; remaining = '2'; reserve = '3' })
    } else {
        (Format-YurunaOperatorMessage -Key 'automation.operator_93fe53da38102f00' -FormatValues ((& $gb $committed), (& $gb $HostMemoryMb), (& $gb ([Math]::Abs($remaining)))) -FormatBindings @{ committed = '0'; hostMemoryMb = '1'; remaining = '2' })
    }
    return [pscustomobject]$verdict
}

function Get-HostPhysicalMemoryMb {
<#
.SYNOPSIS
    Installed physical memory in MiB, or 0 when this host will not report it.
.DESCRIPTION
    One reading per platform, each the figure that counts the memory the machine
    actually has rather than what is free right now:

      * macOS   -- sysctl hw.memsize (bytes). The absolute path is tried first:
                   /usr/sbin is not on PATH in every non-login shell;
      * Linux   -- /proc/meminfo MemTotal, which is stated in kB;
      * Windows -- Win32_ComputerSystem TotalPhysicalMemory (bytes), which is
                   installed memory less what the firmware reserved -- the amount
                   the OS can actually hand out, which is the useful one here.

    Free memory is deliberately NOT what this returns. A hypervisor allocation is
    held for as long as the VM runs, so the question is what the machine has to
    divide up, not what happens to be unused at the moment the run starts.

    Never throws. 0 means "not knowable here", and a caller must report that
    rather than substituting a default -- an invented host size would be spent in
    an arithmetic presented to an operator as fact.
.OUTPUTS
    [int] MiB, or 0.
#>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try {
        if ($IsMacOS) {
            $sysctl = if (Test-Path -LiteralPath '/usr/sbin/sysctl') { '/usr/sbin/sysctl' } else { 'sysctl' }
            $raw = & $sysctl -n hw.memsize 2>$null
            $bytes = 0L
            if ([int64]::TryParse("$raw".Trim(), [ref]$bytes) -and $bytes -gt 0) { return [int]($bytes / 1MB) }
            return 0
        }
        if ($IsLinux) {
            foreach ($line in (Get-Content -LiteralPath '/proc/meminfo' -ErrorAction Stop)) {
                if ($line -match '^MemTotal:\s+(\d+)\s*kB\s*$') { return [int]([int64]$Matches[1] / 1024) }
            }
            return 0
        }
        if ($IsWindows) {
            $total = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
            if ($total -gt 0) { return [int]([int64]$total / 1MB) }
            return 0
        }
    } catch {
        Write-Debug "Get-HostPhysicalMemoryMb: $($_.Exception.Message)"
    }
    return 0
}

function Get-YurunaServiceVmName {
<#
.SYNOPSIS
    The VM names that host this framework's SERVICES, as opposed to the guests a
    cycle creates and destroys.
.DESCRIPTION
    Concurrency guards exist to keep leftover TEST guests from competing with a
    cycle. These four are the opposite kind of VM: the cycle consumes them. The
    caching proxy serves every guest install, the stash service receives the
    build's binaries, the pool-control service serves the intent store, and the
    download agent serves the guest images every host would otherwise fetch
    from the origin itself.
    Stopping one at cycle start -- or refusing to start because one is running --
    does not free the host; it removes something the cycle is about to require.

    There is one definition because there is more than one guard, and a name
    present in one list and missing from the other produces the worst outcome of
    the two: a service stopped by the first guard, then a refusal from the second
    because it is somehow still running. Callers that let an operator rename a
    service VM pass the new name explicitly.
.OUTPUTS
    System.String[]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@('yuruna-caching-proxy-service', 'yuruna-stash-service', 'yuruna-pool-control-service', 'yuruna-download-agent-service')
}

function Select-NameByPrefix {
<#
.SYNOPSIS
    Filter VM names to those starting with any of $Prefix.
.DESCRIPTION
    Shared by every host driver's Get-VMName so "matches the prefix"
    means the same thing on UTM, Hyper-V and libvirt. Matching is
    literal and case-insensitive: VM names are compared the way the
    hypervisors themselves treat them, and a prefix is a plain string,
    never a wildcard pattern -- an operator prefix containing [ or *
    would otherwise silently behave as a character class and sweep VMs
    it was never meant to name.

    An empty or absent prefix set selects everything. That makes
    Get-VMName with no -Prefix a full inventory call, and it keeps a
    caller that resolved its prefix list to nothing from silently
    matching nothing when it meant "no filter".
.PARAMETER Name
    Candidate names.
.PARAMETER Prefix
    Zero or more literal name prefixes.
.OUTPUTS
    [string[]] the matching names, in input order.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string[]]$Name,
        [string[]]$Prefix
    )
    $candidates = @($Name | Where-Object { $_ })
    if ($candidates.Count -eq 0) { return [string[]]@() }
    $wanted = @($Prefix | Where-Object { $_ })
    if ($wanted.Count -eq 0) { return [string[]]$candidates }
    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        foreach ($p in $wanted) {
            if ($candidate.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$matched.Add($candidate)
                break
            }
        }
    }
    return $matched.ToArray()
}

function Invoke-BoundedNativeCommand {
<#
.SYNOPSIS
    Run a native command under a wall-clock cap with stdin closed and both
    output streams captured and size-bounded, killing the process tree if the
    cap is reached.
.DESCRIPTION
    `& tool args` inherits the caller's stdin, stdout and stderr and then waits
    with no bound. On an unattended host both halves of that are load-bearing:

      * A tool that reaches for the terminal -- a credential prompt, a consent
        dialog, anything that opens the controlling tty -- stops its whole
        process group with SIGTTIN/SIGTTOU when the caller is not the
        foreground job, and nobody is there to resume it
        (feedback_timeout-background-pgrp-tty-stop.md).
      * A tool that talks to a wedged system service simply never returns.
        macOS `osascript` and `utmctl` both ride Apple Events, and an
        unresponsive tccd, appleeventsd or target application blocks the call
        indefinitely -- the tools carry no timeout of their own.

    Either way the caller stops making progress, and the only thing left that
    can end the wait is the runner's step-heartbeat watchdog, which ends the
    whole cycle over a single unanswered probe. Bounding the call turns that
    into a verdict the caller can act on in seconds.

    Closing stdin is what makes an interactive prompt fail rather than wait;
    redirecting both output streams keeps the child off the caller's terminal
    so it can never become a background reader of one.

    A timeout is reported as exit code 124, matching timeout(1) and the other
    bounded wrappers in the repo, with TimedOut set so a caller can tell it
    apart from a tool that ran and refused.

    The immediate child exiting is not the same event as its output streams
    reaching end of file: a client that backgrounds real work in a helper
    process (or simply forks) can exit itself while a descendant keeps both
    pipes open. `WaitForExit` returning `$true` only proves the direct child
    is gone. This function tracks stream end-of-file as a separate condition
    from process exit and never blocks past its own deadline waiting for
    either -- in particular it never touches an async read task's result
    before confirming, through a bounded wait, that the task has actually
    finished; doing so blocks the calling thread for as long as the task
    takes to complete, which can be far longer than any cap the caller
    thought they were getting. `DrainTimedOut` reports exactly that
    situation: the process produced a real exit code, but its streams did
    not reach EOF inside the deadline, so the captured output may be
    incomplete and must not be read as a complete answer.

    Captured output is capped at `MaxCapturedChars` per stream. Once a stream
    hits the cap this function keeps reading (and discarding) from it rather
    than stopping: an OS pipe has a finite buffer, and a reader that simply
    stops taking bytes leaves a still-running, unbounded-output child blocked
    on its next write for as long as it lives -- exactly the kind of hang
    this primitive exists to prevent. `OutputTruncated` reports when either
    stream was cut.
.PARAMETER FilePath
    Command to run: a name resolved on PATH, or a full path to an executable.
.PARAMETER ArgumentList
    Arguments passed through verbatim -- no shell, so no quoting to undo.
.PARAMETER TimeoutSeconds
    Wall-clock cap covering the entire call: launch, execution, and draining
    both streams to EOF. Default 15s: long enough that a merely busy host
    still answers, short enough that a wedged one is reported inside a
    preamble rather than by the watchdog. A confirmed timeout may still cost
    a short, separately bounded allowance beyond this cap while the process
    tree is killed and its pipes given a last chance to close; that allowance
    never re-runs or extends the operation itself.
.PARAMETER Environment
    Extra environment variables for the child only.
.PARAMETER MaxCapturedChars
    Per-stream cap on retained output. Defaults to 256K characters, generous
    for any diagnostic tool this wraps while keeping a runaway or malicious
    writer from growing this call's memory without bound.
.OUTPUTS
    [hashtable] @{ ExitCode; StdOut; StdErr; TimedOut; Started; DrainTimedOut;
    KillFailed; OutputTruncated; ElapsedMs }. The first five keys and their
    values are unchanged from before this primitive was rewritten -- Started
    is $false when the command could not be found or launched at all, where
    ExitCode stays -1 and both streams are empty; TimedOut with ExitCode 124
    means the wall-clock cap was reached. The four new keys add facts this
    version can now detect without changing what existing callers already
    read: DrainTimedOut means a stream had not reached EOF when this call
    returned, so StdOut/StdErr may be incomplete even though ExitCode is
    real; KillFailed means the tree-kill itself threw after a timeout;
    OutputTruncated means a stream was cut at MaxCapturedChars.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 15,
        [hashtable]$Environment,
        [ValidateRange(4096, 67108864)][int]$MaxCapturedChars = 262144
    )
    $result = @{
        ExitCode = -1; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $false
        DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 0
    }
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $resolved = (Get-Command -CommandType Application -Name $FilePath -ErrorAction SilentlyContinue |
        Select-Object -First 1).Source
    if (-not $resolved -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) { $resolved = $FilePath }
    if (-not $resolved) {
        Write-Verbose "Invoke-BoundedNativeCommand: '$FilePath' was not found."
        $result.ElapsedMs = $stopwatch.ElapsedMilliseconds
        return $result
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolved
    foreach ($argument in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$argument) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    if ($Environment) {
        foreach ($key in $Environment.Keys) { $psi.Environment["$key"] = [string]$Environment[$key] }
    }
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Verbose "Invoke-BoundedNativeCommand: could not start '$resolved': $($_.Exception.Message)"
        $result.ElapsedMs = $stopwatch.ElapsedMilliseconds
        return $result
    }
    $result.Started = $true
    # Closed rather than left open and empty: a child that reads stdin gets EOF
    # and gives up, where an open pipe leaves it waiting on input never coming.
    try { $proc.StandardInput.Close() } catch { $null = $_ }

    $capMs = [long]$TimeoutSeconds * 1000
    $cts   = [System.Threading.CancellationTokenSource]::new()

    $outBuf     = [char[]]::new(8192)
    $errBuf     = [char[]]::new(8192)
    $outSb      = [System.Text.StringBuilder]::new()
    $errSb      = [System.Text.StringBuilder]::new()
    $outTrunc   = $false
    $errTrunc   = $false
    $outEof     = $false
    $errEof     = $false
    $exited     = $false
    $killFailed = $false

    # Appends at most enough of Buffer to fill Builder to MaxChars, then keeps
    # silently discarding: the caller's own next ReadAsync call is what
    # actually keeps draining the pipe, this only decides what to keep.
    function Add-BoundedNativeChunk {
        param([System.Text.StringBuilder]$Builder, [char[]]$Buffer, [int]$Count, [int]$MaxChars, [ref]$Truncated)
        if ($Truncated.Value) { return }
        $room = $MaxChars - $Builder.Length
        if ($room -le 0) { $Truncated.Value = $true; return }
        $take = [Math]::Min($room, $Count)
        [void]$Builder.Append($Buffer, 0, $take)
        if ($take -lt $Count) { $Truncated.Value = $true }
    }

    # Both streams and the exit signal are pumped from this one thread via
    # WaitAny, never a background thread: PowerShell scriptblocks are
    # runspace-affinitized and cannot safely run on an arbitrary .NET
    # thread-pool thread the way a raw Task.Run delegate would need to.
    # Task.WaitAny/.Wait(timeoutMs) below never block past the millisecond
    # count given them; only a task those calls have already confirmed
    # finished ever has its GetAwaiter().GetResult() (equivalently .Result)
    # read -- that is the exact guard the prior implementation lacked.
    $outTask  = $proc.StandardOutput.ReadAsync([Memory[char]]::new($outBuf), $cts.Token).AsTask()
    $errTask  = $proc.StandardError.ReadAsync([Memory[char]]::new($errBuf), $cts.Token).AsTask()
    $exitTask = $proc.WaitForExitAsync()

    while (-not ($outEof -and $errEof -and $exited)) {
        $remaining = $capMs - $stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        $pending = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        if (-not $outEof) { [void]$pending.Add($outTask) }
        if (-not $errEof) { [void]$pending.Add($errTask) }
        if (-not $exited) { [void]$pending.Add($exitTask) }
        $slice = [Math]::Min(500, [int]$remaining)
        if ($slice -le 0) { break }
        $idx = [System.Threading.Tasks.Task]::WaitAny($pending.ToArray(), $slice)
        if ($idx -lt 0) { continue }
        $finished = $pending[$idx]
        if ($finished -eq $exitTask -and -not $exited) {
            $exited = $true
            try { $null = $exitTask.GetAwaiter().GetResult() } catch { $null = $_ }
        }
        if ($finished -eq $outTask -and -not $outEof) {
            $n = 0
            try { $n = $outTask.GetAwaiter().GetResult() } catch { $outEof = $true }
            if ($n -le 0) { $outEof = $true }
            else {
                Add-BoundedNativeChunk -Builder $outSb -Buffer $outBuf -Count $n -MaxChars $MaxCapturedChars -Truncated ([ref]$outTrunc)
                $outTask = $proc.StandardOutput.ReadAsync([Memory[char]]::new($outBuf), $cts.Token).AsTask()
            }
        }
        if ($finished -eq $errTask -and -not $errEof) {
            $n = 0
            try { $n = $errTask.GetAwaiter().GetResult() } catch { $errEof = $true }
            if ($n -le 0) { $errEof = $true }
            else {
                Add-BoundedNativeChunk -Builder $errSb -Buffer $errBuf -Count $n -MaxChars $MaxCapturedChars -Truncated ([ref]$errTrunc)
                $errTask = $proc.StandardError.ReadAsync([Memory[char]]::new($errBuf), $cts.Token).AsTask()
            }
        }
    }

    if (-not $exited) {
        # The tree, not just the child: the tools this guards are thin clients
        # that leave the actual work sitting in a helper process of their own,
        # and killing only the client orphans it still holding the resource.
        # This cleanup allowance is separate from, and does not extend, the
        # caller's own TimeoutSeconds cap -- it only bounds how long we wait
        # for the kill itself to take effect and for already-open pipes to
        # close, matching this function's behavior before this rewrite.
        try { $proc.Kill($true) } catch { $killFailed = $true }
        $joinDeadline = [System.Diagnostics.Stopwatch]::StartNew()
        while ($joinDeadline.ElapsedMilliseconds -lt 5000 -and -not ($outEof -and $errEof)) {
            if (-not $outEof -and $outTask.Wait(200)) {
                $n = 0
                try { $n = $outTask.GetAwaiter().GetResult() } catch { $outEof = $true }
                if ($n -le 0) { $outEof = $true } else {
                    Add-BoundedNativeChunk -Builder $outSb -Buffer $outBuf -Count $n -MaxChars $MaxCapturedChars -Truncated ([ref]$outTrunc)
                    $outTask = $proc.StandardOutput.ReadAsync([Memory[char]]::new($outBuf), $cts.Token).AsTask()
                }
            }
            if (-not $errEof -and $errTask.Wait(200)) {
                $n = 0
                try { $n = $errTask.GetAwaiter().GetResult() } catch { $errEof = $true }
                if ($n -le 0) { $errEof = $true } else {
                    Add-BoundedNativeChunk -Builder $errSb -Buffer $errBuf -Count $n -MaxChars $MaxCapturedChars -Truncated ([ref]$errTrunc)
                    $errTask = $proc.StandardError.ReadAsync([Memory[char]]::new($errBuf), $cts.Token).AsTask()
                }
            }
        }
        try { $cts.Cancel() } catch { $null = $_ }
        try { $null = $proc.WaitForExit(1000) } catch { $null = $_ }
        try { $proc.Dispose() } catch { $null = $_ }
        try { $cts.Dispose() } catch { $null = $_ }
        $result.TimedOut        = $true
        $result.ExitCode        = 124
        $result.KillFailed      = $killFailed
        $result.DrainTimedOut   = -not ($outEof -and $errEof)
        $result.OutputTruncated = ($outTrunc -or $errTrunc)
        $result.StdOut          = $outSb.ToString()
        $result.StdErr          = $errSb.ToString()
        $result.ElapsedMs       = $stopwatch.ElapsedMilliseconds
        return $result
    }

    # The process itself exited inside the caller's own deadline, and the loop
    # above already drained both streams for as long as that same deadline
    # allowed, concurrently with waiting for exit. Do not grant extra time
    # here just because the process finished -- a lingering descendant still
    # holding a pipe open must show up as DrainTimedOut, not push this call
    # past the cap the caller asked for.
    $result.DrainTimedOut = -not ($outEof -and $errEof)
    if ($result.DrainTimedOut) { try { $cts.Cancel() } catch { $null = $_ } }
    $result.ExitCode        = [int]$proc.ExitCode
    $result.OutputTruncated = ($outTrunc -or $errTrunc)
    $result.StdOut          = $outSb.ToString()
    $result.StdErr          = $errSb.ToString()
    try { $proc.Dispose() } catch { $null = $_ }
    try { $cts.Dispose() } catch { $null = $_ }
    $result.ElapsedMs = $stopwatch.ElapsedMilliseconds
    return $result
}

function New-YurunaDeadline {
<#
.SYNOPSIS
    Build a boot-relative deadline from a budget in milliseconds, comparable
    across process boundaries on this host.
.DESCRIPTION
    [System.Diagnostics.Stopwatch] resets whenever the process that started it
    exits, so it cannot describe a deadline that must survive the sg group
    re-exec in Invoke-LibvirtGroupReExecIfNeeded, or any other relaunch: the
    child process needs to recompute "how much is left" on its own, without
    the parent's Stopwatch object. [Environment]::TickCount64 is a signed
    64-bit count of milliseconds since boot that every process on the same
    host reads from the same clock, so passing the absolute expiry tick --
    not a remaining-seconds count computed once and never revisited -- lets
    any later process on this host, including one that received only a
    plain [long] over a command line or environment variable, recompute the
    true remaining time at the moment it asks.

    Only ExpiryTick is meant to cross a process boundary; reconstruct a
    deadline object from it with New-YurunaDeadlineFromExpiry rather than
    passing this object itself, which pwsh -File cannot transport anyway.
.PARAMETER TotalMilliseconds
    Budget from the current tick.
.PARAMETER ClockTicks
    Injected clock for tests: a scriptblock returning the current tick as a
    [long]. Defaults to { [Environment]::TickCount64 }.
.OUTPUTS
    [pscustomobject] @{ ExpiryTick; ClockTicks }. Treat ExpiryTick as
    immutable once returned; nothing in this module mutates it.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes, so ShouldProcess would be theater.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$TotalMilliseconds,
        [scriptblock]$ClockTicks
    )
    $clock = if ($ClockTicks) { $ClockTicks } else { { [Environment]::TickCount64 } }
    $now = [long](& $clock)
    return New-YurunaDeadlineFromExpiry -ExpiryTick ($now + $TotalMilliseconds) -ClockTicks $clock
}

function New-YurunaDeadlineFromExpiry {
<#
.SYNOPSIS
    Wrap an already-computed boot-relative expiry tick -- received from a
    parent process, an admitted request's journal, or a relaunch -- as a
    deadline object with the same Get-YurunaDeadlineRemainingMs /
    Test-YurunaDeadlineExpired surface as New-YurunaDeadline.
.PARAMETER ExpiryTick
    A value from [Environment]::TickCount64 on this same host, plus whatever
    budget the original caller applied. Clamping a caller-supplied value to
    an entry's own allowed maximum is the caller's policy, not this
    function's: it stores exactly what it is given.
.PARAMETER ClockTicks
    Injected clock for tests; see New-YurunaDeadline.
.OUTPUTS
    [pscustomobject] @{ ExpiryTick; ClockTicks }
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes, so ShouldProcess would be theater.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][long]$ExpiryTick,
        [scriptblock]$ClockTicks
    )
    $clock = if ($ClockTicks) { $ClockTicks } else { { [Environment]::TickCount64 } }
    return [pscustomobject]@{
        PSTypeName = 'Yuruna.Deadline'
        ExpiryTick = $ExpiryTick
        ClockTicks = $clock
    }
}

function Get-YurunaDeadlineRemainingMs {
<#
.SYNOPSIS
    Milliseconds left on a deadline built by New-YurunaDeadline or
    New-YurunaDeadlineFromExpiry, floored at zero.
.OUTPUTS
    [long]
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <Name>Ms so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][ValidateNotNull()]$Deadline)
    $clock = if ($Deadline.ClockTicks) { $Deadline.ClockTicks } else { { [Environment]::TickCount64 } }
    $now = [long](& $clock)
    return [Math]::Max([long]0, [long]$Deadline.ExpiryTick - $now)
}

function Test-YurunaDeadlineExpired {
<#
.SYNOPSIS
    $true once a deadline's remaining time has reached zero.
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][ValidateNotNull()]$Deadline)
    return (Get-YurunaDeadlineRemainingMs -Deadline $Deadline) -le 0
}

function Get-YurunaDeadlineBoundedSeconds {
<#
.SYNOPSIS
    Remaining whole seconds on a deadline, clamped to a native call's own
    ceiling, or $null when there is no usable time left.
.DESCRIPTION
    Invoke-BoundedNativeCommand declares -TimeoutSeconds as
    [ValidateRange(1, 3600)], and Invoke-UtmctlProbe / Invoke-MacBoundedTool
    narrow that further to 600: passing a computed remainder of 0 or a
    fractional second below 1 throws a parameter-binding error at the call
    site instead of returning a structured refusal. Every call that derives
    its timeout from a shared deadline checks the remaining time through this
    function first and skips the call entirely on $null, rather than ever
    passing a sub-one-second value through to a [ValidateRange(1, ...)]
    parameter.
.PARAMETER Ceiling
    The target parameter's own upper bound (600 for Invoke-UtmctlProbe /
    Invoke-MacBoundedTool, 3600 for Invoke-BoundedNativeCommand itself).
.OUTPUTS
    [Nullable[int]]
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'The plural is the unit, not a collection: a duration is named <Name>Seconds so a bare number cannot be read in the wrong unit.')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][ValidateNotNull()]$Deadline,
        [ValidateRange(1, 3600)][int]$Ceiling = 3600
    )
    $remainingMs = Get-YurunaDeadlineRemainingMs -Deadline $Deadline
    $seconds = [Math]::Floor($remainingMs / 1000.0)
    if ($seconds -lt 1) { return $null }
    return [Math]::Min([int]$seconds, $Ceiling)
}

function Get-YurunaPrivateStateRoot {
<#
.SYNOPSIS
    Resolve, and on first use create and secure, the private per-host-owner
    application-data root at $HOME/.yuruna/host-refresh, beside the existing
    cross-host per-user state Get-HostProxyBackupPath already keeps at
    $HOME/.yuruna.
.DESCRIPTION
    Everything the host-refresh protocol treats as authoritative -- the
    lifetime single-flight lock, the request journal, the recovery snapshot
    -- has to live outside every HTTP-served root. The status server serves
    runtime/, log/, test/status/ and the whole repository by deny-list, not
    allow-list, so anything written under a served tree is public unless its
    name shape happens to be denied; this root is never inside one of those
    trees regardless of naming.

    Refuses, rather than silently degrading to an OS-temp fallback or a
    weaker location, when the resolved path:
      * cannot be created;
      * is a symbolic link or reparse point at any component from $HOME
        down to the leaf -- there is no legitimate reason for this specific
        path to be an alias for something else, and chasing a link only
        reopens the redirect risk it exists to close;
      * is owned (on Unix, via a bounded `stat` call compared against the
        current effective UID) by a user other than the one running this
        process;
      * cannot be locked to owner-only access -- 0700 on Unix, or an ACL
        granting only the current Windows identity full control and
        removing inherited access on Windows.

    A single owning runtime/configuration is registered under this root by
    the request/lock code that package 4 adds; this function only resolves
    and secures the directory itself.
.OUTPUTS
    [pscustomobject] @{ Resolved; Path; Reason }. Trust Path only when
    Resolved is $true. Reason is one of: ok, no-home, create-failed,
    resolve-failed, reparse-point, owner-mismatch, permission-failed.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    if ([string]::IsNullOrWhiteSpace($HOME)) {
        return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'no-home' }
    }
    $stateDir = Join-Path $HOME '.yuruna'
    $root     = Join-Path $stateDir 'host-refresh'

    try {
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $root)) {
            New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        Write-Verbose "Get-YurunaPrivateStateRoot: could not create '$root': $($_.Exception.Message)"
        return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'create-failed' }
    }

    # Every component from $HOME to the leaf must be a plain directory: a
    # symlink or reparse point anywhere in that chain could otherwise
    # redirect this "private" root into a served tree or another user's
    # data, and this path has no legitimate reason to be an alias. Uses the
    # raw .NET FileSystemInfo rather than Get-Item/Test-Path: on this class
    # of sandboxed filesystem a directory just created in this same process
    # can occasionally take a few milliseconds to become visible through
    # PowerShell's own provider layer even though the OS-level view (and
    # System.IO directly) is already consistent, so a single provider-level
    # existence check is not reliable immediately after New-Item.
    foreach ($component in @($stateDir, $root)) {
        $info = $null
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            $candidate = [System.IO.DirectoryInfo]::new($component)
            if ($candidate.Exists) { $info = $candidate; break }
            Start-Sleep -Milliseconds 20
        }
        if (-not $info) {
            return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'resolve-failed' }
        }
        if ($info.LinkTarget) {
            return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'reparse-point' }
        }
    }

    if ($IsWindows) {
        try {
            $acl = Get-Acl -LiteralPath $root
            $acl.SetAccessRuleProtection($true, $false)
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $root -AclObject $acl -ErrorAction Stop
        } catch {
            Write-Verbose "Get-YurunaPrivateStateRoot: ACL hardening failed for '$root': $($_.Exception.Message)"
            return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'permission-failed' }
        }
        return [pscustomobject]@{ Resolved = $true; Path = $root; Reason = 'ok' }
    }

    # Unix: verify ownership with a bounded `stat`, since .NET exposes
    # permission bits but not the owning UID without native interop, then
    # lock the directory to owner-only access.
    $statResult = Invoke-BoundedNativeCommand -FilePath 'stat' -ArgumentList @('-c', '%u', $root) -TimeoutSeconds 5
    if ($statResult.Started -and -not $statResult.TimedOut -and $statResult.ExitCode -eq 0) {
        $ownerUid = ($statResult.StdOut | Select-Object -First 1).Trim()
        $idResult = Invoke-BoundedNativeCommand -FilePath 'id' -ArgumentList @('-u') -TimeoutSeconds 5
        $currentUid = if ($idResult.Started -and $idResult.ExitCode -eq 0) { $idResult.StdOut.Trim() } else { $null }
        if ($currentUid -and $ownerUid -and $ownerUid -ne $currentUid) {
            return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'owner-mismatch' }
        }
    }
    $chmodResult = Invoke-BoundedNativeCommand -FilePath 'chmod' -ArgumentList @('0700', $root) -TimeoutSeconds 5
    if (-not $chmodResult.Started -or $chmodResult.TimedOut -or $chmodResult.ExitCode -ne 0) {
        return [pscustomobject]@{ Resolved = $false; Path = $null; Reason = 'permission-failed' }
    }
    return [pscustomobject]@{ Resolved = $true; Path = $root; Reason = 'ok' }
}

function Get-BoundedNativeOutputLine {
<#
.SYNOPSIS
    Split an Invoke-BoundedNativeCommand result's captured streams into the
    line array a `& tool` call site used to receive.
.DESCRIPTION
    Native output arrives from the bounded runner as one string, while the
    call sites it replaces were written against PowerShell's line-per-element
    array. Converting in one place keeps each of those sites a one-line change
    and keeps "what counts as a line" from drifting between them.

    A timed-out or unlaunched command yields an empty array: there is no
    output to interpret, and inventing an empty string as a line would let a
    caller's first-element read succeed with nothing in it.
.PARAMETER Result
    The hashtable returned by Invoke-BoundedNativeCommand.
.PARAMETER IncludeError
    Append stderr lines after stdout, for a caller that ran the tool to read
    its complaint rather than its answer.
.OUTPUTS
    [string[]]
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Result,
        [switch]$IncludeError
    )
    if (-not $Result.Started -or $Result.TimedOut) { return [string[]]@() }
    $text = [string]$Result.StdOut
    if ($IncludeError -and $Result.StdErr) { $text = ($text.TrimEnd("`r", "`n") + "`n" + [string]$Result.StdErr) }
    if ([string]::IsNullOrEmpty($text)) { return [string[]]@() }
    # Only the trailing empty element is dropped, and only when the text ended
    # on a newline. Interior blank lines are real output -- `pmset -g custom`
    # separates its AC and battery blocks with one -- and a filter that removed
    # every empty element would renumber the rows a caller indexes by position.
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) { [void]$lines.Add([string]$line) }
    while ($lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
        $lines.RemoveAt($lines.Count - 1)
    }
    return [string[]]$lines.ToArray()
}

Export-ModuleMember -Function New-YurunaTimestampedBackup, Get-HostProxyBackupPath, ConvertTo-ProxyHostPort, Get-PortMapStatePath, Test-IsAdministrator, Get-PwshApplicationPath, Get-SudoPwshArgumentList, Invoke-YurunaSudo, Test-YurunaSudoRefusal, Test-YurunaCanPrompt, Assert-YurunaPromptable, Get-CachingProxyServicePort, Get-CachingProxyMemoryProfile, Test-Ipv4Address, Test-Ipv6Address, Format-IpUrlHost, Test-IpAddress, Select-YurunaRoutableAddress, ConvertTo-Sha512CryptHash, ConvertTo-YurunaMacAddress, Get-YurunaHostMacSeed, Get-YurunaGuestMacAddress, Test-YurunaGuestMacMatchesName, ConvertTo-Ipv4UInt32, Get-HostIpv4Subnet, Get-Ipv4OnLinkVerdict, Get-PoolFacingIpv4Segment, Get-Ipv4PoolSegmentVerdict, Test-TcpConnectOutcome, Get-TcpOutcomeExplanation, Select-DhcpLeaseIpAddress, Select-StaleDhcpLeaseBlock, Remove-DhcpLeaseBlockText, Get-UtmGuestSeedHostname, ConvertTo-MemoryStartupBytes, Get-GuestBuilderMemoryMb, Get-ServiceVmMemoryMb, Select-SetupServiceVmKey, Get-ServiceVmMemoryVerdict, Get-HostPhysicalMemoryMb, Select-NameByPrefix, Get-YurunaServiceVmName, Invoke-BoundedNativeCommand, Get-BoundedNativeOutputLine, New-YurunaDeadline, New-YurunaDeadlineFromExpiry, Get-YurunaDeadlineRemainingMs, Test-YurunaDeadlineExpired, Get-YurunaDeadlineBoundedSeconds, Get-YurunaPrivateStateRoot
