<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42efc002-974e-471c-8e46-0a144dd8c8fd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test style indentation whitespace
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
    PowerShell source indents with spaces, except inside here-strings.
.DESCRIPTION
    Mixed indentation renders differently everywhere it is read -- a review
    diff, a terminal, an editor with another tab width -- so a block that lines
    up for the author does not for the next reader. The repo indents with
    spaces; this keeps that true without anyone having to notice.

    The exemption is the point. Here-strings hold captured output that is
    compared byte for byte: plist XML, ifconfig blocks, command transcripts.
    Their tabs are DATA. Re-indenting them silently changes what the fixture
    asserts, and the test keeps passing against the altered expectation, so the
    corruption is invisible in exactly the place it matters most. A rule that
    scanned raw text would have to be disabled for those files, and disabling
    it for a file exempts that file's real code too -- so the extents come from
    the parser instead, which knows which lines are string content.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    Push-Location $script:RepoRoot
    try {
        $script:Sources = @(git ls-files --cached --others --exclude-standard |
                Where-Object { $_ -match '\.ps(m?)1$' } | Sort-Object -Unique)
    } finally { Pop-Location }

    # Lines any here-string covers, so string content is never judged as code.
    function Get-HereStringLine {
        param([Parameter(Mandatory)][string]$Path)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        $covered = [Collections.Generic.HashSet[int]]::new()
        if (-not $ast) { return $covered }
        foreach ($s in $ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                    $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
                }, $true)) {
            $ext = $s.Extent
            if ($ext.StartLineNumber -eq $ext.EndLineNumber) { continue }
            for ($i = $ext.StartLineNumber; $i -le $ext.EndLineNumber; $i++) { [void]$covered.Add($i) }
        }
        return $covered
    }
}

Describe 'PowerShell source indents with spaces' {
    It 'finds the tracked PowerShell sources' {
        Assert-True ($script:Sources.Count -gt 100) "expected the repo's sources, found $($script:Sources.Count)"
    }

    It 'indents no line of code with a tab' {
        $offenders = [Collections.Generic.List[string]]::new()
        foreach ($rel in $script:Sources) {
            $full = Join-Path $script:RepoRoot $rel
            $covered = $null
            $lines = Get-Content -LiteralPath $full
            $n = 0
            foreach ($line in $lines) {
                $n++
                if ($line -notmatch '^\t') { continue }
                if ($null -eq $covered) { $covered = Get-HereStringLine -Path $full }
                if ($covered.Contains($n)) { continue }   # fixture data, not indentation
                $offenders.Add("${rel}:${n}")
            }
        }
        Assert-True ($offenders.Count -eq 0) @"
these lines are indented with a tab outside any here-string:
$($offenders -join "`n")
"@
    }
}
