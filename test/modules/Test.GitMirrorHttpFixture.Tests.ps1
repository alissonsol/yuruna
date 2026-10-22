<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4270c47a-c70b-40ee-9c3c-880f0421e5a7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

Describe 'The seed Apache configuration serves production Git mirror transports' -Skip:(-not $IsLinux) {
    BeforeAll {
        foreach ($program in @('python3', 'apache2', 'git', 'go')) {
            if (-not (Get-Command $program -ErrorAction SilentlyContinue)) { throw "Apache mirror fixture requires $program." }
        }
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $module = Join-Path $root 'test/extension/caching-proxy-service'
        $binary = Join-Path $TestDrive mirror-fixture
        Push-Location $module
        try {
            & go test -c -o $binary .
            if ($LASTEXITCODE) { throw 'Production mirror test binary failed to build.' }
        } finally { Pop-Location }
        $output = @(& python3 (Join-Path $root 'tools/git_mirror_http_fixture.py') --root $root --binary $binary 2>&1)
        if ($LASTEXITCODE) { throw "Apache fixture failed: $($output -join "`n")" }
        $script:TransportEvidence = ($output -join "`n") | ConvertFrom-Json
    }

    It 'fetches exact retained commits shallowly under Git protocols 0, 1 and 2' {
        $script:TransportEvidence.smartHttpProtocols | Should -BeTrue
    }
    It 'rejects receive-pack discovery and pushes' {
        $script:TransportEvidence.pushDenied | Should -BeTrue
    }
    It 'serves the exact retained raw blob' {
        $script:TransportEvidence.rawPinned | Should -BeTrue
    }
    It 'separates the 4 KiB resolver body from upload-pack requests' {
        $script:TransportEvidence.bodyLimits | Should -BeTrue
    }
    It 'allows a mirror backend response delayed longer than five seconds' {
        $script:TransportEvidence.backendDelaySeconds | Should -BeGreaterThan 5
    }
    It 'keeps the landing page bounded by its five-second backend timeout' {
        $script:TransportEvidence.landingDeadlineSeconds | Should -BeLessThan 6
    }
    It 'reaches the backend immediately after it restarts' {
        $script:TransportEvidence.immediateBackendRecovery | Should -BeTrue
    }
    It 'starts without ignored worker parameters or unintended worker sharing' {
        $script:TransportEvidence.workerIsolation | Should -BeTrue
    }
    It 'releases reader leases after blocked writes and disconnected clients' {
        $script:TransportEvidence.boundedBlockedReaders | Should -BeTrue
    }
    It 'bounds an unfinished frontend request body' {
        $script:TransportEvidence.slowBodySeconds | Should -BeLessThan 23
    }
}

Describe 'Native worker fault controls preserve operator settings' -Skip:(-not $IsLinux) {
    It 'passes the isolated environment, ownership and restoration regressions without invoking systemd' {
        $root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $output = @(& python3 -B (Join-Path $root 'tools/test_git_mirror_native_worker.py') 2>&1)
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match 'Ran 6 tests'
    }
}
