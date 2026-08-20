<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42d7f1b6-3c40-4e58-9a21-6b8d0f2a4c73
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna docs links reachability
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
    Every shipped document is reachable by following links from README.md.
.DESCRIPTION
    A document nobody links is a document nobody reads, and the repo had
    accumulated them quietly -- the count was measured at 17, then 20, and each
    measurement was a one-off that nothing preserved.

    Reachability follows what a reader actually does: a link to `lab/` lands on
    `lab/README.md`, the same as GitHub renders it, so a folder link counts.
    Checking only `*.md` targets would report a dozen false orphans and train
    everyone to ignore the result.

    CLAUDE.md is excluded deliberately rather than linked. It is stripped from
    the public mirror by KEEP-PRIVATE.txt, so a link to it from README.md would
    be a broken link in the repository most readers see.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here

    # Private to the dev repo, so never part of the public link graph.
    $script:Excluded = @('CLAUDE.md')

    function Get-ShippedDoc {
        Push-Location $script:RepoRoot
        try {
            @(git ls-files '*.md' |
                    Where-Object { $_ -notlike 'dev-only/*' } |
                    Where-Object { $_ -notin $script:Excluded })
        } finally { Pop-Location }
    }

    function Get-DocLink {
        param([string]$Relative)
        $full = Join-Path $script:RepoRoot $Relative
        if (-not (Test-Path -LiteralPath $full)) { return @() }
        $dir  = Split-Path -Parent $Relative
        $text = Get-Content -Raw -LiteralPath $full
        $out  = [Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($text, '\]\((?!https?://|#)([^)#]+)')) {
            $raw = $m.Groups[1].Value.Trim()
            $joined = if ($dir) { Join-Path $dir $raw } else { $raw }
            $norm = ($joined -replace '\\', '/')
            # Collapse ../ segments the way a reader's browser does.
            $parts = [Collections.Generic.List[string]]::new()
            foreach ($seg in ($norm -split '/')) {
                if ($seg -eq '.' -or $seg -eq '') { continue }
                if ($seg -eq '..') { if ($parts.Count) { $parts.RemoveAt($parts.Count - 1) }; continue }
                $parts.Add($seg)
            }
            $p = $parts -join '/'
            if ($raw.EndsWith('/') -or (Test-Path -LiteralPath (Join-Path $script:RepoRoot $p) -PathType Container)) {
                $out.Add("$p/README.md")
            } elseif ($p -like '*.md') {
                $out.Add($p)
            }
        }
        $out
    }
}

Describe 'the documentation link graph' {

    It 'reaches every shipped document from README.md' {
        $docs = Get-ShippedDoc
        Assert-True ($docs.Count -gt 50) "expected the doc set, found $($docs.Count)"

        $seen  = [Collections.Generic.HashSet[string]]::new()
        [void]$seen.Add('README.md')
        $queue = [Collections.Generic.Queue[string]]::new()
        $queue.Enqueue('README.md')
        while ($queue.Count -gt 0) {
            foreach ($l in (Get-DocLink -Relative $queue.Dequeue())) {
                if (($docs -contains $l) -and $seen.Add($l)) { $queue.Enqueue($l) }
            }
        }
        $orphans = @($docs | Where-Object { -not $seen.Contains($_) })
        Assert-NoFinding -Finding $orphans `
            -Because 'a document nothing links to is one nobody finds; link it, or delete it if it has no reader'
    }
}
