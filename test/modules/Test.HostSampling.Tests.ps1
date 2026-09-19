<#PSScriptInfo
.VERSION 2026.09.18
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
    It 'resolves actual localized paths without guessing translated names' {
        $map=@{'Hyper-V Hypervisor Virtual Processor'='Prozessor'; '% Guest Run Time'='Gastzeit'}
        $sets=@([pscustomobject]@{CounterSetName='Prozessor'; Paths=@('\Prozessor(*)\Gastzeit')})
        $rows=@(Resolve-YurunaHostCounterCapability -CounterSets $sets -NameMap $map -RunningVmCount 1)
        $guest=$rows | Where-Object { $_.Object -eq 'Hyper-V Hypervisor Virtual Processor' -and $_.Counter -eq '% Guest Run Time' }
        $guest.Status | Should -Be 'present'
        $guest.Paths | Should -Be '\Prozessor(*)\Gastzeit'
        ($rows | Where-Object Counter -EQ 'Total Intercepts/sec' | Select-Object -First 1).Status | Should -Be 'absent'
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
        $path=Join-Path $PSScriptRoot "../../host/windows.hyper-v/guest.$_-service/New-VM.ps1"
        $parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$vmCores'},$true))
        $set=$ast.Find({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-VMProcessor'},$true)
        $script:RequestedCount=0; $script:AppliedCount=0
        function Limit-HyperVLinuxGuestCoreCount { param($RequestedCores) $script:RequestedCount=$RequestedCores; return 2 }
        function Set-VMProcessor { [CmdletBinding(SupportsShouldProcess)] param($VMName,$Count) if ($PSCmdlet.ShouldProcess($VMName, 'Record fake processor count')) { $script:AppliedCount=$Count } }
        $fixtureText='param($hostCores,$VMName)' + "`n" + ((@($assignments | ForEach-Object { $_.Extent.Text }) + $set.Extent.Text) -join "`n")
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
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMProcessor' { [pscustomobject]@{Count=2; Reserve=0; Maximum=100; RelativeWeight=100; ExposeVirtualizationExtensions=$false; HwThreadCountPerCore=1; CompatibilityForMigrationEnabled=$false} }
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMMemory' { [pscustomobject]@{DynamicMemoryEnabled=$true; Minimum=2GB; Maximum=8GB; Startup=4GB; Buffer=20; Priority=50} }
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
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMProcessor' { throw 'access denied' }
        $result=Get-YurunaHostVmSnapshot
        $result.RunningCount | Should -Be 1
        $result.VMs[0].Processor.Status | Should -Be 'absent'
        $result.VMs[0].Processor.Reason | Should -Match 'access denied'
        $result.VMs[0].Memory.Status | Should -Be 'present'
    }
    It 'names unsupported configuration properties instead of reporting them as zero' {
        Mock -ModuleName Test.HostSampling -CommandName 'Hyper-V\Get-VMMemory' { [pscustomobject]@{DynamicMemoryEnabled=$false; Startup=4GB} }
        $result=Get-YurunaHostVmSnapshot
        $result.VMs[0].Memory.Status | Should -Be 'partial'
        $result.VMs[0].Memory.UnavailableProperties | Should -Contain 'Buffer'
        $result.VMs[0].Memory.Values.Buffer | Should -BeNullOrEmpty
    }
}
