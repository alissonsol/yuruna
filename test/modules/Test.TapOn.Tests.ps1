<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42217d8b-7cee-4d21-a2ec-c0e80e72c346
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test tapon ocr click
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
    The tapOn verb: how a label is matched among Tesseract word boxes, which
    match is clicked and where, the checks made before the first capture, the
    second look at a doubled copy of the frame, and what a failed lookup
    leaves behind.
.DESCRIPTION
    tapOn compared labels with -like, which read '[', ']', '*' and '?' as a
    pattern and threw on an unbalanced '['; joined words of two columns that
    shared a line; read the frame once per label; slept past its deadline;
    and failed with a bare timeout that named nothing it had read. The cases
    drive the matcher with scripted word boxes, Invoke-TapOn with stand-in
    captures, reads, scalers and pointer providers on an injected clock, and
    the real Tesseract and host scaler on the committed frame
    test/fixtures/ocr/tapon-buttons.png.
#>

BeforeAll {
    function New-Box {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: returns an in-memory word box; no state changes.')]
        [OutputType([hashtable])]
        param(
            [string]$Text,
            [int]$X,
            [int]$Y,
            [int]$W = 40,
            [int]$H = 12,
            [int]$Line = 1,
            [int]$Par = 1,
            [int]$Block = 1,
            [int]$Word = 1
        )
        return @{ text = $Text; x = $X; y = $Y; w = $W; h = $H; conf = 95; block = $Block; par = $Par; line = $Line; word = $Word }
    }

    function New-PngStandIn {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a throwaway PNG header under the test drive.')]
        param([string]$Path, [long]$Width, [long]$Height)
        # The signature, the IHDR length and type, the size, then zeros: 33
        # bytes, built element by element so no comma binds before an operator.
        $bytes = [System.Collections.Generic.List[byte]]::new()
        foreach ($value in 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52) { $bytes.Add([byte]$value) }
        foreach ($size in $Width, $Height) {
            foreach ($shift in 24, 16, 8, 0) { $bytes.Add([byte](($size -shr $shift) -band 255)) }
        }
        while ($bytes.Count -lt 33) { $bytes.Add([byte]0) }
        [IO.File]::WriteAllBytes($Path, $bytes.ToArray())
    }

    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR', 'YURUNA_RUNTIME_DIR'
    $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'log'
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $null = New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR, $env:YURUNA_RUNTIME_DIR -Force
    $script:LogDir = $env:YURUNA_LOG_DIR
    $script:Frame = Join-Path $PSScriptRoot '../fixtures/ocr/tapon-buttons.png'

    # Plain script blocks: a closure would bind $script: to its own dynamic
    # module, and a clock built that way never moves.
    $script:Tick = [ref]0L
    $script:Slept = [System.Collections.Generic.List[int]]::new()
    $script:Clock = { $script:Tick.Value }
    $script:Sleep = { param($ms) $script:Slept.Add($ms); $script:Tick.Value += $ms }
    $script:Clicks = [System.Collections.Generic.List[object]]::new()

    Register-HostIOProvider -HostType 'test.tapon.click' -Action 'Send-Click' -Implementation {
        param([hashtable]$a)
        $script:Clicks.Add($a)
        return $true
    }
}

AfterAll {
    $providers = Get-Variable -Name 'YurunaHostIOProviders' -Scope Global -ValueOnly
    foreach ($key in @($providers.Keys | Where-Object { $_ -like 'test.tapon.*' })) { $providers.Remove($key) }
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'Find-OcrWordBoxMatch' {
    It 'match word finds Next and leaves Nextcloud alone' {
        $m = Find-OcrWordBoxMatch -Box @((New-Box -Text 'Nextcloud' -X 10 -Y 10), (New-Box -Text 'Next' -X 10 -Y 40 -Line 2)) -Label 'Next' -MatchMode word
        Assert-Equal -Expected 1 -Actual $m.Count
        Assert-StringEqual -Expected 'Next' -Actual $m[0].text
    }

    It 'match word ignores case and punctuation at the ends of a word' {
        $boxes = @((New-Box -Text 'NEXT.' -X 10 -Y 10), (New-Box -Text '(next)' -X 10 -Y 40 -Line 2))
        foreach ($candidate in 'Next', '(Next).') {
            $m = Find-OcrWordBoxMatch -Box $boxes -Label $candidate -MatchMode word
            Assert-Equal -Expected 2 -Actual $m.Count -Because "label $candidate"
            Assert-StringEqual -Expected 'NEXT.' -Actual $m[0].text
            Assert-StringEqual -Expected '(next)' -Actual $m[1].text
        }
    }

    It 'match word keeps punctuation inside a word' {
        $m = Find-OcrWordBoxMatch -Box @(New-Box -Text 'test-ubuntu' -X 10 -Y 10) -Label 'test' -MatchMode word
        Assert-Equal -Expected 0 -Actual $m.Count
        $m = Find-OcrWordBoxMatch -Box @(New-Box -Text '24.04.3' -X 10 -Y 10) -Label '24.04.3' -MatchMode word
        Assert-Equal -Expected 1 -Actual $m.Count
        Assert-StringEqual -Expected '24.04.3' -Actual $m[0].text
    }

    It 'match contains takes <Label> literally' -ForEach @(
        @{ Label = '[Y/n]' }, @{ Label = 'What?' }, @{ Label = '5*3' }, @{ Label = '[' }
    ) {
        $boxes = @(
            (New-Box -Text 'Cancel' -X 10 -Y 10 -Line 1)
            (New-Box -Text 'What' -X 10 -Y 40 -Line 2)
            (New-Box -Text '5xx3' -X 10 -Y 70 -Line 3)
            (New-Box -Text $Label -X 10 -Y 100 -Line 4)
        )
        $m = Find-OcrWordBoxMatch -Box $boxes -Label $Label -MatchMode contains
        Assert-Equal -Expected 1 -Actual $m.Count
        Assert-StringEqual -Expected $Label -Actual $m[0].text
    }

    It 'match contains returns every match in box order' {
        $boxes = @(
            (New-Box -Text 'Nextcloud' -X 10 -Y 10 -Line 1)
            (New-Box -Text 'Next' -X 10 -Y 40 -Line 2)
            (New-Box -Text 'Next' -X 10 -Y 70 -Line 3)
        )
        $m = Find-OcrWordBoxMatch -Box $boxes -Label 'Next'
        Assert-Equal -Expected 3 -Actual $m.Count
        Assert-StringEqual -Expected 'Nextcloud' -Actual $m[0].text
    }

    It 'a multi-word label matches adjacent words on one line' {
        $m = Find-OcrWordBoxMatch -Box @((New-Box -Text 'Install' -X 100 -Y 50 -W 60), (New-Box -Text 'now' -X 175 -Y 50 -W 30 -Word 2)) -Label 'Install now'
        Assert-Equal -Expected 1 -Actual $m.Count
        Assert-Equal -Expected 100 -Actual $m[0].x
        Assert-Equal -Expected 105 -Actual $m[0].w
        Assert-StringEqual -Expected 'Install now' -Actual $m[0].text
    }

    It 'words on one line in separate columns are not joined' {
        $boxes = @((New-Box -Text 'here' -X 10 -Y 50), (New-Box -Text 'Right' -X 519 -Y 50 -Word 2))
        foreach ($mode in 'contains', 'word') {
            Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'here Right' -MatchMode $mode).Count -Because "mode $mode"
        }
    }

    It 'words on different lines are not joined' {
        $boxes = @((New-Box -Text 'here' -X 10 -Y 50 -Line 1), (New-Box -Text 'Right' -X 55 -Y 50 -Line 2))
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'here Right').Count
    }

    It 'one tall box does not widen the join' {
        $boxes = @(
            (New-Box -Text 'Back' -X 10 -Y 50 -W 40 -H 12)
            (New-Box -Text 'Next' -X 112 -Y 50 -W 40 -H 32 -Word 2)
            (New-Box -Text 'Cancel' -X 214 -Y 50 -W 60 -H 12 -Word 3)
        )
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'Back Next').Count
    }

    It 'a box of punctuation is stepped over in word mode' {
        $boxes = @(
            (New-Box -Text 'Save' -X 10 -Y 50 -W 40)
            (New-Box -Text '-' -X 56 -Y 50 -W 6 -Word 2)
            (New-Box -Text 'Exit' -X 68 -Y 50 -W 36 -Word 3)
        )
        Assert-Equal -Expected 1 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'Save Exit' -MatchMode word).Count
        Assert-Equal -Expected 1 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'Save - Exit' -MatchMode word).Count
        Assert-Equal -Expected 1 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'Save - Exit' -MatchMode contains).Count
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label 'Save Exit' -MatchMode contains).Count
    }

    It 'the center is the rounded middle of the union' {
        # [int] rounds a half to the even number; existing coordinates keep it.
        Assert-Equal -Expected 12 -Actual (Find-OcrWordBoxMatch -Box @(New-Box -Text 'a' -X 10 -Y 0 -W 5) -Label 'a')[0].centerX
        Assert-Equal -Expected 14 -Actual (Find-OcrWordBoxMatch -Box @(New-Box -Text 'a' -X 11 -Y 0 -W 5) -Label 'a')[0].centerX
    }

    It 'an empty label or no boxes match nothing' {
        $boxes = @(New-Box -Text 'Next' -X 10 -Y 10)
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label '').Count
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $boxes -Label '   ').Count
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box @() -Label 'Next').Count
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $null -Label 'Next').Count
    }
}

Describe 'Lines, closest words and halving' {
    It 'groups words into the phrases a label can match' {
        $boxes = @(
            (New-Box -Text 'Left' -X 10 -Y 50 -Word 1)
            (New-Box -Text 'here' -X 55 -Y 50 -Word 2)
            (New-Box -Text 'Right' -X 519 -Y 50 -Word 3)
            (New-Box -Text 'there' -X 564 -Y 50 -Word 4)
        )
        $segments = Get-OcrWordBoxLine -Box $boxes
        Assert-Equal -Expected 2 -Actual $segments.Count
        Assert-StringEqual -Expected 'Left here' -Actual $segments[0].text
        Assert-Equal -Expected 1 -Actual $segments[0].segment
        Assert-Equal -Expected 10 -Actual $segments[0].x
        Assert-Equal -Expected 85 -Actual $segments[0].w
        Assert-StringEqual -Expected 'Right there' -Actual $segments[1].text
        Assert-Equal -Expected 2 -Actual $segments[1].segment
        Assert-Equal -Expected 519 -Actual $segments[1].x
        Assert-Equal -Expected 85 -Actual $segments[1].w
    }

    It 'lists the closest words read, best first, at most five' {
        $texts = 'lagree', 'agree', 'agreed', 'agrees', 'disagree', 'Iagree', 'Agree'
        $boxes = @(for ($i = 0; $i -lt $texts.Count; $i++) { New-Box -Text $texts[$i] -X 10 -Y (10 + 30 * $i) -Line ($i + 1) })
        $entries = @(Get-OcrClosestWord -Box $boxes -Label 'I agree')
        Assert-StringEqual -Expected "'lagree' 100% | 'Iagree' 100% | 'agree' 83% | 'agreed' 83% | 'agrees' 83%" -Actual ($entries -join ' | ')
    }

    It 'offers a run of words for a label of several words' {
        $boxes = @((New-Box -Text 'l' -X 10 -Y 10 -W 4 -Word 1), (New-Box -Text 'agree' -X 20 -Y 10 -Word 2))
        $entries = @(Get-OcrClosestWord -Box $boxes -Label 'I agree')
        Assert-StringEqual -Expected "'l agree' 100%" -Actual $entries[0]
    }

    It 'never runs words across two reads' {
        # A native read and a doubled read concatenated: word numbers start
        # again at 1, so the last word of one never runs into the other.
        $boxes = @((New-Box -Text 'agree' -X 10 -Y 10 -Word 1), (New-Box -Text 'l' -X 10 -Y 10 -W 4 -Word 1))
        $entries = @(Get-OcrClosestWord -Box $boxes -Label 'I agree')
        Assert-Equal -Expected 0 -Actual @($entries | Where-Object { $_.StartsWith("'agree l'") }).Count
    }

    It 'lists nothing below the bar' {
        $entries = @(Get-OcrClosestWord -Box @((New-Box -Text 'Back' -X 10 -Y 10), (New-Box -Text 'Next' -X 60 -Y 10 -Word 2)) -Label 'Finish')
        Assert-Equal -Expected 0 -Actual $entries.Count
    }

    It 'halves a box of the doubled copy outward' {
        $doubled = New-Box -Text 'Next' -X 2001 -Y 1201 -W 199 -H 79 -Word 3
        $halved = InModuleScope Test.SequenceEngine -Parameters @{ Entry = $doubled } {
            param($Entry)
            $out = ConvertTo-HalvedWordBox -Box @($Entry)
            $out[0]
        }
        Assert-Equal -Expected 1000 -Actual $halved.x
        Assert-Equal -Expected 600 -Actual $halved.y
        Assert-Equal -Expected 100 -Actual $halved.w
        Assert-Equal -Expected 40 -Actual $halved.h
        Assert-StringEqual -Expected 'Next' -Actual $halved.text
        Assert-Equal -Expected 3 -Actual $halved.word
    }

    It 'reads the size from the PNG header' {
        $png = Join-Path $TestDrive 'size-640x260.png'
        New-PngStandIn -Path $png -Width 640 -Height 260
        $short = Join-Path $TestDrive 'short.png'
        [IO.File]::WriteAllBytes($short, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A))
        $text = Join-Path $TestDrive 'text.png'
        Set-Content -LiteralPath $text -Value 'this is not a PNG file at all, only text'
        $zero = Join-Path $TestDrive 'zero-width.png'
        New-PngStandIn -Path $zero -Width 0 -Height 260
        # Wrapped in a hashtable so that a $null answer keeps its place.
        $read = InModuleScope Test.SequenceEngine -Parameters @{ Paths = @($png, $short, $text, $zero) } {
            param($Paths)
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $Paths) { $out.Add((Get-PngPixelSize -Path $entry)) }
            @{ Sizes = $out.ToArray() }
        }
        $sizes = $read.Sizes
        Assert-Equal -Expected 640 -Actual $sizes[0].Width
        Assert-Equal -Expected 260 -Actual $sizes[0].Height
        Assert-Null $sizes[1] 'a 7-byte file has no header'
        Assert-Null $sizes[2] 'a text file is not a PNG'
        Assert-Null $sizes[3] 'a width of 0 is no size'
    }
}

Describe 'Invoke-TapOn' {
    BeforeAll {
        Register-HostIOProvider -HostType 'test.tapon.hyperv' -Action 'Send-Click' -Implementation {
            param([hashtable]$a)
            # Hyper-V maps client pixels to the screen itself.
            $script:Transformed = @([int]$a.X, [int]$a.Y)
            return $true
        }
        Register-HostIOProvider -HostType 'test.tapon.utm' -Action 'Send-Click' -Implementation {
            param([hashtable]$a)
            # UTM adds the window origin to the pixel divided by the Retina scale.
            $script:Transformed = @([int][math]::Round($a.Capture.OriginX + $a.X / $a.Capture.Scale), [int][math]::Round($a.Capture.OriginY + $a.Y / $a.Capture.Scale))
            return $true
        }
    }

    BeforeEach {
        $state = Get-SequenceFailureState
        Reset-SequenceFailureSlot -Lifetime step -State $state
        $state.LastFailedStepInvocationId = 'step-x'
        $script:Tick.Value = 0
        $script:Captures = 0
        $script:Slept.Clear()
        $script:Clicks = [System.Collections.Generic.List[object]]::new()
        $script:NativeBoxes = @()
        $script:DoubledBoxes = @()
        $script:CaptureShape = @{ HWnd = 1; Width = 1280; Height = 800 }
        $script:LastCapture = $null
        $script:Transformed = $null
        Get-ChildItem -LiteralPath $script:LogDir -File | Remove-Item -Force
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine {
            $script:Captures++
            Set-Content -LiteralPath $OutFile -Value "frame $($script:Captures)"
            $capture = $script:CaptureShape.Clone()
            $capture.ImagePath = $OutFile
            $script:LastCapture = $capture
            return $capture
        }
        Mock Get-TesseractWordBox -ModuleName Test.SequenceEngine {
            if ((Split-Path -Leaf $ImagePath).StartsWith('clickbutton_')) { return $script:NativeBoxes }
            return $script:DoubledBoxes
        }
        Mock New-DoubledFrame -ModuleName Test.SequenceEngine { @{ Path = ''; Reason = 'no-scaler'; Detail = 'stand-in' } }
        Mock Find-Tesseract -ModuleName Test.SequenceEngine { '/usr/bin/tesseract' }
        Mock Write-RunnerStepHeartbeat -ModuleName Test.SequenceEngine { }
    }

    Context 'clicking' {
        It 'clicks the match center plus the offsets, once, with the capture it read' {
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50 -W 40 -H 12)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -OffsetX 5 -OffsetY -3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the click was sent'
            Assert-Equal -Expected 1 -Actual $script:Clicks.Count
            Assert-Equal -Expected 125 -Actual $script:Clicks[0].X
            Assert-Equal -Expected 53 -Actual $script:Clicks[0].Y
            Assert-StringEqual -Expected 'left' -Actual $script:Clicks[0].Click
            Assert-True ([object]::ReferenceEquals($script:Clicks[0].Capture, $script:LastCapture)) 'the provider receives the capture of the pass, unchanged'
        }

        It 'reads a frame once for all labels and clicks the first label that matches' {
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Install', 'Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'Next was clicked'
            Assert-Equal -Expected 1 -Actual $script:Clicks.Count
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 1 -Exactly
        }

        It 'two word matches without nth fail at once, list both and send no click' {
            $script:NativeBoxes = @((New-Box -Text 'Next' -X 10 -Y 10 -Line 1), (New-Box -Text 'Next' -X 10 -Y 40 -Line 2))
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -MatchMode 'word' `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            $state = Get-SequenceFailureState
            Assert-True ($all[-1] -eq $false) 'an ambiguous label fails the step'
            Assert-Equal -Expected 1 -Actual $script:Captures -Because 'waiting does not make a label unique'
            Assert-Equal -Expected 0 -Actual $script:Clicks.Count
            Assert-StringEqual -Expected 'deterministic' -Actual $state.StepHostInputFault.kind
            Assert-StringEqual -Expected 'ambiguous-label' -Actual $state.StepHostInputFault.reason
            Assert-StringEqual -Expected 'step-x' -Actual $state.StepHostInputFault.stepInvocationId
            Assert-StringEqual -Expected 'wait' -Actual $state.StepFailurePhase
            Assert-True (Test-StepHostInputFaultDeterministic) 'a retry around the step stops after one attempt'
            $expected = Format-YurunaOperatorMessage -Key 'runner.tapon_label_ambiguous' -Arguments @{ label = 'Next'; count = 2; candidates = "'Next' at (30,16), 'Next' at (30,46)" }
            Assert-True ($warnings -contains $expected) "the warning lists both positions; got: $($warnings -join ' | ')"
            Assert-StringEqual -Expected 'frame 1' -Actual (Get-Content -LiteralPath (Join-Path $script:LogDir 'failure_screenshot_vm1.png') -Raw).Trim()
            Assert-StringEqual -Expected 'Next|Next' -Actual (@(Get-Content -LiteralPath (Join-Path $script:LogDir 'failure_ocr_vm1.txt')) -join '|')
        }

        It 'nth 2 clicks the second match' {
            $script:NativeBoxes = @((New-Box -Text 'Next' -X 10 -Y 10 -Line 1), (New-Box -Text 'Next' -X 10 -Y 40 -Line 2))
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -Nth 2 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the second match was clicked'
            Assert-Equal -Expected 1 -Actual $script:Clicks.Count
            Assert-Equal -Expected 30 -Actual $script:Clicks[0].X
            Assert-Equal -Expected 46 -Actual $script:Clicks[0].Y
        }

        It 'nth beyond the matches keeps polling and its timeout names the count' {
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 10 -Y 10)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -Nth 2 -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $false) 'one match cannot satisfy nth 2'
            Assert-Equal -Expected 2 -Actual $script:Captures
            Assert-Equal -Expected 0 -Actual $script:Clicks.Count
            $closest = @((Get-SequenceFailureState).WaitForTextClosestOnScreen)
            Assert-True ($closest -contains "[tesseract] 'Next' matched 1 on the last frame; nth 2 was asked") "got: $($closest -join ' | ')"
        }

        It 'an invalid option fails before any capture: <Case>' -ForEach @(
            @{ Case = 'match fuzzy'; Set = @{ MatchMode = 'fuzzy' }; Detail = "match='fuzzy'" }
            @{ Case = 'match Word'; Set = @{ MatchMode = 'Word' }; Detail = "match='Word'" }
            @{ Case = 'nth 0'; Set = @{ Nth = 0 }; Detail = "nth='0'" }
            @{ Case = 'nth two'; Set = @{ Nth = 'two' }; Detail = "nth='two'" }
            @{ Case = 'nth 1.5'; Set = @{ Nth = 1.5 }; Detail = "nth='1.5'" }
            @{ Case = 'click middle'; Set = @{ Click = 'middle' }; Detail = "click='middle'" }
            @{ Case = 'no label'; Set = @{ Label = @('  ') }; Detail = "label=''" }
            @{ Case = 'word label without letters'; Set = @{ MatchMode = 'word'; Label = '...' }; Detail = "label='...'" }
        ) {
            $arguments = @{ HostType = 'test.tapon.click'; VMName = 'vm1'; Label = @('Next')
                Deadline = (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock); Sleep = $script:Sleep }
            foreach ($key in $Set.Keys) { $arguments[$key] = $Set[$key] }
            $all = @(Invoke-TapOn @arguments 3>&1)
            $fault = (Get-SequenceFailureState).StepHostInputFault
            Assert-True ($all[-1] -eq $false) 'the step fails'
            Should -Invoke Get-VMScreenshot -ModuleName Test.SequenceEngine -Times 0 -Exactly
            Assert-StringEqual -Expected 'invalid-argument' -Actual $fault.reason
            Assert-StringEqual -Expected 'deterministic' -Actual $fault.kind
            Assert-StringEqual -Expected $Detail -Actual $fault.detail
        }

        It 'a host with no pointer provider fails before any capture' {
            $all = @(Invoke-TapOn -HostType 'test.tapon.none' -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $fault = (Get-SequenceFailureState).StepHostInputFault
            Assert-True ($all[-1] -eq $false) 'nothing can click on this host'
            Assert-Equal -Expected 0 -Actual $script:Captures
            Assert-StringEqual -Expected 'Send-Click' -Actual $fault.action
            Assert-StringEqual -Expected 'action-unavailable' -Actual $fault.reason
            Assert-StringEqual -Expected 'deterministic' -Actual $fault.kind
        }

        It 'a host without Tesseract fails before any capture' {
            Mock Find-Tesseract -ModuleName Test.SequenceEngine { $null }
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $fault = (Get-SequenceFailureState).StepHostInputFault
            Assert-True ($all[-1] -eq $false) 'nothing can locate the label'
            Assert-Equal -Expected 0 -Actual $script:Captures
            Assert-StringEqual -Expected 'locator-unavailable' -Actual $fault.reason
            Assert-StringEqual -Expected 'deterministic' -Actual $fault.kind
        }

        It 'passes click <Kind> to the provider' -ForEach @(@{ Kind = 'left' }, @{ Kind = 'right' }, @{ Kind = 'double' }) {
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -Click $Kind `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the stand-in provider sends every kind'
            Assert-StringEqual -Expected $Kind -Actual $script:Clicks[0].Click
        }

        It 'a click the provider fails sets the input phase and is not sent again' {
            $script:FailingCalls = 0
            Register-HostIOProvider -HostType 'test.tapon.failing' -Action 'Send-Click' -Implementation {
                param([hashtable]$a)
                $null = $a
                $script:FailingCalls++
                Set-HostInputFault -Kind transient -Reason 'send-failed' -Transport 'test'
                return $false
            }
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.failing' -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $state = Get-SequenceFailureState
            Assert-True ($all[-1] -eq $false) 'the click failed'
            Assert-Equal -Expected 1 -Actual $script:FailingCalls -Because 'one run of the step sends at most one click'
            Assert-StringEqual -Expected 'input' -Actual $state.StepFailurePhase
            Assert-StringEqual -Expected 'transient' -Actual $state.StepHostInputFault.kind
        }

        It 'names a click kind the provider refuses' {
            Register-HostIOProvider -HostType 'test.tapon.refusing' -Action 'Send-Click' -Implementation {
                param([hashtable]$a)
                Set-HostInputFault -Kind deterministic -Reason 'click-kind-unsupported' -Transport 'test' -Detail ([string]$a.Click)
                return $false
            }
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.refusing' -VMName 'vm1' -Label @('Next') -Click right `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            Assert-True ($all[-1] -eq $false) 'the provider refused the kind'
            $expected = Format-YurunaOperatorMessage -Key 'runner.tapon_click_kind_unsupported' -Arguments @{ hostType = 'test.tapon.refusing'; click = 'right' }
            Assert-True ($warnings -contains $expected) "got: $($warnings -join ' | ')"
        }

        It 'accepts a capture returned as a path' {
            Mock Get-VMScreenshot -ModuleName Test.SequenceEngine {
                $script:Captures++
                Set-Content -LiteralPath $OutFile -Value "frame $($script:Captures)"
                return $OutFile
            }
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the label was clicked'
            Assert-StringEqual -Expected (Join-Path $script:LogDir 'clickbutton_vm1.png') -Actual $script:Clicks[0].Capture.ImagePath
        }

        It 'moves the step heartbeat first in every pass' {
            $ast = Get-YurunaTestFileAst -Path (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1')
            $function = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-TapOn' }, $true)
            $loop = $function.Body.Find({ param($n) $n -is [System.Management.Automation.Language.WhileStatementAst] -and $n.Condition.Extent.Text -match 'Test-YurunaDeadlineExpired' }, $true)
            Assert-NotNull $loop 'Invoke-TapOn polls until its deadline'
            Assert-StringEqual -Expected 'Write-RunnerStepHeartbeat' -Actual $loop.Body.Statements[0].Extent.Text
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $false) 'nothing matched'
            Should -Invoke Write-RunnerStepHeartbeat -ModuleName Test.SequenceEngine -Times 2 -Exactly
            Should -Invoke Get-VMScreenshot -ModuleName Test.SequenceEngine -Times 2 -Exactly
        }

        It 'waits for the next poll when a capture names no file' {
            Mock Get-VMScreenshot -ModuleName Test.SequenceEngine {
                $script:Captures++
                if ($script:Captures -eq 1) { return $null }
                if ($script:Captures -eq 2) { return @{ ImagePath = (Join-Path $TestDrive 'missing.png') } }
                Set-Content -LiteralPath $OutFile -Value "frame $($script:Captures)"
                $capture = $script:CaptureShape.Clone()
                $capture.ImagePath = $OutFile
                $script:LastCapture = $capture
                return $capture
            }
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 9000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the third capture was read and clicked'
            Assert-Equal -Expected 3 -Actual $script:Captures
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 1 -Exactly
            Assert-StringEqual -Expected '3000,3000' -Actual (@($script:Slept) -join ',')
        }

        It 'warns a failed read once and names it on the timeout' {
            Mock Get-TesseractWordBox -ModuleName Test.SequenceEngine { throw 'tesseract exploded' }
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            Assert-True ($all[-1] -eq $false) 'no read succeeded'
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 2 -Exactly
            $expected = Format-YurunaOperatorMessage -Key 'runner.operator_afe15df7c41fff0a' -Arguments @{ value = 'tesseract exploded' }
            Assert-Equal -Expected 1 -Actual @($warnings | Where-Object { $_ -ceq $expected }).Count -Because "got: $($warnings -join ' | ')"
            $closest = @((Get-SequenceFailureState).WaitForTextClosestOnScreen)
            Assert-True ($closest -contains "[tesseract] no words were read while looking for 'Next'") "got: $($closest -join ' | ')"
            Assert-True ($closest -contains '[tesseract] the last read failed: tesseract exploded') "got: $($closest -join ' | ')"
        }
    }

    Context 'failure output' {
        It 'a label that never appears writes the frame and the words read, and sets the wait phase' {
            $script:NativeBoxes = @((New-Box -Text 'Back' -X 10 -Y 10 -Line 1), (New-Box -Text 'Cancel' -X 10 -Y 40 -Line 2))
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $state = Get-SequenceFailureState
            Assert-True ($all[-1] -eq $false) 'the label never appeared'
            Assert-StringEqual -Expected 'frame 2' -Actual (Get-Content -LiteralPath (Join-Path $script:LogDir 'failure_screenshot_vm1.png') -Raw).Trim()
            Assert-StringEqual -Expected 'Back|Cancel' -Actual (@(Get-Content -LiteralPath (Join-Path $script:LogDir 'failure_ocr_vm1.txt')) -join '|')
            Assert-StringEqual -Expected 'Next' -Actual (@($state.WaitForTextPatternsSought) -join '|')
            Assert-StringEqual -Expected 'wait' -Actual $state.StepFailurePhase
            Assert-False $state.WaitForTextConsoleSignalsMeasured 'tapOn runs neither console tracker'
            Assert-Equal -Expected 0 -Actual @(Get-ChildItem -LiteralPath $script:LogDir -Filter 'failure_clickbutton_*').Count
            Assert-False (Test-Path -LiteralPath (Join-Path $script:LogDir 'clickbutton_vm1.png')) 'the capture is removed'
        }

        It 'lists the closest words for each label on a timeout' {
            $script:NativeBoxes = @((New-Box -Text 'lagree' -X 10 -Y 10 -Line 1), (New-Box -Text 'Back' -X 10 -Y 40 -Line 2))
            $null = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('I agree', 'Finish') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $closest = @((Get-SequenceFailureState).WaitForTextClosestOnScreen)
            Assert-Equal -Expected 2 -Actual $closest.Count -Because "got: $($closest -join ' | ')"
            Assert-True ($closest[0].Contains("'lagree' 100%")) $closest[0]
            Assert-StringEqual -Expected "[tesseract] none of the 2 words read came within 60% of 'Finish'" -Actual $closest[1]
        }

        It 'says so when nothing was read' {
            $null = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $closest = @((Get-SequenceFailureState).WaitForTextClosestOnScreen)
            Assert-Equal -Expected 1 -Actual $closest.Count
            Assert-StringEqual -Expected "[tesseract] no words were read while looking for 'Next'" -Actual $closest[0]
        }
    }

    Context 'the second look' {
        BeforeEach {
            $script:DoubledPath = Join-Path $TestDrive 'doubled.png'
            $script:ScalerTimeouts = [System.Collections.Generic.List[int]]::new()
            $script:ReadTimeouts = [System.Collections.Generic.List[int]]::new()
        }

        It 'makes the doubled copy only after a miss on the frame as captured' {
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine {
                Set-Content -LiteralPath $script:DoubledPath -Value 'doubled'
                @{ Path = $script:DoubledPath; Reason = ''; Detail = '' }
            }
            $script:NativeBoxes = @(New-Box -Text 'Next' -X 100 -Y 50)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the label was on the frame as captured'
            Should -Invoke New-DoubledFrame -ModuleName Test.SequenceEngine -Times 0 -Exactly
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 1 -Exactly
        }

        It 'clicks at native coordinates a label only the doubled copy shows' {
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine {
                Set-Content -LiteralPath $script:DoubledPath -Value 'doubled'
                @{ Path = $script:DoubledPath; Reason = ''; Detail = '' }
            }
            $script:DoubledBoxes = @(New-Box -Text 'Next' -X 2000 -Y 1200 -W 200 -H 80)
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -OffsetX 5 -OffsetY -3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the doubled copy showed the label'
            Assert-Equal -Expected 1055 -Actual $script:Clicks[0].X
            Assert-Equal -Expected 617 -Actual $script:Clicks[0].Y
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 2 -Exactly
            Assert-False (Test-Path -LiteralPath $script:DoubledPath) 'the doubled copy is removed'
        }

        It 'applies the <HostName> transform once to a label found on the doubled copy' -ForEach @(
            @{ HostName = 'Hyper-V'; HostType = 'test.tapon.hyperv'; Shape = @{ HWnd = 1; Width = 1280; Height = 800 }; Expected = @(1050, 620) }
            @{ HostName = 'UTM'; HostType = 'test.tapon.utm'; Expected = @(625, 360)
                Shape = @{ WindowId = 7; OriginX = 100; OriginY = 50; Width = 2560; Height = 1600; PointWidth = 1280; PointHeight = 800; Scale = 2.0 } }
        ) {
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine {
                Set-Content -LiteralPath $script:DoubledPath -Value 'doubled'
                @{ Path = $script:DoubledPath; Reason = ''; Detail = '' }
            }
            $script:CaptureShape = $Shape
            $script:DoubledBoxes = @(New-Box -Text 'Next' -X 2000 -Y 1200 -W 200 -H 80)
            $all = @(Invoke-TapOn -HostType $HostType -VMName 'vm1' -Label @('Next') `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 6000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $true) 'the label was clicked'
            Assert-StringEqual -Expected ($Expected -join ',') -Actual (@($script:Transformed) -join ',') -Because 'a doubled or twice-halved coordinate gives other numbers'
        }

        It 'removes the doubled copy when its read fails' {
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine {
                Set-Content -LiteralPath $script:DoubledPath -Value 'doubled'
                @{ Path = $script:DoubledPath; Reason = ''; Detail = '' }
            }
            Mock Get-TesseractWordBox -ModuleName Test.SequenceEngine {
                if ((Split-Path -Leaf $ImagePath).StartsWith('clickbutton_')) { return $script:NativeBoxes }
                throw 'the copy could not be read'
            }
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 3000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            Assert-True ($all[-1] -eq $false) 'the label was never read'
            Assert-False (Test-Path -LiteralPath $script:DoubledPath) 'the doubled copy is removed'
            Should -Invoke New-DoubledFrame -ModuleName Test.SequenceEngine -Times 1 -Exactly
            $expected = Format-YurunaOperatorMessage -Key 'runner.tapon_second_look_failed' -Arguments @{ detail = 'the copy could not be read' }
            Assert-Equal -Expected 1 -Actual @($warnings | Where-Object { $_ -ceq $expected }).Count -Because "got: $($warnings -join ' | ')"
        }

        It 'keeps one look for the rest of the step on a host with no scaler' {
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 9000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $false) 'the label was never read'
            Assert-Equal -Expected 3 -Actual $script:Captures
            Should -Invoke New-DoubledFrame -ModuleName Test.SequenceEngine -Times 1 -Exactly
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 3 -Exactly
        }

        It 'keeps one look after the scaler fails and warns once' {
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine { @{ Path = ''; Reason = 'scaler-failed'; Detail = 'stand-in failure' } }
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 9000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            $warnings = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
            Assert-True ($all[-1] -eq $false) 'the label was never read'
            Should -Invoke New-DoubledFrame -ModuleName Test.SequenceEngine -Times 1 -Exactly
            $expected = Format-YurunaOperatorMessage -Key 'runner.tapon_second_look_failed' -Arguments @{ detail = 'stand-in failure' }
            Assert-Equal -Expected 1 -Actual @($warnings | Where-Object { $_ -ceq $expected }).Count -Because "got: $($warnings -join ' | ')"
        }

        It 'gives the scaler and each read no more than the time the step has left' {
            Mock Get-TesseractWordBox -ModuleName Test.SequenceEngine {
                $script:ReadTimeouts.Add($TimeoutSeconds)
                $script:Tick.Value += 1500
                return $script:NativeBoxes
            }
            Mock New-DoubledFrame -ModuleName Test.SequenceEngine {
                $script:ScalerTimeouts.Add($TimeoutSeconds)
                $script:Tick.Value += 1000
                @{ Path = ''; Reason = 'scaler-failed'; Detail = 'stand-in failure' }
            }
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 5000 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $false) 'the label was never read'
            Assert-StringEqual -Expected '5' -Actual (@($script:ReadTimeouts) -join ',')
            Assert-StringEqual -Expected '3' -Actual (@($script:ScalerTimeouts) -join ',')
            Assert-StringEqual -Expected '2500' -Actual (@($script:Slept) -join ',')
            Assert-Equal -Expected 1 -Actual $script:Captures
        }

        It 'starts nothing with under a second left' {
            $all = @(Invoke-TapOn -HostType 'test.tapon.click' -VMName 'vm1' -Label @('Next') -PollSeconds 3 `
                -Deadline (New-YurunaDeadline -TotalMilliseconds 900 -ClockTicks $script:Clock) -Sleep $script:Sleep 3>&1)
            Assert-True ($all[-1] -eq $false) 'no read could start'
            Assert-Equal -Expected 1 -Actual $script:Captures
            Should -Invoke Get-TesseractWordBox -ModuleName Test.SequenceEngine -Times 0 -Exactly
            Should -Invoke New-DoubledFrame -ModuleName Test.SequenceEngine -Times 0 -Exactly
        }
    }
}

Describe 'New-DoubledFrame' {
    BeforeAll {
        $script:StandInFrame = Join-Path $TestDrive 'frame.png'
        New-PngStandIn -Path $script:StandInFrame -Width 640 -Height 260
        $script:TempFolder = [IO.Path]::GetTempPath().TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }

    BeforeEach {
        $script:ScalerKind = 'magick'
        $script:ScalerDetail = ''
        $script:NativeCall = $null
        $script:NativeResult = @{ Started = $true; ExitCode = 0; TimedOut = $false; DrainTimedOut = $false; KillFailed = $false
            OutputTruncated = $false; DeadlineExhausted = $false; StdOut = ''; StdErr = '' }
        $script:NativeWrite = 'double'
        $script:TaponBefore = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'yuruna-tapon-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Mock Resolve-FrameScaler -ModuleName Test.SequenceEngine { @{ Kind = $script:ScalerKind; Detail = $script:ScalerDetail } }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.SequenceEngine {
            $script:NativeCall = @{ FilePath = $FilePath; ArgumentList = @($ArgumentList); TimeoutSeconds = $TimeoutSeconds }
            $target = [string]$ArgumentList[-1]
            if ($script:NativeWrite -eq 'double') { New-PngStandIn -Path $target -Width 1280 -Height 520 }
            elseif ($script:NativeWrite -eq 'partial') { Set-Content -LiteralPath $target -Value 'partial' }
            elseif ($script:NativeWrite -eq 'wrong') { New-PngStandIn -Path $target -Width 1280 -Height 518 }
            return $script:NativeResult
        }
    }

    It 'runs <Kind> with the documented arguments' -ForEach @(@{ Kind = 'magick' }, @{ Kind = 'convert' }, @{ Kind = 'sips' }) {
        $script:ScalerKind = $Kind
        $result = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $script:StandInFrame } {
            param($Frame)
            New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 7
        }
        try {
            Assert-StringEqual -Expected $Kind -Actual $script:NativeCall.FilePath
            $expectedArguments = if ($Kind -eq 'sips') {
                @('-z', '520', '1280', $script:StandInFrame, '--out', $result.Path)
            } else {
                @($script:StandInFrame, '-resize', '200%', $result.Path)
            }
            Assert-StringEqual -Expected ($expectedArguments -join '|') -Actual (@($script:NativeCall.ArgumentList) -join '|')
            Assert-Equal -Expected 7 -Actual $script:NativeCall.TimeoutSeconds
            Assert-StringEqual -Expected '' -Actual $result.Reason
            Assert-Match -Pattern '^yuruna-tapon-[0-9a-f]{32}\.png$' -Actual (Split-Path -Leaf $result.Path)
            Assert-StringEqual -Expected $script:TempFolder -Actual (Split-Path -Parent $result.Path)
        } finally {
            if ($result.Path) { Remove-Item -LiteralPath $result.Path -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'reports no scaler for <Case>' -ForEach @(
        @{ Case = 'no tool'; Source = 'frame'; Kind = ''; Detail = 'no magick or convert on PATH' }
        @{ Case = 'not a PNG'; Source = 'text'; Kind = 'magick'; Detail = 'not a PNG' }
        @{ Case = 'an oversized frame'; Source = 'oversized'; Kind = 'magick'; Detail = 'frame 5000x3000 exceeds 4096' }
    ) {
        $script:ScalerKind = $Kind
        $script:ScalerDetail = $Detail
        $path = switch ($Source) {
            'text' { $p = Join-Path $TestDrive 'not-a-png.png'; Set-Content -LiteralPath $p -Value 'plain text, not an image'; $p }
            'oversized' { $p = Join-Path $TestDrive 'oversized.png'; New-PngStandIn -Path $p -Width 5000 -Height 3000; $p }
            default { $script:StandInFrame }
        }
        $result = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $path } {
            param($Frame)
            New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 7
        }
        Assert-StringEqual -Expected 'no-scaler' -Actual $result.Reason
        Assert-StringEqual -Expected $Detail -Actual $result.Detail
        Assert-StringEqual -Expected '' -Actual $result.Path
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.SequenceEngine -Times 0 -Exactly
    }

    It 'fails and leaves no copy when the scaler <Case>' -ForEach @(
        @{ Case = 'timed out'; Result = @{ TimedOut = $true }; Write = 'partial'; Prefix = 'magick timed out after 7s' }
        @{ Case = 'exited 1'; Result = @{ ExitCode = 1; StdErr = 'no images defined' }; Write = 'none'; Prefix = 'magick exit 1: no images defined' }
        @{ Case = 'wrote the wrong size'; Result = @{}; Write = 'wrong'; Prefix = 'magick wrote 1280x518, expected 1280x520' }
        @{ Case = 'wrote nothing'; Result = @{}; Write = 'none'; Prefix = 'magick wrote no file' }
    ) {
        foreach ($key in $Result.Keys) { $script:NativeResult[$key] = $Result[$key] }
        $script:NativeWrite = $Write
        $result = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $script:StandInFrame } {
            param($Frame)
            New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 7
        }
        Assert-StringEqual -Expected 'scaler-failed' -Actual $result.Reason
        Assert-True (([string]$result.Detail).StartsWith($Prefix)) "detail: $($result.Detail)"
        $after = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'yuruna-tapon-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        Assert-Equal -Expected 0 -Actual @($after | Where-Object { $script:TaponBefore -notcontains $_ }).Count -Because 'a failed copy is removed'
    }
}

Describe 'Resolve-FrameScaler picks the scaler by platform' {
    BeforeAll {
        $script:EmptyBin = Join-Path $TestDrive 'empty-bin'
        $null = New-Item -ItemType Directory -Path $script:EmptyBin -Force
    }

    It 'picks the scaler by platform' {
        $windows = InModuleScope Test.SequenceEngine { Resolve-FrameScaler -Platform windows }
        Assert-StringEqual -Expected 'drawing' -Actual $windows.Kind
        $savedPath = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = $script:EmptyBin
            $linux = InModuleScope Test.SequenceEngine { Resolve-FrameScaler -Platform linux }
            $macos = InModuleScope Test.SequenceEngine { Resolve-FrameScaler -Platform macos }
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedPath
        }
        Assert-StringEqual -Expected '' -Actual $linux.Kind
        Assert-StringEqual -Expected 'no magick or convert on PATH' -Actual $linux.Detail
        Assert-StringEqual -Expected '' -Actual $macos.Kind
        Assert-StringEqual -Expected 'no sips on PATH' -Actual $macos.Detail
    }
}

# One block per platform, each with the same single case, so the suite has the
# same total everywhere and no platform skip to count.
if ($IsLinux) {
    Describe 'The Linux frame scaler' {
        It 'doubles the committed frame with the host scaler' {
            if (-not (Get-Command magick, convert -CommandType Application -ErrorAction SilentlyContinue)) {
                Set-ItResult -Skipped -Because 'ImageMagick is not installed.'
                return
            }
            $size = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $script:Frame } {
                param($Frame)
                $copy = New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 20
                try { Get-PngPixelSize -Path $copy.Path } finally { if ($copy.Path) { Remove-Item -LiteralPath $copy.Path -Force } }
            }
            Assert-Equal -Expected 1280 -Actual $size.Width
            Assert-Equal -Expected 520 -Actual $size.Height
        }
    }
}
if ($IsWindows) {
    Describe 'The Windows frame scaler' {
        It 'doubles the committed frame with the host scaler' {
            $size = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $script:Frame } {
                param($Frame)
                $copy = New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 20
                try { Get-PngPixelSize -Path $copy.Path } finally { if ($copy.Path) { Remove-Item -LiteralPath $copy.Path -Force } }
            }
            Assert-Equal -Expected 1280 -Actual $size.Width
            Assert-Equal -Expected 520 -Actual $size.Height
        }
    }
}
if ($IsMacOS) {
    Describe 'The macOS frame scaler' {
        It 'doubles the committed frame with the host scaler' {
            $size = InModuleScope Test.SequenceEngine -Parameters @{ Frame = $script:Frame } {
                param($Frame)
                $copy = New-DoubledFrame -ImagePath $Frame -TimeoutSeconds 20
                try { Get-PngPixelSize -Path $copy.Path } finally { if ($copy.Path) { Remove-Item -LiteralPath $copy.Path -Force } }
            }
            Assert-Equal -Expected 1280 -Actual $size.Width
            Assert-Equal -Expected 520 -Actual $size.Height
        }
    }
}

Describe 'The tapOn handler, registration, schema and providers' {
    It 'forwards match, nth and click, and leaves them out when the step has none' {
        Mock Invoke-TapOn -ModuleName Test.SequenceHandler { $script:TapOnBound = $PesterBoundParameters; $true }
        $handler = (Get-SequenceAction -Name tapOn).Handler
        $context = @{ Step = @{ action = 'tapOn'; label = 'Next'; match = 'word'; nth = 2; click = 'double' }; Vars = @{}
            ExpandVariable = { param($value, $variables) $null = $variables; $value }; DefaultTimeoutSeconds = 60; DefaultPollSeconds = 1
            HostType = 'test.tapon.click'; VMName = 'vm1' }
        Assert-True ((& $handler $context) -eq $true) 'the handler returns the result'
        Assert-StringEqual -Expected 'word' -Actual $script:TapOnBound['MatchMode']
        Assert-Equal -Expected 2 -Actual $script:TapOnBound['Nth']
        Assert-StringEqual -Expected 'double' -Actual $script:TapOnBound['Click']
        $context.Step = @{ action = 'tapOn'; label = 'Next' }
        Assert-True ((& $handler $context) -eq $true) 'the handler returns the result'
        foreach ($key in 'MatchMode', 'Nth', 'Click') {
            Assert-False $script:TapOnBound.ContainsKey($key) "$key is bound only when the step has it"
        }
    }

    It 'declares its requirements and keeps its own failure frame' {
        $entry = Get-SequenceAction -Name tapOn
        Assert-StringEqual -Expected 'Send-Click' -Actual (@($entry.HostIORequirement) -join ',')
        Assert-True $entry.OcrRequired 'tapOn reads the screen'
        Assert-StringEqual -Expected 'tesseract' -Actual (@($entry.OcrEngineRequirement) -join ',')
        Assert-True $entry.CapturesOwnFailureScreenshot 'tapOn saves the frame it read'
        Assert-False $entry.UsesWaitSignals 'tapOn matches no failure pattern'
        Assert-StringEqual -Expected 'input' -Actual $entry.ReplaySafety
        Assert-StringEqual -Expected 'ocr_timeout' -Actual $entry.FailureClass
        Assert-StringEqual -Expected 'tesseract' -Actual (@((Get-SequenceActionRequirementMap)['tapOn'].OcrEngine) -join ',')
    }

    It 'labels a failure with the labels it looked for' {
        $label = Get-SequenceActionFailureLabel -Step @{ action = 'tapOn'; label = @('Next', 'Continue') } -Vars @{} -ExpandVariable { param($v) $v }
        Assert-StringEqual -Expected 'tapOn: "Next'' | ''Continue"' -Actual $label
    }

    It 'the sequence schema types match, nth and click' {
        Import-Module powershell-yaml -ErrorAction Stop
        $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/sequence.schema.yml'
        $schemaJson = Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        $toJson = {
            param([hashtable]$Extra)
            $step = [ordered]@{ action = 'tapOn'; label = 'Next' }
            foreach ($key in $Extra.Keys) { $step[$key] = $Extra[$key] }
            ([ordered]@{
                description = 'schema probe'; keystrokeMechanism = 'gui'
                resource = [ordered]@{ 'ubuntu.server.26' = @('start.guest.ubuntu.server.26') }
                component = @($step)
            } | ConvertTo-Json -Depth 32)
        }
        foreach ($accepted in @{ match = 'word' }, @{ nth = 2 }, @{ click = 'double' }) {
            Assert-True (Test-Json -Json (& $toJson $accepted) -Schema $schemaJson -ErrorAction SilentlyContinue) "accepts $($accepted | ConvertTo-Json -Compress)"
        }
        foreach ($rejected in @{ match = 'fuzzy' }, @{ nth = 0 }, @{ nth = '2' }, @{ click = 'middle' }) {
            Assert-False (Test-Json -Json (& $toJson $rejected) -Schema $schemaJson -ErrorAction SilentlyContinue) "rejects $($rejected | ConvertTo-Json -Compress)"
        }
    }

    It 'the <HostName> provider refuses <Kind> before it touches the window' -ForEach @(
        @{ HostName = 'Hyper-V'; Kind = 'right'; Key = 'host.windows.hyper-v'; Backend = 'Send-ClickHyperV'; Owner = 'Test.HostIO.HyperV' }
        @{ HostName = 'Hyper-V'; Kind = 'double'; Key = 'host.windows.hyper-v'; Backend = 'Send-ClickHyperV'; Owner = 'Test.HostIO.HyperV' }
        @{ HostName = 'UTM'; Kind = 'right'; Key = 'host.macos.utm'; Backend = 'Send-ClickUtm'; Owner = 'Test.HostIO.Utm' }
        @{ HostName = 'UTM'; Kind = 'double'; Key = 'host.macos.utm'; Backend = 'Send-ClickUtm'; Owner = 'Test.HostIO.Utm' }
    ) {
        $provider = (Get-Variable -Name 'YurunaHostIOProviders' -Scope Global -ValueOnly)[$Key]['Send-Click']
        Mock -CommandName $Backend -ModuleName $Owner { throw 'the backend must not be called' }
        Clear-HostInputFault
        Assert-False (& $provider @{ VMName = 'vm1'; X = 1; Y = 1; Capture = $null; Click = $Kind }) 'the kind is refused'
        $fault = Get-HostInputFault
        Assert-StringEqual -Expected 'deterministic' -Actual $fault.kind
        Assert-StringEqual -Expected 'click-kind-unsupported' -Actual $fault.reason
        Assert-StringEqual -Expected $Kind -Actual $fault.detail
        Should -Invoke -CommandName $Backend -ModuleName $Owner -Times 0 -Exactly
    }

    It 'the <HostName> provider still sends a left click' -ForEach @(
        @{ HostName = 'Hyper-V'; Key = 'host.windows.hyper-v'; Backend = 'Send-ClickHyperV'; Owner = 'Test.HostIO.HyperV' }
        @{ HostName = 'UTM'; Key = 'host.macos.utm'; Backend = 'Send-ClickUtm'; Owner = 'Test.HostIO.Utm' }
    ) {
        $provider = (Get-Variable -Name 'YurunaHostIOProviders' -Scope Global -ValueOnly)[$Key]['Send-Click']
        Mock -CommandName $Backend -ModuleName $Owner { $true }
        Assert-True (& $provider @{ VMName = 'vm1'; X = 1; Y = 1; Capture = $null; Click = 'left' }) 'a left click is sent'
        Should -Invoke -CommandName $Backend -ModuleName $Owner -Times 1 -Exactly
        Assert-True (& $provider @{ VMName = 'vm1'; X = 1; Y = 1; Capture = $null }) 'a table without Click is a left click'
        Should -Invoke -CommandName $Backend -ModuleName $Owner -Times 2 -Exactly
    }
}

Describe 'A real read of the committed frame' {
    BeforeAll {
        $script:RealBoxes = if (Find-Tesseract) { @(Get-TesseractWordBox -ImagePath $script:Frame | ForEach-Object { $_ }) } else { @() }
    }

    It 'keeps the order and identifiers Tesseract gave' {
        if (-not (Find-Tesseract)) { Set-ItResult -Skipped -Because 'Tesseract is not installed.'; return }
        Assert-True ($script:RealBoxes.Count -gt 0) 'the frame was read'
        $previous = $null
        foreach ($entry in $script:RealBoxes) {
            foreach ($key in 'block', 'par', 'line', 'word') {
                Assert-True ([int]$entry[$key] -ge 1) "$key of '$($entry.text)' is $($entry[$key])"
            }
            $tuple = @([int]$entry.block, [int]$entry.par, [int]$entry.line, [int]$entry.word)
            if ($null -ne $previous) {
                $order = 0
                for ($i = 0; $i -lt 4 -and $order -eq 0; $i++) { $order = $tuple[$i].CompareTo($previous[$i]) }
                Assert-True ($order -ge 0) "'$($entry.text)' comes before the box read ahead of it"
            }
            $previous = $tuple
        }
    }

    It 'finds both whole words Next and not Nextcloud' {
        if (-not (Find-Tesseract)) { Set-ItResult -Skipped -Because 'Tesseract is not installed.'; return }
        $m = Find-OcrWordBoxMatch -Box $script:RealBoxes -Label 'Next' -MatchMode word
        Assert-Equal -Expected 2 -Actual $m.Count -Because "read: $(@($script:RealBoxes | ForEach-Object { $_.text }) -join ' ')"
        Assert-True ($m[0].centerX -ge 240 -and $m[0].centerX -le 330 -and $m[0].centerY -ge 135 -and $m[0].centerY -le 180) "first at ($($m[0].centerX),$($m[0].centerY))"
        Assert-True ($m[1].centerX -ge 10 -and $m[1].centerX -le 100 -and $m[1].centerY -ge 200 -and $m[1].centerY -le 245) "second at ($($m[1].centerX),$($m[1].centerY))"
        $m = Find-OcrWordBoxMatch -Box $script:RealBoxes -Label 'Next' -MatchMode contains
        Assert-Equal -Expected 3 -Actual $m.Count
        Assert-StringEqual -Expected 'Nextcloud' -Actual $m[0].text
    }

    It 'joins Install now and not agree Install' {
        if (-not (Find-Tesseract)) { Set-ItResult -Skipped -Because 'Tesseract is not installed.'; return }
        $m = Find-OcrWordBoxMatch -Box $script:RealBoxes -Label 'Install now'
        Assert-Equal -Expected 1 -Actual $m.Count
        Assert-True ($m[0].centerX -ge 380 -and $m[0].centerX -le 540 -and $m[0].centerY -ge 75 -and $m[0].centerY -le 115) "at ($($m[0].centerX),$($m[0].centerY))"
        Assert-Equal -Expected 0 -Actual (Find-OcrWordBoxMatch -Box $script:RealBoxes -Label 'agree Install').Count
    }
}
