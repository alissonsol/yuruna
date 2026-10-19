<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42119fc0-fb66-4f97-be1e-9ecb9b66d1f5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pssa-settings
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

@{
    # See https://yuruna.link/42e220c4-000a
    # Report every severity and keep PowerShell source ASCII without a BOM.

    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
