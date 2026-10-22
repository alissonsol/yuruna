<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42b9a171-fd96-4867-9e82-432cf026c341
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git mirror configuration
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force
    Import-Module powershell-yaml -Force
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try { $script:key = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) }
    finally { $rsa.Dispose() }
    $script:template = Join-Path $script:root 'test/test.config.yml.template'
}

Describe 'Operator-named reference host enrollment' {
    BeforeEach {
        $script:syncRoot = Join-Path $TestDrive 'host'
        $null = [IO.Directory]::CreateDirectory((Join-Path $script:syncRoot 'test'))
        $script:syncPath = Join-Path $script:syncRoot 'test/test.config.yml'
        Copy-Item $script:template (Join-Path $script:syncRoot 'test/test.config.yml.template')
        $script:local = @{repositories=@{projectUrl='file:///operator/project.git';mirror=@{mode='prefer';verificationPublicKeys=@()}}}
        $script:local | ConvertTo-Yaml | Set-Content $script:syncPath
        $script:reference = @{repositories=@{projectUrl='file:///reference/project.git';mirror=@{mode='prefer';verificationPublicKeys=@($script:key)}}}
        $script:syncReports = [Collections.Generic.List[object]]::new()
        Mock Get-HostType -ModuleName Test.ConfigServiceSync { 'host.ubuntu.kvm' }
        Mock Get-ConfigSyncReferenceConfig -ModuleName Test.ConfigServiceSync { $script:reference }
        Mock Test-ConfigSyncReferenceFreshness -ModuleName Test.ConfigServiceSync { @{Checked=$false;Behind=$false} }
        Mock Write-Information -ModuleName Test.ConfigServiceSync {
            param($MessageData)
            $script:syncReports.Add(@{text=[string]$MessageData;disk=[IO.File]::ReadAllText($script:syncPath)})
        }
    }

    It 'requires explicit key acceptance without changing the file in unattended mode' {
        $before = [IO.File]::ReadAllBytes($script:syncPath)
        { Sync-HostConfiguration -ReferenceHost 'reference.invalid' -RepoRoot $script:syncRoot -NonInteractive -SkipValidation -NoPool -Confirm:$false } |
            Should -Throw '*mirror-key-confirmation-required*-AcceptMirrorKey*'
        [IO.File]::ReadAllBytes($script:syncPath) | Should -BeExactly $before
        Test-Path ($script:syncPath+'.backup') | Should -BeFalse
    }

    It 'backs up and reports key fingerprints before writing explicitly accepted trust' {
        $before = [IO.File]::ReadAllText($script:syncPath)
        $result = Sync-HostConfiguration -ReferenceHost 'reference.invalid' -RepoRoot $script:syncRoot -NonInteractive -AcceptMirrorKey -SkipValidation -NoPool -Confirm:$false
        $result.Wrote | Should -BeTrue
        [IO.File]::ReadAllText($result.BackupPath) | Should -BeExactly $before
        $report = @($script:syncReports | Where-Object text -Like 'repositories.mirror.verificationPublicKeys:*')
        $report.Count | Should -Be 1
        $report[0].text | Should -Match (' -> ' + (Get-ConfigMirrorKeyId -Value @($script:key)))
        $report[0].text | Should -Not -Match ([regex]::Escape($script:key))
        $report[0].disk | Should -BeExactly $before
        $disk = Get-Content $script:syncPath -Raw | ConvertFrom-Yaml -Ordered
        @($disk.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:key)
        $disk.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
    }

    It 'preserves enrolled trust when an older reference omits the mirror block' {
        $script:local.repositories.mirror.verificationPublicKeys = @($script:key)
        $script:local | ConvertTo-Yaml | Set-Content $script:syncPath
        $script:reference.repositories.Remove('mirror')
        $null = Sync-HostConfiguration -ReferenceHost 'reference.invalid' -RepoRoot $script:syncRoot -NonInteractive -SkipValidation -NoPool -Confirm:$false
        $disk = Get-Content $script:syncPath -Raw | ConvertFrom-Yaml -Ordered
        @($disk.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:key)
    }

    It 'refuses malformed reference trust even when acceptance is supplied' {
        $script:reference.repositories.mirror.verificationPublicKeys = @('invalid')
        $before = [IO.File]::ReadAllBytes($script:syncPath)
        { Sync-HostConfiguration -ReferenceHost 'reference.invalid' -RepoRoot $script:syncRoot -NonInteractive -AcceptMirrorKey -SkipValidation -NoPool -Confirm:$false } |
            Should -Throw '*mirror-key-invalid*'
        [IO.File]::ReadAllBytes($script:syncPath) | Should -BeExactly $before
    }
}

Describe 'Mirror configuration trust and preservation' {
    It 'seeds prefer with no trust while retaining custom file repositories on disk' {
        $configPath = Join-Path $TestDrive 'test.config.yml'
        'repositories: {frameworkUrl: "file:///framework.git", projectUrl: "file:///project.git"}' | Set-Content $configPath
        $null = Update-TestConfigFromTemplate -ConfigPath $configPath -TemplatePath $script:template -Confirm:$false
        $disk = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
        $disk.repositories.frameworkUrl | Should -BeExactly 'file:///framework.git'
        $disk.repositories.projectUrl | Should -BeExactly 'file:///project.git'
        $disk.repositories.mirror.mode | Should -BeExactly 'prefer'
        @($disk.repositories.mirror.verificationPublicKeys).Count | Should -Be 0
    }

    It 'round trips an enrolled list through both documented configuration writers' {
        $configPath = Join-Path $TestDrive 'enrolled.yml'
        $config = Get-Content $script:template -Raw | ConvertFrom-Yaml -Ordered
        $config.repositories.mirror.verificationPublicKeys = @($script:key)
        $config.repositories.mirror.url = 'http://192.168.50.9:8000'
        $config.repositories.mirror.mode = 'fallback'
        $config.repositories.mirror.mirrorOnlyMaxAgeSeconds = 350
        $config.repositories.projectUrl = 'file:///operator/project.git'
        $config.vmStart.cachingProxyGitMirrorRefreshSeconds = 120
        $config | ConvertTo-Yaml | Set-Content $configPath
        $null = Update-TestConfigFromTemplate -ConfigPath $configPath -TemplatePath $script:template -Confirm:$false
        $template = Get-Content $script:template -Raw | ConvertFrom-Yaml -Ordered
        $current = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
        $null = Sync-TestConfigToTemplate -ConfigPath $configPath -TemplatePath $script:template -Template $template -Current $current -Confirm:$false
        $disk = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
        @($disk.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:key)
        $disk.repositories.mirror.mode | Should -BeExactly 'fallback'
        $disk.repositories.mirror.url | Should -BeExactly 'http://192.168.50.9:8000'
        $disk.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        $disk.vmStart.cachingProxyGitMirrorRefreshSeconds | Should -Be 120
    }

    It 'uses a SHA256 fingerprint over the enrolled DER bytes' {
        $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromBase64String($script:key))).ToLowerInvariant()
        @(Get-ConfigMirrorKeyId -Value @($script:key)) | Should -BeExactly @($expected)
    }

    It 'keeps a parked public key list recoverable as a YAML list across repeated writes' {
        $configPath = Join-Path $TestDrive 'parked.yml'
        $templatePath = Join-Path $TestDrive 'older-template.yml'
        "repositories:`n  projectUrl: `"`"" | Set-Content $templatePath
        $template = Get-Content $templatePath -Raw | ConvertFrom-Yaml -Ordered
        @{ repositories=@{projectUrl='file:///operator/project.git';mirror=@{verificationPublicKeys=@($script:key)}} } |
            ConvertTo-Yaml | Set-Content $configPath
        foreach ($iteration in 1..2) {
            $current = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
            $null = Sync-TestConfigToTemplate -ConfigPath $configPath -TemplatePath $templatePath -Template $template -Current $current -Confirm:$false
            $parked = Get-ObsoleteConfigEntry -Text (Get-Content $configPath -Raw)
            $recovered = ConvertFrom-Yaml -Yaml ("keys: " + $parked['repositories.mirror.verificationPublicKeys']) -Ordered
            ($recovered.keys -is [string]) | Should -BeFalse
            @($recovered.keys) | Should -BeExactly @($script:key)
            (Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered).repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        }
    }

    It 'rejects invalid trust before <Writer> rewrites the operator file (<KeyKind>)' -ForEach @(
        @{Writer='Update';KeyKind='multiline'}, @{Writer='Sync';KeyKind='multiline'}, @{Writer='Documented';KeyKind='multiline'},
        @{Writer='Update';KeyKind='PEM'}, @{Writer='Sync';KeyKind='PEM'}, @{Writer='Documented';KeyKind='PEM'}
    ) {
        $configPath = Join-Path $TestDrive 'invalid-trust.yml'
        $config = Get-Content $script:template -Raw | ConvertFrom-Yaml -Ordered
        $invalid = if ($KeyKind -eq 'multiline') { $script:key.Insert(20, "`n") } else { "-----BEGIN PUBLIC KEY-----`n$script:key`n-----END PUBLIC KEY-----" }
        $config.repositories.mirror.verificationPublicKeys = @($invalid)
        $config.repositories.projectUrl = 'file:///operator/project.git'
        $config | ConvertTo-Yaml | Set-Content $configPath
        $before = [IO.File]::ReadAllBytes($configPath)
        {
            switch ($Writer) {
                'Update' { $null = Update-TestConfigFromTemplate -ConfigPath $configPath -TemplatePath $script:template -Confirm:$false }
                'Sync' { $null = Sync-TestConfigToTemplate -ConfigPath $configPath -TemplatePath $script:template -Template (Get-Content $script:template -Raw | ConvertFrom-Yaml -Ordered) -Current $config -Confirm:$false }
                'Documented' { $null = Write-DocumentedTestConfig -ConfigPath $configPath -TemplatePath $script:template -Config $config -Confirm:$false }
            }
        } | Should -Throw '*mirror-key-invalid*'
        [IO.File]::ReadAllBytes($configPath) | Should -BeExactly $before
    }

    It 'rejects malformed keys without normalizing them' -ForEach @(
        @{ KeyValue = 'not base64' }, @{ KeyValue = "YWJj`n" }, @{ KeyValue = '-----BEGIN PUBLIC KEY-----' }, @{ KeyValue = 'YWJj' }
    ) {
        @(Test-ConfigMirrorSetting -Config @{repositories=@{mirror=@{verificationPublicKeys=@($KeyValue)}}}).Cause | Should -Contain 'mirror-key-invalid'
    }

    It 'rejects a scalar key instead of silently converting it to a list' {
        @(Test-ConfigMirrorSetting -Config @{repositories=@{mirror=@{verificationPublicKeys=$script:key}}}).Cause | Should -Contain 'mirror-key-invalid'
    }

    It 'preserves omitted trust fields from an older editor or reference host' {
        $current = @{ repositories=@{mirror=@{mode='fallback';verificationPublicKeys=@($script:key);url='http://192.168.50.9'}} }
        $merged = Merge-ConfigMirrorSetting -Current $current -Proposed @{repositories=@{projectUrl='file:///operator/project.git'}}
        @($merged.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:key)
        $merged.repositories.mirror.mode | Should -BeExactly 'fallback'
        $merged.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        @(Get-ConfigMirrorChange -Current $current -Proposed $merged).Count | Should -Be 0
    }

    It 'fails the allow-list gate when a mirror template field is removed' -ForEach @(
        @{ Field='mode' }, @{ Field='url' }, @{ Field='verificationPublicKeys' }, @{ Field='mirrorOnlyMaxAgeSeconds' }, @{ Field='cachingProxyGitMirrorRefreshSeconds' }
    ) {
        $broken = (Get-Content $script:template -Raw) -replace ('(?m)^\s+' + $Field + ':.*\r?\n'), ''
        $path = Join-Path $TestDrive 'broken-template.yml'
        $broken | Set-Content $path
        $null = & pwsh -NoProfile -File (Join-Path $script:root 'tools/Test-ConfigLocaleSeed.ps1') -TemplatePath $path -Quiet
        $LASTEXITCODE | Should -Be 1
    }

    It 'rejects undersized RSA keys' {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        try { $weak = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) } finally { $rsa.Dispose() }
        { Get-ConfigMirrorKeyId -Value $weak } | Should -Throw '*mirror-key-invalid*'
    }

    It 'reports additions and replacements using fingerprints without key bytes' {
        $changes = @(Get-ConfigMirrorChange -Current @{} -Proposed @{repositories=@{mirror=@{verificationPublicKeys=@($script:key)}}})
        $changes.Count | Should -Be 1
        $changes[0].Previous | Should -Be ''
        $changes[0].Current | Should -Match '^[0-9a-f]{64}$'
        $changes[0].Current | Should -Not -Be $script:key
    }

    It 'rejects invalid bounds with typed failures' -ForEach @(
        @{ Config = @{repositories=@{mirror=@{mode='unknown'}}}; Cause='mirror-mode-invalid' },
        @{ Config = @{repositories=@{mirror=@{url='http://user:secret@proxy/'}}}; Cause='mirror-url-invalid' },
        @{ Config = @{repositories=@{mirror=@{mirrorOnlyMaxAgeSeconds=1209601}}}; Cause='mirror-age-invalid' },
        @{ Config = @{repositories=@{mirror=@{mirrorOnlyMaxAgeSeconds=('9' * 100)}}}; Cause='mirror-age-invalid' },
        @{ Config = @{vmStart=@{cachingProxyGitMirrorRefreshSeconds=0}}; Cause='mirror-refresh-interval-invalid' },
        @{ Config = @{vmStart=@{cachingProxyGitMirrorRefreshSeconds='1.2'}}; Cause='mirror-refresh-interval-invalid' }
    ) {
        @(Test-ConfigMirrorSetting -Config $Config).Cause | Should -Contain $Cause
    }
}
