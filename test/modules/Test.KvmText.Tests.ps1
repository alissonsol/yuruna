<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42029610-1d57-467e-bf3b-f8b731e657c1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm transport
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -DisableNameChecking
    $script:Python = (Get-Command python3 -ErrorAction SilentlyContinue).Source
    if (Test-Path -LiteralPath '/usr/bin/python3') { $script:Python = '/usr/bin/python3' }
    if ($script:Python -like '*WindowsApps*') { $script:Python = $null }
    if ($script:Python) {
        $ready = Invoke-BoundedNativeCommand -FilePath $script:Python -ArgumentList @('-I', '-c', 'import sys; assert sys.version_info >= (3, 6)') -TimeoutSeconds 3
        if (-not (Test-BoundedNativeResultComplete -Result $ready) -or $ready.ExitCode -ne 0) { $script:Python = $null }
    }
    $script:Helper = Join-Path $PSScriptRoot 'Test.KvmText.py'
    function Invoke-KvmPythonTest {
        param([string]$Body, [int]$TimeoutSeconds = 10)
        $prefix = @'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location('kvm_text', sys.argv[1])
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
class FakeDomain:
    def __init__(self, fail_at=0):
        self.calls = []
        self.fail_at = fail_at
    def sendKey(self, *arguments):
        self.calls.append(arguments)
        if len(self.calls) == self.fail_at:
            raise RuntimeError('injected key failure')
class FakeConnection:
    def __init__(self, domain):
        self.domain = domain
        self.names = []
        self.closed = False
    def lookupByName(self, name):
        self.names.append(name)
        return self.domain
    def close(self):
        self.closed = True
class FakeLibvirt:
    VIR_KEYCODE_SET_LINUX = 0
    def __init__(self, connection):
        self.connection = connection
        self.uris = []
    def open(self, uri):
        self.uris.append(uri)
        return self.connection
request = {'vmName': 'test', 'chords': [[30], [42, 30], [28]], 'charDelayMs': 10}
domain = FakeDomain()
connection = FakeConnection(domain)
library = FakeLibvirt(connection)
'@
        Invoke-BoundedNativeCommand -FilePath $script:Python -ArgumentList @('-I', '-B', '-c', ($prefix + "`n" + $Body), $script:Helper) -TimeoutSeconds $TimeoutSeconds
    }
}

Describe 'KVM text request and fallback contracts' {
    InModuleScope Test.Transport {
        BeforeEach {
            $script:KvmTextRequestPath = $null
            $script:KvmTextRequest = $null
            $script:KvmTextArguments = $null
            $script:KvmTextTimeout = $null
            $script:KvmTextProbeOverride = $null
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq '/usr/bin/python3' }
            Mock Send-TextKvmLegacy { $true }
            Mock Invoke-BoundedNativeCommand {
                $script:KvmTextRequestPath = $ArgumentList[-1]
                $script:KvmTextRequest = Get-Content -LiteralPath $script:KvmTextRequestPath -Raw | ConvertFrom-Json -AsHashtable
                $script:KvmTextArguments = @($ArgumentList)
                $script:KvmTextTimeout = $TimeoutSeconds
                $script:KvmTextRequestMode = if (-not $IsWindows) { [int][IO.File]::GetUnixFileMode($script:KvmTextRequestPath) }
                if ($script:KvmTextProbeOverride) { return $script:KvmTextProbeOverride }
                @{ Started = $true; ExitCode = 0; StdOut = (@{ status = 'ok'; sent = $script:KvmTextRequest.chords.Count } | ConvertTo-Json -Compress); StdErr = '' }
            }
        }

        It 'preserves zero, one and multiple chord collection shapes' -Skip:$IsWindows {
            Send-TextKvm -VMName 'vm' -Text '' | Should -BeTrue
            Should -Invoke Invoke-BoundedNativeCommand -Times 0
            Send-TextKvm -VMName 'vm' -Text 'a' | Should -BeTrue
            $script:KvmTextRequest.chords.Count | Should -Be 1
            $script:KvmTextRequest.chords[0].Count | Should -Be 1
            $script:KvmTextRequest.chords[0][0] | Should -Be 30
            Send-TextKvm -VMName 'vm' -Text "A+`t`n`r" | Should -BeTrue
            ($script:KvmTextRequest.chords | ConvertTo-Json -Compress) | Should -Be '[[42,30],[42,13],[15],[28],[28]]'
        }

        It 'keeps literal VM names and credentials out of process arguments' -Skip:$IsWindows {
            $name = 'vm "quoted"; $(touch /tmp/never) `literal`'
            Send-TextKvm -VMName $name -Text 'secret-token' | Should -BeTrue
            $script:KvmTextRequest.vmName | Should -BeExactly $name
            ($script:KvmTextArguments -join ' ') | Should -Not -Match 'secret-token|quoted|touch'
            $script:KvmTextArguments[0] | Should -Be '-I'
            $script:KvmTextRequestMode | Should -Be 384
            Test-Path -LiteralPath $script:KvmTextRequestPath | Should -BeFalse
        }

        It 'budgets effective pacing including the queue safety floor and saturates large inputs' -Skip:$IsWindows {
            Send-TextKvm -VMName 'vm' -Text 'abc' -CharDelayMs 2000 | Should -BeTrue
            $script:KvmTextTimeout | Should -Be 21
            $script:KvmTextRequest.charDelayMs | Should -Be 2000
            Send-TextKvm -VMName 'vm' -Text 'abc' -CharDelayMs -1 | Should -BeTrue
            $script:KvmTextTimeout | Should -Be 16
            $script:KvmTextRequest.charDelayMs | Should -Be 0
            Send-TextKvm -VMName 'vm' -Text ('a' * 2000) -CharDelayMs 0 | Should -BeTrue
            $script:KvmTextTimeout | Should -Be 35
            Send-TextKvm -VMName 'vm' -Text 'abcd' -CharDelayMs ([int]::MaxValue) | Should -BeTrue
            $script:KvmTextTimeout | Should -Be 2147483
            $script:KvmTextRequest.charDelayMs | Should -Be ([int]::MaxValue)
        }

        It 'skips unsupported Unicode with one warning and preserves mapped characters' -Skip:$IsWindows {
            Send-TextKvm -VMName 'vm' -Text ('a' + [char]0x4F60 + 'B') -WarningVariable warnings -WarningAction SilentlyContinue | Should -BeTrue
            @($warnings).Count | Should -Be 1
            ($script:KvmTextRequest.chords | ConvertTo-Json -Compress) | Should -Be '[[30],[42,48]]'
        }

        It 'falls back before launch when the system interpreter is absent' {
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -eq '/usr/bin/python3' }
            Send-TextKvm -VMName 'vm' -Text 'abc' | Should -BeTrue
            Should -Invoke Invoke-BoundedNativeCommand -Times 0
            Should -Invoke Send-TextKvmLegacy -Times 1 -ParameterFilter { $Text -eq 'abc' }
        }

        It 'falls back only on a complete missing-binding response before any key' -Skip:$IsWindows {
            $script:KvmTextProbeOverride = @{ Started = $true; ExitCode = 78; StdOut = '{"status":"unavailable","sent":0}' }
            Send-TextKvm -VMName 'vm' -Text 'abc' | Should -BeTrue
            Should -Invoke Send-TextKvmLegacy -Times 1
            Test-Path -LiteralPath $script:KvmTextRequestPath | Should -BeFalse
        }

        It 'never replays an incomplete native send: <Flag>' -ForEach @(
            @{ Flag = 'TimedOut' }, @{ Flag = 'DrainTimedOut' }, @{ Flag = 'OutputTruncated' }, @{ Flag = 'KillFailed' }
        ) -Skip:$IsWindows {
            $script:KvmTextProbeOverride = @{ Started = $true; ExitCode = 78; StdOut = '{"status":"unavailable","sent":0}'; $Flag = $true }
            Send-TextKvm -VMName 'vm' -Text 'abc' -WarningAction SilentlyContinue | Should -BeFalse
            Should -Invoke Send-TextKvmLegacy -Times 0
            Test-Path -LiteralPath $script:KvmTextRequestPath | Should -BeFalse
            $result = Invoke-KvmTextBurst -VMName 'vm' -Chords (,([int[]]@(30))) -CharDelayMs 0
            $result.UnknownDelivery | Should -BeTrue
            $result.Error | Should -Match 'delivery extent is unknown'
        }

        It 'never replays runtime, partial or malformed responses: <Name>' -ForEach @(
            @{ Name = 'domain lookup failure'; Code = 1; Json = '{"status":"failed","sent":0,"error":"not found"}' }
            @{ Name = 'partial key failure'; Code = 1; Json = '{"status":"failed","sent":1,"error":"key failure"}' }
            @{ Name = 'unknown launch failure'; Code = -1; Json = '' }
            @{ Name = 'malformed JSON'; Code = 0; Json = 'invalid' }
            @{ Name = 'false success count'; Code = 0; Json = '{"status":"ok","sent":1}' }
            @{ Name = 'nonzero success exit'; Code = 1; Json = '{"status":"ok","sent":3}' }
            @{ Name = 'invalid unavailable exit'; Code = 0; Json = '{"status":"unavailable","sent":0}' }
            @{ Name = 'partial unavailable'; Code = 78; Json = '{"status":"unavailable","sent":1}' }
            @{ Name = 'invalid unavailable count'; Code = 78; Json = '{"status":"unavailable","sent":false}' }
            @{ Name = 'string unavailable count'; Code = 78; Json = '{"status":"unavailable","sent":"0"}' }
            @{ Name = 'fractional unavailable count'; Code = 78; Json = '{"status":"unavailable","sent":0.0}' }
            @{ Name = 'array unavailable status'; Code = 78; Json = '{"status":["unavailable"],"sent":0}' }
            @{ Name = 'missing count'; Code = 0; Json = '{"status":"ok"}' }
        ) -Skip:$IsWindows {
            $script:KvmTextProbeOverride = @{ Started = ($Code -ne -1); ExitCode = $Code; StdOut = $Json }
            Send-TextKvm -VMName 'vm' -Text 'abc' -WarningAction SilentlyContinue | Should -BeFalse
            Should -Invoke Send-TextKvmLegacy -Times 0
        }

        It 'matches every existing KVM symbolic chord against Linux input-event codes' -Skip:($IsWindows -or -not (Test-Path -LiteralPath '/usr/include/linux/input-event-codes.h')) {
            $codes = @{}
            foreach ($line in Get-Content -LiteralPath '/usr/include/linux/input-event-codes.h') {
                if ($line -match '^#define\s+(KEY_\w+)\s+(0x[\da-fA-F]+|\d+)\b') { $codes[$Matches[1]] = [int]$Matches[2] }
            }
            $map = Get-KeyCodeMap -Kind 'KVM-Char'
            foreach ($character in $map.Keys) {
                Send-TextKvm -VMName 'vm' -Text $character | Should -BeTrue
                $expected = @($map[$character] | ForEach-Object { $codes[$_] })
                ($script:KvmTextRequest.chords[0] -join ',') | Should -Be ($expected -join ',')
            }
            $map.Count | Should -Be 98
        }
    }
}

Describe 'KVM Python libvirt execution semantics' {
    It 'preserves simultaneous chords with safe pulses and requested <Delay> ms pacing' -ForEach @(@{ Delay = 0 }, @{ Delay = 10 }, @{ Delay = 25 }) {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest (('request["charDelayMs"] = ' + $Delay + "`n") + @'
pauses = []
result = helper.send(request, library, pauses.append)
assert result == {'status':'ok','sent':3}, result
assert domain.calls == [(0,1,[30],1,0),(0,1,[42,30],2,0),(0,1,[28],1,0)], domain.calls
assert pauses == [max(request['charDelayMs'],10)/1000.0]*3, pauses
assert library.uris == ['qemu:///system']
assert connection.closed
'@)
        $result.ExitCode | Should -Be 0
    }

    It 'stops at the first failed RPC and closes the connection without replay' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest @'
domain.fail_at = 2
pauses = []
result = helper.send(request, library, pauses.append)
assert result['status'] == 'failed' and result['sent'] == 1, result
assert len(domain.calls) == 2
assert pauses == [.01]
assert connection.closed
'@
        $result.ExitCode | Should -Be 0
    }

    It 'prevents the QEMU delayed input queue overflow that loses modifier releases' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest @'
class InputQueue:
    def __init__(self):
        self.queue = []
        self.dropped = []
        self.held = set()
        self.peak_entries = 0
    def deliver(self, key, down):
        if down:
            self.held.add(key)
        else:
            self.held.discard(key)
    def sendKey(self, _codeset, hold, chord, _length, _flags):
        # QEMU admits EVENT+SYNC below1024 entries, then separately admits
        # DELAY below1024. The paired admission can overshoot by one entry.
        events = [(key,True) for key in chord] + [(key,False) for key in reversed(chord)]
        for key,down in events:
            if not self.queue:
                self.deliver(key,down)
            elif len(self.queue) < 1024:
                self.queue.extend([['event',(key,down)],['sync',None]])
            else:
                self.dropped.append((key,down))
            if len(self.queue) < 1024:
                self.queue.append(['delay',hold or 10])
            self.peak_entries = max(self.peak_entries,len(self.queue))
    def advance(self, seconds):
        remaining = seconds * 1000
        while self.queue:
            kind,value = self.queue[0]
            if kind == 'delay':
                if remaining < value:
                    self.queue[0][1] -= remaining
                    break
                remaining -= value
            elif kind == 'event':
                self.deliver(*value)
            self.queue.pop(0)
old = InputQueue()
for _ in range(1000):
    old.sendKey(0,0,[42,30],2,0)
    old.advance(.01)
assert (42,False) in old.dropped, 'zero-hold defaults must reproduce lost Shift releases'
assert old.peak_entries <= 1025, old.peak_entries
for delay in (0,1,10):
    queue = InputQueue()
    request['charDelayMs'] = delay
    request['chords'] = [[42,30]] * 1000
    connection.domain = queue
    result = helper.send(request,library,queue.advance)
    assert result == {'status':'ok','sent':1000}, result
    assert queue.dropped == [] and queue.queue == [] and queue.held == set(), (delay,queue.dropped)
'@
        $result.ExitCode | Should -Be 0
    }

    It 'passes unusual VM names literally to lookupByName' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest @'
request['vmName'] = 'vm "quotes"; $(never-run) `literal` \\ Unicode-' + chr(0x4f60)
result = helper.send(request, library, lambda _:None)
assert result['status'] == 'ok', result
assert connection.names == [request['vmName']]
'@
        $result.ExitCode | Should -Be 0
    }

    It 'validates the complete request before sending any key' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest @'
request['chords'].append([True])
result = helper.send(request, library)
assert result['status'] == 'failed' and result['sent'] == 0, result
assert library.uris == [] and domain.calls == []
'@
        $result.ExitCode | Should -Be 0
    }

    It 'distinguishes binding ImportError before send from runtime ImportError' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest @'
import builtins, contextlib, io, pathlib, tempfile
original_import = builtins.__import__
def missing(name,*args,**kwargs):
    if name == 'libvirt': raise ImportError('missing test binding')
    return original_import(name,*args,**kwargs)
with tempfile.TemporaryDirectory() as directory:
    source = pathlib.Path(directory) / 'request.json'
    source.write_text(json.dumps(request),encoding='utf-8')
    sys.argv = ['helper',str(source)]
    capture = io.StringIO()
    builtins.__import__ = missing
    try:
        with contextlib.redirect_stdout(capture): code = helper.main()
    finally: builtins.__import__ = original_import
    assert code == 78 and json.loads(capture.getvalue()) == {'status':'unavailable','sent':0}
def runtime_error(_): raise ImportError('runtime failure after binding load')
library.open = runtime_error
result = helper.send(request,library)
assert result['status'] == 'failed' and result['sent'] == 0, result
'@
        $result.ExitCode | Should -Be 0
    }

    It 'terminates a helper blocked in a key RPC within the native cap' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python is unavailable.'; return }
        $result = Invoke-KvmPythonTest -TimeoutSeconds 2 @'
import time
domain.sendKey = lambda *args: time.sleep(30)
helper.send(request,library)
'@
        $result.TimedOut | Should -BeTrue
        $result.ElapsedMs | Should -BeLessThan 4000
        $result.KillFailed | Should -BeFalse
        Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
