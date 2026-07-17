<#PSScriptInfo
.VERSION 2026.07.17
.GUID 426deb9b-03d2-46c7-b22f-02548f71a328
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension loader contract pester
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
    Pester coverage for Test.Extension.psm1: extension-area resolution, the
    mtime-keyed config cache, contract-coverage enforcement, the path-based
    (not name-based) module lookup, and the CamelCase -> Verb-Noun method
    resolution used by ${ext:...} sequence expansions.
.DESCRIPTION
    Most tests run against a synthetic extension tree built in a temp directory
    and pointed at by redirecting the module's $script:ExtensionDir, so the
    loader is exercised end to end (including Import-Module -Global) without
    importing the repo's real extensions or writing anything into the repo tree.
    The discovery surface (Get-ExtensionAreaName) is additionally checked
    read-only against the real test/extension/ tree.

    Covered edges: an area directory that does not exist, a directory with no
    config, an `active:` list that is empty, an active name with no .psm1 on
    disk, -RequireSingle against a multi-extension area, the single-entry
    pipeline unroll that forces callers to write @(Get-ActiveExtensionName ...),
    the "already loaded, do not re-import" guard that stops one area's
    default.psm1 from evicting another's, and a broken area not taking the whole
    Import-ConfiguredExtension bootstrap down with it.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.Extension.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module powershell-yaml -Force -ErrorAction Stop
Import-Module (Join-Path $here 'Test.Extension.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures and helpers at FILE scope, above the first Describe: a Describe body
# runs during discovery and its variables/functions are discarded before any It
# executes. The temp extension tree is a side effect, so it is built in
# BeforeAll -- a file-scope temp dir would be created and deleted during
# discovery, leaving the Its probing a path that no longer exists.

function Use-ExtensionDir {
    <#
    .SYNOPSIS
        Point the loader at an extension root. The module resolves its root
        from $PSScriptRoot at import, so redirecting the module-scope variable
        is the only way to exercise the loader against a synthetic tree.
    #>
    [CmdletBinding()] [OutputType([void])] param([Parameter(Mandatory)][string]$Path)
    & (Get-Module Test.Extension) { param($p) $script:ExtensionDir = $p } $Path
}

function Get-ExtensionDirInUse {
    <#
    .SYNOPSIS
        Read back the loader's current extension root.
    #>
    [CmdletBinding()] [OutputType([string])] param()
    return (& (Get-Module Test.Extension) { $script:ExtensionDir })
}

function New-ExtensionArea {
    <#
    .SYNOPSIS
        Write a synthetic extension area: <root>/<Area>/<Area>.config.yml plus
        optional contract and module files.
    .PARAMETER ActiveName
        Names for the config's `active:` list. Pass @() for an empty list.
    .PARAMETER ModuleName
        Module basenames to actually create on disk. Omit one that is in
        ActiveName to model a config that points at a missing .psm1.
    .PARAMETER RequiredFunction
        Contract verbs. Omit entirely to write no contract file at all.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writing into a temp dir owned by this suite.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Area,
        [AllowEmptyCollection()][string[]]$ActiveName = @(),
        [AllowEmptyCollection()][string[]]$ModuleName = @(),
        [string[]]$RequiredFunction,
        [switch]$NoConfig,
        [switch]$EmptyContract
    )
    $dir = Join-Path $Root $Area
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    if (-not $NoConfig) {
        $lines = if ($ActiveName.Count -eq 0) { @('active: []') } else { @('active:') + ($ActiveName | ForEach-Object { "  - $_" }) }
        Set-Content -LiteralPath (Join-Path $dir "$Area.config.yml") -Value ($lines -join "`n")
    }
    if ($EmptyContract) {
        Set-Content -LiteralPath (Join-Path $dir "$Area.contract.yml") -Value "area: $Area"
    } elseif ($PSBoundParameters.ContainsKey('RequiredFunction')) {
        $lines = @("area: $Area", 'requiredFunction:') + ($RequiredFunction | ForEach-Object { "  - $_" })
        Set-Content -LiteralPath (Join-Path $dir "$Area.contract.yml") -Value ($lines -join "`n")
    }
    foreach ($m in $ModuleName) {
        # Each synthetic module exports one Get-<Module>Thing verb so the
        # contract / method-resolution tests have something real to find.
        $body = @(
            "function Get-$($m)Thing { param([string]`$Value) return `"$m`:`$Value`" }"
            "Export-ModuleMember -Function Get-$($m)Thing"
        ) -join "`n"
        Set-Content -LiteralPath (Join-Path $dir "$m.psm1") -Value $body
    }
    return $dir
}

BeforeAll {
    $realExtensionDir = Get-ExtensionDirInUse
    if (-not $realExtensionDir) {
        throw 'Test.Extension exposes no $script:ExtensionDir to redirect; the loader cannot be pointed at a synthetic tree.'
    }
    $extRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ext-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extRoot -Force | Out-Null

    # yzsolo    : healthy single-extension area, contract fully covered.
    # yzpartial : contract declares two verbs, the module exports one -> warns.
    # yznocon   : no contract file at all -> coverage check is a no-op.
    # yzblank   : contract file with no requiredFunction entries.
    # yzempty   : `active: []`.
    # yzghost   : active name whose .psm1 is not on disk.
    # yzmulti   : two active extensions, both present.
    # yzbare    : a directory with no config at all (half-staged contribution).
    $null = New-ExtensionArea -Root $extRoot -Area 'yzsolo'    -ActiveName @('yzsolo1') -ModuleName @('yzsolo1') -RequiredFunction @('Get-yzsolo1Thing')
    $null = New-ExtensionArea -Root $extRoot -Area 'yzpartial' -ActiveName @('yzpart1') -ModuleName @('yzpart1') -RequiredFunction @('Get-yzpart1Thing', 'Set-yzpart1Thing')
    $null = New-ExtensionArea -Root $extRoot -Area 'yznocon'   -ActiveName @('yznocon1') -ModuleName @('yznocon1')
    $null = New-ExtensionArea -Root $extRoot -Area 'yzblank'   -ActiveName @('yzblank1') -ModuleName @('yzblank1') -EmptyContract
    $null = New-ExtensionArea -Root $extRoot -Area 'yzempty'   -ActiveName @()
    $null = New-ExtensionArea -Root $extRoot -Area 'yzghost'   -ActiveName @('yzghost1')
    $null = New-ExtensionArea -Root $extRoot -Area 'yzmulti'   -ActiveName @('yzmulti1', 'yzmulti2') -ModuleName @('yzmulti1', 'yzmulti2')
    $null = New-ExtensionArea -Root $extRoot -Area 'yzbare'    -NoConfig

    Use-ExtensionDir -Path $extRoot
}

AfterAll {
    if ($realExtensionDir) { Use-ExtensionDir -Path $realExtensionDir }
    foreach ($m in @('yzsolo1', 'yzpart1', 'yznocon1', 'yzblank1', 'yzmulti1', 'yzmulti2')) {
        Remove-Module -Name $m -Force -ErrorAction SilentlyContinue
    }
    if ($extRoot -and (Test-Path -LiteralPath $extRoot)) {
        Remove-Item -LiteralPath $extRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-ExtensionAreaDir' {
    It 'resolves an area to its directory' {
        Assert-Equal -Expected (Join-Path $extRoot 'yzsolo') -Actual (Resolve-ExtensionAreaDir -Area 'yzsolo')
    }
    It 'throws for an area that is not on disk, naming the path it looked at' {
        # No alias map: the area name IS the directory basename, so a typo has
        # to surface here rather than resolve to something else.
        $msg = $null
        try { $null = Resolve-ExtensionAreaDir -Area 'yzsolo-typo' } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'Extension area directory not found') "expected a not-found throw, got [$msg]"
        Assert-True ($msg -match 'yzsolo-typo') 'the message must name the directory it tried'
    }
}

Describe 'Read-ExtensionConfig' {
    It 'reads the active list for an area' {
        $cfg = Read-ExtensionConfig -Area 'yzmulti'
        Assert-Equal -Expected 'yzmulti1,yzmulti2' -Actual (@($cfg.active) -join ',')
    }
    It 'throws when the area directory has no config file' {
        # A half-staged contribution (bare directory) must be a hard error when
        # asked for by name, even though discovery ignores it.
        $msg = $null
        try { $null = Read-ExtensionConfig -Area 'yzbare' } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'yzbare\.config\.yml missing') "expected a missing-config throw, got [$msg]"
    }
    It 'throws when the config declares no active entries' {
        $msg = $null
        try { $null = Read-ExtensionConfig -Area 'yzempty' } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match "has no 'active' entries") "expected an empty-active throw, got [$msg]"
    }
    It 'serves the parsed config from the cache while the file is unchanged' {
        $a = Read-ExtensionConfig -Area 'yzsolo'
        $b = Read-ExtensionConfig -Area 'yzsolo'
        Assert-True ([object]::ReferenceEquals($a, $b)) 'a second read must not re-parse the YAML'
    }
    It 'invalidates the cache when the config file is edited' {
        # The cache is mtime-keyed: an operator editing <area>.config.yml between
        # cycles must not keep getting the stale active list.
        $area = 'yzcache'
        $null = New-ExtensionArea -Root $extRoot -Area $area -ActiveName @('first') -ModuleName @()
        Assert-Equal -Expected 'first' -Actual (@(Get-ActiveExtensionName -Area $area) -join ',')

        $file = Join-Path (Join-Path $extRoot $area) "$area.config.yml"
        Set-Content -LiteralPath $file -Value "active:`n  - second`n  - third"
        (Get-Item -LiteralPath $file).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(2)

        Assert-Equal -Expected 'second,third' -Actual (@(Get-ActiveExtensionName -Area $area) -join ',') `
            -Because 'a newer mtime must evict the cached parse'
    }
}

Describe 'Get-ActiveExtensionName' {
    It 'returns the names in the order the config lists them' {
        Assert-Equal -Expected 'yzmulti1,yzmulti2' -Actual (@(Get-ActiveExtensionName -Area 'yzmulti') -join ',')
    }
    It 'unrolls a single-entry list to a bare string, which is why callers must wrap in @()' {
        # Documented trap: without the @() wrap, $names[0] on a single-entry
        # config is the first CHARACTER of the name, not the name.
        $raw = Get-ActiveExtensionName -Area 'yzsolo'
        Assert-True ($raw -is [string]) 'the pipeline unrolls the single-element array to a scalar'
        Assert-Equal -Expected 'y' -Actual ([string]$raw[0]) -Because 'indexing the unwrapped scalar yields a character'
        Assert-Equal -Expected 'yzsolo1' -Actual (@($raw)[0]) -Because 'the @() wrap is what makes [0] the name'
    }
}

Describe 'Get-ExtensionAreaName' {
    It 'lists only directories that carry a matching config file, sorted' {
        $areas = @(Get-ExtensionAreaName)
        foreach ($expected in @('yzblank', 'yzempty', 'yzghost', 'yzmulti', 'yznocon', 'yzpartial', 'yzsolo')) {
            Assert-True ($areas -contains $expected) "discovery missed the '$expected' area"
        }
        Assert-True ($areas -notcontains 'yzbare') 'a directory with no <area>.config.yml is not an area'
        Assert-Equal -Expected ((@($areas) | Sort-Object) -join ',') -Actual ($areas -join ',') -Because 'areas come back sorted'
    }
    It 'returns an empty list when the extension root does not exist' {
        $saved = Get-ExtensionDirInUse
        try {
            Use-ExtensionDir -Path (Join-Path $extRoot 'no-such-root')
            Assert-Equal -Expected 0 -Actual @(Get-ExtensionAreaName).Count -Because 'a missing root is empty, not an error'
        } finally { Use-ExtensionDir -Path $saved }
    }
    It 'discovers the areas that actually ship in test/extension/' {
        # Read-only against the real tree: no module is imported.
        $saved = Get-ExtensionDirInUse
        try {
            Use-ExtensionDir -Path $realExtensionDir
            $areas = @(Get-ExtensionAreaName)
            foreach ($shipped in @('authentication', 'notification')) {
                Assert-True ($areas -contains $shipped) "the shipped '$shipped' area must be discoverable"
            }
            Assert-True ($areas.Count -ge 2) 'the real tree must not come back empty'
        } finally { Use-ExtensionDir -Path $saved }
    }
}

Describe 'Assert-ExtensionContractCoverage' {
    It 'passes when the module exports every verb the contract requires' {
        $w = @()
        $ok = Assert-ExtensionContractCoverage -Area 'yzsolo' -ExtensionName 'yzsolo1' `
            -ExportedFunction @('Get-yzsolo1Thing') -WarningVariable w -WarningAction SilentlyContinue
        Assert-Equal -Expected $true -Actual $ok
        Assert-Equal -Expected 0 -Actual @($w).Count -Because 'full coverage is silent'
    }
    It 'matches verb names case-insensitively' {
        $ok = Assert-ExtensionContractCoverage -Area 'yzsolo' -ExtensionName 'yzsolo1' `
            -ExportedFunction @('get-YZSOLO1thing') -WarningAction SilentlyContinue
        Assert-Equal -Expected $true -Actual $ok -Because 'PowerShell command names are case-insensitive'
    }
    It 'warns once, naming every missing verb, and returns false' {
        # Policy is warn-and-continue: a stale extension must surface before the
        # first cycle step references it, without blocking unrelated cycles.
        $w = @()
        $ok = Assert-ExtensionContractCoverage -Area 'yzpartial' -ExtensionName 'yzpart1' `
            -ExportedFunction @('Get-yzpart1Thing') -WarningVariable w -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $ok
        Assert-Equal -Expected 1 -Actual @($w).Count -Because 'the operator sees the full delta in one line'
        Assert-True (@($w) -match 'Set-yzpart1Thing') 'the warning must name the missing verb'
        Assert-True (@($w) -match 'yzpartial')        'the warning must name the area'
        Assert-True (@($w) -match 'yzpart1')          'the warning must name the extension'
    }
    It 'reports every verb missing when the module exports nothing at all' {
        $w = @()
        $ok = Assert-ExtensionContractCoverage -Area 'yzpartial' -ExtensionName 'yzpart1' `
            -ExportedFunction @() -WarningVariable w -WarningAction SilentlyContinue
        Assert-Equal -Expected $false -Actual $ok
        Assert-True (@($w) -match 'missing 2 contract verb') "expected both verbs reported, got [$($w -join '')]"
    }
    It 'has nothing to enforce when the area declares no contract' {
        $ok = Assert-ExtensionContractCoverage -Area 'yznocon' -ExtensionName 'yznocon1' -ExportedFunction @() -WarningAction SilentlyContinue
        Assert-Equal -Expected $true -Actual $ok -Because 'no contract file means no contract'
    }
    It 'has nothing to enforce when the contract lists no required verbs' {
        $ok = Assert-ExtensionContractCoverage -Area 'yzblank' -ExtensionName 'yzblank1' -ExportedFunction @() -WarningAction SilentlyContinue
        Assert-Equal -Expected $true -Actual $ok
    }
}

Describe 'Import-Extension' {
    It 'imports the active module globally and returns its name' {
        $names = @(Import-Extension -Area 'yzsolo' -RequireSingle -WarningAction SilentlyContinue)
        Assert-Equal -Expected 'yzsolo1' -Actual ($names -join ',')
        $cmd = Get-Command Get-yzsolo1Thing -ErrorAction SilentlyContinue
        Assert-True ($null -ne $cmd) 'the extension is imported -Global, so its verbs are callable by the cycle step'
        Assert-Equal -Expected 'yzsolo1:x' -Actual (Get-yzsolo1Thing -Value 'x')
    }
    It 'imports every active module of a multi-extension area' {
        $names = @(Import-Extension -Area 'yzmulti' -WarningAction SilentlyContinue)
        Assert-Equal -Expected 'yzmulti1,yzmulti2' -Actual ($names -join ',')
        Assert-True ($null -ne (Get-Command Get-yzmulti1Thing -ErrorAction SilentlyContinue)) 'first module loaded'
        Assert-True ($null -ne (Get-Command Get-yzmulti2Thing -ErrorAction SilentlyContinue)) 'second module loaded'
    }
    It 'does not re-import a module already loaded from the same path' {
        # -Force on Import-Module evicts any module sharing the basename, so
        # re-importing one area's default.psm1 would drop another area's exports
        # from the global table. The path-equality guard is what prevents that.
        $null = Import-Extension -Area 'yzsolo' -WarningAction SilentlyContinue
        $mod = Get-Module -Name 'yzsolo1'
        Assert-True ($null -ne $mod) 'precondition: the module is loaded'
        & $mod { $script:ReimportCanary = 'survived' }

        $null = Import-Extension -Area 'yzsolo' -WarningAction SilentlyContinue

        $canary = & (Get-Module -Name 'yzsolo1') { $script:ReimportCanary }
        Assert-Equal -Expected 'survived' -Actual $canary -Because 'a second Import-Extension must not reload the module'
    }
    It 'warns but still loads when the extension misses a contract verb' {
        $w = @()
        $names = @(Import-Extension -Area 'yzpartial' -WarningVariable w -WarningAction SilentlyContinue)
        Assert-Equal -Expected 'yzpart1' -Actual ($names -join ',') -Because 'a partial extension still loads: warn, do not block'
        Assert-True (@($w) -match 'missing 1 contract verb') "expected a coverage warning, got [$($w -join '')]"
        Assert-True ($null -ne (Get-Command Get-yzpart1Thing -ErrorAction SilentlyContinue)) 'the verbs it does export are usable'
    }
    It 'refuses a multi-extension area under -RequireSingle' {
        # authentication is a one-provider area: two active extensions would mean
        # two answers to "what is the password", so this must not be papered over.
        $msg = $null
        try { $null = Import-Extension -Area 'yzmulti' -RequireSingle -WarningAction SilentlyContinue } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'requires exactly one active extension') "expected a RequireSingle throw, got [$msg]"
        Assert-True ($msg -match 'lists 2') 'the message must say how many it found'
    }
    It 'throws when the config names an extension with no module on disk' {
        $msg = $null
        try { $null = Import-Extension -Area 'yzghost' -WarningAction SilentlyContinue } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'Extension module not found') "expected a missing-module throw, got [$msg]"
        Assert-True ($msg -match 'yzghost1\.psm1') 'the message must name the .psm1 it looked for'
    }
}

Describe 'Resolve-ExtensionMethod' {
    BeforeAll { $null = Import-Extension -Area 'yzsolo' -WarningAction SilentlyContinue }

    It 'translates a CamelCase sequence method name to the exported Verb-Noun command' {
        # Sequence YAML writes ${ext:area.GetPassword(...)}; the module exports
        # Get-Password. The hyphen goes between the leading verb and the rest.
        $cmd = Resolve-ExtensionMethod -Area 'yzsolo' -ExtensionName 'yzsolo1' -Method 'GetYzsolo1Thing'
        Assert-Equal -Expected 'Get-yzsolo1Thing' -Actual $cmd.Name
        Assert-Equal -Expected 'yzsolo1:hello' -Actual (& $cmd -Value 'hello') -Because 'the resolved command must be invokable'
    }
    It 'accepts a name that is already in Verb-Noun form' {
        $cmd = Resolve-ExtensionMethod -Area 'yzsolo' -ExtensionName 'yzsolo1' -Method 'Get-yzsolo1Thing'
        Assert-Equal -Expected 'Get-yzsolo1Thing' -Actual $cmd.Name
    }
    It 'throws when neither the literal nor the hyphenated form is exported' {
        $msg = $null
        try { $null = Resolve-ExtensionMethod -Area 'yzsolo' -ExtensionName 'yzsolo1' -Method 'GetNothing' } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match "does not export 'GetNothing'") "expected an unknown-method throw, got [$msg]"
        Assert-True ($msg -match "also tried 'Get-Nothing'") 'the message must show the hyphenated form it tried'
    }
    It 'throws when the area module has not been imported' {
        $msg = $null
        try { $null = Resolve-ExtensionMethod -Area 'yzmulti' -ExtensionName 'never-loaded' -Method 'GetThing' } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -match 'Extension module not loaded') "expected a not-loaded throw, got [$msg]"
    }
    It 'finds the module by path, so two areas may ship the same module basename' {
        # Both areas' modules would register under the same PowerShell module
        # name; a -Module name filter would hand back the wrong one's exports.
        $shared = 'yzdup'
        $null = New-ExtensionArea -Root $extRoot -Area 'yzdupa' -ActiveName @($shared) -ModuleName @($shared)
        $null = New-ExtensionArea -Root $extRoot -Area 'yzdupb' -ActiveName @($shared) -ModuleName @($shared)
        try {
            $null = Import-Extension -Area 'yzdupa' -WarningAction SilentlyContinue
            $cmd = Resolve-ExtensionMethod -Area 'yzdupa' -ExtensionName $shared -Method 'GetYzdupThing'
            $expectedPath = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $extRoot 'yzdupa') "$shared.psm1"))
            Assert-Equal -Expected $expectedPath -Actual ([System.IO.Path]::GetFullPath($cmd.Module.Path)) `
                -Because 'the command must come from the area that was asked for'

            # The other area ships the same basename but was never imported: the
            # lookup must miss instead of silently answering with area A's module.
            $msg = $null
            try { $null = Resolve-ExtensionMethod -Area 'yzdupb' -ExtensionName $shared -Method 'GetYzdupThing' } catch { $msg = $_.Exception.Message }
            Assert-True ($msg -match 'Extension module not loaded') "a same-named module from another area must not satisfy the lookup: [$msg]"
        } finally {
            Remove-Module -Name $shared -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Import-ConfiguredExtension' {
    It 'loads every healthy area and reports the broken ones without aborting' {
        # Single-call bootstrap: one broken area must not take the cycle down,
        # and the caller must be able to see which ones failed.
        $rows = @(Import-ConfiguredExtension -WarningAction SilentlyContinue)
        Assert-Equal -Expected @(Get-ExtensionAreaName).Count -Actual $rows.Count -Because 'one row per discovered area'

        $byArea = @{}
        foreach ($r in $rows) { $byArea[$r.Area] = $r }

        Assert-Equal -Expected 'yzsolo1' -Actual (@($byArea['yzsolo'].Loaded) -join ',')
        Assert-Equal -Expected $null     -Actual $byArea['yzsolo'].Error -Because 'a healthy area reports no error'
        Assert-Equal -Expected 'yzmulti1,yzmulti2' -Actual (@($byArea['yzmulti'].Loaded) -join ',')

        Assert-True ($byArea['yzempty'].Error -match "has no 'active' entries") 'the empty-active area is reported, not thrown'
        Assert-Equal -Expected 0 -Actual @($byArea['yzempty'].Loaded).Count
        Assert-True ($byArea['yzghost'].Error -match 'Extension module not found') 'the missing-module area is reported'
        Assert-True ($null -ne (Get-Command Get-yzsolo1Thing -ErrorAction SilentlyContinue)) `
            'the healthy areas still loaded despite the broken ones'
    }
    It 'warns for each area it could not load' {
        $w = @()
        $null = Import-ConfiguredExtension -WarningVariable w -WarningAction SilentlyContinue
        Assert-True (@($w) -match "area 'yzempty' failed to load") 'a failed area is surfaced to the operator'
        Assert-True (@($w) -match "area 'yzghost' failed to load") 'every failed area gets its own warning'
    }
}
