<#PSScriptInfo
.VERSION 0.2
.GUID 06e8bceb-f7aa-47e8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2020-2022 Alisson Sol et al.
.TAGS yuruna-validation
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/import-yaml"
Import-Module -Name $modulePath

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

    # Validate globalVariables
    if (-Not ($null -eq  $yaml.globalVariables)) {
        foreach ($key in $yaml.globalVariables.Keys) {
            $value = $yaml.globalVariables[$key]
            if ([string]::IsNullOrEmpty($value)) { Write-Information "globalVariables.$key cannot be null or empty in file: $filePath"; return $false; }
        }
    }

    return $true;
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

    # Validate resources list
    if ($null -eq $yaml.resources) { Write-Information "Resources cannot be null or empty in file: $resourcesFile"; return $false; }
    foreach ($resource in $yaml.resources) {
        $resourceName = $resource['name']
        if ([string]::IsNullOrEmpty($resourceName)) { Write-Information "Resource without name in file: $resourcesFile"; return $false; }
        $resourceNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($resourceName)
        if ([string]::IsNullOrEmpty($resourceNameExpanded)) { Write-Information "Resource '$resourceName' may expand to empty name in file: $resourcesFile"; }
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
        # Variables
        if (-Not ($null -eq  $resource.variables)) {
            foreach ($key in $resource.variables.Keys) {
                $value = $resource.variables[$key]
                if ([string]::IsNullOrEmpty($value)) { Write-Information "resource[$resourceName][$key] cannot be null or empty in file: $resourcesFile"; return $false; }
            }
        }
    }

    # Secrets, if defined, shouldn't be empty
    $secrets_folder = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/secrets"
    if (Test-Path -Path $secrets_folder) {
        $files = Get-ChildItem -Path $secrets_folder -Filter *.txt
        foreach ($file in $files){
            Write-Verbose "Checking secret file: $file"
            $content = Get-Content $file
            if ([string]::IsNullOrEmpty($content)) { Write-Information "Empty secret file: $file"; return $false; }
            git update-index --assume-unchanged $file
        }
    }

    return $true;
}

function Confirm-ResourceOutputList {
    param (
        $project_root,
        $config_subfolder
    )

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    # If is valid for the resources output not to exist yet
    if (-Not (Test-Path -Path $resourcesOutputFile)) { Write-Verbose "Resources output file not found: $resourcesOutputFile"; return $true; }
    $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile

    # Validate resources output list
    if ($null -eq $resourcesOutputYaml) { Write-Information "resources output cannot be null or empty in file: $resourcesOutputFile"; return $false; }
    if ((-Not ($null -eq $resourcesOutputYaml)) -and (-Not ($null -eq  $resourcesOutputYaml.Keys))) {
        foreach ($resource in $resourcesOutputYaml.Keys) {
            if ($resource -eq "globalVariables") {
                foreach ($key in $resourcesOutputYaml.$resource.Keys) {
                    $resourceKey = "$key"
                    $value = $resourcesOutputYaml.$resource[$key]
                    Write-Debug "globalVariables[$resourceKey] = $value"
                    Set-Item -Path Env:$resourceKey -Value ${value}
                }
            }
            else {
                foreach ($key in $resourcesOutputYaml.$resource.Keys) {
                    $resourceKey = "$resource.$key"
                    $value = $resourcesOutputYaml.$resource[$key].value
                    Write-Debug "resourcesOutput[$resourceKey] = $value"
                    Set-Item -Path Env:$resourceKey -Value ${value}
                }
            }
        }
    }

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

    # Validate components list
    if ($null -eq $yaml.components) { Write-Information "Components null or empty in file: $componentsFile"; }
    foreach ($component in $yaml.components) {
        $project = $component['project']
        if ([string]::IsNullOrEmpty($project)) { Write-Information "component.project cannot be null or empty in file: $componentsFile"; return $false; }
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) { Write-Information "component.buildPath cannot be null or empty in file: $componentsFile"; return $false; }

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

    # Validate workloads list
    if ($null -eq $yaml.workloads) { Write-Information "Workloads null or empty in file: $workloadsFile"; }
    foreach ($workload in $yaml.workloads) {
        # context should exist
        $contextName = $ExecutionContext.InvokeCommand.ExpandString($workload['context'])
        if ([string]::IsNullOrEmpty($contextName)) { Write-Information "workloads.context cannot be null or empty in file: $workloadsFile"; return $false; }
        $originalContext = kubectl config current-context
        kubectl config use-context $contextName *>&1 | Write-Verbose
        $currentContext = kubectl config current-context
        kubectl config use-context $originalContext *>&1 | Write-Verbose
        if ($currentContext -ne $contextName) { Write-Debug "K8S context not found: $contextName`nFile: $workloadsFile"; }
        # deployments shoudn't be null or empty
        foreach ($deployment in $workload.deployments) {
            # valid deployments are chart, kubectl, helm and shell
            $isChart = !([string]::IsNullOrEmpty($deployment['chart']))
            $isKubectl = !([string]::IsNullOrEmpty($deployment['kubectl']))
            $isHelm = !([string]::IsNullOrEmpty($deployment['helm']))
            $isShell = !([string]::IsNullOrEmpty($deployment['shell']))
            if (!($isChart -or $isKubectl -or $isHelm -or $isShell)) { Write-Information "context.deployment should be 'chart', 'kubectl', 'helm' or 'shell' in file: $workloadsFile"; return $false; }
            if ($isChart) {
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
            }
            # if ($isKubectl -or $isHelm -or $isShell)
            # only possibility: verify it is not null or empty, what has already been done!
        }
    }

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
