<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c9d0e1-f2a3-4b45-9789-ac0d1e2f3a41
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic fallback pester
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
    Guards that Save-GuestDiagnostic keeps the fuller failed-rung capture for the
    all-rungs-failed fallback manifest, not merely the first rung that produced
    output.
.DESCRIPTION
    Behavioral tests exercise the module-private Select-MoreInformativeDiagResult
    picker in module scope (so a private helper stays private). In the running
    function only the two SSH rungs carry .output; the console rung POSTs its
    capture to disk and returns output='', so it is never a picker candidate. AST
    guards pin that the fallback selection never inspects $lastResult.output and
    that every rung routes through the picker. The throw-free Should assertions
    run under Pester 4.10.1.
#>

$here    = Split-Path -Parent $PSCommandPath
$modPath = Join-Path $here 'Test.Diagnostic.psm1'
Import-Module $modPath -Force

# Invoke the module-private picker in the module's own scope so it is visible.
function Invoke-DiagPicker {
    param($Current, $Candidate)
    & (Get-Module Test.Diagnostic) {
        param($c, $cand)
        Select-MoreInformativeDiagResult -Current $c -Candidate $cand
    } $Current $Candidate
}

# --- REGION: AST helpers (script scope; referenced from It blocks -> Pester 4)
function Get-DiagModuleAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modPath): $($errs[0].Message)" }
    return $ast
}
function Get-LastResultOutputReadCount {
    # Reads of $lastResult.output would let a rung's own output length gate the
    # fallback choice, which is the picker's job; the fallback assigns
    # $result = $lastResult bare and reads $result.output, so this count is 0.
    @((Get-DiagModuleAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $n.Member.Extent.Text -eq 'output' -and $n.Expression.Extent.Text -eq '$lastResult'
    }, $true)).Count
}
function Get-PickerInvokeCount {
    @((Get-DiagModuleAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Select-MoreInformativeDiagResult'
    }, $true)).Count
}
function Get-PickerDefCount {
    @((Get-DiagModuleAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq 'Select-MoreInformativeDiagResult'
    }, $true)).Count
}

Describe 'Select-MoreInformativeDiagResult keeps the fuller failed-rung capture' {
    It 'keeps the rung that captured more error text' {
        # Only the two SSH rungs (key-ssh, password-ssh) ever reach the picker
        # with real output; they are ranked by captured length.
        $r = Invoke-DiagPicker -Current @{ output = 'short'; mechanism = 'key' } `
            -Candidate @{ output = 'a much longer password-ssh capture'; mechanism = 'password' }
        $r.mechanism | Should -Be 'password'
    }
    It 'keeps the incumbent when the candidate captured less (rung order is not information order)' {
        $r = Invoke-DiagPicker -Current @{ output = 'a much longer key-ssh capture'; mechanism = 'key' } `
            -Candidate @{ output = 'short'; mechanism = 'password' }
        $r.mechanism | Should -Be 'key'
    }
    It 'keeps the incumbent on an equal-length tie (no churn)' {
        $r = Invoke-DiagPicker -Current @{ output = 'abcde'; mechanism = 'key' } `
            -Candidate @{ output = '12345'; mechanism = 'password' }
        $r.mechanism | Should -Be 'key'
    }
    It 'ignores the console rung, whose capture goes to disk and leaves output empty' {
        # Invoke-RemoteDiagnosticsConsole returns output='' by design, so its
        # candidate must never displace a real SSH capture in the manifest.
        $r = Invoke-DiagPicker -Current @{ output = 'ssh error text'; mechanism = 'key' } `
            -Candidate @{ output = ''; mechanism = 'console' }
        $r.mechanism | Should -Be 'key'
    }
    It 'keeps the incumbent when both rungs captured nothing (empty candidate not adopted)' {
        $r = Invoke-DiagPicker -Current @{ output = ''; mechanism = 'key' } `
            -Candidate @{ output = ''; mechanism = 'password' }
        $r.mechanism | Should -Be 'key'
    }
    It 'adopts the candidate when the incumbent captured nothing yet' {
        $r = Invoke-DiagPicker -Current @{ output = ''; mechanism = 'key' } `
            -Candidate @{ output = 'password-ssh text'; mechanism = 'password' }
        $r.mechanism | Should -Be 'password'
    }
    It 'adopts the candidate when there is no incumbent' {
        $r = Invoke-DiagPicker -Current $null `
            -Candidate @{ output = 'key-ssh text'; mechanism = 'key' }
        $r.mechanism | Should -Be 'key'
    }
    It 'returns nothing when neither rung produced a result' {
        Invoke-DiagPicker -Current $null -Candidate $null | Should -BeNullOrEmpty
    }
}

Describe 'Save-GuestDiagnostic routes every rung through the informativeness picker' {
    It 'the fallback selection never inspects $lastResult.output directly' {
        Get-LastResultOutputReadCount | Should -Be 0
    }
    It 'invokes the picker once per rung (key-ssh, password-ssh, console)' {
        Get-PickerInvokeCount | Should -BeGreaterOrEqual 3
    }
    It 'defines the picker helper' {
        Get-PickerDefCount | Should -BeGreaterOrEqual 1
    }
}
