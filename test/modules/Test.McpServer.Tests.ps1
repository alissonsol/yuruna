<#PSScriptInfo
.VERSION 2026.09.24
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
        # Shaped like the real emitter: a bare ARRAY of rows keyed
        # Dependency/Pinned/Latest/Status/Source/Detail. An invented envelope
        # here would parse where the real stream did not, which is exactly how
        # this boundary stayed broken while the test stayed green.
        $real = '[{"Dependency":"Go","Pinned":"1.26.5","Latest":"1.26.5","Status":"current",' +
                '"Source":"go.dev/dl","Detail":""}]'
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_dependency_version' } `
            -Run @{ ExitCode = 0; Stdout = $real; Stderr = '' }
        Assert-NotNull $out.json 'the native JSON emitter is parsed, not stringified'
        Assert-StringEqual -Expected 'Go' -Actual ([string]@($out.json)[0].Dependency)
    }

    It 'does not call dependency drift a failed report' {
        # The script exits 1 whenever a pin has drifted, so a CI gate can fail a
        # build on it. That is the report succeeding at its job; reporting it as
        # an error makes "there are updates" look like "the report broke".
        $real = '[{"Dependency":"Kubernetes (minor)","Pinned":"1.36","Latest":"1.37",' +
                '"Status":"UPDATE AVAILABLE","Source":"dl.k8s.io","Detail":"latest release 1.37.0"}]'
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_dependency_version' } `
            -Run @{ ExitCode = 1; Stdout = $real; Stderr = '' }
        Assert-True ([bool]$out.ok) 'a drift report is a report that worked'
        Assert-Equal 1 $out.exitCode 'the exit code still reaches the caller'
        Assert-Match 'drifted' $out.note 'the result has to say what the code meant'

        # Output that is not the document is still a failure.
        $broken = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_dependency_version' } `
            -Run @{ ExitCode = 1; Stdout = 'Pinned dependency versions from ...'; Stderr = '' }
        Assert-False ([bool]$broken.ok) 'unparseable output is not a successful report'
    }

    It 'parses what the real emitter actually writes to stdout' {
        # The fixture above is a claim about the producer. This runs it. Under
        # -AsJson the narration has to stay off stdout: ConvertFrom-Json reads
        # the whole stream, so one line of prose ahead of the document fails the
        # parse on its first character and the pass-through never fires.
        $script = Join-Path $script:RepoRoot 'automation/Check-DependencyVersion.ps1'
        $pwshPath = (Get-Process -Id $PID).Path
        $stdout = & $pwshPath -NoProfile -NonInteractive -File $script -AsJson 2>$null | Out-String
        Assert-True ($stdout.Trim().Length -gt 0) 'the emitter wrote nothing to parse'
        $parsed = $null
        try { $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        Assert-NotNull $parsed 'the -AsJson stream is not parsable JSON, so the pass-through cannot fire'
        Assert-True (@($parsed).Count -gt 0) 'the document carries no rows'
        Assert-NotNull @($parsed)[0].Dependency 'a row must name the dependency it describes'
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
            -Run @{ ExitCode = 1; Stdout = "working"; Stderr = ''
                    TranscriptPath = '/tmp/yuruna/x.log' }
        Assert-False $out.ok
        Assert-Equal 1 $out.exitCode
        Assert-StringEqual -Expected '/tmp/yuruna/x.log' -Actual ([string]$out.transcript) `
            -Because 'the pointer the run carried must reach the result unchanged'
    }

    It 'finds the pointer in output no human would recognize' {
        # The whole point of the structured field: stdout can be in any
        # language, or say nothing about a transcript at all, and the pointer is
        # still there. Nothing here reads this text, which is the assertion.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_component' } `
            -Run @{ ExitCode = 1
                    Stdout = "**********************`nInicio da transcricao do PowerShell`n"
                    Stderr = ''; TranscriptPath = '/tmp/yuruna/y.log' }
        Assert-StringEqual -Expected '/tmp/yuruna/y.log' -Actual ([string]$out.transcript) `
            -Because 'the host culture must not decide whether a pointer is found'
    }

    It 'does not invent a pointer from prose that mentions a transcript' {
        # A sentence that mentions a transcript is not a pointer to one. Prose
        # naming a path and prose naming none must both leave the result without
        # one, or the field means whatever the output happened to say -- and a
        # dumped transcript's own header and footer say the word every time.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_component' } `
            -Run @{ ExitCode = 1
                    Stdout = "Transcript started, output file is /tmp/decoy.log`nPowerShell transcript end"
                    Stderr = ''; TranscriptPath = '' }
        Assert-False ($out.ContainsKey('transcript')) `
            'a run that recorded no transcript must report none, not a sentence that named one'
    }

    It 'reports no pointer when a failing run wrote no transcript' {
        # An ordinary tool, deliberately: the ones with their own switch arm
        # return before the transcript block, so one of those would pass this
        # whether or not the block behaved.
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_invoke_clear' } `
            -Run @{ ExitCode = 1; Stdout = 'cleared nothing'; Stderr = 'threw'; TranscriptPath = '' }
        Assert-False ($out.ContainsKey('transcript')) 'some entry points write none at all'
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
            -Run @{ ExitCode = 1; Stdout = 'a check failed'; Stderr = ''
                    TranscriptPath = '/tmp/x.log' }
        Assert-False $fail.ok
        Assert-StringEqual -Expected '/tmp/x.log' -Actual ([string]$fail.transcript) `
            -Because 'the pointer comes from the run, not from what it printed'
    }

    It 'does not mistake a True sign-off for a failure' {
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_test_configuration' } `
            -Run @{ ExitCode = 0; Stdout = "True`n"; Stderr = '' }
        Assert-True $out.ok
    }
}

Describe 'the server passes only what an entry point can bind' {
    It 'advertises no argument on any tool' {
        # None of the ten entry points declares a config-file parameter, and
        # eight have no [CmdletBinding()], so an advertised input they cannot
        # bind would be absorbed into $args and the run would proceed against
        # defaults while the caller believed its input was honored.
        foreach ($tool in Get-McpToolTable) {
            Assert-Match '"properties"\s*:\s*\{\s*\}' $tool.Schema `
                "$($tool.Name) advertises an input its entry point does not declare"
        }
    }

    It 'refuses an argument the entry point does not declare' {
        $run = Invoke-McpEntryPoint -Script 'Test-Configuration.ps1' `
            -ScriptArgument @('-ConfigFile', '/tmp/nowhere.yml')
        try {
            Assert-NotEqual -Expected 0 -Actual $run.ExitCode `
                -Because 'a script without [CmdletBinding()] would otherwise swallow it and exit 0'
            Assert-Match 'declares no parameter named' $run.Stderr 'the refusal has to name what could not bind'
            Assert-Match 'ConfigFile' $run.Stderr 'and which argument it was'
        } finally {
            if ($run.TranscriptPath) { Remove-Item -LiteralPath $run.TranscriptPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'reports a refusal as a failure on every tool shape' {
        # The per-tool arms describe how each script reports its own outcome,
        # and yuruna_system_diagnostic's arm is "always ok, the problems are in
        # the report" -- true of a run that happened, and a false pass for one
        # that never started. The refusal has to be answered before them.
        foreach ($tool in Get-McpToolTable) {
            $out = ConvertTo-McpToolResult -Tool $tool `
                -Run @{ ExitCode = 126; Stdout = ''; Stderr = 'declares no parameter named: X'
                        TranscriptPath = ''; Refused = $true }
            Assert-False ([bool]$out.ok) "$($tool.Name) reports a refused run as a success"
        }
    }

    It 'leaves an ordinary run of the same tool alone' {
        $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_system_diagnostic' } `
            -Run @{ ExitCode = 0; Stdout = 'report'; Stderr = ''; TranscriptPath = '' }
        Assert-True ([bool]$out.ok) 'the refusal guard must not change how a real run is read'
    }

    It 'still passes an argument the entry point does declare' {
        $run = Invoke-McpEntryPoint -Script 'Test-Configuration.ps1' -ScriptArgument @('-logLevel', 'Error')
        try {
            Assert-NotEqual -Expected 126 -Actual $run.ExitCode 'a declared parameter must not be refused'
        } finally {
            if ($run.TranscriptPath) { Remove-Item -LiteralPath $run.TranscriptPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'answers exactly as the PowerShell binder does' {
        # The binder is the oracle, not a second implementation of its rules.
        # Getting those rules wrong is possible in both directions at once:
        # inventing ambiguity between a declared name and a common one, and
        # granting common parameters to a script with no [CmdletBinding()],
        # which binds none and absorbs them into $args instead.
        $automation = Join-Path $script:RepoRoot 'automation'
        $cases = @(
            @{ Script = 'Test-Configuration.ps1'; Name = 'Conf' }          # declared beats Confirm
            @{ Script = 'Test-Configuration.ps1'; Name = 'c' }             # shortest unambiguous prefix
            @{ Script = 'Test-Configuration.ps1'; Name = 'project_root' }
            @{ Script = 'Test-Configuration.ps1'; Name = 'logLevel' }
            @{ Script = 'Test-Configuration.ps1'; Name = 'Verbose' }       # no CmdletBinding: not bound
            @{ Script = 'Test-Configuration.ps1'; Name = 'Confirm' }
            @{ Script = 'Test-Configuration.ps1'; Name = 'ProgressAction' }
            @{ Script = 'Test-Configuration.ps1'; Name = 'NoSuchThing' }
            @{ Script = 'Set-HostAlias.ps1'; Name = 'C' }                  # ComputerName, not Confirm
            @{ Script = 'Set-HostAlias.ps1'; Name = 'I' }                  # IPAddress, not InformationAction
            @{ Script = 'Set-HostAlias.ps1'; Name = 'Verbose' }            # advanced: common set exists
            @{ Script = 'Set-HostAlias.ps1'; Name = 'W' }                  # ambiguous among common names
            @{ Script = 'Get-SystemDiagnostic.ps1'; Name = 'O' }
            @{ Script = 'Get-SystemDiagnostic.ps1'; Name = 'S' }           # genuinely ambiguous
            @{ Script = 'Check-DependencyVersion.ps1'; Name = 'P' }
            @{ Script = 'Check-DependencyVersion.ps1'; Name = 'AsJson' }
            @{ Script = 'Test-Requirement.ps1'; Name = 'Warn' }
        )
        $findings = @()
        foreach ($case in $cases) {
            $path = Join-Path $automation $case.Script
            $binderBinds = $true
            try {
                $command = Get-Command -Name $path -CommandType ExternalScript -ErrorAction Stop
                $null = $command.ResolveParameter($case.Name)
            } catch { $binderBinds = $false }
            $guardBinds = @(Get-UnboundParameterName -ScriptPath $path -Argument @("-$($case.Name)")).Count -eq 0
            if ($binderBinds -ne $guardBinds) {
                $findings += "$($case.Script) -$($case.Name): binder=$binderBinds guard=$guardBinds"
            }
        }
        Assert-NoFinding $findings 'the guard disagrees with the binder it stands in for'
    }

    It 'refuses every name when the target cannot be loaded' {
        # A script that will not load cannot be shown to accept anything, and an
        # argument it might silently drop is the failure being guarded.
        $broken = Join-Path $TestDrive 'broken.ps1'
        [IO.File]::WriteAllText($broken, "param(`n", [Text.UTF8Encoding]::new($false))
        $unbound = @(Get-UnboundParameterName -ScriptPath $broken -Argument @('-Anything'))
        Assert-Equal -Expected 1 -Actual $unbound.Count 'an unloadable target must refuse, not wave through'
    }

    It 'ignores values and reports only names' {
        $unbound = @(Get-UnboundParameterName `
            -ScriptPath (Join-Path $script:RepoRoot 'automation/Test-Configuration.ps1') `
            -Argument @('-project_root', '-not-a-switch-just-a-value', '-logLevel:Error'))
        Assert-Equal -Expected 1 -Actual $unbound.Count 'only the one undeclared name counts'
        Assert-StringEqual -Expected 'not-a-switch-just-a-value' -Actual $unbound[0]
    }
}

Describe 'the transcript pointer is decided, not discovered' {
    It 'names the transcript before the child runs' {
        # A pointer the server chose is one it can hand out whatever the child
        # printed. Reading the source is the assertion here because the
        # alternative -- matching a word in rendered output -- leaves no trace
        # a behavior test can see until a host changes language.
        $source = [IO.File]::ReadAllText((Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'service') 'Start-McpServer.ps1'))
        Assert-Match 'YURUNA_TRANSCRIPT_PATH' $source 'the server has to name the file it will read'
        # Any comparison against a transcript-shaped literal, however it is
        # spelled. Pinning one formatting of the statement that used to be here
        # would let the same mistake back in written any other way.
        Assert-False ($source -match "(?i)-(match|like|imatch|contains)\s+[`"'][^`"'`\n]*transcript") `
            'no control flow may recognize the transcript by a word in the output'
    }

    It 'reports the path it named once the child has written there' {
        # A stand-in entry point, so the assertion is about the server's half of
        # the contract and not about which real script happens to fail today.
        $stage = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'Writes-Transcript.ps1'),
            "Set-Content -LiteralPath `$env:YURUNA_TRANSCRIPT_PATH -Value 'recorded'`nexit 1`n")
        $priorDir = $script:AutomationDir
        $script:AutomationDir = $stage
        try {
            $run = Invoke-McpEntryPoint -Script 'Writes-Transcript.ps1'
            Assert-True ([bool]$run.TranscriptPath) 'a child that wrote there must come back with the pointer'
            Assert-True (Test-Path -LiteralPath $run.TranscriptPath -PathType Leaf) `
                'a reported pointer must name a file the caller can open'
            $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_component' } -Run $run
            Assert-StringEqual -Expected ([string]$run.TranscriptPath) -Actual ([string]$out.transcript) `
                -Because 'the result carries the same path the run recorded'
            Remove-Item -LiteralPath $run.TranscriptPath -Force -ErrorAction SilentlyContinue
        } finally {
            $script:AutomationDir = $priorDir
        }
    }

    It 'keeps no transcript for a run that succeeded' {
        # A successful run's transcript is a record nothing will ask for: the
        # result carries no pointer to it, so keeping it would leave one file
        # behind per call for as long as the server runs.
        $stage = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $stage 'Writes-And-Succeeds.ps1'),
            "Set-Content -LiteralPath `$env:YURUNA_TRANSCRIPT_PATH -Value 'recorded'`nexit 0`n")
        $priorDir = $script:AutomationDir
        $script:AutomationDir = $stage
        try {
            $before = @(Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'yuruna-mcp-*.transcript.txt').Count
            $run = Invoke-McpEntryPoint -Script 'Writes-And-Succeeds.ps1'
            Assert-Equal -Expected 0 -Actual $run.ExitCode -Because 'the fixture is meant to succeed'
            Assert-StringEqual -Expected '' -Actual ([string]$run.TranscriptPath) `
                -Because 'a pointer nothing reports is a file nothing deletes'
            $after = @(Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'yuruna-mcp-*.transcript.txt').Count
            Assert-Equal -Expected $before -Actual $after `
                -Because 'a successful call must not leave a transcript in the temporary directory'
        } finally {
            $script:AutomationDir = $priorDir
        }
    }

    It 'reports nothing, and leaves nothing behind, when the child wrote no transcript' {
        $stage = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        # Creates the file and leaves it empty, which is what a child that
        # started a transcript and died before writing to it leaves behind. An
        # entry point that never touched the path would skip the size guard
        # this is here to exercise.
        [IO.File]::WriteAllText((Join-Path $stage 'Writes-Nothing.ps1'),
            "Set-Content -LiteralPath `$env:YURUNA_TRANSCRIPT_PATH -Value ''  -NoNewline`nexit 1`n")
        $priorDir = $script:AutomationDir
        $script:AutomationDir = $stage
        try {
            $before = @(Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'yuruna-mcp-*.transcript.txt').Count
            $run = Invoke-McpEntryPoint -Script 'Writes-Nothing.ps1'
            Assert-StringEqual -Expected '' -Actual ([string]$run.TranscriptPath) `
                -Because 'an empty file is not a transcript, and a pointer to one reads as a broken link'
            $out = ConvertTo-McpToolResult -Tool @{ Name = 'yuruna_set_component' } -Run $run
            Assert-False ($out.ContainsKey('transcript')) 'no transcript means no pointer'
            $after = @(Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter 'yuruna-mcp-*.transcript.txt').Count
            Assert-Equal -Expected $before -Actual $after `
                -Because 'a name the server handed out and nobody wrote to must not accumulate per call'
        } finally {
            $script:AutomationDir = $priorDir
        }
    }

    It 'is honored by every entry point that writes a transcript' {
        # The resolver runs before the Yuruna.* eviction that sweeps up the
        # module exporting it. An entry point that drifts back to a bare
        # temporary name loses the pointer silently -- nothing fails, the
        # server just stops finding one.
        $automation = Join-Path $script:RepoRoot 'automation'
        $writers = @(Get-ChildItem -Path $automation -Filter '*.ps1' | Where-Object {
                [IO.File]::ReadAllText($_.FullName) -match '(?m)^\$null = Start-Transcript ' })
        Assert-True ($writers.Count -ge 6) "expected the transcript-writing entry points, found $($writers.Count)"
        foreach ($writer in $writers) {
            $text = [IO.File]::ReadAllText($writer.FullName)
            Assert-Match 'Resolve-YurunaTranscriptPath' $text `
                "$($writer.Name) chooses its own transcript name, so a caller cannot name one"
            $resolveAt = $text.IndexOf('Resolve-YurunaTranscriptPath', [StringComparison]::Ordinal)
            $evictAt = $text.IndexOf('Get-Module Yuruna.* | Remove-Module', [StringComparison]::Ordinal)
            if ($evictAt -ge 0) {
                Assert-True ($resolveAt -lt $evictAt) `
                    "$($writer.Name) resolves the transcript path after the module exporting the resolver is evicted"
            }
        }
    }

    It 'leaves the variable it borrowed exactly as it found it' {
        $prior = 'sentinel-value'
        $env:YURUNA_TRANSCRIPT_PATH = $prior
        try {
            $null = Invoke-McpEntryPoint -Script 'Set-HostAlias.ps1'
            Assert-StringEqual -Expected $prior -Actual "$env:YURUNA_TRANSCRIPT_PATH" `
                -Because "the server runs inside someone else's process environment"
        } finally {
            $env:YURUNA_TRANSCRIPT_PATH = ''
        }
    }
}
