<#PSScriptInfo
.VERSION 2026.09.01
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

    The one deliberate substitution is the data source. Both Go pages fetch
    their rows from a daemon that is not running here, so a stub `fetch` is
    injected ahead of the page's own script and answers with a representative
    payload -- including the pathological values that matter for reflow: a
    request URL and a user-agent long enough to blow out a table cell. The
    markup, the stylesheet and the rendering JavaScript under test are byte
    for byte what the daemon serves.
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

# --- REGION: the two Go raw-string pages -------------------------------------

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

function Add-FetchStub {
    <#
    .SYNOPSIS
        Insert a fetch stub ahead of the page's own script.
    .DESCRIPTION
        Placed before the page script rather than after it: the page calls
        refresh() at parse time, so a stub defined later would never be reached
        and the gate would silently measure an empty table -- a page that
        renders nothing passes every check it should have failed.
    #>
    param([Parameter(Mandatory)][string]$Html, [Parameter(Mandatory)][string]$Json)

    if (($Html -split '<script>').Count -ne 2) { throw 'expected exactly one <script> in the page' }
    $stub = @"
<script>
window.fetch = function () {
  return Promise.resolve({ ok: true, json: function () { return Promise.resolve($Json); } });
};
</script>
"@
    return ($Html -replace '<script>', ($stub + '<script>'))
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
       Source = 'test/extension/caching-proxy-parser-service/parse.go'; Json = $parserRows }
    @{ File = 'caching-proxy-ui.html'
       Source = 'test/extension/caching-proxy-service/ui.go'; Json = $proxyStatus }
)
foreach ($p in $goPages) {
    $html = Get-GoRawStringConstant -Path (Join-Path $RepoRoot $p.Source) -Name 'indexHTML'
    $out = Join-Path $OutputDirectory $p.File
    [IO.File]::WriteAllText($out, (Add-FetchStub -Html $html -Json $p.Json))
    Write-Line "  wrote $($p.File)  <- $($p.Source)"
}

# --- REGION: the per-cycle transcript ----------------------------------------

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
        Write-Information 'A line long enough to need wrapping: /usr/bin/env pwsh -NoProfile -File /home/ytest/git/yuruna/test/service/Start-StatusService.ps1 -Port 8080 -RuntimeDir /var/lib/yuruna/runtime'
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

# --- REGION: the log directory listing ---------------------------------------

# The builder lives inside the status-service here-string template, where every
# runtime variable is backtick-escaped. Extracting the block and undoing that
# escaping runs the CHARACTERS THAT DEPLOY -- a re-implementation here would
# certify markup no service emits.
$serviceSource = [IO.File]::ReadAllText((Join-Path $RepoRoot 'test/service/Start-StatusService.ps1'))
$blockStart = $serviceSource.IndexOf('`$sb = [System.Text.StringBuilder]::new()', [StringComparison]::Ordinal)
$blockEnd = $serviceSource.IndexOf("'</main></body></html>')", [StringComparison]::Ordinal)
if ($blockStart -lt 0 -or $blockEnd -lt 0) { throw 'directory-listing block not found in the status-service template' }
$block = $serviceSource.Substring($blockStart, ($blockEnd - $blockStart) + "'</main></body></html>')".Length)
$block = $block.Replace('`$', '$').Replace('`@', '@')

$listingDir = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-listing-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $listingDir -Force
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $listingDir '000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689') -Force
    Set-Content -LiteralPath (Join-Path $listingDir 'cycle.html') -Value ('x' * 3500000) -NoNewline
    Set-Content -LiteralPath (Join-Path $listingDir 'notes & "quotes".txt') -Value 'x' -NoNewline

    $entries = @(Get-ChildItem -LiteralPath $listingDir | Sort-Object @{Expression = { -not $_.PSIsContainer } }, Name)
    $origLocal = '/log/000200.2026-08-19.08-20-48.422dd0cac87e4cc6831c3228f12ae689/'
    $listing = [scriptblock]::Create($block + "`n`$sb.ToString()").InvokeWithContext(
        @{}, @(
            [psvariable]::new('entries', $entries)
            [psvariable]::new('origLocal', $origLocal)
        ))
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'log-directory-index.html'), ($listing -join ''))
} finally {
    Remove-Item -LiteralPath $listingDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Line '  wrote log-directory-index.html  <- Start-StatusService.ps1 template block'

# The listing links a stylesheet at the site root, and the gate serves this
# directory as the root, so the real stylesheet has to be here or every color
# it measures would be the browser default rather than the shipped token.
Copy-Item -LiteralPath (Join-Path $RepoRoot 'test/status/yuruna.common.css') `
    -Destination (Join-Path $OutputDirectory 'yuruna.common.css') -Force

# --- REGION: the notification email ------------------------------------------

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

# --- REGION: the fixtures have to actually contain what they are checked for --

# A page that renders nothing passes every check it should have failed, and this
# script has already produced one: silencing a preference silenced the log tee
# with it, leaving a transcript with no step headings and no information lines
# that the browser gate then reported clean. A fixture builder that cannot
# detect its own empty output is worth less than no fixture at all.
$expected = [ordered]@{
    'caching-proxy-parser-ui.html' = @('<html lang="en"', 'id="pause"', 'class="scroller"', "fetch('/recent-requests')")
    'caching-proxy-ui.html'        = @('<html lang="en"', 'id="pause"', "fetch('/api/status')")
    'cycle-transcript.html'        = @('<html lang="en"', 'log-error::before', 'class="log-warning"',
                                       'class="log-information"', 'role="heading" aria-level="2"')
    'log-directory-index.html'     = @('<main>', '<caption>', 'scope="col"', 'Parent directory',
                                       '<time datetime=', 'class="scroller"')
    'notification-email.html'      = @('<html lang="en"', 'pre-wrap', 'background:#ffffff')
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
