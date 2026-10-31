<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42fff0b4-1eb3-4eba-8efc-bcdaf457e9b4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner entry-point defaults module-set log-level host-network pester
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
    Pester coverage for what the runner's entry points share: one table of
    timing defaults, a module-set loader that refuses a missing module, the
    operator's -ConfigPath and -logLevel reaching the processes the runner
    starts, and the cycle-start host-network gate, service-VM restore, External
    vSwitch repair and caching-proxy gate as functions.
.DESCRIPTION
    The resident runner and the per-cycle process each kept their own copy of
    the timing defaults and the two disagreed; the copy an operator was told
    to edit was not the one the per-cycle process, which arms the watchdog,
    used. The module-set loader skipped a missing module with a warning. A
    child entry point resolved the in-tree config path instead of the one
    its parent was given, and the outer processes never applied -logLevel to
    themselves. The cycle-start gates were inline preamble code no test could
    reach.
    Run: Invoke-Pester -Path test/modules/Test.RunnerEntryPointContract.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:TestRoot = Split-Path -Parent $here
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -Global -DisableNameChecking
}

Describe 'the runner timing defaults come from one table' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -Global -DisableNameChecking
        $script:TunableKeys = @('FailurePauseMaxSeconds', 'OuterNetworkGateRetrySeconds', 'OuterNetworkGateRetryMaxSeconds',
            'OuterNetworkGateRecoveryPollSeconds', 'FailureCommitPollSeconds', 'OuterPullErrorSleepSeconds',
            'InnerSpawnErrorSleepSeconds', 'StepTimeoutSecondsDefault', 'PreambleTimeoutSecondsDefault',
            'MaxCycleSecondsDefault', 'WatchdogPollSeconds')
    }

    It 'names every key the loop requires, with the documented values' {
        $table = Get-RunnerTunableDefault
        Assert-Equal -Expected (($script:TunableKeys | Sort-Object) -join ',') -Actual ((@($table.Keys) | Sort-Object) -join ',')
        Assert-Equal -Expected 3600 -Actual $table.FailurePauseMaxSeconds
        Assert-Equal -Expected 2700 -Actual $table.StepTimeoutSecondsDefault
        Assert-Equal -Expected 600 -Actual $table.PreambleTimeoutSecondsDefault
        Assert-Equal -Expected 21600 -Actual $table.MaxCycleSecondsDefault
        Assert-Equal -Expected 30 -Actual $table.FailureCommitPollSeconds
    }

    It '<Script> builds its state from the table and assigns none of the values itself' -TestCases @(
        @{ Script = 'Start-TestRunner.ps1' }
        @{ Script = 'modules/Invoke-TestCycleRunner.ps1' }
    ) {
        param([string]$Script)
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:TestRoot $Script)
        Assert-True ((Get-YurunaTestCommandCallCount -Ast $ast -CommandName 'Get-RunnerTunableDefault') -ge 1) "$Script reads the table"
        $literal = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -cmatch '(StepTimeoutSecondsDefault|FailureCommitPollSeconds|WatchdogPollSeconds|PreambleTimeoutSecondsDefault|MaxCycleSecondsDefault|FailurePauseMaxSeconds)\b') -or
            ($n -is [System.Management.Automation.Language.HashtableAst] -and @($n.KeyValuePairs | Where-Object { $_.Item1.Extent.Text -cin $script:TunableKeys }).Count -gt 0)
        }, $true))
        Assert-Equal -Expected 0 -Actual $literal.Count -Because "a second copy of a default drifts: $(@($literal | ForEach-Object { $_.Extent.Text.Split("`n")[0] }) -join ' | ')"
    }

    It 'has the outer loop fall back to the table, never to a literal of its own' {
        $text = (Get-YurunaTestFileAst -Path (Join-Path $here 'Test.RunnerOuterLoop.psm1')).Extent.Text
        $fallbacks = [regex]::Matches($text, "ContainsKey\('(StepTimeoutSecondsDefault|PreambleTimeoutSecondsDefault|MaxCycleSecondsDefault)'\)\)\s*\{[^}]*\}\s*else\s*\{\s*([^}]*)\}")
        Assert-True ($fallbacks.Count -ge 4) 'every fallback was found'
        foreach ($m in $fallbacks) { Assert-Match -Pattern 'Get-RunnerTunableDefault' -Actual $m.Groups[2].Value -Because "fallback for $($m.Groups[1].Value)" }
    }
}

Describe 'the module-set loader refuses a missing module' {
    It 'names the missing module and imports nothing of the set' {
        $modules = Join-Path $TestDrive 'modules'
        $null = New-Item -ItemType Directory -Path $modules
        $probe = Join-Path $TestDrive 'imported.txt'
        $set = @('Test.HostContract.psm1', 'Test.YurunaDir.psm1', 'Test.Config.psm1', 'Test.StateFile.psm1', 'Test.OuterLog.psm1',
            'Test.SingleFlightLock.psm1', 'Test.CriticalRecord.psm1', 'Test.SingleInstance.psm1', 'Test.InnerSpawn.psm1',
            'Test.Recovery.psm1', 'Test.ServiceCensus.psm1', 'Test.ServiceVm.psm1', 'Test.HostRefreshIntent.psm1', 'Test.HostRefresh.psm1')
        foreach ($name in $set) {
            if ($name -eq 'Test.ServiceVm.psm1') { continue }
            Set-Content -LiteralPath (Join-Path $modules $name) -Value "Add-Content -LiteralPath '$probe' -Value '$name'"
        }
        # A child process, so a stub can never replace a real module in this session.
        $child = Join-Path $TestDrive 'load.ps1'
        Set-Content -LiteralPath $child -Value @"
`$PSStyle.OutputRendering = 'PlainText'
Import-Module '$(Join-Path $here 'Test.Prelude.psm1')' -Force
try { Initialize-YurunaEntryPointModuleSet -For Refresh -ModulesDir '$modules'; 'no-throw' } catch { "threw: `$(`$_.Exception.Message)" }
"@
        $out = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $child 2>&1) -join "`n"
        Assert-Match -Pattern '^threw: .*Test\.ServiceVm\.psm1' -Actual $out -Because 'the refusal names the missing file'
        Assert-False (Test-Path -LiteralPath $probe) 'no module of the set was imported before the refusal'
    }
}

Describe 'the operator''s -ConfigPath and -logLevel reach the processes the runner starts' {
    It 'resolves an inherited config path when none is passed, and a passed one wins' {
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_CONFIG_PATH'
        try {
            $env:YURUNA_CONFIG_PATH = '/srv/operator/test.config.yml'
            Assert-Equal -Expected '/srv/operator/test.config.yml' -Actual (Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot).ConfigPath
            Assert-Equal -Expected '/other.yml' -Actual (Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot -ConfigPath '/other.yml').ConfigPath
            Remove-Item -LiteralPath Env:YURUNA_CONFIG_PATH
            Assert-Equal -Expected (Join-Path $script:TestRoot 'test.config.yml') -Actual (Initialize-YurunaEntryPoint -ScriptRoot $script:TestRoot).ConfigPath
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
    }

    It '<Script> applies the level to itself before it captures the environment its children inherit' -TestCases @(
        @{ Script = 'Start-TestRunner.ps1'; Snapshot = 'ForwardEnvSnapshot' }
        @{ Script = 'modules/Invoke-TestCycleRunner.ps1'; Snapshot = 'forwardEnvSnapshot' }
    ) {
        param([string]$Script, [string]$Snapshot)
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:TestRoot $Script)
        $resolve = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Resolve-LogLevel' }, $true))
        Assert-Equal -Expected 1 -Actual $resolve.Count -Because "$Script resolves the level once"
        Assert-Match -Pattern '-CmdLineLevel' -Actual $resolve[0].Extent.Text
        Assert-Match -Pattern '-ConfigLevel' -Actual $resolve[0].Extent.Text
        $snapshotAt = $ast.Extent.Text.IndexOf("`$$Snapshot = @{}", [StringComparison]::OrdinalIgnoreCase)
        if ($snapshotAt -lt 0) { $snapshotAt = $ast.Extent.Text.IndexOf("`$script:$Snapshot = @{}", [StringComparison]::OrdinalIgnoreCase) }
        Assert-True ($snapshotAt -gt 0) 'the environment snapshot exists'
        Assert-True ($resolve[0].Extent.StartOffset -lt $snapshotAt) 'YURUNA_LOG_LEVEL is published before the snapshot'
    }

    It '<Worker> applies the level it inherited' -TestCases @(
        @{ Worker = 'modules/Invoke-StartCycleWorker.ps1' }
        @{ Worker = 'modules/Invoke-HostDiagnosticWorker.ps1' }
        @{ Worker = 'modules/Invoke-PoolStorageDrain.ps1' }
        @{ Worker = 'modules/Invoke-PoolPushForwarder.ps1' }
        @{ Worker = 'modules/Invoke-HostAddressBeacon.ps1' }
        @{ Worker = 'modules/Invoke-RecoveryProbe.ps1' }
        @{ Worker = 'Invoke-GuestDiagnosticWorker.ps1' }
    ) {
        param([string]$Worker)
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:TestRoot $Worker)
        Assert-True ((Get-YurunaTestCommandCallCount -Ast $ast -CommandName 'Use-LogLevelFromEnv') -ge 1) "$Worker calls Use-LogLevelFromEnv"
    }

    It 'publishes the level a resolve picked for the children of the process' {
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_LEVEL'
        $savedVerbose = $global:VerbosePreference
        try {
            Import-Module (Join-Path $here 'Test.LogLevel.psm1') -Force -Global
            $null = Resolve-LogLevel -CmdLineLevel '' -ConfigLevel 'Verbose'
            Assert-Equal -Expected 'Verbose' -Actual $env:YURUNA_LOG_LEVEL
            $null = Resolve-LogLevel -CmdLineLevel 'Warning' -ConfigLevel 'Verbose'
            Assert-Equal -Expected 'Warning' -Actual $env:YURUNA_LOG_LEVEL -Because '-logLevel wins over the config'
        } finally {
            Restore-YurunaTestEnvironment -Saved $saved
            $global:VerbosePreference = $savedVerbose
        }
    }
}

Describe 'the cycle-start host-network gate' {
    BeforeAll {
        Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
        $script:Runtime = Join-Path $TestDrive 'runtime'
    }
    BeforeEach {
        if (Test-Path -LiteralPath $script:Runtime) { Remove-Item -LiteralPath $script:Runtime -Recurse -Force }
        $null = New-Item -ItemType Directory -Path $script:Runtime
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $false; Path = 'external'; Reason = 'fine'; Verdicts = @() }
        Mock -ModuleName Test.RunnerInnerLoop Test-HostGuestNetworkHealth { $script:Health }
        Mock -ModuleName Test.RunnerInnerLoop Write-HostRegistrationRecord { }
        Mock -ModuleName Test.RunnerInnerLoop Test-YurunaRefreshSpawnAllowed { $true }
        Mock -ModuleName Test.RunnerInnerLoop Get-PwshApplicationPath { 'pwsh' }
        Mock -ModuleName Test.RunnerInnerLoop Invoke-BoundedNativeCommand { @{ TimedOut = $false; ExitCode = 0; StdOut = 'swept'; StdErr = '' } }
        Mock -ModuleName Test.RunnerInnerLoop Get-BoundedNativeOutputLine { 'swept one VM' }
        function script:Invoke-Gate { Invoke-CycleHostNetworkGate -HostType 'host.windows.hyper-v' -RuntimeDir $script:Runtime -TestRoot $script:TestRoot -RepoRoot (Split-Path -Parent $script:TestRoot) 3>$null 6>$null }
    }

    It 'passes a healthy host and forgets an earlier loss' {
        Set-Content -LiteralPath (Join-Path $script:Runtime 'runner.hostNetwork.json') -Value '{"consecutiveTotalLoss": 2}'
        $gate = Invoke-Gate
        Assert-True $gate.Ok 'a healthy host runs'
        Assert-False (Test-Path -LiteralPath $gate.StateFile) 'the loss streak is cleared'
    }

    It 'refuses only on the third lost cycle, and sweeps once per loss' {
        $script:Health = [pscustomobject]@{ Healthy = $false; Degraded = $false; Path = 'none'; Reason = 'no uplink'; Verdicts = @() }
        $first = Invoke-Gate
        $second = Invoke-Gate
        Assert-True ($first.Ok -and $second.Ok) 'a transient loss does not darken the host'
        Assert-Equal -Expected 2 -Actual $second.Streak
        $third = Invoke-Gate
        Assert-False $third.Ok 'the third consecutive loss refuses the cycle'
        Assert-Equal -Expected 'swept one VM' -Actual ($third.SweepOutput -join '|') -Because 'the caller prints the sweep output'
        $record = Get-Content -Raw -LiteralPath $third.StateFile | ConvertFrom-Json
        Assert-True ([string]$record.sweptUtc) 'the sweep is remembered for this loss'
        $fourth = Invoke-Gate
        Assert-False $fourth.Ok 'still refused'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Invoke-BoundedNativeCommand -Times 1 -Exactly
    }

    It 'keeps a degraded host''s banner and counts the same condition across cycles' {
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $true; Path = 'default-switch'; Reason = 'bridge lost'
            Verdicts = @([pscustomobject]@{ Switch = 'External A'; Verdict = 'uplink-down' }) }
        $first = Invoke-Gate
        $second = Invoke-Gate
        Assert-True ($first.Ok -and $second.Ok) 'a degraded host still runs'
        $record = Get-Content -Raw -LiteralPath $second.RecordFile | ConvertFrom-Json
        Assert-Equal -Expected 2 -Actual ([int]$record.consecutiveCycles)
        Assert-Match -Pattern 'External A' -Actual (Get-Content -Raw -LiteralPath $second.BannerFile)
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-HostRegistrationRecord -Times 1 -Exactly -Because 'only the appearance is a transition'
    }

    It 'clears the banner when a probe that ran finds the host whole, and not on no opinion' {
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $true; Path = 'default-switch'; Reason = 'bridge lost'
            Verdicts = @([pscustomobject]@{ Switch = 'External A'; Verdict = 'uplink-down' }) }
        $degraded = Invoke-Gate
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $false; Path = 'unknown'; Reason = 'no probe'; Verdicts = @() }
        $null = Invoke-Gate
        Assert-True (Test-Path -LiteralPath $degraded.RecordFile) 'no opinion keeps the finding'
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $false; Path = 'external'; Reason = 'fine'; Verdicts = @() }
        $null = Invoke-Gate
        Assert-False (Test-Path -LiteralPath $degraded.RecordFile) 'a whole host clears the record'
        Assert-False (Test-Path -LiteralPath $degraded.BannerFile) 'and the banner'
    }
}

Describe 'the cycle-start service-VM restore' {
    BeforeAll {
        Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
        Import-Module (Join-Path $here 'Test.HostRefreshTrigger.psm1') -Global -DisableNameChecking
        $script:Runtime = Join-Path $TestDrive 'restore-runtime'
        $null = New-Item -ItemType Directory -Force -Path $script:Runtime
    }
    BeforeEach {
        $script:SavedGeneration = Save-YurunaTestEnvironment -Name 'YURUNA_CYCLE_GENERATION'
        $script:Keys = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.RunnerInnerLoop Format-YurunaOperatorMessage { $script:Keys.Add($Key); $Key }
        Mock -ModuleName Test.RunnerInnerLoop Write-YurunaServiceVmRestoreReport { }
        Mock -ModuleName Test.RunnerInnerLoop Write-HostRefreshAutoEvidence { }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedGeneration }

    It 'reports what the restore returned and leaves the evidence tagged with this cycle''s generation' {
        $env:YURUNA_CYCLE_GENERATION = '7'
        Mock -ModuleName Test.RunnerInnerLoop Restore-YurunaServiceVM { @([pscustomobject]@{ Key = 'stash'; Outcome = 'started' }) }
        $restore = Invoke-CycleServiceVmRestore -HostType 'host.ubuntu.kvm' -RuntimeDir $script:Runtime 3>$null
        Assert-True $restore.Attempted 'the restore ran'
        Assert-Equal -Expected 'stash' -Actual $restore.Results[0].Key
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-YurunaServiceVmRestoreReport -Times 1 -Exactly -ParameterFilter { $Result[0].Key -eq 'stash' }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-HostRefreshAutoEvidence -Times 1 -Exactly -ParameterFilter {
            $Generation -eq '7' -and $Phase -eq 'service-vm-restore' -and $RuntimeDir -eq $script:Runtime -and $ServiceRestoreResult[0].Key -eq 'stash' }
        Assert-True $restore.EvidenceWritten 'the evidence was written'
    }

    It 'never stops the cycle when the restore throws, and still leaves empty evidence' {
        $env:YURUNA_CYCLE_GENERATION = '8'
        Mock -ModuleName Test.RunnerInnerLoop Restore-YurunaServiceVM { throw 'hypervisor busy' }
        $restore = Invoke-CycleServiceVmRestore -HostType 'host.ubuntu.kvm' -RuntimeDir $script:Runtime 3>$null
        Assert-Equal -Expected 0 -Actual @($restore.Results).Count
        Assert-True ($script:Keys -contains 'runner.operator_96a9c1c4155d58e1') 'the failure is warned'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-HostRefreshAutoEvidence -Times 1 -Exactly -ParameterFilter { @($ServiceRestoreResult).Count -eq 0 }
    }

    It 'writes no evidence without a generation from the outer loop' {
        $env:YURUNA_CYCLE_GENERATION = ''
        Mock -ModuleName Test.RunnerInnerLoop Restore-YurunaServiceVM { @() }
        $restore = Invoke-CycleServiceVmRestore -HostType 'host.ubuntu.kvm' -RuntimeDir $script:Runtime 3>$null
        Assert-False $restore.EvidenceWritten 'no generation, no evidence'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-HostRefreshAutoEvidence -Times 0 -Exactly
    }

    It 'keeps the evidence failure from reaching the cycle' {
        $env:YURUNA_CYCLE_GENERATION = '9'
        Mock -ModuleName Test.RunnerInnerLoop Restore-YurunaServiceVM { @() }
        Mock -ModuleName Test.RunnerInnerLoop Write-HostRefreshAutoEvidence { throw 'sidecar unwritable' }
        $restore = Invoke-CycleServiceVmRestore -HostType 'host.ubuntu.kvm' -RuntimeDir $script:Runtime 3>$null
        Assert-False $restore.EvidenceWritten 'the write failed'
        Assert-True ($script:Keys -contains 'runner.refresh_trigger_call_failed') 'the failure is warned'
    }
}

Describe 'the cycle-start External vSwitch repair' {
    BeforeAll {
        Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
        # Only the Hyper-V driver defines the repair; a stand-in lets it be mocked here.
        function global:Repair-YurunaExternalSwitch {
            [CmdletBinding(SupportsShouldProcess)]
            [OutputType([bool])]
            param()
            if ($PSCmdlet.ShouldProcess('External vSwitch', 'Repair')) { return $false }
            return $false
        }
    }
    AfterAll { Remove-Item -LiteralPath Function:\Repair-YurunaExternalSwitch -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:Net = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Net
        $script:Files = @{
            StateFile = Join-Path $script:Net 'runner.hostNetwork.json'
            BannerFile = Join-Path $script:Net 'host-network.txt'
            RecordFile = Join-Path $script:Net 'host-network.json'
        }
        foreach ($path in $script:Files.Values) { Set-Content -LiteralPath $path -Value '{}' }
        Mock -ModuleName Test.RunnerInnerLoop Format-YurunaOperatorMessage { $Key }
        Mock -ModuleName Test.RunnerInnerLoop Write-HostRegistrationRecord { }
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $false; Path = 'external' }
        Mock -ModuleName Test.RunnerInnerLoop Test-HostGuestNetworkHealth { $script:Health }
        function script:Invoke-Repair { $f = $script:Files; Invoke-CycleExternalSwitchRepair -HostType 'host.windows.hyper-v' -RepoRoot $TestDrive @f 3>$null 6>$null }
    }

    It 'clears the degraded pair and the loss streak once a repaired switch probes whole' {
        Mock -ModuleName Test.RunnerInnerLoop Repair-YurunaExternalSwitch { $true }
        $repair = Invoke-Repair
        Assert-True ($repair.Repaired -and $repair.Cleared) 'repaired and cleared'
        foreach ($path in $script:Files.Values) { Assert-False (Test-Path -LiteralPath $path) "$path is cleared" }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Write-HostRegistrationRecord -Times 1 -Exactly
    }

    It 'only ever clears: a repaired switch that still probes degraded keeps the gate''s record' {
        Mock -ModuleName Test.RunnerInnerLoop Repair-YurunaExternalSwitch { $true }
        $script:Health = [pscustomobject]@{ Healthy = $true; Degraded = $true; Path = 'default-switch' }
        $repair = Invoke-Repair
        Assert-False $repair.Cleared 'nothing cleared'
        foreach ($path in $script:Files.Values) { Assert-True (Test-Path -LiteralPath $path) "$path is kept" }
    }

    It 'does not probe again when the repair did nothing or threw' {
        Mock -ModuleName Test.RunnerInnerLoop Repair-YurunaExternalSwitch { $false }
        $declined = Invoke-Repair
        Mock -ModuleName Test.RunnerInnerLoop Repair-YurunaExternalSwitch { throw 'rebind failed' }
        $threw = Invoke-Repair
        Assert-True ($declined.Attempted -and $threw.Attempted) 'both attempted'
        Assert-False ($declined.Repaired -or $threw.Repaired) 'neither repaired'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Test-HostGuestNetworkHealth -Times 0 -Exactly
        foreach ($path in $script:Files.Values) { Assert-True (Test-Path -LiteralPath $path) "$path is kept" }
    }

    It 'pays no second probe on a host that had no degraded record' {
        Mock -ModuleName Test.RunnerInnerLoop Repair-YurunaExternalSwitch { $true }
        Remove-Item -LiteralPath $script:Files.RecordFile
        $null = Invoke-Repair
        Should -Invoke -ModuleName Test.RunnerInnerLoop Test-HostGuestNetworkHealth -Times 0 -Exactly
    }
}

Describe 'the cycle-start caching-proxy gate' {
    BeforeAll {
        Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
        Import-Module (Join-Path $here 'Test.CachingProxyService.psm1') -Global -DisableNameChecking
        $script:Runtime = Join-Path $TestDrive 'proxy-runtime'
        $null = New-Item -ItemType Directory -Force -Path $script:Runtime
    }
    BeforeEach {
        $script:SavedProxyIp = Save-YurunaTestEnvironment -Name 'YURUNA_CACHING_PROXY_SERVICE_IP'
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        Mock -ModuleName Test.RunnerInnerLoop Format-YurunaOperatorMessage { $Key }
        Mock -ModuleName Test.RunnerInnerLoop Enter-CachingProxyServiceLock { @{ Acquired = $true; PidPath = 'held' } }
        Mock -ModuleName Test.RunnerInnerLoop Exit-CachingProxyServiceLock { $true }
        Mock -ModuleName Test.RunnerInnerLoop Test-CachingProxyServiceAvailable { 'http://192.0.2.50:3128' }
        Mock -ModuleName Test.RunnerInnerLoop Get-CachingProxyServiceVmIp { '192.0.2.50' }
        Mock -ModuleName Test.RunnerInnerLoop Test-CacheVMOnExternalNetwork { $false }
        Mock -ModuleName Test.RunnerInnerLoop Test-HostOwnIpAddress { $false }
        Mock -ModuleName Test.RunnerInnerLoop Get-HostOwnIpVerdict { 'nonlocal' }
        Mock -ModuleName Test.RunnerInnerLoop Get-BestHostIp { '192.0.2.10' }
        Mock -ModuleName Test.RunnerInnerLoop Add-PortMap { $true }
        Mock -ModuleName Test.RunnerInnerLoop Remove-PortMap { $true }
        function script:Invoke-ProxyGate { param($Config = @{}) Invoke-CycleCachingProxyGate -Config $Config -RuntimeDir $script:Runtime 3>$null 6>$null }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedProxyIp }

    It 'forwards the exposed ports to a NAT''d local cache under the caching-proxy-service owner' {
        $gate = Invoke-ProxyGate
        Assert-Equal -Expected 'http://192.0.2.50:3128' -Actual $gate.CachingProxyUrl
        Should -Invoke -ModuleName Test.RunnerInnerLoop Add-PortMap -Times 1 -Exactly -ParameterFilter {
            $Owner -eq 'caching-proxy-service' -and $VMIp -eq '192.0.2.50' -and $PortRemap[8022] -eq 22 -and @($Port) -contains 3000 }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 0 -Exactly
        Assert-True ($gate.Output -contains 'runner.operator_39426f6aa7b04537') 'the proxy is reported detected'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Exit-CachingProxyServiceLock -Times 1 -Exactly
    }

    It 'removes the forwarders for a positively external endpoint and forwards nothing' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.0.2.50'
        Mock -ModuleName Test.RunnerInnerLoop Resolve-CachingProxyServiceEndpoint { [pscustomobject]@{ Lines = @('probe line'); EffectiveIp = '192.0.2.50' } }
        $gate = Invoke-ProxyGate
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 1 -Exactly -ParameterFilter { $Owner -eq 'caching-proxy-service' }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Add-PortMap -Times 0 -Exactly
        Assert-Equal -Expected 'probe line' -Actual $gate.Output[0] -Because 'the resolver''s lines come first'
    }

    It 'treats an "external" endpoint this host may own as local and keeps its forwarders' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.0.2.50'
        Mock -ModuleName Test.RunnerInnerLoop Resolve-CachingProxyServiceEndpoint { [pscustomobject]@{ Lines = @(); EffectiveIp = '192.0.2.50' } }
        Mock -ModuleName Test.RunnerInnerLoop Get-HostOwnIpVerdict { 'unknown' }
        $gate = Invoke-ProxyGate
        Assert-True ($gate.Output -contains 'runner.operator_76d8c741d7d223ad') 'the self-ownership is reported'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Add-PortMap -Times 1 -Exactly
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 0 -Exactly
    }

    It 'publishes the effective endpoint a reachable config address resolves to' {
        Mock -ModuleName Test.RunnerInnerLoop Resolve-CachingProxyServiceEndpoint { [pscustomobject]@{ Lines = @(); EffectiveIp = '192.0.2.77' } }
        $null = Invoke-ProxyGate -Config @{ vmStart = @{ cachingProxyIp = ' 192.0.2.77 ' } }
        Should -Invoke -ModuleName Test.RunnerInnerLoop Resolve-CachingProxyServiceEndpoint -Times 1 -Exactly -ParameterFilter { $ConfigIp -eq '192.0.2.77' -and $EnvIp -eq '' }
        Assert-Equal -Expected '192.0.2.77' -Actual $env:YURUNA_CACHING_PROXY_SERVICE_IP
    }

    It 'keeps the serving port map when the target resolves to this host''s own address' {
        Mock -ModuleName Test.RunnerInnerLoop Test-HostOwnIpAddress { $true }
        $gate = Invoke-ProxyGate
        Should -Invoke -ModuleName Test.RunnerInnerLoop Add-PortMap -Times 0 -Exactly
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 0 -Exactly
        Assert-True ($gate.Output -contains 'runner.operator_39426f6aa7b04537') 'still reported detected'
    }

    It 'leaves the port maps alone while a bring-up holds the port-map lock' {
        Mock -ModuleName Test.RunnerInnerLoop Enter-CachingProxyServiceLock { @{ Acquired = $false; PidPath = $null } }
        $gate = Invoke-ProxyGate
        Assert-Equal -Expected @('runner.operator_f5d13a74fd026605') -Actual @($gate.Output)
        Should -Invoke -ModuleName Test.RunnerInnerLoop Add-PortMap -Times 0 -Exactly
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 0 -Exactly
        Should -Invoke -ModuleName Test.RunnerInnerLoop Exit-CachingProxyServiceLock -Times 0 -Exactly
    }

    It 'keeps this host''s forwarders on a missed probe when the operator''s endpoint may be this host' {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.0.2.10'
        Mock -ModuleName Test.RunnerInnerLoop Resolve-CachingProxyServiceEndpoint { [pscustomobject]@{ Lines = @(); EffectiveIp = '192.0.2.10' } }
        Mock -ModuleName Test.RunnerInnerLoop Test-CachingProxyServiceAvailable { $null }
        Mock -ModuleName Test.RunnerInnerLoop Get-HostOwnIpVerdict { 'local' }
        $gate = Invoke-ProxyGate
        Assert-True ($gate.Output -contains 'runner.operator_32de3de6b68e1ac1') 'the kept forwarders are reported'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 0 -Exactly
    }

    It 'removes the forwarders on a missed probe with no endpoint that could be this host' {
        Mock -ModuleName Test.RunnerInnerLoop Test-CachingProxyServiceAvailable { $null }
        $gate = Invoke-ProxyGate
        Assert-True ($gate.Output -contains 'runner.operator_fe40f9dec8593d1a') 'the missing proxy is reported'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Remove-PortMap -Times 1 -Exactly
        Assert-Equal -Expected '' -Actual ([string]$gate.CachingProxyUrl)
    }

    It 'releases the port-map lock when the port map throws' {
        Mock -ModuleName Test.RunnerInnerLoop Add-PortMap { throw 'netsh failed' }
        { Invoke-ProxyGate } | Should -Throw -ExpectedMessage '*netsh failed*'
        Should -Invoke -ModuleName Test.RunnerInnerLoop Exit-CachingProxyServiceLock -Times 1 -Exactly
    }
}

Describe 'the inner runner calls the cycle-start gates instead of carrying them inline' {
    It 'leaves no port map, restore or switch repair call in the entry script' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Invoke-TestRunnerInnerLoop.ps1'), [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($inline in 'Add-PortMap', 'Remove-PortMap', 'Restore-YurunaServiceVM', 'Repair-YurunaExternalSwitch', 'Enter-CachingProxyServiceLock') {
            Assert-False ($names -contains $inline) "$inline belongs to a cycle-start gate function"
        }
        foreach ($gate in 'Invoke-CycleServiceVmRestore', 'Invoke-CycleExternalSwitchRepair', 'Invoke-CycleCachingProxyGate') {
            Assert-True ($names -contains $gate) "the entry script calls $gate"
        }
    }
}
