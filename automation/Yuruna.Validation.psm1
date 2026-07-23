<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d2f4a5-b6c7-4890-1234-5d6e7f809102
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Validation
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
$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Import.Yaml.psm1"
Import-Module -Name $modulePath
# Set-ExpandedResourcesOutput is the single source of the resources.output
# env-push walk; the validator reuses it so its env state can't diverge
# from the Component/Workload publishers. -Global -Force so the exported
# function stays resolvable from any nested scope.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.VariableExpansion.psm1') -Global -Force
# Shared deployment-kind catalog: Confirm-WorkloadList resolves the
# effective kind and the kinds phrase from it so detection and the error
# text can't diverge from Publish-WorkloadList. -Global -Force per
# feedback_module_force_import_evicts_global.md.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.DeploymentKind.psm1') -Global -Force
# New-YurunaValidationResult decorates a boxed [bool] with a Reason so the
# actionable failure pointer travels with the pass/fail decision instead of
# reaching only Write-Information (silenced at Error/Warning). -Global -Force
# per feedback_module_force_import_evicts_global.md.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force

function Confirm-FolderList {
    param (
        $project_root,
        $config_subfolder
    )
    if ([string]::IsNullOrEmpty($project_root)) { $r = "Project path is null or empty"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    if ([string]::IsNullOrEmpty($config_subfolder)) { $r = "Configuration subfolder is null or empty"; Write-Information $r; return (New-YurunaValidationResult $false $r); }

    $config_relative = Join-Path -Path $project_root -ChildPath "config/$config_subfolder"
    $config_root = Resolve-Path -Path $config_relative -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($config_root)) { $r = "Configuration subfolder not found: $config_relative"; Write-Information $r; return (New-YurunaValidationResult $false $r); }

    if (-Not (Test-Path -Path $project_root)) { $r = "Project path not found: $project_root"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    if (-Not (Test-Path -Path $config_root)) { $r = "Config path not found: $config_root"; Write-Information $r; return (New-YurunaValidationResult $false $r); }

    return (New-YurunaValidationResult $true);
}

function Confirm-GlobalVariableList {
    param (
        $yaml,
        $filePath
    )

    if (-Not ($null -eq  $yaml.globalVariables)) {
        foreach ($key in $yaml.globalVariables.Keys) {
            $value = $yaml.globalVariables[$key]
            if ([string]::IsNullOrEmpty($value)) { $r = "globalVariables.$key cannot be null or empty in file: $filePath"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        }
    }

    return (New-YurunaValidationResult $true);
}

function Invoke-SecretFolderValidation {
    # Walks every *.txt under $SecretsFolder and marks each git-assume-
    # unchanged so an operator editing a vault file locally never trips
    # `git status` noise. Empty content is informational for resources
    # (-RequireNonEmpty omitted) and blocking for workloads (the chart's
    # values will substitute the empty string for a password placeholder
    # and silently produce a malformed Secret in the cluster).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SecretsFolder,
        [switch]$RequireNonEmpty
    )
    if (-not (Test-Path -Path $SecretsFolder)) { return (New-YurunaValidationResult $true) }
    Write-Debug "---- Validating Secrets folder: $SecretsFolder"
    $files = Get-ChildItem -Path $SecretsFolder -Filter *.txt
    foreach ($file in $files) {
        Write-Verbose "Checking secret file: $file"
        # Read as one raw string and test for whitespace, so a whitespace-only or multi-line-blank
        # vault file is caught too: Get-Content (no -Raw) returns a string[] on which
        # IsNullOrEmpty is $false, letting a blank secret pass and bake a malformed cluster Secret.
        $content = Get-Content $file -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            $r = "Empty secret file: $file"
            Write-Information $r
            if ($RequireNonEmpty) { return (New-YurunaValidationResult $false $r) }
        }
        git update-index --assume-unchanged $file
    }
    return (New-YurunaValidationResult $true)
}

function Confirm-ResourceList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Resources"
    $folderResult = Confirm-FolderList $project_root $config_subfolder
    if (!($folderResult)) { return (New-YurunaValidationResult $false $folderResult.Reason); }

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { $r = "File not found: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    $yaml = ConvertFrom-File $resourcesFile

    $globalResult = Confirm-GlobalVariableList $yaml $resourcesFile
    if (!($globalResult)) { return (New-YurunaValidationResult $false $globalResult.Reason); }

    if ($null -eq $yaml.resources) { $r = "Resources cannot be null or empty in file: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    # Colliding resource names stage into the same .yuruna/<subfolder>/
    # resources/<name> work folder, so the second tofu apply overwrites the
    # first's template and carried-over state -- one resource is silently
    # never created while the manifest reports only the last apply. Reject
    # raw duplicates (copy-paste) and post-expansion collisions (distinct
    # names that resolve to the same string). Ordinal because Set-Resource
    # uses the expanded name verbatim as the path segment.
    $seenResourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenResourceNamesExpanded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($resource in $yaml.resources) {
        $resourceName = $resource['name']
        if ([string]::IsNullOrEmpty($resourceName)) { $r = "Resource without name in file: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        if (-not $seenResourceNames.Add($resourceName)) { $r = "Duplicate resource name '$resourceName' in file: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $resourceNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($resourceName)
        if ([string]::IsNullOrEmpty($resourceNameExpanded)) { Write-Information "Resource '$resourceName' may expand to empty name in file: $resourcesFile"; }
        elseif (-not $seenResourceNamesExpanded.Add($resourceNameExpanded)) { $r = "Duplicate resource name '$resourceNameExpanded' (expanded from '$resourceName') in file: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $resourceTemplate = $resource['template']
        $templateProjectFolder = Join-Path -Path $project_root -ChildPath "resources/$resourceTemplate" -ErrorAction SilentlyContinue
        if (($null -eq $templateProjectFolder) -or (-Not (Test-Path -Path $templateProjectFolder))) {
            $templateGlobalFolder = Join-Path -Path $yuruna_root  -ChildPath "global/resources/$resourceTemplate" -ErrorAction SilentlyContinue
            if (($null -eq $templateGlobalFolder) -or (-Not (Test-Path -Path $templateGlobalFolder))) {
                $r = "Resources template not found locally or globally: $resourceTemplate`nUsed in file: $resourcesFile";
                Write-Information $r;
                Write-Information "Not found local folder: $templateProjectFolder";
                Write-Information "Not found global folder: $templateGlobalFolder";
                return (New-YurunaValidationResult $false $r);
            }
        }
        if (-Not ($null -eq  $resource.variables)) {
            foreach ($key in $resource.variables.Keys) {
                $value = $resource.variables[$key]
                if ([string]::IsNullOrEmpty($value)) { $r = "resource[$resourceName][$key] cannot be null or empty in file: $resourcesFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
            }
        }
    }

    # Non-empty secrets are informational for resources -- creation proceeds.
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/secrets"
    $null = Invoke-SecretFolderValidation -SecretsFolder $secrets_folder

    return (New-YurunaValidationResult $true);
}

function Confirm-ResourceOutputList {
    param (
        $project_root,
        $config_subfolder
    )

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    # Valid for the resources output not to exist yet
    if (-Not (Test-Path -Path $resourcesOutputFile)) { Write-Verbose "Resources output file not found: $resourcesOutputFile"; return (New-YurunaValidationResult $true); }
    $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile

    if ($null -eq $resourcesOutputYaml) { $r = "resources output cannot be null or empty in file: $resourcesOutputFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    # Validation is read-only: push RAW values (-NoExpand). Variable expansion
    # is the publishers' job at publish time; the validator mirrors the
    # Component publisher's -NoExpand debug pass and does not expand here.
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -NoExpand -EmitDebug

    return (New-YurunaValidationResult $true);
}

function Confirm-ComponentList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Components"
    $folderResult = Confirm-FolderList $project_root $config_subfolder
    if (!($folderResult)) { return (New-YurunaValidationResult $false $folderResult.Reason); }
    $outputResult = Confirm-ResourceOutputList $project_root $config_subfolder
    if (!($outputResult)) { return (New-YurunaValidationResult $false $outputResult.Reason); }

    $componentsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/components.yml"
    if (-Not (Test-Path -Path $componentsFile)) { $r = "File not found: $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    $yaml = ConvertFrom-File $componentsFile

    $globalResult = Confirm-GlobalVariableList $yaml $componentsFile
    if (!($globalResult)) { return (New-YurunaValidationResult $false $globalResult.Reason); }

    if ($null -eq $yaml.components) { Write-Information "Components null or empty in file: $componentsFile"; }
    # Two components sharing a project key build/tag/push to the same image
    # identity (Publish-ComponentList derives the build folder and image off the
    # expanded project), so the second overwrites the first. Reject raw + post-
    # expansion duplicates, mirroring the resources.yml name dedup.
    $seenProjects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenProjectsExpanded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($component in $yaml.components) {
        $project = $component['project']
        if ([string]::IsNullOrEmpty($project)) { $r = "component.project cannot be null or empty in file: $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        if (-not $seenProjects.Add($project)) { $r = "Duplicate component project '$project' in file: $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $projectExpanded = $ExecutionContext.InvokeCommand.ExpandString($project)
        if ([string]::IsNullOrEmpty($projectExpanded)) { Write-Information "Component project '$project' may expand to empty in file: $componentsFile"; }
        elseif (-not $seenProjectsExpanded.Add($projectExpanded)) { $r = "Duplicate component project '$projectExpanded' (expanded from '$project') in file: $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) { Write-Verbose "component.buildPath for $project is null in file: $componentsFile"; }

        $buildCommand = $component['buildCommand']
        if ([string]::IsNullOrEmpty($buildCommand)) { $buildCommand = $yaml.globalVariables['buildCommand']; }
        if ([string]::IsNullOrEmpty($buildCommand)) { $r = "buildCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $tagCommand = $component['tagCommand']
        if ([string]::IsNullOrEmpty($tagCommand)) { $tagCommand = $yaml.globalVariables['tagCommand']; }
        if ([string]::IsNullOrEmpty($tagCommand)) { $r = "tagCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        $pushCommand = $component['pushCommand']
        if ([string]::IsNullOrEmpty($pushCommand)) { $pushCommand = $yaml.globalVariables['pushCommand']; }
        if ([string]::IsNullOrEmpty($pushCommand)) { $r = "pushCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }

        $buildFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "components/$buildPath") -ErrorAction SilentlyContinue
        if (($null -eq $buildFolder) -or (-Not (Test-Path -Path $buildFolder))) { $r = "Components folder not found: $buildPath`nUsed in file: $componentsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    }

    return (New-YurunaValidationResult $true);
}

function Confirm-WorkloadList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Workloads"
    $folderResult = Confirm-FolderList $project_root $config_subfolder
    if (!($folderResult)) { return (New-YurunaValidationResult $false $folderResult.Reason); }
    $outputResult = Confirm-ResourceOutputList $project_root $config_subfolder
    if (!($outputResult)) { return (New-YurunaValidationResult $false $outputResult.Reason); }

    $workloadsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/workloads.yml"
    if (-Not (Test-Path -Path $workloadsFile)) { $r = "File not found: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    $yaml = ConvertFrom-File $workloadsFile

    $globalResult = Confirm-GlobalVariableList $yaml $workloadsFile
    if (!($globalResult)) { return (New-YurunaValidationResult $false $globalResult.Reason); }

    if ($null -eq $yaml.workloads) { Write-Information "Workloads null or empty in file: $workloadsFile"; }
    # A chart deploys as a helm release <installName> into <context>; two
    # chart deployments sharing both keys hit the same release, so the second
    # silently upgrades over the first instead of installing a distinct
    # workload. The helm install lands before any folder is reused, so this
    # is defense-in-depth -- flagging it pre-flight turns a confusing
    # in-cluster overwrite into a clear config error.
    # Two workloads sharing a kube context collide: Publish-WorkloadList wipes
    # .yuruna/<subfolder>/workloads/<context> at the start of EACH workload, so
    # the second silently clobbers the first's staged charts/values. Reject raw
    # copy-paste duplicates and post-expansion collisions (distinct raw contexts
    # that resolve to the same string), mirroring the resources.yml name dedup.
    $seenContexts = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenContextsExpanded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenWorkloadReleases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($workload in $yaml.workloads) {
        $contextRaw = $workload['context']
        $contextName = $ExecutionContext.InvokeCommand.ExpandString($contextRaw)
        if ([string]::IsNullOrEmpty($contextName)) { $r = "workloads.context cannot be null or empty in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        if (-not $seenContexts.Add($contextRaw)) { $r = "Duplicate workload context '$contextRaw' in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        if (-not $seenContextsExpanded.Add($contextName)) { $r = "Duplicate workload context '$contextName' (expanded from '$contextRaw') in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
        # Non-mutating existence probe: `kubectl config get-contexts <name>` exits non-zero when
        # the context is absent WITHOUT switching the operator's current context. Probing with
        # use-context instead would mutate live state and leave the shell on the wrong context
        # if anything threw between the switch and the restore.
        $null = kubectl config get-contexts $contextName *>&1
        if ($LASTEXITCODE -ne 0) { Write-Debug "K8S context not found: $contextName`nFile: $workloadsFile"; }
        foreach ($deployment in $workload.deployments) {
            # Effective deployment kind + the kinds phrase come from the
            # shared Yuruna.DeploymentKind catalog so a new kind is one
            # Register-YurunaDeploymentKind line and the phrase can't
            # diverge from the publisher.
            $kind = Resolve-YurunaDeploymentKind -Deployment $deployment
            if ($null -eq $kind) { $r = "context.deployment should be $(Get-YurunaDeploymentKindExpectedText) in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
            if ($kind.IsChart) {
                $chartName = $deployment['chart'];
                if ([string]::IsNullOrEmpty($chartName)) { $r = "context.chart cannot be null or empty in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
                $chartFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "workloads/$chartName") -ErrorAction SilentlyContinue
                if (($null -eq $chartFolder) -or (-Not (Test-Path -Path $chartFolder))) { $r = "workload[$contextName]chart[$chartName] folder not found: $chartFolder"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
                foreach ($key in $deployment.variables.Keys) {
                    $value = $deployment.variables[$key]
                    if ([string]::IsNullOrEmpty($value)) { $r = "workload[$contextName]chart[$chartName][$key] variable cannot be null or empty in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
                }
                $installName = $deployment.variables['installName']
                if ([string]::IsNullOrEmpty($installName)) { $r = "workload[$contextName]chart[$chartName]variables['installName'] cannot be null or empty in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
                $installNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($installName)
                if (-not $seenWorkloadReleases.Add("$contextName`n$installNameExpanded")) { $r = "Duplicate workload release '$installNameExpanded' in context '$contextName' in file: $workloadsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
            }
            # For kubectl/helm/shell the null/empty check above is sufficient.
        }
    }

    # Non-empty secrets are required -- missing content blocks workload execution.
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/secrets"
    $secretsResult = Invoke-SecretFolderValidation -SecretsFolder $secrets_folder -RequireNonEmpty
    if (-not ($secretsResult)) { return (New-YurunaValidationResult $false $secretsResult.Reason) }
    # Peer folder accommodates workloads that share a parent-level vault
    # across multiple config subfolders (a single set of credentials feeds
    # several deployment configs without duplicating the .txt files).
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/../secrets"
    $peerSecretsResult = Invoke-SecretFolderValidation -SecretsFolder $secrets_folder -RequireNonEmpty
    if (-not ($peerSecretsResult)) { return (New-YurunaValidationResult $false $peerSecretsResult.Reason) }

    return (New-YurunaValidationResult $true);
}

function Confirm-Configuration {
    param (
        $project_root,
        $config_subfolder
    )

    $resourceResult = Confirm-ResourceList $project_root $config_subfolder
    if (!($resourceResult)) { return (New-YurunaValidationResult $false $resourceResult.Reason); }
    $componentResult = Confirm-ComponentList $project_root $config_subfolder
    if (!($componentResult)) { return (New-YurunaValidationResult $false $componentResult.Reason); }
    $workloadResult = Confirm-WorkloadList $project_root $config_subfolder
    if (!($workloadResult)) { return (New-YurunaValidationResult $false $workloadResult.Reason); }

    return (New-YurunaValidationResult $true);
}

Export-ModuleMember -Function * -Alias *
