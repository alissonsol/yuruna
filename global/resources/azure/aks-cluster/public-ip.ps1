<#PSScriptInfo
.VERSION 0.1
.GUID 42ff6071-8293-4401-8234-506789012b3c
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

az network public-ip list -g $args[0] --query "{ip_address : [0].ipAddress}" --output json