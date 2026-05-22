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
