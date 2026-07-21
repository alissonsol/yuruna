<#PSScriptInfo
.VERSION 2026.07.21
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

# yuruna pool storage (ypool-nas): connect an OPTIONAL SMB3 network share and replicate
# cycle output to it. Hosts (like guests) are reimageable, so local storage is
# fast + ephemeral and this NAS-backed share is the durable tier. Everything here
# is BEST-EFFORT: a missing/unreachable/misconfigured/SLOW share never throws AND
# never blocks the caller (the unattended test loop must keep running). Every
# network-touching subprocess is bounded by a wall-clock cap + kill so a wedged
# NAS can never freeze the loop. Config lives under `networkStorage`
# (pool* keys; the replicate flag is pool.networkReplicate) in
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

<#
.SYNOPSIS
Canonicalizes a share path to its bare 'server/share[/sub]' form: collapse every run of / or \ to one /, strip leading slashes, then optionally strip a leading 'user@' and/or a trailing slash. The single definition of 'the same share', so every mount/identity check derives from one place. Pure.
#>
function Get-PoolStorageBareShare {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][string]$Path,
        [switch]$WithoutUser,
        [switch]$TrimTrailing
    )
    $bare = ($Path -replace '[\\/]+', '/') -replace '^/+', ''
    if ($WithoutUser) { $bare = $bare -replace '^[^/@]*@', '' }
    if ($TrimTrailing) { $bare = $bare.TrimEnd('/') }
    return $bare
}

<#
.SYNOPSIS
Normalizes a share path to one platform's UNC form, accepting either '\\srv\share' or '//srv/share' on input. Pure + testable.
#>
function Get-PoolStorageUncPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('windows', 'unix')][string]$Style
    )
    $bare = Get-PoolStorageBareShare -Path $Path   # 'srv/share[/sub]'
    if ($Style -eq 'windows') { return '\\' + ($bare -replace '/', '\') }
    return '//' + $bare
}

<#
.SYNOPSIS
Pure, testable core of the non-Windows mount check: returns $true only when a `mount` output line shows OUR share at OUR exact mount point, anchoring both the mount point (exact equality) and the server/share (case-insensitive compare after normalizing scheme, leading slashes, optional 'user@', and trailing slash) so a different share at the same point is never mistaken for a live mount.
#>
function Test-PoolStorageMountMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][string[]]$MountLines,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$NetworkPath
    )
    if (-not $MountLines) { return $false }
    $wantShare = Get-PoolStorageBareShare -Path $NetworkPath -TrimTrailing   # 'server/share'
    foreach ($line in $MountLines) {
        # Parse each line with the one general mount-line parser so a format quirk
        # fixed there cannot silently diverge from the live-mount detection here.
        $parsed = ConvertFrom-PoolStorageMountLine -MountLine ([string]$line)
        if (-not $parsed) { continue }
        if ($parsed.MountPoint -ne $LocalPath) { continue }
        if ($parsed.RemoteBare -ieq $wantShare) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
Parses ONE `mount` output line (or a synthesized "<remote> on <point>" line for Windows mappings) into its remote + mount-point + host/share-sub parts, with the remote normalized to a bare 'server/share' (scheme, leading slashes, optional 'user@', trailing slash all stripped); returns $null for a line that isn't a recognizable mount. Pure. The shared parser Test-PoolStorageMountMatch uses to detect a live mount.
#>
function ConvertFrom-PoolStorageMountLine {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()][string]$MountLine)
    if ([string]::IsNullOrWhiteSpace($MountLine)) { return $null }
    $s = [string]$MountLine
    $sep = $s.IndexOf(' on ')
    if ($sep -lt 0) { return $null }
    $remote = $s.Substring(0, $sep)
    $tail   = $s.Substring($sep + 4)
    $tIdx = $tail.IndexOf(' type ')                 # Linux: "/mnt/x type cifs (...)"
    if ($tIdx -ge 0) {
        $point = $tail.Substring(0, $tIdx)
    } else {
        $pIdx = $tail.LastIndexOf(' (')             # macOS: "/Users/x (smbfs, ...)"
        $point = if ($pIdx -ge 0) { $tail.Substring(0, $pIdx) } else { $tail }
    }
    $remoteBare = Get-PoolStorageBareShare -Path $remote -WithoutUser -TrimTrailing
    $slash = $remoteBare.IndexOf('/')
    if ($slash -lt 0) { $srvHost = $remoteBare; $shareSub = '' }
    else { $srvHost = $remoteBare.Substring(0, $slash); $shareSub = $remoteBare.Substring($slash + 1) }
    return @{
        Remote     = $remote.Trim()
        RemoteBare = $remoteBare
        MountPoint = $point.Trim()
        HostName   = $srvHost
        ShareSub   = $shareSub
    }
}

<#
.SYNOPSIS
Returns the mounts that would BLOCK a fresh mount of OUR share -- the same server-relative 'share/sub' path mounted at a DIFFERENT point than LocalPath -- anchored on the host-relative 'share/sub' (tolerating a different or dead host alias) because macOS mount_smbfs refuses a second mount of a share it already holds with a misleading "File exists"; each result carries HostMatches so the caller can tell our exact host from a look-alike. Pure + testable.
#>
function Find-PoolStorageConflictingMount {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][string[]]$MountLines,
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$NetworkPath
    )
    # Every call site wraps the return in @(); emit a plain array (no unary-comma
    # wrapper) so an EMPTY result stays count 0 under @() instead of unrolling to a
    # single empty-array element.
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    if (-not $MountLines) { return $out.ToArray() }
    $wantBare = Get-PoolStorageBareShare -Path $NetworkPath -TrimTrailing
    $slash = $wantBare.IndexOf('/')
    if ($slash -lt 0) { return $out.ToArray() }    # no share component -> nothing to anchor on
    $wantHost     = $wantBare.Substring(0, $slash)
    $wantShareSub = $wantBare.Substring($slash + 1)
    if ([string]::IsNullOrWhiteSpace($wantShareSub)) { return $out.ToArray() }
    foreach ($line in $MountLines) {
        $p = ConvertFrom-PoolStorageMountLine -MountLine $line
        if (-not $p) { continue }
        if ([string]::IsNullOrWhiteSpace($p.ShareSub)) { continue }
        if ($p.ShareSub -ine $wantShareSub) { continue }
        if ($p.MountPoint -eq $LocalPath) { continue }    # our own point, not a blocker
        $out.Add([pscustomobject]@{
            Remote      = $p.Remote
            MountPoint  = $p.MountPoint
            HostMatches = ($p.HostName -ieq $wantHost)
        })
    }
    return $out.ToArray()
}

<#
.SYNOPSIS
OS-aware wrapper over Find-PoolStorageConflictingMount that lists the live mounts (mount(8) on macOS/Linux; Get-SmbMapping rendered as "<remote> on <local>" on Windows, bounded since the redirector can stall) and returns the conflicting set. Best-effort; never throws.
#>
function Get-PoolStorageConflictingMount {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    try {
        $lines = @()
        if ($IsWindows) {
            $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ScriptBlock {
                Get-SmbMapping -ErrorAction SilentlyContinue | ForEach-Object { "$($_.RemotePath) on $($_.LocalPath)" }
            }
            if (-not $r.TimedOut -and $r.Result) { $lines = @($r.Result | ForEach-Object { [string]$_ }) }
        } else {
            # Resolve the native binary explicitly -- a bare `mount` is a PowerShell
            # alias for New-PSDrive. Listing kernel mounts is local + instant even
            # when a cifs mount is wedged, so it needs no wall-clock cap.
            $mountExe = (Get-Command -CommandType Application -Name 'mount' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
            if ($mountExe) { $lines = @(& $mountExe 2>$null | ForEach-Object { [string]$_ }) }
        }
        return (Find-PoolStorageConflictingMount -MountLines $lines -LocalPath $Config.LocalPath -NetworkPath $Config.NetworkPath)
    } catch {
        Write-Verbose "Get-PoolStorageConflictingMount: $($_.Exception.Message)"
        return @()
    }
}

# Dismount-PoolStoragePoint unmounts ONE mount point, cross-platform: diskutil
# (force) on macOS because a busy SMB mount refuses a plain umount with "Resource
# busy"; sudo -n umount on Linux (never prompt, mirroring the mount path); and
# Remove-SmbMapping on Windows. Bounded + best-effort; returns $true on success.
function Dismount-PoolStoragePoint {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$MountPoint)
    try {
        if ($IsWindows) {
            $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($MountPoint) -ScriptBlock {
                param($p) Remove-SmbMapping -LocalPath $p -Force -ErrorAction Stop
            }
            return (-not $r.TimedOut -and -not $r.Error)
        } elseif ($IsMacOS) {
            $rc = Invoke-PoolStorageProcess -FilePath 'diskutil' -ArgumentList @('unmount', 'force', $MountPoint) -TimeoutSeconds $script:PoolStorageMountTimeoutSec
            if ($rc -ne 0) { $rc = Invoke-PoolStorageProcess -FilePath 'umount' -ArgumentList @('-f', $MountPoint) -TimeoutSeconds $script:PoolStorageMountTimeoutSec }
            return ($rc -eq 0)
        } else {
            $rc = Invoke-PoolStorageProcess -FilePath 'sudo' -ArgumentList @('-n', 'umount', $MountPoint) -TimeoutSeconds $script:PoolStorageMountTimeoutSec
            if ($rc -ne 0) { $rc = Invoke-PoolStorageProcess -FilePath 'umount' -ArgumentList @($MountPoint) -TimeoutSeconds $script:PoolStorageMountTimeoutSec }
            return ($rc -eq 0)
        }
    } catch {
        Write-Verbose "Dismount-PoolStoragePoint($MountPoint): $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
Finds any mount of OUR share at a point OTHER than LocalPath and unmounts it after operator confirmation, clearing the macOS "File exists" block on the cycle's own mount; interactive by design (the headless cycle gate only HINTS at conflicts, the operator runs this by hand), honors -WhatIf, prompts per mount unless -Force, and returns a summary object. Best-effort: a failed unmount logs + continues.
#>
function Clear-PoolStorageConflictingMount {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [switch]$Force
    )
    $found = @(Get-PoolStorageConflictingMount -Config $Config)
    $result = [pscustomobject]@{ Found = $found.Count; Unmounted = 0; Failed = 0; Skipped = 0; Details = @() }
    if ($found.Count -eq 0) {
        Write-Information "poolStorage: no conflicting mount of '$($Config.NetworkPath)' found." -InformationAction Continue
        return $result
    }
    foreach ($c in $found) {
        $target = "$($c.MountPoint) [$($c.Remote)]"
        if (-not $PSCmdlet.ShouldProcess($target, 'Unmount conflicting SMB share')) { $result.Skipped++; continue }
        if (-not $Force) {
            $hostNote = if ($c.HostMatches) { 'our host' } else { 'a DIFFERENT or stale host alias' }
            $q = "Unmount '$($c.MountPoint)' ($($c.Remote))? It holds the same share '$($Config.NetworkPath)' via $hostNote and blocks the cycle mount with macOS 'File exists'."
            if (-not $PSCmdlet.ShouldContinue($q, 'Conflicting SMB mount')) { $result.Skipped++; continue }
        }
        $ok = Dismount-PoolStoragePoint -MountPoint $c.MountPoint
        if ($ok) {
            $result.Unmounted++
            Write-Information "poolStorage: unmounted conflicting share at '$($c.MountPoint)'." -InformationAction Continue
        } else {
            $result.Failed++
            Write-Warning "poolStorage: failed to unmount '$($c.MountPoint)' ($($c.Remote)); unmount it manually (macOS: diskutil unmount force '$($c.MountPoint)')."
        }
        $result.Details += [pscustomobject]@{ MountPoint = $c.MountPoint; Remote = $c.Remote; Unmounted = $ok }
    }
    return $result
}

# Resolve-YurunaConfigDoc loads test.config.yml for the no-Config path of the
# storage config readers: resolve $env:YURUNA_CONFIG_PATH, require it to exist AND
# Read-TestConfig to be loaded, then read it inside a try/catch. Returns the parsed
# config document, or $null when the feature is effectively off (no resolvable
# path, Read-TestConfig unloaded, or the read threw). Read-TestConfig is ALWAYS
# called with the RESOLVED $Path -- never by-name with $Path omitted -- because its
# Mandatory $Path would stall forever on the interactive parameter prompt under the
# headless runner (see feedback_byname_detection_mandatory_param_prompt_hang). The
# Read-TestConfig-unloaded fallback keeps a caller that never imported Test.Config
# (a storage reader can be dot-sourced standalone) from throwing. CallerName only
# tags the verbose diagnostic so each reader's log line stays self-identifying.
function Resolve-YurunaConfigDoc {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$CallerName)
    $cfgPath = if ($env:YURUNA_CONFIG_PATH) { $env:YURUNA_CONFIG_PATH } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($cfgPath) -and (Test-Path -LiteralPath $cfgPath) -and
        (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
        try { return (Read-TestConfig -Path $cfgPath) } catch { Write-Verbose "Read-TestConfig failed: $($_.Exception.Message)" }
        return $null
    }
    Write-Verbose "${CallerName}: no -Config and no resolvable YURUNA_CONFIG_PATH; feature off."
    return $null
}

<#
.SYNOPSIS
Returns a normalized pool config object, or $null when the feature is OFF (replicate false unless -IgnoreReplicate, or any of networkPath/networkUser/localPath empty); the object's Replicate field carries the real flag. Accepts an already-parsed config (IDictionary), else reads test.config.yml via Read-TestConfig using a RESOLVED path ($env:YURUNA_CONFIG_PATH) -- never with the path omitted, because Read-TestConfig's Mandatory $Path would stall forever on the interactive parameter prompt under the headless runner (see feedback_byname_detection_mandatory_param_prompt_hang).
#>
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
        $Config = Resolve-YurunaConfigDoc -CallerName 'Get-YurunaPoolStorageConfig'
        if (-not $Config) { return $null }
    }
    if (-not ($Config -is [System.Collections.IDictionary]) -or -not $Config.Contains('networkStorage')) { return $null }
    $ps = $Config['networkStorage']
    if (-not ($ps -is [System.Collections.IDictionary])) { return $null }
    # networkReplicate is a POOL behavior, so it lives under the `pool` node;
    # networkStorage carries only the path/credential keys.
    $replicate = $false
    if ($Config.Contains('pool') -and ($Config['pool'] -is [System.Collections.IDictionary])) {
        $replicate = [bool]$Config['pool']['networkReplicate']
    }
    $networkPath = [string]$ps['poolNetworkPath']
    $networkUser = [string]$ps['poolNetworkUser']
    $localPath   = [string]$ps['poolLocalPath']
    if (-not $replicate -and -not $IgnoreReplicate) { return $null }
    if ([string]::IsNullOrWhiteSpace($networkPath) -or
        [string]::IsNullOrWhiteSpace($networkUser) -or
        [string]::IsNullOrWhiteSpace($localPath)) {
        if ($replicate) {
            Write-Warning "pool.networkReplicate is true but networkStorage.poolNetworkPath/poolNetworkUser/poolLocalPath are not all set; replication disabled."
        }
        return $null
    }
    $localPath = Expand-YurunaLocalPath -Path $localPath
    return [pscustomobject]@{
        Replicate   = $replicate
        NetworkPath = $networkPath.Trim()
        NetworkUser = $networkUser.Trim()
        LocalPath   = $localPath
    }
}

# Normalize a networkStorage localPath config value: trim it, then expand a leading
# '~' once, here, so EVERY downstream use (mount target, mount idempotency check, copy
# destination) sees a real path. '~' is a shell expansion; passed straight to
# mount_smbfs / mount it would create a literal '~' directory and the mount check would
# never match. One helper so the pool and stash tiers cannot drift on the '~' rule.
function Expand-YurunaLocalPath {
    param([string]$Path)
    $p = $Path.Trim()
    if ($p -match '^~(?=[\\/]|$)') {
        $p = Join-Path $HOME ($p.Substring(1).TrimStart('/', '\'))
    }
    return $p
}

<#
.SYNOPSIS
Returns the normalized STASH storage record from networkStorage.{stashNetworkPath,stashNetworkUser,stashLocalPath}, or $null when any is unset; the stash storage is ISOLATED from the pool (its own share + account) and has no replicate flag (the stash daemon writes files directly). Returns the SAME shape as Get-YurunaPoolStorageConfig so the generic mount / credential helpers work unchanged.
#>
function Get-YurunaStashStorageConfig {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()]$Config)
    if (-not $Config) {
        $Config = Resolve-YurunaConfigDoc -CallerName 'Get-YurunaStashStorageConfig'
        if (-not $Config) { return $null }
    }
    if (-not ($Config -is [System.Collections.IDictionary]) -or -not $Config.Contains('networkStorage')) { return $null }
    $ns = $Config['networkStorage']
    if (-not ($ns -is [System.Collections.IDictionary])) { return $null }
    $networkPath = [string]$ns['stashNetworkPath']
    $networkUser = [string]$ns['stashNetworkUser']
    $localPath   = [string]$ns['stashLocalPath']
    if ([string]::IsNullOrWhiteSpace($networkPath) -or
        [string]::IsNullOrWhiteSpace($networkUser) -or
        [string]::IsNullOrWhiteSpace($localPath)) {
        return $null
    }
    $localPath = Expand-YurunaLocalPath -Path $localPath
    return [pscustomobject]@{
        Replicate   = $false
        NetworkPath = $networkPath.Trim()
        NetworkUser = $networkUser.Trim()
        LocalPath   = $localPath
    }
}

<#
.SYNOPSIS
Returns $true only when LocalPath is already connected to OUR share (so Connect can be a no-op), anchoring the match on the exact mount point AND verifying the remote carries our share so a different share at the same point or a path-prefix collision is never mistaken for a live mount. Per-OS; best-effort; bounded on Windows.
#>
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

<#
.SYNOPSIS
Mounts the share at LocalPath if not already mounted correctly -- idempotent + best-effort (returns $true/$false, never throws, never blocks: every network-touching call is wall-clock bounded). The password is fetched in-process via Get-Password and never lands in `ps` on Windows (New-SmbMapping) or Linux (a 0600 credentials file); on macOS mount_smbfs has no credentials-file option, so the URL-encoded password is on the argv for the mount's lifetime -- a documented, accepted exposure.
#>
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
            $bare = Get-PoolStorageBareShare -Path $Config.NetworkPath
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
            if (-not (Test-Path -LiteralPath $Config.LocalPath)) {
                # Create the mount point. Try unprivileged first -- it succeeds when
                # the parent is user-writable (e.g. a localPath under $HOME). A
                # root-owned parent like /mnt rejects it, so fall back to
                # `sudo -n mkdir -p`: the SAME passwordless-sudo precondition the
                # cifs mount below already needs, so no new privilege surface. `mount`
                # does not create its target, so a missing mount point otherwise
                # fails the mount with a misleading error. The unprivileged attempt
                # is silenced: its denial on a root-owned parent is expected and
                # handled by the fallback, so an error record there would be noise.
                New-Item -ItemType Directory -Force -Path $Config.LocalPath -ErrorAction SilentlyContinue | Out-Null
                if (-not (Test-Path -LiteralPath $Config.LocalPath)) {
                    $mk = Invoke-PoolStorageProcess -FilePath 'sudo' -ArgumentList @('-n', 'mkdir', '-p', $Config.LocalPath) -TimeoutSeconds $script:PoolStorageMountTimeoutSec
                    if ($mk -ne 0) { throw "could not create mount point '$($Config.LocalPath)' (sudo -n mkdir rc=$mk; a root-owned mount-point parent such as /mnt needs passwordless sudo for mkdir as well as mount)" }
                }
            }
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

<#
.SYNOPSIS
Returns the /etc/sudoers.d drop-in specification (file path, the NOPASSWD rule line, and the resolved command list) for the Linux passwordless-sudo precondition the poolStorage mount needs. Pure (caller passes the account + binary paths); the rule grants the test account NOPASSWD mkdir/mount/umount (mkdir is needed when localPath sits under a root-owned parent like /mnt). Single source of truth shared by the operator hint and the interactive installer so they can never disagree on the rule. A blank user yields an empty Rule/Commands.
#>
function Get-PoolStorageSudoSpec {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$User,
        [Parameter()][string]$MkdirPath  = '/usr/bin/mkdir',
        [Parameter()][string]$MountPath  = '/usr/bin/mount',
        [Parameter()][string]$UmountPath = '/usr/bin/umount',
        [Parameter()][string]$DropInName = 'yuruna-poolstorage'
    )
    $file = "/etc/sudoers.d/$DropInName"
    if ([string]::IsNullOrWhiteSpace($User)) {
        return @{ User = ''; Commands = @(); File = $file; Rule = ''; DropInName = $DropInName }
    }
    $commands = @(@($MkdirPath, $MountPath, $UmountPath) | Where-Object { $_ })
    $rule = "$User ALL=(root) NOPASSWD: $($commands -join ', ')"
    return @{ User = $User; Commands = $commands; File = $file; Rule = $rule; DropInName = $DropInName }
}

<#
.SYNOPSIS
Returns the operator-facing lines for the one-time Linux passwordless-sudo precondition: an /etc/sudoers.d drop-in granting the test account NOPASSWD mkdir/mount/umount (mkdir is needed when localPath sits under a root-owned parent like /mnt). The unattended RUNNER cannot self-install it (its mount path runs `sudo -n`, which never prompts, and /etc/sudoers.d needs root); an interactive operator can, via Set-PoolStorageSudoers. Pure (caller passes the account + binary paths); returns an empty array for a blank user.
#>
function Get-PoolStorageLinuxSudoHint {
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$User,
        [Parameter()][string]$MkdirPath  = '/usr/bin/mkdir',
        [Parameter()][string]$MountPath  = '/usr/bin/mount',
        [Parameter()][string]$UmountPath = '/usr/bin/umount',
        [Parameter()][string]$DropInName = 'yuruna-poolstorage'
    )
    if ([string]::IsNullOrWhiteSpace($User)) { return @() }
    $spec = Get-PoolStorageSudoSpec -User $User -MkdirPath $MkdirPath -MountPath $MountPath -UmountPath $UmountPath -DropInName $DropInName
    return @(
        "Fix (one-time, run as a sudoer -- the unattended runner cannot self-install this: 'sudo -n' never prompts and /etc/sudoers.d needs root; from an interactive session Sync-HostConfiguration installs it for you):",
        "  echo '$($spec.Rule)' | sudo tee $($spec.File) >/dev/null",
        "  sudo chmod 0440 $($spec.File) && sudo visudo -cf $($spec.File)",
        "Then re-run Test-Config. (Adjust the binary paths if your distro differs.)"
    )
}

<#
.SYNOPSIS
Idempotently installs the Linux passwordless-sudo drop-in the poolStorage mount needs, prompting the operator ONCE for their sudo password. Interactive path only -- the unattended runner still cannot (and must not) self-elevate.
.DESCRIPTION
The mount path runs `sudo -n mount/mkdir/umount` (never prompts), so without an /etc/sudoers.d drop-in granting those NOPASSWD it fails and the runner buffers locally. An operator running Sync-HostConfiguration IS at a terminal and can supply the password once. This:

  1. Is Linux-only (macOS mounts via `mount_smbfs -N` with no sudo; Windows uses SMB mappings) -- returns Action='unsupported' elsewhere.
  2. Resolves the account (current user) and the REAL mkdir/mount/umount paths (sudo matches the fully-qualified command), so the rule matches how the mount actually invokes them.
  3. Probes whether passwordless sudo for those commands is ALREADY in effect (`sudo -n -l <cmd>`); if so it is a no-op (Action='present').
  4. Otherwise writes the drop-in via `sudo tee`, `chmod 0440`, and validates with `visudo -cf` (removing it again if validation fails). sudo inherits the terminal so its one password prompt reaches the operator; the cached timestamp covers the follow-up chmod/visudo.

Returns @{ Action = unsupported|present|installed|failed|skipped|whatif; DropInPath; Rule; Message }. Honors -WhatIf (Action='whatif', writes nothing) and -NonInteractive (Action='skipped' with the hint -- never blocks on a password).
#>
function Set-PoolStorageSudoers {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = '"sudoers" is the singular domain term for the sudo policy system (/etc/sudoers, /etc/sudoers.d); it is not a plural of "sudoer".')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Interactive operator flow: the sudo password prompt and progress must reach the console the operator is watching, not an information stream a caller might capture.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowEmptyString()][string]$User = '',
        [switch]$NonInteractive
    )
    if (-not $IsLinux) {
        return @{ Action = 'unsupported'; DropInPath = ''; Rule = ''; Message = 'passwordless-sudo drop-in applies to Linux only (macOS/Windows mounts need no sudo).' }
    }
    if ([string]::IsNullOrWhiteSpace($User)) {
        try { $User = (& id -un 2>$null | Out-String).Trim() } catch { $User = '' }
        if ([string]::IsNullOrWhiteSpace($User)) { $User = "$($env:USER)".Trim() }
    }
    if ([string]::IsNullOrWhiteSpace($User)) {
        return @{ Action = 'failed'; DropInPath = ''; Rule = ''; Message = 'could not determine the current user to grant passwordless sudo to.' }
    }

    # Resolve the REAL binary paths -- sudoers matches the fully-qualified command
    # sudo resolves via secure_path, so the rule must list what the mount actually
    # runs. Fall back to the conventional /usr/bin/* when a lookup comes up empty.
    $mkdir  = (Get-Command -CommandType Application -Name 'mkdir'  -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $mount  = (Get-Command -CommandType Application -Name 'mount'  -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $umount = (Get-Command -CommandType Application -Name 'umount' -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($mkdir))  { $mkdir  = '/usr/bin/mkdir' }
    if ([string]::IsNullOrWhiteSpace($mount))  { $mount  = '/usr/bin/mount' }
    if ([string]::IsNullOrWhiteSpace($umount)) { $umount = '/usr/bin/umount' }
    $spec = Get-PoolStorageSudoSpec -User $User -MkdirPath $mkdir -MountPath $mount -UmountPath $umount

    # Idempotency: is passwordless sudo for every command already in effect?
    # `sudo -n -l <cmd>` exits 0 when the user may run <cmd> and never prompts (-n).
    # Bias toward 'not configured' (offer to install) if any check is not a clean 0
    # -- a redundant re-install just re-prompts once; a false 'present' would leave
    # the mount broken exactly as before.
    $already = $true
    foreach ($c in $spec.Commands) {
        $rc = Invoke-PoolStorageProcess -FilePath 'sudo' -ArgumentList @('-n', '-l', $c) -TimeoutSeconds 15
        if ($rc -ne 0) { $already = $false; break }
    }
    if ($already) {
        return @{ Action = 'present'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "passwordless sudo for mount/mkdir/umount is already configured for '$User'." }
    }

    if ($NonInteractive) {
        return @{ Action = 'skipped'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "passwordless sudo for the poolStorage mount is not configured and -NonInteractive was set; install it manually. $((Get-PoolStorageLinuxSudoHint -User $User -MkdirPath $mkdir -MountPath $mount -UmountPath $umount) -join ' ')" }
    }
    if (-not $PSCmdlet.ShouldProcess($spec.File, "Install the passwordless-sudo drop-in for poolStorage mounts (grants '$User' NOPASSWD mkdir/mount/umount)")) {
        return @{ Action = 'whatif'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "would write: $($spec.Rule)" }
    }

    # Install interactively. sudo is run so its ONE password prompt reaches the
    # operator's terminal (NOT via Invoke-PoolStorageProcess, which closes stdin
    # and redirects the streams away from the tty); the cached credential covers
    # the chmod/visudo that follow. Piping the rule to `sudo tee` is the same
    # idiom the operator hint documents; PowerShell appends the trailing newline a
    # sudoers file wants.
    Write-Host "poolStorage: installing $($spec.File) so mounts run without a password (sudo may prompt once)..."
    try {
        $spec.Rule | & sudo tee $spec.File | Out-Null
        $teeRc = $LASTEXITCODE
        if ($teeRc -ne 0) {
            return @{ Action = 'failed'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "could not write $($spec.File) (sudo tee exit $teeRc); install it manually. $((Get-PoolStorageLinuxSudoHint -User $User -MkdirPath $mkdir -MountPath $mount -UmountPath $umount) -join ' ')" }
        }
        & sudo chmod 0440 $spec.File | Out-Null
        $chmodRc = $LASTEXITCODE
        $visudoOut = (& sudo visudo -cf $spec.File 2>&1 | Out-String).Trim()
        $visudoRc = $LASTEXITCODE
        if ($chmodRc -ne 0 -or $visudoRc -ne 0) {
            # A syntactically invalid drop-in can break sudo for EVERY command, so
            # remove it rather than leave it in place.
            & sudo rm -f $spec.File | Out-Null
            return @{ Action = 'failed'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "the drop-in failed validation (chmod exit $chmodRc, visudo exit ${visudoRc}: $visudoOut) and was removed; install it manually. $((Get-PoolStorageLinuxSudoHint -User $User -MkdirPath $mkdir -MountPath $mount -UmountPath $umount) -join ' ')" }
        }
        return @{ Action = 'installed'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "installed $($spec.File): '$User' may now mount/mkdir/umount without a password." }
    } catch {
        return @{ Action = 'failed'; DropInPath = $spec.File; Rule = $spec.Rule; Message = "installing $($spec.File) threw: $($_.Exception.Message). Install it manually. $((Get-PoolStorageLinuxSudoHint -User $User -MkdirPath $mkdir -MountPath $mount -UmountPath $umount) -join ' ')" }
    }
}

# Join-PoolStoragePath combines a localPath base with a relative subpath. A
# Windows drive-qualified base ('y:' or 'y:\...') is composed by pure string via
# [IO.Path]::Combine, NOT Join-Path: Join-Path resolves the base's drive
# qualifier against the PSDrive table, so a drive letter for an SMB mount the
# current runspace has not yet enumerated -- referenced before the mount, or
# after the mapping silently dropped mid-cycle -- throws a NON-TERMINATING
# DriveNotFoundException ("A drive with the name 'y' does not exist"); the call
# then returns $null and the empty path surfaces downstream as a misleading
# "null Path argument" folder-creation failure. A bare drive letter is also
# drive-RELATIVE, so anchor it to the root ('y:' -> 'y:\') first or the join
# targets the per-process CWD on that drive. Any other base (a '/'-rooted
# macOS/Linux mount point) carries no drive qualifier, so Join-Path is safe there
# and keeps its separator normalization. SubPath is taken verbatim; callers
# normalize any embedded separators before passing it in.
function Join-PoolStoragePath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$SubPath
    )
    if ($LocalPath -notmatch '^[A-Za-z]:') {
        return (Join-Path $LocalPath $SubPath)
    }
    $base = if ($LocalPath -match '^[A-Za-z]:$') { "${LocalPath}\" } else { $LocalPath }
    return [System.IO.Path]::Combine($base, $SubPath)
}

<#
.SYNOPSIS
Copies a source directory to <LocalPath>/<DestSubPath>/ on the share, cross-platform (robocopy / rsync / cp) with every copy run through a wall-clock-bounded subprocess so a NAS stalling mid-copy cannot freeze the loop. Best-effort: a failure logs + returns $false, never throws. Cycle folders are immutable, so this copies (does not mirror-delete).
#>
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
    $dest = Join-PoolStoragePath -LocalPath $Config.LocalPath -SubPath $DestSubPath
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

<#
.SYNOPSIS
Extracts the bare server host from a share path: '\\srv\share' / '//user@srv/share/sub' -> 'srv'. Pure + testable.
#>
function Get-PoolStorageServerName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$NetworkPath)
    $bare = Get-PoolStorageBareShare -Path $NetworkPath -WithoutUser
    return (($bare -split '/', 2)[0]).Trim()
}

<#
.SYNOPSIS
Returns $true when poolStorage may proceed to mount, $false when mounting would force Get-Password to AUTO-GENERATE a junk SMB password (empty vaultKey AND no existing vault entry); a non-empty vaultKey or an already-stored entry proceeds. Pure: takes the resolved booleans, no I/O.
#>
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

<#
.SYNOPSIS
Returns the cycle names present locally but not yet in the ledger's replicated set, OLDEST FIRST (lexical order == cycle order via the zero-padded 6-digit prefix). Pure: names + ledger in, names out.
#>
function Get-PoolStoragePendingSet {
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
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

<#
.SYNOPSIS
Produces a new ledger object = old replicated set + newly committed cycles (name -> NowUtc) + updated scalar status fields, pruning any replicated entry whose cycle no longer exists locally (rotation deletes local folders; the share copy is then the durable one). Pure: no Get-Date, no I/O.
#>
function Merge-PoolStorageLedger {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [System.Collections.Specialized.OrderedDictionary])]
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
    # Carry forward the prior scalar fields before overlaying $Status: a failure
    # run supplies a $Status that omits lastCopied (only a successful copy sets
    # it), so rebuilding purely from $Status would erase the prior run's
    # lastCopied/lastConnectOk. Seeding from $Ledger first preserves an omitted
    # key while a key present in $Status still overwrites it. 'replicated' is
    # skipped -- it is already rebuilt (and pruned to LocalNames) above. This
    # carries EVERY other ledger key forward (today all status scalars); a ledger
    # key that must NOT persist across runs would need an explicit exclusion here.
    if ($Ledger -is [System.Collections.IDictionary]) {
        foreach ($lk in $Ledger.Keys) {
            if ([string]$lk -eq 'replicated') { continue }
            $out[[string]$lk] = $Ledger[$lk]
        }
    }
    if ($Status) { foreach ($sk in $Status.Keys) { $out[[string]$sk] = $Status[$sk] } }
    return $out
}

<#
.SYNOPSIS
Loads runtime/poolstorage.state.json, degrading to an empty ledger shape on absence/corruption (never throws).
#>
function Read-PoolStorageLedger {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary], [System.Collections.Specialized.OrderedDictionary])]
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

<#
.SYNOPSIS
Persists the ledger atomically (temp + rename) via the shared state-file primitive, with a direct fallback if it is not loaded.
#>
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

<#
.SYNOPSIS
Collapses a cycle folder's transient on-disk leaf ('<base>.incomplete' / '<base>' / '<base>.aborted.<UTC>') to its STABLE identity '<base>'; keying the map/dest/ledger on this -- not the raw leaf -- stops a SIGKILLed cycle from being replicated twice (once as .incomplete, again as .aborted.<UTC> after boot-recovery renames it). Prefers the canonical Get-CycleFolderIdentity when loaded; the inline fallback mirrors it so the module stays self-contained + unit-testable.
#>
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

<#
.SYNOPSIS
FAST-FAIL gate: a bounded TCP probe to <server>:445 so a dead NAS is detected in seconds instead of paying the full mount timeout; the faulted task (refused connect) is observed and the client is always disposed.
#>
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

<#
.SYNOPSIS
LOUD-FAIL pre-check: resolves a user's vault key (read-only) and refuses to mount when a mount would auto-generate a junk SMB password (empty vaultKey AND no stored entry); all read-only -- never triggers auto-generation, never writes the vault. networkUser is the single account used for every NAS connection (host-side drain AND the guest caching-proxy mount).
#>
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

<#
.SYNOPSIS
STRICT pre-check: requires a REAL password to already be stored in the vault for the networkUser, returning $false when there is none. Unlike Test-PoolStorageVaultReady (which also accepts a mere non-empty vaultKey mapping and lets Get-Password AUTO-GENERATE), this never permits auto-generation: an SMB networkUser must authenticate to a PRE-EXISTING NAS account, so an auto-generated password is always junk the NAS rejects (cifs mount error(13)). Read-only. Use it before baking the credential into a VM seed so a missing credential fails fast instead of producing a VM that can never mount.
#>
function Test-PoolStorageStoredCredential {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $who = $Config.NetworkUser
    if ([string]::IsNullOrWhiteSpace($who)) { return $false }
    if (-not (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
        Write-Warning "poolStorage: authentication extension not loaded; cannot verify a stored credential for '$who'."
        return $false
    }
    $vaultKey = ''
    if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) {
        try { $vaultKey = [string](Get-EffectiveUser -LogicalUser $who).vaultKey } catch { Write-Verbose "Get-EffectiveUser failed: $($_.Exception.Message)" }
    }
    $resolvedKey = if ([string]::IsNullOrWhiteSpace($vaultKey)) { $who } else { $vaultKey }
    try { return [bool](Test-VaultEntry -VaultKey $resolvedKey) } catch { Write-Verbose "Test-VaultEntry failed: $($_.Exception.Message)"; return $false }
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
    $destFull = Join-PoolStoragePath -LocalPath $Config.LocalPath -SubPath $destSub
    $sentinel = Join-PoolStoragePath -LocalPath $destFull -SubPath '.yuruna-complete'
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

<#
.SYNOPSIS
Orchestrator: loud-fail vault pre-check -> TCP fast-fail gate -> mount -> compute the backlog (local cycles minus the ledger, oldest first) -> copy up to MaxPerRun cycles atomically -> persist the ledger. Best-effort: returns a summary hashtable, never throws, never blocks the loop (it runs in a detached child process). Stops draining on the first copy failure (likely a lost connection) and resumes on the next run.
#>
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

<#
.SYNOPSIS
Returns the per-host destination ROOT on the share -- '<localPath>/<HostId>' -- the parent of every replicated cycle folder (Copy-PoolStorageCycle writes '<localPath>/<HostId>/<CycleName>/'). Pure + testable; deriving the gate's pre-flight target and the real copy destination from ONE helper keeps the two from drifting apart.
#>
function Get-PoolStorageHostFolderPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][string]$HostId
    )
    return (Join-PoolStoragePath -LocalPath $Config.LocalPath -SubPath $HostId)
}

<#
.SYNOPSIS
ACTIVE write-path pre-flight: mounts the share at localPath and ensures the per-host folder '<localPath>/<HostId>' exists (creating it if missing), exercising every precondition a cycle's replication actually needs -- a working mount (networkUser credential, share name, and on Linux passwordless sudo all good) AND a WRITABLE share -- to catch the "reachable NAS but replication silently never happens" class a passive :445 probe cannot see. Best-effort + bounded (mount wall-clock-capped, folder create/verify under a bounded thread job); returns @{ ok; stage; folder; error }. Assumes the caller already found the server reachable. Never throws.
#>
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
        # A stale mount of the SAME share at a DIFFERENT point (e.g. left under a
        # retired host alias) makes macOS reject the new mount with "File exists".
        # This is macOS-only: Linux and Windows both allow the same share at a
        # second mount point, so the hint is a red herring there -- it would point
        # the operator at an unmount that fixes nothing. Surface it (a headless
        # HINT, not a prompt) only on macOS, where it is the actual one-command fix.
        if ($IsMacOS) {
            $conflicts = @(Get-PoolStorageConflictingMount -Config $Config)
            if ($conflicts.Count -gt 0) {
                $pts = ($conflicts | ForEach-Object { "'$($_.MountPoint)' [$($_.Remote)]" }) -join ', '
                $result.error += ". NOTE: the same share is already mounted elsewhere ($pts) -- on macOS this blocks the new mount with 'File exists'. Run Clear-PoolStorageConflictingMount -Config (Get-YurunaPoolStorageConfig -IgnoreReplicate) to unmount it after confirmation"
            }
        }
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

<#
.SYNOPSIS
Returns $true when an SMB server NAME still resolves to at least one IP, $false when it resolves to nothing (a retired hosts-file alias leaves a persistent SMB mapping pointing at a name that no longer exists). [System.Net.Dns]::GetHostAddresses walks the full Windows resolver order (hosts file, DNS, then NetBIOS/LLMNR), so a LAN-only NetBIOS name still resolves and only a genuinely dead name throws; two aliases for ONE NAS resolving to the SAME IP is intentional and never flagged. Best-effort: any resolver error => $false.
#>
function Test-PoolStorageHostResolvable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][string]$ServerName)
    if ([string]::IsNullOrWhiteSpace($ServerName)) { return $false }
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($ServerName)
        return ($null -ne $addrs -and @($addrs).Count -gt 0)
    } catch {
        Write-Verbose "Test-PoolStorageHostResolvable($ServerName): $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
Lists the Windows SMB mappings whose server name no longer resolves to any IP -- a persistent drive left pointing at a retired host alias. Such a mapping keeps Status OK from its cached connection yet BLOCKS a fresh mount of the same physical NAS under a current alias, because the redirector still holds the dead-name session and refuses a second credentialed session to a server it is already (stale-) connected to. Returns objects { LocalPath; RemotePath; ServerName }. Windows-only; empty array elsewhere or on any error. Bounded so a wedged redirector cannot hang the caller.
#>
function Get-PoolStorageStaleAliasMount {
    [CmdletBinding()]
    [OutputType([pscustomobject[]], [object[]])]
    param()
    if (-not $IsWindows) { return @() }
    $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ScriptBlock {
        Get-SmbMapping -ErrorAction SilentlyContinue | Select-Object LocalPath, RemotePath
    }
    if ($r.TimedOut -or $r.Error) { return @() }
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($m in @($r.Result)) {
        if (-not $m -or [string]::IsNullOrWhiteSpace([string]$m.RemotePath)) { continue }
        $server = Get-PoolStorageServerName -NetworkPath ([string]$m.RemotePath)
        if (-not (Test-PoolStorageHostResolvable -ServerName $server)) {
            $out.Add([pscustomobject]@{
                LocalPath  = [string]$m.LocalPath
                RemotePath = [string]$m.RemotePath
                ServerName = $server
            })
        }
    }
    return @($out)
}

<#
.SYNOPSIS
Tears down ONE mapping by LocalPath when it has a drive letter, else by RemotePath (a device-less connection). Bounded + best-effort; returns $true on success. Windows-only.
#>
function Remove-PoolStorageStaleAliasMount {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyString()][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath
    )
    if (-not $IsWindows) { return $false }
    $target = if (-not [string]::IsNullOrWhiteSpace($LocalPath)) { $LocalPath } else { $RemotePath }
    if (-not $PSCmdlet.ShouldProcess($target, 'Remove stale SMB mapping')) { return $false }
    $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($LocalPath, $RemotePath) -ScriptBlock {
        param($local, $remote)
        if (-not [string]::IsNullOrWhiteSpace($local)) {
            Remove-SmbMapping -LocalPath $local -Force -ErrorAction Stop
        } else {
            Remove-SmbMapping -RemotePath $remote -Force -ErrorAction Stop
        }
    }
    return (-not $r.TimedOut -and -not $r.Error)
}

<#
.SYNOPSIS
Ensures the network path's TARGET SUBFOLDER exists on the share, creating it when missing. A share configured as '\\server\share\yuruna.stash' targets a SUBFOLDER, not the share root, and New-SmbMapping to a non-existent subfolder fails ("network name cannot be found" / "device is no longer available"), which the operator sees only as a vague unreachable-mount. The subfolder cannot be created through a mount of itself, so this mounts the PARENT share, creates the leaf, then releases the parent mount. No-op (ok, nothing to create) for a bare share root. Bounded + best-effort; returns @{ ok; created; folder; error }. Run AFTER any stale-alias mapping is cleared so the parent mount is not pre-empted by a dead-name session to the same NAS.
#>
function Initialize-PoolStorageTargetFolder {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][pscustomobject]$Config)
    $result = @{ ok = $false; created = $false; folder = $Config.NetworkPath; error = '' }
    $bare  = Get-PoolStorageBareShare -Path $Config.NetworkPath -TrimTrailing
    $parts = @($bare -split '/')
    if ($parts.Count -lt 3) {
        # server-only or a bare share root -- there is no subfolder to create, and a
        # share itself is provisioned on the NAS, not over SMB.
        $result.ok = $true
        return $result
    }
    $parentBare = ($parts[0..1] -join '/')                       # server/share
    $subRel     = ($parts[2..($parts.Count - 1)] -join '/')      # sub[/deeper]
    if (-not $PSCmdlet.ShouldProcess("$($Config.LocalPath) -> $subRel", 'Ensure target folder on share')) {
        $result.error = 'skipped (WhatIf)'
        return $result
    }
    $parentCfg = [pscustomobject]@{
        Replicate   = $false
        NetworkPath = '//' + $parentBare
        NetworkUser = $Config.NetworkUser
        LocalPath   = $Config.LocalPath
    }
    if (-not (Connect-YurunaPoolStorage -Config $parentCfg -Confirm:$false)) {
        $result.error = "could not mount the parent share '//$parentBare' at '$($Config.LocalPath)' to create '$subRel' (check the '$($Config.NetworkUser)' password and that the account may write the share root)"
        return $result
    }
    try {
        $leaf = Join-PoolStoragePath -LocalPath $Config.LocalPath -SubPath ($subRel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $r = Invoke-PoolStorageBoundedScript -TimeoutSeconds $script:PoolStorageSmbCmdletTimeoutSec -ArgumentList @($leaf) -ScriptBlock {
            param($f)
            $existed = [bool](Test-Path -LiteralPath $f)
            if (-not $existed) { New-Item -ItemType Directory -Force -Path $f -ErrorAction Stop | Out-Null }
            return [pscustomobject]@{ Existed = $existed; Present = [bool](Test-Path -LiteralPath $f) }
        }
        if ($r.TimedOut) {
            $result.error = "creating '$subRel' on the share timed out after ${script:PoolStorageSmbCmdletTimeoutSec}s (the share may be wedged)"
        } elseif ($r.Error -or ($null -eq $r.Result) -or -not $r.Result.Present) {
            $detail = if ($r.Error) { ": $($r.Error)" } else { '' }
            $result.error = "could not create '$subRel' on the share$detail (the account may lack write permission at the share root)"
        } else {
            $result.ok = $true
            $result.created = (-not $r.Result.Existed)
        }
    } finally {
        # Always release the temporary parent mount: the configured LocalPath is
        # meant to map the SUBFOLDER, not the share root.
        $null = Dismount-PoolStoragePoint -MountPoint $Config.LocalPath
    }
    return $result
}

<#
.SYNOPSIS
Picks the cycle names to copy THIS run from the oldest-first pending list, as a hybrid of the NEWEST $NewestShare and the OLDEST remainder (at most $Max total). Copying some newest each run makes TODAY's cycle output appear on the share within ONE drain instead of lagging the whole backlog (pure oldest-first leaves the share weeks behind on a deep backlog, so an operator looking for recent cycles sees only old ones and concludes replication is dead); the oldest remainder still backfills before local rotation can prune it, so nothing is starved. Pure: names in, names out. When the backlog fits in one run ($Max), ordering is irrelevant and the list is returned as-is.
#>
function Get-PoolStorageDrainOrder {
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
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

<#
.SYNOPSIS
Returns a human-readable warning string when the PRIOR drain's ledger indicates replication is failing/stalled (and replicate is on), else $null. The drain is detached + best-effort, so a host that has STOPPED replicating (bad credential, read-only share, a Windows drive-letter/credential collision) otherwise records the failure ONLY in the ledger, where no operator looks; the outer loop calls this each cycle so the failure surfaces loudly (console + outer.log). Pure: ledger hashtable + replicate flag in, message out. Distinguishes a genuine stall from healthy states: caught-up (pending 0) and mid-backlog (copied > 0) both return $null.
#>
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

<#
.SYNOPSIS
Resolves the STASH storage coordinates the stash VM's cloud-init seed needs -- the share UNC (unix form), the stashNetworkUser, its vault password, and this host's id -- read from the ISOLATED networkStorage stash* keys (Get-YurunaStashStorageConfig), not the pool keys. Returns empty strings when unavailable so a caller bakes blanks (the guest then uses local fallback); the fail-fast gate lives in Start-StashServer, not here. Get-YurunaHostId and Get-Password must be loaded in the caller's session.
#>
function Get-YurunaStashSeedValue {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Config)
    $out = @{ NetworkPath = ''; NetworkIp = ''; NetworkUser = ''; Password = ''; HostId = '' }
    try { $out.HostId = [string](Get-YurunaHostId) } catch { Write-Verbose "stash seed hostId: $($_.Exception.Message)" }
    if (-not $out.HostId) { $out.HostId = 'unknown-host' }
    $cfg = $null
    if ($Config) {
        try { $cfg = Get-YurunaStashStorageConfig -Config $Config } catch { Write-Verbose "stash seed config: $($_.Exception.Message)" }
    }
    if (-not $cfg) { return $out }
    $user    = [string]$cfg.NetworkUser
    $netPath = Get-PoolStorageUncPath -Path $cfg.NetworkPath -Style unix
    # Refuse a value with a single quote: it would unbalance the guest's
    # single-quoted /etc/yuruna/ystash-nas.env entries.
    if (($netPath -match "'") -or ($user -match "'")) {
        Write-Warning "poolStorage: networkPath/networkUser contains a single quote; not baking the stash share."
        return $out
    }
    $netPwd = ''
    if ($user -and (Test-PoolStorageVaultReady -Config $cfg -WarningAction SilentlyContinue)) {
        try { $netPwd = [string](Get-Password -Username $user) } catch { Write-Verbose "stash seed password: $($_.Exception.Message)" }
    }
    $out.NetworkPath = $netPath
    $out.NetworkUser = $user
    $out.Password    = $netPwd
    # Resolve the NAS hostname to an IPv4 on the HOST (where NetBIOS/DNS
    # works). A Linux guest often cannot resolve a bare NetBIOS name like
    # 'wserver', so the guest's cifs mount uses ip=<this> and skips name
    # resolution entirely. Empty when unresolvable -> guest falls back to
    # name resolution (and buffers if that fails).
    try {
        $server = Get-PoolStorageServerName -NetworkPath $cfg.NetworkPath
        if ($server) {
            $ip = [System.Net.Dns]::GetHostAddresses($server) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
            if ($ip) { $out.NetworkIp = $ip.IPAddressToString }
        }
    } catch { Write-Verbose "stash seed ip resolve: $($_.Exception.Message)" }
    return $out
}

Export-ModuleMember -Function `
    Get-PoolStorageUncPath, Test-PoolStorageMountMatch, Get-PoolStorageServerName, `
    ConvertFrom-PoolStorageMountLine, Find-PoolStorageConflictingMount, `
    Get-PoolStorageConflictingMount, Clear-PoolStorageConflictingMount, `
    Get-YurunaPoolStorageConfig, Get-YurunaStashStorageConfig, Test-YurunaPoolStorageMounted, Connect-YurunaPoolStorage, `
    Get-PoolStorageLinuxSudoHint, Get-PoolStorageSudoSpec, Set-PoolStorageSudoers, `
    Sync-YurunaPoolStorageFolder, Test-PoolStorageVaultDecision, Get-PoolStorageCycleIdentity, `
    Get-PoolStoragePendingSet, Merge-PoolStorageLedger, Read-PoolStorageLedger, `
    Write-PoolStorageLedger, Test-PoolStorageServerReachable, Test-PoolStorageVaultReady, `
    Test-PoolStorageStoredCredential, `
    Test-PoolStorageHostResolvable, Get-PoolStorageStaleAliasMount, `
    Remove-PoolStorageStaleAliasMount, Initialize-PoolStorageTargetFolder, `
    Get-PoolStorageHostFolderPath, Initialize-PoolStorageHostFolder, `
    Get-PoolStorageDrainOrder, Get-PoolStorageHealthWarning, `
    Invoke-PoolStorageDrain, Get-YurunaStashSeedValue
