<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456725
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

# Capability matrix. Snapshots per-host runtime decisions (OCR engines,
# host I/O backends, active extensions) at startup so a missing backend
# fails the cycle plan up front, not three steps deep with "Unknown host:".
# Rationale and banner format: https://yuruna.link/capability-matrix

Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1')         -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.OcrEngine.psm1')       -Global -Force
Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1')  -Global -Force

# Per-action capability requirements live in Test.SequenceAction's
# registry. Get-CapabilityActionRequirement below is a thin facade
# over Get-SequenceActionRequirementMap so existing callers don't
# have to migrate immediately. The registry is populated at
# Test.SequenceEngine.psm1 load time, which imports Test.SequenceHandler.psm1;
# that module's Register-SequenceAction blocks fill the registry.

function Get-CapabilityActionRequirement {
    <#
    .SYNOPSIS
        Return the action -> required-capability map. Sources from
        Test.SequenceAction's registry, which is the single source
        of truth for the verb -> required-capability mapping.
    #>
    if (Get-Command Get-SequenceActionRequirementMap -ErrorAction SilentlyContinue) {
        return Get-SequenceActionRequirementMap
    }
    Write-Verbose 'Get-CapabilityActionRequirement: Test.SequenceAction not loaded; returning empty map.'
    return [ordered]@{}
}

function Get-CapabilityExtensionArea {
    <#
    .SYNOPSIS
        Snapshot of active extension names per area. Returns an ordered
        hashtable; missing files / unparseable configs are folded into
        an empty array for that area so the matrix never throws on a
        partially-configured operator setup.
    .DESCRIPTION
        Areas are discovered by directory presence under test/extension/
        rather than hardcoded -- adding a new area automatically appears
        in the matrix.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([string]$RepoRoot)
    if (-not $RepoRoot) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
    $extRoot = Join-Path $RepoRoot 'test/extension'
    $out = [ordered]@{}
    if (-not (Test-Path -LiteralPath $extRoot)) { return $out }
    foreach ($dir in (Get-ChildItem -LiteralPath $extRoot -Directory | Sort-Object Name)) {
        $cfgPath = Join-Path $dir.FullName "$($dir.Name).config.yml"
        $active = @()
        if (Test-Path -LiteralPath $cfgPath) {
            try {
                $cfg = Get-Content -Raw -LiteralPath $cfgPath -ErrorAction Stop |
                    ConvertFrom-Yaml -Ordered -ErrorAction Stop
                if ($cfg -is [System.Collections.IDictionary] -and $cfg.Contains('active') -and $cfg.active) {
                    $active = @($cfg.active)
                }
            } catch {
                Write-Verbose "Get-CapabilityExtensionArea: $($dir.Name) config unreadable: $($_.Exception.Message)"
            }
        }
        $out[$dir.Name] = $active
    }
    return $out
}

function Get-HostCapabilityMatrix {
    <#
    .SYNOPSIS
        Snapshot the harness's capabilities on the current host. Pure data,
        no side effects. Consumed by Write-HostCapabilityBanner and
        Test-CyclePlanCapability.
    .PARAMETER HostType
        Target host identifier ('host.windows.hyper-v', 'host.macos.utm',
        'host.ubuntu.kvm'). Defaults to the value of Get-HostType -- the
        live local host.
    .PARAMETER RepoRoot
        Repo root used to find test/extension/. Defaults to two levels
        above this module.
    .OUTPUTS
        @{ hostType; hostIO=@(actions); ocr=@(providers); extensions={ area=>active[] } }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$HostType,
        [string]$RepoRoot
    )
    if (-not $HostType) {
        if (Get-Command Get-HostType -ErrorAction SilentlyContinue) { $HostType = Get-HostType }
    }
    $matrix = Get-HostIOProviderMatrix
    $hostIO = @()
    if ($HostType -and $matrix.Contains($HostType)) { $hostIO = @($matrix[$HostType]) }
    $ocr = @()
    if (Get-Command Get-EnabledOcrProvider -ErrorAction SilentlyContinue) {
        $ocr = @(Get-EnabledOcrProvider)
    }
    # Recovery providers: whether a per-host VNC reconnect / fast-path
    # screenshot provider is registered. The repair primitives work with zero
    # providers (Repair-VncConnection clears the cached handle either way), so
    # this surfaces the optional per-host layer, and makes the recovery wiring
    # visible at cycle start instead of silently re-rotting into a no-op.
    $vncReconnect = $false
    if ($HostType -and (Get-Command Test-VncProviderAvailable -ErrorAction SilentlyContinue)) {
        $vncReconnect = [bool](Test-VncProviderAvailable -HostType $HostType)
    }
    $screenshotProvider = $false
    if ($HostType -and (Get-Command Test-ScreenshotProviderAvailable -ErrorAction SilentlyContinue)) {
        $screenshotProvider = [bool](Test-ScreenshotProviderAvailable -HostType $HostType)
    }
    $extensions = Get-CapabilityExtensionArea -RepoRoot $RepoRoot
    return @{
        hostType           = $HostType
        hostIO             = $hostIO
        ocr                = $ocr
        vncReconnect       = $vncReconnect
        screenshotProvider = $screenshotProvider
        extensions         = $extensions
    }
}

function Write-HostCapabilityBanner {
    <#
    .SYNOPSIS
        Print the matrix to the Information stream as a single block.
        Designed to land in the cycle HTML log via Yuruna.Log's stream
        proxy so post-mortem readers see what was actually wired at
        cycle start.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$Matrix
    )
    if (-not $Matrix) { $Matrix = Get-HostCapabilityMatrix }
    $sep = '---------------------------------------------------------'
    Write-Information ''
    Write-Information $sep
    Write-Information "Yuruna capability matrix ($($Matrix.hostType))"
    Write-Information $sep
    $hostIO = if ($Matrix.hostIO.Count) { ($Matrix.hostIO | Sort-Object) -join ', ' } else { '(none registered)' }
    Write-Information "  Host I/O:   $hostIO"
    $ocr = if ($Matrix.ocr.Count) { ($Matrix.ocr -join ', ') } else { '(none available)' }
    Write-Information "  OCR:        $ocr"
    $vncR = if ($Matrix.vncReconnect) { 'per-host provider' } else { 'built-in (clear cached handle)' }
    $ssR  = if ($Matrix.screenshotProvider) { 'fast-path provider' } else { 'legacy capture' }
    Write-Information "  Recovery:   VNC reconnect ($vncR), screenshot ($ssR)"
    if ($Matrix.extensions.Keys.Count) {
        Write-Information '  Extensions:'
        foreach ($area in $Matrix.extensions.Keys) {
            $names = $Matrix.extensions[$area]
            $shown = if ($names.Count) { $names -join ', ' } else { '(no active)' }
            Write-Information ("    {0,-22} {1}" -f $area, $shown)
        }
    }
    Write-Information $sep
}

function Get-SequenceActionsUsed {
    <#
    .SYNOPSIS
        Walk one or more sequence YAML files and return the set of action
        verbs that appear in any step (including nested `retry` blocks).
    .DESCRIPTION
        Uses Read-SequenceFile from Test.SequenceEngine.psm1 when available
        (centralized parser + caching); falls back to a direct
        ConvertFrom-Yaml read so the function is usable from contexts
        that load this module without the engine.
    .OUTPUTS
        [string[]] sorted unique action names.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)][string[]]$SequencePath
    )
    $verbs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in $SequencePath) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Verbose "Get-SequenceActionsUsed: missing $path; skipping."
            continue
        }
        try {
            $cfg = if (Get-Command Read-SequenceFile -ErrorAction SilentlyContinue) {
                Read-SequenceFile -Path $path
            } else {
                Get-Content -Raw -LiteralPath $path -ErrorAction Stop |
                    ConvertFrom-Yaml -Ordered -ErrorAction Stop
            }
        } catch {
            Write-Verbose "Get-SequenceActionsUsed: parse failed for $path : $($_.Exception.Message); skipping."
            continue
        }
        if (-not $cfg -or -not $cfg.steps) { continue }
        Add-SequenceActionFromStep -Steps $cfg.steps -Verbs $verbs
    }
    return @($verbs | Sort-Object)
}

function Add-SequenceActionFromStep {
    # Private. Recurses through retry-nested steps so a retry block's
    # inner verbs count toward the cycle's verb set.
    #
    # $Verbs is NOT marked Mandatory: an empty HashSet trips the
    # parameter binder's "Cannot bind argument because it is an empty
    # collection" check (pwsh treats any non-null IEnumerable that
    # yields zero items as "no value"). The caller always supplies a
    # set; missing here would throw on first .Add().
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Mutates the caller-supplied HashSet only; no externally observable state.')]
    param(
        $Steps,
        [System.Collections.Generic.HashSet[string]]$Verbs
    )
    if (-not $Steps -or -not $Verbs) { return }
    foreach ($step in $Steps) {
        if ($step -is [System.Collections.IDictionary] -and $step.Contains('action')) {
            [void]$Verbs.Add([string]$step.action)
            if ($step.Contains('steps') -and $step.steps) {
                Add-SequenceActionFromStep -Steps $step.steps -Verbs $Verbs
            }
        }
    }
}

function Test-CyclePlanCapability {
    <#
    .SYNOPSIS
        Cross-check a cycle plan against the current host's capability
        matrix. Returns @{ supported=[bool]; missing=@{...} } so the
        caller decides how to react (warn vs hard-fail).
    .PARAMETER SequencePath
        Flat list of YAML sequence files in the plan. The runner gets
        this from the cycle plan's chainPaths entries.
    .PARAMETER HostType
        Defaults to Get-HostType.
    .OUTPUTS
        @{
          supported    = $true | $false
          hostType     = '...'
          actionsUsed  = @(...)        # all verbs found in the plan
          unknownActions = @(...)      # not in the requirement table (likely typo or new verb)
          missingHostIO  = @(...)      # required by some action, not registered on this host
          ocrRequired    = $true | $false
          ocrAvailable   = $true | $false
        }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string[]]$SequencePath,
        [string]$HostType
    )
    if (-not $HostType) {
        if (Get-Command Get-HostType -ErrorAction SilentlyContinue) { $HostType = Get-HostType }
    }
    $verbs = Get-SequenceActionsUsed -SequencePath $SequencePath
    $reqMap = Get-CapabilityActionRequirement
    $unknown    = New-Object System.Collections.Generic.List[string]
    $hostIOReq  = New-Object System.Collections.Generic.HashSet[string]
    $ocrReq     = $false
    foreach ($v in $verbs) {
        if (-not $reqMap.Contains($v)) {
            [void]$unknown.Add($v)
            continue
        }
        $req = $reqMap[$v]
        foreach ($a in $req.HostIO) { [void]$hostIOReq.Add($a) }
        if ($req.OcrRequired) { $ocrReq = $true }
    }
    $missingHostIO = @()
    foreach ($action in $hostIOReq) {
        if (-not (Test-HostIOActionAvailable -HostType $HostType -Action $action)) {
            $missingHostIO += $action
        }
    }
    $ocrAvailable = $false
    if (Get-Command Get-EnabledOcrProvider -ErrorAction SilentlyContinue) {
        $ocrAvailable = @(Get-EnabledOcrProvider).Count -gt 0
    }
    $supported = ($missingHostIO.Count -eq 0) -and (-not ($ocrReq -and -not $ocrAvailable))
    return @{
        supported      = $supported
        hostType       = $HostType
        actionsUsed    = $verbs
        unknownActions = @($unknown | Sort-Object)
        missingHostIO  = @($missingHostIO | Sort-Object)
        ocrRequired    = $ocrReq
        ocrAvailable   = $ocrAvailable
    }
}

function Get-CyclePlanSequencePath {
    <#
    .SYNOPSIS
        Resolve every sequence name in a cycle plan to its YAML path.
        Caller-facing helper for Test-CyclePlanCapabilityFromPlan.
    .DESCRIPTION
        Walks each plan entry's fullChain and calls Resolve-SequencePath
        (from Test.SequenceEngine.psm1) per name. Missing names are logged
        Verbose and skipped -- the planner already throws PlannerFatal for
        true misses, so missing here means a transient file-system race.
    .OUTPUTS
        [string[]] of absolute paths, deduplicated, in plan order.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$HostType
    )
    if (-not (Get-Command Resolve-SequencePath -ErrorAction SilentlyContinue)) {
        throw "Get-CyclePlanSequencePath: Test.SequenceEngine.psm1 must be imported (Resolve-SequencePath not found)."
    }
    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Plan) {
        foreach ($name in $entry.fullChain) {
            $p = Resolve-SequencePath -SequencesDir $SequencesDir -Name $name -HostType $HostType -RepoRoot $RepoRoot
            if (-not $p) { Write-Verbose "Get-CyclePlanSequencePath: $name not resolved (skipping)."; continue }
            if ($seen.Add($p)) { [void]$paths.Add($p) }
        }
    }
    return @($paths.ToArray())
}

function Test-CyclePlanCapabilityFromPlan {
    <#
    .SYNOPSIS
        Convenience wrapper: resolve plan -> paths, then run
        Test-CyclePlanCapability. Used by Invoke-TestRunnerInnerLoop.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [string]$HostType
    )
    if (-not $HostType) {
        if (Get-Command Get-HostType -ErrorAction SilentlyContinue) { $HostType = Get-HostType }
    }
    $paths = Get-CyclePlanSequencePath -Plan $Plan -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType
    if (-not $paths -or $paths.Count -eq 0) {
        # No paths means an empty plan; treat as supported so the cycle
        # falls through to whatever Get-GuestList-based legacy path exists.
        return @{ supported = $true; hostType = $HostType; actionsUsed = @(); unknownActions = @(); missingHostIO = @(); ocrRequired = $false; ocrAvailable = $false }
    }
    return (Test-CyclePlanCapability -SequencePath $paths -HostType $HostType)
}

function Write-HostRegistrationRecord {
    <#
    .SYNOPSIS
        Externalize this host's identity + capabilities as
        runtime/host.registration.json (served by the status service at
        /runtime/host.registration.json) for the multi-host pool-aggregator service /
        pool-planner. Best-effort; never throws -- telemetry must not fail a cycle.
    .DESCRIPTION
        Built from Get-HostCapabilityMatrix + the process host identity so a pool
        consumer learns each host's hostId / platform / hostIO / OCR / extensions
        without SSHing in. Identity + capability only (mostly static); LIVE runner
        state is NOT mirrored here -- status.json + the heartbeat already carry it.
        The one exception is `network`, which reports a degraded-but-running guest
        network: the host keeps passing cycles in that state, so no cycle verdict a
        pool consumer can read ever names it.
        Written once per cycle at runner startup on the MAIN runspace, never from
        the heartbeat threadpool timer (the scriptblock-as-TimerCallback trap).
        Resolves the runtime dir + hostId from $env:YURUNA_RUNTIME_DIR +
        $global:__YurunaHostId (set by the entry point) rather than calling into
        Test.YurunaDir, to avoid foreign-module command-resolution surprises.
        capacity/ipPool/disk/supportedGuests are reserved (null) for Horizon B
        + the pool-planner, so those become a data-population step
        rather than a re-architecture. Atomic temp+rename so a polling consumer
        never reads a half-written record.
    .OUTPUTS
        System.String -- the path written, or $null on a (swallowed) failure.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort single-file telemetry write; never throws, overwrite is idempotent.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the $global:__YurunaHostId / __YurunaRunId cross-host identity channels set by the entry point.')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [string]$RepoRoot
    )
    try {
        $runtimeDir = $env:YURUNA_RUNTIME_DIR
        if (-not $runtimeDir -or -not (Test-Path -LiteralPath $runtimeDir)) { return $null }
        $cap = Get-HostCapabilityMatrix -HostType $HostType -RepoRoot $RepoRoot
        # host.windows.hyper-v -> hyper-v ; host.ubuntu.kvm -> kvm ; host.macos.utm -> utm
        $hypervisor = ($HostType -replace '^host\.[^.]+\.', '')
        # poolId: this host's pool, DERIVED by the outer loop's pool-sync from
        # pools.yml members[] (the single source of truth) and persisted to
        # runtime/pool.state.json -- the cross-process channel, since this writer
        # runs in the FRESH inner process that does not inherit the outer's
        # $global. null when unpooled or intent not yet pulled (the aggregator then
        # falls back to its own pool label). Read inline so Test.Capability keeps no
        # dependency on Test.PoolSync.
        # gating: the pool's advisory alert policy, carried alongside poolId in
        # pool.state.json (null when the pool authored none). Forwarded verbatim so the
        # aggregator parses the thresholds; a null/absent gating tells it to observe the
        # pool's gauges but never page it.
        # poolGuid: the pool's stable 42-GUID (the dashboard "Pool ID"), carried
        # alongside poolId in pool.state.json. Advertised so the aggregator can
        # label host_info with it. null when unpooled.
        $poolId   = $null
        $poolGuid = $null
        $gating   = $null
        try {
            $poolStatePath = Join-Path $runtimeDir 'pool.state.json'
            if (Test-Path -LiteralPath $poolStatePath) {
                $ps = Get-Content -Raw -LiteralPath $poolStatePath | ConvertFrom-Json -ErrorAction Stop
                if ($ps -and -not [string]::IsNullOrWhiteSpace([string]$ps.poolId))   { $poolId   = [string]$ps.poolId }
                if ($ps -and -not [string]::IsNullOrWhiteSpace([string]$ps.poolGuid)) { $poolGuid = [string]$ps.poolGuid }
                if ($ps -and ($null -ne $ps.gating)) { $gating = $ps.gating }
            }
        } catch { $null = $_ }
        # statusPort: the real status-service port so the aggregator can deep-link
        # without assuming 8080. Best-effort from statusService.port; null otherwise.
        $statusPort = $null
        try {
            if ($env:YURUNA_CONFIG_PATH -and (Test-Path -LiteralPath $env:YURUNA_CONFIG_PATH) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
                $cfgDoc = Get-Content -Raw -LiteralPath $env:YURUNA_CONFIG_PATH | ConvertFrom-Yaml -Ordered
                if ($cfgDoc -and $cfgDoc['statusService'] -and $cfgDoc['statusService']['port']) { $statusPort = [int]$cfgDoc['statusService']['port'] }
            }
        } catch { $null = $_ }
        # activeExtensions: the extension areas this host is ACTIVELY running right
        # now (distinct from capabilities.extensions, which is what it COULD run --
        # true for every host). The pool-aggregator-service reads this to populate the
        # dashboard's Extension hosts table WITHOUT mounting ystash-nas (no cross-host
        # config service / NAS-credential dependency). Driven by per-service runtime
        # markers a host writes when it brings a service up -- Start-StashServiceVM.ps1
        # writes runtime/stash-service.json; Stop-StashServiceVM.ps1 removes it. File I/O
        # only (no foreign-module calls), matching this function's resolution policy.
        # extensionTargets carries the per-area deep-link the host advertises for its
        # service (the stash-service VM's UI base URL the host resolved via Get-VMIp into the
        # marker's stashBaseUrl), so the aggregator can /go/stash to it without an
        # address store of its own.
        $activeExtensions = @()
        $extensionTargets = [ordered]@{}
        try {
            $stashMarker = Join-Path $runtimeDir 'stash-service.json'
            if (Test-Path -LiteralPath $stashMarker) {
                $sm = Get-Content -Raw -LiteralPath $stashMarker | ConvertFrom-Json -ErrorAction Stop
                # Marker presence = active; an explicit active:false clears it.
                if ($null -eq $sm.active -or [bool]$sm.active) {
                    $activeExtensions += 'stash-service'
                    if (-not [string]::IsNullOrWhiteSpace([string]$sm.stashBaseUrl)) {
                        $extensionTargets['stash-service'] = [string]$sm.stashBaseUrl
                    }
                }
            }
        } catch { Write-Verbose "activeExtensions (stash-service.json): $($_.Exception.Message)" }
        # pool-control-service: the Pool control service marker (runtime/pool-control-service.json,
        # written by Start-PoolControlServiceVM.ps1). Same contract as the stash marker
        # -- presence = active, and poolControlServiceBaseUrl is the deep-link the aggregator
        # surfaces from the Extension hosts table.
        try {
            $pcMarker = Join-Path $runtimeDir 'pool-control-service.json'
            if (Test-Path -LiteralPath $pcMarker) {
                $pc = Get-Content -Raw -LiteralPath $pcMarker | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $pc.active -or [bool]$pc.active) {
                    $activeExtensions += 'pool-control-service'
                    if (-not [string]::IsNullOrWhiteSpace([string]$pc.poolControlServiceBaseUrl)) {
                        $extensionTargets['pool-control-service'] = [string]$pc.poolControlServiceBaseUrl
                    }
                }
            }
        } catch { Write-Verbose "activeExtensions (pool-control-service.json): $($_.Exception.Message)" }
        # projectUrl / projectCommit / testSets: what this host's CURRENT project
        # offers, so the pool-control service can build its library of assignable
        # test sets without ever cloning a project itself -- the host already has
        # the clone, and its GH_TOKEN never has to leave it.
        #
        # Read from runtime markers + the project clone that the cycle already
        # produced; file I/O and one already-imported planner call only, matching
        # this function's resolution policy. Every branch is best-effort: a
        # project that cannot be read simply reports nothing, because a
        # discovery nicety must never be able to fail a registration write.
        #
        # NOTE (ordering): this record is written in Phase 0, BEFORE the pooled
        # repos override and the project clone refresh. So these three fields
        # describe the project as of the PREVIOUS cycle's clone. That is
        # acceptable for a discovery offer -- the set list changes only when a
        # project commits -- but it is why the board can lag one cycle behind a
        # brand-new assignment.
        $projectUrl = $null; $projectCommit = $null; $projectTestSets = @()
        try {
            $projectDir = Join-Path (Split-Path -Parent $runtimeDir) 'project'
            $repoRootForProject = Split-Path -Parent (Split-Path -Parent $runtimeDir)
            if (Test-Path -LiteralPath (Join-Path $projectDir '.git')) {
                $u = & git -C $projectDir config --get remote.origin.url 2>$null
                if ($LASTEXITCODE -eq 0 -and $u) { $projectUrl = "$u".Trim() }
                $c = & git -C $projectDir rev-parse --short HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $c) { $projectCommit = "$c".Trim() }
            }
            if (Get-Command Get-ProjectTestSet -ErrorAction SilentlyContinue) {
                # -WarningAction SilentlyContinue: malformed optional labels are
                # already warned about at cycle start; repeating them on every
                # registration write would be noise.
                $sets = Get-ProjectTestSet -RepoRoot $repoRootForProject -WarningAction SilentlyContinue
                $projectTestSets = @(foreach ($s in $sets) {
                    [ordered]@{
                        name        = [string]$s['name']
                        displayName = [string]$s['displayName']
                        description = [string]$s['description']
                        sequences   = @($s['sequences'])
                    }
                })
            }
        } catch { Write-Verbose "project test-set discovery: $($_.Exception.Message)" }
        # projectAccess: the result of this host's last probe of a POOL-ASSIGNED
        # projectUrl (Test.RunnerInnerLoop writes the marker). Absent on an
        # unpooled host, or on a pooled host whose pool assigned nothing.
        $projectAccess = $null
        try {
            $accessMarker = Join-Path $runtimeDir 'project.access.json'
            if (Test-Path -LiteralPath $accessMarker) {
                $projectAccess = Get-Content -Raw -LiteralPath $accessMarker | ConvertFrom-Json -ErrorAction Stop
            }
        } catch { Write-Verbose "projectAccess marker: $($_.Exception.Message)" }
        # network: this host's guest-network topology when it is NOT the healthy
        # one. A Hyper-V vSwitch object outlives its uplink binding across a host
        # reboot, so a host can be fully online, pass every host check, and still
        # attach every guest to a switch with no carrier -- a state the cycle
        # verdict alone cannot express, because such a host keeps running and
        # passing on the Default Switch (NAT + DHCP). Absent marker = healthy, so
        # the field stays null and an aggregator that never learned about it is
        # unaffected. Read as a file, matching this function's resolution policy.
        $network = $null
        try {
            $networkMarker = Join-Path $runtimeDir 'host-network.json'
            if (Test-Path -LiteralPath $networkMarker) {
                $nm = Get-Content -Raw -LiteralPath $networkMarker | ConvertFrom-Json -ErrorAction Stop
                if ($nm -and [bool]$nm.degraded) {
                    # ConvertFrom-Json rehydrates an ISO-8601 timestamp as a
                    # [datetime] in LOCAL time, so a plain string cast would
                    # republish a locale-formatted, zone-less value that no pool
                    # consumer can parse back into an instant. Re-emit UTC Z.
                    $sinceUtc = if ($nm.sinceUtc -is [DateTime]) {
                        ([DateTime]$nm.sinceUtc).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                    } else {
                        [string]$nm.sinceUtc
                    }
                    $network = [ordered]@{
                        externalSwitch = [string]$nm.externalSwitch
                        verdict        = [string]$nm.verdict
                        degraded       = $true
                        sinceUtc       = $sinceUtc
                    }
                }
            }
        } catch { Write-Verbose "host-network marker: $($_.Exception.Message)" }
        $record = [ordered]@{
            schemaVersion    = 1
            hostId           = [string]$global:__YurunaHostId
            hostname         = [string]([System.Net.Dns]::GetHostName())
            hostType         = $HostType
            hypervisor       = $hypervisor
            poolId           = $poolId
            poolGuid         = $poolGuid
            gating           = $gating
            capabilities     = $cap
            activeExtensions = $activeExtensions
            extensionTargets = $extensionTargets
            projectUrl       = $projectUrl
            projectCommit    = $projectCommit
            testSets         = $projectTestSets
            projectAccess    = $projectAccess
            network          = $network
            runId           = [string]$global:__YurunaRunId
            pid             = $PID
            statusPort      = $statusPort
            writtenAtUtc    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            # Reserved for the Horizon B resilience gates (IP/capacity admission,
            # caching-proxy-service circuit breaker, disk headroom -- docs/opportunities.md)
            # + the pool-planner's host selection; populated when those land.
            capacity        = $null
            ipPool          = $null
            disk            = $null
            supportedGuests = $null
        }
        $path = Join-Path $runtimeDir 'host.registration.json'
        $tmp  = "$path.tmp"
        # -Depth 10: capacity/ipPool/disk gain a nested object when Horizon B
        # populates them, beyond ConvertTo-Json's default depth that would
        # silently serialize a deeper level as "@{...}".
        $json = $record | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $path
    } catch {
        Write-Verbose "Write-HostRegistrationRecord: $($_.Exception.Message)"
        return $null
    }
}

Export-ModuleMember -Function Get-CapabilityActionRequirement, Get-CapabilityExtensionArea, Get-HostCapabilityMatrix, Write-HostCapabilityBanner, Get-SequenceActionsUsed, Test-CyclePlanCapability, Get-CyclePlanSequencePath, Test-CyclePlanCapabilityFromPlan, Write-HostRegistrationRecord
