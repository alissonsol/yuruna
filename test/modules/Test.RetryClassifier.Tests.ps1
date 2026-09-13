<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42ec2071-1f84-4394-921b-5ee9b08141b3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry classifier transient resilience pester
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
    Guards the shared transient-failure classifier against the wording-drift
    class: a symptom the policy is meant to ride out, spelled by a tool in
    words the pattern does not carry.
.DESCRIPTION
    The classifier decides "is this failure worth retrying?" by matching the
    tool's own English error text. That makes it silently sensitive to how each
    tool phrases a condition, and a miss is invisible: the call fails fast on
    attempt 1 of 5 and reads as a permanent error, so the retry cover the policy
    promises is simply absent.

    The case that motivates these guards: a refused connection reaches the
    classifier in two unrelated wordings. Go prints the errno form
    ("connect: connection refused"); kubectl catches the same errno and
    reformats it around the URL's host ("The connection to the server <host>
    was refused - did you specify the right host or port?"). The two share no
    contiguous substring, so a pattern carrying only the first fails fast on
    `kubectl -f <URL>` -- one of the call sites the policy explicitly gates.

    The fail-fast direction is pinned too: a deterministic config, auth, or
    NotFound error must NOT match, or every such error burns the whole backoff
    budget before failing.

    Should assertions only, so the suite runs under Pester 4.10.1 as well as 5.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path (Join-Path $repoRoot 'automation') 'Yuruna.Retry.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$script:pattern = Get-YurunaTransientPattern
}

Describe 'Transient classifier: a refused connection in every wording a lab tool uses' {
    # Both spellings name the same condition -- a peer that was not listening,
    # which is what a restarting proxy, registry, or API server looks like.
    It 'matches kubectl''s host-shaped refusal from a manifest fetch' {
        # kubectl reformats ECONNREFUSED around the URL host, so the text names
        # the origin server even when the socket that refused was the proxy in
        # front of it.
        'The connection to the server github.com was refused - did you specify the right host or port?' |
            Should -Match $script:pattern
    }

    It 'matches kubectl''s host-shaped refusal against the API server' {
        'The connection to the server localhost:8080 was refused - did you specify the right host or port?' |
            Should -Match $script:pattern
    }

    It 'still matches the Go errno wording' {
        'Error response from daemon: dial tcp 192.168.7.42:3129: connect: connection refused' |
            Should -Match $script:pattern
    }

    It 'matches a resolver that answered with neither a record nor NXDOMAIN' {
        'dial tcp: lookup yuruna-caching-proxy-service on 127.0.0.53:53: server misbehaving' |
            Should -Match $script:pattern
    }
}

Describe 'Transient classifier: the tokens already relied on keep matching' {
    It 'matches <token>' -TestCases @(
        @{ token = 'Error: INSTALLATION FAILED: failed to fetch https://example.invalid/index.yaml' }
        @{ token = 'dial tcp 10.0.0.1:443: i/o timeout' }
        @{ token = 'dial tcp: lookup example.invalid: no such host' }
        @{ token = 'read: connection reset by peer' }
        @{ token = 'net/http: TLS handshake timeout' }
        @{ token = 'Temporary failure in name resolution' }
        @{ token = 'unexpected EOF' }
        @{ token = 'server reported 502 Bad Gateway, status code=502' }
        @{ token = 'You have reached your pull rate limit. too many requests' }
        @{ token = 'Error acquiring the state lock' }
        @{ token = 'ConditionalCheckFailedException' }
    ) {
        param($token)
        $token | Should -Match $script:pattern
    }
}

Describe 'Transient classifier: deterministic failures still fail fast' {
    # Matching is necessary but not sufficient for a retry, yet a false match
    # here spends the entire backoff budget on an error that can never clear.
    It 'does not match <token>' -TestCases @(
        @{ token = 'Error from server (NotFound): namespaces "missing-ns" not found' }
        @{ token = 'error: unknown flag: --nonesuch' }
        @{ token = 'Error from server (Forbidden): pods is forbidden: User cannot list resource' }
        @{ token = 'error validating data: ValidationError(Deployment.spec): unknown field "replica"' }
        @{ token = 'Error: UPGRADE FAILED: another operation is in progress' }
    ) {
        param($token)
        $token | Should -Not -Match $script:pattern
    }

    It 'does not match a status-shaped substring inside a larger number' {
        'transferred 1500 bytes in 2500 ms' | Should -Not -Match $script:pattern
    }

    It 'does not match EOF inside an unrelated token' {
        'Traceback: EOFError raised while parsing' | Should -Not -Match $script:pattern
    }
}

Describe 'Transient classifier: the deployment predicate acts on the verdict' {
    # The classifier is only useful through the predicate the deployment loop
    # builds from it, so the wiring is pinned end to end rather than the regex
    # alone: a kubectl refusal must spend the ladder, a NotFound must not.
    #
    # The failing tool reports through $LASTEXITCODE rather than by throwing,
    # which is how the deployment loop's native kubectl/helm calls fail. The
    # distinction is load-bearing: a scriptblock that throws leaves the helper
    # with no captured output, so the predicate would match nothing and fail
    # fast regardless of what the classifier says.
    BeforeEach {
        Mock -ModuleName 'Yuruna.Retry' Start-Sleep { }
    }

    It 'retries a kubectl refusal across the whole ladder' {
        $transientPattern = $script:pattern
        $shouldRetry = {
            param($info)
            $text = (@($info.Output) | ForEach-Object { [string]$_ }) -join "`n"
            return ($text -match $transientPattern)
        }.GetNewClosure()
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'kubectl-refused' -MaxAttempts 5 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock {
                 $script:runs++
                 Write-Output 'The connection to the server github.com was refused - did you specify the right host or port?'
                 $global:LASTEXITCODE = 1
             } -ShouldRetry $shouldRetry
        $r.Success | Should -BeFalse
        $script:runs | Should -Be 5
    }

    It 'fails fast on a NotFound instead of spending the ladder' {
        $transientPattern = $script:pattern
        $shouldRetry = {
            param($info)
            $text = (@($info.Output) | ForEach-Object { [string]$_ }) -join "`n"
            return ($text -match $transientPattern)
        }.GetNewClosure()
        $script:runs = 0
        $r = Invoke-WithYurunaRetry -Label 'kubectl-notfound' -MaxAttempts 5 `
             -InitialDelaySeconds 1 -MaxDelaySeconds 1 -JitterFraction 0 `
             -ScriptBlock {
                 $script:runs++
                 Write-Output 'Error from server (NotFound): namespaces "missing-ns" not found'
                 $global:LASTEXITCODE = 1
             } -ShouldRetry $shouldRetry
        $r.Success | Should -BeFalse
        $script:runs | Should -Be 1
    }
}
