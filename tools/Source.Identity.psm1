<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42eaea2f-4195-47c6-a397-402234a8930f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna source metadata identity guid header
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

# What a source file declares about itself: the copyright and license pointer
# of its header, and the 42-prefixed GUID that keeps its history joined through
# a rename. The metadata gate decides from these facts, and the suites that
# compare aligned copies or census the PowerShell identities read the same
# facts here, so a file cannot declare one identity to the gate and another to
# a test. CONTRIBUTING.md, "Source metadata", states the rules.

$script:CopyrightPattern = '\(c\)\s*\d{4}(?:\s*-\s*\d{4})?\s+by\s+Alisson Sol et al\.'
$script:PointerPattern   = 'LICENSEURI\s+https://yuruna\.link/license(?![\w./-])'
$script:GuidPattern      = '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'
# A GUID line is optional comment markers, "GUID:", the value and an optional
# closing marker. Inside a block comment that already holds the copyright line
# it has no markers of its own, so nesting never closes the block early.
$script:GuidLinePattern  = '^\s*(?:@?REM\s+)?[^\sA-Za-z0-9]*\s*GUID:\s*(?<value>[^\s*]+?)\s*(?:\*/|-->|\*@)?\s*$'
$script:SequenceGuidPattern = '^sequenceGuid:\s*[''"]?(?<value>[^''"\s#]+)'
$script:PsInfoGuidPattern = '^\s*\.GUID\s+(?<value>\S+)'
# The sequence loader treats a document with a top-level resource: map as a
# guest sequence, and keystrokeMechanism: belongs to the guest schema alone;
# either key at the top level of a YAML file marks the one sequence kind
# sequenceGuid names. Other hash-comment formats are never asked: a Python
# annotation can open a line with "resource:" too.
$script:GuestSequencePattern = '^(?:resource|keystrokeMechanism):(?:\s|$)'

function Get-SourceHeaderPattern {
    <#
    .SYNOPSIS
        The regular expressions for a copyright line, a license pointer and a
        GUID value, for a caller that checks those lines itself.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{ Copyright = $script:CopyrightPattern; Pointer = $script:PointerPattern; Guid = $script:GuidPattern }
}

function New-SourceGuid {
    <#
    .SYNOPSIS
        A fresh GUID in the 42-prefixed namespace durable definitions use.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Returns a value; changes nothing.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $n = [guid]::NewGuid().ToString('N')
    return '42' + $n.Substring(2, 6) + '-' + $n.Substring(8, 4) + '-' + $n.Substring(12, 4) + '-' + $n.Substring(16, 4) + '-' + $n.Substring(20, 12)
}

function Get-SourceHeaderFact {
    <#
    .SYNOPSIS
        The header and identity a file's first lines declare.
    .DESCRIPTION
        Guid is the identity the file declares: the .GUID of a PowerShell
        PSScriptInfo block, and outside PowerShell the sequenceGuid of a
        sequence or the GUID line directly below the copyright line of anything
        else. LineGuid and SequenceGuid keep the two forms apart, StrayGuidLine
        is a GUID line found anywhere else in the lines (1-based), and
        GuestSequence marks a YAML guest sequence, which sequenceGuid names.
    .PARAMETER Style
        The comment style of the file: psinfo for PowerShell, otherwise the
        style name the metadata gate maps the extension to.
    .PARAMETER Line
        The file's first lines.
    .PARAMETER RelativePath
        The file's path, which tells a YAML file apart.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Style, [Parameter(Mandatory)][AllowEmptyString()][string[]]$Line, [string]$RelativePath)
    $yaml = $RelativePath -match '\.ya?ml$'
    $fact = [pscustomobject]@{ Block = $false; Copyright = $false; Pointer = $false; Guid = $null
        CopyrightLine = $null; LineGuid = $null; SequenceGuid = $null; StrayGuidLine = 0; GuestSequence = $false }
    if ($Style -eq 'psinfo') {
        $inside = $false
        foreach ($text in $Line) {
            if (-not $inside) {
                if ($text -match '^\s*<#PSScriptInfo\b') { $inside = $true; $fact.Block = $true }
                continue
            }
            if ($text -match '#>') { break }
            if ($text -match "^\s*\.COPYRIGHT\s+$script:CopyrightPattern") { $fact.Copyright = $true }
            elseif ($text -match '^\s*\.LICENSEURI\s+https://yuruna\.link/license(?![\w./-])') { $fact.Pointer = $true }
            elseif ($text -match $script:PsInfoGuidPattern) { $fact.Guid = $Matches['value'] }
        }
        return $fact
    }
    $guidAt = -1
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Line[$i] -notmatch "Copyright\s*$script:CopyrightPattern") { continue }
        $fact.Copyright = $true
        $fact.CopyrightLine = $Line[$i]
        for ($j = $i - 1; $j -ge 0; $j--) {
            if ($Line[$j] -match '[A-Za-z0-9]') { $fact.Pointer = $Line[$j] -match $script:PointerPattern; break }
        }
        for ($j = $i + 1; $j -lt $Line.Count; $j++) {
            if ($Line[$j] -notmatch '[A-Za-z0-9]') { continue }
            if ($Line[$j] -match $script:GuidLinePattern) { $fact.LineGuid = $Matches['value']; $guidAt = $j }
            break
        }
        break
    }
    for ($i = 0; $i -lt $Line.Count; $i++) {
        if ($Style -eq 'hash' -and -not $fact.SequenceGuid -and $Line[$i] -match $script:SequenceGuidPattern) { $fact.SequenceGuid = $Matches['value'] }
        elseif ($i -ne $guidAt -and -not $fact.StrayGuidLine -and $Line[$i] -match $script:GuidLinePattern) { $fact.StrayGuidLine = $i + 1 }
        if ($yaml -and $Line[$i] -match $script:GuestSequencePattern) { $fact.GuestSequence = $true }
    }
    $fact.Guid = if ($fact.SequenceGuid) { $fact.SequenceGuid } else { $fact.LineGuid }
    return $fact
}

function Get-SourceIdentityLineValue {
    <#
    .SYNOPSIS
        The GUID one line declares in any identity form, or $null.
    .DESCRIPTION
        A PSScriptInfo .GUID line, a sequenceGuid key or a GUID comment line.
        One line says only what it looks like; whether the file declares it is
        Get-SourceHeaderFact's answer, because a file can quote another
        file's header.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -match '^\s*\.GUID\s+(?<value>[0-9a-fA-F-]{36})\s*$' -or $Text -match $script:SequenceGuidPattern -or
        $Text -match $script:GuidLinePattern) {
        return $Matches['value']
    }
    return $null
}

function Hide-SourceIdentity {
    <#
    .SYNOPSIS
        The text with the value of every identity line replaced by a
        placeholder.
    .DESCRIPTION
        Files that only stay aligned, such as the Ubuntu 24 and 26 variants of
        one script, keep their own GUIDs; a check that compares them compares
        everything else. The line stays, with its markers, so a copy that lost
        its identity line still differs.
    .PARAMETER Text
        The file text.
    .PARAMETER Placeholder
        What each value becomes.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Placeholder',
        Justification = 'Read by the match evaluators below, which the analyzer does not follow into.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [string]$Placeholder = 'ID')
    $replace = {
        param($match)
        $value = $match.Groups['value']
        return $match.Value.Substring(0, $value.Index - $match.Index) + $Placeholder + $match.Value.Substring($value.Index - $match.Index + $value.Length)
    }
    $Text = [regex]::Replace($Text, '(?m)^[ \t]*\.GUID[ \t]+(?<value>[^\s]+)', $replace)
    $Text = [regex]::Replace($Text, '(?m)^sequenceGuid:[ \t]*(?<value>[^\s#]+)', $replace)
    # Line by line, because the GUID line pattern anchors at both ends; a line
    # keeps its carriage return, which the pattern's trailing \s* absorbs.
    $Text = [regex]::Replace($Text, '(?m)^[^\n]*', {
            param($line)
            $found = [regex]::Match($line.Value, $script:GuidLinePattern)
            if (-not $found.Success) { return $line.Value }
            $value = $found.Groups['value']
            return $line.Value.Substring(0, $value.Index) + $Placeholder + $line.Value.Substring($value.Index + $value.Length)
        })
    return $Text
}

Export-ModuleMember -Function Get-SourceHeaderPattern, New-SourceGuid, Get-SourceHeaderFact, Get-SourceIdentityLineValue, Hide-SourceIdentity
