<#PSScriptInfo
.VERSION 2026.10.26
.GUID 424025fc-72c7-4d6f-8266-32ee055a88e0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test mobile responsive rtl touch css html pester
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
    Source-level rules that keep the web UIs usable on a phone, checked without
    a browser.
.DESCRIPTION
    The paint-based gate measures a desktop window and never evaluates a rule
    under (pointer: coarse), so a regression on a phone passes every other
    check. These read the page sources the browsers read: the viewport meta on
    every page, a mirrored side for every one-sided panel anchor, the 16px text
    pin under a coarse pointer, a measured footer height, 100dvh beside every
    100vh, every service table inside a scroll region, an identifier input a
    phone keyboard cannot capitalize, state colors drawn from tokens, and a PDF
    preview embedded only where the browser has an inline viewer.
#>

BeforeDiscovery {
    $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $serviceWeb = @('pool-control-service', 'download-agent-service', 'stash-service') |
        ForEach-Object { Join-Path $root "test/extension/$_/server/internal/httpsrv/web" }
    $script:PageCases = @(@(Get-ChildItem -LiteralPath (Join-Path $root 'test/status') -Filter '*.html' -File) +
        @($serviceWeb | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.html' -File }) |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $script:SheetCases = @(@((Join-Path $root 'test/status/yuruna.common.css')) + @($serviceWeb | ForEach-Object { Join-Path $_ 'assets/style.css' }) |
        ForEach-Object { @{ Name = ($_ -replace '^.*/test/', 'test/'); Path = $_ } })
}

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ServiceWeb = @('pool-control-service', 'download-agent-service', 'stash-service') |
        ForEach-Object { Join-Path $script:Root "test/extension/$_/server/internal/httpsrv/web" }
    $script:Pages = @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'test/status') -Filter '*.html' -File) +
        @($script:ServiceWeb | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter '*.html' -File })
    $script:ChromeSheets = @((Join-Path $script:Root 'test/status/yuruna.common.css')) +
        @($script:ServiceWeb | ForEach-Object { Join-Path $_ 'assets/style.css' })
    function Get-CssRule {
        param([string]$Css)
        $text = [regex]::Replace($Css, '(?s)/\*.*?\*/', '')
        return @([regex]::Matches($text, '([^{}]+)\{([^{}]*)\}') | ForEach-Object {
            [pscustomobject]@{ Selector = $_.Groups[1].Value.Trim(); Body = $_.Groups[2].Value }
        })
    }
}

Describe 'Every page renders at the device width' {
    It 'declares the viewport on <Name>' -TestCases $script:PageCases {
        param($Name, $Path)
        $null = $Name
        [IO.File]::ReadAllText($Path) | Should -Match '<meta name="viewport" content="width=device-width'
    }
}

Describe 'Phone rules in the shared chrome' {
    It 'mirrors every one-sided panel anchor for right-to-left pages, pins text controls to 16px under a coarse pointer, and reserves the measured footer in <Name>' -TestCases $script:SheetCases {
        param($Name, $Path)
        $null = $Name
        $css = [IO.File]::ReadAllText($Path)
        foreach ($rule in (Get-CssRule -Css $css)) {
            if ($rule.Body -notmatch 'position:\s*absolute') { continue }
            $right = $rule.Body -match '(^|;|\s)right:\s*0'
            $left = $rule.Body -match '(^|;|\s)left:\s*0'
            if ($right -eq $left) { continue }
            $selector = ($rule.Selector -split '\n')[-1].Trim()
            $css.Contains('[dir="rtl"] ' + $selector + ' {') | Should -BeTrue -Because "$selector is anchored to one side only, which is off-screen in a right-to-left page"
        }
        $css | Should -Match '(?s)@media \(pointer: coarse\) \{[^@]*select, textarea[^{]*\{ font-size: 16px; \}' -Because 'iOS zooms into a smaller control on focus, at any width'
        $css | Should -Match 'var\(--footer-h,' -Because 'the fixed footer reserves its measured height'
    }
    It 'measures the footer in every page script' {
        foreach ($file in @('test/status/yuruna.common.js', 'test/extension/extension-sdk/webui/assets/yuruna.core.js')) {
            $src = [IO.File]::ReadAllText((Join-Path $script:Root $file))
            $src | Should -Match "setProperty\('--footer-h'" -Because "$file keeps the stylesheet's reserve equal to the footer"
            $src | Should -Match 'ResizeObserver'
        }
    }
}

Describe 'Viewport heights and scroll regions' {
    It 'pairs every 100vh with 100dvh' {
        foreach ($file in @($script:Pages.FullName) + @($script:ChromeSheets)) {
            $text = [IO.File]::ReadAllText($file)
            foreach ($rule in (Get-CssRule -Css $text)) {
                if ($rule.Body -match '\b100vh\b') {
                    $rule.Body | Should -Match '\b100dvh\b' -Because "$(Split-Path -Leaf $file) sizes $($rule.Selector) by the large viewport, which hides the bottom of the page under the iOS toolbar"
                }
            }
        }
    }
    It 'puts every service table inside a scroll region' {
        foreach ($dir in $script:ServiceWeb) {
            foreach ($page in (Get-ChildItem -LiteralPath $dir -Filter '*.html' -File)) {
                $lines = [IO.File]::ReadAllLines($page.FullName)
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -notmatch '<table[\s>]') { continue }
                    $here = $lines[$i].Contains('class="table-wrap"')
                    $before = ($i -gt 0) -and $lines[$i - 1].Contains('class="table-wrap"')
                    ($here -or $before) | Should -BeTrue -Because "$($page.Name):$($i + 1) would scroll the whole page on a phone"
                }
            }
        }
    }
    It 'keeps the config action bar on screen by pinning the body to the viewport' {
        [IO.File]::ReadAllText((Join-Path $script:Root 'test/status/config.html')) | Should -Match 'body \{ height: 100vh; height: 100dvh;'
    }
}

Describe 'Inputs and state colors' {
    It 'keeps a phone keyboard from capitalizing the pool id' {
        $page = [IO.File]::ReadAllText((Join-Path $script:Root 'test/extension/pool-control-service/server/internal/httpsrv/web/pools.html'))
        $field = [regex]::Match($page, '<input id="new-poolid"[^>]*>').Value
        $field | Should -Match 'autocapitalize="none"'
        $field | Should -Match 'pattern="\[a-z0-9\]\[a-z0-9-\]\{0,62\}"'
        [IO.File]::ReadAllText((Join-Path $script:Root 'test/extension/pool-control-service/server/internal/httpsrv/web/assets/pools.js')) |
            Should -Match "getElementById\('new-poolid'\)\.value\.trim\(\)\.toLowerCase\(\)"
        [IO.File]::ReadAllText((Join-Path $script:Root 'test/pool/New-Pool.ps1')) | Should -Match '\$PoolId -cnotmatch'
    }
    It 'draws status markup colors from tokens, not fixed values' {
        $src = [IO.File]::ReadAllText((Join-Path $script:Root 'test/status/yuruna.common.js'))
        $src | Should -Not -Match 'style="[^"]*(color|background):\s*#[0-9a-fA-F]{3,6}'
        $css = [IO.File]::ReadAllText((Join-Path $script:Root 'test/status/yuruna.common.css'))
        $css | Should -Match '\.badge\.quarantined \{ background: var\(--warn-bg\); color: var\(--warn-fg\); \}'
    }
    It 'embeds a PDF preview only where the browser has an inline viewer' {
        $stash = Get-Content -LiteralPath (Join-Path $script:Root 'test/extension/stash-service/server/internal/httpsrv/web/assets/stash.js') -Raw
        $case = [regex]::Match($stash, "(?s)case 'pdf':(.*?)(?=case ')").Groups[1].Value
        $case | Should -Match "(?s)navigator\.pdfViewerEnabled !== false\)\s*\{\s*Y\.append\(wrap, Y\.el\('embed'" -Because 'an empty embed pushes the open link below the fold on a phone'
        $case | Should -Match "Y\.el\('a', \{ href: raw" -Because 'the open link is always offered'
    }

    It 'outlines the unlock field with the control edge, not the divider' {
        $css = [IO.File]::ReadAllText((Join-Path $script:Root 'test/extension/pool-control-service/server/internal/httpsrv/web/assets/style.css'))
        $css | Should -Match '(?s)\.unlock-overlay \.login input \{[^}]*border: 1px solid var\(--control-edge\)'
    }
}
