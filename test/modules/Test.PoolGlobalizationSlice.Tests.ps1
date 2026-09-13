<#PSScriptInfo
.VERSION 2026.09.13
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
    floor request adapter, and generated pseudo catalogs.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:WebRoot = Join-Path $script:RepoRoot 'test/extension/pool-control-service/server/internal/httpsrv/web'
$script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
$script:Chrome = $null
foreach ($name in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) { $script:Chrome = $command.Source; break }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-pool-globalization-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
foreach ($relative in @(
    'test/extension/extension-sdk/webui/assets/yuruna.core.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/common.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/hosts.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/board.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Ploc.pool.js'
    'test/extension/pool-control-service/server/internal/httpsrv/web/assets/qps-Plocm.pool.js'
)) {
    $source = Join-Path $script:RepoRoot $relative
    Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "$relative is not shipped"
    Copy-Item -LiteralPath $source -Destination (Join-Path $script:Sandbox (Split-Path -Leaf $source)) -Force
}

$script:OfficialProjectEnglish = ''
$script:OfficialProjectPseudo = ''
$script:BoardBoundaryPayload = $null
if ($script:Chrome -and
    (Test-Path -LiteralPath (Join-Path $script:ProjectRoot 'test/test.runner.yml') -PathType Leaf)) {
    $pseudoFixturePath = Join-Path $script:Sandbox 'project-pseudo.json'
    $mapTool = Join-Path $script:RepoRoot 'tools/Invoke-ProjectLocaleMap.ps1'
    $mapOutput = & pwsh -NoProfile -File $mapTool -ProjectRoot $script:ProjectRoot `
        -PseudoFixturePath $pseudoFixturePath -Quiet 2>&1 | Out-String
    Assert-Equal -Expected 0 -Actual $LASTEXITCODE `
        "the official project could not produce a source-current pseudo fixture: $mapOutput"

    $pseudoFixture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($pseudoFixturePath)) -AsHashtable
    $displayEntry = @($pseudoFixture.entries |
        Where-Object fieldPath -EQ '/testSets/name=smoke/displayName')[0]
    if ($displayEntry) {
        $script:OfficialProjectEnglish = [string]$displayEntry.scalar
        $script:OfficialProjectPseudo = [string]$displayEntry.localized.'qps-Ploc'
    }

    $boundaryPath = Join-Path $script:Sandbox 'board-boundary.json'
    $goWorkPath = Join-Path $script:Sandbox 'go.work'
    $sdkPath = Join-Path $script:RepoRoot 'test/extension/extension-sdk'
    $serverPath = Join-Path $script:RepoRoot 'test/extension/pool-control-service/server'
    $goWork = "go 1.25.0`n`nuse (`n`t$sdkPath`n`t$serverPath`n)`n"
    [IO.File]::WriteAllText($goWorkPath, $goWork, [Text.UTF8Encoding]::new($false))

    $oldGoWork = $env:GOWORK
    $oldGoCache = $env:GOCACHE
    $oldPseudoFixture = $env:YURUNA_PROJECT_PSEUDO_FIXTURE
    $oldBoundaryOutput = $env:YURUNA_BOARD_BOUNDARY_OUTPUT
    $oldPseudoLocale = $env:YURUNA_PROJECT_PSEUDO_LOCALE
    try {
        $env:GOWORK = $goWorkPath
        $env:GOCACHE = Join-Path $script:Sandbox 'go-cache'
        $env:YURUNA_PROJECT_PSEUDO_FIXTURE = $pseudoFixturePath
        $env:YURUNA_BOARD_BOUNDARY_OUTPUT = $boundaryPath
        $env:YURUNA_PROJECT_PSEUDO_LOCALE = 'qps-Ploc'
        Push-Location $serverPath
        try {
            $goOutput = & go test ./internal/httpsrv `
                -run '^TestWriteOfficialProjectLocaleBoundaryFixture$' -count=1 2>&1 | Out-String
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE `
                "the real pool /api/board boundary fixture failed: $goOutput"
        }
        finally { Pop-Location }
    }
    finally {
        $env:GOWORK = $oldGoWork
        $env:GOCACHE = $oldGoCache
        $env:YURUNA_PROJECT_PSEUDO_FIXTURE = $oldPseudoFixture
        $env:YURUNA_BOARD_BOUNDARY_OUTPUT = $oldBoundaryOutput
        $env:YURUNA_PROJECT_PSEUDO_LOCALE = $oldPseudoLocale
    }
    if (Test-Path -LiteralPath $boundaryPath -PathType Leaf) {
        $script:BoardBoundaryPayload = ConvertFrom-Json -InputObject (
            [IO.File]::ReadAllText($boundaryPath)) -AsHashtable
    }
}

function Invoke-PoolPseudoPage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Locale,
        [Parameter(Mandatory)][ValidateSet('ltr', 'rtl')][string]$Direction,
        [switch]$FullDocument
    )

    $transport = @'
<script>
(function () {
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  try { delete Object.assign; } catch (e) {}
  try { delete Number.isFinite; } catch (e) {}
  Number.prototype.toLocaleString = function () { return String(this); };
  window.XMLHttpRequest = function () {
    var self = this;
    this.open = function (method, url) { self.url = url; };
    this.setRequestHeader = function () {};
    this.abort = function () { if (self.onabort) { self.onabort(); } };
    this.send = function () {
      var data;
      if (self.url === '/api/hosts') {
        data = { ok: true, pools: ['lab'], targetPoolId: '', hostnamesVisible: false,
          statusError: 'aggregate \u2069\u202E spoof',
          hosts: [{ hostId: '42cc', hostname: '', type: 'ubuntu.kvm', control: 'ready', access: 'denied', pool: 'lab' }] };
      } else if (self.url === '/api/hosts/facts') {
        data = { ok: true, hosts: { '42cc': { ok: true,
          frameworkAccess: 'repo \u2069\u202E spoof', frameworkAccessState: 'readable',
          frameworkUrl: 'https://example.test/framework/\u2069\u202E/spoof',
          projectAccess: 'No access', projectAccessState: 'denied',
          projectUrl: 'https://example.test/project/\u2069\u202E/spoof' } } };
      } else if (self.url === '/api/hostinfo') {
        data = { ok: true, goBaseUrl: '' };
      } else {
        data = { ok: false, error: 'unexpected request ' + self.url };
      }
      self.status = data.ok === false ? 500 : 200;
      self.statusText = data.ok === false ? 'Error' : 'OK';
      self.responseText = JSON.stringify(data);
      window.setTimeout(function () { if (self.onload) { self.onload(); } }, 0);
    };
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

    $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
        --virtual-time-budget=5000 --dump-dom "file://$path" 2>$null | Out-String
    if ($FullDocument) { return [Net.WebUtility]::HtmlDecode($dom) }
    $match = [regex]::Match($dom, '(?s)<tbody id="host-rows">(.*?)</tbody>')
    if (-not $match.Success) { return '' }
    return [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
}

function Invoke-PoolBoardPage {
    <#
    .SYNOPSIS
        Render the shipped board against a server-boundary fixture.
    .DESCRIPTION
        The Go tests prove locale-map selection at the HTTP boundary. This
        browser pass begins at that boundary and proves the returned project
        label survives the shipped core/common/board stack into textContent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Payload,
        [switch]$ExerciseConfirmation,
        [AllowEmptyString()][string]$BoardFailureDetail,
        [AllowEmptyString()][string]$AssignmentFailureDetail,
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
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  window.XMLHttpRequest = function () {
    var self = this;
    this.open = function (method, url) { self.url = url; };
    this.setRequestHeader = function () {};
    this.abort = function () { if (self.onabort) { self.onabort(); } };
    this.send = function () {
      var data;
      if (self.url.indexOf('/api/board?') === 0) {
        data = $boardReply;
      } else if (self.url === '/api/hostinfo') {
        data = { ok: true, goBaseUrl: '' };
      } else {
        data = { ok: false, error: 'unexpected request ' + self.url };
      }
      self.status = data.ok === false ? 500 : 200;
      self.statusText = data.ok === false ? 'Error' : 'OK';
      self.responseText = JSON.stringify(data);
      window.setTimeout(function () { if (self.onload) { self.onload(); } }, 0);
    };
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
    if ($AssignmentFailureDetail) {
        $assignmentJson = ConvertTo-Json -InputObject $AssignmentFailureDetail -Compress
        $failureHarness = @"
<script>
window.alert = function (message) {
  var capture = document.createElement('p');
  capture.id = 'alert-capture';
  capture.textContent = message;
  document.body.appendChild(capture);
};
Y.mutate = function () { return Promise.reject({ message: $assignmentJson }); };
</script>
"@
        $html = $html.Replace('<script src="common.js"></script>',
            '<script src="common.js"></script>' + "`n" + $failureHarness.Trim())
    }
    if ($ExerciseConfirmation) {
        $confirmation = @'
<script>
window.setTimeout(function () {
  var select = document.querySelector('#cards select');
  if (!select || select.options.length < 2) { return; }
  select.value = select.options[1].value;
  var changed = document.createEvent('HTMLEvents');
  changed.initEvent('change', true, false);
  select.dispatchEvent(changed);
}, 100);
</script>
'@
        if ($AssignmentFailureDetail) {
            $confirmation += @'
<script>
window.setTimeout(function () { document.getElementById('confirm-ok').click(); }, 250);
</script>
'@
        }
        $html = $html.Replace('<script src="board.js"></script>',
            '<script src="board.js"></script>' + "`n" + $confirmation.Trim())
    }
    $path = Join-Path $script:Sandbox 'project-label-board.html'
    [IO.File]::WriteAllText($path, $html)
    return (& $script:Chrome --headless --disable-gpu --no-sandbox `
        --virtual-time-budget=5000 --dump-dom "file://$path" 2>$null | Out-String)
}
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'the pool repository-access slice renders through shipped pseudo assets' {

    It 'renders the stable denied state in expanded and mirrored pseudo at the browser floor' {
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
        }
    }
}

Describe 'the shipped board renders the project locale-map result' {

    It 'puts the official pseudo-map boundary label in the DOM and keeps the English scalar fallback' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }
        if (-not $script:OfficialProjectEnglish -or -not $script:OfficialProjectPseudo -or
            -not $script:BoardBoundaryPayload) {
            Set-ItResult -Skipped -Because 'the adjacent yuruna-project pseudo-map boundary fixture is not available'
            return
        }

        # Both strings came through the real Go /api/board handler. Its host
        # registration consumed the ephemeral qps map generated from the
        # official scalar; the second registration deliberately has no map and
        # proves the supported old-project fallback at the same boundary.
        $dom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage `
            -Payload $script:BoardBoundaryPayload -Locale 'qps-Ploc' -Direction 'ltr'))
        $start = [char]0x2068
        $end = [char]0x2069
        Assert-True ($dom.Contains('<strong>' + $start + $script:OfficialProjectPseudo + $end + '</strong>')) `
            'the actual yuruna-project pseudo label did not reach the rendered assigned-set DOM'
        Assert-True ($dom.Contains('<option value="yuruna-project.smoke">' +
                $script:OfficialProjectPseudo + '</option>')) `
            'the actual yuruna-project pseudo label did not reach the rendered picker DOM'
        Assert-True ($dom.Contains('<strong>' + $start + $script:OfficialProjectEnglish + $end + '</strong>')) `
            'the old-project/missing-map English scalar fallback disappeared in the browser'
        Assert-False ($dom.Contains('<strong>' + $start + 'yuruna-project.smoke' + $end + '</strong>')) `
            'the browser fell through to the machine key despite receiving a human label'

        $picker = [regex]::Match($dom, '<select aria-label="([^"]+)"')
        Assert-True $picker.Success 'the rendered project picker has no accessible name'
        Assert-True ($picker.Groups[1].Value.StartsWith('[')) `
            'the picker accessible name did not come from the selected pseudo catalog'
        Assert-False ($picker.Groups[1].Value.Contains('Test set for ')) `
            'the picker accessible name remained hard-coded English under pseudo'
        Assert-True ($picker.Groups[1].Value.Contains($start + 'Localized project' + $end)) `
            'the external pool name was not isolated inside the localized accessible name'

        $boardSource = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'assets/board.js'))
        Assert-True ($boardSource.Contains("t('pool.test_set_label'")) `
            'the production board renderer does not use the catalog key for the picker name'
        Assert-False ($boardSource.Contains("'aria-label': 'Test set for '")) `
            'the production board renderer still carries the English aria-label literal'
    }

    It 'isolates every project/operator value inside a destructive confirmation' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $attack = [string]([char]0x2069) + [char]0x202e
        $poolName = "Pool $attack unsafe"
        $offerName = "Offer $attack unsafe"
        $projectUrl = "https://example.test/$attack/unsafe"
        $safePoolName = 'Pool  unsafe'
        $safeOfferName = 'Offer  unsafe'
        $safeProjectUrl = 'https://example.test//unsafe'
        $payload = [ordered]@{
            ok = $true; range = '24h'; statsError = ''
            cards = @([ordered]@{
                    poolId = 'hostile'; displayName = $poolName; hostsTotal = 1
                    hostsReporting = 1; successPct = 100; total = 1; failed = 0
                    testSet = ''; testSetLabel = ''; assignAllowed = $true
                    assignDisabledDetail = ''; blocked = @()
                })
            offers = @([ordered]@{
                    name = 'hostile.offer'; displayName = $offerName
                    frameworkUrl = 'https://example.test/yuruna'; projectUrl = $projectUrl
                })
        }

        $dom = [Net.WebUtility]::HtmlDecode(
            (Invoke-PoolBoardPage -Payload $payload -ExerciseConfirmation))
        $start = [char]0x2068
        $end = [char]0x2069
        Assert-True ($dom.Contains('Assign "' + $start + $safeOfferName + $end +
                '" to ' + $start + $safePoolName + $end + '?')) `
            'the confirmation title left a project or pool name outside a bidi isolate'
        Assert-True ($dom.Contains('1 host will switch to ' + $start + $safeProjectUrl + $end +
                ' on their next cycle.')) `
            'the confirmation body left the project URL outside a bidi isolate'
        Assert-True ($dom.Contains('aria-label="Test set for ' + $start + $safePoolName + $end + '"')) `
            'the project picker accessible name left its pool value outside a bidi isolate'
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
                    testSet = ''; testSetLabel = ''; assignAllowed = $true
                    assignDisabledDetail = ''; blocked = @()
                })
            offers = @([ordered]@{
                    name = 'proj.smoke'; displayName = 'Smoke'
                    frameworkUrl = 'https://example.test/yuruna'; projectUrl = 'https://example.test/project'
                })
        }
        $start = [char]0x2068
        $end = [char]0x2069

        $statsDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage -Payload $payload))
        Assert-True ($statsDom.Contains('Live numbers unavailable (' + $start + 'stats  spoof' + $end +
                '). Assigning still works.')) `
            'the board stats failure detail escaped its bidi isolate'

        $loadDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage -Payload $payload `
                    -BoardFailureDetail "load $attack spoof"))
        Assert-True ($loadDom.Contains('Could not load the board: ' + $start + 'load  spoof' + $end +
                '. Retrying on the next refresh.')) `
            'the board load failure detail escaped its bidi isolate'

        $assignDom = [Net.WebUtility]::HtmlDecode((Invoke-PoolBoardPage -Payload $payload `
                    -ExerciseConfirmation -AssignmentFailureDetail "assign $attack spoof"))
        Assert-True ($assignDom.Contains('id="alert-capture">Could not assign: ' + $start +
                'assign  spoof' + $end + '</p>')) `
            'the assignment failure detail escaped its bidi isolate'

        $hostsDom = Invoke-PoolPseudoPage -Locale 'qps-Ploc' -Direction 'ltr' -FullDocument
        Assert-True ($hostsDom.Contains('Aggregator unavailable (' + $start + 'aggregate  spoof' + $end +
                '); control state is unknown. Moving hosts still works.')) `
            'the hosts aggregator failure detail escaped its bidi isolate'
    }
}
