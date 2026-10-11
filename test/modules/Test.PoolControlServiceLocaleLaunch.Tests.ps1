<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42fe2557-d61c-421d-b8c0-e41640d44f1a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna globalization pool control launcher locale pester
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
    Keep the pool-control daemon's locale options connected to every launcher.
.DESCRIPTION
    The Go flags are useful only when the host proof and all three VM seed
    builders carry the validated config value to the live process. These tests
    guard that shipped deployment path, including the separate pseudo-locale
    gate that must remain off unless a reference run asks for it explicitly.
#>

BeforeDiscovery {
    $script:CanRunBash = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
}

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:StartPath = Join-Path $script:RepoRoot 'test/service/Start-PoolControlServiceVM.ps1'
$script:SeedPath = Join-Path $script:RepoRoot 'host/vmconfig/pool-control-service.base.user-data'
$script:GuestPath = Join-Path $script:RepoRoot 'guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh'
}

Describe 'pool-control locale deployment wiring' {
    It 'bakes language and an off-by-default pseudo gate into the shared VM seed' {
        $seed = [IO.File]::ReadAllText($script:SeedPath)
        Assert-True ($seed.Contains('YURUNA_LANGUAGE=YURUNA_LANGUAGE_PLACEHOLDER')) `
            'the VM seed does not carry the lab-wide language'
        Assert-True ($seed.Contains(
                'YURUNA_ALLOW_PSEUDO_LOCALE=YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER')) `
            'the VM seed does not carry the explicit pseudo gate'
    }

    It 'validates and writes both values in <_>' -ForEach @(
        'host/ubuntu.kvm/guest.pool-control-service/New-VM.ps1'
        'host/windows.hyper-v/guest.pool-control-service/New-VM.ps1'
        'host/macos.utm/guest.pool-control-service/New-VM.ps1'
    ) {
        $path = Join-Path $script:RepoRoot $_
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-Equal -Expected 0 -Actual @($errors).Count -Because "$_ must parse"
        $text = [IO.File]::ReadAllText($path)
        Assert-True ($text.Contains('[switch]$AllowPseudoLocale')) `
            "$_ has no explicit pseudo reference-run switch"
        Assert-True ($text.Contains('Resolve-SeedLanguageTag -Config $tc')) `
            "$_ does not read language from the validated config"
        Assert-True ($text -notmatch 'YURUNA_LANGUAGE_PLACEHOLDER\s*=\s*\$languageRaw') `
            "$_ passes an unvalidated config value to the seed"
        Assert-True ($text.Contains('YURUNA_LANGUAGE_PLACEHOLDER       = $poolControlLanguage')) `
            "$_ does not replace the seed language"
        Assert-True ($text.Contains(
                'YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER = $allowPseudoLocaleValue')) `
            "$_ does not replace the seed pseudo gate"
        Assert-True ($text.Contains("if (`$AllowPseudoLocale) { 'true' } else { 'false' }")) `
            "$_ does not keep the pseudo gate off by default"
    }

    It 'passes language and the explicit pseudo switch from the host-side launcher' {
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile(
            $script:StartPath, [ref]$null, [ref]$errors)
        Assert-Equal -Expected 0 -Actual @($errors).Count -Because 'the host launcher must parse'
        $text = [IO.File]::ReadAllText($script:StartPath)
        Assert-True ($text.Contains('Resolve-SeedLanguageTag -Config $hostStatusSeed.Config')) `
            'the host-side proof does not read the validated lab-wide language'
        Assert-True ($text.Contains("'--language', `$poolControlLanguage")) `
            'the host-side proof never passes --language to the daemon'
        Assert-True ($text.Contains("if (`$AllowPseudoLocale) { `$goArgs += '--allow-pseudo-locale' }")) `
            'the host-side proof has no explicit pseudo switch'
        Assert-True ($text.Contains('Invoke-YurunaServiceVmBuild') -and $text.Contains('-AllowPseudoLocale:$AllowPseudoLocale')) `
            'the VM launcher does not propagate the operator pseudo switch'
    }

    It 'carries the seed values through the guest env file and systemd command' {
        $guest = [IO.File]::ReadAllText($script:GuestPath)
        foreach ($needle in @(
            "sed -n 's/^YURUNA_LANGUAGE=//p' `"`$GLOBALIZATION_ENV`""
            "sed -n 's/^YURUNA_ALLOW_PSEUDO_LOCALE=//p' `"`$GLOBALIZATION_ENV`""
            'POOL_CONTROL_LANGUAGE=$POOL_CONTROL_LANGUAGE'
            'POOL_CONTROL_ALLOW_PSEUDO_LOCALE=$POOL_CONTROL_ALLOW_PSEUDO_LOCALE'
            '--language=\${POOL_CONTROL_LANGUAGE}'
            '--allow-pseudo-locale=\${POOL_CONTROL_ALLOW_PSEUDO_LOCALE}'
        )) {
            Assert-True ($guest.Contains($needle)) "the guest launch path lost '$needle'"
        }
        Assert-True ($guest.Contains(
                '[ "$POOL_CONTROL_ALLOW_PSEUDO_LOCALE" = true ] || POOL_CONTROL_ALLOW_PSEUDO_LOCALE=false')) `
            'a missing or noncanonical pseudo value can enable pseudo negotiation'
    }

    It 'stores locale settings in the same dedicated file as the other service seeds' {
        Import-Module powershell-yaml -ErrorAction Stop
        $seed = ConvertFrom-Yaml ([IO.File]::ReadAllText($script:SeedPath))
        $locale = @($seed.write_files | Where-Object path -eq '/etc/yuruna/globalization.env')
        $locale.Count | Should -Be 1
        $locale[0].owner | Should -Be 'root:root'
        $locale[0].permissions | Should -Be '0644'
        $locale[0].content | Should -Match '(?m)^YURUNA_LANGUAGE=YURUNA_LANGUAGE_PLACEHOLDER$'
        $locale[0].content | Should -Match '(?m)^YURUNA_ALLOW_PSEUDO_LOCALE=YURUNA_ALLOW_PSEUDO_LOCALE_PLACEHOLDER$'
        $pool = @($seed.write_files | Where-Object path -eq '/etc/yuruna/pool.env')
        $pool.Count | Should -Be 1
        $pool[0].content | Should -Not -Match '(?m)^YURUNA_(LANGUAGE|ALLOW_PSEUDO_LOCALE)='
    }
}

Describe 'pool-control guest locale source selection' -Skip:(-not $script:CanRunBash) {
    It 'uses <Name>' -ForEach @(
        @{ Name='canonical settings'; Canonical="YURUNA_LANGUAGE=es-ES`nYURUNA_ALLOW_PSEUDO_LOCALE=true"; Legacy="YURUNA_LANGUAGE=fr-FR`nYURUNA_ALLOW_PSEUDO_LOCALE=false"; Expected='es-ES|true' },
        @{ Name='canonical auto and false over stale legacy values'; Canonical="YURUNA_LANGUAGE=auto`nYURUNA_ALLOW_PSEUDO_LOCALE=false"; Legacy="YURUNA_LANGUAGE=fr-FR`nYURUNA_ALLOW_PSEUDO_LOCALE=true"; Expected='auto|false' },
        @{ Name='canonical defaults when the dedicated file is empty'; Canonical=''; Legacy="YURUNA_LANGUAGE=fr-FR`nYURUNA_ALLOW_PSEUDO_LOCALE=true"; Expected='auto|false' },
        @{ Name='canonical pseudo gate only with the exact true value'; Canonical="YURUNA_LANGUAGE=en-US`nYURUNA_ALLOW_PSEUDO_LOCALE=TRUE"; Legacy=$null; Expected='en-US|false' },
        @{ Name='legacy settings when the dedicated file is absent'; Canonical=$null; Legacy="YURUNA_LANGUAGE=fr-FR`nYURUNA_ALLOW_PSEUDO_LOCALE=true"; Expected='fr-FR|true' },
        @{ Name='defaults when both settings files are absent'; Canonical=$null; Legacy=$null; Expected='auto|false' }
    ) {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        foreach ($file in @{ 'globalization.env'=$Canonical; 'pool.env'=$Legacy }.GetEnumerator()) {
            if ($null -ne $file.Value) {
                Set-Content -LiteralPath (Join-Path $fixture $file.Key) -Value $file.Value -Encoding utf8NoBOM
            }
        }
        $source = [IO.File]::ReadAllText($script:GuestPath)
        $start = $source.IndexOf('GLOBALIZATION_ENV=/etc/yuruna/globalization.env', [StringComparison]::Ordinal)
        $end = $source.IndexOf('# Aggregator URL', $start, [StringComparison]::Ordinal)
        $start | Should -BeGreaterOrEqual 0
        $end | Should -BeGreaterThan $start
        $phase = $source.Substring($start, $end - $start).Replace('/etc/yuruna/', '${FIXTURE_ROOT}/')
        $entry = Join-Path $fixture 'locale.sh'
        $body = 'set -euo pipefail' + "`n" + $phase + "`nprintf '%s|%s' `"`$POOL_CONTROL_LANGUAGE`" `"`$POOL_CONTROL_ALLOW_PSEUDO_LOCALE`"`n"
        Set-Content -LiteralPath $entry -Value $body -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash -ErrorAction Stop).Source -ArgumentList @($entry) -TimeoutSeconds 10 `
            -Environment @{ FIXTURE_ROOT=$fixture }
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut.Trim() | Should -BeExactly $Expected
    }
}
