<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42b6c7d8-e9a0-4b12-8c34-5d6e7f8a9b03
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test registry comparer case-sensitivity pester
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
    New-YurunaRegistry reports the comparer of the store actually in use, not the
    requested -Comparer: when a global anchor already holds a store, the requested
    comparer is not applied, so the reported Comparer and the Clear rebuild must both
    follow the live store's case-sensitivity, and a warning surfaces the ignored request.
.DESCRIPTION
    Behavioral tests over the closure bundle: fresh registries report their own
    comparer; reusing an anchor with a mismatched -Comparer reports the live store's
    comparer (not the request), warns, and keeps its case-sensitivity across Clear.
    Each test uses a unique global anchor and removes it afterward. Pester 4.10.1.
#>

$here = Split-Path -Parent $PSCommandPath
$mod  = Join-Path $here 'Test.Registry.psm1'
Import-Module $mod -Force

function Get-TestAnchorName { 'Test_' + [System.Guid]::NewGuid().ToString('N') }

Describe 'New-YurunaRegistry reports the live store comparer' {
    It 'a fresh OrdinalIgnoreCase registry reports OrdinalIgnoreCase and is case-insensitive' {
        $av = Get-TestAnchorName
        try {
            $r = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $r.Comparer | Should -Be 'OrdinalIgnoreCase'
            & $r.Register 'a' 1; & $r.Register 'A' 2
            (& $r.Get 'a') | Should -Be 2   # 'A' overwrote 'a' -> case-insensitive
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'a fresh Ordinal registry reports Ordinal and is case-sensitive' {
        $av = Get-TestAnchorName
        try {
            $r = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal'
            $r.Comparer | Should -Be 'Ordinal'
            & $r.Register 'a' 1; & $r.Register 'A' 2
            (& $r.Get 'a') | Should -Be 1   # 'a' and 'A' distinct -> case-sensitive
            (& $r.Get 'A') | Should -Be 2
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'reusing an anchor with a different -Comparer reports the live store comparer, not the request' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $r2   = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal' -WarningAction SilentlyContinue
            $r2.Comparer | Should -Be 'OrdinalIgnoreCase'
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'reusing an anchor with a different -Comparer warns that the request was not applied' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal' -WarningVariable w -WarningAction SilentlyContinue
            @($w).Count | Should -BeGreaterOrEqual 1
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'not passing -Comparer on a reused anchor does not warn' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -WarningVariable w -WarningAction SilentlyContinue
            @($w).Count | Should -Be 0
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'Clear rebuilds the store with the live comparer, not the ignored request' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $r2   = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal' -WarningAction SilentlyContinue
            & $r2.Clear
            & $r2.Register 'a' 1; & $r2.Register 'A' 2
            (& $r2.Get 'a') | Should -Be 2   # still case-insensitive after Clear (not switched to Ordinal)
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'a mismatch reuse preserves live entries and the summary reports the live comparer' {
        $av = Get-TestAnchorName
        $nm = 'T_' + [System.Guid]::NewGuid().ToString('N')
        try {
            $r1 = New-YurunaRegistry -Name $nm -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            & $r1.Register 'kept' 42
            $r2 = New-YurunaRegistry -Name $nm -AnchorVar $av -Comparer 'Ordinal' -WarningAction SilentlyContinue
            (& $r2.Get 'kept') | Should -Be 42                # live entries survive the reuse
            $row = Get-YurunaRegistrySummary | Where-Object { $_.Name -eq $nm }
            $row | Should -Not -BeNullOrEmpty
            $row.Comparer | Should -Be 'OrdinalIgnoreCase'    # the summary view reports the live comparer too
        } finally {
            Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue
            $dir = Get-Variable -Name '__YurunaRegistryDirectory' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($dir) { [void]$dir.Remove($nm) }
        }
    }
}
