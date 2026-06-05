<#PSScriptInfo
.VERSION 2026.06.05
.GUID 42e8bceb-f7aa-4ae8-a633-1fc36173d278
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

function ConvertFrom-Content {
    param (
        $Content
    )

    if (-Not (Get-Module -ListAvailable -Name powershell-yaml)) { Write-Information "Need to install powershell-yaml using:`nInstall-Module -Name powershell-yaml" -InformationAction Stop; Exit -1 }

    if ($Content -is [string[]]) { $Content = $Content -join "`n" }
    return ConvertFrom-YAML -Ordered $Content
}

function ConvertFrom-File {
    param (
        $FileName
    )

    return ConvertFrom-Content (Get-Content -Raw $FileName)
}

function Find-KeyValue {
    param (
        [Parameter(Mandatory=$true, Position=0)]
        $Items,
        [Parameter(Mandatory=$true, Position=1)]
        $KeyName
    )

    $keyValue = ''
    foreach ($item in $Items) {
        $key = $item.key
        Write-Debug "$key"
        if ($key -eq $KeyName) {
            $keyValue = $item.value
            break
        }
    }

    return $keyValue
}

Export-ModuleMember -Function * -Alias *
