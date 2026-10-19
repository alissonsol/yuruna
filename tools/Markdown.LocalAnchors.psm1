<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 4276ae79-65a6-4bc5-a01e-a181498da537
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna documentation anchors markdown
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

# The pointer gate and the link-catalog publisher both decide whether a
# nonlocalized document carries a published anchor. They read the document
# with this one rule, so an id inside a fenced example cannot count for one
# tool and not for the other. -- Markdown.LocalAnchors.psm1

function Get-LocalSbomAnchorId {
    <#
    .SYNOPSIS
        Read stable anchors from a nonlocalized document, excluding fenced examples.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$LiteralPath)

    $ids = [Collections.Generic.List[string]]::new()
    $fenceCharacter = ''
    $fenceLength = 0
    foreach ($line in [IO.File]::ReadAllLines($LiteralPath)) {
        if ($fenceCharacter) {
            $closing = '^ {0,3}' + [regex]::Escape($fenceCharacter) + '{' + $fenceLength + ',}[ \t]*$'
            if ($line -match $closing) { $fenceCharacter = '' }
            continue
        }
        $fence = [regex]::Match($line, '^ {0,3}(`{3,}|~{3,})(.*)$')
        if ($fence.Success -and -not ($fence.Groups[1].Value[0] -eq '`' -and
                $fence.Groups[2].Value.Contains('`'))) {
            $fenceCharacter = [string]$fence.Groups[1].Value[0]
            $fenceLength = $fence.Groups[1].Length
            continue
        }
        $anchor = [regex]::Match($line, '^[ \t]*<a id="(42[0-9a-f]{6}-[0-9a-f]{4})"></a>[ \t]*$')
        if ($anchor.Success) { $ids.Add($anchor.Groups[1].Value) }
    }
    return [string[]]$ids.ToArray()
}

Export-ModuleMember -Function Get-LocalSbomAnchorId
