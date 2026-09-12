<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42a4c7d2-1f58-4b93-8c07-5e6d2a91f374
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization gates registry performance pester
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
    Run the globalization gates that only fail when something is actually wrong,
    and hold the one list they all read.
.DESCRIPTION
    Several tools have to agree about which files the project ships to a
    browser. When each kept its own list, a directory could appear in one and
    not another, and a file would then pass only the checks somebody remembered
    to point at it -- which is indistinguishable from passing all of them. They
    now read globalization/manifests/browser-sources.json, and this suite is
    what notices when the registry stops describing the tree.

    The performance rows here are the cheap deterministic ones: bytes and
    request counts, measured from the working tree, identical on any machine.
    That is what lets them sit in an ordinary suite. Timing is a different
    instrument with different failure modes and lives in its own harness.

    Run: Invoke-Pester -Path test/modules/Test.GlobalizationGates.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module PSScriptAnalyzer -ErrorAction SilentlyContinue

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:RegistryPath = Join-Path $script:RepoRoot 'globalization/manifests/browser-sources.json'
$script:Registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:RegistryPath))
$script:CrossRepoPath = Join-Path $script:RepoRoot 'tools/Invoke-CrossRepoGate.ps1'
$script:CrossRepoAst = [Management.Automation.Language.Parser]::ParseFile(
    $script:CrossRepoPath, [ref]$null, [ref]$null)
$script:LintAst = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $script:RepoRoot 'tools/Invoke-Lint.ps1'), [ref]$null, [ref]$null)

function Get-CrossRepoFunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name is used inside the AST predicate, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $function = $script:CrossRepoAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $function) { return '' }
    return $function.Extent.Text
}

function Get-LintFunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name is used inside the AST predicate, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $function = $script:LintAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $function) { return '' }
    return $function.Extent.Text
}

function Invoke-Gate {
    <#
    .SYNOPSIS
        Run one tool and return its exit code and output together.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Script, [string[]]$Arguments = @())
    $path = Join-Path $script:RepoRoot $Script
    $output = & pwsh -NoProfile -File $path @Arguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}

function New-PerfFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates only disposable files and a disposable Git index below Pester TestDrive.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
    $site = Join-Path $root 'site'
    New-Item -ItemType Directory -Path $site -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $site 'index.html'),
        '<!doctype html><script>var ready = true;</script>')
    & git -C $root init --quiet
    & git -C $root add -- 'site/index.html'
    $registryPath = Join-Path $root 'browser-sources.json'
    $baselinePath = Join-Path $root 'perf-baseline.json'
    $registry = [ordered]@{
        roots = @([ordered]@{ path = 'site' })
        excludeSuffixes = @('.test.js')
        pages = @([ordered]@{ path = 'site/index.html' })
    }
    [IO.File]::WriteAllText($registryPath, (ConvertTo-Json -InputObject $registry -Depth 8))
    $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' -Arguments @(
        '-Root', $root, '-RegistryPath', $registryPath, '-BaselinePath', $baselinePath,
        '-Update', '-Quiet')
    Assert-Equal -Expected 0 -Actual $result.Code -Because $result.Output
    return @{ Root = $root; Registry = $registryPath; Baseline = $baselinePath }
}
}

Describe 'one registry names every browser source' {

    It 'lists roots that all exist' {
        $findings = @()
        foreach ($root in $script:Registry.roots) {
            $path = Join-Path $script:RepoRoot ([string]$root.path)
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                $findings += "$($root.path): the registry names a directory that is not in the tree"
            }
        }
        Assert-NoFinding $findings 'the registry describes a tree that no longer exists'
    }

    It 'accounts for every shipped browser asset in the tree' {
        # The direction that matters. A registry missing a directory is a set of
        # files that quietly stop being checked, and nothing else would say so.
        #
        # The search covers the WHOLE tracked tree, not a list of places to
        # look. A search list is itself a second registry: a root dropped from
        # the real one and absent from the search list disappears from both,
        # and the gate reports nothing -- which is exactly what a passing gate
        # looks like. Every tracked stylesheet and script must be claimed by
        # some root, so removing any root leaves its files unclaimed.
        $known = @()
        foreach ($root in $script:Registry.roots) { $known += ([string]$root.path) -replace '\\', '/' }

        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }
        Assert-True ($tracked.Count -gt 100) `
            'git listed almost nothing, so this gate is measuring the wrong tree'

        $findings = @()
        foreach ($relative in $tracked) {
            if ($relative -notmatch '\.(js|css)$') { continue }
            $skip = $false
            foreach ($suffix in @($script:Registry.excludeSuffixes)) {
                if ($relative.EndsWith([string]$suffix)) { $skip = $true; break }
            }
            if ($skip) { continue }
            $covered = $false
            foreach ($root in $known) { if ($relative.StartsWith("$root/")) { $covered = $true; break } }
            if (-not $covered) { $findings += "$relative is shipped to a browser and no registry root covers it" }
        }
        Assert-NoFinding $findings 'a browser source is outside every gate that reads the registry'
    }

    It 'claims every file that produces CSS a browser will apply' {
        # Same shape as the asset check above, and the same reason. Dropping a
        # producer from the registry does not fail the palette tools -- they
        # simply check one file fewer and report success over the gap. So the
        # tree is asked instead: anything that consumes a custom property is a
        # producer, and must be declared.
        #
        # Test files and the generator itself carry var(--) as fixture text or
        # as the pattern they search for. They ship to no browser.
        $declared = @($script:Registry.cssProducers | ForEach-Object { [string]$_.path })
        Assert-True ($declared.Count -ge 10) 'the registry declares too few CSS producers to describe the surface'

        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }

        $findings = @()
        foreach ($relative in $tracked) {
            if ($relative -notmatch '\.(css|html|go|ps1|psm1|js)$') { continue }
            if ($relative -like 'dev-only/*' -or $relative -like 'tools/*') { continue }
            if ($relative -match '(_test\.go|\.Tests\.ps1|\.test\.js)$') { continue }
            $full = Join-Path $script:RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($full)
            # Two triggers, because one is not enough. A custom property is the
            # obvious one, but a producer that styles only with literal colors
            # has none -- and the floor rules this registry feeds are about flex
            # gap, grid, logical properties and safe-area units, none of which
            # need a custom property either. Selecting on var(--) alone is how a
            # whole shipped page stayed outside every floor gate: it is a page
            # that carries a stylesheet, not a page that carries a token.
            # Both tags, anywhere in the file. A producer that assembles its
            # document in pieces writes the open and the close from separate
            # statements, so they are not adjacent in the source and the body
            # between them is code rather than CSS -- matching an opening tag
            # followed by a declaration would miss exactly that shape. A bare
            # mention (a comment saying a page carries no inline style, a CSP
            # note naming the tag) has the open and no close, so requiring both
            # separates a producer from a sentence about one.
            $carriesStyle = ($relative -match '\.css$') -or
                (($text -match '(?i)<style[\s>]') -and ($text -match '(?i)</style\s*>'))
            if (-not $carriesStyle -and $text.IndexOf('var(--') -lt 0) { continue }
            if ($declared -notcontains $relative) {
                $why = if ($text.IndexOf('var(--') -ge 0) { 'uses a custom property' } else { 'carries a stylesheet' }
                $findings += "$relative $why and is not a declared CSS producer"
            }
        }
        Assert-NoFinding $findings 'a file the floor has to render is outside the palette-fallback tools'
    }

    It 'claims every file that carries browser code inside something else' {
        # A page whose script lives in a Go string literal or an HTML block is
        # shipped JavaScript that a sweep for *.js never sees. Left undeclared
        # it reports a clean floor by not being looked at, which is the same
        # answer a genuinely clean file gives.
        $declared = @($script:Registry.inlineScriptProducers | ForEach-Object { [string]$_.path })

        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }

        $findings = @()
        foreach ($relative in $tracked) {
            if ($relative -notmatch '\.(html|go|ps1|psm1)$') { continue }
            if ($relative -like 'dev-only/*' -or $relative -like 'tools/*') { continue }
            if ($relative -match '(_test\.go|\.Tests\.ps1)$') { continue }
            $full = Join-Path $script:RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $text = [IO.File]::ReadAllText($full)
            # A block naming a src is a reference to a file already checked.
            $blocks = [regex]::Matches($text, '(?s)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>')
            $hasBody = $false
            foreach ($b in $blocks) { if ($b.Groups[1].Value.Trim()) { $hasBody = $true; break } }
            if (-not $hasBody) { continue }
            if ($declared -notcontains $relative) {
                $findings += "$relative carries an inline script and is not a declared producer"
            }
        }
        Assert-NoFinding $findings 'shipped browser code sits outside the floor check'
    }

    It 'claims every directory that holds a shipped page' {
        # Same shape as the other two coverage rules. A service UI missing from
        # the page-root list is never rendered for contrast, focus order or
        # reflow, and the accessibility gate reports a clean run over it --
        # which is the output an accessible UI also produces.
        $declared = @($script:Registry.pageRoots | ForEach-Object { ([string]$_.path) -replace '\\', '/' })
        Assert-True ($declared.Count -ge 3) 'the registry declares too few page roots to describe the surface'

        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }

        $findings = @()
        foreach ($relative in $tracked) {
            if ($relative -notmatch '\.html$') { continue }
            if ($relative -like 'dev-only/*' -or $relative -like 'docs/*') { continue }
            $dir = ($relative -replace '/[^/]+$', '')
            $covered = $false
            foreach ($root in $declared) {
                if ($dir -eq $root -or $dir.StartsWith("$root/")) { $covered = $true; break }
            }
            if (-not $covered) { $findings += "$relative is a shipped page and no page root covers it" }
        }
        Assert-NoFinding $findings 'a page sits outside the accessibility sweep'
    }

    It 'claims every whole page a host writes into a guest' {
        # The reverse-discovery rules above all select by extension -- .html,
        # .go, .ps1, .css. A provisioning seed is none of those, so a page
        # written by one is invisible to every sweep in this file unless its
        # producer is named here. A page nothing sweeps is a page whose charset
        # and lang nothing checks, and it is served at the one moment a reader
        # is already looking at a failure.
        $declared = @($script:Registry.provisionedPageProducers |
            ForEach-Object { ([string]$_.path) -replace '\\', '/' })
        Assert-True ($declared.Count -ge 1) 'the registry names no provisioned page producer'

        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard) } finally { Pop-Location }

        $findings = @()
        foreach ($relative in $tracked) {
            # Everything the rules above do not already claim by extension. A
            # hand-written list of provisioning extensions would only find the
            # kind of file someone already thought of, which is the failure this
            # rule exists to catch -- a page can just as easily be written by a
            # shell script or a YAML template.
            if ($relative -match '\.(html|go|ps1|psm1|js|css|json|md)$') { continue }
            if ($relative -like 'dev-only/*' -or $relative -like 'docs/*') { continue }
            # The recorded reference captures are frozen copies of what the
            # registered producers already emit, and nothing serves them. An
            # entry here would put a page in the registry that no host writes
            # anywhere, which is the same false claim from the other side.
            if ($relative -like 'globalization/fixtures/reference/*') { continue }
            $full = Join-Path $script:RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            # FileInfo rather than Get-Item: PowerShell treats a dot-prefixed
            # name as hidden on Unix, and Get-Item without -Force reports the
            # repository's own .gitattributes as missing.
            if ([IO.FileInfo]::new($full).Length -gt 2MB) { continue }
            $text = [IO.File]::ReadAllText($full)
            # A whole document, not a fragment someone mentioned: the opening
            # tag is what makes a browser parse the bytes as a page.
            if ($text -notmatch '(?i)<html\b') { continue }
            if ($declared -notcontains $relative) {
                $findings += "$relative writes a whole HTML document and no producer entry claims it"
            }
        }
        Assert-NoFinding $findings 'a provisioned page escapes the browser registry'
    }

    It 'materializes each provisioned page with a valid document shape' {
        # The registry entry alone proves nothing: the gate has to be able to
        # get the bytes back out of the seed and see a real document in them.
        $exported = Join-Path $TestDrive 'provisioned-pages'
        $run = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'tools/Export-GeneratedPages.ps1') `
            -OutputDirectory $exported -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because $run
        $findings = @()
        foreach ($producer in $script:Registry.provisionedPageProducers) {
            $seedPath = Join-Path $script:RepoRoot ([string]$producer.path)
            if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
                $findings += "$($producer.path): the registry names a producer that is not in the tree"
                continue
            }
            $seed = [IO.File]::ReadAllText($seedPath)
            if (-not $seed.Contains([string]$producer.marker)) {
                $findings += "$($producer.path): the marker '$($producer.marker)' names nothing in the seed"
                continue
            }
            $page = Join-Path $exported ([string]$producer.page)
            if (-not (Test-Path -LiteralPath $page -PathType Leaf)) {
                $findings += "$($producer.page): the exporter wrote no page for this producer"
                continue
            }
            $html = [IO.File]::ReadAllText($page)
            foreach ($required in @('<!doctype html>', '<html lang="', '<meta charset="utf-8">', '<title>', '<h1>')) {
                if (-not $html.Contains($required)) {
                    $findings += "$($producer.page): the emitted document has no '$required'"
                }
            }
            # And that it is THIS seed's document. Checking only for a valid
            # shape would accept an exporter that had stopped reading the seed
            # and started writing a page of its own.
            $seedText = ($seed -replace "`r`n", "`n")
            $sample = @($html -split "`n" | Where-Object { $_ -match '<(h1|title)>' } |
                ForEach-Object { ($_ -replace '<[^>]+>', '').Trim() } | Where-Object { $_ })
            if ($sample.Count -eq 0) {
                $findings += "$($producer.page): the emitted document carries no heading to trace to its seed"
            }
            foreach ($phrase in $sample) {
                if (-not $seedText.Contains($phrase)) {
                    $findings += "$($producer.page): '$phrase' is not in $($producer.path), so the page is not this seed's"
                }
            }
        }
        Assert-NoFinding $findings 'a provisioned page is registered but not a valid document'
    }

    It 'names pages that exist and load something' {
        $findings = @()
        foreach ($page in $script:Registry.pages) {
            $path = Join-Path $script:RepoRoot ([string]$page.path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $findings += "$($page.path): the registry names a page that is not in the tree"
                continue
            }
            $html = [IO.File]::ReadAllText($path)
            if ($html -notmatch '<script') { $findings += "$($page.path): loads no script, so it measures nothing" }
        }
        Assert-NoFinding $findings 'the page list does not describe the shipped pages'
    }

    It 'gives every tracked page exactly one performance disposition' {
        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files --cached --others --exclude-standard -- '*.html') } finally { Pop-Location }
        $tracked = @($tracked | Where-Object {
                $_ -notlike 'dev-only/*' -and $_ -notlike 'docs/*'
            } | Sort-Object -Unique)
        $registered = @($script:Registry.pages | ForEach-Object { [string]$_.path })
        $findings = @()
        foreach ($page in $tracked) {
            $count = @($registered | Where-Object { $_ -ceq $page }).Count
            if ($count -ne 1) { $findings += "$page has $count performance dispositions, expected one" }
        }
        foreach ($page in $registered) {
            if ($tracked -notcontains $page) { $findings += "$page has a disposition but is not a tracked page" }
        }
        Assert-Equal -Expected 17 -Actual $tracked.Count `
            'the current shipped HTML census changed; classify the new surface deliberately'
        Assert-NoFinding $findings 'the performance manifest can become incomplete without failing'
    }
}

Describe 'a gate that cannot run is not reported as passing' {

    It 'names every tool a gate depends on, and what goes unchecked without it' {
        $result = Invoke-Gate -Script 'tools/Invoke-Preflight.ps1'
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a tool this project cannot be checked without is missing:`n$($result.Output)"
        # Each row has to say which gate needs it. A preflight that only
        # answered present/absent would tell an operator nothing about what a
        # missing tool costs them.
        foreach ($tool in @('pwsh', 'git', 'Pester', 'PSScriptAnalyzer', 'powershell-yaml',
                'go', 'node', 'shellcheck', 'chrome')) {
            Assert-True ($result.Output -match [regex]::Escape($tool)) "the preflight does not report on $tool"
        }
    }

    It 'refuses in release mode what it merely notes on a workstation' {
        # The distinction that matters. A missing browser on a laptop is an
        # inconvenience; in a run that speaks for the project it means a gate
        # was skipped, and a skipped gate reported green is a claim nobody
        # checked. This asserts the two modes actually differ -- if every tool
        # is present the run is green either way, which is also correct.
        $dev = Invoke-Gate -Script 'tools/Invoke-Preflight.ps1' -Arguments @('-Quiet')
        $release = Invoke-Gate -Script 'tools/Invoke-Preflight.ps1' -Arguments @('-Release', '-Quiet')

        Assert-Equal -Expected 0 -Actual $dev.Code 'the developer preflight should pass on a machine that can build'
        # Case-SENSITIVE, and anchored to a row. The summary line always ends
        # '<n> degraded.', and PowerShell's -match ignores case, so a plain match
        # takes the degraded branch on every host -- including a fully
        # provisioned one, where it then asserts that a green release run failed.
        if ($dev.Output -cmatch '(?m)^DEGRADED\s') {
            Assert-Equal -Expected 1 -Actual $release.Code `
                'a degraded row must block a release run, or "skipped" is being counted as green'
            Assert-True ($release.Output -match 'MISSING') 'the release run does not name the row it blocked on'
        } else {
            Assert-Equal -Expected 0 -Actual $release.Code `
                'nothing is degraded, so the release run should pass too'
        }
    }

    It 'fails release mode when a required prerequisite is taken away' {
        # The test above only compares the two modes as this host happens to be
        # provisioned; on a complete machine it takes the green branch and the
        # blocking behavior is never exercised at all. This removes a
        # prerequisite deliberately, which is the only way to show that a
        # missing tool blocks a release rather than being noted and passed over.
        #
        # PATH is narrowed rather than a tool deleted: the run must find pwsh
        # itself, and nothing outside this child process is disturbed.
        $pwshDirectory = Split-Path -Parent (Get-Process -Id $PID).Path
        $narrowed = if ($IsWindows) {
            @($pwshDirectory, "$env:SystemRoot\System32") -join ';'
        } else {
            @($pwshDirectory, '/usr/bin', '/bin') -join ':'
        }
        $preflight = Join-Path $script:RepoRoot 'tools/Invoke-Preflight.ps1'

        $priorPath = $env:PATH
        try {
            $env:PATH = $narrowed
            $output = & (Get-Process -Id $PID).Path -NoProfile -File $preflight -Release 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $env:PATH = $priorPath
        }

        # If the narrowed PATH still reaches every tool -- a host that installs
        # them all under /usr/bin -- there is nothing to have blocked on, and
        # asserting a failure would be asserting the shape of this machine.
        if ($output -cmatch '(?m)^MISSING\s') {
            Assert-Equal -Expected 1 -Actual $code `
                'a prerequisite the release cannot reach must block the run, not be noted and passed over'
            Assert-Match 'blocking' $output `
                'the run must say how many rows blocked it, not only that something was missing'
        } else {
            Set-ItResult -Skipped -Because 'every required tool is reachable even from a narrowed PATH here'
        }
    }
}

Describe 'the shipped surface stays inside its budget' {

    It 'has a recorded baseline' {
        $path = Join-Path $script:RepoRoot 'globalization/perf-baseline.json'
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'there is no checked performance baseline, so no byte or request growth can be noticed'
        $baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path))
        Assert-True ($baseline.assets.PSObject.Properties.Name.Count -ge 10) `
            'the baseline records too few assets to describe the shipped surface'
        Assert-Equal -Expected 17 -Actual $baseline.pages.PSObject.Properties.Name.Count `
            'each tracked page needs a budget row or an explicit exclusion'
        foreach ($asset in $baseline.assets.PSObject.Properties) {
            Assert-StringEqual -Expected 'deterministic-gzip-estimate' `
                -Actual $asset.Value.transferDisposition `
                "$($asset.Name) silently treats estimated gzip bytes as observed transport"
        }
        foreach ($page in $baseline.pages.PSObject.Properties) {
            Assert-StringEqual -Expected 'budgeted' -Actual $page.Value.disposition `
                "$($page.Name) has no explicit performance disposition"
        }
        Assert-StringEqual -Expected 'yuruna.perf-baseline/v2' -Actual $baseline.schema `
            'the baseline does not carry executable scenario budgets'
        foreach ($scenario in @('browserFloorColdFirstUsable', 'browserCapabilityOffFirstUsable',
                'browserSteadyRender', 'powershellCli', 'transcriptThroughput', 'goService', 'httpLatency')) {
            Assert-True ($baseline.executableBudgets.PSObject.Properties.Name -contains $scenario) `
                "the provisional executable budget '$scenario' is absent"
            $budget = $baseline.executableBudgets.$scenario
            Assert-True ([int]$budget.samples -ge $(if ($scenario -eq 'browserFloorColdFirstUsable') { 30 } else { 100 })) `
                "$scenario has too few samples for its declared statistic"
            Assert-True ([double]$budget.relativePercent -gt 0) "$scenario has no relative ceiling"
            Assert-True (@($budget.PSObject.Properties.Name | Where-Object {
                        $_ -like 'absoluteTolerance*'
                    }).Count -gt 0) "$scenario has no absolute-noise disposition"
        }
    }

    It 'measures within the declared tolerances' {
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' -Arguments @('-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "the shipped surface is outside its recorded budget:`n$($result.Output)"
    }

    It 'keeps the default path free of an extra request for its language' {
        # The reason the kernel and the default locale are compiled into the
        # runtime rather than fetched: a label that arrives after the paint it
        # belonged to is a flash of nothing, and on the floor browser that flash
        # is most of the load.
        $baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $script:RepoRoot 'globalization/perf-baseline.json')))
        $findings = @()
        foreach ($p in $baseline.pages.PSObject.Properties) {
            $html = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $p.Name))
            foreach ($m in [regex]::Matches($html, '<script\b[^>]*\bsrc\s*=\s*["'']([^"'']+)["'']', 'IgnoreCase')) {
                if ($m.Groups[1].Value -match 'en-US\.|locale|catalog') {
                    $findings += "$($p.Name) fetches $($m.Groups[1].Value) for its default language"
                }
            }
        }
        Assert-NoFinding $findings 'a page spends a request on the language it already carries'
    }

    It 'fails when a tracked page loses its disposition' {
        $copy = Join-Path $TestDrive 'browser-sources-with-gap.json'
        $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:RegistryPath))
        $registry.pages = @($registry.pages | Select-Object -Skip 1)
        [IO.File]::WriteAllText($copy, (ConvertTo-Json -InputObject $registry -Depth 12))
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' `
            -Arguments @('-Quiet', '-RegistryPath', $copy)
        Assert-Equal -Expected 1 -Actual $result.Code `
            'removing a page row made the measured surface smaller and still passed'
        Assert-True ($result.Output -match 'unregistered|incomplete') `
            "the failure does not name the manifest gap:`n$($result.Output)"
    }

    It 'fails when a shipped asset has no budget' {
        $copy = Join-Path $TestDrive 'perf-with-gap.json'
        $baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $script:RepoRoot 'globalization/perf-baseline.json')))
        $first = $baseline.assets.PSObject.Properties.Name | Select-Object -First 1
        $baseline.assets.PSObject.Properties.Remove($first)
        [IO.File]::WriteAllText($copy, (ConvertTo-Json -InputObject $baseline -Depth 12))
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' `
            -Arguments @('-Quiet', '-BaselinePath', $copy)
        Assert-Equal -Expected 1 -Actual $result.Code 'an unbudgeted asset must fail, not print NEW and pass'
        Assert-True ($result.Output -match 'unbudgeted') `
            "the failure does not identify the missing budget:`n$($result.Output)"
    }

    It 'fails when a recorded size or page disposition is erased' {
        $copy = Join-Path $TestDrive 'perf-without-dispositions.json'
        $baseline = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $script:RepoRoot 'globalization/perf-baseline.json')))
        $asset = $baseline.assets.PSObject.Properties | Select-Object -First 1
        $page = $baseline.pages.PSObject.Properties | Select-Object -First 1
        $asset.Value.PSObject.Properties.Remove('transferDisposition')
        $page.Value.PSObject.Properties.Remove('disposition')
        [IO.File]::WriteAllText($copy, (ConvertTo-Json -InputObject $baseline -Depth 12))
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' `
            -Arguments @('-Quiet', '-BaselinePath', $copy)
        Assert-Equal -Expected 1 -Actual $result.Code `
            'an unclassified page or transfer estimate must not remain release-authoritative'
        Assert-True ($result.Output -match 'transfer-size disposition') `
            "the missing transfer-size classification is not named:`n$($result.Output)"
        Assert-True ($result.Output -match 'page performance disposition') `
            "the missing page classification is not named:`n$($result.Output)"
    }

    It 'fails highly compressible inline page growth on raw bytes' {
        $fixture = New-PerfFixture
        $page = Join-Path $fixture.Root 'site/index.html'
        [IO.File]::AppendAllText($page, '<script>/*' + ('a' * 4096) + '*/</script>')
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' -Arguments @(
            '-Root', $fixture.Root, '-RegistryPath', $fixture.Registry,
            '-BaselinePath', $fixture.Baseline, '-Quiet')
        Assert-Equal -Expected 1 -Actual $result.Code `
            'large raw inline growth compressed away and escaped the page budget'
        Assert-Match -Pattern 'site/index\.html raw' -Actual $result.Output
        Assert-False ($result.Output -match 'site/index\.html gzip') `
            'the fixture no longer isolates the raw-byte ceiling from gzip growth'
    }

    It 'discovers an untracked candidate page before commit' {
        $fixture = New-PerfFixture
        [IO.File]::WriteAllText((Join-Path $fixture.Root 'site/new.html'),
            '<!doctype html><script>var candidate = true;</script>')
        $result = Invoke-Gate -Script 'tools/Invoke-PerfBaseline.ps1' -Arguments @(
            '-Root', $fixture.Root, '-RegistryPath', $fixture.Registry,
            '-BaselinePath', $fixture.Baseline, '-Quiet')
        Assert-Equal -Expected 1 -Actual $result.Code `
            'an untracked candidate page was invisible until commit'
        Assert-Match -Pattern 'unregistered: site/new\.html' -Actual $result.Output
    }
}

Describe 'generated pages substitute only the request seam' {

    It 'does not install a positive fetch global' {
        $exporter = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools/Export-GeneratedPages.ps1'))
        Assert-False ($exporter -match 'window\.fetch\s*=\s*function') `
            'the fixture masks capability-off behavior by supplying fetch'
        Assert-True ($exporter -match 'window\.yurunaRequest\s*=\s*function') `
            'the fixture no longer injects data behind the canonical request seam'
    }

    It 'keeps the production adapter visible in every exported Go page' {
        $output = Join-Path $TestDrive 'generated-pages'
        $result = & pwsh -NoProfile -File (Join-Path $script:RepoRoot 'tools/Export-GeneratedPages.ps1') `
            -OutputDirectory $output -Quiet 2>&1 | Out-String
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because $result
        foreach ($name in @('caching-proxy-ui.html', 'caching-proxy-parser-ui.html',
                'caching-proxy-ui-failed.html', 'caching-proxy-parser-ui-failed.html')) {
            $html = [IO.File]::ReadAllText((Join-Path $output $name))
            Assert-Equal -Expected 1 -Actual ([regex]::Matches($html,
                    'window\.fetch\s*=\s*function').Count) `
                "$name must contain only the production adapter's conditional fetch stand-in"
            Assert-Equal -Expected 2 -Actual ([regex]::Matches($html,
                    'window\.yurunaRequest\s*=\s*function').Count) `
                "$name needs the real adapter followed by one fixture transport"
        }
    }
}

Describe 'the publisher validates the artifacts it is about to publish' {

    It 'exposes changed-domain, full, and release orchestration modes' {
        $gate = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'tools/Invoke-CrossRepoGate.ps1'))
        foreach ($mode in @('changed-domain', 'full', 'release')) {
            Assert-True ($gate.IndexOf("'$mode'", [StringComparison]::Ordinal) -ge 0) `
                "the orchestrator has no $mode mode"
        }
        foreach ($required in @("Name = 'preflight'", "Name = 'js-test'", "Name = 'go-build'",
                "Name = 'globalization-authority'", "Name = 'framework-lint'",
                "Name = 'framework-shellcheck'", "Name = 'ascii-no-bom'",
                "Name = 'accessibility'", "Name = 'terminology'",
                "Name = 'suite-baseline'", "Name = 'config-locale-seed'",
                'Invoke-AffectedSliceMap.ps1',
                'Test.DocReachability.Tests.ps1', 'Test.StatusServiceLocale.Tests.ps1',
                'Test.StatusPauseSlice.Tests.ps1', 'Test.PoolGlobalizationSlice.Tests.ps1',
                'Test.ReferenceSliceMatrix.Tests.ps1', 'Test.CodeRegistry.Tests.ps1',
                'Get-EngineeringOpenRow')) {
            Assert-True ($gate.IndexOf($required, [StringComparison]::Ordinal) -ge 0) `
                "full/release mode omits $required"
        }
        # The repair line for the suite-baseline row names the runner, because a
        # repair line that cannot name its command is not a repair. What must
        # not happen is this orchestrator RUNNING the suite: one full run would
        # become several, and a gate meant to answer in seconds would take
        # minutes. So the guard covers everything the file executes and skips
        # the text it only prints.
        $executable = $gate.Replace((Get-CrossRepoFunction -Name 'Get-GateRemediation'), '')
        Assert-True ($executable.Length -lt $gate.Length) `
            'the remediation table was not found, so this guard is checking nothing'
        Assert-False ($executable -match 'Invoke-TestSuite') `
            'the cross-repository gate recursively launches the full suite instead of named leaf checks'
        Assert-True ($gate.IndexOf('Invoke-ProjectLocaleMap.ps1', [StringComparison]::Ordinal) -ge 0) `
            'the cross-repository path does not use the authoritative parsed project-map contract'
        Assert-False ($gate -match 'Localized:\\s\*\\n') `
            'a source regex is still competing with the parsed project-map contract'
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($gate,
                'elseif \(-not \(Get-Module -ListAvailable PSScriptAnalyzer\)\)').Count) `
            'duplicate analyzer-unavailable branches can suppress the required cannot-run row'
    }

    It 'selects untracked project scripts but not ignored output before commit' {
        $function = Get-CrossRepoFunction -Name 'Get-GitCandidatePath'
        Assert-True ([bool]$function) 'the orchestrator has no shared candidate-file selector'
        $select = [scriptblock]::Create($function +
            "`nGet-GitCandidatePath -Root `$args[0] -Include `$args[1]")
        $root = Join-Path $TestDrive 'project-script-candidate'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & git -C $root init --quiet
        [IO.File]::WriteAllText((Join-Path $root '.gitignore'), "ignored.ps1`n")
        [IO.File]::WriteAllText((Join-Path $root 'candidate.ps1'), "Write-Output 'candidate'`n")
        [IO.File]::WriteAllText((Join-Path $root 'candidate.sh'), "#!/bin/sh`nexit 0`n")
        [IO.File]::WriteAllText((Join-Path $root 'ignored.ps1'), "Write-Output 'generated'`n")
        $powershell = @(& $select $root @('*.ps1', '*.psm1'))
        $shell = @(& $select $root @('*.sh'))
        Assert-Equal -Expected 1 -Actual $powershell.Count `
            'the project lint selector omitted an untracked candidate or included ignored output'
        Assert-StringEqual -Expected 'candidate.ps1' -Actual $powershell[0]
        Assert-Equal -Expected 1 -Actual $shell.Count `
            'the shellcheck selector omitted an untracked candidate'
        Assert-StringEqual -Expected 'candidate.sh' -Actual $shell[0]
    }

    It 'derives seed and W2 readiness only from checked rows and affected-slice evidence' {
        $function = Get-CrossRepoFunction -Name 'Get-EngineeringOpenRow'
        Assert-True ([bool]$function) 'the orchestrator has no mechanical engineering-open aggregate'
        $derive = [scriptblock]::Create($function +
            "`nGet-EngineeringOpenRow -GateRows `$args[0] -SliceEvidence `$args[1]")
        $common = @(
            'doc-translation', 'region-anchors', 'project-lint', 'project-shellcheck',
            'project-locale-map', 'project-utf8', 'affected-slice-map', 'preflight',
            'framework-lint', 'framework-shellcheck', 'ascii-no-bom',
            'suite-baseline', 'config-locale-seed',
            'domain-inventory', 'catalog-compile', 'catalog-embed', 'utf8-catalog',
            'globalization-authority', 'terminology', 'es5-floor', 'palette-fallback',
            'perf-baseline', 'js-test', 'go-build', 'accessibility',
            'doc-reachability', 'code-registry-contract', 'reference-slice-matrix',
            'status-slice-matrix', 'pool-slice-matrix'
        )
        $rows = @($common | ForEach-Object {
                [pscustomobject]@{ Gate = $_; State = 'pass'; Detail = '' }
            })
        $evidence = [pscustomobject]@{
            slices = @(
                [pscustomobject]@{ id = 'status-pause-generated'; seedOpen = $true; openBlockers = @() }
                [pscustomobject]@{ id = 'pool-repository-project'; seedOpen = $true; openBlockers = @() }
            )
            summary = [pscustomobject]@{ openBlockerCount = 0 }
        }

        $green = @(& $derive $rows $evidence)
        Assert-Equal -Expected 3 -Actual $green.Count 'the aggregate does not emit both seeds and W2-OPEN'
        Assert-True (@($green | Where-Object State -NE 'pass').Count -eq 0) `
            'fully green checked evidence did not open both continuations'

        $withoutLint = @($rows | Where-Object Gate -NE 'framework-lint')
        $missing = @(& $derive $withoutLint $evidence)
        Assert-True (@($missing | Where-Object State -NE 'cannot-run').Count -eq 0) `
            'deleting a required common leaf did not close both seeds and W2-OPEN'

        $registryFailed = @($rows | ForEach-Object {
                [pscustomobject]@{
                    Gate = $_.Gate
                    State = if ($_.Gate -eq 'code-registry-contract') { 'fail' } else { $_.State }
                    Detail = $_.Detail
                }
            })
        $closedByRegistry = @(& $derive $registryFailed $evidence)
        Assert-True (@($closedByRegistry | Where-Object State -NE 'fail').Count -eq 0) `
            'a failing code-registry contract did not close both seeds and W2-OPEN'

        $evidence.slices[0].seedOpen = $false
        $evidence.slices[0].openBlockers = @('P-01')
        $blocked = @(& $derive $rows $evidence)
        Assert-StringEqual -Expected 'fail' -Actual `
            ($blocked | Where-Object Gate -EQ 'SEED-OPEN(status)').State `
            'a reachable status blocker did not close the status seed'
        Assert-StringEqual -Expected 'pass' -Actual `
            ($blocked | Where-Object Gate -EQ 'SEED-OPEN(pool)').State `
            'a status-only blocker incorrectly closed the pool seed'
        Assert-StringEqual -Expected 'fail' -Actual ($blocked | Where-Object Gate -EQ 'W2-OPEN').State `
            'one closed seed did not close W2-OPEN'
    }

    It 'rejects a mismatched pair and records what it actually checked' {
        $project = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
        $linkMap = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna.link/yuruna.link.json'
        if (-not (Test-Path -LiteralPath $project -PathType Container) -or
            -not (Test-Path -LiteralPath $linkMap -PathType Leaf)) {
            Set-ItResult -Skipped -Because 'the project and link-map support checkouts are not beside this tree'
            return
        }
        $evidence = Join-Path $TestDrive 'cross-repo-evidence.json'
        $result = Invoke-Gate -Script 'tools/Invoke-CrossRepoGate.ps1' -Arguments @(
            '-Release', '-ProjectRoot', $project, '-LinkMap', $linkMap,
            '-FrameworkTreeHash', ('0' * 40), '-ProjectTreeHash', ('0' * 40),
            '-EvidencePath', $evidence, '-Quiet')
        Assert-Equal -Expected 1 -Actual $result.Code 'a release result was not bound to its staged trees'
        Assert-True (Test-Path -LiteralPath $evidence -PathType Leaf) 'the failed pair wrote no evidence'
        $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($evidence))
        Assert-StringEqual -Expected 'yuruna.cross-repo-gate/v1' -Actual $doc.schema 'the evidence schema changed'
        Assert-StringEqual -Expected 'release' -Actual $doc.mode 'the evidence does not name its orchestration mode'
        Assert-True ([bool]$doc.frameworkTree -and [bool]$doc.projectTree) `
            'the evidence does not name both actual staged hashes'
        foreach ($gate in @('staged-framework-hash', 'staged-project-hash')) {
            $row = $doc.rows | Where-Object gate -EQ $gate
            Assert-StringEqual -Expected 'fail' -Actual $row.state "$gate did not reject the mismatch"
        }
        $deferred = $doc.rows | Where-Object gate -EQ 'framework-gate-set'
        Assert-StringEqual -Expected 'not-applicable' -Actual $deferred.state `
            'an invalid tree pair did not stop before expensive framework leaves'
        Assert-False ([bool]($doc.rows | Where-Object gate -EQ 'accessibility')) `
            'the bad-hash mutation launched the browser matrix before rejecting its candidate'
    }
}

Describe 'the generated artifacts match their sources' {

    It 'keeps every boundary consumer mapped to an owned affected slice' {
        $result = Invoke-Gate -Script 'tools/Invoke-AffectedSliceMap.ps1' `
            -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "the affected-slice evidence is stale or has an unmapped blocker:`n$($result.Output)"
    }

    It 'holds converted literals and machine boundaries to their ratchets' {
        $result = Invoke-Gate -Script 'tools/Test-GlobalizationAuthority.ps1' -Arguments @('-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "converted prose or a message-shaped protocol escaped its gate:`n$($result.Output)"
    }

    It 'reports the compiled catalogs as current' {
        $result = Invoke-Gate -Script 'tools/Invoke-CatalogCompile.ps1' -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "run tools/Invoke-CatalogCompile.ps1 -Update:`n$($result.Output)"
    }

    It 'reports every runtime copy as current' {
        # Browser runtimes and Go modules both carry copies of what the compiler
        # produced. A copy diverges the moment someone edits the near one.
        $result = Invoke-Gate -Script 'tools/Invoke-CatalogEmbed.ps1' -Arguments @('-Check', '-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "run tools/Invoke-CatalogEmbed.ps1:`n$($result.Output)"
    }

    It 'reports the translated documents as undrifted' {
        # This gate had no automated caller: the project's own gate table listed
        # it while nothing ran it, so a commit that edited an English source
        # left every check green and the drift was caught only when a person
        # remembered to type the command.
        #
        # Exit 2 is "could not run" -- the sibling checkout is absent -- which
        # is not a drift finding and must not be reported as one.
        $result = Invoke-Gate -Script 'tools/Test-DocTranslation.ps1' -Arguments @('-Quiet')
        if ($result.Code -eq 2) {
            Set-ItResult -Skipped -Because 'the yuruna-project checkout this gate reads is not beside this one'
            return
        }
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a translated document has drifted from the English it was translated from:`n$($result.Output)"
    }

    It 'runs the gates that reach the project repository' {
        # Every gate in this tree stops at its own edge, and a lab runs a
        # framework and a project from two repositories on two release
        # cadences. Nothing checked the project except the documentation tools
        # that already crossed the boundary.
        #
        # Exit 2 is "a gate could not run" -- no project checkout, or a missing
        # tool -- which is not a pass and must not be reported as one.
        $result = Invoke-Gate -Script 'tools/Invoke-CrossRepoGate.ps1' -Arguments @('-Quiet')
        if ($result.Code -eq 2) {
            Set-ItResult -Skipped -Because 'a cross-repository gate could not run on this host'
            return
        }
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a gate failed against the project repository:`n$($result.Output)"
    }

    It 'says which gates in this tree do not reach the project' {
        # The honest half. A gate that cannot reach the project is not a gate
        # the project passes, and reporting it as N/A with a reason is the
        # difference between coverage and the appearance of it.
        $result = Invoke-Gate -Script 'tools/Invoke-CrossRepoGate.ps1'
        if ($result.Code -eq 2) {
            Set-ItResult -Skipped -Because 'a cross-repository gate could not run on this host'
            return
        }
        foreach ($gate in @('es5-floor', 'palette-fallback', 'catalog-compile', 'perf-baseline', 'go-build')) {
            Assert-True ($result.Output -match [regex]::Escape($gate)) "the report does not mention $gate at all"
        }
        Assert-True ($result.Output -match 'not-applicable') `
            'nothing is reported as inapplicable, which would mean every gate reaches a repository it cannot see'
    }

    It 'holds every browser source to the floor' {
        $result = Invoke-Gate -Script 'tools/Invoke-Es5Check.ps1' -Arguments @('-Quiet')
        Assert-Equal -Expected 0 -Actual $result.Code `
            "a shipped browser source is outside the floor:`n$($result.Output)"
    }
}

Describe 'the generated catalogs are lintable, with one bounded exception' {

    It 'bounds whole-repository lint classification to the generated PSD1 BOM conflict' {
        $function = Get-LintFunction -Name 'Test-IsGeneratedCatalogBomConflict'
        Assert-True ([bool]$function) 'whole-repository lint does not classify the deliberate BOM conflict'
        $classify = [scriptblock]::Create($function +
            "`nTest-IsGeneratedCatalogBomConflict -RelativePath `$args[0] -RuleName `$args[1]")
        Assert-True ([bool](& $classify 'globalization/generated/powershell/qps-Ploc.status.psd1' `
                'PSUseBOMForUnicodeEncodedFile')) `
            'the exact generated no-BOM conflict still blocks whole-repository lint'
        Assert-False ([bool](& $classify 'test/modules/handwritten.psd1' 'PSUseBOMForUnicodeEncodedFile')) `
            'a handwritten Unicode file escaped the BOM rule'
        Assert-False ([bool](& $classify 'globalization/generated/powershell/qps-Ploc.status.psd1' `
                'PSUseOutputTypeCorrectly')) `
            'the path exception swallowed an unrelated analyzer finding'
        Assert-False ([bool](& $classify 'globalization/generated/powershell/nested/qps-Ploc.status.psd1' `
                'PSUseBOMForUnicodeEncodedFile')) `
            'the generated-output exception expanded into an unreviewed subtree'
    }

    It 'produces nothing the analyzer objects to except the BOM it cannot have' {
        # PSUseBOMForUnicodeEncodedFile wants a byte-order mark on the mirrored
        # pseudo catalog, which carries non-ASCII text. This project will not
        # write one: a BOM is invisible in every editor, rides into hashes, and
        # breaks byte-for-byte consumers -- and the drift check for these very
        # files compares their bytes. The renderer that reads them requires
        # PowerShell 7, which decodes UTF-8 without a mark correctly, so the
        # condition the rule protects against does not arise here.
        #
        # The exception is bounded rather than waved through: any OTHER analyzer
        # finding in generated output is a real defect in the emitter, and this
        # is what would notice one.
        $generated = Join-Path $script:RepoRoot 'globalization/generated/powershell'
        $files = @(Get-ChildItem -LiteralPath $generated -File -Filter '*.psd1')
        Assert-True ($files.Count -ge 3) 'the generated catalogs are missing, so this checks nothing'

        $settings = Join-Path $script:RepoRoot 'PSScriptAnalyzerSettings.psd1'
        $findings = @()
        foreach ($file in $files) {
            foreach ($r in @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settings)) {
                if ($r.RuleName -eq 'PSUseBOMForUnicodeEncodedFile') { continue }
                $findings += "$($file.Name):$($r.Line) $($r.RuleName) -- $($r.Message)"
            }
        }
        Assert-NoFinding $findings 'the catalog emitter produces PowerShell the analyzer objects to'
    }

    It 'writes no byte-order mark, which is what the byte comparison depends on' {
        $generated = Join-Path $script:RepoRoot 'globalization/generated/powershell'
        $findings = @()
        foreach ($file in (Get-ChildItem -LiteralPath $generated -File -Filter '*.psd1')) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $findings += "$($file.Name) starts with a byte-order mark"
            }
        }
        Assert-NoFinding $findings 'a mark here would change the bytes the staleness check compares'
    }
}

Describe 'the Go services carry what the catalog compiled' {

    It 'gives every Go consumer a module-local copy' {
        # Go cannot import across a module boundary the service does not own, so
        # a service that has no copy beside it has no catalog at all.
        $consumers = @('test/extension/pool-control-service/server/internal/catalog')
        $findings = @()
        foreach ($dir in $consumers) {
            $full = Join-Path $script:RepoRoot $dir
            if (-not (Test-Path -LiteralPath $full -PathType Container)) {
                $findings += "$dir does not exist, so that service embeds no catalog"
                continue
            }
            $files = @(Get-ChildItem -LiteralPath $full -File -Filter '*.go')
            if ($files.Count -eq 0) { $findings += "$dir carries no compiled catalog" }
            foreach ($f in $files) {
                $text = [IO.File]::ReadAllText($f.FullName)
                if ($text -notmatch '(?m)^package\s+catalog$') {
                    $findings += "$dir/$($f.Name) is not in the package its directory names"
                }
            }
        }
        Assert-NoFinding $findings 'a Go service cannot reach the catalog it is supposed to render'
    }

    It 'gives the shared SDK the locale table' {
        $path = Join-Path $script:RepoRoot 'test/extension/extension-sdk/i18n/localedata.go'
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'the Go SDK has no generated locale table, so it would have to consult its own locale database'
        $text = [IO.File]::ReadAllText($path)
        foreach ($symbol in @('generatedLocaleData', 'generatedSupported', 'generatedPseudo', 'generatedAliases')) {
            Assert-True ($text -match [regex]::Escape($symbol)) "the generated locale table has no $symbol"
        }
    }
}
