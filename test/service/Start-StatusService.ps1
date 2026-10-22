<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42fba995-7607-4a66-acfd-0149a2a9f06a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Starts the status HTTP server as an independent background process.

.DESCRIPTION
    Launches a detached pwsh process that serves the test/status/ directory
    over HTTP. The server keeps running even if the caller exits.
    A PID file ($env:YURUNA_RUNTIME_DIR/server.pid) is written so
    service/Stop-StatusService.ps1 can shut it down later.

.PARAMETER Port
    TCP port to listen on. Defaults to the value in test.config.yml,
    or 8080 if not configured.

.PARAMETER Restart
    Stop any existing server before starting a new one. Use this after
    a git pull or config change to ensure the server picks up new files.

.PARAMETER RefreshSafe
    Start the service only if it is positively absent, and never disturb
    anything else. This is the start a host refresh uses to bring the listener
    back: it never stops a process, never takes a port from another owner,
    never restarts a live server whose framework commit changed, and never
    runs the startup sweeps that clear control files or rewrite status.json.
    An owned server that answers is left running (existing-ready); an owned
    server that does not answer, a pidfile whose owner cannot be identified,
    a port held by anyone else, or a concurrent start is reported and left
    alone. Must run as its own process (pwsh -File): it ends with an explicit
    exit code, 0 for existing-ready or started, 2 for a start it could not
    complete, 1 for an invocation it refused. Requires YURUNA_RUNTIME_DIR to
    name the owning runtime directory.

.PARAMETER ResultPath
    RefreshSafe only: where to write the outcome record
    {schemaVersion, outcome, port, pid, startTimeUnixMs, sha, shaMatches,
    reason}. Callers read this file rather than parsing output. It must lie
    outside the status, runtime, log and repository directories, all of which
    the service serves.

.PARAMETER DeadlineTickMs
    RefreshSafe only: the boot-relative tick ([Environment]::TickCount64) by
    which the start must finish. Clamped to at most two minutes from now;
    defaults to one minute. Every wait derives from it.
#>

[CmdletBinding(DefaultParameterSetName = 'Normal')]
param(
    [Parameter(ParameterSetName = 'Normal')]
    [Parameter(ParameterSetName = 'RefreshSafe', Mandatory)]
    [int]$Port = 0,
    [Parameter(ParameterSetName = 'Normal')][switch]$Restart,
    [Parameter(ParameterSetName = 'RefreshSafe', Mandatory)][switch]$RefreshSafe,
    [Parameter(ParameterSetName = 'RefreshSafe')][string]$ResultPath,
    [Parameter(ParameterSetName = 'RefreshSafe')][ValidateRange(1, [long]::MaxValue)][long]$DeadlineTickMs
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking


$ErrorActionPreference = "Stop"

# Seconds to wait for the detached status service to start answering on $Port
# before emitting the "not responding" warning. The loop polls once per
# second, so this is also the maximum number of poll attempts.
$script:StatusServiceReadyTimeoutSeconds = 60

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths      = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
$TestRoot   = $paths.TestRoot
$RepoRoot   = $paths.RepoRoot
$StatusDir  = $paths.StatusDir
$ModulesDir = $paths.ModulesDir

# See https://yuruna.link/42e5cdfd-003d
Initialize-YurunaEntryPointModuleSet -For StatusService -ModulesDir $ModulesDir
# The startup lock, the refresh-safe outcome record and the ownership check.
# -Global without -Force: this script is also &-invoked inside the inner
# runner, where reloading the lock module would discard its record of locks
# that process already holds.
Import-Module (Join-Path $ModulesDir 'Test.StateFile.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.SingleFlightLock.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.StatusControlRoute.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.PrivateStateRepair.psm1') -DisableNameChecking

# --- REGION: Startup serialization and the refresh-safe outcome
# See https://yuruna.link/42e5cdfd-003d
$script:StatusStartupLock = $null
$script:RefreshSafeResultPath = $null
$script:RefreshSafeDeadline = $null
function Exit-StatusServiceStartupLock {
    [CmdletBinding()]
    param()
    if ($null -ne $script:StatusStartupLock) {
        try { Exit-YurunaSingleFlightLock -Lock $script:StatusStartupLock } catch { Write-Verbose "startup lock release failed: $($_.Exception.Message)" }
        $script:StatusStartupLock = $null
    }
}
function Complete-RefreshSafeStart {
    <#
    .SYNOPSIS
        End a refresh-safe start: write the outcome record, report it,
        release the startup lock and exit with the outcome's code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('existing-ready', 'started', 'existing-unresponsive', 'unknown-owner', 'port-conflict',
            'port-privilege-required', 'start-timeout', 'admission-busy', 'launch-failed', 'generation-failed', 'invalid-invocation')]
        [string]$Outcome,
        [string]$Reason = '',
        [int]$ProcessId = 0,
        [long]$StartTimeUnixMs = 0,
        [string]$Sha = '',
        [Nullable[bool]]$ShaMatches
    )
    $code = switch ($Outcome) { 'existing-ready' { 0 } 'started' { 0 } 'invalid-invocation' { 1 } default { 2 } }
    if ($script:RefreshSafeResultPath) {
        $record = [ordered]@{
            schemaVersion   = 1
            outcome         = $Outcome
            port            = $Port
            pid             = $ProcessId
            startTimeUnixMs = $StartTimeUnixMs
            sha             = $Sha
            shaMatches      = $ShaMatches
            reason          = $Reason
        }
        if (-not (Write-YurunaStateFileJson -Path $script:RefreshSafeResultPath -InputObject $record -Confirm:$false)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_result_unwritable' -Arguments @{ path = $script:RefreshSafeResultPath })
        }
    }
    switch ($Outcome) {
        'existing-ready' { Write-Output (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_existing_ready' -Arguments @{ processId = $ProcessId; port = $Port }) }
        'started' { Write-Output (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_started' -Arguments @{ processId = $ProcessId; port = $Port }) }
        'invalid-invocation' { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_refused' -Arguments @{ reason = $Reason }) }
        default { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_partial' -Arguments @{ port = $Port; outcome = $Outcome; reason = $Reason }) }
    }
    Exit-StatusServiceStartupLock
    exit $code
}
# A trap covers its whole scope, including the imports above that run before
# the helper exists; calling it unguarded there would replace the real error
# with "Exit-StatusServiceStartupLock is not recognized".
trap {
    if (Get-Command -Name 'Exit-StatusServiceStartupLock' -CommandType Function -ErrorAction SilentlyContinue) { Exit-StatusServiceStartupLock }
    break
}

if ($RefreshSafe) {
    $script:RefreshSafeDeadline = New-YurunaDeadlineFromExpiry -MaximumMilliseconds 120000 -ExpiryTick $(
        if ($PSBoundParameters.ContainsKey('DeadlineTickMs')) { $DeadlineTickMs } else { [Environment]::TickCount64 + 60000 })
    if ($ResultPath) {
        # Checked here against the roots known before the runtime is, so even
        # a refusal of the runtime itself leaves a record; checked again below
        # once the runtime and log directories are resolved.
        $resultFull = [System.IO.Path]::GetFullPath($ResultPath)
        if ((Test-StatusPathOutsideServedRoot -Path $resultFull -ServedRoot @($RepoRoot, $StatusDir, $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR)) -and
            [System.IO.Directory]::Exists([System.IO.Path]::GetDirectoryName($resultFull))) {
            $script:RefreshSafeResultPath = $resultFull
        } else {
            # A result the caller would read is refused rather than written
            # into a served tree or a directory that does not exist.
            Complete-RefreshSafeStart -Outcome 'invalid-invocation' -Reason 'result-path-refused'
        }
    }
    # The owning runtime is an input here, never a default: a refresh that
    # starts a listener for a different runtime restores nothing.
    if ([string]::IsNullOrWhiteSpace($env:YURUNA_RUNTIME_DIR) -or -not [System.IO.Directory]::Exists($env:YURUNA_RUNTIME_DIR)) {
        Complete-RefreshSafeStart -Outcome 'invalid-invocation' -Reason 'runtime-unresolved'
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        Complete-RefreshSafeStart -Outcome 'invalid-invocation' -Reason 'port-invalid'
    }
}
$null = Initialize-YurunaRuntimeDir
$null = Initialize-YurunaLogDir
$RuntimeDir = $env:YURUNA_RUNTIME_DIR
$LogDir     = $env:YURUNA_LOG_DIR

$PidFile = Join-Path $RuntimeDir "server.pid"
$ServedRootSet = @($RepoRoot, $StatusDir, $RuntimeDir, $LogDir)

if ($script:RefreshSafeResultPath -and -not (Test-StatusPathOutsideServedRoot -Path $script:RefreshSafeResultPath -ServedRoot $ServedRootSet)) {
    $script:RefreshSafeResultPath = $null
    Complete-RefreshSafeStart -Outcome 'invalid-invocation' -Reason 'result-path-refused'
}

if ($Port -le 0) {
    $configPath = Join-Path $TestRoot "test.config.yml"
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered
            if ($config.statusService.port) { $Port = [int]$config.statusService.port }
        } catch { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_b679e6af39104f7b' -Arguments @{ value = "$_" }) }
    }
    if ($Port -le 0) { $Port = 8080 }
}

# A stopped pipeline can enter the trap without allowing its Get-Command
# guard to run. Finally must release the handle even when startup is canceled
# in a long-lived interactive session.
try {
$startLockInfo = $null
$privateStateRepair = $null
try {
    $startLockInfo = Get-YurunaPrivateStatePath -Name ("status-service.{0}.start.lock" -f (Get-StatusRuntimeKey -RuntimeDir $RuntimeDir)) -ServedRoot $ServedRootSet
} catch { Write-Verbose "startup lock path unresolved: $($_.Exception.Message)" }
if (-not $RefreshSafe -and (-not $startLockInfo -or -not $startLockInfo.Resolved)) {
    $privateStateRepair = Repair-YurunaStartupPrivateState -ServedRoot $ServedRootSet -AllowPrompt -Confirm:$false
    if ($privateStateRepair.Resolved) {
        $startLockInfo = Get-YurunaPrivateStatePath -Name ("status-service.{0}.start.lock" -f (Get-StatusRuntimeKey -RuntimeDir $RuntimeDir)) -ServedRoot $ServedRootSet
    }
}
if ($startLockInfo -and $startLockInfo.Resolved) {
    $startLockWaitMs = if ($RefreshSafe) {
        [int][Math]::Min(5000, [Math]::Max(0, (Get-YurunaDeadlineRemainingMs -Deadline $script:RefreshSafeDeadline) - 1000))
    } else { 15000 }
    $startLock = Enter-YurunaSingleFlightLock -Path $startLockInfo.Path -WaitMilliseconds $startLockWaitMs `
        -Metadata @{ purpose = 'status-service-start'; port = $Port }
    if (-not $RefreshSafe -and -not $startLock.Held -and $startLock.Reason -eq 'access-denied') {
        $privateStateRepair = Repair-YurunaStartupPrivateState -ServedRoot $ServedRootSet -AllowPrompt -RepairFileAccess -Confirm:$false
        if ($privateStateRepair.Resolved) {
            $startLock = Enter-YurunaSingleFlightLock -Path $startLockInfo.Path -WaitMilliseconds $startLockWaitMs `
                -Metadata @{ purpose = 'status-service-start'; port = $Port }
        }
    }
    if ($startLock.Held) {
        $script:StatusStartupLock = $startLock
    } elseif ($RefreshSafe) {
        Complete-RefreshSafeStart -Outcome 'admission-busy' -Reason ([string]$startLock.Reason)
    } else {
        $lockFailureReason = if ($privateStateRepair -and -not $privateStateRepair.Resolved) { $privateStateRepair.Reason } else { $startLock.Reason }
        throw [IO.IOException]::new("Status service startup is already in progress or its lock cannot be acquired ($lockFailureReason) at '$($startLockInfo.Path)'; refusing a concurrent start.")
    }
} elseif ($RefreshSafe) {
    $lockReason = if ($startLockInfo) { [string]$startLockInfo.Reason } else { 'resolve-failed' }
    Complete-RefreshSafeStart -Outcome 'invalid-invocation' -Reason "private-state-$lockReason"
} else {
    $lockFailureReason = if ($privateStateRepair -and -not $privateStateRepair.Resolved) { $privateStateRepair.Reason } elseif ($startLockInfo) { $startLockInfo.Reason } else { 'resolve-failed' }
    throw [IO.IOException]::new("Status service startup lock could not be resolved ($lockFailureReason). Start the runner from an interactive terminal to allow any required sudo authentication.")
}

function Save-StatusServiceErrorLog {
    <#
    .SYNOPSIS
        Preserve three bounded generations of listener errors before a launch.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RuntimeDirectory,
        [ValidateRange(1, 10)][int]$Retain = 3,
        [ValidateRange(1024, 16777216)][int]$MaximumBytes = 1MB
    )
    $logNames = @('server.err', 'server.err.old', 'server.stderr')
    # Check every destination before changing any file. A redirected log must
    # never follow a link into an unrelated file, including an archive link.
    foreach ($name in $logNames) {
        foreach ($suffix in @('') + @(1..$Retain | ForEach-Object { ".previous.$_" })) {
            $path = Join-Path $RuntimeDirectory "$name$suffix"
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw [IO.IOException]::new("Status service error log is not a regular file: $path")
                }
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDirectory, 'Preserve status-service error logs')) { return }
    foreach ($name in $logNames) {
        $current = Join-Path $RuntimeDirectory $name
        if (-not (Test-Path -LiteralPath $current)) { continue }
        for ($generation = $Retain; $generation -ge 1; $generation--) {
            $source = if ($generation -eq 1) { $current } else { "$current.previous.$($generation - 1)" }
            if (-not (Test-Path -LiteralPath $source)) { continue }
            $destination = "$current.previous.$generation"
            $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                $inputStream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                try {
                    $count = [int][Math]::Min($MaximumBytes, $inputStream.Length)
                    $null = $inputStream.Seek(-$count, [IO.SeekOrigin]::End)
                    $buffer = [byte[]]::new($count)
                    $read = 0
                    while ($read -lt $count) {
                        $received = $inputStream.Read($buffer, $read, $count - $read)
                        if ($received -eq 0) { throw [IO.IOException]::new("Status service error log changed while preserving it: $source") }
                        $read += $received
                    }
                    [IO.File]::WriteAllBytes($temporary, $buffer)
                } finally { $inputStream.Dispose() }
                [IO.File]::Move($temporary, $destination, $true)
            } finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    # Clear only after every current log has a durable archive. A failed
    # archive leaves all original evidence available for the next attempt.
    foreach ($name in $logNames) {
        $current = Join-Path $RuntimeDirectory $name
        if (Test-Path -LiteralPath $current) { [IO.File]::WriteAllBytes($current, [byte[]]@()) }
    }
}

if ($Restart -and (Test-Path $PidFile)) {
    $oldPid = (Get-Content $PidFile).Trim()
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        if ($proc -and (Test-PidFileIdentity -PidFile $PidFile -Process $proc)) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7d154137c3c42ce0' -Arguments @{ oldPid = "$oldPid" })
            Start-Sleep -Seconds 1
        } elseif ($proc) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_605eb1849fd039c2' -Arguments @{ oldPid = "$oldPid" })
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# --- REGION: Check for an existing server
# See https://yuruna.link/42e5cdfd-003e
$ShaFile = Join-Path $RuntimeDir 'server.sha'

# The refresh-safe start never stops a server. It classifies the pidfile's
# owner and acts only on positive absence: an owned server that answers is
# left running whatever commit it was started from, and anything it cannot
# identify is reported rather than replaced.
function Get-RefreshSafeFrameworkSha {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $seconds = Get-YurunaDeadlineBoundedSeconds -Deadline $script:RefreshSafeDeadline -Ceiling 3 -ReserveMilliseconds 2000
    if (-not $seconds) { return '' }
    $git = Invoke-BoundedNativeCommand -FilePath 'git' -ArgumentList @('-C', $RepoRoot, 'rev-parse', 'HEAD') -TimeoutSeconds $seconds
    if (-not (Test-BoundedNativeResultComplete -Result $git) -or [int]$git.ExitCode -ne 0) { return '' }
    $value = ([string]$git.StdOut).Trim()
    if ($value -cmatch '^[0-9a-f]{40}$') { return $value }
    return ''
}
if ($RefreshSafe) {
    # The process-identity classifier reads the process table once and can
    # confirm the owner by the generated script its command line names. Best
    # effort: without it the pidfile falls back to Test-PidFileIdentity (a
    # PowerShell process that predates the pidfile). -Global without -Force,
    # like the imports above.
    if (-not (Get-Command -Name 'Get-YurunaRunnerRecordState' -ErrorAction SilentlyContinue)) {
        try {
            Import-Module (Join-Path $ModulesDir 'Test.SingleInstance.psm1') -Global -DisableNameChecking -ErrorAction Stop
        } catch { Write-Verbose "process-identity classifier unavailable: $($_.Exception.Message)" }
    }
    $ownership = Get-StatusServerOwnership -PidFile $PidFile -ExpectedScriptPath (Join-Path $RuntimeDir '.status-service.ps1')
    switch -CaseSensitive ($ownership.State) {
        'AliveOwned' {
            $answers = $false
            $probeSeconds = Get-YurunaDeadlineBoundedSeconds -Deadline $script:RefreshSafeDeadline -Ceiling 3 -ReserveMilliseconds 1000
            if ($probeSeconds) {
                try {
                    $null = Invoke-WebRequest -Uri "http://localhost:$Port/status/" -TimeoutSec $probeSeconds -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
                    $answers = $true
                } catch { Write-Verbose "refresh-safe probe of the owned server did not answer: $($_.Exception.Message)" }
            }
            if (-not $answers) {
                Complete-RefreshSafeStart -Outcome 'existing-unresponsive' -ProcessId $ownership.Pid -StartTimeUnixMs $ownership.StartTimeUnixMs -Reason 'status-unanswered'
            }
            $currentSha = Get-RefreshSafeFrameworkSha
            $persistedSha = ''
            try { if (Test-Path -LiteralPath $ShaFile) { $persistedSha = ([System.IO.File]::ReadAllText($ShaFile)).Trim() } } catch { $persistedSha = '' }
            $shaMatches = if ($currentSha -and $persistedSha) { [string]::Equals($currentSha, $persistedSha, [StringComparison]::Ordinal) } else { $null }
            Complete-RefreshSafeStart -Outcome 'existing-ready' -ProcessId $ownership.Pid -StartTimeUnixMs $ownership.StartTimeUnixMs `
                -Sha $persistedSha -ShaMatches $shaMatches -Reason ([string]$ownership.Reason)
        }
        'AliveOther' { Complete-RefreshSafeStart -Outcome 'unknown-owner' -ProcessId $ownership.Pid -Reason ([string]$ownership.Reason) }
        'Unknown' { Complete-RefreshSafeStart -Outcome 'unknown-owner' -ProcessId $ownership.Pid -Reason ([string]$ownership.Reason) }
    }
}
if (-not $RefreshSafe -and (Test-Path $PidFile)) {
    $oldPid = (Get-Content $PidFile).Trim()
    $serverAlive = $false
    if ($oldPid) {
        $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
        # Confirm identity -- a PowerShell process that predates the pidfile --
        # not merely the process name: on a long-uptime host the OS can recycle
        # this PID onto an unrelated process, and force-killing it (below, when
        # the port does not answer) would take down whatever now owns the PID
        # (e.g. the freshly-launched outer runner after a reboot).
        if ($proc -and (Test-PidFileIdentity -PidFile $PidFile -Process $proc)) {
            try {
                # Probe the SAME url as the readiness wait below. status.json is
                # served from the runtime dir (/runtime/status.json), so a probe of
                # /status.json 404s against a perfectly healthy server -- which
                # reads here as dead, force-kills it, and relaunches on every call,
                # making the compare-and-skip below unreachable.
                $null = Invoke-WebRequest -Uri "http://localhost:$Port/status/" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
                $serverAlive = $true
            } catch {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_804eb754aac66717' -Arguments @{ oldPid = "$oldPid"; port = "$Port" })
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 1
            }
        }
    }
    if ($serverAlive) {
        $currentSha = $null
        try {
            $currentSha = (& git -C $RepoRoot rev-parse HEAD 2>$null | Out-String).Trim()
        } catch { Write-Verbose "server.sha probe: git rev-parse failed: $($_.Exception.Message)" }
        $persistedSha = $null
        if (Test-Path -LiteralPath $ShaFile) {
            try { $persistedSha = (Get-Content -LiteralPath $ShaFile -Raw).Trim() } catch { Write-Verbose "server.sha read failed: $($_.Exception.Message)" }
        }
        if ($currentSha -and $persistedSha -and ($currentSha -eq $persistedSha)) {
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0c4975f10de7b90a' -Arguments @{ oldPid = "$oldPid"; port = "$Port"; length = "$($currentSha.Substring(0,[Math]::Min(12,$currentSha.Length)))" })
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1ab8b41c49078fda')
            Exit-StatusServiceStartupLock
            exit 0
        }
        # See https://yuruna.link/42e5cdfd-003f
        $restartMessage = if (-not $currentSha) {
            Format-YurunaOperatorMessage -Key 'runner.status_restart_unknown_head' -Arguments @{ processId = $oldPid }
        } elseif (-not $persistedSha) {
            Format-YurunaOperatorMessage -Key 'runner.status_restart_missing_pin' -Arguments @{ processId = $oldPid }
        } else {
            Format-YurunaOperatorMessage -Key 'runner.status_restart_changed_head' -Arguments @{ processId = $oldPid; previous = $persistedSha; current = $currentSha }
        }
        Write-Output $restartMessage
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# See https://yuruna.link/42e5cdfd-003f
if ($RefreshSafe) {
    if (-not (Test-PortListenerFree -Port $Port -BudgetMs 0)) {
        if (Test-PortPrivilegeBlocked -Port $Port) {
            Complete-RefreshSafeStart -Outcome 'port-privilege-required' -Reason 'wildcard-reservation-refused'
        }
        Complete-RefreshSafeStart -Outcome 'port-conflict' -Reason 'port-held'
    }
    $portResolution = [pscustomobject]@{ Status = 'Free'; Message = '' }
} else {
    $portResolution = Resolve-PortOrphan -Port $Port -PidFile $PidFile -Elevate -Confirm:$false
}
# 'PrivilegeRequired' refuses for the same reason a conflict does -- this process
# cannot bind the wildcard prefix, and neither can the server -- but the port is
# EMPTY, so it must not be reported as one that is in use. Handled with Conflict
# so a new status can never fall through this gate and start a blind cycle; only
# the banner and the thrown message differ.
if ($portResolution.Status -eq 'Conflict' -or $portResolution.Status -eq 'PrivilegeRequired') {
    foreach ($line in ($portResolution.Message -split "`n")) { Write-Warning $line.TrimEnd() }
    # See https://yuruna.link/42e5cdfd-003f
    $reason = if ($portResolution.Status -eq 'PrivilegeRequired') {
        "Status-service port $Port is free, but this process may not reserve http://*:$Port/ (needs elevation, or a netsh urlacl); refusing to start."
    } else {
        "Status-service port $Port is held by another process; refusing to start."
    }
    $conflict = [System.InvalidOperationException]::new($reason)
    $conflict.Data['YurunaPortConflict'] = $true
    $conflict.Data['YurunaPort'] = $Port
    $conflict.Data['YurunaPortStatus'] = $portResolution.Status
    Exit-StatusServiceStartupLock
    throw $conflict
}

# --- REGION: Ensure repoUrl is set in status.json
$StatusFile = Join-Path $RuntimeDir "status.json"
# Not in the refresh-safe start: status.json belongs to the running cycle,
# and a refresh never rewrites it.
if (-not $RefreshSafe -and (Test-Path $StatusFile)) {
    try {
        $statusDoc = Get-Content -Raw $StatusFile | ConvertFrom-Json
        $configPath = Join-Path $TestRoot "test.config.yml"
        $config = $null
        if (Test-Path $configPath) {
            try { $config = Get-Content -Raw $configPath | ConvertFrom-Yaml -Ordered } catch { Write-Verbose "Could not parse test.config.yml: $_" }
        }
        $repoUrl = $null
        if ($config -and $config.repositories -and $config.repositories.frameworkUrl) { $repoUrl = $config.repositories.frameworkUrl }
        if (-not $repoUrl -and $statusDoc.repoUrl) { $repoUrl = $statusDoc.repoUrl }
        if (-not $repoUrl) {
            $remote = & git -C $RepoRoot remote get-url origin 2>$null
            if ($LASTEXITCODE -eq 0 -and $remote) {
                $repoUrl = [string]$remote
            } else {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_c60b9cd85c0b5307' -Arguments @{ remote = 'unavailable' })
            }
        }
        if ($repoUrl) {
            if (-not (Get-Command Resolve-GitRemoteLink -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $ModulesDir 'Test.HostGit.psm1') -DisableNameChecking -ErrorAction Stop
            }
            $repoUrl = (Resolve-GitRemoteLink -Url ([string]$repoUrl)).Url
        }
        if ([string]$statusDoc.repoUrl -cne [string]$repoUrl) {
            if ($statusDoc.PSObject.Properties['repoUrl']) {
                $statusDoc.repoUrl = $repoUrl
            } else {
                $statusDoc | Add-Member -NotePropertyName 'repoUrl' -NotePropertyValue $repoUrl
            }
            # See https://yuruna.link/42e5cdfd-0040
            $statusJson = $statusDoc | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($StatusFile, $statusJson, [System.Text.UTF8Encoding]::new($false))
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d930446c8044b6fe' -Arguments @{ repoUrl = "$repoUrl" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d697f222c6bc539a' -Arguments @{ value = "$_" })
    }
}

# --- REGION: Clean up leftovers from older layouts
# See https://yuruna.link/42e5cdfd-0040
if (-not $RefreshSafe) {
    Remove-Item (Join-Path $StatusDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $RuntimeDir 'server.heartbeat') -Force -ErrorAction SilentlyContinue
    $LegacyTrackDir = Join-Path $StatusDir 'track'
    foreach ($legacyName in @('server.pid','runner.pid','status.json','server.err','current-action.json',
                              'control.pause','control.step-pause','control.cycle-pause','.status-service.ps1')) {
        Remove-Item (Join-Path $StatusDir       $legacyName) -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $LegacyTrackDir  $legacyName) -Force -ErrorAction SilentlyContinue
    }
    # Drop the entire legacy test/status/track/ tree if it survives a
    # checkout upgrade (perf data now lives under status/perf/, runtime
    # state under status/runtime/, extension event logs under
    # status/extension/...; the old folder is no longer .gitignored).
    if (Test-Path -LiteralPath $LegacyTrackDir) {
        Remove-Item -LiteralPath $LegacyTrackDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Stale break-active sidecar / continue flag from a previous run that crashed
    # mid-break: clear them so the UI doesn't render a Continue button against a
    # break that no longer exists, and the next break doesn't auto-resume on the
    # first poll tick.
    Remove-Item (Join-Path $RuntimeDir 'break-active.json')      -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $RuntimeDir 'control.break-continue') -Force -ErrorAction SilentlyContinue
}

# --- REGION: Enumerate host IPs -> $env:YURUNA_RUNTIME_DIR/ipaddresses.txt
# See https://yuruna.link/42e5cdfd-0041
$IpAddressesFile = Join-Path $RuntimeDir "ipaddresses.txt"
try {
    $collectedAddresses = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        ForEach-Object { $_.Address } |
        Where-Object { -not [System.Net.IPAddress]::IsLoopback($_) }

    $ipv4 = @($collectedAddresses |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        ForEach-Object { $_.ToString() } |
        Sort-Object -Unique)
    $ipv6 = @($collectedAddresses |
        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6 } |
        ForEach-Object { $_.ToString() } |
        Sort-Object -Unique)
    # Kept for the service marker further down. Resolving the machine name
    # instead answers with the /etc/hosts loopback alias on Debian-family
    # systems -- 127.0.1.1 is a real answer and reaches nobody.
    $script:PrimaryIpv4 = if ($ipv4.Count -gt 0) { $ipv4[0] } else { '' }

    if ($ipv4.Count -eq 0 -and $ipv6.Count -eq 0) {
        $fileContent = "No IP addresses detected"
        $reportCount = 0
    } else {
        $lines = @()
        if ($ipv4.Count -gt 0) { $lines += ($ipv4 -join ',') }
        if ($ipv6.Count -gt 0) { $lines += ($ipv6 -join ',') }
        # LF not CRLF -- UI splits on \n; single line terminator avoids
        # \r leaking into rendered strings.
        $fileContent = ($lines -join "`n")
        $reportCount = $ipv4.Count + $ipv6.Count
    }
    # UTF-8 without BOM so a browser fetch() yields a clean string.
    [System.IO.File]::WriteAllText($IpAddressesFile, $fileContent, [System.Text.UTF8Encoding]::new($false))
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e009e767fbf24bd9' -Arguments @{ reportCount = "$reportCount"; ipAddressesFile = "$IpAddressesFile" })
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_da36587ee2ba9291' -Arguments @{ value = "$_" })
    # Best-effort: leave a previous file intact.
}

# --- REGION: Detect host type
# $detectedHost is captured at parent startup and threaded into the
# detached server's here-string (as $serverHostType) so the per-host
# folder lookup at /control/guest-folders can find host/<short>/guest.*.
$detectedHost = ''
try {
    # Test.HostContract imported by the StatusService kind at file top; Get-HostType
    # is resolvable here without a redundant Import-Module call.
    $detectedHost = Get-HostType
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8028cfa409a3186a' -Arguments @{ value = "$_" })
}

# --- REGION: Announce the forwarder teardown's sudo
# See https://yuruna.link/42e5cdfd-0042
if ($IsMacOS -and -not $RefreshSafe) {
    $forwarderStateDir = Join-Path $HOME 'yuruna/image/caching-proxy-service'
    $hasRootForwarder  = $false
    $meIsRoot          = $false
    try { $meIsRoot = ((& '/usr/bin/id' -u) -eq '0') } catch { Write-Verbose "id -u check failed, assuming non-root: $_" }
    if (-not $meIsRoot -and (Test-Path $forwarderStateDir)) {
        foreach ($pf in (Get-ChildItem -LiteralPath $forwarderStateDir -Filter 'forwarder.*.pid' -File -ErrorAction SilentlyContinue)) {
            $fp = (Get-Content $pf.FullName -Raw).Trim()
            if ($fp -as [int]) {
                $owner = "$(& '/bin/ps' -p $fp -o 'user=' 2>$null)".Trim()
                if ($owner -eq 'root') { $hasRootForwarder = $true; break }
            }
        }
    }
    if ($hasRootForwarder) {
        # See https://yuruna.link/42e5cdfd-0043
        if ($env:YURUNA_NONINTERACTIVE -eq '1') {
            & sudo -n -v 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_forwarder_sudo_unavailable')
            }
        } else {
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c369c06124066bbe')
            & sudo -v
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "  sudo -v failed -- the root-owned forwarder may not be stopped cleanly."
            }
        }
    }
}

# --- REGION: Probe proxy cache -> $env:YURUNA_RUNTIME_DIR/caching-proxy-service.txt
# See https://yuruna.link/42e5cdfd-0044
$CachingProxyServiceFile = Join-Path $RuntimeDir "caching-proxy-service.txt"
try {
    if ($RefreshSafe) {
        # The probe loads the host driver and rewrites the host-wide port map
        # under the caching-proxy lock; a refresh-safe start changes neither
        # and keeps the banner the last full start wrote.
        Write-Verbose 'Refresh-safe start: caching-proxy probe and port map left as they are.'
    } elseif ($detectedHost) {
        # -Global: this script is &-invoked from the inner cycle runner (a module
        # context), where a -Force import without -Global pulls the host contract
        # out of the global table for foreign modules (the legacy-eviction
        # regression class) -- a contract call made later from Invoke-Sequence
        # would then fail to resolve.
        Import-Module (Join-Path $ModulesDir 'Test.HostContract.psm1') -Force -Global
        [void](Initialize-YurunaHost -RepoRoot (Split-Path -Parent $TestRoot) -HostType $detectedHost)
        # Re-import: Initialize-YurunaHost evicts this script's view of Test.CachingProxyService.
        # See https://yuruna.link/42aaf735-0006
        Import-Module (Join-Path $ModulesDir 'Test.CachingProxyService.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        # The port-map block below writes the same host-wide netsh/forwarder
        # state the runner and a caching-proxy-service bring-up write, so it
        # must take the same lock they take. Not part of the StatusService
        # entry-point module set (that set covers the probe, not the write),
        # so it is imported here next to its only consumer.
        Import-Module (Join-Path $ModulesDir 'Test.CachingProxyServiceLock.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        # See https://yuruna.link/42e5cdfd-0044
        $configuredCacheIp = ''
        if (-not $Env:YURUNA_CACHING_PROXY_SERVICE_IP) {
            try {
                $proxyConfigPath = Join-Path $TestRoot 'test.config.yml'
                if (Test-Path -LiteralPath $proxyConfigPath) {
                    $proxyConfig = Get-Content -Raw $proxyConfigPath | ConvertFrom-Yaml -Ordered
                    if ($proxyConfig.vmStart -and $proxyConfig.vmStart.cachingProxyIp) {
                        $configuredCacheIp = "$($proxyConfig.vmStart.cachingProxyIp)".Trim()
                    }
                }
            } catch { Write-Verbose "Could not read vmStart.cachingProxyIp for the caching-proxy banner: $_" }
            if ($configuredCacheIp -and (Get-Command Resolve-CachingProxyServiceEndpoint -ErrorAction SilentlyContinue)) {
                try {
                    $resolvedCacheEndpoint = Resolve-CachingProxyServiceEndpoint -EnvIp '' -ConfigIp $configuredCacheIp
                    if ($resolvedCacheEndpoint.EffectiveIp) {
                        $Env:YURUNA_CACHING_PROXY_SERVICE_IP = $resolvedCacheEndpoint.EffectiveIp
                    }
                } catch { Write-Verbose "Caching-proxy endpoint resolution failed for the banner: $_" }
            }
        }
        $cachingProxyUrl = Test-CachingProxyServiceAvailable -Quiet
        if ($cachingProxyUrl) {
            # See https://yuruna.link/42e5cdfd-0044
            $cachingProxyContent = $null
            $mapOk = $false
            $bestIp = $null
            $isExternal = [bool]$Env:YURUNA_CACHING_PROXY_SERVICE_IP
            if ($isExternal) {
                $externUrlIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                # See https://yuruna.link/42e5cdfd-0044
                if ($externUrlIp -and ((Get-HostOwnIpVerdict -IpAddress $externUrlIp) -ne 'nonlocal')) {
                    $isExternal = $false
                }
            }
            # See https://yuruna.link/42e5cdfd-0044
            $portMapDeferred = $false
            $cpPortLock = if (Get-Command Enter-CachingProxyServiceLock -ErrorAction SilentlyContinue) {
                Enter-CachingProxyServiceLock -RuntimeDir $RuntimeDir -Role 'portmap' -TimeoutSeconds 0
            } else { @{ Acquired = $true; PidPath = $null } }
            if (-not $cpPortLock.Acquired) {
                $portMapDeferred = $true
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_6e9385fec86f1e3d')
            } else {
                try {
                if ($isExternal) {
                    # Remote serves its own ports; surface the remote IP
                    # in the dashboard link. Clear any stale local
                    # mapping from a prior local-cache cycle.
                    [void](Remove-PortMap -Confirm:$false)
                    $bestIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                    $mapOk = [bool]$bestIp
                } else {
                    # See https://yuruna.link/42e5cdfd-0044
                    if ($IsMacOS) {
                        $vmIp = $null
                        $candidate = (Read-CachingProxyServiceState).ipAddress
                        if ($candidate -and (Test-IpAddress $candidate)) { $vmIp = $candidate }
                    } else {
                        $vmIp = if ($cachingProxyUrl -match '^http://([0-9.]+):') { $matches[1] } else { $null }
                        if ($vmIp -and (Test-HostOwnIpAddress -IpAddress $vmIp)) {
                            # Own-address URL (locally-owned cache fronted
                            # by this host's forwarders): the port-map
                            # target must be the cache VM's real IP, never
                            # the host address fronting it (self-loop).
                            $stateVmIp = Get-CachingProxyServiceVmIp
                            if ($stateVmIp) { $vmIp = $stateVmIp }
                        }
                    }
                    # See https://yuruna.link/42e5cdfd-0044
                    $cacheOnExternalSwitch = [bool](Test-CacheVMOnExternalNetwork)
                    if ($cacheOnExternalSwitch) {
                        [void](Remove-PortMap -Confirm:$false)
                        $mapOk = $true
                        $bestIp = $vmIp
                    } elseif ($vmIp -and (Test-HostOwnIpAddress -IpAddress $vmIp)) {
                        # The target resolved no further than one of this
                        # host's own addresses: a forwarder aimed there
                        # would loop each port back onto its own listener.
                        # Keep the port map that is currently serving
                        # traffic instead of replacing it with a loop.
                        $mapOk = $true
                        $bestIp = Get-BestHostIp
                        if (-not $bestIp) { $bestIp = $vmIp }
                    } else {
                        # See https://yuruna.link/42e5cdfd-0044
                        $cacheHttpPort  = Get-CachingProxyServicePort -Scheme http
                        $cacheHttpsPort = Get-CachingProxyServicePort -Scheme https
                        # See https://yuruna.link/42e5cdfd-0044
                        $squidPorts = if ($IsMacOS) { @(80, 3000) } else { Get-CachingProxyServiceExposedPort -HttpPort $cacheHttpPort -HttpsPort $cacheHttpsPort }
                        if ($vmIp) {
                            $portMapArgs = @{
                                VMIp = $vmIp
                                Port = $squidPorts
                                PortRemap = @{ 8022 = 22 }
                            }
                            if ($IsMacOS) {
                                $portMapArgs.PortRemap[$cacheHttpPort]  = 3138
                                $portMapArgs.PortRemap[$cacheHttpsPort] = 3139
                                $portMapArgs.ProxyProtocolPort          = @($cacheHttpPort, $cacheHttpsPort)
                            }
                            $mapResult = Add-PortMap @portMapArgs -Confirm:$false
                            $mapOk = [bool]$mapResult
                        }
                        if ($mapOk) {
                            $bestIp = Get-BestHostIp
                            if (-not $bestIp) { $bestIp = $vmIp }  # routable-iface fallback
                        }
                    }
                }
                } finally {
                    if (Get-Command Exit-CachingProxyServiceLock -ErrorAction SilentlyContinue) { [void](Exit-CachingProxyServiceLock -Handle $cpPortLock) }
                }
            }
            if ($portMapDeferred) {
                $cachingProxyContent = '<span data-i18n="status.cache_caching_proxy_service_detected_port_map_owned_by_a_bri_e1fa0937">Caching-proxy service: detected (port map owned by a bring-up)</span>'
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_05564109830bf14c' -Arguments @{ cachingProxyServiceFile = "$CachingProxyServiceFile" })
            } elseif ($mapOk) {
                # See https://yuruna.link/42e5cdfd-0044
                $dashboardUrl = "http://${bestIp}"
                $cachingProxyContent = '<span data-i18n="status.cache_caching_proxy_service_306beb37">Caching-proxy service:</span> <a data-i18n="status.cache_detected_b96da48a" href="' + $dashboardUrl + '" target="_blank">detected</a>'
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8b6ee3aa9ee2accc' -Arguments @{ dashboardUrl = "$dashboardUrl"; cachingProxyServiceFile = "$CachingProxyServiceFile" })
            } else {
                $cachingProxyContent = '<span data-i18n="status.cache_caching_proxy_service_detected_port_map_failed_28a5d3cf">Caching-proxy service: detected (port map failed)</span>'
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7b24fa88b4b5c43b' -Arguments @{ cachingProxyServiceFile = "$CachingProxyServiceFile" })
            }
        } elseif ($configuredCacheIp) {
            # A cache IS configured and did not answer. That is a different
            # report from "this host has no cache", and conflating the two sends
            # the reader to the configuration when the configuration is right and
            # the cache is down -- or unreachable from here.
            $cachingProxyContent = '<span data-i18n="status.cache_caching_proxy_service_configured_at_address_not_answer_df71d10d" data-i18n-args="' + [System.Net.WebUtility]::HtmlEncode((@{ address = $configuredCacheIp } | ConvertTo-Json -Compress)) + '">Caching-proxy service: configured at ' + [System.Net.WebUtility]::HtmlEncode($configuredCacheIp) + ', not answering</span>'
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d1a8b606d415b200' -Arguments @{ configuredCacheIp = "$configuredCacheIp"; cachingProxyServiceFile = "$CachingProxyServiceFile" })
        } else {
            $cachingProxyContent = '<span data-i18n="status.cache_caching_proxy_service_not_detected_eeb2edfb">Caching-proxy service: not detected</span>'
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4e4329f6b3a6f23d' -Arguments @{ cachingProxyServiceFile = "$CachingProxyServiceFile" })
        }
        [System.IO.File]::WriteAllText($CachingProxyServiceFile, $cachingProxyContent, [System.Text.UTF8Encoding]::new($false))
    } else {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_aabcbb7e32e7daf7')
    }
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8de82fa7556a6dc9' -Arguments @{ value = "$_" })
    # Best-effort: leave a previous file intact if there was one.
}

# Host guest-network state (runtime/host-network.*) is served here and written
# only by the runner's cycle-start gate.
# See https://yuruna.link/42e5cdfd-0044

# --- REGION: Launch the server as a detached process
# Where the detached workers' entry points resolve from. Always the
# repository in production; a test that expands this template itself can
# point it at stand-ins without changing what the server serves.
$StatusWorkerRoot = $RepoRoot
# Baked unconditionally: the port and repoUrl paths above only resolved the
# config path on some branches, and a server baked with an empty path reads
# its watchdog bounds from no file.
$ServerConfigPath = Join-Path $TestRoot 'test.config.yml'
$serverScript = @"
`$ErrorActionPreference = 'Stop'
`$listener = [System.Net.HttpListener]::new()
`$listener.Prefixes.Add('http://*:$Port/')
`$statusDir = '$($StatusDir -replace "'","''")'
`$runtimeDir  = '$($RuntimeDir  -replace "'","''")'
`$logDir    = '$($LogDir    -replace "'","''")'
`$repoRoot  = '$($RepoRoot  -replace "'","''")'
# Test-IpAddress and Get-CachingProxyServicePort are used to validate
# vmStart.cachingProxyIp at save time in /control/test-config. Detached
# server runspace is fresh -- import the module that exports them.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Invoke-CachingProxyServiceProbe (used by /control/test-caching-proxy-service) lives in
# Test.CachingProxyService.psm1. The parent process imports it for its startup
# probe, but the detached child has its own fresh runspace.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Read-TestConfig (mtime+hash cached YAML parse) for the test-config GET
# and perf-aggregates handlers. Same cache the runner uses, so an
# operator edit to test.config.yml is observed on the very next handler
# call without restarting the server.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Config.psm1')      -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.ConfigSync.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction Stop
Import-Module (Join-Path `$repoRoot 'test/modules/Test.PerfAggregate.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction Stop
# Status negotiation uses the same canonical-tag, alias, qvalue and
# provenance implementation as every command/service boundary. The page then
# narrows only the supported set to the catalog assets it actually ships.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Locale.psm1')      -Force -DisableNameChecking -Verbose:`$false -ErrorAction Stop
# Directory listings and localized plain-text errors are generated by this
# PowerShell service rather than by the browser, so they use the same compiled
# status catalog and typed number formatter as other PowerShell surfaces.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Catalog.psm1')     -Force -DisableNameChecking -Verbose:`$false -ErrorAction Stop
# Get-PoolStorageServerName (used by /control/host-aliases) shares the
# networkStorage path grammar with the mount code, so the alias endpoint
# and the mount can never disagree on which token is the server name.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.PoolStorage.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Test-ConfigSyncProof / Protect-ConfigSyncCredential (used by
# /control/vault-credential) live with their client-side counterparts in
# one module so the two ends of the shared-token envelope cannot drift.
# Test.Extension supplies Import-Extension for the lazy authentication-
# extension load inside that route.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.ConfigServiceSync.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.Extension.psm1')      -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Get-RunnerInstanceState is the single tested implementation of the
# runner PID + StartTime-sidecar identity check; the runner-status and
# start-cycle handlers call it via Test-RunnerAlive below instead of
# each re-deriving that logic. This detached server has its own runspace,
# so the module must be imported here for the command to resolve.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.SingleInstance.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Get-HostStorageFact answers /control/host-facts' storage figures. It lives
# in a module because the counting rule it implements -- one figure per space
# pool, permanent devices only -- is platform-specific enough to be worth
# testing directly, which a handler body baked into this here-string is not.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.HostFacts.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# Unix hosts expose native memory gauges on this listener, using bounded
# reads instead of requiring a second daemon and firewall port.
Import-Module (Join-Path `$repoRoot 'test/modules/Test.HostMemoryMetrics.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# See https://yuruna.link/42e5cdfd-0045
Import-Module (Join-Path `$repoRoot 'test/modules/Test.StateFile.psm1')          -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.SingleFlightLock.psm1')   -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.CriticalRecord.psm1')     -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.InnerSpawn.psm1')         -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.HostRefreshIntent.psm1')  -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.HostRefresh.psm1')        -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
Import-Module (Join-Path `$repoRoot 'test/modules/Test.StatusControlRoute.psm1') -Force -DisableNameChecking -Verbose:`$false -ErrorAction SilentlyContinue
# --- REGION: Secret file policy
# See https://yuruna.link/42185271-000d
# File and archive routes share these shapes, including derived secret files.
`$secretNameShapes = @('*.snapshot.json', '*.snapshot.*.json', '*.backup', '*.bak', '*.tmp',
    'host-refresh/*', '*/host-refresh/*', '*host-refresh.journal*', '*host-refresh.request*',
    '*host-refresh.lock', '*host-refresh.admission.lock', '*.record', '*.record.prev',
    '*.handshake.json', '*.hop.json', '*.ack.json', '*.key', '*.credential', '*.cred', '*.pfx', '*.p12',
    '*-key', '*_key', '*_rsa', '*_ecdsa', '*_ed25519', '*_dsa', '*.ppk',
    'host-config-ca', 'host-config-ca/*', '*/host-config-ca', '*/host-config-ca/*')
`$stepPauseFile  = Join-Path `$runtimeDir 'control.step-pause'
`$cyclePauseFile = Join-Path `$runtimeDir 'control.cycle-pause'
# The lab hold is machine-initiated, not an operator pause: the cycle's
# lab-health gate raises it while a service the host had been reaching is away.
# The service only ever CLEARS it (start-cycle) or hands the gate a release
# request; raising one from here would park a cycle on a verdict nothing probed.
`$labHoldFile        = Join-Path `$runtimeDir 'control.lab-hold'
`$labHoldSidecarFile = Join-Path `$runtimeDir 'lab-hold.json'
`$labHoldReleaseFile = Join-Path `$runtimeDir 'control.lab-hold-release'
`$statusJsonFile = Join-Path `$runtimeDir 'status.json'
`$serverLogFile  = Join-Path `$runtimeDir 'server.err'
# `$serverHostType is the parent-detected host type baked into the
# detached server's here-string. Used by /control/guest-folders to list
# guests under host/<short>/.
`$serverHostType = '$detectedHost'
# Baked in like `$serverHostType above: the detached server has its own runspace
# and never inherits the parent's locals. /control/runner-status reads the live
# watchdog bounds (testCycle.stepTimeoutSeconds / preambleTimeoutSeconds) from
# here so its liveness verdict matches what the watchdog will actually enforce.
`$serverConfigPath = '$($ServerConfigPath -replace "'","''")'
# Detached worker entry points and the scripts they run, baked like the paths
# above. A test that expands this template can point the worker root at
# stand-ins; the server itself always serves `$repoRoot.
`$workerRoot = '$($StatusWorkerRoot -replace "'","''")'
`$hostRefreshEntry        = Join-Path `$workerRoot 'test/lab/Invoke-HostRefresh.ps1'
`$hostDiagnosticWorker    = Join-Path `$workerRoot 'test/modules/Invoke-HostDiagnosticWorker.ps1'
`$startCycleWorker        = Join-Path `$workerRoot 'test/modules/Invoke-StartCycleWorker.ps1'
`$diagScriptPath          = Join-Path `$workerRoot 'automation/Get-SystemDiagnostic.ps1'
`$startCycleCleanupScript = Join-Path `$workerRoot 'test/Remove-TestVMFiles.ps1'
`$startCycleRunnerScript  = Join-Path `$workerRoot 'test/Start-TestRunner.ps1'
`$hostRefreshStateUrl     = '/runtime/host-refresh.state.json'
`$startCycleStateUrl      = '/runtime/start-cycle.state.json'
# What the private state root must never be inside of: everything this
# server hands out.
`$servedRootSet = @(`$repoRoot, `$statusDir, `$runtimeDir, `$logDir)
# See https://yuruna.link/42e5cdfd-0045
function Write-ServerErr {
    param([string]`$msg)
    try {
        foreach (`$path in @(`$serverLogFile, "`$serverLogFile.old")) {
            if (Test-Path -LiteralPath `$path) {
                `$item = Get-Item -LiteralPath `$path -Force
                if (`$item.PSIsContainer -or (`$item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }
            }
        }
        if ((Test-Path -LiteralPath `$serverLogFile) -and ((Get-Item -LiteralPath `$serverLogFile).Length -gt 1MB)) {
            Move-Item -LiteralPath `$serverLogFile -Destination "`$serverLogFile.old" -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath `$serverLogFile -Value "[`$(Get-Date -Format o)] `$msg" -ErrorAction SilentlyContinue
    } catch { Write-Debug `$_ }
}
# See https://yuruna.link/42e5cdfd-0045
function Resolve-PageLocale {
    param([string]`$AcceptLanguage, [AllowEmptyString()][string]`$ConfigLanguage)

    # Read the lab-wide lock at the request boundary so an operator edit takes
    # effect without restarting this detached service. Tests bind the parameter
    # explicitly to exercise the emitted resolver without reading their host's
    # config; production calls omit it and use the validated shared reader.
    if (-not `$PSBoundParameters.ContainsKey('ConfigLanguage')) {
        `$ConfigLanguage = ''
        try {
            `$localeConfig = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml')
            if (`$localeConfig) {
                `$ConfigLanguage = [string](Get-TestConfigValue -Config `$localeConfig -Path 'language')
            }
        } catch {
            Write-Verbose "Status locale config read failed: `$(`$_.Exception.Message)"
        }
    }

    `$baseManifest = Get-LocaleManifest
    `$supported = @(`$baseManifest.Supported)
    if (`$env:YURUNA_ALLOW_PSEUDO_LOCALE -in @('1', 'true')) {
        `$supported += @('qps-Ploc', 'qps-Plocm')
    }
    `$pageManifest = @{
        Default = `$baseManifest.Default
        Supported = `$supported
        Aliases = `$baseManifest.Aliases
        Direction = `$baseManifest.Direction
        MaxTagLength = `$baseManifest.MaxTagLength
        MaxHeaderLength = `$baseManifest.MaxHeaderLength
    }
    `$context = New-LocaleContext -ConfigLanguage "`$ConfigLanguage" -AcceptLanguage "`$AcceptLanguage" -ProcessCulture '' -Manifest `$pageManifest
    return @{
        Tag = [string]`$context.ResolvedTag
        RequestedTag = [string]`$context.RequestedTag
        Direction = [string]`$context.Direction
        Source = [string]`$context.Source
    }
}

# Add the selected generated catalog while the document parser is still
# loading. English is already embedded in yuruna.common.js; pseudo catalogs
# are separate assets so an ordinary page pays no extra request.
function Add-PageLocaleCatalog {
    param([string]`$Html, [string]`$Locale, [string]`$CatalogRoot = `$statusDir)
    if (`$Locale -ceq 'en-US') { return `$Html }
    `$marker = '<script src="yuruna.common.js"></script>'
    if (-not `$Html.Contains(`$marker)) {
        # Transcript and nested report HTML share this generic file route but
        # do not run the status browser runtime. Label their document without
        # injecting a script into a page that has no catalog consumer.
        return `$Html
    }
    `$asset = Get-StatusLocaleCatalogAsset -Locale `$Locale -Root `$CatalogRoot
    if (-not `$asset) { throw "Status page selected `$Locale but its generated catalog is missing." }
    `$catalog = '<script src="/' + `$asset.RequestName + '"></script>'
    return `$Html.Replace(`$marker, `$marker + "`n" + `$catalog)
}

# Materialize the exact localized representation before its validator is
# computed. Hashing the English source bytes would give every locale the same
# ETag and let an If-None-Match for one language suppress another language's
# body with a false 304.
function ConvertTo-LocalizedPageHtml {
    param([string]`$Html, `$Locale, [string]`$CatalogRoot = `$statusDir)

    if (`$null -eq `$Locale -or -not `$Locale.Tag) { return `$Html }
    `$localeTagEnc = [System.Net.WebUtility]::HtmlEncode(`$Locale.Tag)
    `$localeRequestedEnc = [System.Net.WebUtility]::HtmlEncode(`$Locale.RequestedTag)
    `$localeDirectionEnc = [System.Net.WebUtility]::HtmlEncode(`$Locale.Direction)
    `$localeSourceEnc = [System.Net.WebUtility]::HtmlEncode(`$Locale.Source)
    `$localized = `$Html.Replace('<html lang="en">',
        ('<html lang="' + `$localeTagEnc + '" dir="' + `$localeDirectionEnc +
            '" data-yuruna-requested-language="' + `$localeRequestedEnc +
            '" data-yuruna-locale-source="' + `$localeSourceEnc + '">'))
    `$localized = ConvertTo-CatalogHtml -Html `$localized -Locale `$Locale.Tag
    return Add-PageLocaleCatalog -Html `$localized -Locale `$Locale.Tag -CatalogRoot `$CatalogRoot
}

function Get-RepresentationETag {
    param([byte[]]`$Bytes)

    `$sha = [System.Security.Cryptography.SHA256]::Create()
    try { `$digest = `$sha.ComputeHash(`$Bytes) } finally { `$sha.Dispose() }
    `$hex = ([System.BitConverter]::ToString(`$digest)).Replace('-', '').ToLowerInvariant()
    return '"' + `$hex + '"'
}

# Describe a pseudo catalog by immutable request name and by the stable file
# that supplies its bytes. The request name carries the complete SHA-256, so a
# catalog may be cached forever without a rebuilt page ever naming stale bytes.
function Get-StatusLocaleCatalogAsset {
    param([string]`$Locale, [string]`$Root = `$statusDir)

    `$delivered = @((Get-LocaleManifest).Supported) + @('qps-Ploc', 'qps-Plocm')
    if (`$Locale -ceq 'en-US' -or `$Locale -cnotin `$delivered -or -not `$Root) { return `$null }
    `$sourceName = `$Locale + '.status.js'
    `$sourcePath = Join-Path `$Root `$sourceName
    if (-not (Test-Path -LiteralPath `$sourcePath -PathType Leaf)) { return `$null }
    `$bytes = [System.IO.File]::ReadAllBytes(`$sourcePath)
    `$etag = Get-RepresentationETag -Bytes `$bytes
    `$hash = `$etag.Trim('"')
    return @{
        Locale = `$Locale
        SourceName = `$sourceName
        SourcePath = `$sourcePath
        RequestName = `$Locale + '.' + `$hash + '.status.js'
        Bytes = `$bytes
        ETag = `$etag
    }
}

function Test-RepresentationETagMatch {
    param([string]`$Header, [string]`$ETag)

    if (-not `$Header -or -not `$ETag) { return `$false }
    foreach (`$raw in (`$Header -split ',')) {
        `$candidate = `$raw.Trim()
        if (`$candidate -eq '*') { return `$true }
        if (`$candidate.StartsWith('W/', [StringComparison]::OrdinalIgnoreCase)) {
            `$candidate = `$candidate.Substring(2)
        }
        if ([string]::Equals(`$candidate, `$ETag, [StringComparison]::Ordinal)) { return `$true }
    }
    return `$false
}

function Set-ImmutableAssetValidator {
    param(`$Request, `$Response, `$Asset)

    `$Response.Headers.Set('Cache-Control', 'public,max-age=31536000,immutable')
    `$Response.Headers.Set('ETag', [string]`$Asset.ETag)
    if (Test-RepresentationETagMatch -Header `$Request.Headers['If-None-Match'] -ETag `$Asset.ETag) {
        `$Response.StatusCode = 304
        return `$false
    }
    return `$true
}

# Set every locale-dependent header before deciding on 304. RFC 9110 allows
# representation metadata on a not-modified response, and keeping these fields
# is essential here: Content-Language identifies which localized validator
# matched, while Vary prevents a shared cache from reusing that decision for a
# different Accept-Language request.
function Set-LocalizedRepresentationValidator {
    param(`$Request, `$Response, [byte[]]`$Bytes, `$Locale)

    `$etag = Get-RepresentationETag -Bytes `$Bytes
    Set-ResponseLocaleHeaders -Response `$Response -Locale `$Locale
    `$Response.Headers.Set('ETag', `$etag)
    if (Test-RepresentationETagMatch -Header `$Request.Headers['If-None-Match'] -ETag `$etag) {
        `$Response.StatusCode = 304
        # Leave Content-Length unset. A 304 may advertise only the length of
        # the selected representation that a 200 would have carried; zero
        # would describe neither this nonempty page nor an absent body.
        return `$false
    }
    return `$true
}

function Set-ResponseLocaleHeaders {
    param(`$Response, `$Locale)

    `$Response.Headers.Set('Content-Language', [string]`$Locale.Tag)
    `$vary = (@(`$Response.Headers.GetValues('Vary')) -join ',')
    if (`$vary -notmatch '(?i)(?:^|,)\s*Accept-Language\s*(?:,|$)') {
        `$Response.Headers.Add('Vary', 'Accept-Language')
    }
}

function Set-StatusErrorRepresentation {
    param(`$Request, `$Response, [int]`$StatusCode, [string]`$Key, `$Locale)

    `$text = Format-CatalogMessage -Key `$Key -Locale `$Locale.Tag
    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$text)
    `$Response.StatusCode = `$StatusCode
    `$Response.ContentType = 'text/plain; charset=utf-8'
    `$Response.Headers.Set('Cache-Control', 'no-store')
    # A validator still identifies the localized error representation for
    # diagnostics, but conditional 304 applies only to a successful selected
    # representation. Turning a real 404/413 into 304 hides the error itself.
    Set-ResponseLocaleHeaders -Response `$Response -Locale `$Locale
    `$Response.Headers.Set('ETag', (Get-RepresentationETag -Bytes `$bytes))
    `$Response.ContentLength64 = `$bytes.Length
    return @{ Bytes = `$bytes; ShouldWrite = `$true }
}

function ConvertTo-JsonEscapedString {
    param([string]`$s)
    `$s -replace '\\','\\' -replace '"','\"' -replace '[\r\n]+',' '
}
# See https://yuruna.link/42e5cdfd-0045
function ConvertTo-IsoUtcString {
    param(`$Value)
    if (`$null -eq `$Value) { return '' }
    if (`$Value -is [DateTime])       { return ([DateTime]`$Value).ToUniversalTime().ToString('o') }
    if (`$Value -is [DateTimeOffset]) { return ([DateTimeOffset]`$Value).UtcDateTime.ToString('o') }
    return "`$Value"
}
# See https://yuruna.link/42e5cdfd-0045
function Get-StatusMessageBytes {
    param(`$Request, `$Response, [string]`$Key, [hashtable]`$Arguments = @{}, [switch]`$Json)
    `$locale = Resolve-PageLocale -AcceptLanguage `$Request.Headers['Accept-Language']
    Set-ResponseLocaleHeaders -Response `$Response -Locale `$locale
    `$Response.Headers.Set('Cache-Control', 'no-store')
    `$Response.Headers.Set('X-Yuruna-Message-Code', `$Key)
    `$text = Format-CatalogMessage -Key `$Key -Arguments `$Arguments -Locale `$locale.Tag
    `$Response.ContentType = if (`$Json) { 'application/json; charset=utf-8' } else { 'text/plain; charset=utf-8' }
    if (`$Json) { `$text = @{ ok = `$false; code = `$Key; error = `$text } | ConvertTo-Json -Compress }
    return ,([System.Text.Encoding]::UTF8.GetBytes(`$text))
}

function Get-ControlIdentityCached {
    `$vaultDirectory = Join-Path `$repoRoot 'test/status/extension/authentication'
    `$revision = (@('vault.yml', 'users.yml') | ForEach-Object {
        `$file = [IO.FileInfo]::new((Join-Path `$vaultDirectory `$_))
        if (`$file.Exists) { "`$(`$file.LastWriteTimeUtc.Ticks):`$(`$file.Length)" } else { 'absent' }
    }) -join '|'
    if ((Get-Variable -Name ControlIdentityCache -Scope Script -ErrorAction SilentlyContinue) -and `$script:ControlIdentityCache.Revision -ceq `$revision) { return `$script:ControlIdentityCache }
    `$token = ''; `$tag = ''
    if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -and (Import-RouteModule -ModuleRelativePath 'test/modules/Test.Extension.psm1' -RequiredCommand 'Import-Extension')) {
        try { `$null = Import-Extension -Area 'authentication' -RequireSingle } catch { return @{ Token = ''; Tag = '' } }
    }
    if (Get-Command Reset-UsersConfigCache -ErrorAction SilentlyContinue) { Reset-UsersConfigCache -Confirm:`$false }
    if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.ConfigServiceSync.psm1' -RequiredCommand 'Get-YurunaControlTag', 'Test-YurunaControlProof', 'Get-InternalAuthKeyValue') {
        try { `$token = [string](Get-InternalAuthKeyValue); `$tag = [string](Get-YurunaControlTag -Token `$token) } catch { return @{ Token = ''; Tag = '' } }
    }
    if (`$token -and `$tag) { `$script:ControlIdentityCache = @{ Token = `$token; Tag = `$tag; Revision = `$revision }; return `$script:ControlIdentityCache }
    return @{ Token = ''; Tag = '' }
}

function Send-StatusMessage {
    param(`$Request, `$Response, [string]`$Key, [hashtable]`$Arguments = @{}, [switch]`$Json, [switch]`$NoClose)
    `$bytes = Get-StatusMessageBytes -Request `$Request -Response `$Response -Key `$Key -Arguments `$Arguments -Json:`$Json
    `$Response.ContentLength64 = `$bytes.Length
    if (`$Request.HttpMethod -ne 'HEAD') { `$Response.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
    if (-not `$NoClose) { `$Response.OutputStream.Close() }
}

function Send-JsonError {
    param(`$Response, [int]`$StatusCode, [string]`$Json, `$Request,
        [string]`$Key, [hashtable]`$Arguments = @{}, [string]`$Reason)
    if (`$Key) {
        `$locale = Resolve-PageLocale -AcceptLanguage `$Request.Headers['Accept-Language']
        Set-ResponseLocaleHeaders -Response `$Response -Locale `$locale
        `$Response.ContentType = 'application/json; charset=utf-8'
        `$Response.Headers.Set('Cache-Control', 'no-store')
        `$payload = [ordered]@{ ok = `$false; code = `$Key; error = (Format-CatalogMessage -Key `$Key -Arguments `$Arguments -Locale `$locale.Tag) }
        if (`$Reason) { `$payload.reason = `$Reason }
        `$Json = `$payload | ConvertTo-Json -Compress -Depth 4
    }
    `$Response.StatusCode = `$StatusCode
    `$b = [System.Text.Encoding]::UTF8.GetBytes(`$Json)
    `$Response.ContentLength64 = `$b.Length
    if (-not `$Request -or `$Request.HttpMethod -ne 'HEAD') { `$Response.OutputStream.Write(`$b, 0, `$b.Length) }
    `$Response.OutputStream.Close()
}
# Every reply the refresh, start-cycle and diagnostic routes build: the
# caller's identity fields, plus the catalog key and the sentence localized
# for this request when there is one. Close turns keep-alive off, which is
# what ends a connection whose body was never read (or never finished).
function Send-JsonReply {
    param(`$Response, `$Request, [int]`$StatusCode, [System.Collections.IDictionary]`$Body,
        [string]`$MessageKey, [hashtable]`$MessageArguments = @{}, [switch]`$Close, [string]`$RetryAfter)
    `$payload = [ordered]@{ ok = `$false }
    if (`$Body -and `$Body.Contains('ok')) { `$payload['ok'] = [bool]`$Body['ok'] }
    if (`$MessageKey) {
        `$replyLocale = Resolve-PageLocale -AcceptLanguage `$Request.Headers['Accept-Language']
        Set-ResponseLocaleHeaders -Response `$Response -Locale `$replyLocale
        `$payload['code'] = `$MessageKey
        `$payload['error'] = Format-CatalogMessage -Key `$MessageKey -Arguments `$MessageArguments -Locale `$replyLocale.Tag
    }
    if (`$Body) { foreach (`$field in @(`$Body.Keys)) { if (`$field -ne 'ok') { `$payload[`$field] = `$Body[`$field] } } }
    `$payloadBytes = [System.Text.Encoding]::UTF8.GetBytes((`$payload | ConvertTo-Json -Compress -Depth 5))
    `$Response.StatusCode = `$StatusCode
    `$Response.ContentType = 'application/json; charset=utf-8'
    `$Response.Headers.Set('Cache-Control', 'no-store')
    if (`$RetryAfter) { `$Response.Headers.Set('Retry-After', `$RetryAfter) }
    if (`$Close) { `$Response.KeepAlive = `$false }
    `$Response.ContentLength64 = `$payloadBytes.Length
    if (`$Request.HttpMethod -ne 'HEAD') {
        `$Response.OutputStream.Write(`$payloadBytes, 0, `$payloadBytes.Length)
    }
    `$Response.OutputStream.Close()
}
# See https://yuruna.link/42e5cdfd-0045
function Import-RouteModule {
    param(
        [Parameter(Mandatory)][string]`$ModuleRelativePath,
        [Parameter(Mandatory)][string[]]`$RequiredCommand
    )
    `$missing = @(`$RequiredCommand | Where-Object { -not (Get-Command `$_ -ErrorAction SilentlyContinue) })
    if (`$missing.Count -eq 0) { return `$true }
    try {
        Import-Module (Join-Path `$repoRoot `$ModuleRelativePath) -Force -DisableNameChecking -Verbose:`$false -ErrorAction Stop
    } catch {
        Write-ServerErr "route module `$ModuleRelativePath failed to import: `$(`$_.Exception.Message)"
        return `$false
    }
    foreach (`$c in `$RequiredCommand) {
        if (-not (Get-Command `$c -ErrorAction SilentlyContinue)) {
            Write-ServerErr "route module `$ModuleRelativePath imported but does not export '`$c'."
            return `$false
        }
    }
    return `$true
}
# See https://yuruna.link/42e5cdfd-0045
`$script:StatusRouteReady = @{}
function Test-StatusRouteReady {
    param([Parameter(Mandatory)][ValidateSet('host-refresh', 'start-cycle', 'host-diagnostic')][string]`$Route)
    `$checkedAt = [DateTime]::UtcNow
    `$cachedReady = `$script:StatusRouteReady[`$Route]
    if (`$cachedReady -and `$checkedAt -lt `$cachedReady.ValidUntil) { return `$cachedReady }
    `$routeReady = (Import-RouteModule -ModuleRelativePath 'automation/Yuruna.Common.psm1' -RequiredCommand 'New-YurunaDeadline')
    if (`$routeReady) {
        `$routeReady = Import-RouteModule -ModuleRelativePath 'test/modules/Test.StatusControlRoute.psm1' -RequiredCommand 'New-StatusBoundedBodyRead', 'Update-StatusBoundedBodyRead', 'Get-StatusBoundedBodyReadWait', 'Close-StatusBoundedBodyRead', 'Test-HostRefreshContentType', 'ConvertFrom-HostRefreshRequestBody', 'Get-HostRefreshControlSummary', 'Get-HostRefreshAdmissionReply', 'Get-StartCycleAdmissionReply', 'Test-StatusWorkerArgument', 'Get-StatusWorkerDirectory', 'Get-HostDiagnosticRouteState', 'New-StatusOperationId', 'Test-StatusRouteCommandSet', 'Save-StatusLaunchOutcome', 'Get-StatusWorkerTranscriptStem'
    }
    if (`$routeReady) {
        `$routeReady = Import-RouteModule -ModuleRelativePath 'test/modules/Test.InnerSpawn.psm1' -RequiredCommand 'Start-YurunaDetachedProcess'
    }
    `$routeRequirement = @{
        'Start-YurunaDetachedProcess' = @('FilePath', 'ArgumentList', 'WorkingDirectory', 'StdOutPath', 'StdErrPath', 'StdInPath', 'PrivateDirectory', 'Environment', 'Deadline')
    }
    `$routeWorker = ''
    `$routeVector = @()
    switch (`$Route) {
        'host-refresh' {
            if (`$routeReady) {
                `$routeReady = Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostRefresh.psm1' -RequiredCommand 'Get-VirtualizationRepairRung', 'Get-HostRefreshCapability', 'New-HostRefreshBudget', 'New-HostRefreshWorkerArgumentList', 'Publish-HostRefreshQueuedState'
            }
            if (`$routeReady) {
                `$routeReady = Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostRefreshIntent.psm1' -RequiredCommand 'Request-HostRefreshAdmission', 'Set-HostRefreshLaunchOutcome', 'Get-HostRefreshPrivateWorkDir'
            }
            `$routeRequirement['Request-HostRefreshAdmission'] = @('RequestId', 'Channel', 'Tier', 'MaxRung', 'RuntimeDir', 'HostType', 'AdmissionWaitMilliseconds')
            `$routeRequirement['Set-HostRefreshLaunchOutcome'] = @('RequestId', 'Outcome', 'Launch')
            `$routeRequirement['New-HostRefreshWorkerArgumentList'] = @('RepoRoot', 'RequestId', 'Budget')
            `$routeRequirement['Publish-HostRefreshQueuedState'] = @('RuntimeDir', 'RequestId', 'Channel')
            `$routeRequirement['Get-HostRefreshCapability'] = @('HostType', 'RepoRoot')
            `$routeRequirement['Get-VirtualizationRepairRung'] = @('HostType')
            `$routeWorker = `$hostRefreshEntry
        }
        'start-cycle' {
            if (`$routeReady) {
                `$routeReady = Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostRefreshIntent.psm1' -RequiredCommand 'Request-HostRefreshStartCycleReservation', 'Set-HostRefreshStartCycleLaunch'
            }
            `$routeRequirement['Request-HostRefreshStartCycleReservation'] = @('OperationId', 'RuntimeDir', 'AdmissionWaitMilliseconds')
            `$routeRequirement['Set-HostRefreshStartCycleLaunch'] = @('OperationId', 'Generation', 'Outcome', 'Launch')
            `$routeWorker = `$startCycleWorker
            `$routeVector = @('-OperationId', '00000000-0000-0000-0000-000000000000', '-Generation', 'probe', '-RuntimeDir', `$runtimeDir,
                '-CleanupScriptPath', `$startCycleCleanupScript, '-RunnerScriptPath', `$startCycleRunnerScript, '-WorkingDirectory', `$repoRoot)
        }
        'host-diagnostic' {
            `$routeWorker = `$hostDiagnosticWorker
            `$routeVector = @('-RunId', '00000000-0000-0000-0000-000000000000', '-DiagnosticScriptPath', `$diagScriptPath,
                '-WorkDirectory', `$runtimeDir, '-WorkingDirectory', `$repoRoot)
        }
    }
    if (`$routeReady) {
        `$commandSet = Test-StatusRouteCommandSet -Requirement `$routeRequirement
        if (-not `$commandSet.Ready) {
            `$routeReady = `$false
            Write-ServerErr "route `$Route cannot run: missing `$(`$commandSet.Missing -join ', ')"
        }
    }
    if (`$routeReady -and `$Route -eq 'host-refresh') {
        try {
            `$routeVector = @(New-HostRefreshWorkerArgumentList -RepoRoot `$workerRoot -RequestId '00000000-0000-0000-0000-000000000000' -Budget (New-HostRefreshBudget))
        } catch {
            `$routeReady = `$false
            Write-ServerErr "route host-refresh cannot build its worker vector: `$(`$_.Exception.Message)"
        }
    }
    if (`$routeReady) {
        `$vectorCheck = Test-StatusWorkerArgument -ScriptPath `$routeWorker -ArgumentList `$routeVector
        if (-not `$vectorCheck.Valid) {
            `$routeReady = `$false
            Write-ServerErr "route `$Route refuses its worker vector: `$(`$vectorCheck.Reason) `$(`$vectorCheck.Parameter)"
        }
    }
    `$readyRecord = [pscustomobject]@{
        Ready      = [bool]`$routeReady
        Reason     = `$(if (`$routeReady) { '' } else { 'listener_dependency_missing' })
        ValidUntil = `$checkedAt.AddSeconds(`$(if (`$routeReady) { 60 } else { 10 }))
    }
    `$script:StatusRouteReady[`$Route] = `$readyRecord
    return `$readyRecord
}

# The refresh summary /control/control-status carries. The capability is read
# per request (two small file reads, no native call); the remote-refresh
# provisioning state is cached for 30 seconds. Never throws into the route:
# any failure reads as unavailable, because this field decides whether a
# disruptive button is shown.
`$script:HostRefreshRemoteCache = `$null
function Get-HostRefreshSummaryCached {
    `$summaryFallback = [ordered]@{ protocol = 1; availability = 'unavailable'; ceiling = ''; reason = 'capability_unavailable'; remote = 'unqualified'; state = 'unknown' }
    try {
        `$summaryAt = [DateTime]::UtcNow
        if (-not `$script:HostRefreshRemoteCache -or `$summaryAt -ge `$script:HostRefreshRemoteCache.ValidUntil) {
            `$remoteState = 'unqualified'
            if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostRefreshAuth.psm1' -RequiredCommand 'Get-YurunaHostRefreshRemoteState') {
                try { `$remoteState = [string](Get-YurunaHostRefreshRemoteState -HostId (Get-ArchiveHostId)).Remote } catch { `$remoteState = 'unqualified' }
            }
            `$script:HostRefreshRemoteCache = [pscustomobject]@{ Remote = `$remoteState; ValidUntil = `$summaryAt.AddSeconds(30) }
        }
        `$summaryFallback.remote = [string]`$script:HostRefreshRemoteCache.Remote
        `$refreshReady = Test-StatusRouteReady -Route 'host-refresh'
        if (-not (Get-Command -Name 'Get-HostRefreshControlSummary' -ErrorAction SilentlyContinue)) {
            `$summaryFallback.reason = 'listener_dependency_missing'
            return `$summaryFallback
        }
        `$listenerReady = [bool]`$refreshReady.Ready
        `$listenerReason = [string]`$refreshReady.Reason
        if ([string]::IsNullOrWhiteSpace(`$serverHostType)) { `$listenerReady = `$false; `$listenerReason = 'unsupported_host' }
        `$refreshCapability = `$null
        if (`$serverHostType -and (Get-Command -Name 'Get-HostRefreshCapability' -ErrorAction SilentlyContinue)) {
            try { `$refreshCapability = Get-HostRefreshCapability -HostType `$serverHostType -RepoRoot `$repoRoot } catch {
                Write-ServerErr "refresh capability failed: `$(`$_.Exception.Message)"
                `$refreshCapability = `$null
            }
        }
        return (Get-HostRefreshControlSummary -Capability `$refreshCapability -ListenerReady `$listenerReady -ListenerReason `$listenerReason -Remote ([string]`$script:HostRefreshRemoteCache.Remote))
    } catch {
        Write-ServerErr "refresh summary failed: `$(`$_.Exception.Message)"
        return `$summaryFallback
    }
}

# See https://yuruna.link/42e5cdfd-0045
function Start-StatusWorker {
    param(
        [Parameter(Mandatory)][string]`$Directory,
        [Parameter(Mandatory)][string]`$StdInPath,
        [Parameter(Mandatory)][string]`$ScriptPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]`$ArgumentList,
        [Parameter(Mandatory)][string]`$TranscriptStem
    )
    `$workerVector = Test-StatusWorkerArgument -ScriptPath `$ScriptPath -ArgumentList `$ArgumentList
    if (-not `$workerVector.Valid) {
        Write-ServerErr "worker `$ScriptPath refused its vector: `$(`$workerVector.Reason) `$(`$workerVector.Parameter)"
        return [pscustomobject]@{ Launched = `$false; Reason = 'worker_unavailable' }
    }
    try {
        `$launchArguments = @{
            FilePath         = `$ScriptPath
            ArgumentList     = `$ArgumentList
            WorkingDirectory = `$repoRoot
            StdOutPath       = (Join-Path `$Directory (`$TranscriptStem + '.out'))
            StdErrPath       = (Join-Path `$Directory (`$TranscriptStem + '.err'))
            StdInPath        = `$StdInPath
            PrivateDirectory = `$Directory
            Environment      = @{ YURUNA_RUNTIME_DIR = `$runtimeDir }
            # The Windows launcher is a short-lived hop. Its acknowledgment
            # identifies the worker before reservation liveness can be checked.
            WaitForHandshakeMilliseconds = if (`$IsWindows) { 5000 } else { 0 }
            Deadline         = (New-YurunaDeadline -TotalMilliseconds 5000)
        }
        `$launchRecord = @(Start-YurunaDetachedProcess @launchArguments -Confirm:`$false |
                Where-Object { `$_ -and `$_.PSObject.Properties['Launched'] }) | Select-Object -Last 1
        if (-not `$launchRecord) { return [pscustomobject]@{ Launched = `$false; Reason = 'launcher_failed' } }
        return `$launchRecord
    } catch {
        Write-ServerErr "worker `$ScriptPath did not launch: `$(`$_.Exception.Message)"
        return [pscustomobject]@{ Launched = `$false; Reason = 'launcher_failed' }
    }
}

# See https://yuruna.link/42e5cdfd-0045
function Add-PendingRequestBody {
    param([Parameter(Mandatory)]`$RequestContext, [bool]`$Loopback, [string]`$ProofWire, `$Upload)
    if (`$pendingBodies.Count -ge 4) {
        Send-JsonReply -Response `$RequestContext.Response -Request `$RequestContext.Request -StatusCode 503 -Close -RetryAfter '2' ``
            -Body ([ordered]@{ ok = `$false; reason = 'listener_busy' }) -MessageKey 'status.api_listener_busy'
        return
    }
    if (-not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.StatusControlRoute.psm1' -RequiredCommand ``
            'New-StatusBoundedBodyRead', 'Update-StatusBoundedBodyRead', 'Get-StatusBoundedBodyReadWait', 'Close-StatusBoundedBodyRead')) {
        Send-JsonReply -Response `$RequestContext.Response -Request `$RequestContext.Request -StatusCode 503 -Close ``
            -Body ([ordered]@{ ok = `$false; reason = 'listener_dependency_missing' }) -MessageKey 'status.api_listener_dependency_missing'
        return
    }
    `$maxBytes = if (`$Upload) { [int]`$Upload.MaximumBytes } else { 4096 }
    `$timeoutMs = if (`$Upload) { `$script:UploadBodyTimeoutMilliseconds } else { 2000 }
    `$bodyRead = New-StatusBoundedBodyRead -Stream `$RequestContext.Request.InputStream -MaxBytes `$maxBytes -TimeoutMs `$timeoutMs ``
        -Tag ([pscustomobject]@{ RequestContext = `$RequestContext; Loopback = `$Loopback; ProofWire = `$ProofWire; Upload = `$Upload })
    `$pendingBodies.Add(`$bodyRead)
    Step-PendingRequestBody
}

`$script:UploadBodyTimeoutMilliseconds = 30000
function Complete-StatusArtifactUpload {
    param([Parameter(Mandatory)]`$RequestContext, [byte[]]`$Bytes, [Parameter(Mandatory)]`$Upload)
    `$temporary = "`$(`$Upload.Target).`$PID-`$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        `$parent = [IO.Path]::GetDirectoryName([string]`$Upload.Target)
        if (`$Upload.Kind -eq 'log-upload') { `$null = [IO.Directory]::CreateDirectory(`$parent) }
        [IO.File]::WriteAllBytes(`$temporary, `$Bytes)
        [IO.File]::Move(`$temporary, [string]`$Upload.Target, `$true)
        if (`$Upload.Kind -eq 'log-upload') {
            # Only installer-upload extensions participate in this retention.
            try {
                `$sameDir = @(Get-ChildItem -LiteralPath `$parent -File -ErrorAction SilentlyContinue |
                    Where-Object { `$_.Extension -in '.log','.txt','.json','.err','.crash','.tar' } |
                    Sort-Object -Property LastWriteTimeUtc -Descending)
                foreach (`$old in (`$sameDir | Select-Object -Skip 300)) { Remove-Item -LiteralPath `$old.FullName -Force -ErrorAction SilentlyContinue }
            } catch { Write-Debug `$_ }
            Send-JsonReply -Response `$RequestContext.Response -Request `$RequestContext.Request -StatusCode 201 ``
                -Body ([ordered]@{ ok = `$true; path = [string]`$Upload.RelativePath })
        } else {
            Send-JsonReply -Response `$RequestContext.Response -Request `$RequestContext.Request -StatusCode 200 ``
                -Body ([ordered]@{ ok = `$true; bytes = `$Bytes.Length; path = 'log/' + [string]`$Upload.RelativePath })
        }
    } catch {
        Write-ServerErr "`$(`$Upload.Kind) write failed (`$(`$Upload.RelativePath)): `$(`$_.Exception.Message)"
        Send-JsonError -Response `$RequestContext.Response -Request `$RequestContext.Request -StatusCode 500 ``
            -Key 'status.api_write_failed_detail_c07681e1' -Arguments @{ detail = `$_.Exception.Message }
    } finally {
        if (Test-Path -LiteralPath `$temporary) { Remove-Item -LiteralPath `$temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Step-PendingRequestBody {
    for (`$bodyIndex = `$pendingBodies.Count - 1; `$bodyIndex -ge 0; `$bodyIndex--) {
        `$bodyRead = `$pendingBodies[`$bodyIndex]
        `$bodyStatus = 'error'
        try { `$bodyStatus = Update-StatusBoundedBodyRead -BodyRead `$bodyRead } catch {
            Write-ServerErr "request body read failed: `$(`$_.Exception.Message)"
            `$bodyStatus = 'error'
        }
        if (`$bodyStatus -eq 'reading') { continue }
        `$pendingBodies.RemoveAt(`$bodyIndex)
        `$pendingContext = `$bodyRead.Tag.RequestContext
        try {
            switch (`$bodyStatus) {
                'complete' {
                    if (`$bodyRead.Tag.Upload) {
                        Complete-StatusArtifactUpload -RequestContext `$pendingContext -Bytes `$bodyRead.Bytes -Upload `$bodyRead.Tag.Upload
                    } else {
                        Invoke-HostRefreshRequest -RequestContext `$pendingContext -BodyBytes `$bodyRead.Bytes -Loopback ([bool]`$bodyRead.Tag.Loopback) -ProofWire ([string]`$bodyRead.Tag.ProofWire)
                    }
                }
                'too_large' {
                    `$sizeMessage = if (`$bodyRead.Tag.Upload) { [string]`$bodyRead.Tag.Upload.SizeMessage } else { 'status.api_payload_too_large_4_kb' }
                    Send-JsonReply -Response `$pendingContext.Response -Request `$pendingContext.Request -StatusCode 413 -Close ``
                        -Body ([ordered]@{ ok = `$false; reason = 'payload_too_large' }) -MessageKey `$sizeMessage
                }
                'timeout' {
                    Send-JsonReply -Response `$pendingContext.Response -Request `$pendingContext.Request -StatusCode 408 -Close ``
                        -Body ([ordered]@{ ok = `$false; reason = 'body_timeout' }) -MessageKey 'status.api_request_body_timeout'
                }
                default {
                    Write-ServerErr 'request body ended with a read error; the connection is dropped.'
                    try { `$pendingContext.Response.Abort() } catch { Write-Debug `$_ }
                }
            }
        } catch {
            Write-ServerErr "request body reply failed: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
            try { `$pendingContext.Response.Abort() } catch { Write-Debug `$_ }
        } finally {
            Close-StatusBoundedBodyRead -BodyRead `$bodyRead
        }
    }
}

# The second half of POST /control/host-refresh, once the whole body is in:
# validate it against the closed schema, apply loopback defaults, authorize a
# non-loopback caller's refresh proof, take the short admission lock, and on
# a spawn decision launch the detached worker and publish the queued state.
# Every outcome is a documented reply; nothing here waits for the repair.
function Invoke-HostRefreshRequest {
    param([Parameter(Mandatory)]`$RequestContext, [byte[]]`$BodyBytes, [bool]`$Loopback, [string]`$ProofWire)
    `$refreshRequest = `$RequestContext.Request
    `$refreshResponse = `$RequestContext.Response
    try {
        `$allowedRung = @(Get-VirtualizationRepairRung -HostType `$serverHostType |
                Where-Object { [int]`$_.Order -le 4 } | ForEach-Object { [string]`$_.Name })
        `$refreshBody = ConvertFrom-HostRefreshRequestBody -Bytes `$(if (`$BodyBytes) { `$BodyBytes } else { [byte[]]@() }) -AllowedRungName `$allowedRung -Remote:(-not `$Loopback)
        if (-not `$refreshBody.Valid) {
            `$invalidReply = [ordered]@{ ok = `$false; reason = [string]`$refreshBody.Reason }
            if (`$refreshBody.Field) { `$invalidReply['field'] = [string]`$refreshBody.Field }
            Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode 400 -Body `$invalidReply ``
                -MessageKey 'status.api_request_body_invalid' -MessageArguments @{ reason = [string]`$refreshBody.Reason; field = `$(if (`$refreshBody.Field) { [string]`$refreshBody.Field } else { '-' }) }
            return
        }
        `$refreshSummary = Get-HostRefreshSummaryCached
        `$refreshCeiling = if (`$refreshBody.MaxRung) { [string]`$refreshBody.MaxRung } else { [string]`$refreshSummary.ceiling }
        if (`$refreshSummary.availability -ne 'available' -or -not `$refreshCeiling) {
            Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'refresh_unavailable' }) ``
                -MessageKey 'status.api_host_refresh_unavailable' -MessageArguments @{ reason = `$(if (`$refreshSummary.reason) { [string]`$refreshSummary.reason } else { 'no_qualified_rung' }) }
            return
        }
        `$refreshRequestId = if (`$refreshBody.RequestIdSupplied) { [string]`$refreshBody.RequestId } else { New-StatusOperationId }
        `$refreshChannel = 'listener'
        if (-not `$Loopback) {
            # The refresh proof is its own layer: the generic guard above has
            # already checked the transport header and the legacy control
            # proof, and neither authorizes a repair. The proof is read from
            # its own header, never from X-Yuruna-Control.
            if (-not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostRefreshAuth.psm1' -RequiredCommand 'Test-YurunaHostRefreshAuthorization')) {
                Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode 403 -Body ([ordered]@{ ok = `$false; reason = 'refresh_verifier_unavailable' }) ``
                    -MessageKey 'status.api_host_refresh_authorization_refused' -MessageArguments @{ reason = 'refresh_verifier_unavailable' }
                return
            }
            `$refreshAuthorization = Test-YurunaHostRefreshAuthorization -ProofWire `$ProofWire -HostId (Get-ArchiveHostId) -RequestId `$refreshRequestId -Tier 'restart' -MaxRung `$refreshCeiling
            if (-not `$refreshAuthorization.Authorized) {
                `$refusalStatus = [int]`$refreshAuthorization.HttpStatus
                if (`$refusalStatus -lt 400) { `$refusalStatus = 403 }
                Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode `$refusalStatus -Body ([ordered]@{ ok = `$false; reason = [string]`$refreshAuthorization.Reason }) ``
                    -MessageKey 'status.api_host_refresh_authorization_refused' -MessageArguments @{ reason = [string]`$refreshAuthorization.Reason }
                return
            }
            `$refreshChannel = 'remote'
        }
        `$refreshAdmission = Request-HostRefreshAdmission -RequestId `$refreshRequestId -Channel `$refreshChannel -Tier 'restart' -MaxRung `$refreshCeiling ``
            -RuntimeDir `$runtimeDir -HostType `$serverHostType -AdmissionWaitMilliseconds 1000 -Confirm:`$false
        `$refreshLaunch = `$null
        if ([string]`$refreshAdmission.Decision -ceq 'spawn') {
            # See https://yuruna.link/42e5cdfd-0045
            `$refreshLaunch = [pscustomobject]@{ Launched = `$false; Reason = 'launcher_failed' }
            `$refreshPrivateUnavailable = `$false
            try {
                `$workDirectory = Get-HostRefreshPrivateWorkDir
                if (`$workDirectory -and `$workDirectory -isnot [string] -and `$workDirectory.PSObject.Properties['Path']) {
                    `$workDirectory = if (`$workDirectory.PSObject.Properties['Resolved'] -and -not `$workDirectory.Resolved) { `$null } else { [string]`$workDirectory.Path }
                }
                if ([string]::IsNullOrWhiteSpace([string]`$workDirectory)) {
                    `$refreshPrivateUnavailable = `$true
                    `$refreshLaunch = [pscustomobject]@{ Launched = `$false; Reason = 'private_state_unavailable' }
                } else {
                    `$refreshStdIn = Join-Path ([string]`$workDirectory) 'stdin.empty'
                    if (-not [System.IO.File]::Exists(`$refreshStdIn)) { [System.IO.File]::WriteAllBytes(`$refreshStdIn, [byte[]]@()) }
                    `$refreshVector = @(New-HostRefreshWorkerArgumentList -RepoRoot `$workerRoot -RequestId `$refreshRequestId -Budget (New-HostRefreshBudget))
                    `$refreshAttempt = 0
                    `$null = [int]::TryParse([string]`$refreshAdmission.Attempt, [ref]`$refreshAttempt)
                    if (`$refreshAttempt -lt 1) { `$refreshAttempt = 1 }
                    # A relaunch reuses the attempt number, and the earlier
                    # launch's transcripts are the evidence of why it failed.
                    `$refreshStem = Get-StatusWorkerTranscriptStem -Directory ([string]`$workDirectory) -Stem ('{0}.{1}' -f `$refreshRequestId, `$refreshAttempt)
                    `$refreshLaunch = Start-StatusWorker -Directory ([string]`$workDirectory) -StdInPath `$refreshStdIn -ScriptPath `$hostRefreshEntry ``
                        -ArgumentList `$refreshVector -TranscriptStem `$refreshStem
                }
            } finally {
                `$launchOutcome = if (`$refreshLaunch -and `$refreshLaunch.Launched) { 'started' } else { 'launch-failed' }
                `$launchRecord = Save-StatusLaunchOutcome -Argument @{ RequestId = `$refreshRequestId; Outcome = `$launchOutcome; Launch = `$refreshLaunch } -Record {
                    param([hashtable]`$A, [int]`$Attempt)
                    `$null = `$Attempt
                    Set-HostRefreshLaunchOutcome -RequestId `$A.RequestId -Outcome `$A.Outcome -Launch `$A.Launch -Confirm:`$false
                }
                if (-not `$launchRecord.Saved) {
                    Write-ServerErr "control/host-refresh could not record launch outcome '`$launchOutcome' for `$refreshRequestId after `$(`$launchRecord.Attempts) attempt(s); admission reads it as pending until the queued expiry: `$(@(`$launchRecord.Failure) -join '; ')"
                }
            }
            if (`$refreshPrivateUnavailable) {
                Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'private_state_unavailable' }) ``
                    -MessageKey 'status.api_private_state_unavailable' -MessageArguments @{ reason = 'work_directory_unavailable' }
                return
            }
            if (`$refreshLaunch -and `$refreshLaunch.Launched) {
                try { `$null = Publish-HostRefreshQueuedState -RuntimeDir `$runtimeDir -RequestId `$refreshRequestId -Channel `$refreshChannel } catch {
                    Write-ServerErr "control/host-refresh could not publish the queued state: `$(`$_.Exception.Message)"
                }
            }
        }
        `$admissionReply = Get-HostRefreshAdmissionReply -Admission `$refreshAdmission -Launch `$refreshLaunch -Ceiling `$refreshCeiling ``
            -StateUrl `$hostRefreshStateUrl -StartCycleStateUrl `$startCycleStateUrl
        Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode `$admissionReply.StatusCode -Body `$admissionReply.Body ``
            -MessageKey `$admissionReply.MessageKey -MessageArguments `$admissionReply.MessageArguments
    } catch {
        Write-ServerErr "control/host-refresh failed: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
        Send-JsonReply -Response `$refreshResponse -Request `$refreshRequest -StatusCode 500 -Body ([ordered]@{ ok = `$false; reason = 'internal_error' }) ``
            -MessageKey 'status.api_internal_error'
    }
}

# See https://yuruna.link/42185271-0012
function Invoke-StartCycleRequest {
    param([Parameter(Mandatory)]`$Request, [Parameter(Mandatory)]`$Response)
    `$startCycleDirectory = Get-StatusWorkerDirectory -Name 'start-cycle' -ServedRoot `$servedRootSet -Confirm:`$false
    if (-not `$startCycleDirectory.Resolved) {
        `$privateReason = ([string]`$startCycleDirectory.Reason).Replace('-', '_')
        Send-JsonReply -Response `$Response -Request `$Request -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'private_state_unavailable' }) ``
            -MessageKey 'status.api_private_state_unavailable' -MessageArguments @{ reason = `$privateReason }
        return
    }
    `$startCycleOperation = New-StatusOperationId
    `$startCycleReservation = Request-HostRefreshStartCycleReservation -OperationId `$startCycleOperation -RuntimeDir `$runtimeDir ``
        -AdmissionWaitMilliseconds 1000 -Confirm:`$false
    `$startCycleLaunch = `$null
    if ([string]`$startCycleReservation.Decision -ceq 'reserved') {
        `$startCycleGeneration = [string]`$startCycleReservation.Generation
        `$startCycleLaunch = [pscustomobject]@{ Launched = `$false; Reason = 'launcher_failed' }
        try {
            `$startCycleLaunch = Start-StatusWorker -Directory `$startCycleDirectory.Path -StdInPath `$startCycleDirectory.StdInPath ``
                -ScriptPath `$startCycleWorker -TranscriptStem `$startCycleOperation ``
                -ArgumentList @('-OperationId', `$startCycleOperation, '-Generation', `$startCycleGeneration, '-RuntimeDir', `$runtimeDir,
                    '-CleanupScriptPath', `$startCycleCleanupScript, '-RunnerScriptPath', `$startCycleRunnerScript, '-WorkingDirectory', `$repoRoot)
        } finally {
            `$startCycleOutcome = if (`$startCycleLaunch -and `$startCycleLaunch.Launched) { 'started' } else { 'launch-failed' }
            `$startCycleRecord = Save-StatusLaunchOutcome -Argument @{
                OperationId = `$startCycleOperation; Generation = `$startCycleGeneration; Outcome = `$startCycleOutcome; Launch = `$startCycleLaunch
            } -Record {
                param([hashtable]`$A, [int]`$Attempt)
                `$null = `$Attempt
                Set-HostRefreshStartCycleLaunch -OperationId `$A.OperationId -Generation `$A.Generation -Outcome `$A.Outcome -Launch `$A.Launch
            }
            if (-not `$startCycleRecord.Saved) {
                Write-ServerErr "start-cycle could not record launch outcome '`$startCycleOutcome' for `$startCycleOperation after `$(`$startCycleRecord.Attempts) attempt(s); the reservation stays until this listener exits: `$(@(`$startCycleRecord.Failure) -join '; ')"
            }
        }
    }
    `$startCycleReply = Get-StartCycleAdmissionReply -Reservation `$startCycleReservation -Launch `$startCycleLaunch ``
        -OperationId `$startCycleOperation -StateUrl `$startCycleStateUrl -RefreshStateUrl `$hostRefreshStateUrl
    Send-JsonReply -Response `$Response -Request `$Request -StatusCode `$startCycleReply.StatusCode -Body `$startCycleReply.Body ``
        -MessageKey `$startCycleReply.MessageKey -MessageArguments `$startCycleReply.MessageArguments
}
# --- REGION: Send-GitArchive
# See https://yuruna.link/42fffc2c-0013
function Send-GitArchive {
    <#
    .SYNOPSIS
        Stream committed framework or project content with origin and revision sidecars.
    #>
    param(`$Response, `$Request, `$Context, [string]`$RepoDir, [string]`$ErrorLabel, [string[]]`$ExcludePath = @())
    `$tmp        = [System.IO.Path]::GetTempFileName()
    `$sidecarDir = `$null
    try {
        `$archiveArgs = @('-C', `$RepoDir, 'archive', '--format=tar.gz')
        `$treeish     = 'HEAD'
        `$sidecars    = [ordered]@{}
        `$originUrl = & git -C `$RepoDir config --get remote.origin.url 2>`$null
        if (`$LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(`$originUrl)) {
            if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostGit.psm1' -RequiredCommand 'Resolve-GitRemoteLink') {
                `$publicOrigin = (Resolve-GitRemoteLink -Url ([string]`$originUrl)).Url
                if (`$publicOrigin) { `$sidecars['.yuruna-origin'] = `$publicOrigin }
            }
        }
        `$commit = & git -C `$RepoDir rev-parse HEAD 2>`$null
        `$commit = if (`$LASTEXITCODE -eq 0) { ([string]`$commit).Trim() } else { '' }
        if (`$commit -match '^[0-9a-f]{40}`$') {
            `$sidecars['.yuruna-revision'] = `$commit
            `$treeish = `$commit
        }
        `$archiveKey = `$commit + '|' + [string]`$sidecars['.yuruna-origin'] + '|' + (`$ExcludePath -join ',')
        if (-not (Get-Variable -Name GitArchiveCache -Scope Script -ErrorAction SilentlyContinue)) { `$script:GitArchiveCache = @{} }
        if (`$commit -match '^[0-9a-f]{40}`$' -and `$script:GitArchiveCache.ContainsKey(`$RepoDir) -and `$script:GitArchiveCache[`$RepoDir].Key -ceq `$archiveKey) {
            `$bytes = `$script:GitArchiveCache[`$RepoDir].Bytes
            `$Response.ContentType = 'application/gzip'
            `$Response.Headers.Add('Cache-Control', 'no-store')
            `$Response.ContentLength64 = `$bytes.Length
            if (`$Request.HttpMethod -ne 'HEAD') { `$Response.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
            `$Response.OutputStream.Close()
            return
        }
        if (`$sidecars.Count -gt 0) {
            `$sidecarDir = New-Item -ItemType Directory -Path ([IO.Path]::Combine([IO.Path]::GetTempPath(), [Guid]::NewGuid().ToString('N'))) -Force
            foreach (`$sidecarName in @(`$sidecars.Keys)) {
                `$sidecarFile = Join-Path `$sidecarDir.FullName `$sidecarName
                [IO.File]::WriteAllText(`$sidecarFile, `$sidecars[`$sidecarName])
                `$archiveArgs += ('--add-file=' + `$sidecarFile)
            }
        }
        `$archiveArgs += @('-o', `$tmp, `$treeish)
        if (`$ExcludePath.Count) {
            `$archiveArgs += '--'
            `$archiveArgs += '.'
            foreach (`$excluded in `$ExcludePath) { `$archiveArgs += (':(exclude)' + `$excluded) }
        }
        & git @archiveArgs 2>`$null
        if (`$LASTEXITCODE -ne 0 -or -not (Test-Path `$tmp)) {
            `$Response.StatusCode = 500
            `$body = [System.Text.Encoding]::UTF8.GetBytes('git archive failed')
            `$Response.OutputStream.Write(`$body, 0, `$body.Length)
            `$Response.OutputStream.Close()
            return
        }
        `$bytes = [System.IO.File]::ReadAllBytes(`$tmp)
        if (`$commit -match '^[0-9a-f]{40}`$') {
            if (`$script:GitArchiveCache.Count -ge 3 -and -not `$script:GitArchiveCache.ContainsKey(`$RepoDir)) { `$script:GitArchiveCache.Clear() }
            `$script:GitArchiveCache[`$RepoDir] = @{ Key = `$archiveKey; Bytes = `$bytes }
        }
        `$Response.ContentType = 'application/gzip'
        `$Response.Headers.Add('Cache-Control', 'no-store')
        `$Response.ContentLength64 = `$bytes.Length
        if (`$Request.HttpMethod -ne 'HEAD') { `$Response.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
        `$Response.OutputStream.Close()
    } catch {
        Write-ServerErr "`${ErrorLabel}: `$(`$_.Exception.Message)"
        try { `$Context.Response.Abort() } catch { Write-Debug `$_ }
    } finally {
        Remove-Item `$tmp -Force -ErrorAction SilentlyContinue
        if (`$sidecarDir) { Remove-Item -LiteralPath `$sidecarDir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
# --- REGION: Archived cycle results (poolStorage move mode)
# See https://yuruna.link/42e5cdfd-0045
`$script:ArchiveHostId = `$null
function Get-ArchiveHostId {
    # runtime/host.uuid cannot change while this server runs, so it is read once.
    if (`$null -ne `$script:ArchiveHostId) { return `$script:ArchiveHostId }
    `$script:ArchiveHostId = ''
    try {
        `$uuidFile = Join-Path `$runtimeDir 'host.uuid'
        if (Test-Path -LiteralPath `$uuidFile) { `$script:ArchiveHostId = (Get-Content -Raw -LiteralPath `$uuidFile).Trim() }
    } catch { `$script:ArchiveHostId = '' }
    return `$script:ArchiveHostId
}

function Get-ArchiveCycleRoot {
    # Resolved per call through the mtime+hash-cached config read, so an operator
    # edit to test.config.yml is observed on the next request exactly like every
    # other handler here. Returns '' when pool storage is unconfigured or its mount
    # is not present -- this server never mounts anything and never runs sudo.
    try {
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) { return '' }
        `$hid = Get-ArchiveHostId
        if ([string]::IsNullOrWhiteSpace(`$hid)) { return '' }
        `$cfgPath = Join-Path `$repoRoot 'test/test.config.yml'
        if (-not (Test-Path -LiteralPath `$cfgPath)) { return '' }
        `$psCfg = Get-YurunaPoolStorageConfig -Config (Read-TestConfig -Path `$cfgPath) -WarningAction SilentlyContinue
        if (-not `$psCfg) { return '' }
        if (-not (Test-Path -LiteralPath `$psCfg.LocalPath)) { return '' }
        `$root = Get-PoolStorageCycleRootPath -Config `$psCfg -HostId `$hid
        if (-not (Test-Path -LiteralPath `$root)) { return '' }
        return `$root
    } catch { return '' }
}

function ConvertTo-ArchiveRelativePath {
    # See https://yuruna.link/42e5cdfd-0045
    param([string]`$Rel)
    `$norm = (`$Rel -replace '\\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace(`$norm)) { return '' }
    `$parts = @(`$norm -split '/' | Where-Object { `$_ -ne '' })
    if (`$parts.Count -eq 0) { return '' }
    if (`$parts[0] -like 'history.*') {
        if (`$parts.Count -lt 2) { return '' }
        `$parts = @(`$parts[1..(`$parts.Count - 1)])
    }
    `$parts[0] = `$parts[0] -replace '\.incomplete`$', '' -replace '\.aborted\.[^/]+`$', ''
    if (`$parts[0] -notmatch '^\d{6}\..+\..+\..+') { return '' }
    return (`$parts -join '/')
}

function Resolve-ArchivedLogPath {
    # The full local-path -> share-path fallback: '' when there is no archive, no
    # mapping, or nothing at the mapped location.
    param([string]`$Rel)
    `$root = Get-ArchiveCycleRoot
    if ([string]::IsNullOrWhiteSpace(`$root)) { return '' }
    `$mapped = ConvertTo-ArchiveRelativePath -Rel `$Rel
    if ([string]::IsNullOrWhiteSpace(`$mapped)) { return '' }
    `$candidate = Join-Path `$root (`$mapped -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath `$candidate) { return `$candidate }
    return ''
}

# Folders the completion sentinel was seen in, by name, with the folder's
# last-write time at that moment. A finished copy is never written again, so a
# later listing skips the existence check for every folder whose last-write time
# still matches, and pays it only for new folders and ones changed since.
`$script:ArchiveCompleteMark = @{}

function Get-ArchivedCycleEntry {
    # See https://yuruna.link/42e5cdfd-0045
    `$root = Get-ArchiveCycleRoot
    if ([string]::IsNullOrWhiteSpace(`$root)) { return @() }
    try {
        `$known = `$script:ArchiveCompleteMark
        if (`$known -isnot [hashtable]) { `$known = @{} }
        `$marks = @{}
        `$found = [System.Collections.Generic.List[object]]::new()
        foreach (`$dir in @(Get-ChildItem -LiteralPath `$root -Directory -ErrorAction SilentlyContinue)) {
            if (`$dir.Name -notmatch '^\d{6}\..+\..+\..+') { continue }
            `$stamp = `$dir.LastWriteTimeUtc.Ticks
            `$complete = (`$known[`$dir.Name] -eq `$stamp) -or
                [System.IO.File]::Exists([System.IO.Path]::Combine(`$dir.FullName, '.yuruna-complete'))
            if (-not `$complete) { continue }
            `$marks[`$dir.Name] = `$stamp
            `$found.Add(`$dir)
        }
        `$script:ArchiveCompleteMark = `$marks
        return `$found.ToArray()
    } catch { return @() }
}

function Get-ArchivedCycleName {
    # The archived leaf names, for the cycle-number short link.
    return @(Get-ArchivedCycleEntry | ForEach-Object { `$_.Name })
}

# Runner liveness for /control/runner-status.
# See https://yuruna.link/42185271-000b
function Test-RunnerAlive {
    param([switch]`$QuietErrors)
    `$runnerPidFile   = Join-Path `$runtimeDir 'runner.pid'
    `$runnerStartFile = Join-Path `$runtimeDir 'runner.start'
    # See https://yuruna.link/42e5cdfd-0045
    `$verboseLines = [System.Collections.Generic.List[string]]::new()
    `$state = Get-RunnerInstanceState -RunnerPidFile `$runnerPidFile -RunnerStartFile `$runnerStartFile -Verbose 4>&1 |
        ForEach-Object {
            if (`$_ -is [System.Management.Automation.VerboseRecord]) { `$verboseLines.Add([string]`$_.Message); return }
            `$_
        } |
        Select-Object -Last 1
    foreach (`$line in `$verboseLines) {
        if (`$line -notmatch 'cross-check failed') { continue }
        if (`$QuietErrors) { Write-Debug `$line } else { Write-ServerErr `$line }
    }
    # 'OtherRunner' is a live runner owning the pidfile (identified by
    # StartTime sidecar or cmdline regex); 'None'/'Self'/'Stale' are not.
    `$running = (`$state -and `$state.status -eq 'OtherRunner')
    # Preserve the prior null-when-absent contract: the file PID is reported
    # only when a pidfile actually named one (0 means missing/unparseable).
    `$pidVal = if (`$state -and `$state.pid -gt 0) { [int]`$state.pid } else { `$null }
    [pscustomobject]@{ Running = `$running; RunnerPid = `$pidVal }
}
try {
    `$listener.Start()
    Write-ServerErr "listener started on http://*:$Port/ (pid `$PID)"
    Write-ServerErr "server hostType='`$serverHostType'"
    # Compile the critical-record I/O helper now, once, so the first refresh
    # or start-cycle admission does not pay for it inside a request.
    if (Get-Command -Name 'Initialize-YurunaCriticalRecordIo' -ErrorAction SilentlyContinue) {
        try { `$null = Initialize-YurunaCriticalRecordIo } catch { Write-ServerErr "critical-record I/O pre-warm failed: `$(`$_.Exception.Message)" }
    }
    # Bodies being read for control/host-refresh, the pending accept, and the
    # last host-diagnostic launch (which throttles a caller that polls faster
    # than a worker starts).
    `$pendingBodies = [System.Collections.Generic.List[object]]::new()
    `$contextTask = `$null
    `$script:HostDiagSpawnUtc = `$null
    `$script:HostDiagSpawnRunId = ''
    # Cross-request memoized per-sequence aggregates served at
    # /control/perf-aggregates. Cleared on POST to that endpoint.
    # `$perfAggregatesBytes holds the serialized response so a GET on an
    # already-built cache skips ConvertTo-Json + GetBytes entirely.
    `$perfAggregatesCache = `$null
    `$perfAggregatesBytes = `$null
    # See https://yuruna.link/42e5cdfd-0045
    `$repoAccessCache = @{}
    `$repoAccessCacheTtl = [TimeSpan]::FromMinutes(10)
    while (`$listener.IsListening) {
      # Outer try/catch: any throw below MUST NOT kill the server.
      # `$listener.EndGetContext(...)` MUST stay inside this try, since
      # transient HttpListenerException (client reset, malformed request,
      # http.sys hiccup) would otherwise unwind to the outer try/finally
      # and exit with no log. Wrap the whole iteration; log + continue.
      try {
        # Wait for the next request without ever parking on a request body.
        # With no body being read the wait is indefinite (the server has no
        # self-exit timer, so it needs no periodic wake-up); with one, the
        # loop also wakes when that read completes or reaches its deadline,
        # so a withheld or trickled body never stalls the other routes.
        if (`$pendingBodies.Count -gt 0) { Step-PendingRequestBody }
        if (`$null -eq `$contextTask) { `$contextTask = `$listener.GetContextAsync() }
        `$waitTasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
        `$waitTasks.Add(`$contextTask)
        foreach (`$pendingBody in `$pendingBodies) { if (`$pendingBody.Task) { `$waitTasks.Add(`$pendingBody.Task) } }
        `$waitMs = if (`$pendingBodies.Count -gt 0) { Get-StatusBoundedBodyReadWait -BodyRead `$pendingBodies.ToArray() } else { -1 }
        `$null = [System.Threading.Tasks.Task]::WaitAny(`$waitTasks.ToArray(), [int]`$waitMs)
        if (-not `$contextTask.IsCompleted) { continue }
        `$acceptedTask = `$contextTask
        `$contextTask = `$null
        `$ctx = `$acceptedTask.GetAwaiter().GetResult()
        try {
            `$req  = `$ctx.Request
            `$res  = `$ctx.Response
            # --- REGION: HTTP response headers
            # See https://yuruna.link/42185271-0002
            # Set every response's policy here; omit cross-origin grants.
            `$res.Headers.Add('X-Content-Type-Options', 'nosniff')
            `$res.Headers.Add('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self'; media-src 'self'; object-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
            `$path = `$req.Url.LocalPath.TrimStart('/')
            if (`$path -eq '' -or `$path -eq 'status/' -or `$path -eq 'status') { `$path = 'index.html' }
            `$path = `$path -replace '^status[/\\]', ''

            if (`$path -eq 'metrics') {
                if (`$req.HttpMethod -notin @('GET', 'HEAD')) {
                    `$res.StatusCode = 405
                    `$res.Headers.Set('Allow', 'GET, HEAD')
                    `$res.ContentLength64 = 0
                    `$res.OutputStream.Close()
                    continue
                }
                `$memorySuccess = `$false
                `$memoryBody = "# TYPE yuruna_host_memory_collection_success gauge``nyuruna_host_memory_collection_success 0``n"
                try {
                    `$memoryReply = Get-YurunaHostMemoryMetricPayload
                    `$memorySuccess = `$memoryReply.Success
                    `$memoryBody = `$memoryReply.Body
                } catch { Write-ServerErr "memory metrics: `$(`$_.Exception.Message)" }
                `$memoryBytes = [Text.Encoding]::UTF8.GetBytes(`$memoryBody)
                `$res.StatusCode = if (`$memorySuccess) { 200 } else { 503 }
                `$res.ContentType = 'text/plain; version=0.0.4; charset=utf-8'
                `$res.Headers.Set('Cache-Control', 'no-store')
                `$res.ContentLength64 = `$memoryBytes.Length
                if (`$req.HttpMethod -ne 'HEAD') { `$res.OutputStream.Write(`$memoryBytes, 0, `$memoryBytes.Length) }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: Control request authorization
            # See https://yuruna.link/42185271-0002
            `$csrfAlwaysProtected = @(
                'control/start-cycle','control/break-continue','control/test-caching-proxy-service',
                'control/host-diagnostic','control/step-pause','control/step-resume',
                'control/cycle-pause','control/cycle-resume','control/lab-hold-release',
                'control/host-refresh'
            )
            `$csrfWriteProtected = @('control/test-config','control/perf-aggregates')
            if ((`$csrfAlwaysProtected -contains `$path) -or (`$csrfWriteProtected -contains `$path)) {
                if (`$req.HttpMethod -eq 'OPTIONS') {
                    # Preflight for a cross-origin custom-header request: answer
                    # every guarded route the same way -- with no Access-Control-
                    # Allow-* header -- so the browser denies the actual request.
                    # Same-origin callers never preflight.
                    `$res.StatusCode = 204
                    `$res.OutputStream.Close()
                    continue
                }
                # Always-protected routes require the header on any method; the
                # write-protected pair only on state-changing verbs, since their
                # GET/HEAD read path changes nothing.
                `$needsHeader = (`$csrfAlwaysProtected -contains `$path) -or (@('POST','PUT') -contains `$req.HttpMethod)
                if (`$needsHeader -and `$req.Headers['X-Yuruna'] -ne '1') {
                    `$res.ContentType = 'application/json; charset=utf-8'
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    Send-JsonError -Response `$res -StatusCode 403 -Request `$req -Key 'status.api_forbidden_missing_x_yuruna_request_header_cross_site_r_c47c4ea5'
                    continue
                }
                # See https://yuruna.link/42185271-0003
                # A missing internal key leaves control loopback-only.
                if (`$needsHeader) {
                    `$ctlLoopback = `$false
                    # See https://yuruna.link/42e5cdfd-0045
                    try { `$ctlLoopback = [System.Net.IPAddress]::IsLoopback(`$req.RemoteEndPoint.Address) } catch { `$ctlLoopback = `$false }
                    if (-not `$ctlLoopback) {
                        `$ctlToken = ''
                        try {
                            if (Get-Command Import-Extension -ErrorAction SilentlyContinue) {
                                try { `$null = Import-Extension -Area 'authentication' -RequireSingle } catch { `$null = `$_ }
                            }
                            # See https://yuruna.link/42e5cdfd-0045
                            foreach (`$ctlName in @('internal-auth-key', 'lab-auth-token', 'pool-auth-token')) {
                                if (`$ctlToken) { break }
                                `$ctlTm = if (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) { Get-EffectiveUser -LogicalUser `$ctlName } else { `$null }
                                if (`$ctlTm -and `$ctlTm.vaultKey -and (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue) -and (Test-VaultEntry -VaultKey `$ctlTm.vaultKey)) {
                                    `$ctlToken = Get-Password -Username `$ctlName
                                }
                            }
                        } catch { `$ctlToken = '' }
                        # See https://yuruna.link/42e5cdfd-0045
                        `$ctlWire   = [string]`$req.Headers['X-Yuruna-Control']
                        `$ctlReason = ''
                        if (-not (Get-Command Test-YurunaControlProof -ErrorAction SilentlyContinue)) {
                            `$ctlReason = 'verifier-unavailable'
                        } elseif ([string]::IsNullOrWhiteSpace(`$ctlToken)) {
                            `$ctlReason = 'host-token-missing'
                        } elseif ([string]::IsNullOrWhiteSpace(`$ctlWire)) {
                            `$ctlReason = 'proof-missing'
                        } elseif (-not (Test-YurunaControlProof -Token `$ctlToken -Wire `$ctlWire)) {
                            # Expired vs forged is decidable from the wire's own expiry
                            # segment without trusting it: a well-formed but past expiry is
                            # the routine case (the operator sat on the page too long).
                            `$ctlReason = 'proof-invalid'
                            `$ctlDot = `$ctlWire.IndexOf('.')
                            if (`$ctlDot -gt 0) {
                                [long]`$ctlExp = 0
                                if ([long]::TryParse(`$ctlWire.Substring(0, `$ctlDot), [ref]`$ctlExp) -and
                                    `$ctlExp -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
                                    `$ctlReason = 'proof-expired'
                                }
                            }
                        }
                        if (`$ctlReason) {
                            `$res.ContentType = 'application/json; charset=utf-8'
                            `$res.Headers.Add('Cache-Control', 'no-store')
                            Send-JsonError -Response `$res -StatusCode 403 -Request `$req -Key 'status.api_follow_guidance_at_https_yuruna_link_42185271_0007_ed03dcd1' -Reason `$ctlReason
                            continue
                        }
                    }
                }
            }

            # --- REGION: /control/test-config: read/write test.config.yml from UI
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/test-config') {
                `$testConfigFile = Join-Path `$repoRoot 'test/test.config.yml'
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -eq 'GET' -or `$req.HttpMethod -eq 'HEAD') {
                    if (-not (Test-Path -LiteralPath `$testConfigFile)) {
                        Send-JsonError -Response `$res -StatusCode 404 -Request `$req -Key 'status.api_test_config_yml_not_found_3b38d785'
                        continue
                    }
                    try {
                        `$doc  = Read-TestConfig -Path `$testConfigFile -ThrowOnError
                        # Readers share the cached document. Redact a response
                        # view without removing the secrets the next save must
                        # merge from the original document.
                        `$view = [ordered]@{}
                        foreach (`$key in `$doc.Keys) {
                            `$view[`$key] = if (`$key -eq 'secrets') { [ordered]@{} } else { `$doc[`$key] }
                        }
                        `$json = `$view | ConvertTo-Json -Depth 20
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$json)
                    } catch {
                        `$res.StatusCode = 500
                        `$errMsg = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        `$bytes = (Get-StatusMessageBytes -Request `$req -Response `$res -Key 'status.api_yaml_parse_failed_detail_363d5cf4' -Arguments @{ detail = `$_.Exception.Message } -Json)
                    }
                    `$res.ContentLength64 = `$bytes.Length
                    if (`$req.HttpMethod -ne 'HEAD') {
                        `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                    }
                    `$res.OutputStream.Close()
                    continue
                }
                if (`$req.HttpMethod -eq 'POST' -or `$req.HttpMethod -eq 'PUT') {
                    `$payload = `$null
                    # ContentLength64 == -1 means chunked/unknown; allow those through.
                    if (`$req.ContentLength64 -gt 1MB) {
                        Send-JsonError -Response `$res -StatusCode 413 -Request `$req -Key 'status.api_payload_too_large_1_mb_350b49df'
                        continue
                    }
                    try {
                        `$reader = [System.IO.StreamReader]::new(`$req.InputStream, `$req.ContentEncoding)
                        `$payload = `$reader.ReadToEnd()
                        `$reader.Close()
                    } catch {
                        Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_could_not_read_body_aa31dc00'
                        continue
                    }
                    `$parsedDoc = `$null
                    try {
                        `$parsedDoc = `$payload | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                    } catch {
                        `$errMsg = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_invalid_json_detail_c907dfc3' -Arguments @{ detail = `$_.Exception.Message }
                        continue
                    }
                    # See https://yuruna.link/42e5cdfd-0045
                    `$cacheIpErr = `$null
                    if (`$parsedDoc -is [System.Collections.IDictionary] -and `$parsedDoc.Contains('vmStart')) {
                        `$vsNode = `$parsedDoc['vmStart']
                        if (`$vsNode -is [System.Collections.IDictionary] -and `$vsNode.Contains('cachingProxyIp')) {
                            `$cacheIp = "`$(`$vsNode['cachingProxyIp'])".Trim()
                            `$vsNode['cachingProxyIp'] = `$cacheIp
                            if (`$cacheIp) {
                                if (-not (Get-Command Test-IpAddress -ErrorAction SilentlyContinue)) {
                                    `$cacheIpErr = "Test-IpAddress not available in this runspace -- cannot validate vmStart.cachingProxyIp"
                                } elseif (-not (Test-IpAddress `$cacheIp)) {
                                    `$cacheIpErr = "vmStart.cachingProxyIp='`$cacheIp' is not a valid IPv4 or IPv6 address"
                                } else {
                                    `$cachePort = Get-CachingProxyServicePort -Scheme http
                                    `$probeTcp = New-Object System.Net.Sockets.TcpClient
                                    `$probeOk  = `$false
                                    try {
                                        `$probeAsync = `$probeTcp.BeginConnect(`$cacheIp, `$cachePort, `$null, `$null)
                                        `$probeOk    = (`$probeAsync.AsyncWaitHandle.WaitOne(1500) -and `$probeTcp.Connected)
                                    } catch {
                                        Write-ServerErr "save-time cachingProxyIp probe `${cacheIp}:`${cachePort} threw: `$(`$_.Exception.Message)"
                                    } finally {
                                        `$probeTcp.Close()
                                    }
                                    if (-not `$probeOk) {
                                        `$cacheIpErr = "vmStart.cachingProxyIp='`$cacheIp' is not reachable on TCP :`$cachePort"
                                    }
                                }
                            }
                        }
                    }
                    if (`$cacheIpErr) {
                        `$errMsg = (ConvertTo-JsonEscapedString `$cacheIpErr)
                        Send-JsonError -Response `$res -StatusCode 400 -Json ('{"ok":false,"error":"' + `$errMsg + '"}')
                        continue
                    }
                    # See https://yuruna.link/42e5cdfd-0045
                    # Re-merge the on-disk secrets node: the GET above serves it redacted
                    # and the UI round-trips the whole document, so a save would otherwise
                    # overwrite the stored secrets with the empty node.
                    `$diskDoc = `$null
                    try {
                        if ((`$parsedDoc -is [System.Collections.IDictionary]) -and (Test-Path -LiteralPath `$testConfigFile)) {
                            `$diskDoc = Read-TestConfig -Path `$testConfigFile -NoCache -ThrowOnError
                            if (`$diskDoc -is [System.Collections.IDictionary] -and `$diskDoc.Contains('secrets') -and (`$diskDoc['secrets'] -is [System.Collections.IDictionary])) {
                                `$diskSecrets = `$diskDoc['secrets']
                                if (-not `$parsedDoc.Contains('secrets') -or -not (`$parsedDoc['secrets'] -is [System.Collections.IDictionary])) {
                                    `$parsedDoc['secrets'] = `$diskSecrets
                                } else {
                                    `$postedSecrets = `$parsedDoc['secrets']
                                    foreach (`$sk in @(`$diskSecrets.Keys)) {
                                        `$postedVal = if (`$postedSecrets.Contains(`$sk)) { "`$(`$postedSecrets[`$sk])" } else { '' }
                                        if ([string]::IsNullOrEmpty(`$postedVal)) { `$postedSecrets[`$sk] = `$diskSecrets[`$sk] }
                                    }
                                }
                            }
                        }
                    } catch {
                        Write-ServerErr "test-config secrets re-merge failed: `$(`$_.Exception.Message)"
                        Send-JsonError -Response `$res -StatusCode 500 -Request `$req -Key 'status.api_write_failed_detail_c07681e1' -Arguments @{ detail = `$_.Exception.Message }
                        continue
                    }
                    `$tmp = "`$testConfigFile.`$PID-`$([guid]::NewGuid().ToString('N')).tmp"
                    `$writeOk = `$false
                    try {
                        # Older editors omit mirror fields. Omission is not an
                        # operator request to remove enrolled trust.
                        if (-not `$diskDoc) { `$diskDoc = [ordered]@{} }
                        `$parsedDoc = Merge-ConfigMirrorSetting -Current `$diskDoc -Proposed `$parsedDoc
                        `$mirrorChanges = @(Get-ConfigMirrorChange -Current `$diskDoc -Proposed `$parsedDoc)
                        if (`$mirrorChanges.Count -gt 0 -and (Test-Path -LiteralPath `$testConfigFile)) {
                            Copy-Item -LiteralPath `$testConfigFile -Destination "`$testConfigFile.backup" -Force
                        }
                        foreach (`$change in `$mirrorChanges) {
                            Write-ServerErr "`$(`$change.Path): `$(`$change.Previous) -> `$(`$change.Current) (backup: `$testConfigFile.backup)"
                        }
                        # See https://yuruna.link/42e5cdfd-0045
                        `$yamlOut = `$parsedDoc | ConvertTo-Yaml
                        Set-Content -LiteralPath `$tmp -Value `$yamlOut -Encoding utf8 -NoNewline
                        [System.IO.File]::Move(`$tmp, `$testConfigFile, `$true)
                        `$writeOk = `$true
                    } catch {
                        `$errMsg = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        Send-JsonError -Response `$res -StatusCode 500 -Request `$req -Key 'status.api_write_failed_detail_c07681e1' -Arguments @{ detail = `$_.Exception.Message }
                        Write-ServerErr "test-config write failed: `$errMsg"
                    } finally {
                        # On the failure path, Set-Content may have left
                        # a partial .tmp next to the real file; on the
                        # success path the atomic move already consumed it.
                        # Either way, ensure no .tmp is left behind.
                        if (-not `$writeOk -and (Test-Path -LiteralPath `$tmp)) {
                            Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if (-not `$writeOk) { continue }
                    `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                    `$res.ContentLength64 = `$body.Length
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.Headers.Add('Allow', 'GET, POST, PUT')
                Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_be4fb6a2'
                continue
            }

            # --- REGION: /control/runtime-env: surface specific env vars to the UI
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/runtime-env') {
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.Headers.Add('Allow', 'GET')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_be4fb6a2'
                    continue
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$envValue = if (`$env:YURUNA_CACHING_PROXY_SERVICE_IP) { `$env:YURUNA_CACHING_PROXY_SERVICE_IP } else { '' }
                # See https://yuruna.link/42e5cdfd-0045
                `$serverUser = try { [Environment]::UserName } catch { '' }
                `$payload = @{
                    YURUNA_CACHING_PROXY_SERVICE_IP = `$envValue
                    serverUserAccount = `$serverUser
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/host-facts: machine facts for pool UIs
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/host-facts') {
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.Headers.Add('Allow', 'GET')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_be4fb6a2'
                    continue
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$hfMemory = [long]0
                `$hfCores  = [long]0
                try {
                    if (`$IsWindows) {
                        `$hfMemory = [long](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory
                        `$hfCores  = [long]((Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum)
                    } elseif (`$IsMacOS) {
                        `$hfMemory = [long](& sysctl -n hw.memsize 2>`$null)
                        `$hfCores  = [long](& sysctl -n hw.physicalcpu 2>`$null)
                    } else {
                        `$hfMemLine = Get-Content -LiteralPath '/proc/meminfo' -TotalCount 1 -ErrorAction Stop
                        if (`$hfMemLine -match 'MemTotal:\s*(\d+)\s*kB') { `$hfMemory = [long]`$Matches[1] * 1024 }
                        # See https://yuruna.link/42e5cdfd-0045
                        `$hfPairs = & lscpu -b '-p=Core,Socket' 2>`$null | Where-Object { `$_ -and `$_ -notmatch '^#' } | Sort-Object -Unique
                        `$hfCores = [long](`$hfPairs | Measure-Object).Count
                    }
                } catch { `$null = `$_ }
                if (`$hfCores -le 0) { `$hfCores = [long][Environment]::ProcessorCount }
                `$hfStorTotal = [long]0
                `$hfStorFree  = [long]0
                try {
                    `$hfStorage   = Get-HostStorageFact
                    `$hfStorTotal = [long]`$hfStorage.TotalBytes
                    `$hfStorFree  = [long]`$hfStorage.FreeBytes
                } catch { `$null = `$_ }
                # See https://yuruna.link/42e5cdfd-0045
                `$hfAccess = @{ framework = ''; project = '' }
                `$hfState  = @{ framework = ''; project = '' }
                `$hfLink   = @{ framework = ''; project = '' }
                `$hfProbeQueue = @()
                if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.HostGit.psm1' -RequiredCommand 'Get-HostRepositoryAccess') {
                    `$hfUrl = @{ framework = ''; project = '' }
                    if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.Config.psm1' -RequiredCommand @('Read-TestConfig', 'Get-TestConfigValue')) {
                        try {
                            `$hfCfg = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml')
                            `$hfUrl.framework = "`$(Get-TestConfigValue -Config `$hfCfg -Path 'repositories.frameworkUrl')".Trim()
                            `$hfUrl.project   = "`$(Get-TestConfigValue -Config `$hfCfg -Path 'repositories.projectUrl')".Trim()
                        } catch { `$null = `$_ }
                    }
                    foreach (`$hfRepo in @(
                        @{ Key = 'framework'; Dir = `$repoRoot },
                        @{ Key = 'project';   Dir = (Join-Path `$repoRoot 'project') })) {
                        `$hfRead = Get-HostRepositoryAccess -RepoDir `$hfRepo.Dir -ConfiguredUrl `$hfUrl[`$hfRepo.Key]
                        if (`$hfRead.Source -ne 'unprobed') {
                            `$hfAccess[`$hfRepo.Key] = `$hfRead.Access
                            `$hfState[`$hfRepo.Key]  = `$hfRead.AccessState
                            `$hfLink[`$hfRepo.Key]   = `$hfRead.Url
                            `$repoAccessCache.Remove(`$hfRepo.Key)
                            continue
                        }
                        `$hfHit = `$repoAccessCache[`$hfRepo.Key]
                        if (`$hfHit -and ((Get-Date) - `$hfHit.At) -lt `$repoAccessCacheTtl -and `$hfHit.Url -eq `$hfUrl[`$hfRepo.Key]) {
                            `$hfAccess[`$hfRepo.Key] = `$hfHit.Access
                            `$hfState[`$hfRepo.Key]  = `$hfHit.State
                            `$hfLink[`$hfRepo.Key]   = `$hfHit.Link
                        } else {
                            `$hfProbeQueue += @{ Key = `$hfRepo.Key; Dir = `$hfRepo.Dir; Url = `$hfUrl[`$hfRepo.Key] }
                        }
                    }
                }
                `$payload = @{
                    ok                = `$true
                    memoryBytes       = `$hfMemory
                    cores             = `$hfCores
                    storageTotalBytes = `$hfStorTotal
                    storageFreeBytes  = `$hfStorFree
                    frameworkAccess   = `$hfAccess.framework
                    projectAccess     = `$hfAccess.project
                    frameworkAccessState = `$hfState.framework
                    projectAccessState   = `$hfState.project
                    frameworkUrl      = `$hfLink.framework
                    projectUrl        = `$hfLink.project
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                # Deliberately after the response: this is the network probe,
                # and the caller's budget covers the whole lab (see
                # `$repoAccessCache). A host with no clone of a configured
                # repository is the only case that reaches here.
                foreach (`$hfQ in `$hfProbeQueue) {
                    try {
                        `$hfProbe = Get-HostRepositoryAccess -RepoDir `$hfQ.Dir -ConfiguredUrl `$hfQ.Url -Probe -TimeoutSeconds 20
                        # Url is the configured value this entry answers FOR (the
                        # key the next request re-checks it against); Link is the
                        # linkable form of it that the answer carries.
                        `$repoAccessCache[`$hfQ.Key] = @{ Access = `$hfProbe.Access; State = `$hfProbe.AccessState; Link = `$hfProbe.Url; Url = `$hfQ.Url; At = (Get-Date) }
                    } catch {
                        Write-ServerErr "host-facts `$(`$hfQ.Key) access probe failed: `$(`$_.Exception.Message)"
                    }
                }
                continue
            }

            # --- REGION: /control/perf-aggregates: per-sequence cycle durations for performance.html
            # GET  -> cached aggregates (computes on first call).
            # POST -> clear the cache then return fresh aggregates.
            if (`$path -eq 'control/perf-aggregates') {
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.Headers.Add('Allow', 'GET, POST')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_be4fb6a2'
                    continue
                }
                if (`$req.HttpMethod -eq 'POST') {
                    `$perfAggregatesCache = `$null
                    `$perfAggregatesBytes = `$null
                }
                if (`$null -eq `$perfAggregatesCache) {
                    # Same cap that bounds status.json's history[] (the
                    # "Recent Cycles" list on the dashboard). Read from
                    # test.config.yml so the constant lives in exactly
                    # one place; Invoke-TestRunnerInnerLoop uses the same
                    # path for its Complete-Run -MaxHistoryRuns.
                    `$recentLimit = 30
                    try {
                        `$testConfigFile = Join-Path `$repoRoot 'test/test.config.yml'
                        `$doc = Read-TestConfig -Path `$testConfigFile
                        if (`$doc -and (`$doc.testCycle -is [System.Collections.IDictionary]) -and `$doc.testCycle.Contains('recentDisplayCount')) {
                            `$v = [int]`$doc.testCycle.recentDisplayCount
                            if (`$v -gt 0) { `$recentLimit = `$v }
                        }
                    } catch {
                        Write-ServerErr "perf-aggregates: could not read recentDisplayCount: `$(`$_.Exception.Message)"
                    }
                    `$cyclesDir = Join-Path `$statusDir 'perf/cycles'
                    `$perfRows = [Collections.Generic.List[object]]::new()
                    if (Test-Path -LiteralPath `$cyclesDir) {
                        `$jsonlFiles = @(Get-ChildItem -LiteralPath `$cyclesDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
                                          Sort-Object Name -Descending |
                                          Select-Object -First `$recentLimit)
                        foreach (`$f in `$jsonlFiles) {
                            try {
                                `$reader = [System.IO.StreamReader]::new(`$f.FullName)
                                try {
                                    while (-not `$reader.EndOfStream) {
                                        `$line = `$reader.ReadLine()
                                        if ([string]::IsNullOrWhiteSpace(`$line)) { continue }
                                        try { `$row = `$line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                                        if (`$row.sequenceName -and `$row.cycleStartUtc) { `$perfRows.Add(`$row) }
                                    }
                                } finally { `$reader.Close() }
                            } catch {
                                Write-ServerErr "perf-aggregates: failed to read `$(`$f.FullName): `$(`$_.Exception.Message)"
                            }
                        }
                    }
                    `$sequences = ConvertTo-PerfSequenceAggregate -Row @(`$perfRows)
                    # Execution IDs join console and SSH checkpoints. Older
                    # sidecars use host reception time within the step window.
                    # Newest-first prefers the latest capture; Consumed prevents
                    # two step rows from claiming the same execution evidence.
                    `$ckptDir2 = Join-Path `$statusDir 'perf/checkpoints'
                    `$ckptSidecars = New-Object System.Collections.ArrayList
                    if (Test-Path -LiteralPath `$ckptDir2) {
                        `$scFiles = @(Get-ChildItem -LiteralPath `$ckptDir2 -Filter '*.json' -File -ErrorAction SilentlyContinue |
                                       Sort-Object Name -Descending | Select-Object -First 1000)
                        foreach (`$sc in `$scFiles) {
                            try {
                                `$scDoc = Get-Content -LiteralPath `$sc.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                            } catch { continue }
                            if (-not `$scDoc.receivedAtUtc) { continue }
                            `$rcvd = [DateTime]::MinValue
                            try {
                                # Same [DateTime]-not-text rule as the step window above: the
                                # sidecar field arrives already materialized, and re-parsing its
                                # culture-formatted text drops the fractional second the window
                                # comparison below needs.
                                `$rcvd = [DateTime]::SpecifyKind(([DateTime]`$scDoc.receivedAtUtc).ToUniversalTime(), [DateTimeKind]::Utc)
                            } catch { continue }
                            `$null = `$ckptSidecars.Add([pscustomobject]@{
                                ReceivedAt  = `$rcvd
                                Checkpoints = `$scDoc.checkpoints
                                StepInvocationId = [string]`$scDoc.stepInvocationId
                                SequenceInvocationId = [string]`$scDoc.sequenceInvocationId
                                Consumed    = `$false
                            })
                        }
                    }
                    `$sidecarArray = `$ckptSidecars.ToArray()
                    `$out = [ordered]@{}
                    foreach (`$seq in (`$sequences.Keys | Sort-Object)) {
                        `$cyclesArr = @(`$sequences[`$seq])
                        # See https://yuruna.link/42e5cdfd-0045
                        foreach (`$cyc2 in `$cyclesArr) {
                            `$sortedSteps = @(`$cyc2.steps | Sort-Object -Stable @{Expression={ if (`$null -ne `$_.startedMs) { [long]`$_.startedMs } else { [long]0 } }})
                            foreach (`$st2 in `$sortedSteps) {
                                if ("`$(`$st2.kind)" -notin @('fetchAndExecute', 'sshFetchAndExecute')) { continue }
                                `$candidate = Find-PerfCheckpoint -Step `$st2 -Sidecar `$sidecarArray
                                if (`$candidate) {
                                    `$candidate.Consumed = `$true
                                    `$st2.checkpoints = @(`$candidate.Checkpoints)
                                }
                            }
                            `$cyc2.steps = `$sortedSteps
                        }
                        `$out[`$seq] = `$cyclesArr
                    }
                    `$perfAggregatesCache = [ordered]@{
                        generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
                        recentLimit    = `$recentLimit
                        sequences      = `$out
                    }
                    # See https://yuruna.link/42e5cdfd-0045
                    `$json = `$perfAggregatesCache | ConvertTo-Json -Depth 8 -Compress
                    `$perfAggregatesBytes = [System.Text.Encoding]::UTF8.GetBytes(`$json)
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$res.ContentLength64 = `$perfAggregatesBytes.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$perfAggregatesBytes, 0, `$perfAggregatesBytes.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/perf-checkpoints: guest-pushed fetch-and-execute phase timings
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/perf-checkpoints') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_post_the_checkpoint_body_85c8aecf'
                    continue
                }
                if (`$req.ContentLength64 -gt 256KB) {
                    Send-JsonError -Response `$res -StatusCode 413 -Request `$req -Key 'status.api_payload_too_large_256_kb_ad49d5cd'
                    continue
                }
                `$rawBody = ''
                try {
                    `$reader = [System.IO.StreamReader]::new(`$req.InputStream, `$req.ContentEncoding)
                    try { `$rawBody = `$reader.ReadToEnd() } finally { `$reader.Close() }
                } catch { `$rawBody = '' }
                `$parsed = `$null
                try { `$parsed = `$rawBody | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { `$parsed = `$null }
                if (`$null -eq `$parsed -or -not (`$parsed -is [System.Collections.IDictionary])) {
                    Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_body_must_be_a_json_object_831ab327'
                    continue
                }
                # Bounded, validated copy of the checkpoint list (max 500;
                # name <= 200 chars; offsetMs a non-negative int). Off-shape
                # entries are dropped, not rejected, so a partial run still
                # records the checkpoints it did capture.
                `$cleanCkpts = New-Object System.Collections.ArrayList
                if (`$parsed.Contains('checkpoints') -and (`$parsed.checkpoints -is [System.Collections.IEnumerable])) {
                    foreach (`$ck in `$parsed.checkpoints) {
                        if (`$cleanCkpts.Count -ge 500) { break }
                        if (-not (`$ck -is [System.Collections.IDictionary])) { continue }
                        `$nm = ''
                        if (`$ck.Contains('name') -and `$null -ne `$ck.name) { `$nm = [string]`$ck.name }
                        if (`$nm.Length -gt 200) { `$nm = `$nm.Substring(0, 200) }
                        if ([string]::IsNullOrWhiteSpace(`$nm)) { continue }
                        `$off = 0
                        try { `$off = [int]`$ck.offsetMs } catch { `$off = 0 }
                        if (`$off -lt 0) { `$off = 0 }
                        `$null = `$cleanCkpts.Add([ordered]@{ name = `$nm; offsetMs = `$off })
                    }
                }
                `$scriptPathIn = ''
                if (`$parsed.Contains('scriptPath') -and `$null -ne `$parsed.scriptPath) { `$scriptPathIn = [string]`$parsed.scriptPath }
                if (`$scriptPathIn.Length -gt 400) { `$scriptPathIn = `$scriptPathIn.Substring(0, 400) }
                `$srcTag = ''
                if (`$parsed.Contains('source') -and `$null -ne `$parsed.source) { `$srcTag = [string]`$parsed.source }
                `$guestHost = ''
                if (`$parsed.Contains('hostname') -and `$null -ne `$parsed.hostname) { `$guestHost = [string]`$parsed.hostname }
                `$ckptExit = 0
                try { if (`$parsed.Contains('exitCode')) { `$ckptExit = [int]`$parsed.exitCode } } catch { `$ckptExit = 0 }
                `$remoteIp = ''
                try { `$remoteIp = `$req.RemoteEndPoint.Address.ToString() } catch { `$remoteIp = '' }

                `$receivedUtc = [DateTime]::UtcNow.ToString('o')
                `$sidecar = [ordered]@{
                    schema        = 1
                    receivedAtUtc = `$receivedUtc
                    remoteIp      = `$remoteIp
                    scriptPath    = `$scriptPathIn
                    source        = `$srcTag
                    hostname      = `$guestHost
                    exitCode      = `$ckptExit
                    checkpoints   = @(`$cleanCkpts)
                }
                foreach (`$identityField in 'stepInvocationId', 'sequenceInvocationId') {
                    if (`$parsed.Contains(`$identityField) -and [string]`$parsed[`$identityField] -match '^[0-9a-fA-F]{32}$') {
                        `$sidecar[`$identityField] = [string]`$parsed[`$identityField]
                    }
                }

                `$ckptDir = Join-Path `$statusDir 'perf/checkpoints'
                `$writeOk = `$false
                try {
                    if (-not (Test-Path -LiteralPath `$ckptDir)) {
                        `$null = New-Item -ItemType Directory -Path `$ckptDir -Force -ErrorAction SilentlyContinue
                    }
                    # ':' is illegal in Windows filenames, so the ISO arrival
                    # stamp gets colons -> hyphens (same transform Test.Perf uses
                    # for cycle JSONL names); the receivedAtUtc field inside keeps
                    # the untouched ISO for the window comparison.
                    `$safeStamp   = `$receivedUtc -replace ':', '-'
                    `$tail        = ([Guid]::NewGuid().ToString('N')).Substring(0, 4)
                    `$ckptFile    = Join-Path `$ckptDir "`${safeStamp}__`${tail}.json"
                    # The checkpoint filename already carries a per-write stamp+guid, so
                    # its .tmp sibling is unique per writer without a further suffix.
                    `$tmpFile     = "`$ckptFile.tmp"
                    `$sidecarJson = `$sidecar | ConvertTo-Json -Depth 6 -Compress
                    [System.IO.File]::WriteAllText(`$tmpFile, `$sidecarJson)
                    [System.IO.File]::Move(`$tmpFile, `$ckptFile, `$true)
                    `$writeOk = `$true
                    # Light retention: keep the newest ~500 sidecars so the
                    # directory can't grow without bound across many cycles.
                    `$allCkpts = @(Get-ChildItem -LiteralPath `$ckptDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                    if (`$allCkpts.Count -gt 500) {
                        foreach (`$old in (`$allCkpts | Select-Object -Skip 500)) {
                            Remove-Item -LiteralPath `$old.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                } catch {
                    Write-ServerErr "perf-checkpoints: write failed: `$(`$_.Exception.Message)"
                }
                if (-not `$writeOk) {
                    Send-JsonError -Response `$res -StatusCode 500 -Request `$req -Key 'status.api_sidecar_write_failed_0ce361a9'
                    continue
                }
                # Fresh checkpoint data invalidates the memoized aggregates so the
                # next GET re-runs the join (mirrors the POST-recalc invalidation).
                `$perfAggregatesCache = `$null
                `$perfAggregatesBytes = `$null
                `$payloadOut = '{"ok":true,"checkpoints":' + `$cleanCkpts.Count + '}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payloadOut)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/test-caching-proxy-service (POST ?ip=<ip>): probe a caching-proxy service from the host
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/test-caching-proxy-service') {
                # POST-only: this drives a live host-side outbound probe to an
                # operator-supplied target, so it must not be reachable via a
                # simple GET (e.g. a foreign page's <img src>). The ?ip= query
                # is still honored on the POST.
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_be4fb6a2'
                    continue
                }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$ipQ = `$req.QueryString['ip']
                if (`$null -eq `$ipQ) { `$ipQ = '' }
                `$ipQ = "`$ipQ".Trim()
                `$ipValid = `$false
                if (`$ipQ) {
                    try { `$ipValid = [bool](Test-IpAddress `$ipQ) } catch { `$ipValid = `$false }
                }
                # SSRF containment: the probe makes host-side TCP connects and
                # an HTTP fetch against the requested target, so only targets
                # that can plausibly be this lab's cache VM are accepted --
                # loopback/RFC1918/link-local space or the operator-configured
                # external cache IP. Public addresses are refused.
                if (`$ipValid) {
                    `$ipAllowed = `$false
                    `$parsedIp = `$null
                    if ([System.Net.IPAddress]::TryParse(`$ipQ, [ref]`$parsedIp)) {
                        if ([System.Net.IPAddress]::IsLoopback(`$parsedIp)) { `$ipAllowed = `$true }
                        elseif (`$parsedIp.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                            `$b = `$parsedIp.GetAddressBytes()
                            `$ipAllowed = ((`$b[0] -eq 10) -or
                                          (`$b[0] -eq 172 -and `$b[1] -ge 16 -and `$b[1] -le 31) -or
                                          (`$b[0] -eq 192 -and `$b[1] -eq 168) -or
                                          (`$b[0] -eq 169 -and `$b[1] -eq 254))
                        }
                        elseif (`$parsedIp.IsIPv6LinkLocal -or `$parsedIp.IsIPv6UniqueLocal) { `$ipAllowed = `$true }
                    }
                    if (-not `$ipAllowed -and `$env:YURUNA_CACHING_PROXY_SERVICE_IP -and (`$ipQ -eq "`$env:YURUNA_CACHING_PROXY_SERVICE_IP".Trim())) { `$ipAllowed = `$true }
                    if (-not `$ipAllowed) {
                        Send-JsonError -Response `$res -StatusCode 403 -Request `$req -Key 'status.api_forbidden_probe_target_must_be_a_private_loopback_rfc1_2c763dac'
                        continue
                    }
                }
                if (-not `$ipValid) {
                    `$payload = [pscustomobject]@{
                        ok                 = `$true
                        ip                 = `$ipQ
                        valid              = `$false
                        success            = `$false
                        httpProxyReachable = `$false
                        passCount          = 0
                        warnCount          = 0
                        failCount          = 0
                        lines              = @()
                    } | ConvertTo-Json -Compress -Depth 4
                } else {
                    try {
                        `$probe = Invoke-CachingProxyServiceProbe -CacheIp `$ipQ -CacheSource 'status-service /control/test-caching-proxy-service'
                        `$payload = [pscustomobject]@{
                            ok                 = `$true
                            ip                 = `$ipQ
                            valid              = `$true
                            success            = [bool]`$probe.Success
                            httpProxyReachable = [bool]`$probe.HttpProxyReachable
                            passCount          = [int]`$probe.PassCount
                            warnCount          = [int]`$probe.WarnCount
                            failCount          = [int]`$probe.FailCount
                            lines              = @(`$probe.Lines)
                        } | ConvertTo-Json -Compress -Depth 4
                    } catch {
                        `$errMsg = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        `$payload = '{"ok":false,"ip":"' + (`$ipQ -replace '\\','\\' -replace '"','\"') + '","valid":true,"error":"' + `$errMsg + '"}'
                        Write-ServerErr "test-caching-proxy-service probe failed for `${ipQ}: `$errMsg"
                    }
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/guest-folders: list guest.* dirs under current host
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/guest-folders') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$guests = @()
                if (`$serverHostType) {
                    `$hostFolderName = `$serverHostType -replace '^host\.', ''
                    `$hostPath = Join-Path `$repoRoot ('host/' + `$hostFolderName)
                    if (Test-Path -LiteralPath `$hostPath) {
                        `$guests = @(Get-ChildItem -LiteralPath `$hostPath -Directory -Filter 'guest.*' -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty Name | Sort-Object)
                    }
                }
                # See https://yuruna.link/42e5cdfd-0045
                `$items = @(`$guests | ForEach-Object { '"' + (`$_ -replace '\\','\\\\' -replace '"','\"') + '"' })
                `$payload = '[' + (`$items -join ',') + ']'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/runner-status: is Start-TestRunner actually alive?
            # Verifies <runtime>/runner.pid really is the outer runner
            # (runner.start StartTime sidecar preferred; cmdline-regex
            # fallback) and returns { running: bool, pid: int|null }.
            # See docs/control-routes.md (GET /control/runner-status).
            if (`$path -eq 'control/runner-status') {
                `$rs      = Test-RunnerAlive
                `$running = `$rs.Running
                `$pidVal  = `$rs.RunnerPid
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                # --- REGION: Liveness
                # See https://yuruna.link/42e5cdfd-0045
                `$hbAge = `$null; `$phaseVal = `$null; `$liveness = 'unknown'; `$lapsed = `$null
                # This handler body runs in a long-lived loop runspace, so every
                # value the payload reports has to be cleared per request: a probe
                # that throws before the bound is resolved would otherwise print
                # the PREVIOUS poll's number next to a fresh verdict.
                `$bound = `$null; `$runState = `$null
                try {
                    `$hbPath = Join-Path `$runtimeDir 'runner.stepHeartbeat'
                    if (Test-Path -LiteralPath `$hbPath) {
                        `$hbAge = [int]((Get-Date) - (Get-Item -LiteralPath `$hbPath).LastWriteTime).TotalSeconds
                    }
                    `$phasePath = Join-Path `$runtimeDir 'runner.phase'
                    if (Test-Path -LiteralPath `$phasePath) {
                        `$phaseVal = "`$(Get-Content -LiteralPath `$phasePath -Raw)".Trim()
                    }
                    `$lapsePath = Join-Path `$runtimeDir 'runner.watchdog.lapsed'
                    if (Test-Path -LiteralPath `$lapsePath) {
                        `$lapsed = "`$(Get-Content -LiteralPath `$lapsePath -Raw)".Trim()
                    }
                    # See https://yuruna.link/42e5cdfd-0045
                    `$statePath = Join-Path `$runtimeDir 'runner.state.json'
                    if (Test-Path -LiteralPath `$statePath) {
                        try {
                            `$stateRaw = Get-Content -LiteralPath `$statePath -Raw
                            if (`$stateRaw -and `$stateRaw.Trim()) {
                                `$runState = "`$((`$stateRaw | ConvertFrom-Json).current)".Trim()
                            }
                        } catch { Write-Debug "runner-status: runner.state.json read failed: `$(`$_.Exception.Message)" }
                    }
                    # See https://yuruna.link/42e5cdfd-0045
                    `$stepBound = 2700; `$preBound = 600
                    try {
                        `$cfgLive = Read-TestConfig -Path `$serverConfigPath
                        `$sv = Get-TestConfigValue -Config `$cfgLive -Path 'testCycle.stepTimeoutSeconds'
                        `$pv = Get-TestConfigValue -Config `$cfgLive -Path 'testCycle.preambleTimeoutSeconds'
                        `$tmp = 0
                        if (`$null -ne `$sv -and [int]::TryParse("`$sv".Trim(), [ref]`$tmp) -and `$tmp -gt 0) { `$stepBound = `$tmp }
                        `$tmp = 0
                        if (`$null -ne `$pv -and [int]::TryParse("`$pv".Trim(), [ref]`$tmp) -and `$tmp -ge 0) { `$preBound = `$tmp }
                    } catch { Write-Debug "runner-status: config read failed: `$(`$_.Exception.Message)" }
                    `$bound = if (`$phaseVal -and `$preBound -gt 0 -and `$preBound -lt `$stepBound) { `$preBound } else { `$stepBound }
                    # See https://yuruna.link/42e5cdfd-0045
                    `$liveness = if (-not `$running)          { 'idle' }
                                elseif (`$runState -eq 'paused') { 'paused' }
                                elseif (`$null -eq `$hbAge)   { 'unknown' }
                                elseif (`$hbAge -gt `$bound)  { 'stalled' }
                                elseif (`$hbAge -gt (`$bound / 2)) { 'slow' }
                                else                          { 'ok' }
                } catch {
                    Write-ServerErr "runner-status liveness probe failed: `$(`$_.Exception.Message)"
                }
                `$payload = @{
                    running                 = `$running
                    pid                     = `$pidVal
                    liveness                = `$liveness
                    phase                   = `$phaseVal
                    stepHeartbeatAgeSeconds = `$hbAge
                    boundSeconds            = `$bound
                    watchdogLapsed          = `$lapsed
                    runnerState             = `$runState
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/control-status: can this host be driven remotely?
            # See https://yuruna.link/42185271-000c
            if (`$path -eq 'control/control-status') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$controlIdentity = Get-ControlIdentityCached
                `$csToken = `$controlIdentity.Token
                `$csTag = `$controlIdentity.Tag
                # The caller's vantage rides along so the page can tell whether
                # its Start button can work at all from here: a non-loopback
                # press needs the refresh proof header, which the dashboard
                # never carries, so a remote page offers watching instead of a
                # press that can only be refused. Copied before the field is
                # added; the summary parts are cached and shared.
                `$refreshStatusSummary = [ordered]@{}
                foreach (`$refreshPair in (Get-HostRefreshSummaryCached).GetEnumerator()) { `$refreshStatusSummary[`$refreshPair.Key] = `$refreshPair.Value }
                `$refreshCallerLoopback = `$false
                try { `$refreshCallerLoopback = [System.Net.IPAddress]::IsLoopback(`$req.RemoteEndPoint.Address) } catch { `$refreshCallerLoopback = `$false }
                `$refreshStatusSummary['caller'] = if (`$refreshCallerLoopback) { 'loopback' } else { 'remote' }
                # See https://yuruna.link/42e5cdfd-0045
                `$payload = @{
                    ok              = `$true
                    tokenConfigured = (-not [string]::IsNullOrWhiteSpace(`$csToken))
                    tokenTag        = `$csTag
                    utcNow          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
                    refresh         = `$refreshStatusSummary
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/host-diagnostic: detached, single-flight host diagnostic
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/host-diagnostic') {
                `$diagnosticLocale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                try {
                    if (-not (Test-StatusRouteReady -Route 'host-diagnostic').Ready) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'listener_dependency_missing' }) ``
                            -MessageKey 'status.api_listener_dependency_missing'
                        continue
                    }
                    `$diagnosticDirectory = Get-StatusWorkerDirectory -Name 'host-diagnostic' -ServedRoot `$servedRootSet -Confirm:`$false
                    if (-not `$diagnosticDirectory.Resolved) {
                        `$privateReason = ([string]`$diagnosticDirectory.Reason).Replace('-', '_')
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'private_state_unavailable' }) ``
                            -MessageKey 'status.api_private_state_unavailable' -MessageArguments @{ reason = `$privateReason }
                        continue
                    }
                    `$diagnosticText = `$null
                    `$diagnosticCode = ''
                    if (-not [System.IO.File]::Exists(`$diagScriptPath)) {
                        `$diagnosticCode = 'status.api_diagnostic_script_missing'
                        `$diagnosticText = Format-CatalogMessage -Key `$diagnosticCode -Locale `$diagnosticLocale.Tag -Arguments @{ path = `$diagScriptPath }
                    } else {
                        `$diagnosticState = Get-HostDiagnosticRouteState -WorkDirectory `$diagnosticDirectory.Path -NowUtc ([DateTime]::UtcNow) ``
                            -LastSpawnUtc `$script:HostDiagSpawnUtc -LastSpawnRunId ([string]`$script:HostDiagSpawnRunId)
                        if (`$diagnosticState.Action -eq 'serve') {
                            `$diagnosticText = [System.IO.File]::ReadAllText(`$diagnosticState.ResultPath)
                        } elseif (`$diagnosticState.Action -eq 'serve_failure') {
                            `$diagnosticCode = 'status.api_diagnostic_failed'
                            `$diagnosticText = Format-CatalogMessage -Key `$diagnosticCode -Locale `$diagnosticLocale.Tag -Arguments @{ detail = [string]`$diagnosticState.FailureReason }
                        } else {
                            `$diagnosticRunId = [string]`$diagnosticState.RunId
                            if (`$diagnosticState.Action -eq 'spawn') {
                                `$diagnosticRunId = New-StatusOperationId
                                `$diagnosticLaunch = Start-StatusWorker -Directory `$diagnosticDirectory.Path -StdInPath `$diagnosticDirectory.StdInPath ``
                                    -ScriptPath `$hostDiagnosticWorker -TranscriptStem `$diagnosticRunId ``
                                    -ArgumentList @('-RunId', `$diagnosticRunId, '-DiagnosticScriptPath', `$diagScriptPath, '-WorkDirectory', `$diagnosticDirectory.Path, '-WorkingDirectory', `$repoRoot)
                                if (-not `$diagnosticLaunch.Launched) {
                                    `$launchReason = ([string]`$diagnosticLaunch.Reason).Replace('-', '_')
                                    Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'launcher_failed' }) ``
                                        -MessageKey 'status.api_worker_launcher_failed' -MessageArguments @{ reason = `$launchReason }
                                    continue
                                }
                                `$script:HostDiagSpawnUtc = [DateTime]::UtcNow
                                `$script:HostDiagSpawnRunId = `$diagnosticRunId
                            }
                            Send-JsonReply -Response `$res -Request `$req -StatusCode 202 -RetryAfter '3' ``
                                -Body ([ordered]@{ ok = `$true; action = 'pending'; runId = `$diagnosticRunId; retryAfterSeconds = 3 })
                            continue
                        }
                    }
                    `$res.StatusCode = 200
                    `$res.ContentType = 'text/plain; charset=utf-8'
                    `$res.Headers.Set('Cache-Control', 'no-store')
                    if (`$diagnosticCode) {
                        Set-ResponseLocaleHeaders -Response `$res -Locale `$diagnosticLocale
                        `$res.Headers.Set('X-Yuruna-Message-Code', `$diagnosticCode)
                    }
                    `$reportBytes = [System.Text.Encoding]::UTF8.GetBytes([string]`$diagnosticText)
                    `$res.ContentLength64 = `$reportBytes.Length
                    if (`$req.HttpMethod -ne 'HEAD') {
                        `$res.OutputStream.Write(`$reportBytes, 0, `$reportBytes.Length)
                    }
                    `$res.OutputStream.Close()
                } catch {
                    Write-ServerErr "host-diagnostic failed: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
                    try {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 500 -Body ([ordered]@{ ok = `$false; reason = 'internal_error' }) -MessageKey 'status.api_internal_error'
                    } catch {
                        Write-ServerErr "host-diagnostic reply failed: `$(`$_.Exception.Message)"
                        try { `$res.Abort() } catch { Write-Debug `$_ }
                    }
                }
                continue
            }

            # --- REGION: /control/host-aliases: networkStorage server names -> IPs as THIS host resolves them
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/host-aliases') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'GET' -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.StatusCode = 405
                    `$res.Headers.Add('Allow', 'GET')
                    `$bytes = (Get-StatusMessageBytes -Request `$req -Response `$res -Key 'status.api_method_not_allowed_be4fb6a2' -Json)
                } elseif (-not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.PoolStorage.psm1' -RequiredCommand 'Get-PoolStorageServerName') -or
                          -not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.Config.psm1'      -RequiredCommand 'Read-TestConfig')) {
                    `$res.StatusCode = 500
                    `$bytes = (Get-StatusMessageBytes -Request `$req -Response `$res -Key 'status.api_test_poolstorage_test_config_could_not_be_loaded_in_th_108a1c6c' -Json)
                } else {
                    try {
                        `$doc = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml') -ThrowOnError
                        `$ns  = if (`$doc -is [System.Collections.IDictionary]) { `$doc['networkStorage'] } else { `$null }
                        `$aliases    = [ordered]@{}
                        `$unresolved = [System.Collections.Generic.List[string]]::new()
                        if (`$ns -is [System.Collections.IDictionary]) {
                            foreach (`$npKey in @('poolStorageNetworkPath', 'stashStorageNetworkPath')) {
                                `$np = if (`$ns.Contains(`$npKey)) { "`$(`$ns[`$npKey])".Trim() } else { '' }
                                if (-not `$np) { continue }
                                `$server = Get-PoolStorageServerName -NetworkPath `$np
                                if (-not `$server -or `$aliases.Contains(`$server) -or `$unresolved.Contains(`$server)) { continue }
                                try {
                                    `$addrs = [System.Net.Dns]::GetHostAddresses(`$server)
                                    `$pick = `$addrs | Where-Object { `$_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
                                    if (-not `$pick) { `$pick = `$addrs | Select-Object -First 1 }
                                    if (`$pick) { `$aliases[`$server] = `$pick.ToString() } else { [void]`$unresolved.Add(`$server) }
                                } catch {
                                    [void]`$unresolved.Add(`$server)
                                }
                            }
                        }
                        `$payload = @{ ok = `$true; aliases = `$aliases; unresolved = @(`$unresolved) } | ConvertTo-Json -Compress -Depth 5
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                    } catch {
                        `$res.StatusCode = 500
                        `$errMsg = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        `$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"error":"' + `$errMsg + '"}')
                    }
                }
                `$res.ContentLength64 = `$bytes.Length
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/vault-credential: token-gated networkStorage credential for a peer host
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/vault-credential') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$vcStatus = 200
                `$vcError  = `$null
                `$vcCode = 'status.api_detail_caf3c2c2'
                `$vcLocale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                Set-ResponseLocaleHeaders -Response `$res -Locale `$vcLocale
                `$qUser  = `$req.QueryString['user']
                `$qNonce = `$req.QueryString['nonce']
                `$qProof = `$req.QueryString['proof']
                if (`$req.HttpMethod -ne 'GET') {
                    `$vcStatus = 405; `$vcCode = 'status.api_method_not_allowed_be4fb6a2'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                    `$res.Headers.Add('Allow', 'GET')
                } elseif (-not `$qUser -or -not `$qNonce -or -not `$qProof) {
                    `$vcStatus = 400; `$vcCode = 'status.api_user_nonce_and_proof_query_parameters_are_required_1a7f21f9'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                } elseif (-not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.ConfigServiceSync.psm1' -RequiredCommand 'Test-ConfigSyncProof', 'Protect-ConfigSyncCredential', 'Get-InternalAuthKeyValue') -or
                          -not (Import-RouteModule -ModuleRelativePath 'test/modules/Test.Config.psm1'        -RequiredCommand 'Read-TestConfig')) {
                    `$vcStatus = 500; `$vcCode = 'status.api_test_configservicesync_test_config_could_not_be_loaded_084ff97c'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                }
                if (-not `$vcError) {
                    # Lazy authentication-extension load: the vault only has
                    # to be readable when a peer actually asks. Import-Extension
                    # itself comes from a best-effort startup import, so recover
                    # it the same way rather than reporting the vault as
                    # unavailable when only its loader went missing.
                    if (Import-RouteModule -ModuleRelativePath 'test/modules/Test.Extension.psm1' -RequiredCommand 'Import-Extension') {
                        try { `$null = Import-Extension -Area 'authentication' -RequireSingle } catch { `$null = `$_ }
                    }
                    if (-not (Get-Command Get-EffectiveUser -ErrorAction SilentlyContinue) -or
                        -not (Get-Command Test-VaultEntry -ErrorAction SilentlyContinue)) {
                        `$vcStatus = 503; `$vcCode = 'status.api_authentication_extension_unavailable_2ece9896'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                    }
                }
                if (-not `$vcError) {
                    try {
                        `$doc = Read-TestConfig -Path (Join-Path `$repoRoot 'test/test.config.yml') -ThrowOnError
                        `$ns  = if (`$doc -is [System.Collections.IDictionary]) { `$doc['networkStorage'] } else { `$null }
                        `$allowed = [System.Collections.Generic.List[string]]::new()
                        if (`$ns -is [System.Collections.IDictionary]) {
                            foreach (`$nuKey in @('poolStorageNetworkUser', 'stashStorageNetworkUser')) {
                                `$nu = if (`$ns.Contains(`$nuKey)) { "`$(`$ns[`$nuKey])".Trim() } else { '' }
                                if (`$nu) { [void]`$allowed.Add(`$nu) }
                            }
                        }
                        if (-not `$allowed.Contains([string]`$qUser)) {
                            `$vcStatus = 404; `$vcCode = 'status.api_user_not_referenced_by_this_host_s_networkstorage_conf_08561dd3'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                        } else {
                            # Legacy-name fallback included: a host still holding
                            # its token under 'pool-auth-token' keeps serving peers.
                            `$vcToken = Get-InternalAuthKeyValue
                            if (-not `$vcToken) {
                                `$vcStatus = 503; `$vcCode = 'status.api_internal_authentication_key_not_configured_on_this_hos_db3031f0'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                            } else {
                                if (-not (Test-ConfigSyncProof -Token `$vcToken -User `$qUser -Nonce `$qNonce -Proof `$qProof)) {
                                    `$vcStatus = 403; `$vcCode = 'status.api_proof_mismatch_wrong_or_stale_internal_authentication__9dcc8f9b'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                                } else {
                                    `$um = Get-EffectiveUser -LogicalUser `$qUser
                                    `$vcKey = if (`$um.vaultKey) { `$um.vaultKey } else { [string]`$qUser }
                                    if (-not (Test-VaultEntry -VaultKey `$vcKey)) {
                                        `$vcStatus = 404; `$vcCode = 'status.api_no_stored_credential_for_that_user_on_this_host_3f8ab13b'; `$vcError = Format-CatalogMessage -Key `$vcCode -Locale `$vcLocale.Tag
                                    } else {
                                        `$pw = Get-Password -Username `$qUser
                                        `$envelope = Protect-ConfigSyncCredential -Token `$vcToken -User `$qUser -ClientNonce `$qNonce -Password `$pw
                                        `$envelope['ok'] = `$true
                                        `$payload = `$envelope | ConvertTo-Json -Compress -Depth 3
                                    }
                                }
                            }
                        }
                    } catch {
                        `$vcStatus = 500
                        `$vcError = (ConvertTo-JsonEscapedString `$_.Exception.Message)
                        Write-ServerErr "vault-credential failed: `$vcError"
                    }
                }
                if (`$vcError) {
                    `$res.StatusCode = `$vcStatus
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ ok = `$false; code = `$vcCode; error = `$vcError } | ConvertTo-Json -Compress))
                } else {
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                }
                `$res.ContentLength64 = `$bytes.Length
                if (`$req.HttpMethod -ne 'HEAD') { `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: Control endpoints: Pause/Continue back-channel from UI
            # Flag-file semantics:
            # docs/control-routes.md#pause-and-resume-the-flag-file-back-channel
            if (`$path -eq 'control/step-pause' -or `$path -eq 'control/step-resume' -or
                `$path -eq 'control/cycle-pause' -or `$path -eq 'control/cycle-resume') {
                `$isCycle = (`$path -like 'control/cycle-*')
                `$desiredPaused = (`$path -like 'control/*-pause')
                `$targetFile = if (`$isCycle) { `$cyclePauseFile } else { `$stepPauseFile }
                `$fieldName  = if (`$isCycle) { 'cyclePaused' } else { 'stepPaused' }
                `$sinceField = if (`$isCycle) { 'cyclePausedSinceUtc' } else { 'stepPausedSinceUtc' }
                # Stamped here as well as into the flag file, because the runner's
                # own status write is what normally mirrors the two -- and during a
                # hold there are no step boundaries to trigger one. Without this the
                # dashboard would show a hold with no age for as long as it lasts,
                # which is exactly the reading that matters on a step-pause.
                `$sinceValue = ''
                try {
                    if (`$desiredPaused) {
                        `$sinceValue = (Get-Date -Format o)
                        Set-Content -Path `$targetFile -Value `$sinceValue -ErrorAction SilentlyContinue
                    } else {
                        Remove-Item `$targetFile -Force -ErrorAction SilentlyContinue
                    }
                } catch { Write-Debug `$_ }
                try {
                    # Read-modify-write: must read fresh from disk every
                    # time (a concurrent runner-side write would otherwise
                    # be silently clobbered if we returned a cached parse).
                    # [File]::ReadAllText skips the Get-Content cmdlet-
                    # binding / encoding-sniff overhead.
                    `$doc = [System.IO.File]::ReadAllText(`$statusJsonFile) | ConvertFrom-Json -AsHashtable
                    `$doc[`$fieldName] = `$desiredPaused
                    `$doc[`$sinceField] = `$sinceValue
                    `$tmp = "`$statusJsonFile.`$PID-`$([guid]::NewGuid().ToString('N')).tmp"
                    `$doc | ConvertTo-Json -Depth 20 | Set-Content -Path `$tmp -Encoding utf8
                    [System.IO.File]::Move(`$tmp, `$statusJsonFile, `$true)
                } catch { Write-Debug `$_ }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$pausedJson = if (`$desiredPaused) { 'true' } else { 'false' }
                `$payload = '{"ok":true,"' + `$fieldName + '":' + `$pausedJson + '}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/lab-hold-release: stop waiting on a lab service
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/lab-hold-release') {
                if (`$req.HttpMethod -ne 'POST') {
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_post_required_663cc07c'
                    continue
                }
                if (-not (Test-Path `$labHoldFile)) {
                    Send-JsonError -Response `$res -StatusCode 409 -Request `$req -Key 'status.api_no_lab_hold_is_active_49dd8185'
                    continue
                }
                try { Set-Content -Path `$labHoldReleaseFile -Value (Get-Date -Format o) -ErrorAction SilentlyContinue }
                catch { Write-Debug `$_ }
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = '{"ok":true,"labHoldRelease":true}'
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/break-continue: Continue-from-break button
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/break-continue') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_post_required_663cc07c'
                    continue
                }
                `$breakActiveFile   = Join-Path `$runtimeDir 'break-active.json'
                `$breakContinueFile = Join-Path `$runtimeDir 'control.break-continue'
                if (-not (Test-Path -LiteralPath `$breakActiveFile)) {
                    Send-JsonError -Response `$res -StatusCode 409 -Request `$req -Key 'status.api_no_break_active_bc29bdab'
                    continue
                }
                try {
                    Set-Content -Path `$breakContinueFile -Value (Get-Date -Format o) -ErrorAction Stop
                } catch {
                    Send-JsonError -Response `$res -StatusCode 500 -Request `$req -Key 'status.api_write_failed_detail_c07681e1' -Arguments @{ detail = `$_.Exception.Message }
                    continue
                }
                `$body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                `$res.ContentLength64 = `$body.Length
                `$res.OutputStream.Write(`$body, 0, `$body.Length)
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /control/start-cycle: queue the save-and-restart worker
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/start-cycle') {
                try {
                    if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                        `$res.ContentType = 'application/json; charset=utf-8'
                        `$res.Headers.Add('Cache-Control', 'no-store')
                        Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_post_required_663cc07c'
                        continue
                    }
                    if (-not (Test-StatusRouteReady -Route 'start-cycle').Ready) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Body ([ordered]@{ ok = `$false; reason = 'listener_dependency_missing' }) ``
                            -MessageKey 'status.api_listener_dependency_missing'
                        continue
                    }
                    Invoke-StartCycleRequest -Request `$req -Response `$res
                } catch {
                    Write-ServerErr "start-cycle failed: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
                    try {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 500 -Body ([ordered]@{ ok = `$false; reason = 'internal_error' }) -MessageKey 'status.api_internal_error'
                    } catch {
                        Write-ServerErr "start-cycle reply failed: `$(`$_.Exception.Message)"
                        try { `$res.Abort() } catch { Write-Debug `$_ }
                    }
                }
                continue
            }

            # --- REGION: /control/host-refresh: bounded admission and detached repair worker
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'control/host-refresh') {
                try {
                    if (`$req.HttpMethod -ne 'POST') {
                        `$res.ContentType = 'application/json; charset=utf-8'
                        `$res.Headers.Add('Cache-Control', 'no-store')
                        `$res.Headers.Add('Allow', 'POST')
                        Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_post_required_663cc07c'
                        continue
                    }
                    if (-not (Test-StatusRouteReady -Route 'host-refresh').Ready) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Close -Body ([ordered]@{ ok = `$false; reason = 'listener_dependency_missing' }) ``
                            -MessageKey 'status.api_listener_dependency_missing'
                        continue
                    }
                    if (-not (Test-HostRefreshContentType -ContentType ([string]`$req.ContentType))) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 415 -Close -Body ([ordered]@{ ok = `$false; reason = 'unsupported_media_type' }) ``
                            -MessageKey 'status.api_unsupported_media_type'
                        continue
                    }
                    # A declared length past the cap is refused before a byte is
                    # read. It is only a shortcut: the reader counts the bytes it
                    # receives, so a chunked or understated body is cut off one
                    # byte past the cap all the same.
                    if (`$req.ContentLength64 -gt 4096) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 413 -Close -Body ([ordered]@{ ok = `$false; reason = 'payload_too_large' }) ``
                            -MessageKey 'status.api_payload_too_large_4_kb'
                        continue
                    }
                    `$refreshAvailability = Get-HostRefreshSummaryCached
                    if (`$refreshAvailability.availability -ne 'available') {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Close -Body ([ordered]@{ ok = `$false; reason = 'refresh_unavailable' }) ``
                            -MessageKey 'status.api_host_refresh_unavailable' -MessageArguments @{ reason = [string]`$refreshAvailability.reason }
                        continue
                    }
                    if (`$pendingBodies.Count -ge 4) {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 503 -Close -RetryAfter '2' -Body ([ordered]@{ ok = `$false; reason = 'listener_busy' }) ``
                            -MessageKey 'status.api_listener_busy'
                        continue
                    }
                    `$refreshLoopback = `$false
                    try { `$refreshLoopback = [System.Net.IPAddress]::IsLoopback(`$req.RemoteEndPoint.Address) } catch { `$refreshLoopback = `$false }
                    Add-PendingRequestBody -RequestContext `$ctx -Loopback `$refreshLoopback -ProofWire ([string]`$req.Headers['X-Yuruna-Refresh-Proof'])
                } catch {
                    Write-ServerErr "control/host-refresh failed before its body was read: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
                    try {
                        Send-JsonReply -Response `$res -Request `$req -StatusCode 500 -Close -Body ([ordered]@{ ok = `$false; reason = 'internal_error' }) -MessageKey 'status.api_internal_error'
                    } catch {
                        Write-ServerErr "control/host-refresh reply failed: `$(`$_.Exception.Message)"
                        try { `$res.Abort() } catch { Write-Debug `$_ }
                    }
                }
                continue
            }

            # --- REGION: /livecheck -- cheap reachability probe for guests
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'livecheck' -or `$path -eq 'livecheck/') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                `$payload = @{
                    ok      = `$true
                    service = 'yuruna-status-service'
                    time    = (Get-Date).ToString('o')
                } | ConvertTo-Json -Compress
                `$body = [System.Text.Encoding]::UTF8.GetBytes(`$payload)
                `$res.ContentLength64 = `$body.Length
                # HEAD: advertise Content-Length but send no body.
                # HTTP.sys RSTs the connection when user code writes
                # bytes for a HEAD response, which makes wget --spider
                # probes from automation/fetch-and-execute.sh fail and
                # silently fall back to GitHub for every fetch.
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /ca.crt -- caching-proxy-service CA for guest CA self-heal
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'ca.crt' -or `$path -eq 'ca.crt/') {
                `$caRes = `$null
                try { `$caRes = Resolve-CachingProxyServiceCaCertPem } catch { `$caRes = `$null }
                if (`$caRes -and `$caRes.Pem) {
                    `$res.ContentType = 'application/x-x509-ca-cert'
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    `$res.Headers.Add('X-Yuruna-CA-Source', [string]`$caRes.Source)
                    `$body = [System.Text.Encoding]::ASCII.GetBytes([string]`$caRes.Pem)
                } else {
                    `$res.StatusCode = 404
                    `$res.ContentType = 'application/json; charset=utf-8'
                    `$body = (Get-StatusMessageBytes -Request `$req -Response `$res -Key 'status.api_no_caching_proxy_service_ca_resolvable_f924b0aa' -Json)
                }
                `$res.ContentLength64 = `$body.Length
                # HEAD: advertise Content-Length but send no body -- HTTP.sys
                # RSTs the connection when user code writes a body for a HEAD,
                # which would make a guest's wget --spider silently fall back.
                if (`$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$body, 0, `$body.Length)
                }
                `$res.OutputStream.Close()
                continue
            }

            # --- REGION: /diagnostics/<folder>/<filename> -- guest-pushed diagnostic dump
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -like 'diagnostics/*') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'POST' -and `$req.HttpMethod -ne 'PUT') {
                    `$res.Headers.Add('Allow', 'POST, PUT')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_method_not_allowed_post_the_dump_body_fa73866b'
                    continue
                }
                # See https://yuruna.link/42e5cdfd-0045
                `$rel  = `$path.Substring(12)
                `$segs = @(`$rel -split '/' | Where-Object { `$_ })
                if (`$segs.Count -lt 2 -or (`$segs | Where-Object { -not `$_ })) {
                    Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_expected_diagnostics_folder_filename_5f581c78'
                    continue
                }
                `$diagFile   = `$segs[-1]
                `$folderSegs = `$segs[0..(`$segs.Count - 2)]
                # Relative folder path reported in the success payload and error log below.
                `$diagFolder = (`$folderSegs -join '/')
                # See https://yuruna.link/42e5cdfd-0045
                `$segReject = `$false
                foreach (`$seg in `$folderSegs) {
                    if (`$seg -match '[\\]' -or `$seg -match '\.\.') { `$segReject = `$true; break }
                }
                if (`$segReject) {
                    Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_folder_segment_contains_traversal_or_backslash_0ada7fa5'
                    continue
                }
                if (`$diagFile -notlike '*.system.diagnostic.*.txt' -or `$diagFile -match '[\\/]' -or `$diagFile -match '\.\.') {
                    Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_filename_must_match_system_diagnostic_id_txt_ec048334'
                    continue
                }
                `$folderPath = `$logDir
                foreach (`$seg in `$folderSegs) { `$folderPath = Join-Path `$folderPath `$seg }
                if (-not (Test-Path -LiteralPath `$folderPath -PathType Container)) {
                    Send-JsonError -Response `$res -StatusCode 404 -Request `$req -Key 'status.api_failure_folder_not_found_runner_must_have_created_it_f_2d632e5e'
                    continue
                }
                # Pin the resolved file under logDir so a folder name that
                # somehow normalized to a parent (won't happen given the
                # checks above, but layered defense) still can't escape.
                `$filePath = [System.IO.Path]::GetFullPath((Join-Path `$folderPath `$diagFile))
                # Separator-anchored prefix: a bare StartsWith would also
                # admit sibling directories sharing the prefix (log-root
                # 'log' vs 'log-evil').
                `$logRootFull = [System.IO.Path]::GetFullPath(`$logDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                if (-not `$filePath.StartsWith(`$logRootFull, [System.StringComparison]::Ordinal)) {
                    Send-JsonError -Response `$res -StatusCode 403 -Request `$req -Key 'status.api_path_escapes_log_root_13754cf8'
                    continue
                }
                if (`$req.ContentLength64 -gt 5MB) {
                    Send-JsonError -Response `$res -StatusCode 413 -Request `$req -Key 'status.api_payload_too_large_5_mb_ab90ca52'
                    continue
                }
                Add-PendingRequestBody -RequestContext `$ctx -Upload ([pscustomobject]@{
                    Kind = 'diagnostics'; Target = `$filePath; RelativePath = `$diagFolder + '/' + `$diagFile
                    MaximumBytes = 5MB; SizeMessage = 'status.api_payload_too_large_5_mb_ab90ca52'
                })
                continue
            }

            # --- REGION: /yuruna-archive.tar.gz -- committed-content tarball
            # Replaces ``git clone`` for guests in the dev iteration loop:
            # ``git archive --format=tar.gz HEAD`` streams a tarball of
            # the latest committed tree, no .git/, no working-tree
            # uncommitted noise. Sidesteps the deny-list (which forbids
            # .git/) since it does not expose the repo internals.
            if (`$path -eq 'yuruna-archive.tar.gz') {
                # See https://yuruna.link/42e5cdfd-0045
                Send-GitArchive -Response `$res -Request `$req -Context `$ctx -RepoDir `$repoRoot -ErrorLabel 'yuruna-archive' -ExcludePath @('dev-only', 'docs')
                continue
            }

            # --- REGION: /yuruna-project-archive.tar.gz -- project repo tarball
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -eq 'yuruna-project-archive.tar.gz') {
                `$projectRoot = Join-Path `$repoRoot 'project'
                if (-not (Test-Path -LiteralPath (Join-Path `$projectRoot '.git'))) {
                    `$res.StatusCode = 404
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_project_repo_not_present_on_host_885e6338'
                    continue
                }
                Send-GitArchive -Response `$res -Request `$req -Context `$ctx -RepoDir `$projectRoot -ErrorLabel 'yuruna-project-archive'
                continue
            }

            # --- REGION: /log-upload/<rel> -- write a diagnostic file under `$logDir
            # See https://yuruna.link/42e5cdfd-0045
            # See https://yuruna.link/42d69dfa-001a
            if (`$path -like 'log-upload/*') {
                `$res.ContentType = 'application/json; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store')
                if (`$req.HttpMethod -ne 'PUT' -and `$req.HttpMethod -ne 'POST') {
                    `$res.Headers.Add('Allow', 'PUT, POST')
                    Send-JsonError -Response `$res -StatusCode 405 -Request `$req -Key 'status.api_put_or_post_required_1f919659'
                    continue
                }
                `$uploadRel = `$path.Substring(11) -replace '\\','/'
                `$uploadDeny = `$false
                if ([string]::IsNullOrWhiteSpace(`$uploadRel))             { `$uploadDeny = `$true }
                elseif (`$uploadRel -match '(^|/)\.\.(/|`$)')              { `$uploadDeny = `$true }
                elseif (`$uploadRel -match '^/')                           { `$uploadDeny = `$true }
                elseif (-not (`$uploadRel -match '\.(log|txt|json|err|crash|tar)`$')) { `$uploadDeny = `$true }
                if (`$uploadDeny) {
                    Send-JsonError -Response `$res -StatusCode 400 -Request `$req -Key 'status.api_invalid_upload_path_must_end_in_log_txt_json_err_crash_7020967c'
                    continue
                }
                if (`$req.ContentLength64 -gt 4MB) {
                    Send-JsonError -Response `$res -StatusCode 413 -Request `$req -Key 'status.api_payload_too_large_4_mb_3455f869'
                    continue
                }
                `$uploadTarget = Join-Path `$logDir `$uploadRel
                `$uploadFull   = [System.IO.Path]::GetFullPath(`$uploadTarget)
                # Separator-anchored prefix: a bare StartsWith would also
                # admit sibling directories sharing the prefix.
                `$logDirFull   = [System.IO.Path]::GetFullPath(`$logDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
                if (-not `$uploadFull.StartsWith(`$logDirFull, [System.StringComparison]::Ordinal)) {
                    Send-JsonError -Response `$res -StatusCode 403 -Request `$req -Key 'status.api_path_escapes_log_dir_355b2034'
                    continue
                }
                Add-PendingRequestBody -RequestContext `$ctx -Upload ([pscustomobject]@{
                    Kind = 'log-upload'; Target = `$uploadFull; RelativePath = `$uploadRel
                    MaximumBytes = 4MB; SizeMessage = 'status.api_payload_too_large_4_mb_3455f869'
                })
                continue
            }

            # See https://yuruna.link/42185271-000e
            if (`$path -match '^cycle/(\d{1,6})/?`$') {
                # Digits only, re-formatted through an int: the captured segment
                # cannot carry a traversal sequence into the filter below.
                `$wantedCycle = '{0:D6}' -f [int]`$matches[1]
                `$cycleHit = @(Get-ChildItem -LiteralPath `$logDir -Directory -Filter "`$wantedCycle.*" -ErrorAction SilentlyContinue |
                    Sort-Object Name | Select-Object -Last 1)
                if (`$cycleHit.Count -eq 0) {
                    # Rotation moves older cycles down into dated history.<date>/
                    # buckets, so the top level only holds the recent ones. Looking
                    # there second keeps the common case a single directory read.
                    `$cycleHit = @(Get-ChildItem -LiteralPath `$logDir -Directory -Filter 'history.*' -ErrorAction SilentlyContinue |
                        ForEach-Object { Get-ChildItem -LiteralPath `$_.FullName -Directory -Filter "`$wantedCycle.*" -ErrorAction SilentlyContinue } |
                        Sort-Object Name | Select-Object -Last 1)
                }
                if (`$cycleHit.Count -eq 0) {
                    # Third tier: the pool share. On a move-mode host this is where
                    # every finished cycle lives, so it is the only tier that can
                    # answer -- the two above see just the running cycle.
                    `$archivedName = @(Get-ArchivedCycleName | Where-Object { `$_ -like "`$wantedCycle.*" } | Sort-Object | Select-Object -Last 1)
                    if (`$archivedName.Count -gt 0) {
                        `$res.StatusCode = 302
                        `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                        `$res.Headers.Add('Location', "/log/`$(`$archivedName[0])/`$(`$archivedName[0]).html")
                        `$res.OutputStream.Close()
                        continue
                    }
                }
                if (`$cycleHit.Count -gt 0) {
                    # The folder keeps whatever lifecycle suffix it has on disk
                    # (.incomplete mid-cycle, .aborted.<UTC> after a crash); the
                    # transcript inside is always named with the bare identity.
                    `$cycleRoot = (Get-Item -LiteralPath `$logDir).FullName.TrimEnd('/','\')
                    `$cycleRel  = `$cycleHit[0].FullName.Substring(`$cycleRoot.Length).TrimStart('/','\').Replace('\','/')
                    `$cycleBase = `$cycleHit[0].Name -replace '\.incomplete`$', '' -replace '\.aborted\.[^/\\]+`$', ''
                    # 302 + no-store, never 301: the target moves as the folder is
                    # renamed through its lifecycle, so a cached redirect would pin
                    # a reader to a path that no longer exists.
                    `$res.StatusCode = 302
                    `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                    `$res.Headers.Add('Location', "/log/`$cycleRel/`$cycleBase.html")
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.StatusCode = 404
                `$res.ContentType = 'text/plain; charset=utf-8'
                Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_no_cycle_cycle_in_the_retained_log_history_99ad14e2' -Arguments @{ cycle = `$wantedCycle }
                continue
            }

            # --- REGION: /archive/<cycle>.zip -- one cycle folder as a single zip
            # See https://yuruna.link/42185271-000f
            # Packs one cycle folder into a single .zip for share-cycle.html. The
            # leaf is matched against the cycle-folder grammar rather than
            # sanitized, so no path separator survives and the archive cannot be
            # aimed anywhere else on disk.
            if (`$path -like 'archive/*') {
                `$leaf = `$path.Substring(8)
                if (`$leaf -notmatch '^(\d{6}\.(\d{4}-\d{2}-\d{2})\.(\d{2}-\d{2}-\d{2})\.([0-9a-fA-F]{32})(?:\.incomplete)?)\.zip`$') {
                    `$res.StatusCode = 404
                    `$res.ContentType = 'text/plain; charset=utf-8'
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_not_a_cycle_results_archive_name_395b9777'
                    continue
                }
                `$cycleFolder = `$Matches[1]
                # See https://yuruna.link/42e5cdfd-0045
                `$archiveName = '{0}.{1}T{2}Z.zip' -f `$Matches[4].Substring(0,8), `$Matches[2], `$Matches[3]
                `$srcDir = Join-Path `$logDir `$cycleFolder
                if (-not (Test-Path -LiteralPath `$srcDir -PathType Container)) {
                    # Archived: pack from the share instead. The zip is still built
                    # on this host from a filesystem it can see, so the share page
                    # keeps working for a cycle whose local folder has been deleted.
                    `$archivedSrc = Resolve-ArchivedLogPath -Rel `$cycleFolder
                    if (`$archivedSrc -and (Test-Path -LiteralPath `$archivedSrc -PathType Container)) { `$srcDir = `$archivedSrc }
                }
                if (-not (Test-Path -LiteralPath `$srcDir -PathType Container)) {
                    `$res.StatusCode = 404
                    `$res.ContentType = 'text/plain; charset=utf-8'
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_no_cycle_results_folder_folder_on_this_host_51798923' -Arguments @{ folder = `$cycleFolder }
                    continue
                }
                # See https://yuruna.link/42e5cdfd-0045
                if (`$req.HttpMethod -eq 'HEAD') {
                    `$res.StatusCode = 200
                    `$res.ContentType = 'application/zip'
                    `$res.Headers.Add('Content-Disposition', ('attachment; filename="' + `$archiveName + '"'))
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    # See https://yuruna.link/42e5cdfd-0045
                    `$res.OutputStream.Close()
                    continue
                }
                # See https://yuruna.link/42e5cdfd-0045
                `$tmpArchive = Join-Path `$runtimeDir ("share-cycle." + [guid]::NewGuid().ToString('N') + '.zip')
                try {
                    `$srcRoot = (Resolve-Path -LiteralPath `$srcDir).ProviderPath.TrimEnd('\', '/')
                    `$zip = [System.IO.Compression.ZipFile]::Open(`$tmpArchive, [System.IO.Compression.ZipArchiveMode]::Create)
                    try {
                        foreach (`$file in [System.IO.Directory]::EnumerateFiles(`$srcRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
                            # See https://yuruna.link/42e5cdfd-0045
                            `$blocked = `$false
                            foreach (`$shape in `$secretNameShapes) {
                                if ([System.IO.Path]::GetFileName(`$file) -like `$shape) { `$blocked = `$true; break }
                            }
                            if (`$blocked) { continue }
                            # Every entry is rooted at the cycle folder, so an
                            # extract lands one named folder instead of scattering
                            # transcripts into whatever directory the colleague was
                            # in, and the host's own log path stays out of the zip.
                            `$entryName = `$cycleFolder + '/' + (`$file.Substring(`$srcRoot.Length + 1) -replace '\\', '/')
                            try {
                                # ReadWrite sharing: a cycle that is still running
                                # is being written to while it is packed, and the
                                # read-share default would be refused on the file
                                # its writer still holds open.
                                `$inStream = [System.IO.File]::Open(`$file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                            } catch [System.IO.IOException] {
                                # Gone or locked outright between the walk and the
                                # read. One file of a live cycle is not worth
                                # failing the whole archive over.
                                continue
                            }
                            try {
                                `$entry = `$zip.CreateEntry(`$entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                                `$entry.LastWriteTime = [System.IO.File]::GetLastWriteTime(`$file)
                                `$entryStream = `$entry.Open()
                                try { `$inStream.CopyTo(`$entryStream) } finally { `$entryStream.Dispose() }
                            } finally { `$inStream.Dispose() }
                        }
                        # A guest folder that produced no artifacts still says
                        # something by being there, and a zip carries a directory
                        # only when it is named as an entry of its own.
                        foreach (`$dir in [System.IO.Directory]::EnumerateDirectories(`$srcRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
                            if (@([System.IO.Directory]::GetFileSystemEntries(`$dir)).Count -gt 0) { continue }
                            `$null = `$zip.CreateEntry(`$cycleFolder + '/' + (`$dir.Substring(`$srcRoot.Length + 1) -replace '\\', '/') + '/')
                        }
                    } finally { `$zip.Dispose() }
                    if (-not (Test-Path -LiteralPath `$tmpArchive)) { throw 'the packer produced no archive' }
                    `$archiveBytes = [System.IO.File]::ReadAllBytes(`$tmpArchive)
                    `$res.StatusCode = 200
                    `$res.ContentType = 'application/zip'
                    `$res.Headers.Add('Content-Disposition', ('attachment; filename="' + `$archiveName + '"'))
                    `$res.Headers.Add('Cache-Control', 'no-store')
                    `$res.ContentLength64 = `$archiveBytes.Length
                    `$res.OutputStream.Write(`$archiveBytes, 0, `$archiveBytes.Length)
                } catch {
                    # Naming the cycle and the failure is the difference between
                    # "that cycle is gone" and "the pack itself broke", which the
                    # share page shows the operator verbatim.
                    Write-ServerErr "archive `$cycleFolder failed: `$(`$_.Exception.Message)"
                    `$res.StatusCode = 500
                    `$res.ContentType = 'text/plain; charset=utf-8'
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_could_not_pack_folder_detail_268ee848' -Arguments @{ folder = `$cycleFolder; detail = `$_.Exception.Message } -NoClose
                } finally {
                    Remove-Item -LiteralPath `$tmpArchive -Force -ErrorAction SilentlyContinue
                }
                `$res.OutputStream.Close()
                continue
            }

            # Dispatch file serving by URL prefix (yuruna-repo/ ->
            # `$repoRoot, runtime/ -> `$runtimeDir, log/ -> `$logDir,
            # else `$statusDir); each branch pins the path under its
            # mount root, then the unified deny-list (`$denyLikeStatus)
            # blocks secrets on every route. See docs/control-routes.md.
            if (`$path -like 'yuruna-repo/*') {
                `$rel  = `$path.Substring(12)
                `$root = `$repoRoot
            } elseif (`$path -like 'runtime/*') {
                `$rel  = `$path.Substring(8)
                `$root = `$runtimeDir
            } elseif (`$path -like 'log/*') {
                `$rel  = `$path.Substring(4)
                `$root = `$logDir
            } else {
                `$rel  = `$path
                `$root = `$statusDir
            }
            # Pseudo catalogs are stored under a stable deployment filename but
            # exposed to pages only through a content-addressed URL. An exact
            # canonical match is required: a made-up hash remains a normal
            # nonexistent path and returns 404 instead of serving mismatched
            # bytes under an immutable cache key.
            `$immutableLocaleCatalog = `$null
            if (`$root -ceq `$statusDir -and
                `$rel -cmatch '^([A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*)\.([0-9a-f]{64})\.status\.js$') {
                `$candidateCatalog = Get-StatusLocaleCatalogAsset -Locale `$Matches[1] -Root `$statusDir
                if (`$candidateCatalog -and `$rel -ceq `$candidateCatalog.RequestName) {
                    `$immutableLocaleCatalog = `$candidateCatalog
                    `$rel = `$candidateCatalog.SourceName
                }
            }
            `$file = Join-Path `$root `$rel
            # Archived-cycle fallback: a move-mode host has deleted the local folder,
            # so serve the same URL from the mounted share instead. Re-rooting here
            # (rather than rewriting the recorded URLs) is what keeps status.json
            # history rows, per-guest tiles and flame-chart links working unchanged.
            # The containment check below is applied to whichever root won.
            if ((`$path -like 'log/*') -and -not (Test-Path -LiteralPath `$file)) {
                `$archived = Resolve-ArchivedLogPath -Rel `$rel
                if (`$archived) {
                    `$file = `$archived
                    `$root = Get-ArchiveCycleRoot
                }
            }
            `$file = [System.IO.Path]::GetFullPath(`$file)
            `$rootFull = [System.IO.Path]::GetFullPath(`$root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            # Equality is legitimate here (empty `$rel serves the mount's
            # directory index); the descendant test is separator-anchored so
            # a sibling directory sharing the prefix (e.g. the repo root vs
            # a '<repo>-something' checkout next to it) cannot pass.
            if (-not ((`$file -ceq `$rootFull) -or `$file.StartsWith(`$rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::Ordinal))) {
                `$res.StatusCode = 403
                Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_forbidden_78342a09'
                continue
            }
            # Apply access rules to the same canonical relative path that
            # file opening uses, so repeated separators cannot bypass them.
            `$relNorm = [System.IO.Path]::GetRelativePath(`$rootFull, `$file) -replace '\\', '/'
            # See https://yuruna.link/42e5cdfd-0045
            if (`$relNorm.Contains(':')) {
                `$res.StatusCode = 403
                Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_forbidden_78342a09'
                continue
            }
            if (`$path -like 'yuruna-repo/*') {
                # Deny-list: secrets, vault state, the .git directory.
                # Pattern-based so future credential / event-log files
                # in the same families are auto-protected.
                # The yuruna-project sequence files live elsewhere; this
                # only governs what ships out of the framework's repo.
                `$denyExact = @(
                    'test/test.config.yml',
                    '.git'
                )
                `$denyLike = @(
                    '*.pfx',
                    '.git/*',
                    '*/vault.yml',
                    '*/vault.lock',
                    '*/transports.yml',
                    'test/status/extension/*',
                    'test/status/ssh/*',
                    '*/yuruna-caching-proxy-service.yml',
                    'test/status/runtime/yuruna-caching-proxy-service.yml',
                    '*.events.log',
                    '*-password.txt'
                ) + `$secretNameShapes
                `$denied = (`$denyExact -contains `$relNorm)
                if (-not `$denied) {
                    foreach (`$pat in `$denyLike) {
                        if (`$relNorm -like `$pat) { `$denied = `$true; break }
                    }
                }
                if (`$denied) {
                    `$res.StatusCode = 403
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_forbidden_deny_list_1c7d1cfa'
                    continue
                }
            }
            # See https://yuruna.link/42e5cdfd-0045
            if (`$path -notlike 'yuruna-repo/*') {
                `$denyLikeStatus = @(
                    '*/vault.yml',     'vault.yml',
                    '*/vault.lock',    'vault.lock',
                    '*/transports.yml','transports.yml',
                    '*/events.log',    'events.log',
                    'extension/*',
                    'ssh/yuruna_ed25519',
                    'ssh/*_ed25519',
                    '*/yuruna-caching-proxy-service.yml',
                    'yuruna-caching-proxy-service.yml',
                    '*-password.txt'
                ) + `$secretNameShapes
                `$denied = `$false
                foreach (`$pat in `$denyLikeStatus) {
                    if (`$relNorm -like `$pat) { `$denied = `$true; break }
                }
                if (`$denied) {
                    `$res.StatusCode = 403
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_forbidden_deny_list_1c7d1cfa'
                    continue
                }
            }
            # --- REGION: Directory listing
            # See https://yuruna.link/42e5cdfd-0045
            if (Test-Path -LiteralPath `$file -PathType Container) {
                if (`$path -like 'yuruna-repo/*' -or `$path -eq 'yuruna-repo' -or `$path -eq 'yuruna-repo/' -or
                    `$root -ceq `$runtimeDir -or `$relNorm -eq 'runtime' -or `$relNorm -like 'runtime/*') {
                    `$res.StatusCode = 403
                    Send-StatusMessage -Request `$req -Response `$res -Key 'status.api_forbidden_directory_listing_disabled_5d107f5b'
                    continue
                }
                `$origLocal = `$req.Url.LocalPath
                if (-not `$origLocal.EndsWith('/')) {
                    # Without a trailing slash the browser resolves the
                    # listing's relative <a href> one segment too high,
                    # so a click on raw_001.png would request
                    # /log/raw_001.png instead of /log/<dir>/raw_001.png.
                    `$res.StatusCode = 301
                    `$res.Headers.Add('Location', `$origLocal + '/')
                    `$res.OutputStream.Close()
                    continue
                }
                `$entries = @(Get-ChildItem -LiteralPath `$file -Force -ErrorAction SilentlyContinue |
                    Sort-Object @{Expression = { -not `$_.PSIsContainer }}, Name)
                # See https://yuruna.link/42e5cdfd-0045
                if (`$path -eq 'log' -or `$path -eq 'log/') {
                    # Backfill can read the pool archive directly. Its local-only
                    # listing must not occupy this listener checking NAS sentinels.
                    `$archiveEntries = if (`$req.QueryString['localOnly'] -eq 'true') { @() } else { @(Get-ArchivedCycleEntry) }
                    `$localNames = @{}
                    foreach (`$e in `$entries) { `$localNames[`$e.Name] = `$true }
                    `$extra = [System.Collections.Generic.List[object]]::new()
                    foreach (`$archived in `$archiveEntries) {
                        if (-not `$localNames.ContainsKey(`$archived.Name)) { `$extra.Add(`$archived) }
                    }
                    if (`$extra.Count -gt 0) {
                        `$entries = @(@(`$entries) + @(`$extra) |
                            Sort-Object @{Expression = { -not `$_.PSIsContainer }}, Name)
                    }
                }
                # See https://yuruna.link/42e5cdfd-0045
                `$listingLocale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                `$sb = [System.Text.StringBuilder]::new()
                # Paths and entry names are attacker-controlled text inside a
                # surrounding sentence/table. Strip injected UAX #9 controls,
                # then keep the real letters inside one FSI/PDI pair. The href
                # below remains independently percent-encoded from the raw name.
                `$listingBidiControl = '[' + ([char]0x061c) + ([char]0x200e) + ([char]0x200f) +
                    ([char]0x202a) + '-' + ([char]0x202e) + ([char]0x2066) + '-' + ([char]0x2069) + ']'
                `$listingIsolateStart = ([char]0x2068).ToString()
                `$listingIsolateEnd = ([char]0x2069).ToString()
                `$displayPath = (`$origLocal -replace `$listingBidiControl, '')
                if (`$displayPath) { `$displayPath = `$listingIsolateStart + `$displayPath + `$listingIsolateEnd }
                `$titleText = Format-CatalogMessage -Key 'status.directory_index_title' -Arguments @{ path = `$displayPath } -Locale `$listingLocale.Tag
                `$captionText = Format-CatalogMessage -Key 'status.directory_contents_caption' -Arguments @{ path = `$displayPath } -Locale `$listingLocale.Tag
                `$columnNameText = Format-CatalogMessage -Key 'status.directory_column_name' -Locale `$listingLocale.Tag
                `$columnSizeText = Format-CatalogMessage -Key 'status.directory_column_size' -Locale `$listingLocale.Tag
                `$columnModifiedText = Format-CatalogMessage -Key 'status.directory_column_modified_utc' -Locale `$listingLocale.Tag
                `$parentText = Format-CatalogMessage -Key 'status.directory_parent' -Locale `$listingLocale.Tag
                `$titleEnc = [System.Net.WebUtility]::HtmlEncode(`$titleText)
                `$captionEnc = [System.Net.WebUtility]::HtmlEncode(`$captionText)
                `$columnNameEnc = [System.Net.WebUtility]::HtmlEncode(`$columnNameText)
                `$columnSizeEnc = [System.Net.WebUtility]::HtmlEncode(`$columnSizeText)
                `$columnModifiedEnc = [System.Net.WebUtility]::HtmlEncode(`$columnModifiedText)
                `$parentEnc = [System.Net.WebUtility]::HtmlEncode(`$parentText)
                `$listingTagEnc = [System.Net.WebUtility]::HtmlEncode(`$listingLocale.Tag)
                `$listingRequestedEnc = [System.Net.WebUtility]::HtmlEncode(`$listingLocale.RequestedTag)
                `$listingDirectionEnc = [System.Net.WebUtility]::HtmlEncode(`$listingLocale.Direction)
                `$listingSourceEnc = [System.Net.WebUtility]::HtmlEncode(`$listingLocale.Source)
                # See https://yuruna.link/42e5cdfd-0045
                [void]`$sb.AppendLine('<!doctype html><html lang="' + `$listingTagEnc + '" dir="' + `$listingDirectionEnc + '" data-yuruna-requested-language="' + `$listingRequestedEnc + '" data-yuruna-locale-source="' + `$listingSourceEnc + '"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>' + `$titleEnc + '</title><link rel="stylesheet" href="/yuruna.common.css"><style>body{margin:1.5em}h1{font-size:1.1em}h1,caption{overflow-wrap:anywhere}table{border-collapse:collapse}td,th{padding:0.2em 1em;border-bottom:1px solid var(--border);font-family:var(--font-mono);text-align:left}th{background:var(--bg-hover)}caption{text-align:left;padding:0.2em 1em 0.6em;font-family:var(--font-mono)}.scroller{overflow-x:auto}</style></head><body>')
                [void]`$sb.AppendLine('<main>')
                [void]`$sb.AppendLine("<h1>`$titleEnc</h1>")
                # See https://yuruna.link/42e5cdfd-0045
                [void]`$sb.AppendLine('<div class="scroller">')
                [void]`$sb.AppendLine('<table><caption>' + `$captionEnc + '</caption><thead><tr><th scope="col">' + `$columnNameEnc + '</th><th scope="col">' + `$columnSizeEnc + '</th><th scope="col">' + `$columnModifiedEnc + '</th></tr></thead><tbody>')
                if (`$origLocal -ne '/') {
                    # "../" is the entire accessible name of the only link out of a
                    # directory. The visible text stays so a speech-input user can
                    # still say what they see; the appended words are what a screen
                    # reader announces.
                    [void]`$sb.AppendLine('<tr><td><a href="../">../<span class="sr-only"> ' + `$parentEnc + '</span></a></td><td></td><td></td></tr>')
                }
                foreach (`$e in `$entries) {
                    `$displayName = ([string]`$e.Name -replace `$listingBidiControl, '')
                    if (`$displayName) { `$displayName = `$listingIsolateStart + `$displayName + `$listingIsolateEnd }
                    `$nameEnc = [System.Net.WebUtility]::HtmlEncode(`$displayName)
                    `$hrefEnc = [Uri]::EscapeDataString(`$e.Name)
                    # A round-trip timestamp is a machine format on a page with no
                    # machine consumers. The readable form is the text; the exact
                    # value rides in the datetime attribute for anything that does
                    # come to parse it.
                    `$mtimeIso = `$e.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    `$mtime = '<time datetime="' + `$mtimeIso + '">' + `$e.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + '</time>'
                    if (`$e.PSIsContainer) {
                        [void]`$sb.Append('<tr><td><a href="').Append(`$hrefEnc).Append('/">').Append(`$nameEnc).Append('/</a></td><td></td><td>').Append(`$mtime).AppendLine('</td></tr>')
                    } else {
                        # Exact bytes stay reachable in the title; the cell shows the
                        # magnitude, which is what a listing is read for.
                        `$len = [long]`$e.Length
                        if (`$len -lt 1024) {
                            `$sizeKey = 'status.file_size_bytes'
                            `$sizeValue = Format-CatalogNumber -Value `$len -Locale `$listingLocale.Tag -Decimals 0
                        } elseif (`$len -lt 1048576) {
                            `$sizeKey = 'status.file_size_kilobytes'
                            `$sizeValue = Format-CatalogNumber -Value (`$len / 1024) -Locale `$listingLocale.Tag -Decimals 1
                        } elseif (`$len -lt 1073741824) {
                            `$sizeKey = 'status.file_size_megabytes'
                            `$sizeValue = Format-CatalogNumber -Value (`$len / 1048576) -Locale `$listingLocale.Tag -Decimals 1
                        } else {
                            `$sizeKey = 'status.file_size_gigabytes'
                            `$sizeValue = Format-CatalogNumber -Value (`$len / 1073741824) -Locale `$listingLocale.Tag -Decimals 1
                        }
                        `$sizeText = Format-CatalogMessage -Key `$sizeKey -Arguments @{ size = `$sizeValue } -Locale `$listingLocale.Tag
                        `$sizeTextEnc = [System.Net.WebUtility]::HtmlEncode(`$sizeText)
                        `$exactSizeValue = Format-CatalogNumber -Value `$len -Locale `$listingLocale.Tag -Decimals 0
                        `$exactSizeText = Format-CatalogMessage -Key 'status.file_size_bytes' -Arguments @{ size = `$exactSizeValue } -Locale `$listingLocale.Tag
                        `$exactSizeTextEnc = [System.Net.WebUtility]::HtmlEncode(`$exactSizeText)
                        [void]`$sb.Append('<tr><td><a href="').Append(`$hrefEnc).Append('">').Append(`$nameEnc).Append('</a></td><td data-bytes="').Append(`$len).Append('" title="').Append(`$exactSizeTextEnc).Append('">').Append(`$sizeTextEnc).Append('</td><td>').Append(`$mtime).AppendLine('</td></tr>')
                    }
                }
                [void]`$sb.AppendLine('</tbody></table>')
                [void]`$sb.AppendLine('</div>')
                [void]`$sb.AppendLine('</main></body></html>')
                `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$sb.ToString())
                `$res.ContentType = 'text/html; charset=utf-8'
                `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                if (-not (Set-LocalizedRepresentationValidator -Request `$req -Response `$res ``
                        -Bytes `$bytes -Locale `$listingLocale)) {
                    `$res.OutputStream.Close()
                    continue
                }
                `$res.ContentLength64 = `$bytes.Length
                if (`$req.HttpMethod -ne 'HEAD') { `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
                `$res.OutputStream.Close()
                continue
            }
            if (`$immutableLocaleCatalog -or (Test-Path -LiteralPath `$file -PathType Leaf)) {
                `$ext = [System.IO.Path]::GetExtension(`$file)
                `$res.ContentType = switch (`$ext) {
                    '.html' { 'text/html; charset=utf-8' }
                    '.json' { 'application/json; charset=utf-8' }
                    '.css'  { 'text/css; charset=utf-8' }
                    '.js'   { 'application/javascript; charset=utf-8' }
                    '.txt'  { 'text/plain; charset=utf-8' }
                    '.png'  { 'image/png' }
                    '.sh'   { 'text/x-shellscript; charset=utf-8' }
                    '.ps1'  { 'text/plain; charset=utf-8' }
                    '.psm1' { 'text/plain; charset=utf-8' }
                    '.yml'  { 'text/yaml; charset=utf-8' }
                    '.yaml' { 'text/yaml; charset=utf-8' }
                    '.md'   { 'text/markdown; charset=utf-8' }
                    default { 'application/octet-stream' }
                }
                # See https://yuruna.link/42e5cdfd-0045
                if (`$immutableLocaleCatalog) {
                    if (-not (Set-ImmutableAssetValidator -Request `$req -Response `$res ``
                            -Asset `$immutableLocaleCatalog)) {
                        `$res.OutputStream.Close()
                        continue
                    }
                } elseif (`$ext -eq '.html') {
                    `$res.Headers.Add('Cache-Control', 'public, max-age=60, must-revalidate')
                    `$res.Headers.Add('Last-Modified', ([System.IO.File]::GetLastWriteTimeUtc(`$file).ToString('R')))
                } elseif (`$ext -in '.json','.txt','.css','.js','.sh','.ps1','.psm1','.yml','.yaml','.md') {
                    `$res.Headers.Add('Cache-Control', 'no-store, no-cache, must-revalidate')
                    `$res.Headers.Add('Pragma', 'no-cache')
                    `$res.Headers.Add('Expires', '0')
                }
                `$fileLength = if (`$immutableLocaleCatalog) {
                    [long]`$immutableLocaleCatalog.Bytes.Length
                } else {
                    [long]([System.IO.FileInfo]::new(`$file).Length)
                }
                if (`$fileLength -gt 50MB) {
                    `$errorLocale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                    `$errorResponse = Set-StatusErrorRepresentation -Request `$req -Response `$res -StatusCode 413 -Key 'status.error_file_too_large' -Locale `$errorLocale
                    if (`$errorResponse.ShouldWrite -and `$req.HttpMethod -ne 'HEAD') {
                        `$res.OutputStream.Write(`$errorResponse.Bytes, 0, `$errorResponse.Bytes.Length)
                    }
                    `$res.OutputStream.Close()
                    continue
                }
                # A content-addressed catalog must serve the SAME captured
                # bytes its URL and ETag name. Re-reading the stable source
                # after hash validation would let a concurrent deployment put
                # new bytes under the old immutable URL.
                `$bytes = if (`$immutableLocaleCatalog) {
                    [byte[]]`$immutableLocaleCatalog.Bytes
                } else {
                    [System.IO.File]::ReadAllBytes(`$file)
                }
                if (`$ext -eq '.html') {
                    # See https://yuruna.link/42e5cdfd-0045
                    `$locale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                    `$html = [System.Text.Encoding]::UTF8.GetString(`$bytes)
                    `$html = ConvertTo-LocalizedPageHtml -Html `$html -Locale `$locale
                    `$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$html)
                    if (-not (Set-LocalizedRepresentationValidator -Request `$req -Response `$res ``
                            -Bytes `$bytes -Locale `$locale)) {
                        `$res.OutputStream.Close()
                        continue
                    }
                }
                `$res.ContentLength64 = `$bytes.Length
                # HEAD returns the headers (incl. Content-Length) but no body:
                # skip the read+write so a large file isn't loaded only to be
                # discarded, and the managed HttpListener (Linux/macOS) doesn't
                # emit an unexpected body on a HEAD response.
                if (`$req.HttpMethod -ne 'HEAD') { `$res.OutputStream.Write(`$bytes, 0, `$bytes.Length) }
            } else {
                `$errorLocale = Resolve-PageLocale -AcceptLanguage `$req.Headers['Accept-Language']
                `$errorResponse = Set-StatusErrorRepresentation -Request `$req -Response `$res -StatusCode 404 -Key 'status.error_not_found' -Locale `$errorLocale
                if (`$errorResponse.ShouldWrite -and `$req.HttpMethod -ne 'HEAD') {
                    `$res.OutputStream.Write(`$errorResponse.Bytes, 0, `$errorResponse.Bytes.Length)
                }
                # See https://yuruna.link/42e5cdfd-0045
                if (`$path -like 'yuruna-repo/*') {
                    Write-ServerErr "yuruna-repo 404: path=`$path resolved=`$file"
                }
            }
            `$res.OutputStream.Close()
        } catch {
            # See https://yuruna.link/42e5cdfd-0045
            Write-ServerErr "handler error: path=`$path `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
            try { `$ctx.Response.Abort() } catch { Write-Debug `$_ }
        }
      } catch {
        # Log unhandled iteration-level failures (EndGetContext throws,
        # listener kicked out by http.sys) and keep serving. Without
        # this the server died silently on the first transient blip.
        Write-ServerErr "iteration error: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
        `$contextTask = `$null
        Start-Sleep -Milliseconds 200
      }
    }
} catch {
    Write-ServerErr "fatal: `$(`$_.Exception.GetType().FullName): `$(`$_.Exception.Message)"
    throw
} finally { `$listener.Stop() }
"@

# See https://yuruna.link/42e5cdfd-0045
Remove-Item (Join-Path $RuntimeDir '.status-service.ps1') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $RuntimeDir 'server.out') -Force -ErrorAction SilentlyContinue

$serverScriptFile = Join-Path $RuntimeDir ".status-service.ps1"
Set-Content -Path $serverScriptFile -Value $serverScript -Encoding UTF8BOM

# See https://yuruna.link/42e5cdfd-0045
$serverScriptParseError = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($serverScriptFile, [ref]$null, [ref]$serverScriptParseError)
if ($serverScriptParseError -and $serverScriptParseError.Count) {
    foreach ($parseError in ($serverScriptParseError | Select-Object -First 5)) {
        Write-Output ("  line $($parseError.Extent.StartLineNumber), column $($parseError.Extent.StartColumnNumber): $($parseError.Message)")
    }
    if ($RefreshSafe) { Complete-RefreshSafeStart -Outcome 'generation-failed' -Reason 'parse-error' }
    Exit-StatusServiceStartupLock
    throw ("The generated status-service script has $($serverScriptParseError.Count) syntax error(s) and would die on startup; refusing to launch it. " +
           "The generated file is $serverScriptFile -- each error above is a line IN THAT FILE, produced by the server here-string in $PSCommandPath.")
}

# -NonInteractive: the server runs with no console, so a command that
# prompted for a missing mandatory value would park the whole request loop
# on a read nobody can answer; non-interactive, it fails that one request.
try {
    Save-StatusServiceErrorLog -RuntimeDirectory $RuntimeDir -Confirm:$false
    if ($IsWindows) {
        # See https://yuruna.link/42e5cdfd-0045
        $serverOut = Join-Path $RuntimeDir "server.out"
        $serverErrFile = Join-Path $RuntimeDir "server.stderr"
        # See https://yuruna.link/42e5cdfd-0045
        $serverScriptQuoted = '"' + $serverScriptFile + '"'
        # See https://yuruna.link/42e5cdfd-0045
        $stdinSink = Join-Path $RuntimeDir 'stdin.empty'
        if (-not (Test-Path -LiteralPath $stdinSink)) {
            [System.IO.File]::WriteAllBytes($stdinSink, [byte[]]@())
        }
        $proc = Start-Process -FilePath "pwsh" `
            -ArgumentList "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-File", $serverScriptQuoted `
            -RedirectStandardInput  $stdinSink `
            -RedirectStandardOutput $serverOut `
            -RedirectStandardError  $serverErrFile `
            -PassThru
        Set-Content -Path $PidFile -Value $proc.Id
    } else {
        # See https://yuruna.link/42e5cdfd-0045
        $stdErr = Join-Path $RuntimeDir "server.stderr"
        & bash -c "set -m; nohup pwsh -NoProfile -NonInteractive -File '$serverScriptFile' </dev/null >/dev/null 2>'$stdErr' & echo `$!" | Set-Variable -Name bgPid
        Set-Content -Path $PidFile -Value $bgPid
    }
} catch {
    if ($RefreshSafe) { Complete-RefreshSafeStart -Outcome 'launch-failed' -Reason ([string]$_.Exception.GetType().Name) }
    throw
}

# --- REGION: Verify server started
# The refresh-safe start waits only as long as its deadline allows, keeping
# time for the commit lookup and the outcome record (the caller bounds this
# process by the same deadline and reads only that record), and never kills a
# server that is slow to come up.
$readyWaitSeconds = $script:StatusServiceReadyTimeoutSeconds
if ($RefreshSafe) {
    $readyWaitSeconds = Get-YurunaDeadlineBoundedSeconds -Deadline $script:RefreshSafeDeadline `
        -Ceiling $script:StatusServiceReadyTimeoutSeconds -ReserveMilliseconds 8000
    if (-not $readyWaitSeconds) { $readyWaitSeconds = 1 }
}
$serverReady = Wait-WithProgress -Activity "Status service: waiting for http://localhost:$Port/" `
    -TotalSeconds $readyWaitSeconds -PollSeconds 1 -Test {
        try {
            $null = Invoke-WebRequest -Uri "http://localhost:$Port/status/" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop -Verbose:$false -Debug:$false
            return $true
        } catch { return $false }
    }
if (-not $serverReady) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d938ab5118c5d2c1' -Arguments @{ port = "$Port"; statusServiceReadyTimeoutSeconds = "$readyWaitSeconds" })
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f8a43d6f86299328' -Arguments @{ err = "$(Join-Path $RuntimeDir 'server.err'), $(Join-Path $RuntimeDir 'server.stderr')" })
    if ($RefreshSafe) {
        $launchedPid = 0
        try { $null = [int]::TryParse(([System.IO.File]::ReadAllText($PidFile)).Trim(), [ref]$launchedPid) } catch { $launchedPid = 0 }
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_refresh_safe_not_ready' -Arguments @{ processId = $launchedPid; seconds = $readyWaitSeconds })
        Complete-RefreshSafeStart -Outcome 'start-timeout' -ProcessId $launchedPid -Reason 'status-unanswered'
    }
}

# --- REGION: Host-address beacon
# See https://yuruna.link/42e5cdfd-0046
# See https://yuruna.link/4220a755-002d
if ($serverReady) {
    try {
        $beaconScript = Join-Path $RepoRoot 'test/modules/Invoke-HostAddressBeacon.ps1'
        if (Test-Path -LiteralPath $beaconScript) {
            $beaconErr = Join-Path $RuntimeDir 'hostaddress.beacon.err'
            # See https://yuruna.link/42e5cdfd-0047
            $beaconLock    = Join-Path $RuntimeDir 'hostaddress.beacon.lock'
            $beaconRunning = $false
            if (Test-Path -LiteralPath $beaconLock) {
                try {
                    $lockProbe = [System.IO.File]::Open(
                        $beaconLock, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    $lockProbe.Dispose()
                } catch { $beaconRunning = $true }
            }
            if ($beaconRunning) {
                Write-Verbose 'Host-address beacon: one is already running and follows server.pid across a restart, so this service is covered; not spawning a second.'
            } elseif ($IsWindows) {
                $beaconStdin = Join-Path $RuntimeDir 'hostaddress.beacon.stdin.empty'
                if (-not (Test-Path -LiteralPath $beaconStdin)) { [System.IO.File]::WriteAllBytes($beaconStdin, [byte[]]@()) }
                $beaconOut = Join-Path $RuntimeDir 'hostaddress.beacon.out'
                Start-Process -FilePath 'pwsh' `
                    -ArgumentList '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', ('"' + $beaconScript + '"'), '-StatusPort', "$Port" `
                    -RedirectStandardInput  $beaconStdin `
                    -RedirectStandardOutput $beaconOut `
                    -RedirectStandardError  $beaconErr | Out-Null
            } else {
                # See https://yuruna.link/42e5cdfd-0045
                $beaconOut = Join-Path $RuntimeDir 'hostaddress.beacon.out'
                & bash -c "set -m; nohup pwsh -NoProfile -NonInteractive -File '$beaconScript' -StatusPort '$Port' </dev/null >>'$beaconOut' 2>'$beaconErr' & echo `$!" | Out-Null
            }
        }
    } catch {
        # See https://yuruna.link/42e5cdfd-0045
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_beacon_start_failed' -Arguments @{ detail = $_.Exception.Message; logPath = (Join-Path $RuntimeDir 'hostaddress.beacon.err') })
    }
}

# See https://yuruna.link/42e5cdfd-0045
try {
    $launchSha = if ($RefreshSafe) { Get-RefreshSafeFrameworkSha } else { (& git -C $RepoRoot rev-parse HEAD 2>$null | Out-String).Trim() }
    if ($launchSha) {
        [System.IO.File]::WriteAllText($ShaFile, $launchSha, [System.Text.UTF8Encoding]::new($false))
    } elseif (Test-Path -LiteralPath $ShaFile) {
        Remove-Item -LiteralPath $ShaFile -Force -ErrorAction SilentlyContinue
    }
} catch { Write-Verbose "Could not persist server.sha: $($_.Exception.Message)" }

# --- REGION: Display connection info
# The refresh-safe start runs no bare native command and waits on no name
# lookup: both are unbounded, and its caller holds a deadline.
$machineName = if ($RefreshSafe) { [Environment]::MachineName } else { (hostname).Trim() }
$ip = if ($RefreshSafe) { $null } else {
    try {
        ([System.Net.Dns]::GetHostAddresses($machineName) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            Select-Object -First 1).IPAddressToString
    } catch { $null }
}

Write-Output ""
$serverPid = (Get-Content $PidFile).Trim()
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_22a9eb2cecee6010' -Arguments @{ serverPid = "$serverPid"; port = "$Port" })
Write-Output "  Local:  http://localhost:$Port/status/"
if ($ip) {
    Write-Output "  Remote: http://${ip}:$Port/status/"
}
Write-Output "  Host:   http://${machineName}:$Port/status/"
Write-Output ""

# --- REGION: Publish where this service can be reached
# See https://yuruna.link/42e5cdfd-0048
$ServiceMarkerFile = Join-Path $RuntimeDir 'status-service.json'
try {
    $markerHost = if ($script:PrimaryIpv4) { $script:PrimaryIpv4 } else { 'localhost' }
    $markerBody = [ordered]@{
        active       = $true
        area         = 'status-service'
        startedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        port         = $Port
        baseUrl      = "http://${markerHost}:$Port/"
        localUrl     = "http://localhost:$Port/"
        processId    = $serverPid
    }
    $markerJson = ((ConvertTo-Json -InputObject $markerBody -Depth 5) -replace "`r`n", "`n").TrimEnd() + "`n"
    [System.IO.File]::WriteAllText($ServiceMarkerFile, $markerJson, [System.Text.UTF8Encoding]::new($false))
} catch {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_79a383bb842b92af' -Arguments @{ message = "$($_.Exception.Message)" })
}

# --- REGION: LAN reachability self-heal (all host types)
# See https://yuruna.link/42e5cdfd-0049
if (-not $RefreshSafe) {
    Import-Module (Join-Path $ModulesDir 'Test.StatusFirewall.psm1') -Force
    $fw = Set-YurunaStatusFirewallRule -Port $Port -NonInteractive
    if ($fw.Changed) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_be11a610adef5489' -Arguments @{ message = "$($fw.Message)" })
    } elseif ($fw.Blocked) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_298b29b58a48d4d4' -Arguments @{ message = "$($fw.Message)" })
        if ($ip) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.status_lan_clients_time_out' -Arguments @{ port = "$Port"; address = "$ip" })
        }
    }
}

Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1ab8b41c49078fda')
if ($RefreshSafe) {
    $startedPid = 0
    $startedAt = [long]0
    try { $null = [int]::TryParse(([System.IO.File]::ReadAllText($PidFile)).Trim(), [ref]$startedPid) } catch { $startedPid = 0 }
    if ($startedPid -gt 0) {
        try { $startedAt = [DateTimeOffset]::new((Get-Process -Id $startedPid -ErrorAction Stop).StartTime).ToUnixTimeMilliseconds() } catch { $startedAt = [long]0 }
    }
    Complete-RefreshSafeStart -Outcome 'started' -ProcessId $startedPid -StartTimeUnixMs $startedAt -Sha ([string]$launchSha) -ShaMatches $true
}
Exit-StatusServiceStartupLock
} finally {
    Exit-StatusServiceStartupLock
}
