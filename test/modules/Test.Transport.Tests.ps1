<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42c1a7e9-5b62-4d38-9a04-7e2f1c6b8d90
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
    with no socket. Throw-based assertions; run under Pester 4.10.1 (the top-level
    Assert-* helpers are not visible in It blocks under Pester 5's scope split).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Transport.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Throw {
    param([scriptblock]$Script, [string]$Match = '', [string]$Because = '')
    $threw = $false
    try { & $Script } catch {
        $threw = $true
        if ($Match -and ($_.Exception.Message -notmatch $Match)) {
            throw "Threw, but message '$($_.Exception.Message)' did not match '$Match'. $Because"
        }
    }
    if (-not $threw) { throw "Expected a throw. $Because" }
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

# --- REGION: control-chord plumbing -------------------------------------------
# The chord path cannot be exercised against a real guest here (it needs a VM,
# a VNC server or a raised UTM window), so these guard the two failure modes
# that are silent at runtime: a chord name falling through to the "unknown
# key" branch, and a multi-key chord being flattened into a single keypress.
# A flattened Ctrl-U types a bare 'u' into the guest instead of killing the
# line, which looks like success at every layer.

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

# --- Held-key release on an interrupted VNC send -----------------------------
# Shadows the module-internal transport primitives inside Test.Transport's own
# session state, so the press/release stream is observable with no socket. Kept
# after the Describes above, none of which touch these three functions.
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
