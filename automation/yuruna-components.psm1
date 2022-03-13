<#PSScriptInfo
.VERSION 0.3
.GUID 06e8bceb-f7aa-47e8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2020-2022 Alisson Sol et al.
.TAGS yuruna-components
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
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/yuruna-validation"
Import-Module -Name $validationModulePath

function Publish-ComponentList {
    param (
        $project_root,
        $config_subfolder
    )

    if (!(Confirm-ComponentList $project_root $config_subfolder)) { return $false; }
    Write-Debug "---- Publishing Components"
    # For each component in components.yml
    #   apply resources global variables, resources.output variables, global variables, components variables
    #   execute build command in the folder
    #     command is parameter in components.yml
    #   tag and push component to registry

    $componentsFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/components.yml"
    if (-Not (Test-Path -Path $componentsFile)) { Write-Information "File not found: $componentsFile"; return $false; }
    $componentsYaml = ConvertFrom-File $componentsFile
    if ($null -eq $componentsYaml) { Write-Information "Components null or empty in file: $componentsFile"; return $true; }
    if ($null -eq $componentsYaml.components) { Write-Information "Components null or empty in file: $componentsFile"; return $true; }

    # copy componentsFile to work folder under .yuruna
    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/components"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}',(Get-Date)))
    $backupFile = Join-Path -Path $workFolder -ChildPath "components.$dtTime.yml"
    Copy-Item "$componentsFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $componentsFile copied to: $backupFile"
    # TODO: Decide on copying all code also

    $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    $resourcesOutputYaml = $null
    if (Test-Path -Path $resourcesOutputFile) {
        $resourcesOutputYaml = ConvertFrom-File $resourcesOutputFile
    }

    # Debug info
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

    if (-Not ($null -eq $componentsYaml.globalVariables)) {
        foreach ($key in $componentsYaml.globalVariables.Keys) {
            $value = $componentsYaml.globalVariables[$key]
            Write-Debug "globalVariables[$key] = $value"
            Set-Item -Path Env:$key -Value ${value}
        }
    }

    $componentsPath = Join-Path -Path $project_root -ChildPath "components/"
    # For each component in components.yml
    foreach ($component in $componentsYaml.components) {
        # Component project
        $project = $component['project']
        if ([string]::IsNullOrEmpty($project)) { Write-Information "component.project cannot be null or empty in file: $componentsFile"; return $false; }
        $buildPath = $component['buildPath']
        if ([string]::IsNullOrEmpty($buildPath)) { Write-Information "component.buildPath cannot be null or empty in file: $componentsFile"; return $false; }
        $buildFolder = Resolve-Path -Path (Join-Path -Path $project_root -ChildPath "components/$buildPath")
        if (-Not (Test-Path -Path $buildFolder)) { Write-Information "Components folder not found: $buildFolder`nUsed in file: $componentsFile"; return $false; }
        Write-Information "-- Component: $project from $buildFolder"

        # Notice how there is not string expansion for the components script
        $componentVars = [ordered]@{}
        # apply resources global variables, resources.output variables, global variables, components variables
        if ((-Not ($null -eq $resourcesOutputYaml)) -and (-Not ($null -eq  $resourcesOutputYaml.Keys))) {
            foreach ($resource in $resourcesOutputYaml.Keys) {
                if ($resource -eq "globalVariables") {
                    foreach ($key in $resourcesOutputYaml.$resource.Keys) {
                        $resourceKey = "$key"
                        $value = $resourcesOutputYaml.$resource[$key]
                        $componentVars[$resourceKey] = $value
                        Set-Item -Path Env:$resourceKey -Value ${value}
                    }
                }
                else {
                    foreach ($key in $resourcesOutputYaml.$resource.Keys) {
                        $resourceKey = "$resource.$key"
                        $value = $resourcesOutputYaml.$resource[$key].value
                        $componentVars[$resourceKey] = $value
                        Set-Item -Path Env:$resourceKey -Value ${value}
                    }
                }
            }
        }

        if (-Not ($null -eq $componentsYaml.globalVariables)) {
            foreach ($key in $componentsYaml.globalVariables.Keys) {
                $value = $componentsYaml.globalVariables[$key]
                $componentVars[$key] = $value
                Set-Item -Path Env:$key -Value ${value}
            }
        }

        if ((-Not ($null -eq $component.variables)) -and (-Not ($null -eq  $component.variables.Keys))) {
            foreach ($key in $component.variables.Keys) {
                $value = $component.variables[$key]
                $componentVars[$key] = $value
                Write-Debug "componentVariables[$key] = $value"
                Set-Item -Path Env:$key -Value ${value}
            }
        }

        # execute build command in the folder
        # command is parameter in components.yml
        $buildCommand = $component['buildCommand']
        if ([string]::IsNullOrEmpty($buildCommand)) { $buildCommand = $componentsYaml.globalVariables['buildCommand'] }
        if ([string]::IsNullOrEmpty($buildCommand)) { Write-Information "buildCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }

        $dockerfile = Join-Path -Path $buildFolder -ChildPath "Dockerfile"
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { $dockerfile = Join-Path -Path $buildFolder -ChildPath "$project-dockerfile"; }
        if (-Not (Test-Path -Path $dockerfile)) { Write-Information "Missing dockerfile in folder: $buildFolder"; return $false; }

        $componentVars['project'] = $project
        $componentVars['buildPath'] = $buildPath
        $componentVars['dockerfile'] = $dockerfile
        foreach ($key in $componentVars.Keys) {
            $value = $componentVars[$key]
            if ([string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
            Set-Item -Path Env:$key -Value ${value}
            Write-Debug "$project[Env:$key] is $(Get-Content -Path Env:$key)"
        }

        Push-Location $componentsPath
        # preProcessor
        $preProcessor = $componentVars['preProcessor']
        if ([string]::IsNullOrEmpty($preProcessor)) { $preProcessor = $componentsYaml.globalVariables['preProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($preProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($preProcessor)
            Write-Information "preProcessor: $executionCommand"
            Invoke-Expression $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for preProcessor: $executionCommand"
                return ($ErrorActionPreference -eq "Continue");
            }
        }

        # build
        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($buildCommand)
        Write-Debug "Build: $executionCommand"
        Invoke-Expression $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Build: $executionCommand"
            return ($ErrorActionPreference -eq "Continue");
        }

        # postProcessor
        $postProcessor = $componentVars['postProcessor']
        if ([string]::IsNullOrEmpty($postProcessor)) { $postProcessor = $componentsYaml.globalVariables['postProcessor'] }
        if (-Not ([string]::IsNullOrEmpty($postProcessor))) {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($postProcessor)
            Write-Information "postProcessor: $executionCommand"
            Invoke-Expression $executionCommand
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for postProcessor: $executionCommand"
                return ($ErrorActionPreference -eq "Continue");
            }
        }
        Pop-Location

        # tag and push component to registry
        $tagCommand = $component['tagCommand']
        if ([string]::IsNullOrEmpty($tagCommand)) { $tagCommand = $componentsYaml.globalVariables['tagCommand']; }
        if ([string]::IsNullOrEmpty($tagCommand)) { Write-Information "tagCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }
        $pushCommand = $component['pushCommand']
        if ([string]::IsNullOrEmpty($pushCommand)) { $pushCommand = $componentsYaml.globalVariables['pushCommand']; }
        if ([string]::IsNullOrEmpty($pushCommand)) { Write-Information "pushCommand cannot be null or empty in file (both globalVariables and component level): $componentsFile"; return $false; }
        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($tagCommand)
        Write-Debug "Tag: $executionCommand"
        Invoke-Expression $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Tag: $executionCommand"
            return ($ErrorActionPreference -eq "Continue");
        }

        # TODO: generic registry login approach
        $registryLocation = $([Environment]::GetEnvironmentVariable("${env:registryName}.registryLocation"))
        if ($registryLocation -like '*azurecr.io*') {
            $executionCommand = $ExecutionContext.InvokeCommand.ExpandString("az acr login -n $registryLocation *>&1")
            Invoke-Expression $executionCommand *>&1 | Write-Verbose
            if (-Not (0 -eq $LASTEXITCODE)) {
                Write-Information "EXITCODE: $LASTEXITCODE for: $executionCommand"
                return ($ErrorActionPreference -eq "Continue");
            }
        }

        $executionCommand = $ExecutionContext.InvokeCommand.ExpandString($pushCommand)
        Write-Debug "Push: $executionCommand"
        Invoke-Expression $executionCommand
        if (-Not (0 -eq $LASTEXITCODE)) {
            Write-Information "EXITCODE: $LASTEXITCODE for Push: $executionCommand"
            return ($ErrorActionPreference -eq "Continue");
        }
    }

    return $true;
}

Export-ModuleMember -Function * -Alias *
