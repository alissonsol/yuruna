<#PSScriptInfo
.VERSION 2026.11.23
.GUID 420c96e5-f59d-45b7-98c5-ebfba2695a78
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm pointer qemu
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
    The KVM pointer transport: Send-ClickKvm clicks a guest through QEMU's
    input-send-event monitor command, and its registration as Send-Click for
    host.ubuntu.kvm.
.DESCRIPTION
    Covers the pixel-to-axis mapping, the four (or six) monitor calls of a
    click with their caps and budget, and the fault each failure records. The
    failure this suite exists for is a click that is made twice or left with
    its button held: a press whose delivery is unknown must never be sent
    again, a press that may have landed must be released, also when the
    pipeline is stopped, and the recorded fault must say whether any button
    event may have reached the guest, because a retry reads it. The monitor
    calls are mocked in module scope; a stand-in virsh on a private PATH entry
    proves the argument and environment shape and the release on a stopped
    pipeline.
#>

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.Kvm.psm1') -Force -DisableNameChecking -Global
}

Describe 'KVM pointer transport' {
    InModuleScope Test.Transport {
        BeforeAll {
            function Get-PointerTestCallName {
                param([object[]]$Calls)
                foreach ($call in $Calls) {
                    $events = [string]$call.ArgumentList[4]
                    if ($events.Contains('"down":true')) { 'press' }
                    elseif ($events.Contains('"down":false')) { 'release' }
                    elseif ($events.Contains('{"axis":"x","value":32767}')) { 'park' }
                    else { 'move' }
                }
            }
            $script:PointerTestCapture = @{ ImagePath = 'x.png'; Width = 1280; Height = 800 }
            $script:PointerTestNoAnswer = @{ Started = $true; ExitCode = 124; TimedOut = $true; StdOut = ''; StdErr = ''; ElapsedMs = 4600 }
            $script:PointerTestNotLaunched = @{ Started = $false; ExitCode = -1; DeadlineExhausted = $true; StdOut = ''; StdErr = ''; ElapsedMs = 0 }
            function Get-PointerTestErrorReply {
                param([string]$Text)
                @{ Started = $true; ExitCode = 0; StdOut = ('{"id":"libvirt-2","error":{"class":"GenericError","desc":"' + $Text + '"}}'); StdErr = ''; ElapsedMs = 15 }
            }
            function Get-PointerTestLibvirtFailure {
                param([string]$Text)
                @{ Started = $true; ExitCode = 1; StdOut = ''; StdErr = "error: $Text"; ElapsedMs = 12 }
            }
            function Get-PointerTestOkReply {
                param([int]$ElapsedMs = 15)
                @{ Started = $true; ExitCode = 0; StdOut = '{"return":{},"id":"libvirt-1"}'; StdErr = ''; ElapsedMs = $ElapsedMs }
            }
        }

        BeforeEach {
            $script:PointerTestCalls = [System.Collections.Generic.List[object]]::new()
            $script:PointerTestSleeps = [System.Collections.Generic.List[int]]::new()
            $script:PointerTestReplies = [System.Collections.Generic.Queue[object]]::new()
            Clear-HostInputFault
            Mock Start-Sleep { $script:PointerTestSleeps.Add([int]$Milliseconds) }
            Mock Invoke-BoundedNativeCommand {
                $script:PointerTestCalls.Add(@{
                    FilePath       = $FilePath
                    ArgumentList   = @($ArgumentList)
                    TimeoutSeconds = $TimeoutSeconds
                    Environment    = $Environment
                    HasDeadline    = $PesterBoundParameters.ContainsKey('Deadline')
                    RemainingMs    = if ($PesterBoundParameters.ContainsKey('Deadline')) {
                        Get-YurunaDeadlineRemainingMs -Deadline $Deadline } else { -1 }
                })
                if ($script:PointerTestReplies.Count -gt 0) { return $script:PointerTestReplies.Dequeue() }
                return @{ Started = $true; ExitCode = 0; StdOut = '{"return":{},"id":"libvirt-1"}'; StdErr = ''; ElapsedMs = 15 }
            }
        }

        It 'maps the checked-in points of 1280x800 and 1024x768 frames' {
            $expected = @{
                1280 = @{ 0 = 12; 1 = 38; 2 = 64; 3 = 89; 320 = 8204; 639 = 16371; 640 = 16396; 1278 = 32729; 1279 = 32755 }
                800  = @{ 0 = 20; 1 = 61; 2 = 102; 3 = 143; 200 = 8212; 399 = 16363; 400 = 16404; 798 = 32706; 799 = 32747 }
                1024 = @{ 0 = 16; 1 = 48; 2 = 80; 3 = 112; 256 = 8208; 511 = 16368; 512 = 16400; 1022 = 32720; 1023 = 32752 }
                768  = @{ 0 = 21; 1 = 64; 2 = 106; 3 = 149; 192 = 8213; 383 = 16362; 384 = 16405; 766 = 32704; 767 = 32746 }
            }
            foreach ($side in $expected.Keys) {
                foreach ($px in $expected[$side].Keys) {
                    Assert-Equal $expected[$side][$px] (ConvertTo-KvmPointerAxis -Pixel $px -Size $side) "pixel $px of $side"
                }
            }
        }

        It 'returns every pixel under floor(axis * size / 32768)' {
            foreach ($side in @(2, 1280, 800, 1024, 768, 1920, 1080)) {
                for ($px = 0; $px -lt $side; $px++) {
                    $axis = ConvertTo-KvmPointerAxis -Pixel $px -Size $side
                    $back = [int][Math]::Floor($axis * [double]$side / 32768)
                    if ($back -ne $px) { Assert-Equal $px $back "pixel $px of $side went to axis $axis" }
                }
            }
        }

        It 'clamps a pixel outside the frame to the edge pixel' {
            Assert-Equal 12 (ConvertTo-KvmPointerAxis -Pixel -7 -Size 1280)
            Assert-Equal 32755 (ConvertTo-KvmPointerAxis -Pixel 5000 -Size 1280)
        }

        It 'sends move, press, release and park for a left click' {
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningVariable w -WarningAction SilentlyContinue
            Assert-True ($result -is [bool] -and $result) 'a delivered click returns $true alone'
            Assert-Equal 4 $script:PointerTestCalls.Count
            $prefix = '{"execute":"input-send-event","arguments":{"events":['
            $expected = @(
                ($prefix + '{"type":"abs","data":{"axis":"x","value":16396}},{"type":"abs","data":{"axis":"y","value":16404}}]}}')
                ($prefix + '{"type":"btn","data":{"down":true,"button":"left"}}]}}')
                ($prefix + '{"type":"btn","data":{"down":false,"button":"left"}}]}}')
                ($prefix + '{"type":"abs","data":{"axis":"x","value":32767}},{"type":"abs","data":{"axis":"y","value":16383}}]}}')
            )
            for ($i = 0; $i -lt 4; $i++) {
                $call = $script:PointerTestCalls[$i]
                Assert-StringEqual 'virsh' $call.FilePath
                Assert-Equal 5 $call.ArgumentList.Count
                Assert-StringEqual '--connect' $call.ArgumentList[0]
                Assert-StringEqual 'qemu:///system' $call.ArgumentList[1]
                Assert-StringEqual 'qemu-monitor-command' $call.ArgumentList[2]
                Assert-StringEqual 'vm' $call.ArgumentList[3]
                Assert-True ($expected[$i] -ceq $call.ArgumentList[4]) "call $i sent $($call.ArgumentList[4])"
                Assert-Equal 5 $call.TimeoutSeconds
                Assert-StringEqual 'C' $call.Environment.LC_MESSAGES
                Assert-True ($call.Environment.ContainsKey('LC_ALL') -and $call.Environment.LC_ALL -ceq '') 'LC_ALL is emptied'
            }
            Assert-StringEqual '50,50' ($script:PointerTestSleeps -join ',')
            Assert-Null (Get-HostInputFault)
            Assert-Equal 0 $w.Count
        }

        It 'presses the right button for a right click' {
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click right)
            Assert-Match '"button":"right"' $script:PointerTestCalls[1].ArgumentList[4]
            Assert-Match '"button":"right"' $script:PointerTestCalls[2].ArgumentList[4]
        }

        It 'sends two press and release pairs for a double click, then parks' {
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click double)
            Assert-StringEqual 'move,press,release,press,release,park' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            Assert-StringEqual '50,50,80,50' ($script:PointerTestSleeps -join ',')
        }

        It 'binds the move, the presses and the park to the budget and never a release' {
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click double)
            Assert-StringEqual 'True,True,False,True,False,True' (($script:PointerTestCalls | ForEach-Object { $_.HasDeadline }) -join ',')
            $remaining = $script:PointerTestCalls[0].RemainingMs
            Assert-True ($remaining -gt 14000 -and $remaining -le 15000) "the move had $remaining ms of budget"
        }

        It 'scales from the capture it is given' {
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture @{ ImagePath = 'x.png'; Width = 1280; Height = 800 })
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture @{ ImagePath = 'x.png'; Width = 1024; Height = 768 })
            Assert-Match '"value":16396}},\{"type":"abs","data":\{"axis":"y","value":16404\}' $script:PointerTestCalls[0].ArgumentList[4]
            Assert-Match '"value":20496}},\{"type":"abs","data":\{"axis":"y","value":17088\}' $script:PointerTestCalls[4].ArgumentList[4]
        }

        It 'reads an empty kind as left' {
            Assert-True (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click '')
            Assert-Match '"down":true,"button":"left"' $script:PointerTestCalls[1].ArgumentList[4]
        }

        It 'refuses a click kind the pointer does not implement: <Kind>' -ForEach @(
            @{ Kind = 'middle' }
            @{ Kind = 'RIGHT' }
        ) {
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click $Kind -WarningVariable w -WarningAction SilentlyContinue
            Assert-False $result
            $fault = Get-HostInputFault
            Assert-StringEqual 'deterministic' $fault.kind
            Assert-StringEqual 'click-kind-unsupported' $fault.reason
            Assert-StringEqual 'KVM' $fault.transport
            Assert-True ($fault.detail -ceq $Kind) "detail was $($fault.detail)"
            Assert-Equal 0 $fault.delivered
            Assert-Equal 0 $script:PointerTestCalls.Count
            Assert-Equal 0 $w.Count
        }

        It 'refuses a frame it cannot scale from: <Name>' -ForEach @(
            @{ Name = 'no capture'; Frame = $null }
            @{ Name = 'no Width'; Frame = @{ ImagePath = 'x.png'; Height = 800 } }
            @{ Name = 'Width 0'; Frame = @{ ImagePath = 'x.png'; Width = 0; Height = 800 } }
            @{ Name = 'Width 1'; Frame = @{ ImagePath = 'x.png'; Width = 1; Height = 800 } }
            @{ Name = 'Width -5'; Frame = @{ ImagePath = 'x.png'; Width = -5; Height = 800 } }
            @{ Name = 'Width NaN'; Frame = @{ ImagePath = 'x.png'; Width = [double]::NaN; Height = 800 } }
            @{ Name = 'Width infinite'; Frame = @{ ImagePath = 'x.png'; Width = [double]::PositiveInfinity; Height = 800 } }
            @{ Name = 'Width abc'; Frame = @{ ImagePath = 'x.png'; Width = 'abc'; Height = 800 } }
            @{ Name = 'Width 1280.5'; Frame = @{ ImagePath = 'x.png'; Width = 1280.5; Height = 800 } }
            @{ Name = 'Width 40000'; Frame = @{ ImagePath = 'x.png'; Width = 40000; Height = 800 } }
            @{ Name = 'no Height'; Frame = @{ ImagePath = 'x.png'; Width = 1280 } }
            @{ Name = 'Height 0'; Frame = @{ ImagePath = 'x.png'; Width = 1280; Height = 0 } }
            @{ Name = 'Height NaN'; Frame = @{ ImagePath = 'x.png'; Width = 1280; Height = [double]::NaN } }
            @{ Name = 'Height 40000'; Frame = @{ ImagePath = 'x.png'; Width = 1280; Height = 40000 } }
        ) {
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $Frame -WarningVariable w -WarningAction SilentlyContinue
            Assert-False $result
            $fault = Get-HostInputFault
            Assert-StringEqual 'deterministic' $fault.kind
            Assert-StringEqual 'invalid-frame' $fault.reason
            Assert-Equal 0 $fault.delivered
            Assert-Equal 2 $fault.total
            Assert-Equal 0 $script:PointerTestCalls.Count
            Assert-Equal 1 $w.Count
        }

        It 'records a missing absolute pointer as deterministic' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestErrorReply -Text 'Input handler not found for event type abs'))
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningVariable w -WarningAction SilentlyContinue
            Assert-False $result
            $fault = Get-HostInputFault
            Assert-StringEqual 'deterministic' $fault.kind
            Assert-StringEqual 'no-absolute-pointer' $fault.reason
            Assert-StringEqual 'Input handler not found for event type abs' $fault.detail
            Assert-Equal 0 $fault.delivered
            Assert-Equal 2 $fault.total
            Assert-Equal 1 $script:PointerTestCalls.Count
            Assert-Equal 1 $w.Count
        }

        It 'treats a paused guest as nothing delivered' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestErrorReply -Text 'VM not running'))
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            $fault = Get-HostInputFault
            Assert-StringEqual 'transient' $fault.kind
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 0 $fault.delivered
            Assert-Equal 1 $script:PointerTestCalls.Count
        }

        It 'reports a move with no answer as nothing delivered' {
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            $fault = Get-HostInputFault
            Assert-StringEqual 'transient' $fault.kind
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-True ($fault.detail.StartsWith('move: virsh gave no complete answer in 4600 ms')) "detail was $($fault.detail)"
            Assert-Equal 0 $fault.delivered
            Assert-Equal 1 $script:PointerTestCalls.Count
        }

        It 'reports a move reply it cannot read as nothing delivered: <Name>' -ForEach @(
            @{ Name = 'not JSON'; StdOut = 'not json' }
            @{ Name = 'an array'; StdOut = '[1]' }
            @{ Name = 'neither return nor error'; StdOut = '{"id":"libvirt-1"}' }
        ) {
            $script:PointerTestReplies.Enqueue(@{ Started = $true; ExitCode = 0; StdOut = $StdOut; StdErr = ''; ElapsedMs = 15 })
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            $fault = Get-HostInputFault
            Assert-StringEqual 'transient' $fault.kind
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 0 $fault.delivered
            Assert-Equal 1 $script:PointerTestCalls.Count
        }

        It 'reports a missing virsh as nothing sent' {
            $script:PointerTestReplies.Enqueue(@{ Started = $false; ExitCode = -1; StartError = ''; StdOut = ''; StdErr = ''; ElapsedMs = 0 })
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            $fault = Get-HostInputFault
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-StringEqual 'move: virsh was not found' $fault.detail
            Assert-Equal 1 $script:PointerTestCalls.Count
        }

        It 'sends no release when QEMU refused the press' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestErrorReply -Text 'VM not running'))
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 0 $fault.delivered
        }

        It 'sends no release when the domain stopped before the press' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestLibvirtFailure -Text 'Requested operation is not valid: domain is not running'))
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 0 $fault.delivered
        }

        It 'counts a call the budget did not admit as not sent' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue($script:PointerTestNotLaunched)
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 0 $fault.delivered
            Assert-StringEqual 'press 1: the click budget was spent before the call' $fault.detail
        }

        It 'releases after a press with no answer and reports delivery as unknown' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningVariable w -WarningAction SilentlyContinue
            Assert-False $result
            Assert-StringEqual 'move,press,release' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'transient' $fault.kind
            Assert-StringEqual 'delivery-unknown' $fault.reason
            Assert-Equal -1 $fault.delivered
            Assert-Equal 2 $fault.total
            Assert-Equal 1 $w.Count
        }

        It 'releases after a press that failed inside libvirt' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestLibvirtFailure -Text 'Timed out during operation: cannot acquire state change lock'))
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press,release' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            Assert-StringEqual 'delivery-unknown' (Get-HostInputFault).reason
        }

        It 'keeps the first failure when the cleanup release succeeds' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press,release,release' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $detail = (Get-HostInputFault).detail
            Assert-True ($detail.StartsWith('release 1:')) "detail was $detail"
            Assert-False ($detail.Contains('release unconfirmed')) "detail was $detail"
        }

        It 'tries the release twice more and reports a button that may be held' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningVariable w -WarningAction SilentlyContinue
            Assert-False $result
            Assert-StringEqual 'move,press,release,release,release' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $detail = (Get-HostInputFault).detail
            Assert-True ($detail.EndsWith('; release unconfirmed')) "detail was $detail"
            Assert-Equal 2 $w.Count
        }

        It 'stops a double click at its first failure' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestErrorReply -Text 'VM not running'))
            Assert-False (Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click double -WarningAction SilentlyContinue)
            Assert-StringEqual 'move,press,release,press' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'send-failed' $fault.reason
            Assert-Equal 2 $fault.delivered
            Assert-Equal 4 $fault.total
        }

        It 'returns true with one warning when only the park fails' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue($script:PointerTestNoAnswer)
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningVariable w -WarningAction SilentlyContinue
            Assert-True ($result -is [bool] -and $result) 'a click whose park failed still returns $true alone'
            Assert-Null (Get-HostInputFault)
            Assert-Equal 1 $w.Count
        }

        It 'warns when the presses of a double click are more than 400 ms apart' {
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply -ElapsedMs 200))
            $script:PointerTestReplies.Enqueue((Get-PointerTestOkReply -ElapsedMs 200))
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -Click double -WarningVariable w -WarningAction SilentlyContinue
            Assert-True $result
            Assert-Equal 1 $w.Count
            Assert-Equal 6 $script:PointerTestCalls.Count
        }

        It 'releases the button when an error interrupts the hold' {
            $script:PointerTestSleepCount = 0
            Mock Start-Sleep {
                $script:PointerTestSleepCount++
                if ($script:PointerTestSleepCount -eq 2) { throw [System.IO.IOException]::new('injected') }
                $script:PointerTestSleeps.Add([int]$Milliseconds)
            }
            $result = Send-ClickKvm -VMName 'vm' -X 640 -Y 400 -Capture $script:PointerTestCapture -WarningAction SilentlyContinue
            Assert-True ($result -is [bool] -and -not $result) 'an interrupted click returns $false alone'
            Assert-StringEqual 'move,press,release' ((Get-PointerTestCallName -Calls $script:PointerTestCalls) -join ',')
            $fault = Get-HostInputFault
            Assert-StringEqual 'delivery-unknown' $fault.reason
            Assert-Equal -1 $fault.delivered
            Assert-StringEqual 'error: injected' $fault.detail
        }
    }
}

Describe 'KVM pointer through a stand-in virsh' -Skip:$IsWindows {
    BeforeAll {
        $script:StandInDir = New-YurunaTestTempDir -Prefix 'yrn-kvmpointer'
        $script:StandInCalls = Join-Path $script:StandInDir 'calls.txt'
        $script:StandInEnv = Join-Path $script:StandInDir 'env.txt'
        $script:StandInSlow = Join-Path $script:StandInDir 'slow-press'
        $script:StandInDone = Join-Path $script:StandInDir 'press-done'
        $shim = @"
#!/bin/sh
printf 'CALL\n' >> '$($script:StandInCalls)'
for argument in "`$@"; do printf '%s\n' "`$argument" >> '$($script:StandInCalls)'; done
printf 'LC_MESSAGES=%s\nLC_ALL=%s\n' "`$LC_MESSAGES" "`$LC_ALL" > '$($script:StandInEnv)'
case "`$5" in
    *'"down":true'*)
        if [ -f '$($script:StandInSlow)' ]; then
            sleep 3
            : > '$($script:StandInDone)'
        fi
        ;;
esac
printf '%s\n' '{"return":{},"id":"libvirt-1"}'
exit 0
"@
        $shimPath = Join-Path $script:StandInDir 'virsh'
        Set-Content -LiteralPath $shimPath -Value ($shim -replace "`r", '') -NoNewline -Encoding ascii
        & chmod +x $shimPath
        $script:SavedPath = Save-YurunaTestEnvironment -Name 'PATH'
        $env:PATH = $script:StandInDir + [IO.Path]::PathSeparator + $script:SavedPath.PATH

        function Get-StandInCall {
            $calls = [System.Collections.Generic.List[object]]::new()
            if (-not (Test-Path -LiteralPath $script:StandInCalls)) { return , $calls }
            $current = $null
            foreach ($line in [IO.File]::ReadAllLines($script:StandInCalls)) {
                if ($line -ceq 'CALL') {
                    $current = [System.Collections.Generic.List[string]]::new()
                    $calls.Add($current)
                } elseif ($null -ne $current) {
                    $current.Add($line)
                }
            }
            return , $calls
        }
    }

    AfterAll {
        Restore-YurunaTestEnvironment -Saved $script:SavedPath
        Remove-YurunaTestTempDir $script:StandInDir
    }

    BeforeEach {
        foreach ($file in @($script:StandInCalls, $script:StandInEnv, $script:StandInSlow, $script:StandInDone)) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes the VM name and the JSON as one argument each under the C message locale' {
        $marker = Join-Path $script:StandInDir 'marker'
        $name = 'vm "q"; $(touch ' + $marker + ') `x` -h'
        $result = Send-ClickKvm -VMName $name -X 640 -Y 400 -Capture @{ ImagePath = 'x.png'; Width = 1280; Height = 800 }
        Assert-True ($result -is [bool] -and $result) 'the stand-in acknowledged every call'
        $calls = Get-StandInCall
        Assert-Equal 4 $calls.Count
        foreach ($call in $calls) {
            Assert-Equal 5 $call.Count
            Assert-True ($call[3] -ceq $name) "the VM name arrived as '$($call[3])'"
            $parsed = $call[4] | ConvertFrom-Json
            Assert-StringEqual 'input-send-event' $parsed.execute
        }
        Assert-False (Test-Path -LiteralPath $marker) 'the VM name reached a shell'
        $environment = [IO.File]::ReadAllLines($script:StandInEnv)
        Assert-True ($environment -ccontains 'LC_MESSAGES=C') "env was $($environment -join ' | ')"
        Assert-True ($environment -ccontains 'LC_ALL=') "env was $($environment -join ' | ')"
    }

    It 'releases the button when the pipeline is stopped during the press' {
        Set-Content -LiteralPath $script:StandInSlow -Value '' -NoNewline -Encoding ascii
        $common = Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1'
        $transport = Join-Path $PSScriptRoot 'Test.Transport.psm1'
        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript(@"
Import-Module '$common' -Global -Force -DisableNameChecking
Import-Module '$transport' -Force -DisableNameChecking
Send-ClickKvm -VMName 'vm' -X 1 -Y 1 -Capture @{ Width = 1280; Height = 800 }
"@)
            $null = $ps.BeginInvoke()
            $names = {
                $recorded = Get-StandInCall
                # A call the stand-in is still writing has fewer than five lines.
                @(foreach ($call in @($recorded | Where-Object { $_.Count -ge 5 })) {
                    $events = [string]$call[4]
                    if ($events.Contains('"down":true')) { 'press' }
                    elseif ($events.Contains('"down":false')) { 'release' }
                    elseif ($events.Contains('{"axis":"x","value":32767}')) { 'park' }
                    else { 'move' }
                })
            }
            $until = [DateTime]::UtcNow.AddSeconds(30)
            while (-not ((& $names) -ccontains 'press') -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
            Assert-True ((& $names) -ccontains 'press') 'the press never reached the stand-in'
            $ps.Stop()
            $until = [DateTime]::UtcNow.AddSeconds(30)
            while (@(& $names).Count -lt 3 -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
            Assert-StringEqual 'move,press,release' ((& $names) -join ',')
            # The stopped bounded call does not kill the press child; wait until
            # it has ended (its last act, or the cap's kill) so no process
            # outlives the case.
            $until = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Test-Path -LiteralPath $script:StandInDone) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
        } finally {
            $ps.Dispose()
        }
    }
}

Describe 'KVM click provider registration' {
    BeforeAll {
        $script:ForwardedClick = @{}
    }

    It 'registers Send-Click for host.ubuntu.kvm' {
        Assert-True (Test-HostIOActionAvailable -HostType 'host.ubuntu.kvm' -Action 'Send-Click')
    }

    It 'forwards every argument to the transport' {
        Mock Send-ClickKvm -ModuleName Test.HostIO.Kvm {
            $script:ForwardedClick.Bound = @{ VMName = $VMName; X = $X; Y = $Y; Capture = $Capture; Click = $Click }
            return $true
        }
        $provider = (Get-Variable -Name 'YurunaHostIOProviders' -Scope Global -ValueOnly)['host.ubuntu.kvm']['Send-Click']
        $capture = @{ Width = 1280; Height = 800 }
        $result = & $provider @{ VMName = 'vm'; X = 3; Y = 4; Capture = $capture; Click = 'double' }
        Assert-True ($result -is [bool] -and $result) 'the provider returns what the transport returned'
        $bound = $script:ForwardedClick.Bound
        Assert-StringEqual 'vm' $bound.VMName
        Assert-Equal 3 $bound.X
        Assert-Equal 4 $bound.Y
        Assert-True ([object]::ReferenceEquals($capture, $bound.Capture)) 'the capture was forwarded as given'
        Assert-True ($bound.Click -ceq 'double') "Click was $($bound.Click)"
        $null = & $provider @{ VMName = 'vm'; X = 3; Y = 4; Capture = $capture }
        Assert-True ($script:ForwardedClick.Bound.Click -is [string] -and $script:ForwardedClick.Bound.Click -ceq '') 'a table without Click binds an empty string'
    }
}
