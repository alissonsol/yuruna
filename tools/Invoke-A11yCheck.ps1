<#PSScriptInfo
.VERSION 2026.09.13
.GUID 420b9d4a-e9ff-472b-9afa-d978ada39114
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna accessibility wcag contrast reflow chrome test
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
    Measure the shipped web surfaces against the WCAG checks a stylesheet
    parser cannot answer, using the browser that is already installed.
.DESCRIPTION
    The other quality gates read source. This one reads what a browser paints,
    because four of the checks below have no answer in the source at all:

      - Contrast is a property of the COMPOSITED result. A token table is a
        hypothesis: a color can be inherited, overlaid, or blended by an
        `opacity` on an ancestor, and the value that finally meets the eye is
        not written anywhere. Reading `--pass-fg` tells you what the author
        typed; `getComputedStyle` tells you what the reader sees.
      - Reflow needs a viewport. There is no static property of a stylesheet
        that says "this page scrolls in two dimensions at 320px".
      - Target size needs layout: a box is under 24x24 only after padding,
        font metrics and flex distribution have run.
      - "Is this element focusable" is a DOM question, not a text one.

    Chrome is driven over the DevTools Protocol rather than with --dump-dom,
    for a reason worth stating because the simpler route looks like it works:
    headless Chrome CLAMPS its viewport to a 500 CSS px minimum, in both
    headless modes, at every --window-size, and --force-device-scale-factor
    moves devicePixelRatio without moving the CSS viewport. So a
    --window-size=320 run silently measures a 500px page and reports reflow
    clean. That is a false pass, which is worse than no check at all.
    Emulation.setDeviceMetricsOverride reaches a true 320px viewport.

    PowerShell speaks the protocol directly through
    System.Net.WebSockets.ClientWebSocket, so this gate needs no node, no npm
    and no browser-automation package -- matching Invoke-JsTest.ps1, which
    already reports SKIPPED rather than success on a host without node.

    In -Serve mode (the default) the pages are served from the working tree by
    an in-process HttpListener, so the gate measures the CSS as edited rather
    than whatever a deployed VM is still serving. Pages that fetch their data
    from an API render their empty state; every static check still applies, and
    the checks that need live rows are the reason -Url exists.
.PARAMETER Url
    Measure these already-running pages instead of serving the working tree.
.PARAMETER StripCustomProperties
    Serve every stylesheet and inline <style> with custom properties removed:
    each `--name:` definition and each declaration whose value contains var()
    is deleted, which is what a browser without custom properties does to
    them. What renders is then what the documented floor renders. Paired with
    -PaletteSnapshot it turns "the floor still paints" into a comparison
    rather than a judgment.
.PARAMETER PaletteSnapshot
    Write the computed background and text color of a fixed set of elements,
    per page and width, as JSON. Two runs -- one plain, one
    -StripCustomProperties -- produce identical files when every var() has a
    correct literal in front of it, and differ exactly where one is missing.
.PARAMETER Serve
    Directories to serve and measure. Defaults to the four service web roots
    and the host status pages.
.PARAMETER Width
    Viewport widths in CSS pixels. Defaults to 320 (the WCAG 1.4.10 reflow
    width, which is also 1280 at 400% zoom) and 1280.
.PARAMETER Scheme
    Color schemes to measure. Defaults to both, because a token defined once
    in the light block is exactly the defect this catches.
.PARAMETER PageFilter
    File-name filter for served pages. Defaults to every HTML page. The
    reference-slice suite uses it to run the composed pseudo-locale matrix
    without repeating unrelated generated pages.
.PARAMETER RequireDirection
    Require each measured document to declare ltr or rtl before scripts run.
.PARAMETER ExpectedLanguage
    Require the exact documentElement.lang value on every measured URL.
.PARAMETER ExpectedDirection
    Require the exact documentElement.dir value on every measured URL.
.PARAMETER CheckFocusTargets
    Focus every visible interactive control and fail when it cannot accept
    focus. This is a rendered focus-target check, not evidence of native Tab
    order or keyboard activation; those require the real-browser operator row.
.PARAMETER Quiet
    Print the summary only.
.EXAMPLE
    pwsh tools/Invoke-A11yCheck.ps1
.EXAMPLE
    pwsh tools/Invoke-A11yCheck.ps1 -Url http://192.168.7.43/ -Width 320
.EXAMPLE
    Several running services in one run. The list is COMMA-separated: a
    space-separated list is not an array to PowerShell, and each extra value
    would bind to a different parameter.

    pwsh -Command "& ./tools/Invoke-A11yCheck.ps1 -Url 'http://192.168.7.44/','http://192.168.7.43/'"
.NOTES
    Exits 0 when every page is clean, 1 when any check fails, and 2 when the
    run could not happen (no browser). Exit 2 is never success: a host without
    Chrome must not report a green accessibility gate.
#>

[CmdletBinding()]
# -Url declares a position so everything after it is named-only. Without that,
# `-Url a b c` binds only `a` and spills `b` and `c` onto the next two
# positions, so a plain list of pages fails with "cannot convert http://... to
# Int32" -- an error naming a parameter the operator never typed. PowerShell
# will not bind a space-separated list to an array parameter either way; the
# comma form in the examples is the one that works.
param(
    [Parameter(Position = 0)]
    [string[]]$Url,
    [Parameter()]
    [string[]]$Serve,
    [int[]]$Width = @(320, 1280),
    [ValidateSet('light', 'dark')]
    [string[]]$Scheme = @('light', 'dark'),
    [string]$PageFilter = '*.html',
    [switch]$RequireDirection,
    [string]$ExpectedLanguage,
    [ValidateSet('ltr', 'rtl')]
    [string]$ExpectedDirection,
    [switch]$CheckFocusTargets,
    [switch]$StripCustomProperties,
    [string]$PaletteSnapshot,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

if ($Serve -and $Url) {
    Write-Error '-Serve and -Url are mutually exclusive; live URLs may not share the relaxed local-file browser session.' -ErrorAction Continue
    exit 2
}

function Write-Line { param([string]$Text) Write-Information $Text -InformationAction Continue }

function Start-A11yBrowserProcess {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts only the explicitly discovered browser for this diagnostic and returns its exact process handle.')]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Browser process did not start: $FilePath" }
        return [pscustomobject]@{
            Process = $process
            StandardErrorTask = $process.StandardError.ReadToEndAsync()
        }
    } catch {
        $process.Dispose()
        throw
    }
}

# --- REGION: targets
if (-not $Serve -and -not $Url) {
    # The page roots come from the shared registry rather than a list kept
    # here. A service added to the tree and missing from one tool's private
    # list is a UI nobody renders for contrast, focus order or reflow, and the
    # gate reports a clean run over it -- which is the same output a genuinely
    # accessible UI produces.
    $registryPath = Join-Path $RepoRoot 'globalization/manifests/browser-sources.json'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "The browser-source registry is missing: $registryPath"
    }
    $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))
    $Serve = @($registry.pageRoots | ForEach-Object { Join-Path $RepoRoot ([string]$_.path) })
    if ($Serve.Count -eq 0) { throw 'The browser-source registry lists no page roots.' }

    # Five surfaces are GENERATED and have no .html file to discover: two service
    # UIs that live as Go raw-string constants, the cycle transcript, the log
    # directory listing, and the html part of the failure email. A gate that only
    # walks the tree cannot see them, so they are materialized first and served
    # like any other root. The path is
    # fixed rather than unique so a failing run leaves the page behind to open.
    $generated = Join-Path ([IO.Path]::GetTempPath()) 'yuruna-a11y-generated'
    # Cleared first: the exporter signals success by falling off its end, which
    # leaves $LASTEXITCODE untouched -- so whatever a previous command left there
    # would otherwise be read as this call's verdict.
    $global:LASTEXITCODE = 0
    $exported = @(& (Join-Path $PSScriptRoot 'Export-GeneratedPages.ps1') -OutputDirectory $generated -Quiet)
    # An exporter that failed emits no directory, and an empty entry is skipped
    # further down -- so without this the generated surfaces would simply not be
    # measured and the gate would still report a clean run over what remained.
    # A gate that cannot see part of what it covers has to say so.
    if ($LASTEXITCODE -ne 0) {
        throw ("The generated-page exporter exited $LASTEXITCODE, so its pages cannot be measured:`n" +
            ($exported -join "`n"))
    }
    $generatedRoot = @($exported | Select-Object -Last 1)[0]
    if (-not $generatedRoot -or -not (Test-Path -LiteralPath $generatedRoot -PathType Container)) {
        throw "The generated-page exporter named no output directory, so its pages cannot be measured."
    }
    $Serve += $generatedRoot
}

$roots = @()
foreach ($d in @($Serve)) {
    if (-not $d) { continue }
    $full = if ([IO.Path]::IsPathRooted($d)) { $d } else { Join-Path $RepoRoot $d }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Write-Error "not a directory: $full" -ErrorAction Continue
        exit 2
    }
    $roots += (Resolve-Path -LiteralPath $full).Path
}

# Discovery precedes the toolchain check, so a skipped run still names what it
# left unmeasured instead of reporting an empty nothing.
$pages = [Collections.Generic.List[object]]::new()
foreach ($r in $roots) {
    foreach ($f in (Get-ChildItem -LiteralPath $r -Filter $PageFilter -File | Sort-Object Name)) {
        # Three of the default roots are called "web", so a leaf-name label
        # makes findings from different services indistinguishable -- which is
        # worse than verbose, because it sends the reader to the wrong file.
        $rel = $r
        if ($r.StartsWith($RepoRoot)) { $rel = $r.Substring($RepoRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar, '/') }
        $rel = ($rel -replace '\\', '/')
        $pages.Add([pscustomobject]@{ Root = $r; File = $f.Name; Label = "$rel/$($f.Name)" })
    }
}
foreach ($u in @($Url)) {
    if ($u) { $pages.Add([pscustomobject]@{ Root = $null; File = $u; Label = $u }) }
}

if ($pages.Count -eq 0) {
    Write-Error 'no pages to measure' -ErrorAction Continue
    exit 2
}

$chrome = $null
foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'chrome')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $chrome = $c.Source; break }
}
if (-not $chrome -and $IsMacOS) {
    $mac = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
    if (Test-Path -LiteralPath $mac) { $chrome = $mac }
}
if (-not $chrome) {
    if (-not $Quiet) { foreach ($p in $pages) { Write-Line "SKIPPED $($p.Label)" } }
    Write-Line ("{0} page(s), 0 measured -- SKIPPED: no Chrome or Chromium on PATH" -f $pages.Count)
    exit 2
}
$browserVersion = (& $chrome --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $browserVersion -notmatch '\d+(?:\.\d+){1,3}') {
    Write-Line ("{0} page(s), 0 measured -- SKIPPED: browser version could not be established" -f $pages.Count)
    exit 2
}
Write-Line "browser: $browserVersion"

# --- REGION: the measurement, as it runs inside the page
# One expression, evaluated in the page after load. It returns findings, never
# throws: a probe that dies takes the whole gate's verdict with it.
$probe = @'
(function () {
  var out = { reflow: null, findings: [] };
  function add(kind, detail) { out.findings.push({ kind: kind, detail: detail }); }
  function lum(c) {
    var m = c.match(/[\d.]+/g); if (!m || m.length < 3) return null;
    var p = m.slice(0, 3).map(function (v) {
      v = v / 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
  }
  function ratio(a, b) {
    var l1 = lum(a), l2 = lum(b); if (l1 === null || l2 === null) return null;
    if (l1 < l2) { var t = l1; l1 = l2; l2 = t; }
    return (l1 + 0.05) / (l2 + 0.05);
  }
  function opaque(c) { var m = c.match(/[\d.]+/g); return m && (m.length < 4 || parseFloat(m[3]) > 0.95); }
  // The painted background is whatever the first non-transparent ancestor
  // paints. An element with no background of its own is not white -- it is
  // whatever is behind it, which is the whole reason this runs in a browser.
  function bg(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      var c = getComputedStyle(n).backgroundColor;
      if (c && opaque(c) && !/rgba\(0, 0, 0, 0\)/.test(c)) return c;
    }
    return getComputedStyle(document.documentElement).backgroundColor || 'rgb(255, 255, 255)';
  }
  function sel(el) {
    var s = el.tagName.toLowerCase();
    if (el.id) { s += '#' + el.id; }
    else if (el.className && typeof el.className === 'string' && el.className.trim()) {
      s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
    }
    return s;
  }
  function shown(el) {
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) return false;
    var r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  var de = document.documentElement;
  out.reflow = { scrollWidth: de.scrollWidth, innerWidth: window.innerWidth };
  if (de.scrollWidth > window.innerWidth + 1) {
    // Naming the widest element is the difference between a finding somebody
    // can act on and one they have to re-derive by hand in devtools.
    // An element wider than the viewport is NOT the cause when an ancestor
    // already scrolls it -- a 733px table inside a working overflow-x:auto
    // wrapper is the design, not the defect, and naming it sends the reader to
    // the one place that is already correct.
    function clipped(e) {
      for (var n = e.parentElement; n && n !== document.documentElement; n = n.parentElement) {
        var ox = getComputedStyle(n).overflowX;
        if (ox === 'auto' || ox === 'scroll' || ox === 'hidden') { return true; }
      }
      return false;
    }
    var widest = null;
    Array.prototype.forEach.call(document.querySelectorAll('body *'), function (e) {
      var r = e.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) { return; }
      if (r.right <= window.innerWidth + 1) { return; }
      if (clipped(e)) { return; }
      if (!widest || r.right > widest.right) { widest = { right: r.right, width: r.width, el: e }; }
    });
    var who = widest ? (' widest: ' + sel(widest.el) + ' reaches ' + Math.round(widest.right) + 'px (' + Math.round(widest.width) + 'px wide)') : '';
    add('reflow', 'document scrolls in two dimensions: scrollWidth ' + de.scrollWidth + ' > viewport ' + window.innerWidth + '.' + who);
  }

  var language = document.documentElement.getAttribute('lang') || '';
  if (!language) { add('lang', '<html> has no lang attribute'); }
  if (__EXPECTED_LANGUAGE__ && language !== __EXPECTED_LANGUAGE__) {
    add('lang', '<html> declares lang="' + language + '"; expected "' + __EXPECTED_LANGUAGE__ + '"');
  }
  var direction = document.documentElement.getAttribute('dir') || '';
  if (__REQUIRE_DIRECTION__ && direction !== 'ltr' && direction !== 'rtl') {
    add('direction', '<html> must declare dir="ltr" or dir="rtl" before scripts run');
  }
  if (__REQUIRE_DIRECTION__ && window.YurunaI18n && window.YurunaI18n.direction) {
    var expectedDirection = window.YurunaI18n.direction();
    if ((expectedDirection === 'ltr' || expectedDirection === 'rtl') && direction !== expectedDirection) {
      add('direction', '<html> declares dir="' + direction + '" but its resolved locale requires dir="' + expectedDirection + '"');
    }
  }
  if (__EXPECTED_DIRECTION__ && direction !== __EXPECTED_DIRECTION__) {
    add('direction', '<html> declares dir="' + direction + '"; expected "' + __EXPECTED_DIRECTION__ + '"');
  }
  (window.__yurunaCspViolations || []).forEach(function (violation) {
    add('csp-violation', violation);
  });

  var seen = Object.create(null);
  Array.prototype.forEach.call(document.querySelectorAll('[id]'), function (e) {
    if (seen[e.id]) { add('duplicate-id', 'id "' + e.id + '" is used more than once'); }
    seen[e.id] = 1;
  });

  ['aria-controls', 'aria-labelledby', 'aria-describedby'].forEach(function (a) {
    Array.prototype.forEach.call(document.querySelectorAll('[' + a + ']'), function (e) {
      e.getAttribute(a).split(/\s+/).forEach(function (id) {
        if (id && !document.getElementById(id)) {
          add('dangling-aria', sel(e) + ' ' + a + ' points at "' + id + '", which no element defines');
        }
      });
    });
  });

  var FOCUSABLE = 'a[href],button,input,select,textarea,summary,[tabindex]';
  var focusables = document.querySelectorAll(FOCUSABLE);
  Array.prototype.forEach.call(focusables, function (e) {
    if (e.disabled || e.getAttribute('tabindex') === '-1') { return; }
    if (e.closest('[aria-hidden="true"]')) {
      add('focusable-aria-hidden', sel(e) + ' is focusable and inside aria-hidden="true"');
    }
    if (!shown(e)) { return; }
    if (__CHECK_FOCUS_TARGETS__) {
      try { e.focus(); } catch (focusError) {
        add('focus-target', sel(e) + ' threw when focused: ' + focusError.message);
      }
      if (document.activeElement !== e) {
        add('focus-target', sel(e) + ' is visible but did not accept focus');
      }
    }
    var r = e.getBoundingClientRect();
    // 2.5.8 exempts targets whose 24px circles do not overlap a neighbor's,
    // and inline targets inside a sentence. Neither is cheap to prove here, so
    // only flag boxes small on BOTH axes -- an under-report, not an over-one.
    if (r.width < 24 && r.height < 24 && e.tagName !== 'A') {
      add('target-size', sel(e) + ' is ' + Math.round(r.width) + 'x' + Math.round(r.height) + ' CSS px, under 24x24');
    }
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(e.tagName) && e.type !== 'hidden') {
      var named = e.getAttribute('aria-label') || e.getAttribute('aria-labelledby') ||
                  e.getAttribute('title') || e.getAttribute('placeholder') || e.closest('label') ||
                  (e.id && document.querySelector('label[for="' + (window.CSS && CSS.escape ? CSS.escape(e.id) : e.id) + '"]'));
      if (!named) { add('no-accessible-name', sel(e) + ' is a form control with no name source'); }
    }
    // 1.4.11: for a text control the border IS the component boundary -- the
    // fill is usually the page's own background, so nothing else identifies it.
    if (/^(INPUT|SELECT|TEXTAREA)$/.test(e.tagName)) {
      var cs = getComputedStyle(e);
      if (cs.borderTopStyle !== 'none' && parseFloat(cs.borderTopWidth) > 0) {
        var br = ratio(cs.borderTopColor, bg(e.parentElement || e));
        if (br !== null && br < 2.995) {
          add('non-text-contrast', sel(e) + ' border ' + cs.borderTopColor + ' on ' + bg(e.parentElement || e) + ' = ' + br.toFixed(2) + ':1, under 3:1');
        }
      }
    }
  });

  var reference = document.querySelector('[data-yuruna-globalization-reference]');
  if (reference) {
    var referenceText = (reference.textContent || '').replace(/\s+/g, ' ').trim();
    if (!shown(reference) || !referenceText) {
      add('locale-render', 'the globalization reference state did not render visibly');
    } else if (/^qps-/i.test(de.getAttribute('lang') || '')) {
      var expectedMarkers = parseInt(reference.getAttribute('data-yuruna-pseudo-markers') || '1', 10);
      var actualMarkers = (referenceText.match(/\[/g) || []).length;
      if (actualMarkers < expectedMarkers) {
        add('locale-render', 'the pseudo-locale reference state rendered no generated pseudo text');
      }
    }
  }

  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  var node, reported = Object.create(null);
  while ((node = walker.nextNode())) {
    var text = node.nodeValue.replace(/\s+/g, ' ').trim();
    if (!text) { continue; }
    var el = node.parentElement; if (!el || !shown(el)) { continue; }
    // 1.4.3 exempts text that is part of an INACTIVE component. A disabled
    // control is dimmed on purpose and its low contrast carries the meaning.
    if (el.closest('[disabled],[aria-disabled="true"],fieldset[disabled]')) { continue; }
    var cs2 = getComputedStyle(el);
    var back = bg(el);
    var r2 = ratio(cs2.color, back);
    if (r2 === null) { continue; }
    var px = parseFloat(cs2.fontSize);
    var weight = parseInt(cs2.fontWeight, 10) || 400;
    var large = px >= 24 || (weight >= 700 && px >= 18.66);
    var floor = large ? 3 : 4.5;
    // 0.005 of slack so a value that rounds to exactly the floor is not failed
    // by the last bit of a double.
    if (r2 < floor - 0.005) {
      var key = cs2.color + '|' + back + '|' + px + '|' + weight;
      if (reported[key]) { continue; }
      reported[key] = 1;
      add('contrast', sel(el) + ' "' + text.slice(0, 28) + '" ' + cs2.color + ' on ' + back +
          ' = ' + r2.toFixed(2) + ':1, under ' + floor + ':1 (' + px + 'px/' + weight + ')');
    }
  }
  // A fixed sample of the surfaces a palette is responsible for. Recorded
  // rather than judged: the same list rendered with and without custom
  // properties has to produce the same colors, and any element where it does
  // not is one whose literal fallback is missing or wrong. Bounded and
  // ordered so two runs line up entry for entry.
  out.palette = [];
  var wanted = ['body', 'header.app', 'footer.app', '#banner', '#footer-bar',
                'main', 'table', 'th', 'td', 'button', 'a', 'input',
                '.badge', '.card', '.menu-panel', 'code'];
  for (var w = 0; w < wanted.length; w++) {
    var node = document.querySelector(wanted[w]);
    if (!node) { continue; }
    var pcs = getComputedStyle(node);
    out.palette.push({
      sel: wanted[w],
      bg: pcs.backgroundColor,
      fg: pcs.color,
      bc: pcs.borderTopColor,
      ff: pcs.fontFamily
    });
  }
  return JSON.stringify(out);
})()
'@
$probe = $probe.Replace('__REQUIRE_DIRECTION__', ([bool]$RequireDirection).ToString().ToLowerInvariant())
$probe = $probe.Replace('__CHECK_FOCUS_TARGETS__', ([bool]$CheckFocusTargets).ToString().ToLowerInvariant())
$probe = $probe.Replace('__EXPECTED_LANGUAGE__', (ConvertTo-Json -InputObject ([string]$ExpectedLanguage) -Compress))
$probe = $probe.Replace('__EXPECTED_DIRECTION__', (ConvertTo-Json -InputObject ([string]$ExpectedDirection) -Compress))

# --- REGION: static file server
# Every page in this repository references its assets from the ORIGIN root
# (`/assets/style.css`, not `assets/style.css`). Serving several web roots under
# one origin with a path prefix therefore sends all of them to the FIRST root's
# stylesheet, and the gate measures three services against a fourth service's
# CSS -- a false pass, which is the one failure mode a gate must not have. So
# each root gets its own port, and `/assets/...` resolves inside it.
$listener = $null
$serverRunspace = $null
$rootPort = @{}
if ($roots.Count -gt 0) {
    $listener = [Net.HttpListener]::new()
    foreach ($r in $roots) {
        $probeSocket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $probeSocket.Start(); $p = $probeSocket.LocalEndpoint.Port; $probeSocket.Stop()
        $rootPort[$r] = $p
        $listener.Prefixes.Add("http://127.0.0.1:$p/")
    }
    $listener.Start()

    $serve = {
        param($listener, $rootPort, $strip)

        # What a browser without custom properties is left with: a definition
        # it cannot store, and a declaration it cannot resolve, are both
        # invalid, and an invalid declaration is dropped while the rest of the
        # rule stands. Deleting them here reproduces that exactly, without
        # needing the engine that does it.
        function Get-CssWithoutCustomProperty {
            param([string]$Css)
            $out = [Text.StringBuilder]::new()
            foreach ($chunk in ($Css -split '(?<=[;{}])')) {
                $decl = $chunk -replace '(?s)/\*.*?\*/', ''
                if ($decl -match '^\s*--[A-Za-z0-9_-]+\s*:') { continue }
                if ($decl -match ':[^;{}]*\bvar\s*\(') { continue }
                [void]$out.Append($chunk)
            }
            return $out.ToString()
        }

        $mime = @{
            '.html' = 'text/html; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
            '.js' = 'text/javascript; charset=utf-8'; '.json' = 'application/json'
            '.svg' = 'image/svg+xml'; '.png' = 'image/png'; '.ico' = 'image/x-icon'
        }
        while ($listener.IsListening) {
            # GetContext throws when the listener is stopped from the main
            # thread; that is the shutdown signal, not an error.
            try { $ctx = $listener.GetContext() } catch { break }
            try {
                # The port says which root; the path is resolved inside it.
                $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
                $root = ($rootPort.GetEnumerator() | Where-Object { $_.Value -eq $ctx.Request.Url.Port } | Select-Object -First 1).Key
                $file = $null
                if ($root) {
                    $candidate = Join-Path $root ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
                    $full = [IO.Path]::GetFullPath($candidate)
                    # Never serve outside the root the port named.
                    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd(
                        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
                    $comparison = if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
                            [Runtime.InteropServices.OSPlatform]::Windows)) {
                        [StringComparison]::OrdinalIgnoreCase
                    } else { [StringComparison]::Ordinal }
                    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
                    if ($full.StartsWith($prefix, $comparison) -and
                        (Test-Path -LiteralPath $full -PathType Leaf)) {
                        $file = $full
                    }
                }
                if ($file) {
                    $bytes = [IO.File]::ReadAllBytes($file)
                    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
                    if ($strip -and ($ext -eq '.css' -or $ext -eq '.html')) {
                        $text = [Text.UTF8Encoding]::new($false).GetString($bytes)
                        if ($ext -eq '.css') {
                            $text = Get-CssWithoutCustomProperty -Css $text
                        } else {
                            # Inline styles are part of the same cascade and
                            # fail the same way, so a page whose palette lives
                            # in its own <style> has to be transformed too.
                            $text = [regex]::Replace($text, '(?is)(<style[^>]*>)(.*?)(</style>)', {
                                param($m)
                                $m.Groups[1].Value + (Get-CssWithoutCustomProperty -Css $m.Groups[2].Value) + $m.Groups[3].Value
                            })
                        }
                        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
                    }
                    $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                } else {
                    $ctx.Response.StatusCode = 404
                }
            } catch { $ctx.Response.StatusCode = 500 } finally { $ctx.Response.OutputStream.Close() }
        }
    }
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($serve).AddArgument($listener).AddArgument($rootPort).AddArgument([bool]$StripCustomProperties)
    $null = $ps.BeginInvoke()
    $serverRunspace = $ps
}

# --- REGION: CDP
$socket = $null
$chromeProc = $null
$chromeErrorTask = $null
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-a11y-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
$chromeLog = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'yuruna-a11y-chrome.log'
$nextId = 0
$findings = [Collections.Generic.List[string]]::new()
$paletteRow = [Collections.Generic.List[object]]::new()
$measured = 0
$browserReady = $false
$browserPrerequisiteFailure = $null

function Send-Cdp {
    param([string]$Method, [hashtable]$Params = @{}, [string]$SessionId)
    $script:nextId++
    $msg = @{ id = $script:nextId; method = $Method; params = $Params }
    if ($SessionId) { $msg.sessionId = $SessionId }
    $json = $msg | ConvertTo-Json -Depth 10 -Compress
    $buf = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($json))
    if (-not $socket.SendAsync($buf, 'Text', $true, [Threading.CancellationToken]::None).Wait(15000)) {
        throw "CDP send timed out: $Method"
    }
    $want = $script:nextId
    $seg = [ArraySegment[byte]]::new([byte[]]::new(262144))
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $deadline) {
        $sb = [Text.StringBuilder]::new()
        do {
            $t = $socket.ReceiveAsync($seg, [Threading.CancellationToken]::None)
            if (-not $t.Wait(20000)) { throw "CDP receive timed out: $Method" }
            $null = $sb.Append([Text.Encoding]::UTF8.GetString($seg.Array, 0, $t.Result.Count))
        } while (-not $t.Result.EndOfMessage)
        $obj = $sb.ToString() | ConvertFrom-Json
        # Events share the socket with replies; keep reading until the id matches.
        if ($obj.id -eq $want) {
            if ($obj.error) { throw "CDP error on ${Method}: $($obj.error.message)" }
            return $obj.result
        }
    }
    throw "CDP reply never arrived: $Method"
}

try {
    # Chrome selects and owns its DevTools port atomically. The chosen port is
    # reported through DevToolsActivePort below; pre-allocating then releasing
    # a port leaves a race in which another process can impersonate Chrome.
    $chromeArgs = @(
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--hide-scrollbars', '--force-device-scale-factor=1',
        "--user-data-dir=$profileDir", '--remote-debugging-port=0', 'about:blank'
    )
    # Local -Serve pages may call their repository APIs without CORS headers.
    # Live -Url checks stay inside the browser security model.
    if ($roots.Count -gt 0) { $chromeArgs = @('--disable-web-security') + $chromeArgs }
    # Disabling Chrome's sandbox is an explicit opt-in for a constrained CI
    # environment; it is never inferred merely from the operating system.
    if ($env:YURUNA_A11Y_NO_SANDBOX -eq '1') { $chromeArgs = @('--no-sandbox') + $chromeArgs }
    $launch = Start-A11yBrowserProcess -FilePath $chrome -ArgumentList $chromeArgs
    $chromeProc = $launch.Process
    $chromeErrorTask = $launch.StandardErrorTask

    $wsUrl = $null
    $dbgPort = 0
    $activePortPath = Join-Path $profileDir 'DevToolsActivePort'
    for ($i = 0; $i -lt 80; $i++) {
        try {
            if (Test-Path -LiteralPath $activePortPath -PathType Leaf) {
                $active = [IO.File]::ReadAllLines($activePortPath)
                $parsedPort = 0
                if ($active.Count -ge 1 -and [int]::TryParse($active[0], [ref]$parsedPort) -and
                    $parsedPort -ge 1 -and $parsedPort -le 65535) {
                    $dbgPort = $parsedPort
                    $ver = Invoke-RestMethod "http://127.0.0.1:$dbgPort/json/version" -TimeoutSec 2
                    $candidateWs = [uri]$ver.webSocketDebuggerUrl
                    if ($candidateWs.Scheme -eq 'ws' -and $candidateWs.Host -in @('127.0.0.1', 'localhost') -and
                        $candidateWs.Port -eq $dbgPort) { $wsUrl = $candidateWs.AbsoluteUri; break }
                }
            }
        } catch { Write-Verbose "DevTools endpoint probe: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 250
    }
    if (-not $wsUrl) {
        Write-Line ("{0} page(s), 0 measured -- SKIPPED: Chrome did not open a DevTools endpoint" -f $pages.Count)
        exit 2
    }

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    if (-not $socket.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(15000)) {
        throw 'could not connect to the DevTools endpoint'
    }
    $browserReady = $true

    foreach ($page in $pages) {
        $pageUrl = if ($null -eq $page.Root) { $page.File } else {
            "http://127.0.0.1:$($rootPort[$page.Root])/$($page.File)"
        }
        foreach ($w in $Width) {
            foreach ($sch in $Scheme) {
                $target = Send-Cdp -Method 'Target.createTarget' -Params @{ url = 'about:blank' }
                $sid = (Send-Cdp -Method 'Target.attachToTarget' -Params @{ targetId = $target.targetId; flatten = $true }).sessionId
                try {
                    Send-Cdp -Method 'Emulation.setDeviceMetricsOverride' -SessionId $sid -Params @{
                        width = $w; height = 900; deviceScaleFactor = 1; mobile = $false } | Out-Null
                    Send-Cdp -Method 'Emulation.setEmulatedMedia' -SessionId $sid -Params @{
                        features = @(@{ name = 'prefers-color-scheme'; value = $sch }) } | Out-Null
                    Send-Cdp -Method 'Page.addScriptToEvaluateOnNewDocument' -SessionId $sid -Params @{
                        source = @'
window.__yurunaCspViolations = [];
window.addEventListener('securitypolicyviolation', function (event) {
  window.__yurunaCspViolations.push(
    'blocked ' + (event.blockedURI || 'inline') + ' by ' + (event.effectiveDirective || event.violatedDirective || 'unknown directive'));
});
'@
                    } | Out-Null
                    Send-Cdp -Method 'Page.navigate' -SessionId $sid -Params @{ url = $pageUrl } | Out-Null
                    Start-Sleep -Milliseconds 1600
                    $res = Send-Cdp -Method 'Runtime.evaluate' -SessionId $sid -Params @{
                        expression = $probe; returnByValue = $true; awaitPromise = $false }
                    if ($res.exceptionDetails) { throw "probe threw: $($res.exceptionDetails.text)" }
                    $data = $res.result.value | ConvertFrom-Json
                    $measured++
                    $tag = "$($page.Label) [$($w)px $sch]"
                    if ($PaletteSnapshot -and $data.palette) {
                        foreach ($entry in $data.palette) {
                            $paletteRow.Add([ordered]@{
                                page = $page.Label; width = $w; scheme = $sch
                                selector = $entry.sel; background = $entry.bg
                                color = $entry.fg; border = $entry.bc; font = $entry.ff
                            })
                        }
                    }
                    if ($data.findings.Count -eq 0) {
                        if (-not $Quiet) { Write-Line "ok   $tag" }
                    } else {
                        if (-not $Quiet) { Write-Line "FAIL $tag" }
                        foreach ($f in $data.findings) {
                            $line = "  {0,-22} {1}" -f $f.kind, $f.detail
                            if (-not $Quiet) { Write-Line $line }
                            $findings.Add("${tag}: $($f.kind): $($f.detail)")
                        }
                    }
                } finally {
                    try { Send-Cdp -Method 'Target.closeTarget' -Params @{ targetId = $target.targetId } | Out-Null }
                    catch { Write-Verbose "closeTarget failed: $($_.Exception.Message)" }
                }
            }
        }
    }
    if ($PaletteSnapshot) {
        # Sorted, so two runs are comparable byte for byte rather than in the
        # order Chrome happened to finish the pages.
        $ordered = @($paletteRow | Sort-Object { $_.page }, { $_.width }, { $_.scheme }, { $_.selector })
        $json = ($ordered | ConvertTo-Json -Depth 6).Replace("`r`n", "`n").TrimEnd() + "`n"
        [IO.File]::WriteAllText($PaletteSnapshot, $json, [Text.UTF8Encoding]::new($false))
        if (-not $Quiet) { Write-Line ("palette snapshot: {0} row(s) -> {1}" -f $ordered.Count, $PaletteSnapshot) }
    }
} catch {
    if (-not $browserReady) {
        $browserPrerequisiteFailure = $_
    } else { throw }
} finally {
    # Teardown runs after a failure as well as after a clean pass, so each step
    # is independent: one that cannot complete must not strand the next one, and
    # a teardown error must never replace the finding that caused it.
    if ($socket) { try { $socket.Dispose() } catch { Write-Verbose "socket dispose: $($_.Exception.Message)" } }
    if ($chromeProc -and -not $chromeProc.HasExited) {
        try { $chromeProc.Kill(); [void]$chromeProc.WaitForExit(5000) }
        catch { Write-Verbose "chrome kill: $($_.Exception.Message)" }
    }
    if ($chromeProc -and $chromeProc.HasExited -and $chromeErrorTask) {
        try {
            $chromeError = $chromeErrorTask.GetAwaiter().GetResult()
            [IO.File]::WriteAllText($chromeLog, $chromeError, [Text.UTF8Encoding]::new($false))
        } catch { Write-Verbose "chrome stderr: $($_.Exception.Message)" }
    }
    if ($chromeProc) { try { $chromeProc.Dispose() } catch { Write-Verbose "chrome dispose: $($_.Exception.Message)" } }
    if ($listener) { try { $listener.Stop(); $listener.Close() } catch { Write-Verbose "listener stop: $($_.Exception.Message)" } }
    if ($serverRunspace) { try { $serverRunspace.Dispose() } catch { Write-Verbose "runspace dispose: $($_.Exception.Message)" } }
    if (Test-Path -LiteralPath $profileDir) {
        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($browserPrerequisiteFailure) {
    Write-Line ("{0} page(s), 0 measured -- SKIPPED: browser launch/CDP setup failed: {1}" -f
        $pages.Count, $browserPrerequisiteFailure.Exception.Message)
    exit 2
}

Write-Line ("{0} page-view(s) measured across {1} page(s), {2} finding(s)" -f $measured, $pages.Count, $findings.Count)

if ($findings.Count -gt 0) {
    Write-Error ("accessibility gate: {0} finding(s)" -f $findings.Count) -ErrorAction Continue
    exit 1
}
exit 0
