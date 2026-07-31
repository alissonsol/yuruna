<#PSScriptInfo
.VERSION 2026.07.31
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
    engine. The healthy sample is the OCR text of a real capture verbatim.
    The corrupt samples are built from it: real captures of the stuck-key
    failure contain the non-ASCII glyphs OCR invents, which cannot live in an
    ASCII source file, so the appended garbage is reconstructed here in the
    shape those captures take (a clean autorepeat run, and the mixed-glyph
    run tesseract actually produces from one).

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

# The stuck key as OCR actually renders it: a wall of repeated glyphs does
# not survive OCR as one clean character, it comes back as mixed noise across
# many lines ('PUPPY PY BBY PPP...'). This shape, not the clean run, is what
# a real capture holds, so it is what pins the threshold against reality.
$EchoMixedCorrupt = $EchoHealthy + 'rm y1.' + (('PUPPY PY BBY PPP YB BP PY BBY PPP YB ') * 40)

# A screenful of ordinary, heterogeneous console output ABOVE the command --
# a reboot/shutdown log rather than a repeated banner. Unlike a repeated
# banner it offers no periodic coincidental gram hits, so it is the honest
# test that scrollback preceding the command is not scored as corruption.
$EchoScrollback = @'
The system is going down for reboot now. Broadcast message from root.
Stopping User Manager for UID 1000. Removed slice User Slice of ch01user1.
Reached target Shutdown. Reached target Final Step. Unmounting /home.
Please stand by while the operating system reconfigures the network stack.
Authentication required to manage system services over the control bus.
'@ + $EchoHealthy

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

    It 'fails a stuck key that OCR rendered as mixed glyphs, not a clean run' {
        # The default-threshold pin: this is the realistic shape of the real
        # failure (garbage read as 'PUPPY PY BBY...'), and it must be caught
        # with NO threshold override, so loosening the default breaks here.
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoMixedCorrupt) `
            -Because 'A stuck key must be caught at the default threshold even when OCR scatters it into mixed glyphs.'
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

    It 'ignores a screenful of heterogeneous scrollback ahead of the command' {
        # The honest version of the banner test, and the regression guard for
        # a real defect: ordinary console output above the command (a boot or
        # shutdown log) is unexplained and shares no periodic run with the
        # command, so a naive "count everything after the first explained
        # position" measure scored a perfectly healthy frame as corrupt and
        # abandoned the capture without pressing Enter. It must verify.
        Assert-Equal -Expected 'intact' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText $EchoScrollback) `
            -Because 'A healthy command with unrelated scrollback above it must not be judged corrupt.'
    }

    It 'still catches corruption that trails scrollback plus the command' {
        # The complement of the guard above: excluding leading scrollback must
        # not blind the check to garbage that follows the command echo.
        Assert-Equal -Expected 'corrupt' -Actual (Test-ConsoleEchoIntact -Expected $EchoExpected -OcrText ($EchoScrollback + ('y' * 400)))
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
