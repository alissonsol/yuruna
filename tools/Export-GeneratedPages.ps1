<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42df925f-3353-4a16-aae2-7e8a097c522c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna accessibility wcag fixture generated html test
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
    Materialize the HTML this project GENERATES into files a browser gate can
    open, so the generated surfaces are measured the way the static ones are.
.DESCRIPTION
    Invoke-A11yCheck serves directories of .html files. Five of this project's
    web surfaces are not .html files and never were:

      - two service UIs that live as Go raw-string constants,
      - the per-cycle test transcript, assembled by a PowerShell module,
      - the log directory listing, built by a string builder inside the
        status-service template,
      - the html part of the cycle-failure notification email.

    There is no file to find, so any gate that only reads files misses these
    surfaces entirely; this script writes what those code paths produce.

    Every page here comes from the SHIPPING code path, not a transcription of
    it. The Go constants are extracted from the source; the transcript is
    written by the real log tee; the directory listing is the template's own
    block, unescaped and executed. A hand-copied fixture would drift from the
    code the day after it was written, and would then certify a page nobody
    serves.

    The one deliberate substitution is the data source. Both Go pages request
    rows from a daemon that is not running here, so the canonical request
    adapter is replaced, after it has loaded, with a fixture transport that
    answers with a representative payload -- including the pathological
    values that matter for reflow. The exporter never creates a missing
    browser global: doing that would make a page appear compatible because its
    test supplied a production prerequisite.
.PARAMETER OutputDirectory
    Where to write the pages. Defaults to a new folder under the temp path.
    The directory is created if missing and its .html files are replaced.
.PARAMETER Quiet
    Suppress the per-file progress lines; the directory path is still emitted.
.OUTPUTS
    The absolute path of the directory holding the generated pages.
.EXAMPLE
    pwsh tools/Invoke-A11yCheck.ps1 -Serve (pwsh tools/Export-GeneratedPages.ps1 -Quiet)
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The log tee reads $global:__YurunaLogFile to decide where to append; pointing it at a fixture is the documented way to drive it, and a narrower scope would not reach the module.')]
param(
    [string]$OutputDirectory,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$script:Announce = -not $Quiet
function Write-Line { param([string]$Text) if ($script:Announce) { Write-Information $Text -InformationAction Continue } }

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-generated-pages-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

# --- REGION: Go raw-string pages
function Get-GoRawStringConstant {
    <#
    .SYNOPSIS
        Return the body of a Go raw-string constant.
    .DESCRIPTION
        The pages are `const <Name> = ` + backtick-delimited raw string. A raw
        string cannot contain a backtick, so the first one after the opening
        delimiter is unambiguously the close -- no escape handling needed.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    $text = [IO.File]::ReadAllText($Path)
    $marker = "const $Name = ``"
    $start = $text.IndexOf($marker, [StringComparison]::Ordinal)
    if ($start -lt 0) { throw "no raw-string constant '$Name' in $Path" }
    $bodyAt = $start + $marker.Length
    $end = $text.IndexOf('`', $bodyAt)
    if ($end -lt 0) { throw "unterminated raw-string constant '$Name' in $Path" }
    return $text.Substring($bodyAt, $end - $bodyAt)
}

function Add-FailingRequestTransport {
    <#
    .SYNOPSIS
        Replace the canonical request function with a rejecting fixture.
    .DESCRIPTION
        Both pages carry a visible error state -- a banner saying the values
        below are from the last successful read -- and a stub that always
        succeeded meant that text was never rendered, never measured for
        contrast, and never checked for the shape a screen reader gets. An
        outage is exactly when an operator reads this page, so it is exactly
        the state that has to be legible.
    #>
    param([Parameter(Mandatory)][string]$Html)

    if (($Html -split '<script>').Count -lt 2) { throw 'expected at least one <script> in the page' }
    $stub = @'
<script>
window.yurunaRequest = function () { return Promise.reject(new Error('exported failure state')); };
</script>
'@
    $at = $Html.IndexOf('</script>', [StringComparison]::OrdinalIgnoreCase)
    if ($at -lt 0) { throw 'expected the request adapter script in the page' }
    $after = $at + '</script>'.Length
    return $Html.Insert($after, "`n$stub")
}

function Add-RequestTransport {
    <#
    .SYNOPSIS
        Replace the canonical request function with a fixture transport.
    .DESCRIPTION
        Placed after the adapter and before the page script: the page calls
        refresh() at parse time, so a fixture defined later would never be
        reached. Installing `window.fetch` here used to make the adapter's
        feature test positive even on a capability-off page, masking exactly
        the compatibility defect the generated-page gate is meant to expose.
    #>
    param([Parameter(Mandatory)][string]$Html, [Parameter(Mandatory)][string]$Json)

    # The page carries two script blocks: the request adapter the service
    # splices in, and the page's own. Override only the adapter's public seam;
    # never supply fetch, XMLHttpRequest, Promise, or another browser global.
    if (($Html -split '<script>').Count -lt 2) { throw 'expected at least one <script> in the page' }
    $stub = @"
<script>
window.yurunaRequest = function () {
  return Promise.resolve($Json);
};
</script>
"@
    $at = $Html.IndexOf('</script>', [StringComparison]::OrdinalIgnoreCase)
    if ($at -lt 0) { throw 'expected the request adapter script in the page' }
    $after = $at + '</script>'.Length
    return $Html.Insert($after, "`n$stub")
}

# A long URL and a long user-agent are the whole point of this row: they are the
# attacker-controlled fields the page's own header comment names, and they are
# what turns a nowrap cell into an unbounded page width.
$parserRows = @'
[
 {"ts_iso":"2026-08-22T09:14:02.511Z","client_ip":"192.168.7.61","status":"TCP_HIT/200","bytes":91234,
  "method":"GET","url":"http://archive.ubuntu.com/ubuntu/pool/main/l/linux/linux-image-unsigned-6.8.0-41-generic_6.8.0-41.41_amd64.deb?verylongqueryparameter=abcdefghijklmnopqrstuvwxyz0123456789",
  "ua":"Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0 SomeVeryLongProductToken/1.2.3"},
 {"ts_iso":"2026-08-22T09:14:03.002Z","client_ip":"192.168.7.62","status":"TCP_MISS/404","bytes":512,
  "method":"GET","url":"http://example.invalid/missing","ua":"curl/8.5.0"},
 {"ts_iso":"2026-08-22T09:14:03.884Z","client_ip":"192.168.7.63","status":"TCP_DENIED/403","bytes":0,
  "method":"CONNECT","url":"blocked.invalid:443","ua":"-"}
]
'@

$proxyStatus = @'
{"mode":"local",
 "squid":{"reachable":true,"version":"7.2","uptimeSeconds":48213,"requestsTotal":184223,
          "hitRatioPct":63.4,"cacheSizeKB":4194304,"memoryUsageKB":262144,
          "memCacheSizeKB":65536,"fileDescriptorsInUse":42},
 "switches":{"offline":false,"noUpstream":true,"source":"/etc/yuruna/proxy.switches",
             "detail":"upstream suppressed by operator"},
 "registry":{"reachable":true,"repositories":11,"canaryOk":true,"canaryLatencySeconds":0.06,
             "prewarmLastRun":"2026-08-22T01:44:25Z","prewarmHeld":9,"prewarmTotal":9}}
'@

$goPages = @(
    @{ File = 'caching-proxy-parser-ui.html'
       Source = 'test/extension/caching-proxy-parser-service/parse.go'
       Adapter = 'test/extension/caching-proxy-parser-service/requestadapter.go'; Json = $parserRows }
    @{ File = 'caching-proxy-ui.html'
       Source = 'test/extension/caching-proxy-service/ui.go'
       Adapter = 'test/extension/caching-proxy-service/requestadapter.go'; Json = $proxyStatus }
)
foreach ($p in $goPages) {
    # The served document, not the constant it is built from. The service
    # splices its request adapter into the head before sending, and a gate that
    # measured the pre-splice constant would be measuring a page nobody gets --
    # including missing the adapter's own bytes and its script block.
    $html = Get-GoRawStringConstant -Path (Join-Path $RepoRoot $p.Source) -Name 'indexHTML'
    $adapter = Get-GoRawStringConstant -Path (Join-Path $RepoRoot $p.Adapter) -Name 'requestAdapterScript'
    $registryPath = Join-Path (Split-Path (Join-Path $RepoRoot $p.Source) -Parent) 'internal/catalog/registry.go'
    $registrySource = [IO.File]::ReadAllText($registryPath)
    $kernelMatch = [regex]::Match($registrySource, '(?m)^const BrowserKernel = ("(?:\\.|[^"\\])*")\s*$')
    if (-not $kernelMatch.Success) { throw "Generated browser kernel is missing from $registryPath" }
    $catalogKernel = ConvertFrom-Json -InputObject $kernelMatch.Groups[1].Value
    $adapter = [string]$catalogKernel + "`nwindow.YurunaI18n.init(document);`n" + $adapter
    # A plain string replace: -replace would read $ sequences in the adapter as
    # capture-group references and silently drop them.
    $html = $html.Replace('</head>', '<script>' + $adapter + "</script>`n</head>")
    $out = Join-Path $OutputDirectory $p.File
    [IO.File]::WriteAllText($out, (Add-RequestTransport -Html $html -Json $p.Json))
    Write-Line "  wrote $($p.File)  <- $($p.Source)"

    # The same page with its request refused, so the error banner is a measured
    # surface rather than text nobody has ever rendered.
    $failFile = $p.File -replace '\.html$', '-failed.html'
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $failFile), (Add-FailingRequestTransport -Html $html))
    Write-Line "  wrote $failFile  <- $($p.Source)"
}

# --- REGION: Globalization reference slices
# The ordinary accessibility sweep renders English source pages. These four
# pages keep the same shipped builders and assets but apply the server decision
# and fixture data for each pseudo locale, so reflow, contrast, direction and
# focus targets are measured on the expanded/RTL states operators will use to
# find untranslated or direction-sensitive code.
function ConvertTo-ReferencePageLocale {
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][ValidateSet('ltr', 'rtl')][string]$Direction,
        [Parameter(Mandatory)][string]$RuntimeTag,
        [Parameter(Mandatory)][string]$CatalogTag
    )

    if (-not $Html.Contains('<html lang="en">')) { throw 'reference page has no canonical html language marker' }
    if (-not $Html.Contains($RuntimeTag)) { throw "reference page has no runtime marker: $RuntimeTag" }
    $root = '<html lang="' + $Tag + '" dir="' + $Direction +
        '" data-yuruna-requested-language="' + $Tag + '" data-yuruna-locale-source="http">'
    $localized = $Html.Replace('<html lang="en">', $root)
    return $localized.Replace($RuntimeTag, $RuntimeTag + "`n" + $CatalogTag)
}

$statusSource = Join-Path $RepoRoot 'test/status'
foreach ($asset in @('yuruna.common.css', 'yuruna.common.js', 'qps-Ploc.status.js', 'qps-Plocm.status.js')) {
    Copy-Item -LiteralPath (Join-Path $statusSource $asset) -Destination (Join-Path $OutputDirectory $asset) -Force
}
$statusFixture = @'
<script>
(function () {
  var persisted = {
    code: 'sequence_paused_waiting_resume',
    label: '[2/11] workload.guest.example',
    line: '[2/11] workload.guest.example Paused (waiting for resume)'
  };
  function renderReference() {
    var target = document.getElementById('globalization-status-reference');
    target.textContent = window.Yuruna.actionText(persisted);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', renderReference);
  } else {
    renderReference();
  }
}());
</script>
'@
foreach ($locale in @(
        @{ Tag = 'qps-Ploc'; Direction = 'ltr' }
        @{ Tag = 'qps-Plocm'; Direction = 'rtl' })) {
    $tag = [string]$locale.Tag
    $statusHtml = [IO.File]::ReadAllText((Join-Path $statusSource 'index.html'))
    $statusHtml = $statusHtml.Replace('</main>', @'
  <section aria-labelledby="globalization-status-title">
    <h2 id="globalization-status-title">Reference state</h2>
    <p id="globalization-status-reference" data-yuruna-globalization-reference data-yuruna-pseudo-markers="2"></p>
  </section>
</main>
'@)
    $statusHtml = ConvertTo-ReferencePageLocale -Html $statusHtml -Tag $tag -Direction $locale.Direction `
        -RuntimeTag '<script src="yuruna.common.js"></script>' `
        -CatalogTag ("<script src=`"$tag.status.js`"></script>" + "`n" + $statusFixture.Trim())
    $statusName = "status-reference-$tag.html"
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $statusName), $statusHtml)
    Write-Line "  wrote $statusName  <- status/index.html + served $tag catalog"
}

$poolWeb = Join-Path $RepoRoot 'test/extension/pool-control-service/server/internal/httpsrv/web'
$poolAssetsOut = Join-Path $OutputDirectory 'assets'
$null = New-Item -ItemType Directory -Path $poolAssetsOut -Force
foreach ($asset in @('style.css', 'common.js', 'hosts.js', 'qps-Ploc.pool.js', 'qps-Plocm.pool.js')) {
    Copy-Item -LiteralPath (Join-Path $poolWeb "assets/$asset") -Destination (Join-Path $poolAssetsOut $asset) -Force
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'test/extension/extension-sdk/webui/assets/yuruna.core.js') `
    -Destination (Join-Path $poolAssetsOut 'yuruna.core.js') -Force

# The exported page opens from disk with no service behind it, so the routes the
# hosts builder reads are answered locally. Y.api is this runtime's request seam,
# the counterpart of window.yurunaRequest in the Go pages, and Y.hostInfo goes
# through it too, so overriding it covers every route the page asks for. No
# browser global is replaced: a fixture that supplied its own fetch would be
# measuring the stand-in rather than the page. The block is spliced in after the
# runtime defines Y and before the page script runs.
$poolTransport = @'
<script>
(function () {
  var FIXTURES = {
    '/api/hosts': { ok: true, pools: ['lab'], targetPoolId: '', hostnamesVisible: false,
      hosts: [{ hostId: '42cc', hostname: '', type: 'ubuntu.kvm', control: 'ready', access: 'denied', pool: 'lab' }] },
    '/api/hosts/facts': { ok: true, hosts: { '42cc': { ok: true,
      frameworkAccess: 'yuruna', frameworkAccessState: 'readable',
      projectAccess: '', projectAccessState: 'denied',
      projectUrl: 'https://example.test/private' } } },
    '/api/hostinfo': { ok: true, goBaseUrl: '' }
  };
  window.Y.api = function (path) {
    if (Object.prototype.hasOwnProperty.call(FIXTURES, path)) {
      return Promise.resolve(FIXTURES[path]);
    }
    return Promise.reject(new Error('unexpected fixture request ' + path));
  };
}());
</script>
'@
foreach ($locale in @(
        @{ Tag = 'qps-Ploc'; Direction = 'ltr' }
        @{ Tag = 'qps-Plocm'; Direction = 'rtl' })) {
    $tag = [string]$locale.Tag
    $poolHtml = [IO.File]::ReadAllText((Join-Path $poolWeb 'hosts.html'))
    $poolHtml = $poolHtml.Replace('<tbody id="host-rows">',
        '<tbody id="host-rows" data-yuruna-globalization-reference data-yuruna-pseudo-markers="1">')
    $poolHtml = $poolHtml.Replace('<script src="/assets/yuruna.core.js"></script>',
        '<script src="/assets/yuruna.core.js"></script>' + "`n" + $poolTransport.Trim())
    $poolHtml = ConvertTo-ReferencePageLocale -Html $poolHtml -Tag $tag -Direction $locale.Direction `
        -RuntimeTag '<script src="/assets/common.js"></script>' `
        -CatalogTag "<script src=`"/assets/$tag.pool.js`"></script>"
    $poolName = "pool-reference-$tag.html"
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $poolName), $poolHtml)
    Write-Line "  wrote $poolName  <- pool hosts builder + served $tag catalog"
}

# --- REGION: Per-cycle transcript
# Written by the real tee so the severity spans and the step-rule promotion are
# the shipped ones. A transcript transcribed by hand would assert nothing about
# the module that actually writes them.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Log.psm1') -Force -DisableNameChecking
$transcript = Join-Path $OutputDirectory 'cycle-transcript.html'
[IO.File]::WriteAllText($transcript, (Get-YurunaLogPreamble))

$savedLogFile = $global:__YurunaLogFile
$savedInfo = $global:InformationPreference
$savedWarn = $global:WarningPreference
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Log.psm1') -Force -Global -DisableNameChecking
try {
    $global:__YurunaLogFile = $transcript
    # Information has to stay Continue: the proxy appends only for a record that
    # actually flows, so silencing the preference silences the TRANSCRIPT too and
    # leaves a fixture with no step headings and no information lines -- one that
    # passes every check it should have failed. The console noise is dropped by
    # redirecting the stream instead, which is downstream of the append.
    $global:InformationPreference = 'Continue'
    $global:WarningPreference = 'SilentlyContinue'

    & {
        Write-Information '----- [1/3] initialize-lab -----'
        Write-Information 'VM inventory: 9 hosts, 0 degraded.'
        Write-Verbose 'ssh connect 192.168.7.42 in 0.4 s' -Verbose:$false
        Write-Information '----- [1/3] initialize-lab : PASS -----'
        Write-Information '----- [2/3] workload.guest.ubuntu.server.26.amisad-core.s001 -----'
        Write-Warning 'Cycle pass with 1 host address change(s) inside it.'
        # The sample has to be long enough to wrap and has to carry a real path,
        # and the fixture that records it rewrites this checkout's location to a
        # token. Spelling the location out instead would record one machine's
        # directory as content, and match only on that machine.
        Write-Information ('A line long enough to need wrapping: /usr/bin/env pwsh -NoProfile -File ' +
            (Join-Path $RepoRoot 'test/service/Start-StatusService.ps1') + ' -Port 8080 -RuntimeDir /var/lib/yuruna/runtime')
        Write-Information '----- [2/3] workload.guest.ubuntu.server.26.amisad-core.s001 : PASS -----'
        Write-Information '----- [3/3] finalize -----'
        Write-Error 'guest did not answer within 300 s' -ErrorAction SilentlyContinue
        Write-Information '----- [3/3] finalize : FAIL -----'
    } 6>$null
} finally {
    $global:__YurunaLogFile = $savedLogFile
    $global:InformationPreference = $savedInfo
    $global:WarningPreference = $savedWarn
    Remove-Module -Name 'Yuruna.Log' -Force -ErrorAction SilentlyContinue
}
[IO.File]::AppendAllText($transcript, "</pre></main></body></html>$([Environment]::NewLine)")
Write-Line '  wrote cycle-transcript.html  <- Test.Log.psm1 + Yuruna.Log.psm1'

# --- REGION: Log directory listing
# The builder lives inside the status-service runtime. Extracting the block runs
# the CHARACTERS THAT DEPLOY -- a re-implementation here would certify markup no
# service emits.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.Catalog.psm1') -Force -DisableNameChecking
$serviceSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'test/service/Invoke-StatusServiceRuntime.ps1'))
$blockStart = $serviceSource.IndexOf('$sb = [System.Text.StringBuilder]::new()', [StringComparison]::Ordinal)
$blockEnd = $serviceSource.IndexOf("'</main></body></html>')", [StringComparison]::Ordinal)
if ($blockStart -lt 0 -or $blockEnd -lt 0) { throw 'directory-listing block not found in the status-service runtime' }
$block = $serviceSource.Substring($blockStart, ($blockEnd - $blockStart) + "'</main></body></html>')".Length)

$listingDir = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-listing-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $listingDir -Force
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $listingDir '000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689') -Force
    Set-Content -LiteralPath (Join-Path $listingDir 'cycle.html') -Value ('x' * 3500000) -NoNewline
    Set-Content -LiteralPath (Join-Path $listingDir 'notes.txt') -Value 'x' -NoNewline

    # Windows cannot create a filename containing quotes. The renderer consumes
    # entry metadata, so supply that display name without requiring such a file.
    $entries = @(Get-ChildItem -LiteralPath $listingDir | Select-Object Name, PSIsContainer, Length, LastWriteTimeUtc)
    foreach ($entry in $entries) {
        if ($entry.Name -ceq 'notes.txt') { $entry.Name = 'notes & "quotes".txt' }
    }
    $entries = @($entries | Sort-Object @{Expression = { -not $_.PSIsContainer } }, Name)
    $origLocal = '/log/000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689/'
    $listing = [scriptblock]::Create($block + "`n`$sb.ToString()").InvokeWithContext(
        @{}, @(
            [psvariable]::new('entries', $entries)
            [psvariable]::new('origLocal', $origLocal)
            # The block renders whatever locale it is handed. Supplying it here
            # rather than letting the block resolve one keeps the extracted
            # code free of the request it no longer has.
            [psvariable]::new('listingLocale', @{
                    Tag = 'en-US'; RequestedTag = 'en-US'; Direction = 'ltr'; Source = 'default'
                })
        ))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'log-directory-index.html'), ($listing -join ''))
} finally {
    Remove-Item -LiteralPath $listingDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Line '  wrote log-directory-index.html  <- Invoke-StatusServiceRuntime.ps1 listing block'

# The listing links a stylesheet at the site root, and the gate serves this
# directory as the root, so the real stylesheet has to be here or every color
# it measures would be the browser default rather than the shipped token.
Copy-Item -LiteralPath (Join-Path $RepoRoot 'test/status/yuruna.common.css') `
    -Destination (Join-Path $OutputDirectory 'yuruna.common.css') -Force

# --- REGION: Notification email
# The transport is private to the extension module, so the capture runs inside
# that module's scope, where a local function shadows the cmdlet the sender
# calls. The alternative -- rebuilding the payload here -- would test this file.
$notifyModule = Join-Path $RepoRoot 'test/extension/notification/default.psm1'
Import-Module $notifyModule -Force -DisableNameChecking
try {
    $bodyText = @'
Cycle 000200 FAILED on syzor202607a.

  step 3/3  finalize
  guest did not answer within 300 s

Full transcript: http://192.168.7.44/log/000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689/000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689.html

{"failureClass":"vm_start_failure","host":"syzor202607a","cycle":200}
'@
    # The sender pipes its transport call to Out-Null, so a stub that RETURNS the
    # payload hands it straight to the bit bucket. It has to be captured on the
    # way past instead.
    $payload = & (Get-Module 'default') {
        param($Text)
        $script:__capturedBody = $null
        function Invoke-RestMethod {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                Justification = 'Shadowing the transport inside the module scope IS the capture technique; the sender is private and pipes its result to Out-Null.')]
            [CmdletBinding()]
            param($Body, [Parameter(ValueFromRemainingArguments = $true)]$Ignored)
            $null = $Ignored
            $script:__capturedBody = $Body
        }
        Send-EmailViaResend -ResendCfg @{ apiKey = 'fixture'; fromEmail = 'lab@example.com' } `
            -ToAddress 'operator@example.com' -Subject 'Cycle 000200 FAILED' -BodyText $Text
        $script:__capturedBody
    } $bodyText
    $html = ($payload | ConvertFrom-Json).html
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'notification-email.html'), $html)
} finally {
    Remove-Module -Name 'default' -Force -ErrorAction SilentlyContinue
}
Write-Line '  wrote notification-email.html  <- notification/default.psm1'

# --- REGION: Guest-provisioned pages
# Read out of the seed rather than re-typed here. A copy in this file would be
# the thing the gates measure, and the bytes the guest actually serves would
# stop being checked the first time the two drifted.
$registryPath = Join-Path $RepoRoot 'globalization/manifests/browser-sources.json'
$registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))
# Filtered, not merely wrapped: an absent property yields $null, and @($null)
# has one element, so a plain count check would pass over a deleted section and
# then iterate once with nothing in hand.
$provisioned = @($registry.provisionedPageProducers | Where-Object { $_ -and $_.path })
if ($provisioned.Count -eq 0) {
    Write-Error 'the browser-source registry lists no provisioned page producers' -ErrorAction Continue
    exit 1
}
foreach ($producer in $provisioned) {
    $seedPath = Join-Path $RepoRoot ([string]$producer.path)
    if (-not (Test-Path -LiteralPath $seedPath -PathType Leaf)) {
        Write-Error "provisioned page producer is missing: $($producer.path)" -ErrorAction Continue
        exit 1
    }
    $seed = [IO.File]::ReadAllText($seedPath) -replace "`r`n", "`n"
    # The document is a cloud-init `content: |` literal under the write_files
    # entry whose path is the marker: find that entry, then take the indented
    # block that follows and strip the block indent cloud-init strips.
    # Anchored to the write_files entry that declares the path, not to any
    # mention of it: the same string appears in configuration that refers to the
    # page, and matching one of those would extract a neighboring entry's
    # document while looking like it worked.
    $entry = [regex]::Match($seed, ('(?m)^\s*-\s+path:\s*[''"]?' +
            [regex]::Escape([string]$producer.marker) + '[''"]?\s*$'))
    if (-not $entry.Success) {
        Write-Error "no write_files entry declares $($producer.marker) in $($producer.path)" -ErrorAction Continue
        exit 1
    }
    $markerAt = $entry.Index
    $lines = @($seed.Substring($markerAt) -split "`n")
    $bodyLines = [Collections.Generic.List[string]]::new()
    $indent = -1
    $started = $false
    foreach ($line in $lines) {
        if (-not $started) {
            # cloud-init accepts the block-scalar indicators YAML defines --
            # a chomping sign and an explicit indent -- so recognizing only the
            # bare form would read a valid seed as an empty page.
            if ($line -match '^\s*content:\s*\|[-+]?[0-9]*\s*$') { $started = $true }
            continue
        }
        if ($line.Trim() -eq '') { $bodyLines.Add(''); continue }
        $lead = $line.Length - $line.TrimStart(' ').Length
        if ($indent -lt 0) { $indent = $lead }
        if ($lead -lt $indent) { break }
        $bodyLines.Add($line.Substring($indent))
    }
    if (@($bodyLines | Where-Object { $_.Trim() }).Count -eq 0) {
        Write-Error "the content block for $($producer.page) is empty in $($producer.path)" -ErrorAction Continue
        exit 1
    }
    $document = ($bodyLines -join "`n").TrimEnd() + "`n"
    # %U is Squid's own interpolation point. A gate that rendered the macro
    # would measure a line no reader ever sees; a plausible URL is what the
    # page actually shows, and it is also the longest unbreakable string on it.
    Import-Module (Join-Path $RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -DisableNameChecking
    $document = ConvertTo-ProvisionedCatalogHtml -Content $document -RepoRoot $RepoRoot -Language 'en-US'
    $document = $document.Replace('%U', 'http://archive.ubuntu.com/ubuntu/dists/noble/main/binary-amd64/Packages.gz')
    [IO.File]::WriteAllText((Join-Path $OutputDirectory ([string]$producer.page)), $document)
}
Write-Line "  $($provisioned.Count) provisioned page(s) extracted from their seeds"

# --- REGION: Populated dashboards
# Served from the working tree, the status overview and the performance page
# read their rows from runtime/status.json and control/perf-aggregates, which a
# checkout either lacks (the empty state) or holds from whatever this machine
# last ran. The shipped pages are copied unchanged into a folder of their own
# with fixture answers at those relative URLs, so the populated tables, history
# and timelines are measured on every host the same way. The values include the
# long unbroken identifiers and the failure text that stress reflow.
$populated = Join-Path $OutputDirectory 'status-populated'
foreach ($folder in @($populated, (Join-Path $populated 'runtime'), (Join-Path $populated 'control'))) {
    $null = New-Item -ItemType Directory -Path $folder -Force
}
foreach ($asset in @('index.html', 'performance.html', 'yuruna.common.css', 'yuruna.common.js')) {
    Copy-Item -LiteralPath (Join-Path $statusSource $asset) -Destination (Join-Path $populated $asset) -Force
}
$populatedStatus = @'
{
  "schemaVersion": 1,
  "host": "host.ubuntu.kvm",
  "hostname": "lab-host-01",
  "hostId": "426d17ef0b88426b922180dad1a9e921",
  "cycleStartUtc": "2026-10-20T08:00:00Z",
  "startedAt": "2026-10-20T08:00:00Z",
  "finishedAt": null,
  "overallStatus": "running",
  "stepPaused": false,
  "cyclePaused": false,
  "labHold": false,
  "labHoldAreas": [],
  "gitCommits": [
    { "sha": "0123456789", "repoUrl": "https://example.test/framework" },
    { "sha": "abcdef0", "repoUrl": "https://example.test/project" }
  ],
  "repoUrl": "https://example.test/framework",
  "lastGetImageAt": "2026-10-19T22:00:00Z",
  "cycle": 214,
  "cycleFolderUrl": "log/000214.2026-10-20.08-00-00.426d17ef0b88426b922180dad1a9e921/",
  "lastFailure": null,
  "guests": [
    { "guestKey": "guest.ubuntu.server.26", "vmName": "test-guest.ubuntu.server.26-01", "topLevel": "workload.guest.ubuntu.server.26.k8s.website",
      "status": "pass", "quarantined": false, "quarantinedUntilCommit": "",
      "failureArtifacts": "log/000214.2026-10-20.08-00-00.426d17ef0b88426b922180dad1a9e921/test-guest.ubuntu.server.26-01/",
      "steps": [
        { "name": "New-VM", "status": "pass", "startedAt": "2026-10-20T08:00:05Z", "finishedAt": "2026-10-20T08:00:09Z", "skipped": false, "errorMessage": null },
        { "name": "Start-VM", "status": "pass", "startedAt": "2026-10-20T08:00:09Z", "finishedAt": "2026-10-20T08:00:10Z", "skipped": false, "errorMessage": null },
        { "name": "Start-GuestOS", "status": "pass", "startedAt": "2026-10-20T08:00:10Z", "finishedAt": "2026-10-20T08:06:58Z", "skipped": false, "errorMessage": null },
        { "name": "Start-GuestWorkload", "status": "pass", "startedAt": "2026-10-20T08:06:58Z", "finishedAt": "2026-10-20T08:13:32Z", "skipped": false, "errorMessage": null }
      ] },
    { "guestKey": "guest.windows.11", "vmName": "test-guest.windows.11-01", "topLevel": "workload.guest.windows.11",
      "status": "fail", "quarantined": false, "quarantinedUntilCommit": "",
      "failureArtifacts": "log/000214.2026-10-20.08-00-00.426d17ef0b88426b922180dad1a9e921/test-guest.windows.11-01/",
      "steps": [
        { "name": "New-VM", "status": "pass", "startedAt": "2026-10-20T08:00:05Z", "finishedAt": "2026-10-20T08:00:08Z", "skipped": false, "errorMessage": null },
        { "name": "Start-VM", "status": "pass", "startedAt": "2026-10-20T08:00:08Z", "finishedAt": "2026-10-20T08:00:08Z", "skipped": false, "errorMessage": null },
        { "name": "Start-GuestOS", "status": "fail", "startedAt": "2026-10-20T08:00:08Z", "finishedAt": "2026-10-20T08:30:08Z", "skipped": false,
          "errorMessage": "Timed out after 1800 s waiting for 'Windows Setup' on the console; the last OCR read was 'Getting ready' (C:\\Windows\\Panther\\UnattendGC\\setupact.log)" },
        { "name": "Start-GuestWorkload", "status": "skipped", "startedAt": null, "finishedAt": null, "skipped": true, "errorMessage": null }
      ] },
    { "guestKey": "guest.amazon.linux.2023", "vmName": "test-guest.amazon.linux.2023-01-with-a-long-unbroken-vm-name-for-reflow", "topLevel": "workload.guest.amazon.linux.2023.postgresql.replication.with.a.long.sequence.name",
      "status": "running", "quarantined": false, "quarantinedUntilCommit": "", "failureArtifacts": "",
      "steps": [
        { "name": "New-VM", "status": "pass", "startedAt": "2026-10-20T08:00:05Z", "finishedAt": "2026-10-20T08:00:11Z", "skipped": false, "errorMessage": null },
        { "name": "Start-VM", "status": "running", "startedAt": "2026-10-20T08:00:11Z", "finishedAt": null, "skipped": false, "errorMessage": null }
      ] }
  ],
  "sequences": [
    { "name": "workload.guest.ubuntu.server.26.k8s.website", "guests": [ "guest.ubuntu.server.26" ] },
    { "name": "workload.guest.windows.11", "guests": [ "guest.windows.11" ] },
    { "name": "workload.guest.amazon.linux.2023.postgresql.replication.with.a.long.sequence.name", "guests": [ "guest.amazon.linux.2023" ] }
  ],
  "nested": {},
  "history": [
    { "cycleStartUtc": "2026-10-20T06:00:00Z", "startedAt": "2026-10-20T06:00:00Z", "finishedAt": "2026-10-20T06:41:12Z", "totalDurationSeconds": 2472,
      "overallStatus": "fail", "host": "host.ubuntu.kvm", "hostname": "lab-host-01",
      "gitCommits": [ { "sha": "0123456789", "repoUrl": "https://example.test/framework" } ],
      "cycleFolderUrl": "log/000213.2026-10-20.06-00-00.426d17ef0b88426b922180dad1a9e921/",
      "guestSummary": { "guest.ubuntu.server.26": { "status": "pass" }, "guest.windows.11": { "status": "fail" } },
      "sequenceSummary": [ { "name": "workload.guest.ubuntu.server.26.k8s.website", "status": "pass" }, { "name": "workload.guest.windows.11", "status": "fail" } ] },
    { "cycleStartUtc": "2026-10-20T04:00:00Z", "startedAt": "2026-10-20T04:00:00Z", "finishedAt": "2026-10-20T04:28:44Z", "totalDurationSeconds": 1724,
      "overallStatus": "pass", "host": "host.ubuntu.kvm", "hostname": "lab-host-01",
      "gitCommits": [ { "sha": "fedcba9876", "repoUrl": "https://example.test/framework" } ],
      "cycleFolderUrl": "log/000212.2026-10-20.04-00-00.426d17ef0b88426b922180dad1a9e921/",
      "guestSummary": { "guest.ubuntu.server.26": { "status": "pass" }, "guest.windows.11": { "status": "pass" } },
      "sequenceSummary": [ { "name": "workload.guest.ubuntu.server.26.k8s.website", "status": "pass" }, { "name": "workload.guest.windows.11", "status": "pass" } ] },
    { "cycleStartUtc": "2026-10-20T02:00:00Z", "startedAt": "2026-10-20T02:00:00Z", "finishedAt": "2026-10-20T02:03:10Z", "totalDurationSeconds": 190,
      "overallStatus": "aborted", "host": "host.ubuntu.kvm", "hostname": "lab-host-01",
      "gitCommits": [ { "sha": "fedcba9876", "repoUrl": "https://example.test/framework" } ],
      "cycleFolderUrl": "log/000211.2026-10-20.02-00-00.426d17ef0b88426b922180dad1a9e921/",
      "guestSummary": { "guest.ubuntu.server.26": { "status": "aborted" } },
      "sequenceSummary": [ { "name": "workload.guest.ubuntu.server.26.k8s.website", "status": "aborted" } ] }
  ]
}
'@
$populatedPerf = @'
{
  "generatedAtUtc": "2026-10-20T08:14:00Z",
  "sequences": {
    "workload.guest.ubuntu.server.26.k8s.website": [
      { "sequenceInvocationId": "4a1b2c3d-0001", "cycleStartUtc": "2026-10-20T04:00:00Z", "cycleStartedAtUtc": "2026-10-20T04:00:00Z",
        "invocationStartedAtUtc": "2026-10-20T04:00:05Z", "vmName": "test-guest.ubuntu.server.26-01",
        "durationMs": 806000, "stepCount": 3, "failCount": 0, "retryFailureCount": 0,
        "steps": [
          { "name": "boot", "kind": "waitForText", "startedMs": 1000, "endedMs": 409000, "durationMs": 408000, "outcome": "pass" },
          { "name": "workload", "kind": "fetchAndExecute", "startedMs": 409000, "endedMs": 803000, "durationMs": 394000, "outcome": "pass",
            "checkpoints": [ { "name": "packages", "offsetMs": 20000 }, { "name": "kubernetes", "offsetMs": 140000 }, { "name": "website", "offsetMs": 300000 } ] },
          { "name": "verify", "kind": "httpCheck", "startedMs": 803000, "endedMs": 807000, "durationMs": 4000, "outcome": "pass" }
        ] },
      { "sequenceInvocationId": "4a1b2c3d-0002", "cycleStartUtc": "2026-10-20T06:00:00Z", "cycleStartedAtUtc": "2026-10-20T06:00:00Z",
        "invocationStartedAtUtc": "2026-10-20T06:00:05Z", "vmName": "test-guest.ubuntu.server.26-01",
        "durationMs": 851000, "stepCount": 3, "failCount": 0, "retryFailureCount": 1,
        "steps": [
          { "name": "boot", "kind": "waitForText", "startedMs": 1000, "endedMs": 431000, "durationMs": 430000, "outcome": "pass" },
          { "name": "workload", "kind": "retry", "startedMs": 431000, "endedMs": 848000, "durationMs": 417000, "outcome": "pass" },
          { "name": "workload attempt 1", "kind": "fetchAndExecute", "startedMs": 431000, "endedMs": 470000, "durationMs": 39000, "outcome": "fail", "parentAction": "workload", "parentAttempt": 1 },
          { "name": "verify", "kind": "httpCheck", "startedMs": 848000, "endedMs": 852000, "durationMs": 4000, "outcome": "pass" }
        ] }
    ],
    "workload.guest.windows.11": [
      { "sequenceInvocationId": "5b2c3d4e-0001", "cycleStartUtc": "2026-10-20T06:00:00Z", "cycleStartedAtUtc": "2026-10-20T06:00:00Z",
        "invocationStartedAtUtc": "2026-10-20T06:00:05Z", "vmName": "test-guest.windows.11-01",
        "durationMs": 1800000, "stepCount": 1, "failCount": 1, "retryFailureCount": 0, "diagnosticIncompleteCount": 1,
        "steps": [
          { "name": "Windows Setup", "kind": "waitForText", "startedMs": 1000, "endedMs": 1801000, "durationMs": 1800000, "outcome": "timeout",
            "diagnosticOutcome": "timeout", "evidenceCaptureDurationMs": 15000 }
        ] }
    ]
  }
}
'@
[IO.File]::WriteAllText((Join-Path $populated 'runtime/status.json'), $populatedStatus)
[IO.File]::WriteAllText((Join-Path $populated 'control/perf-aggregates'), $populatedPerf)
Write-Line '  wrote status-populated/  <- status/index.html + performance.html with fixture runtime data'

# --- REGION: Fixture content
# A page that renders nothing passes every check it should have failed. Silencing a
# preference also silences the log tee, leaving a transcript with no step headings and no
# information lines that the browser gate then reports clean. A fixture builder that cannot
# detect its own empty output is worth less than no fixture at all.
$expected = [ordered]@{
    'caching-proxy-parser-ui.html' = @('<html lang="en"', 'id="pause"', 'class="scroller"', "yurunaRequest('/recent-requests'")
    'caching-proxy-ui.html'        = @('<html lang="en"', 'id="pause"', "yurunaRequest('/api/status'")
    'caching-proxy-parser-ui-failed.html' = @('<html lang="en"', 'window.yurunaRequest', 'Promise.reject', 'Refresh failed.')
    'caching-proxy-ui-failed.html'        = @('<html lang="en"', 'window.yurunaRequest', 'Promise.reject', 'Refresh failed.')
    'cycle-transcript.html'        = @('<html lang="en-US" dir="ltr"', 'log-error::before', 'class="log-warning"',
                                       'class="log-information"', 'role="heading" aria-level="2"')
    'log-directory-index.html'     = @('<main>', '<caption>', 'scope="col"', 'Parent directory',
                                       '<time datetime=', 'class="scroller"')
    'notification-email.html'      = @('<html lang="en-US"', 'pre-wrap', 'background:#ffffff')
    'status-reference-qps-Ploc.html' = @('<html lang="qps-Ploc" dir="ltr"',
        'qps-Ploc.status.js', 'data-yuruna-globalization-reference', 'sequence_paused_waiting_resume')
    'status-reference-qps-Plocm.html' = @('<html lang="qps-Plocm" dir="rtl"',
        'qps-Plocm.status.js', 'data-yuruna-globalization-reference', 'sequence_paused_waiting_resume')
    'pool-reference-qps-Ploc.html' = @('<html lang="qps-Ploc" dir="ltr"',
        'qps-Ploc.pool.js', 'data-yuruna-globalization-reference', 'frameworkAccessState')
    'pool-reference-qps-Plocm.html' = @('<html lang="qps-Plocm" dir="rtl"',
        'qps-Plocm.pool.js', 'data-yuruna-globalization-reference', 'frameworkAccessState')
    'squid-no-upstream.html'       = @('<!doctype html>', '<html lang="en-US" dir="ltr">', '<meta charset="utf-8">',
                                       '<title data-i18n=', '<main>', '<h1 data-i18n=')
    'status-populated/index.html'  = @('<html lang="en"', 'id="menu-button"', 'yuruna.common.js')
    'status-populated/performance.html' = @('<html lang="en"', 'id="perf-body"', 'yuruna.common.js')
    'status-populated/runtime/status.json' = @('"guests"', '"history"', '"errorMessage": "Timed out')
    'status-populated/control/perf-aggregates' = @('"sequences"', '"checkpoints"', '"diagnosticOutcome"')
}
$missing = [Collections.Generic.List[string]]::new()
foreach ($file in $expected.Keys) {
    $path = Join-Path $OutputDirectory $file
    if (-not (Test-Path -LiteralPath $path)) { $missing.Add("$file was not written"); continue }
    $text = [IO.File]::ReadAllText($path)
    if ($text.Length -lt 200) { $missing.Add("$file is $($text.Length) bytes; that is not a page") }
    foreach ($marker in $expected[$file]) {
        if (-not $text.Contains($marker)) { $missing.Add("$file has no '$marker'") }
    }
}
if ($missing.Count -gt 0) {
    foreach ($m in $missing) { Write-Error "generated page check: $m" -ErrorAction Continue }
    Write-Error "generated pages are not what the gate expects to measure; $($missing.Count) problem(s)"
    exit 1
}
Write-Line "  $($expected.Count) page(s) written and checked"

Write-Output $OutputDirectory
