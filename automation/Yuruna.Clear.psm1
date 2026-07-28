<#PSScriptInfo
.VERSION 2026.07.28
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

    # The deployed resource names are the top-level keys of resources.output.yml
    # other than globalVariables: Set-Resource writes that map plus one
    # `<resourceName>: <tofu outputs>` block per resource it actually created.
    # There is no `resources:` list in this file -- that shape belongs to the
    # forward resources.yml, and reading it here would silently find nothing and
    # report a successful teardown that destroyed no resource.
    #
    # Two properties of that key set matter. A resource declared with an empty
    # template is never written here at all -- it only names an already-existing
    # resource and owns no work folder -- so the keys are exactly the set that
    # has something to destroy. And the keys are already variable-expanded, so
    # they match the .yuruna work folder names verbatim and must not be expanded
    # a second time.
    $resourceNames = @()
    if (($null -ne $yaml) -and ($null -ne $yaml.Keys)) {
        $resourceNames = @($yaml.Keys | Where-Object { (-Not [string]::IsNullOrWhiteSpace($_)) -and ($_ -ne 'globalVariables') })
    }
    if ($resourceNames.Count -eq 0) { Write-Information "No deployed resources in file: $resourcesFile"; return $true; }
    $destroyFailed = $false
    foreach ($resourceName in $resourceNames) {
        Write-Debug "resource: $resourceName"
        $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources/$resourceName"
        $workFolder = Resolve-Path -Path $workFolder -ErrorAction SilentlyContinue
        # No work folder: already destroyed and removed by an earlier run, so
        # there is no local tfstate left to destroy from.
        if ([string]::IsNullOrEmpty($workFolder)) {
            Write-Debug "No work folder for ${resourceName}; nothing to destroy"
            continue
        }
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

    return (-Not $destroyFailed);
}

Export-ModuleMember -Function * -Alias *
