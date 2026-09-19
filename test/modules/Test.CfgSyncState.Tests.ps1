<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4241d9f0-ad34-48bf-acbd-de2cff3f7bf7
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

BeforeAll {
$here        = Split-Path -Parent $PSCommandPath
$yurunaDir   = Join-Path $here 'Test.YurunaDir.psm1'
$script:configSync  = Join-Path $here 'Test.ConfigSync.psm1'
Import-Module $yurunaDir -Force -ErrorAction SilentlyContinue

# --- REGION: https://yuruna.link/42d69dfa-0015
function Get-FileAst {
    param([string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($Path): $($errs[0].Message)" }
    return $ast
}
# Count [<TypePattern>]::<Member>(...) static invocations with exactly $ArgCount args
# (-1 = any).
function Get-StaticInvokeCount {
    param($Ast, [string]$TypePattern, [string]$Member, [int]$ArgCount = -1)
    $tp = $TypePattern; $m = $Member; $ac = $ArgCount
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq $m -and $n.Expression.Extent.Text -match $tp -and
        ($ac -lt 0 -or (@($n.Arguments).Count -eq $ac))
    }, $true)).Count
}
# Count [IO.File]::Open(...) calls that pass FileMode::CreateNew -- the claim that
# host.uuid depends on. Only the create can serve as the lock: it is O_CREAT|O_EXCL
# on POSIX and CREATE_NEW on Windows, so exactly one caller can bring the path into
# existence. A rename cannot stand in for it on POSIX, where [IO.File]::Move tests
# for the destination and then renames -- racers that pass the test together all
# rename successfully, the last one lands on disk, and every earlier one walks away
# with an id that was never persisted.
function Get-CreateExclusiveOpenCount {
    param($Ast)
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'Open' -and
        $n.Expression.Extent.Text -match 'System\.IO\.File' -and
        $n.Extent.Text -match 'FileMode\]::CreateNew'
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

}

Describe 'Get-YurunaHostId persists a stable host UUID atomically' {
    BeforeEach {
        $script:root  = Join-Path ([System.IO.Path]::GetTempPath()) ('hostid-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
        # Start-Job processes usually stagger, so the first persists host.uuid and the
        # rest adopt it via the read fast-path. They do not always stagger, though:
        # when they land together this reaches the real first-write race, which is why
        # the claim has to be create-exclusive rather than a rename. The primitive
        # itself is pinned by the create-exclusive-open / no-WriteAllText-of-$uuidFile
        # AST guards below, which hold whether or not a given run hits the race.
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
    It 'claims host.uuid with a create-exclusive open, never a rename' {
        $hostIdAst = Get-FileAst $yurunaDir
        (Get-CreateExclusiveOpenCount -Ast $hostIdAst) | Should -BeGreaterOrEqual 1
        # A rename would silently re-admit the double-winner: on POSIX it tests for
        # the destination and then renames, so simultaneous racers all succeed.
        (Get-StaticInvokeCount -Ast $hostIdAst -TypePattern 'System\.IO\.File' -Member 'Move') | Should -Be 0
    }
    It 'never writes the destination host.uuid directly (the claim carries the write)' {
        (Get-WriteAllTextTargetCount -Ast (Get-FileAst $yurunaDir) -TargetVar '$uuidFile') | Should -Be 0
    }
}

Describe 'Update-TestConfigFromTemplate rewrites test.config.yml atomically (AST)' {
    It 'never writes the config path with a non-atomic Set-Content' {
        (Get-CommandWithTextCount -Ast (Get-FileAst $script:configSync) -Name 'Set-Content' -Text '$ConfigPath') | Should -Be 0
    }
    It 'routes every config rewrite through the atomic Write-YurunaStateFile' {
        (Get-CommandWithTextCount -Ast (Get-FileAst $script:configSync) -Name 'Write-YurunaStateFile' -Text '$ConfigPath') | Should -BeGreaterOrEqual 3
    }
    It 'resolves Write-YurunaStateFile when only Test.ConfigSync is imported (self-loads its dependency)' {
        # The rewrite routes through Write-YurunaStateFile (Test.StateFile). Every consumer
        # of Test.ConfigSync -- including the operator validator Test-Config.ps1, which does
        # not load the full runner set -- must have that primitive in scope, so the module
        # imports it itself. Guard against a future top-level import removal.
        Get-Module Test.StateFile, Test.ConfigSync | Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module $script:configSync -Force -DisableNameChecking
        (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}
