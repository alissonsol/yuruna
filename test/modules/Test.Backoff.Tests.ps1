<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42f7a8b9-c0d1-4e23-9a45-6b7c8d9e0f13
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test backoff jitter pester
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
    Behavioral + structural guards on Test.Backoff.psm1's Get-PollDelay jitter.
.DESCRIPTION
    Get-PollDelay returns base*1000 ms minus proportional de-sync jitter (up to
    25% of base). The jitter is SUBTRACTED so the delay never exceeds base
    seconds -- preserving the 59 s cap's "wake within a minute" guarantee -- while
    the spread scales with the interval (a fixed [0,100) ms jitter is negligible
    at the cap). These tests pin: the delay stays in [base*750, base*1000] ms, the
    spread at the cap far exceeds a fixed 100 ms jitter, and the jitter ceiling is
    derived from base (not a constant). The upper-bound and spread cases fail
    against an additive fixed-jitter implementation.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Backoff.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

# Recompute base the same way Get-PollDelay does (exponent capped at 30 so a
# long-paused Attempt counter can't overflow Int32 in Pow/Min).
function Get-ExpectedBase {
    param([int]$Attempt)
    $exp = [Math]::Max(0, $Attempt - 1)
    if ($exp -gt 30) { $exp = 30 }
    $b = [int][Math]::Min(59, [Math]::Pow(2, $exp))
    if ($b -lt 1) { $b = 1 }
    return $b
}

Describe 'Get-PollDelay proportional down-jitter' {
    It 'never exceeds base seconds (preserves the 59 s wake-within-a-minute cap)' {
        foreach ($att in @(1, 4, 5, 6, 7, 31)) {
            $base = Get-ExpectedBase -Attempt $att
            $vals = 1..500 | ForEach-Object { Get-PollDelay -Attempt $att }
            $over = @($vals | Where-Object { $_ -gt ($base * 1000) })
            Assert-Equal -Expected 0 -Actual $over.Count -Because "attempt $($att): delay must stay <= base*1000 ($($base * 1000)ms); additive jitter would exceed it"
        }
    }

    It 'stays at or above 75% of base (down-jitter is bounded at 25%)' {
        foreach ($att in @(1, 5, 6, 7, 31)) {
            $base = Get-ExpectedBase -Attempt $att
            $vals = 1..500 | ForEach-Object { Get-PollDelay -Attempt $att }
            $under = @($vals | Where-Object { $_ -lt ($base * 750) })
            Assert-Equal -Expected 0 -Actual $under.Count -Because "attempt $($att): delay must stay >= base*750 ($($base * 750)ms)"
        }
    }

    It 'spreads proportionally at the 59 s cap (jitter scales with the interval)' {
        $base = Get-ExpectedBase -Attempt 31   # 59
        $vals = 1..1000 | ForEach-Object { Get-PollDelay -Attempt 31 }
        $spread = ($vals | Measure-Object -Maximum).Maximum - ($vals | Measure-Object -Minimum).Minimum
        Assert-True ($spread -gt 1000) "at base=$base the spread ($spread ms) must far exceed a fixed 100 ms jitter"
    }

    It 'derives the jitter ceiling from base, not a constant (AST guard)' {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors: $($errs[0].Message)" }
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-PollDelay' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $fn) 'Get-PollDelay is defined'
        $getRandom = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-Random' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $getRandom) 'Get-Random is called'
        # Find the argument to -Maximum and assert it references $base.
        $maxArg = $null
        $els = $getRandom.CommandElements
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq 'Maximum') {
                $maxArg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
                break
            }
        }
        Assert-True ($null -ne $maxArg) 'Get-Random is called with -Maximum'
        Assert-True ($maxArg.Extent.Text -match '\$base') "the jitter ceiling must scale with base, got '$($maxArg.Extent.Text)'"
    }
}
