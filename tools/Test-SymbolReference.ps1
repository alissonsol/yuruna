<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42550c03-bbdb-4270-97dd-067cdbeba71a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna documentation symbols gate
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
    Find PowerShell command names in documentation and comments that name
    nothing in the tree.
.DESCRIPTION
    A Verb-Noun name in prose is a pointer: an operator types it, a reader
    searches the tree for it. A function that is renamed or removed leaves
    those pointers behind with nothing to say they are stale, so they keep
    sending readers to code that is not there.

    A name resolves when it is a function defined in any root (scope prefixes
    such as script: are stripped), the stem of a script or tool file (.ps1,
    .psm1, .py, .sh, and a Pester suite's stem), a command of the running
    PowerShell, or an entry of tools/symbol-reference.allowlist.json: commands
    of modules the running host may lack (Hyper-V, SMB, local accounts),
    optional hooks the code calls when a module provides them, and illustrative
    names in examples, each with its reason. A function a script defines inside
    a here-string (a script it writes out and runs) counts as defined too.

    Checked: the tracked and untracked (not ignored) Markdown, and the comments
    of the PowerShell, of each root, except dev-only/ (designs name commands
    still proposed), CHANGELOG.md (history), and generated catalogs and SBOMs.
    Not a name: a token followed by * (a family of names), by / or after /
    (a slash-joined list or a DISM switch), or followed by a dot and letters
    (a file name).
.PARAMETER Root
    Repositories to check and resolve against. Default: this repository.
.PARAMETER AllowListPath
    The allow-list. Default: symbol-reference.allowlist.json beside this script.
.OUTPUTS
    Exit 0: no finding. 1: a name that resolves to nothing. 2: bad input.
#>

[CmdletBinding()]
param(
    [string[]]$Root,
    [string]$AllowListPath
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = @(Split-Path -Parent $PSScriptRoot) }
if (-not $AllowListPath) { $AllowListPath = Join-Path $PSScriptRoot 'symbol-reference.allowlist.json' }

# --- REGION: Get-CandidateFile
function Get-CandidateFile {
    param([Parameter(Mandatory)][string]$Repository)
    $listed = @(& git -C $Repository ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "git could not list the files of $Repository" }
    return @($listed | Sort-Object -Unique)
}

# --- REGION: Test-OutOfScope
function Test-OutOfScope {
    param([Parameter(Mandatory)][string]$RelativePath)
    return ($RelativePath.StartsWith('dev-only/', [StringComparison]::Ordinal) -or
        $RelativePath -like '*CHANGELOG.md' -or
        $RelativePath.StartsWith('globalization/', [StringComparison]::Ordinal) -or
        $RelativePath -like '*/generated/*' -or
        $RelativePath -like 'docs/sbom/*' -or $RelativePath -like '*/docs/sbom/*')
}

try {
    $allow = Get-Content -LiteralPath $AllowListPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "the allow-list is unreadable ($AllowListPath): $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}
$known = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($group in $allow.commands.PSObject.Properties) { foreach ($name in @($group.Value)) { $null = $known.Add([string]$name) } }
foreach ($entry in @($allow.hooks.PSObject.Properties) + @($allow.illustrative.PSObject.Properties)) { $null = $known.Add($entry.Name) }
foreach ($command in Get-Command -CommandType Cmdlet, Function -ErrorAction SilentlyContinue) { $null = $known.Add($command.Name) }

$files = @{}
foreach ($repository in $Root) {
    $full = (Resolve-Path -LiteralPath $repository).Path
    $files[$full] = Get-CandidateFile -Repository $full
    foreach ($relative in $files[$full]) {
        $leaf = [IO.Path]::GetFileName($relative)
        if ($leaf.EndsWith('.Tests.ps1', [StringComparison]::OrdinalIgnoreCase)) { $null = $known.Add($leaf.Substring(0, $leaf.Length - 10)) }
        elseif ($leaf -match '^([A-Za-z]+-[A-Za-z0-9]+)\.(ps1|psm1|py|sh)$') { $null = $known.Add($Matches[1]) }
        if ($leaf -notmatch '\.(ps1|psm1)$') { continue }
        $path = Join-Path $full $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $null = $known.Add(($definition.Name -replace '^(script|global|local|private):', ''))
        }
        # A runtime written out of a here-string defines its functions in text
        # the parser sees only as a string.
        foreach ($text in [regex]::Matches([IO.File]::ReadAllText($path), '(?m)^\s*function\s+(?:(?:script|global|local|private):)?([A-Za-z]+-[A-Za-z0-9]+)')) {
            $null = $known.Add($text.Groups[1].Value)
        }
    }
}

$verbs = @((Get-Verb).Verb | Sort-Object -Property Length -Descending)
$pattern = [regex]::new('(?<![\w$.\-/\\])(?:' + ($verbs -join '|') + ')-[A-Z][A-Za-z0-9]*(?![\w\-*/]|\.[A-Za-z])')

$findings = [Collections.Generic.List[string]]::new()
$checked = 0
foreach ($full in $files.Keys) {
    $name = Split-Path -Leaf $full
    foreach ($relative in $files[$full]) {
        if (Test-OutOfScope -RelativePath $relative) { continue }
        $path = Join-Path $full $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $segments = @()
        if ($relative -like '*.md') {
            $segments = @([pscustomobject]@{ Text = [IO.File]::ReadAllText($path); Line = 1 })
        } elseif ($relative -match '\.(ps1|psm1)$') {
            $tokens = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$null)
            $segments = @($tokens | Where-Object { $_.Kind -eq [Management.Automation.Language.TokenKind]::Comment } |
                ForEach-Object { [pscustomobject]@{ Text = $_.Text; Line = $_.Extent.StartLineNumber } })
        } else { continue }
        $checked++
        foreach ($segment in $segments) {
            foreach ($match in $pattern.Matches($segment.Text)) {
                if ($known.Contains($match.Value)) { continue }
                $line = $segment.Line + ([regex]::Matches($segment.Text.Substring(0, $match.Index), "`n")).Count
                $findings.Add("FAIL  ${name}/${relative}:$line $($match.Value) names nothing in the tree")
            }
        }
    }
}

foreach ($finding in $findings) { Write-Output $finding }
Write-Output ("Test-SymbolReference: {0} repo(s), {1} file(s) checked, {2} unresolved name(s)." -f $Root.Count, $checked, $findings.Count)
if ($findings.Count -gt 0) { exit 1 }
exit 0
