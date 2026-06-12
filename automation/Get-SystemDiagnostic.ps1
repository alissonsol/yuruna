<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456720
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna diagnostics system health docker kubernetes
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
     11. HOST DETAIL -- starts with the Yuruna runner process tree
                    (descendants of $YURUNA_RUNTIME_DIR/inner.pid or
                    runner.pid) so a stuck cycle's blocking child
                    (ssh.exe, virsh, vmconnect, ...) is visible. Then
                    per-platform:
                      * Windows: Hyper-V VMs, listening sockets
                        (Get-NetTCPConnection), firewall profiles,
                        recent System log errors.
                      * macOS:   netstat -nr, ifconfig, scutil DNS,
                        lsof listening sockets, UTM/utmctl state,
                        unified log errors.
                      * Linux:   netplan, /etc/resolv.conf, /etc/hosts,
                        resolvectl/systemd-resolve status, ip route
                        (full), ss listening sockets, ping connectivity
                        probe, iptables -S, dmesg -T with OOM scan,
                        lsmod (virtualization modules), journalctl -xe,
                        per-unit journals for docker/containerd/kubelet,
                        /opt/cni/bin/ + /etc/cni/net.d/ state.
     11b. INSTALL TIMELINE (Linux only) -- /var/log/installer/* (subiquity
                    server-debug + curtin-install logs, autoinstall-user-data
                    that actually shipped), /var/log/cloud-init.log tail,
                    cloud-init status --long + analyze blame, /run/cloud-init
                    result+status JSON, systemd-analyze time/blame, the
                    boot list and the install boot's journal, networkctl
                    + ip -br link/addr, and a dmesg grep for eth0/netvsc/
                    accept_ra/carrier events. Diagnoses install-time
                    wedges (subiquity _send_update CHANGE eth0 loop,
                    apt mirror retry storms, IPv6 RA-driven netplan
                    re-apply) that runtime sections cannot see.
     11c. GUEST PROVISIONING (Linux only) -- every file under
                    /var/log/yuruna/ (one per pwsh_retry-wrapped action;
                    today: pwsh-yaml-install.log) carrying per-attempt
                    pre-flight probes and Verbose streams, plus a slice
                    of systemd-resolved's journal and a current snapshot
                    of PSRepository / PackageProvider / module state.
                    Diagnoses transient PSGallery / NuGet / DNS flakes
                    that one-shot Install-Module would render as the
                    same low-information "No match was found" string
                    regardless of which leg actually failed.
     12. YURUNA PROJECT -- ../project tree scan for resources.output.yml
                    files (path + content + empty-block analysis) and a
                    grep across every .yuruna/ working folder for any
                    line mentioning error/fail/warning, so a stuck cycle
                    can be triaged from one diagnostic dump.
     13. GAP HEURISTICS -- four cross-section checks for silent failure
                    modes where one phase wrote artifacts but a downstream
                    phase produced nothing in the cluster (tofu-state-
                    without-helm-releases, declared-namespace-missing,
                    cluster-Ready-but-no-user-pods, registry-image-not-
                    referenced).
     14. SUMMARY -- list of problems detected

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

.PARAMETER SkipProjectGaps
    Skip the YURUNA PROJECT and GAP HEURISTICS sections. These recursively
    walk the entire ../project tree (the slowest part of a run); a
    host/guest-only collection that does not need deploy-gap analysis can
    bypass them. Omit it to get the full collection.

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
    # When set, skips the YURUNA PROJECT and GAP HEURISTICS sections. Those
    # walk the entire project tree recursively (resources.output.yml, .yuruna/
    # working folders, tofu state) and are the slowest part of a run; a
    # host/guest-only collection that does not care about deploy-gap analysis
    # can bypass them. Default (unset) reproduces the full collection.
    [switch]$SkipProjectGaps,
    [ValidateSet('Error','Warning','Information','Verbose','Debug', IgnoreCase = $true)]
    [string]$logLevel = 'Information'
)
Write-Debug "Get-SystemDiagnostic: skipDocker=$SkipDocker skipKube=$SkipKube skipProjectGaps=$SkipProjectGaps logLevel=$logLevel"

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

# --- See https://yuruna.link/system-diagnostic#invoke-withdeadline
function Invoke-WithDeadline {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = 5,
        [object[]]$ArgumentList = @()
    )
    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if ($null -eq $completed) {
        try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch { $null = $_ }
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
        return @{ TimedOut = $true; Output = $null; ExitCode = -1 }
    }
    $out = $null
    try {
        $out = Receive-Job -Job $job -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    } finally {
        try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { $null = $_ }
    }
    # --- See https://yuruna.link/system-diagnostic#invoke-withdeadline (exit-code recovery)
    return @{ TimedOut = $false; Output = $out; ExitCode = $null }
}

# Recursive project-tree walks can wedge for minutes on a huge or
# network-mounted checkout. Run each behind Invoke-WithDeadline so a slow
# walk degrades to a partial/empty result plus a marker line instead of
# stalling the whole diagnostic. Job serialization preserves the FileInfo
# note properties the callers read (FullName, Length, Extension, Name,
# LastWriteTime), so downstream code is unchanged on the success path.
#
# The function has a singular collection contract, so the timeout marker is
# emitted by the caller (statement level) rather than from here -- a
# Write-Output of the marker would be captured into the caller's @(...)
# array instead of reaching stdout/transcript.
function Get-FileTreeWithDeadline {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$Label,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 30
    )
    $result = Invoke-WithDeadline -TimeoutSeconds $TimeoutSeconds -ArgumentList $ArgumentList -ScriptBlock $ScriptBlock
    if ($result.TimedOut) {
        Add-Problem ("DIAG: {0} recursive walk timed out after {1}s; results below may be incomplete." -f $Label, $TimeoutSeconds)
        return @{ TimedOut = $true; TimeoutSeconds = $TimeoutSeconds; Label = $Label; Items = @() }
    }
    return @{ TimedOut = $false; TimeoutSeconds = $TimeoutSeconds; Label = $Label; Items = @($result.Output) }
}

# Emit the degradation marker (if any) at statement level so it lands in
# stdout/transcript next to the section that triggered it. Pure side effect:
# call this WITHOUT assigning its result, then read the walk's .Items
# separately, so the marker is never captured into a caller's @(...) array.
function Show-FileTreeWalkTimeout {
    param([Parameter(Mandatory)][hashtable]$Walk)
    if ($Walk.TimedOut) {
        Write-Output ("  ({0} walk timed out after {1}s -- returning partial/empty results)" -f $Walk.Label, $Walk.TimeoutSeconds)
    }
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgs = @(),
        [string]$ProblemTag = $null,
        [int]$TimeoutSeconds = 0,
        [switch]$Privileged
    )
    if ($Privileged -and $script:LinuxPriv -and $script:LinuxPriv.Count -gt 0) {
        $ToolArgs = @($script:LinuxPriv | Select-Object -Skip 1) + @($Tool) + $ToolArgs
        $Tool = $script:LinuxPriv[0]
    }
    try {
        if ($TimeoutSeconds -gt 0) {
            $result = Invoke-WithDeadline -TimeoutSeconds $TimeoutSeconds -ArgumentList @($Tool, $ToolArgs) -ScriptBlock {
                param($t, $a)
                & $t @a 2>&1 | ForEach-Object { $_.ToString() }
                $LASTEXITCODE
            }
            if ($result.TimedOut) {
                Write-Output ("  ({0} probe timed out after {1}s -- daemon likely wedged)" -f $Tool, $TimeoutSeconds)
                if ($ProblemTag) { Add-Problem "$($ProblemTag): probe timeout after ${TimeoutSeconds}s from '$Tool $($ToolArgs -join ' ')'." }
                return
            }
            $lines = @($result.Output)
            $exit = 0
            if ($lines.Count -gt 0) {
                $last = $lines[$lines.Count - 1]
                if ($last -is [int]) {
                    $exit = [int]$last
                    $lines = $lines[0..($lines.Count - 2)]
                }
            }
            $lines | ForEach-Object { Write-Output ([string]$_) }
            if ($exit -ne 0 -and $ProblemTag) {
                Add-Problem "$($ProblemTag): exit code $exit from '$Tool $($ToolArgs -join ' ')'."
            }
            return
        }
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

# --- Linux privileged-probe support ------------------------------------
# journalctl / dmesg / networkctl only expose system- and kernel-scope
# output when run with privilege. Over an unprivileged SSH session they
# silently degrade to the caller's own user journal and a restricted
# (usually empty) kernel ring buffer -- so a remote diagnostic that does
# not elevate comes back blank for exactly the boot / network / kernel
# evidence it exists to capture. Resolve a non-interactive sudo prefix
# once (-n never prompts, so a password-required sudo fails fast instead
# of hanging the whole capture) and reuse it for every privileged probe.
function Get-LinuxPrivPrefix {
    if (-not $IsLinux) { return @() }
    $uid = $null
    try { $uid = (& id -u 2>$null) } catch { $null = $_ }
    if ("$uid" -eq '0') { return @() }
    if (-not (Test-CommandAvailable 'sudo')) { return @() }
    & sudo -n true 2>$null
    if (0 -eq $LASTEXITCODE) { return @('sudo', '-n') }
    return @()
}
$script:LinuxPriv = @(Get-LinuxPrivPrefix)

# Run a privileged Linux probe with the resolved prefix and return its
# output as a string[]. Stderr is dropped by default (matches probes that
# only want clean stdout); -KeepStderr merges it (for probes that inspect
# warnings or detect a restricted ring buffer). $LASTEXITCODE is left
# reflecting the underlying tool so callers can still branch on it.
function Invoke-PrivProbe {
    param(
        [Parameter(Mandatory)][string]$Tool,
        [string[]]$ToolArgs = @(),
        [switch]$KeepStderr
    )
    $argv = @($script:LinuxPriv) + @($Tool) + $ToolArgs
    $exe  = $argv[0]
    $rest = @($argv | Select-Object -Skip 1)
    if ($KeepStderr) {
        return @(& $exe @rest 2>&1 | ForEach-Object { $_.ToString() })
    }
    return @(& $exe @rest 2>$null | ForEach-Object { $_.ToString() })
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
    Write-Output ("Hostname     : {0}" -f [System.Net.Dns]::GetHostName())
    Write-Output ("Username     : {0}" -f [Environment]::UserName)
    Write-Output ("Time (UTC)   : {0}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Write-Output ("Time (local) : {0}" -f (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))

    # ---- Software ----------------------------------------------------
    # --- See https://yuruna.link/system-diagnostic#1-host-software-probe-resilience
    Write-Sub "Software"
    function Get-VersionLine {
        param(
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][scriptblock]$Probe
        )
        $value = $null
        try {
            $value = & $Probe
        } catch {
            $value = $null
        }
        if ($value -is [array]) { $value = $value | Where-Object { $_ } | Select-Object -First 1 }
        $text = if ($null -ne $value) { ([string]$value).Trim() } else { '' }
        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Output ("  {0,-20} : (not installed)" -f $Name)
        } else {
            Write-Output ("  {0,-20} : {1}" -f $Name, $text)
        }
    }
    # PowerShell -- always available since this script requires v7.
    Get-VersionLine 'PowerShell' {
        '{0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition
    }
    Get-VersionLine 'git' {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            ((& git --version 2>$null) -replace '^git version ','')
        }
    }
    Get-VersionLine 'python3' {
        if (Get-Command python3 -ErrorAction SilentlyContinue) {
            ((& python3 --version 2>$null) -replace '^Python ','')
        }
    }
    Get-VersionLine 'node' {
        if (Get-Command node -ErrorAction SilentlyContinue) { & node --version 2>$null }
    }
    Get-VersionLine 'npm' {
        if (Get-Command npm -ErrorAction SilentlyContinue) { & npm --version 2>$null }
    }
    # --- See https://yuruna.link/system-diagnostic#per-tool-request-timeouts (docker --version)
    Get-VersionLine 'Docker' {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            ((& docker --version 2>$null) -replace '^Docker version ','' -replace ',\s*build.*$','')
        }
    }
    Get-VersionLine 'Docker buildx' {
        if (Get-Command docker -ErrorAction SilentlyContinue) {
            $bx = & docker buildx version 2>$null | Select-Object -First 1
            if ($bx) { ($bx -split '\s+')[1] }
        }
    }
    Get-VersionLine 'containerd' {
        if (Get-Command containerd -ErrorAction SilentlyContinue) {
            $cd = & containerd --version 2>$null | Select-Object -First 1
            if ($cd) {
                $parts = $cd -split '\s+' | Where-Object { $_ -match '^v?\d+\.' } | Select-Object -First 1
                if ($parts) { $parts } else { $cd }
            }
        }
    }
    Get-VersionLine 'Kubernetes' {
        if (Get-Command kubectl -ErrorAction SilentlyContinue) {
            # --- See https://yuruna.link/system-diagnostic#per-tool-request-timeouts (kubectl --client)
            $j = & kubectl version --client -o json --request-timeout=5s 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).clientVersion.gitVersion
            }
        }
    }
    Get-VersionLine 'Helm' {
        if (Get-Command helm -ErrorAction SilentlyContinue) {
            & helm version --short 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'OpenTofu' {
        if (Get-Command tofu -ErrorAction SilentlyContinue) {
            $j = & tofu version -json 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).terraform_version
            }
        }
    }
    Get-VersionLine 'mkcert' {
        if (Get-Command mkcert -ErrorAction SilentlyContinue) {
            & mkcert -version 2>&1 | Select-Object -First 1
        }
    }
    Get-VersionLine 'curl' {
        if (Get-Command curl -ErrorAction SilentlyContinue) {
            # First line is `curl X.Y.Z (build/triplet) libcurl/X.Y.Z ...`;
            # everything after the opening paren is libcurl feature noise.
            (& curl --version 2>$null | Select-Object -First 1) -replace '\s*\(.*$',''
        }
    }
    Get-VersionLine 'wget' {
        if (Get-Command wget -ErrorAction SilentlyContinue) {
            & wget --version 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'tesseract' {
        if (Get-Command tesseract -ErrorAction SilentlyContinue) {
            & tesseract --version 2>&1 | Select-Object -First 1
        }
    }
    Get-VersionLine 'qemu-img' {
        if (Get-Command qemu-img -ErrorAction SilentlyContinue) {
            # First line is `qemu-img version X.Y.Z, Copyright (c) ... Fabrice Bellard`;
            # the Copyright tail is constant noise.
            (& qemu-img --version 2>$null | Select-Object -First 1) -replace ',\s*Copyright.*$',''
        }
    }
    Get-VersionLine 'AWS cli' {
        if (Get-Command aws -ErrorAction SilentlyContinue) {
            # `aws-cli/X.Y.Z Python/X.Y.Z OS/build prompt/...`; everything
            # after the first whitespace is environment context, not version.
            (& aws --version 2>&1 | Select-Object -First 1) -replace '\s.*$',''
        }
    }
    Get-VersionLine 'Azure cli' {
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $j = & az version 2>$null
            if ($LASTEXITCODE -eq 0 -and $j) {
                (($j -join "`n") | ConvertFrom-Json).'azure-cli'
            }
        }
    }
    Get-VersionLine 'Google Cloud' {
        if (Get-Command gcloud -ErrorAction SilentlyContinue) {
            # --- See https://yuruna.link/system-diagnostic#per-tool-request-timeouts (gcloud -v)
            & gcloud -v 2>$null | Select-Object -First 1
        }
    }
    Get-VersionLine 'Visual Studio Code' {
        if (Get-Command code -ErrorAction SilentlyContinue) {
            & code -v 2>$null | Select-Object -First 1
        }
    }

    # ---- OS details --------------------------------------------------
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

    Write-Sub "Connectivity"

    # --- See https://yuruna.link/system-diagnostic#probe-via-proxy-when-egress-is-locked
    $proxyUrl  = $null
    $proxyHost = $null
    $proxyPort = 0
    foreach ($v in 'https_proxy','HTTPS_PROXY','http_proxy','HTTP_PROXY') {
        $val = [System.Environment]::GetEnvironmentVariable($v)
        if ($val) {
            try {
                $u = [Uri]$val
                if ($u.Host) {
                    $proxyUrl  = $val
                    $proxyHost = $u.Host
                    $proxyPort = if ($u.Port -gt 0) { $u.Port } else { 3128 }
                    break
                }
            } catch { $null = $_ }
        }
    }

    # Gate probe: prove we can reach the proxy (if set) or the public
    # internet (if not) before launching the full endpoint matrix.
    $gateHost = if ($proxyUrl) { $proxyHost } else { '8.8.8.8' }
    $gatePort = if ($proxyUrl) { $proxyPort } else { 443 }
    $gateOk = $false
    $gateRejected = $false
    $gateMsg = $null
    try {
        $gateClient = [System.Net.Sockets.TcpClient]::new()
        try {
            $gateAsync = $gateClient.BeginConnect($gateHost, $gatePort, $null, $null)
            if ($gateAsync.AsyncWaitHandle.WaitOne(1500)) {
                try {
                    $gateClient.EndConnect($gateAsync)
                    $gateOk = $true
                } catch [System.Net.Sockets.SocketException] {
                    if ($_.Exception.SocketErrorCode -eq [System.Net.Sockets.SocketError]::ConnectionRefused) {
                        $gateRejected = $true
                    }
                    $gateMsg = $_.Exception.Message
                }
            } else {
                $gateMsg = "no response in 1500 ms"
            }
        } finally { $gateClient.Dispose() }
    } catch { $gateMsg = $_.Exception.Message }

    if (-not $gateOk) {
        if ($proxyUrl) {
            Write-Output "(egress proxy ${proxyHost}:${proxyPort} unreachable: $gateMsg -- skipping endpoint probes)"
            Add-Problem "NETWORK: egress proxy ${proxyHost}:${proxyPort} unreachable ($gateMsg)."
        } elseif ($gateRejected) {
            Write-Output "(direct TCP/443 to 8.8.8.8 refused by local egress filter; no http(s)_proxy in env -- skipping endpoint probes)"
            Add-Problem "NETWORK: direct TCP/443 refused by local egress filter and no http(s)_proxy is set."
        } else {
            Write-Output "(no outbound connectivity to 8.8.8.8:443 within 1500 ms -- skipping endpoint probes)"
            Add-Problem "NETWORK: no outbound connectivity (gate probe to 8.8.8.8:443 failed: $gateMsg)."
        }
    } else {
        $connectivityEndpoints = @(
            # Yuruna sites
            '8.8.8.8',
            'ports.ubuntu.com',
            'archive.ubuntu.com',
            'registry.k8s.io',
            'ghcr.io',
            'pkg.dev',
            'github.com',
            'security.ubuntu.com',
            'registry.opentofu.org',
            'download.docker.com',
            'pkgs.k8s.io',
            'packages.opentofu.org',
            'mcr.microsoft.com',

            # AWS EC2 regional service endpoints
            'ec2.us-east-1.amazonaws.com',
            'ec2.us-west-2.amazonaws.com',
            'ec2.eu-west-1.amazonaws.com',

            # Azure core infrastructure endpoints
            'eastus.blob.core.windows.net',
            'lgmsapewus2.blob.core.windows.net',
            'lgmsapeweu.blob.core.windows.net',

            # Google Cloud Storage locational endpoints
            'us-central1-storage.googleapis.com',
            'us-east1-storage.googleapis.com',
            'europe-west1-storage.googleapis.com'
        )

        if ($proxyUrl) {
            # --- See https://yuruna.link/system-diagnostic#probe-via-proxy-when-egress-is-locked
            Write-Output ("Egress goes through ${proxyHost}:${proxyPort} ({0}); reporting round-trip via HTTP CONNECT." -f $proxyUrl)
            $probeTimeoutMs = 4000
            $probeDeadline  = [System.Environment]::TickCount + $probeTimeoutMs

            # Phase 1: kick TCP connects to the proxy for every target.
            $probes = foreach ($t in $connectivityEndpoints) {
                $entry = [pscustomobject]@{
                    Target       = $t
                    RTT          = $null
                    Status       = $null
                    Client       = $null
                    ConnectAsync = $null
                    Stream       = $null
                    ReadBuf      = $null
                    ReadAsync    = $null
                    StartTick    = [System.Environment]::TickCount
                    Stage        = 'Connecting'
                }
                try {
                    $entry.Client = [System.Net.Sockets.TcpClient]::new()
                    $entry.ConnectAsync = $entry.Client.BeginConnect($proxyHost, $proxyPort, $null, $null)
                } catch {
                    $entry.Stage  = 'Failed'
                    $entry.Status = "proxy connect start failed: $($_.Exception.Message)"
                    if ($entry.Client) { try { $entry.Client.Dispose() } catch { $null = $_ } }
                    $entry.Client = $null
                }
                $entry
            }

            # Phase 2: as each proxy-TCP completes, send CONNECT and kick the read.
            foreach ($p in ($probes | Where-Object { $_.Stage -eq 'Connecting' })) {
                $remain = $probeDeadline - [System.Environment]::TickCount
                if ($remain -lt 0) { $remain = 0 }
                try {
                    if ($p.ConnectAsync.AsyncWaitHandle.WaitOne($remain)) {
                        $p.Client.EndConnect($p.ConnectAsync)
                        $p.Stream = $p.Client.GetStream()
                        $req = "CONNECT $($p.Target):443 HTTP/1.1`r`nHost: $($p.Target):443`r`nProxy-Connection: close`r`n`r`n"
                        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
                        $p.Stream.Write($bytes, 0, $bytes.Length)
                        $p.ReadBuf   = New-Object byte[] 1024
                        $p.ReadAsync = $p.Stream.BeginRead($p.ReadBuf, 0, $p.ReadBuf.Length, $null, $null)
                        $p.Stage     = 'Reading'
                    } else {
                        $p.Stage  = 'Failed'
                        $p.Status = "proxy TCP timeout (>${probeTimeoutMs} ms)"
                        try { $p.Client.Dispose() } catch { $null = $_ }
                    }
                } catch {
                    $p.Stage  = 'Failed'
                    $p.Status = "proxy TCP failed"
                    try { $p.Client.Dispose() } catch { $null = $_ }
                }
            }

            # Phase 3: collect proxy CONNECT responses.
            foreach ($p in ($probes | Where-Object { $_.Stage -eq 'Reading' })) {
                $remain = $probeDeadline - [System.Environment]::TickCount
                if ($remain -lt 0) { $remain = 0 }
                try {
                    if ($p.ReadAsync.AsyncWaitHandle.WaitOne($remain)) {
                        $n = $p.Stream.EndRead($p.ReadAsync)
                        if ($n -gt 0) {
                            $resp = [System.Text.Encoding]::ASCII.GetString($p.ReadBuf, 0, $n)
                            $firstLine = ($resp -split "`r`n", 2)[0]
                            $parts = $firstLine -split '\s+', 3
                            if ($parts.Count -ge 2 -and $parts[0] -match '^HTTP/\d\.\d$' -and $parts[1] -match '^\d{3}$') {
                                $code = $parts[1]
                                $reason = if ($parts.Count -ge 3) { $parts[2] } else { '' }
                                if ($code -eq '200') {
                                    $p.RTT    = [System.Environment]::TickCount - $p.StartTick
                                    $p.Status = "$($p.RTT) ms"
                                } else {
                                    $p.Status = ("proxy $code $reason").Trim()
                                }
                            } else {
                                $p.Status = "proxy bad reply"
                            }
                        } else {
                            $p.Status = "proxy closed (no bytes)"
                        }
                    } else {
                        $p.Status = "proxy reply timeout (>${probeTimeoutMs} ms)"
                    }
                } catch {
                    $p.Status = "proxy read failed"
                } finally {
                    try { $p.Stream.Dispose() } catch { $null = $_ }
                    try { $p.Client.Dispose() } catch { $null = $_ }
                }
            }

            $connectResults = $probes | ForEach-Object {
                [pscustomobject]@{ Target = $_.Target; RTT = $_.RTT; Status = $_.Status }
            }
        } else {
            # No env proxy: hit each target directly on TCP/443 in parallel.
            Write-Output "Probing each target via direct TCP/443 (no http(s)_proxy in env)."
            $connectTimeoutMs = 2500
            $connectDeadline = [System.Environment]::TickCount + $connectTimeoutMs

            $connectProbes = foreach ($t in $connectivityEndpoints) {
                $client = $null
                $async  = $null
                $startErr = $null
                try {
                    $client = [System.Net.Sockets.TcpClient]::new()
                    $async  = $client.BeginConnect($t, 443, $null, $null)
                } catch {
                    $startErr = $_.Exception.Message
                    if ($client) { try { $client.Dispose() } catch { $null = $_ } }
                    $client = $null
                    $async  = $null
                }
                [pscustomobject]@{
                    Target     = $t
                    Client     = $client
                    Async      = $async
                    StartTick  = [System.Environment]::TickCount
                    StartError = $startErr
                }
            }

            $connectResults = foreach ($p in $connectProbes) {
                $status = $null
                $rttMs  = $null
                if ($p.StartError) {
                    $status = "start failed: $($p.StartError)"
                } elseif (-not $p.Async) {
                    $status = "couldn't connect"
                } else {
                    $remain = $connectDeadline - [System.Environment]::TickCount
                    if ($remain -lt 0) { $remain = 0 }
                    try {
                        if ($p.Async.AsyncWaitHandle.WaitOne($remain)) {
                            $p.Client.EndConnect($p.Async)
                            $rttMs  = [System.Environment]::TickCount - $p.StartTick
                            $status = "${rttMs} ms"
                        } else {
                            $status = "timeout (>${connectTimeoutMs} ms)"
                        }
                    } catch {
                        $status = "couldn't connect"
                    } finally {
                        try { $p.Client.Dispose() } catch { $null = $_ }
                    }
                }
                [pscustomobject]@{
                    Target = $p.Target
                    RTT    = $rttMs
                    Status = $status
                }
            }
        }

        $connectResults |
            Sort-Object @{ Expression = { if ($null -eq $_.RTT) { [int]::MaxValue } else { $_.RTT } } }, Target |
            Select-Object Target, Status |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_ }

        $connectFailures = @($connectResults | Where-Object { $null -eq $_.RTT })
        if ($connectFailures.Count -gt 0) {
            Add-Problem ("NETWORK: {0}/{1} endpoint(s) unreachable: {2}" -f `
                $connectFailures.Count, $connectResults.Count, (($connectFailures.Target) -join ', '))
        }
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
            $jc = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-p','err','-n','20','--since','1 hour ago','--no-pager')
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

    Write-Sub "Full *.stderr.log files under yuruna repo root (verbatim, for tofu/helm/kubectl/docker post-mortems)"
    # Per-phase stderr.log + *.rc catalog and the -Force-required dot-dir
    # scan trap: https://yuruna.link/architecture
    $yurunaRootCandidate = Join-Path -Path $PSScriptRoot -ChildPath '..'
    $diagScanRoot = $null
    if (Test-Path -LiteralPath $yurunaRootCandidate) {
        $diagScanRoot = (Resolve-Path -LiteralPath $yurunaRootCandidate).Path
    }
    if (-not $diagScanRoot) {
        Write-Output "(no yuruna repo root at $yurunaRootCandidate -- skipping)"
    } else {
        $phaseLogs = @(Get-ChildItem -Path $diagScanRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.stderr.log' })
        if ($phaseLogs.Count -eq 0) {
            Write-Output "(no *.stderr.log under $diagScanRoot -- no phase has produced output here)"
        } else {
            foreach ($tl in ($phaseLogs | Sort-Object FullName)) {
                $sizeNote = ''
                $content  = ''
                try {
                    if ($tl.Length -gt 64KB) {
                        $sizeNote = " (last 64 KB shown of $($tl.Length) bytes)"
                        $stream = [System.IO.File]::Open($tl.FullName, 'Open', 'Read', 'ReadWrite')
                        try {
                            $null = $stream.Seek([Math]::Max(0L, [int64]$tl.Length - 65536L), 'Begin')
                            $reader = New-Object System.IO.StreamReader($stream)
                            $content = $reader.ReadToEnd()
                            $reader.Close()
                        } finally { $stream.Dispose() }
                    } else {
                        $content = Get-Content -LiteralPath $tl.FullName -Raw -ErrorAction Stop
                    }
                } catch {
                    Write-Output ("{0}: (read failed: {1})" -f $tl.FullName, $_.Exception.Message)
                    continue
                }
                # Sidecar exit-code file (helm.stderr.log -> helm.rc, etc.)
                $rcSidecar = [System.IO.Path]::ChangeExtension($tl.FullName, $null).TrimEnd('.') -replace '\.stderr$', '.rc'
                $rcNote = ''
                if (Test-Path -LiteralPath $rcSidecar) {
                    $rcText = (Get-Content -LiteralPath $rcSidecar -Raw -ErrorAction SilentlyContinue)
                    if ($null -ne $rcText) {
                        $rcNote = " (last rc={0})" -f $rcText.Trim()
                    }
                }
                $mtime = $tl.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
                Write-Output ''
                Write-Output ("--- {0}  ({1} bytes, mtime {2}){3}{4} ---" -f $tl.FullName, $tl.Length, $mtime, $sizeNote, $rcNote)
                if ([string]::IsNullOrWhiteSpace($content)) {
                    Write-Output '(empty)'
                } else {
                    Write-Output $content.TrimEnd()
                }
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
        # --- See https://yuruna.link/system-diagnostic#wedged-daemon-protection
        $probe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
            $null = & docker info --format '{{.ServerVersion}}' 2>&1
            $LASTEXITCODE
        }
        if ($probe.TimedOut) {
            Write-Output "(docker info probe timed out after 5s -- daemon likely wedged)"
            Add-Problem "DOCKER: probe timeout (docker info did not return within 5s; daemon likely wedged)."
        } elseif ((@($probe.Output) | Select-Object -Last 1) -ne 0) {
            Write-Output "Docker CLI present but daemon unreachable."
            Add-Problem "DOCKER: daemon unreachable (`docker info` failed)."
        } else {
            Write-Sub "docker version (client+server)"
            Invoke-Tool -Tool 'docker' -ToolArgs @('version','--format','Client: {{.Client.Version}} ({{.Client.Os}}/{{.Client.Arch}})`nServer: {{.Server.Version}} ({{.Server.Os}}/{{.Server.Arch}})') -TimeoutSeconds 5
            Write-Sub "docker info (selected fields)"
            $infoProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                & docker info --format '{{json .}}' 2>$null
            }
            $info = $null
            if ($infoProbe.TimedOut) {
                Write-Output "(docker info probe timed out after 5s -- daemon likely wedged)"
                Add-Problem "DOCKER: probe timeout (docker info --format json did not return within 5s)."
            } else {
                $info = ($infoProbe.Output -join "`n") | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
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
            Invoke-Tool -Tool 'docker' -ToolArgs @('ps','-a','--format','table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}') -TimeoutSeconds 5
            $psProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                & docker ps -a --format '{{.Names}}|{{.Status}}' 2>$null
            }
            $rows = @()
            if ($psProbe.TimedOut) {
                Write-Output "(docker ps probe timed out after 5s -- daemon likely wedged)"
                Add-Problem "DOCKER: probe timeout (docker ps -a did not return within 5s)."
            } else {
                $rows = @($psProbe.Output)
            }
            foreach ($r in $rows) {
                $parts = $r -split '\|', 2
                if ($parts.Count -ne 2) { continue }
                $name = $parts[0]; $status = $parts[1]
                if ($status -match '^Restarting' -or $status -match 'unhealthy' -or $status -match 'Dead') {
                    Add-Problem "DOCKER: container '$name' status: $status"
                }
            }
            Write-Sub "docker images (top 100 by size)"
            $imgsProbe = Invoke-WithDeadline -TimeoutSeconds 5 -ScriptBlock {
                & docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.Size}}|{{.CreatedSince}}' 2>&1
                $LASTEXITCODE
            }
            $imgsRaw = @()
            $imgsExit = 0
            if ($imgsProbe.TimedOut) {
                Write-Output "(docker images probe timed out after 5s -- daemon likely wedged)"
                Add-Problem "DOCKER: probe timeout (docker images did not return within 5s)."
                $imgsExit = -1
            } else {
                $imgsOutput = @($imgsProbe.Output)
                if ($imgsOutput.Count -gt 0) {
                    $last = $imgsOutput[$imgsOutput.Count - 1]
                    if ($last -is [int]) {
                        $imgsExit = [int]$last
                        $imgsRaw = $imgsOutput[0..($imgsOutput.Count - 2)]
                    } else {
                        $imgsRaw = $imgsOutput
                    }
                }
            }
            if ($imgsExit -ne 0) {
                if (-not $imgsProbe.TimedOut) {
                    Write-Output ("(docker images returned exit {0})" -f $imgsExit)
                }
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
            Invoke-Tool -Tool 'docker' -ToolArgs @('stats','--no-stream','--format','table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}') -TimeoutSeconds 5
            Write-Sub "docker system df"
            Invoke-Tool -Tool 'docker' -ToolArgs @('system','df') -TimeoutSeconds 5

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
        # --- See https://yuruna.link/system-diagnostic#per-tool-request-timeouts (kubectl --request-timeout)
        $kv = & kubectl version --output=json --request-timeout=5s 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($kv) {
            if ($kv.clientVersion) { Write-Output ("Client : {0}" -f $kv.clientVersion.gitVersion) }
            if ($kv.serverVersion) { Write-Output ("Server : {0}" -f $kv.serverVersion.gitVersion) }
            else { Write-Output "Server : (unreachable)" ; Add-Problem "KUBE: server version unavailable -- cluster may be unreachable." }
        }
        Write-Sub "Current context"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('config','current-context')

        Write-Sub "kubectl get nodes -o wide"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','nodes','-o','wide','--request-timeout=5s') -TimeoutSeconds 5
        $nodes = & kubectl get nodes --no-headers --request-timeout=5s 2>$null
        foreach ($n in $nodes) {
            $cols = $n -split '\s+'
            if ($cols.Count -ge 2 -and $cols[1] -notmatch '^Ready') {
                Add-Problem "KUBE: node '$($cols[0])' status: $($cols[1])"
            }
        }

        Write-Sub "Namespaces"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ns','--request-timeout=5s') -TimeoutSeconds 5

        Write-Sub "Pods (all namespaces, -o wide)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pods','-A','-o','wide','--request-timeout=5s') -TimeoutSeconds 5
        $pods = & kubectl get pods -A --no-headers --request-timeout=5s 2>$null
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
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','svc','-A','--request-timeout=5s')

        Write-Sub "Deployments (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','deploy','-A','--request-timeout=5s')

        Write-Sub "DaemonSets (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ds','-A','--request-timeout=5s')

        Write-Sub "StatefulSets (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','sts','-A','--request-timeout=5s')

        Write-Sub "Jobs / CronJobs (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','jobs,cronjobs','-A','--request-timeout=5s')

        Write-Sub "Ingresses (all namespaces)"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','ingress','-A','--request-timeout=5s')

        Write-Sub "PersistentVolumes / PVCs"
        Invoke-Tool -Tool 'kubectl' -ToolArgs @('get','pv,pvc','-A','--request-timeout=5s')

        Write-Sub "ConfigMaps + Secrets (counts only)"
        $cmCount = (& kubectl get cm  -A --no-headers --request-timeout=5s 2>$null | Measure-Object).Count
        $scCount = (& kubectl get secret -A --no-headers --request-timeout=5s 2>$null | Measure-Object).Count
        Write-Output ("ConfigMaps : {0}" -f $cmCount)
        Write-Output ("Secrets    : {0}" -f $scCount)

        Write-Sub "Recent Warning events (last 100 across all namespaces)"
        $evts = @(& kubectl get events -A --field-selector type=Warning --sort-by .lastTimestamp --request-timeout=5s 2>&1)
        if ($evts.Count -gt 1) {
            Write-Output $evts[0]
            $rows = $evts | Select-Object -Skip 1
            $rows | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            if ($rows.Count -gt 100) { Write-Output ("(... {0} older warning(s) omitted)" -f ($rows.Count - 100)) }
        } else {
            $evts | ForEach-Object { Write-Output $_ }
        }
        $warnings = & kubectl get events -A --field-selector type=Warning --no-headers --request-timeout=5s 2>$null
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
        $nsAll = @(& kubectl get ns --no-headers --request-timeout=5s 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
        $nsWithPods = @(& kubectl get pods -A --no-headers --request-timeout=5s 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
        $nsWithDeploys = @(& kubectl get deploy -A --no-headers --request-timeout=5s 2>$null | ForEach-Object { ($_ -split '\s+')[0] } | Sort-Object -Unique)
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

    # ===== 11. HOST DETAIL =============================================
    # --- See https://yuruna.link/system-diagnostic#11-host-detail-runner-process-tree
    Invoke-DiagnosticSection "HOST DETAIL" {

        # ---- Runner process tree (all platforms) ----------------------
        Write-Sub "Yuruna runner process tree (descendants of inner.pid / runner.pid)"
        $runtimeDir = $env:YURUNA_RUNTIME_DIR
        if (-not $runtimeDir) {
            # Common default when Get-SystemDiagnostic is invoked outside
            # a runner cycle. The status server publishes its own copy
            # of the env var to its child pwsh; absent here, derive from
            # script location.
            $runtimeDir = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'test' -AdditionalChildPath 'status', 'track'
        }
        $rootPid = 0
        $rootSource = ''
        foreach ($candidate in @('inner.pid','runner.pid')) {
            $candidateFile = Join-Path $runtimeDir $candidate
            if (Test-Path -LiteralPath $candidateFile) {
                try { $rootPid = [int]((Get-Content -LiteralPath $candidateFile -Raw -ErrorAction Stop).Trim()) } catch { $rootPid = 0 }
                if ($rootPid -gt 0) { $rootSource = $candidate; break }
            }
        }
        if ($rootPid -le 0) {
            Write-Output "(no inner.pid or runner.pid under $runtimeDir -- runner not active or runtime dir undiscoverable)"
        } elseif (-not (Get-Process -Id $rootPid -ErrorAction SilentlyContinue)) {
            Write-Output "(pid $rootPid (from $rootSource) is not currently running -- runner has exited)"
        } else {
            Write-Output "Root pid: $rootPid (from $rootSource)"
            # Build (pid -> {ppid, etime, pcpu, cmd}) map per platform.
            $procMap = @{}
            if ($IsWindows) {
                try {
                    # Win32_Process has Handle (=pid), ParentProcessId, CommandLine,
                    # CreationDate. No wall-elapsed column -- compute it from
                    # CreationDate. No %CPU -- approximate via UserModeTime+KernelModeTime.
                    $allProcs = Get-CimInstance Win32_Process -ErrorAction Stop
                    foreach ($p in $allProcs) {
                        $etimeSec = $null
                        if ($p.CreationDate) {
                            try { $etimeSec = [int]((Get-Date) - $p.CreationDate).TotalSeconds } catch { $etimeSec = $null }
                        }
                        $procMap[[int]$p.ProcessId] = @{
                            ppid  = [int]$p.ParentProcessId
                            etime = $etimeSec
                            cpu   = $null    # CIM doesn't expose pcpu; row formatter just shows '-'
                            cmd   = [string]$p.CommandLine
                        }
                    }
                } catch {
                    Write-Output "(Get-CimInstance Win32_Process failed: $($_.Exception.Message))"
                }
            } elseif ($IsLinux -or $IsMacOS) {
                # --- See https://yuruna.link/system-diagnostic#ps-ww-is-mandatory-on-macos-linux
                try {
                    $psLines = & '/bin/ps' -ww -axo 'pid=,ppid=,etime=,pcpu=,args=' 2>$null
                    foreach ($line in $psLines) {
                        $trim = ([string]$line).Trim()
                        if (-not $trim) { continue }
                        # Split on first 4 whitespace runs; rest is args.
                        $parts = $trim -split '\s+', 5
                        if ($parts.Count -lt 5) { continue }
                        $procMap[[int]$parts[0]] = @{
                            ppid  = [int]$parts[1]
                            etime = $parts[2]
                            cpu   = $parts[3]
                            cmd   = $parts[4]
                        }
                    }
                } catch {
                    Write-Output "(ps -axo failed: $($_.Exception.Message))"
                }
            }
            if ($procMap.Count -gt 0 -and $procMap.ContainsKey($rootPid)) {
                # Iterative breadth-first walk with depth tracking. Children
                # by ppid index built once for O(N) walk.
                $childIdx = @{}
                foreach ($entry in $procMap.GetEnumerator()) {
                    $pp = $entry.Value.ppid
                    if (-not $childIdx.ContainsKey($pp)) { $childIdx[$pp] = New-Object System.Collections.Generic.List[int] }
                    $childIdx[$pp].Add([int]$entry.Key)
                }
                $stack   = [System.Collections.Generic.Stack[object]]::new()
                $stack.Push(@{ pid = $rootPid; depth = 0 })
                $visited = [System.Collections.Generic.HashSet[int]]::new()
                Write-Output ("{0,-6} {1,-6} {2,-12} {3,-6}  CMD" -f 'PID','PPID','ETIME','CPU')
                while ($stack.Count -gt 0) {
                    $cur = $stack.Pop()
                    $cpid = [int]$cur.pid
                    if (-not $visited.Add($cpid)) { continue }
                    if (-not $procMap.ContainsKey($cpid)) { continue }
                    $info  = $procMap[$cpid]
                    $indent = ('  ' * [int]$cur.depth)
                    $etimeStr = if ($null -ne $info.etime) { ('{0}' -f $info.etime) } else { '-' }
                    $cpuStr   = if ($null -ne $info.cpu)   { ('{0}' -f $info.cpu)   } else { '-' }
                    $cmdLine  = ([string]$info.cmd)
                    if ($cmdLine.Length -gt 240) { $cmdLine = $cmdLine.Substring(0, 240) + ' ...' }
                    Write-Output ("{0,-6} {1,-6} {2,-12} {3,-6}  {4}{5}" -f $cpid, $info.ppid, $etimeStr, $cpuStr, $indent, $cmdLine)
                    if ($childIdx.ContainsKey($cpid)) {
                        # Push in reverse so the first child is popped first.
                        $kids = $childIdx[$cpid]
                        for ($i = $kids.Count - 1; $i -ge 0; $i--) {
                            $stack.Push(@{ pid = $kids[$i]; depth = [int]$cur.depth + 1 })
                        }
                    }
                }
            } else {
                Write-Output "(no process info collected -- runner pid $rootPid likely exited between probe and walk)"
            }
        }

        if (-not ($IsLinux -or $IsMacOS -or $IsWindows)) {
            Write-Output ""
            Write-Output "(skipped per-platform detail: unknown OS)"
            return
        }

        if ($IsWindows) {
            # ---- Windows-specific facts -------------------------------
            Write-Sub "Hyper-V VMs (if present)"
            if (Test-CommandAvailable 'Get-VM') {
                try {
                    $vms = Get-VM -ErrorAction Stop | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime
                    if ($vms) {
                        $vms | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Output $_.TrimEnd() }
                    } else {
                        Write-Output "(no VMs registered with Hyper-V)"
                    }
                } catch {
                    Write-Output "(Get-VM failed: $($_.Exception.Message); needs Hyper-V role + elevation)"
                }
            } else {
                Write-Output "(Get-VM not available -- Hyper-V management tools not installed)"
            }

            Write-Sub "Listening sockets (Get-NetTCPConnection -State Listen, first 40)"
            try {
                $listen = Get-NetTCPConnection -State Listen -ErrorAction Stop |
                    Select-Object LocalAddress, LocalPort, OwningProcess |
                    Sort-Object LocalPort
                if ($listen) {
                    $listen | Select-Object -First 40 | Format-Table -AutoSize | Out-String -Width 200 | ForEach-Object { Write-Output $_.TrimEnd() }
                    if (@($listen).Count -gt 40) { Write-Output ("(... {0} more entries omitted)" -f (@($listen).Count - 40)) }
                } else {
                    Write-Output "(no listening sockets reported)"
                }
            } catch {
                Write-Output "(Get-NetTCPConnection failed: $($_.Exception.Message))"
            }

            Write-Sub "Windows firewall profiles"
            try {
                Get-NetFirewallProfile -ErrorAction Stop |
                    Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
                    Format-Table -AutoSize | Out-String | ForEach-Object { Write-Output $_.TrimEnd() }
            } catch {
                Write-Output "(Get-NetFirewallProfile failed: $($_.Exception.Message))"
            }

            Write-Sub "Recent System log errors (last 1h, 25 most recent)"
            try {
                $sinceStart = (Get-Date).AddHours(-1)
                $evts = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=@(1,2); StartTime=$sinceStart } -MaxEvents 25 -ErrorAction Stop
                if ($evts) {
                    $evts | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
                        Format-Table -AutoSize -Wrap | Out-String -Width 240 | ForEach-Object { Write-Output $_.TrimEnd() }
                } else {
                    Write-Output "(no System log errors/warnings in the last 1h)"
                }
            } catch {
                Write-Output "(Get-WinEvent System failed: $($_.Exception.Message))"
            }
            return
        }

        if ($IsMacOS) {
            # ---- macOS-specific facts ---------------------------------
            Write-Sub "Default route + interfaces (netstat -nr | head; ifconfig brief)"
            if (Test-CommandAvailable 'netstat') {
                & netstat -nrf inet 2>$null | Select-Object -First 12 | ForEach-Object { Write-Output $_ }
            }
            if (Test-CommandAvailable 'ifconfig') {
                & ifconfig 2>$null | Where-Object { $_ -match '^[a-z]|inet ' } | ForEach-Object { Write-Output $_ }
            }

            Write-Sub "DNS (scutil --dns | head -40)"
            if (Test-CommandAvailable 'scutil') {
                & scutil --dns 2>$null | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(scutil not in PATH)"
            }

            Write-Sub "Listening sockets (lsof -nP -iTCP -sTCP:LISTEN | head -40)"
            if (Test-CommandAvailable 'lsof') {
                & lsof -nP -iTCP -sTCP:LISTEN 2>$null | Select-Object -First 40 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(lsof not in PATH)"
            }

            Write-Sub "Virtualization stack (UTM/QEMU/utmctl)"
            foreach ($cmd in @('utmctl','qemu-img','virsh')) {
                if (Test-CommandAvailable $cmd) {
                    Write-Output ("  {0}: $(& which $cmd 2>$null)" -f $cmd)
                } else {
                    Write-Output ("  {0}: (not in PATH)" -f $cmd)
                }
            }
            if (Test-CommandAvailable 'utmctl') {
                Write-Output ""
                & utmctl list 2>$null | ForEach-Object { Write-Output $_ }
            }

            Write-Sub "Kernel ring buffer (dmesg -- needs root; otherwise sudo log show)"
            if (Test-CommandAvailable 'log') {
                # macOS unified log: pull errors/warnings from the last hour.
                & log show --last 1h --predicate 'eventMessage contains[c] "error" OR eventMessage contains[c] "fail"' --info --debug 2>$null |
                    Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            }
            return
        }

        # ---- Linux-specific facts (unchanged below) -------------------
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
            $dmesgOut = Invoke-PrivProbe -Tool 'dmesg' -ToolArgs @('-T') -KeepStderr
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
            $jxe = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-xe','-n','100','--no-pager') -KeepStderr
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
                $jOut = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-u',$svc,'--since','6 hours ago','-p','warning','-n','100','--no-pager') -KeepStderr
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

    # ===== 11b. INSTALL & EARLY-BOOT TIMELINE (Linux) ==================
    # --- See https://yuruna.link/system-diagnostic#11b-install-early-boot-timeline-linux
    if ($IsLinux) {
        Invoke-DiagnosticSection "INSTALL & EARLY-BOOT TIMELINE (Linux)" {
            Write-Sub "/var/log/installer/ (dir listing)"
            if (Test-Path '/var/log/installer') {
                $instItems = @(Get-ChildItem -Path '/var/log/installer' -Force -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($instItems.Count -eq 0) {
                    Write-Output "(directory exists but empty)"
                } else {
                    foreach ($it in $instItems) {
                        $size = if ($it.PSIsContainer) { '<DIR>' } else { ("{0,10}" -f $it.Length) }
                        Write-Output ("  {0}  {1}" -f $size, $it.Name)
                    }
                }
            } else {
                Write-Output "(no /var/log/installer -- not an Ubuntu Server / subiquity install, or logs were wiped)"
            }

            Write-Sub "/var/log/installer/autoinstall-user-data (full -- placeholders resolved)"
            if (Test-Path '/var/log/installer/autoinstall-user-data') {
                Get-Content -LiteralPath '/var/log/installer/autoinstall-user-data' -ErrorAction SilentlyContinue |
                    ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(absent)"
            }

            Write-Sub "/var/log/installer/subiquity-server-debug.log (smoking-gun scan + tail 100)"
            if (Test-Path '/var/log/installer/subiquity-server-debug.log') {
                $sub = Get-Content -LiteralPath '/var/log/installer/subiquity-server-debug.log' -ErrorAction SilentlyContinue
                $sendUpdate = @($sub | Where-Object { $_ -match '_send_update' })
                $changeIfaces = @($sub | Where-Object { $_ -match 'CHANGE\s+(eth0|enp0s1|ens3|en0)' })
                Write-Output ("_send_update lines: {0}" -f $sendUpdate.Count)
                Write-Output ("CHANGE <iface>   : {0}" -f $changeIfaces.Count)
                if ($sendUpdate.Count -ge 200) {
                    Add-Problem ("INSTALL: subiquity _send_update fired {0} times -- network model is being re-emitted, classic CHANGE-loop signature (IPv6 RAs, mirror retry storm, or VF flap)." -f $sendUpdate.Count)
                }
                $mirrorRetry = @($sub | Where-Object { $_ -match 'Retrying|mirror.*retry|elect.*mirror|geoip' })
                if ($mirrorRetry.Count -gt 0) {
                    Write-Output ""
                    Write-Output "Mirror-election / retry hits (first 20):"
                    $mirrorRetry | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
                }
                Write-Output ""
                Write-Output "Tail (last 100 lines):"
                $sub | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(absent)"
            }

            Write-Sub "/var/log/installer/subiquity-curtin-install.log (retry scan + tail 80)"
            if (Test-Path '/var/log/installer/subiquity-curtin-install.log') {
                $curtin = Get-Content -LiteralPath '/var/log/installer/subiquity-curtin-install.log' -ErrorAction SilentlyContinue
                $retries = @($curtin | Where-Object { $_ -match 'Retrying|retry|TimeoutError|ConnectionError|temporary failure' })
                Write-Output ("Retry/Timeout/Connection-error lines: {0}" -f $retries.Count)
                if ($retries.Count -ge 5) {
                    Add-Problem ("INSTALL: curtin saw {0} retry/timeout/connection-error lines -- proxy or mirror was slow/unreachable; check apt block in autoinstall-user-data." -f $retries.Count)
                    Write-Output "First 10 retry/error lines:"
                    $retries | Select-Object -First 10 | ForEach-Object { Write-Output $_ }
                }
                Write-Output ""
                Write-Output "Tail (last 80 lines):"
                $curtin | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(absent)"
            }

            Write-Sub "cloud-init status --long"
            if (Test-CommandAvailable 'cloud-init') {
                Invoke-Tool -Tool 'cloud-init' -ToolArgs @('status','--long')
            } else {
                Write-Output "(cloud-init not in PATH)"
            }

            Write-Sub "cloud-init analyze blame (top 20)"
            if (Test-CommandAvailable 'cloud-init') {
                $analyzeOut = & cloud-init analyze blame 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $analyzeOut | Select-Object -First 25 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output ("(cloud-init analyze blame exit {0})" -f $LASTEXITCODE)
                }
            }

            Write-Sub "/run/cloud-init/result.json"
            if (Test-Path '/run/cloud-init/result.json') {
                Get-Content -LiteralPath '/run/cloud-init/result.json' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
            } else { Write-Output "(absent)" }

            Write-Sub "/run/cloud-init/status.json"
            if (Test-Path '/run/cloud-init/status.json') {
                Get-Content -LiteralPath '/run/cloud-init/status.json' -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
            } else { Write-Output "(absent)" }

            Write-Sub "/var/log/cloud-init.log (tail 200)"
            if (Test-Path '/var/log/cloud-init.log') {
                Get-Content -LiteralPath '/var/log/cloud-init.log' -Tail 200 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
            } else { Write-Output "(absent)" }

            Write-Sub "/var/log/cloud-init-output.log (tail 200)"
            if (Test-Path '/var/log/cloud-init-output.log') {
                Get-Content -LiteralPath '/var/log/cloud-init-output.log' -Tail 200 -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_ }
            } else { Write-Output "(absent)" }

            Write-Sub "systemd-analyze time"
            if (Test-CommandAvailable 'systemd-analyze') {
                Invoke-Tool -Tool 'systemd-analyze' -ToolArgs @('time')
                Write-Output ""
                Write-Output "Blame (top 20):"
                $blame = & systemd-analyze blame 2>$null
                $blame | Select-Object -First 20 | ForEach-Object { Write-Output $_ }
            } else {
                Write-Output "(systemd-analyze not in PATH)"
            }

            Write-Sub "journalctl --list-boots"
            if (Test-CommandAvailable 'journalctl') {
                Invoke-Tool -Tool 'journalctl' -ToolArgs @('--list-boots','--no-pager') -Privileged
            } else { Write-Output "(journalctl not available)" }

            Write-Sub "journalctl -b -1 -p warning --no-pager (PREVIOUS boot -- usually the install boot; head 60 + tail 60)"
            if (Test-CommandAvailable 'journalctl') {
                $prev = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b','-1','-p','warning','--no-pager')
                if ($prev) {
                    $prev | Select-Object -First 60 | ForEach-Object { Write-Output $_ }
                    if ($prev.Count -gt 120) {
                        Write-Output ("... ({0} middle lines omitted) ..." -f ($prev.Count - 120))
                        $prev | Select-Object -Last 60 | ForEach-Object { Write-Output $_ }
                    } elseif ($prev.Count -gt 60) {
                        $prev | Select-Object -Skip 60 | ForEach-Object { Write-Output $_ }
                    }
                } else {
                    Write-Output "(no previous boot, or no warning+ entries)"
                }
            }

            Write-Sub "journalctl -b 0 -u systemd-networkd --no-pager (last 100)"
            if (Test-CommandAvailable 'journalctl') {
                $nw = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-b','0','-u','systemd-networkd','--no-pager')
                if ($nw) {
                    $nw | Select-Object -Last 100 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output "(no systemd-networkd entries this boot)"
                }
            }

            Write-Sub "networkctl status --all"
            if (Test-CommandAvailable 'networkctl') {
                Invoke-Tool -Tool 'networkctl' -ToolArgs @('status','--all','--no-pager') -Privileged
            } else { Write-Output "(networkctl not in PATH)" }

            Write-Sub "ip -br link / ip -br addr"
            if (Test-CommandAvailable 'ip') {
                Invoke-Tool -Tool 'ip' -ToolArgs @('-br','link')
                Write-Output ""
                Invoke-Tool -Tool 'ip' -ToolArgs @('-br','addr')
            }

            Write-Sub "dmesg | grep -iE 'eth0|netvsc|hv_|carrier|link is|accept_ra|NEWLINK' (last 80 matches)"
            if (Test-CommandAvailable 'dmesg') {
                $dm = Invoke-PrivProbe -Tool 'dmesg' -ToolArgs @('-T')
                if ($LASTEXITCODE -eq 0) {
                    $hits = @($dm | Where-Object { $_ -match '(?i)eth0|netvsc|hv_|carrier|link is|accept_ra|NEWLINK' })
                    if ($hits.Count -eq 0) {
                        Write-Output "(no eth0/netvsc/carrier/RA lines in kernel ring buffer)"
                    } else {
                        $hits | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
                    }
                } else {
                    Write-Output "(dmesg restricted -- rerun as root for kernel ring buffer)"
                }
            }
        }
    }

    # ===== 11c. GUEST PROVISIONING (Linux) =============================
    # --- See https://yuruna.link/definition#defining-get-systemdiagnostic (section 11c)
    if ($IsLinux) {
        Invoke-DiagnosticSection "GUEST PROVISIONING (Linux)" {
            Write-Sub "/var/log/yuruna/ (dir listing)"
            if (Test-Path '/var/log/yuruna') {
                $items = @(Get-ChildItem -Path '/var/log/yuruna' -Force -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($items.Count -eq 0) {
                    Write-Output "(directory exists but empty -- no pwsh_retry actions have run yet)"
                } else {
                    foreach ($it in $items) {
                        $size = if ($it.PSIsContainer) { '<DIR>' } else { ("{0,10}" -f $it.Length) }
                        Write-Output ("  {0}  {1}" -f $size, $it.Name)
                    }
                }
            } else {
                Write-Output "(no /var/log/yuruna -- guest update.sh has not run, or its pwsh_retry wrapper was bypassed)"
            }

            Write-Sub "/var/log/yuruna/*.log (full contents)"
            if (Test-Path '/var/log/yuruna') {
                $logs = @(Get-ChildItem -Path '/var/log/yuruna' -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
                if ($logs.Count -eq 0) {
                    Write-Output "(no *.log files)"
                } else {
                    foreach ($log in $logs) {
                        Write-Output ""
                        Write-Output ("===== {0} ({1} bytes) =====" -f $log.Name, $log.Length)
                        Get-Content -LiteralPath $log.FullName -ErrorAction SilentlyContinue |
                            ForEach-Object { Write-Output $_ }
                        $body = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
                        if ($body -and ($body -match 'all \d+ attempts exhausted')) {
                            Add-Problem ("PROVISIONING: {0} records exhausted pwsh_retry attempts -- the wrapped pwsh action failed every retry, cycle aborted." -f $log.Name)
                        }
                    }
                }
            }

            Write-Sub "journalctl -u systemd-resolved --since '15 min ago' (DNS slice)"
            if (Test-CommandAvailable 'journalctl') {
                $r = Invoke-PrivProbe -Tool 'journalctl' -ToolArgs @('-u','systemd-resolved','--since','15 min ago','--no-pager')
                if ($r) {
                    $r | Select-Object -Last 80 | ForEach-Object { Write-Output $_ }
                } else {
                    Write-Output "(no systemd-resolved entries in the last 15 min)"
                }
            } else {
                Write-Output "(journalctl not available)"
            }

            Write-Sub "PSRepository / PackageProvider / module state (current snapshot)"
            try {
                Get-PSRepository -ErrorAction Stop |
                    Format-List Name,SourceLocation,InstallationPolicy,Trusted | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output ("Get-PSRepository ERROR: {0}" -f $_.Exception.Message)
                Add-Problem "PROVISIONING: Get-PSRepository threw -- PSGallery registration is unhealthy; Install-Module will fail with 'No match was found'."
            }
            Write-Output "--- PackageProvider -ListAvailable ---"
            try {
                Get-PackageProvider -ListAvailable -ErrorAction Stop |
                    Select-Object Name,Version | Format-Table -AutoSize | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output ("Get-PackageProvider ERROR: {0}" -f $_.Exception.Message)
            }
            Write-Output "--- Modules (PowerShellGet, PSResourceGet, powershell-yaml) ---"
            try {
                Get-Module PowerShellGet, Microsoft.PowerShell.PSResourceGet, powershell-yaml -ListAvailable |
                    Select-Object Name,Version | Format-Table -AutoSize | Out-String |
                    ForEach-Object { Write-Output $_ }
            } catch {
                Write-Output ("Get-Module ERROR: {0}" -f $_.Exception.Message)
            }
        }
    }

    # ===== 12. YURUNA PROJECT ==========================================
    Invoke-DiagnosticSection "YURUNA PROJECT" {
        if ($SkipProjectGaps) {
            Write-Output "(skipped via -SkipProjectGaps)"
            return
        }
        $candidate   = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'project'
        $projectRoot = $null
        if (Test-Path -LiteralPath $candidate) {
            $projectRoot = (Resolve-Path -LiteralPath $candidate).Path
        }
        if (-not $projectRoot) {
            Write-Output "(no project directory at $candidate -- run this script from a yuruna checkout to populate this section)"
            return
        }
        $yurunaRoot     = (Split-Path -Parent $PSScriptRoot)
        $yurunaVerFile  = Join-Path -Path $yurunaRoot  -ChildPath 'VERSION'
        $projectVerFile = Join-Path -Path $projectRoot -ChildPath 'VERSION'

        function Get-RemoteOriginUrl {
            param([Parameter(Mandatory)][string]$RepoPath)
            if (Test-CommandAvailable 'git') {
                try {
                    $url = & git -C $RepoPath config --get remote.origin.url 2>$null
                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($url)) {
                        return ([string]$url).Trim()
                    }
                } catch {
                    Write-Verbose "Get-RemoteOriginUrl: git config failed for '$RepoPath' ($($_.Exception.Message)); trying sidecar."
                }
            }
            # Tarball-extracted trees have no .git/, so fall back to the
            # sidecar Start-StatusService.ps1 injects via `git archive --add-file`.
            $marker = Join-Path -Path $RepoPath -ChildPath '.yuruna-origin'
            if (Test-Path -LiteralPath $marker) {
                $line = Get-Content -LiteralPath $marker -TotalCount 1 -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    return ([string]$line).Trim()
                }
            }
            return $null
        }

        $yurunaVersion  = $null
        if (Test-Path -LiteralPath $yurunaVerFile) {
            $firstLine = Get-Content -LiteralPath $yurunaVerFile -TotalCount 1 -ErrorAction SilentlyContinue
            if ($null -ne $firstLine) { $yurunaVersion = ([string]$firstLine).Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($yurunaVersion)) {
            Write-Output "Yuruna version: (not found at $yurunaVerFile)"
            Add-Problem "YURUNA: VERSION file missing or empty at $yurunaVerFile"
        } else {
            $yurunaOrigin = Get-RemoteOriginUrl -RepoPath $yurunaRoot
            if ([string]::IsNullOrWhiteSpace($yurunaOrigin)) {
                Write-Output "Yuruna version: $yurunaVersion"
            } else {
                Write-Output "Yuruna version: $yurunaVersion - $yurunaOrigin"
            }
        }
        $projectVersion = $null
        if (Test-Path -LiteralPath $projectVerFile) {
            $firstLine = Get-Content -LiteralPath $projectVerFile -TotalCount 1 -ErrorAction SilentlyContinue
            if ($null -ne $firstLine) { $projectVersion = ([string]$firstLine).Trim() }
        }
        if ([string]::IsNullOrWhiteSpace($projectVersion)) {
            Write-Output "Project version: (not found at $projectVerFile)"
            Add-Problem "YURUNA: project VERSION file missing or empty at $projectVerFile"
        } else {
            $projectOrigin = Get-RemoteOriginUrl -RepoPath $projectRoot
            if ([string]::IsNullOrWhiteSpace($projectOrigin)) {
                Write-Output "Project version: $projectVersion"
            } else {
                Write-Output "Project version: $projectVersion - $projectOrigin"
            }
        }
        Write-Output "Project root: $projectRoot"

        $outputWalk = Get-FileTreeWithDeadline -Label 'resources.output.yml scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'resources.output.yml' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $outputWalk
        $outputFiles = @($outputWalk.Items)
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
        $yurunaWalk = Get-FileTreeWithDeadline -Label '.yuruna/ directory scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq '.yuruna' }
        }
        Show-FileTreeWalkTimeout -Walk $yurunaWalk
        $yurunaDirs = @($yurunaWalk.Items)
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
                $fileWalk = Get-FileTreeWithDeadline -Label ("file scan of {0}" -f $yd.FullName) -ArgumentList @($yd.FullName) -ScriptBlock {
                    param($dir)
                    Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue
                }
                Show-FileTreeWalkTimeout -Walk $fileWalk
                $files = @($fileWalk.Items)
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
                $mtimeWalk = Get-FileTreeWithDeadline -Label ("mtime scan of {0}" -f $yd.FullName) -ArgumentList @($yd.FullName) -ScriptBlock {
                    param($dir)
                    Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue
                }
                Show-FileTreeWalkTimeout -Walk $mtimeWalk
                foreach ($f in @($mtimeWalk.Items)) { $allFiles.Add($f) }
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

    # ===== 13. GAP HEURISTICS ==========================================
    # --- See https://yuruna.link/system-diagnostic#13-gap-heuristics
    Invoke-DiagnosticSection "GAP HEURISTICS" {
        if ($SkipProjectGaps) {
            Write-Output "(skipped via -SkipProjectGaps)"
            return
        }
        $candidate   = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'project'
        $projectRoot = $null
        if (Test-Path -LiteralPath $candidate) {
            $projectRoot = (Resolve-Path -LiteralPath $candidate).Path
        }
        if (-not $projectRoot) {
            Write-Output "(no project directory at $candidate -- skipping gap heuristics)"
            return
        }

        $kubectlReady = ($null -ne (Get-Command 'kubectl' -ErrorAction SilentlyContinue)) -and (-not $SkipKube)
        $helmReady    = $null -ne (Get-Command 'helm'    -ErrorAction SilentlyContinue)

        # --- Heuristic 1: tofu.tfstate exists but helm has zero releases ---
        # --- See https://yuruna.link/system-diagnostic#heuristic-1-tofu-state-without-helm-releases
        Write-Sub "Heuristic 1: tofu state without helm releases"
        $tfStateWalk = Get-FileTreeWithDeadline -Label 'tofu.tfstate scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'tofu.tfstate' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $tfStateWalk
        $tfStateFiles = @($tfStateWalk.Items)
        $tfStateCount = $tfStateFiles.Count
        if ($tfStateCount -eq 0) {
            Write-Output "(no tofu.tfstate files under $projectRoot -- Set-Resource has not run; skipping)"
        } elseif (-not $helmReady) {
            Write-Output "($tfStateCount tofu.tfstate file(s) present but helm not in PATH; cannot check)"
        } else {
            $helmCount = 0
            try {
                $helmJson = & helm list -A -o json 2>$null
                if ($null -ne $helmJson -and -not [string]::IsNullOrWhiteSpace($helmJson)) {
                    $helmList = $helmJson | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($helmList) { $helmCount = @($helmList).Count }
                }
            } catch {
                Write-Verbose ("helm list failed: {0}" -f $_.Exception.Message)
            }
            Write-Output ("tofu.tfstate files: {0}; helm releases (all namespaces): {1}" -f $tfStateCount, $helmCount)
            if ($helmCount -eq 0) {
                Add-Problem ("GAP: $tfStateCount tofu.tfstate file(s) present but helm has 0 releases across all namespaces -- the workloads phase appears to have been skipped or exited 0 without calling Set-Workload. Check the helm.stderr.log files above and the wrapper script's last lines.")
            }
        }

        # --- Heuristic 2: resources.output.yml declares a namespace that doesn't exist in the cluster ---
        # --- See https://yuruna.link/system-diagnostic#heuristic-2-declared-namespaces-missing-from-cluster
        Write-Sub "Heuristic 2: declared namespaces missing from cluster"
        $nsOutputWalk = Get-FileTreeWithDeadline -Label 'resources.output.yml scan' -ArgumentList @($projectRoot) -ScriptBlock {
            param($root)
            Get-ChildItem -Path $root -Recurse -Filter 'resources.output.yml' -File -ErrorAction SilentlyContinue
        }
        Show-FileTreeWalkTimeout -Walk $nsOutputWalk
        $outputFiles = @($nsOutputWalk.Items)
        if ($outputFiles.Count -eq 0) {
            Write-Output "(no resources.output.yml under $projectRoot -- skipping)"
        } elseif (-not $kubectlReady) {
            Write-Output "($($outputFiles.Count) resources.output.yml file(s) present but kubectl not in PATH; cannot check)"
        } else {
            $declaredNs = New-Object System.Collections.Generic.List[object]
            foreach ($of in $outputFiles) {
                try {
                    $content = Get-Content -LiteralPath $of.FullName -Raw -ErrorAction Stop
                } catch { continue }
                # --- See https://yuruna.link/system-diagnostic#heuristic-2-declared-namespaces-missing-from-cluster (regex rationale)
                $inGlobals = $false
                foreach ($raw in ($content -split "`r?`n")) {
                    if ($raw -match '^globalVariables:\s*$') { $inGlobals = $true; continue }
                    if ($inGlobals -and $raw -match '^\S') { $inGlobals = $false; continue }
                    if ($inGlobals -and $raw -match '^\s+namespace:\s*[''"]?([^''"\s]+)[''"]?\s*$') {
                        $declaredNs.Add(@{ Name = $Matches[1]; File = $of.FullName })
                    }
                }
            }
            if ($declaredNs.Count -eq 0) {
                Write-Output "(no globalVariables.namespace declarations found in any resources.output.yml)"
            } else {
                $clusterNs = @(& kubectl get ns -o name --request-timeout=5s 2>$null | ForEach-Object { ($_ -replace '^namespace/','').Trim() } | Where-Object { $_ })
                foreach ($d in $declaredNs) {
                    if ($clusterNs -contains $d.Name) {
                        Write-Output ("  namespace '{0}' declared in {1} -- present in cluster" -f $d.Name, $d.File)
                    } else {
                        Write-Output ("  namespace '{0}' declared in {1} -- MISSING from cluster" -f $d.Name, $d.File)
                        Add-Problem ("GAP: namespace '$($d.Name)' declared in $($d.File) but does not exist in the cluster -- workloads phase never created it (helm install / kubectl create namespace did not run, or errored).")
                    }
                }
            }
        }

        # --- Heuristic 3: nodes Ready but zero user-namespace pods ---
        # --- See https://yuruna.link/system-diagnostic#heuristic-3-cluster-ready-but-no-user-namespace-pods
        Write-Sub "Heuristic 3: cluster Ready but no user-namespace pods"
        if (-not $kubectlReady) {
            Write-Output "(kubectl not in PATH; cannot check)"
        } else {
            $readyNodes = @(& kubectl get nodes --no-headers --request-timeout=5s 2>$null |
                Where-Object { ($_ -split '\s+')[1] -match '^Ready' })
            if ($readyNodes.Count -eq 0) {
                Write-Output "(no Ready nodes -- cluster is not up; not a deploy gap, see KUBE section)"
            } else {
                $systemNs = @('default','kube-system','kube-public','kube-node-lease','kube-flannel','kube-proxy')
                $userPods = @(& kubectl get pods -A --no-headers --request-timeout=5s 2>$null |
                    ForEach-Object {
                        $cols = $_ -split '\s+'
                        if ($cols.Count -ge 2 -and $systemNs -notcontains $cols[0]) { $_ }
                    })
                Write-Output ("Ready nodes: {0}; user-namespace pods: {1}" -f $readyNodes.Count, $userPods.Count)
                if ($userPods.Count -eq 0) {
                    Add-Problem ("GAP: cluster has $($readyNodes.Count) Ready node(s) but zero pods outside the system namespaces -- nothing has been deployed (workloads/components phase did not land).")
                }
            }
        }

        # --- Heuristic 4: image in local registry but no pod references it ---
        # --- See https://yuruna.link/system-diagnostic#heuristic-4-local-registry-image-not-referenced-by-any-pod
        Write-Sub "Heuristic 4: local registry image not referenced by any pod"
        if (-not $kubectlReady) {
            Write-Output "(kubectl not in PATH; cannot check)"
        } else {
            $registryRepos = @()
            try {
                $probe = Invoke-WebRequest -Uri 'http://localhost:5000/v2/_catalog' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                if ($probe -and $probe.Content) {
                    $catalog = $probe.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($catalog -and $catalog.repositories) { $registryRepos = @($catalog.repositories) }
                }
            } catch {
                Write-Verbose ("local registry probe failed: {0}" -f $_.Exception.Message)
            }
            if ($registryRepos.Count -eq 0) {
                Write-Output "(no local registry at :5000 or its catalog is empty; nothing to cross-check)"
            } else {
                # Containers + initContainers + ephemeralContainers, all namespaces
                $allImages = @(& kubectl get pods -A --request-timeout=5s `
                    -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"`n"}{end}{range .spec.initContainers[*]}{.image}{"`n"}{end}{range .spec.ephemeralContainers[*]}{.image}{"`n"}{end}{end}' 2>$null `
                    -split "`n" | Where-Object { $_ })
                $orphans = @()
                foreach ($repo in $registryRepos) {
                    # --- See https://yuruna.link/system-diagnostic#heuristic-4-local-registry-image-not-referenced-by-any-pod (image-ref shape)
                    $needle = "/$repo`:"
                    $matched = @($allImages | Where-Object { $_ -like "*$needle*" })
                    if ($matched.Count -eq 0) {
                        $orphans += $repo
                        Write-Output ("  registry repo '{0}' -- NO pod references it" -f $repo)
                    } else {
                        Write-Output ("  registry repo '{0}' -- referenced by {1} container(s)" -f $repo, $matched.Count)
                    }
                }
                if ($orphans.Count -gt 0) {
                    Add-Problem ("GAP: $($orphans.Count) image(s) pushed to local registry but not referenced by any pod -- $($orphans -join ', '). The workloads phase either didn't deploy a chart that uses these images, or the chart rendered them with a different registry prefix (check componentsRegistry.registryLocation in resources.output.yml).")
                }
            }
        }
    }

    # ===== 14. SUMMARY =================================================
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
