<#PSScriptInfo
.VERSION 0.1
.GUID 42039415-c637-4845-b678-9012f7081920
.AUTHOR Alisson Sol
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

#requires -version 7

docker run -d -p 5000:5000 --restart always --name registry registry:latest