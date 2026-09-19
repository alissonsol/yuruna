<#PSScriptInfo
.VERSION 2026.09.18
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
    $groups = [ordered]@{
        'Hyper-V Hypervisor Virtual Processor' = @('% Guest Run Time','% Hypervisor Run Time','% Total Run Time','Total Intercepts/sec','Other Intercepts/sec','Total Intercepts Cost','CPU Wait Time Per Dispatch','Logical Processor Dispatches/sec','CPU Wake Up Time Per Dispatch','CPU Contention Time Per Dispatch')
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
    foreach ($spec in Get-YurunaHostCounterSpecification) {
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
        $sets = @(Get-Counter -ListSet * -ErrorAction Stop | Select-Object CounterSetName, Paths, PathsWithInstances, Description)
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
    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
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
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Directory 'counter-inventory.json') -Encoding utf8
    Import-Module (Join-Path $PSScriptRoot 'Test.HostMetricsExporter.psm1') -Global -Force -ErrorAction Stop
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds -and -not (Test-Path (Join-Path $Directory 'stop'))) {
        if ($OwnerProcessId -gt 0 -and -not (Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue)) { break }
        $start = $timer.Elapsed.TotalSeconds
        $vm = Get-YurunaHostVmSnapshot
        $capabilities = @(Resolve-YurunaHostCounterCapability -CounterSets $inventory.CounterSets -NameMap $inventory.NameMap -RunningVmCount $vm.RunningCount)
        $paths = @($capabilities | Where-Object Status -EQ 'present' | ForEach-Object Paths | Select-Object -Unique)
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
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int]($remaining * 1000)) }
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
                        $bytes = [IO.File]::ReadAllBytes($file.FullName)
                        if ($file.Extension -eq '.ndjson' -and $bytes.Length -and $bytes[-1] -ne 10) {
                            $lastNewline = [Array]::LastIndexOf($bytes, [byte]10)
                            $bytes = if ($lastNewline -ge 0) { [byte[]]$bytes[0..$lastNewline] } else { [byte[]]@() }
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

Export-ModuleMember -Function Invoke-YurunaHostBoundedCommand, Get-YurunaHostSamplingSetting, Get-YurunaHostCounterSpecification, Resolve-YurunaHostCounterCapability, Get-YurunaHostCounterInventory, Get-YurunaHostPowerStatus, Get-YurunaHostVmSnapshot, Get-YurunaHostSampleInfo, ConvertTo-YurunaHostCounterSample, Write-YurunaHostSampleRecord, Invoke-YurunaHostSampling, Start-YurunaHostSampling, Stop-YurunaHostSampling, Save-YurunaHostSampleSnapshot
