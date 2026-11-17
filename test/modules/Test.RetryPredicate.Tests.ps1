<#PSScriptInfo
.VERSION 2026.11.16
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

# The operator line that reports an accepted attempt is compared to the
# catalog's own rendering of its key, so the comparison holds in every operator
# locale and fails when the line is missing, its key is wrong or an argument no
# longer fills its placeholder.
Import-Module (Join-Path (Join-Path $repoRoot 'automation') 'Yuruna.Globalization.psm1') -Force -DisableNameChecking
function Get-AppliedLine {
    <#
    .SYNOPSIS
        The operator line that reports an attempt as the completion of an
        earlier one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][int]$Attempt,
        [Parameter(Mandatory)][int]$MaxAttempts,
        [Parameter(Mandatory)][int]$LastExit
    )
    return (Format-YurunaOperatorMessage -Key 'automation.retry_already_applied' -Arguments @{ label = $Label; attempt = "$Attempt"; maxAttempts = "$MaxAttempts"; lastExit = "$LastExit" })
}

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

# A retried command can have been completed by the attempt whose answer was
# lost: an API server commits a create whose response timed out, and the retry
# is refused as AlreadyExists. -SucceedWhen names such a failure as the earlier
# attempt's completion, and is asked about nothing else.
Describe 'Invoke-WithYurunaRetry -SucceedWhen (a failure that completes an earlier attempt)' {
    BeforeEach {
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
        $script:asked = [System.Collections.Generic.List[object]]::new()
        $script:runs = 0
    }

    It 'is not consulted on the first attempt, nor on an attempt that passed on its own' {
        $r = Invoke-WithYurunaRetry -Label 'test-first-attempt' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; if ($script:runs -eq 1) { $global:LASTEXITCODE = 1; 'refused' } else { $global:LASTEXITCODE = 0; 'done' } } `
             -SucceedWhen { param($info) $script:asked.Add($info); $true } -InformationVariable report
        Assert-True $r.Success
        Assert-Equal -Expected 2 -Actual $r.Attempts
        Assert-Equal -Expected 0 -Actual $script:asked.Count -Because 'nothing earlier can have acted before the first attempt, and the second attempt passed'
        Assert-Null $r.CompletedBy 'a pass of the command''s own names no completion'
        $lines = @($report | ForEach-Object { [string]$_.MessageData })
        $applied = @((Get-AppliedLine -Label 'test-first-attempt' -Attempt 1 -MaxAttempts 3 -LastExit 1), (Get-AppliedLine -Label 'test-first-attempt' -Attempt 2 -MaxAttempts 3 -LastExit 0))
        Assert-Equal -Expected 0 -Actual @($lines | Where-Object { $_ -cin $applied }).Count -Because "a pass of the command's own is not reported as a completion by an earlier attempt (reported: $($lines -join ' | '))"
    }

    It 'is consulted on a failed later attempt with that attempt''s record, and a true answer ends the retry as a success' {
        $r = Invoke-WithYurunaRetry -Label 'test-already-applied' -MaxAttempts 5 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; $global:LASTEXITCODE = 1; "refused $script:runs" } `
             -SucceedWhen { param($info) $script:asked.Add($info); $true } -InformationVariable report
        Assert-Equal -Expected 1 -Actual $script:asked.Count -Because 'asked once, about the first retried attempt'
        Assert-Equal -Expected 2 -Actual $script:asked[0].Attempt
        Assert-Equal -Expected 5 -Actual $script:asked[0].MaxAttempts
        Assert-Equal -Expected 1 -Actual $script:asked[0].ExitCode
        Assert-StringEqual 'refused 2' (@($script:asked[0].Output) -join '|')
        Assert-False $script:asked[0].TimedOut
        Assert-True $r.Success 'the predicate said an earlier attempt had applied the outcome'
        Assert-Equal -Expected 0 -Actual $r.LastExit
        Assert-Equal -Expected 0 -Actual $global:LASTEXITCODE
        Assert-Equal -Expected 2 -Actual $r.Attempts
        Assert-Equal -Expected 2 -Actual $script:runs -Because 'no attempt follows the accepted one'
        Assert-StringEqual 'already-applied' $r.CompletedBy
        $lines = @($report | ForEach-Object { [string]$_.MessageData })
        $applied = Get-AppliedLine -Label 'test-already-applied' -Attempt 2 -MaxAttempts 5 -LastExit 1
        Assert-Equal -Expected 1 -Actual @($lines | Where-Object { $_ -ceq $applied }).Count -Because "one operator line says the attempt's outcome had already been applied by an earlier attempt (reported: $($lines -join ' | '))"
    }

    It 'keeps retrying and exhausts as before when the predicate answers false' {
        $r = Invoke-WithYurunaRetry -Label 'test-not-applied' -MaxAttempts 3 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; $global:LASTEXITCODE = 1; 'refused' } `
             -SucceedWhen { param($info) $script:asked.Add($info); $false } -InformationVariable report
        Assert-False $r.Success
        Assert-Equal -Expected 3 -Actual $r.Attempts
        Assert-Equal -Expected 1 -Actual $r.LastExit
        Assert-Equal -Expected 2 -Actual $script:asked.Count -Because 'asked about attempts 2 and 3'
        Assert-Null $r.CompletedBy
        $lines = @($report | ForEach-Object { [string]$_.MessageData })
        $applied = @(foreach ($attempt in 1..3) { Get-AppliedLine -Label 'test-not-applied' -Attempt $attempt -MaxAttempts 3 -LastExit 1 })
        Assert-Equal -Expected 0 -Actual @($lines | Where-Object { $_ -cin $applied }).Count -Because "nothing was accepted, so no line says the outcome had already been applied (reported: $($lines -join ' | '))"
    }

    It 'is never consulted about an attempt the deadline stopped' {
        $r = Invoke-WithYurunaRetry -Label 'test-stopped' -MaxAttempts 2 -TimeoutSeconds 1 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command 'Start-Sleep -Seconds 60' } `
             -SucceedWhen { param($info) $script:asked.Add($info); $true } 3>$null
        Assert-False $r.Success
        Assert-True $r.TimedOut
        Assert-Equal -Expected 2 -Actual $script:runs
        Assert-Equal -Expected 0 -Actual $script:asked.Count -Because 'a stopped attempt''s outcome is unknown'
        Assert-Null $r.CompletedBy
    }

    It 'counts a throwing predicate as false, reports it, and keeps the attempt a failure' {
        $r = Invoke-WithYurunaRetry -Label 'test-throwing-succeed-when' -MaxAttempts 2 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock { $script:runs++; $global:LASTEXITCODE = 1; 'refused' } `
             -SucceedWhen { throw 'predicate bug' } -InformationVariable report
        Assert-False $r.Success
        Assert-Equal -Expected 2 -Actual $r.Attempts
        Assert-Equal -Expected 1 -Actual $r.LastExit
        Assert-Null $r.CompletedBy
        $lines = @($report | ForEach-Object { [string]$_.MessageData })
        Assert-Equal -Expected 1 -Actual @($lines | Where-Object { $_ -like '*test-throwing-succeed-when*predicate bug*' }).Count -Because "the throw is reported once, on the one retried attempt (reported: $($lines -join ' | '))"
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

    It 'names the download its last attempt reported failing when it gives up' {
        $env:YURUNA_RETRY_MAX_ATTEMPTS = '2'
        $r = Invoke-TofuInitWithRetry -ResourceName 'sample' -LogPath (Join-Path $TestDrive 'fetch.stderr.log')
        Assert-Equal -Expected $false -Actual $r.Success
        Assert-Equal -Expected 'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS' -Actual $r.FetchFailure.Url
        Assert-Equal -Expected '504 Gateway Timeout' -Actual $r.FetchFailure.Error
    }
}

Describe 'Get-TofuFetchFailure (the download a failed tofu init names)' {
    BeforeAll {
        $script:readTofuFailure = & (Get-Module Yuruna.Retry) { ${function:Get-TofuFetchFailure} }
        # tofu's own framing: a colored box whose long lines wrap inside it.
        function Format-TofuDiagnostic {
            param([string[]]$Line)
            $bar = "`e[31m`u{2502}`e[0m "
            @("`e[31m`u{2577}`e[0m`e[0m", "$bar`e[0m`e[1m`e[31mError: `e[0m`e[0m`e[1mFailed to install provider`e[0m", $bar) +
                @($Line | ForEach-Object { "$bar`e[0m$_" }) + @("`e[31m`u{2575}`e[0m`e[0m")
        }
    }

    It 'reads <Case> out of the box tofu draws' -TestCases @(
        @{ Case = 'a client timeout'; Line = @(
                'Error while installing hashicorp/external v2.4.2: could not query provider'
                'registry for registry.opentofu.org/hashicorp/external: failed to retrieve'
                'authentication checksums for provider: request failed after 2 attempts: Get'
                '"https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS":'
                'net/http: request canceled (Client.Timeout exceeded while awaiting headers)')
            Url = 'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS'
            Reason = 'net/http: request canceled (Client.Timeout exceeded while awaiting headers)' }
        @{ Case = 'the retrying client giving up'; Line = @(
                'Error while installing hashicorp/external v2.4.2: github.com: GET'
                'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_linux_arm64.zip'
                'giving up after 3 attempt(s)')
            Url = 'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_linux_arm64.zip'
            Reason = 'giving up after 3 attempt(s)' }
        @{ Case = 'a status the server returned'; Line = @(
                'Error while installing hashicorp/external v2.4.2: could not query provider'
                'registry for registry.opentofu.org/hashicorp/external: failed to retrieve'
                'cryptographic signature for provider: request failed after 2 attempts: 504'
                'Gateway Timeout returned from'
                'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS.sig')
            Url = 'https://github.com/opentofu/terraform-provider-external/releases/download/v2.4.2/terraform-provider-external_2.4.2_SHA256SUMS.sig'
            Reason = '504 Gateway Timeout' }
    ) {
        param($Case, $Line, $Url, $Reason)
        $null = $Case
        $output = @("`e[0m`e[1mInitializing provider plugins...`e[0m", '- Finding latest version of hashicorp/external...') + (Format-TofuDiagnostic -Line $Line)
        $failure = & $script:readTofuFailure -Output $output
        Assert-Equal -Expected $Url -Actual $failure.Url
        Assert-Equal -Expected $Reason -Actual $failure.Error
    }

    It 'keeps only the scheme, host and path of the URL, and redacts a secret in what it keeps' {
        # A release download is redirected to a signed URL whose query is a credential.
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_FIXTURE_API_TOKEN'
        try {
            $env:YURUNA_FIXTURE_API_TOKEN = 'fixture-secret-value'
            $failure = & $script:readTofuFailure -Output @(
                'Error: Get "https://user:pw@objects.example.invalid/fixture-secret-value/provider.zip?X-Amz-Signature=abc#part": context deadline exceeded')
            Assert-Equal -Expected 'https://objects.example.invalid/<redacted>/provider.zip' -Actual $failure.Url
            Assert-Equal -Expected 'context deadline exceeded' -Actual $failure.Error
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
    }

    It 'returns nothing when tofu named no download' {
        Assert-True ($null -eq (& $script:readTofuFailure -Output (Format-TofuDiagnostic -Line @('Inconsistent dependency lock file')))) 'no download, no reading'
        Assert-True ($null -eq (& $script:readTofuFailure -Output @())) 'no output, no reading'
        Assert-True ($null -eq (& $script:readTofuFailure -Output $null)) 'no output, no reading'
    }
}
