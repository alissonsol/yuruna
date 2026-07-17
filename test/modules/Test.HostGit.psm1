<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42c9d0e1-f2a3-4b45-9678-9a0b1c2d3e42
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host
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

# Git + project-clone helpers: framework auto-update at cycle start
# (Invoke-GitPull), HEAD short-hash reporting, the Restart-Manager /
# PEB cwd scanner that diagnoses Windows file-locker PIDs when
# Remove-Item fails, the wipe-and-re-clone of the project-under-test,
# and the on-demand PSGallery installs (powershell-yaml,
# PSScriptAnalyzer) the runner needs but pwsh 7 doesn't ship.

function Get-GitUpstreamStatus {
    <#
    .SYNOPSIS
        Classify a git working tree vs its upstream: no-tree / no-upstream /
        up-to-date / ahead / behind / diverged.
    .DESCRIPTION
        Pure read-only -- does NOT fetch (each caller fetches its own way first,
        with its own retry / offline policy), so the result reflects whatever
        the local refs currently say. One comparison code path: Invoke-GitPull
        maps the State to a pull/skip/error decision; Test-RepoFreshness
        (Test.ConfigValidator) maps the same State to a PASS/WARN row.
    .OUTPUTS
        [hashtable] @{ State; Ahead; Behind; Local; Remote }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path (Join-Path $Path '.git'))) {
        return @{ State = 'no-tree'; Ahead = 0; Behind = 0; Local = $null; Remote = $null }
    }
    $local = & git -C $Path rev-parse HEAD 2>$null
    if ($local) { $local = "$local".Trim() }
    $remote = & git -C $Path rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $remote) {
        return @{ State = 'no-upstream'; Ahead = 0; Behind = 0; Local = $local; Remote = $null }
    }
    $remote = "$remote".Trim()
    if ($local -eq $remote) {
        return @{ State = 'up-to-date'; Ahead = 0; Behind = 0; Local = $local; Remote = $remote }
    }
    # Count-based classification is equivalent to merge-base: behind == 0 iff
    # remote is an ancestor of local (ahead), ahead == 0 iff local is an
    # ancestor of remote (behind), both > 0 iff the histories diverged.
    $behind = 0; $ahead = 0
    $behindRaw = & git -C $Path rev-list --count "$local..$remote" 2>$null
    $behindExit = $LASTEXITCODE
    $aheadRaw = & git -C $Path rev-list --count "$remote..$local" 2>$null
    $aheadExit = $LASTEXITCODE
    if ($behindExit -ne 0 -or $aheadExit -ne 0 -or
        -not [int]::TryParse("$behindRaw".Trim(), [ref]$behind) -or
        -not [int]::TryParse("$aheadRaw".Trim(), [ref]$ahead)) {
        # A failed / unparseable rev-list count must NOT collapse to 'up-to-date' (a false
        # healthy). Report 'unknown' so callers treat it as WARN/skip rather than clean.
        return @{ State = 'unknown'; Ahead = 0; Behind = 0; Local = $local; Remote = $remote }
    }
    $state = if ($behind -gt 0 -and $ahead -eq 0) { 'behind' }
             elseif ($ahead -gt 0 -and $behind -eq 0) { 'ahead' }
             elseif ($ahead -gt 0 -and $behind -gt 0) { 'diverged' }
             else { 'up-to-date' }
    return @{ State = $state; Ahead = $ahead; Behind = $behind; Local = $local; Remote = $remote }
}

function Test-GitRemoteAuthFailure {
    <#
    .SYNOPSIS
        Pure text classifier: does this git fetch/pull/ls-remote output carry a
        credential / authorization signature (a stale or missing GitHub login),
        as opposed to a network outage or a local-branch condition?
    .DESCRIPTION
        Lets the pull path fail FAST with an actionable "refresh GitHub access"
        message instead of a runner blocking on git's interactive username /
        password prompt. With the credential-prompt env neutralized
        (GIT_TERMINAL_PROMPT=0), a missing credential surfaces as "terminal
        prompts disabled"; an expired / wrong one as "Authentication failed" or
        "Invalid username or password"; a private repo the current identity can
        no longer see as "Repository not found"; an expired PAT / unauthorized
        SSO as an HTTPS "returned error: 401|403"; an SSH key that is not loaded
        as "Permission denied (publickey)". Every one is fixed by refreshing the
        login, not by retrying -- so the caller stops rather than burning its
        retry budget.
    .OUTPUTS
        [bool] $true when the output matches an auth/authorization signature.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }
    return [bool]($Output -match '(?i)(terminal prompts disabled|could not read (Username|Password)|Authentication failed|Invalid username or password|Permission denied \(publickey\)|Repository not found|returned error: 40[13])')
}

function Get-YurunaGitCredentialArg {
    <#
    .SYNOPSIS
        The `git -c ...` arguments that make git authenticate to github.com with
        $env:GH_TOKEN, or an empty array when GH_TOKEN is unset. Pure (reads only
        the environment variable).
    .DESCRIPTION
        Plain `git` does NOT read GH_TOKEN -- only the GitHub CLI (`gh`) does --
        so a host whose only GitHub credential is GH_TOKEN (a headless runner, a
        freshly-imaged pool host, a CI box) fails every https fetch/pull/clone with
        "could not read Username", even though the operator set the token
        expecting git to use it. This returns an inline credential helper, SCOPED
        to https://github.com, that answers git's credential request with the token
        as the password for an x-access-token user.

        Two properties matter:
          * SCOPED to github.com, so the token is never offered to any other
            remote (a private mirror, the LAN pool-intent store, a file:// URL).
          * The helper reads $GH_TOKEN at RUN TIME from the environment git passes
            it, so the token value never appears on a command line (visible to
            `ps`), in git config, or in a log -- only the fixed helper string and
            the literal variable name `$GH_TOKEN` do.

        GitHub tokens are `[A-Za-z0-9_]` (classic) or `github_pat_[A-Za-z0-9_]`
        (fine-grained), so the unquoted `$GH_TOKEN` expansion in the POSIX-sh
        helper is shell-safe. The `!`-prefixed helper runs under git's shell
        (`/bin/sh`, or Git-for-Windows' bundled sh), so it is cross-platform.
    .OUTPUTS
        [string[]] -- the -c argument pairs, or an empty array when no token.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'Returns a [string[]] of git -c args; callers always wrap with @(...), so the pipeline unroll into object[] is harmless and re-collected.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return @() }
    # First value '' resets any inherited helper FOR github.com so only ours
    # answers; the second installs the inline helper. Single-quoted so PowerShell
    # keeps $GH_TOKEN literal for git's shell to expand at run time.
    $reset  = 'credential.https://github.com.helper='
    $helper = 'credential.https://github.com.helper=!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f'
    return [string[]]@('-c', $reset, '-c', $helper)
}

function Get-YurunaGhCliCredentialArg {
    <#
    .SYNOPSIS
        The `git -c ...` arguments that make git authenticate to github.com
        through the GitHub CLI's stored login (`gh auth git-credential`), or an
        empty array when gh is not on PATH.
    .DESCRIPTION
        `gh auth login` stores its credential in gh's own config/keyring --
        plain git never sees it unless `gh auth setup-git` also wrote gh into
        the user's gitconfig, a step the login flow only offers on the
        interactive HTTPS path (and `gh repo clone` injects only for the clone
        itself). On Linux git has no default credential store at all, so a host
        bootstrapped with `gh auth login` + `gh repo clone` authenticates the
        clone and then fails every later fetch/pull with "could not read
        Username". This returns the same per-invocation injection gh itself
        uses: gh's credential-helper plumbing, SCOPED to https://github.com so
        the login is never offered to any other remote.

        `gh auth git-credential` speaks git's credential protocol and never
        prompts; when gh holds no login it simply answers nothing, which
        surfaces as a normal auth failure for the caller's fallback chain.
        The helper says bare `gh` (not a resolved absolute path): git runs
        helpers through its shell, which inherits this process's PATH -- the
        same PATH that just resolved gh -- and an absolute Windows path
        ('Program Files' spaces) would need sh-side quoting.
    .OUTPUTS
        [string[]] -- the -c argument pairs, or an empty array when gh is absent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'Returns a [string[]] of git -c args; callers always wrap with @(...), so the pipeline unroll into object[] is harmless and re-collected.')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    if (-not (Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue)) { return @() }
    # Same reset-then-install shape as Get-YurunaGitCredentialArg: the '' value
    # clears inherited helpers FOR github.com so only gh answers this attempt.
    $reset  = 'credential.https://github.com.helper='
    $helper = 'credential.https://github.com.helper=!gh auth git-credential'
    return [string[]]@('-c', $reset, '-c', $helper)
}

function Get-YurunaGitAuthAttemptList {
    <#
    .SYNOPSIS
        The ordered credentialed attempts for a network git call against
        github.com: the explicit GH_TOKEN first, then the gh CLI's stored
        login. Empty when the host has neither source.
    .DESCRIPTION
        One place owns the source ORDER so every network-git path (the inner
        runner's Invoke-GitNetworkCommand, the outer loop's bounded runner)
        chains identically. GH_TOKEN outranks the gh login because an explicit
        environment token is deliberate operator intent -- the same precedence
        gh itself applies. Callers run these before a plain (unmodified) git
        attempt, which stays the last resort so the machine's own credential
        manager / SSH agent can still win.

        Descriptors are hashtables, never nested bare arrays: a nested array
        return unrolls one level on the pipeline and an empty inner array
        vanishes entirely (see feedback_return_comma_list_plus_at_paren_double_wraps).
    .OUTPUTS
        [hashtable[]] -- @{ Source = <label for logs>; Args = [string[]] git -c pairs },
        in the order the attempts should run.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'Returns a [hashtable[]]; callers always wrap with @(...), so the pipeline unroll into object[] is harmless and re-collected.')]
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    $attempts = [System.Collections.Generic.List[hashtable]]::new()
    $token = @(Get-YurunaGitCredentialArg)
    if ($token.Count -gt 0) { $attempts.Add(@{ Source = 'GH_TOKEN'; Args = [string[]]$token }) }
    $ghCli = @(Get-YurunaGhCliCredentialArg)
    if ($ghCli.Count -gt 0) { $attempts.Add(@{ Source = 'gh CLI login'; Args = [string[]]$ghCli }) }
    return $attempts.ToArray()
}

function Invoke-GitNetworkCommandOnce {
    <#
    .SYNOPSIS
        One prompt-proof network-git run (see Invoke-GitNetworkCommand). Prefers
        the bounded, process-tree-killing pool-sync runner when it is loaded;
        otherwise neutralizes the credential-prompt env on this process around a
        plain call and restores it after.
    .OUTPUTS
        [hashtable] @{ ExitCode; Output }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [Parameter()][int]$TimeoutSeconds = 60
    )
    if (Get-Command Invoke-PoolSyncGitCapture -ErrorAction SilentlyContinue) {
        $r = Invoke-PoolSyncGitCapture -ArgumentList $GitArgs -TimeoutSeconds $TimeoutSeconds
        $text = ((@($r.StdOut, $r.StdErr) | Where-Object { $_ }) -join "`n").Trim()
        return @{ ExitCode = [int]$r.ExitCode; Output = $text }
    }
    # Fallback: neutralize the prompt env on THIS process around a plain call.
    $names = @('GIT_TERMINAL_PROMPT', 'GIT_ASKPASS', 'SSH_ASKPASS', 'GCM_INTERACTIVE')
    $prev  = @{}
    foreach ($n in $names) { $prev[$n] = [Environment]::GetEnvironmentVariable($n) }
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_ASKPASS         = ''
    $env:SSH_ASKPASS         = ''
    $env:GCM_INTERACTIVE     = 'never'
    try {
        $out = & git @GitArgs 2>&1
        return @{ ExitCode = $LASTEXITCODE; Output = ((@($out) -join "`n")).Trim() }
    } finally {
        foreach ($n in $names) {
            if ($null -eq $prev[$n]) { Remove-Item -Path "Env:$n" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "Env:$n" -Value $prev[$n] }
        }
    }
}

function Invoke-GitNetworkCommand {
    <#
    .SYNOPSIS
        Run a network-touching git command (fetch / pull / ls-remote / clone) so
        it can NEVER block on an interactive credential prompt, never hang the
        runner, AND authenticate to github.com with every credential source the
        host actually has.
    .DESCRIPTION
        An unattended runner -- and, on the bare-pwsh path, the INTERACTIVE outer
        loop -- would otherwise stall forever inside git the moment a stale or
        missing GitHub credential makes git prompt for a username (the block is
        inside the git child, so a wall-clock check in the caller can't catch it).
        Prompt-proofing is handled by Invoke-GitNetworkCommandOnce.

        On top of that this is the ONE place the inner runner's git talks to a
        remote, so it is where the host's GitHub credential sources are chained
        (order owned by Get-YurunaGitAuthAttemptList): a github.com-scoped
        GH_TOKEN helper first, then the gh CLI's stored login -- so `gh auth
        login` alone is enough, no `gh auth setup-git` / gitconfig edit needed
        -- and always a plain run last (the machine's credential manager or SSH
        agent may hold a credential the other sources do not). A failed attempt
        falls through to the next source only when the failure is
        credential-shaped (Test-GitRemoteAuthFailure); a network outage fails
        identically for every source, so it is returned immediately instead of
        burning another bounded timeout per source. With no token and no gh, a
        single plain run happens exactly as before.
    .OUTPUTS
        [hashtable] @{ ExitCode; Output }. ExitCode is 124 on a pool-sync timeout,
        -1 when git could not be started.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [Parameter()][int]$TimeoutSeconds = 60
    )
    foreach ($attempt in @(Get-YurunaGitAuthAttemptList)) {
        # The -c auth args are git GLOBAL options, so they must precede the
        # subcommand -- prepend them to whatever the caller passed (which starts
        # with a global like -C or the subcommand itself).
        $r = Invoke-GitNetworkCommandOnce -GitArgs (@($attempt.Args) + @($GitArgs)) -TimeoutSeconds $TimeoutSeconds
        if ($r.ExitCode -eq 0) { return $r }
        if (-not (Test-GitRemoteAuthFailure -Output $r.Output)) { return $r }
        Write-Verbose "Invoke-GitNetworkCommand: the $($attempt.Source) attempt was rejected as unauthorized; trying the next credential source."
    }
    return Invoke-GitNetworkCommandOnce -GitArgs $GitArgs -TimeoutSeconds $TimeoutSeconds
}

function Write-GitAuthRefreshBanner {
    <#
    .SYNOPSIS
        Emit the actionable "GitHub access needs refreshing" message when a git
        fetch/pull failed because the cached credential is missing or expired
        (classified by Test-GitRemoteAuthFailure), so the operator refreshes the
        login in one step instead of debugging a silent hang.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyString()][string]$RemoteUrl,
        [Parameter()][AllowEmptyString()][string]$GitOutput
    )
    $remote = if ([string]::IsNullOrWhiteSpace($RemoteUrl)) { 'origin' } else { $RemoteUrl.Trim() }
    $said   = ''
    if (-not [string]::IsNullOrWhiteSpace($GitOutput)) {
        $line = (($GitOutput -split "`r?`n") | Where-Object { $_ -match '\S' } | Select-Object -First 1)
        if ($line) { $said = "`n  git said: $($line.Trim())" }
    }
    Write-Warning @"
GitHub access needs refreshing.
  git could not authenticate to the framework remote:
    $remote
  The cached GitHub credential is missing or expired, so 'git fetch' / 'git
  pull' would block on an interactive login prompt (which hangs an unattended
  runner). Refresh the login with ONE of, then re-run:
    * gh auth login   (the runner picks up the gh CLI's stored login by itself)
    * export GH_TOKEN=<a valid GitHub token>
    * refresh your git credential helper / re-enter the personal access token$said
"@
}

function Invoke-GitPull {
    <#
    .SYNOPSIS
    Runs git pull in the repo root. Returns $true on success.
    .DESCRIPTION
    Every network git call routes through Invoke-GitNetworkCommand, so a stale or
    missing GitHub login can never block the runner on git's interactive username
    prompt. A cheap ls-remote preflight verifies the remote is both reachable AND
    authorized before the fetch; an auth failure (at the preflight, the fetch, or
    the pull) stops FAST with the "refresh GitHub access" message instead of
    hanging or spending the whole retry budget on a problem that will not
    self-heal.
    #>
    param([string]$RepoRoot)

    # Origin URL for the diagnostic message only (local config read -- no network,
    # no prompt). Best-effort: an unusual remote name just yields a blank here.
    $remoteUrl = & git -C $RepoRoot config --get remote.origin.url 2>$null
    if ($remoteUrl) { $remoteUrl = "$remoteUrl".Trim() }

    # Preflight: confirm the credential still AUTHORIZES against origin without ever
    # blocking on a login prompt. This is the "will the pull work?" check the fetch
    # below would otherwise discover only by hanging. Only an auth signature
    # short-circuits here; a network blip, a missing 'origin', or a timeout falls
    # through to the retry loop, which owns the transient-network backoff and the
    # no-upstream handling. One extra lightweight ref advertisement per cycle -- far
    # cheaper than a fetch, and it turns a silent hang into a clear message.
    $pre = Invoke-GitNetworkCommand -GitArgs @('-C', $RepoRoot, 'ls-remote', '--exit-code', '--quiet', 'origin', 'HEAD') -TimeoutSeconds 30
    if ($pre.ExitCode -ne 0 -and (Test-GitRemoteAuthFailure -Output $pre.Output)) {
        Write-GitAuthRefreshBanner -RemoteUrl $remoteUrl -GitOutput $pre.Output
        return $false
    }

    # Fetch without modifying working tree. Linear-backoff retry on
    # failure: on macOS the Application Firewall stalls outbound TCP
    # connects right after a process opens a new listening socket
    # (status server, caching-proxy forwarders). Shows up as "Couldn't
    # connect / No route to host" on the first fetches of a fresh
    # runner and has recovered past a 5s wait in observed runs. 5
    # retries with 10/20/30/40/50s waits cover ~2.5 min of blip without
    # masking a genuine outage.
    $maxRetries      = 5
    $maxTotalSeconds = 180   # wall-clock cap (in addition to the attempt count) so a hung/slow
                             # fetch cannot stretch the loop far past the intended ~2.5 min window
    $startUtc        = [DateTime]::UtcNow
    $attempt         = 0
    while ($true) {
        $attempt++
        $totalAttempts = $maxRetries + 1
        Write-Information "Fetching remote changes in: $RepoRoot (attempt $attempt/$totalAttempts)" -InformationAction Continue
        $fetch = Invoke-GitNetworkCommand -GitArgs @('-C', $RepoRoot, 'fetch') -TimeoutSeconds 60
        Write-Information "$($fetch.Output)" -InformationAction Continue
        if ($fetch.ExitCode -eq 0) { break }
        # An auth failure never self-heals across retries -- stop now with the actionable message.
        if (Test-GitRemoteAuthFailure -Output $fetch.Output) {
            Write-GitAuthRefreshBanner -RemoteUrl $remoteUrl -GitOutput $fetch.Output
            return $false
        }
        $elapsed = [int]([DateTime]::UtcNow - $startUtc).TotalSeconds
        if ($attempt -gt $maxRetries -or $elapsed -ge $maxTotalSeconds) {
            Write-Error "git fetch failed (exit $($fetch.ExitCode)) after $attempt attempt(s) / ${elapsed}s (cap ${maxTotalSeconds}s)."
            return $false
        }
        # Clamp the backoff so we never sleep past the wall-clock deadline.
        $waitSeconds = [Math]::Min(10 * $attempt, [Math]::Max(1, $maxTotalSeconds - $elapsed))
        Write-Information "  git fetch failed (exit $($fetch.ExitCode)); retrying in ${waitSeconds}s..." -InformationAction Continue
        Start-Sleep -Seconds $waitSeconds
    }

    # One shared comparison path (Get-GitUpstreamStatus); this function maps
    # the State to a pull/skip/error action. The fetch above already ran, so
    # the classifier reads fresh remote refs.
    $st = Get-GitUpstreamStatus -Path $RepoRoot
    switch ($st.State) {
        'no-upstream' {
            Write-Information "No upstream tracking branch found; skipping ahead/behind check." -InformationAction Continue
            return $true
        }
        'up-to-date' {
            Write-Information "Local branch is up to date with remote." -InformationAction Continue
            return $true
        }
        'ahead' {
            Write-Information "Local branch is ahead of remote. Proceeding with local changes." -InformationAction Continue
            return $true
        }
        'behind' {
            Write-Information "Local branch is behind remote by $($st.Behind) commit(s). Pulling..." -InformationAction Continue
            $pull = Invoke-GitNetworkCommand -GitArgs @('-C', $RepoRoot, 'pull', '--ff-only') -TimeoutSeconds 60
            if ($pull.ExitCode -eq 0) {
                Write-Information "Pull succeeded: $($pull.Output)" -InformationAction Continue
                return $true
            }
            if (Test-GitRemoteAuthFailure -Output $pull.Output) {
                Write-GitAuthRefreshBanner -RemoteUrl $remoteUrl -GitOutput $pull.Output
                return $false
            }
            Write-Error "git pull --ff-only failed (exit $($pull.ExitCode)): $($pull.Output)"
            return $false
        }
        'unknown' {
            # Could not determine ahead/behind (rev-list failed). Do not block the cycle on an
            # undeterminable status -- warn and skip the ahead/behind check.
            Write-Warning "Could not determine upstream status (git rev-list failed); skipping ahead/behind check."
            return $true
        }
        default {
            # diverged (no-tree cannot reach here -- the fetch above already ran)
            Write-Error "Local branch has diverged from remote ($($st.Ahead) ahead, $($st.Behind) behind). Rebase or merge manually."
            return $false
        }
    }
}

function Get-CurrentGitCommit {
    <#
    .SYNOPSIS
    Returns the short git commit hash of HEAD.
    #>
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

function Get-FileLockingProcess {
    <#
    .SYNOPSIS
    Returns processes that currently hold an open handle to $Path (file or directory).
    .DESCRIPTION
    Two Windows mechanisms layered together, because no single API covers
    every "in use by another process" cause:

      1. Restart Manager (rstrtmgr.dll) -- the same API behind File
         Explorer's "open in <App>" dialog. Catches *file-handle* lockers
         (antivirus mid-scan, file watchers, .git/index, dll loaded from
         the tree, etc). Registers the path plus every file underneath.
      2. PEB-based cwd scan -- enumerates every accessible process and
         reads its RTL_USER_PROCESS_PARAMETERS.CurrentDirectory via
         NtQueryInformationProcess + ReadProcessMemory. Catches the
         *directory-cwd* lockers Restart Manager misses (a stale pwsh /
         cmd terminal sitting in <RepoRoot>/project, which is the typical
         cause of "empty folder won't delete").

    Diagnostic only: turns the generic "being used by another process"
    Win32 error into PID + process name so the operator can decide
    whether to close the holder or ignore it.

    Non-Windows: returns an empty array (no equivalent stable API; lsof
    is out-of-process and outside this helper's scope).
    Failure modes: any API failure (Restart Manager rc, OpenProcess
    access denied, 32-bit target with mismatched PEB layout) is swallowed
    -- this is best-effort diagnostic, not a control-flow decision the
    caller should branch on.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$Path
    )
    if (-not $IsWindows) { return @() }
    if (-not ('Yuruna.RestartManager' -as [type])) {
        # Add-Type once per process; the type stays loaded so re-invocations
        # skip the C# compile. Keep the type name namespaced so it doesn't
        # collide with anything else added later.
        $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Yuruna {
    public static class RestartManager {
        // ---- Restart Manager: file-handle lockers ----
        [StructLayout(LayoutKind.Sequential)]
        private struct RM_UNIQUE_PROCESS {
            public int dwProcessId;
            public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct RM_PROCESS_INFO {
            public RM_UNIQUE_PROCESS Process;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string strServiceShortName;
            public uint ApplicationType;
            public uint AppStatus;
            public uint TSSessionId;
            [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
        }
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
        [DllImport("rstrtmgr.dll")]
        private static extern int RmEndSession(uint pSessionHandle);
        [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
        private static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
        [DllImport("rstrtmgr.dll")]
        private static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

        public class Holder {
            public int Pid;
            public string Name;
            public bool Restartable;
            public string Reason; // "file-handle" or "cwd"
        }

        public static List<Holder> GetLockers(string[] paths) {
            var result = new List<Holder>();
            uint session;
            string key = Guid.NewGuid().ToString();
            int rc = RmStartSession(out session, 0, key);
            if (rc != 0) return result;
            try {
                rc = RmRegisterResources(session, (uint)paths.Length, paths, 0, null, 0, null);
                if (rc != 0) return result;
                uint needed = 0;
                uint count  = 0;
                uint reason = 0;
                rc = RmGetList(session, out needed, ref count, null, ref reason);
                if (needed == 0) return result;
                var arr = new RM_PROCESS_INFO[needed];
                count = needed;
                rc = RmGetList(session, out needed, ref count, arr, ref reason);
                if (rc != 0) return result;
                for (int i = 0; i < count; i++) {
                    result.Add(new Holder {
                        Pid         = arr[i].Process.dwProcessId,
                        Name        = arr[i].strAppName,
                        Restartable = arr[i].bRestartable,
                        Reason      = "file-handle"
                    });
                }
            }
            finally {
                RmEndSession(session);
            }
            return result;
        }

        // ---- PEB cwd scan: catches processes whose current directory IS
        // the locked folder. Restart Manager doesn't see these because no
        // file handle is open, only a directory handle from SetCurrentDirectory.
        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_BASIC_INFORMATION {
            public IntPtr Reserved1;
            public IntPtr PebBaseAddress;
            public IntPtr Reserved2_0;
            public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId;
            public IntPtr Reserved3;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr h);
        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationProcess(IntPtr h, int infoClass, ref PROCESS_BASIC_INFORMATION pbi, int size, out int retLen);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, IntPtr size, out IntPtr nRead);

        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint PROCESS_VM_READ = 0x10;

        // PEB offsets are stable across modern Windows but technically
        // undocumented. x86 hosts aren't supported (this would require
        // the 32-bit layout); helper returns empty if we ever run there.
        private const int PEB_PROCESS_PARAMETERS_OFFSET_X64 = 0x20;
        private const int RTL_USER_CURRENT_DIRECTORY_OFFSET_X64 = 0x38;

        public static List<Holder> GetCwdHolders(string targetPath) {
            var result = new List<Holder>();
            if (IntPtr.Size != 8) return result;
            string target = NormalisePath(targetPath);
            foreach (var proc in System.Diagnostics.Process.GetProcesses()) {
                try {
                    IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, proc.Id);
                    if (h == IntPtr.Zero) continue;
                    try {
                        var pbi = new PROCESS_BASIC_INFORMATION();
                        int len;
                        if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out len) != 0) continue;
                        if (pbi.PebBaseAddress == IntPtr.Zero) continue;

                        byte[] ptrBuf = new byte[8];
                        IntPtr nRead;
                        if (!ReadProcessMemory(h, new IntPtr(pbi.PebBaseAddress.ToInt64() + PEB_PROCESS_PARAMETERS_OFFSET_X64), ptrBuf, new IntPtr(8), out nRead)) continue;
                        long pp = BitConverter.ToInt64(ptrBuf, 0);
                        if (pp == 0) continue;

                        byte[] usBuf = new byte[16];
                        if (!ReadProcessMemory(h, new IntPtr(pp + RTL_USER_CURRENT_DIRECTORY_OFFSET_X64), usBuf, new IntPtr(16), out nRead)) continue;
                        ushort length = BitConverter.ToUInt16(usBuf, 0);
                        long bufferAddr = BitConverter.ToInt64(usBuf, 8);
                        if (length == 0 || bufferAddr == 0) continue;

                        byte[] strBuf = new byte[length];
                        if (!ReadProcessMemory(h, new IntPtr(bufferAddr), strBuf, new IntPtr(length), out nRead)) continue;
                        string cwd = NormalisePath(Encoding.Unicode.GetString(strBuf, 0, (int)nRead));
                        if (cwd == target) {
                            string name = null;
                            try { name = proc.ProcessName; } catch { }
                            result.Add(new Holder {
                                Pid         = proc.Id,
                                Name        = name ?? "(unknown)",
                                Restartable = false,
                                Reason      = "cwd"
                            });
                        }
                    } finally {
                        CloseHandle(h);
                    }
                } catch {
                    // skip protected/exited/foreign-arch processes
                } finally {
                    try { proc.Dispose(); } catch { }
                }
            }
            return result;
        }

        private static string NormalisePath(string p) {
            if (string.IsNullOrEmpty(p)) return string.Empty;
            return p.TrimEnd('\0','\\','/').Replace('/','\\').ToLowerInvariant();
        }
    }
}
'@
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction SilentlyContinue
    }
    if (-not ('Yuruna.RestartManager' -as [type])) { return @() }
    # Restart Manager only accepts FILE paths -- registering a directory
    # path fails with ACCESS_DENIED (rc=5) and a single bad resource aborts
    # the whole call, so build the resource list from file paths only.
    # For a directory target, enumerate files inside it (capped so a giant
    # tree doesn't stall the error path); cwd-only directory locks are
    # caught separately by the PEB scan below.
    $resources = @()
    if (Test-Path -LiteralPath $Path -PathType Container) {
        try {
            $resources = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                Select-Object -First 256 | ForEach-Object { $_.FullName })
        } catch { $null = $_ }
    } elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        $resources = @($Path)
    }
    $rmHolders = @()
    if ($resources.Count -gt 0) {
        try { $rmHolders = [Yuruna.RestartManager]::GetLockers($resources) } catch { $null = $_ }
    }
    # Restart Manager misses processes that lock the directory only via
    # cwd (SetCurrentDirectory). Fall through to the PEB scan in those
    # cases -- it's the typical "empty folder won't delete" cause.
    $cwdHolders = @()
    try { $cwdHolders = [Yuruna.RestartManager]::GetCwdHolders($Path) } catch { $null = $_ }

    $all = @($rmHolders) + @($cwdHolders)
    if ($all.Count -eq 0) { return @() }
    # De-dupe by PID: a process can show up via both mechanisms. Prefer
    # Restart Manager's reason ("file-handle" is more specific than "cwd"
    # if both apply). Group-Object would re-sort; preserve discovery order.
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $unique = foreach ($h in $all) {
        if ($seen.Add($h.Pid)) { $h }
    }
    $enriched = foreach ($h in $unique) {
        $proc = $null
        try { $proc = Get-Process -Id $h.Pid -ErrorAction Stop } catch { $null = $_ }
        [pscustomobject]@{
            Pid         = $h.Pid
            Name        = $h.Name
            Image       = if ($proc) { $proc.ProcessName } else { $null }
            Reason      = $h.Reason
            Restartable = $h.Restartable
        }
    }
    return @($enriched)
}

function Update-ProjectClone {
    <#
    .SYNOPSIS
    At cycle start, refresh <RepoRoot>/project/ from test.config.yml's repositories.projectUrl.
    .DESCRIPTION
    The project under verification lives in a separate Git repository
    (configured via test.config.yml `repositories.projectUrl`). Each cycle
    blows away <RepoRoot>/project/ and re-clones it so previous cycle
    output cannot leak forward. Returns @{ success; skipped; errorMessage }.

    When `repositories.projectUrl` is empty/missing, this is a no-op (skipped) -
    that path is the in-tree stop-gap, where project/ ships as part of
    the framework repo and the runner uses it directly.

    Safety: we refuse to delete unless the resolved target sits strictly
    under $RepoRoot. A misconfigured RepoRoot or project path could
    otherwise scrub something unrelated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ProjectUrl
    )
    if ([string]::IsNullOrWhiteSpace($ProjectUrl)) {
        Write-Information "repositories.projectUrl is empty - skipping project clone (using in-tree project/)." -InformationAction Continue
        return @{ success = $true; skipped = $true; errorMessage = $null }
    }

    $projectDir = Join-Path $RepoRoot 'project'
    $resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    # Resolve project dir without requiring it to exist; manual path build
    # so the safety check works even when project/ was wiped mid-cycle.
    $resolvedProjectParent = (Resolve-Path -LiteralPath $RepoRoot).Path
    $projectDirNormalized  = [System.IO.Path]::GetFullPath((Join-Path $resolvedProjectParent 'project'))
    if (-not $projectDirNormalized.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return @{ success = $false; skipped = $false; errorMessage = "Refusing to delete project dir outside RepoRoot: $projectDirNormalized" }
    }

    if ($PSCmdlet.ShouldProcess($projectDir, "Wipe and re-clone from $ProjectUrl")) {
        # Preflight the project remote BEFORE the destructive wipe: a private
        # projectUrl with a stale/expired GitHub credential would otherwise block
        # the clone on an interactive username prompt (an uncatchable runner hang),
        # and wiping first would also throw away the last good checkout. ls-remote
        # is credential-prompt-proof + bounded; only an auth signature short-circuits
        # (a network blip / non-git path falls through to the clone, which reports
        # it). Leave the existing clone in place and fail fast with clear guidance.
        $pre = Invoke-GitNetworkCommand -GitArgs @('ls-remote', '--exit-code', '--quiet', $ProjectUrl, 'HEAD') -TimeoutSeconds 30
        if ($pre.ExitCode -ne 0 -and (Test-GitRemoteAuthFailure -Output $pre.Output)) {
            Write-GitAuthRefreshBanner -RemoteUrl $ProjectUrl -GitOutput $pre.Output
            return @{ success = $false; skipped = $false; errorMessage = "project remote '$ProjectUrl' rejected the cached GitHub credential (needs refreshing): $($pre.Output)" }
        }
        if (Test-Path $projectDir) {
            Write-Information "Removing previous project clone: $projectDir" -InformationAction Continue
            try {
                # -Force chases hidden + read-only entries (.git/objects/pack
                # files arrive read-only on Windows after a clone).
                Remove-Item -LiteralPath $projectDir -Recurse -Force -ErrorAction Stop
            } catch {
                # Windows "being used by another process" never names the
                # holder -- it's almost always a stale pwsh/VSCode with
                # the dir as cwd, or AV mid-scan. Resolve PIDs via Restart
                # Manager so the operator knows what to close instead of
                # retrying forever and trusting the next cycle to be luckier.
                $msg = "Failed to remove previous project clone ($projectDir): $($_.Exception.Message)"
                $holders = Get-FileLockingProcess -Path $projectDir
                if ($holders.Count -gt 0) {
                    $lines = $holders | ForEach-Object {
                        $imgPart = if ($_.Image) { " ($($_.Image).exe)" } else { '' }
                        "  PID $($_.Pid) [$($_.Reason)] - $($_.Name)$imgPart"
                    }
                    $msg = "$msg`nProcess(es) holding the folder:`n$($lines -join "`n")"
                } else {
                    $msg = "$msg`n(No holder identified by Restart Manager or PEB cwd scan -- on Windows this can mean an antivirus scan, a transient handle, an elevated/protected process, or a 32-bit holder we can't introspect.)"
                }
                return @{ success = $false; skipped = $false; errorMessage = $msg }
            }
        }
        Write-Information "Cloning $ProjectUrl -> $projectDir" -InformationAction Continue
        # Prompt-proof (and bounded, when the pool-sync runner is loaded) so a
        # credential that expired between the preflight and here can't hang the clone.
        $clone = Invoke-GitNetworkCommand -GitArgs @('clone', '--depth', '1', $ProjectUrl, $projectDir) -TimeoutSeconds 600
        if ($clone.ExitCode -ne 0) {
            if (Test-GitRemoteAuthFailure -Output $clone.Output) {
                Write-GitAuthRefreshBanner -RemoteUrl $ProjectUrl -GitOutput $clone.Output
            }
            return @{ success = $false; skipped = $false; errorMessage = "git clone failed (exit $($clone.ExitCode)): $($clone.Output)" }
        }
        Write-Information "Project clone refreshed." -InformationAction Continue
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
}

# Shared PSGallery module-install policy for the two dependency bootstrappers below:
# return $true when already discoverable, honor -WhatIf via ShouldProcess, else
# Install-Module at CurrentUser scope with -Force -AllowClobber (-Force suppresses the
# untrusted-repository prompt that would otherwise hang an unattended run), and warn +
# return $false on failure. Every message derives from $Name, so the two public
# wrappers below need no message text of their own.
function Install-YurunaGalleryModuleIfMissing {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)

    if (Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue) {
        Write-Verbose "$Name already installed."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Install-Module (CurrentUser scope)')) {
        Write-Information "WhatIf: Install-Module $Name -Scope CurrentUser" -InformationAction Continue
        return $false
    }
    try {
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Information "Installed module: $Name (CurrentUser scope)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Failed to install ${Name}: $($_.Exception.Message). Install manually with: Install-Module $Name -Scope CurrentUser"
        return $false
    }
}

function Install-PowerShellYamlIfMissing {
<#
.SYNOPSIS
    Ensure the powershell-yaml module is available to the runner.
.DESCRIPTION
    Test.SequencePlanner.Resolve-CyclePlan reads project/test/
    test.runner.yml and every per-sequence baseline file via
    Read-SequenceFile, which Import-Modules powershell-yaml on demand.
    pwsh 7 doesn't ship it, so on a freshly-imaged host the planner
    throws -- the inner runner's try/catch then falls back to the
    legacy guestSequence list, which leaves Start-GuestOS with an
    empty sequence array and records every guest as "skipped" in
    status.json with no log line. Installing here at host-prep time
    keeps that silent-skip trap out of the cycle.

    Idempotent: returns $true immediately when the module is already
    discoverable on PSModulePath. CurrentUser scope, so no elevation
    is required. -Force suppresses the PSGallery "untrusted repository"
    prompt that would otherwise hang an unattended Enable-TestAutomation
    run.
.OUTPUTS
    [bool] $true when the module is available afterwards (already
    installed or just installed); $false on install failure.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    return Install-YurunaGalleryModuleIfMissing -Name 'powershell-yaml' @PSBoundParameters
}

function Install-PSScriptAnalyzerIfMissing {
<#
.SYNOPSIS
    Ensure the PSScriptAnalyzer module is available to the harness and to
    editor / CI lint flows.
.DESCRIPTION
    PSScriptAnalyzer surfaces rule violations across the harness's
    PowerShell sources (`.ps1` and `.psm1`). pwsh 7 does not ship it,
    so install it once per host (re-runs are no-ops). Installed right
    after powershell-yaml so the "install PowerShell + Yaml support,
    then add PSScriptAnalyzer" ordering is honored on a fresh box.

    Idempotent: returns $true immediately when the module is already
    discoverable on PSModulePath. CurrentUser scope, so no elevation
    is required. -Force suppresses the PSGallery "untrusted repository"
    prompt that would otherwise hang an unattended Enable-TestAutomation
    run.
.OUTPUTS
    [bool] $true when the module is available afterwards (already
    installed or just installed); $false on install failure.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()
    return Install-YurunaGalleryModuleIfMissing -Name 'PSScriptAnalyzer' @PSBoundParameters
}

Export-ModuleMember -Function Invoke-GitPull, Get-GitUpstreamStatus, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing, Test-GitRemoteAuthFailure, Write-GitAuthRefreshBanner, Invoke-GitNetworkCommand, Get-YurunaGitCredentialArg, Get-YurunaGhCliCredentialArg, Get-YurunaGitAuthAttemptList