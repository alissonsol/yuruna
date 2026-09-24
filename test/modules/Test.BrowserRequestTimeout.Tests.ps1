<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42f60b19-4d8a-4e27-9b53-1c7048ae3d62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser timeout fetch pester
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
    Prove the shared request timeout answers the caller on time when the
    request it bounds never answers at all.
.DESCRIPTION
    A timeout that only cancels the transport is not a timeout. Aborting frees
    the socket but settles nothing the caller is waiting on, and a transport
    that ignores the signal is not even canceled. Both failures look the same
    from the page -- a promise that never settles -- so the timer has to reject
    the caller's promise itself rather than wait for the transport to fail.

    Both request paths are measured: Y.api in the shared runtime, and the
    standalone bounded helper carried by the two pages that are built as Go
    string literals and so load no runtime at all. What the rejection says is
    measured too, because a page can only explain the wait to a reader if the
    error describes the timeout rather than reporting the abort it caused.

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
        Load the runtime over a stalled transport and report what Y.api did
        with a request that never answers.
    .PARAMETER Preamble
        JavaScript that runs BEFORE the runtime loads, so the transport it
        installs is the one the runtime binds to.
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
# the page. It is defined BEFORE the runtime loads so the runtime binds to it
# rather than to the browser's own.
#
# It honors an abort signal, because a native fetch does. That is what makes
# the test sharp: the timer's abort does reach this promise, so the rejection
# the caller ends up with proves the timer settled it first.
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

Describe 'a stalled request is given up on rather than left hanging' {

    BeforeEach {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
        }
    }

    It 'rejects a request the transport never answers' {
        $result = Invoke-TimeoutScenario -Name 'stalled-fetch' -Preamble $script:StalledFetch
        Assert-True ($result -like 'REJECTED*') `
            "the stalled request was not given up on (page reported '$result')"
        Assert-True ($result -notlike '*NaN*') 'the rejection reported no elapsed time'
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
        $result = Invoke-TimeoutScenario -Name 'message' -Preamble $script:StalledFetch
        Assert-True ($result -match 'took too long') `
            "the caller received no explanation it could show a reader: '$result'"
    }
}
