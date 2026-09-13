<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42e44773-6606-4bbd-98b8-3b7ebd390f80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host metrics sync pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Verify live-monitor transaction rollback and preview without contacting a host.
#>
BeforeAll {
    $script:Python = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $script:Python) { $script:Python = Get-Command python -ErrorAction SilentlyContinue }
    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Force
}
Describe 'existing monitor update boundaries' {
    It 'validates atomic replacement, idempotence, and rollback against temporary configurations' {
        if (-not $script:Python) { Set-ItResult -Skipped -Because 'Python 3 is unavailable on this developer host.'; return }
        $result=Invoke-YurunaHostBoundedCommand -FilePath $script:Python.Source -ArgumentList @((Join-Path $PSScriptRoot '../pool/test_sync_host_metrics.py'),'-v') -TimeoutSeconds 20
        $result.Status | Should -Be 'complete'
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'Ran 5 tests'
    }
    It 'previews an explicit proxy without SSH or remote changes' {
        $result=Invoke-YurunaHostBoundedCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot '../pool/Sync-PoolHostMetricsOnProxy.ps1'),'-ProxyAddress','192.0.2.1','-WhatIf') -TimeoutSeconds 20
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'What if:.*pool-host Prometheus metric filter'
    }
}
