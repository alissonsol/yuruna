<#PSScriptInfo
.VERSION 2026.07.24
.GUID 42d9f5a7-c3e4-4b02-8f56-8a7b9c0d1e23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool intent apache alias proxy pester
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
    Guards on Sync-PoolIntentAliasOnProxy, which repoints the caching proxy's
    read-only /pool-intent.git route at the pool NAS store.
.DESCRIPTION
    The function reconfigures a SHARED service every pooled runner pulls from,
    so the guards matter more than the happy path:

      * no proxy address / no ssh module  -> skip, never a hard failure
      * a store path carrying a quote     -> refused before it reaches a shell
      * -WhatIf                           -> no remote call at all
      * remote SKIP/OK/CHANGED            -> mapped onto Ok/Changed faithfully

    Invoke-GuestSsh is mocked in module scope, so no packet leaves the machine;
    addresses are TEST-NET (192.0.2.x, RFC 5737).

    Run: pwsh -NoProfile -File test/modules/Test.PoolIntentAliasSync.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }

Import-Module (Join-Path $here 'Test.Ssh.psm1')          -Global -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.CachingProxy.psm1')         -Force -DisableNameChecking

Describe 'Sync-PoolIntentAliasOnProxy guards' {
    BeforeEach { $env:YURUNA_CACHING_PROXY_IP = '' }
    AfterEach  { $env:YURUNA_CACHING_PROXY_IP = '' }

    Context 'refuses to act without a target' {
        It 'skips when no proxy address can be resolved' {
            Mock Read-CachingProxyState -ModuleName Test.CachingProxy { $null }
            $r = Sync-PoolIntentAliasOnProxy -Confirm:$false
            Assert-False $r.Ok 'unresolvable proxy is not a success'
            Assert-False $r.Changed 'nothing was changed'
            Assert-True ($r.Message -match 'no caching-proxy address') $r.Message
        }
    }

    Context 'refuses a store path that could escape into the remote shell' {
        It 'rejects a single quote before any ssh happens' {
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath "/mnt/x';id;'" -Confirm:$false
            Assert-False $r.Ok 'a quoted path must not be sent'
            Assert-True ($r.Message -match 'refusing a store path') $r.Message
        }
        It 'rejects embedded whitespace' {
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -StorePath '/mnt/two words.git' -Confirm:$false
            Assert-False $r.Ok
            Assert-True ($r.Message -match 'refusing a store path') $r.Message
        }
    }

    Context 'maps the remote outcome faithfully' {
        It 'reports Changed when the proxy rewrote the alias' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy {
                @{ success = $true; exitCode = 0; output = 'CHANGED: /pool-intent.git -> /mnt/ypool-nas/pool-intent.git' }
            }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-True $r.Ok
            Assert-True $r.Changed 'CHANGED must surface so the operator is told'
        }
        It 'reports success WITHOUT Changed when the alias was already correct' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy {
                @{ success = $true; exitCode = 0; output = 'OK: alias already serves /mnt/ypool-nas/pool-intent.git' }
            }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-True $r.Ok
            Assert-False $r.Changed 'an idempotent re-run must not claim a change'
        }
        It 'reports success WITHOUT Changed when the store is absent (the 404-every-runner guard)' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy {
                @{ success = $true; exitCode = 0; output = 'SKIP: no bare repo at /mnt/ypool-nas/pool-intent.git' }
            }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Changed 'apache must never be repointed at a missing store'
        }
        It 'reports failure when the remote step failed' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy {
                @{ success = $false; exitCode = 1; output = 'FAILED: apache rejected the new conf; restored the previous one' }
            }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Ok
            Assert-False $r.Changed
        }
        It 'never throws when ssh itself blows up' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy { throw 'ssh exploded' }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -Confirm:$false
            Assert-False $r.Ok 'a bring-up must not fail over this'
            Assert-True ($r.Message -match 'ssh exploded') $r.Message
        }
    }

    Context 'WhatIf' {
        It 'makes no remote call' {
            Mock Invoke-GuestSsh -ModuleName Test.CachingProxy { throw 'must not be called under -WhatIf' }
            $r = Sync-PoolIntentAliasOnProxy -ProxyAddress '192.0.2.10' -WhatIf
            Assert-True $r.Ok
            Assert-False $r.Changed
        }
    }
}
