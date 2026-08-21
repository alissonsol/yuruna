<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42b151d1-856e-48cb-8f07-88010f773bcb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test mcp stdio json-rpc pester
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
    Golden JSON-RPC exchanges for the core framework's stdio MCP server.
.DESCRIPTION
    The exchanges run through the server's OWN loop rather than a restatement of
    it, so what is covered is the thing an operator's client will drive.

    Three properties, and the third is the one that bites:

      - the protocol shape is what a client expects (initialize, tools/list,
        tools/call, notifications, unknown methods);
      - stdout carries JSON-RPC frames and nothing else, because a client parses
        that stream and one stray line corrupts the session; and
      - the RESULT SEMANTICS of the entry points are not uniform, and each odd
        one is read the way that entry point actually answers. Test-Runtime has
        no exit statement, Get-SystemDiagnostic always exits 0, and Set-HostAlias
        writes no transcript -- reading any of them by exit code alone reports
        the wrong thing.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.McpServer.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
$script:RepoRoot = Split-Path -Parent $TestRoot
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Dot-source the server without letting it serve, so the tests drive the same
# functions the stdio loop drives.
$env:YURUNA_MCP_SERVER_NO_RUN = '1'
. (Join-Path (Join-Path $TestRoot 'service') 'Start-McpServer.ps1')

<#
.SYNOPSIS
    Runs one or more JSON-RPC lines through the server's own loop.
.OUTPUTS
    [object[]] the decoded responses, in order.
#>
function Invoke-McpExchange {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string[]]$Line)
    $reader = [System.IO.StringReader]::new(($Line -join "`n"))
    $writer = [System.IO.StringWriter]::new()
    try {
        Invoke-McpLoop -Reader $reader -Writer $writer
    } finally {
        $reader.Dispose()
    }
    return @($writer.ToString() -split "`r?`n" |
        Where-Object { $_.Trim() } |
        ForEach-Object { $_ | ConvertFrom-Json })
}

}

Describe 'the core MCP server protocol' {
    It 'answers initialize with the pinned protocol and its own identity' {
        $r = @(Invoke-McpExchange -Line '{"jsonrpc":"2.0","id":1,"method":"initialize"}')
        Assert-Equal 1 $r.Count
        Assert-Equal '2025-06-18' $r[0].result.protocolVersion
        Assert-Equal 'yuruna-core' $r[0].result.serverInfo.name
        Assert-NotNull $r[0].result.capabilities.tools 'capabilities must advertise tools'
    }

    It 'lists every core entry point, sorted, with honest annotations' {
        $r = @(Invoke-McpExchange -Line '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
        $tools = @($r[0].result.tools)
        Assert-Equal 10 $tools.Count 'ten core entry points are exposed'

        $names = @($tools | ForEach-Object { $_.name })
        $sorted = @($names | Sort-Object)
        Assert-Equal ($sorted -join ',') ($names -join ',') 'tools/list must be stable, so a pinned count means something'

        # The read/write split is a claim about what the script does, and it is
        # what a client reads before deciding whether to ask permission.
        $readOnly = @($tools | Where-Object { $_.annotations.readOnlyHint } | ForEach-Object { $_.name })
        foreach ($expected in @('yuruna_test_configuration', 'yuruna_test_requirement', 'yuruna_test_runtime',
                                'yuruna_system_diagnostic', 'yuruna_dependency_version')) {
            Assert-True ($readOnly -contains $expected) "$expected changes nothing and must be annotated read-only"
        }
        foreach ($mutating in @('yuruna_set_component', 'yuruna_set_resource', 'yuruna_set_workload',
                                'yuruna_set_host_alias', 'yuruna_invoke_clear')) {
            Assert-False ($readOnly -contains $mutating) "$mutating writes, and must not be annotated read-only"
        }

        # Only one of them discards something a repeat call cannot restore.
        $destructive = @($tools | Where-Object { $_.annotations.destructiveHint } | ForEach-Object { $_.name })
        Assert-Equal 'yuruna_invoke_clear' ($destructive -join ',') 'exactly Invoke-Clear is destructive'
    }

    It 'answers a notification with nothing at all' {
        # Not an empty response -- nothing. A client has no slot for a reply to
        # a message it sent no id with.
        $r = @(Invoke-McpExchange -Line '{"jsonrpc":"2.0","method":"notifications/initialized"}')
        Assert-Equal 0 $r.Count 'a notification takes no response'
    }

    It 'reports unknown methods and unknown tools distinctly' {
        $r = @(Invoke-McpExchange -Line @(
            '{"jsonrpc":"2.0","id":3,"method":"resources/list"}',
            '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"no_such_tool"}}'
        ))
        Assert-Equal (-32601) $r[0].error.code 'an unknown method is -32601'
        Assert-Equal (-32602) $r[1].error.code 'an unknown tool is an invalid param, not an unknown method'
    }

    It 'rejects a line that is not JSON without ending the session' {
        $r = @(Invoke-McpExchange -Line @('not json at all', '{"jsonrpc":"2.0","id":5,"method":"ping"}'))
        Assert-Equal (-32700) $r[0].error.code
        Assert-NotNull $r[1].result 'the loop must keep serving after a bad frame'
    }

    It 'echoes a string id unchanged' {
        # Ids may be numbers or strings and a client matches on the exact value.
        $r = @(Invoke-McpExchange -Line '{"jsonrpc":"2.0","id":"abc-123","method":"ping"}')
        Assert-Equal 'abc-123' $r[0].id
    }
}

Describe 'the entry points that do not answer like the others' {
    It 'reads Test-Runtime by its last pipeline object, never by an exit code' {
        # The script has no exit statement at all, so $LASTEXITCODE would report
        # success for a failing run.
        $run = @{ ExitCode = 0; Stdout = "checking things`nFalse`n"; Stderr = '' }
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_runtime' } -Run $run
        Assert-False $out.ok 'a False verdict is a failure even though the exit code is 0'
        Assert-Equal 'False' $out.verdict

        $pass = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_runtime' } `
            -Run @{ ExitCode = 0; Stdout = "noise`nTrue`n"; Stderr = '' }
        Assert-True $pass.ok
    }

    It 'never reports Get-SystemDiagnostic as healthy on the strength of its exit code' {
        # It always exits 0: that means the report was produced, not that the
        # host is well.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_system_diagnostic' } `
            -Run @{ ExitCode = 0; Stdout = 'SUMMARY: 3 problems'; Stderr = '' }
        Assert-True $out.ok 'the run itself succeeded'
        Assert-Match 'always exits 0' $out.note 'the result must say what the exit code does and does not mean'
        Assert-Match 'problems' $out.output 'the report itself is where the problems are'
    }

    It 'passes Check-DependencyVersion JSON through rather than re-wrapping it' {
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_dependency_version' } `
            -Run @{ ExitCode = 0; Stdout = '{"pins":[{"name":"go","version":"1.25.0"}]}'; Stderr = '' }
        Assert-NotNull $out.json 'the native JSON emitter is parsed, not stringified'
        Assert-Equal 'go' $out.json.pins[0].name
    }

    It 'treats a thrown error as Set-HostAlias failing, since it gives no other signal' {
        # No exit statement and no transcript: stderr is all there is.
        $bad = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_host_alias' } `
            -Run @{ ExitCode = 0; Stdout = ''; Stderr = 'Set-HostAlias: alias is not valid' }
        Assert-False $bad.ok 'a thrown error is the failure signal this script gives'

        $good = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_host_alias' } `
            -Run @{ ExitCode = 0; Stdout = 'alias set'; Stderr = '' }
        Assert-True $good.ok
    }

    It 'returns the transcript pointer when an ordinary entry point fails' {
        # On a failure the transcript is the half of the output worth reading
        # first, and a caller shown only an exit code has to re-run by hand.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_component' } `
            -Run @{ ExitCode = 1; Stdout = "working`nTranscript started, output file is /tmp/yuruna/x.log`n"; Stderr = '' }
        Assert-False $out.ok
        Assert-Equal 1 $out.exitCode
        Assert-Match 'x\.log' $out.transcript 'the transcript pointer must survive into the result'
    }
}

Describe 'the stdio contract' {
    It 'writes nothing to stdout but JSON-RPC frames' {
        # A client parses this stream; one stray line corrupts the session.
        $out = @(Invoke-McpExchange -Line @(
            '{"jsonrpc":"2.0","id":1,"method":"initialize"}',
            '{"jsonrpc":"2.0","method":"notifications/initialized"}',
            '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
        ))
        Assert-Equal 2 $out.Count 'two requests and one notification produce exactly two frames'
        foreach ($frame in $out) {
            Assert-Equal '2.0' $frame.jsonrpc 'every frame is JSON-RPC 2.0'
        }
    }

    It 'has no listener and takes no credential' {
        # The transport IS the trust boundary. A -Listen parameter or a token
        # here would imply a boundary this server does not have.
        $body = Get-Content -Raw -LiteralPath (Join-Path (Join-Path $TestRoot 'service') 'Start-McpServer.ps1')
        Assert-False ($body -match '(?m)^\s*\[string\]\$Listen') 'this server must never grow a listener'
        Assert-False ($body -match 'HttpListener') 'this server must never grow a listener'
        Assert-Match 'stdio' $body 'the trust model is documented in the script that relies on it'
    }
}

Describe 'a bare boolean verdict outranks the exit code' {
    It 'reads a top-level `return $false` as a failure, not a pass' {
        # Test-Configuration takes an early `return $false` when the root set
        # will not resolve. At top level that EMITS False and exits 0, so
        # reading the exit code alone reports a validation that never ran as a
        # clean pass -- which is exactly what a smoke test caught.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_configuration' } `
            -Run @{ ExitCode = 0; Stdout = "False`n"; Stderr = '' }
        Assert-False $out.ok 'a False verdict is a failure even with exit 0'
        Assert-Equal 'False' $out.verdict
        Assert-Match 'verdict is the output, not the exit code' $out.note
    }

    It 'still trusts the exit code when the script did not sign off with one' {
        $pass = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_configuration' } `
            -Run @{ ExitCode = 0; Stdout = "checked 12 things`nall good"; Stderr = '' }
        Assert-True $pass.ok
        $fail = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_configuration' } `
            -Run @{ ExitCode = 1; Stdout = "Transcript started, output file is /tmp/x.log"; Stderr = '' }
        Assert-False $fail.ok
        Assert-Match 'x\.log' $fail.transcript
    }

    It 'does not mistake a True sign-off for a failure' {
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_configuration' } `
            -Run @{ ExitCode = 0; Stdout = "True`n"; Stderr = '' }
        Assert-True $out.ok
    }
}
