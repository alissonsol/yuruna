<#PSScriptInfo
.VERSION 2026.05.29
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
    module with the same basename (auth/default.psm1 +
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
    in a loop. An area is recognised by having a `<area>.config.yml`
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

Export-ModuleMember -Function Resolve-ExtensionAreaDir, Read-ExtensionConfig, Get-ActiveExtensionName, Import-Extension, Resolve-ExtensionMethod, Assert-ExtensionContractCoverage, Get-ExtensionAreaName, Import-ConfiguredExtension
