<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42c68b27-f0b2-4a32-92c7-e8448db1a932
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization message http compatibility browser pester
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
    Prove that the reference browser branches on the canonical HTTP message
    envelope while retaining the named N/N-1 reason fallback.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Chrome = $null
foreach ($name in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { $script:Chrome = $command.Source; break }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-message-http-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/extension/extension-sdk/webui/assets/yuruna.core.js') `
    -Destination (Join-Path $script:Sandbox 'yuruna.core.js') -Force
Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/extension/pool-control-service/server/internal/httpsrv/web/assets/common.js') `
    -Destination (Join-Path $script:Sandbox 'common.js') -Force
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'the HTTP message migration keeps identity separate from prose' {

    It 'uses message.code first and reads the legacy reason only when no envelope exists' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $page = @'
<!doctype html><html lang="en-US"><head><meta charset="utf-8"><title>message</title>
<script>
var activeResponse;
window.fetch = function () {
  return Promise.resolve({
    ok: false,
    status: 503,
    json: function () { return Promise.resolve(activeResponse); }
  });
};
</script></head><body><pre id="out">PENDING</pre>
<script src="yuruna.core.js"></script>
<script src="common.js"></script>
<script>
(function () {
  var rows = [], Y = window.Y;
  function record(name, error) {
    rows.push(name + '.code=' + (error.code || ''));
    rows.push(name + '.unlock=' + String(Y.needsUnlock(error)));
    rows.push(name + '.text=' + error.message);
  }
  activeResponse = {
    ok: false,
    message: {
      schema: 'yuruna.message/v1',
      code: 'auth.lab_token_unavailable',
      args: {},
      detail: { text: 'auth.unconfigured is only detail', source: 'labgate' }
    },
    reason: 'auth-unconfigured',
    error: 'legacy prose'
  };
  Y.api('/canonical').then(function () {}, function (error) {
    record('canonical', error);
    activeResponse = {
      ok: false,
      message: {
        schema: 'yuruna.message/v1', code: 'auth.unconfigured', args: {},
        detail: { text: 'No gate is configured.', source: 'labgate' }
      },
      reason: 'different-legacy-value'
    };
    return Y.api('/unconfigured').then(function () {}, function (second) {
      record('unconfigured', second);
      activeResponse = { ok: false, reason: 'auth-unconfigured', error: 'old producer' };
      return Y.api('/legacy').then(function () {}, function (legacy) {
        record('legacy', legacy);
      });
    });
  }).then(function () {
    document.getElementById('out').textContent = rows.join('\n');
  });
}());
</script></body></html>
'@
        $pagePath = Join-Path $script:Sandbox 'message.html'
        [IO.File]::WriteAllText($pagePath, $page)
        $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
            --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String
        $match = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
        Assert-True $match.Success 'the browser produced no message result'
        $text = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)

        Assert-True ($text.Contains('canonical.code=auth.lab_token_unavailable')) 'the canonical code was not preserved'
        Assert-True ($text.Contains('canonical.unlock=false')) 'legacy prose/reason overrode a conflicting canonical code'
        Assert-True ($text.Contains('canonical.text=auth.unconfigured is only detail')) 'the sourced detail was not used for display'
        Assert-True ($text.Contains('unconfigured.unlock=true')) 'the canonical unconfigured code was not recognized'
        Assert-True ($text.Contains('legacy.code=')) 'the legacy producer invented a canonical code'
        Assert-True ($text.Contains('legacy.unlock=true')) 'the named N/N-1 reason fallback stopped working'
    }
}
