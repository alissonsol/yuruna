<#PSScriptInfo
.VERSION 2026.06.19
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
    $null = [int]::TryParse(("$(& git -C $Path rev-list --count "$local..$remote" 2>$null)").Trim(), [ref]$behind)
    $null = [int]::TryParse(("$(& git -C $Path rev-list --count "$remote..$local" 2>$null)").Trim(), [ref]$ahead)
    $state = if ($behind -gt 0 -and $ahead -eq 0) { 'behind' }
             elseif ($ahead -gt 0 -and $behind -eq 0) { 'ahead' }
             elseif ($ahead -gt 0 -and $behind -gt 0) { 'diverged' }
             else { 'up-to-date' }
    return @{ State = $state; Ahead = $ahead; Behind = $behind; Local = $local; Remote = $remote }
}

function Invoke-GitPull {
    <#
    .SYNOPSIS
    Runs git pull in the repo root. Returns $true on success.
    #>
    param([string]$RepoRoot)

    # Fetch without modifying working tree. Linear-backoff retry on
    # failure: on macOS the Application Firewall stalls outbound TCP
    # connects right after a process opens a new listening socket
    # (status server, caching-proxy forwarders). Shows up as "Couldn't
    # connect / No route to host" on the first fetches of a fresh
    # runner and has recovered past a 5s wait in observed runs. 5
    # retries with 10/20/30/40/50s waits cover ~2.5 min of blip without
    # masking a genuine outage.
    $maxRetries  = 5
    $attempt     = 0
    while ($true) {
        $attempt++
        $totalAttempts = $maxRetries + 1
        Write-Information "Fetching remote changes in: $RepoRoot (attempt $attempt/$totalAttempts)" -InformationAction Continue
        $output = & git -C $RepoRoot fetch 2>&1
        Write-Information "$output" -InformationAction Continue
        if ($LASTEXITCODE -eq 0) { break }
        if ($attempt -gt $maxRetries) {
            Write-Error "git fetch failed (exit $LASTEXITCODE) after $totalAttempts attempts."
            return $false
        }
        $waitSeconds = 10 * $attempt
        Write-Information "  git fetch failed (exit $LASTEXITCODE); retrying in ${waitSeconds}s..." -InformationAction Continue
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
            $pullOutput = & git -C $RepoRoot pull --ff-only 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Information "Pull succeeded: $pullOutput" -InformationAction Continue
                return $true
            }
            Write-Error "git pull --ff-only failed (exit $LASTEXITCODE): $pullOutput"
            return $false
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
        $cloneOut = & git clone --depth 1 $ProjectUrl $projectDir 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{ success = $false; skipped = $false; errorMessage = "git clone failed (exit $LASTEXITCODE): $cloneOut" }
        }
        Write-Information "Project clone refreshed." -InformationAction Continue
    }
    return @{ success = $true; skipped = $false; errorMessage = $null }
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

    if (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue) {
        Write-Verbose "powershell-yaml already installed."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('powershell-yaml', 'Install-Module (CurrentUser scope)')) {
        Write-Information "WhatIf: Install-Module powershell-yaml -Scope CurrentUser" -InformationAction Continue
        return $false
    }
    try {
        Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Information "Installed module: powershell-yaml (CurrentUser scope)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Failed to install powershell-yaml: $($_.Exception.Message). Install manually with: Install-Module powershell-yaml -Scope CurrentUser"
        return $false
    }
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

    if (Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue) {
        Write-Verbose "PSScriptAnalyzer already installed."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess('PSScriptAnalyzer', 'Install-Module (CurrentUser scope)')) {
        Write-Information "WhatIf: Install-Module PSScriptAnalyzer -Scope CurrentUser" -InformationAction Continue
        return $false
    }
    try {
        Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        Write-Information "Installed module: PSScriptAnalyzer (CurrentUser scope)." -InformationAction Continue
        return $true
    } catch {
        Write-Warning "Failed to install PSScriptAnalyzer: $($_.Exception.Message). Install manually with: Install-Module PSScriptAnalyzer -Scope CurrentUser"
        return $false
    }
}

Export-ModuleMember -Function Invoke-GitPull, Get-GitUpstreamStatus, Get-CurrentGitCommit, Get-FileLockingProcess, Update-ProjectClone, Install-PowerShellYamlIfMissing, Install-PSScriptAnalyzerIfMissing