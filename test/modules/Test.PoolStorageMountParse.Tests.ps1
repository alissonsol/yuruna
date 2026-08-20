<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42fe4c73-e319-458f-b4f5-d66b50142f3e
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
    Test-PoolStorageMountMatch must not open-code the ' on ' split, the Linux
    ' type ' vs macOS ' (' branch, or the remote-bare normalization that
    ConvertFrom-PoolStorageMountLine already performs -- a format quirk fixed in
    one parser would silently diverge from the other and misdetect a live mount.
    These guards assert the detector delegates to the general parser and that
    each parse token appears exactly once in the module. Source-text only. Runs under Pester 4.10.1
    (script-scoped throw helper).
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

Describe 'poolstorage-mount-parse -- the mount-line parse is not duplicated' {
    It 'Test-PoolStorageMountMatch delegates to ConvertFrom-PoolStorageMountLine' {
        $body = Get-PoolStorageFunctionText -Name 'Test-PoolStorageMountMatch'
        $n = ([regex]::Matches($body, [regex]::Escape('ConvertFrom-PoolStorageMountLine -MountLine ([string]$line)'))).Count
        Assert-True ($n -eq 1) "the detector must parse each line via the shared parser, found $n such calls in its body"
    }
    It 'every mount-table enumerator parses through the shared parser' {
        foreach ($fn in @('Test-PoolStorageMountMatch', 'Find-PoolStorageTierMount', 'Find-PoolStorageConflictingMount')) {
            $body = Get-PoolStorageFunctionText -Name $fn
            Assert-True ($body -match [regex]::Escape('ConvertFrom-PoolStorageMountLine -MountLine')) "$fn must parse its lines via the shared parser"
        }
    }
    It "the Linux ' type ' branch appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($script:src, [regex]::Escape(".IndexOf(' type ')"))).Count
        Assert-True ($n -eq 1) "expected one ' type ' split after dedup, found $n"
    }
    It "the macOS ' (' branch appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($script:src, [regex]::Escape(".LastIndexOf(' (')"))).Count
        Assert-True ($n -eq 1) "expected one ' (' split after dedup, found $n"
    }
    It "the ' on ' remote/point split appears exactly once (only in the parser)" {
        $n = ([regex]::Matches($script:src, [regex]::Escape(".IndexOf(' on ')"))).Count
        Assert-True ($n -eq 1) "expected one ' on ' split after dedup, found $n"
    }
}
