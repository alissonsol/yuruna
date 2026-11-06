<#PSScriptInfo
.VERSION 2026.11.05
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
    back: it never stops a process (only -ReplaceWedged stops an owned
    listener whose lease reads wedged), never takes a port from another owner,
    never restarts a live server whose framework commit changed, and never
    runs the startup sweeps that clear control files or rewrite status.json.
    An owned server that answers is left running (existing-ready); an owned
    server that does not answer, a pidfile whose owner cannot be identified,
    a port held by anyone else, or a concurrent start is reported and left
    alone. Must run as its own process (pwsh -File): it ends with an explicit
    exit code, 0 for existing-ready or started, 2 for a start it could not
    complete, 1 for an invocation it refused. Requires YURUNA_RUNTIME_DIR to
    name the owning runtime directory.

.PARAMETER ReplaceWedged
    RefreshSafe only: an owned server that does not answer and whose liveness
    lease reads wedged (idle past its renewals, or one request past the
    ceiling) is stopped and a new one started; one whose lease reads busy,
    alive or unknown is reported as existing-unresponsive and left alone, as
    without this switch. The host-address beacon uses it to replace a wedged
    listener in the middle of a cycle, where the full start's sweeps must
    not run.

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
    [Parameter(ParameterSetName = 'RefreshSafe')][switch]$ReplaceWedged,
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
$script:RefreshSafePortWaitMs = 0
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
            if (-not $answers -and $ReplaceWedged) {
                $lease = Get-StatusServiceLeaseVerdict -Path (Join-Path $RuntimeDir 'server.lease.json') -ProcessId ([int]$ownership.Pid)
                if ($lease.Verdict -cne 'wedged') {
                    Complete-RefreshSafeStart -Outcome 'existing-unresponsive' -ProcessId $ownership.Pid -StartTimeUnixMs $ownership.StartTimeUnixMs -Reason "lease-$($lease.Verdict)"
                }
                # Ownership was proven just above by command line and start time,
                # so the process stopped here is this runtime's listener.
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.status_listener_replaced' -Arguments @{
                    processId = "$($ownership.Pid)"; state = "$($lease.State)"; route = "$($lease.Route)"; seconds = "$($lease.AgeSeconds)" })
                $stopWaitMs = [int][Math]::Max(0, [Math]::Min(10000, (Get-YurunaDeadlineRemainingMs -Deadline $script:RefreshSafeDeadline) - 8000))
                $exited = $false
                try {
                    $wedged = Get-Process -Id ([int]$ownership.Pid) -ErrorAction Stop
                    Stop-Process -Id ([int]$ownership.Pid) -Force -ErrorAction Stop
                    $exited = $wedged.WaitForExit($stopWaitMs)
                } catch [Microsoft.PowerShell.Commands.ProcessCommandException] { $exited = $true }
                catch { Write-Verbose "wedged listener stop failed: $($_.Exception.Message)" }
                if (-not $exited) {
                    Complete-RefreshSafeStart -Outcome 'existing-unresponsive' -ProcessId $ownership.Pid -StartTimeUnixMs $ownership.StartTimeUnixMs -Reason 'stop-failed'
                }
                Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
                $script:RefreshSafePortWaitMs = $stopWaitMs
                $answers = $null
            }
            if ($answers -eq $false) {
                Complete-RefreshSafeStart -Outcome 'existing-unresponsive' -ProcessId $ownership.Pid -StartTimeUnixMs $ownership.StartTimeUnixMs -Reason 'status-unanswered'
            }
            if ($null -eq $answers) { break }
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
                # A listener serves one request at a time, so a long request
                # leaves it silent for as long as that request runs. Its lease
                # says whether it is serving or wedged; one that is serving is
                # left running, and any restart for new code waits for the next
                # start rather than cutting a request off.
                $lease = Get-StatusServiceLeaseVerdict -Path (Join-Path $RuntimeDir 'server.lease.json') -ProcessId ([int]$oldPid)
                if ($lease.Verdict -in @('alive', 'busy')) {
                    Write-Output (Format-YurunaOperatorMessage -Key 'runner.status_listener_busy' -Arguments @{
                        processId = "$oldPid"; port = "$Port"; route = "$($lease.Route)"; seconds = "$($lease.AgeSeconds)" })
                    Exit-StatusServiceStartupLock
                    exit 0
                }
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_804eb754aac66717' -Arguments @{ oldPid = "$oldPid"; port = "$Port" })
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.status_listener_lease_verdict' -Arguments @{
                    processId = "$oldPid"; verdict = "$($lease.Verdict)"; reason = "$($lease.Reason)"; seconds = "$($lease.AgeSeconds)" })
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
    # A wedged listener this start just stopped may hold its port a moment longer.
    if (-not (Test-PortListenerFree -Port $Port -BudgetMs ([int]$script:RefreshSafePortWaitMs))) {
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
            # See https://yuruna.link/42e5cdfd-0040
            # A whole-document read-modify-write under the shared status-file
            # lock, through the atomic writer: the runner and the listener's
            # pause routes may be writing the same document while the service
            # starts, and the copy read above is stale by the time it is written.
            if (-not (Get-Command Update-StatusDocumentField -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $ModulesDir 'Test.Status.psm1') -Global -DisableNameChecking -ErrorAction Stop
            }
            if (-not (Update-StatusDocumentField -StatusPath $StatusFile -Field @{ repoUrl = $repoUrl } -Confirm:$false)) {
                throw 'status.json was not rewritten'
            }
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d930446c8044b6fe' -Arguments @{ repoUrl = "$repoUrl" })
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d697f222c6bc539a' -Arguments @{ value = "$_" })
    }
}

# --- REGION: Clean up leftovers from older layouts
# See https://yuruna.link/42e5cdfd-0040
# Credential copies under names that earlier releases wrote and nothing reads.
# They are removed even on a refresh-safe start, because each one is a secret
# the runtime directory should not hold.
foreach ($legacyCredential in @('yuruna-caching-proxy.yml', 'yuruna-caching-proxy.yml.backup', 'caching-proxy.txt')) {
    Remove-Item -LiteralPath (Join-Path $RuntimeDir $legacyCredential) -Force -ErrorAction SilentlyContinue
}
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
                    [void](Remove-PortMap -Owner 'caching-proxy-service' -Confirm:$false)
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
                        [void](Remove-PortMap -Owner 'caching-proxy-service' -Confirm:$false)
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
                            $mapResult = Add-PortMap -Owner 'caching-proxy-service' @portMapArgs -Confirm:$false
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
# The runtime is Invoke-StatusServiceRuntime.ps1 beside this script. The
# launcher written below calls it with this start's values, and its path on
# the server's command line is what identifies the server process.
# Where the detached workers' entry points resolve from: always the
# repository in production.
$StatusWorkerRoot = $RepoRoot
# Passed unconditionally: the port and repoUrl paths above only resolved the
# config path on some branches, and a server given an empty path reads its
# watchdog bounds from no file.
$ServerConfigPath = Join-Path $TestRoot 'test.config.yml'
$serverRuntimeFile = Join-Path $PSScriptRoot 'Invoke-StatusServiceRuntime.ps1'
$quoteLiteral = { param([string]$Value) "'" + ($Value -replace "'", "''") + "'" }
$serverScript = "& $(& $quoteLiteral $serverRuntimeFile) -Port $Port -StatusDir $(& $quoteLiteral $StatusDir) " +
    "-RuntimeDir $(& $quoteLiteral $RuntimeDir) -LogDir $(& $quoteLiteral $LogDir) -RepoRoot $(& $quoteLiteral $RepoRoot) " +
    "-ServerHostType $(& $quoteLiteral $detectedHost) -ServerConfigPath $(& $quoteLiteral $ServerConfigPath) " +
    "-WorkerRoot $(& $quoteLiteral $StatusWorkerRoot)`n"

# See https://yuruna.link/42e5cdfd-0045
Remove-Item (Join-Path $RuntimeDir '.status-service.ps1') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $RuntimeDir 'server.out') -Force -ErrorAction SilentlyContinue

$serverScriptFile = Join-Path $RuntimeDir ".status-service.ps1"
Set-Content -Path $serverScriptFile -Value $serverScript -Encoding UTF8BOM

# See https://yuruna.link/42e5cdfd-0045
foreach ($parsedScript in @($serverScriptFile, $serverRuntimeFile)) {
    $serverScriptParseError = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($parsedScript, [ref]$null, [ref]$serverScriptParseError)
    if ($serverScriptParseError -and $serverScriptParseError.Count) {
        foreach ($parseError in ($serverScriptParseError | Select-Object -First 5)) {
            Write-Output ("  line $($parseError.Extent.StartLineNumber), column $($parseError.Extent.StartColumnNumber): $($parseError.Message)")
        }
        if ($RefreshSafe) { Complete-RefreshSafeStart -Outcome 'generation-failed' -Reason 'parse-error' }
        Exit-StatusServiceStartupLock
        throw ("The status-service script $parsedScript has $($serverScriptParseError.Count) syntax error(s) and would die on startup; refusing to launch it. " +
               "Each error above is a line in that file.")
    }
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
