<#PSScriptInfo
.VERSION 0.1
.GUID 42e8bceb-f7aa-4ae8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS import-yaml
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
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

    $lines = ''
    foreach ($line in $Content) { $lines = $lines + "`n" + $line }
    return ConvertFrom-YAML -Ordered $lines
}

function ConvertFrom-File {
    param (
        $FileName
    )

    [string[]]$fileContent = Get-Content $FileName
    return ConvertFrom-Content $fileContent
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
