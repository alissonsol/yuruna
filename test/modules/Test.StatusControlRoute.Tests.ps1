<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42798304-85e4-4102-8026-ce168ff64fd3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service route host-refresh body-reader pester
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
    them: bounded body reads, the refresh body schema, the reply table, the
    capability summary, worker argument vectors, the diagnostic decision, the
    private worker directory, and the served-tree deny-lists.
.DESCRIPTION
    The listener handles one request at a time, so these decisions have to be
    cheap, deterministic and fail closed: a body that never finishes must not
    park the loop, a body that names a local-only safety switch must be
    refused whatever its spelling, an admission record must map to exactly one
    documented reply, and a worker vector must bind against the script it
    launches before anything is started.

    Reads use real loopback sockets, the transport the listener reads from,
    so a pending read is genuinely pending and a trickled body genuinely
    arrives byte by byte. Worker-directory cases run in a child process with a
    scratch HOME, because $HOME cannot be rebound in this one. The generated
    server is expanded from the launcher exactly as the launcher expands it.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.StatusControlRoute.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'

function Get-GeneratedServerText {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $lines = [IO.File]::ReadAllLines($script:ServicePath)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^\$serverScript = @"$') { $start = $i + 1; continue }
        if ($start -ge 0 -and $lines[$i] -match '^"@$') { $end = $i - 1; break }
    }
    if ($start -lt 0 -or $end -lt $start) { throw 'could not find the server here-string in the launcher' }
    return $ExecutionContext.InvokeCommand.ExpandString((($lines[$start..$end]) -join "`n"))
}
$script:ServerText = Get-GeneratedServerText
$parseErrors = $null
$script:ServerAst = [System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$parseErrors)
$script:ServerParseErrors = @($parseErrors)

function Get-ServerFunctionText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $wanted = $Name
    $found = $script:ServerAst.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
        }.GetNewClosure(), $true) | Select-Object -First 1
    if (-not $found) { throw "the generated server defines no $Name" }
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
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $client.Connect([System.Net.IPAddress]::Loopback, $listener.LocalEndpoint.Port)
        $server = $listener.AcceptTcpClient()
    } finally { $listener.Stop() }
    return [pscustomobject]@{ Writer = $client; WriterStream = $client.GetStream(); Reader = $server; ReaderStream = $server.GetStream() }
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
            Assert-True ($watch.ElapsedMilliseconds -lt 50) "an update with nothing to consume took $($watch.ElapsedMilliseconds) ms"
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
        $pair = New-SocketPair
        try {
            $read = New-StatusBoundedBodyRead -Stream $pair.ReaderStream -NowMs 0
            $pair.Reader.Dispose()
            Wait-TaskSettled -BodyRead $read -Milliseconds 2000
            Assert-StringEqual 'error' (Update-StatusBoundedBodyRead -BodyRead $read -NowMs 1)
            Close-StatusBoundedBodyRead -BodyRead $read
            Close-StatusBoundedBodyRead -BodyRead $read
            Close-StatusBoundedBodyRead -BodyRead $null
        } finally { Close-SocketPair $pair }
        $disposed = [System.IO.MemoryStream]::new()
        $disposed.Dispose()
        $unusable = New-StatusBoundedBodyRead -Stream $disposed -NowMs 0
        Assert-StringEqual 'error' (Update-StatusBoundedBodyRead -BodyRead $unusable -NowMs 1) 'a read on an unusable stream is an error, not a throw'
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

Describe 'the refresh body has one closed schema' {

    It 'accepts a complete remote body and a partial loopback body' {
        $remote = ConvertFrom-HostRefreshRequestBody -Remote -AllowedRungName $script:AllowedRung `
            -Bytes (ConvertTo-BodyByte ('{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"start-if-stopped"}'))
        Assert-True $remote.Valid $remote.Reason
        Assert-StringEqual $script:ValidId $remote.RequestId
        Assert-StringEqual 'start-if-stopped' $remote.MaxRung
        Assert-True $remote.RequestIdSupplied
        $loopback = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{}')
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
            $result = ConvertFrom-HostRefreshRequestBody -Remote -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $body)
            Assert-False $result.Valid "remote body $body must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
        }
    }

    It 'refuses every request id that is not the canonical lowercase form' {
        foreach ($id in @($script:ValidId.ToUpperInvariant(), ('{' + $script:ValidId + '}'), $script:ValidId.Replace('-', ''), 'not-a-guid', '')) {
            $result = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte ('{"requestId":"' + $id + '"}'))
            Assert-False $result.Valid "request id '$id' must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
            Assert-StringEqual 'requestId' $result.Field
        }
    }

    It 'refuses a tier other than restart and a rung above the restart tier or unknown' {
        foreach ($body in @('{"tier":"full"}', '{"tier":"Restart"}', '{"maxRung":"reapply-settings"}', '{"maxRung":"reinstall"}', '{"maxRung":"reboot"}', '{"maxRung":"teleport"}', '{"maxRung":"Probe"}')) {
            $result = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $body)
            Assert-False $result.Valid "$body must be refused"
            Assert-StringEqual 'invalid_value' $result.Reason
        }
    }

    It 'refuses every spelling of a local-only safety switch as forbidden' {
        foreach ($name in @('force', 'Force', 'FORCE', '-Force', 'allowHardStop', 'AllowHardStop', 'hardStop', 'hard_stop', 'hard-stop',
                'restoreServiceVmName', 'leaveStoppedServiceVmName', 'configPath', 'ConfigPath', 'x_force_y')) {
            $result = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte ('{"' + $name + '":true}'))
            Assert-False $result.Valid "$name must be refused"
            Assert-StringEqual 'forbidden_field' $result.Reason "$name names a local-only switch"
        }
    }

    It 'refuses unknown keys as unsupported and case-variant duplicates' {
        $unknown = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","note":"x"}')
        Assert-StringEqual 'unsupported_field' $unknown.Reason
        Assert-StringEqual 'note' $unknown.Field
        $cased = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"Tier":"restart"}')
        Assert-StringEqual 'unsupported_field' $cased.Reason 'keys are case-sensitive'
        $duplicate = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","TIER":"restart"}')
        Assert-False $duplicate.Valid
        Assert-StringEqual 'invalid_json' $duplicate.Reason 'a name repeated in another casing is ambiguous'
        $exact = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"tier":"restart","tier":"restart"}')
        Assert-StringEqual 'invalid_json' $exact.Reason
    }

    It 'refuses non-object roots, deep nesting, non-string values, comments, trailing commas, a BOM and invalid UTF-8' {
        foreach ($text in @('[]', '"restart"', '42', 'null', '{"a":{"b":{"c":{"d":{"e":1}}}}}', '{"tier":1}', '{"tier":null}',
                '{"tier":"restart",}', '{/*c*/"tier":"restart"}', '', '{')) {
            $result = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte $text)
            Assert-False $result.Valid "'$text' must be refused"
        }
        $bom = [byte[]]@(0xEF, 0xBB, 0xBF) + (ConvertTo-BodyByte '{}')
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes $bom).Reason
        $invalidUtf8 = [byte[]]@(0x7B, 0x22, 0xC3, 0x28, 0x22, 0x3A, 0x31, 0x7D)
        Assert-StringEqual 'invalid_json' (ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes $invalidUtf8).Reason
    }

    It 'never echoes an arbitrary field name' {
        $result = ConvertFrom-HostRefreshRequestBody -AllowedRungName $script:AllowedRung -Bytes (ConvertTo-BodyByte '{"<script>alert(1)</script>":1}')
        Assert-StringEqual 'unsupported_field' $result.Reason
        Assert-StringEqual 'field' $result.Field 'a name outside the echo shape is replaced'
    }

    It 'accepts only a JSON content type with a UTF-8 charset or none' {
        foreach ($ok in @('application/json', 'application/json; charset=utf-8', 'Application/JSON;charset=UTF-8', 'application/json; charset="utf-8"')) {
            Assert-True (Test-HostRefreshContentType -ContentType $ok) $ok
        }
        foreach ($bad in @('', 'text/plain', 'application/json; charset=latin1', 'application/jsonx', 'application/x-www-form-urlencoded', 'application/json; boundary=x')) {
            Assert-False (Test-HostRefreshContentType -ContentType $bad) $bad
        }
    }
}

Describe 'every admission decision maps to exactly one documented reply' {

    It 'maps spawn with a launch to 202 spawned and without one to 503 launcher_failed' {
        $admission = [pscustomobject]@{ Decision = 'spawn'; RequestId = $script:ValidId; Ceiling = 'start-if-stopped' }
        $ok = Get-HostRefreshAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $true; Reason = 'launched' })
        Assert-Equal 202 $ok.StatusCode
        Assert-StringEqual 'spawned' $ok.Body.action
        Assert-True $ok.Body.ok
        Assert-StringEqual $script:ValidId $ok.Body.requestId
        Assert-StringEqual 'start-if-stopped' $ok.Body.ceiling
        Assert-StringEqual '/runtime/host-refresh.state.json' $ok.Body.stateUrl
        Assert-StringEqual '' $ok.MessageKey
        $failed = Get-HostRefreshAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $false; Reason = 'launcher-failed' })
        Assert-Equal 503 $failed.StatusCode
        Assert-StringEqual 'launcher_failed' $failed.Body.reason
        Assert-StringEqual $script:ValidId $failed.Body.requestId 'a failed launch keeps the queued request identity so it can be retried'
        Assert-StringEqual '/runtime/host-refresh.state.json' $failed.Body.stateUrl
        Assert-StringEqual 'status.api_worker_launcher_failed' $failed.MessageKey
        Assert-StringEqual 'launcher_failed' $failed.MessageArguments.reason
        $none = Get-HostRefreshAdmissionReply -Admission $admission -Launch $null
        Assert-Equal 503 $none.StatusCode 'a spawn with no launch result never reads as spawned'
    }

    It 'maps already-claimed, completed, busy, policy-mismatch, stored and unavailable' {
        $claimed = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'already-claimed'; RequestId = $script:ValidId }) -Ceiling 'reclaim'
        Assert-Equal 202 $claimed.StatusCode
        Assert-StringEqual 'already_claimed' $claimed.Body.action
        Assert-StringEqual 'reclaim' $claimed.Body.ceiling
        $completed = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'completed'; RequestId = $script:ValidId; State = 'completed'; Verdict = 'partial' })
        Assert-Equal 200 $completed.StatusCode
        Assert-True $completed.Body.ok 'ok means the record was retrieved, not that the repair succeeded'
        Assert-StringEqual 'partial' $completed.Body.verdict
        Assert-StringEqual 'completed' $completed.Body.action
        $healthy = Get-HostRefreshAdmissionReply -Admission @{ Decision = 'completed'; RequestId = $script:ValidId; State = 'recovery-pending'; Verdict = 'already-healthy' }
        Assert-StringEqual 'already_healthy' $healthy.Body.verdict 'private tokens cross the wire underscored'
        Assert-StringEqual 'recovery_pending' $healthy.Body.state
        $busy = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; RequestId = $script:ValidId; ActiveRequestId = 'aaaa'; ActiveKind = 'host-refresh' })
        Assert-Equal 409 $busy.StatusCode
        Assert-StringEqual 'busy' $busy.Body.reason
        Assert-StringEqual 'host_refresh' $busy.Body.activeKind
        Assert-StringEqual 'aaaa' $busy.Body.activeRequestId
        Assert-StringEqual '/runtime/host-refresh.state.json' $busy.Body.stateUrl
        $busyCycle = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'busy'; ActiveRequestId = 'bbbb'; ActiveKind = 'start-cycle' })
        Assert-StringEqual 'start_cycle' $busyCycle.Body.activeKind
        Assert-StringEqual '/runtime/start-cycle.state.json' $busyCycle.Body.stateUrl 'a start-cycle holder is observed at its own state file'
        $conflict = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'policy-mismatch'; RequestId = $script:ValidId })
        Assert-Equal 409 $conflict.StatusCode
        Assert-StringEqual 'request_conflict' $conflict.Body.reason
        $stored = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'stored'; RequestId = $script:ValidId; State = 'refused'; Verdict = 'refused' })
        Assert-Equal 409 $stored.StatusCode
        Assert-StringEqual 'request_closed' $stored.Body.reason
        Assert-StringEqual 'refused' $stored.Body.state
        Assert-StringEqual 'refused' $stored.Body.verdict
        $unavailable = Get-HostRefreshAdmissionReply -Admission ([pscustomobject]@{ Decision = 'unavailable'; Reason = 'journal-unreadable' })
        Assert-Equal 503 $unavailable.StatusCode
        Assert-StringEqual 'admission_unavailable' $unavailable.Body.reason
        Assert-StringEqual 'journal_unreadable' $unavailable.MessageArguments.reason
    }

    It 'answers an unrecognized or missing decision with 500, never a success' {
        foreach ($admission in @($null, [pscustomobject]@{ Decision = 'SPAWN' }, [pscustomobject]@{ Decision = 'maybe' }, @{})) {
            $reply = Get-HostRefreshAdmissionReply -Admission $admission -Launch ([pscustomobject]@{ Launched = $true })
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
        $refreshBusy = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'busy'; ActiveKind = 'host-refresh'; ActiveRequestId = $script:ValidId }) -OperationId $id
        Assert-Equal 409 $refreshBusy.StatusCode
        Assert-StringEqual 'host_refresh' $refreshBusy.Body.activeKind
        Assert-StringEqual '/runtime/host-refresh.state.json' $refreshBusy.Body.stateUrl
        Assert-StringEqual 'status.api_host_refresh_busy' $refreshBusy.MessageKey
        $cycleBusy = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'busy'; ActiveKind = 'start-cycle'; ActiveRequestId = 'other' }) -OperationId $id
        Assert-StringEqual 'start_cycle' $cycleBusy.Body.activeKind
        Assert-StringEqual 'status.api_another_start_cycle_request_is_in_progress_3f51d139' $cycleBusy.MessageKey 'an older page still reads the sentence it always read'
        $unavailable = Get-StartCycleAdmissionReply -Reservation ([pscustomobject]@{ Decision = 'unavailable'; Reason = 'journal-corrupt' }) -OperationId $id
        Assert-Equal 503 $unavailable.StatusCode
        Assert-StringEqual 'admission_unavailable' $unavailable.Body.reason
        Assert-Equal 500 (Get-StartCycleAdmissionReply -Reservation $null -OperationId $id).StatusCode
    }
}

Describe 'the capability summary is compact and fails closed' {

    It 'copies an available capability and adds remote' {
        $summary = Get-HostRefreshControlSummary -ListenerReady $true -Remote 'missing' -Capability ([ordered]@{
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
            $summary = Get-HostRefreshControlSummary -ListenerReady $true -Remote 'unqualified' -Capability $case.Capability
            Assert-StringEqual 'unavailable' $summary.availability
            Assert-StringEqual '' $summary.ceiling 'an unavailable capability never names a ceiling'
            Assert-StringEqual $case.Reason $summary.reason
        }
        $pending = Get-HostRefreshControlSummary -ListenerReady $true -Remote 'bogus' -Capability @{ protocol = 1; availability = 'unavailable'; state = 'recovery-pending' }
        Assert-StringEqual 'recovery_pending' $pending.state
        Assert-StringEqual 'unqualified' $pending.remote 'an unknown remote state reads as unqualified'
    }

    It 'applies the listener refusal over an available capability' {
        $capability = @{ protocol = 1; availability = 'available'; ceiling = 'reclaim'; reason = ''; state = 'active' }
        $missing = Get-HostRefreshControlSummary -Capability $capability -ListenerReady $false -Remote 'missing'
        Assert-StringEqual 'unavailable' $missing.availability
        Assert-StringEqual 'listener_dependency_missing' $missing.reason
        Assert-StringEqual 'active' $missing.state 'the request state is still reported'
        $noHost = Get-HostRefreshControlSummary -Capability $capability -ListenerReady $false -ListenerReason 'unsupported_host' -Remote 'missing'
        Assert-StringEqual 'unsupported_host' $noHost.reason
    }

    It 'stays within 256 bytes, and the whole control-status reply within 1024' {
        $longest = Get-HostRefreshControlSummary -ListenerReady $false -ListenerReason ('a' * 48) -Remote 'unqualified' `
            -Capability @{ protocol = 1; availability = 'available'; ceiling = 'restart-if-hung'; state = 'recovery_pending' }
        $json = $longest | ConvertTo-Json -Compress
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($json) -le 256) "summary is $([System.Text.Encoding]::UTF8.GetByteCount($json)) bytes"
        $available = Get-HostRefreshControlSummary -ListenerReady $true -Remote 'provisioned' `
            -Capability @{ protocol = 1; availability = 'available'; ceiling = 'restart-broker'; state = 'recovery_pending' }
        $payload = @{
            ok = $true; tokenConfigured = $true; tokenTag = ('f' * 64); utcNow = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); refresh = $available
        } | ConvertTo-Json -Compress
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($payload) -lt 1024) "control-status is $([System.Text.Encoding]::UTF8.GetByteCount($payload)) bytes"
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
            $previousHome = $env:HOME
            try {
                $env:HOME = $homeDir
                $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $probe 2>&1 | Out-String
            } finally {
                if ($null -eq $previousHome) { Remove-Item Env:HOME -ErrorAction SilentlyContinue } else { $env:HOME = $previousHome }
            }
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
            $owned = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', $serverScript -PassThru
            $other = Start-Process -FilePath $pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', $otherScript -PassThru
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

    It 'guards the refresh route with the always-on cross-site check and answers 405 through the shared error' {
        Assert-Match "'control/host-refresh'" (($script:ServerText -split '\$csrfWriteProtected')[0]) 'control/host-refresh must be in the always-protected list'
        $route = Get-ServerRouteText -Route 'control/host-refresh'
        Assert-Match "Send-JsonError -Response \`$res -StatusCode 405 -Request \`$req -Key 'status.api_post_required_663cc07c'" $route
        Assert-True ($route -notmatch 'ReadToEnd') 'the refresh route must not read its body synchronously'
        Assert-True ($route -match 'Add-PendingRequestBody') 'the refresh route hands its body to the bounded reader'
        Assert-True ($route -match '\$pendingBodies\.Count -ge 4') 'at most four bodies are read at once'
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
        Assert-True ($startCycleHandler -match 'Request-HostRefreshStartCycleReservation') 'start-cycle reserves before launching'
        Assert-True ($startCycleHandler -match '(?s)finally\s*\{.*Save-StatusLaunchOutcome.*Set-HostRefreshStartCycleLaunch') 'every reserved launch is recorded from a finally'
        Assert-True ((Get-ServerFunctionText -Name 'Invoke-HostRefreshRequest') -match '(?s)finally\s*\{.*Save-StatusLaunchOutcome.*Set-HostRefreshLaunchOutcome') 'every admitted launch is recorded from a finally'
    }

    It 'launches workers only with fixed argument vectors checked against the script' {
        $worker = Get-ServerFunctionText -Name 'Start-StatusWorker'
        Assert-True ($worker -match 'Test-StatusWorkerArgument -ScriptPath \$ScriptPath -ArgumentList \$ArgumentList') 'every vector is bound-checked before launch'
        Assert-True ($worker -match 'TotalMilliseconds 5000') 'the launch is bounded'
        $refresh = Get-ServerFunctionText -Name 'Invoke-HostRefreshRequest'
        Assert-True ($refresh -match 'New-HostRefreshWorkerArgumentList -RepoRoot \$workerRoot -RequestId \$refreshRequestId -Budget') 'the refresh vector comes from the fixed builder'
        $refreshCode = (@($refresh -split "`r?`n" | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n")
        Assert-True ($refreshCode -notmatch 'X-Yuruna-Control') 'the refresh proof is never read from the legacy header'
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
        foreach ($name in @('Request-HostRefreshAdmission', 'Set-HostRefreshLaunchOutcome', 'Get-HostRefreshPrivateWorkDir', 'Get-HostRefreshCapability',
                'New-HostRefreshBudget', 'New-HostRefreshWorkerArgumentList', 'Publish-HostRefreshQueuedState', 'Get-VirtualizationRepairRung',
                'Request-HostRefreshStartCycleReservation', 'Set-HostRefreshStartCycleLaunch', 'Start-YurunaDetachedProcess',
                'Test-YurunaHostRefreshAuthorization', 'Get-YurunaHostRefreshRemoteState', 'Get-StatusWorkerDirectory', 'Get-HostDiagnosticRouteState',
                'Save-StatusLaunchOutcome', 'Get-StatusWorkerTranscriptStem')) {
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
        $private = @('host-refresh/host-refresh.journal', 'x/host-refresh/host-refresh.lock', 'host-refresh.journal', 'host-refresh.journal.prev',
            'host-refresh.request.json', 'host-refresh.request.v1.json', 'host-refresh.lock', 'host-refresh.admission.lock', 'runner-gate.record',
            'service-census.record.prev', 'abc.handshake.json', 'x.hop.json', 'x.hop.json.ack.json', 'runner-handoff.0123.ack.json',
            'remote-verifier.key', 'authority/operator.credential', 'work/stdin.empty.tmp')
        $public = @('host-refresh.state.json', 'start-cycle.state.json', 'status.json', 'runner.refresh-evidence.json', 'runner.cycle.json',
            'inner.start', 'runner.refresh-gated.json')
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
    }
}

Describe 'the refresh request handler maps each path to its documented reply' {

    BeforeAll {
        $definitions = @(
            (Get-ServerFunctionText -Name 'Send-JsonReply'),
            (Get-ServerFunctionText -Name 'Invoke-HostRefreshRequest'),
            (Get-ServerFunctionText -Name 'Set-ResponseLocaleHeaders')
        ) -join "`n"
        $script:RefreshHarness = [scriptblock]::Create("param([hashtable]`$Case)`n" + $definitions + "`n" + @'
$serverHostType = 'host.ubuntu.kvm'
$runtimeDir = '/scratch/runtime'
$workerRoot = '/scratch/repo'
$hostRefreshEntry = '/scratch/repo/test/lab/Invoke-HostRefresh.ps1'
$hostRefreshStateUrl = '/runtime/host-refresh.state.json'
$startCycleStateUrl = '/runtime/start-cycle.state.json'
$calls = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $calls.Add("err:$msg") }
function Resolve-PageLocale { param($AcceptLanguage) $null = $AcceptLanguage; return @{ Tag = 'en-US'; Direction = 'ltr' } }
function Get-VirtualizationRepairRung { param($HostType) $null = $HostType
    foreach ($pair in @(@('probe', 0), @('reclaim', 1), @('start-if-stopped', 2), @('restart-if-hung', 3), @('restart-broker', 4), @('reapply-settings', 5))) {
        [pscustomobject]@{ Name = $pair[0]; Order = $pair[1] } } }
function Get-HostRefreshSummaryCached { return $Case.Summary }
function Import-RouteModule { param($ModuleRelativePath, $RequiredCommand) $null = $ModuleRelativePath, $RequiredCommand; return [bool]$Case.VerifierLoads }
function Get-ArchiveHostId { return '42af6f0d32ad41c48cffd47c91c16b2d' }
function Test-YurunaHostRefreshAuthorization { param($ProofWire, $HostId, $RequestId, $Tier, $MaxRung)
    $calls.Add("auth:$ProofWire|$HostId|$RequestId|$Tier|$MaxRung"); return $Case.Authorization }
function Request-HostRefreshAdmission { param($RequestId, $Channel, $Tier, $MaxRung, $RuntimeDir, $HostType, $AdmissionWaitMilliseconds, [switch]$Confirm)
    $null = $Confirm; $calls.Add("admit:$RequestId|$Channel|$Tier|$MaxRung|$RuntimeDir|$HostType|$AdmissionWaitMilliseconds")
    $record = $Case.Admission.Clone(); if (-not $record.ContainsKey('RequestId')) { $record.RequestId = $RequestId }; return [pscustomobject]$record }
function Get-HostRefreshPrivateWorkDir { return $Case.WorkDir }
function New-HostRefreshBudget { return [pscustomobject]@{ TotalExpiryTick = 1 } }
function New-HostRefreshWorkerArgumentList { param($RepoRoot, $RequestId, $Budget) $null = $Budget; $calls.Add("argv:$RepoRoot|$RequestId")
    if ($Case.ArgvThrows) { throw [System.InvalidOperationException]::new('argument list refused') }
    '-RequestId'; $RequestId }
function Start-StatusWorker { param($Directory, $StdInPath, $ScriptPath, $ArgumentList, $TranscriptStem)
    $calls.Add("launch:$ScriptPath|$($ArgumentList -join ' ')|$TranscriptStem|$Directory"); return $Case.Launch }
# Answers each record attempt from OutcomeReplies in order (saved, refused or
# throw), then saved.
function Set-HostRefreshLaunchOutcome { param($RequestId, $Outcome, $Launch, [switch]$Confirm) $null = $Launch, $Confirm; $calls.Add("outcome:$RequestId|$Outcome")
    $next = 'saved'
    if ($Case.OutcomeReplies -and $Case.OutcomeReplies.Count -gt 0) { $next = [string]$Case.OutcomeReplies[0]; $Case.OutcomeReplies.RemoveAt(0) }
    if ($next -eq 'throw') { throw [System.IO.IOException]::new('journal write failed') }
    return [pscustomobject]@{ Saved = ($next -eq 'saved'); Reason = $next } }
function Publish-HostRefreshQueuedState { param($RuntimeDir, $RequestId, $Channel) $calls.Add("queued:$RuntimeDir|$RequestId|$Channel"); return $true }
$headers = [System.Net.WebHeaderCollection]::new()
$request = [pscustomobject]@{ Headers = $headers; HttpMethod = 'POST' }
$response = [pscustomobject]@{ Headers = [System.Net.WebHeaderCollection]::new(); OutputStream = [System.IO.MemoryStream]::new(); StatusCode = 0; ContentType = ''; ContentLength64 = [long]0; KeepAlive = $true }
$context = [pscustomobject]@{ Request = $request; Response = $response }
Invoke-HostRefreshRequest -RequestContext $context -BodyBytes ([System.Text.Encoding]::UTF8.GetBytes($Case.Body)) -Loopback ([bool]$Case.Loopback) -ProofWire ([string]$Case.Proof)
[pscustomobject]@{ Response = $response; Json = (ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($response.OutputStream.ToArray()))); Calls = @($calls) }
'@)
        $script:WorkDir = New-YurunaTestTempDir -Prefix 'yuruna-route-work'
        $script:Available = [ordered]@{ protocol = 1; availability = 'available'; ceiling = 'start-if-stopped'; reason = ''; remote = 'provisioned'; state = 'idle' }
        function New-RefreshCase {
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
        $got = & $script:RefreshHarness (New-RefreshCase)
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual 'spawned' $got.Json.action
        Assert-Match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' $got.Json.requestId 'loopback gets a generated canonical id'
        Assert-StringEqual 'start-if-stopped' $got.Json.ceiling 'loopback defaults to the advertised ceiling'
        $admit = @($got.Calls | Where-Object { $_ -like 'admit:*' })
        Assert-Equal 1 $admit.Count
        Assert-Match '\|listener\|restart\|start-if-stopped\|/scratch/runtime\|host\.ubuntu\.kvm\|1000$' $admit[0]
        Assert-True (@($got.Calls | Where-Object { $_ -like 'launch:/scratch/repo/test/lab/Invoke-HostRefresh.ps1|-RequestId *' }).Count -eq 1) 'the fixed entry script is launched'
        Assert-True (@($got.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count -eq 1)
        Assert-True (@($got.Calls | Where-Object { $_ -like 'queued:/scratch/runtime|*|listener' }).Count -eq 1)
        Assert-True ([IO.File]::Exists((Join-Path $script:WorkDir 'stdin.empty'))) 'the stdin sentinel is prepared in the private work directory'
    }

    It 'keeps the request queued and answers 503 launcher_failed when the launch fails' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ Launch = [pscustomobject]@{ Launched = $false; Reason = 'hop-failed' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'launcher_failed' $got.Json.reason
        Assert-True ([bool]$got.Json.requestId) 'the reply names the request to retry'
        Assert-True (@($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count -eq 1)
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'queued:*' }).Count 'nothing is published for a worker that never started'
    }

    It 'launches nothing for already-claimed, completed, busy, conflicting or closed requests' {
        foreach ($decision in @('already-claimed', 'completed', 'busy', 'policy-mismatch', 'stored', 'unavailable')) {
            $got = & $script:RefreshHarness (New-RefreshCase @{ Admission = @{ Decision = $decision; ActiveKind = 'host-refresh'; State = 'completed'; Verdict = 'repaired' } })
            Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count "$decision must not launch"
            Assert-True ($got.Response.StatusCode -in @(200, 202, 409, 503)) "$decision answered $($got.Response.StatusCode)"
        }
    }

    It 'refuses an invalid body before admission, naming the field' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ Body = '{"allowHardStop":true}' })
        Assert-Equal 400 $got.Response.StatusCode
        Assert-StringEqual 'forbidden_field' $got.Json.reason
        Assert-StringEqual 'allowHardStop' $got.Json.field
        Assert-StringEqual 'status.api_request_body_invalid' $got.Json.code
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count 'no admission for a refused body'
    }

    It 'refuses when the capability is not available' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ Summary = [ordered]@{ protocol = 1; availability = 'unavailable'; ceiling = ''; reason = 'no_qualified_rung'; remote = 'missing'; state = 'idle' } })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'refresh_unavailable' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'admit:*' }).Count
    }

    It 'authorizes a non-loopback caller from its own proof header and admits it on the remote channel' {
        $body = '{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"reclaim"}'
        $got = & $script:RefreshHarness (New-RefreshCase @{ Loopback = $false; Body = $body; Proof = 'yhr1.proof' })
        Assert-Equal 202 $got.Response.StatusCode
        Assert-StringEqual "auth:yhr1.proof|42af6f0d32ad41c48cffd47c91c16b2d|$($script:ValidId)|restart|reclaim" (@($got.Calls | Where-Object { $_ -like 'auth:*' })[0])
        Assert-Match '\|remote\|restart\|reclaim\|' (@($got.Calls | Where-Object { $_ -like 'admit:*' })[0])
    }

    It 'refuses a non-loopback caller without every key, with a refused proof, or with no verifier' {
        $partial = & $script:RefreshHarness (New-RefreshCase @{ Loopback = $false; Body = '{"tier":"restart"}' })
        Assert-Equal 400 $partial.Response.StatusCode 'a remote body must carry all three keys'
        $body = '{"requestId":"' + $script:ValidId + '","tier":"restart","maxRung":"reclaim"}'
        $refused = & $script:RefreshHarness (New-RefreshCase @{ Loopback = $false; Body = $body; Authorization = @{ Authorized = $false; Reason = 'refresh_proof_expired'; HttpStatus = 403 } })
        Assert-Equal 403 $refused.Response.StatusCode
        Assert-StringEqual 'refresh_proof_expired' $refused.Json.reason
        Assert-StringEqual 'status.api_host_refresh_authorization_refused' $refused.Json.code
        Assert-Equal 0 @($refused.Calls | Where-Object { $_ -like 'admit:*' }).Count
        $noVerifier = & $script:RefreshHarness (New-RefreshCase @{ Loopback = $false; Body = $body; VerifierLoads = $false })
        Assert-Equal 403 $noVerifier.Response.StatusCode
        Assert-StringEqual 'refresh_verifier_unavailable' $noVerifier.Json.reason
    }

    It 'answers 503 private_state_unavailable when the work directory cannot be secured, and closes the admitted launch' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ WorkDir = $null })
        Assert-Equal 503 $got.Response.StatusCode
        Assert-StringEqual 'private_state_unavailable' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count 'the pending launch admission recorded is closed, or the request reads as claimed'
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'queued:*' }).Count
    }

    It 'closes the admitted launch when building the worker vector throws, and still answers 500' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ ArgvThrows = $true })
        Assert-Equal 500 $got.Response.StatusCode
        Assert-StringEqual 'internal_error' $got.Json.reason
        Assert-Equal 0 @($got.Calls | Where-Object { $_ -like 'launch:*' }).Count
        Assert-Equal 1 @($got.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count 'the throw still records the failed launch'
    }

    It 'tries a launch record that did not commit once more, and logs one that never does' {
        $retried = & $script:RefreshHarness (New-RefreshCase @{ OutcomeReplies = [System.Collections.Generic.List[string]]@('admission-busy') })
        Assert-Equal 202 $retried.Response.StatusCode
        Assert-Equal 2 @($retried.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count 'a record that did not commit is tried again'
        Assert-Equal 0 @($retried.Calls | Where-Object { $_ -like 'err:*' }).Count 'a second attempt that commits logs nothing'

        $thrown = & $script:RefreshHarness (New-RefreshCase @{ OutcomeReplies = [System.Collections.Generic.List[string]]@('throw', 'saved') })
        Assert-Equal 202 $thrown.Response.StatusCode 'a record write that throws does not tear the reply'
        Assert-Equal 2 @($thrown.Calls | Where-Object { $_ -like 'outcome:*|started' }).Count

        $lost = & $script:RefreshHarness (New-RefreshCase @{
                Launch = [pscustomobject]@{ Launched = $false; Reason = 'hop-failed' }
                OutcomeReplies = [System.Collections.Generic.List[string]]@('admission-busy', 'journal-unwritable')
            })
        Assert-Equal 503 $lost.Response.StatusCode
        Assert-StringEqual 'launcher_failed' $lost.Json.reason
        Assert-Equal 2 @($lost.Calls | Where-Object { $_ -like 'outcome:*|launch-failed' }).Count
        $logged = @($lost.Calls | Where-Object { $_ -like 'err:control/host-refresh could not record launch outcome*' })
        Assert-Equal 1 $logged.Count 'a launch outcome that never commits is logged'
        Assert-Match 'journal-unwritable' $logged[0]
    }

    It 'keeps an earlier launch transcript of the same attempt' {
        $body = '{"requestId":"' + $script:ValidId + '"}'
        $earlier = Join-Path $script:WorkDir "$($script:ValidId).1.out"
        [IO.File]::WriteAllText($earlier, 'the earlier launch')
        try {
            $got = & $script:RefreshHarness (New-RefreshCase @{ Body = $body })
            Assert-Equal 202 $got.Response.StatusCode
            $launch = @($got.Calls | Where-Object { $_ -like 'launch:*' })
            Assert-Equal 1 $launch.Count
            Assert-True ($launch[0] -like "*|$($script:ValidId).1.2|*") "the relaunch writes new transcripts: $($launch[0])"
        } finally { Remove-Item -LiteralPath $earlier -Force -ErrorAction SilentlyContinue }
    }

    It 'turns a throw into a 500 JSON reply rather than a torn connection' {
        $got = & $script:RefreshHarness (New-RefreshCase @{ Admission = $null })
        Assert-Equal 500 $got.Response.StatusCode
        Assert-StringEqual 'internal_error' $got.Json.reason
        Assert-True (@($got.Calls | Where-Object { $_ -like 'err:control/host-refresh failed:*' }).Count -eq 1) 'the throw is logged'
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
$hostRefreshStateUrl = '/runtime/host-refresh.state.json'
$startCycleStateUrl = '/runtime/start-cycle.state.json'
$calls = [System.Collections.Generic.List[string]]::new()
function Write-ServerErr { param([string]$msg) $calls.Add("err:$msg") }
function Resolve-PageLocale { param($AcceptLanguage) $null = $AcceptLanguage; return @{ Tag = 'en-US'; Direction = 'ltr' } }
function Get-StatusWorkerDirectory { param($Name, $ServedRoot, [switch]$Confirm) $null = $ServedRoot, $Confirm; $calls.Add("directory:$Name"); return $Case.Directory }
function Request-HostRefreshStartCycleReservation { param($OperationId, $RuntimeDir, $AdmissionWaitMilliseconds, [switch]$Confirm)
    $null = $Confirm; $calls.Add("reserve:$OperationId|$RuntimeDir|$AdmissionWaitMilliseconds"); return [pscustomobject]$Case.Reservation }
function Start-StatusWorker { param($Directory, $StdInPath, $ScriptPath, $ArgumentList, $TranscriptStem)
    $null = $StdInPath; $calls.Add("launch:$ScriptPath|$TranscriptStem|$Directory|$($ArgumentList -join ' ')")
    if ($Case.LaunchThrows) { throw [System.InvalidOperationException]::new('launcher exploded') }
    return $Case.Launch }
# Answers each record attempt from RecordReplies in order (saved, refused or
# throw), then saved.
function Set-HostRefreshStartCycleLaunch { param($OperationId, $Generation, $Outcome, $Launch, [switch]$Confirm) $null = $Launch, $Confirm
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
                @{ Decision = 'busy'; Generation = $null; ActiveKind = 'host-refresh'; ActiveRequestId = $script:ValidId; Reason = 'host-refresh-active' },
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
