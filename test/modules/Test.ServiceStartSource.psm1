<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4227c856-a95f-4a92-aad7-e9c25f3fbe58
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension service start source fixture
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

# Start-StashServiceVM.ps1, Start-PoolControlServiceVM.ps1 and
# Start-DownloadAgentServiceVM.ps1 name their service and run the shared
# test/service/Start-ExtensionService.ps1, which runs the service's readiness
# part, Start-ExtensionService.<key>.ps1, in place. A suite that reads what one
# of those starts runs (to order its calls, find a banner or scan for an exit)
# reads it through these functions: the shared script with that service's part
# where the script loads it.

# The one line the shared script loads a part with, and the one form a wrapper
# names its service in.
$script:PartLinePattern = '^\. \(Get-Command -CommandType ExternalScript -Name \$startPart\)\.ScriptBlock\s*$'
$script:ServiceKeyPattern = "-ServiceKey '(stash|pool-control|download-agent)'"

function Get-YurunaServiceStartFile {
    <#
    .SYNOPSIS
        The files one service Start runs: its entry script, the shared
        pipeline and the service's readiness part, with the service key.
    .PARAMETER Path
        A Start-<Service>ServiceVM.ps1 entry script that forwards to the
        shared pipeline.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $wrapper = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($wrapper)) { throw "Start script not found: $wrapper" }
    $wrapperText = [IO.File]::ReadAllText($wrapper)
    if ($wrapperText -notmatch $script:ServiceKeyPattern) { throw "$wrapper names no service for Start-ExtensionService.ps1." }
    $key = $Matches[1]
    $folder = Split-Path -Parent $wrapper
    $shared = Join-Path $folder 'Start-ExtensionService.ps1'
    $part = Join-Path $folder "Start-ExtensionService.$key.ps1"
    foreach ($file in $shared, $part) {
        if (-not [IO.File]::Exists($file)) { throw "Start pipeline file not found: $file" }
    }
    return [pscustomobject]@{ Wrapper = $wrapper; ServiceKey = $key; Shared = $shared; Part = $part }
}

function Get-YurunaServiceStartPartBody {
    <#
    .SYNOPSIS
        A readiness part's code as the shared script runs it: without its
        header, the comment that introduces it and its param block, which
        carries only analyzer suppressions for the variables it shares.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "$Path does not parse: $($errors[0].Message)" }
    if (-not $ast.ParamBlock) { throw "$Path has no param block; a readiness part opens with one." }
    return $text.Substring($ast.ParamBlock.Extent.EndOffset).TrimStart("`n")
}

function Get-YurunaServiceStartText {
    <#
    .SYNOPSIS
        What one service Start runs, as a single text: the shared pipeline
        with the service's part in place of the line that loads it.
    .DESCRIPTION
        The order is the order the start runs, so a call-order check or a
        banner search reads across the move from one script into a shared one
        and a part. The other services' parts are not included.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $files = Get-YurunaServiceStartFile -Path $Path
    $text = [IO.File]::ReadAllText($files.Shared) -replace "`r`n", "`n"
    $out = [Text.StringBuilder]::new()
    $loaded = 0
    foreach ($line in $text.Split("`n")) {
        if ($line -match $script:PartLinePattern) {
            [void]$out.Append((Get-YurunaServiceStartPartBody -Path $files.Part)).Append("`n")
            $loaded++
        } else {
            [void]$out.Append($line).Append("`n")
        }
    }
    if ($loaded -ne 1) { throw "$($files.Shared) loads its service part $loaded times; expected once." }
    return $out.ToString().Substring(0, $out.Length - 1)
}

function Get-YurunaServiceStartAst {
    <#
    .SYNOPSIS
        The parsed form of Get-YurunaServiceStartText; offsets and line
        numbers count in that text.
    #>
    [CmdletBinding()]
    [OutputType([Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput((Get-YurunaServiceStartText -Path $Path), [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "The start run by $Path does not parse: $($errors[0].Message)" }
    return $ast
}

Export-ModuleMember -Function Get-YurunaServiceStartFile, Get-YurunaServiceStartPartBody, Get-YurunaServiceStartText, Get-YurunaServiceStartAst
