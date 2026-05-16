<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456720
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna diagnostics system health docker kubernetes
.LICENSEURI https://yuruna.com
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
    Read-only system diagnostics dump: host metrics, Docker state, Kubernetes
    state, and a "problems detected" summary aggregating any signal that
    typically indicates trouble on a Yuruna test host.

.DESCRIPTION
    Sections (each gracefully skipped if its tool is unavailable):
      1. HOST    -- hostname, OS, kernel, uptime, PowerShell, time
      2. CPU     -- model, core count, load average / busy %
      3. MEMORY  -- total / used / available / swap
      4. DISK    -- free space per filesystem; flag any > 90% full
      5. GPU     -- vendor + driver where detectable
      6. NETWORK -- interfaces, default route, DNS resolution sanity
      7. TOP     -- top processes by CPU and by memory
      8. EVENTS  -- recent kernel/system errors
      9. DOCKER  -- daemon health, containers (all), images, disk usage
     10. KUBE    -- cluster info, nodes, all-namespaces inventory,
                    port-forwards (detected via host-process scan),
                    recent Warning events
     11. LINUX   -- (Linux only) netplan + /etc/resolv.conf + /etc/hosts,
                    resolvectl/systemd-resolve status, ip route (full),
                    ss listening sockets, ping connectivity probe,
                    iptables -S + nft list ruleset, dmesg -T (with OOM
                    scan), lsmod (virtualization modules), journalctl
                    -xe, per-unit journals for docker/containerd/kubelet,
                    /opt/cni/bin/ + /etc/cni/net.d/ state.
     12. YURUNA PROJECT -- ../project tree scan for resources.output.yml
                    files (path + content + empty-block analysis) and a
                    grep across every .yuruna/ working folder for any
                    line mentioning error/fail/warning, so a stuck cycle
                    can be triaged from one diagnostic dump.
     13. SUMMARY -- list of problems detected

    Side-effect-free: nothing is started, stopped, or modified.

    Implementation details (what each section reports + helper contracts):
        https://yuruna.link/definition#defining-get-systemdiagnostic
    Incident-driven design rationale (per-section "Why ..." entries):
        https://yuruna.link/memory#system-diagnostics

.PARAMETER OutFile
    Optional: also tee output to this path.

.PARAMETER SkipKube
    Skip the Kubernetes section even if kubectl is available
    (useful when kubectl would block on a stale context).

.PARAMETER SkipDocker
    Skip the Docker section even if docker is available.

.PARAMETER logLevel
    One of Error|Warning|Information|Verbose|Debug. Each level shows
    itself + all higher-priority streams (Error highest). Default
    'Information' so the section banners show by default.

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1 -OutFile diag.txt

.EXAMPLE
    pwsh automation/Get-SystemDiagnostic.ps1 -SkipKube > diag.txt
#>

param(
    [string]$OutFile = $null,
    [switch]$SkipDocker,
    [switch]$SkipKube,
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel = 'Information'
)
Write-Debug "Get-SystemDiagnostic: skipDocker=$SkipDocker skipKube=$SkipKube logLevel=$logLevel"

$_logRank = @{ Error=1; Warning=2; Information=3; Verbose=4; Debug=5 }
$_logEff  = $_logRank[$logLevel]
$global:WarningPreference     = if ($_logRank.Warning     -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:InformationPreference = if ($_logRank.Information -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:VerbosePreference     = if ($_logRank.Verbose     -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }
$global:DebugPreference       = if ($_logRank.Debug       -le $_logEff) { 'Continue' } else { 'SilentlyContinue' }

$script:Problems = [System.Collections.Generic.List[string]]::new()

function Write-Section {
    param([string]$Title)
    Write-Output ""
    Write-Output "============================================================"
    Write-Output "  $Title"
    Write-Output "============================================================"
}
function Write-Sub {
    param([string]$Title)
    Write-Output ""
    Write-Output "--- $Title ---"
}
function Add-Problem {
    param([string]$Message)
    $script:Problems.Add($Message) | Out-Null
}

function Invoke-DiagnosticSection {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    Write-Section $Title
    try {
        & $Body
    } catch {
        Write-Output ""
        Write-Output ("** ERROR in section '{0}': {1}" -f $Title, $_.Exception.Message)
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            $firstPosLine = ($_.InvocationInfo.PositionMessage -split "`r?`n" | Select-Object -First 1)
            if ($firstPosLine) { Write-Output ("   {0}" -f $firstPosLine.Trim()) }
        }
        Add-Problem ("Section '{0}' aborted: {1}" -f $Title, $_.Exception.Message)
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgs = @(),
        [string]$ProblemTag = $null
    )
    try {
        & $Tool @ToolArgs 2>&1 | ForEach-Object { Write-Output ($_.ToString()) }
        if ($LASTEXITCODE -ne 0 -and $ProblemTag) {
            Add-Problem "$($ProblemTag): exit code $LASTEXITCODE from '$Tool $($ToolArgs -join ' ')'."
        }
    } catch {
        if ($ProblemTag) { Add-Problem "$($ProblemTag): $($_.Exception.Message)" }
        Write-Output "  (error: $($_.Exception.Message))"
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    return ($null -ne (Get-Command $Name -ErrorAction SilentlyContinue))
}

function Format-ByteCount {
    param([Parameter(Mandatory)][double]$Bytes)
    $units = 'B','KB','MB','GB','TB','PB'
    $i = 0
    $v = $Bytes
    while ($v -ge 1024 -and $i -lt $units.Count - 1) { $v /= 1024; $i++ }
    return ('{0:N2} {1}' -f $v, $units[$i])
}

$transcriptStarted = $false
if ($OutFile) {
    try {
        $transcriptStarted = $true
        Start-Transcript -Path $OutFile -Force | Out-Null
    } catch {
        Write-Warning "Could not start transcript to '$OutFile': $($_.Exception.Message). Continuing without -OutFile."
        $transcriptStarted = $false
    }
}

try {

    # ===== 1. HOST =====================================================
    Invoke-DiagnosticSection "HOST" {
    $platform = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { 'Unknown' }
    Write-Output ("Platform     : {0}" -f $platform)
    Write-Output ("Hostname     : {0}" -f [System.Net.Dns]::GetHostName())
    Write-Output ("Time (UTC)   : {0}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Write-Output ("Time (local) : {0}" -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))
    Write-Output ("PowerShell   : {0}" -f $PSVersionTable.PSVersion)
    Write-Output ("Edition      : {0}" -f $PSVersionTable.PSEdition)
    if ($IsWindows) {
        $osi = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($osi) {
            Write-Output ("OS Version   : {0} (build {1})" -f $osi.Caption, $osi.BuildNumber)
            Write-Output ("Last boot    : {0}" -f $osi.LastBootUpTime)
            $up = (Get-Date) - $osi.LastBootUpTime
            Write-Output ("Uptime       : {0:F1} hours" -f $up.TotalHours)
        }
    } elseif ($IsMacOS) {
        Write-Sub "uname -a"
        Invoke-Tool -Tool '/usr/bin/uname' -ToolArgs @('-a')
        Write-Sub "sw_vers"
        Invoke-Tool -Tool '/usr/bin/sw_vers'
        Write-Sub "uptime"
        Invoke-Tool -Tool '/usr/bin/uptime'
    } elseif ($IsLinux) {
        Write-Sub "uname -a"
        Invoke-Tool -Tool 'uname' -ToolArgs @('-a')
        if (Test-Path '/etc/os-release') {
            Write-Sub "/etc/os-release"
            Get-Content '/etc/os-release' | Where-Object { $_ -match '^(NAME|VERSION|PRETTY_NAME)=' } | ForEach-Object { Write-Output $_ }
        }
        Write-Sub "uptime"
        Invoke-Tool -Tool 'uptime'
    }
    }

    # ===== 2. CPU ======================================================
    Invoke-DiagnosticSection "CPU" {
    if ($IsWindows) {
        $cpus = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue
        if ($cpus) {
            foreach ($c in $cpus) {
                Write-Output ("Model     : {0}" -f $c.Name)
                Write-Output ("Cores     : {0} physical / {1} logical" -f $c.NumberOfCores, $c.NumberOfLogicalProcessors)
                Write-Output ("Max clock : {0} MHz" -f $c.MaxClockSpeed)
                Write-Output ("Load %    : {0}" -f $c.LoadPercentage)
                Write-Output ""
            }
            $busy = ($cpus | Measure-Object LoadPercentage -Average).Average
            if ($busy -ge 90) { Add-Problem "CPU: average load $([math]::Round($busy,1))% across all logical processors (>=90)." }
        }
    } elseif ($IsMacOS) {
        Write-Sub "sysctl -n machdep.cpu.brand_string / hw.ncpu"
        Invoke-Tool -Tool '/usr/sbin/sysctl' -ToolArgs @('-n','machdep.cpu.brand_string')
        Invoke-Tool -Tool '/usr/sbin/sysctl' -ToolArgs @('-n','hw.ncpu')
        Write-Sub "top -l 1 (CPU header)"
        & '/usr/bin/top' -l 1 -n 0 2>$null | Select-Object -First 12 | ForEach-Object { Write-Output $_ }
    } elseif ($IsLinux) {
        $cores = 0
        if (Test-Path '/proc/cpuinfo') {
            $modelLine = Get-Content '/proc/cpuinfo' | Where-Object { $_ -match '^model name' } | Select-Object -First 1
            $model = if ($modelLine) {
                ($modelLine -replace '^model name\s*:\s*', '').Trim()
            } else {
                '(unknown -- no "model name" line in /proc/cpuinfo)'
            }
            $cores = @(Get-Content '/proc/cpuinfo' | Where-Object { $_ -match '^processor' }).Count
            Write-Output "Model : $model"
            Write-Output "Cores : $cores"
        }
        if (Test-Path '/proc/loadavg') {
            $load = (Get-Content '/proc/loadavg').Trim()
            Write-Output "Load  : $load"
            $load1m = [double](($load -split '\s+')[0])
            if ($cores -gt 0 -and $load1m -gt ($cores * 1.5)) {
                Add-Problem "CPU: 1-min load $load1m exceeds 1.5x cores ($cores)."
            }
        }
    }
    }

    # ===== 3. MEMORY ===================================================
    Invoke-DiagnosticSection "MEMORY" {
    if ($IsWindows) {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $totalKb = [int64]$os.TotalVisibleMemorySize
            $freeKb  = [int64]$os.FreePhysicalMemory
            $used    = ($totalKb - $freeKb) * 1KB
            $total   = $totalKb * 1KB
            $free    = $freeKb * 1KB
            Write-Output ("Total : {0}" -f (Format-ByteCount $total))
            Write-Output ("Used  : {0}" -f (Format-ByteCount $used))
            Write-Output ("Free  : {0}" -f (Format-ByteCount $free))
            $pct = ($used / $total) * 100
            Write-Output ("Used%: {0:N1}%" -f $pct)
            if ($pct -ge 90) { Add-Problem ("MEMORY: {0:N1}% used (>=90%)." -f $pct) }
            Write-Output ("Page file total : {0}" -f (Format-ByteCount ($os.SizeStoredInPagingFiles * 1KB)))
            Write-Output ("Page file free  : {0}" -f (Format-ByteCount ($os.FreeSpaceInPagingFiles * 1KB)))
        }
    } elseif ($IsMacOS) {
        Write-Sub "vm_stat"
        Invoke-Tool -Tool '/usr/bin/vm_stat'
        Write-Sub "top -l 1 PhysMem"
        & '/usr/bin/top' -l 1 -n 0 2>$null | Select-String -Pattern 'PhysMem' | ForEach-Object { Write-Output $_ }
    } elseif ($IsLinux) {
        if (Test-Path '/proc/meminfo') {
            $mi = Get-Content '/proc/meminfo'
            $mi | Where-Object { $_ -match '^(MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree|Buffers|Cached):' } | ForEach-Object { Write-Output $_ }
            $totalKb = 0
            $availKb = 0
            foreach ($line in $mi) {
                if ($line -match '^MemTotal:\s*(\d+)')         { $totalKb = [int64]$Matches[1] }
                elseif ($line -match '^MemAvailable:\s*(\d+)') { $availKb = [int64]$Matches[1] }
            }
            if ($totalKb -gt 0) {
                $usedPct = (1 - ($availKb / $totalKb)) * 100
                Write-Output ("Available%: {0:N1}% used (1 - MemAvailable/MemTotal)" -f $usedPct)
                if ($usedPct -ge 90) { Add-Problem ("MEMORY: {0:N1}% used (>=90%)." -f $usedPct) }
            }
        }
    }
    }

    # ===== 4. DISK =====================================================
    Invoke-DiagnosticSection "DISK" {
    if ($IsWindows) {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        if ($disks) {
            $disks | ForEach-Object {
                $tot = [double]$_.Size
                $fre = [double]$_.FreeSpace
                $used = $tot - $fre
                $pct = if ($tot -gt 0) { ($used / $tot) * 100 } else { 0 }
                Write-Output ("{0}  size={1}  free={2}  used={3:N1}%  fs={4}" -f `
                    $_.DeviceID, (Format-ByteCount $tot), (Format-ByteCount $fre), $pct, $_.FileSystem)
                if ($pct -ge 90) { Add-Problem ("DISK: {0} is {1:N1}% full." -f $_.DeviceID, $pct) }
            }
        }
    } else {
        Write-Sub "df -h (local filesystems)"
        if ($IsMacOS) {
            Invoke-Tool -Tool '/bin/df' -ToolArgs @('-h','-l')
        } else {
            Invoke-Tool -Tool 'df' -ToolArgs @('-h','-x','tmpfs','-x','devtmpfs','-x','squashfs','-x','overlay')
        }
        $dfArgs = if ($IsMacOS) { @('-Pl') } else { @('-Pl','-x','tmpfs','-x','devtmpfs','-x','squashfs','-x','overlay') }
        $dfBin = if ($IsMacOS) { '/bin/df' } else { 'df' }
        $lines = & $dfBin @dfArgs 2>$null | Select-Object -Skip 1
        foreach ($l in $lines) {
            $cols = $l -split '\s+'
            if ($cols.Count -ge 6) {
                $usePct = $cols[4] -replace '%',''
                if ($usePct -as [int] -and [int]$usePct -ge 90) {
                    Add-Problem ("DISK: {0} is {1}% full (mounted at {2})." -f $cols[0], $usePct, $cols[5])
                }
            }
        }
    }
    }

    # ===== 5. GPU ======================================================
    Invoke-DiagnosticSection "GPU" {
    if (Test-CommandAvailable 'nvidia-smi') {
        Write-Sub "nvidia-smi"
        Invoke-Tool -Tool 'nvidia-smi' -ToolArgs @('--query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu', '--format=csv')
    } else {
        Write-Output "(nvidia-smi not present; using platform fallback)"
        if ($IsWindows) {
            $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            if ($vc) {
                $vc | ForEach-Object {
                    Write-Output ("GPU       : {0}" -f $_.Name)
                    Write-Output ("Driver    : {0}" -f $_.DriverVersion)
                    Write-Output ("VRAM      : {0}" -f (Format-ByteCount ([double]$_.AdapterRAM)))
                    Write-Output ""
                }
            }
        } elseif ($IsMacOS) {
            Write-Sub "system_profiler SPDisplaysDataType (truncated)"
            $out = & '/usr/sbin/system_profiler' SPDisplaysDataType 2>$null
            $out | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
        } elseif ($IsLinux) {
            if (Test-CommandAvailable 'lspci') {
                Write-Sub "lspci -nnk | grep -A2 -E 'VGA|3D|Display'"
                & lspci -nnk 2>$null | Out-String | ForEach-Object {
                    ($_ -split "`n") | Where-Object { $_ -match 'VGA|3D|Display' -or $_ -match '^\s+(Subsystem|Kernel)' } |
                        ForEach-Object { Write-Output $_ }
                }
            } else {
                Write-Output "(lspci not installed; install pciutils for GPU detail)"
            }
        }
    }
    }

    # ===== 6. NETWORK ==================================================
    Invoke-DiagnosticSection "NETWORK" {
    if ($IsWindows) {
        Write-Sub "Get-NetIPAddress (IPv4)"
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
            Select-Object IPAddress, InterfaceAlias, PrefixLength, AddressState |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
        Write-Sub "Default route"
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1 | Format-List | Out-String | ForEach-Object { Write-Output $_ }
    } else {
        Write-Sub "ifconfig (interfaces with IPv4)"
        if ($IsMacOS) {
            & /sbin/ifconfig 2>$null | Out-String | ForEach-Object { Write-Output $_ }
        } else {
            Invoke-Tool -Tool 'ip' -ToolArgs @('-brief','addr')
        }
        Write-Sub "Default route"
        if ($IsMacOS) {
            Invoke-Tool -Tool '/sbin/route' -ToolArgs @('-n','get','default')
        } else {
            Invoke-Tool -Tool 'ip' -ToolArgs @('-4','route','show','default')
        }
    }
    Write-Sub "DNS resolution probe (one.one.one.one)"
    try {
        $r = [System.Net.Dns]::GetHostAddresses('one.one.one.one')
        if ($r) { $r | ForEach-Object { Write-Output ("  {0}" -f $_.IPAddressToString) } }
    } catch {
        Write-Output "  FAILED: $($_.Exception.Message)"
        Add-Problem "NETWORK: DNS resolution of 'one.one.one.one' failed -- check resolver configuration."
    }
    }

    # ===== 7. TOP PROCESSES ============================================
    Invoke-DiagnosticSection "TOP PROCESSES" {
    Write-Sub "Top 10 by CPU"
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CPU -ne $null } |
        Sort-Object CPU -Descending |
        Select-Object -First 10 |
        Select-Object @{n='PID';e={$_.Id}}, ProcessName, @{n='CPU(s)';e={[math]::Round($_.CPU,1)}}, @{n='WS(MB)';e={[math]::Round($_.WorkingSet64/1MB,1)}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
    Write-Sub "Top 10 by memory"
    Get-Process -ErrorAction SilentlyContinue |
        Sort-Object WorkingSet64 -Descending |
        Select-Object -First 10 |
        Select-Object @{n='PID';e={$_.Id}}, ProcessName, @{n='WS(MB)';e={[math]::Round($_.WorkingSet64/1MB,1)}}, @{n='Threads';e={$_.Threads.Count}} |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }
    }

    # ===== 8. RECENT EVENTS ============================================
    Invoke-DiagnosticSection "RECENT SYSTEM EVENTS (errors / warnings)" {
    if ($IsWindows) {
        Write-Sub "Get-WinEvent System -- Errors in last 1h"
        try {
            $sysErr = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=2; StartTime=(Get-Date).AddHours(-1) } -ErrorAction Stop |
                Select-Object -First 15
            if ($sysErr) {
                $sysErr | Select-Object TimeCreated, Id, ProviderName, @{n='Message';e={$_.Message -replace "`r?`n",' '}} |
                    Format-Table -AutoSize -Wrap | Out-String | ForEach-Object { Write-Output $_ }
                if ($sysErr.Count -ge 5) { Add-Problem "EVENTS: $($sysErr.Count)+ System Error events in the last hour." }
            } else {
                Write-Output "(no errors in the last hour)"
            }
        } catch {
            Write-Output "(query failed: $($_.Exception.Message))"
        }
    } elseif ($IsLinux) {
        if (Test-CommandAvailable 'journalctl') {
            Write-Sub "journalctl -p err -n 20 --no-pager (since 1h ago)"
            $jc = & journalctl -p err -n 20 --since '1 hour ago' --no-pager 2>$null
            $count = ($jc | Measure-Object).Count
            if ($count -gt 0) {
                $jc | ForEach-Object { Write-Output $_ }
                if ($count -ge 10) { Add-Problem "EVENTS: $count journalctl error entries in the last hour." }
            } else { Write-Output "(no error entries in the last hour)" }
        } elseif (Test-Path '/var/log/syslog') {
            Write-Sub "tail /var/log/syslog (last 30 lines)"
            Get-Content '/var/log/syslog' -Tail 30 | ForEach-Object { Write-Output $_ }
        }
    } elseif ($IsMacOS) {
        if (Test-CommandAvailable 'dmesg') {
            Write-Sub "dmesg | tail -n 30"
            try {
                $dm = & dmesg 2>$null | Select-Object -Last 30
                $dm | ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output "(dmesg requires elevation; skipping)"
            }
        }
    }
    }

    # ===== 9. DOCKER ===================================================
    Invoke-DiagnosticSection "DOCKER" {
    if ($SkipDocker) {
        Write-Output "(skipped via -SkipDocker)"
    } elseif (-not (Test-CommandAvailable 'docker')) {
        Write-Output "docker command not found in PATH."
        Add-Problem "DOCKER: docker not installed (or not in PATH)."
    } else {
        $null = & docker info --format '{{.ServerVersion}}' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Output "Docker CLI present but daemon unreachable."
            Add-Problem "DOCKER: daemon unreachable (`docker info` failed)."
        } else {
            Write-Sub "docker version (client+server)"
            Invoke-Tool -Tool 'docker' -ToolArgs @('version','--format','Client: {{.Client.Version}} ({{.Client.Os}}/{{.Client.Arch}})`nServer: {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})')
            Write-Sub "docker info (selected fields)"
            $info = & docker info --format '{{json .}}' 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($info) {
                Write-Output ("Containers     : total={0}, running={1}, paused={2}, stopped={3}" -f $info.Containers, $info.ContainersRunning, $info.ContainersPaused, $info.ContainersStopped)
                Write-Output ("Images         : {0}" -f $info.Images)
                Write-Output ("Storage driver : {0}" -f $info.Driver)
                Write-Output ("Server version : {0}" -f $info.ServerVersion)
                Write-Output ("Cgroup driver  : {0}" -f $info.CgroupDriver)
                Write-Output ("Kernel version : {0}" -f $info.KernelVersion)
                Write-Output ("Operating sys  : {0}" -f $info.OperatingSystem)
                if ($info.Warnings -and $info.Warnings.Count -gt 0) {
                    Write-Output "Warnings:"
                    foreach ($w in $info.Warnings) { Write-Output "  - $w"; Add-Problem "DOCKER: warning -- $w" }
                }
            }
            Write-Sub "docker ps -a (all containers)"
            Invoke-Tool -Tool 'docker' -ToolArgs @('ps','-a','--format','table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}')
            $rows = & docker ps -a --format '{{.Names}}|{{.Status}}' 2>$null
            foreach ($r in $rows) {
                $parts = $r -split '\|', 2
                if ($parts.Count -ne 2) { continue }
                $name = $parts[0]; $status = $parts[1]
                if ($status -match '^Restarting' -or $status -match 'unhealthy' -or $status -match 'Dead') {
                    Add-Problem "DOCKER: container '$name' status: $status"
                }
            }
            Write-Sub "docker images (top 100 by size)"
            $imgsRaw = & docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Output ("(docker images returned exit {0})" -f $LASTEXITCODE)
            } else {
                $rows = @($imgsRaw | Where-Object { $_ -match '\|' } | ForEach-Object {
                    $parts = $_ -split '\|', 5
                    $bytes = 0
                    if ($parts[3] -match '^([\d.]+)\s*([kMGT]?B)$') {
                        $n = [double]$matches[1]
                        switch ($matches[2]) {
                            'B'  { $bytes = $n }
                            'kB' { $bytes = $n * 1KB }
                            'MB' { $bytes = $n * 1MB }
                            'GB' { $bytes = $n * 1GB }
                            'TB' { $bytes = $n * 1TB }
                        }
                    }
                    [PSCustomObject]@{
                        Repository = $parts[0]; Tag = $parts[1]; Id = $parts[2]
                        Size = $parts[3]; Bytes = $bytes; Created = $parts[4]
                    }
                })
                $sorted = $rows | Sort-Object Bytes -Descending | Select-Object -First 100
                Write-Output ("{0,-50} {1,-15} {2,-12} {3,10}  {4}" -f 'REPOSITORY','TAG','IMAGE ID','SIZE','CREATED')
                foreach ($r in $sorted) {
                    Write-Output ("{0,-50} {1,-15} {2,-12} {3,10}  {4}" -f $r.Repository, $r.Tag, $r.Id, $r.Size, $r.Created)
                }
                if ($rows.Count -gt 100) {
                    Write-Output ("(... {0} smaller image(s) omitted)" -f ($rows.Count - 100))
                }
            }
            Write-Sub "docker stats --no-stream (running containers)"
            Invoke-Tool -Tool 'docker' -ToolArgs @('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}')
            Write-Sub "docker system df"
            Invoke-Tool -Tool 'docker' -ToolArgs @('system','df')

            Write-Sub "Local registry catalog (probe http://localhost:5000/v2/_catalog)"
            try {
                $probe = Invoke-WebRequest -Uri 'http://localhost:5000/v2/_catalog' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                if ($probe -and $probe.Content) {
                    $catalog = $probe.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($catalog -and $catalog.repositories) {
                        $repos = @($catalog.repositories)
                        Write-Output "Repositories ($($repos.Count)):"
                        foreach ($repo in $repos) { Write-Output ("  {0}" -f $repo) }
                        if ($repos.Count -eq 0) {
                            Add-Problem "REGISTRY: local registry on :5000 is reachable but its catalog is empty -- no images have been pushed (or the registry's storage was reset)."
                        }
                    } else {
                        Write-Output "(registry returned non-JSON content)"
                    }
                }
            } catch {
                Write-Output "(no registry on http://localhost:5000 -- this is normal on hosts that don't use the localhost flow)"
            }
        }
    }
    }

    # ===== 10. KUBERNETES ==============================================
    Invoke-DiagnosticSection "KUBERNETES" {
    if ($SkipKube) {
        Write-Output "(skipped via -SkipKube)"
    } elseif (-not (Test-CommandAvailable 'kubectl')) {
        Write-Output "kubectl command not found in PATH."
        Add-Problem "KUBE: kubectl not installed (or not in PATH)."
    } else {
        Write-Sub "kubectl version"
        $kv = & kubectl version --output=json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($kv) {
            if ($kv.clientVersion) { Write-Output ("Client : {0}" -f $kv.clientVersion.gitVersion) }
            if ($kv.serverVersion) { Write-Output ("Server : {0}" -f $kv.serverVersion.gitVersion) }
            else { Write-Output "Server : (unreachable)" ; Add-Problem "KUBE: server version unavailable -- cluster may be unreachable." }
        }
        Write-Sub "Current context"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('config','current-context')

        Write-Sub "kubectl get nodes -o wide"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','nodes','-o','wide')
        $nodes = & kubectl get nodes --no-headers 2>$null
        foreach ($n in $nodes) {
            $cols = $n -split '\s+'
            if ($cols.Count -ge 2 -and $cols[1] -notmatch '^Ready') {
                Add-Problem "KUBE: node '$($cols[0])' status: $($cols[1])"
            }
        }

        Write-Sub "Namespaces"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ns')

        Write-Sub "Pods (all namespaces, -o wide)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pods','-A','-o','wide')
        $pods = & kubectl get pods -A --no-headers 2>$null
        foreach ($p in $pods) {
            $cols = $p -split '\s+'
            if ($cols.Count -lt 6) { continue }
            $ns      = $cols[0]
            $name    = $cols[1]
            $ready   = $cols[2]
            $status  = $cols[3]
            $restarts = $cols[4] -replace '\(.*\)',''
            $restartCount = 0
            [int]::TryParse($restarts, [ref]$restartCount) | Out-Null
            if ($status -notin @('Running','Completed','Succeeded')) {
                Add-Problem "KUBE: pod $ns/$name status: $status (ready $ready)"
            } elseif ($restartCount -ge 5) {
                Add-Problem "KUBE: pod $ns/$name has $restartCount restarts."
            }
        }

        Write-Sub "Services (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','svc','-A')

        Write-Sub "Deployments (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','deploy','-A')

        Write-Sub "DaemonSets (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ds','-A')

        Write-Sub "StatefulSets (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','sts','-A')

        Write-Sub "Jobs / CronJobs (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','jobs,cronjobs','-A')

        Write-Sub "Ingresses (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ingress','-A')

        Write-Sub "PersistentVolumes / PVCs"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pv,pvc','-A')

        Write-Sub "ConfigMaps + Secrets (counts only)"
        $cmCount = (& kubectl get cm  -A --no-headers 2>$null | Measure-Object).Count
        $scCount = (& kubectl get secret -A --no-headers 2>$null | Measure-Object).Count
        Write-Output ("ConfigMaps : {0}" -f $cmCount)
        Write-Output ("Secrets    : {0}" -f $scCount)

        Write-Sub "Recent Warning events (last 100 across all namespaces)"
        $evts = @(& kubectl get events -A --field-selector type=Warning --sort-by .lastTimestamp 2>&1)
        if ($evts.Count -gt 1) {
            Write-Output $evts[0]
            $rows = $evts | Select-Object -Skip 1
            $rows | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            if ($rows.Count -gt 100) { Write-Output ("(... {0} older warning(s) omitted)" -f ($rows.Count - 100)) }
        } else {
            $evts | ForEach-Object { Write-Output $_ }
        }
        $warnings = & kubectl get events -A --field-selector type=Warning --no-headers 2>$null
        if ($warnings -and $warnings.Count -gt 0) {
            Add-Problem "KUBE: $($warnings.Count) Warning events present (see kubectl get events -A)."
        }

        Write-Sub "helm releases (all namespaces)"
        if (Test-CommandAvailable 'helm') {
            Invoke-Tool -Tool 'helm' -ToolArgs @('list','-A')
            $rels = & helm list -A -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($rels) {
                foreach ($r in $rels) {
                    if ($r.status -notin @('deployed','superseded')) {
                        Add-Problem ("HELM: release '{0}' (ns: {1}) status: {2}" -f $r.name, $r.namespace, $r.status)
                    }
                }
            }
        } else {
            Write-Output "(helm not in PATH -- chart-based workloads will not have been deployed)"
            Add-Problem "HELM: helm not installed (or not in PATH)."
        }

        Write-Sub "Namespaces that exist but have no Pods/Deployments"
        $nsBuiltin = @('default','kube-system','kube-public','kube-node-lease','kube-flannel')
        $nsAll = @(& kubectl get ns --no-headers 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
        $nsWithPods = @(& kubectl get pods -A --no-headers 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
        $nsWithDeploys = @(& kubectl get deploy -A --no-headers 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
        $emptyNs = @($nsAll | Where-Object { $_ -and ($nsBuiltin -notcontains $_) -and ($nsWithPods -notcontains $_) -and ($nsWithDeploys -notcontains $_) })
        if ($emptyNs.Count -gt 0) {
            foreach ($n in $emptyNs) {
                Write-Output ("  $n")
                Add-Problem "KUBE: namespace '$n' exists but has no Pods or Deployments -- a workload (helm/kubectl) for this namespace likely failed to land."
            }
        } else {
            Write-Output "(none)"
        }

        Write-Sub "kubectl port-forward processes (host scan)"
        if ($IsWindows) {
            $procs = Get-CimInstance Win32_Process -Filter "Name='kubectl.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'port-forward' }
            if ($procs) {
                $procs | ForEach-Object {
                    Write-Output ("  PID={0}  CMD={1}" -f $_.ProcessId, $_.CommandLine)
                }
            } else { Write-Output "(none)" }
        } elseif ($IsMacOS -or $IsLinux) {
            $found = & /bin/ps -axo pid=,args= 2>$null | Where-Object { $_ -match 'kubectl[^/]*port-forward' }
            if ($found) {
                $found | ForEach-Object { Write-Output ("  $_") }
            } else { Write-Output "(none)" }
        }
    }
    }

    # ===== 11. LINUX HOST DETAIL =======================================
    Invoke-DiagnosticSection "LINUX HOST DETAIL" {
        if (-not $IsLinux) {
            Write-Output "(skipped: not a Linux host)"
            return
        }

        Write-Sub "Netplan config (/etc/netplan/*.yaml)"
        $netplanFiles = @(Get-ChildItem -Path '/etc/netplan' -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
        if ($netplanFiles.Count -eq 0) {
            Write-Output "(no /etc/netplan/*.yaml -- distro likely uses NetworkManager or ifupdown)"
        } else {
            foreach ($f in $netplanFiles) {
                Write-Output "# $($f.FullName)"
                Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
                Write-Output ""
            }
        }

        Write-Sub "/etc/resolv.conf"
        if (Test-Path '/etc/resolv.conf') {
            $resolvItem = Get-Item -LiteralPath '/etc/resolv.conf' -Force -ErrorAction SilentlyContinue
            if ($resolvItem -and $resolvItem.LinkType) {
                Write-Output ("(symlink -> {0})" -f ($resolvItem.Target -join ', '))
            }
            Get-Content -LiteralPath '/etc/resolv.conf' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
        } else {
            Write-Output "(missing)"
            Add-Problem "LINUX: /etc/resolv.conf is missing -- name resolution will fail."
        }

        Write-Sub "/etc/hosts"
        if (Test-Path '/etc/hosts') {
            Get-Content -LiteralPath '/etc/hosts' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
        } else {
            Write-Output "(missing)"
        }

        Write-Sub "DNS resolver status"
        if (Test-CommandAvailable 'resolvectl') {
            Invoke-Tool -Tool 'resolvectl' -ToolArgs @('status')
        } elseif (Test-CommandAvailable 'systemd-resolve') {
            Invoke-Tool -Tool 'systemd-resolve' -ToolArgs @('--status')
        } else {
            Write-Output "(neither resolvectl nor systemd-resolve found -- systemd-resolved likely not in use)"
        }

        Write-Sub "ip route (full table)"
        Invoke-Tool -Tool 'ip' -ToolArgs @('route')

        Write-Sub "Listening sockets (ss -tulpn)"
        if (Test-CommandAvailable 'ss') {
            Invoke-Tool -Tool 'ss' -ToolArgs @('-tulpn')
        } else {
            Write-Output "(ss not available -- install iproute2)"
        }

        Write-Sub "Connectivity probe (ping -c 3 -W 2 1.1.1.1)"
        if (Test-CommandAvailable 'ping') {
            $pingOut = & ping -c 3 -W 2 1.1.1.1 2>&1
            $pingExit = $LASTEXITCODE
            $pingOut | ForEach-Object { Write-Output $_ }
            if ($pingExit -ne 0) {
                Add-Problem "LINUX: ping to 1.1.1.1 failed (exit $pingExit) -- check default route, NAT, or upstream connectivity."
            }
        } else {
            Write-Output "(ping not installed)"
        }

        Write-Sub "Firewall (iptables -S, first 200 lines)"
        if (Test-CommandAvailable 'iptables') {
            $ipt = & iptables -S 2>&1
            $iptExit = $LASTEXITCODE
            if ($iptExit -ne 0) {
                Write-Output ("(iptables -S returned exit {0}: {1})" -f $iptExit, (($ipt | Select-Object -First 1) -join ' '))
            } else {
                $ipt | Select-Object -First 200 | ForEach-Object { Write-Output $_ }
                if ($ipt.Count -gt 200) { Write-Output ("(... {0} more lines omitted)" -f ($ipt.Count - 200)) }
            }
        } else {
            Write-Output "(iptables not in PATH)"
        }
        if (Test-CommandAvailable 'ss') {
            Write-Sub "Listening sockets (ss -tuln, first 200 lines)"
            $ssOut = & ss -tuln 2>&1
            $ssExit = $LASTEXITCODE
            if ($ssExit -ne 0) {
                Write-Output ("(ss returned exit {0}: {1})" -f $ssExit, (($ssOut | Select-Object -First 1) -join ' '))
            } else {
                $ssOut | Select-Object -First 200 | ForEach-Object { Write-Output $_ }
                if ($ssOut.Count -gt 200) { Write-Output ("(... {0} more lines omitted)" -f ($ssOut.Count - 200)) }
            }
        }

        Write-Sub "dmesg -T (last 100 lines, with OOM scan)"
        if (Test-CommandAvailable 'dmesg') {
            $dmesgOut = & dmesg -T 2>&1
            $dmesgExit = $LASTEXITCODE
            if ($dmesgExit -ne 0) {
                Write-Output ("(dmesg returned exit {0}; kernel.dmesg_restrict may be 1 -- rerun as root for kernel ring buffer)" -f $dmesgExit)
            } else {
                $dmesgOut | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
                $oomHits = @($dmesgOut | Where-Object { $_ -match 'Out of memory|oom-kill|killed process' })
                if ($oomHits.Count -gt 0) {
                    Add-Problem ("LINUX: dmesg shows {0} OOM-killer event(s) -- memory pressure has killed a process. Review dmesg for details." -f $oomHits.Count)
                }
                $hwHits = @($dmesgOut | Where-Object { $_ -match 'I/O error|Hardware Error|MCE:|EDAC' })
                if ($hwHits.Count -gt 0) {
                    Add-Problem ("LINUX: dmesg shows {0} hardware/driver error line(s) (I/O error, MCE, EDAC, etc.)." -f $hwHits.Count)
                }
            }
        } else {
            Write-Output "(dmesg not in PATH)"
        }

        Write-Sub "Virtualization kernel modules (lsmod, filtered)"
        if (Test-CommandAvailable 'lsmod') {
            $lsmodOut = @(& lsmod 2>$null)
            $virt = $lsmodOut | Where-Object { $_ -match '^(kvm|virtio|hv_|hyperv|vmw|vbox|xen)' }
            if ($virt) {
                if ($lsmodOut.Count -gt 0) { Write-Output $lsmodOut[0] }
                $virt | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(no virtualization-related modules loaded -- bare metal or unrecognized hypervisor)"
            }
        } else {
            Write-Output "(lsmod not in PATH)"
        }

        Write-Sub "journalctl -xe (last 100 lines, no-pager)"
        if (Test-CommandAvailable 'journalctl') {
            $jxe = & journalctl -xe -n 100 --no-pager 2>&1
            if ($jxe) {
                $inScriptBlock = $false
                foreach ($line in $jxe) {
                    $lineStr = [string]$line
                    if ($lineStr -match 'Creating Scriptblock text \(\d+ of \d+\)') {
                        Write-Output ($lineStr -replace '(Creating Scriptblock text \(\d+ of \d+\)):.*$', '$1: [Get-SystemDiagnostic.ps1 script redacted]')
                        $inScriptBlock = $true
                        continue
                    }
                    if ($inScriptBlock -and $lineStr -match '^\s') { continue }
                    $inScriptBlock = $false
                    Write-Output $lineStr
                }
            }
        } else {
            Write-Output "(journalctl not available)"
        }

        Write-Sub "Container runtime journals (last 100 warning+ entries, since 6h ago)"
        if (Test-CommandAvailable 'journalctl') {
            foreach ($svc in @('docker','containerd','kubelet')) {
                Write-Output "## $svc"
                $jOut = & journalctl -u $svc --since '6 hours ago' -p warning -n 100 --no-pager 2>&1
                if (-not $jOut -or (($jOut -join "`n") -match 'No entries')) {
                    Write-Output "(no warning+ entries in the last 6 hours, or unit not present)"
                } else {
                    $jOut | ForEach-Object { Write-Output $_ }
                }
            }
        } else {
            Write-Output "(journalctl not available)"
        }

        Write-Sub "CNI plugins (/opt/cni/bin/)"
        if (Test-Path '/opt/cni/bin') {
            $cniBin = @(Get-ChildItem -Path '/opt/cni/bin' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($cniBin.Count -gt 0) {
                $cniBin | ForEach-Object { Write-Output ("  {0}" -f $_.Name) }
            } else {
                Write-Output "(/opt/cni/bin/ exists but is empty)"
                Add-Problem "LINUX: /opt/cni/bin/ is empty -- no CNI plugins installed; pods cannot get network."
            }
        } else {
            Write-Output "(no /opt/cni/bin -- Kubernetes node or CNI not installed here)"
        }

        Write-Sub "CNI config (/etc/cni/net.d/)"
        if (Test-Path '/etc/cni/net.d') {
            $cniNet = @(Get-ChildItem -Path '/etc/cni/net.d' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($cniNet.Count -gt 0) {
                foreach ($cf in $cniNet) {
                    Write-Output "# $($cf.FullName)"
                    Get-Content -LiteralPath $cf.FullName -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
                    Write-Output ""
                }
            } else {
                Write-Output "(/etc/cni/net.d/ exists but is empty)"
                Add-Problem "LINUX: /etc/cni/net.d/ is empty -- kubelet will fail to set up pod networks."
            }
        } else {
            Write-Output "(no /etc/cni/net.d -- Kubernetes not configured here)"
        }
    }

    # ===== 12. YURUNA PROJECT ==========================================
    Invoke-DiagnosticSection "YURUNA PROJECT" {
        $candidate   = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'project'
        $projectRoot = $null
        if (Test-Path -LiteralPath $candidate) {
            $projectRoot = (Resolve-Path -LiteralPath $candidate).Path
        }
        if (-not $projectRoot) {
            Write-Output "(no project directory at $candidate -- run this script from a yuruna checkout to populate this section)"
            return
        }
        Write-Output "Project root: $projectRoot"

        $outputFiles = @(Get-ChildItem -Path $projectRoot -Recurse -Filter 'resources.output.yml' -File -ErrorAction SilentlyContinue)
        if ($outputFiles.Count -eq 0) {
            Write-Sub "resources.output.yml"
            Write-Output "(none under $projectRoot -- 'yuruna resources' has not been run for any project, or its output file was cleared)"
        } else {
            foreach ($of in $outputFiles) {
                Write-Sub $of.FullName
                $content = $null
                try {
                    $content = Get-Content -LiteralPath $of.FullName -Raw -ErrorAction Stop
                } catch {
                    Write-Output "  (could not read: $($_.Exception.Message))"
                    continue
                }
                if ([string]::IsNullOrWhiteSpace($content)) {
                    Write-Output "  (file is empty)"
                    Add-Problem ("YURUNA: {0} is empty" -f $of.FullName)
                    continue
                }
                Write-Output $content

                $lines  = $content -split "`r?`n"
                $issues = [System.Collections.Generic.List[string]]::new()
                $pendingKey         = $null
                $pendingKeyLine     = -1
                $pendingHasContent  = $false
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    $raw = $lines[$i]
                    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
                    $trimmedStart = $raw.TrimStart()
                    if ($trimmedStart.StartsWith('#')) { continue }
                    if ($trimmedStart.StartsWith('---')) { continue }
                    if ($raw -match '^([A-Za-z_][A-Za-z0-9_.-]*):\s*(.*?)\s*$') {
                        if ($null -ne $pendingKey -and -not $pendingHasContent) {
                            $issues.Add(("top-level resource block '{0}' (line {1}) is present but empty -- a downstream chart that does `index .Values `"{0}.<output>`"` will render empty string and silently produce a malformed value (e.g. an InvalidImageName pod). Run 'yuruna resources <project> <env>' to (re)capture this resource's tofu output." -f $pendingKey, ($pendingKeyLine + 1)))
                        }
                        $pendingKey        = $Matches[1]
                        $pendingKeyLine    = $i
                        $sameLineVal       = $Matches[2]
                        $pendingHasContent = (-not [string]::IsNullOrWhiteSpace($sameLineVal)) -and ($sameLineVal -notmatch '^(null|~|\{\}|\[\])$')
                    } elseif ($raw -match '^\s+\S') {
                        $pendingHasContent = $true
                    }
                }
                if ($null -ne $pendingKey -and -not $pendingHasContent) {
                    $issues.Add(("top-level resource block '{0}' (line {1}) is present but empty" -f $pendingKey, ($pendingKeyLine + 1)))
                }
                for ($i = 0; $i -lt $lines.Count; $i++) {
                    if ($lines[$i] -match '^\s+value:\s*$') {
                        $parent = '?'
                        for ($j = $i - 1; $j -ge 0; $j--) {
                            if ($lines[$j] -match '^\s+([A-Za-z_][A-Za-z0-9_.-]*):\s*$') { $parent = $Matches[1]; break }
                        }
                        $issues.Add(("empty 'value:' for nested field '{0}' (line {1}) -- tofu captured the output name but its value was empty/null" -f $parent, ($i + 1)))
                    }
                }

                if ($issues.Count -gt 0) {
                    Write-Output ""
                    Write-Output "  Detected issues:"
                    foreach ($iss in $issues) {
                        Write-Output ("    * {0}" -f $iss)
                        Add-Problem ("YURUNA: {0} -- {1}" -f $of.FullName, $iss)
                    }
                }
            }
        }

        Write-Sub "Errors, failures and warnings"
        $yurunaDirs = @(Get-ChildItem -Path $projectRoot -Recurse -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq '.yuruna' })
        if ($yurunaDirs.Count -eq 0) {
            Write-Output "(no .yuruna/ working folders under $projectRoot -- no project has been deployed via the yuruna framework here yet)"
        } else {
            $skipPathFragments = @(
                [IO.Path]::DirectorySeparatorChar + '.terraform' + [IO.Path]::DirectorySeparatorChar + 'providers' + [IO.Path]::DirectorySeparatorChar
            )
            $skipExtensions = @('.exe','.dll','.so','.dylib','.zip','.tar','.gz','.tgz','.bz2','.xz','.7z','.rar','.iso','.img','.qcow2','.vhd','.vhdx','.png','.jpg','.jpeg','.gif','.ico','.pdf','.class','.pyc')

            $denyTerms = @(
                'failureThreshold',
                'ErrorAction',
                'WarningLevel'
            )
            $denyPattern = $null
            if ($denyTerms.Count -gt 0) {
                $escaped = $denyTerms | ForEach-Object { [regex]::Escape($_) }
                $denyPattern = '(?i)\b(?:' + ($escaped -join '|') + ')\w*\b'
            }
            $totalMatches = 0
            $filesScanned = 0
            $filesSkipped = 0
            $linesFiltered = 0
            foreach ($yd in $yurunaDirs) {
                $files = @(Get-ChildItem -Path $yd.FullName -Recurse -File -ErrorAction SilentlyContinue)
                foreach ($fi in $files) {
                    if ($fi.Length -gt 5MB)             { $filesSkipped++; continue }
                    if ($skipExtensions -contains $fi.Extension.ToLowerInvariant()) { $filesSkipped++; continue }
                    $skipByPath = $false
                    foreach ($frag in $skipPathFragments) {
                        if ($fi.FullName -like ('*' + $frag + '*')) { $skipByPath = $true; break }
                    }
                    if ($skipByPath) { $filesSkipped++; continue }
                    $filesScanned++
                    $hits = $null
                    try {
                        $hits = @(Select-String -LiteralPath $fi.FullName -Pattern '\b(error|fail|warning)' -CaseSensitive:$false -ErrorAction SilentlyContinue)
                    } catch {
                        continue
                    }
                    if (-not $hits -or $hits.Count -eq 0) { continue }
                    $keptHits = New-Object System.Collections.Generic.List[object]
                    foreach ($h in $hits) {
                        $line = $h.Line
                        if ($null -eq $line) { continue }
                        if ($denyPattern) {
                            $stripped = [regex]::Replace($line, $denyPattern, '')
                            if ($stripped -notmatch '(?i)\b(error|fail|warning)') {
                                $linesFiltered++
                                continue
                            }
                        }
                        $keptHits.Add($h)
                    }
                    if ($keptHits.Count -eq 0) { continue }
                    Write-Output ""
                    Write-Output $fi.FullName
                    foreach ($h in $keptHits) {
                        $line = $h.Line
                        if ($null -eq $line) { continue }
                        $line = $line.TrimEnd()
                        if ($line.Length -gt 64) { $line = $line.Substring(0, 64) }
                        Write-Output ("    {0}" -f $line)
                        $totalMatches++
                    }
                }
            }
            Write-Output ""
            Write-Output ("(scanned $filesScanned files, skipped $filesSkipped, $totalMatches lines matched, $linesFiltered filtered by denylist)")
            if ($totalMatches -gt 0) {
                Add-Problem ("YURUNA: {0} error/fail/warning lines across .yuruna/ working folders (see YURUNA PROJECT section above)" -f $totalMatches)
            }

            Write-Sub "Most recently modified files under .yuruna/ (top 100 by mtime)"
            $allFiles = New-Object System.Collections.Generic.List[object]
            foreach ($yd in $yurunaDirs) {
                Get-ChildItem -Path $yd.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $allFiles.Add($_) }
            }
            if ($allFiles.Count -eq 0) {
                Write-Output "(no files)"
            } else {
                $recent = $allFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 100
                foreach ($f in $recent) {
                    $rel = $f.FullName
                    if ($rel.StartsWith($projectRoot)) { $rel = $rel.Substring($projectRoot.Length).TrimStart('\','/') }
                    Write-Output ("  {0:yyyy-MM-dd HH:mm:ss}  {1,10}  {2}" -f $f.LastWriteTime, $f.Length, $rel)
                }
                $newest = $recent | Select-Object -First 1
                $ageMin = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
                Write-Output ""
                Write-Output ("Last .yuruna/ write : $($newest.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')) ({0} min ago)" -f $ageMin)
            }
        }
    }

    # ===== 13. SUMMARY =================================================
    Write-Section "PROBLEMS DETECTED"
    if ($script:Problems.Count -eq 0) {
        Write-Output "(none)"
    } else {
        Write-Output ("{0} problem(s) flagged:" -f $script:Problems.Count)
        $i = 0
        foreach ($p in $script:Problems) {
            $i++
            Write-Output ("  {0,3}. {1}" -f $i, $p)
        }
    }

    Write-Output ""
    Write-Output "Diagnostics complete."

} finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null }
        catch { Write-Verbose "Stop-Transcript on cleanup raised: $($_.Exception.Message)" }
    }
}
