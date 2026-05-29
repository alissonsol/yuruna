<#PSScriptInfo
.VERSION 2026.05.29
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
    #
    # PSUseBOMForUnicodeEncodedFile is called out explicitly because PS7
    # Set-Content / Out-File default to BOM-less UTF-8 (see
    # ~/.claude/.../feedback_setcontent_strips_utf8_bom.md). Rewrite with
    # `[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($true))`.

    Severity            = @('Error', 'Warning')
    IncludeDefaultRules = $true

    Rules = @{
        PSUseBOMForUnicodeEncodedFile = @{ Enable = $true }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
