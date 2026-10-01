<#PSScriptInfo
.VERSION 2026.09.30
.GUID 421acc52-385e-488d-859e-c51ce10fdcdc
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service listener responsiveness live harness pester
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
    A live status listener stays responsive while request bodies are
    withheld, trickled or oversized, and while every worker it launched hangs.
.DESCRIPTION
    The listener handles one request context at a time, so the only proof
    that a pending body or a slow worker cannot park it is a real listener on
    a real socket. This suite generates the server from the launcher's
    template, starts it on an ephemeral port against a scratch runtime, log
    and HOME, and drives it with raw sockets (for withheld, trickled and
    chunked bodies) and an HTTP client (for everything else).

    The server runs from a scratch repository root whose modules are links
    to this repository's, except three that are replaced by stand-ins: the
    refresh module (capability and worker vector), the refresh journal
    (admission and the start-cycle reservation, kept in a scratch JSON file)
    and the detached launcher (which starts the stand-in workers). The
    stand-in workers carry the real workers' parameter blocks, record their
    PID and sleep, so every launch is observable and every worker "hangs".
    Nothing touches the real status service, its runtime or its port.

    Teardown kills only processes whose command line names the scratch tree.
    The run needs POSIX symbolic links; on Windows it is skipped and the
    native run is a release gate.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:ServicePath = Join-Path $script:RepoRoot 'test/service/Start-StatusService.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path
$script:HarnessReady = $false
$script:HarnessSkipReason = ''

$script:StubHostRefresh = @'
function Get-VirtualizationRepairRung { [CmdletBinding()] param([string]$HostType) $null = $HostType
    $order = 0
    foreach ($name in @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')) {
        [pscustomobject]@{ Name = $name; Order = $order; Available = ($order -le 2) }; $order++ } }
function Get-HarnessJournal { $path = Join-Path $env:YURUNA_TEST_STUB_DIR 'journal.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ requests = @(); reservation = $null } }
    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -AsHashtable) }
function Get-HostRefreshCapability { [CmdletBinding()] param([string]$HostType, [string]$RepoRoot, [string]$JournalPath) $null = $HostType, $RepoRoot, $JournalPath
    $journal = Get-HarnessJournal
    $active = @($journal.requests | Where-Object { $_.state -in @('queued', 'running') }).Count -gt 0
    return [ordered]@{ protocol = 1; availability = 'available'; ceiling = 'start-if-stopped'; reason = ''; state = $(if ($active) { 'active' } else { 'idle' }) } }
function New-HostRefreshBudget { [CmdletBinding()] param([long]$ExpiryTick, [long]$PreAdmissionExpiryTick, [scriptblock]$ClockTicks) $null = $ExpiryTick, $PreAdmissionExpiryTick, $ClockTicks
    $now = [Environment]::TickCount64; return [pscustomobject]@{ TotalExpiryTick = $now + 915000; PreAdmissionExpiryTick = $now + 60000 } }
function New-HostRefreshWorkerArgumentList { [CmdletBinding()] param([string]$RepoRoot, [string]$RequestId, $Budget, [switch]$IncludeInterpreterArgument) $null = $RepoRoot, $IncludeInterpreterArgument
    '-RequestId'; $RequestId; '-DeadlineTickMs'; [string]$Budget.TotalExpiryTick; '-PreAdmissionDeadlineTickMs'; [string]$Budget.PreAdmissionExpiryTick }
function Publish-HostRefreshQueuedState { [CmdletBinding()] param([string]$RuntimeDir, [string]$RequestId, [string]$Channel)
    [IO.File]::WriteAllText((Join-Path $RuntimeDir 'host-refresh.state.json'), (ConvertTo-Json -Compress -InputObject ([ordered]@{ schemaVersion = 1; requestId = $RequestId; phase = 'queued'; state = 'queued'; channel = $Channel }))); return $true }
Export-ModuleMember -Function Get-VirtualizationRepairRung, Get-HostRefreshCapability, New-HostRefreshBudget, New-HostRefreshWorkerArgumentList, Publish-HostRefreshQueuedState
'@

$script:StubHostRefreshIntent = @'
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
function Get-HarnessJournalPath { return (Join-Path $env:YURUNA_TEST_STUB_DIR 'journal.json') }
function Read-HarnessJournal { $path = Get-HarnessJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @{ requests = @(); reservation = $null } }
    $journal = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -AsHashtable
    $journal.requests = @($journal.requests); return $journal }
function Save-HarnessJournal { param($Journal) [IO.File]::WriteAllText((Get-HarnessJournalPath), (ConvertTo-Json -Compress -Depth 6 -InputObject $Journal)) }
function Add-HarnessCall { param([string]$Line) Add-Content -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'calls.log') -Value $Line }
function Request-HostRefreshAdmission { [CmdletBinding(SupportsShouldProcess)] param([string]$RequestId, [string]$Channel, [string]$Tier, [string]$MaxRung, [string]$RuntimeDir, [string]$HostType, [hashtable]$Context, $AdmissionLock, [int]$AdmissionWaitMilliseconds, [scriptblock]$UtcNow)
    $null = $RuntimeDir, $HostType, $Context, $AdmissionLock, $UtcNow
    Add-HarnessCall "admit:$RequestId|$Channel|$Tier|$MaxRung|$AdmissionWaitMilliseconds"
    $journal = Read-HarnessJournal
    if ($journal.reservation) { return [pscustomobject]@{ Decision = 'busy'; RequestId = $RequestId; ActiveKind = 'start-cycle'; ActiveRequestId = $journal.reservation.operationId; Reason = 'start-cycle-active' } }
    $known = @($journal.requests | Where-Object { $_.requestId -eq $RequestId }) | Select-Object -First 1
    if ($known) {
        if ($known.maxRung -ne $MaxRung) { return [pscustomobject]@{ Decision = 'policy-mismatch'; RequestId = $RequestId } }
        if ($known.state -eq 'completed') { return [pscustomobject]@{ Decision = 'completed'; RequestId = $RequestId; State = 'completed'; Verdict = $known.verdict; Ceiling = $known.maxRung } }
        if ($known.launch -eq 'launch-failed') { return [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId; Attempt = 1; Ceiling = $known.maxRung } }
        return [pscustomobject]@{ Decision = 'already-claimed'; RequestId = $RequestId; Ceiling = $known.maxRung } }
    $active = @($journal.requests | Where-Object { $_.state -in @('queued', 'running') }) | Select-Object -First 1
    if ($active) { return [pscustomobject]@{ Decision = 'busy'; RequestId = $RequestId; ActiveKind = 'host-refresh'; ActiveRequestId = $active.requestId } }
    $journal.requests += @{ requestId = $RequestId; maxRung = $MaxRung; state = 'queued'; launch = 'pending'; verdict = '' }
    Save-HarnessJournal $journal
    return [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId; Attempt = 1; Ceiling = $MaxRung } }
function Set-HostRefreshLaunchOutcome { [CmdletBinding(SupportsShouldProcess)] param([string]$RequestId, [string]$Outcome, $Launch)
    $null = $Launch; Add-HarnessCall "outcome:$RequestId|$Outcome"
    $journal = Read-HarnessJournal
    foreach ($request in $journal.requests) { if ($request.requestId -eq $RequestId) { $request.launch = $Outcome } }
    Save-HarnessJournal $journal; return [pscustomobject]@{ Saved = $true; Reason = 'ok' } }
function Get-HostRefreshPrivateWorkDir { [CmdletBinding()] param([switch]$NoCreate)
    $leaf = Get-YurunaPrivateStatePath -Name 'stdin.empty' -Subdirectory 'work' -NoCreate:$NoCreate
    if (-not $leaf.Resolved) { return $null }; return (Split-Path -Parent $leaf.Path) }
function Get-YurunaHostRefreshLockPath { [CmdletBinding()] param([switch]$NoCreate)
    $leaf = Get-YurunaPrivateStatePath -Name 'host-refresh.lock' -NoCreate:$NoCreate; if ($leaf.Resolved) { return $leaf.Path }; return $null }
function Request-HostRefreshStartCycleReservation { [CmdletBinding(SupportsShouldProcess)] param([string]$OperationId, [string]$RuntimeDir, [int]$AdmissionWaitMilliseconds)
    $null = $RuntimeDir; Add-HarnessCall "reserve:$OperationId|$AdmissionWaitMilliseconds"
    $journal = Read-HarnessJournal
    $active = @($journal.requests | Where-Object { $_.state -in @('queued', 'running') }) | Select-Object -First 1
    if ($active) { return [pscustomobject]@{ Decision = 'busy'; ActiveKind = 'host-refresh'; ActiveRequestId = $active.requestId } }
    if ($journal.reservation) { return [pscustomobject]@{ Decision = 'busy'; ActiveKind = 'start-cycle'; ActiveRequestId = $journal.reservation.operationId } }
    $journal.reservation = @{ operationId = $OperationId; generation = ('gen-' + [Guid]::NewGuid().ToString('N')) }
    Save-HarnessJournal $journal
    return [pscustomobject]@{ Decision = 'reserved'; Generation = $journal.reservation.generation } }
function Set-HostRefreshStartCycleLaunch { [CmdletBinding()] param([string]$OperationId, [string]$Generation, [string]$Outcome, $Launch)
    $null = $Launch; Add-HarnessCall "reservation-launch:$OperationId|$Generation|$Outcome"
    if ($Outcome -eq 'launch-failed') { $journal = Read-HarnessJournal; $journal.reservation = $null; Save-HarnessJournal $journal }
    return [pscustomobject]@{ Saved = $true } }
Export-ModuleMember -Function Request-HostRefreshAdmission, Set-HostRefreshLaunchOutcome, Get-HostRefreshPrivateWorkDir, Get-YurunaHostRefreshLockPath,
    Request-HostRefreshStartCycleReservation, Set-HostRefreshStartCycleLaunch
'@

$script:StubInnerSpawn = @'
function Get-PwshExePath { [CmdletBinding()] param() return [Environment]::ProcessPath }
function Start-YurunaDetachedProcess { [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath, [string]$WorkingDirectory, [string]$StdOutPath, [string]$StdErrPath, [string]$PrivateDirectory, [string[]]$ArgumentList,
        [hashtable]$Environment, [string]$StdInPath, [string]$HandshakePath, [int]$WaitForHandshakeMilliseconds, $Deadline)
    $null = $PrivateDirectory, $HandshakePath, $WaitForHandshakeMilliseconds, $Deadline
    Add-Content -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'calls.log') -Value ("launch:$FilePath " + (@($ArgumentList) -join ' '))
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FilePath) + @($ArgumentList)
    $process = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList $arguments -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath -RedirectStandardInput $StdInPath -PassThru
    return [pscustomobject]@{ Launched = $true; Reason = 'launched'; LauncherPid = $process.Id; FinalPid = $process.Id } }
Export-ModuleMember -Function Get-PwshExePath, Start-YurunaDetachedProcess
'@

function Get-StandInWorker {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$ParamBlock)
    return @"
[CmdletBinding()]
param(
$ParamBlock
)
[IO.File]::WriteAllText((Join-Path `$env:YURUNA_TEST_PID_DIR ('$Kind.' + `$PID)), [string]`$PID)
Start-Sleep -Seconds 120
"@
}

function New-HarnessTree {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway test tree.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $root = New-YurunaTestTempDir -Prefix 'yuruna-listener-harness'
    $tree = [pscustomobject]@{
        Root = $root; Repo = (Join-Path $root 'repo'); Runtime = (Join-Path $root 'runtime'); Log = (Join-Path $root 'log')
        Home = (Join-Path $root 'home'); Pids = (Join-Path $root 'pids'); Stub = (Join-Path $root 'stub')
    }
    $modules = Join-Path $tree.Repo 'test/modules'
    $null = New-Item -ItemType Directory -Path $modules, (Join-Path $tree.Repo 'test/lab'), $tree.Runtime, $tree.Log, $tree.Home, $tree.Pids, $tree.Stub
    foreach ($name in @('automation', 'globalization')) {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $tree.Repo $name) -Target (Join-Path $script:RepoRoot $name)
    }
    $replaced = @('Test.HostRefresh.psm1', 'Test.HostRefreshIntent.psm1', 'Test.InnerSpawn.psm1', 'Invoke-HostDiagnosticWorker.ps1', 'Invoke-StartCycleWorker.ps1')
    foreach ($file in @(Get-ChildItem -LiteralPath $here -File)) {
        if ($replaced -contains $file.Name -or $file.Name -like '*.Tests.ps1') { continue }
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $modules $file.Name) -Target $file.FullName
    }
    [IO.File]::WriteAllText((Join-Path $modules 'Test.HostRefresh.psm1'), $script:StubHostRefresh)
    [IO.File]::WriteAllText((Join-Path $modules 'Test.HostRefreshIntent.psm1'), $script:StubHostRefreshIntent)
    [IO.File]::WriteAllText((Join-Path $modules 'Test.InnerSpawn.psm1'), $script:StubInnerSpawn)
    [IO.File]::WriteAllText((Join-Path $tree.Repo 'test/lab/Invoke-HostRefresh.ps1'), (Get-StandInWorker -Kind 'refresh' -ParamBlock @'
    [string]$RequestId, [long]$DeadlineTickMs, [long]$PreAdmissionDeadlineTickMs
'@))
    [IO.File]::WriteAllText((Join-Path $modules 'Invoke-StartCycleWorker.ps1'), (Get-StandInWorker -Kind 'start-cycle' -ParamBlock @'
    [string]$OperationId, [string]$Generation, [string]$RuntimeDir, [string]$CleanupScriptPath, [string]$RunnerScriptPath,
    [string]$WorkingDirectory, [int]$LockWaitSeconds, [int]$CleanupTimeoutSeconds
'@))
    [IO.File]::WriteAllText((Join-Path $modules 'Invoke-HostDiagnosticWorker.ps1'), (Get-StandInWorker -Kind 'diagnostic' -ParamBlock @'
    [string]$RunId, [string]$DiagnosticScriptPath, [string]$WorkDirectory, [string]$WorkingDirectory, [int]$TimeoutSeconds, [int]$MaxReportChars
'@))
    [IO.File]::WriteAllText((Join-Path $tree.Runtime 'status.json'), '{"overallStatus":"running","cyclePaused":false}')
    return $tree
}

function Invoke-HarnessRequest {
    <#
    .SYNOPSIS
        One HTTP request to the harness listener; never throws on a status.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'OPTIONS', 'HEAD')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Path,
        [string]$Body,
        [string]$ContentType = 'application/json',
        [switch]$NoCsrfHeader,
        [int]$TimeoutMs = 5000
    )
    $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "http://127.0.0.1:$($script:Port)/$Path")
    if (-not $NoCsrfHeader) { $null = $message.Headers.TryAddWithoutValidation('X-Yuruna', '1') }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $message.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.UTF8Encoding]::new($false))
        $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        $response = $script:Client.SendAsync($message, $cts.Token).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $watch.Stop()
        $json = $null
        try { $json = ConvertFrom-Json -InputObject $text } catch { $json = $null }
        $retryAfter = if ($response.Headers.RetryAfter) { [string]$response.Headers.RetryAfter } else { '' }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Text = $text; Json = $json; ElapsedMs = $watch.ElapsedMilliseconds; RetryAfter = $retryAfter }
    } finally { $cts.Dispose(); $message.Dispose() }
}

function Open-RawRequest {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Opens a loopback connection to the harness.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Head)
    $client = [System.Net.Sockets.TcpClient]::new()
    $client.Connect([System.Net.IPAddress]::Loopback, $script:Port)
    $stream = $client.GetStream()
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Head)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    return [pscustomobject]@{ Client = $client; Stream = $stream; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Wait-RawResponse {
    <#
    .SYNOPSIS
        Wait for the listener to answer or close a raw connection, optionally
        sending one more byte every interval meanwhile.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Raw,
        [int]$TimeoutMs = 6000,
        [int]$TrickleEveryMs = 0,
        [string]$TrickleText = 'x'
    )
    $buffer = [byte[]]::new(8192)
    $received = [System.Text.StringBuilder]::new()
    $nextTrickle = $TrickleEveryMs
    $answeredAt = -1
    while ($Raw.Watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Raw.Client.Available -gt 0) {
            $count = $Raw.Stream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) { break }
            if ($answeredAt -lt 0) { $answeredAt = $Raw.Watch.ElapsedMilliseconds }
            $null = $received.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $count))
            continue
        }
        if ($Raw.Client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and $Raw.Client.Available -eq 0) {
            if ($answeredAt -lt 0) { $answeredAt = $Raw.Watch.ElapsedMilliseconds }
            break
        }
        if ($TrickleEveryMs -gt 0 -and $answeredAt -lt 0 -and $Raw.Watch.ElapsedMilliseconds -ge $nextTrickle) {
            try {
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($TrickleText)
                $Raw.Stream.Write($bytes, 0, $bytes.Length)
            } catch { if ($answeredAt -lt 0) { $answeredAt = $Raw.Watch.ElapsedMilliseconds }; break }
            $nextTrickle += $TrickleEveryMs
        }
        Start-Sleep -Milliseconds 20
    }
    try { $Raw.Client.Dispose() } catch { $null = $_ }
    $text = $received.ToString()
    $status = 0
    if ($text -match '^HTTP/1\.\d (\d{3})') { $status = [int]$Matches[1] }
    return [pscustomobject]@{ Status = $status; Text = $text; AnsweredMs = $answeredAt }
}

function Get-HarnessCall {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Prefix = '')
    $path = Join-Path $script:Tree.Stub 'calls.log'
    if (-not (Test-Path -LiteralPath $path)) { return [string[]]@() }
    return [string[]]@([IO.File]::ReadAllLines($path) | Where-Object { $_.StartsWith($Prefix) })
}

function Reset-HarnessJournal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Resets a scratch fixture file.')]
    [CmdletBinding()]
    param([AllowNull()][hashtable]$Journal)
    $path = Join-Path $script:Tree.Stub 'journal.json'
    if ($null -eq $Journal) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; return }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -Compress -Depth 6 -InputObject $Journal))
}

function Get-StandInPid {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Kind)
    return [string[]]@(Get-ChildItem -LiteralPath $script:Tree.Pids -Filter "$Kind.*" -File -ErrorAction SilentlyContinue | ForEach-Object Name)
}

function Stop-HarnessProcess {
    <#
    .SYNOPSIS
        Stop a process this suite started, and only when its command line names
        the scratch tree.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops only processes this suite started, verified by command line.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $commandLine = ''
    try { $commandLine = ([IO.File]::ReadAllText("/proc/$ProcessId/cmdline")).Replace([char]0, ' ') } catch { $commandLine = '' }
    if (-not $commandLine -and -not $IsLinux) {
        try { $commandLine = [string]((& /bin/ps -o command= -p $ProcessId 2>$null) -join ' ') } catch { $commandLine = '' }
    }
    if (-not ([string]$commandLine).Contains($script:Tree.Root)) { return }
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).Kill($true) } catch { $null = $_ }
}

if ($IsWindows) {
    $script:HarnessSkipReason = 'the harness tree needs POSIX symbolic links; the native Windows run is a release gate'
} else {
    $script:Tree = New-HarnessTree
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, 0)
    $probe.Start(); $script:Port = $probe.LocalEndpoint.Port; $probe.Stop()
    # The template's own inputs, bound here the way the launcher binds them.
    $Port = $script:Port
    $StatusDir = Join-Path $script:RepoRoot 'test/status'
    $RuntimeDir = $script:Tree.Runtime
    $LogDir = $script:Tree.Log
    $RepoRoot = $script:Tree.Repo
    $detectedHost = 'host.ubuntu.kvm'
    $ServerConfigPath = Join-Path $script:Tree.Repo 'test/test.config.yml'
    $StatusWorkerRoot = $script:Tree.Repo
    $lines = [IO.File]::ReadAllLines($script:ServicePath)
    $start = -1; $end = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($start -lt 0 -and $lines[$i] -match '^\$serverScript = @"$') { $start = $i + 1; continue }
        if ($start -ge 0 -and $lines[$i] -match '^"@$') { $end = $i - 1; break }
    }
    $server = $ExecutionContext.InvokeCommand.ExpandString((($lines[$start..$end]) -join "`n"))
    $null = $Port, $StatusDir, $RuntimeDir, $LogDir, $RepoRoot, $detectedHost, $ServerConfigPath, $StatusWorkerRoot
    $script:ServerFile = Join-Path $script:Tree.Root 'server.ps1'
    [IO.File]::WriteAllText($script:ServerFile, $server)
    $saved = @{}
    foreach ($name in @('HOME', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_TEST_STUB_DIR', 'YURUNA_TEST_PID_DIR')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:HOME = $script:Tree.Home
        $env:YURUNA_RUNTIME_DIR = $script:Tree.Runtime
        $env:YURUNA_LOG_DIR = $script:Tree.Log
        $env:YURUNA_TEST_STUB_DIR = $script:Tree.Stub
        $env:YURUNA_TEST_PID_DIR = $script:Tree.Pids
        $script:Server = Start-Process -FilePath $script:Pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-File', $script:ServerFile `
            -RedirectStandardOutput (Join-Path $script:Tree.Root 'server.stdout') -RedirectStandardError (Join-Path $script:Tree.Root 'server.stderr') -PassThru
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
    $script:Client = [System.Net.Http.HttpClient]::new()
    $script:Client.Timeout = [TimeSpan]::FromSeconds(20)
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ([DateTime]::UtcNow -lt $deadline -and -not $script:HarnessReady) {
        if ($script:Server.HasExited) { break }
        try { $script:HarnessReady = ((Invoke-HarnessRequest -Path 'status/' -TimeoutMs 2000).Status -eq 200) } catch { Start-Sleep -Milliseconds 300 }
    }
    if ($script:HarnessReady) {
        # Warm the paths whose first use loads catalogs and parses worker
        # scripts, so the timed cases measure the loop and not a cold start.
        $null = Invoke-HarnessRequest -Path 'control/control-status' -TimeoutMs 15000
        $null = Invoke-HarnessRequest -Path 'runtime/status.json' -TimeoutMs 15000
    } else {
        $errors = if (Test-Path -LiteralPath (Join-Path $script:Tree.Runtime 'server.err')) { [IO.File]::ReadAllText((Join-Path $script:Tree.Runtime 'server.err')) } else { '' }
        $stderr = if (Test-Path -LiteralPath (Join-Path $script:Tree.Root 'server.stderr')) { [IO.File]::ReadAllText((Join-Path $script:Tree.Root 'server.stderr')) } else { '' }
        $script:HarnessSkipReason = ("the harness listener never answered: " + (($errors + ' ' + $stderr) -replace "`e\[[0-9;]*[A-Za-z]", '')).Trim()
    }
}
}

AfterAll {
    if ($script:Client) { $script:Client.Dispose() }
    if ($script:Tree) {
        foreach ($file in @(Get-ChildItem -LiteralPath $script:Tree.Pids -File -ErrorAction SilentlyContinue)) {
            $recorded = 0
            if ([int]::TryParse(([IO.File]::ReadAllText($file.FullName)).Trim(), [ref]$recorded)) { Stop-HarnessProcess -ProcessId $recorded }
        }
        if ($script:Server) { Stop-HarnessProcess -ProcessId $script:Server.Id }
        Start-Sleep -Milliseconds 300
        Remove-YurunaTestTempDir $script:Tree.Root
    }
}

Describe 'a live listener stays responsive around bodies and workers' {

    It 'answers concurrent refresh, start-cycle and diagnostic requests quickly while the read-only routes keep answering' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $tasks = @{}
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($spec in @(
                @{ Name = 'refresh'; Method = 'POST'; Path = 'control/host-refresh'; Body = '{}' },
                @{ Name = 'start-cycle'; Method = 'POST'; Path = 'control/start-cycle' },
                @{ Name = 'diagnostic'; Method = 'GET'; Path = 'control/host-diagnostic' })) {
            $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($spec.Method), "http://127.0.0.1:$($script:Port)/$($spec.Path)")
            $null = $message.Headers.TryAddWithoutValidation('X-Yuruna', '1')
            if ($spec.Body) {
                $message.Content = [System.Net.Http.StringContent]::new($spec.Body, [System.Text.UTF8Encoding]::new($false))
                $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
            }
            $tasks[$spec.Name] = $script:Client.SendAsync($message)
        }
        $elapsed = @{}
        while ($elapsed.Count -lt $tasks.Count -and $watch.ElapsedMilliseconds -lt 10000) {
            foreach ($name in @($tasks.Keys)) {
                if (-not $elapsed.ContainsKey($name) -and $tasks[$name].IsCompleted) { $elapsed[$name] = $watch.ElapsedMilliseconds }
            }
            Start-Sleep -Milliseconds 10
        }
        $findings = @()
        foreach ($name in @($tasks.Keys)) {
            if (-not $elapsed.ContainsKey($name)) { $findings += "$name never answered"; continue }
            $status = [int]$tasks[$name].Result.StatusCode
            if ($status -notin @(200, 202, 409)) { $findings += "$name answered $status" }
            if ($elapsed[$name] -gt 1500) { $findings += "$name took $($elapsed[$name]) ms" }
        }
        Assert-NoFinding $findings 'a concurrent control request was slow or undocumented'
        # Refresh and start-cycle exclude each other: whichever the loop admits
        # first is launched and the other is told busy, never both.
        $admitted = @(@('refresh', 'start-cycle') | Where-Object { [int]$tasks[$_].Result.StatusCode -eq 202 })
        Assert-Equal 1 $admitted.Count 'exactly one of refresh and start-cycle is admitted'
        Assert-Equal 202 ([int]$tasks['diagnostic'].Result.StatusCode) 'the diagnostic answers pending while its worker runs'
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ([DateTime]::UtcNow -lt $deadline -and ((Get-StandInPid -Kind $admitted[0]).Count -lt 1 -or (Get-StandInPid -Kind 'diagnostic').Count -lt 1)) { Start-Sleep -Milliseconds 100 }
        Assert-True ((Get-StandInPid -Kind $admitted[0]).Count -ge 1) "the $($admitted[0]) stand-in worker is running"
        Assert-True ((Get-StandInPid -Kind 'diagnostic').Count -ge 1) 'the diagnostic stand-in worker is running'
        foreach ($attempt in 1..5) {
            foreach ($path in @('status/', 'runtime/status.json')) {
                $read = Invoke-HarnessRequest -Path $path -TimeoutMs 3000
                Assert-Equal 200 $read.Status "$path did not answer"
                Assert-True ($read.ElapsedMs -le 1000) "$path took $($read.ElapsedMs) ms while workers hang"
            }
        }
    }

    It 'answers 408 for a withheld body within its deadline, admits nothing and keeps serving meanwhile' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $admissionsBefore = (Get-HarnessCall -Prefix 'admit:').Count
        $refreshBefore = (Get-StandInPid -Kind 'refresh').Count
        $raw = Open-RawRequest -Head "POST /control/host-refresh HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n"
        Start-Sleep -Milliseconds 200
        $status = Invoke-HarnessRequest -Path 'status/' -TimeoutMs 3000
        Assert-Equal 200 $status.Status
        Assert-True ($status.ElapsedMs -le 1000) "/status/ took $($status.ElapsedMs) ms while a body was withheld"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the withheld body was answered after $($answer.AnsweredMs) ms"
        Assert-True ($answer.Status -in @(0, 408)) "a withheld body got $($answer.Status)"
        if ($answer.Status -eq 408) { Assert-Match 'body_timeout' $answer.Text }
        Assert-Equal $admissionsBefore (Get-HarnessCall -Prefix 'admit:').Count 'no admission for a body that never arrived'
        Assert-Equal $refreshBefore (Get-StandInPid -Kind 'refresh').Count 'no worker for a body that never arrived'
    }

    It 'cuts a trickled body at two seconds despite progress' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $raw = Open-RawRequest -Head "POST /control/host-refresh HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 50`r`n`r`n{"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000 -TrickleEveryMs 300 -TrickleText ' '
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the trickled body was answered after $($answer.AnsweredMs) ms"
        Assert-True ($answer.Status -in @(0, 408)) "a trickled body got $($answer.Status)"
    }

    It 'cuts a chunked trickle the same way, and refuses a chunked body past the cap' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $raw = Open-RawRequest -Head "POST /control/host-refresh HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`n`r`n"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000 -TrickleEveryMs 300 -TrickleText "1`r`n `r`n"
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the chunked trickle was answered after $($answer.AnsweredMs) ms"
        $big = ' ' * 5000
        $oversize = Open-RawRequest -Head ("POST /control/host-refresh HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`n`r`n" +
            ('{0:x}' -f $big.Length) + "`r`n" + $big + "`r`n0`r`n`r`n")
        $refused = Wait-RawResponse -Raw $oversize -TimeoutMs 4000
        Assert-Equal 413 $refused.Status 'a chunked body past 4096 bytes is refused with no declared length to go on'
        Assert-Match 'payload_too_large' $refused.Text
        $declared = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"x":"' + ('y' * 5000) + '"}')
        Assert-Equal 413 $declared.Status 'a declared length past the cap is refused before reading'
    }

    It 'turns a fifth pending body away at once and keeps serving' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $held = @()
        try {
            foreach ($i in 1..4) {
                $held += Open-RawRequest -Head "POST /control/host-refresh HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n"
            }
            Start-Sleep -Milliseconds 300
            $fifth = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body '{}'
            Assert-Equal 503 $fifth.Status
            Assert-StringEqual 'listener_busy' $fifth.Json.reason
            Assert-StringEqual '2' $fifth.RetryAfter 'the busy reply says when to retry'
            Assert-True ($fifth.ElapsedMs -le 1000) "the busy reply took $($fifth.ElapsedMs) ms"
            Assert-Equal 200 (Invoke-HarnessRequest -Path 'status/' -TimeoutMs 3000).Status
        } finally {
            foreach ($raw in $held) { $null = Wait-RawResponse -Raw $raw -TimeoutMs 4000 }
        }
    }

    It 'keeps the cross-site guard and the method check in front of the route' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $get = Invoke-HarnessRequest -Path 'control/host-refresh'
        Assert-Equal 405 $get.Status 'a GET that carries the header reaches the method check'
        $noHeader = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body '{}' -NoCsrfHeader
        Assert-Equal 403 $noHeader.Status 'a POST without the header is refused before the route'
        $preflight = Invoke-HarnessRequest -Method OPTIONS -Path 'control/host-refresh' -NoCsrfHeader
        Assert-Equal 204 $preflight.Status
        $media = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body '{}' -ContentType 'text/plain'
        Assert-Equal 415 $media.Status
    }

    It 'refuses forbidden keys with 400 and admits nothing' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $before = (Get-HarnessCall -Prefix 'admit:').Count
        foreach ($body in @('{"force":true}', '{"AllowHardStop":true}', '{"configPath":"/etc/x"}', '{"tier":"full"}')) {
            $reply = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body $body
            Assert-Equal 400 $reply.Status $body
            Assert-True ($reply.Json.reason -in @('forbidden_field', 'invalid_value')) "$body got $($reply.Json.reason)"
        }
        Assert-Equal $before (Get-HarnessCall -Prefix 'admit:').Count 'a refused body never reaches admission'
    }

    It 'replays a known request by its id and refuses a different one while it is active' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $id = [Guid]::NewGuid().ToString('D')
        $first = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"requestId":"' + $id + '","maxRung":"start-if-stopped"}')
        Assert-Equal 202 $first.Status $first.Text
        Assert-StringEqual 'spawned' $first.Json.action
        $again = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"requestId":"' + $id + '","maxRung":"start-if-stopped"}')
        Assert-Equal 202 $again.Status
        Assert-StringEqual 'already_claimed' $again.Json.action
        $other = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"requestId":"' + [Guid]::NewGuid().ToString('D') + '"}')
        Assert-Equal 409 $other.Status
        Assert-StringEqual 'busy' $other.Json.reason
        Assert-StringEqual 'host_refresh' $other.Json.activeKind
        Assert-StringEqual $id $other.Json.activeRequestId
        $changed = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"requestId":"' + $id + '","maxRung":"reclaim"}')
        Assert-Equal 409 $changed.Status
        Assert-StringEqual 'request_conflict' $changed.Json.reason
        $completedId = [Guid]::NewGuid().ToString('D')
        Reset-HarnessJournal -Journal @{ requests = @(@{ requestId = $completedId; maxRung = 'start-if-stopped'; state = 'completed'; launch = 'started'; verdict = 'partial' }); reservation = $null }
        $replay = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body ('{"requestId":"' + $completedId + '","maxRung":"start-if-stopped"}')
        Assert-Equal 200 $replay.Status
        Assert-True $replay.Json.ok
        Assert-StringEqual 'partial' $replay.Json.verdict 'a completed replay reports its stored verdict, which is what the caller must read'
    }

    It 'makes start-cycle and refresh exclude each other in both orders' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal @{ requests = @(@{ requestId = 'active-refresh'; maxRung = 'reclaim'; state = 'running'; launch = 'started'; verdict = '' }); reservation = $null }
        $blocked = Invoke-HarnessRequest -Method POST -Path 'control/start-cycle'
        Assert-Equal 409 $blocked.Status
        Assert-StringEqual 'host_refresh' $blocked.Json.activeKind
        Assert-StringEqual '/runtime/host-refresh.state.json' $blocked.Json.stateUrl
        Reset-HarnessJournal -Journal $null
        $queued = Invoke-HarnessRequest -Method POST -Path 'control/start-cycle'
        Assert-Equal 202 $queued.Status $queued.Text
        Assert-StringEqual 'queued' $queued.Json.action
        $recorded = @(Get-HarnessCall -Prefix "reservation-launch:$($queued.Json.operationId)|")
        Assert-Equal 1 $recorded.Count 'the launch of a reserved start-cycle is recorded once, first time'
        Assert-Match '\|started$' $recorded[0]
        $refresh = Invoke-HarnessRequest -Method POST -Path 'control/host-refresh' -Body '{}'
        Assert-Equal 409 $refresh.Status
        Assert-StringEqual 'start_cycle' $refresh.Json.activeKind
        Assert-StringEqual $queued.Json.operationId $refresh.Json.activeRequestId
        Assert-StringEqual '/runtime/start-cycle.state.json' $refresh.Json.stateUrl
    }

    It 'advertises the refresh capability in a small control-status reply' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $status = Invoke-HarnessRequest -Path 'control/control-status'
        Assert-Equal 200 $status.Status
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($status.Text) -lt 1024) "control-status is $([System.Text.Encoding]::UTF8.GetByteCount($status.Text)) bytes"
        Assert-Equal 1 $status.Json.refresh.protocol
        Assert-StringEqual 'available' $status.Json.refresh.availability
        Assert-StringEqual 'start-if-stopped' $status.Json.refresh.ceiling
        Assert-StringEqual 'idle' $status.Json.refresh.state
    }

    It 'answers pending on repeated diagnostic requests without launching a second worker' {
        if ($IsWindows) { Set-ItResult -Skipped -Because $script:HarnessSkipReason; return }
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $before = (Get-StandInPid -Kind 'diagnostic').Count
        $replies = @(1..4 | ForEach-Object { Invoke-HarnessRequest -Path 'control/host-diagnostic'; Start-Sleep -Milliseconds 400 })
        foreach ($reply in $replies) {
            Assert-Equal 202 $reply.Status
            Assert-StringEqual 'pending' $reply.Json.action
            Assert-StringEqual '3' $reply.RetryAfter
        }
        Start-Sleep -Milliseconds 1500
        Assert-True (((Get-StandInPid -Kind 'diagnostic').Count - $before) -le 1) 'a burst of requests launches at most one diagnostic worker'
        Assert-Equal 1 @($replies.Json.runId | Sort-Object -Unique).Count 'every pending reply names the same run'
    }
}
