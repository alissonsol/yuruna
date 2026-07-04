<#PSScriptInfo
.VERSION 2026.07.03
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

$script:TestConfigCache = @{}

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
                return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
            } finally { $sha.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        Write-Verbose "Read-TestConfig: content hash compute failed on $Path : $($_.Exception.Message)"
        return ''
    }
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
        # Resolve-Path can return $null for a path that Test-Path (above) confirms
        # exists -- observed on macOS. Fall back to the input path (already absolute
        # and existing) so the hash + read never receive a null Path, which would
        # otherwise fail Get-TestConfigContentHash's Mandatory -Path bind with a
        # cryptic "Cannot bind argument to parameter 'Path'" that masquerades as a
        # YAML parse error at the call site.
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path
        if ([string]::IsNullOrEmpty($resolved)) { $resolved = $Path }
        $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
        $hash     = Get-TestConfigContentHash -Path $resolved
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
        $script:TestConfigCache = @{}
    }
}

function Get-TestConfigSnapshotPath {
    <#
    .SYNOPSIS
        Returns the canonical on-disk path for the parsed-config snapshot
        the outer publishes for the inner to consume.
    .DESCRIPTION
        Cross-process snapshot location. Outer parses test.config.yml,
        writes the parsed result here as JSON tagged with the source
        file's mtime + content hash; inner reads the snapshot if its
        tag still matches the live YAML's mtime + hash. Avoids the
        second YAML re-parse per cycle without sacrificing freshness
        (an operator edit between outer's read and inner's read makes
        the tags mismatch, and inner falls back to a full YAML parse).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # $env:TEMP is Windows-only -- it is $null on macOS/Linux, which would make the
    # Join-Path below throw "Cannot bind argument to parameter 'Path'" whenever a
    # standalone caller (e.g. Test-Config.ps1) reads a config without
    # YURUNA_RUNTIME_DIR set. [IO.Path]::GetTempPath() resolves the temp dir on
    # every platform.
    $runtimeDir = if (-not [string]::IsNullOrWhiteSpace($env:YURUNA_RUNTIME_DIR)) { $env:YURUNA_RUNTIME_DIR } else { [System.IO.Path]::GetTempPath() }
    return (Join-Path $runtimeDir '.test.config.snapshot.json')
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
        to its own YAML parse (current behavior before the snapshot
        landed). Pair with Read-TestConfigOrSnapshot.
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
        $dest = Get-TestConfigSnapshotPath
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
        $snapshotPath = Get-TestConfigSnapshotPath
        if (Test-Path -LiteralPath $snapshotPath) {
            try {
                $resolved = (Resolve-Path -LiteralPath $Path).Path
                $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
                $hash     = Get-TestConfigContentHash -Path $resolved
                # Source freshness triple; reuse it on the fallback parse below so
                # the 64 KB SHA-256 is computed at most once per call.
                $known    = @{ Path = $resolved; Mtime = $mtime; Hash = $hash }
                $raw      = Get-Content -Raw -LiteralPath $snapshotPath -ErrorAction Stop
                $envelope = $raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($envelope -is [System.Collections.IDictionary] `
                    -and $envelope.Contains('sourcePath')  -and ($envelope.sourcePath  -ieq $resolved) `
                    -and $envelope.Contains('sourceHash')  -and ($envelope.sourceHash  -ieq $hash) `
                    -and $envelope.Contains('sourceMtime') -and ([datetime]::Parse($envelope.sourceMtime).ToUniversalTime() -eq $mtime) `
                    -and $envelope.Contains('config')      -and ($envelope.config -is [System.Collections.IDictionary])) {
                    return $envelope.config
                }
            } catch {
                Write-Verbose "Read-TestConfigOrSnapshot: snapshot read fell through ($($_.Exception.Message)); using full parse."
            }
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

Export-ModuleMember -Function Read-TestConfig, Clear-TestConfigCache, Get-TestConfigValue, Get-TestConfigSnapshotPath, Publish-TestConfigSnapshot, Read-TestConfigOrSnapshot
