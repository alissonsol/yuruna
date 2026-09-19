<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42c7e970-22e8-4cf0-a45b-a1a1ad090cb7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test catalog source assertions
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -DisableNameChecking

function Get-CatalogSourceMessage {
    <#
    .SYNOPSIS
        Read the compiled English messages that an inspected source body emits.
    .DESCRIPTION
        Source contract tests inspect the real call sites through their AST.
        Resolving only constant keys found in that body keeps an unrelated
        catalog entry from satisfying a warning assertion. Missing keys fail
        instead of making a source assertion silently inspect less text.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Source)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw "Cannot inspect catalog source: $($errors[0].Message)" }
    $calls = @($ast.FindAll({ param($node)
                $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Format-YurunaOperatorMessage', 'Format-CatalogMessage', 'New-SequencePlannerException')
            }, $true))
    foreach ($call in $calls) {
        $elements = $call.CommandElements
        for ($index = 1; $index -lt $elements.Count - 1; $index++) {
            if ($elements[$index] -isnot [Management.Automation.Language.CommandParameterAst] -or $elements[$index].ParameterName -ne 'Key') { continue }
            if ($elements[$index + 1] -isnot [Management.Automation.Language.StringConstantExpressionAst]) { throw 'Source message assertions require a literal catalog key.' }
            $key = $elements[$index + 1].Value
            $domain = $key.Split('.')[0]
            $table = Get-CatalogDomain -Locale en-US -Domain $domain
            if (-not $table.ContainsKey($key)) { throw "Missing compiled source message: $key" }
            Format-CatalogMessage -Key $key -Locale en-US
            break
        }
    }
}
Export-ModuleMember -Function Get-CatalogSourceMessage
