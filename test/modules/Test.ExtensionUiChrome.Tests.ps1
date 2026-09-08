<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42a98740-f91d-4449-a691-90bbcafc57af
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
      - --chrome-bg is dark in both color schemes, i.e. the header really is
        black everywhere rather than only where someone remembered;
      - every page carries the same header elements and the same menu control,
        with the current page marked exactly once;
      - every service title reads "<Page> - <Service>", never the reverse.

    A root font-size is checked too: every rem in the chrome resolves against
    the root, so a stylesheet that puts its base size on `html` instead of
    `body` renders the same bar a few percent smaller than its siblings.

    The throw-based Assert-* helpers and every fixture are built in BeforeAll,
    the only scope an It can read: Pester 5 runs file scope and Describe bodies
    during discovery, and nothing they define survives into the run phase.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)
$ext = Join-Path $repo 'test/extension'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

# Read in BeforeAll, not in a Describe body: a Describe body is evaluated during
# the discovery pass and its scope is discarded before any It runs, so a fixture
# declared inside one reaches the assertions as $null.
$script:chromePattern = '(?s)/\* =+\r?\n   PAGE CHROME.*?/\* === end page chrome =+ \*/'
$pages = @()
$stylesheets = @()
$scripts = @()

# The host status pages carry the same chrome from their own stylesheet. They
# are not part of $services: their titles follow a different convention and
# their brand link is a relative file name, so only the chrome-shaped
# assertions apply to them.
$statusDir = Join-Path $repo 'test/status'
$script:statusLinks = @('index.html', 'config.html', 'performance.html', 'diagnostics.html')
$script:statusGuide = 'https://yuruna.link/operator'
$script:statusPages = @(
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

# One copy for every service UI: //go:embed cannot cross a module, so the shared
# runtime is embedded in the SDK's webui package and handed over from there.
$script:coreRuntimePath = Join-Path $ext 'extension-sdk/webui/assets/yuruna.core.js'
$script:coreRuntime = Get-Content -Raw -LiteralPath $script:coreRuntimePath

foreach ($svc in $services) {
    $web = Join-Path $ext (Join-Path $svc.Dir 'server/internal/httpsrv/web')
    $stylesheets += [pscustomobject]@{
        Service = $svc.Name
        Path    = (Join-Path $web 'assets/style.css')
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $web 'assets/style.css'))
    }
    # Every page of the service, as the browser assembles it: the SDK's shared
    # runtime first, then this service's own layer on top. The chrome lives in
    # the runtime, so reading common.js alone would say the menu had gone.
    $scripts += [pscustomobject]@{
        Service = $svc.Name
        Text    = $script:coreRuntime + "`n" + (Get-Content -Raw -LiteralPath (Join-Path $web 'assets/common.js'))
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
$script:chromeStylesheets = @($stylesheets) + @([pscustomobject]@{
        Service = 'Yuruna status pages'
        Path    = (Join-Path $statusDir 'yuruna.common.css')
        Text    = (Get-Content -Raw -LiteralPath (Join-Path $statusDir 'yuruna.common.css'))
    })
}

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

    It 'keeps --chrome-bg dark in both color schemes, so no header renders light' {
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
            # target="_blank" keeps the guide off the tab the service is running
            # in: the pages poll and hold unsaved edits, so navigating away from
            # them to read documentation loses live state.
            if (-not [regex]::IsMatch($p.Text, "<a class=`"menu-out`" href=`"$([regex]::Escape($p.Guide))`" target=`"_blank`" rel=`"noopener`">")) {
                $findings += "$($p.Id): menu does not link the guide in a new tab"
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

    It 'sets viewport-fit=cover on every page, so the black bars honor the notch insets' {
        $findings = @()
        foreach ($p in $pages) {
            if (-not $p.Text.Contains('viewport-fit=cover')) { $findings += "$($p.Id): viewport meta lacks viewport-fit=cover" }
        }
        # Without it iOS Safari resolves every env(safe-area-inset-*) to 0, which
        # makes the chrome's inset padding inert and parks the footer bar under
        # the home indicator.
        Assert-NoFinding $findings 'the chrome pads itself with env(safe-area-inset-*), which needs this meta to be non-zero'
    }

    It 'wires the menu into every service UI' {
        $findings = @()
        foreach ($s in $scripts) {
            if ($s.Text -notmatch 'initMenu') { $findings += "$($s.Service): its scripts define no initMenu" }
        }
        Assert-NoFinding $findings 'static links still navigate, but the panel would never open'
    }

    It 'loads the shared runtime before its own scripts on every page' {
        $findings = @()
        foreach ($p in $pages) {
            $core = $p.Text.IndexOf('/assets/yuruna.core.js')
            if ($core -lt 0) {
                $findings += "$($p.Id): does not load /assets/yuruna.core.js"
                continue
            }
            # Order is load-bearing twice over: the runtime installs the baseline
            # shims (fetch, KeyboardEvent.key) and defines Y, and a service
            # script that ran first would find neither.
            $own = $p.Text.IndexOf('/assets/common.js')
            if ($own -ge 0 -and $own -lt $core) {
                $findings += "$($p.Id): loads common.js before the shared runtime"
            }
        }
        Assert-NoFinding $findings 'the runtime defines Y and installs the browser-baseline shims; nothing may run ahead of it'
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
            # In the menu specifically, and in a new tab -- see the service-side
            # twin of this test.
            if (-not [regex]::IsMatch($p.Text, "<a class=`"menu-out`" href=`"$([regex]::Escape($statusGuide))`" target=`"_blank`" rel=`"noopener`">")) {
                $findings += "$($p.Id): menu does not link the guide in a new tab"
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

# ---------------------------------------------------------------------------
# Static accessibility invariants.
#
# These are the checks that need no browser, so they run everywhere -- including
# the hosts where tools/Invoke-A11yCheck.ps1 reports SKIPPED because Chrome is
# absent. The two suites are deliberately complementary rather than redundant:
# a browser answers "what did this paint at 320px", markup answers "is this
# sayable at all", and neither can answer the other's question.
# ---------------------------------------------------------------------------
Describe 'static accessibility invariants across every shipped page' {

    BeforeAll {
        # $PSCommandPath is test/modules/<file>, so the repo root is three
        # levels up -- matching $repo at the top of this file. Getting this
        # wrong does not error: the globs below simply match nothing and every
        # assertion passes over an empty set.
        $script:repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:allPages = @()
        $webRoots = @(
            'test/extension/pool-control-service/server/internal/httpsrv/web'
            'test/extension/download-agent-service/server/internal/httpsrv/web'
            'test/extension/stash-service/server/internal/httpsrv/web'
            'test/status'
        )
        foreach ($rel in $webRoots) {
            $dir = Join-Path $script:repoRoot $rel
            foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.html' -File | Sort-Object Name)) {
                $script:allPages += [pscustomobject]@{
                    Id   = "$rel/$($f.Name)"
                    Text = (Get-Content -Raw -LiteralPath $f.FullName)
                }
            }
        }
    }

    It 'finds the pages to check' {
        # Guards every assertion below: a fixture that silently empties makes
        # all of them pass, which is the failure mode this suite's own runner
        # calls out as invisible to an exit code.
        Assert-True ($script:allPages.Count -ge 15) `
            "expected at least 15 shipped pages, found $($script:allPages.Count)"
        foreach ($p in $script:allPages) {
            Assert-True ($p.Text.Length -gt 200) "$($p.Id) read as $($p.Text.Length) bytes"
        }
    }

    It 'declares a language on every page' {
        # 3.1.1 is Level A and one attribute wide. A screen reader with no lang
        # reads English content with whatever voice it happens to be set to.
        $findings = @()
        foreach ($p in $script:allPages) {
            if ($p.Text -notmatch '(?i)<html[^>]*\slang\s*=\s*["''][a-z]') {
                $findings += "$($p.Id): <html> declares no lang"
            }
        }
        Assert-NoFinding $findings 'every page states the language it is written in'
    }

    It 'gives every page exactly one top-level heading' {
        # Heading structure is how a screen-reader user skims a page they have
        # not seen. Two h1s say the page has two subjects; none says it has no
        # name at all. This also catches an h1 that landed somewhere unintended
        # -- the first draft of these headings was inserted by a regex that
        # matched "<main>" inside a CSS comment, which no other check noticed.
        $findings = @()
        foreach ($p in $script:allPages) {
            $n = [regex]::Matches($p.Text, '(?i)<h1\b').Count
            if ($n -ne 1) { $findings += "$($p.Id): $n <h1> elements, expected exactly 1" }
        }
        Assert-NoFinding $findings 'a page has one subject and says so once'
    }

    It 'uses each id once per page' {
        # A duplicate id silently breaks every aria-* reference and label[for=]
        # that names it -- getElementById returns the first, the accessibility
        # tree follows suit, and the second control is left unlabeled.
        $findings = @()
        foreach ($p in $script:allPages) {
            $ids = [regex]::Matches($p.Text, '(?i)\sid\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
            foreach ($g in ($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
                $findings += "$($p.Id): id '$($g.Name)' appears $($g.Count) times"
            }
        }
        Assert-NoFinding $findings 'a duplicate id breaks every reference that names it'
    }

    It 'points every aria reference at an id the page defines' {
        # aria-labelledby naming a missing id does not degrade to "no label" in
        # a useful way: the control ends up with an empty accessible name, which
        # reads as nothing at all.
        $findings = @()
        foreach ($p in $script:allPages) {
            $ids = @([regex]::Matches($p.Text, '(?i)\sid\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            foreach ($attr in @('aria-controls', 'aria-labelledby', 'aria-describedby')) {
                foreach ($m in [regex]::Matches($p.Text, "(?i)\s$attr\s*=\s*""([^""]+)""")) {
                    foreach ($ref in ($m.Groups[1].Value -split '\s+')) {
                        if ($ref -and $ids -notcontains $ref) {
                            $findings += "$($p.Id): $attr points at '$ref', which the page does not define"
                        }
                    }
                }
            }
        }
        Assert-NoFinding $findings 'an aria reference to a missing id is an empty accessible name'
    }

    It 'keeps aria-hidden off focusable elements' {
        # aria-hidden on something focusable is the one ARIA combination with no
        # valid use: the element stays in the tab order and announces nothing,
        # so a keyboard user lands on a stop that does not exist for them.
        $findings = @()
        foreach ($p in $script:allPages) {
            foreach ($m in [regex]::Matches($p.Text, '(?i)<(a|button|input|select|textarea|summary)\b[^>]*>')) {
                $tag = $m.Value
                if ($tag -notmatch '(?i)aria-hidden\s*=\s*"true"') { continue }
                if ($tag -match '(?i)\bdisabled\b' -or $tag -match '(?i)tabindex\s*=\s*"-1"') { continue }
                if ($m.Groups[1].Value -eq 'a' -and $tag -notmatch '(?i)\shref\s*=') { continue }
                $findings += "$($p.Id): $($m.Groups[1].Value) is focusable and aria-hidden"
            }
        }
        Assert-NoFinding $findings 'aria-hidden on a focusable element is a tab stop that announces nothing'
    }

    It 'gives every statically declared form control a name source' {
        # A <select> has no placeholder fallback in the accessible-name
        # computation and its first <option> is not a name, so an unlabeled one
        # announces as a bare "combo box". Controls built in JS are the browser
        # gate's job; this covers what ships in the markup.
        $findings = @()
        foreach ($p in $script:allPages) {
            foreach ($m in [regex]::Matches($p.Text, '(?i)<(input|select|textarea)\b[^>]*>')) {
                $tag = $m.Value
                if ($tag -match '(?i)type\s*=\s*"(hidden|submit|reset|button)"') { continue }
                if ($tag -match '(?i)aria-label(ledby)?\s*=' -or $tag -match '(?i)\stitle\s*=') { continue }
                if ($tag -match '(?i)\splaceholder\s*=' -and $m.Groups[1].Value -ne 'select') { continue }
                $id = if ($tag -match '(?i)\sid\s*=\s*"([^"]+)"') { $Matches[1] } else { $null }
                if ($id -and $p.Text -match "(?i)<label[^>]*\sfor\s*=\s*""$([regex]::Escape($id))""") { continue }
                # A wrapping <label> is the other valid source; approximate it by
                # looking for one opened within the preceding 200 characters and
                # not yet closed.
                $before = $p.Text.Substring([Math]::Max(0, $m.Index - 200), [Math]::Min(200, $m.Index))
                if ($before -match '(?i)<label\b' -and $before -notmatch '(?i)</label>\s*$') { continue }
                $findings += "$($p.Id): <$($m.Groups[1].Value)$(if ($id) { " id=$id" })> has no name source"
            }
        }
        Assert-NoFinding $findings 'a control with no name announces as its role and nothing else'
    }

    It 'contains the visible label inside the accessible name' {
        # 2.5.3 Label in Name. A voice-control user says what they can SEE, so
        # an aria-label that replaces the visible text rather than extending it
        # makes the control unaddressable by the only name its user has for it.
        $findings = @()
        foreach ($p in $script:allPages) {
            foreach ($m in [regex]::Matches($p.Text, '(?is)<(button|a)\b([^>]*aria-label\s*=\s*"([^"]*)"[^>]*)>(.*?)</\1>')) {
                $label = $m.Groups[3].Value
                $visible = ($m.Groups[4].Value -replace '(?s)<[^>]+>', ' ') -replace '\s+', ' '
                $visible = $visible.Trim()
                if (-not $visible) { continue }
                if ($label.ToLowerInvariant().Contains($visible.ToLowerInvariant())) { continue }
                $findings += "$($p.Id): visible text '$visible' is not inside aria-label '$label'"
            }
        }
        Assert-NoFinding $findings 'a voice-control user can only say what the control shows'
    }

    It 'never removes a focus outline without drawing a replacement' {
        # 2.4.7 is the checkpoint keyboard users notice first. Suppressing the
        # user-agent ring is fine; suppressing it and drawing nothing is not.
        $sheets = @(
            'test/extension/pool-control-service/server/internal/httpsrv/web/assets/style.css'
            'test/extension/pool-control-service/server/internal/httpsrv/web/assets/board.css'
            'test/extension/download-agent-service/server/internal/httpsrv/web/assets/style.css'
            'test/extension/stash-service/server/internal/httpsrv/web/assets/style.css'
            'test/status/yuruna.common.css'
        )
        $findings = @()
        foreach ($rel in $sheets) {
            $text = Get-Content -Raw -LiteralPath (Join-Path $script:repoRoot $rel)
            $kills = [regex]::Matches($text, '(?i)outline\s*:\s*(none|0)\b').Count
            if ($kills -gt 0 -and $text -notmatch '(?i):focus-visible') {
                $findings += "${rel}: suppresses the focus outline $kills time(s) and defines no :focus-visible replacement"
            }
        }
        Assert-NoFinding $findings 'a suppressed focus ring needs a replacement, not silence'
    }
}

# ---------------------------------------------------------------------------
# Keyboard-operability invariants.
#
# Each of these pins a defect that made a core task impossible with a keyboard,
# not merely awkward. They read the shipped assets rather than a rendered page
# so they run on any host; the rendered-DOM half is tools/Invoke-A11yCheck.ps1.
# ---------------------------------------------------------------------------
Describe 'keyboard routes to every core task' {

    BeforeAll {
        $script:repo2 = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:stashWeb = Join-Path $script:repo2 'test/extension/stash-service/server/internal/httpsrv/web'
        $script:stashIndexJs = Get-Content -Raw -LiteralPath (Join-Path $script:stashWeb 'assets/index.js')
        $script:stashNewHtml = Get-Content -Raw -LiteralPath (Join-Path $script:stashWeb 'new.html')
        $script:statusJs = Get-Content -Raw -LiteralPath (Join-Path $script:repo2 'test/status/yuruna.common.js')
    }

    It 'reads the assets it checks' {
        Assert-True ($script:stashIndexJs.Length -gt 2000) 'stash index.js did not load'
        Assert-True ($script:stashNewHtml.Length -gt 500) 'stash new.html did not load'
        Assert-True ($script:statusJs.Length -gt 50000) 'yuruna.common.js did not load'
    }

    It 'opens a stash from a real link, not only a row click' {
        # A click handler on <tr> reaches the mouse and nothing else. Viewing a
        # stash is the reason the service exists, so the anchor is the whole
        # keyboard route to it -- and to its Download.
        Assert-True ($script:stashIndexJs -match "Y\.el\('a',\s*\{\s*href:\s*v\.permalink") `
            'the stash row no longer builds an anchor to the permalink'
    }

    It 'reveals the upload form from a real control' {
        # The upload form ships display:none and these tabs are the only thing
        # that shows it, so as <div>s they put one of the page's two core tasks
        # out of reach entirely.
        $findings = @()
        foreach ($id in @('tab-text', 'tab-files')) {
            $m = [regex]::Match($script:stashNewHtml, '(?s)<(\w+)\b[^>]*\bid="' + $id + '"[^>]*>')
            if (-not $m.Success) { $findings += "$id is gone"; continue }
            if ($m.Groups[1].Value -ne 'button') { $findings += "$id is a <$($m.Groups[1].Value)>, not a button" }
            if ($m.Value -notmatch 'role="tab"') { $findings += "$id carries no role=tab" }
            if ($m.Value -notmatch 'aria-controls=') { $findings += "$id names no panel" }
        }
        if ($script:stashNewHtml -notmatch 'role="tablist"') { $findings += 'the tab strip is not a tablist' }
        if ([regex]::Matches($script:stashNewHtml, 'role="tabpanel"').Count -ne 2) {
            $findings += 'the two forms are not both tabpanels'
        }
        Assert-NoFinding $findings 'a styled div is not a control'
    }

    It 'names every control the config tree builds' {
        # The visible key is a sibling span, so nothing associates it with the
        # control it describes. nameControls() is applied where the control is
        # appended -- one site per builder -- so a new builder cannot quietly
        # ship unnamed.
        Assert-True ($script:statusJs -match 'function nameControls') `
            'yuruna.common.js no longer defines nameControls'
        $appends = [regex]::Matches($script:statusJs, 'row\.appendChild\(build\w+\(')
        Assert-Equal -Expected 0 -Actual $appends.Count `
            'a config control is appended without going through nameControls'
        Assert-True ($script:statusJs -match "keyEl\.id = 'cfg-key-'") `
            'the config key no longer carries the id its control points at'
    }

    It 'makes the config tree expandable from the keyboard' {
        # Collapsing is how a deep tree becomes navigable, which is what a
        # keyboard user needs most; it was a click handler on two plain spans.
        $findings = @()
        if ($script:statusJs -notmatch "toggle\.setAttribute\('role', 'button'\)") { $findings += 'the toggle is not a button' }
        if ($script:statusJs -notmatch 'toggle\.tabIndex = 0') { $findings += 'the toggle is not focusable' }
        if ($script:statusJs -notmatch 'toggle\.onkeydown') { $findings += 'the toggle answers no key' }
        if ($script:statusJs -notmatch "aria-expanded'") { $findings += 'the toggle exposes no expanded state' }
        Assert-NoFinding $findings 'a disclosure needs a control, not a cursor style'
    }

    It 'says the status word wherever color carries it' {
        # These badges put the status in the CLASS and a name, label or
        # timestamp in the TEXT. The history table has no status column at all,
        # so for a past cycle the verdict lived nowhere but the fill color.
        Assert-True ($script:statusJs -match 'function srStatus') `
            'yuruna.common.js no longer defines srStatus'
        $colorOnly = [regex]::Matches($script:statusJs, "'<span class=""(badge|step-pill) ' \+ (cls\(|statusCls)")
        foreach ($m in $colorOnly) {
            $tail = $script:statusJs.Substring($m.Index, [Math]::Min(260, $script:statusJs.Length - $m.Index))
            Assert-True ($tail -match 'srStatus\(') `
                "a badge is emitted with its status in the class only: $($m.Value)"
        }
    }
}

# ---------------------------------------------------------------------------
# What happens AFTER the user acts, or while they are not acting.
#
# These pin behavior that only exists at runtime, so they check the code that
# produces it rather than a rendered page: whether a repaint is guarded, whether
# a result lands in a live region, whether a destructive path asks first.
# ---------------------------------------------------------------------------
Describe 'async behavior: focus survives, results are announced, deletes ask' {

    BeforeAll {
        $script:repo3 = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
        $script:webDirs = @(
            'test/extension/pool-control-service/server/internal/httpsrv/web'
            'test/extension/download-agent-service/server/internal/httpsrv/web'
            'test/extension/stash-service/server/internal/httpsrv/web'
        ) | ForEach-Object { Join-Path $script:repo3 $_ }
        $script:assets = @()
        foreach ($d in $script:webDirs) {
            foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $d 'assets') -Filter '*.js' -File)) {
                if ($f.Name -like '*.test.js') { continue }
                $script:assets += [pscustomobject]@{ Id = "$(Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $d))))/$($f.Name)"; Text = (Get-Content -Raw -LiteralPath $f.FullName) }
            }
        }
        $script:statusJs3 = Get-Content -Raw -LiteralPath (Join-Path $script:repo3 'test/status/yuruna.common.js')
    }

    It 'reads the assets it checks' {
        Assert-True ($script:assets.Count -ge 15) "expected the service assets, found $($script:assets.Count)"
        Assert-True ($script:statusJs3.Length -gt 50000) 'yuruna.common.js did not load'
    }

    It 'guards every repaint that wipes a list of controls' {
        # A repaint that empties a container removes whatever holds focus, so a
        # keyboard user on a 5-second poll cannot finish a row action before the
        # row is rebuilt under them -- and a half-typed value goes with it.
        #
        # Scoped to the containers that hold ROW CONTROLS, by id. A blanket rule
        # over every textContent='' would also catch the ones that should NOT be
        # held: an error panel that must always paint, the scan progress ticker
        # (2.2.2's essential-activity case), and single-value cells that hold
        # nothing focusable.
        $guarded = @{
            'image-rows'    = 'images.js'
            'host-rows'     = 'hosts.js'
            'pool-rows'     = 'pools.js'
            'ts-rows'       = 'test-sets.js'
            'check-rows'    = 'diagnostics.js'
        }
        $findings = @()
        foreach ($a in $script:assets) {
            foreach ($id in $guarded.Keys) {
                if ($a.Id -notlike "*$($guarded[$id])") { continue }
                # The same container is looked up several times per file (the
                # sorter, the busy overlay, the repaint). Only the repaint needs
                # the guard, so ANY occurrence carrying it satisfies this.
                $hits = [regex]::Matches($a.Text, "getElementById\('" + [regex]::Escape($id) + "'\)")
                if ($hits.Count -eq 0) { continue }
                $guardedHere = $false
                foreach ($h in $hits) {
                    $tail = $a.Text.Substring($h.Index, [Math]::Min(300, $a.Text.Length - $h.Index))
                    if ($tail -match 'holdRepaint\(') { $guardedHere = $true; break }
                }
                if (-not $guardedHere) {
                    $findings += "$($a.Id): no #$id repaint is behind holdRepaint"
                }
            }
        }
        # The board's card grid is built from a variable, not an id lookup.
        $board = ($script:assets | Where-Object { $_.Id -like '*board.js' }).Text
        if ($board -and $board -notmatch 'holdRepaint\(host, render\)') {
            $findings += 'board.js: the card grid repaint is not behind holdRepaint'
        }
        # The status board rewrites two regions with innerHTML on a 60 s tick.
        foreach ($needle in @('holdRepaint\(listSeq', 'holdRepaint\(histBody')) {
            if ($script:statusJs3 -notmatch $needle) { $findings += "yuruna.common.js: $needle is missing" }
        }
        Assert-NoFinding $findings 'a timed repaint must not take the focused control with it'
    }

    It 'defines the repaint guard once, where every service picks it up' {
        # One definition rather than three: the guard is subtle enough that three
        # copies is three chances for one of them to drift into a version that
        # releases the repaint while focus is still inside the region.
        Assert-True ($script:coreRuntime -match 'Y\.holdRepaint') 'the shared runtime has no holdRepaint'
        foreach ($d in $script:webDirs) {
            $name = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $d))))
            $pages = @(Get-ChildItem -LiteralPath $d -Filter '*.html' -File)
            Assert-True ($pages.Count -gt 0) "$name has no pages"
            foreach ($page in $pages) {
                $text = Get-Content -Raw -LiteralPath $page.FullName
                Assert-True ($text -match 'yuruna\.core\.js') "$name/$($page.Name) does not load the runtime that defines holdRepaint"
            }
        }
        Assert-True ($script:statusJs3 -match 'function holdRepaint') 'yuruna.common.js has no holdRepaint'
    }

    It 'announces every standing async result' {
        # A result written into a bare <div> is invisible to a screen reader:
        # nothing moves focus there and nothing announces it. The container must
        # already carry the role at load -- a live region created at the moment
        # its text is written is unreliably announced.
        $wanted = @{
            'notice' = 'alert'; 'msg' = 'alert'; 'login-error' = 'alert'
            'status' = 'status'; 'summary' = 'status'; 'stats-banner' = 'status'
            'config-status' = 'status'; 'perf-message' = 'status'; 'share-status' = 'status'
            'banner-text' = 'status'; 'test-result' = 'status'; 'delete-note' = 'status'
        }
        $findings = @()
        $pages = @()
        foreach ($d in $script:webDirs) { $pages += Get-ChildItem -LiteralPath $d -Filter '*.html' -File }
        $pages += Get-ChildItem -LiteralPath (Join-Path $script:repo3 'test/status') -Filter '*.html' -File
        foreach ($p in $pages) {
            $text = Get-Content -Raw -LiteralPath $p.FullName
            foreach ($id in $wanted.Keys) {
                $m = [regex]::Match($text, '(?s)<(?:div|p|span|pre)\b[^>]*\sid="' + [regex]::Escape($id) + '"[^>]*>')
                if (-not $m.Success) { continue }
                if ($m.Value -notmatch 'role="(status|alert)"') {
                    $findings += "$($p.Name): #$id is written asynchronously and is not a live region"
                }
            }
        }
        Assert-NoFinding $findings 'an unannounced result is no result at all'
    }

    It 'asks before destroying something' {
        # 3.3.4. Each of these deletes user data with no undo, and each has a
        # sibling on the same page that already confirms -- the inconsistency was
        # the defect, not the absence of a convention.
        $findings = @()
        foreach ($a in $script:assets) {
            if ($a.Id -notmatch 'pools\.js$|test-sets\.js$|index\.js$|images\.js$') { continue }
            foreach ($m in [regex]::Matches($a.Text, "method: 'DELETE'")) {
                $start = [Math]::Max(0, $m.Index - 900)
                $before = $a.Text.Substring($start, $m.Index - $start)
                if ($before -notmatch 'confirm\(') {
                    $findings += "$($a.Id): a DELETE fires with no confirmation above it"
                }
            }
        }
        Assert-NoFinding $findings 'a delete with no undo asks first'
    }

    It 'gives the lab-token prompt real dialog behavior' {
        $common = Get-Content -Raw -LiteralPath (Join-Path $script:webDirs[0] 'assets/common.js')
        $findings = @()
        foreach ($needle in @("role: 'dialog'", "'aria-modal': 'true'", "'aria-labelledby'", "opener.focus\(\)", "'Escape'")) {
            if ($common -notmatch $needle) { $findings += "the unlock overlay is missing $needle" }
        }
        Assert-NoFinding $findings 'a modal moves focus in, keeps it, and gives it back'
    }

    It 'lets the operator stop the page updating itself' {
        # 2.2.2. Every footer already showed a countdown; none of them could be
        # stopped, and the Refresh control only ever made it happen SOONER.
        $findings = @()
        $pages = @()
        foreach ($d in $script:webDirs) { $pages += Get-ChildItem -LiteralPath $d -Filter '*.html' -File }
        $pages += Get-ChildItem -LiteralPath (Join-Path $script:repo3 'test/status') -Filter '*.html' -File
        foreach ($p in $pages) {
            $text = Get-Content -Raw -LiteralPath $p.FullName
            if ($text -notmatch 'id="countdown"') { continue }
            if ($text -notmatch 'id="footer-pause"') { $findings += "$($p.Name): auto-refreshes with no pause control" }
            if ($text -match '<a id="footer-refresh"') { $findings += "$($p.Name): the refresh control is a link that never navigates" }
        }
        Assert-NoFinding $findings 'auto-updating content needs a stop'
    }
}
