<#PSScriptInfo
.VERSION 2026.09.27
.GUID 429bfeab-669e-4cbb-ba50-b031e884727c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner boot-recovery host-refresh pester
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
    The boot sweep of a runner restarted by a host refresh keeps what the
    operator left and removes only what it proves stale.
.DESCRIPTION
    Every case builds a private runtime and log directory and uses disposable
    stand-in processes for the live and dead identities. The default sweep is
    exercised on the same fixture shape so the refresh mode is compared with
    the behavior it must not change.
#>

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $script:Here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:Here 'Test.Recovery.psm1') -Force -DisableNameChecking
    $script:Controls = @('control.step-pause', 'control.cycle-pause', 'control.pause', 'control.lab-hold', 'lab-hold.json',
        'control.lab-hold-release', 'control.cycle-restart')
    $script:Live = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()

    function New-Fixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds throwaway runtime and log directories.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param()
        $root = New-YurunaTestTempDir -Prefix 'yrn-refresh-boot'
        $runtime = Join-Path $root 'runtime'
        $log = Join-Path $root 'log'
        $null = New-Item -ItemType Directory -Path $runtime, $log -Force
        foreach ($name in $script:Controls) { Set-Content -LiteralPath (Join-Path $runtime $name) -Value 'x' -Encoding utf8NoBOM }
        return @{ Root = $root; Runtime = $runtime; Log = $log }
    }

    function Get-DeadPid {
        [CmdletBinding()]
        [OutputType([int])]
        param()
        $p = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru
        $p.WaitForExit()
        return $p.Id
    }

    function Start-LiveProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a disposable stand-in the suite kills in AfterAll.')]
        [CmdletBinding()]
        [OutputType([System.Diagnostics.Process])]
        param()
        $p = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -PassThru
        $script:Live.Add($p)
        Start-Sleep -Milliseconds 300
        return $p
    }

    function Get-StartIso {
        [CmdletBinding()]
        [OutputType([string])]
        param([int]$ProcessId)
        return (Get-Process -Id $ProcessId).StartTime.ToUniversalTime().ToString('o')
    }

    function New-CycleFolder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: a crashed-cycle folder under the fixture log directory.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Log, [string]$Number, $MarkerPid, [switch]$NoMarker)
        $folder = Join-Path $Log "$Number.2026-09-25.10-00-00.4287d16ff2c346a98ea90fd3a0c307da.incomplete"
        $null = New-Item -ItemType Directory -Path $folder -Force
        if (-not $NoMarker) {
            $marker = [ordered]@{ cycleStartUtc = '2026-09-25T10:00:00Z'; startedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
            if ($null -ne $MarkerPid) { $marker.pid = $MarkerPid }
            Set-Content -LiteralPath (Join-Path $folder '.incomplete') -Value ($marker | ConvertTo-Json) -Encoding utf8NoBOM
        }
        return $folder
    }
}

AfterAll {
    foreach ($p in @($script:Live)) { try { if (-not $p.HasExited) { $p.Kill() } } catch { $null = $_ } }
}

Describe 'Invoke-YurunaBootRecovery -RefreshPreservation' {
    It 'keeps every operator control and reports them' {
        $f = New-Fixture
        try {
            $s = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -Confirm:$false 6>$null
            foreach ($name in $script:Controls) {
                Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$name survives"
            }
            Assert-Equal -Expected 'refresh-preservation' -Actual $s.Mode
            Assert-Equal -Expected ($script:Controls -join ',') -Actual (@($s.PreservedControls) -join ',')
            Assert-Equal -Expected 0 -Actual @($s.ClearedPauseFlags).Count
        } finally { Remove-YurunaTestTempDir $f.Root }
    }

    It 'removes only a dead inner.pid generation, keeps an unproven one, and never touches runner or service pidfiles' {
        $f = New-Fixture
        try {
            $dead = Get-DeadPid
            foreach ($name in @('runner.pid', 'server.pid', 'config-server.pid')) {
                Set-Content -LiteralPath (Join-Path $f.Runtime $name) -Value "$dead" -Encoding utf8NoBOM
            }
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.pid') -Value 'not-a-pid' -Encoding utf8NoBOM
            $kept = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -Confirm:$false 6>$null
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.pid')) 'a malformed inner.pid is never deleted'
            Assert-True (@($kept.PreservedPidFiles | Where-Object { $_.file -eq 'inner.pid' -and $_.state -eq 'Unknown' }).Count -eq 1) 'reported as Unknown'
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.pid') -Value "$dead" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.start') -Value '2026-01-01T00:00:00.0000000Z' -Encoding utf8NoBOM
            $s = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -Confirm:$false 6>$null
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.pid')) 'the dead generation is removed'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.start')) 'with its start record'
            Assert-Equal -Expected 'inner.pid' -Actual @($s.ClearedPidFiles)[0].pidFile
            foreach ($name in @('runner.pid', 'server.pid', 'config-server.pid')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$name is untouched even though its PID is dead"
            }
            Assert-Equal -Expected 'deferred' -Actual @($s.PreservedPidFiles | Where-Object file -eq 'runner.pid')[0].state
        } finally { Remove-YurunaTestTempDir $f.Root }
    }

    It 'archives break-active.json only for a dead reclaimed inner with no live inner in its place' {
        $f = New-Fixture
        try {
            $breakFile = Join-Path $f.Runtime 'break-active.json'
            Set-Content -LiteralPath $breakFile -Value '{}' -Encoding utf8NoBOM
            $null = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -Confirm:$false 6>$null
            Assert-True (Test-Path -LiteralPath $breakFile) 'kept without a reclaimed inner'
            $live = Start-LiveProcess
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.pid') -Value "$($live.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.start') -Value (Get-StartIso -ProcessId $live.Id) -Encoding utf8NoBOM
            $reclaimed = @{ pid = (Get-DeadPid); startTimeUnixMs = [long]1000 }
            $null = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -ReclaimedInner $reclaimed -Confirm:$false 6>$null
            Assert-True (Test-Path -LiteralPath $breakFile) 'kept while a live inner owns the runtime'
            Remove-Item -LiteralPath (Join-Path $f.Runtime 'inner.pid'), (Join-Path $f.Runtime 'inner.start') -Force
            $s = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -ReclaimedInner $reclaimed -Confirm:$false 6>$null
            Assert-False (Test-Path -LiteralPath $breakFile) 'archived for the dead reclaimed inner'
            Assert-Match -Pattern '^break-active\..+\.json\.aborted$' -Actual $s.ArchivedBreakActive.archivedAs
        } finally { Remove-YurunaTestTempDir $f.Root }
    }

    It 'archives an orphaned cycle only when its writer is proven gone' {
        $f = New-Fixture
        try {
            $liveFolder = New-CycleFolder -Log $f.Log -Number '000101' -MarkerPid $PID
            $deadFolder = New-CycleFolder -Log $f.Log -Number '000102' -MarkerPid (Get-DeadPid)
            $noPid = New-CycleFolder -Log $f.Log -Number '000103' -MarkerPid $null
            $suffixOnly = New-CycleFolder -Log $f.Log -Number '000104' -NoMarker
            $s = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -Confirm:$false 6>$null
            Assert-True (Test-Path -LiteralPath $liveFolder) 'a marker whose writer may still run is kept'
            Assert-False (Test-Path -LiteralPath $deadFolder) 'the dead writer''s folder was archived'
            Assert-True (Test-Path -LiteralPath $noPid) 'a marker without a PID proves nothing'
            Assert-True (Test-Path -LiteralPath $suffixOnly) 'a suffix-only folder proves nothing'
            Assert-Equal -Expected 1 -Actual @($s.ArchivedCycles).Count
            Assert-Equal -Expected 3 -Actual @($s.PreservedOrphans).Count
        } finally { Remove-YurunaTestTempDir $f.Root }
    }

    It 'changes nothing under -WhatIf' {
        $f = New-Fixture
        try {
            Set-Content -LiteralPath (Join-Path $f.Runtime 'inner.pid') -Value "$(Get-DeadPid)" -Encoding utf8NoBOM
            $before = @(Get-ChildItem -LiteralPath $f.Runtime -Force | ForEach-Object Name | Sort-Object)
            $null = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -RefreshPreservation -WhatIf
            Assert-Equal -Expected ($before -join ',') -Actual (@(Get-ChildItem -LiteralPath $f.Runtime -Force | ForEach-Object Name | Sort-Object) -join ',')
        } finally { Remove-YurunaTestTempDir $f.Root }
    }
}

Describe 'Default boot recovery is unchanged' {
    It 'still clears pause flags, dead pidfiles and a stale break marker, and archives orphans' {
        $f = New-Fixture
        try {
            $dead = Get-DeadPid
            foreach ($name in @('inner.pid', 'runner.pid')) { Set-Content -LiteralPath (Join-Path $f.Runtime $name) -Value "$dead" -Encoding utf8NoBOM }
            Set-Content -LiteralPath (Join-Path $f.Runtime 'break-active.json') -Value '{}' -Encoding utf8NoBOM
            $null = New-CycleFolder -Log $f.Log -Number '000201' -MarkerPid $PID
            $s = Invoke-YurunaBootRecovery -RuntimeDir $f.Runtime -LogDir $f.Log -Confirm:$false 6>$null
            $left = @(Get-ChildItem -LiteralPath $f.Runtime -Force | ForEach-Object Name | Where-Object { $_ -notlike 'break-active.*.json.aborted' } | Sort-Object)
            Assert-Equal -Expected 'control.cycle-restart' -Actual ($left -join ',') -Because 'the default sweep removes pauses, holds, dead pidfiles and the break marker; the restart request is for the inner'
            Assert-Equal -Expected 'default' -Actual $s.Mode
            Assert-Equal -Expected 1 -Actual @($s.ArchivedCycles).Count -Because 'the default sweep archives an orphan without an ownership check'
            Assert-Equal -Expected 0 -Actual (@($s.PreservedControls).Count + @($s.PreservedPidFiles).Count + @($s.PreservedOrphans).Count)
        } finally { Remove-YurunaTestTempDir $f.Root }
    }
}

Describe 'Clear-StaleControlState -RefreshPreservation' {
    It 'consumes nothing in either scope, and the default Startup scope still consumes the restart request' {
        $f = New-Fixture
        try {
            foreach ($scope in @('Startup', 'PreSpawn')) {
                $s = Clear-StaleControlState -Scope $scope -RuntimeDir $f.Runtime -RefreshPreservation -Confirm:$false
                Assert-False $s.cycleRestartCleared "$scope keeps control.cycle-restart"
                Assert-True (@($s.preserved) -contains 'control.cycle-restart') 'reported as preserved'
                foreach ($name in $script:Controls) {
                    Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$scope keeps $name"
                }
            }
            $default = Clear-StaleControlState -Scope Startup -SkipInteractiveState -RuntimeDir $f.Runtime -Confirm:$false
            Assert-True $default.cycleRestartCleared 'the default inner startup consumes the restart request'
        } finally { Remove-YurunaTestTempDir $f.Root }
    }
}
