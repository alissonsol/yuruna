<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42d5631c-7360-4f48-8d8e-8a86935d048d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna tools lint shellcheck scope
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

# Explicit scopes for the lint and shellcheck gates. A scope names one file or
# one directory and has to select source; it never widens into a whole-tree
# scan. Both gates resolve scopes here, so a path one gate accepts is accepted by
# the other, and neither can drift into a silent pass on a path it did not match.

# --- REGION: ConvertTo-GateScope
function ConvertTo-GateScope {
    <#
    .SYNOPSIS
        Normalize a repository-relative scope; reject blank, rooted, or parent-traversing input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'An explicit scope must name a file or directory.'
    }
    $normalized = $Value -replace '\\', '/'
    if ($normalized.StartsWith('/', [StringComparison]::Ordinal) -or
        $normalized -match '^[A-Za-z]:') {
        throw "Scope must be repository-relative here: '$Value'."
    }
    $segments = @($normalized -split '/' | Where-Object { $_ -and $_ -cne '.' })
    if ($segments -contains '..') {
        throw "Scope cannot traverse parent directories: '$Value'."
    }
    return ($segments -join '/')
}

# --- REGION: Resolve-GateTarget
function Resolve-GateTarget {
    <#
    .SYNOPSIS
        Resolve an explicit scope to a repository-relative scope, or to an existing path outside the repository.
    .DESCRIPTION
        A rooted path that lands inside the repository is rewritten to its repository-relative
        form, so the same file reads the same whichever spelling the caller used. A rooted
        path outside the repository names an external file or directory, which the caller lists
        with Get-GateExternalFile. A path that does not exist throws, because a scope that
        names nothing must fail rather than pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'An explicit scope must name a file or directory.'
    }
    $normalized = $Value -replace '\\', '/'
    $rooted = [IO.Path]::IsPathRooted($Value) -or
        $normalized.StartsWith('/', [StringComparison]::Ordinal) -or
        $normalized -match '^[A-Za-z]:'
    if (-not $rooted) {
        return [pscustomobject]@{ Kind = 'Repository'; Scope = (ConvertTo-GateScope -Value $Value); Path = $null }
    }

    # Windows paths are case-insensitive; POSIX paths are not, so a sibling that
    # differs only by case is a different directory on Linux and macOS.
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $root = (([IO.Path]::GetFullPath($RepoRoot)) -replace '\\', '/').TrimEnd('/')
    $full = [IO.Path]::GetFullPath($normalized)
    $fullNormalized = ($full -replace '\\', '/').TrimEnd('/')
    if ([string]::Equals($fullNormalized, $root, $comparison)) {
        return [pscustomobject]@{ Kind = 'Repository'; Scope = ''; Path = $null }
    }
    if ($fullNormalized.StartsWith($root + '/', $comparison)) {
        $inside = $fullNormalized.Substring($root.Length + 1)
        return [pscustomobject]@{ Kind = 'Repository'; Scope = (ConvertTo-GateScope -Value $inside); Path = $null }
    }
    if (-not (Test-Path -LiteralPath $full)) {
        throw "Scope '$Value' does not exist."
    }
    return [pscustomobject]@{ Kind = 'External'; Scope = $null; Path = $full }
}

# --- REGION: Get-GateExternalFile
function Get-GateExternalFile {
    <#
    .SYNOPSIS
        List the files an external file or directory names, using the selector the gates use inside a repository.
    .DESCRIPTION
        A file names itself. A directory inside a git worktree yields its tracked and
        non-ignored files, so generated and ignored trees stay out of the scan exactly as they
        do in the repository. A directory outside any worktree falls back to every file below
        it except git metadata.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Leaf) { return @($Path) }
    $listed = @(& git -C $Path ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -eq 0) {
        return @($listed | Where-Object { $_ } | ForEach-Object { Join-Path $Path $_ })
    }
    return @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { $_.FullName })
}

# --- REGION: Test-GateScopeMatch
function Test-GateScopeMatch {
    <#
    .SYNOPSIS
        Match one exact file or the descendants of one directory, never a sibling that shares a name prefix.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Scope
    )

    return -not $Scope -or
        [string]::Equals($RelativePath, $Scope, [StringComparison]::OrdinalIgnoreCase) -or
        $RelativePath.StartsWith($Scope + '/', [StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function ConvertTo-GateScope, Resolve-GateTarget, Get-GateExternalFile, Test-GateScopeMatch
