<#PSScriptInfo
.VERSION 2026.09.24
.GUID 427d5433-30b3-40c0-aa3e-59e31c0c828b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool admin gc
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

<#
.SYNOPSIS
    Purge a stale host from the pool: delete its NAS records (identity +
    replicated cycles) and strip it from every pool's members[].
.DESCRIPTION
    Pool garbage-collection CLI. Given a stable hostId, removes the host's entire
    footprint so it stops showing up in the "Yuruna hosts" / Extension-hosts set:

      1. STORAGE. Deletes, under networkStorage.poolStorageLocalPath (read from
         test.config.yml):
           * <poolStorageLocalPath>/hosts/info.<hostId>.yml  -- the identity record the
             aggregator lists a host from.
           * <poolStorageLocalPath>/<hostId>/                -- the host's replicated
             cycle folders (reclaims NAS disk).
      2. MEMBERSHIP. Strips the hostId from EVERY pool's members[] in the intent
         store (pools.yml), then commits + pushes.

    Ephemeral hosts (a disposable nested-host cycle, a reimaged box) mint a fresh
    hostId each rebuild, so without cleanup each run leaves a dead entry behind.

    Guards: refuses to remove THIS host's own uuid (runtime/host.uuid) or a
    record last seen < 24h ago (it may still be live) unless -Force. Idempotent;
    SupportsShouldProcess (-WhatIf / -Confirm). Distinct from Remove-HostFromPool,
    which only edits ONE named pool's membership and never touches storage.
.PARAMETER HostId
    Stable hostId to purge -- the record's hostUuid / runtime/host.uuid:
    '42' + 30 hex. The GUID-dashed spelling every panel and UI reveals a full id
    in is accepted too, so a value copied off one works as pasted.
.PARAMETER Force
    Override the safety refusals (own uuid / recently-seen record).
.PARAMETER ConfigPath
    test.config.yml to read the pool storage path from (default: next to test/).
.PARAMETER IntentGitUrl
    Writable URL/path of the bare intent repo for the membership strip. Defaults
    to pool.intentGitUrl from test.config.yml. When neither is set, the storage
    records are still removed and the membership step is skipped with a warning.
.PARAMETER IntentDir
    Local working clone. Defaults to <runtime>/pool-intent-admin.
.EXAMPLE
    ./Remove-PoolHost.ps1 -HostId 42abcdef0123456789abcdef01234567
.EXAMPLE
    ./Remove-PoolHost.ps1 -HostId 42abcdef0123456789abcdef01234567 -WhatIf
.EXAMPLE
    ./Remove-PoolHost.ps1 -HostId 42abcdef-0123-4567-89ab-cdef01234567
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$HostId,
    [switch]$Force,
    [string]$ConfigPath = $null,
    [string]$IntentGitUrl,
    [string]$IntentDir
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths       = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder -ConfigPath $ConfigPath
$ModulesDir  = $paths.ModulesDir
$ConfigPath  = $paths.ConfigPath
Initialize-YurunaEntryPointModuleSet -For PoolAdmin -ModulesDir $ModulesDir
# The PoolAdmin set covers the intent-store side; the NAS-record side lives in
# Test.PoolStorage (Get-YurunaPoolStorageConfig), which it does not load.
Import-Module (Join-Path $ModulesDir 'Test.PoolStorage.psm1') -Global -Force -DisableNameChecking
# The live-dashboard eviction (forget-host) reuses the pool push transport
# (CA-pinned HTTPS + bearer) and the caching-proxy-service address; loaded here, resolved
# lazily + best-effort at the end (a missing token/proxy just skips it).
foreach ($m in @('Test.PoolPush.psm1', 'Test.CachingProxyService.psm1', 'Test.Extension.psm1')) {
    $mp = Join-Path $ModulesDir $m
    if (Test-Path -LiteralPath $mp) { Import-Module $mp -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue }
}
$ExitOk      = Get-EntryPointExitCode -Outcome Ok
$ExitFailure = Get-EntryPointExitCode -Outcome Failure
# The failure paths below pass -ErrorAction Continue: under the strict
# preference above, a bare Write-Error would itself terminate and skip
# the clean exit-code path.
Import-Module powershell-yaml -ErrorAction Stop

$canonicalHostId = ConvertTo-YurunaHostId -Value $HostId
if (-not $canonicalHostId) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5641829b01e1eb6c' -Arguments @{ hostId = "$HostId" }) -ErrorAction Continue
    exit $ExitFailure
}
$HostId = $canonicalHostId
# The spelling every line below shows the operator, which is the one the
# dashboard and the pool-control UI reveal a full id in; $HostId itself stays
# the canonical key the store is read and written with.
$shownHostId = Format-YurunaHostId -HostId $HostId

# --- REGION: Resolve the pool storage path from test.config.yml
$cfg = $null
if (Test-Path -LiteralPath $ConfigPath) { $cfg = Read-TestConfig -Path $ConfigPath }
# A GC tool only needs the poolStorageLocalPath to reach the share; whether this
# host archives in copy or move mode is irrelevant to deleting another host's records.
$storage = if ($cfg) { Get-YurunaPoolStorageConfig -Config $cfg } else { $null }
if (-not $storage -or [string]::IsNullOrWhiteSpace($storage.LocalPath)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_cbeb78ddd2cd7816' -Arguments @{ configPath = "$ConfigPath" }) -ErrorAction Continue
    exit $ExitFailure
}
$localPath  = $storage.LocalPath
$infoPath   = Join-Path $localPath (Join-Path 'hosts' "info.$HostId.yml")
# The host's archive root under the current layout, plus the frozen pre-unification
# root a long-lived share may still carry. Both are deleted: this GC is the only
# sanctioned deleter of the legacy roots, and in move mode the current root holds
# the ONLY copy of this host's cycle results.
$hostFolder = Get-PoolStorageHostFolderPath -Config $storage -HostId $HostId
$legacyRoot = Join-Path $localPath $HostId

if (-not (Test-Path -LiteralPath $localPath)) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7eec910180112557' -Arguments @{ localPath = "$localPath" })
}

# --- REGION: Safety guards (overridable with -Force)
$runtimeDir  = Initialize-YurunaRuntimeDir
$ownUuidFile = Join-Path $runtimeDir 'host.uuid'
if (Test-Path -LiteralPath $ownUuidFile) {
    $ownUuid = (Get-Content -Raw -LiteralPath $ownUuidFile).Trim()
    if ($ownUuid -and ($ownUuid -ieq $HostId) -and -not $Force) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_7385349d84f77b6d' -Arguments @{ shownHostId = "$shownHostId" }) -ErrorAction Continue
        exit $ExitFailure
    }
}
if ((Test-Path -LiteralPath $infoPath) -and -not $Force) {
    # Compute the recency verdict INSIDE the try (the parse can throw) but raise
    # the refusal OUTSIDE it -- the catch is scoped to the parse alone, so an
    # unreadable record degrades to "not recent" instead of masking the guard.
    $recentInfo = ''
    try {
        $rec      = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Yaml
        $lastSeen = if ($rec -is [System.Collections.IDictionary]) { [string]$rec['lastSeenUtc'] } else { '' }
        if ($lastSeen) {
            $dt   = [datetime]::Parse($lastSeen, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $ageH = ([datetime]::UtcNow - $dt).TotalHours
            if ($ageH -lt 24) { $recentInfo = ("last seen {0:N1}h ago (lastSeenUtc=$lastSeen)" -f $ageH) }
        }
    } catch { Write-Verbose "Could not parse lastSeenUtc from ${infoPath}: $($_.Exception.Message)" }
    if ($recentInfo) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_799b226f960c20de' -Arguments @{ shownHostId = "$shownHostId"; recentInfo = "$recentInfo" }) -ErrorAction Continue
        exit $ExitFailure
    }
}

# --- REGION: Remove the NAS records
$removed           = [System.Collections.Generic.List[string]]::new()
$storageIncomplete = $false
if (Test-Path -LiteralPath $infoPath) {
    if ($PSCmdlet.ShouldProcess($infoPath, (Format-YurunaOperatorMessage -Key 'runner.operator_0ea7a491f185a1a6'))) {
        if (Remove-PoolStorageTree -Path $infoPath -Confirm:$false) {
            [void]$removed.Add("identity record  $infoPath")
        } else {
            $storageIncomplete = $true
        }
    }
} else {
    Write-Verbose "No identity record at $infoPath (already gone)."
}
if (Test-Path -LiteralPath $hostFolder) {
    # Retry-tolerant: the SMB share acknowledges child deletes before it releases the
    # directory entries, so a single-shot recursive delete fails on a directory that
    # is already empty. A leftover tree must not abort the run either -- the
    # membership strip and the dashboard eviction below are what actually stop the
    # host reappearing, and they are worth doing even when the NAS is being slow.
    if ($PSCmdlet.ShouldProcess($hostFolder, (Format-YurunaOperatorMessage -Key 'runner.operator_609076c68c3ffd8f'))) {
        if (Remove-PoolStorageTree -Path $hostFolder -Confirm:$false) {
            [void]$removed.Add("cycle data       $hostFolder")
        } else {
            $storageIncomplete = $true
        }
    }
} else {
    Write-Verbose "No archived cycle folder at $hostFolder (already gone)."
}
if (Test-Path -LiteralPath $legacyRoot) {
    if ($PSCmdlet.ShouldProcess($legacyRoot, (Format-YurunaOperatorMessage -Key 'runner.operator_5ad3f8500420e985'))) {
        if (Remove-PoolStorageTree -Path $legacyRoot -Confirm:$false) {
            [void]$removed.Add("legacy data      $legacyRoot")
        } else {
            $storageIncomplete = $true
        }
    }
} else {
    Write-Verbose "No legacy cycle folder at $legacyRoot (already gone)."
}

# --- REGION: Strip membership from every pool (needs the writable intent store)
$t = Resolve-YurunaPoolAdminTarget -IntentGitUrl $IntentGitUrl -IntentDir $IntentDir
if ([string]::IsNullOrWhiteSpace($t.IntentGitUrl)) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b752ee38cb8d2c81')
} else {
    $open = Open-YurunaPoolIntent -IntentGitUrl $t.IntentGitUrl -IntentDir $t.IntentDir -Confirm:$false
    if (-not $open.Ok) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7d60c40c2ee69f28' -Arguments @{ intentGitUrl = "$($t.IntentGitUrl)"; error = "$($open.Error)" })
    } else {
        $doc          = Read-YurunaPoolsDoc -IntentDir $t.IntentDir
        $changedPools = [System.Collections.Generic.List[string]]::new()
        foreach ($pool in @($doc['pools'])) {
            if ($pool -isnot [System.Collections.IDictionary]) { continue }
            $members = @($pool['members'])
            if ($members -contains $HostId) {
                $pool['members'] = @($members | Where-Object { $_ -ne $HostId })
                [void]$changedPools.Add([string]$pool['poolId'])
            }
        }
        if ($changedPools.Count -eq 0) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ab09d4d54d248346' -Arguments @{ shownHostId = "$shownHostId" }) -InformationAction Continue
        } elseif ($PSCmdlet.ShouldProcess("pools.yml [$($changedPools -join ', ')]", (Format-YurunaOperatorMessage -Key 'runner.operator_8660cf0175a55371' -Arguments @{ hostId = "$HostId" }))) {
            $save = Save-YurunaPoolDoc -IntentDir $t.IntentDir -RelPath 'pools.yml' -Doc $doc -SchemaName 'pools.schema.yml' -Confirm:$false
            if (-not $save.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_9c27a25b6843707d' -Arguments @{ error = "$($save.Error)" }) -ErrorAction Continue; exit $ExitFailure }
            $pub = Publish-YurunaPoolIntent -IntentDir $t.IntentDir -Message "pool: purge host $HostId from members[]" -Confirm:$false
            if (-not $pub.Ok) { Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_493d8875345272bb' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue; exit $ExitFailure }
            if (-not $pub.Pushed) {
                Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_6374c70e057ee77d' -Arguments @{ error = "$($pub.Error)" }) -ErrorAction Continue
                exit $ExitFailure
            }
            [void]$removed.Add("pool membership  [$($changedPools -join ', ')]")
        }
    }
}

# --- REGION: Evict from the live dashboard view (aggregator forget-host, best-effort)
# The "Yuruna hosts" panel is the pool-aggregator-service's in-memory view (Prometheus
# yuruna_pool_host_info), NOT the NAS records above -- a host it discovered by
# POLLING status services lingers there for the aggregator's host TTL (-host-ttl, default 24h) after last contact, so the
# deletions so far do not clear it. When an internal authentication key + caching-proxy-service are
# configured, ask the aggregator to forget the host NOW. Opt-in + best-effort: a
# missing token, unknown proxy, or unreachable aggregator is a silent skip (pull +
# TTL still converge) and never fails the purge or throws.
try {
    if ($PSCmdlet.ShouldProcess('pool-aggregator-service :9400', (Format-YurunaOperatorMessage -Key 'runner.operator_243d23ca0fc2d079' -Arguments @{ hostId = "$HostId" }))) {
        if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
            try { $null = Import-Extension -Area 'authentication' -RequireSingle } catch { $null = $_ }
        }
        # Resolve ONLY when a declared + populated internal-auth-key vault entry exists;
        # an empty vaultKey means push/forget is off (calling Get-Password then
        # would auto-generate a junk per-host token the aggregator would reject).
        # 'internal-auth-key' first, then the legacy 'lab-auth-token' and
        # 'pool-auth-token' names, so a host enrolled under an older one can still evict.
        $token = ''
        if ((Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -and (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
            try {
                foreach ($logical in @('internal-auth-key', 'lab-auth-token', 'pool-auth-token')) {
                    $eff = Get-EffectiveUser -LogicalUser $logical
                    if ($eff.vaultKey -and (Test-VaultEntry -VaultKey $eff.vaultKey)) { $token = [string](Get-Password -Username $logical); break }
                }
            } catch { $null = $_ }
        }
        $proxyIp = ''
        if (Get-Command Read-CachingProxyServiceState -ErrorAction SilentlyContinue) {
            try { $st = Read-CachingProxyServiceState; if ($st -and $st.ipAddress) { $proxyIp = [string]$st.ipAddress } } catch { $null = $_ }
        }
        if ([string]::IsNullOrWhiteSpace($proxyIp) -and $env:YURUNA_CACHING_PROXY_SERVICE_IP) { $proxyIp = $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() }

        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Verbose 'forget-host: no internal authentication key configured; skipping live-view eviction (the panel clears on the aggregator host TTL).'
        } elseif ([string]::IsNullOrWhiteSpace($proxyIp)) {
            Write-Verbose 'forget-host: no caching-proxy-service IP known; skipping live-view eviction.'
        } elseif (Get-Command Invoke-PoolForgetHost -ErrorAction SilentlyContinue) {
            $f = Invoke-PoolForgetHost -ProxyIp $proxyIp -HostId $HostId -Token $token -RuntimeDir $runtimeDir
            if ($f.ok) { [void]$removed.Add("dashboard view   pool-aggregator-service forgot $HostId") }
            else { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_e2c9fb708e765fa2' -Arguments @{ shownHostId = "$shownHostId"; reason = "$($f.reason)" }) }
        }
    }
} catch {
    Write-Warning "forget-host (non-fatal): $($_.Exception.Message)"
}

# --- REGION: Summary
if ($removed.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8417703f46733c00' -Arguments @{ shownHostId = "${shownHostId}" }) -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_63f2c3fd9bb2e4f0' -Arguments @{ shownHostId = "${shownHostId}" }) -InformationAction Continue
    foreach ($r in $removed) { Write-Information "  - $r" -InformationAction Continue }
}
# Membership and the dashboard eviction already ran; only the NAS delete is unfinished,
# and re-running is a safe no-op for everything that did succeed.
if ($storageIncomplete) {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f9654b9bc37f4396' -Arguments @{ shownHostId = "${shownHostId}"; localPath = "$localPath" }) -ErrorAction Continue
    exit $ExitFailure
}
exit $ExitOk
