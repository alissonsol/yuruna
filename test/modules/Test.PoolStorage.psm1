<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42c5e8a1-9b3d-4f27-8a6c-1d2e3f4a5b6c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool storage smb nas replication
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

# yuruna pool storage (ypsp): connect an OPTIONAL SMB3 network share and replicate
# cycle output to it. Hosts (like guests) are reimageable, so local storage is
# fast + ephemeral and this NAS-backed share is the durable tier. Everything here
# is BEST-EFFORT: a missing/unreachable/misconfigured/SLOW share never throws AND
# never blocks the caller (the unattended test loop must keep running). Every
# network-touching subprocess is bounded by a wall-clock cap + kill so a wedged
# NAS can never freeze the loop. Config lives under `poolStorage` in
# test.config.yml; networkUser is also the vault key its password is fetched under.

# Wall-clock caps (seconds) for the network-touching operations. These are
# BACKSTOPS for a wedged/unreachable NAS, not normal-path budgets: a healthy LAN
# mount + copy finish in well under a second. Copy gets the largest cap because a
# legitimately large (but progressing) cycle folder must not be killed mid-flight;
# rsync additionally carries its own --timeout for precise I/O-stall detection.
$script:PoolStorageMountTimeoutSec     = 90
$script:PoolStorageCopyTimeoutSec      = 600
$script:PoolStorageSmbCmdletTimeoutSec = 60

# Invoke-PoolStorageProcess runs a native command bounded by a wall-clock cap and
# kills the whole process tree on timeout, so a hung mount/copy can never block
# the loop. stdin is redirected + closed immediately, so a child that would
# otherwise prompt (e.g. sudo asking for a password) gets EOF and fails fast
# instead of stalling. Returns the process exit code, or 124 on timeout
# (conventional), or -1 if the process could not be started. Mirrors the bounded
# Process.Start + WaitForExit + Kill($true) idiom used in Test.Ssh.psm1.
function Invoke-PoolStorageProcess {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][int]$TimeoutSeconds = 60
    )
    $resolved = (Get-Command -CommandType Application -Name $FilePath -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $resolved) { $resolved = $FilePath }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $resolved
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add([string]$a) }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Verbose "Invoke-PoolStorageProcess: failed to start '$resolved': $($_.Exception.Message)"
        return -1
    }
    # Closing stdin gives a prompting child EOF (sudo can't block on a password
    # prompt). Drain stdout/stderr asynchronously so a chatty child can't deadlock
    # on a full pipe while we wait.
    try { $proc.StandardInput.Close() } catch { $null = $_ }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Warning "poolStorage: '$FilePath' exceeded ${TimeoutSeconds}s; killing the process tree."
        try { $proc.Kill($true) } catch { $null = $_ }
        try { $null = $proc.WaitForExit(5000) } catch { $null = $_ }
        try { $proc.Dispose() } catch { $null = $_ }
        return 124
    }
    try { $null = [System.Threading.Tasks.Task]::WaitAll(@($outTask, $errTask), 2000) } catch { $null = $_ }
    $code = [int]$proc.ExitCode
    try { $proc.Dispose() } catch { $null = $_ }
    return $code
}

# Invoke-PoolStorageBoundedScript runs a scriptblock under a wall-clock cap via a
# thread job, so a slow cmdlet (the Windows SMB redirector has no -TimeoutSec and
# can stall for tens of seconds on an unreachable NAS) cannot block the loop. On
# timeout it abandons the job and returns immediately; the orphaned call releases
# itself when the redirector's own internal timeout fires. Returns a hashtable
# @{ TimedOut; Result; Error }. Falls back to inline execution when Start-ThreadJob
# is unavailable (still bounded by the redirector's internal timeout, just not the
# tighter cap).
function Invoke-PoolStorageBoundedScript {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter()][object[]]$ArgumentList = @(),
        [Parameter()][int]$TimeoutSeconds = 60
    )
    if (-not (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        try { return @{ TimedOut = $false; Result = (& $ScriptBlock @ArgumentList); Error = $null } }
        catch { return @{ TimedOut = $false; Result = $null; Error = $_.Exception.Message } }
    }
    $job = Start-ThreadJob -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
        Write-Warning "poolStorage: SMB operation exceeded ${TimeoutSeconds}s; abandoning (the redirector releases the orphaned call on its own timeout)."
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        return @{ TimedOut = $true; Result = $null; Error = "timeout ${TimeoutSeconds}s" }
    }
    $err = $null
    $res = $null
    try { $res = Receive-Job -Job $job -ErrorAction Stop } catch { $err = $_.Exception.Message }
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    return @{ TimedOut = $false; Result = $res; Error = $err }
}

# Get-PoolStorageUncPath normalizes a share path to one platform's UNC form,
# accepting either '\\srv\share' or '//srv/share' on input. Pure + testable.
function Get-PoolStorageUncPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('windows', 'unix')][string]$Style
    )
    $bare = ($Path -replace '[\\/]+', '/') -replace '^/+', ''   # 'srv/share[/sub]'
    if ($Style -eq 'windows') { return '\\' + ($bare -replace '/', '\') }
    return '//' + $bare
}

# Test-PoolStorageMountMatch is the pure, testable core of the non-Windows mount
# check: does any `mount` output line show OUR share at OUR exact mount point?
# BOTH halves are anchored -- the mount point by exact equality, and the
# server/share by an exact (case-insensitive) compare after normalizing away the
# scheme, leading slashes, an optional 'user@' prefix, and a trailing slash. A
# substring test here would false-match a DIFFERENT share at the same point (e.g.
# wanting 'srv/work' against a mounted '//srv/work2', or 'nas/p' against
# '//other-nas/p'), causing Connect to no-op and replication to write to the
# wrong share.
function Test-PoolStorageMountMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][string[]]$MountLines,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$NetworkPath
    )
    if (-not $MountLines) { return $false }
    $wantShare = (($NetworkPath -replace '[\\/]+', '/') -replace '^/+', '').TrimEnd('/')   # 'server/share'
    foreach ($line in $MountLines) {
        $s = [string]$line
        $sep = $s.IndexOf(' on ')
        if ($sep -lt 0) { continue }
        $remote = $s.Substring(0, $sep)
        $tail   = $s.Substring($sep + 4)
        $tIdx = $tail.IndexOf(' type ')                 # Linux: "/mnt/x type cifs (...)"
        if ($tIdx -ge 0) {
            $point = $tail.Substring(0, $tIdx)
        } else {
            $pIdx = $tail.LastIndexOf(' (')             # macOS: "/Users/x (smbfs, ...)"
            $point = if ($pIdx -ge 0) { $tail.Substring(0, $pIdx) } else { $tail }
        }
        if ($point.Trim() -ne $LocalPath) { continue }
        # Normalize the mounted remote the same way: 'server/share', minus 'user@'.
        $remoteBare = ((($remote -replace '[\\/]+', '/') -replace '^/+', '') -replace '^[^/@]*@', '').TrimEnd('/')
        if ($remoteBare -ieq $wantShare) { return $true }
    }
    return $false
}

# Get-YurunaPoolStorageConfig returns a normalized config object, or $null when
# the feature is OFF: replicate false (unless -IgnoreReplicate), or any of
# networkPath/networkUser/localPath empty. The object's Replicate field carries the
# real flag. Accepts an already-parsed config (IDictionary); when none is supplied it
# reads test.config.yml via Read-TestConfig USING A RESOLVED PATH ($env:YURUNA_CONFIG_PATH).
# It never calls Read-TestConfig with the path omitted: that command has a
# Mandatory $Path, and a by-name call with the arg missing stalls forever on the
# interactive "Supply values for the following parameters:" prompt under the
# headless/operator runner (see feedback_byname_detection_mandatory_param_prompt_hang).
function Get-YurunaPoolStorageConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Config,
        # Return the normalized object even when replicate is false, as long as the
        # three paths are set -- for pre-flight validation (Test-Config) of the
        # connection parameters before an operator flips replicate to true. The
        # returned object's Replicate field still reflects the real flag. The runner
        # / drain never pass this, so a false replicate stays a no-op there.
        [switch]$IgnoreReplicate
    )
    if (-not $Config) {
        $cfgPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($cfgPath) -and (Test-Path -LiteralPath $cfgPath) -and
            (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            try { $Config = Read-TestConfig -Path $cfgPath } catch { Write-Verbose "Read-TestConfig failed: $($_.Exception.Message)" }
        } else {
            Write-Verbose "Get-YurunaPoolStorageConfig: no -Config and no resolvable YURUNA_CONFIG_PATH; feature off."
            return $null
        }
    }
    if (-not ($Config -is [System.Collections.IDictionary]) -or -not $Config.Contains('poolStorage')) { return $null }
    $ps = $Config['poolStorage']
    if (-not ($ps -is [System.Collections.IDictionary])) { return $null }
    $replicate   = [bool]$ps['replicate']
    $networkPath = [string]$ps['networkPath']
    $networkUser = [string]$ps['networkUser']
    $localPath   = [string]$ps['localPath']
    if (-not $replicate -and -not $IgnoreReplicate) { return $null }
    if ([string]::IsNullOrWhiteSpace($networkPath) -or
        [string]::IsNullOrWhiteSpace($networkUser) -or
        [string]::IsNullOrWhiteSpace($localPath)) {
        if ($replicate) {
            Write-Warning "poolStorage.replicate is true but networkPath/networkUser/localPath are not all set; replication disabled."
        }
        return $null
    }
    $localPath = $localPath.Trim()
    # Expand a leading '~' here, once, so EVERY downstream use (mount target, mount
    # idempotency check, copy destination) sees a real path. '~' is a shell
    # expansion; passed straight to mount_smbfs / mount it would create a literal
    # '~' directory and the mount check would never match.
    if ($localPath -match '^~(?=[\\/]|$)') {
        $localPath = Join-Path $HOME ($localPath.Substring(1).TrimStart('/', '\'))
    }
    return [pscustomobject]@{
        Replicate   = $replicate
        NetworkPath = $networkPath.Trim()
        NetworkUser = $networkUser.Trim()
        LocalPath   = $localPath
    }
}

# Test-YurunaPoolStorageMounted returns $true only when LocalPath is already
# connected to OUR share (so Connect can be a no-op). The match is anchored on the
# exact mount point AND verifies the remote carries our share, so a different
# share at the same point, or a path-prefix collision, is never mistaken for a
# live mount. Per-OS; best-effort; bounded on Windows.
function Test-YurunaPoolStorageMounted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    try {
        if ($IsWindows) {
            $want = Get-PoolStorageUncPath -Path $Config.NetworkPath -Style windows
            $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($Config.LocalPath) -ScriptBlock {
                param($local) Get-SmbMapping -LocalPath $local -ErrorAction SilentlyContinue
            }
            if ($r.TimedOut) { return $false }
            $m = $r.Result
            return ($m -and ($m.RemotePath -replace '\\$', '') -ieq ($want -replace '\\$', ''))
        }
        # macOS + Linux: resolve the native binary explicitly -- a bare `mount` is
        # a PowerShell alias for New-PSDrive. Listing kernel mounts is local +
        # instant even when a cifs mount is wedged, so it needs no wall-clock cap.
        # The anchored match lives in Test-PoolStorageMountMatch (pure + tested).
        $mountExe = (Get-Command -CommandType Application -Name 'mount' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $mountExe) { return $false }
        $mountOut = @(& $mountExe 2>$null | ForEach-Object { [string]$_ })
        return (Test-PoolStorageMountMatch -MountLines $mountOut -LocalPath $Config.LocalPath -NetworkPath $Config.NetworkPath)
    } catch {
        Write-Verbose "Test-YurunaPoolStorageMounted: $($_.Exception.Message)"
        return $false
    }
}

# Connect-YurunaPoolStorage mounts the share at LocalPath if not already mounted
# correctly. Idempotent + best-effort (returns $true/$false, never throws, never
# blocks: every network-touching call is wall-clock bounded). The password is
# fetched in-process via Get-Password; it never lands in `ps` on Windows
# (New-SmbMapping) or Linux (a 0600 credentials file). On macOS mount_smbfs has no
# credentials-file option, so the (URL-encoded) password is on the argv for the
# mount's lifetime -- a documented, accepted exposure; keychain is a future
# hardening.
function Connect-YurunaPoolStorage {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    if (Test-YurunaPoolStorageMounted -Config $Config) {
        Write-Verbose "poolStorage already mounted at $($Config.LocalPath)"
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($Config.LocalPath, "Connect SMB share $($Config.NetworkPath)")) { return $false }

    $password = $null
    if (Get-Command Get-Password -ErrorAction SilentlyContinue) {
        try { $password = Get-Password -Username $Config.NetworkUser } catch { Write-Verbose "Get-Password failed: $($_.Exception.Message)" }
    }
    if ([string]::IsNullOrEmpty($password)) {
        Write-Warning "poolStorage: no password available for '$($Config.NetworkUser)'; cannot mount the share."
        return $false
    }

    try {
        if ($IsWindows) {
            $remote = Get-PoolStorageUncPath -Path $Config.NetworkPath -Style windows
            $null = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($Config.LocalPath) -ScriptBlock {
                param($local)
                Get-SmbMapping -LocalPath $local -ErrorAction SilentlyContinue |
                    ForEach-Object { Remove-SmbMapping -LocalPath $local -Force -ErrorAction SilentlyContinue }
            }
            $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageMountTimeoutSec -ArgumentList @($Config.LocalPath, $remote, $Config.NetworkUser, $password) -ScriptBlock {
                param($local, $rem, $user, $pass)
                New-SmbMapping -LocalPath $local -RemotePath $rem -UserName $user -Password $pass -Persistent $true -ErrorAction Stop | Out-Null
            }
            if ($r.TimedOut) { throw "New-SmbMapping timed out after ${script:PoolStorageMountTimeoutSec}s" }
            if ($r.Error) { throw $r.Error }
        } elseif ($IsMacOS) {
            $bare = ($Config.NetworkPath -replace '[\\/]+', '/') -replace '^/+', ''
            if (-not (Test-Path -LiteralPath $Config.LocalPath)) { New-Item -ItemType Directory -Force -Path $Config.LocalPath | Out-Null }
            # mount_smbfs takes the credentials only inside a URL. URL-encode both
            # fields: the vault alphabet legitimately includes @ # % & + =, any of
            # which would otherwise corrupt the //user:pass@host parse and silently
            # auth with the wrong password.
            $encUser = [uri]::EscapeDataString($Config.NetworkUser)
            $encPass = [uri]::EscapeDataString($password)
            $url = "//$($encUser):$($encPass)@$bare"
            $rc = Invoke-PoolStorageProcess -FilePath 'mount_smbfs' -ArgumentList @('-N', $url, $Config.LocalPath) -TimeoutSeconds $script:PoolStorageMountTimeoutSec
            if ($rc -ne 0) { throw "mount_smbfs rc=$rc" }
        } else {
            $remote = Get-PoolStorageUncPath -Path $Config.NetworkPath -Style unix
            if (-not (Test-Path -LiteralPath $Config.LocalPath)) { New-Item -ItemType Directory -Force -Path $Config.LocalPath | Out-Null }
            $credDir = if ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
            # Per-invocation unique name (no cross-run collision) deleted in the
            # finally below: the plaintext credentials only need to exist for the
            # mount() syscall, never after it.
            $credFile = Join-Path $credDir ("poolstorage.$PID.$([guid]::NewGuid().ToString('N')).cifs.cred")
            try {
                $utf8 = [System.Text.UTF8Encoding]::new($false)
                # Lock the file down to 0600 BEFORE the secret is written: create it
                # empty, chmod, then write. A plaintext SMB password must never sit
                # in a world-readable file, not even momentarily.
                [System.IO.File]::WriteAllText($credFile, '', $utf8)
                & chmod 600 $credFile 2>$null
                if ($LASTEXITCODE -ne 0) { throw "chmod 600 on credentials file failed (rc=$LASTEXITCODE)" }
                $credBody = "username=$($Config.NetworkUser)`npassword=$password`n"
                [System.IO.File]::WriteAllText($credFile, $credBody, $utf8)
                $uid = (& id -u).Trim(); $gid = (& id -g).Trim()
                $opts = "credentials=$credFile,vers=3.0,uid=$uid,gid=$gid,iocharset=utf8,nofail"
                # sudo -n: never prompt. Without passwordless sudo for this mount it
                # fails fast instead of blocking the loop on a hidden password prompt.
                $rc = Invoke-PoolStorageProcess -FilePath 'sudo' -ArgumentList @('-n', 'mount', '-t', 'cifs', $remote, $Config.LocalPath, '-o', $opts) -TimeoutSeconds $script:PoolStorageMountTimeoutSec
                if ($rc -ne 0) { throw "sudo mount -t cifs rc=$rc (passwordless sudo for mount may be required)" }
            } finally {
                if ($credFile -and (Test-Path -LiteralPath $credFile)) {
                    Remove-Item -LiteralPath $credFile -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        Write-Warning "poolStorage: failed to mount $($Config.NetworkPath) at $($Config.LocalPath): $($_.Exception.Message)"
        return $false
    }
    Write-Information "poolStorage: mounted $($Config.NetworkPath) at $($Config.LocalPath)" -InformationAction Continue
    return $true
}

# Sync-YurunaPoolStorageFolder copies a source directory to <LocalPath>/<DestSubPath>/
# on the share. Cross-platform (robocopy / rsync / cp), every copy run through a
# wall-clock-bounded subprocess so a NAS stalling mid-copy cannot freeze the loop.
# Best-effort: a failure logs + returns $false, never throws. Cycle folders are
# immutable, so this copies (does not mirror-delete).
function Sync-YurunaPoolStorageFolder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestSubPath
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "poolStorage: source '$Source' not found; nothing to replicate."
        return $false
    }
    if (-not (Connect-YurunaPoolStorage -Config $Config)) { return $false }
    $dest = Join-Path $Config.LocalPath $DestSubPath
    if (-not $PSCmdlet.ShouldProcess($dest, "Replicate $Source")) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
        if ($IsWindows) {
            # robocopy exit codes 0-7 are success (>=8 = failure); 124 = our
            # timeout; <0 = failed to start. Only 0-7 is success.
            $rc = Invoke-PoolStorageProcess -FilePath 'robocopy' -ArgumentList @($Source, $dest, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS') -TimeoutSeconds $script:PoolStorageCopyTimeoutSec
            if ($rc -lt 0 -or $rc -ge 8) { throw "robocopy rc=$rc" }
        } elseif (Get-Command rsync -ErrorAction SilentlyContinue) {
            # --timeout aborts on an I/O stall (a wedged-but-not-errored mount)
            # precisely, without killing a legitimately slow-but-progressing copy;
            # the process cap is the outer backstop.
            $rc = Invoke-PoolStorageProcess -FilePath 'rsync' -ArgumentList @('-a', '--timeout=120', "$Source/", "$dest/") -TimeoutSeconds $script:PoolStorageCopyTimeoutSec
            if ($rc -ne 0) { throw "rsync rc=$rc" }
        } elseif (Get-Command cp -ErrorAction SilentlyContinue) {
            $rc = Invoke-PoolStorageProcess -FilePath 'cp' -ArgumentList @('-a', "$Source/.", $dest) -TimeoutSeconds $script:PoolStorageCopyTimeoutSec
            if ($rc -ne 0) { throw "cp rc=$rc" }
        } else {
            Write-Warning "poolStorage: no bounded copy tool (robocopy/rsync/cp) available; skipping replication of '$Source'."
            return $false
        }
    } catch {
        Write-Warning "poolStorage: replication of '$Source' -> '$dest' failed: $($_.Exception.Message)"
        return $false
    }
    Write-Information "poolStorage: replicated $Source -> $dest" -InformationAction Continue
    return $true
}

# === Replicator: async, fail-fast, atomic, backlog-draining =================
# The host->pool copy is driven by Invoke-PoolStorageDrain (fired DETACHED at
# cycle end by the outer loop, single-instance via a lock file). It copies EVERY
# not-yet-replicated cycle (oldest first), each atomically (a cycle is committed
# only after its copy AND a .yuruna-complete sentinel succeed, then recorded in a
# LOCAL ledger that is the source of truth). The pool share has no live reader, so
# correctness rests on the local ledger, not on share-side atomicity.

# Get-PoolStorageServerName extracts the bare server host from a share path:
# '\\srv\share' / '//user@srv/share/sub' -> 'srv'. Pure + testable.
function Get-PoolStorageServerName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkPath)
    $bare = (($NetworkPath -replace '[\\/]+', '/') -replace '^/+', '') -replace '^[^/@]*@', ''
    return (($bare -split '/', 2)[0]).Trim()
}

# Test-PoolStorageVaultDecision returns $true when poolStorage may proceed to
# mount, $false when mounting would force Get-Password to AUTO-GENERATE a junk SMB
# password (empty vaultKey AND no existing vault entry). A non-empty vaultKey, or
# an already-stored entry, proceeds. Pure: takes the resolved booleans, no I/O.
function Test-PoolStorageVaultDecision {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][string]$VaultKey,
        [Parameter(Mandatory)][bool]$EntryExists
    )
    if (-not [string]::IsNullOrWhiteSpace($VaultKey)) { return $true }
    return $EntryExists
}

# Get-PoolStoragePendingSet returns the cycle names present locally but not yet in
# the ledger's replicated set, OLDEST FIRST (lexical order == cycle order via the
# zero-padded 6-digit prefix). Pure: names + ledger in, names out.
function Get-PoolStoragePendingSet {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][string[]]$LocalNames,
        [Parameter()][AllowNull()]$Ledger
    )
    if (-not $LocalNames) { return @() }
    $replicated = @{}
    if ($Ledger -is [System.Collections.IDictionary] -and $Ledger.Contains('replicated') -and
        $Ledger['replicated'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Ledger['replicated'].Keys) { $replicated[[string]$k] = $true }
    }
    $seen = @{}
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $LocalNames) {
        $name = [string]$n
        if ($name -notmatch '^\d{6}\..+\..+\..+') { continue }
        if ($replicated.ContainsKey($name) -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $pending.Add($name)
    }
    return @($pending | Sort-Object)
}

# Merge-PoolStorageLedger produces a new ledger object = old replicated set + newly
# committed cycles (name -> NowUtc) + updated scalar status fields, pruning any
# replicated entry whose cycle no longer exists locally (rotation deletes local
# folders; the share copy is then the durable one). Pure: no Get-Date, no I/O.
function Merge-PoolStorageLedger {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter()][AllowNull()]$Ledger,
        [Parameter()][AllowNull()][string[]]$Committed,
        [Parameter()][AllowNull()][hashtable]$Status,
        [Parameter()][AllowNull()][string[]]$LocalNames,
        [Parameter()][string]$NowUtc = ''
    )
    $replicated = [ordered]@{}
    if ($Ledger -is [System.Collections.IDictionary] -and $Ledger.Contains('replicated') -and
        $Ledger['replicated'] -is [System.Collections.IDictionary]) {
        foreach ($k in $Ledger['replicated'].Keys) { $replicated[[string]$k] = [string]$Ledger['replicated'][$k] }
    }
    if ($Committed) { foreach ($c in $Committed) { $replicated[[string]$c] = $NowUtc } }
    if ($null -ne $LocalNames) {
        $localSet = @{}
        foreach ($n in $LocalNames) { $localSet[[string]$n] = $true }
        $kept = [ordered]@{}
        foreach ($k in $replicated.Keys) { if ($localSet.ContainsKey([string]$k)) { $kept[[string]$k] = $replicated[$k] } }
        $replicated = $kept
    }
    $out = [ordered]@{ replicated = $replicated }
    if ($Status) { foreach ($sk in $Status.Keys) { $out[[string]$sk] = $Status[$sk] } }
    return $out
}

# Read-PoolStorageLedger loads runtime/poolstorage.state.json, degrading to an
# empty ledger shape on absence/corruption (never throws).
function Read-PoolStorageLedger {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $empty = [ordered]@{ replicated = [ordered]@{} }
    $path = Join-Path $RuntimeDir 'poolstorage.state.json'
    if (-not (Test-Path -LiteralPath $path)) { return $empty }
    try {
        $raw = Get-Content -Raw -LiteralPath $path -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $empty }
        $obj = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if (-not ($obj -is [System.Collections.IDictionary])) { return $empty }
        if (-not $obj.Contains('replicated') -or -not ($obj['replicated'] -is [System.Collections.IDictionary])) {
            $obj['replicated'] = [ordered]@{}
        }
        return $obj
    } catch {
        Write-Verbose "Read-PoolStorageLedger: $($_.Exception.Message)"
        return $empty
    }
}

# Write-PoolStorageLedger persists the ledger atomically (temp + rename) via the
# shared state-file primitive, with a direct fallback if it is not loaded.
function Write-PoolStorageLedger {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)]$Ledger
    )
    if (-not (Test-Path -LiteralPath $RuntimeDir)) { New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null }
    $path = Join-Path $RuntimeDir 'poolstorage.state.json'
    if (-not $PSCmdlet.ShouldProcess($path, 'Write poolStorage ledger')) { return $false }
    if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
        return (Write-YurunaStateFileJson -Path $path -InputObject $Ledger -Depth 6 -Confirm:$false)
    }
    try {
        $json = $Ledger | ConvertTo-Json -Depth 6 -Compress
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        Write-Verbose "Write-PoolStorageLedger fallback failed: $($_.Exception.Message)"
        return $false
    }
}

# Get-PoolStorageCycleIdentity collapses a cycle folder's transient on-disk leaf
# ('<base>.incomplete' / '<base>' / '<base>.aborted.<UTC>') to its STABLE identity
# '<base>'. Keying the map/dest/ledger on this -- not the raw leaf -- is what stops
# a SIGKILLed cycle from being replicated twice (once as .incomplete, again as
# .aborted.<UTC> after boot-recovery renames it). Prefers the canonical
# Get-CycleFolderIdentity (Test.Log.psm1) when loaded; the inline fallback mirrors
# it so the module stays self-contained + unit-testable.
function Get-PoolStorageCycleIdentity {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    if (Get-Command Get-CycleFolderIdentity -ErrorAction SilentlyContinue) {
        return (Get-CycleFolderIdentity -Path $Name)
    }
    $leaf = Split-Path -Leaf $Name
    return ($leaf -replace '\.incomplete$', '' -replace '\.aborted\.[^/\\]+$', '')
}

# Get-PoolStorageLocalCycleMap returns identity -> full path for every cycle folder
# under LogDir, scanning the top level AND each history.YYYY-MM-DD/ bucket (a long
# NAS outage can let uncopied cycles rotate into history). The key is the stable
# cycle identity (suffixes stripped), so the three lifecycle leaf forms of one
# cycle collapse to a single entry. First-seen wins. Private I/O helper.
function Get-PoolStorageLocalCycleMap {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$LogDir)
    $map = @{}
    if (-not (Test-Path -LiteralPath $LogDir)) { return $map }
    try {
        Get-ChildItem -LiteralPath $LogDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{6}\..+\..+\..+' } |
            ForEach-Object { $id = Get-PoolStorageCycleIdentity -Name $_.Name; if (-not $map.ContainsKey($id)) { $map[$id] = $_.FullName } }
        Get-ChildItem -LiteralPath $LogDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'history.*' } |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d{6}\..+\..+\..+' } |
                    ForEach-Object { $id = Get-PoolStorageCycleIdentity -Name $_.Name; if (-not $map.ContainsKey($id)) { $map[$id] = $_.FullName } }
            }
    } catch { Write-Verbose "Get-PoolStorageLocalCycleMap: $($_.Exception.Message)" }
    return $map
}

# Test-PoolStorageServerReachable is the FAST-FAIL gate: a bounded TCP probe to
# <server>:445 so a dead NAS is detected in seconds instead of paying the full
# mount timeout. The faulted task (refused connect) is observed; the client is
# always disposed.
function Test-PoolStorageServerReachable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter()][int]$TimeoutSeconds = 5
    )
    $server = Get-PoolStorageServerName -NetworkPath $Config.NetworkPath
    if ([string]::IsNullOrWhiteSpace($server)) { return $false }
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $task = $client.ConnectAsync($server, 445)
        if (-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) { return $false }
        return [bool]$client.Connected
    } catch {
        Write-Verbose "Test-PoolStorageServerReachable: $($_.Exception.Message)"
        return $false
    } finally {
        if ($client) { try { $client.Close(); $client.Dispose() } catch { $null = $_ } }
    }
}

# Test-PoolStorageVaultReady is the LOUD-FAIL pre-check: resolve a user's vault key
# (read-only) and refuse to mount when a mount would auto-generate a junk SMB
# password (empty vaultKey AND no stored entry). All read-only -- never triggers
# auto-generation, never writes the vault. networkUser is the single account used
# for every NAS connection (host-side drain AND the guest caching-proxy mount).
function Test-PoolStorageVaultReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $who = $Config.NetworkUser
    if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue)) {
        Write-Warning "poolStorage: authentication extension not loaded; cannot verify the vault credential for '$who'. Skipping replication."
        return $false
    }
    $vaultKey = ''
    try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $who).vaultKey } catch { Write-Verbose "Get-EffectiveUser failed: $($_.Exception.Message)" }
    $resolvedKey = if ([string]::IsNullOrWhiteSpace($vaultKey)) { $who } else { $vaultKey }
    $entryExists = $false
    if (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue) {
        try { $entryExists = [bool](Test-VaultEntry -VaultKey $resolvedKey) } catch { Write-Verbose "Test-VaultEntry failed: $($_.Exception.Message)" }
    }
    $ready = Test-PoolStorageVaultDecision -VaultKey $vaultKey -EntryExists $entryExists
    if (-not $ready) {
        Write-Warning "poolStorage: '$who' has an empty vaultKey and no stored credential, so mounting would auto-generate a junk SMB password. Map a non-empty vaultKey and Set-Password it (docs/test-config.md). Skipping replication."
    }
    return $ready
}

# Copy-PoolStorageCycle copies one cycle folder to <localPath>/<HostId>/<CycleName>/
# and commits it with a .yuruna-complete sentinel written LAST. Any pre-existing
# copy WITHOUT a sentinel (a crashed prior attempt) is deleted first and recopied,
# so a partial is never trusted. Returns $true only when copy AND sentinel both
# succeed. Private; assumes the share is already mounted.
function Copy-PoolStorageCycle {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][string]$CycleName
    )
    if (-not $PSCmdlet.ShouldProcess("$HostId/$CycleName", 'Replicate cycle to poolStorage')) { return $false }
    $destSub  = Join-Path $HostId $CycleName
    $destFull = Join-Path $Config.LocalPath $destSub
    $sentinel = Join-Path $destFull '.yuruna-complete'
    if ((Test-Path -LiteralPath $destFull) -and -not (Test-Path -LiteralPath $sentinel)) {
        Remove-Item -LiteralPath $destFull -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Sync-YurunaPoolStorageFolder -Config $Config -Source $Source -DestSubPath $destSub -Confirm:$false)) { return $false }
    try {
        $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") + "`n"
        [System.IO.File]::WriteAllText($sentinel, $stamp, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Warning "poolStorage: copied $CycleName but the completion sentinel failed: $($_.Exception.Message)"
        return $false
    }
    return $true
}

# Invoke-PoolStorageDrain is the orchestrator: loud-fail vault pre-check -> TCP
# fast-fail gate -> mount -> compute the backlog (local cycles minus the ledger,
# oldest first) -> copy up to MaxPerRun cycles atomically -> persist the ledger.
# Best-effort: returns a summary hashtable, never throws, never blocks the loop
# (it runs in a detached child process). Stops draining on the first copy failure
# (likely a lost connection) and resumes on the next run.
function Invoke-PoolStorageDrain {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter()][AllowNull()]$Config,
        [Parameter()][int]$MaxPerRun = 100
    )
    $summary = @{ connectOk = $false; copied = 0; pending = 0; error = '' }
    $cfg = Get-YurunaPoolStorageConfig -Config $Config
    if (-not $cfg) { return $summary }   # feature off -> no-op

    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $ledger = Read-PoolStorageLedger -RuntimeDir $RuntimeDir
    $cycleMap = Get-PoolStorageLocalCycleMap -LogDir $LogDir
    $localNames = @($cycleMap.Keys)

    $recordAndReturn = {
        param($errMsg, $connectOk)
        $pendingNow = @(Get-PoolStoragePendingSet -LocalNames $localNames -Ledger $ledger)
        $summary.pending = $pendingNow.Count
        $summary.error = $errMsg
        $status = @{ lastAttemptUtc = $nowUtc; lastConnectOk = [bool]$connectOk; lastError = [string]$errMsg; pendingCount = $pendingNow.Count }
        $merged = Merge-PoolStorageLedger -Ledger $ledger -Status $status -LocalNames $localNames -NowUtc $nowUtc
        $null = Write-PoolStorageLedger -RuntimeDir $RuntimeDir -Ledger $merged -Confirm:$false
        return $summary
    }

    if (-not (Test-PoolStorageVaultReady -Config $cfg)) { return (& $recordAndReturn 'vault credential not configured' $false) }
    if (-not (Test-PoolStorageServerReachable -Config $cfg)) {
        return (& $recordAndReturn "server unreachable: $(Get-PoolStorageServerName -NetworkPath $cfg.NetworkPath):445" $false)
    }
    if (-not (Connect-YurunaPoolStorage -Config $cfg -Confirm:$false)) { return (& $recordAndReturn 'mount failed' $false) }
    $summary.connectOk = $true

    $pending = @(Get-PoolStoragePendingSet -LocalNames $localNames -Ledger $ledger)
    $summary.pending = $pending.Count
    $committed = [System.Collections.Generic.List[string]]::new()
    # Hybrid order: copy the newest few + the oldest remainder each run, so a fresh
    # cycle reaches the share within one drain even behind a deep backlog (the
    # remainder still backfills oldest-first). Equivalent to oldest-first when the
    # whole backlog fits in one run.
    foreach ($name in @(Get-PoolStorageDrainOrder -PendingOldestFirst $pending -Max $MaxPerRun)) {
        $src = [string]$cycleMap[$name]
        if (-not $src -or -not (Test-Path -LiteralPath $src)) { continue }
        if (Copy-PoolStorageCycle -Config $cfg -Source $src -HostId $HostId -CycleName $name) {
            $committed.Add($name)
        } else {
            break   # likely lost connection; resume next drain
        }
    }
    $summary.copied = $committed.Count
    $remaining = $pending.Count - $committed.Count
    $status = @{
        lastAttemptUtc = $nowUtc; lastConnectOk = $true; lastError = ''
        pendingCount = $remaining; lastCopied = $committed.Count
    }
    $merged = Merge-PoolStorageLedger -Ledger $ledger -Committed @($committed) -Status $status -LocalNames $localNames -NowUtc $nowUtc
    $null = Write-PoolStorageLedger -RuntimeDir $RuntimeDir -Ledger $merged -Confirm:$false

    # Refresh this host's NAS identity record (hosts/info.<HostId>.yml) once per
    # successful drain, so a reimaged host can later recognize + reclaim its uuid.
    # Best-effort + optional: gated on Test.HostIdentity being loaded (the drain
    # script imports it) so Test.PoolStorage carries no hard dependency, and never
    # allowed to break the drain.
    if ((Get-Command Write-HostInfoRecord -ErrorAction SilentlyContinue) -and (Get-Command Get-CachedHostHardwareFingerprint -ErrorAction SilentlyContinue)) {
        try {
            $fp = Get-CachedHostHardwareFingerprint
            if ($fp) { $null = Write-HostInfoRecord -MountRoot $cfg.LocalPath -HostId $HostId -Fingerprint $fp -Confirm:$false }
        } catch { Write-Verbose "poolStorage drain: host-identity record write failed (non-fatal): $($_.Exception.Message)" }
    }
    return $summary
}

# Get-PoolStorageHostFolderPath returns the per-host destination ROOT on the
# share -- '<localPath>/<HostId>' -- the parent of every replicated cycle folder
# (Copy-PoolStorageCycle writes '<localPath>/<HostId>/<CycleName>/'). Pure +
# testable; deriving the gate's pre-flight target and the real copy destination
# from ONE helper keeps the two from drifting apart.
function Get-PoolStorageHostFolderPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$HostId
    )
    return (Join-Path $Config.LocalPath $HostId)
}

# Initialize-PoolStorageHostFolder is the ACTIVE write-path pre-flight: mount the
# share at localPath and ensure the per-host folder '<localPath>/<HostId>' exists
# (create it if missing). This exercises every precondition a cycle's replication
# actually needs -- a working mount (so the networkUser credential, the share
# name, and -- on Linux -- passwordless sudo are all good) AND a WRITABLE share
# (so the per-host root can be created) -- catching the "reachable NAS but
# replication silently never happens" class that a passive :445 reachability
# probe cannot see. Best-effort + bounded: the mount is wall-clock-capped by
# Connect-YurunaPoolStorage and the folder create/verify runs under a bounded
# thread job, so a share that wedges AFTER mounting can't hang the caller.
# Returns @{ ok; stage; folder; error }. Assumes the caller already found the
# server reachable (Test-PoolStorageServerReachable) -- so a merely-offline NAS
# stays a transient WARN upstream, never a hard failure here. Never throws.
function Initialize-PoolStorageHostFolder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$HostId
    )
    $folder = Get-PoolStorageHostFolderPath -Config $Config -HostId $HostId
    $result = @{ ok = $false; stage = 'mount'; folder = $folder; error = '' }
    if (-not $PSCmdlet.ShouldProcess($folder, 'Verify poolStorage per-host folder')) {
        $result.error = 'skipped (WhatIf)'
        return $result
    }
    if (-not (Connect-YurunaPoolStorage -Config $Config -Confirm:$false)) {
        $result.error = "could not mount the SMB share '$($Config.NetworkPath)' at localPath '$($Config.LocalPath)' (check the networkUser password in the vault, the share name, and -- on Linux -- passwordless sudo for mount)"
        return $result
    }
    if (-not (Test-Path -LiteralPath $Config.LocalPath)) {
        $result.error = "the SMB share reported mounted but localPath '$($Config.LocalPath)' is not accessible"
        return $result
    }
    # Create + verify the per-host folder under a wall-clock cap so a share that
    # wedges AFTER mounting (a NAS can stall mid-write) can't hang the caller.
    $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($folder) -ScriptBlock {
        param($f)
        if (-not (Test-Path -LiteralPath $f)) { New-Item -ItemType Directory -Force -Path $f -ErrorAction Stop | Out-Null }
        return [bool](Test-Path -LiteralPath $f)
    }
    if ($r.TimedOut) {
        $result.stage = 'folder'
        $result.error = "creating the per-host folder '$folder' on the share timed out after ${script:PoolStorageSmbCmdletTimeoutSec}s (the share may be wedged)"
        return $result
    }
    if ($r.Error -or -not $r.Result) {
        $result.stage = 'folder'
        $detail = if ($r.Error) { ": $($r.Error)" } else { '' }
        $result.error = "could not create the per-host folder '$folder' on the share$detail (the mount may be read-only, or the account may lack write permission under '$($Config.LocalPath)')"
        return $result
    }
    $result.ok = $true
    $result.stage = 'ok'
    return $result
}

# Get-PoolStorageDrainOrder picks the cycle names to copy THIS run from the
# oldest-first pending list, as a hybrid of the NEWEST $NewestShare and the OLDEST
# remainder (at most $Max total). Copying some newest each run makes TODAY's cycle
# output appear on the share within ONE drain instead of lagging the whole backlog
# (pure oldest-first leaves the share weeks behind on a deep backlog -- the data is
# fine but an operator looking for recent cycles sees only old ones and concludes
# replication is dead). The oldest remainder still backfills before local rotation
# can prune it, so nothing is starved. Pure: names in, names out. When the backlog
# fits in one run ($Max), ordering is irrelevant and the list is returned as-is.
function Get-PoolStorageDrainOrder {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][string[]]$PendingOldestFirst,
        [Parameter()][int]$Max = 100,
        [Parameter()][int]$NewestShare = 20
    )
    $p = @($PendingOldestFirst | Where-Object { $null -ne $_ })
    if ($Max -le 0) { return @() }
    if ($p.Count -le $Max) { return $p }
    # Disjoint head/tail windows: newestCount + oldestCount = Max <= Count, so the
    # oldest-head and newest-tail slices never overlap (no de-dup needed).
    $newestCount = [Math]::Max(0, [Math]::Min($NewestShare, $Max))
    $oldestCount = $Max - $newestCount
    # Accumulate into a typed List, NOT `$x = if (...) { @(...) }` slices: a single-
    # element `@(...)` emitted from an if-statement unwraps to a scalar (and an
    # empty branch to $null), so `$newest + $oldest` would string-CONCATENATE when
    # newestCount==1 and silently fuse/drop cycle names. The List is unwrap-proof.
    # Newest FIRST: the drain commits in list order and breaks on the first copy
    # failure (treated as a lost connection), so copying today's cycles before the
    # oldest backfill guarantees recent data lands even if an old cycle later stalls
    # the run. The oldest remainder follows and backfills across subsequent drains.
    $out = [System.Collections.Generic.List[string]]::new()
    if ($newestCount -gt 0) { foreach ($n in @($p | Select-Object -Last  $newestCount)) { $out.Add([string]$n) } }
    if ($oldestCount -gt 0) { foreach ($o in @($p | Select-Object -First $oldestCount)) { $out.Add([string]$o) } }
    return @($out)
}

# Get-PoolStorageHealthWarning returns a human-readable warning string when the
# PRIOR drain's ledger indicates replication is failing/stalled (and replicate is
# on), else $null. The drain is detached + best-effort, so a host that has STOPPED
# replicating (bad credential, read-only share, a Windows drive-letter/credential
# collision) otherwise records the failure ONLY in the ledger, where no operator
# looks. The outer loop calls this each cycle so the failure surfaces loudly
# (console + outer.log + whatever consumes those). Pure: ledger hashtable +
# replicate flag in, message out. Distinguishes a genuine stall from healthy
# states: caught-up (pending 0) and mid-backlog (copied > 0) both return $null.
function Get-PoolStorageHealthWarning {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Ledger,
        [Parameter()][bool]$Replicate
    )
    if (-not $Replicate) { return $null }
    if (-not ($Ledger -is [System.Collections.IDictionary])) { return $null }
    # A ledger with no recorded attempt yet (first run, or feature just enabled)
    # carries none of these scalars -- nothing to warn about.
    if (-not $Ledger.Contains('lastConnectOk') -and -not $Ledger.Contains('lastError')) { return $null }
    $connectOk = [bool]$Ledger['lastConnectOk']
    $pending   = if ($Ledger.Contains('pendingCount')) { [int]$Ledger['pendingCount'] } else { 0 }
    $copied    = if ($Ledger.Contains('lastCopied'))   { [int]$Ledger['lastCopied'] }   else { 0 }
    $lastErr   = [string]$Ledger['lastError']
    if (-not $connectOk) {
        $tail = if ($lastErr) { " ($lastErr)" } else { '' }
        return "poolStorage replication is FAILING: the last drain could not connect to the share$tail. $pending cycle(s) unreplicated. See docs/pool-storage.md (Operating & troubleshooting)."
    }
    if ($copied -le 0 -and $pending -gt 0) {
        $tail = if ($lastErr) { " Last error: $lastErr." } else { '' }
        return "poolStorage connected but copied 0 of $pending pending cycle(s) last run -- likely a read-only share or the pool account lacking write permission.$tail See docs/pool-storage.md."
    }
    if ($lastErr) {
        return "poolStorage last drain reported an error: $lastErr ($pending cycle(s) pending)."
    }
    return $null
}

Export-ModuleMember -Function `
    Get-PoolStorageUncPath, Test-PoolStorageMountMatch, Get-PoolStorageServerName, `
    Get-YurunaPoolStorageConfig, Test-YurunaPoolStorageMounted, Connect-YurunaPoolStorage, `
    Sync-YurunaPoolStorageFolder, Test-PoolStorageVaultDecision, Get-PoolStorageCycleIdentity, `
    Get-PoolStoragePendingSet, Merge-PoolStorageLedger, Read-PoolStorageLedger, `
    Write-PoolStorageLedger, Test-PoolStorageServerReachable, Test-PoolStorageVaultReady, `
    Get-PoolStorageHostFolderPath, Initialize-PoolStorageHostFolder, `
    Get-PoolStorageDrainOrder, Get-PoolStorageHealthWarning, `
    Invoke-PoolStorageDrain
