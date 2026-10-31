<#PSScriptInfo
.VERSION 2026.10.31
.GUID 426838e1-71d2-46b1-bc18-fcfc5a3e6391
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test accessibility mobile touch firefox states pester
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
    Hold the paint-based accessibility gate to the views a phone, a second
    engine and an operator's clicks produce.
.DESCRIPTION
    A desktop window never evaluates a (pointer: coarse) rule, never opens a
    menu and never shows an unlock prompt, so each of those surfaces passed the
    gate by never being drawn. Each fixture page here carries a defect that only
    one such view can see, and the gate must find it there and only there:
    a coarse-pointer rule that breaks reflow, a page with no viewport meta that
    a phone lays out 980px wide, a menu and an unlock prompt with low contrast,
    a menu that does not open, and an extension page whose runtime comes from
    the SDK's shared /assets/ folder. Firefox runs the same probes where it is
    installed.

    Run: Invoke-Pester -Path test/modules/Test.A11yGateProfiles.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:A11y = Join-Path $script:RepoRoot 'tools/Invoke-A11yCheck.ps1'
$script:Fixture = Join-Path $TestDrive 'fixture'
$null = New-Item -ItemType Directory -Path $script:Fixture -Force

$viewport = '<meta name="viewport" content="width=device-width, initial-scale=1">'
$pagesByName = [ordered]@{
    'coarse.html' = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">$viewport<style>html { background: #ffffff; color: #111111; }</style><title>coarse</title>
<style>.touch-only { display: none; } @media (pointer: coarse) { .touch-only { display: block; width: 1200px; } }</style>
</head><body><main><h1>Coarse</h1><p class="touch-only">Only a touch screen lays this out.</p></main></body></html>
"@
    'nometa.html' = @'
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><style>html { background: #ffffff; color: #111111; }</style><title>nometa</title></head>
<body><main><h1>No viewport</h1><p>A phone browser lays this page out 980px wide.</p></main></body></html>
'@
    'menu.html' = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">$viewport<style>html { background: #ffffff; color: #111111; }</style><title>menu</title></head><body>
<button type="button" id="menu-button" aria-controls="menu-panel" aria-expanded="false">Menu</button>
<nav id="menu-panel" hidden><a href="#x" style="color:#d0d0d0;background:#ffffff">Pale link</a></nav>
<main><h1>Menu</h1></main>
<script>
var b = document.getElementById('menu-button'), p = document.getElementById('menu-panel');
b.addEventListener('click', function () { p.hidden = !p.hidden; b.setAttribute('aria-expanded', p.hidden ? 'false' : 'true'); });
</script></body></html>
"@
    'brokenmenu.html' = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">$viewport<style>html { background: #ffffff; color: #111111; }</style><title>broken</title></head><body>
<button type="button" id="menu-button" aria-controls="menu-panel" aria-expanded="false">Menu</button>
<nav id="menu-panel" hidden><a href="#x">Home</a></nav><main><h1>No script wires this menu</h1></main></body></html>
"@
    'unlock.html' = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">$viewport<style>html { background: #ffffff; color: #111111; }</style><title>unlock</title></head><body><main><h1>Unlock</h1>
<section id="login" hidden><p style="color:#c8c8c8;background:#ffffff">Pale hint</p><span id="login-error" role="alert"></span></section>
</main></body></html>
"@
    'sdk.html' = @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">$viewport<style>html { background: #ffffff; color: #111111; }</style><title>sdk</title></head><body>
<header><div class="menu"><button type="button" class="menu-button" id="menu-button" aria-haspopup="true" aria-expanded="false" aria-controls="menu-panel">Menu</button>
<nav class="menu-panel" id="menu-panel" aria-label="Pages" hidden><a href="sdk.html">Home</a></nav></div></header>
<main><h1>SDK runtime</h1></main>
<script src="/assets/yuruna.core.js"></script></body></html>
"@
}
foreach ($name in $pagesByName.Keys) {
    [IO.File]::WriteAllText((Join-Path $script:Fixture $name), $pagesByName[$name], [Text.UTF8Encoding]::new($false))
}

function Invoke-GateRun {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Engine, [hashtable]$Environment = @{})
    # -Command turns any failing script into exit 1, so the gate's own code is
    # passed on: it tells a finding (1) from a missing browser (2).
    $command = "& '$($script:A11y.Replace("'", "''"))' -Serve '$($script:Fixture.Replace("'", "''"))' " +
        "-Width 1280 -Phone '360x780' -Scheme light -Browser $Engine; " + 'exit $LASTEXITCODE'
    $saved = Save-YurunaTestEnvironment -Name @($Environment.Keys)
    foreach ($key in $Environment.Keys) { [Environment]::SetEnvironmentVariable($key, $Environment[$key]) }
    try {
        $text = & (Get-Process -Id $PID).Path -NoProfile -Command $command 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Restore-YurunaTestEnvironment -Saved $saved
    }
    # Every view prints "ok   <tag>" or "FAIL <tag>" and then one indented
    # line per finding, so the output maps each view to what it found.
    $views = @{}
    $current = $null
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^(?:ok  |FAIL) (?<tag>.+)$') {
            $current = ($Matches['tag'].Trim() -split '[\\/]')[-1]
            $views[$current] = [Collections.Generic.List[string]]::new()
        } elseif ($current -and $line -match '^  (?<kind>\S+)\s+(?<detail>.*)$') {
            $views[$current].Add("$($Matches['kind']): $($Matches['detail'])")
        }
    }
    return @{ Code = $code; Output = $text; Views = $views }
}

function Get-ViewFinding {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][hashtable]$Run, [Parameter(Mandatory)][string]$Tag)
    if (-not $Run.Views.ContainsKey($Tag)) { throw "the gate measured no view '$Tag':`n$($Run.Output)" }
    return @($Run.Views[$Tag])
}

$script:Chrome = Invoke-GateRun -Engine 'chrome'
$script:Firefox = Invoke-GateRun -Engine 'firefox'
}

Describe 'the phone, state and shared-runtime views in Chrome' {
    BeforeEach {
        if ($script:Chrome.Code -eq 2) { Set-ItResult -Skipped -Because 'no Chrome or Chromium is available' }
    }

    It 'measures every page as it loads and each further state it offers' {
        # 6 pages x (one desktop width + one phone) as they load, the menu on
        # three pages and the unlock prompt on one, in both views.
        Assert-Match '20 page-view\(s\) measured across 6 page\(s\)' $script:Chrome.Output $script:Chrome.Output
        Assert-Equal -Expected 1 -Actual $script:Chrome.Code -Because 'the fixture pages carry findings'
        Assert-False $script:Chrome.Views.ContainsKey('coarse.html [1280px light, menu-open]') 'a page without a menu was measured with one open'
    }

    It 'evaluates the coarse-pointer rules only in the phone view' {
        Assert-Match 'reflow: document scrolls in two dimensions' ((Get-ViewFinding $script:Chrome 'coarse.html [phone 360x780 light]') -join "`n") `
            'a coarse-pointer rule that breaks reflow went unmeasured'
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Chrome 'coarse.html [1280px light]').Count -Because 'a fine pointer never applies that rule'
    }

    It 'reports a page that a phone would lay out 980px wide' {
        Assert-Match 'viewport: the layout viewport is 980px on a 360px-wide phone' ((Get-ViewFinding $script:Chrome 'nometa.html [phone 360x780 light]') -join "`n")
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Chrome 'nometa.html [1280px light]').Count
    }

    It 'opens the menu and measures what it shows, and reports a menu that does not open' {
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Chrome 'menu.html [1280px light]').Count -Because 'the closed menu shows nothing to measure'
        Assert-Match 'contrast: .*Pale link' ((Get-ViewFinding $script:Chrome 'menu.html [1280px light, menu-open]') -join "`n") 'the open menu was not measured'
        Assert-Match 'contrast: .*Pale link' ((Get-ViewFinding $script:Chrome 'menu.html [phone 360x780 light, menu-open]') -join "`n")
        Assert-Match 'state: the menu-open state did not open: the menu panel did not open' `
            ((Get-ViewFinding $script:Chrome 'brokenmenu.html [1280px light, menu-open]') -join "`n") 'a menu that never opens passed'
    }

    It 'shows the unlock prompt and measures it' {
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Chrome 'unlock.html [1280px light]').Count
        Assert-Match 'contrast: .*Pale hint' ((Get-ViewFinding $script:Chrome 'unlock.html [1280px light, unlock]') -join "`n") 'the unlock prompt was not measured'
    }

    It 'serves an extension page the SDK runtime it loads from /assets/' {
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Chrome 'sdk.html [1280px light, menu-open]').Count `
            -Because 'the SDK runtime wires the menu, so the menu opens only when the runtime was served'
    }
}

Describe 'the same probes in Firefox' {
    BeforeEach {
        if ($script:Firefox.Code -eq 2) { Set-ItResult -Skipped -Because 'Firefox is not installed' }
    }

    It 'measures a phone with a coarse pointer and opens the same states' {
        Assert-Match '20 page-view\(s\) measured across 6 page\(s\)' $script:Firefox.Output $script:Firefox.Output
        Assert-Match 'reflow: document scrolls in two dimensions' ((Get-ViewFinding $script:Firefox 'coarse.html [firefox phone 360x780 light]') -join "`n")
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Firefox 'coarse.html [firefox 1280px light]').Count
        Assert-Match 'contrast: .*Pale link' ((Get-ViewFinding $script:Firefox 'menu.html [firefox 1280px light, menu-open]') -join "`n")
        Assert-Match 'contrast: .*Pale hint' ((Get-ViewFinding $script:Firefox 'unlock.html [firefox phone 360x780 light, unlock]') -join "`n")
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Firefox 'sdk.html [firefox 1280px light, menu-open]').Count
    }

    It 'leaves the viewport-meta check to Chrome, because desktop Firefox ignores the meta' {
        Assert-Equal -Expected 0 -Actual (Get-ViewFinding $script:Firefox 'nometa.html [firefox phone 360x780 light]').Count
    }
}

Describe 'browser prerequisites' {
    It 'needs Firefox only when it is named alone' -Skip:(-not $IsLinux) {
        # Linux finds Firefox on PATH alone, so an empty PATH is a host without it.
        $empty = Join-Path $TestDrive 'empty-path'
        $null = New-Item -ItemType Directory -Path $empty -Force
        $run = Invoke-GateRun -Engine 'firefox' -Environment @{ PATH = $empty }
        Assert-Equal -Expected 2 -Actual $run.Code -Because 'a run that asked for Firefox alone cannot pass without it'
        Assert-Match '6 page\(s\), 0 measured -- SKIPPED: no Firefox on PATH' $run.Output
    }

    # Chrome carries its profile as one argument and Firefox as two. A process
    # still running on the profile once the tree kill is done is stopped by
    # its id, and only by that id: a lost id read as 0 would signal the gate's
    # own process group, and with it whatever runner started the gate.
    It 'stops a browser by the <Form> profile directory it runs on, not a neighbor or the gate' -Skip:$IsWindows -ForEach @(
        @{ Form = '--user-data-dir='; Arguments = { param($Directory) @("--user-data-dir=$Directory") } }
        @{ Form = '--profile'; Arguments = { param($Directory) @('--profile', $Directory) } }
    ) {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:A11y, [ref]$null, [ref]$null)
        foreach ($name in 'Start-A11yBrowserProcess', 'Stop-A11yBrowserProfile') {
            $definition = $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
                }.GetNewClosure(), $true) | Select-Object -First 1
            Assert-True ($null -ne $definition) "the browser helper $name is missing"
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        # Stand-ins for a browser: idle shells carrying a profile directory the
        # way the browser carries it.
        $holderScript = Join-Path $TestDrive 'profile-holder.ps1'
        [IO.File]::WriteAllText($holderScript, 'param([Parameter(ValueFromRemainingArguments)]$Rest) Start-Sleep -Seconds 120')
        $shell = (Get-Process -Id $PID).Path
        $owned = Join-Path $TestDrive 'yuruna-a11y-0123456789ab'
        $holders = foreach ($directory in $owned, "$owned-neighbor") {
            Start-A11yBrowserProcess -FilePath $shell -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $holderScript) + (& $Arguments $directory))
        }
        try {
            $stopped = Stop-A11yBrowserProfile -FilePath $shell -ProfileDirectory $owned
            Assert-Equal -Expected 1 -Actual $stopped -Because 'one process runs on the profile directory'
            Assert-True ($holders[0].Process.WaitForExit(5000)) 'the process on the profile directory kept running'
            Assert-False $holders[1].Process.HasExited 'a process on another profile directory was stopped'
        } finally {
            foreach ($holder in $holders) {
                if (-not $holder.Process.HasExited) { $holder.Process.Kill() }
                $holder.Process.Dispose()
            }
        }
    }
}
