<#PSScriptInfo
.VERSION 2026.05.29
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

function Set-ExpandedVariableHashtable {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only env vars and a caller-supplied sink; ShouldProcess would be noise per key.')]
    param(
        [Parameter()]$Variables,
        [Parameter()][System.Collections.IDictionary]$Sink,
        [string]$DebugLabel,
        [switch]$CacheExpanded,
        [switch]$WarnOnEmpty
    )
    if ($null -eq $Variables -or $null -eq $Variables.Keys) { return }
    $keys = @($Variables.Keys)
    foreach ($key in $keys) {
        $value = $ExecutionContext.InvokeCommand.ExpandString($Variables[$key])
        if ($WarnOnEmpty -and [string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
        if ($DebugLabel) { Write-Debug "$DebugLabel[$key] = $value" }
        Set-Item -Path Env:$key -Value $value
        if ($Sink) { $Sink[$key] = $value }
        if ($CacheExpanded) { $Variables[$key] = $value }
    }
}

function Set-ExpandedResourcesOutput {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Mutates only env vars and a caller-supplied sink; ShouldProcess would be noise per key.')]
    param(
        [Parameter()]$ResourcesOutputYaml,
        [Parameter()][System.Collections.IDictionary]$Sink,
        [switch]$EmitDebug
    )
    if ($null -eq $ResourcesOutputYaml -or $null -eq $ResourcesOutputYaml.Keys) { return }
    foreach ($resource in $ResourcesOutputYaml.Keys) {
        $isGlobal = ($resource -eq 'globalVariables')
        foreach ($key in $ResourcesOutputYaml.$resource.Keys) {
            if ($isGlobal) {
                $resourceKey = "$key"
                $raw = $ResourcesOutputYaml.$resource[$key]
            } else {
                $resourceKey = "$resource.$key"
                $raw = $ResourcesOutputYaml.$resource[$key].value
            }
            $value = $ExecutionContext.InvokeCommand.ExpandString($raw)
            if ($EmitDebug) {
                $label = if ($isGlobal) { 'globalVariables' } else { 'resourcesOutput' }
                Write-Debug "$label[$resourceKey] = $value"
            }
            Set-Item -Path Env:$resourceKey -Value $value
            if ($Sink) { $Sink[$resourceKey] = $value }
        }
    }
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

    # Backup workloadsFile to the .yuruna work folder
    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/workloads"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}',(Get-Date)))
    $backupFile = Join-Path -Path $workFolder -ChildPath "workloads.$dtTime.yml"
    Copy-Item "$workloadsFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $workloadsFile copied to: $backupFile"

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

    # Resources output is expanded for env lookup but not persisted back.
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -EmitDebug
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
        # Context must exist
        $originalContext = kubectl config current-context
        kubectl config use-context $contextName *>&1 | Write-Verbose
        $currentContext = kubectl config current-context
        kubectl config use-context $originalContext *>&1 | Write-Verbose
        if ($currentContext -ne $contextName) { Write-Information "K8S context not found: $contextName`nFile: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "K8S context not found: $contextName (workloads.yml: $workloadsFile)" -FailureClass 'cluster_unreachable' -DurationMs $sw.ElapsedMilliseconds); }
        kubectl config use-context $contextName *>&1 | Write-Verbose

        foreach ($deployment in $workload.deployments) {
            # Deployment kinds: chart | kubectl | helm | shell
            $isChart = !([string]::IsNullOrEmpty($deployment['chart']))
            $isKubectl = !([string]::IsNullOrEmpty($deployment['kubectl']))
            $isHelm = !([string]::IsNullOrEmpty($deployment['helm']))
            $isShell = !([string]::IsNullOrEmpty($deployment['shell']))
            if (!($isChart -or $isKubectl -or $isHelm -or $isShell)) { Write-Information "context.deployment should be 'chart', 'kubectl', 'helm' or 'shell' in file: $workloadsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "context.deployment must be 'chart', 'kubectl', 'helm' or 'shell' in $workloadsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

            # Build the merged variable set: resources.output + workloads
            # globals + workload locals + deployment locals (latter wins).
            # Each layer is also pushed to env so ${env:...} references in
            # later layers resolve against the merged state.
            $deploymentVars = [ordered]@{}
            Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -Sink $deploymentVars
            Set-ExpandedVariableHashtable -Variables $workloadsYaml.globalVariables -Sink $deploymentVars
            Set-ExpandedVariableHashtable -Variables $workload.variables -Sink $deploymentVars
            Set-ExpandedVariableHashtable -Variables $deployment.variables -Sink $deploymentVars -DebugLabel 'deploymentVariables' -WarnOnEmpty

            if ($isChart) {
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

                # Per-chart helm stderr/stdout log + final-rc sidecar. Mirrors
                # the tofu.stderr.log pattern from Set-Resource so Get-System
                # Diagnostic.ps1's *.stderr.log glob picks it up on failure.
                # Truncate at chart entry; per-helm-command output is appended
                # with a "=== <cmd> (exit=N) ===" header. helm.rc is rewritten
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
                Write-Debug "Helm lint"
                $lintOutput = helm lint *>&1
                $lintExit = $LASTEXITCODE
                Add-Content -LiteralPath $helmLogFile -Value "=== helm lint (exit=$lintExit) ==="
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
                        Add-Content -LiteralPath $helmLogFile -Value "=== pre-flight helm status (state=$pendingState; recovering) ==="
                        $statusOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_) }
                        $rollbackOutput = helm rollback $installName 0 2>&1
                        $rollbackExit = $LASTEXITCODE
                        Add-Content -LiteralPath $helmLogFile -Value "=== helm rollback $installName 0 (exit=$rollbackExit) ==="
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
                            Add-Content -LiteralPath $helmLogFile -Value "=== helm uninstall $installName --no-hooks (exit=$uninstallExit) ==="
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
                # release in the namespace). Replaces the prior uninstall
                # +install pair, which on a watchdog kill between the two
                # calls left the operator with no release AND a dirty
                # namespace and no recovery path beyond a full rerun.
                #
                # Non-zero exit is still authoritative -- the release
                # did NOT land (or it landed and was auto-rolled-back).
                # We ALSO scan the captured output for lines starting
                # with "Error:" because helm has historically returned 0
                # on certain post-render rejections (server-side
                # admission failures that surface only in the trailing
                # log). Either signal aborts the test sequence.
                Write-Debug "Helm upgrade --install --atomic $installName"
                $installOutput = helm upgrade --install --atomic $installName . --debug *>&1
                $installExit = $LASTEXITCODE
                Add-Content -LiteralPath $helmLogFile -Value "=== helm upgrade --install --atomic $installName --debug (exit=$installExit) ==="
                $installOutput | ForEach-Object { Add-Content -LiteralPath $helmLogFile -Value ([string]$_); Write-Verbose "$_" }
                Set-Content -LiteralPath $helmRcFile -Value $installExit -NoNewline
                $installErrorLines = @($installOutput | Where-Object { $_ -match '^\s*Error:' })
                if ($installExit -ne 0 -or $installErrorLines.Count -gt 0) {
                    Write-Information "helm upgrade --install --atomic '$installName' FAILED (exit $installExit, $($installErrorLines.Count) Error: line(s)) in $workFolder"
                    $installOutput | ForEach-Object { Write-Information "$_" }
                    Pop-Location
                    return (New-YurunaResultManifest -Success $false -ErrorMessage "helm upgrade --install --atomic '$installName' failed in $workFolder (exit $installExit, $($installErrorLines.Count) Error: line(s))" -FailureClass 'tool_failed' -ExitCode $installExit -DurationMs $sw.ElapsedMilliseconds)
                }
                Pop-Location
            }
            else {
                # Push deploymentVars to the environment for command expansion
                foreach ($key in $deploymentVars.Keys) {
                    $value = $deploymentVars[$key]
                    Set-Item -Path Env:$key -Value ${value}
                }
                Set-Item -Path Env:contextName -Value ${contextName}
                $expression = $null
                $toolName = $null
                if ($isKubectl) { $value = $deployment['kubectl']; $expression = "kubectl $value"; $toolName = 'kubectl' }
                if ($isHelm) { $value = $deployment['helm']; $expression = "helm $value"; $toolName = 'helm' }
                if ($isShell) { $value = $deployment['shell']; $expression = "$value"; $toolName = 'shell' }

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
                # helm fetches (repo update, install <repo>/<chart>) cross the network
                # and stutter on shared-egress rate limits or proxy blips. Symptom:
                # `Error: INSTALLATION FAILED: failed to fetch https://github.com/...`
                # Multiple hosts sharing one squid egress IP can fail inside a
                # sub-second window -- a shared upstream event, not per-host config.
                # Retry helm up to 3 times with exponential backoff (10s, 20s) ONLY
                # when the output matches a transient-fetch pattern; real config errors
                # (chart not found, schema violation, auth) fail fast.
                $maxAttempts = if ($isHelm) { 3 } else { 1 }
                $attemptDelay = 10
                $transientPattern = '(?i)(failed to fetch|i/o timeout|no such host|connection refused|connection reset|client\.timeout|EOF|TLS handshake|temporary failure|503 |502 |504 |429 |too many requests)'
                $output = $null
                $toolExit = 0
                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    $output = Invoke-DynamicExpression -Command $expression *>&1
                    $toolExit = $LASTEXITCODE
                    if ($toolExit -eq 0) { break }
                    if ($attempt -ge $maxAttempts) { break }
                    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
                    if ($outputText -notmatch $transientPattern) { break }
                    Write-Information "TRANSIENT helm failure (exit $toolExit, attempt $attempt/$maxAttempts) -- retrying in ${attemptDelay}s: $expression"
                    Add-Content -LiteralPath $toolLogFile -Value "=== $expression (exit=$toolExit, attempt $attempt/$maxAttempts, transient -- will retry in ${attemptDelay}s) ==="
                    $output | ForEach-Object { Add-Content -LiteralPath $toolLogFile -Value ([string]$_) }
                    Start-Sleep -Seconds $attemptDelay
                    $attemptDelay = $attemptDelay * 2
                }
                Add-Content -LiteralPath $toolLogFile -Value "=== $expression (exit=$toolExit) ==="
                $output | ForEach-Object { Add-Content -LiteralPath $toolLogFile -Value ([string]$_) }
                Set-Content -LiteralPath $toolRcFile -Value $toolExit -NoNewline
                # Shell can Write-Information back to the user, so stream visibly
                if ($isShell) {
                    $output | ForEach-Object { Write-Information ([string]$_) }
                }
                else {
                    $output | ForEach-Object { Write-Verbose ([string]$_) }
                }
                if (-Not (0 -eq $toolExit)) {
                    # Always abort the cycle on a non-zero tool exit.
                    # The prior `return ($ErrorActionPreference -eq "Continue")` returned
                    # $true under the default EAP=Continue, swallowing helm/kubectl
                    # failures so the bash wrapper's `set -e` had nothing to catch and
                    # the next sequence step (e.g. test-localhost.sh) ran into a missing
                    # ingress controller and timed out 3 minutes later -- masking the
                    # real fault. Match the chart branch above: any non-zero exit aborts.
                    Write-Information "EXITCODE: $toolExit for: $expression"
                    $output | ForEach-Object { Write-Information "$_" }
                    Pop-Location
                    return (New-YurunaResultManifest -Success $false -ErrorMessage "$toolName exit $toolExit for: $expression" -FailureClass 'tool_failed' -ExitCode $toolExit -DurationMs $sw.ElapsedMilliseconds)
                }
                Pop-Location
            }
        }
        kubectl config use-context $originalContext *>&1 | Write-Verbose
    }

    return (New-YurunaResultManifest -Success $true -DurationMs $sw.ElapsedMilliseconds);
}

Export-ModuleMember -Function Publish-WorkloadList -Alias *
