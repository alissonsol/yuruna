<#PSScriptInfo
.VERSION 2026.11.05
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
    # Naming a custom rule drops the default rules unless IncludeDefaultRules
    # stays set. The analyzer resolves CustomRulePath against the current
    # location, not this file, so the settings are used from the repository
    # root; tools/Analyzer.SilentCatch.psm1 says what its rule flags.

    IncludeDefaultRules = $true
    CustomRulePath = @('tools/Analyzer.SilentCatch.psm1')

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}
