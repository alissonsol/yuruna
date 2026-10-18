<#PSScriptInfo
.VERSION 2026.10.14
.GUID 42d6d3a9-02a1-4fb8-87ed-a2137333c910
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host diagnostics performance
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Retain bounded host performance evidence independently of the inner runner.
.DESCRIPTION
    See https://yuruna.link/42dc5bb9-0010 for counter interpretation and controls.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
function Get-YurunaHostSamplingSetting {
    <# .SYNOPSIS
        Resolve inexpensive sampling defaults and the environment opt-out.
    #>
    [CmdletBinding()]
    param()
    $interval = 15
    $parsed = 0
    if ([int]::TryParse("$env:YURUNA_HOST_SAMPLE_INTERVAL_SECONDS", [ref]$parsed)) {
        $interval = [math]::Clamp($parsed, 5, 300)
    }
    [pscustomobject]@{ Enabled = ($IsWindows -and "$env:YURUNA_HOST_SAMPLING_DISABLED" -notmatch '^(1|true|yes)$'); IntervalSeconds = $interval }
}

function Get-YurunaHostCounterSpecification {
    <# .SYNOPSIS
        Define a bounded counter set; names are resolved against this host's inventory.
    #>
    [CmdletBinding()]
    param()
    # See https://yuruna.link/42e220c4-0004
    $groups = [ordered]@{
        'Hyper-V Hypervisor Virtual Processor' = @('% Guest Run Time','% Hypervisor Run Time','% Total Run Time','Total Intercepts/sec','Other Intercepts/sec','Total Intercepts Cost','CPU Wait Time Per Dispatch','Logical Processor Dispatches/sec','CPU Wake Up Time Per Dispatch','CPU Contention Time Per Dispatch',
            'Hypercalls/sec','SysReg Accesses/sec','MSR Accesses/sec','IO Instructions/sec','Virtual Interrupts/sec','Synthetic Interrupts/sec','Hardware Interrupts/sec','Pending Interrupts/sec','Memory Intercept Messages/sec','Nested Page Fault Intercepts/sec',
            'SMC Instructions/sec','CPPC Request Context Switches/sec','External Interrupts/sec','Posted Interrupt Scans/sec','Posted Interrupt Notifications/sec','Extended Hypercall Intercept Messages/sec','Reflected Guest Page Faults/sec','Other Reflected Guest Exceptions/sec','Global I/O TLB Flushes/sec','Local I/O TLB Flushes/sec')
        'Hyper-V Hypervisor Root Virtual Processor' = @('% Guest Run Time','% Hypervisor Run Time','% Total Run Time','Total Intercepts/sec','CPU Wait Time Per Dispatch')
        'Hyper-V Hypervisor Logical Processor' = @('% Total Run Time','% Hypervisor Run Time','Context Switches/sec','Scheduler Local Run List Size')
        'Processor Information' = @('% Processor Performance','Processor Frequency','% DPC Time','% Interrupt Time')
        'System' = @('Context Switches/sec','Processor Queue Length')
        'Memory' = @('Available MBytes','Committed Bytes','Commit Limit','Pages/sec')
        'PhysicalDisk' = @('Avg. Disk sec/Read','Avg. Disk sec/Write','Avg. Disk Read Queue Length','Avg. Disk Write Queue Length')
    }
    foreach ($object in $groups.Keys) {
        foreach ($counter in $groups[$object]) {
            [pscustomobject]@{ Object = $object; Counter = $counter; Guest = ($object -eq 'Hyper-V Hypervisor Virtual Processor') }
        }
    }
}

function Resolve-YurunaHostCounterCapability {
    <# .SYNOPSIS
        Match discovered localized paths without inventing counters or conflating idle with absent.
    #>
    [CmdletBinding()]
    param([object[]]$CounterSets, [hashtable]$NameMap = @{}, [Nullable[int]]$RunningVmCount)
    $specification = @(Get-YurunaHostCounterSpecification)
    $vpObject = 'Hyper-V Hypervisor Virtual Processor'
    $localVpObject = if ($NameMap.ContainsKey($vpObject)) { $NameMap[$vpObject] } else { $vpObject }
    $vpSet = @($CounterSets | Where-Object CounterSetName -EQ $localVpObject | Select-Object -First 1)
    $known = @($specification | Where-Object Object -EQ $vpObject | ForEach-Object Counter)
    $englishByLocal = @{}
    foreach ($name in $NameMap.Keys) { $englishByLocal[[string]$NameMap[$name]] = [string]$name }
    # Keep a bounded inventory-backed diagnostic tail. These narrower rates
    # may overlap the named counters; they are observations, not additive causes.
    $extra = @($vpSet | ForEach-Object Paths | ForEach-Object {
        $localName = $_.Substring($_.LastIndexOf('\') + 1)
        $name = if ($englishByLocal.ContainsKey($localName)) { $englishByLocal[$localName] } else { $localName }
        if ($name -match '(?i)(intercept|access|instruction|fault|flush).*\/sec$' -and $name -notin $known) { $name }
    } | Sort-Object -Unique | Select-Object -First 12)
    foreach ($name in $extra) { $specification += [pscustomobject]@{ Object=$vpObject; Counter=$name; Guest=$true } }
    foreach ($spec in $specification) {
        $objectName = if ($NameMap.ContainsKey($spec.Object)) { $NameMap[$spec.Object] } else { $spec.Object }
        $counterName = if ($NameMap.ContainsKey($spec.Counter)) { $NameMap[$spec.Counter] } else { $spec.Counter }
        $set = @($CounterSets | Where-Object CounterSetName -EQ $objectName | Select-Object -First 1)
        $paths = @($set | ForEach-Object { $_.Paths } | Where-Object { $_.EndsWith('\' + $counterName, [StringComparison]::OrdinalIgnoreCase) })
        $status = if ($spec.Guest -and $null -ne $RunningVmCount -and $RunningVmCount -eq 0) { 'not-applicable' } elseif ($paths.Count) { 'present' } else { 'absent' }
        [pscustomobject]@{ Object = $spec.Object; Counter = $spec.Counter; LocalObject = $objectName; LocalCounter = $counterName; Paths = $paths; Guest = $spec.Guest; Status = $status; Reason = if ($status -eq 'not-applicable') { (Format-YurunaOperatorMessage -Key 'runner.operator_66b5545928b78b87') } elseif ($status -eq 'absent') { (Format-YurunaOperatorMessage -Key 'runner.operator_74ab27201629f72c') } else { '' } }
    }
}

function Get-YurunaHostCounterInventory {
    <# .SYNOPSIS
        Enumerate actual PDH paths and resolve English counter IDs to the installed language.
    #>
    [CmdletBinding()]
    param()
    $map = @{}
    $localization = 'unavailable'
    try {
        $english = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009' -Name Counter -ErrorAction Stop).Counter
        $local = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\CurrentLanguage' -Name Counter -ErrorAction Stop).Counter
        $byId = @{}
        for ($i = 0; $i -lt $local.Count - 1; $i += 2) { $byId[$local[$i]] = $local[$i + 1] }
        for ($i = 0; $i -lt $english.Count - 1; $i += 2) { if ($byId.ContainsKey($english[$i])) { $map[$english[$i + 1]] = $byId[$english[$i]] } }
        $localization = 'resolved'
    } catch { Write-Verbose $_.Exception.Message }
    try {
        # Instance paths are not read by capability resolution, and each sample
        # already names the instances it measured, so they are left out here.
        $sets = @(Get-Counter -ListSet * -ErrorAction Stop | Select-Object CounterSetName, Paths, Description)
        [pscustomobject]@{ Status = 'present'; Reason = ''; Localization = $localization; NameMap = $map; CounterSets = $sets }
    } catch {
        [pscustomobject]@{ Status = 'absent'; Reason = $_.Exception.Message; Localization = $localization; NameMap = $map; CounterSets = @() }
    }
}

function Get-YurunaHostPowerStatus {
    <# .SYNOPSIS
        Read the current AC/DC state without changing the power plan.
    #>
    [CmdletBinding()]
    param()
    try {
        if (-not ('YurunaHostPower' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class YurunaHostPower {
    [StructLayout(LayoutKind.Sequential)] public struct Status { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, Reserved; public uint BatteryLifeTime, BatteryFullLifeTime; }
    [DllImport("kernel32.dll")] public static extern bool GetSystemPowerStatus(out Status status);
}
'@
        }
        $power = [YurunaHostPower+Status]::new()
        if (-not [YurunaHostPower]::GetSystemPowerStatus([ref]$power)) { throw 'GetSystemPowerStatus failed.' }
        [pscustomobject]@{ Status = 'present'; Source = switch ($power.ACLineStatus) { 0 { 'DC' }; 1 { 'AC' }; default { 'unknown' } }; BatteryPercent = if ($power.BatteryLifePercent -eq 255) { $null } else { [int]$power.BatteryLifePercent } }
    } catch { [pscustomobject]@{ Status = 'absent'; Source = 'unknown'; Reason = $_.Exception.Message } }
}

function Get-YurunaHostVmSnapshot {
    <# .SYNOPSIS
        Read VM identity and allocated resources, retaining an explicit unavailable result.
    #>
    [CmdletBinding()]
    param()
    try {
        $machines = @(Hyper-V\Get-VM -ErrorAction Stop)
        $configuration = [ordered]@{
            Processor = @{ Properties=@('Count','Reserve','Maximum','RelativeWeight','ExposeVirtualizationExtensions','HwThreadCountPerCore','CompatibilityForMigrationEnabled') }
            Memory = @{ Properties=@('DynamicMemoryEnabled','Minimum','Maximum','Startup','Buffer','Priority') }
        }
        $vms = @(foreach ($machine in $machines) {
            $summary = $machine | Select-Object Name, Id, @{ n='State'; e={ [string]$_.State } }, ProcessorCount, MemoryAssigned, MemoryDemand, MemoryStartup, DynamicMemoryEnabled, Generation, Version
            foreach ($kind in $configuration.Keys) {
                $spec = $configuration[$kind]
                try {
                    $settings = if ($kind -eq 'Processor') { Hyper-V\Get-VMProcessor -VM $machine -ErrorAction Stop } else { Hyper-V\Get-VMMemory -VM $machine -ErrorAction Stop }
                    if (-not $settings) { throw 'The Hyper-V configuration query returned no settings.' }
                    $missing = @($spec.Properties | Where-Object { $null -eq $settings.PSObject.Properties[$_] -or $null -eq $settings.$_ })
                    $detail = [pscustomobject]@{ Status=if ($missing.Count) { 'partial' } else { 'present' }; Values=($settings | Select-Object -Property $spec.Properties); UnavailableProperties=$missing }
                } catch { $detail = [pscustomobject]@{ Status='absent'; Reason=$_.Exception.Message } }
                $summary | Add-Member -NotePropertyName $kind -NotePropertyValue $detail
            }
            $summary
        })
        [pscustomobject]@{ Status = 'present'; RunningCount = @($vms | Where-Object State -EQ 'Running').Count; VMs = $vms }
    } catch { [pscustomobject]@{ Status = 'absent'; RunningCount = $null; VMs = @(); Reason = $_.Exception.Message } }
}

function Get-YurunaHostSampleInfo {
    <# .SYNOPSIS
        Read host build, firmware, scheduler and exporter identity once per recording.
    #>
    [CmdletBinding()]
    param()
    $result = [ordered]@{ Kind = 'metadata'; Utc = [datetime]::UtcNow.ToString('o'); MonotonicTicks = [Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency = [Diagnostics.Stopwatch]::Frequency; ClockDomain = 'host-qpc'; Hostname = [Environment]::MachineName; Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); ProcessArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
    foreach ($class in @('Win32_OperatingSystem','Win32_BIOS','Win32_Processor','Win32_ComputerSystem')) {
        try {
            $rows = Get-CimInstance -ClassName $class -OperationTimeoutSec 3 -ErrorAction Stop
            $result[$class] = switch ($class) {
                'Win32_OperatingSystem' { $rows | Select-Object Caption, Version, BuildNumber, LastBootUpTime, TotalVisibleMemorySize, FreePhysicalMemory, TotalVirtualMemorySize, FreeVirtualMemory }
                'Win32_BIOS' { $rows | Select-Object SMBIOSBIOSVersion, ReleaseDate }
                'Win32_Processor' { $rows | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, CurrentClockSpeed, MaxClockSpeed }
                'Win32_ComputerSystem' { $rows | Select-Object Manufacturer, Model, TotalPhysicalMemory }
            }
        } catch { $result[$class] = @{ Status = 'absent'; Reason = $_.Exception.Message } }
    }
    try { $result.WindowsRevision = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop | Select-Object CurrentBuild, UBR, DisplayVersion } catch { $result.WindowsRevision = @{ Status = 'absent'; Reason = $_.Exception.Message } }
    try { $result.Scheduler = Get-WinEvent -FilterHashtable @{ ProviderName = 'Microsoft-Windows-Hyper-V-Hypervisor'; ID = 2 } -MaxEvents 1 -ErrorAction Stop | Select-Object TimeCreated, Id, Message } catch { $result.Scheduler = @{ Status = 'absent'; Reason = $_.Exception.Message } }
    try { $result.PowerPlan = @(& powercfg.exe /getactivescheme 2>&1 | ForEach-Object { "$_" }) } catch { $result.PowerPlan = @{ Status = 'absent'; Reason = $_.Exception.Message } }
    try { $result.ExporterService = Get-CimInstance Win32_Service -Filter "Name='windows_exporter'" -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object Name, State, StartMode, PathName } catch { $result.ExporterService = @{ Status = 'absent'; Reason = $_.Exception.Message } }
    [pscustomobject]$result
}

function ConvertTo-YurunaHostCounterSample {
    <# .SYNOPSIS
        Preserve per-instance cooked values and invalid states, excluding aggregate instances.
    #>
    [CmdletBinding()]
    param([object[]]$CounterSamples, [int]$MaximumRows = 1024)
    $kept = 0
    foreach ($sample in $CounterSamples) {
        if ([string]$sample.InstanceName -match '(^|[/:,])_total$' -or [string]$sample.Path -match '\(_total\)') { continue }
        if ($kept++ -ge $MaximumRows) { break }
        $valid = ($sample.Status -in @(0, 1) -and -not [double]::IsNaN([double]$sample.CookedValue) -and -not [double]::IsInfinity([double]$sample.CookedValue))
        [pscustomobject]@{ Path = $sample.Path; Instance = $sample.InstanceName; Status = if ($valid) { 'present' } else { 'absent' }; PdhStatus = $sample.Status; CounterType = [string]$sample.CounterType; Value = if ($valid) { $sample.CookedValue } else { $null }; RawValue = $sample.RawValue; SecondValue = $sample.SecondValue; Timestamp100NSec = $sample.Timestamp100NSec }
    }
}

function Write-YurunaHostSampleRecord {
    <# .SYNOPSIS
        Flush an append-only record and rotate only owned segments at the size limit.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)]$Record, [int]$SegmentBytes = 4194304, [int]$MaximumSegments = 4)
    $null = [IO.Directory]::CreateDirectory($Directory)
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'samples.*.ndjson' -File | Sort-Object Name)
    $number = if ($files.Count) { [int]($files[-1].BaseName.Split('.')[-1]) } else { 0 }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 15 -Compress) + "`n")
    if ($files.Count -and $files[-1].Length + $bytes.Length -gt $SegmentBytes) { $number++ }
    $path = Join-Path $Directory ('samples.{0:d6}.ndjson' -f $number)
    $stream = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            break
        } catch [IO.IOException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 50
        }
    }
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    $old = @(Get-ChildItem -LiteralPath $Directory -Filter 'samples.*.ndjson' -File | Sort-Object Name -Descending | Select-Object -Skip $MaximumSegments)
    foreach ($file in $old) { Remove-Item -LiteralPath $file.FullName -Force }
}

function Invoke-YurunaHostSampling {
    <# .SYNOPSIS
        Collect flushed host evidence in a dedicated process with a stop sentinel.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Directory, [ValidateRange(1,86400)][int]$DurationSeconds = 60, [ValidateRange(1,300)][int]$IntervalSeconds = 15, [int]$OwnerProcessId = 0)
    $null = [IO.Directory]::CreateDirectory($Directory)
    Write-YurunaHostSampleRecord -Directory $Directory -Record @{ Kind='state'; Status='collecting'; Utc=[datetime]::UtcNow.ToString('o'); MonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency=[Diagnostics.Stopwatch]::Frequency }
    if (-not $IsWindows) {
        Write-YurunaHostSampleRecord -Directory $Directory -Record @{ Kind='state'; Status='not-applicable'; Reason=(Format-YurunaOperatorMessage -Key 'runner.operator_b86ea943b0beb5ed') }
        return
    }
    $metadata = Get-YurunaHostSampleInfo
    $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Directory 'metadata.json') -Encoding utf8
    $inventory = Get-YurunaHostCounterInventory
    $inventory | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath (Join-Path $Directory 'counter-inventory.json') -Encoding utf8
    Import-Module (Join-Path $PSScriptRoot 'Test.HostMetricsExporter.psm1') -Global -Force -ErrorAction Stop
    $timer = [Diagnostics.Stopwatch]::StartNew()
    # Waiting on the owner's handle below replaces a process lookup per slice;
    # a handle also cannot be fooled by the PID being reused.
    $owner = $null
    if ($OwnerProcessId -gt 0) {
        try { $owner = [Diagnostics.Process]::GetProcessById($OwnerProcessId) } catch { $owner = $null }
    }
    $capabilityVmCount = $null
    $capabilitiesResolved = $false
    try {
        while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds -and -not (Test-Path (Join-Path $Directory 'stop'))) {
            if ($OwnerProcessId -gt 0 -and -not (Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue)) { break }
            $start = $timer.Elapsed.TotalSeconds
            $vm = Get-YurunaHostVmSnapshot
            # The inventory is fixed for this recording; only the running-VM
            # count changes which capabilities apply.
            if (-not $capabilitiesResolved -or $vm.RunningCount -ne $capabilityVmCount) {
                $capabilities = @(Resolve-YurunaHostCounterCapability -CounterSets $inventory.CounterSets -NameMap $inventory.NameMap -RunningVmCount $vm.RunningCount)
                $paths = @($capabilities | Where-Object Status -EQ 'present' | ForEach-Object Paths | Select-Object -Unique)
                $capabilityVmCount = $vm.RunningCount
                $capabilitiesResolved = $true
            }
            $record = [ordered]@{ Kind='sample'; Utc=[datetime]::UtcNow.ToString('o'); MonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency=[Diagnostics.Stopwatch]::Frequency; ClockDomain='host-qpc'; Power=(Get-YurunaHostPowerStatus); Vm=$vm; Capabilities=$capabilities; Counters=@(); CounterStatus='absent'; CounterReason='No applicable counters.' }
            if ($paths.Count) {
                $errors = @()
                $read = @(Get-Counter -Counter $paths -SampleInterval 1 -MaxSamples 2 -ErrorAction SilentlyContinue -ErrorVariable errors)
                $record.Counters = @(ConvertTo-YurunaHostCounterSample -CounterSamples @($read | Select-Object -Last 1 | ForEach-Object CounterSamples))
                $record.CounterStatus = if (@($record.Counters | Where-Object Status -EQ 'present').Count) { 'present' } else { 'absent' }
                $record.CounterReason = ($errors | ForEach-Object { $_.Exception.Message }) -join '; '
            }
            $payload = Invoke-YurunaHostMetricsProbe -Port 9182 -TimeoutSec 3
            $record.Exporter = Get-YurunaHostMetricsCapability -Payload $payload -RunningVmCount $vm.RunningCount
            $record.CollectionSeconds = $timer.Elapsed.TotalSeconds - $start
            Write-YurunaHostSampleRecord -Directory $Directory -Record $record
            $remaining = $IntervalSeconds - ($timer.Elapsed.TotalSeconds - $start)
            $sleepUntil = [math]::Min($DurationSeconds, $start + $IntervalSeconds)
            while ($remaining -gt 0 -and $timer.Elapsed.TotalSeconds -lt $sleepUntil) {
                if (Test-Path -LiteralPath (Join-Path $Directory 'stop')) { break }
                $sliceMs = [int][math]::Min(500, ($sleepUntil - $timer.Elapsed.TotalSeconds) * 1000)
                if ($sliceMs -le 0) { break }
                if ($owner) {
                    if ($owner.WaitForExit($sliceMs)) { break }
                } else {
                    Start-Sleep -Milliseconds $sliceMs
                }
            }
        }
    } finally {
        if ($owner) { $owner.Dispose() }
    }
}

function Invoke-YurunaHostBoundedCommand {
    <# .SYNOPSIS
        Capture one read-only native diagnostic command with a process-tree deadline.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList, [ValidateRange(1,60)][int]$TimeoutSeconds = 5, [string]$InputText)
    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $info.RedirectStandardInput = $PSBoundParameters.ContainsKey('InputText')
    foreach ($arg in $ArgumentList) { $info.ArgumentList.Add($arg) }
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($info.RedirectStandardInput) {
            $inputWrite = $process.StandardInput.WriteAsync($InputText)
            if (-not $inputWrite.Wait(1000)) { $process.Kill($true); throw 'Command did not accept its input within one second.' }
            $process.StandardInput.Close()
        }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $partial = if ([Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr), 1000)) { $stdout.Result + $stderr.Result } else { '' }
            return [pscustomobject]@{ Status='timeout'; ExitCode=$null; Output="Command exceeded its collection deadline.`n$partial" }
        }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr), 1000)) { throw 'Command output did not close within one second.' }
        [pscustomobject]@{ Status='complete'; ExitCode=$process.ExitCode; Output=($stdout.Result + $stderr.Result) }
    } catch { [pscustomobject]@{ Status='unavailable'; ExitCode=$null; Output=$_.Exception.Message } }
    finally { if ($process) { $process.Dispose() } }
}

function Start-YurunaHostSampling {
    <# .SYNOPSIS
        Start a supervised sampler sibling of the inner runner; never block a cycle on PDH.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RuntimeDirectory, [string]$PwshPath = (Get-Process -Id $PID).Path)
    if (-not $PSCmdlet.ShouldProcess($RuntimeDirectory, (Format-YurunaOperatorMessage -Key 'runner.operator_2276f721ecc44594'))) { return $null }
    $setting = Get-YurunaHostSamplingSetting
    if (-not $setting.Enabled) {
        [void][IO.Directory]::CreateDirectory($RuntimeDirectory)
        @{ Directory=''; Status='not-applicable'; Reason=(Format-YurunaOperatorMessage -Key 'runner.operator_0f1cc6c29ab6043f'); Utc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RuntimeDirectory 'host-sampling.current.json') -Encoding utf8
        return $null
    }
    $process = $null
    try {
        $directory = Join-Path $RuntimeDirectory ('host-sampling/' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($directory)
        $previous = @(Get-ChildItem -LiteralPath (Join-Path $RuntimeDirectory 'host-sampling') -Directory | Where-Object Name -Match '^[0-9a-f]{32}$' | Sort-Object CreationTimeUtc -Descending | Select-Object -Skip 4)
        foreach ($old in $previous) { Remove-Item -LiteralPath $old.FullName -Recurse -Force }
        @{ Directory=$directory; Utc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RuntimeDirectory 'host-sampling.current.json') -Encoding utf8
        $info = [Diagnostics.ProcessStartInfo]::new($PwshPath)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',(Join-Path $PSScriptRoot '../../automation/Collect-HostPerformance.ps1'),'-Worker','-OutputDirectory',$directory,'-DurationSeconds','86400','-IntervalSeconds',"$($setting.IntervalSeconds)",'-OwnerProcessId',"$PID")) { $info.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::Start($info)
        $interval = $setting.IntervalSeconds
        $job = Start-ThreadJob -ScriptBlock {
            $sampleProcess = $using:process
            $sampleDirectory = $using:directory
            $interval = $using:interval
            $progress = [Diagnostics.Stopwatch]::StartNew()
            $lastToken = ''
            while (-not $SampleProcess.WaitForExit(1000)) {
                if (Test-Path (Join-Path $SampleDirectory 'stop')) { break }
                $latest = @(Get-ChildItem -LiteralPath $SampleDirectory -Filter 'samples.*.ndjson' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
                $token = if ($latest.Count) { "$($latest[0].Name):$($latest[0].Length):$($latest[0].LastWriteTimeUtc.Ticks)" } else { '' }
                if ($token -ne $lastToken) { $progress.Restart(); $lastToken = $token }
                if ($progress.Elapsed.TotalSeconds -gt [math]::Max(45, 3 * $Interval)) {
                    $SampleProcess.Kill($true)
                    @{ Status='timeout'; Reason='Sampler stopped after failing to flush within its collection bound.'; Utc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $SampleDirectory 'sampler-outcome.json')
                    break
                }
            }
        }
        [pscustomobject]@{ Process=$process; Job=$job; Directory=$directory }
    } catch {
        if ($process -and -not $process.HasExited) { $process.Kill($true) }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d042e67680b63d87' -Arguments @{ message = "$($_.Exception.Message)" })
        return $null
    }
}

function Stop-YurunaHostSampling {
    <# .SYNOPSIS
        Stop only this sampler and its supervisor without affecting the inner runner.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param($Handle)
    if (-not $Handle) { return }
    if (-not $PSCmdlet.ShouldProcess($Handle.Directory, (Format-YurunaOperatorMessage -Key 'runner.operator_2fa9168635fa01f9'))) { return }
    try {
        [IO.File]::WriteAllText((Join-Path $Handle.Directory 'stop'), '')
        $forced = -not $Handle.Process.WaitForExit(2000)
        if ($forced) { $Handle.Process.Kill($true) }
        if (-not (Test-Path (Join-Path $Handle.Directory 'sampler-outcome.json'))) {
            @{ Status=if ($forced) { 'stopped' } elseif ($Handle.Process.ExitCode -eq 0) { 'complete' } else { 'partial' }; Reason=(Format-YurunaOperatorMessage -Key 'runner.operator_448f7135573f0ef3'); Utc=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Handle.Directory 'sampler-outcome.json')
        }
        if ($Handle.Job) { $null = Wait-Job -Job $Handle.Job -Timeout 3; Remove-Job -Job $Handle.Job -Force -ErrorAction SilentlyContinue }
    } catch { Write-Verbose "Host sampler cleanup: $($_.Exception.Message)" }
}

function Save-YurunaHostSampleSnapshot {
    <# .SYNOPSIS
        Copy the durable bounded ring before guest diagnostics, without performing live probes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DestinationDirectory, [string]$RuntimeDirectory = $env:YURUNA_RUNTIME_DIR)
    try {
        $target = Join-Path $DestinationDirectory ('host-samples-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))
        $null = [IO.Directory]::CreateDirectory($target)
        $status = 'unavailable'; $reason = (Format-YurunaOperatorMessage -Key 'runner.operator_ed5920e8d2fdc735')
        if ($RuntimeDirectory) {
            $pointer = Join-Path $RuntimeDirectory 'host-sampling.current.json'
            if (Test-Path -LiteralPath $pointer) {
                $recording = Get-Content -LiteralPath $pointer -Raw | ConvertFrom-Json
                $source = $recording.Directory
                if (-not $source -and $recording.Reason) { $reason = [string]$recording.Reason }
                $root = [IO.Path]::GetFullPath((Join-Path $RuntimeDirectory 'host-sampling')) + [IO.Path]::DirectorySeparatorChar
                if ($source -and [IO.Path]::GetFullPath($source).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    $files = @(Get-ChildItem -LiteralPath $source -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(samples\.\d+\.ndjson|metadata\.json|counter-inventory\.json|sampler-outcome\.json)$' })
                    foreach ($file in $files) {
                        $reader = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                        $buffer = [IO.MemoryStream]::new()
                        try {
                            $reader.CopyTo($buffer)
                            $bytes = $buffer.ToArray()
                        } finally { $reader.Dispose(); $buffer.Dispose() }
                        if ($file.Extension -eq '.ndjson' -and $bytes.Length -and $bytes[-1] -ne 10) {
                            # A trailing-range slice ([byte[]]$bytes[0..$n]) builds an
                            # intermediate object array sized to the whole segment, which
                            # costs nearly a second on a multi-MiB ring; Array.Copy does
                            # not. The two branches assign $bytes directly rather than
                            # through an if-expression's captured value: PowerShell
                            # unrolls an empty array to $null when it crosses that
                            # capture, which an `else { [byte[]]@() }` result would.
                            $lastNewline = [Array]::LastIndexOf($bytes, [byte]10)
                            if ($lastNewline -ge 0) {
                                $complete = [byte[]]::new($lastNewline + 1)
                                [Array]::Copy($bytes, $complete, $complete.Length)
                                $bytes = $complete
                            } else {
                                $bytes = [byte[]]@()
                            }
                        }
                        [IO.File]::WriteAllBytes((Join-Path $target $file.Name), $bytes)
                    }
                    if ($files.Count) { $status = 'partial'; $reason = (Format-YurunaOperatorMessage -Key 'runner.operator_50198f42d649113b') }
                }
            }
        }
        @{ Status=$status; Reason=$reason; Utc=[datetime]::UtcNow.ToString('o'); MonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency=[Diagnostics.Stopwatch]::Frequency } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target 'snapshot.json') -Encoding utf8
        [pscustomobject]@{ Status=$status; Path=$target; Reason=$reason }
    } catch { [pscustomobject]@{ Status='unavailable'; Path=''; Reason=$_.Exception.Message } }
}

# Parsed virtual-processor readings from the live recording. A wait that asks
# once a minute then parses only the lines written since it last asked, not
# the whole multi-MiB ring.
$script:VmRunCache = @{ Directory = ''; Offsets = @{}; Samples = [Collections.Generic.List[object]]::new() }

# The per-cause intercept rates a livelock verdict averages, so the record
# names what the trapping virtual processors were trapping on. Named causes
# never cover every PDH sub-counter Hyper-V Hypervisor Virtual Processor
# carries; Get-YurunaVmLivelockVerdict adds what these leave unaccounted for
# against Total Intercepts/sec, so a gap here reads as "not yet named"
# rather than as a measured zero.
$script:LivelockCauseCounters = @('Hypercalls/sec','SysReg Accesses/sec','MSR Accesses/sec','IO Instructions/sec','Virtual Interrupts/sec','Synthetic Interrupts/sec','Hardware Interrupts/sec','Pending Interrupts/sec','Memory Intercept Messages/sec','Nested Page Fault Intercepts/sec','Other Intercepts/sec',
    'SMC Instructions/sec','CPPC Request Context Switches/sec','External Interrupts/sec','Posted Interrupt Scans/sec','Posted Interrupt Notifications/sec','Extended Hypercall Intercept Messages/sec','Reflected Guest Page Faults/sec','Other Reflected Guest Exceptions/sec','Global I/O TLB Flushes/sec','Local I/O TLB Flushes/sec')
# Synthetic bucket name for Get-YurunaVmLivelockVerdict's unexplained
# remainder; never a real PDH counter, so it can never collide with one.
$script:LivelockUnaccountedLabel = 'Unaccounted/sec'

function ConvertTo-YurunaVmRunSample {
    <# .SYNOPSIS
        Reduce one sampler record to per-VM virtual-processor readings keyed by English counter name.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Record)
    # Counter paths carry the host's display language. The capability rows the
    # record carries map each localized name back to the English one asked for.
    $english = @{}
    foreach ($capability in @($Record.Capabilities)) {
        if ($capability -and $capability.Object -eq 'Hyper-V Hypervisor Virtual Processor' -and $capability.LocalCounter) {
            $english[([string]$capability.LocalCounter).ToLowerInvariant()] = [string]$capability.Counter
        }
    }
    $machines = @{}
    foreach ($counter in @($Record.Counters)) {
        if (-not $counter -or $counter.Status -ne 'present' -or $null -eq $counter.Value) { continue }
        $instance = [string]$counter.Instance
        $at = $instance.LastIndexOf(':hv vp ', [StringComparison]::OrdinalIgnoreCase)
        if ($at -lt 1) { continue }
        $path = [string]$counter.Path
        $name = $english[$path.Substring($path.LastIndexOf('\') + 1).ToLowerInvariant()]
        if (-not $name) { continue }
        # PDH reports instance names lowercased, so VM names compare that way.
        $vm = $instance.Substring(0, $at).ToLowerInvariant()
        $vp = $instance.Substring($at + 7).Trim()
        if (-not $machines.ContainsKey($vm)) { $machines[$vm] = @{} }
        if (-not $machines[$vm].ContainsKey($vp)) { $machines[$vm][$vp] = @{} }
        $machines[$vm][$vp][$name] = [double]$counter.Value
    }
    # Get-VM's listing of the guests running when the sample was taken, or
    # $null when the record carries no successful listing. A powered-off guest
    # and a running one whose counters failed to read both leave the sample
    # without the VM's processors; only this listing tells them apart.
    $running = $null
    if ($Record.Vm -and [string]$Record.Vm.Status -eq 'present') {
        $running = @{}
        foreach ($machine in @($Record.Vm.VMs)) {
            if ($machine -and ([string]$machine.State) -like 'Running*') { $running[([string]$machine.Name).ToLowerInvariant()] = $true }
        }
    }
    $utc = if ($Record.Utc -is [datetime]) { $Record.Utc.ToUniversalTime() } else {
        [datetime]::Parse([string]$Record.Utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    [pscustomobject]@{ Utc = $utc; VMs = $machines; Running = $running; CounterCapabilities = @($Record.Capabilities | Where-Object Object -EQ 'Hyper-V Hypervisor Virtual Processor' | Select-Object Counter, Status, Reason) }
}

function Read-YurunaHostVmRunSample {
    <# .SYNOPSIS
        Return the samples the live host recording holds for a recent window.
    .DESCRIPTION
        Reads the recording the outer runner's sampler is writing, so the inner
        runner learns what the hypervisor saw without a PDH query of its own.
        Every sample in the window is returned, including samples without
        virtual-processor readings, which Get-YurunaVmLivelockVerdict needs to
        see a power cycle.
        Returns nothing when no recording exists, which is every host but
        Windows and any host with sampling turned off.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$RuntimeDirectory = $env:YURUNA_RUNTIME_DIR, [ValidateRange(60, 86400)][int]$WindowSeconds = 3600)
    $directory = ''
    try {
        if ($RuntimeDirectory) {
            $pointer = Join-Path $RuntimeDirectory 'host-sampling.current.json'
            if ([IO.File]::Exists($pointer)) { $directory = [string]([IO.File]::ReadAllText($pointer) | ConvertFrom-Json).Directory }
        }
    } catch { $directory = '' }
    $cache = $script:VmRunCache
    if (-not $directory -or -not [IO.Directory]::Exists($directory)) {
        $cache.Directory = ''
        $cache.Offsets = @{}
        $cache.Samples.Clear()
        return
    }
    if ($cache.Directory -ne $directory) {
        $cache.Directory = $directory
        $cache.Offsets = @{}
        $cache.Samples.Clear()
    }
    $cutoff = [datetime]::UtcNow.AddSeconds(-$WindowSeconds)
    $timestamp = [regex]'^\{"Kind":"sample","Utc":"([^"]+)"'
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'samples.*.ndjson' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $offset = if ($cache.Offsets.ContainsKey($file.Name)) { [long]$cache.Offsets[$file.Name] } else { 0L }
        if ($file.Length -le $offset) { continue }
        if ($offset -eq 0 -and $file.LastWriteTimeUtc -lt $cutoff) { $cache.Offsets[$file.Name] = $file.Length; continue }
        $bytes = $null
        $read = 0
        try {
            $stream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try {
                $null = $stream.Seek($offset, [IO.SeekOrigin]::Begin)
                $bytes = [byte[]]::new([math]::Max(0, $stream.Length - $offset))
                while ($read -lt $bytes.Length) {
                    $chunk = $stream.Read($bytes, $read, $bytes.Length - $read)
                    if ($chunk -le 0) { break }
                    $read += $chunk
                }
            } finally { $stream.Dispose() }
        } catch { Write-Verbose "Host recording segment unreadable: $($_.Exception.Message)"; continue }
        if ($read -le 0) { continue }
        # The sampler may be mid-write; only complete lines are consumed, and
        # the partial tail is read again once its newline lands.
        $end = [Array]::LastIndexOf($bytes, [byte]10, $read - 1)
        if ($end -lt 0) { continue }
        $cache.Offsets[$file.Name] = $offset + $end + 1
        foreach ($line in [Text.Encoding]::UTF8.GetString($bytes, 0, $end).Split("`n")) {
            $stamp = $timestamp.Match($line)
            if ($stamp.Success) {
                $lineUtc = [datetime]::MinValue
                if ([datetime]::TryParse($stamp.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$lineUtc) -and
                    $lineUtc.ToUniversalTime() -lt $cutoff) { continue }
            }
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($record.Kind -ne 'sample') { continue }
            $sample = ConvertTo-YurunaVmRunSample -Record $record
            # Samples without virtual-processor readings are kept: one taken while
            # the guest was powered off is what ends a pinned run at the power cycle.
            if ($sample.Utc -ge $cutoff) { $cache.Samples.Add($sample) }
        }
    }
    foreach ($name in @($cache.Offsets.Keys)) {
        if (-not [IO.File]::Exists((Join-Path $directory $name))) { $cache.Offsets.Remove($name) }
    }
    # Segments are read oldest first and lines in order, so the list is sorted.
    while ($cache.Samples.Count -and $cache.Samples[0].Utc -lt $cutoff) { $cache.Samples.RemoveAt(0) }
    return $cache.Samples.ToArray()
}

function Get-YurunaVmProcessorWindow {
    <# .SYNOPSIS
        Summarize each processor independently of the automatic recovery predicate.
    #>
    [CmdletBinding()]
    param([object[]]$Reading, [string]$VMKey, [int]$WindowSeconds, [int]$GapLimit)
    if (-not $Reading.Count) { return [pscustomobject]@{ SampleCount=0; Processors=@(); CounterCapabilities=@() } }
    $newest = $Reading[-1].Utc
    $cutoff = $newest.AddSeconds(-$WindowSeconds)
    $window = [Collections.Generic.List[object]]::new()
    $previous = $newest
    for ($i = $Reading.Count - 1; $i -ge 0; $i--) {
        $row = $Reading[$i]
        if ($row.Utc -lt $cutoff -or ($previous - $row.Utc).TotalSeconds -gt $GapLimit) { break }
        $window.Add($row)
        $previous = $row.Utc
    }
    $names = @('% Guest Run Time', '% Hypervisor Run Time', 'Total Intercepts/sec') + $script:LivelockCauseCounters
    $processorIds = @($window | ForEach-Object { $_.VMs[$VMKey].Keys } | Sort-Object -Unique)
    $processors = @(foreach ($id in $processorIds) {
        $counters = [ordered]@{}
        $observed = @($window | ForEach-Object { if ($_.VMs[$VMKey].ContainsKey($id)) { $_.VMs[$VMKey][$id].Keys } })
        foreach ($name in @(($names + $observed) | Sort-Object -Unique)) {
            $values = [Collections.Generic.List[double]]::new()
            foreach ($row in $window) {
                $vp = $row.VMs[$VMKey][$id]
                if (-not $vp -or $null -eq $vp[$name]) { continue }
                $value = [double]$vp[$name]
                if (-not [double]::IsFinite($value) -or $value -lt 0 -or ($name.StartsWith('%') -and $value -gt 100.5)) { continue }
                $values.Add($value)
            }
            $counters[$name] = [ordered]@{
                Status = if ($values.Count -eq 0) { 'unavailable' } elseif ($values.Count -eq $window.Count) { 'present' } else { 'partial' }
                Average = if ($values.Count) { [math]::Round(($values | Measure-Object -Average).Average, 2) } else { $null }
                SampleCount = $values.Count; UnavailableSampleCount = $window.Count - $values.Count
            }
        }
        # Compare paired readings only: missing causes must not become zeros
        # or use a different denominator from Total Intercepts/sec.
        $residuals = [Collections.Generic.List[double]]::new()
        foreach ($row in $window) {
            $vp = $row.VMs[$VMKey][$id]
            if (-not $vp -or $null -eq $vp['Total Intercepts/sec']) { continue }
            $total = [double]$vp['Total Intercepts/sec']
            if (-not [double]::IsFinite($total) -or $total -lt 0) { continue }
            $sum = 0.0; $complete = $true
            $absentCauses = @($row.CounterCapabilities | Where-Object { $_.Status -in @('absent','not-applicable') } | ForEach-Object Counter)
            foreach ($cause in $script:LivelockCauseCounters) {
                if ($null -eq $vp[$cause] -and $cause -in $absentCauses) { continue }
                if ($null -eq $vp[$cause] -or -not [double]::IsFinite([double]$vp[$cause]) -or $vp[$cause] -lt 0) { $complete=$false; break }
                $sum += $vp[$cause]
            }
            if ($complete) { $residuals.Add([math]::Max(0, $total - $sum)) }
        }
        [pscustomobject]@{
            Processor = [string]$id; Counters = $counters
            UnaccountedEstimatePerSecond = if ($residuals.Count) { [math]::Round(($residuals | Measure-Object -Average).Average) } else { $null }
            ResidualSampleCount = $residuals.Count
            ResidualStatus = if ($residuals.Count) { 'estimate-counter-categories-may-overlap' } else { 'unavailable-incomplete-counters' }
            ResidualUnavailableCounters = @($Reading[-1].CounterCapabilities | Where-Object { $_.Counter -in $script:LivelockCauseCounters -and $_.Status -in @('absent','not-applicable') } | ForEach-Object Counter)
        }
    })
    [pscustomobject]@{
        SampleCount=$window.Count; WindowSeconds=$WindowSeconds
        OldestSampleUtc=$window[-1].Utc.ToString('o'); NewestSampleUtc=$newest.ToString('o')
        Processors=$processors; CounterCapabilities=@($Reading[-1].CounterCapabilities)
    }
}

function Get-YurunaVmLivelockVerdict {
    <# .SYNOPSIS
        Decide whether every virtual processor of a VM has stayed pinned inside the hypervisor long enough to call the guest livelocked.
    .DESCRIPTION
        A guest that stopped making progress while its virtual processors keep
        trapping looks, from the console, like a guest that is merely slow:
        nothing new appears. The hypervisor's run-time split separates them. A
        reading counts toward the run when every virtual processor of the VM
        is at least 80% busy and the hypervisor holds at least 88% of that
        time. The run is the newest unbroken stretch of such readings.

        Every processor must be pinned at once because a healthy multi-vCPU
        guest routinely parks one processor in a spin wait while another
        works, and that processor alone shows the same split. Healthy guests on
        the ARM64 lab host hold the all-processor shape for at most half a
        minute; wedged ones hold it until they are powered off. A reading over
        100% (the counter's first sample after a VM starts) neither extends nor
        ends the run, and a gap in the recording ends it, because the run must
        be observed rather than assumed.

        A run never spans a power cycle the sampler saw: a sample whose Get-VM
        listing shows the VM not running ends it, and the next boot is judged
        on its own readings. A sample with no readings for a VM the host still
        listed as running is a failed counter read, a hole the gap limit judges
        like any other. The sampler can miss a restart that completes between
        two samples, so a caller that must not inherit a previous boot's run
        passes Since: readings taken before that instant are not judged.
    .OUTPUTS
        [pscustomobject] Verdict 'livelocked' | 'not-livelocked' | 'unavailable',
        LivelockedSeconds, the run's averages, InterceptBreakdown (mean per-cause
        rates, highest first; carries an 'Unaccounted/sec' entry, which can rank
        first, for the remainder the named causes do not explain), DominantIntercept,
        Detail and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [AllowEmptyCollection()][object[]]$Sample = @(),
        [datetime]$NowUtc = [datetime]::UtcNow,
        [ValidateRange(30, 86400)][int]$MinimumSeconds = 300,
        [ValidateRange(5, 300)][int]$IntervalSeconds = 15,
        [datetime]$Since = [datetime]::MinValue
    )
    $key = $VMName.ToLowerInvariant()
    $result = [ordered]@{
        Verdict = 'unavailable'; LivelockedSeconds = 0; MinimumSeconds = $MinimumSeconds; VirtualProcessors = 0
        GuestRunPercent = $null; HypervisorRunPercent = $null; InterceptsPerSecond = $null
        InterceptBreakdown = [ordered]@{}; DominantIntercept = ''; SampleCount = 0; NewestSampleUtc = ''
        Detail = ''; Reason = ''; ProcessorWindow = $null
    }
    # Compared as instants, the same way NowUtc is: a Local-kind value would
    # otherwise move the bound by the host's UTC offset.
    $sinceUtc = $Since.ToUniversalTime()
    $timeline = @($Sample | Where-Object { $_ -and $null -ne $_.VMs -and $_.Utc -ge $sinceUtc } | Sort-Object Utc)
    $readings = @($timeline | Where-Object { $_.VMs.ContainsKey($key) })
    if ($readings.Count -eq 0) {
        $result.Reason = 'The host recording holds no virtual-processor readings for this VM.'
        $result.Detail = $result.Reason
        return [pscustomobject]$result
    }
    # Only readings after the newest sample that lists the VM as not running
    # belong to the current boot. A sample without readings for a VM still
    # listed as running is left out and judged by the gap limit, like any hole.
    $stopped = @($timeline | Where-Object { -not $_.VMs.ContainsKey($key) -and $null -ne $_.Running -and -not $_.Running.ContainsKey($key) })
    if ($stopped.Count) { $readings = @($readings | Where-Object { $_.Utc -gt $stopped[-1].Utc }) }
    $gapLimit = [math]::Max(45, 3 * $IntervalSeconds)
    if ($readings.Count) {
        $result.ProcessorWindow = Get-YurunaVmProcessorWindow -Reading $readings -VMKey $key -WindowSeconds $MinimumSeconds -GapLimit $gapLimit
    }
    # With no reading since the VM was last listed as stopped, that listing is
    # the newest word on the guest: recent, it means no run is in progress.
    $newest = if ($readings.Count) { $readings[-1].Utc } else { $stopped[-1].Utc }
    $result.NewestSampleUtc = $newest.ToString('o')
    if (($NowUtc.ToUniversalTime() - $newest).TotalSeconds -gt $gapLimit) {
        $result.Reason = 'The newest host reading for this VM is too old to describe the guest now.'
        $result.Detail = $result.Reason
        return [pscustomobject]$result
    }
    $runStart = $null; $runEnd = $null; $previous = $null
    $guestSum = 0.0; $hypervisorSum = 0.0; $interceptSum = 0.0; $count = 0
    $causeSum = @{}
    for ($i = $readings.Count - 1; $i -ge 0; $i--) {
        $reading = $readings[$i]
        if ($previous -and ($previous - $reading.Utc).TotalSeconds -gt $gapLimit) { break }
        $previous = $reading.Utc
        $processors = $reading.VMs[$key]
        $valid = ($processors.Count -gt 0); $pinned = $true
        $guest = 0.0; $hypervisor = 0.0; $intercepts = 0.0
        foreach ($vp in $processors.Values) {
            $g = $vp['% Guest Run Time']; $h = $vp['% Hypervisor Run Time']
            if ($null -eq $g -or $null -eq $h -or -not [double]::IsFinite([double]$g) -or -not [double]::IsFinite([double]$h) -or $g -lt 0 -or $h -lt 0 -or $g -gt 100.5 -or $h -gt 100.5) { $valid = $false; break }
            $busy = $g + $h
            if ($busy -lt 80 -or ($h / $busy) -lt 0.88) { $pinned = $false }
            $guest += $g; $hypervisor += $h
            if ($null -ne $vp['Total Intercepts/sec']) { $intercepts += $vp['Total Intercepts/sec'] }
        }
        if (-not $valid) { continue }
        if (-not $pinned) { break }
        if (-not $runEnd) { $runEnd = $reading.Utc; $result.VirtualProcessors = $processors.Count }
        $runStart = $reading.Utc
        $count++
        $guestSum += $guest / $processors.Count
        $hypervisorSum += $hypervisor / $processors.Count
        $interceptSum += $intercepts
        foreach ($cause in $script:LivelockCauseCounters) {
            $rate = 0.0; $seen = $false
            foreach ($vp in $processors.Values) { if ($null -ne $vp[$cause]) { $rate += $vp[$cause]; $seen = $true } }
            if ($seen) { $causeSum[$cause] = [double]($causeSum[$cause]) + $rate }
        }
    }
    $result.SampleCount = $count
    if ($runEnd) {
        $result.LivelockedSeconds = [int]($runEnd - $runStart).TotalSeconds
        $result.GuestRunPercent = [math]::Round($guestSum / $count, 1)
        $result.HypervisorRunPercent = [math]::Round($hypervisorSum / $count, 1)
        $result.InterceptsPerSecond = [math]::Round($interceptSum / $count)
        foreach ($cause in @($causeSum.Keys | Sort-Object { $causeSum[$_] } -Descending)) {
            $result.InterceptBreakdown[$cause] = [math]::Round($causeSum[$cause] / $count)
        }
        # The named causes above are a bounded list, not every PDH sub-counter
        # Hyper-V Hypervisor Virtual Processor carries. What they leave
        # unexplained against the measured total is itself a reading -- the
        # record says "not yet named" rather than implying nothing was
        # trapping once the known causes run out, which a breakdown that
        # silently stopped at its own list would otherwise read as.
        $namedSum = ([double[]]@($result.InterceptBreakdown.Values) | Measure-Object -Sum).Sum
        $unaccounted = [math]::Round($result.InterceptsPerSecond - $namedSum)
        if ($unaccounted -gt 0) { $result.InterceptBreakdown[$script:LivelockUnaccountedLabel] = $unaccounted }
        # Re-rank now that Unaccounted/sec may belong anywhere in the order,
        # including first, so a reader scanning the JSON keys top-to-bottom
        # sees the true ranking rather than Unaccounted/sec always trailing.
        $ranked = [ordered]@{}
        foreach ($cause in @($result.InterceptBreakdown.Keys | Sort-Object { $result.InterceptBreakdown[$_] } -Descending)) {
            $ranked[$cause] = $result.InterceptBreakdown[$cause]
        }
        $result.InterceptBreakdown = $ranked
        $top = @($ranked.Keys)
        if ($top.Count -and $ranked[$top[0]] -gt 0) { $result.DominantIntercept = [string]$top[0] }
        $result.Detail = Format-YurunaOperatorMessage -Key 'runner.operator_33a0b7c1e1b2be21' -Arguments @{
            processors = "$($result.VirtualProcessors)"; guestPercent = "$($result.GuestRunPercent)"
            hypervisorPercent = "$($result.HypervisorRunPercent)"; interceptsPerSecond = "$($result.InterceptsPerSecond)"
            seconds = "$($result.LivelockedSeconds)"
        }
    } else {
        $result.Reason = 'The newest host reading does not show every virtual processor pinned in the hypervisor.'
        $result.Detail = $result.Reason
    }
    $result.Verdict = if ($result.LivelockedSeconds -ge $MinimumSeconds) { 'livelocked' } else { 'not-livelocked' }
    return [pscustomobject]$result
}

function Get-YurunaVmLivelockState {
    <# .SYNOPSIS
        Read the live host recording and return the livelock verdict for one VM.
    .OUTPUTS
        The verdict, or $null when no host recording exists to judge from --
        a host without sampling has not measured anything, which is not the
        same as having measured and found no readings for the VM.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$RuntimeDirectory = $env:YURUNA_RUNTIME_DIR,
        [ValidateRange(30, 86400)][int]$MinimumSeconds = 300,
        # Readings older than this are not judged; a wait passes its own start.
        [datetime]$Since = [datetime]::MinValue
    )
    $samples = @(Read-YurunaHostVmRunSample -RuntimeDirectory $RuntimeDirectory -WindowSeconds ([math]::Max(3600, 2 * $MinimumSeconds)))
    if (-not $script:VmRunCache.Directory) { return $null }
    Get-YurunaVmLivelockVerdict -VMName $VMName -Sample $samples -MinimumSeconds $MinimumSeconds -IntervalSeconds (Get-YurunaHostSamplingSetting).IntervalSeconds -Since $Since
}

Export-ModuleMember -Function Invoke-YurunaHostBoundedCommand, Get-YurunaHostSamplingSetting, Get-YurunaHostCounterSpecification, Resolve-YurunaHostCounterCapability, Get-YurunaHostCounterInventory, Get-YurunaHostPowerStatus, Get-YurunaHostVmSnapshot, Get-YurunaHostSampleInfo, ConvertTo-YurunaHostCounterSample, Write-YurunaHostSampleRecord, Invoke-YurunaHostSampling, Start-YurunaHostSampling, Stop-YurunaHostSampling, Save-YurunaHostSampleSnapshot, ConvertTo-YurunaVmRunSample, Read-YurunaHostVmRunSample, Get-YurunaVmLivelockVerdict, Get-YurunaVmLivelockState
