<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42bc659c-43c2-496e-bcea-01f39b34ee81
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test fetch fallback project evidence pester
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

BeforeDiscovery {
    $script:ProjectFetchBash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

BeforeAll {
    $script:ProjectFetchBash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:ProjectFetchRuns = @{}
    if ($script:ProjectFetchBash) {
        $root = Join-Path $PSScriptRoot '../..'
        $wrapper = Get-Content (Join-Path $root 'automation/fetch-and-execute.sh') -Raw
        $logDeclaration = "fae_log='/tmp/yuruna-last-fetch-and-execute.log'"
        $libraryDeclaration = 'YURUNA_LIB_DIR=/usr/local/lib/yuruna'
        if (-not $wrapper.Contains($logDeclaration) -or -not $wrapper.Contains($libraryDeclaration)) {
            throw 'The wrapper fixture must redirect its log and retry-library paths before execution.'
        }
        $wrapper = $wrapper.Replace($logDeclaration, 'fae_log="${FAE_TEST_DIR:?}/log"').
            Replace($libraryDeclaration, 'YURUNA_LIB_DIR="${FAE_TEST_DIR:?}/lib"').
            Replace('/etc/yuruna/host.env', '${FAE_TEST_DIR:?}/missing-host.env').
            Replace('/usr/local/lib/yuruna/yuruna-host-locate.sh', '${FAE_TEST_DIR:?}/missing-locate.sh').
            Replace('/usr/local/lib/yuruna/yuruna-network.sh', '${FAE_TEST_DIR:?}/missing-network.sh')
        $wrapperPath = Join-Path $TestDrive 'project-fetch-wrapper.sh'
        [IO.File]::WriteAllText($wrapperPath, $wrapper.Replace(([string][char]13 + [char]10), [string][char]10))
        $driver = Get-Content (Join-Path $root 'test/shell/test-project-fetch-fallback.sh') -Raw
        $driver = $driver.Replace(([string][char]13 + [char]10), [string][char]10)
        $priorEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            $output = (($driver + [char]10 + '#') | & $script:ProjectFetchBash.Source -s -- $wrapperPath.Replace('\', '/') 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { throw "The isolated Bash fixture failed: $output" }
        } finally { [Console]::OutputEncoding = $priorEncoding }
        $pattern = '(?m)^@@CASE (\S+) (\d+) (\d+)\r?\nout=([A-Za-z0-9+/=]*)\r?\nerr=([A-Za-z0-9+/=]*)\r?\nlog=([A-Za-z0-9+/=]*)\r?\ncalls=([A-Za-z0-9+/=]*)\r?\n@@END'
        foreach ($match in [regex]::Matches($output, $pattern)) {
            $record = @{ ExitCode = [int]$match.Groups[2].Value; RemainingAuthFiles = [int]$match.Groups[3].Value }
            foreach ($entry in @(@('Output', 4), @('Error', 5), @('Log', 6), @('Calls', 7))) {
                $record[$entry[0]] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[$entry[1]].Value))
            }
            $script:ProjectFetchRuns[$match.Groups[1].Value] = $record
        }
        if ($script:ProjectFetchRuns.Count -ne 25) { throw "Expected all 25 isolated scenarios; captured output: $output" }
    }
}

Describe 'Project payload fallback and invocation evidence' -Skip:(-not $script:ProjectFetchBash) {
    It 'keeps the complete project path for a host or manual base URL' -ForEach @(
        @{ Name = 'host'; Url = 'http://host.invalid/yuruna-repo/project/example/workload.sh' },
        @{ Name = 'base'; Url = 'https://manual.invalid/source/project/example/workload.sh' }
    ) {
        $run = $script:ProjectFetchRuns[$Name]
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'PAYLOAD_RAN'
        $run.Calls | Should -Match ([regex]::Escape($Url))
        $run.Calls | Should -Not -Match 'github'
        if ($Name -eq 'host') { $run.Calls | Should -Match '--no-proxy' }
    }

    It 'fetches a public project at its own exact commit with one prefix removed' {
        $run = $script:ProjectFetchRuns.project
        $run.ExitCode | Should -Be 0
        $run.Calls | Should -Match 'https://raw\.githubusercontent\.com/private/project/2222222222222222222222222222222222222222/example/workload\.sh'
        $run.Calls | Should -Not -Match 'framework/repository|/project/example/'
        $run.Output | Should -Match 'PAYLOAD_RAN'
        $run.Log | Should -Match '# revision: 2222222222222222222222222222222222222222'
    }

    It 'preserves request queries with a single delimiter for <Name>' -ForEach @(
        @{ Name = 'host_query'; Url = 'http://host.invalid/yuruna-repo/project/example/workload.sh?nocache=path-source&extra=override' },
        @{ Name = 'base_query'; Url = 'https://manual.invalid/source/project/example/workload.sh?nocache=path-source&extra=override' },
        @{ Name = 'base_existing_query'; Url = 'https://manual.invalid/source/?path=project/example/workload.sh&nocache=path-source&extra=override' }
    ) {
        $run = $script:ProjectFetchRuns[$Name]
        $run.ExitCode | Should -Be 0
        $request = @($run.Calls -split '\r?\n' | Where-Object { $_ -match '^https?://' })
        $request.Count | Should -Be 1
        $request[0] | Should -BeExactly $Url
        $run.Log | Should -Match '(?m)^# script:\s+project/example/workload\.sh$'
        $run.Log | Should -Match '(?m)^# payload-script: project/example/workload\.sh$'
        $run.Output | Should -Match 'sha256 verified \(project/example/workload\.sh\)'
        $run.Output | Should -Match 'PAYLOAD_RAN'
    }

    It 'discards host cache queries when fetching a pinned project through <Name>' -ForEach @(
        @{ Name = 'project_query'; Url = 'https://raw.githubusercontent.com/private/project/2222222222222222222222222222222222222222/example/workload.sh' },
        @{ Name = 'authenticated_query'; Url = 'https://api.github.com/repos/private/project/contents/example/workload.sh?ref=2222222222222222222222222222222222222222' }
    ) {
        $run = $script:ProjectFetchRuns[$Name]
        $run.ExitCode | Should -Be 0
        $request = @($run.Calls -split '\r?\n' | Where-Object { $_ -match '^https?://' })
        $request.Count | Should -Be 1
        $request[0] | Should -BeExactly $Url
        $run.Calls | Should -Not -Match 'nocache|extra=override'
        $run.Log | Should -Match '(?m)^# script:\s+project/example/workload\.sh$'
        $run.Log | Should -Match '(?m)^# payload-script: project/example/workload\.sh$'
        $run.Output | Should -Match 'PAYLOAD_RAN'
        $run.RemainingAuthFiles | Should -Be 0
        ($run.Output + $run.Error + $run.Log + $run.Calls) | Should -Not -Match 'fixture-project-token-that-must-not-appear'
    }

    It 'retains the root invocation while a real generated-style wrapper delegates to a shared payload' {
        $run = $script:ProjectFetchRuns.nested
        $run.ExitCode | Should -Be 0
        @([regex]::Matches($run.Calls, '@@REQUEST')).Count | Should -Be 2
        $run.Calls | Should -Match '/guest/ubuntu\.server\.26/ubuntu\.server\.26\.update\.sh'
        $run.Calls | Should -Match '/guest/shared/update\.sh'
        $run.Calls | Should -Not -Match 'nocache'
        $run.Log | Should -Match '^# Yuruna fetch-and-execute log'
        $run.Log | Should -Match '(?m)^# script:\s+guest/ubuntu\.server\.26/ubuntu\.server\.26\.update\.sh$'
        $run.Log | Should -Match '(?m)^# payload-script: guest/shared/update\.sh$'
        @([regex]::Matches($run.Log, '(?m)^# script:')).Count | Should -Be 1
        $run.Log | Should -Match '# stepInvocationId: step-nested'
        $run.Log | Should -Match '# sequenceInvocationId: sequence-current'
        $run.Output | Should -Match 'sha256 verified \(guest/ubuntu\.server\.26/ubuntu\.server\.26\.update\.sh\)'
        $run.Output | Should -Match 'sha256 verified \(guest/shared/update\.sh\)'
        $run.Log | Should -Match 'PAYLOAD_RAN'
        $run.Log | Should -Not -Match 'OLD_SUCCESS_SENTINEL|old-step|old/success'
    }

    It 'rejects an inherited invocation identity outside the repository before fetching' {
        $run = $script:ProjectFetchRuns.invalid_identity
        $run.ExitCode | Should -Be 1
        $run.Calls | Should -BeNullOrEmpty
        $run.Error | Should -Match 'INVALID FETCH INVOCATION'
        $run.Log | Should -Match '# phase: invalid-invocation'
        $run.Log | Should -Not -Match 'OLD_SUCCESS_SENTINEL|forged'
    }

    It 'authenticates private project requests through a private, removed wget configuration' {
        $run = $script:ProjectFetchRuns.authenticated
        $run.ExitCode | Should -Be 0
        $run.Calls | Should -Match 'https://api\.github\.com/repos/private/project/contents/example/workload\.sh\?ref=2222222222222222222222222222222222222222'
        if ($IsLinux) { $run.Calls | Should -Match 'CONFIG_MODE=600' }
        $run.Calls | Should -Match 'AUTH_HEADER_MATCH=1'
        $run.RemainingAuthFiles | Should -Be 0
        ($run.Output + $run.Error + $run.Log + $run.Calls) | Should -Not -Match 'fixture-project-token-that-must-not-appear'
    }

    It 'rejects a <Name> project pin before making a request' -ForEach @(
        @{ Name = 'missing' }, @{ Name = 'partial' }, @{ Name = 'invalid' }
    ) {
        $run = $script:ProjectFetchRuns[$Name]
        $run.ExitCode | Should -Be 2
        $run.Calls | Should -BeNullOrEmpty
        $run.Error | Should -Match 'PROJECT FALLBACK UNAVAILABLE'
        $run.Output | Should -Match 'no pinned project fetch source'
        $run.Log | Should -Match '# phase: source-unavailable'
        $run.Output | Should -Not -Match 'PAYLOAD_RAN'
    }

    It 'explains missing guest authentication after a project HTTP error' {
        $run = $script:ProjectFetchRuns.unauthenticated
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'private/project at 2222222222222222222222222222222222222222'
        $run.Output | Should -Match 'private project requires guest authentication'
        $run.Output | Should -Match 'HTTP:\s+404'
        $run.Log | Should -Match '# http-status: 404'
        $run.Output | Should -Not -Match 'PAYLOAD_RAN'
    }

    It 'reports a rejected guest credential without exposing it' {
        $run = $script:ProjectFetchRuns.denied
        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'guest credential can read the named repository'
        $run.Log | Should -Match '# http-status: 401'
        $run.RemainingAuthFiles | Should -Be 0
        ($run.Output + $run.Error + $run.Log + $run.Calls) | Should -Not -Match 'fixture-project-token-that-must-not-appear'
    }

    It 'keeps the retry library pinned to the framework while the payload uses the project' {
        $run = $script:ProjectFetchRuns.library
        $run.ExitCode | Should -Be 0
        $run.Calls | Should -Match 'https://raw\.githubusercontent\.com/private/project/2222222222222222222222222222222222222222/example/workload\.sh'
        $run.Calls | Should -Match 'https://raw\.githubusercontent\.com/framework/repository/1111111111111111111111111111111111111111/automation/yuruna-retry\.sh'
        $run.Output | Should -Match 'sha256 verified \(automation/yuruna-retry\.sh\)'
        $run.Output | Should -Match 'PAYLOAD_RAN'
    }

    It 'stops before sending a request when private credential setup fails' {
        $run = $script:ProjectFetchRuns.auth_setup
        $run.ExitCode | Should -Be 2
        $run.Calls | Should -BeNullOrEmpty
        $run.Error | Should -Match 'GITHUB AUTHENTICATION UNAVAILABLE'
        $run.Output | Should -Match 'guest authentication unavailable'
        $run.Log | Should -Match '# phase: authentication-unavailable'
        ($run.Output + $run.Error + $run.Log) | Should -Not -Match 'fixture-project-token-that-must-not-appear'
    }

    It 'refuses mismatched project bytes even after its bounded re-fetch' {
        $run = $script:ProjectFetchRuns.mismatch
        $run.ExitCode | Should -Be 3
        @([regex]::Matches($run.Calls, '@@REQUEST')).Count | Should -Be 2
        $run.Output | Should -Match 'integrity mismatch -- refusing to run'
        $run.Log | Should -Match '# phase: integrity-failed'
        $run.Output | Should -Not -Match 'PAYLOAD_RAN'
    }

    It 'replaces a stale successful log with the failed download and current invocation' -ForEach @(
        @{ Name = 'server_error'; Status = '503' }, @{ Name = 'transport'; Status = 'unavailable' }
    ) {
        $run = $script:ProjectFetchRuns[$Name]
        $run.ExitCode | Should -Be 2
        $run.Log | Should -Match '# stepInvocationId: step-'
        $run.Log | Should -Match '# sequenceInvocationId: sequence-current'
        $run.Log | Should -Match '# script:\s+project/example/workload\.sh'
        $run.Log | Should -Match ('# http-status: ' + $Status)
        $run.Log | Should -Match '# phase: download-failed'
        $run.Log | Should -Match '# exit code: 2'
        $run.Log | Should -Match '# ended:'
        $run.Log | Should -Not -Match 'OLD_SUCCESS_SENTINEL|old-step|old/success'
    }

    It 'keeps framework payload fallback independent of project coordinates' {
        $run = $script:ProjectFetchRuns.framework
        $run.ExitCode | Should -Be 0
        $run.Calls | Should -Match 'framework/repository/1111111111111111111111111111111111111111/guest/workload\.sh'
        $run.Calls | Should -Not -Match 'private/project'
        $script:ProjectFetchRuns.framework_missing.ExitCode | Should -Be 2
        $script:ProjectFetchRuns.framework_missing.Calls | Should -BeNullOrEmpty
    }

    It 'records one complete identity header and preserves a failing payload exit' {
        $run = $script:ProjectFetchRuns.payload_failure
        $run.ExitCode | Should -Be 7
        $run.Log | Should -Match '^# Yuruna fetch-and-execute log'
        foreach ($name in 'script', 'stepInvocationId', 'sequenceInvocationId') {
            @([regex]::Matches($run.Log, ('(?m)^# ' + $name + ':'))).Count | Should -Be 1
        }
        $run.Log | Should -Match '# ---'
        $run.Log | Should -Match '# phase: executing-payload'
        $run.Log | Should -Match '# exit code: 7'
        $run.Output | Should -Match 'PAYLOAD_RAN'
        $run.Output | Should -Not -Match 'FETCHED AND EXECUTED:'
    }

    It 'redacts URL credentials and response cookies from console and stored evidence' {
        $run = $script:ProjectFetchRuns.sensitive_url
        $run.ExitCode | Should -Be 0
        ($run.Output + $run.Error + $run.Log) | Should -Not -Match 'fixture-project-token-that-must-not-appear|operator:|Set-Cookie'
        $run.Log | Should -Match 'http://\[REDACTED\]@host\.invalid/source/\?\[REDACTED\]'
    }
}
