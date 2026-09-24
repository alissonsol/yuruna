<#PSScriptInfo
.VERSION 2026.09.24
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

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
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
        Assert-True ($text.Contains("Get-TestConfigValue -Config `$tc -Path 'language'")) `
            "$_ does not read language from the validated config"
        Assert-True ($text.Contains('ConvertTo-CanonicalLocaleTag -Tag $languageRaw')) `
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
        Assert-True ($text.Contains("Get-TestConfigValue -Config `$hostStatusSeed.Config -Path 'language'")) `
            'the host-side proof does not read the validated lab-wide language'
        Assert-True ($text.Contains("'--language', `$poolControlLanguage")) `
            'the host-side proof never passes --language to the daemon'
        Assert-True ($text.Contains("if (`$AllowPseudoLocale) { `$goArgs += '--allow-pseudo-locale' }")) `
            'the host-side proof has no explicit pseudo switch'
        Assert-True ($text.Contains("if (`$AllowPseudoLocale) { `$newVmArgs += '-AllowPseudoLocale' }")) `
            'the VM launcher does not propagate the operator pseudo switch'
    }

    It 'carries the seed values through the guest env file and systemd command' {
        $guest = [IO.File]::ReadAllText($script:GuestPath)
        foreach ($needle in @(
            "sed -n 's/^YURUNA_LANGUAGE=//p' /etc/yuruna/pool.env"
            "sed -n 's/^YURUNA_ALLOW_PSEUDO_LOCALE=//p' /etc/yuruna/pool.env"
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
}
