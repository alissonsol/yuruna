<#PSScriptInfo
.VERSION 2026.07.14
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
# Idempotent network git ops (fetch/clone/push) retry within one overall
# wall-clock budget so a single transient blip (a proxy hiccup, a momentary
# DNS/TLS failure) does not abort the operator action or leave intent
# committed-but-unpushed. Kept short so an interactive admin command fails in
# bounded time rather than hanging.
$script:PoolAdminRetryBudgetSec = 90
$script:PoolAdminRetryDelaySec  = 3

<#
.SYNOPSIS
Runs an idempotent network git op (fetch/clone/push) via Invoke-PoolSyncGit, retrying within one
overall wall-clock budget. Returns the final git exit code (0 = success).
.DESCRIPTION
Only fetch/clone/push route through here -- they are safe to repeat and the failures worth
surviving are transient (network/proxy). Local ops (add/reset/commit/diff) are NOT retried: a
retry there cannot clear a real repo-state error and would only mask it. The budget is a deadline
(UtcNow-based), not an attempt count, so a slow attempt shrinks the remaining retries rather than
extending the total; each git child is additionally capped at the smaller of the per-call timeout
and the time left to the deadline. The shared Invoke-WithYurunaRetry policy is not reused here: it
classifies transient failures on command OUTPUT text, whereas Invoke-PoolSyncGit exposes only an
exit code, so that policy would degrade to retry-on-any-non-zero and carries no wall-clock budget.
#>
function Invoke-PoolAdminGitWithRetry {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Label,
        [int]$TimeoutSeconds = $script:PoolAdminGitTimeoutSec,
        [int]$BudgetSeconds  = $script:PoolAdminRetryBudgetSec,
        [int]$DelaySeconds   = $script:PoolAdminRetryDelaySec
    )
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(1, $BudgetSeconds))
    $rc = -1
    while ($true) {
        $remaining   = [int][Math]::Ceiling(($deadlineUtc - [DateTime]::UtcNow).TotalSeconds)
        if ($remaining -lt 1) { $remaining = 1 }
        $callTimeout = [Math]::Min($TimeoutSeconds, $remaining)
        $rc = Invoke-PoolSyncGit -ArgumentList $ArgumentList -TimeoutSeconds $callTimeout
        if ($rc -eq 0) { return 0 }
        # Stop if another attempt (plus its backoff) would not finish inside the budget.
        if ([DateTime]::UtcNow.AddSeconds($DelaySeconds) -ge $deadlineUtc) { break }
        Write-Verbose "${Label}: git exit ${rc}; retrying within the ${BudgetSeconds}s budget"
        Start-Sleep -Seconds $DelaySeconds
    }
    return $rc
}

<#
.SYNOPSIS
Maps a schema file name to its path under test/schemas/ (this module lives in test/modules/).
#>
function Resolve-YurunaPoolSchemaPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return (Join-Path (Split-Path -Parent $PSScriptRoot) (Join-Path 'schemas' $Name))
}

<#
.SYNOPSIS
Validates an in-memory doc (IDictionary) against a test/schemas/*.yml JSON-Schema via Test-Json.
.DESCRIPTION
Returns @{ Ok; Errors }. When Test-Json is unavailable it degrades to an Ok parse-only pass (the
doc already parsed) so the CLI still works on older PowerShell, just without enforcement.
#>
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

<#
.SYNOPSIS
Validates one pool-intent file against its schema, returning $true when the file is acceptable.
.DESCRIPTION
A -Required file that is absent FAILS (returns $false): pools.yml is the pool's identity and the
runners pull whatever is committed, so a missing pools.yml would silently leave the pool
unconfigured -- it must not read as success. A non-required file that is absent is a SKIP
(returns $true) -- guests.compatibility.yml and the test-sets are genuinely optional. A present
file is parsed and schema-checked via Test-YurunaPoolDocValid. Emits PASS/FAIL/SKIP breadcrumbs.
#>
function Test-YurunaPoolIntentFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Required
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Required) {
            Write-Warning "FAIL  ${Label}: required file is missing ($Path)"
            return $false
        }
        Write-Information "SKIP  ${Label}: not present ($Path)" -InformationAction Continue
        return $true
    }
    $doc = $null
    try { $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered } catch {
        Write-Warning "FAIL  ${Label}: YAML parse error -- $($_.Exception.Message)"
        return $false
    }
    $v = Test-YurunaPoolDocValid -Doc $doc -SchemaName $SchemaName
    if ($v.Ok) { Write-Information "PASS  ${Label}: schema-valid ($Path)" -InformationAction Continue; return $true }
    Write-Warning "FAIL  ${Label}: $($v.Errors -join '; ')"
    return $false
}

<#
.SYNOPSIS
Ensures a working clone of the WRITABLE intent repo at $IntentDir.
.DESCRIPTION
Clones when absent, else fetches + reset --hard origin/HEAD so the edit is based on the latest
remote state. Bounded + prompt-proof. Returns @{ Ok; Error }.
#>
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
        $rc = Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', $IntentDir, 'fetch', '--quiet', 'origin') -Label 'git fetch'
        if ($rc -ne 0) { return @{ Ok = $false; Error = "git fetch failed (exit $rc) from $IntentGitUrl" } }
        # A clone left mid-rebase (an interrupted Publish rebase-retry) holds an
        # in-flight unpushed commit while its branch tip has already moved onto the
        # remote's -- so the merge-base probe below would read it as a safe
        # fast-forward and reset --hard would discard it. Detect the
        # rebase-in-progress state first and refuse.
        if ((Test-Path -LiteralPath (Join-Path $gitDir 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gitDir 'rebase-apply'))) {
            return @{ Ok = $false; Error = "the admin clone at $IntentDir has an unfinished rebase (unpushed pool intent in flight); refusing to reset --hard. Finish or abort it (git -C '$IntentDir' rebase --abort) and push from a writable location, or delete $IntentDir to discard and re-clone from $IntentGitUrl." }
        }
        # Refuse to reset --hard unless the remote provably contains our HEAD: a
        # local commit the remote lacks is committed-but-unpushed pool intent (a
        # prior Publish reached the commit but not the push), and a silent reset
        # would erase it with no trace. merge-base --is-ancestor: rc==0 means HEAD
        # IS contained in FETCH_HEAD (a safe fast-forward -- reset only adds
        # commits); rc==128 is an unborn HEAD / missing ref where reset IS the
        # recovery. Any other rc -- 1 (local-ahead / diverged), 124 (timeout), -1
        # (git unrunnable) -- cannot prove containment, so refuse rather than
        # green-light a destructive reset.
        $rcAncestor = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
        if ($rcAncestor -ne 0 -and $rcAncestor -ne 128) {
            return @{ Ok = $false; Error = "cannot confirm the admin clone at $IntentDir is safe to reset (merge-base rc=$rcAncestor; likely local commit(s) the remote does not have); refusing to reset --hard. Push them from a writable location, or delete $IntentDir to discard and re-clone from $IntentGitUrl." }
        }
        # Reset to FETCH_HEAD (origin's default branch) rather than the origin/HEAD
        # symbolic ref, which a plain clone does not always populate.
        $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'reset', '--hard', '--quiet', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
        if ($rc -ne 0) { return @{ Ok = $false; Error = "git reset failed (exit $rc)" } }
        return @{ Ok = $true; Error = '' }
    }
    $parent = Split-Path -Parent $IntentDir
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    # Clone retry is idempotent for the common transient case: git removes a target
    # dir it created on a connect-stage failure, so a network/proxy blip re-clones
    # cleanly. A timeout process-kill mid-transfer can leave a partial dir a later
    # run must clear -- no worse than a single attempt, and the store is authored
    # here, not read, so a leftover partial loses no data.
    $rc = Invoke-PoolAdminGitWithRetry -ArgumentList @('clone', '--quiet', $IntentGitUrl, $IntentDir) -Label 'git clone'
    if ($rc -ne 0) { return @{ Ok = $false; Error = "git clone failed (exit $rc) from $IntentGitUrl" } }
    return @{ Ok = $true; Error = '' }
}

<#
.SYNOPSIS
Parses <IntentDir>/pools.yml into an ordered dictionary, or returns a fresh empty doc
({schemaVersion:1, pools:[]}) when the file is absent.
#>
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

<#
.SYNOPSIS
Validates $Doc against $SchemaName then writes it to <IntentDir>/<RelPath> as BOM-less UTF-8.
.DESCRIPTION
ConvertTo-Yaml can emit a BOM; the bare-repo + git consumers must stay BOM-free. Returns
@{ Ok; Error }. Does NOT commit -- Publish-YurunaPoolIntent does.
#>
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

<#
.SYNOPSIS
Commits everything under $IntentDir and pushes to the writable origin (bounded).
.DESCRIPTION
A commit identity is passed inline so a fresh proxy clone with no configured user.name/email still
commits. Returns @{ Ok; Pushed; Error }: Ok=committed locally, Pushed=reached the remote (a
read-only/offline remote leaves Pushed=$false with a hint -- the function itself does not throw).
The admin CLIs, however, treat Pushed=$false as a command failure (exit non-zero): a committed-but-
unpushed intent is not durable and is discarded by the next Open-YurunaPoolIntent.
#>
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
    $rc = Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', $IntentDir, 'push', '--quiet', 'origin', 'HEAD:main') -Label 'git push'
    if ($rc -ne 0) {
        # A reachable remote that rejects the push is most likely a non-fast-
        # forward: a concurrent admin pushed between our Open and here. Fetch,
        # rebase our commit onto the new tip, and retry the push once. A content
        # conflict (both edited pools.yml) aborts the rebase and leaves the local
        # commit intact for the caller to surface (Open refuses to reset over it).
        # A fetch that also fails means the remote is offline/read-only -- surface
        # Pushed=$false without disturbing the clone.
        $rcFetch = Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', $IntentDir, 'fetch', '--quiet', 'origin') -Label 'git fetch (rebase retry)'
        if ($rcFetch -eq 0) {
            $rcRebase = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, '-c', 'user.name=yuruna-pool-admin', '-c', 'user.email=pool-admin@yuruna.local', 'rebase', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
            if ($rcRebase -eq 0) {
                $rc2 = Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', $IntentDir, 'push', '--quiet', 'origin', 'HEAD:main') -Label 'git push (after rebase)'
                if ($rc2 -eq 0) { return @{ Ok = $true; Pushed = $true; Error = '' } }
                $rc = $rc2
            } else {
                $null = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'rebase', '--abort') -TimeoutSeconds $script:PoolAdminGitTimeoutSec
            }
        }
        return @{ Ok = $true; Pushed = $false; Error = "committed locally but push failed (exit $rc) -- push from a writable location (e.g. on the proxy: a file:// or local path to the bare repo)" }
    }
    return @{ Ok = $true; Pushed = $true; Error = '' }
}

<#
.SYNOPSIS
Fills the WRITABLE intent url + the admin working clone dir with sensible defaults.
.DESCRIPTION
The url falls back to pool.intentGitUrl from test.config.yml; the clone dir defaults to
<runtime>/pool-intent-admin (kept separate from the runner's read-only pool-intent clone so admin
edits never race the runner's reset --hard).
#>
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

<#
.SYNOPSIS
Returns the pool object with $PoolId from $Doc, or $null.
#>
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
    Resolve-YurunaPoolSchemaPath, Test-YurunaPoolDocValid, Test-YurunaPoolIntentFile, `
    Open-YurunaPoolIntent, Read-YurunaPoolsDoc, Save-YurunaPoolDoc, Publish-YurunaPoolIntent, `
    Get-YurunaPoolFromDoc, Resolve-YurunaPoolAdminTarget
