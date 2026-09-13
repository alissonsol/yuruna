<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42e19a4c-5b73-4c81-9f26-3d0a8b7e6c15
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization catalog browser es5 pester
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
    Hold the browser catalog kernel to the floor it claims, and hold every
    runtime that formats a value to one answer.
.DESCRIPTION
    The kernel is copied into two browser runtimes so that a page spends no
    request on it. Two copies of a file diverge the moment someone edits the
    near one, so the first thing checked here is that both copies are still the
    source they came from.

    The second is agreement. A count rendered by a PowerShell command lands in
    a transcript, the same count rendered by the kernel lands on the page above
    it, and a reader comparing the two cannot tell a formatting difference from
    a real one. Both run the same fixture, and the fixture states the answer
    rather than recording what either currently produces.

    The third is the floor. The kernel is rendered by a browser with Intl,
    normalize, fetch and AbortController removed and with toLocaleString made
    locale-blind, which is what Safari 9.0 actually offers. Testing the
    capability rather than a version label is the point: a page that renders
    only because the test browser is modern proves nothing about the floor.

    Run: Invoke-Pester -Path test/modules/Test.BrowserCatalogKernel.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:KernelPath = Join-Path $script:RepoRoot 'globalization/kernel/yuruna.i18n.js'
$script:EmbedTool = Join-Path $script:RepoRoot 'tools/Invoke-CatalogEmbed.ps1'
$script:Fixture = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
    (Join-Path $script:RepoRoot 'globalization/fixtures/format-agreement.json')))

# Every browser runtime that carries the kernel. A page loads exactly one
# script, so the kernel has to be inside whichever one that page loads.
$script:Runtimes = @(
    'test/status/yuruna.common.js'
    'test/extension/extension-sdk/webui/assets/yuruna.core.js'
)

$script:Chrome = $null
foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $script:Chrome = $c.Source; break }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-kernel-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'the kernel is one file, copied' {

    It 'is embedded in every runtime, unmodified' {
        $kernel = ([IO.File]::ReadAllText($script:KernelPath)).TrimEnd() -replace "`r`n", "`n"
        $findings = @()
        foreach ($rel in $script:Runtimes) {
            $path = Join-Path $script:RepoRoot $rel
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                $findings += "$rel does not exist"
                continue
            }
            $text = [IO.File]::ReadAllText($path) -replace "`r`n", "`n"
            if ($text.IndexOf($kernel) -lt 0) {
                $findings += "$rel carries a kernel that is not the one in globalization/kernel"
            }
        }
        Assert-NoFinding $findings 'a runtime was edited in place rather than regenerated'
    }

    It 'reports nothing to do, so the shipped copies match their sources' {
        # The same check the gate runs. A failure here means the kernel or a
        # catalog changed and the runtimes were not regenerated.
        & pwsh -NoProfile -File $script:EmbedTool -Check -Quiet 2>&1 | Out-Null
        Assert-Equal -Expected 0 -Actual $LASTEXITCODE `
            'run tools/Invoke-CatalogEmbed.ps1 to bring the runtimes back in line with the kernel and the catalogs'
    }

    It 'carries the default locale so no page waits on a request to render' {
        # The reason the kernel is embedded rather than fetched: a label that
        # arrives after the paint it belonged to is a flash of nothing.
        $findings = @()
        foreach ($rel in $script:Runtimes) {
            $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $rel))
            if ($text -notmatch "registry\['en-US'\]") { $findings += "$rel has no resident en-US table" }
            if ($text -notmatch 'YurunaLocaleData') { $findings += "$rel has no locale data" }
        }
        Assert-NoFinding $findings 'a runtime would have to fetch before it could render its first label'
    }

    It 'separates selectable locale authority from planned formatting data' {
        foreach ($rel in $script:Runtimes) {
            $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $rel))
            Assert-Match -Pattern 'YurunaEnabledLocales' -Actual $text `
                "$rel has no generated locale-selection authority"
        }
    }
}

Describe 'every runtime writes a value the same way' {

    It 'renders the shared fixture identically in PowerShell' {
        $findings = @()
        foreach ($case in $script:Fixture.cases) {
            $actual = Format-CatalogArgument -Value $case.value -Type $case.type -Locale $case.locale
            if ($actual -cne $case.expect) {
                $findings += "$($case.name): PowerShell wrote '$actual', the contract says '$($case.expect)'"
            }
        }
        Assert-NoFinding $findings 'the PowerShell renderer disagrees with the shared formatting contract'
    }

    It 'renders the shared fixture identically in a browser with no Intl' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        # The floor preamble removes what Safari 9.0 lacks and makes
        # toLocaleString answer in the browser's own locale regardless of its
        # argument, which is what the floor actually does. A kernel that leaned
        # on any of these would fail here rather than on a reader's phone.
        $preamble = @'
(function () {
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
  try { delete Object.assign; } catch (e) {}
  try { delete Array.prototype.includes; } catch (e) {}
  try { delete Array.prototype.find; } catch (e) {}
  try { delete String.prototype.padStart; } catch (e) {}
  Number.prototype.toLocaleString = function () { return String(this); };
  Date.prototype.toLocaleString = function () { return this.toString(); };
}());
'@

        $cases = ConvertTo-Json -InputObject @($script:Fixture.cases) -Depth 6
        $findings = @()

        foreach ($rel in $script:Runtimes) {
            $source = Join-Path $script:RepoRoot $rel
            $name = Split-Path -Leaf $source
            Copy-Item -LiteralPath $source -Destination (Join-Path $script:Sandbox $name) -Force

            $page = @"
<!doctype html><html lang="en-US"><head><meta charset="utf-8"><title>k</title>
<script>$preamble</script></head><body><pre id="out"></pre>
<script src="$name"></script>
<script>
(function () {
  var Y = window.YurunaI18n, cases = $cases, rows = [];
  if (!Y) { document.getElementById('out').textContent = 'NOKERNEL'; return; }
  for (var i = 0; i < cases.length; i++) {
    var c = cases[i];
    rows.push(c.name + '\t' + Y.formatArgument(c.value, c.type, c.locale));
  }
  document.getElementById('out').textContent = rows.join('\n');
}());
</script></body></html>
"@
            $pagePath = Join-Path $script:Sandbox "agree-$name.html"
            [IO.File]::WriteAllText($pagePath, $page)

            $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
                --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String

            # Read the element, never the whole dump. --dump-dom echoes the
            # page's own inline script back, so a sentinel searched for across
            # the dump always finds the line that would have written it.
            $m = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
            if (-not $m.Success) {
                $findings += "$rel rendered no output at all, so its parse failed at the floor"
                continue
            }
            if ($m.Groups[1].Value.Trim() -eq 'NOKERNEL') {
                $findings += "$rel did not define the kernel when loaded as a page's only script"
                continue
            }
            $rendered = @{}
            foreach ($line in ($m.Groups[1].Value -split "`n")) {
                $parts = $line -split "`t", 2
                if ($parts.Count -eq 2) {
                    # The DOM dump is HTML, so the text arrives entity-encoded.
                    $rendered[[Net.WebUtility]::HtmlDecode($parts[0].Trim())] = [Net.WebUtility]::HtmlDecode($parts[1])
                }
            }
            foreach ($case in $script:Fixture.cases) {
                if (-not $rendered.ContainsKey($case.name)) {
                    $findings += "${rel}: '$($case.name)' rendered nothing"
                    continue
                }
                if ($rendered[$case.name] -cne $case.expect) {
                    $findings += "${rel}: '$($case.name)' wrote '$($rendered[$case.name])', the contract says '$($case.expect)'"
                }
            }
        }
        Assert-NoFinding $findings 'a browser runtime disagrees with the shared formatting contract at the floor'
    }
}

Describe 'the kernel renders a page at the floor' {

    It 'seals a pseudo context before its separately loaded catalog arrives' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/extension/extension-sdk/webui/assets/yuruna.core.js') `
            -Destination (Join-Path $script:Sandbox 'late-runtime.js') -Force
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/status/qps-Ploc.status.js') `
            -Destination (Join-Path $script:Sandbox 'late-pseudo.js') -Force
        $page = @'
<!doctype html><html lang="qps-Ploc" dir="ltr" data-yuruna-requested-language="qps-Ploc" data-yuruna-locale-source="http"><head><meta charset="utf-8"><title>late</title></head>
<body><pre id="out">PENDING</pre>
<script src="late-runtime.js"></script>
<script>
window.beforePseudoAsset = {
  locale: window.YurunaI18n.context().resolvedTag,
  text: window.YurunaI18n.t('status.cycle_paused')
};
</script>
<script src="late-pseudo.js"></script>
<script>
(function () {
  var Y = window.YurunaI18n, after = Y.t('status.cycle_paused'), rows = [];
  rows.push('beforeLocale=' + window.beforePseudoAsset.locale);
  rows.push('beforeFallback=' + window.beforePseudoAsset.text);
  rows.push('afterPseudo=' + after);
  rows.push('planned=' + Y.resolve('pt-BR'));
  document.getElementById('out').textContent = rows.join('\n');
}());
</script></body></html>
'@
        $path = Join-Path $script:Sandbox 'late-catalog.html'
        [IO.File]::WriteAllText($path, $page)
        $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
            --virtual-time-budget=5000 --dump-dom "file://$path" 2>$null | Out-String
        $match = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
        Assert-True $match.Success 'the late-catalog page rendered no result'
        $text = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        Assert-True ($text.Contains('beforeLocale=qps-Ploc')) `
            'catalog script timing changed the server-owned page locale'
        Assert-True ($text.Contains('beforeFallback=Paused, waiting for resume.')) `
            'a not-yet-loaded pseudo table did not fall back to resident English'
        Assert-True ($text -match '(?m)^afterPseudo=\[' -and $text -notmatch '(?m)^afterPseudo=Paused,') `
            'the separately loaded pseudo table never became active'
        Assert-True ($text.Contains('planned=en-US')) `
            'planned pt-BR became selectable merely because localeData carries it'
    }

    It 'looks up, pluralizes and falls back with the floor APIs gone' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }

        $name = 'yuruna.common.js'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'test/status/yuruna.common.js') `
            -Destination (Join-Path $script:Sandbox $name) -Force

        # The checks a page actually depends on: the resident table answers, a
        # count picks its form, an unsupported tag cannot select a catalog, and
        # a key nothing declares shows as itself rather than as blank text.
        $page = @"
<!doctype html><html lang="en-US" data-yuruna-requested-language="en-US" data-yuruna-locale-source="http"><head><meta charset="utf-8"><title>k</title>
<script>
(function () {
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
}());
</script></head><body><pre id="out"></pre>
<script src="$name"></script>
<script>
(function () {
  var Y = window.YurunaI18n, rows = [];
  function check(label, got, want) { rows.push((got === want ? 'OK' : 'FAIL') + '\t' + label + '\tgot=' + got + '\twant=' + want); }
  check('init reads the served lang', Y.init(document), 'en-US');
  check('a literal message', Y.t('status.cycle_paused'), 'Paused, waiting for resume.');
  check('one takes the singular', Y.t('status.host_online_count', {count: 1}), '1 host online.');
  check('four takes the plural', Y.t('status.host_online_count', {count: 4}), '4 hosts online.');
  check('zero is plural in English', Y.t('status.host_online_count', {count: 0}), '0 hosts online.');
  check('an argument is grouped', Y.t('status.host_online_count', {count: 1234567}), '1,234,567 hosts online.');
  check('a duration floors', Y.t('status.cycle_duration', {elapsed: 5400}), 'Duration: 1h 30m');
  check('external text is placed as given', Y.t('status.external_detail', {detail: 'Connection refused'}), 'The tool reported: Connection refused');
  check('a missing key shows as itself', Y.t('status.no_such_key'), 'status.no_such_key');
  check('a traversal cannot select a catalog', Y.resolve('../../etc'), 'en-US');
  check('an unresident alias falls back', Y.resolve('pt'), 'en-US');
  check('case is not significant', Y.resolve('EN-us'), 'en-US');
  check('direction comes from the manifest', Y.direction(), 'ltr');
  var context = Y.context();
  check('context carries the request winner', context.requestedTag, 'en-US');
  check('context carries the server result', context.resolvedTag, 'en-US');
  check('context carries the selection source', context.source, 'http');
  check('context names the browser time policy', context.timeZone, 'local');
  check('context carries catalog version', context.catalogVersion.length > 0, true);
  check('context carries catalog hash', /^[0-9a-f]{64}$/.test(context.catalogHash), true);
  context.resolvedTag = 'qps-Ploc';
  check('context is immutable', context.resolvedTag, 'en-US');
  check('late locale changes are refused', Y.setLocale('qps-Ploc'), 'en-US');
  check('the floor really has no Intl', typeof window.Intl, 'undefined');
  document.getElementById('out').textContent = rows.join('\n');
}());
</script></body></html>
"@
        $pagePath = Join-Path $script:Sandbox 'floor.html'
        [IO.File]::WriteAllText($pagePath, $page)

        $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
            --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String

        $m = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
        Assert-True $m.Success 'the page rendered nothing, so the runtime failed to parse at the floor'

        $findings = @()
        $seen = 0
        foreach ($line in ($m.Groups[1].Value -split "`n")) {
            $text = [Net.WebUtility]::HtmlDecode($line).Trim()
            if (-not $text) { continue }
            $seen++
            if ($text.StartsWith('FAIL')) { $findings += ($text -replace "`t", ' ') }
        }
        Assert-True ($seen -ge 22) "only $seen checks ran, so the page stopped partway"
        Assert-NoFinding $findings 'the kernel behaves differently once the floor is actually emulated'
    }
}
