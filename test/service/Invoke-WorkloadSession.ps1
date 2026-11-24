<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42318f59-c35a-4de6-903f-ead5de41362f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna mcp workload worker session
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
    The worker of the workload MCP server: one process per session.
.DESCRIPTION
    Started by Start-WorkloadMcpServer.ps1 with the client ends of two
    anonymous pipes. It sends hello, then serves one request at a time: each
    method maps to one handler of Test.WorkloadSession.psm1. The engine is not
    loaded here; the session.start handler loads it, so phrases.list answers
    without it.

    Every line written to the reply pipe passes the secret filter and is read
    back before it is written: a registered value can stand anywhere in a
    framed line, also inside its JSON syntax, and a line the filter broke would
    read as a malformed frame and end the session. Such a line is replaced by
    the workload_secret_filter_failed refusal for its own request id.

    While a handler runs, the request pipe is read without blocking through
    the ShouldStop block: a cancel for the current request, a session.end
    request and the end of input stop the operation at its next gate. A
    worker serves one session and exits after it replied to session.end, and
    the lease is given back on every way out.
    See https://yuruna.link/42fffc2c-001f.

    Exit codes: 0 ended, 1 unexpected error or malformed frame, 2 the pipes
    could not be opened.
.PARAMETER RequestPipeHandle
    Client handle of the pipe the front end writes requests to.
.PARAMETER ReplyPipeHandle
    Client handle of the pipe this worker writes frames to.
.PARAMETER SessionId
    The session id the front end chose; hello carries it back.
.PARAMETER SessionDir
    The session folder the front end created.
.PARAMETER RefBase
    The first reference ordinal of this worker.
.PARAMETER ConfigPath
    Test configuration file for the session start.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RequestPipeHandle,
    [Parameter(Mandatory)][string]$ReplyPipeHandle,
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$SessionDir,
    [long]$RefBase = 0,
    [string]$ConfigPath
)

$env:YURUNA_NONINTERACTIVE = '1'
Remove-Item -LiteralPath Env:\YURUNA_CYCLE_CONTEXT -ErrorAction SilentlyContinue
# A Windows console code page prints Chinese and Hebrew catalog text as
# question marks; YURUNA_KEEP_CONSOLE_ENCODING=1 keeps the console's own.
if ($IsWindows -and $env:YURUNA_KEEP_CONSOLE_ENCODING -ne '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../modules/Test.WorkloadProtocol.psm1') -Global -DisableNameChecking

function ConvertTo-WorkloadResultFileText {
    <#
    .SYNOPSIS
        The text of journal.result.json or failure.result.json: the filtered result, or the fixed refusal.
    .DESCRIPTION
        The serialized result passes the secret filter as text and must still
        parse into a dictionary with a boolean ok and hold no registered
        value; otherwise the file receives the workload_secret_filter_failed
        refusal, so the tool that reads it answers that refusal and never a
        text the front end cannot read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Result)
    try {
        $json = ConvertTo-Json -InputObject $Result -Compress -Depth 32
        $filtered = Protect-SequenceSecretText -Text $json
        if (-not (Test-SequenceSecretText -Text $filtered)) {
            $back = ConvertFrom-Json -InputObject $filtered -AsHashtable -DateKind String -NoEnumerate -ErrorAction Stop
            if ($back -is [System.Collections.IDictionary] -and $back.Contains('ok') -and $back['ok'] -is [bool]) { return $filtered }
        }
    } catch {
        Write-Verbose "A result file text did not pass the secret filter check: $($_.Exception.Message)"
    }
    $refusal = New-WorkloadRefusal -Code 'workload_secret_filter_failed' -Key 'runner.workload_secret_filter_failed'
    return (ConvertTo-Json -InputObject $refusal -Compress -Depth 32)
}

function Write-WorkloadResultFile {
    <#
    .SYNOPSIS
        Replaces a result file through a temporary file; returns whether it did. Never throws.
    .DESCRIPTION
        On Windows the move fails while another process holds the file open
        without delete sharing, so it is tried three times. The older file
        stays when all three fail.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    $tmp = "$Path.$PID.tmp"
    for ($try = 1; $try -le 3; $try++) {
        try {
            [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
            [IO.File]::Move($tmp, $Path, $true)
            return $true
        } catch {
            Write-Verbose "Try $try to replace '$Path' failed: $($_.Exception.Message)"
            if ($try -lt 3) { Start-Sleep -Milliseconds 50 }
        }
    }
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Verbose "The temporary file '$tmp' stays: $($_.Exception.Message)"
    }
    return $false
}

function ConvertTo-WorkloadReplyLine {
    <#
    .SYNOPSIS
        The reply frame line for a request: the filtered answer, or a fixed refusal for the same id.
    .DESCRIPTION
        The result passes the object filter, is framed, and the framed line
        passes the text filter. The filtered line is written only when it
        holds no registered value and still reads as a reply with this id and
        a result with a boolean ok. Otherwise the line of the
        workload_secret_filter_failed refusal is returned, framed as built: it
        carries only catalog text and the request id. A result whose frame is
        too long becomes the workload_internal_error refusal. -Operation adds
        state, dispatched and effect to each refusal built here, so an
        operation is never answered without its effect.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Id,
        [AllowNull()][object]$Result,
        [System.Collections.IDictionary]$Operation = $null
    )
    try {
        $protected = Protect-WorkloadReply -InputObject $Result
        $line = $null
        try {
            $line = ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'reply'; id = $Id; result = $protected })
        } catch {
            $tooLong = New-WorkloadRefusal -Code 'workload_internal_error' -Key 'runner.workload_internal_error' -Arguments @{ detail = $_.Exception.Message }
            if ($null -ne $Operation) { foreach ($key in $Operation.Keys) { $tooLong[$key] = $Operation[$key] } }
            $line = ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'reply'; id = $Id; result = $tooLong })
        }
        $filtered = Protect-SequenceSecretText -Text $line
        if (-not (Test-SequenceSecretText -Text $filtered)) {
            $back = ConvertFrom-WorkloadFrameLine -Line $filtered
            $result = $back['result']
            if ($back['type'] -ceq 'reply' -and $back['id'] -is [string] -and $back['id'] -ceq $Id -and
                $result -is [System.Collections.IDictionary] -and $result.Contains('ok') -and $result['ok'] -is [bool]) {
                return $filtered
            }
        }
    } catch {
        Write-Verbose "The reply to $Id did not pass the secret filter check: $($_.Exception.Message)"
    }
    $refusal = New-WorkloadRefusal -Code 'workload_secret_filter_failed' -Key 'runner.workload_secret_filter_failed'
    if ($null -ne $Operation) { foreach ($key in $Operation.Keys) { $refusal[$key] = $Operation[$key] } }
    return (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'reply'; id = $Id; result = $refusal }))
}

function ConvertTo-WorkloadProgressLine {
    <#
    .SYNOPSIS
        The progress frame line for a request, checked as a reply is; $null when the filter broke it. Never throws.
    .DESCRIPTION
        Progress is advisory: a line that fails the check is not sent, and the
        operation runs on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Id,
        [int]$Completed,
        [int]$Total,
        [AllowEmptyString()][AllowNull()][string]$Label
    )
    try {
        $line = ConvertTo-WorkloadFrameLine -Frame ([ordered]@{
                type = 'progress'; id = $Id; completed = $Completed; total = $Total; label = (Protect-SequenceSecretText -Text $Label)
            })
        $filtered = Protect-SequenceSecretText -Text $line
        if (Test-SequenceSecretText -Text $filtered) { return $null }
        $back = ConvertFrom-WorkloadFrameLine -Line $filtered
        if ($back['type'] -ceq 'progress' -and $back['id'] -is [string] -and $back['id'] -ceq $Id) { return $filtered }
    } catch {
        Write-Verbose "A progress frame was not sent: $($_.Exception.Message)"
    }
    return $null
}

function Get-WorkloadOperationMember {
    <#
    .SYNOPSIS
        The state, dispatched and effect members a refusal of an operation carries.
    .DESCRIPTION
        Counted says whether the handler counted the operation, the sign that
        it may have sent input: an operation answered by a refusal of this
        shell is then uncertain, never none-proven.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][object]$Answer,
        [Parameter(Mandatory)][bool]$Counted
    )
    $isMap = $Answer -is [System.Collections.IDictionary]
    $dispatched = $Counted
    if ($isMap -and $Answer.Contains('dispatched') -and $Answer['dispatched'] -is [bool]) { $dispatched = $Answer['dispatched'] }
    $effect = $(if ($dispatched) { 'uncertain' } else { 'none-proven' })
    if ($isMap -and $Answer['effect'] -is [string] -and $Answer['effect'] -cin @('applied', 'none-proven', 'uncertain')) { $effect = $Answer['effect'] }
    $state = 'failed'
    if ($isMap -and $Answer['state'] -is [string] -and $Answer['state'] -cin @('succeeded', 'failed', 'canceled')) { $state = $Answer['state'] }
    return [ordered]@{ state = $state; dispatched = $dispatched; effect = $effect }
}

function Read-WorkloadControlFrame {
    <#
    .SYNOPSIS
        Takes every frame that has arrived on the request pipe while a handler runs, without blocking. Never throws.
    .DESCRIPTION
        A cancel for the current request and a session.end request set Stop;
        a mask.ack is recorded; other frames are ignored. A frame starts the
        next read before it is handled, so a handler always finds a read
        pending. The end of input is final: after it, every read completes at
        once, so no read is started again and ParentLost stops every later
        call. A line that is no frame is recorded in Rejected and ends reading
        the same way. A throw here would reach the engine as a failure of the
        primitive that is running, so nothing is thrown.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$Worker,
        [Parameter(Mandatory)][hashtable]$Pipe,
        [int]$WaitMilliseconds = 0
    )
    try {
        if ($Worker.ParentLost -eq $true) { return }
        if ($WaitMilliseconds -gt 0 -and $null -ne $Pipe.Read) {
            $null = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($Pipe.Read), $WaitMilliseconds)
        }
        while ($null -ne $Pipe.Read -and $Pipe.Read.IsCompleted) {
            $line = $(if ($Pipe.Read.IsCompletedSuccessfully) { $Pipe.Read.Result } else { $null })
            if ($null -eq $line) {
                $Worker.Stop = $true
                $Worker.ParentLost = $true
                return
            }
            $frame = $null
            try {
                $frame = ConvertFrom-WorkloadFrameLine -Line $line
            } catch {
                $Pipe.Rejected = 'request pipe: ' + $_.Exception.Message
                $Worker.Stop = $true
                $Worker.ParentLost = $true
                return
            }
            $Pipe.Read = & $Pipe.ReadNext
            switch -CaseSensitive ([string]$frame['type']) {
                'cancel' {
                    if ($null -ne $Worker.CurrentId -and $frame['id'] -is [string] -and $frame['id'] -ceq [string]$Worker.CurrentId) { $Worker.Stop = $true }
                }
                'request' {
                    if ($frame['method'] -is [string] -and $frame['method'] -ceq 'session.end') {
                        $Worker.PendingEnd = $frame
                        $Worker.Stop = $true
                    }
                }
                'mask.ack' {
                    if ($frame['id'] -is [long] -or $frame['id'] -is [int]) {
                        if ([long]$frame['id'] -gt [long]$Pipe.MaskAck) { $Pipe.MaskAck = [long]$frame['id'] }
                    }
                }
            }
        }
    } catch {
        Write-Verbose "The request pipe was not read: $($_.Exception.Message)"
    }
}

function Send-WorkloadPipeLine {
    <#
    .SYNOPSIS
        Writes one frame line to the reply pipe; a write without a reader marks the front end lost.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Line)
    try {
        $writer.WriteLine($Line)
        $writer.Flush()
        return $true
    } catch {
        Write-Verbose "The reply pipe has no reader: $($_.Exception.Message)"
        $worker.ParentLost = $true
        $worker.Stop = $true
        return $false
    }
}

function Write-WorkloadShellError {
    <#
    .SYNOPSIS
        One line of diagnostics to stderr, which the front end keeps in worker.err.log.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-WorkloadShellCall {
    <#
    .SYNOPSIS
        The call object every handler receives as its one argument.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Request)
    $params = $Request['params']
    if ($params -isnot [System.Collections.IDictionary]) { $params = @{} }
    return @{
        Id         = [string]$Request['id']
        Method     = [string]$Request['method']
        Params     = $params
        SessionId  = $shellParameter.SessionId
        SessionDir = $shellParameter.SessionDir
        RefBase    = $shellParameter.RefBase
        ConfigPath = $shellParameter.ConfigPath
        Worker     = $worker
        ShouldStop = $shouldStop
        Progress   = $progress
    }
}

function Invoke-WorkloadShellEnd {
    <#
    .SYNOPSIS
        Ends the session with a reason and discards the answer; a throw goes to stderr.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$Reason)
    try {
        $null = Invoke-WorkloadSessionEndRequest -Call @{ Params = @{ reason = $Reason }; Worker = $worker }
    } catch {
        Write-WorkloadShellError -Text ('session end ({0}) failed: {1}' -f $Reason, $_.Exception.Message)
    }
}

try {
    $utf8 = [Text.UTF8Encoding]::new($false)
    $requestStream = [IO.Pipes.AnonymousPipeClientStream]::new([IO.Pipes.PipeDirection]::In, $RequestPipeHandle)
    $replyStream = [IO.Pipes.AnonymousPipeClientStream]::new([IO.Pipes.PipeDirection]::Out, $ReplyPipeHandle)
    $reader = [IO.StreamReader]::new($requestStream, $utf8)
    $writer = [IO.StreamWriter]::new($replyStream, $utf8)
    $writer.NewLine = "`n"
} catch {
    [Console]::Error.WriteLine('The pipes could not be opened: ' + $_.Exception.Message)
    exit 2
}
$shellParameter = @{ SessionId = $SessionId; SessionDir = $SessionDir; RefBase = $RefBase; ConfigPath = $ConfigPath }
$pipe = @{ Read = $null; ReadNext = { $reader.ReadLineAsync() }.GetNewClosure(); MaskAck = 0; Rejected = $null }
$pipe.Read = & $pipe.ReadNext

$worker = @{ Session = $null
    Screen  = @{ Table = $null; Boxes = @(); Counter = $RefBase; Ordinal = 0 }
    Page    = @{ Table = $null; Counter = $RefBase; Ordinal = 0 }
    PendingEnd = $null; ParentLost = $false; Stop = $false; CurrentId = $null; MaskId = 0 }

Import-Module (Join-Path $PSScriptRoot '../modules/Test.WorkloadSession.psm1') -Global -DisableNameChecking

$shouldStop = { Read-WorkloadControlFrame -Worker $worker -Pipe $pipe; [bool]$worker.Stop }
$progress = {
    param([int]$Completed, [int]$Total, [string]$Label)
    $line = ConvertTo-WorkloadProgressLine -Id ([string]$worker.CurrentId) -Completed $Completed -Total $Total -Label $Label
    if ($null -ne $line -and -not $worker.ParentLost) { $null = Send-WorkloadPipeLine -Line $line }
}
# The sink hands every new secret to the front end, which masks it in the
# worker's logs, and waits for the acknowledgment: the engine may print the
# value as soon as this returns. It writes exactly one [bool].
$maskSink = {
    param([string[]]$Values)
    if ($worker.ParentLost) { return $false }
    $forms = [Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        $json = ConvertTo-Json -InputObject ([string]$value) -Compress
        foreach ($form in @([string]$value, $json.Substring(1, $json.Length - 2), [uri]::EscapeDataString([string]$value))) {
            if ($form.Length -gt 0 -and -not $forms.Contains($form)) { $forms.Add($form) }
        }
    }
    $worker.MaskId = $worker.MaskId + 1
    $maskId = $worker.MaskId
    $line = $null
    try {
        $line = ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'mask'; id = $maskId; values = [object[]]$forms.ToArray() })
    } catch {
        Write-Verbose "The mask frame was not built: $($_.Exception.Message)"
        return $false
    }
    if (-not (Send-WorkloadPipeLine -Line $line)) { return $false }
    $deadline = [Environment]::TickCount64 + [long](Get-WorkloadProtocolLimit).MaskAckSeconds * 1000
    while ($true) {
        if ([long]$pipe.MaskAck -ge $maskId) { return $true }
        if ($worker.ParentLost) { return $false }
        $left = $deadline - [Environment]::TickCount64
        if ($left -le 0) { return $false }
        $null = Read-WorkloadControlFrame -Worker $worker -Pipe $pipe -WaitMilliseconds ([int][Math]::Min([long][int]::MaxValue, $left))
    }
}
Register-WorkloadMaskSink -ScriptBlock $maskSink
$limits = Get-WorkloadProtocolLimit
$null = Send-WorkloadPipeLine -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{
            type = 'hello'; protocol = $limits.PipeProtocol; sessionId = $SessionId; pid = $PID; surfaces = @('screen', 'page') }))

# Method names are compared ordinally: a hashtable would match them ignoring case.
$handlers = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$handlers['phrases.list'] = 'Invoke-WorkloadPhraseRequest'
$handlers['snapshot.take'] = 'Invoke-WorkloadSnapshotRequest'
$handlers['suggest'] = 'Invoke-WorkloadSuggestRequest'
$handlers['session.start'] = 'Invoke-WorkloadSessionStartRequest'
$handlers['session.end'] = 'Invoke-WorkloadSessionEndRequest'
$handlers['step.run'] = 'Invoke-WorkloadStepRequest'
$handlers['action.run'] = 'Invoke-WorkloadActionRequest'
$handlers['sequence.run'] = 'Invoke-WorkloadSequenceRunRequest'
$handlers['sequence.save'] = 'Invoke-WorkloadSequenceSaveRequest'
$operationMethods = @('step.run', 'action.run', 'sequence.run')
$resultFileMethods = @('session.start', 'step.run', 'action.run', 'sequence.run', 'sequence.save')

try {
    while ($true) {
        $null = [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($pipe.Read))
        $line = $(if ($pipe.Read.IsCompletedSuccessfully) { $pipe.Read.Result } else { $null })
        if ($null -eq $line) {
            $worker.ParentLost = $true
            Invoke-WorkloadShellEnd -Reason 'parent-lost'
            exit 0
        }
        $frame = $null
        try {
            $frame = ConvertFrom-WorkloadFrameLine -Line $line
        } catch {
            Write-WorkloadShellError -Text ('request pipe: ' + $_.Exception.Message)
            exit 1
        }
        $pipe.Read = & $pipe.ReadNext
        if ([string]$frame['type'] -cne 'request') { continue }

        $method = [string]$frame['method']
        $worker.CurrentId = [string]$frame['id']
        $call = Get-WorkloadShellCall -Request $frame
        $isOperation = $operationMethods -ccontains $method
        $seqBefore = $(if ($null -ne $worker.Session) { [int]$worker.Session.OperationSeq } else { 0 })
        $result = $null
        $answer = $null
        $reason = $null
        try {
            $handler = $(if ($handlers.ContainsKey($method)) { $handlers[$method] } else { $null })
            if ($null -eq $handler) {
                $reason = 'unknown method ' + $method
            } else {
                $output = @(& $handler -Call $call)
                if ($output.Count -eq 1) { $answer = $output[0] }
                $result = $answer
                if ($output.Count -ne 1 -or $answer -isnot [System.Collections.IDictionary] -or -not $answer.Contains('ok') -or $answer['ok'] -isnot [bool]) {
                    $reason = 'the handler of ' + $method + ' answered without a boolean ok'
                }
            }
        } catch {
            $answer = $null
            $reason = $_.Exception.Message
        }
        $operation = $null
        if ($isOperation) {
            $seqAfter = $(if ($null -ne $worker.Session) { [int]$worker.Session.OperationSeq } else { 0 })
            $operation = Get-WorkloadOperationMember -Answer $answer -Counted ($seqAfter -gt $seqBefore)
        }
        if ($null -ne $reason) {
            $result = New-WorkloadRefusal -Code 'workload_internal_error' -Key 'runner.workload_internal_error' -Arguments @{ detail = $reason }
            if ($null -ne $operation) { foreach ($key in $operation.Keys) { $result[$key] = $operation[$key] } }
        }

        if ($resultFileMethods -ccontains $method -and $null -ne $worker.Session) {
            foreach ($file in @(
                    @{ Name = 'journal.result.json'; Get = { Get-WorkloadJournalResult -Session $worker.Session } }
                    @{ Name = 'failure.result.json'; Get = { Get-WorkloadFailureResult -Session $worker.Session } })) {
                try {
                    $text = ConvertTo-WorkloadResultFileText -Result (& $file.Get)
                    if (-not (Write-WorkloadResultFile -Path (Join-Path $SessionDir $file.Name) -Content $text)) {
                        Write-WorkloadShellError -Text ('result file not replaced: ' + $file.Name)
                    }
                } catch {
                    Write-WorkloadShellError -Text ('result file not written: ' + $file.Name + ': ' + $_.Exception.Message)
                }
            }
        }

        if ($null -ne $operation) {
            $null = Send-WorkloadPipeLine -Line (ConvertTo-WorkloadReplyLine -Id $worker.CurrentId -Result $result -Operation $operation)
        } else {
            $null = Send-WorkloadPipeLine -Line (ConvertTo-WorkloadReplyLine -Id $worker.CurrentId -Result $result)
        }

        if ($null -ne $worker.PendingEnd) {
            $endCall = Get-WorkloadShellCall -Request $worker.PendingEnd
            $endResult = $null
            try {
                $endResult = Invoke-WorkloadSessionEndRequest -Call $endCall
            } catch {
                $endResult = New-WorkloadRefusal -Code 'workload_internal_error' -Key 'runner.workload_internal_error' -Arguments @{ detail = $_.Exception.Message }
            }
            $null = Send-WorkloadPipeLine -Line (ConvertTo-WorkloadReplyLine -Id $endCall.Id -Result $endResult)
            exit 0
        }
        if ($null -ne $pipe.Rejected) {
            Write-WorkloadShellError -Text ([string]$pipe.Rejected)
            exit 1
        }
        if ($worker.ParentLost) {
            Invoke-WorkloadShellEnd -Reason 'parent-lost'
            exit 0
        }
        if ($method -ceq 'session.end') { exit 0 }
        $worker.Stop = $false
        $worker.CurrentId = $null
    }
} finally {
    Invoke-WorkloadShellEnd -Reason 'worker-exit'
}
