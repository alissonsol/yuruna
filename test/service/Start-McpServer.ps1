<#PSScriptInfo
.VERSION 2026.09.01
.GUID 42483736-4c90-4f3e-b602-9b7c1511b13e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna mcp stdio json-rpc automation
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
    Serve the core framework's entry points over MCP on stdio.
.DESCRIPTION
    The five Go daemons mount MCP on an HTTP port because a pool reaches them
    over the network. The core framework is different: it is a set of scripts an
    operator runs on their own machine, so its MCP server runs FOREGROUND on
    stdin/stdout and is started by whatever client wants it.

    That transport is also the whole trust model. This server has no listener,
    no token and no gate: a process reading one operator's stdin was started by
    that operator, and it can do exactly what they can already do by typing the
    same command. Adding a credential here would protect nothing and imply a
    boundary that does not exist. It is why this file must never grow a
    -Listen parameter -- see "Why stdio, and only stdio" below.

    Each tool shells out to the entry point rather than dot-sourcing it. That is
    deliberate: these scripts set preferences, write transcripts and call exit,
    and running them in-process would let one tool's `exit` end the server and
    one tool's $ErrorActionPreference outlive it.

    THE RESULT SEMANTICS ARE NOT UNIFORM, and pretending they are is how a
    caller learns the wrong thing:

      - Test-Runtime has no exit statement at all. Its verdict is a boolean
        emitted as the LAST pipeline object, so $LASTEXITCODE says nothing.
      - Get-SystemDiagnostic always exits 0. Its problems live in the prose
        summary and in class-tagged JSON records, so exit code 0 means "the
        report was produced", never "nothing is wrong".
      - Check-DependencyVersion is the one native JSON emitter (-AsJson), so
        its output is passed through rather than re-wrapped.
      - Set-Component, Set-Resource, Set-Workload, Invoke-Clear and the two
        Test-* gates exit non-zero on failure and write a transcript; the
        transcript pointer is the useful half of a failure, so it is returned.
      - ANY of them can also sign off with a bare boolean and exit 0.
        Test-Configuration takes an early `return $false` when the root set
        will not resolve, and at top level that EMITS False while exiting 0 --
        so a trailing False is read as the verdict whatever the exit code
        says. Trusting the code there reports a gate that never ran as a pass.
      - Set-HostAlias has NEITHER an exit statement nor a transcript. A thrown
        error is the only failure signal it gives, so that is what is used.

.PARAMETER RepoRoot
    Repository root. Defaults to the enlistment this script lives in.
.EXAMPLE
    pwsh -NoProfile -File test/service/Start-McpServer.ps1

    Serves MCP on stdio. Point a client at that command; there is nothing to
    connect to and nothing to authenticate.
#>

[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$script:RepoRoot      = $RepoRoot
$script:AutomationDir = Join-Path $RepoRoot 'automation'
$script:ProtocolVersion = '2025-06-18'

# --- REGION: https://yuruna.link/extensions-api#mcp-endpoints

<#
.SYNOPSIS
    The version this server reports, read from the enlistment's VERSION file.
.OUTPUTS
    [string]
#>
function Get-McpServerVersion {
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

<#
.SYNOPSIS
    Runs one automation entry point as a child pwsh and returns what it did.
.DESCRIPTION
    A child process, not a dot-source: these scripts call exit and set
    preferences, either of which would reach the server if they shared its
    process.

    Both streams are captured. stdout is the answer; stderr is kept because a
    failure's cause is routinely only there, and a caller shown an exit code
    with no message has to go and re-run the command by hand to learn anything.
.OUTPUTS
    [hashtable] ExitCode, Stdout, Stderr.
#>
function Invoke-McpEntryPoint {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$ScriptArgument = @()
    )
    $path = Join-Path $script:AutomationDir $Script
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ ExitCode = 127; Stdout = ''; Stderr = "no such entry point: $path" }
    }
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $argv = @('-NoProfile', '-NonInteractive', '-File', $path) + $ScriptArgument
        $proc = Start-Process -FilePath $pwsh -ArgumentList $argv -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return @{
            ExitCode = $proc.ExitCode
            Stdout   = (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue)
            Stderr   = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
        }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    The tool table: every core entry point this server exposes.
.DESCRIPTION
    ReadOnly is a claim about the script, not a convenience. The three Test-*
    gates and the two reporters change nothing an operator could observe later;
    everything else writes configuration or deletes state.

    Destructive is narrower still: only Invoke-Clear discards something that
    calling it again cannot bring back.
.OUTPUTS
    [object[]]
#>
function Get-McpToolTable {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $noArgs  = '{"type":"object","properties":{}}'
    $cfgArgs = '{"type":"object","properties":{"configFile":{"type":"string","description":"path to a test config; the entry point default is used when absent"}}}'
    return @(
        @{ Name = 'yuruna_test_configuration'; Script = 'Test-Configuration.ps1'; ReadOnly = $true;  Schema = $cfgArgs
           Description = 'Validate the test configuration. Exits non-zero with a transcript when a check fails, and returns a bare False while exiting 0 when the root set will not resolve at all.' }
        @{ Name = 'yuruna_test_requirement';   Script = 'Test-Requirement.ps1';   ReadOnly = $true;  Schema = $cfgArgs
           Description = 'Check that this host meets the requirements a cycle needs. Exits non-zero on a failed requirement.' }
        @{ Name = 'yuruna_test_runtime';       Script = 'Test-Runtime.ps1';       ReadOnly = $true;  Schema = $cfgArgs
           Description = 'Check the runtime. The verdict is a boolean emitted as the last pipeline object; this script has no exit statement, so the exit code says nothing.' }
        @{ Name = 'yuruna_system_diagnostic';  Script = 'Get-SystemDiagnostic.ps1'; ReadOnly = $true; Schema = $noArgs
           Description = 'Produce the host diagnostic report. ALWAYS exits 0: exit code 0 means the report was produced, never that nothing is wrong. Read the problems in the output.' }
        @{ Name = 'yuruna_dependency_version'; Script = 'Check-DependencyVersion.ps1'; ReadOnly = $true; Schema = $noArgs
           Description = 'Report the pinned dependency versions and what is installed. Emits JSON natively.' }
        @{ Name = 'yuruna_set_component';      Script = 'Set-Component.ps1';      ReadOnly = $false; Schema = $cfgArgs
           Description = 'Apply the component definitions. Writes configuration; exits non-zero with a transcript on failure.' }
        @{ Name = 'yuruna_set_resource';       Script = 'Set-Resource.ps1';       ReadOnly = $false; Schema = $cfgArgs
           Description = 'Apply the resource definitions. Writes configuration; exits non-zero with a transcript on failure.' }
        @{ Name = 'yuruna_set_workload';       Script = 'Set-Workload.ps1';       ReadOnly = $false; Schema = $cfgArgs
           Description = 'Apply the workload definitions. Writes configuration; exits non-zero with a transcript on failure.' }
        @{ Name = 'yuruna_set_host_alias';     Script = 'Set-HostAlias.ps1';      ReadOnly = $false; Schema = $noArgs
           Description = 'Set the host alias. Unlike its siblings it has no exit statement and writes no transcript, so a thrown error is the only failure signal.' }
        @{ Name = 'yuruna_invoke_clear';       Script = 'Invoke-Clear.ps1';       ReadOnly = $false; Destructive = $true; Schema = $cfgArgs
           Description = 'Clear generated state. DESTRUCTIVE: what it removes is not recoverable by calling it again.' }
    )
}

<#
.SYNOPSIS
    Turns an entry point's run into the result a tool reports.
.DESCRIPTION
    One place decides what "it worked" means, so the three different answers the
    entry points give cannot each grow their own reader.
.OUTPUTS
    [hashtable]
#>
function ConvertTo-McpToolResult {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Tool,
        [Parameter(Mandatory)][hashtable]$Run
    )
    $stdout = "$($Run.Stdout)"
    $stderr = "$($Run.Stderr)"

    # A bare boolean as the LAST thing on stdout is a verdict, whatever the exit
    # code says. Three of these scripts can take an early `return $false` at top
    # level -- Test-Configuration does it when the root set will not resolve --
    # and at top level that EMITS False and exits 0. Reading such a run by exit
    # code alone reports a validation that never happened as a pass.
    $lines   = @($stdout -split "`r?`n" | Where-Object { $_.Trim() })
    $verdict = if ($lines.Count) { $lines[-1].Trim() } else { '' }
    $boolVerdict = $verdict -match '^(True|False)$'

    switch ($Tool.Name) {
        'yuruna_test_runtime' {
            # No exit statement anywhere in the script: the verdict is the last
            # non-empty line it printed. Reading $LASTEXITCODE here would report
            # success for every run, including a failing one.
            $ok = $verdict -match '^(True|true)$'
            return @{ ok = $ok; verdict = $verdict; output = $stdout; stderr = $stderr
                      note = 'Test-Runtime has no exit statement; the verdict is its last pipeline object.' }
        }
        'yuruna_system_diagnostic' {
            # Always exits 0. Saying "ok" off the exit code would report a host
            # with problems as healthy.
            return @{ ok = $true; output = $stdout; stderr = $stderr
                      note = 'Get-SystemDiagnostic always exits 0; problems are in the report, not the exit code.' }
        }
        'yuruna_dependency_version' {
            # The one native JSON emitter: passed through rather than re-wrapped,
            # so a caller parses the same bytes the script produced.
            $parsed = $null
            try { $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
            if ($null -ne $parsed) {
                return @{ ok = ($Run.ExitCode -eq 0); json = $parsed; stderr = $stderr }
            }
            return @{ ok = ($Run.ExitCode -eq 0); output = $stdout; stderr = $stderr
                      note = 'expected JSON from -AsJson but the output did not parse' }
        }
        'yuruna_set_host_alias' {
            # Neither an exit statement nor a transcript. A thrown error is all
            # there is, and it lands on stderr.
            $ok = ($Run.ExitCode -eq 0) -and -not $stderr.Trim()
            return @{ ok = $ok; output = $stdout; stderr = $stderr
                      note = 'Set-HostAlias writes no transcript and has no exit statement; a thrown error is the failure signal.' }
        }
    }

    # The ordinary shape: the exit code decides, UNLESS the script signed off
    # with a bare boolean -- an early `return $false` at top level emits that
    # and exits 0, and trusting the code there reports a gate that never ran as
    # a pass.
    $ok = ($Run.ExitCode -eq 0)
    $result = @{ ok = $ok; exitCode = $Run.ExitCode; output = $stdout; stderr = $stderr }
    if ($boolVerdict -and $verdict -match '^False$') {
        $result['ok'] = $false
        $result['verdict'] = $verdict
        $result['note'] = 'the script returned False at top level and exited 0; the verdict is the output, not the exit code'
    }
    if ($Run.ExitCode -ne 0) {
        $transcript = @($stdout -split "`r?`n" | Where-Object { $_ -match '(?i)transcript' })
        if ($transcript.Count) { $result['transcript'] = $transcript[-1].Trim() }
    }
    return $result
}

<#
.SYNOPSIS
    Answers one JSON-RPC request. Returns $null for a notification.
.OUTPUTS
    [hashtable] or $null
#>
function Invoke-McpMethod {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object]$Request)

    $id = $Request.id
    # A notification has no id and takes no response at all -- not an empty one.
    if ($null -eq $id) { return $null }

    switch ($Request.method) {
        'initialize' {
            return @{ jsonrpc = '2.0'; id = $id; result = @{
                protocolVersion = $script:ProtocolVersion
                capabilities    = @{ tools = @{ listChanged = $false } }
                serverInfo      = @{ name = 'yuruna-core'; version = (Get-McpServerVersion) }
            } }
        }
        'ping' { return @{ jsonrpc = '2.0'; id = $id; result = @{} } }
        'tools/list' {
            $tools = @(Get-McpToolTable | Sort-Object { $_.Name } | ForEach-Object {
                @{
                    name        = $_.Name
                    description = $_.Description
                    inputSchema = ($_.Schema | ConvertFrom-Json)
                    annotations = @{
                        readOnlyHint    = [bool]$_.ReadOnly
                        destructiveHint = [bool]$_.Destructive
                        idempotentHint  = $false
                    }
                }
            })
            return @{ jsonrpc = '2.0'; id = $id; result = @{ tools = $tools } }
        }
        'tools/call' {
            $name = $Request.params.name
            $tool = @(Get-McpToolTable | Where-Object { $_.Name -eq $name }) | Select-Object -First 1
            if (-not $tool) {
                return @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32602; message = "unknown tool $name" } }
            }
            $scriptArgs = @()
            $configFile = $Request.params.arguments.configFile
            if ($configFile) { $scriptArgs = @('-ConfigFile', [string]$configFile) }
            if ($tool.Name -eq 'yuruna_dependency_version') { $scriptArgs += '-AsJson' }

            $run    = Invoke-McpEntryPoint -Script $tool.Script -ScriptArgument $scriptArgs
            $result = ConvertTo-McpToolResult -Tool $tool -Run $run
            return @{ jsonrpc = '2.0'; id = $id; result = @{
                isError = -not [bool]$result.ok
                content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 12) })
            } }
        }
    }
    return @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = "unknown method $($Request.method)" } }
}

<#
.SYNOPSIS
    Reads newline-delimited JSON-RPC from a reader and writes replies to stdout.
.DESCRIPTION
    Separated from the process wiring so the golden tests drive the same loop
    the operator does, instead of a restatement of it.

    Nothing but a JSON-RPC frame may reach stdout: the client parses that stream
    and a stray Write-Host would corrupt the session. Diagnostics go to stderr.
#>
function Invoke-McpLoop {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][System.IO.TextReader]$Reader,
        [Parameter(Mandatory)][System.IO.TextWriter]$Writer
    )
    while ($null -ne ($line = $Reader.ReadLine())) {
        if (-not $line.Trim()) { continue }
        $request = $null
        try {
            $request = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $Writer.WriteLine((@{ jsonrpc = '2.0'; error = @{ code = -32700; message = 'request is not JSON' } } | ConvertTo-Json -Compress -Depth 6))
            $Writer.Flush()
            continue
        }
        $response = $null
        try {
            $response = Invoke-McpMethod -Request $request
        } catch {
            $response = @{ jsonrpc = '2.0'; id = $request.id; error = @{ code = -32603; message = "$($_.Exception.Message)" } }
        }
        if ($null -ne $response) {
            $Writer.WriteLine(($response | ConvertTo-Json -Compress -Depth 20))
            $Writer.Flush()
        }
    }
}

# Dot-sourced by the suite to reach the functions above without serving.
if ($env:YURUNA_MCP_SERVER_NO_RUN -eq '1') { return }

Invoke-McpLoop -Reader ([Console]::In) -Writer ([Console]::Out)
