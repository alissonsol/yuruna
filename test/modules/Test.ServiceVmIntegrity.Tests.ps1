<#PSScriptInfo
.VERSION 2026.10.26
.GUID 4229d039-c021-419e-a736-76c0a2f58264
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service seed digest archive ca pin pester
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
    Pins that service VMs build and trust only what the building host seeded:
    the framework archive and the proxy's Go sources by SHA-256, and the
    proxy CA by fingerprint.
.DESCRIPTION
    Service VMs used to extract the host's archive and compile the host's
    working tree over plain HTTP without any check, and every guest trusted
    whatever /ca.crt answered at the host address. The digests and the
    fingerprint now travel in the seed, which is the channel the host
    controls. The archive cases use a throwaway repository, the shell cases
    run the seeded shell code with stand-ins for wget and the trust store.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Fixtures set and restore environment variables read by the shell code under test.')]
param()

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostGit.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CachingProxyService.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -Global -DisableNameChecking

    function New-TestCaPem {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture certificate.')]
        param([string]$Name)
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        try {
            $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new("CN=$Name", $rsa,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509BasicConstraintsExtension]::new($true, $false, 0, $true))
            $cert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
            try { return $cert.ExportCertificatePem() + "`n" } finally { $cert.Dispose() }
        } finally { $rsa.Dispose() }
    }
    $script:CaA = New-TestCaPem -Name 'fixture-ca-a'
    $script:CaB = New-TestCaPem -Name 'fixture-ca-b'
    $script:Bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
}

Describe 'the framework archive a service VM extracts is the seeded commit' {
    BeforeAll {
        $script:Repo = Join-Path $TestDrive 'repo'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Repo 'docs') -Force
        $git = { param([Parameter(ValueFromRemainingArguments)]$GitArgs) & git -C $script:Repo -c user.name=fixture -c user.email=fixture@example.invalid @GitArgs 2>&1 | Out-Null }
        & git init -q $script:Repo
        Set-Content -LiteralPath (Join-Path $script:Repo 'VERSION') -Value '1' -NoNewline
        Set-Content -LiteralPath (Join-Path $script:Repo 'docs/private.md') -Value 'not shipped' -NoNewline
        & $git add -A; & $git commit -q -m one
        $script:First = (& git -C $script:Repo rev-parse HEAD).Trim()
        Set-Content -LiteralPath (Join-Path $script:Repo 'VERSION') -Value '2' -NoNewline
        & $git commit -q -am two
        $script:Second = (& git -C $script:Repo rev-parse HEAD).Trim()
    }
    It 'hashes a commit to the same digest every time, and differently from another commit' {
        $a = Get-YurunaGitArchiveDigest -RepoDir $script:Repo -Commit $script:First -ExcludePath @('docs')
        $b = Get-YurunaGitArchiveDigest -RepoDir $script:Repo -Commit $script:First -ExcludePath @('docs')
        $a | Should -Match '^[0-9a-f]{64}$'
        $b | Should -Be $a
        Get-YurunaGitArchiveDigest -RepoDir $script:Repo -Commit $script:Second -ExcludePath @('docs') | Should -Not -Be $a
    }
    It 'writes the requested commit, leaves the excluded paths out and names the revision' {
        $out = Join-Path $TestDrive 'first.tar.gz'
        $made = Export-YurunaGitArchive -RepoDir $script:Repo -Commit $script:First -ExcludePath @('docs') -OutFile $out -Confirm:$false
        $made.Ok | Should -BeTrue
        $listing = @(& tar -tzf $out)
        $listing | Should -Contain 'VERSION'
        $listing | Should -Contain '.yuruna-revision'
        ($listing -match '^docs/') | Should -BeNullOrEmpty
        (& tar -xzOf $out VERSION) | Should -Be '1'
    }
    It 'refuses a commit the checkout does not hold' {
        (Export-YurunaGitArchive -RepoDir $script:Repo -Commit ('0' * 40) -OutFile (Join-Path $TestDrive 'none.tar.gz') -Confirm:$false).Ok | Should -BeFalse
        Get-YurunaGitArchiveDigest -RepoDir $script:Repo -Commit ('0' * 40) | Should -Be ''
    }
    It 'is the construction the status service streams, selected by ?commit=' {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1')
        $fn = [regex]::Match($source, '(?ms)^function Send-GitArchive \{.*?^\}').Value
        $fn | Should -Match 'Export-YurunaGitArchive -RepoDir'
        $fn | Should -Match "QueryString\['commit'\]"
        $fn | Should -Not -Match "& git @archiveArgs" -Because 'the route builds no archive of its own'
    }
    It 'is seeded by the renderer for the commit the seed names' {
        $base = Join-Path $TestDrive 'base.user-data'
        $overlay = Join-Path $TestDrive 'overlay.yml'
        Set-Content -LiteralPath $base -Value "#cloud-config`nwrite_files:`n  - path: /x`n    content: |`n      YURUNA_FRAMEWORK_ARCHIVE_SHA256_PLACEHOLDER`n" -NoNewline
        Set-Content -LiteralPath $overlay -Value '' -NoNewline
        $rendered = New-CloudInitUserData -BasePath $base -OverlayPath $overlay -RepoRoot $script:RepoRoot -Replacement @{} -Confirm:$false
        $ref = (& git -C $script:RepoRoot rev-parse HEAD).Trim()
        $rendered | Should -Match (Get-YurunaGitArchiveDigest -RepoDir $script:RepoRoot -Commit $ref -ExcludePath (Get-YurunaFrameworkArchiveExcludePath))
    }
    It 'hashes the paths the framework route leaves out' {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1')
        $route = [regex]::Match($source, "-ErrorLabel 'yuruna-archive' -ExcludePath @\(([^)]*)\)")
        $route.Success | Should -BeTrue
        $served = @([regex]::Matches($route.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        $served | Should -Be @(Get-YurunaFrameworkArchiveExcludePath) -Because 'a digest of other exclusions never matches the served bytes'
    }
    It '<Seed> requests the seeded commit and checks the digest before it extracts' -ForEach @(
        @{ Seed = 'stash-service' }, @{ Seed = 'pool-control-service' }, @{ Seed = 'download-agent-service' }
    ) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$Seed.base.user-data")
        $text | Should -Match 'YURUNA_FRAMEWORK_ARCHIVE_SHA256_PLACEHOLDER'
        $fetch = $text.IndexOf('yuruna-archive.tar.gz?commit=$YR_ARCHIVE_COMMIT')
        $check = $text.IndexOf('sha256sum -c --strict --status', $fetch)
        $extract = $text.IndexOf('tar -xzf "$FETCH_DIR/archive.tar.gz"', $fetch)
        ($fetch -ge 0 -and $check -gt $fetch -and $extract -gt $check) | Should -BeTrue
        $text | Should -Not -Match 'yuruna-archive\.tar\.gz" &&' -Because 'no unverified fetch of the moving HEAD remains'
    }
}

Describe 'the caching proxy builds only sources that match the seeded manifest' {
    BeforeAll {
        $script:ProxySeed = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/caching-proxy-service.base.user-data')
        $m = [regex]::Match($script:ProxySeed, '(?ms)^    yr_fetch\(\) \{.*?^    \}\r?$')
        $script:FetchFunction = ($m.Value -split "`n" | ForEach-Object { $_ -replace '^    ', '' }) -join "`n"
    }
    It 'fetches every repository file through the check' {
        $script:FetchFunction | Should -Not -BeNullOrEmpty
        ([regex]::Matches($script:ProxySeed, 'wget[^\n]*\$\{YR_BASE\}')).Count | Should -Be 1 -Because 'the only fetch of the repository base is the one inside yr_fetch'
        $script:ProxySeed | Should -Match 'YURUNA_SOURCE_MANIFEST_BASE64_PLACEHOLDER'
    }
    It 'keeps a matching file and removes a different one' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $bin = Join-Path $dir 'bin'
        $null = New-Item -ItemType Directory -Path $bin -Force
        Set-Content -LiteralPath (Join-Path $dir 'served-good') -Value 'package main' -NoNewline
        Set-Content -LiteralPath (Join-Path $dir 'served-bad') -Value 'package evil' -NoNewline
        $goodSha = (Get-FileHash -LiteralPath (Join-Path $dir 'served-good') -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest = Join-Path $dir 'build-source.sha256'
        Set-Content -LiteralPath $manifest -Value "$goodSha  test/extension/x/good.go`n$goodSha  test/extension/x/bad.go`n" -NoNewline
        # The stand-in wget copies the file named after the last path segment.
        [IO.File]::WriteAllText((Join-Path $bin 'wget'), "#!/bin/sh`nfor a; do out=`"`$prev`"; prev=`"`$a`"; done`nwhile [ `$# -gt 0 ]; do [ `"`$1`" = -O ] && dest=`"`$2`"; url=`"`$1`"; shift; done`ncase `"`$url`" in *good.go) cp '$dir/served-good' `"`$dest`";; *bad.go) cp '$dir/served-bad' `"`$dest`";; esac`n")
        & chmod +x (Join-Path $bin 'wget')
        $script = ($script:FetchFunction -replace '/etc/yuruna/build-source.sha256', $manifest) + @"

YR_BASE=http://host/yuruna-repo/; YR_FLAGS=; YR_SRC=fixture
yr_fetch test/extension/x/good.go '$dir/good.go'; echo good=`$?
yr_fetch test/extension/x/bad.go '$dir/bad.go'; echo bad=`$?
"@
        $out = (& env "PATH=${bin}:$($env:PATH)" $script:Bash -c $script 2>&1) -join "`n"
        $out | Should -Match 'good=0'
        $out | Should -Match 'bad=1'
        Test-Path -LiteralPath (Join-Path $dir 'good.go') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir 'bad.go') | Should -BeFalse
    }
    It 'manifests the working tree in ordinal order, without tests or testdata' {
        $manifest = Get-YurunaSourceDigestManifest -RepoRoot $script:RepoRoot -Path @('VERSION', 'test/extension/caching-proxy-service')
        $lines = @($manifest.TrimEnd("`n") -split "`n")
        $lines | Should -Contain ('{0}  VERSION' -f (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot 'VERSION') -Algorithm SHA256).Hash.ToLowerInvariant())
        ($lines -match '_test\.go$') | Should -BeNullOrEmpty
        ($lines -match '/testdata/') | Should -BeNullOrEmpty
        $sorted = [string[]]$lines.Clone(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $lines | Should -Be $sorted
    }
}

Describe 'the proxy CA is trusted by fingerprint' {
    BeforeEach {
        # These cases are about a host that enrolls no mirror verification key,
        # whatever this machine's own configuration enrolls.
        Mock -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey { @{} }
    }
    It 'computes the fingerprint guests compute with openssl' -Skip:(-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
        $file = Join-Path $TestDrive 'ca-a.pem'
        Set-Content -LiteralPath $file -Value $script:CaA -NoNewline
        $openssl = ((& openssl x509 -in $file -outform DER | & sha256sum) -split ' ')[0]
        Get-YurunaCertificateSha256 -Pem $script:CaA | Should -Be $openssl
        Get-YurunaCertificateSha256 -Pem 'not a certificate' | Should -Be ''
    }
    It 'keeps one owned CA, with an owner-only key, across reads' {
        $homeDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $homeDir
        Get-YurunaBumpCa -HomePath $homeDir | Should -BeNullOrEmpty
        $created = Get-YurunaBumpCa -Create -HomePath $homeDir -Confirm:$false
        $created.Sha256 | Should -Match '^[0-9a-f]{64}$'
        (Get-YurunaBumpCa -HomePath $homeDir).Sha256 | Should -Be $created.Sha256
        if (-not $IsWindows) {
            $key = Get-ChildItem -LiteralPath $homeDir -Recurse -Filter 'bump-ca.key' -File -Force | Select-Object -First 1
            ($key.UnixFileMode.value__ -band 0x3F) | Should -Be 0
        }
    }
    It 'adopts an existing proxy CA and key instead of rotating the pool root' {
        $old = Get-YurunaBumpCa -Create -HomePath (Join-Path $TestDrive 'old-builder') -Confirm:$false
        $provider = { $old }.GetNewClosure()
        $adopted = Get-YurunaBumpCa -Create -HomePath (Join-Path $TestDrive 'new-builder') -ReadExistingCa $provider -Confirm:$false
        $adopted.Sha256 | Should -BeExactly $old.Sha256
        $adopted.KeyPem | Should -BeExactly $old.KeyPem
        (Get-YurunaBumpCa -HomePath (Join-Path $TestDrive 'new-builder')).Sha256 | Should -BeExactly $old.Sha256
    }
    It 'does not read a guest or replace an already owned identity' {
        $dir = Join-Path $TestDrive 'owned-builder'
        $owned = Get-YurunaBumpCa -Create -HomePath $dir -Confirm:$false
        $read = Get-YurunaBumpCa -Create -HomePath $dir -ReadExistingCa { throw 'must not read guest' } -Confirm:$false
        $read.Sha256 | Should -BeExactly $owned.Sha256
    }
    It 'leaves storage empty when migration yields a mismatched key' {
        $a = Get-YurunaBumpCa -Create -HomePath (Join-Path $TestDrive 'pair-a') -Confirm:$false
        $b = Get-YurunaBumpCa -Create -HomePath (Join-Path $TestDrive 'pair-b') -Confirm:$false
        $provider = { @{CertPem=$a.CertPem;KeyPem=$b.KeyPem} }.GetNewClosure()
        $dir = Join-Path $TestDrive 'bad-pair'
        { Get-YurunaBumpCa -Create -HomePath $dir -ReadExistingCa $provider -Confirm:$false } | Should -Throw
        Get-YurunaBumpCa -HomePath $dir | Should -BeNullOrEmpty
    }
    It 'does not mint a new identity when migration fails' {
        $dir = Join-Path $TestDrive 'failed-read'
        { Get-YurunaBumpCa -Create -HomePath $dir -ReadExistingCa { throw 'guest unavailable' } -Confirm:$false } | Should -Throw
        Get-YurunaBumpCa -HomePath $dir | Should -BeNullOrEmpty
    }
    It 'does not overwrite a partially persisted identity' {
        $dir = Join-Path $TestDrive 'partial-pair'
        $owned = Get-YurunaBumpCa -Create -HomePath $dir -Confirm:$false
        $key = Get-ChildItem $dir -Recurse -Force -Filter bump-ca.key | Select-Object -First 1
        Remove-Item $key.FullName
        { Get-YurunaBumpCa -Create -HomePath $dir -Confirm:$false } | Should -Throw
        (Get-ChildItem $dir -Recurse -Force -Filter bump-ca.pem | Get-Content -Raw) | Should -BeExactly $owned.CertPem
    }
    It '<Platform> prepares the persistent CA before removing the proxy VM' -ForEach @(
        @{Platform='ubuntu.kvm';Remove='Remove-KvmDomainDefinition'}
        @{Platform='macos.utm';Remove='Remove-UtmTestVM'}
        @{Platform='windows.hyper-v';Remove='Remove-HyperVGuestDefinition'}
    ) {
        $source = Get-Content -Raw (Join-Path $script:RepoRoot "host/$Platform/guest.caching-proxy-service/New-VM.ps1")
        $prepare = $source.IndexOf('$bumpCa = Get-YurunaBumpCa -Create')
        $prepare | Should -BeGreaterOrEqual 0
        $source.IndexOf($Remove) | Should -BeGreaterThan $prepare
        $source | Should -Match 'Get-CachingProxyServiceLegacyCa -VMName \$VMName -Address'
    }
    It 'accepts a first use, keeps a pinned CA, and refuses a different one' {
        Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { $null }
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{} }
        (Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42').Reason | Should -Be 'first-use'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaA))
        $env:PIN_FIXTURE = $b64
        $env:PIN_SHA = Get-YurunaCertificateSha256 -Pem $script:CaA
        try {
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ caCert = $env:PIN_FIXTURE; caCertSha256 = $env:PIN_SHA; caCertSourceHost = '192.0.2.42' } }
            (Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42').Accepted | Should -BeTrue
            $refused = Resolve-YurunaPinnedProxyCa -Pem $script:CaB -CacheHost '192.0.2.42'
            $refused.Accepted | Should -BeFalse
            $refused.Reason | Should -Be 'pin-mismatch'
            $refused.Pem | Should -Be $script:CaA -Because 'the trusted CA is what callers keep using'
        } finally { Remove-Item Env:PIN_FIXTURE, Env:PIN_SHA -ErrorAction SilentlyContinue }
    }
    It 'treats a cached CA without a fingerprint as a last-good copy, not a pin' {
        # A proxy that generated a new CA on every build left a cached copy that
        # a later rebuild made stale; only a CA recorded with its fingerprint pins.
        $env:PIN_OLD = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaB))
        try {
            Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { $null }
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ ipAddress = '192.0.2.42'; caCert = $env:PIN_OLD; caCertSourceHost = '192.0.2.42' } }
            $current = Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42'
            $current.Accepted | Should -BeTrue
            $current.Reason | Should -Be 'first-use'
        } finally { Remove-Item Env:PIN_OLD -ErrorAction SilentlyContinue }
    }
    It 'records the fingerprint with the CA it caches, so the next fetch is pinned' {
        $runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $previous = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $runtime
        try {
            $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaA))
            $null = Save-CachingProxyServiceState -CaCert $b64 -CaCertSourceHost '192.0.2.42' -Confirm:$false
            (Read-CachingProxyServiceState).caCertSha256 | Should -Be (Get-YurunaCertificateSha256 -Pem $script:CaA)
            Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { $null }
            (Resolve-YurunaPinnedProxyCa -Pem $script:CaB -CacheHost '192.0.2.42').Reason | Should -Be 'pin-mismatch'
        } finally { $env:YURUNA_RUNTIME_DIR = $previous }
    }
    It 'trusts a discovered proxy on first use although this host owns another CA' {
        # The recorded proxy address can be a proxy another host built, found by
        # discovery; owning a CA says nothing about the root that proxy serves.
        $env:PIN_FIXTURE = $script:CaA
        $env:PIN_SERVED = $script:CaB
        try {
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ ipAddress = '192.0.2.42' } }
            Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { @{ CertPem = $env:PIN_FIXTURE; KeyPem = 'k'; Sha256 = 'x' } }
            Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaPem { $env:PIN_SERVED }
            Mock -ModuleName Test.CachingProxyService Save-CachingProxyServiceState { 'saved' }
            $r = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl 'http://192.0.2.42/yuruna-squid-ca.crt' -CacheHost '192.0.2.42' -MaxAttempts 1
            $r.Source | Should -Be 'live'
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.CaCertBase64)) | Should -Be $script:CaB
            $served = Resolve-CachingProxyServiceCaCertPem -LiveTimeoutSeconds 1
            $served.Source | Should -Be 'live'
            $served.Pem | Should -Be $script:CaB -Because 'guests are served the root the proxy bumps with'
        } finally { Remove-Item Env:PIN_FIXTURE, Env:PIN_SERVED -ErrorAction SilentlyContinue }
    }
    It 'accepts the owned CA from its proxy over a root pinned before the rebuild' {
        $env:PIN_FIXTURE = $script:CaA
        $env:PIN_OLD = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaB))
        $env:PIN_SHA = Get-YurunaCertificateSha256 -Pem $script:CaB
        try {
            Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { @{ CertPem = $env:PIN_FIXTURE; KeyPem = 'k'; Sha256 = 'x' } }
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ ipAddress = '192.0.2.42'; caCert = $env:PIN_OLD; caCertSha256 = $env:PIN_SHA; caCertSourceHost = '192.0.2.42' } }
            $owned = Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42'
            $owned.Accepted | Should -BeTrue
            $owned.Reason | Should -Be 'owned'
        } finally { Remove-Item Env:PIN_FIXTURE, Env:PIN_OLD, Env:PIN_SHA -ErrorAction SilentlyContinue }
    }
    It 'refuses a different root from a proxy pinned to the owned CA' {
        $env:PIN_FIXTURE = $script:CaA
        $env:PIN_OLD = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaA))
        $env:PIN_SHA = Get-YurunaCertificateSha256 -Pem $script:CaA
        try {
            Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { @{ CertPem = $env:PIN_FIXTURE; KeyPem = 'k'; Sha256 = 'x' } }
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ ipAddress = '192.0.2.42'; caCert = $env:PIN_OLD; caCertSha256 = $env:PIN_SHA; caCertSourceHost = '192.0.2.42' } }
            $refused = Resolve-YurunaPinnedProxyCa -Pem $script:CaB -CacheHost '192.0.2.42'
            $refused.Accepted | Should -BeFalse
            $refused.Reason | Should -Be 'pin-mismatch'
            $refused.Pem | Should -Be $script:CaA
        } finally { Remove-Item Env:PIN_FIXTURE, Env:PIN_OLD, Env:PIN_SHA -ErrorAction SilentlyContinue }
    }
    It 'installs the seeded CA on the proxy before it would generate one' {
        $seed = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/caching-proxy-service.base.user-data')
        $install = $seed.IndexOf('install -m 0600 /etc/yuruna/bump-ca/ca.key "$CA_DIR/ca.key"')
        $generate = $seed.IndexOf('openssl req -new -newkey rsa:2048 -sha256 -days 3650 -nodes -x509')
        ($install -ge 0 -and $generate -gt $install) | Should -BeTrue
        $seed | Should -Match 'rm -f /etc/yuruna/bump-ca/ca.key'
    }
    It 'renders the fingerprint of the CA a seed carries through <Placeholder>' -TestCases @(
        @{ Placeholder = 'YURUNA_BUMP_CA_CERT_BASE64_PLACEHOLDER' }
        @{ Placeholder = 'CA_CERT_BASE64_PLACEHOLDER' }
    ) {
        param($Placeholder)
        $base = Join-Path $TestDrive 'ca-base.user-data'
        $overlay = Join-Path $TestDrive 'ca-overlay.yml'
        Set-Content -LiteralPath $base -Value "#cloud-config`nwrite_files:`n  - path: /etc/yuruna/host.env`n    content: |`n      YURUNA_CA_SHA256=YURUNA_CA_SHA256_PLACEHOLDER`n" -NoNewline
        Set-Content -LiteralPath $overlay -Value '' -NoNewline
        $b64 = [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($script:CaA))
        $rendered = New-CloudInitUserData -BasePath $base -OverlayPath $overlay -RepoRoot $script:RepoRoot `
            -Replacement @{ $Placeholder = $b64 } -Confirm:$false
        $rendered | Should -Match ('YURUNA_CA_SHA256=' + (Get-YurunaCertificateSha256 -Pem $script:CaA))
    }
    It 'pins the CA in host.env on every service guest' -ForEach @(
        @{ Seed = 'stash-service' }, @{ Seed = 'pool-control-service' }, @{ Seed = 'download-agent-service' }, @{ Seed = 'caching-proxy-service' }
    ) {
        Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$Seed.base.user-data") |
            Should -Match '(?m)^\s+YURUNA_CA_SHA256=YURUNA_CA_SHA256_PLACEHOLDER\r?$'
    }
    It 'gives the download agent its CA in the seed rather than over HTTP' {
        $seed = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/download-agent-service.base.user-data')
        $seed | Should -Match 'YURUNA_CACHE_CA_CERT_BASE64_PLACEHOLDER'
        $seed | Should -Not -Match 'wget[^\n]*yuruna-squid-ca\.crt'
    }
}

# A host that did not build the proxy used to trust the first CA it fetched for
# that address over plain HTTP. With the lab's mirror verification key enrolled,
# it trusts only a CA the proxy's builder signed, and follows a signed rotation.
Describe 'a host that did not build the proxy trusts its CA through a signed statement' {
    BeforeAll {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try {
            $script:SigningKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rsa.ExportPkcs8PrivateKeyPem()))
            $spki = $rsa.ExportSubjectPublicKeyInfo()
        } finally { $rsa.Dispose() }
        $script:KeyId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($spki)).ToLowerInvariant()
        $script:Keys = @{ $script:KeyId = $spki }
        $other = [Security.Cryptography.RSA]::Create(3072)
        try { $script:OtherKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($other.ExportPkcs8PrivateKeyPem())) } finally { $other.Dispose() }
        $script:StatementA = ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $script:SigningKey -CaPem $script:CaA
        $script:StatementB = ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $script:SigningKey -CaPem $script:CaB
        $script:PinA = @{ ipAddress = '192.0.2.42'; caCert = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaA)); caCertSha256 = (Get-YurunaCertificateSha256 -Pem $script:CaA); caCertSourceHost = '192.0.2.42' }
    }
    BeforeEach {
        Mock -ModuleName Test.CachingProxyService Get-YurunaBumpCa { $null }
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{} }
    }

    It 'signs the CA fingerprint so an enrolled key verifies it' {
        $verdict = Test-YurunaProxyCaStatement -Statement $script:StatementA -VerificationKeys $script:Keys
        $verdict.Valid | Should -BeTrue
        $verdict.CaSha256 | Should -Be (Get-YurunaCertificateSha256 -Pem $script:CaA)
        (ConvertFrom-Json $script:StatementA).keyId | Should -Be $script:KeyId
        ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 '' -CaPem $script:CaA | Should -Be '' -Because 'no signing key means no statement'
    }
    It 'refuses a statement that is tampered with, signed by another key or not about a proxy CA' {
        $envelope = ConvertFrom-Json $script:StatementA -AsHashtable
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($envelope.payload)) -replace '"caSha256":"[0-9a-f]+"', ('"caSha256":"' + (Get-YurunaCertificateSha256 -Pem $script:CaB) + '"')
        $envelope.payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        (Test-YurunaProxyCaStatement -Statement ($envelope | ConvertTo-Json -Compress) -VerificationKeys $script:Keys).Reason | Should -Be 'statement-invalid'
        $foreign = ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $script:OtherKey -CaPem $script:CaA
        (Test-YurunaProxyCaStatement -Statement $foreign -VerificationKeys $script:Keys).Reason | Should -Be 'statement-key-not-enrolled'
        (Test-YurunaProxyCaStatement -Statement 'not json' -VerificationKeys $script:Keys).Reason | Should -Be 'statement-invalid'
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportFromPem([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:SigningKey)))
            $body = [Text.Encoding]::UTF8.GetBytes(('{"schemaVersion":1,"kind":"mirror-receipt","keyId":"' + $script:KeyId + '","caSha256":"' + (Get-YurunaCertificateSha256 -Pem $script:CaA) + '"}'))
            $sig = $rsa.SignData($body, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally { $rsa.Dispose() }
        $wrongKind = @{ keyId = $script:KeyId; payload = [Convert]::ToBase64String($body); signature = [Convert]::ToBase64String($sig) } | ConvertTo-Json -Compress
        (Test-YurunaProxyCaStatement -Statement $wrongKind -VerificationKeys $script:Keys).Reason | Should -Be 'statement-invalid'
    }
    It 'decides <Case>' -TestCases @(
        @{ Case = 'no first use without a statement once a key is enrolled'; Pinned = $false; Fetched = 'A'; Statement = ''; Keys = $true; Accepted = $false; Reason = 'statement-absent' }
        @{ Case = 'a signed CA on first use'; Pinned = $false; Fetched = 'A'; Statement = 'A'; Keys = $true; Accepted = $true; Reason = 'signed' }
        @{ Case = 'a signed rotation over the pin'; Pinned = $true; Fetched = 'B'; Statement = 'B'; Keys = $true; Accepted = $true; Reason = 'signed' }
        @{ Case = 'a pinned CA whatever its statement says'; Pinned = $true; Fetched = 'A'; Statement = 'foreign'; Keys = $true; Accepted = $true; Reason = 'pinned' }
        @{ Case = 'a statement naming another CA'; Pinned = $false; Fetched = 'B'; Statement = 'A'; Keys = $true; Accepted = $false; Reason = 'statement-ca-mismatch' }
        @{ Case = 'a statement from a key that is not enrolled'; Pinned = $true; Fetched = 'B'; Statement = 'foreign'; Keys = $true; Accepted = $false; Reason = 'statement-key-not-enrolled' }
        @{ Case = 'a changed root without a statement'; Pinned = $true; Fetched = 'B'; Statement = ''; Keys = $true; Accepted = $false; Reason = 'pin-mismatch' }
        @{ Case = 'first use on a host with no key to verify with'; Pinned = $false; Fetched = 'B'; Statement = 'B'; Keys = $false; Accepted = $true; Reason = 'first-use' }
        @{ Case = 'a pool upgrade with an old pin and no enrolled key'; Pinned = $true; Fetched = 'B'; Statement = 'B'; Keys = $false; Accepted = $false; Reason = 'pin-mismatch' }
    ) {
        param($Case, $Pinned, $Fetched, $Statement, $Keys, $Accepted, $Reason)
        $null = $Case
        if ($Pinned) {
            $env:PIN_STATE = $script:PinA | ConvertTo-Json -Compress
            Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { $env:PIN_STATE | ConvertFrom-Json -AsHashtable }
        }
        try {
            $pem = if ($Fetched -eq 'A') { $script:CaA } else { $script:CaB }
            $text = switch ($Statement) { 'A' { $script:StatementA } 'B' { $script:StatementB } 'foreign' { ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $script:OtherKey -CaPem $pem } default { '' } }
            $verdict = Resolve-YurunaPinnedProxyCa -Pem $pem -CacheHost '192.0.2.42' -Statement $text -VerificationKeys $(if ($Keys) { $script:Keys } else { @{} })
            $verdict.Reason | Should -Be $Reason
            $verdict.Accepted | Should -Be $Accepted
            if (-not $Accepted -and $Pinned) { $verdict.Pem | Should -Be $script:CaA -Because 'callers keep the root they trust' }
        } finally { Remove-Item Env:PIN_STATE -ErrorAction SilentlyContinue }
    }
    # A host that cached a root before fingerprints were recorded keeps the
    # proxy it already used until that proxy's builder publishes a statement.
    It 'trusts again, without a statement, only the root it cached for that proxy before fingerprints' {
        $legacy = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CaA))
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{ ipAddress = '192.0.2.42'; caCert = $legacy; caCertSourceHost = '192.0.2.42' } }.GetNewClosure()
        $same = Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42' -Statement '' -VerificationKeys $script:Keys
        $same.Accepted | Should -BeTrue
        $same.Reason | Should -Be 'last-good'
        $other = Resolve-YurunaPinnedProxyCa -Pem $script:CaB -CacheHost '192.0.2.42' -Statement '' -VerificationKeys $script:Keys
        $other.Reason | Should -Be 'statement-absent' -Because 'a last-good copy vouches for no other root'
        $other.Pem | Should -BeNullOrEmpty -Because 'a last-good copy is not a pin callers keep serving'
        $signed = Resolve-YurunaPinnedProxyCa -Pem $script:CaB -CacheHost '192.0.2.42' -Statement $script:StatementB -VerificationKeys $script:Keys
        $signed.Reason | Should -Be 'signed'
        (Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.43' -Statement '' -VerificationKeys $script:Keys).Reason | Should -Be 'statement-absent' -Because 'a copy cached for another proxy vouches for nothing here'
    }
    It 'reads the enrolled keys from the configuration when the caller passes none' {
        $keys = $script:Keys; Mock -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey { $keys }.GetNewClosure()
        (Resolve-YurunaPinnedProxyCa -Pem $script:CaA -CacheHost '192.0.2.42').Reason | Should -Be 'statement-absent'
        Should -Invoke -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey -Times 1 -Exactly
    }
    It 'loads real enrolled keys in a fresh guest-builder process: <Case>' -ForEach @(
        @{ Case = 'signed rotation'; StatementName = 'StatementB'; Accepted = $true; Reason = 'signed' }
        @{ Case = 'foreign signer'; StatementName = 'Foreign'; Accepted = $false; Reason = 'statement-key-not-enrolled' }
        @{ Case = 'missing statement'; StatementName = ''; Accepted = $false; Reason = 'pin-mismatch' }
        @{ Case = 'invalid enrolled key'; StatementName = 'StatementB'; Accepted = $false; Reason = 'pin-mismatch'; InvalidKey = $true }
    ) {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $configPath = Join-Path $fixture 'test.config.yml'
        $publicKey = [Convert]::ToBase64String([byte[]]$script:Keys[$script:KeyId])
        if ($InvalidKey) { $publicKey = 'invalid-key-fixture-secret' }
        $configText = @{repositories=@{projectUrl='file:///operator/project.git';mirror=@{verificationPublicKeys=@($publicKey)}}} | ConvertTo-Json -Depth 8
        Set-Content -LiteralPath $configPath -Value $configText -NoNewline
        $script:PinA | ConvertTo-Json | Set-Content (Join-Path $fixture 'yuruna-caching-proxy-service.yml')
        Set-Content (Join-Path $fixture 'served.pem') $script:CaB -NoNewline
        $statement = switch ($StatementName) {
            'StatementB' { $script:StatementB }
            'Foreign' { ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $script:OtherKey -CaPem $script:CaB }
            default { '' }
        }
        Set-Content (Join-Path $fixture 'statement.json') $statement -NoNewline
        $childScript = Join-Path $fixture 'verify.ps1'
        @'
param($RepoRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RepoRoot 'test/modules/Test.CachingProxyService.psm1') -DisableNameChecking
$pem = Get-Content -Raw (Join-Path $env:YURUNA_RUNTIME_DIR 'served.pem')
$statement = [IO.File]::ReadAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'statement.json'))
$diagnosticPath = Join-Path $env:YURUNA_RUNTIME_DIR 'key-load.log'
$verdict = Resolve-YurunaPinnedProxyCa -Pem $pem -CacheHost '192.0.2.42' -Statement $statement 6> $diagnosticPath
$keys = Get-YurunaProxyCaVerificationKey 6>> $diagnosticPath
@{keyCount=$keys.Count;verdict=$verdict;diagnostic=[IO.File]::ReadAllText($diagnosticPath)} | ConvertTo-Json -Depth 6 -Compress
'@ | Set-Content -LiteralPath $childScript
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
        foreach ($arg in @('-NoProfile', '-File', $childScript, $script:RepoRoot)) { $start.ArgumentList.Add($arg) }
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['YURUNA_CONFIG_PATH'] = $configPath
        $start.Environment['YURUNA_RUNTIME_DIR'] = $fixture
        $child = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $child.StandardOutput.ReadToEndAsync()
            $stderr = $child.StandardError.ReadToEndAsync()
            $child.WaitForExit(120000) | Should -BeTrue
            $child.ExitCode | Should -Be 0 -Because $stderr.GetAwaiter().GetResult()
            $result = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $result.keyCount | Should -Be $(if ($InvalidKey) { 0 } else { 1 })
            $result.verdict.Accepted | Should -Be $Accepted
            $result.verdict.Reason | Should -Be $Reason
            if (-not $Accepted) { $result.verdict.Pem | Should -Be $script:CaA }
            if ($InvalidKey) {
                $result.diagnostic | Should -Match 'YURUNA_PROXY_CA_KEY_LOAD_ERROR='
                $result.diagnostic | Should -Match '"stage":"key-validation"'
                $result.diagnostic | Should -Not -Match 'invalid-key-fixture-secret'
            } else { $result.diagnostic | Should -BeNullOrEmpty }
            [IO.File]::ReadAllText($configPath) | Should -BeExactly $configText
        } finally {
            if (-not $child.HasExited) { $child.Kill($true) }
            $child.Dispose()
        }
    }
    It 'seeds no CA it refused, persists none, and says why' {
        $env:PIN_SERVED = $script:CaB
        try {
            Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaPem { $env:PIN_SERVED }
            Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaStatement { '' }
            $keys = $script:Keys; Mock -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey { $keys }.GetNewClosure()
            Mock -ModuleName Test.CachingProxyService Save-CachingProxyServiceState { 'saved' }
            Mock -ModuleName Test.CachingProxyService Write-Warning { }
            $r = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl 'http://192.0.2.42/yuruna-squid-ca.crt' -CacheHost '192.0.2.42' -MaxAttempts 1
            $r.Refused | Should -BeTrue
            $r.Reason | Should -Be 'statement-absent'
            $r.CaCertBase64 | Should -Be ''
            $r.Exhausted | Should -BeFalse -Because 'the proxy answered; its CA was refused'
            Should -Invoke -ModuleName Test.CachingProxyService Save-CachingProxyServiceState -Times 0
            Should -Invoke -ModuleName Test.CachingProxyService Write-Warning -ParameterFilter { $Message -match 'yuruna-squid-ca\.sig\.json' }
        } finally { Remove-Item Env:PIN_SERVED -ErrorAction SilentlyContinue }
    }
    It 'seeds and pins a CA the proxy''s builder signed' {
        $env:PIN_SERVED = $script:CaB
        $env:PIN_STATEMENT = $script:StatementB
        try {
            Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaPem { $env:PIN_SERVED }
            Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaStatement { $env:PIN_STATEMENT }
            $keys = $script:Keys; Mock -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey { $keys }.GetNewClosure()
            Mock -ModuleName Test.CachingProxyService Save-CachingProxyServiceState { 'saved' }
            $r = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl 'http://192.0.2.42/yuruna-squid-ca.crt' -CacheHost '192.0.2.42' -MaxAttempts 1
            $r.Refused | Should -BeFalse
            $r.Reason | Should -Be 'signed'
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($r.CaCertBase64)) | Should -Be $script:CaB
            Should -Invoke -ModuleName Test.CachingProxyService Save-CachingProxyServiceState -Times 1 -Exactly
        } finally { Remove-Item Env:PIN_SERVED, Env:PIN_STATEMENT -ErrorAction SilentlyContinue }
    }
    It 'sends a host download direct when the proxy''s CA is not trusted' {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostDownload.psm1') -Force -DisableNameChecking
        $env:PIN_SERVED = $script:CaB
        try {
            Mock -ModuleName Yuruna.HostDownload Test-CachingProxyServicePort { $true }
            Mock -ModuleName Yuruna.HostDownload Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value $env:PIN_SERVED -NoNewline }
            Mock -ModuleName Yuruna.HostDownload Get-CachingProxyServiceCaStatement { '' }
            Mock -ModuleName Yuruna.HostDownload Write-YurunaProxyCaRefusal { }
            $keys = $script:Keys; Mock -ModuleName Test.CachingProxyService Get-YurunaProxyCaVerificationKey { $keys }.GetNewClosure()
            $before = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'yuruna-squid-ca-*.pem' -ErrorAction SilentlyContinue).Count
            Get-CacheProxyForHostDownload -Uri 'https://example.invalid/image.iso' -ResolveCacheHostIp { '192.0.2.42' } | Should -BeNullOrEmpty
            Should -Invoke -ModuleName Yuruna.HostDownload Write-YurunaProxyCaRefusal -Times 1 -Exactly
            @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'yuruna-squid-ca-*.pem' -ErrorAction SilentlyContinue).Count | Should -Be $before -Because 'the refused CA file is removed'
            $signingKey = $script:SigningKey; Mock -ModuleName Yuruna.HostDownload Get-CachingProxyServiceCaStatement { ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 $signingKey -CaPem $env:PIN_SERVED }.GetNewClosure()
            $cfg = Get-CacheProxyForHostDownload -Uri 'https://example.invalid/image.iso' -ResolveCacheHostIp { '192.0.2.42' }
            $cfg.CaPemPath | Should -Not -BeNullOrEmpty -Because 'a signed CA is trusted for the download'
            Remove-Item -LiteralPath $cfg.CaPemPath -Force -ErrorAction SilentlyContinue
        } finally { Remove-Item Env:PIN_SERVED -ErrorAction SilentlyContinue }
    }
    It '<Builder> stops with the source_integrity exit when it refuses the proxy CA' -ForEach @(
        @{ Builder = 'host/ubuntu.kvm/modules/New-UbuntuServerVM.ps1'; Result = 'ca' }
        @{ Builder = 'host/macos.utm/modules/New-UbuntuServerVM.ps1'; Result = 'ca' }
        @{ Builder = 'host/windows.hyper-v/modules/New-UbuntuServerVM.ps1'; Result = 'ca' }
        @{ Builder = 'host/ubuntu.kvm/guest.download-agent-service/New-VM.ps1'; Result = 'cacheCa' }
        @{ Builder = 'host/macos.utm/guest.download-agent-service/New-VM.ps1'; Result = 'cacheCa' }
        @{ Builder = 'host/windows.hyper-v/guest.download-agent-service/New-VM.ps1'; Result = 'cacheCa' }
    ) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $Builder)
        $text | Should -Match ('(?s)\$' + $Result + ' = Get-CachingProxyServiceCaCertBase64 .*?if \(\$' + $Result + '\.Refused\) \{.*?-ErrorAction Continue\s+exit \(Get-YurunaSourceIntegrityExitCode\)')
    }
    It 'publishes the statement a proxy builder signed, only beside the CA it names' {
        $seed = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/caching-proxy-service.base.user-data')
        $seed | Should -Match "path: /etc/yuruna/bump-ca/ca\.sig\.json[^\n]*\n(?:\s+\S[^\n]*\n){3}\s+content: 'YURUNA_PROXY_CA_STATEMENT_BASE64_PLACEHOLDER'"
        $seed | Should -Match ([regex]::Escape('cmp -s /etc/squid/ssl_cert/ca.pem /etc/yuruna/bump-ca/ca.pem; then install -m 0644 /etc/yuruna/bump-ca/ca.sig.json /var/www/html/yuruna-squid-ca.sig.json'))
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            $builder = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "host/$platform/guest.caching-proxy-service/New-VM.ps1")
            $builder | Should -Match 'ConvertTo-YurunaProxyCaStatement -SigningKeyBase64 \(\[string\]\$gitMirrorSeed\.SigningKeyBase64\) -CaPem \$bumpCa\.CertPem'
            $builder | Should -Match 'YURUNA_PROXY_CA_STATEMENT_BASE64_PLACEHOLDER = \$proxyCaStatementB64'
        }
    }
}

Describe 'legacy proxy CA retrieval keeps the VM key private and checks its pin' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.Ssh.psm1') -Global -DisableNameChecking
        $script:LegacyPair = Get-YurunaBumpCa -Create -HomePath (Join-Path $TestDrive 'legacy-ssh') -Confirm:$false
    }
    BeforeEach {
        $env:LEGACY_CA_OUTPUT = $script:LegacyPair.CertPem + $script:LegacyPair.KeyPem
        Mock -ModuleName Test.CachingProxyService Invoke-GuestSsh { @{success=$true;output=$env:LEGACY_CA_OUTPUT} }
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{} }
    }
    AfterEach { Remove-Item Env:LEGACY_CA_OUTPUT -ErrorAction SilentlyContinue }
    It 'retrieves the pair through a bounded explicit local-VM address without logging the key' {
        $pair = Get-CachingProxyServiceLegacyCa -VMName owned-proxy -Address '192.0.2.42' -InformationVariable info
        Get-YurunaCertificateSha256 $pair.CertPem | Should -BeExactly $script:LegacyPair.Sha256
        $pair.KeyPem | Should -BeExactly $script:LegacyPair.KeyPem
        ($info -join "`n") | Should -Not -Match 'PRIVATE KEY'
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-GuestSsh -Times 1 -ParameterFilter {
            $ResolvedAddress -eq '192.0.2.42' -and $VMName -eq 'owned-proxy' -and $TimeoutSeconds -eq 20 -and $AddressWaitSeconds -eq 0 -and
            $User -eq 'caching-proxy-service-admin' -and $Command -eq 'sudo -n cat /etc/squid/ssl_cert/ca.pem /etc/squid/ssl_cert/ca.key'
        }
    }
    It 'rejects a pair whose certificate differs from the recorded pin' {
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{caCertSourceHost='192.0.2.42';caCertSha256=('0'*64)} }
        { Get-CachingProxyServiceLegacyCa -VMName owned-proxy -Address '192.0.2.42' } | Should -Throw '*migration-pin-mismatch*'
    }
    It 'accepts the recorded certificate pin for this VM' {
        $sha = $script:LegacyPair.Sha256
        Mock -ModuleName Test.CachingProxyService Read-CachingProxyServiceState { @{caCertSourceHost='192.0.2.42';caCertSha256=$sha} }.GetNewClosure()
        (Get-CachingProxyServiceLegacyCa -VMName owned-proxy -Address '192.0.2.42').CertPem | Should -BeExactly $script:LegacyPair.CertPem
    }
    It 'does not expose SSH output when retrieval fails' {
        Mock -ModuleName Test.CachingProxyService Invoke-GuestSsh { @{success=$false;output='PRIVATE KEY sentinel'} }
        { Get-CachingProxyServiceLegacyCa -VMName owned-proxy -Address '192.0.2.42' } | Should -Throw '*migration-read-failed*'
    }
    It 'rejects incomplete SSH output: <Missing>' -ForEach @(@{Missing='certificate'},@{Missing='key'}) {
        $env:LEGACY_CA_OUTPUT = if ($Missing -eq 'certificate') { $script:LegacyPair.KeyPem } else { $script:LegacyPair.CertPem }
        { Get-CachingProxyServiceLegacyCa -VMName owned-proxy -Address '192.0.2.42' } | Should -Throw '*migration-pair-missing*'
    }
}

Describe 'rebuild recovery enrolls verified CA signing trust through host control' {
    BeforeAll {
        $script:RepairKeyPath = Join-Path $TestDrive 'public-key.json'
        @{keyId=$script:KeyId;publicKey=[Convert]::ToBase64String($script:Keys[$script:KeyId])} | ConvertTo-Json | Set-Content $script:RepairKeyPath
        $script:RepairHost = @{hostId=('a'*32);baseUrl='http://192.0.2.7:8080'}
    }
    BeforeEach {
        $env:CA_REPAIR_DOC = Join-Path $TestDrive 'remote-config.json'
        Mock -ModuleName Test.CachingProxyService Save-CachingProxyServiceState { throw 'pins must not be removed' }
        @{repositories=@{projectUrl='file:///operator/project.git';mirror=@{mode='off';url='http://other-mirror';verificationPublicKeys=@()}};vmStart=@{cachingProxyIp='192.0.2.42'};custom='keep'} | ConvertTo-Json -Depth 12 | Set-Content $env:CA_REPAIR_DOC
        $pem = $script:CaB; Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaPem { $pem }.GetNewClosure()
        $stmt = $script:StatementB; Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaStatement { $stmt }.GetNewClosure()
        Mock -ModuleName Test.CachingProxyService Invoke-RestMethod {
            if ($Method -eq 'POST') {
                Copy-Item $env:CA_REPAIR_DOC ($env:CA_REPAIR_DOC+'.backup')
                Set-Content $env:CA_REPAIR_DOC $Body
                return @{ok=$true}
            }
            return (Get-Content -Raw $env:CA_REPAIR_DOC | ConvertFrom-Json -AsHashtable)
        }
    }
    AfterEach { Remove-Item Env:CA_REPAIR_DOC -ErrorAction SilentlyContinue }
    It 'keeps operator settings and existing pins, reports the replacement before writing, and verifies enrollment' {
        $before = Get-Content -Raw $env:CA_REPAIR_DOC
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false -InformationVariable reports
        $result.Success | Should -BeTrue
        $disk = Get-Content -Raw $env:CA_REPAIR_DOC | ConvertFrom-Json -AsHashtable
        $disk.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        $disk.repositories.mirror.mode | Should -BeExactly 'off'
        $disk.repositories.mirror.url | Should -BeExactly 'http://other-mirror'
        $disk.custom | Should -BeExactly 'keep'
        @($disk.repositories.mirror.verificationPublicKeys).Count | Should -Be 1
        Get-Content -Raw ($env:CA_REPAIR_DOC+'.backup') | Should -BeExactly $before
        ($reports -join "`n") | Should -Match 'repositories.mirror.verificationPublicKeys:.*->'
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 1 -ParameterFilter {
            $Method -eq 'POST' -and $Headers['X-Yuruna'] -eq '1' -and $Headers['X-Yuruna-Control'] -match ('\.'+('a'*32)+'\.')
        }
        Should -Invoke -ModuleName Test.CachingProxyService Save-CachingProxyServiceState -Times 0
    }
    It 'is idempotent after successful recovery' {
        $null = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $before = Get-Content -Raw $env:CA_REPAIR_DOC
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeTrue
        Get-Content -Raw $env:CA_REPAIR_DOC | Should -BeExactly $before
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 1 -ParameterFilter { $Method -eq 'POST' }
    }
    It 'writes nothing for a statement naming another CA' {
        $stmt = $script:StatementA; Mock -ModuleName Test.CachingProxyService Get-CachingProxyServiceCaStatement { $stmt }.GetNewClosure()
        { Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 0
    }
    It 'writes nothing for an invalid public export' {
        $path = Join-Path $TestDrive 'wrong-key.json'
        @{keyId=('0'*64);publicKey=[Convert]::ToBase64String($script:Keys[$script:KeyId])} | ConvertTo-Json | Set-Content $path
        { Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $path -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 0
    }
    It 'reports an unreachable host and still repairs another host' {
        Mock -ModuleName Test.CachingProxyService Invoke-RestMethod { throw 'connection refused' } -ParameterFilter { $Uri -like '*192.0.2.8*' }
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @(@{hostId=('b'*32);baseUrl='http://192.0.2.8:8080'},$script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeFalse
        @($result.Hosts | Where-Object Success).Count | Should -Be 1
        @($result.Hosts | Where-Object { -not $_.Success }).Count | Should -Be 1
    }
    It 'reports safe control-refusal reasons without exposing response or request secrets: <Refusal>' -ForEach @(
        @{Refusal='proof-invalid';Expected='proof-invalid'}
        @{Refusal='fixture-secret-reason';Expected=''}
    ) {
        Mock -ModuleName Test.CachingProxyService Invoke-RestMethod {
            $failure = [Exception]::new('fixture-secret-request-header')
            $failure | Add-Member -NotePropertyName Response -NotePropertyValue @{StatusCode=403}
            $record = [Management.Automation.ErrorRecord]::new($failure, 'fixture-forbidden', [Management.Automation.ErrorCategory]::PermissionDenied, $null)
            $record.ErrorDetails = [Management.Automation.ErrorDetails]::new((@{reason=$Refusal;error='fixture-secret-response'} | ConvertTo-Json -Compress))
            throw $record
        } -ParameterFilter { $Method -eq 'POST' }
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false -WarningVariable warnings
        $result.Success | Should -BeFalse
        $result.Hosts[0].HttpStatus | Should -Be 403
        $result.Hosts[0].ControlReason | Should -BeExactly $Expected
        if ($Expected) { ($warnings -join ' ') | Should -Match $Expected }
        ($warnings -join ' ') | Should -Not -Match 'fixture-secret'
    }

    It 'does not enroll hosts configured to use another proxy' {
        $doc = Get-Content -Raw $env:CA_REPAIR_DOC | ConvertFrom-Json -AsHashtable
        $doc.vmStart.cachingProxyIp = '192.0.2.99'
        $doc | ConvertTo-Json -Depth 12 | Set-Content $env:CA_REPAIR_DOC
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Hosts[0].Reason | Should -BeExactly 'other-proxy'
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
    It 'previews enrollment without writing' {
        $null = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -WhatIf
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 0 -ParameterFilter { $Method -eq 'POST' }
    }
    It 'detects a host that acknowledged a write without persisting enrollment' {
        Mock -ModuleName Test.CachingProxyService Invoke-RestMethod { @{ok=$true} } -ParameterFilter { $Method -eq 'POST' }
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeFalse
        $result.Hosts[0].Reason | Should -BeExactly 'host-config-verification'
    }
    It 'detects a host that refused the configuration update' {
        Mock -ModuleName Test.CachingProxyService Invoke-RestMethod { @{ok=$false} } -ParameterFilter { $Method -eq 'POST' }
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeFalse
        $result.Hosts[0].Reason | Should -BeExactly 'host-config-write'
    }
    It 'does not claim recovery for an empty inventory' {
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @() -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeFalse
        Should -Invoke -ModuleName Test.CachingProxyService Invoke-RestMethod -Times 0
    }
    It 'preserves previously enrolled keys when adding the builder key' {
        $doc = Get-Content -Raw $env:CA_REPAIR_DOC | ConvertFrom-Json -AsHashtable
        $other = [Security.Cryptography.RSA]::Create(3072)
        try { $oldKey = [Convert]::ToBase64String($other.ExportSubjectPublicKeyInfo()) } finally { $other.Dispose() }
        $doc.repositories.mirror.verificationPublicKeys = @($oldKey)
        $doc | ConvertTo-Json -Depth 12 | Set-Content $env:CA_REPAIR_DOC
        $result = Repair-CachingProxyPoolCaTrust -CacheHost '192.0.2.42' -PublicKeyPath $script:RepairKeyPath -HostRecord @($script:RepairHost) -ControlToken fixture -Confirm:$false
        $result.Success | Should -BeTrue
        $disk = Get-Content -Raw $env:CA_REPAIR_DOC | ConvertFrom-Json -AsHashtable
        $disk.repositories.mirror.verificationPublicKeys | Should -Contain $oldKey
        @($disk.repositories.mirror.verificationPublicKeys).Count | Should -Be 2
    }
}

Describe 'the guest CA self-heal installs only the seeded CA' -Skip:($IsWindows -or -not (Get-Command bash -ErrorAction SilentlyContinue) -or -not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    BeforeEach {
        $script:Dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:BinDir = Join-Path $script:Dir 'bin'
        $null = New-Item -ItemType Directory -Path $script:BinDir -Force
        Set-Content -LiteralPath (Join-Path $script:Dir 'served.pem') -Value $script:CaA -NoNewline
        $script:Anchor = Join-Path $script:Dir 'anchors/yuruna-squid-ca.crt'
        # wget: --spider is the bump probe, trusted once the anchor holds CA A when
        # PROBE_AFTER_INSTALL=1; -O <file> <url> is the CA fetch.
        [IO.File]::WriteAllText((Join-Path $script:BinDir 'wget'), @"
#!/bin/sh
case " `$* " in
  *" --spider "*) [ "`${PROBE_AFTER_INSTALL:-0}" = 1 ] && cmp -s '$($script:Dir)/served.pem' '$($script:Anchor)' && exit 0; exit 4 ;;
esac
while [ `$# -gt 0 ]; do [ "`$1" = -qO ] && dest="`$2"; shift; done
cp '$($script:Dir)/served.pem' "`$dest"
"@)
        [IO.File]::WriteAllText((Join-Path $script:BinDir 'sudo'), "#!/bin/sh`nexec `"`$@`"`n")
        [IO.File]::WriteAllText((Join-Path $script:BinDir 'update-ca-certificates'), "#!/bin/sh`necho refreshed >> '$($script:Dir)/refresh.log'`n")
        foreach ($f in 'wget', 'sudo', 'update-ca-certificates') { & chmod +x (Join-Path $script:BinDir $f) }
        $script:Sha = Get-YurunaCertificateSha256 -Pem $script:CaA
    }
    BeforeAll {
        function Invoke-SelfHeal {
            param([string]$Pin, [string]$ProbeAfterInstall = '0')
            $hostEnv = Join-Path $script:Dir 'host.env'
            Set-Content -LiteralPath $hostEnv -Value "YURUNA_STATUS_SERVICE_IP=192.0.2.7`nYURUNA_STATUS_SERVICE_PORT=8080`nYURUNA_CA_SHA256=$Pin`n" -NoNewline
            $lib = Join-Path $script:RepoRoot 'automation/yuruna-retry.sh'
            $out = & env "PATH=$($script:BinDir):$($env:PATH)" "YURUNA_HOST_ENV_FILE=$hostEnv" "YURUNA_CA_ANCHOR_FILE=$($script:Anchor)" `
                "PROBE_AFTER_INSTALL=$ProbeAfterInstall" "https_proxy=http://192.0.2.42:3129" bash -c ". '$lib'; yuruna_ca_selfheal; echo rc=`$?" 2>&1
            return ($out -join "`n")
        }
    }
    It 'refuses to install anything without a seeded fingerprint' {
        $out = Invoke-SelfHeal -Pin ''
        $out | Should -Match 'rc=2'
        Test-Path -LiteralPath $script:Anchor | Should -BeFalse
    }
    It 'refuses a CA that is not the seeded one' {
        $out = Invoke-SelfHeal -Pin (Get-YurunaCertificateSha256 -Pem $script:CaB)
        $out | Should -Match 'rc=2'
        $out | Should -Match 'not the CA this guest was seeded to trust'
        Test-Path -LiteralPath $script:Anchor | Should -BeFalse
    }
    It 'installs the seeded CA when it makes the bump trusted' {
        $out = Invoke-SelfHeal -Pin $script:Sha -ProbeAfterInstall '1'
        $out | Should -Match 'rc=0'
        Get-Content -Raw -LiteralPath $script:Anchor | Should -Be $script:CaA
    }
    It 'takes the CA out again when it does not help' {
        $out = Invoke-SelfHeal -Pin $script:Sha -ProbeAfterInstall '0'
        $out | Should -Match 'rc=2'
        Test-Path -LiteralPath $script:Anchor | Should -BeFalse -Because 'a root that did not help is not left trusted'
    }
    It 'restores and checks the anchor <Family> guests install into' -TestCases @(
        @{ Family = 'Debian'; Refresh = 'update-ca-certificates'; Anchor = '/usr/local/share/ca-certificates/yuruna-squid-ca.crt' }
        @{ Family = 'RHEL'; Refresh = 'update-ca-trust'; Anchor = '/etc/pki/ca-trust/source/anchors/yuruna-squid-ca.crt' }
    ) {
        param($Refresh, $Anchor)
        # Only the refresh command of one family is on PATH, and sudo records
        # instead of running, so the real trust store is never touched.
        $only = Join-Path $script:Dir 'only'
        $null = New-Item -ItemType Directory -Path $only -Force
        [IO.File]::WriteAllText((Join-Path $only 'sudo'), "#!/bin/sh`necho `"`$*`" >> '$($script:Dir)/sudo.log'`n")
        [IO.File]::WriteAllText((Join-Path $only $Refresh), "#!/bin/sh`n")
        foreach ($f in 'sudo', $Refresh) { & chmod +x (Join-Path $only $f) }
        $lib = Join-Path $script:RepoRoot 'automation/yuruna-retry.sh'
        $bash = (Get-Command bash).Source
        $named = & env "PATH=$only" $bash -c ". '$lib' 2>/dev/null; _yuruna_ca_trust /fixture.pem; _yuruna_ca_anchor_path"
        $named | Select-Object -Last 1 | Should -Be $Anchor
        Get-Content -LiteralPath (Join-Path $script:Dir 'sudo.log') | Should -Contain "install -m 0644 /fixture.pem $Anchor"
    }
    It 'leaves an already trusted seeded CA in place when the bump fails for another reason' {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $script:Anchor) -Force
        Set-Content -LiteralPath $script:Anchor -Value $script:CaA -NoNewline
        $out = Invoke-SelfHeal -Pin $script:Sha -ProbeAfterInstall '0'
        $out | Should -Match 'already trusted'
        Get-Content -Raw -LiteralPath $script:Anchor | Should -Be $script:CaA
    }
}
