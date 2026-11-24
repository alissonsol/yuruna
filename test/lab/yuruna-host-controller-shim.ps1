<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42889aa3-3572-45cd-81f3-ebde682b78e1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-update controller shim windows
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    The Windows host controller shim: starts the host controller from a
    private snapshot and starts it again when it ends.
.DESCRIPTION
    Deployed by Enable-TestAutomation as <controller root>\shim.ps1 and run
    by the scheduled task "Yuruna Host Controller" under Windows PowerShell
    5.1, the shell Windows always has and no installer replaces. It is the
    one layer no host update replaces, so it reads nothing but the
    controller root, stays 7-bit ASCII, and uses nothing PowerShell 7 added:
      current    current=<hash>, previous=<hash>, checkout=<path>
      rejected   hashes given up on, one per line
      versions\<hash>\ok   created by a controller of that snapshot that started
      stop       present: end the controller and exit (Disable-TestAutomation)

    Controller exits:
      75        start the current snapshot again at once
      76        another controller holds the lock: wait 30 s, not a death
      77        upgrade PowerShell: run the installer named in
                pwsh-upgrade.request, bounded at 1200 s, write
                pwsh-upgrade.result, then start the controller at once,
                whatever the upgrade did
      anything  start again after 10 s, doubling to 60 s, back to 10 s after
                a run of five minutes; three deaths in a row of a snapshot
                that never created ok reject that snapshot

    The controller is started with Process.Start and the shim waits on that
    one process: Start-Process -Wait would wait for every descendant, and
    the listener and the runner a controller starts live for weeks. A stop
    ends the controller process alone, as if it had been killed, and waits
    at most 30 s; a step child it started runs on to its own bound, and the
    next controller continues from the journal.
.PARAMETER ControllerRoot
    The controller root; the shim's own folder by default.
.PARAMETER PwshPath
    PowerShell 7; found on PATH, then in its default folder, by default.
.PARAMETER WindowsPowerShellPath
    Windows PowerShell, which runs the upgrade of PowerShell 7.
.PARAMETER UpgradeRoot
    The folder an upgrade request's installer must lie in:
    %ProgramData%\yuruna, which only Administrators can write.
#>

[CmdletBinding()]
param(
    [string]$ControllerRoot = $PSScriptRoot,
    [string]$PwshPath = '',
    [string]$WindowsPowerShellPath = '',
    [string]$UpgradeRoot = ''
)

$ErrorActionPreference = 'Stop'

function Write-ShimLog {
    param([string]$Text)
    $line = ('{0} yuruna-host-controller: {1}' -f [DateTime]::UtcNow.ToString('o'), $Text)
    try {
        $path = Join-Path $script:Root 'shim.log'
        $info = New-Object System.IO.FileInfo $path
        if ($info.Exists -and $info.Length -gt 1048576) { [System.IO.File]::Copy($path, "$path.1", $true); [System.IO.File]::Delete($path) }
        [System.IO.File]::AppendAllText($path, $line + "`r`n", [System.Text.Encoding]::ASCII)
    } catch {
        [Console]::Error.WriteLine($line)
    }
}

function Get-ShimEpoch { return [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds }

function Test-ShimStop { return [System.IO.File]::Exists((Join-Path $script:Root 'stop')) }

# Waits in steps of a second, so a stop is seen at once, not after the whole
# wait. Returns $true when a stop was asked for.
function Wait-ShimPause {
    param([int]$Seconds)
    for ($i = 0; $i -lt $Seconds; $i++) {
        if (Test-ShimStop) { return $true }
        Start-Sleep -Seconds 1
    }
    return (Test-ShimStop)
}

function Test-ShimHash {
    param([string]$Hash)
    return ($Hash -cmatch '\A[0-9a-f]{16}\z')
}

function Test-ShimRejected {
    param([string]$Hash)
    $path = Join-Path $script:Root 'rejected'
    if (-not [System.IO.File]::Exists($path)) { return $false }
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line.Trim() -ceq $Hash) { return $true }
    }
    return $false
}

function Test-ShimUsable {
    param([string]$Hash)
    return ((Test-ShimHash $Hash) -and -not (Test-ShimRejected $Hash) -and [System.IO.Directory]::Exists((Join-Path (Join-Path $script:Root 'versions') $Hash)))
}

function Read-ShimCurrent {
    $state = @{ Current = ''; Previous = ''; Checkout = '' }
    $path = Join-Path $script:Root 'current'
    if (-not [System.IO.File]::Exists($path)) { return $state }
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($path)) {
            if ($line.StartsWith('current=')) { $state.Current = $line.Substring(8) }
            elseif ($line.StartsWith('previous=')) { $state.Previous = $line.Substring(9) }
            elseif ($line.StartsWith('checkout=')) { $state.Checkout = $line.Substring(9) }
        }
    } catch {
        Write-ShimLog "could not read $path"
    }
    return $state
}

function Write-ShimCurrent {
    param([string]$Current, [string]$Previous, [string]$Checkout)
    $path = Join-Path $script:Root 'current'
    $temp = "$path.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($temp, "current=$Current`nprevious=$Previous`ncheckout=$Checkout`n", [System.Text.Encoding]::ASCII)
        if ([System.IO.File]::Exists($path)) { [System.IO.File]::Replace($temp, $path, [NullString]::Value) } else { [System.IO.File]::Move($temp, $path) }
        return $true
    } catch {
        try { [System.IO.File]::Delete($temp) } catch { Write-ShimLog "could not remove $temp" }
        Write-ShimLog "could not rewrite $path"
        return $false
    }
}

# The newest snapshot that has started once and was not rejected.
function Get-ShimNewestOk {
    $best = ''
    $bestTime = [DateTime]::MinValue
    $versions = Join-Path $script:Root 'versions'
    if (-not [System.IO.Directory]::Exists($versions)) { return '' }
    foreach ($dir in [System.IO.Directory]::GetDirectories($versions)) {
        $ok = Join-Path $dir 'ok'
        if (-not [System.IO.File]::Exists($ok)) { continue }
        $candidate = [System.IO.Path]::GetFileName($dir)
        if (-not (Test-ShimUsable $candidate)) { continue }
        $time = [System.IO.File]::GetLastWriteTimeUtc($ok)
        if (-not $best -or $time -gt $bestTime) { $best = $candidate; $bestTime = $time }
    }
    return $best
}

function Invoke-ShimReject {
    param([string]$Hash)
    $state = Read-ShimCurrent
    try { [System.IO.File]::AppendAllText((Join-Path $script:Root 'rejected'), "$Hash`n", [System.Text.Encoding]::ASCII) } catch { Write-ShimLog "could not record $Hash as rejected" }
    if ($state.Previous -and $state.Previous -cne $Hash -and (Test-ShimUsable $state.Previous)) {
        $null = Write-ShimCurrent -Current $state.Previous -Previous '' -Checkout $state.Checkout
        Write-ShimLog "snapshot $Hash died three times without starting; rejected, back to $($state.Previous)"
    } else {
        $null = Write-ShimCurrent -Current '' -Previous '' -Checkout $state.Checkout
        Write-ShimLog "snapshot $Hash died three times without starting; rejected, no previous snapshot"
    }
}

function Resolve-ShimPwsh {
    if ($script:Pwsh) { return $script:Pwsh }
    $found = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Path }
    if ($env:ProgramFiles) {
        $default = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
        if ([System.IO.File]::Exists($default)) { return $default }
    }
    return ''
}

# One process, waited on by its own handle in steps of a second so a stop is
# seen. Returns @{ Code; Stopped }.
function Invoke-ShimProcess {
    param([string]$FilePath, [string]$Arguments, [int]$BoundSeconds, [hashtable]$Environment)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $script:Root
    if ($Environment) { foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = [string]$Environment[$name] } }
    $process = [System.Diagnostics.Process]::Start($info)
    $script:Child = $process
    $started = if ($BoundSeconds -gt 0) { Get-ShimEpoch } else { 0 }
    try {
        while (-not $process.WaitForExit(1000)) {
            if (Test-ShimStop) {
                Stop-ShimChild
                return @{ Code = $null; Stopped = $true }
            }
            if ($BoundSeconds -gt 0 -and ((Get-ShimEpoch) - $started) -ge $BoundSeconds) {
                Write-ShimLog "process $($process.Id) passed its bound of $BoundSeconds s; ending it"
                try { $process.Kill() } catch { Write-ShimLog "process $($process.Id) could not be ended" }
                $null = $process.WaitForExit(30000)
                return @{ Code = $null; Stopped = $false; TimedOut = $true }
            }
        }
        return @{ Code = $process.ExitCode; Stopped = $false }
    } finally {
        $script:Child = $null
        $process.Dispose()
    }
}

# Ends the controller alone, as if it had been killed, and waits at most 30 s.
function Stop-ShimChild {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Runs unattended under the scheduled task; ending its own child is the stop it was asked for.')]
    param()
    $process = $script:Child
    if (-not $process) { return }
    Write-ShimLog "stop: ending controller $($process.Id)"
    try { if (-not $process.HasExited) { $process.Kill() } } catch { Write-ShimLog "stop: controller $($process.Id) could not be ended" }
    if (-not $process.WaitForExit(30000)) { Write-ShimLog "stop: controller $($process.Id) still running after 30 s; leaving it" }
}

# Exit 77: the controller asked for the PowerShell 7 upgrade it cannot run on
# itself. The request names an installer copy in a folder only Administrators
# can write; anything else is refused and only logged.
function Invoke-ShimUpgrade {
    $request = Join-Path $script:Root 'pwsh-upgrade.request'
    $resultPath = Join-Path $script:Root 'pwsh-upgrade.result'
    $result = [ordered]@{ schemaVersion = 1; installer = ''; startedUtc = [DateTime]::UtcNow.ToString('o'); endedUtc = ''; exitCode = $null; timedOut = $false; reason = '' }
    $installer = ''
    if ([System.IO.File]::Exists($request)) {
        try { $installer = ([System.IO.File]::ReadAllText($request)).Trim() } catch { $installer = '' }
    }
    $allowed = $script:UpgradeRootPath
    if (-not $installer) {
        $result.reason = 'request_missing'
    } elseif (-not $allowed -or -not [System.IO.Path]::IsPathRooted($installer) -or -not $installer.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFullPath($installer)).StartsWith($allowed.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        -not [System.IO.File]::Exists($installer)) {
        $result.reason = 'installer_refused'
    } else {
        $result.installer = $installer
        Write-ShimLog "upgrading PowerShell with $installer"
        $run = Invoke-ShimProcess -FilePath $script:WindowsPowerShell -BoundSeconds 1200 `
            -Arguments ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Unattended -UpgradePowerShell' -f $installer)
        if ($run.Stopped) { return $false }
        $result.exitCode = $run.Code
        $result.timedOut = [bool]$run.TimedOut
        $result.reason = if ($run.TimedOut) { 'timeout' } elseif ($run.Code -eq 0) { 'ok' } else { 'failed' }
    }
    $result.endedUtc = [DateTime]::UtcNow.ToString('o')
    try {
        [System.IO.File]::WriteAllText($resultPath, (New-Object PSObject -Property $result | ConvertTo-Json -Compress), [System.Text.Encoding]::ASCII)
        if ([System.IO.File]::Exists($request)) { [System.IO.File]::Delete($request) }
    } catch {
        Write-ShimLog "could not write $resultPath"
    }
    Write-ShimLog "PowerShell upgrade ended: $($result.reason)"
    return $true
}

function Invoke-Shim {
    $delay = 10
    $deaths = 0
    $deathHash = ''
    while ($true) {
        if (Test-ShimStop) { Write-ShimLog 'stop: exiting'; return }
        $state = Read-ShimCurrent
        $hash = $state.Current
        if (-not (Test-ShimUsable $hash)) {
            $hash = Get-ShimNewestOk
            if (-not $hash) {
                Write-ShimLog 'no snapshot to start; looking again in 60 s'
                if (Wait-ShimPause 60) { return }
                continue
            }
            Write-ShimLog "current snapshot unusable; starting $hash"
        }
        if (-not $state.Checkout) {
            Write-ShimLog "no checkout recorded in $(Join-Path $script:Root 'current'); looking again in 60 s"
            if (Wait-ShimPause 60) { return }
            continue
        }
        $pwsh = Resolve-ShimPwsh
        if (-not $pwsh) {
            Write-ShimLog 'pwsh.exe not found; looking again in 60 s'
            if (Wait-ShimPause 60) { return }
            continue
        }
        $controller = Join-Path (Join-Path (Join-Path $script:Root 'versions') $hash) 'test\lab\Invoke-HostUpdateController.ps1'
        if ([System.IO.Path]::DirectorySeparatorChar -ne '\') { $controller = $controller.Replace('\', [System.IO.Path]::DirectorySeparatorChar) }
        $arguments = '-NoLogo -NoProfile -NonInteractive -File "{0}" -ControllerRoot "{1}" -Snapshot {2} -Checkout "{3}"' -f $controller, $script:Root, $hash, $state.Checkout
        $start = Get-ShimEpoch
        $run = Invoke-ShimProcess -FilePath $pwsh -Arguments $arguments -Environment @{ YURUNA_HOST_CONTROLLER_LOG = (Join-Path $script:Root 'controller.log') }
        if ($run.Stopped) { Write-ShimLog 'stop: exiting'; return }
        $code = $run.Code
        if ($code -eq 75) { $delay = 10; $deaths = 0; continue }
        if ($code -eq 76) {
            Write-ShimLog 'another controller holds the lock; trying again in 30 s'
            if (Wait-ShimPause 30) { return }
            continue
        }
        if ($code -eq 77) {
            if (-not (Invoke-ShimUpgrade)) { Write-ShimLog 'stop: exiting'; return }
            $delay = 10
            $deaths = 0
            continue
        }
        if (((Get-ShimEpoch) - $start) -ge 300) { $delay = 10; $deaths = 0 }
        if ([System.IO.File]::Exists((Join-Path (Join-Path (Join-Path $script:Root 'versions') $hash) 'ok'))) {
            $deaths = 0
        } else {
            if ($hash -cne $deathHash) { $deathHash = $hash; $deaths = 0 }
            $deaths++
            if ($deaths -ge 3) {
                Invoke-ShimReject -Hash $hash
                $deaths = 0
            }
        }
        Write-ShimLog "controller of snapshot $hash exited with $code; starting again in $delay s"
        if (Wait-ShimPause $delay) { return }
        $delay = [Math]::Min($delay * 2, 60)
    }
}

$script:Root = [System.IO.Path]::GetFullPath($ControllerRoot)
$script:Pwsh = $PwshPath
$script:Child = $null
$script:WindowsPowerShell = $WindowsPowerShellPath
if (-not $script:WindowsPowerShell -and $env:SystemRoot) { $script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$script:UpgradeRootPath = $UpgradeRoot
if (-not $script:UpgradeRootPath -and $env:ProgramData) { $script:UpgradeRootPath = Join-Path $env:ProgramData 'yuruna' }
if ($script:UpgradeRootPath) { $script:UpgradeRootPath = [System.IO.Path]::GetFullPath($script:UpgradeRootPath) }

# Dot-sourced, the shim only defines its functions, so a suite can drive one
# rule at a time.
if ($MyInvocation.InvocationName -ne '.') {
    Write-ShimLog "started (controller root $script:Root)"
    Invoke-Shim
    exit 0
}
