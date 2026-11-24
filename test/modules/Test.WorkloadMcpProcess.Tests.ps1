<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42054c1d-2eae-4f28-af47-af8c0c7fe98b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload mcp process
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
    Pester guard on the workload MCP front end and the worker shell as real
    processes on real pipes.
.DESCRIPTION
    The front-end suite drives a stub channel on a scripted clock, so it
    cannot see what only real processes show: a megabyte frame crossing a
    64 KiB pipe while the worker floods its own stdout and stderr, a worker
    that never says hello or exits before it, a process the worker started
    that keeps the pipes open after the worker is gone, a worker that ignores
    the end request, handles left behind by five sessions, and the server
    and the worker shell started as their own processes. A front end that
    waited for the end of a pipe, or kept a client end of a worker pipe,
    would hang or leak here while every stub case stayed green.

    Each case but the last four drives the dot-sourced front end inside the
    test process against a stub worker script written to TestDrive, on the
    real clock: every wait is bounded at ten times its expected duration,
    and the two cases that prove a deadline lower only that deadline to 3 s.
    The last four start Start-WorkloadMcpServer.ps1 or the real
    Invoke-WorkloadSession.ps1 as child processes. AfterEach ends every
    process a case started and did not see exit.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_WORKLOAD_MCP_SERVER_NO_RUN', 'NO_COLOR'
    $env:YURUNA_WORKLOAD_MCP_SERVER_NO_RUN = '1'
    $env:NO_COLOR = '1'
    $serviceDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'service'
    $script:FrontEndPath = Join-Path $serviceDir 'Start-WorkloadMcpServer.ps1'
    $script:WorkerShellPath = Join-Path $serviceDir 'Invoke-WorkloadSession.ps1'
    $script:PwshPath = (Get-Process -Id $PID).Path
    . $script:FrontEndPath
    $script:Started = [Collections.Generic.List[object]]::new()

    # The part every stub worker shares: the parameters of the worker shell,
    # the protocol module, the two pipes opened as the shell opens them, and a
    # request loop that answers session.start and session.end as the shell
    # does. A stub passes -Handle to take a frame before the default answers.
    $script:StubPrologue = @'
param(
    [Parameter(Mandatory)][string]$RequestPipeHandle,
    [Parameter(Mandatory)][string]$ReplyPipeHandle,
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(Mandatory)][string]$SessionDir,
    [long]$RefBase = 0,
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
$env:NO_COLOR = '1'
Import-Module '__MODULE__' -Global -DisableNameChecking
$utf8 = [Text.UTF8Encoding]::new($false)
$requestPipe = [IO.Pipes.AnonymousPipeClientStream]::new('In', $RequestPipeHandle)
$replyPipe = [IO.Pipes.AnonymousPipeClientStream]::new('Out', $ReplyPipeHandle)
$reader = [IO.StreamReader]::new($requestPipe, $utf8)
$writer = [IO.StreamWriter]::new($replyPipe, $utf8)
$writer.NewLine = "`n"
function Send-StubFrame {
    param($Frame)
    $writer.WriteLine((ConvertTo-WorkloadFrameLine -Frame $Frame))
    $writer.Flush()
}
function Send-StubReply {
    param($Id, $Result)
    Send-StubFrame ([ordered]@{ type = 'reply'; id = $Id; result = $Result })
}
function Send-StubHello {
    Send-StubFrame ([ordered]@{ type = 'hello'; protocol = [long](Get-WorkloadProtocolLimit).PipeProtocol; sessionId = $SessionId; pid = $PID; surfaces = @('screen') })
}
function Invoke-StubLoop {
    param([scriptblock]$Handle = { param($Frame) $false })
    while ($null -ne ($line = $reader.ReadLine())) {
        $frame = ConvertFrom-WorkloadFrameLine -Line $line
        if (& $Handle $frame) { continue }
        if ([string]$frame['type'] -cne 'request') { continue }
        switch -CaseSensitive ([string]$frame['method']) {
            'session.start' {
                Send-StubReply -Id $frame['id'] -Result ([ordered]@{ ok = $true; vmName = 'vm-stub'; guestKey = 'guest.stub'; hostType = 'host.stub'
                        defaultSurface = 'screen'; variables = @(); otherRunningVms = @() })
            }
            'session.end' {
                Send-StubReply -Id $frame['id'] -Result ([ordered]@{ ok = $true; released = $true; cycleFolder = '' })
                exit 0
            }
            default { Send-StubReply -Id $frame['id'] -Result ([ordered]@{ ok = $true }) }
        }
    }
}

'@.Replace('__MODULE__', (Join-Path $PSScriptRoot 'Test.WorkloadProtocol.psm1'))

    function Write-ProcessTestStub {
        <#
        .SYNOPSIS
            Writes one stub worker script, the shared prologue plus its body, and returns its path.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$Body
        )
        $dir = Join-Path $TestDrive 'stubs'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir "$Name.ps1"
        [IO.File]::WriteAllText($path, ($script:StubPrologue + $Body + "`n"), [Text.UTF8Encoding]::new($false))
        return $path
    }

    function New-ProcessTestClient {
        <#
        .SYNOPSIS
            The client's input: a pipe read through UTF-8 and the client end the case holds and never writes.
        .DESCRIPTION
            The held end shares the handle object of the pipe, so disposing it
            is the end of the client's input. DisposeLocalCopyOfClientHandle is
            never called on this pipe: it would close that shared handle.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates an in-process pipe pair the case disposes itself.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param()
        $pipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In)
        $hold = [IO.Pipes.AnonymousPipeClientStream]::new([IO.Pipes.PipeDirection]::Out, $pipe.ClientSafePipeHandle)
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false))
        return @{ Pipe = $pipe; Hold = $hold; Reader = $reader; Writer = [IO.StringWriter]::new() }
    }

    function New-ProcessTestState {
        <#
        .SYNOPSIS
            A front-end state on the real clock with a StringWriter, a stub worker and a session root under TestDrive.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory state and one folder under TestDrive.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter(Mandatory)][hashtable]$Client,
            [Parameter(Mandatory)][string]$WorkerScript
        )
        $root = Join-Path $TestDrive ('sessions-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root -Force
        return (Initialize-WorkloadMcpState -Writer $Client.Writer -WorkerScript $WorkerScript -SessionRoot $root)
    }

    function Add-ProcessTestStarted {
        <#
        .SYNOPSIS
            Records a process the case started, with its start ticks, for AfterEach.
        #>
        [CmdletBinding()]
        [OutputType([void])]
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [Parameter(Mandatory)][long]$StartTicks
        )
        $script:Started.Add(@{ Pid = $ProcessId; StartTicks = $StartTicks })
    }

    function Add-ProcessTestWorker {
        <#
        .SYNOPSIS
            Records the worker process of the state, when one is open, for AfterEach; returns its pid or 0.
        #>
        [CmdletBinding()]
        [OutputType([int])]
        param([Parameter(Mandatory)][hashtable]$State)
        $worker = $State.Worker
        if ($null -eq $worker -or $null -eq $worker.Process) { return 0 }
        $id = [int]$worker.Process.Id
        Add-ProcessTestStarted -ProcessId $id -StartTicks ([long]$worker.StartTicks)
        return $id
    }

    function Get-ProcessTestCallLine {
        <#
        .SYNOPSIS
            One tools/call line of the client.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Tool,
            [System.Collections.IDictionary]$Arguments = [ordered]@{}
        )
        return (ConvertTo-Json -Compress -Depth 20 -InputObject ([ordered]@{
                    jsonrpc = '2.0'; id = $Id; method = 'tools/call'; params = [ordered]@{ name = $Tool; arguments = $Arguments }
                }))
    }

    function Get-ProcessTestAnswer {
        <#
        .SYNOPSIS
            The decoded answer of the writer that carries the id, or $null.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter(Mandatory)][IO.StringWriter]$Writer,
            [Parameter(Mandatory)][string]$Id
        )
        foreach ($outLine in ($Writer.ToString() -split "`n")) {
            if (-not $outLine) { continue }
            $message = ConvertFrom-Json -InputObject $outLine -AsHashtable -DateKind String
            if ($message['id'] -is [string] -and $message['id'] -ceq $Id) { return $message }
        }
        return $null
    }

    function Get-ProcessTestToolResult {
        <#
        .SYNOPSIS
            The tool result of an answer, parsed from its first content item.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Answer)
        return (ConvertFrom-Json -InputObject ([string]$Answer['result']['content'][0]['text']) -AsHashtable -DateKind String)
    }

    function Wait-ProcessTestAnswer {
        <#
        .SYNOPSIS
            Runs the front-end loop until the answer with the id is written or the bound passed; returns that answer or $null.
        .DESCRIPTION
            The -Until block is a closure over this function's locals: inside
            it a script variable reads $null and no function of the suite is
            found, so it uses only the captured writer, marker and bound.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)][hashtable]$Client,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][int]$Milliseconds
        )
        $outWriter = $Client.Writer
        $marker = '"id":"' + $Id + '"'
        $begin = [Environment]::TickCount64
        $bound = [long]$Milliseconds
        $until = { $outWriter.ToString().Contains($marker) -or ([Environment]::TickCount64 - $begin) -ge $bound }.GetNewClosure()
        Invoke-WorkloadMcpLoop -Reader $Client.Reader -Writer $outWriter -State $State -Until $until
        return (Get-ProcessTestAnswer -Writer $outWriter -Id $Id)
    }

    function Send-ProcessTestCall {
        <#
        .SYNOPSIS
            Sends one tools/call line, records a worker it opened, and returns its answer when -Milliseconds is given.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)][hashtable]$Client,
            [Parameter(Mandatory)][string]$Id,
            [Parameter(Mandatory)][string]$Tool,
            [System.Collections.IDictionary]$Arguments = [ordered]@{},
            [int]$Milliseconds = 0
        )
        $hadWorker = $null -ne $State.Worker
        Invoke-WorkloadMcpClientLine -State $State -Line (Get-ProcessTestCallLine -Id $Id -Tool $Tool -Arguments $Arguments)
        if (-not $hadWorker) { $null = Add-ProcessTestWorker -State $State }
        if ($Milliseconds -le 0) { return $null }
        return (Wait-ProcessTestAnswer -State $State -Client $Client -Id $Id -Milliseconds $Milliseconds)
    }

    function Stop-ProcessTestClient {
        <#
        .SYNOPSIS
            Ends the client's input and runs the loop until the state is finished or the bound passed; returns Finished.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: disposes the in-process client pipe of the case.')]
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)][hashtable]$Client,
            [Parameter(Mandatory)][int]$Milliseconds
        )
        $Client.Hold.Dispose()
        $begin = [Environment]::TickCount64
        $bound = [long]$Milliseconds
        $until = { $State.Finished -or ([Environment]::TickCount64 - $begin) -ge $bound }.GetNewClosure()
        Invoke-WorkloadMcpLoop -Reader $Client.Reader -Writer $Client.Writer -State $State -Until $until
        $Client.Reader.Dispose()
        $Client.Pipe.Dispose()
        return [bool]$State.Finished
    }

    function Wait-ProcessTestGone {
        <#
        .SYNOPSIS
            Polls until no process has the pid, at most the bound; returns whether it is gone.
        #>
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [Parameter(Mandatory)][int]$ProcessId,
            [Parameter(Mandatory)][int]$Milliseconds
        )
        $begin = [Environment]::TickCount64
        while ($true) {
            if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
            if (([Environment]::TickCount64 - $begin) -ge $Milliseconds) { return $false }
            Start-Sleep -Milliseconds 100
        }
    }

    function Start-ProcessTestShell {
        <#
        .SYNOPSIS
            Starts the real worker shell on pipes the test made; returns the process, the pipes and the stream readers.
        .DESCRIPTION
            The test drops its copies of the worker's pipe ends right after the
            start, as the front end does, so the shell sees its request pipe
            close when the test disposes the write end.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts a worker shell the case ends itself.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$SessionDir)
        $null = New-Item -ItemType Directory -Path $SessionDir -Force
        $utf8 = [Text.UTF8Encoding]::new($false)
        $requestPipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out, [IO.HandleInheritability]::Inheritable)
        $replyPipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In, [IO.HandleInheritability]::Inheritable)
        $info = [Diagnostics.ProcessStartInfo]::new($script:PwshPath)
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $script:WorkerShellPath,
                '-RequestPipeHandle', $requestPipe.GetClientHandleAsString(), '-ReplyPipeHandle', $replyPipe.GetClientHandleAsString(),
                '-SessionId', 'process-test', '-SessionDir', $SessionDir)) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = $utf8
        $info.StandardErrorEncoding = $utf8
        $info.Environment['NO_COLOR'] = '1'
        try {
            $process = [Diagnostics.Process]::Start($info)
        } finally {
            $requestPipe.DisposeLocalCopyOfClientHandle()
            $replyPipe.DisposeLocalCopyOfClientHandle()
        }
        Add-ProcessTestStarted -ProcessId $process.Id -StartTicks $process.StartTime.ToUniversalTime().Ticks
        $requestWriter = [IO.StreamWriter]::new($requestPipe, $utf8)
        $requestWriter.NewLine = "`n"
        return @{
            Process      = $process
            RequestPipe  = $requestPipe
            ReplyPipe    = $replyPipe
            Writer       = $requestWriter
            Reader       = [IO.StreamReader]::new($replyPipe, $utf8)
            OutText      = $process.StandardOutput.ReadToEndAsync()
            ErrText      = $process.StandardError.ReadToEndAsync()
        }
    }

    function Read-ProcessTestShellLine {
        <#
        .SYNOPSIS
            Reads one line from the shell's reply pipe within the bound; $null when none came.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][hashtable]$Shell,
            [Parameter(Mandatory)][int]$Milliseconds
        )
        $task = $Shell.Reader.ReadLineAsync()
        if (-not $task.Wait($Milliseconds)) { return $null }
        return $task.Result
    }
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'the workload front end with real worker processes' {
    BeforeEach {
        $script:Started.Clear()
    }

    AfterEach {
        foreach ($entry in @($script:Started.ToArray())) {
            if (Test-WorkloadProcessIdentity -ProcessId $entry.Pid -StartTicks $entry.StartTicks) {
                Stop-Process -Id $entry.Pid -Force -ErrorAction SilentlyContinue
                $null = Wait-ProcessTestGone -ProcessId $entry.Pid -Milliseconds 10000
            }
        }
        $script:Started.Clear()
        $script:WorkerHelloTimeoutSeconds = 30
        $script:ShutdownGraceSeconds = 20
    }

    It 'carries megabyte frames with non-ASCII text both ways while the worker floods stdout and stderr' {
        $stub = Write-ProcessTestStub -Name 'flood' -Body @'
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    if ([string]$Frame['type'] -cne 'request' -or [string]$Frame['method'] -cne 'action.run') { return $false }
    $flood = [string]::new([char]'x', 4194304)
    [Console]::Out.Write($flood)
    [Console]::Out.Flush()
    [Console]::Error.Write($flood)
    [Console]::Error.Flush()
    Send-StubReply -Id $Frame['id'] -Result ([ordered]@{ ok = $true; state = 'succeeded'; echo = $Frame['params']['fields']['v'] })
    return $true
}
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $start = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $start 'the start was not answered within 30 s'
        Assert-True ((Get-ProcessTestToolResult -Answer $start)['ok'] -eq $true) 'the start was refused'
        $folder = $state.Worker.Folder
        $sent = ('ab' + "`u{e7}`u{65e5}") * 200000
        Assert-Equal 800000 $sent.Length 'the fixture value has the wrong length'
        $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c2' -Tool 'workload_action' -Arguments ([ordered]@{
                operationId = 'op-1'; action = 'typeText'; fields = [ordered]@{ v = $sent }; intent = 'type the long value' }) -Milliseconds 120000
        Assert-NotNull $answer 'the action was not answered within 120 s'
        $result = Get-ProcessTestToolResult -Answer $answer
        Assert-StringEqual 'succeeded' ([string]$result['state']) 'the action did not succeed'
        Assert-True ([string]::Equals($sent, [string]$result['echo'], [StringComparison]::Ordinal)) 'the echoed value differs from the one sent'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 60000) 'the front end did not finish within 60 s of the end of input'
        $text = $client.Writer.ToString()
        Assert-False ($text.Contains("`r")) 'the writer holds a carriage return'
        foreach ($outLine in ($text -split "`n")) {
            if (-not $outLine) { continue }
            $message = ConvertFrom-Json -InputObject $outLine -AsHashtable -DateKind String
            Assert-StringEqual '2.0' ([string]$message['jsonrpc']) "a writer line is not JSON-RPC: $($outLine.Substring(0, [Math]::Min(80, $outLine.Length)))"
        }
        Assert-True (Test-Path -LiteralPath (Join-Path $folder 'worker.out.log') -PathType Leaf) 'worker.out.log does not exist'
        Assert-True (Test-Path -LiteralPath (Join-Path $folder 'worker.err.log') -PathType Leaf) 'worker.err.log does not exist'
    }

    It 'fails the start when no hello comes in time and leaves no process' {
        $stub = Write-ProcessTestStub -Name 'silent' -Body 'Start-Sleep -Seconds 600'
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $script:WorkerHelloTimeoutSeconds = 3
        try {
            Invoke-WorkloadMcpClientLine -State $state -Line (Get-ProcessTestCallLine -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }))
            $workerPid = Add-ProcessTestWorker -State $state
            Assert-True ($workerPid -gt 0) 'no worker process was started'
            $answer = Wait-ProcessTestAnswer -State $state -Client $client -Id 'c1' -Milliseconds 30000
        } finally {
            $script:WorkerHelloTimeoutSeconds = 30
        }
        Assert-NotNull $answer 'the start was not answered within 30 s'
        Assert-True ($answer['result']['isError'] -eq $true) 'the start was not a tool error'
        Assert-StringEqual 'workload_worker_start_failed' ([string](Get-ProcessTestToolResult -Answer $answer)['error']['code']) 'wrong code'
        Assert-True (Wait-ProcessTestGone -ProcessId $workerPid -Milliseconds 10000) 'the worker process is still running'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'reports the stderr of a worker that exits before hello' {
        $stub = Write-ProcessTestStub -Name 'early' -Body @'
[Console]::Error.WriteLine('first line of the early stub')
[Console]::Error.WriteLine('the last stderr line of the early stub')
exit 3
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $answer 'the start was not answered within 30 s'
        $result = Get-ProcessTestToolResult -Answer $answer
        Assert-StringEqual 'workload_worker_start_failed' ([string]$result['error']['code']) 'wrong code'
        Assert-True (([string]$result['error']['message']).Contains('the last stderr line of the early stub')) "the detail lacks the last stderr line: $($result['error']['message'])"
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'ends the session when the worker writes a malformed frame' {
        $stub = Write-ProcessTestStub -Name 'malformed' -Body @'
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    if ([string]$Frame['type'] -cne 'request' -or [string]$Frame['method'] -cne 'snapshot.take') { return $false }
    $writer.WriteLine('not json')
    $writer.Flush()
    return $true
}
Start-Sleep -Seconds 600
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $start = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $start 'the start was not answered within 30 s'
        $workerPid = [int]$state.Worker.Process.Id
        $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c2' -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' }) -Milliseconds 30000
        Assert-NotNull $answer 'the snapshot was not answered within 30 s'
        Assert-StringEqual 'workload_worker_lost' ([string](Get-ProcessTestToolResult -Answer $answer)['error']['code']) 'wrong code'
        Assert-Null $state.Worker 'the state still holds the worker'
        Assert-StringEqual 'ended' ([string]$state.Session.Phase) 'the session did not end'
        Assert-True (Wait-ProcessTestGone -ProcessId $workerPid -Milliseconds 10000) 'the worker process is still running'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'detects a worker that exits while a process it started still holds the pipes' {
        $stub = Write-ProcessTestStub -Name 'holder' -Body @'
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    if ([string]$Frame['type'] -cne 'request' -or [string]$Frame['method'] -cne 'step.run') { return $false }
    $sleeper = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 600' -PassThru
    Register-WorkloadOwnedProcess -SessionDir $SessionDir -ProcessId $sleeper.Id -StartTicks $sleeper.StartTime.ToUniversalTime().Ticks -Role 'sleeper'
    [IO.File]::WriteAllText((Join-Path $SessionDir 'sleeper.json'), ('{{"pid":{0},"startTicks":{1}}}' -f $sleeper.Id, $sleeper.StartTime.ToUniversalTime().Ticks))
    exit 0
}
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $start = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $start 'the start was not answered within 30 s'
        $folder = $state.Worker.Folder
        $begin = [Environment]::TickCount64
        $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c2' -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text Next'; intent = 'start the sleeper' }) -Milliseconds 30000
        $elapsed = [Environment]::TickCount64 - $begin
        $sleeperFile = Join-Path $folder 'sleeper.json'
        if (Test-Path -LiteralPath $sleeperFile -PathType Leaf) {
            $sleeper = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sleeperFile)) -AsHashtable
            Add-ProcessTestStarted -ProcessId ([int]$sleeper['pid']) -StartTicks ([long]$sleeper['startTicks'])
        }
        Assert-NotNull $answer 'the lost-worker answer did not come within 30 s'
        Assert-True ($elapsed -lt 30000) "the lost-worker answer took $elapsed ms"
        $result = Get-ProcessTestToolResult -Answer $answer
        Assert-StringEqual 'workload_worker_lost' ([string]$result['error']['code']) 'wrong code'
        Assert-StringEqual 'uncertain' ([string]$result['state']) 'wrong state'
        Assert-True (Test-Path -LiteralPath $sleeperFile -PathType Leaf) 'the stub did not start its sleeper'
        Assert-True (Wait-ProcessTestGone -ProcessId ([int]$sleeper['pid']) -Milliseconds 10000) 'the sleeper the worker started is still running'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'kills a worker that ignores the end request after the grace period' {
        $stub = Write-ProcessTestStub -Name 'deaf' -Body @'
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    return ([string]$Frame['type'] -ceq 'request' -and [string]$Frame['method'] -ceq 'session.end')
}
Start-Sleep -Seconds 600
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $start = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $start 'the start was not answered within 30 s'
        $workerPid = [int]$state.Worker.Process.Id
        $script:ShutdownGraceSeconds = 3
        try {
            $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c2' -Tool 'workload_session_end' -Milliseconds 40000
        } finally {
            $script:ShutdownGraceSeconds = 20
        }
        Assert-NotNull $answer 'the end was not answered within 40 s'
        $result = Get-ProcessTestToolResult -Answer $answer
        Assert-True ($result['ended'] -eq $true) 'ended is not true'
        Assert-True ($result['forced'] -eq $true) 'forced is not true'
        Assert-True ($result['killConfirmed'] -eq $true) 'killConfirmed is not true'
        Assert-True (Wait-ProcessTestGone -ProcessId $workerPid -Milliseconds 10000) 'the worker process is still running'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'cancels a running operation through the poll form' {
        $stub = Write-ProcessTestStub -Name 'cancel' -Body @'
$script:HeldId = $null
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    $type = [string]$Frame['type']
    if ($type -ceq 'request' -and [string]$Frame['method'] -ceq 'step.run') {
        $script:HeldId = [string]$Frame['id']
        return $true
    }
    if ($type -ceq 'cancel' -and $null -ne $script:HeldId -and [string]$Frame['id'] -ceq $script:HeldId) {
        Send-StubReply -Id $script:HeldId -Result ([ordered]@{ ok = $false; state = 'canceled' })
        $script:HeldId = $null
        return $true
    }
    return $false
}
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $start = Send-ProcessTestCall -State $state -Client $client -Id 'c1' -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
        Assert-NotNull $start 'the start was not answered within 30 s'
        $null = Send-ProcessTestCall -State $state -Client $client -Id 'c2' -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'wait for text Next'; intent = 'hold the step' })
        Assert-True ($null -ne $state.InFlight) 'the step was not sent to the worker'
        $answer = Send-ProcessTestCall -State $state -Client $client -Id 'c3' -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; cancel = $true }) -Milliseconds 30000
        Assert-NotNull $answer 'the poll with cancel was not answered within 30 s'
        $result = Get-ProcessTestToolResult -Answer $answer
        Assert-StringEqual 'canceled' ([string]$result['state']) 'the poll did not report the canceled result'
        Assert-StringEqual 'op-1' ([string]$result['operationId']) 'wrong operation'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'gives each new worker the next reference block' {
        $stub = Write-ProcessTestStub -Name 'refbase' -Body @'
[Console]::Error.WriteLine([string]$RefBase)
[Console]::Error.Flush()
Send-StubHello
Invoke-StubLoop
'@
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $folders = [Collections.Generic.List[string]]::new()
        foreach ($round in 1, 2) {
            $start = Send-ProcessTestCall -State $state -Client $client -Id "start-$round" -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
            Assert-NotNull $start "start $round was not answered within 30 s"
            $folders.Add([string]$state.Worker.Folder)
            $end = Send-ProcessTestCall -State $state -Client $client -Id "end-$round" -Tool 'workload_session_end' -Milliseconds 30000
            Assert-NotNull $end "end $round was not answered within 30 s"
        }
        Assert-NotEqual $folders[0] $folders[1] 'the two workers share a folder'
        Assert-StringEqual '0' ([IO.File]::ReadAllText((Join-Path $folders[0] 'worker.err.log')).Trim()) 'the first worker got another reference base'
        Assert-StringEqual '1000000' ([IO.File]::ReadAllText((Join-Path $folders[1] 'worker.err.log')).Trim()) 'the second worker got another reference base'
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
    }

    It 'starts and ends five sessions without leaving a process or a handle' {
        $stub = Write-ProcessTestStub -Name 'session' -Body @'
Send-StubHello
Invoke-StubLoop
'@
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $fdBefore = $(if ($IsLinux) { @(Get-ChildItem -LiteralPath "/proc/$PID/fd" -Force).Count } else { 0 })
        $client = New-ProcessTestClient
        $state = New-ProcessTestState -Client $client -WorkerScript $stub
        $workerPids = [Collections.Generic.List[int]]::new()
        foreach ($round in 1..5) {
            $start = Send-ProcessTestCall -State $state -Client $client -Id "start-$round" -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-stub' }) -Milliseconds 30000
            Assert-NotNull $start "start $round was not answered within 30 s"
            $workerPids.Add([int]$state.Worker.Process.Id)
            $end = Send-ProcessTestCall -State $state -Client $client -Id "end-$round" -Tool 'workload_session_end' -Milliseconds 30000
            Assert-NotNull $end "end $round was not answered within 30 s"
            Assert-True ((Get-ProcessTestToolResult -Answer $end)['ended'] -eq $true) "end $round did not end the session"
        }
        Assert-True (Stop-ProcessTestClient -State $state -Client $client -Milliseconds 30000) 'the front end did not finish'
        $client.Writer.Dispose()
        foreach ($workerPid in $workerPids) {
            Assert-True (Wait-ProcessTestGone -ProcessId $workerPid -Milliseconds 10000) "worker $workerPid is still running"
        }
        if ($IsLinux) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect()
            $fdAfter = @(Get-ChildItem -LiteralPath "/proc/$PID/fd" -Force).Count
            Assert-True ($fdAfter -le ($fdBefore + 2)) "the test process holds $fdAfter descriptors after five sessions, $fdBefore before"
        }
    }
}

Describe 'the workload server and the worker shell as their own processes' {
    BeforeEach {
        $script:Started.Clear()
    }

    AfterEach {
        foreach ($entry in @($script:Started.ToArray())) {
            if (Test-WorkloadProcessIdentity -ProcessId $entry.Pid -StartTicks $entry.StartTicks) {
                Stop-Process -Id $entry.Pid -Force -ErrorAction SilentlyContinue
                $null = Wait-ProcessTestGone -ProcessId $entry.Pid -Milliseconds 10000
            }
        }
        $script:Started.Clear()
    }

    It 'the server process answers on its real standard streams in UTF-8 and exits when its input ends' {
        $stub = Write-ProcessTestStub -Name 'echo' -Body @'
Send-StubHello
Invoke-StubLoop -Handle {
    param($Frame)
    if ([string]$Frame['type'] -cne 'request' -or [string]$Frame['method'] -cne 'phrases.list') { return $false }
    Send-StubReply -Id $Frame['id'] -Result ([ordered]@{ ok = $true; search = $Frame['params']['search']; phrases = @() })
    return $true
}
'@
        $root = Join-Path $TestDrive 'server-sessions'
        $null = New-Item -ItemType Directory -Path $root -Force
        $utf8 = [Text.UTF8Encoding]::new($false)
        $info = [Diagnostics.ProcessStartInfo]::new($script:PwshPath)
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $script:FrontEndPath, '-WorkerScript', $stub, '-SessionRoot', $root)) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardInputEncoding = $utf8
        $info.StandardOutputEncoding = $utf8
        $info.StandardErrorEncoding = $utf8
        $info.Environment['NO_COLOR'] = '1'
        $null = $info.Environment.Remove('YURUNA_WORKLOAD_MCP_SERVER_NO_RUN')
        $server = [Diagnostics.Process]::Start($info)
        Add-ProcessTestStarted -ProcessId $server.Id -StartTicks $server.StartTime.ToUniversalTime().Ticks
        $errText = $server.StandardError.ReadToEndAsync()
        $search = "`u{e7}`u{e3}`u{65e5}"
        $server.StandardInput.NewLine = "`n"
        $server.StandardInput.WriteLine((Get-ProcessTestCallLine -Id 'c1' -Tool 'workload_phrases' -Arguments ([ordered]@{ search = $search })))
        $server.StandardInput.Flush()
        $read = $server.StandardOutput.ReadLineAsync()
        Assert-True ($read.Wait(60000)) "the server wrote no line within 60 s; stderr so far is not shown until exit"
        $message = ConvertFrom-Json -InputObject $read.Result -AsHashtable -DateKind String
        Assert-StringEqual 'c1' ([string]$message['id']) 'the answer carries another id'
        $result = Get-ProcessTestToolResult -Answer $message
        Assert-True ($result['ok'] -eq $true) "the phrases call was refused: $($read.Result)"
        Assert-True ([string]::Equals($search, [string]$result['search'], [StringComparison]::Ordinal)) "the search came back as '$($result['search'])'"
        $sessionFile = @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Join-Path $_.FullName 'session.json' } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        Assert-Equal 1 $sessionFile.Count 'the server did not write one session.json'
        $worker = (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sessionFile[0])) -AsHashtable)['worker']
        Add-ProcessTestStarted -ProcessId ([int]$worker['pid']) -StartTicks ([long]$worker['startTicks'])
        $server.StandardInput.Close()
        Assert-True ($server.WaitForExit(30000)) 'the server did not exit within 30 s of the end of its input'
        $null = $errText.Wait(10000)
        Assert-Equal 0 $server.ExitCode "the server exited with $($server.ExitCode): $($errText.Result)"
        Assert-True (Wait-ProcessTestGone -ProcessId ([int]$worker['pid']) -Milliseconds 10000) 'the worker process is still running'
        $server.Dispose()
    }

    It 'the real worker shell ends on its own when its request pipe closes' {
        $shell = Start-ProcessTestShell -SessionDir (Join-Path $TestDrive 'shell-close')
        try {
            $hello = Read-ProcessTestShellLine -Shell $shell -Milliseconds 60000
            Assert-NotNull $hello 'the worker shell sent no hello within 60 s'
            Assert-StringEqual 'hello' ([string](ConvertFrom-WorkloadFrameLine -Line $hello)['type']) 'the first frame is not hello'
            $shell.Writer.Dispose()
            Assert-True ($shell.Process.WaitForExit(60000)) 'the worker shell did not exit within 60 s of its request pipe closing'
            Assert-Equal 0 $shell.Process.ExitCode "the worker shell exited with $($shell.Process.ExitCode)"
        } finally {
            $shell.Reader.Dispose()
            $shell.ReplyPipe.Dispose()
        }
    }

    It 'the real worker shell lists the framework phrases without a session' {
        $shell = Start-ProcessTestShell -SessionDir (Join-Path $TestDrive 'shell-phrases')
        try {
            $hello = Read-ProcessTestShellLine -Shell $shell -Milliseconds 60000
            Assert-NotNull $hello 'the worker shell sent no hello within 60 s'
            $shell.Writer.WriteLine('{"type":"request","id":"r1","method":"phrases.list","params":{}}')
            $shell.Writer.Flush()
            $replyLine = Read-ProcessTestShellLine -Shell $shell -Milliseconds 60000
            Assert-NotNull $replyLine 'the worker shell sent no reply within 60 s'
            $frame = ConvertFrom-WorkloadFrameLine -Line $replyLine
            Assert-StringEqual 'reply' ([string]$frame['type']) 'the frame is not a reply'
            Assert-StringEqual 'r1' ([string]$frame['id']) 'the reply carries another id'
            Assert-True ($frame['result']['ok'] -eq $true) "phrases.list was refused: $replyLine"
            $sentences = @($frame['result']['phrases'] | ForEach-Object { [string]$_['sentence'] })
            Assert-True ($sentences -ccontains 'click button <label>') "no phrase has the sentence 'click button <label>'"
            $shell.Writer.Dispose()
            Assert-True ($shell.Process.WaitForExit(60000)) 'the worker shell did not exit within 60 s of its request pipe closing'
            Assert-Equal 0 $shell.Process.ExitCode "the worker shell exited with $($shell.Process.ExitCode)"
        } finally {
            $shell.Reader.Dispose()
            $shell.ReplyPipe.Dispose()
        }
    }

    It 'the real worker shell ends cleanly when its reply pipe has no reader' {
        $shell = Start-ProcessTestShell -SessionDir (Join-Path $TestDrive 'shell-noreader')
        $hello = Read-ProcessTestShellLine -Shell $shell -Milliseconds 60000
        Assert-NotNull $hello 'the worker shell sent no hello within 60 s'
        $shell.Writer.WriteLine('{"type":"request","id":"r1","method":"phrases.list","params":{}}')
        $shell.Writer.Flush()
        $shell.Reader.Dispose()
        $shell.ReplyPipe.Dispose()
        $shell.Writer.Dispose()
        Assert-True ($shell.Process.WaitForExit(60000)) 'the worker shell did not exit within 60 s'
        $null = $shell.ErrText.Wait(10000)
        Assert-Equal 0 $shell.Process.ExitCode "the worker shell exited with $($shell.Process.ExitCode): $($shell.ErrText.Result)"
        Assert-False (([string]$shell.ErrText.Result).Contains('IOException')) "the worker shell's stderr holds IOException: $($shell.ErrText.Result)"
    }
}
