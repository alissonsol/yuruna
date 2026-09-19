<#PSScriptInfo
.VERSION 2026.09.18
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$script:RepoRoot      = $RepoRoot
$script:AutomationDir = Join-Path $RepoRoot 'automation'
$script:ProtocolVersion = '2025-06-18'

# --- REGION: https://yuruna.link/42fffc2c-000f
function Get-McpServerVersion {
    <#
    .SYNOPSIS
        The version this server reports, read from the enlistment's VERSION file.
    .OUTPUTS
        [string]
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

function Get-UnboundParameterName {
    <#
    .SYNOPSIS
        The named arguments a script cannot bind, out of the ones about to be passed.
    .DESCRIPTION
        Asks PowerShell's own binder rather than reimplementing it. ResolveParameter
        applies the real rules -- an exact name, an unambiguous abbreviation, a
        declared parameter winning over a common one of the same prefix, and the
        common set existing only for a script that declares [CmdletBinding()] -- and
        throws when a name binds to nothing or to more than one thing.

        Reimplementing those rules is what this function used to do, and it got them
        wrong in both directions at once: it invented ambiguity between a declared
        name and a common one, and it granted common parameters to the eight entry
        points that declare no [CmdletBinding()] and therefore have none.

        Reading the script rather than trying the call is the point: a script
        without [CmdletBinding()] reports nothing at all for an unknown name. It
        absorbs it into $args and runs against defaults, so there is no failure to
        observe afterwards.
    .OUTPUTS
        [string[]] the argument names that the script cannot bind.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Argument = @()
    )
    $unbound = [Collections.Generic.List[string]]::new()
    if (-not $Argument -or $Argument.Count -eq 0) { return $unbound.ToArray() }

    $command = $null
    try { $command = Get-Command -Name $ScriptPath -CommandType ExternalScript -ErrorAction Stop }
    catch { $command = $null }

    foreach ($token in $Argument) {
        $name = "$token"
        if (-not $name.StartsWith('-')) { continue }
        $name = $name.TrimStart('-')
        # -Name:Value is one token carrying both.
        if ($name -match '^(?<n>[^:]+):') { $name = $Matches['n'] }
        if (-not $name) { continue }
        # A script that will not even load cannot be shown to accept anything,
        # and passing an argument it might silently drop is the failure this
        # guards. Refusing is the safe answer.
        if (-not $command) { $unbound.Add($name); continue }
        try { $null = $command.ResolveParameter($name) }
        catch { $unbound.Add($name) }
    }
    return $unbound.ToArray()
}

function Invoke-McpEntryPoint {
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
        The transcript is named before the run rather than looked for afterwards.
        An entry point that writes one records it where YURUNA_TRANSCRIPT_PATH says,
        so the pointer this returns is something the server decided, not something
        it recognized in the child's output. What the child printed stays what a
        person reads.
    .OUTPUTS
        [hashtable] ExitCode, Stdout, Stderr, TranscriptPath.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Script,
        [string[]]$ScriptArgument = @()
    )
    $path = Join-Path $script:AutomationDir $Script
    if (-not (Test-Path -LiteralPath $path)) {
        return @{ ExitCode = 127; Stdout = ''; Stderr = (Format-YurunaOperatorMessage -Key 'runner.mcp_missing_entry' -Arguments @{ path = $path }); TranscriptPath = '' }
    }
    # Most of these scripts have no [CmdletBinding()], and a script without it
    # absorbs an unknown -Name into $args and runs anyway. So an argument the
    # target does not declare is not refused by PowerShell -- it is silently
    # dropped, and the run proceeds against defaults while the caller believes
    # its input was honored. Refusing here is the only place that reads as a
    # failure. The check is over the declared parameter names, not over any
    # message, so it holds on a host in any language.
    $undeclared = @(Get-UnboundParameterName -ScriptPath $path -Argument $ScriptArgument)
    if ($undeclared.Count) {
        return @{ ExitCode = 126; Stdout = ''; TranscriptPath = ''; Refused = $true
            Stderr = (Format-YurunaOperatorMessage -Key 'runner.mcp_unbound_parameter' -Arguments @{ script = $Script; parameters = ($undeclared -join ', ') }) }
    }
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    # Named per run: two tool calls in flight must not share one record, and the
    # server has to be able to say which call a transcript belongs to.
    $transcriptFile = Join-Path ([IO.Path]::GetTempPath()) (
        'yuruna-mcp-' + [Guid]::NewGuid().ToString('n') + '.transcript.txt')
    $priorTranscript = $env:YURUNA_TRANSCRIPT_PATH
    try {
        $pwsh = (Get-Process -Id $PID).Path
        if (-not $pwsh) { $pwsh = 'pwsh' }
        $argv = @('-NoProfile', '-NonInteractive', '-File', $path) + $ScriptArgument
        # Start-Process hands the child this process's environment, so the name
        # travels without changing any entry point's argument vector -- and an
        # entry point that writes no transcript simply ignores it.
        $env:YURUNA_TRANSCRIPT_PATH = $transcriptFile
        $proc = Start-Process -FilePath $pwsh -ArgumentList $argv -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Kept, and reported, only for a failed run that actually wrote there.
        # A path to a file that does not exist is worse than no pointer -- it
        # reads as a transcript the caller failed to open -- and a successful
        # run's record is one nothing will ever ask for, so keeping it would
        # leave a file behind on every call.
        $written = ''
        if ($proc.ExitCode -ne 0 -and
            (Test-Path -LiteralPath $transcriptFile -PathType Leaf) -and
            (Get-Item -LiteralPath $transcriptFile).Length -gt 0) {
            $written = $transcriptFile
        }
        return @{
            ExitCode       = $proc.ExitCode
            Stdout         = (Get-Content -Raw -LiteralPath $outFile -ErrorAction SilentlyContinue)
            Stderr         = (Get-Content -Raw -LiteralPath $errFile -ErrorAction SilentlyContinue)
            TranscriptPath = $written
        }
    } finally {
        $env:YURUNA_TRANSCRIPT_PATH = $priorTranscript
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        # A kept transcript is deliberately left behind: the pointer is the
        # useful half of a failure, and a caller reads it after this returns.
        # Everything else goes, so a long-lived server does not fill the
        # temporary directory one call at a time.
        if (-not $written) {
            Remove-Item -LiteralPath $transcriptFile -Force -ErrorAction SilentlyContinue
        }
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
    # No tool takes an argument. The entry points resolve their own scope from
    # the root set, and none of them declares a config-file parameter -- an
    # input advertised here that no script accepts is worse than none, because
    # eight of the ten have no [CmdletBinding()] and would absorb it into $args
    # and run against the default while the caller believed otherwise.
    $noArgs = '{"type":"object","properties":{}}'
    return @(
        @{ Name = 'yuruna_test_configuration'; Script = 'Test-Configuration.ps1'; ReadOnly = $true;  Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_test_configuration') }
        @{ Name = 'yuruna_test_requirement';   Script = 'Test-Requirement.ps1';   ReadOnly = $true;  Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_test_requirement') }
        @{ Name = 'yuruna_test_runtime';       Script = 'Test-Runtime.ps1';       ReadOnly = $true;  Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_test_runtime') }
        @{ Name = 'yuruna_system_diagnostic';  Script = 'Get-SystemDiagnostic.ps1'; ReadOnly = $true; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_system_diagnostic') }
        @{ Name = 'yuruna_dependency_version'; Script = 'Check-DependencyVersion.ps1'; ReadOnly = $true; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_dependency_version') }
        @{ Name = 'yuruna_set_component';      Script = 'Set-Component.ps1';      ReadOnly = $false; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_set_component') }
        @{ Name = 'yuruna_set_resource';       Script = 'Set-Resource.ps1';       ReadOnly = $false; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_set_resource') }
        @{ Name = 'yuruna_set_workload';       Script = 'Set-Workload.ps1';       ReadOnly = $false; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_set_workload') }
        @{ Name = 'yuruna_set_host_alias';     Script = 'Set-HostAlias.ps1';      ReadOnly = $false; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_set_host_alias') }
        @{ Name = 'yuruna_invoke_clear';       Script = 'Invoke-Clear.ps1';       ReadOnly = $false; Destructive = $true; Schema = $noArgs
           Description = (Format-YurunaOperatorMessage -Key 'runner.mcp_yuruna_invoke_clear') }
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

    # Answered before the per-tool arms. Those arms describe how each script
    # reports ITS OWN outcome, and one of them is "always ok, the problems are in
    # the report" -- correct for a run that happened, and a false pass for one
    # that was refused before it started.
    if ($Run.Refused) {
        return @{ ok = $false; exitCode = $Run.ExitCode; output = $stdout; stderr = $stderr
                  note = (Format-YurunaOperatorMessage -Key 'runner.mcp_refused'); noteCode = 'mcp_refused' }
    }

    switch ($Tool.Name) {
        'yuruna_test_runtime' {
            # No exit statement anywhere in the script: the verdict is the last
            # non-empty line it printed. Reading $LASTEXITCODE here would report
            # success for every run, including a failing one.
            $ok = $verdict -match '^(True|true)$'
            return @{ ok = $ok; verdict = $verdict; output = $stdout; stderr = $stderr
                      note = (Format-YurunaOperatorMessage -Key 'runner.mcp_runtime_verdict'); noteCode = 'mcp_runtime_verdict' }
        }
        'yuruna_system_diagnostic' {
            # Always exits 0. Saying "ok" off the exit code would report a host
            # with problems as healthy.
            return @{ ok = $true; output = $stdout; stderr = $stderr
                      note = (Format-YurunaOperatorMessage -Key 'runner.mcp_diagnostic_verdict'); noteCode = 'mcp_diagnostic_verdict' }
        }
        'yuruna_dependency_version' {
            # The one native JSON emitter: passed through rather than re-wrapped,
            # so a caller parses the same bytes the script produced.
            $parsed = $null
            try { $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
            if ($null -ne $parsed) {
                # Exit 1 here means a pin has drifted, which is what the report
                # is FOR. It exists so a CI gate can fail a build on drift; a
                # caller that asked for the report got it, and calling that an
                # error would make "there are updates" indistinguishable from
                # "the report could not be produced".
                return @{ ok = $true; json = $parsed; exitCode = $Run.ExitCode; stderr = $stderr
                          note = (Format-YurunaOperatorMessage -Key 'runner.mcp_dependency_drift'); noteCode = 'mcp_dependency_drift' }
            }
            return @{ ok = ($Run.ExitCode -eq 0); output = $stdout; stderr = $stderr
                      note = (Format-YurunaOperatorMessage -Key 'runner.mcp_dependency_invalid_json'); noteCode = 'mcp_dependency_invalid_json' }
        }
        'yuruna_set_host_alias' {
            # Neither an exit statement nor a transcript. A thrown error is all
            # there is, and it lands on stderr.
            $ok = ($Run.ExitCode -eq 0) -and -not $stderr.Trim()
            return @{ ok = $ok; output = $stdout; stderr = $stderr
                      note = (Format-YurunaOperatorMessage -Key 'runner.mcp_host_alias_verdict'); noteCode = 'mcp_host_alias_verdict' }
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
        $result['note'] = Format-YurunaOperatorMessage -Key 'runner.mcp_false_verdict'
        $result['noteCode'] = 'mcp_false_verdict'
    }
    # The transcript pointer is a field the run carries, never a line recognized
    # in what it printed. Matching a word in rendered output makes that word a
    # wire format: it changes with the host's language and with any rewording,
    # and both changes look like a run that simply wrote no transcript.
    if ($Run.ExitCode -ne 0 -and "$($Run.TranscriptPath)") {
        $result['transcript'] = [string]$Run.TranscriptPath
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
                return @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32602; message = (Format-YurunaOperatorMessage -Key 'runner.mcp_unknown_tool' -Arguments @{ name = $name }) } }
            }
            $scriptArgs = @()
            if ($tool.Name -eq 'yuruna_dependency_version') { $scriptArgs += '-AsJson' }

            $run    = Invoke-McpEntryPoint -Script $tool.Script -ScriptArgument $scriptArgs
            $result = ConvertTo-McpToolResult -Tool $tool -Run $run
            return @{ jsonrpc = '2.0'; id = $id; result = @{
                isError = -not [bool]$result.ok
                content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 12) })
            } }
        }
    }
    return @{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = (Format-YurunaOperatorMessage -Key 'runner.mcp_unknown_method' -Arguments @{ method = $Request.method }) } }
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
            $Writer.WriteLine((@{ jsonrpc = '2.0'; error = @{ code = -32700; message = (Format-YurunaOperatorMessage -Key 'runner.mcp_invalid_json') } } | ConvertTo-Json -Compress -Depth 6))
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
