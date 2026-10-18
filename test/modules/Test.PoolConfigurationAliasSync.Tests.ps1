<#PSScriptInfo
.VERSION 2026.10.18
.GUID 428a6a51-09a1-4515-99d2-2504e234cbcf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool configuration apache alias proxy pester
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
    Guards on Sync-PoolConfigurationAliasOnProxy, which repoints the caching-proxy service's
    read-only /pool-configuration.git route at the pool NAS store.
.DESCRIPTION
    The function reconfigures a SHARED service every pooled runner pulls from,
    so the guards matter more than the happy path:

      * no proxy address / no ssh module  -> skip, never a hard failure
      * a store path carrying a quote     -> refused before it reaches a shell
      * -WhatIf                           -> no remote call at all
      * remote SKIP/OK/CHANGED            -> mapped onto Ok/Changed faithfully

    Invoke-GuestSsh is mocked in module scope, so no packet leaves the machine;
    addresses are TEST-NET (192.0.2.x, RFC 5737).

    Run: pwsh -NoProfile -File test/modules/Test.PoolConfigurationAliasSync.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

Import-Module (Join-Path $here 'Test.Ssh.psm1')          -Global -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.CachingProxyService.psm1')         -Force -DisableNameChecking

function New-AliasShellFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates only isolated files under TestDrive.')]
    [CmdletBinding()]
    param([switch]$LegacyEnabled, [switch]$CanonicalEnabled)
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $store = Join-Path $root 'store.git'
    $apache = Join-Path $root 'apache2'
    $available = Join-Path $apache 'conf-available'
    $enabled = Join-Path $apache 'conf-enabled'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $store 'refs'), $available, $enabled
    $canonical = Join-Path $available 'yuruna-pool-configuration.conf'
    $legacy = Join-Path $available 'yuruna-pool-intent.conf'
    Set-Content -LiteralPath $legacy -Value 'Alias /pool-intent.git /old/store.git'
    if ($LegacyEnabled) { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $enabled 'yuruna-pool-intent.conf') -Target $legacy }
    if ($CanonicalEnabled) {
        Set-Content -LiteralPath $canonical -Value "Alias /pool-configuration.git $store"
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $enabled 'yuruna-pool-configuration.conf') -Target $canonical
    }
    return [pscustomobject]@{ Root = $root; Store = $store; Apache = $apache; Canonical = $canonical; Legacy = $legacy; Enabled = $enabled }
}

}

Describe 'Sync-PoolConfigurationAliasOnProxy guards' {
    BeforeEach { $env:YURUNA_CACHING_PROXY_SERVICE_IP = '' }
    AfterEach  { $env:YURUNA_CACHING_PROXY_SERVICE_IP = '' }

    Context 'refuses to act without a target' {
        It 'skips when no proxy address can be resolved' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { $null }
            $r = Sync-PoolConfigurationAliasOnProxy -Confirm:$false
            Assert-False $r.Ok 'unresolvable proxy is not a success'
            Assert-False $r.Changed 'nothing was changed'
            Assert-True ($r.Message -match 'no caching-proxy-service address') $r.Message
        }
    }

    Context 'refuses a store path that could escape into the remote shell' {
        It 'rejects a single quote before any ssh happens' {
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath "/mnt/x';id;'" -Confirm:$false
            Assert-False $r.Ok 'a quoted path must not be sent'
            Assert-True ($r.Message -match 'refusing a store path') $r.Message
        }
        It 'rejects embedded whitespace' {
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath '/mnt/two words.git' -Confirm:$false
            Assert-False $r.Ok
            Assert-True ($r.Message -match 'refusing a store path') $r.Message
        }
    }

    Context 'maps the remote outcome faithfully' {
        It 'reports Changed when the proxy rewrote the alias' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService {
                @{ success = $true; exitCode = 0; output = 'CHANGED: /pool-configuration.git -> /mnt/ypool-nas/pool-configuration.git' }
            }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-True $r.Ok
            Assert-True $r.Changed 'CHANGED must surface so the operator is told'
        }
        It 'reports success WITHOUT Changed when the alias was already correct' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService {
                @{ success = $true; exitCode = 0; output = 'OK: alias already serves /mnt/ypool-nas/pool-configuration.git' }
            }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-True $r.Ok
            Assert-False $r.Changed 'an idempotent re-run must not claim a change'
        }
        It 'reports success WITHOUT Changed when the store is absent (the 404-every-runner guard)' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService {
                @{ success = $true; exitCode = 0; output = 'SKIP: no bare repo at /mnt/ypool-nas/pool-configuration.git' }
            }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Changed 'apache must never be repointed at a missing store'
        }
        It 'reports failure when the remote step failed' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService {
                @{ success = $false; exitCode = 1; output = 'FAILED: apache rejected the new conf; restored the previous one' }
            }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Ok
            Assert-False $r.Changed
        }
        It 'never throws when ssh itself blows up' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService { throw 'ssh exploded' }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Ok 'a bring-up must not fail over this'
            Assert-True ($r.Message -match 'ssh exploded') $r.Message
        }
    }

    Context 'WhatIf' {
        It 'makes no remote call' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService { throw 'must not be called under -WhatIf' }
            $r = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -WhatIf
            Assert-True $r.Ok
            Assert-False $r.Changed
        }
    }
}

Describe 'Sync-PoolConfigurationAliasOnProxy migrates Apache routes' -Skip:($IsWindows -or -not [bool](Get-Command bash -ErrorAction SilentlyContinue)) {
    BeforeEach {
        Mock Invoke-GuestSsh -ModuleName Test.CachingProxyService {
            $store = [regex]::Match($Command, "(?m)^STORE='([^']+)'$").Groups[1].Value
            $apache = Join-Path (Split-Path -Parent $store) 'apache2'
            # All filesystem paths and privileged commands stay inside this fixture.
            $stubs = @'
sudo() { "$@"; }
a2enconf() { ln -sfn "$APACHE_FIXTURE/conf-available/$1.conf" "$APACHE_FIXTURE/conf-enabled/$1.conf"; }
a2disconf() { rm -f "$APACHE_FIXTURE/conf-enabled/$1.conf"; }
apache2ctl() {
  if [ -f "$APACHE_FIXTURE/configtest.fail" ]; then echo 'invalid configuration'; return 1; fi
  echo 'Syntax OK'
}
systemctl() {
  if [ -f "$APACHE_FIXTURE/reload.fail" ]; then return 1; fi
  echo reload >> "$APACHE_FIXTURE/reloads"
}
'@
            $body = $stubs + "`n" + $Command.Replace('/etc/apache2', $apache)
            $result = Invoke-YurunaTestShell -Body $body -Environment @{ APACHE_FIXTURE = $apache }
            return @{ success = ($result.ExitCode -eq 0); exitCode = $result.ExitCode; output = $result.Output }
        }
    }
    It 'moves an enabled legacy route onto the canonical store and disables the old configuration' {
        $fixture = New-AliasShellFixture -LegacyEnabled
        $legacyBefore = Get-Content -Raw -LiteralPath $fixture.Legacy
        $result = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath $fixture.Store -Confirm:$false
        $result.Ok | Should -BeTrue -Because $result.Message
        $result.Changed | Should -BeTrue
        $conf = Get-Content -Raw -LiteralPath $fixture.Canonical
        $conf | Should -Match ([regex]::Escape("Alias /pool-configuration.git $($fixture.Store)"))
        $conf | Should -Match ([regex]::Escape("Alias /pool-intent.git $($fixture.Store)"))
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-intent.conf') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-configuration.conf') | Should -BeTrue
        Get-Content -Raw -LiteralPath $fixture.Legacy | Should -BeExactly $legacyBefore
        $again = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath $fixture.Store -Confirm:$false
        $again.Ok | Should -BeTrue
        $again.Changed | Should -BeFalse
        @(Get-Content -LiteralPath (Join-Path $fixture.Apache 'reloads')).Count | Should -Be 1
    }
    It 'repairs a canonical configuration that is missing the legacy compatibility route' {
        $fixture = New-AliasShellFixture -CanonicalEnabled
        $result = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath $fixture.Store -Confirm:$false
        $result.Ok | Should -BeTrue -Because $result.Message
        $result.Changed | Should -BeTrue
        Get-Content -Raw -LiteralPath $fixture.Canonical | Should -Match ([regex]::Escape("Alias /pool-intent.git $($fixture.Store)"))
    }
    It 'restores an existing configuration and both enabled states when <Failure> fails' -ForEach @(
        @{ Failure = 'configtest' }
        @{ Failure = 'reload' }
    ) {
        $fixture = New-AliasShellFixture -LegacyEnabled -CanonicalEnabled
        $before = Get-Content -Raw -LiteralPath $fixture.Canonical
        Set-Content -LiteralPath (Join-Path $fixture.Apache "$Failure.fail") -Value 'fail'
        $result = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath $fixture.Store -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.Changed | Should -BeFalse
        Get-Content -Raw -LiteralPath $fixture.Canonical | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-intent.conf') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-configuration.conf') | Should -BeTrue
    }
    It 'removes a newly created configuration and restores the legacy route when validation fails' {
        $fixture = New-AliasShellFixture -LegacyEnabled
        Set-Content -LiteralPath (Join-Path $fixture.Apache 'configtest.fail') -Value 'fail'
        $result = Sync-PoolConfigurationAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath $fixture.Store -Confirm:$false
        $result.Ok | Should -BeFalse
        Test-Path -LiteralPath $fixture.Canonical | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-configuration.conf') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.Enabled 'yuruna-pool-intent.conf') | Should -BeTrue
    }
}
