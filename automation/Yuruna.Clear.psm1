<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42d48379-bb62-43d9-b80a-bcbb0440f82e
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

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
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

    # See https://yuruna.link/4213a0b3-0007
    if (!(Confirm-ResourceList $project_root $config_subfolder)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'automation.operator_f30d376c3b6737d6')
    }
    Write-Debug "---- Destroying Resources"

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_b400ae75394f002b' -Arguments @{ resourcesFile = "$resourcesFile" }); return $false; }
    $yaml = ConvertFrom-File $resourcesFile

    # The output manifest stores resolved globals. Re-expanding their dollar
    # signs would change credentials or execute text supplied as a value.
    Set-ExpandedVariableHashtable -Variables $yaml.globalVariables -DebugLabel 'globalVariables' -NoExpand

    # See https://yuruna.link/4213a0b3-0008
    $resourceNames = @()
    if (($null -ne $yaml) -and ($null -ne $yaml.Keys)) {
        $resourceNames = @($yaml.Keys | Where-Object { (-Not [string]::IsNullOrWhiteSpace($_)) -and ($_ -ne 'globalVariables') })
    }
    if ($resourceNames.Count -eq 0) { Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_e39c3c3dc7a39a89' -Arguments @{ resourcesFile = "$resourcesFile" }); return $true; }
    $tofuCommand = Get-Command -Name tofu -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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
        if ($null -eq $tofuCommand) {
            Write-Warning "OpenTofu executable not found; retaining resource state at $workFolder."
            $destroyFailed = $true
            continue
        }
        Push-Location $workFolder -ErrorAction Stop
        try {
            Write-Information "-- Clear: $workFolder"
            # Resolution or process startup failure cannot borrow another
            # command's successful exit code and authorize deleting local state.
            $global:LASTEXITCODE = $null
            try {
                $result = & $tofuCommand.Source destroy -auto-approve -refresh=false 2>&1
                $destroyExit = if ($null -eq $global:LASTEXITCODE) { 127 } else { $global:LASTEXITCODE }
            }
            catch {
                $result = $_
                $destroyExit = 127
            }
            Write-Debug "OpenTofu destroy (exit $destroyExit): $result"
        }
        finally {
            Pop-Location
        }
        if ($destroyExit -ne 0) {
            # Keep the work folder (and its tfstate) when destroy fails: it is the
            # only local state that lets the destroy be retried. Deleting it here
            # would orphan the real cloud/VM resource with no way to recover.
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.operator_90f26461d4a00353' -Arguments @{ destroyExit = "${destroyExit}"; resourceName = "${resourceName}"; workFolder = "$workFolder" })
            $destroyFailed = $true
        }
        else {
            Remove-Item -Path $workFolder -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    return (-Not $destroyFailed);
}

Export-ModuleMember -Function * -Alias *
