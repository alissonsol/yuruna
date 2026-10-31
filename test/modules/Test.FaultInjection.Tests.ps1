<#PSScriptInfo
.VERSION 2026.10.31
.GUID 423e089a-1db3-4c9e-9470-56b8ea08d48b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner fault-injection chaos pester
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
    Pester coverage for the runner's fault points: when one fires, what it
    does, and that each named point sits where its name says, behind the
    environment check that keeps a real cycle from paying for it.
.DESCRIPTION
    The composed-loop chaos cases that fire these points inside the real
    resident, cycle process and inner live in Test.RunnerThreeProcess, whose
    chain harness they need.
    Run: Invoke-Pester -Path test/modules/Test.FaultInjection.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:TestRoot = Split-Path -Parent $here
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.FaultInjection.psm1') -Force -Global -DisableNameChecking
}

Describe 'Invoke-YurunaFaultPoint' {
    BeforeEach {
        $script:SavedPoints = Save-YurunaTestEnvironment -Name 'YURUNA_FAULT_POINTS'
        $script:Runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $null = New-Item -ItemType Directory -Path $script:Runtime
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedPoints
    }

    It 'does nothing when no point is armed' {
        Remove-Item -LiteralPath Env:YURUNA_FAULT_POINTS -ErrorAction SilentlyContinue
        $null = New-Item -ItemType File -Path (Join-Path $script:Runtime 'fault-injection.enabled')
        { Invoke-YurunaFaultPoint -Name 'status-write' -RuntimeDir $script:Runtime } | Should -Not -Throw
    }

    It 'does nothing without the marker in the runtime folder, even when armed' {
        $env:YURUNA_FAULT_POINTS = 'status-write'
        { Invoke-YurunaFaultPoint -Name 'status-write' -RuntimeDir $script:Runtime } | Should -Not -Throw
        Assert-False (Test-Path -LiteralPath (Join-Path $script:Runtime 'fault-injection.log')) 'nothing fired, nothing logged'
    }

    It 'throws a marked exception and logs the point when armed and marked' {
        $env:YURUNA_FAULT_POINTS = 'ocr, status-write'
        $null = New-Item -ItemType File -Path (Join-Path $script:Runtime 'fault-injection.enabled')
        $thrown = $null
        try { Invoke-YurunaFaultPoint -Name 'status-write' -RuntimeDir $script:Runtime } catch { $thrown = $_.Exception.Message }
        Assert-Equal -Expected 'YurunaFaultInjected: status-write' -Actual $thrown
        Assert-Match -Pattern "pid=$PID point=status-write action=throw" -Actual (Get-Content -Raw -LiteralPath (Join-Path $script:Runtime 'fault-injection.log'))
    }

    It 'leaves a point that is not armed alone' {
        $env:YURUNA_FAULT_POINTS = 'ocr'
        $null = New-Item -ItemType File -Path (Join-Path $script:Runtime 'fault-injection.enabled')
        { Invoke-YurunaFaultPoint -Name 'capture' -RuntimeDir $script:Runtime } | Should -Not -Throw
    }

    It 'hangs for the configured time, and ends the process on exit' {
        $null = New-Item -ItemType File -Path (Join-Path $script:Runtime 'fault-injection.enabled')
        $savedHang = Save-YurunaTestEnvironment -Name 'YURUNA_FAULT_HANG_SECONDS'
        try {
            $env:YURUNA_FAULT_POINTS = 'capture:hang'
            $env:YURUNA_FAULT_HANG_SECONDS = '1'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Invoke-YurunaFaultPoint -Name 'capture' -RuntimeDir $script:Runtime
            Assert-True ($watch.Elapsed.TotalMilliseconds -ge 900) 'the hang lasted'
        } finally { Restore-YurunaTestEnvironment -Saved $savedHang }
        $child = "Import-Module '$(Join-Path $here 'Test.FaultInjection.psm1')'; `$env:YURUNA_FAULT_POINTS = 'ocr:exit'; Invoke-YurunaFaultPoint -Name 'ocr' -RuntimeDir '$($script:Runtime)'; exit 0"
        & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command $child
        Assert-Equal -Expected 97 -Actual $LASTEXITCODE
    }
}

Describe 'each fault point sits where its name says' {
    It 'names exactly the documented points' {
        Assert-Equal -Expected 'before-inner-pid,capture,cycle-import,inner-import,ledger-read,ocr,status-write,step-heartbeat' `
            -Actual ((Get-YurunaFaultPointName | Sort-Object) -join ',')
    }

    It 'fires <Point> in <File>, behind the environment check' -TestCases @(
        @{ Point = 'cycle-import'; File = 'modules/Invoke-TestCycleRunner.ps1' }
        @{ Point = 'inner-import'; File = 'modules/Invoke-TestRunnerInnerLoop.ps1' }
        @{ Point = 'before-inner-pid'; File = 'modules/Invoke-TestRunnerInnerLoop.ps1' }
        @{ Point = 'step-heartbeat'; File = 'modules/Test.RunnerHeartbeat.psm1' }
        @{ Point = 'capture'; File = 'modules/Test.SequenceEngine.psm1' }
        @{ Point = 'ocr'; File = 'modules/Test.OcrEngine.psm1' }
        @{ Point = 'ledger-read'; File = 'modules/Test.RecoveryLedger.psm1' }
        @{ Point = 'status-write'; File = 'modules/Test.Status.psm1' }
    ) {
        param([string]$Point, [string]$File)
        $text = [IO.File]::ReadAllText((Join-Path $script:TestRoot $File))
        $pattern = "if \(\`$env:YURUNA_FAULT_POINTS\) \{ Import-Module \(Join-Path \`$PSScriptRoot 'Test\.FaultInjection\.psm1'\) -DisableNameChecking; Invoke-YurunaFaultPoint -Name '$([regex]::Escape($Point))'"
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($text, $pattern)).Count -Because "one guarded call of $Point"
    }

    It 'fires before-inner-pid before the inner records itself, and capture before each screen capture' {
        $inner = [IO.File]::ReadAllText((Join-Path $script:TestRoot 'modules/Invoke-TestRunnerInnerLoop.ps1'))
        Assert-True ($inner.IndexOf("-Name 'before-inner-pid'") -lt $inner.IndexOf('$innerPidWritten = Write-YurunaStateFile -Path $InnerPidFile')) 'before inner.pid'
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $here 'Test.SequenceEngine.psm1') -Name 'Wait-ForText'
        $body = $fn.Body.Extent.Text
        Assert-True ($body.IndexOf("-Name 'capture'") -lt $body.IndexOf('$captured = Get-VMScreenshot')) 'before the capture'
    }
}
