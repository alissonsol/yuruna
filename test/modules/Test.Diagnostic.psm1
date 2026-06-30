<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456712
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostics failure cross-platform
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
    Collects post-failure system diagnostic captures from a guest VM
    and drops them into the per-guest cycleGuestDataFolder next to the
    screenshot and OCR text.

.DESCRIPTION
    Runs automation/Get-SystemDiagnostic.ps1 inside the guest over SSH
    and writes the captured output to:
        <OutputFolder>/<yyyy-MM-dd.HH-mm>.system.diagnostic.<Id>.txt
    where <Id> is the caller-supplied tag from the 'id' field of a
    saveSystemDiagnostic sequence step. The dashboard tile links
    straight into the cycleGuestDataFolder so every capture in the
    cycle is visible to the operator with one click.

    Authentication strategy (intentional, ordered, cross-platform):
      1. password via `sshpass -e` -- the password is loaded into the
         SSHPASS env var of the spawned job so it never reaches the
         process arg list / ps output. This is the path the user asked
         for: "use the currently stored password for the current user
         of the test sequence that failed."
      2. fallback to the harness's per-host ed25519 key when sshpass is
         not installed (Windows out-of-box). Pure pwsh ssh works on
         every host so we get diagnostics even where the password path
         isn't available; the operator can install sshpass to upgrade.
      3. SECOND-DEFENCE console keystroke injection. When SSH itself is
         unavailable (sshd down, network partition, or auth genuinely
         the bug we're trying to debug), we fall back to typing a one-
         liner into the guest's tty1 via the Yuruna.Host Send-Text
         contract. The one-liner curls Get-SystemDiagnostic.ps1 from
         the host's status server, runs it locally, and POSTs the
         result back to the host's /diagnostics/<folder>/<file>
         endpoint, which writes it directly into the per-guest folder.
         Precondition: an interactive shell is sitting at the guest's
         tty1 (the failure path tends to leave one there after a
         passwd / login retry). The function will time out and
         degrade quietly if the keystrokes go into the void.

    Side-effect-free on the guest: Get-SystemDiagnostic.ps1 is a pure
    read-only dump and we never elevate.
#>

# -Global so callers that have already imported Test.VMUtility / Test.Ssh
# keep their existing bindings — same pattern Test.Ssh uses for its own
# transitive imports.
Import-Module (Join-Path $PSScriptRoot 'Test.VMUtility.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1')        -Force -DisableNameChecking -Global
# Test.Extension loads the active authentication extension; Get-Password
# is exported by that extension and is the source of truth for the
# stored per-user password.
Import-Module (Join-Path $PSScriptRoot 'Test.Extension.psm1')  -Force -Global
# Test.Config provides the mtime-keyed Read-TestConfig cache so
# Resolve-StatusServiceEndpoint doesn't reparse test.config.yml on
# every diagnostic call.
Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1')     -Force -DisableNameChecking -Global

# Remote script path. We deliberately use $HOME (shell-expanded on the
# guest) rather than a hardcoded /home/<user>/ -- works for ec2-user,
# the per-guest test user, ubuntu without any per-guest fork.
$script:RemoteDiagScript = '$HOME/yuruna/automation/Get-SystemDiagnostic.ps1'

function Get-RemoteDiagnosticsCommand {
<#
.SYNOPSIS
    Returns the bash one-liner the SSH rungs run on the guest to
    produce a diagnostic capture, with an optional curl bootstrap
    fallback for the case where the yuruna tarball hasn't yet been
    extracted on the guest.
.DESCRIPTION
    Without -BootstrapUrl, the command is the bare
    `pwsh -NoProfile -File $HOME/yuruna/automation/Get-SystemDiagnostic.ps1`.

    With -BootstrapUrl, the command tests for the materialized script
    first; if absent, it falls through to `curl -fsSL <url>/yuruna-repo
    /automation/Get-SystemDiagnostic.ps1` and runs the downloaded copy
    out of /tmp. This rescues the failure mode where the cycle
    watchdog fires mid-update.sh -- e.g. apt-get update stalled on UTM
    bridge networking before reaching the tarball-extract step -- so
    pwsh would otherwise exit 64 with its usage banner and the
    captured artifact would be useless. The status server's
    /yuruna-repo/ mount serves the host's working tree, so the
    downloaded script is the same one that would have been in the
    tarball.

    Bash conditional rather than `&&` so an exit code from pwsh
    inside the bootstrap branch doesn't suppress the trailing
    `rm /tmp/yuruna-diag.ps1` cleanup.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$BootstrapUrl)

    if ([string]::IsNullOrWhiteSpace($BootstrapUrl)) {
        return "pwsh -NoProfile -File $script:RemoteDiagScript"
    }
    $u      = $BootstrapUrl.TrimEnd('/')
    $remote = $script:RemoteDiagScript
    return ("if [ -f $remote ]; then " +
            "pwsh -NoProfile -File $remote; " +
            "elif curl -fsSL '$u/yuruna-repo/automation/Get-SystemDiagnostic.ps1' -o /tmp/yuruna-diag.ps1; then " +
            "pwsh -NoProfile -File /tmp/yuruna-diag.ps1; rm -f /tmp/yuruna-diag.ps1; " +
            "else echo 'diag-bootstrap: yuruna not extracted and status server unreachable' >&2; exit 64; fi")
}

# --- Save-GuestDiagnostic timeouts -----------------------------------------
# Module-level on purpose: not a parameter so every caller (sequence
# action, failure-artifact path, ad-hoc test driver) shares the same
# cap. Tune by editing here -- the values below are calibrated for a
# healthy guest finishing in well under a minute, plus a margin for
# the pathological case where one section of Get-SystemDiagnostic
# hangs and we still want to bail before the cycle timer fires.
# Both budgets are enforced explicitly: any SSH call that returns
# 'Timed out after Xs' surfaces a Write-Warning here, and any total
# elapsed beyond $SaveGuestDiagnosticTotalTimeoutSeconds emits a
# closing Write-Warning so the operator sees the cap was hit instead
# of attributing the missing artifact to a connectivity issue.
$script:SaveGuestDiagnosticTotalTimeoutSeconds      = 300   # 5 min wall-clock cap on the whole capture
$script:SaveGuestDiagnosticPerCommandTimeoutSeconds = 60    # 60 s cap on each individual ssh command

function Get-DiagnosticsFileName {
<#
.SYNOPSIS
    Returns the timestamped basename for one diagnostic capture, tagged
    with a caller-supplied identifier.
.DESCRIPTION
    Format: yyyy-MM-dd.HH-mm.system.diagnostic.<Id>.txt (UTC). The
    timestamp is sortable and aligns with the yyyy-MM-ddTHH-mm-ssZ
    convention used elsewhere in test/status/log/. Minute precision is
    intentional: a cycle's per-guest folder is timestamped to the
    second already, so the additional second on the diagnostic file
    would only repeat noise visible in the parent directory name.
    The Id tag is what lets a single cycle hold multiple captures
    (each saveSystemDiagnostic step in a sequence supplies a distinct
    Id) without filenames colliding.
.PARAMETER Id
    Caller-supplied tag appended after 'system.diagnostic.' and before
    '.txt'. Use snake/dot-case (no slashes, no spaces, no '..'). The
    'id' field on each saveSystemDiagnostic sequence step chooses the
    tag — e.g. 'after.k8s.bootstrap' or 'before.reboot'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id
    )
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd.HH-mm')
    return "$stamp.system.diagnostic.$Id.txt"
}

function Resolve-StoredPassword {
<#
.SYNOPSIS
    Look up the currently stored password for a guest's SSH user.
.DESCRIPTION
    Wraps Get-Password (active authentication extension) with the soft-
    fail behavior this module needs: a missing/uninitialized vault must
    NOT throw -- the diagnostics flow has to degrade gracefully to the
    key-based fallback path. The vault is a per-cycle artifact; pre-
    sequence failures (New-VM crashing before any sequence ran) can
    legitimately reach this code with no entry to look up.

    Returns @{ password; reason } so callers can discriminate the three
    distinct failure modes (auth extension not loaded, Get-Password
    not exported, Get-Password threw) instead of collapsing all three to
    a bare $null that leaves the operator guessing which one fired. The
    reason string is short (one phrase) so a caller can log it directly
    into the diagnostic file header / failure NDJSON.

      password  [string] the stored password, or $null on any failure
      reason    [string] 'ok' when password is set, otherwise one of
                  'auth-extension-load-failed',
                  'get-password-not-exported',
                  'get-password-threw',
                  'no-entry'   (Get-Password returned $null)
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Username)
    if (-not (Get-Command Get-Password -ErrorAction SilentlyContinue)) {
        try {
            [void](Import-Extension -Area 'authentication' -RequireSingle)
        } catch {
            Write-Verbose "Save-GuestDiagnostic: auth extension load failed: $($_.Exception.Message)"
            return @{ password = $null; reason = 'auth-extension-load-failed' }
        }
    }
    if (-not (Get-Command Get-Password -ErrorAction SilentlyContinue)) {
        return @{ password = $null; reason = 'get-password-not-exported' }
    }
    try {
        $pw = Get-Password -Username $Username
    } catch {
        Write-Verbose "Save-GuestDiagnostic: Get-Password threw for '$Username': $($_.Exception.Message)"
        return @{ password = $null; reason = 'get-password-threw' }
    }
    if ([string]::IsNullOrEmpty($pw)) {
        return @{ password = $null; reason = 'no-entry' }
    }
    return @{ password = $pw; reason = 'ok' }
}

function Invoke-RemoteDiagnosticsPasswordSsh {
<#
.SYNOPSIS
    Runs Get-SystemDiagnostic.ps1 over SSH using password auth via
    sshpass. Returns @{ success; output; exitCode; mechanism } the same
    shape Invoke-RemoteDiagnosticsKeySsh returns so the caller can pick
    a path without branching on the return shape.
.DESCRIPTION
    SSHPASS is set inside the background job so the password never lives
    in the parent process env (which would inherit into every later
    Start-Process call) and never appears on a process arg list visible
    to /bin/ps or Get-CimInstance Win32_Process. Job-level isolation
    matches the existing Invoke-GuestSsh pattern.

    `-o PreferredAuthentications=password -o PubkeyAuthentication=no`
    forces the password path even when the key happens to be authorized
    in the guest -- so this function genuinely tests the credential the
    operator asked us to use.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Vault extension (Set-Password) stores plaintext by design; SecureString here would force ConvertTo-SecureString -AsPlainText at the caller and not improve security since the secret reaches sshpass via SSHPASS in an isolated child runspace.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'User + Password mirror the sshpass -e contract; PSCredential adds no value when the password is consumed via a native env variable inside a Start-Job.')]
    param(
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$SshpassPath,
        [int]$TimeoutSeconds = 180,
        [string]$BootstrapUrl
    )
    # Outer-scope references so PSScriptAnalyzer treats both as used; their
    # real consumption is via $using:Password / $using:SshpassPath inside
    # the Start-Job below, which the analyzer can't walk into.
    $null = $Password
    $null = $SshpassPath
    $target  = "$User@$Address"
    $command = Get-RemoteDiagnosticsCommand -BootstrapUrl $BootstrapUrl

    $job = Start-Job -ScriptBlock {
        $env:SSHPASS = $using:Password
        # Host-key bypass options must match the Test.Ssh policy
        # (Test.Ssh.psm1 header) — VMs with reused names/IPs present a
        # different host key each cycle, so we never read or write any
        # known_hosts file.
        $out = & $using:SshpassPath -e ssh `
            -o StrictHostKeyChecking=no `
            -o UserKnownHostsFile=/dev/null `
            -o GlobalKnownHostsFile=/dev/null `
            -o PreferredAuthentications=password `
            -o PubkeyAuthentication=no `
            -o ConnectTimeout=10 `
            -o ServerAliveInterval=30 `
            -o LogLevel=ERROR `
            $using:target $using:command 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    }

    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job   -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        return @{
            success   = $false
            output    = "Timed out after ${TimeoutSeconds}s"
            exitCode  = -1
            mechanism = 'password'
        }
    }
    $r = Receive-Job -Job $job
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $exit = [int]$r.ExitCode
    return @{
        success   = ($exit -eq 0)
        output    = ("$($r.Output)").TrimEnd()
        exitCode  = $exit
        mechanism = 'password'
    }
}

function Invoke-RemoteDiagnosticsKeySsh {
<#
.SYNOPSIS
    Runs Get-SystemDiagnostic.ps1 over SSH using the harness's
    per-host ed25519 key. Cross-platform fallback for hosts without
    sshpass installed.
.DESCRIPTION
    Delegates to Invoke-GuestSsh (Test.Ssh) so the BatchMode / host-key
    options are the harness defaults and any future fix to that path
    benefits this function automatically.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$GuestKey,
        [int]$TimeoutSeconds = 180,
        [string]$BootstrapUrl
    )
    $command = Get-RemoteDiagnosticsCommand -BootstrapUrl $BootstrapUrl
    # Test.Ssh is imported -Global at module load, and the Yuruna.Host Send-*
    # dispatchers import Invoke-Sequence -Global, so Test.Ssh stays in the
    # global session through the console rung -- the module-qualified call
    # below resolves without a per-call re-assert.
    $r = Test.Ssh\Invoke-GuestSsh -VMName $VMName -GuestKey $GuestKey `
            -Command $command -TimeoutSeconds $TimeoutSeconds
    return @{
        success   = [bool]$r.success
        output    = [string]$r.output
        exitCode  = [int]$r.exitCode
        mechanism = 'key'
    }
}

function Resolve-StatusServiceEndpoint {
<#
.SYNOPSIS
    Returns the URL the guest should use to reach the host's status
    server, as @{ ip; port; url }, or $null if either piece can't be
    determined.
.DESCRIPTION
    IP comes from the active host driver's Get-GuestReachableHostIp
    (same call site that New-VM.ps1 uses to seed cloud-init); port
    comes from test.config.yml's statusService.port with the 8080
    default the server uses when the field is missing.

    When VMName is supplied and Hyper-V's Get-VMNetworkAdapter is
    available, we resolve the VM's actual vSwitch and pass it as
    -SwitchName to Get-GuestReachableHostIp. Without that hint, the
    Hyper-V driver falls back to the Default Switch IP (172.x.x.x),
    which is unreachable from a guest attached to the External
    vSwitch and produces the symptom "console keystroke fallback
    via http://172.29.32.1:8080 (line length=...) -> 180s timeout"
    even though sshd is healthy and curl from inside the guest to
    the host's LAN IP (192.168.x.x) returns instantly.

    Soft-fails to $null rather than throwing because the console
    fallback is itself an emergency code path -- we don't want a
    missing host driver to swallow what would otherwise be a partial
    SSH-side diagnostic.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$RepoRoot,
        [string]$VMName
    )

    $ip = $null
    if (Get-Command Get-GuestReachableHostIp -ErrorAction SilentlyContinue) {
        try {
            # Hyper-V: look up the VM's switch so Get-GuestReachableHostIp
            # returns the host's LAN IP (External vSwitch) instead of the
            # Default Switch IP. KVM/UTM don't expose Get-VMNetworkAdapter,
            # so the lookup quietly no-ops and we keep the legacy no-arg
            # call -- those drivers have a single-subnet topology where
            # the IP is unambiguous.
            $switchName = $null
            if ($VMName -and (Get-Command Get-VMNetworkAdapter -ErrorAction SilentlyContinue)) {
                try {
                    $adapter = Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop | Select-Object -First 1
                    if ($adapter) { $switchName = [string]$adapter.SwitchName }
                } catch {
                    Write-Verbose "Resolve-StatusServiceEndpoint: Get-VMNetworkAdapter '$VMName' failed: $($_.Exception.Message)"
                }
            }
            if ($switchName) {
                $ip = Get-GuestReachableHostIp -SwitchName $switchName
            } else {
                $ip = Get-GuestReachableHostIp
            }
        } catch { Write-Verbose "Get-GuestReachableHostIp threw: $($_.Exception.Message)" }
    }
    if (-not $ip) { return $null }

    # Resolve port from test.config.yml. RepoRoot is optional; default
    # walks up from $PSScriptRoot (test/modules/) two levels to land on
    # the repo root so a stand-alone import still finds the config.
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $port = 8080
    $configPath = Join-Path $RepoRoot 'test/test.config.yml'
    # Read-TestConfig is mtime+hash cached; repeated diagnostic calls in
    # one cycle do not re-parse the YAML.
    $cfg = Read-TestConfig -Path $configPath
    if ($cfg -and $cfg.statusService.port) { $port = [int]$cfg.statusService.port }
    return @{ ip = [string]$ip; port = [int]$port; url = "http://${ip}:${port}" }
}

function New-DiagnosticsConsoleCommand {
<#
.SYNOPSIS
    Returns the one-line bash command that fetches
    Get-SystemDiagnostic.ps1 from the status server, runs it under
    pwsh on the guest, and POSTs the captured text back to
    /diagnostics/<folder>/<file>.
.DESCRIPTION
    Plain ASCII so every byte maps to a scancode in Invoke-Sequence's
    char table -- the console transport sends scancodes for ` $ ; = / `
    etc and rejects anything outside that table. Single-quoted
    Content-Type and small variable names keep the line short (~240
    chars at default) so 30 ms/char typing finishes in under 8 s.

    Failure modes are intentionally swallowed by the shell side:
      * curl fetch fails  -> pwsh never runs, second curl has nothing
      * pwsh runs but throws -> partial transcript in y.txt is still
                                POSTed (the operator wants to SEE the
                                bug, not have us hide it on exit code)
      * second curl fails -> rm in the trailing `;` still runs so we
                             don't leave artifacts on the guest
#>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor: returns the one-liner string; does not mutate host or guest state. Matches the New-RandomPassword precedent in the auth extension.')]
    param(
        [Parameter(Mandatory)][string]$ServerUrl,
        [Parameter(Mandatory)][string]$FailureFolderName,
        [Parameter(Mandatory)][string]$DiagnosticsFileName
    )
    # `cd /tmp` first so y.ps1/y.txt live somewhere the guest will tolerate
    # without `sudo`. /tmp is world-writable on every guest OS we test
    # against. The trailing rm runs regardless of POST exit code so we
    # leave no breadcrumb on the guest.
    return ("H=$ServerUrl;F=$FailureFolderName;N=$DiagnosticsFileName;" +
            'cd /tmp;' +
            'curl -fsSLo y.ps1 $H/yuruna-repo/automation/Get-SystemDiagnostic.ps1 && ' +
            'pwsh -NoProfile -File y.ps1 > y.txt 2>&1;' +
            "curl -sS -X POST --data-binary @y.txt -H 'Content-Type: text/plain' " +
            '$H/diagnostics/$F/$N;' +
            'rm -f y.ps1 y.txt')
}

function Wait-DiagnosticsFile {
<#
.SYNOPSIS
    Polls $FailureFolderPath/$DiagnosticsFileName until it exists and
    is non-empty, OR the timeout elapses. Returns the file size on
    success, $null on timeout.
.DESCRIPTION
    The console path is best-effort: the guest writes the file
    indirectly via the status server's /diagnostics POST handler, so
    "did it land" is observable on the host filesystem. We poll on a
    1-second cadence -- fast enough to confirm a healthy capture
    within a few seconds of curl returning, slow enough not to
    saturate the disk.
#>
    [CmdletBinding()]
    # Returns [long] on success, $null on timeout. PSUseOutputTypeCorrectly
    # only validates against the typed returns, so declaring [long] is
    # sufficient; the $null branch carries no type to match.
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$FailureFolderPath,
        [Parameter(Mandatory)][string]$DiagnosticsFileName,
        [int]$TimeoutSeconds = 240
    )
    $target  = Join-Path $FailureFolderPath $DiagnosticsFileName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $size = (Get-Item -LiteralPath $target).Length
            if ($size -gt 0) { return [long]$size }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Invoke-RemoteDiagnosticsConsole {
<#
.SYNOPSIS
    Second-defence diagnostics path: types a fetch+run+POST one-liner
    into the guest's tty1 via the Yuruna.Host Send-Text contract and
    waits for the resulting file to appear in the failure folder.
.DESCRIPTION
    Used when SSH is unreachable (sshd not up) or auth is itself the
    bug we're debugging. Requires the active Yuruna.Host driver to
    export Send-Text + Send-Key -- the runner loads these via
    Initialize-YurunaHost before any failure path runs, so they're
    typically available; we degrade quietly with a Write-Warning if
    not.

    Returns the standard @{ success; output; exitCode; mechanism }
    hashtable so Save-GuestDiagnostic's strategy chain can branch
    on the same shape regardless of which path produced the file.
    `output` is the empty string here -- the actual capture is
    written directly into the failure folder by the status server,
    not piped through this function.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$FailureFolderPath,
        [Parameter(Mandatory)][string]$DiagnosticsFileName,
        [int]$TimeoutSeconds = 240
    )
    $failResult = @{ success = $false; output = ''; exitCode = -1; mechanism = 'console' }

    $sendText = Get-Command Send-Text -ErrorAction SilentlyContinue
    $sendKey  = Get-Command Send-Key  -ErrorAction SilentlyContinue
    if (-not $sendText -or -not $sendKey) {
        Write-Warning "Invoke-RemoteDiagnosticsConsole: Send-Text/Send-Key not loaded (Initialize-YurunaHost must run first); skipping console path."
        return $failResult
    }

    $endpoint = Resolve-StatusServiceEndpoint -VMName $VMName
    if (-not $endpoint) {
        Write-Warning "Invoke-RemoteDiagnosticsConsole: could not resolve host status-service URL; skipping console path."
        return $failResult
    }

    # Multi-segment relative folder. The per-guest data folder lives at
    # <logDir>/<cycleBase>/<VMName>/, so the URL path mirrors the disk
    # path: /diagnostics/<cycleBase>/<VMName>/<file>. Older code passed
    # just <VMName>, which resolved to <logDir>/<VMName>/ on the server
    # (non-existent) and was also rejected by the now-obsolete
    # *.failure-screens-* pattern check. Forward slash is required so
    # bash leaves it intact in the URL; we never embed Windows paths.
    $cycleBase  = Split-Path -Leaf (Split-Path -Parent $FailureFolderPath)
    $vmFolder   = Split-Path -Leaf $FailureFolderPath
    $folderName = if ($cycleBase) { "$cycleBase/$vmFolder" } else { $vmFolder }
    $cmd = New-DiagnosticsConsoleCommand -ServerUrl $endpoint.url `
            -FailureFolderName $folderName -DiagnosticsFileName $DiagnosticsFileName

    Write-Verbose "  Diagnostics: console keystroke fallback via $($endpoint.url) (line length=$($cmd.Length))"

    # Send-Text returns $true on success per the host facade; we tolerate
    # $false because some hosts (KVM virsh send-key) don't bubble up a
    # useful status. The deciding signal is whether the file lands on
    # disk before the timeout.
    try {
        [void](Send-Text -VMName $VMName -Text $cmd -Mechanism gui)
        # Brief settle so the last typed char registers before Enter.
        Start-Sleep -Milliseconds 200
        [void](Send-Key -VMName $VMName -Key 'Enter' -Mechanism gui)
    } catch {
        Write-Warning "Invoke-RemoteDiagnosticsConsole: keystroke injection threw: $($_.Exception.Message)"
        return $failResult
    }

    $bytes = Wait-DiagnosticsFile -FailureFolderPath $FailureFolderPath `
            -DiagnosticsFileName $DiagnosticsFileName -TimeoutSeconds $TimeoutSeconds
    if ($null -eq $bytes) {
        Write-Warning "Invoke-RemoteDiagnosticsConsole: diagnostics file did not arrive within ${TimeoutSeconds}s."
        return $failResult
    }
    Write-Verbose "  Diagnostics: console path succeeded (${bytes} bytes uploaded by guest)."
    return @{ success = $true; output = ''; exitCode = 0; mechanism = 'console' }
}

function Save-GuestDiagnostic {
<#
.SYNOPSIS
    SSH into a guest, run Get-SystemDiagnostic.ps1, and write the
    captured output into the per-guest data folder for the current cycle.
.DESCRIPTION
    Called from two places:
      (a) Copy-FailureArtifactsToStatusLog -- on cycle failure, captures
          the post-mortem state right after the screenshot + OCR copy.
      (b) The `saveSystemDiagnostic` sequence action, fired wherever an
          explicit checkpoint step appears in the YAML.

    Soft-failing by contract -- diagnostics are a debugging aid; an
    unreachable guest, a missing pwsh on the guest, a missing vault
    entry, all degrade to a Write-Warning and a return value of $false.
    The outer failure path must NOT be re-thrown by this collection step.

    The function tries password auth first (the operator's stated
    preference) and falls back to key auth so a Windows host without
    sshpass still gets a diagnostic.

.PARAMETER VMName
    Guest VM name as registered with the host hypervisor.
.PARAMETER GuestKey
    Guest identifier (e.g. guest.ubuntu.server.24). Determines the SSH
    login user via Get-GuestSshUser.
.PARAMETER OutputFolder
    Absolute path of the destination folder. Typically the
    cycleGuestDataFolder produced by Get-CycleGuestDataFolder; the
    function creates the folder if it does not yet exist (so a caller
    that only knows the path string need not pre-create it).
.PARAMETER Id
    Tag appended to the saved filename — see Get-DiagnosticsFileName
    for the exact format. Sequence steps supply their own value: the
    saveSystemDiagnostic action requires an 'id' field on each step so
    multiple captures in the same cycle land in distinct files.

    The wall-clock budget for the whole capture, and the per-SSH-call
    timeout for each attempt, are NOT parameters -- they're module-
    level variables ($SaveGuestDiagnosticTotalTimeoutSeconds and
    $SaveGuestDiagnosticPerCommandTimeoutSeconds at the top of this
    file) so every caller picks up the same cap and changes are made
    in one place. The function emits Write-Warning lines when either
    cap is hit so the operator sees the budget was exceeded instead
    of attributing the missing artifact to a connectivity issue.
.OUTPUTS
    [hashtable] manifest with:
        success     [bool]   $true if a diagnostic file was written
        outPath     [string] absolute path of the written file (or $null)
        mechanism   [string] 'key-ssh' | 'password-ssh' | 'console' | 'none'
        attempted   [string[]] rungs tried in order (e.g. 'key-ssh','console')
        exitCode    [int]    exit code from the winning (or last) rung
        bytes       [long]   size of the diagnostic file (0 if not written)
        skipped     [bool]   $true if a precondition aborted before any rung ran
        reason      [string] short reason on skip / failure (or $null)
    Boolean-coercible: callers that did `if ($result)` continue to work
    because PowerShell coerces a non-empty hashtable to $true. Use
    $result.success for explicit pass/fail.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$GuestKey,
        [Parameter(Mandatory)][string]$OutputFolder,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Id
    )
    # Attempted-rung accumulator hoisted to the top so every early-return
    # site can include it in the manifest. Each rung pushes its label
    # before invoking the SSH/console handler.
    $attempted = @()

    # Wall-clock budget for the whole capture. Each downstream call
    # below clamps its own timeout to `min(perCommandCap, remaining)`
    # so a near-deadline rung doesn't overshoot. Surface caps in logs
    # so a stuck cycle's transcript points the operator at the bound.
    $diagStart    = Get-Date
    $diagDeadline = $diagStart.AddSeconds($script:SaveGuestDiagnosticTotalTimeoutSeconds)
    $perCmdCap    = [int]$script:SaveGuestDiagnosticPerCommandTimeoutSeconds
    Write-Verbose ("Save-GuestDiagnostic: total cap {0}s, per-ssh cap {1}s" -f $script:SaveGuestDiagnosticTotalTimeoutSeconds, $perCmdCap)
    function Get-DiagBudgetRemaining {
        $remaining = [int]($diagDeadline - (Get-Date)).TotalSeconds
        if ($remaining -lt 0) { $remaining = 0 }
        return $remaining
    }
    function Get-PerCmdBudget {
        # Clamp the per-command cap to whatever remains in the total
        # budget so a long-running rung at minute 4 of the 5-minute cap
        # can't blow through the cycle's outer timeout.
        $remain = Get-DiagBudgetRemaining
        if ($remain -le 0) { return 0 }
        return [math]::Min($perCmdCap, $remain)
    }
    function Test-DiagSshTimeoutHit {
        # Each Invoke-* rung returns @{ output = "Timed out after Xs" }
        # on its inner Wait-Job timeout. Surface the cap-hit so the
        # operator sees the deadline was reached instead of attributing
        # the missing artifact to a connectivity issue.
        param($Result, [string]$Rung)
        if ($Result -and $Result.output -and ([string]$Result.output) -match 'Timed out after (\d+)s') {
            Write-Warning ("Save-GuestDiagnostic: '{0}' rung hit the {1}s per-ssh-command cap (defined in `$script:SaveGuestDiagnosticPerCommandTimeoutSeconds at the top of Test.Diagnostic.psm1)." -f $Rung, $Matches[1])
        }
    }

    if (-not (Test-Path -LiteralPath $OutputFolder -PathType Container)) {
        try {
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
        } catch {
            Write-Warning "Save-GuestDiagnostic: could not create output folder '$OutputFolder': $($_.Exception.Message)"
            return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=0; bytes=0L; skipped=$true; reason="could not create output folder '$OutputFolder': $($_.Exception.Message)" }
        }
    }
    # Local alias retained so the rest of the function (and the shared
    # console-fallback helpers) keep using FailureFolderPath -- this
    # minimizes the diff and avoids renaming a parameter on every
    # private helper called below.
    $FailureFolderPath = $OutputFolder

    # Module-qualified Test.Ssh calls below: when Save-GuestDiagnostic
    # runs from the failure-artifact path (Invoke-TestInnerRunner's
    # Copy-FailureArtifactsToStatusLog re-imports this module with
    # -Force -Global), PowerShell's nested re-import can lose the bare-
    # name binding to Test.Ssh's exports even though Test.Diagnostic's
    # body imported it -Global at the top. Qualifying the call goes
    # directly through Test.Ssh's command table.
    $user = Test.Ssh\Get-GuestSshUser -GuestKey $GuestKey
    if (-not $user -or $user -eq 'root') {
        # 'root' is Get-GuestSshUser's catch-all return when the guest
        # key is unknown (Windows guests today). Diagnostics over SSH
        # has no sensible path there yet.
        Write-Warning "Save-GuestDiagnostic: no SSH user mapping for guest '$GuestKey'; skipping."
        return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=0; bytes=0L; skipped=$true; reason="no SSH user mapping for guest '$GuestKey'" }
    }

    # Pre-flight (Hyper-V External vSwitch only): actively probe the LAN
    # subnet to populate the host's ARP cache. On the External vSwitch
    # the host is NOT the DHCP server, so passive ARP discovery never
    # finds the guest -- KVP-only discovery via hv_kvp_daemon can take
    # 5-15 min to publish (memory note:
    # hyperv_external_vswitch_arp_discovery). Wait-SshReady will then
    # spin for its entire budget hitting "Could not resolve hostname"
    # because Get-GuestAddress falls back to the VMName when no IP is
    # discoverable. The probe itself is a parallel ICMP sweep over the
    # /24, ~5 s elapsed; subsequent Get-VMIp calls find the guest in
    # the now-populated neighbor cache. Guarded on Get-Command so the
    # call is a no-op on KVM/UTM hosts (whose drivers don't export
    # this function and don't need it -- virsh domifaddr / utmctl /
    # dhcpd_leases already cover those cases).
    if (Get-Command Invoke-YurunaExternalArpProbe -ErrorAction SilentlyContinue) {
        try {
            Write-Verbose "  Diagnostics: pre-probing Yuruna-External /24 to populate ARP cache (KVP can be 5-15 min late)..."
            Invoke-YurunaExternalArpProbe
        } catch {
            Write-Debug "Save-GuestDiagnostic: ARP probe threw: $($_.Exception.Message)"
        }
    }

    # Pre-flight: real-handshake Wait-SshReady gate (mid-reboot races,
    # half-up sshd, late-binding KVP). Budget capped to the cycle's
    # remaining diag budget. Full rationale and trap class:
    # https://yuruna.link/test/harness
    $waitBudget = [math]::Min(180, (Get-DiagBudgetRemaining))
    if ($waitBudget -le 0) {
        Write-Warning ("Save-GuestDiagnostic: total {0}s budget already exhausted before Wait-SshReady; skipping." -f $script:SaveGuestDiagnosticTotalTimeoutSeconds)
        return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=0; bytes=0L; skipped=$true; reason="total $($script:SaveGuestDiagnosticTotalTimeoutSeconds)s budget exhausted before Wait-SshReady" }
    }
    if (-not (Test.Ssh\Wait-SshReady -VMName $VMName -GuestKey $GuestKey -TimeoutSeconds $waitBudget -PollSeconds 5)) {
        Write-Warning ("Save-GuestDiagnostic: SSH did not become ready within {0}s for VM '{1}' (mid-reboot, late-binding KVP, or sshd not yet up); skipping diagnostics capture." -f $waitBudget, $VMName)
        return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=0; bytes=0L; skipped=$true; reason="SSH not ready within ${waitBudget}s for VM '$VMName' (mid-reboot or sshd not yet up)" }
    }

    # Wait-SshReady proved we can reach $user@$target via key auth, so
    # Get-GuestAddress will now return a real IP. Defensive re-check
    # kept so the SSH calls below have a non-VMName target even in the
    # pathological case where the IP unbinds between Wait-SshReady's
    # last poll and here.
    $address = Test.Ssh\Get-GuestAddress -VMName $VMName
    if (-not $address -or $address -eq $VMName) {
        Write-Warning "Save-GuestDiagnostic: Wait-SshReady passed but Get-GuestAddress no longer returns an IP for '$VMName' (guest may have rebooted again); skipping."
        return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=0; bytes=0L; skipped=$true; reason="Get-GuestAddress no longer returns an IP for '$VMName'" }
    }

    $sshpassPath = (Get-Command sshpass -ErrorAction SilentlyContinue)?.Source
    # @{ password; reason } -- preserve $reason so the password-SSH-skip
    # branch below can name the specific failure mode ("no-entry" is the
    # common pre-sequence case; "auth-extension-load-failed" / "get-
    # password-threw" mean something is actually wrong with the vault
    # plumbing and deserves a louder line).
    $pwLookup    = Resolve-StoredPassword -Username $user
    $password    = $pwLookup.password
    $pwReason    = $pwLookup.reason

    # Resolve the host status-service URL once and feed it to BOTH SSH
    # rungs as their curl-bootstrap fallback. The previous chain treated
    # the curl bootstrap as a console-rung-only concern; that left a gap
    # when SSH was healthy but the guest had not yet extracted the yuruna
    # tarball (e.g. cycle watchdog fired mid-update.sh during the apt-get
    # phase). The SSH command then exited 64 from pwsh's usage banner and
    # the diagnostic file ended up containing that banner instead of real
    # state. Soft-fail to $null if the endpoint can't be resolved -- the
    # rungs degrade to the bare `pwsh -File` command and the console rung
    # is still the final fallback.
    $bootstrapUrl = $null
    try {
        $endpoint = Resolve-StatusServiceEndpoint -VMName $VMName
        if ($endpoint) { $bootstrapUrl = [string]$endpoint.url }
    } catch {
        Write-Verbose "Save-GuestDiagnostic: Resolve-StatusServiceEndpoint threw: $($_.Exception.Message)"
    }

    # Strategy chain (keyed SSH -> password SSH -> console) and the
    # $lastResult most-informative-wins fallback policy:
    # https://yuruna.link/test/harness
    $fileName = Get-DiagnosticsFileName -Id $Id
    $outPath  = Join-Path $FailureFolderPath $fileName

    $result      = $null
    $lastResult  = $null
    # $attempted was hoisted to the top of the function so the early-
    # return manifests below can include rungs that were tried.

    # Primary: key SSH (most reliable rung on a healthy guest).
    $keyBudget = Get-PerCmdBudget
    if ($keyBudget -le 0) {
        Write-Warning ("Save-GuestDiagnostic: total {0}s budget exhausted before key-ssh rung; skipping further rungs." -f $script:SaveGuestDiagnosticTotalTimeoutSeconds)
    } else {
        $attempted += 'key-ssh'
        Write-Verbose ("  Diagnostics: ssh {0}@{1} (key auth via yuruna_ed25519, budget {2}s)" -f $user, $address, $keyBudget)
        $keyResult = Invoke-RemoteDiagnosticsKeySsh `
            -VMName $VMName -GuestKey $GuestKey -TimeoutSeconds $keyBudget `
            -BootstrapUrl $bootstrapUrl
        Test-DiagSshTimeoutHit -Result $keyResult -Rung 'key-ssh'
        if ($keyResult.output -and -not $lastResult.output) {
            $lastResult = $keyResult
        }
        if ($keyResult.success) {
            $result = $keyResult
        } else {
            Write-Verbose "  Diagnostics: key SSH failed (exit=$($keyResult.exitCode)); trying password SSH if available."
        }
    }

    # Backup: password SSH. Useful for the early-bootstrap case where
    # the yuruna_ed25519 key hasn't been installed yet; needs sshpass
    # on PATH (Linux-only out of the box -- the macOS installer does
    # not bring it in by design).
    if (-not $result) {
        $pwBudget = Get-PerCmdBudget
        if ($pwBudget -le 0) {
            Write-Warning ("Save-GuestDiagnostic: total {0}s budget exhausted before password-ssh rung; skipping further rungs." -f $script:SaveGuestDiagnosticTotalTimeoutSeconds)
        } elseif ($sshpassPath -and $password) {
            $attempted += 'password-ssh'
            Write-Verbose ("  Diagnostics: ssh {0}@{1} (password auth via sshpass, budget {2}s)" -f $user, $address, $pwBudget)
            $passwordResult = Invoke-RemoteDiagnosticsPasswordSsh `
                -User $user -Address $address -Password $password `
                -SshpassPath $sshpassPath -TimeoutSeconds $pwBudget `
                -BootstrapUrl $bootstrapUrl
            Test-DiagSshTimeoutHit -Result $passwordResult -Rung 'password-ssh'
            if ($passwordResult.output -and -not $lastResult.output) {
                $lastResult = $passwordResult
            }
            if ($passwordResult.success) {
                $result = $passwordResult
            } else {
                Write-Verbose "  Diagnostics: password SSH failed (exit=$($passwordResult.exitCode))."
            }
        } else {
            # Discriminate the three vault-side failure modes so an
            # operator (or remediator) can fix the right thing. The
            # pre-sequence "no-entry" case is benign; the other two
            # mean the vault plumbing itself is broken and the cycle's
            # operator needs to inspect the authentication extension.
            $reason =
                if (-not $sshpassPath) { 'sshpass not on PATH' }
                elseif ($pwReason -eq 'auth-extension-load-failed') { "authentication extension failed to load (no stored password for '$user')" }
                elseif ($pwReason -eq 'get-password-not-exported')  { "authentication extension does not export Get-Password (no stored password for '$user')" }
                elseif ($pwReason -eq 'get-password-threw')         { "Get-Password threw for '$user' (vault may be corrupted)" }
                else                                                 { "no stored password for '$user'" }
            Write-Verbose "  Diagnostics: $reason -- skipping password SSH."
        }
    }

    # Emergency fallback: console keystroke path. Writes directly to
    # disk via POST, so on success we return early and skip the local
    # Set-Content below (otherwise we'd clobber the upload with a
    # header-only body). Used when sshd is unreachable (half-up sshd,
    # auth misconfigured, network partition) -- the only case where
    # typing into tty1 still has a chance.
    if (-not $result) {
        $consoleBudget = Get-PerCmdBudget
        if ($consoleBudget -le 0) {
            Write-Warning ("Save-GuestDiagnostic: total {0}s budget exhausted before console rung; skipping." -f $script:SaveGuestDiagnosticTotalTimeoutSeconds)
        } else {
            $attempted += 'console'
            $consoleResult = Invoke-RemoteDiagnosticsConsole `
                -VMName $VMName -FailureFolderPath $FailureFolderPath `
                -DiagnosticsFileName $fileName -TimeoutSeconds $consoleBudget
            Test-DiagSshTimeoutHit -Result $consoleResult -Rung 'console'
            if ($consoleResult.success) {
                Write-Verbose "  Diagnostics saved: $(Split-Path -Leaf $FailureFolderPath)/$fileName (mechanism=console, attempts=$($attempted -join ','))"
                $consoleBytes = 0L
                try { if (Test-Path -LiteralPath $outPath) { $consoleBytes = [long](Get-Item -LiteralPath $outPath).Length } } catch { Write-Verbose "Save-GuestDiagnostic: outPath size probe failed: $($_.Exception.Message)" }
                return @{ success=$true; outPath=$outPath; mechanism='console'; attempted=$attempted; exitCode=[int]$consoleResult.exitCode; bytes=$consoleBytes; skipped=$false; reason=$null }
            }
            if ($consoleResult.output -and -not $lastResult.output) {
                $lastResult = $consoleResult
            }
            Write-Verbose "  Diagnostics: console failed (exit=$($consoleResult.exitCode))."
        }
    }

    # All rungs exhausted -- surface whatever output we collected so the
    # operator sees error text instead of an empty folder.
    if (-not $result) {
        if ($lastResult) {
            $result = $lastResult
        } else {
            $result = @{ success = $false; output = '(all diagnostics rungs failed: console, key ssh, password ssh)'; exitCode = -1; mechanism = 'none' }
        }
    }

    $body = [System.Text.StringBuilder]::new()
    [void]$body.AppendLine("# Yuruna Diagnostics")
    [void]$body.AppendLine("# VM        : $VMName")
    [void]$body.AppendLine("# Guest     : $GuestKey")
    [void]$body.AppendLine("# SSH user  : $user")
    [void]$body.AppendLine("# Address   : $address")
    [void]$body.AppendLine("# Mechanism : $($result.mechanism)")
    [void]$body.AppendLine("# Exit code : $($result.exitCode)")
    [void]$body.AppendLine("# Captured  : $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
    [void]$body.AppendLine("# ---")
    [void]$body.AppendLine($result.output)

    try {
        # PS7 Set-Content default is BOM-less UTF-8 (per repo memory),
        # which is correct for a plain-text diagnostics dump. We
        # explicitly set the encoding so a future global change to the
        # default doesn't silently shift this file's encoding and
        # confuse downstream readers (browsers serving it as text/plain).
        Set-Content -LiteralPath $outPath -Value $body.ToString() -Encoding utf8 -NoNewline
    } catch {
        Write-Warning "Save-GuestDiagnostic: could not write '$outPath': $($_.Exception.Message)"
        return @{ success=$false; outPath=$outPath; mechanism=[string]$result.mechanism; attempted=$attempted; exitCode=[int]$result.exitCode; bytes=0L; skipped=$false; reason="Set-Content failed: $($_.Exception.Message)" }
    }

    $elapsedSec = [int]((Get-Date) - $diagStart).TotalSeconds
    if ($elapsedSec -gt $script:SaveGuestDiagnosticTotalTimeoutSeconds) {
        Write-Warning ("Save-GuestDiagnostic: total elapsed {0}s exceeded the {1}s cap (`$script:SaveGuestDiagnosticTotalTimeoutSeconds in Test.Diagnostic.psm1) -- rung sequence ran long for VM '{2}'. Inspect SSH responsiveness or raise the cap." -f $elapsedSec, $script:SaveGuestDiagnosticTotalTimeoutSeconds, $VMName)
    }
    Write-Verbose "  Diagnostics saved: $(Split-Path -Leaf $FailureFolderPath)/$fileName (mechanism=$($result.mechanism), exit=$($result.exitCode), elapsed=${elapsedSec}s)"
    $writtenBytes = 0L
    try { if (Test-Path -LiteralPath $outPath) { $writtenBytes = [long](Get-Item -LiteralPath $outPath).Length } } catch { Write-Verbose "Save-GuestDiagnostic: outPath size probe failed: $($_.Exception.Message)" }
    return @{
        success   = [bool]$result.success
        outPath   = $outPath
        mechanism = [string]$result.mechanism
        attempted = $attempted
        exitCode  = [int]$result.exitCode
        bytes     = $writtenBytes
        skipped   = $false
        reason    = if ($result.success) { $null } else { '(all diagnostics rungs failed)' }
    }
}

Export-ModuleMember -Function `
    Save-GuestDiagnostic, `
    Get-DiagnosticsFileName, `
    Resolve-StatusServiceEndpoint, `
    New-DiagnosticsConsoleCommand
