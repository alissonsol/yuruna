<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42fca7ca-dec4-468b-84b9-d01fef0491cc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser devtools contract pester
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
    Prove the page operations of the web channel against a real Chromium-family
    browser: locating, clicking, filling, selecting, keys, expectations,
    navigation, dialogs, windows, downloads, a large page and the loss of the
    page and of the browser.
.DESCRIPTION
    The unit suite of the protocol client runs over a scripted transport that
    answers what the client was written to expect. Only a real browser shows
    whether the browser still answers that way: a reply that changed shape, an
    event that no longer arrives, a click that lands twice or nowhere. Each case
    drives the page operations of Test.WebSession.psm1 the way a page verb does,
    then reads what the page saw with Runtime.evaluate, so a defect of the page
    reader cannot hide a defect of an action. Every page appends what its
    handlers saw to its log, and the cases count those lines to prove that no
    step ran twice.

    Without Chrome or Chromium on the host every case skips; such a run is never
    a contract pass.

    Run: Invoke-Pester -Path test/modules/Test.WebBrowserContract.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.WebSession.psm1') -Force -Global -DisableNameChecking

$script:Chrome = Get-YurunaTestBrowser
$script:Browser = $null
$script:Cdp = $null
if ($script:Chrome) { $script:Browser = Start-YurunaTestBrowser -Browser $script:Chrome }
# A port that accepts and never answers, and one nothing listens on.
$script:Hang = Start-YurunaTestHttpResponder -Reply @('', '', '') -HoldOpen
$script:ClosedPort = Get-YurunaTestFreePort

$logScript = 'function log(s) { document.getElementById(''log'').textContent += s + ''\n''; }'

$script:PageText = [ordered]@{}
$script:PageText['basic.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Sign in page</title></head><body>
<h1>Sign in</h1>
<p id="intro">Please sign in to continue.</p>
<label for="email">Email</label> <input id="email" type="text" value="old">
<label for="pw">Password</label> <input id="pw" type="password">
<label for="notes">Notes</label> <textarea id="notes">old notes</textarea>
<label><input type="checkbox" id="remember"> Remember me</label>
<label for="country">Country</label> <select id="country"><option>Brazil</option><option>Israel</option><option>China</option></select>
<button id="signin">Sign in</button>
<button id="later" disabled>Later</button>
<a href="/next.html">Next page</a>
<div id="status"></div>
<pre id="log"></pre>
<script>
{{log}}
document.getElementById('signin').addEventListener('click', function (e) {
  log('signin detail=' + e.detail);
  document.getElementById('status').textContent = 'Signed in';
  var intro = document.getElementById('intro'); if (intro) { intro.remove(); }
});
document.getElementById('later').addEventListener('click', function () { log('later'); });
setTimeout(function () { document.getElementById('later').disabled = false; }, 1500);
document.getElementById('remember').addEventListener('click', function () { log('remember click'); });
['email', 'pw', 'notes'].forEach(function (id) {
  document.getElementById(id).addEventListener('input', function (e) { log('input ' + id + ' ' + e.isTrusted); });
});
</script></body></html>
'@
$script:PageText['form.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Form page</title></head><body>
<h1>Form</h1>
<form id="f" action="/next.html" method="get">
<label for="first">First</label> <input id="first" name="first">
<label><input type="checkbox" id="agree"> Agree</label>
<button type="submit">Send</button>
</form>
<label for="short">Short</label> <input id="short" maxlength="5">
<label for="count">Count</label> <input id="count" type="number">
<div id="editor" contenteditable="true" role="textbox" aria-label="Editor">old text</div>
<label><input type="radio" name="size" id="small" checked> Small</label>
<label><input type="radio" name="size" id="large"> Large</label>
<button id="plain">Plain</button>
<pre id="log"></pre>
<script>
{{log}}
document.getElementById('f').addEventListener('submit', function (e) { e.preventDefault(); log('submit'); });
['mousedown', 'click', 'dblclick', 'contextmenu'].forEach(function (name) {
  document.getElementById('plain').addEventListener(name, function () { log('plain ' + name); });
});
document.getElementById('editor').addEventListener('input', function (e) { log('input editor ' + e.isTrusted); });
document.addEventListener('keydown', function (e) { log('key ' + e.key); });
</script></body></html>
'@
$script:PageText['select.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Select page</title></head><body>
<h1>Select</h1>
<label for="color">Color</label>
<select id="color">
<option>Red</option><option>Green</option><option disabled>Off</option><option>Twin</option><option>Twin</option>
<optgroup label="Locked" disabled><option>Grouped</option></optgroup>
<option label="Sky label">sky</option><option>  Wide   option  </option>
</select>
<label for="many">Many</label> <select id="many" multiple><option>One</option><option>Two</option></select>
<label for="frozen">Frozen</label> <select id="frozen" disabled><option>Only</option></select>
<label for="notes">Notes</label> <input id="notes">
<pre id="log"></pre>
<script>
{{log}}
var color = document.getElementById('color');
color.addEventListener('input', function (e) { log('input ' + e.isTrusted); });
color.addEventListener('change', function (e) { log('change ' + e.isTrusted); });
</script></body></html>
'@
$script:PageText['duplicates.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Duplicates page</title></head><body>
<h1>Duplicates</h1>
<ul><li>Alpha <button onclick="log('delete 1')">Delete</button></li><li>Beta <button onclick="log('delete 2')">Delete</button></li></ul>
<button onclick="log('save')">Save</button>
<button onclick="log('save draft')">Save draft</button>
<button onclick="log('save as copy')">  SAVE   As Copy </button>
<button aria-label="Close panel" onclick="log('close panel')">X</button>
<label for="nick">Nickname</label> <input id="nick">
<input id="search" placeholder="Search here">
<input id="postal" aria-label="Postal code">
<pre id="log"></pre>
<script>
{{log}}
</script></body></html>
'@
$script:PageText['overlay.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Overlay page</title></head><body>
<h1>Overlay</h1>
<div style="position:relative;height:60px"><button id="covered">Covered</button><div id="cover" style="position:absolute;left:0;top:0;width:100%;height:100%;background:#ddd"></div></div>
<div style="position:relative;height:60px"><button id="under">Under cover</button><div id="lid" style="position:absolute;left:0;top:0;width:100%;height:100%;background:#ccc"></div></div>
<button id="late" style="display:none">Shown late</button>
<button style="visibility:hidden">Invisible</button>
<button id="zero" style="width:0;height:0;padding:0;border:0;margin:0;overflow:hidden;font-size:0">Zero size</button>
<div style="position:relative;height:40px"><button id="moving" style="position:absolute;left:0;top:0">Moving</button></div>
<label>Fixed value <input id="fixed" readonly value="x"></label>
<label>Off field <input id="off" disabled></label>
<button id="aria" aria-disabled="true">Aria off</button>
<fieldset disabled><button id="infield">In fieldset</button></fieldset>
<div id="replace"></div>
<pre id="log"></pre>
<div style="height:3000px"></div>
<button id="far">Far down</button>
<script>
{{log}}
setTimeout(function () { document.getElementById('cover').remove(); }, 1500);
setTimeout(function () { document.getElementById('late').style.display = 'inline-block'; }, 1200);
document.getElementById('covered').addEventListener('click', function () { log('covered'); });
document.getElementById('under').addEventListener('click', function () { log('under'); });
document.getElementById('zero').addEventListener('click', function () { log('zero'); });
document.getElementById('aria').addEventListener('click', function () { log('aria'); });
document.getElementById('far').addEventListener('click', function () { log('far'); });
var moving = document.getElementById('moving'), step = 0;
moving.addEventListener('click', function () { log('moving'); });
var mover = setInterval(function () { step++; moving.style.left = (step * 7) + 'px'; }, 20);
setTimeout(function () { clearInterval(mover); }, 1000);
var holder = document.getElementById('replace');
function place() {
  holder.textContent = '';
  var b = document.createElement('button'); b.textContent = 'Replaced';
  b.addEventListener('click', function () { log('replaced'); });
  holder.appendChild(b);
}
place();
var replacer = setInterval(place, 100);
setTimeout(function () { clearInterval(replacer); }, 1000);
</script></body></html>
'@
$script:PageText['text.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Text page</title></head><body>
<h1>Texts</h1>
<p><span>Hello, </span><b>maria</b><span>!</span></p>
<p>Wel<mark>come</mark> aboard</p>
<p>Line one<br>Line two</p>
<p style="text-transform:uppercase">quiet words</p>
<div style="display:none"><button>Gone display</button></div>
<div style="visibility:hidden"><button>Gone visibility</button></div>
<div hidden><button>Gone hidden</button></div>
<div aria-hidden="true"><button>Gone aria</button></div>
<div id="n1" role="note" aria-label="Equal notice">Equal notice</div>
<div id="n2" role="note" aria-label="Equal notice">Equal notice</div>
<div id="late"></div>
<label for="filled">Filled</label> <input id="filled" value="typed value">
<script>
setTimeout(function () { document.getElementById('n1').remove(); }, 1700);
setTimeout(function () { document.getElementById('n2').remove(); }, 2400);
setTimeout(function () { document.getElementById('late').textContent = 'Late arrival'; }, 1900);
</script></body></html>
'@
$script:PageText['nav.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Nav page</title></head><body>
<h1>Navigation</h1>
<a href="/next.html">Plain link</a>
<button onclick="location.assign('/next.html')">Go now</button>
<button onclick="setTimeout(function () { location.assign('/next.html'); }, 0)">Go zero</button>
<button onclick="setTimeout(function () { location.assign('/next.html'); }, 300)">Go later</button>
<a href="#part">Fragment</a>
<button onclick="history.pushState({}, '', '/pushed')">Push state</button>
<a href="http://127.0.0.1:{{closed}}/">Closed link</a>
<a href="http://127.0.0.1:{{hang}}/">Hang link</a>
<button onclick="document.getElementById('msg').textContent = 'Changed text'">Text only</button>
<form action="/next.html" method="get"><label for="q">Query</label> <input id="q" name="q"><button type="submit">Search</button></form>
<div id="msg"></div>
<div id="part" style="margin-top:2000px">Part</div>
</body></html>
'@
$script:PageText['next.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Next page</title></head><body>
<h1>Next page here</h1>
<a href="/nav.html">Back</a>
</body></html>
'@
$script:PageText['frames.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Frames page</title></head><body>
<h1>Frames</h1>
<button onclick="log('outer')">Outer action</button>
<div id="spacer"></div>
<iframe id="same" title="Same frame" width="420" height="300"></iframe>
<iframe id="cross" title="Cross frame" width="420" height="300"></iframe>
<pre id="log"></pre>
<script>
{{log}}
if (location.search.indexOf('far') >= 0) { document.getElementById('spacer').style.height = '2600px'; }
window.addEventListener('message', function (e) { log(String(e.data)); });
document.getElementById('same').src = '/inner.html' + location.search;
document.getElementById('cross').src = 'http://localhost:' + location.port + '/inner.html' + location.search;
</script></body></html>
'@
$script:PageText['inner.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Inner page</title></head><body>
<div id="pad"></div>
<label for="field">Inner field</label> <input id="field">
<button id="inner-btn">Inner action</button>
<script>
if (location.search.indexOf('deep') >= 0) { document.getElementById('pad').style.height = '900px'; }
document.getElementById('inner-btn').addEventListener('click', function () { parent.postMessage('inner ' + location.hostname, '*'); });
document.getElementById('field').addEventListener('input', function (e) { parent.postMessage('inner-input ' + location.hostname + ' ' + e.target.value, '*'); });
</script></body></html>
'@
$script:PageText['shadow.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Shadow page</title></head><body>
<h1>Shadow</h1>
<open-box></open-box>
<closed-box></closed-box>
<pre id="log"></pre>
<script>
{{log}}
customElements.define('open-box', class extends HTMLElement {
  constructor() {
    super();
    var root = this.attachShadow({ mode: 'open' });
    root.innerHTML = '<label for="sn">Shadow name</label> <input id="sn"><button>Shadow open</button>';
    root.querySelector('button').addEventListener('click', function () { log('shadow open'); });
  }
});
customElements.define('closed-box', class extends HTMLElement {
  constructor() {
    super();
    var root = this.attachShadow({ mode: 'closed' });
    root.innerHTML = '<button>Shadow closed</button>';
    root.querySelector('button').addEventListener('click', function () { log('shadow closed'); });
  }
});
</script></body></html>
'@
$script:PageText['dialog.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Dialog page</title></head><body>
<h1>Dialogs</h1>
<button onclick="alert('hello'); log('after alert')">Alert</button>
<button onclick="var answer = confirm('sure?'); log('confirm ' + answer)">Confirm</button>
<a href="/next.html" target="_blank">New tab</a>
<button onclick="window.open('/next.html')">Open window</button>
<button onclick="window.onbeforeunload = function (e) { e.preventDefault(); e.returnValue = ''; }; log('armed')">Arm leave</button>
<a href="/download.bin">Download file</a>
<pre id="log"></pre>
<script>
{{log}}
</script></body></html>
'@
# A table whose accessibility tree answers more than 1 MB.
$rows = [System.Text.StringBuilder]::new()
foreach ($row in 1..300) {
    [void]$rows.Append("<tr><td>Row $row</td><td>Item $row description text</td><td>Value $row</td><td>Owner $row</td><td>Region $row</td><td>Status ok</td><td>Note $row</td><td><button onclick=`"log('pick $row')`">Pick $row</button></td></tr>`n")
}
$script:PageText['table.html'] = @'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Table page</title></head><body>
<h1>Table</h1>
<table><tbody>
{{rows}}</tbody></table>
<pre id="log"></pre>
<script>
{{log}}
</script></body></html>
'@.Replace('{{rows}}', $rows.ToString())

$html = 'text/html; charset=utf-8'
$routes = [ordered]@{}
foreach ($name in $script:PageText.Keys) {
    $body = $script:PageText[$name].Replace('{{log}}', $logScript).Replace('{{hang}}', [string]$script:Hang.Port).Replace('{{closed}}', [string]$script:ClosedPort)
    $routes['^GET /' + [regex]::Escape($name) + '[ ?]'] = New-YurunaTestHttpReply -Body $body -ContentType $html
}
$routes['^GET /download\.bin[ ?]'] = New-YurunaTestHttpReply -Body 'payload' -ContentType 'application/octet-stream' -Header @{ 'Content-Disposition' = 'attachment; filename="file.bin"' }
$script:NotFoundPage = '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Missing</title></head><body><h1>Not found here</h1></body></html>'
$routes['^GET /'] = New-YurunaTestHttpReply -StatusCode 404 -Body $script:NotFoundPage -ContentType $html
$script:Pages = Start-YurunaTestHttpResponder -Route $routes -RequestCount 1000
$script:Base = $script:Pages.BaseUrl
if ($script:Browser) {
    $script:Cdp = Connect-WebCdp -Port $script:Browser.Port -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(30))
    Open-WebCdpPage -Connection $script:Cdp -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(30))
}

function Get-ContractDeadline {
    param([int]$Seconds = 10)
    return [DateTime]::UtcNow.AddSeconds($Seconds)
}

function Get-ContractEffect {
    return @{ Dispatched = $false; Acknowledged = $false }
}

function Open-ContractPage {
    param([Parameter(Mandatory)][string]$Path, [hashtable]$Connection = $script:Cdp)
    return (Invoke-WebPageOpen -Connection $Connection -Url "$script:Base/$Path" -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect))
}

# Test code only: the page's own view, read without the page reader.
function Invoke-ContractEval {
    param([Parameter(Mandatory)][string]$Expression, [hashtable]$Connection = $script:Cdp)
    $answer = Invoke-WebCdp -Connection $Connection -Method 'Runtime.evaluate' -Params ([ordered]@{ expression = $Expression; returnByValue = $true }) `
        -SessionId ([string]$Connection.Page.SessionId) -DeadlineUtc (Get-ContractDeadline)
    if ($answer['result'] -is [System.Collections.IDictionary]) { return $answer['result']['value'] }
    return $null
}

function Get-ContractLog {
    param([hashtable]$Connection = $script:Cdp)
    $text = [string](Invoke-ContractEval -Connection $Connection -Expression '(document.getElementById(''log'') || { textContent: '''' }).textContent')
    return [string[]]@($text -split "`n" | Where-Object { $_ })
}

function Get-ContractLineCount {
    param([Parameter(Mandatory)][string]$Line, [hashtable]$Connection = $script:Cdp)
    return @(Get-ContractLog -Connection $Connection | Where-Object { $_ -ceq $Line }).Count
}

# A message from a frame reaches the log a moment after the click.
function Wait-ContractLine {
    param([Parameter(Mandatory)][string]$Line, [int]$Count = 1)
    $stopAt = [DateTime]::UtcNow.AddSeconds(5)
    while ((Get-ContractLineCount -Line $Line) -lt $Count -and [DateTime]::UtcNow -lt $stopAt) { Start-Sleep -Milliseconds 100 }
    return (Get-ContractLineCount -Line $Line)
}

# The page failure a call ends with, or $null when it passes.
function Get-ContractFailure {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try {
        $null = & $Action
    } catch {
        $failure = Get-WebFailureData -ErrorRecord $_
        if ($null -eq $failure) { throw }
        return $failure
    }
    return $null
}

function Get-ContractForest {
    param([hashtable]$Connection = $script:Cdp)
    return (Read-WebPageForest -Connection $Connection -DeadlineUtc (Get-ContractDeadline))
}

# Frames load after their page: read the forest until a condition holds.
function Wait-ContractForest {
    param([Parameter(Mandatory)][scriptblock]$Until)
    $stopAt = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        $forest = Get-ContractForest
        if (& $Until $forest) { return $forest }
        if ([DateTime]::UtcNow -ge $stopAt) { throw 'the page never reached the expected state' }
        Start-Sleep -Milliseconds 100
    }
}

function Get-ContractMatch {
    param([Parameter(Mandatory)][hashtable]$Forest, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Label, [string]$Match = 'exact')
    # Find-WebElement writes its array as one object; the assignment takes
    # that array, and the return lists its elements for the caller's @().
    $found = Find-WebElement -Forest $Forest -Role $Role -Name $Label -Match $Match
    return $found
}

function Wait-ContractFrame {
    param([string]$Search = '')
    $null = Open-ContractPage -Path "frames.html$Search"
    return (Wait-ContractForest -Until { param($Forest) @(Get-ContractMatch -Forest $Forest -Role 'button' -Label 'Inner action').Count -eq 2 })
}

# Whether a raw accessibility node has a role and a name; a node may lack either.
function Test-ContractAxNode {
    param([Parameter(Mandatory)][AllowNull()]$Node, [Parameter(Mandatory)][string]$Role, [Parameter(Mandatory)][string]$Label)
    if ($Node -isnot [System.Collections.IDictionary]) { return $false }
    if ($Node['role'] -isnot [System.Collections.IDictionary] -or $Node['name'] -isnot [System.Collections.IDictionary]) { return $false }
    return ([string]$Node['role']['value'] -ceq $Role -and [string]$Node['name']['value'] -ceq $Label)
}

function Get-ContractTarget {
    $answer = Invoke-WebCdp -Connection $script:Cdp -Method 'Target.getTargets' -DeadlineUtc (Get-ContractDeadline)
    return @($answer['targetInfos'])
}

function Invoke-ContractClick {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Locator, [int]$Seconds = 10, [hashtable]$Effect = (Get-ContractEffect))
    return (Invoke-WebPageClick -Connection $script:Cdp -Locator $Locator -DeadlineUtc (Get-ContractDeadline -Seconds $Seconds) -Effect $Effect)
}
}

AfterAll {
    if ($script:Cdp) { Close-WebCdp -Connection $script:Cdp }
    Stop-YurunaTestBrowser -Session $script:Browser
    $null = Stop-YurunaTestHttpResponder $script:Pages
    $null = Stop-YurunaTestHttpResponder $script:Hang
}

Describe 'the browser under test' {
    It 'is a Chromium-family browser and says which' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $product = [string]$script:Cdp.Browser['product']
        Assert-Match '^(Headless)?(Chrome|Edg)/\d+' $product 'the DevTools client is written against Chromium'
        Write-Information "browser contract: $product on $([Runtime.InteropServices.RuntimeInformation]::OSDescription)" -InformationAction Continue
    }

    It 'answers the accessibility tree without enabling the domain' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $tree = Invoke-WebCdp -Connection $script:Cdp -Method 'Accessibility.getFullAXTree' -Params @{} -SessionId ([string]$script:Cdp.Page.SessionId) -DeadlineUtc (Get-ContractDeadline)
        $nodes = @($tree['nodes'])
        Assert-True ($nodes.Count -gt 10) "the tree has $($nodes.Count) nodes"
        $heading = @($nodes | Where-Object { Test-ContractAxNode -Node $_ -Role 'heading' -Label 'Sign in' })
        Assert-Equal 1 $heading.Count 'the heading of the page is in the tree'
    }

    It 'answers the full tree for a page behind another tab and for an off-screen cross-site frame' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $other = Invoke-WebCdp -Connection $script:Cdp -Method 'Target.createTarget' -Params @{ url = 'about:blank' } -DeadlineUtc (Get-ContractDeadline)
        try {
            $null = Invoke-WebCdp -Connection $script:Cdp -Method 'Target.activateTarget' -Params @{ targetId = [string]$other['targetId'] } -DeadlineUtc (Get-ContractDeadline)
            $tree = Invoke-WebCdp -Connection $script:Cdp -Method 'Accessibility.getFullAXTree' -Params @{} -SessionId ([string]$script:Cdp.Page.SessionId) -DeadlineUtc (Get-ContractDeadline)
            $button = @(@($tree['nodes']) | Where-Object { Test-ContractAxNode -Node $_ -Role 'button' -Label 'Sign in' })
            Assert-Equal 1 $button.Count 'a page behind another tab still answers its whole tree'
        } finally {
            $null = Invoke-WebCdp -Connection $script:Cdp -Method 'Target.closeTarget' -Params @{ targetId = [string]$other['targetId'] } -DeadlineUtc (Get-ContractDeadline) -AllowError -32602
        }
        $null = Wait-ContractFrame -Search '?far'
        Assert-Equal 1 $script:Cdp.Page.Children.Count 'the cross-site frame is attached as a child session'
        $child = @($script:Cdp.Page.Children.Values)[0]
        $inner = Invoke-WebCdp -Connection $script:Cdp -Method 'Accessibility.getFullAXTree' -Params @{} -SessionId ([string]$child.SessionId) -DeadlineUtc (Get-ContractDeadline)
        $innerButton = @(@($inner['nodes']) | Where-Object { Test-ContractAxNode -Node $_ -Role 'button' -Label 'Inner action' })
        Assert-Equal 1 $innerButton.Count 'an off-screen cross-site frame answers its whole tree'
    }

    It 'loads a page with a cross-site frame without an idle connection' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $ownRoutes = [ordered]@{
            '^GET /frames\.html[ ?]' = New-YurunaTestHttpReply -Body $script:PageText['frames.html'].Replace('{{log}}', 'function log(s) { document.getElementById(''log'').textContent += s + ''\n''; }') -ContentType 'text/html; charset=utf-8'
            '^GET /inner\.html[ ?]'  = New-YurunaTestHttpReply -Body $script:PageText['inner.html'] -ContentType 'text/html; charset=utf-8'
            '^GET /'                 = New-YurunaTestHttpReply -StatusCode 404 -Body $script:NotFoundPage -ContentType 'text/html; charset=utf-8'
        }
        $own = Start-YurunaTestHttpResponder -Route $ownRoutes -RequestCount 40
        $requests = @()
        try {
            foreach ($load in 1..3) {
                $watch = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Invoke-WebPageOpen -Connection $script:Cdp -Url "$($own.BaseUrl)/frames.html?load=$load" -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
                $null = Wait-ContractForest -Until { param($Forest) @(Get-ContractMatch -Forest $Forest -Role 'button' -Label 'Inner action').Count -eq 2 }
                $watch.Stop()
                Assert-True ($watch.ElapsedMilliseconds -lt 2000) "load $load with both frames took $($watch.ElapsedMilliseconds) ms"
            }
            $null = Open-ContractPage -Path 'next.html'
        } finally {
            $requests = @(Stop-YurunaTestHttpResponder $own)
        }
        Assert-True ($requests.Count -ge 9) "the responder read $($requests.Count) requests for three loads of three documents"
        $idle = @($requests | Where-Object { [string]::IsNullOrWhiteSpace($_) })
        Assert-Equal 0 $idle.Count 'the browser opened a connection it sent no request on: the profile lacks the network prediction preference'
    }
}

Describe 'locating' {
    It 'finds controls by role and name, the name taken from a label, a placeholder, aria-label and content' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'duplicates.html'
        $forest = Get-ContractForest
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'textbox' -Label 'Nickname').Count 'a name from a label'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'textbox' -Label 'Search here').Count 'a name from a placeholder'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'textbox' -Label 'Postal code').Count 'a name from aria-label on a field'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Close panel').Count 'a name from aria-label on a button'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Save').Count 'a name from content'
        $null = Open-ContractPage -Path 'basic.html'
        $basic = Get-ContractForest
        Assert-Equal 1 @(Get-ContractMatch -Forest $basic -Role 'textbox' -Label 'Email').Count 'a labeled text field'
        Assert-Equal 1 @(Get-ContractMatch -Forest $basic -Role 'checkbox' -Label 'Remember me').Count 'a label-wrapped check box'
        Assert-Equal 1 @(Get-ContractMatch -Forest $basic -Role 'combobox' -Label 'Country').Count 'a labeled select'
        Assert-Equal 1 @(Get-ContractMatch -Forest $basic -Role 'link' -Label 'Next page').Count 'a link'
        Assert-Equal 1 @(Get-ContractMatch -Forest $basic -Role 'heading' -Label 'Sign in').Count 'a heading'
    }

    It 'ignores case and white space in a name' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'duplicates.html'
        $forest = Get-ContractForest
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'save as copy').Count 'the padded, mixed-case name matches'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label '  SAVE   draft ').Count 'white space and case of the wanted name do not matter'
    }

    It 'tells Save from Save draft unless contains is asked' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'duplicates.html'
        $forest = Get-ContractForest
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Save').Count 'the whole name by default'
        Assert-Equal 3 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Save' -Match 'contains').Count 'a part of the name with contains'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Save' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'save') 'the exact Save button was clicked once'
        Assert-Equal 0 (Get-ContractLineCount -Line 'save draft') 'Save draft was not clicked'
    }

    It 'refuses two Delete buttons and lists them, and clicks the second with nth' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'duplicates.html'
        $effect = Get-ContractEffect
        $failure = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Delete' }) -Effect $effect }
        Assert-StringEqual 'ambiguous' ([string]$failure.Kind)
        Assert-Equal 2 @($failure.Candidates).Count 'both buttons are listed'
        Assert-Equal 2 ([int]$failure.MatchCount)
        Assert-False $effect.Dispatched 'nothing was sent to the page'
        Assert-Equal 0 @(Get-ContractLog | Where-Object { $_ -like 'delete*' }).Count 'no Delete button was clicked'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Delete'; nth = 2 })
        Assert-Equal 1 (Get-ContractLineCount -Line 'delete 2') 'the second button was clicked once'
        Assert-Equal 0 (Get-ContractLineCount -Line 'delete 1') 'the first button was not clicked'
    }

    It 'does not see elements hidden by display, visibility, the hidden attribute or aria-hidden' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $forest = Get-ContractForest
        foreach ($hiddenName in 'Gone display', 'Gone visibility', 'Gone hidden', 'Gone aria') {
            Assert-Equal 0 @(Get-ContractMatch -Forest $forest -Role 'button' -Label $hiddenName).Count "$hiddenName is not seen"
        }
    }

    It 'finds controls inside an open and a closed shadow root' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'shadow.html'
        $forest = Get-ContractForest
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'textbox' -Label 'Shadow name').Count 'a labeled field in an open root'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Shadow open').Count 'a button in an open root'
        Assert-Equal 1 @(Get-ContractMatch -Forest $forest -Role 'button' -Label 'Shadow closed').Count 'a button in a closed root'
    }

    It 'finds controls in a same-origin and a cross-site frame, in document order' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $forest = Wait-ContractFrame
        # getTargets answers only page targets unless its own filter names more.
        $listed = Invoke-WebCdp -Connection $script:Cdp -Method 'Target.getTargets' -Params @{ filter = @(@{ type = 'iframe' }) } -DeadlineUtc (Get-ContractDeadline)
        $frameTargets = @(@($listed['targetInfos']) | Where-Object { [string]$_['type'] -ceq 'iframe' -and [string]$_['url'] -like 'http://localhost:*' })
        Assert-True ($frameTargets.Count -ge 1) 'the frame from localhost runs out of process; without that the case would test the same-process path twice'
        Assert-Equal 1 $script:Cdp.Page.Children.Count 'the connection holds one child session'
        $buttons = @($forest.Entries | Where-Object { [string]$_.Role -ceq 'button' -and [int]$_.Address.BackendNodeId -gt 0 } | ForEach-Object { [string]$_.Name })
        Assert-StringEqual 'Outer action,Inner action,Inner action' ($buttons -join ',')
        $inner = Get-ContractMatch -Forest $forest -Role 'button' -Label 'Inner action'
        Assert-StringEqual ([string]$script:Cdp.Page.SessionId) ([string]$inner[0].Address.SessionId) 'the same-origin frame is read on the page session'
        Assert-NotEqual ([string]$script:Cdp.Page.SessionId) ([string]$inner[1].Address.SessionId) 'the cross-site frame is read on its own session'
        Assert-Equal 1 @($inner[1].Address.Owners).Count 'the cross-site button has its iframe as owner'
    }

    It 'picks the nth match in document order across frames' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Wait-ContractFrame
        $effect = Get-ContractEffect
        $failure = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Inner action' }) -Effect $effect }
        Assert-StringEqual 'ambiguous' ([string]$failure.Kind)
        Assert-Equal 2 @($failure.Candidates).Count
        Assert-False $effect.Dispatched 'no click without nth'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Inner action'; nth = 1 })
        Assert-Equal 1 (Wait-ContractLine -Line 'inner 127.0.0.1') 'nth 1 is the button of the frame the page holds first'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Inner action'; nth = 2 })
        Assert-Equal 1 (Wait-ContractLine -Line 'inner localhost') 'nth 2 is the button of the cross-site frame'
        Assert-Equal 1 (Get-ContractLineCount -Line 'inner 127.0.0.1') 'the first frame was clicked once in all'
    }

    It 'shows the buttons of the page and of both frames in the snapshot entries' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $forest = Wait-ContractFrame
        $all = Get-WebPageSnapshotEntry -Forest $forest
        $entries = @($all | Where-Object { $_.Kind -eq 'node' -and [string]$_.Role -ceq 'button' })
        Assert-StringEqual 'Outer action,Inner action,Inner action' (@($entries | ForEach-Object { [string]$_.Name }) -join ',')
        foreach ($entry in $entries) { Assert-NotNull $entry.Address "$($entry.Name) has an address" }
        Assert-StringEqual ([string]$script:Cdp.Page.SessionId) ([string]$entries[1].Address.SessionId)
        Assert-NotEqual ([string]$script:Cdp.Page.SessionId) ([string]$entries[2].Address.SessionId) 'the cross-site button names another session'
    }

    It 'finds elements by css in the top document only' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Wait-ContractFrame
        $null = Invoke-ContractClick -Locator ([ordered]@{ css = 'button' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'outer') 'the one button of the top document was clicked'
        $failure = Get-ContractFailure { Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ css = '#inner-btn' }) -DeadlineUtc (Get-ContractDeadline -Seconds 2) }
        Assert-StringEqual 'expectation' ([string]$failure.Kind) 'a css locator does not enter frames'
        Assert-Equal 0 ([int]$failure.MatchCount)
    }
}

Describe 'clicking' {
    It 'clicks a button by name' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $effect = Get-ContractEffect
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Sign in' }) -Effect $effect
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'both effect facts are true'
        $log = @(Get-ContractLog)
        Assert-StringEqual 'signin detail=1' ($log -join '|') 'one click with detail 1'
        Assert-StringEqual 'Signed in' ([string](Invoke-ContractEval -Expression 'document.getElementById(''status'').textContent'))
        Assert-False (Invoke-ContractEval -Expression '!!document.getElementById(''intro'')') 'the paragraph was removed'
    }

    It 'waits for a disabled button and clicks it once' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Later' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'later')
    }

    It 'waits for a cover to go away and clicks once' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Covered' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'covered')
        Assert-False (Invoke-ContractEval -Expression '!!document.getElementById(''cover'')') 'the click came after the cover went'
    }

    It 'waits for a moving button to stop' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Moving' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'moving')
    }

    It 'scrolls to a button far down the page and clicks it' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Far down' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'far')
        Assert-True ([double](Invoke-ContractEval -Expression 'window.scrollY') -gt 1000) 'the page was scrolled to the button'
    }

    It 'clicks the button that replaced a detached one, once' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Replaced' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'replaced')
    }

    It 'fails as not_actionable on a zero-size and on a covered button and names the cover' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $zeroEffect = Get-ContractEffect
        $zero = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Zero size' }) -Seconds 2 -Effect $zeroEffect }
        Assert-StringEqual 'not_actionable' ([string]$zero.Kind)
        Assert-StringEqual 'no box' ([string]$zero.Detail)
        Assert-False $zeroEffect.Dispatched
        $coverEffect = Get-ContractEffect
        $covered = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Under cover' }) -Seconds 2 -Effect $coverEffect }
        Assert-StringEqual 'not_actionable' ([string]$covered.Kind)
        Assert-StringEqual 'covered by <DIV id=lid>' ([string]$covered.Detail)
        Assert-False $coverEffect.Dispatched
        Assert-Equal 0 ((Get-ContractLineCount -Line 'zero') + (Get-ContractLineCount -Line 'under')) 'neither button was clicked'
    }

    It 'does not click an aria-disabled button' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        $effect = Get-ContractEffect
        $failure = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Aria off' }) -Seconds 2 -Effect $effect }
        Assert-StringEqual 'not_actionable' ([string]$failure.Kind)
        Assert-StringEqual 'disabled' ([string]$failure.Detail)
        Assert-False $effect.Dispatched
        Assert-Equal 0 (Get-ContractLineCount -Line 'aria')
    }

    It 'clicks inside a same-origin frame and a cross-site frame, also far down and scrolled inside' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        foreach ($search in '', '?far', '?deep') {
            $null = Wait-ContractFrame -Search $search
            $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Inner action'; nth = 1 })
            Assert-Equal 1 (Wait-ContractLine -Line 'inner 127.0.0.1') "the same-origin frame reports its host ($search)"
            $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Inner action'; nth = 2 })
            Assert-Equal 1 (Wait-ContractLine -Line 'inner localhost') "the cross-site frame reports its host ($search)"
        }
    }

    It 'clicks inside a shadow root' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'shadow.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Shadow open' })
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Shadow closed' })
        Assert-StringEqual 'shadow open|shadow closed' (@(Get-ContractLog) -join '|')
    }
}

Describe 'filling' {
    It 'replaces the content of a text field, a textarea and an editable box' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $effect = Get-ContractEffect
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Email' }) -Text 'maria@example.test' -DeadlineUtc (Get-ContractDeadline) -Effect $effect
        Assert-True ($effect.Dispatched -and $effect.Acknowledged)
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Notes' }) -Text 'new notes' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual 'maria@example.test' ([string](Invoke-ContractEval -Expression 'document.getElementById(''email'').value')) 'the old value was replaced'
        Assert-StringEqual 'new notes' ([string](Invoke-ContractEval -Expression 'document.getElementById(''notes'').value'))
        Assert-Equal 1 (Get-ContractLineCount -Line 'input email true') 'one trusted input event for the field'
        Assert-Equal 1 (Get-ContractLineCount -Line 'input notes true') 'one trusted input event for the textarea'
        $null = Open-ContractPage -Path 'form.html'
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Editor' }) -Text 'new text' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual 'new text' ([string](Invoke-ContractEval -Expression 'document.getElementById(''editor'').textContent'))
        Assert-Equal 1 (Get-ContractLineCount -Line 'input editor true') 'one trusted input event for the editable box'
    }

    It 'fills Unicode outside the basic plane and reads it back' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $wanted = 'clef ' + [char]::ConvertFromUtf32(0x1D11E) + ' caf' + [char]0x00E9 + ' ' + [char]::ConvertFromUtf32(0x1F600)
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Email' }) -Text $wanted -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-True ([string]::Equals($wanted, [string](Invoke-ContractEval -Expression 'document.getElementById(''email'').value'), [StringComparison]::Ordinal)) 'the value is the text, unit for unit'
    }

    It 'empties a field with an empty text' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Email' }) -Text '' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual '' ([string](Invoke-ContractEval -Expression 'document.getElementById(''email'').value'))
    }

    It 'fills a password and compares lengths only' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Password' }) -Text 'fixture-secret-7' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual 'fixture-secret-7' ([string](Invoke-ContractEval -Expression 'document.getElementById(''pw'').value')) 'the field holds the text although the tree shows bullets'
        Assert-Equal 1 (Get-ContractLineCount -Line 'input pw true')
    }

    It 'fails as expectation when maxlength cuts the value' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'form.html'
        $effect = Get-ContractEffect
        $failure = Get-ContractFailure { Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Short' }) -Text 'abcdefgh' -DeadlineUtc (Get-ContractDeadline) -Effect $effect }
        Assert-StringEqual 'expectation' ([string]$failure.Kind)
        Assert-StringEqual 'value differs: wanted 8 characters, read 5' ([string]$failure.Detail)
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'the text was handed to the page'
    }

    It 'refuses a read-only and a disabled field' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'overlay.html'
        foreach ($fieldName in 'Fixed value', 'Off field') {
            $effect = Get-ContractEffect
            $failure = Get-ContractFailure { Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = $fieldName }) -Text 'y' -DeadlineUtc (Get-ContractDeadline -Seconds 2) -Effect $effect }
            Assert-StringEqual 'not_actionable' ([string]$failure.Kind) $fieldName
            Assert-False $effect.Dispatched "$fieldName got no input"
        }
        Assert-StringEqual 'x' ([string](Invoke-ContractEval -Expression 'document.getElementById(''fixed'').value'))
        Assert-StringEqual '' ([string](Invoke-ContractEval -Expression 'document.getElementById(''off'').value'))
    }

    It 'fills a field inside a cross-site frame' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Wait-ContractFrame
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Inner field'; nth = 2 }) -Text 'far text' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-Equal 1 (Wait-ContractLine -Line 'inner-input localhost far text') 'the cross-site field received the text once'
        Assert-Equal 0 @(Get-ContractLog | Where-Object { $_ -like 'inner-input 127.0.0.1*' }).Count 'the same-origin field was not touched'
    }
}

Describe 'selecting' {
    It 'selects by label without regard to case and fires input and change once' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'select.html'
        $effect = Get-ContractEffect
        $null = Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'combobox'; name = 'Color' }) -Option 'gREEN' -DeadlineUtc (Get-ContractDeadline) -Effect $effect
        Assert-True ($effect.Dispatched -and $effect.Acknowledged)
        Assert-Equal 1 ([int](Invoke-ContractEval -Expression 'document.getElementById(''color'').selectedIndex'))
        Assert-StringEqual 'input false|change false' (@(Get-ContractLog) -join '|') 'one input and one change, dispatched by the fixed function'
        $null = Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'combobox'; name = 'Color' }) -Option 'sky label' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual 'sky' ([string](Invoke-ContractEval -Expression 'document.getElementById(''color'').value')) 'an option is found by its label attribute'
        $null = Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'combobox'; name = 'Color' }) -Option 'wide option' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-Equal 7 ([int](Invoke-ContractEval -Expression 'document.getElementById(''color'').selectedIndex')) 'white space inside a label does not matter'
    }

    It 'changes nothing when the option is already selected' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'select.html'
        $effect = Get-ContractEffect
        $null = Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'combobox'; name = 'Color' }) -Option 'Red' -DeadlineUtc (Get-ContractDeadline) -Effect $effect
        Assert-False $effect.Dispatched 'nothing changed on the page'
        Assert-Equal 0 @(Get-ContractLog).Count 'no input or change was fired'
    }

    It 'fails on a duplicate label, a disabled option, an option of a disabled group and a missing option with the reasons of the fixed function' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'select.html'
        $cases = @(
            @{ Option = 'Twin'; Kind = 'ambiguous'; Detail = 'option' }
            @{ Option = 'Off'; Kind = 'not_actionable'; Detail = 'option disabled' }
            @{ Option = 'Grouped'; Kind = 'not_actionable'; Detail = 'option disabled' }
            @{ Option = 'Purple'; Kind = 'not_found'; Detail = 'option' }
        )
        foreach ($case in $cases) {
            $wantedOption = $case.Option
            $effect = Get-ContractEffect
            $failure = Get-ContractFailure { Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'combobox'; name = 'Color' }) -Option $wantedOption -DeadlineUtc (Get-ContractDeadline -Seconds 2) -Effect $effect }
            Assert-StringEqual $case.Kind ([string]$failure.Kind) $wantedOption
            Assert-StringEqual $case.Detail ([string]$failure.Detail) $wantedOption
            Assert-False $effect.Dispatched "$wantedOption changed nothing"
            Assert-Equal 0 ([int](Invoke-ContractEval -Expression 'document.getElementById(''color'').selectedIndex')) "$wantedOption left the selection"
        }
        Assert-Equal 0 @(Get-ContractLog).Count 'no input or change was fired'
    }

    It 'refuses a multiple select and an element that is no select' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'select.html'
        $multiple = Get-ContractFailure { Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'listbox'; name = 'Many' }) -Option 'One' -DeadlineUtc (Get-ContractDeadline -Seconds 2) -Effect (Get-ContractEffect) }
        Assert-StringEqual 'not_actionable' ([string]$multiple.Kind)
        Assert-StringEqual 'multiple' ([string]$multiple.Detail)
        $notSelect = Get-ContractFailure { Invoke-WebPageSelect -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'Notes' }) -Option 'One' -DeadlineUtc (Get-ContractDeadline -Seconds 2) -Effect (Get-ContractEffect) }
        Assert-StringEqual 'not_actionable' ([string]$notSelect.Kind)
        Assert-StringEqual 'not-a-select' ([string]$notSelect.Detail)
    }
}

Describe 'checking' {
    It 'checks, leaves checked, unchecks and leaves unchecked a box' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        $box = [ordered]@{ role = 'checkbox'; name = 'Remember me' }
        foreach ($wanted in $true, $true, $false, $false) {
            $null = Invoke-WebPageClick -Connection $script:Cdp -Locator $box -Checked $wanted -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
            Assert-Equal $wanted ([bool](Invoke-ContractEval -Expression 'document.getElementById(''remember'').checked'))
        }
        Assert-Equal 2 (Get-ContractLineCount -Line 'remember click') 'two clicks in four steps'
    }

    It 'checks a radio button' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'form.html'
        $null = Invoke-WebPageClick -Connection $script:Cdp -Locator ([ordered]@{ role = 'radio'; name = 'Large' }) -Checked $true -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-True ([bool](Invoke-ContractEval -Expression 'document.getElementById(''large'').checked'))
        Assert-False ([bool](Invoke-ContractEval -Expression 'document.getElementById(''small'').checked'))
    }
}

Describe 'keys' {
    It 'submits a form with Enter' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'form.html'
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'First' }) -Text 'x' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        $null = Invoke-WebPagePress -Connection $script:Cdp -Key 'Enter' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-Equal 1 (Get-ContractLineCount -Line 'submit')
    }

    It 'moves focus with Tab and toggles a box with Space' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'form.html'
        $null = Invoke-WebPageFill -Connection $script:Cdp -Locator ([ordered]@{ role = 'textbox'; name = 'First' }) -Text 'x' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        $null = Invoke-WebPagePress -Connection $script:Cdp -Key 'Tab' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-StringEqual 'agree' ([string](Invoke-ContractEval -Expression 'document.activeElement.id'))
        $null = Invoke-WebPagePress -Connection $script:Cdp -Key 'Space' -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        Assert-True ([bool](Invoke-ContractEval -Expression 'document.getElementById(''agree'').checked'))
    }

    It 'sends the arrow, Escape and function keys as key events without leaving the page' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'form.html'
        # Set by the case, not by the page: a reload would run the page's
        # script again and set a page-made mark again.
        $null = Invoke-ContractEval -Expression 'window.__mark = ''kept'''
        $sent = @('Left', 'Right', 'Up', 'Down', 'Escape', 'F5', 'F11', 'F12')
        foreach ($keyName in $sent) {
            $null = Invoke-WebPagePress -Connection $script:Cdp -Key $keyName -DeadlineUtc (Get-ContractDeadline) -Effect (Get-ContractEffect)
        }
        Assert-StringEqual 'key ArrowLeft|key ArrowRight|key ArrowUp|key ArrowDown|key Escape|key F5|key F11|key F12' (@(Get-ContractLog) -join '|') 'each key arrived once, in order'
        Assert-StringEqual 'kept' ([string](Invoke-ContractEval -Expression 'window.__mark')) 'F5 did not reload the page'
    }
}

Describe 'expecting' {
    It 'finds a heading' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Texts' }) -DeadlineUtc (Get-ContractDeadline)
    }

    It 'finds text that spans several text nodes and inline elements' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        foreach ($shown in 'Hello, maria!', 'Welcome aboard', 'Line one Line two') {
            $null = Invoke-WebPageExpect -Connection $script:Cdp -Text $shown -DeadlineUtc (Get-ContractDeadline -Seconds 3)
        }
    }

    It 'reads transformed text as rendered' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $forest = Get-ContractForest
        Assert-True (([string]$forest.Text).Contains('QUIET WORDS')) "the page text holds the rendered upper case: $($forest.Text)"
    }

    It 'does not find hidden text or a field value' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $forest = Get-ContractForest
        foreach ($absent in 'Gone display', 'Gone visibility', 'Gone hidden', 'Gone aria', 'typed value') {
            Assert-False (Test-WebPageText -Forest $forest -Text $absent) "$absent is not page text"
        }
        $failure = Get-ContractFailure { Invoke-WebPageExpect -Connection $script:Cdp -Text 'typed value' -DeadlineUtc (Get-ContractDeadline -Seconds 1) }
        Assert-StringEqual 'expectation' ([string]$failure.Kind)
    }

    It 'waits for text that arrives late' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Text 'Late arrival' -DeadlineUtc (Get-ContractDeadline)
    }

    It 'finds text that two elements show at once' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $notice = [ordered]@{ role = 'note'; name = 'Equal notice' }
        Assert-Equal 2 @(Get-ContractMatch -Forest (Get-ContractForest) -Role 'note' -Label 'Equal notice').Count 'both notices are shown'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator $notice -DeadlineUtc (Get-ContractDeadline)
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Text 'Equal notice' -DeadlineUtc (Get-ContractDeadline)
    }

    It 'waits until both equal notices are gone, with no ambiguity error' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'note'; name = 'Equal notice' }) -Gone -DeadlineUtc (Get-ContractDeadline)
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Text 'Equal notice' -Gone -DeadlineUtc (Get-ContractDeadline)
        Assert-False ([bool](Invoke-ContractEval -Expression '!!document.getElementById(''n2'')')) 'the second notice was removed before the expectation passed'
    }

    It 'fails as expectation when text never arrives' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'text.html'
        $failure = Get-ContractFailure { Invoke-WebPageExpect -Connection $script:Cdp -Text 'Never shown' -DeadlineUtc (Get-ContractDeadline -Seconds 2) }
        Assert-StringEqual 'expectation' ([string]$failure.Kind)
        Assert-StringEqual 'found 0' ([string]$failure.Detail)
        Assert-Equal 0 ([int]$failure.MatchCount)
    }
}

Describe 'navigating' {
    It 'opens a page and reports its URL and title' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $result = Open-ContractPage -Path 'basic.html'
        Assert-StringEqual "$script:Base/basic.html" ([string]$result.Url)
        Assert-True $result.Navigated
        Assert-StringEqual 'Sign in page' ([string](Get-ContractForest).Title)
    }

    It 'follows a link, a script navigation at once, after 0 ms and after 300 ms' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $starts = @(
            [ordered]@{ role = 'link'; name = 'Plain link' }
            [ordered]@{ role = 'button'; name = 'Go now' }
            [ordered]@{ role = 'button'; name = 'Go zero' }
            [ordered]@{ role = 'button'; name = 'Go later' }
        )
        foreach ($start in $starts) {
            $null = Open-ContractPage -Path 'nav.html'
            $result = Invoke-ContractClick -Locator $start
            Assert-True $result.Navigated "$($start.name) navigated"
            Assert-StringEqual "$script:Base/next.html" ([string]$result.Url) "$($start.name) arrived"
            $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Next page here' }) -DeadlineUtc (Get-ContractDeadline -Seconds 2)
        }
    }

    It 'settles a fragment and a pushState navigation' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'nav.html'
        $fragment = Invoke-ContractClick -Locator ([ordered]@{ role = 'link'; name = 'Fragment' })
        Assert-StringEqual "$script:Base/nav.html#part" ([string]$fragment.Url)
        $pushed = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Push state' })
        Assert-StringEqual "$script:Base/pushed" ([string]$pushed.Url)
    }

    It 'fails an open of a closed port as navigation and names the network error' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $effect = Get-ContractEffect
        $failure = Get-ContractFailure { Invoke-WebPageOpen -Connection $script:Cdp -Url "http://127.0.0.1:$script:ClosedPort/" -DeadlineUtc (Get-ContractDeadline) -Effect $effect }
        Assert-StringEqual 'navigation' ([string]$failure.Kind)
        Assert-Match '^net::ERR_' ([string]$failure.Detail) 'the network error is named'
        Assert-True ($effect.Dispatched -and $effect.Acknowledged) 'the browser took the URL'
    }

    It 'fails a click on a link to a closed port as navigation' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'nav.html'
        $failure = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'link'; name = 'Closed link' }) }
        Assert-StringEqual 'navigation' ([string]$failure.Kind)
        Assert-Match '^unreachable: http://127\.0\.0\.1:' ([string]$failure.Detail)
    }

    It 'fails as navigation when a load does not finish before the deadline' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $open = Get-ContractFailure { Invoke-WebPageOpen -Connection $script:Cdp -Url "http://127.0.0.1:$($script:Hang.Port)/" -DeadlineUtc (Get-ContractDeadline -Seconds 3) -Effect (Get-ContractEffect) }
        $watch.Stop()
        Assert-StringEqual 'navigation' ([string]$open.Kind)
        Assert-StringEqual 'no response' ([string]$open.Detail)
        Assert-True ($watch.ElapsedMilliseconds -lt 30000) "the open returned after $($watch.ElapsedMilliseconds) ms"
        $null = Open-ContractPage -Path 'nav.html'
        $watch.Restart()
        $click = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'link'; name = 'Hang link' }) -Seconds 3 }
        $watch.Stop()
        Assert-StringEqual 'navigation' ([string]$click.Kind)
        Assert-StringEqual 'load did not finish' ([string]$click.Detail)
        Assert-True ($watch.ElapsedMilliseconds -lt 30000) "the click returned after $($watch.ElapsedMilliseconds) ms"
    }

    It 'settles a click that does not navigate in about half a second' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'nav.html'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Text only' })
        $watch.Stop()
        Assert-False $result.Navigated
        Assert-True ($watch.ElapsedMilliseconds -ge 450 -and $watch.ElapsedMilliseconds -le 5000) "the click settled after $($watch.ElapsedMilliseconds) ms"
        Assert-StringEqual 'Changed text' ([string](Invoke-ContractEval -Expression 'document.getElementById(''msg'').textContent'))
    }

    It 'opens a page that answers 404' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $result = Open-ContractPage -Path 'missing.html'
        Assert-StringEqual "$script:Base/missing.html" ([string]$result.Url)
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Text 'Not found here' -DeadlineUtc (Get-ContractDeadline -Seconds 2)
    }
}

Describe 'dialogs, windows and downloads' {
    It 'dismisses an alert and a confirm, fails as unsupported and can go on' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'dialog.html'
        $alertEffect = Get-ContractEffect
        $alert = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Alert' }) -Effect $alertEffect }
        Assert-StringEqual 'unsupported' ([string]$alert.Kind)
        Assert-StringEqual 'dialog: alert' ([string]$alert.Detail)
        Assert-True $alertEffect.Dispatched
        $confirm = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Confirm' }) }
        Assert-StringEqual 'unsupported' ([string]$confirm.Kind)
        Assert-StringEqual 'dialog: confirm' ([string]$confirm.Detail)
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Dialogs' }) -DeadlineUtc (Get-ContractDeadline)
        Assert-StringEqual 'after alert|confirm false' (@(Get-ContractLog) -join '|') 'the confirm was dismissed, not accepted, and each click ran once'
    }

    It 'closes a window opened by target _blank and by window.open and fails as unsupported' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'dialog.html'
        $owned = [string]$script:Cdp.Page.TargetId
        $pagesBefore = @(Get-ContractTarget | Where-Object { [string]$_['type'] -ceq 'page' }).Count
        foreach ($opener in @([ordered]@{ role = 'link'; name = 'New tab' }, [ordered]@{ role = 'button'; name = 'Open window' })) {
            $failure = Get-ContractFailure { Invoke-ContractClick -Locator $opener }
            Assert-StringEqual 'unsupported' ([string]$failure.Kind) $opener.name
            Assert-StringEqual 'popup' ([string]$failure.Detail) $opener.name
            $until = [DateTime]::UtcNow.AddSeconds(3)
            do {
                $targets = @(Get-ContractTarget)
                $children = @($targets | Where-Object { [string]$_['openerId'] -ceq $owned })
                if ($children.Count -eq 0) { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $until)
            Assert-Equal 0 $children.Count "the window of $($opener.name) was closed"
            Assert-Equal $pagesBefore @($targets | Where-Object { [string]$_['type'] -ceq 'page' }).Count 'as many pages as before the click'
            Assert-StringEqual $owned ([string]$script:Cdp.Page.TargetId) 'the owned page is the one it was'
            $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Dialogs' }) -DeadlineUtc (Get-ContractDeadline)
        }
    }

    It 'accepts a leave-page prompt during an open' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'dialog.html'
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Arm leave' })
        Assert-Equal 1 (Get-ContractLineCount -Line 'armed')
        $result = Open-ContractPage -Path 'basic.html'
        Assert-StringEqual "$script:Base/basic.html" ([string]$result.Url) 'the prompt was accepted and the page left'
    }

    It 'refuses a download and fails as unsupported' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'dialog.html'
        $clickEffect = Get-ContractEffect
        $click = Get-ContractFailure { Invoke-ContractClick -Locator ([ordered]@{ role = 'link'; name = 'Download file' }) -Effect $clickEffect }
        Assert-StringEqual 'unsupported' ([string]$click.Kind)
        Assert-StringEqual 'download' ([string]$click.Detail)
        Assert-True ($clickEffect.Dispatched -and $clickEffect.Acknowledged)
        $openEffect = Get-ContractEffect
        $open = Get-ContractFailure { Invoke-WebPageOpen -Connection $script:Cdp -Url "$script:Base/download.bin" -DeadlineUtc (Get-ContractDeadline) -Effect $openEffect }
        Assert-StringEqual 'unsupported' ([string]$open.Kind)
        Assert-StringEqual 'download' ([string]$open.Detail)
        Assert-True ($openEffect.Dispatched -and $openEffect.Acknowledged)
        Assert-True (Test-WebCdpOpen -Connection $script:Cdp) 'the owned page stays open'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Dialogs' }) -DeadlineUtc (Get-ContractDeadline)
    }

    It 'closes a page whose dialog is open' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $second = Connect-WebCdp -Port $script:Browser.Port -DeadlineUtc (Get-ContractDeadline -Seconds 30)
        try {
            Open-WebCdpPage -Connection $second -DeadlineUtc (Get-ContractDeadline -Seconds 30)
            $secondTarget = [string]$second.Page.TargetId
            $null = Open-ContractPage -Path 'dialog.html' -Connection $second
            $null = Invoke-WebCdp -Connection $second -Method 'Runtime.evaluate' -Params @{ expression = "setTimeout(function () { alert('x'); }, 0)" } `
                -SessionId ([string]$second.Page.SessionId) -DeadlineUtc (Get-ContractDeadline)
            Start-Sleep -Milliseconds 300
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Close-WebCdp -Connection $second
            $watch.Stop()
            Assert-True ($watch.ElapsedMilliseconds -lt 20000) "the close took $($watch.ElapsedMilliseconds) ms"
            $left = @(Get-ContractTarget | Where-Object { [string]$_['targetId'] -ceq $secondTarget })
            Assert-Equal 0 $left.Count 'the page with the open dialog is gone'
        } finally {
            Close-WebCdp -Connection $second
        }
    }
}

Describe 'cost' {
    It 'reads a page of 300 table rows and clicks one of its buttons' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'table.html'
        $tree = Invoke-WebCdp -Connection $script:Cdp -Method 'Accessibility.getFullAXTree' -Params @{} -SessionId ([string]$script:Cdp.Page.SessionId) -DeadlineUtc (Get-ContractDeadline)
        $size = (ConvertTo-Json -InputObject $tree -Depth 32 -Compress).Length
        Assert-True ($size -gt 1000000) "the tree reply is $size characters; the case guards the large-reply path only above 1 MB"
        $null = Invoke-ContractClick -Locator ([ordered]@{ role = 'button'; name = 'Pick 250' })
        Assert-StringEqual 'pick 250' (@(Get-ContractLog) -join '|') 'the one button was clicked once'
    }
}

Describe 'loss' {
    It 'fails as page_lost after the page crashes and opens again afterwards' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        $null = Open-ContractPage -Path 'basic.html'
        # Page.crash never answers: it is sent without waiting for a reply.
        InModuleScope Test.WebSession -Parameters @{ Connection = $script:Cdp } {
            param($Connection)
            $null = Send-WebCdpCommand -Connection $Connection -Method 'Page.crash' -SessionId ([string]$Connection.Page.SessionId)
        }
        $failure = Get-ContractFailure { Invoke-WebPageExpect -Connection $script:Cdp -Text 'Sign in' -DeadlineUtc (Get-ContractDeadline) }
        Assert-StringEqual 'page_lost' ([string]$failure.Kind)
        $result = Open-ContractPage -Path 'basic.html'
        Assert-True $result.Navigated 'the crashed page opens again'
        $null = Invoke-WebPageExpect -Connection $script:Cdp -Locator ([ordered]@{ role = 'heading'; name = 'Sign in' }) -DeadlineUtc (Get-ContractDeadline)
    }

    It 'fails as transport when the browser goes away' {
        if (-not $script:Chrome) { Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to drive'; return }
        Stop-YurunaTestBrowser -Session $script:Browser
        $script:Browser = $null
        $failure = Get-ContractFailure { Invoke-WebCdp -Connection $script:Cdp -Method 'Browser.getVersion' -DeadlineUtc (Get-ContractDeadline) }
        Assert-StringEqual 'transport' ([string]$failure.Kind)
    }
}
