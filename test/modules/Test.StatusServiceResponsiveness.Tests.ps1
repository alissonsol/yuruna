<#PSScriptInfo
.VERSION 2026.11.23
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
    repair module (capability and worker vector), the host operation journal
    (admission and the start-cycle reservation, kept in a scratch JSON file)
    and the detached launcher (which starts the stand-in workers). The
    stand-in workers carry the real workers' parameter blocks, record their
    PID and sleep, so every launch is observable and every worker "hangs".
    Nothing touches the real status service, its runtime or its port.

    Teardown kills only processes whose command line names the scratch tree.
    POSIX uses links to the shared modules; Windows copies them and binds a
    localhost prefix so the harness needs no wildcard URL reservation.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Config.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:RuntimePath = Join-Path $script:RepoRoot 'test/service/Invoke-StatusServiceRuntime.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path
$script:HarnessReady = $false
$script:HarnessSkipReason = ''

if (-not ('Yuruna.TestFixtures.HarnessResponseTiming' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Yuruna.TestFixtures {
    public sealed class HarnessResponseTiming {
        public System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> Task { get; private set; }
        public long ElapsedMs { get; private set; }
        public HarnessResponseTiming(System.Threading.Tasks.Task<System.Net.Http.HttpResponseMessage> response,
                System.Diagnostics.Stopwatch clock) {
            // Capture completion on the HTTP completion thread. A delayed
            // PowerShell observer must not add its own scheduling latency.
            Task = response.ContinueWith(completed => {
                ElapsedMs = clock.ElapsedMilliseconds;
                return completed.GetAwaiter().GetResult();
            }, System.Threading.CancellationToken.None,
                System.Threading.Tasks.TaskContinuationOptions.ExecuteSynchronously,
                System.Threading.Tasks.TaskScheduler.Default);
        }
    }
}
'@
}

$script:StubHostRepair = @'
function Get-VirtualizationRepairRung { [CmdletBinding()] param([string]$HostType) $null = $HostType
    $order = 0
    foreach ($name in @('probe', 'reclaim', 'start-if-stopped', 'restart-if-hung', 'restart-broker', 'reapply-settings', 'reinstall', 'reboot')) {
        [pscustomobject]@{ Name = $name; Order = $order; Available = ($order -le 2) }; $order++ } }
function Get-HarnessJournal { $path = Join-Path $env:YURUNA_TEST_STUB_DIR 'journal.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ requests = @(); reservation = $null } }
    return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -AsHashtable) }
function Get-HostRepairCapability { [CmdletBinding()] param([string]$HostType, [string]$RepoRoot, [string]$JournalPath) $null = $HostType, $RepoRoot, $JournalPath
    $journal = Get-HarnessJournal
    $active = @($journal.requests | Where-Object { $_.state -in @('queued', 'running') }).Count -gt 0
    return [ordered]@{ protocol = 1; availability = 'available'; ceiling = 'start-if-stopped'; reason = ''; state = $(if ($active) { 'active' } else { 'idle' }) } }
function New-HostRepairBudget { [CmdletBinding()] param([long]$ExpiryTick, [long]$PreAdmissionExpiryTick, [scriptblock]$ClockTicks) $null = $ExpiryTick, $PreAdmissionExpiryTick, $ClockTicks
    $now = [Environment]::TickCount64; return [pscustomobject]@{ TotalExpiryTick = $now + 915000; PreAdmissionExpiryTick = $now + 60000 } }
function New-HostRepairWorkerArgumentList { [CmdletBinding()] param([string]$RepoRoot, [string]$RequestId, $Budget, [switch]$IncludeInterpreterArgument) $null = $RepoRoot, $IncludeInterpreterArgument
    '-RequestId'; $RequestId; '-DeadlineTickMs'; [string]$Budget.TotalExpiryTick; '-PreAdmissionDeadlineTickMs'; [string]$Budget.PreAdmissionExpiryTick }
function Publish-HostRepairQueuedState { [CmdletBinding()] param([string]$RuntimeDir, [string]$RequestId, [string]$Channel)
    [IO.File]::WriteAllText((Join-Path $RuntimeDir 'host-repair.state.json'), (ConvertTo-Json -Compress -InputObject ([ordered]@{ schemaVersion = 1; requestId = $RequestId; phase = 'queued'; state = 'queued'; channel = $Channel }))); return $true }
Export-ModuleMember -Function Get-VirtualizationRepairRung, Get-HostRepairCapability, New-HostRepairBudget, New-HostRepairWorkerArgumentList, Publish-HostRepairQueuedState
'@

$script:StubHostOperationJournal = @'
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Global -DisableNameChecking
function Get-HarnessJournalPath { return (Join-Path $env:YURUNA_TEST_STUB_DIR 'journal.json') }
function Read-HarnessJournal { $path = Get-HarnessJournalPath
    if (-not (Test-Path -LiteralPath $path)) { return @{ requests = @(); reservation = $null } }
    $journal = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)) -AsHashtable
    $journal.requests = @($journal.requests); return $journal }
function Save-HarnessJournal { param($Journal) [IO.File]::WriteAllText((Get-HarnessJournalPath), (ConvertTo-Json -Compress -Depth 6 -InputObject $Journal)) }
function Add-HarnessCall { param([string]$Line) Add-Content -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'calls.log') -Value $Line }
function Request-HostRepairAdmission { [CmdletBinding(SupportsShouldProcess)] param([string]$RequestId, [string]$Channel, [string]$Tier, [string]$MaxRung, [string]$RuntimeDir, [string]$HostType, [hashtable]$Context, $AdmissionLock, [int]$AdmissionWaitMilliseconds, [scriptblock]$UtcNow)
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
    if ($active) { return [pscustomobject]@{ Decision = 'busy'; RequestId = $RequestId; ActiveKind = 'host-repair'; ActiveRequestId = $active.requestId } }
    $journal.requests += @{ requestId = $RequestId; maxRung = $MaxRung; state = 'queued'; launch = 'pending'; verdict = '' }
    Save-HarnessJournal $journal
    return [pscustomobject]@{ Decision = 'spawn'; RequestId = $RequestId; Attempt = 1; Ceiling = $MaxRung } }
function Set-HostRepairLaunchOutcome { [CmdletBinding(SupportsShouldProcess)] param([string]$RequestId, [string]$Outcome, $Launch)
    $null = $Launch; Add-HarnessCall "outcome:$RequestId|$Outcome"
    $journal = Read-HarnessJournal
    foreach ($request in $journal.requests) { if ($request.requestId -eq $RequestId) { $request.launch = $Outcome } }
    Save-HarnessJournal $journal; return [pscustomobject]@{ Saved = $true; Reason = 'ok' } }
function Get-HostRepairPrivateWorkDir { [CmdletBinding()] param([switch]$NoCreate)
    $leaf = Get-YurunaPrivateStatePath -Name 'stdin.empty' -Subdirectory 'work' -NoCreate:$NoCreate
    if (-not $leaf.Resolved) { return $null }; return (Split-Path -Parent $leaf.Path) }
function Get-YurunaHostOperationLockPath { [CmdletBinding()] param([switch]$NoCreate)
    $leaf = Get-YurunaPrivateStatePath -Name 'host-operation.lock' -NoCreate:$NoCreate; if ($leaf.Resolved) { return $leaf.Path }; return $null }
function Request-StartCycleReservation { [CmdletBinding(SupportsShouldProcess)] param([string]$OperationId, [string]$RuntimeDir, [int]$AdmissionWaitMilliseconds)
    $null = $RuntimeDir; Add-HarnessCall "reserve:$OperationId|$AdmissionWaitMilliseconds"
    $journal = Read-HarnessJournal
    $active = @($journal.requests | Where-Object { $_.state -in @('queued', 'running') }) | Select-Object -First 1
    if ($active) { return [pscustomobject]@{ Decision = 'busy'; ActiveKind = 'host-repair'; ActiveRequestId = $active.requestId } }
    if ($journal.reservation) { return [pscustomobject]@{ Decision = 'busy'; ActiveKind = 'start-cycle'; ActiveRequestId = $journal.reservation.operationId } }
    $journal.reservation = @{ operationId = $OperationId; generation = ('gen-' + [Guid]::NewGuid().ToString('N')) }
    Save-HarnessJournal $journal
    return [pscustomobject]@{ Decision = 'reserved'; Generation = $journal.reservation.generation } }
function Set-StartCycleLaunch { [CmdletBinding()] param([string]$OperationId, [string]$Generation, [string]$Outcome, $Launch)
    $null = $Launch; Add-HarnessCall "reservation-launch:$OperationId|$Generation|$Outcome"
    if ($Outcome -eq 'launch-failed') { $journal = Read-HarnessJournal; $journal.reservation = $null; Save-HarnessJournal $journal }
    return [pscustomobject]@{ Saved = $true } }
# A stand-in controller holds its lock while controller.held exists.
function Get-HostUpdateControllerLockState { [CmdletBinding()] param()
    if (Test-Path -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'controller.held')) { return 'held' }; return 'free' }
function Get-HostUpdateCapability { [CmdletBinding()] param([string]$RepoRoot, [string]$RuntimeDir, [string]$JournalPath, [scriptblock]$UtcNow)
    $null = $RepoRoot, $RuntimeDir, $JournalPath, $UtcNow
    return [pscustomobject]@{ LockState = (Get-HostUpdateControllerLockState); JournalStatus = 'ok'; ControllerState = $null; Protocol = 1; UpdateState = 'idle' } }
function Request-HostUpdateAdmission { [CmdletBinding(SupportsShouldProcess)] param([string]$RequestId, [string]$Channel, [string]$Scope, [string]$Drain, [int]$DrainSeconds,
        [string]$ExpectCommit, [string]$RuntimeDir, [string]$HostType, [int]$AdmissionWaitMilliseconds, [scriptblock]$UtcNow)
    $null = $RuntimeDir, $HostType, $UtcNow
    Add-HarnessCall "admit-update:$RequestId|$Channel|$Scope|$Drain|$DrainSeconds|$ExpectCommit|$AdmissionWaitMilliseconds"
    return [pscustomobject]@{ Decision = 'queued'; RequestId = $RequestId; State = 'queued' } }
Export-ModuleMember -Function Request-HostRepairAdmission, Set-HostRepairLaunchOutcome, Get-HostRepairPrivateWorkDir, Get-YurunaHostOperationLockPath,
    Request-StartCycleReservation, Set-StartCycleLaunch, Get-HostUpdateControllerLockState, Get-HostUpdateCapability, Request-HostUpdateAdmission
'@

$script:StubInnerSpawn = @'
function Get-PwshExePath { [CmdletBinding()] param() return [Environment]::ProcessPath }
function Start-YurunaDetachedProcess { [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath, [string]$WorkingDirectory, [string]$StdOutPath, [string]$StdErrPath, [string]$PrivateDirectory, [string[]]$ArgumentList,
        [hashtable]$Environment, [string]$StdInPath, [string]$HandshakePath, [int]$WaitForHandshakeMilliseconds, $Deadline)
    $null = $PrivateDirectory, $HandshakePath, $WaitForHandshakeMilliseconds, $Deadline
    Add-Content -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'calls.log') -Value ("launch:$FilePath " + (@($ArgumentList) -join ' '))
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $FilePath) + @($ArgumentList)
    $options = @{ FilePath = [Environment]::ProcessPath; ArgumentList = $arguments; WorkingDirectory = $WorkingDirectory
        RedirectStandardOutput = $StdOutPath; RedirectStandardError = $StdErrPath; RedirectStandardInput = $StdInPath; PassThru = $true }
    if ($IsWindows) { $options.WindowStyle = 'Hidden' }
    $process = Start-Process @options
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
        Config = (Join-Path $root 'operator.config.yml')
    }
    $modules = Join-Path $tree.Repo 'test/modules'
    $null = New-Item -ItemType Directory -Path $modules, (Join-Path $tree.Repo 'test/lab'), $tree.Runtime, $tree.Log, $tree.Home, $tree.Pids, $tree.Stub
    foreach ($name in @('automation', 'globalization')) {
        if ($IsWindows) { Copy-Item -LiteralPath (Join-Path $script:RepoRoot $name) -Destination (Join-Path $tree.Repo $name) -Recurse }
        else { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $tree.Repo $name) -Target (Join-Path $script:RepoRoot $name) }
    }
    if ($IsWindows) {
        # A slow first ACL-backed directory creation must precede request
        # handling. Delay only creation, leaving every existing-path check real.
        $commonPath = Join-Path $tree.Repo 'automation/Yuruna.Common.psm1'
        $common = [IO.File]::ReadAllText($commonPath)
        $creation = 'if ($Platform -eq ''windows'') { $null = [IO.Directory]::CreateDirectory($Path) }'
        if (-not $common.Contains($creation)) { throw 'The private-directory creation fixture no longer matches its source.' }
        $common = $common.Replace($creation, 'if ($Platform -eq ''windows'') { Start-Sleep -Milliseconds 700; $null = [IO.Directory]::CreateDirectory($Path) }')
        [IO.File]::WriteAllText($commonPath, $common)
    }
    $replaced = @('Test.HostRepair.psm1', 'Test.HostOperationJournal.psm1', 'Test.InnerSpawn.psm1', 'Test.HostMemoryMetrics.psm1', 'Invoke-HostDiagnosticWorker.ps1', 'Invoke-StartCycleWorker.ps1')
    foreach ($file in @(Get-ChildItem -LiteralPath $here -File)) {
        if ($replaced -contains $file.Name -or $file.Name -like '*.Tests.ps1') { continue }
        if ($IsWindows) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $modules $file.Name) }
        else { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $modules $file.Name) -Target $file.FullName }
    }
    [IO.File]::WriteAllText((Join-Path $modules 'Test.HostRepair.psm1'), $script:StubHostRepair)
    [IO.File]::WriteAllText((Join-Path $modules 'Test.HostOperationJournal.psm1'), $script:StubHostOperationJournal)
    [IO.File]::WriteAllText((Join-Path $modules 'Test.InnerSpawn.psm1'), $script:StubInnerSpawn)
    [IO.File]::WriteAllText((Join-Path $modules 'Test.HostMemoryMetrics.psm1'), @'
function Get-YurunaHostMemoryMetricPayload {
    if (Test-Path -LiteralPath (Join-Path $env:YURUNA_TEST_STUB_DIR 'memory.fail')) { throw 'memory read unavailable' }
    [pscustomobject]@{ Success = $true; Body = "# TYPE yuruna_host_memory_available_bytes gauge`nyuruna_host_memory_available_bytes 4096`nyuruna_host_memory_collection_success 1`n" }
}
Export-ModuleMember -Function Get-YurunaHostMemoryMetricPayload
'@)
    [IO.File]::WriteAllText((Join-Path $tree.Repo 'test/lab/Invoke-HostRepair.ps1'), (Get-StandInWorker -Kind 'repair' -ParamBlock @'
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
    [IO.File]::WriteAllText((Join-Path $tree.Repo 'test/test.config.yml'), "repositories:`n  frameworkUrl: file:///checkout-default-framework`n  projectUrl: file:///checkout-default-project`n")
    [IO.File]::WriteAllText($tree.Config, @'
repositories:
  frameworkUrl: file:///operator-framework
  projectUrl: file:///operator-project
vmStart:
  cachingProxyGitMirrorRefreshSeconds: 900
testCycle:
  stepTimeoutSeconds: 2700
secrets:
  fixture: retain-on-save
'@)
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
        [switch]$Chunked,
        [int]$TimeoutMs = 5000
    )
    $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), "http://localhost:$($script:Port)/$Path")
    if (-not $NoCsrfHeader) { $null = $message.Headers.TryAddWithoutValidation('X-Yuruna', '1') }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $message.Content = [System.Net.Http.StringContent]::new($Body, [System.Text.UTF8Encoding]::new($false))
        $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
    }
    if ($Chunked) { $message.Headers.TransferEncodingChunked = $true }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $cts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        $timing = [Yuruna.TestFixtures.HarnessResponseTiming]::new($script:Client.SendAsync($message, $cts.Token), $watch)
        $response = $timing.Task.GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $watch.Stop()
        $json = $null
        try { $json = ConvertFrom-Json -InputObject $text } catch { $json = $null }
        $retryAfter = if ($response.Headers.RetryAfter) { [string]$response.Headers.RetryAfter } else { '' }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Text = $text; Json = $json; ElapsedMs = $timing.ElapsedMs; RetryAfter = $retryAfter; ContentType = [string]$response.Content.Headers.ContentType }
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
    if (-not $commandLine -and $IsWindows) {
        try { $commandLine = [string](Get-CimInstance -ClassName Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop).CommandLine } catch { $commandLine = '' }
    } elseif (-not $commandLine -and -not $IsLinux) {
        try { $commandLine = [string]((& /bin/ps -o command= -p $ProcessId 2>$null) -join ' ') } catch { $commandLine = '' }
    }
    if (-not ([string]$commandLine).Contains($script:Tree.Root)) { return }
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).Kill($true) } catch { $null = $_ }
}

function Start-Harness {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Starts a loopback-only server in a throwaway test tree.')]
    [CmdletBinding()]
    param([switch]$UnsafePrivateRoot)
    $script:HarnessReady = $false
    $script:HarnessSkipReason = ''
    $script:Tree = New-HarnessTree
    if ($UnsafePrivateRoot) {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Tree.Home '.yuruna')
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path (Join-Path $script:Tree.Home '.yuruna/host-repair') -Target $script:Tree.Runtime
    }
    $script:Port = Get-YurunaTestFreePort -AnyAddress
    # The runtime's own inputs, passed the way the launcher passes them.
    $serverArguments = @(
        '-Port', "$($script:Port)", '-StatusDir', (Join-Path $script:RepoRoot 'test/status'), '-RuntimeDir', $script:Tree.Runtime
        '-LogDir', $script:Tree.Log, '-RepoRoot', $script:Tree.Repo, '-ServerHostType', 'host.ubuntu.kvm'
        '-ServerConfigPath', $script:Tree.Config, '-WorkerRoot', $script:Tree.Repo
    )
    $server = [IO.File]::ReadAllText($script:RuntimePath)
    if ($IsWindows) { $server = $server.Replace('"http://*:$Port/"', '"http://localhost:$Port/"') }
    $server = $server.Replace('$script:UploadBodyTimeoutMilliseconds = 30000', '$script:UploadBodyTimeoutMilliseconds = 2000')
    $script:ServerFile = Join-Path $script:Tree.Root 'server.ps1'
    [IO.File]::WriteAllText($script:ServerFile, $server)
    $saved = Save-YurunaTestEnvironment -Name @('HOME', 'USERPROFILE', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_TEST_STUB_DIR', 'YURUNA_TEST_PID_DIR')
    try {
        $env:HOME = $script:Tree.Home
        if ($IsWindows) { $env:USERPROFILE = $script:Tree.Home }
        $env:YURUNA_RUNTIME_DIR = $script:Tree.Runtime
        $env:YURUNA_LOG_DIR = $script:Tree.Log
        $env:YURUNA_TEST_STUB_DIR = $script:Tree.Stub
        $env:YURUNA_TEST_PID_DIR = $script:Tree.Pids
        $options = @{ FilePath = $script:Pwsh; ArgumentList = @('-NoProfile', '-NonInteractive', '-File', $script:ServerFile) + $serverArguments
            RedirectStandardOutput = (Join-Path $script:Tree.Root 'server.stdout'); RedirectStandardError = (Join-Path $script:Tree.Root 'server.stderr'); PassThru = $true }
        if ($IsWindows) { $options.WindowStyle = 'Hidden' }
        $script:Server = Start-Process @options
    } finally {
        Restore-YurunaTestEnvironment -Saved $saved
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

function Stop-Harness {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops and removes only the scratch listener and its verified children.')]
    [CmdletBinding()]
    param()
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

Start-Harness
}

AfterAll {
    Stop-Harness
}

Describe 'a live listener stays responsive around bodies and workers' {

    It 'reads the selected operator configuration instead of the checkout default' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $reply = Invoke-HarnessRequest -Path 'control/test-config'
        Assert-Equal 200 $reply.Status $reply.Text
        Assert-StringEqual 'file:///operator-framework' $reply.Json.repositories.frameworkUrl
        Assert-StringEqual 'file:///operator-project' $reply.Json.repositories.projectUrl
        Assert-Equal 0 @($reply.Json.secrets.PSObject.Properties).Count 'the selected file secrets remain redacted'
        $disk = Read-TestConfig -Path $script:Tree.Config -NoCache -ThrowOnError
        Assert-StringEqual 'file:///operator-framework' $disk.repositories.frameworkUrl
        Assert-StringEqual 'retain-on-save' $disk.secrets.fixture
    }

    It 'saves only the selected configuration, retaining operator URLs and reporting the replaced value' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $defaultPath = Join-Path $script:Tree.Repo 'test/test.config.yml'
        $defaultBefore = [IO.File]::ReadAllText($defaultPath)
        $posted = [ordered]@{
            repositories = @{ frameworkUrl = 'file:///operator-framework'; projectUrl = 'file:///operator-project' }
            vmStart = @{ cachingProxyGitMirrorRefreshSeconds = 1800 }
            testCycle = @{ stepTimeoutSeconds = 2700 }
            secrets = @{}
        }
        $saved = Invoke-HarnessRequest -Method POST -Path 'control/test-config' -Body ($posted | ConvertTo-Json -Depth 8)
        Assert-Equal 200 $saved.Status $saved.Text
        $disk = Read-TestConfig -Path $script:Tree.Config -NoCache -ThrowOnError
        Assert-Equal 1800 $disk.vmStart.cachingProxyGitMirrorRefreshSeconds
        Assert-StringEqual 'file:///operator-framework' $disk.repositories.frameworkUrl
        Assert-StringEqual 'file:///operator-project' $disk.repositories.projectUrl
        Assert-StringEqual 'retain-on-save' $disk.secrets.fixture
        Assert-StringEqual $defaultBefore ([IO.File]::ReadAllText($defaultPath)) 'the checkout default is never the selected writer target'
        $backup = Read-TestConfig -Path ($script:Tree.Config + '.backup') -NoCache -ThrowOnError
        Assert-Equal 900 $backup.vmStart.cachingProxyGitMirrorRefreshSeconds
        $errors = [IO.File]::ReadAllText((Join-Path $script:Tree.Runtime 'server.err'))
        Assert-Match 'vmStart\.cachingProxyGitMirrorRefreshSeconds: 900 -> 1800 \(backup:' $errors
    }

    It 'refuses a save while another process holds the selected configuration write lock' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $before = [IO.File]::ReadAllText($script:Tree.Config)
        $lock = Enter-YurunaSingleFlightLock -Path ($script:Tree.Config + '.lock') -WaitMilliseconds 0
        Assert-True $lock.Held 'the test process owns the selected configuration lock'
        $previousClient = $script:Client
        $script:Client = [System.Net.Http.HttpClient]::new()
        $script:Client.Timeout = [TimeSpan]::FromSeconds(45)
        try {
            $body = '{"repositories":{"frameworkUrl":"file:///operator-framework","projectUrl":"file:///operator-project"}}'
            $reply = Invoke-HarnessRequest -Method POST -Path 'control/test-config' -Body $body -TimeoutMs 45000
            Assert-Equal 503 $reply.Status $reply.Text
            Assert-StringEqual $before ([IO.File]::ReadAllText($script:Tree.Config)) 'a refused concurrent save preserves the operator file'
        } finally {
            Exit-YurunaSingleFlightLock -Lock $lock
            $script:Client.Dispose()
            $script:Client = $previousClient
        }
    }

    It 'serves native memory readings as Prometheus metrics without a control header' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $reply = Invoke-HarnessRequest -Path 'metrics' -NoCsrfHeader
        Assert-Equal 200 $reply.Status $reply.Text
        Assert-Match '^text/plain; version=0.0.4' $reply.ContentType
        Assert-Match '(?m)^yuruna_host_memory_available_bytes 4096$' $reply.Text
        Assert-Match '(?m)^yuruna_host_memory_collection_success 1$' $reply.Text
    }

    It 'fails a memory scrape without publishing zero readings or stopping the listener' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $failure = Join-Path $script:Tree.Stub 'memory.fail'
        [IO.File]::WriteAllText($failure, '')
        try {
            $reply = Invoke-HarnessRequest -Path 'metrics' -NoCsrfHeader
            Assert-Equal 503 $reply.Status $reply.Text
            Assert-Match '(?m)^yuruna_host_memory_collection_success 0$' $reply.Text
            Assert-False ($reply.Text -match 'yuruna_host_memory_available_bytes') 'an unreadable memory source is not zero available bytes'
            Assert-Equal 200 (Invoke-HarnessRequest -Path 'runtime/status.json').Status
        } finally { Remove-Item -LiteralPath $failure -Force }
    }

    It 'serves an empty file as an empty 200 instead of resetting the connection' {
        # A stage's .err.log is empty when the stage wrote nothing to stderr.
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $folder = Join-Path $script:Tree.Log 'empty-guest'
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllBytes((Join-Path $folder 'stage.err.log'), [byte[]]@())
        $reply = Invoke-HarnessRequest -Path 'log/empty-guest/stage.err.log'
        Assert-Equal 200 $reply.Status $reply.Text
        Assert-StringEqual '' $reply.Text
        Assert-Equal 200 (Invoke-HarnessRequest -Method HEAD -Path 'log/empty-guest/stage.err.log').Status
        Assert-Equal 200 (Invoke-HarnessRequest -Path 'runtime/status.json').Status
        # Off Windows an aborted response can still reach the client as an empty
        # 200; the handler error the server logs before aborting is the tell.
        $serverErr = Join-Path $script:Tree.Runtime 'server.err'
        $logged = if (Test-Path -LiteralPath $serverErr) { [IO.File]::ReadAllText($serverErr) } else { '' }
        Assert-False ($logged -match 'handler error: path=\S*empty-guest/stage\.err\.log') "the empty file must be answered, not aborted: $logged"
    }

    It 'keeps the metrics endpoint read-only and honors HEAD' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $head = Invoke-HarnessRequest -Method HEAD -Path 'metrics' -NoCsrfHeader
        Assert-Equal 200 $head.Status
        Assert-StringEqual '' $head.Text
        Assert-Equal 405 (Invoke-HarnessRequest -Method POST -Path 'metrics' -NoCsrfHeader).Status
    }

    It 'keeps answering health checks while a diagnostic upload withholds its body' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $folder = Join-Path $script:Tree.Log 'upload-guest'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $raw = Open-RawRequest -Head "POST /diagnostics/upload-guest/probe.system.diagnostic.1.txt HTTP/1.1`r`nHost: localhost`r`nContent-Length: 100`r`n`r`n"
        try {
            Start-Sleep -Milliseconds 200
            $health = Invoke-HarnessRequest -Path 'status/' -TimeoutMs 1000
            Assert-Equal 200 $health.Status
            Assert-True ($health.ElapsedMs -le 1000) 'health must answer before the upload body arrives'
        } finally { $raw.Client.Dispose() }
    }

    It 'stores a complete <Kind> upload with its existing response contract' -ForEach @(
        @{ Kind = 'diagnostic'; Path = 'diagnostics/upload-guest/complete.system.diagnostic.1.txt'; File = 'upload-guest/complete.system.diagnostic.1.txt'; Status = 200 },
        @{ Kind = 'execution log'; Path = 'log-upload/upload-guest/execution.log'; File = 'upload-guest/execution.log'; Status = 201 }
    ) {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Tree.Log 'upload-guest') -Force
        $text = "first line`ncomplete evidence: caf$([char]0x00E9)"
        $reply = Invoke-HarnessRequest -Method POST -Path $Path -Body $text -ContentType 'text/plain'
        Assert-Equal $Status $reply.Status $reply.Text
        Assert-True $reply.Json.ok
        Assert-StringEqual $text ([IO.File]::ReadAllText((Join-Path $script:Tree.Log $File)))
        if ($Kind -eq 'diagnostic') { Assert-Equal ([Text.Encoding]::UTF8.GetByteCount($text)) $reply.Json.bytes }
        Assert-Equal 0 @(Get-ChildItem -LiteralPath (Join-Path $script:Tree.Log 'upload-guest') -Filter '*.tmp').Count 'uploads leave no partial temporary files'
    }

    It 'times out a trickled <Kind> upload without replacing existing evidence' -ForEach @(
        @{ Kind = 'diagnostic'; Path = 'diagnostics/upload-guest/timeout.system.diagnostic.1.txt'; File = 'upload-guest/timeout.system.diagnostic.1.txt' },
        @{ Kind = 'execution log'; Path = 'log-upload/upload-guest/timeout.log'; File = 'upload-guest/timeout.log' }
    ) {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Tree.Log 'upload-guest') -Force
        $target = Join-Path $script:Tree.Log $File
        [IO.File]::WriteAllText($target, 'previous complete evidence')
        $raw = Open-RawRequest -Head "POST /$Path HTTP/1.1`r`nHost: localhost`r`nContent-Length: 100`r`n`r`na"
        $health = Invoke-HarnessRequest -Path 'runtime/status.json' -TimeoutMs 1000
        Assert-Equal 200 $health.Status 'runtime health remains responsive during the upload'
        $reply = Wait-RawResponse -Raw $raw -TimeoutMs 6000 -TrickleEveryMs 300 -TrickleText 'x'
        Assert-True ($reply.AnsweredMs -ge 1900 -and $reply.AnsweredMs -le 3500) "the trickled upload answered after $($reply.AnsweredMs) ms"
        Assert-Equal 408 $reply.Status $reply.Text
        Assert-Match 'body_timeout' $reply.Text
        Assert-StringEqual 'previous complete evidence' ([IO.File]::ReadAllText($target))
    }

    It 'rejects declared and chunked oversized <Kind> uploads before publishing a file' -ForEach @(
        @{ Kind = 'diagnostic'; Path = 'diagnostics/upload-guest/large.system.diagnostic.1.txt'; File = 'upload-guest/large.system.diagnostic.1.txt'; Limit = 5MB },
        @{ Kind = 'execution log'; Path = 'log-upload/upload-guest/large.log'; File = 'upload-guest/large.log'; Limit = 4MB }
    ) {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Tree.Log 'upload-guest') -Force
        $raw = Open-RawRequest -Head "POST /$Path HTTP/1.1`r`nHost: localhost`r`nContent-Length: $($Limit + 1)`r`n`r`n"
        $declared = Wait-RawResponse -Raw $raw -TimeoutMs 3000
        Assert-Equal 413 $declared.Status $declared.Text
        $chunked = Invoke-HarnessRequest -Method POST -Path $Path -Body ('x' * ($Limit + 1)) -Chunked -ContentType 'text/plain' -TimeoutMs 10000
        Assert-Equal 413 $chunked.Status $chunked.Text
        Join-Path $script:Tree.Log $File | Should -Not -Exist
        Assert-Equal 200 (Invoke-HarnessRequest -Path 'status/' -TimeoutMs 1000).Status
    }

    It 'bounds shared pending upload capacity and rejects invalid paths before reading a body' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $held = @()
        try {
            foreach ($index in 1..4) {
                $held += Open-RawRequest -Head "PUT /log-upload/upload-guest/held-$index.log HTTP/1.1`r`nHost: localhost`r`nContent-Length: 100`r`n`r`n"
            }
            Start-Sleep -Milliseconds 200
            $busy = Invoke-HarnessRequest -Method PUT -Path 'log-upload/upload-guest/fifth.log' -Body 'complete'
            Assert-Equal 503 $busy.Status $busy.Text
            Assert-StringEqual 'listener_busy' $busy.Json.reason
            Assert-Equal 200 (Invoke-HarnessRequest -Path 'status/' -TimeoutMs 1000).Status
        } finally { foreach ($raw in $held) { $raw.Client.Dispose() } }
        $invalid = Invoke-HarnessRequest -Method POST -Path 'log-upload/upload-guest/disallowed.exe' -Body 'evidence'
        Assert-Equal 400 $invalid.Status
        $missing = Invoke-HarnessRequest -Method POST -Path 'diagnostics/never-created/report.system.diagnostic.1.txt' -Body 'evidence'
        Assert-Equal 404 $missing.Status
    }

    It 'records HTTP completion time even when the observer is delayed (completed before tracking: <CompleteBeforeTracking>)' -TestCases @(
        @{ CompleteBeforeTracking = $true }, @{ CompleteBeforeTracking = $false }
    ) {
        param($CompleteBeforeTracking)
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
        try {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $source = [Threading.Tasks.TaskCompletionSource[Net.Http.HttpResponseMessage]]::new()
            if ($CompleteBeforeTracking) { $source.SetResult($response) }
            $timing = [Yuruna.TestFixtures.HarnessResponseTiming]::new($source.Task, $clock)
            if (-not $CompleteBeforeTracking) {
                $timing.Task.IsCompleted | Should -BeFalse
                $source.SetResult($response)
            }
            $completedBeforeDelay = $clock.ElapsedMilliseconds
            Start-Sleep -Milliseconds 50
            $timing.Task.IsCompletedSuccessfully | Should -BeTrue
            [object]::ReferenceEquals($timing.Task.Result, $response) | Should -BeTrue
            $timing.ElapsedMs | Should -BeLessOrEqual $completedBeforeDelay
        } finally { $response.Dispose() }
    }

    It 'answers concurrent repair, start-cycle and diagnostic requests quickly while the read-only routes keep answering' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $tasks = @{}
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($spec in @(
                @{ Name = 'repair'; Method = 'POST'; Path = 'control/host-repair'; Body = '{}' },
                @{ Name = 'start-cycle'; Method = 'POST'; Path = 'control/start-cycle' },
                @{ Name = 'diagnostic'; Method = 'GET'; Path = 'control/host-diagnostic' })) {
            $message = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($spec.Method), "http://localhost:$($script:Port)/$($spec.Path)")
            $null = $message.Headers.TryAddWithoutValidation('X-Yuruna', '1')
            if ($spec.Body) {
                $message.Content = [System.Net.Http.StringContent]::new($spec.Body, [System.Text.UTF8Encoding]::new($false))
                $message.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
            }
            $tasks[$spec.Name] = [Yuruna.TestFixtures.HarnessResponseTiming]::new($script:Client.SendAsync($message), $watch)
        }
        $elapsed = @{}
        while ($elapsed.Count -lt $tasks.Count -and $watch.ElapsedMilliseconds -lt 10000) {
            foreach ($name in @($tasks.Keys)) {
                if (-not $elapsed.ContainsKey($name) -and $tasks[$name].Task.IsCompleted) { $elapsed[$name] = $tasks[$name].ElapsedMs }
            }
            Start-Sleep -Milliseconds 10
        }
        $findings = @()
        foreach ($name in @($tasks.Keys)) {
            if (-not $elapsed.ContainsKey($name)) { $findings += "$name never answered"; continue }
            $status = [int]$tasks[$name].Task.Result.StatusCode
            if ($status -notin @(200, 202, 409)) { $findings += "$name answered $status" }
            if ($elapsed[$name] -gt 1500) { $findings += "$name completed after $($elapsed[$name]) ms (observer finished at $($watch.ElapsedMilliseconds) ms)" }
        }
        Assert-NoFinding $findings 'a concurrent control request was slow or undocumented'
        # Repair and start-cycle exclude each other: whichever the loop admits
        # first is launched and the other is told busy, never both.
        $admitted = @(@('repair', 'start-cycle') | Where-Object { [int]$tasks[$_].Task.Result.StatusCode -eq 202 })
        Assert-Equal 1 $admitted.Count 'exactly one of repair and start-cycle is admitted'
        Assert-Equal 202 ([int]$tasks['diagnostic'].Task.Result.StatusCode) 'the diagnostic answers pending while its worker runs'
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

    It 'keeps reads available and refuses unsafe worker state after startup preparation fails' {
        $saved = @{}
        foreach ($name in 'Tree', 'Port', 'ServerFile', 'Server', 'Client', 'HarnessReady', 'HarnessSkipReason') {
            $saved[$name] = Get-Variable -Name $name -Scope Script -ValueOnly
        }
        $script:Tree = $null
        $script:ServerFile = $null
        $script:Server = $null
        $script:Client = $null
        try {
            Start-Harness -UnsafePrivateRoot
            Assert-True $script:HarnessReady $script:HarnessSkipReason
            $errors = [IO.File]::ReadAllText((Join-Path $script:Tree.Runtime 'server.err'))
            Assert-Match 'private worker directory work preparation failed: reparse-point' $errors
            foreach ($path in 'status/', 'runtime/status.json') {
                $reply = Invoke-HarnessRequest -Path $path -TimeoutMs 3000
                Assert-Equal 200 $reply.Status $reply.Text
            }
            $reply = Invoke-HarnessRequest -Method POST -Path 'control/start-cycle' -TimeoutMs 3000
            Assert-Equal 503 $reply.Status $reply.Text
            Assert-StringEqual 'private_state_unavailable' $reply.Json.reason
            Assert-Equal 0 ((Get-StandInPid -Kind 'start-cycle').Count) 'unsafe state launches no worker'
            Assert-Equal 0 ((Get-HarnessCall -Prefix 'launch:').Count) 'startup preparation never launches work'
            Assert-Equal 200 (Invoke-HarnessRequest -Path 'status/' -TimeoutMs 3000).Status
        } finally {
            Stop-Harness
            foreach ($name in $saved.Keys) { Set-Variable -Name $name -Scope Script -Value $saved[$name] }
        }
    }

    It 'answers 408 for a withheld body within its deadline, admits nothing and keeps serving meanwhile' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $admissionsBefore = (Get-HarnessCall -Prefix 'admit:').Count
        $repairBefore = (Get-StandInPid -Kind 'repair').Count
        $raw = Open-RawRequest -Head "POST /control/host-repair HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n"
        Start-Sleep -Milliseconds 200
        $status = Invoke-HarnessRequest -Path 'status/' -TimeoutMs 3000
        Assert-Equal 200 $status.Status
        Assert-True ($status.ElapsedMs -le 1000) "/status/ took $($status.ElapsedMs) ms while a body was withheld"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the withheld body was answered after $($answer.AnsweredMs) ms"
        Assert-True ($answer.Status -in @(0, 408)) "a withheld body got $($answer.Status)"
        if ($answer.Status -eq 408) { Assert-Match 'body_timeout' $answer.Text }
        Assert-Equal $admissionsBefore (Get-HarnessCall -Prefix 'admit:').Count 'no admission for a body that never arrived'
        Assert-Equal $repairBefore (Get-StandInPid -Kind 'repair').Count 'no worker for a body that never arrived'
    }

    It 'cuts a trickled body at two seconds despite progress' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $raw = Open-RawRequest -Head "POST /control/host-repair HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 50`r`n`r`n{"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000 -TrickleEveryMs 300 -TrickleText ' '
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the trickled body was answered after $($answer.AnsweredMs) ms"
        Assert-True ($answer.Status -in @(0, 408)) "a trickled body got $($answer.Status)"
    }

    It 'cuts a chunked trickle the same way, and refuses a chunked body past the cap' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $raw = Open-RawRequest -Head "POST /control/host-repair HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`n`r`n"
        $answer = Wait-RawResponse -Raw $raw -TimeoutMs 6000 -TrickleEveryMs 300 -TrickleText "1`r`n `r`n"
        Assert-True ($answer.AnsweredMs -ge 1900 -and $answer.AnsweredMs -le 3500) "the chunked trickle was answered after $($answer.AnsweredMs) ms"
        $big = ' ' * 5000
        $oversize = Open-RawRequest -Head ("POST /control/host-repair HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nTransfer-Encoding: chunked`r`n`r`n" +
            ('{0:x}' -f $big.Length) + "`r`n" + $big + "`r`n0`r`n`r`n")
        $refused = Wait-RawResponse -Raw $oversize -TimeoutMs 4000
        Assert-Equal 413 $refused.Status 'a chunked body past 4096 bytes is refused with no declared length to go on'
        Assert-Match 'payload_too_large' $refused.Text
        $declared = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"x":"' + ('y' * 5000) + '"}')
        Assert-Equal 413 $declared.Status 'a declared length past the cap is refused before reading'
    }

    It 'turns a fifth pending body away at once and keeps serving' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $held = @()
        try {
            foreach ($i in 1..4) {
                $held += Open-RawRequest -Head "POST /control/host-repair HTTP/1.1`r`nHost: localhost`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 100`r`n`r`n"
            }
            Start-Sleep -Milliseconds 300
            $fifth = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body '{}'
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
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $get = Invoke-HarnessRequest -Path 'control/host-repair'
        Assert-Equal 405 $get.Status 'a GET that carries the header reaches the method check'
        $noHeader = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body '{}' -NoCsrfHeader
        Assert-Equal 403 $noHeader.Status 'a POST without the header is refused before the route'
        $preflight = Invoke-HarnessRequest -Method OPTIONS -Path 'control/host-repair' -NoCsrfHeader
        Assert-Equal 204 $preflight.Status
        $media = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body '{}' -ContentType 'text/plain'
        Assert-Equal 415 $media.Status
    }

    It 'refuses forbidden keys with 400 and admits nothing' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $before = (Get-HarnessCall -Prefix 'admit:').Count
        foreach ($body in @('{"force":true}', '{"AllowHardStop":true}', '{"configPath":"/etc/x"}', '{"tier":"full"}')) {
            $reply = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body $body
            Assert-Equal 400 $reply.Status $body
            Assert-True ($reply.Json.reason -in @('forbidden_field', 'invalid_value')) "$body got $($reply.Json.reason)"
        }
        Assert-Equal $before (Get-HarnessCall -Prefix 'admit:').Count 'a refused body never reaches admission'
    }

    It 'replays a known request by its id and refuses a different one while it is active' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $id = [Guid]::NewGuid().ToString('D')
        $first = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"requestId":"' + $id + '","maxRung":"start-if-stopped"}')
        Assert-Equal 202 $first.Status $first.Text
        Assert-StringEqual 'spawned' $first.Json.action
        $again = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"requestId":"' + $id + '","maxRung":"start-if-stopped"}')
        Assert-Equal 202 $again.Status
        Assert-StringEqual 'already_claimed' $again.Json.action
        $other = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"requestId":"' + [Guid]::NewGuid().ToString('D') + '"}')
        Assert-Equal 409 $other.Status
        Assert-StringEqual 'busy' $other.Json.reason
        Assert-StringEqual 'host_repair' $other.Json.activeKind
        Assert-StringEqual $id $other.Json.activeRequestId
        $changed = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"requestId":"' + $id + '","maxRung":"reclaim"}')
        Assert-Equal 409 $changed.Status
        Assert-StringEqual 'request_conflict' $changed.Json.reason
        $completedId = [Guid]::NewGuid().ToString('D')
        Reset-HarnessJournal -Journal @{ requests = @(@{ requestId = $completedId; maxRung = 'start-if-stopped'; state = 'completed'; launch = 'started'; verdict = 'partial' }); reservation = $null }
        $replay = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body ('{"requestId":"' + $completedId + '","maxRung":"start-if-stopped"}')
        Assert-Equal 200 $replay.Status
        Assert-True $replay.Json.ok
        Assert-StringEqual 'partial' $replay.Json.verdict 'a completed replay reports its stored verdict, which is what the caller must read'
    }

    It 'makes start-cycle and repair exclude each other in both orders' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal @{ requests = @(@{ requestId = 'active-repair'; maxRung = 'reclaim'; state = 'running'; launch = 'started'; verdict = '' }); reservation = $null }
        $blocked = Invoke-HarnessRequest -Method POST -Path 'control/start-cycle'
        Assert-Equal 409 $blocked.Status
        Assert-StringEqual 'host_repair' $blocked.Json.activeKind
        Assert-StringEqual '/runtime/host-repair.state.json' $blocked.Json.stateUrl
        Reset-HarnessJournal -Journal $null
        $queued = Invoke-HarnessRequest -Method POST -Path 'control/start-cycle'
        Assert-Equal 202 $queued.Status $queued.Text
        Assert-StringEqual 'queued' $queued.Json.action
        $recorded = @(Get-HarnessCall -Prefix "reservation-launch:$($queued.Json.operationId)|")
        Assert-Equal 1 $recorded.Count 'the launch of a reserved start-cycle is recorded once, first time'
        Assert-Match '\|started$' $recorded[0]
        $repair = Invoke-HarnessRequest -Method POST -Path 'control/host-repair' -Body '{}'
        Assert-Equal 409 $repair.Status
        Assert-StringEqual 'start_cycle' $repair.Json.activeKind
        Assert-StringEqual $queued.Json.operationId $repair.Json.activeRequestId
        Assert-StringEqual '/runtime/start-cycle.state.json' $repair.Json.stateUrl
    }

    It 'advertises the repair capability in a small control-status reply' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        Reset-HarnessJournal -Journal $null
        $status = Invoke-HarnessRequest -Path 'control/control-status'
        Assert-Equal 200 $status.Status
        Assert-True ([System.Text.Encoding]::UTF8.GetByteCount($status.Text) -lt 1024) "control-status is $([System.Text.Encoding]::UTF8.GetByteCount($status.Text)) bytes"
        Assert-Equal 1 $status.Json.repair.protocol
        Assert-StringEqual 'available' $status.Json.repair.availability
        Assert-StringEqual 'start-if-stopped' $status.Json.repair.ceiling
        Assert-StringEqual 'idle' $status.Json.repair.state
        Assert-StringEqual 'protocol,availability,scopes,reason,remote,state,caller' (@($status.Json.update.PSObject.Properties.Name) -join ',')
        Assert-StringEqual 'loopback' $status.Json.update.caller 'a request to localhost at the listener port is this host itself'
        Assert-StringEqual 'missing' $status.Json.update.remote
    }

    It 'guards POST /control/host-update and queues only this host''s own request while a controller runs' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $held = Join-Path $script:Tree.Stub 'controller.held'
        Remove-Item -LiteralPath $held -Force -ErrorAction SilentlyContinue
        $before = (Get-HarnessCall -Prefix 'admit-update:').Count
        Assert-Equal 405 (Invoke-HarnessRequest -Path 'control/host-update').Status 'a GET that carries the header reaches the method check'
        Assert-Equal 403 (Invoke-HarnessRequest -Method POST -Path 'control/host-update' -Body '{}' -NoCsrfHeader).Status 'a POST without the header is refused before the route'
        Assert-Equal 204 (Invoke-HarnessRequest -Method OPTIONS -Path 'control/host-update' -NoCsrfHeader).Status
        Assert-Equal 415 (Invoke-HarnessRequest -Method POST -Path 'control/host-update' -Body '{}' -ContentType 'text/plain').Status
        $drain = Invoke-HarnessRequest -Method POST -Path 'control/host-update' -Body '{"drain":"now"}'
        Assert-Equal 400 $drain.Status
        Assert-StringEqual 'forbidden_field' $drain.Json.reason
        Assert-StringEqual 'drain' $drain.Json.field
        $absent = Invoke-HarnessRequest -Method POST -Path 'control/host-update' -Body '{}'
        Assert-Equal 503 $absent.Status $absent.Text
        Assert-StringEqual 'controller_absent' $absent.Json.reason
        Assert-Equal $before (Get-HarnessCall -Prefix 'admit-update:').Count 'nothing is queued while no controller runs'
        [IO.File]::WriteAllText($held, '')
        try {
            $queued = Invoke-HarnessRequest -Method POST -Path 'control/host-update' -Body '{}'
            Assert-Equal 202 $queued.Status $queued.Text
            Assert-StringEqual 'queued' $queued.Json.action
            Assert-StringEqual '/runtime/host-update.state.json' $queued.Json.stateUrl
            $admitted = @(Get-HarnessCall -Prefix "admit-update:$($queued.Json.requestId)|")
            Assert-Equal 1 $admitted.Count
            Assert-Match '\|listener\|restart\|after-cycle\|7200\|\|1000$' $admitted[0]
            $raw = Open-RawRequest -Head ("POST /control/host-update HTTP/1.1`r`nHost: evil.example:$($script:Port)`r`nX-Yuruna: 1`r`nContent-Type: application/json`r`nContent-Length: 2`r`n`r`n{}")
            $foreign = Wait-RawResponse -Raw $raw -TimeoutMs 6000
            Assert-Equal 403 $foreign.Status 'a loopback address under a foreign Host name is not this host itself'
            Assert-Match 'update_proof_missing' $foreign.Text
            Assert-Equal ($before + 1) (Get-HarnessCall -Prefix 'admit-update:').Count 'only the loopback request reached admission'
        } finally {
            Remove-Item -LiteralPath $held -Force -ErrorAction SilentlyContinue
        }
    }

    It 'admits a host update from another machine only with a proof signed by the key in the pool-control record' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $held = Join-Path $script:Tree.Stub 'controller.held'
        $privateRoot = [IO.Path]::Combine($script:Tree.Home, '.yuruna', 'host-repair')
        $recordPath = [IO.Path]::Combine($privateRoot, 'pool-control.record')
        $vectorDir = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'hostupdate', 'testdata')
        $vectors = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::Combine($vectorDir, 'vectors.json')))
        $uuidPath = Join-Path $script:Tree.Runtime 'host.uuid'
        $hadUuid = [IO.File]::Exists($uuidPath)
        if (-not $hadUuid) { [IO.File]::WriteAllText($uuidPath, '42cccccccccccccccccccccccccccccc') }
        $hostId = [string](Invoke-HarnessRequest -Path 'control/control-status').Json.hostId
        Assert-Match '\A[0-9a-f]{32}\z' $hostId
        $sign = {
            param([string]$KeyFile, [string]$RequestId, [string]$Scope)
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $fields = @($hostId, $RequestId, $Scope, '7200', '', "$now", "$($now + 120)")
            $rsa = [Security.Cryptography.RSA]::Create()
            try {
                $rsa.ImportFromPem([IO.File]::ReadAllText([IO.Path]::Combine($vectorDir, $KeyFile)))
                $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes('yuruna-host-update|v2|' + ($fields -join '|')),
                    [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
            } finally { $rsa.Dispose() }
            (@('yup1') + $fields + @([Convert]::ToBase64String($sig).TrimEnd('=').Replace('+', '-').Replace('/', '_'))) -join '.'
        }
        # A foreign Host name makes the request another machine's to the
        # route, while the loopback address still passes the transport guard.
        $send = {
            param([string]$Proof, [string]$Body)
            $head = "POST /control/host-update HTTP/1.1`r`nHost: pool-host.example:$($script:Port)`r`nX-Yuruna: 1`r`nX-Yuruna-Update-Proof: $Proof`r`n" +
                "Content-Type: application/json`r`nConnection: close`r`nContent-Length: $([Text.Encoding]::UTF8.GetByteCount($Body))`r`n`r`n$Body"
            Wait-RawResponse -Raw (Open-RawRequest -Head $head) -TimeoutMs 6000
        }
        $id = [Guid]::NewGuid().ToString('D')
        $before = (Get-HarnessCall -Prefix 'admit-update:').Count
        [IO.File]::WriteAllText($held, '')
        try {
            $unprovisioned = & $send (& $sign 'test-key.pem' $id 'restart') ('{"requestId":"' + $id + '"}')
            Assert-Equal 403 $unprovisioned.Status $unprovisioned.Text
            Assert-Match 'update_remote_unprovisioned' $unprovisioned.Text
            if (-not [IO.Directory]::Exists($privateRoot)) { $null = [IO.Directory]::CreateDirectory($privateRoot, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
            [IO.File]::WriteAllText($recordPath, ([ordered]@{ schema = 'yuruna.pool-control-record/v1'; poolControl = 'http://192.0.2.10'; updateKey = $vectors.publicKey } | ConvertTo-Json -Compress))
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode($recordPath, [IO.UnixFileMode]'UserRead, UserWrite') }

            $noId = & $send (& $sign 'test-key.pem' $id 'restart') '{}'
            Assert-Equal 400 $noId.Status 'a remote request must name the id its proof binds'
            Assert-Match '"field":"requestId"' $noId.Text
            $policy = & $send (& $sign 'test-key.pem' $id 'restart') ('{"requestId":"' + $id + '","scope":"full"}')
            Assert-Equal 403 $policy.Status
            Assert-Match 'update_proof_policy_mismatch' $policy.Text
            $forged = & $send (& $sign 'other-key.pem' $id 'restart') ('{"requestId":"' + $id + '"}')
            Assert-Equal 403 $forged.Status
            Assert-Match 'update_proof_invalid' $forged.Text
            Assert-Equal $before (Get-HarnessCall -Prefix 'admit-update:').Count 'no refused request reached admission'

            $queued = & $send (& $sign 'test-key.pem' $id 'restart') ('{"requestId":"' + $id + '"}')
            Assert-Equal 202 $queued.Status $queued.Text
            Assert-Match '"action":"queued"' $queued.Text
            $admitted = @(Get-HarnessCall -Prefix "admit-update:$id|")
            Assert-Equal 1 $admitted.Count
            Assert-Match '\|remote\|restart\|after-cycle\|7200\|\|1000$' $admitted[0]
        } finally {
            Remove-Item -LiteralPath $held, $recordPath -Force -ErrorAction SilentlyContinue
            if (-not $hadUuid) { Remove-Item -LiteralPath $uuidPath -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'answers pending on repeated diagnostic requests without launching a second worker' {
        Assert-True $script:HarnessReady $script:HarnessSkipReason
        $before = (Get-StandInPid -Kind 'diagnostic').Count
        # An earlier case's run can still be inside its spawn grace, and a grace
        # that ends between two requests starts the next run by design. Ask
        # until this case's own run has started, so the burst below falls
        # wholly inside one grace however slowly the host answers.
        $launchDeadline = [DateTime]::UtcNow.AddSeconds(45)
        while ([DateTime]::UtcNow -lt $launchDeadline -and (Get-StandInPid -Kind 'diagnostic').Count -le $before) {
            $null = Invoke-HarnessRequest -Path 'control/host-diagnostic'
            Start-Sleep -Milliseconds 500
        }
        Assert-True ((Get-StandInPid -Kind 'diagnostic').Count -gt $before) 'the diagnostic stand-in worker of this case is running'
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
