<#PSScriptInfo
.VERSION 2026.08.25
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
.PARAMETER Serve
    Directories to serve and measure. Defaults to the four service web roots
    and the host status pages.
.PARAMETER Width
    Viewport widths in CSS pixels. Defaults to 320 (the WCAG 1.4.10 reflow
    width, which is also 1280 at 400% zoom) and 1280.
.PARAMETER Scheme
    Color schemes to measure. Defaults to both, because a token defined once
    in the light block is exactly the defect this catches.
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
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]]$Url,
    [Parameter()]
    [string[]]$Serve,
    [int[]]$Width = @(320, 1280),
    [ValidateSet('light', 'dark')]
    [string[]]$Scheme = @('light', 'dark'),
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Write-Line { param([string]$Text) Write-Information $Text -InformationAction Continue }

# --- REGION: targets ---------------------------------------------------------

if (-not $Serve -and -not $Url) {
    $Serve = @(
        'test/extension/pool-control-service/server/internal/httpsrv/web'
        'test/extension/download-agent-service/server/internal/httpsrv/web'
        'test/extension/stash-service/server/internal/httpsrv/web'
        'test/status'
    ) | ForEach-Object { Join-Path $RepoRoot $_ }

    # Five surfaces are GENERATED and have no .html file to discover: two service
    # UIs that live as Go raw-string constants, the cycle transcript, the log
    # directory listing, and the html part of the failure email. A gate that only
    # walks the tree cannot see them, so they are materialized first and served
    # like any other root. The path is
    # fixed rather than unique so a failing run leaves the page behind to open.
    $generated = Join-Path ([IO.Path]::GetTempPath()) 'yuruna-a11y-generated'
    $Serve += (& (Join-Path $PSScriptRoot 'Export-GeneratedPages.ps1') -OutputDirectory $generated -Quiet |
        Select-Object -Last 1)
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
    foreach ($f in (Get-ChildItem -LiteralPath $r -Filter '*.html' -File | Sort-Object Name)) {
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

# --- REGION: the measurement, as it runs inside the page ---------------------

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

  if (!document.documentElement.getAttribute('lang')) { add('lang', '<html> has no lang attribute'); }

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
  return JSON.stringify(out);
})()
'@

# --- REGION: static file server ----------------------------------------------

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
        param($listener, $rootPort)
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
                    if ($full.StartsWith(([IO.Path]::GetFullPath($root))) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                        $file = $full
                    }
                }
                if ($file) {
                    $bytes = [IO.File]::ReadAllBytes($file)
                    $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
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
    $null = $ps.AddScript($serve).AddArgument($listener).AddArgument($rootPort)
    $null = $ps.BeginInvoke()
    $serverRunspace = $ps
}

# --- REGION: CDP -------------------------------------------------------------

$socket = $null
$chromeProc = $null
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-a11y-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
$nextId = 0
$findings = [Collections.Generic.List[string]]::new()
$measured = 0

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
    $dbgPort = 0
    $p2 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $p2.Start(); $dbgPort = $p2.LocalEndpoint.Port; $p2.Stop()

    # --disable-web-security: the services send no CORS headers, so a page
    # served from this gate's own origin cannot complete its own fetches and an
    # unpopulated page measures nothing. Deliberate, scoped to a throwaway
    # profile, and this process only ever loads this repository's own pages.
    $chromeArgs = @(
        '--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--disable-web-security', '--hide-scrollbars', '--force-device-scale-factor=1',
        "--user-data-dir=$profileDir", "--remote-debugging-port=$dbgPort", 'about:blank'
    )
    if ($env:YURUNA_A11Y_NO_SANDBOX -eq '1' -or $IsLinux) { $chromeArgs = @('--no-sandbox') + $chromeArgs }
    $chromeLog = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'yuruna-a11y-chrome.log'
    $chromeProc = Start-Process -FilePath $chrome -ArgumentList $chromeArgs -PassThru -RedirectStandardError $chromeLog -ErrorAction Stop

    $wsUrl = $null
    for ($i = 0; $i -lt 80; $i++) {
        try {
            $ver = Invoke-RestMethod "http://127.0.0.1:$dbgPort/json/version" -TimeoutSec 2
            $wsUrl = $ver.webSocketDebuggerUrl
            if ($wsUrl) { break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $wsUrl) {
        Write-Line ("{0} page(s), 0 measured -- SKIPPED: Chrome did not open a DevTools endpoint" -f $pages.Count)
        exit 2
    }

    $socket = [Net.WebSockets.ClientWebSocket]::new()
    if (-not $socket.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(15000)) {
        throw 'could not connect to the DevTools endpoint'
    }

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
                    Send-Cdp -Method 'Page.navigate' -SessionId $sid -Params @{ url = $pageUrl } | Out-Null
                    Start-Sleep -Milliseconds 1600
                    $res = Send-Cdp -Method 'Runtime.evaluate' -SessionId $sid -Params @{
                        expression = $probe; returnByValue = $true; awaitPromise = $false }
                    if ($res.exceptionDetails) { throw "probe threw: $($res.exceptionDetails.text)" }
                    $data = $res.result.value | ConvertFrom-Json
                    $measured++
                    $tag = "$($page.Label) [$($w)px $sch]"
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
} finally {
    # Teardown runs after a failure as well as after a clean pass, so each step
    # is independent: one that cannot complete must not strand the next one, and
    # a teardown error must never replace the finding that caused it.
    if ($socket) { try { $socket.Dispose() } catch { Write-Verbose "socket dispose: $($_.Exception.Message)" } }
    if ($chromeProc -and -not $chromeProc.HasExited) { try { $chromeProc.Kill() } catch { Write-Verbose "chrome kill: $($_.Exception.Message)" } }
    if ($listener) { try { $listener.Stop(); $listener.Close() } catch { Write-Verbose "listener stop: $($_.Exception.Message)" } }
    if ($serverRunspace) { try { $serverRunspace.Dispose() } catch { Write-Verbose "runspace dispose: $($_.Exception.Message)" } }
    if (Test-Path -LiteralPath $profileDir) {
        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Line ("{0} page-view(s) measured across {1} page(s), {2} finding(s)" -f $measured, $pages.Count, $findings.Count)

if ($findings.Count -gt 0) {
    Write-Error ("accessibility gate: {0} finding(s)" -f $findings.Count) -ErrorAction Continue
    exit 1
}
exit 0
