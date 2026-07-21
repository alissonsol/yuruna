<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e2f3a4-b5c6-4d78-9abc-de1f2a3b4c63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic console ocr pester
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
    Guards Test-ConsoleEchoIntact, the predicate that decides whether the
    console one-liner reached the guest tty intact before it is submitted.
.DESCRIPTION
    The predicate is pure, so these run with no host, no VM and no OCR
    engine: the samples are the OCR text itself, taken from real captures.

    The two anchors are the reason this file exists. A correctly typed line
    OCRs badly -- ';' as ':', 'H=' as 'HF', '//' as '/7', 'curl' as 'cur',
    'linux' as 'Tinux' -- and is cut off partway through. A keystroke-
    corrupted line looks the same up to the point where one key stuck in
    autorepeat and appended ~1400 copies of itself. A predicate that fails
    the first sample is worse than no predicate at all, because it would
    reject every healthy capture on the last-resort diagnostics path; a
    predicate that passes the second one does nothing.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.DiagnosticEchoVerify.Tests.ps1
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.Diagnostic.psm1'
Import-Module $modPath -Force

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures live at FILE scope, above the first Describe: a Describe body runs
# during discovery and its variables are gone before any It executes.

# The command as the rung builds it, from the same constructor the rung
# calls, so the expected text and the typed text can never drift apart.
$EchoExpected = New-DiagnosticsConsoleCommand `
    -ServerUrl 'http://192.168.64.1:8080' `
    -FailureFolderName '003688.2026-07-20.16-18-13.4287d16ff2c346a98ea90fd3a0c307da.incomplete/test-amazon-linux-2023-01' `
    -DiagnosticsFileName '2026-07-20.16-23.system.diagnostic.yuruna.update.txt'

# Verbatim OCR of a HEALTHY capture: every error in it is real. Note it stops
# at '$H/yurur' -- the command continues on screen but the engine only
# recognized this far. Healthy captures are routinely partial.
$EchoHealthy = 'Lch0luser1@ch01host1 JS HFhttp:/7192.168.64.1:8080:F=003688.2026-07-20.16-18-13.4287d16fPZc346a9Bea90Fd3a0c307da.incomplete/test-amazon-Tinux-2023-01:N=2026-07-20.16-23.system.diagnostic.yuruna.update.txticd /tmp:cur -fsSLo y.ps1 $H/yurur'

# The same line after a key stuck in autorepeat.
$EchoCorrupt = $EchoHealthy + ('y' * 1400)

# Gross truncation: the echo died a few characters in.
$EchoTruncated = 'Lch0luser1@ch01host1 JS HFhttp:/7192.168.64'

Describe 'Test-ConsoleEchoIntact - real capture samples' {

    It 'passes the healthy capture despite pervasive OCR noise and a partial read' {
        # The single most important assertion in this file. If it fails, the
        # console rung stops working on every guest, healthy or not.
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoHealthy) `
            -Because 'A correctly typed line must verify even when OCR mangles it and reads only part of it.'
    }

    It 'fails the autorepeat-corrupted capture' {
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoCorrupt) `
            -Because 'A stuck key appending ~1400 characters must be caught before Enter.'
    }

    It 'fails a grossly truncated echo' {
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoTruncated) `
            -Because 'An echo showing only the first few characters means the line never landed.'
    }

    It 'separates the healthy and corrupt samples by a wide margin, not a hair' {
        # A threshold that only just separates the samples would be luck. The
        # corrupt sample must stay corrupt even if the tolerance is doubled,
        # and the healthy sample must stay intact even if it is quartered.
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoCorrupt -MaxUnexplainedRun 160)
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoHealthy -MaxUnexplainedRun 20)
    }
}

Describe 'Test-ConsoleEchoIntact - degradation to unknown' {

    It 'returns unknown for empty OCR text' {
        # This is the severe-corruption case on macOS: Vision crops to the
        # densest text cluster and a wall of repeated glyphs defeats it, so
        # it returns nothing exactly when the damage is worst. Empty must
        # never read as intact (we would submit a destroyed line) and never
        # as corrupt (we would abandon a healthy one).
        Assert-Equal -Expected 'unknown' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText '')
    }

    It 'returns unknown when OCR read too little to judge' {
        Assert-Equal -Expected 'unknown' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText 'ch01host1')
    }

    It 'returns unknown for whitespace-only OCR text' {
        Assert-Equal -Expected 'unknown' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText "   `n `t  `n  ")
    }

    It 'returns unknown when there is no expected command to compare against' {
        Assert-Equal -Expected 'unknown' -Actual (Test-ConsoleEchoIntact -Expected '' -OcrText $EchoHealthy)
    }
}

Describe 'Test-ConsoleEchoIntact - noise tolerance properties' {

    It 'tolerates scattered single-character substitutions' {
        # Isolated noise can only ever invalidate GramSize consecutive
        # windows, so it cannot accumulate into a long unexplained run no
        # matter how much of it there is. This is the property that lets the
        # predicate be strict about runs while staying loose about accuracy.
        $chars = $EchoHealthy.ToCharArray()
        for ($i = 7; $i -lt $chars.Length; $i += 11) { $chars[$i] = '#' }
        $noisy = -join $chars
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $noisy) `
            -Because 'Roughly 9% of characters corrupted at random must still verify.'
    }

    It 'catches a stuck key regardless of which character sticks' {
        foreach ($ch in 'y', 'a', '0', '.', '/', 'm') {
            $sample = $EchoHealthy + ($ch * 400)
            Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $sample) `
                -Because "A stuck '$ch' must be caught even when the character occurs in the command."
        }
    }

    It 'catches garbage inserted in the middle of the line, not only at the end' {
        $mid = $EchoHealthy.Insert(120, ('q' * 300))
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $mid)
    }

    It 'ignores an arbitrarily long shell prompt or banner ahead of the command' {
        # Text printed BEFORE the command is legitimately unexplainable and
        # unbounded, so run counting must not start until the command itself
        # has been recognized.
        $banner = ('Welcome to Amazon Linux 2023. Last login: Mon Jul 20 16:18:13 2026 from 192.168.64.1. ' * 6)
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText ($banner + $EchoHealthy))
    }
}

Describe 'Test-ConsoleEchoIntact - equality-style checks are excluded by construction' {

    It 'does not require the OCR text to contain the whole command' {
        # The healthy sample stops two thirds of the way through. Asserting
        # this explicitly so a future tightening that demands a tail anchor
        # (Content-Type, the trailing rm) fails here rather than in the field.
        Assert-True -Condition ($EchoHealthy -notmatch 'Content-Type') 'Sample must not contain the command tail.'
        Assert-True -Condition ($EchoHealthy -notmatch 'rm -f')        'Sample must not contain the trailing rm.'
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoHealthy)
    }

    It 'judges the line as a whole rather than asking whether fragments appear somewhere' {
        # Test-OCRMatch is the module's other text predicate and is NOT
        # usable here: it answers "is this prompt on screen", splitting its
        # pattern on whitespace and punctuation and requiring only that each
        # fragment appear somewhere in the text. On a screen that still shows
        # the command plus a wall of garbage, every fragment is present.
        #
        # The check below is the structural version of that argument, stated
        # without depending on Test-OCRMatch's internals: the corrupt sample
        # CONTAINS the healthy one verbatim, so any predicate satisfied by
        # "the expected content is present" passes it. Only a predicate that
        # also weighs what is present in EXCESS can tell them apart.
        Assert-True -Condition ($EchoCorrupt.StartsWith($EchoHealthy)) 'Corrupt sample must contain the healthy one intact.'
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoHealthy)
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoCorrupt)
    }
}
