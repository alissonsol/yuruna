<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456811
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

# Loader for pluggable extension areas under test/extension/<area>/.
# Each area's <area>.config.yml names the active .psm1 modules; this
# module imports them and exposes their public functions to the caller
# via -Global import.

# Repo root = three levels above this file (test/modules/Test.Extension.psm1).
$script:RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:ExtensionDir = Join-Path $script:RepoRoot 'test/extension'

# Mtime-keyed cache for parsed <Area>.config.yml. Hit on every ${ext:...}
# expansion and per callExtension step; without the cache the YAML is re-
# parsed each time. Mirrors Test.Config.psm1's pattern but skips the
# content-hash check -- these files are small (<1 KB) and not subject to
# the same-size + same-mtime race the test-config cache defends against.
$script:ExtensionConfigCache = @{}

<#
.SYNOPSIS
    Returns the absolute path of an extension area directory under
    test/extension/. Area name must match the directory basename
    exactly (e.g. 'authentication', 'notification') -- no alias map.
.PARAMETER Area
    Area name (the directory basename).
#>
function Resolve-ExtensionAreaDir {
    param([Parameter(Mandatory)][string]$Area)
    $dir = Join-Path $script:ExtensionDir $Area
    if (-not (Test-Path $dir)) { throw "Extension area directory not found: $dir" }
    return $dir
}

<#
.SYNOPSIS
    Reads the <Area>.config.yml for an area as an ordered dictionary.
    Throws if the file is missing or has no 'active' entries.
.PARAMETER Area
    Area name (e.g. 'authentication', 'notification'). The config file
    is named "<Area>.config.yml" in the area directory.
#>
function Read-ExtensionConfig {
    param([Parameter(Mandatory)][string]$Area)
    $dir  = Resolve-ExtensionAreaDir -Area $Area
    $file = Join-Path $dir "$Area.config.yml"
    if (-not (Test-Path $file)) { throw "$Area.config.yml missing for area '$Area' at $file." }
    $resolved = (Resolve-Path -LiteralPath $file).Path
    $mtime    = (Get-Item -LiteralPath $resolved).LastWriteTimeUtc
    if ($script:ExtensionConfigCache.ContainsKey($resolved)) {
        $entry = $script:ExtensionConfigCache[$resolved]
        if ($entry.Mtime -eq $mtime) { return $entry.Config }
    }
    $cfg = Get-Content -Raw $resolved | ConvertFrom-Yaml -Ordered
    if (-not $cfg.Contains('active') -or -not $cfg.active -or @($cfg.active).Count -eq 0) {
        throw "$Area.config.yml for area '$Area' has no 'active' entries."
    }
    $script:ExtensionConfigCache[$resolved] = @{ Mtime = $mtime; Config = $cfg }
    return $cfg
}

<#
.SYNOPSIS
    Returns the names of active extensions for $Area (one or more, in
    order). The pipeline unrolls a single-element array to a scalar
    string, so callers MUST wrap the call in @(...) before indexing:
        $names = @(Get-ActiveExtensionName -Area 'authentication')
        $extName = $names[0]
    Without the @() wrap, `$names[0]` on a single-entry config returns
    the first character ('d' from 'default'), not the name.
#>
function Get-ActiveExtensionName {
    param([Parameter(Mandatory)][string]$Area)
    return (Read-ExtensionConfig -Area $Area).active
}

<#
.SYNOPSIS
    Asserts that the supplied function list covers the contract verbs
    declared in <Area>/<Area>.contract.yml. Mirrors the shape of
    host/Yuruna.Host.Contract.psm1's Assert-YurunaHostContractCoverage:
    one warning naming every gap, returns boolean.
.DESCRIPTION
    Called by Import-Extension once per loaded module. If the area has
    no .contract.yml the function returns $true (no contract declared
    -> nothing to enforce). When a contract is present, missing verbs
    are reported in a single Write-Warning so the operator sees the
    full delta in one line. Returns $true when coverage is complete,
    $false otherwise -- callers decide whether to fail loudly or
    continue based on policy. The current Import-Extension policy is
    "warn and continue" so a stale/partial extension surfaces before
    the first cycle step references it without blocking unrelated
    cycles.
.PARAMETER Area
    Extension area name (the directory basename).
.PARAMETER ExtensionName
    Module basename without .psm1 (typically 'default'). Used in the
    warning to name which extension implementation is incomplete.
.PARAMETER ExportedFunction
    The list of function names actually exported by the loaded module
    (Get-Module | Select-Object -Expand ExportedCommands keys).
#>
function Assert-ExtensionContractCoverage {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$ExtensionName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExportedFunction
    )
    $dir          = Resolve-ExtensionAreaDir -Area $Area
    $contractFile = Join-Path $dir "$Area.contract.yml"
    if (-not (Test-Path -LiteralPath $contractFile)) {
        Write-Verbose "No contract file for area '$Area' at $contractFile; skipping coverage check."
        return $true
    }
    $contract = Get-Content -Raw $contractFile | ConvertFrom-Yaml -Ordered
    $required = @()
    if ($contract.Contains('requiredFunction') -and $contract.requiredFunction) {
        $required = @($contract.requiredFunction)
    }
    if ($required.Count -eq 0) {
        Write-Verbose "Contract for area '$Area' declares no requiredFunction entries; skipping coverage check."
        return $true
    }
    $exported = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$ExportedFunction, [System.StringComparer]::OrdinalIgnoreCase)
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        if (-not $exported.Contains($name)) { [void]$missing.Add($name) }
    }
    if ($missing.Count -gt 0) {
        Write-Warning "Extension '$ExtensionName' for area '$Area' is missing $($missing.Count) contract verb(s): $($missing -join ', '). See $contractFile."
        return $false
    }
    Write-Verbose "Extension '$ExtensionName' for area '$Area' covers all $($required.Count) contract verbs."
    return $true
}

<#
.SYNOPSIS
    Imports the active extension(s) for $Area into the global scope.
    Authentication uses exactly one; notification iterates the list.
#>
function Import-Extension {
    param(
        [Parameter(Mandatory)][string]$Area,
        [switch]$RequireSingle
    )
    $dir   = Resolve-ExtensionAreaDir -Area $Area
    $names = @(Get-ActiveExtensionName -Area $Area)
    if ($RequireSingle -and $names.Count -ne 1) {
        throw "Area '$Area' requires exactly one active extension; $Area.config.yml lists $($names.Count): $($names -join ', ')."
    }
    foreach ($n in $names) {
        $path = Join-Path $dir "$n.psm1"
        if (-not (Test-Path $path)) { throw "Extension module not found for area '$Area', name '$n': $path" }
        # Skip re-import if the same .psm1 path is already loaded. -Force
        # on Import-Module evicts any module sharing the basename
        # ('default') -- so a second area's default.psm1 gets re-loaded
        # over the first, and the first's exports disappear from the
        # global table even though the first call site never asked for
        # a refresh. Match by absolute path so dev-time edits still
        # re-import (operator hits Ctrl+C, makes a change, re-runs --
        # the file mtime change isn't checked here, but explicit
        # Remove-Module + re-Import-Extension still works).
        $absPath = [System.IO.Path]::GetFullPath($path)
        $existing = Get-Module | Where-Object {
            $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -eq $absPath)
        } | Select-Object -First 1
        if (-not $existing) {
            Import-Module -Name $path -Global -Force
        }
        # Post-load contract check: warn (don't throw) when the loaded
        # module is missing a verb declared in <Area>.contract.yml. A
        # stale or partial extension surfaces here, before the first
        # cycle step references it.
        $loaded = Get-Module | Where-Object {
            $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -eq $absPath)
        } | Select-Object -First 1
        if ($loaded) {
            $exportedNames = @($loaded.ExportedCommands.Keys)
            [void](Assert-ExtensionContractCoverage -Area $Area -ExtensionName $n -ExportedFunction $exportedNames)
        }
    }
    return $names
}

<#
.SYNOPSIS
    Resolves a YAML-friendly method name (e.g. 'GetPassword') to the
    PowerShell verb-noun command exported by an extension module
    (e.g. 'Get-Password'). Falls back to exact-match if the literal
    name is already exported.
.DESCRIPTION
    Sequence YAML uses CamelCase method names for readability
    (`${ext:authentication.GetPassword(...)}`), while the underlying
    functions follow PowerShell's hyphenated Verb-Noun convention. The
    translation inserts a single hyphen between the leading verb (e.g.
    'Get', 'New', 'Set') and the rest of the name. Throws if neither
    form resolves.

    Lookup is path-based, NOT module-name-based: two areas can ship a
    module with the same basename (authentication/default.psm1 +
    notification/default.psm1) and both will register under the same
    PowerShell module name 'default', confusing -Module filters. Match
    the loaded module by its absolute .psm1 path instead so the
    intended exports are always found.
.PARAMETER Area
    Extension area name (e.g. 'authentication', 'notification') --
    determines which area's directory the module path is resolved
    against.
.PARAMETER ExtensionName
    Module basename without .psm1 (typically 'default').
.PARAMETER Method
    Method name as written in the sequence YAML (CamelCase or
    Verb-Noun).
#>
function Resolve-ExtensionMethod {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$ExtensionName,
        [Parameter(Mandatory)][string]$Method
    )
    $dir     = Resolve-ExtensionAreaDir -Area $Area
    $modPath = [System.IO.Path]::GetFullPath((Join-Path $dir "$ExtensionName.psm1"))
    $mod = Get-Module | Where-Object {
        $_.Path -and ([System.IO.Path]::GetFullPath($_.Path) -eq $modPath)
    } | Select-Object -First 1
    if (-not $mod) {
        throw "Extension module not loaded for area '$Area' (looked for $modPath in Get-Module)."
    }
    $hyphenated = [regex]::Replace($Method, '^([A-Z][a-z]+)([A-Z])', '$1-$2')
    foreach ($candidate in @($Method, $hyphenated) | Select-Object -Unique) {
        if ($mod.ExportedCommands.ContainsKey($candidate)) {
            return $mod.ExportedCommands[$candidate]
        }
    }
    throw "Extension '$ExtensionName' (loaded from $modPath) does not export '$Method' (also tried '$hyphenated')."
}

<#
.SYNOPSIS
    Returns the names of every extension area present under test/extension/.
.DESCRIPTION
    Discovery primitive: an entry point that wants to load "every
    declared extension" (instead of hard-coding a list of areas in
    its own bootstrap) calls Get-ExtensionAreaName + Import-Extension
    in a loop. An area is recognized by having a `<area>.config.yml`
    file at test/extension/<area>/<area>.config.yml -- bare
    directories without that file are ignored so a half-staged
    contribution can sit on disk without affecting the runtime.

    Pair with Import-ConfiguredExtension when the caller just wants
    "load all of them" semantics.
.OUTPUTS
    [string[]] area names sorted alphabetically.
#>
function Get-ExtensionAreaName {
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param()
    if (-not (Test-Path -LiteralPath $script:ExtensionDir)) { return @() }
    $names = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $script:ExtensionDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $cfg = Join-Path $dir.FullName "$($dir.Name).config.yml"
        if (Test-Path -LiteralPath $cfg) { $names += $dir.Name }
    }
    return $names
}

<#
.SYNOPSIS
    Imports every extension area that exposes a <area>.config.yml.
.DESCRIPTION
    Single-call bootstrap for entry points that want all configured
    extensions loaded with -Global semantics. Each area's failure is
    caught locally and surfaced as a Write-Warning so a single broken
    area can't take the entire cycle down.

    The function returns a list of (area, names) tuples for the
    cycle-start manifest / capability-matrix dump; an autonomous tool
    can introspect what loaded and what didn't through the warnings
    plus the returned summary.
.OUTPUTS
    Array of [PSCustomObject]@{ Area; Loaded; Error }.
#>
function Import-ConfiguredExtension {
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Module-import side effects only; caller is the bootstrap path.')]
    param()
    $rows = @()
    foreach ($area in (Get-ExtensionAreaName)) {
        $loaded = @()
        $err = $null
        try {
            $loaded = @(Import-Extension -Area $area)
        } catch {
            $err = $_.Exception.Message
            Write-Warning "Import-ConfiguredExtension: area '$area' failed to load: $err"
        }
        $rows += [PSCustomObject]@{
            Area   = $area
            Loaded = $loaded
            Error  = $err
        }
    }
    return $rows
}

<#
.SYNOPSIS
    Every address this host can currently reach the extension area $HostType
    at, nearest first. The list may be empty and is never $null.
.DESCRIPTION
    The one call client code makes to answer "where is the stash service /
    pool-control service?" without naming an address itself.

    A host that NEEDS one of these services usually does not run it: the
    service lives on another host, often another subnet, at an address DHCP is
    free to change. Nothing in this host's config knows where it is, so the
    alternative is a hard-coded literal that is correct only until the service
    moves -- and then a cycle spends its whole timeout budget on a machine that
    no longer exists.

    Sources, in the order they are returned:

      1. An operator pin in $env:YURUNA_EXTENSION_HOST_<AREA> (the area
         upper-cased with every non-alphanumeric replaced by '_', e.g.
         YURUNA_EXTENSION_HOST_STASH_SERVICE). An operator who states an
         address means it, so it is tried before anything discovered.
      2. The live host-contract lookup (Get-VMIp) for the VM that serves the
         area on THIS host -- nearer than any remote answer, and current
         across rebuilds in a way a literal never is.
      3. The pool's own record (the pool-aggregator-service's /api/v1/extension-hosts),
         which is where a service running on ANOTHER host is found. Since the
         aggregator lives in the caching-proxy-service VM, knowing the proxy address --
         which every host needs anyway, to reach the cache at all -- is enough
         to locate every other service the pool offers. A host with no caching
         proxy has no aggregator to ask and no pool: the lookup simply
         contributes nothing.

    A LIST rather than one answer, because the caller is the only one that can
    say which address is usable: it holds the probe (the stash pre-flight
    demands /healthz), it may prefer a particular subnet, and it usually has a
    site-specific last resort of its own to append. Every entry here is a HINT,
    never a promise -- prove one before committing a cycle to it.

    Addresses carrying whitespace or a quote are dropped: these end up composed
    into URLs, scp targets and single-quoted guest env lines, where such a value
    corrupts the command rather than failing it.

    Never throws. Each source is independent -- a pool that does not answer, a
    host contract without Get-VMIp, an extension area nobody serves -- and any
    of them coming up empty just shortens the list.

    PowerShell unrolls a single-element array to a scalar on the way out, and
    an empty one to nothing at all, so callers that count or index MUST wrap
    the call -- the same rule Get-ActiveExtensionName carries:

        $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service')
.PARAMETER HostType
    The KIND of service wanted, named by its extension area slug:
    'stash-service', 'pool-control-service'. Not the hypervisor host type
    Get-HostType returns ('host.windows.hyper-v') -- unrelated vocabulary.
.PARAMETER VMName
    VM to ask the host contract about. Defaults to "yuruna-<HostType>", the
    name the framework's own Start-*VM scripts create. Pass '' to skip the
    local lookup entirely (a caller that already did it).
.PARAMETER AggregatorBaseUrl
    Pool-aggregator service base URL. Defaults to the one derived from this host's
    caching-proxy service; pass it to query a specific collector.
.PARAMETER TimeoutSeconds
    Per-request timeout for the pool lookup. Short by default: this sits in
    front of a cycle, and a pool that does not answer promptly must not delay
    one.
.OUTPUTS
    [string[]] addresses, nearest first, de-duplicated. Possibly empty.
#>
function Get-ExtensionHostAddress {
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][Alias('Area')][string]$HostType,
        [AllowEmptyString()][string]$VMName,
        [string]$AggregatorBaseUrl,
        [int]$TimeoutSeconds = 5
    )

    $candidates = [System.Collections.Generic.List[hashtable]]::new()

    # 1. Operator pin.
    $envName = 'YURUNA_EXTENSION_HOST_' + ($HostType.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
    $pinned  = [System.Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($pinned)) {
        [void]$candidates.Add(@{ Address = $pinned; Source = "`$env:$envName" })
    }

    # 2. A VM on this host serving the area. Get-VMIp arrives with the host
    #    driver (Initialize-YurunaHost); a client that never loaded one simply
    #    has no local source, which is not an error.
    $localVm = if ($PSBoundParameters.ContainsKey('VMName')) { $VMName } else { "yuruna-$HostType" }
    if (-not [string]::IsNullOrWhiteSpace($localVm)) {
        if (Get-Command Get-VMIp -ErrorAction SilentlyContinue) {
            try {
                $vmIp = [string](Get-VMIp -VMName $localVm)
                if (-not [string]::IsNullOrWhiteSpace($vmIp)) {
                    [void]$candidates.Add(@{ Address = $vmIp; Source = "VM '$localVm' on this host" })
                }
            } catch {
                Write-Verbose "Get-ExtensionHostAddress: Get-VMIp '$localVm' failed: $($_.Exception.Message)"
            }
        } else {
            Write-Verbose "Get-ExtensionHostAddress: no Get-VMIp in scope; skipping the local lookup for '$localVm'."
        }
    }

    # 3. The pool's record. Import-Extension is the framework path -- it honours
    #    <area>.config.yml, so a site that swapped the reader gets its own --
    #    but it parses YAML, which a client script running outside a cycle may
    #    not have the parser loaded for; hence the module file as fallback
    #    rather than as the first choice.
    if (-not (Get-Command Get-PoolExtensionHost -ErrorAction SilentlyContinue)) {
        try { $null = Import-Extension -Area 'pool-aggregator-service' }
        catch {
            Write-Verbose "Get-ExtensionHostAddress: Import-Extension pool-aggregator-service failed: $($_.Exception.Message)"
            $readerPath = Join-Path $script:ExtensionDir 'pool-aggregator-service' -AdditionalChildPath 'default.psm1'
            if (Test-Path -LiteralPath $readerPath) {
                try { Import-Module -Name $readerPath -Global -Force -DisableNameChecking -Verbose:$false }
                catch { Write-Verbose "Get-ExtensionHostAddress: loading $readerPath failed: $($_.Exception.Message)" }
            }
        }
    }
    if (Get-Command Get-PoolExtensionHost -ErrorAction SilentlyContinue) {
        $lookup = @{ Area = $HostType; TimeoutSeconds = $TimeoutSeconds }
        if (-not [string]::IsNullOrWhiteSpace($AggregatorBaseUrl)) { $lookup['BaseUrl'] = $AggregatorBaseUrl }
        try {
            $fromPool = [string](Get-PoolExtensionHost @lookup)
            if (-not [string]::IsNullOrWhiteSpace($fromPool)) {
                [void]$candidates.Add(@{ Address = $fromPool; Source = 'the pool' })
            }
        } catch {
            Write-Verbose "Get-ExtensionHostAddress: the pool lookup for '$HostType' failed: $($_.Exception.Message)"
        }
    } else {
        Write-Verbose "Get-ExtensionHostAddress: no pool-aggregator-service reader available; the pool contributes nothing."
    }

    $addresses = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        $address = ([string]$candidate.Address).Trim()
        if (-not $address) { continue }
        if ($address -match "['`"\s]") {
            Write-Verbose "Get-ExtensionHostAddress: dropping '$address' ($($candidate.Source)) -- an address carrying quotes or whitespace cannot be composed into a URL or an scp target."
            continue
        }
        if (-not $seen.Add($address)) { continue }
        Write-Verbose "Get-ExtensionHostAddress: '$HostType' -> $address (from $($candidate.Source))."
        [void]$addresses.Add($address)
    }
    return [string[]]$addresses.ToArray()
}

Export-ModuleMember -Function Resolve-ExtensionAreaDir, Read-ExtensionConfig, Get-ActiveExtensionName, Import-Extension, Resolve-ExtensionMethod, Assert-ExtensionContractCoverage, Get-ExtensionAreaName, Import-ConfiguredExtension, Get-ExtensionHostAddress
