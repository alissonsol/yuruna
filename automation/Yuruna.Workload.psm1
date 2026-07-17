<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42b0d2e3-f4a5-4678-9012-3b4c5d6e7f80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Workload
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

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Validation.psm1"
Import-Module -Name $validationModulePath
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force
# New-YurunaTimestampedBackup: the shared timestamped-backup step, so the
# timestamp format cannot drift between the three publishers.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Common.psm1') -Global -Force
# Set-ExpandedVariableHashtable + Set-ExpandedResourcesOutput live in
# Yuruna.VariableExpansion so [[Yuruna.Component]] can reuse the same
# walk (with its -NoExpand flavour) instead of carrying a parallel
# inline copy. -Global so the exported functions stay resolvable from
# any nested scope Publish-WorkloadList enters.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.VariableExpansion.psm1') -Global -Force
# Shared retry policy (10s initial, x2 backoff, 5 attempts, jitter) used
# by the transient-fetch retry below. -Global -Force so the import does
# not evict an instance another module loaded; see
# feedback_module_force_import_evicts_global.md.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Retry.psm1') -Global -Force
# Shared deployment-kind catalog (chart|kubectl|helm|shell detection,
# error text, tool-expression mapping, retry gating) consumed by the
# per-deployment loop below and, separately, by Confirm-WorkloadList.
# Imported here as well as in Yuruna.Validation because Set-Workload.ps1
# imports Workload only; -Global -Force so the import does not evict an
# instance another module loaded (feedback_module_force_import_evicts_global.md).
Import-Module (Join-Path $PSScriptRoot 'Yuruna.DeploymentKind.psm1') -Global -Force

function Invoke-WorkloadChartDeployment {
    <#
    .SYNOPSIS
        Apply one chart deployment (copy chart, write values.yaml, helm
        lint / pending-state recovery / upgrade --install --atomic).
    .DESCRIPTION
        Self-contained: pushes into the per-install work folder and pops
        it before every exit path. Reads $sw live so a failure manifest
        carries the elapsed-at-failure duration.
    .OUTPUTS
        $null when the chart applied cleanly (caller continues the loop),
        or a New-YurunaResultManifest failure [hashtable] when the
        deployment must abort the cycle.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        $project_root,
        $config_subfolder,
        $contextName,
        $deployment,
        $deploymentVars,
        $workloadsFile,
        $sw
    )
    $chartName = $deployment['chart']
    if ([string]::IsNullOrEmpty($chartName)) { Write-Information "context.chart cannot be null or empty in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "context.chart cannot be null or empty in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $chartFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "workloads/$chartName")
    if (-Not (Test-Path -Path $chartFolder)) { Write-Information "workload[$contextName]chart[$chartName] folder not found: $chartFolder"; return (New-YurunaResultManifest -Success $false -ErrorMessage "workload[$contextName] chart[$chartName] folder not found: $chartFolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $installName = $ExecutionContext.InvokeCommand.ExpandString($deployment.variables['installName'])
    if ([string]::IsNullOrEmpty($installName)) {
        Write-Information "Chart[$chartName] missing variables['installName'] in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "Chart[$chartName] missing variables['installName'] in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds);
    }
    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads/$contextName/$installName"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    Write-Debug "Copying chart from: $chartFolder to $workFolder"
    Copy-Item "$chartFolder/*" -Destination $workFolder -Recurse -Container -ErrorAction SilentlyContinue

    # Write deploymentVars to values.yaml. Backslashes are stripped
    # per helm's --set format constraints:
    # https://helm.sh/docs/intro/using_helm/#the-format-and-limitations-of---set
    $helmValuesFile = Join-Path -Path $workFolder -ChildPath "values.yaml"
    $null = New-Item -Path $helmValuesFile -ItemType File -Force
    foreach ($key in $deploymentVars.Keys) {
        $value = $deploymentVars[$key]
        $value =  $value -replace '\\', ''
        $line = "${key}: `"$value`""
        if (($value.ToString().StartsWith("`"")) -and ($value.ToString().EndsWith("`""))) {
            $line = "${key}: $value"
        }
        Add-Content -Path $helmValuesFile -Value $line
    }
    $line = "contextName: `"$contextName`""
    Add-Content -Path $helmValuesFile -Value $line
    Write-Debug "Helm execute from: $workFolder"
    Push-Location $workFolder

    # Per-chart helm stderr/stdout log + final-rc sidecar. Mirrors the
    # tofu.stderr.log pattern from Set-Resource so
    # Get-SystemDiagnostic.ps1's *.stderr.log glob picks it up on failure.
    # Truncate at chart entry; per-helm-command output is appended
    # with a "== <cmd> (exit=N) ==" header. helm.rc is rewritten
    # after each helm call so the LAST observed exit code is what
    # the diagnostic reports -- matches operator intuition ("did
    # helm succeed?") and is what the gap-detector heuristic checks.
    $helmLogFile = Join-Path -Path $workFolder -ChildPath "helm.stderr.log"
    $helmRcFile  = Join-Path -Path $workFolder -ChildPath "helm.rc"
    Remove-Item -LiteralPath $helmLogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $helmRcFile  -Force -ErrorAction SilentlyContinue

    # Helm lint. Exit non-zero indicates the chart has a
    # schema/required-field violation that WILL cascade to a
    # failed install (e.g. an "image: /<repo>:<tag>" produced
    # when componentsRegistry.registryLocation rendered as ""
    # because resources.output.yml had `componentsRegistry: {}`).
    # Surface the captured output on the Information stream
    # and abort the cycle BEFORE attempting install.
    #
    # The chart PATH ('.', the pushed-to $workFolder) must be passed
    # explicitly: helm 4 made it a required argument, where helm 3
    # defaulted it to the current directory. A bare `helm lint` exits 1
    # with "requires at least 1 argument", which reads as a rejected
    # chart and fails the cycle before install.
    Write-Debug "Helm lint"
    $lintOutput = helm lint . *>&1
    $lintExit = $LASTEXITCODE
    Add-Content -LiteralPath $helmLogFile -Value "== helm lint (exit=$lintExit) =="
    $lintOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_); Write-Verbose "$_" }
    Set-Content -LiteralPath $helmRcFile -Value $lintExit -NoNewline
    if ($lintExit -ne 0) {
        Write-Information "helm lint FAILED (exit $lintExit) for chart '$installName' in $workFolder"
        $lintOutput | ForEach-Object { Write-Information "$_" }
        Pop-Location
        return (New-YurunaResultManifest -Success $false -ErrorMessage "helm lint failed for chart '$installName' in $workFolder" -FailureClass 'chart_invalid' -ExitCode $lintExit -DurationMs $sw.ElapsedMilliseconds)
    }

    # Pre-flight: a watchdog SIGKILL of helm mid-upgrade
    # (or a host crash) leaves the release in pending-*
    # state. Helm's atomic-rollback guarantees fire only on
    # a helm-detected failure -- a process kill bypasses
    # them. Next cycle's `helm upgrade --install` then
    # exits with "another operation in progress" and no
    # auto-recovery is wired downstream. Detect pending-*
    # status and clear it via rollback (preserves history)
    # so the upgrade below proceeds cleanly.
    Write-Debug "Helm status probe for $installName"
    $statusOutput = helm status $installName 2>&1
    $statusExit   = $LASTEXITCODE
    if ($statusExit -eq 0) {
        $statusLine = ($statusOutput | Where-Object { $_ -match '^STATUS:\s*(\S+)' }) | Select-Object -First 1
        if ($statusLine -and $statusLine -match '^STATUS:\s*(pending-\S+)') {
            $pendingState = $Matches[1]
            Write-Warning "Helm release '$installName' is in $pendingState state (likely prior-cycle SIGKILL). Rolling back to recover."
            Add-Content -LiteralPath $helmLogFile -Value "== pre-flight helm status (state=$pendingState; recovering) =="
            $statusOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_) }
            $rollbackOutput = helm rollback $installName 0 2>&1
            $rollbackExit = $LASTEXITCODE
            Add-Content -LiteralPath $helmLogFile -Value "== helm rollback $installName 0 (exit=$rollbackExit) =="
            $rollbackOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_) }
            if ($rollbackExit -ne 0) {
                # Rollback to revision 0 fails when there is no
                # prior good revision (the very first upgrade
                # was the one that was killed). Fall through
                # to `helm uninstall --no-hooks` so the next
                # upgrade --install can land a fresh release.
                Write-Warning "  helm rollback failed (exit $rollbackExit); falling back to uninstall --no-hooks."
                $uninstallOutput = helm uninstall $installName --no-hooks 2>&1
                $uninstallExit = $LASTEXITCODE
                Add-Content -LiteralPath $helmLogFile -Value "== helm uninstall $installName --no-hooks (exit=$uninstallExit) =="
                $uninstallOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_) }
            }
        }
    }

    # Helm upgrade --install --atomic: idempotent in the
    # "release-already-exists" case (no uninstall/install
    # race window where the release disappears mid-cycle)
    # AND atomic in the failure case (automatic rollback to
    # the prior revision on any helm-detected failure, so
    # an interrupted deployment never leaves a half-rendered
    # release in the namespace). A two-step uninstall+install
    # pair instead would, on a watchdog kill between the two
    # calls, strand the operator with no release AND a dirty
    # namespace and no recovery path beyond a full rerun.
    #
    # Non-zero exit is still authoritative -- the release
    # did NOT land (or it landed and was auto-rolled-back).
    # We ALSO scan the captured output for lines starting
    # with "Error:" because helm can return 0
    # on certain post-render rejections (server-side
    # admission failures that surface only in the trailing
    # log). Either signal aborts the test sequence.
    Write-Debug "Helm upgrade --install --atomic $installName"
    $installOutput = helm upgrade --install --atomic $installName . --debug *>&1
    $installExit = $LASTEXITCODE
    Add-Content -LiteralPath $helmLogFile -Value "== helm upgrade --install --atomic $installName --debug (exit=$installExit) =="
    $installOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_); Write-Verbose "$_" }
    Set-Content -LiteralPath $helmRcFile -Value $installExit -NoNewline
    # Match only helm's terminal error shapes: a real error line starts at column
    # 0 with "Error: " (helm's stderr format), so an indented --debug / rendered
    # line that merely contains "Error:" (a NOTES or manifest value) is not a helm
    # failure and must not match. --atomic failures also carry an "INSTALLATION
    # FAILED" / "UPGRADE FAILED" marker.
    $installErrorLines = @($installOutput | Where-Object { $_ -match '^Error: ' -or $_ -match '(INSTALLATION|UPGRADE) FAILED' })
    if ($installExit -ne 0 -or $installErrorLines.Count -gt 0) {
        Write-Information "helm upgrade --install --atomic '$installName' FAILED (exit $installExit, $($installErrorLines.Count) Error: line(s)) in $workFolder"
        $installOutput | ForEach-Object { Write-Information "$_" }
        Pop-Location
        return (New-YurunaResultManifest -Success $false -ErrorMessage "helm upgrade --install --atomic '$installName' failed in $workFolder (exit $installExit, $($installErrorLines.Count) Error: line(s))" -FailureClass 'tool_failed' -ExitCode $installExit -DurationMs $sw.ElapsedMilliseconds)
    }
    Pop-Location
}

function Invoke-WorkloadToolDeployment {
    <#
    .SYNOPSIS
        Apply one non-chart deployment (kubectl | helm | shell) via the
        resolved deployment-kind descriptor, with transient-fetch retry.
    .DESCRIPTION
        Self-contained: pushes into the per-context work folder and pops
        it before every exit path. Resolves Invoke-DynamicExpression via
        Get-Command here (same module session state) so the GetNewClosure
        scriptblock can invoke it via `& $dynExpr` after Yuruna.Retry runs
        the block in its own scope, which cannot see this module's private
        import by name (feedback_closure_foreign_module_command_resolution.md).
        Reads $sw live so a failure manifest carries elapsed-at-failure ms.
    .OUTPUTS
        $null when the tool applied cleanly (caller continues the loop),
        or a New-YurunaResultManifest failure [hashtable] when the
        deployment must abort the cycle.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        $kind,
        $project_root,
        $config_subfolder,
        $contextName,
        $deployment,
        $deploymentVars,
        $sw
    )
    # Push deploymentVars to the environment for command expansion
    foreach ($key in $deploymentVars.Keys) {
        $value = $deploymentVars[$key]
        Set-Item -Path Env:$key -Value ${value}
    }
    Set-Item -Path Env:contextName -Value ${contextName}
    # Tool name, command prefix and value come from the
    # resolved descriptor. CommandPrefix carries its own
    # trailing space for kubectl/helm and is '' for shell, so
    # shell runs its value verbatim. $kind is the non-chart
    # kind this else-branch was entered for.
    $value = $deployment[$kind.Field]
    $expression = "$($kind.CommandPrefix)$value"
    $toolName = $kind.ToolName

    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads/$contextName"
    $workFolder = Resolve-Path -Path $workFolder
    Set-Item -Path Env:workFolder -Value ${workFolder}
    Push-Location $workFolder
    $expression = $ExecutionContext.InvokeCommand.ExpandString($expression)
    Write-Debug "$expression"
    # Per-tool stderr/stdout log + final-rc sidecar in the per-
    # context workFolder. Mirrors Set-Resource's tofu.stderr.log
    # so Get-SystemDiagnostic.ps1's *.stderr.log glob picks it up
    # on failure. Multiple deployments of the same tool append to
    # the same log -- order matches workloads.yml. <tool>.rc is
    # rewritten after each call so the LAST exit code is what the
    # diagnostic reports.
    $toolLogFile = Join-Path -Path $workFolder -ChildPath "$toolName.stderr.log"
    $toolRcFile  = Join-Path -Path $workFolder -ChildPath "$toolName.rc"
    # helm fetches (repo update, install <repo>/<chart>) and kubectl
    # `-f <URL>` deployments cross the network and stutter on shared-
    # egress rate limits or proxy blips. Symptoms:
    #   `Error: INSTALLATION FAILED: failed to fetch https://...`
    #   `error: unable to read URL "https://github.com/...", server
    #    reported 502 Bad Gateway, status code=502`
    # Multiple hosts sharing one squid egress IP can fail inside a
    # sub-second window -- a shared upstream event, not per-host config.
    # Retry via the shared Yuruna.Retry policy (10s initial, x2
    # backoff, 5 attempts, jitter) ONLY when the output matches a
    # transient-fetch pattern and the tool is helm/kubectl; real
    # config errors (chart not found, schema violation, auth,
    # NotFound/Invalid for kubectl) and shell steps fail fast.
    # Sourced from Yuruna.Retry so this phase and the tofu retry
    # in Yuruna.Resource classify transients from one definition.
    $transientPattern = Get-YurunaTransientPattern
    $retryable = $kind.Retryable
    # Closures so the predicate and command survive being invoked
    # from inside the Yuruna.Retry module scope. GetNewClosure pins
    # $expression/$retryable/$transientPattern by value. The
    # scriptblock runs in the retry module's session state, which
    # cannot see this module's private import of
    # Invoke-DynamicExpression by name -- so capture its CommandInfo
    # here (where it IS visible) and invoke it via & instead.
    $dynExpr = Get-Command Invoke-DynamicExpression
    $execBlock = { & $dynExpr -Command $expression *>&1 }.GetNewClosure()
    $shouldRetryTransient = {
        param($info)
        if (-not $retryable) { return $false }
        $text = (@($info.Output) | ForEach-Object { [string]$_ }) -join "`n"
        return ($text -match $transientPattern)
    }.GetNewClosure()
    $retry = Invoke-WithYurunaRetry -Label $expression -ScriptBlock $execBlock -LogPath $toolLogFile -ShouldRetry $shouldRetryTransient
    $output   = $retry.LastOutput
    $toolExit = $retry.LastExit
    Set-Content -LiteralPath $toolRcFile -Value $toolExit -NoNewline
    # Shell can Write-Information back to the user, so stream visibly
    if ($kind.Name -eq 'shell') {
        $output | ForEach-Object { Write-Information ([string]$_) }
    }
    else {
        $output | ForEach-Object { Write-Verbose ([string]$_) }
    }
    if (-Not (0 -eq $toolExit)) {
        # Always abort the cycle on a non-zero tool exit. A swallowed
        # helm/kubectl failure leaves the bash wrapper's `set -e` with
        # nothing to catch, so the next sequence step (e.g.
        # test-localhost.sh) runs into a missing ingress controller and
        # times out minutes later -- masking the real fault.
        Write-Information "EXITCODE: $toolExit for: $expression"
        $output | ForEach-Object { Write-Information "$_" }
        Pop-Location
        return (New-YurunaResultManifest -Success $false -ErrorMessage "$toolName exit $toolExit for: $expression" -FailureClass 'tool_failed' -ExitCode $toolExit -DurationMs $sw.ElapsedMilliseconds)
    }
    Pop-Location
}

function Publish-WorkloadList {
    <#
    .SYNOPSIS
        Publish every workload declared in config/<subfolder>/workloads.yml.
    .DESCRIPTION
        Iterates each workload, switches to its kube context, and runs
        each deployment (chart | kubectl | helm | shell). Chart
        deployments are copied to the .yuruna work folder with merged
        variable values written to values.yaml before helm install.
    .OUTPUTS
        [hashtable] result manifest produced by New-YurunaResultManifest.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        $project_root,
        $config_subfolder
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (!(Confirm-WorkloadList $project_root $config_subfolder)) { return (New-YurunaResultManifest -Success $false -ErrorMessage "Confirm-WorkloadList failed for $project_root / $config_subfolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    Write-Debug "---- Publish Workloads"
    # For each workload: switch to its kube context, run each deployment
    # (chart | kubectl | helm | shell). For `chart`, copy to the .yuruna work
    # folder, merge variables (resources globals + resources.output + workload
    # globals + workload locals + deployment locals), write values.yaml, run
    # helm install. Non-chart deployments read the same merged variables via
    # ${env:vars}.
    $workloadsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/workloads.yml"
    if (-Not (Test-Path -Path $workloadsFile)) { Write-Information "File not found: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "File not found: $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $workloadsYaml = ConvertFrom-File $workloadsFile
    if ($null -eq $workloadsYaml) { Write-Information "Workloads null or empty in file: $workloadsFile"; return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }
    if ($null -eq $workloadsYaml.workloads) { Write-Information "Workloads null or empty in file: $workloadsFile"; return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }

    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    New-YurunaTimestampedBackup -SourceFile $workloadsFile -WorkFolder $workFolder -Prefix 'workloads'

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    $resourcesOutputYaml = $null
    if (Test-Path -Path $resourcesOutputFile) {
        $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile
    }
    else {
        # Allow phased workload deployment by reusing an upper-level resource output
        $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/../resources.output.yml"
        if (Test-Path -Path $resourcesOutputFile) {
            $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile
        }
    }

    # Resources output values go to env verbatim (-NoExpand): they are
    # terraform outputs plus already-expanded globals, so ExpandString is
    # a no-op on well-formed data but would execute $(...)/backtick
    # subexpressions echoed back by cloud resource names or tags.
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -EmitDebug -NoExpand
    # Global variables expanded into env and CACHED back so the second
    # pass (per-deployment) doesn't pay re-expansion cost.
    Set-ExpandedVariableHashtable -Variables $workloadsYaml.globalVariables -DebugLabel 'globalVariables' -CacheExpanded

    foreach ($workload in $workloadsYaml.workloads) {
        $contextName = $ExecutionContext.InvokeCommand.ExpandString($workload['context'])
        Write-Information "-- Workloads for context: $contextName"
        if ([string]::IsNullOrEmpty($contextName)) { Write-Information "workloads.context cannot be null or empty in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "workloads.context cannot be null or empty in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads/$contextName"
        if (-Not ([string]::IsNullOrEmpty($workFolder))) {
            $resolvedFolder = Resolve-Path -Path $workFolder -ErrorAction SilentlyContinue
            if (-Not ([string]::IsNullOrEmpty($resolvedFolder))) {
                Remove-Item -Path $resolvedFolder -Force -Recurse -ErrorAction SilentlyContinue
            }
        }
        if ([string]::IsNullOrEmpty($workFolder)) { Write-Information "workFolder cannot be null or empty in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "workFolder cannot be null or empty in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        Set-Item -Path Env:contextName -Value ${contextName}
        Set-Item -Path Env:workFolder -Value ${workFolder}

        Set-ExpandedVariableHashtable -Variables $workload.variables -DebugLabel 'workloadVariables'

        $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads/$contextName"
        $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
        # Save the operator's active context so the finally below can put the
        # shell back on it. Capture kubectl's exit code: a broken kubeconfig
        # makes the read fail, and blindly restoring an empty $originalContext
        # in the finally would error or clobber the operator's active context,
        # so gate the restore on a confirmed read.
        $originalContext = kubectl config current-context 2>$null
        $originalContextRead = ($LASTEXITCODE -eq 0) -and (-not [string]::IsNullOrWhiteSpace($originalContext))
        # Context must exist. `kubectl config get-contexts <name>` is a
        # non-mutating existence probe -- it exits non-zero when the context is
        # absent without switching the operator's current context, so a missing
        # context never leaves the shell on the wrong cluster.
        $null = kubectl config get-contexts $contextName *>&1
        $probeExit = $LASTEXITCODE
        if ($probeExit -ne 0) { Write-Information "K8S context '$contextName' not usable (cluster unreachable or context not found)`nFile: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "K8S context '$contextName' not usable (cluster unreachable or context not found) in $workloadsFile" -FailureClass 'cluster_unreachable' -DurationMs $sw.ElapsedMilliseconds); }
        # Activate the context for the deployment loop; every kubectl/helm call
        # below targets whatever the kubeconfig's current context is.
        kubectl config use-context $contextName *>&1 | Write-Verbose
        $useContextExit = $LASTEXITCODE
        if ($useContextExit -ne 0) { Write-Information "K8S context '$contextName' not usable (cluster unreachable or context not found)`nFile: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "K8S context '$contextName' not usable (cluster unreachable or context not found) in $workloadsFile" -FailureClass 'cluster_unreachable' -DurationMs $sw.ElapsedMilliseconds); }

        # Restore $originalContext in a finally so every early-return failure
        # path inside the per-deployment loop (and the normal end-of-loop exit)
        # leaves the operator's shell on the context they started with. Bare
        # try/finally with NO catch so YurunaCycleRestart and other message-
        # prefix control-flow markers still propagate to Invoke-Sequence
        # (guards against the generic-catch-eats-control-flow-markers class).
        try {
        foreach ($deployment in $workload.deployments) {
            # Effective deployment kind + the kinds phrase come from the
            # shared Yuruna.DeploymentKind catalog so a new kind is one
            # Register-YurunaDeploymentKind line and the phrase can't
            # diverge from the validator. Hoist the phrase once so the
            # should-be and must-be strings stay identical.
            $kind = Resolve-YurunaDeploymentKind -Deployment $deployment
            $expectedKinds = Get-YurunaDeploymentKindExpectedText
            if ($null -eq $kind) { Write-Information "context.deployment should be $expectedKinds in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "context.deployment must be $expectedKinds in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

            # Build the merged variable set: resources.output + workloads
            # globals + workload locals + deployment locals (latter wins).
            # Each layer is also pushed to env so ${env:...} references in
            # later layers resolve against the merged state.
            $deploymentVars = [ordered]@{}
            Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -Sink $deploymentVars -NoExpand
            Set-ExpandedVariableHashtable -Variables $workloadsYaml.globalVariables -Sink $deploymentVars
            Set-ExpandedVariableHashtable -Variables $workload.variables -Sink $deploymentVars
            Set-ExpandedVariableHashtable -Variables $deployment.variables -Sink $deploymentVars -DebugLabel 'deploymentVariables' -WarnOnEmpty

            if ($kind.IsChart) {
                $deploymentFailure = Invoke-WorkloadChartDeployment -project_root $project_root -config_subfolder $config_subfolder -contextName $contextName -deployment $deployment -deploymentVars $deploymentVars -workloadsFile $workloadsFile -sw $sw
            }
            else {
                $deploymentFailure = Invoke-WorkloadToolDeployment -kind $kind -project_root $project_root -config_subfolder $config_subfolder -contextName $contextName -deployment $deployment -deploymentVars $deploymentVars -sw $sw
            }
            if ($null -ne $deploymentFailure) { return $deploymentFailure }
        }
        }
        finally {
            if ($originalContextRead) { kubectl config use-context $originalContext *>&1 | Write-Verbose }
        }
    }

    return (New-YurunaResultManifest -Success $true -DurationMs $sw.ElapsedMilliseconds);
}

Export-ModuleMember -Function Publish-WorkloadList -Alias *
