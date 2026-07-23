<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42194e68-1535-4731-bba7-f7195cc13b3c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pidfile identity recovery pester
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
    Pester guard on the shared PID-file identity primitive: a kill path must
    force-kill ONLY the process that wrote the pidfile, never a PID the OS
    recycled onto an unrelated process.
.DESCRIPTION
    Two halves:
      * Test-PidFileIdentity (Test.YurunaDir) -- true only for a PowerShell
        process whose StartTime predates the pidfile mtime; false for a
        non-PowerShell process, a process that started after the pidfile
        (recycled), a null process, or an unreadable pidfile/StartTime.
      * Clear-StalePidFile -MtimeIdentity (Test.Recovery) -- the boot-recovery
        companion for service pidfiles with no .start sidecar: clears a live
        PID that started after the pidfile mtime, keeps one that started
        before, and clears a dead PID.
#>

# Run under Pester 4.10.1 (the repo test convention): the top-level helper and
# Describe-body setup below are invisible inside It blocks under Pester 5's
# discovery/run scope split. See feedback_repo_tests_need_pester4.
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Force
Import-Module (Join-Path $here 'Test.Recovery.psm1')  -Force

function Write-TempPidFile {
    param([int]$PidValue, [datetime]$Mtime)
    $p = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-pidtest-" + [guid]::NewGuid().ToString('N') + '.pid')
    Set-Content -LiteralPath $p -Value "$PidValue"
    if ($PSBoundParameters.ContainsKey('Mtime')) { (Get-Item -LiteralPath $p).LastWriteTime = $Mtime }
    return $p
}

# This process, the stand-in for "the PowerShell process that wrote the pidfile".
# It is captured at FILE scope because a Describe body is executed during
# discovery and its variables are discarded before any It runs -- an in-Describe
# $me would reach the assertions as $null, quietly turning every case into the
# null-process case.
$me = Get-Process -Id $PID

Describe 'Test-PidFileIdentity' {
    It 'is true for the owning PowerShell process when the pidfile mtime is at/after its start' {
        $pf = Write-TempPidFile -PidValue $PID -Mtime (Get-Date)
        try { Test-PidFileIdentity -PidFile $pf -Process $me | Should -Be $true }
        finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'is false when the process started AFTER the pidfile mtime (recycled PID)' {
        $pf = Write-TempPidFile -PidValue $PID -Mtime ($me.StartTime.AddMinutes(-10))
        try { Test-PidFileIdentity -PidFile $pf -Process $me | Should -Be $false }
        finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'is false for a non-PowerShell process' {
        $pf = Write-TempPidFile -PidValue 1 -Mtime (Get-Date)
        try {
            $notPwsh = [pscustomobject]@{ ProcessName = 'chrome'; StartTime = (Get-Date).AddHours(-1); Id = 4242 }
            Test-PidFileIdentity -PidFile $pf -Process $notPwsh | Should -Be $false
        } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'is false for a null process' {
        $pf = Write-TempPidFile -PidValue 1 -Mtime (Get-Date)
        try { Test-PidFileIdentity -PidFile $pf -Process $null | Should -Be $false }
        finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'is false when the pidfile is missing' {
        Test-PidFileIdentity -PidFile (Join-Path ([IO.Path]::GetTempPath()) 'yuruna-absent.pid') -Process $me | Should -Be $false
    }
}

Describe 'Clear-StalePidFile -MtimeIdentity (service pidfile, no .start companion)' {
    It 'clears a live PID that started AFTER the pidfile mtime (recycled)' {
        $pf = Write-TempPidFile -PidValue 4242 -Mtime ((Get-Date).AddMinutes(-10))
        try {
            Mock -ModuleName Test.Recovery Get-Process { [pscustomobject]@{ Id = 4242; StartTime = (Get-Date) } }
            $r = Clear-StalePidFile -PidFile $pf -MtimeIdentity -Confirm:$false
            $r.reason | Should -Be 'pid_recycled'
            (Test-Path -LiteralPath $pf) | Should -Be $false
        } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps a live PID that started BEFORE the pidfile mtime (genuine owner)' {
        $pf = Write-TempPidFile -PidValue 4242 -Mtime (Get-Date)
        try {
            Mock -ModuleName Test.Recovery Get-Process { [pscustomobject]@{ Id = 4242; StartTime = (Get-Date).AddMinutes(-10) } }
            $r = Clear-StalePidFile -PidFile $pf -MtimeIdentity -Confirm:$false
            $r | Should -Be $null
            (Test-Path -LiteralPath $pf) | Should -Be $true
        } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'clears a dead PID regardless of -MtimeIdentity' {
        $pf = Write-TempPidFile -PidValue 4242 -Mtime (Get-Date)
        try {
            Mock -ModuleName Test.Recovery Get-Process { $null }
            $r = Clear-StalePidFile -PidFile $pf -MtimeIdentity -Confirm:$false
            $r.reason | Should -Be 'process_not_running'
            (Test-Path -LiteralPath $pf) | Should -Be $false
        } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps a live PID with NO -MtimeIdentity and no companion (conservative)' {
        $pf = Write-TempPidFile -PidValue 4242 -Mtime ((Get-Date).AddMinutes(-10))
        try {
            Mock -ModuleName Test.Recovery Get-Process { [pscustomobject]@{ Id = 4242; StartTime = (Get-Date) } }
            $r = Clear-StalePidFile -PidFile $pf -Confirm:$false
            $r | Should -Be $null
            (Test-Path -LiteralPath $pf) | Should -Be $true
        } finally { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
}
