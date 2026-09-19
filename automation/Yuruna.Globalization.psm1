<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42406825-22d1-45b2-a7ec-f513c4302535
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization operator catalogs
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Render whole operator messages with the command's resolved locale.
.DESCRIPTION
    Importing the adapter reads no locale or catalog data. The first emission
    resolves the configured language lock and process UI culture, then delegates
    to the shared compiled renderer, whose domain tables are cached per runspace.
    Machine output and bootstrap scripts do not import this adapter.
#>
$script:OperatorContext = $null
$script:OperatorRoot = Split-Path -Parent $PSScriptRoot

function Format-YurunaOperatorMessage {
    <#
    .SYNOPSIS
        Render a stable message key with explicitly named argument values.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Key, [hashtable]$Arguments = @{},
        [AllowNull()][AllowEmptyCollection()][object[]]$FormatValues,
        [hashtable]$FormatBindings = @{})
    # Existing composite formats can align or format the same value in more
    # than one way. Evaluate the source values once, then give the translator
    # named display arguments while preserving each original value format.
    $context = Get-YurunaOperatorLocale
    $formatLocale = if ($context.ResolvedTag -like 'qps-*') { 'en-US' } else { $context.ResolvedTag }
    $culture = [Globalization.CultureInfo]::GetCultureInfo($formatLocale)
    foreach ($name in $FormatBindings.Keys) {
        $Arguments[$name] = [string]::Format($culture, ('{' + [string]$FormatBindings[$name] + '}'), [object[]]$FormatValues)
    }
    return Format-CatalogMessage -Key $Key -Arguments $Arguments -Locale $context.ResolvedTag
}

function Get-YurunaOperatorLocale {
    <#
    .SYNOPSIS
        Resolve the shared immutable locale context on first operator emission.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:OperatorContext) {
        Import-Module (Join-Path $script:OperatorRoot 'test/modules/Test.Catalog.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:OperatorRoot 'test/modules/Test.Locale.psm1') -DisableNameChecking
        $language = 'auto'
        $configuration = Join-Path $script:OperatorRoot 'test/test.config.yml'
        if ([IO.File]::Exists($configuration)) {
            $match = [regex]::Match([IO.File]::ReadAllText($configuration), '(?m)^language:\s*["'']?([A-Za-z0-9-]+)["'']?\s*(?:#.*)?$')
            if ($match.Success) { $language = $match.Groups[1].Value }
        }
        $script:OperatorContext = New-LocaleContext -ConfigLanguage $language -ProcessCulture ([Globalization.CultureInfo]::CurrentUICulture.Name)
    }
    return $script:OperatorContext
}

function Resolve-YurunaOperatorProjectLabel {
    <#
    .SYNOPSIS
        Resolve optional project display metadata without changing its stable name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Entry, [ValidateSet('description', 'displayName')][string]$ScalarKey = 'description')
    $context = Get-YurunaOperatorLocale
    Import-Module (Join-Path $script:OperatorRoot 'test/modules/Test.SequencePlanner.psm1') -DisableNameChecking
    return Resolve-ProjectLabel -Entry $Entry -ScalarKey $ScalarKey -Locale $context.ResolvedTag
}

Export-ModuleMember -Function Format-YurunaOperatorMessage, Get-YurunaOperatorLocale, Resolve-YurunaOperatorProjectLabel
