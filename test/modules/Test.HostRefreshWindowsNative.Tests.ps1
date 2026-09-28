<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42a7f823-d59f-4fc6-8a5e-3c728e041b69
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh hyper-v windows native pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7.2

<#
.SYNOPSIS
    Opt-in native Windows checks for the bounded Hyper-V refresh driver.
.DESCRIPTION
    Set YURUNA_TEST_NATIVE_HYPERV=1 in an elevated PowerShell process on a
    Windows Hyper-V host with VMMS running. An opted-in run fails when those
    prerequisites are absent. Without the switch the native cases are skipped.

    No native command is mocked. Queries run through the driver's bounded
    child processes. The start verb always receives -WhatIf, including the
    already-running case, so a concurrent service stop cannot make this suite
    start VMMS. It never stops a service, changes a guest, or invokes the
    refresh orchestrator, runner, listener, or private journal.
#>

Describe 'Native Windows Hyper-V refresh driver' -Tag 'NativeHyperV' -Skip:($env:YURUNA_TEST_NATIVE_HYPERV -cne '1') {
    BeforeAll {
        $script:NativeHyperVModule = $null
        if (-not $IsWindows) { throw 'YURUNA_TEST_NATIVE_HYPERV requires Windows.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            $principal = [Security.Principal.WindowsPrincipal]::new($identity)
            if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
                throw 'YURUNA_TEST_NATIVE_HYPERV requires an elevated PowerShell process.'
            }
        } finally { $identity.Dispose() }
        if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
            throw 'YURUNA_TEST_NATIVE_HYPERV requires the installed Hyper-V PowerShell module.'
        }

        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:NativeHyperVDriver = Join-Path $repoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
        Import-Module $script:NativeHyperVDriver -Force -Global -DisableNameChecking -ErrorAction Stop
        $script:NativeHyperVModule = Get-Module Yuruna.Host
        $script:NativeHyperVPwsh = (Get-Process -Id $PID).Path
        $service = Get-HyperVServiceEvidence -TimeoutSeconds 30
        if ($service.TimedOut -or $service.Status -ne 'Running') {
            throw "YURUNA_TEST_NATIVE_HYPERV requires a positively Running VMMS; got $($service.Status)."
        }

        function Get-NativeVmmsIdentity {
            [CmdletBinding()]
            [OutputType([string])]
            param()
            $processes = @([Diagnostics.Process]::GetProcessesByName('vmms'))
            try {
                if ($processes.Count -ne 1) { throw "Expected one running VMMS process; found $($processes.Count)." }
                return '{0}:{1}' -f $processes[0].Id, $processes[0].StartTime.ToUniversalTime().Ticks
            } finally {
                foreach ($process in $processes) { $process.Dispose() }
            }
        }
    }

    AfterAll {
        if ($script:NativeHyperVModule) {
            Remove-Module -ModuleInfo $script:NativeHyperVModule -Force -ErrorAction SilentlyContinue
        }
    }

    It 'gets a responsive provider result through the real bounded child' {
        $identityBefore = Get-NativeVmmsIdentity
        $deadline = New-YurunaDeadline -TotalMilliseconds 60000
        $result = Test-VirtualizationResponsive -Deadline $deadline -TimeoutSeconds 30
        $result.hostType | Should -Be 'host.windows.hyper-v'
        $result.state | Should -Be 'Responsive'
        $result.reason | Should -Be 'responsive'
        $result.started | Should -BeTrue
        $result.timedOut | Should -BeFalse
        $result.evidence.providerModule | Should -Be 'loaded'
        $result.evidence.serviceStatus | Should -Be 'Running'
        $result.evidence.exitCode | Should -Be 0
        $result.evidence.drainTimedOut | Should -BeFalse
        $result.evidence.outputTruncated | Should -BeFalse
        Get-NativeVmmsIdentity | Should -BeExactly $identityBefore
    }

    It 'reads VMMS through the real bounded service child' {
        $result = Get-HyperVServiceEvidence -TimeoutSeconds 15
        $result.Status | Should -Be 'Running'
        $result.StartType | Should -BeIn @('Automatic', 'Manual')
        $result.TimedOut | Should -BeFalse
    }

    It 'reports already-running without replacing VMMS when the start verb is previewed' {
        $identityBefore = Get-NativeVmmsIdentity
        $result = Start-VirtualizationServiceIfStopped -Deadline (New-YurunaDeadline -TotalMilliseconds 45000) -WhatIf -Confirm:$false
        $result.outcome | Should -Be 'already-running'
        $result.reason | Should -Be 'already-running'
        @($result.actions).Count | Should -Be 1
        $result.actions[0].before | Should -Be 'Running'
        $result.actions[0].after | Should -Be 'Running'
        $result.actions[0].result | Should -Be 'already-running'
        Get-NativeVmmsIdentity | Should -BeExactly $identityBefore
    }

    It 'refuses the probe after its actual monotonic deadline expires' {
        $deadline = New-YurunaDeadlineFromExpiry -ExpiryTick ([Environment]::TickCount64 - 1)
        $result = Test-VirtualizationResponsive -Deadline $deadline
        $result.reason | Should -Be 'deadline-exhausted'
        $result.deadlineExhausted | Should -BeTrue
        $result.started | Should -BeFalse
    }

    It 'refuses the start verb after its actual monotonic deadline expires' {
        $identityBefore = Get-NativeVmmsIdentity
        $deadline = New-YurunaDeadlineFromExpiry -ExpiryTick ([Environment]::TickCount64 - 1)
        $result = Start-VirtualizationServiceIfStopped -Deadline $deadline -WhatIf -Confirm:$false
        $result.outcome | Should -Be 'refused'
        $result.reason | Should -Be 'deadline-exhausted'
        @($result.actions).Count | Should -Be 0
        Get-NativeVmmsIdentity | Should -BeExactly $identityBefore
    }

    It 'imports the driver in a fresh NoProfile child and previews without replacing VMMS' {
        $identityBefore = Get-NativeVmmsIdentity
        $command = @'
$ErrorActionPreference = 'Stop'
Import-Module $env:YURUNA_TEST_HYPERV_DRIVER -Force -Global -DisableNameChecking
$result = Start-VirtualizationServiceIfStopped -Deadline (New-YurunaDeadline -TotalMilliseconds 45000) -WhatIf -Confirm:$false
'NATIVE-HYPERV-RESULT:' + ($result | ConvertTo-Json -Depth 8 -Compress)
'@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $native = Invoke-BoundedNativeCommand -FilePath $script:NativeHyperVPwsh `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
            -Environment @{ YURUNA_TEST_HYPERV_DRIVER = $script:NativeHyperVDriver } -TimeoutSeconds 75
        $native.Started | Should -BeTrue
        $native.TimedOut | Should -BeFalse
        $native.DrainTimedOut | Should -BeFalse
        $native.OutputTruncated | Should -BeFalse
        $native.ExitCode | Should -Be 0 -Because ([string]$native.StdErr)
        $lines = @(([string]$native.StdOut -split '\r?\n') | Where-Object { $_.StartsWith('NATIVE-HYPERV-RESULT:') })
        $lines.Count | Should -Be 1
        $result = $lines[0].Substring('NATIVE-HYPERV-RESULT:'.Length) | ConvertFrom-Json
        $result.outcome | Should -Be 'already-running'
        $result.hostType | Should -Be 'host.windows.hyper-v'
        @($result.actions).Count | Should -Be 1
        $result.actions[0].result | Should -Be 'already-running'
        Get-NativeVmmsIdentity | Should -BeExactly $identityBefore
    }
}
