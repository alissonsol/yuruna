<#PSScriptInfo
.VERSION 0.1
.GUID 42bb2c3d-4e5f-4067-b890-1c2d3e4f5067
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

Push-Location $PSScriptRoot

$env:basePath = $HOME
echo "basePath: ${env:basePath}";

$env:pfxPath = ".aspnet/https/aspnetapp.pfx"
echo "pfxPath: ${env:pfxPath}";

$env:pfxFile = Join-Path -Path ${env:basePath} -ChildPath ${env:pfxPath}
echo "pfxFile: $env:pfxFile"

Copy-Item -Path $env:pfxFile -Destination . -Force;

Pop-Location
