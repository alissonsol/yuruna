<#PSScriptInfo
.VERSION 2026.07.17
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
    New-YurunaRegistry reports the comparer of the store actually in use, derived from
    its live type: when a global anchor already holds a store and the caller passes an
    explicit -Comparer that disagrees, the existing entries are migrated into a fresh
    store under the requested comparer (never silently ignored), so the reported
    Comparer and the Clear rebuild both follow the requested case-sensitivity.
.DESCRIPTION
    Behavioral tests over the closure bundle: fresh registries report their own
    comparer; reusing an anchor with a mismatched explicit -Comparer migrates the live
    entries into the requested comparer, reports it, preserves the entries, and keeps
    that case-sensitivity across Clear -- without throwing. Each test uses a unique
    global anchor and removes it afterward. Pester 4.10.1.
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
    It 'reusing an anchor with a different explicit -Comparer migrates to the requested comparer' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $r2   = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal'
            $r2.Comparer | Should -Be 'Ordinal'
            & $r2.Register 'a' 1; & $r2.Register 'A' 2
            (& $r2.Get 'a') | Should -Be 1   # migrated store is now case-sensitive
            (& $r2.Get 'A') | Should -Be 2
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'migrating on a comparer mismatch does not throw' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            { New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal' } | Should -Not -Throw
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'not passing -Comparer on a reused anchor keeps the live comparer' {
        $av = Get-TestAnchorName
        try {
            $r1 = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal'
            & $r1.Register 'a' 1; & $r1.Register 'A' 2
            $r2 = New-YurunaRegistry -Name 'T' -AnchorVar $av   # no -Comparer: no migration
            $r2.Comparer | Should -Be 'Ordinal'
            (& $r2.Get 'a') | Should -Be 1   # still case-sensitive; the live store was untouched
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'Clear rebuilds the store with the migrated comparer' {
        $av = Get-TestAnchorName
        try {
            $null = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            $r2   = New-YurunaRegistry -Name 'T' -AnchorVar $av -Comparer 'Ordinal'
            & $r2.Clear
            & $r2.Register 'a' 1; & $r2.Register 'A' 2
            (& $r2.Get 'a') | Should -Be 1   # case-sensitive after Clear (Clear followed the migrated comparer)
            (& $r2.Get 'A') | Should -Be 2
        } finally { Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'a mismatch reuse migrates live entries and the summary reports the migrated comparer' {
        $av = Get-TestAnchorName
        $nm = 'T_' + [System.Guid]::NewGuid().ToString('N')
        try {
            $r1 = New-YurunaRegistry -Name $nm -AnchorVar $av -Comparer 'OrdinalIgnoreCase'
            & $r1.Register 'kept' 42
            $r2 = New-YurunaRegistry -Name $nm -AnchorVar $av -Comparer 'Ordinal'
            (& $r2.Get 'kept') | Should -Be 42                # live entries survive the migration
            $row = Get-YurunaRegistrySummary | Where-Object { $_.Name -eq $nm }
            $row | Should -Not -BeNullOrEmpty
            $row.Comparer | Should -Be 'Ordinal'              # the summary view reports the migrated comparer too
        } finally {
            Remove-Variable -Name $av -Scope Global -ErrorAction SilentlyContinue
            $dir = Get-Variable -Name '__YurunaRegistryDirectory' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
            if ($dir) { [void]$dir.Remove($nm) }
        }
    }
}
