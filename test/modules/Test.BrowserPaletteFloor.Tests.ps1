<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42e575be-d2eb-4fca-aff0-b96b48ea124c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test browser baseline css custom-properties pester
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
    Hold every shipped browser stylesheet to rendering without CSS custom
    properties, and hold the generator that guarantees it to being able to fail.
.DESCRIPTION
    The documented floor has no custom properties. An engine there treats a
    declaration whose value contains var() as invalid and DROPS it, so a rule
    that states its color only through var() paints nothing: the page renders
    in user-agent defaults -- black on white, or worse, invisible text on a
    surface that was supposed to be dark. Like the ES5 floor, it fails only on
    the engine nobody here runs, and it looks fine everywhere else.

    tools/Invoke-CssVarFallback.ps1 generates the literal declaration that sits
    immediately before each var() one, so the old engine keeps the literal and
    a current engine takes the var(). This suite checks the result two ways.

    The first is independent of that script. It re-derives the declaration
    sequence with its own parser and asserts the pairing directly, so a
    generator that stopped emitting -- or stopped being run -- cannot report a
    floor that no longer holds.

    The second is aimed at the generator itself. A checker that silently stops
    matching turns an unchecked tree into one that merely looks checked, so it
    is handed a missing fallback and a stale one and has to fail on both, and
    handed a correct pair and has to stay quiet.

    Run: Invoke-Pester -Path test/modules/Test.BrowserPaletteFloor.Tests.ps1
#>

BeforeAll {
Import-Module (Join-Path $PSScriptRoot 'Test.ProductGlobalization.psm1') -Force -Global -DisableNameChecking
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Generator = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Invoke-CssVarFallback.ps1'

# A child pwsh, because the exit code is half of what is under test and only
# survives a process boundary.
function Invoke-Generator {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string[]]$Argument)
    $argv = @('-NoProfile', '-File', $script:Generator) + $Argument
    $out = (& pwsh @argv 2>&1 | Out-String)
    return @{ Output = $out; ExitCode = $LASTEXITCODE }
}

$script:Sandbox = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-palette-' + [Guid]::NewGuid().ToString('n'))
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

# Every browser CSS source that ships, whatever file carries it. The .css
# files are only part of it: the status pages style themselves inline, two Go
# services build their page as a string constant, and the generated directory
# listing lives in a PowerShell here-string. A discovery that globbed *.css
# would report a clean floor over a third of the real surface.
# The producer list comes from the shared registry. Kept here as a second copy
# it was a contract with two owners: a producer added to the tool's list and
# not to this one would be generated correctly and never verified, and the
# suite would stay green over the gap.
$script:SourceFile = @(
    (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText(
        (Join-Path $script:RepoRoot 'globalization/manifests/browser-sources.json')))
    ).cssProducers | ForEach-Object { [string]$_.path }
)

# The CSS carried by a file, whether the file is a stylesheet or embeds one.
function Get-EmbeddedCss {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$FullPath)

    $text = Get-Content -Raw -LiteralPath $FullPath
    if ($FullPath -like '*.css') { return $text }
    $opts = [Text.RegularExpressions.RegexOptions]::Singleline -bor
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
    $parts = foreach ($m in [regex]::Matches($text, '<style[^>]*>(.*?)</style>', $opts)) { $m.Groups[1].Value }
    return ($parts -join "`n")
}

# Declarations in source order, with the at-rule context each sits under. This
# is a second implementation on purpose: it reads the sequence with a regex
# rather than the generator's character scanner, so both would have to break
# the same way to agree wrongly.
function Get-CssDeclaration {
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$Text)

    $stripped = [regex]::Replace($Text, '(?s)/\*.*?\*/', '')
    $found = [System.Collections.Generic.List[pscustomobject]]::new()
    $darkDepth = -1
    $depth = 0
    $buffer = ''
    for ($i = 0; $i -lt $stripped.Length; $i++) {
        $c = $stripped[$i]
        if ($c -eq '{') {
            if ($buffer -match '@media[^{}]*prefers-color-scheme' -and $darkDepth -lt 0) { $darkDepth = $depth }
            $depth++
            $buffer = ''
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($darkDepth -ge 0 -and $depth -le $darkDepth) { $darkDepth = -1 }
            $buffer = ''
            continue
        }
        if ($c -eq ';') {
            if ($buffer -match '^\s*([-A-Za-z][-A-Za-z0-9]*)\s*:\s*(\S.*)$') {
                $found.Add([pscustomobject]@{
                    Property = $Matches[1]
                    Value    = $Matches[2].Trim()
                    Depth    = $depth
                    InDark   = ($darkDepth -ge 0)
                })
            } else {
                # A run that is not a declaration still breaks adjacency.
                $found.Add([pscustomobject]@{ Property = ''; Value = ''; Depth = $depth; InDark = ($darkDepth -ge 0) })
            }
            $buffer = ''
            continue
        }
        $buffer += $c
    }
    return $found.ToArray()
}

$script:Source = @(
    foreach ($rel in $script:SourceFile) {
        $full = [IO.Path]::Combine($script:RepoRoot, ($rel -replace '/', [IO.Path]::DirectorySeparatorChar))
        $css = Get-EmbeddedCss -FullPath $full
        [pscustomobject]@{
            Name         = $rel
            Css          = $css
            Declarations = @(Get-CssDeclaration -Text $css)
        }
    })
}

AfterAll {
    if ($script:Sandbox -and (Test-Path -LiteralPath $script:Sandbox)) {
        Remove-Item -LiteralPath $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'every shipped stylesheet renders without custom properties' {

    It 'reads the sources it checks' {
        Assert-Equal -Expected 16 -Actual $script:Source.Count `
            'the registered browser CSS sources are not all being read'
        $withVar = @($script:Source | Where-Object { $_.Css -match 'var\(--' })
        Assert-True ($withVar.Count -ge 12) `
            "only $($withVar.Count) sources carry var(), so this suite is reading the wrong text"
        $total = ($script:Source | ForEach-Object { $_.Declarations.Count } | Measure-Object -Sum).Sum
        Assert-True ($total -gt 1500) "the parser found only $total declarations across the sources"
    }

    It 'precedes every var() declaration with a literal of the same property' {
        # This is the floor itself. Without the literal in front, the old
        # engine drops the declaration and paints a user-agent default.
        $findings = @()
        foreach ($src in $script:Source) {
            $decls = $src.Declarations
            for ($i = 0; $i -lt $decls.Count; $i++) {
                $d = $decls[$i]
                if ($d.Value -notmatch 'var\(') { continue }
                if ($d.Property -like '--*') { continue }
                if ($d.InDark) { continue }
                $ok = $false
                if ($i -gt 0) {
                    $prev = $decls[$i - 1]
                    $ok = ($prev.Property -eq $d.Property) -and
                          ($prev.Depth -eq $d.Depth) -and
                          ($prev.Value -notmatch 'var\(')
                }
                if (-not $ok) {
                    $findings += "$($src.Name): '$($d.Property): $($d.Value)' has no literal fallback before it"
                }
            }
        }
        Assert-NoFinding $findings 'that declaration is dropped whole on the floor, so the rule paints nothing'
    }

    It 'defines every custom property inside :root' {
        # Resolution is single-valued only while this holds. A definition
        # scoped to a class or an attribute would give one name two live
        # values, and no single literal could stand in for both.
        $findings = @()
        foreach ($src in $script:Source) {
            $stripped = [regex]::Replace($src.Css, '(?s)/\*.*?\*/', '')
            $selector = ''
            foreach ($line in ($stripped -split "`n")) {
                if ($line -match '^([^{}]*)\{') { $selector = $Matches[1].Trim() }
                if ($line -match '^\s*(--[A-Za-z0-9_-]+)\s*:' -and $selector -ne ':root') {
                    $findings += "$($src.Name): $($Matches[1]) is defined under '$selector', not :root"
                }
            }
        }
        Assert-NoFinding $findings 'a name with more than one live value cannot be resolved to one literal'
    }

    It 'keeps the generated fallbacks current with the palette' {
        $run = Invoke-Generator -Argument @('-Quiet')
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a stale literal renders the wrong color on the floor and nowhere else:`n$($run.Output)"
    }
}

Describe 'the fallback generator can still fail' {

    It 'reports a var() declaration with no literal in front of it' {
        $sample = New-Sample -Name 'missing.css' -Body @'
:root { --sample-line: #abcdef; }
.card { border: 1px solid var(--sample-line); }
'@
        $run = Invoke-Generator -Argument @('-Source', $sample)
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a missing fallback has to fail the run'
        Assert-Match -Pattern 'missing fallback' -Actual $run.Output `
            'the report has to name what is missing'
    }

    It 'reports a literal that no longer matches the palette' {
        $sample = New-Sample -Name 'stale.css' -Body @'
:root { --sample-bg: #123456; }
.card { background: #ffffff; background: var(--sample-bg); }
'@
        $run = Invoke-Generator -Argument @('-Source', $sample)
        Assert-Equal -Expected 1 -Actual $run.ExitCode 'a stale fallback has to fail the run'
        Assert-Match -Pattern 'stale fallback' -Actual $run.Output `
            'the report has to say the literal drifted from the palette'
    }

    It 'stays quiet when the literal is present and current' {
        $sample = New-Sample -Name 'good.css' -Body @'
:root { --sample-bg: #123456; }
.card { background: #123456; background: var(--sample-bg); }
'@
        $run = Invoke-Generator -Argument @('-Source', $sample)
        Assert-Equal -Expected 0 -Actual $run.ExitCode `
            -Because "a correct pair must not be reported:`n$($run.Output)"
    }

    It 'refuses a custom property defined outside :root' {
        $sample = New-Sample -Name 'scoped.css' -Body @'
:root { --sample-bg: #123456; }
.theme-dark { --sample-bg: #000000; }
.card { background: #123456; background: var(--sample-bg); }
'@
        $run = Invoke-Generator -Argument @('-Source', $sample)
        Assert-Equal -Expected 2 -Actual $run.ExitCode `
            -Because "a scoped redefinition breaks single-valued resolution:`n$($run.Output)"
    }

    It 'writes the same bytes on a second pass' {
        $body = @'
:root { --sample-bg: #123456; --sample-line: #abcdef; }
.card { background: var(--sample-bg); border: 1px solid var(--sample-line); }
'@
        $sample = New-Sample -Name 'idempotent.css' -Body $body
        $first = Invoke-Generator -Argument @('-Update', '-Source', $sample)
        Assert-Equal -Expected 1 -Actual $first.ExitCode 'the first pass has fallbacks to add'
        $afterFirst = Get-Content -Raw -LiteralPath $sample
        $second = Invoke-Generator -Argument @('-Update', '-Source', $sample)
        Assert-Equal -Expected 0 -Actual $second.ExitCode 'the second pass has nothing left to do'
        Assert-StringEqual -Expected $afterFirst -Actual (Get-Content -Raw -LiteralPath $sample) `
            'generated output has to be stable, or every run shows a diff'
    }
}

Describe 'the pages render the same without custom properties' {

    # The static rules above prove the literal is THERE. Only a browser proves
    # it is RIGHT: that the value in front of each var() is the one the
    # cascade would have resolved to. The gate serves every page twice at the
    # same width and scheme -- once as authored, once with every custom
    # property and every var() declaration deleted, which is what an engine
    # without them is left with -- and records the computed colors both
    # times. Identical snapshots mean the floor renders what a current
    # browser renders. A difference names the element whose fallback is
    # missing or wrong.

    BeforeAll {
        $script:A11y = Join-Path $script:RepoRoot 'tools' | Join-Path -ChildPath 'Invoke-A11yCheck.ps1'
        $script:Chrome = $null
        foreach ($n in @('google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser')) {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c) { $script:Chrome = $c.Source; break }
        }
        function Get-PaletteSnapshot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes only into the temp sandbox removed in AfterAll.')]
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Name, [switch]$Strip)
            $out = Join-Path $script:Sandbox $Name
            $argv = @('-NoProfile', '-File', $script:A11y, '-Quiet',
                      '-Scheme', 'light', '-Width', '1280', '-PaletteSnapshot', $out)
            if ($Strip) { $argv += '-StripCustomProperties' }
            & pwsh @argv 2>&1 | Out-Null
            return $out
        }
    }

    It 'computes the same palette with custom properties removed' {
        if (-not $script:Chrome) {
            Set-ItResult -Skipped -Because 'no Chrome or Chromium on this host to render with'
            return
        }
        $plain = Get-PaletteSnapshot -Name 'palette-plain.json'
        $floor = Get-PaletteSnapshot -Name 'palette-floor.json' -Strip

        Assert-True (Test-Path -LiteralPath $plain) 'the plain render wrote no snapshot'
        Assert-True (Test-Path -LiteralPath $floor) 'the floor render wrote no snapshot'

        $plainText = Get-Content -Raw -LiteralPath $plain
        $floorText = Get-Content -Raw -LiteralPath $floor
        Assert-True ($plainText.Length -gt 200) 'the snapshot is empty, so nothing was measured'

        if ($plainText -cne $floorText) {
            # Name the first few differing rows rather than dumping both files.
            $a = @($plainText -split "`n")
            $b = @($floorText -split "`n")
            $diff = @()
            for ($i = 0; $i -lt [Math]::Min($a.Count, $b.Count) -and $diff.Count -lt 6; $i++) {
                if ($a[$i] -cne $b[$i]) { $diff += "line $($i + 1): authored '$($a[$i].Trim())' vs floor '$($b[$i].Trim())'" }
            }
            Assert-NoFinding $diff 'an element renders differently without custom properties, so its literal fallback is missing or wrong'
        }
        Assert-StringEqual -Expected $plainText -Actual $floorText `
            'the floor render has to match the authored render'
    }
}

Describe 'the shared chrome palette resolves to one set of literals' {

    It 'gives every chrome token the same value in every UI that carries it' {
        # The page-chrome block is copied per UI because go:embed cannot cross
        # a module boundary, and a byte-identity test holds the copies
        # together. The generated literals are part of those bytes now, so the
        # tokens they come from have to agree before the copies can.
        $sheets = @{
            'status'       = 'test/status/yuruna.common.css'
            'pool-control' = 'test/extension/pool-control-service/server/internal/httpsrv/web/assets/style.css'
            'stash'        = 'test/extension/stash-service/server/internal/httpsrv/web/assets/style.css'
            'download'     = 'test/extension/download-agent-service/server/internal/httpsrv/web/assets/style.css'
        }
        $seen = @{}
        foreach ($name in $sheets.Keys) {
            $full = [IO.Path]::Combine($script:RepoRoot, ($sheets[$name] -replace '/', [IO.Path]::DirectorySeparatorChar))
            $text = Get-Content -Raw -LiteralPath $full
            # Bare :root only: the dark block never applies on the floor.
            $cut = $text.IndexOf('prefers-color-scheme')
            if ($cut -gt 0) { $text = $text.Substring(0, $cut) }
            foreach ($m in [regex]::Matches($text, '(--chrome-[a-z-]+|--touch-min)\s*:\s*([^;}]+)')) {
                $token = $m.Groups[1].Value
                $value = $m.Groups[2].Value.Trim()
                if (-not $seen.ContainsKey($token)) { $seen[$token] = @{} }
                $seen[$token][$name] = $value
            }
        }
        Assert-True ($seen.Count -ge 9) "expected the shared chrome tokens, found $($seen.Count)"
        $findings = @()
        foreach ($token in $seen.Keys) {
            $values = @($seen[$token].Values | Sort-Object -Unique)
            if ($values.Count -gt 1) {
                $detail = ($seen[$token].GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
                $findings += "$token differs between UIs: $detail"
            }
        }
        Assert-NoFinding $findings 'a chrome token that differs makes the copied block impossible to keep identical'
    }
}

Describe 'product globalization acceptance' {
    It 'globalization acceptance: all surfaces expanded and mirrored locales' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/status/globalization-pages.test.js'
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/extension/ui-pages.test.js'
    }
    It 'globalization acceptance: capability off keyboard IME and hostile bidi' {
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/status/yuruna.common.test.js'
        Invoke-ProductGlobalizationCheck -Kind Node -Path 'test/extension/ui-pages.test.js'
    }
}
