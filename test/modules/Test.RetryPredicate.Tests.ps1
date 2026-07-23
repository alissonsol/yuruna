<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42a9f0c3-5d7e-4b81-9c2a-6f3e8d1b40a7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry predicate resilience pester
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
    Behavioral guards on Invoke-WithYurunaRetry's -ShouldRetry predicate control
    flow, including the fail-safe direction when the predicate itself throws.
.DESCRIPTION
    -ShouldRetry lets a caller fail fast on a non-transient failure. The predicate
    returns $true (retry) or $false (fail fast). If the predicate THROWS, that is a
    bug in the caller's test -- not evidence the failure is permanent -- so the
    helper must fall back to the no-predicate default (retry on any non-zero exit)
    rather than silently converting a retryable failure into a fail-fast. These
    tests pin: a throwing predicate exhausts all attempts, a $false predicate still
    fails fast after one attempt, a $true predicate retries, and the no-predicate
    default retries. The throwing-predicate case fails against a swallow-to-$false
    implementation (retryThis initialized $false + empty catch).

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path (Join-Path $repoRoot 'automation') 'Yuruna.Retry.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Describe 'Invoke-WithYurunaRetry -ShouldRetry predicate control flow' {
    BeforeEach {
        # Neutralize real backoff waits so the retry-count assertions run fast and
        # deterministically. Small delays are still passed as a fallback in case
        # the module-scoped mock is not applied on some Pester build.
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
    }

    It 'retries a throwing predicate instead of failing fast (a broken predicate must not disable retry cover)' {
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'test-throw-pred' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; throw 'boom' } `
             -ShouldRetry { throw 'predicate bug' }
        Assert-Equal -Expected $false -Actual $r.Success -Because 'the work always fails'
        Assert-Equal -Expected 3 -Actual $r.Attempts -Because 'a throwing predicate must fall back to retryable and exhaust all attempts (was 1 = fail-fast under the swallow bug)'
        Assert-Equal -Expected 3 -Actual $script:runs -Because 'the scriptblock must run on every attempt'
    }

    It 'still fails fast when the predicate returns $false (the non-transient escape hatch is preserved)' {
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'test-false-pred' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; throw 'boom' } `
             -ShouldRetry { $false }
        Assert-Equal -Expected 1 -Actual $r.Attempts -Because 'a $false predicate must fail fast after the first attempt'
        Assert-Equal -Expected 1 -Actual $script:runs -Because 'no further attempts after fail-fast'
    }

    It 'retries when the predicate returns $true' {
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'test-true-pred' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; throw 'boom' } `
             -ShouldRetry { $true }
        Assert-Equal -Expected 3 -Actual $r.Attempts -Because 'a $true predicate retries every attempt'
        Assert-Equal -Expected 3 -Actual $script:runs
    }

    It 'retries on any non-zero exit when no predicate is given (default contract unchanged)' {
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'test-no-pred' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; throw 'boom' }
        Assert-Equal -Expected 3 -Actual $r.Attempts -Because 'no predicate => retry on any non-zero exit'
        Assert-Equal -Expected 3 -Actual $script:runs
    }
}
