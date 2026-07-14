<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c7d8e9-a0b1-4c23-9d45-6e7f8a9b0c14
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
    them into this scope. AST guards then assert the script routes both network probes
    and all three config boolean flags through the helpers, and that the probe helper
    disposes in a finally. Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$scriptPath = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'Test-Config.ps1')).Path

# Parse the script and lift the two helper definitions into this scope so they can be
# exercised without running the whole validator (which probes the network and exits).
# The AST is an unqualified file-scope variable: inside an It block a $script: reference
# resolves to the test runner's own script scope, not this file's, so a $script:-qualified
# fixture reaches the assertions as $null.
$errs = $null
$cfgAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errs)
$wanted = 'Test-TcpReachable', 'ConvertTo-YurunaBool'
$fnDefs = $cfgAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $n.Name
}, $true)
foreach ($fn in $fnDefs) { . ([ScriptBlock]::Create($fn.Extent.Text)) }
# Fail loudly at load if a helper could not be lifted (renamed/removed), instead of
# every It later reporting a bare 'command not recognized' with no cause.
foreach ($name in $wanted) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Test.EntConfig.Tests.ps1: could not lift '$name' from Test-Config.ps1 (renamed or removed?)."
    }
}

function Get-CommandCallCount {
    param($Ast, [string]$Name)
    $wm = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wm
    }, $true)).Count
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

Describe 'Test-Config.ps1 routes probes and flags through the helpers' {
    It 'the probe helper disposes its socket in a finally' {
        $fn = Get-HelperDefinition -Ast $cfgAst -Name 'Test-TcpReachable'
        $fn | Should -Not -BeNullOrEmpty
        $body = $fn.Body.Extent.Text
        $body | Should -Match 'finally'
        $body | Should -Match '\.Dispose\(\)'
    }
    It 'both TCP probes route through Test-TcpReachable' {
        (Get-CommandCallCount -Ast $cfgAst -Name 'Test-TcpReachable') | Should -Be 2
    }
    It 'no inline TcpClient BeginConnect remains outside the shared helper' {
        # Exactly one BeginConnect member-invoke -- the one inside Test-TcpReachable.
        (Get-MemberInvokeCount -Ast $cfgAst -Member 'BeginConnect') | Should -Be 1
    }
    It 'the three config boolean flags route through ConvertTo-YurunaBool' {
        (Get-CommandCallCount -Ast $cfgAst -Name 'ConvertTo-YurunaBool') | Should -Be 3
    }
}
