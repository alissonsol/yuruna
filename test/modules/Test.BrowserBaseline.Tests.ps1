<#PSScriptInfo
.VERSION 2026.09.13
.GUID 427765c1-3491-491c-8ca6-00baf0708bec
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser baseline es5 javascript pester
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
    Holds every shipped browser asset to the Safari iOS 9.0 baseline the UI
    documents, and holds the checker that enforces it to being able to fail.
.DESCRIPTION
    The baseline in docs/definition.md is a hard floor, and it is broken
    silently: an iOS 9 parser rejects a file carrying one arrow function
    outright, so nothing in it runs. The page then serves its static shell --
    a header bar, an empty tbody -- and reads as merely empty rather than
    broken. Three service UIs drifted a full major version past the floor
    without anyone noticing, because every browser anyone tested on ran them.

    So the check cannot be "does it work here". tools/Invoke-Es5Check.ps1 is a
    lexer that reports ES2015+ syntax and APIs found in CODE (not in comments,
    strings or regex literals), and this suite runs it over everything the
    services and the status pages ship.

    The second half of the suite is aimed at the checker rather than the assets.
    A lint that silently stops matching reports a clean run over files it never
    understood, which is worse than no lint: it converts an unchecked codebase
    into one that looks checked. So the checker is handed known-bad input and
    has to fail on it, and handed a comment that merely looks bad and has to
    stay quiet.

    Run: Invoke-Pester -Path test/modules/Test.BrowserBaseline.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Checker = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Invoke-Es5Check.ps1'

# A child pwsh, because the exit code is half of what is under test and only
# survives a process boundary.
function Invoke-Checker {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Target)
    $argv = @('-NoProfile', '-File', $script:Checker)
    if ($Target) { $argv += @('-Path') + $Target }
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-es5-' + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null

function New-Sample {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Body)
    $path = Join-Path $script:Sandbox $Name
    Set-Content -LiteralPath $path -Value $Body -Encoding utf8
    return $path
}

$script:Runtime = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk',
    'webui', 'assets', 'yuruna.core.js')
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'every shipped browser asset stays on the documented baseline' {

    It 'reports no baseline break anywhere the services and status pages ship' {
        $run = Invoke-Checker
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a file past the floor does not degrade, it stops running entirely:`n$($run.Output)"
    }

    It 'ships the shared runtime the services load before their own scripts' {
        Assert-True (Test-Path -LiteralPath $script:Runtime) `
            'extension-sdk/webui/assets/yuruna.core.js is what installs the baseline shims'
        $text = Get-Content -Raw -LiteralPath $script:Runtime
        foreach ($shim in @('window.fetch', 'Y.key', 'Element.prototype.closest')) {
            Assert-True ($text -match [regex]::Escape($shim)) "the runtime no longer installs $shim"
        }
    }
}

Describe 'the static palette cannot acquire a JavaScript-only value' {

    It 'rejects a custom-property write' {
        $sample = New-Sample -Name 'set-property.js' -Body `
            "document.documentElement.style.setProperty('--surface', '#fff');"
        $run = Invoke-Checker -Target $sample
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "a runtime palette write has no generated Safari 9 literal:`n$($run.Output)"
        Assert-Match -Pattern 'CSSStyleDeclaration.setProperty' -Actual $run.Output `
            'the finding does not identify the forbidden write'
    }

    It 'rejects a custom-property read' {
        $sample = New-Sample -Name 'get-property.js' -Body `
            "var surface = window.getComputedStyle(document.body).getPropertyValue('--surface');"
        $run = Invoke-Checker -Target $sample
        Assert-Equal -Expected 1 -Actual $run.ExitCode `
            -Because "a runtime palette read makes the compiled fallback incomplete:`n$($run.Output)"
        Assert-Match -Pattern 'CSSStyleDeclaration.getPropertyValue' -Actual $run.Output `
            'the finding does not identify the forbidden read'
    }
}

Describe 'the stylesheets degrade instead of breaking on the baseline' {

    BeforeAll {
        # Split-CssRule walks a stylesheet brace by brace and returns one entry
        # per STYLE rule, with the at-rules it sits inside. A regex cannot do
        # this: `\{[^}]*\}` starting at an @media or @supports brace swallows
        # the opener and the first rule together, which reads the guard's answer
        # off a block that does not exist.
        function Split-CssRule {
            [CmdletBinding()]
            [OutputType([pscustomobject[]])]
            param([Parameter(Mandatory)][string]$Text)

            $rules = [Collections.Generic.List[object]]::new()
            $context = [Collections.Generic.List[string]]::new()
            $preludeStart = 0
            $i = 0
            while ($i -lt $Text.Length) {
                $c = $Text[$i]
                if ($c -eq '{') {
                    $prelude = $Text.Substring($preludeStart, $i - $preludeStart).Trim()
                    if ($prelude.StartsWith('@')) {
                        $context.Add($prelude)
                        $i++; $preludeStart = $i
                        continue
                    }
                    # A style rule: everything to its own closing brace.
                    $close = $Text.IndexOf('}', $i)
                    if ($close -lt 0) { break }
                    $rules.Add([pscustomobject]@{
                            Selector = $prelude
                            Body     = $Text.Substring($i + 1, $close - $i - 1)
                            Context  = $context.ToArray() -join ' '
                        })
                    $i = $close + 1; $preludeStart = $i
                    continue
                }
                if ($c -eq '}') {
                    if ($context.Count -gt 0) { $context.RemoveAt($context.Count - 1) }
                    $i++; $preludeStart = $i
                    continue
                }
                $i++
            }
            return $rules.ToArray()
        }

        # Comments are stripped before parsing: these stylesheets explain their
        # own gap and grid policy in prose, and a rule that flagged the
        # explanation would be a rule nobody keeps.
        # The registry, not a path glob. Globbing httpsrv found four service
        # stylesheets and missed every other producer this repository ships --
        # the status pages, the shared chrome sheet, the pages built inside Go
        # and PowerShell, and the seed a guest serves. Those are exactly the
        # surfaces the floor rules below exist for, and a rule that never opens
        # a file reports it clean.
        $registryPath = Join-Path $script:RepoRoot 'globalization/manifests/browser-sources.json'
        $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))
        $script:Sheets = @(
            foreach ($producer in @($registry.cssProducers)) {
                $full = Join-Path $script:RepoRoot ([string]$producer.path)
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                $text = [IO.File]::ReadAllText($full)
                # A producer that is not itself a stylesheet carries its CSS in
                # <style> blocks; take those and nothing around them, the same
                # extraction the palette-fallback tool performs.
                if ([string]$producer.kind -cne 'Css') {
                    $blocks = @([regex]::Matches($text, '<style[^>]*>(.*?)</style>', 'Singleline, IgnoreCase') |
                        ForEach-Object { $_.Groups[1].Value })
                    if ($blocks.Count -eq 0) { continue }
                    $text = $blocks -join "`n"
                }
                # Comments are stripped before parsing: these stylesheets explain
                # their own gap and grid policy in prose, and a rule that flagged
                # the explanation would be a rule nobody keeps.
                $stripped = [regex]::Replace($text, '(?s)/\*.*?\*/', '')
                [pscustomobject]@{
                    Name  = ([string]$producer.path)
                    Rules = @(Split-CssRule -Text $stripped)
                }
            })
    }

    It 'reads the stylesheets it checks' {
        # Every registered producer, so a new one joins the floor rules by being
        # registered rather than by sitting under a particular directory.
        $registryPath = Join-Path $script:RepoRoot 'globalization/manifests/browser-sources.json'
        $declared = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath))).cssProducers).Count
        Assert-True ($script:Sheets.Count -ge ($declared - 1)) `
            "the registry declares $declared CSS producers but only $($script:Sheets.Count) were read"
        Assert-True ($script:Sheets.Count -ge 4) "expected the service stylesheets, found $($script:Sheets.Count)"
        $total = ($script:Sheets | ForEach-Object { $_.Rules.Count } | Measure-Object -Sum).Sum
        Assert-True ($total -gt 200) "the parser found only $total rules, so it is not reading these stylesheets"
        # A rule nested inside an at-rule has to come back as its own entry, or
        # every check below passes by not seeing anything.
        $nested = @($script:Sheets | ForEach-Object { $_.Rules } | Where-Object { $_.Context })
        Assert-True ($nested.Count -gt 0) 'the parser never descends into @media / @supports'
    }

    It 'still fails when a floor break is put in front of it' {
        # A lint that stops matching reports the same clean run as a codebase
        # with nothing wrong. Each rule is fed the break it exists to catch,
        # through the same parser the sheets go through, so a regex that
        # silently stopped working cannot pass as a green floor.
        $known = @(
            @{ Why = 'flex gap'
               Css = '.row { display: flex; gap: 1rem; }' }
            @{ Why = 'unguarded grid'
               Css = '.board { display: grid; grid-template-columns: 1fr 1fr; }' }
            @{ Why = 'logical property'
               Css = '.card { margin-inline: 1rem; }' }
        )
        foreach ($sample in $known) {
            $rules = @(Split-CssRule -Text $sample.Css)
            Assert-True ($rules.Count -ge 1) "the parser read no rule out of the $($sample.Why) sample"
            $hit = $false
            foreach ($rule in $rules) {
                if ($rule.Body -match '(?<!grid-)\bgap\s*:' -and $rule.Body -match 'display:\s*flex') { $hit = $true }
                if ($rule.Body -match 'display:\s*(inline-)?grid' -and -not $rule.Context) { $hit = $true }
                if ($rule.Body -match '\b(margin|padding|inset|border)-(inline|block)(-(start|end))?\s*:') { $hit = $true }
            }
            Assert-True $hit "the $($sample.Why) sample passed every floor rule, so the rules no longer match"
        }
    }

    It 'spaces flex children with margins, never with gap' {
        # flex `gap` is Safari 14.1 / iOS 14.5, and it fails SILENTLY below that
        # -- the items simply touch. A feature query cannot rescue it either,
        # because `@supports (gap: 1rem)` is true on Safari 12-14.0 for grid
        # while flex gap is still unimplemented, so the only safe answer is a
        # margin. A gap inside a grid rule is a grid gap and is not matched.
        $findings = @()
        foreach ($sheet in $script:Sheets) {
            foreach ($rule in $sheet.Rules) {
                if ($rule.Body -notmatch 'display:\s*(inline-)?flex') { continue }
                if ($rule.Body -match 'display:\s*(inline-)?grid') { continue }
                if ($rule.Body -match '(^|[;\s])gap\s*:') {
                    $findings += "$($sheet.Name): $($rule.Selector) spaces its flex children with gap"
                }
            }
        }
        Assert-NoFinding $findings 'below Safari 14.5 the children of that rule touch, with nothing to say why'
    }

    It 'keeps a layout under every CSS Grid rule' {
        # Grid is Safari 10.1. Below it a grid rule degrades to block flow, which
        # is right for a stacked list and wrong for a card board -- so each one
        # has to have decided: either the grid sits behind @supports with a
        # fallback outside it, or the same rule declares another display first.
        $findings = @()
        foreach ($sheet in $script:Sheets) {
            foreach ($rule in $sheet.Rules) {
                if ($rule.Body -notmatch 'display:\s*(inline-)?grid') { continue }
                $guarded = $rule.Context -match '@supports[^@]*display\s*:\s*grid'
                $fallbackFirst = $rule.Body -match '(?s)display:\s*(?!(inline-)?grid)[a-z-]+.*display:\s*(inline-)?grid'
                if (-not ($guarded -or $fallbackFirst)) {
                    $findings += "$($sheet.Name): $($rule.Selector) is a grid with no layout below Safari 10.1"
                }
            }
        }
        Assert-NoFinding $findings 'the floor build falls back to block flow, which is a decision to make rather than to inherit'
    }

    It 'mirrors every physical side it sets for right-to-left' {
        # The floor bans logical properties, so a page that offsets one side
        # has to say what the other direction does or the offset stays on the
        # same side when the text turns around. The mirrored pseudo-locale is a
        # required matrix row, and a stylesheet with no [dir="rtl"] rule at all
        # renders it identically to left-to-right -- which reads as a pass.
        # Scoped to the stylesheets the two reference pages load. The status
        # pages' own inline styles are deliberately out of scope here: they are
        # a separate surface, checked on their own rather than by this gate.
        $scoped = @(
            'test/status/yuruna.common.css'
            'test/extension/pool-control-service/server/internal/httpsrv/web/assets/style.css'
            'test/extension/pool-control-service/server/internal/httpsrv/web/assets/board.css'
        )
        $sideProperty = '(margin|padding|border)-(left|right)'
        $neutral = @('0', '0px', 'auto', 'inherit', 'initial', 'unset', 'revert', 'none')
        $findings = @()
        foreach ($sheet in @($script:Sheets | Where-Object { $_.Name -cin $scoped })) {
            $mirrored = @($sheet.Rules | Where-Object { $_.Selector -match '\[dir\s*=\s*.?rtl' })
            foreach ($rule in $sheet.Rules) {
                if ($rule.Selector -match '\[dir\s*=\s*.?rtl') { continue }
                $needs = $false
                foreach ($m in [regex]::Matches($rule.Body, "\b$sideProperty\s*:\s*([^;}]+)")) {
                    if ($m.Groups[3].Value.Trim() -notin $neutral) { $needs = $true }
                }
                # A left/right text-align turns around too; center does not.
                foreach ($m in [regex]::Matches($rule.Body, '\b(text-align|float)\s*:\s*([^;}]+)')) {
                    if ($m.Groups[2].Value.Trim() -in @('left', 'right')) { $needs = $true }
                }
                if (-not $needs) { continue }
                # The mirror is matched by the selector it restates, so a rule
                # can be mirrored by one that also covers other selectors.
                $target = ($rule.Selector -split ',' | ForEach-Object { $_.Trim() })[0]
                if (-not $target) { continue }
                $covered = @($mirrored | Where-Object { $_.Selector -match [regex]::Escape($target) })
                if ($covered.Count -eq 0) {
                    $findings += "$($sheet.Name): '$($rule.Selector)' sets a physical side with no [dir=rtl] mirror"
                }
            }
        }
        Assert-NoFinding $findings 'a page offsets one side and never says what the other direction does'
        # The scope list has to keep naming real producers, or this passes by
        # checking nothing.
        $checked = @($script:Sheets | Where-Object { $_.Name -cin $scoped })
        Assert-Equal -Expected $scoped.Count -Actual $checked.Count `
            'a scoped stylesheet is no longer a registered producer, so it went unchecked'
    }

    It 'uses physical margins and padding, not the logical properties' {
        # margin-inline / padding-inline and friends are Safari 14.1+. Below
        # that the declaration is dropped entirely, which silently un-does
        # whatever offset it was applying.
        $findings = @()
        foreach ($sheet in $script:Sheets) {
            foreach ($rule in $sheet.Rules) {
                foreach ($m in [regex]::Matches($rule.Body, '\b(margin|padding|inset|border)-(inline|block)(-(start|end))?\s*:')) {
                    $findings += "$($sheet.Name): $($rule.Selector) sets $($m.Value.TrimEnd(':'))"
                }
            }
        }
        Assert-NoFinding $findings 'the floor build drops the declaration and the offset it was making goes with it'
    }
}

Describe 'the checker can still fail' {

    It 'rejects an arrow function' {
        $sample = New-Sample -Name 'arrow.js' -Body 'var f = function () { return [1].map(function (x) { return x; }); };
var g = (x) => x + 1;'
        $run = Invoke-Checker -Target @($sample)
        Assert-NotEqual -Expected 0 -Actual $run.ExitCode 'an arrow function must fail the check'
        Assert-Match -Pattern 'arrow function' -Actual $run.Output -Because 'the finding names what it found'
    }

    It 'rejects async/await, which is what the service UIs had drifted onto' {
        $sample = New-Sample -Name 'async.js' -Body 'async function load() { var d = await fetch("/x"); return d; }'
        $run = Invoke-Checker -Target @($sample)
        Assert-NotEqual -Expected 0 -Actual $run.ExitCode 'async/await must fail the check'
        Assert-Match -Pattern 'async function' -Actual $run.Output -Because 'the finding names what it found'
    }

    It 'rejects let and const, which the floor build parses only in strict mode' {
        $sample = New-Sample -Name 'letconst.js' -Body 'const a = 1;
let b = 2;'
        $run = Invoke-Checker -Target @($sample)
        Assert-NotEqual -Expected 0 -Actual $run.ExitCode 'let/const must fail the check'
    }

    It 'rejects an API the floor build parses and then throws on' {
        $sample = New-Sample -Name 'api.js' -Body 'function f(o, el) { var k = Object.entries(o); el.append(k); return k; }'
        $run = Invoke-Checker -Target @($sample)
        Assert-NotEqual -Expected 0 -Actual $run.ExitCode 'a missing runtime API must fail the check'
        Assert-Match -Pattern 'Object\.entries' -Actual $run.Output -Because 'the finding names the call'
    }

    It 'stays quiet about a comment, a string and a regex that merely look modern' {
        # The distinction the whole checker rests on. A lint that flags `=>` in
        # prose is one that gets switched off, and a switched-off lint is how
        # the drift happened in the first place.
        $sample = New-Sample -Name 'lookalike.js' -Body @'
// An arrow => in a comment, and the word async, and await, and const.
/* let x = 1; and a spread ... too */
var msg = 'a => b';
var other = "async function ()";
var re = /=>|await|const/g;
var division = (10 / 2) / 5;
function ok(a) { return a / 2; }
'@
        $run = Invoke-Checker -Target @($sample)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "only CODE is a baseline break:`n$($run.Output)"
    }

    It 'reads the files it was pointed at, rather than reporting an empty run as clean' {
        $sample = New-Sample -Name 'plain.js' -Body 'var a = 1;'
        $run = Invoke-Checker -Target @($sample)
        Assert-Equal -Expected 0 -Actual $run.ExitCode 'an ES5 file passes'
        Assert-Match -Pattern '1 file\(s\)' -Actual $run.Output -Because 'the summary says how much it actually read'

        $missing = Invoke-Checker -Target @((Join-Path $script:Sandbox 'no-such-directory'))
        Assert-NotEqual -Expected 0 -Actual $missing.ExitCode 'a path that matches nothing is an error, not a pass'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
