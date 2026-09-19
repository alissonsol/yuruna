<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42f60b19-4d8a-4e27-9b53-1c7048ae3d62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser floor timeout fetch pester
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
    Prove the shared request timeout answers the caller on time in every
    capability combination the supported browsers actually present.
.DESCRIPTION
    A timeout that cannot reject a stalled promise is not a timeout, whatever
    the version label on the browser says. Three combinations exist across the
    supported range and they fail differently:

      No fetch at all. The XHR stand-in is installed and holds a handle it can
      abort, so both cancellation and rejection work.

      Native fetch and AbortController. The signal cancels the request.

      Native fetch, no AbortController. Nothing can cancel: the stand-in was
      not installed, so there is no handle, and a native fetch given no signal
      cannot be interrupted. This is the combination that hangs if the timer
      only aborts instead of also rejecting, and it is a real browser rather
      than a hypothetical one.

    The capability pair is tested directly rather than inferred from a version,
    because a page that works only because the test browser is modern proves
    nothing about the floor.

    Run: Invoke-Pester -Path test/modules/Test.BrowserRequestTimeout.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Runtime = Join-Path $script:RepoRoot 'test/extension/extension-sdk/webui/assets/yuruna.core.js'

$script:Chrome = $null
foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $script:Chrome = $c.Source; break }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-timeout-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
Copy-Item -LiteralPath $script:Runtime -Destination (Join-Path $script:Sandbox 'yuruna.core.js') -Force

function Invoke-TimeoutScenario {
    <#
    .SYNOPSIS
        Load the runtime under one capability combination and report what
        Y.api did with a request that never answers.
    .PARAMETER Preamble
        JavaScript that runs BEFORE the runtime loads, so it decides which
        capabilities the runtime finds.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Preamble)

    $page = @"
<!doctype html><html lang="en-US"><head><meta charset="utf-8"><title>t</title>
<script>
$Preamble
</script></head><body><pre id="out">PENDING</pre>
<script src="yuruna.core.js"></script>
<script>
(function () {
  var out = document.getElementById('out');
  if (!window.Y || !window.Y.api) { out.textContent = 'NORUNTIME'; return; }
  var started = new Date().getTime();
  window.Y.api('/never-answers', { timeoutMs: 250 }).then(function () {
    out.textContent = 'RESOLVED';
  }, function (err) {
    var waited = new Date().getTime() - started;
    out.textContent = 'REJECTED ' + waited + ' ' + (err && err.message ? err.message : '');
  });
}());
</script></body></html>
"@
    $pagePath = Join-Path $script:Sandbox "$Name.html"
    [IO.File]::WriteAllText($pagePath, $page)

    # The virtual-time budget is what lets a 250 ms timeout be observed without
    # the suite waiting on a wall clock.
    $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
        --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String
    $m = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
    if (-not $m.Success) { return 'NOOUTPUT' }
    return [Net.WebUtility]::HtmlDecode($m.Groups[1].Value).Trim()
}

# A fetch that never answers, which is what a stalled daemon looks like from
# the page. Defining it BEFORE the runtime loads is the point: the runtime
# installs its stand-in only when fetch is missing, so this is how a browser
# with a native one is represented.
#
# It honors an abort signal, because a native fetch does. Without that the
# scenario with AbortController would exercise the same path as the one
# without it, and three tests would prove one thing.
$script:StalledFetch = @'
  window.fetch = function (url, init) {
    return new Promise(function (resolve, reject) {
      if (init && init.signal) {
        init.signal.addEventListener('abort', function () {
          var err = new Error('The operation was aborted.');
          err.name = 'AbortError';
          reject(err);
        });
      }
    });
  };
'@
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'a stalled request is given up on, whatever the browser can cancel' {

    BeforeEach {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
        }
    }

    It 'rejects when the browser has fetch but cannot abort it' {
        # The combination that matters. Nothing here can cancel the request, so
        # the timer has to answer the caller by itself.
        $result = Invoke-TimeoutScenario -Name 'fetch-no-abort' -Preamble @"
$script:StalledFetch
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
"@
        Assert-True ($result -like 'REJECTED*') `
            "with native fetch and no AbortController the request was not given up on (page reported '$result')"
        Assert-True ($result -notlike '*NaN*') 'the rejection reported no elapsed time'
    }

    It 'rejects when the browser can abort it' {
        $result = Invoke-TimeoutScenario -Name 'fetch-with-abort' -Preamble $script:StalledFetch
        Assert-True ($result -like 'REJECTED*') `
            "with AbortController present the request was not given up on (page reported '$result')"
    }

    It 'rejects when the browser has no fetch at all' {
        # The floor itself: the XHR stand-in is installed, and it holds a handle
        # it can abort. XMLHttpRequest is replaced so nothing leaves the page.
        # The stand-in behaves the way a real XMLHttpRequest does: abort() fires
        # onabort, NOT onerror. A fake that fired neither would let a shim with
        # no onabort handler look correct here and hang in a browser.
        $result = Invoke-TimeoutScenario -Name 'no-fetch' -Preamble @'
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  window.XMLHttpRequest = function () {
    var self = this;
    this.open = function () { };
    this.setRequestHeader = function () { };
    this.send = function () { };
    this.abort = function () { if (self.onabort) { self.onabort(); } };
    this.readyState = 1;
  };
'@
        Assert-True ($result -like 'REJECTED*') `
            "on the floor's XHR path the request was not given up on (page reported '$result')"
    }

    It 'bounds a request on a page that carries no shared runtime' {
        # The two pages built as Go string literals load neither runtime, so
        # Y.api's timer never runs on them. They use the adapter's own bounded
        # helper, and this reads that helper out of the file the service will
        # actually serve rather than out of the source it was generated from.
        $generated = Join-Path $script:RepoRoot 'test/extension/caching-proxy-service/requestadapter.go'
        Assert-True (Test-Path -LiteralPath $generated -PathType Leaf) `
            'the caching-proxy service carries no generated request adapter'
        $goText = [IO.File]::ReadAllText($generated)
        $m = [regex]::Match($goText, '(?s)const requestAdapterScript = `(.*)`
?
')
        Assert-True $m.Success 'the generated adapter has no raw-string body to read'
        [IO.File]::WriteAllText((Join-Path $script:Sandbox 'adapter.js'), $m.Groups[1].Value)

        $page = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>t</title>
<script>
(function () {
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
  window.fetch = function () { return new Promise(function () { }); };
}());
</script>
<script src="adapter.js"></script>
</head><body><pre id="out">PENDING</pre>
<script>
(function () {
  var out = document.getElementById('out');
  if (typeof window.yurunaRequest !== 'function') { out.textContent = 'NOHELPER'; return; }
  window.yurunaRequest('/api/status', 250).then(function () {
    out.textContent = 'RESOLVED';
  }, function (e) {
    out.textContent = 'REJECTED ' + (e && e.message ? e.message : '');
  });
}());
</script></body></html>
'@
        $pagePath = Join-Path $script:Sandbox 'raw-page.html'
        [IO.File]::WriteAllText($pagePath, $page)
        $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
            --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String
        $out = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
        Assert-True $out.Success 'the raw page rendered nothing'
        $result = [Net.WebUtility]::HtmlDecode($out.Groups[1].Value).Trim()

        # NOHELPER is the failure this guards against specifically: guarding the
        # whole adapter on a missing fetch would leave the helper undefined on
        # every browser that has one.
        Assert-True ($result -ne 'NOHELPER') `
            'the bounded helper is missing on a browser that has a native fetch'
        Assert-True ($result -like 'REJECTED*') `
            "a raw page's request was not given up on (page reported '$result')"
    }

    It 'says what happened rather than failing silently' {
        $result = Invoke-TimeoutScenario -Name 'message' -Preamble @"
$script:StalledFetch
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
"@
        Assert-True ($result -match 'took too long') `
            "the caller received no explanation it could show a reader: '$result'"
    }
}
