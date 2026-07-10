<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42b81e18-a081-4f36-a562-0f5fdfb2efbd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test poolstorage share normalize pester
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
    Structural Pester guard on test/modules/Test.PoolStorage.psm1: the
    share-path -> bare 'server/share' canonicalization lives in ONE helper
    (Get-PoolStorageBareShare) instead of being hand-rolled at every call site.
.DESCRIPTION
    The `($x -replace '[\\/]+', '/') -replace '^/+', ''` base normalization (with
    optional 'user@' strip and trailing-slash trim) was copy-pasted across seven
    call sites -- the single definition of 'the same share' that mount/identity
    checks depend on. These guards assert the base regex now appears exactly once
    (it was in all seven copies), the helper is defined with both optional
    switches, and every share-derivation site delegates to it. Source-text only.
    Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here = Split-Path -Parent $PSCommandPath
$src  = Get-Content (Join-Path $here 'Test.PoolStorage.psm1') -Raw

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'poolstorage-bare-share -- one canonicalizer, not seven copies' {
    It 'defines a Get-PoolStorageBareShare helper with both optional switches' {
        Assert-True ($src -match '(?m)^function Get-PoolStorageBareShare\b') 'helper must exist'
        Assert-True ($src -match '\[switch\]\$WithoutUser')  'must expose -WithoutUser'
        Assert-True ($src -match '\[switch\]\$TrimTrailing') 'must expose -TrimTrailing'
    }
    It "the base slash-collapse regex appears exactly once (only in the helper)" {
        $n = ([regex]::Matches($src, [regex]::Escape("-replace '[\\/]+', '/'"))).Count
        Assert-True ($n -eq 1) "expected one base normalization after dedup, found $n"
    }
    It 'the seven share-derivation sites all delegate to the helper' {
        $n = ([regex]::Matches($src, [regex]::Escape('Get-PoolStorageBareShare -Path'))).Count
        Assert-True ($n -eq 7) "expected seven delegating call sites, found $n"
    }
}
