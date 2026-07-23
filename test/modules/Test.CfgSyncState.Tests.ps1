<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42e1f2a3-b4c5-4d67-89ab-ce2f3a4b5c63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config sync state hostid pester
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
    Get-YurunaHostId persists the host UUID with create-exclusive atomicity (one id
    per host under concurrent first use, $null on a genuine persist failure), and
    Update-TestConfigFromTemplate rewrites test.config.yml through the atomic
    Write-YurunaStateFile primitive.
.DESCRIPTION
    Behavioral tests for Get-YurunaHostId (Test.YurunaDir); AST guards for the
    create-exclusive Move and for the atomic config-rewrite routing in
    Test.ConfigSync. The throw-free Should assertions run under Pester 4.10.1.
#>

$here        = Split-Path -Parent $PSCommandPath
$yurunaDir   = Join-Path $here 'Test.YurunaDir.psm1'
$configSync  = Join-Path $here 'Test.ConfigSync.psm1'
Import-Module $yurunaDir -Force -ErrorAction SilentlyContinue

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
# Count [<TypePattern>]::<Member>(...) static invocations with exactly $ArgCount args
# (-1 = any). The two-arg [IO.File]::Move fails if the destination exists (the
# create-exclusive claim); a 3-arg Move(src,dest,$true) would overwrite instead.
function Get-StaticInvokeCount {
    param($Ast, [string]$TypePattern, [string]$Member, [int]$ArgCount = -1)
    $tp = $TypePattern; $m = $Member; $ac = $ArgCount
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq $m -and $n.Expression.Extent.Text -match $tp -and
        ($ac -lt 0 -or (@($n.Arguments).Count -eq $ac))
    }, $true)).Count
}
function Get-CommandWithTextCount {
    param($Ast, [string]$Name, [string]$Text)
    $n = $Name; $t = $Text
    @($Ast.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq $n -and $node.Extent.Text.Contains($t)
    }, $true)).Count
}
# Count WriteAllText(...) invocations whose FIRST argument is the given variable text.
# The create-exclusive write targets a per-process temp, never $uuidFile directly; an
# overwrite would write $uuidFile and re-key the host under a concurrent generator.
function Get-WriteAllTextTargetCount {
    param($Ast, [string]$TargetVar)
    $tv = $TargetVar
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'WriteAllText' -and (@($n.Arguments).Count -ge 1) -and
        (@($n.Arguments)[0].Extent.Text -eq $tv)
    }, $true)).Count
}
# `return $id` reachable from a catch would hand back a non-persisted id after a
# failed write; the write-failure path must return $null so the caller does not
# key the host to an id that never reached disk.
function Get-ReturnIdInCatchCount {
    param($Ast)
    $count = 0
    foreach ($catch in @($Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CatchClauseAst] }, $true))) {
        $count += @($catch.Body.FindAll({ param($m)
            $m -is [System.Management.Automation.Language.ReturnStatementAst] -and
            $m.Pipeline -and $m.Pipeline.Extent.Text -eq '$id'
        }, $true)).Count
    }
    $count
}

Describe 'Get-YurunaHostId persists a stable host UUID atomically' {
    BeforeEach {
        $script:root  = Join-Path $env:TEMP ('hostid-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:saved = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:root
    }
    AfterEach {
        $env:YURUNA_RUNTIME_DIR = $script:saved
        if (Test-Path -LiteralPath $script:root) { [System.IO.Directory]::Delete($script:root, $true) }
    }
    It 'generates a 42-prefixed id, persists it, and is idempotent' {
        $first = Get-YurunaHostId
        $first | Should -Match '^42[0-9a-f]{30}$'
        (Test-Path -LiteralPath (Join-Path $script:root 'host.uuid')) | Should -Be $true
        Get-YurunaHostId | Should -Be $first
    }
    It 'adopts an existing host.uuid instead of regenerating' {
        $existing = '42deadbeefdeadbeefdeadbeefdeadb'
        [System.IO.File]::WriteAllText((Join-Path $script:root 'host.uuid'), $existing)
        Get-YurunaHostId | Should -Be $existing
    }
    It 'concurrent callers agree on one id (cross-process smoke)' {
        # Smoke-level: Start-Job processes stagger, so the first usually persists
        # host.uuid and the rest adopt it via the read fast-path -- a tight first-write
        # race is rarely hit. The create-exclusive convergence itself is the load-bearing
        # claim, pinned by the two-arg-Move / no-WriteAllText-of-$uuidFile AST guards below.
        $r = $script:root; $mp = $yurunaDir
        $jobs = 1..5 | ForEach-Object {
            Start-Job -ScriptBlock {
                $env:YURUNA_RUNTIME_DIR = $using:r
                Import-Module $using:mp -Force
                Get-YurunaHostId
            }
        }
        $results = @($jobs | Wait-Job -Timeout 90 | Receive-Job)
        $jobs | Remove-Job -Force
        $results.Count                            | Should -Be 5
        (@($results | Sort-Object -Unique)).Count | Should -Be 1
    }
    It 'returns $null when the runtime dir cannot be resolved' {
        Mock -ModuleName Test.YurunaDir Initialize-YurunaRuntimeDir { $null }
        Get-YurunaHostId | Should -BeNullOrEmpty
    }
    It 'returns $null (never a non-persisted id) from a write-failure catch' {
        (Get-ReturnIdInCatchCount -Ast (Get-FileAst $yurunaDir)) | Should -Be 0
    }
    It 'writes host.uuid via a two-arg [System.IO.File]::Move (create-exclusive), not an overwrite' {
        (Get-StaticInvokeCount -Ast (Get-FileAst $yurunaDir) -TypePattern 'System\.IO\.File' -Member 'Move' -ArgCount 2) | Should -BeGreaterOrEqual 1
    }
    It 'never writes the destination host.uuid directly (the temp is written, then renamed)' {
        (Get-WriteAllTextTargetCount -Ast (Get-FileAst $yurunaDir) -TargetVar '$uuidFile') | Should -Be 0
    }
}

Describe 'Update-TestConfigFromTemplate rewrites test.config.yml atomically (AST)' {
    It 'never writes the config path with a non-atomic Set-Content' {
        (Get-CommandWithTextCount -Ast (Get-FileAst $configSync) -Name 'Set-Content' -Text '$ConfigPath') | Should -Be 0
    }
    It 'routes every config rewrite through the atomic Write-YurunaStateFile' {
        (Get-CommandWithTextCount -Ast (Get-FileAst $configSync) -Name 'Write-YurunaStateFile' -Text '$ConfigPath') | Should -BeGreaterOrEqual 3
    }
    It 'resolves Write-YurunaStateFile when only Test.ConfigSync is imported (self-loads its dependency)' {
        # The rewrite routes through Write-YurunaStateFile (Test.StateFile). Every consumer
        # of Test.ConfigSync -- including the operator validator Test-Config.ps1, which does
        # not load the full runner set -- must have that primitive in scope, so the module
        # imports it itself. Guard against a future top-level import removal.
        Get-Module Test.StateFile, Test.ConfigSync | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $configSync -Force -DisableNameChecking
        (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}
