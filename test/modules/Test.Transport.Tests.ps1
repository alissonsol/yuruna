<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42869a92-a8d2-410d-9364-cdfba1a4ed8e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test transport vnc pester
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
    Pester coverage for Read-VncBuffer in Test.Transport.psm1: the fixed-size
    RFB read honors an optional wall-clock deadline that bounds the whole
    multi-read handshake, independent of the per-read socket ReceiveTimeout.
.DESCRIPTION
    Read-VncBuffer is pure over a System.IO.Stream, so a MemoryStream drives it
    with no socket. Throw-based assertions, with the Assert-* helpers in the
    file's BeforeAll so they are visible to the It blocks under Pester 5.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Transport.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking


function Get-TransportAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modulePath): $($errs[0].Message)" }
    return $ast
}
function Get-TransportFunctionText {
    param([string]$Name)
    $fn = @((Get-TransportAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true))
    if ($fn.Count -eq 0) { throw "Function '$Name' not found in Test.Transport.psm1" }
    return $fn[0].Extent.Text
}

# --- REGION: Held-key release on an interrupted VNC send
# Shadows the module-internal transport primitives inside Test.Transport's own
# session state, so the press/release stream is observable with no socket. This
# has to sit in the same scope as the Import-Module above: the shadowing runs
# against the imported module object, which no other scope can resolve.
$script:TransportModule = Get-Module Test.Transport
& $script:TransportModule {
    function script:Connect-VNC {
        # The unused parameters are the point: the code under test binds these
        # by name, so the stub has to accept the same signature as the real
        # primitive. It hands back a sentinel instead of opening a socket.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Shadow stub; the signature must match the real Connect-VNC for the caller to bind, and there is nothing to connect to.')]
        param($VMName, $Port)
        [pscustomobject]@{ Fake = $true }
    }
    function script:Disconnect-VNC { $script:disconnected = $true }
    function script:Send-VncKeyEvent {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Shadow stub; $Client is the connection handle the real primitive writes to, and this one records the press/release stream instead.')]
        param($Client, $KeySym, $Down)
        $script:n++
        if ($script:failAt -gt 0 -and $script:n -eq $script:failAt) {
            throw [System.IO.IOException]::new('injected mid-send failure')
        }
        [void]$script:rec.Add([pscustomobject]@{ Sym = [int]$KeySym; Down = [bool]$Down })
    }
}
function Reset-KeyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clears three in-memory recording variables inside the test module scope; nothing outside this file is touched and -WhatIf on a fixture reset is meaningless.')]
    param([int]$FailAt = 0)
    & $script:TransportModule { param($f)
        $script:rec = [System.Collections.ArrayList]::new()
        $script:n = 0; $script:failAt = $f; $script:disconnected = $false } $FailAt
}
# Any keysym with more presses than releases is a key still down in the guest,
# which the guest kernel auto-repeats at the console default until the VM dies.
function Get-HeldKeySym {
    $rec = & $script:TransportModule { , $script:rec.ToArray() }
    $tally = @{}
    foreach ($e in $rec) { $tally[$e.Sym] = ($tally[$e.Sym] ?? 0) + ($e.Down ? 1 : -1) }
    return @($tally.GetEnumerator() | Where-Object { $_.Value -ne 0 } | ForEach-Object { $_.Key })
}
}

Describe 'Read-VncBuffer wall-clock deadline' {

    It 'reads exactly Count bytes (no deadline supplied = backward compatible)' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        $buf = Read-VncBuffer -Stream $s -Count 12
        Assert-True ($buf.Length -eq 12) 'returns the requested count'
        Assert-True ($buf[0] -eq 1 -and $buf[11] -eq 12) 'returns the actual bytes'
    }

    It 'returns the bytes when the deadline is in the future' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..4))
        $buf = Read-VncBuffer -Stream $s -Count 4 -Deadline ([DateTime]::UtcNow.AddSeconds(30))
        Assert-True ($buf.Length -eq 4) 'a comfortable deadline does not interfere'
    }

    It 'throws once the wall-clock deadline has passed' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(-1)) } 'deadline' -Because 'a past deadline must throw before/at the first read'
    }

    It 'throws when the stream closes before Count bytes arrive' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..5))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(30)) } 'closed' -Because 'a short stream (EOF) must throw the connection-closed error'
    }
}

# --- REGION: Control-chord plumbing
# The chord path cannot be exercised against a real guest here (it needs a VM,
# a VNC server or a raised UTM window), so these guard the two failure modes
# that are silent at runtime: a chord name falling through to the "unknown
# key" branch, and a multi-key chord being flattened into a single keypress.
# A flattened Ctrl-U types a bare 'u' into the guest instead of killing the
# line, which looks like success at every layer.


Describe 'Control-chord support across the Send-Key backends' {

    It 'rejects a chord name the UTM chord table does not define' {
        # Pure: the lookup fails before any window is raised or osascript runs.
        Assert-True ((Send-ChordUTM -VMName 'nosuchvm' -KeyName 'CtrlNope' -WarningAction SilentlyContinue) -eq $false) `
            'an unknown chord must report failure, not warn-and-return-true'
    }

    It 'routes a chord name out of the AppleScript key path on UTM' {
        # `key code` cannot hold a modifier across the base key, so a chord
        # must leave Send-KeyUTM for the CGEvent path.
        $text = Get-TransportFunctionText -Name 'Send-KeyUTM'
        Assert-True ($text -match 'UtmChords') 'Send-KeyUTM must consult the chord table'
        Assert-True ($text -match 'Send-ChordUTM') 'Send-KeyUTM must delegate chords to Send-ChordUTM'
    }

    It 'consults the chord table before the scalar named table on every backend' {
        # The named maps hold one code per name and do not contain chord
        # names, so a backend that checks only the named map reports
        # "Unknown key 'CtrlU'" and sends nothing.
        foreach ($pair in @(
            @{ fn = 'Send-KeyVNC';    map = 'X11Chords' }
            @{ fn = 'Send-KeyHyperV'; map = 'Ps2Chords' }
        )) {
            $text = Get-TransportFunctionText -Name $pair.fn
            Assert-True ($text -match $pair.map) "$($pair.fn) must consult $($pair.map)"
        }
        $kvm = Get-TransportFunctionText -Name 'Send-KeyKvm'
        Assert-True ($kvm -match "KVM-Chord") 'Send-KeyKvm must consult the KVM-Chord map'
    }

    It 'splats the KVM chord so both keycodes reach virsh' {
        # `virsh send-key <domain> KEY_LEFTCTRL KEY_U` needs two POSITIONAL
        # arguments. Passing the array as one argument sends a single
        # unrecognized token, and passing only its first element sends a
        # lone Ctrl -- both look like a successful call.
        $text = Get-TransportFunctionText -Name 'Send-KeyKvm'
        Assert-True ($text -match '@codes') 'the chord array must be splatted onto virsh send-key'
    }

    It 'releases the modifier after the base key on the Hyper-V chord' {
        # The PS/2 controller tracks "is down" per code, so the modifier's
        # break must come last or Ctrl stays latched into the next keystroke.
        $text = Get-TransportFunctionText -Name 'Send-KeyHyperV'
        Assert-True ($text -match '(?s)\$modMake,\s*\r?\n\s*\$baseMake,\s*\r?\n\s*\[byte\]\(\$baseMake -bor 0x80\),\s*\r?\n\s*\[byte\]\(\$modMake -bor 0x80\)') `
            'chord order must be modifier make, base make, base break, modifier break'
    }

    It 'sets the control flag on the CGEvent chord and clears it on release' {
        # The flagged events are what make the guest see Ctrl held; the
        # release is posted UNFLAGGED so the HID-system source clears the
        # modifier for the next key.
        $text = Get-TransportFunctionText -Name 'Send-ChordUTM'
        Assert-True ($text -match 'CGEventSetFlags\(modDn, modFlag\)') 'the modifier press must carry the flag'
        Assert-True ($text -match 'CGEventSetFlags\(down, modFlag\)')  'the base press must carry the flag'
        Assert-True ($text -match '(?s)var modUp = \$\.CGEventCreateKeyboardEvent\(src, modKeyCode, false\);\s*\r?\n\s*\$\.CGEventPost\(0, modUp\);') `
            'the modifier release must be posted without a flag'
    }
}


Describe 'VNC sends never leave a key held in the guest' {

    It 'pairs every press with a release on a clean text send' {
        Reset-KeyRecording
        Assert-True ((Send-TextVNC -VMName 'vm' -Text 'aB c' -CharDelayMs 0) -eq $true) 'clean send must report success'
        Assert-True ((Get-HeldKeySym).Count -eq 0) "clean send left keys held: $(Get-HeldKeySym)"
    }

    It 'releases the character key when the send dies between its press and release' {
        # 'ab' unshifted emits down(a) up(a) down(b) up(b); failing the 4th
        # write is the exact shape seen in production -- the press landed in
        # the guest, the release never did, and 'b' auto-repeated forever.
        Reset-KeyRecording -FailAt 4
        Assert-True ((Send-TextVNC -VMName 'vm' -Text 'ab' -CharDelayMs 0 -WarningAction SilentlyContinue) -eq $false) `
            'an interrupted send must report failure'
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted send left keys held: $(Get-HeldKeySym)"
    }

    It 'releases Shift too when the send dies inside a shifted character' {
        # 'A' emits down(Shift) down(a) up(a) up(Shift); fail the 3rd write.
        Reset-KeyRecording -FailAt 3
        Send-TextVNC -VMName 'vm' -Text 'A' -CharDelayMs 0 -WarningAction SilentlyContinue | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "shifted interrupt left keys held: $(Get-HeldKeySym)"
    }

    It 'releases the key when a single Send-KeyVNC dies mid-pair' {
        # This is the path that sends Enter after every typed command.
        Reset-KeyRecording -FailAt 2
        Send-KeyVNC -VMName 'vm' -KeyName 'Enter' -WarningAction SilentlyContinue | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted Enter left keys held: $(Get-HeldKeySym)"
    }

    It 'releases both halves when a chord dies between the base press and release' {
        # CtrlU emits down(Ctrl) down(u) up(u) up(Ctrl); fail the 3rd write.
        Reset-KeyRecording -FailAt 3
        Send-KeyVNC -VMName 'vm' -KeyName 'CtrlU' -WarningAction SilentlyContinue | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted chord left keys held: $(Get-HeldKeySym)"
    }
}

Describe 'Hyper-V keyboard cache invalidation' {
    # Hyper-V re-creates a VM's Msvm_Keyboard association across a guest
    # reboot while the VM name stays the same, so the cache key cannot detect
    # a handle that has gone stale. A failed delivery is the only evidence,
    # and a cache that survives one turns a single stale handle into every
    # later keystroke failing identically -- which no retry above can undo,
    # because each attempt is handed the same dead instance.
    #
    # Invoke-CimMethod is a Windows-only cmdlet, so there is nothing for Mock
    # to intercept on the host this suite usually runs on. Set-Item into
    # function:script: inside the module's own session state shadows the cmdlet
    # by name-resolution order, which drives the same branches on either
    # platform; AfterEach removes it so nothing else in the run inherits the
    # shadow.
    AfterEach {
        InModuleScope 'Test.Transport' {
            Remove-Item -LiteralPath 'function:script:Invoke-CimMethod' -ErrorAction SilentlyContinue
        }
    }

    It 'drops the cached handle when the send throws' {
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { throw 'stale handle' }
            $threw = $false
            try { Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C)) | Out-Null } catch { $threw = $true }
            @{ Threw = $threw; Cached = $script:CachedKb }
        }
        Assert-True $r.Threw 'a WMI error must still surface to the caller'
        Assert-True ($null -eq $r.Cached) `
            'a throwing send must leave no cached handle for the next attempt to reuse'
    }

    It 'drops the cached handle when the send reports a non-zero ReturnValue' {
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { @{ ReturnValue = 32768 } }
            $ok = Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C))
            @{ Ok = $ok; Cached = $script:CachedKb }
        }
        Assert-True (-not $r.Ok) 'a non-zero ReturnValue is a failed delivery'
        Assert-True ($null -eq $r.Cached) `
            'a rejected send must invalidate the handle too, not only a throw'
    }

    It 'keeps the cached handle when the send succeeds' {
        # The cache exists to spare a WMI lookup per keystroke; clearing it on
        # the happy path would give that back on every send.
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { @{ ReturnValue = 0 } }
            $ok = Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C))
            @{ Ok = $ok; Cached = $script:CachedKb }
        }
        Assert-True $r.Ok 'ReturnValue 0 is success'
        Assert-True ($null -ne $r.Cached) `
            'a successful send must not cost the next one a re-resolve'
    }
}

Describe 'Send-ScanCode reports why the synthetic keyboard refused' {

    It 'names the Msvm_Keyboard refusals a Hyper-V host actually hits' {
        # Both codes reach the same $false, and the repairs differ: 32769 is
        # the harness running unelevated, and 32775 is a handle addressing no
        # live keyboard -- which the re-resolve fixes when it is a stale
        # instance and cannot fix when the guest has no VMBus keyboard driver
        # at all. A bare "pressKey returned false" in the transcript cannot
        # tell an operator which one to go fix.
        $text = Get-TransportFunctionText -Name 'Send-ScanCode'
        Assert-True ($text -match '32769') 'the access-denied code must be named'
        Assert-True ($text -match '32775') 'the invalid-state code must be named'
        Assert-True ($text -match 'Write-Warning') 'a non-zero ReturnValue must reach the transcript'
        Assert-True ($text -match '\$r\.ReturnValue -ne 0') 'the warning must be gated on the failure path only'
    }

    It 'warns before it drops the handle, so both repairs stay visible' {
        # The clear is silent on its own. Warning first is what leaves the
        # reason in the cycle log when the re-resolve does not help, which is
        # exactly the guest-has-no-driver case.
        $text = Get-TransportFunctionText -Name 'Send-ScanCode'
        Assert-True ($text -match '(?s)Write-Warning[^\r\n]*\r?\n\s*Clear-HyperVKeyboard') `
            'the warning must precede the cache clear on the rejected-send path'
    }
}


Describe 'Send-TextHyperV honors the batched/per-char text-send shape' {

    BeforeEach {
        & $script:TransportModule {
            $script:scanSends = [System.Collections.ArrayList]::new()
            function script:Get-HyperVKeyboard {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; the caller binds -VMName and there is no WMI keyboard to resolve here.')]
                param($VMName)
                [pscustomobject]@{ Fake = $true }
            }
            function script:Send-ScanCode {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; $Keyboard is the WMI instance the real primitive invokes against, and this one records the codes instead.')]
                param($Keyboard, [byte[]]$Codes)
                [void]$script:scanSends.Add([byte[]]$Codes)
                return $true
            }
        }
    }

    It 'sends one call per character and no reset prefix when batching is off' {
        # An ARM64 Hyper-V guest receives NONE of a batched payload, so the
        # per-char shape is the only one that arrives there -- and the
        # modifier-reset prefix must not lead it, because every character sent
        # after that prefix is swallowed too. Count the calls, not the codes:
        # the character codes are identical either way, and the call boundary
        # is the whole difference.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $false }
        Assert-True ((Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0) -eq $true) 'per-char send must report success'
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 3 -Actual $sends.Count -Because 'one call per character, with no reset prefix ahead of them'
    }

    It 'still leads a batched send with the modifier-reset prefix' {
        # The prefix is what keeps a latched Shift from upshifting a whole
        # batched password, so dropping it everywhere would trade one host's
        # bug for another's.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $true }
        Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 0xAA -Actual ([int]$sends[0][0]) -Because 'the batched send opens with the LShift break'
    }

    It 'keeps a shifted character and its Shift pair in the same call' {
        # Splitting them would leave Shift held across the pacing sleep and
        # upshift whatever the guest read next.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $false }
        Send-TextHyperV -VMName 'vm' -Text 'A' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        $charCall = $sends[-1]
        Assert-Equal -Expected 0x2A -Actual ([int]$charCall[0]) -Because 'the shift make leads the character call'
        Assert-Equal -Expected 0xAA -Actual ([int]$charCall[-1]) -Because 'the shift break closes the same call'
    }

    It 'still emits the whole payload in one call when batching is on' {
        & $script:TransportModule { $script:DefaultBatchedTextSend = $true }
        Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 2 -Actual $sends.Count -Because 'reset prefix + one batch'
    }

    It 'defaults to per-char on an ARM64 Windows host and batched elsewhere' {
        # The default is computed at module load from the HOST architecture,
        # not from the guest, because the drop is in the synthetic keyboard.
        $text = Get-Content -Raw $modulePath
        Assert-True ($text -match 'DefaultBatchedTextSend\s*=\s*\r?\n?\s*-not \(\$IsWindows -and') `
            'the default must be negated only for a Windows ARM64 host'
        Assert-True ($text -match '\$comm\.batchedTextSend') 'vmCommunication.batchedTextSend must override the default'
    }
}
