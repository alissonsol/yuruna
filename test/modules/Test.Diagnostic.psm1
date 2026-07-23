<#PSScriptInfo
.VERSION 2026.07.22
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
         process arg list / ps output. Password auth is preferred
         because it exercises the same stored vault credential the
         failed test sequence actually used, so the capture reflects
         that credential's state.
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
# keep their existing bindings -- same pattern Test.Ssh uses for its own
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

# OCR is used only to verify the echo of the console one-liner before it is
# submitted. It is strictly an accuracy aid on a best-effort debugging path,
# so the import is allowed to fail: a host without the OCR chain must still
# be able to collect diagnostics, just without the pre-Enter check. Every
# consumer re-probes with Get-Command and degrades to 'unknown', so a failed
# import here costs verification and nothing else.
#
# -Global is required, not stylistic. A bare -Force re-import evicts an
# already-global module into THIS module's private scope, and the next
# Get-EnabledOcrProvider call from any other caller then fails with "not
# recognized" (feedback_module_force_import_evicts_global.md).
try {
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrMatch.psm1')  -Force -DisableNameChecking -Global -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1') -Force -DisableNameChecking -Global -ErrorAction Stop
} catch {
    Write-Verbose "Test.Diagnostic: OCR modules unavailable; console echo verification will be skipped. $($_.Exception.Message)"
}

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
    `rm /tmp/yuruna-diag.ps1` cleanup. `rc=$?` captures pwsh's real
    exit BEFORE the rm and re-raises it via `exit $rc`, so the SSH rung
    (which decides success purely on exit code) can't read the rm's 0
    as a clean capture when pwsh actually failed.
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
            "pwsh -NoProfile -File /tmp/yuruna-diag.ps1; rc=`$?; rm -f /tmp/yuruna-diag.ps1; exit `$rc; " +
            "else echo 'diag-bootstrap: yuruna not extracted and status server unreachable' >&2; exit 64; fi")
}

# --- REGION: Save-GuestDiagnostic timeouts
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
    tag -- e.g. 'after.k8s.bootstrap' or 'before.reboot'.
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
        # (Test.Ssh.psm1 header) -- VMs with reused names/IPs present a
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
.PARAMETER NewerThanUtc
    When supplied, a file already present at the target counts as this
    attempt's capture only if its LastWriteTimeUtc is strictly newer than
    this baseline, so a stale same-minute file is not mistaken for arrival.
#>
    [CmdletBinding()]
    # Returns [long] on success, $null on timeout. PSUseOutputTypeCorrectly
    # only validates against the typed returns, so declaring [long] is
    # sufficient; the $null branch carries no type to match.
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$FailureFolderPath,
        [Parameter(Mandatory)][string]$DiagnosticsFileName,
        [int]$TimeoutSeconds = 240,
        [Nullable[datetime]]$NewerThanUtc = $null
    )
    $target  = Join-Path $FailureFolderPath $DiagnosticsFileName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $item = Get-Item -LiteralPath $target
            # Filenames are minute-precision and the Id is caller-supplied, so
            # two same-minute captures target the identical path. Requiring the
            # mtime to advance past the pre-injection baseline stops a stale
            # pre-existing file from being reported as this attempt's upload.
            if ($item.Length -gt 0 -and ($null -eq $NewerThanUtc -or $item.LastWriteTimeUtc -gt $NewerThanUtc)) {
                return [long]$item.Length
            }
        }
        Start-Sleep -Seconds 1
    }
    return $null
}

function Clear-GuestTtyLine {
<#
.SYNOPSIS
    Sends Ctrl-U to the guest console so the tty's line buffer is empty
    before a command is typed into it.
.DESCRIPTION
    Ctrl-U is VKILL in canonical mode: it discards the current input line
    and nothing else. It signals no process, so it is safe to send
    unconditionally -- at a shell prompt, at `login:`, at a password
    prompt, or into a boot console that ignores it entirely. That safety
    is the reason Ctrl-U (and not a bare Enter) opens the console path:
    an Enter would SUBMIT whatever residue is already on the line rather
    than discard it, which is exactly how a partial line becomes an
    executed command.

    In raw-mode full-screen applications (vi, less, a curses installer)
    ^U is a half-page scroll instead of a line kill. That is a benign
    no-op for our purpose, and it is why this is not gated on any
    screen-state check: gating tty hygiene on OCR would make the
    emergency path depend on the OCR path, whose degradation is itself
    a modelled failure class.

    Never throws -- cleanup must not convert a soft diagnostic failure
    into a thrown exception, and a failed clear must not stop the
    payload from being typed.
.PARAMETER VMName
    Guest VM whose console receives the chord.
#>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        [void](Send-Key -VMName $VMName -Key 'CtrlU' -Mechanism gui)
        Start-Sleep -Milliseconds 200
    } catch {
        Write-Verbose "  Diagnostics: console line-buffer clear (Ctrl-U) failed: $($_.Exception.Message)"
    }
}

function Reset-GuestTtyPrompt {
<#
.SYNOPSIS
    Sends Ctrl-C then Enter to the guest console so the next sequence
    step starts on a fresh prompt.
.DESCRIPTION
    Called only after the console rung has already typed its payload
    into the tty. By that point the line is dirty regardless, so this is
    strictly cleanup: without it a partially typed or keystroke-corrupted
    command stays on the line and the FOLLOWING sequence step's text is
    appended to it, landing as extra arguments on a command nobody asked
    for.

    Order is load-bearing. Ctrl-C first DISCARDS the pending line; Enter
    first would EXECUTE it. Ctrl-C is also what makes the resulting guest
    state predictable across contexts -- at a shell it prints ^C and
    redraws, at `login:` or a password prompt it restarts the prompt, and
    at a boot console with no foreground process group it is ignored. The
    trailing Enter then forces the prompt to redraw, the same benign
    nudge sequences already use to make agetty repaint a login.

    Deliberately NOT sent from the rung's pre-typing guards: a Ctrl-C
    into a guest we never touched could interrupt a healthy foreground
    command for no benefit.

    Never throws.
.PARAMETER VMName
    Guest VM whose console receives the chords.
#>
    [CmdletBinding()]
    [OutputType([void])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort console cleanup on an already-dirty tty inside the soft-failing diagnostics path; a -Confirm prompt would stall an unattended failure path and leave the guest console dirty.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        [void](Send-Key -VMName $VMName -Key 'CtrlC' -Mechanism gui)
        Start-Sleep -Milliseconds 200
        [void](Send-Key -VMName $VMName -Key 'Enter' -Mechanism gui)
        Write-Verbose "  Diagnostics: console tty restored (Ctrl-C + Enter) after a failed console rung."
    } catch {
        Write-Verbose "  Diagnostics: console tty restore (Ctrl-C + Enter) failed: $($_.Exception.Message)"
    }
}

# Tuning constants for the pre-Enter console echo check. Named rather than
# inline so the unit tests can state the same numbers the rung enforces.
#
# GramSize 4 is the smallest window that makes a run of one repeated
# character unexplainable while still surviving OCR noise: a single
# misread character invalidates at most GramSize consecutive windows, so
# scattered noise can never accumulate into a long unexplained run.
$script:ConsoleEchoGramSize = 4
# Longest tolerated run of consecutive normalized characters that the
# expected command cannot account for. Calibrated against real captures:
# a correctly typed line yields 16 (the shell prompt, which is genuinely
# not part of the command), while the mildest real keystroke corruption
# yields 135 and the severe one 4362. 80 sits 5x above the healthy value
# and 1.7x below the mildest observed corruption.
$script:ConsoleEchoMaxUnexplainedRun = 80
# Fraction of the command's distinct grams that must appear somewhere in
# the OCR text. Guards gross truncation, where the screen shows only the
# first few characters. Real captures put a healthy line at 52-87% and a
# truncated fragment at 3.5%, so the floor is far from both boundaries.
$script:ConsoleEchoMinCoveragePercent = 20
# Below this many normalized characters there is not enough signal to
# judge, and the verdict is 'unknown' rather than 'corrupt'. This is the
# Vision-returns-nothing case, which happens precisely on the WORST
# corruption (the Swift path crops to the densest text cluster and a wall
# of repeated glyphs defeats it), so an empty read must never be scored as
# healthy either.
$script:ConsoleEchoMinNormalizedLength = 32
# Hard wall-clock cap on one verification round trip (capture + up to two
# OCR engines). Tesseract costs ~1.7s on a clean frame and ~5.4s on a
# corrupted one -- the garbage is slowest to read precisely when it
# matters -- and the screenshot path is separately bounded at 5s.
$script:ConsoleEchoVerifyCapSeconds = 15
# The file-wait window is never shortened below this, no matter how much
# wall clock verification and a retype consumed. A retype that starved the
# upload wait would turn a recovered line into a false timeout.
$script:ConsoleMinFileWaitSeconds = 30

function Get-OcrGramSet {
<#
.SYNOPSIS
    Returns the set of distinct fixed-length character windows in a string.
.DESCRIPTION
    Module-private helper for Test-ConsoleEchoIntact. A HashSet is returned
    by reference (via the unary comma) because PowerShell would otherwise
    unroll it to an object array and cost the O(1) lookup the caller's inner
    loop depends on.
.PARAMETER Text
    Already-normalized text to window.
.PARAMETER Size
    Window length in characters.
#>
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.HashSet[string]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseOutputTypeCorrectly', '',
        Justification = 'The unary-comma return is what preserves the HashSet across the pipeline; the analyzer reads the wrapper array as the return type, while every caller receives the declared HashSet.')]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Size
    )
    $set = [System.Collections.Generic.HashSet[string]]::new()
    for ($i = 0; $i -le $Text.Length - $Size; $i++) {
        [void]$set.Add($Text.Substring($i, $Size))
    }
    return ,$set
}

function Test-ConsoleEchoIntact {
<#
.SYNOPSIS
    Judges whether the console echo of a typed command, as read by OCR,
    is the command we typed -- returning 'intact', 'corrupt' or 'unknown'.
.DESCRIPTION
    Pure function: no screenshot, no OCR engine, no host contact. Given the
    text that was typed and the text OCR read off the screen, it returns a
    verdict. Keeping it pure is what makes the failure signature testable
    against captured samples with no VM in the loop.

    THE HARD CONSTRAINT IS THAT OCR OF A CONSOLE IS VERY NOISY. On a real
    healthy capture the correctly typed line came back as
    "HFhttp:/7192.168.64.1:8080:F=..." -- 'H=' read as 'HF', '//' as '/7',
    ';' as ':', 'curl' as 'cur', '2>&1' as '2>81'. It was also cut off
    two thirds of the way through, because the rest had scrolled or fallen
    outside the recognized region. Any check resembling equality, or any
    check demanding the whole command be visible, rejects every healthy
    capture and makes this last-resort rung strictly worse than no check.

    So the test is not "does the screen match the command" but "does the
    screen contain a long stretch the command cannot explain":

      1. Both strings are normalized through Get-OCRNormalized, which folds
         the known confusion groups (o/O/0/@, l/I/1/i, S/5/s, :/;/. ...) and
         drops the characters OCR routinely invents or loses.
      2. The command's distinct GramSize-character windows form the set of
         everything the screen is allowed to show.
      3. Walking the OCR text, each position is 'explained' if its window is
         in that set. The longest run of consecutive UNEXPLAINED positions is
         the corruption signal. This is the discriminating measure because
         isolated OCR noise can only ever produce a run of at most GramSize,
         whereas a stuck key produces one continuous run hundreds of
         characters long. Measurement starts at the first explained position
         so the shell prompt printed before the command is not counted.
      4. Independently, the fraction of the command's windows that appear
         anywhere in the OCR text is the truncation signal.

    Deliberately NOT used: Test-OCRMatch. It answers "is this prompt on
    screen", splitting its pattern on whitespace and punctuation and
    requiring only that each fragment appear somewhere. Measured against
    the fully corrupted frame it returns true for the pattern
    'rm -f y.ps1 y.txt' -- a predicate built on it never fires.

    Also deliberately not used: the longest run of one repeated character.
    It reads as the obvious test for a stuck key and does not work. On the
    real frames the longest same-character run was 24 on the corrupted
    capture against 25 on the other -- no discrimination at all, because
    ~1400 stuck glyphs do not survive OCR as a clean run; tesseract renders
    them as 'PUPPY PY BBY PPP YB BP...' across 65 lines. Those lines are
    still unexplainable by the command, which is why (3) catches them.

    'unknown' is a first-class verdict and always means "proceed". It is
    returned when the OCR text is too short to judge and when the
    normalizer itself is unavailable. The caller must press Enter on
    'unknown': this is the last-resort diagnostics path, and refusing to
    submit a line we simply could not read loses the capture outright.
.PARAMETER Expected
    The exact text handed to Send-Text.
.PARAMETER OcrText
    Text an OCR engine read from the console screenshot.
.PARAMETER GramSize
    Window length used to decide whether a position is explained.
.PARAMETER MaxUnexplainedRun
    Longest run of unexplained normalized characters still called 'intact'.
.PARAMETER MinCoveragePercent
    Minimum percentage of the command's windows that must appear in the OCR
    text before the echo is considered present at all.
.PARAMETER MinNormalizedLength
    OCR text shorter than this yields 'unknown'.
.OUTPUTS
    [string] one of 'intact', 'corrupt', 'unknown'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OcrText,
        [int]$GramSize            = $script:ConsoleEchoGramSize,
        [int]$MaxUnexplainedRun   = $script:ConsoleEchoMaxUnexplainedRun,
        [int]$MinCoveragePercent  = $script:ConsoleEchoMinCoveragePercent,
        [int]$MinNormalizedLength = $script:ConsoleEchoMinNormalizedLength
    )

    # The normalizer lives in Test.OcrMatch, whose import is allowed to
    # fail. Without it there is no noise-tolerant comparison to make, and
    # guessing is worse than declining to judge.
    if (-not (Get-Command Get-OCRNormalized -ErrorAction SilentlyContinue)) {
        Write-Verbose '  Diagnostics: Get-OCRNormalized unavailable; console echo verification skipped.'
        return 'unknown'
    }
    if ([string]::IsNullOrWhiteSpace($Expected)) { return 'unknown' }

    $normExpected = Get-OCRNormalized -Text $Expected
    $normOcr      = Get-OCRNormalized -Text $OcrText

    if ($normExpected.Length -lt $GramSize) { return 'unknown' }
    # Too little text to distinguish "the screen was unreadable" from "the
    # line was destroyed". Both reach here; only the second is actionable,
    # and we cannot tell them apart, so we decline.
    if ($normOcr.Length -lt $MinNormalizedLength) { return 'unknown' }

    $expectedGrams = Get-OcrGramSet -Text $normExpected -Size $GramSize
    if ($expectedGrams.Count -eq 0) { return 'unknown' }

    # Truncation signal first: if the command is barely on screen at all,
    # the run measurement below has nothing meaningful to anchor to.
    $ocrGrams = Get-OcrGramSet -Text $normOcr -Size $GramSize
    $seen = 0
    foreach ($gram in $expectedGrams) {
        if ($ocrGrams.Contains($gram)) { $seen++ }
    }
    $coveragePercent = 100.0 * $seen / $expectedGrams.Count
    if ($coveragePercent -lt $MinCoveragePercent) {
        Write-Verbose ('  Diagnostics: console echo coverage {0:N1}% below {1}% floor -- echo truncated or absent.' -f $coveragePercent, $MinCoveragePercent)
        return 'corrupt'
    }

    # Corruption signal: the longest stretch the command cannot account
    # for. Counting starts only once something HAS been explained, so the
    # prompt and any banner printed ahead of the command are excluded --
    # they are legitimately not part of the command and are unbounded in
    # length.
    $longestRun  = 0
    $currentRun  = 0
    $anyExplained = $false
    $lastStart   = $normOcr.Length - $GramSize
    for ($i = 0; $i -le $lastStart; $i++) {
        if ($expectedGrams.Contains($normOcr.Substring($i, $GramSize))) {
            $anyExplained = $true
            $currentRun = 0
        } elseif ($anyExplained) {
            $currentRun++
            if ($currentRun -gt $longestRun) { $longestRun = $currentRun }
        }
    }

    if ($longestRun -gt $MaxUnexplainedRun) {
        Write-Verbose ('  Diagnostics: console echo has a {0}-character stretch the command cannot explain (limit {1}) -- keystroke corruption.' -f $longestRun, $MaxUnexplainedRun)
        return 'corrupt'
    }
    Write-Verbose ('  Diagnostics: console echo verified (coverage {0:N1}%, longest unexplained run {1}).' -f $coveragePercent, $longestRun)
    return 'intact'
}

function Get-ConsoleEchoVerdict {
<#
.SYNOPSIS
    Screenshots the guest console, OCRs it, and returns the
    Test-ConsoleEchoIntact verdict for the command just typed.
.DESCRIPTION
    All of the I/O for the echo check, kept out of the predicate so the
    predicate stays unit-testable. Every failure here -- no host driver, no
    OCR engine, a throw from either, or the wall-clock cap -- resolves to
    'unknown', which the caller treats as "proceed". Nothing in this
    function may abort the capture: a broken verifier must cost accuracy,
    never the diagnostic itself.

    Engine order is a cost decision. Vision runs first because it costs
    ~250-390ms regardless of what is on screen, and on a healthy frame its
    verdict ends the check. Tesseract is consulted only when Vision
    declined or flagged, because it costs ~1.7s on a clean frame and ~5.4s
    on a corrupted one. That second opinion is not optional: on the most
    severely corrupted real frame Vision returned an EMPTY string (its
    densest-text-cluster crop is defeated by a wall of repeated glyphs),
    and tesseract is the only engine that saw the damage.

    A 'corrupt' verdict from either engine wins. The screen genuinely holds
    text the command cannot explain, and the recovery it triggers is one
    bounded retype.
.PARAMETER VMName
    Guest whose console is captured.
.PARAMETER Expected
    The text that was typed, passed straight through to the predicate.
.OUTPUTS
    [string] one of 'intact', 'corrupt', 'unknown'.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Expected
    )

    # Get-VMScreenshot only exists once Initialize-YurunaHost has loaded a
    # driver, so it cannot be a module-scope import; probe it at call time,
    # the same way the rung probes Send-Text / Send-Key.
    $screenshot = Get-Command Get-VMScreenshot  -ErrorAction SilentlyContinue
    $ocr        = Get-Command Invoke-OcrProvider -ErrorAction SilentlyContinue
    if (-not $screenshot -or -not $ocr) {
        Write-Verbose '  Diagnostics: screenshot or OCR provider unavailable; console echo verification skipped.'
        return 'unknown'
    }

    $deadline = (Get-Date).AddSeconds($script:ConsoleEchoVerifyCapSeconds)
    $imagePath = $null
    try {
        $imagePath = Get-VMScreenshot -VMName $VMName -Source frame
        if (-not $imagePath -or -not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
            Write-Verbose '  Diagnostics: console screenshot unavailable; echo verification skipped.'
            return 'unknown'
        }

        $verdict = 'unknown'
        foreach ($engine in 'macos-vision', 'tesseract') {
            if ((Get-Date) -ge $deadline) {
                Write-Verbose "  Diagnostics: console echo verification hit its ${script:ConsoleEchoVerifyCapSeconds}s cap; proceeding unverified."
                break
            }
            if (-not (Test-OcrProviderAvailable -Name $engine)) { continue }
            $text = ''
            try {
                $text = [string](Invoke-OcrProvider -Name $engine -ImagePath $imagePath)
            } catch {
                Write-Verbose "  Diagnostics: OCR engine '$engine' failed during echo verification: $($_.Exception.Message)"
                continue
            }
            $engineVerdict = Test-ConsoleEchoIntact -Expected $Expected -OcrText $text
            Write-Verbose "  Diagnostics: console echo verdict from '$engine': $engineVerdict"
            # Corruption is decisive -- act on it without paying for the
            # slower engine. 'intact' from the fast engine also ends the
            # check; only 'unknown' is worth a second opinion.
            if ($engineVerdict -eq 'corrupt') { return 'corrupt' }
            if ($engineVerdict -eq 'intact')  { return 'intact' }
        }
        return $verdict
    } catch {
        Write-Verbose "  Diagnostics: console echo verification errored: $($_.Exception.Message)"
        return 'unknown'
    } finally {
        # The frame is a transient artifact of the check, not a cycle
        # screenshot the operator will look for; the cycle's own screen
        # captures are written elsewhere by the sequence runner.
        if ($imagePath) {
            Remove-Item -LiteralPath $imagePath -Force -ErrorAction SilentlyContinue
        }
    }
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
    # path: /diagnostics/<cycleBase>/<VMName>/<file> -- a bare <VMName>
    # would resolve to the non-existent <logDir>/<VMName>/ on the
    # server. Forward slash is required so bash leaves it intact in
    # the URL; we never embed Windows paths.
    $cycleBase  = Split-Path -Leaf (Split-Path -Parent $FailureFolderPath)
    $vmFolder   = Split-Path -Leaf $FailureFolderPath
    $folderName = if ($cycleBase) { "$cycleBase/$vmFolder" } else { $vmFolder }
    $cmd = New-DiagnosticsConsoleCommand -ServerUrl $endpoint.url `
            -FailureFolderName $folderName -DiagnosticsFileName $DiagnosticsFileName

    Write-Verbose "  Diagnostics: console keystroke fallback via $($endpoint.url) (line length=$($cmd.Length))"

    # Snapshot the target's mtime before typing so a stale same-minute
    # file from an earlier capture can't be mistaken for this upload; the
    # console POST rewrites the file and advances its mtime past this.
    $targetFile = Join-Path $FailureFolderPath $DiagnosticsFileName
    $baselineMtimeUtc = $null
    if (Test-Path -LiteralPath $targetFile -PathType Leaf) {
        try { $baselineMtimeUtc = (Get-Item -LiteralPath $targetFile).LastWriteTimeUtc } catch { $null = $_ }
    }

    # tty hygiene bracket. Everything from the first keystroke onwards runs
    # inside a try/finally so that every way this rung can fail after it has
    # touched the console -- injection throw, upload timeout, or an error
    # from Wait-DiagnosticsFile itself -- leaves the guest on a clean prompt.
    # The guards above return BEFORE this bracket on purpose: nothing was
    # typed there, so there is no dirt to clear and no reason to interrupt
    # the guest.
    $typed     = $false
    $succeeded = $false
    try {
        # Pre-type: discard anything already sitting in the tty's line
        # buffer. Without this, residue concatenates with the first
        # characters of the one-liner and the command is malformed before
        # it is ever submitted.
        Clear-GuestTtyLine -VMName $VMName

        # Send-Text returns $true on success per the host facade; we tolerate
        # $false because some hosts (KVM virsh send-key) don't bubble up a
        # useful status. The deciding signal is whether the file lands on
        # disk before the timeout.
        # Wall clock spent typing and verifying, deducted from the upload
        # wait below so the rung's total stays inside the caller's budget.
        $preEnterClock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Marked before the call, not after: a throw part-way through
            # Send-Text has still delivered some characters to the tty, and
            # that half-line is exactly what the restore has to clear.
            $typed = $true
            [void](Send-Text -VMName $VMName -Text $cmd -Mechanism gui)
            # Brief settle so the last typed char registers before Enter.
            Start-Sleep -Milliseconds 200

            # Verify the echo BEFORE submitting. The transport posts
            # per-character HID events to a global event source, and a key
            # that sticks in autorepeat appends hundreds of copies of one
            # character to the line. Submitting that runs a command nobody
            # wrote; catching it here costs one retype.
            $verdict = Get-ConsoleEchoVerdict -VMName $VMName -Expected $cmd
            if ($verdict -eq 'corrupt') {
                Write-Warning "Invoke-RemoteDiagnosticsConsole: console echo does not match the typed command; clearing the line and retyping once."
                # Ctrl-U discards the corrupted line without submitting it.
                # An Enter here would execute exactly the malformed command
                # we just detected.
                Clear-GuestTtyLine -VMName $VMName
                [void](Send-Text -VMName $VMName -Text $cmd -Mechanism gui)
                Start-Sleep -Milliseconds 200
                $verdict = Get-ConsoleEchoVerdict -VMName $VMName -Expected $cmd
                if ($verdict -eq 'corrupt') {
                    # A second corrupted echo means the tty is not taking
                    # dictation reliably; more typing only burns budget that
                    # the remaining rungs and the cycle still need. Return
                    # the standard failure -- the finally block restores the
                    # prompt, which is what stops the NEXT sequence step from
                    # being appended to this line.
                    Write-Warning "Invoke-RemoteDiagnosticsConsole: console echo still corrupt after one retype; abandoning the console path without submitting."
                    return $failResult
                }
                Write-Verbose '  Diagnostics: console echo verified after retype.'
            }
            [void](Send-Key -VMName $VMName -Key 'Enter' -Mechanism gui)
        } catch {
            Write-Warning "Invoke-RemoteDiagnosticsConsole: keystroke injection threw: $($_.Exception.Message)"
            return $failResult
        }
        $preEnterClock.Stop()

        # TimeoutSeconds is the caller's budget for the whole rung, not just
        # for the upload wait. Echo verification and a possible retype run
        # before that wait, so their measured cost is deducted from the
        # budget rather than added on top -- otherwise a verified-and-
        # retyped capture would overrun the per-command budget that
        # Save-GuestDiagnostic derives from the cycle's total.
        #
        # The floor exists because the deduction must not be able to starve
        # the wait: the guest still has to fetch, run and POST the capture
        # after Enter, and a wait shorter than that is a guaranteed false
        # timeout on a line that was successfully repaired.
        $waitSeconds = $TimeoutSeconds - [int][math]::Ceiling($preEnterClock.Elapsed.TotalSeconds)
        if ($waitSeconds -lt $script:ConsoleMinFileWaitSeconds) {
            $waitSeconds = [math]::Min($script:ConsoleMinFileWaitSeconds, $TimeoutSeconds)
        }

        $bytes = Wait-DiagnosticsFile -FailureFolderPath $FailureFolderPath `
                -DiagnosticsFileName $DiagnosticsFileName -TimeoutSeconds $waitSeconds `
                -NewerThanUtc $baselineMtimeUtc
        if ($null -eq $bytes) {
            Write-Warning "Invoke-RemoteDiagnosticsConsole: diagnostics file did not arrive within ${waitSeconds}s."
            return $failResult
        }
        Write-Verbose "  Diagnostics: console path succeeded (${bytes} bytes uploaded by guest)."
        $succeeded = $true
        return @{ success = $true; output = ''; exitCode = 0; mechanism = 'console' }
    } finally {
        # On success the guest ran the one-liner and returned to its prompt
        # by itself, so an interrupt would be gratuitous. Only a failed rung
        # leaves something on the line worth discarding.
        if ($typed -and -not $succeeded) {
            Reset-GuestTtyPrompt -VMName $VMName
        }
    }
}

function Select-MoreInformativeDiagResult {
    # Fallback picker for the all-rungs-failed manifest: keep whichever failed
    # rung produced the longer captured error text. In practice this ranks only
    # the two SSH rungs (key-ssh, password-ssh) -- they are the only rungs whose
    # failed result carries .output. The console rung POSTs its capture straight
    # to the failure folder and returns output='' (see
    # Invoke-RemoteDiagnosticsConsole), so its candidate is always ignored here.
    # Preferring rung order alone would pin the manifest to key-ssh even when the
    # later password-ssh rung captured the fuller stderr, so length is the
    # content proxy between the two. Length is only a proxy: a verbose low-signal
    # capture (e.g. the pwsh exit-64 usage banner) can outrank a concise real
    # error -- acceptable for a post-mortem debugging aid. A tie keeps the
    # incumbent so an equally sized later rung does not churn the choice; a
    # candidate with no output is ignored, so an empty capture never replaces a
    # real one.
    param($Current, $Candidate)
    if (-not $Candidate -or -not $Candidate.output) { return $Current }
    if (-not $Current -or -not $Current.output) { return $Candidate }
    if (([string]$Candidate.output).Length -gt ([string]$Current.output).Length) { return $Candidate }
    return $Current
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

    The function tries password auth first (it exercises the stored
    vault credential the failed sequence used) and falls back to key
    auth so a Windows host without sshpass still gets a diagnostic.

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
    Tag appended to the saved filename -- see Get-DiagnosticsFileName
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
    # Local alias: the shared console-fallback helpers below take
    # -FailureFolderPath, so map the OutputFolder parameter onto that
    # name once here instead of renaming it on every private helper.
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
    $sshReady = $true
    if (-not (Test.Ssh\Wait-SshReady -VMName $VMName -GuestKey $GuestKey -TimeoutSeconds $waitBudget -PollSeconds 5)) {
        # Do NOT return here. The console-keystroke rung below is the fallback built precisely
        # for the sshd-down / auth-broken / network-partitioned cases -- the exact scenarios
        # where SSH readiness fails. Skip only the two SSH rungs and still give console a chance.
        Write-Warning ("Save-GuestDiagnostic: SSH did not become ready within {0}s for VM '{1}' (mid-reboot, late-binding KVP, or sshd not yet up); skipping SSH rungs, will try the console fallback." -f $waitBudget, $VMName)
        $sshReady = $false
        $attempted += 'ssh-not-ready'
    }

    # Wait-SshReady proved we can reach $user@$target via key auth, so
    # Get-GuestAddress will now return a real IP. Defensive re-check
    # kept so the SSH calls below have a non-VMName target even in the
    # pathological case where the IP unbinds between Wait-SshReady's
    # last poll and here.
    $address = Test.Ssh\Get-GuestAddress -VMName $VMName
    if (-not $address -or $address -eq $VMName) {
        # No routable IP means the SSH rungs cannot run, but the console rung drives the VM
        # console (tty1 keystrokes) and needs no IP -- fall through to it instead of returning.
        Write-Warning "Save-GuestDiagnostic: no routable IP for '$VMName' (guest may be mid-reboot); skipping SSH rungs, will try the console fallback."
        $sshReady = $false
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
    # rungs as their curl-bootstrap fallback -- a console-rung-only
    # bootstrap leaves a gap when SSH is healthy but the guest has not
    # yet extracted the yuruna tarball (e.g. cycle watchdog fired
    # mid-update.sh during the apt-get phase): the SSH command exits 64
    # from pwsh's usage banner and the diagnostic file captures that
    # banner instead of real state. Soft-fail to $null if the endpoint
    # can't be resolved -- the rungs degrade to the bare `pwsh -File`
    # command and the console rung is still the final fallback.
    $bootstrapUrl = $null
    try {
        $endpoint = Resolve-StatusServiceEndpoint -VMName $VMName
        if ($endpoint) { $bootstrapUrl = [string]$endpoint.url }
    } catch {
        Write-Verbose "Save-GuestDiagnostic: Resolve-StatusServiceEndpoint threw: $($_.Exception.Message)"
    }

    # Strategy chain (keyed SSH -> password SSH -> console). The all-rungs-failed
    # fallback keeps the SSH rung with the fuller captured error text; the
    # console rung POSTs its capture to disk and adds no manifest text:
    # https://yuruna.link/test/harness
    $fileName = Get-DiagnosticsFileName -Id $Id
    $outPath  = Join-Path $FailureFolderPath $fileName

    $result      = $null
    $lastResult  = $null
    # $attempted was hoisted to the top of the function so the early-
    # return manifests below can include rungs that were tried.

    # Primary: key SSH (most reliable rung on a healthy guest). Skipped when the pre-flight
    # showed SSH is unreachable -- the console rung below is the fallback for that case.
    $keyBudget = if ($sshReady) { Get-PerCmdBudget } else { 0 }
    if (-not $sshReady) {
        Write-Verbose "  Diagnostics: SSH not reachable; skipping key-ssh rung."
    } elseif ($keyBudget -le 0) {
        Write-Warning ("Save-GuestDiagnostic: total {0}s budget exhausted before key-ssh rung; skipping further rungs." -f $script:SaveGuestDiagnosticTotalTimeoutSeconds)
    } else {
        $attempted += 'key-ssh'
        Write-Verbose ("  Diagnostics: ssh {0}@{1} (key auth via yuruna_ed25519, budget {2}s)" -f $user, $address, $keyBudget)
        $keyResult = Invoke-RemoteDiagnosticsKeySsh `
            -VMName $VMName -GuestKey $GuestKey -TimeoutSeconds $keyBudget `
            -BootstrapUrl $bootstrapUrl
        Test-DiagSshTimeoutHit -Result $keyResult -Rung 'key-ssh'
        $lastResult = Select-MoreInformativeDiagResult -Current $lastResult -Candidate $keyResult
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
        } elseif ($sshReady -and $sshpassPath -and $password) {
            $attempted += 'password-ssh'
            Write-Verbose ("  Diagnostics: ssh {0}@{1} (password auth via sshpass, budget {2}s)" -f $user, $address, $pwBudget)
            $passwordResult = Invoke-RemoteDiagnosticsPasswordSsh `
                -User $user -Address $address -Password $password `
                -SshpassPath $sshpassPath -TimeoutSeconds $pwBudget `
                -BootstrapUrl $bootstrapUrl
            Test-DiagSshTimeoutHit -Result $passwordResult -Rung 'password-ssh'
            $lastResult = Select-MoreInformativeDiagResult -Current $lastResult -Candidate $passwordResult
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
                if (-not $sshReady) { 'SSH not reachable' }
                elseif (-not $sshpassPath) { 'sshpass not on PATH' }
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
            $lastResult = Select-MoreInformativeDiagResult -Current $lastResult -Candidate $consoleResult
            Write-Verbose "  Diagnostics: console failed (exit=$($consoleResult.exitCode))."
        }
    }

    # All rungs exhausted -- surface whatever output we collected so the
    # operator sees error text instead of an empty folder.
    if (-not $result) {
        if (-not $lastResult) {
            # No rung produced any guest output (all failed early or were
            # skipped for budget). A header-only stub reads like a capture
            # but holds no guest state; an empty per-guest folder is the
            # clearer signal, so skip the write and return nothing on disk.
            Write-Verbose "  Diagnostics: no rung produced output for VM '$VMName'; leaving folder empty rather than writing a header-only stub."
            return @{ success=$false; outPath=$null; mechanism='none'; attempted=$attempted; exitCode=-1; bytes=0L; skipped=$false; reason='(all diagnostics rungs failed: no guest output)' }
        }
        $result = $lastResult
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
    New-DiagnosticsConsoleCommand, `
    Test-ConsoleEchoIntact
