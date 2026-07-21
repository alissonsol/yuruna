<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42b8c9d0-e1f2-4a34-9678-9b0c1d2e3f40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool sync membership pester
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
    Guards on pool-sync invariants: Resolve-YurunaPoolForHost normalizes members[] and
    matches ordinal-exact, a no-match-with-members warning is wired in, and the
    fetch+reset pull is bounded by one wall-clock deadline.
.DESCRIPTION
    Behavioral tests for the pure lookup helpers; AST guards for the git deadline and
    the warning wiring in Sync-YurunaPoolIntent (which does git + file I/O and is not
    unit-invoked here). The throw-free Should assertions run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.PoolSync.psm1'
Import-Module $modPath -Force

# Unqualified and above the first Describe: an It block resolves a plain file-scope
# name through its parent scope chain, but a $script:-qualified one binds to the test
# framework's own script scope and reads back $null once the run phase starts.
$TestHostId = '42abcdef0123456789abcdef01234567'.Substring(0, 32)

# --- REGION: AST helpers (file scope; referenced from It blocks)
function Get-ModuleAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
    return $ast
}
function Get-AssignmentCount {
    param($Ast, [string]$Lhs)
    $wl = $Lhs
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $wl
    }, $true)).Count
}
function Get-CommandInvokeCount {
    param($Ast, [string]$Name)
    $wanted = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wanted
    }, $true)).Count
}
function Get-MemberAccessCount {
    param($Ast, [string]$Member)
    $wm = $Member
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -eq $wm
    }, $true)).Count
}

Describe 'Resolve-YurunaPoolForHost normalizes members and matches ordinal-exact' {
    It 'matches a bare-string member' {
        $intent = @{ pools = @(@{ poolId = 'p1'; members = @($TestHostId, '42other') }) }
        (Resolve-YurunaPoolForHost -Intent $intent -HostId $TestHostId).poolId | Should -Be 'p1'
    }
    It 'matches a structured member carrying a hostId key' {
        $intent = @{ pools = @(@{ poolId = 'p2'; members = @(@{ hostId = $TestHostId; name = 'n' }) }) }
        (Resolve-YurunaPoolForHost -Intent $intent -HostId $TestHostId).poolId | Should -Be 'p2'
    }
    It 'matches a structured member carrying a name key' {
        $intent = @{ pools = @(@{ poolId = 'p3'; members = @(@{ name = $TestHostId }) }) }
        (Resolve-YurunaPoolForHost -Intent $intent -HostId $TestHostId).poolId | Should -Be 'p3'
    }
    It 'does NOT match a differently-cased member (ordinal-exact identity)' {
        $intent = @{ pools = @(@{ poolId = 'p4'; members = @($TestHostId.ToUpper()) }) }
        Resolve-YurunaPoolForHost -Intent $intent -HostId $TestHostId | Should -BeNullOrEmpty
    }
    It 'returns $null when no member matches' {
        $intent = @{ pools = @(@{ poolId = 'p5'; members = @('42someoneelse') }) }
        Resolve-YurunaPoolForHost -Intent $intent -HostId $TestHostId | Should -BeNullOrEmpty
    }
}

Describe 'Test-PoolIntentHasMember distinguishes populated from empty membership' {
    It 'is true when a pool lists at least one member' {
        (Test-PoolIntentHasMember -Intent @{ pools = @(@{ poolId = 'p'; members = @('42x') }) }) | Should -Be $true
    }
    It 'is false when every pool has an empty members list' {
        (Test-PoolIntentHasMember -Intent @{ pools = @(@{ poolId = 'p'; members = @() }) }) | Should -Be $false
    }
    It 'is false when the intent has no pools' {
        (Test-PoolIntentHasMember -Intent @{ }) | Should -Be $false
    }
}

Describe 'Sync-YurunaPoolIntent bounds the pull by one deadline and surfaces failures' {
    It 'derives the fetch and reset budgets from a single $deadlineUtc' {
        $ast = Get-ModuleAst
        (Get-AssignmentCount -Ast $ast -Lhs '$deadlineUtc') | Should -BeGreaterOrEqual 1
        (Get-AssignmentCount -Ast $ast -Lhs '$fetchBudget') | Should -BeGreaterOrEqual 1
        (Get-AssignmentCount -Ast $ast -Lhs '$resetBudget') | Should -BeGreaterOrEqual 1
    }
    It 'reads PullTimeoutSec once (to seed the deadline), not once per git call' {
        # A per-call PullTimeoutSec hands each of fetch and reset a fresh full budget, so
        # the pair can run to ~2x the intended wall-clock bound; reading it once forces
        # both to derive their timeout from one shared deadline.
        (Get-MemberAccessCount -Ast (Get-ModuleAst) -Member 'PullTimeoutSec') | Should -Be 1
    }
    It 'classifies the failing git rc for the warning (timeout vs a real error)' {
        (Get-AssignmentCount -Ast (Get-ModuleAst) -Lhs '$why') | Should -BeGreaterOrEqual 1
    }
    It 'warns when the host is absent from a populated members[] (wired via Test-PoolIntentHasMember)' {
        (Get-CommandInvokeCount -Ast (Get-ModuleAst) -Name 'Test-PoolIntentHasMember') | Should -BeGreaterOrEqual 1
    }
    It 'passes a shrinking budget to fetch then reset, both bounded by one PullTimeoutSec' {
        # Behavioral guard for the shared deadline: burn ~1.2s inside the fetch call so
        # the reset budget -- derived from the SAME deadline -- is strictly smaller than
        # the fetch budget. fetch is computed at deadline-set so it is the full 5s; reset
        # is <= 4s. A reset budget re-inflated to a full/literal value (bypassing the
        # deadline) would fail the reset filter's upper bound.
        $tmp = Join-Path $env:TEMP ('poolsync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path (Join-Path $tmp '.git') -Force | Out-Null
        $shimmed = $false
        try {
            if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
                function global:ConvertFrom-Yaml { }
                $shimmed = $true
            }
            Mock -ModuleName Test.PoolSync Invoke-PoolSyncGit {
                if ($ArgumentList -contains 'fetch') { Start-Sleep -Milliseconds 1200 }
                return 0
            }
            Mock -ModuleName Test.PoolSync Write-YurunaPoolState { $true }
            Mock -ModuleName Test.PoolSync Write-YurunaPoolManifest { $true }
            $cfg = @{ pool = @{ enabled = $true; intentGitUrl = 'http://localhost/x.git'; localClonePath = $tmp; pullTimeoutSeconds = 5 } }
            $null = Sync-YurunaPoolIntent -Config $cfg -HostId '42none000000000000000000000000'
            Assert-MockCalled -ModuleName Test.PoolSync Invoke-PoolSyncGit -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'fetch') -and $TimeoutSeconds -eq 5
            }
            Assert-MockCalled -ModuleName Test.PoolSync Invoke-PoolSyncGit -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'reset') -and $TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 4
            }
        } finally {
            if ($shimmed) { Remove-Item function:\ConvertFrom-Yaml -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $tmp) { [System.IO.Directory]::Delete($tmp, $true) }
        }
    }
}
