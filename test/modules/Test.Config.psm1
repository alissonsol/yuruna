<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456721
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# ConvertTo-LowerHex (SHA-256 -> lowercase-hex) lives in the leaf Test.Hash module
# so every hashing caller shares one definition; import it -Global so the bare-name
# calls below resolve wherever Test.Config is loaded (including its ad-hoc importers).
Import-Module (Join-Path $PSScriptRoot 'Test.Hash.psm1') -Global -Force

# Single source of truth for reading test.config.yml. Centralises the
# `Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered` flow so error
# handling stays uniform across call sites: parse failures, $null on
# miss, and -is [IDictionary] validation all happen here. New validation
# rules (e.g. schema check) added here reach every caller automatically.
#
# Cache key is absolute path + LastWriteTimeUtc + a SHA-256 of the first
# 64 KB of file content. The content hash defends against the corner case
# where an editor restores a file to its original size AND mtime (e.g. a
# `git checkout` of a same-size revision, a `touch -d` to an exact prior
# timestamp, or a CI step that copies a backup over): mtime alone would
# return stale cached YAML, and downstream callers would silently see an
# old config for the rest of the process.
#
# 64 KB is enough to cover the entire repo's YAML files (current largest
# is < 8 KB); reading more than 64 KB on every cache check would
# negate the benefit of caching for big files.
#
# Callers that need a guaranteed fresh read (e.g. the outer's failure-pause
# config-mtime trigger) pass -NoCache.

# Ordinal (case-sensitive) key comparer: the cache is keyed by the resolved absolute
# path, and on a case-sensitive filesystem two paths differing only in case are
# DIFFERENT files that must not share a slot (the default @{} literal is case-
# insensitive). Bounded by a small FIFO cap -- the resolved-config-path set is normally
# small (test.config.yml plus the handful of schema-validated configs), so the cap is a
# safety net against unbounded growth, not a hot path.
$script:TestConfigCacheMax = 64
function Initialize-TestConfigCacheStore {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseLiteralInitializerForHashtable', '',
        Justification = 'A case-SENSITIVE Ordinal comparer is required so case-distinct paths on a case-sensitive filesystem do not share a cache slot; the @{} literal PSSA prefers here is case-insensitive, so the literal initializer is unusable.')]
    param()
    $script:TestConfigCache      = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
    $script:TestConfigCacheOrder = [System.Collections.Generic.List[string]]::new()
}
Initialize-TestConfigCacheStore

function Get-TestConfigContentHash {
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $cap   = 65536
            $buf   = New-Object byte[] $cap
            $read  = $fs.Read($buf, 0, $cap)
            $sha   = [System.Security.Cryptography.SHA256]::Create()
            try {
                $hash = $sha.ComputeHash($buf, 0, $read)
                return (ConvertTo-LowerHex $hash)
            } finally { $sha.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        Write-Verbose "Read-TestConfig: content hash compute failed on $Path : $($_.Exception.Message)"
        return ''
    }
}

function Get-TestConfigFreshnessTriple {
    <#
    .SYNOPSIS
        Resolve a config path to its canonical (path, mtime, hash) freshness
        triple used to key the parse cache and validate snapshots.
    .DESCRIPTION
        Returns a hashtable with Path (resolved absolute path), Mtime
        (LastWriteTimeUtc) and Hash (64 KB SHA-256). Caller must have already
        confirmed the file exists; the resolve step below tolerates a null
        Resolve-Path result but the file must be present for Get-Item to succeed.
    .PARAMETER Path
        Absolute or relative path to an existing YAML file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    # Resolve-Path can return $null for a path the caller's Test-Path confirmed
    # exists -- observed on macOS. Fall back to the input path (already absolute
    # and existing) so the hash + read never receive a null Path, which would
    # otherwise fail Get-TestConfigContentHash's Mandatory -Path bind with a
    # cryptic "Cannot bind argument to parameter 'Path'" that masquerades as a
    # YAML parse error at the call site.
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrEmpty($resolved)) { $resolved = $Path }
    $mtime = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
    $hash  = Get-TestConfigContentHash -Path $resolved
    return @{ Path = $resolved; Mtime = $mtime; Hash = $hash }
}

function Read-TestConfig {
    <#
    .SYNOPSIS
        Load and parse a YAML config file. Returns an ordered dictionary
        or $null on parse / missing-file errors.
    .DESCRIPTION
        Wraps `Get-Content -Raw | ConvertFrom-Yaml -Ordered` with a
        unified error path and an mtime-keyed cache.
    .PARAMETER Path
        Absolute or relative path to the YAML file.
    .PARAMETER NoCache
        Force a fresh read even when the cache holds an unchanged copy.
        Use for diagnostic / probe call sites where the cost of re-parsing
        is acceptable.
    .PARAMETER ThrowOnError
        Re-throw parse exceptions instead of returning $null. Use when the
        caller cannot tolerate a silent missing/broken config (e.g. the
        outer runner's startup gate).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NoCache,
        [switch]$ThrowOnError,
        # Freshness triple already computed by the caller (Read-TestConfigOrSnapshot
        # computes it to compare against the snapshot envelope). When all three are
        # supplied, skip recomputing the 64 KB SHA-256 a second time on fallthrough.
        [string]$KnownResolvedPath,
        [object]$KnownMtime,
        [string]$KnownHash
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($ThrowOnError) { throw "Config file not found: $Path" }
        return $null
    }
    if ($KnownResolvedPath -and $KnownMtime -and $KnownHash) {
        $resolved = $KnownResolvedPath
        $mtime    = [datetime]$KnownMtime
        $hash     = $KnownHash
    } else {
        $triple   = Get-TestConfigFreshnessTriple -Path $Path
        $resolved = $triple.Path
        $mtime    = $triple.Mtime
        $hash     = $triple.Hash
    }
    if (-not $NoCache -and $script:TestConfigCache.ContainsKey($resolved)) {
        $entry = $script:TestConfigCache[$resolved]
        if ($entry.Mtime -eq $mtime -and $entry.Hash -eq $hash) { return $entry.Config }
    }
    try {
        $parsed = Get-Content -Raw -LiteralPath $resolved -ErrorAction Stop |
            ConvertFrom-Yaml -Ordered -ErrorAction Stop
    } catch {
        if ($ThrowOnError) { throw }
        Write-Verbose "Read-TestConfig: could not parse $resolved : $($_.Exception.Message)"
        return $null
    }
    if ($parsed -isnot [System.Collections.IDictionary]) {
        if ($ThrowOnError) { throw "Config root is not a mapping: $resolved" }
        Write-Verbose "Read-TestConfig: root of $resolved is not a mapping; returning `$null."
        return $null
    }
    $script:TestConfigCache[$resolved] = @{ Mtime = $mtime; Hash = $hash; Config = $parsed }
    if (-not $script:TestConfigCacheOrder.Contains($resolved)) { $script:TestConfigCacheOrder.Add($resolved) }
    while ($script:TestConfigCacheOrder.Count -gt $script:TestConfigCacheMax) {
        $evict = $script:TestConfigCacheOrder[0]
        $script:TestConfigCacheOrder.RemoveAt(0)
        [void]$script:TestConfigCache.Remove($evict)
    }
    # Auto-publish the snapshot on every successful parse. The publish
    # is a best-effort atomic write; failure is silently logged at
    # Verbose level. Subsequent same-process reads hit the in-process
    # cache above; cross-process consumers (inner -- spawned after
    # outer publishes) call Read-TestConfigOrSnapshot which compares
    # the snapshot envelope's (mtime, hash) against the live yml and
    # only uses it when both still match.
    Publish-TestConfigSnapshot -Config $parsed -SourcePath $resolved -SourceMtime $mtime -SourceHash $hash -Confirm:$false | Out-Null
    return $parsed
}

function Clear-TestConfigCache {
    <#
    .SYNOPSIS
        Drop all cached parses. Used by tests; production code should
        rely on the mtime-keyed invalidation instead.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.Config cache', 'Clear')) {
        Initialize-TestConfigCacheStore
    }
}

function Get-TestConfigSnapshotPath {
    <#
    .SYNOPSIS
        Returns the on-disk path for the parsed-config snapshot the outer publishes
        for the inner to consume, one slot per source config.
    .DESCRIPTION
        Cross-process snapshot location. Outer parses a config, writes the parsed
        result here as JSON tagged with the source file's mtime + content hash; inner
        reads the snapshot if its tag still matches the live YAML's mtime + hash. Avoids
        the second YAML re-parse per cycle without sacrificing freshness (an operator
        edit between outer's read and inner's read makes the tags mismatch, and inner
        falls back to a full YAML parse). The resolved SOURCE PATH is hashed into the
        filename so distinct configs (test.config.yml, vault.yml, ...) get distinct slots
        instead of clobbering one shared file -- the schema validator reads several
        configs through the same reader.
    .PARAMETER SourcePath
        The resolved source config path this snapshot belongs to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SourcePath)
    # Hash the resolved source path into the filename. The resolved path is canonical,
    # so this respects filesystem case (matching the Ordinal cache key): the same file
    # always maps to the same slot, and case-distinct files on a case-sensitive FS get
    # distinct slots.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $tag = (ConvertTo-LowerHex (
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SourcePath)))).Substring(0, 12)
    } finally { $sha.Dispose() }
    # $env:TEMP is Windows-only ($null on macOS/Linux); [IO.Path]::GetTempPath() resolves
    # the temp dir on every platform.
    if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_RUNTIME_DIR)) {
        # The runner's runtime dir is per-runner and not world-writable.
        $dir = $env:YURUNA_RUNTIME_DIR
    } else {
        # A standalone caller (e.g. Test-Config.ps1) with no runtime dir would otherwise
        # land in the world-writable shared system temp, where another local user could
        # collide with -- or plant a poisoned snapshot for -- this one. Namespace under a
        # per-user subdirectory so each user's snapshots are isolated.
        $user    = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { 'nouser' }
        $userTag = [System.Text.RegularExpressions.Regex]::Replace($user, '[^A-Za-z0-9._-]', '_')
        $dir     = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-$userTag"
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
    }
    return (Join-Path $dir ".test.config.snapshot.$tag.json")
}

function Publish-TestConfigSnapshot {
    <#
    .SYNOPSIS
        Persist a parsed test.config.yml + freshness tag to disk so the
        inner process can consume it without re-parsing the YAML.
    .DESCRIPTION
        Best-effort atomic write: serializes the config payload + a
        small header (sourcePath, sourceMtime, sourceHash, publishedAt,
        publisherPid) to <runtimeDir>/.test.config.snapshot.json via a
        temp-file rename. A consumer compares its source file's
        (mtime, hash) against the snapshot's header to decide whether
        the snapshot is still authoritative.

        Failure modes are logged Verbose; the publisher's main flow
        never raises because the worst case is the consumer falls back
        to its own YAML parse. Pair with Read-TestConfigOrSnapshot.
    .PARAMETER Config
        Already-parsed configuration (the dictionary returned by Read-
        TestConfig).
    .PARAMETER SourcePath
        Absolute path of the YAML file that was parsed.
    .PARAMETER SourceMtime
        LastWriteTimeUtc of the YAML file at parse time.
    .PARAMETER SourceHash
        Get-TestConfigContentHash of the YAML file at parse time.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][datetime]$SourceMtime,
        [Parameter(Mandatory)][string]$SourceHash
    )
    # Snapshot publish is strictly best-effort: a consumer that can't read it just
    # re-parses the YAML. So the WHOLE body (path resolution included) is wrapped --
    # it must never raise into Read-TestConfig and turn a clean parse into a failure.
    $dest = $null
    try {
        $dest = Get-TestConfigSnapshotPath -SourcePath $SourcePath
        if (-not $PSCmdlet.ShouldProcess($dest, 'Publish test.config.yml snapshot')) { return $dest }
        $envelope = [ordered]@{
            sourcePath   = [string]$SourcePath
            sourceMtime  = $SourceMtime.ToString('o')
            sourceHash   = [string]$SourceHash
            publishedAt  = (Get-Date).ToUniversalTime().ToString('o')
            publisherPid = $PID
            config       = $Config
        }
        $json = $envelope | ConvertTo-Json -Depth 32 -Compress
        $tmp  = "$dest.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $dest -Force
    } catch {
        Write-Verbose "Publish-TestConfigSnapshot: $($_.Exception.Message)"
    }
    return $dest
}

function Read-TestConfigOrSnapshot {
    <#
    .SYNOPSIS
        Prefer the cross-process snapshot when its freshness tag still
        matches the source YAML; fall back to Read-TestConfig otherwise.
    .DESCRIPTION
        Saves one YAML re-parse per inner-cycle when the outer has
        already published a snapshot for the same (path, mtime, hash)
        triple. On any snapshot miss (file absent, parse error, hash /
        mtime drift, IDictionary shape mismatch), transparently falls
        through to Read-TestConfig with the same parameters. The
        in-process cache from Read-TestConfig is still honored when
        the fallback path fires.

        Output shape is identical to Read-TestConfig so existing
        callers can swap call sites without further changes.
    .PARAMETER Path
        Absolute or relative path of the YAML to load.
    .PARAMETER NoCache
        Force a fresh read AND refuse the snapshot. Use when an
        intentional mid-cycle edit must be observed (e.g. the outer's
        Get-OuterStepTimeoutMinute re-read).
    .PARAMETER ThrowOnError
        Re-throw on parse failure (forwarded to the fallback path).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$NoCache,
        [switch]$ThrowOnError
    )
    $known = $null
    if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
        try {
            # Source freshness triple; reuse it on the fallback parse below so
            # the 64 KB SHA-256 is computed at most once per call. Shares the
            # macOS null-Resolve-Path fallback with Read-TestConfig so a null
            # resolve does not throw and silently forfeit the snapshot.
            $known    = Get-TestConfigFreshnessTriple -Path $Path
            $resolved = $known.Path
            $mtime    = $known.Mtime
            $hash     = $known.Hash
            # Per-source slot: the snapshot filename is keyed by the resolved source
            # path, so a snapshot published for a different config cannot be mistaken
            # for this one.
            $snapshotPath = Get-TestConfigSnapshotPath -SourcePath $resolved
            if (Test-Path -LiteralPath $snapshotPath) {
                $raw      = Get-Content -Raw -LiteralPath $snapshotPath -ErrorAction Stop
                $envelope = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($envelope -is [System.Collections.IDictionary] `
                    -and $envelope.Contains('sourcePath')  -and ($envelope.sourcePath  -ieq $resolved) `
                    -and $envelope.Contains('sourceHash')  -and ($envelope.sourceHash  -ieq $hash) `
                    -and $envelope.Contains('sourceMtime') -and ([datetime]::Parse($envelope.sourceMtime).ToUniversalTime() -eq $mtime) `
                    -and $envelope.Contains('config')      -and ($envelope.config -is [System.Collections.IDictionary])) {
                    return $envelope.config
                }
            }
        } catch {
            Write-Verbose "Read-TestConfigOrSnapshot: snapshot read fell through ($($_.Exception.Message)); using full parse."
        }
    }
    if ($known) {
        return (Read-TestConfig -Path $Path -NoCache:$NoCache -ThrowOnError:$ThrowOnError `
            -KnownResolvedPath $known.Path -KnownMtime $known.Mtime -KnownHash $known.Hash)
    }
    return (Read-TestConfig -Path $Path -NoCache:$NoCache -ThrowOnError:$ThrowOnError)
}

function Get-TestConfigValue {
    <#
    .SYNOPSIS
        Read a dotted key path out of a parsed config; returns $null when
        any segment is missing. Removes the repetitive
        `if ($cfg -is [IDictionary] -and $cfg.foo -is [IDictionary] -and ...)`
        chain from call sites.
    .EXAMPLE
        Get-TestConfigValue -Config $cfg -Path 'repositories.projectUrl'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Config,
        [Parameter(Mandatory)][string]$Path
    )
    $node = $Config
    foreach ($segment in ($Path -split '\.')) {
        if ($node -is [System.Collections.IDictionary] -and $node.Contains($segment)) {
            $node = $node[$segment]
        } else {
            return $null
        }
    }
    return $node
}

Export-ModuleMember -Function Read-TestConfig, Clear-TestConfigCache, Get-TestConfigValue, Get-TestConfigSnapshotPath, Publish-TestConfigSnapshot, Read-TestConfigOrSnapshot, Get-TestConfigFreshnessTriple
