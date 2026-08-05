<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42c7a1b9-3d4e-4f80-9a21-5b6c7d8e9f01
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

# Orchestration-sequence execution for Invoke-TestSequence.ps1: runs every
# `InvokeTestSequence` inner sequence IN-PROCESS under ONE status.json
# cycle, one dashboard row per inner sequence. See docs/test-runner.md.
#
# Known duplication: Invoke-OrchestratorGuestRun below mirrors the per-guest
# prep + chain-run Invoke-TestSequence.ps1 performs inline for a standalone run
# (plan -> caching-proxy service -> ssh-user override -> VM ensure/start ->
# Invoke-TestSequenceChain). The two are kept separate so a change here cannot
# regress the standalone path; folding them onto one helper needs a full-lab
# run to re-verify both.

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

function Write-OrchestratorLine {
    # Progress output to the INFORMATION stream (not the success stream): these
    # functions return values the caller captures ($rc = Invoke-...), so a
    # Write-Output here would be swallowed into that value, and Write-OrchestratorLine is
    # flagged by PSScriptAnalyzer. -InformationAction Continue makes it display
    # and be captured by the cycle-log transcript. Same convention as
    # Test.SequenceRunner's chain-progress output.
    param([Parameter(ValueFromPipeline)][object]$Message)
    process { Write-Information $Message -InformationAction Continue }
}

function Invoke-OrchestratorHostAction {
    <#
    .SYNOPSIS
        Run an inner host-action sequence (`host:` block) on the host:
        the sibling script(s) named in host.script (single) or
        host.scripts (ordered, stop at first non-zero). Honors
        host.elevated / host.arguments. Returns the exit code (0 = pass).
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
        Invoke-TestSequence.ps1 run calls Start-LogFile and gets its own
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
        [Parameter(Mandatory)][string]$Name
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
        Write-Error "Host-action '$Name' has no 'host.script' or 'host.scripts'."
        return 1
    }
    if ($elevated -and -not (Test-IsElevatedHost)) {
        Write-Error "Host-action '$Name' requires elevation but this shell is not elevated. Re-run from an elevated shell (Run as Administrator)."
        return 1
    }
    $pwshExe = if (Get-Command Get-PwshExePath -ErrorAction SilentlyContinue) { Get-PwshExePath } else { 'pwsh' }
    $entryDir = Split-Path -Parent $SequencePath
    $exitCode = 0
    foreach ($scriptName in $scriptNames) {
        $scriptPath = Join-Path $entryDir $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            Write-Error "Host-action '$Name' script not found: $scriptPath"
            return 1
        }
        Write-OrchestratorLine "Host action: $scriptPath $($hostArgs -join ' ')$(if ($elevated) { ' (elevated)' })"
        # Pipe to Write-OrchestratorLine, not the success stream: this
        # function returns the exit code, so un-piped stdout would be swallowed
        # into that value instead of shown. The information stream (rather than
        # the console host) is what reaches the cycle artifacts, since the log
        # proxy tees the Write-* cmdlets and nothing else -- a host action whose
        # output bypassed it would fail with its reason on the terminal only,
        # and "FAIL" alone in the transcript and the event log. 2>&1 folds in
        # the child's stderr, which is where a failing host script explains
        # itself.
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @hostArgs 2>&1 | Write-OrchestratorLine
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
        Mirrors Invoke-TestSequence.ps1's standalone per-guest prep for a single
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

    # --- GuestKey from the baseline map (first OS key), same as Invoke-TestSequence.
    $osKeys = @()
    if ($Sequence.baseline -is [System.Collections.IDictionary] -and $Sequence.baseline.Keys.Count -gt 0) {
        $osKeys = @($Sequence.baseline.Keys)
    }
    if ($osKeys.Count -eq 0) {
        return & $fail "Inner sequence '$Name' has no 'baseline:' OS key; not a runnable guest sequence."
    }
    $osKey    = [string]$osKeys[0]
    $guestKey = "guest.$osKey"
    if (-not (Test-GuestFolder -RepoRoot $RepoRoot -HostType $HostType -GuestKey $guestKey)) {
        return & $fail "Guest folder not found for '$guestKey' on $HostType (inner '$Name')."
    }

    # --- VM name (prefix from config), overridden to the snapshot id on warm path.
    $prefix = $Config.vmStart.testVmNamePrefix ?? 'test-'
    $vmName = Get-TestVMName -GuestKey $guestKey -Prefix $prefix

    # --- Chain plan (warm-path aware). Pass the resolved file as the top-level
    #     override so the exact inner file runs; prereqs still resolve by name.
    $plan = Resolve-TestSequencePlan `
        -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType `
        -SequenceName $Name -OsKey $osKey -SequencePathOverride $SequencePath
    if ($plan.resolveFailed) { return & $fail "Chain plan resolution failed for inner '$Name'." }
    $chainEntries = $plan.chainEntries
    $effectiveUser = $plan.effectiveUser
    $effectiveHost = $plan.effectiveHost
    $totalSteps    = $plan.chainTotalSteps
    if ($plan.warmPath -and $plan.requiredSnapshotId) { $vmName = $plan.requiredSnapshotId }

    # --- SSH-user override (Save-GuestDiagnostic + SSH-mode host driver read it).
    if (Get-Command Clear-GuestSshUserOverride -ErrorAction SilentlyContinue) { Clear-GuestSshUserOverride }
    if ($effectiveUser -and (Get-Command Set-GuestSshUserOverride -ErrorAction SilentlyContinue)) {
        Set-GuestSshUserOverride -GuestKey $guestKey -Username $effectiveUser
    }

    # --- Ensure the VM exists (reuse or create), forwarding the shared proxy.
    if ((Get-VMState -VMName $vmName) -ne 'absent') {
        Write-OrchestratorLine "VM '$vmName' already exists. Reusing."
    } else {
        Write-OrchestratorLine "VM '$vmName' not found. Creating..."
        $newVmArgs = @{ GuestKey = $guestKey; RepoRoot = $RepoRoot; VMName = $vmName; CachingProxyServiceUrl = $CachingProxyServiceUrl }
        if ($effectiveUser) { $newVmArgs.Username = $effectiveUser }
        if ($effectiveHost) { $newVmArgs.Hostname = $effectiveHost }
        $r = New-VM @newVmArgs -Confirm:$false
        if (-not $r.success) { return & $fail "New-VM failed for inner '$Name': $($r.errorMessage)" }
        Write-OrchestratorLine "VM '$vmName' created."
    }

    # --- Ensure the VM is running, unless the first step is loadDiskSnapshot
    #     (its handler tolerates a stopped VM and starts it after the restore).
    $firstAction = ''
    if ($chainEntries.Count -gt 0) {
        $firstEntry = $chainEntries[0]
        $firstSteps = @($firstEntry.sequence.steps)
        if ($firstSteps.Count -gt 0) { $firstAction = [string]$firstSteps[0].action }
    }
    if ($firstAction -eq 'loadDiskSnapshot') {
        Write-OrchestratorLine "VM '$vmName': skipping pre-sequence start -- first step is loadDiskSnapshot."
    } elseif ((Get-VMState -VMName $vmName) -eq 'running') {
        Write-OrchestratorLine "VM '$vmName' is already running."
    } else {
        $startTimeout = $Config.vmStart.startTimeoutSeconds ? [int]$Config.vmStart.startTimeoutSeconds : 120
        $bootDelay    = $Config.vmStart.bootDelaySeconds    ? [int]$Config.vmStart.bootDelaySeconds    : 15
        Write-OrchestratorLine "Starting VM '$vmName'..."
        $r = Start-VM -VMName $vmName -Confirm:$false
        if (-not $r.success) { return & $fail "Start-VM failed for inner '$Name': $($r.errorMessage)" }
        if (-not (Wait-VMRunning -VMName $vmName -TimeoutSeconds $startTimeout -BootDelaySeconds $bootDelay)) {
            return & $fail "VM '$vmName' did not reach running state within ${startTimeout}s (inner '$Name')."
        }
        Write-OrchestratorLine "VM '$vmName' is running."
    }

    # --- Run the whole chain (StartStep 1 .. end).
    $result = Invoke-TestSequenceChain `
        -ChainEntries $chainEntries -ChainPlan $plan.chainPlan `
        -StartStep 1 -EffectiveStop $totalSteps -StopStep 0 -ChainTotalSteps $totalSteps `
        -HostType $HostType -GuestKey $guestKey -VMName $vmName `
        -SequenceName $Name -ShowSensitive:$ShowSensitive
    if (-not $result.ok) {
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

    # Nested-cycle awareness. An orchestration is normally the cycle OWNER, but
    # it can itself run nested inside another cycle (an orchestration referenced
    # as an inner sequence). When $ctx is present this run is NESTED: it attaches
    # ONE node for the whole orchestration and skips every owner-only status op
    # (Reset/Initialize/Set-Guest*/Complete-Run/Start-LogFile). Either way, the
    # step loop publishes a cycle-context handle before each step so a child
    # PROCESS the step spawns (a host action re-entering Invoke-TestSequence.ps1)
    # attaches as a nested node under the right parent. See Test.Status.psm1
    # "Nested-cycle support".
    $ctx        = Get-CycleContext
    $orchNested = [bool]$ctx
    $statusFile = if ($ctx -and $ctx.statusPath) { [string]$ctx.statusPath } else { Join-Path $env:YURUNA_RUNTIME_DIR 'status.json' }
    $orchNodeId = if ($orchNested) {
        $pfx = [string]$ctx.parentId
        if ($pfx) { "$pfx/$setName" } else { $setName }
    } else { '' }

    # --- Resolve every step to (name, path, sequence, kind) up front so the
    #     status cycle can list all inner sequences before the first runs.
    $entries = New-Object System.Collections.Generic.List[object]
    $stepIdx = 0
    foreach ($step in @($Sequence['steps'])) {
        $stepIdx++
        if ($step -isnot [System.Collections.IDictionary] -or [string]$step['action'] -ne 'InvokeTestSequence') {
            Write-Error "Orchestration sequence '$setName' step $stepIdx is not an 'InvokeTestSequence' action."
            return 1
        }
        $innerRef = [string]$step['sequence']
        if ([string]::IsNullOrWhiteSpace($innerRef)) {
            Write-Error "Orchestration sequence '$setName' step $stepIdx has no 'sequence:' to invoke."
            return 1
        }
        $innerName = $innerRef -replace '\.ya?ml$', ''
        $innerPath = Resolve-SequencePath -SequencesDir $SequencesDir -Name $innerName -HostType $HostType -RepoRoot $RepoRoot
        if (-not $innerPath) {
            Write-Error "Inner sequence not found: $innerName (referenced in '$setName')"
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
    Write-OrchestratorLine "============================================="
    Write-OrchestratorLine "  Orchestration: $setName"
    Write-OrchestratorLine "  Sequence:      $SequencePath"
    Write-OrchestratorLine "  Steps:         $($entries.Count)"
    Write-OrchestratorLine "  On error:      $(if ($continueOnError) { 'continue (report all)' } else { 'stop at first failure' })"
    Write-OrchestratorLine "============================================="

    # --- Resolve the caching-proxy-service endpoint ONCE (shared by every guest run),
    #     mirroring Invoke-TestSequence's own resolve. Env candidate wins per its rules.
    $envCacheIp    = if ($env:YURUNA_CACHING_PROXY_SERVICE_IP) { $env:YURUNA_CACHING_PROXY_SERVICE_IP.Trim() } else { '' }
    $configCacheIp = ''
    if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIp')) {
        $configCacheIp = "$($Config.vmStart.cachingProxyIp)".Trim()
    }
    if (($envCacheIp -or $configCacheIp) -and (Get-Command Resolve-CachingProxyServiceEndpoint -ErrorAction SilentlyContinue)) {
        $endpoint = Resolve-CachingProxyServiceEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
        foreach ($line in $endpoint.Lines) { Write-OrchestratorLine $line }
        # The probe above proves the port answered ONCE; this is the moment the
        # cycle commits to that address for every guest it is about to build, so
        # confirm it stays up first. A cache VM rebuilt shortly before the run is
        # still provisioning, and the restart that applies its ssl-bump config
        # lands after the ports have already opened -- a cycle that probed in the
        # gap pins the address, then reports the cache lost for the next several
        # steps while the guests it seeded fall back to direct downloads.
        if ($endpoint.EffectiveIp -and (Get-Command Wait-CachingProxyServiceSettled -ErrorAction SilentlyContinue)) {
            $settle = Wait-CachingProxyServiceSettled -CacheIp $endpoint.EffectiveIp -Port $endpoint.HttpPort
            foreach ($line in $settle.Lines) { Write-OrchestratorLine $line }
        }
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = $endpoint.EffectiveIp
    }
    $cachingProxyUrl = Test-CachingProxyServiceAvailable
    if ($cachingProxyUrl) { Write-OrchestratorLine "Caching-proxy service: $cachingProxyUrl (forwarded to inner runs)" }

    # --- Register the cycle. OWNER: reset + initialize ONE status cycle where
    #     each inner sequence is its own top-level row (synthetic guest key =
    #     inner name) so the dashboard shows a single unified cycle. NESTED:
    #     attach ONE `nested` node for the whole orchestration under the parent
    #     that invoked us, and write our transcript under the owner's cycle
    #     folder -- never reset/own the doc.
    if ($orchNested) {
        $nlog = Start-NestedLogFile -RootCycleFolder ([string]$ctx.rootCycleFolder) -NodeId $orchNodeId -CycleStartUtc ([string]$ctx.cycleStartUtc)
        Register-NestedRunNode -StatusPath $statusFile -NodeId $orchNodeId -ParentId ([string]$ctx.parentId) `
            -Name $setName -Kind 'orchestration' -LogRel $nlog.LogRel -CycleStartUtc ([string]$ctx.cycleStartUtc)
        $cycleStartUtc = [string]$ctx.cycleStartUtc
        Write-OrchestratorLine "Log file: $($nlog.LogFile)"
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

        $cycleStartUtc = Initialize-StatusDocument `
            -StatusFilePath $statusFile -HostType $HostType -Hostname (hostname) `
            -GitCommit $frameworkCommit -RepoUrl $frameworkUrl -GitCommits $gitCommitsList `
            -GuestList $guestKeys -Sequences $sequences -StepNames @('Run')
        foreach ($e in $entries) { Set-GuestTopLevel -GuestKey $e.name -TopLevel $e.name -Confirm:$false }

        $cycleNumber = Get-CycleNumber
        $logFile = Start-LogFile -TestRoot $TestRoot -CycleStartUtc $cycleStartUtc -Hostname (hostname) -CycleNumber $cycleNumber
        Write-OrchestratorLine "Log file: $logFile"

        # Open the per-step perf log for the cycle this orchestration owns.
        # An orchestration owns its whole cycle, so nothing upstream has opened
        # one; without this every Write-PerfStepRow below no-ops on a null cycle
        # context and the cycle contributes no rows at all. Soft-failing on the
        # same terms as every other perf call -- a perf problem must not fail a
        # cycle. Start-PerfCycle publishes the handle the inner sequences (and
        # any child pwsh they spawn) adopt automatically.
        if (Get-Command -Name Start-PerfCycle -ErrorAction SilentlyContinue) {
            try {
                # Project SHA resolved the same way the guest-cycle path does:
                # only from a real <RepoRoot>/project/.git, and 'unknown' is
                # dropped so rows carry a null rather than a fake commit.
                $projectCommit = $null
                $projectDir = Join-Path $RepoRoot 'project'
                if ((Test-Path (Join-Path $projectDir '.git')) -and (Get-Command Get-CurrentGitCommit -ErrorAction SilentlyContinue)) {
                    $maybe = Get-CurrentGitCommit -RepoRoot $projectDir
                    if ($maybe -and $maybe -ne 'unknown') { $projectCommit = [string]$maybe }
                }
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
                Write-OrchestratorLine "Start-PerfCycle failed (non-fatal): $($_.Exception.Message)"
            }
        }
    }
    # Root cycle folder + number children inherit for their nested transcripts +
    # tiles: the OWNER's own cycle folder, or the propagated root when nested.
    $rootCycleFolder = if ($orchNested) { [string]$ctx.rootCycleFolder } else { [string]$global:__YurunaCycleFolder }
    $rootCycleNumber = if ($orchNested) { [int]$ctx.cycleNumber } else { (Get-CycleNumber) }

    # --- Walk the steps in order.
    $results = New-Object System.Collections.Generic.List[object]
    $stopped = $false
    $overall = 'pass'
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
            if (-not $orchNested) {
                Set-GuestStatus -GuestKey $e.name -Status 'running' -Confirm:$false
                Set-StepStatus -GuestKey $e.name -StepName 'Run' -Status 'running' -Confirm:$false
            }

            # Publish the cycle-context handle so any child PROCESS this step
            # spawns (a host action re-entering Invoke-TestSequence.ps1 -- e.g.
            # set-resource -> Set-Resource.ps1 -> per-stage guest builds)
            # attaches as a nested node under this step. Owner: parent = the
            # step's top-level row ($e.name). Nested: parent = this
            # orchestration's node. Cleared after the step so a later in-process
            # step doesn't inherit a stale parent.
            $stepParentId = if ($orchNested) { $orchNodeId } else { $e.name }
            Publish-CycleContext -CycleStartUtc $cycleStartUtc -StatusPath $statusFile `
                -RootCycleFolder $rootCycleFolder -CycleNumber $rootCycleNumber -ParentId $stepParentId

            $reason = ''
            try {
                if ($e.kind -eq 'host') {
                    $exit = Invoke-OrchestratorHostAction -Sequence $e.sequence -SequencePath $e.path -Name $e.name
                    $ok = ($exit -eq 0)
                    if (-not $ok) { $reason = "host action '$($e.name)' exited $exit" }
                } elseif ($e.kind -eq 'guest') {
                    $run = Invoke-OrchestratorGuestRun -Sequence $e.sequence -SequencePath $e.path -Name $e.name `
                        -RepoRoot $RepoRoot -SequencesDir $SequencesDir -HostType $HostType -Config $Config `
                        -CachingProxyServiceUrl $cachingProxyUrl -ShowSensitive:$ShowSensitive
                    $ok = [bool]$run.ok
                    if ($run.vmName -and -not $orchNested) { Set-GuestVMName -GuestKey $e.name -VMName $run.vmName -Confirm:$false }
                    if (-not $ok) { $reason = $run.reason }
                } else {
                    $ok = $false
                    $reason = "inner '$($e.name)' is neither a guest sequence (baseline + steps) nor a host action (host:)."
                    Write-Error $reason
                }
            } finally {
                Clear-CycleContext
            }

            $outcome = if ($ok) { 'PASS' } else { 'FAIL' }
            if (-not $orchNested) {
                Set-StepStatus -GuestKey $e.name -StepName 'Run' -Status $(if ($ok) { 'pass' } else { 'fail' }) -ErrorMessage $reason -Confirm:$false
                Set-GuestStatus -GuestKey $e.name -Status $(if ($ok) { 'pass' } else { 'fail' }) -Confirm:$false
            }
            Write-OrchestratorLine "----- [$($e.index)/$($entries.Count)] $($e.name) : $outcome -----"
            $results.Add([ordered]@{ index = $e.index; name = $e.name; kind = $e.kind; outcome = $outcome })
            if (-not $ok) {
                $overall = 'fail'
                if (-not $continueOnError) { $stopped = $true }
            }
        }
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
            if (Get-Command Complete-Run -ErrorAction SilentlyContinue) { Complete-Run -OverallStatus $overall -MaxHistoryRuns $maxHistory }
            if (Get-Command Stop-LogFile -ErrorAction SilentlyContinue) { Stop-LogFile -Outcome $overall -Reason '' }
        }
    }

    # --- Summary.
    $failCount = @($results | Where-Object { $_.outcome -eq 'FAIL' }).Count
    $skipCount = @($results | Where-Object { $_.outcome -eq 'SKIPPED' }).Count
    $passCount = @($results | Where-Object { $_.outcome -eq 'PASS' }).Count
    Write-OrchestratorLine ""
    Write-OrchestratorLine "============================================="
    Write-OrchestratorLine "  Orchestration: $setName -- $passCount passed, $failCount failed, $skipCount skipped"
    foreach ($r in $results) {
        Write-OrchestratorLine ("  [{0}] {1,-8} {2} [{3}]" -f $r.index, $r.outcome, $r.name, $r.kind)
    }
    Write-OrchestratorLine "============================================="

    if ($failCount -eq 0 -and $skipCount -eq 0) { return 0 } else { return 1 }
}

Export-ModuleMember -Function Test-IsOrchestrationSequence, Invoke-OrchestrationSequence
