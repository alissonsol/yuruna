<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42ff6071-8293-4401-8234-506789012b3c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

az network public-ip list -g $args[0] --query "{ip_address : [0].ipAddress}" --output json