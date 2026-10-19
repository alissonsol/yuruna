<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42bb9ef7-db75-4e0a-a393-c189a531d90c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host diagnostics performance pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Verify the host sampler's reduced wakeup and capability-resolution cadence.
.DESCRIPTION
    Invoke-YurunaHostSampling returns at once off Windows, so its loop is
    exercised with $IsWindows shadowed to $true inside Test.HostSampling's own
    module scope (the same technique Test.HostMetricsExporter.Tests.ps1 and
    Test.ServiceMiscScripts.Tests.ps1 use), rather than skipped on this host:
    the loop body itself touches nothing Windows-specific once its collaborators
    are mocked, so there is no reason to leave the mechanism unverified here.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostMetricsExporter.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Force -Global
    InModuleScope Test.HostSampling { Set-Variable -Name IsWindows -Value $true -Scope Script }
    function Initialize-SamplingFixture {
        <# .SYNOPSIS
            Mocks the collaborators every scenario below needs, leaving the VM
            snapshot (and anything else a scenario varies) for the caller.
        #>
        Mock Get-YurunaHostSampleInfo -ModuleName Test.HostSampling { [pscustomobject]@{ Host = 'fixture' } }
        Mock Get-YurunaHostCounterInventory -ModuleName Test.HostSampling { [pscustomobject]@{ Status = 'present'; Reason = ''; Localization = 'unavailable'; NameMap = @{}; CounterSets = @() } }
        Mock Get-YurunaHostPowerStatus -ModuleName Test.HostSampling { [pscustomobject]@{ Status = 'present'; Source = 'AC'; BatteryPercent = $null } }
        Mock Invoke-YurunaHostMetricsProbe -ModuleName Test.HostSampling { '' }
        Mock Get-YurunaHostMetricsCapability -ModuleName Test.HostSampling { [pscustomobject]@{ Status = 'absent' } }
    }
    function Get-WrittenSampleRecord {
        <# .SYNOPSIS
            Every 'sample' record a run wrote, oldest first.
        #>
        param([Parameter(Mandatory)][string]$Directory)
        $segments = @(Get-ChildItem -LiteralPath $Directory -Filter 'samples.*.ndjson' -ErrorAction SilentlyContinue | Sort-Object Name)
        $records = @(foreach ($segment in $segments) { Get-Content -LiteralPath $segment.FullName | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } })
        , @($records | Where-Object Kind -EQ 'sample')
    }
}
AfterAll {
    InModuleScope Test.HostSampling { Remove-Variable -Name IsWindows -Scope Script -ErrorAction SilentlyContinue }
}
Describe 'host sampler cadence' {
    It 'resolves capabilities again only when the running-VM count changes' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'resolve'
        # Mutated from inside a Mock body, which Pester invokes as a detached
        # call each time: a plain local here would not persist between calls.
        $script:Counts = @(1, 1, 1, 0, 0)
        $script:CountIndex = 0
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling {
            $count = $script:Counts[$script:CountIndex]
            $script:CountIndex++
            if ($script:CountIndex -ge $script:Counts.Count) { [IO.File]::WriteAllText((Join-Path $directory 'stop'), '') }
            [pscustomobject]@{ Status = 'present'; RunningCount = $count; VMs = @() }
        }
        Mock Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling { @() }

        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 1 -OwnerProcessId $PID

        Should -Invoke Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling -Times 2 -Exactly
        (Get-WrittenSampleRecord -Directory $directory).Count | Should -Be 5
    }
    It 'reuses the same capability object across samples the running-VM count does not change' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'reuse'
        $script:ReuseCallCount = 0
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling {
            $script:ReuseCallCount++
            if ($script:ReuseCallCount -ge 3) { [IO.File]::WriteAllText((Join-Path $directory 'stop'), '') }
            [pscustomobject]@{ Status = 'present'; RunningCount = 1; VMs = @() }
        }
        Mock Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling { @([pscustomobject]@{ Object = 'fixture'; Status = 'present'; Paths = @() }) }

        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 1 -OwnerProcessId $PID

        $records = Get-WrittenSampleRecord -Directory $directory
        $records.Count | Should -Be 3
        # Same values on every record, not merely the same shape: this is
        # what makes the skipped re-resolution unobservable to a reader.
        ($records[0].Capabilities[0].Object) | Should -Be ($records[2].Capabilities[0].Object)
    }
    It 'writes the same record keys as before the cadence change' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'keys'
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling {
            [IO.File]::WriteAllText((Join-Path $directory 'stop'), '')
            [pscustomobject]@{ Status = 'present'; RunningCount = 0; VMs = @() }
        }
        Mock Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling { @() }

        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 1 -OwnerProcessId $PID

        $records = Get-WrittenSampleRecord -Directory $directory
        $records.Count | Should -Be 1
        ($records[0].PSObject.Properties.Name | Sort-Object) -join ',' | Should -Be (('Kind', 'Utc', 'MonotonicTicks', 'MonotonicFrequency', 'ClockDomain', 'Power', 'Vm', 'Capabilities', 'Counters', 'CounterStatus', 'CounterReason', 'Exporter', 'CollectionSeconds' | Sort-Object) -join ',')
    }
    It 'ends the loop at once when the owner process is already gone' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'owner-gone'
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling { throw 'must not sample once the owner is gone' }
        $dead = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'exit 0' -PassThru
        $dead.WaitForExit()

        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 1 -OwnerProcessId $dead.Id

        (Get-WrittenSampleRecord -Directory $directory).Count | Should -Be 0
    }
    It 'makes no Start-Sleep call in the inner wait when an owner handle is present' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'wait-handle'
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling {
            [IO.File]::WriteAllText((Join-Path $directory 'stop'), '')
            [pscustomobject]@{ Status = 'present'; RunningCount = 0; VMs = @() }
        }
        Mock Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling { @() }
        Mock Start-Sleep -ModuleName Test.HostSampling {}

        $watch = [Diagnostics.Stopwatch]::StartNew()
        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 10 -OwnerProcessId $PID
        $watch.Stop()

        Should -Invoke Start-Sleep -ModuleName Test.HostSampling -Times 0 -Exactly
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
    It 'falls back to a counted Start-Sleep when no owner handle is available' {
        Initialize-SamplingFixture
        $directory = Join-Path $TestDrive 'wait-sleep'
        $script:FallbackCallCount = 0
        Mock Get-YurunaHostVmSnapshot -ModuleName Test.HostSampling {
            $script:FallbackCallCount++
            if ($script:FallbackCallCount -ge 2) { [IO.File]::WriteAllText((Join-Path $directory 'stop'), '') }
            [pscustomobject]@{ Status = 'present'; RunningCount = 0; VMs = @() }
        }
        Mock Resolve-YurunaHostCounterCapability -ModuleName Test.HostSampling { @() }
        Mock Start-Sleep -ModuleName Test.HostSampling {}

        Invoke-YurunaHostSampling -Directory $directory -DurationSeconds 30 -IntervalSeconds 2 -OwnerProcessId 0

        Should -Invoke Start-Sleep -ModuleName Test.HostSampling -Times 1
    }
}
Describe 'host sampler inner loop source' {
    It 'does not look up the owner process or wake ten times a second inside the inner wait' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.HostSampling.psm1'), [ref]$null, [ref]$null)
        $function = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-YurunaHostSampling' }, $true)
        $innerLoop = $function.Body.FindAll({ param($n) $n -is [Management.Automation.Language.WhileStatementAst] }, $true) | Select-Object -Last 1
        $innerLoop.Extent.Text | Should -Not -Match 'Get-Process'
        $innerLoop.Extent.Text | Should -Not -Match 'Min\(100'
    }
}
