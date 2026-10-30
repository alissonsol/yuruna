<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42accc6c-6914-4c57-a2a1-9768c3dc7bd0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host driver source fixture
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

# A host driver is host/<driver>/modules/Yuruna.Host.psm1 plus the part files it
# dot-sources from the same folder, one per responsibility. A suite that reads
# driver source (to lift a function, slice a region or scan for a call) reads it
# through these functions, so it keeps working when code moves between the root
# module and its parts.

$script:DriverNames = @('macos.utm', 'ubuntu.kvm', 'windows.hyper-v')
# The one form a driver uses to load a part: a whole line, at module level.
$script:PartLinePattern = '^\. \(Join-Path \$PSScriptRoot ''(Yuruna\.Host\.[A-Za-z]+\.ps1)''\)\s*$'

function Get-YurunaDriverRepoRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$RepoRoot)
    if ($RepoRoot) { return [IO.Path]::GetFullPath($RepoRoot) }
    return [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
}

function Get-YurunaDriverFile {
    <#
    .SYNOPSIS
        The files of one host driver: the root module first, then each part in
        the order the root loads it.
    .PARAMETER RepoRoot
        A framework checkout to read; this module's own checkout by default.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:DriverNames })][string]$Driver,
        [string]$RepoRoot
    )
    $folder = Join-Path (Get-YurunaDriverRepoRoot -RepoRoot $RepoRoot) "host/$Driver/modules"
    $root = Join-Path $folder 'Yuruna.Host.psm1'
    if (-not [IO.File]::Exists($root)) { throw "Driver module not found: $root" }
    $files = [Collections.Generic.List[string]]::new()
    $files.Add($root)
    foreach ($line in [IO.File]::ReadAllLines($root)) {
        if ($line -match $script:PartLinePattern) {
            $part = Join-Path $folder $Matches[1]
            if (-not [IO.File]::Exists($part)) { throw "Driver part not found: $part" }
            $files.Add($part)
        }
    }
    return [string[]]$files
}

function Get-YurunaDriverPartBody {
    <#
    .SYNOPSIS
        A part file's code without its own header: the PSScriptInfo block, the
        #requires line and the blank lines that follow them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $lines = [IO.File]::ReadAllLines($Path)
    $index = 0
    if ($lines.Count -gt 0 -and $lines[0] -eq '<#PSScriptInfo') {
        while ($index -lt $lines.Count -and $lines[$index] -ne '#>') { $index++ }
        $index++
    }
    while ($index -lt $lines.Count -and ($lines[$index] -eq '' -or $lines[$index] -like '#requires*')) { $index++ }
    return ($lines[$index..($lines.Count - 1)] -join "`n")
}

function Get-YurunaDriverText {
    <#
    .SYNOPSIS
        One driver's source as a single text: the root module with each part's
        code in place of the line that loads it.
    .DESCRIPTION
        The order is the order the module runs, so a region slice or a pattern
        that spans a moved block reads as it did before the block moved.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:DriverNames })][string]$Driver,
        [string]$RepoRoot
    )
    $folder = Join-Path (Get-YurunaDriverRepoRoot -RepoRoot $RepoRoot) "host/$Driver/modules"
    $root = Join-Path $folder 'Yuruna.Host.psm1'
    if (-not [IO.File]::Exists($root)) { throw "Driver module not found: $root" }
    $text = [IO.File]::ReadAllText($root) -replace "`r`n", "`n"
    $out = [Text.StringBuilder]::new()
    foreach ($line in $text.Split("`n")) {
        if ($line -match $script:PartLinePattern) {
            $part = Join-Path $folder $Matches[1]
            if (-not [IO.File]::Exists($part)) { throw "Driver part not found: $part" }
            [void]$out.Append((Get-YurunaDriverPartBody -Path $part)).Append("`n")
        } else {
            [void]$out.Append($line).Append("`n")
        }
    }
    return $out.ToString().Substring(0, $out.Length - 1)
}

function Get-YurunaDriverAst {
    <#
    .SYNOPSIS
        The parsed form of Get-YurunaDriverText; line numbers count in that text.
    #>
    [CmdletBinding()]
    [OutputType([Management.Automation.Language.ScriptBlockAst])]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:DriverNames })][string]$Driver,
        [string]$RepoRoot
    )
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput((Get-YurunaDriverText -Driver $Driver -RepoRoot $RepoRoot), [ref]$null, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "Driver $Driver does not parse: $($errors[0].Message)" }
    return $ast
}

function Get-YurunaDriverFunction {
    <#
    .SYNOPSIS
        The definition text of one top-level function of a driver, from
        whichever of its files defines it.
    .DESCRIPTION
        Throws when no file, or more than one, defines the name, so a suite that
        lifts a function fails on its own line instead of running a stand-in.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:DriverNames })][string]$Driver,
        [Parameter(Mandatory)][string]$Name,
        [string]$RepoRoot
    )
    $found = @(foreach ($file in (Get-YurunaDriverFile -Driver $Driver -RepoRoot $RepoRoot)) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        foreach ($node in $ast.FindAll({ param($candidate)
                    $candidate -is [Management.Automation.Language.FunctionDefinitionAst] -and $candidate.Name -ceq $Name }, $true)) {
            # A helper of the same name nested in another function is not the driver's.
            $nested = $false
            for ($parent = $node.Parent; $parent; $parent = $parent.Parent) {
                if ($parent -is [Management.Automation.Language.FunctionDefinitionAst]) { $nested = $true; break }
            }
            if (-not $nested) { $node }
        }
    })
    if ($found.Count -ne 1) { throw "Expected one definition of $Name in the $Driver driver, found $($found.Count)." }
    return $found[0].Extent.Text
}

function Resolve-YurunaDriverPath {
    <#
    .SYNOPSIS
        For a path to a driver's root module, its driver name and checkout;
        $null for any other file.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path) -replace '\\', '/'
    if ($full -match '^(?<root>.*)/host/(?<driver>macos\.utm|ubuntu\.kvm|windows\.hyper-v)/modules/Yuruna\.Host\.psm1$') {
        return @{ Driver = $Matches['driver']; RepoRoot = $Matches['root'] }
    }
    return $null
}

function Get-YurunaSourceText {
    <#
    .SYNOPSIS
        The text of a source file; for a driver's root module, the whole
        driver as Get-YurunaDriverText reads it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $driver = Resolve-YurunaDriverPath -Path $Path
    if ($driver) { return (Get-YurunaDriverText -Driver $driver.Driver -RepoRoot $driver.RepoRoot) }
    return [IO.File]::ReadAllText($Path)
}

function Get-YurunaSourceAst {
    <#
    .SYNOPSIS
        The parsed form of Get-YurunaSourceText for a file.
    #>
    [CmdletBinding()]
    [OutputType([Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $driver = Resolve-YurunaDriverPath -Path $Path
    if ($driver) { return (Get-YurunaDriverAst -Driver $driver.Driver -RepoRoot $driver.RepoRoot) }
    return [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
}

function Get-YurunaSourceFunction {
    <#
    .SYNOPSIS
        The definition text of a top-level function in a source file; for a
        driver's root module, from whichever driver file defines it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $driver = Resolve-YurunaDriverPath -Path $Path
    if ($driver) { return (Get-YurunaDriverFunction -Driver $driver.Driver -Name $Name -RepoRoot $driver.RepoRoot) }
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $found = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $Name }, $true)
    if (-not $found) { throw "Expected one definition of $Name in $Path, found 0." }
    return $found.Extent.Text
}

Export-ModuleMember -Function Get-YurunaDriverFile, Get-YurunaDriverPartBody, Get-YurunaDriverText, Get-YurunaDriverAst, Get-YurunaDriverFunction, `
    Resolve-YurunaDriverPath, Get-YurunaSourceText, Get-YurunaSourceAst, Get-YurunaSourceFunction
