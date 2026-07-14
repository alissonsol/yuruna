<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42b0c62a-e89b-4a4d-88a0-ec973bcf58f3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test poolstorage mount parse pester
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
    Structural Pester guard on test/modules/Test.PoolStorage.psm1: the mount(8)
    line parse (remote / mount-point / type-vs-paren split, remote normalization)
    lives in ONE place -- ConvertFrom-PoolStorageMountLine -- and the live-mount
    detector Test-PoolStorageMountMatch reuses it instead of re-implementing it.
.DESCRIPTION
    Test-PoolStorageMountMatch used to open-code the same ' on ' split, the Linux
    ' type ' vs macOS ' (' branch, and the remote-bare normalization that
    ConvertFrom-PoolStorageMountLine already performs, so a format quirk fixed in
    one parser could silently diverge from the other and misdetect a live mount.
    These guards assert the detector now delegates to the general parser and that
    each parse token appears exactly once in the module (it appeared twice while
    the parse was duplicated). Source-text only. Runs under Pester 4.10.1
    (script-scoped throw helper).
#>

$here = Split-Path -Parent $PSCommandPath
$src  = Get-Content (Join-Path $here 'Test.PoolStorage.psm1') -Raw

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'poolstorage-mount-parse -- the mount-line parse is not duplicated' {
    It 'Test-PoolStorageMountMatch delegates to ConvertFrom-PoolStorageMountLine' {
        $n = ([regex]::Matches($src, [regex]::Escape('ConvertFrom-PoolStorageMountLine -MountLine ([string]$line)'))).Count
        Assert-True ($n -eq 1) "the detector must parse each line via the shared parser, found $n such calls"
    }
    It "the Linux ' type ' branch appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($src, [regex]::Escape(".IndexOf(' type ')"))).Count
        Assert-True ($n -eq 1) "expected one ' type ' split after dedup, found $n"
    }
    It "the macOS ' (' branch appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($src, [regex]::Escape(".LastIndexOf(' (')"))).Count
        Assert-True ($n -eq 1) "expected one ' (' split after dedup, found $n"
    }
    It "the ' on ' remote/point split appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($src, [regex]::Escape(".IndexOf(' on ')"))).Count
        Assert-True ($n -eq 1) "expected one ' on ' split after dedup, found $n"
    }
}
