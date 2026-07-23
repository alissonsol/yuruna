<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a9c1d2-e3f4-4567-8901-2a3b4c5d6e7f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Component
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
# Yuruna.VariableExpansion. Component passes -NoExpand because its
# layering happens at the YAML level -- ExpandString here would
# interpolate against whatever happens to be in env at the moment,
# which is exactly what the layered model is meant to avoid.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.VariableExpansion.psm1') -Global -Force
# Registry-login dispatcher. Yuruna.Component.Registry bridges to the
# credential-provider registry in automation/Yuruna.CredentialProvider
# so this pipeline's "registryLogin" phase and the test harness's
# self-heal Repair-Credential path agree on what the login command is
# for any given registry hostname. Adding a new registry kind (ECR,
# GAR, Docker Hub, Harbor, ...) is one Register-CredentialProvider
# call inside Yuruna.CredentialProvider; nothing to edit here.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Component.Registry.psm1') -Global -Force
Remove-Item Env:DOCKER_BUILDKIT -Force -ErrorAction SilentlyContinue

function Publish-ComponentList {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param (
        $project_root,
        $config_subfolder
    )

    # Split the inner scriptblock's pipeline: hashtables become the manifest
    # (via $state, which the ForEach-Object child scope can mutate), and every
    # other line routes to the host via Out-Default so replayed phase output
    # cannot array-wrap the manifest returned to callers.
    # --- REGION: https://yuruna.link/memory#why-publish-componentlist-splits-its-pipeline-through-a-state-hashtable
    $state = @{ manifest = $null }
    & {
    param($project_root, $config_subfolder)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    if (!(Confirm-ComponentList $project_root $config_subfolder)) { return (New-YurunaResultManifest -Success $false -ErrorMessage "Confirm-ComponentList failed for $project_root / $config_subfolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    Write-Debug "---- Publishing Components"
    # For each component: merge variables (resources global + resources.output
    # + component-level globals + component locals), run buildCommand from the
    # folder, then tag and push to the registry. Commands come from components.yml.

    $componentsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/components.yml"
    if (-Not (Test-Path -Path $componentsFile)) { Write-Information "File not found: $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "File not found: $componentsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
    $componentsYaml = ConvertFrom-File $componentsFile
    if ($null -eq $componentsYaml) { Write-Information "Components null or empty in file: $componentsFile"; return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }
    if ($null -eq $componentsYaml.components) { Write-Information "Components null or empty in file: $componentsFile"; return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $sw.ElapsedMilliseconds); }

    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/components"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    New-YurunaTimestampedBackup -SourceFile $componentsFile -WorkFolder $workFolder -Prefix 'components'

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    $resourcesOutputYaml = $null
    if (Test-Path -Path $resourcesOutputFile) {
        $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile
    }

    # Resources output and component-globals pushed to env verbatim
    # (no ExpandString -- layering is done at the YAML level).
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -NoExpand -EmitDebug
    Set-ExpandedVariableHashtable -Variables $componentsYaml.globalVariables -NoExpand -DebugLabel 'globalVariables'

    $componentsPath = Join-Path -Path $project_root -ChildPath "components/"

    # Per-environment docker stderr/stdout log + final-rc sidecar. Mirrors
    # Set-Resource's tofu.stderr.log pattern so Get-SystemDiagnostic.ps1's
    # *.stderr.log glob picks it up on failure. All components in this run
    # append to the same log (preProcessor/build/postProcessor/tag/login/push
    # per component); docker.rc is rewritten after each docker call so the
    # LAST exit code is what the diagnostic reports. Truncated at the start
    # of the run so a re-run doesn't inherit stale text.
    $dockerLogFile = Join-Path -Path $workFolder -ChildPath "docker.stderr.log"
    $dockerRcFile  = Join-Path -Path $workFolder -ChildPath "docker.rc"
    Remove-Item -LiteralPath $dockerLogFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dockerRcFile  -Force -ErrorAction SilentlyContinue

    function Invoke-ComponentCommand {
        # Run a build-pipeline command, capture all streams into the per-
        # environment docker.stderr.log with a "== [$Phase] <cmd> (exit=N)
        # ==" header, rewrite docker.rc with the latest exit code, and
        # replay the captured output onto the parent stdout so the test
        # runner's transcript still shows what docker did. Sets the global
        # $LASTEXITCODE so the caller's `if (-Not (0 -eq $LASTEXITCODE))`
        # checks see this phase's exit code.
        param([string]$Phase, [string]$Command)
        $out = Invoke-DynamicExpression -Command $Command *>&1
        # Pure-PowerShell command sequences (no native exe in the chain)
        # leave $LASTEXITCODE at its prior value -- $null in a freshly-
        # started pwsh process. The caller's `if (-Not (0 -eq $LASTEXITCODE))`
        # then evaluates `0 -eq $null` to $false and treats the phase as a
        # tool failure. Coerce so "no native command ran" reads as success.
        $rc  = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
        Add-Content -LiteralPath $dockerLogFile -Value "== [$Phase] $Command (exit=$rc) =="
        $out | ForEach-Object { Add-Content -LiteralPath $dockerLogFile -Value ([string]$_) }
        Set-Content -LiteralPath $dockerRcFile -Value $rc -NoNewline
        $out | ForEach-Object { Write-Output ([string]$_) }
        $global:LASTEXITCODE = $rc
    }

    foreach ($component in $componentsYaml.components) {
        $projectName = $component['project']
        if ([string]::IsNullOrEmpty($projectName)) { Write-Information "component.project cannot be null or empty in file: $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "component.project cannot be null or empty in file: $componentsFile" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $projectNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($projectName)
        Write-Verbose "$projectName = $projectNameExpanded"
        $projectName = $projectNameExpanded
        Set-Item -Path Env:projectName -Value ${projectName}
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) {
            $buildPath = $projectName;
        }
        $buildPath = $ExecutionContext.InvokeCommand.ExpandString($buildPath)

        $buildFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "components/$buildPath")
        if (-Not (Test-Path -Path $buildFolder)) { Write-Information "Components folder not found: $buildFolder`nUsed in file: $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "Components folder not found: $buildFolder (used in $componentsFile)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        Write-Information "-- Component: $projectName from $buildFolder"

        # No string expansion for the components script here; values are
        # layered in order: resources globals, resources.output, components
        # globals, component locals. Each layer is also pushed to env via
        # the helper's per-key Set-Item.
        $componentVars = [ordered]@{}
        Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -Sink $componentVars -NoExpand
        Set-ExpandedVariableHashtable -Variables $componentsYaml.globalVariables -Sink $componentVars -NoExpand
        Set-ExpandedVariableHashtable -Variables $component.variables -Sink $componentVars -NoExpand -DebugLabel 'componentVariables'

        $buildCommand = $component['buildCommand']
        if ([string]::IsNullOrEmpty($buildCommand)) { $buildCommand = $componentsYaml.globalVariables['buildCommand'] }
        if ([string]::IsNullOrEmpty($buildCommand)) { Write-Information "buildCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "buildCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

        $dockerfile = Join-Path -Path $buildFolder -ChildPath "Dockerfile"
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "$projectName-dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { Write-Information "Missing dockerfile in folder: $buildFolder"; return (New-YurunaResultManifest -Success $false -ErrorMessage "Missing dockerfile in folder: $buildFolder" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }

        $componentVars['project'] = $projectName
        $componentVars['buildPath'] = $buildPath
        $componentVars['dockerfile'] = $dockerfile
        foreach ($key in $componentVars.Keys) {
            $value = $componentVars[$key]
            if ([string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
            Set-Item -Path Env:$key -Value ${value}
            Write-Debug "$projectName[Env:$key] is $(Get-Content -Path Env:$key)"
        }

        Push-Location $componentsPath
        $preProcessor = $componentVars['preProcessor']
        if ([string]::IsNullOrEmpty($preProcessor)) { $preProcessor = $componentsYaml.globalVariables['preProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($preProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($preProcessor)
            Write-Information "preProcessor: $executionCommand"
            Invoke-ComponentCommand -Phase "preProcessor[$projectName]" -Command $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for preProcessor: $executionCommand"
                # A non-zero tool exit is a failure: report success=$false so a
                # consumer keying on `success` (Complete-YurunaRun, diagnostics)
                # catches it. The exit code + failureClass carry the triage
                # detail. Deriving success from the ambient $ErrorActionPreference
                # instead would let a failed build/tag/push masquerade as a pass
                # at the framework defaults (EAP stays 'Continue').
                return (New-YurunaResultManifest -Success $false -ErrorMessage "preProcessor[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }

        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($buildCommand)
        Write-Debug "Build: $executionCommand"
        Invoke-ComponentCommand -Phase "build[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Build: $executionCommand"
            return (New-YurunaResultManifest -Success $false -ErrorMessage "build[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }

        $postProcessor = $componentVars['postProcessor']
        if ([string]::IsNullOrEmpty($postProcessor)) { $postProcessor = $componentsYaml.globalVariables['postProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($postProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($postProcessor)
            Write-Information "postProcessor: $executionCommand"
            Invoke-ComponentCommand -Phase "postProcessor[$projectName]" -Command $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for postProcessor: $executionCommand"
                return (New-YurunaResultManifest -Success $false -ErrorMessage "postProcessor[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }
        Pop-Location

        $tagCommand = $component['tagCommand']
        if ([string]::IsNullOrEmpty($tagCommand)) { $tagCommand = $componentsYaml.globalVariables['tagCommand']; }
        if ([string]::IsNullOrEmpty($tagCommand)) { Write-Information "tagCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "tagCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $pushCommand = $component['pushCommand']
        if ([string]::IsNullOrEmpty($pushCommand)) { $pushCommand = $componentsYaml.globalVariables['pushCommand']; }
        if ([string]::IsNullOrEmpty($pushCommand)) { Write-Information "pushCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return (New-YurunaResultManifest -Success $false -ErrorMessage "pushCommand cannot be null or empty in $componentsFile (both globalVariables and component level)" -FailureClass 'config_error' -DurationMs $sw.ElapsedMilliseconds); }
        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($tagCommand)
        Write-Debug "Tag: $executionCommand"
        Invoke-ComponentCommand -Phase "tag[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Tag: $executionCommand"
            return (New-YurunaResultManifest -Success $false -ErrorMessage "tag[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }

        # Registry login dispatched through Yuruna.Component.Registry
        # (Azure ACR, ECR, GAR, Docker Hub, generic). $null means "no
        # provider matched or this provider opted out" -- silently skip
        # the phase and let the operator's pre-existing docker
        # credential helper handle the push.
        $registryLocation = $([Environment]::GetEnvironmentVariable("${env:registryName}.registryLocation"))
        $loginCommand = Resolve-ComponentRegistryLogin -RegistryLocation $registryLocation
        if ($loginCommand) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString("$loginCommand *>&1")
            Invoke-ComponentCommand -Phase "registryLogin[$projectName]" -Command $executionCommand | Write-Verbose
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for: $executionCommand"
                return (New-YurunaResultManifest -Success $false -ErrorMessage "registryLogin[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
            }
        }

        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($pushCommand)
        Write-Debug "Push: $executionCommand"
        Invoke-ComponentCommand -Phase "push[$projectName]" -Command $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Push: $executionCommand"
            return (New-YurunaResultManifest -Success $false -ErrorMessage "push[$projectName] exit ${LASTEXITCODE}: $executionCommand" -FailureClass 'tool_failed' -ExitCode $LASTEXITCODE -DurationMs $sw.ElapsedMilliseconds);
        }
    }

    return (New-YurunaResultManifest -Success $true -DurationMs $sw.ElapsedMilliseconds);

    } $project_root $config_subfolder | ForEach-Object {
        if ($_ -is [System.Collections.IDictionary]) {
            $state.manifest = $_
        }
        else {
            $_ | Out-Default
        }
    }

    if ($null -eq $state.manifest) {
        return (New-YurunaResultManifest -Success $false -ErrorMessage 'Publish-ComponentList produced no manifest' -FailureClass 'unknown')
    }
    return $state.manifest
}

Export-ModuleMember -Function * -Alias *
