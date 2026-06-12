<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42c7d3a9-5e1b-4f80-9a2c-6d8e3f1b0a47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Sequence-file reading and search-path resolution. Read-SequenceFile parses a
# YAML sequence into an OrderedDictionary; Resolve-SequencePath /
# Get-SequenceSearchPath / Get-SequenceMode(Path) / Get-ProjectTestSearchDir /
# Find-ProjectSequenceFile build the gui/ssh-aware candidate paths. Extracted
# from the engine. Read-SequenceFile imports powershell-yaml on demand, and
# Get-SequenceMode reads the keystroke mechanism from
# $env:YURUNA_KEYSTROKE_MECHANISM (the engine mirrors its config value there),
# so this module carries no engine $script: state.
<#
.SYNOPSIS
    Parses a YAML sequence file into an OrderedDictionary.
.DESCRIPTION
    Centralises the powershell-yaml dependency for every sequence reader
    (Invoke-Sequence, Test.SequencePlanner, Test-Sequence). Uses
    -Ordered so the steps array and the variables map preserve their
    on-disk order. The returned object is an [OrderedDictionary]; callers
    must use .Keys / .Contains() rather than .PSObject.Properties, since
    the YAML parser does not produce PSCustomObject.
#>
function Read-SequenceFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        # Bypass the mtime-keyed cache for diagnostic / probe call
        # sites that need a guaranteed fresh read.
        [switch]$NoCache
    )
    if (-not (Get-Module powershell-yaml)) {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw "powershell-yaml is required to read sequence files. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        }
        Import-Module powershell-yaml -Global -Verbose:$false -ErrorAction Stop
    }
    # Mtime-keyed parse cache, parallel to Test.Config's pattern.
    # The planner walks every sequence in the chain once per Resolve-
    # CyclePlan call; without a cache that's 50+ YAML parses per cycle
    # (~300-500 ms). Cache key is absolute path + LastWriteTimeUtc.
    if (-not $script:SequenceFileCache) { $script:SequenceFileCache = @{} }
    if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
        $resolved = (Resolve-Path -LiteralPath $Path).Path
        $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
        if ($script:SequenceFileCache.ContainsKey($resolved)) {
            $entry = $script:SequenceFileCache[$resolved]
            if ($entry.Mtime -eq $mtime) { return $entry.Parsed }
        }
    }
    try {
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if (-not $NoCache -and (Test-Path -LiteralPath $Path)) {
            $resolved = (Resolve-Path -LiteralPath $Path).Path
            $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
            $script:SequenceFileCache[$resolved] = @{ Mtime = $mtime; Parsed = $parsed }
        }
        return $parsed
    } catch {
        # YamlDotNet's SyntaxErrorException carries Start/End marks with
        # Line/Column, but powershell-yaml wraps it in a generic
        # MethodInvocationException whose message just says "Exception
        # calling 'Load' with '1' argument(s): <inner>". Walk the
        # InnerException chain to find the SyntaxErrorException, pull the
        # marks, and re-throw with file path + line:col so the operator
        # doesn't have to bisect the sequence tree by hand.
        $err = $_.Exception
        $synErr = $null
        $probe = $err
        while ($probe) {
            if ($probe.GetType().FullName -eq 'YamlDotNet.Core.SyntaxErrorException') {
                $synErr = $probe; break
            }
            $probe = $probe.InnerException
        }
        if ($synErr) {
            $line = $synErr.Start.Line
            $col  = $synErr.Start.Column
            throw "YAML parse error in $Path at line ${line}:${col}: $($synErr.Message)"
        }
        throw "YAML parse error in $Path`: $($err.Message)"
    }
}

<#
.SYNOPSIS
    Returns the active sequence mode (gui or ssh) from test.config.yml.
.DESCRIPTION
    Maps test.config.yml keystrokeMechanism to the sequence subfolder:
    "SSH" -> "ssh", anything else -> "gui". Callers use this to build
    mode-specific paths like <sequencesDir>/<mode>/<name>.yml. Reads the
    mechanism from $env:YURUNA_KEYSTROKE_MECHANISM, which Invoke-Sequence
    mirrors from its config value at load (this module no longer shares the
    engine's $script: scope), mirroring the YURUNA_LOG_LEVEL pattern.
#>
function Get-SequenceMode {
    if ($env:YURUNA_KEYSTROKE_MECHANISM -eq "SSH") { return "ssh" }
    return "gui"
}

<#
.SYNOPSIS
    Whether a missing ssh/ sequence may fall back to its gui/ sibling.
.DESCRIPTION
    Reads $env:YURUNA_ALLOW_GUI_FALLBACK (mirrored from
    vmCommunication.allowGuiFallback by Invoke-Sequence, like
    YURUNA_KEYSTROKE_MECHANISM). Default is $false: under keystrokeMechanism=SSH
    the gui/ and ssh/ mechanisms are INDEPENDENT, so a missing ssh/ sequence is a
    resolution miss (hard error upstream), not a silent run on the OCR sibling
    that an SSH-only host could not drive.
#>
function Test-GuiFallbackAllowed {
    return ($env:YURUNA_ALLOW_GUI_FALLBACK -eq 'true')
}

<#
.SYNOPSIS
    Given a sequence path in one mode's subfolder, return the path in another mode's subfolder.
.DESCRIPTION
    Swaps the mode subfolder (gui <-> ssh) while keeping the sequence filename
    and the parent sequences directory. Returns $null if the input path is not
    under a recognised mode subfolder. Callers are responsible for Test-Path-ing
    the result before using it.
#>
function Get-SequenceModePath {
    param(
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode
    )
    $leaf      = Split-Path -Leaf   $SequencePath
    $parent    = Split-Path -Parent $SequencePath
    $grandparent = Split-Path -Parent $parent
    if (-not $grandparent) { return $null }
    return (Join-Path (Join-Path $grandparent $Mode) $leaf)
}

<#
.SYNOPSIS
    Returns the ordered list of project test/<mode>/ directories beneath
    the cloned project root, e.g. project/example/website/test/gui/.
.DESCRIPTION
    The cycle clones test.config.yml's repositories.projectUrl into <RepoRoot>/project/. Each
    project under that tree may ship its own test sequences in
    <project>/test/<mode>/. We walk project/ once and collect every
    directory whose name matches the requested mode and whose immediate
    parent is named "test". This keeps depth flexible — projects sit at
    project/<category>/<name>/test/<mode>/ (e.g. example/website) or at
    project/<name>/test/<mode>/ (e.g. template) — without callers having
    to know the layout.

    project/test/ (cycle config holder) deliberately has no gui/ssh
    subdirs, so it is naturally excluded.
#>
function Get-ProjectTestSearchDir {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode
    )
    $projectRoot = Join-Path $RepoRoot 'project'
    if (-not (Test-Path $projectRoot)) { return @() }
    return @(
        Get-ChildItem -Path $projectRoot -Directory -Recurse -Filter $Mode -ErrorAction SilentlyContinue |
            Where-Object { (Split-Path -Leaf (Split-Path -Parent $_.FullName)) -eq 'test' } |
            ForEach-Object { $_.FullName }
    )
}

<#
.SYNOPSIS
    Returns the single project-tree match for $FileName under test/$Mode/ folders.
.DESCRIPTION
    Scans every project test/<Mode>/ folder returned by Get-ProjectTestSearchDir
    for a file with the exact $FileName. Returns the full path when exactly one
    hit is found; $null when none. When two or more hits are found, throws a
    PlannerFatal exception so the cycle aborts before any guest runs --
    duplicates indicate an ambiguous plan (two examples both shipping the same
    sequence name) and the operator must decide which one wins.
.PARAMETER RepoRoot
    Framework repo root. The project clone lives at <RepoRoot>/project/.
.PARAMETER Mode
    Keystroke mechanism ('gui' or 'ssh') -- selects the test/<mode>/ subfolder.
.PARAMETER FileName
    Sequence basename WITH extension, e.g. "workload.guest.ubuntu.server.24.yml".
    Host-specific variants get passed in with the suffix already applied.
#>
function Find-ProjectSequenceFile {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][ValidateSet('gui', 'ssh')][string]$Mode,
        [Parameter(Mandatory)][string]$FileName
    )
    $hits = @(
        foreach ($d in (Get-ProjectTestSearchDir -RepoRoot $RepoRoot -Mode $Mode)) {
            $candidate = Join-Path $d $FileName
            if (Test-Path $candidate) { $candidate }
        }
    )
    if ($hits.Count -gt 1) {
        $list = ($hits | ForEach-Object { "    $_" }) -join "`n"
        throw "PlannerFatal: $($hits.Count) project sequence files named '$FileName' found under test/$Mode/ folders:`n$list`nKeep only one so the planner can resolve a single sequence file."
    }
    if ($hits.Count -eq 1) { return $hits[0] }
    return $null
}

<#
.SYNOPSIS
    Resolves a sequence name to the path under the active mode subfolder, with gui fallback.
.DESCRIPTION
    Search order:
      1. Project tree:   project/<...>/test/<mode>/<Name>.[<host-short>.]yml
      2. Framework:      <SequencesDir>/<mode>/<Name>.[<host-short>.]yml
      3. Framework gui:  <SequencesDir>/gui/<Name>.[<host-short>.]yml (when mode != gui)
    Project-tree matches win so a project can override a framework
    sequence with the same name. Returns $null when no tier matches --
    callers should pair this with Get-SequenceSearchPath to report the
    actual locations tried instead of inventing a "resolved" path.
.PARAMETER SequencesDir
    Path to the framework sequences root (e.g. test/sequences). The gui/
    and ssh/ subfolders live directly beneath this.
.PARAMETER Name
    Sequence basename without extension, e.g. "workload.guest.ubuntu.server.24".
.PARAMETER HostType
    Optional. When supplied, host-specific variants
    (<Name>.<host-short>.yml) are tried before the unsuffixed file.
.PARAMETER RepoRoot
    Optional. When supplied, project-tree dirs (project/<...>/test/<mode>/)
    are searched first. Omit for framework-only resolution.
#>
function Resolve-SequencePath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    # When a HostType is provided, prefer a host-specific sequence file
    # (filename suffix == HostType minus the 'host.' prefix). This lets a
    # single GuestKey ship divergent sequences across hosts -- e.g. KVM's
    # ubuntu.server.24 uses a cloud-image (no autoinstall, boots straight to
    # login) while Hyper-V's drives subiquity through autoinstall first.
    # When $HostType is null/empty the host-specific tiers are skipped.
    $mode = Get-SequenceMode
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }

    # Default RepoRoot to parent of SequencesDir's parent (test/sequences -> test -> repo).
    # Callers that already know RepoRoot can pass it explicitly to skip the inference.
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    # Tier 1: project tree. Scan EVERY test/<mode>/ folder under the project
    # root via Find-ProjectSequenceFile -- examples are self-contained, so a
    # sequence may live under any example's test tree. When two folders
    # contain the same filename, Find-ProjectSequenceFile throws PlannerFatal
    # so the operator resolves the duplicate before the cycle proceeds (see
    # the catch around Resolve-CyclePlan in Invoke-TestInnerRunner.ps1).
    if ($RepoRoot) {
        $modeOrder = @($mode)
        # gui/ fallback only when explicitly allowed -- otherwise the mechanisms
        # are independent and a missing ssh/ sequence must not resolve to gui/.
        if ($mode -ne 'gui' -and (Test-GuiFallbackAllowed)) { $modeOrder += 'gui' }
        foreach ($searchMode in $modeOrder) {
            if ($hostShort) {
                $hit = Find-ProjectSequenceFile -RepoRoot $RepoRoot -Mode $searchMode -FileName "$Name.$hostShort.yml"
                if ($hit) { return $hit }
            }
            $hit = Find-ProjectSequenceFile -RepoRoot $RepoRoot -Mode $searchMode -FileName "$Name.yml"
            if ($hit) { return $hit }
        }
    }

    # Tier 2/3: framework SequencesDir.
    if ($hostShort) {
        $hostModePath = Join-Path (Join-Path $SequencesDir $mode) "$Name.$hostShort.yml"
        if (Test-Path $hostModePath) { return $hostModePath }
    }
    $modePath = Join-Path (Join-Path $SequencesDir $mode) "$Name.yml"
    if (Test-Path $modePath) { return $modePath }
    # gui/ fallback only when explicitly allowed (independent mechanisms by default).
    if ($mode -ne 'gui' -and (Test-GuiFallbackAllowed)) {
        if ($hostShort) {
            $hostGuiPath = Join-Path (Join-Path $SequencesDir 'gui') "$Name.$hostShort.yml"
            if (Test-Path $hostGuiPath) { return $hostGuiPath }
        }
        $guiPath = Join-Path (Join-Path $SequencesDir 'gui') "$Name.yml"
        if (Test-Path $guiPath) { return $guiPath }
    }
    # Nothing matched. Returning the last-tried path here would lie about
    # where the file "lives" -- callers Test-Path'd it and emitted warnings
    # naming a path that was never an actual hit. Return $null so the miss
    # is unambiguous; callers pair this with Get-SequenceSearchPath when
    # they need to show the operator which locations were searched.
    return $null
}

<#
.SYNOPSIS
    Returns the ordered list of paths Resolve-SequencePath would attempt for $Name.
.DESCRIPTION
    Mirrors the search order of Resolve-SequencePath without touching the
    filesystem -- every tier (project tree x mode x host-suffix, then
    framework SequencesDir tiers) is materialised so callers can show the
    operator exactly which locations were checked when nothing matched.
    Use this in "sequence not found" diagnostics instead of printing the
    last-attempted path as if it were the canonical location.
#>
function Get-SequenceSearchPath {
    param(
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$Name,
        [string]$HostType,
        [string]$RepoRoot
    )
    $mode = Get-SequenceMode
    $hostShort = $null
    if ($HostType) { $hostShort = $HostType -replace '^host\.','' }
    if (-not $RepoRoot) {
        $maybeTest = Split-Path -Parent $SequencesDir
        if ($maybeTest) { $RepoRoot = Split-Path -Parent $maybeTest }
    }

    $paths = New-Object System.Collections.Generic.List[string]
    if ($RepoRoot) {
        $modeOrder = @($mode)
        # gui/ fallback only when explicitly allowed -- otherwise the mechanisms
        # are independent and a missing ssh/ sequence must not resolve to gui/.
        if ($mode -ne 'gui' -and (Test-GuiFallbackAllowed)) { $modeOrder += 'gui' }
        foreach ($searchMode in $modeOrder) {
            foreach ($d in (Get-ProjectTestSearchDir -RepoRoot $RepoRoot -Mode $searchMode)) {
                if ($hostShort) { [void]$paths.Add((Join-Path $d "$Name.$hostShort.yml")) }
                [void]$paths.Add((Join-Path $d "$Name.yml"))
            }
        }
    }
    if ($hostShort) { [void]$paths.Add((Join-Path (Join-Path $SequencesDir $mode) "$Name.$hostShort.yml")) }
    [void]$paths.Add((Join-Path (Join-Path $SequencesDir $mode) "$Name.yml"))
    if ($mode -ne 'gui' -and (Test-GuiFallbackAllowed)) {
        if ($hostShort) { [void]$paths.Add((Join-Path (Join-Path $SequencesDir 'gui') "$Name.$hostShort.yml")) }
        [void]$paths.Add((Join-Path (Join-Path $SequencesDir 'gui') "$Name.yml"))
    }
    return $paths.ToArray()
}

Export-ModuleMember -Function Read-SequenceFile, Get-SequenceMode, Get-SequenceModePath, Test-GuiFallbackAllowed, Get-ProjectTestSearchDir, Find-ProjectSequenceFile, Resolve-SequencePath, Get-SequenceSearchPath