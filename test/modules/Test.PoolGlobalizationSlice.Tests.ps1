<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42b0f66e-8f3f-4913-bbbf-f26bbcff321d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization pool pseudo rtl browser pester
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
    Render the pool repository-access reference slice through its shipped page,
    shared request adapter, and generated pseudo catalogs.
#>

BeforeAll {
Import-Module (Join-Path $PSScriptRoot 'Test.ProductGlobalization.psm1') -Force -Global -DisableNameChecking
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:WebRoot = Join-Path $script:RepoRoot 'test/extension/pool-control-service/server/internal/httpsrv/web'
$script:Chrome = Get-YurunaTestBrowser


$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-pool-globalization-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
foreach ($relative in @(
    'test/extension/extension-sdk/webui/assets/yuruna.core.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/common.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/hosts.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/board.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/pools.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Ploc.pool.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Plocm.pool.js'
)) {
    $source = Join-Path $script:RepoRoot $relative
    Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "$relative is not shipped"
    Copy-Item -LiteralPath $source -Destination (Join-Path $script:Sandbox (Split-Path -Leaf $source)) -Force
}

function Invoke-PoolPseudoPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][ValidateSet('ltr', 'rtl')][string]$Direction,
        [switch]$FullDocument
    )

    # Intl and normalize are taken away so the page is forced through the
    # embedded formatters, and toLocaleString is made locale-blind so a
    # formatter that delegated to the engine would show it. The transport is
    # answered in the page so the slice renders from fixed bytes and nothing
    # leaves the browser.
    $transport = @'
<script>
(function () {
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  Number.prototype.toLocaleString = function () { return String(this); };
  window.fetch = function (url) {
    var data;
    if (url === '/api/hosts') {
      data = { ok: true, pools: ['lab'], targetPoolId: '', hostnamesVisible: false,
        statusError: 'aggregate \u2069\u202E spoof',
        hosts: [{ hostId: '42cc', hostname: '', type: 'ubuntu.kvm', control: 'ready', access: 'denied', pool: 'lab' }] };
    } else if (url === '/api/hosts/facts') {
      data = { ok: true, hosts: { '42cc': { ok: true,
        frameworkAccess: 'repo \u2069\u202E spoof', frameworkAccessState: 'readable',
        frameworkUrl: 'https://example.test/framework/\u2069\u202E/spoof',
        projectAccess: 'No access', projectAccessState: 'denied',
        projectUrl: 'https://example.test/project/\u2069\u202E/spoof' } } };
    } else if (url === '/api/hostinfo') {
      data = { ok: true, goBaseUrl: '' };
    } else {
      data = { ok: false, error: 'unexpected request ' + url };
    }
    return new Promise(function (resolve) {
      window.setTimeout(function () {
        resolve({
          ok: data.ok !== false,
          status: data.ok === false ? 500 : 200,
          json: function () { return Promise.resolve(data); }
        });
      }, 0);
    });
  };
}());
</script>
'@

    $html = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'hosts.html'))
    $html = $html.Replace('<html lang="en">', "<html lang=`"$Locale`" dir=`"$Direction`">")
    $html = $html.Replace('<link rel="stylesheet" href="/assets/style.css">', '')
    $html = $html.Replace('/assets/', '')
    $html = $html.Replace('<script src="yuruna.core.js"></script>', $transport + "`n<script src=`"yuruna.core.js`"></script>")
    $html = $html.Replace('<script src="common.js"></script>',
        "<script src=`"common.js`"></script>`n<script src=`"$Locale.pool.js`"></script>")
    $path = Join-Path $script:Sandbox "$Locale.html"
    [IO.File]::WriteAllText($path, $html)

    $dom = Get-YurunaTestBrowserDom -Browser $script:Chrome -Path $path
    if ($FullDocument) { return [Net.WebUtility]::HtmlDecode($dom) }
    $match = [regex]::Match($dom, '(?s)<tbody id="host-rows">(.*?)</tbody>')
    if (-not $match.Success) { return '' }
    return [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
}

function Invoke-PoolBoardPage {
    <#
    .SYNOPSIS
        Render the shipped board against an /api/board payload.
    .DESCRIPTION
        Starts at the server boundary and proves what the payload carries
        survives the shipped core/common/board stack into textContent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Payload,
        [AllowEmptyString()][string]$BoardFailureDetail,
        [ValidateSet('en-US', 'qps-Ploc', 'qps-Plocm')][string]$Locale = 'en-US',
        [ValidateSet('ltr', 'rtl')][string]$Direction = 'ltr'
    )

    $boardJson = $Payload | ConvertTo-Json -Depth 12 -Compress
    $boardReply = if ($BoardFailureDetail) {
        '{ ok: false, error: ' + (ConvertTo-Json -InputObject $BoardFailureDetail -Compress) + ' }'
    } else { $boardJson }
    $transport = @"
<script>
(function () {
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  window.fetch = function (url) {
    var data;
    if (url.indexOf('/api/board?') === 0) {
      data = $boardReply;
    } else if (url === '/api/hostinfo') {
      data = { ok: true, goBaseUrl: '' };
    } else {
      data = { ok: false, error: 'unexpected request ' + url };
    }
    return new Promise(function (resolve) {
      window.setTimeout(function () {
        resolve({
          ok: data.ok !== false,
          status: data.ok === false ? 500 : 200,
          json: function () { return Promise.resolve(data); }
        });
      }, 0);
    });
  };
}());
</script>
"@

    $html = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'board.html'))
    $html = $html.Replace('<html lang="en">', "<html lang=`"$Locale`" dir=`"$Direction`">")
    $html = $html.Replace('<link rel="stylesheet" href="/assets/style.css">', '')
    $html = $html.Replace('<link rel="stylesheet" href="/assets/board.css">', '')
    $html = $html.Replace('/assets/', '')
    $html = $html.Replace('<script src="yuruna.core.js"></script>',
        $transport + "`n<script src=`"yuruna.core.js`"></script>")
    if ($Locale -ne 'en-US') {
        $html = $html.Replace('<script src="common.js"></script>',
            "<script src=`"common.js`"></script>`n<script src=`"$Locale.pool.js`"></script>")
    }
    $path = Join-Path $script:Sandbox 'repositories-board.html'
    [IO.File]::WriteAllText($path, $html)
    return (Get-YurunaTestBrowserDom -Browser $script:Chrome -Path $path)
}

function Invoke-PoolPoolsPage {
    <#
    .SYNOPSIS
        Render the shipped Pools page, type a project URL into its first row,
        and save it.
    .DESCRIPTION
        The page asks window.confirm before a save on a pool with members; the
        question is captured into the DOM, as is the notice a refused write
        leaves, so both are read back from the dump.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ProjectUrl,
        [AllowEmptyString()][string]$MutationFailureDetail
    )

    $stateJson = $State | ConvertTo-Json -Depth 12 -Compress
    $transport = @"
<script>
(function () {
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  window.fetch = function (url) {
    var data;
    if (url === '/api/state') {
      data = $stateJson;
    } else if (url === '/api/hostinfo') {
      data = { ok: true, goBaseUrl: '' };
    } else if (url === '/api/pool/host-control') {
      data = { ok: true, pools: {} };
    } else {
      data = { ok: false, error: 'unexpected request ' + url };
    }
    return new Promise(function (resolve) {
      window.setTimeout(function () {
        resolve({
          ok: data.ok !== false,
          status: data.ok === false ? 500 : 200,
          json: function () { return Promise.resolve(data); }
        });
      }, 0);
    });
  };
}());
</script>
"@
    $mutation = if ($MutationFailureDetail) {
        'Promise.reject({ message: ' + (ConvertTo-Json -InputObject $MutationFailureDetail -Compress) + ' })'
    } else { 'Promise.resolve({ ok: true })' }
    $harness = @"
<script>
window.confirm = function (question) {
  var capture = document.createElement('p');
  capture.id = 'confirm-capture';
  capture.textContent = question;
  document.body.appendChild(capture);
  return true;
};
Y.mutate = function () { return $mutation; };
</script>
"@
    $typed = ConvertTo-Json -InputObject $ProjectUrl -Compress
    $typing = @"
<script>
window.setTimeout(function () {
  var box = document.querySelector('#pool-rows input.repo-url[data-repo="project"]');
  var save = document.querySelector('#pool-rows button[data-action="set-repositories"]');
  if (!box || !save) { return; }
  box.value = $typed;
  var input = document.createEvent('HTMLEvents');
  input.initEvent('input', true, false);
  box.dispatchEvent(input);
  save.click();
}, 250);
</script>
"@

    $html = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'pools.html'))
    $html = $html.Replace('<link rel="stylesheet" href="/assets/style.css">', '')
    $html = $html.Replace('/assets/', '')
    $html = $html.Replace('<script src="yuruna.core.js"></script>',
        $transport + "`n<script src=`"yuruna.core.js`"></script>")
    $html = $html.Replace('<script src="common.js"></script>',
        '<script src="common.js"></script>' + "`n" + $harness.Trim())
    $html = $html.Replace('<script src="pools.js"></script>',
        '<script src="pools.js"></script>' + "`n" + $typing.Trim())
    $path = Join-Path $script:Sandbox 'repositories-pools.html'
    [IO.File]::WriteAllText($path, $html)
    return (Get-YurunaTestBrowserDom -Browser $script:Chrome -Path $path)
}
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'the pool repository-access slice renders through shipped pseudo assets' {

    It 'renders the stable denied state in expanded and mirrored pseudo' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        foreach ($case in @(
            @{ Locale = 'qps-Ploc'; Direction = 'ltr' }
            @{ Locale = 'qps-Plocm'; Direction = 'rtl' }
        )) {
            $row = Invoke-PoolPseudoPage -Locale $case.Locale -Direction $case.Direction
            Assert-True ([bool]$row) "$($case.Locale) produced no host row"
            Assert-False ($row.Contains('<strong>No access</strong>')) "$($case.Locale) rendered the legacy English prose"
            Assert-False ($row.Contains('pool.repo_no_access')) "$($case.Locale) rendered a catalog key"
            Assert-True ($row -match '<strong>\[') "$($case.Locale) did not render the pseudo-catalog repository label"
            $start = [char]0x2068
            $end = [char]0x2069
            Assert-True ($row.Contains($start + 'repo  spoof' + $end)) `
                "$($case.Locale) did not isolate a host-supplied repository name"
            Assert-True ($row.Contains($start + 'https://example.test/framework//spoof' + $end)) `
                "$($case.Locale) did not isolate a host-supplied repository URL"
            Assert-True ($row.Contains($start + 'https://example.test/project//spoof' + $end)) `
                "$($case.Locale) did not isolate the denied project URL inside its tooltip"
            # The page isolates a host value before the catalog formats it; in
            # a right-to-left locale the formatter must not nest a second pair.
            Assert-False ($row.Contains([string]$start + $start) -or $row.Contains([string]$end + $end)) `
                "$($case.Locale) isolated a host-supplied value twice"
        }
    }
}

Describe 'the shipped board and Pools pages render each pool''s repositories' {

    It 'shows each pool''s project URL read-only and isolated in expanded and mirrored pseudo' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $attack = [string]([char]0x2069) + [char]0x202e
        $payload = [ordered]@{
            ok = $true; range = '24h'; statsError = ''
            cards = @(
                [ordered]@{
                    poolId = 'lab'; displayName = 'Lab'; hostsTotal = 1; hostsReporting = 1
                    successPct = 100; total = 1; failed = 0
                    frameworkUrl = 'https://example.test/framework'
                    projectUrl = "https://example.test/project/$attack/spoof"; blocked = @()
                }
                [ordered]@{
                    poolId = 'own'; displayName = 'Own'; hostsTotal = 1; hostsReporting = 1
                    successPct = 100; total = 1; failed = 0
                    frameworkUrl = ''; projectUrl = ''; blocked = @('42cc')
                }
            )
        }
        $start = [char]0x2068
        $end = [char]0x2069
        foreach ($case in @(
            @{ Locale = 'qps-Ploc'; Direction = 'ltr' }
            @{ Locale = 'qps-Plocm'; Direction = 'rtl' }
        )) {
            # The cards alone: the dump also carries the page's scripts, the
            # fixture payload among them.
            $page = Invoke-PoolBoardPage -Payload $payload -Locale $case.Locale -Direction $case.Direction
            $cards = [regex]::Match($page, '(?s)<div id="cards">(.*)</div>\s*<p id="empty"')
            Assert-True $cards.Success "$($case.Locale) rendered no card region"
            $dom = [Net.WebUtility]::HtmlDecode($cards.Groups[1].Value)
            $running = Format-CatalogMessage -Key 'pool.running' -Locale $case.Locale
            Assert-True ($dom.Contains('<p class="assigned">' + $running + '<strong>' + $start +
                    'https://example.test/project//spoof' + $end + '</strong></p>')) `
                "$($case.Locale) did not show the pool's project URL, isolated, after the localized label"
            $own = Format-CatalogMessage -Key 'pool.the_hosts_own_projects' -Locale $case.Locale
            Assert-True ($dom.Contains('<p class="assigned">' + $running + '<span class="none">' + $own + '</span></p>')) `
                "$($case.Locale) did not say a pool without a project URL runs the hosts' own projects"
            $denied = Format-CatalogMessage -Key 'pool.hosts_project_denied' -Arguments @{ count = 1 } -Locale $case.Locale
            Assert-True ($dom.Contains('<p class="blocked">' + $denied + '</p>')) `
                "$($case.Locale) lost the warning for a member that cannot read its project"
            Assert-False ($dom.Contains('https://example.test/framework')) `
                "$($case.Locale) put the framework URL on the card, which names only the project"
            Assert-False ($dom -match '<select\b') "$($case.Locale) rendered a picker on a read-only board"
            Assert-False ($dom -match '>pool\.[a-z0-9_]+<') "$($case.Locale) rendered a catalog key as text"
        }

        $boardSource = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'assets/board.js'))
        Assert-False ($boardSource.Contains('Y.mutate(')) `
            'the board writes nothing; a pool''s repositories are set on the Pools page'
    }

    It 'isolates the project URL inside the Pools save confirmation and names every box' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $attack = [string]([char]0x2069) + [char]0x202e
        $state = [ordered]@{
            ok = $true
            pools = @([ordered]@{
                    poolId = 'hostile'; poolGuid = ('42' + ('1' * 30)); displayName = 'Hostile'
                    members = @('42' + ('2' * 30))
                    repositories = [ordered]@{
                        frameworkUrl = 'https://example.test/framework'; projectUrl = 'https://example.test/project'
                    }
                })
            autoEnrollment = [ordered]@{ enabled = $true; targetPoolId = 'default'; excluded = @() }
        }
        $start = [char]0x2068
        $end = [char]0x2069

        $dom = [Net.WebUtility]::HtmlDecode(
            (Invoke-PoolPoolsPage -State $state -ProjectUrl "https://example.test/$attack/unsafe"))
        Assert-True ($dom.Contains('id="confirm-capture">1 host will switch to ' + $start +
                'https://example.test//unsafe' + $end + ' on their next cycle.</p>')) `
            'the save confirmation left the typed project URL outside a bidi isolate'
        Assert-True ($dom -match '<th data-sort="repositories"><button type="button" class="sort"[^>]*>Framework / Project</button></th>\s*<th[^>]*>Actions</th>') `
            'the Framework / Project column is not the sortable header between Pool Status and Actions'
        Assert-True ($dom -match '<input [^>]*class="repo-url"[^>]*data-repo="framework"[^>]*aria-label="Framework URL for pool hostile"') `
            'the framework box does not name its pool'
        Assert-True ($dom -match '<input [^>]*class="repo-url"[^>]*data-repo="project"[^>]*aria-label="Project URL for pool hostile"') `
            'the project box does not name its pool'
        Assert-True ($dom.Contains('aria-label="Save the framework and project URLs of pool hostile"')) `
            'the Save control does not name its pool'
        Assert-False ($dom -match '<textarea [^>]*repo') 'a URL box became a textarea, which wraps and scrolls'
        Assert-False ($dom -match '<form\b') 'the page grew a form, which the CSP form-action none blocks'
    }

    It 'isolates bidi-hostile remote detail in every pool failure sentence' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $attack = [string]([char]0x2069) + [char]0x202e
        $payload = [ordered]@{
            ok = $true; range = '24h'; statsError = "stats $attack spoof"
            cards = @([ordered]@{
                    poolId = 'lab'; displayName = 'Lab'; hostsTotal = 1
                    hostsReporting = 1; successPct = 100; total = 1; failed = 0
                    frameworkUrl = ''; projectUrl = ''; blocked = @()
                })
        }
        $start = [char]0x2068
        $end = [char]0x2069

        $statsDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage -Payload $payload))
        Assert-True ($statsDom.Contains('Live numbers unavailable (' + $start + 'stats  spoof' + $end + ').')) `
            'the board stats failure detail escaped its bidi isolate'

        $loadDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage -Payload $payload `
                    -BoardFailureDetail "load $attack spoof"))
        Assert-True ($loadDom.Contains('Could not load the board: ' + $start + 'load  spoof' + $end +
                '. Retrying on the next refresh.')) `
            'the board load failure detail escaped its bidi isolate'

        $state = [ordered]@{
            ok = $true
            pools = @([ordered]@{
                    poolId = 'lab'; poolGuid = ('42' + ('1' * 30)); displayName = 'Lab'; members = @()
                    repositories = [ordered]@{
                        frameworkUrl = 'https://example.test/framework'; projectUrl = 'https://example.test/project'
                    }
                })
        }
        $saveDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolPoolsPage -State $state `
                    -ProjectUrl 'https://example.test/other' -MutationFailureDetail "save $attack spoof"))
        Assert-True ($saveDom -match ('>Save failed: ' + [regex]::Escape([string]$start + 'save  spoof' + $end) + '</div>')) `
            'the Pools save failure detail escaped its bidi isolate'

        $hostsDom = Invoke-PoolPseudoPage -Locale 'qps-Ploc' -Direction 'ltr' -FullDocument
        $expectedFailure = Format-CatalogMessage -Key 'pool.aggregator_unavailable_value1_control_state_is_unknown_moving_hos' `
            -Arguments @{ value1 = ([string]$start + 'aggregate  spoof' + $end) } -Locale 'qps-Ploc'
        Assert-True ($hostsDom.Contains($expectedFailure)) `
            'the hosts aggregator failure detail escaped its bidi isolate'
    }
}

Describe 'product globalization acceptance' {
    It 'globalization acceptance: every pool and aggregator state' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/extension/ui-pages.test.js'
        Invoke-ProductGlobalizationCheck -Kind Go -Path 'test/extension/pool-aggregator-service'
    }
    It 'globalization acceptance: all framework project compatibility pairs' {
        Invoke-ProductGlobalizationCheck -Kind Go -Path 'test/extension/pool-control-service'
    }
}
