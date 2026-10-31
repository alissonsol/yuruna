<#PSScriptInfo
.VERSION 2026.10.31
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

    Firefox runs the same probes where it is installed. It no longer speaks
    the DevTools Protocol, so it is driven over WebDriver BiDi, the same kind of
    JSON-over-WebSocket exchange, through the same client. Its color scheme and
    pointer type are preferences read at launch, so each scheme and pointer
    combination gets a browser of its own; desktop Firefox also ignores the
    viewport meta, so the layout-viewport check below is Chrome's alone.

    A desktop window never evaluates a `(pointer: coarse)` rule, so every
    phone rule in the stylesheets would pass unmeasured. Each page is therefore
    also measured as a phone: a mobile viewport with touch emulation, upright
    and on its side. A phone browser that finds no width=device-width viewport
    meta lays the page out 980px wide and scales it down, which reads as
    reflow-clean while the text is unreadably small, so a phone view whose
    layout viewport is wider than its screen is a finding of its own.

    A page is measured in more than its first state. Where the page has the
    controls for them, the menu is opened and the unlock prompt is shown, and
    each such state is measured like a page of its own. A state that a page
    offers but that does not open is a finding, so a broken menu cannot pass
    by never being drawn. The populated dashboards come from
    Export-GeneratedPages.ps1, which serves fixture data at the relative URLs
    the pages read.

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
    Desktop viewport widths in CSS pixels, measured with a fine pointer.
    Defaults to 320 (the WCAG 1.4.10 reflow width, which is also 1280 at 400%
    zoom), 768 and 1024 (the tablet breakpoints) and 1280.
.PARAMETER Phone
    Phone viewports as WIDTHxHEIGHT in CSS pixels, measured as a mobile
    viewport with touch emulation. Defaults to 360x780 and 844x390, one phone
    upright and on its side. Pass @() to measure desktop widths only.
.PARAMETER Browser
    Browsers to measure in. Defaults to chrome and firefox. Chrome is required
    whenever it is listed. Firefox in the default list is measured where it is
    installed and reported SKIPPED where it is not; named alone, it is
    required.
.PARAMETER State
    Page states to measure: default (the page as it loads), menu-open and
    unlock. Defaults to all three. A state is measured only on pages that have
    its control; -Url pages are measured in every state they offer.
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
.PARAMETER Concurrency
    Page-views measured at once, each in a browser tab of its own. Default: half
    the logical processors, at least 1 and at most 16.
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
    Chrome must not report a green accessibility gate. iOS Safari and Android
    Chrome stay documented manual device checks (docs/accessibility.md); the
    phone views here measure the layout rules, not those engines.
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
    [int[]]$Width = @(320, 768, 1024, 1280),
    [ValidatePattern('^\d{3,4}x\d{3,4}$')]
    [string[]]$Phone = @('360x780', '844x390'),
    [ValidateSet('light', 'dark')]
    [string[]]$Scheme = @('light', 'dark'),
    [ValidateSet('chrome', 'firefox')]
    [string[]]$Browser = @('chrome', 'firefox'),
    [ValidateSet('default', 'menu-open', 'unlock')]
    [string[]]$State = @('default', 'menu-open', 'unlock'),
    [string]$PageFilter = '*.html',
    [switch]$RequireDirection,
    [string]$ExpectedLanguage,
    [ValidateSet('ltr', 'rtl')]
    [string]$ExpectedDirection,
    [switch]$CheckFocusTargets,
    [ValidateRange(1, 64)]
    [int]$Concurrency = [Math]::Clamp([int][Math]::Floor([Environment]::ProcessorCount / 2), 1, 16),
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
        [Parameter(Mandatory)][string[]]$ArgumentList,
        # Firefox writes the console messages of the pages it renders to its
        # standard output, which would otherwise land in this gate's report.
        [switch]$DiscardStandardOutput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardOutput = [bool]$DiscardStandardOutput
    foreach ($argument in $ArgumentList) { [void]$startInfo.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw "Browser process did not start: $FilePath" }
        if ($DiscardStandardOutput) { $null = $process.StandardOutput.ReadToEndAsync() }
        return [pscustomobject]@{
            Process = $process
            StandardErrorTask = $process.StandardError.ReadToEndAsync()
        }
    } catch {
        $process.Dispose()
        throw
    }
}

# Chrome started from an elevated process on Windows starts itself again without
# elevation, and the process that was started exits. The browser that is
# measured is then one this script never held, so the profile directory on its
# command line is all that identifies it: --user-data-dir=<dir> for Chrome,
# --profile <dir> for Firefox.
function Stop-A11yBrowserProfile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops only browsers running on the throwaway profile directory this diagnostic created.')]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$ProfileDirectory
    )

    if (-not $IsWindows) {
        # Linux and macOS: the same identity, read from the process table. A
        # browser that relaunched itself, or a helper the tree kill missed,
        # keeps writing into the profile the caller is about to remove.
        $ownedArg = '(?:^|\s)(?:--user-data-dir=|--profile\s+)' + [regex]::Escape($ProfileDirectory) + '(?:\s|$)'
        $stopped = 0
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            # The id is taken before the arguments are matched: a second -match
            # replaces $Matches, and [int] of the group it no longer holds is 0
            # -- and Stop-Process -Id 0 on Linux signals this script's own
            # process group, which takes down whatever runner started it.
            $running = @(& ps -eo 'pid=,args=' 2>$null | ForEach-Object {
                    if ("$_" -match '^\s*(\d+)\s+(.*)$') {
                        $candidate = [int]$Matches[1]
                        if ($candidate -gt 0 -and $candidate -ne $PID -and $Matches[2] -match $ownedArg) { $candidate }
                    }
                })
            foreach ($processId in $running) {
                try { Stop-Process -Id $processId -Force -ErrorAction Stop; $stopped++ } catch { Write-Verbose "browser stop: $($_.Exception.Message)" }
            }
            if ($running.Count) { Start-Sleep -Milliseconds 200 }
        } while ($running.Count -and [DateTime]::UtcNow -lt $deadline)
        return $stopped
    }
    $image = [IO.Path]::GetFileName($FilePath).Replace("'", "''")
    $owned = '(?:--user-data-dir=|--profile\s+)"?' + [regex]::Escape($ProfileDirectory) + '(?:"|\s|$)'
    $stopped = 0
    # Asked again until nothing answers: a child process outlives its browser
    # for a moment, and the profile directory is removed next, which stays
    # locked until the last of them is gone.
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $running = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$image'" -ErrorAction SilentlyContinue |
                Where-Object { [string]$_.CommandLine -match $owned })
        foreach ($candidate in $running) {
            # One that exits between the listing and the stop is already what was wanted.
            try { Stop-Process -Id $candidate.ProcessId -Force -ErrorAction Stop; $stopped++ }
            catch { Write-Verbose "browser stop: $($_.Exception.Message)" }
        }
        if ($running.Count) { Start-Sleep -Milliseconds 200 }
    } while ($running.Count -and [DateTime]::UtcNow -lt $deadline)
    return $stopped
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
    # A populated dashboard reads its fixture data from the relative URLs the
    # page fetches (runtime/status.json, control/perf-aggregates), so each one
    # is exported into a folder of its own and served as a root of its own.
    foreach ($folder in (Get-ChildItem -LiteralPath $generatedRoot -Directory | Sort-Object Name)) {
        if (Get-ChildItem -LiteralPath $folder.FullName -Filter '*.html' -File) { $Serve += $folder.FullName }
    }
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

# --- REGION: browsers
$chrome = $null
$browserVersion = $null
if ('chrome' -in $Browser) {
    $chrome = $null
    foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser', 'chrome')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $chrome = $c.Source; break }
    }
    if (-not $chrome -and $IsMacOS) {
        $mac = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
        if (Test-Path -LiteralPath $mac) { $chrome = $mac }
    }
    if (-not $chrome -and $IsWindows) {
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
            if (-not $base) { continue }
            $candidate = Join-Path $base 'Google/Chrome/Application/chrome.exe'
            if (Test-Path -LiteralPath $candidate) { $chrome = $candidate; break }
        }
    }
    if (-not $chrome) {
        if (-not $Quiet) { foreach ($p in $pages) { Write-Line "SKIPPED $($p.Label)" } }
        Write-Line ("{0} page(s), 0 measured -- SKIPPED: no Chrome or Chromium on PATH" -f $pages.Count)
        exit 2
    }
    if ($IsWindows) {
        # chrome.exe is a GUI-subsystem program: asked for --version it prints
        # nothing and opens an ordinary browser on the operator's own profile, and
        # with no browser already running that call does not return until the
        # window is closed. The version lives in the file's own metadata.
        $browserVersion = [string](Get-Item -LiteralPath $chrome).VersionInfo.ProductVersion
        $global:LASTEXITCODE = 0
    } else {
        $browserVersion = (& $chrome --version 2>&1 | Out-String).Trim()
    }
    if ($LASTEXITCODE -ne 0 -or $browserVersion -notmatch '\d+(?:\.\d+){1,3}') {
        Write-Line ("{0} page(s), 0 measured -- SKIPPED: browser version could not be established" -f $pages.Count)
        exit 2
    }
    Write-Line "browser: $browserVersion"
}

# Firefox is measured where it is installed: in the default list a missing
# Firefox is reported and the run goes on, and only a run that named Firefox
# alone needs it.
$firefox = $null
$firefoxVersion = $null
$firefoxSkip = $null
if ('firefox' -in $Browser) {
    foreach ($n in @('firefox', 'firefox-esr')) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $firefox = $c.Source; break }
    }
    if (-not $firefox -and $IsMacOS) {
        $mac = '/Applications/Firefox.app/Contents/MacOS/firefox'
        if (Test-Path -LiteralPath $mac) { $firefox = $mac }
    }
    if (-not $firefox -and $IsWindows) {
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $base) { continue }
            $candidate = Join-Path $base 'Mozilla Firefox/firefox.exe'
            if (Test-Path -LiteralPath $candidate) { $firefox = $candidate; break }
        }
    }
    if (-not $firefox) {
        $firefoxSkip = 'no Firefox on PATH'
    } else {
        # firefox.exe is a GUI-subsystem program like chrome.exe: its version is
        # read from the file, never by asking it.
        if ($IsWindows) {
            $firefoxVersion = 'Mozilla Firefox ' + [string](Get-Item -LiteralPath $firefox).VersionInfo.ProductVersion
        } else {
            $firefoxVersion = (& $firefox --version 2>&1 | Out-String).Trim()
        }
        if ($firefoxVersion -notmatch '\d+(?:\.\d+){1,3}') {
            $firefoxSkip = 'browser version could not be established'
            $firefox = $null
        } else {
            Write-Line "browser: $firefoxVersion"
        }
    }
    if ($firefoxSkip -and 'chrome' -notin $Browser) {
        Write-Line ("{0} page(s), 0 measured -- SKIPPED: {1}" -f $pages.Count, $firefoxSkip)
        exit 2
    }
}

# --- REGION: Page measurement
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
  // The layout viewport is the root's client width. innerWidth is the visual
  // viewport, which a phone browser widens to show content that overflows (a
  // page 1200px wide reads 1208 there, and by that measure scrolls nowhere),
  // and which also holds a classic scrollbar that the page cannot use.
  var viewportWidth = de.clientWidth || window.innerWidth;
  out.reflow = { scrollWidth: de.scrollWidth, clientWidth: viewportWidth, innerWidth: window.innerWidth };
  if (de.scrollWidth > viewportWidth + 1) {
    // Naming the widest element is the difference between a finding somebody
    // can act on and one they have to re-derive by hand in devtools.
    // An element wider than the viewport is NOT the cause when an ancestor
    // already scrolls it -- a 733px table inside a working overflow-x:auto
    // wrapper is the design, not the defect, and naming it sends the reader to
    // the one place that is already correct.
    // An ancestor's overflow only clips what its box contains. An absolutely
    // positioned box is contained by its nearest POSITIONED ancestor, so a
    // scroll wrapper left at position:static scrolls the table and lets the
    // absolute box out -- which is how a 1px visually-hidden span can add a
    // second scroll direction to the page while every visible box fits.
    function containsAbsolute(n) {
      var cs = getComputedStyle(n);
      if (cs.position !== 'static') { return true; }
      if (cs.transform !== 'none' || cs.perspective !== 'none' || cs.filter !== 'none') { return true; }
      return (cs.contain || '').indexOf('paint') >= 0 || (cs.contain || '').indexOf('layout') >= 0;
    }
    function clipped(e) {
      var position = getComputedStyle(e).position;
      if (position === 'fixed') { return false; }
      var absolute = position === 'absolute';
      for (var n = e.parentElement; n && n !== document.documentElement; n = n.parentElement) {
        if (absolute && !containsAbsolute(n)) { continue; }
        var ox = getComputedStyle(n).overflowX;
        if (ox === 'auto' || ox === 'scroll' || ox === 'hidden') { return true; }
      }
      return false;
    }
    var widest = null;
    // body included: when the overflow is the body box itself, scanning only
    // its descendants names nothing and the reader gets a measurement with no
    // subject. An escaped absolutely positioned descendant is the other way to
    // reach here -- clipped() reports its ancestors' overflow, but an absolute
    // box takes its containing block from the nearest POSITIONED ancestor, so
    // an unpositioned scroll wrapper never clips it however its overflow reads.
    var scanned = [document.body].concat(
      Array.prototype.slice.call(document.querySelectorAll('body *')));
    scanned.forEach(function (e) {
      if (!e) { return; }
      var r = e.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) { return; }
      if (r.right <= viewportWidth + 1) { return; }
      if (clipped(e)) { return; }
      if (!widest || r.right > widest.right) { widest = { right: r.right, width: r.width, el: e }; }
    });
    var who = widest ? (' widest: ' + sel(widest.el) + ' reaches ' + Math.round(widest.right) + 'px (' + Math.round(widest.width) + 'px wide)') : '';
    add('reflow', 'document scrolls in two dimensions: scrollWidth ' + de.scrollWidth + ' > viewport ' + viewportWidth + '.' + who);
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
  // The further states this page offers, read from its own controls: the
  // page menu, and an unlock prompt (a #login section, or Y.unlock where the
  // service builds its prompt on demand).
  out.states = {
    'menu-open': !!document.getElementById('menu-button'),
    'unlock': !!document.getElementById('login') || !!(window.Y && typeof window.Y.unlock === 'function')
  };
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
#
# A service answers an /assets/<name> that its own folder lacks from the SDK's
# shared folder, which is where the runtime every extension page loads first
# (yuruna.core.js) lives. Served without that fallback, an extension page loads
# no script at all: it is measured as bare markup, its menu never opens and its
# tables never fill, and the gate reports that shell clean.
$sharedAssets = Join-Path $RepoRoot 'test/extension/extension-sdk/webui/assets'
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
        param($listener, $rootPort, $sharedAssets)

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
                    } elseif ($rel -match '^assets/([A-Za-z0-9._-]+)$') {
                        # A flat name only, as the services' own fallback takes.
                        $shared = Join-Path $sharedAssets $Matches[1]
                        if (Test-Path -LiteralPath $shared -PathType Leaf) { $file = $shared }
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
    # Several tabs load at once, so several runspaces take requests from the
    # one listener; each only reads the port map.
    $serverRunspace = @(foreach ($worker in 1..([Math]::Min($Concurrency, 4))) {
            $ps = [PowerShell]::Create()
            $null = $ps.AddScript($serve).AddArgument($listener).AddArgument($rootPort).AddArgument($sharedAssets)
            $null = $ps.BeginInvoke()
            $ps
        })
}

# --- REGION: page states
# Each script puts a loaded page into one further state and returns '' when it
# got there, or the reason it did not. A state the page offers but that does
# not open is a finding: a menu that never opens must not pass by never being
# drawn. The error text is a fixture, so its contrast is measured.
$stateSetup = @{
    'menu-open' = @'
(function () {
  var button = document.getElementById('menu-button');
  if (!button) { return 'the page has no #menu-button'; }
  button.click();
  var panel = document.getElementById(button.getAttribute('aria-controls') || 'menu-panel');
  if (!panel || panel.hidden || getComputedStyle(panel).display === 'none') { return 'the menu panel did not open'; }
  if (button.getAttribute('aria-expanded') !== 'true') { return 'the menu button did not report aria-expanded="true"'; }
  return '';
})()
'@
    'unlock' = @'
(function () {
  var sample = 'That code is not the current lab token.';
  var section = document.getElementById('login');
  if (section) {
    section.hidden = false;
    var error = document.getElementById('login-error');
    if (error && !error.textContent) { error.textContent = sample; }
    return getComputedStyle(section).display === 'none' ? 'the #login prompt did not show' : '';
  }
  if (!(window.Y && typeof window.Y.unlock === 'function')) { return 'the page has no unlock prompt'; }
  window.Y.unlock();
  var overlay = document.getElementById('yuruna-unlock');
  if (!overlay || getComputedStyle(overlay).display === 'none') { return 'Y.unlock() did not open its prompt'; }
  var message = overlay.querySelector('[role="alert"]');
  if (message) { message.hidden = false; message.textContent = sample; }
  return '';
})()
'@
}

# Installed before any page script runs, in every tab of both browsers.
$cspWatch = @'
window.__yurunaCspViolations = [];
window.addEventListener('securitypolicyviolation', function (event) {
  window.__yurunaCspViolations.push(
    'blocked ' + (event.blockedURI || 'inline') + ' by ' + (event.effectiveDirective || event.violatedDirective || 'unknown directive'));
});
'@

# --- REGION: views
# A profile is one viewport and pointer: the desktop widths with a fine
# pointer, the phones as a mobile viewport with touch.
$profiles = [Collections.Generic.List[object]]::new()
foreach ($w in $Width) {
    $profiles.Add([pscustomobject]@{ Name = "$($w)px"; Width = $w; Height = 900; Mobile = $false })
}
foreach ($size in $Phone) {
    $wh = $size.Split('x')
    $profiles.Add([pscustomobject]@{ Name = "phone $size"; Width = [int]$wh[0]; Height = [int]$wh[1]; Mobile = $true })
}

# The states measured after the first pass, and whether that pass is reported.
$furtherStates = @($State | Where-Object { $_ -ne 'default' })
$reportDefault = 'default' -in $State

function Get-A11yViewTag {
    param([string]$Label, [string]$Engine, [pscustomobject]$ViewProfile, [string]$ViewScheme, [string]$ViewState)
    $parts = @()
    if ($Engine -eq 'firefox') { $parts += 'firefox' }
    $parts += @($ViewProfile.Name, $ViewScheme)
    $suffix = if ($ViewState -ne 'default') { ", $ViewState" } else { '' }
    return "$Label [$($parts -join ' ')$suffix]"
}

# The first pass measures every page as it loads, and also learns which further
# states each page offers. Without 'default' in -State that pass still runs, but
# only to learn the states; its findings are not reported.
function Get-A11yDefaultView {
    param([Parameter(Mandatory)][string]$Engine, [Parameter(Mandatory)][object[]]$ViewProfile, [Parameter(Mandatory)][string[]]$ViewScheme)
    foreach ($page in $pages) {
        $pageUrl = if ($null -eq $page.Root) { $page.File } else { "http://127.0.0.1:$($rootPort[$page.Root])/$($page.File)" }
        foreach ($vp in $ViewProfile) {
            foreach ($sch in $ViewScheme) {
                [pscustomobject]@{
                    Url = $pageUrl; Label = $page.Label; Profile = $vp; Scheme = $sch; State = 'default'
                    Report = $reportDefault
                    Tag = (Get-A11yViewTag -Label $page.Label -Engine $Engine -ViewProfile $vp -ViewScheme $sch -ViewState 'default')
                }
            }
        }
    }
}

# --- REGION: browser protocols
$findings = [Collections.Generic.List[string]]::new()
$measured = 0
$nextId = 0

# One request and its reply over the browser's WebSocket. The DevTools Protocol
# and WebDriver BiDi share the shape: an id that the reply echoes, with events
# on the same socket read past until that reply arrives. Their errors differ: an
# object with a message, or a code beside a separate message.
function Send-A11yMessage {
    param(
        [Parameter(Mandatory)][pscustomobject]$Engine,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [string]$SessionId
    )
    $script:nextId++
    $msg = @{ id = $script:nextId; method = $Method; params = $Params }
    if ($SessionId) { $msg.sessionId = $SessionId }
    $json = $msg | ConvertTo-Json -Depth 10 -Compress
    $buf = [ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($json))
    if (-not $Engine.Socket.SendAsync($buf, 'Text', $true, [Threading.CancellationToken]::None).Wait(15000)) {
        throw "$($Engine.Protocol) send timed out: $Method"
    }
    $want = $script:nextId
    $seg = [ArraySegment[byte]]::new([byte[]]::new(262144))
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $deadline) {
        $sb = [Text.StringBuilder]::new()
        do {
            $t = $Engine.Socket.ReceiveAsync($seg, [Threading.CancellationToken]::None)
            if (-not $t.Wait(20000)) { throw "$($Engine.Protocol) receive timed out: $Method" }
            $null = $sb.Append([Text.Encoding]::UTF8.GetString($seg.Array, 0, $t.Result.Count))
        } while (-not $t.Result.EndOfMessage)
        $obj = $sb.ToString() | ConvertFrom-Json
        if ($obj.id -eq $want) {
            if ($obj.error) {
                $why = if ($obj.error.message) { $obj.error.message } else { "$($obj.error): $($obj.message)" }
                throw "$($Engine.Protocol) error on ${Method}: $why"
            }
            return $obj.result
        }
    }
    throw "$($Engine.Protocol) reply never arrived: $Method"
}

# The value of a script that returns a string, in either browser. A script
# that throws is the probe's own defect, never a page finding.
function Invoke-A11yTabScript {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab, [Parameter(Mandatory)][string]$Expression)
    if ($Engine.Kind -eq 'chrome') {
        $res = Send-A11yMessage -Engine $Engine -Method 'Runtime.evaluate' -SessionId $Tab.Session -Params @{
            expression = $Expression; returnByValue = $true; awaitPromise = $false }
        if ($res.exceptionDetails) { throw "probe threw: $($res.exceptionDetails.text)" }
        return $res.result.value
    }
    $res = Send-A11yMessage -Engine $Engine -Method 'script.evaluate' -Params @{
        expression = $Expression; target = @{ context = $Tab.Context }; awaitPromise = $false; resultOwnership = 'none' }
    if ($res.type -eq 'exception') { throw "probe threw: $($res.exceptionDetails.text)" }
    return $res.result.value
}

function Open-A11yTab {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab)
    $view = $Tab.View
    if ($Engine.Kind -eq 'chrome') {
        $Tab.Target = (Send-A11yMessage -Engine $Engine -Method 'Target.createTarget' -Params @{ url = 'about:blank' }).targetId
        $Tab.Session = (Send-A11yMessage -Engine $Engine -Method 'Target.attachToTarget' -Params @{ targetId = $Tab.Target; flatten = $true }).sessionId
        Send-A11yMessage -Engine $Engine -Method 'Emulation.setDeviceMetricsOverride' -SessionId $Tab.Session -Params @{
            width = $view.Profile.Width; height = $view.Profile.Height; deviceScaleFactor = 1; mobile = $view.Profile.Mobile } | Out-Null
        if ($view.Profile.Mobile) {
            Send-A11yMessage -Engine $Engine -Method 'Emulation.setTouchEmulationEnabled' -SessionId $Tab.Session -Params @{
                enabled = $true; maxTouchPoints = 5 } | Out-Null
        }
        Send-A11yMessage -Engine $Engine -Method 'Emulation.setEmulatedMedia' -SessionId $Tab.Session -Params @{
            features = @(@{ name = 'prefers-color-scheme'; value = $view.Scheme }) } | Out-Null
        Send-A11yMessage -Engine $Engine -Method 'Page.addScriptToEvaluateOnNewDocument' -SessionId $Tab.Session -Params @{ source = $cspWatch } | Out-Null
        Send-A11yMessage -Engine $Engine -Method 'Page.navigate' -SessionId $Tab.Session -Params @{ url = $view.Url } | Out-Null
        return
    }
    $Tab.Context = (Send-A11yMessage -Engine $Engine -Method 'browsingContext.create' -Params @{ type = 'tab' }).context
    Send-A11yMessage -Engine $Engine -Method 'browsingContext.setViewport' -Params @{
        context = $Tab.Context; viewport = @{ width = $view.Profile.Width; height = $view.Profile.Height } } | Out-Null
    Send-A11yMessage -Engine $Engine -Method 'browsingContext.navigate' -Params @{ context = $Tab.Context; url = $view.Url; wait = 'none' } | Out-Null
}

function Close-A11yTab {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab)
    if ($Engine.Kind -eq 'chrome') {
        if ($Tab.Target) { Send-A11yMessage -Engine $Engine -Method 'Target.closeTarget' -Params @{ targetId = $Tab.Target } | Out-Null }
    } elseif ($Tab.Context) {
        Send-A11yMessage -Engine $Engine -Method 'browsingContext.close' -Params @{ context = $Tab.Context } | Out-Null
    }
}

# A background tab may run its timers and paint late, so in Firefox each tab is
# brought to the front before it is put into a state or probed.
function Enter-A11yTab {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab)
    if ($Engine.Kind -eq 'firefox') {
        Send-A11yMessage -Engine $Engine -Method 'browsingContext.activate' -Params @{ context = $Tab.Context } | Out-Null
    }
}

# The navigation of a tab, repeated for one that stalled before it committed.
function Invoke-A11yTabNavigate {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab)
    if ($Engine.Kind -eq 'chrome') {
        Send-A11yMessage -Engine $Engine -Method 'Page.navigate' -SessionId $Tab.Session -Params @{ url = $Tab.View.Url } | Out-Null
    } else {
        Send-A11yMessage -Engine $Engine -Method 'browsingContext.navigate' -Params @{ context = $Tab.Context; url = $Tab.View.Url; wait = 'none' } | Out-Null
    }
}

# Polls until the tab holds a complete document other than about:blank, or
# the seconds run out; the last state read is returned either way.
function Wait-A11yTabLoaded {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][pscustomobject]$Tab, [Parameter(Mandatory)][int]$Seconds)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $state = @('not-read', '')
    do {
        # A document being replaced can refuse the read; that is "not yet".
        try {
            $state = (Invoke-A11yTabScript -Engine $Engine -Tab $Tab -Expression 'JSON.stringify([document.readyState, location.href])') |
                ConvertFrom-Json
        } catch { $state = @('read-failed', [string]$_.Exception.Message) }
        if ($state[0] -eq 'complete' -and $state[1] -ne 'about:blank') {
            return [pscustomobject]@{ Loaded = $true; ReadyState = $state[0]; Url = $state[1] }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    return [pscustomobject]@{ Loaded = $false; ReadyState = $state[0]; Url = $state[1] }
}

# --- REGION: batches
# Page-views are measured a batch at a time, each in a tab of its own with its
# own viewport and color scheme, so the browser renders a batch in parallel.
# Each tab is probed only after its document finished loading and the batch
# then settled for 1.6 s; a tab put into a further state settles 0.4 s more.
function Measure-A11yBatch {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][object[]]$Batch)
    $open = [Collections.Generic.List[object]]::new()
    try {
        foreach ($view in $Batch) {
            $tab = [pscustomobject]@{ View = $view; Target = $null; Session = $null; Context = $null; StateError = ''; LoadError = '' }
            $open.Add($tab)
            Open-A11yTab -Engine $Engine -Tab $tab
        }
        # A tab still showing about:blank has not committed its navigation,
        # and its blank document already reads complete. Under load a
        # navigation can stall before it commits, and a second one usually
        # lands. A tab that never loads is reported as such: its blank
        # document would answer every rule as a markup finding (no lang, no
        # landmarks) on a page the browser never showed.
        foreach ($tab in $open) {
            $loadState = Wait-A11yTabLoaded -Engine $Engine -Tab $tab -Seconds 30
            if ($loadState.Loaded) { continue }
            Invoke-A11yTabNavigate -Engine $Engine -Tab $tab
            $loadState = Wait-A11yTabLoaded -Engine $Engine -Tab $tab -Seconds 30
            if (-not $loadState.Loaded) {
                $tab.LoadError = ('the page did not finish loading within 30 s on either of two navigations (readyState {0} at {1})' -f
                    $loadState.ReadyState, $loadState.Url)
            }
        }
        Start-Sleep -Milliseconds 1600
        $staged = $false
        foreach ($tab in $open) {
            if ($tab.View.State -eq 'default' -or $tab.LoadError) { continue }
            Enter-A11yTab -Engine $Engine -Tab $tab
            $tab.StateError = [string](Invoke-A11yTabScript -Engine $Engine -Tab $tab -Expression $stateSetup[$tab.View.State])
            $staged = $true
        }
        if ($staged) { Start-Sleep -Milliseconds 400 }
        foreach ($tab in $open) {
            $view = $tab.View
            if ($tab.LoadError) {
                if (-not $view.Report) { continue }
                $script:measured++
                Write-Line "FAIL $($view.Tag)"
                Write-Line ("  {0,-22} {1}" -f 'load', $tab.LoadError)
                $findings.Add("$($view.Tag): load: $($tab.LoadError)")
                continue
            }
            Enter-A11yTab -Engine $Engine -Tab $tab
            $data = (Invoke-A11yTabScript -Engine $Engine -Tab $tab -Expression $probe) | ConvertFrom-Json
            if ($view.State -eq 'default') {
                if (-not $Engine.Offers.ContainsKey($view.Url)) { $Engine.Offers[$view.Url] = @{} }
                foreach ($offered in @('menu-open', 'unlock')) {
                    if ($data.states.$offered) { $Engine.Offers[$view.Url][$offered] = $true }
                }
            }
            if (-not $view.Report) { continue }
            $script:measured++
            $viewFindings = [Collections.Generic.List[object]]::new()
            foreach ($f in @($data.findings)) { $viewFindings.Add($f) }
            if ($tab.StateError) {
                $viewFindings.Add([pscustomobject]@{ kind = 'state'; detail = "the $($view.State) state did not open: $($tab.StateError)" })
            }
            # A phone browser lays out a page without a width=device-width
            # viewport meta 980px wide and scales it down: reflow-clean to the
            # probe, unreadably small to the reader. Firefox on the desktop
            # ignores the viewport meta, so only Chrome's mobile view can tell.
            if ($Engine.Kind -eq 'chrome' -and $view.Profile.Mobile -and [int]$data.reflow.clientWidth -gt $view.Profile.Width + 1) {
                $viewFindings.Add([pscustomobject]@{ kind = 'viewport'; detail = (
                            'the layout viewport is {0}px on a {1}px-wide phone; the page needs <meta name="viewport" content="width=device-width, initial-scale=1">' -f
                            $data.reflow.clientWidth, $view.Profile.Width) })
            }
            if ($viewFindings.Count -eq 0) {
                if (-not $Quiet) { Write-Line "ok   $($view.Tag)" }
            } else {
                # Printed even when quiet. -Quiet silences the passing
                # page-views, which are noise; a finding is the entire
                # reason this ran, and every caller that passes -Quiet
                # is the one whose operator has only this log to read.
                # Reporting the count alone sends them to reproduce the
                # run by hand to learn what it already knew.
                Write-Line "FAIL $($view.Tag)"
                foreach ($f in $viewFindings) {
                    $line = "  {0,-22} {1}" -f $f.kind, $f.detail
                    Write-Line $line
                    $findings.Add("$($view.Tag): $($f.kind): $($f.detail)")
                }
            }
        }
    } finally {
        foreach ($tab in $open) {
            try { Close-A11yTab -Engine $Engine -Tab $tab }
            catch { Write-Verbose "tab close failed: $($_.Exception.Message)" }
        }
    }
}

# Every page as it loads, then each further state on the pages that offer it.
function Measure-A11yView {
    param([Parameter(Mandatory)][pscustomobject]$Engine, [Parameter(Mandatory)][object[]]$View)
    for ($start = 0; $start -lt $View.Count; $start += $Concurrency) {
        Measure-A11yBatch -Engine $Engine -Batch @($View[$start..([Math]::Min($start + $Concurrency, $View.Count) - 1)])
    }
    $stateViews = @(foreach ($view in $View) {
            foreach ($further in $furtherStates) {
                if (-not ($Engine.Offers.ContainsKey($view.Url) -and $Engine.Offers[$view.Url][$further])) { continue }
                [pscustomobject]@{
                    Url = $view.Url; Label = $view.Label; Profile = $view.Profile; Scheme = $view.Scheme; State = $further
                    Report = $true
                    Tag = (Get-A11yViewTag -Label $view.Label -Engine $Engine.Kind -ViewProfile $view.Profile -ViewScheme $view.Scheme -ViewState $further)
                }
            }
        })
    for ($start = 0; $start -lt $stateViews.Count; $start += $Concurrency) {
        Measure-A11yBatch -Engine $Engine -Batch @($stateViews[$start..([Math]::Min($start + $Concurrency, $stateViews.Count) - 1)])
    }
}

# --- REGION: Chrome
$socket = $null
$chromeProc = $null
$chromeErrorTask = $null
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-a11y-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
$chromeLog = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'yuruna-a11y-chrome.log'
$browserReady = $false
$browserPrerequisiteFailure = $null

if ($chrome) {
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
        $chromeEngine = [pscustomobject]@{ Kind = 'chrome'; Protocol = 'CDP'; Socket = $socket; Offers = @{} }
        Measure-A11yView -Engine $chromeEngine -View @(Get-A11yDefaultView -Engine 'chrome' -ViewProfile $profiles -ViewScheme $Scheme)
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
            # The whole tree: Chrome's renderer and GPU helpers outlive the
            # launcher otherwise, and keep the profile locked against the removal
            # below.
            try { $chromeProc.Kill($true); [void]$chromeProc.WaitForExit(5000) }
            catch { Write-Verbose "chrome kill: $($_.Exception.Message)" }
        }
        # Whatever still runs on this profile -- a relaunched browser, a helper the
        # tree kill missed -- is stopped by the profile on its command line.
        try { $null = Stop-A11yBrowserProfile -FilePath $chrome -ProfileDirectory $profileDir }
        catch { Write-Verbose "chrome profile stop: $($_.Exception.Message)" }
        # Chrome's stderr is evidence only when the browser never became usable;
        # after a run that measured pages it is noise, and a stale copy from an
        # earlier failure would mislead whoever opens it.
        if ($chromeProc -and $chromeProc.HasExited -and $chromeErrorTask -and -not $browserReady) {
            try {
                $chromeError = $chromeErrorTask.GetAwaiter().GetResult()
                [IO.File]::WriteAllText($chromeLog, $chromeError, [Text.UTF8Encoding]::new($false))
            } catch { Write-Verbose "chrome stderr: $($_.Exception.Message)" }
        } elseif ($browserReady) {
            Remove-Item -LiteralPath $chromeLog -Force -ErrorAction SilentlyContinue
        }
        if ($chromeProc) { try { $chromeProc.Dispose() } catch { Write-Verbose "chrome dispose: $($_.Exception.Message)" } }
        foreach ($attempt in 1..10) {
            if (-not (Test-Path -LiteralPath $profileDir)) { break }
            Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $profileDir) { Start-Sleep -Milliseconds 300 }
        }
    }
}

# --- REGION: Firefox
# One browser per color scheme and pointer, because Firefox reads both from
# preferences at launch: the scheme override (0 dark, 1 light) and the pointer
# capabilities (1 a coarse pointer without hover, 6 a fine pointer with hover).
# The listening port comes from WebDriverBiDiServer.json in the throwaway
# profile, which Firefox writes after binding the port it chose, for the same
# reason Chrome's DevToolsActivePort is read rather than a port chosen here.
$firefoxLog = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath 'yuruna-a11y-firefox.log'
function Invoke-A11yFirefoxGroup {
    param([Parameter(Mandatory)][string]$GroupScheme, [Parameter(Mandatory)][bool]$Touch, [Parameter(Mandatory)][object[]]$GroupProfile)
    $ffProfile = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-a11y-" + [Guid]::NewGuid().ToString('N').Substring(0, 12))
    $ffSocket = $null
    $ffProc = $null
    $ffErrorTask = $null
    $ready = $false
    try {
        $null = New-Item -ItemType Directory -Path $ffProfile -Force
        $pointer = if ($Touch) { 1 } else { 6 }
        $override = if ($GroupScheme -eq 'dark') { 0 } else { 1 }
        [IO.File]::WriteAllLines((Join-Path $ffProfile 'user.js'), [string[]]@(
                "user_pref(`"layout.css.prefers-color-scheme.content-override`", $override);"
                "user_pref(`"ui.primaryPointerCapabilities`", $pointer);"
                "user_pref(`"ui.allPointerCapabilities`", $pointer);"
                'user_pref("browser.shell.checkDefaultBrowser", false);'), [Text.UTF8Encoding]::new($false))
        $launch = Start-A11yBrowserProcess -FilePath $firefox -DiscardStandardOutput -ArgumentList @(
            '--headless', '--no-remote', '--profile', $ffProfile, '--remote-debugging-port=0', 'about:blank')
        $ffProc = $launch.Process
        $ffErrorTask = $launch.StandardErrorTask
        $wsUrl = $null
        $serverFile = Join-Path $ffProfile 'WebDriverBiDiServer.json'
        for ($i = 0; $i -lt 120; $i++) {
            try {
                if (Test-Path -LiteralPath $serverFile -PathType Leaf) {
                    $server = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($serverFile))
                    $port = [int]$server.ws_port
                    if ([string]$server.ws_host -in @('127.0.0.1', 'localhost') -and $port -ge 1 -and $port -le 65535) {
                        $wsUrl = "ws://127.0.0.1:$port/session"; break
                    }
                }
            } catch { Write-Verbose "BiDi endpoint probe: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 250
        }
        if (-not $wsUrl) { throw 'Firefox did not open a WebDriver BiDi endpoint' }
        $ffSocket = [Net.WebSockets.ClientWebSocket]::new()
        if (-not $ffSocket.ConnectAsync([Uri]$wsUrl, [Threading.CancellationToken]::None).Wait(15000)) {
            throw 'could not connect to the WebDriver BiDi endpoint'
        }
        $engine = [pscustomobject]@{ Kind = 'firefox'; Protocol = 'BiDi'; Socket = $ffSocket; Offers = @{} }
        $session = Send-A11yMessage -Engine $engine -Method 'session.new' -Params @{ capabilities = @{} }
        if ([string]$session.capabilities.browserName -ne 'firefox') {
            throw "the WebDriver BiDi endpoint answered as '$($session.capabilities.browserName)', not firefox"
        }
        Send-A11yMessage -Engine $engine -Method 'script.addPreloadScript' -Params @{ functionDeclaration = "() => {`n$cspWatch`n}" } | Out-Null
        $ready = $true
        Measure-A11yView -Engine $engine -View @(Get-A11yDefaultView -Engine 'firefox' -ViewProfile $GroupProfile -ViewScheme @($GroupScheme))
    } catch {
        if ($ready) { throw }
        return $_.Exception.Message
    } finally {
        if ($ffSocket) { try { $ffSocket.Dispose() } catch { Write-Verbose "socket dispose: $($_.Exception.Message)" } }
        if ($ffProc -and -not $ffProc.HasExited) {
            try { $ffProc.Kill($true); [void]$ffProc.WaitForExit(5000) }
            catch { Write-Verbose "firefox kill: $($_.Exception.Message)" }
        }
        try { $null = Stop-A11yBrowserProfile -FilePath $firefox -ProfileDirectory $ffProfile }
        catch { Write-Verbose "firefox profile stop: $($_.Exception.Message)" }
        if ($ffProc -and $ffProc.HasExited -and $ffErrorTask -and -not $ready) {
            try {
                [IO.File]::WriteAllText($firefoxLog, $ffErrorTask.GetAwaiter().GetResult(), [Text.UTF8Encoding]::new($false))
            } catch { Write-Verbose "firefox stderr: $($_.Exception.Message)" }
        } elseif ($ready) {
            Remove-Item -LiteralPath $firefoxLog -Force -ErrorAction SilentlyContinue
        }
        if ($ffProc) { try { $ffProc.Dispose() } catch { Write-Verbose "firefox dispose: $($_.Exception.Message)" } }
        foreach ($attempt in 1..10) {
            if (-not (Test-Path -LiteralPath $ffProfile)) { break }
            Remove-Item -LiteralPath $ffProfile -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $ffProfile) { Start-Sleep -Milliseconds 300 }
        }
    }
    return $null
}

if ($firefox -and -not $browserPrerequisiteFailure) {
    foreach ($sch in $Scheme) {
        foreach ($touch in @($false, $true)) {
            $groupProfiles = @($profiles | Where-Object { $_.Mobile -eq $touch })
            if ($groupProfiles.Count -eq 0) { continue }
            $failure = Invoke-A11yFirefoxGroup -GroupScheme $sch -Touch $touch -GroupProfile $groupProfiles
            if ($failure) { $firefoxSkip = "browser launch/BiDi setup failed: $failure"; break }
        }
        if ($firefoxSkip) { break }
    }
}

# --- REGION: verdict
if ($listener) { try { $listener.Stop(); $listener.Close() } catch { Write-Verbose "listener stop: $($_.Exception.Message)" } }
foreach ($runspace in @($serverRunspace)) {
    if ($runspace) { try { $runspace.Dispose() } catch { Write-Verbose "runspace dispose: $($_.Exception.Message)" } }
}

if ($browserPrerequisiteFailure) {
    Write-Line ("{0} page(s), 0 measured -- SKIPPED: browser launch/CDP setup failed: {1}" -f
        $pages.Count, $browserPrerequisiteFailure.Exception.Message)
    if (Test-Path -LiteralPath $chromeLog) { Write-Line ("Chrome's own error output: {0}" -f $chromeLog) }
    exit 2
}
if ($firefoxSkip) {
    Write-Line ("{0} page(s), 0 measured in Firefox -- SKIPPED: {1}" -f $pages.Count, $firefoxSkip)
    if (Test-Path -LiteralPath $firefoxLog) { Write-Line ("Firefox's own error output: {0}" -f $firefoxLog) }
    if (-not $chrome) { exit 2 }
}

Write-Line ("{0} page-view(s) measured across {1} page(s), {2} finding(s)" -f $measured, $pages.Count, $findings.Count)

if ($findings.Count -gt 0) {
    Write-Error ("accessibility gate: {0} finding(s)" -f $findings.Count) -ErrorAction Continue
    exit 1
}
exit 0
