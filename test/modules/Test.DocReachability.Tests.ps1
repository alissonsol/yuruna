<#PSScriptInfo
.VERSION 2026.09.18
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

    function Invoke-RouterBrowserFloor {
        param([string]$RouterRoot, [string]$OutputRoot)
        foreach ($entrypoint in @('index.html', '404.html')) {
            if (-not (Test-Path -LiteralPath (Join-Path $RouterRoot $entrypoint) -PathType Leaf)) {
                throw "Router entrypoint is missing: $entrypoint"
            }
        }
        [void](New-Item -ItemType Directory -Path $OutputRoot)
        Get-ChildItem -LiteralPath $RouterRoot -File -Filter '*.js' |
            Where-Object Name -NotLike '*.test.js' |
            Copy-Item -Destination $OutputRoot
        $producers = [Collections.Generic.List[string]]::new()
        foreach ($page in Get-ChildItem -LiteralPath $RouterRoot -File -Filter '*.html') {
            $index = 0
            foreach ($block in [regex]::Matches([IO.File]::ReadAllText($page.FullName), '(?is)<script\b(?![^>]*\bsrc\s*=)[^>]*>(.*?)</script>')) {
                $index++
                $body = $block.Groups[1].Value
                if (-not $body.Trim()) { continue }
                $producer = "$($page.Name).inline-$index.js"
                $path = Join-Path $OutputRoot $producer
                [IO.File]::WriteAllText($path, $body)
                if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                    [IO.File]::ReadAllText($path) -cne $body) {
                    throw "Router inline extraction did not preserve $producer"
                }
                $producers.Add($producer)
            }
        }
        $output = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $script:RepoRoot 'tools/Invoke-Es5Check.ps1') -Path $OutputRoot 2>&1
        @{ ExitCode = $LASTEXITCODE; Output = $output -join "`n"; Producers = @($producers) }
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

Describe 'public globalization guidance' {
    It 'globalization acceptance: public globalization navigation in both repositories' {
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md')) | Should -Match '\]\(docs/globalization\.md\)'
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'docs/README.md')) | Should -Match '\]\(globalization\.md\)'
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'CONTRIBUTING.md')) | Should -Match '\]\(docs/globalization\.md\)'
        $guide = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'docs/globalization.md'))
        $guide | Should -Match 'locale-manifest\.json'
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'README.md')) | Should -Match '\]\(docs/pt-BR/index\.md\)'
        [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'docs/pt-BR/index.md')) | Should -Match 'README\.md'
        $guide | Should -Match 'yuruna-project/blob/main/docs/globalization\.md'
        $project = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
        if (Test-Path -LiteralPath $project -PathType Container) {
            [IO.File]::ReadAllText((Join-Path $project 'README.md')) | Should -Match '\]\(docs/globalization\.md\)'
            [IO.File]::ReadAllText((Join-Path $project 'README.md')) | Should -Match '\]\(docs/pt-BR/index\.md\)'
            [IO.File]::ReadAllText((Join-Path $project 'docs/pt-BR/index.md')) | Should -Match '../../README\.md'
            [IO.File]::ReadAllText((Join-Path $project 'docs/globalization.md')) | Should -Match 'yuruna/blob/main/docs/globalization\.md'
        }
    }
    It 'globalization acceptance: router ES5 XHR and preserved short links' {
        $router = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link'
        if (-not (Test-Path -LiteralPath $router -PathType Container)) {
            Set-ItResult -Skipped -Because 'Auxiliary router repository is outside the public framework checkout.'
            return
        }
        $output = & node (Join-Path $router 'redirect.test.js') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $result = Invoke-RouterBrowserFloor -RouterRoot $router -OutputRoot (Join-Path $TestDrive 'router-floor')
        $result.ExitCode | Should -Be 0 -Because $result.Output
    }
    It 'rejects modern syntax in the router <Page> inline producer' -TestCases @(
        @{ Page = 'index.html'; OtherPage = '404.html' }
        @{ Page = '404.html'; OtherPage = 'index.html' }
    ) {
        param($Page, $OtherPage)
        $router = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link'
        if (-not (Test-Path -LiteralPath $router -PathType Container)) {
            Set-ItResult -Skipped -Because 'Auxiliary router repository is outside the public framework checkout.'
            return
        }
        $fixtureRoot = Join-Path $TestDrive "$Page-fixture"
        [void](New-Item -ItemType Directory -Path $fixtureRoot)
        Get-ChildItem -LiteralPath $router -File |
            Where-Object { $_.Extension -in @('.js', '.html') } |
            Copy-Item -Destination $fixtureRoot
        $pagePath = Join-Path $fixtureRoot $Page
        $html = [IO.File]::ReadAllText($pagePath)
        $html | Should -Match '</body>'
        [IO.File]::WriteAllText($pagePath, $html.Replace('</body>', '<script>let unsafeRouter = () => 1;</script></body>'))

        $result = Invoke-RouterBrowserFloor -RouterRoot $fixtureRoot -OutputRoot (Join-Path $TestDrive "$Page-floor")
        $producer = @($result.Producers | Where-Object { $_ -like "$Page.inline-*.js" })
        $producer.Count | Should -BeGreaterThan 0 -Because 'the injected executable body must reach the real checker'
        $result.ExitCode | Should -Not -Be 0 -Because 'the baseline browser cannot parse the injected inline body'
        $result.Output | Should -Match ([regex]::Escape($producer[-1]))
        $result.Output | Should -Match 'arrow function'
        $result.Output | Should -Match 'let declaration'
        $result.Output | Should -Not -Match ([regex]::Escape("$OtherPage.inline-"))
    }
}
