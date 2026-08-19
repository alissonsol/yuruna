<#PSScriptInfo
.VERSION 2026.08.19
.GUID 424fe851-fed8-47ea-9226-0b27f8af81c6
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
    optional 'user@' strip and trailing-slash trim) is the single definition of
    'the same share' that mount/identity
    checks depend on. These guards assert the base regex appears exactly once,
    the helper is defined with both optional
    switches, and every share-derivation site delegates to it. Source-text only.
    Runs under Pester 4.10.1 (script-scoped throw helper).
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$script:src  = Get-Content (Join-Path $here 'Test.PoolStorage.psm1') -Raw

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The source text of ONE top-level function, from its 'function' line to the start
# of the next top-level function or of that function's doc-comment block. Lets a
# guard assert WHERE a call sits instead of how often it appears module-wide -- a
# module-wide count turns every new correctly-delegating caller into a failure.
function Get-PoolStorageFunctionText {
    param([Parameter(Mandatory)][string]$Name)
    $m = [regex]::Match($script:src, ('(?ms)^function\s+' + [regex]::Escape($Name) + '\b.*?(?=^<\#|^function\s|\z)'))
    if (-not $m.Success) { throw "function $Name is not defined in Test.PoolStorage.psm1" }
    return $m.Value
}

}

Describe 'poolstorage-bare-share -- one canonicalizer, not seven copies' {
    It 'defines a Get-PoolStorageBareShare helper with both optional switches' {
        Assert-True ($script:src -match '(?m)^function Get-PoolStorageBareShare\b') 'helper must exist'
        Assert-True ($script:src -match '\[switch\]\$WithoutUser')  'must expose -WithoutUser'
        Assert-True ($script:src -match '\[switch\]\$TrimTrailing') 'must expose -TrimTrailing'
    }
    It "the base slash-collapse regex appears exactly once (only in the helper)" {
        $n = ([regex]::Matches($script:src, [regex]::Escape("-replace '[\\/]+', '/'"))).Count
        Assert-True ($n -eq 1) "expected one base normalization after dedup, found $n"
    }
    It 'every share-derivation site delegates to the helper' {
        foreach ($fn in @(
                'Get-PoolStorageUncPath'
                'Test-PoolStorageMountMatch'
                'ConvertFrom-PoolStorageMountLine'
                'Find-PoolStorageTierMount'
                'Find-PoolStorageConflictingMount'
                'Connect-YurunaPoolStorage'
                'Get-PoolStorageServerName'
                'Initialize-PoolStorageTargetFolder')) {
            $body = Get-PoolStorageFunctionText -Name $fn
            Assert-True ($body -match [regex]::Escape('Get-PoolStorageBareShare -Path')) "$fn must derive its bare share through the helper"
        }
    }
}
