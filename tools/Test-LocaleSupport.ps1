<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42dda1b3-cdbb-4dbc-89d4-7c6e5d485304
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization locale support release
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Verify the published support declaration against complete compiled locale artifacts.
.DESCRIPTION
    The documentation declares the manifest as its support authority. Every
    active locale must have complete compiled browser, PowerShell and Go data
    bound to current inputs. Release mode also pins both staged trees and
    refuses unstaged changes before and after the check. This proves artifact
    consistency; translator and reviewer approval remains a separate gate.
.PARAMETER Root
    Framework checkout or private-stripped staging tree.
.PARAMETER ProjectRoot
    Companion checkout; required when pinning the staged pair.
.PARAMETER FrameworkTreeHash
    Expected framework index tree in release mode.
.PARAMETER ProjectTreeHash
    Expected companion index tree in release mode.
.PARAMETER Quiet
    Print only failure details and the result summary.
#>
[CmdletBinding()]
param([string]$Root = (Split-Path -Parent $PSScriptRoot), [string]$ProjectRoot,
    [string]$FrameworkTreeHash, [string]$ProjectTreeHash, [switch]$Quiet)
$ErrorActionPreference = 'Stop'

# --- REGION: Resolve-LocaleSupportFile
function Resolve-LocaleSupportFile {
    param([string]$Root, [string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '(^[\\/]|\\|(^|/)\.\.(/|$)|:)') { throw 'Locale support input requires a confined relative path.' }
    $path = Join-Path $Root $Relative
    $cursor = [IO.Path]::GetFullPath($path)
    while ($cursor) {
        $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($entry -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked locale support input: $path" }
        $cursor = Split-Path -Parent $cursor
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing locale support input: $Relative" }
    return $path
}

# --- REGION: Assert-LocaleSupportTree
function Assert-LocaleSupportTree {
    param([string]$Root, [string]$Expected)
    if (-not $Root -or $Expected -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') { throw 'Both exact staged tree identities and repository roots are required.' }
    $tree = & git -C $Root write-tree 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]$tree -cne $Expected) { throw "Locale support staged tree identity differs: $Root" }
    $changes = & git -C $Root diff --name-only -- 2>&1
    if ($LASTEXITCODE -ne 0 -or @($changes).Count) { throw "Locale support candidate has unstaged changes: $Root" }
    $untracked = & git -C $Root ls-files --others --exclude-standard 2>&1
    if ($LASTEXITCODE -ne 0 -or @($untracked).Count) { throw "Locale support candidate has untracked inputs: $Root" }
}

# --- REGION: Assert-LocaleSupportCandidate
function Assert-LocaleSupportCandidate {
    param([string]$Root, [string]$ProjectRoot, [string]$FrameworkTreeHash, [string]$ProjectTreeHash)
    $pinned = [bool]($FrameworkTreeHash -or $ProjectTreeHash)
    if ($pinned) {
        Assert-LocaleSupportTree -Root $Root -Expected $FrameworkTreeHash
        Assert-LocaleSupportTree -Root $ProjectRoot -Expected $ProjectTreeHash
    }
    $manifestPath = Resolve-LocaleSupportFile $Root 'globalization/locale-manifest.json'
    $setPath = Resolve-LocaleSupportFile $Root 'globalization/manifests/catalog-set.json'
    $documentation = [IO.File]::ReadAllText((Resolve-LocaleSupportFile $Root 'docs/globalization.md'))
    $declarations = [regex]::Matches($documentation, '<!-- yuruna-locale-support (\{[^\r\n]*\}) -->')
    if ($declarations.Count -ne 1) { throw 'Documentation requires exactly one manifest-authoritative support declaration.' }
    $declaration = ConvertFrom-Json $declarations[0].Groups[1].Value -AsHashtable
    if ($declaration.manifest -cne 'globalization/locale-manifest.json' -or $declaration.predicate -cne 'status=supported' -or
        $declaration.catalogSet -cne 'globalization/manifests/catalog-set.json' -or $declaration.Count -ne 3) { throw 'Documentation support declaration differs from the runtime authority.' }
    $manifest = ConvertFrom-Json ([IO.File]::ReadAllText($manifestPath)) -AsHashtable
    $set = ConvertFrom-Json ([IO.File]::ReadAllText($setPath)) -AsHashtable
    $manifestHash = (Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($manifest.schema -cne 'yuruna.locale-manifest/v1' -or $set.schema -cne 'yuruna.catalog-set/v1' -or
        $set.localeManifest -cne $manifestHash -or $set.inputs['globalization/locale-manifest.json'] -cne $manifestHash -or
        $manifest.locales[$manifest.default].status -cne 'supported') { throw 'Compiled support manifest identity or default locale differs.' }
    foreach ($mapping in @($set.inputs, $set.artifacts)) {
        if (-not $mapping -or -not $mapping.Count) { throw 'Compiled support inputs or artifacts are absent.' }
        foreach ($relative in $mapping.Keys) {
            $path = Resolve-LocaleSupportFile $Root $relative
            if ($mapping[$relative] -cnotmatch '^[0-9a-f]{64}$' -or
                (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $mapping[$relative]) { throw "Compiled support hash differs: $relative" }
        }
    }
    $domains = @{}
    foreach ($relative in $set.inputs.Keys) {
        if ($relative -clike ('globalization/catalogs/' + $manifest.default + '/*.json')) {
            $catalog = ConvertFrom-Json ([IO.File]::ReadAllText((Resolve-LocaleSupportFile $Root $relative))) -AsHashtable
            if ($catalog.locale -cne $manifest.default -or $domains.ContainsKey($catalog.domain)) { throw 'Default catalog domain identity is invalid.' }
            $domains[$catalog.domain] = $catalog
        }
    }
    if (-not $domains.Count) { throw 'Default locale has no compiled catalog domains.' }
    foreach ($locale in $manifest.locales.Keys) {
        $entry = $manifest.locales[$locale]
        if ($entry.status -cnotin @('supported', 'pseudo')) { continue }
        if ([string]::IsNullOrWhiteSpace($entry.pluralRule)) { throw "Active locale has no pinned plural rule: $locale" }
        foreach ($domain in $domains.Keys) {
            foreach ($relative in @("globalization/generated/browser/$locale.$domain.js", "globalization/generated/powershell/$locale.$domain.psd1",
                    ('globalization/generated/go/catalog/' + ($locale -replace '[^A-Za-z0-9]', '') + "_$domain.go"))) {
                if (-not $set.artifacts.ContainsKey($relative)) { throw "Active locale has no compiled artifact: $relative" }
            }
            if ($entry.status -ceq 'supported' -and $locale -cne $manifest.default) {
                $relative = "globalization/catalogs/$locale/$domain.json"
                if (-not $set.inputs.ContainsKey($relative)) { throw "Supported locale has no complete source catalog: $relative" }
                $translated = ConvertFrom-Json ([IO.File]::ReadAllText((Resolve-LocaleSupportFile $Root $relative))) -AsHashtable
                foreach ($key in $domains[$domain].messages.Keys) {
                    if ($domains[$domain].messages[$key].lifecycle -ceq 'tombstone') { continue }
                    $sourceHash = $set.messageSources[$key].sourceHash
                    if (-not $translated.messages.ContainsKey($key) -or $sourceHash -cnotmatch '^[0-9a-f]{64}$' -or
                        $translated.messages[$key].sourceHash -cne $sourceHash -or $set.translations["$locale/$key"].sourceHash -cne $sourceHash) {
                        throw "Supported locale is incomplete or source-stale: $locale/$key"
                    }
                }
            }
        }
    }
    if ($pinned) {
        Assert-LocaleSupportTree -Root $Root -Expected $FrameworkTreeHash
        Assert-LocaleSupportTree -Root $ProjectRoot -Expected $ProjectTreeHash
    }
    return @{ supported = @($manifest.locales.Keys | Where-Object { $manifest.locales[$_].status -ceq 'supported' } | Sort-Object)
        localeManifestSha256 = $manifestHash; catalogSetSha256 = (Get-FileHash $setPath -Algorithm SHA256).Hash.ToLowerInvariant()
        frameworkTree = $FrameworkTreeHash; projectTree = $ProjectTreeHash }
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    $result = Assert-LocaleSupportCandidate -Root $Root -ProjectRoot $ProjectRoot -FrameworkTreeHash $FrameworkTreeHash -ProjectTreeHash $ProjectTreeHash
    if (-not $Quiet) { $result | ConvertTo-Json -Depth 4 | Write-Output }
    Write-Output ('Locale support matches its compiled candidate: ' + ($result.supported -join ', '))
    exit 0
} catch { Write-Error $_ -ErrorAction Continue; exit 1 }
