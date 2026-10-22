<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42fb91f9-ac3c-48ec-849f-108167698afd
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

# See https://yuruna.link/4213a0b3-00b5

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RunnerHeartbeat.psm1') -DisableNameChecking
function Test-IsOrchestrationSequence {
    <#
    .SYNOPSIS
        $true when a parsed sequence is an orchestration sequence: no
        `baseline:`, a non-empty `steps:`, and a first step whose action
        is InvokeTestSequence. Mixed/other actions are validated per-step
        by Invoke-OrchestrationSequence, not here.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Sequence)
    if ($Sequence -isnot [System.Collections.IDictionary]) { return $false }
    if ($Sequence.Contains('baseline')) { return $false }
    if (-not $Sequence.Contains('steps') -or -not $Sequence['steps']) { return $false }
    $first = @($Sequence['steps'])[0]
    if ($first -isnot [System.Collections.IDictionary] -or -not $first.Contains('action')) { return $false }
    return ([string]$first['action'] -eq 'InvokeTestSequence')
}

function Test-IsElevatedHost {
    # Windows-only privilege probe for host.elevated inner sequences. On
    # non-Windows hosts elevation semantics differ (sudo/polkit), so assume
    # the operator arranged privileges and let the host script fail if not.
    if (-not $IsWindows) { return $true }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-CycleStepEvent {
    <#
    .SYNOPSIS
        Record a step boundary as data, beside the transcript line that shows it.
    .DESCRIPTION
        The outcome travels as a stable lower-case token rather than the word
        the rule prints. PASS and FAIL are what a reader sees; a consumer that
        matched on them would be reading a rendered value, which is the shape
        this exists to stop.

        Best-effort by construction: the writer swallows its own failures, and
        a cycle must not fail because a telemetry line could not be appended.
        Guarded by Get-Command so an entry point whose module set omits
        Test.Log runs exactly as it did before.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Append-only telemetry through a writer that is itself best-effort.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('start', 'end')][string]$Phase,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [AllowEmptyString()][string]$Kind = '',
        [AllowEmptyString()][string]$Outcome = ''
    )
    if (-not (Get-Command Write-CycleNdjsonEvent -ErrorAction SilentlyContinue)) { return }
    # Written out whole rather than composed from the phase. A code assembled
    # at run time cannot be searched for: nobody grepping the tree for
    # "step.start" finds the place that emits it, and the code registry cannot
    # verify that this file carries what it claims to carry. Half the value of
    # a stable code is that looking for it works.
    $eventName = switch ($Phase) {
        'start' { 'step.start' }
        'end'   { 'step.end' }
    }
    $record = @{
        event = $eventName
        index = $Index
        total = $Total
        name  = $Name
        kind  = $Kind
    }
    if ($Outcome) { $record['outcome'] = $Outcome.ToLowerInvariant() }
    try { Write-CycleNdjsonEvent -EventRecord $record } catch { Write-Verbose "step event not recorded: $($_.Exception.Message)" }
}

function Write-OrchestratorLine {
    # Progress output to the INFORMATION stream (not the success stream): these
    # functions return values the caller captures ($rc = Invoke-...), so a
    # Write-Output here would be swallowed into that value, and Write-OrchestratorLine is
    # flagged by PSScriptAnalyzer. -InformationAction Continue makes it display
    # and be captured by the cycle-log transcript. Same convention as
    # Test.SequenceRunner's chain-progress output.
    # -Tail keeps the last lines for a caller that will need to quote them
    # (a host action's failure reason); the transcript tee is unchanged.
    param(
        [Parameter(ValueFromPipeline)][object]$Message,
        [AllowNull()][System.Collections.Generic.List[string]]$Tail
    )
    process {
        if ($null -ne $Tail) { Add-OrchestratorOutputTail -Tail $Tail -Line "$Message" }
        Write-Information $Message -InformationAction Continue
    }
}

function Add-OrchestratorOutputTail {
    <#
    .SYNOPSIS
        Keep the last lines a host action printed, plain text, bounded.
    .DESCRIPTION
        The transcript keeps everything; this keeps only what a failure reason
        can quote. Console color sequences are stripped so the line reads the
        same in a JSON record as on the screen, and the list never grows past
        -Limit entries.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowNull()][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Tail,
        [AllowNull()][AllowEmptyString()][string]$Line,
        [ValidateRange(1, 1000)][int]$Limit = 40
    )
    if ($null -eq $Tail) { return }
    $plain = ("$Line" -replace '\x1b\[[0-9;?]*[ -/]*[@-~]', '').Trim()
    if (-not $plain) { return }
    $Tail.Add($plain)
    while ($Tail.Count -gt $Limit) { $Tail.RemoveAt(0) }
}

function Get-OrchestratorHostActionDetail {
    <#
    .SYNOPSIS
        The one line of a failed host action's output worth putting in the
        failure reason: its last error line, else its last line.
    .DESCRIPTION
        A host action that exits non-zero has usually said why on its last
        Write-Error, and the orchestrator's own reason ("exited 1") loses it:
        the sentence survives only in the transcript, which the dashboard and
        the failure record never quote. The error prefix the console adds is
        dropped; the text is capped so a record stays a record.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][System.Collections.Generic.List[string]]$Tail,
        [ValidateRange(40, 4000)][int]$MaxLength = 600
    )
    if ($null -eq $Tail -or $Tail.Count -eq 0) { return '' }
    $errorPattern = '^(Write-Error:\s*|ERROR:\s*|Error:\s*)'
    $pick = ''
    for ($i = $Tail.Count - 1; $i -ge 0; $i--) {
        if ($Tail[$i] -match $errorPattern) { $pick = $Tail[$i] -replace $errorPattern, ''; break }
    }
    if (-not $pick) { $pick = $Tail[$Tail.Count - 1] }
    $pick = $pick.Trim()
    if ($pick.Length -gt $MaxLength) { $pick = $pick.Substring(0, $MaxLength - 3) + '...' }
    return $pick
}

function Invoke-OrchestratorHostAction {
    <#
    .SYNOPSIS
        Run an inner host-action sequence (`host:` block) on the host:
        the sibling script(s) named in host.script (single) or
        host.scripts (ordered, stop at first non-zero). Honors
        host.elevated / host.arguments. Returns the exit code (0 = pass).
        With -OutputTail, the last lines the scripts printed are appended to
        that list (color sequences stripped) for the caller's failure reason.
    .NOTES
        DESIGN -- console vs. HTML transcript for host-action stages.
        The host script's own stdout and stderr are routed through the
        information stream below, which the Yuruna.Log proxy tees into THIS
        cycle's HTML transcript. The proxy only wraps the Write-* cmdlets, so
        output handed straight to the console host would reach the terminal
        and no artifact. But a host script is free to fan its real work out
        into child processes with their OWN redirected output -- e.g. the
        AmisAd set-resource.yml runs Set-Resource.ps1, whose Invoke-Stage
        launches each guest build as a hidden child `pwsh` (Start-Process
        -WindowStyle Hidden -RedirectStandardOutput <name>.out.log). When it
        does, the parent console shows ONLY the boundary lines the host
        script writes directly (`===== [<name>] ... =====` / `exited N`);
        the per-stage step-by-step detail is NOT on the console. That detail
        still lands in two places: (a) the redirected <name>.out.log file,
        and (b) each child's OWN per-cycle HTML transcript -- every child
        Debug-TestSequence.ps1 run calls Start-LogFile and gets its own
        <cycle>.html under status/log/. This divergence is intentional
        (stages are quiet on the console, verbose in their own logs; the
        child's out/err tail is echoed to the console only on non-zero
        exit). It is a property of the host script, not of this dispatcher:
        the orchestrator streams whatever the host script emits and does not
        reach into the child processes it spawns.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]$Sequence,
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][System.Collections.Generic.List[string]]$OutputTail
    )
    $hostBlock = $Sequence['host']
    $elevated  = $hostBlock.Contains('elevated') -and [bool]$hostBlock['elevated']
    $hostArgs  = @()
    if ($hostBlock.Contains('arguments') -and $hostBlock['arguments']) {
        $hostArgs = @($hostBlock['arguments'] | ForEach-Object { [string]$_ })
    }
    $scriptNames = @()
    if ($hostBlock.Contains('scripts') -and $hostBlock['scripts']) {
        $scriptNames = @($hostBlock['scripts'] | ForEach-Object { [string]$_ })
    } elseif ($hostBlock.Contains('script') -and -not [string]::IsNullOrWhiteSpace([string]$hostBlock['script'])) {
        $scriptNames = @([string]$hostBlock['script'])
    }
    if ($scriptNames.Count -eq 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c6c3099b644345dc' -Arguments @{ name = "$Name" })
        return 1
    }
    if ($elevated -and -not (Test-IsElevatedHost)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_11dd313197e1d9c6' -Arguments @{ name = "$Name" })
        return 1
    }
    $pwshExe = if (Get-Command Get-PwshExePath -ErrorAction SilentlyContinue) { Get-PwshExePath } else { 'pwsh' }
    $entryDir = Split-Path -Parent $SequencePath
    $exitCode = 0
    foreach ($scriptName in $scriptNames) {
        $scriptPath = Join-Path $entryDir $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_5a564e98a029d970' -Arguments @{ name = "$Name"; scriptPath = "$scriptPath" })
            return 1
        }
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_4ed4aab44d7af64a' -Arguments @{ scriptPath = "$scriptPath"; join = "$($hostArgs -join ' ')"; elevated = "$(if ($elevated) { ' (elevated)' })" })
        # See https://yuruna.link/4213a0b3-00b6
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @hostArgs 2>&1 | Write-OrchestratorLine -Tail $OutputTail
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { break }
    }
    return $exitCode
}

function Invoke-OrchestratorGuestRun {
    <#
    .SYNOPSIS
        Run one inner GUEST sequence (baseline + steps) in-process: build
        the chain plan, ensure/start the VM, and run the whole chain via
        Invoke-TestSequenceChain. Returns @{ ok; vmName; guestKey; reason }.
    .DESCRIPTION
        Mirrors Debug-TestSequence.ps1's standalone per-guest prep for a single
        full run (StartStep 1 .. end). The caching-proxy-service URL is resolved
        once by the caller and forwarded so every inner run shares it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Sequence,
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)]$Config,
        [string]$CachingProxyServiceUrl = '',
        [switch]$ShowSensitive
    )
    $fail = { param($msg) return @{ ok = $false; vmName = $null; guestKey = $null; reason = $msg } }

    # --- REGION: Derive GuestKey from the sequence's baseline map
    # First OS key, the same source of truth Debug-TestSequence reads.
    $osKeys = @()
    if ($Sequence.baseline -is [System.Collections.IDictionary] -and $Sequence.baseline.Keys.Count -gt 0) {
        $osKeys = @($Sequence.baseline.Keys)
    }
    if ($osKeys.Count -eq 0) {
        return & $fail (Format-YurunaOperatorMessage -Key 'runner.inner_sequence_resource_missing' -Arguments @{ name = $Name })
    }
    $osKey    = [string]$osKeys[0]
    $guestKey = "guest.$osKey"
    if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $guestKey)) {
        return & $fail (Format-YurunaOperatorMessage -Key 'runner.inner_guest_folder_missing' -Arguments @{ guest = $guestKey; host = $HostType; name = $Name })
    }

    # --- REGION: Derive VM name
    # Prefix from config; the snapshot id on the warm path.
    $prefix = $Config.vmStart.testVmNamePrefix ?? 'test-'
    $vmName = Get-TestVMName -GuestKey $guestKey -Prefix $prefix

    # --- REGION: Build chain plan
    # Warm-path aware. Pass the resolved file as the top-level
    # override so the exact inner file runs; prereqs still resolve by name.
    $plan = Resolve-TestSequencePlan `
        -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType `
        -SequenceName $Name -OsKey $osKey -SequencePathOverride $SequencePath
    if ($plan.resolveFailed) { return & $fail "Chain plan resolution failed for inner '$Name'." }
    $chainEntries = $plan.chainEntries
    $effectiveUser = $plan.effectiveUser
    $effectiveHost = $plan.effectiveHost
    $totalSteps    = $plan.chainTotalSteps
    if ($plan.warmPath -and $plan.requiredSnapshotId) { $vmName = $plan.requiredSnapshotId }

    # --- REGION: SSH-user override
    # Save-GuestDiagnostic + the SSH-mode host driver read it.
    if (Get-Command Clear-GuestSshUserOverride -ErrorAction SilentlyContinue) { Clear-GuestSshUserOverride }
    if ($effectiveUser -and (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        Set-GuestSshUserOverride -GuestKey $guestKey -Username $effectiveUser
    }

    # --- REGION: Ensure VM exists (reuse or create)
    # Forwards the shared proxy.
    if ((Get-VMState -VMName $vmName) -ne 'absent') {
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_a625bc6e8395161a' -Arguments @{ vmName = "$vmName" })
    } else {
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_734d4db0ea4612b1' -Arguments @{ vmName = "$vmName" })
        $newVmArgs = @{ GuestKey = $guestKey; RepoRoot = $RepoRoot; VMName = $vmName; CachingProxyServiceUrl = $CachingProxyServiceUrl }
        if ($effectiveUser) { $newVmArgs.Username = $effectiveUser }
        if ($effectiveHost) { $newVmArgs.Hostname = $effectiveHost }
        $r = New-VM @newVmArgs -Confirm:$false
        if (-not $r.success) { return & $fail "New-VM failed for inner '$Name': $($r.errorMessage)" }
        Write-OrchestratorLine "VM '$vmName' created."
    }

    # --- REGION: Ensure VM is running
    # Skipped when the first step is loadDiskSnapshot
    # (its handler tolerates a stopped VM and starts it after the restore).
    # Read through a wrapper such as `retry` to the inner step that actually
    # runs first, so a nested restore is recognized as one.
    $firstAction = [string](Get-FirstExecutedStepAction -ChainEntries $chainEntries -StartStep 1)
    if ($firstAction -eq 'loadDiskSnapshot') {
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_21e1094877b5bc10' -Arguments @{ vmName = "$vmName" })
    } elseif ((Get-VMState -VMName $vmName) -eq 'running') {
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_e0af652141bb2f23' -Arguments @{ vmName = "$vmName" })
    } else {
        $startTimeout = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
        $bootDelay    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_051a02c281a0d2b2' -Arguments @{ vmName = "$vmName" })
        $r = Start-VM -VMName $vmName -Confirm:$false
        if (-not $r.success) { return & $fail "Start-VM failed for inner '$Name': $($r.errorMessage)" }
        if (-not (Wait-VMRunning -VMName $vmName -TimeoutSeconds $startTimeout -BootDelaySeconds $bootDelay)) {
            return & $fail "VM '$vmName' did not reach running state within ${startTimeout}s (inner '$Name')."
        }
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_f466b580997a484d' -Arguments @{ vmName = "$vmName" })
    }

    # --- REGION: Run each chain entry (StartStep 1 .. end)
    $result = Invoke-TestSequenceChain `
        -ChainEntries $chainEntries -ChainPlan $plan.chainPlan `
        -StartStep 1 -EffectiveStop $totalSteps -StopStep 0 -ChainTotalSteps $totalSteps `
        -HostType $HostType -GuestKey $guestKey -VMName $vmName `
        -SequenceName $Name -ShowSensitive:$ShowSensitive
    if (-not $result.ok) {
        # Evidence first: the guest is still up and holding the state that failed.
        $failedVm = if ($result.finishedVmName) { [string]$result.finishedVmName } else { $vmName }
        Save-ChainFailureArtifact -VMName $failedVm -GuestKey $guestKey -RepoRoot $RepoRoot
        return @{ ok = $false; vmName = $result.finishedVmName; guestKey = $guestKey; reason = "chain '$Name' failed" }
    }
    return @{ ok = $true; vmName = $result.finishedVmName; guestKey = $guestKey; reason = '' }
}

function Invoke-OrchestrationSequence {
    <#
    .SYNOPSIS
        Run an orchestration sequence: walk its InvokeTestSequence steps,
        dispatch each inner sequence (host action or in-process guest
        chain) under ONE status.json cycle, and return an exit code
        (0 = all passed). Stops at the first failure unless the outer
        sequence sets `continueOnError: true`.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads $global:__YurunaCycleFolder -- the cross-module cycle-folder handle set by Start-LogFile (Test.Log) -- to root nested child transcripts under the owner cycle folder. Read-only; same handle Test.Log documents.')]
    param(
        [Parameter(Mandatory)]$Sequence,
        [Parameter(Mandatory)][string]$SequencePath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$SequencesDir,
        [Parameter(Mandatory)][string]$TestRoot,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)]$Config,
        [switch]$ShowSensitive
    )

    $setName = if ($Sequence.Contains('name') -and $Sequence['name']) {
        [string]$Sequence['name']
    } else { [System.IO.Path]::GetFileNameWithoutExtension($SequencePath) }
    $continueOnError = $Sequence.Contains('continueOnError') -and [bool]$Sequence['continueOnError']

    # See https://yuruna.link/4213a0b3-00b7
    $ctx        = Get-CycleContext
    $orchNested = [bool]$ctx
    $statusFile = if ($ctx -and $ctx.statusPath) { [string]$ctx.statusPath } else { Join-Path $env:YURUNA_RUNTIME_DIR 'status.json' }
    $orchNodeId = if ($orchNested) {
        $pfx = [string]$ctx.parentId
        if ($pfx) { "$pfx/$setName" } else { $setName }
    } else { '' }

    # --- REGION: Resolve sequence file
    # Every step is resolved to (name, path, sequence, kind) up front so the
    # status cycle can list all inner sequences before the first runs.
    $entries = New-Object System.Collections.Generic.List[object]
    $stepIdx = 0
    foreach ($step in @($Sequence['steps'])) {
        $stepIdx++
        if ($step -isnot [System.Collections.IDictionary] -or [string]$step['action'] -ne 'InvokeTestSequence') {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_fd26523bb424d415' -Arguments @{ setName = "$setName"; stepIdx = "$stepIdx" })
            return 1
        }
        $innerRef = [string]$step['sequence']
        if ([string]::IsNullOrWhiteSpace($innerRef)) {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f52b08f0a9c9458f' -Arguments @{ setName = "$setName"; stepIdx = "$stepIdx" })
            return 1
        }
        $innerName = $innerRef -replace '\.ya?ml$', ''
        $innerPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $innerName -HostType $HostType -RepoRoot $RepoRoot
        if (-not $innerPath) {
            Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_f11bbe223863fb80' -Arguments @{ innerName = "$innerName"; setName = "$setName" })
            foreach ($p in (Get-SequenceSearchPath -SequencesDir $SequencesDir -Name $innerName -HostType $HostType -RepoRoot $RepoRoot)) { Write-OrchestratorLine "  $p" }
            return 1
        }
        $innerSeq = Read-SequenceFile -Path $innerPath
        $kind = if ($innerSeq -is [System.Collections.IDictionary] -and $innerSeq['host'] -is [System.Collections.IDictionary]) {
            'host'
        } elseif ($innerSeq -is [System.Collections.IDictionary] -and $innerSeq.Contains('baseline') -and $innerSeq.Contains('steps')) {
            'guest'
        } else { 'unknown' }
        $entries.Add([pscustomobject]@{
            index       = $stepIdx
            name        = $innerName
            path        = $innerPath
            sequence    = $innerSeq
            kind        = $kind
            description = if ($step.Contains('description')) { [string]$step['description'] } else { '' }
        })
    }

    Write-OrchestratorLine ""
    Write-OrchestratorLine "========"
    Write-OrchestratorLine "  Orchestration: $setName"
    Write-OrchestratorLine "  Sequence:      $SequencePath"
    Write-OrchestratorLine "  Steps:         $($entries.Count)"
    Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_9ce0fabe891f6c6f' -Arguments @{ failure = "$(if ($continueOnError) { 'continue (report all)' } else { 'stop at first failure' })" })
    Write-OrchestratorLine "========"

    # --- REGION: Resolve the caching-proxy-service endpoint from config + env
    # Resolved ONCE and shared by every guest run,
    # mirroring Debug-TestSequence's own resolve. Env candidate wins per its rules.
    $envCacheIp    = if ($env:YURUNA_CACHING_PROXY_SERVICE_IP) { $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { '' }
    $configCacheIp = ''
    if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIp')) {
        $configCacheIp = "$($Config.vmStart.cachingProxyIp)".Trim()
    }
    $cacheEndpoint = $null
    if (($envCacheIp -or $configCacheIp) -and (Get-Command Resolve-CachingProxyServiceEndpoint -ErrorAction SilentlyContinue)) {
        $endpoint = Resolve-CachingProxyServiceEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
        $cacheEndpoint = $endpoint
        foreach ($line in $endpoint.Lines) { Write-OrchestratorLine $line }
        # See https://yuruna.link/42f6b05f-0049
        if ($endpoint.EffectiveIp -and (Get-Command Wait-CachingProxyServiceSettled -ErrorAction SilentlyContinue)) {
            # See https://yuruna.link/4213a0b3-00b8
            $settle = Wait-CachingProxyServiceSettled -CacheIp $endpoint.EffectiveIp -Port $endpoint.HttpPort
            foreach ($line in $settle.Lines) { Write-OrchestratorLine $line }
        }
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = $endpoint.EffectiveIp
    }
    $cachingProxyUrl = Test-CachingProxyServiceAvailable
    if ($cachingProxyUrl) { Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_6d7d25b104033455' -Arguments @{ cachingProxyUrl = "$cachingProxyUrl" }) }

    # --- REGION: Register this run as a cycle in status.json
    # OWNER: reset + initialize ONE status cycle where
    # each inner sequence is its own top-level row (synthetic guest key =
    # inner name) so the dashboard shows a single unified cycle. NESTED:
    # attach ONE `nested` node for the whole orchestration under the parent
    # that invoked us, and write our transcript under the owner's cycle
    # folder -- never reset/own the doc.
    if ($orchNested) {
        $nlog = Start-NestedLogFile -RootCycleFolder ([string]$ctx.rootCycleFolder) -NodeId $orchNodeId -CycleStartUtc ([string]$ctx.cycleStartUtc)
        Register-NestedRunNode -StatusPath $statusFile -NodeId $orchNodeId -ParentId ([string]$ctx.parentId) `
            -Name $setName -Kind 'orchestration' -LogRel $nlog.LogRel -CycleStartUtc ([string]$ctx.cycleStartUtc)
        $cycleStartUtc = [string]$ctx.cycleStartUtc
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_3e560fa5dd1ee982' -Arguments @{ logFile = "$($nlog.LogFile)" })
    } else {
        Reset-StatusDocumentForCycleStart -StatusFilePath $statusFile -Confirm:$false
        $guestKeys = @($entries | ForEach-Object { $_.name })
        $sequences = @($entries | ForEach-Object { [ordered]@{ name = $_.name; guests = @($_.name) } })

        $frameworkUrl = if ($Config.repositories -is [System.Collections.IDictionary] -and $Config.repositories.frameworkUrl) {
            [string]$Config.repositories.frameworkUrl
        } else { '' }
        $frameworkCommit = ''
        if (Get-Command Get-CurrentGitCommit -ErrorAction SilentlyContinue) {
            try { $frameworkCommit = [string](Get-CurrentGitCommit -RepoRoot $RepoRoot) } catch { $frameworkCommit = '' }
        }
        $gitCommitsList = @()
        if ($frameworkCommit) { $gitCommitsList += [ordered]@{ sha = $frameworkCommit; repoUrl = $frameworkUrl } }
        $projectCommitReference = $null
        if ($Config.repositories -is [System.Collections.IDictionary] -and
            (Get-Command Get-ProjectGitCommitReference -ErrorAction SilentlyContinue)) {
            $projectCommitReference = Get-ProjectGitCommitReference -RepoRoot $RepoRoot -ProjectUrl $Config.repositories.projectUrl
        }
        $projectCommit = if ($projectCommitReference) { [string]$projectCommitReference.sha } else { $null }
        if ($projectCommitReference) { $gitCommitsList += $projectCommitReference }

        $cycleStartUtc = Initialize-StatusDocument `
            -StatusFilePath $statusFile -HostType $HostType -Hostname (hostname) `
            -GitCommit $frameworkCommit -RepoUrl $frameworkUrl -GitCommits $gitCommitsList `
            -GuestList $guestKeys -Sequences $sequences -StepNames @('Run')
        foreach ($e in $entries) { Set-GuestTopLevel -GuestKey $e.name -TopLevel $e.name -Confirm:$false }

        $cycleNumber = Get-CycleNumber
        $logFile = Start-LogFile -TestRoot $TestRoot -CycleStartUtc $cycleStartUtc -Hostname (hostname) -CycleNumber $cycleNumber -GitCommits $gitCommitsList
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_254906044fad17f7' -Arguments @{ logFile = "$logFile" })

        # Open the per-step perf log for the cycle this orchestration owns.
        # An orchestration owns its whole cycle, so nothing upstream has opened
        # one; without this every Write-PerfStepRow below no-ops on a null cycle
        # context and the cycle contributes no rows at all. Soft-failing on the
        # same terms as every other perf call -- a perf problem must not fail a
        # cycle. Start-PerfCycle publishes the handle the inner sequences (and
        # any child pwsh they spawn) adopt automatically.
        if (Get-Command -Name Start-PerfCycle -ErrorAction SilentlyContinue) {
            try {
                # Built only when the cycle folder is actually known: Join-Path
                # throws on an empty Path, and letting that reach the catch
                # below would trade a missing hostInfoHash for a cycle with no
                # perf rows at all. Absent file just leaves the hash null.
                $perfArgs = @{
                    CycleStartUtc       = $cycleStartUtc
                    HostPlatform  = $HostType
                    Hostname      = (hostname)
                    HarnessCommit = $frameworkCommit
                    ProjectCommit = $projectCommit
                }
                $cycFolder = [string]$global:__YurunaCycleFolder
                if ($cycFolder) { $perfArgs.HostDiagnosticPath = Join-Path $cycFolder 'host.diagnostic.txt' }
                Start-PerfCycle @perfArgs -Confirm:$false
            } catch {
                Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_5cc65763e73334c7' -Arguments @{ message = "$($_.Exception.Message)" })
            }
        }
    }
    # Root cycle folder + number children inherit for their nested transcripts +
    # tiles: the OWNER's own cycle folder, or the propagated root when nested.
    $rootCycleFolder = if ($orchNested) { [string]$ctx.rootCycleFolder } else { [string]$global:__YurunaCycleFolder }
    $rootCycleNumber = if ($orchNested) { [int]$ctx.cycleNumber } else { (Get-CycleNumber) }

    # --- REGION: Run each chain entry that overlaps the requested step range
    $results = New-Object System.Collections.Generic.List[object]
    $stopped = $false
    $escapedException = $null
    $logOutcome = $null
    $overall = 'pass'
    $firstFailureReason = ''

    # Entry-boundary control gates. The sequence engine gates every STEP on
    # these flags, but a chain entry is not a step: a host action never reaches
    # that engine at all, so between two entries the operator's Pause took
    # effect only once the next entry had already started -- and a lab service
    # that went away between them was not noticed until something downstream
    # failed on it.
    $orchRuntimeDir = if (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue) {
        Initialize-YurunaRuntimeDir
    } else { [string]$env:YURUNA_RUNTIME_DIR }
    $orchStepPauseFlag   = if ($orchRuntimeDir) { Join-Path $orchRuntimeDir 'control.step-pause' }    else { '' }
    $orchCycleRestartFlag = if ($orchRuntimeDir) { Join-Path $orchRuntimeDir 'control.cycle-restart' } else { '' }

    $orchWaitWhilePaused = {
        param([string]$Label)
        if (-not $orchStepPauseFlag -or -not (Test-Path -LiteralPath $orchStepPauseFlag)) { return }
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_2abc7b8438379497' -Arguments @{ label = "$Label" })
        $attempt = 1
        while (Test-Path -LiteralPath $orchStepPauseFlag) {
            $delay = if (Get-Command Get-PollDelay -ErrorAction SilentlyContinue) { Get-PollDelay -Attempt $attempt } else { 2000 }
            Start-Sleep -Milliseconds $delay
            Write-RunnerStepHeartbeat -RuntimeDir $orchRuntimeDir
            $attempt++
        }
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_837ab3f8df47479e' -Arguments @{ label = "$Label" })
    }

    # Same control-flow marker the sequence engine throws, carried both as an
    # Exception.Data tag and as the message prefix, so a restart requested while
    # an entry is held routes through the inner runner's cycle-catch instead of
    # counting as a crash.
    $orchCheckCycleRestart = {
        param([string]$Label)
        if (-not $orchCycleRestartFlag -or -not (Test-Path -LiteralPath $orchCycleRestartFlag)) { return }
        Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_5bce4dcd946bfee3' -Arguments @{ label = "$Label" })
        $restart = [System.Management.Automation.RuntimeException]::new("YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at $Label")
        $restart.Data['YurunaCycleRestart'] = $true
        throw $restart
    }

    try {
        foreach ($e in $entries) {
            if ($stopped) {
                if (-not $orchNested) {
                    Set-GuestStatus -GuestKey $e.name -Status 'skipped' -Confirm:$false
                    Set-StepStatus -GuestKey $e.name -StepName 'Run' -Status 'skipped' -Confirm:$false
                }
                $results.Add([ordered]@{ index = $e.index; name = $e.name; kind = $e.kind; outcome = 'SKIPPED' })
                continue
            }
            Write-OrchestratorLine ""
            Write-OrchestratorLine "----- [$($e.index)/$($entries.Count)] $($e.name) -----"
            # The same boundary as data. The rule above gives the rendered page
            # an outline; this gives a consumer one without reading prose at
            # all -- and the aggregator already ships this stream off the host,
            # so a step boundary becomes something the pool can see rather than
            # something each reader has to re-derive from a line of dashes.
            Write-CycleStepEvent -Phase 'start' -Index ([int]$e.index) -Total ([int]$entries.Count) -Name ([string]$e.name) -Kind ([string]$e.kind)

            # Operator pause wins over the lab hold: someone who has parked the
            # cycle is present, and re-probing a lab nobody is watching achieves
            # nothing. The lab gate is Get-Command-guarded so an entry point
            # whose module set omits Test.LabHealth runs exactly as before.
            $entryStartUtc = [datetime]::UtcNow
            $entryLabel = "[$($e.index)/$($entries.Count)] $($e.name)"
            $labHoldReason = ''
            & $orchWaitWhilePaused $entryLabel
            if (Get-Command Invoke-LabHealthGate -ErrorAction SilentlyContinue) {
                try {
                    $null = Invoke-LabHealthGate -Label $entryLabel -Config $Config -HostType $HostType `
                        -Stage $e.name -CheckAbort $orchCheckCycleRestart -WaitWhilePaused $orchWaitWhilePaused
                } catch {
                    # An exhausted hold fails THIS entry rather than escaping the
                    # loop: the enclosing construct is try/finally with no catch,
                    # so an escape would run the finalizer with $overall still
                    # 'pass' and record a green cycle over a stopped lab. The
                    # cycle-restart marker keeps escaping -- unwinding IS what it
                    # asks for.
                    if (($_.Exception.Data -and $_.Exception.Data['YurunaCycleRestart']) -or
                        ($_.Exception.Message -like 'YurunaCycleRestart:*')) { throw }
                    $labHoldReason = [string]$_.Exception.Message
                    Write-OrchestratorLine "$entryLabel $labHoldReason"
                }
            }
            & $orchCheckCycleRestart $entryLabel

            if (-not $orchNested) {
                Set-GuestStatus -GuestKey $e.name -Status 'running' -Confirm:$false
                Set-StepStatus -GuestKey $e.name -StepName 'Run' -Status 'running' -Confirm:$false
            }

            # Publish the cycle-context handle so any child PROCESS this step
            # spawns (a host action re-entering Debug-TestSequence.ps1 -- e.g.
            # set-resource -> Set-Resource.ps1 -> per-stage guest builds)
            # attaches as a nested node under this step. Owner: parent = the
            # step's top-level row ($e.name). Nested: parent = this
            # orchestration's node. Cleared after the step so a later in-process
            # step doesn't inherit a stale parent.
            $stepParentId = if ($orchNested) { $orchNodeId } else { $e.name }
            Publish-CycleContext -CycleStartUtc $cycleStartUtc -StatusPath $statusFile `
                -RootCycleFolder $rootCycleFolder -CycleNumber $rootCycleNumber -ParentId $stepParentId

            $reason = ''
            $entryVmName = ''
            try {
                if ($labHoldReason) {
                    # The gate already wrote a classified last_failure.json, and
                    # the inherited-class read below picks it up, so this entry
                    # only has to report the outcome -- running it would report
                    # whatever unrelated symptom the missing service produces.
                    $ok = $false
                    $reason = $labHoldReason
                } elseif ($e.kind -eq 'host') {
                    $hostTail = [System.Collections.Generic.List[string]]::new()
                    $exit = Invoke-OrchestratorHostAction -Sequence $e.sequence -SequencePath $e.path -Name $e.name -OutputTail $hostTail
                    $ok = ($exit -eq 0)
                    if (-not $ok) {
                        # The action's own last error line is the cause a reader
                        # needs; a classified record the action wrote replaces
                        # this reason below, so the richer text always wins.
                        $detail = Get-OrchestratorHostActionDetail -Tail $hostTail
                        $reason = if ($detail) {
                            Format-YurunaOperatorMessage -Key 'runner.host_action_exit_detail' -Arguments @{ name = "$($e.name)"; exit = "$exit"; detail = "$detail" }
                        } else {
                            Format-YurunaOperatorMessage -Key 'runner.operator_8d9e40dd307d47d9' -Arguments @{ name = "$($e.name)"; exit = "$exit" }
                        }
                    }
                } elseif ($e.kind -eq 'guest') {
                    $entryCacheReady = $true
                    if ((Test-SequenceRequiresCacheRegistry -SequenceName ([string]$e.name)) -and
                        $cacheEndpoint -and $cacheEndpoint.EffectiveIp) {
                        # A cache rebuild can begin after an earlier chain entry,
                        # so the required manifest path is checked at the last
                        # boundary before this guest starts.
                        $regWait = 900
                        if ($Config -and $Config.vmStart -is [System.Collections.IDictionary] -and
                            $Config.vmStart.Contains('cachingProxyRegistryWaitSeconds')) {
                            $regWait = [int]$Config.vmStart.cachingProxyRegistryWaitSeconds
                        }
                        $entryCache = Wait-CachingProxyServiceSettled -CacheIp $cacheEndpoint.EffectiveIp `
                            -Port $cacheEndpoint.HttpPort -RegistryTimeoutSeconds $regWait -RequireRegistry
                        foreach ($line in $entryCache.Lines) { Write-OrchestratorLine $line }
                        if (-not $entryCache.Ready) {
                            $entryCacheReady = $false
                            $reason = [string]$entryCache.Lines[-1]
                        }
                    }
                    if ($entryCacheReady) {
                        $run = Invoke-OrchestratorGuestRun -Sequence $e.sequence -SequencePath $e.path -Name $e.name `
                            -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -Config $Config `
                            -CachingProxyServiceUrl $cachingProxyUrl -ShowSensitive:$ShowSensitive
                        $ok = [bool]$run.ok
                        if ($run.vmName) { $entryVmName = [string]$run.vmName }
                        if ($run.vmName -and -not $orchNested) { Set-GuestVMName -GuestKey $e.name -VMName $run.vmName -Confirm:$false }
                        if (-not $ok) { $reason = $run.reason }
                    } else {
                        $ok = $false
                    }
                } else {
                    $ok = $false
                    $reason = (Format-YurunaOperatorMessage -Key 'runner.operator_e2e4c1d2a97c7116' -Arguments @{ name = "$($e.name)" })
                    Write-Error $reason
                }
            } finally {
                Clear-CycleContext
            }

            $inheritedClass = 'unknown'
            $inheritedDependencies = @()
            if (-not $ok -and $env:YURUNA_LOG_DIR) {
                $innerFailure = Join-Path $env:YURUNA_LOG_DIR 'last_failure.json'
                try {
                    if ((Test-Path -LiteralPath $innerFailure -PathType Leaf) -and
                        (Get-Item -LiteralPath $innerFailure -ErrorAction Stop).LastWriteTimeUtc -ge $entryStartUtc) {
                        $innerRec = Get-Content -Raw -LiteralPath $innerFailure -ErrorAction Stop |
                            ConvertFrom-Json -AsHashtable -ErrorAction Stop
                        if ($innerRec.Contains('failureClass') -and $innerRec['failureClass']) {
                            $inheritedClass = [string]$innerRec['failureClass']
                        }
                        if ($innerRec['description']) { $reason = [string]$innerRec['description'] }
                        if ($innerRec['context'] -is [System.Collections.IDictionary] -and $innerRec['context']['dependencyFailures']) {
                            $inheritedDependencies = @($innerRec['context']['dependencyFailures'])
                        }
                        if (Get-Command Copy-CycleFailureRecord -ErrorAction SilentlyContinue) {
                            $null = Copy-CycleFailureRecord -LogDir $env:YURUNA_LOG_DIR
                        }
                    }
                } catch {
                    Write-Verbose "Invoke-OrchestrationSequence: inner failure class unreadable -- $($_.Exception.Message)"
                }
            }

            $outcome = if ($ok) { 'PASS' } else { 'FAIL' }
            if (-not $orchNested) {
                Set-StepStatus -GuestKey $e.name -StepName 'Run' -Status $(if ($ok) { 'pass' } else { 'fail' }) -ErrorMessage $reason -Confirm:$false
                Set-GuestStatus -GuestKey $e.name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Confirm:$false
            }
            Write-OrchestratorLine "----- [$($e.index)/$($entries.Count)] $($e.name) : $outcome -----"
            Write-CycleStepEvent -Phase 'end' -Index ([int]$e.index) -Total ([int]$entries.Count) -Name ([string]$e.name) -Kind ([string]$e.kind) -Outcome $outcome
            $results.Add([ordered]@{ index = $e.index; name = $e.name; kind = $e.kind; outcome = $outcome })
            if (-not $ok) {
                $overall = 'fail'
                # See https://yuruna.link/4213a0b3-00b9
                try {
                    if (-not (Get-Command Write-CycleInfraFailure -ErrorAction SilentlyContinue)) {
                        Import-Module (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1') -Force -Global -ErrorAction Stop
                    }
                    # See https://yuruna.link/4213a0b3-00ba
                    Write-CycleInfraFailure -Stage $e.name -FailureClass $inheritedClass -Severity 'hard' `
                        -GuestKey '(orchestration)' -VMName $entryVmName -ErrorMessage $reason -HostType $HostType `
                        -DependencyFailures $inheritedDependencies
                } catch {
                    Write-Verbose "Invoke-OrchestrationSequence: no failure record written for '$($e.name)' -- $($_.Exception.Message)"
                }
                # First failure wins: it is the one that stopped the run, and
                # with continueOnError the later entries are consequences.
                if (-not $firstFailureReason) { $firstFailureReason = "$($e.name): $reason" }
                if (-not $continueOnError) { $stopped = $true }
            }
        }
    } catch {
        $overall = 'fail'
        $escapedException = $_.Exception
        if (-not $firstFailureReason) { $firstFailureReason = [string]$escapedException.Message }
        if ($escapedException.Data['YurunaCycleRestart'] -or $escapedException.Message -like 'YurunaCycleRestart:*') { $logOutcome = 'aborted' }
        throw
    } finally {
        if ($orchNested) {
            # NESTED: finalize only THIS orchestration's node + seal its
            # transcript. The owner finalizes the cycle (history/manifest/rename).
            if (Get-Command Set-NestedRunStatus -ErrorAction SilentlyContinue) {
                Set-NestedRunStatus -StatusPath $statusFile -NodeId $orchNodeId -Status $overall
            }
            if (Get-Command Stop-NestedLogFile -ErrorAction SilentlyContinue) { Stop-NestedLogFile }
        } else {
            $maxHistory = 30
            if ($Config -is [System.Collections.IDictionary] -and $Config.testCycle -is [System.Collections.IDictionary] -and $Config.testCycle.recentDisplayCount) {
                $maxHistory = [int]$Config.testCycle.recentDisplayCount
            }
            if (Get-Command Complete-Run -ErrorAction SilentlyContinue) {
                Complete-Run -OverallStatus $overall -MaxHistoryRuns $maxHistory
                if ($escapedException) { $escapedException.Data['YurunaCycleFinalized'] = $true }
            }
            if (Get-Command Stop-LogFile -ErrorAction SilentlyContinue) { Stop-LogFile -Outcome $(if ($logOutcome) { $logOutcome } else { $overall }) -Reason $firstFailureReason }
        }
    }

    # --- REGION: Summary
    $failCount = @($results | Where-Object { $_.outcome -eq 'FAIL' }).Count
    $skipCount = @($results | Where-Object { $_.outcome -eq 'SKIPPED' }).Count
    $passCount = @($results | Where-Object { $_.outcome -eq 'PASS' }).Count
    Write-OrchestratorLine ""
    Write-OrchestratorLine "========"
    Write-OrchestratorLine (Format-YurunaOperatorMessage -Key 'runner.operator_cf9f4d7cb9117fd1' -Arguments @{ setName = "$setName"; passCount = "$passCount"; failCount = "$failCount"; skipCount = "$skipCount" })
    foreach ($r in $results) {
        Write-OrchestratorLine ("  [{0}] {1,-8} {2} [{3}]" -f $r.index, $r.outcome, $r.name, $r.kind)
    }
    Write-OrchestratorLine "========"

    if ($failCount -eq 0 -and $skipCount -eq 0) { return 0 } else { return 1 }
}

Export-ModuleMember -Function Test-IsOrchestrationSequence, Invoke-OrchestrationSequence, Write-CycleStepEvent
