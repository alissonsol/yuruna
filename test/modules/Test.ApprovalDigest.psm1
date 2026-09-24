<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42e7a3c9-5b18-4d62-9a07-3f5c81b40de6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization terminology approval digest canonical
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
    The digest of what an approver actually approved, for the pt-BR terminology
    and style-guide artifacts.
.DESCRIPTION
    An approval used to publish one fact: the release it was given for. That
    attests nothing about the content. Every term decision and every style rule
    could be rewritten afterwards -- reversed, or appended to with a rule nobody
    read -- and the record would still say approved, because nothing in it
    described the words.

    This is the missing half. The digest covers the APPROVABLE projection of an
    artifact and nothing else:

      - the terminology file's term decisions and retired-name rulings;
      - the style guide's rules, plus the pin naming the terminology bytes it
        was written against, so re-pinning the guide over different terminology
        invalidates it too;
      - and never the artifact's own `status` or `approvals`, because a digest
        that covered the approval it is stored in could not be computed before
        being written.

    The projection is canonicalized before hashing: object keys in ordinal
    order, arrays in their authored order, no insignificant whitespace. That is
    what lets a VERSION-only bump keep an approval valid -- the release stamp is
    not in the projection -- while any edit to a decision or a rule invalidates
    it.
.NOTES
    Ordinal sorting, not culture-aware: this value is compared byte for byte
    across hosts, and a Turkish or Swedish collation would reorder the keys and
    change the digest without changing a word of the content.
#>

Set-StrictMode -Version 3.0

$script:DigestAlgorithm = 'sha256-canonical-approvable-v1'

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
    # Authored order is content for an array: the rules read in the order they
    # are written, so reordering them is an edit and has to change the digest.
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-CanonicalApprovalJson -Value $item }
        return '[' + ($parts -join ',') + ']'
    }
    return ConvertTo-Json -InputObject ([string]$Value) -Compress
}

function Get-ApprovableProjection {
    <#
    .SYNOPSIS
        The parts of an artifact an approver is attesting to.
    .OUTPUTS
        [ordered]
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][ValidateSet('terminology', 'style-guide')][string]$Kind
    )

    $names = @($Artifact.PSObject.Properties.Name)
    $projection = [ordered]@{}
    if ($Kind -ceq 'terminology') {
        foreach ($field in @('locale', 'terms', 'retiredNameRulings')) {
            if ($names -contains $field) { $projection[$field] = $Artifact.$field }
        }
        # The definitions pin: the terminology is derived from that document, so
        # the bytes it was derived from are part of what was approved.
        if ($names -contains 'sources' -and $Artifact.sources.PSObject.Properties.Name -contains 'definitions') {
            $projection['definitionsSha256'] = [string]$Artifact.sources.definitions.sha256
        }
    } else {
        foreach ($field in @('locale', 'rules')) {
            if ($names -contains $field) { $projection[$field] = $Artifact.$field }
        }
        if ($names -contains 'terminologySource') {
            $projection['terminologySha256'] = [string]$Artifact.terminologySource.sha256
        }
    }
    return $projection
}

function Get-ApprovableContentDigest {
    <#
    .SYNOPSIS
        The algorithm tag and hex digest for an artifact's approvable content.
    .OUTPUTS
        [ordered] algorithm, sha256
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Artifact,
        [Parameter(Mandatory)][ValidateSet('terminology', 'style-guide')][string]$Kind
    )

    $canonical = ConvertTo-CanonicalApprovalJson -Value (Get-ApprovableProjection -Artifact $Artifact -Kind $Kind)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($canonical))
    } finally {
        $sha.Dispose()
    }
    return [ordered]@{
        algorithm = $script:DigestAlgorithm
        sha256 = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    }
}

function Get-ApprovalDigestAlgorithm {
    <#
    .SYNOPSIS
        The algorithm tag this module writes and verifies.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:DigestAlgorithm
}

Export-ModuleMember -Function ConvertTo-CanonicalApprovalJson, Get-ApprovableProjection, Get-OrdinalSortedName,
    Get-ApprovableContentDigest, Get-ApprovalDigestAlgorithm
