<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42756b16-4f56-4574-9bb7-56d74bcfe44f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runtime safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    foreach ($name in @('Test.PoolNotifier', 'Test.PoolStorage', 'Test.PoolSync', 'Test.CachingProxyServiceLock', 'Test.ConfigServiceCA', 'Test.LocalizationExchange')) {
        Import-Module (Join-Path $PSScriptRoot ($name + '.psm1')) -Force -Global -DisableNameChecking
    }
}

Describe 'pool runtime safety' {
    It 'does not activate a quoted false pool setting' {
        foreach ($value in @($false, 'false', 'no', 'off', '0', '')) {
            $config = @{ pool = @{ enabled = $value; intentGitUrl = 'https://example.invalid/pool.git'; localClonePath = "$TestDrive/pool" } }
            Get-YurunaPoolConfig -Config $config | Should -BeNullOrEmpty
            (Get-YurunaPoolConfig -Config $config -IgnoreEnabled).Enabled | Should -BeFalse
        }
        foreach ($value in @($true, 'true', 'yes', 'on', '1')) {
            (Get-YurunaPoolConfig -Config @{ pool = @{ enabled = $value; intentGitUrl = 'https://example.invalid/pool.git'; localClonePath = "$TestDrive/pool" } }).Enabled | Should -BeTrue
        }
    }

    It 'retries a rising alert edge after the spool write fails' {
        $script:Writes = 0
        Mock Write-PoolSpoolMessage -ModuleName Test.PoolNotifier { $script:Writes++; return $script:Writes -gt 1 }
        $state = @{}
        $gauge = @{ lab = @{ alertActive = $true; healthyFraction = 0.25; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 4 } }
        Add-PoolAlertSpoolEntry -GaugeState $gauge -State $state -SpoolRoot $TestDrive | Should -Be 0
        $state.pools.lab.lastActive | Should -BeFalse
        Add-PoolAlertSpoolEntry -GaugeState $gauge -State $state -SpoolRoot $TestDrive | Should -Be 1
        $state.pools.lab.lastActive | Should -BeTrue
        Add-PoolAlertSpoolEntry -GaugeState $gauge -State $state -SpoolRoot $TestDrive | Should -Be 0
        Should -Invoke Write-PoolSpoolMessage -ModuleName Test.PoolNotifier -Times 2 -Exactly
    }

    It 'returns its timeout without waiting for a blocked thread to stop' {
        $before = @(Get-Job).Id
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $result = & (Get-Module Test.PoolStorage) { Invoke-PoolStorageBoundedScript -ScriptBlock { [Threading.Thread]::Sleep(5000) } -TimeoutSeconds 1 -WarningAction SilentlyContinue }
            $clock.Stop()
            $result.TimedOut | Should -BeTrue
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
        } finally {
            $jobs = @(Get-Job | Where-Object { $_.Name -eq 'YurunaPoolStorageBounded' -and $_.Id -notin $before })
            foreach ($job in $jobs) { $null = Wait-Job $job -Timeout 7; Remove-Job $job -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'refuses an impossible lock directory without spinning' {
        $file = Join-Path $TestDrive 'ordinary-file'
        Set-Content -LiteralPath $file -Value 'fixture'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        { Enter-CachingProxyServiceLock -RuntimeDir "$file/child" -TimeoutSeconds 1 } | Should -Throw
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
    }
}

Describe 'private configuration and confined localization paths' {
    It 'renews an expiring server leaf while preserving the trusted CA' {
        $prior = $env:YURUNA_RUNTIME_DIR
        $existing = $null; $renewed = $null; $ca = $null; $key = $null
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'certificate-runtime'
            $ca = Initialize-YurunaConfigCA -Confirm:$false
            $caThumb = $ca.Thumbprint
            $key = [Security.Cryptography.ECDsa]::Create([Security.Cryptography.ECCurve+NamedCurves]::nistP256)
            $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=fixture', $key, [Security.Cryptography.HashAlgorithmName]::SHA256)
            $existing = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-2), [DateTimeOffset]::UtcNow.AddDays(1))
            $path = Join-Path $env:YURUNA_RUNTIME_DIR 'host-config-ca/server.pfx'
            [IO.File]::WriteAllBytes($path, $existing.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12))
            $renewed = New-YurunaConfigServerCertificate -Confirm:$false
            $renewed.Thumbprint | Should -Not -Be $existing.Thumbprint
            $renewed.NotAfter.ToUniversalTime() | Should -BeGreaterThan ([DateTime]::UtcNow.AddDays(30))
            (Initialize-YurunaConfigCA -Confirm:$false).Thumbprint | Should -Be $caThumb
        } finally {
            $env:YURUNA_RUNTIME_DIR = $prior
            foreach ($item in @($existing, $renewed, $ca, $key)) { if ($item) { $item.Dispose() } }
        }
    }

    It 'permits symlinked ancestors but refuses links within the confined root' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'creating symbolic links requires a Windows privilege'; return }
        $real = Join-Path $TestDrive 'real'
        $link = Join-Path $TestDrive 'linked'
        $null = New-Item -ItemType Directory -Path "$real/root" -Force
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $real
        try {
            $root = "$link/root"
            & (Get-Module Test.LocalizationExchange) { param($base) Resolve-LocalizationPath -Root $base -Relative 'translation.json' } $root | Should -Be "$root/translation.json"
            $null = New-Item -ItemType SymbolicLink -Path "$root/escape" -Target $TestDrive
            { & (Get-Module Test.LocalizationExchange) { param($base) Resolve-LocalizationPath -Root $base -Relative 'escape/translation.json' } $root } | Should -Throw '*Linked localization path*'
        } finally {
            Remove-Item -LiteralPath "$link/root/escape" -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
        }
    }
}
