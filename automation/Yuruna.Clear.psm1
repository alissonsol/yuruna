<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c1e3f4-a5b6-4789-0123-4c5d6e7f8091
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Clear
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
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Validation.psm1"
Import-Module -Name $validationModulePath

function Clear-Configuration {
    param (
        $project_root,
        $config_subfolder
    )

    # Teardown consumes resources.output.yml (the deployed-state manifest, gated
    # by Test-Path below) and destroys from the deployed .yuruna work folders --
    # NOT the forward resources.yml + its referenced template folders. Blocking
    # destroy on forward validation means any source-config drift after deploy (a
    # template folder renamed/deleted, a variable now expanding empty) leaves the
    # operator unable to destroy what was actually created, defeating idempotent
    # cleanup. Downgrade the forward check to a warning so teardown is never
    # blocked by it; the resources.output.yml gate below is the real precondition.
    if (!(Confirm-ResourceList $project_root $config_subfolder)) {
        Write-Warning "Clear-Configuration: forward resources.yml validation failed; proceeding with teardown from resources.output.yml anyway (source config may have drifted since deploy)."
    }
    Write-Debug "---- Destroying Resources"

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return $false; }
    $yaml = ConvertFrom-File $resourcesFile

    # Global variables saved expanded for reuse. Same expand -> Set-Item Env ->
    # cache-back walk as the resource/component/workload publishers; call the one
    # shared implementation (resolvable here because Yuruna.Validation, imported
    # above, imports Yuruna.VariableExpansion -Global) so the teardown env matches
    # what deploy set.
    Set-ExpandedVariableHashtable -Variables $yaml.globalVariables -DebugLabel 'globalVariables' -CacheExpanded

    if ($null -eq $yaml.resources) { Write-Information "Resources null or empty in file: $resourcesFile"; return $true; }
    $destroyFailed = $false
    foreach ($resource in $yaml.resources) {
        $resourceName = $ExecutionContext.InvokeCommand.ExpandString($resource['name'])
        $resourceTemplate = $resource['template']
        Write-Debug "resource: $resourceName - template: $resourceTemplate"
        if ([string]::IsNullOrEmpty($resourceName)) { Write-Information "Resource without name in file: $resourcesFile"; return $false; }
        # Empty template: just naming an already-existing resource, nothing to destroy
        if (![string]::IsNullOrEmpty($resourceTemplate)) {
            $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources/$resourceName"
            if (-Not ([string]::IsNullOrEmpty($workFolder))) {
                $workFolder = Resolve-Path -Path $workFolder -ErrorAction SilentlyContinue
                if (-Not ([string]::IsNullOrEmpty($workFolder))) {
                    Push-Location $workFolder
                    Write-Information "-- Clear: $workFolder"
                    $result = tofu destroy -auto-approve -refresh=false 2>&1
                    $destroyExit = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
                    Write-Debug "OpenTofu destroy (exit $destroyExit): $result"
                    Pop-Location
                    if ($destroyExit -ne 0) {
                        # Keep the work folder (and its tfstate) when destroy fails: it is the
                        # only local state that lets the destroy be retried. Deleting it here
                        # would orphan the real cloud/VM resource with no way to recover.
                        Write-Information "OpenTofu destroy failed (exit ${destroyExit}) for ${resourceName}; preserving $workFolder for retry"
                        $destroyFailed = $true
                    }
                    else {
                        Remove-Item -Path $workFolder -Force -Recurse -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }

    return (-Not $destroyFailed);
}

Export-ModuleMember -Function * -Alias *
