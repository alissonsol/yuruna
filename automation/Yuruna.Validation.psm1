<#PSScriptInfo
.VERSION 2026.06.05
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

function Confirm-FolderList {
    param (
        $project_root,
        $config_subfolder
    )
    if ([string]::IsNullOrEmpty($project_root)) { Write-Information "Project path is null or empty"; return $false; }
    if ([string]::IsNullOrEmpty($config_subfolder)) { Write-Information "Configuration subfolder is null or empty"; return $false; }

    $config_relative = Join-Path -Path $project_root -ChildPath "config/$config_subfolder"
    $config_root = Resolve-Path -Path $config_relative -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($config_root)) { Write-Information "Configuration subfolder not found: $config_relative"; return $false; }

    if (-Not (Test-Path -Path $project_root)) { Write-Information "Project path not found: $project_root"; return $false; }
    if (-Not (Test-Path -Path $config_root)) { Write-Information "Config path not found: $config_root"; return $false; }

    return $true;
}

function Confirm-GlobalVariableList {
    param (
        $yaml,
        $filePath
    )

    if (-Not ($null -eq  $yaml.globalVariables)) {
        foreach ($key in $yaml.globalVariables.Keys) {
            $value = $yaml.globalVariables[$key]
            if ([string]::IsNullOrEmpty($value)) { Write-Information "globalVariables.$key cannot be null or empty in file: $filePath"; return $false; }
        }
    }

    return $true;
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
    if (-not (Test-Path -Path $SecretsFolder)) { return $true }
    Write-Debug "---- Validating Secrets folder: $SecretsFolder"
    $files = Get-ChildItem -Path $SecretsFolder -Filter *.txt
    foreach ($file in $files) {
        Write-Verbose "Checking secret file: $file"
        $content = Get-Content $file
        if ([string]::IsNullOrEmpty($content)) {
            Write-Information "Empty secret file: $file"
            if ($RequireNonEmpty) { return $false }
        }
        git update-index --assume-unchanged $file
    }
    return $true
}

function Confirm-ResourceList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Resources"
    if (!(Confirm-FolderList $project_root $config_subfolder)) { return $false; }

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return $false; }
    $yaml = ConvertFrom-File $resourcesFile

    if (!(Confirm-GlobalVariableList $yaml $resourcesFile)) { return $false; }

    if ($null -eq $yaml.resources) { Write-Information "Resources cannot be null or empty in file: $resourcesFile"; return $false; }
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
        if ([string]::IsNullOrEmpty($resourceName)) { Write-Information "Resource without name in file: $resourcesFile"; return $false; }
        if (-not $seenResourceNames.Add($resourceName)) { Write-Information "Duplicate resource name '$resourceName' in file: $resourcesFile"; return $false; }
        $resourceNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($resourceName)
        if ([string]::IsNullOrEmpty($resourceNameExpanded)) { Write-Information "Resource '$resourceName' may expand to empty name in file: $resourcesFile"; }
        elseif (-not $seenResourceNamesExpanded.Add($resourceNameExpanded)) { Write-Information "Duplicate resource name '$resourceNameExpanded' (expanded from '$resourceName') in file: $resourcesFile"; return $false; }
        $resourceTemplate = $resource['template']
        $templateProjectFolder = Join-Path -Path $project_root -ChildPath "resources/$resourceTemplate" -ErrorAction SilentlyContinue
        if (($null -eq $templateProjectFolder) -or (-Not (Test-Path -Path $templateProjectFolder))) {
            $templateGlobalFolder = Join-Path -Path $yuruna_root  -ChildPath "global/resources/$resourceTemplate" -ErrorAction SilentlyContinue
            if (($null -eq $templateGlobalFolder) -or (-Not (Test-Path -Path $templateGlobalFolder))) {
                Write-Information "Resources template not found locally or globally: $resourceTemplate`nUsed in file: $resourcesFile";
                Write-Information "Not found local folder: $templateProjectFolder";
                Write-Information "Not found global folder: $templateGlobalFolder";
                return $false;
            }
        }
        if (-Not ($null -eq  $resource.variables)) {
            foreach ($key in $resource.variables.Keys) {
                $value = $resource.variables[$key]
                if ([string]::IsNullOrEmpty($value)) { Write-Information "resource[$resourceName][$key] cannot be null or empty in file: $resourcesFile"; return $false; }
            }
        }
    }

    # Non-empty secrets are informational for resources — creation proceeds.
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/secrets"
    $null = Invoke-SecretFolderValidation -SecretsFolder $secrets_folder

    return $true;
}

function Confirm-ResourceOutputList {
    param (
        $project_root,
        $config_subfolder
    )

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    # Valid for the resources output not to exist yet
    if (-Not (Test-Path -Path $resourcesOutputFile)) { Write-Verbose "Resources output file not found: $resourcesOutputFile"; return $true; }
    $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile

    if ($null -eq $resourcesOutputYaml) { Write-Information "resources output cannot be null or empty in file: $resourcesOutputFile"; return $false; }
    # Validation is read-only: push RAW values (-NoExpand). Variable expansion
    # is the publishers' job at publish time; the validator mirrors the
    # Component publisher's -NoExpand debug pass and does not expand here.
    Set-ExpandedResourcesOutput -ResourcesOutputYaml $resourcesOutputYaml -NoExpand -EmitDebug

    return $true;
}

function Confirm-ComponentList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Components"
    if (!(Confirm-FolderList $project_root $config_subfolder)) { return $false; }
    if (!(Confirm-ResourceOutputList $project_root $config_subfolder)) { return $false; }

    $componentsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/components.yml"
    if (-Not (Test-Path -Path $componentsFile)) { Write-Information "File not found: $componentsFile"; return $false; }
    $yaml = ConvertFrom-File $componentsFile

    if (!(Confirm-GlobalVariableList $yaml $componentsFile)) { return $false; }

    if ($null -eq $yaml.components) { Write-Information "Components null or empty in file: $componentsFile"; }
    # Two components sharing a project key build/tag/push to the same image
    # identity (Publish-ComponentList derives the build folder and image off the
    # expanded project), so the second overwrites the first. Reject raw + post-
    # expansion duplicates, mirroring the resources.yml name dedup.
    $seenProjects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $seenProjectsExpanded = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($component in $yaml.components) {
        $project = $component['project']
        if ([string]::IsNullOrEmpty($project)) { Write-Information "component.project cannot be null or empty in file: $componentsFile"; return $false; }
        if (-not $seenProjects.Add($project)) { Write-Information "Duplicate component project '$project' in file: $componentsFile"; return $false; }
        $projectExpanded = $ExecutionContext.InvokeCommand.ExpandString($project)
        if ([string]::IsNullOrEmpty($projectExpanded)) { Write-Information "Component project '$project' may expand to empty in file: $componentsFile"; }
        elseif (-not $seenProjectsExpanded.Add($projectExpanded)) { Write-Information "Duplicate component project '$projectExpanded' (expanded from '$project') in file: $componentsFile"; return $false; }
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) { Write-Verbose "component.buildPath for $project is null in file: $componentsFile"; }

        $buildCommand = $component['buildCommand']
        if ([string]::IsNullOrEmpty($buildCommand)) { $buildCommand = $yaml.globalVariables['buildCommand']; }
        if ([string]::IsNullOrEmpty($buildCommand)) { Write-Information "buildCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }
        $tagCommand = $component['tagCommand']
        if ([string]::IsNullOrEmpty($tagCommand)) { $tagCommand = $yaml.globalVariables['tagCommand']; }
        if ([string]::IsNullOrEmpty($tagCommand)) { Write-Information "tagCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }
        $pushCommand = $component['pushCommand']
        if ([string]::IsNullOrEmpty($pushCommand)) { $pushCommand = $yaml.globalVariables['pushCommand']; }
        if ([string]::IsNullOrEmpty($pushCommand)) { Write-Information "pushCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }

        $buildFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "components/$buildPath") -ErrorAction SilentlyContinue
        if (($null -eq $buildFolder) -or (-Not (Test-Path -Path $buildFolder))) { Write-Information "Components folder not found: $buildPath`nUsed in file: $componentsFile"; return $false; }
    }

    return $true;
}

function Confirm-WorkloadList {
    param (
        $project_root,
        $config_subfolder
    )
    Write-Debug "---- Validating Workloads"
    if (!(Confirm-FolderList $project_root $config_subfolder)) { return $false; }
    if (!(Confirm-ResourceOutputList $project_root $config_subfolder)) { return $false; }

    $workloadsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/workloads.yml"
    if (-Not (Test-Path -Path $workloadsFile)) { Write-Information "File not found: $workloadsFile"; return $false; }
    $yaml = ConvertFrom-File $workloadsFile

    if (!(Confirm-GlobalVariableList $yaml $workloadsFile)) { return $false; }

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
        if ([string]::IsNullOrEmpty($contextName)) { Write-Information "workloads.context cannot be null or empty in file: $workloadsFile"; return $false; }
        if (-not $seenContexts.Add($contextRaw)) { Write-Information "Duplicate workload context '$contextRaw' in file: $workloadsFile"; return $false; }
        if (-not $seenContextsExpanded.Add($contextName)) { Write-Information "Duplicate workload context '$contextName' (expanded from '$contextRaw') in file: $workloadsFile"; return $false; }
        $originalContext = kubectl config current-context
        kubectl config use-context $contextName *>&1 | Write-Verbose
        $currentContext = kubectl config current-context
        kubectl config use-context $originalContext *>&1 | Write-Verbose
        if ($currentContext -ne $contextName) { Write-Debug "K8S context not found: $contextName`nFile: $workloadsFile"; }
        foreach ($deployment in $workload.deployments) {
            # Effective deployment kind + the kinds phrase come from the
            # shared Yuruna.DeploymentKind catalog so a new kind is one
            # Register-YurunaDeploymentKind line and the phrase can't
            # diverge from the publisher.
            $kind = Resolve-YurunaDeploymentKind -Deployment $deployment
            if ($null -eq $kind) { Write-Information "context.deployment should be $(Get-YurunaDeploymentKindExpectedText) in file: $workloadsFile"; return $false; }
            if ($kind.IsChart) {
                $chartName = $deployment['chart'];
                if ([string]::IsNullOrEmpty($chartName)) { Write-Information "context.chart cannot be null or empty in file: $workloadsFile"; return $false; }
                $chartFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "workloads/$chartName") -ErrorAction SilentlyContinue
                if (($null -eq $chartFolder) -or (-Not (Test-Path -Path $chartFolder))) { Write-Information "workload[$contextName]chart[$chartName] folder not found: $chartFolder"; return $false; }
                foreach ($key in $deployment.variables.Keys) {
                    $value = $deployment.variables[$key]
                    if ([string]::IsNullOrEmpty($value)) { Write-Information "workload[$contextName]chart[$chartName][$key] variable cannot be null or empty in file: $workloadsFile"; return $false; }
                }
                $installName = $deployment.variables['installName']
                if ([string]::IsNullOrEmpty($installName)) { Write-Information "workload[$contextName]chart[$chartName]variables['installName'] cannot be null or empty in file: $workloadsFile"; return $false; }
                $installNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($installName)
                if (-not $seenWorkloadReleases.Add("$contextName`n$installNameExpanded")) { Write-Information "Duplicate workload release '$installNameExpanded' in context '$contextName' in file: $workloadsFile"; return $false; }
            }
            # For kubectl/helm/shell the null/empty check above is sufficient.
        }
    }

    # Non-empty secrets are required — missing content blocks workload execution.
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/secrets"
    if (-not (Invoke-SecretFolderValidation -SecretsFolder $secrets_folder -RequireNonEmpty)) { return $false }
    # Peer folder accommodates workloads that share a parent-level vault
    # across multiple config subfolders (a single set of credentials feeds
    # several deployment configs without duplicating the .txt files).
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/../secrets"
    if (-not (Invoke-SecretFolderValidation -SecretsFolder $secrets_folder -RequireNonEmpty)) { return $false }

    return $true;
}

function Confirm-Configuration {
    param (
        $project_root,
        $config_subfolder
    )

    if (!(Confirm-ResourceList $project_root $config_subfolder)) { return $false; }
    if (!(Confirm-ComponentList $project_root $config_subfolder)) { return $false; }
    if (!(Confirm-WorkloadList $project_root $config_subfolder)) { return $false; }

    return $true;
}

Export-ModuleMember -Function * -Alias *
