<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42caaabc-fe31-4614-8998-b7a6aed945ce
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service startup private-state pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeAll {
    $path = Join-Path $PSScriptRoot '../service/Start-StatusService.ps1'
    $source = [IO.File]::ReadAllText($path)
    $block = [regex]::Match($source, '(?ms)^\$startLockInfo = \$null\r?\n.*?(?=^function Save-StatusServiceErrorLog \{)')
    if (-not $block.Success) { throw 'Status startup serialization block was not found.' }
    $script:SerializationBlock = [scriptblock]::Create($block.Value)
    $startupAst = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $releaseHelper = @($startupAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Exit-StatusServiceStartupLock'
    }, $false))[0].Extent.Text
    $startupTrap = @($startupAst.EndBlock.Traps)[0].Extent.Text
    $acquisition = @($startupAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$startLockInfo'
    }, $false))[0]
    $lifecycle = $acquisition.Parent
    while ($lifecycle -and $lifecycle -isnot [Management.Automation.Language.TryStatementAst]) { $lifecycle = $lifecycle.Parent }
    $startupBody = if ($lifecycle) { $lifecycle.Extent.Text } else { $source.Substring($acquisition.Extent.StartOffset) }
    $script:StartupLifecycle = $releaseHelper + "`n" + $startupTrap + "`n" + $startupBody
    $script:LockModulePath = Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1'

    function Get-StartupLockContender {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path)
        $contender = [powershell]::Create()
        try {
            $null = $contender.AddScript({
                param($ModulePath, $LockPath)
                Import-Module $ModulePath -Global -DisableNameChecking
                $lock = Enter-YurunaSingleFlightLock -Path $LockPath -WaitMilliseconds 100
                try { [pscustomobject]@{ Held = $lock.Held; Reason = $lock.Reason } }
                finally { Exit-YurunaSingleFlightLock -Lock $lock }
            }).AddArgument($script:LockModulePath).AddArgument($Path)
            $result = @($contender.Invoke())
            if ($contender.HadErrors) { throw $contender.Streams.Error[0] }
            if ($result.Count -ne 1) { throw "Unexpected lock contender result count: $($result.Count)" }
            return $result[0]
        } finally { $contender.Dispose() }
    }

    # Only the serialization statements execute; service launch and real locks
    # must remain unreachable even if a mock is accidentally omitted.
    function Get-YurunaPrivateStatePath {
        param([string]$Name, [string[]]$ServedRoot)
        throw "Unmocked private path: $Name in $($ServedRoot -join ',')"
    }
    function Get-StatusRuntimeKey {
        param([string]$RuntimeDir)
        throw "Unmocked runtime key: $RuntimeDir"
    }
    function Enter-YurunaSingleFlightLock {
        param([string]$Path, [int]$WaitMilliseconds, [hashtable]$Metadata)
        throw "Unmocked lock: $Path, $WaitMilliseconds, $($Metadata.purpose)"
    }
    function Get-YurunaDeadlineRemainingMs {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
            Justification = 'Ms is the existing production command abbreviation for milliseconds.')]
        param([object]$Deadline)
        throw "Unmocked deadline: $Deadline"
    }
    function Complete-RefreshSafeStart {
        param([string]$Outcome, [string]$Reason)
        throw "Unmocked refresh result: $Outcome/$Reason"
    }
    function Repair-YurunaStartupPrivateState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
            Justification = 'The throwing test double only exposes the production command parameters to Pester.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string[]]$ServedRoot, [switch]$AllowPrompt, [switch]$RepairFileAccess)
        throw "Unmocked repair: $($ServedRoot -join ','), $AllowPrompt, $RepairFileAccess, $($PSBoundParameters['Confirm'])"
    }
    function Invoke-StatusStartupSerialization {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
            Justification = 'The extracted production block reads these variables in the dot-sourced scope.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'The extracted production block reads the RefreshSafe parameter in this scope.')]
        [CmdletBinding()]
        param([switch]$RefreshSafe)
        $RuntimeDir = $script:FixtureRuntime
        $Port = 8080
        $ServedRootSet = $script:FixtureServedRoots
        . $script:SerializationBlock
    }
}

Describe 'Status service startup private-state recovery' {
    BeforeEach {
        $script:FixtureRuntime = Join-Path $TestDrive 'runtime'
        $script:FixtureServedRoots = @((Join-Path $TestDrive 'checkout'), $script:FixtureRuntime)
        $script:FixtureLockPath = Join-Path $TestDrive 'private/status-service.0123456789abcdef.start.lock'
        $script:StatusStartupLock = $null
        $script:RefreshSafeDeadline = [pscustomobject]@{ Label = 'bounded refresh' }
        $script:PathAnswers = [Collections.Generic.Queue[object]]::new()
        $script:LockAnswers = [Collections.Generic.Queue[object]]::new()
        $script:RepairAnswers = [Collections.Generic.Queue[object]]::new()
        $script:GoodPath = [pscustomobject]@{ Resolved = $true; Reason = 'ok'; Path = $script:FixtureLockPath }
        $script:HeldLock = [pscustomobject]@{ Held = $true; Reason = 'acquired'; Generation = 'kept-generation' }
        $script:PathAnswers.Enqueue($script:GoodPath)
        $script:LockAnswers.Enqueue($script:HeldLock)
        $script:RepairAnswers.Enqueue([pscustomobject]@{ Resolved = $true; Reason = 'ok' })
        $paths = $script:PathAnswers
        $locks = $script:LockAnswers
        $repairs = $script:RepairAnswers
        Mock Get-YurunaPrivateStatePath {
            if ($paths.Count -eq 0) { throw 'Unexpected extra private-path resolution.' }
            $paths.Dequeue()
        }.GetNewClosure()
        Mock Enter-YurunaSingleFlightLock {
            if ($locks.Count -eq 0) { throw 'Unexpected extra lock acquisition.' }
            $locks.Dequeue()
        }.GetNewClosure()
        Mock Repair-YurunaStartupPrivateState {
            if ($repairs.Count -eq 0) { throw 'Unexpected extra private-state repair.' }
            $repairs.Dequeue()
        }.GetNewClosure()
        Mock Get-StatusRuntimeKey { '0123456789abcdef' }
        Mock Get-YurunaDeadlineRemainingMs { 6000 }
        Mock Complete-RefreshSafeStart {
            param($Outcome, $Reason)
            throw "refresh:$Outcome/$Reason"
        }
    }

    It 'keeps a successfully acquired lock without any repair' {
        Invoke-StatusStartupSerialization
        [object]::ReferenceEquals($script:StatusStartupLock, $script:HeldLock) | Should -Be $true
        Should -Invoke Get-YurunaPrivateStatePath -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'status-service.0123456789abcdef.start.lock' -and $ServedRoot.Count -eq 2
        }
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly -ParameterFilter {
            $Path -eq $script:FixtureLockPath -and $WaitMilliseconds -eq 15000 -and
            $Metadata.purpose -eq 'status-service-start' -and $Metadata.port -eq 8080
        }
        Should -Invoke Repair-YurunaStartupPrivateState -Times 0 -Exactly
    }

    It 'repairs an unresolved root and resolves its lock path again before acquisition' {
        $script:PathAnswers.Clear()
        $script:PathAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'owner-mismatch' })
        $script:PathAnswers.Enqueue($script:GoodPath)
        Invoke-StatusStartupSerialization
        [object]::ReferenceEquals($script:StatusStartupLock, $script:HeldLock) | Should -Be $true
        Should -Invoke Get-YurunaPrivateStatePath -Times 2 -Exactly
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly -ParameterFilter {
            $AllowPrompt -and -not $RepairFileAccess -and -not $Confirm -and $ServedRoot.Count -eq 2
        }
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly
    }

    It 'reports the precise repair refusal without attempting an unserialized start' {
        $script:PathAnswers.Clear()
        $script:PathAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'owner-mismatch' })
        $script:RepairAnswers.Clear()
        $script:RepairAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'sudo-password-required' })
        { Invoke-StatusStartupSerialization } | Should -Throw '*startup lock could not be resolved (sudo-password-required)*'
        $script:StatusStartupLock | Should -BeNullOrEmpty
        Should -Invoke Enter-YurunaSingleFlightLock -Times 0 -Exactly
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly
    }

    It 'preserves a leaf refusal discovered after the root was repaired' {
        $script:PathAnswers.Clear()
        $script:PathAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'owner-mismatch' })
        $script:PathAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'reparse-point' })
        { Invoke-StatusStartupSerialization } | Should -Throw '*startup lock could not be resolved (reparse-point)*'
        $script:StatusStartupLock | Should -BeNullOrEmpty
        Should -Invoke Get-YurunaPrivateStatePath -Times 2 -Exactly
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly
        Should -Invoke Enter-YurunaSingleFlightLock -Times 0 -Exactly
    }

    It 'repairs a denied lock file and retries the same inode path once' {
        $script:LockAnswers.Clear()
        $script:LockAnswers.Enqueue([pscustomobject]@{ Held = $false; Reason = 'access-denied' })
        $script:LockAnswers.Enqueue($script:HeldLock)
        Invoke-StatusStartupSerialization
        [object]::ReferenceEquals($script:StatusStartupLock, $script:HeldLock) | Should -Be $true
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly -ParameterFilter {
            $AllowPrompt -and $RepairFileAccess -and -not $Confirm
        }
        Should -Invoke Enter-YurunaSingleFlightLock -Times 2 -Exactly -ParameterFilter {
            $Path -eq $script:FixtureLockPath
        }
    }

    It 'does not loop when a lock remains inaccessible after repair' {
        $script:LockAnswers.Clear()
        1..2 | ForEach-Object { $script:LockAnswers.Enqueue([pscustomobject]@{ Held = $false; Reason = 'access-denied' }) }
        { Invoke-StatusStartupSerialization } | Should -Throw '*lock cannot be acquired (access-denied)*'
        $script:StatusStartupLock | Should -BeNullOrEmpty
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly
        Should -Invoke Enter-YurunaSingleFlightLock -Times 2 -Exactly
    }

    It 'retains a failed file-repair reason instead of replacing it with access denied' {
        $script:LockAnswers.Clear()
        $script:LockAnswers.Enqueue([pscustomobject]@{ Held = $false; Reason = 'access-denied' })
        $script:RepairAnswers.Clear()
        $script:RepairAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'unsafe-hardlink' })
        { Invoke-StatusStartupSerialization } | Should -Throw '*lock cannot be acquired (unsafe-hardlink)*'
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly
        Should -Invoke Repair-YurunaStartupPrivateState -Times 1 -Exactly
    }

    It 'does not treat a lock held by another process as a permissions problem' {
        $script:LockAnswers.Clear()
        $script:LockAnswers.Enqueue([pscustomobject]@{ Held = $false; Reason = 'held-elsewhere' })
        { Invoke-StatusStartupSerialization } | Should -Throw "*lock cannot be acquired (held-elsewhere)*$($script:FixtureLockPath)*"
        Should -Invoke Repair-YurunaStartupPrivateState -Times 0 -Exactly
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly
    }

    It 'never repairs an unresolved private root during a refresh-safe start' {
        $script:PathAnswers.Clear()
        $script:PathAnswers.Enqueue([pscustomobject]@{ Resolved = $false; Reason = 'owner-mismatch' })
        { Invoke-StatusStartupSerialization -RefreshSafe } | Should -Throw '*refresh:invalid-invocation/private-state-owner-mismatch*'
        Should -Invoke Complete-RefreshSafeStart -Times 1 -Exactly -ParameterFilter {
            $Outcome -eq 'invalid-invocation' -and $Reason -eq 'private-state-owner-mismatch'
        }
        Should -Invoke Repair-YurunaStartupPrivateState -Times 0 -Exactly
        Should -Invoke Enter-YurunaSingleFlightLock -Times 0 -Exactly
    }

    It 'never repairs an access-denied lock during a refresh-safe start' {
        $script:LockAnswers.Clear()
        $script:LockAnswers.Enqueue([pscustomobject]@{ Held = $false; Reason = 'access-denied' })
        { Invoke-StatusStartupSerialization -RefreshSafe } | Should -Throw '*refresh:admission-busy/access-denied*'
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly -ParameterFilter { $WaitMilliseconds -eq 5000 }
        Should -Invoke Repair-YurunaStartupPrivateState -Times 0 -Exactly
        Should -Invoke Complete-RefreshSafeStart -Times 1 -Exactly -ParameterFilter {
            $Outcome -eq 'admission-busy' -and $Reason -eq 'access-denied'
        }
    }

    It 'accepts a refresh-safe lock within the remaining deadline without repair' {
        Invoke-StatusStartupSerialization -RefreshSafe
        [object]::ReferenceEquals($script:StatusStartupLock, $script:HeldLock) | Should -Be $true
        Should -Invoke Enter-YurunaSingleFlightLock -Times 1 -Exactly -ParameterFilter { $WaitMilliseconds -eq 5000 }
        Should -Invoke Repair-YurunaStartupPrivateState -Times 0 -Exactly
        Should -Invoke Complete-RefreshSafeStart -Times 0 -Exactly
    }
}

Describe 'Status service startup lock lifetime' {
    It 'releases the actual lock after <Mode> while preserving live contention' -ForEach @(
        @{ Mode = 'cancellation' }
        @{ Mode = 'failure' }
    ) {
        $lockPath = Join-Path $TestDrive "startup-$Mode.lock"
        $state = [hashtable]::Synchronized(@{ ReachedBody = $false; Mode = $Mode })
        $startup = [powershell]::Create()
        try {
            # Execute the launcher's actual lock lifetime, helper and trap. Stop
            # at the first post-acquisition path lookup, before any host action.
            $fixture = @'
param($State, $ModulePath, $LockPath, $Lifecycle)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Global -DisableNameChecking
$RuntimeDir = [IO.Path]::GetDirectoryName($LockPath)
$Port = 8080
$RefreshSafe = $false
$Restart = $false
$PidFile = [IO.Path]::Combine($RuntimeDir, 'server.pid')
$ServedRootSet = @($RuntimeDir)
$script:StatusStartupLock = $null
function Get-YurunaPrivateStatePath {
    param($Name, $ServedRoot)
    if (-not $Name -or -not $ServedRoot) { throw 'Missing private-path fixture inputs.' }
    [pscustomobject]@{ Resolved = $true; Path = $LockPath; Reason = 'ok' }
}
function Get-StatusRuntimeKey {
    param($RuntimeDir)
    if (-not $RuntimeDir) { throw 'Missing runtime fixture input.' }
    'fixture-runtime'
}
function Join-Path {
    param($Path, $ChildPath)
    if ($ChildPath -eq 'server.sha') {
        $State.ReachedBody = $true
        if ($State.Mode -eq 'failure') { throw 'startup-fixture-failure' }
        Start-Sleep -Seconds 30
        throw 'Startup cancellation did not arrive.'
    }
    Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
}
. ([scriptblock]::Create($Lifecycle))
'@
            $null = $startup.AddScript($fixture).AddArgument($state).AddArgument($script:LockModulePath).
                AddArgument($lockPath).AddArgument($script:StartupLifecycle)
            $pending = $startup.BeginInvoke()
            $deadline = [Environment]::TickCount64 + 10000
            while (-not $state.ReachedBody -and -not $pending.IsCompleted -and [Environment]::TickCount64 -lt $deadline) {
                Start-Sleep -Milliseconds 10
            }
            $state.ReachedBody | Should -BeTrue -Because 'the fixture must reach the real acquired-lock body'
            if ($Mode -eq 'cancellation') {
                $held = Get-StartupLockContender -Path $lockPath
                $held.Held | Should -BeFalse
                $held.Reason | Should -Be 'held-elsewhere'
                $startup.Stop()
            }
            $startupFailure = $null
            try { $null = $startup.EndInvoke($pending) } catch { $startupFailure = $_ }
            $startupFailure | Should -Not -BeNullOrEmpty
            if ($Mode -eq 'failure') { $startupFailure.Exception.ToString() | Should -Match 'startup-fixture-failure' }
            # Keep the owner's runspace alive: disposing it would hide a leaked
            # handle, which otherwise survives in an interactive session.
            $after = Get-StartupLockContender -Path $lockPath
            $after.Held | Should -BeTrue -Because 'the completed startup must release its held-open file handle'
            $after.Reason | Should -Be 'acquired'
        } finally {
            $startup.Stop()
            $startup.Dispose()
        }
    }
}
