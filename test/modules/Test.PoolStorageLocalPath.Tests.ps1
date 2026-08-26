<#PSScriptInfo
.VERSION 2026.08.25
.GUID 424870fb-615c-4ade-a4de-1429ce37a8ca
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test poolstorage localpath pester
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
    Structural Pester guard on test/modules/Test.PoolStorage.psm1: the localPath
    trim + leading-'~' expansion is shared by one Expand-YurunaLocalPath helper,
    not duplicated across the pool and stash storage-config readers.
.DESCRIPTION
    Get-YurunaPoolStorageConfig and Get-YurunaStashStorageConfig must share one
    trim + '~'-expansion block; a drift in the '~' rule would silently
    break one storage tier's mount path. These guards assert the block lives in
    one private helper, both readers delegate, the '~'-match regex appears exactly
    once, and the helper stays private. Source-text only. Runs under Pester 4.10.1.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$src      = Get-Content (Join-Path $here 'Test.PoolStorage.psm1') -Raw
$script:tildeRx  = '^~(?=[\\/]|$)'
$script:exportLn = ($src -split "`n" | Where-Object { $_ -match 'Export-ModuleMember' }) -join "`n"

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'poolstorage-localpath -- the ~-expansion is shared by one helper' {
    It 'defines an Expand-YurunaLocalPath helper' {
        Assert-True ($src -match '(?m)^function Expand-YurunaLocalPath\b') `
            'the duplicated trim + ~-expansion block must collapse into one helper'
    }
    It 'both storage-config readers delegate to Expand-YurunaLocalPath' {
        $n = ([regex]::Matches($src, [regex]::Escape('Expand-YurunaLocalPath -Path $localPath'))).Count
        Assert-True ($n -eq 2) "expected both readers to call Expand-YurunaLocalPath, found $n"
    }
    It 'the leading-~ expansion regex now appears exactly once (inside the helper)' {
        $n = ([regex]::Matches($src, [regex]::Escape($script:tildeRx))).Count
        Assert-True ($n -eq 1) "expected exactly one ~-expansion regex after dedup, found $n"
    }
    It 'Expand-YurunaLocalPath stays private (not in the Export-ModuleMember allowlist)' {
        Assert-True ($script:exportLn -match 'Export-ModuleMember') 'Export-ModuleMember must be present'
        Assert-True ($script:exportLn -notmatch 'Expand-YurunaLocalPath') 'the ~-expansion helper must not be exported'
    }
}
