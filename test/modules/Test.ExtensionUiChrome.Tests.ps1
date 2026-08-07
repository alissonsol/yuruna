<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7adb1-b8f1-48fe-a89b-2b2d8acb1dc6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension ui chrome header menu pester
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
    Guards the shared page chrome of the Yuruna web UIs -- the three extension
    services (pool control, stash, download agent) and the host status pages:
    one identical stylesheet block, one header shape, one menu, and page-first
    document titles.
.DESCRIPTION
    The three daemons each //go:embed their own web/ directory and the status
    pages are served straight off disk, so the chrome cannot live in one file
    -- it is copied into four stylesheets and fifteen pages. Copies drift
    silently: a white header on one service, a nav list on another, a title
    that starts with the service name so every browser tab reads the same.
    These tests pin the parts that must not diverge:

      - the PAGE CHROME block of every stylesheet is byte-identical;
      - --chrome-bg is dark in both colour schemes, i.e. the header really is
        black everywhere rather than only where someone remembered;
      - every page carries the same header elements and the same menu control,
        with the current page marked exactly once;
      - every service title reads "<Page> - <Service>", never the reverse.

    A root font-size is checked too: every rem in the chrome resolves against
    the root, so a stylesheet that puts its base size on `html` instead of
    `body` renders the same bar a few percent smaller than its siblings.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, and every fixture is read at file scope above the first
    Describe, so this runs under Pester 4.10.1 as well as 5.x (Pester 5's scope
    split hides both top-level helpers and Describe-body variables from It).
#>

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)
$ext = Join-Path $repo 'test/extension'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-NoFinding {
    param([string[]]$Findings, [string]$Because = '')
    if ($Findings.Count -gt 0) { throw ("$Because`n  " + ($Findings -join "`n  ")) }
}

function Get-RelLuminance([string]$hex) {
    $hex = $hex.TrimStart('#')
    $chan = @(0, 2, 4) | ForEach-Object {
        $c = [Convert]::ToInt32($hex.Substring($_, 2), 16) / 255
        if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $chan[0] + 0.7152 * $chan[1] + 0.0722 * $chan[2]
}

# Every page of every extension UI, with the page name its <title> must lead
# with and the menu entry it must mark as current. An empty Current means the
# page is not itself a menu entry (the stash detail view lives under /s/<id>),
# so it marks nothing.
$services = @(
    @{
        Name  = 'Yuruna Pool Control'
        Dir   = 'pool-control-service'
        Guide = 'https://yuruna.link/pool-control'
        Links = @('/', '/assign', '/hosts', '/pools', '/test-sets', '/diagnostics')
        Pages = @(
            @{ File = 'board.html'; Title = 'Board'; Current = '/' }
            @{ File = 'index.html'; Title = 'Assign'; Current = '/assign' }
            @{ File = 'hosts.html'; Title = 'Hosts'; Current = '/hosts' }
            @{ File = 'pools.html'; Title = 'Pools'; Current = '/pools' }
            @{ File = 'test-sets.html'; Title = 'Test sets'; Current = '/test-sets' }
            @{ File = 'diagnostics.html'; Title = 'Diagnostics'; Current = '/diagnostics' }
        )
    }
    @{
        Name  = 'Yuruna Stash'
        Dir   = 'stash-service'
        Guide = 'https://yuruna.link/stash-guide'
        Links = @('/', '/new')
        Pages = @(
            @{ File = 'index.html'; Title = 'Stashes'; Current = '/' }
            @{ File = 'new.html'; Title = 'New stash'; Current = '/new' }
            @{ File = 'stash.html'; Title = 'Stash'; Current = '' }
        )
    }
    @{
        Name  = 'Yuruna Download Agent'
        Dir   = 'download-agent-service'
        Guide = 'https://yuruna.link/download-agent'
        Links = @('/')
        Pages = @(
            @{ File = 'index.html'; Title = 'Download pool'; Current = '/' }
        )
    }
)

# Read at file scope, above the first Describe: a Describe body is evaluated
# during the discovery pass and its scope is discarded before any It runs, so a
# fixture declared inside one reaches the assertions as $null.
$chromePattern = '(?s)/\* =+\r?\n   PAGE CHROME.*?/\* === end page chrome =+ \*/'
$pages = @()
$stylesheets = @()
$scripts = @()

# The host status pages carry the same chrome from their own stylesheet. They
# are not part of $services: their titles follow a different convention and
# their brand link is a relative file name, so only the chrome-shaped
# assertions apply to them.
$statusDir = Join-Path $repo 'test/status'
$statusLinks = @('index.html', 'config.html', 'performance.html', 'diagnostics.html')
$statusGuide = 'https://yuruna.link/operator'
$statusPages = @(
    @{ File = 'index.html'; Current = 'index.html' }
    @{ File = 'config.html'; Current = 'config.html' }
    @{ File = 'performance.html'; Current = 'performance.html' }
    @{ File = 'diagnostics.html'; Current = 'diagnostics.html' }
    # Reached from the dashboard with one cycle in the query string, never from
    # the menu, so it carries the chrome but marks nothing current.
    @{ File = 'share-cycle.html'; Current = '' }
) | ForEach-Object {
    [pscustomobject]@{
        Id      = "status/$($_.File)"
        Current = $_.Current
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $statusDir $_.File))
    }
}

foreach ($svc in $services) {
    $web = Join-Path $ext (Join-Path $svc.Dir 'server/internal/httpsrv/web')
    $stylesheets += [pscustomobject]@{
        Service = $svc.Name
        Path    = (Join-Path $web 'assets/style.css')
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $web 'assets/style.css'))
    }
    $scripts += [pscustomobject]@{
        Service = $svc.Name
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $web 'assets/common.js'))
    }
    foreach ($p in $svc.Pages) {
        $pages += [pscustomobject]@{
            Service = $svc.Name
            Guide   = $svc.Guide
            Links   = $svc.Links
            Id      = "$($svc.Dir)/$($p.File)"
            Title   = $p.Title
            Current = $p.Current
            Text    = (Get-Content -Raw -LiteralPath (Join-Path $web $p.File))
        }
    }
}

# Every stylesheet that carries the chrome, including the status pages' own.
$chromeStylesheets = @($stylesheets) + @([pscustomobject]@{
        Service = 'Yuruna status pages'
        Path    = (Join-Path $statusDir 'yuruna.common.css')
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $statusDir 'yuruna.common.css'))
    })

Describe 'extension UI chrome: one header, one menu, page-first titles' {

    It 'ships an identical PAGE CHROME block in every stylesheet that carries it' {
        $blocks = foreach ($s in $chromeStylesheets) {
            $m = [regex]::Match($s.Text, $chromePattern)
            Assert-True $m.Success "$($s.Service) stylesheet has no PAGE CHROME block"
            [pscustomobject]@{ Service = $s.Service; Block = $m.Value }
        }
        $distinct = @($blocks.Block | Select-Object -Unique)
        Assert-Equal -Expected 1 -Actual $distinct.Count `
            -Because 'the chrome block is copied per UI because //go:embed cannot cross modules; the copies have drifted'
    }

    It 'leaves the root font size alone, so one rem is the same length in every UI' {
        # The chrome is sized entirely in rem, and rem resolves against the ROOT
        # element. A base `font: 15px/...` on `html` (rather than on `body`)
        # rescales the whole bar -- title, version, menu button, bar height --
        # by 15/16 in that UI alone, which reads as "this one looks different"
        # with no rule anywhere that says so.
        $findings = @()
        foreach ($s in $chromeStylesheets) {
            foreach ($m in [regex]::Matches($s.Text, '(?m)^\s*([^\r\n{}]*\bhtml\b[^\r\n{}]*)\{([^}]*)\}')) {
                $selector = $m.Groups[1].Value.Trim()
                $body = $m.Groups[2].Value
                if ($body -match '(?m)^\s*font(-size)?\s*:') {
                    $findings += "$($s.Service): '$selector' sets a font size on the root element"
                }
            }
        }
        Assert-NoFinding $findings 'a UI rescaled its own chrome by moving the base size onto html'
    }

    It 'keeps --chrome-bg dark in both colour schemes, so no header renders light' {
        $findings = @()
        foreach ($s in $chromeStylesheets) {
            $values = [regex]::Matches($s.Text, '--chrome-bg:\s*(#[0-9a-fA-F]{6})') | ForEach-Object { $_.Groups[1].Value }
            if ($values.Count -ne 2) {
                $findings += "$($s.Service): expected a light-scheme and a dark-scheme --chrome-bg, found $($values.Count)"
                continue
            }
            foreach ($v in $values) {
                $l = Get-RelLuminance $v
                # 0.05 relative luminance is roughly #3c3c3c -- comfortably above
                # any near-black and far below a light bar.
                if ($l -ge 0.05) { $findings += "$($s.Service): --chrome-bg $v has luminance $([Math]::Round($l,4)), not a black bar" }
            }
        }
        Assert-NoFinding $findings 'a service header stopped being black'
    }

    It 'titles every page "Page - Service", never service-first' {
        $findings = @()
        foreach ($p in $pages) {
            $m = [regex]::Match($p.Text, '<title>(.*?)</title>')
            if (-not $m.Success) { $findings += "$($p.Id): no <title>"; continue }
            $want = "$($p.Title) &mdash; $($p.Service)"
            if ($m.Groups[1].Value -ne $want) {
                $findings += "$($p.Id): title is '$($m.Groups[1].Value)', want '$want'"
            }
        }
        Assert-NoFinding $findings 'a tab strip full of these must stay tellable apart'
    }

    It 'carries the same header elements on every page' {
        $findings = @()
        foreach ($p in $pages) {
            foreach ($needle in @(
                    '<header class="app">',
                    "<span class=`"name`"><a href=`"/`">$($p.Service)</a></span>",
                    'id="header-version"',
                    'id="machine"',
                    'class="spacer"')) {
                if (-not $p.Text.Contains($needle)) { $findings += "$($p.Id): header is missing $needle" }
            }
        }
        Assert-NoFinding $findings 'the header shape is what makes the three services read as one product'
    }

    It 'carries the same menu, listing every page of its service plus the guide' {
        $findings = @()
        foreach ($p in $pages) {
            foreach ($needle in @('id="menu-button"', 'aria-haspopup="true"', 'id="menu-panel"', 'aria-expanded="false"')) {
                if (-not $p.Text.Contains($needle)) { $findings += "$($p.Id): menu is missing $needle" }
            }
            # The panel starts closed: without the attribute the links paint over
            # the page on load, and the toggle's first click would appear dead.
            if (-not [regex]::IsMatch($p.Text, 'id="menu-panel"[^>]*\shidden')) {
                $findings += "$($p.Id): menu panel is not hidden on load"
            }
            foreach ($href in $p.Links) {
                if (-not [regex]::IsMatch($p.Text, "<a href=`"$([regex]::Escape($href))`"[^>]*>")) {
                    $findings += "$($p.Id): menu does not link $href"
                }
            }
            # In the menu specifically, as the trailing outbound entry. A bare
            # "the URL appears somewhere on the page" test passed while the guide
            # was ALSO a footer link, so it could not have caught the menu entry
            # going missing.
            if (-not [regex]::IsMatch($p.Text, "<a class=`"menu-out`" href=`"$([regex]::Escape($p.Guide))`">")) {
                $findings += "$($p.Id): menu does not link the guide"
            }
        }
        Assert-NoFinding $findings 'the menu is the only way off a page now that the header nav is gone'
    }

    It 'keeps the guide out of the footer, so the menu is the only place it lives' {
        # Two links in one footer segment read as one control: the whole
        # "Refresh: 60s . guide" run looks clickable, and which part does what is
        # a guess. The menu already carries the guide on every page.
        $findings = @()
        foreach ($p in $pages) {
            $footer = [regex]::Match($p.Text, '(?s)<footer[^>]*>.*?</footer>')
            if (-not $footer.Success) { continue }
            if ($footer.Value -match '(?i)>\s*guide\s*<') { $findings += "$($p.Id): footer still carries a guide link" }
        }
        Assert-NoFinding $findings 'a second guide link duplicates the menu and blurs the refresh control'
    }

    It 'marks the current page exactly once in the menu' {
        $findings = @()
        foreach ($p in $pages) {
            $marked = [regex]::Matches($p.Text, '<a href="([^"]+)"\s+aria-current="page"')
            $want = if ($p.Current) { 1 } else { 0 }
            if ($marked.Count -ne $want) {
                $findings += "$($p.Id): $($marked.Count) menu entries marked current, want $want"
            } elseif ($p.Current -and $marked[0].Groups[1].Value -ne $p.Current) {
                $findings += "$($p.Id): marks $($marked[0].Groups[1].Value) current, want $($p.Current)"
            }
        }
        Assert-NoFinding $findings 'the tick is the only cue for where you are'
    }

    It 'sets viewport-fit=cover on every page, so the black bars honour the notch insets' {
        $findings = @()
        foreach ($p in $pages) {
            if (-not $p.Text.Contains('viewport-fit=cover')) { $findings += "$($p.Id): viewport meta lacks viewport-fit=cover" }
        }
        # Without it iOS Safari resolves every env(safe-area-inset-*) to 0, which
        # makes the chrome's inset padding inert and parks the footer bar under
        # the home indicator.
        Assert-NoFinding $findings 'the chrome pads itself with env(safe-area-inset-*), which needs this meta to be non-zero'
    }

    It 'wires the menu from every service common.js' {
        $findings = @()
        foreach ($s in $scripts) {
            if ($s.Text -notmatch 'initMenu') { $findings += "$($s.Service): common.js has no initMenu" }
        }
        Assert-NoFinding $findings 'static links still navigate, but the panel would never open'
    }
}

Describe 'host status pages carry the same chrome as the service UIs' {

    It 'carries the same header elements on every status page' {
        $findings = @()
        foreach ($p in $statusPages) {
            foreach ($needle in @(
                    '<header class="app">',
                    '<span class="name"><a href="index.html">',
                    'id="header-title"',
                    'id="header-version"',
                    'id="header-machine"',
                    'class="spacer"')) {
                if (-not $p.Text.Contains($needle)) { $findings += "$($p.Id): header is missing $needle" }
            }
        }
        Assert-NoFinding $findings 'the header shape is what makes the status pages and the services read as one product'
    }

    It 'carries the same menu, listing every status page plus the guide' {
        $findings = @()
        foreach ($p in $statusPages) {
            foreach ($needle in @('id="menu-button"', 'aria-haspopup="true"', 'id="menu-panel"', 'aria-expanded="false"')) {
                if (-not $p.Text.Contains($needle)) { $findings += "$($p.Id): menu is missing $needle" }
            }
            # The panel starts closed: without the attribute the links paint over
            # the page on load, and the toggle's first click would appear dead.
            if (-not [regex]::IsMatch($p.Text, 'id="menu-panel"[^>]*\shidden')) {
                $findings += "$($p.Id): menu panel is not hidden on load"
            }
            foreach ($href in $statusLinks) {
                if (-not [regex]::IsMatch($p.Text, "<a href=`"$([regex]::Escape($href))`"[^>]*>")) {
                    $findings += "$($p.Id): menu does not link $href"
                }
            }
            # In the menu specifically -- see the service-side twin of this test.
            if (-not [regex]::IsMatch($p.Text, "<a class=`"menu-out`" href=`"$([regex]::Escape($statusGuide))`">")) {
                $findings += "$($p.Id): menu does not link the guide"
            }
            $footer = [regex]::Match($p.Text, '(?s)<footer[^>]*>.*?</footer>')
            if ($footer.Success -and $footer.Value -match '(?i)>\s*guide\s*<') {
                $findings += "$($p.Id): footer still carries a guide link"
            }
        }
        Assert-NoFinding $findings 'the menu is the only way off a status page now that the header CTA is gone'
    }

    It 'marks the current status page exactly once in the menu' {
        $findings = @()
        foreach ($p in $statusPages) {
            $marked = [regex]::Matches($p.Text, '<a href="([^"]+)"\s+aria-current="page"')
            # An empty Current means the page is not itself a menu entry (the
            # share page is always about one named cycle), so it marks nothing.
            $want = if ($p.Current) { 1 } else { 0 }
            if ($marked.Count -ne $want) {
                $findings += "$($p.Id): $($marked.Count) menu entries marked current, want $want"
            } elseif ($p.Current -and $marked[0].Groups[1].Value -ne $p.Current) {
                $findings += "$($p.Id): marks $($marked[0].Groups[1].Value) current, want $($p.Current)"
            }
        }
        Assert-NoFinding $findings 'the tick is the only cue for where you are'
    }

    It 'keeps no per-page header CTA, so the menu is the single way to navigate' {
        $findings = @()
        foreach ($p in $statusPages) {
            if ($p.Text -match 'header-cta') { $findings += "$($p.Id): still carries a .header-cta" }
        }
        $js = Get-Content -Raw -LiteralPath (Join-Path $statusDir 'yuruna.common.js')
        if ($js -match 'header-cta') { $findings += 'yuruna.common.js still builds a .header-cta' }
        Assert-NoFinding $findings 'a page-specific CTA next to a standard menu is two ways to say the same thing'
    }

    It 'sets viewport-fit=cover on every status page' {
        $findings = @()
        foreach ($p in $statusPages) {
            if (-not $p.Text.Contains('viewport-fit=cover')) { $findings += "$($p.Id): viewport meta lacks viewport-fit=cover" }
        }
        Assert-NoFinding $findings 'the chrome pads itself with env(safe-area-inset-*), which needs this meta to be non-zero'
    }

    It 'wires the menu from yuruna.common.js' {
        $js = Get-Content -Raw -LiteralPath (Join-Path $statusDir 'yuruna.common.js')
        Assert-True ($js -match 'function initMenu') 'yuruna.common.js has no initMenu'
    }
}
