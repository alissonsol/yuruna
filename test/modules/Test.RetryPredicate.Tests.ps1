<#PSScriptInfo
.VERSION 2026.10.31
.GUID 426e19c5-9718-4a13-b5d3-7b13bd7d1d65
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

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path (Join-Path $repoRoot 'automation') 'Yuruna.Retry.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

}

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

Describe 'Invoke-TofuInitWithRetry attempt budget' {
    BeforeEach {
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        $script:savedAttempts = Save-YurunaTestEnvironment -Name 'YURUNA_RETRY_MAX_ATTEMPTS'
        $env:YURUNA_RETRY_MAX_ATTEMPTS = ''
        # An init that cannot reach the provider registry, as OpenTofu reports it.
        Set-Item -Path Function:global:tofu -Value {
            'Error: Failed to resolve provider packages: could not query provider registry: Client.Timeout exceeded while awaiting headers'
            $global:LASTEXITCODE = 1
        }
    }

    AfterEach {
        Remove-Item -Path Function:global:tofu -ErrorAction SilentlyContinue
        Restore-YurunaTestEnvironment -Saved $script:savedAttempts
    }

    It 'runs init six times, one more than the shared default, before it gives up' {
        $log = Join-Path $TestDrive 'six.stderr.log'
        $r = Invoke-TofuInitWithRetry -ResourceName 'sample' -LogPath $log
        Assert-Equal -Expected $false -Actual $r.Success
        Assert-Equal -Expected 6 -Actual $r.MaxAttempts -Because 'five attempts span only about four minutes of backoff, shorter than a registry stall the proxy has passed through'
        Assert-Equal -Expected 6 -Actual @(Select-String -LiteralPath $log -Pattern '^== .* attempt \d+/6 \(exit=1\) ==$').Count -Because 'each attempt the tool ran writes its own section'
    }

    It 'keeps the operator''s YURUNA_RETRY_MAX_ATTEMPTS over its own default' {
        $env:YURUNA_RETRY_MAX_ATTEMPTS = '2'
        $log = Join-Path $TestDrive 'two.stderr.log'
        $r = Invoke-TofuInitWithRetry -ResourceName 'sample' -LogPath $log
        Assert-Equal -Expected 2 -Actual $r.MaxAttempts
        Assert-Equal -Expected 2 -Actual @(Select-String -LiteralPath $log -Pattern '^== .* attempt \d+/2 \(exit=1\) ==$').Count
    }
}
