<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a1b2c3-d4e5-4f67-8901-9c0d1e2f3a58
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test start-guest dispatcher dedup pester
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
    Start-GuestOS and Start-GuestWorkload run their sequence list through one shared
    Invoke-GuestSequenceList (in Invoke-Sequence), differing only in the failure
    message's phase label; both preserve the empty->skipped, pass->success, and
    fail->error-with-label behavior.
.DESCRIPTION
    Behavioral tests exercise both exported cmdlets with Invoke-SequenceByName mocked --
    empty/pass/fail, the phase-labelled and step-location failure messages, the mtime
    gate rejecting a stale sidecar, the mid-chain rename retarget, and value-level
    EffectiveVariables forwarding. AST guards assert the loop is defined once in
    Invoke-Sequence and that each dispatcher delegates to it rather than running
    Invoke-SequenceByName inline. Pester 4.10.1.
#>

$here = Split-Path -Parent $PSCommandPath

function Get-FileAst {
    param([string]$Path)
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
}
function Get-CallCount {
    param($Ast, [string]$Name)
    $wm = $Name
    @($Ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $wm
    }, $true)).Count
}
# Unqualified file-scope variables: inside an It block a $script: reference resolves to the
# test runner's own script scope, not this file's, so a $script:-qualified AST reaches the
# structural guards as $null.
$engineAst = Get-FileAst (Join-Path $here 'Invoke-Sequence.psm1')
$osAst     = Get-FileAst (Join-Path $here 'Test.Start-GuestOS.psm1')
$wlAst     = Get-FileAst (Join-Path $here 'Test.Start-GuestWorkload.psm1')

Describe 'ha-startguest: the dispatcher loop is shared, not duplicated' {
    BeforeAll {
        Get-Module Test.Start-GuestOS, Test.Start-GuestWorkload, Invoke-Sequence, Test.YurunaDir |
            Remove-Module -Force -ErrorAction SilentlyContinue
        Import-Module (Join-Path $here 'Test.YurunaDir.psm1')          -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Invoke-Sequence.psm1')         -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Start-GuestOS.psm1')      -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Start-GuestWorkload.psm1') -Force -Global -DisableNameChecking
    }

    # Each scenario is its own Context so Pester 4 clears its mocks at the boundary --
    # behavioral isolation without relying on later-mock-wins override semantics.
    Context 'an empty sequence list' {
        It '<Cmd> returns success/skipped' -TestCases @(
            @{ Cmd = 'Start-GuestOS' }, @{ Cmd = 'Start-GuestWorkload' }
        ) {
            param($Cmd)
            $r = & $Cmd -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @()
            $r.success | Should -BeTrue
            $r.skipped | Should -BeTrue
        }
    }

    Context 'a passing sequence' {
        It '<Cmd> returns success (not skipped)' -TestCases @(
            @{ Cmd = 'Start-GuestOS' }, @{ Cmd = 'Start-GuestWorkload' }
        ) {
            param($Cmd)
            foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestOS', 'Test.Start-GuestWorkload') {
                Mock Invoke-SequenceByName    -ModuleName $m { $true }
                Mock Get-SequenceFinishedVMName -ModuleName $m { $null }
            }
            $r = & $Cmd -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seq1')
            $r.success | Should -BeTrue
            $r.skipped | Should -BeFalse
        }
    }

    Context 'the generic failure message carries the caller phase label' {
        It 'Start-GuestOS uses the "Start" label' {
            foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestOS') {
                Mock Invoke-SequenceByName    -ModuleName $m { $false }
                Mock Initialize-YurunaLogDir  -ModuleName $m { Join-Path $env:TEMP ('nolog-' + [guid]::NewGuid().ToString('N')) }
            }
            $r = Start-GuestOS -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seqX')
            $r.success      | Should -BeFalse
            $r.errorMessage | Should -Be "Start sequence 'seqX' failed"
        }
        It 'Start-GuestWorkload uses the "Workload" label' {
            foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestWorkload') {
                Mock Invoke-SequenceByName    -ModuleName $m { $false }
                Mock Initialize-YurunaLogDir  -ModuleName $m { Join-Path $env:TEMP ('nolog-' + [guid]::NewGuid().ToString('N')) }
            }
            $r = Start-GuestWorkload -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seqY')
            $r.success      | Should -BeFalse
            $r.errorMessage | Should -Be "Workload sequence 'seqY' failed"
        }
    }

    Context 'a sidecar written during the sequence promotes the message to the step location' {
        It 'formats "Step [n/total] action - description" from a fresh last_failure.json' {
            $script:halog = Join-Path $env:TEMP ('halog-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:halog -Force | Out-Null
            $payload = [ordered]@{
                stepNumber = 3; totalSteps = 7
                action = 'TypeText'; description = 'enter the admin password'
            } | ConvertTo-Json
            Set-Content -LiteralPath (Join-Path $script:halog 'last_failure.json') -Value $payload -Encoding utf8
            # A -ModuleName mock body runs in that module's session state, so a test-scope
            # $script: var is $null there; bake the path in as a literal instead.
            $logMock = [scriptblock]::Create("'" + ($script:halog -replace "'", "''") + "'")
            try {
                foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestOS') {
                    Mock Initialize-YurunaLogDir -ModuleName $m $logMock
                    Mock Invoke-SequenceByName   -ModuleName $m { $false }
                }
                $r = Start-GuestOS -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seqX')
                $r.success      | Should -BeFalse
                $r.errorMessage | Should -Be "Step [3/7] TypeText - enter the admin password (sequence: seqX)"
            } finally {
                Remove-Item -LiteralPath $script:halog -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        It 'keeps the generic message when the sidecar predates the sequence (mtime gate)' {
            $script:hastale = Join-Path $env:TEMP ('hastale-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:hastale -Force | Out-Null
            $stale = Join-Path $script:hastale 'last_failure.json'
            $payload = [ordered]@{ stepNumber = 9; totalSteps = 9; action = 'Reboot'; description = 'stale run' } | ConvertTo-Json
            Set-Content -LiteralPath $stale -Value $payload -Encoding utf8
            (Get-Item -LiteralPath $stale).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-10)
            $logMock = [scriptblock]::Create("'" + ($script:hastale -replace "'", "''") + "'")
            try {
                foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestWorkload') {
                    Mock Initialize-YurunaLogDir -ModuleName $m $logMock
                    Mock Invoke-SequenceByName   -ModuleName $m { $false }
                }
                $r = Start-GuestWorkload -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seqZ')
                $r.errorMessage | Should -Be "Workload sequence 'seqZ' failed"
            } finally {
                Remove-Item -LiteralPath $script:hastale -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'a mid-chain saveDiskSnapshot rename retargets the next sequence' {
        It 'runs the following sequence against the renamed VM' {
            foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestOS') {
                Mock Invoke-SequenceByName     -ModuleName $m { $true }
                Mock Get-SequenceFinishedVMName -ModuleName $m { 'vm-renamed' }
            }
            $r = Start-GuestOS -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seq1', 'seq2')
            $r.success | Should -BeTrue
            Assert-MockCalled Invoke-SequenceByName -ModuleName 'Invoke-Sequence' -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'seq2' -and $VMName -eq 'vm-renamed'
            }
        }
    }

    Context 'the caller variable overrides reach Invoke-SequenceByName' {
        It 'forwards EffectiveVariables and the sequence name through the delegation' {
            foreach ($m in 'Invoke-Sequence', 'Test.Start-GuestWorkload') {
                Mock Invoke-SequenceByName     -ModuleName $m { $true }
                Mock Get-SequenceFinishedVMName -ModuleName $m { $null }
            }
            $vars = [ordered]@{ username = 'yuser1'; currentPassword = 'p@ss' }
            $r = Start-GuestWorkload -HostType h -GuestKey g -VMName vm -RepoRoot r -SequencesDir s -SequenceNames @('seq1') -EffectiveVariables $vars
            $r.success | Should -BeTrue
            Assert-MockCalled Invoke-SequenceByName -ModuleName 'Invoke-Sequence' -Times 1 -Exactly -ParameterFilter {
                $Name -eq 'seq1' -and $EffectiveVariables['username'] -eq 'yuser1' -and $EffectiveVariables['currentPassword'] -eq 'p@ss'
            }
        }
    }

    Context 'structure: one definition, both delegate (AST)' {
        It 'Invoke-Sequence defines Invoke-GuestSequenceList exactly once' {
            @($engineAst.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-GuestSequenceList'
            }, $true)).Count | Should -Be 1
        }
        It '<File> delegates to Invoke-GuestSequenceList and runs no inline Invoke-SequenceByName loop' -TestCases @(
            @{ File = 'Start-GuestOS' }, @{ File = 'Start-GuestWorkload' }
        ) {
            param($File)
            $ast = if ($File -eq 'Start-GuestOS') { $osAst } else { $wlAst }
            (Get-CallCount -Ast $ast -Name 'Invoke-GuestSequenceList') | Should -BeGreaterOrEqual 1
            (Get-CallCount -Ast $ast -Name 'Invoke-SequenceByName')    | Should -Be 0
        }
    }
}
