<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d9d074-28e8-46bf-a0d7-68b45ee5ec8c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install upgrade configuration
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -Version 7

<#
.SYNOPSIS
    Exercise the standalone installer recovery snapshot against real files.
.DESCRIPTION
    The same embedded function runs without any checkout module. Its record
    fixture is written by the production critical-record writer, preserving
    the launch format used by installed public runners.
#>
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    Import-Module (Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1') -Force -DisableNameChecking
    $source = Get-Content (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -Raw
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
    $function = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-YurunaInstallerState'
    }, $true)
    if (-not $function) { throw 'Missing standalone installer state function' }
    $script:FunctionText = $function.Extent.Text
    . ([scriptblock]::Create($script:FunctionText))

    function New-InstallerStateFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates isolated files under Pester TestDrive.')]
        param([switch]$ExternalConfig, [switch]$CleanExit, [switch]$CustomRuntime)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $repo = Join-Path $root 'checkout'
        $runtime = if ($CustomRuntime) { Join-Path $root 'operator-runtime' } else { Join-Path $repo 'test/status/runtime' }
        $private = Join-Path $root 'private'
        $null = New-Item -ItemType Directory -Path $runtime, $private, (Join-Path $repo 'test') -Force
        $runner = Join-Path $repo 'test/Start-TestRunner.ps1'
        Copy-Item (Join-Path $script:RepoRoot 'test/Start-TestRunner.ps1') $runner
        $config = if ($ExternalConfig) { Join-Path $root 'operator.yml' } else { Join-Path $repo 'test/test.config.yml' }
        $content = "test:`n  projectUrl: file:///operator/project`n  gitSource:`n    mode: direct`n    verificationPublicKeys:`n      - operator-key`n"
        [IO.File]::WriteAllText($config, $content)
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($config, [IO.UnixFileMode]384) }
        $record = @{
            schemaVersion = 1; runnerProtocolVersion = 1; scriptPath = $runner
            repoRoot = $repo; runtimeDir = $runtime; workingDirectory = (Join-Path $repo 'test')
            runner = @{ pid = 999999; startTimeUnixMs = 1 }
            parameters = @{ ConfigPath = $config; NoGitPull = $true; NoStatusService = $true
                NoConfigGate = $false; CycleDelaySeconds = 73; logLevel = 'Debug' }
            explicitlyBound = @('ConfigPath', 'NoGitPull', 'CycleDelaySeconds')
            environment = @{ YURUNA_RUNTIME_DIR = $runtime; YURUNA_TEST_SECRET = 'private-value' }
            cleanExit = [bool]$CleanExit; endedUtc = $null
        }
        $keyPath = $runtime.TrimEnd('/', '\')
        if (-not $IsLinux) { $keyPath = $keyPath.ToLowerInvariant() }
        $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyPath))).ToLowerInvariant().Substring(0, 16)
        $recordPath = Join-Path $private "runner-launch.$key.record"
        $write = Write-YurunaCriticalRecord -Path $recordPath -Kind runner-launch -Payload $record -ExpectedGeneration 0 -Confirm:$false
        if (-not $write.Committed) { throw "Fixture record failed: $($write.Reason)" }
        return @{ Repo = $repo; Runtime = $runtime; Private = $private; Config = $config; Content = $content
            Snapshot = (Join-Path $root 'saved/state.json'); Record = $record; RecordPath = $recordPath }
    }
}

Describe 'Standalone installer recovery state' {
    It 'preserves selected config and frozen options across checkout replacement: external=<External>' -ForEach @(
        @{ External = $false }, @{ External = $true }
    ) {
        $f = New-InstallerStateFixture -ExternalConfig:$External
        $capture = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        $capture.launchRecord.parameters.CycleDelaySeconds | Should -Be 73
        $capture.launchRecord.environment.YURUNA_TEST_SECRET | Should -Be 'private-value'
        $capture.configPath | Should -Be $f.Config
        if (-not $External) { Remove-Item $f.Config }
        # Stopping the old process changes its record after capture. The frozen
        # state must keep the original options and clean-exit observation.
        $f.Record.parameters.CycleDelaySeconds = 999
        $f.Record.cleanExit = $true
        $null = Write-YurunaCriticalRecord -Path $f.RecordPath -Kind runner-launch -Payload $f.Record -ExpectedGeneration 1 -Confirm:$false
        $restored = Invoke-YurunaInstallerState -Action Restore -RepoRoot $f.Repo -SnapshotPath $f.Snapshot
        [IO.File]::ReadAllText($f.Config) | Should -BeExactly $f.Content
        $restored.launchRecord.parameters.CycleDelaySeconds | Should -Be 73
        $restored.launchRecord.cleanExit | Should -BeFalse
        if (-not $IsWindows) {
            ([int](Get-Item (Split-Path $f.Snapshot -Parent)).UnixFileMode -band 63) | Should -Be 0
            ([int](Get-Item $f.Config).UnixFileMode -band 63) | Should -Be 0
        }
    }

    It 'refuses changed config rather than replacing a concurrent operator edit' {
        $f = New-InstallerStateFixture -ExternalConfig
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        [IO.File]::WriteAllText($f.Config, 'operator changed this')
        { Invoke-YurunaInstallerState -Action Restore -RepoRoot $f.Repo -SnapshotPath $f.Snapshot } | Should -Throw '*changed*'
        [IO.File]::ReadAllText($f.Config) | Should -BeExactly 'operator changed this'
        Test-Path $f.Snapshot | Should -BeTrue
    }

    It 'discovers a selected external config in a recorded custom runtime' {
        $f = New-InstallerStateFixture -ExternalConfig -CustomRuntime
        $savedRuntime = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = $null
            $capture = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
            $capture.configPath | Should -BeExactly $f.Config
            $capture.launchRecord.runtimeDir | Should -BeExactly $f.Runtime
        } finally { $env:YURUNA_RUNTIME_DIR = $savedRuntime }
    }

    It 'allows reading frozen options after setup deliberately enrolls a new key' {
        $f = New-InstallerStateFixture
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        $null = Invoke-YurunaInstallerState -Action Restore -RepoRoot $f.Repo -SnapshotPath $f.Snapshot
        [IO.File]::AppendAllText($f.Config, "      - newly-enrolled-key`n")
        $saved = Invoke-YurunaInstallerState -Action Read -RepoRoot $f.Repo -SnapshotPath $f.Snapshot
        $saved.launchRecord.parameters.ConfigPath | Should -BeExactly $f.Config
        [IO.File]::ReadAllText($f.Config) | Should -Match 'newly-enrolled-key'
    }

    It 'refuses corrupt launch evidence before creating a snapshot' {
        $f = New-InstallerStateFixture
        [IO.File]::WriteAllText($f.RecordPath, 'damaged')
        { Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot } | Should -Throw
        Test-Path $f.Snapshot | Should -BeFalse
    }

    It 'refuses an incompatible candidate option before restoring config' {
        $f = New-InstallerStateFixture
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        Remove-Item $f.Config
        [IO.File]::WriteAllText((Join-Path $f.Repo 'test/Start-TestRunner.ps1'), 'param([string]$ConfigPath)')
        { Invoke-YurunaInstallerState -Action Restore -RepoRoot $f.Repo -SnapshotPath $f.Snapshot } | Should -Throw '*NoGitPull*'
        Test-Path $f.Config | Should -BeFalse
    }

    It 'rejects altered snapshot config bytes' {
        $f = New-InstallerStateFixture
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        $saved = Get-Content $f.Snapshot -Raw | ConvertFrom-Json -AsHashtable
        $saved.configurations[0].bytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('bad'))
        $saved | ConvertTo-Json -Depth 30 | Set-Content $f.Snapshot
        Remove-Item $f.Config
        { Invoke-YurunaInstallerState -Action Restore -RepoRoot $f.Repo -SnapshotPath $f.Snapshot } | Should -Throw '*hash*'
        Test-Path $f.Config | Should -BeFalse
    }

    It 'captures a stopped runner without changing the original cleanExit flag: <Clean>' -ForEach @(
        @{ Clean = $false }, @{ Clean = $true }
    ) {
        $f = New-InstallerStateFixture -CleanExit:$Clean
        $capture = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        $capture.launchRecord.cleanExit | Should -Be $Clean
        $raw = Read-YurunaCriticalRecord -Path $f.RecordPath -Kind runner-launch
        $raw.Payload.cleanExit | Should -Be $Clean
        $raw.Generation | Should -Be 1
    }

    It 'keeps the complete function identical in each single-file installer' {
        foreach ($path in @('install/windows.hyper-v.ps1', 'install/ubuntu.kvm.sh', 'install/macos.utm.sh')) {
            $text = Get-Content (Join-Path $script:RepoRoot $path) -Raw
            $text.Contains($script:FunctionText) | Should -BeTrue -Because "$path must retain its standalone recovery implementation"
        }
    }

    It 'captures before process stop and restores before config seeding in all installers' {
        foreach ($path in @('install/ubuntu.kvm.sh', 'install/macos.utm.sh')) {
            $text = Get-Content (Join-Path $script:RepoRoot $path) -Raw
            $text.IndexOf("`ncapture_installer_state`n") | Should -BeLessThan $text.IndexOf("`nstop_yuruna_processes`n")
            $text.IndexOf("`nrestore_installer_state`n") | Should -BeLessThan $text.IndexOf('# --- REGION: Seed test.config.yml')
        }
        $text = Get-Content (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $text.IndexOf('$capturedInstallerState = Invoke-YurunaInstallerState') | Should -BeLessThan $text.IndexOf("`nStop-YurunaProcess -YurunaDir")
        $text.IndexOf('$null = Invoke-YurunaInstallerState -Action Restore') | Should -BeLessThan $text.IndexOf('# --- REGION: Seed test.config.yml')
    }
}

Describe 'Explicit start from captured installer state' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -Force -DisableNameChecking
    }

    It 'refuses an existing runner without launching a replacement' {
        $f = New-InstallerStateFixture
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        Mock Get-RunnerInstanceState { @{ status = 'OtherRunner'; pid = 42 } } -ModuleName Test.SingleInstance
        Mock Start-YurunaDetachedProcess { throw 'must not launch' } -ModuleName Test.SingleInstance
        { Start-YurunaCapturedRunner -RepoRoot $f.Repo -SnapshotPath $f.Snapshot -Confirm:$false } | Should -Throw '*already owns*'
        Should -Invoke Start-YurunaDetachedProcess -ModuleName Test.SingleInstance -Times 0 -Exactly
    }

    It 'starts a new process with recorded values for cleanExit=<Clean>' -ForEach @(
        @{ Clean = $false }, @{ Clean = $true }
    ) {
        $f = New-InstallerStateFixture -CleanExit:$Clean
        $modulePath = (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1').Replace("'", "''")
        $privatePath = $f.Private.Replace("'", "''")
        $runner = Join-Path $f.Repo 'test/Start-TestRunner.ps1'
        $child = @'
param([string]$ConfigPath, [switch]$NoGitPull, [switch]$NoStatusService, [switch]$NoConfigGate,
    [ValidateRange(0, 3600)][int]$CycleDelaySeconds = 10, [string]$logLevel)
$ErrorActionPreference = 'Stop'
Import-Module '__MODULE__' -DisableNameChecking
$runtime = $env:YURUNA_RUNTIME_DIR
$process = Get-Process -Id $PID
[IO.File]::WriteAllText((Join-Path $runtime 'runner.start'), $process.StartTime.ToUniversalTime().ToString('o'))
[IO.File]::WriteAllText((Join-Path $runtime 'runner.pid'), [string]$PID)
$forward = @{ YURUNA_RUNTIME_DIR = $runtime; YURUNA_TEST_SECRET = $env:YURUNA_TEST_SECRET }
$write = Write-YurunaRunnerLaunchRecord -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters `
    -ResolvedConfigPath $ConfigPath -RuntimeDir $runtime -RepoRoot (Split-Path $PSScriptRoot -Parent) `
    -WorkingDirectory (Get-Location).Path -ForwardEnvironment $forward -AllowedEnvironmentName @($forward.Keys) `
    -PrivateRoot '__PRIVATE__' -Confirm:$false
if (-not $write.Written) { throw $write.Reason }
Start-Sleep -Seconds 20
'@
        [IO.File]::WriteAllText($runner, $child.Replace('__MODULE__', $modulePath).Replace('__PRIVATE__', $privatePath))
        $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $f.Repo -RuntimeDir $f.Runtime -PrivateRoot $f.Private -SnapshotPath $f.Snapshot
        # This fixture starts a harmless console worker, so no GUI capability
        # is required even on a macOS test worker reached over SSH.
        Mock Get-YurunaIdentityPlatform { 'Linux' } -ModuleName Test.SingleInstance
        try {
            $started = Start-YurunaCapturedRunner -RepoRoot $f.Repo -SnapshotPath $f.Snapshot -TimeoutSeconds 15 -Confirm:$false
            $started.Started | Should -BeTrue
            $started.Pid | Should -Not -Be $f.Record.runner.pid
            $started.StartTimeUnixMs | Should -BeGreaterThan $f.Record.runner.startTimeUnixMs
            $record = Read-YurunaRunnerLaunchRecord -RuntimeDir $f.Runtime -PrivateRoot $f.Private
            $record.Valid | Should -BeTrue
            $record.Record.parameters.ConfigPath | Should -BeExactly $f.Config
            $record.Record.parameters.CycleDelaySeconds | Should -Be 73
            $record.Record.parameters.NoGitPull | Should -BeTrue
            $record.Record.parameters.NoStatusService | Should -BeTrue
            $record.Record.parameters.NoConfigGate | Should -BeFalse
            $record.Record.environment.YURUNA_TEST_SECRET | Should -Be 'private-value'
            $saved = Invoke-YurunaInstallerState -Action Read -RepoRoot $f.Repo -SnapshotPath $f.Snapshot
            $saved.launchRecord.cleanExit | Should -Be $Clean
        } finally {
            $pidFile = Join-Path $f.Runtime 'runner.pid'
            if (Test-Path $pidFile) {
                $fixturePid = [int][IO.File]::ReadAllText($pidFile)
                Stop-Process -Id $fixturePid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
