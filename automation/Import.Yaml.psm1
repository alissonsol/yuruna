<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 42a7694d-69b5-445b-b086-f13404589e45
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Import.Yaml
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

# Set once powershell-yaml has been found, so the module path is searched once
# per loaded copy of this module instead of once per converted file. Only the
# positive answer is kept: a missing module is looked for again on every call,
# so installing it and retrying in the same session works.
$script:PowerShellYamlAvailable = $false

function ConvertFrom-Content {
    param (
        $Content
    )

    if (-not $script:PowerShellYamlAvailable) {
        # Throw a terminating error the caller can catch, rather than killing the whole host process
        # with Exit -1 (which tears down the runner / any embedding script with no chance to recover).
        if (-Not (Get-Module -ListAvailable -Name powershell-yaml)) {
            throw (Format-YurunaOperatorMessage -Key 'automation.operator_4eeea39bff48dea5')
        }
        $script:PowerShellYamlAvailable = $true
    }

    if ($Content -is [string[]]) { $Content = $Content -join "`n" }
    return ConvertFrom-YAML -Ordered $Content
}

function ConvertFrom-File {
    param (
        $FileName
    )

    return ConvertFrom-Content (Get-Content -Raw $FileName)
}

Export-ModuleMember -Function * -Alias *
