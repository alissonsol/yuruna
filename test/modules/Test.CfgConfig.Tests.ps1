<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42f3a4b5-c6d7-4e89-9a0b-cd2e3f4a5b64
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config validator cache snapshot pester
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
    The Read-TestConfig cache uses an Ordinal (case-sensitive) key comparer and is
    FIFO-bounded; the config snapshot has one slot per source (the whole resolved path
    is hashed, namespaced per-user in the shared temp); and Test-AgainstSchema parses
    through Read-TestConfig, self-loading it and keeping its fail-soft contract.
.DESCRIPTION
    Behavioral tests exercise the exported cache/snapshot surface (Ordinal collision,
    FIFO eviction past the cap, per-source + per-user snapshot slots, fail-soft
    validation); AST guards pin the bound comparison node and the validator routing.
    The throw-free Should assertions run under Pester 4.10.1.
#>

$here         = Split-Path -Parent $PSCommandPath
$configMod    = Join-Path $here 'Test.Config.psm1'
$validatorMod = Join-Path $here 'Test.ConfigValidator.psm1'
Import-Module $configMod -Force
if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
}

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true)).Count
}
function Get-BoundComparisonCount {
    # A real "-gt" comparison node whose left is the order-list Count and right is the cap,
    # so a match in a comment or string literal cannot satisfy it.
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $n.Operator -eq [System.Management.Automation.Language.TokenKind]::Igt -and
        $n.Left.Extent.Text -like '*TestConfigCacheOrder*Count*' -and
        $n.Right.Extent.Text -like '*TestConfigCacheMax*'
    }, $true)).Count
}

Describe 'Read-TestConfig cache is case-sensitive (Ordinal) and FIFO-bounded' {
    It 'keys the cache with an Ordinal comparer (case-distinct paths do not collide)' {
        # The default @{} literal is case-insensitive: 'x' and 'X' would collapse to one
        # slot, which on a case-sensitive filesystem is two different files.
        $count = & (Get-Module Test.Config) {
            Clear-TestConfigCache -Confirm:$false
            try {
                $script:TestConfigCache['x'] = 1
                $script:TestConfigCache['X'] = 2
                $script:TestConfigCache.Count
            } finally { Clear-TestConfigCache -Confirm:$false }
        }
        $count | Should -Be 2
    }

    It 'evicts the oldest entries first (FIFO) and holds the cache at the cap' {
        $saved = $env:YURUNA_RUNTIME_DIR
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("cfgc-fifo-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            # Point the snapshot writes at the disposable dir too, so the whole run cleans up.
            $env:YURUNA_RUNTIME_DIR = $root
            $max = & (Get-Module Test.Config) { $script:TestConfigCacheMax }
            & (Get-Module Test.Config) { Clear-TestConfigCache -Confirm:$false }
            $paths = New-Object System.Collections.Generic.List[string]
            for ($i = 0; $i -lt ($max + 2); $i++) {
                $f = Join-Path $root ("c$i.yml")
                Set-Content -LiteralPath $f -Value "k: $i" -Encoding utf8
                $paths.Add((Resolve-Path -LiteralPath $f).Path)
                Read-TestConfig -Path $f | Out-Null
            }
            $state = & (Get-Module Test.Config) {
                [pscustomobject]@{
                    Count      = $script:TestConfigCache.Count
                    OrderCount = $script:TestConfigCacheOrder.Count
                    Keys       = @($script:TestConfigCache.Keys)
                    OrderFront = $script:TestConfigCacheOrder[0]
                }
            }
            $state.Count      | Should -Be $max
            $state.OrderCount | Should -Be $max
            $state.Keys | Should -Not -Contain $paths[0]   # oldest evicted
            $state.Keys | Should -Not -Contain $paths[1]
            $state.Keys | Should -Contain $paths[$paths.Count - 1]   # newest survives
            $state.OrderFront | Should -Be $paths[2]        # front is now the third-inserted
        } finally {
            $env:YURUNA_RUNTIME_DIR = $saved
            & (Get-Module Test.Config) { Clear-TestConfigCache -Confirm:$false }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'bounds the cache with a real order.Count -gt max comparison node' {
        (Get-BoundComparisonCount -Ast (Get-FileAst $configMod)) | Should -BeGreaterOrEqual 1
    }
}

Describe 'Get-TestConfigSnapshotPath is one slot per source, per-user in shared temp' {
    It 'gives distinct configs distinct snapshot slots' {
        $a = Get-TestConfigSnapshotPath -SourcePath 'C:\x\test.config.yml'
        $b = Get-TestConfigSnapshotPath -SourcePath 'C:\x\vault.yml'
        $a | Should -Not -Be $b
    }
    It 'is deterministic for the same source path' {
        (Get-TestConfigSnapshotPath -SourcePath 'C:\x\test.config.yml') |
            Should -Be (Get-TestConfigSnapshotPath -SourcePath 'C:\x\test.config.yml')
    }
    It 'hashes the whole resolved path, not just the leaf (same filename, different dir -> different slot)' {
        (Get-TestConfigSnapshotPath -SourcePath 'C:\x\vault.yml') |
            Should -Not -Be (Get-TestConfigSnapshotPath -SourcePath 'C:\y\vault.yml')
    }
    It 'uses the runtime dir when YURUNA_RUNTIME_DIR is set' {
        $saved = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = 'C:\rt-xyz'
            (Split-Path -Parent (Get-TestConfigSnapshotPath -SourcePath 'C:\x\test.config.yml')) | Should -Be 'C:\rt-xyz'
        } finally { $env:YURUNA_RUNTIME_DIR = $saved }
    }
    It 'namespaces under the exact per-user temp subdirectory when no runtime dir is set' {
        $saved = $env:YURUNA_RUNTIME_DIR
        $user    = if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { 'nouser' }
        $userTag = [System.Text.RegularExpressions.Regex]::Replace($user, '[^A-Za-z0-9._-]', '_')
        $expectedDir = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-$userTag"
        $preExisted  = Test-Path -LiteralPath $expectedDir
        try {
            $env:YURUNA_RUNTIME_DIR = ''
            (Split-Path -Parent (Get-TestConfigSnapshotPath -SourcePath 'C:\x\test.config.yml')) | Should -Be $expectedDir
        } finally {
            $env:YURUNA_RUNTIME_DIR = $saved
            if (-not $preExisted -and (Test-Path -LiteralPath $expectedDir)) {
                Remove-Item -LiteralPath $expectedDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Test-AgainstSchema parses through the hardened Read-TestConfig' {
    It 'resolves Read-TestConfig when only Test.ConfigValidator is imported (self-loads Test.Config)' {
        Get-Module Test.Config, Test.ConfigValidator, Test.Output, Test.HostGit | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $validatorMod -Force
        (Get-Command Read-TestConfig -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
    It 'invokes Read-TestConfig from the validator module (no separate parse path)' {
        (Get-CommandInvokeCount -Ast (Get-FileAst $validatorMod) -Name 'Read-TestConfig') | Should -BeGreaterOrEqual 1
    }
}

Describe 'Test-AgainstSchema keeps its fail-soft contract through the reader swap' {
    BeforeAll { Import-Module $validatorMod -Force }
    It 'returns without throwing when the YAML file is missing' {
        { Test-AgainstSchema -Label 'x' -YamlPath 'C:\does\not\exist-cfgc.yml' -SchemaPath 'C:\does\not\exist-schema.yml' } |
            Should -Not -Throw
    }
    It 'does not let a non-mapping root escape (Read-TestConfig -ThrowOnError is caught)' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("cfgc-bad-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            $bad    = Join-Path $root 'scalar.yml';  Set-Content -LiteralPath $bad    -Value 'just-a-scalar-string' -Encoding utf8
            $schema = Join-Path $root 'schema.yml';  Set-Content -LiteralPath $schema -Value "type: object"          -Encoding utf8
            { Test-AgainstSchema -Label 'x' -YamlPath $bad -SchemaPath $schema } | Should -Not -Throw
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
