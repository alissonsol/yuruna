<#PSScriptInfo
.VERSION 2026.07.22
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

# Orchestration-sequence execution for Test-Sequence.ps1.
#
# An "orchestration sequence" has no `baseline:` and its steps are
# `action: InvokeTestSequence` entries -- each names an inner sequence
# (a guest sequence with baseline+steps, or a host-action `host:` block).
# The orchestrator runs every inner sequence IN-PROCESS under ONE
# status.json cycle: each inner sequence is a distinct row (its own
# synthetic guest key + sequences[] entry) so the dashboard shows one
# unified cycle with per-sequence names and pass/fail, instead of the
# one-cycle-per-child model the retired Test-SequenceSet.ps1 produced.
#
# This replaces the local one-shot Test-SequenceSet driver.
#
# NOTE (dedup follow-up): Invoke-OrchestratorGuestRun below mirrors the
# per-guest prep + chain-run Test-Sequence.ps1 performs inline for a
# standalone run (plan -> caching proxy -> ssh-user override -> VM
# ensure/start -> Invoke-TestSequenceChain). It is kept separate here so
# this change leaves the proven standalone path untouched; a later pass
# can fold both onto one helper once a full-lab run re-verifies it.

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
        The host script's own stdout streams to the console (via Out-Host
        below) and is mirrored into THIS cycle's HTML transcript by the
        Yuruna.Log tee. But a host script is free to fan its real work out
        into child processes with their OWN redirected output -- e.g. the
        AmisAd set-resource.yml runs Set-Resource.ps1, whose Invoke-Stage
        launches each guest build as a hidden child `pwsh` (Start-Process
        -WindowStyle Hidden -RedirectStandardOutput <name>.out.log). When it
        does, the parent console shows ONLY the boundary lines the host
        script writes directly (`===== [<name>] ... =====` / `exited N`);
        the per-stage step-by-step detail is NOT on the console. That detail
        still lands in two places: (a) the redirected <name>.out.log file,
        and (b) each child's OWN per-cycle HTML transcript -- every child
        Test-Sequence.ps1 run calls Start-LogFile and gets its own
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
        # Out-Host: stream the child script's output to the console/transcript
        # rather than the success stream -- this function's return value (the
        # exit code) is captured by the caller, so un-piped stdout would be
        # swallowed into that value instead of shown.
        & $pwshExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @hostArgs | Out-Host
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
        Mirrors Test-Sequence.ps1's standalone per-guest prep for a single
        full run (StartStep 1 .. end). The caching-proxy URL is resolved
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
        [string]$CachingProxyUrl = '',
        [switch]$ShowSensitive
    )
    $fail = { param($msg) return @{ ok = $false; vmName = $null; guestKey = $null; reason = $msg } }

    # --- GuestKey from the baseline map (first OS key), same as Test-Sequence.
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
        $newVmArgs = @{ GuestKey = $guestKey; RepoRoot = $RepoRoot; VMName = $vmName; CachingProxyUrl = $CachingProxyUrl }
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
    # PROCESS the step spawns (a host action re-entering Test-Sequence.ps1)
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

    # --- Resolve the caching-proxy endpoint ONCE (shared by every guest run),
    #     mirroring Test-Sequence's own resolve. Env candidate wins per its rules.
    $envCacheIp    = if ($env:YURUNA_CACHING_PROXY_IP) { $env:YURUNA_CACHING_PROXY_IP.Trim() } else { '' }
    $configCacheIp = ''
    if ($Config.vmStart -is [System.Collections.IDictionary] -and $Config.vmStart.Contains('cachingProxyIP')) {
        $configCacheIp = "$($Config.vmStart.cachingProxyIP)".Trim()
    }
    if (($envCacheIp -or $configCacheIp) -and (Get-Command Resolve-CachingProxyEndpoint -ErrorAction SilentlyContinue)) {
        $endpoint = Resolve-CachingProxyEndpoint -EnvIp $envCacheIp -ConfigIp $configCacheIp
        foreach ($line in $endpoint.Lines) { Write-OrchestratorLine $line }
        $env:YURUNA_CACHING_PROXY_IP = $endpoint.EffectiveIp
    }
    $cachingProxyUrl = Test-CachingProxyAvailable
    if ($cachingProxyUrl) { Write-OrchestratorLine "Caching proxy: $cachingProxyUrl (forwarded to inner runs)" }

    # --- Register the cycle. OWNER: reset + initialize ONE status cycle where
    #     each inner sequence is its own top-level row (synthetic guest key =
    #     inner name) so the dashboard shows a single unified cycle. NESTED:
    #     attach ONE `nested` node for the whole orchestration under the parent
    #     that invoked us, and write our transcript under the owner's cycle
    #     folder -- never reset/own the doc.
    if ($orchNested) {
        $nlog = Start-NestedLogFile -RootCycleFolder ([string]$ctx.rootCycleFolder) -NodeId $orchNodeId -CycleId ([string]$ctx.cycleId)
        Register-NestedRunNode -StatusPath $statusFile -NodeId $orchNodeId -ParentId ([string]$ctx.parentId) `
            -Name $setName -Kind 'orchestration' -LogRel $nlog.LogRel -CycleId ([string]$ctx.cycleId)
        $cycleId = [string]$ctx.cycleId
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

        $cycleId = Initialize-StatusDocument `
            -StatusFilePath $statusFile -HostType $HostType -Hostname (hostname) `
            -GitCommit $frameworkCommit -RepoUrl $frameworkUrl -GitCommits $gitCommitsList `
            -GuestList $guestKeys -Sequences $sequences -StepNames @('Run')
        foreach ($e in $entries) { Set-GuestTopLevel -GuestKey $e.name -TopLevel $e.name -Confirm:$false }

        $cycleNumber = Get-CycleNumber
        $logFile = Start-LogFile -TestRoot $TestRoot -CycleId $cycleId -Hostname (hostname) -CycleNumber $cycleNumber
        Write-OrchestratorLine "Log file: $logFile"
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
            # spawns (a host action re-entering Test-Sequence.ps1 -- e.g.
            # set-resource -> Set-Resource.ps1 -> per-stage guest builds)
            # attaches as a nested node under this step. Owner: parent = the
            # step's top-level row ($e.name). Nested: parent = this
            # orchestration's node. Cleared after the step so a later in-process
            # step doesn't inherit a stale parent.
            $stepParentId = if ($orchNested) { $orchNodeId } else { $e.name }
            Publish-CycleContext -CycleId $cycleId -StatusPath $statusFile `
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
                        -CachingProxyUrl $cachingProxyUrl -ShowSensitive:$ShowSensitive
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
