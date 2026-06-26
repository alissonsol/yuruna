<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42c2d3e4-f5a6-4b78-9c01-2d3e4f5a6b7c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin intent git yaml
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

# Shared helpers for the pool admin CLI (New-Pool / Add-HostToPool / ... /
# Test-PoolIntent). The operator authors the pool intent here; the runners only
# PULL it (read-only over HTTP from the proxy). The admin therefore clones from a
# WRITABLE url/path (the bare repo's local path on the proxy, file://, or a
# pre-authenticated remote -- the bounded git child runs with
# GIT_TERMINAL_PROMPT=0 so it never blocks on a credential prompt). Every change
# is schema-validated BEFORE commit so a malformed intent never reaches the store
# that the whole pool pulls. Git calls reuse Test.PoolSync's bounded, prompt-proof
# Invoke-PoolSyncGit.

$script:PoolAdminGitTimeoutSec = 60

# Resolve-YurunaPoolSchemaPath maps a schema file name to its path under
# test/schemas/ (this module lives in test/modules/).
function Resolve-YurunaPoolSchemaPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'schemas' $Name))
}

# Test-YurunaPoolDocValid validates an in-memory doc (IDictionary) against a
# test/schemas/*.yml JSON-Schema via Test-Json. Returns @{ Ok; Errors }. When
# Test-Json is unavailable it degrades to an Ok parse-only pass (the doc already
# parsed) so the CLI still works on older PowerShell, just without enforcement.
function Test-YurunaPoolDocValid {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$SchemaName
    )
    $schemaPath = Resolve-YurunaPoolSchemaPath -Name $SchemaName
    if (-not (Test-Path -LiteralPath $schemaPath)) { return @{ Ok = $false; Errors = @("schema not found: $schemaPath") } }
    if (-not (Get-Command Test-Json -ErrorAction SilentlyContinue)) { return @{ Ok = $true; Errors = @() } }
    try {
        $schemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 20
        $docJson    = $Doc | ConvertTo-Json -Depth 20
        $je = $null
        $ok = Test-Json -Json $docJson -Schema $schemaJson -ErrorVariable je -ErrorAction SilentlyContinue
        if ($ok) { return @{ Ok = $true; Errors = @() } }
        return @{ Ok = $false; Errors = @($je | ForEach-Object { [string]$_ }) }
    } catch {
        return @{ Ok = $false; Errors = @($_.Exception.Message) }
    }
}

# Open-YurunaPoolIntent ensures a working clone of the WRITABLE intent repo at
# $IntentDir: clone when absent, else fetch + reset --hard origin/HEAD so the edit
# is based on the latest remote state. Bounded + prompt-proof. Returns @{ Ok; Error }.
function Open-YurunaPoolIntent {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IntentGitUrl,
        [Parameter(Mandatory)][string]$IntentDir
    )
    if (-not (Get-Command Invoke-PoolSyncGit -ErrorAction SilentlyContinue)) {
        return @{ Ok = $false; Error = 'Test.PoolSync (Invoke-PoolSyncGit) not loaded.' }
    }
    if (-not $PSCmdlet.ShouldProcess($IntentDir, "Open pool intent clone of $IntentGitUrl")) { return @{ Ok = $true; Error = '' } }
    $gitDir = Join-Path $IntentDir '.git'
    if (Test-Path -LiteralPath $gitDir) {
        $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'fetch', '--quiet', 'origin') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
        if ($rc -ne 0) { return @{ Ok = $false; Error = "git fetch failed (exit $rc) from $IntentGitUrl" } }
        # Reset to FETCH_HEAD (origin's default branch) rather than the origin/HEAD
        # symbolic ref, which a plain clone does not always populate.
        $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'reset', '--hard', '--quiet', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
        if ($rc -ne 0) { return @{ Ok = $false; Error = "git reset failed (exit $rc)" } }
        return @{ Ok = $true; Error = '' }
    }
    $parent = Split-Path -Parent $IntentDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $rc = Invoke-PoolSyncGit -ArgumentList @('clone', '--quiet', $IntentGitUrl, $IntentDir) -TimeoutSeconds $script:PoolAdminGitTimeoutSec
    if ($rc -ne 0) { return @{ Ok = $false; Error = "git clone failed (exit $rc) from $IntentGitUrl" } }
    return @{ Ok = $true; Error = '' }
}

# Read-YurunaPoolsDoc parses <IntentDir>/pools.yml into an ordered dictionary, or
# returns a fresh empty doc ({schemaVersion:1, pools:[]}) when the file is absent.
function Read-YurunaPoolsDoc {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$IntentDir)
    $path = Join-Path $IntentDir 'pools.yml'
    if (-not (Test-Path -LiteralPath $path)) { return ([ordered]@{ schemaVersion = 1; pools = @() }) }
    $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered
    if (-not ($doc -is [System.Collections.IDictionary])) { return ([ordered]@{ schemaVersion = 1; pools = @() }) }
    if (-not $doc.Contains('schemaVersion')) { $doc['schemaVersion'] = 1 }
    if (-not $doc.Contains('pools') -or $null -eq $doc['pools']) { $doc['pools'] = @() }
    return $doc
}

# Save-YurunaPoolDoc validates $Doc against $SchemaName then writes it to
# <IntentDir>/<RelPath> as BOM-less UTF-8 (ConvertTo-Yaml can emit a BOM; the
# bare-repo + git consumers must stay BOM-free). Returns @{ Ok; Error }. Does NOT
# commit -- Publish-YurunaPoolIntent does.
function Save-YurunaPoolDoc {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IntentDir,
        [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$SchemaName
    )
    $v = Test-YurunaPoolDocValid -Doc $Doc -SchemaName $SchemaName
    if (-not $v.Ok) { return @{ Ok = $false; Error = "schema validation failed against $SchemaName -- $($v.Errors -join '; ')" } }
    $path = Join-Path $IntentDir $RelPath
    if (-not $PSCmdlet.ShouldProcess($path, 'Write pool intent file')) { return @{ Ok = $true; Error = '' } }
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $yaml = ConvertTo-Yaml $Doc
        [System.IO.File]::WriteAllText($path, $yaml, [System.Text.UTF8Encoding]::new($false))
        return @{ Ok = $true; Error = '' }
    } catch { return @{ Ok = $false; Error = $_.Exception.Message } }
}

# Publish-YurunaPoolIntent commits everything under $IntentDir and pushes to the
# writable origin (bounded). A commit identity is passed inline so a fresh proxy
# clone with no configured user.name/email still commits. Returns
# @{ Ok; Pushed; Error }: Ok=committed locally, Pushed=reached the remote (a
# read-only/offline remote leaves Pushed=$false with a hint, not a hard failure).
function Publish-YurunaPoolIntent {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IntentDir,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $PSCmdlet.ShouldProcess($IntentDir, "Commit + push pool intent: $Message")) { return @{ Ok = $true; Pushed = $true; Error = '' } }
    $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'add', '-A') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
    if ($rc -ne 0) { return @{ Ok = $false; Pushed = $false; Error = "git add failed (exit $rc)" } }
    # Nothing staged -> no-op success (idempotent re-run).
    $rcDiff = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'diff', '--cached', '--quiet') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
    if ($rcDiff -eq 0) { return @{ Ok = $true; Pushed = $true; Error = 'no changes' } }
    $rc = Invoke-PoolSyncGit -ArgumentList @(
        '-C', $IntentDir,
        '-c', 'user.name=yuruna-pool-admin', '-c', 'user.email=pool-admin@yuruna.local',
        'commit', '--quiet', '-m', $Message) -TimeoutSeconds $script:PoolAdminGitTimeoutSec
    if ($rc -ne 0) { return @{ Ok = $false; Pushed = $false; Error = "git commit failed (exit $rc)" } }
    # Push to origin's 'main' explicitly (HEAD:main). The yuruna intent repo is
    # always 'main' (the proxy seeds it with --initial-branch=main); pinning the
    # destination branch makes the push deterministic even when a fresh clone of
    # an empty repo left the local branch named 'master', so a later clone reading
    # the bare repo's HEAD (main) always sees the pushed commit.
    $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'push', '--quiet', 'origin', 'HEAD:main') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
    if ($rc -ne 0) {
        return @{ Ok = $true; Pushed = $false; Error = "committed locally but push failed (exit $rc) -- push from a writable location (e.g. on the proxy: a file:// or local path to the bare repo)" }
    }
    return @{ Ok = $true; Pushed = $true; Error = '' }
}

# Resolve-YurunaPoolAdminTarget fills the WRITABLE intent url + the admin working
# clone dir with sensible defaults: url falls back to pool.intentGitUrl from
# test.config.yml; the clone dir defaults to <runtime>/pool-intent-admin (kept
# separate from the runner's read-only pool-intent clone so admin edits never race
# the runner's reset --hard).
function Resolve-YurunaPoolAdminTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$IntentGitUrl, [string]$IntentDir)
    if ([string]::IsNullOrWhiteSpace($IntentGitUrl) -and (Get-Command Get-YurunaPoolConfig -ErrorAction SilentlyContinue)) {
        $pc = Get-YurunaPoolConfig -IgnoreEnabled -WarningAction SilentlyContinue
        if ($pc) { $IntentGitUrl = $pc.IntentGitUrl }
    }
    if ([string]::IsNullOrWhiteSpace($IntentDir)) {
        $rt = if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) { Initialize-YurunaRuntimeDir }
              elseif ($env:YURUNA_RUNTIME_DIR) { $env:YURUNA_RUNTIME_DIR }
              else { [System.IO.Path]::GetTempPath() }
        $IntentDir = Join-Path $rt 'pool-intent-admin'
    }
    return @{ IntentGitUrl = $IntentGitUrl; IntentDir = $IntentDir }
}

# Get-YurunaPoolFromDoc returns the pool object with $PoolId from $Doc, or $null.
function Get-YurunaPoolFromDoc {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$PoolId
    )
    foreach ($p in @($Doc['pools'])) {
        if (($p -is [System.Collections.IDictionary]) -and ([string]$p['poolId'] -eq $PoolId)) { return $p }
    }
    return $null
}

Export-ModuleMember -Function `
    Resolve-YurunaPoolSchemaPath, Test-YurunaPoolDocValid, Open-YurunaPoolIntent, `
    Read-YurunaPoolsDoc, Save-YurunaPoolDoc, Publish-YurunaPoolIntent, Get-YurunaPoolFromDoc, `
    Resolve-YurunaPoolAdminTarget
