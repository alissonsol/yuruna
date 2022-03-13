<#PSScriptInfo
.VERSION 0.2
.GUID 06e8bceb-f7aa-47e8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2020-2022 Alisson Sol et al.
.TAGS yuruna-requirements
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

function Confirm-RequirementList {

    $requirementsFile = Join-Path -Path $PSScriptRoot -ChildPath "yuruna-requirements.yml"
    if (-Not (Test-Path -Path $requirementsFile)) { Write-Information "File not found: $requirementsFile"; return $false; }
    $requirementsYaml = ConvertFrom-File $requirementsFile
    if ($null -eq $requirementsYaml) { Write-Information "Requirements null or empty in file: $requirementsFile"; return $true; }
    if ($null -eq $requirementsYaml.requirements) { Write-Information "Components null or empty in file: $requirementsFile"; return $true; }

    if (-Not ($null -eq $requirementsYaml.requirements)) {
        $output = "{0,20}" -f "Tool" + "{0,16}" -f "Required" + "  {0}" -f "Found"
        Write-Host $output
        foreach ($tool in $requirementsYaml.requirements) {
            $toolName = $tool['tool']
            $toolCommand = $tool['command']
            $toolVersion = $tool['version']
            $toolFound = Invoke-Expression $toolCommand *>&1
            $output = "{0,20}" -f $toolName + "{0,16}" -f $toolVersion + "  {0}" -f $toolFound
            Write-Host $output
        }
    }

    return $true
}

Export-ModuleMember -Function * -Alias *
