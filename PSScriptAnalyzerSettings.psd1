<#PSScriptInfo
.VERSION 2026.09.08
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
    # PSScriptAnalyzer settings for the yuruna repo.
    #
    # Auto-discovered by `Invoke-ScriptAnalyzer -Path . -Recurse`
    # (see CONTRIBUTING.md). Findings of every severity are reported:
    # Information-severity results (missing comment help, undeclared
    # output types, positional-parameter calls) are NOT filtered out, so
    # they surface alongside Errors and Warnings.

    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
