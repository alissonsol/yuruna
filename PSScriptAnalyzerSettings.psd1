<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a9b8c7-d6e5-4f43-2109-87a6b5c4d3e2
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
    # PSScriptAnalyzer settings for the yuruna repo.
    #
    # Auto-discovered by `Invoke-ScriptAnalyzer -Path . -Recurse`
    # (see CONTRIBUTING.md). All Error- and Warning-severity findings
    # are gates and must be zero before merge.

    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
