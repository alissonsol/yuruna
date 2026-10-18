<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42332a75-ac63-4075-9383-e02c25254b0b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cache registry zot release pester
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
    What the host does with the cache's verdict on its own zot release: the
    build reports it, the cycle stops waiting on it, and an operator can swap
    the release without changing code.
.DESCRIPTION
    The caching-proxy-service VM syncs a probe image per upstream through its
    zot release and publishes the verdict in /zot-meta. An incompatible release
    refuses images its upstream serves; no wait changes that, so the
    cycle-start registry wait ends at once and says why, instead of spending
    its budget and blaming a cold cache. The build command waits for the same
    verdict and prints the cache's own fix instructions.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $repoRoot 'test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global

    $script:WarmSetsHeld = @'
yuruna_prewarm_state_available 1
yuruna_prewarm_images_total{set="k8s"} 7
yuruna_prewarm_images_resident{set="k8s"} 7
yuruna_prewarm_images_total{set="cni"} 2
yuruna_prewarm_images_resident{set="cni"} 2
yuruna_prewarm_manifest_seconds{set="k8s",image="registry.k8s.io/kube-apiserver:v1.37.1",state="resident"} 0.032
'@
    $script:Incompatible = @'
yuruna_zot_selftest_available 1
yuruna_zot_selftest_ok 0
yuruna_zot_selftest_verdict{verdict="incompatible"} 1
yuruna_zot_selftest_release_info{version="v2.1.23",pinned="v2.1.23",override="0"} 1
yuruna_zot_selftest_probe_failed{image="registry.k8s.io/pause:3.10.2",stage="tag",status="503",outcome="rejected",compat="docker2s2"} 1
yuruna_zot_selftest_probe_failed{image="mcr.microsoft.com/dotnet/runtime-deps:10.0",stage="tag",status="503",outcome="rejected",compat="docker2s2"} 1
'@
    $script:Repaired = @'
yuruna_zot_selftest_available 1
yuruna_zot_selftest_ok 1
yuruna_zot_selftest_verdict{verdict="healed"} 1
yuruna_zot_selftest_release_info{version="v2.1.23",pinned="v2.1.23",override="0"} 1
yuruna_zot_selftest_compat_added{mode="docker2s2"} 1
'@
    $script:HealthPage = @'
yuruna caching-proxy health -- 2026-10-12T13:30:10Z

zot /v2/ liveness            : up
zot sync self-test           : INCOMPATIBLE -- zot v2.1.23 refused 2 of 4 probe images (2026-10-12T13:30:00Z)
  registry.k8s.io/pause:3.10.2: HTTP 503 for the tag; zot's log: docker media type requires http.compat docker2s2
    1. Let the self-test add what zot asks for, restart zot, and test again:
         sudo /usr/local/bin/zot-sync-selftest.py --heal
zot manifest dotnet/sdk:10.0 : HTTP 200 in 0.275s (cap 120s)
'@
}

Describe 'A host can install another zot release without changing code' {
    It 'keeps the pin when neither key is set' {
        $r = Resolve-CachingProxyZotOverride -Config @{ vmStart = @{ cachingProxyIp = '' } }
        $r.Version | Should -BeExactly ''
        $r.Sha256 | Should -BeExactly ''
        (Resolve-CachingProxyZotOverride -Config $null).Version | Should -BeExactly ''
    }
    It 'passes a release tag and its checksum through, from a hashtable or a parsed object' {
        $sha = 'AB' * 32
        $r = Resolve-CachingProxyZotOverride -Config @{ vmStart = @{ cachingProxyZotVersion = ' v2.1.21 '; cachingProxyZotSha256 = $sha } }
        $r.Version | Should -BeExactly 'v2.1.21'
        $r.Sha256 | Should -BeExactly $sha.ToLowerInvariant()
        $o = [pscustomobject]@{ vmStart = [pscustomobject]@{ cachingProxyZotVersion = 'v2.2.0-rc1'; cachingProxyZotSha256 = 'c' * 64 } }
        (Resolve-CachingProxyZotOverride -Config $o).Version | Should -BeExactly 'v2.2.0-rc1'
    }
    It 'refuses a value that is not a release tag, since it is baked into a shell assignment' {
        { Resolve-CachingProxyZotOverride -Config @{ vmStart = @{ cachingProxyZotVersion = "v2.1.21'; reboot; '"; cachingProxyZotSha256 = 'c' * 64 } } } |
            Should -Throw '*not a zot release tag*'
    }
    It 'refuses a release without the checksum the VM verifies it against, and says where to find it' {
        { Resolve-CachingProxyZotOverride -Config @{ vmStart = @{ cachingProxyZotVersion = 'v2.1.21' } } } |
            Should -Throw '*releases/download/v2.1.21/checksums.sha256.txt*'
    }
}

Describe 'The cycle-start registry wait stops on an incompatible zot release' {
    It 'names the release, the refused image and the mode zot asks for, without probing a manifest' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') { [pscustomobject]@{ StatusCode = 200; Content = $script:WarmSetsHeld + "`n" + $script:Incompatible } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        }
        $r = Test-CachingProxyRegistryReady -CacheIp '192.0.2.7' -Port 5000
        $r.Ready | Should -BeFalse
        $r.Terminal | Should -BeTrue
        $r.Reason | Should -Match "the cache's zot v2\.1\.23 is incompatible"
        $r.Reason | Should -Match 'registry\.k8s\.io/pause:3\.10\.2: HTTP 503 at the tag'
        $r.Reason | Should -Match 'http\.compat docker2s2'
        $r.Reason | Should -Match 'not a cold cache'
        $r.Reason | Should -Match 'http://192\.0\.2\.7/cache-health'
        Should -Invoke Invoke-WebRequest -ModuleName Test.CachingProxyService -ParameterFilter { $Uri -like '*/manifests/*' } -Times 0 -Exactly
    }
    It 'lets a cache whose self-test repaired its configuration serve guests' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') { [pscustomobject]@{ StatusCode = 200; Content = $script:WarmSetsHeld + "`n" + $script:Repaired } }
            else { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        }
        (Test-CachingProxyRegistryReady -CacheIp '127.0.0.1' -Port 5000).Ready | Should -BeTrue
    }
    It 'ends the wait after one probe and says waiting does not help' {
        Mock Test-CachingProxyRegistryReady -ModuleName Test.CachingProxyService {
            @{ Ready = $false; Terminal = $true; Reason = "the cache's zot v2.1.23 is incompatible"; StatusCode = 200; Uri = 'u' }
        }
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $listener.LocalEndpoint.Port `
                -RegistryPort 5000 -RegistryTimeoutSeconds 600 -RequireRegistry -RequiredConsecutive 2 -IntervalSeconds 0 -TimeoutSeconds 20
            $r.Ready | Should -BeFalse
            Should -Invoke Test-CachingProxyRegistryReady -ModuleName Test.CachingProxyService -Times 1 -Exactly
            $text = $r.Lines -join "`n"
            $text | Should -Match 'waiting does not change that: the cache.s zot v2\.1\.23 is incompatible\. Kubernetes guest work was not started\.'
            $text | Should -Not -Match 'waiting up to 600s'
        } finally { $listener.Stop() }
    }
}

Describe 'The build reports the cache''s verdict on its zot release' {
    It 'fails on an incompatible release and prints the cache''s own fix instructions' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') { [pscustomobject]@{ StatusCode = 200; Content = $script:Incompatible } }
            else { [pscustomobject]@{ StatusCode = 200; Content = $script:HealthPage } }
        }
        $r = Get-CachingProxyZotSelfTestReport -CacheIp '192.0.2.7'
        $r.Level | Should -Be 'FAIL'
        $text = $r.Lines -join "`n"
        $text | Should -Match '\[FAIL\] zot sync self-test \(http://192\.0\.2\.7/cache-health\)'
        $text | Should -Match 'INCOMPATIBLE -- zot v2\.1\.23'
        $text | Should -Match 'zot-sync-selftest\.py --heal'
        $text | Should -Not -Match 'zot /v2/ liveness|zot manifest dotnet'
        $text | Should -Match 'Kubernetes guests stop at their control-plane warm pass'
    }
    It 'warns about a repaired configuration and passes a release that syncs' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') { [pscustomobject]@{ StatusCode = 200; Content = $script:Repaired } }
            else { [pscustomobject]@{ StatusCode = 404; Content = '' } }
        }
        $r = Get-CachingProxyZotSelfTestReport -CacheIp '192.0.2.7'
        $r.Level | Should -Be 'WARN'
        ($r.Lines -join "`n") | Should -Match 'verdict: healed'
    }
    It 'waits for the verdict, then sets the exit code from it' {
        $script:polls = 0
        Mock Start-Sleep -ModuleName Test.CachingProxyService { }
        Mock Get-CachingProxyZotSelfTestReport -ModuleName Test.CachingProxyService {
            $script:polls++
            if ($script:polls -lt 3) { @{ Level = 'PENDING'; Lines = @('  [WAIT]') } }
            else { @{ Level = 'FAIL'; Lines = @('  [FAIL] zot sync self-test') } }
        }
        $r = Wait-CachingProxyZotSelfTest -CacheIp '192.0.2.7' -TimeoutSeconds 600 -IntervalSeconds 1 -InformationAction SilentlyContinue
        $r.ExitCode | Should -Be 1
        $r.Level | Should -Be 'FAIL'
        $script:polls | Should -Be 3
    }
    It 'leaves a build without a verdict in time to finish, and says where to look' {
        Mock Start-Sleep -ModuleName Test.CachingProxyService { }
        Mock Get-CachingProxyZotSelfTestReport -ModuleName Test.CachingProxyService { @{ Level = 'PENDING'; Lines = @() } }
        $r = Wait-CachingProxyZotSelfTest -CacheIp '192.0.2.7' -TimeoutSeconds 0 -InformationAction SilentlyContinue
        $r.ExitCode | Should -Be 0
        ($r.Lines -join "`n") | Should -Match 'http://192\.0\.2\.7/cache-health shows the verdict'
    }
}
