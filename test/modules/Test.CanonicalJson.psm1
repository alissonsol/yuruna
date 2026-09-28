<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42e7a3c9-5b18-4d62-9a07-3f5c81b40de6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization canonical json digest
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    One deterministic JSON text for a value, for digests that are compared
    byte for byte.
.DESCRIPTION
    The localization exchange hashes a request's rows and the source files it
    stages, and compares those digests across hosts and across runs. A digest
    over ConvertTo-Json output would change whenever the members of an object
    arrived in a different order, so the value is canonicalized first: object
    keys in ordinal order, arrays in their authored order, numbers in the
    invariant culture, and no insignificant whitespace.
.NOTES
    Ordinal sorting, not culture-aware: this value is compared byte for byte
    across hosts, and a Turkish or Swedish collation would reorder the keys and
    change the digest without changing a word of the content.
#>

Set-StrictMode -Version 3.0

function Get-OrdinalSortedName {
    <#
    .SYNOPSIS
        Member names in ordinal order, whatever culture the host is running in.
    .DESCRIPTION
        Sort-Object is culture-aware even with -CaseSensitive: on a Turkish host
        the dotted and dotless i are separate letters and 'Irish' sorts before
        'india', where the invariant order is the reverse. That would give the
        same content two different digests on two hosts, which is the one thing
        a value compared byte for byte across machines cannot do.
    .OUTPUTS
        [string[]]
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Name)

    $sorted = [string[]]::new($Name.Length)
    [Array]::Copy($Name, $sorted, $Name.Length)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    # Emitted rather than returned as one object: every caller enumerates this,
    # and the pipeline handles an empty or single-name set without a wrapper.
    return $sorted
}

function ConvertTo-CanonicalApprovalJson {
    <#
    .SYNOPSIS
        One deterministic text for a value, whatever order its members arrived in.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Value)

    $parts = @()
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-Json -InputObject $Value -Compress }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in (Get-OrdinalSortedName -Name @($Value.Keys))) {
            $parts += (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' +
                (ConvertTo-CanonicalApprovalJson -Value $Value[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($name in (Get-OrdinalSortedName -Name @($Value.PSObject.Properties.Name))) {
            $parts += (ConvertTo-Json -InputObject ([string]$name) -Compress) + ':' +
                (ConvertTo-CanonicalApprovalJson -Value $Value.$name)
        }
        return '{' + ($parts -join ',') + '}'
    }
    # Authored order is content for an array: two lists holding the same items
    # in a different order are different values, so the digest has to differ.
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalApprovalJson -Value $item }
        return '[' + ($parts -join ',') + ']'
    }
    return ConvertTo-Json -InputObject ([string]$Value) -Compress
}

Export-ModuleMember -Function ConvertTo-CanonicalApprovalJson, Get-OrdinalSortedName
