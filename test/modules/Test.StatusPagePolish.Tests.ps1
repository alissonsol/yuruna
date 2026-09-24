<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42ada5a7-c360-4c5f-80be-7d4773345016
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status accessibility anchor pester
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
    Guards two status-page invariants: the faint foreground color meets WCAG AA
    contrast in both themes, and the yuruna.common.css REGION anchor matches the
    heading it points at in docs/definition.md.
.DESCRIPTION
    --fg-faint is used for muted/empty-state text; below 4.5:1 it is unreadable
    for low-vision users, and the default gray-400 (#9ca3af) failed even the 3:1
    large-text floor. These tests recompute the WCAG relative-luminance contrast of
    the light and dark --fg-faint against a representative background of each theme
    and require >= 4.5:1.

    Separately, the stylesheet points into definition.md, and that pointer used to
    carry the heading's own slug -- which a rename broke silently, and which a '+'
    in the heading broke ambiguously, because renderers disagree on whether it
    collapses to a hyphen. The pointer now carries an opaque id that does not
    change with the wording, so what is checked is that the id in the stylesheet
    is the one written above that heading, and that the heading is still there.
    A deleted heading or a pointer aimed elsewhere still fails.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$repo    = Split-Path -Parent (Split-Path -Parent $here)
$cssPath = Join-Path $repo 'test/status/yuruna.common.css'
$script:defPath = Join-Path $repo 'docs/definition.md'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-RelLuminance([string]$hex) {
    $hex = $hex.TrimStart('#')
    $chan = @(0,2,4) | ForEach-Object {
        $c = [Convert]::ToInt32($hex.Substring($_,2),16) / 255
        if ($c -le 0.03928) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $chan[0] + 0.7152 * $chan[1] + 0.0722 * $chan[2]
}
function Get-Contrast([string]$fg, [string]$bg) {
    $l1 = Get-RelLuminance $fg; $l2 = Get-RelLuminance $bg
    $hi = [Math]::Max($l1,$l2); $lo = [Math]::Min($l1,$l2)
    ($hi + 0.05) / ($lo + 0.05)
}
function ConvertTo-Slug([string]$heading) {
    # Approximate GitHub/static-site heading slugs: lowercase, drop punctuation
    # except spaces and hyphens, then spaces -> hyphens. (A '+' would leave a
    # double space here -> a double hyphen -- which is exactly the trap the
    # heading rename avoids.)
    $s = $heading.ToLowerInvariant() -replace '[^a-z0-9 \-]', ''
    ($s -replace '\s+', '-')
}

# Read at file scope, above the first Describe: a Describe body is evaluated
# during the discovery pass and its scope is discarded before any It runs, so a
# fixture declared inside one reaches the assertions as $null. Only file-level
# declarations preceding the first Describe survive into the run pass.
$css = Get-Content -Raw -LiteralPath $cssPath
$script:faint = [regex]::Matches($css, '--fg-faint:\s*(#[0-9a-fA-F]{6})') | ForEach-Object { $_.Groups[1].Value }

}

Describe 'status-page polish: WCAG contrast + REGION anchor integrity' {

    It 'exposes exactly two --fg-faint values (light + dark theme)' {
        Assert-Equal -Expected 2 -Actual $script:faint.Count -Because 'expected a light and a dark --fg-faint'
    }

    It 'light-theme --fg-faint meets WCAG AA (>= 4.5:1) on the near-white background' {
        # Worst-case light background the faint text sits on (--bg-primary #f9fafb).
        $c = Get-Contrast $script:faint[0] '#f9fafb'
        Assert-True ($c -ge 4.5) "light --fg-faint $($script:faint[0]) has $([Math]::Round($c,2)):1, needs >= 4.5:1"
    }

    It 'dark-theme --fg-faint meets WCAG AA (>= 4.5:1) on the elevated dark background' {
        # Worst-case (lightest) dark background the faint text sits on (--bg-elevated #111827).
        $c = Get-Contrast $script:faint[1] '#111827'
        Assert-True ($c -ge 4.5) "dark --fg-faint $($script:faint[1]) has $([Math]::Round($c,2)):1, needs >= 4.5:1"
    }

    It 'the mobile/dark-mode REGION pointer still names that heading' {
        # The pointer used to carry the heading's own slug, so a rename or a
        # '+' in the heading silently broke it and this test compared the two
        # spellings. Pointers now carry an opaque id instead, which cannot
        # drift with the wording -- so what has to be proved is that the id in
        # the stylesheet is the one sitting above that heading in
        # definition.md, and that the heading is still there to point at.
        $m = [regex]::Match($css, 'yuruna\.link/(42[0-9a-f]{6}-[0-9a-f]{4})')
        Assert-True $m.Success 'the css carries no REGION pointer in the id form'

        $def = Get-Content -Raw -LiteralPath $script:defPath
        $h = [regex]::Match($def,
            '(?m)^<a id="(42[0-9a-f]{6}-[0-9a-f]{4})"></a>\r?\n\r?\n###\s+Defining the status-page mobile[^\r\n]*hardening\s*$')
        Assert-True $h.Success 'the mobile/dark-mode heading, with its anchor id, is present in definition.md'

        $ids = @([regex]::Matches($css, 'yuruna\.link/(42[0-9a-f]{6}-[0-9a-f]{4})') |
            ForEach-Object { $_.Groups[1].Value })
        Assert-True ($ids -contains $h.Groups[1].Value) `
            "the stylesheet does not point at the mobile/dark-mode heading (its id is $($h.Groups[1].Value))"
    }
}
