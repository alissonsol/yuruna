<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b7e04d-95c1-4a2f-8d63-70e1c9a4b528
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization slice status pause pseudo pester
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
    Drive one persisted event from the runner that produced it to the page a
    reader sees, in English and then in a pseudo-locale, from the same record.
.DESCRIPTION
    This is the slice that decides whether any of the catalog work is real.
    Everything before it was machinery: a compiler, a renderer, a set of gates.
    None of it proves that a state a PowerShell runner recorded can be shown to
    a reader in a language chosen where the reader is.

    The chain it exercises is the whole one. The runner writes what happened as
    a CODE and a label -- not as a sentence -- into the file the status service
    serves. The browser reads that record and renders it from its own catalog.
    Point the same record at a second locale and the same code produces
    different words, which is the property that makes translation possible at
    all: nothing between the two ends carries English.

    The producer still writes its own sentence beside the code, and a surface
    that cannot render one still shows it. That fallback is what lets an older
    page, a log tail and a transcript keep working while the conversion happens.

    Run: Invoke-Pester -Path test/modules/Test.StatusPauseSlice.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Runtime = Join-Path $script:RepoRoot 'test/status/yuruna.common.js'
$script:PseudoAsset = Join-Path $script:RepoRoot 'globalization/generated/browser/qps-Ploc.status.js'
$script:MirroredAsset = Join-Path $script:RepoRoot 'globalization/generated/browser/qps-Plocm.status.js'

$script:Chrome = $null
foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $script:Chrome = $c.Source; break }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-slice-" + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:Sandbox -Force
Copy-Item -LiteralPath $script:Runtime -Destination (Join-Path $script:Sandbox 'yuruna.common.js') -Force
Copy-Item -LiteralPath $script:PseudoAsset -Destination (Join-Path $script:Sandbox 'qps-Ploc.status.js') -Force
Copy-Item -LiteralPath $script:MirroredAsset -Destination (Join-Path $script:Sandbox 'qps-Plocm.status.js') -Force

function Invoke-SlicePage {
    <#
    .SYNOPSIS
        Render one page and return what it wrote, one labeled row per line.
    .PARAMETER Preamble
        Script that runs BEFORE the runtime, so it decides what the runtime
        finds. Used to take capabilities away.
    .PARAMETER Extra
        Extra scripts to load after the runtime, in order. The non-default
        locale asset arrives this way, which is how a page actually gets one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Body,
        [string]$Preamble = '',
        [string[]]$Extra = @(),
        [string]$Lang = 'en-US',
        [ValidateSet('ltr', 'rtl')][string]$Direction = 'ltr'
    )

    $extraTags = ($Extra | ForEach-Object { "<script src=`"$_`"></script>" }) -join "`n"
    $page = @"
<!doctype html><html lang="$Lang" dir="$Direction"><head><meta charset="utf-8"><title>slice</title>
<script>
$Preamble
</script></head><body><pre id="out"></pre>
<script src="yuruna.common.js"></script>
$extraTags
<script>
(function () {
  var rows = [];
  function say(label, value) { rows.push(label + '\t' + value); }
  try {
$Body
  } catch (e) {
    say('THREW', (e && e.message) ? e.message : String(e));
  }
  document.getElementById('out').textContent = rows.join('\n');
}());
</script></body></html>
"@
    $pagePath = Join-Path $script:Sandbox "$Name.html"
    [IO.File]::WriteAllText($pagePath, $page)
    $dom = & $script:Chrome --headless --disable-gpu --no-sandbox `
        --virtual-time-budget=5000 --dump-dom "file://$pagePath" 2>$null | Out-String
    $m = [regex]::Match($dom, '(?s)<pre id="out">(.*?)</pre>')
    if (-not $m.Success) { return @{} }
    $out = @{}
    foreach ($line in ([Net.WebUtility]::HtmlDecode($m.Groups[1].Value) -split "`n")) {
        $parts = $line -split "`t", 2
        if ($parts.Count -eq 2) { $out[$parts[0].Trim()] = $parts[1] }
    }
    return $out
}

# The record the runner writes. It carries a code and a label, and the sentence
# only as the fallback for a surface that cannot render one.
$script:PersistedEvent = @'
    var persisted = {
      guestKey: 'workload.guest.example',
      vmName:   'syzor-example',
      line:     '[2/11] workload.guest.example Paused (waiting for resume)',
      code:     'sequence_paused_waiting_resume',
      label:    '[2/11] workload.guest.example',
      updatedAt: '2026-09-03T04:00:00Z'
    };
'@
}

AfterAll {
if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
    Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
}
}

Describe 'the runner records a state, and the reader is shown it in their language' {

    BeforeEach {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
        }
    }

    It 'renders the persisted event in English from its code' {
        $out = Invoke-SlicePage -Name 'english' -Body ($script:PersistedEvent + @'
    say('locale', window.YurunaI18n.init(document));
    say('text', window.Yuruna.actionText(persisted));
'@)
        Assert-StringEqual -Expected 'en-US' -Actual $out['locale'] 'the page did not take the served language'
        Assert-StringEqual -Expected '[2/11] workload.guest.example Paused, waiting for resume.' `
            -Actual $out['text'] 'the English rendering does not come from the catalog'
    }

    It 'renders the same event in a pseudo-locale, from the same code' {
        # The property the whole design exists for. Nothing about the record
        # changed: the same code and the same label produce different words,
        # because the words were never in the record.
        $out = Invoke-SlicePage -Name 'pseudo' -Lang 'qps-Ploc' -Extra @('qps-Ploc.status.js') `
            -Body ($script:PersistedEvent + @'
    say('locale', window.YurunaI18n.init(document));
    say('text', window.Yuruna.actionText(persisted));
    say('label-kept', String(window.Yuruna.actionText(persisted).indexOf('[2/11] workload.guest.example') === 0));
'@)
        Assert-StringEqual -Expected 'qps-Ploc' -Actual $out['locale'] `
            'the page did not resolve to the pseudo locale it was served as'
        Assert-True ($out['text'] -ne '[2/11] workload.guest.example Paused, waiting for resume.') `
            'the pseudo locale rendered the English sentence, so the code is not deciding the words'
        Assert-True ($out['text'] -notmatch 'status\.cycle_paused') `
            'the pseudo locale rendered the key name, so its catalog never loaded'
        Assert-StringEqual -Expected 'True' -Actual $out['label-kept'] `
            'the label is data and must survive the language change unchanged'
    }

    It 'renders that same persisted event in the mirrored pseudo-locale' {
        # This is deliberately the identical record used above. Mirrored text
        # proves both the third shipped catalog and the RTL path; manufacturing
        # a second record here would only prove two unrelated fixtures render.
        $out = Invoke-SlicePage -Name 'pseudo-mirrored' -Lang 'qps-Plocm' -Direction 'rtl' `
            -Extra @('qps-Plocm.status.js') -Body ($script:PersistedEvent + @'
    say('locale', window.YurunaI18n.init(document));
    var rendered = window.Yuruna.actionText(persisted);
    say('text', rendered);
    say('label-kept', String(rendered.indexOf('[2/11] workload.guest.example') === 0));
    say('mirrored', String(rendered.indexOf('\u202E') >= 0 && rendered.indexOf('\u202C') >= 0));
'@)
        Assert-StringEqual -Expected 'qps-Plocm' -Actual $out['locale'] `
            'the page did not resolve to the mirrored pseudo locale it was served as'
        Assert-True ($out['text'] -ne '[2/11] workload.guest.example Paused, waiting for resume.') `
            'the mirrored locale rendered the English sentence'
        Assert-True ($out['text'] -notmatch 'status\.cycle_paused') `
            'the mirrored locale rendered a key because its catalog never loaded'
        Assert-StringEqual -Expected 'True' -Actual $out['label-kept'] `
            'the same persisted label changed under mirrored rendering'
        Assert-StringEqual -Expected 'True' -Actual $out['mirrored'] `
            'the mirrored catalog did not exercise its bounded direction override'
    }

    It 'shows the producer sentence when nothing can render the code' {
        # The bounded fallback: an older page, a log tail, a transcript. Without
        # it the conversion would have to land everywhere at once.
        $out = Invoke-SlicePage -Name 'fallback' -Body @'
    var old = { line: '[2/11] workload.guest.example Paused (waiting for resume)', code: '', label: '' };
    window.YurunaI18n.init(document);
    say('text', window.Yuruna.actionText(old));
    var unknown = { line: 'something a newer runner said', code: 'not_a_code_this_page_knows' };
    say('unknown', window.Yuruna.actionText(unknown));
'@
        Assert-StringEqual -Expected '[2/11] workload.guest.example Paused (waiting for resume)' `
            -Actual $out['text'] 'a record with no code must still read'
        Assert-StringEqual -Expected 'something a newer runner said' -Actual $out['unknown'] `
            'a code this page does not know must fall back rather than render blank'
    }

    It 'leaves no unbracketed sentence under the expanded pseudo locale' {
        # What the expanded pseudo locale is for. Every string that came from
        # the catalog is bracketed; a sentence still hard-coded in the page
        # renders bare, and that is exactly how it is found.
        $out = Invoke-SlicePage -Name 'unbracketed' -Lang 'qps-Ploc' -Extra @('qps-Ploc.status.js') `
            -Body ($script:PersistedEvent + @'
    window.YurunaI18n.init(document);
    var samples = {
      pause:    window.Yuruna.t('status.cycle_paused'),
      resume:   window.Yuruna.t('status.cycle_resume_action'),
      resuming: window.Yuruna.t('status.cycle_resuming'),
      timing:   window.Yuruna.t('status.step_timing_unavailable'),
      duration: window.Yuruna.t('status.cycle_duration', { elapsed: 5400 })
    };
    var bare = [];
    for (var k in samples) {
      if (!Object.prototype.hasOwnProperty.call(samples, k)) { continue; }
      if (samples[k].indexOf('[') !== 0) { bare.push(k); }
    }
    say('bare', bare.join(',') || 'none');
'@)
        Assert-StringEqual -Expected 'none' -Actual $out['bare'] `
            'a message rendered without the pseudo brackets, so it did not come from the catalog'
    }

    It 'frames third-party text and isolates it from the sentence around it' {
        # An error string is attacker-influenced often enough that a value able
        # to reorder the words around it is a real outcome. In particular, an
        # injected PDI must not close our isolate before a following override.
        $out = Invoke-SlicePage -Name 'external' -Body @'
    window.YurunaI18n.init(document);
    // Written as escapes rather than as the characters themselves: this file
    // is ASCII, and an invisible direction control pasted into a source file
    // is exactly the thing nobody can see to review.
    var hostile = 'refused \u2069\u202E rotcev';
    var text = window.Yuruna.controlErrorText(500, { error: hostile });
    say('framed', String(text.indexOf('The tool reported:') === 0));
    say('isolated', String(text.split('\u2068').length === 2 && text.split('\u2069').length === 2));
    say('controls', String(text.indexOf('\u202E') < 0));
    say('content', String(text.indexOf('refused  rotcev') >= 0));
'@
        Assert-StringEqual -Expected 'True' -Actual $out['framed'] 'the external value is not framed by a catalog sentence'
        Assert-StringEqual -Expected 'True' -Actual $out['isolated'] 'the external value is not bidi-isolated'
        Assert-StringEqual -Expected 'True' -Actual $out['controls'] 'an injected bidi control escaped sanitization'
        Assert-StringEqual -Expected 'True' -Actual $out['content'] 'sanitization removed ordinary external text'
    }

    It 'renders the slice with the floor capabilities taken away' {
        # The same rendering with Intl, normalize and native fetch gone, which
        # is what the floor browser offers. A slice that works only on a modern
        # engine proves nothing about the readers this project targets.
        $out = Invoke-SlicePage -Name 'capability-off' -Preamble @'
  try { delete window.Intl; } catch (e) { window.Intl = undefined; }
  try { delete String.prototype.normalize; } catch (e) {}
  try { delete window.fetch; } catch (e) { window.fetch = undefined; }
  try { delete window.AbortController; } catch (e) { window.AbortController = undefined; }
  Number.prototype.toLocaleString = function () { throw new Error('locale-blind'); };
  Date.prototype.toLocaleString = function () { throw new Error('locale-blind'); };
'@ -Body ($script:PersistedEvent + @'
    window.YurunaI18n.init(document);
    say('text', window.Yuruna.actionText(persisted));
    say('duration', window.Yuruna.t('status.cycle_duration', { elapsed: 5400 }));
    say('count', window.Yuruna.t('status.host_online_count', { count: 1234 }));
    say('intl', typeof window.Intl);
'@)
        Assert-StringEqual -Expected '[2/11] workload.guest.example Paused, waiting for resume.' `
            -Actual $out['text'] 'the slice does not render at the floor'
        Assert-StringEqual -Expected 'Duration: 1h 30m' -Actual $out['duration'] 'the duration is wrong at the floor'
        Assert-StringEqual -Expected '1,234 hosts online.' -Actual $out['count'] 'the count is wrong at the floor'
        Assert-StringEqual -Expected 'undefined' -Actual $out['intl'] 'the floor was not actually emulated'
    }
}

Describe 'the runner writes a state rather than a sentence' {

    It 'persists the code and the label beside the line' {
        $engine = Join-Path $script:RepoRoot 'test/modules/Test.SequenceEngine.psm1'
        $text = [IO.File]::ReadAllText($engine)
        Assert-True ($text -match "param\(\[string\]\`$Line, \[string\]\`$Code = '', \[string\]\`$Label = ''\)") `
            'the current-action writer does not take a code and a label'
        Assert-True ($text -match '(?m)^\s+label\s+=\s+\$Label$') `
            'the persisted record does not carry the label'
        Assert-True ($text -match "'sequence_paused_waiting_resume' \`$Label") `
            'the pause site does not record which step and guest it paused on'
    }

    It 'keeps a key for every code a surface renders' {
        # A code the browser maps to a key that no catalog declares would render
        # as the key name, in the middle of otherwise translated text.
        $runtime = [IO.File]::ReadAllText($script:Runtime)
        $m = [regex]::Match($runtime, "(?s)var ACTION_CODE_KEY = \{(.*?)\};")
        Assert-True $m.Success 'the runtime declares no code-to-key map'

        $catalog = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
                (Join-Path $script:RepoRoot 'globalization/catalogs/en-US/status.json')))
        $declared = @($catalog.messages.PSObject.Properties.Name)

        $findings = @()
        foreach ($pair in [regex]::Matches($m.Groups[1].Value, "'([^']+)':\s*'([^']+)'")) {
            $key = $pair.Groups[2].Value
            if ($declared -notcontains $key) {
                $findings += "code '$($pair.Groups[1].Value)' maps to '$key', which the catalog does not declare"
            }
        }
        Assert-NoFinding $findings 'a coded state would render as a key name'
    }
}
