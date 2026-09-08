<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42b8bc4c-f5b0-463b-9fd9-76f8a65ee16f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence chain pester
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
    Pester coverage for the chain-convergence seams in Test.SequenceEngine.psm1:
    Select-SequenceStepWindow (the in-memory -StartStep/-StopStep slice, so
    Debug-TestSequence needs no temp-YAML step files) and Get-SequenceFinishedVMName
    (the shared mid-chain rename surface both chain paths read).
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    The window helper is pure and fully covered here; the rename surface's value
    is set by a live Invoke-Sequence run (host I/O), so only its default + type
    contract are unit-checked -- the propagation itself is an operator live-cycle
    validation (snapshot-chain workload).
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.SequenceEngine.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function New-StepList {
    [CmdletBinding()]
    [OutputType([object[]])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: builds an in-memory step array; changes no state.')]
    param([int]$Count)
    return @(1..$Count | ForEach-Object { @{ action = "step$_" } })
}

# A flooded console as it actually appears: a repeating start/finish PAIR,
# further split into fragments by OCR of a framebuffer, so the most common
# single line covers only a third of the screen. Any rule requiring ONE line to
# dominate misses precisely this shape. Defined here and not in the Describe
# body for the discovery-scope reason noted below.
function Get-FloodText {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Pairs = 33)
    return ((1..$Pairs | ForEach-Object {
        @('start: subiquity/Network/_send_update: CHANGE etho',
          'finish: subiquity/Network/_send_updete: CHANGE etho',
          'sub iquitg/Netl_uork/ _send_update:',
          'CHANGE etho') -join "`n"
    }) -join "`n")
}

# Lines that stay distinct AFTER normalization. Digits are folded to '#' before
# counting, so varying only a number produces one shape, not many -- a fixture
# built that way would be uniform while looking varied and would assert the
# opposite of what it reads like.
function Get-DistinctLineSet {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([int]$Count)
    $words = @(
        'unpacking base system into target', 'configuring apt package manager',
        'installing kernel linux generic', 'writing partition table to vda',
        'mounting target boot efi partition', 'downloading security updates now',
        'running curtin extract stage', 'setting up grub efi amd',
        'generating locales en us utf', 'final system configuration stage',
        'acquiring packages from archive mirror', 'creating logical volume group',
        'formatting filesystem as ext', 'copying installer log to target',
        'enabling openssh server unit', 'importing authorized keys for user',
        'updating initramfs for all kernels', 'probing block devices for layout',
        'applying netplan configuration now', 'starting subiquity server process',
        'reading autoinstall from seed volume', 'validating storage layout request',
        'calculating package dependency set', 'unmounting target filesystems',
        'writing machine identity file'
    )
    return @($words | Select-Object -First $Count)
}

# The Export-ModuleMember statement text the export guard matches against, read at
# FILE scope: a Describe body is executed during discovery and its variables are
# discarded before any It runs, so an in-Describe $script:exportStmt would reach the
# guard as $null.
$script:exportStmt = [regex]::Match((Get-Content -Raw (Join-Path $here 'Test.SequenceEngine.psm1')), '(?s)Export-ModuleMember.*').Value

# @() at each call mirrors how Invoke-Sequence consumes the result -- PowerShell
# unwraps a one-element return, so callers wrap to keep array semantics.
}

Describe 'Select-SequenceStepWindow' {
    It 'returns all steps for a whole-sequence window (default)' {
        $s = New-StepList -Count 6
        Assert-Equal -Expected 6 -Actual @(Select-SequenceStepWindow -Steps $s).Count -Because 'default = whole'
        Assert-Equal -Expected 6 -Actual @(Select-SequenceStepWindow -Steps $s -StartStep 1 -StopStep 0).Count -Because '(1,0) = whole'
    }
    It 'slices an inclusive 1-based window and renumbers to the slice' {
        $w = @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 3 -StopStep 5)
        Assert-Equal -Expected 3 -Actual $w.Count -Because 'count'
        Assert-Equal -Expected 'step3' -Actual $w[0].action -Because 'first is the window start'
        Assert-Equal -Expected 'step5' -Actual $w[-1].action -Because 'last is the window stop'
    }
    It 'runs from StartStep to the end when StopStep is 0' {
        Assert-Equal -Expected 3 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 4).Count -Because '4..end of 6'
    }
    It 'supports a single-step window' {
        $w = @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 2 -StopStep 2)
        Assert-Equal -Expected 1 -Actual $w.Count -Because 'single step'
        Assert-Equal -Expected 'step2' -Actual $w[0].action -Because 'the right step'
    }
    It 'clamps StopStep beyond the total' {
        Assert-Equal -Expected 2 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 5 -StopStep 99).Count -Because 'clamped 5..6'
    }
    It 'returns empty for an out-of-range window or empty input' {
        Assert-Equal -Expected 0 -Actual @(Select-SequenceStepWindow -Steps (New-StepList -Count 6) -StartStep 10 -StopStep 12).Count -Because 'out of range'
        Assert-Equal -Expected 0 -Actual @(Select-SequenceStepWindow -Steps @() -StartStep 1 -StopStep 0).Count -Because 'empty input'
    }
}

Describe 'Invoke-GuestSequenceList warm-resume threading' {
    # The skip-until-reach path runs without touching the filesystem: sequences
    # before the resume target are skipped (Invoke-SequenceByName never called),
    # so a resume target that is not in the list leaves every entry skipped and
    # must refuse to report a (false) success -- the guard under test.
    It 'refuses success when the resume target is not in the workload list (all skipped)' {
        $r = Invoke-GuestSequenceList -PhaseLabel 'Workload' -HostType 'host.ubuntu.kvm' -GuestKey 'g' `
            -VMName 'test-x' -RepoRoot (Split-Path -Parent $here) -SequencesDir $here `
            -SequenceNames @('seq.a', 'seq.b') -ResumeFromSequence 'seq.zzz' -ResumeFromStep 5
        Assert-Equal -Expected $false -Actual $r.success -Because 'no sequence ran, so success would be false-positive'
        Assert-True ($r.errorMessage -like '*not found in the workload list*') 'errorMessage names the missing resume target'
    }
    It 'treats an empty sequence list as skipped regardless of resume args' {
        $r = Invoke-GuestSequenceList -PhaseLabel 'Workload' -HostType 'host.ubuntu.kvm' -GuestKey 'g' `
            -VMName 'test-x' -RepoRoot (Split-Path -Parent $here) -SequencesDir $here `
            -SequenceNames @() -ResumeFromSequence 'seq.a' -ResumeFromStep 3
        Assert-True $r.skipped 'empty list => skipped'
    }
}

Describe 'Invoke-SequenceByName -StartStep' {
    It 'exposes a -StartStep parameter (the warm-resume forward to Invoke-Sequence)' {
        $p = (Get-Command Invoke-SequenceByName).Parameters
        Assert-True ($p.ContainsKey('StartStep')) 'Invoke-SequenceByName must accept -StartStep'
        Assert-Equal -Expected 'Int32' -Actual $p['StartStep'].ParameterType.Name -Because 'StartStep is an int'
    }
}

Describe 'Get-SequenceFinishedVMName' {
    It 'returns a string (default empty before any sequence ran in this session)' {
        $v = Get-SequenceFinishedVMName
        Assert-True ($v -is [string]) 'string contract'
    }
}

Describe 'Get-OcrDegradationGrace' {
    It 'grants a full window for a console restart' {
        Assert-Equal 45 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'grants half the window (rounded up) for a lighter ring repair' {
        Assert-Equal 23 (Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'clamps the grant to the remaining budget under the cap' {
        Assert-Equal 20 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 100 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'returns 0 when the per-wait cap is exhausted (a dead feed still times out)' {
        Assert-Equal 0 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 120 -MaxGrantSeconds 120 -BaseWindowSeconds 45)
    }
    It 'returns 0 when there is no grace budget at all' {
        Assert-Equal 0 (Get-OcrDegradationGrace -Action 'ring-repair' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 0 -BaseWindowSeconds 45)
    }
    It 'caps a console restart to a small total budget (short waits)' {
        Assert-Equal 10 (Get-OcrDegradationGrace -Action 'console-restart' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 10 -BaseWindowSeconds 45)
    }
    It 'rejects an out-of-set action at the parameter binder' {
        $threw = $false
        try { [void](Get-OcrDegradationGrace -Action 'reboot-guest' -AlreadyGrantedSeconds 0 -MaxGrantSeconds 120 -BaseWindowSeconds 45) }
        catch { $threw = $true }
        Assert-True $threw 'ValidateSet should reject an unknown action'
    }
}

Describe 'Wait-ForText periodic nudge contract' {
    It 'exposes optional key and interval parameters without changing plain waits' {
        $p = (Get-Command Wait-ForText).Parameters
        Assert-True ($p.ContainsKey('NudgeKey')) 'Wait-ForText must accept the recovery key'
        Assert-True ($p.ContainsKey('NudgeIntervalSeconds')) 'Wait-ForText must accept the recovery cadence'
    }
    It 'checks success and installer failures before injecting the recovery key' {
        $t = (Get-Command Wait-ForText).ScriptBlock.Ast.Extent.Text
        $positiveAt = $t.IndexOf('if ($result.Match)')
        $failureAt  = $t.IndexOf('$activeFailurePattern = @($FailurePattern)')
        $nudgeAt    = $t.IndexOf('$nudgeOk = [bool](Send-Key')
        Assert-True ($positiveAt -ge 0) 'located the positive match branch'
        Assert-True ($failureAt -ge 0) 'located the failure-pattern branch'
        Assert-True ($nudgeAt -ge 0) 'located the periodic key injection'
        Assert-True ($positiveAt -lt $nudgeAt) 'a visible target must return before another key is sent'
        Assert-True ($failureAt -lt $nudgeAt) 'an installer crash must abort before Enter is sent'
    }
    It 're-arms from the actual send time so slow OCR cannot cause key bursts' {
        $t = (Get-Command Wait-ForText).ScriptBlock.Ast.Extent.Text
        Assert-True ($t -match [regex]::Escape('$nextNudgeUtc = $nudgeNowUtc.AddSeconds($NudgeIntervalSeconds)')) `
            'the next key deadline must advance from now, not from a stale target'
    }
}

Describe 'Get-ConsoleFloodVerdict' {
    # The third content state a poll can be in, and the one both existing
    # self-heals are blind to. A blank capture is caught by the no-text counter;
    # a capture that stopped changing is caught by the frame-hash freeze check. A
    # console scrolling one repeating line is neither -- the feed is live and the
    # screen is full -- yet the pattern being sought has been pushed off the
    # surface and cannot return while the flood lasts. Told apart from an
    # ordinary "pattern never printed", it names the guest as the owner; left
    # together, the record sends the reader to a script that was never reached.

    It 'calls a repeating pair a flood even though no single line dominates' {
        $v = Get-ConsoleFloodVerdict -Text (Get-FloodText)
        Assert-True $v.Flooded 'a surface carrying nothing but a repeating unit is unreadable for a pattern'
        Assert-True ($v.DominantCount -lt ($v.TotalLines / 2)) `
            'the fixture must keep its most common line under half the screen, or it is not testing the real shape'
        Assert-True ($v.DistinctLines -le 5) 'the whole screen is a handful of shapes'
    }

    It 'does not call a busy installer screen a flood' {
        # Many different lines means the installer is still printing, and the
        # pattern may yet arrive. Firing here would abandon healthy waits.
        $busy = @(
            'Starting subiquity server process', 'configuring apt package manager',
            'installing kernel linux-generic', 'writing partition table to /dev/vda',
            'mounting /target/boot/efi', 'downloading security updates',
            'curtin command install', 'running curtin extract',
            'acquiring 4 packages from archive.ubuntu.com', 'unpacking base system',
            'setting up grub-efi-amd64', 'Continue with autoinstall? (yes/no)',
            'generating locales en_US.UTF-8', 'final system configuration'
        ) -join "`n"
        $v = Get-ConsoleFloodVerdict -Text $busy
        Assert-True (-not $v.Flooded) 'a screen of distinct lines is progress, not repetition'
    }

    It 'does not fire on a screen that is merely half repetition' {
        # A guest printing a repeating line WHILE other output continues is still
        # producing information. The verdict has to need near-total repetition.
        $mixed = (((1..7 | ForEach-Object { 'start: subiquity/Network/_send_update: CHANGE eth0' }) + @(
            'installing kernel linux-generic', 'writing partition table', 'mounting /target',
            'Continue with autoinstall? (yes/no)', 'running curtin extract', 'setting up grub',
            'generating locales', 'final configuration step')) -join "`n")
        $v = Get-ConsoleFloodVerdict -Text $mixed
        Assert-True (-not $v.Flooded) 'half a screen of real output is not a flooded console'
    }

    It 'sees through a counter or timestamp on the repeating line' {
        # The repeating line usually carries a tick, and OCR of a framebuffer
        # misreads characters differently in each frame. Comparing raw text would
        # find variety that is only noise.
        $counted = (1..20 | ForEach-Object { "[   $_.$($_)0123] cloud-init[2263]: waiting for network configuration" }) -join "`n"
        $v = Get-ConsoleFloodVerdict -Text $counted
        Assert-True $v.Flooded 'digits are normalized away, so a ticking counter does not disguise a flood'
        Assert-Equal 1 $v.DistinctLines
    }

    It 'never calls a nearly-empty screen a flood' {
        # Two lines, both a prompt, is the screen every login wait starts on.
        # Without a floor on line count it would read as perfect repetition.
        $v = Get-ConsoleFloodVerdict -Text ("ch01host1 login:`nPassword:")
        Assert-True (-not $v.Flooded) 'a sparse screen has no evidence either way'
    }

    It 'is safe on empty and whitespace input' {
        foreach ($t in @('', '   ', "`n`n`n")) {
            $v = Get-ConsoleFloodVerdict -Text $t
            Assert-True (-not $v.Flooded) 'no text is not a flood'
            Assert-Equal 0 $v.TotalLines
        }
    }

    It 'scales its diversity threshold with how much evidence the screen holds' {
        # A 200-line screen may carry a couple of dozen shapes and still be
        # repeating; a 12-line one must be almost uniform before the same claim
        # is safe. A fixed distinct-line threshold would be wrong at one end or
        # the other.
        $wide = (@(Get-DistinctLineSet -Count 24) +
                 (1..176 | ForEach-Object { 'start: subiquity/Network/_send_update: CHANGE eth0' })) -join "`n"
        $wideVerdict = Get-ConsoleFloodVerdict -Text $wide
        Assert-Equal 25 $wideVerdict.DistinctLines
        Assert-True $wideVerdict.Flooded `
            '25 shapes in 200 lines is still a screen overwriting itself'
        $narrow = (@(Get-DistinctLineSet -Count 6) +
                   (1..6 | ForEach-Object { 'start: subiquity/Network/_send_update: CHANGE eth0' })) -join "`n"
        $narrowVerdict = Get-ConsoleFloodVerdict -Text $narrow
        Assert-Equal 7 $narrowVerdict.DistinctLines
        Assert-True (-not $narrowVerdict.Flooded) `
            'half of twelve lines is not enough evidence to abandon the pattern'
    }
}

Describe 'Sequence-start pause gate reports the hold' {
    # The gate holds the runner while the guest keeps running, so a hold is part
    # of the cause of whatever the next step finds on screen. Behavior here needs
    # a live sequence run, host contracts and a runtime dir, so this guards the
    # wiring structurally: both ends on the event stream, and the release handed
    # to the failure record. Losing any of the three puts a 30-minute hold back
    # where it was -- in the human log only, invisible to every consumer that
    # reads the failure.
    BeforeAll {
        $errs = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $here 'Test.SequenceEngine.psm1'), [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors in Test.SequenceEngine.psm1: $($errs[0].Message)" }
        $assign = $moduleAst.FindAll({
                param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                          $n.Left.Extent.Text -eq '$waitWhilePaused'
            }, $true)
        if (-not $assign) { throw 'the $waitWhilePaused gate was not found in Test.SequenceEngine.psm1' }
        $script:gateText = $assign[0].Right.Extent.Text
    }

    It 'emits both ends of the hold' {
        Assert-Match -Pattern "event\s*=\s*'sequence_paused'"  -Actual $script:gateText `
            -Because 'an open hold must be visible even if the runner never releases it'
        Assert-Match -Pattern "event\s*=\s*'sequence_resumed'" -Actual $script:gateText `
            -Because 'the release carries the duration a reader joins on'
    }

    It 'measures the hold and hands the release to the failure record' {
        Assert-Match -Pattern 'heldSeconds' -Actual $script:gateText -Because 'a hold with no duration reports nothing useful'
        Assert-Match -Pattern '\$script:Fail\.LastPauseRelease' -Actual $script:gateText `
            -Because 'the failure record is where a hold stops looking like a guest that never printed'
    }

    It 'never lets telemetry block the gate' {
        # A pause that cannot be emitted is still a pause; the operator's resume
        # must not depend on an emitter being loaded.
        Assert-Match -Pattern 'Get-Command Send-CycleEventSafely' -Actual $script:gateText `
            -Because 'the emit is guarded, not assumed'
    }
}

Describe 'Get-ConsoleTextSignature' {
    # What makes "the console stopped moving" measurable at all. Raw captures of
    # an unchanged screen are never equal -- a blinking cursor alone guarantees
    # that -- which is exactly why the byte-hash freeze detector cannot see a
    # guest parked on a prompt. Comparing normalized text can.

    It 'reads two captures of an unchanged screen as the same screen' {
        $a = "start: subiquity/Network/_send_update: CHANGE eth0`nfinish: subiquity/Network/_send_update: CHANGE eth0"
        $b = "start:  subiquity/Network/_send_update: CHANGE eth0`r`nfinish: subiquity/Network/_send_update: CHANGE eth0  "
        Assert-Equal -Expected (Get-ConsoleTextSignature -Text $a) -Actual (Get-ConsoleTextSignature -Text $b) `
            -Because 'whitespace and line-ending jitter between captures is not the guest printing'
    }

    It 'still separates screens whose text actually differs' {
        $a = Get-ConsoleTextSignature -Text 'Continue with autoinstall? (yes|no)'
        $b = Get-ConsoleTextSignature -Text 'Installing system'
        Assert-True ($a -ne $b) 'a screen that changed must not read as unchanged'
    }

    It 'answers empty for empty input rather than throwing' {
        # An empty baseline is the one case where "changed" proves nothing, so
        # the callers test for it -- which requires a value, not an exception.
        Assert-Equal -Expected '' -Actual (Get-ConsoleTextSignature -Text '')
    }
}

Describe 'Module export surface' {
    # Assert against the Export-ModuleMember statement text, not ExportedFunctions:
    # Get-PollDelay is defined in Test.Backoff (never in this module), so PowerShell
    # silently ignores an Export-ModuleMember entry for it -- it is absent from
    # ExportedFunctions either way. Guarding the SOURCE list is what actually
    # catches a regression that re-adds the misleading re-export.
    It 'does not list Get-PollDelay in Export-ModuleMember (it is owned by Test.Backoff, resolved via the -Global import)' {
        Assert-True ($script:exportStmt.Length -gt 0) 'located the Export-ModuleMember statement'
        Assert-True ($script:exportStmt -notmatch '\bGet-PollDelay\b') 'Get-PollDelay belongs to Test.Backoff; callers resolve it via the global import, not an Invoke-Sequence re-export'
    }
    It 'still exports the core dispatch surface and pure helpers' {
        $exported = (Get-Module Test.SequenceEngine).ExportedFunctions.Keys
        foreach ($fn in 'Invoke-Sequence', 'Invoke-SequenceByName', 'Wait-ForText', 'Select-SequenceStepWindow', 'Get-OcrDegradationGrace', 'Get-ConsoleFloodVerdict', 'Get-ConsoleTextSignature', 'Get-LastWaitVerdict', 'Wait-ForConsoleChange', 'Get-LastConsoleChangeVerdict') {
            Assert-True ($exported -contains $fn) "expected export missing: $fn"
        }
    }
}

Describe 'Wait-ForConsoleChange separates a still console from an unreadable one' {
    BeforeAll {
        # Stubs live in the engine's own session state so the unqualified calls
        # inside Wait-ForConsoleChange resolve to them, and their recording bag
        # lives there too -- an It body holds a reference to the same object once
        # the reset hands it back, so the assertions read what the stubs wrote.
        . (Get-Module Test.SequenceEngine) {
            function Get-CycleScreenDir {
                # SupportsShouldProcess rather than a manual -WhatIf switch, because
                # that is how the real helper takes the -WhatIf:$false the caller
                # passes it; a hand-rolled switch would bind but diverge.
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds.')]
                [CmdletBinding(SupportsShouldProcess)]
                param($VMName)
                $null = $PSCmdlet.ShouldProcess($script:ProbeStub.ScreenDir, 'Ensure cycle screen dir exists')
                return $script:ProbeStub.ScreenDir
            }
            function Get-VMScreenshot {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds; only OutFile is recorded.')]
                param($VMName, $OutFile, $HostType)
                $script:ProbeStub.OutFiles += @([string]$OutFile)
                Set-Content -LiteralPath $OutFile -Value 'png' -NoNewline
                return $true
            }
            function Test-CombinedOcrMatch {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Stub: the signature has to match the real helper so the caller binds; the text is scripted.')]
                param($ImagePath, $Pattern, $FreshMatchTailLines)
                return @{ Match = $false; AnyText = [string]$script:ProbeStub.OcrText; EngineResults = @{} }
            }
            function Reset-ProbeStubState {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Test stub helper: reseeds an in-memory recording bag; no external state.')]
                param([string]$ScreenDir)
                $script:ProbeStub = @{
                    ScreenDir = $ScreenDir
                    OutFiles  = @()
                    OcrText   = ''
                }
                return $script:ProbeStub
            }
        }
    }

    BeforeEach {
        $script:probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-probe-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:probeDir -Force | Out-Null
        $script:probe = & (Get-Module Test.SequenceEngine) { param($d) Reset-ProbeStubState -ScreenDir $d } $script:probeDir
    }

    AfterEach {
        Remove-Item -LiteralPath $script:probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'calls a console with no readable text unreadable, not unchanged' {
        # The whole point of the verdict: an OCR surface that came back empty on
        # every frame observed nothing about the guest, and a caller told only
        # "false" would report the guest as having ignored what was sent to it.
        $script:probe.OcrText = ''
        $changed = Wait-ForConsoleChange -VMName 'vm-01' -BaselineText 'parked prompt' -TimeoutSeconds 2 -PollSeconds 1 -WarningAction SilentlyContinue
        $v = Get-LastConsoleChangeVerdict
        Assert-False $changed 'an unreadable console is not a changed console'
        Assert-False ([bool]$v.Readable) 'no frame yielded text, so nothing was read'
        Assert-True ($v.Captures -gt 0) 'frames were captured and confirmed present'
        Assert-Equal -Expected 0 -Actual $v.Reads -Because 'not one of those captures produced text'
    }

    It 'reports a console that moved as changed and readable' {
        $script:probe.OcrText = 'installing system'
        $changed = Wait-ForConsoleChange -VMName 'vm-01' -BaselineText 'parked prompt' -TimeoutSeconds 2 -PollSeconds 1
        $v = Get-LastConsoleChangeVerdict
        Assert-True $changed 'content differing from the baseline is the answer being consumed'
        Assert-True ([bool]$v.Readable) 'the frame was read'
        Assert-True ([bool]$v.Changed) 'the verdict must agree with the return value'
    }

    It 'reports a readable console that held still as unchanged, not unreadable' {
        $script:probe.OcrText = 'parked prompt'
        $changed = Wait-ForConsoleChange -VMName 'vm-01' -BaselineText 'parked prompt' -TimeoutSeconds 2 -PollSeconds 1
        $v = Get-LastConsoleChangeVerdict
        Assert-False $changed 'the content never differed from the baseline'
        Assert-True ([bool]$v.Readable) 'the reader worked; it is the guest that held still'
        Assert-True ($v.Reads -gt 0) 'frames were read even though none differed'
    }

    It 'captures to a name short enough to leave the path under a native reader ceiling' {
        # The probe file is the deepest artifact the harness writes: cycle folder,
        # nested stage folder, per-VM screens folder, then this name. Spending the
        # guest name here again -- the folder already carries it -- is what pushed
        # the path past what the OCR engines can open, and an unopenable capture
        # reads as a console with no text on it.
        $script:probe.OcrText = 'parked prompt'
        $null = Wait-ForConsoleChange -VMName 'test-guest.ubuntu.server.24-01' -BaselineText 'parked prompt' -TimeoutSeconds 2 -PollSeconds 1
        Assert-True ($script:probe.OutFiles.Count -gt 0) 'the probe captured at least one frame'
        $name = [System.IO.Path]::GetFileName($script:probe.OutFiles[0])
        Assert-True ($name.Length -le 16) "probe file name '$name' must stay short; every character here comes off the path budget"
        Assert-True ($name -notmatch 'test-guest') 'the per-VM directory already names the guest; repeating it only lengthens the path'
    }
}
