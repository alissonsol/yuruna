<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d5c8e4-fc67-48d0-a8eb-71baa6f478be
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test private-state startup permissions pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
    $script:ModulePath = Join-Path $PSScriptRoot 'Test.PrivateStateRepair.psm1'
    Import-Module $script:ModulePath -Force -DisableNameChecking

    function New-RootAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns only a mock response record.')]
        param([string]$Reason = 'owner-mismatch', [string]$HomeVerified = 'verified')
        [pscustomobject]@{ Resolved = ($Reason -eq 'ok'); Reason = $Reason; HomeVerified = $HomeVerified; Path = (Join-Path $TestDrive 'account/.yuruna/host-refresh') }
    }

    function New-NativeAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns only a mock response record.')]
        param([int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '')
        @{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr; TimedOut = $false; Started = $true
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 1; DeadlineExhausted = $false; ProcessId = 1 }
    }

    function Set-RootAnswer {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only the mock response queue.')]
        param([string[]]$Reason)
        $script:RootAnswers.Clear()
        foreach ($value in $Reason) { $script:RootAnswers.Enqueue((New-RootAnswer -Reason $value)) }
    }
}

AfterAll {
    Remove-Module Test.PrivateStateRepair -ErrorAction SilentlyContinue
}

Describe 'Startup private-state permission recovery' {
    BeforeEach {
        InModuleScope Test.PrivateStateRepair {
            Set-Variable -Name IsWindows -Value $false -Scope Script
            Set-Variable -Name IsMacOS -Value $false -Scope Script
        }
        $script:RootAnswers = [Collections.Generic.Queue[object]]::new()
        Set-RootAnswer -Reason @('owner-mismatch', 'owner-mismatch', 'ok')
        $script:NativeAnswers = [Collections.Generic.Queue[object]]::new()
        $script:NativeAnswers.Enqueue((New-NativeAnswer))
        $script:FixtureHome = Join-Path $TestDrive 'account'
        $script:PythonPath = Join-Path $TestDrive 'python3'
        $script:SudoPath = Join-Path $TestDrive 'sudo'
        $roots = $script:RootAnswers
        $native = $script:NativeAnswers
        $fixtureHome = $script:FixtureHome
        $python = $script:PythonPath
        $sudo = $script:SudoPath
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot {
            if ($roots.Count -eq 0) { throw 'unexpected resolver call' }
            $roots.Dequeue()
        }.GetNewClosure()
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaCurrentOwnerId {
            [pscustomobject]@{ Resolved = $true; OwnerId = '1001'; PrimaryGroupId = '1002'; IsRoot = $false }
        }
        Mock -ModuleName Test.PrivateStateRepair Resolve-YurunaCanonicalPath {
            param($Path)
            [pscustomobject]@{ Resolved = $true; Path = $(if ($Path -eq $HOME) { $fixtureHome } else { $Path }) }
        }.GetNewClosure()
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaPathDriveInfo {
            [pscustomobject]@{ Resolved = $true; DriveType = 'Fixed'; FileSystem = 'ext4' }
        }
        Mock -ModuleName Test.PrivateStateRepair Get-Command { [pscustomobject]@{ Source = $python } }.GetNewClosure() -ParameterFilter { $Name -eq 'python3' }
        Mock -ModuleName Test.PrivateStateRepair Get-Command { [pscustomobject]@{ Source = $sudo } }.GetNewClosure() -ParameterFilter { $Name -eq 'sudo' }
        Mock -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand {
            if ($native.Count -eq 0) { throw 'unexpected native invocation' }
            $native.Dequeue()
        }.GetNewClosure()
        Mock -ModuleName Test.PrivateStateRepair Test-YurunaCanPrompt { $true }
        Mock -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation { $true }
        Mock -ModuleName Test.PrivateStateRepair Test-YurunaStartupLockAccess { $false }
    }

    It 'leaves a healthy root alone without running commands or requesting credentials' {
        Set-RootAnswer -Reason 'ok'
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.Reason | Should -Be 'ok'
        $result.RepairAttempted | Should -Be $false
        $result.Privileged | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { $NoCreate -and $VerifyHome }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 0 -Exactly
    }

    It 'uses the ordinary resolver to create or secure a user-owned root without elevation' -ForEach @('absent', 'permission-loose') {
        Set-RootAnswer -Reason @($_, 'ok')
        $result = Repair-YurunaStartupPrivateState -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.OriginalReason | Should -Be $_
        $result.RepairAttempted | Should -Be $true
        $result.Privileged | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { -not $NoCreate -and $VerifyHome }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'keeps a healthy root and readable locks unchanged during an outer startup scan' {
        Set-RootAnswer -Reason 'ok'
        Mock -ModuleName Test.PrivateStateRepair Test-YurunaStartupLockAccess { $true }
        $result = Repair-YurunaStartupPrivateState -RepairFileAccess -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.RepairAttempted | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { $NoCreate }
        Should -Invoke -ModuleName Test.PrivateStateRepair Test-YurunaStartupLockAccess -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'creates an absent root and accepts its empty lock directory without requiring Python' {
        Set-RootAnswer -Reason @('absent', 'ok')
        Mock -ModuleName Test.PrivateStateRepair Test-YurunaStartupLockAccess { $true }
        $result = Repair-YurunaStartupPrivateState -RepairFileAccess -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.Reason | Should -Be 'ok'
        $result.OriginalReason | Should -Be 'absent'
        $result.RepairAttempted | Should -Be $true
        $result.Privileged | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 2 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { $NoCreate -and $VerifyHome }
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { -not $NoCreate -and $VerifyHome }
        Should -Invoke -ModuleName Test.PrivateStateRepair Test-YurunaStartupLockAccess -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-Command -Times 0 -Exactly -ParameterFilter { $Name -eq 'python3' -or $Name -eq 'sudo' }
    }

    It 'revalidates a successful unprivileged helper with the same served roots' {
        $served = Join-Path $TestDrive 'checkout'
        $result = Repair-YurunaStartupPrivateState -ServedRoot @($served) -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.RepairAttempted | Should -Be $true
        $result.Privileged | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 3 -Exactly -ParameterFilter { $VerifyHome -and $ServedRoot.Count -eq 1 -and $ServedRoot[0] -eq $served }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:PythonPath -and $TimeoutSeconds -eq 30 -and
            $ArgumentList[0] -like '*Repair-PrivateState.py' -and $ArgumentList[1] -eq '--home' -and $ArgumentList[2] -eq $script:FixtureHome -and
            $ArgumentList[3] -eq '--uid' -and $ArgumentList[4] -eq '1001' -and $ArgumentList[5] -eq '--gid' -and $ArgumentList[6] -eq '1002'
        }
    }

    It 'uses cached or passwordless sudo without prompting when the helper requires elevation' {
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.Privileged | Should -Be $true
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:SudoPath -and $ArgumentList[0] -eq '-n' -and $ArgumentList[1] -eq '--' -and
            $ArgumentList[2] -eq $script:PythonPath -and $TimeoutSeconds -eq 30 -and $Environment.LC_ALL -eq 'C'
        }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 0 -Exactly
    }

    It 'authenticates once through the terminal then retries the bounded sudo command' -ForEach @('sudo: a password is required', 'sudo: interactive authentication is required') {
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr $_))
        $script:NativeAnswers.Enqueue((New-NativeAnswer))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.Privileged | Should -Be $true
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 2 -Exactly -ParameterFilter {
            $FilePath -eq $script:SudoPath -and $ArgumentList[0] -eq '-n' -and $TimeoutSeconds -eq 30
        }
    }

    It 'does not prompt without explicit permission or an interactive terminal' -ForEach @(
        @{ Allow = $false; Promptable = $true }
        @{ Allow = $true; Promptable = $false }
        @{ Allow = $false; Promptable = $false }
    ) {
        Mock -ModuleName Test.PrivateStateRepair Test-YurunaCanPrompt { $Promptable }.GetNewClosure()
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr 'sudo: a password is required'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt:$Allow -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'sudo-password-required'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 0 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 2 -Exactly
    }

    It 'reports authentication failure without retrying or reading the password itself' {
        Mock -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation { $false }
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr 'sudo: a password is required'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'sudo-authentication-failed'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 2 -Exactly
    }

    It 'does not prompt repeatedly when the elevated repair still fails after authentication' {
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr 'sudo: a password is required'))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdOut '{"reason":"foreign-owner"}'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'foreign-owner'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 3 -Exactly
    }

    It 'reports a repeated sudo refusal after one successful terminal authentication' {
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr 'sudo: a password is required'))
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdErr 'sudo: a password is required'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'sudo-authorization-failed'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 1 -Exactly
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 3 -Exactly
    }

    It 'leaves explicitly forbidden roots untouched' -ForEach @('no-home', 'home-mismatch', 'reparse-point', 'network-filesystem', 'served-tree') {
        Set-RootAnswer -Reason $_
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be $_
        $result.RepairAttempted | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { $NoCreate }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'observes only during WhatIf even when file access recovery was requested' -ForEach @($false, $true) {
        Set-RootAnswer -Reason $(if ($_) { 'ok' } else { 'owner-mismatch' })
        $result = Repair-YurunaStartupPrivateState -RepairFileAccess:$_ -WhatIf
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'preview'
        $result.RepairAttempted | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 1 -Exactly -ParameterFilter { $NoCreate }
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses elevation when account home verification is unavailable' {
        $script:RootAnswers.Clear()
        $script:RootAnswers.Enqueue((New-RootAnswer))
        $script:RootAnswers.Enqueue((New-RootAnswer -HomeVerified 'unverified'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'home-unverified'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses an unknown or malformed current identity' -ForEach @(
        @{ Resolved = $false; Uid = '1001'; Gid = '1002' }
        @{ Resolved = $true; Uid = 'unknown'; Gid = '1002' }
        @{ Resolved = $true; Uid = '1001'; Gid = 'unknown' }
    ) {
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaCurrentOwnerId {
            [pscustomobject]@{ Resolved = $Resolved; OwnerId = $Uid; PrimaryGroupId = $Gid; IsRoot = $false }
        }.GetNewClosure()
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'owner-unverified'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses an unresolved home path before running the repair helper' {
        Mock -ModuleName Test.PrivateStateRepair Resolve-YurunaCanonicalPath { [pscustomobject]@{ Resolved = $false; Path = $null } }
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'home-unverified'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses unknown or network home filesystems before running any helper' -ForEach @(
        @{ Resolved = $false; DriveType = 'Unknown' }
        @{ Resolved = $true; DriveType = 'Network' }
    ) {
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaPathDriveInfo { [pscustomobject]@{ Resolved = $Resolved; DriveType = $DriveType } }.GetNewClosure()
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'filesystem-unverified'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses containment in either direction even when the resolver supplied an ownership error' -ForEach @('parent', 'same', 'child') {
        $candidate = Join-Path $script:FixtureHome '.yuruna/host-refresh'
        $served = switch ($_) { parent { $script:FixtureHome } same { $candidate } child { Join-Path $candidate 'runtime' } }
        $result = Repair-YurunaStartupPrivateState -ServedRoot @($served) -Confirm:$false
        $result.Reason | Should -Be 'served-tree'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'refuses an unresolved served root before attempting permissions changes' {
        $served = Join-Path $TestDrive 'unknown-checkout'
        Mock -ModuleName Test.PrivateStateRepair Resolve-YurunaCanonicalPath { [pscustomobject]@{ Resolved = $false; Path = $null } } -ParameterFilter { $Path -eq $served }
        $result = Repair-YurunaStartupPrivateState -ServedRoot @($served) -Confirm:$false
        $result.Reason | Should -Be 'served-root-unverified'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'uses case-insensitive containment for macOS' {
        InModuleScope Test.PrivateStateRepair { Set-Variable -Name IsMacOS -Value $true -Scope Script }
        $served = (Join-Path $script:FixtureHome '.yuruna/host-refresh').ToUpperInvariant()
        $result = Repair-YurunaStartupPrivateState -ServedRoot @($served) -Confirm:$false
        $result.Reason | Should -Be 'served-tree'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'reports a missing helper interpreter without trying sudo' {
        Mock -ModuleName Test.PrivateStateRepair Get-Command { $null } -ParameterFilter { $Name -eq 'python3' }
        $result = Repair-YurunaStartupPrivateState -Confirm:$false
        $result.Reason | Should -Be 'python-missing'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'reports missing sudo only after the helper requests elevation' {
        Mock -ModuleName Test.PrivateStateRepair Get-Command { $null } -ParameterFilter { $Name -eq 'sudo' }
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $result = Repair-YurunaStartupPrivateState -Confirm:$false
        $result.Reason | Should -Be 'sudo-missing'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly
    }

    It 'does not accept partial native results or elevate after an incomplete helper' -ForEach @('TimedOut', 'DrainTimedOut', 'OutputTruncated', 'KillFailed', 'DeadlineExhausted') {
        $answer = New-NativeAnswer -ExitCode 2
        $answer.$_ = $true
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue($answer)
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'repair-incomplete'
        $result.Privileged | Should -Be $false
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly
    }

    It 'reports a timed-out sudo attempt without starting an authentication prompt' {
        $answer = New-NativeAnswer -ExitCode 124 -StdErr 'sudo: a password is required'
        $answer.TimedOut = $true
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 2))
        $script:NativeAnswers.Enqueue($answer)
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'repair-incomplete'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-YurunaPrivateStateSudoValidation -Times 0 -Exactly
    }

    It 'reports an explicit helper refusal without invoking sudo for a permanent failure' {
        $script:NativeAnswers.Clear()
        $script:NativeAnswers.Enqueue((New-NativeAnswer -ExitCode 1 -StdOut '{"reason":"symlink-refused"}'))
        $result = Repair-YurunaStartupPrivateState -AllowPrompt -Confirm:$false
        $result.Reason | Should -Be 'symlink-refused'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly
    }

    It 'does not treat successful helper exit as proof that the private root is safe' {
        Set-RootAnswer -Reason @('owner-mismatch', 'owner-mismatch', 'parent-untrusted')
        $result = Repair-YurunaStartupPrivateState -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'parent-untrusted'
        Should -Invoke -ModuleName Test.PrivateStateRepair Get-YurunaPrivateStateRoot -Times 3 -Exactly
    }

    It 'inspects private files on explicit access-denied recovery even when the root resolves' {
        Set-RootAnswer -Reason @('ok', 'ok', 'ok')
        $result = Repair-YurunaStartupPrivateState -RepairFileAccess -Confirm:$false
        $result.Resolved | Should -Be $true
        $result.RepairAttempted | Should -Be $true
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 1 -Exactly
    }

    It 'does not invoke Unix ownership tools for a Windows ACL failure' {
        InModuleScope Test.PrivateStateRepair { Set-Variable -Name IsWindows -Value $true -Scope Script }
        Set-RootAnswer -Reason @('permission-loose', 'ok')
        $result = Repair-YurunaStartupPrivateState -Confirm:$false
        $result.Resolved | Should -Be $true
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }

    It 'reports Windows private-file access failures without claiming successful repair' {
        InModuleScope Test.PrivateStateRepair { Set-Variable -Name IsWindows -Value $true -Scope Script }
        Set-RootAnswer -Reason @('ok', 'ok')
        $result = Repair-YurunaStartupPrivateState -RepairFileAccess -Confirm:$false
        $result.Resolved | Should -Be $false
        $result.Reason | Should -Be 'file-access-denied'
        Should -Invoke -ModuleName Test.PrivateStateRepair Invoke-BoundedNativeCommand -Times 0 -Exactly
    }
}

Describe 'Startup lock metadata inspection' {
    BeforeEach {
        $script:LockRoot = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($script:LockRoot)
    }

    It 'accepts an empty lock directory without creating files' {
        $result = & (Get-Module Test.PrivateStateRepair) { param($path) Test-YurunaStartupLockAccess -RootPath $path } $script:LockRoot
        $result | Should -Be $true
        @(Get-ChildItem -LiteralPath $script:LockRoot -Force).Count | Should -Be 0
    }

    It 'observes an owned held lock without competing for its file handle or changing content' -Skip:$IsWindows {
        $path = Join-Path $script:LockRoot 'status-service.fixture.start.lock'
        [IO.File]::WriteAllText($path, 'existing generation')
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]'UserRead, UserWrite')
        $held = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
            $result | Should -Be $true
            $held.CanWrite | Should -Be $true
        } finally { $held.Dispose() }
        [IO.File]::ReadAllText($path) | Should -Be 'existing generation'
        [IO.File]::GetUnixFileMode($path) | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite')
    }

    It 'refuses a lock without owner write permission without changing that permission' -Skip:$IsWindows {
        $path = Join-Path $script:LockRoot 'status-service.fixture.start.lock'
        [IO.File]::WriteAllText($path, 'existing generation')
        [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead)
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $false
        [IO.File]::GetUnixFileMode($path) | Should -Be ([IO.UnixFileMode]::UserRead)
    }

    It 'refuses a directory where a lock file belongs' {
        $null = [IO.Directory]::CreateDirectory((Join-Path $script:LockRoot 'status-service.fixture.start.lock'))
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $false
    }

    It 'refuses a symbolic lock without following its target' -Skip:$IsWindows {
        $target = Join-Path $TestDrive 'link-target.txt'
        [IO.File]::WriteAllText($target, 'outside state')
        $null = [IO.File]::CreateSymbolicLink((Join-Path $script:LockRoot 'status-service.fixture.start.lock'), $target)
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $false
        [IO.File]::ReadAllText($target) | Should -Be 'outside state'
    }

    It 'ignores an unrelated symbolic link while inspecting only startup locks' -Skip:$IsWindows {
        $target = Join-Path $TestDrive 'unrelated-target.txt'
        [IO.File]::WriteAllText($target, 'unrelated state')
        $link = Join-Path $script:LockRoot 'unrelated.record'
        $null = [IO.File]::CreateSymbolicLink($link, $target)
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $true
        [IO.FileInfo]::new($link).LinkTarget | Should -Be $target
        [IO.File]::ReadAllText($target) | Should -Be 'unrelated state'
    }

    It 'refuses a lock belonging to another user before checking its permissions' {
        [IO.File]::WriteAllText((Join-Path $script:LockRoot 'status-service.fixture.start.lock'), 'existing generation')
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '1001' } }
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '0' } }
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $false
    }

    It 'refuses an unreadable current identity' {
        Mock -ModuleName Test.PrivateStateRepair Get-YurunaCurrentOwnerId { [pscustomobject]@{ Resolved = $false; OwnerId = $null } }
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $script:LockRoot
        $result | Should -Be $false
    }

    It 'refuses a missing directory rather than treating failed enumeration as an empty directory' {
        $path = Join-Path $script:LockRoot 'absent'
        $result = & (Get-Module Test.PrivateStateRepair) { param($value) Test-YurunaStartupLockAccess -RootPath $value } $path
        $result | Should -Be $false
        $path | Should -Not -Exist
    }
}

Describe 'Private-state filesystem repair helper' {
    It 'passes the Python filesystem and privilege-boundary regressions' -Skip:$IsWindows {
        $python = Get-Command python3 -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $suite = Join-Path $PSScriptRoot '../service/test_private_state_repair.py'
        $result = Yuruna.Common\Invoke-BoundedNativeCommand -FilePath $python.Source -ArgumentList @('-B', $suite) -TimeoutSeconds 30
        (Yuruna.Common\Test-BoundedNativeResultComplete -Result $result) | Should -Be $true
        $output = "$($result.StdOut)`n$($result.StdErr)"
        $result.ExitCode | Should -Be 0 -Because $output
        $output | Should -Match '(?m)^Ran [1-9][0-9]* tests? in '
        $output | Should -Match '(?m)^OK(?:\s|\(|$)'
    }
}

Describe 'Private-state recovery entry-point boundaries' {
    BeforeAll {
        $script:RunnerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Start-TestRunner.ps1'), [ref]$null, [ref]$null)
        $script:StatusAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../service/Start-StatusService.ps1'), [ref]$null, [ref]$null)

        function Get-CommandNode {
            param($Ast, [string]$Name)
            @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object { $_.GetCommandName() -eq $Name })
        }

        function Get-NearestIfCondition {
            param($Node)
            $parent = $Node.Parent
            while ($parent -and $parent -isnot [Management.Automation.Language.IfStatementAst]) { $parent = $parent.Parent }
            if ($parent) { return $parent.Clauses[0].Item1.Extent.Text }
            return ''
        }
    }

    It 'prepares private state before sg removes PowerShell prompt support and before writing the runner launch record' {
        $repair = @(Get-CommandNode -Ast $script:RunnerAst -Name 'Repair-YurunaStartupPrivateState')
        $reexec = @(Get-CommandNode -Ast $script:RunnerAst -Name 'Invoke-LibvirtGroupReExecIfNeeded')
        $record = @(Get-CommandNode -Ast $script:RunnerAst -Name 'Write-YurunaRunnerLaunchRecord')
        $repair.Count | Should -Be 1
        $reexec.Count | Should -Be 1
        $record.Count | Should -Be 1
        $repair[0].Extent.StartOffset | Should -BeLessThan $reexec[0].Extent.StartOffset
        $repair[0].Extent.StartOffset | Should -BeLessThan $record[0].Extent.StartOffset
        $repair[0].Extent.Text | Should -Match '-AllowPrompt'
        $repair[0].Extent.Text | Should -Match '-RepairFileAccess:'
        (Get-NearestIfCondition -Node $repair[0]) | Should -Match '-not\s+\$RefreshResume'
    }

    It 'keeps both status-service repair paths outside refresh-safe starts' {
        $repairs = @(Get-CommandNode -Ast $script:StatusAst -Name 'Repair-YurunaStartupPrivateState')
        $repairs.Count | Should -Be 2
        foreach ($repair in $repairs) {
            (Get-NearestIfCondition -Node $repair) | Should -Match '-not\s+\$RefreshSafe'
            $repair.Extent.Text | Should -Match '-ServedRoot\s+\$ServedRootSet'
        }
        $lockRepair = @($repairs | Where-Object { $_.Extent.Text -match '-RepairFileAccess' })
        $lockRepair.Count | Should -Be 1
        (Get-NearestIfCondition -Node $lockRepair[0]) | Should -Match "\`$startLock\.Reason\s+-eq\s+'access-denied'"
    }
}
