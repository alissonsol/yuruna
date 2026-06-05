<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42e3a5b6-c7d8-4901-2345-6e7f80910213
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Resource
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
# Loaded -Global so downstream modules and the parent shell can use
# New-YurunaResultManifest and Test-YurunaResultManifestOk on the values
# this module returns.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force
# Shared retry policy with the guest-side automation/yuruna-retry.sh.
# --- See https://yuruna.link/network#defining-yuruna-retry-lib
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Retry.psm1') -Force

$globalVariables = [ordered]@{}

# Tail size sized to capture a typical tofu Error block (header + 1-2
# frame lines + provider message) without flooding the test-runner log
# on a multi-screen warning dump. Full rationale:
# https://yuruna.link/memory#why-tofu-failure-throws-include-the-stderr-tail
$script:tofuStderrTailLines = 30

function Get-TofuStderrTail {
    [OutputType([string])]
    param([string] $tofuLogFile)
    if ([string]::IsNullOrEmpty($tofuLogFile) -or -Not (Test-Path -LiteralPath $tofuLogFile)) {
        return ""
    }
    $tail = Get-Content -LiteralPath $tofuLogFile -Tail $script:tofuStderrTailLines -ErrorAction SilentlyContinue
    if ($null -eq $tail) { return "" }
    return "`n--- tail of $tofuLogFile (last $script:tofuStderrTailLines lines) ---`n" + ($tail -join "`n")
}

function Publish-ResourceListHelper {
    [OutputType([hashtable])]
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [string] $project_root,
        [string] $config_subfolder,
        [bool] $isInitialization
    )

    Write-Debug "     isInitialization: $isInitialization"
    # For each resource in resources.yml: copy template to .yuruna work folder,
    # apply variables, run tofu apply there (creates local .terraform that
    # tofu destroy will reuse).

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "File not found: $resourcesFile" -FailureClass 'config_error'); }
    $yaml = ConvertFrom-File $resourcesFile

    if ($isInitialization) {
        # Global variables are saved expanded after first time so resources.output
        # can re-use them.
        if ((-Not ($null -eq $yaml.globalVariables)) -and (-Not ($null -eq $yaml.globalVariables.Keys))) {
            $keys = @($yaml.globalVariables.Keys)
            foreach ($key in $keys) {
                $value = $ExecutionContext.InvokeCommand.ExpandString($yaml.globalVariables[$key])
                Write-Debug "resources.globalVariables[$key] = $value"
                Set-Item -Path Env:$key -Value ${value}
                $yaml.globalVariables[$key] = $value
                $globalVariables.Add($key, $value)
            }
        }
    }
    else {
        $yamlExpanded = @{ }
        $yamlExpanded.Add("globalVariables", $globalVariables)
        $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
        $null = New-Item -Path $resourcesOutputFile -ItemType File -Force
        Add-Content -Path $resourcesOutputFile -Value $(ConvertTo-Yaml $yamlExpanded)
    }

    if ($null -eq $yaml.resources) { Write-Information "Resources null or empty in file: $resourcesFile"; return (New-YurunaResultManifest -Success $true -Skipped $true); }
    foreach ($resource in $yaml.resources) {
        $resourceName = $resource['name']
        $resourceNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($resourceName)
        Write-Verbose "$resourceName = $resourceNameExpanded"
        $resourceName = $resourceNameExpanded
        $resourceTemplate = $resource['template']
        if ([string]::IsNullOrEmpty($resourceName)) { Write-Information "Resource without name in file: $resourcesFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "Resource without name in file: $resourcesFile" -FailureClass 'config_error'); }
        # Empty template: just naming an already-existing resource
        if (![string]::IsNullOrEmpty($resourceTemplate)) {
            $templateFolder = Join-Path -Path $project_root -ChildPath "resources/$resourceTemplate" -ErrorAction SilentlyContinue
            if (($null -eq $templateFolder) -or (-Not (Test-Path -Path $templateFolder))) {
                $templateFolder = Join-Path -Path $yuruna_root  -ChildPath "global/resources/$resourceTemplate" -ErrorAction SilentlyContinue
                if (($null -eq $templateFolder) -or (-Not (Test-Path -Path $templateFolder))) {
                    Write-Information "Resources template not found locally or globally: $resourceTemplate`nUsed in file: $resourcesFile";
                    return (New-YurunaResultManifest -Success $false -ErrorMessage "Resources template not found: $resourceTemplate (used in $resourcesFile)" -FailureClass 'config_error');
                }
            }
            if ($isInitialization) {
                Write-Information "-- Initializing: $resourceName from template $templateFolder"
            }
            else {
                Write-Information "-- Creating: $resourceName from template $templateFolder"
            }
            # Atomic template refresh via staging directory. Stage
            # template + any carry-over tofu state (.terraform/,
            # .terraform.lock.hcl, tofu.planfile) into a sibling
            # <workFolder>.new directory, then atomic-swap via Move-Item:
            #   1. live  -> <name>.old
            #   2. .new  -> live
            #   3. .old  -> trash
            # Step 2's failure rolls .old back to live so the cycle
            # never observes a half-applied template. A .workfolder.
            # complete marker is written immediately after the swap so
            # a downstream consumer can verify the staging finished.
            # Guards against the tofu silent-cascade trap (output -json
            # -> {} -> empty resources.output.yml -> malformed helm
            # refs); see feedback_tofu_null_resource_provisioner_silent_cascade.md.
            #
            # -ErrorAction Stop on every copy: a permission blip, AV
            # lock, or templateFolder typo aborts the resource loudly
            # instead of silently producing an empty workFolder that
            # the silent-cascade trap then consumes.
            $workFolderRoot = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources/$resourceName"
            $workFolderNew  = "$workFolderRoot.new"
            $workFolderOld  = "$workFolderRoot.old"
            # SIGKILL recovery: the swap below is "live -> .old; .new -> live"
            # with a PowerShell catch that rolls back if Move-Item itself throws.
            # A process kill (watchdog SIGTERM/SIGKILL, host shutdown, BSOD)
            # between the two moves leaves only <workFolder>.old on disk; the
            # catch never runs. Without this guard, the staging branch below
            # sees `Test-Path $workFolderRoot == $false`, skips the .terraform/
            # tofu.planfile carry-over, and the next `tofu apply` runs against
            # a freshly-created folder with no provider state -- usually
            # destroying actual cloud resources.
            #
            # Detect that signature (no live, .old present) and restore
            # before any other staging step runs.
            if (-not (Test-Path -LiteralPath $workFolderRoot) -and (Test-Path -LiteralPath $workFolderOld)) {
                Write-Verbose "Set-Resource: recovering '$resourceName' from .old (prior-cycle SIGKILL between swap moves)."
                Move-Item -LiteralPath $workFolderOld -Destination $workFolderRoot -Force
            }
            if (Test-Path -LiteralPath $workFolderNew) {
                Remove-Item -LiteralPath $workFolderNew -Recurse -Force
            }
            $null = New-Item -ItemType Directory -Force -Path $workFolderNew
            Copy-Item -Path "$templateFolder/*" -Destination $workFolderNew -Recurse -Container -ErrorAction Stop
            if (Test-Path -LiteralPath $workFolderRoot) {
                foreach ($carryOver in @('.terraform', '.terraform.lock.hcl', 'tofu.planfile')) {
                    $src = Join-Path -Path $workFolderRoot -ChildPath $carryOver
                    if (Test-Path -LiteralPath $src) {
                        Copy-Item -LiteralPath $src -Destination $workFolderNew -Recurse -Force -ErrorAction Stop
                    }
                }
                if (Test-Path -LiteralPath $workFolderOld) {
                    Remove-Item -LiteralPath $workFolderOld -Recurse -Force
                }
                Move-Item -LiteralPath $workFolderRoot -Destination $workFolderOld
                try {
                    Move-Item -LiteralPath $workFolderNew -Destination $workFolderRoot
                } catch {
                    Move-Item -LiteralPath $workFolderOld -Destination $workFolderRoot -Force
                    throw
                }
                Remove-Item -LiteralPath $workFolderOld -Recurse -Force -ErrorAction SilentlyContinue
            } else {
                Move-Item -LiteralPath $workFolderNew -Destination $workFolderRoot
            }
            $workFolder = Resolve-Path -Path $workFolderRoot
            # .workfolder.complete marker: proves staging+swap finished.
            # A watchdog kill before the marker write leaves either no
            # work folder or the previous cycle's unchanged copy --
            # never a half-applied template that tofu would silently
            # consume.
            $completeMarker = Join-Path -Path $workFolder -ChildPath '.workfolder.complete'
            Set-Content -LiteralPath $completeMarker -Value ([DateTime]::UtcNow.ToString('o')) -Encoding utf8NoBOM -ErrorAction Stop

            Set-Item -Path Env:resourceName -Value ${resourceName}
            $terraformVarsFile = Join-Path -Path $workFolder -ChildPath "terraform.tfvars"
            $null = New-Item -Path $terraformVarsFile -ItemType File -Force
            $terraformVars = [ordered]@{}
            foreach ($key in $globalVariables.Keys) {
                $value = $globalVariables[$key]
                $terraformVars[$key] = $value
                Set-Item -Path Env:$key -Value ${value}
            }
            if (-Not ($null -eq $resource.variables)) {
                foreach ($key in $resource.variables.Keys) {
                    $value = $resource.variables[$key]
                    $terraformVars[$key] = $value
                    Write-Verbose "resourceVariables[$key] = $value"
                    Set-Item -Path Env:$key -Value ${value}
                }
            }
            foreach ($key in $terraformVars.Keys) {
                $value = $ExecutionContext.InvokeCommand.ExpandString($terraformVars[$key])
                if ([string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
                $line = "$key = `"$value`""
                Add-Content -Path $terraformVarsFile -Value $line
                Set-Item -Path Env:$key -Value ${value}
                Write-Debug "$line"
            }
            Push-Location $workFolder

            $terraformPath = Join-Path -Path $workFolder -ChildPath ".terraform"
            if ($isInitialization -and (Test-Path -Path $terraformPath)) {
                Write-Information "-- WARNING: tofu already initialized: $terraformPath `n   Resource may not be created. Use 'yuruna clear' to clear tofu state.";
                Pop-Location;
                return (New-YurunaResultManifest -Success $false -ErrorMessage "tofu already initialized at $terraformPath (run 'yuruna clear' first)" -FailureClass 'config_error');
            }
            # Per-resource tofu stderr/stdout log. Stable path so re-runs
            # overwrite -- the latest attempt is what matters.
            $tofuLogFile = Join-Path -Path $workFolder -ChildPath "tofu.stderr.log"
            Remove-Item -LiteralPath $tofuLogFile -Force -ErrorAction SilentlyContinue
            # Exit-code sidecar (tofu.rc) next to tofu.stderr.log so the
            # post-mortem diagnostic's rc-scan resolves the tofu outcome; the
            # retry helper rewrites it on each init / apply / output pass.
            $tofuRcFile = Join-Path -Path $workFolder -ChildPath "tofu.rc"
            Remove-Item -LiteralPath $tofuRcFile -Force -ErrorAction SilentlyContinue

            Write-Debug "OpenTofu init"
            # Exponential backoff with jitter shared with the guest-side
            # automation/yuruna-retry.sh (Yuruna.Retry.psm1). Defaults
            # (5 attempts, 10s initial delay, *=2, +/-25% jitter) widen
            # the retry window past github.com's typical 5xx blip so a
            # transient provider-download failure no longer fails the
            # cycle. TF_PLUGIN_CACHE_DIR (set above) ensures every
            # subsequent attempt and every subsequent cycle reads the
            # already-fetched plugin from disk instead of redownloading.
            # --- See https://yuruna.link/network#defining-yuruna-retry-lib
            $retryResult = Invoke-TofuInitWithRetry -ResourceName $resourceName -LogPath $tofuLogFile -RcFile $tofuRcFile
            if (-not $retryResult.Success) {
                Pop-Location
                throw ("tofu init failed for resource '$resourceName' after $($retryResult.Attempts) attempts (final exit $($retryResult.LastExit)). Inspect $tofuLogFile for the underlying error (often a 5xx from registry.opentofu.org or a provider checksum mismatch)." + (Get-TofuStderrTail $tofuLogFile))
            }

            Write-Debug "Executing tofu command from $workFolder"
            # --- See https://yuruna.link/memory#why-set-resource-uses-a-saved-planfile-for-apply
            $planFile = Join-Path -Path $workFolder -ChildPath "tofu.planfile"
            # tofu plan and the saved-planfile apply are safe to re-run on a
            # transient failure: plan is read-only, and a saved-planfile apply
            # re-applies the same plan. The refreshing-apply fallback is NOT --
            # it recomputes the plan, so a retry after a partial apply is not
            # safely idempotent and must fail loudly.
            $retryableTofu = $true
            if ($isInitialization) {
                $resolvedCommand = "tofu plan -input=false -compact-warnings -out=`"$planFile`""
            }
            else {
                if (Test-Path -LiteralPath $planFile) {
                    $resolvedCommand = "tofu apply -input=false -auto-approve `"$planFile`""
                }
                else {
                    # Missing planfile: fall back to a refreshing apply.
                    Write-Verbose "Planfile not found at $planFile; falling back to refreshing apply."
                    $resolvedCommand = "tofu apply -input=false -auto-approve"
                    $retryableTofu = $false
                }
            }
            # Retry on a transient signal only (a network blip reaching a
            # provider / registry / data-source, or remote-state-backend lock
            # contention); a real plan or null_resource provisioner error does
            # not match the shared classifier and fails fast. Mirrors the
            # tofu-init retry above and the helm/kubectl retry in
            # Yuruna.Workload -- one Yuruna.Retry policy + classifier. The
            # closures capture the command and predicate by value because the
            # retry scriptblock runs in the Yuruna.Retry module scope, which
            # cannot see this module's private Invoke-DynamicExpression import
            # by name -- so capture its CommandInfo here and invoke it via &.
            $dynExprCmd = Get-Command Invoke-DynamicExpression
            $transientTest = Get-Command Test-YurunaTransientFailure
            $applyBlock = { & $dynExprCmd -Command $resolvedCommand *>&1 }.GetNewClosure()
            $applyShouldRetry = {
                param($info)
                if (-not $retryableTofu) { return $false }
                return [bool](& $transientTest -Output $info.Output)
            }.GetNewClosure()
            $applyRetry = Invoke-WithYurunaRetry -Label $resolvedCommand -ScriptBlock $applyBlock -LogPath $tofuLogFile -RcFile $tofuRcFile -ShouldRetry $applyShouldRetry
            $applyLog  = $applyRetry.LastOutput
            $applyExit = $applyRetry.LastExit
            $applyLog | ForEach-Object { Write-Verbose ([string]$_) }
            if ($applyExit -ne 0) {
                Pop-Location
                throw ("tofu command '$resolvedCommand' failed for resource '$resourceName' (exit $applyExit). Inspect $tofuLogFile for the underlying error (often a null_resource provisioner returning non-zero, or a data-source program failing)." + (Get-TofuStderrTail $tofuLogFile))
            }

            if (-Not $isInitialization) {
                # `tofu output -json` crosses the network too (remote state
                # backends) and hits the same lock / 5xx transients, so retry
                # it on the shared classifier. The retry helper merges streams
                # with 2>&1, so filter out ErrorRecords (stderr) before the
                # parse -- a stray warning line must not corrupt the JSON.
                $outputShouldRetry = {
                    param($info)
                    return [bool](& $transientTest -Output $info.Output)
                }.GetNewClosure()
                $outputRetry = Invoke-WithYurunaRetry -Label "tofu output -json ($resourceName)" -LogPath $tofuLogFile -RcFile $tofuRcFile -ShouldRetry $outputShouldRetry -ScriptBlock { & tofu output -json }
                $outputExit = $outputRetry.LastExit
                $jsonOutput = (@($outputRetry.LastOutput) | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n"
                if ($outputExit -ne 0) {
                    Pop-Location
                    throw ("tofu output -json failed for resource '$resourceName' (exit $outputExit). Inspect $tofuLogFile." + (Get-TofuStderrTail $tofuLogFile))
                }
                if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
                    Pop-Location
                    throw "tofu output -json returned empty for resource '$resourceName' -- this codebase requires every resource to define at least one `output` block. Add one in $templateFolder/*.tf, or remove the resource from resources.yml if it is no longer needed."
                }
                $terraformYaml = $jsonOutput | ConvertFrom-Json
                # --- See https://yuruna.link/memory#why-set-resource-fails-fast-on-empty-tofu-outputs
                $propsList = @($terraformYaml.PSObject.Properties)
                if ($propsList.Count -eq 0) {
                    Pop-Location
                    throw ("tofu output -json returned {} for resource '$resourceName' -- apply succeeded but every `output` block evaluated to empty. The null_resource provisioner under $templateFolder almost certainly failed silently (no exit code, no stdout). Check $tofuLogFile and the provisioner scripts in $templateFolder." + (Get-TofuStderrTail $tofuLogFile))
                }
                $tuple = @{ }
                $tuple."$resourceName" = $terraformYaml
                Add-Content -Path $resourcesOutputFile -Value $(ConvertTo-Yaml $tuple)
            }
            Pop-Location
        }
    }

    if (-Not $isInitialization) {
        if ((Get-Item $resourcesOutputFile).Length -gt 0) { Write-Information "Resources output file: $resourcesOutputFile"; }
    }

    return (New-YurunaResultManifest -Success $true);
}

function Publish-ResourceList {
    [OutputType([hashtable])]
    param (
        $project_root,
        $config_subfolder
    )

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Debug "---- Publishing Resources"
    # Two-pass tofu run; see
    # https://yuruna.link/memory#why-set-resource-uses-a-saved-planfile-for-apply
    if (!(Confirm-ResourceList $project_root $config_subfolder)) { return (New-YurunaResultManifest -Success $false -ErrorMessage "Confirm-ResourceList failed for $project_root / $config_subfolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

    # Unattended-mode signal: silences tofu's interactive hints and the
    # curses progress UI (the latter trips pwsh-on-Linux Write-Progress).
    Set-Item -Path Env:TF_IN_AUTOMATION -Value "1"

    # On-disk provider cache shared across resources and cycles. Once
    # `tofu init` has fetched a provider, subsequent inits reuse the
    # cached plugin instead of round-tripping to github.com — guards
    # against the registry-5xx-burst class where releases.github.com /
    # registry.opentofu.org returns the same 5xx within a tight retry
    # window, so a per-attempt retry loop cannot survive the burst but
    # a cached plugin sidesteps it entirely. The cache is self-
    # populating; nothing external (squid, network mirror) needs to be
    # reachable. Operator can override the path via TF_PLUGIN_CACHE_DIR;
    # otherwise it lives under the project's .yuruna/ tree so a
    # `yuruna clear` purges it. plugin_cache_may_break_dependency_lock_file:
    # harmless here because every resource is its own working dir with
    # its own .terraform.lock.hcl.
    if (-not $env:TF_PLUGIN_CACHE_DIR) {
        $defaultPluginCache = Join-Path -Path $project_root -ChildPath ".yuruna/tofu-plugin-cache"
        $null = New-Item -ItemType Directory -Force -Path $defaultPluginCache -ErrorAction SilentlyContinue
        Set-Item -Path Env:TF_PLUGIN_CACHE_DIR -Value (Resolve-Path -LiteralPath $defaultPluginCache).Path
    }

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "File not found: $resourcesFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}',(Get-Date)))
    $backupFile = Join-Path -Path $workFolder -ChildPath "resources.$dtTime.yml"
    Copy-Item "$resourcesFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $resourcesFile copied to: $backupFile"

    # Helper now returns a result manifest -- branch on its .success key
    # (Test-YurunaResultManifestOk handles null/missing-key defensively).
    $initResult = Publish-ResourceListHelper -project_root $project_root -config_subfolder $config_subfolder -isInitialization $true
    if (Test-YurunaResultManifestOk $initResult) {
        $applyResult = Publish-ResourceListHelper -project_root $project_root -config_subfolder $config_subfolder -isInitialization $false
        # Preserve the helper's failureClass/errorMessage/exitCode but stamp
        # the outer wall-clock duration so the manifest reflects total work.
        $applyResult['durationMs'] = $sw.ElapsedMilliseconds
        return $applyResult
    }

    $initResult['durationMs'] = $sw.ElapsedMilliseconds
    return $initResult
}

Export-ModuleMember -Function * -Alias *
