<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42064213-0b2d-4567-9d5d-580219d8c1fb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git mirror provisioning
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.CachingProxyService.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1') -Force
    Import-Module powershell-yaml -Force
    $script:repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    & (Get-Module Test.CachingProxyService) {
        function script:Get-EffectiveUser { param($LogicalUser) throw "unmocked $LogicalUser" }
        function script:Test-VaultEntry { param($VaultKey) throw "unmocked $VaultKey" }
        function script:Get-Password { param($Username) throw "unmocked $Username" }
        function script:Set-Password {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification='Test double for the vault API.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification='Test double for the vault API.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Test double never writes.')]
            [CmdletBinding()]param($Username, $NewPassword)
            throw "unmocked $Username $($NewPassword.Length)"
        }
        function script:Set-UserVaultKey {
            [CmdletBinding(SupportsShouldProcess)]param($LogicalUser, $VaultKey)
            if ($PSCmdlet.ShouldProcess($LogicalUser, 'test double')) { throw "unmocked $LogicalUser $VaultKey" }
        }
    }
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try {
        $script:storedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rsa.ExportPkcs8PrivateKeyPem()))
        $script:publicKey = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo())
    }
    finally { $rsa.Dispose() }

    # A checkout with one commit and the chosen origin, so the seed list does not
    # depend on which clone runs the suite.
    function New-SeedCheckout {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates a disposable repository under TestDrive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Remote)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = & git init --quiet $path 2>&1
        $null = & git -C $path -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --quiet --allow-empty -m seed 2>&1
        $null = & git -C $path remote add origin $Remote 2>&1
        if ($LASTEXITCODE -ne 0) { throw "could not create the seed checkout for $Remote" }
        return $path
    }
}

Describe 'Own proxy enrollment during setup' {
    BeforeEach {
        $script:configPath = Join-Path $TestDrive 'test.config.yml'
        Copy-Item (Join-Path $script:repo 'test/test.config.yml.template') ($script:configPath+'.template')
        $script:config = Get-Content ($script:configPath+'.template') -Raw | ConvertFrom-Yaml -Ordered
        $script:config.repositories.projectUrl = 'file:///operator/project.git'
        $script:config.repositories.mirror.mode = 'fallback'
        $script:config.vmStart.cachingProxyIp = '192.0.2.8'
        $script:config | ConvertTo-Yaml | Set-Content $script:configPath
        $script:statePath = Join-Path $TestDrive 'proxy.yml'
        Mock Get-CachingProxyServiceStatePath -ModuleName Test.CachingProxyService { $script:statePath }
        @{publicKey=$script:publicKey;keyId=(Get-ConfigMirrorKeyId -Value @($script:publicKey))} |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'git-mirror-public-key.json')
        $script:enrollmentReports = [Collections.Generic.List[object]]::new()
        Mock Write-Information -ModuleName Test.CachingProxyService {
            param($MessageData)
            $script:enrollmentReports.Add(@{text=[string]$MessageData;disk=[IO.File]::ReadAllText($script:configPath)})
        }
    }

    It 'enrolls an already bound proxy once without replacing operator configuration' {
        $before = [IO.File]::ReadAllText($script:configPath)
        Set-CachingProxyGitMirrorEnrollment -ConfigPath $script:configPath -ProxyIp '192.0.2.8' -Confirm:$false | Should -BeTrue
        [IO.File]::ReadAllText($script:configPath+'.backup') | Should -BeExactly $before
        $report = @($script:enrollmentReports | Where-Object text -Like 'repositories.mirror.verificationPublicKeys:*')
        $report.Count | Should -Be 1
        $report[0].text | Should -Match (' -> ' + (Get-ConfigMirrorKeyId -Value @($script:publicKey)))
        $report[0].disk | Should -BeExactly $before
        $disk = Get-Content $script:configPath -Raw | ConvertFrom-Yaml -Ordered
        @($disk.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:publicKey)
        $disk.repositories.mirror.mode | Should -BeExactly 'fallback'
        $disk.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        Set-CachingProxyGitMirrorEnrollment -ConfigPath $script:configPath -ProxyIp '192.0.2.8' -Confirm:$false | Should -BeFalse
    }

    It 'retains the previous key during an explicit own proxy key rotation' {
        $rsa = [Security.Cryptography.RSA]::Create(3072)
        try { $old = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) } finally { $rsa.Dispose() }
        $script:config.repositories.mirror.verificationPublicKeys = @($old)
        $script:config | ConvertTo-Yaml | Set-Content $script:configPath
        Set-CachingProxyGitMirrorEnrollment -ConfigPath $script:configPath -ProxyIp '192.0.2.8' -Confirm:$false | Should -BeTrue
        $disk = Get-Content $script:configPath -Raw | ConvertFrom-Yaml -Ordered
        @($disk.repositories.mirror.verificationPublicKeys).Count | Should -Be 2
        $disk.repositories.mirror.verificationPublicKeys | Should -Contain $old
        $disk.repositories.mirror.verificationPublicKeys | Should -Contain $script:publicKey
    }

    It 'does not enroll trust for a different operator selected mirror endpoint' {
        $script:config.repositories.mirror.url = 'http://192.0.2.9'
        $script:config | ConvertTo-Yaml | Set-Content $script:configPath
        $before = [IO.File]::ReadAllBytes($script:configPath)
        Set-CachingProxyGitMirrorEnrollment -ConfigPath $script:configPath -ProxyIp '192.0.2.8' -Confirm:$false | Should -BeFalse
        [IO.File]::ReadAllBytes($script:configPath) | Should -BeExactly $before
    }

    It 'refuses a public export whose key fingerprint does not match' {
        @{publicKey=$script:publicKey;keyId=('0'*64)} | ConvertTo-Json | Set-Content (Join-Path $TestDrive 'git-mirror-public-key.json')
        $before = [IO.File]::ReadAllBytes($script:configPath)
        { Set-CachingProxyGitMirrorEnrollment -ConfigPath $script:configPath -ProxyIp '192.0.2.8' -Confirm:$false } | Should -Throw '*mirror-public-key-export-invalid*'
        [IO.File]::ReadAllBytes($script:configPath) | Should -BeExactly $before
    }
}

Describe 'Read-only persisted mirror endpoint discovery' {
    BeforeEach {
        $script:savedDiscoveryRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'endpoint-runtime'
        Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { throw 'mutating state reader must not run before the first pull' }
    }
    AfterEach { $env:YURUNA_RUNTIME_DIR = $script:savedDiscoveryRuntime }

    It 'does not create a runtime directory when state is absent' {
        Get-CachingProxyServiceStateIp -ReadOnly | Should -BeExactly ''
        Test-Path $env:YURUNA_RUNTIME_DIR | Should -BeFalse
        Should -Invoke Read-CachingProxyServiceState -ModuleName Test.CachingProxyService -Times 0
    }

    It 'does not rotate or rewrite corrupt state while resolving the endpoint' {
        $null = [IO.Directory]::CreateDirectory($env:YURUNA_RUNTIME_DIR)
        $path = Join-Path $env:YURUNA_RUNTIME_DIR 'yuruna-caching-proxy-service.yml'
        [IO.File]::WriteAllText($path, 'ipAddress: [invalid')
        $before = [IO.File]::ReadAllBytes($path)
        Get-CachingProxyServiceStateIp -ReadOnly | Should -BeExactly ''
        [IO.File]::ReadAllBytes($path) | Should -BeExactly $before
        @(Get-ChildItem $env:YURUNA_RUNTIME_DIR -Force).Count | Should -Be 1
        Should -Invoke Read-CachingProxyServiceState -ModuleName Test.CachingProxyService -Times 0
    }
}

Describe 'Mirror key and credential seed lifecycle' {
    It 'creates decoded signing and token files privately before ownership changes' -Skip:$IsWindows {
        $seed = Get-Content (Join-Path $script:repo 'host/vmconfig/caching-proxy-service.base.user-data') -Raw | ConvertFrom-Yaml
        $command = @($seed.runcmd | Where-Object { $_ -is [string] -and $_ -match 'base64 -d /etc/yuruna/git-mirror/signing-key' })[0]
        $start = $command.IndexOf('chmod 0751 /etc/yuruna/git-mirror', [StringComparison]::Ordinal)
        $end = $command.IndexOf('cat > /etc/yuruna/git-mirror/worker.env', $start, [StringComparison]::Ordinal)
        $fragment = $command.Substring($start, $end-$start)
        # A subshell can narrow the mask without changing permissions for the
        # unrelated service artifacts installed later in the same seed command.
        $prefix = $command.Substring([Math]::Max(0,$start-200), [Math]::Min(200,$start))
        if ($prefix -match '(?s)(\(\s*umask 077\s*)$') { $fragment = $Matches[1] + $fragment }
        $private = Join-Path $TestDrive 'mirror-private'
        $null = [IO.Directory]::CreateDirectory($private)
        foreach ($name in 'repositories','signing-key','token') {
            [IO.File]::WriteAllText((Join-Path $private "$name.b64"), [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('fixture')))
        }
        $fragment = $fragment.Replace('/etc/yuruna/git-mirror', $private)
        $observer = Join-Path $TestDrive 'observe.py'
        @'
import os, stat, sys
path = sys.argv[-1]
if path.endswith(('signing-key.pem', '/credentials')):
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode != 0o600:
        raise SystemExit('secret exposed before chown: %o' % mode)
'@ | Set-Content $observer
        $entry = Join-Path $TestDrive 'decode.sh'
        $python = (Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $singleQuoteEscape = "'" + [char]34 + "'" + [char]34 + "'"
        $escapedPython = $python.Replace("'", $singleQuoteEscape)
        $escapedObserver = $observer.Replace("'", $singleQuoteEscape)
        $harness = "set -e`numask 022`nchown() { '$escapedPython' '$escapedObserver' `"`$@`"; }`n" + $fragment
        [IO.File]::WriteAllText($entry, $harness)
        $output = & bash $entry 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        [IO.File]::ReadAllText((Join-Path $private 'signing-key.pem')) | Should -BeExactly 'fixture'
        [IO.File]::ReadAllText((Join-Path $private 'credentials')) | Should -BeExactly 'fixture'
    }

    BeforeEach {
        $script:oldRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Get-EffectiveUser -ModuleName Test.CachingProxyService { @{vaultKey=''} }
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService { $false }
        Mock Get-Password -ModuleName Test.CachingProxyService { throw 'must not auto-generate' }
        Mock Set-Password -ModuleName Test.CachingProxyService { }
        Mock Set-UserVaultKey -ModuleName Test.CachingProxyService { $true }
    }
    AfterEach { $env:YURUNA_RUNTIME_DIR = $script:oldRuntime }

    It 'mints a signing key once but never generates an optional GitHub token' {
        $result = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{}
        $result.KeyId | Should -Match '^[0-9a-f]{64}$'
        $result.TokenBase64 | Should -Be ''
        Should -Invoke Get-Password -ModuleName Test.CachingProxyService -Times 0
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 1 -ParameterFilter { $Username -eq 'github-mirror-signing-key' }
        $export = Get-Content (Join-Path $env:YURUNA_RUNTIME_DIR 'git-mirror-public-key.json') -Raw | ConvertFrom-Json
        $export.publicKey | Should -BeExactly $result.PublicKey
        $export.keyId | Should -BeExactly $result.KeyId
    }

    It 'reuses the stored key across proxy rebuilds' {
        Mock Get-EffectiveUser -ModuleName Test.CachingProxyService { param($LogicalUser) @{vaultKey=$LogicalUser} }
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService { param($VaultKey) $VaultKey -eq 'github-mirror-signing-key' }
        Mock Get-Password -ModuleName Test.CachingProxyService { $script:storedKey }
        $first = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{}
        $second = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{}
        $first.SigningKeyBase64 | Should -BeExactly $script:storedKey
        $second.KeyId | Should -BeExactly $first.KeyId
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 0
    }

    It 'never mints when the signing vault read throws' {
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService { throw 'vault locked' }
        $result = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{} -WarningAction SilentlyContinue
        $result.SigningKeyBase64 | Should -Be ''
        $result.PublicKey | Should -Be ''
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 0
    }

    It 'does not replace a corrupt stored signing key' {
        Mock Get-EffectiveUser -ModuleName Test.CachingProxyService { param($LogicalUser) @{vaultKey=$LogicalUser} }
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService { param($VaultKey) $VaultKey -eq 'github-mirror-signing-key' }
        Mock Get-Password -ModuleName Test.CachingProxyService { 'corrupt-key' }
        $result = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{} -WarningAction SilentlyContinue
        $result.SigningKeyBase64 | Should -Be ''
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 0
    }

    It 'provisions anonymously for a rejected optional token' {
        Mock Get-EffectiveUser -ModuleName Test.CachingProxyService { param($LogicalUser) @{vaultKey=$LogicalUser} }
        Mock Test-VaultEntry -ModuleName Test.CachingProxyService { $true }
        Mock Get-Password -ModuleName Test.CachingProxyService { param($Username) if ($Username -eq 'github-mirror-token') { return "bad`ntoken" }; $script:storedKey }
        $result = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{} -WarningAction SilentlyContinue
        $result.TokenBase64 | Should -Be ''
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 0
    }

    It 'seeds the public repositories, the checkout remote and configured GitHub sources' {
        $checkout = New-SeedCheckout -Remote 'https://github.com/example/framework.git'
        $result = Get-CachingProxyGitMirrorSeedSetting -RepoRoot $checkout -Config @{repositories=@{projectUrl='https://github.com/example/custom.git';frameworkUrl='file:///operator.git'}}
        $list = @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($result.RepositoriesBase64)) | ConvertFrom-Json).repositories)
        $list | Should -Be @('alissonsol/yuruna', 'alissonsol/yuruna-project', 'example/custom', 'example/framework')
        $result.BuildRepository | Should -BeExactly 'example/framework'
        $result.BuildCommit | Should -Match '^[0-9a-f]{40}$'
    }

    It 'names a development repository only when the checkout or its configuration does' {
        # The module ships publicly, so the private names reach a proxy only
        # from the development checkout that provisions it.
        $public = New-SeedCheckout -Remote 'https://github.com/alissonsol/yuruna.git'
        $list = @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-CachingProxyGitMirrorSeedSetting -RepoRoot $public -Config @{}).RepositoriesBase64)) | ConvertFrom-Json).repositories)
        $list | Should -Be @('alissonsol/yuruna', 'alissonsol/yuruna-project')
        $development = New-SeedCheckout -Remote 'https://github.com/alissonsol/yurunadev.git'
        $config = @{repositories=@{frameworkUrl='https://github.com/alissonsol/yurunadev.git';projectUrl='https://github.com/alissonsol/yurunadev-project.git'}}
        $list = @(([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((Get-CachingProxyGitMirrorSeedSetting -RepoRoot $development -Config $config).RepositoriesBase64)) | ConvertFrom-Json).repositories)
        $list | Should -Be @('alissonsol/yuruna', 'alissonsol/yuruna-project', 'alissonsol/yurunadev', 'alissonsol/yurunadev-project')
    }

    It 'rejects a refresh interval outside the documented seed bounds' {
        { Get-CachingProxyGitMirrorSeedSetting -RepoRoot $script:repo -Config @{vmStart=@{cachingProxyGitMirrorRefreshSeconds=1}} } | Should -Throw '*mirror-refresh-interval-invalid*'
        Should -Invoke Set-Password -ModuleName Test.CachingProxyService -Times 0
    }
}
