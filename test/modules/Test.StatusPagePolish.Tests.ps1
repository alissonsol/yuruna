<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42c3f5a8-0e61-4d92-b7a4-3f8c1d6e9b57
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
    Guards two status-page invariants: the faint foreground colour meets WCAG AA
    contrast in both themes, and the yuruna.common.css REGION anchor matches the
    heading it points at in docs/definition.md.
.DESCRIPTION
    --fg-faint is used for muted/empty-state text; below 4.5:1 it is unreadable
    for low-vision users, and the default gray-400 (#9ca3af) failed even the 3:1
    large-text floor. These tests recompute the WCAG relative-luminance contrast of
    the light and dark --fg-faint against a representative background of each theme
    and require >= 4.5:1. Separately, a heading containing a '+' slugs ambiguously
    (the '+' collapses to a hyphen inconsistently across renderers), silently
    breaking the REGION deep-link; the anchor test slugifies the target heading and
    requires it to equal the css anchor, so a reintroduced '+' or a drifted rename
    is caught.

    The throw-based Assert-* helpers are defined at script scope and referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here    = Split-Path -Parent $PSCommandPath
$repo    = Split-Path -Parent (Split-Path -Parent $here)
$cssPath = Join-Path $repo 'test/status/yuruna.common.css'
$defPath = Join-Path $repo 'docs/definition.md'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

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
$faint = [regex]::Matches($css, '--fg-faint:\s*(#[0-9a-fA-F]{6})') | ForEach-Object { $_.Groups[1].Value }

Describe 'status-page polish: WCAG contrast + REGION anchor integrity' {

    It 'exposes exactly two --fg-faint values (light + dark theme)' {
        Assert-Equal -Expected 2 -Actual $faint.Count -Because 'expected a light and a dark --fg-faint'
    }

    It 'light-theme --fg-faint meets WCAG AA (>= 4.5:1) on the near-white background' {
        # Worst-case light background the faint text sits on (--bg-primary #f9fafb).
        $c = Get-Contrast $faint[0] '#f9fafb'
        Assert-True ($c -ge 4.5) "light --fg-faint $($faint[0]) has $([Math]::Round($c,2)):1, needs >= 4.5:1"
    }

    It 'dark-theme --fg-faint meets WCAG AA (>= 4.5:1) on the elevated dark background' {
        # Worst-case (lightest) dark background the faint text sits on (--bg-elevated #111827).
        $c = Get-Contrast $faint[1] '#111827'
        Assert-True ($c -ge 4.5) "dark --fg-faint $($faint[1]) has $([Math]::Round($c,2)):1, needs >= 4.5:1"
    }

    It 'the mobile/dark-mode REGION anchor matches its definition.md heading slug' {
        $m = [regex]::Match($css, 'definition#(defining-the-status-page-mobile[^\s]*hardening)')
        Assert-True $m.Success 'the mobile/dark-mode REGION pointer is present in the css'
        $anchor = $m.Groups[1].Value
        $def = Get-Content -Raw -LiteralPath $defPath
        $h = [regex]::Match($def, '(?m)^###\s+(Defining the status-page mobile[^\r\n]*hardening)\s*$')
        Assert-True $h.Success 'the mobile/dark-mode heading is present in definition.md'
        $slug = ConvertTo-Slug $h.Groups[1].Value
        Assert-Equal -Expected $slug -Actual $anchor -Because 'a "+" in the heading (or a drifted rename) breaks the REGION deep-link'
    }
}
