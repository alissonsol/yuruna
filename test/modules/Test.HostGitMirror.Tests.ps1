<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d67854-78e5-47cc-bb39-1453d818809f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit mirror pester
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

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Force -DisableNameChecking
    $script:Sha = 'a' * 40
    $script:ReceiptFixture = Get-Content -Raw (Join-Path $PSScriptRoot '../extension/caching-proxy-service/testdata/git-mirror/receipts/vectors.json') | ConvertFrom-Json -AsHashtable
    $script:ReceiptKeys = @{ $script:ReceiptFixture.keyId = [Convert]::FromBase64String($script:ReceiptFixture.publicKey) }
    $script:RealMirrorRequest = & (Get-Module Test.HostGit) { Get-Command Invoke-GitMirrorHttpRequest }
    $script:RealOriginCommand = Get-Command Invoke-GitNetworkCommand

    function Invoke-MirrorFixtureGit {
        param([string]$Path, [string[]]$Arguments)
        $output = @(& git -C $Path @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($output -join ' ')" }
        return ($output -join "`n").Trim()
    }

    function New-LiveMirrorFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates disposable repositories and one test helper process under Pester TestDrive.')]
        param()
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $upstream = Join-Path $root upstream
        [IO.Directory]::CreateDirectory($upstream) | Out-Null
        $null = Invoke-MirrorFixtureGit $upstream @('init', '--quiet', '--initial-branch=main')
        $null = Invoke-MirrorFixtureGit $upstream @('config', 'user.name', 'fixture')
        $null = Invoke-MirrorFixtureGit $upstream @('config', 'user.email', 'fixture@example.invalid')
        [IO.File]::WriteAllText((Join-Path $upstream source.txt), 'first source')
        $null = Invoke-MirrorFixtureGit $upstream @('add', '.')
        $null = Invoke-MirrorFixtureGit $upstream @('commit', '--quiet', '-m', 'first')
        $revision = Invoke-MirrorFixtureGit $upstream @('rev-parse', 'HEAD')
        $upstreamUrl = ([UriBuilder]::new('file', '', -1, $upstream)).Uri.AbsoluteUri
        $config = @{
            root = (Join-Path $root mirror); stateRoot = (Join-Path $root state); readerRoot = (Join-Path $root reader)
            signingKey = (Join-Path $PSScriptRoot '../extension/caching-proxy-service/testdata/git-mirror/receipts/test-key.pem')
            repositories = @('example/repo'); refreshIntervalMilliseconds = 0; noUpstreamPath = (Join-Path $root no-upstream)
        }
        $configPath = Join-Path $root fixture.json
        [IO.File]::WriteAllText($configPath, (ConvertTo-Json $config -Compress))
        $start = [Diagnostics.ProcessStartInfo]::new($script:MirrorFixtureBinary)
        $start.ArgumentList.Add('-test.run=^TestGitMirrorFixtureProcess$')
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true; $start.RedirectStandardInput = $true
        $start.Environment['YURUNA_GIT_MIRROR_FIXTURE_CONFIG'] = $configPath
        $count = if ($start.Environment['GIT_CONFIG_COUNT']) { [int]$start.Environment['GIT_CONFIG_COUNT'] } else { 0 }
        $start.Environment["GIT_CONFIG_KEY_$count"] = "url.$upstreamUrl.insteadOf"
        $start.Environment["GIT_CONFIG_VALUE_$count"] = 'https://github.com/example/repo.git'
        $start.Environment['GIT_CONFIG_COUNT'] = [string]($count + 1)
        $process = [Diagnostics.Process]::Start($start)
        $errors = $process.StandardError.ReadToEndAsync()
        try {
            $ready = $process.StandardOutput.ReadLineAsync()
            if (-not $ready.Wait(20000) -or -not $ready.Result) { throw 'Mirror fixture did not become ready.' }
            if (-not $ready.Result.StartsWith('{', [StringComparison]::Ordinal)) {
                $rest = $process.StandardOutput.ReadToEndAsync()
                if (-not $process.WaitForExit(5000)) { $process.Kill($true); $null = $process.WaitForExit(5000) }
                throw "Mirror fixture startup failed: $($ready.Result) $($rest.GetAwaiter().GetResult()) $($errors.GetAwaiter().GetResult())"
            }
            $endpoint = ($ready.Result | ConvertFrom-Json).baseURL
            if (-not $endpoint) { throw "Invalid fixture response: $($ready.Result)" }
            return @{ root = $root; upstream = $upstream; upstreamUrl = $upstreamUrl; revision = $revision;
                process = $process; errors = $errors; mirrorRoot = $config.root; noUpstreamPath = $config.noUpstreamPath;
                context = @{ mode = 'prefer'; url = $endpoint; verificationPublicKeys = @($script:ReceiptFixture.publicKey); mirrorOnlyMaxAgeSeconds = 604800 } }
        } catch {
            if (-not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
            $process.Dispose()
            throw
        }
    }

    function Stop-LiveMirrorFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stops only the disposable fixture process started by this suite.')]
        param([hashtable]$Fixture)
        if (-not $Fixture) { return }
        $process = $Fixture.process
        try {
            if (-not $process.HasExited) {
                $process.StandardInput.Close()
                if (-not $process.WaitForExit(5000)) { $process.Kill($true); $null = $process.WaitForExit(5000) }
            }
        } finally { $process.Dispose() }
    }
}

Describe 'Host verification agrees with production Go signing vectors' {
    It 'verifies signed vector <name>' -ForEach (
        (Get-Content -Raw (Join-Path $PSScriptRoot '../extension/caching-proxy-service/testdata/git-mirror/receipts/vectors.json') | ConvertFrom-Json -AsHashtable).vectors
    ) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $envelope -Depth 6 -Compress))
        $request = $script:ReceiptFixture.request
        $result = Test-GitMirrorReceipt -Bytes $bytes -Repository $request.repository -Ref $request.ref -Nonce $request.nonce -VerificationKeys $script:ReceiptKeys -Now ([DateTimeOffset]$script:ReceiptFixture.now)
        $result.success | Should -Be ([string]::IsNullOrEmpty($expectedReason))
        $result.reason | Should -BeExactly $expectedReason
        if ($result.success -and $name -eq 'valid') { $result.payload.selectedSha | Should -BeExactly $script:Sha }
        elseif ($result.success) {
            $result.payload.status | Should -BeExactly $(if ($name -eq 'pending') { 'pending' } else { 'error' })
            $result.payload.objectReady | Should -BeFalse
            $result.payload.selectedSha | Should -BeNullOrEmpty
        }
        else { $result.payload | Should -BeNullOrEmpty }
    }

    It 'rejects duplicate envelope keys before using either payload' {
        $valid = $script:ReceiptFixture.vectors | Where-Object name -EQ valid
        $json = ConvertTo-Json -InputObject $valid.envelope -Compress
        $json = '{"keyId":"untrusted",' + $json.Substring(1)
        $result = Test-GitMirrorReceipt -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) -Repository example/repo -Ref refs/heads/main -Nonce $script:ReceiptFixture.request.nonce -VerificationKeys $script:ReceiptKeys -Now ([DateTimeOffset]$script:ReceiptFixture.now)
        $result.success | Should -BeFalse
        $result.reason | Should -BeExactly 'mirror-receipt-invalid'
        $result.payload | Should -BeNullOrEmpty
    }

    It 'rejects receipt body <kind>' -ForEach @(
        @{ kind = 'malformed-UTF8' }
        @{ kind = 'oversized' }
    ) {
        $bytes = if ($kind -eq 'oversized') { [byte[]]::new(65537) } else { [byte[]]@(255, 254, 253) }
        $result = Test-GitMirrorReceipt -Bytes $bytes -Repository example/repo -Ref refs/heads/main -Nonce $script:ReceiptFixture.request.nonce -VerificationKeys $script:ReceiptKeys -Now ([DateTimeOffset]$script:ReceiptFixture.now)
        $result.success | Should -BeFalse
        $result.payload | Should -BeNullOrEmpty
    }
}

Describe 'Host source selection preserves trust and source policy' {
    BeforeEach {
        & (Get-Module Test.HostGit) { $script:GitMirrorCapabilityCache.Clear() }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            @{ ExitCode = 0; Output = "ref: refs/heads/main`tHEAD`n$('a' * 40)`tHEAD" }
        }
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest {
            @{ success = $false; statusCode = 503; bytes = [byte[]]@(); reason = 'mirror-unavailable' }
        }
    }

    It 'does not contact a mirror without an enrolled key' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'https://github.com/acme/framework.git' `
            -Ref HEAD -SourceContext @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @(); mirrorOnlyMaxAgeSeconds = 604800 } `
            -Operation Gate
        $selection.success | Should -BeTrue
        $selection.selectedSha | Should -BeExactly $script:Sha
        $selection.verification | Should -BeExactly 'origin-direct'
        $selection.fallbackReason | Should -BeExactly 'mirror-untrusted'
        @($selection.attempts | Where-Object source -EQ mirror).Count | Should -Be 0
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 0
    }

    It 'keeps explicit off mode on the configured origin' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'https://github.com/acme/framework.git' `
            -Ref HEAD -SourceContext @{ mode = 'off'; url = 'http://127.0.0.1:1' } -Operation Gate
        $selection.success | Should -BeTrue
        $selection.verification | Should -BeExactly 'not-applicable'
        $selection.fallbackReason | Should -BeNullOrEmpty
        @($selection.attempts | Where-Object source -EQ mirror).Count | Should -Be 0
    }

    It 'rejects an unknown source reason in a handed-off selection' {
        $context = @{ mode = 'off' }
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context
        $selection.success | Should -BeTrue
        $selection.fallbackReason = 'unknown-future-reason'
        $valid = Test-GitSourceSelection -Selection $selection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $context
        $valid.success | Should -BeFalse
    }

    It 'preserves a configured local repository source' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'file:///operator/project' `
            -Ref HEAD -SourceContext @{ mode = 'prefer'; url = 'http://127.0.0.1:1' } -Operation Gate
        $selection.success | Should -BeTrue
        $selection.verification | Should -BeExactly 'not-applicable'
        $selection.fetchUrl | Should -BeExactly 'file:///operator/project'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1 -ParameterFilter {
            $GitArgs -contains 'file:///operator/project'
        }
    }

    It 'refuses malformed trust configuration before network access' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'https://github.com/acme/framework.git' `
            -Ref HEAD -SourceContext @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @('not base64') } -Operation Gate
        $selection.success | Should -BeFalse
        $selection.failureClass | Should -BeExactly 'bootstrap_sync'
        $selection.detail | Should -Match 'verification'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0
    }

    It 'does not start origin work after the enclosing deadline' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'https://github.com/acme/framework.git' `
            -Ref HEAD -SourceContext @{ mode = 'off' } -Operation Poll `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(-1))
        $selection.success | Should -BeFalse
        $selection.failureClass | Should -BeExactly 'network_timeout'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0
    }

    It 'keeps authoritative missing refs distinct from a transport outage' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 2; Output = '' } }
        $selection = Resolve-GitSourceSelection -RepositoryUrl 'https://github.com/acme/framework.git' `
            -Ref refs/heads/missing -SourceContext @{ mode = 'off' } -Operation Gate
        $selection.success | Should -BeFalse
        $selection.failureClass | Should -BeExactly 'project_access_denied'
        $selection.fallbackReason | Should -BeExactly 'ref-missing-confirmed'
    }

    It 'distinguishes transport failures from certificate configuration (<Case>)' -ForEach @(
        @{ Case = 'low-speed timeout'; Output = "fatal: unable to access 'http://127.0.0.1:33007/fixture/project.git/': Operation too slow. Less than 1 bytes/sec transferred the last 1 seconds"; Class = 'network_timeout' }
        @{ Case = 'TLS premature termination'; Output = 'gnutls_handshake() failed: The TLS connection was non-properly terminated.'; Class = 'network_timeout' }
        @{ Case = 'TLS connection reset'; Output = 'OpenSSL SSL_connect: Connection reset by peer'; Class = 'network_timeout' }
        @{ Case = 'untrusted certificate'; Output = 'SSL certificate problem: unable to get local issuer certificate'; Class = 'bootstrap_sync' }
        @{ Case = 'certificate hostname'; Output = "SSL: no alternative certificate subject name matches target host name 'github.com'"; Class = 'bootstrap_sync' }
        @{ Case = 'missing CA file'; Output = 'error setting certificate file: /missing/ca.pem'; Class = 'bootstrap_sync' }
    ) {
        $script:OriginError = $Output
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 128; Output = $script:OriginError } }
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext @{ mode = 'off' }
        $selection.success | Should -BeFalse
        $selection.failureClass | Should -BeExactly $Class
    }

    It 'preserves signature failure evidence when direct origin succeeds' {
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest {
            if ($Url.EndsWith('/status.json')) {
                return @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes('{"apiVersion":1,"capabilities":["resolve"]}'); reason = '' }
            }
            $vector = $script:ReceiptFixture.vectors | Where-Object name -EQ tampered-payload
            @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $vector.envelope -Compress)); reason = '' }
        }
        $context = @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @($script:ReceiptFixture.publicKey) }
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context
        $selection.success | Should -BeTrue
        $selection.verification | Should -BeExactly origin-direct
        $selection.failureClass | Should -BeExactly source_integrity
        $selection.fallbackReason | Should -BeExactly mirror-receipt-invalid
        @($selection.attempts | Where-Object failureClass -EQ source_integrity).Count | Should -Be 1
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1
    }

    It 'does not treat an unsigned missing-worker response as content authority or a bad signature' {
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest {
            if ($Url.EndsWith('/status.json')) {
                return @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes('{"apiVersion":1,"capabilities":["resolve"]}'); reason = '' }
            }
            @{ success = $false; statusCode = 503; bytes = [Text.Encoding]::UTF8.GetBytes('{"reason":"mirror-unavailable","detail":"signing-key-absent"}'); reason = 'mirror-unavailable' }
        }
        $context = @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @($script:ReceiptFixture.publicKey) }
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context
        $selection.success | Should -BeTrue
        $selection.verification | Should -BeExactly origin-direct
        $selection.failureClass | Should -BeNullOrEmpty
        $selection.fallbackReason | Should -BeExactly mirror-unavailable
        $selection.proof | Should -BeNullOrEmpty
    }

    It 'expires negative capability after five seconds and invalidates it when configuration changes' {
        $context = @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @($script:ReceiptFixture.publicKey); mirrorOnlyMaxAgeSeconds = 604800 }
        $now = [DateTimeOffset]::UtcNow
        $null = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context -Clock { $now }
        $null = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context -Clock { $now.AddSeconds(4) }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 1
        $null = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context -Clock { $now.AddSeconds(6) }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 2
        $context.mirrorOnlyMaxAgeSeconds = 0
        $null = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context -Clock { $now.AddSeconds(7) }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 3
    }

    It 'preserves credentialed legacy project transport without creating mirror provenance' {
        $root = Join-Path $TestDrive legacy
        [IO.Directory]::CreateDirectory($root) | Out-Null
        $url = 'https://fixture-user:fixture-password@example.invalid/team/project.git'
        Mock -ModuleName Test.HostGit Invoke-GitSelectedFetch { throw 'Legacy embedded credentials must not enter selected mirror transport.' }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs[0] -eq 'ls-remote') { return @{ ExitCode = 0; Output = "$('a' * 40)`tHEAD" } }
            return @{ ExitCode = 1; Output = 'fixture clone failure' }
        }
        $result = Update-ProjectClone -RepoRoot $root -ProjectUrl $url -SourceContext @{ mode = 'off' } -Confirm:$false 6>$null
        $result.success | Should -BeFalse
        $result.sourceSelection | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1 -ParameterFilter { $GitArgs[0] -eq 'clone' -and $GitArgs -contains $url }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitSelectedFetch -Exactly -Times 0
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 0
    }
}

Describe 'An absent or unavailable mirror preserves the real origin credential chain' {
    BeforeEach {
        & (Get-Module Test.HostGit) { $script:GitMirrorCapabilityCache.Clear() }
        Mock -ModuleName Test.HostGit Get-YurunaGitAuthAttemptList { @() }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommandOnce {
            @{ ExitCode = 0; Output = "ref: refs/heads/main`tHEAD`n$('a' * 40)`tHEAD" }
        }
    }

    It 'uses direct GitHub when <Case>' -ForEach @(
        @{ Case = 'the host has not enrolled a mirror key'; Stage = 'untrusted'; Status = 0; Body = ''; ExpectedReason = 'mirror-untrusted'; HttpCalls = 0 }
        @{ Case = 'the old proxy returns a capability 404 page'; Stage = 'capability'; Status = 404; Body = '<html>Not Found</html>'; ExpectedReason = 'mirror-unavailable'; HttpCalls = 1 }
        @{ Case = 'the old proxy serves HTML at the capability endpoint'; Stage = 'capability'; Status = 200; Body = '<html>Proxy home</html>'; ExpectedReason = 'mirror-unavailable'; HttpCalls = 1 }
        @{ Case = 'the proxy connection is refused'; Stage = 'capability'; Status = 0; Body = ''; ExpectedReason = 'mirror-unavailable'; HttpCalls = 1 }
        @{ Case = 'the resolve route is absent'; Stage = 'resolve'; Status = 404; Body = '<html>Not Found</html>'; ExpectedReason = 'mirror-unavailable'; HttpCalls = 2 }
        @{ Case = 'the resolve worker is unavailable'; Stage = 'resolve'; Status = 502; Body = '<html>Bad Gateway</html>'; ExpectedReason = 'mirror-unavailable'; HttpCalls = 2 }
    ) {
        $script:unavailableStage = $Stage
        $script:unavailableStatus = $Status
        $script:unavailableBody = $Body
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest {
            if ($script:unavailableStage -eq 'resolve' -and $Url.EndsWith('/status.json')) {
                return @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes('{"apiVersion":1,"capabilities":["resolve"]}'); reason = '' }
            }
            @{ success = $script:unavailableStatus -eq 200; statusCode = $script:unavailableStatus;
                bytes = [Text.Encoding]::UTF8.GetBytes($script:unavailableBody); reason = 'mirror-unavailable' }
        }
        $context = @{ mode = 'prefer'; url = 'http://127.0.0.1:1';
            verificationPublicKeys = $(if ($Stage -eq 'untrusted') { @() } else { @($script:ReceiptFixture.publicKey) }) }
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $context `
            -Operation Gate -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(45))
        $selection.success | Should -BeTrue
        $selection.source | Should -BeExactly 'origin'
        $selection.verification | Should -BeExactly 'origin-direct'
        $selection.fetchUrl | Should -BeExactly 'https://github.com/example/repo.git'
        $selection.selectedSha | Should -BeExactly $script:Sha
        $selection.failureClass | Should -BeNullOrEmpty
        $selection.fallbackReason | Should -BeExactly $ExpectedReason
        $selection.proof | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommandOnce -Exactly -Times 1 -ParameterFilter {
            $GitArgs[0] -eq 'ls-remote' -and $GitArgs -contains 'https://github.com/example/repo.git' -and
                $GitArgs -notcontains '-c' -and $TimeoutSeconds -gt 0 -and $TimeoutSeconds -le 30
        }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times $HttpCalls
    }
}

Describe 'Host operations use the production mirror coordinator and Git transport' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
        $script:MirrorFixtureBinary = Join-Path $TestDrive ('git-mirror-fixture' + $(if ($IsWindows) { '.exe' } else { '' }))
        $build = Invoke-BoundedNativeCommand -FilePath go -ArgumentList @('test', '-c', '-o', $script:MirrorFixtureBinary, '.') `
            -WorkingDirectory (Join-Path $PSScriptRoot '../extension/caching-proxy-service') -TimeoutSeconds 120 `
            -Environment @{ GOCACHE = $(if ($env:GOCACHE) { $env:GOCACHE } else { Join-Path $TestDrive go-cache }) }
        if ($build.ExitCode -ne 0 -or -not (Test-BoundedNativeResultComplete -Result $build)) { throw "Cannot build production mirror fixture: $($build.StdErr)" }
    }
    BeforeEach {
        $script:Live = New-LiveMirrorFixture
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'A confirmed mirror must not contact origin.' }
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest { & $script:RealMirrorRequest @PesterBoundParameters }
    }
    AfterEach { Stop-LiveMirrorFixture $script:Live }

    It 'resolves a confirmed pin before any direct origin probe' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate
        $selection.success | Should -BeTrue -Because $selection.detail
        $selection.verification | Should -BeExactly 'mirror-confirmed'
        $selection.selectedSha | Should -BeExactly $script:Live.revision
        $selection.resolvedDefaultBranch | Should -BeExactly refs/heads/main
        $selection.fetchRef | Should -BeExactly "refs/yuruna/pins/$($script:Live.revision)"
        $selection.proof.receipt | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly
    }

    It 'keeps the gate pin when upstream advances before a shallow project fetch' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate
        $selection.success | Should -BeTrue -Because $selection.detail
        [IO.File]::WriteAllText((Join-Path $script:Live.upstream source.txt), 'later source')
        $null = Invoke-MirrorFixtureGit $script:Live.upstream @('commit', '--quiet', '-am', 'advance')
        $repo = Join-Path $script:Live.root host
        [IO.Directory]::CreateDirectory($repo) | Out-Null
        $result = Update-ProjectClone -RepoRoot $repo -ProjectUrl https://github.com/example/repo.git -SourceContext $script:Live.context -SourceSelection $selection -Confirm:$false 6>$null
        $result.success | Should -BeTrue -Because $result.errorMessage
        $result.revision | Should -BeExactly $script:Live.revision
        $project = Join-Path $repo project
        Get-Content -Raw (Join-Path $project source.txt) | Should -BeExactly 'first source'
        Invoke-MirrorFixtureGit $project @('remote', 'get-url', 'origin') | Should -BeExactly 'https://github.com/example/repo.git'
        Invoke-MirrorFixtureGit $project @('rev-parse', '--abbrev-ref', '@{upstream}') | Should -BeExactly origin/main
        Invoke-MirrorFixtureGit $project @('rev-parse', '--is-shallow-repository') | Should -BeExactly true
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly
    }

    It 'fetches the frozen SHA from origin after mirror transport failure without inventing fresh confirmation' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate
        $selection.success | Should -BeTrue -Because $selection.detail
        [IO.File]::WriteAllText((Join-Path $script:Live.upstream source.txt), 'later source')
        $null = Invoke-MirrorFixtureGit $script:Live.upstream @('commit', '--quiet', '-am', 'advance')
        Mock -ModuleName Test.HostGit Invoke-GitMirrorNetworkCommand { @{ ExitCode = 124; Output = 'connection timed out' } }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            $translated = @($GitArgs | ForEach-Object { if ($_ -ceq 'https://github.com/example/repo.git') { $script:Live.upstreamUrl } else { $_ } })
            & $script:RealOriginCommand -GitArgs $translated -TimeoutSeconds $TimeoutSeconds
        }
        $repo = Join-Path $script:Live.root host
        [IO.Directory]::CreateDirectory($repo) | Out-Null
        $result = Update-ProjectClone -RepoRoot $repo -ProjectUrl https://github.com/example/repo.git -SourceContext $script:Live.context -SourceSelection $selection -Confirm:$false 6>$null
        $result.success | Should -BeTrue -Because $result.errorMessage
        $result.revision | Should -BeExactly $script:Live.revision
        $result.sourceSelection.source | Should -BeExactly origin
        $result.sourceSelection.verification | Should -BeExactly mirror-confirmed
        $result.sourceSelection.originCheckedAt | Should -BeExactly $selection.originCheckedAt
        $result.sourceSelection.proof.receipt | Should -BeExactly $selection.proof.receipt
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 1 -Exactly -ParameterFilter {
            $GitArgs -contains 'fetch' -and $GitArgs[-1] -like "+$($script:Live.revision):refs/yuruna/source-candidates/*"
        }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly -ParameterFilter { $GitArgs -contains 'ls-remote' }
    }

    It 'rejects a moved mirror pin and retains integrity evidence after exact origin recovery' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $selection.success | Should -BeTrue -Because $selection.detail
        [IO.File]::WriteAllText((Join-Path $script:Live.upstream source.txt), 'unexpected mirror content')
        $null = Invoke-MirrorFixtureGit $script:Live.upstream @('commit', '--quiet', '-am', 'advance')
        $next = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $next.success | Should -BeTrue -Because $next.detail
        $mirror = Join-Path $script:Live.mirrorRoot 'example/repo.git'
        $null = Invoke-MirrorFixtureGit $mirror @('update-ref', $selection.fetchRef, $next.selectedSha)
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            $translated = @($GitArgs | ForEach-Object { if ($_ -ceq 'https://github.com/example/repo.git') { $script:Live.upstreamUrl } else { $_ } })
            & $script:RealOriginCommand -GitArgs $translated -TimeoutSeconds $TimeoutSeconds -DeadlineUtc $DeadlineUtc
        }
        $repo = Join-Path $script:Live.root host
        [IO.Directory]::CreateDirectory($repo) | Out-Null
        $result = Update-ProjectClone -RepoRoot $repo -ProjectUrl https://github.com/example/repo.git -SourceContext $script:Live.context -SourceSelection $selection -Confirm:$false 6>$null
        $result.success | Should -BeTrue -Because $result.errorMessage
        $result.revision | Should -BeExactly $script:Live.revision
        $result.sourceSelection.fallbackReason | Should -BeExactly mirror-content-mismatch
        $result.sourceSelection.failureClass | Should -BeExactly source_integrity
        $result.sourceSelection.verification | Should -BeExactly mirror-confirmed
        $result.sourceSelection.proof.receipt | Should -BeExactly $selection.proof.receipt
        Get-Content -Raw (Join-Path $repo project/source.txt) | Should -BeExactly 'first source'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly -ParameterFilter { $GitArgs -contains 'ls-remote' }
    }

    It 'updates through a confirmed mirror while isolating inherited credentials and proxies' {
        $repo = Join-Path $script:Live.root host
        $null = Invoke-MirrorFixtureGit $script:Live.root @('clone', '--quiet', $script:Live.upstreamUrl, $repo)
        $null = Invoke-MirrorFixtureGit $repo @('remote', 'set-url', 'origin', 'https://github.com/example/repo.git')
        $null = Invoke-MirrorFixtureGit $repo @('config', 'http.extraHeader', 'Authorization: fixture-only')
        $null = Invoke-MirrorFixtureGit $repo @('config', "http.$($script:Live.context.url)/.extraHeader", 'Proxy-Authorization: fixture-only')
        $null = Invoke-MirrorFixtureGit $repo @('config', 'http.proxy', 'http://127.0.0.1:1')
        [IO.File]::WriteAllText((Join-Path $repo operator-state.txt), 'preserve')
        [IO.File]::WriteAllText((Join-Path $script:Live.upstream source.txt), 'new source')
        $null = Invoke-MirrorFixtureGit $script:Live.upstream @('commit', '--quiet', '-am', 'advance')
        $expected = Invoke-MirrorFixtureGit $script:Live.upstream @('rev-parse', 'HEAD')
        $privateHome = Join-Path $script:Live.root credential-home
        [IO.Directory]::CreateDirectory($privateHome) | Out-Null
        [IO.File]::WriteAllText((Join-Path $privateHome '.netrc'), "default login fixture password fixture`n")
        [IO.File]::WriteAllText((Join-Path $privateHome '.gitconfig'), "[url `"http://127.0.0.1:1/`"]`n`t insteadOf = $($script:Live.context.url)/`n")
        $previousToken = $env:GH_TOKEN; $previousProxy = $env:HTTP_PROXY
        $previousHome = [Environment]::GetEnvironmentVariable('HOME')
        try {
            $env:GH_TOKEN = 'fixture-only-token'
            $env:HTTP_PROXY = 'http://127.0.0.1:1'
            [Environment]::SetEnvironmentVariable('HOME', $privateHome)
            $result = Invoke-GitRepositoryUpdate -RepoRoot $repo -SourceContext $script:Live.context -Confirm:$false
        } finally {
            $env:GH_TOKEN = $previousToken; $env:HTTP_PROXY = $previousProxy
            [Environment]::SetEnvironmentVariable('HOME', $previousHome)
        }
        $result.success | Should -BeTrue -Because $result.errorMessage
        $result.revision | Should -BeExactly $expected
        $result.sourceSelection.verification | Should -BeExactly mirror-confirmed
        Invoke-MirrorFixtureGit $repo @('rev-parse', 'HEAD') | Should -BeExactly $expected
        Get-Content -Raw (Join-Path $repo operator-state.txt) | Should -BeExactly preserve
        Invoke-MirrorFixtureGit $repo @('remote', 'get-url', 'origin') | Should -BeExactly 'https://github.com/example/repo.git'
        Invoke-MirrorFixtureGit $repo @('for-each-ref', '--format=%(refname)', 'refs/yuruna/source-candidates') | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly
    }

    It 'reuses capability for thirty seconds but never reuses a previous resolution proof' {
        $clockTime = [DateTimeOffset]::UtcNow
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate -Clock { $clockTime }
        $first.success | Should -BeTrue -Because $first.detail
        $second = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate -Clock { $clockTime.AddSeconds(29) }
        $second.success | Should -BeTrue -Because $second.detail
        $second.proof.nonce | Should -Not -Be $first.proof.nonce
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Times 1 -Exactly -ParameterFilter { $Url.EndsWith('/status.json') }
        $third = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Operation Gate -Clock { $clockTime.AddSeconds(31) }
        $third.success | Should -BeTrue -Because $third.detail
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Times 2 -Exactly -ParameterFilter { $Url.EndsWith('/status.json') }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Times 3 -Exactly -ParameterFilter {
            $Url.EndsWith('/resolve') -and -not (ConvertFrom-Json $Body -AsHashtable).ContainsKey('operationId')
        }
    }

    It 'uses a retained pin only after both routes fail as transport and retains its confirmation time' {
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $first.success | Should -BeTrue -Because $first.detail
        [IO.File]::WriteAllText($script:Live.noUpstreamPath, 'fixture outage')
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 124; Output = 'connection timed out' } }
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context -InstalledRevision $script:Live.revision
        $selected.success | Should -BeTrue -Because $selected.detail
        $selected.verification | Should -BeExactly mirror-stale
        $selected.failureClass | Should -BeExactly host_network_degraded
        $selected.fallbackReason | Should -BeExactly mirror-upstream-unreachable
        $selected.originCheckedAt | Should -BeExactly $first.originCheckedAt
        $selected.selectedSha | Should -BeExactly $first.selectedSha
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1
    }

    It 'uses direct confirmation when only the mirror upstream route is blocked' {
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $first.success | Should -BeTrue -Because $first.detail
        [IO.File]::WriteAllText($script:Live.noUpstreamPath, 'fixture outage')
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            $translated = @($GitArgs | ForEach-Object { if ($_ -ceq 'https://github.com/example/repo.git') { $script:Live.upstreamUrl } else { $_ } })
            & $script:RealOriginCommand -GitArgs $translated -TimeoutSeconds $TimeoutSeconds -DeadlineUtc $DeadlineUtc
        }
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $selected.success | Should -BeTrue -Because $selected.detail
        $selected.verification | Should -BeExactly origin-direct
        $selected.source | Should -BeExactly mirror
        $selected.selectedSha | Should -BeExactly $first.selectedSha
        $selected.fallbackReason | Should -BeExactly mirror-upstream-unreachable
        $selected.failureClass | Should -BeNullOrEmpty
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1
    }

    It 'does not resurrect a retained pin after direct origin denies access' {
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $first.success | Should -BeTrue -Because $first.detail
        [IO.File]::WriteAllText($script:Live.noUpstreamPath, 'fixture outage')
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 128; Output = 'fatal: Authentication failed' } }
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $selected.success | Should -BeFalse
        $selected.failureClass | Should -BeExactly project_access_denied
        $selected.selectedSha | Should -BeNullOrEmpty
        $selected.verification | Should -BeNullOrEmpty
    }

    It 'preserves a newer installed project when only an older stale pin is available' -ForEach @(
        @{ provenance = 'legacy'; recovered = $false }
        @{ provenance = 'origin-direct'; recovered = $false }
        @{ provenance = 'origin-direct'; recovered = $true }
    ) {
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $first.success | Should -BeTrue -Because $first.detail
        [IO.File]::WriteAllText((Join-Path $script:Live.upstream source.txt), 'new installed source')
        $null = Invoke-MirrorFixtureGit $script:Live.upstream @('commit', '--quiet', '-am', 'new installed source')
        $installedSha = Invoke-MirrorFixtureGit $script:Live.upstream @('rev-parse', 'HEAD')
        $repo = Join-Path $script:Live.root host
        [IO.Directory]::CreateDirectory($repo) | Out-Null
        $null = Invoke-MirrorFixtureGit $repo @('clone', '--quiet', $script:Live.upstreamUrl, 'project')
        if ($recovered) { Move-Item -LiteralPath (Join-Path $repo project) -Destination (Join-Path $repo project.previous) }
        $installed = if ($provenance -eq 'origin-direct') {
            @{ selectedSha = $installedSha; repository = 'example/repo'; ref = 'HEAD'; verification = 'origin-direct'; originCheckedAt = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o') }
        } else { $null }
        [IO.File]::WriteAllText($script:Live.noUpstreamPath, 'fixture outage')
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 124; Output = 'connection timed out' } }
        $result = Update-ProjectClone -RepoRoot $repo -ProjectUrl https://github.com/example/repo.git -SourceContext $script:Live.context -InstalledProvenance $installed -Confirm:$false 6>$null
        $result.success | Should -BeFalse
        $result.failureClass | Should -BeExactly network_timeout
        $result.sourceSelection.fallbackReason | Should -BeExactly mirror-stale-rollback-blocked
        Invoke-MirrorFixtureGit (Join-Path $repo project) @('rev-parse', 'HEAD') | Should -BeExactly $installedSha
        Get-Content -Raw (Join-Path $repo project/source.txt) | Should -BeExactly 'new installed source'
        Test-Path (Join-Path $repo project.incoming) | Should -BeFalse
        Test-Path (Join-Path $repo project.previous) | Should -BeFalse
    }

    It 'rechecks stale age even when the same installed pin remains available' {
        $first = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $first.success | Should -BeTrue -Because $first.detail
        [IO.File]::WriteAllText($script:Live.noUpstreamPath, 'fixture outage')
        $script:Live.context.mirrorOnlyMaxAgeSeconds = 1
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { @{ ExitCode = 124; Output = 'connection timed out' } }
        $now = [DateTimeOffset]::UtcNow.AddSeconds(10)
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context -InstalledRevision $script:Live.revision -Clock { $now }
        $selected.success | Should -BeFalse
        $selected.fallbackReason | Should -BeExactly mirror-stale-expired
        $selected.failureClass | Should -BeExactly network_timeout
    }

    It 'uses protected first acceptance for a long cycle but refuses expiry bypass through a selection field' {
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -SourceContext $script:Live.context
        $selected.success | Should -BeTrue -Because $selected.detail
        $accepted = [DateTimeOffset]$selected.acceptedAt
        $later = $accepted.AddMinutes(10)
        $direct = Test-GitSourceSelection -Selection $selected -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Now $later
        $direct.success | Should -BeFalse
        $direct.reason | Should -BeExactly mirror-receipt-time-invalid
        $handoff = Test-GitSourceSelection -Selection $selected -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Now $later -AcceptedAt $accepted
        $handoff.success | Should -BeTrue -Because $handoff.reason
        $script:Live.context.verificationPublicKeys = @()
        $retired = Test-GitSourceSelection -Selection $selected -RepositoryUrl https://github.com/example/repo.git -Ref HEAD -SourceContext $script:Live.context -Now $later -AcceptedAt $accepted
        $retired.success | Should -BeFalse
    }
}

Describe 'Pending work shares the caller deadline without extending it' {
    BeforeEach {
        & (Get-Module Test.HostGit) { $script:GitMirrorCapabilityCache.Clear() }
        $script:BudgetStart = [DateTimeOffset]$script:ReceiptFixture.now
        $script:BudgetClock = $script:BudgetStart
        $script:RequestLimits = [Collections.Generic.List[double]]::new()
        Mock -ModuleName Test.HostGit Get-GitMirrorNonce { $script:ReceiptFixture.request.nonce }
        Mock -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest {
            if ($Url.EndsWith('/status.json')) {
                $script:BudgetClock = $script:BudgetClock.AddSeconds($TimeoutSeconds)
                return @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes('{"apiVersion":1,"capabilities":["resolve"]}'); reason = '' }
            }
            $script:RequestLimits.Add($TimeoutSeconds)
            $script:BudgetClock = $script:BudgetClock.AddSeconds($TimeoutSeconds)
            $vector = $script:ReceiptFixture.vectors | Where-Object name -EQ pending
            @{ success = $true; statusCode = 200; bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $vector.envelope -Compress)); reason = '' }
        }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            @{ ExitCode = 0; Output = "$('a' * 40)`trefs/heads/main" }
        }
        $script:BudgetContext = @{ mode = 'prefer'; url = 'http://127.0.0.1:1'; verificationPublicKeys = @($script:ReceiptFixture.publicKey) }
    }

    It 'bounds <operation> and leaves the documented origin remainder' -ForEach @(
        @{ operation = 'Framework'; mirrorSeconds = 130; requests = 7; originSeconds = 30; reason = 'mirror-budget-exhausted' }
        @{ operation = 'Gate'; mirrorSeconds = 45; requests = 3; originSeconds = 30; reason = 'mirror-budget-exhausted' }
        @{ operation = 'Project'; mirrorSeconds = 43; requests = 2; originSeconds = 30; reason = 'mirror-budget-exhausted' }
        @{ operation = 'Poll'; mirrorSeconds = 23; requests = 1; originSeconds = 7; reason = 'mirror-populating' }
    ) {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref refs/heads/main `
            -SourceContext $script:BudgetContext -Operation $operation -DeadlineUtc $script:BudgetStart.AddSeconds(200) -Clock { $script:BudgetClock }
        $selection.success | Should -BeTrue -Because $selection.detail
        $selection.verification | Should -BeExactly origin-direct
        $selection.fallbackReason | Should -BeExactly $reason
        ($script:BudgetClock - $script:BudgetStart).TotalSeconds | Should -Be $mirrorSeconds
        $script:RequestLimits.Count | Should -Be $requests
        @($script:RequestLimits | Where-Object { $_ -le 0 -or $_ -gt 20 }).Count | Should -Be 0
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1 -ParameterFilter { $TimeoutSeconds -eq $originSeconds }
        Should -Invoke -ModuleName Test.HostGit Invoke-GitMirrorHttpRequest -Exactly -Times 1 -ParameterFilter {
            $Url.EndsWith('/resolve') -and -not (ConvertFrom-Json $Body -AsHashtable).ContainsKey('operationId')
        }
    }

    It 'does not restart the enclosing deadline when a running population job continues' {
        $selection = Resolve-GitSourceSelection -RepositoryUrl https://github.com/example/repo.git -Ref refs/heads/main `
            -SourceContext $script:BudgetContext -Operation Framework -DeadlineUtc $script:BudgetStart.AddSeconds(80) -Clock { $script:BudgetClock }
        $selection.success | Should -BeFalse
        $selection.failureClass | Should -BeExactly network_timeout
        $selection.fallbackReason | Should -BeExactly mirror-budget-exhausted
        ($script:BudgetClock - $script:BudgetStart).TotalSeconds | Should -Be 80
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0
    }
}
