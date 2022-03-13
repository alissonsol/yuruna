<#PSScriptInfo
.VERSION 0.2
.GUID 06e8bceb-f7aa-47e8-a633-1fc36173d278
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2020-2022 Alisson Sol et al.
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

function ConvertFrom-Content {
    param (
        $Content
    )

    if (-Not (Get-Module -ListAvailable -Name powershell-yaml)) { Write-Information "Need to install powershell-yaml using:`nInstall-Module -Name powershell-yaml" -InformationAction Stop; Exit -1 }

    $lines = ''
    # Convert a string array to a string
    foreach ($line in $Content) { $lines = $lines + "`n" + $line }
    # Deserialize a string to the PowerShell object
    $yaml = ConvertFrom-YAML -Ordered $lines

    # Return the object
    return $yaml
}

function ConvertFrom-File {
    param (
        $FileName
    )

	# Load file content to a string array containing all YML file lines
    [string[]]$fileContent = Get-Content $FileName
    $yaml = ConvertFrom-Content $fileContent

    # Return the object
    return $yaml
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
