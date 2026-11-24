<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42798304-85e4-4102-8026-ce168ff64fd3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service route host-operation body-reader pester
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
    The status listener's route helpers and the generated routes that use
    them: bounded body reads, the repair body schema, the reply table, the
    capability summary, worker argument vectors, the diagnostic decision, the
    private worker directory, and the served-tree deny-lists.
.DESCRIPTION
    The listener handles one request at a time, so these decisions have to be
    cheap, deterministic and fail closed: a body that never finishes must not
    park the loop, a body that names a local-only safety switch must be
    refused whatever its spelling, an admission record must map to exactly one
    documented reply, and a worker vector must bind against the script it
    launches before anything is started.

    Reads use real loopback sockets for pending and trickled bodies, and a
    controlled failing stream for I/O errors. Worker-directory cases run in a child process with a
    scratch HOME, because $HOME cannot be rebound in this one. The generated
    server is expanded from the launcher exactly as the launcher expands it.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.StatusControlRoute.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:RuntimePath = Join-Path $script:RepoRoot 'test/service/Invoke-StatusServiceRuntime.ps1'

# The status service runtime the launcher runs.
$script:ServerText = [IO.File]::ReadAllText($script:RuntimePath)
$parseErrors = $null
$script:ServerAst = [System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$parseErrors)
$script:ServerParseErrors = @($parseErrors)

if (-not ('Yuruna.TestFixtures.FailingStatusBodyStream' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Yuruna.TestFixtures {
    public sealed class FailingStatusBodyStream : System.IO.MemoryStream {
        public override System.Threading.Tasks.Task<int> ReadAsync(byte[] buffer, int offset, int count,
                System.Threading.CancellationToken cancellationToken) {
            return System.Threading.Tasks.Task.FromException<int>(new System.IO.IOException("fixture read failure"));
        }
    }
}
'@
}

function Get-ServerFunctionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $found = Get-YurunaTestFunctionAst -Ast $script:ServerAst -Name $Name
    if (-not $found) { return '' }
    return $found.Extent.Text
}

function Get-ServerRouteText {
    <#
    .SYNOPSIS
        The whole if statement that dispatches one route in the generated server.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Route)
    $clause = '$path -eq ''' + $Route + ''''
    $found = $script:ServerAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq $clause
        }.GetNewClosure(), $true) | Select-Object -First 1
    if (-not $found) { throw "the generated server has no route $Route" }
    return $found.Extent.Text
}

# A connected loopback socket pair: the listener reads a request body from
# exactly this kind of stream, so a read with nothing sent is really pending.
function New-SocketPair {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a loopback socket pair for one test case.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $pair = New-YurunaTestSocketPair
    return [pscustomobject]@{ Writer = $pair.Client; WriterStream = $pair.Client.GetStream(); Reader = $pair.Server; ReaderStream = $pair.Server.GetStream() }
}

function Close-SocketPair {
    [CmdletBinding()]
    param([AllowNull()]$Pair)
    if ($null -eq $Pair) { return }
    foreach ($item in @($Pair.Writer, $Pair.Reader)) { try { $item.Dispose() } catch { $null = $_ } }
}

function Wait-TaskSettled {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$BodyRead, [int]$Milliseconds = 2000)
    # WaitAny, not Task.Wait: a faulted read is an expected outcome here, and
    # Wait would rethrow it instead of simply returning.
    if ($BodyRead.Task) { $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($BodyRead.Task), $Milliseconds) }
}

function New-FakeResponse {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory response double.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $response = [pscustomobject]@{
        Headers = [System.Net.WebHeaderCollection]::new(); OutputStream = [System.IO.MemoryStream]::new()
        StatusCode = 0; ContentType = ''; ContentLength64 = [long]0; KeepAlive = $true; Aborted = $false
    }
    $response | Add-Member -MemberType ScriptMethod -Name Abort -Value { $this.Aborted = $true }
    return $response
}

function Read-FakeResponseJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Response)
    $text = [System.Text.Encoding]::UTF8.GetString($Response.OutputStream.ToArray())
    return (ConvertFrom-Json -InputObject $text)
}

$script:AllowedRung = @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker')
$script:ValidId = '0b6f3c2e-8a51-4d0e-9f4c-2d7a1e6b5c90'

function ConvertTo-BodyByte {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The unary comma returns the byte[] whole; callers pass it straight to a [byte[]] parameter.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    return , ([System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}
}

Describe 'control proofs use the current host identity' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.ConfigServiceSync.psm1') -Global -DisableNameChecking
    }
    It 'observes an identity created after the listener first checked' {
        $runtimeDir = Join-Path $TestDrive 'late-host-identity'
        $null = New-Item -ItemType Directory -Path $runtimeDir
        $null = $runtimeDir
        $script:ArchiveHostId = $null
        . ([scriptblock]::Create((Get-ServerFunctionText -Name 'Get-ArchiveHostId')))
        Get-ArchiveHostId | Should -BeNullOrEmpty
        $id = '42' + ('a' * 30)
        [IO.File]::WriteAllText((Join-Path $runtimeDir 'host.uuid'), $id)
        $proof = Get-YurunaControlProof -Token fixture -Audience $id -ExpiryUnixSeconds ([DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds())
        Test-YurunaControlProof -Token fixture -Wire $proof -Audience (Get-ArchiveHostId) | Should -BeTrue
    }
    It 'rejects a stale audience and accepts the replacement identity' {
        $runtimeDir = Join-Path $TestDrive 'changed-host-identity'
        $null = New-Item -ItemType Directory -Path $runtimeDir
        $null = $runtimeDir
        $script:ArchiveHostId = $null
        . ([scriptblock]::Create((Get-ServerFunctionText -Name 'Get-ArchiveHostId')))
        $file = Join-Path $runtimeDir 'host.uuid'
        $old = '42' + ('b' * 30)
        $current = '42' + ('c' * 30)
        [IO.File]::WriteAllText($file, $old)
        Get-ArchiveHostId | Should -BeExactly $old
        [IO.File]::WriteAllText($file, $current)
        $expiry = [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()
        $oldProof = Get-YurunaControlProof -Token fixture -Audience $old -ExpiryUnixSeconds $expiry
        $currentProof = Get-YurunaControlProof -Token fixture -Audience $current -ExpiryUnixSeconds $expiry
        Test-YurunaControlProof -Token fixture -Wire $oldProof -Audience (Get-ArchiveHostId) | Should -BeFalse
        Test-YurunaControlProof -Token fixture -Wire $currentProof -Audience (Get-ArchiveHostId) | Should -BeTrue
        Remove-Item -LiteralPath $file
        Get-ArchiveHostId | Should -BeNullOrEmpty
    }
}

Describe 'a body read never parks the caller' {

    It 'completes a small body that arrived in one piece' {
        $pair = New-SocketPair
        try {
            $bytes = ConvertTo-BodyByte '{"tier":"restart"}'
            $pair.WriterStream.Write($bytes, 0, $bytes.Length)
            $pair.Writer.Client.Shutdown([System.Net.Sockets.SocketShutdown]::Send)
            $read = New-StatusBoundedBodyRead -Stream $pair.ReaderStream -NowMs 0
            $status = 'reading'
            for ($i = 0; $i -lt 50 -and $status -eq 'reading'; $i++) {
                Wait-TaskSettled -BodyRead $read -Milliseconds 100
                $status = Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1
            }
            Assert-StringEqual 'complete' $status
            Assert-StringEqual '{"tier":"restart"}' ([System.Text.Encoding]::UTF8.GetString($read.Bytes))
        } finally { Close-SocketPair $pair }
    }

    It 'accepts exactly the cap and refuses one byte past it, whatever length was declared' {
        foreach ($size in @(4096, 4097)) {
            $stream = [System.IO.MemoryStream]::new([byte[]]::new($size))
            $read = New-StatusBoundedBodyRead -Stream $stream -NowMs 0
            $status = 'reading'
            for ($i = 0; $i -lt 10 -and $status -eq 'reading'; $i++) { $status = Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1 }
            if ($size -eq 4096) {
                Assert-StringEqual 'complete' $status 'a body of exactly 4096 bytes is within the cap'
                Assert-Equal 4096 $read.Bytes.Length
            } else {
                Assert-StringEqual 'too_large' $status 'the 4097th byte must be refused even with no declared length'
            }
            Close-StatusBoundedBodyRead -BodyRead $read
        }
    }

    It 'reports a withheld body as reading, returns at once, and times it out at the deadline' {
        $pair = New-SocketPair
        try {
            $read = New-StatusBoundedBodyRead -Stream $pair.ReaderStream -TimeoutMs 2000 -NowMs 1000
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $status = Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1500
            $watch.Stop()
            Assert-StringEqual 'reading' $status
            # A parked update waits for the read and overshoots by seconds; a
            # millisecond bound also fails on a descheduled or collecting test
            # process when suites run side by side.
            Assert-True ($watch.ElapsedMilliseconds -lt 1000) "an update with nothing to consume took $($watch.ElapsedMilliseconds) ms"
            Assert-StringEqual 'timeout' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 3000)
        } finally { Close-SocketPair $pair }
    }

    It 'cuts a trickled body off at the absolute deadline despite progress' {
        $pair = New-SocketPair
        try {
            $read = New-StatusBoundedBodyRead -Stream $pair.ReaderStream -TimeoutMs 2000 -NowMs 0
            foreach ($tick in @(300, 600, 900, 1200, 1500, 1800)) {
                $pair.WriterStream.Write([byte[]]@(0x7b), 0, 1)
                Wait-TaskSettled -BodyRead $read -Milliseconds 1000
                Assert-StringEqual 'reading' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs $tick) "progress at $tick ms is not an end"
            }
            Assert-Equal 6 $read.Count 'every trickled byte was consumed'
            $pair.WriterStream.Write([byte[]]@(0x7d), 0, 1)
            Wait-TaskSettled -BodyRead $read -Milliseconds 1000
            Assert-StringEqual 'timeout' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 2100) 'progress must not extend the deadline'
        } finally { Close-SocketPair $pair }
    }

    It 'completes a body that arrived in time even when the loop reaches it after the deadline' {
        # The listener's request stream answers the read after a declared
        # body synchronously with zero, as a memory stream does; the loop may
        # get to it late while it serves an archive or another admission.
        $stream = [System.IO.MemoryStream]::new((ConvertTo-BodyByte '{"tier":"restart"}'))
        $read = New-StatusBoundedBodyRead -Stream $stream -TimeoutMs 2000 -NowMs 0
        Assert-StringEqual 'complete' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 60000) 'a whole body is not a timeout'
        Assert-StringEqual '{"tier":"restart"}' ([System.Text.Encoding]::UTF8.GetString($read.Bytes))
        Close-StatusBoundedBodyRead -BodyRead $read
    }

    It 'reports a stream that fails as error, and closes without throwing' {
        # Closing a socket locally can finish an outstanding read with zero
        # bytes instead of an exception. Supply an actual asynchronous fault
        # so scheduler timing cannot turn the failure fixture into clean EOF.
        $stream = [Yuruna.TestFixtures.FailingStatusBodyStream]::new()
        try {
            $read = New-StatusBoundedBodyRead -Stream $stream -NowMs 0
            $read.Status | Should -BeExactly 'reading'
            $read.Task.IsFaulted | Should -BeTrue
            Assert-StringEqual 'error' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1)
            Close-StatusBoundedBodyRead -BodyRead $read
            Close-StatusBoundedBodyRead -BodyRead $read
            Close-StatusBoundedBodyRead -BodyRead $null
        } finally { $stream.Dispose() }
        $disposed = [System.IO.MemoryStream]::new()
        $disposed.Dispose()
        $unusable = New-StatusBoundedBodyRead -Stream $disposed -NowMs 0
        Assert-StringEqual 'error' (Update-StatusBoundedBodyRead -BodyRead $unusable -NowMs 1) 'a read on an unusable stream is an error, not a throw'
    }

    It 'accepts an empty stream as clean EOF rather than an I/O error' {
        $stream = [IO.MemoryStream]::new()
        try {
            $read = New-StatusBoundedBodyRead -Stream $stream -NowMs 0
            Assert-StringEqual 'complete' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1)
            $read.Bytes.Length | Should -Be 0
            Close-StatusBoundedBodyRead -BodyRead $read
        } finally { $stream.Dispose() }
    }

    It 'waits until the earliest deadline, or indefinitely with nothing pending' {
        Assert-Equal -1 (Get-StatusBoundedBodyReadWait -BodyRead @() -NowMs 0)
        Assert-Equal -1 (Get-StatusBoundedBodyReadWait -BodyRead $null -NowMs 0)
        $one = [pscustomobject]@{ Status = 'reading'; DeadlineMs = 5000 }
        Assert-Equal 3000 (Get-StatusBoundedBodyReadWait -BodyRead @($one) -NowMs 2000)
        $done = [pscustomobject]@{ Status = 'complete'; DeadlineMs = 2100 }
        $late = [pscustomobject]@{ Status = 'reading'; DeadlineMs = 2500 }
        Assert-Equal 500 (Get-StatusBoundedBodyReadWait -BodyRead @($one, $done, $late) -NowMs 2000) 'a finished read has no deadline left to wait for'
        Assert-Equal 0 (Get-StatusBoundedBodyReadWait -BodyRead @($late) -NowMs 9000) 'a passed deadline waits zero, never a negative'
    }
}

Describe 'the repair body has one closed schema' {

    It 'accepts a complete remote body and a partial loopback body' {
        $remote = ConvertFrom-HostRepairRequestBody -Remote -AllowedRungName $script:AllowedRung `
            -Bytes (ConvertTo-BodyByte ('{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"start-if-stopped"}'))
        Assert-True $remote.Valid $remote.Reason
        Assert-StringEqual $script:ValidId $remote.RequestId
        Assert-StringEqual 'start-if-stopped' $remote.MaxRung
        Assert-True $remote.RequestIdSupplied
        $loopback = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{}')
        Assert-True $loopback.Valid 'loopback may omit every key and take the defaults'
        Assert-False $loopback.RequestIdSupplied
        Assert-StringEqual 'restart' $loopback.Tier
        Assert-StringEqual '' $loopback.MaxRung
    }

    It 'requires every key from a remote caller' {
        foreach ($body in @(
                ('{"tier":"restart","maxRung":"probe"}'),
                ('{"requestId":"' + $script:ValidId + '","maxRung":"probe"}'),
                ('{"requestId":"' + $script:ValidId + '","tier":"restart"}'))) {
            $result = ConvertFrom-HostRepairRequestBody -Remote -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $body)
            Assert-False $result.Valid "remote body $body must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
        }
    }

    It 'refuses every request id that is not the canonical lowercase form' {
        foreach ($id in @($script:ValidId.ToUpperInvariant(), ('{' + $script:ValidId + '}'), $script:ValidId.Replace('-', ''), 'not-a-guid', '')) {
            $result = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte ('{"requestId":"' + $id + '"}'))
            Assert-False $result.Valid "request id '$id' must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
            Assert-StringEqual 'requestId' $result.Field
        }
    }

    It 'refuses a tier other than restart and a rung above the restart tier or unknown' {
        foreach ($body in @('{"tier":"full"}', '{"tier":"Restart"}', '{"maxRung":"reapply-settings"}', '{"maxRung":"reinstall"}', '{"maxRung":"reboot"}', '{"maxRung":"teleport"}', '{"maxRung":"Probe"}')) {
            $result = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $body)
            Assert-False $result.Valid "$body must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
        }
    }

    It 'refuses every spelling of a local-only safety switch as forbidden' {
        foreach ($name in @('force', 'Force', 'FORCE', '-Force', 'allowHardStop', 'AllowHardStop', 'hardStop', 'hard_stop', 'hard-stop',
                'restoreServiceVmName', 'leaveStoppedServiceVmName', 'configPath', 'ConfigPath', 'x_force_y')) {
            $result = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte ('{"' + $name + '":true}'))
            Assert-False $result.Valid "$name must be refused"
            Assert-StringEqual 'forbidden_field' $result.Reason "$name names a local-only switch"
        }
    }

    It 'refuses unknown keys as unsupported and case-variant duplicates' {
        $unknown = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","note":"x"}')
        Assert-StringEqual 'unsupported_field' $unknown.Reason
        Assert-StringEqual 'note' $unknown.Field
        $cased = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"Tier":"restart"}')
        Assert-StringEqual 'unsupported_field' $cased.Reason 'keys are case-sensitive'
        $duplicate = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","TIER":"restart"}')
        Assert-False $duplicate.Valid
        Assert-StringEqual 'invalid_json' $duplicate.Reason 'a name repeated in another casing is ambiguous'
        $exact = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","tier":"restart"}')
        Assert-StringEqual 'invalid_json' $exact.Reason
    }

    It 'refuses non-object roots, deep nesting, non-string values, comments, trailing commas, a BOM and invalid UTF-8' {
        foreach ($text in @('[]', '"restart"', '42', 'null', '{"a":{"b":{"c":{"d":{"e":1}}}}}', '{"tier":1}', '{"tier":null}',
                '{"tier":"restart",}', '{/*c*/"tier":"restart"}', '', '{')) {
            $result = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $text)
            Assert-False $result.Valid "'$text' must be refused"
        }
        $bom = [byte[]]@(0xEF, 0xBB, 0xBF) + (ConvertTo-BodyByte '{}')
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes $bom).Reason
        $invalidUtf8 = [byte[]]@(0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D)
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes $invalidUtf8).Reason
    }

    It 'never echoes an arbitrary field name' {
        $result = ConvertFrom-HostRepairRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"<script>alert(1)</script>":1}')
        Assert-StringEqual 'unsupported_field' $result.Reason
        Assert-StringEqual 'field' $result.Field 'a name outside the echo shape is replaced'
    }

    It 'accepts only a JSON content type with a UTF-8 charset or none' {
        foreach ($ok in @('application/json', 'application/json; charset=utf-8', 'Application/JSON;charset=UTF-8', 'application/json; charset="utf-8"')) {
            Assert-True (Test-HostControlContentType -ContentType $ok) $ok
        }
        foreach ($bad in @('', 'text/plain', 'application/json; charset=latin1', 'application/jsonx', 'application/x-www-form-urlencoded', 'application/json; boundary=x')) {
            Assert-False (Test-HostControlContentType -ContentType $bad) $bad
        }
    }
}

Describe 'the host-update body has one closed schema' {

    It 'refuses <Name> as forbidden_field, whatever its value' -ForEach @(
        @{ Name = 'drain' }, @{ Name = 'Drain' }, @{ Name = 'DRAIN' }, @{ Name = 'drain_mode' }, @{ Name = 'drainseconds' }
        @{ Name = 'DrainSeconds' }, @{ Name = 'x-drain' }, @{ Name = 'force' }, @{ Name = 'configPath' }
    ) {
        foreach ($value in @('"now"', '1', 'null', '{}', '"after-cycle"')) {
            $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte ('{"' + $Name + '":' + $value + '}'))
            Assert-False $result.Valid "$Name=$value must be refused"
            Assert-StringEqual 'forbidden_field' $result.Reason "$Name=$value"
            Assert-StringEqual $Name $result.Field 'the name is echoed as sent'
        }
    }

    It 'applies the defaults to an empty body' {
        $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{}')
        Assert-True $result.Valid $result.Reason
        Assert-False $result.RequestIdSupplied
        Assert-StringEqual 'restart' $result.Scope
        Assert-Equal 7200 $result.DrainSeconds
        Assert-Null $result.ExpectCommit
    }

    It 'accepts drainSeconds <Value>' -ForEach @(@{ Value = 60 }, @{ Value = 7200 }, @{ Value = 21600 }) {
        $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte ('{"drainSeconds":' + $Value + '}'))
        Assert-True $result.Valid $result.Reason
        Assert-Equal $Value $result.DrainSeconds
    }

    It 'refuses drainSeconds <Text>' -ForEach @(@{ Text = '59' }, @{ Text = '21601' }, @{ Text = '60.5' }, @{ Text = '"7200"' }, @{ Text = '1e3' }, @{ Text = 'null' }, @{ Text = '-60' }) {
        $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte ('{"drainSeconds":' + $Text + '}'))
        Assert-False $result.Valid
        Assert-StringEqual 'invalid_value' $result.Reason
        Assert-StringEqual 'drainSeconds' $result.Field
    }

    It 'accepts every full request with the values it names' {
        $body = '{"requestId":"' + $script:ValidId + '","scope":"full","drainSeconds":600,"expectCommit":"0123456789abcdef0123456789abcdef01234567"}'
        $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte $body)
        Assert-True $result.Valid $result.Reason
        Assert-StringEqual $script:ValidId $result.RequestId
        Assert-True $result.RequestIdSupplied
        Assert-StringEqual 'full' $result.Scope
        Assert-Equal 600 $result.DrainSeconds
        Assert-StringEqual '0123456789abcdef0123456789abcdef01234567' $result.ExpectCommit
    }

    It 'refuses an expectCommit, scope or request id outside its shape' {
        foreach ($case in @(
                @{ Body = '{"expectCommit":"abc123"}'; Field = 'expectCommit' }
                @{ Body = '{"expectCommit":"ABCDEF1"}'; Field = 'expectCommit' }
                @{ Body = ('{"expectCommit":"' + ('a' * 41) + '"}'); Field = 'expectCommit' }
                @{ Body = '{"expectCommit":"main"}'; Field = 'expectCommit' }
                @{ Body = '{"expectCommit":1234567}'; Field = 'expectCommit' }
                @{ Body = '{"scope":"Restart"}'; Field = 'scope' }
                @{ Body = '{"scope":"install"}'; Field = 'scope' }
                @{ Body = '{"scope":null}'; Field = 'scope' }
                @{ Body = ('{"requestId":"' + $script:ValidId.ToUpperInvariant() + '"}'); Field = 'requestId' }
                @{ Body = '{"requestId":"not-a-guid"}'; Field = 'requestId' })) {
            $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte $case.Body)
            Assert-False $result.Valid "$($case.Body) must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason $case.Body
            Assert-StringEqual $case.Field $result.Field $case.Body
        }
        foreach ($commit in @('abcdef1', ('0' * 40))) {
            Assert-True (ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte ('{"expectCommit":"' + $commit + '"}'))).Valid $commit
        }
    }

    It 'refuses unknown keys, a case variant of an allowed key and duplicates in any casing' {
        $unknown = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{"note":"x"}')
        Assert-StringEqual 'unsupported_field' $unknown.Reason
        Assert-StringEqual 'note' $unknown.Field
        Assert-StringEqual 'unsupported_field' (ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{"Scope":"restart"}')).Reason 'keys are case-sensitive'
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{"scope":"restart","SCOPE":"full"}')).Reason
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{"scope":"restart","scope":"restart"}')).Reason
        $echo = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte '{"<script>":1}')
        Assert-StringEqual 'field' $echo.Field 'a name outside the echo shape is replaced'
    }

    It 'refuses a BOM, invalid UTF-8, depth five, other roots and an oversize body' {
        $bom = [byte[]]@(0xEF, 0xBB, 0xBF) + (ConvertTo-BodyByte '{}')
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostUpdateRequestBody -Bytes $bom).Reason
        $invalidUtf8 = [byte[]]@(0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D)
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostUpdateRequestBody -Bytes $invalidUtf8).Reason
        foreach ($text in @('{"a":{"b":{"c":{"d":{}}}}}', '[]', '"restart"', 'null', '', '{', '{"scope":"restart",}', '{/*c*/}')) {
            $result = ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte $text)
            Assert-False $result.Valid "'$text' must be refused"
            Assert-StringEqual 'invalid_json' $result.Reason "'$text'"
        }
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostUpdateRequestBody -Bytes (ConvertTo-BodyByte ('{"scope":"' + ('r' * 5000) + '"}'))).Reason
    }
}

Describe 'the host-update loopback rule' {

    It 'counts <Address> with Host <HostLabel> as loopback: <Expected>' -ForEach @(
        @{ Address = '127.0.0.1'; HostLabel = 'localhost:8080'; Header = 'localhost:8080'; Port = 8080; Expected = $true }
        @{ Address = '127.0.0.1'; HostLabel = 'LOCALHOST:8080'; Header = 'LOCALHOST:8080'; Port = 8080; Expected = $true }
        @{ Address = '127.0.0.1'; HostLabel = '127.0.0.1:8080'; Header = '127.0.0.1:8080'; Port = 8080; Expected = $true }
        @{ Address = '::1'; HostLabel = '[::1]:8080'; Header = '[::1]:8080'; Port = 8080; Expected = $true }
        @{ Address = '::ffff:127.0.0.1'; HostLabel = 'localhost:8080'; Header = 'localhost:8080'; Port = 8080; Expected = $true }
        @{ Address = '127.0.0.2'; HostLabel = 'localhost:8080'; Header = 'localhost:8080'; Port = 8080; Expected = $true }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost (port 80)'; Header = 'localhost'; Port = 80; Expected = $true }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost:80 (port 80)'; Header = 'localhost:80'; Port = 80; Expected = $true }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost (port 8080)'; Header = 'localhost'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost:8081'; Header = 'localhost:8081'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost.:8080'; Header = 'localhost.:8080'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'user@localhost:8080'; Header = 'user@localhost:8080'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'localhost:8080/x'; Header = 'localhost:8080/x'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'evil.example:8080'; Header = 'evil.example:8080'; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'empty'; Header = ''; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'none'; Header = $null; Port = 8080; Expected = $false }
        @{ Address = '127.0.0.1'; HostLabel = 'a list'; Header = 'localhost:8080, localhost:8080'; Port = 8080; Expected = $false }
        @{ Address = '192.168.1.5'; HostLabel = 'localhost:8080'; Header = 'localhost:8080'; Port = 8080; Expected = $false }
        @{ Address = '192.168.1.5'; HostLabel = '192.168.1.5:8080'; Header = '192.168.1.5:8080'; Port = 8080; Expected = $false }
    ) {
        $verdict = Test-HostUpdateLoopbackCaller -RemoteAddress ([System.Net.IPAddress]::Parse($Address)) -HostHeader $Header -Port $Port
        Assert-Equal $Expected $verdict "$Address with Host '$Header' on port $Port"
    }

    It 'refuses a caller with no remote address' {
        Assert-False (Test-HostUpdateLoopbackCaller -RemoteAddress $null -HostHeader 'localhost:8080' -Port 8080)
    }
}

Describe 'every admission decision maps to exactly one documented reply' {

    It 'maps spawn with a launch to 202 spawned and without one to 503 launcher_failed' {
        $admission = [pscustomobject]@{ Decision = 'spawn'; RequestId = $script:ValidId; Ceiling = 'start-if-stopped' }
        $ok = Get-HostRepairAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $true; Reason = 'launched' })
        Assert-Equal 202 $ok.StatusCode
        Assert-StringEqual 'spawned' $ok.Body.action
        Assert-True $ok.Body.ok
        Assert-StringEqual $script:ValidId $ok.Body.requestId
        Assert-StringEqual 'start-if-stopped' $ok.Body.ceiling
        Assert-StringEqual '/runtime/host-repair.state.json' $ok.Body.stateUrl
        Assert-StringEqual '' $ok.MessageKey
        $failed = Get-HostRepairAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $false; Reason = 'launcher-failed' })
        Assert-Equal 503 $failed.StatusCode
        Assert-StringEqual 'launcher_failed' $failed.Body.reason
        Assert-StringEqual $script:ValidId $failed.Body.requestId 'a failed launch keeps the queued request identity so it can be retried'
        Assert-StringEqual '/runtime/host-repair.state.json' $failed.Body.stateUrl
        Assert-StringEqual 'status.api_worker_launcher_failed' $failed.MessageKey
        Assert-StringEqual 'launcher_failed' $failed.MessageArguments.reason
        $none = Get-HostRepairAdmissionReply -Admission $admission -Launch $null
        Assert-Equal 503 $none.StatusCode 'a spawn with no launch result never reads as spawned'
    }

    It 'maps already-claimed, completed, busy, policy-mismatch, stored and unavailable' {
        $claimed = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'already-claimed'; RequestId = $script:ValidId }) -Ceiling 'reclaim'
        Assert-Equal 202 $claimed.StatusCode
        Assert-StringEqual 'already_claimed' $claimed.Body.action
        Assert-StringEqual 'reclaim' $claimed.Body.ceiling
        $completed = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'completed'; RequestId = $script:ValidId; State = 'completed'; Verdict = 'partial' })
        Assert-Equal 200 $completed.StatusCode
        Assert-True $completed.Body.ok 'ok means the record was retrieved, not that the repair succeeded'
        Assert-StringEqual 'partial' $completed.Body.verdict
        Assert-StringEqual 'completed' $completed.Body.action
        $healthy = Get-HostRepairAdmissionReply -Admission @{ Decision = 'completed'; RequestId = $script:ValidId; State = 'recovery-pending'; Verdict = 'already-healthy' }
        Assert-StringEqual 'already_healthy' $healthy.Body.verdict 'private tokens cross the wire underscored'
        Assert-StringEqual 'recovery_pending' $healthy.Body.state
        $busy = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; RequestId = $script:ValidId; ActiveRequestId = 'aaaa'; ActiveKind = 'host-repair' })
        Assert-Equal 409 $busy.StatusCode
        Assert-StringEqual 'busy' $busy.Body.reason
        Assert-StringEqual 'host_repair' $busy.Body.activeKind
        Assert-StringEqual 'aaaa' $busy.Body.activeRequestId
        Assert-StringEqual '/runtime/host-repair.state.json' $busy.Body.stateUrl
        $busyCycle = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; ActiveRequestId = 'bbbb'; ActiveKind = 'start-cycle' })
        Assert-StringEqual 'start_cycle' $busyCycle.Body.activeKind
        Assert-StringEqual '/runtime/start-cycle.state.json' $busyCycle.Body.stateUrl 'a start-cycle holder is observed at its own state file'
        $busyUpdate = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; ActiveRequestId = 'cccc'; ActiveKind = 'host-update' })
        Assert-StringEqual 'host_update' $busyUpdate.Body.activeKind
        Assert-StringEqual '/runtime/host-update.state.json' $busyUpdate.Body.stateUrl 'a host-update holder is observed at its own state file'
        Assert-StringEqual 'status.api_host_update_busy' $busyUpdate.MessageKey
        $conflict = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'policy-mismatch'; RequestId = $script:ValidId })
        Assert-Equal 409 $conflict.StatusCode
        Assert-StringEqual 'request_conflict' $conflict.Body.reason
        $stored = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'stored'; RequestId = $script:ValidId; State = 'refused'; Verdict = 'refused' })
        Assert-Equal 409 $stored.StatusCode
        Assert-StringEqual 'request_closed' $stored.Body.reason
        Assert-StringEqual 'refused' $stored.Body.state
        Assert-StringEqual 'refused' $stored.Body.verdict
        $unavailable = Get-HostRepairAdmissionReply -Admission ([pscustomobject]@{ Decision = 'unavailable'; Reason = 'journal-unreadable' })
        Assert-Equal 503 $unavailable.StatusCode
        Assert-StringEqual 'admission_unavailable' $unavailable.Body.reason
        Assert-StringEqual 'journal_unreadable' $unavailable.MessageArguments.reason
    }

    It 'answers an unrecognized or missing decision with 500, never a success' {
        foreach ($admission in @($null, [pscustomobject]@{ Decision = 'SPAWN' }, [pscustomobject]@{ Decision = 'maybe' }, @{})) {
            $reply = Get-HostRepairAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $true })
            Assert-Equal 500 $reply.StatusCode
            Assert-StringEqual 'internal_error' $reply.Body.reason
        }
    }

    It 'maps start-cycle reservations, including a failed launch and each busy holder' {
        $id = New-StatusOperationId
        $queued = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'reserved'; Generation = 'g1' }) -Launch ([pscustomobject]@{ Launched = $true }) -OperationId $id
        Assert-Equal 202 $queued.StatusCode
        Assert-StringEqual 'queued' $queued.Body.action
        Assert-StringEqual $id $queued.Body.operationId
        Assert-StringEqual '/runtime/start-cycle.state.json' $queued.Body.stateUrl
        $failed = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'reserved'; Generation = 'g1' }) -Launch ([pscustomobject]@{ Launched = $false; Reason = 'hop-failed' }) -OperationId $id
        Assert-Equal 503 $failed.StatusCode
        Assert-StringEqual 'launcher_failed' $failed.Body.reason
        Assert-StringEqual 'hop_failed' $failed.MessageArguments.reason
        $repairBusy = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'busy'; ActiveKind = 'host-repair'; ActiveRequestId = $script:ValidId }) -OperationId $id
        Assert-Equal 409 $repairBusy.StatusCode
        Assert-StringEqual 'host_repair' $repairBusy.Body.activeKind
        Assert-StringEqual '/runtime/host-repair.state.json' $repairBusy.Body.stateUrl
        Assert-StringEqual 'status.api_host_repair_busy' $repairBusy.MessageKey
        $cycleBusy = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'busy'; ActiveKind = 'start-cycle'; ActiveRequestId = 'other' }) -OperationId $id
        Assert-StringEqual 'start_cycle' $cycleBusy.Body.activeKind
        Assert-StringEqual 'status.api_another_start_cycle_request_is_in_progress_3f51d139' $cycleBusy.MessageKey 'an older page still reads the sentence it always read'
        $updateBusy = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'busy'; ActiveKind = 'host-update'; ActiveRequestId = $script:ValidId }) -OperationId $id
        Assert-Equal 409 $updateBusy.StatusCode
        Assert-StringEqual 'host_update' $updateBusy.Body.activeKind
        Assert-StringEqual '/runtime/host-update.state.json' $updateBusy.Body.stateUrl
        Assert-StringEqual 'status.api_host_update_busy' $updateBusy.MessageKey
        $unavailable = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'unavailable'; Reason = 'journal-corrupt' }) -OperationId $id
        Assert-Equal 503 $unavailable.StatusCode
        Assert-StringEqual 'admission_unavailable' $unavailable.Body.reason
        Assert-Equal 500 (Get-StartCycleAdmissionReply -Reservation $null -OperationId $id).StatusCode
    }
}

Describe 'the capability summary is compact and fails closed' {

    It 'copies an available capability and adds remote' {
        $summary = Get-HostRepairControlSummary -ListenerReady $true -Remote 'missing' -Capability ([ordered]@{
                protocol = 1; availability = 'available'; ceiling = 'start-if-stopped'; reason = ''; state = 'idle' })
        Assert-StringEqual 'available' $summary.availability
        Assert-StringEqual 'start-if-stopped' $summary.ceiling
        Assert-StringEqual '' $summary.reason
        Assert-StringEqual 'missing' $summary.remote
        Assert-StringEqual 'idle' $summary.state
        Assert-Equal 1 $summary.protocol
    }

    It 'reads every missing, malformed or refused capability as unavailable' {
        $cases = @(
            @{ Capability = $null; Reason = 'capability_unavailable' }
            @{ Capability = @{ protocol = 2; availability = 'available'; ceiling = 'reclaim'; state = 'idle' }; Reason = 'protocol_unreadable' }
            @{ Capability = @{ protocol = 1; availability = 'available'; ceiling = ''; state = 'idle' }; Reason = 'no_qualified_rung' }
            @{ Capability = @{ protocol = 1; availability = 'available'; ceiling = 'Reclaim Now'; state = 'idle' }; Reason = 'no_qualified_rung' }
            @{ Capability = @{ protocol = 1; availability = 'unavailable'; ceiling = ''; reason = 'no-qualified-rung'; state = 'recovery-pending' }; Reason = 'no_qualified_rung' }
            @{ Capability = @{ protocol = 1; availability = 'yes'; ceiling = 'reclaim' }; Reason = 'capability_unavailable' }
        )
        foreach ($case in $cases) {
            $summary = Get-HostRepairControlSummary -ListenerReady $true -Remote 'unqualified' -Capability $case.Capability
            Assert-StringEqual 'unavailable' $summary.availability
            Assert-StringEqual '' $summary.ceiling 'an unavailable capability never names a ceiling'
            Assert-StringEqual $case.Reason $summary.reason
        }
        $pending = Get-HostRepairControlSummary -ListenerReady $true -Remote 'bogus' -Capability @{ protocol = 1; availability = 'unavailable'; state = 'recovery-pending' }
        Assert-StringEqual 'recovery_pending' $pending.state
        Assert-StringEqual 'unqualified' $pending.remote 'an unknown remote state reads as unqualified'
    }

    It 'applies the listener refusal over an available capability' {
        $capability = @{ protocol = 1; availability = 'available'; ceiling = 'reclaim'; reason = ''; state = 'active' }
        $missing = Get-HostRepairControlSummary -Capability $capability -ListenerReady $false -Remote 'missing'
        Assert-StringEqual 'unavailable' $missing.availability
        Assert-StringEqual 'listener_dependency_missing' $missing.reason
        Assert-StringEqual 'active' $missing.state 'the request state is still reported'
        $noHost = Get-HostRepairControlSummary -Capability $capability -ListenerReady $false -ListenerReason 'unsupported_host' -Remote 'missing'
        Assert-StringEqual 'unsupported_host' $noHost.reason
    }

    It 'stays within 256 bytes, and the whole control-status reply within 1024' {
        $longest = Get-HostRepairControlSummary -ListenerReady $false -ListenerReason ('a' * 48) -Remote 'unqualified' `
            -Capability @{ protocol = 1; availability = 'available'; ceiling = 'restart-if-hung'; state = 'recovery_pending' }
        $json = $longest | ConvertTo-Json -Compress
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($json) -le 256) "summary is $([System.Text.Encoding]::UTF8.GetByteCount($json)) bytes"
        $available = Get-HostRepairControlSummary -ListenerReady $true -Remote 'provisioned' `
            -Capability @{ protocol = 1; availability = 'available'; ceiling = 'restart-broker'; state = 'recovery_pending' }
        $update = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -ControllerState @{ scopes = 'restart,full' } `
            -Protocol 999999 -UpdateState 'recovering'
        $update['caller'] = 'loopback'
        $payload = @{
            ok = $true; tokenConfigured = $true; tokenTag = ('f' * 64); utcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); repair = $available
            update = $update
        } | ConvertTo-Json -Compress
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($payload) -lt 1024) "control-status is $([System.Text.Encoding]::UTF8.GetByteCount($payload)) bytes"
    }
}

Describe 'every host-update admission decision maps to its reply' {

    It 'maps queued and a takeover to 202 queued, and an active replay to already queued or claimed' {
        $queued = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'queued'; RequestId = $script:ValidId; State = 'queued' }) -Scope 'restart'
        Assert-Equal 202 $queued.StatusCode
        Assert-True $queued.Body.ok
        Assert-StringEqual 'queued' $queued.Body.action
        Assert-StringEqual 'restart' $queued.Body.scope
        Assert-StringEqual '/runtime/host-update.state.json' $queued.Body.stateUrl
        Assert-False ($queued.Body.Contains('supersedes'))
        $other = [Guid]::NewGuid().ToString('D')
        $takeover = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'taken-over'; RequestId = $script:ValidId; SupersededId = $other }) -Scope 'restart'
        Assert-Equal 202 $takeover.StatusCode
        Assert-StringEqual $other $takeover.Body.supersedes
        $waiting = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'already-active'; RequestId = $script:ValidId; State = 'queued' })
        Assert-StringEqual 'already_queued' $waiting.Body.action
        foreach ($state in @('running', 'recovery-pending')) {
            Assert-StringEqual 'already_claimed' (Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'already-active'; RequestId = $script:ValidId; State = $state })).Body.action $state
        }
    }

    It 'maps completed, busy, policy-mismatch, policy-invalid and unavailable' {
        $completed = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'completed'; RequestId = $script:ValidId; State = 'completed'; Verdict = 'updated_with_remarks' })
        Assert-Equal 200 $completed.StatusCode
        Assert-StringEqual 'completed' $completed.Body.action
        Assert-StringEqual 'updated_with_remarks' $completed.Body.verdict
        foreach ($case in @(
                @{ Kind = 'host-update'; Wire = 'host_update'; Url = '/runtime/host-update.state.json'; Key = 'status.api_host_update_busy' }
                @{ Kind = 'host-repair'; Wire = 'host_repair'; Url = '/runtime/host-repair.state.json'; Key = 'status.api_host_repair_busy' }
                @{ Kind = 'start-cycle'; Wire = 'start_cycle'; Url = '/runtime/start-cycle.state.json'; Key = 'status.api_host_repair_busy' }
                @{ Kind = 'teleport'; Wire = 'host_repair'; Url = '/runtime/host-repair.state.json'; Key = 'status.api_host_repair_busy' })) {
            $busy = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; ActiveKind = $case.Kind; ActiveRequestId = 'aaaa' })
            Assert-Equal 409 $busy.StatusCode $case.Kind
            Assert-StringEqual 'busy' $busy.Body.reason
            Assert-StringEqual $case.Wire $busy.Body.activeKind $case.Kind
            Assert-StringEqual 'aaaa' $busy.Body.activeRequestId
            Assert-StringEqual $case.Url $busy.Body.stateUrl $case.Kind
            Assert-StringEqual $case.Key $busy.MessageKey $case.Kind
        }
        $conflict = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'policy-mismatch'; RequestId = $script:ValidId })
        Assert-Equal 409 $conflict.StatusCode
        Assert-StringEqual 'request_conflict' $conflict.Body.reason
        $invalid = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'policy-invalid'; RequestId = $script:ValidId })
        Assert-Equal 400 $invalid.StatusCode
        Assert-StringEqual 'invalid_value' $invalid.Body.reason
        Assert-StringEqual 'drain' $invalid.Body.field
        $unavailable = Get-HostUpdateAdmissionReply -Admission ([pscustomobject]@{ Decision = 'unavailable'; Reason = 'runtime-owner-mismatch' })
        Assert-Equal 503 $unavailable.StatusCode
        Assert-StringEqual 'admission_unavailable' $unavailable.Body.reason
        Assert-StringEqual 'runtime_owner_mismatch' $unavailable.MessageArguments.reason
    }

    It 'answers an unrecognized or missing decision with 500, never a success' {
        foreach ($admission in @($null, [pscustomobject]@{ Decision = 'QUEUED' }, [pscustomobject]@{ Decision = 'spawn' }, @{})) {
            $reply = Get-HostUpdateAdmissionReply -Admission $admission
            Assert-Equal 500 $reply.StatusCode
            Assert-StringEqual 'internal_error' $reply.Body.reason
        }
    }
}

Describe 'the update capability is compact and fails closed' {

    It 'reads controller_absent for <LockState>' -ForEach @(@{ LockState = 'free' }, @{ LockState = 'absent' }, @{ LockState = 'unknown' }, @{ LockState = '' }) {
        $summary = Get-HostUpdateControlSummary -ListenerReady $true -LockState $LockState -JournalStatus 'ok' -Protocol 1 -UpdateState 'idle'
        Assert-StringEqual 'unavailable' $summary.availability
        Assert-StringEqual 'controller_absent' $summary.reason
        Assert-StringEqual '' $summary.scopes 'an unavailable capability lists no scope'
        Assert-StringEqual 'missing' $summary.remote
    }

    It 'reads listener_dependency_missing when the route is not ready' {
        $summary = Get-HostUpdateControlSummary -ListenerReady $false -ListenerReason 'listener_dependency_missing' -LockState 'held' -JournalStatus 'ok' -Protocol 1 -UpdateState 'active'
        Assert-StringEqual 'unavailable' $summary.availability
        Assert-StringEqual 'listener_dependency_missing' $summary.reason
        Assert-StringEqual 'active' $summary.state 'the update state is still reported'
    }

    It 'reads journal_unreadable for a journal it cannot read' {
        foreach ($status in @('corrupt', 'unreadable', 'unknown-version', '')) {
            $summary = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus $status -Protocol 1 -UpdateState 'unknown'
            Assert-StringEqual 'journal_unreadable' $summary.reason $status
        }
        foreach ($status in @('ok', 'absent', 'recovered-previous')) {
            Assert-StringEqual 'available' (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus $status -Protocol 1).availability $status
        }
    }

    It 'reads session_unusable only from the state file' {
        $unusable = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -ControllerState @{ sessionUsable = $false; scopes = 'restart' } -Protocol 1
        Assert-StringEqual 'session_unusable' $unusable.reason
        foreach ($state in @($null, @{}, @{ sessionUsable = $true }, @{ sessionUsable = 'false' })) {
            Assert-StringEqual 'available' (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -ControllerState $state -Protocol 1).availability
        }
    }

    It 'lists restart when the state file is absent and only the scopes it knows' {
        $absent = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -Protocol 1 -UpdateState 'idle'
        Assert-StringEqual 'available' $absent.availability
        Assert-StringEqual '' $absent.reason
        Assert-StringEqual 'restart' $absent.scopes
        Assert-StringEqual 'restart,full' (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -ControllerState @{ scopes = 'restart,full' }).scopes
        Assert-StringEqual 'restart' (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -ControllerState @{ scopes = 'everything' }).scopes
    }

    It 'reports the pool-control record whatever the availability, and its address only when provisioned' {
        $absent = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'free' -JournalStatus 'ok' -Protocol 1 -Remote 'provisioned' -PoolControl 'http://192.0.2.10'
        Assert-StringEqual 'controller_absent' $absent.reason
        Assert-StringEqual 'provisioned' $absent.remote 'remote is reported with no controller'
        Assert-StringEqual 'http://192.0.2.10' $absent.poolControl
        $ready = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -Protocol 1 -Remote 'provisioned' -PoolControl 'https://pool.example:8443/p'
        Assert-StringEqual 'protocol,availability,scopes,reason,remote,state,poolControl' (@($ready.Keys) -join ',')
        Assert-True ([Text.Encoding]::UTF8.GetByteCount(($ready | ConvertTo-Json -Compress)) -le 512) 'the summary stays inside its bound'
        foreach ($remote in @('missing', 'invalid')) {
            $other = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -Protocol 1 -Remote $remote -PoolControl 'http://192.0.2.10'
            Assert-StringEqual $remote $other.remote
            Assert-False ($other.Contains('poolControl')) "an address rides along with $remote"
        }
    }

    It 'reads an address outside the record''s own shape as invalid: <PoolControl>' -ForEach @(
        @{ PoolControl = '' }, @{ PoolControl = 'javascript:alert(1)' }, @{ PoolControl = 'http://192.0.2.10/?x=1' }, @{ PoolControl = 'http://a b' }
        @{ PoolControl = 'http://h/' + ('a' * 260) }
    ) {
        $summary = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok' -Protocol 1 -Remote 'provisioned' -PoolControl $PoolControl
        Assert-StringEqual 'invalid' $summary.remote
        Assert-False ($summary.Contains('poolControl'))
        Assert-StringEqual 'invalid' (Get-HostUpdateControlSummary -ListenerReady $true -Remote 'other').remote 'an unknown remote state reads as invalid'
    }

    It 'clamps unknown values' {
        $summary = Get-HostUpdateControlSummary -ListenerReady $false -ListenerReason 'Not A Code!' -Protocol 12345678 -UpdateState 'recovery-pending'
        Assert-StringEqual 'listener_dependency_missing' $summary.reason
        Assert-Equal -1 $summary.protocol
        Assert-StringEqual 'unknown' $summary.state
        Assert-StringEqual 'recovering' (Get-HostUpdateControlSummary -ListenerReady $true -UpdateState 'recovering').state
        Assert-Equal -1 (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok').protocol 'an unread protocol is -1 and decides nothing'
        Assert-StringEqual 'available' (Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'ok').availability
        Assert-StringEqual 'protocol,availability,scopes,reason,remote,state' (@($summary.Keys) -join ',')
    }

    It 'stays within 192 bytes' {
        $longest = Get-HostUpdateControlSummary -ListenerReady $false -ListenerReason ('a' * 48) -Protocol 999999 -UpdateState 'recovering'
        $json = $longest | ConvertTo-Json -Compress
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($json) -le 192) "summary is $([System.Text.Encoding]::UTF8.GetByteCount($json)) bytes"
        $available = Get-HostUpdateControlSummary -ListenerReady $true -LockState 'held' -JournalStatus 'recovered-previous' -ControllerState @{ scopes = 'restart,full' } -Protocol 999999 -UpdateState 'recovering'
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount(($available | ConvertTo-Json -Compress)) -le 192)
    }
}

Describe 'a worker vector binds against the script it launches' {

    BeforeAll {
        $script:WorkerTemp = New-YurunaTestTempDir -Prefix 'yuruna-route-argv'
        $script:WorkerScript = Join-Path $script:WorkerTemp 'worker.ps1'
        Set-Content -LiteralPath $script:WorkerScript -Encoding utf8 -Value @'
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestId,
    [long]$DeadlineTickMs,
    [long]$DeadlineTickLimit,
    [Alias('Rt')][string]$RuntimeDir,
    [switch]$Force
)
$null = $RequestId, $DeadlineTickMs, $DeadlineTickLimit, $RuntimeDir, $Force
'@
    }
    AfterAll { Remove-YurunaTestTempDir $script:WorkerTemp }

    It 'accepts a full-name vector with a switch' {
        $result = Test-StatusWorkerArgument -ScriptPath $script:WorkerScript -ArgumentList @('-RequestId', $script:ValidId, '-DeadlineTickMs', '5000000000', '-Force')
        Assert-True $result.Valid "$($result.Reason) $($result.Parameter)"
        Assert-True (Test-StatusWorkerArgument -ScriptPath $script:WorkerScript -ArgumentList @()).Valid 'an empty vector binds (the script decides what is mandatory)'
    }

    It 'refuses unknown, abbreviated, ambiguous, aliased and common names' {
        $cases = @(
            @{ Vector = @('-Nope', 'x'); Reason = 'unknown_parameter' }
            @{ Vector = @('-Request', $script:ValidId); Reason = 'abbreviated_parameter' }
            @{ Vector = @('-DeadlineTick', '1'); Reason = 'ambiguous_parameter' }
            @{ Vector = @('-Rt', '/tmp'); Reason = 'abbreviated_parameter' }
            @{ Vector = @('-Verbose'); Reason = 'unknown_parameter' }
            @{ Vector = @('-WhatIf'); Reason = 'unknown_parameter' }
        )
        foreach ($case in $cases) {
            $result = Test-StatusWorkerArgument -ScriptPath $script:WorkerScript -ArgumentList $case.Vector
            Assert-False $result.Valid ($case.Vector -join ' ')
            Assert-StringEqual $case.Reason $result.Reason ($case.Vector -join ' ')
        }
    }

    It 'refuses a switch with a value, a missing or empty value, a line break, a positional value and a repeat' {
        $cases = @(
            @{ Vector = @('-Force', 'yes'); Reason = 'invalid_value' }
            @{ Vector = @('-Force:$true'); Reason = 'invalid_value' }
            @{ Vector = @('-RequestId'); Reason = 'missing_value' }
            @{ Vector = @('-RequestId', ''); Reason = 'missing_value' }
            @{ Vector = @('-RequestId', '-Force'); Reason = 'missing_value' }
            @{ Vector = @('-RequestId', "a`nb"); Reason = 'invalid_value' }
            @{ Vector = @('-RequestId', "a`rb"); Reason = 'invalid_value' }
            @{ Vector = @('positional'); Reason = 'invalid_value' }
            @{ Vector = @('-RequestId', 'a', '-RequestId', 'b'); Reason = 'invalid_value' }
        )
        foreach ($case in $cases) {
            $result = Test-StatusWorkerArgument -ScriptPath $script:WorkerScript -ArgumentList $case.Vector
            Assert-False $result.Valid ($case.Vector -join ' ')
            Assert-StringEqual $case.Reason $result.Reason ($case.Vector -join ' ')
        }
    }

    It 'refuses a missing script and re-reads a script that changed' {
        Assert-StringEqual 'script_missing' (Test-StatusWorkerArgument -ScriptPath (Join-Path $script:WorkerTemp 'absent.ps1') -ArgumentList @()).Reason
        $changing = Join-Path $script:WorkerTemp 'changing.ps1'
        Set-Content -LiteralPath $changing -Value '[CmdletBinding()] param([string]$Alpha) $null = $Alpha'
        Assert-True (Test-StatusWorkerArgument -ScriptPath $changing -ArgumentList @('-Alpha', 'x')).Valid
        Set-Content -LiteralPath $changing -Value '[CmdletBinding()] param([string]$Beta) $null = $Beta'
        (Get-Item -LiteralPath $changing).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(1)
        Assert-StringEqual 'unknown_parameter' (Test-StatusWorkerArgument -ScriptPath $changing -ArgumentList @('-Alpha', 'x')).Reason
    }

    It 'binds the vectors the listener actually launches against the real worker scripts' {
        $diagnostic = Test-StatusWorkerArgument -ScriptPath (Join-Path $here 'Invoke-HostDiagnosticWorker.ps1') `
            -ArgumentList @('-RunId', $script:ValidId, '-DiagnosticScriptPath', '/x/Get-SystemDiagnostic.ps1', '-WorkDirectory', '/x/host-diagnostic', '-WorkingDirectory', '/x')
        Assert-True $diagnostic.Valid "$($diagnostic.Reason) $($diagnostic.Parameter)"
        $startCycle = Test-StatusWorkerArgument -ScriptPath (Join-Path $here 'Invoke-StartCycleWorker.ps1') `
            -ArgumentList @('-OperationId', $script:ValidId, '-Generation', 'g1', '-RuntimeDir', '/x/runtime', '-CleanupScriptPath', '/x/Remove-TestVMFiles.ps1',
                '-RunnerScriptPath', '/x/Start-TestRunner.ps1', '-WorkingDirectory', '/x')
        Assert-True $startCycle.Valid "$($startCycle.Reason) $($startCycle.Parameter)"
    }
}

Describe 'the diagnostic route serves, waits or spawns from the worker state' {

    BeforeAll {
        $script:DiagTemp = New-YurunaTestTempDir -Prefix 'yuruna-route-diag'
        function Set-DiagState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Writes a scratch fixture file.')]
            [CmdletBinding()]
            param([AllowNull()][hashtable]$State, [string]$Raw)
            $path = Join-Path $script:DiagTemp 'state.json'
            if ($PSBoundParameters.ContainsKey('Raw')) { [IO.File]::WriteAllText($path, $Raw); return }
            if ($null -eq $State) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
            [IO.File]::WriteAllText($path, ($State | ConvertTo-Json -Compress))
        }
        [IO.File]::WriteAllText((Join-Path $script:DiagTemp 'result.txt'), 'report')
        $script:Now = [DateTime]::new(2026, 9, 25, 12, 0, 0, [DateTimeKind]::Utc)
    }
    AfterAll { Remove-YurunaTestTempDir $script:DiagTemp }

    It 'spawns with no state' {
        Set-DiagState -State $null
        Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now).Action
    }

    It 'waits for a running worker until its deadline plus the grace, then spawns again' {
        Set-DiagState -State @{ schemaVersion = 1; runId = 'r1'; phase = 'running'; startedUtc = $script:Now.AddSeconds(-30).ToString('o'); deadlineUtc = $script:Now.AddSeconds(10).ToString('o') }
        $pending = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now
        Assert-StringEqual 'pending' $pending.Action
        Assert-StringEqual 'r1' $pending.RunId
        Assert-StringEqual 'pending' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now.AddSeconds(20)).Action
        Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now.AddSeconds(30)).Action
    }

    It 'serves a fresh completed run and spawns once it is stale' {
        Set-DiagState -State @{ schemaVersion = 1; runId = 'r2'; phase = 'completed'; completedUtc = $script:Now.AddSeconds(-5).ToString('o') }
        $serve = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now
        Assert-StringEqual 'serve' $serve.Action
        Assert-StringEqual (Join-Path $script:DiagTemp 'result.txt') $serve.ResultPath
        Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now.AddSeconds(20)).Action
    }

    It 'serves a fresh completed run it cannot send as a failure, never as a new run' {
        Set-DiagState -State @{ schemaVersion = 1; runId = 'r2'; phase = 'completed'; completedUtc = $script:Now.AddSeconds(-5).ToString('o') }
        # The listener spawned r2 itself: a spawn answer here would start a
        # new run on every poll until the cooldown passed.
        $tooLarge = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now -MaxServeBytes 3 -LastSpawnUtc $script:Now.AddSeconds(-40) -LastSpawnRunId 'r2'
        Assert-StringEqual 'serve_failure' $tooLarge.Action 'an oversized report is not served'
        Assert-StringEqual 'report_too_large' $tooLarge.FailureReason
        $resultPath = Join-Path $script:DiagTemp 'result.txt'
        Remove-Item -LiteralPath $resultPath -Force
        try {
            $missing = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now -LastSpawnUtc $script:Now.AddSeconds(-40) -LastSpawnRunId 'r2'
            Assert-StringEqual 'serve_failure' $missing.Action
            Assert-StringEqual 'report_unavailable' $missing.FailureReason
            Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now.AddSeconds(20)).Action 'past the cooldown a new run starts'
        } finally { [IO.File]::WriteAllText($resultPath, 'report') }
    }

    It 'serves a fresh failure as its failure' {
        Set-DiagState -State @{ schemaVersion = 1; runId = 'r3'; phase = 'failed'; completedUtc = $script:Now.AddSeconds(-2).ToString('o'); reason = 'timeout' }
        $failure = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now
        Assert-StringEqual 'serve_failure' $failure.Action
        Assert-StringEqual 'timeout' $failure.FailureReason
    }

    It 'answers pending for a launch younger than the grace that has written nothing yet' {
        Set-DiagState -State @{ schemaVersion = 1; runId = 'old'; phase = 'completed'; completedUtc = $script:Now.AddMinutes(-5).ToString('o') }
        $pending = Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now -LastSpawnUtc $script:Now.AddSeconds(-3) -LastSpawnRunId 'new'
        Assert-StringEqual 'pending' $pending.Action
        Assert-StringEqual 'new' $pending.RunId
        Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now -LastSpawnUtc $script:Now.AddSeconds(-30) -LastSpawnRunId 'new').Action
    }

    It 'treats a corrupt or foreign state file as no state' {
        foreach ($raw in @('not json', '', '{"schemaVersion":2,"phase":"completed"}', '[1,2]')) {
            Set-DiagState -Raw $raw
            Assert-StringEqual 'spawn' (Get-HostDiagnosticRouteState -WorkDirectory $script:DiagTemp -NowUtc $script:Now).Action "'$raw'"
            Assert-Null (Read-StatusWorkerState -Path (Join-Path $script:DiagTemp 'state.json'))
        }
    }
}

Describe 'the worker directory is private, prepared and pruned' {

    It 'creates an owner-only directory with an empty stdin sentinel, prunes old transcripts and refuses a link' {
        $scratch = New-YurunaTestTempDir -Prefix 'yuruna-route-home'
        try {
            $homeDir = Join-Path $scratch 'home'
            $null = New-Item -ItemType Directory -Path $homeDir
            $probe = Join-Path $scratch 'probe.ps1'
            $modulePath = Join-Path $here 'Test.StatusControlRoute.psm1'
            [IO.File]::WriteAllText($probe, @"
`$ErrorActionPreference = 'Stop'
Import-Module '$($modulePath -replace "'", "''")' -Force -DisableNameChecking
`$first = Get-StatusWorkerDirectory -Name 'host-diagnostic' -RetainTranscript 3 -Confirm:`$false
if (-not `$first.Resolved) { Write-Output ('RESULT ' + (ConvertTo-Json -Compress @{ stage = 'first'; reason = `$first.Reason })); exit 0 }
foreach (`$i in 1..6) {
    foreach (`$ext in 'out', 'err') {
        `$file = Join-Path `$first.Path ("run`$i.`$ext")
        [IO.File]::WriteAllText(`$file, 'x')
        [IO.File]::SetLastWriteTimeUtc(`$file, [DateTime]::UtcNow.AddMinutes(-10 + `$i))
    }
}
`$second = Get-StatusWorkerDirectory -Name 'host-diagnostic' -RetainTranscript 3 -Confirm:`$false
`$mode = if (`$IsWindows) { 0 } else { [int][IO.File]::GetUnixFileMode(`$second.Path) }
`$kept = @(Get-ChildItem -LiteralPath `$second.Path -File | Where-Object { `$_.Extension -in '.out', '.err' } | ForEach-Object Name | Sort-Object)
`$linkTarget = Join-Path '$($scratch -replace "'", "''")' 'elsewhere'
`$null = New-Item -ItemType Directory -Path `$linkTarget
`$linkReason = ''
if (-not `$IsWindows) {
    `$null = New-Item -ItemType SymbolicLink -Path (Join-Path (Split-Path -Parent `$second.Path) 'start-cycle') -Target `$linkTarget
    `$linkReason = (Get-StatusWorkerDirectory -Name 'start-cycle' -Confirm:`$false).Reason
}
Write-Output ('RESULT ' + (ConvertTo-Json -Compress @{
    stage = 'done'; resolved = `$second.Resolved; stdin = [IO.File]::Exists(`$second.StdInPath); stdinLength = (Get-Item -LiteralPath `$second.StdInPath).Length
    mode = `$mode; kept = `$kept; linkReason = `$linkReason; underHome = `$second.Path.StartsWith('$($homeDir -replace "'", "''")')
}))
"@)
            $previous = Save-YurunaTestEnvironment -Name 'HOME', 'USERPROFILE'
            try {
                # Windows derives the home directory from USERPROFILE, not HOME.
                $env:HOME = $homeDir
                $env:USERPROFILE = $homeDir
                $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probe 2>&1 | Out-String
            } finally { Restore-YurunaTestEnvironment -Saved $previous }
            $clean = $output -replace "`e\[[0-9;]*[A-Za-z]", ''
            $line = @($clean -split "`r?`n" | Where-Object { $_ -like 'RESULT *' }) | Select-Object -First 1
            Assert-True ([bool]$line) 'the child produced no result line'
            $result = ConvertFrom-Json -InputObject $line.Substring(7)
            Assert-StringEqual 'done' $result.stage "the private directory did not resolve: $($result.reason)"
            Assert-True $result.resolved
            Assert-True $result.underHome 'the worker directory must live under the private root in HOME'
            Assert-True $result.stdin 'the stdin sentinel exists'
            Assert-Equal 0 $result.stdinLength 'the stdin sentinel is empty'
            if (-not $IsWindows) {
                Assert-Equal 448 ([int]$result.mode) 'the worker directory is owner-only (0700)'
                Assert-StringEqual 'reparse-point' $result.linkReason 'a linked worker directory is refused'
            }
            Assert-StringEqual 'run4.err,run4.out,run5.err,run5.out,run6.err,run6.out' (@($result.kept) -join ',') 'the newest three of each stream are kept'
        } finally { Remove-YurunaTestTempDir $scratch }
    }
}

Describe 'the runner decision, the recorded arguments and the served-root test' {

    It 'spawns only on positive absence' {
        $cases = @(
            @{ State = @{ State = 'Missing' }; Decision = 'spawn' }
            @{ State = @{ State = 'DeadOrRecycled' }; Decision = 'spawn' }
            @{ State = @{ State = 'AliveOwned' }; Decision = 'restarted' }
            @{ State = @{ State = 'AliveOther' }; Decision = 'unknown' }
            @{ State = @{ State = 'Unknown' }; Decision = 'unknown' }
            @{ State = @{ status = 'None'; pid = 0 }; Decision = 'spawn' }
            @{ State = @{ status = 'OtherRunner'; pid = 42 }; Decision = 'restarted' }
            @{ State = @{ status = 'Stale'; pid = 0 }; Decision = 'unknown' }
            @{ State = @{ status = 'Self'; pid = 42 }; Decision = 'unknown' }
        )
        foreach ($case in $cases) {
            $decision = Get-StartCycleRunnerDecision -State $case.State
            Assert-StringEqual $case.Decision $decision.Decision (ConvertTo-Json -Compress -InputObject $case.State)
        }
        Assert-StringEqual 'spawn' (Get-StartCycleRunnerDecision -State @{ status = 'Stale'; pid = 42 } -ProcessAlive $false).Decision 'a recorded PID that is gone is absent'
        Assert-StringEqual 'unknown' (Get-StartCycleRunnerDecision -State @{ status = 'Stale'; pid = 42 } -ProcessAlive $true).Decision 'a live, unidentified PID is not absent'
        Assert-StringEqual 'unknown' (Get-StartCycleRunnerDecision -State @{ status = 'Stale'; pid = 42 }).Decision 'liveness not observed is not absence'
        Assert-StringEqual 'runner_unknown' (Get-StartCycleRunnerDecision -State $null).Reason
    }

    It 'forwards only the explicitly bound runner options, in a fixed order' {
        $record = @{
            parameters      = @{ ConfigPath = '/lab/test.config.yml'; NoGitPull = $true; NoStatusService = $false; NoConfigGate = $true; CycleDelaySeconds = 30; logLevel = 'Info' }
            explicitlyBound = @('CycleDelaySeconds', 'ConfigPath', 'NoGitPull', 'NoStatusService')
        }
        Assert-StringEqual '-ConfigPath /lab/test.config.yml -NoGitPull -CycleDelaySeconds 30' ((@(Get-StartCycleRunnerArgument -Record $record)) -join ' ')
        Assert-Equal 0 @(Get-StartCycleRunnerArgument -Record $null).Count
        Assert-Equal 0 @(Get-StartCycleRunnerArgument -Record @{ parameters = @{ ConfigPath = "a`nb" }; explicitlyBound = @('ConfigPath') }).Count 'a line break stops the conversion'
        Assert-Equal 0 @(Get-StartCycleRunnerArgument -Record @{ parameters = @{ NoGitPull = 'yes' }; explicitlyBound = @('NoGitPull') }).Count 'a switch that is not a boolean stops the conversion'
        Assert-Equal 0 @(Get-StartCycleRunnerArgument -Record @{ parameters = @{ CycleDelaySeconds = -1 }; explicitlyBound = @('CycleDelaySeconds') }).Count
    }

    It 'tells a served tree from a sibling that shares its prefix' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-route-served'
        try {
            $served = Join-Path $root 'repo'
            $null = New-Item -ItemType Directory -Path $served, (Join-Path $root 'repo-sibling')
            Assert-False (Test-StatusPathOutsideServedRoot -Path (Join-Path $served 'x/result.json') -ServedRoot @($served))
            Assert-False (Test-StatusPathOutsideServedRoot -Path $served -ServedRoot @($served))
            Assert-True (Test-StatusPathOutsideServedRoot -Path (Join-Path $root 'repo-sibling/result.json') -ServedRoot @($served))
            Assert-True (Test-StatusPathOutsideServedRoot -Path (Join-Path $root 'result.json') -ServedRoot @($served, '', $null))
            if (-not $IsWindows) {
                $alias = Join-Path $root 'alias'
                $null = New-Item -ItemType SymbolicLink -Path $alias -Target $served
                Assert-False (Test-StatusPathOutsideServedRoot -Path (Join-Path $alias 'result.json') -ServedRoot @($served)) 'a link into a served tree is inside it'
            }
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'keys a runtime directory by sixteen hex characters, the same for two spellings' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-route-rtkey'
        try {
            $key = Get-StatusRuntimeKey -RuntimeDir $root
            Assert-Match '^[0-9a-f]{16}$' $key
            Assert-StringEqual $key (Get-StatusRuntimeKey -RuntimeDir ($root + [IO.Path]::DirectorySeparatorChar))
            Assert-NotEqual $key (Get-StatusRuntimeKey -RuntimeDir (Join-Path $root 'other'))
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'reports a command set that lacks a command or a parameter' {
        $ready = Test-StatusRouteCommandSet -Requirement @{ 'Get-Item' = @('LiteralPath', 'Force') }
        Assert-True $ready.Ready
        $missing = Test-StatusRouteCommandSet -Requirement @{ 'Get-Item' = @('NoSuchParameter'); 'Get-NoSuchCommandForRoute' = @() }
        Assert-False $missing.Ready
        Assert-StringEqual 'Get-Item -NoSuchParameter,Get-NoSuchCommandForRoute' (@($missing.Missing | Sort-Object) -join ',')
    }

    It 'classifies a pidfile without the identity classifier: missing, malformed, gone, foreign' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-route-owner'
        try {
            $pidFile = Join-Path $root 'server.pid'
            $script = Join-Path $root '.status-service.ps1'
            Assert-StringEqual 'Missing' (Get-StatusServerOwnership -PidFile $pidFile -ExpectedScriptPath $script).State
            [IO.File]::WriteAllText($pidFile, 'not-a-pid')
            Assert-StringEqual 'Unknown' (Get-StatusServerOwnership -PidFile $pidFile -ExpectedScriptPath $script).State 'a malformed pidfile is unknown, never absent'
            $gone = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'exit 0' -PassThru
            $gone.WaitForExit()
            [IO.File]::WriteAllText($pidFile, [string]$gone.Id)
            $goneState = (Get-StatusServerOwnership -PidFile $pidFile -ExpectedScriptPath $script).State
            Assert-True ($goneState -in @('DeadOrRecycled', 'AliveOther', 'Unknown')) "an exited PID is not an owned server ($goneState)"
            [IO.File]::WriteAllText($pidFile, [string]$PID)
            [IO.File]::SetLastWriteTimeUtc($pidFile, (Get-Process -Id $PID).StartTime.ToUniversalTime().AddMinutes(-10))
            if (-not (Get-Command -Name 'Get-YurunaRunnerRecordState' -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Force -Global -DisableNameChecking
                Assert-StringEqual 'AliveOther' (Get-StatusServerOwnership -PidFile $pidFile -ExpectedScriptPath $script).State 'a process that started after the pidfile was written does not own it'
            }
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'the server pidfile is classified with the process-identity classifier loaded' {

    It 'confirms a live server by the script its command line names, and refuses anything else' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-route-u7owner'
        $standIns = @()
        try {
            $runtime = Join-Path $root 'runtime'
            $null = New-Item -ItemType Directory -Path $runtime
            $serverScript = Join-Path $runtime '.status-service.ps1'
            $otherScript = Join-Path $root 'other-service.ps1'
            foreach ($path in @($serverScript, $otherScript)) { [IO.File]::WriteAllText($path, 'Start-Sleep -Seconds 60') }
            $pwsh = (Get-Process -Id $PID).Path
            $owned = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', ('"' + $serverScript + '"') -PassThru
            $other = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', ('"' + $otherScript + '"') -PassThru
            $standIns = @($owned, $other)
            # The launcher writes server.pid after the server started.
            Start-Sleep -Milliseconds 1500
            [IO.File]::WriteAllText((Join-Path $runtime 'owned.pid'), [string]$owned.Id)
            [IO.File]::WriteAllText((Join-Path $runtime 'other.pid'), [string]$other.Id)
            $stale = Join-Path $runtime 'stale.pid'
            [IO.File]::WriteAllText($stale, [string]$owned.Id)
            [IO.File]::SetLastWriteTimeUtc($stale, [DateTime]::UtcNow.AddMinutes(-30))
            $probe = Join-Path $root 'probe.ps1'
            [IO.File]::WriteAllText($probe, @"
`$ErrorActionPreference = 'Stop'
Import-Module '$((Join-Path $here 'Test.YurunaDir.psm1') -replace "'", "''")' -Global -Force -DisableNameChecking
Import-Module '$((Join-Path $here 'Test.SingleInstance.psm1') -replace "'", "''")' -Global -DisableNameChecking
Import-Module '$((Join-Path $here 'Test.StatusControlRoute.psm1') -replace "'", "''")' -Global -Force -DisableNameChecking
`$rows = foreach (`$name in 'owned', 'other', 'stale') {
    `$pidFile = Join-Path '$($runtime -replace "'", "''")' "`$name.pid"
    `$u7 = Get-YurunaRunnerRecordState -PidFile `$pidFile -MtimeIdentity -ExpectedScriptPath '$($serverScript -replace "'", "''")'
    `$own = Get-StatusServerOwnership -PidFile `$pidFile -ExpectedScriptPath '$($serverScript -replace "'", "''")'
    [ordered]@{ name = `$name; u7State = [string]`$u7.State; u7Reason = [string]`$u7.Reason; state = [string]`$own.State; reason = [string]`$own.Reason; pid = `$own.Pid }
}
Write-Output ('RESULT ' + (ConvertTo-Json -Compress -InputObject @(`$rows)))
"@)
            $output = & $pwsh -NoProfile -NonInteractive -File $probe 2>&1 | Out-String
            $clean = $output -replace "`e\[[0-9;]*[A-Za-z]", ''
            $line = @($clean -split "`r?`n" | Where-Object { $_ -like 'RESULT *' }) | Select-Object -First 1
            Assert-True ([bool]$line) 'the child produced no result line'
            $rows = @{}
            foreach ($row in @(ConvertFrom-Json -InputObject $line.Substring(7))) { $rows[$row.name] = $row }
            # The classifier alone never proves a sidecar-less pidfile; that is
            # the case this function must resolve rather than report.
            Assert-StringEqual 'Unknown' $rows['owned'].u7State
            Assert-StringEqual 'no-exact-identity' $rows['owned'].u7Reason
            Assert-StringEqual 'AliveOwned' $rows['owned'].state 'a healthy server is its runtime owner, not an unknown owner'
            Assert-StringEqual 'command-line' $rows['owned'].reason
            Assert-Equal $owned.Id ([int]$rows['owned'].pid)
            Assert-StringEqual 'AliveOther' $rows['other'].state 'a process running some other script does not own the pidfile'
            Assert-StringEqual 'other-command' $rows['other'].reason
            Assert-StringEqual 'DeadOrRecycled' $rows['stale'].state 'a process that started after the pidfile was written is a recycled PID'
        } finally {
            foreach ($standIn in $standIns) { if ($standIn -and -not $standIn.HasExited) { try { $standIn.Kill() } catch { $null = $_ } } }
            Remove-YurunaTestTempDir $root
        }
    }
}

Describe 'the generated server wires the routes the way the listener must' {

    It 'emits a server script with no parse errors' {
        Assert-Equal 0 $script:ServerParseErrors.Count "the generated server does not parse: $(@($script:ServerParseErrors | ForEach-Object { $_.Message }) -join '; ')"
    }

    It 'guards the repair route with the always-on cross-site check and answers 405 through the shared error' {
        $guard = Get-StatusControlRouteGuard -Path 'control/host-repair' -Method 'GET'
        Assert-True ($guard -and $guard.Guard -eq 'Always' -and $guard.RequiresHeader) 'control/host-repair must be guarded on every method'
        $route = Get-ServerRouteText -Route 'control/host-repair'
        Assert-Match "Send-JsonError -Response \`$res -StatusCode 405 -Request \`$req -Key 'status.api_post_required_663cc07c'" $route
        Assert-True ($route -notmatch 'ReadToEnd') 'the repair route must not read its body synchronously'
        Assert-True ($route -match 'Add-PendingRequestBody') 'the repair route hands its body to the bounded reader'
        Assert-True ($route -match '\$pendingBodies\.Count -ge 4') 'at most four bodies are read at once'
    }

    It 'guards the host-update route like the repair route, reads its body through the bounded reader and launches nothing' {
        $guard = Get-StatusControlRouteGuard -Path 'control/host-update' -Method 'GET'
        Assert-True ($guard -and $guard.Guard -eq 'Always' -and $guard.RequiresHeader) 'control/host-update must be guarded on every method'
        Assert-Equal 0 @($guard.ProofScope).Count 'a scoped proof never opens it'
        $route = Get-ServerRouteText -Route 'control/host-update'
        Assert-Match "Send-JsonError -Response \`$res -StatusCode 405 -Request \`$req -Key 'status.api_post_required_663cc07c'" $route
        Assert-True ($route -notmatch 'ReadToEnd') 'the host-update route must not read its body synchronously'
        Assert-True ($route -match "Add-PendingRequestBody -RequestContext \`$ctx -Route 'host-update' -UpdateLoopback \`$updateLoopback") 'the route hands its body and its loopback verdict to the bounded reader'
        Assert-True ($route -match '\$pendingBodies\.Count -ge 4') 'at most four bodies are read at once'
        Assert-True ($route -match "Test-HostUpdateLoopbackCaller -RemoteAddress \`$req\.RemoteEndPoint\.Address -HostHeader \(\[string\]\`$req\.Headers\['Host'\]\) -Port \`$Port") 'the verdict reads the raw Host header and the listener port'
        Assert-True ($script:ServerText -match "Tag\.Route -ceq 'host-update'\) \{\s+Invoke-HostUpdateRequest -RequestContext \`$pendingContext -BodyBytes \`$bodyRead\.Bytes -Loopback \(\[bool\]\`$bodyRead\.Tag\.UpdateLoopback\)") 'the dispatcher sends a host-update body to its own handler'
        $handler = Get-ServerFunctionText -Name 'Invoke-HostUpdateRequest'
        foreach ($forbidden in @('Start-StatusWorker', 'Start-YurunaDetachedProcess', 'Publish-HostRepairQueuedState', '& pwsh', 'Start-Process')) {
            Assert-True (-not $handler.Contains($forbidden)) "the host-update handler must not contain '$forbidden'"
        }
        Assert-True ($handler -match "Drain = 'after-cycle'") 'the route always hands admission the constant after-cycle'
    }

    It 'never accepts a request with the blocking call, and waits on the pending bodies too' {
        Assert-True ($script:ServerText -notmatch '\$listener\.GetContext\(\)') 'the loop must not park in GetContext'
        Assert-True ($script:ServerText -match '\$listener\.GetContextAsync\(\)')
        Assert-True ($script:ServerText -match 'Task\]::WaitAny\(') 'the loop waits on the accept and the pending reads together'
        Assert-True ($script:ServerText -match 'Initialize-YurunaCriticalRecordIo') 'the critical-record helper is compiled at startup'
    }

    It 'keeps every mutation out of the start-cycle and diagnostic routes' {
        Assert-True ($script:ServerText -notmatch 'control\.start-cycle\.lock') 'the old start-cycle lock and its age sweep are gone'
        $startCycleHandler = Get-ServerFunctionText -Name 'Invoke-StartCycleRequest'
        Assert-True ((Get-ServerRouteText -Route 'control/start-cycle') -match 'Invoke-StartCycleRequest -Request \$req -Response \$res') 'the start-cycle route hands off to its handler'
        foreach ($routeName in @('control/start-cycle', 'control/host-diagnostic')) {
            $route = Get-ServerRouteText -Route $routeName
            if ($routeName -eq 'control/start-cycle') { $route = $route + "`n" + $startCycleHandler }
            foreach ($forbidden in @('& pwsh', 'Remove-Item', 'Set-Content', 'WriteAllText', 'bash -c', 'Start-Process', 'control.cycle-restart', 'Remove-TestVMFiles')) {
                Assert-True (-not $route.Contains($forbidden)) "$routeName must not contain '$forbidden'"
            }
            Assert-True ($route -match 'Start-StatusWorker') "$routeName launches its detached worker"
        }
        Assert-True ($startCycleHandler -match 'Request-StartCycleReservation') 'start-cycle reserves before launching'
        Assert-True ($startCycleHandler -match '(?s)finally\s*\{.*Save-StatusLaunchOutcome.*Set-StartCycleLaunch') 'every reserved launch is recorded from a finally'
        Assert-True ((Get-ServerFunctionText -Name 'Invoke-HostOperationRequest') -match '(?s)finally\s*\{.*Save-StatusLaunchOutcome.*Set-HostRepairLaunchOutcome') 'every admitted launch is recorded from a finally'
    }

    It 'launches workers only with fixed argument vectors checked against the script' {
        $worker = Get-ServerFunctionText -Name 'Start-StatusWorker'
        Assert-True ($worker -match 'Test-StatusWorkerArgument -ScriptPath \$ScriptPath -ArgumentList \$ArgumentList') 'every vector is bound-checked before launch'
        Assert-True ($worker -match 'TotalMilliseconds 5000') 'the launch is bounded'
        $repair = Get-ServerFunctionText -Name 'Invoke-HostOperationRequest'
        Assert-True ($repair -match 'New-HostRepairWorkerArgumentList -RepoRoot \$workerRoot -RequestId \$repairRequestId -Budget') 'the repair vector comes from the fixed builder'
        $repairCode = (@($repair -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n")
        Assert-True ($repairCode -notmatch 'X-Yuruna-Control') 'the repair proof is never read from the legacy header'
    }

    It 'names every route command to the route guard so a lost import heals' {
        $guarded = @{}
        foreach ($guard in $script:ServerAst.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-RouteModule'
                }, $true)) {
            foreach ($constant in $guard.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) {
                $guarded[$constant.Value] = $true
            }
        }
        $findings = @()
        foreach ($name in @('Request-HostRepairAdmission', 'Set-HostRepairLaunchOutcome', 'Get-HostRepairPrivateWorkDir', 'Get-HostRepairCapability',
                'New-HostRepairBudget', 'New-HostRepairWorkerArgumentList', 'Publish-HostRepairQueuedState', 'Get-VirtualizationRepairRung',
                'Request-StartCycleReservation', 'Set-StartCycleLaunch', 'Start-YurunaDetachedProcess',
                'Test-YurunaHostRepairAuthorization', 'Get-YurunaHostRepairRemoteState', 'Get-StatusWorkerDirectory', 'Get-HostDiagnosticRouteState',
                'Save-StatusLaunchOutcome', 'Get-StatusWorkerTranscriptStem', 'Request-HostUpdateAdmission', 'Get-HostUpdateControllerLockState',
                'Get-HostUpdateCapability', 'ConvertFrom-HostUpdateRequestBody', 'Test-HostUpdateLoopbackCaller', 'Get-HostUpdateControlSummary',
                'Get-HostUpdateAdmissionReply')) {
            if (-not $guarded.ContainsKey($name)) { $findings += "$name is called but never named to Import-RouteModule" }
        }
        Assert-NoFinding $findings 'a route calls a command a lost startup import cannot recover'
    }

    It 'denies every private name through the served-tree shapes and allows the public progress files' {
        $assignment = $script:ServerAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$secretNameShapes'
            }, $true) | Select-Object -First 1
        Assert-NotNull $assignment 'the shared shapes are gone'
        $shapes = @(& ([scriptblock]::Create($assignment.Right.Extent.Text)))
        $private = @('host-repair/host-operation.journal', 'x/host-repair/host-operation.lock', 'host-operation.journal', 'host-operation.journal.prev',
            'host-operation.lock', 'host-operation.admission.lock', 'runner-gate.record',
            'service-census.record.prev', 'abc.handshake.json', 'x.hop.json', 'x.hop.json.ack.json', 'runner-handoff.0123.ack.json',
            'remote-verifier.key', 'authority/operator.credential', 'work/stdin.empty.tmp',
            'host-repair/host-controller.lock', 'x/host-repair/host-controller/current', 'host-repair/host-controller/runner-console.sock')
        $public = @('host-repair.state.json', 'start-cycle.state.json', 'status.json', 'runner.repair-evidence.json', 'runner.cycle.json',
            'inner.start', 'runner.gate-held.json', 'host-update.state.json', 'host-controller.state.json')
        $findings = @()
        foreach ($name in $private) {
            $denied = $false
            foreach ($shape in $shapes) { if ($name -like $shape) { $denied = $true; break } }
            if (-not $denied) { $findings += "private name '$name' is served" }
        }
        foreach ($name in $public) {
            foreach ($shape in $shapes) { if ($name -like $shape) { $findings += "public name '$name' is denied by '$shape'" } }
        }
        Assert-NoFinding $findings 'the served-tree shapes do not separate private state from public progress'
        foreach ($leaf in @('host-update.state.json', 'host-controller.state.json')) {
            Assert-True ($script:ServerText -match ("'" + [regex]::Escape($leaf) + "'")) "the runtime allow-list serves $leaf"
        }
    }

    It 'reads the host-update route as ready with no worker vector' {
        $definitions = @(
            (Get-ServerFunctionText -Name 'Import-RouteModule'),
            (Get-ServerFunctionText -Name 'Test-StatusRouteReady')
        ) -join "`n"
        $probe = [scriptblock]::Create("param([string]`$RepoRoot)`n" + $definitions + "`n" + @'
$repoRoot = $RepoRoot
$script:StatusRouteReady = @{}
$errors = [System.Collections.Generic.List[string]]::new()
$vectors = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $errors.Add($msg) }
# A worker-vector check that always refuses: a route that ran it could never
# be ready, so a ready answer proves the route skipped it.
function Test-StatusWorkerArgument { param($ScriptPath, $ArgumentList) $null = $ArgumentList; $vectors.Add([string]$ScriptPath); [pscustomobject]@{ Valid = $false; Reason = 'probe'; Parameter = 'probe' } }
$ready = Test-StatusRouteReady -Route 'host-update'
[pscustomobject]@{ Ready = $ready.Ready; Reason = $ready.Reason; Errors = @($errors); Vectors = @($vectors) }
'@)
        $got = & $probe $script:RepoRoot
        Assert-True $got.Ready "host-update not ready: $($got.Errors -join '; ')"
        Assert-StringEqual '' $got.Reason
        Assert-Equal 0 @($got.Vectors).Count 'no worker vector is checked for a route that launches nothing'
    }
}

Describe 'the repair request handler maps each path to its documented reply' {

    BeforeAll {
        $definitions = @(
            (Get-ServerFunctionText -Name 'Send-JsonReply'),
            (Get-ServerFunctionText -Name 'Invoke-HostOperationRequest'),
            (Get-ServerFunctionText -Name 'Set-ResponseLocaleHeaders')
        ) -join "`n"
        $script:RepairHarness = [scriptblock]::Create("param([hashtable]`$Case)`n" + $definitions + "`n" + @'
$serverHostType = 'host.ubuntu.kvm'
$runtimeDir = '/scratch/runtime'
$workerRoot = '/scratch/repo'
$hostRepairEntry = '/scratch/repo/test/lab/Invoke-HostRepair.ps1'
$hostRepairStateUrl = '/runtime/host-repair.state.json'
$startCycleStateUrl = '/runtime/start-cycle.state.json'
$calls = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $calls.Add("err:$msg") }
function Resolve-PageLocale { param($AcceptLanguage) $null = $AcceptLanguage; return @{ Tag = 'en-US'; Direction = 'ltr' } }
function Get-VirtualizationRepairRung { param($HostType) $null = $HostType
    foreach ($pair in @(@('probe', 0), @('reclaim', 1), @('start-if-stopped', 2), @('restart-if-hung', 3), @('restart-broker', 4), @('reapply-settings', 5))) {
        [pscustomobject]@{ Name = $pair[0]; Order = $pair[1] } } }
function Get-HostRepairSummaryCached { return $Case.Summary }
function Import-RouteModule { param($ModuleRelativePath, $RequiredCommand) $null = $ModuleRelativePath, $RequiredCommand; return [bool]$Case.VerifierLoads }
function Get-ArchiveHostId { return '42af6f0d32ad41c48cffd47c91c16b2d' }
function Test-YurunaHostRepairAuthorization { param($ProofWire, $HostId, $RequestId, $Tier, $MaxRung)
    $calls.Add("auth:$ProofWire|$HostId|$RequestId|$Tier|$MaxRung"); return $Case.Authorization }
function Request-HostRepairAdmission { param($RequestId, $Channel, $Tier, $MaxRung, $RuntimeDir, $HostType, $AdmissionWaitMilliseconds, [switch]$Confirm)
    $null = $Confirm; $calls.Add("admit:$RequestId|$Channel|$Tier|$MaxRung|$RuntimeDir|$HostType|$AdmissionWaitMilliseconds")
    $record = $Case.Admission.Clone(); if (-not $record.ContainsKey('RequestId')) { $record.RequestId = $RequestId }; return [pscustomobject]$record }
function Get-HostRepairPrivateWorkDir { return $Case.WorkDir }
function New-HostRepairBudget { return [pscustomobject]@{ TotalExpiryTick = 1 } }
function New-HostRepairWorkerArgumentList { param($RepoRoot, $RequestId, $Budget) $null = $Budget; $calls.Add("argv:$RepoRoot|$RequestId")
    if ($Case.ArgvThrows) { throw [System.InvalidOperationException]::new('argument list refused') }
    '-RequestId'; $RequestId }
function Start-StatusWorker { param($Directory, $StdInPath, $ScriptPath, $ArgumentList, $TranscriptStem)
    $calls.Add("launch:$ScriptPath|$($ArgumentList -join ' ')|$TranscriptStem|$Directory"); return $Case.Launch }
# Answers each record attempt from OutcomeReplies in order (saved, refused or
# throw), then saved.
function Set-HostRepairLaunchOutcome { param($RequestId, $Outcome, $Launch, [switch]$Confirm) $null = $Launch, $Confirm; $calls.Add("outcome:$RequestId|$Outcome")
    $next = 'saved'
    if ($Case.OutcomeReplies -and $Case.OutcomeReplies.Count -gt 0) { $next = [string]$Case.OutcomeReplies[0]; $Case.OutcomeReplies.RemoveAt(0) }
    if ($next -eq 'throw') { throw [System.IO.IOException]::new('journal write failed') }
    return [pscustomobject]@{ Saved = ($next -eq 'saved'); Reason = $next } }
function Publish-HostRepairQueuedState { param($RuntimeDir, $RequestId, $Channel) $calls.Add("queued:$RuntimeDir|$RequestId|$Channel"); return $true }
$headers = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $headers; HttpMethod = 'POST' }
$response = [pscustomobject]@{ Headers = [System.Net.WebHeaderCollection]::new(); OutputStream = [System.IO.MemoryStream]::new(); StatusCode = 0; ContentType = ''; ContentLength64 = [long]0; KeepAlive = $true }
$context = [pscustomobject]@{ Request = $request; Response = $response }
Invoke-HostOperationRequest -RequestContext $context -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Case.Body)) -Loopback ([bool]$Case.Loopback) -ProofWire ([string]$Case.Proof)
[pscustomobject]@{ Response = $response; Json = (ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()))); Calls = @($calls) }
'@)
        $script:WorkDir = New-YurunaTestTempDir -Prefix 'yuruna-route-work'
        $script:Available = [ordered]@{ protocol = 1; availability = 'available'; ceiling = 'start-if-stopped'; reason = ''; remote = 'provisioned'; state = 'idle' }
        function New-RepairCase {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test case.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([hashtable]$Override = @{})
            $case = @{
                Body = '{}'; Loopback = $true; Proof = ''; Summary = $script:Available; VerifierLoads = $true
                Authorization = @{ Authorized = $true; Reason = 'ok'; HttpStatus = 200 }
                Admission = @{ Decision = 'spawn'; Attempt = 1 }; WorkDir = $script:WorkDir
                Launch = [pscustomobject]@{ Launched = $true; Reason = 'launched' }
            }
            foreach ($key in $Override.Keys) { $case[$key] = $Override[$key] }
            return $case
        }
    }
    AfterAll { Remove-YurunaTestTempDir $script:WorkDir }

    It 'admits a loopback body with defaults, launches the worker, records the launch and publishes the queued state' {
        $got = & $script:RepairHarness (New-RepairCase)
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual 'spawned' $got.Json.action
        Assert-Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' $got.Json.requestId 'loopback gets a generated canonical id'
        Assert-StringEqual 'start-if-stopped' $got.Json.ceiling 'loopback defaults to the advertised ceiling'
        $admit = @($got.Calls | Where-Object { $_ -like 'admit:*' })
        Assert-Equal 1 $admit.Count
        Assert-Match '\|listener\|restart\|start-if-stopped\|/scratch/runtime\|host\.ubuntu\.kvm\|1000$' $admit[0]
        Assert-True (@($got.Calls | Where-Object { $_ -like 'launch:/scratch/repo/test/lab/Invoke-HostRepair.ps1|-RequestId *' }).Count -eq 1) 'the fixed entry script is launched'
        Assert-True (@($got.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count -eq 1)
        Assert-True (@($got.Calls | Where-Object { $_ -like 'queued:/scratch/runtime|*|listener' }).Count -eq 1)
        Assert-True ([IO.File]::Exists((Join-Path $script:WorkDir 'stdin.empty'))) 'the stdin sentinel is prepared in the private work directory'
    }

    It 'keeps the request queued and answers 503 launcher_failed when the launch fails' {
        $got = & $script:RepairHarness (New-RepairCase @{ Launch = [pscustomobject]@{ Launched = $false; Reason = 'hop-failed' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'launcher_failed' $got.Json.reason
        Assert-True ([bool]$got.Json.requestId) 'the reply names the request to retry'
        Assert-True (@($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count -eq 1)
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'queued:*' }).Count 'nothing is published for a worker that never started'
    }

    It 'launches nothing for already-claimed, completed, busy, conflicting or closed requests' {
        foreach ($decision in @('already-claimed', 'completed', 'busy', 'policy-mismatch', 'stored', 'unavailable')) {
            $got = & $script:RepairHarness (New-RepairCase @{ Admission = @{ Decision = $decision; ActiveKind = 'host-repair'; State = 'completed'; Verdict = 'repaired' } })
            Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count "$decision must not launch"
            Assert-True ($got.Response.StatusCode -in @(200, 202, 409, 503)) "$decision answered $($got.Response.StatusCode)"
        }
    }

    It 'refuses an invalid body before admission, naming the field' {
        $got = & $script:RepairHarness (New-RepairCase @{ Body = '{"allowHardStop":true}' })
        Assert-Equal 400 $got.Response.StatusCode
        Assert-StringEqual 'forbidden_field' $got.Json.reason
        Assert-StringEqual 'allowHardStop' $got.Json.field
        Assert-StringEqual 'status.api_request_body_invalid' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count 'no admission for a refused body'
    }

    It 'refuses when the capability is not available' {
        $got = & $script:RepairHarness (New-RepairCase @{ Summary = [ordered]@{ protocol = 1; availability = 'unavailable'; ceiling = ''; reason = 'no_qualified_rung'; remote = 'missing'; state = 'idle' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'repair_unavailable' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count
    }

    It 'authorizes a non-loopback caller from its own proof header and admits it on the remote channel' {
        $body = '{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"reclaim"}'
        $got = & $script:RepairHarness (New-RepairCase @{ Loopback = $false; Body = $body; Proof = 'yrp1.proof' })
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual "auth:yrp1.proof|42af6f0d32ad41c48cffd47c91c16b2d|$($script:ValidId)|restart|reclaim" (@($got.Calls | Where-Object { $_ -like 'auth:*' })[0])
        Assert-Match '\|remote\|restart\|reclaim\|' (@($got.Calls | Where-Object { $_ -like 'admit:*' })[0])
    }

    It 'refuses a non-loopback caller without every key, with a refused proof, or with no verifier' {
        $partial = & $script:RepairHarness (New-RepairCase @{ Loopback = $false; Body = '{"tier":"restart"}' })
        Assert-Equal 400 $partial.Response.StatusCode 'a remote body must carry all three keys'
        $body = '{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"reclaim"}'
        $refused = & $script:RepairHarness (New-RepairCase @{ Loopback = $false; Body = $body; Authorization = @{ Authorized = $false; Reason = 'repair_proof_expired'; HttpStatus = 403 } })
        Assert-Equal 403 $refused.Response.StatusCode
        Assert-StringEqual 'repair_proof_expired' $refused.Json.reason
        Assert-StringEqual 'status.api_host_repair_authorization_refused' $refused.Json.code
        Assert-Equal 0 @($refused.Calls | Where-Object { $_ -like 'admit:*' }).Count
        $noVerifier = & $script:RepairHarness (New-RepairCase @{ Loopback = $false; Body = $body; VerifierLoads = $false })
        Assert-Equal 403 $noVerifier.Response.StatusCode
        Assert-StringEqual 'repair_verifier_unavailable' $noVerifier.Json.reason
    }

    It 'answers 503 private_state_unavailable when the work directory cannot be secured, and closes the admitted launch' {
        $got = & $script:RepairHarness (New-RepairCase @{ WorkDir = $null })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'private_state_unavailable' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count 'the pending launch admission recorded is closed, or the request reads as claimed'
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'queued:*' }).Count
    }

    It 'closes the admitted launch when building the worker vector throws, and still answers 500' {
        $got = & $script:RepairHarness (New-RepairCase @{ ArgvThrows = $true })
        Assert-Equal 500 $got.Response.StatusCode
        Assert-StringEqual 'internal_error' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count 'the throw still records the failed launch'
    }

    It 'tries a launch record that did not commit once more, and logs one that never does' {
        $retried = & $script:RepairHarness (New-RepairCase @{ OutcomeReplies = [System.Collections.Generic.List[string]]@('admission-busy') })
        Assert-Equal 202 $retried.Response.StatusCode
        Assert-Equal 2 @($retried.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count 'a record that did not commit is tried again'
        Assert-Equal 0 @($retried.Calls | Where-Object { $_ -like 'err:*' }).Count 'a second attempt that commits logs nothing'

        $thrown = & $script:RepairHarness (New-RepairCase @{ OutcomeReplies = [System.Collections.Generic.List[string]]@('throw', 'saved') })
        Assert-Equal 202 $thrown.Response.StatusCode 'a record write that throws does not tear the reply'
        Assert-Equal 2 @($thrown.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count

        $lost = & $script:RepairHarness (New-RepairCase @{
                Launch = [pscustomobject]@{ Launched = $false; Reason = 'hop-failed' }
                OutcomeReplies = [System.Collections.Generic.List[string]]@('admission-busy', 'journal-unwritable')
            })
        Assert-Equal 503 $lost.Response.StatusCode
        Assert-StringEqual 'launcher_failed' $lost.Json.reason
        Assert-Equal 2 @($lost.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count
        $logged = @($lost.Calls | Where-Object { $_ -like 'err:control/host-repair could not record launch outcome*' })
        Assert-Equal 1 $logged.Count 'a launch outcome that never commits is logged'
        Assert-Match 'journal-unwritable' $logged[0]
    }

    It 'keeps an earlier launch transcript of the same attempt' {
        $body = '{"requestId":"' + $script:ValidId + '"}'
        $earlier = Join-Path $script:WorkDir "$($script:ValidId).1.out"
        [IO.File]::WriteAllText($earlier, 'the earlier launch')
        try {
            $got = & $script:RepairHarness (New-RepairCase @{ Body = $body })
            Assert-Equal 202 $got.Response.StatusCode
            $launch = @($got.Calls | Where-Object { $_ -like 'launch:*' })
            Assert-Equal 1 $launch.Count
            Assert-True ($launch[0] -like "*|$($script:ValidId).1.2|*") "the relaunch writes new transcripts: $($launch[0])"
        } finally { Remove-Item -LiteralPath $earlier -Force -ErrorAction SilentlyContinue }
    }

    It 'turns a throw into a 500 JSON reply rather than a torn connection' {
        $got = & $script:RepairHarness (New-RepairCase @{ Admission = $null })
        Assert-Equal 500 $got.Response.StatusCode
        Assert-StringEqual 'internal_error' $got.Json.reason
        Assert-True (@($got.Calls | Where-Object { $_ -like 'err:control/host-repair failed:*' }).Count -eq 1) 'the throw is logged'
    }
}

Describe 'the host-update request handler maps each path to its documented reply' {

    BeforeAll {
        $definitions = @(
            (Get-ServerFunctionText -Name 'Send-JsonReply'),
            (Get-ServerFunctionText -Name 'Invoke-HostUpdateRequest'),
            (Get-ServerFunctionText -Name 'Set-ResponseLocaleHeaders')
        ) -join "`n"
        $script:UpdateHarness = [scriptblock]::Create("param([hashtable]`$Case)`n" + $definitions + "`n" + @'
$serverHostType = 'host.ubuntu.kvm'
$runtimeDir = '/scratch/runtime'
$hostUpdateStateUrl = '/runtime/host-update.state.json'
$hostRepairStateUrl = '/runtime/host-repair.state.json'
$startCycleStateUrl = '/runtime/start-cycle.state.json'
$calls = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $calls.Add("err:$msg") }
function Resolve-PageLocale { param($AcceptLanguage) $null = $AcceptLanguage; return @{ Tag = 'en-US'; Direction = 'ltr' } }
if (-not $Case.RealLock) { function Get-HostUpdateControllerLockState { $calls.Add('lock'); return [string]$Case.LockState } }
function Get-HostUpdateSummaryCached { return $Case.Summary }
function Request-HostUpdateAdmission { param($RequestId, $Channel, $Scope, $Drain, $DrainSeconds, $ExpectCommit, $RuntimeDir, $HostType, $AdmissionWaitMilliseconds, [switch]$Confirm)
    $null = $Confirm; $calls.Add("admit:$RequestId|$Channel|$Scope|$Drain|$DrainSeconds|$ExpectCommit|$RuntimeDir|$HostType|$AdmissionWaitMilliseconds")
    if ($null -eq $Case.Admission) { throw [System.IO.IOException]::new('journal write failed') }
    $record = $Case.Admission.Clone(); if (-not $record.ContainsKey('RequestId')) { $record.RequestId = $RequestId }; return [pscustomobject]$record }
$headers = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $headers; HttpMethod = 'POST' }
$response = [pscustomobject]@{ Headers = [System.Net.WebHeaderCollection]::new(); OutputStream = [System.IO.MemoryStream]::new(); StatusCode = 0; ContentType = ''; ContentLength64 = [long]0; KeepAlive = $true }
$context = [pscustomobject]@{ Request = $request; Response = $response }
Invoke-HostUpdateRequest -RequestContext $context -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Case.Body)) -Loopback ([bool]$Case.Loopback)
[pscustomobject]@{ Response = $response; Json = (ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()))); Calls = @($calls) }
'@)
        $script:UpdateAvailable = [ordered]@{ protocol = 1; availability = 'available'; scopes = 'restart'; reason = ''; remote = 'missing'; state = 'idle' }
        function New-UpdateCase {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test case.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([hashtable]$Override = @{})
            $case = @{ Body = '{}'; Loopback = $true; LockState = 'held'; Summary = $script:UpdateAvailable; Admission = @{ Decision = 'queued'; State = 'queued' } }
            foreach ($key in $Override.Keys) { $case[$key] = $Override[$key] }
            return $case
        }
    }

    It 'queues a loopback body with defaults, always draining after the cycle, and launches nothing' {
        $got = & $script:UpdateHarness (New-UpdateCase)
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual 'queued' $got.Json.action
        Assert-StringEqual 'restart' $got.Json.scope
        Assert-StringEqual '/runtime/host-update.state.json' $got.Json.stateUrl
        Assert-Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' $got.Json.requestId 'loopback gets a generated canonical id'
        $admit = @($got.Calls | Where-Object { $_ -like 'admit:*' })
        Assert-Equal 1 $admit.Count
        Assert-Match '\|listener\|restart\|after-cycle\|7200\|\|/scratch/runtime\|host\.ubuntu\.kvm\|1000$' $admit[0]
    }

    It 'passes the request id, drainSeconds and expectCommit through, and still drains after the cycle' {
        $body = '{"requestId":"' + $script:ValidId + '","drainSeconds":600,"expectCommit":"abcdef1"}'
        $got = & $script:UpdateHarness (New-UpdateCase @{ Body = $body })
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual $script:ValidId $got.Json.requestId
        Assert-StringEqual "admit:$($script:ValidId)|listener|restart|after-cycle|600|abcdef1|/scratch/runtime|host.ubuntu.kvm|1000" (@($got.Calls | Where-Object { $_ -like 'admit:*' })[0])
    }

    It 'refuses drain in a body before anything else, naming the field' {
        $got = & $script:UpdateHarness (New-UpdateCase @{ Body = '{"drain":"now"}' })
        Assert-Equal 400 $got.Response.StatusCode
        Assert-StringEqual 'forbidden_field' $got.Json.reason
        Assert-StringEqual 'drain' $got.Json.field
        Assert-StringEqual 'status.api_request_body_invalid' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -in @('lock') -or $_ -like 'admit:*' }).Count 'a refused body probes nothing and admits nothing'
    }

    It 'refuses a caller that is not this host itself with 403 update_proof_missing' {
        $got = & $script:UpdateHarness (New-UpdateCase @{ Loopback = $false })
        Assert-Equal 403 $got.Response.StatusCode
        Assert-StringEqual 'update_proof_missing' $got.Json.reason
        Assert-StringEqual 'status.api_host_update_proof_missing' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count
    }

    It 'refuses with 503 controller_absent when the controller lock reads <LockState>' -ForEach @(@{ LockState = 'free' }, @{ LockState = 'absent' }, @{ LockState = 'unknown' }) {
        $got = & $script:UpdateHarness (New-UpdateCase @{ LockState = $LockState })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'controller_absent' $got.Json.reason
        Assert-StringEqual 'status.api_host_update_controller_absent' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count 'a request nobody will run is never queued'
    }

    It 'refuses with 503 controller_absent on a host with no private root at all, creating nothing' {
        $scratchHome = New-YurunaTestTempDir -Prefix 'yuruna-route-noroot'
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.HostOperationJournal.psm1') -Force -Global -DisableNameChecking
        & (Get-Module Test.HostOperationJournal) { param($h) $script:HostOperationHomePath = $h } $scratchHome
        try {
            $got = & $script:UpdateHarness (New-UpdateCase @{ RealLock = $true })
            Assert-Equal 503 $got.Response.StatusCode
            Assert-StringEqual 'controller_absent' $got.Json.reason
            Assert-False (Test-Path -LiteralPath (Join-Path $scratchHome '.yuruna')) 'the probe never creates the private root'
        } finally {
            & (Get-Module Test.HostOperationJournal) { $script:HostOperationHomePath = $null }
            Remove-YurunaTestTempDir $scratchHome
        }
    }

    It 'refuses a scope the controller does not run with 409 scope_unavailable, queuing nothing' {
        $got = & $script:UpdateHarness (New-UpdateCase @{ Body = '{"scope":"full"}' })
        Assert-Equal 409 $got.Response.StatusCode
        Assert-StringEqual 'scope_unavailable' $got.Json.reason
        Assert-StringEqual 'full' $got.Json.scope
        Assert-StringEqual 'status.api_host_update_scope_unavailable' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count
        $both = [ordered]@{ protocol = 1; availability = 'available'; scopes = 'restart,full'; reason = ''; remote = 'missing'; state = 'idle' }
        Assert-Equal 202 (& $script:UpdateHarness (New-UpdateCase @{ Body = '{"scope":"full"}'; Summary = $both })).Response.StatusCode 'a listed scope is admitted'
    }

    It 'answers busy with the holder, and a takeover with the update it supersedes' {
        $busy = & $script:UpdateHarness (New-UpdateCase @{ Admission = @{ Decision = 'busy'; ActiveKind = 'host-update'; ActiveRequestId = $script:ValidId } })
        Assert-Equal 409 $busy.Response.StatusCode
        Assert-StringEqual 'host_update' $busy.Json.activeKind
        Assert-StringEqual $script:ValidId $busy.Json.activeRequestId
        Assert-StringEqual 'status.api_host_update_busy' $busy.Json.code
        $old = [Guid]::NewGuid().ToString('D')
        $takeover = & $script:UpdateHarness (New-UpdateCase @{ Admission = @{ Decision = 'taken-over'; State = 'queued'; SupersededId = $old } })
        Assert-Equal 202 $takeover.Response.StatusCode
        Assert-StringEqual $old $takeover.Json.supersedes
    }

    It 'turns a throw into a 500 JSON reply rather than a torn connection' {
        $got = & $script:UpdateHarness (New-UpdateCase @{ Admission = $null })
        Assert-Equal 500 $got.Response.StatusCode
        Assert-StringEqual 'internal_error' $got.Json.reason
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'err:control/host-update failed:*' }).Count 'the throw is logged'
    }
}

Describe 'the start-cycle handler records every launch it was admitted to make' {

    BeforeAll {
        $definitions = @(
            (Get-ServerFunctionText -Name 'Send-JsonReply'),
            (Get-ServerFunctionText -Name 'Invoke-StartCycleRequest'),
            (Get-ServerFunctionText -Name 'Set-ResponseLocaleHeaders')
        ) -join "`n"
        $script:StartCycleHarness = [scriptblock]::Create("param([hashtable]`$Case)`n" + $definitions + "`n" + @'
$runtimeDir = '/scratch/runtime'
$repoRoot = '/scratch/repo'
$servedRootSet = @('/scratch/repo', '/scratch/runtime')
$startCycleWorker = '/scratch/repo/test/modules/Invoke-StartCycleWorker.ps1'
$startCycleCleanupScript = '/scratch/repo/test/Remove-TestVMFiles.ps1'
$startCycleRunnerScript = '/scratch/repo/test/Start-TestRunner.ps1'
$hostRepairStateUrl = '/runtime/host-repair.state.json'
$startCycleStateUrl = '/runtime/start-cycle.state.json'
$calls = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $calls.Add("err:$msg") }
function Resolve-PageLocale { param($AcceptLanguage) $null = $AcceptLanguage; return @{ Tag = 'en-US'; Direction = 'ltr' } }
function Get-StatusWorkerDirectory { param($Name, $ServedRoot, [switch]$Confirm) $null = $ServedRoot, $Confirm; $calls.Add("directory:$Name"); return $Case.Directory }
function Request-StartCycleReservation { param($OperationId, $RuntimeDir, $AdmissionWaitMilliseconds, [switch]$Confirm)
    $null = $Confirm; $calls.Add("reserve:$OperationId|$RuntimeDir|$AdmissionWaitMilliseconds"); return [pscustomobject]$Case.Reservation }
function Start-StatusWorker { param($Directory, $StdInPath, $ScriptPath, $ArgumentList, $TranscriptStem)
    $null = $StdInPath; $calls.Add("launch:$ScriptPath|$TranscriptStem|$Directory|$($ArgumentList -join ' ')")
    if ($Case.LaunchThrows) { throw [System.InvalidOperationException]::new('launcher exploded') }
    return $Case.Launch }
# Answers each record attempt from RecordReplies in order (saved, refused or
# throw), then saved.
function Set-StartCycleLaunch { param($OperationId, $Generation, $Outcome, $Launch, [switch]$Confirm) $null = $Launch, $Confirm
    $calls.Add("record:$OperationId|$Generation|$Outcome")
    $next = 'saved'
    if ($Case.RecordReplies -and $Case.RecordReplies.Count -gt 0) { $next = [string]$Case.RecordReplies[0]; $Case.RecordReplies.RemoveAt(0) }
    if ($next -eq 'throw') { throw [System.IO.IOException]::new('journal write failed') }
    return [pscustomobject]@{ Saved = ($next -eq 'saved') } }
$request = [pscustomobject]@{ Headers = [System.Net.WebHeaderCollection]::new(); HttpMethod = 'POST' }
$response = [pscustomobject]@{ Headers = [System.Net.WebHeaderCollection]::new(); OutputStream = [System.IO.MemoryStream]::new(); StatusCode = 0; ContentType = ''; ContentLength64 = [long]0; KeepAlive = $true }
$thrown = $null
try { Invoke-StartCycleRequest -Request $request -Response $response } catch { $thrown = $_.Exception }
$text = [System.Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray())
[pscustomobject]@{ Response = $response; Json = $(if ($text) { ConvertFrom-Json -InputObject $text } else { $null }); Calls = @($calls); Thrown = $thrown }
'@)
        function New-StartCycleCase {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Builds an in-memory test case.')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([hashtable]$Override = @{})
            $case = @{
                Directory   = [pscustomobject]@{ Resolved = $true; Path = '/scratch/private/start-cycle'; StdInPath = '/scratch/private/start-cycle/stdin.empty'; Reason = 'ok' }
                Reservation = @{ Decision = 'reserved'; Generation = 'a1b2c3'; ActiveKind = ''; ActiveRequestId = $null; Reason = 'reserved' }
                Launch      = [pscustomobject]@{ Launched = $true; Reason = 'launched' }
            }
            foreach ($key in $Override.Keys) { $case[$key] = $Override[$key] }
            return $case
        }
    }

    It 'reserves, launches the fixed worker vector, records the launch and answers 202 queued' {
        $got = & $script:StartCycleHarness (New-StartCycleCase)
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual 'queued' $got.Json.action
        $reserve = @($got.Calls | Where-Object { $_ -like 'reserve:*' })
        Assert-Equal 1 $reserve.Count
        Assert-Match '\|/scratch/runtime\|1000$' $reserve[0]
        $operation = ($reserve[0] -replace '^reserve:', '').Split('|')[0]
        Assert-StringEqual $operation $got.Json.operationId
        $launch = @($got.Calls | Where-Object { $_ -like 'launch:*' })
        Assert-Equal 1 $launch.Count
        Assert-True ($launch[0] -like "launch:/scratch/repo/test/modules/Invoke-StartCycleWorker.ps1|$operation|/scratch/private/start-cycle|-OperationId $operation -Generation a1b2c3 -RuntimeDir /scratch/runtime *") $launch[0]
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -ceq "record:$operation|a1b2c3|started" }).Count
    }

    It 'records launch-failed, which removes the reservation, when the launch fails' {
        $got = & $script:StartCycleHarness (New-StartCycleCase @{ Launch = [pscustomobject]@{ Launched = $false; Reason = 'hop-failed' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'launcher_failed' $got.Json.reason
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'record:*|a1b2c3|launch-failed' }).Count
    }

    It 'records launch-failed when the launch throws, and lets the throw reach the dispatcher' {
        $got = & $script:StartCycleHarness (New-StartCycleCase @{ LaunchThrows = $true })
        Assert-NotNull $got.Thrown 'the dispatcher answers 500 for a throw'
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'record:*|a1b2c3|launch-failed' }).Count 'a reservation owned by a live listener is never left pending'
    }

    It 'tries a record that did not commit once more, and logs one that never does' {
        $retried = & $script:StartCycleHarness (New-StartCycleCase @{ RecordReplies = [System.Collections.Generic.List[string]]@('throw') })
        Assert-Equal 202 $retried.Response.StatusCode
        Assert-Equal 2 @($retried.Calls | Where-Object { $_ -like 'record:*|started' }).Count
        Assert-Equal 0 @($retried.Calls | Where-Object { $_ -like 'err:*' }).Count

        $lost = & $script:StartCycleHarness (New-StartCycleCase @{
                Launch = [pscustomobject]@{ Launched = $false; Reason = 'launcher-failed' }
                RecordReplies = [System.Collections.Generic.List[string]]@('refused', 'refused')
            })
        Assert-Equal 503 $lost.Response.StatusCode
        Assert-Equal 2 @($lost.Calls | Where-Object { $_ -like 'record:*|launch-failed' }).Count
        Assert-Equal 1 @($lost.Calls | Where-Object { $_ -like 'err:start-cycle could not record launch outcome*' }).Count
    }

    It 'launches and records nothing when the host is busy or admission is unavailable' {
        foreach ($reservation in @(
                @{ Decision = 'busy'; Generation = $null; ActiveKind = 'host-repair'; ActiveRequestId = $script:ValidId; Reason = 'host-operation-active' },
                @{ Decision = 'busy'; Generation = $null; ActiveKind = 'start-cycle'; ActiveRequestId = $script:ValidId; Reason = 'start-cycle-active' },
                @{ Decision = 'unavailable'; Generation = $null; ActiveKind = ''; ActiveRequestId = $null; Reason = 'admission-busy' })) {
            $got = & $script:StartCycleHarness (New-StartCycleCase @{ Reservation = $reservation })
            Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' -or $_ -like 'record:*' }).Count "$($reservation.Decision) $($reservation.ActiveKind)"
            Assert-True ($got.Response.StatusCode -in @(409, 503)) "answered $($got.Response.StatusCode)"
        }
    }

    It 'reserves nothing when the private directory cannot be secured' {
        $got = & $script:StartCycleHarness (New-StartCycleCase @{ Directory = [pscustomobject]@{ Resolved = $false; Path = $null; StdInPath = $null; Reason = 'owner-mismatch' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'private_state_unavailable' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'reserve:*' }).Count
    }
}

Describe 'launch records, transcript stems and refusal reasons' {

    It 'records once when the first attempt commits, retries once otherwise, and never throws' {
        $script:RecordTries = [System.Collections.Generic.List[int]]::new()
        $first = Save-StatusLaunchOutcome -Argument @{ Id = 'x' } -Record { param($A, $Attempt) $script:RecordTries.Add($Attempt); [pscustomobject]@{ Saved = ($A.Id -eq 'x') } }
        Assert-True $first.Saved
        Assert-Equal 1 $first.Attempts
        Assert-StringEqual '1' ($script:RecordTries -join ',')

        $script:RecordTries.Clear()
        $second = Save-StatusLaunchOutcome -Record { param($A, $Attempt) $null = $A; $script:RecordTries.Add($Attempt); [pscustomobject]@{ Saved = ($Attempt -eq 2); Reason = 'admission-busy' } }
        Assert-True $second.Saved
        Assert-Equal 2 $second.Attempts
        Assert-Match 'admission-busy' ($second.Failure -join ';')

        $never = Save-StatusLaunchOutcome -Record { param($A, $Attempt) $null = $A, $Attempt; throw [System.IO.IOException]::new('disk gone') }
        Assert-False $never.Saved
        Assert-Equal 2 @($never.Failure).Count
        Assert-Match 'IOException' ($never.Failure -join ';')

        $silent = Save-StatusLaunchOutcome -Record { param($A, $Attempt) $null = $A, $Attempt } -MaxAttempts 1
        Assert-False $silent.Saved 'a record that returns nothing did not commit'
    }

    It 'keeps the preferred stem while it is free and never reuses a launched one' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-route-stem'
        try {
            Assert-StringEqual 'abc.1' (Get-StatusWorkerTranscriptStem -Directory $root -Stem 'abc.1')
            [IO.File]::WriteAllText((Join-Path $root 'abc.1.err'), 'x')
            Assert-StringEqual 'abc.1.2' (Get-StatusWorkerTranscriptStem -Directory $root -Stem 'abc.1') 'an earlier .err alone marks the stem used'
            [IO.File]::WriteAllText((Join-Path $root 'abc.1.2.out'), 'x')
            Assert-StringEqual 'abc.1.3' (Get-StatusWorkerTranscriptStem -Directory $root -Stem 'abc.1')
            [IO.File]::WriteAllText((Join-Path $root 'abc.1.3.out'), 'x')
            Assert-Match '^abc\.1\.\d{8}T\d{9}$' (Get-StatusWorkerTranscriptStem -Directory $root -Stem 'abc.1' -MaxSuffix 3) 'past the numeric suffixes a timestamp is used'
            $refused = $false
            try { $null = Get-StatusWorkerTranscriptStem -Directory $root -Stem '../x' } catch { $refused = $true }
            Assert-True $refused 'a stem that could leave the directory is refused'
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'maps every confirmation reason the reservation API returns' {
        $cases = [ordered]@{
            'reservation-lost' = 'reservation_lost'; 'admission-busy' = 'busy'; 'lifetime-lock-not-held' = 'internal_error'
            'journal-unwritable' = 'internal_error'; 'private-root-unavailable' = 'internal_error'; 'admission-lock-not-held' = 'internal_error'
            'admission-lock-access-denied' = 'internal_error'; 'journal-corrupt' = 'internal_error'; '' = 'internal_error'
        }
        foreach ($reason in $cases.Keys) {
            Assert-StringEqual $cases[$reason] (Get-StartCycleRefusalReason -ConfirmReason $reason) "'$reason'"
        }
        Assert-StringEqual 'internal_error' (Get-StartCycleRefusalReason -ConfirmReason $null)
    }
}

Describe 'the merged /log/ index reads the pool share in one pass' {

    # The archive merge runs inside the listener's only request slot. On Linux
    # every Get-Item enumerates the whole parent directory, so looking each
    # archived name up again made one index request quadratic in archived
    # cycles: over the pool share it held the listener for tens of minutes, and
    # every guest livecheck queued behind it failed. The helpers are lifted out
    # of the generated server into a module of their own, with Get-Item replaced
    # by a counter, so a lookup per name fails the case instead of slowing it.
    BeforeAll {
        $script:ArchiveIndexText = @(
            (Get-ServerFunctionText -Name 'Get-ArchivedCycleEntry'),
            (Get-ServerFunctionText -Name 'Get-ArchivedCycleName')
        ) -join "`n"
    }

    It 'lists only sentinel-complete cycle folders, as the folder objects themselves, with no lookup per name' {
        Assert-True ($script:ArchiveIndexText -match 'function Get-ArchivedCycleEntry') 'the generated server must define Get-ArchivedCycleEntry'
        $root = New-YurunaTestTempDir -Prefix 'yuruna-archive-index'
        try {
            $hostId = '42e5e36df63d4edf8b664e6cf6fce463'
            $complete = @(foreach ($n in 1..5) { '{0:D6}.2026-10-0{1}.12-00-00.{2}' -f (700 + $n), $n, $hostId })
            foreach ($name in $complete) {
                $dir = [IO.Directory]::CreateDirectory((Join-Path $root $name))
                [IO.File]::WriteAllText((Join-Path $dir.FullName '.yuruna-complete'), '')
            }
            $copying = '000706.2026-10-06.12-00-00.{0}' -f $hostId
            $null = [IO.Directory]::CreateDirectory((Join-Path $root $copying))
            $other = [IO.Directory]::CreateDirectory((Join-Path $root 'not-a-cycle'))
            [IO.File]::WriteAllText((Join-Path $other.FullName '.yuruna-complete'), '')

            $module = New-Module -Name 'ArchiveIndexUnderTest' -ScriptBlock ([scriptblock]::Create(@"
`$script:GetItemCalls = 0
function Get-Item { `$script:GetItemCalls++ }
function Get-ArchiveCycleRoot { '$($root -replace "'", "''")' }
$($script:ArchiveIndexText)
"@))
            try {
                $first = @(& $module { Get-ArchivedCycleEntry })
                Assert-StringEqual (($complete | Sort-Object) -join ',') ((@($first | ForEach-Object Name) | Sort-Object) -join ',') 'only the sentinel-complete cycle folders are listed'
                Assert-Equal 0 @($first | Where-Object { -not $_.PSIsContainer }).Count 'every entry is the provider folder object the index renders'
                Assert-Equal 0 (& $module { $script:GetItemCalls }) 'no archived name may be looked up again'

                # A copy that completes later is listed on the next request, and a
                # folder that changed and lost its sentinel is not.
                [IO.File]::WriteAllText((Join-Path $root "$copying/.yuruna-complete"), '')
                $withdrawn = $complete[0]
                [IO.File]::Delete((Join-Path $root "$withdrawn/.yuruna-complete"))
                [IO.Directory]::SetLastWriteTimeUtc((Join-Path $root $withdrawn), [DateTime]::UtcNow.AddMinutes(1))
                $names = @(& $module { Get-ArchivedCycleName })
                Assert-True ($names -contains $copying) 'a copy that completed since the last request must be listed'
                Assert-True ($names -notcontains $withdrawn) 'a folder that changed and lost its sentinel must not be listed'
                Assert-Equal 5 $names.Count 'four remembered folders and the one that completed'
                Assert-Equal 0 (& $module { $script:GetItemCalls }) 'no archived name may be looked up again'
            } finally { Remove-Module $module -ErrorAction SilentlyContinue }
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'merges the archive into the /log/ root index without a lookup per name' {
        $merge = $script:ServerAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.IfStatementAst] -and
                $n.Clauses[0].Item1.Extent.Text -eq '$path -eq ''log'' -or $path -eq ''log/'''
            }, $true) | Select-Object -First 1
        Assert-True ($null -ne $merge) 'the generated server must merge the archive into the /log/ root index'
        $calls = @($merge.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        Assert-True ($calls -contains 'Get-ArchivedCycleEntry') 'the merge must take the folder objects from Get-ArchivedCycleEntry'
        Assert-True ($calls -notcontains 'Get-Item') 'the merge must not look an archived name up again'
    }

    It 'honors the local-only listing without reading the archive (<Mode>)' -TestCases @(
        @{ Mode = 'local only'; Query = 'true'; ArchiveCalls = 0; Names = 'local-cycle' }
        @{ Mode = 'default'; Query = $null; ArchiveCalls = 1; Names = 'archived-cycle,local-cycle' }
        @{ Mode = 'explicit merged'; Query = 'false'; ArchiveCalls = 1; Names = 'archived-cycle,local-cycle' }
    ) {
        param($Query, $ArchiveCalls, $Names)
        $merge = $script:ServerAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.IfStatementAst] -and
                $n.Clauses[0].Item1.Extent.Text -eq '$path -eq ''log'' -or $path -eq ''log/'''
            }, $true) | Select-Object -First 1
        $module = New-Module -ScriptBlock {
            $script:ArchiveCalls = 0
            function Get-ArchivedCycleEntry {
                $script:ArchiveCalls++
                [pscustomobject]@{ Name = 'archived-cycle'; PSIsContainer = $true }
                [pscustomobject]@{ Name = 'local-cycle'; PSIsContainer = $true }
            }
        }
        try {
            $result = & $module {
                param($MergeText, $LocalOnly, $IdentityText)
                . ([scriptblock]::Create($IdentityText))
                $path = 'log/'
                $req = [pscustomobject]@{ QueryString = @{ localOnly = $LocalOnly } }
                $entries = @([pscustomobject]@{ Name = 'local-cycle'; PSIsContainer = $true })
                $null = $path, $req # Read by the lifted handler in this scope.
                . ([scriptblock]::Create($MergeText))
                [pscustomobject]@{ Calls = $script:ArchiveCalls; Names = ($entries.Name -join ',') }
            } $merge.Extent.Text $Query (Get-ServerFunctionText -Name 'ConvertTo-ArchiveRelativePath')
            Assert-Equal $ArchiveCalls $result.Calls 'local-only backfill discovery must never enumerate the network archive'
            Assert-StringEqual $Names $result.Names 'the regular index still merges and deduplicates archive folders'
        } finally { Remove-Module $module -ErrorAction SilentlyContinue }
    }

    It 'lists a cycle kept locally as <Mode> once, not again as its archive copy' -TestCases @(
        @{ Mode = 'aborted'; Suffix = '.aborted.2001-02-03T04-05-06Z' }
        @{ Mode = 'incomplete'; Suffix = '.incomplete' }
    ) {
        param($Suffix)
        # Pool storage names its copy by the cycle's stable identity, while the
        # host keeps the folder under a lifecycle suffix. Compared by leaf name
        # the two never match, so a copy-mode host would list the cycle twice.
        $merge = $script:ServerAst.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.IfStatementAst] -and
                $n.Clauses[0].Item1.Extent.Text -eq '$path -eq ''log'' -or $path -eq ''log/'''
            }, $true) | Select-Object -First 1
        $module = New-Module -ScriptBlock {
            function Get-ArchivedCycleEntry {
                [pscustomobject]@{ Name = '000100.2001-02-01.00-00-00.a0b1c2d3e4f5061728394a5b6c7d8e9f'; PSIsContainer = $true }
                [pscustomobject]@{ Name = '000123.2001-02-02.23-00-00.a0b1c2d3e4f5061728394a5b6c7d8e9f'; PSIsContainer = $true }
            }
        }
        $local = '000123.2001-02-02.23-00-00.a0b1c2d3e4f5061728394a5b6c7d8e9f' + $Suffix
        try {
            $names = & $module {
                param($MergeText, $IdentityText, $LocalName)
                . ([scriptblock]::Create($IdentityText))
                $path = 'log/'
                $req = [pscustomobject]@{ QueryString = @{ localOnly = $null } }
                $entries = @(
                    [pscustomobject]@{ Name = $LocalName; PSIsContainer = $true }
                    [pscustomobject]@{ Name = 'cycle.events.ndjson'; PSIsContainer = $false })
                $null = $path, $req # Read by the lifted handler in this scope.
                . ([scriptblock]::Create($MergeText))
                $entries.Name -join ','
            } $merge.Extent.Text (Get-ServerFunctionText -Name 'ConvertTo-ArchiveRelativePath') $local
            Assert-StringEqual "000100.2001-02-01.00-00-00.a0b1c2d3e4f5061728394a5b6c7d8e9f,$local,cycle.events.ndjson" $names `
                'the local folder stands for its archive copy, and a cycle only the archive holds is still listed'
        } finally { Remove-Module $module -ErrorAction SilentlyContinue }
    }
}

Describe 'the listener liveness lease' {
    BeforeAll {
        function Read-LeaseRecord {
            param([string]$Path)
            [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
        }
        function Set-LeaseRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a lease file into the case''s scratch directory.')]
            param([string]$Path, [int]$ProcessId = $PID, [string]$State, [long]$Tick, [long]$StartTimeUnixMs = 0, [string]$Route = '')
            if (-not $StartTimeUnixMs) { $StartTimeUnixMs = [DateTimeOffset]::new((Get-Process -Id $ProcessId).StartTime).ToUnixTimeMilliseconds() }
            $record = [ordered]@{ schemaVersion = 1; pid = $ProcessId; startTimeUnixMs = $StartTimeUnixMs; state = $State; route = $Route
                sinceUtc = ''; sinceTick = $Tick; renewedUtc = ''; renewedTick = $Tick; served = 3 }
            [IO.File]::WriteAllText($Path, ($record | ConvertTo-Json -Compress))
        }
    }

    It 'writes on every change a reader must see and holds back the rest' {
        $path = Join-Path $TestDrive 'policy.lease.json'
        $lease = New-StatusServiceLease -Path $path
        $t = [long]1000000
        Assert-True (Update-StatusServiceLease -Lease $lease -State idle -NowTick $t -Confirm:$false) 'the first idle state is written'
        Assert-False (Update-StatusServiceLease -Lease $lease -State idle -NowTick ($t + 9000) -Confirm:$false) 'an idle lease renews every ten seconds, not sooner'
        Assert-True (Update-StatusServiceLease -Lease $lease -State busy -Route 'archive/a.zip' -NowTick ($t + 9500) -Confirm:$false) 'a request right after a renewal is still written'
        $record = Read-LeaseRecord $path
        Assert-Equal 'busy' $record.state
        Assert-Equal 'archive/a.zip' $record.route
        Assert-Equal ($t + 9500) $record.sinceTick
        Assert-False (Update-StatusServiceLease -Lease $lease -State idle -NowTick ($t + 10500) -Confirm:$false) 'idle waits two seconds after a request'
        Assert-False (Update-StatusServiceLease -Lease $lease -State busy -Route 'b' -NowTick ($t + 11000) -Confirm:$false) 'a request within five seconds keeps the earlier stamp'
        Assert-True (Update-StatusServiceLease -Lease $lease -State busy -Route 'c' -NowTick ($t + 15000) -Confirm:$false) 'a request five seconds on restamps'
        Assert-Equal ($t + 15000) (Read-LeaseRecord $path).sinceTick
        Assert-True (Update-StatusServiceLease -Lease $lease -State idle -NowTick ($t + 17500) -Confirm:$false) 'idle is written once the request has been done for two seconds'
        $record = Read-LeaseRecord $path
        Assert-Equal 'idle' $record.state
        Assert-Equal '' $record.route
        Assert-Equal $PID $record.pid
        Assert-Equal 3 $record.served
        Assert-True (Update-StatusServiceLease -Lease $lease -State idle -NowTick ($t + 27500) -Confirm:$false) 'an idle lease is renewed after ten seconds'
        Assert-Equal ($t + 27500) (Read-LeaseRecord $path).renewedTick
    }

    It 'reports a write it could not make' {
        $lease = New-StatusServiceLease -Path (Join-Path $TestDrive 'no-such-dir/x.lease.json')
        Assert-False (Update-StatusServiceLease -Lease $lease -State idle -Confirm:$false)
        Assert-True $lease.WriteFailed
    }

    It 'reads <Case>' -TestCases @(
        @{ Case = 'a fresh idle lease as alive'; State = 'idle'; AgeMs = 30000; Expected = 'alive' }
        @{ Case = 'an idle lease past its renewals as wedged'; State = 'idle'; AgeMs = 91000; Expected = 'wedged' }
        @{ Case = 'a request under the ceiling as busy'; State = 'busy'; AgeMs = 590000; Expected = 'busy' }
        @{ Case = 'a request past the ceiling as wedged'; State = 'busy'; AgeMs = 601000; Expected = 'wedged' }
    ) {
        param($State, $AgeMs, $Expected)
        $path = Join-Path $TestDrive "verdict-$State-$AgeMs.json"
        $now = [long]50000000
        Set-LeaseRecord -Path $path -State $State -Tick ($now - $AgeMs) -Route 'log/x'
        $verdict = Get-StatusServiceLeaseVerdict -Path $path -ProcessId $PID -NowTick $now
        Assert-Equal $Expected $verdict.Verdict
        Assert-Equal ([long][Math]::Floor($AgeMs / 1000)) $verdict.AgeSeconds
        Assert-Equal $State $verdict.State
    }

    It 'has no evidence from a missing lease, another process''s, or an earlier process behind the same PID' {
        $path = Join-Path $TestDrive 'unknown.lease.json'
        Assert-Equal 'lease-missing' (Get-StatusServiceLeaseVerdict -Path $path -ProcessId $PID).Reason
        Set-LeaseRecord -Path $path -State idle -Tick ([Environment]::TickCount64)
        Assert-Equal 'lease-other-process' (Get-StatusServiceLeaseVerdict -Path $path -ProcessId ($PID + 1)).Reason
        Set-LeaseRecord -Path $path -State idle -Tick ([Environment]::TickCount64) -StartTimeUnixMs 1000
        $recycled = Get-StatusServiceLeaseVerdict -Path $path -ProcessId $PID
        Assert-Equal 'unknown' $recycled.Verdict
        Assert-Equal 'lease-other-process' $recycled.Reason
        [IO.File]::WriteAllText($path, '{ not json')
        Assert-Equal 'lease-unreadable' (Get-StatusServiceLeaseVerdict -Path $path -ProcessId $PID).Reason
    }

    It 'replaces the listener only on a second wedged pass that the probe confirms, and then waits before trying again' {
        $runtime = Join-Path $TestDrive 'watch-runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        [IO.File]::WriteAllText((Join-Path $runtime 'server.pid'), "$PID")
        $lease = Join-Path $runtime 'server.lease.json'
        $now = [long]90000000
        $state = @{ WedgedPasses = 0 }
        $script:Replaced = 0
        $script:ProbeAnswers = $false
        $probe = { $script:ProbeAnswers }
        $replace = { $script:Replaced++; 0 }
        Set-LeaseRecord -Path $lease -State idle -Tick ($now - 10000)
        Assert-Equal 'ok' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
        Set-LeaseRecord -Path $lease -State idle -Tick ($now - 200000)
        Assert-Equal 'wedged-pending' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
        $script:ProbeAnswers = $true
        Assert-Equal 'answered' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
        Assert-Equal 0 $script:Replaced 'a listener that answers is never replaced'
        $script:ProbeAnswers = $false
        Assert-Equal 'wedged-pending' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
        Assert-Equal 'replaced' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
        Assert-Equal 1 $script:Replaced
        $null = Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick ($now + 1000) -InformationAction SilentlyContinue
        Assert-Equal 'throttled' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick ($now + 2000) -InformationAction SilentlyContinue)
        Assert-Equal 1 $script:Replaced 'no second attempt inside the retry window'
        Assert-Equal 'replace-failed' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace { 2 } -NowTick ($now + 301000) -InformationAction SilentlyContinue)
        Remove-Item -LiteralPath (Join-Path $runtime 'server.pid')
        Assert-Equal 'no-listener' (Invoke-StatusListenerWatch -RuntimeDir $runtime -State $state -Probe $probe -Replace $replace -NowTick $now -InformationAction SilentlyContinue)
    }

    It 'renews the lease from the listener loop and stamps each request' {
        $script:ServerText | Should -Match ([regex]::Escape("`$script:ServerLease = New-StatusServiceLease -Path (Join-Path `$runtimeDir 'server.lease.json')"))
        $loop = $script:ServerText.Substring($script:ServerText.IndexOf('while ($listener.IsListening) {', [StringComparison]::Ordinal))
        $idle = $loop.IndexOf('Update-StatusServiceLease -Lease $script:ServerLease -State idle', [StringComparison]::Ordinal)
        $wait = $loop.IndexOf('[System.Threading.Tasks.Task]::WaitAny(', [StringComparison]::Ordinal)
        $busy = $loop.IndexOf('Update-StatusServiceLease -Lease $script:ServerLease -State busy -Route $path', [StringComparison]::Ordinal)
        $route = $loop.IndexOf("if (`$path -eq 'metrics')", [StringComparison]::Ordinal)
        Assert-True ($idle -ge 0 -and $idle -lt $wait) 'the idle lease is renewed before every wait'
        Assert-True ($busy -gt $wait -and $busy -lt $route) 'each request is stamped before any route runs'
        $loop | Should -Match '\$waitMs = 15000' -Because 'the loop wakes to renew the lease even with no request'
    }
}

Describe 'the host-address beacon watches the listener' {
    It 'runs one watch pass per loop and replaces through the non-destructive start' {
        $beacon = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'test/modules/Invoke-HostAddressBeacon.ps1'))
        $beacon | Should -Match ([regex]::Escape('Invoke-StatusListenerWatch -RuntimeDir $RuntimeDir -State $listenerWatch -Probe $probeListener -Replace $replaceListener'))
        $beacon | Should -Match ([regex]::Escape("'-NonDestructive', '-ReplaceWedged'"))
        $beacon | Should -Not -Match 'Start-StatusService\.ps1''\)[^\r\n]*-Restart' -Because 'the replacement must not run the full start''s sweeps'
    }
}
