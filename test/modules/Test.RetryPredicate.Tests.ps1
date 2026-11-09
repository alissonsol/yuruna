<#PSScriptInfo
.VERSION 2026.11.08
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

Describe 'Invoke-WithYurunaRetry -WindowSeconds' {
    It 'starts no attempt after the window closes and reports the attempts it made as the allowance' {
        # Real sleeps: the window is measured on a monotonic clock, so it cannot
        # be advanced by a stand-in. One-second backoffs against a three-second
        # window keep the run near four attempts, far below the explicit count.
        $script:runs = 0
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-WithYurunaRetry -Label 'test-window' -MaxAttempts 50 -WindowSeconds 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; throw 'boom' }
        $clock.Stop()
        Assert-Equal -Expected $false -Actual $r.Success
        Assert-True ($r.Attempts -lt 50) "the window, not the attempt count, must end the run (made $($r.Attempts))"
        Assert-True ($r.Attempts -ge 3) "the window allowed at least three one-second backoffs (made $($r.Attempts))"
        Assert-Equal -Expected $r.Attempts -Actual $r.MaxAttempts -Because 'a run the window ended reports the attempts it made, so "all N attempts exhausted" stays true'
        Assert-Equal -Expected $script:runs -Actual $r.Attempts
        Assert-True ($clock.Elapsed.TotalSeconds -ge 3) "the run must last the window (lasted $($clock.Elapsed.TotalSeconds) s)"
        Assert-True ($clock.Elapsed.TotalSeconds -lt 6) "no backoff may run past the window's end (lasted $($clock.Elapsed.TotalSeconds) s)"
    }
}

Describe 'Invoke-TofuInitWithRetry attempt budget' {
    BeforeEach {
        $script:slept = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { $script:slept.Add([int]$Seconds) }
        $script:savedAttempts = Save-YurunaTestEnvironment -Name 'YURUNA_RETRY_MAX_ATTEMPTS'
        $env:YURUNA_RETRY_MAX_ATTEMPTS = ''
        # An init that cannot reach the provider releases, as OpenTofu reports it.
        Set-Item -Path Function:global:tofu -Value {
            'Error: Failed to install provider: request failed after 2 attempts: 504 Gateway Timeout returned from https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS'
            $global:LASTEXITCODE = 1
        }
    }

    AfterEach {
        Remove-Item -Path Function:global:tofu -ErrorAction SilentlyContinue
        Restore-YurunaTestEnvironment -Saved $script:savedAttempts
    }

    It 'backs init off for at least half an hour, two minutes at most per sleep, before it gives up' {
        # GitHub's release endpoints have answered 504 for most of half an hour.
        # The stand-in sleeps take no time, so the attempt backstop ends this
        # run; it must hold enough backoff to cover the window by itself.
        $log = Join-Path $TestDrive 'window.stderr.log'
        $r = Invoke-TofuInitWithRetry -ResourceName 'sample' -LogPath $log
        Assert-Equal -Expected $false -Actual $r.Success
        $total = ($script:slept | Measure-Object -Sum).Sum
        Assert-True ($total -ge 1800) "init's backoff must span the 30-minute window (spans $total s over $($r.Attempts) attempts)"
        Assert-True (@($script:slept | Where-Object { $_ -gt 120 }).Count -eq 0) "no backoff may exceed two minutes (slept: $($script:slept -join ', '))"
        Assert-Equal -Expected $r.MaxAttempts -Actual $r.Attempts
        Assert-Equal -Expected $r.Attempts -Actual @(Select-String -LiteralPath $log -Pattern "^== .* attempt \d+/$($r.MaxAttempts) \(exit=1\) ==`$").Count -Because 'each attempt the tool ran writes its own section'
    }

    It 'keeps the operator''s YURUNA_RETRY_MAX_ATTEMPTS over its own default' {
        $env:YURUNA_RETRY_MAX_ATTEMPTS = '2'
        $log = Join-Path $TestDrive 'two.stderr.log'
        $r = Invoke-TofuInitWithRetry -ResourceName 'sample' -LogPath $log
        Assert-Equal -Expected 2 -Actual $r.MaxAttempts
        Assert-Equal -Expected 2 -Actual @(Select-String -LiteralPath $log -Pattern '^== .* attempt \d+/2 \(exit=1\) ==$').Count
    }
}
