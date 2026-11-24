<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4268b6f2-a206-40de-9e3a-3d9e2964a4d6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna mcp stdio workload authoring
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
    Serve the workload authoring tools over MCP on stdio.
.DESCRIPTION
    Two processes serve one client. This front end reads the client's lines,
    answers every call within the response budget, keeps the operations by
    their operationId and never loads the sequence engine. A worker process
    (Invoke-WorkloadSession.ps1) holds the session, loads the engine and runs
    the steps; the two talk over a pair of anonymous pipes, one JSON frame per
    line.

    The loop never blocks on one source: client lines, worker frames, the
    worker's stdout and stderr, its exit and the deadlines are all waited on
    together, so a ping or a poll is answered while a step runs. A step that
    outlives the budget is answered workload_still_waiting and keeps running;
    a poll with the same operationId returns its result later, and the same id
    with the same input never runs twice.

    Like the core server, this one has no network endpoint and takes no secret
    of its own: the process that reads the operator's stdin was started by
    that operator.
.PARAMETER RepoRoot
    Repository root. Defaults to the enlistment this script lives in.
.PARAMETER MaxCallSeconds
    The response budget of one call, 30 to 600 seconds. The default stays
    below the 60 seconds after which common MCP clients give up on a request.
.PARAMETER SessionRoot
    The folder that holds one folder per worker. Defaults to workload-mcp under
    the log directory.
.PARAMETER ConfigPath
    Test configuration file handed to the worker.
.PARAMETER WorkerScript
    The worker script; a suite points it at a stand-in.
.EXAMPLE
    pwsh -NoProfile -File test/service/Start-WorkloadMcpServer.ps1

    Serves MCP on stdio; point a client at that command.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot,
    [ValidateRange(30, 600)][int]$MaxCallSeconds = 50,
    [string]$SessionRoot,
    [string]$ConfigPath,
    [Parameter(DontShow)][string]$WorkerScript
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking 3>$null 4>$null 5>$null 6>$null
Import-Module (Join-Path $PSScriptRoot '../modules/Test.YurunaDir.psm1') -DisableNameChecking 3>$null 4>$null 5>$null 6>$null
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LocalizationExchange.psm1') -DisableNameChecking 3>$null 4>$null 5>$null 6>$null
Import-Module (Join-Path $PSScriptRoot '../modules/Test.WorkloadProtocol.psm1') -DisableNameChecking 3>$null 4>$null 5>$null 6>$null

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
if (-not $WorkerScript) { $WorkerScript = Join-Path $PSScriptRoot 'Invoke-WorkloadSession.ps1' }
$script:RepoRoot = $RepoRoot
# The script parameters the loop reads when it builds its own state. The
# session root stays empty here: dot-sourcing the script creates no folder.
$script:WorkloadMcpParameter = @{
    MaxCallSeconds = $MaxCallSeconds
    SessionRoot    = $SessionRoot
    ConfigPath     = $ConfigPath
    WorkerScript   = $WorkerScript
    RepoRoot       = $RepoRoot
}

# Timeouts in seconds; a suite may lower them after dot-sourcing the script.
$script:WorkerHelloTimeoutSeconds = 30
$script:WorkerWriteTimeoutSeconds = 10
$script:SessionStartTimeoutSeconds = 180
$script:ShutdownGraceSeconds = 20
$script:KillConfirmSeconds = 5
$script:DrainSeconds = 2
$script:SupportedProtocolVersion = @('2025-06-18')

# --- REGION: https://yuruna.link/42fffc2c-001f
function Get-WorkloadMcpServerVersion {
    <#
    .SYNOPSIS
        The version this server reports, read from the enlistment's VERSION file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Join-Path $script:RepoRoot 'VERSION'
    if (Test-Path -LiteralPath $path) {
        $value = (Get-Content -LiteralPath $path -TotalCount 1) -replace '\s', ''
        if ($value) { return $value }
    }
    return 'dev'
}

function ConvertTo-WorkloadMcpSchemaText {
    <#
    .SYNOPSIS
        A closed object schema as JSON text, from property schemas given as JSON text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Specialized.OrderedDictionary]$Property,
        [AllowEmptyCollection()][string[]]$Required = @()
    )
    $properties = @(foreach ($name in $Property.Keys) { '"' + $name + '":' + $Property[$name] }) -join ','
    $names = @(foreach ($name in $Required) { '"' + $name + '"' }) -join ','
    return '{"type":"object","properties":{' + $properties + '},"required":[' + $names + '],"additionalProperties":false}'
}

function Get-WorkloadMcpToolTable {
    <#
    .SYNOPSIS
        The eleven tools of the workload server with their hints, routes, worker methods and input schemas.
    .DESCRIPTION
        The three operation tools are idempotent because the same operationId
        and input never run twice. Route says how the front end serves a call:
        operation (a step, an action or a replay, kept by its operationId),
        file (read from the session folder, never touching the worker), worker
        (served without a session), session (needs an attached session), start
        and end.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $guest = '{"type":"string","maxLength":64,"pattern":"^guest\\.[a-z0-9]+(?:[.-][a-z0-9]+)*$"}'
    $vm = '{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"}'
    $sequence = '{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}(?:\\.ya?ml)?$"}'
    $operationId = '{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"}'
    $surface = '{"type":"string","enum":["screen","page"]}'
    $intent = '{"type":"string","minLength":1,"maxLength":200}'
    $cancel = '{"type":"boolean"}'
    $variables = '{"type":"object","maxProperties":64,"propertyNames":{"pattern":"^[A-Za-z_][A-Za-z0-9_]{0,63}$"},"additionalProperties":{"type":["string","number","boolean"],"maxLength":4096}}'
    $none = ConvertTo-WorkloadMcpSchemaText -Property ([ordered]@{})
    return @(
        @{ Name = 'workload_action'; ReadOnly = $false; Destructive = $true; Idempotent = $true; Route = 'operation'; Method = 'action.run'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('operationId') -Property ([ordered]@{
                        operationId = $operationId; action = '{"type":"string","pattern":"^[A-Za-z][A-Za-z0-9]{0,63}$"}'
                        fields = '{"type":"object","maxProperties":64}'; intent = $intent; cancel = $cancel }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_action') }
        @{ Name = 'workload_failure'; ReadOnly = $true; Destructive = $false; Idempotent = $false; Route = 'file'; Method = $null
            Schema = $none; Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_failure') }
        @{ Name = 'workload_journal'; ReadOnly = $true; Destructive = $false; Idempotent = $false; Route = 'file'; Method = $null
            Schema = $none; Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_journal') }
        @{ Name = 'workload_phrases'; ReadOnly = $true; Destructive = $false; Idempotent = $false; Route = 'worker'; Method = 'phrases.list'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Property ([ordered]@{ search = '{"type":"string","minLength":1,"maxLength":200}' }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_phrases') }
        @{ Name = 'workload_run_sequence'; ReadOnly = $false; Destructive = $true; Idempotent = $true; Route = 'operation'; Method = 'sequence.run'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('operationId') -Property ([ordered]@{
                        operationId = $operationId; sequence = $sequence
                        timeoutSeconds = '{"type":"integer","minimum":60,"maximum":43200}'; cancel = $cancel }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_run_sequence') }
        @{ Name = 'workload_save_sequence'; ReadOnly = $false; Destructive = $false; Idempotent = $false; Route = 'session'; Method = 'sequence.save'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('name', 'description', 'resource') -Property ([ordered]@{
                        name = '{"type":"string","maxLength":100,"pattern":"^workload\\.[a-z0-9]+(?:[.-][a-z0-9]+)*$"}'
                        description = '{"type":"string","minLength":1,"maxLength":200}'
                        resource = '{"type":"array","minItems":1,"maxItems":16,"items":{"type":"string","pattern":"^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$"}}'
                        componentSteps = '{"type":"integer","minimum":0,"maximum":10000}' }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_save_sequence') }
        @{ Name = 'workload_session_end'; ReadOnly = $false; Destructive = $false; Idempotent = $true; Route = 'end'; Method = 'session.end'
            Schema = $none; Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_session_end') }
        @{ Name = 'workload_session_start'; ReadOnly = $false; Destructive = $false; Idempotent = $false; Route = 'start'; Method = 'session.start'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('guestKey', 'vmName') -Property ([ordered]@{
                        guestKey = $guest; vmName = $vm; sequence = $sequence; variables = $variables }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_session_start') }
        @{ Name = 'workload_snapshot'; ReadOnly = $true; Destructive = $false; Idempotent = $false; Route = 'session'; Method = 'snapshot.take'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('surface') -Property ([ordered]@{
                        surface = $surface; find = '{"type":"string","minLength":1,"maxLength":200}'; image = '{"type":"boolean"}' }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_snapshot') }
        @{ Name = 'workload_step'; ReadOnly = $false; Destructive = $true; Idempotent = $true; Route = 'operation'; Method = 'step.run'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('operationId') -Property ([ordered]@{
                        operationId = $operationId; step = '{"type":"string","minLength":1,"maxLength":2000}'; on = $surface
                        intent = $intent; timeoutSeconds = '{"type":"integer","minimum":1,"maximum":7200}'; cancel = $cancel }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_step') }
        @{ Name = 'workload_suggest_step'; ReadOnly = $true; Destructive = $false; Idempotent = $false; Route = 'session'; Method = 'suggest'
            Schema = (ConvertTo-WorkloadMcpSchemaText -Required @('ref') -Property ([ordered]@{ ref = '{"type":"string","pattern":"^[sp][1-9][0-9]{0,11}$"}' }))
            Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_suggest_step') }
    )
}

function Get-WorkloadMcpRunField {
    <#
    .SYNOPSIS
        The run fields of an operation tool, and the ones its run form needs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Name)
    switch -CaseSensitive ($Name) {
        'workload_step' { return @{ Run = @('step', 'on', 'intent', 'timeoutSeconds'); Needed = @('step', 'intent') } }
        'workload_action' { return @{ Run = @('action', 'fields', 'intent'); Needed = @('action', 'fields', 'intent') } }
        'workload_run_sequence' { return @{ Run = @('sequence', 'timeoutSeconds'); Needed = @('sequence') } }
    }
    return $null
}

function Test-WorkloadMcpArgument {
    <#
    .SYNOPSIS
        $null for arguments a tool accepts; otherwise one line naming the problem.
    .DESCRIPTION
        The schema first. An operation tool then has two forms: the poll form
        carries no run field, the run form carries the fields that start the
        operation, all of them, and never cancel.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments
    )
    $problem = Get-YurunaJsonSchemaError -Json (ConvertTo-Json -InputObject $Arguments -Compress -Depth 32) -Schema $Tool.Schema
    if ($null -ne $problem) { return [string]$problem }
    if ($Tool.Route -cne 'operation') { return $null }
    $fields = Get-WorkloadMcpRunField -Name $Tool.Name
    $present = @($fields.Run | Where-Object { $Arguments.Contains($_) })
    if ($present.Count -eq 0) { return $null }
    $missing = @($fields.Needed | Where-Object { -not $Arguments.Contains($_) })
    if ($missing.Count -gt 0) {
        return (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_run_form_incomplete' -Arguments @{ fields = ($missing -join ', ') })
    }
    if ($Arguments.Contains('cancel')) {
        return (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_cancel_with_run_fields')
    }
    return $null
}

function Initialize-WorkloadMcpState {
    <#
    .SYNOPSIS
        The one state every handler of the front end takes.
    .DESCRIPTION
        Every limit the state tracks is a tick count read from Clock, and a
        limit has passed when the clock is at or after it. A suite passes a
        scripted clock and a stub worker factory.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.IO.TextWriter]$Writer,
        [int]$MaxCallSeconds = 50,
        [string]$SessionRoot,
        [string]$RepoRoot = $script:RepoRoot,
        [string]$WorkerScript = $script:WorkloadMcpParameter.WorkerScript,
        [string]$ConfigPath,
        [scriptblock]$WorkerFactory = { param($State) Open-WorkloadMcpWorkerProcess -State $State },
        [scriptblock]$ClockTicks = { [Environment]::TickCount64 }
    )
    return @{
        Writer        = $Writer
        Clock         = $ClockTicks
        MaxCallMs     = [long]$MaxCallSeconds * 1000
        WorkerFactory = $WorkerFactory
        WorkerOrdinal = 0
        Worker        = $null
        Session       = @{ Phase = 'none' }
        Queue         = [Collections.Generic.List[object]]::new()
        Calls         = [Collections.Generic.List[object]]::new()
        InFlight      = $null
        Operations    = @{}
        Masks         = [Collections.Generic.List[string]]::new()
        NextRequest   = 0
        ClientEnded   = $false
        Finished      = $false
        SessionRoot   = $SessionRoot
        RepoRoot      = $RepoRoot
        WorkerScript  = $WorkerScript
        ConfigPath    = $ConfigPath
        ClientRead    = $null
        Opening       = $null
    }
}

function Get-WorkloadMcpNow {
    <#
    .SYNOPSIS
        The state's clock, as a tick count in milliseconds.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][hashtable]$State)
    return [long](& $State.Clock)
}

function Test-WorkloadMcpLimitPassed {
    <#
    .SYNOPSIS
        Whether a limit of the state has passed; a $null limit never has.
    .DESCRIPTION
        In PowerShell a number is at or after $null, so the comparison alone
        would call an unset limit passed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()]$Limit
    )
    if ($null -eq $Limit) { return $false }
    return ((Get-WorkloadMcpNow -State $State) -ge [long]$Limit)
}

function Find-WorkloadMcpItemIndex {
    <#
    .SYNOPSIS
        The index of an object in a list, compared by reference; -1 when absent.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$List,
        [AllowNull()]$Item
    )
    if ($null -eq $Item) { return -1 }
    for ($i = 0; $i -lt $List.Count; $i++) {
        if ([object]::ReferenceEquals($List[$i], $Item)) { return $i }
    }
    return -1
}

function Clear-WorkloadMcpListItem {
    <#
    .SYNOPSIS
        Removes an object from a list by reference; returns whether it was there.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$List,
        [AllowNull()]$Item
    )
    $index = Find-WorkloadMcpItemIndex -List $List -Item $Item
    if ($index -lt 0) { return $false }
    $List.RemoveAt($index)
    return $true
}

function Test-WorkloadMcpSameId {
    <#
    .SYNOPSIS
        Whether two JSON-RPC ids are equal in type and value.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Left, [AllowNull()]$Right)
    if (-not (Test-WorkloadMcpIdType -Id $Left) -or -not (Test-WorkloadMcpIdType -Id $Right)) { return $false }
    if ($Left -is [string] -or $Right -is [string]) {
        return ($Left -is [string] -and $Right -is [string] -and $Left -ceq $Right)
    }
    return ([System.Numerics.BigInteger]$Left -eq [System.Numerics.BigInteger]$Right)
}

function Test-WorkloadMcpIdType {
    <#
    .SYNOPSIS
        Whether a JSON-RPC id is a string or an integer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Id)
    return ($Id -is [string] -or $Id -is [int] -or $Id -is [long] -or $Id -is [System.Numerics.BigInteger])
}

function Write-WorkloadMcpMessage {
    <#
    .SYNOPSIS
        Writes one JSON-RPC message as one line; the only writer of the client stream.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Message
    )
    $State.Writer.WriteLine((ConvertTo-Json -InputObject $Message -Compress -Depth 32))
    $State.Writer.Flush()
}

function Write-WorkloadMcpServerLog {
    <#
    .SYNOPSIS
        Appends one event line to server.log of the current worker's folder.
    .DESCRIPTION
        Ids, methods, tools, codes, frame types and lengths only: never an
        argument value or a result text. An event without a worker folder is
        not logged; the log of a folder starts with the worker that owns it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$EventName,
        [System.Collections.IDictionary]$Data = @{}
    )
    $worker = $State.Worker
    if ($null -eq $worker -or -not $worker.Folder) { return }
    $parts = [Collections.Generic.List[string]]::new()
    $parts.Add([DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture))
    $parts.Add($EventName)
    foreach ($key in $Data.Keys) {
        $value = $Data[$key]
        if ($null -eq $value) { continue }
        $parts.Add(('{0}={1}' -f $key, ([string]$value -replace '\s', '_')))
    }
    try {
        [IO.File]::AppendAllText((Join-Path $worker.Folder 'server.log'), (($parts -join ' ') + "`n"), [Text.UTF8Encoding]::new($false))
    } catch {
        Write-Verbose "server.log was not written: $($_.Exception.Message)"
    }
}

function Write-WorkloadMcpResponse {
    <#
    .SYNOPSIS
        Writes a JSON-RPC result or error; an error without -HasId carries no id.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()]$Id,
        [switch]$HasId,
        [AllowNull()]$Result,
        [int]$ErrorCode,
        [string]$ErrorMessage
    )
    $message = [ordered]@{ jsonrpc = '2.0' }
    if ($HasId) { $message['id'] = $Id }
    if ($ErrorCode -ne 0) {
        $message['error'] = [ordered]@{ code = $ErrorCode; message = $ErrorMessage }
        Write-WorkloadMcpServerLog -State $State -EventName 'answer' -Data ([ordered]@{ id = $(if ($HasId) { $Id } else { $null }); rpcError = $ErrorCode })
    } else {
        $message['result'] = $Result
    }
    Write-WorkloadMcpMessage -State $State -Message $message
}

function Get-WorkloadMcpErrorResult {
    <#
    .SYNOPSIS
        A refusal of the front end: ok false with a stable code and its rendered message.
    .DESCRIPTION
        Every call site passes the code and the catalog key as quoted literals,
        so the code registry and the slice map find both.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{}
    )
    return [ordered]@{
        ok    = $false
        error = [ordered]@{ code = $Code; message = (Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments) }
    }
}

function ConvertTo-WorkloadMcpToolContent {
    <#
    .SYNOPSIS
        The content items of a tool result.
    .DESCRIPTION
        One text item with the result as JSON, or the text of a session file as
        it was read. A snapshot that succeeded gives two or three items: the
        result without its text, plus the member image (returned, too_large,
        withheld or none); the snapshot text; and the frame as an image/png
        item only when image is returned. The image is decided from the
        worker's reply alone: once the worker withholds the path, no file is
        read.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [AllowNull()][object]$RawText = $null
    )
    if ($null -ne $RawText) { return , @([ordered]@{ type = 'text'; text = $RawText }) }
    if ($ToolName -cne 'workload_snapshot' -or $Result['ok'] -ne $true) {
        return , @([ordered]@{ type = 'text'; text = (ConvertTo-Json -InputObject $Result -Compress -Depth 32) })
    }
    $first = [ordered]@{}
    foreach ($key in $Result.Keys) { if ($key -cne 'text') { $first[$key] = $Result[$key] } }
    $bytes = $null
    $image = 'none'
    if ($Result.Contains('imageWithheld')) {
        $image = 'withheld'
    } elseif ($Result.Contains('imagePath')) {
        $image = 'too_large'
        try {
            $file = [IO.FileInfo]::new([string]$Result['imagePath'])
            if ($file.Exists -and $file.Length -le (Get-WorkloadProtocolLimit).MaxImageBytes) {
                $bytes = [IO.File]::ReadAllBytes($file.FullName)
                $image = 'returned'
            }
        } catch {
            Write-Verbose "The frame file was not read: $($_.Exception.Message)"
            $image = 'too_large'
        }
    }
    $first['image'] = $image
    $items = [Collections.Generic.List[object]]::new()
    $items.Add([ordered]@{ type = 'text'; text = (ConvertTo-Json -InputObject $first -Compress -Depth 32) })
    $items.Add([ordered]@{ type = 'text'; text = [string]$Result['text'] })
    if ($image -ceq 'returned') {
        $items.Add([ordered]@{ type = 'image'; data = [Convert]::ToBase64String($bytes); mimeType = 'image/png' })
    }
    return , $items.ToArray()
}

function Send-WorkloadMcpToolResult {
    <#
    .SYNOPSIS
        Answers a call once and removes its record; returns whether it answered.
    .DESCRIPTION
        A call that is no longer in State.Calls was answered already, or the
        client dropped it, and gets nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [AllowNull()][object]$RawText = $null
    )
    if (-not (Clear-WorkloadMcpListItem -List $State.Calls -Item $Call)) { return $false }
    $content = ConvertTo-WorkloadMcpToolContent -ToolName $Call.Tool -Result $Result -RawText $RawText
    $code = $null
    if ($Result['error'] -is [System.Collections.IDictionary]) { $code = $Result['error']['code'] }
    elseif ($Result.Contains('noteCode')) { $code = $Result['noteCode'] }
    Write-WorkloadMcpServerLog -State $State -EventName 'answer' -Data ([ordered]@{ id = $Call.RpcId; tool = $Call.Tool; code = $code })
    Write-WorkloadMcpResponse -State $State -Id $Call.RpcId -HasId -Result ([ordered]@{ content = $content; isError = ($Result['ok'] -eq $false) })
    return $true
}

function Get-WorkloadMcpBusyOperation {
    <#
    .SYNOPSIS
        The operation that is running or canceling, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$State)
    foreach ($record in $State.Operations.Values) {
        if ([string]$record.State -cin @('running', 'canceling')) { return $record }
    }
    return $null
}

function Get-WorkloadMcpSurfaceRefusal {
    <#
    .SYNOPSIS
        The workload_surface_unsupported refusal for a surface the worker's hello did not list, else $null.
    .DESCRIPTION
        The front end knows no surface name: it compares with the list the
        worker sent, so a worker that offers another surface needs no change
        here.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][string]$Surface
    )
    if ([string]::IsNullOrEmpty($Surface)) { return $null }
    $worker = $State.Worker
    if ($null -eq $worker -or $null -eq $worker.Hello) { return $null }
    $offered = @($worker.Hello['surfaces'] | ForEach-Object { [string]$_ })
    if ($offered -ccontains $Surface) { return $null }
    return (Get-WorkloadMcpErrorResult -Code 'workload_surface_unsupported' -Key 'runner.workload_surface_unsupported' `
            -Arguments @{ surface = $Surface; surfaces = ($offered -join ', ') })
}

function Complete-WorkloadMcpOperation {
    <#
    .SYNOPSIS
        Stores the terminal result of an operation and answers every call bound to it.
    .DESCRIPTION
        The front end sets operationId and state in the result and changes
        nothing else in it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Record,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][string]$FinalState
    )
    $Result['operationId'] = $Record.Id
    $Result['state'] = $FinalState
    $Record.Result = $Result
    $Record.State = $FinalState
    Write-WorkloadMcpServerLog -State $State -EventName 'operation' -Data ([ordered]@{ operationId = $Record.Id; state = $FinalState })
    foreach ($call in @($State.Calls.ToArray())) {
        if ($call.Route -ceq 'operation' -and [string]$call.OperationId -ceq $Record.Id) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result $Result
        }
    }
}

function Complete-WorkloadMcpUndispatched {
    <#
    .SYNOPSIS
        Finishes an operation the worker never received: canceled, nothing ran.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Record
    )
    $result = Get-WorkloadMcpErrorResult -Code 'workload_not_dispatched' -Key 'runner.workload_not_dispatched' -Arguments @{ operationId = $Record.Id }
    $result['effect'] = 'none-proven'
    $result['dispatched'] = $false
    Complete-WorkloadMcpOperation -State $State -Record $Record -Result $result -FinalState 'canceled'
}

function Send-WorkloadMcpFrame {
    <#
    .SYNOPSIS
        Queues one frame for the worker; the loop's Pump writes it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Frame
    )
    $line = ConvertTo-WorkloadFrameLine -Frame $Frame
    $null = & $State.Worker.Send $line
    Write-WorkloadMcpServerLog -State $State -EventName 'frame-out' -Data ([ordered]@{ type = $Frame['type']; id = $Frame['id']; length = $line.Length })
}

function Send-WorkloadMcpNextCall {
    <#
    .SYNOPSIS
        Sends the next queued request to the worker while nothing is in flight.
    .DESCRIPTION
        Nothing is taken while the worker has not said hello, closes, has
        exited, or the session ends: such an entry waits for the exit handling,
        which answers it, so an operation the worker never received is never
        reported uncertain. The phase and the surface are checked again when an
        entry is taken, because both can change while it waits.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$State)
    while ($null -eq $State.InFlight -and $State.Queue.Count -gt 0) {
        $worker = $State.Worker
        if ($null -eq $worker -or $null -eq $worker.Hello -or $worker.Closing -or $null -ne $worker.ExitSeen) { return }
        if ($State.Session.Phase -ceq 'ending') { return }
        $entry = $State.Queue[0]
        $State.Queue.RemoveAt(0)
        $record = $null
        if ($entry.Route -ceq 'operation') { $record = $State.Operations[$entry.OperationId] }
        if ($entry.Route -ceq 'start') {
            if ($State.Session.Phase -cne 'starting') { continue }
        } elseif ($entry.Route -cin @('session', 'operation') -and $State.Session.Phase -cne 'active') {
            if ($null -ne $record) { Complete-WorkloadMcpUndispatched -State $State -Record $record }
            else {
                $null = Send-WorkloadMcpToolResult -State $State -Call $entry.Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
            }
            continue
        }
        $refusal = Get-WorkloadMcpSurfaceRefusal -State $State -Surface $entry.Surface
        if ($null -ne $refusal) {
            if ($null -ne $record) {
                $refusal['effect'] = 'none-proven'
                $refusal['dispatched'] = $false
                Complete-WorkloadMcpOperation -State $State -Record $record -Result $refusal -FinalState 'failed'
            } else {
                $null = Send-WorkloadMcpToolResult -State $State -Call $entry.Call -Result $refusal
            }
            continue
        }
        $State.NextRequest = $State.NextRequest + 1
        $id = 'r' + $State.NextRequest
        $line = ConvertTo-WorkloadFrameLine -Frame ([ordered]@{ type = 'request'; id = $id; method = $entry.Method; params = $entry.Params })
        $null = & $worker.Send $line
        $State.InFlight = @{ Id = $id; Entry = $entry; Abandoned = $false }
        if ($null -ne $record) {
            $record.RequestId = $id
            $record.Dispatched = $true
        }
        Write-WorkloadMcpServerLog -State $State -EventName 'frame-out' -Data ([ordered]@{ type = 'request'; id = $id; method = $entry.Method; length = $line.Length })
    }
}

function Clear-WorkloadMcpQueue {
    <#
    .SYNOPSIS
        Empties the queue: operations end not dispatched, a start entry is dropped, every other call is answered.
    .DESCRIPTION
        A start entry names no call: its calls are answered where the phase
        changed. The other calls get workload_no_session when a session ends
        and workload_worker_lost when a worker without a session closes.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [switch]$SessionEnding
    )
    $entries = @($State.Queue.ToArray())
    $State.Queue.Clear()
    foreach ($entry in $entries) {
        if ($entry.Route -ceq 'operation') {
            $record = $State.Operations[$entry.OperationId]
            if ($null -ne $record) { Complete-WorkloadMcpUndispatched -State $State -Record $record }
        } elseif ($entry.Route -ceq 'start' -or $null -eq $entry.Call) {
            continue
        } elseif ($SessionEnding) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $entry.Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
        } else {
            $null = Send-WorkloadMcpToolResult -State $State -Call $entry.Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_worker_lost' -Key 'runner.workload_worker_lost')
        }
    }
}

function Close-WorkloadMcpWorker {
    <#
    .SYNOPSIS
        Closes a worker that holds no session: its request pipe ends, and it exits by itself.
    .DESCRIPTION
        A request already in flight stays in flight and keeps its call's
        deadline. A worker that does not exit within the grace period is
        killed by the timer. A worker that is closing already is left to its
        two deadlines.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$State)
    $worker = $State.Worker
    if ($null -eq $worker -or $worker.Closing) { return }
    $null = & $worker.CloseInput
    $worker.Closing = $true
    $worker.CloseDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:ShutdownGraceSeconds * 1000
    Write-WorkloadMcpServerLog -State $State -EventName 'worker-close'
    Clear-WorkloadMcpQueue -State $State
}

function Close-WorkloadMcpSession {
    <#
    .SYNOPSIS
        Begins the end of the session; returns the answer of an end call, or $null when the end call waits.
    .DESCRIPTION
        Without a session it answers ended false and leaves a worker without
        a session running, except at the end of the client's input, which
        closes that worker. With a session it cancels the operation in flight,
        settles the queue, sends the session.end request and starts the grace
        period; the end calls are answered by Invoke-WorkloadMcpWorkerExit.
        A second call while the session ends changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('client-request', 'client-ended')][string]$Reason
    )
    $session = $State.Session
    if ($session.Phase -cin @('none', 'ended')) {
        if ($Reason -ceq 'client-ended') { Close-WorkloadMcpWorker -State $State }
        return [ordered]@{ ok = $true; ended = $false }
    }
    if ($session.Phase -ceq 'ending') { return $null }
    $session.Phase = 'ending'
    $session.StartDeadline = $null
    $busy = Get-WorkloadMcpBusyOperation -State $State
    $session.EndOperationId = $(if ($null -ne $busy) { $busy.Id } else { $null })
    Clear-WorkloadMcpQueue -State $State -SessionEnding
    $inFlight = $State.InFlight
    if ($null -ne $State.Worker -and $null -ne $inFlight -and $inFlight.Entry.Route -ceq 'operation') {
        $record = $State.Operations[$inFlight.Entry.OperationId]
        if ($null -ne $record -and $record.State -ceq 'running') {
            Send-WorkloadMcpFrame -State $State -Frame ([ordered]@{ type = 'cancel'; id = $record.RequestId })
            $record.State = 'canceling'
            Write-WorkloadMcpServerLog -State $State -EventName 'operation' -Data ([ordered]@{ operationId = $record.Id; state = 'canceling' })
        }
    }
    foreach ($call in @($State.Calls.ToArray())) {
        if ($call.Route -ceq 'start') {
            $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
        }
    }
    $State.NextRequest = $State.NextRequest + 1
    $session.EndRequestId = 'r' + $State.NextRequest
    $session.EndReason = $Reason
    if ($null -ne $State.Worker) {
        Send-WorkloadMcpFrame -State $State -Frame ([ordered]@{ type = 'request'; id = $session.EndRequestId; method = 'session.end'; params = [ordered]@{ reason = $Reason } })
    }
    $session.EndDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:ShutdownGraceSeconds * 1000
    return $null
}

function Write-WorkloadMcpSessionFile {
    <#
    .SYNOPSIS
        Rewrites session.json of a worker folder through a temporary file.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$Channel)
    $path = Join-Path $Channel.Folder 'session.json'
    $tmp = "$path.$PID.tmp"
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Channel.SessionDocument -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $path, $true)
    } catch {
        Write-Verbose "session.json was not written: $($_.Exception.Message)"
    }
}

function Invoke-WorkloadMcpSessionPrune {
    <#
    .SYNOPSIS
        Deletes the oldest session folders beyond the retention, sparing links and live sessions.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$Keep
    )
    $retain = [int](Get-WorkloadProtocolLimit).SessionFolderRetention - 1
    $names = [string[]]@(Get-ChildItem -LiteralPath $SessionRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -cmatch '^\d{8}T\d{6}Z-[0-9a-f]{8}$' -and $_.Name -cne $Keep } | ForEach-Object { $_.Name })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $excess = $names.Count - $retain
    for ($i = 0; $i -lt $excess; $i++) {
        $folder = Get-Item -LiteralPath (Join-Path $SessionRoot $names[$i]) -Force
        if ($folder.LinkTarget) { continue }
        $document = $null
        $sessionFile = Join-Path $folder.FullName 'session.json'
        if (Test-Path -LiteralPath $sessionFile -PathType Leaf) {
            try {
                $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($sessionFile)) -AsHashtable -DateKind String -NoEnumerate
            } catch {
                Write-Verbose "session.json of '$($folder.Name)' cannot be read: $($_.Exception.Message)"
            }
        }
        if ($document -is [System.Collections.IDictionary] -and [string]$document['state'] -cne 'ended' -and
            $document['frontEnd'] -is [System.Collections.IDictionary]) {
            $frontEnd = $document['frontEnd']
            if (Test-WorkloadProcessIdentity -ProcessId ([int]$frontEnd['pid']) -StartTicks ([long]$frontEnd['startTicks'])) { continue }
        }
        try {
            Remove-Item -LiteralPath $folder.FullName -Recurse -Force
        } catch {
            Write-Verbose "Session folder '$($folder.Name)' was not deleted: $($_.Exception.Message)"
        }
    }
}

function Open-WorkloadMcpWorkerProcess {
    <#
    .SYNOPSIS
        The default worker factory: starts the worker process and returns its channel.
    .DESCRIPTION
        The worker gets the client ends of two anonymous pipes. The front end
        drops its copies of those ends right after the start, whether or not
        the start threw; otherwise it would hold them and the worker would
        never see its request pipe close. Every read is asynchronous and every
        write is queued, so the loop never waits on the worker: a worker
        blocked on its own full stdout reads nothing, and a front end that
        waited for its write would stop draining that stdout.

        The script blocks of the channel are closures over $channel, $clock and
        $writeTimeoutTicks. A closure runs in a module of its own, where a
        script variable reads $null and a function of this script is not
        found, so they use only those locals, their parameter and .NET.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable]$State)
    $opening = $State.Opening
    $requestPipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::Out, [IO.HandleInheritability]::Inheritable, 65536)
    try {
        $replyPipe = [IO.Pipes.AnonymousPipeServerStream]::new([IO.Pipes.PipeDirection]::In, [IO.HandleInheritability]::Inheritable, 65536)
    } catch {
        $requestPipe.Dispose()
        throw
    }
    $pwsh = (Get-Process -Id $PID).Path
    if (-not $pwsh) { $pwsh = 'pwsh' }
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $argv = @('-NoProfile', '-NonInteractive', '-File', $State.WorkerScript,
        '-RequestPipeHandle', $requestPipe.GetClientHandleAsString(), '-ReplyPipeHandle', $replyPipe.GetClientHandleAsString(),
        '-SessionId', $opening.SessionId, '-SessionDir', $opening.Folder, '-RefBase', [string]$opening.RefBase)
    if ($State.ConfigPath) { $argv += @('-ConfigPath', $State.ConfigPath) }
    foreach ($argument in $argv) { $psi.ArgumentList.Add([string]$argument) }
    $process = $null
    try {
        try {
            $process = [Diagnostics.Process]::Start($psi)
        } finally {
            $requestPipe.DisposeLocalCopyOfClientHandle()
            $replyPipe.DisposeLocalCopyOfClientHandle()
        }
    } catch {
        $requestPipe.Dispose()
        $replyPipe.Dispose()
        throw
    }
    $process.StandardInput.Close()
    $reader = [IO.StreamReader]::new($replyPipe, $utf8)
    $channel = @{
        Process       = $process
        StartTicks    = $process.StartTime.ToUniversalTime().Ticks
        ExitTask      = $process.WaitForExitAsync([Threading.CancellationToken]::None)
        RequestPipe   = $requestPipe
        ReplyPipe     = $replyPipe
        Reader        = $reader
        ReadTask      = $reader.ReadLineAsync()
        OutBuffer     = [char[]]::new(8192)
        ErrBuffer     = [char[]]::new(8192)
        OutTask       = $null
        ErrTask       = $null
        Hello         = $null
        HelloDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:WorkerHelloTimeoutSeconds * 1000
        OutQueue      = [Collections.Generic.Queue[byte[]]]::new()
        WriteTask     = $null
        WriteDeadline = $null
    }
    $clock = $State.Clock
    $writeTimeoutTicks = [long]$script:WorkerWriteTimeoutSeconds * 1000
    $channel.Send = {
        param($Line)
        $channel.OutQueue.Enqueue([Text.UTF8Encoding]::new($false).GetBytes([string]$Line + "`n"))
    }.GetNewClosure()
    $channel.Pump = {
        if ($null -ne $channel.WriteTask) {
            if (-not $channel.WriteTask.IsCompleted) {
                return (-not ((& $clock) -ge $channel.WriteDeadline))
            }
            if (-not $channel.WriteTask.IsCompletedSuccessfully) { return $false }
            $channel.WriteTask = $null
        }
        if ($channel.OutQueue.Count -gt 0) {
            $bytes = $channel.OutQueue.Dequeue()
            try {
                $channel.WriteTask = $channel.RequestPipe.WriteAsync($bytes, 0, $bytes.Length)
            } catch {
                Write-Verbose "The request pipe refused a write: $($_.Exception.Message)"
                return $false
            }
            $channel.WriteDeadline = (& $clock) + $writeTimeoutTicks
        }
        return $true
    }.GetNewClosure()
    $channel.ReadNext = { $channel.Reader.ReadLineAsync() }.GetNewClosure()
    $channel.ReadOut = { $channel.Process.StandardOutput.ReadAsync($channel.OutBuffer, 0, $channel.OutBuffer.Length) }.GetNewClosure()
    $channel.ReadErr = { $channel.Process.StandardError.ReadAsync($channel.ErrBuffer, 0, $channel.ErrBuffer.Length) }.GetNewClosure()
    $channel.Kill = {
        try {
            if (-not $channel.Process.HasExited) { $channel.Process.Kill($true) }
        } catch {
            Write-Verbose "The worker was not killed: $($_.Exception.Message)"
        }
    }.GetNewClosure()
    $channel.CloseInput = {
        $channel.OutQueue.Clear()
        $channel.WriteTask = $null
        try { $channel.RequestPipe.Dispose() } catch { Write-Verbose "The request pipe did not close: $($_.Exception.Message)" }
    }.GetNewClosure()
    $channel.Dispose = {
        foreach ($item in @($channel.Reader, $channel.RequestPipe, $channel.ReplyPipe, $channel.Process)) {
            try { if ($null -ne $item) { $item.Dispose() } } catch { Write-Verbose "A worker handle did not close: $($_.Exception.Message)" }
        }
    }.GetNewClosure()
    $channel.OutTask = & $channel.ReadOut
    $channel.ErrTask = & $channel.ReadErr
    return $channel
}

function Open-WorkloadMcpWorker {
    <#
    .SYNOPSIS
        Opens a worker through the state's factory: the session id, its folder, the prune and session.json.
    .DESCRIPTION
        The one caller of State.WorkerFactory, so a stub factory gets the same
        folder, id and reference block as the real one. Worker n of one front
        end starts its references at (n - 1) * ReferenceBlock, so an id never
        names two nodes within one server process. A factory that throws
        leaves State.Worker $null and the exception reaches the caller.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param([Parameter(Mandatory)][hashtable]$State)
    if (-not $State.SessionRoot) { throw [System.InvalidOperationException]::new('The state has no SessionRoot.') }
    $State.NextRequest = 0
    $State.InFlight = $null
    $State.WorkerOrdinal = $State.WorkerOrdinal + 1
    $stamp = [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $id = $stamp + '-' + [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(4)).ToLowerInvariant()
    $folder = Join-Path $State.SessionRoot $id
    $null = New-Item -ItemType Directory -Path $folder -Force
    Invoke-WorkloadMcpSessionPrune -SessionRoot $State.SessionRoot -Keep $id
    $State.Opening = @{ SessionId = $id; Folder = $folder; RefBase = [long]($State.WorkerOrdinal - 1) * [long](Get-WorkloadProtocolLimit).ReferenceBlock }
    $channel = & $State.WorkerFactory $State
    $channel.SessionId = $id
    $channel.Folder = $folder
    $channel.ErrTail = ''
    $channel.ExitSeen = $null
    $channel.Closing = $false
    $State.Worker = $channel
    $self = Get-Process -Id $PID
    $workerIdentity = $null
    if ($null -ne $channel.Process) { $workerIdentity = [ordered]@{ pid = $channel.Process.Id; startTicks = [long]$channel.StartTicks } }
    $channel.SessionDocument = [ordered]@{
        sessionId  = $id
        createdUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        frontEnd   = [ordered]@{ pid = $PID; startTicks = $self.StartTime.ToUniversalTime().Ticks }
        worker     = $workerIdentity
        state      = 'open'
    }
    Write-WorkloadMcpSessionFile -Channel $channel
    Write-WorkloadMcpServerLog -State $State -EventName 'worker-start' -Data ([ordered]@{ ordinal = $State.WorkerOrdinal; pid = $(if ($null -ne $channel.Process) { $channel.Process.Id } else { $null }) })
}

function Open-WorkloadMcpRouteWorker {
    <#
    .SYNOPSIS
        Opens a worker for a call when there is none or the one there closes; returns a refusal when it cannot.
    .DESCRIPTION
        A closing worker is not waited for: it is killed and its exit handled
        at once, then a new worker is opened.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$State)
    if ($null -ne $State.Worker -and -not $State.Worker.Closing) { return $null }
    if ($null -ne $State.Worker) {
        Write-WorkloadMcpServerLog -State $State -EventName 'worker-kill' -Data ([ordered]@{ reason = 'superseded' })
        $null = & $State.Worker.Kill
        Invoke-WorkloadMcpWorkerExit -State $State -Reason 'superseded'
    }
    try {
        Open-WorkloadMcpWorker -State $State
    } catch {
        return (Get-WorkloadMcpErrorResult -Code 'workload_worker_start_failed' -Key 'runner.workload_worker_start_failed' -Arguments @{ detail = $_.Exception.Message })
    }
    return $null
}

function Get-WorkloadMcpFileResult {
    <#
    .SYNOPSIS
        Answers workload_journal or workload_failure from the file the worker wrote, without touching the worker.
    .DESCRIPTION
        The worker replaces the file while it may be read, so the read is
        tried three times and shares the file for writing and deletion. The
        text is returned unchanged; it is parsed only to read ok.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][string]$FileName
    )
    $folder = [string]$State.Session.Folder
    if ($folder) {
        $path = Join-Path $folder $FileName
        for ($try = 1; $try -le 3; $try++) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { break }
            try {
                $stream = [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                try {
                    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false))
                    $text = $reader.ReadToEnd()
                    $reader.Dispose()
                } finally {
                    $stream.Dispose()
                }
                $parsed = ConvertFrom-Json -InputObject $text -AsHashtable -DateKind String -NoEnumerate -ErrorAction Stop
                if ($parsed -is [System.Collections.IDictionary]) {
                    $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $parsed -RawText $text
                    return
                }
            } catch {
                Write-Verbose "$FileName was not read on try $($try): $($_.Exception.Message)"
            }
            if ($try -lt 3) { Start-Sleep -Milliseconds 50 }
        }
    }
    $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
}

function Invoke-WorkloadMcpQueuedRoute {
    <#
    .SYNOPSIS
        Routes a call of route worker or session: checks, then queues its request.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][hashtable]$Added
    )
    $busy = Get-WorkloadMcpBusyOperation -State $State
    if ($null -ne $busy) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_busy' -Key 'runner.workload_busy' -Arguments @{ operationId = $busy.Id })
        return
    }
    $phase = $State.Session.Phase
    if (($Tool.Route -ceq 'session' -and $phase -cnotin @('starting', 'active')) -or ($Tool.Route -ceq 'worker' -and $phase -ceq 'ending')) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
        return
    }
    $surface = [string]$Arguments['surface']
    $refusal = Get-WorkloadMcpSurfaceRefusal -State $State -Surface $surface
    if ($null -ne $refusal) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $refusal
        return
    }
    if ($State.Queue.Count -ge [int](Get-WorkloadProtocolLimit).MaxQueuedCalls) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_queue_full' -Key 'runner.workload_queue_full')
        return
    }
    if ($Tool.Route -ceq 'worker') {
        $refusal = Open-WorkloadMcpRouteWorker -State $State
        if ($null -ne $refusal) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $refusal
            return
        }
    }
    $entry = @{ Route = $Tool.Route; Method = $Tool.Method; Params = $Arguments; Call = $Call; OperationId = $null; Surface = $surface }
    $Added.Entry = $entry
    $State.Queue.Add($entry)
    Send-WorkloadMcpNextCall -State $State
}

function Invoke-WorkloadMcpStartRoute {
    <#
    .SYNOPSIS
        Routes workload_session_start: joins an identical start, refuses another, or opens a session.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][hashtable]$Added
    )
    $session = $State.Session
    $hash = Get-WorkloadInputHash -Tool 'workload_session_start' -Arguments $Arguments
    if ($session.Phase -cin @('active', 'starting') -and $session.InputHash -ceq $hash) {
        if ($session.Phase -ceq 'active') { $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $session.StartResult }
        return
    }
    if ($session.Phase -cin @('active', 'starting', 'ending')) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_session_active' -Key 'runner.workload_session_active' -Arguments @{ vmName = [string]$session.VmName })
        return
    }
    $State.Operations.Clear()
    $refusal = Open-WorkloadMcpRouteWorker -State $State
    if ($null -ne $refusal) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $refusal
        return
    }
    $session.Phase = 'starting'
    $session.Attached = $false
    $session.InputHash = $hash
    $session.VmName = [string]$Arguments['vmName']
    $session.StartResult = $null
    $session.StartDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:SessionStartTimeoutSeconds * 1000
    $entry = @{ Route = 'start'; Method = 'session.start'; Params = $Arguments; Call = $null; OperationId = $null; Surface = $null }
    $Added.Entry = $entry
    $State.Queue.Add($entry)
    Send-WorkloadMcpNextCall -State $State
}

function Invoke-WorkloadMcpOperationRoute {
    <#
    .SYNOPSIS
        Routes an operation tool: the poll form, the run form of a known id, and a new run.
    .DESCRIPTION
        A refusal that creates no record is the plain refusal, without a
        state: only an operation that has a record is answered with one.
        The front end creates no file for a cancel; the worker stops the
        operation at its next gate.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$Call,
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Arguments,
        [Parameter(Mandatory)][hashtable]$Added
    )
    $operationId = [string]$Arguments['operationId']
    $fields = Get-WorkloadMcpRunField -Name $Tool.Name
    $runForm = @($fields.Run | Where-Object { $Arguments.Contains($_) }).Count -gt 0
    $record = $State.Operations[$operationId]
    if (-not $runForm) {
        if ($null -eq $record) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_operation_unknown' -Key 'runner.workload_operation_unknown' -Arguments @{ operationId = $operationId })
            return
        }
        if ($record.Tool -cne $Tool.Name) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_operation_conflict' -Key 'runner.workload_operation_conflict' -Arguments @{ operationId = $operationId })
            return
        }
        $Call.OperationId = $operationId
        if ($Arguments['cancel'] -eq $true -and $record.State -ceq 'running') {
            if (-not $record.Dispatched) {
                foreach ($entry in @($State.Queue.ToArray())) {
                    if ($entry.Route -ceq 'operation' -and $entry.OperationId -ceq $operationId) { $null = Clear-WorkloadMcpListItem -List $State.Queue -Item $entry }
                }
                Complete-WorkloadMcpUndispatched -State $State -Record $record
                return
            }
            Send-WorkloadMcpFrame -State $State -Frame ([ordered]@{ type = 'cancel'; id = $record.RequestId })
            $record.State = 'canceling'
            Write-WorkloadMcpServerLog -State $State -EventName 'operation' -Data ([ordered]@{ operationId = $operationId; state = 'canceling' })
        }
        if ($record.State -cin @('succeeded', 'failed', 'canceled', 'uncertain')) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $record.Result
        }
        return
    }
    $hash = Get-WorkloadInputHash -Tool $Tool.Name -Arguments $Arguments
    if ($null -ne $record) {
        if ($record.Tool -cne $Tool.Name -or $record.InputHash -cne $hash) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_operation_conflict' -Key 'runner.workload_operation_conflict' -Arguments @{ operationId = $operationId })
            return
        }
        $Call.OperationId = $operationId
        if ($record.State -cin @('succeeded', 'failed', 'canceled', 'uncertain')) {
            $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $record.Result
        }
        return
    }
    if ($State.Session.Phase -cnotin @('starting', 'active')) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
        return
    }
    $busy = Get-WorkloadMcpBusyOperation -State $State
    if ($null -ne $busy) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_busy' -Key 'runner.workload_busy' -Arguments @{ operationId = $busy.Id })
        return
    }
    $surface = [string]$Arguments['on']
    $refusal = Get-WorkloadMcpSurfaceRefusal -State $State -Surface $surface
    if ($null -ne $refusal) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result $refusal
        return
    }
    if ($State.Queue.Count -ge [int](Get-WorkloadProtocolLimit).MaxQueuedCalls) {
        $null = Send-WorkloadMcpToolResult -State $State -Call $Call -Result (Get-WorkloadMcpErrorResult -Code 'workload_queue_full' -Key 'runner.workload_queue_full')
        return
    }
    $params = [ordered]@{}
    foreach ($key in $Arguments.Keys) { if ($key -cne 'cancel') { $params[$key] = $Arguments[$key] } }
    $params['operationId'] = $operationId
    $record = @{ Id = $operationId; Tool = $Tool.Name; InputHash = $hash; State = 'running'; Result = $null; Progress = $null
        RequestId = $null; Dispatched = $false; CreatedTicks = (Get-WorkloadMcpNow -State $State) }
    $State.Operations[$operationId] = $record
    $Added.OperationId = $operationId
    $Call.OperationId = $operationId
    Write-WorkloadMcpServerLog -State $State -EventName 'operation' -Data ([ordered]@{ operationId = $operationId; tool = $Tool.Name; state = 'running' })
    $entry = @{ Route = 'operation'; Method = $Tool.Method; Params = $params; Call = $null; OperationId = $operationId; Surface = $surface }
    $Added.Entry = $entry
    $State.Queue.Add($entry)
    Send-WorkloadMcpNextCall -State $State
}

function Invoke-WorkloadMcpToolCall {
    <#
    .SYNOPSIS
        Answers tools/call: the tool, its arguments, the frame limit, then the route.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Request,
        [Parameter(Mandatory)][hashtable]$Added
    )
    $id = $Request['id']
    $params = $Request['params']
    if ($params -isnot [System.Collections.IDictionary]) { $params = @{} }
    $name = $params['name']
    $tool = $null
    if ($name -is [string]) { $tool = @(Get-WorkloadMcpToolTable | Where-Object { $_.Name -ceq $name }) | Select-Object -First 1 }
    if ($null -eq $tool) {
        Write-WorkloadMcpResponse -State $State -Id $id -HasId -ErrorCode -32602 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_unknown_tool' -Arguments @{ name = [string]$name })
        return
    }
    $arguments = $(if ($params.Contains('arguments')) { $params['arguments'] } else { [ordered]@{} })
    $problem = $null
    if ($arguments -isnot [System.Collections.IDictionary]) {
        $problem = Get-YurunaJsonSchemaError -Json (ConvertTo-Json -InputObject $arguments -Compress -Depth 32) -Schema $tool.Schema
    } else {
        $problem = Test-WorkloadMcpArgument -Tool $tool -Arguments $arguments
    }
    if ($null -ne $problem) {
        Write-WorkloadMcpResponse -State $State -Id $id -HasId -ErrorCode -32602 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_invalid_arguments' -Arguments @{ name = $tool.Name; detail = $problem })
        return
    }
    $limit = [int](Get-WorkloadProtocolLimit).MaxFrameChars - 1024
    if ((ConvertTo-Json -InputObject $arguments -Compress -Depth 32).Length -gt $limit) {
        Write-WorkloadMcpResponse -State $State -Id $id -HasId -ErrorCode -32600 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_request_too_large' -Arguments @{ limit = $limit })
        return
    }
    $progressToken = $null
    if ($params['_meta'] -is [System.Collections.IDictionary]) { $progressToken = $params['_meta']['progressToken'] }
    $call = @{ RpcId = $id; Tool = $tool.Name; Route = $tool.Route; OperationId = $null
        Deadline = (Get-WorkloadMcpNow -State $State) + $State.MaxCallMs; ProgressToken = $progressToken; ProgressCount = 0 }
    $State.Calls.Add($call)
    $Added.Call = $call
    switch -CaseSensitive ($tool.Route) {
        'file' {
            $fileName = $(if ($tool.Name -ceq 'workload_journal') { 'journal.result.json' } else { 'failure.result.json' })
            Get-WorkloadMcpFileResult -State $State -Call $call -FileName $fileName
        }
        'start' { Invoke-WorkloadMcpStartRoute -State $State -Call $call -Arguments $arguments -Added $Added }
        'end' {
            $answer = Close-WorkloadMcpSession -State $State -Reason 'client-request'
            if ($null -ne $answer) { $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result $answer }
        }
        'operation' { Invoke-WorkloadMcpOperationRoute -State $State -Call $call -Tool $tool -Arguments $arguments -Added $Added }
        default { Invoke-WorkloadMcpQueuedRoute -State $State -Call $call -Tool $tool -Arguments $arguments -Added $Added }
    }
}

function Invoke-WorkloadMcpCancelNotification {
    <#
    .SYNOPSIS
        notifications/cancelled: drops the call, never the start or the operation it waits for.
    .DESCRIPTION
        A client that gives up on a request sends the same notification as a
        user who interrupts, so an operation stays reachable by its id. The
        request of a worker or session call is dropped from the queue, or,
        when in flight, marked abandoned so its reply is dropped.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()]$RequestId
    )
    foreach ($call in @($State.Calls.ToArray())) {
        if (-not (Test-WorkloadMcpSameId -Left $call.RpcId -Right $RequestId)) { continue }
        $null = Clear-WorkloadMcpListItem -List $State.Calls -Item $call
        if ($call.Route -cin @('worker', 'session')) {
            foreach ($entry in @($State.Queue.ToArray())) {
                if ([object]::ReferenceEquals($entry.Call, $call)) { $null = Clear-WorkloadMcpListItem -List $State.Queue -Item $entry }
            }
            if ($null -ne $State.InFlight -and [object]::ReferenceEquals($State.InFlight.Entry.Call, $call)) { $State.InFlight.Abandoned = $true }
        }
        Write-WorkloadMcpServerLog -State $State -EventName 'client-cancel' -Data ([ordered]@{ id = $call.RpcId; tool = $call.Tool })
    }
}

function Invoke-WorkloadMcpClientLine {
    <#
    .SYNOPSIS
        Handles one line from the client and writes its answer, if any.
    .DESCRIPTION
        A notification is never answered. An exception while one line is
        handled answers -32603 and takes back what the line added while its
        request still waits in the queue, so a deadline of that call never
        fires later; a request already in flight stays there and its reply
        is stored.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [AllowNull()][AllowEmptyString()][string]$Line
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $limits = Get-WorkloadProtocolLimit
    if ($Line.Length -gt $limits.MaxRequestLineChars) {
        Write-WorkloadMcpResponse -State $State -ErrorCode -32600 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_request_too_large' -Arguments @{ limit = $limits.MaxRequestLineChars })
        return
    }
    $request = $null
    try {
        $request = ConvertFrom-Json -InputObject $Line -AsHashtable -DateKind String -NoEnumerate -ErrorAction Stop
    } catch {
        Write-WorkloadMcpResponse -State $State -ErrorCode -32700 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_invalid_json')
        return
    }
    if ($request -isnot [System.Collections.IDictionary]) {
        Write-WorkloadMcpResponse -State $State -ErrorCode -32600 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_invalid_request')
        return
    }
    $hasId = $request.Contains('id') -and $null -ne $request['id']
    $id = $request['id']
    $method = $request['method']
    if ($method -isnot [string]) {
        if ($request.Contains('result') -or $request.Contains('error')) { return }
        $validId = $hasId -and (Test-WorkloadMcpIdType -Id $id)
        Write-WorkloadMcpResponse -State $State -Id $id -HasId:$validId -ErrorCode -32600 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_invalid_request')
        return
    }
    if (-not $hasId) {
        if ($method -ceq 'notifications/cancelled' -and $request['params'] -is [System.Collections.IDictionary]) {
            Invoke-WorkloadMcpCancelNotification -State $State -RequestId $request['params']['requestId']
        }
        return
    }
    if (-not (Test-WorkloadMcpIdType -Id $id)) {
        Write-WorkloadMcpResponse -State $State -ErrorCode -32600 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_invalid_request')
        return
    }
    $added = @{ Call = $null; Entry = $null; OperationId = $null }
    $toolName = $null
    if ($method -ceq 'tools/call' -and $request['params'] -is [System.Collections.IDictionary] -and $request['params']['name'] -is [string]) { $toolName = $request['params']['name'] }
    Write-WorkloadMcpServerLog -State $State -EventName 'request' -Data ([ordered]@{ id = $id; method = $method; tool = $toolName })
    try {
        switch -CaseSensitive ($method) {
            'initialize' {
                $params = $request['params']
                $requested = $null
                if ($params -is [System.Collections.IDictionary]) { $requested = $params['protocolVersion'] }
                $version = $(if ($requested -is [string] -and $script:SupportedProtocolVersion -ccontains $requested) { $requested } else { '2025-06-18' })
                Write-WorkloadMcpResponse -State $State -Id $id -HasId -Result ([ordered]@{
                        protocolVersion = $version
                        capabilities    = [ordered]@{ tools = [ordered]@{ listChanged = $false } }
                        serverInfo      = [ordered]@{ name = 'yuruna-workload'; version = (Get-WorkloadMcpServerVersion) }
                        instructions    = (Format-YurunaOperatorMessage -Key 'runner.mcp_workload_instructions' -Arguments @{ reference = '${ext:authentication.GetPassword(${username})}' })
                    })
            }
            'ping' { Write-WorkloadMcpResponse -State $State -Id $id -HasId -Result ([ordered]@{}) }
            'tools/list' {
                $table = @(Get-WorkloadMcpToolTable)
                $names = [string[]]@($table | ForEach-Object { $_.Name })
                [Array]::Sort($names, [StringComparer]::Ordinal)
                $tools = [Collections.Generic.List[object]]::new()
                foreach ($toolName in $names) {
                    $tool = $table | Where-Object { $_.Name -ceq $toolName } | Select-Object -First 1
                    $tools.Add([ordered]@{
                            name        = $tool.Name
                            description = $tool.Description
                            inputSchema = (ConvertFrom-Json -InputObject $tool.Schema -AsHashtable -NoEnumerate)
                            annotations = [ordered]@{ readOnlyHint = [bool]$tool.ReadOnly; destructiveHint = [bool]$tool.Destructive; idempotentHint = [bool]$tool.Idempotent }
                        })
                }
                Write-WorkloadMcpResponse -State $State -Id $id -HasId -Result ([ordered]@{ tools = $tools.ToArray() })
            }
            'tools/call' { Invoke-WorkloadMcpToolCall -State $State -Request $request -Added $added }
            default {
                Write-WorkloadMcpResponse -State $State -Id $id -HasId -ErrorCode -32601 -ErrorMessage (Format-YurunaOperatorMessage -Key 'runner.mcp_unknown_method' -Arguments @{ method = $method })
            }
        }
    } catch {
        $message = "$($_.Exception.Message)"
        if ($null -ne $added.Call) { $null = Clear-WorkloadMcpListItem -List $State.Calls -Item $added.Call }
        $inFlight = ($null -ne $added.Entry -and $null -ne $State.InFlight -and [object]::ReferenceEquals($State.InFlight.Entry, $added.Entry))
        if (-not $inFlight) {
            if ($null -ne $added.Entry) { $null = Clear-WorkloadMcpListItem -List $State.Queue -Item $added.Entry }
            if ($null -ne $added.OperationId) { $State.Operations.Remove($added.OperationId) }
        }
        Write-WorkloadMcpResponse -State $State -Id $id -HasId -ErrorCode -32603 -ErrorMessage $message
    }
}

function Receive-WorkloadMcpStartReply {
    <#
    .SYNOPSIS
        Handles the worker's reply to session.start.
    .DESCRIPTION
        A reply that arrives while the phase is no longer starting changes
        nothing and answers nothing: its calls were answered when the phase
        changed. The front end reads only ok from the reply.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result
    )
    $session = $State.Session
    if ($session.Phase -cne 'starting') { return }
    $session.StartDeadline = $null
    $worker = $State.Worker
    if ($Result['ok'] -eq $true) {
        $session.Phase = 'active'
        $session.Attached = $true
        $session.Folder = $worker.Folder
        $session.Id = $worker.SessionId
        $Result['sessionId'] = $worker.SessionId
        $Result['sessionFolder'] = $worker.Folder
        $Result['surfaces'] = [object[]]@($worker.Hello['surfaces'])
        $session.StartResult = $Result
        if ($null -ne $worker.SessionDocument) {
            $worker.SessionDocument['vmName'] = [string]$Result['vmName']
            $worker.SessionDocument['guestKey'] = [string]$Result['guestKey']
            $worker.SessionDocument['state'] = 'attached'
            Write-WorkloadMcpSessionFile -Channel $worker
        }
        foreach ($call in @($State.Calls.ToArray())) {
            if ($call.Route -ceq 'start') { $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result $Result }
        }
        return
    }
    $session.Phase = 'none'
    foreach ($call in @($State.Calls.ToArray())) {
        if ($call.Route -ceq 'start') { $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result $Result }
    }
    Close-WorkloadMcpWorker -State $State
}

function Receive-WorkloadMcpReply {
    <#
    .SYNOPSIS
        Handles a reply for the request in flight.
    .DESCRIPTION
        An operation's state comes from the result's state when it is
        succeeded, failed or canceled, else from ok.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][hashtable]$InFlight,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result
    )
    $entry = $InFlight.Entry
    if ($InFlight.Abandoned) {
        Write-WorkloadMcpServerLog -State $State -EventName 'reply-dropped' -Data ([ordered]@{ id = $InFlight.Id; reason = 'call-gone' })
        return
    }
    switch -CaseSensitive ($entry.Route) {
        'start' { Receive-WorkloadMcpStartReply -State $State -Result $Result }
        'operation' {
            $record = $State.Operations[$entry.OperationId]
            if ($null -eq $record) { return }
            $final = [string]$Result['state']
            if ($final -cnotin @('succeeded', 'failed', 'canceled')) { $final = $(if ($Result['ok'] -eq $true) { 'succeeded' } else { 'failed' }) }
            Complete-WorkloadMcpOperation -State $State -Record $record -Result $Result -FinalState $final
        }
        default {
            if ($null -ne $entry.Call) { $null = Send-WorkloadMcpToolResult -State $State -Call $entry.Call -Result $Result }
        }
    }
}

function Invoke-WorkloadMcpWorkerLost {
    <#
    .SYNOPSIS
        A worker that broke the protocol: kill it, then handle its exit.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$Detail = ''
    )
    if ($null -eq $State.Worker) { return }
    Write-WorkloadMcpServerLog -State $State -EventName 'worker-kill' -Data ([ordered]@{ reason = 'lost'; detail = $Detail })
    $null = & $State.Worker.Kill
    Invoke-WorkloadMcpWorkerExit -State $State -Reason 'lost'
}

function Invoke-WorkloadMcpWorkerFrame {
    <#
    .SYNOPSIS
        Handles one line from the worker's reply pipe.
    .DESCRIPTION
        hello comes first, once, with the protocol number and the session id
        the front end gave; anything else before it is a failed start. A line
        that is no frame, a frame of an unknown type, a reply without a result
        object with a boolean ok and a progress without integer counts are a
        lost worker. A reply or a progress that names no request in flight is
        logged and dropped.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    $worker = $State.Worker
    if ($null -eq $worker) { return }
    $frame = $null
    try {
        $frame = ConvertFrom-WorkloadFrameLine -Line $Line
    } catch {
        Invoke-WorkloadMcpWorkerLost -State $State -Detail 'malformed-frame'
        return
    }
    $type = [string]$frame['type']
    Write-WorkloadMcpServerLog -State $State -EventName 'frame-in' -Data ([ordered]@{ type = $type; id = $(if ($frame['id'] -is [string] -or $frame['id'] -is [long] -or $frame['id'] -is [int]) { $frame['id'] } else { $null }); length = $Line.Length })
    if ($null -eq $worker.Hello) {
        $limits = Get-WorkloadProtocolLimit
        $surfaces = $frame['surfaces']
        $valid = $type -ceq 'hello' -and ($frame['protocol'] -is [long] -or $frame['protocol'] -is [int]) -and
            [long]$frame['protocol'] -eq [long]$limits.PipeProtocol -and $frame['sessionId'] -is [string] -and
            $frame['sessionId'] -ceq $worker.SessionId -and $surfaces -is [System.Collections.IList] -and
            @($surfaces | Where-Object { $_ -isnot [string] }).Count -eq 0
        if (-not $valid) {
            Invoke-WorkloadMcpWorkerLost -State $State -Detail 'hello'
            return
        }
        $worker.Hello = $frame
        Write-WorkloadMcpServerLog -State $State -EventName 'worker-hello' -Data ([ordered]@{ pid = $frame['pid']; surfaces = (@($surfaces) -join ',') })
        Send-WorkloadMcpNextCall -State $State
        return
    }
    switch -CaseSensitive ($type) {
        'reply' {
            $result = $frame['result']
            if ($result -isnot [System.Collections.IDictionary] -or -not $result.Contains('ok') -or $result['ok'] -isnot [bool]) {
                Invoke-WorkloadMcpWorkerLost -State $State -Detail 'reply-shape'
                return
            }
            $replyId = $frame['id']
            $session = $State.Session
            if ($null -ne $session.EndRequestId -and $replyId -is [string] -and $replyId -ceq $session.EndRequestId) {
                $session.EndReply = $result
                return
            }
            $inFlight = $State.InFlight
            if ($null -eq $inFlight -or $replyId -isnot [string] -or $replyId -cne $inFlight.Id) {
                Write-WorkloadMcpServerLog -State $State -EventName 'reply-dropped' -Data ([ordered]@{ reason = 'no-request' })
                return
            }
            $State.InFlight = $null
            Receive-WorkloadMcpReply -State $State -InFlight $inFlight -Result $result
            Send-WorkloadMcpNextCall -State $State
        }
        'progress' {
            $completed = $frame.completed
            $total = $frame.total
            if (($completed -isnot [long] -and $completed -isnot [int]) -or ($total -isnot [long] -and $total -isnot [int])) {
                Invoke-WorkloadMcpWorkerLost -State $State -Detail 'progress-shape'
                return
            }
            $inFlight = $State.InFlight
            $record = $null
            if ($null -ne $inFlight -and $inFlight.Entry.Route -ceq 'operation' -and $frame['id'] -is [string] -and $frame['id'] -ceq $inFlight.Id) {
                $record = $State.Operations[$inFlight.Entry.OperationId]
            }
            if ($null -eq $record -or $record.RequestId -cne $inFlight.Id) {
                Write-WorkloadMcpServerLog -State $State -EventName 'progress-dropped'
                return
            }
            $label = [string]$frame['label']
            $record.Progress = [ordered]@{ completed = $completed; total = $total; label = $label }
            foreach ($call in @($State.Calls.ToArray())) {
                if ($call.Route -cne 'operation' -or [string]$call.OperationId -cne $record.Id -or $null -eq $call.ProgressToken) { continue }
                $call.ProgressCount = $call.ProgressCount + 1
                Write-WorkloadMcpMessage -State $State -Message ([ordered]@{
                        jsonrpc = '2.0'
                        method  = 'notifications/progress'
                        params  = [ordered]@{ progressToken = $call.ProgressToken; progress = $call.ProgressCount; total = $total; message = ('{0}/{1} {2}' -f $completed, $total, $label) }
                    })
            }
        }
        'mask' {
            foreach ($value in @($frame['values'])) {
                if ($value -is [string] -and $value.Length -gt 0 -and -not $State.Masks.Contains($value)) { $State.Masks.Add($value) }
            }
            if (-not $worker.Closing) { Send-WorkloadMcpFrame -State $State -Frame ([ordered]@{ type = 'mask.ack'; id = $frame['id'] }) }
        }
        default { Invoke-WorkloadMcpWorkerLost -State $State -Detail 'frame-type' }
    }
}

function Add-WorkloadMcpWorkerLog {
    <#
    .SYNOPSIS
        Appends text the worker wrote to stdout or stderr to its log, with every registered value masked.
    .DESCRIPTION
        A value can arrive split over two reads, so the last (longest mask
        length minus one) characters wait for the next read before they are
        written. Past MaxWorkerLogChars the log stops after one line that says
        so, and reading goes on. ErrTail keeps the last 2000 masked characters
        of stderr for the detail of workload_worker_start_failed.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('out', 'err')][string]$Stream,
        [AllowEmptyString()][string]$Text = '',
        [switch]$EndOfStream
    )
    $worker = $State.Worker
    if ($null -eq $worker) { return }
    if ($null -eq $worker.LogState) { $worker.LogState = @{} }
    $log = $worker.LogState[$Stream]
    if ($null -eq $log) {
        $log = @{ Tail = ''; Written = [long]0; Stopped = $false }
        $worker.LogState[$Stream] = $log
    }
    $masks = [string[]]@($State.Masks | Sort-Object -Property Length -Descending)
    $masked = $log.Tail + $Text
    foreach ($mask in $masks) { $masked = $masked.Replace($mask, '***', [StringComparison]::Ordinal) }
    $keep = 0
    if ($masks.Count -gt 0) { $keep = $masks[0].Length - 1 }
    if ($EndOfStream -or $masked.Length -le $keep) {
        if ($EndOfStream) { $out = $masked; $log.Tail = '' } else { $out = ''; $log.Tail = $masked }
    } else {
        $out = $masked.Substring(0, $masked.Length - $keep)
        $log.Tail = $masked.Substring($masked.Length - $keep)
    }
    if ($out.Length -eq 0) { return }
    if ($Stream -ceq 'err') {
        $tail = [string]$worker.ErrTail + $out
        if ($tail.Length -gt 2000) { $tail = $tail.Substring($tail.Length - 2000) }
        $worker.ErrTail = $tail
    }
    if ($log.Stopped -or -not $worker.Folder) { return }
    $limit = [long](Get-WorkloadProtocolLimit).MaxWorkerLogChars
    $write = $out
    if ($log.Written + $out.Length -gt $limit) {
        $write = $out.Substring(0, [int]([Math]::Max(0, $limit - $log.Written))) + ("`n# truncated: MaxWorkerLogChars={0}`n" -f $limit)
        $log.Stopped = $true
    }
    $log.Written = $log.Written + $out.Length
    try {
        [IO.File]::AppendAllText((Join-Path $worker.Folder ('worker.{0}.log' -f $Stream)), $write, [Text.UTF8Encoding]::new($false))
    } catch {
        Write-Verbose "worker.$Stream.log was not written: $($_.Exception.Message)"
    }
}

function Get-WorkloadMcpWorkerExitDetail {
    <#
    .SYNOPSIS
        The detail of workload_worker_start_failed: the exit code, or unknown, and the end of stderr.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Channel)
    $exit = 'exit unknown'
    try {
        if ($null -ne $Channel.Process -and $Channel.Process.HasExited) { $exit = 'exit ' + $Channel.Process.ExitCode }
    } catch {
        Write-Verbose "The exit code was not read: $($_.Exception.Message)"
    }
    return ($exit + ' ' + [string]$Channel.ErrTail)
}

function Invoke-WorkloadMcpWorkerExit {
    <#
    .SYNOPSIS
        Handles the end of a worker: settles what waited for it, cleans up and frees the state.
    .DESCRIPTION
        The one place that answers end calls. Order matters: the operation in
        flight becomes uncertain, queued operations end not dispatched, the
        queue is emptied, the end calls are answered with what the worker
        released, and every other call that waited is answered by kind. A
        worker that was closing answers nothing: its queue was settled when
        it began to close and a call in flight to it keeps its deadline.
        Reason is the word of the exit event in server.log; nothing branches
        on it. A second call for the same exit changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][ValidateSet('exited', 'lost', 'killed', 'superseded')][string]$Reason
    )
    $worker = $State.Worker
    if ($null -eq $worker) { return }
    Add-WorkloadMcpWorkerLog -State $State -Stream 'out' -EndOfStream
    Add-WorkloadMcpWorkerLog -State $State -Stream 'err' -EndOfStream
    $session = $State.Session
    $exited = $false
    try {
        if ($null -ne $worker.Process) { $exited = $worker.Process.HasExited }
        elseif ($null -ne $worker.ExitTask) { $exited = $worker.ExitTask.IsCompleted }
    } catch {
        Write-Verbose "The worker's exit was not read: $($_.Exception.Message)"
    }
    $detail = Get-WorkloadMcpWorkerExitDetail -Channel $worker
    Write-WorkloadMcpServerLog -State $State -EventName 'worker-exit' -Data ([ordered]@{ reason = $Reason; exited = $exited })
    if (-not $worker.Closing) {
        $inFlight = $State.InFlight
        if ($null -ne $inFlight -and $inFlight.Entry.Route -ceq 'operation') {
            $record = $State.Operations[$inFlight.Entry.OperationId]
            if ($null -ne $record -and $record.State -cin @('running', 'canceling')) {
                $lost = Get-WorkloadMcpErrorResult -Code 'workload_worker_lost' -Key 'runner.workload_worker_lost'
                $result = [ordered]@{ ok = $false; state = 'uncertain'; operationId = $record.Id; error = $lost['error']; effect = 'uncertain'; progress = $record.Progress }
                Complete-WorkloadMcpOperation -State $State -Record $record -Result $result -FinalState 'uncertain'
            }
        }
        foreach ($entry in @($State.Queue.ToArray())) {
            if ($entry.Route -ceq 'operation') {
                $record = $State.Operations[$entry.OperationId]
                if ($null -ne $record -and $record.State -cin @('running', 'canceling')) { Complete-WorkloadMcpUndispatched -State $State -Record $record }
            }
        }
        $State.Queue.Clear()
        foreach ($call in @($State.Calls.ToArray())) {
            if ($call.Route -cne 'end') { continue }
            $answer = [ordered]@{ ok = $true; ended = $true; forced = ($session.Forced -eq $true) }
            if ($answer.forced) { $answer['killConfirmed'] = $exited }
            $reply = $session.EndReply
            $answer['released'] = $(if ($reply -is [System.Collections.IDictionary] -and $reply['released'] -is [bool]) { $reply['released'] } else { $false })
            $answer['cycleFolder'] = $(if ($reply -is [System.Collections.IDictionary] -and $null -ne $reply['cycleFolder']) { [string]$reply['cycleFolder'] } else { '' })
            if ($null -ne $session.EndOperationId) {
                $record = $State.Operations[$session.EndOperationId]
                $answer['operation'] = [ordered]@{ id = $session.EndOperationId; state = $(if ($null -ne $record) { $record.State } else { $null }) }
            }
            $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result $answer
        }
        foreach ($call in @($State.Calls.ToArray())) {
            if ($call.Route -ceq 'start' -or $null -eq $worker.Hello) {
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_worker_start_failed' -Key 'runner.workload_worker_start_failed' -Arguments @{ detail = $detail })
            } elseif ($session.Phase -ceq 'ending') {
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_no_session' -Key 'runner.workload_no_session')
            } else {
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_worker_lost' -Key 'runner.workload_worker_lost')
            }
        }
        $session.EndRequestId = $null
        $session.EndReply = $null
        $session.EndOperationId = $null
        $session.Forced = $false
    }
    try {
        $null = Invoke-WorkloadOwnedProcessCleanup -SessionDir $worker.Folder
    } catch {
        Write-Verbose "The owned processes were not cleaned up: $($_.Exception.Message)"
    }
    try {
        $null = & $worker.Dispose
    } catch {
        Write-Verbose "The worker channel was not disposed: $($_.Exception.Message)"
    }
    if ($null -ne $worker.SessionDocument) {
        $worker.SessionDocument['state'] = 'ended'
        $worker.SessionDocument['endedUtc'] = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $worker.SessionDocument['endReason'] = $(if ($session.EndReason) { [string]$session.EndReason } else { $Reason })
        Write-WorkloadMcpSessionFile -Channel $worker
    }
    if (-not $worker.Closing) {
        $session.Phase = $(if ($session.Attached -eq $true) { 'ended' } else { 'none' })
        $session.EndReason = $null
    }
    $session.StartDeadline = $null
    $session.EndDeadline = $null
    $session.KillDeadline = $null
    $State.Queue.Clear()
    $State.InFlight = $null
    $State.Worker = $null
}

function Invoke-WorkloadMcpTimer {
    <#
    .SYNOPSIS
        Acts on every limit that has passed; returns whether it acted.
    .DESCRIPTION
        A limit is read only while its state holds, and a limit that is $null
        has not passed. A call answers workload_still_waiting at its deadline
        and not one tick earlier. The deadline of an end call is never acted
        on: the grace period and the kill bound its wait.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][hashtable]$State)
    $acted = $false
    $now = Get-WorkloadMcpNow -State $State
    foreach ($call in @($State.Calls.ToArray())) {
        if ($call.Route -cin @('end', 'file') -or $now -lt [long]$call.Deadline) { continue }
        if ((Find-WorkloadMcpItemIndex -List $State.Calls -Item $call) -lt 0) { continue }
        $acted = $true
        switch -CaseSensitive ($call.Route) {
            'start' {
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result ([ordered]@{
                        ok = $true; state = 'starting'; noteCode = 'workload_session_starting'
                        note = (Format-YurunaOperatorMessage -Key 'runner.workload_session_starting')
                    })
            }
            'operation' {
                $record = $State.Operations[[string]$call.OperationId]
                $operationState = $(if ($null -ne $record) { $record.State } else { 'running' })
                $created = $(if ($null -ne $record) { [long]$record.CreatedTicks } else { $now })
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result ([ordered]@{
                        ok = $true; state = $operationState; operationId = $call.OperationId; noteCode = 'workload_still_waiting'
                        note = (Format-YurunaOperatorMessage -Key 'runner.workload_still_waiting' -Arguments @{ operationId = [string]$call.OperationId })
                        progress = $(if ($null -ne $record) { $record.Progress } else { $null })
                        elapsedSeconds = [long][Math]::Floor(($now - $created) / 1000)
                    })
            }
            default {
                foreach ($entry in @($State.Queue.ToArray())) {
                    if ([object]::ReferenceEquals($entry.Call, $call)) { $null = Clear-WorkloadMcpListItem -List $State.Queue -Item $entry }
                }
                if ($null -ne $State.InFlight -and [object]::ReferenceEquals($State.InFlight.Entry.Call, $call)) { $State.InFlight.Abandoned = $true }
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_call_timeout' -Key 'runner.workload_call_timeout' -Arguments @{ seconds = [long]($State.MaxCallMs / 1000) })
            }
        }
    }
    $worker = $State.Worker
    if ($null -ne $worker -and $null -eq $worker.Hello -and (Test-WorkloadMcpLimitPassed -State $State -Limit $worker.HelloDeadline)) {
        Invoke-WorkloadMcpWorkerLost -State $State -Detail 'hello-timeout'
        return $true
    }
    $session = $State.Session
    if ($session.Phase -ceq 'starting' -and (Test-WorkloadMcpLimitPassed -State $State -Limit $session.StartDeadline)) {
        $session.StartDeadline = $null
        $session.Phase = 'none'
        $detail = $(if ($null -ne $worker) { Get-WorkloadMcpWorkerExitDetail -Channel $worker } else { 'exit unknown ' })
        foreach ($call in @($State.Calls.ToArray())) {
            if ($call.Route -ceq 'start') {
                $null = Send-WorkloadMcpToolResult -State $State -Call $call -Result (Get-WorkloadMcpErrorResult -Code 'workload_worker_start_failed' -Key 'runner.workload_worker_start_failed' -Arguments @{ detail = $detail })
            }
        }
        Close-WorkloadMcpWorker -State $State
        return $true
    }
    if ($session.Phase -ceq 'ending') {
        if (Test-WorkloadMcpLimitPassed -State $State -Limit $session.EndDeadline) {
            $session.EndDeadline = $null
            if ($null -ne $worker -and $null -eq $worker.ExitSeen) {
                Write-WorkloadMcpServerLog -State $State -EventName 'worker-kill' -Data ([ordered]@{ reason = 'grace' })
                $null = & $worker.Kill
                $session.Forced = $true
                $session.KillDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:KillConfirmSeconds * 1000
            }
            return $true
        }
        if (Test-WorkloadMcpLimitPassed -State $State -Limit $session.KillDeadline) {
            $session.KillDeadline = $null
            Invoke-WorkloadMcpWorkerExit -State $State -Reason 'killed'
            return $true
        }
    }
    if ($null -ne $worker -and $worker.Closing) {
        if (Test-WorkloadMcpLimitPassed -State $State -Limit $worker.CloseDeadline) {
            $worker.CloseDeadline = $null
            Write-WorkloadMcpServerLog -State $State -EventName 'worker-kill' -Data ([ordered]@{ reason = 'close' })
            $null = & $worker.Kill
            $worker.KillDeadline = (Get-WorkloadMcpNow -State $State) + [long]$script:KillConfirmSeconds * 1000
            return $true
        }
        if (Test-WorkloadMcpLimitPassed -State $State -Limit $worker.KillDeadline) {
            $worker.KillDeadline = $null
            Invoke-WorkloadMcpWorkerExit -State $State -Reason 'killed'
            return $true
        }
    }
    return $acted
}

function Get-WorkloadMcpWaitInterval {
    <#
    .SYNOPSIS
        Milliseconds to the nearest limit the loop must wake for, between 0 and 1000.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][hashtable]$State)
    $limits = [Collections.Generic.List[long]]::new()
    foreach ($call in $State.Calls) {
        if ($call.Route -cnotin @('end', 'file')) { $limits.Add([long]$call.Deadline) }
    }
    $session = $State.Session
    if ($session.Phase -ceq 'starting' -and $null -ne $session.StartDeadline) { $limits.Add([long]$session.StartDeadline) }
    if ($session.Phase -ceq 'ending') {
        if ($null -ne $session.EndDeadline) { $limits.Add([long]$session.EndDeadline) }
        if ($null -ne $session.KillDeadline) { $limits.Add([long]$session.KillDeadline) }
    }
    $worker = $State.Worker
    if ($null -ne $worker) {
        if ($null -eq $worker.Hello -and $null -ne $worker.HelloDeadline) { $limits.Add([long]$worker.HelloDeadline) }
        if ($worker.Closing) {
            if ($null -ne $worker.CloseDeadline) { $limits.Add([long]$worker.CloseDeadline) }
            if ($null -ne $worker.KillDeadline) { $limits.Add([long]$worker.KillDeadline) }
        }
        if ($null -ne $worker.ExitSeen) { $limits.Add([long]$worker.ExitSeen + [long]$script:DrainSeconds * 1000) }
        if ($null -ne $worker.WriteTask -and $null -ne $worker.WriteDeadline) { $limits.Add([long]$worker.WriteDeadline) }
    }
    $now = Get-WorkloadMcpNow -State $State
    $wait = [long]1000
    foreach ($limit in $limits) { $wait = [Math]::Min($wait, $limit - $now) }
    return [int][Math]::Max([long]0, $wait)
}

function Invoke-WorkloadMcpLoop {
    <#
    .SYNOPSIS
        Serves the client until its input ends and the worker is gone.
    .DESCRIPTION
        Every pass takes the first thing that is ready: a failed write, a
        worker frame, the worker's exit, its stdout or stderr, a limit, a
        client line. Worker frames come before client lines, so an answer
        already received is written before the next request is read. The
        exit is handled once the reply and diagnostic streams ended or the
        drain time passed, since a process the worker started can hold those
        streams open after the worker exited. -Until returns after the pass
        on which it is true; the pending client read stays in the state, so a
        later call goes on with it.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][System.IO.TextReader]$Reader,
        [Parameter(Mandatory)][System.IO.TextWriter]$Writer,
        [hashtable]$State,
        [scriptblock]$Until
    )
    if ($null -eq $State) {
        $parameter = $script:WorkloadMcpParameter
        $root = $parameter.SessionRoot
        if (-not $root) { $root = Join-Path (Initialize-YurunaLogDir) 'workload-mcp' }
        $State = Initialize-WorkloadMcpState -Writer $Writer -MaxCallSeconds $parameter.MaxCallSeconds -SessionRoot $root `
            -RepoRoot $parameter.RepoRoot -WorkerScript $parameter.WorkerScript -ConfigPath $parameter.ConfigPath
    }
    while (-not $State.Finished) {
        if ($null -ne $Until -and (& $Until)) { return }
        if ($null -eq $State.ClientRead -and -not $State.ClientEnded) { $State.ClientRead = $Reader.ReadLineAsync() }
        $worker = $State.Worker
        if ($null -ne $worker -and -not (& $worker.Pump)) {
            Invoke-WorkloadMcpWorkerLost -State $State -Detail 'write'
            continue
        }
        if ($null -ne $worker -and $null -ne $worker.ReadTask -and $worker.ReadTask.IsCompleted) {
            $task = $worker.ReadTask
            $line = $(if ($task.IsCompletedSuccessfully) { $task.Result } else { $null })
            if ($null -eq $line) {
                $worker.ReadTask = $null
            } else {
                Invoke-WorkloadMcpWorkerFrame -State $State -Line $line
                if ([object]::ReferenceEquals($State.Worker, $worker)) { $worker.ReadTask = & $worker.ReadNext }
            }
            continue
        }
        if ($null -ne $worker) {
            if ($null -eq $worker.ExitSeen) {
                if ($null -ne $worker.ExitTask -and $worker.ExitTask.IsCompleted) {
                    $worker.ExitSeen = Get-WorkloadMcpNow -State $State
                    continue
                }
            } elseif (($null -eq $worker.ReadTask -and $null -eq $worker.OutTask -and $null -eq $worker.ErrTask) -or
                (Test-WorkloadMcpLimitPassed -State $State -Limit ([long]$worker.ExitSeen + [long]$script:DrainSeconds * 1000))) {
                Invoke-WorkloadMcpWorkerExit -State $State -Reason 'exited'
                continue
            }
            $handled = $false
            foreach ($stream in @('out', 'err')) {
                $taskName = $(if ($stream -ceq 'out') { 'OutTask' } else { 'ErrTask' })
                $task = $worker[$taskName]
                if ($null -eq $task -or -not $task.IsCompleted) { continue }
                $count = $(if ($task.IsCompletedSuccessfully) { [int]$task.Result } else { 0 })
                if ($count -le 0) {
                    $worker[$taskName] = $null
                } else {
                    $buffer = $(if ($stream -ceq 'out') { $worker.OutBuffer } else { $worker.ErrBuffer })
                    Add-WorkloadMcpWorkerLog -State $State -Stream $stream -Text ([string]::new($buffer, 0, $count))
                    $worker[$taskName] = $(if ($stream -ceq 'out') { & $worker.ReadOut } else { & $worker.ReadErr })
                }
                $handled = $true
                break
            }
            if ($handled) { continue }
        }
        if (Invoke-WorkloadMcpTimer -State $State) { continue }
        if ($null -ne $State.ClientRead -and $State.ClientRead.IsCompleted) {
            $task = $State.ClientRead
            $State.ClientRead = $null
            $line = $(if ($task.IsCompletedSuccessfully) { $task.Result } else { $null })
            if ($null -ne $line) {
                Invoke-WorkloadMcpClientLine -State $State -Line $line
            } else {
                $State.ClientEnded = $true
                $State.Calls.Clear()
                $null = Close-WorkloadMcpSession -State $State -Reason 'client-ended'
            }
            continue
        }
        if ($State.ClientEnded -and $null -eq $State.Worker) {
            $State.Finished = $true
            continue
        }
        $tasks = [Collections.Generic.List[Threading.Tasks.Task]]::new()
        if ($null -ne $State.ClientRead) { $tasks.Add($State.ClientRead) }
        if ($null -ne $worker) {
            foreach ($task in @($worker.ReadTask, $worker.OutTask, $worker.ErrTask, $worker.WriteTask)) {
                if ($null -ne $task) { $tasks.Add($task) }
            }
            if ($null -eq $worker.ExitSeen -and $null -ne $worker.ExitTask) { $tasks.Add($worker.ExitTask) }
        }
        $interval = Get-WorkloadMcpWaitInterval -State $State
        if ($tasks.Count -gt 0) {
            $null = [Threading.Tasks.Task]::WaitAny($tasks.ToArray(), $interval)
        } else {
            Start-Sleep -Milliseconds $interval
        }
    }
}

# Dot-sourced by the suites to reach the functions above without serving.
if ($env:YURUNA_WORKLOAD_MCP_SERVER_NO_RUN -eq '1') { return }

$reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.UTF8Encoding]::new($false))
$writer = [IO.StreamWriter]::new([Console]::OpenStandardOutput(), [Text.UTF8Encoding]::new($false))
$writer.NewLine = "`n"
Invoke-WorkloadMcpLoop -Reader $reader -Writer $writer 3>$null 4>$null 5>$null 6>$null | Out-Null
