<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42220101-cf44-4fb6-8774-d996d04d2df5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test workload mcp server
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
    Pester guard on the front end of the workload MCP server, driven against a
    stub worker on a scripted clock.
.DESCRIPTION
    Start-WorkloadMcpServer.ps1 answers an MCP client while a worker process
    runs the steps. The cases drive its own handlers (the client line, the
    worker frame, the timer, the worker exit, the loop) against a worker
    channel without a process, so every limit is reached by moving a tick
    clock instead of waiting.

    The suite exists for the failures a client would never see coming: an
    operation dispatched twice for one operationId, a call answered twice or
    never, a request sent to a worker that is ending, closing or gone, an
    operation the worker never received reported as uncertain, a stray line on
    standard output, a page surface forwarded to a worker that does not offer
    it, a secret value written unmasked to the worker log, and a session folder
    pruned under a live front end.

    Cases that need the worker's own behavior (journal, secrets, saved YAML)
    are in Test.WorkloadSession.Tests.ps1; real processes are in
    Test.WorkloadMcpProcess.Tests.ps1.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Catalog.psm1') -Force -Global -DisableNameChecking

    # Dot-source the front end without letting it serve, so the cases drive the
    # functions its loop drives.
    $script:ServerPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'service/Start-WorkloadMcpServer.ps1'
    $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_WORKLOAD_MCP_SERVER_NO_RUN'
    $env:YURUNA_WORKLOAD_MCP_SERVER_NO_RUN = '1'
    . $script:ServerPath

    $script:StateCount = 0

    function Get-StubDefaultAnswer {
        <#
        .SYNOPSIS
            The answer of the default stub worker to one request frame.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][System.Collections.IDictionary]$Frame)
        switch -CaseSensitive ([string]$Frame['method']) {
            'session.start' {
                return @{ ok = $true; vmName = 'vm-stub'; guestKey = 'guest.stub'; hostType = 'host.stub'; defaultSurface = 'screen'
                    variables = @(); otherRunningVms = @() }
            }
            'session.end' { return @{ ok = $true; released = $true; cycleFolder = '' } }
        }
        return @{ ok = $true }
    }

    function New-StubWorkloadWorker {
        <#
        .SYNOPSIS
            A worker channel without a process, scripted by the case.
        .DESCRIPTION
            Send records each line and answers a request with OnRequest; a
            dictionary it returns is queued as the reply, $null holds the
            request until the case calls Reply. ExitTask completes on Kill,
            Dispose, and (unless -NeverExits) on CloseInput or the answer to
            session.end, and the exit ends the reply stream with a null line.
            Every completion uses TrySetResult, since two blocks can complete
            the same source.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory worker channel and changes no system state.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [scriptblock]$OnRequest,
            [switch]$NeverExits,
            [switch]$FailWrite,
            [string[]]$HelloSurfaces = @('screen'),
            [switch]$NoHello
        )
        if ($null -eq $OnRequest) { $OnRequest = { param($Frame) Get-StubDefaultAnswer -Frame $Frame } }
        $stub = @{
            Process         = $null
            StartTicks      = 0
            Sent            = [Collections.Generic.List[string]]::new()
            Lines           = [Collections.Generic.Queue[string]]::new()
            Pending         = $null
            Exited          = $false
            ExitSource      = [Threading.Tasks.TaskCompletionSource[bool]]::new()
            KillCount       = 0
            CloseInputCount = 0
            DisposeCount    = 0
            NeverExits      = [bool]$NeverExits
            FailWrite       = [bool]$FailWrite
            OnRequest       = $OnRequest
            OutTask         = $null
            ErrTask         = $null
            HelloDeadline   = $null
            Hello           = $null
        }
        if (-not $NoHello) { $stub.Hello = @{ protocol = 1; sessionId = 'stub'; surfaces = [object[]]@($HelloSurfaces) } }
        $stub.ExitTask = $stub.ExitSource.Task
        $stub.Exit = {
            if ($stub.Exited) { return }
            $stub.Exited = $true
            $null = $stub.ExitSource.TrySetResult($true)
            if ($null -ne $stub.Pending) {
                $pending = $stub.Pending
                $stub.Pending = $null
                $null = $pending.TrySetResult([NullString]::Value)
            }
        }.GetNewClosure()
        $stub.Push = {
            param($Line)
            if ($null -ne $stub.Pending) {
                $pending = $stub.Pending
                $stub.Pending = $null
                $null = $pending.TrySetResult([string]$Line)
            } else {
                $stub.Lines.Enqueue([string]$Line)
            }
        }.GetNewClosure()
        $stub.Reply = {
            param($Id, $Result)
            & $stub.Push (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'reply'; id = $Id; result = $Result }))
        }.GetNewClosure()
        $stub.Send = {
            param($Line)
            $stub.Sent.Add([string]$Line)
            $frame = ConvertFrom-WorkloadFrameLine -Line $Line
            if ([string]$frame['type'] -cne 'request') { return }
            $answer = & $stub.OnRequest $frame
            if ($null -eq $answer) { return }
            & $stub.Reply $frame['id'] $answer
            if ([string]$frame['method'] -ceq 'session.end' -and -not $stub.NeverExits) { & $stub.Exit }
        }.GetNewClosure()
        $stub.ReadNext = {
            if ($stub.Lines.Count -gt 0) { return [Threading.Tasks.Task]::FromResult[string]($stub.Lines.Dequeue()) }
            if ($stub.Exited) { return [Threading.Tasks.Task]::FromResult[string]([NullString]::Value) }
            $stub.Pending = [Threading.Tasks.TaskCompletionSource[string]]::new()
            return $stub.Pending.Task
        }.GetNewClosure()
        $stub.ReadOut = { $null }
        $stub.ReadErr = { $null }
        $stub.Pump = { -not $stub.FailWrite }.GetNewClosure()
        $stub.Kill = { $stub.KillCount++; & $stub.Exit }.GetNewClosure()
        $stub.CloseInput = { $stub.CloseInputCount++; if (-not $stub.NeverExits) { & $stub.Exit } }.GetNewClosure()
        $stub.Dispose = { $stub.DisposeCount++; & $stub.Exit }.GetNewClosure()
        $stub.ReadTask = & $stub.ReadNext
        return $stub
    }

    function Get-WorkloadTestStub {
        <#
        .SYNOPSIS
            The stub the factory hands out next: a prepared one, else a default one.
        #>
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][hashtable]$State)
        $script:Ordinals.Add($State.WorkerOrdinal)
        $stub = $(if ($script:PreparedStubs.Count -gt 0) { $script:PreparedStubs.Dequeue() } else { New-StubWorkloadWorker })
        $script:Stubs.Add($stub)
        return $stub
    }

    function New-WorkloadTestState {
        <#
        .SYNOPSIS
            A front-end state on the scripted clock, with a session root under TestDrive and the stub factory.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds an in-memory state and one folder under TestDrive.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param()
        $script:StateCount++
        $root = Join-Path $TestDrive ('sessions-{0}' -f $script:StateCount)
        $null = New-Item -ItemType Directory -Path $root -Force
        $writer = [IO.StringWriter]::new()
        $writer.NewLine = "`n"
        return Initialize-WorkloadMcpState -Writer $writer -SessionRoot $root -WorkerFactory { param($State) Get-WorkloadTestStub -State $State } -ClockTicks { $script:Now }
    }

    function Get-WorkloadTestCallLine {
        <#
        .SYNOPSIS
            The client line of one tools/call request.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)]$Id,
            [Parameter(Mandatory)][string]$Tool,
            [System.Collections.IDictionary]$Arguments = @{},
            [string]$ProgressToken
        )
        $params = [ordered]@{ name = $Tool; arguments = $Arguments }
        if ($ProgressToken) { $params['_meta'] = [ordered]@{ progressToken = $ProgressToken } }
        return (ConvertTo-Json -Compress -Depth 32 -InputObject ([ordered]@{ jsonrpc = '2.0'; id = $Id; method = 'tools/call'; params = $params }))
    }

    function Send-WorkloadTestCall {
        <#
        .SYNOPSIS
            Hands one tools/call line to the front end, as the loop does for a client line.
        #>
        [CmdletBinding()]
        [OutputType([void])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)]$Id,
            [Parameter(Mandatory)][string]$Tool,
            [System.Collections.IDictionary]$Arguments = @{},
            [string]$ProgressToken
        )
        Invoke-WorkloadMcpClientLine -State $State -Line (Get-WorkloadTestCallLine -Id $Id -Tool $Tool -Arguments $Arguments -ProgressToken $ProgressToken)
    }

    function Invoke-WorkloadTestWorkerLine {
        <#
        .SYNOPSIS
            Hands every line the stub worker queued to Invoke-WorkloadMcpWorkerFrame, as the loop would.
        #>
        [CmdletBinding()]
        [OutputType([void])]
        param([Parameter(Mandatory)][hashtable]$State)
        $worker = $State.Worker
        while ($null -ne $worker -and [object]::ReferenceEquals($State.Worker, $worker) -and $null -ne $worker.ReadTask -and $worker.ReadTask.IsCompleted) {
            $line = $worker.ReadTask.Result
            if ($null -eq $line) { break }
            Invoke-WorkloadMcpWorkerFrame -State $State -Line $line
            if ([object]::ReferenceEquals($State.Worker, $worker)) { $worker.ReadTask = & $worker.ReadNext }
        }
    }

    function Get-WorkloadTestMessage {
        <#
        .SYNOPSIS
            Every message the front end wrote to the state's writer, decoded.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory)][hashtable]$State)
        $lines = @($State.Writer.ToString() -split "`n" | Where-Object { $_ })
        return , [object[]]@($lines | ForEach-Object { ConvertFrom-Json -InputObject $_ -AsHashtable -DateKind String -NoEnumerate })
    }

    function Get-WorkloadTestAnswer {
        <#
        .SYNOPSIS
            The messages that answer one request id.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)]$Id
        )
        return , [object[]]@((Get-WorkloadTestMessage -State $State) | Where-Object {
                $_.Contains('id') -and ($_.Contains('result') -or $_.Contains('error')) -and ($_['id'] -is [string]) -eq ($Id -is [string]) -and $_['id'] -eq $Id
            })
    }

    function Get-WorkloadTestResult {
        <#
        .SYNOPSIS
            The tool result of the one answer to a request id, parsed from its first text item; throws unless exactly one answer exists.
        #>
        [CmdletBinding()]
        [OutputType([System.Collections.IDictionary])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            [Parameter(Mandatory)]$Id
        )
        $answers = Get-WorkloadTestAnswer -State $State -Id $Id
        if ($answers.Count -ne 1) { throw "request $Id has $($answers.Count) answers, expected one" }
        return (ConvertFrom-Json -InputObject $answers[0]['result']['content'][0]['text'] -AsHashtable -DateKind String -NoEnumerate)
    }

    function Get-WorkloadTestSentFrame {
        <#
        .SYNOPSIS
            The frames the front end sent to a stub, parsed, optionally only the requests of one method.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory)][hashtable]$Stub,
            [string]$Method
        )
        $frames = @($Stub.Sent | ForEach-Object { ConvertFrom-WorkloadFrameLine -Line $_ })
        if ($Method) { $frames = @($frames | Where-Object { [string]$_['type'] -ceq 'request' -and [string]$_['method'] -ceq $Method }) }
        return , [object[]]$frames
    }

    function Open-WorkloadTestSession {
        <#
        .SYNOPSIS
            Starts a session the stub answers and returns the start result.
        #>
        [CmdletBinding()]
        [OutputType([System.Collections.IDictionary])]
        param(
            [Parameter(Mandatory)][hashtable]$State,
            $Id = 1,
            [string]$VmName = 'vm-stub'
        )
        Send-WorkloadTestCall -State $State -Id $Id -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = $VmName })
        Invoke-WorkloadTestWorkerLine -State $State
        return (Get-WorkloadTestResult -State $State -Id $Id)
    }

    function Invoke-WorkloadMcpExchange {
        <#
        .SYNOPSIS
            Runs Invoke-WorkloadMcpLoop over the given client lines and returns every decoded message.
        .DESCRIPTION
            A StringReader reaches the end of input at once, which ends the
            session, so this serves only cases that complete inside one
            exchange.
        #>
        [CmdletBinding()]
        [OutputType([object[]])]
        param(
            [Parameter(Mandatory)][string[]]$Line,
            [hashtable]$State
        )
        if ($null -eq $State) { $State = New-WorkloadTestState }
        $reader = [IO.StringReader]::new(($Line -join "`n") + "`n")
        try {
            Invoke-WorkloadMcpLoop -Reader $reader -Writer $State.Writer -State $State
        } finally {
            $reader.Dispose()
        }
        return , (Get-WorkloadTestMessage -State $State)
    }

    function Initialize-WorkloadTestFixture {
        <#
        .SYNOPSIS
            Puts the scripted clock and the stub records of one case in their first state.
        #>
        [CmdletBinding()]
        [OutputType([void])]
        param()
        $script:Now = [long]1000000
        $script:Stubs = [Collections.Generic.List[object]]::new()
        $script:PreparedStubs = [Collections.Generic.Queue[object]]::new()
        $script:Ordinals = [Collections.Generic.List[object]]::new()
    }

    $script:ToolName = @('workload_action', 'workload_failure', 'workload_journal', 'workload_phrases', 'workload_run_sequence',
        'workload_save_sequence', 'workload_session_end', 'workload_session_start', 'workload_snapshot', 'workload_step',
        'workload_suggest_step')
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
}

Describe 'the protocol surface of the workload server' {
    BeforeEach { Initialize-WorkloadTestFixture }

    It 'answers initialize with a supported version and its own identity' {
        $messages = Invoke-WorkloadMcpExchange -Line @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}',
            '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}',
            '{"jsonrpc":"2.0","id":3,"method":"initialize"}')
        Assert-Equal 3 $messages.Count 'one answer per initialize'
        foreach ($message in $messages) {
            Assert-StringEqual '2025-06-18' $message['result']['protocolVersion'] "answer $($message['id'])"
            Assert-StringEqual 'yuruna-workload' $message['result']['serverInfo']['name'] "answer $($message['id'])"
        }
    }

    It 'sends the working rules as instructions' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')
        $reference = '${ext:authentication.GetPassword(${username})}'
        $expected = Format-CatalogMessage -Key 'runner.mcp_workload_instructions' -Arguments @{ reference = $reference } -Locale 'en-US'
        $instructions = [string]$messages[0]['result']['instructions']
        Assert-True ([string]::Equals($expected, $instructions, [StringComparison]::Ordinal)) "instructions differ from the catalog message: $instructions"
        $rules = @($instructions -split "`n")
        Assert-Equal 7 $rules.Count 'seven working rules'
        Assert-True ($rules[3].Contains($reference)) "the fourth rule lacks the reference: $($rules[3])"
        Assert-True ($rules[4].Contains('workload_still_waiting')) "the fifth rule lacks workload_still_waiting: $($rules[4])"
    }

    It 'declares the response budget as -MaxCallSeconds with the default 50' {
        $ast = Get-YurunaTestFileAst $script:ServerPath
        $parameter = @($ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'MaxCallSeconds' })
        Assert-Equal 1 $parameter.Count 'one MaxCallSeconds parameter'
        Assert-StringEqual '50' $parameter[0].DefaultValue.Extent.Text 'the default budget'
        $range = @($parameter[0].Attributes | Where-Object { $_.TypeName.Name -ceq 'ValidateRange' })
        Assert-Equal 1 $range.Count 'one ValidateRange attribute'
        Assert-StringEqual '30,600' (@($range[0].PositionalArguments | ForEach-Object { $_.Extent.Text }) -join ',') 'the range of the budget'
        $writer = [IO.StringWriter]::new()
        $state = Initialize-WorkloadMcpState -Writer $writer -SessionRoot (Join-Path $TestDrive 'budget')
        Assert-Equal 50000 $state.MaxCallMs 'the default MaxCallMs'
    }

    It 'loads no module of the sequence system' {
        $loaded = @(Get-Module -All | Where-Object {
                $_.Name -like 'Test.Sequence*' -or $_.Name -ceq 'Test.StepPhrase' -or $_.Name -ceq 'Test.Ssh' -or
                $_.Name -ceq 'Test.Transport' -or $_.Name -like 'Test.HostIO*' -or $_.Name -ceq 'Yuruna.Host'
            } | ForEach-Object { $_.Name })
        Assert-Equal 0 $loaded.Count "modules of the sequence system are loaded: $($loaded -join ', ')"
        $ast = Get-YurunaTestFileAst $script:ServerPath
        $imports = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Import-Module' }, $true))
        Assert-Equal 4 $imports.Count 'four Import-Module commands'
        $expected = @('Yuruna.Globalization.psm1', 'Test.YurunaDir.psm1', 'Test.LocalizationExchange.psm1', 'Test.WorkloadProtocol.psm1')
        for ($i = 0; $i -lt 4; $i++) {
            Assert-True ($imports[$i].Extent.Text.Contains($expected[$i])) "import $($i + 1) is not $($expected[$i]): $($imports[$i].Extent.Text)"
        }
    }

    It 'answers a method it does not know, server/discover included, with -32601' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":1,"method":"server/discover"}', '{"jsonrpc":"2.0","id":2,"method":"no/such/method"}')
        Assert-Equal 2 $messages.Count 'two answers'
        foreach ($message in $messages) { Assert-Equal -32601 $message['error']['code'] "answer $($message['id'])" }
    }

    It 'lists the eleven tools, sorted, with the annotations of the tool table' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
        $tools = @($messages[0]['result']['tools'])
        Assert-StringEqual ($script:ToolName -join ',') (@($tools | ForEach-Object { $_['name'] }) -join ',') 'the tool names in order'
        $hints = @{
            workload_action = 'False,True,True'; workload_failure = 'True,False,False'; workload_journal = 'True,False,False'
            workload_phrases = 'True,False,False'; workload_run_sequence = 'False,True,True'; workload_save_sequence = 'False,False,False'
            workload_session_end = 'False,False,True'; workload_session_start = 'False,False,False'; workload_snapshot = 'True,False,False'
            workload_step = 'False,True,True'; workload_suggest_step = 'True,False,False'
        }
        foreach ($tool in $tools) {
            $annotations = $tool['annotations']
            $actual = '{0},{1},{2}' -f $annotations['readOnlyHint'], $annotations['destructiveHint'], $annotations['idempotentHint']
            Assert-StringEqual $hints[$tool['name']] $actual "the hints of $($tool['name'])"
        }
    }

    It 'gives every tool a closed object schema without a top-level combinator' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
        $required = @{
            workload_action = 'operationId'; workload_failure = ''; workload_journal = ''; workload_phrases = ''
            workload_run_sequence = 'operationId'; workload_save_sequence = 'name,description,resource'; workload_session_end = ''
            workload_session_start = 'guestKey,vmName'; workload_snapshot = 'surface'; workload_step = 'operationId'; workload_suggest_step = 'ref'
        }
        foreach ($tool in @($messages[0]['result']['tools'])) {
            $schema = $tool['inputSchema']
            Assert-StringEqual 'object' $schema['type'] "type of $($tool['name'])"
            Assert-True ($schema['additionalProperties'] -is [bool] -and $schema['additionalProperties'] -eq $false) "additionalProperties of $($tool['name'])"
            foreach ($combinator in @('oneOf', 'anyOf', 'allOf')) {
                Assert-False ($schema.Contains($combinator)) "$($tool['name']) has a top-level $combinator"
            }
            Assert-StringEqual $required[$tool['name']] (@($schema['required']) -join ',') "required of $($tool['name'])"
        }
    }

    It 'renders every tool description from the catalog' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
        foreach ($tool in @($messages[0]['result']['tools'])) {
            $expected = Format-CatalogMessage -Key ('runner.mcp_' + $tool['name']) -Locale 'en-US'
            Assert-True ([string]::Equals($expected, [string]$tool['description'], [StringComparison]::Ordinal)) "the description of $($tool['name']) differs from the catalog"
        }
    }

    It 'answers a notification, and a response sent by the client, with nothing' {
        $messages = Invoke-WorkloadMcpExchange -Line @(
            '{"jsonrpc":"2.0","method":"notifications/initialized"}',
            '{"jsonrpc":"2.0","method":"notifications/unknown","params":{}}',
            '{"id":9,"result":{}}')
        Assert-Equal 0 $messages.Count 'no line for a notification or a response'
    }

    It 'rejects a line that is not JSON without ending the session' {
        $messages = Invoke-WorkloadMcpExchange -Line @('not json', '{"jsonrpc":"2.0","id":2,"method":"ping"}')
        Assert-Equal 2 $messages.Count 'two answers'
        Assert-Equal -32700 $messages[0]['error']['code'] 'the parse error'
        Assert-Equal 2 $messages[1]['id'] 'the ping is answered'
        Assert-True ($messages[1].Contains('result')) 'the ping has a result'
    }

    It 'rejects a batch, a request without a method and a line that is too long as invalid requests' {
        $long = '{"jsonrpc":"2.0","id":3,"method":"ping","params":{"pad":"' + ('x' * (Get-WorkloadProtocolLimit).MaxRequestLineChars) + '"}}'
        $messages = Invoke-WorkloadMcpExchange -Line @('[{"jsonrpc":"2.0","id":1,"method":"ping"}]', '{"jsonrpc":"2.0","id":2}', $long)
        Assert-Equal 3 $messages.Count 'three answers'
        foreach ($message in $messages) { Assert-Equal -32600 $message['error']['code'] 'an invalid request' }
    }

    It 'reports unknown methods and unknown tools distinctly' {
        $messages = Invoke-WorkloadMcpExchange -Line @(
            '{"jsonrpc":"2.0","id":1,"method":"tools/nope"}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workload_nope","arguments":{}}}')
        Assert-Equal -32601 $messages[0]['error']['code'] 'the unknown method'
        Assert-Equal -32602 $messages[1]['error']['code'] 'the unknown tool'
    }

    It 'echoes a string id unchanged' {
        $messages = Invoke-WorkloadMcpExchange -Line @('{"jsonrpc":"2.0","id":"abc-123","method":"ping"}')
        Assert-True ($messages[0]['id'] -is [string] -and $messages[0]['id'] -ceq 'abc-123') "the id came back as $($messages[0]['id'])"
    }

    It 'writes one JSON-RPC message per line and nothing else' {
        $state = New-WorkloadTestState
        $null = Invoke-WorkloadMcpExchange -State $state -Line @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize"}', '{"jsonrpc":"2.0","id":2,"method":"tools/list"}',
            '{"jsonrpc":"2.0","id":3,"method":"ping"}', 'not json', '{"jsonrpc":"2.0","method":"notifications/initialized"}',
            '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"workload_nope"}}')
        $text = $state.Writer.ToString()
        Assert-False ($text.Contains("`r")) 'a carriage return was written'
        $lines = @($text -split "`n" | Where-Object { $_ })
        Assert-Equal 5 $lines.Count 'five answers'
        foreach ($line in $lines) {
            $message = ConvertFrom-Json -InputObject $line -AsHashtable -DateKind String -NoEnumerate
            Assert-StringEqual '2.0' $message['jsonrpc'] "line: $line"
        }
    }

    It 'has no listener, takes no credential and never uses the console reader or writer' {
        $source = Get-YurunaTestSourceText $script:ServerPath
        $ast = Get-YurunaTestFileAst $script:ServerPath
        $parameters = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ParameterAst] }, $true))
        Assert-Equal 0 @($parameters | Where-Object { $_.Name.VariablePath.UserPath -like 'Listen*' }).Count 'a Listen parameter'
        Assert-Equal 0 @($parameters | Where-Object { $_.StaticType -eq [pscredential] -or $_.StaticType -eq [securestring] }).Count 'a credential parameter'
        foreach ($word in @('HttpListener', 'TcpListener', '[pscredential]', 'SecureString')) {
            Assert-False ($source.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -ge 0) "the source names $word"
        }
        Assert-False ($source -match '\[Console\]::(?:In|Out)\b') 'the source uses the console reader or writer'
        $loops = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-WorkloadMcpLoop' }, $true))
        $entry = @(foreach ($loop in $loops) {
                $ancestor = $loop.Parent
                while ($null -ne $ancestor -and $ancestor -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $ancestor = $ancestor.Parent }
                if ($null -eq $ancestor) { $loop }
            })
        Assert-Equal 1 $entry.Count 'one entry statement'
        $streams = @($entry[0].Redirections | ForEach-Object { [string]$_.FromStream } | Sort-Object)
        Assert-StringEqual 'Debug,Information,Verbose,Warning' ($streams -join ',') 'the entry redirects streams 3 to 6'
    }
}

Describe 'arguments the workload server refuses before any worker' {
    BeforeEach { Initialize-WorkloadTestFixture }

    It 'refuses arguments that break a schema and sends the worker nothing' {
        $state = New-WorkloadTestState
        # Two keys that differ only in case need a dictionary that compares keys ordinally.
        $caseKeys = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
        $caseKeys['guestKey'] = 'guest.a'
        $caseKeys['vmName'] = 'vm-a'
        $caseKeys['VmName'] = 'vm-b'
        $bad = [ordered]@{
            workload_action        = [ordered]@{ operationId = 'op-1'; action = 'inputText'; fields = [ordered]@{}; intent = 'i'; extra = 1 }
            workload_failure       = [ordered]@{ unknown = 1 }
            workload_journal       = [ordered]@{ unknown = 1 }
            workload_phrases       = [ordered]@{ Search = 'login' }
            workload_run_sequence  = [ordered]@{ operationId = 'op-1'; sequence = 'start.guest.x'; timeoutSeconds = 59 }
            workload_save_sequence = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a'); componentSteps = 'two' }
            workload_session_end   = [ordered]@{ unknown = 1 }
            workload_session_start = $caseKeys
            workload_snapshot      = [ordered]@{ surface = 'screen'; image = 'yes' }
            workload_step          = [ordered]@{ operationId = '-op' }
            workload_suggest_step  = [ordered]@{ ref = 's0' }
        }
        $id = 0
        foreach ($tool in $bad.Keys) {
            $id++
            Send-WorkloadTestCall -State $state -Id $id -Tool $tool -Arguments $bad[$tool]
            $answers = Get-WorkloadTestAnswer -State $state -Id $id
            Assert-Equal 1 $answers.Count "one answer for $tool"
            Assert-Equal -32602 $answers[0]['error']['code'] "the schema refusal of $tool"
        }
        Assert-Equal 0 $script:Stubs.Count 'a worker was opened'
        Assert-Null $state.Worker 'the state holds a worker'
    }

    It 'refuses the arguments this server does not take' {
        $state = New-WorkloadTestState
        $calls = @(
            @{ Tool = 'workload_run_sequence'; Arguments = [ordered]@{ operationId = 'op-1'; sequence = 'start.guest.x'; startStep = 2 } }
            @{ Tool = 'workload_run_sequence'; Arguments = [ordered]@{ operationId = 'op-1'; sequence = 'start.guest.x'; stopStep = 2 } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a'); folder = 'x' } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a'); keystrokeMechanism = 'ssh' } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = [ordered]@{ a = 'b' } } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @() } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd' } }
        )
        $id = 0
        foreach ($call in $calls) {
            $id++
            Send-WorkloadTestCall -State $state -Id $id -Tool $call.Tool -Arguments $call.Arguments
            $answers = Get-WorkloadTestAnswer -State $state -Id $id
            Assert-Equal 1 $answers.Count "one answer for call $id"
            Assert-Equal -32602 $answers[0]['error']['code'] "call $id of $($call.Tool)"
        }
        Assert-Equal 0 $script:Stubs.Count 'a worker was opened'
    }

    It 'refuses a run form that lacks a field and a cancel beside run fields' {
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next' })
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_action' -Arguments ([ordered]@{ operationId = 'op-2'; action = 'pressKey'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-3'; step = 'click Next'; intent = 'i'; cancel = $true })
        $first = (Get-WorkloadTestAnswer -State $state -Id 1)[0]
        $second = (Get-WorkloadTestAnswer -State $state -Id 2)[0]
        $third = (Get-WorkloadTestAnswer -State $state -Id 3)[0]
        Assert-Equal -32602 $first['error']['code'] 'a run form without intent'
        Assert-Match 'intent' $first['error']['message'] 'the message names the missing field'
        Assert-Equal -32602 $second['error']['code'] 'a run form without fields'
        Assert-Match 'fields' $second['error']['message'] 'the message names the missing field'
        Assert-Equal -32602 $third['error']['code'] 'a cancel beside run fields'
        Assert-Match 'cancel' $third['error']['message'] 'the message names cancel'
        Assert-Equal 0 $script:Stubs.Count 'a worker was opened'
    }

    It 'passes an ISO date in an argument to the worker as the same text' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $sent = 'type 2026-11-17T03:15:02.123+01:00 and press Enter'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = $sent; intent = 'i' })
        $request = (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'step.run')
        Assert-Equal 1 $request.Count 'one step.run'
        Assert-True ($request[0]['params']['step'] -is [string] -and [string]::Equals($sent, $request[0]['params']['step'], [StringComparison]::Ordinal)) "the step arrived as $($request[0]['params']['step'])"
    }

    It 'answers tools that need a session with workload_no_session before attachment' {
        $state = New-WorkloadTestState
        $calls = @(
            @{ Tool = 'workload_snapshot'; Arguments = [ordered]@{ surface = 'screen' } }
            @{ Tool = 'workload_suggest_step'; Arguments = [ordered]@{ ref = 's1' } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a') } }
            @{ Tool = 'workload_step'; Arguments = [ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' } }
            @{ Tool = 'workload_action'; Arguments = [ordered]@{ operationId = 'op-2'; action = 'pressKey'; fields = [ordered]@{ key = 'Enter' }; intent = 'i' } }
            @{ Tool = 'workload_run_sequence'; Arguments = [ordered]@{ operationId = 'op-3'; sequence = 'start.guest.x' } }
            @{ Tool = 'workload_journal'; Arguments = [ordered]@{} }
            @{ Tool = 'workload_failure'; Arguments = [ordered]@{} }
        )
        $id = 0
        foreach ($call in $calls) {
            $id++
            Send-WorkloadTestCall -State $state -Id $id -Tool $call.Tool -Arguments $call.Arguments
            $answer = (Get-WorkloadTestAnswer -State $state -Id $id)[0]
            Assert-True ($answer['result']['isError'] -eq $true) "$($call.Tool) is not an error"
            $result = Get-WorkloadTestResult -State $state -Id $id
            Assert-StringEqual 'workload_no_session' $result['error']['code'] "the code of $($call.Tool)"
        }
        Assert-Equal 0 $script:Stubs.Count 'a worker was opened'
    }
}

Describe 'sessions of the workload server' {
    BeforeEach { Initialize-WorkloadTestFixture }

    It 'opens a worker for workload_phrases before attachment and keeps it for the start' {
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_phrases'
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-True ((Get-WorkloadTestResult -State $state -Id 1)['ok'] -eq $true) 'the phrases call failed'
        $start = Open-WorkloadTestSession -State $state -Id 2
        Assert-True ($start['ok'] -eq $true) 'the start failed'
        Assert-Equal 1 $script:Stubs.Count 'the factory ran more than once'
    }

    It 'ends an absent session without error, twice' {
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_end'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        foreach ($id in 1, 2) {
            $answer = (Get-WorkloadTestAnswer -State $state -Id $id)[0]
            Assert-True ($answer['result']['isError'] -eq $false) "end $id is an error"
            Assert-True ((Get-WorkloadTestResult -State $state -Id $id)['ended'] -eq $false) "end $id ended a session"
        }
    }

    It 'refuses a second start with other input and joins one with the same input' {
        $state = New-WorkloadTestState
        $first = Open-WorkloadTestSession -State $state -Id 1 -VmName 'vm-a'
        Assert-True ($first['ok'] -eq $true) 'the first start failed'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-b' })
        Assert-StringEqual 'workload_session_active' (Get-WorkloadTestResult -State $state -Id 2)['error']['code'] 'another start'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        $firstText = (Get-WorkloadTestAnswer -State $state -Id 1)[0]['result']['content'][0]['text']
        $thirdText = (Get-WorkloadTestAnswer -State $state -Id 3)[0]['result']['content'][0]['text']
        Assert-True ([string]::Equals($firstText, $thirdText, [StringComparison]::Ordinal)) 'the joined start did not answer the stored result'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'session.start').Count 'session.start requests'
        Assert-StringEqual 'active' $state.Session.Phase 'the first session stays'
    }

    It 'reports a start that outlives the budget as starting and joins a repeated identical start' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.start') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $arguments = [ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' }
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments $arguments
        $script:Now += $state.MaxCallMs
        $null = Invoke-WorkloadMcpTimer -State $state
        $answer = (Get-WorkloadTestAnswer -State $state -Id 1)[0]
        Assert-True ($answer['result']['isError'] -eq $false) 'the starting answer is an error'
        Assert-StringEqual 'starting' (Get-WorkloadTestResult -State $state -Id 1)['state'] 'the state of a slow start'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_start' -Arguments $arguments
        Assert-Equal 0 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'the repeated start was answered before the reply'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'session.start')[0]
        & $stub.Reply $request['id'] (Get-StubDefaultAnswer -Frame $request)
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-True ((Get-WorkloadTestResult -State $state -Id 2)['ok'] -eq $true) 'the repeated start did not get the session'
        Assert-Equal 1 (Get-WorkloadTestAnswer -State $state -Id 1).Count 'the first call was answered twice'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $stub -Method 'session.start').Count 'session.start requests'
    }

    It 'closes the worker when its start fails or times out and allows a new start' {
        $refusing = New-StubWorkloadWorker -OnRequest { param($Frame)
            if ([string]$Frame['method'] -ceq 'session.start') { return @{ ok = $false; error = @{ code = 'workload_vm_stopped'; message = 'm' } } }
            Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($refusing)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-StringEqual 'workload_vm_stopped' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'the refusal of the worker'
        Assert-StringEqual 'none' $state.Session.Phase 'the phase after a refused start'
        Assert-Equal 1 $refusing.CloseInputCount 'CloseInput of the refusing worker'
        Assert-Equal 0 $refusing.KillCount 'Kill of the refusing worker'
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        $second = Open-WorkloadTestSession -State $state -Id 2
        Assert-True ($second['ok'] -eq $true) 'the new start failed'
        Assert-Equal 2 $state.WorkerOrdinal 'the worker of the new start'
        Assert-Equal 2 $script:Stubs.Count 'workers opened'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[1] -Method 'session.start').Count 'the second worker got the start'

        try {
            $script:SessionStartTimeoutSeconds = 10
            $holding = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.start') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
            $script:PreparedStubs.Enqueue($holding)
            $timed = New-WorkloadTestState
            Send-WorkloadTestCall -State $timed -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
            $script:Now += 10000
            Assert-True ($script:Now -lt $timed.Calls[0].Deadline) 'the clock passed the call deadline'
            $null = Invoke-WorkloadMcpTimer -State $timed
            Assert-StringEqual 'workload_worker_start_failed' (Get-WorkloadTestResult -State $timed -Id 1)['error']['code'] 'the timed-out start'
            Assert-StringEqual 'none' $timed.Session.Phase 'the phase after a timed-out start'
            Assert-Equal 1 $holding.CloseInputCount 'CloseInput of the holding worker'
            Assert-Equal 0 $holding.KillCount 'Kill of the holding worker'
            Invoke-WorkloadMcpWorkerExit -State $timed -Reason 'exited'
            $again = Open-WorkloadTestSession -State $timed -Id 2
            Assert-True ($again['ok'] -eq $true) 'the start after the timeout failed'
            Assert-Equal 2 $timed.WorkerOrdinal 'the worker of the start after the timeout'
            Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[3] -Method 'session.start').Count 'the next worker got the start'
        } finally {
            $script:SessionStartTimeoutSeconds = 180
        }
    }

    It 'opens a new worker for a start that arrives while a failed one closes' {
        $first = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.start') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($first)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_phrases'
        $request = (Get-WorkloadTestSentFrame -Stub $first -Method 'session.start')[0]
        & $first.Reply $request['id'] @{ ok = $false; error = @{ code = 'workload_vm_stopped'; message = 'm' } }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $state -Id 2)['error']['code'] 'the queued phrases call'
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $first -Method 'phrases.list').Count 'phrases.list reached the failed worker'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Assert-Equal 1 $first.KillCount 'Kill of the closing worker'
        Assert-Equal 2 $script:Stubs.Count 'the factory runs'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[1] -Method 'session.start').Count 'the second worker got the start'
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-True ((Get-WorkloadTestResult -State $state -Id 3)['ok'] -eq $true) 'the second start failed'
    }

    It 'gives a later session a new worker ordinal and no operations' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state -Id 1
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 2)['state'] 'the operation of the first session'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_session_end'
        Invoke-WorkloadTestWorkerLine -State $state
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        Assert-True ((Get-WorkloadTestResult -State $state -Id 3)['ended'] -eq $true) 'the session did not end'
        $null = Open-WorkloadTestSession -State $state -Id 4
        Assert-StringEqual '1,2' ($script:Ordinals -join ',') 'the worker ordinals the factory saw'
        Send-WorkloadTestCall -State $state -Id 5 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-StringEqual 'workload_operation_unknown' (Get-WorkloadTestResult -State $state -Id 5)['error']['code'] 'a poll of the first session'
    }

    It 'refuses a surface the worker did not offer' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $sentAfterStart = $script:Stubs[0].Sent.Count
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; on = 'page'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'page' })
        foreach ($id in 2, 3) {
            Assert-StringEqual 'workload_surface_unsupported' (Get-WorkloadTestResult -State $state -Id $id)['error']['code'] "call $id"
        }
        Assert-Equal $sentAfterStart $script:Stubs[0].Sent.Count 'a line was sent after the start'
    }

    It 'forwards the page surface when the worker offers it' {
        $script:PreparedStubs.Enqueue((New-StubWorkloadWorker -HelloSurfaces @('screen', 'page')))
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'page' })
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; on = 'page'; intent = 'i' })
        Invoke-WorkloadTestWorkerLine -State $state
        $snapshot = (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'snapshot.take')
        $step = (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'step.run')
        Assert-Equal 1 $snapshot.Count 'snapshot.take requests'
        Assert-StringEqual 'page' $snapshot[0]['params']['surface'] 'the snapshot surface'
        Assert-Equal 1 $step.Count 'step.run requests'
        Assert-StringEqual 'page' $step[0]['params']['on'] 'the step surface'
        Assert-False ($state.Writer.ToString().Contains('workload_surface_unsupported')) 'a page surface was refused'
    }
}

Describe 'operations of the workload server' {
    BeforeEach { Initialize-WorkloadTestFixture }

    It 'returns the result of an operation that ends inside the budget' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadTestWorkerLine -State $state
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'succeeded' $result['state'] 'the state'
        Assert-StringEqual 'op-1' $result['operationId'] 'the operationId'
    }

    It 'answers still waiting when the budget passes and the result on a later poll' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $script:Now += $state.MaxCallMs
        $null = Invoke-WorkloadMcpTimer -State $state
        $answer = (Get-WorkloadTestAnswer -State $state -Id 2)[0]
        $waiting = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'workload_still_waiting' $waiting['noteCode'] 'the note'
        Assert-StringEqual 'running' $waiting['state'] 'the state'
        Assert-True ($answer['result']['isError'] -eq $false) 'still waiting is an error'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        & $stub.Reply $request['id'] @{ ok = $true }
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 3)['state'] 'the poll after the reply'
    }

    It 'answers still waiting at the budget and not one tick earlier' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $start = $script:Now
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $script:Now = $start + $state.MaxCallMs - 1
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal 0 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'answered one tick before the budget'
        $script:Now = $start + $state.MaxCallMs
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-StringEqual 'workload_still_waiting' (Get-WorkloadTestResult -State $state -Id 2)['noteCode'] 'the answer at the budget'
    }

    It 'returns a failed operation as a tool error with its code, class and message' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame)
            if ([string]$Frame['method'] -ceq 'step.run') { return @{ ok = $false; state = 'failed'; error = @{ code = 'workload_step_failed'; class = 'wait_timeout'; message = 'm' } } }
            Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-True ((Get-WorkloadTestAnswer -State $state -Id 2)[0]['result']['isError'] -eq $true) 'a failed operation is not an error'
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'failed' $result['state'] 'the state'
        Assert-StringEqual 'workload_step_failed' $result['error']['code'] 'the code'
        Assert-StringEqual 'wait_timeout' $result['error']['class'] 'the class'
        Assert-StringEqual 'm' $result['error']['message'] 'the message'
    }

    It 'dispatches once when the same id and input arrive again' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $arguments = [ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' }
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments $arguments
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments $arguments
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'step.run').Count 'step.run requests'
        $first = (Get-WorkloadTestAnswer -State $state -Id 2)[0]['result']['content'][0]['text']
        $second = (Get-WorkloadTestAnswer -State $state -Id 3)[0]['result']['content'][0]['text']
        Assert-True ([string]::Equals($first, $second, [StringComparison]::Ordinal)) 'the two results differ'
    }

    It 'refuses an id reused with other input or by another tool' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Back'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_action' -Arguments ([ordered]@{ operationId = 'op-1'; action = 'pressKey'; fields = [ordered]@{ key = 'Enter' }; intent = 'i' })
        foreach ($id in 3, 4) {
            Assert-StringEqual 'workload_operation_conflict' (Get-WorkloadTestResult -State $state -Id $id)['error']['code'] "call $id"
        }
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'step.run').Count 'step.run requests'
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'action.run').Count 'action.run requests'
    }

    It 'answers a poll for an id that never ran with workload_operation_unknown' {
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-never' })
        Assert-StringEqual 'workload_operation_unknown' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'a poll of an unknown id'
    }

    It 'refuses new work while an operation runs and still serves polls, journal and failure' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $busy = @(
            @{ Tool = 'workload_step'; Arguments = [ordered]@{ operationId = 'op-2'; step = 'click Back'; intent = 'i' } }
            @{ Tool = 'workload_snapshot'; Arguments = [ordered]@{ surface = 'screen' } }
            @{ Tool = 'workload_suggest_step'; Arguments = [ordered]@{ ref = 's1' } }
            @{ Tool = 'workload_save_sequence'; Arguments = [ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a') } }
            @{ Tool = 'workload_phrases'; Arguments = [ordered]@{} }
        )
        $id = 10
        foreach ($call in $busy) {
            $id++
            Send-WorkloadTestCall -State $state -Id $id -Tool $call.Tool -Arguments $call.Arguments
            Assert-StringEqual 'workload_busy' (Get-WorkloadTestResult -State $state -Id $id)['error']['code'] "$($call.Tool) while an operation runs"
        }
        $journal = '{"ok":true,"entries":[],"stateChanges":[]}'
        $failure = '{"ok":true,"failure":null}'
        [IO.File]::WriteAllText((Join-Path $state.Session.Folder 'journal.result.json'), $journal)
        [IO.File]::WriteAllText((Join-Path $state.Session.Folder 'failure.result.json'), $failure)
        Send-WorkloadTestCall -State $state -Id 20 -Tool 'workload_journal'
        Send-WorkloadTestCall -State $state -Id 21 -Tool 'workload_failure'
        Assert-StringEqual $journal (Get-WorkloadTestAnswer -State $state -Id 20)[0]['result']['content'][0]['text'] 'the journal'
        Assert-StringEqual $failure (Get-WorkloadTestAnswer -State $state -Id 21)[0]['result']['content'][0]['text'] 'the failure'
        Send-WorkloadTestCall -State $state -Id 22 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-Equal 0 (Get-WorkloadTestAnswer -State $state -Id 22).Count 'the poll was refused'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        & $stub.Reply $request['id'] @{ ok = $true }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 22)['state'] 'the poll is answered with the result'
    }

    It 'sends one cancel frame and reports the state the worker ends in' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; cancel = $true })
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; cancel = $true })
        Assert-Equal 1 @((Get-WorkloadTestSentFrame -Stub $stub) | Where-Object { [string]$_['type'] -ceq 'cancel' }).Count 'cancel frames'
        $script:Now += $state.MaxCallMs
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-StringEqual 'canceling' (Get-WorkloadTestResult -State $state -Id 4)['state'] 'the poll answered meanwhile'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        & $stub.Reply $request['id'] @{ ok = $false; state = 'canceled'; error = @{ code = 'workload_operation_canceled' } }
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 5 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        $canceled = Get-WorkloadTestResult -State $state -Id 5
        Assert-StringEqual 'canceled' $canceled['state'] 'the state the worker ended in'
        Assert-StringEqual 'workload_operation_canceled' $canceled['error']['code'] 'the error code'
        Assert-StringEqual 'code' (@($canceled['error'].Keys) -join ',') 'the error was changed'

        Send-WorkloadTestCall -State $state -Id 6 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-2'; step = 'click Next'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 7 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-2'; cancel = $true })
        $second = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[1]
        & $stub.Reply $second['id'] @{ ok = $true }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 7)['state'] 'a canceled operation that the worker finished'
    }

    It 'cancels an operation that was never sent without sending it' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; cancel = $true })
        $result = Get-WorkloadTestResult -State $state -Id 4
        Assert-StringEqual 'canceled' $result['state'] 'the state'
        Assert-StringEqual 'workload_not_dispatched' $result['error']['code'] 'the code'
        Assert-StringEqual 'none-proven' $result['effect'] 'the effect'
        Assert-True ($result['dispatched'] -eq $false) 'dispatched'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take')[0]
        & $stub.Reply $request['id'] @{ ok = $true; surface = 'screen'; text = '' }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run').Count 'step.run reached the worker'
    }

    It 'finishes an operation queued at session end as not dispatched' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_session_end'
        Send-WorkloadTestCall -State $state -Id 5 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-StringEqual 'workload_not_dispatched' (Get-WorkloadTestResult -State $state -Id 5)['error']['code'] 'the poll of the queued operation'
    }

    It 'answers -32603 and keeps serving when handling a line throws' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Mock Get-WorkloadInputHash { throw 'x' }
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $answers = Get-WorkloadTestAnswer -State $state -Id 2
        Assert-Equal 1 $answers.Count 'one answer'
        Assert-Equal -32603 $answers[0]['error']['code'] 'the internal error'
        Invoke-WorkloadMcpClientLine -State $state -Line '{"jsonrpc":"2.0","id":3,"method":"ping"}'
        Assert-Equal 1 (Get-WorkloadTestAnswer -State $state -Id 3).Count 'the ping'
        $before = $state.Writer.ToString().Length
        $script:Now += $state.MaxCallMs + 1
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal $before $state.Writer.ToString().Length 'the timer answered the failed call'
    }

    It 'does not cancel the operation when the client cancels the request' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadMcpClientLine -State $state -Line '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}'
        Assert-Equal 0 @((Get-WorkloadTestSentFrame -Stub $stub) | Where-Object { [string]$_['type'] -ceq 'cancel' }).Count 'a cancel frame was sent'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        & $stub.Reply $request['id'] @{ ok = $true }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal 0 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'the canceled request was answered'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 3)['state'] 'the later poll'
    }

    It 'forwards the arguments of workload_save_sequence and returns a worker refusal as a tool error' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame)
            if ([string]$Frame['method'] -ceq 'sequence.save') { return @{ ok = $false; error = @{ code = 'workload_name_exists'; message = 'm' } } }
            Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_save_sequence' -Arguments ([ordered]@{
                name = 'workload.guest.stub.check'; description = 'Check the stub'; resource = @('start.guest.stub', 'workload.guest.stub'); componentSteps = 2 })
        Invoke-WorkloadTestWorkerLine -State $state
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'sequence.save')
        Assert-Equal 1 $request.Count 'sequence.save requests'
        $params = $request[0]['params']
        Assert-StringEqual 'workload.guest.stub.check' $params['name'] 'name'
        Assert-StringEqual 'Check the stub' $params['description'] 'description'
        Assert-True ($params['resource'] -is [System.Collections.IList]) 'resource is not a list'
        Assert-StringEqual 'start.guest.stub,workload.guest.stub' (@($params['resource']) -join ',') 'resource'
        Assert-Equal 2 $params['componentSteps'] 'componentSteps'
        Assert-True ((Get-WorkloadTestAnswer -State $state -Id 2)[0]['result']['isError'] -eq $true) 'the refusal is not an error'
        Assert-StringEqual 'workload_name_exists' (Get-WorkloadTestResult -State $state -Id 2)['error']['code'] 'the code'
    }

    It 'forwards progress only to a waiting request that sent a token' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' }) -ProgressToken 'tk'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        & $stub.Push (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'progress'; id = $request['id']; completed = 0; total = 3; label = 'go' }))
        Invoke-WorkloadTestWorkerLine -State $state
        & $stub.Push (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'progress'; id = $request['id']; completed = 1; total = 3; label = 'go' }))
        Invoke-WorkloadTestWorkerLine -State $state
        & $stub.Reply $request['id'] @{ ok = $true }
        Invoke-WorkloadTestWorkerLine -State $state
        $notifications = @((Get-WorkloadTestMessage -State $state) | Where-Object { [string]$_['method'] -ceq 'notifications/progress' })
        Assert-Equal 2 $notifications.Count 'progress notifications'
        foreach ($notification in $notifications) { Assert-StringEqual 'tk' $notification['params']['progressToken'] 'the token' }
        Assert-Equal 1 $notifications[0]['params']['progress'] 'the first progress'
        Assert-Equal 2 $notifications[1]['params']['progress'] 'the second progress'
        Assert-StringEqual '0/3 go' $notifications[0]['params']['message'] 'the first message'
        $count = (Get-WorkloadTestMessage -State $state).Count
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'progress'; id = $request['id']; completed = 2; total = 3; label = 'go' }))
        Assert-Equal $count (Get-WorkloadTestMessage -State $state).Count 'progress after the answer was forwarded'
        Assert-StringEqual 'succeeded' (Get-WorkloadTestResult -State $state -Id 3)['state'] 'the call without a token'
    }

    It 'marks a running operation uncertain when the worker is lost' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $arguments = [ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' }
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments $arguments
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'lost'
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'workload_worker_lost' $result['error']['code'] 'the code'
        Assert-StringEqual 'uncertain' $result['state'] 'the state'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments $arguments
        Assert-StringEqual 'uncertain' (Get-WorkloadTestResult -State $state -Id 3)['state'] 'the repeated run form'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run').Count 'step.run requests'
        Assert-Equal 1 $script:Stubs.Count 'a worker was opened for the repeated run form'
    }

    It 'answers a call that outlives the budget with workload_call_timeout and drops the late reply' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        $script:Now += $state.MaxCallMs
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-StringEqual 'workload_call_timeout' (Get-WorkloadTestResult -State $state -Id 2)['error']['code'] 'the timed-out call'
        $before = $state.Writer.ToString().Length
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take')[0]
        & $stub.Reply $request['id'] @{ ok = $true; surface = 'screen'; text = '' }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal $before $state.Writer.ToString().Length 'the late reply wrote a line'
    }

    It 'queues calls in arrival order and refuses the one past the limit' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        for ($id = 100; $id -lt 116; $id++) { Send-WorkloadTestCall -State $state -Id $id -Tool 'workload_phrases' }
        Assert-Equal 16 $state.Queue.Count 'queued calls'
        Send-WorkloadTestCall -State $state -Id 200 -Tool 'workload_phrases'
        Assert-StringEqual 'workload_queue_full' (Get-WorkloadTestResult -State $state -Id 200)['error']['code'] 'the call past the limit'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take')[0]
        & $stub.Reply $request['id'] @{ ok = $true; surface = 'screen'; text = '' }
        Invoke-WorkloadTestWorkerLine -State $state
        $order = @((Get-WorkloadTestMessage -State $state) | Where-Object { $_['id'] -ge 100 -and $_['id'] -lt 116 } | ForEach-Object { $_['id'] })
        Assert-StringEqual ((100..115) -join ',') ($order -join ',') 'the order of the answers'
    }

    It 'ends the session when the client ends: cancel, end request, bounded wait, kill' {
        $stub = New-StubWorkloadWorker -NeverExits -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $null = Close-WorkloadMcpSession -State $state -Reason 'client-ended'
        $frames = (Get-WorkloadTestSentFrame -Stub $stub)
        Assert-StringEqual 'cancel' $frames[-2]['type'] 'the frame before the end request'
        Assert-StringEqual 'session.end' $frames[-1]['method'] 'the last frame'
        Assert-StringEqual 'client-ended' $frames[-1]['params']['reason'] 'the end reason'
        $script:Now = [long]$state.Session.EndDeadline - 1
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal 0 $stub.KillCount 'killed before the grace passed'
        $script:Now = [long]$state.Session.EndDeadline
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal 1 $stub.KillCount 'not killed after the grace'
    }

    It 'serves journal and failure from the session files after the worker is lost' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $journal = '{"ok":true,"entries":[{"seq":1}],"stateChanges":[]}'
        $failure = '{"ok":true,"failure":{"failureClass":"wait_timeout"}}'
        [IO.File]::WriteAllText((Join-Path $state.Session.Folder 'journal.result.json'), $journal)
        [IO.File]::WriteAllText((Join-Path $state.Session.Folder 'failure.result.json'), $failure)
        Invoke-WorkloadMcpWorkerLost -State $state -Detail 'test'
        Assert-Null $state.Worker 'the worker is still there'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_journal'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_failure'
        Assert-StringEqual $journal (Get-WorkloadTestAnswer -State $state -Id 2)[0]['result']['content'][0]['text'] 'the journal'
        Assert-StringEqual $failure (Get-WorkloadTestAnswer -State $state -Id 3)[0]['result']['content'][0]['text'] 'the failure'
    }

    It 'returns the snapshot text as its own item and the image only when permitted' {
        $png = Join-Path $TestDrive 'frame.png'
        [IO.File]::WriteAllBytes($png, [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3))
        $script:SnapshotReply = $null
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $script:SnapshotReply }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $text = "# surface: screen   snapshot: 1`n- line `"Next`" [ref=s1]"

        $script:SnapshotReply = [ordered]@{ ok = $true; surface = 'screen'; snapshot = 1; text = $text; imagePath = $png }
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen'; image = $true })
        Invoke-WorkloadTestWorkerLine -State $state
        $content = @((Get-WorkloadTestAnswer -State $state -Id 2)[0]['result']['content'])
        Assert-Equal 3 $content.Count 'items with an image'
        $first = ConvertFrom-Json -InputObject $content[0]['text'] -AsHashtable -DateKind String -NoEnumerate
        Assert-False ($first.Contains('text')) 'the first item holds the text'
        Assert-StringEqual $png $first['imagePath'] 'the image path'
        Assert-StringEqual 'returned' $first['image'] 'the image member'
        Assert-StringEqual 'ok,surface,snapshot,imagePath,image' (@($first.Keys) -join ',') 'the members of the first item'
        Assert-StringEqual $text $content[1]['text'] 'the text item'
        Assert-StringEqual 'image' $content[2]['type'] 'the image item'
        Assert-StringEqual 'image/png' $content[2]['mimeType'] 'the image type'
        Assert-StringEqual ([Convert]::ToBase64String([IO.File]::ReadAllBytes($png))) $content[2]['data'] 'the image data'

        $script:SnapshotReply = [ordered]@{ ok = $true; surface = 'screen'; snapshot = 2; text = $text; imageWithheld = $true }
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen'; image = $true })
        Invoke-WorkloadTestWorkerLine -State $state
        $content = @((Get-WorkloadTestAnswer -State $state -Id 3)[0]['result']['content'])
        Assert-Equal 2 $content.Count 'items with a withheld image'
        $first = ConvertFrom-Json -InputObject $content[0]['text'] -AsHashtable -DateKind String -NoEnumerate
        Assert-StringEqual 'withheld' $first['image'] 'the withheld image'
        Assert-False ($first.Contains('imagePath')) 'a withheld image has a path'

        $script:SnapshotReply = [ordered]@{ ok = $true; surface = 'screen'; snapshot = 3; text = $text }
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Invoke-WorkloadTestWorkerLine -State $state
        $content = @((Get-WorkloadTestAnswer -State $state -Id 4)[0]['result']['content'])
        Assert-Equal 2 $content.Count 'items without an image'
        Assert-StringEqual 'none' (ConvertFrom-Json -InputObject $content[0]['text'] -AsHashtable -NoEnumerate)['image'] 'no image'

        $script:SnapshotReply = [ordered]@{ ok = $true; surface = 'screen'; snapshot = 4; text = $text; imagePath = (Join-Path $TestDrive 'no-such.png') }
        Send-WorkloadTestCall -State $state -Id 5 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen'; image = $true })
        Invoke-WorkloadTestWorkerLine -State $state
        $content = @((Get-WorkloadTestAnswer -State $state -Id 5)[0]['result']['content'])
        Assert-Equal 2 $content.Count 'items for a missing frame'
        $first = ConvertFrom-Json -InputObject $content[0]['text'] -AsHashtable -DateKind String -NoEnumerate
        Assert-StringEqual 'too_large' $first['image'] 'a missing frame'
        Assert-True ($first.Contains('imagePath')) 'the path of a missing frame was dropped'

        $script:RealLimit = Get-WorkloadProtocolLimit
        Mock Get-WorkloadProtocolLimit {
            $table = [ordered]@{}
            foreach ($key in $script:RealLimit.Keys) { $table[$key] = $script:RealLimit[$key] }
            $table['MaxImageBytes'] = 8
            $table
        }
        $script:SnapshotReply = [ordered]@{ ok = $true; surface = 'screen'; snapshot = 5; text = $text; imagePath = $png }
        Send-WorkloadTestCall -State $state -Id 6 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen'; image = $true })
        Invoke-WorkloadTestWorkerLine -State $state
        $content = @((Get-WorkloadTestAnswer -State $state -Id 6)[0]['result']['content'])
        Assert-Equal 2 $content.Count 'items for a frame over the limit'
        $first = ConvertFrom-Json -InputObject $content[0]['text'] -AsHashtable -DateKind String -NoEnumerate
        Assert-StringEqual 'too_large' $first['image'] 'a frame over the limit'
        Assert-StringEqual $png $first['imagePath'] 'the path of a frame over the limit'
    }

    It 'masks registered values in the worker log, also across two reads' {
        $stub = New-StubWorkloadWorker
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $value = 'S3cr3t-log-1'
        Add-WorkloadMcpWorkerLog -State $state -Stream 'out' -Text "early line`n"
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'mask'; id = 1; values = @($value) }))
        Add-WorkloadMcpWorkerLog -State $state -Stream 'out' -Text 'x S3cr3t-'
        Add-WorkloadMcpWorkerLog -State $state -Stream 'out' -Text "log-1 y`n"
        Add-WorkloadMcpWorkerLog -State $state -Stream 'out' -EndOfStream
        $log = [IO.File]::ReadAllText((Join-Path $state.Worker.Folder 'worker.out.log'))
        Assert-False ($log.Contains($value)) "the value is in the log: $log"
        Assert-StringEqual "early line`nx *** y`n" $log 'the log text'
        Assert-Equal 1 @((Get-WorkloadTestSentFrame -Stub $stub) | Where-Object { [string]$_['type'] -ceq 'mask.ack' }).Count 'mask.ack frames'
    }

    It 'treats a malformed frame, a wrong hello and a failed write as a lost worker' {
        $noHello = New-StubWorkloadWorker -NoHello
        $script:PreparedStubs.Enqueue($noHello)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_phrases'
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'hello'; protocol = 2; sessionId = $noHello.SessionId; pid = 1; surfaces = @('screen') }))
        Assert-Equal 1 $noHello.KillCount 'Kill after a wrong hello'
        Assert-StringEqual 'workload_worker_start_failed' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'a wrong hello'

        $holding = New-StubWorkloadWorker -OnRequest { param($Frame) $null = $Frame; $null }
        $script:PreparedStubs.Enqueue($holding)
        $malformed = New-WorkloadTestState
        Send-WorkloadTestCall -State $malformed -Id 1 -Tool 'workload_phrases'
        Invoke-WorkloadMcpWorkerFrame -State $malformed -Line 'not json'
        Assert-Equal 1 $holding.KillCount 'Kill after a malformed frame'
        Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $malformed -Id 1)['error']['code'] 'a malformed frame'

        $failing = New-StubWorkloadWorker -FailWrite
        $script:PreparedStubs.Enqueue($failing)
        $written = New-WorkloadTestState
        $null = Invoke-WorkloadMcpExchange -State $written -Line @((Get-WorkloadTestCallLine -Id 1 -Tool 'workload_phrases'))
        Assert-Equal 1 $failing.KillCount 'Kill after a failed write'
        Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $written -Id 1)['error']['code'] 'a failed write'
    }

    It 'prunes session folders beyond twenty and spares a live session' {
        $state = New-WorkloadTestState
        $self = Get-Process -Id $PID
        for ($i = 0; $i -lt 25; $i++) {
            $folder = Join-Path $state.SessionRoot ('20200101T0000{0:d2}Z-{1:x8}' -f $i, $i)
            $null = New-Item -ItemType Directory -Path $folder
            if ($i -eq 0) {
                $document = [ordered]@{ sessionId = 'live'; frontEnd = [ordered]@{ pid = $PID; startTicks = $self.StartTime.ToUniversalTime().Ticks }; state = 'active' }
                [IO.File]::WriteAllText((Join-Path $folder 'session.json'), (ConvertTo-Json -InputObject $document -Depth 4))
            }
        }
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_phrases'
        $names = @(Get-ChildItem -LiteralPath $state.SessionRoot -Directory | ForEach-Object { $_.Name })
        Assert-Equal 21 $names.Count "folders left: $($names -join ', ')"
        Assert-True ($names -ccontains ('20200101T000000Z-{0:x8}' -f 0)) 'the live session was pruned'
        for ($i = 1; $i -le 5; $i++) { Assert-False ($names -ccontains ('20200101T0000{0:d2}Z-{1:x8}' -f $i, $i)) "old folder $i was kept" }
        for ($i = 6; $i -lt 25; $i++) { Assert-True ($names -ccontains ('20200101T0000{0:d2}Z-{1:x8}' -f $i, $i)) "new folder $i was pruned" }
        Assert-True ($names -ccontains $state.Worker.SessionId) 'the new folder is missing'
    }

    It 'refuses a request whose arguments would not fit one frame' {
        $state = New-WorkloadTestState
        $text = [string]::new([char]0x2028, 200000)
        $line = '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"workload_action","arguments":{"operationId":"op-1","action":"inputText","fields":{"text":"' +
            $text + '"},"intent":"i"}}}'
        Assert-True ($line.Length -le (Get-WorkloadProtocolLimit).MaxRequestLineChars) 'the client line is over its limit'
        Invoke-WorkloadMcpClientLine -State $state -Line $line
        $answers = Get-WorkloadTestAnswer -State $state -Id 7
        Assert-Equal 1 $answers.Count 'one answer'
        Assert-Equal -32600 $answers[0]['error']['code'] 'the frame limit'
        Assert-Equal 0 $script:Stubs.Count 'a worker was opened'
        Assert-Null $state.Worker 'the state holds a worker'
    }

    It 'settles what waited for a worker that never said hello and hands none of it to the next' {
        $first = New-StubWorkloadWorker -NoHello
        $script:PreparedStubs.Enqueue($first)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'hello'; protocol = 2; sessionId = $first.SessionId; pid = 1; surfaces = @('screen') }))
        Assert-StringEqual 'workload_worker_start_failed' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'the start'
        $operation = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'canceled' $operation['state'] 'the queued operation'
        Assert-StringEqual 'workload_not_dispatched' $operation['error']['code'] 'the code of the queued operation'
        Assert-True ($operation['dispatched'] -eq $false) 'the queued operation was dispatched'
        Assert-Equal 0 $state.Queue.Count 'the queue'
        Assert-Null $state.InFlight 'the request in flight'
        $result = Open-WorkloadTestSession -State $state -Id 3 -VmName 'vm-b'
        Assert-True ($result['ok'] -eq $true) 'the second start failed'
        $second = (Get-WorkloadTestSentFrame -Stub $script:Stubs[1])
        Assert-Equal 1 @($second | Where-Object { [string]$_['type'] -ceq 'request' }).Count 'requests to the second worker'
        Assert-StringEqual 'session.start' $second[0]['method'] 'the request to the second worker'
        Assert-StringEqual 'vm-b' $second[0]['params']['vmName'] 'the VM of the second start'
    }

    It 'leaves no queued request behind when a worker is lost' {
        $first = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($first)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_phrases'
        Invoke-WorkloadMcpWorkerFrame -State $state -Line 'not json'
        foreach ($id in 2, 3) { Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $state -Id $id)['error']['code'] "call $id" }
        Assert-Equal 0 $state.Queue.Count 'the queue'
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_phrases'
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal 2 $script:Stubs.Count 'workers opened'
        Assert-Equal 1 $script:Stubs[1].Sent.Count 'lines sent to the second worker'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[1] -Method 'phrases.list').Count 'phrases.list requests'
    }
}

Describe 'the end of a workload session' {
    BeforeEach { Initialize-WorkloadTestFixture }

    It 'sends an ending worker nothing but the end request' {
        $stub = New-StubWorkloadWorker -NeverExits -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.end') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_phrases'
        Assert-StringEqual 'workload_no_session' (Get-WorkloadTestResult -State $state -Id 3)['error']['code'] 'phrases while the session ends'
        $frames = (Get-WorkloadTestSentFrame -Stub $stub)
        Assert-StringEqual 'session.end' $frames[-1]['method'] 'the last frame'
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $stub -Method 'phrases.list').Count 'phrases.list requests'
        Assert-Equal 0 $state.Queue.Count 'the queue'
    }

    It 'drops a queued start when the session ends before hello' {
        $stub = New-StubWorkloadWorker -NoHello
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        Assert-StringEqual 'workload_no_session' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'the start'
        $frames = (Get-WorkloadTestSentFrame -Stub $stub)
        Assert-Equal 1 $frames.Count 'lines sent'
        Assert-StringEqual 'session.end' $frames[0]['method'] 'the line sent'
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'hello'; protocol = 1; sessionId = $stub.SessionId; pid = 1; surfaces = @('screen') }))
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $stub -Method 'session.start').Count 'session.start requests after hello'
    }

    It 'leaves an attached session alone when the limits of its start and of an earlier end pass' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state -Id 1
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        Invoke-WorkloadTestWorkerLine -State $state
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        $second = Open-WorkloadTestSession -State $state -Id 3
        Assert-True ($second['ok'] -eq $true) 'the second start failed'
        $script:Now += 600000
        Assert-False (Invoke-WorkloadMcpTimer -State $state) 'the timer acted'
        Assert-StringEqual 'active' $state.Session.Phase 'the phase'
        Assert-Equal 0 $script:Stubs[1].KillCount 'Kill of the second worker'
        Assert-Equal 0 $script:Stubs[1].CloseInputCount 'CloseInput of the second worker'
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[1] -Method 'snapshot.take').Count 'snapshot.take requests'
    }

    It 'answers the end of a session once, with what the worker released' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        $before = $state.Writer.ToString().Length
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal $before $state.Writer.ToString().Length 'the end reply wrote a line'
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        $answers = Get-WorkloadTestAnswer -State $state -Id 2
        Assert-Equal 1 $answers.Count 'answers of the end call'
        Assert-True ($answers[0]['result']['isError'] -eq $false) 'the end is an error'
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-True ($result['ended'] -eq $true) 'ended'
        Assert-True ($result['forced'] -eq $false) 'forced'
        Assert-True ($result['released'] -eq $true) 'released'
        Assert-StringEqual '' $result['cycleFolder'] 'cycleFolder'
        Assert-StringEqual 'ended' $state.Session.Phase 'the phase'
    }

    It 'answers an end call with the end result when the worker never says hello' {
        $stub = New-StubWorkloadWorker -NoHello
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'hello'; protocol = 2; sessionId = $stub.SessionId; pid = 1; surfaces = @('screen') }))
        $answers = Get-WorkloadTestAnswer -State $state -Id 2
        Assert-Equal 1 $answers.Count 'answers of the end call'
        $text = [string]$answers[0]['result']['content'][0]['text']
        Assert-False ($text.Contains('workload_worker_start_failed') -or $text.Contains('workload_no_session')) "the end call was refused: $text"
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-True ($result['ended'] -eq $true) 'ended'
        Assert-True ($result['forced'] -eq $false) 'forced'
        Assert-True ($result['released'] -eq $false) 'released'
    }

    It 'reports the operation that a session end stopped' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'step.run') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'step.run')[0]
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_session_end'
        $frames = (Get-WorkloadTestSentFrame -Stub $stub)
        Assert-StringEqual 'cancel' $frames[-2]['type'] 'the frame before the end request'
        Assert-StringEqual $request['id'] $frames[-2]['id'] 'the id of the cancel'
        Assert-StringEqual 'session.end' $frames[-1]['method'] 'the last frame'
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; cancel = $true })
        Assert-Equal 1 @((Get-WorkloadTestSentFrame -Stub $stub) | Where-Object { [string]$_['type'] -ceq 'cancel' }).Count 'cancel frames'
        $script:Now = [long]$state.Calls[-1].Deadline
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-StringEqual 'canceling' (Get-WorkloadTestResult -State $state -Id 4)['state'] 'the poll at its deadline'
        & $stub.Reply $request['id'] @{ ok = $false; state = 'canceled' }
        Invoke-WorkloadTestWorkerLine -State $state
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        $result = Get-WorkloadTestResult -State $state -Id 3
        Assert-StringEqual 'op-1' $result['operation']['id'] 'the operation id'
        Assert-StringEqual 'canceled' $result['operation']['state'] 'the operation state'
    }

    It 'sends nothing for a call that timed out in the queue' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_save_sequence' -Arguments ([ordered]@{ name = 'workload.x'; description = 'd'; resource = @('a') })
        $script:Now += $state.MaxCallMs + 1
        $rounds = 0
        while ((Invoke-WorkloadMcpTimer -State $state) -and $rounds -lt 10) { $rounds++ }
        foreach ($id in 2, 3) { Assert-StringEqual 'workload_call_timeout' (Get-WorkloadTestResult -State $state -Id $id)['error']['code'] "call $id" }
        Assert-Equal 0 $state.Queue.Count 'the queue'
        $before = $state.Writer.ToString().Length
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take')[0]
        & $stub.Reply $request['id'] @{ ok = $true; surface = 'screen'; text = '' }
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal $before $state.Writer.ToString().Length 'a line was written'
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $stub -Method 'sequence.save').Count 'sequence.save requests'
    }

    It 'keeps serving after a frame that ended the worker' {
        $stub = New-StubWorkloadWorker
        & $stub.Push 'not json'
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Invoke-WorkloadMcpExchange -State $state -Line @((Get-WorkloadTestCallLine -Id 1 -Tool 'workload_phrases'), '{"jsonrpc":"2.0","id":2,"method":"ping"}')
        Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'the phrases call'
        Assert-Equal 1 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'the ping'
        Assert-True ($stub.KillCount -ge 1) 'Kill was not recorded'
        Assert-True ($stub.DisposeCount -ge 1) 'Dispose was not recorded'
    }

    It 'does not start the end again when the client''s input ends during it' {
        $stub = New-StubWorkloadWorker -NeverExits -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.end') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_end'
        $deadline = $state.Session.EndDeadline
        $script:Now += 5000
        $null = Close-WorkloadMcpSession -State $state -Reason 'client-ended'
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $stub -Method 'session.end').Count 'session.end requests'
        Assert-Equal $deadline $state.Session.EndDeadline 'the end deadline'
    }

    It 'sends the start to the worker that workload_phrases opened' {
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_phrases'
        Invoke-WorkloadTestWorkerLine -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'session.start').Count 'session.start before any other event'
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-True ((Get-WorkloadTestResult -State $state -Id 2)['ok'] -eq $true) 'the start failed'
        Assert-Equal 1 $script:Stubs.Count 'the factory runs'
    }

    It 'sends nothing to a worker whose exit was seen' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $state.Worker.ExitSeen = $script:Now
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        Assert-Equal 0 (Get-WorkloadTestSentFrame -Stub $script:Stubs[0] -Method 'step.run').Count 'step.run requests'
        Invoke-WorkloadMcpWorkerExit -State $state -Reason 'exited'
        $result = Get-WorkloadTestResult -State $state -Id 2
        Assert-StringEqual 'canceled' $result['state'] 'the state'
        Assert-StringEqual 'workload_not_dispatched' $result['error']['code'] 'the code'
        Assert-StringEqual 'none-proven' $result['effect'] 'the effect'
    }

    It 'leaves nothing in flight when a request could not be sent' {
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        $stub = $script:Stubs[0]
        $send = $stub.Send
        $stub.Send = { param($Line) throw "no send: $Line" }
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1'; step = 'click Next'; intent = 'i' })
        $answers = Get-WorkloadTestAnswer -State $state -Id 2
        Assert-Equal 1 $answers.Count 'answers of the run form'
        Assert-Equal -32603 $answers[0]['error']['code'] 'the internal error'
        Assert-Null $state.InFlight 'the request in flight'
        Assert-Equal 0 $state.Queue.Count 'the queue'
        Send-WorkloadTestCall -State $state -Id 3 -Tool 'workload_step' -Arguments ([ordered]@{ operationId = 'op-1' })
        Assert-StringEqual 'workload_operation_unknown' (Get-WorkloadTestResult -State $state -Id 3)['error']['code'] 'the poll'
        $stub.Send = $send
        Send-WorkloadTestCall -State $state -Id 4 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Assert-Equal 1 (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take').Count 'snapshot.take requests'
    }

    It 'drops progress that names no operation in flight and loses a worker that replies without a result object' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'snapshot.take') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        $null = Open-WorkloadTestSession -State $state
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'snapshot.take')[0]
        $before = $state.Writer.ToString().Length
        foreach ($progressId in @($request['id'], 'r99')) {
            Invoke-WorkloadMcpWorkerFrame -State $state -Line (ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'progress'; id = $progressId; completed = 0; total = 1; label = 'x' }))
        }
        Assert-Equal $before $state.Writer.ToString().Length 'a progress frame wrote a line'
        Assert-Equal 0 $stub.KillCount 'Kill after a dropped progress'
        Invoke-WorkloadMcpWorkerFrame -State $state -Line ('{"type":"reply","id":"' + $request['id'] + '","result":5}')
        Assert-Equal 1 $stub.KillCount 'Kill after a reply without a result object'
        Assert-StringEqual 'workload_worker_lost' (Get-WorkloadTestResult -State $state -Id 2)['error']['code'] 'the snapshot call'
    }

    It 'answers a call once: a refusal and a starting answer leave no record' {
        $stub = New-StubWorkloadWorker -OnRequest { param($Frame) if ([string]$Frame['method'] -ceq 'session.start') { return $null }; Get-StubDefaultAnswer -Frame $Frame }
        $script:PreparedStubs.Enqueue($stub)
        $state = New-WorkloadTestState
        Send-WorkloadTestCall -State $state -Id 1 -Tool 'workload_snapshot' -Arguments ([ordered]@{ surface = 'screen' })
        Assert-StringEqual 'workload_no_session' (Get-WorkloadTestResult -State $state -Id 1)['error']['code'] 'the refusal'
        Assert-Equal 0 $state.Calls.Count 'calls after the refusal'
        $before = $state.Writer.ToString().Length
        $script:Now += $state.MaxCallMs + 1
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal $before $state.Writer.ToString().Length 'the timer answered the refused call'
        Send-WorkloadTestCall -State $state -Id 2 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })
        $script:Now = [long]$state.Calls[0].Deadline
        $null = Invoke-WorkloadMcpTimer -State $state
        Assert-Equal 1 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'answers of the start at its deadline'
        Assert-StringEqual 'starting' (Get-WorkloadTestResult -State $state -Id 2)['state'] 'the starting answer'
        $request = (Get-WorkloadTestSentFrame -Stub $stub -Method 'session.start')[0]
        & $stub.Reply $request['id'] (Get-StubDefaultAnswer -Frame $request)
        Invoke-WorkloadTestWorkerLine -State $state
        Assert-Equal 1 (Get-WorkloadTestAnswer -State $state -Id 2).Count 'answers of the start after the reply'
        Assert-Equal 0 $state.Calls.Count 'calls after the reply'
    }

    It 'runs a session from start to end in one exchange without a kill' {
        $state = New-WorkloadTestState
        $null = Invoke-WorkloadMcpExchange -State $state -Line @(
            (Get-WorkloadTestCallLine -Id 1 -Tool 'workload_session_start' -Arguments ([ordered]@{ guestKey = 'guest.stub'; vmName = 'vm-a' })),
            (Get-WorkloadTestCallLine -Id 2 -Tool 'workload_session_end'))
        Assert-True ((Get-WorkloadTestResult -State $state -Id 1)['ok'] -eq $true) 'the start'
        $end = Get-WorkloadTestResult -State $state -Id 2
        Assert-True ($end['ended'] -eq $true) 'ended'
        Assert-True ($end['forced'] -eq $false) 'forced'
        Assert-True ($end['released'] -eq $true) 'released'
        Assert-Equal 0 $script:Stubs[0].KillCount 'Kill'
        Assert-True ($script:Stubs[0].DisposeCount -ge 1) 'Dispose was not recorded'
        Assert-True ($state.Finished -eq $true) 'Finished'
    }
}
