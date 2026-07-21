<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42d0e1f2-a3b4-4c56-9890-bd1e2f3a4b52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool admin gate retry pester
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
    Test-YurunaPoolIntentFile fails a REQUIRED but absent file (pools.yml) while
    SKIPping optional ones, and the idempotent network git ops (fetch/clone/push)
    retry within one wall-clock budget.
.DESCRIPTION
    Behavioral tests exercise the exported Test-YurunaPoolIntentFile and the
    module-private Invoke-PoolAdminGitWithRetry (in module scope), with the git
    primitive + schema validator mocked. AST guards pin that the CI gate marks
    pools.yml -Required and that fetch/clone/push route through the retry wrapper.
    The throw-free Should assertions run under Pester 4.10.1.
#>

$here          = Split-Path -Parent $PSCommandPath
$adminPath     = Join-Path $here 'Test.PoolAdmin.psm1'
$syncPath      = Join-Path $here 'Test.PoolSync.psm1'
$poolIntentPs1 = Join-Path (Split-Path -Parent $here) 'Test-PoolIntent.ps1'
Import-Module $syncPath  -Force   # exports Invoke-PoolSyncGit (mocked below)
Import-Module $adminPath -Force

# powershell-yaml may be absent in the test session; shim ConvertFrom-Yaml so the
# present-file cases can mock it in module scope.
$script:yamlShimmed = $false
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    function global:ConvertFrom-Yaml {
        param([Parameter(ValueFromPipeline)]$InputObject, [switch]$Ordered)
        process { $null = $InputObject; $null = $Ordered }
    }
    $script:yamlShimmed = $true
}

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
function Get-CommandInvocation {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true))
}
function Get-FunctionDefCount {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted
    }, $true)).Count
}
function Test-CallHasSwitch {
    param($Call, [string]$SwitchName)
    $sw = $SwitchName
    @($Call.CommandElements | Where-Object {
        $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq $sw
    }).Count -gt 0
}
function Test-AnyExtentMatch {
    param($Nodes, [string]$Pattern)
    $p = $Pattern
    @($Nodes | Where-Object { $_.Extent.Text -match $p }).Count -gt 0
}

Describe 'Test-YurunaPoolIntentFile enforces required vs optional intent files' {
    It 'FAILS a required file that is absent (pools.yml must not read as success)' {
        $missing = Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Test-YurunaPoolIntentFile -Path $missing -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
    }
    It 'SKIPs (passes) an optional file that is absent' {
        $missing = Join-Path $env:TEMP ('nope-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Test-YurunaPoolIntentFile -Path $missing -SchemaName 'guests.compatibility.schema.yml' -Label 'guests.compatibility.yml' | Should -Be $true
    }
    It 'PASSes a present, schema-valid file' {
        $tmp = Join-Path $env:TEMP ('yes-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value 'schemaVersion: 1'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { @{ schemaVersion = 1 } }
            Mock -ModuleName Test.PoolAdmin Test-YurunaPoolDocValid { @{ Ok = $true; Errors = @() } }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required | Should -Be $true
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'FAILs a present file that is schema-invalid' {
        $tmp = Join-Path $env:TEMP ('bad-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value 'schemaVersion: 1'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { @{ schemaVersion = 1 } }
            Mock -ModuleName Test.PoolAdmin Test-YurunaPoolDocValid { @{ Ok = $false; Errors = @('pools[0].poolId required') } }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    It 'FAILs a present file that will not parse as YAML' {
        $tmp = Join-Path $env:TEMP ('unparse-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.yml')
        Set-Content -LiteralPath $tmp -Value ': not yaml'
        try {
            Mock -ModuleName Test.PoolAdmin ConvertFrom-Yaml { throw 'bad yaml' }
            Test-YurunaPoolIntentFile -Path $tmp -SchemaName 'pools.schema.yml' -Label 'pools.yml' -Required -WarningAction SilentlyContinue | Should -Be $false
        } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-PoolAdminGitWithRetry survives a transient failure within a bounded budget' {
    It 'returns 0 and calls git once when the first attempt succeeds (no retry, no sleep)' {
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        Mock -ModuleName Test.PoolAdmin Start-Sleep { }
        $rc = & (Get-Module Test.PoolAdmin) {
            param($Budget, $Delay)
            Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', 'x', 'fetch', '--quiet', 'origin') -Label 'git fetch' -BudgetSeconds $Budget -DelaySeconds $Delay
        } 30 1
        $rc | Should -Be 0
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 1 -Exactly -Scope It
        Assert-MockCalled -ModuleName Test.PoolAdmin Start-Sleep -Times 0 -Exactly -Scope It
    }
    It 'retries a transient failure and returns 0 once the next attempt succeeds' {
        $env:POOLADMIN_GIT_ATTEMPTS = '0'
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit {
            $n = [int]$env:POOLADMIN_GIT_ATTEMPTS + 1
            $env:POOLADMIN_GIT_ATTEMPTS = "$n"
            if ($n -lt 2) { 128 } else { 0 }
        }
        Mock -ModuleName Test.PoolAdmin Start-Sleep { }
        try {
            $rc = & (Get-Module Test.PoolAdmin) {
                param($Budget, $Delay)
                Invoke-PoolAdminGitWithRetry -ArgumentList @('-C', 'x', 'push', '--quiet', 'origin', 'HEAD:main') -Label 'git push' -BudgetSeconds $Budget -DelaySeconds $Delay
            } 30 1
            $rc | Should -Be 0
            Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 2 -Exactly -Scope It
            Assert-MockCalled -ModuleName Test.PoolAdmin Start-Sleep -Times 1 -Exactly -Scope It
        } finally { Remove-Item Env:\POOLADMIN_GIT_ATTEMPTS -ErrorAction SilentlyContinue }
    }
    It 'gives up with the failing exit code once the wall-clock budget is spent (bounded, real backoff)' {
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 128 }
        $rc = & (Get-Module Test.PoolAdmin) {
            param($Budget, $Delay)
            Invoke-PoolAdminGitWithRetry -ArgumentList @('clone', '--quiet', 'url', 'dir') -Label 'git clone' -BudgetSeconds $Budget -DelaySeconds $Delay
        } 2 1
        $rc | Should -Be 128
        # >=2 attempts proves it retried; the test returning at all proves the
        # deadline bounds the loop (a budget-blind retry would spin forever).
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Times 2 -Scope It
    }
}

Describe 'CI gate marks pools.yml required and admin git ops route through retry (AST)' {
    It 'Test-PoolIntent.ps1 defines no local intent-file validator (delegates to the module)' {
        (Get-FunctionDefCount -Ast (Get-FileAst $poolIntentPs1) -Name 'Test-OneIntentFile') | Should -Be 0
    }
    It 'Test-PoolIntent.ps1 marks exactly the pools.yml check -Required' {
        $calls = Get-CommandInvocation -Ast (Get-FileAst $poolIntentPs1) -Name 'Test-YurunaPoolIntentFile'
        $calls.Count | Should -BeGreaterOrEqual 2
        $required = @($calls | Where-Object { Test-CallHasSwitch -Call $_ -SwitchName 'Required' })
        $required.Count | Should -Be 1
        $required[0].Extent.Text | Should -Match 'pools\.yml'
    }
    It 'Test.PoolAdmin.psm1 routes ONLY the network ops (fetch/clone/push) through the retry wrapper' {
        $ast = Get-FileAst $adminPath
        (Get-FunctionDefCount -Ast $ast -Name 'Invoke-PoolAdminGitWithRetry') | Should -BeGreaterOrEqual 1
        $wrapped = Get-CommandInvocation -Ast $ast -Name 'Invoke-PoolAdminGitWithRetry'
        $direct  = Get-CommandInvocation -Ast $ast -Name 'Invoke-PoolSyncGit'
        $wrapped.Count | Should -BeGreaterOrEqual 3
        # Idempotent network ops retry; local ops must NOT (a retry there cannot clear
        # a real repo-state error and would only mask it). Assert op identities, not a
        # bare count, so wrapping a local op or unwrapping a network op is caught.
        foreach ($op in 'fetch', 'clone', 'push') {
            (Test-AnyExtentMatch -Nodes $wrapped -Pattern "'$op'") | Should -Be $true
            (Test-AnyExtentMatch -Nodes $direct  -Pattern "'$op'") | Should -Be $false
        }
        # merge-base + rebase are LOCAL ops: retrying a rebase could re-enter a
        # half-applied rebase, so they must stay direct like add/commit/reset/diff.
        foreach ($op in 'add', 'commit', 'reset', 'diff', 'merge-base', 'rebase') {
            (Test-AnyExtentMatch -Nodes $direct  -Pattern "'$op'") | Should -Be $true
            (Test-AnyExtentMatch -Nodes $wrapped -Pattern "'$op'") | Should -Be $false
        }
    }
}

Describe 'Open-YurunaPoolIntent refuses to reset --hard over unpushed local commits' {
    It 'returns Ok=$false and does NOT reset when the clone is local-ahead (merge-base --is-ancestor = 1)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { param($LiteralPath) $LiteralPath -notlike '*rebase-*' }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { if ($ArgumentList -contains 'merge-base') { 1 } else { 0 } }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $false
        $r.Error | Should -Match 'refusing to reset'
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
    It 'proceeds with the reset when HEAD is contained in FETCH_HEAD (merge-base = 0)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { param($LiteralPath) $LiteralPath -notlike '*rebase-*' }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $true
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
    It 'returns Ok=$false and does NOT reset when a rebase is in progress (mid-rebase clone)' {
        Mock -ModuleName Test.PoolAdmin Test-Path { $true }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolAdminGitWithRetry { 0 }
        Mock -ModuleName Test.PoolAdmin Invoke-PoolSyncGit { 0 }
        $r = Open-YurunaPoolIntent -IntentGitUrl 'https://example/intent' -IntentDir 'TestDrive:\intent' -Confirm:$false
        $r.Ok | Should -Be $false
        $r.Error | Should -Match 'unfinished rebase'
        Assert-MockCalled -ModuleName Test.PoolAdmin Invoke-PoolSyncGit -Scope It -Times 0 -Exactly -ParameterFilter { $ArgumentList -contains 'reset' }
    }
}

# Drop the portability shim so it does not leak into a later suite sharing this session.
if ($script:yamlShimmed) { Remove-Item Function:\ConvertFrom-Yaml -Force -ErrorAction SilentlyContinue }
