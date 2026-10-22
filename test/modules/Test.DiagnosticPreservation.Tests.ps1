<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42f4d2ce-8bea-4df2-9273-6b149f08d814
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic preservation runner pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.EXTERNALMODULEDEPENDENCIES Pester
#>

#requires -version 7

BeforeAll {
    $script:PreviousRuntime = $env:YURUNA_RUNTIME_DIR
    Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.DiagnosticPreservation.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking
    $script:PreservationModule = Get-Module Test.DiagnosticPreservation -All | Select-Object -First 1
    function Get-PreservationLoopState {
        return @{
            RepoRoot='fixture'; ConfigPath=(Join-Path $TestDrive 'config.yml'); InnerScript='fixture'; PwshExe='pwsh'; ArgList=@()
            ForwardEnvSnapshot=@{}; ShutdownState=@{Requested=$false}; NoGitPull=$true
            FailurePauseMaxSeconds=1; FailureCommitPollSeconds=1; OuterPullErrorSleepSeconds=1
            InnerSpawnErrorSleepSeconds=1; StepTimeoutSecondsDefault=1; WatchdogPollSeconds=1
        }
    }
}

AfterAll {
    $env:YURUNA_RUNTIME_DIR = $script:PreviousRuntime
    & $script:PreservationModule { Remove-Variable PreservationTestShutdown -Scope Script -ErrorAction SilentlyContinue }
}

Describe 'Durable stopOnFailure preservation marker' {
    BeforeEach {
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR
}


    It 'records only inspection metadata, with an atomic completed marker' {
        Set-DiagnosticVmPreservation -VMName test-vm -GuestKey guest.ubuntu.server.26 -StepName Start-GuestWorkload -Confirm:$false | Should -BeTrue
        $record = Get-DiagnosticVmPreservation
        $record.schemaVersion | Should -Be 1
        $record.vmName | Should -Be 'test-vm'
        $record.reason | Should -Be 'stopOnFailure'
        $record.createdUtc | Should -Not -BeNullOrEmpty
        $record.ContainsKey('errorMessage') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $env:YURUNA_RUNTIME_DIR -Filter '*.tmp').Count | Should -Be 0
    }

    It 'rejects a directory or symbolic link marker before reading its content' -Skip:$IsWindows {
        $marker = Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json'
        $null = New-Item -ItemType Directory -Path $marker
        (Get-DiagnosticVmPreservation).state | Should -Be 'invalid'
        Remove-Item -LiteralPath $marker
        $target = Join-Path $env:YURUNA_RUNTIME_DIR 'target.json'
        Set-Content -LiteralPath $target -Value '{"schemaVersion":1,"vmName":"linked-vm"}'
        $null = New-Item -ItemType SymbolicLink -Path $marker -Target $target
        (Get-DiagnosticVmPreservation).state | Should -Be 'invalid'
    }

    It 'rejects a FIFO marker without blocking a read' -Skip:(-not $IsLinux) {
        $marker = Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json'
        & mkfifo $marker
        $LASTEXITCODE | Should -Be 0
        $driver = Join-Path $env:YURUNA_RUNTIME_DIR 'fifo-probe.ps1'
        $modulePath = Join-Path $PSScriptRoot 'Test.DiagnosticPreservation.psm1'
        Set-Content -LiteralPath $driver -Value "Import-Module '$modulePath'; (Get-DiagnosticVmPreservation -RuntimeDir '$env:YURUNA_RUNTIME_DIR').state"
        Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-File', $driver) -TimeoutSeconds 3
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut.Trim() | Should -Be 'invalid'
    }

    It 'honors WhatIf without creating the hold' {
        Set-DiagnosticVmPreservation -VMName test-vm -WhatIf | Should -BeFalse
        Get-DiagnosticVmPreservation | Should -BeNullOrEmpty
    }

    It 'treats an unreadable or malformed marker as held evidence' {
        Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json') -Value '{broken'
        (Get-DiagnosticVmPreservation).state | Should -Be 'invalid'
        $shutdown = @{Requested=$false}
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation { $shutdown['Requested']=$true }
        Wait-DiagnosticVmPreservation -ShutdownState $shutdown | Should -Be 'shutdown'
        Test-Path -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json') | Should -BeTrue
    }

    It 'releases only an explicit Boolean false, retaining missing, invalid, or string configuration' -ForEach @(
        @{Yaml="testCycle:`n  stopOnFailure: false`n"; Released=$true},
        @{Yaml="testCycle:`n  stopOnFailure: true`n"; Released=$false},
        @{Yaml="testCycle:`n  stopOnFailure: 'false'`n"; Released=$false},
        @{Yaml="testCycle: {}`n"; Released=$false},
        @{Yaml="testCycle: [`n"; Released=$false}
    ) {
        $null = Set-DiagnosticVmPreservation -VMName test-vm -Confirm:$false
        $configPath = Join-Path $env:YURUNA_RUNTIME_DIR 'config.yml'
        Set-Content -LiteralPath $configPath -Value $Yaml
        $shutdown = @{Requested=$false}
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation { $shutdown['Requested']=$true }
        $result = Wait-DiagnosticVmPreservation -ShutdownState $shutdown -ConfigPath $configPath
        $result | Should -Be ($Released ? 'released' : 'shutdown')
        Test-Path -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json') | Should -Be (-not $Released)
    }

    It 'recreates a missing marker after a failed cycle when stopOnFailure was explicitly enabled' {
        $configPath = Join-Path $env:YURUNA_RUNTIME_DIR 'config.yml'
        Set-Content -LiteralPath $configPath -Value "testCycle:`n  stopOnFailure: true`n"
        $shutdown = @{Requested=$false}
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation { $shutdown['Requested']=$true }
        Wait-DiagnosticVmPreservation -ShutdownState $shutdown -ConfigPath $configPath -HoldOnFailure | Should -Be 'shutdown'
        (Get-DiagnosticVmPreservation).vmName | Should -Be '(unknown)'
    }

    It 'stops the runner if an enabled failure hold cannot be persisted' {
        $configPath = Join-Path $env:YURUNA_RUNTIME_DIR 'config.yml'
        Set-Content -LiteralPath $configPath -Value "testCycle:`n  stopOnFailure: true`n"
        $shutdown = @{Requested=$false}
        Mock Set-DiagnosticVmPreservation -ModuleName Test.DiagnosticPreservation { return $false }
        Wait-DiagnosticVmPreservation -ShutdownState $shutdown -ConfigPath $configPath -HoldOnFailure | Should -Be 'shutdown'
        $shutdown.Requested | Should -BeTrue
    }

    It 'keeps default failure cleanup available when stopOnFailure is false' {
        $configPath = Join-Path $env:YURUNA_RUNTIME_DIR 'config.yml'
        Set-Content -LiteralPath $configPath -Value "testCycle:`n  stopOnFailure: false`n"
        Wait-DiagnosticVmPreservation -ShutdownState @{Requested=$false} -ConfigPath $configPath -HoldOnFailure | Should -Be 'absent'
        Get-DiagnosticVmPreservation | Should -BeNullOrEmpty
    }

    It 'uses valid real runner state transitions when holding and releasing an in-cycle failure' {
        $configPath = Join-Path $env:YURUNA_RUNTIME_DIR 'config.yml'
        Set-Content -LiteralPath $configPath -Value "testCycle:`n  stopOnFailure: false`n"
        $driver = Join-Path $env:YURUNA_RUNTIME_DIR 'state-probe.ps1'
        $body = @'
$ErrorActionPreference='Stop'
$env:YURUNA_RUNTIME_DIR='__RUNTIME__'
Import-Module '__MODULES__/Test.Config.psm1' -Global -DisableNameChecking
Import-Module '__MODULES__/Test.RunnerState.psm1' -Global -DisableNameChecking
Import-Module '__MODULES__/Test.DiagnosticPreservation.psm1' -DisableNameChecking
$null=Initialize-RunnerState -Confirm:$false
$null=Set-RunnerState -To cycle-start -Confirm:$false
$null=Set-RunnerState -To in-cycle -Confirm:$false
$null=Set-DiagnosticVmPreservation -VMName fixture-vm -Confirm:$false
$result=Wait-DiagnosticVmPreservation -ShutdownState @{Requested=$false} -ConfigPath '__CONFIG__'
$state=Get-RunnerState
foreach($transition in $state.history) {
    if(-not(Test-RunnerStateTransition -From $transition.from -To $transition.to)) { throw "Invalid transition $($transition.from)->$($transition.to)" }
}
[ordered]@{result=$result; current=$state.current; path=@($state.history | ForEach-Object { $_.to })} | ConvertTo-Json -Compress
'@
        Set-Content -LiteralPath $driver -Value $body.Replace('__RUNTIME__', $env:YURUNA_RUNTIME_DIR).Replace('__MODULES__', $PSScriptRoot).Replace('__CONFIG__', $configPath)
        Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-File', $driver) -TimeoutSeconds 8
        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $state = $result.StdOut | ConvertFrom-Json
        $state.result | Should -Be 'released'
        $state.current | Should -Be 'idle'
        $state.path[-3..-1] -join ',' | Should -Be 'fault,paused,idle'
    }

    It 'honors operator marker removal without waiting for a commit or retry timeout' {
        $null = Set-DiagnosticVmPreservation -VMName test-vm -Confirm:$false
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation {
            Remove-Item -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json')
        }
        Wait-DiagnosticVmPreservation -ShutdownState @{Requested=$false} | Should -Be 'released'
    }
}

Describe 'Outer runner preservation gates precede destructive automation' {
    BeforeEach {
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR
}


    It 'parks before the first dispatch when preserved evidence survived a runner restart' {
        $null = Set-DiagnosticVmPreservation -VMName test-vm -Confirm:$false
        $state = Get-PreservationLoopState
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation { $state.ShutdownState['Requested']=$true }
        Mock Invoke-OuterCycleDispatch -ModuleName Test.RunnerOuterLoop { throw 'A preserved VM must not reach a new cycle.' }
        Invoke-RunnerOuterLoop -State $state
        Should -Invoke Invoke-OuterCycleDispatch -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'diagnostic-preserve.json') | Should -BeTrue
    }

    It 'parks immediately after a failed dispatch before refresh or recovery can run' {
        $state = Get-PreservationLoopState
        Mock Start-Sleep -ModuleName Test.DiagnosticPreservation { $state.ShutdownState['Requested']=$true }
        Mock Invoke-OuterCycleDispatch -ModuleName Test.RunnerOuterLoop {
            $null = Set-DiagnosticVmPreservation -VMName test-vm -Confirm:$false
            return @{Outcome='completed'; ExitCode=1}
        }
        Mock Publish-OuterRecoveryResult -ModuleName Test.RunnerOuterLoop { return $null }
        Mock Import-OuterRefreshTriggerModule -ModuleName Test.RunnerOuterLoop { throw 'Automatic refresh must not run during preservation.' }
        Mock Invoke-OuterRecovery -ModuleName Test.RunnerOuterLoop { throw 'Recovery must not run during preservation.' }
        Invoke-RunnerOuterLoop -State $state
        Should -Invoke Invoke-OuterCycleDispatch -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly
        Should -Invoke Import-OuterRefreshTriggerModule -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly
        Should -Invoke Invoke-OuterRecovery -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly
    }
}
