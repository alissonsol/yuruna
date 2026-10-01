<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42771d17-19c8-478e-adde-9418cf0f9f10
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


# Shared helpers for the pool admin CLI (New-Pool / Add-HostToPool / ... /
# Test-PoolIntent). See ../../docs/pool-admin.md#before-you-start for the
# write path vs the runner's read-only pull path. -- Test.PoolAdmin.psm1

$script:PoolAdminGitTimeoutSeconds = 60
# Idempotent network git ops (fetch/clone/push) retry within one overall
# wall-clock budget so a single transient blip (a proxy hiccup, a momentary
# DNS/TLS failure) does not abort the operator action or leave intent
# committed-but-unpushed. Kept short so an interactive admin command fails in
# bounded time rather than hanging.
$script:PoolAdminRetryBudgetSeconds = 90
$script:PoolAdminRetryDelaySeconds  = 3

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
        [int]$TimeoutSeconds = $script:PoolAdminGitTimeoutSeconds,
        [int]$BudgetSeconds  = $script:PoolAdminRetryBudgetSeconds,
        [int]$DelaySeconds   = $script:PoolAdminRetryDelaySeconds
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
(returns $true) -- guests.compatibility.yml is genuinely optional. A present
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c1ccd779c5d89baf' -Arguments @{ label = "${Label}"; path = "$Path" })
            return $false
        }
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c13dcea8b437ce0f' -Arguments @{ label = "${Label}"; path = "$Path" }) -InformationAction Continue
        return $true
    }
    $doc = $null
    try { $doc = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e0674b7efa2de0b5' -Arguments @{ label = "${Label}"; message = "$($_.Exception.Message)" })
        return $false
    }
    $v = Test-YurunaPoolDocValid -Doc $doc -SchemaName $SchemaName
    if ($v.Ok) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9002006fe4b250e9' -Arguments @{ label = "${Label}"; path = "$Path" }) -InformationAction Continue; return $true }
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_804e070f07e0a11f' -Arguments @{ label = "${Label}"; join = "$($v.Errors -join '; ')" })
    return $false
}

# One admin command at a time may work in a given admin clone. Every admin CLI is its own process
# and they all share <runtime>/pool-intent-admin, so without this the clone is opened by several
# processes at once: two first uses both find no .git and clone into the same directory (one
# wins, the rest fail), and a read's reset --hard can land between a writer's edit and its
# commit, so the writer finds nothing to stage and reports success for a change that never
# happened. The lock therefore covers the whole command: it is taken when the clone is opened and
# kept until the process exits (the operating system frees it even after a crash) or
# Unlock-YurunaPoolIntentClone runs. Admins on other hosts work in their own clones and still meet
# at the remote, where Publish-YurunaPoolIntent rebases a lost push race.
$script:PoolAdminLockWaitSeconds = 120
$script:PoolAdminHeldLocks = [System.Collections.Generic.Dictionary[string, System.IO.FileStream]]::new(
    $(if ($IsLinux) { [StringComparer]::Ordinal } else { [StringComparer]::OrdinalIgnoreCase }))

<#
.SYNOPSIS
Takes the cross-process lock for an admin clone, waiting up to $WaitSeconds for another command.
.DESCRIPTION
The lock is an exclusively opened file NEXT TO the clone (<IntentDir>.lock), never inside it, so
`git add -A` cannot stage it and a clone that does not exist yet can still be locked. Re-entrant
within a process: a second call for the same clone returns at once. Returns @{ Ok; Error }; Ok=$false
only when another command still holds the clone after the wait. A lock that cannot be created for
any other reason (an unwritable directory, a filesystem without file locking) is skipped, not
fatal: the caller's own clone or fetch reports the real problem, and this guard must not become a
new way for an admin command to fail.
.PARAMETER IntentDir
The clone directory. A PowerShell path (a drive such as TestDrive:, a relative path) is resolved,
because other processes must land on the same file.
.PARAMETER WaitSeconds
How long to wait for a command that holds the clone.
#>
function Lock-YurunaPoolIntentClone {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$IntentDir,
        [int]$WaitSeconds = $script:PoolAdminLockWaitSeconds
    )
    $cloneFull = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IntentDir))
    $lockPath = $cloneFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + '.lock'
    if ($script:PoolAdminHeldLocks.ContainsKey($lockPath)) { return @{ Ok = $true; Error = '' } }
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, $WaitSeconds))
    while ($true) {
        try {
            [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($lockPath))
            $script:PoolAdminHeldLocks[$lockPath] = [System.IO.FileStream]::new($lockPath, [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return @{ Ok = $true; Error = '' }
        } catch {
            # A held lock is an IOException (a sharing violation). Only PowerShell's own method-call
            # wrapper is unwrapped: an UnauthorizedAccessException also carries an IOException
            # inside it, and that one is a permissions problem, not another command.
            $cause = $_.Exception
            if ($cause -is [System.Management.Automation.RuntimeException] -and $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [System.IO.IOException]) {
                Write-Verbose "admin clone lock skipped: $($cause.Message)"
                return @{ Ok = $true; Error = '' }
            }
            if ([DateTime]::UtcNow -ge $deadlineUtc) {
                return @{ Ok = $false; Error = "another pool admin command is still using the admin clone at $IntentDir (waited $WaitSeconds s for $lockPath); run this command again when it finishes." }
            }
            Start-Sleep -Milliseconds 250
        }
    }
}

<#
.SYNOPSIS
Releases the lock Lock-YurunaPoolIntentClone took for one admin clone, or for every clone with -All.
.DESCRIPTION
An admin command need not call this: it holds the clone for its whole run and the operating system
frees the lock when the process ends. It exists for a long-lived caller and for tests that delete
the clone's directory, which Windows refuses while the lock file is open.
#>
function Unlock-YurunaPoolIntentClone {
    [CmdletBinding(DefaultParameterSetName = 'One')]
    [OutputType([void])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'One')][string]$IntentDir,
        [Parameter(Mandatory, ParameterSetName = 'All')][switch]$All
    )
    $held = if ($All) { @($script:PoolAdminHeldLocks.Keys) } else {
        $cloneFull = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($IntentDir))
        @($cloneFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + '.lock')
    }
    foreach ($lockPath in $held) {
        $stream = $null
        if ($script:PoolAdminHeldLocks.TryGetValue($lockPath, [ref]$stream)) {
            [void]$script:PoolAdminHeldLocks.Remove($lockPath)
            $stream.Dispose()
        }
    }
}

<#
.SYNOPSIS
Ensures a working clone of the WRITABLE intent repo at $IntentDir.
.DESCRIPTION
Clones when absent, else fetches + reset --hard origin/HEAD so the edit is based on the latest
remote state. Bounded + prompt-proof. Returns @{ Ok; Error }. Takes the clone's cross-process lock
first (see Lock-YurunaPoolIntentClone) and keeps it until the process exits, so no other admin
command can clone, reset or commit in the clone while this one edits it.
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
    if (-not $PSCmdlet.ShouldProcess($IntentDir, (Format-YurunaOperatorMessage -Key 'runner.operator_811a9975fa1a2df7' -Arguments @{ intentGitUrl = "$IntentGitUrl" }))) { return @{ Ok = $true; Error = '' } }
    $locked = Lock-YurunaPoolIntentClone -IntentDir $IntentDir -WaitSeconds $script:PoolAdminLockWaitSeconds
    if (-not $locked.Ok) { return @{ Ok = $false; Error = $locked.Error } }
    $gitDir = Join-Path $IntentDir '.git'
    if (Test-Path -LiteralPath $gitDir) {
        # The clone is the operator's write path and may hold unpushed intent, so a
        # different origin is refused rather than rewritten or re-cloned over it.
        if ((Get-Command Test-PoolIntentCloneOrigin -ErrorAction SilentlyContinue) -and -not (Test-PoolIntentCloneOrigin -Path $IntentDir -Url $IntentGitUrl)) {
            return @{ Ok = $false; Error = "the admin clone at $IntentDir has a different origin than the requested $IntentGitUrl; refusing to fetch or push it. Use another -IntentDir, or delete $IntentDir to re-clone from $IntentGitUrl." }
        }
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
        $rcAncestor = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'merge-base', '--is-ancestor', 'HEAD', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
        if ($rcAncestor -ne 0 -and $rcAncestor -ne 128) {
            return @{ Ok = $false; Error = "cannot confirm the admin clone at $IntentDir is safe to reset (merge-base rc=$rcAncestor; likely local commit(s) the remote does not have); refusing to reset --hard. Push them from a writable location, or delete $IntentDir to discard and re-clone from $IntentGitUrl." }
        }
        # Reset to FETCH_HEAD (origin's default branch) rather than the origin/HEAD
        # symbolic ref, which a plain clone does not always populate.
        $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'reset', '--hard', '--quiet', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
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
Upgrades an in-memory pools.yml document to schemaVersion 3, in place, and returns it.
.DESCRIPTION
Schema v3 carries a pool's framework and project URLs as `repositories`
({ frameworkUrl, projectUrl }). A document below v3 -- or one with no schemaVersion at all,
which the v2 admin tooling read as 2 -- is upgraded: a pool whose `testSet` holds a non-empty
frameworkUrl AND projectUrl gets them as `repositories`, in the same key position; the
`testSet` object (with its `name` and `sequences`) and any `testSets` list are dropped; and
schemaVersion becomes 3.

A document already at 3 is returned unchanged, and so is one at a higher or a non-integer
version: this checkout cannot know that shape, so it leaves the document for the writer's
schema validation to refuse instead of guessing. Idempotent. Every admin read goes through
Read-YurunaPoolsDoc, which calls this, so the next admin write persists the upgrade.
.PARAMETER Doc
The parsed pools.yml document.
.OUTPUTS
System.Collections.IDictionary -- the same $Doc instance.
#>
function ConvertTo-PoolIntentSchemaV3 {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Doc)
    $version = if ($Doc.Contains('schemaVersion')) { $Doc['schemaVersion'] } else { 2 }
    if (-not (($version -is [int]) -or ($version -is [long]))) { return $Doc }
    if ($version -ge 3) { return $Doc }
    foreach ($pool in @($Doc['pools'])) {
        if ($pool -isnot [System.Collections.IDictionary]) { continue }
        $legacy = $pool['testSet']
        if (($legacy -is [System.Collections.IDictionary]) -and -not $pool.Contains('repositories')) {
            $frameworkUrl = ([string]$legacy['frameworkUrl']).Trim()
            $projectUrl   = ([string]$legacy['projectUrl']).Trim()
            if ($frameworkUrl -and $projectUrl) {
                $pair = [ordered]@{ frameworkUrl = $frameworkUrl; projectUrl = $projectUrl }
                if ($pool -is [System.Collections.Specialized.OrderedDictionary]) {
                    $pool.Insert(@($pool.Keys).IndexOf('testSet'), 'repositories', $pair)
                } else {
                    $pool['repositories'] = $pair
                }
            }
        }
        if ($pool.Contains('testSet'))  { $pool.Remove('testSet') }
        if ($pool.Contains('testSets')) { $pool.Remove('testSets') }
    }
    # schemaVersion leads the file when it has to be added, as every writer emits it.
    if (($Doc -is [System.Collections.Specialized.OrderedDictionary]) -and -not $Doc.Contains('schemaVersion')) {
        $Doc.Insert(0, 'schemaVersion', 3)
    } else {
        $Doc['schemaVersion'] = 3
    }
    return $Doc
}

<#
.SYNOPSIS
Parses <IntentDir>/pools.yml into an ordered dictionary upgraded to schemaVersion 3, or returns a
fresh empty doc ({schemaVersion:3, pools:[]}) when the file is absent or not a mapping.
.DESCRIPTION
Every pool-admin CLI reads through here, so ConvertTo-PoolIntentSchemaV3 runs on every admin
read and the next admin write persists the upgrade. Test-PoolIntent.ps1 and
Update-PoolIntentSchema.ps1 read pools.yml raw instead: they must see the version as stored.
#>
function Read-YurunaPoolsDoc {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string]$IntentDir)
    $path = Join-Path $IntentDir 'pools.yml'
    $doc = $null
    if (Test-Path -LiteralPath $path) { $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered }
    if ($doc -isnot [System.Collections.IDictionary]) { $doc = [ordered]@{ schemaVersion = 3; pools = @() } }
    if (-not $doc.Contains('pools') -or $null -eq $doc['pools']) { $doc['pools'] = @() }
    return (ConvertTo-PoolIntentSchemaV3 -Doc $doc)
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
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_4f719f0639145301'))) { return @{ Ok = $true; Error = '' } }
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
    if (-not $PSCmdlet.ShouldProcess($IntentDir, (Format-YurunaOperatorMessage -Key 'runner.operator_efd4f169b13d993c' -Arguments @{ message = "$Message" }))) { return @{ Ok = $true; Pushed = $true; Error = '' } }
    $rc = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'add', '-A') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
    if ($rc -ne 0) { return @{ Ok = $false; Pushed = $false; Error = "git add failed (exit $rc)" } }
    # Nothing staged -> no-op success (idempotent re-run).
    $rcDiff = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'diff', '--cached', '--quiet') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
    if ($rcDiff -eq 0) { return @{ Ok = $true; Pushed = $true; Error = 'no changes' } }
    $rc = Invoke-PoolSyncGit -ArgumentList @(
        '-C', $IntentDir,
        '-c', 'user.name=yuruna-pool-admin', '-c', 'user.email=pool-admin@yuruna.local',
        'commit', '--quiet', '-m', $Message) -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
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
            $rcRebase = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, '-c', 'user.name=yuruna-pool-admin', '-c', 'user.email=pool-admin@yuruna.local', 'rebase', 'FETCH_HEAD') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
            if ($rcRebase -eq 0) {
                $rc2 = Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', $IntentDir, 'push', '--quiet', 'origin', 'HEAD:main') -Label 'git push (after rebase)'
                if ($rc2 -eq 0) { return @{ Ok = $true; Pushed = $true; Error = '' } }
                $rc = $rc2
            } else {
                $null = Invoke-PoolSyncGit -ArgumentList @('-C', $IntentDir, 'rebase', '--abort') -TimeoutSeconds $script:PoolAdminGitTimeoutSeconds
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

<#
.SYNOPSIS
Normalizes an operator-typed hostId to its canonical form (42-prefixed 32-hex, no
separators). Returns $null when the value is not a host uuid in any accepted form.
.DESCRIPTION
The stored and on-wire form is always the bare 32 hex chars, but every surface that
shows an operator a FULL id spells it GUID-formatted (8-4-4-4-12, what
Format-YurunaHostId renders) because a dozen near-identical 42-prefixed ids are not
tellable apart without the dashes -- the Grafana pool dashboard reveals one that way
from its Host ID column, and so does the pool-control UI. An operator copying a
hostId off either therefore pastes a hyphenated string that no store ever contains,
so accept it here and hand callers the canonical form. This is the inverse of
Format-YurunaHostId; the pair is what makes an id readable in one place and usable
in the other. Braces and surrounding whitespace are
tolerated for the same reason -- they come free with a copy from other tooling. Case
is preserved as lowercase: hex comparisons against pools.yml members[] and the NAS
record filenames are ordinal, and every producer writes lowercase.
.OUTPUTS
System.String -- the canonical hostId, or $null if $Value is not one.
#>
function ConvertTo-YurunaHostId {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $v = $Value.Trim().Trim('{', '}').Replace('-', '')
    if ($v -notmatch '^42[0-9a-fA-F]{30}$') { return $null }
    return $v.ToLowerInvariant()
}

<#
.SYNOPSIS
    Create a bare pool-intent repository, seeded with an empty schema-valid pools.yml.
.DESCRIPTION
    The only other implementations live in shell, inside the caching-proxy-service
    and pool-control-service cloud-init, so this is the host side's way to create a
    store. Three details are load-bearing and are the reason this is a shared
    function rather than a fresh `git init` at each call site:

      * `core.fileMode false` -- a NAS mount maps modes from the mount options, so
        git would otherwise see a permission change on every file it writes back.
      * `receive.updateServerInfo true` -- keeps the dumb-HTTP indexes current after
        each push. The usual post-update hook never becomes executable on a CIFS
        mount, so info/refs would go stale the moment intent was written and readers
        would keep being served the old refs.
      * `schemaVersion: 3` -- a store seeded at an older version READS fine,
        because nothing validates on read, and then fails every write at schema
        validation. The store looks healthy right up until someone creates a pool.

    Idempotent: an existing repository is left untouched.
.PARAMETER Path
    Filesystem path of the bare repository to create.
.PARAMETER Force
    Recreate even if the path already looks like a repository.
#>
function New-YurunaPoolIntentStore {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )
    $already = Test-Path -LiteralPath (Join-Path $Path 'refs')
    if ($already -and -not $Force) {
        return [pscustomobject]@{ Path = $Path; Created = $false; Reason = 'already a repository' }
    }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_4f741864aba4d1fd'))) {
        return [pscustomobject]@{ Path = $Path; Created = $false; Reason = 'WhatIf' }
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    & git init --bare --initial-branch=main -- $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_d3b174912efd30ac' -Arguments @{ path = "$Path"; lASTEXITCODE = "$LASTEXITCODE" }) }
    & git -C $Path config core.fileMode false 2>&1 | Out-Null
    & git -C $Path config receive.updateServerInfo true 2>&1 | Out-Null

    $seed = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-intent-seed-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $seed -Force
    try {
        & git -C $seed init -q --initial-branch=main 2>&1 | Out-Null
        & git -C $seed config core.fileMode false 2>&1 | Out-Null
        # LF, no BOM: the file is read by git and by ConvertFrom-Yaml on three platforms.
        [IO.File]::WriteAllText((Join-Path $seed 'pools.yml'), "schemaVersion: 3`npools: []`n",
            (New-Object System.Text.UTF8Encoding($false)))
        & git -C $seed add -A 2>&1 | Out-Null
        # Identity supplied inline so this works on a host with no git user configured.
        & git -C $seed -c user.name=yuruna -c user.email=pool@yuruna.local commit -q -m 'seed pool intent' 2>&1 | Out-Null
        & git -C $seed push -q -- $Path HEAD:main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.runner_a4fb11bebe1b1114' -Arguments @{ path = "$Path"; lASTEXITCODE = "$LASTEXITCODE" }) }
        & git -C $Path update-server-info 2>&1 | Out-Null
    } finally {
        Remove-Item -LiteralPath $seed -Recurse -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{ Path = $Path; Created = $true; Reason = 'seeded' }
}

<#
.SYNOPSIS
    Make a WRITABLE filesystem intent target openable: seed the bare repository
    when the path carries none yet. Returns @{ Ok; Created; Reason }.
.DESCRIPTION
    Open-YurunaPoolIntent can only clone a store that already exists, so every
    authoring command against a path that was never seeded dies on the same
    opaque `git clone failed (exit 128)`. The store is an implementation detail of
    the pool, not something an operator creates by hand, and the only thing that
    ever seeded it was a lab bring-up running New-Lab. Any other route to a fresh
    pool folder (a NAS tier mounted straight into networkStorage, a share rebuilt
    under a new root, a beacon whose pool folder was replaced) reaches an
    authoring command with nothing to open and no hint of what is missing.

    Only for CREATE/UPDATE paths. The read-only consumers (Get-PoolIntent,
    Get-PoolStatus, Test-PoolIntent) must keep failing on an absent store: for
    them a wrong url and an empty pool are different answers, and seeding one
    here would turn "you are pointed at nothing" into a healthy-looking empty
    pool that reports every host as unenrolled.

    A remote url (http/https/ssh/git/file with a host) is left alone -- nothing
    on this side can create a repository over there, and the caller's own clone
    failure is the honest report. Only a local or UNC PATH is seeded, and only
    when it holds no repository already; an existing store is never touched.
.PARAMETER IntentGitUrl
    The writable target Resolve-YurunaPoolAdminTarget produced.
#>
function Initialize-YurunaPoolIntentStorePath {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$IntentGitUrl)

    if ([string]::IsNullOrWhiteSpace($IntentGitUrl)) { return @{ Ok = $false; Created = $false; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_b225367bfb565d80') } }
    $target = $IntentGitUrl.Trim()

    # A scheme means "somewhere else". file:// is the one scheme that still names
    # a local path, so it is unwrapped rather than skipped -- an operator writing
    # the writable target as a file:// url means the same store as the bare path.
    if ($target -match '^file://(?<rest>.+)$') {
        $target = ([uri]$target).LocalPath
    } elseif ($target -match '^[A-Za-z][A-Za-z0-9+.-]*://') {
        return @{ Ok = $true; Created = $false; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_e314b5fed409feed') }
    } elseif ($target -match '^[^@/\\]+@[^:/\\]+:') {
        # scp-like ssh remote (git@host:path); the user@ prefix is required so a
        # Windows drive path (C:\...) is never mistaken for one.
        return @{ Ok = $true; Created = $false; Reason = (Format-YurunaOperatorMessage -Key 'runner.operator_e314b5fed409feed') }
    }

    if (Test-Path -LiteralPath (Join-Path $target 'refs')) {
        return @{ Ok = $true; Created = $false; Reason = 'already a repository' }
    }
    if (-not $PSCmdlet.ShouldProcess($target, (Format-YurunaOperatorMessage -Key 'runner.operator_37c6d3d1e44ac68b'))) {
        return @{ Ok = $true; Created = $false; Reason = 'WhatIf' }
    }
    try {
        $store = New-YurunaPoolIntentStore -Path $target -Confirm:$false
        return @{ Ok = $true; Created = [bool]$store.Created; Reason = $store.Reason }
    } catch {
        # Surfaced, not swallowed: the caller's clone is about to fail anyway,
        # and "the store is missing AND could not be created because <reason>"
        # is the message that names the real blocker (an unwritable mount, a
        # NAS credential that authenticated read-only).
        return @{ Ok = $false; Created = $false; Reason = $_.Exception.Message }
    }
}

function Open-YurunaPoolAdminStore {
    <#
    .SYNOPSIS
        Resolve and open the pool intent store with one consistent error contract.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$IntentGitUrl, [string]$IntentDir)
    $target = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
    if ([string]::IsNullOrWhiteSpace($target.IntentGitUrl)) {
        return @{ Ok = $false; Target = $target; Error = (Format-YurunaOperatorMessage -Key 'runner.operator_7dd0aa845d3a93ea') }
    }
    if (-not $PSCmdlet.ShouldProcess($target.IntentDir, 'Open pool intent store')) { return @{ Ok = $false; Target = $target; Error = 'Open declined.' } }
    $opened = Open-YurunaPoolIntent -IntentGitUrl $target.IntentGitUrl -IntentDir $target.IntentDir -Confirm:$false
    $errorText = if ($opened.Ok) { '' } else { Format-YurunaOperatorMessage -Key 'runner.operator_5080fa98b3c9b51c' -Arguments @{ intentGitUrl = "$($target.IntentGitUrl)"; error = "$($opened.Error)" } }
    return @{ Ok = [bool]$opened.Ok; Target = $target; Error = $errorText }
}

function Publish-YurunaPoolDocChange {
    <#
    .SYNOPSIS
        Save a validated document and require successful intent publication.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$IntentDir, [Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][string]$SchemaName,
        [Parameter(Mandatory)][string]$Message)
    if (-not $PSCmdlet.ShouldProcess($IntentDir, $Message)) { return @{ Ok = $false; Pushed = $false; Error = 'Publication declined.' } }
    $saved = Save-YurunaPoolDoc -IntentDir $IntentDir -RelPath $RelPath -Doc $Doc -SchemaName $SchemaName -Confirm:$false
    if (-not $saved.Ok) { return @{ Ok = $false; Pushed = $false; Error = (Format-YurunaOperatorMessage -Key 'runner.operator_9c27a25b6843707d' -Arguments @{ error = "$($saved.Error)" }) } }
    $published = Publish-YurunaPoolIntent -IntentDir $IntentDir -Message $Message -Confirm:$false
    $key = if (-not $published.Ok) { 'runner.operator_493d8875345272bb' } else { 'runner.operator_d7dcddaba0a5b0ef' }
    $errorText = if ($published.Ok -and $published.Pushed) { '' } else { Format-YurunaOperatorMessage -Key $key -Arguments @{ error = "$($published.Error)" } }
    return @{ Ok = [bool]($published.Ok -and $published.Pushed); Pushed = [bool]$published.Pushed; Error = $errorText }
}

# A re-import (Import-Module -Force) drops this table, and a lock whose stream was dropped with it
# would stay held by this process and block the next Open of the same clone until the process ends.
$ExecutionContext.SessionState.Module.OnRemove = { Unlock-YurunaPoolIntentClone -All }

Export-ModuleMember -Function Open-YurunaPoolAdminStore, Publish-YurunaPoolDocChange, `
    Resolve-YurunaPoolSchemaPath, Test-YurunaPoolDocValid, Test-YurunaPoolIntentFile, `
    Lock-YurunaPoolIntentClone, Unlock-YurunaPoolIntentClone, `
    Open-YurunaPoolIntent, ConvertTo-PoolIntentSchemaV3, Read-YurunaPoolsDoc, Save-YurunaPoolDoc, Publish-YurunaPoolIntent, `
    Get-YurunaPoolFromDoc, Resolve-YurunaPoolAdminTarget, ConvertTo-YurunaHostId, `
    New-YurunaPoolIntentStore, Initialize-YurunaPoolIntentStorePath
