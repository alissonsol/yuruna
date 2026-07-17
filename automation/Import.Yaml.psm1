<#PSScriptInfo
.VERSION 2026.07.17
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

    # Throw a terminating error the caller can catch, rather than killing the whole host process
    # with Exit -1 (which tears down the runner / any embedding script with no chance to recover).
    if (-Not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is required. Install it with: Install-Module -Name powershell-yaml"
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

function Find-KeyValue {
    <#
    .SYNOPSIS
    Return the value for $KeyName from a list of {key,value} items, or $null when
    the key is absent -- so a legitimately empty ('') value stays distinguishable
    from "not found".
    #>
    param (
        [Parameter(Mandatory=$true, Position=0)]
        $Items,
        [Parameter(Mandatory=$true, Position=1)]
        $KeyName
    )

    $keyValue = $null
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
