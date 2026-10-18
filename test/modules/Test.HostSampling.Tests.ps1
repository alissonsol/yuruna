<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42d3bc19-cf65-4604-a69f-39ddfab7231d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host diagnostics performance pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Verify retained host evidence, counter availability, and process deadlines.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.HostMetricsExporter.psm1') -Force
}
Describe 'host counter capability and cooked samples' {
    It 'adds at most twelve actual inventory rates without treating overlapping rates as causes' {
        $paths = @(1..20 | ForEach-Object { '\Hyper-V Hypervisor Virtual Processor(*)\Diagnostic Fault {0:00}/sec' -f $_ })
        $paths += '\Hyper-V Hypervisor Virtual Processor(*)\Unrelated Rate/sec'
        $sets = @([pscustomobject]@{ CounterSetName='Hyper-V Hypervisor Virtual Processor'; Paths=$paths })
        $rows = @(Resolve-YurunaHostCounterCapability -CounterSets $sets -RunningVmCount 1)
        $extra = @($rows | Where-Object Counter -Like 'Diagnostic Fault*')
        $extra.Count | Should -Be 12
        @($extra | Where-Object Status -NE present).Count | Should -Be 0
        $rows.Counter | Should -Not -Contain 'Unrelated Rate/sec'
    }
    It 'resolves additional inventory rates through the English name map' {
        $map = @{ 'Hyper-V Hypervisor Virtual Processor'='Prozessor'; 'New Faults/sec'='Neue Fehler/s' }
        $sets = @([pscustomobject]@{ CounterSetName='Prozessor'; Paths=@('\Prozessor(*)\Neue Fehler/s') })
        $row = Resolve-YurunaHostCounterCapability -CounterSets $sets -NameMap $map -RunningVmCount 1 | Where-Object Counter -EQ 'New Faults/sec'
        $row.Status | Should -Be present
        $row.LocalCounter | Should -Be 'Neue Fehler/s'
    }
    It 'resolves actual localized paths without guessing translated names' {
        $map=@{'Hyper-V Hypervisor Virtual Processor'='Prozessor'; '% Guest Run Time'='Gastzeit'}
        $sets=@([pscustomobject]@{CounterSetName='Prozessor'; Paths=@('\Prozessor(*)\Gastzeit')})
        $rows=@(Resolve-YurunaHostCounterCapability -CounterSets $sets -NameMap $map -RunningVmCount 1)
        $guest=$rows | Where-Object { $_.Object -eq 'Hyper-V Hypervisor Virtual Processor' -and $_.Counter -eq '% Guest Run Time' }
        $guest.Status | Should -Be 'present'
        $guest.Paths | Should -Be '\Prozessor(*)\Gastzeit'
        ($rows | Where-Object Counter -EQ 'Total Intercepts/sec' | Select-Object -First 1).Status | Should -Be 'absent'
    }
    It 'treats the virtual network adapter and switch port objects as guest counters' {
        $rows = @(Resolve-YurunaHostCounterCapability -CounterSets @() -RunningVmCount 0)
        foreach ($object in 'Hyper-V Virtual Network Adapter', 'Hyper-V Virtual Switch Port') {
            $row = $rows | Where-Object Object -EQ $object | Select-Object -First 1
            $row | Should -Not -BeNullOrEmpty -Because "$object must be part of the bounded counter set"
            $row.Guest | Should -BeTrue
            $row.Status | Should -Be 'not-applicable'
        }
        @($rows | Where-Object { $_.Object -eq 'Hyper-V Virtual Network Adapter' -and $_.Counter -eq 'Dropped Packets Incoming/sec' }).Count | Should -Be 1
    }
    It 'distinguishes an idle host from unknown VM enumeration' {
        (@(Resolve-YurunaHostCounterCapability -CounterSets @() -RunningVmCount 0) | Where-Object Guest | Select-Object -First 1).Status | Should -Be 'not-applicable'
        (@(Resolve-YurunaHostCounterCapability -CounterSets @() -RunningVmCount $null) | Where-Object Guest | Select-Object -First 1).Status | Should -Be 'absent'
    }
    It 'keeps zero and new data but drops total instances and marks invalid samples unavailable' {
        $samples = foreach ($case in @(@('vm:0',0,0),@('vm:1',1,2),@('_Total',0,9),@('0,_Total',0,9),@('bad',5,9))) {
            [pscustomobject]@{Path="\object($($case[0]))\counter"; InstanceName=$case[0]; Status=$case[1]; CookedValue=$case[2]; CounterType='AverageTimer32'; RawValue=123; SecondValue=456; Timestamp100NSec=789}
        }
        $rows=@(ConvertTo-YurunaHostCounterSample -CounterSamples $samples)
        $rows.Count | Should -Be 3
        $rows[0].Value | Should -Be 0
        $rows[1].Status | Should -Be 'present'
        $rows[1].SecondValue | Should -Be 456
        $rows[2].Status | Should -Be 'absent'
        $rows[2].Value | Should -BeNullOrEmpty
    }
}
Describe 'durable bounded host evidence' {
    It 'rotates owned segments and keeps the newest complete records' {
        $directory=Join-Path $TestDrive 'ring'
        foreach ($number in 1..8) { Write-YurunaHostSampleRecord -Directory $directory -Record @{ Number=$number; Payload=('a'*70) } -SegmentBytes 120 -MaximumSegments 3 }
        $files=@(Get-ChildItem $directory -Filter 'samples.*.ndjson' | Sort-Object Name)
        $files.Count | Should -Be 3
        (Get-Content $files[-1].FullName -Raw | ConvertFrom-Json).Number | Should -Be 8
    }
    It 'copies only complete lines and owned evidence files before diagnostics' {
        $runtime=Join-Path $TestDrive 'runtime'; $source=Join-Path $runtime 'host-sampling/owned'
        $null=New-Item -ItemType Directory $source -Force
        [IO.File]::WriteAllText((Join-Path $source 'samples.000000.ndjson'), "{`"ok`":true}`n{`"half`":")
        Set-Content (Join-Path $source 'unrelated.txt') 'keep private'
        @{Directory=$source} | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $result=Save-YurunaHostSampleSnapshot -RuntimeDirectory $runtime -DestinationDirectory (Join-Path $TestDrive 'cycle')
        $result.Status | Should -Be 'partial'
        (Get-Content (Join-Path $result.Path 'samples.000000.ndjson') -Raw | ConvertFrom-Json).ok | Should -BeTrue
        Test-Path (Join-Path $result.Path 'unrelated.txt') | Should -BeFalse
    }
    It 'writes an explicit fallback when no sampler exists and rejects out-of-root pointers' {
        $runtime=Join-Path $TestDrive 'absent'; $null=New-Item -ItemType Directory $runtime
        @{Directory=$TestDrive} | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $result=Save-YurunaHostSampleSnapshot -RuntimeDirectory $runtime -DestinationDirectory (Join-Path $TestDrive 'fallback')
        $result.Status | Should -Be 'unavailable'
        (Get-Content (Join-Path $result.Path 'snapshot.json') -Raw | ConvertFrom-Json).Status | Should -Be 'unavailable'
    }
    It 'clears a previous recording pointer when sampling is disabled' {
        $before=$env:YURUNA_HOST_SAMPLING_DISABLED
        try {
            $env:YURUNA_HOST_SAMPLING_DISABLED='1'; $runtime=Join-Path $TestDrive 'disabled'
            $null=Start-YurunaHostSampling -RuntimeDirectory $runtime -Confirm:$false
            (Get-Content (Join-Path $runtime 'host-sampling.current.json') -Raw | ConvertFrom-Json).Directory | Should -BeNullOrEmpty
        } finally { $env:YURUNA_HOST_SAMPLING_DISABLED=$before }
    }
    It 'bounds a stuck native probe and retains output produced before timeout' {
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $result=Invoke-YurunaHostBoundedCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Write-Output evidence; Start-Sleep -Seconds 30') -TimeoutSeconds 1
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 5
        $result.Status | Should -Be 'timeout'
        $result.Output | Should -Match 'evidence'
    }
    It 'passes diagnostic text over standard input without shell quoting' {
        $result=Invoke-YurunaHostBoundedCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','[Console]::In.ReadToEnd()') -InputText 'literal $value and `ticks'
        $result.ExitCode | Should -Be 0
        $result.Output.Trim() | Should -Be 'literal $value and `ticks'
    }
}
Describe 'host-sample evidence stays small' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
        $script:CounterInventoryStub=$null
        if (-not (Get-Command 'Get-Counter' -ErrorAction SilentlyContinue)) {
            $script:CounterInventoryStub=New-Module -ScriptBlock {
                function Get-Counter { <# .SYNOPSIS
                    Stub counter-set enumeration for evidence tests off Windows.
                #>
                    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                        Justification = 'Accepts the real cmdlet''s -ListSet so the call binds; the one scripted fixture answers the same way regardless of the wildcard.')]
                    [CmdletBinding()] param($ListSet)
                    [pscustomobject]@{CounterSetName='System'; Paths=@('\System\Context Switches/sec'); PathsWithInstances=@('\System(0)\Context Switches/sec','\System(1)\Context Switches/sec'); Description='stub'}
                }
                Export-ModuleMember -Function Get-Counter
            }
            Import-Module $script:CounterInventoryStub -Global
        }
    }
    AfterAll { if ($script:CounterInventoryStub) { Remove-Module $script:CounterInventoryStub -Force } }
    It 'copies a segment ending mid-line up to and including its last newline' {
        $runtime=Join-Path $TestDrive 'runtime-mid'; $source=Join-Path $runtime 'host-sampling/owned'
        $null=New-Item -ItemType Directory $source -Force
        [IO.File]::WriteAllBytes((Join-Path $source 'samples.000000.ndjson'), [Text.Encoding]::UTF8.GetBytes("{`"ok`":true}`n{`"half`":"))
        @{Directory=$source} | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $result=Save-YurunaHostSampleSnapshot -RuntimeDirectory $runtime -DestinationDirectory (Join-Path $TestDrive 'cycle-mid')
        [IO.File]::ReadAllBytes((Join-Path $result.Path 'samples.000000.ndjson')) | Should -Be ([Text.Encoding]::UTF8.GetBytes("{`"ok`":true}`n"))
    }
    It 'copies a segment with no newline as empty' {
        $runtime=Join-Path $TestDrive 'runtime-none'; $source=Join-Path $runtime 'host-sampling/owned'
        $null=New-Item -ItemType Directory $source -Force
        [IO.File]::WriteAllBytes((Join-Path $source 'samples.000000.ndjson'), [Text.Encoding]::UTF8.GetBytes('no newline at all'))
        @{Directory=$source} | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $result=Save-YurunaHostSampleSnapshot -RuntimeDirectory $runtime -DestinationDirectory (Join-Path $TestDrive 'cycle-none')
        (Get-Item (Join-Path $result.Path 'samples.000000.ndjson')).Length | Should -Be 0
    }
    It 'copies a segment already ending in a newline whole' {
        $runtime=Join-Path $TestDrive 'runtime-whole'; $source=Join-Path $runtime 'host-sampling/owned'
        $null=New-Item -ItemType Directory $source -Force
        $content=[Text.Encoding]::UTF8.GetBytes("{`"a`":1}`n{`"b`":2}`n")
        [IO.File]::WriteAllBytes((Join-Path $source 'samples.000000.ndjson'), $content)
        @{Directory=$source} | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $result=Save-YurunaHostSampleSnapshot -RuntimeDirectory $runtime -DestinationDirectory (Join-Path $TestDrive 'cycle-whole')
        [IO.File]::ReadAllBytes((Join-Path $result.Path 'samples.000000.ndjson')) | Should -Be $content
    }
    It 'omits PathsWithInstances from the counter inventory' {
        $inventory=Get-YurunaHostCounterInventory
        @($inventory.CounterSets[0].PSObject.Properties.Name) | Should -Not -Contain 'PathsWithInstances'
    }
    It 'writes the counter inventory as a single compressed line' {
        # Invoke-YurunaHostSampling returns before this write on a non-Windows
        # host, so the write statement is read from source instead of driven
        # end to end.
        $functionAst=Get-YurunaTestFunctionAst -Path (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Name 'Invoke-YurunaHostSampling'
        $functionAst.Extent.Text | Should -Match "ConvertTo-Json -Depth 8 -Compress \| Set-Content -LiteralPath \(Join-Path \`$Directory 'counter-inventory\.json'\)"
    }
    It 'trims a segment without an object-array range allocation' {
        $functionAst=Get-YurunaTestFunctionAst -Path (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Name 'Save-YurunaHostSampleSnapshot'
        $rangeOverBytes=@($functionAst.FindAll({
                    param($n)
                    $n -is [Management.Automation.Language.BinaryExpressionAst] -and
                    $n.Operator -eq [Management.Automation.Language.TokenKind]::DotDot -and
                    $n.Parent -is [Management.Automation.Language.IndexExpressionAst] -and
                    $n.Parent.Target.Extent.Text -eq '$bytes'
                }, $true))
        $rangeOverBytes.Count | Should -Be 0
    }
}
Describe 'exporter capability is independent of host readiness' {
    It 'does not infer guest processor metrics from an unrelated Hyper-V metric' {
        $result=Get-YurunaHostMetricsCapability -Payload "windows_hyperv_virtual_machine_health_ok 1`n" -RunningVmCount 1
        $result.Status | Should -Be 'present'
        $result.Capabilities.GuestRuntime.Status | Should -Be 'absent'
        (Get-YurunaHostMetricsCapability -Payload '' -RunningVmCount 0).Capabilities.GuestRuntime.Status | Should -Be 'not-applicable'
    }
    It 'recognizes deployed and newer runtime spellings and records build identity' {
        $payload=@'
windows_hyperv_hypervisor_virtual_processor_time_total{vm="guest",state="guest"} 0
windows_hyperv_hypervisor_virtual_processor_mode_time_total{vm="guest",state="hypervisor"} 100
windows_exporter_build_info{version="0.31.8"} 1
'@
        $result=Get-YurunaHostMetricsCapability -Payload $payload -RunningVmCount 1
        $result.Capabilities.GuestRuntime.Status | Should -Be 'present'
        $result.Capabilities.GuestHypervisorRuntime.Status | Should -Be 'present'
        $result.BuildInfo | Should -Match '0.31.8'
    }
    It 'keeps the monitoring seed aligned with the runtime filter and excludes unrelated series' {
        $regex=Get-YurunaHostMetricsRetentionRegex
        $seed=Get-Content (Join-Path $PSScriptRoot '../../host/vmconfig/caching-proxy-service.base.user-data') -Raw
        $seed.Contains("regex: '$regex'") | Should -BeTrue
        'windows_hyperv_hypervisor_virtual_processor_mode_time_total' | Should -Match "^($regex)$"
        'windows_logical_disk_read_latency_seconds_total' | Should -Match "^($regex)$"
        'windows_process_cpu_time_total' | Should -Not -Match "^($regex)$"
        'windows_cs_hostname' | Should -Not -Match "^($regex)$"
    }
}
Describe 'service VM processor policy' {
    It 'applies the shared ARM64 clamp before configuring <_>' -ForEach @('caching-proxy','pool-control','stash','download-agent') {
        # The builder hands its host core count to the shared service-guest function, which owns the clamp.
        $builder=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "../../host/windows.hyper-v/guest.$_-service/New-VM.ps1")
        $builder | Should -Match 'New-HyperVServiceGuest\b[^\r\n]*-HostCores \$hostCores'
        $path=Join-Path $PSScriptRoot '../../host/windows.hyper-v/modules/Yuruna.Host.psm1'
        $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-HyperVServiceGuest'},$true)
        $assignments=@($function.Body.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$cores'},$true))
        $set=$function.Body.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-VMProcessor'},$true)
        $script:RequestedCount=0; $script:AppliedCount=0
        function Limit-HyperVLinuxGuestCoreCount { param($RequestedCores) $script:RequestedCount=$RequestedCores; return 2 }
        function Set-VMProcessor { [CmdletBinding(SupportsShouldProcess)] param($VMName,$Count) if ($PSCmdlet.ShouldProcess($VMName, 'Record fake processor count')) { $script:AppliedCount=$Count } }
        $fixtureText='param($HostCores,$VMName)' + "`
" + ((@($assignments | ForEach-Object { $_.Extent.Text }) + $set.Extent.Text) -join "`
")
        & ([scriptblock]::Create($fixtureText)) 16 'fixture'
        $script:RequestedCount | Should -Be 8
        $script:AppliedCount | Should -Be 2
    }
}
Describe 'VM resource configuration evidence' {
    BeforeAll {
        $script:HyperVSamplingStub=$null
        if (-not (Get-Command 'Hyper-V\Get-VM' -ErrorAction SilentlyContinue)) {
            $script:HyperVSamplingStub=New-Module -Name 'Hyper-V' -ScriptBlock {
                function Get-VM { <# .SYNOPSIS
                    Stub the VM census for offline evidence tests.
                #> [CmdletBinding()] param() throw 'Unexpected live VM query.' }
                function Get-VMProcessor { <# .SYNOPSIS
                    Stub processor settings for offline evidence tests.
                #> [CmdletBinding()] param($VM) throw "Unexpected processor query: $VM" }
                function Get-VMMemory { <# .SYNOPSIS
                    Stub memory settings for offline evidence tests.
                #> [CmdletBinding()] param($VM) throw "Unexpected memory query: $VM" }
                Export-ModuleMember -Function Get-VM,Get-VMProcessor,Get-VMMemory
            }
            Import-Module $script:HyperVSamplingStub -Global
        }
    }
    BeforeEach {
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VM' { [pscustomobject]@{Name='fixture'; Id='vm-id'; State='Running'; ProcessorCount=2; MemoryAssigned=4GB; MemoryStartup=4GB; DynamicMemoryEnabled=$true} }
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMProcessor' -RemoveParameterType 'VM' { [pscustomobject]@{Count=2; Reserve=0; Maximum=100; RelativeWeight=100; ExposeVirtualizationExtensions=$false; HwThreadCountPerCore=1; CompatibilityForMigrationEnabled=$false} }
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMMemory' -RemoveParameterType 'VM' { [pscustomobject]@{DynamicMemoryEnabled=$true; Minimum=2GB; Maximum=8GB; Startup=4GB; Buffer=20; Priority=50} }
    }
    AfterAll { if ($script:HyperVSamplingStub) { Remove-Module $script:HyperVSamplingStub -Force } }
    It 'retains processor policy and dynamic-memory bounds including valid zero and false values' {
        $result=Get-YurunaHostVmSnapshot
        $result.Status | Should -Be 'present'
        $result.RunningCount | Should -Be 1
        $result.VMs[0].Processor.Status | Should -Be 'present'
        $result.VMs[0].Processor.Values.Reserve | Should -Be 0
        $result.VMs[0].Processor.Values.ExposeVirtualizationExtensions | Should -BeFalse
        $result.VMs[0].Memory.Values.Maximum | Should -Be 8GB
        $result.VMs[0].Memory.Values.Buffer | Should -Be 20
    }
    It 'preserves the VM census and independent memory evidence when processor querying fails' {
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMProcessor' -RemoveParameterType 'VM' { throw 'access denied' }
        $result=Get-YurunaHostVmSnapshot
        $result.RunningCount | Should -Be 1
        $result.VMs[0].Processor.Status | Should -Be 'absent'
        $result.VMs[0].Processor.Reason | Should -Match 'access denied'
        $result.VMs[0].Memory.Status | Should -Be 'present'
    }
    It 'names unsupported configuration properties instead of reporting them as zero' {
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMMemory' -RemoveParameterType 'VM' { [pscustomobject]@{DynamicMemoryEnabled=$false; Startup=4GB} }
        $result=Get-YurunaHostVmSnapshot
        $result.VMs[0].Memory.Status | Should -Be 'partial'
        $result.VMs[0].Memory.UnavailableProperties | Should -Contain 'Buffer'
        $result.VMs[0].Memory.Values.Buffer | Should -BeNullOrEmpty
    }
}
Describe 'guest livelock verdict from host samples' {
    BeforeAll {
        $script:LivelockVm = 'test-guest.ubuntu.server.26-01'
        $script:LivelockNow = [datetime]::new(2026, 10, 6, 17, 39, 30, [DateTimeKind]::Utc)
        # One reading per sampler interval, newest last, ending at $script:LivelockNow.
        function New-RunSampleSeries {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory fixture; changes no state.')]
            param([int]$Count, [scriptblock]$Processors, [int]$IntervalSeconds = 15)
            foreach ($index in 0..($Count - 1)) {
                $utc = $script:LivelockNow.AddSeconds(-$IntervalSeconds * ($Count - 1 - $index))
                [pscustomobject]@{ Utc = $utc; VMs = @{ $script:LivelockVm = (& $Processors $index) } }
            }
        }
        function New-Processor {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory fixture; changes no state.')]
            param([double]$Guest, [double]$Hypervisor, [double]$Intercepts = 3690000, [hashtable]$Cause = @{})
            $reading = @{ '% Guest Run Time' = $Guest; '% Hypervisor Run Time' = $Hypervisor; 'Total Intercepts/sec' = $Intercepts }
            foreach ($name in $Cause.Keys) { $reading[$name] = $Cause[$name] }
            return $reading
        }
    }
    It 'calls a guest livelocked once every processor stays pinned for the whole window' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 4.8 -Hypervisor 94.1) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'livelocked'
        $verdict.LivelockedSeconds | Should -Be 300
        $verdict.VirtualProcessors | Should -Be 1
        $verdict.HypervisorRunPercent | Should -Be 94.1
        $verdict.Detail | Should -Match '300'
    }
    It 'ends the run at a sample that lists the VM as not running' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } })
        $powerOff = $script:LivelockNow.AddSeconds(15)
        $samples += [pscustomobject]@{ Utc = $powerOff; VMs = @{}; Running = @{} }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow.AddSeconds(20)
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 0
        $verdict.NewestSampleUtc | Should -Be $powerOff.ToString('o') -Because 'the power-off listing is the newest word on the guest'
    }
    It 'judges a boot after a power cycle on its own readings' {
        $previous = @(New-RunSampleSeries -Count 41 -Processors { @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } })
        $powerOff = $script:LivelockNow.AddSeconds(15)
        $samples = @($previous) + [pscustomobject]@{ Utc = $powerOff; VMs = @{}; Running = @{} }
        foreach ($index in 1..21) {
            $samples += [pscustomobject]@{ Utc = $powerOff.AddSeconds(15 * $index); VMs = @{ $script:LivelockVm = @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } } }
        }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $powerOff.AddSeconds(320)
        $verdict.Verdict | Should -Be 'livelocked'
        $verdict.LivelockedSeconds | Should -Be 300 -Because 'the 600 seconds before the power cycle must not count toward the new boot'
    }
    It 'keeps the run across a failed counter read while the host lists the guest as running' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } })
        $samples[10] = [pscustomobject]@{ Utc = $samples[10].Utc; VMs = @{}; Running = @{ $script:LivelockVm = $true } }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'livelocked' -Because 'a counter read that failed is a hole in the recording, not a power cycle'
        $verdict.LivelockedSeconds | Should -Be 300
    }
    It 'still ends the run when failed reads leave a hole past the gap limit' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } })
        foreach ($index in 9..11) { $samples[$index] = [pscustomobject]@{ Utc = $samples[$index].Utc; VMs = @{}; Running = @{ $script:LivelockVm = $true } } }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 120 -Because 'the 60 seconds without readings exceed the 45 second gap limit'
    }
    It 'refuses to judge when the newest listing of a stopped VM is too old' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 7.7 -Hypervisor 91.2) } })
        $samples += [pscustomobject]@{ Utc = $script:LivelockNow.AddSeconds(15); VMs = @{}; Running = @{} }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow.AddMinutes(10)
        $verdict.Verdict | Should -Be 'unavailable' -Because 'a power-off seen ten minutes ago says nothing about the guest now'
    }
    It 'judges only the readings at or after Since' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 4.8 -Hypervisor 94.1) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow -Since $script:LivelockNow.AddSeconds(-120)
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 120
    }
    It 'reads Since as an instant whatever Kind the caller passed' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 4.8 -Hypervisor 94.1) } })
        $local = $script:LivelockNow.AddSeconds(-120).ToLocalTime()
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow -Since $local
        $verdict.LivelockedSeconds | Should -Be 120 -Because 'the host time zone must not move the bound'
    }
    It 'reports unavailable when no reading for the VM falls after Since' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 4.8 -Hypervisor 94.1) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow -Since $script:LivelockNow.AddSeconds(30)
        $verdict.Verdict | Should -Be 'unavailable'
    }
    It 'keeps a pinned run shorter than the window below the verdict' {
        $samples = @(New-RunSampleSeries -Count 10 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 135
    }
    It 'does not count a processor parked in a spin wait while another works' {
        $samples = @(New-RunSampleSeries -Count 30 -Processors { @{ '0' = (New-Processor -Guest 7 -Hypervisor 91); '1' = (New-Processor -Guest 66 -Hypervisor 33 -Intercepts 1200000) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 0
        $verdict.ProcessorWindow.SampleCount | Should -Be 21
        $verdict.ProcessorWindow.Processors.Count | Should -Be 2
        $vp0 = $verdict.ProcessorWindow.Processors | Where-Object Processor -EQ '0'
        $vp1 = $verdict.ProcessorWindow.Processors | Where-Object Processor -EQ '1'
        $vp0.Counters['% Hypervisor Run Time'].Average | Should -Be 91
        $vp1.Counters['% Guest Run Time'].Average | Should -Be 66
        $vp1.Counters['Total Intercepts/sec'].Average | Should -Be 1200000
        $vp1.Counters['SysReg Accesses/sec'].Status | Should -Be unavailable
        $vp1.UnaccountedEstimatePerSecond | Should -BeNullOrEmpty
        $vp1.ResidualStatus | Should -Be 'unavailable-incomplete-counters'
    }
    It 'names the trapping processor and the moment the storm moved to its sibling' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors {
            param($index)
            if ($index -lt 14) {
                @{ '0' = (New-Processor -Guest 7 -Hypervisor 91 -Intercepts 3500000 -Cause @{ 'External Interrupts/sec' = 3499000 })
                   '1' = (New-Processor -Guest 40 -Hypervisor 6 -Intercepts 200000 -Cause @{ 'External Interrupts/sec' = 199000 }) }
            } else {
                @{ '0' = (New-Processor -Guest 40 -Hypervisor 7 -Intercepts 230000 -Cause @{ 'External Interrupts/sec' = 229000 })
                   '1' = (New-Processor -Guest 7 -Hypervisor 91 -Intercepts 3530000 -Cause @{ 'External Interrupts/sec' = 3529000 }) }
            }
        })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked' -Because 'one processor at a time is never the all-processor predicate'
        $window = $verdict.ProcessorWindow
        $vp1 = $window.Processors | Where-Object Processor -EQ '1'
        $vp1.Stormed | Should -BeTrue
        $vp1.DominantIntercept | Should -Be 'External Interrupts/sec'
        $window.StormedProcessors | Should -Contain '1'
        @($window.StormTransitions).Count | Should -Be 1
        @($window.StormTransitions[0].Processors) | Should -Be @('1')
        $window.StormTransitions[0].Utc | Should -Be $samples[14].Utc.ToString('o')
        ($window.Processors | Where-Object Processor -EQ '0').HypervisorShare | Should -BeGreaterThan 0.5
    }
    It 'leaves a quiet guest unflagged' {
        $samples = @(New-RunSampleSeries -Count 5 -Processors { @{ '0' = (New-Processor -Guest 30 -Hypervisor 5 -Intercepts 20000) } })
        $window = (Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow).ProcessorWindow
        $window.Processors[0].Stormed | Should -BeFalse
        $window.Processors[0].HypervisorShare | Should -BeLessThan 0.2
        @($window.StormedProcessors).Count | Should -Be 0
        @($window.StormTransitions).Count | Should -Be 0
    }
    It 'counts each available counter independently and retains capability failures' {
        $samples = @(New-RunSampleSeries -Count 3 -Processors {
            param($index)
            $vp = New-Processor -Guest 66 -Hypervisor 33
            if ($index -eq 0) { $vp['% Hypervisor Run Time'] = [double]::NaN }
            if ($index -eq 1) { $vp.Remove('Total Intercepts/sec') }
            @{ '0'=$vp }
        })
        $samples[-1] | Add-Member CounterCapabilities @([pscustomobject]@{ Counter='SMC Instructions/sec'; Status='absent'; Reason='not published' })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $vp = $verdict.ProcessorWindow.Processors[0]
        $vp.Counters['% Hypervisor Run Time'].Average | Should -Be 33
        $vp.Counters['% Hypervisor Run Time'].SampleCount | Should -Be 2
        $vp.Counters['% Hypervisor Run Time'].Status | Should -Be partial
        $vp.Counters['Total Intercepts/sec'].SampleCount | Should -Be 2
        $verdict.ProcessorWindow.CounterCapabilities[0].Reason | Should -Be 'not published'
        $verdict.Verdict | Should -Be 'not-livelocked'
    }
    It 'summarizes a fully measured residual on a working processor without granting recovery' {
        $samples = @(New-RunSampleSeries -Count 3 -Processors {
            $causes = @{}
            $names = & (Get-Module Test.HostSampling) { $script:LivelockCauseCounters }
            foreach ($name in $names) { $causes[$name] = 0.0 }
            $causes['Hypercalls/sec'] = 100.0
            @{ '0'=(New-Processor -Guest 66 -Hypervisor 33 -Intercepts 1200000 -Cause $causes) }
        })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.ProcessorWindow.Processors[0].UnaccountedEstimatePerSecond | Should -Be 1199900
        $verdict.ProcessorWindow.Processors[0].ResidualSampleCount | Should -Be 3
    }
    It 'reports a residual when architecture-specific counters are explicitly absent' {
        $samples = @(New-RunSampleSeries -Count 3 -Processors {
            $causes = @{}
            foreach ($name in (& (Get-Module Test.HostSampling) { $script:LivelockCauseCounters })) {
                if ($name -notin @('MSR Accesses/sec','IO Instructions/sec')) { $causes[$name]=0.0 }
            }
            @{ '0'=(New-Processor -Guest 66 -Hypervisor 33 -Intercepts 1200000 -Cause $causes) }
        })
        foreach ($sample in $samples) {
            $sample | Add-Member CounterCapabilities @(
                [pscustomobject]@{ Counter='MSR Accesses/sec'; Status='absent'; Reason='not published' },
                [pscustomobject]@{ Counter='IO Instructions/sec'; Status='absent'; Reason='not published' })
        }
        $vp = (Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow).ProcessorWindow.Processors[0]
        $vp.UnaccountedEstimatePerSecond | Should -Be 1200000
        $vp.ResidualUnavailableCounters | Should -Contain 'MSR Accesses/sec'
        $vp.Counters['MSR Accesses/sec'].Status | Should -Be unavailable
    }
    It 'does not count a healthy installer that shares its time with the hypervisor' {
        $samples = @(New-RunSampleSeries -Count 30 -Processors { @{ '0' = (New-Processor -Guest 27 -Hypervisor 71 -Intercepts 2690000) } })
        (Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow).Verdict | Should -Be 'not-livelocked'
    }
    It 'neither extends nor ends the run on an over-range reading, and judges the share of busy time' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors {
            param($index)
            if ($index -eq 5) { @{ '0' = (New-Processor -Guest 0 -Hypervisor 5552443855) } }
            elseif ($index -eq 12) { @{ '0' = (New-Processor -Guest 3.8 -Hypervisor 83) } }
            else { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94) } }
        })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'livelocked' -Because 'a dip that keeps the hypervisor at 96% of the busy time is the same trap storm'
        $verdict.SampleCount | Should -Be 20
    }
    It 'ends the run at a gap in the recording' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94) } })
        # Two minutes with no readings between the older half and the newer.
        foreach ($sample in $samples[0..10]) { $sample.Utc = $sample.Utc.AddSeconds(-120) }
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.Verdict | Should -Be 'not-livelocked'
        $verdict.LivelockedSeconds | Should -Be 135
    }
    It 'refuses to judge from a stale recording or one without the VM' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94) } })
        (Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow.AddMinutes(10)).Verdict | Should -Be 'unavailable'
        (Get-YurunaVmLivelockVerdict -VMName 'another-vm' -Sample $samples -NowUtc $script:LivelockNow).Verdict | Should -Be 'unavailable'
        (Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample @() -NowUtc $script:LivelockNow).Verdict | Should -Be 'unavailable'
    }
    It 'names the intercept the processors were taking' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94 -Cause @{ 'SysReg Accesses/sec' = 3600000; 'Hypercalls/sec' = 1200; 'Other Intercepts/sec' = 0 }) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.DominantIntercept | Should -Be 'SysReg Accesses/sec'
        @($verdict.InterceptBreakdown.Keys)[0] | Should -Be 'SysReg Accesses/sec'
    }
    It 'asks the sampler for the per-cause intercept rates' {
        $counters = @(Get-YurunaHostCounterSpecification | Where-Object Object -EQ 'Hyper-V Hypervisor Virtual Processor' | ForEach-Object Counter)
        foreach ($name in @('SysReg Accesses/sec', 'Hypercalls/sec', 'Virtual Interrupts/sec', 'Memory Intercept Messages/sec', 'MSR Accesses/sec',
                'SMC Instructions/sec', 'CPPC Request Context Switches/sec', 'External Interrupts/sec', 'Posted Interrupt Scans/sec')) {
            $counters | Should -Contain $name
        }
    }
    It 'names the remainder Unaccounted/sec instead of reading it as no cause at all' {
        # The real shape a livelocked ARM64 Hyper-V host produced: every named
        # cause reads zero while Total Intercepts/sec is in the millions. A
        # breakdown that stopped at its own cause list would read as "nothing
        # was trapping", which is the opposite of what the host measured.
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 7.6 -Hypervisor 91.3 -Intercepts 3392205 -Cause @{ 'SysReg Accesses/sec' = 0; 'Hypercalls/sec' = 0; 'Other Intercepts/sec' = 0 }) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.DominantIntercept | Should -Be 'Unaccounted/sec'
        $verdict.InterceptBreakdown['Unaccounted/sec'] | Should -Be 3392205
        @($verdict.InterceptBreakdown.Keys)[0] | Should -Be 'Unaccounted/sec' -Because 'the breakdown must rank Unaccounted/sec by its actual size, not always trail it'
    }
    It 'omits Unaccounted/sec when the named causes explain the whole total' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94 -Intercepts 100000 -Cause @{ 'SysReg Accesses/sec' = 100000 }) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        $verdict.InterceptBreakdown.Contains('Unaccounted/sec') | Should -BeFalse
        $verdict.DominantIntercept | Should -Be 'SysReg Accesses/sec'
    }
    It 'ranks a partial gap alongside the named causes instead of always trailing them' {
        $samples = @(New-RunSampleSeries -Count 21 -Processors { @{ '0' = (New-Processor -Guest 5 -Hypervisor 94 -Intercepts 1000000 -Cause @{ 'SysReg Accesses/sec' = 300000; 'Hypercalls/sec' = 50000 }) } })
        $verdict = Get-YurunaVmLivelockVerdict -VMName $script:LivelockVm -Sample $samples -NowUtc $script:LivelockNow
        # 1,000,000 total - 350,000 named = 650,000 unaccounted: the largest share.
        $verdict.DominantIntercept | Should -Be 'Unaccounted/sec'
        $verdict.InterceptBreakdown['Unaccounted/sec'] | Should -Be 650000
        @($verdict.InterceptBreakdown.Keys) | Should -Be @('Unaccounted/sec', 'SysReg Accesses/sec', 'Hypercalls/sec')
    }
}
Describe 'reading the live host recording' {
    BeforeAll {
        function New-RecordingRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory fixture; changes no state.')]
            param([datetime]$Utc, [double]$Guest, [double]$Hypervisor, [string]$Instance = 'test-guest.ubuntu.server.26-01:hv vp 0')
            # Paths and capability names as a German host renders them: the
            # reader must map them back through the record's own capability rows.
            [ordered]@{
                Kind = 'sample'; Utc = $Utc.ToString('o')
                Capabilities = @(
                    [pscustomobject]@{ Object = 'Hyper-V Hypervisor Virtual Processor'; Counter = '% Guest Run Time'; LocalCounter = '% Gastlaufzeit' }
                    [pscustomobject]@{ Object = 'Hyper-V Hypervisor Virtual Processor'; Counter = '% Hypervisor Run Time'; LocalCounter = '% Hypervisorlaufzeit' }
                )
                Counters = @(
                    [pscustomobject]@{ Path = "\\host\hyper-v hypervisor virtueller prozessor($Instance)\% gastlaufzeit"; Instance = $Instance; Status = 'present'; Value = $Guest }
                    [pscustomobject]@{ Path = "\\host\hyper-v hypervisor virtueller prozessor($Instance)\% hypervisorlaufzeit"; Instance = $Instance; Status = 'present'; Value = $Hypervisor }
                    [pscustomobject]@{ Path = '\\host\hyper-v hypervisor root virtual processor(root vp 0)\% gastlaufzeit'; Instance = 'root vp 0'; Status = 'present'; Value = 50 }
                )
            }
        }
        function New-VmListing {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: builds an in-memory fixture; changes no state.')]
            param([string]$State)
            # The Get-VM listing the sampler writes into every sample record.
            @{ Status = 'present'; RunningCount = [int]($State -eq 'Running'); VMs = @(@{ Name = 'test-guest.ubuntu.server.26-01'; State = $State }) }
        }
    }
    It 'returns $null, not a verdict, on a host that keeps no recording' {
        $runtime = Join-Path $TestDrive 'no-recording'
        $null = New-Item -ItemType Directory $runtime -Force
        Get-YurunaVmLivelockState -VMName 'test-guest.ubuntu.server.26-01' -RuntimeDirectory $runtime | Should -BeNullOrEmpty
    }
    It 'maps localized counters, skips root processors, and reads only what was appended' {
        $runtime = Join-Path $TestDrive 'recording'
        $directory = Join-Path $runtime 'host-sampling/owned'
        $null = New-Item -ItemType Directory $directory -Force
        @{ Directory = $directory } | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $start = [datetime]::UtcNow.AddSeconds(-330)
        foreach ($index in 0..10) { Write-YurunaHostSampleRecord -Directory $directory -Record (New-RecordingRecord -Utc $start.AddSeconds(15 * $index) -Guest 5 -Hypervisor 94) }
        $first = @(Read-YurunaHostVmRunSample -RuntimeDirectory $runtime)
        $first.Count | Should -Be 11
        $first[0].VMs.Keys | Should -Be @('test-guest.ubuntu.server.26-01')
        $first[0].VMs['test-guest.ubuntu.server.26-01']['0']['% Hypervisor Run Time'] | Should -Be 94
        foreach ($index in 11..22) { Write-YurunaHostSampleRecord -Directory $directory -Record (New-RecordingRecord -Utc $start.AddSeconds(15 * $index) -Guest 5 -Hypervisor 94) }
        # A record the sampler is still writing is left for the next read.
        [IO.File]::AppendAllText((Join-Path $directory 'samples.000000.ndjson'), '{"Kind":"sample","Utc":')
        @(Read-YurunaHostVmRunSample -RuntimeDirectory $runtime).Count | Should -Be 23
        $verdict = Get-YurunaVmLivelockState -VMName 'TEST-GUEST.ubuntu.server.26-01' -RuntimeDirectory $runtime
        $verdict.Verdict | Should -Be 'livelocked' -Because 'PDH lowercases instance names, so the VM name must match regardless of case'
    }
    It 'keeps a power-off sample, so the reading after it starts a new run' {
        $runtime = Join-Path $TestDrive 'power-cycle'
        $directory = Join-Path $runtime 'host-sampling/owned'
        $null = New-Item -ItemType Directory $directory -Force
        @{ Directory = $directory } | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $start = [datetime]::UtcNow.AddSeconds(-40)
        $before = New-RecordingRecord -Utc $start -Guest 5 -Hypervisor 94
        $before.Vm = New-VmListing -State 'Running'
        # As the sampler writes a powered-off guest: host rows only, the VM listed Off.
        $off = New-RecordingRecord -Utc $start.AddSeconds(15) -Guest 5 -Hypervisor 94
        $off.Counters = @($off.Counters | Where-Object Instance -EQ 'root vp 0')
        $off.Vm = New-VmListing -State 'Off'
        $after = New-RecordingRecord -Utc $start.AddSeconds(30) -Guest 5 -Hypervisor 94
        $after.Vm = New-VmListing -State 'Running'
        foreach ($record in @($before, $off, $after)) { Write-YurunaHostSampleRecord -Directory $directory -Record $record }
        $samples = @(Read-YurunaHostVmRunSample -RuntimeDirectory $runtime)
        $samples.Count | Should -Be 3
        $samples[1].VMs -is [hashtable] | Should -BeTrue
        $samples[1].VMs.Count | Should -Be 0
        $samples[1].Running.ContainsKey('test-guest.ubuntu.server.26-01') | Should -BeFalse
        (Get-YurunaVmLivelockState -VMName 'test-guest.ubuntu.server.26-01' -RuntimeDirectory $runtime).LivelockedSeconds | Should -Be 0 -Because 'the reading after the power-off belongs to a new boot'
    }
    It 'keeps a failed counter read inside the run while the guest is listed as running' {
        $runtime = Join-Path $TestDrive 'failed-read'
        $directory = Join-Path $runtime 'host-sampling/owned'
        $null = New-Item -ItemType Directory $directory -Force
        @{ Directory = $directory } | ConvertTo-Json | Set-Content (Join-Path $runtime 'host-sampling.current.json')
        $start = [datetime]::UtcNow.AddSeconds(-40)
        $before = New-RecordingRecord -Utc $start -Guest 5 -Hypervisor 94
        $before.Vm = New-VmListing -State 'Running'
        # As PDH reports invalid data: every virtual-processor row kept, none of them present.
        $failed = New-RecordingRecord -Utc $start.AddSeconds(15) -Guest 5 -Hypervisor 94
        $failed.Counters = @($failed.Counters | ForEach-Object {
            if ($_.Instance -like '*:hv vp *') { [pscustomobject]@{ Path = $_.Path; Instance = $_.Instance; Status = 'absent'; Value = $null } } else { $_ }
        })
        $failed.Vm = New-VmListing -State 'Running'
        $after = New-RecordingRecord -Utc $start.AddSeconds(30) -Guest 5 -Hypervisor 94
        $after.Vm = New-VmListing -State 'Running'
        foreach ($record in @($before, $failed, $after)) { Write-YurunaHostSampleRecord -Directory $directory -Record $record }
        $samples = @(Read-YurunaHostVmRunSample -RuntimeDirectory $runtime)
        $samples.Count | Should -Be 3
        $samples[1].VMs.Count | Should -Be 0
        $samples[1].Running.ContainsKey('test-guest.ubuntu.server.26-01') | Should -BeTrue
        (Get-YurunaVmLivelockState -VMName 'test-guest.ubuntu.server.26-01' -RuntimeDirectory $runtime).LivelockedSeconds | Should -Be 30 -Because 'a failed read while the guest runs is a hole, not a power cycle'
    }
    It 'records no listing when Get-VM failed, so the sample cannot end a run' {
        $record = New-RecordingRecord -Utc ([datetime]::UtcNow) -Guest 5 -Hypervisor 94
        $record.Vm = @{ Status = 'absent'; RunningCount = $null; VMs = @(); Reason = 'Hyper-V module unavailable' }
        (ConvertTo-YurunaVmRunSample -Record $record).Running | Should -BeNullOrEmpty
        (ConvertTo-YurunaVmRunSample -Record (New-RecordingRecord -Utc ([datetime]::UtcNow) -Guest 5 -Hypervisor 94)).Running | Should -BeNullOrEmpty
    }
}
