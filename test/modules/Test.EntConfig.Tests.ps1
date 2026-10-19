<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42e237df-6378-43f5-b1f4-c3f181119e39
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config tcp reachable boolean pester
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
    Test-Config.ps1 probes TCP reachability through a single Test-TcpReachable helper
    that disposes its socket on every path, and normalizes boolean-ish config flags
    through ConvertTo-YurunaBool so a quoted 'false'/'0'/'no' is not read as $true.
.DESCRIPTION
    The two helpers are local functions in the Test-Config.ps1 script (not a module), so
    the behavioral tests extract their definitions from the script AST and dot-source
    them into this scope. AST guards then assert the script routes every network probe
    and all three config boolean flags through the helpers, and that the probe helper
    disposes in a finally. Pester 5.x.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$scriptPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'Test-Config.ps1')).Path

# Parse the script and lift the two helper definitions into this scope so they can be
# exercised without running the whole validator (which probes the network and exits).
# The AST is an unqualified file-scope variable: inside an It block a $script: reference
# resolves to the test runner's own script scope, not this file's, so a $script:-qualified
# fixture reaches the assertions as $null.
$errs = $null
$cfgAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
$wanted = 'Test-TcpReachable', 'ConvertTo-YurunaBool', 'Get-ConfigProxyEndpoint', 'Get-ConfigProxyContext'
$fnDefs = $cfgAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name
}, $true)
# Test-TcpReachable hands the socket work to the shared Test-TcpConnectOutcome.
$commonPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..', 'automation', 'Yuruna.Common.psm1')).Path
Import-Module $commonPath -Global -Force -DisableNameChecking
$commonAst = [System.Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$null, [ref]$null)
if (-not $commonAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-TcpConnectOutcome' }, $true)) {
    throw "Test.EntConfig.Tests.ps1: Test-TcpConnectOutcome is not defined in Yuruna.Common.psm1 (renamed or removed?)."
}
foreach ($fn in $fnDefs) { . ([ScriptBlock]::Create($fn.Extent.Text)) }
# Fail loudly at load if a helper could not be lifted (renamed/removed), instead of
# every It later reporting a bare 'command not recognized' with no cause.
foreach ($name in @('Test-TcpReachable', 'ConvertTo-YurunaBool')) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Test.EntConfig.Tests.ps1: could not lift '$name' from Test-Config.ps1 (renamed or removed?)."
    }
}

function Get-CommandCallCount {
    param($Ast, [string]$Name)
    return (Get-YurunaTestCommandCallCount -Ast $Ast -CommandName $Name)
}
function Get-MemberInvokeCount {
    param($Ast, [string]$Member)
    $wm = $Member
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq $wm
    }, $true)).Count
}
function Get-HelperDefinition {
    param($Ast, [string]$Name)
    $wm = $Name
    $Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wm
    }, $true) | Select-Object -First 1
}

}

Describe 'ConvertTo-YurunaBool normalizes boolean-ish config flags' {
    It 'maps the false-ish spelling <V> to $false' -TestCases @(
        @{ V = 'false' }, @{ V = 'FALSE' }, @{ V = '0' }, @{ V = 'no' }, @{ V = 'off' }, @{ V = '  false  ' }
    ) {
        param($V)
        ConvertTo-YurunaBool $V | Should -BeFalse
    }
    It 'maps the true-ish spelling <V> to $true' -TestCases @(
        @{ V = 'true' }, @{ V = 'TRUE' }, @{ V = '1' }, @{ V = 'yes' }, @{ V = 'on' }
    ) {
        param($V)
        ConvertTo-YurunaBool $V | Should -BeTrue
    }
    It 'passes a real [bool] through unchanged' {
        ConvertTo-YurunaBool $true  | Should -BeTrue
        ConvertTo-YurunaBool $false | Should -BeFalse
    }
    It 'treats $null, empty string, and numbers by the [bool] fallback' {
        ConvertTo-YurunaBool $null | Should -BeFalse
        ConvertTo-YurunaBool ''    | Should -BeFalse
        ConvertTo-YurunaBool 0     | Should -BeFalse
        ConvertTo-YurunaBool 1     | Should -BeTrue
    }
    It 'falls back to the [bool] cast for an unrecognized non-empty string' {
        ConvertTo-YurunaBool 'maybe' | Should -BeTrue
    }
}

Describe 'Test-TcpReachable is a bounded probe that always disposes' {
    It 'returns $true for a reachable local listener' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        try {
            Test-TcpReachable -HostName '127.0.0.1' -Port $port -TimeoutMs 3000 | Should -BeTrue
        } finally { $listener.Stop() }
    }
    It 'returns $false for a closed port without throwing' {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $port = ([System.Net.IPEndPoint]$l.LocalEndpoint).Port; $l.Stop()
        { Test-TcpReachable -HostName '127.0.0.1' -Port $port -TimeoutMs 3000 } | Should -Not -Throw
        Test-TcpReachable -HostName '127.0.0.1' -Port $port -TimeoutMs 3000 | Should -BeFalse
    }
}

Describe 'Preflight TCP evidence and bounded recovery' {
    BeforeEach {
        Mock Start-Sleep {}
    }

    It 'retains a transient timeout when the next connection succeeds' {
        $script:probeCall = 0
        Mock Test-TcpConnectOutcome {
            $script:probeCall++
            if ($script:probeCall -eq 1) {
                return @{ Outcome = 'timeout'; Reachable = $false; ElapsedMs = 5000; Detail = '' }
            }
            return @{ Outcome = 'reachable'; Reachable = $true; ElapsedMs = 17; Detail = ''; SocketAddressFamily = 'InterNetworkV6'; RemoteAddress = '192.0.2.1'; RemoteAddressFamily = 'InterNetwork' }
        }

        $report = Test-TcpReachable -HostName 'github.com' -Port 443 -TimeoutMs 5000 -MaxAttempts 3 -PassThru
        $report.Reachable | Should -BeTrue
        $report.Attempts.Count | Should -Be 2
        $report.Attempts[0].Outcome | Should -Be 'timeout'
        $report.Attempts[0].ElapsedMs | Should -Be 5000
        $report.Attempts[1].Outcome | Should -Be 'reachable'
        $report.Attempts[1].ElapsedMs | Should -Be 17
        $report.Attempts[0].HostName | Should -Be 'github.com'
        $report.Attempts[0].Port | Should -Be 443
        $report.Attempts[0].SocketAddressFamily | Should -BeNullOrEmpty
        $report.Attempts[0].RemoteAddress | Should -BeNullOrEmpty
        $report.Attempts[1].SocketAddressFamily | Should -Be 'InterNetworkV6'
        $report.Attempts[1].RemoteAddress | Should -Be '192.0.2.1'
        $report.Attempts[1].RemoteAddressFamily | Should -Be 'InterNetwork'
        [datetime]::Parse($report.Attempts[0].StartedAtUtc).ToUniversalTime() | Should -BeLessOrEqual ([datetime]::UtcNow)
        Should -Invoke Test-TcpConnectOutcome -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Milliseconds -eq 500 }
    }

    It 'keeps a persistent <Outcome> failure blocking after three attempts' -TestCases @(
        @{ Outcome = 'timeout' }, @{ Outcome = 'refused' }, @{ Outcome = 'unreachable' }
    ) {
        param($Outcome)
        $script:probeOutcome = $Outcome
        Mock Test-TcpConnectOutcome {
            return @{ Outcome = $script:probeOutcome; Reachable = $false; ElapsedMs = 7; Detail = 'Socket error evidence' }
        }

        $report = Test-TcpReachable -HostName 'github.com' -MaxAttempts 3 -PassThru
        $report.Reachable | Should -BeFalse
        $report.Outcome | Should -Be $Outcome
        $report.Attempts.Count | Should -Be 3
        foreach ($attempt in $report.Attempts) {
            $attempt.Outcome | Should -Be $Outcome
            $attempt.Detail | Should -Be 'Socket error evidence'
        }
        Should -Invoke Test-TcpConnectOutcome -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'does not retry an unclassified socket error' {
        Mock Test-TcpConnectOutcome {
            return @{ Outcome = 'error'; Reachable = $false; ElapsedMs = 2; Detail = 'Invalid argument' }
        }
        $report = Test-TcpReachable -HostName 'github.com' -MaxAttempts 3 -PassThru
        $report.Reachable | Should -BeFalse
        $report.Outcome | Should -Be 'error'
        $report.Attempts.Count | Should -Be 1
        $report.Attempts[0].Detail | Should -Be 'Invalid argument'
        Should -Invoke Test-TcpConnectOutcome -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'keeps earlier evidence when a later socket allocation throws' {
        $script:probeCall = 0
        Mock Test-TcpConnectOutcome {
            $script:probeCall++
            if ($script:probeCall -eq 1) {
                return @{ Outcome = 'timeout'; Reachable = $false; ElapsedMs = 5000; Detail = '' }
            }
            throw 'Socket allocation failed'
        }
        $report = Test-TcpReachable -HostName 'github.com' -MaxAttempts 3 -PassThru
        $report.Reachable | Should -BeFalse
        $report.Outcome | Should -Be 'error'
        $report.Attempts.Count | Should -Be 2
        $report.Attempts[0].Outcome | Should -Be 'timeout'
        $report.Attempts[1].Detail | Should -Be 'Socket allocation failed'
        Should -Invoke Test-TcpConnectOutcome -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'leaves existing boolean callers on a single attempt' {
        Mock Test-TcpConnectOutcome {
            return @{ Outcome = 'timeout'; Reachable = $false; ElapsedMs = 5000; Detail = '' }
        }
        Test-TcpReachable -HostName 'github.com' | Should -BeFalse
        Should -Invoke Test-TcpConnectOutcome -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'redacts proxy user information, paths, queries, and fragments' {
        $safe = Get-ConfigProxyEndpoint -Value 'http://alice:secret@proxy.example:3128/private?token=hidden#credential'
        $safe.Configured | Should -BeTrue
        $safe.Scheme | Should -Be 'http'
        $safe.Host | Should -Be 'proxy.example'
        $safe.Port | Should -Be 3128
        ($safe | ConvertTo-Json -Compress) | Should -Not -Match 'alice|secret|private|token|hidden|credential'
    }

    It 'does not expose malformed proxy configuration in diagnostics' {
        $safe = Get-ConfigProxyEndpoint -Value 'http://alice:secret@[]:broken?token=hidden'
        $safe.Configured | Should -BeTrue
        $safe.ValidEndpoint | Should -BeFalse
        ($safe | ConvertTo-Json -Compress) | Should -Not -Match 'alice|secret|token|hidden|broken'
    }

    It 'keeps the direct probe separate from sanitized Git proxy configuration' {
        Mock Invoke-BoundedNativeCommand {
            return @{ Started = $true; ExitCode = 0; StdOut = 'http://alice:secret@proxy.example:3128/private?token=hidden' }
        }
        $context = Get-ConfigProxyContext -RepoRoot $TestDrive
        $context.probeRoute | Should -Be 'direct'
        $context.gitProxy.queryStatus | Should -Be 'configured'
        $context.gitProxy.host | Should -Be 'proxy.example'
        ($context.gitProxy | ConvertTo-Json -Compress) | Should -Not -Match 'alice|secret|private|token|hidden'
        Should -Invoke Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $TimeoutSeconds -eq 3 -and $ArgumentList[0] -eq '-C' -and $ArgumentList[1] -eq $TestDrive -and
            $ArgumentList[3] -eq '--get-urlmatch' -and $ArgumentList[4] -eq 'http.proxy' -and $ArgumentList[5] -eq 'https://github.com/'
        }
    }

    It 'does not treat an incomplete Git proxy query as configured' {
        Mock Invoke-BoundedNativeCommand {
            return @{ Started = $true; ExitCode = 0; TimedOut = $true; StdOut = 'http://secret@proxy.example:3128' }
        }
        $context = Get-ConfigProxyContext -RepoRoot $TestDrive
        $context.gitProxy.queryStatus | Should -Be 'unavailable'
        ($context.gitProxy | ConvertTo-Json -Compress) | Should -Not -Match 'secret|proxy.example'
    }
}

Describe 'Test-Config.ps1 routes probes and flags through the helpers' {
    It 'the probe helper disposes its socket in a finally' {
        $fn = Get-HelperDefinition -Ast $cfgAst -Name 'Test-TcpReachable'
        $fn | Should -Not -BeNullOrEmpty
        $fn.Body.Extent.Text | Should -Match 'Test-TcpConnectOutcome'
        $shared = Get-HelperDefinition -Ast $commonAst -Name 'Test-TcpConnectOutcome'
        $shared | Should -Not -BeNullOrEmpty
        $body = $shared.Body.Extent.Text
        $body | Should -Match 'finally'
        $body | Should -Match '\.Close\(\)'
    }
    It 'every TCP probe routes through Test-TcpReachable' {
        # One call per probe site the validator performs: GitHub, the pool registry's
        # advertised stash service, and Resend. An exact count, so a new probe that
        # opens its own socket instead of calling the helper is caught here rather
        # than leaking a handle in the long-running validator process.
        (Get-CommandCallCount -Ast $cfgAst -Name 'Test-TcpReachable') | Should -Be 3
    }
    It 'no inline TcpClient BeginConnect remains outside the shared helper' {
        # The validator opens no socket itself; the one BeginConnect lives in the shared probe.
        (Get-MemberInvokeCount -Ast $cfgAst -Member 'BeginConnect') | Should -Be 0
        (Get-MemberInvokeCount -Ast $commonAst -Member 'BeginConnect') | Should -Be 1
    }
    It 'the three config boolean flags route through ConvertTo-YurunaBool' {
        (Get-CommandCallCount -Ast $cfgAst -Name 'ConvertTo-YurunaBool') | Should -Be 3
    }
}
