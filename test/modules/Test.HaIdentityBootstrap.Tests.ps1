<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42f0a1b2-c3d4-4e56-9f78-9a0b1c2d3e47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host identity fingerprint sysctl macos pester
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
    Get-HostFingerprintMacOS guards its numeric sysctl reads on exit code + non-empty
    output, so a failed or empty read leaves the field at its default (cpuCount 0,
    ramBytes 0) instead of silently casting '' to 0 into the host fingerprint, and
    records the degraded read with a verbose breadcrumb.
.DESCRIPTION
    The gate is the pure Resolve-GuardedSysctlValue (lifted from the module AST and run
    directly, since it needs no sysctl): a successful non-empty read returns the trimmed
    value the caller casts (so the fingerprint is byte-identical on a working host), and
    a failed/empty read returns $null plus a verbose breadcrumb. AST guards assert the
    macOS fingerprint routes its reads through the guard and retains no bare
    [int]/[int64] sysctl cast. Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$modPath  = Join-Path $here 'Test.HostIdentity.psm1'
# The AST is an unqualified file-scope variable: inside an It block a $script: reference
# resolves to the test runner's own script scope, not this file's, so a $script:-qualified
# fixture reaches the assertions as $null -- and a -Not -Match against $null passes
# vacuously, which is exactly the silent false-pass the AST guards exist to prevent.
$errs = $null
$hostIdAst = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
if ($errs) { throw "Parse errors in Test.HostIdentity.psm1: $($errs[0].Message)" }
$fnDef = $hostIdAst.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-GuardedSysctlValue'
}, $true) | Select-Object -First 1
if (-not $fnDef) { throw "Test.HaIdentityBootstrap.Tests.ps1: could not lift Resolve-GuardedSysctlValue from Test.HostIdentity.psm1 (renamed or removed?)." }
. ([ScriptBlock]::Create($fnDef.Extent.Text))

function Get-CommandCallCount {
    param($Ast, [string]$Name)
    $wm = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wm
    }, $true)).Count
}

Describe 'Resolve-GuardedSysctlValue gates a sysctl read on exit code + non-empty output' {
    It 'returns the trimmed value the caller casts on a successful non-empty read: <Raw>' -TestCases @(
        @{ Raw = '8';             Expect = '8' }
        @{ Raw = '  8  ';         Expect = '8' }
        @{ Raw = '17179869184';   Expect = '17179869184' }
    ) {
        param($Raw, $Expect)
        Resolve-GuardedSysctlValue -Raw $Raw -ExitCode 0 -Key 'k' | Should -Be $Expect
    }
    It 'the returned success value casts to the same number a bare [int]/[int64] would' {
        [int](Resolve-GuardedSysctlValue -Raw '8' -ExitCode 0 -Key 'k')                | Should -Be 8
        [int64](Resolve-GuardedSysctlValue -Raw '17179869184' -ExitCode 0 -Key 'k')    | Should -Be 17179869184
    }
    It 'returns $null (caller keeps its default) when the read failed or was empty: <Case>' -TestCases @(
        @{ Case = 'nonzero exit'; Raw = '8'; ExitCode = 1 }
        @{ Case = 'empty output'; Raw = '';  ExitCode = 0 }
        @{ Case = 'null output';  Raw = $null; ExitCode = 0 }
        @{ Case = 'whitespace';   Raw = '   '; ExitCode = 0 }
    ) {
        param($Raw, $ExitCode)
        Resolve-GuardedSysctlValue -Raw $Raw -ExitCode $ExitCode -Key 'k' -Verbose:$false | Should -BeNullOrEmpty
    }
    It 'records a verbose breadcrumb naming the key when the read is unavailable' {
        # In production the caller (Get-HostFingerprintMacOS -Verbose) propagates
        # $VerbosePreference into this helper; simulate that so the breadcrumb emits.
        $prev = $VerbosePreference
        $VerbosePreference = 'Continue'
        try {
            $rec = Resolve-GuardedSysctlValue -Raw '' -ExitCode 0 -Key 'hw.memsize' 4>&1
        } finally { $VerbosePreference = $prev }
        @($rec | Where-Object {
            $_ -is [System.Management.Automation.VerboseRecord] -and $_.Message -match 'hw\.memsize'
        }).Count | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-HostFingerprintMacOS routes its sysctl reads through the guard' {
    It 'retains no bare [int]/[int64] sysctl cast' {
        $hostIdAst.Extent.Text | Should -Not -Match '\[int(64)?\]\(& sysctl'
    }
    It 'reads all three corroborating fields through Get-SysctlValue' {
        (Get-CommandCallCount -Ast $hostIdAst -Name 'Get-SysctlValue') | Should -BeGreaterOrEqual 3
        $text = $hostIdAst.Extent.Text
        foreach ($key in 'machdep.cpu.brand_string', 'hw.logicalcpu', 'hw.memsize') {
            $text | Should -Match ("Get-SysctlValue -Key '" + [regex]::Escape($key) + "'")
        }
    }
}

Describe 'Get-HostFingerprintMacOS keeps fingerprint defaults on a failed read and assigns on success' {
    BeforeAll { Import-Module $modPath -Force }
    AfterAll  { Remove-Module Test.HostIdentity -Force -ErrorAction SilentlyContinue }

    It 'keeps cpuCount/ramBytes/cpuModel at their defaults when every sysctl read fails (no re-key)' {
        InModuleScope Test.HostIdentity {
            Mock Get-SysctlValue { $null }
            $fp = Get-HostFingerprintMacOS
            $fp.cpuCount | Should -Be 0
            $fp.ramBytes | Should -Be 0
            $fp.cpuModel | Should -Be ''
        }
    }
    It 'assigns each field from a successful read' {
        InModuleScope Test.HostIdentity {
            Mock Get-SysctlValue {
                param($Key)
                switch ($Key) {
                    'hw.logicalcpu'            { '8' }
                    'hw.memsize'               { '17179869184' }
                    'machdep.cpu.brand_string' { 'Apple M2' }
                    default                    { $null }
                }
            }
            $fp = Get-HostFingerprintMacOS
            $fp.cpuCount | Should -Be 8
            $fp.ramBytes | Should -Be 17179869184
            $fp.cpuModel | Should -Be 'Apple M2'
        }
    }
}
