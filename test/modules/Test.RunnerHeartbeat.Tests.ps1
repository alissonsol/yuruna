<#PSScriptInfo
.VERSION 2026.08.25
.GUID 42fba86f-4ea4-4dbf-82c2-0ea57b04218c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner heartbeat pester
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
    Pester coverage for Test.RunnerHeartbeat.psm1 (the threadpool runner.heartbeat
    timer). Verifies the file is seeded and advanced while running, that Stop
    halts it, and that the error counter starts clean.
.DESCRIPTION
    Uses a short timer period so the test runs in well under a second. Throw-based
    assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RunnerHeartbeat.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'Start/Stop-RunnerHeartbeat' {
    It 'seeds the file, advances it while running, then freezes on Stop' {
        $f = [System.IO.Path]::GetTempFileName()
        try {
            Start-RunnerHeartbeat -Path $f -DueMs 40 -PeriodMs 40
            Start-Sleep -Milliseconds 250
            Assert-True (Test-Path $f) 'heartbeat file exists'
            $mtA = (Get-Item $f).LastWriteTimeUtc
            Start-Sleep -Milliseconds 200
            $mtB = (Get-Item $f).LastWriteTimeUtc
            Assert-True ($mtB -gt $mtA) 'timer advances the mtime while running'

            Stop-RunnerHeartbeat
            Start-Sleep -Milliseconds 120
            $mtC = (Get-Item $f).LastWriteTimeUtc
            Start-Sleep -Milliseconds 200
            $mtD = (Get-Item $f).LastWriteTimeUtc
            Assert-Equal -Expected $mtC -Actual $mtD -Because 'mtime frozen after Stop'
        } finally {
            Stop-RunnerHeartbeat
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    It 'Stop is idempotent (safe to call when not started / twice)' {
        Stop-RunnerHeartbeat
        Stop-RunnerHeartbeat   # must not throw
        Assert-True $true 'no throw on repeated Stop'
    }
    It 'Get-RunnerHeartbeatError returns a clean count on a healthy run' {
        $f = [System.IO.Path]::GetTempFileName()
        try {
            Start-RunnerHeartbeat -Path $f -DueMs 40 -PeriodMs 40
            Start-Sleep -Milliseconds 200
            Assert-Equal -Expected 0 -Actual (Get-RunnerHeartbeatError) -Because 'no write errors on a writable path'
        } finally {
            Stop-RunnerHeartbeat
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
}
