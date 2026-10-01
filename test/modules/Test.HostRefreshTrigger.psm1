<#PSScriptInfo
.VERSION 2026.09.30
.GUID 424f9ac4-a8c5-484f-9b6f-760e69d94781
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh automatic trigger policy
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

# The automatic host-refresh policy: when the resident runner may start a
# hypervisor repair on its own, and how it proves the repair ran.
#
# Three processes are involved and only files cross between them. The inner
# runner observes the hypervisor (the service-VM restore sweep) and writes one
# evidence file per cycle, stamped with the generation the resident outer
# minted for that cycle; the per-cycle process only relays its exit; the
# resident outer consumes the file right after the dispatch, keeps the
# timeout count in a private file and decides. A sidecar from any other
# cycle is rejected by its generation, so a stale observation can never
# count twice or count for the wrong cycle.
#
# The count and the daily budget live in separate private files on purpose:
# a responsive observation clears the count, but nothing but the passage of
# a UTC day frees the budget, and a clock set back never does. The budget
# ledger is a checksummed critical record written under the admission lock
# before any request exists, so a crash after the reservation still counts
# the day as used -- the fail-safe direction for an unattended restart.
#
# Every platform is declared unqualified until a native canary proves the
# repair on it; the runner still reads the knob, counts the evidence and says
# once why it does not act. The module joins no entry-point module set: the
# resident outer and the inner import it guarded at their call sites, and
# everything heavy (the repair journal, the lock, the critical record, the
# private-root helpers, the refresh-gate reader the journal's admission
# consults) resolves lazily by name, so a missing piece yields a
# structured 'dependency-missing:<module>' refusal instead of an exception in
# a loop that must keep running.

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -DisableNameChecking

# --- REGION: Declarations
# Enabling automatic repair on a platform is one entry here plus the canary
# evidence the release runbook lists; nothing else in the module changes.
$script:HostRefreshAutoProtocolVersion = 1
$script:HostRefreshAutoPhaseAllowlist = @('service-vm-restore')
$script:HostRefreshAutoQualification = @{
    'host.macos.utm'       = @{ Qualified = $false; Reason = 'awaiting-native-qualification' }
    'host.ubuntu.kvm'      = @{ Qualified = $false; Reason = 'platform-unqualified' }
    'host.windows.hyper-v' = @{ Qualified = $false; Reason = 'platform-unqualified' }
}
# One timeout is not proof of a wedge: an automatic restart needs the timeout
# in two completed cycles at least.
$script:HostRefreshAutoMinimumThreshold = 2
# The worker bounds itself to 915 s; the parent waits a minute longer before
# stopping its own child, so a worker finishing its reporting phase is never
# cut off by the wait that launched it.
$script:HostRefreshAutoLaunchTimeoutSeconds = 975
$script:HostRefreshAutoResumeMaxAttempts = 3
$script:HostRefreshAutoResumeSpacingSeconds = 300
$script:HostRefreshAutoClockSkewSeconds = 300
$script:HostRefreshAutoLedgerRetentionDays = 400
# Two readers of one process's start time (the process table, .NET's
# Process.StartTime) round differently; a recycled pid starts far outside this.
$script:HostRefreshAutoIdentityToleranceMs = 2000
$script:HostRefreshAutoEvidenceFileName = 'runner.refresh-evidence.json'
$script:HostRefreshAutoStreakFileName = 'host-refresh.auto-streak.json'
$script:HostRefreshAutoBudgetFileName = 'host-refresh.auto-budget.record'
$script:HostRefreshAutoBudgetKind = 'host-refresh-auto-budget'
$script:HostRefreshAutoEvidenceKind = 'host-refresh-evidence'
$script:HostRefreshAutoStreakKind = 'host-refresh-auto-streak'
$script:HostRefreshAutoGenerationPattern = '^[0-9a-f]{32}:[1-9][0-9]{0,8}$'
$script:HostRefreshAutoRequestIdPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
$script:HostRefreshAutoTokenPattern = '^[a-z0-9][a-z0-9._:-]{0,191}$'
# The evidence and streak files are a few hundred bytes; anything far larger
# is not one of them and is refused rather than parsed.
$script:HostRefreshAutoMaxFileBytes = 65536
# Where each lazily resolved command comes from. A command that is already
# visible (loaded by the caller, or a test stub) is used as is.
$script:HostRefreshAutoDependency = @{
    'Get-VirtualizationRepairRung'           = 'Test.HostRefresh'
    'New-HostRefreshBudget'                  = 'Test.HostRefresh'
    'New-HostRefreshWorkerArgumentList'      = 'Test.HostRefresh'
    'Get-YurunaHostRefreshAdmissionLockPath' = 'Test.HostRefreshIntent'
    'New-YurunaHostRefreshRequestId'         = 'Test.HostRefreshIntent'
    'Get-HostRefreshAdmissionDecision'       = 'Test.HostRefreshIntent'
    'Request-HostRefreshAdmission'           = 'Test.HostRefreshIntent'
    'Set-HostRefreshLaunchOutcome'           = 'Test.HostRefreshIntent'
    'Stop-HostRefreshQueuedRequest'          = 'Test.HostRefreshIntent'
    'Get-HostRefreshActiveRequest'           = 'Test.HostRefreshIntent'
    'Get-HostRefreshResult'                  = 'Test.HostRefreshIntent'
    'Get-YurunaRefreshGateState'             = 'Test.SingleInstance'
    'Enter-YurunaSingleFlightLock'           = 'Test.SingleFlightLock'
    'Exit-YurunaSingleFlightLock'            = 'Test.SingleFlightLock'
    'Test-YurunaSingleFlightLockOwned'       = 'Test.SingleFlightLock'
    'Get-YurunaLockRank'                     = 'Test.SingleFlightLock'
    'Read-YurunaCriticalRecord'              = 'Test.CriticalRecord'
    'Write-YurunaCriticalRecord'             = 'Test.CriticalRecord'
    'Get-YurunaProcessIdentityLiveness'      = 'Yuruna.Common'
    'Get-YurunaPrivateStatePath'             = 'Yuruna.Common'
    'Read-TestConfig'                        = 'Test.Config'
    'Get-TestConfigValue'                    = 'Test.Config'
}
$script:HostRefreshAutoModulePath = @{
    'Test.HostRefresh'       = Join-Path $PSScriptRoot 'Test.HostRefresh.psm1'
    'Test.HostRefreshIntent' = Join-Path $PSScriptRoot 'Test.HostRefreshIntent.psm1'
    'Test.SingleInstance'    = Join-Path $PSScriptRoot 'Test.SingleInstance.psm1'
    'Test.SingleFlightLock'  = Join-Path $PSScriptRoot 'Test.SingleFlightLock.psm1'
    'Test.CriticalRecord'    = Join-Path $PSScriptRoot 'Test.CriticalRecord.psm1'
    'Test.Config'            = Join-Path $PSScriptRoot 'Test.Config.psm1'
    'Yuruna.Common'          = Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1'
}
$script:HostRefreshAutoJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:HostRefreshAutoJsonOption.DateKind = 'String' }
# Lines written once per process (unavailable platform, missing dependency),
# so a host that cannot act says why without repeating it every cycle.
$script:HostRefreshAutoLoggedOnce = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$script:HostRefreshAutoProcessStartUnixMs = $null
$script:HostRefreshAutoHostType = $null

# --- REGION: Private helpers
function Get-HostRefreshAutoField {
    <#
    .SYNOPSIS
        One field of a record that may be a dictionary (parsed JSON) or an
        object, $null when absent.
    #>
    [CmdletBinding()]
    param([AllowNull()]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        foreach ($key in @($InputObject.Keys)) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) { return $InputObject[$key] }
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-HostRefreshAutoToken {
    <#
    .SYNOPSIS
        A lowercase token safe to write into a served file or a log line, or
        the fallback when the value is not one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value, [string]$Fallback = 'unclassified')
    $text = "$Value".Trim()
    if ($text -cmatch $script:HostRefreshAutoTokenPattern) { return $text }
    return $Fallback
}

function ConvertTo-HostRefreshAutoUtcDate {
    <#
    .SYNOPSIS
        A UTC instant from a DateTime, DateTimeOffset or ISO-8601 string, or
        $null when the value is none of them.
    .DESCRIPTION
        An Unspecified DateTime is taken as UTC, never converted as local
        time: every instant this module stores is UTC, and a local-time
        reading would shift a reservation by the host's offset.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
    }
    if ($Value -is [System.DateTimeOffset]) { return $Value.UtcDateTime }
    $text = "$Value".Trim()
    if (-not $text) { return $null }
    $parsed = [System.DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
    if ([System.DateTimeOffset]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Get-HostRefreshAutoNow {
    <#
    .SYNOPSIS
        The current UTC time from an injected clock (a scriptblock, a
        DateTime or a DateTimeOffset), or the system clock.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Clock)
    $value = if ($Clock -is [scriptblock]) { & $Clock } else { $Clock }
    $utc = ConvertTo-HostRefreshAutoUtcDate -Value $value
    if ($null -eq $utc) { return [datetime]::UtcNow }
    return [datetime]$utc
}

function Get-HostRefreshAutoUtcDay {
    <#
    .SYNOPSIS
        The yyyy-MM-dd UTC day of an instant; the budget rolls over at
        00:00:00Z.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][datetime]$Utc)
    return $Utc.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-HostRefreshAutoUtcDay {
    <#
    .SYNOPSIS
        The UTC midnight a yyyy-MM-dd day string names, or $null.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Value)
    $text = "$Value".Trim()
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ($text -cmatch '^\d{4}-\d{2}-\d{2}$' -and
        [datetime]::TryParseExact($text, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }
    return $null
}

function Resolve-HostRefreshAutoCommand {
    <#
    .SYNOPSIS
        Make each named command visible, importing its module once when it
        is not, and report the first one that stays missing.
    .DESCRIPTION
        A command already visible -- loaded by the caller or defined as a
        test stand-in -- is used as is and nothing is imported. Otherwise the
        owning module is imported -Global without -Force, so a copy the
        caller already holds is reused rather than reloaded under it. An
        import failure is a missing dependency, never an exception.
    .OUTPUTS
        [pscustomobject] @{ Resolved; Reason; Module; Command }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($command in $Name) {
        if (Get-Command -Name $command -ErrorAction SilentlyContinue) { continue }
        $module = [string]$script:HostRefreshAutoDependency[$command]
        $path = if ($module) { $script:HostRefreshAutoModulePath[$module] } else { $null }
        if ($path -and [System.IO.File]::Exists($path)) {
            try {
                Import-Module -Name $path -Global -DisableNameChecking -ErrorAction Stop
            } catch {
                Write-Verbose "Resolve-HostRefreshAutoCommand: importing '$path' failed: $($_.Exception.Message)"
            }
        }
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            $moduleName = if ($module) { $module } else { 'unknown' }
            return [pscustomobject]@{ Resolved = $false; Reason = "dependency-missing:$moduleName"; Module = $moduleName; Command = $command }
        }
    }
    return [pscustomobject]@{ Resolved = $true; Reason = 'resolved'; Module = ''; Command = '' }
}

function Write-HostRefreshAutoLog {
    <#
    .SYNOPSIS
        Format one catalog message and write it to outer.log and the console.
    .DESCRIPTION
        The decision's success stream is its result record, so operator text
        goes to the Information or Warning stream, never Write-Output.
        outer.log is written through Write-OuterLog when it is loaded; a
        logging failure never reaches the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{},
        [ValidateSet('Information', 'Warning')][string]$Level = 'Information'
    )
    $text = $Key
    try { $text = Format-YurunaOperatorMessage -Key $Key -Arguments $Arguments } catch { $null = $_ }
    if (Get-Command -Name Write-OuterLog -ErrorAction SilentlyContinue) {
        try { Write-OuterLog -Message $text } catch { Write-Verbose "Write-HostRefreshAutoLog: outer.log write failed: $($_.Exception.Message)" }
    }
    if ($Level -eq 'Warning') { Write-Warning -Message $text }
    else { Write-Information -MessageData $text -InformationAction Continue }
}

function Write-HostRefreshAutoLogOnce {
    <#
    .SYNOPSIS
        Write-HostRefreshAutoLog at most once per process for one identity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [Parameter(Mandatory)][string]$Key,
        [hashtable]$Arguments = @{},
        [ValidateSet('Information', 'Warning')][string]$Level = 'Information'
    )
    if ($script:HostRefreshAutoLoggedOnce.Add($Identity)) {
        Write-HostRefreshAutoLog -Key $Key -Arguments $Arguments -Level $Level
    } else {
        Write-Verbose "Write-HostRefreshAutoLogOnce: '$Identity' already reported in this process."
    }
}

function Get-HostRefreshAutoProcessStartTime {
    <#
    .SYNOPSIS
        This process's start time in Unix milliseconds, read once; 0 when it
        cannot be read.
    .DESCRIPTION
        The runner's own start-time reader is used when it is loaded, so the
        caller identity recorded with a request matches the one the runner
        reports for itself; .NET's Process.StartTime otherwise. The value is
        read once per process, so the identity recorded at admission and the
        one compared at a later resume come from the same reader.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param()
    if ($null -eq $script:HostRefreshAutoProcessStartUnixMs) {
        $value = $null
        if (Get-Command -Name Get-YurunaProcessStartUnixMs -ErrorAction SilentlyContinue) {
            try { $value = Get-YurunaProcessStartUnixMs -ProcessId $PID } catch { $value = $null }
        }
        if ($null -eq $value -or [long]$value -le 0) {
            try {
                $start = [System.Diagnostics.Process]::GetProcessById($PID).StartTime
                $value = [System.DateTimeOffset]::new($start).ToUnixTimeMilliseconds()
            } catch {
                $value = [long]0
            }
        }
        $script:HostRefreshAutoProcessStartUnixMs = [long]$value
    }
    return [long]$script:HostRefreshAutoProcessStartUnixMs
}

function Get-HostRefreshAutoHostType {
    <#
    .SYNOPSIS
        This host's type from Get-HostType, read once per process; empty when
        the detector is not loaded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (-not $script:HostRefreshAutoHostType) {
        if (Get-Command -Name Get-HostType -ErrorAction SilentlyContinue) {
            try { $script:HostRefreshAutoHostType = [string](Get-HostType) } catch { $script:HostRefreshAutoHostType = '' }
        }
    }
    return [string]$script:HostRefreshAutoHostType
}

function Read-HostRefreshAutoJsonFile {
    <#
    .SYNOPSIS
        Read a small JSON object file without following a link.
    .OUTPUTS
        [pscustomobject] @{ Status ok|missing|unreadable; Data [hashtable] }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $info = [System.IO.FileInfo]::new($Path)
    if ($info.LinkTarget) { return [pscustomobject]@{ Status = 'unreadable'; Data = $null } }
    if (-not $info.Exists) {
        $status = if ([System.IO.Directory]::Exists($Path)) { 'unreadable' } else { 'missing' }
        return [pscustomobject]@{ Status = $status; Data = $null }
    }
    if ($info.Length -gt $script:HostRefreshAutoMaxFileBytes) { return [pscustomobject]@{ Status = 'unreadable'; Data = $null } }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
        $jsonOption = $script:HostRefreshAutoJsonOption
        $data = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop @jsonOption
    } catch {
        return [pscustomobject]@{ Status = 'unreadable'; Data = $null }
    }
    if (-not ($data -is [System.Collections.IDictionary])) { return [pscustomobject]@{ Status = 'unreadable'; Data = $null } }
    return [pscustomobject]@{ Status = 'ok'; Data = $data }
}

function Read-HostRefreshAutoStreak {
    <#
    .SYNOPSIS
        The persisted timeout count, or a fresh zero record.
    .OUTPUTS
        [pscustomobject] @{ Status ok|missing|corrupt; Record [ordered] }.
        A corrupt file yields a zero record the caller rewrites.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    $fresh = [ordered]@{
        schemaVersion = 1; kind = $script:HostRefreshAutoStreakKind; streak = 0; lastCountedGeneration = ''
        firstFaultUtc = $null; lastFaultUtc = $null; lastResponsiveUtc = $null; lastProbeReasons = @()
    }
    $read = Read-HostRefreshAutoJsonFile -Path $Path
    if ($read.Status -eq 'missing') { return [pscustomobject]@{ Status = 'missing'; Record = $fresh } }
    if ($read.Status -ne 'ok') { return [pscustomobject]@{ Status = 'corrupt'; Record = $fresh } }
    $data = $read.Data
    $count = 0
    $valid = ("$($data['schemaVersion'])" -eq '1') -and ([string]$data['kind'] -ceq $script:HostRefreshAutoStreakKind) -and
        [int]::TryParse("$($data['streak'])", [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$count) -and
        ($count -ge 0)
    if (-not $valid) { return [pscustomobject]@{ Status = 'corrupt'; Record = $fresh } }
    $fresh.streak = $count
    $fresh.lastCountedGeneration = [string]$data['lastCountedGeneration']
    $fresh.firstFaultUtc = $data['firstFaultUtc']
    $fresh.lastFaultUtc = $data['lastFaultUtc']
    $fresh.lastResponsiveUtc = $data['lastResponsiveUtc']
    $fresh.lastProbeReasons = @($data['lastProbeReasons'] | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ Status = 'ok'; Record = $fresh }
}

function Get-HostRefreshAutoPoolOverride {
    <#
    .SYNOPSIS
        The pool's config.testCycle map as a plain hashtable; empty for no
        pool, no config or no testCycle block.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Pool)
    $out = @{}
    if (-not ($Pool -is [System.Collections.IDictionary])) { return $out }
    $config = $Pool['config']
    if (-not ($config -is [System.Collections.IDictionary])) { return $out }
    $testCycle = $config['testCycle']
    if (-not ($testCycle -is [System.Collections.IDictionary])) { return $out }
    foreach ($key in $testCycle.Keys) { $out[[string]$key] = $testCycle[$key] }
    return $out
}

function Get-HostRefreshAutoProtocolFileVersion {
    <#
    .SYNOPSIS
        The repair protocol version the tree on disk declares.
    .DESCRIPTION
        The resident outer keeps this module in memory across tree updates,
        so the file is compared with this module's own constant: a mismatch
        is an old outer running beside a new worker (or the reverse), and an
        automatic launch across that boundary is refused.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$RepoRoot)
    if (-not $RepoRoot) { return [pscustomobject]@{ Valid = $false; Version = 0 } }
    $path = [System.IO.Path]::Combine($RepoRoot, 'test', 'host-refresh.protocol-version')
    try {
        $info = [System.IO.FileInfo]::new($path)
        if (-not $info.Exists -or $info.Length -gt 64) { return [pscustomobject]@{ Valid = $false; Version = 0 } }
        $text = [System.IO.File]::ReadAllText($path).Trim()
        $version = 0
        if ($text -cmatch '^[0-9]{1,6}$' -and [int]::TryParse($text, [ref]$version)) {
            return [pscustomobject]@{ Valid = $true; Version = $version }
        }
    } catch {
        Write-Verbose "Get-HostRefreshAutoProtocolFileVersion: $($_.Exception.Message)"
    }
    return [pscustomobject]@{ Valid = $false; Version = 0 }
}

function Get-HostRefreshAutoProcessLiveness {
    <#
    .SYNOPSIS
        alive, dead or unknown for a recorded process identity.
    .DESCRIPTION
        A pid alone is not an identity: a live process whose start time is
        more than the tolerance away from the recorded one is a recycled pid,
        so the recorded process is dead. A record without a start time, or a
        live pid whose start time cannot be read, is unknown -- and callers
        treat unknown as alive.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$ProcessId, [AllowNull()]$StartTimeUnixMs)
    if (-not (Resolve-HostRefreshAutoCommand -Name 'Get-YurunaProcessIdentityLiveness').Resolved) { return 'unknown' }
    return Get-YurunaProcessIdentityLiveness -ProcessId $ProcessId -StartTimeUnixMs $StartTimeUnixMs
}

function Get-HostRefreshAutoResumeCandidate {
    <#
    .SYNOPSIS
        Whether the blocking request is an automatic one this outer should
        relaunch with the same id.
    .DESCRIPTION
        Only an automatic request qualifies -- local, listener and remote
        requests resume through their own channels -- and only when:
          * it is recovery-pending, still queued, or running with its
            recorded worker positively dead (a worker this outer stopped
            after an overrun, or one that crashed);
          * it is below the attempt cap;
          * it was admitted for this outer process. The worker protects the
            caller the request recorded and does not look for another, so a
            resume by a restarted outer would leave the outer waiting on the
            worker unprotected; that request is left to the operator
            (caller-changed). A request that recorded no caller is protected
            through the worker's own ancestry and may resume;
          * it has been idle for the spacing interval. An unreadable or
            future timestamp is age zero, so a clock set back delays a
            resume rather than hurrying it.
        Restoration is $true when an obligation is armed: the worker then
        only restores what an earlier attempt disrupted.
    .OUTPUTS
        [pscustomobject] @{ Eligible; Reason; RequestId; Attempt; State;
        Restoration }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][datetime]$NowUtc)
    $record = [ordered]@{ Eligible = $false; Reason = 'none'; RequestId = $null; Attempt = 0; State = $null; Restoration = $false }
    $resolved = Resolve-HostRefreshAutoCommand -Name 'Get-HostRefreshActiveRequest'
    if (-not $resolved.Resolved) { $record.Reason = $resolved.Reason; return [pscustomobject]$record }
    $request = Get-HostRefreshActiveRequest
    if ($null -eq $request) { return [pscustomobject]$record }
    $requestId = [string](Get-HostRefreshAutoField -InputObject $request -Name 'requestId')
    $record.RequestId = $requestId
    if ([string](Get-HostRefreshAutoField -InputObject $request -Name 'channel') -cne 'automatic') { $record.Reason = 'not-automatic'; return [pscustomobject]$record }
    if ($requestId -cnotmatch $script:HostRefreshAutoRequestIdPattern) { $record.Reason = 'request-id-invalid'; return [pscustomobject]$record }
    $state = [string](Get-HostRefreshAutoField -InputObject $request -Name 'state')
    $record.State = $state
    if ($state -cnotin @('recovery-pending', 'queued', 'running')) { $record.Reason = 'state-not-resumable'; return [pscustomobject]$record }
    $attempt = 0
    if (-not [int]::TryParse("$(Get-HostRefreshAutoField -InputObject $request -Name 'attempt')", [ref]$attempt)) { $attempt = $script:HostRefreshAutoResumeMaxAttempts }
    $record.Attempt = $attempt
    if ($attempt -ge $script:HostRefreshAutoResumeMaxAttempts) { $record.Reason = 'attempts-exhausted'; return [pscustomobject]$record }
    $context = Get-HostRefreshAutoField -InputObject $request -Name 'context'
    $caller = Get-HostRefreshAutoField -InputObject $context -Name 'callerOuter'
    $callerPid = Get-HostRefreshAutoField -InputObject $caller -Name 'pid'
    if ($null -ne $callerPid -and "$callerPid" -ne '') {
        $callerNumber = 0
        $callerStart = [long]0
        $currentStart = Get-HostRefreshAutoProcessStartTime
        $sameProcess = [int]::TryParse("$callerPid", [ref]$callerNumber) -and $callerNumber -eq $PID -and
            [long]::TryParse("$(Get-HostRefreshAutoField -InputObject $caller -Name 'startTimeUnixMs')", [ref]$callerStart) -and
            $callerStart -gt 0 -and $currentStart -gt 0 -and
            [Math]::Abs([decimal]$callerStart - [decimal]$currentStart) -le $script:HostRefreshAutoIdentityToleranceMs
        if (-not $sameProcess) { $record.Reason = 'caller-changed'; return [pscustomobject]$record }
    }
    $attempts = @(Get-HostRefreshAutoField -InputObject $request -Name 'attempts' | Where-Object { $null -ne $_ })
    $final = if ($attempts.Count -gt 0) { $attempts[$attempts.Count - 1] } else { $null }
    if ($state -ceq 'running') {
        $worker = Get-HostRefreshAutoField -InputObject $final -Name 'worker'
        $liveness = Get-HostRefreshAutoProcessLiveness -ProcessId (Get-HostRefreshAutoField -InputObject $worker -Name 'pid') `
            -StartTimeUnixMs (Get-HostRefreshAutoField -InputObject $worker -Name 'startTimeUnixMs')
        if ($liveness -ne 'dead') { $record.Reason = "worker-$liveness"; return [pscustomobject]$record }
    }
    $armed = @(Get-HostRefreshAutoField -InputObject $request -Name 'obligations' | Where-Object {
            $null -ne $_ -and [string](Get-HostRefreshAutoField -InputObject $_ -Name 'status') -ceq 'armed' })
    $record.Restoration = ($state -ceq 'recovery-pending' -or $armed.Count -gt 0)
    $last = $null
    if ($null -ne $final) {
        $last = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $final -Name 'finishedUtc')
        if ($null -eq $last) { $last = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $final -Name 'claimedUtc') }
    }
    if ($null -eq $last) {
        $launch = Get-HostRefreshAutoField -InputObject $request -Name 'launch'
        $last = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $launch -Name 'updatedUtc')
    }
    if ($null -eq $last) { $last = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $request -Name 'createdUtc') }
    if ($null -eq $last) { $record.Reason = 'age-unknown'; return [pscustomobject]$record }
    $ageSeconds = ($NowUtc - $last).TotalSeconds
    if ($ageSeconds -lt $script:HostRefreshAutoResumeSpacingSeconds) { $record.Reason = 'spacing'; return [pscustomobject]$record }
    $record.Eligible = $true
    $record.Reason = 'eligible'
    return [pscustomobject]$record
}

function Get-HostRefreshAutoVerdict {
    <#
    .SYNOPSIS
        The worker's recorded result for one automatic request, validated
        before it is believed.
    .DESCRIPTION
        The result must be for this request, on the automatic channel, and
        from an attempt that ended after this launch. A success verdict
        additionally needs a responsive final probe and the caller outer
        reported parked -- the two facts that make it safe for this outer to
        continue. Anything else is 'failed' with the mismatch named.

        Freshness is judged on the attempt's own end time: a request left
        recovery-pending (an obligation still armed) has ended its attempt but
        has no terminal time, and it is exactly the result that carries a
        resident-outer handoff. The request's terminal time is the fallback
        for a record that keeps no attempt, such as a tombstone.
    .OUTPUTS
        [pscustomobject] @{ Verdict; Matched; Reason; Handoff }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][datetime]$LaunchUtc
    )
    $record = [ordered]@{ Verdict = 'failed'; Matched = $false; Reason = 'result-missing'; Handoff = $null }
    $resolved = Resolve-HostRefreshAutoCommand -Name 'Get-HostRefreshResult'
    if (-not $resolved.Resolved) { $record.Reason = $resolved.Reason; return [pscustomobject]$record }
    $result = Get-HostRefreshResult -RequestId $RequestId
    if ($null -eq $result -or -not [bool](Get-HostRefreshAutoField -InputObject $result -Name 'Found')) { return [pscustomobject]$record }
    if ([string](Get-HostRefreshAutoField -InputObject $result -Name 'RequestId') -cne $RequestId) { $record.Reason = 'request-mismatch'; return [pscustomobject]$record }
    if ([string](Get-HostRefreshAutoField -InputObject $result -Name 'Channel') -cne 'automatic') { $record.Reason = 'channel-mismatch'; return [pscustomobject]$record }
    # After matching the request and channel, carry the handoff through the
    # freshness and verdict checks: a gate the worker left must be completed by this
    # outer, or every spawn stays held. A stale token is harmless: the outer
    # validates it before any preflight and otherwise follows the gate.
    # The journal keeps a handoff as {tokenId, purpose}; the outer that
    # completes it also needs the request it belongs to, so that is added.
    $handoff = Get-HostRefreshAutoField -InputObject $result -Name 'Handoff'
    $emptyHandoff = ($handoff -is [string] -and -not $handoff) -or ($handoff -is [System.Collections.IDictionary] -and $handoff.Count -eq 0)
    if ($null -ne $handoff -and -not $emptyHandoff) {
        if ($handoff -is [string]) {
            $record.Handoff = $handoff
        } else {
            $copy = [ordered]@{}
            if ($handoff -is [System.Collections.IDictionary]) { foreach ($key in @($handoff.Keys)) { $copy[[string]$key] = $handoff[$key] } }
            else { foreach ($property in $handoff.PSObject.Properties) { $copy[$property.Name] = $property.Value } }
            if (-not (Get-HostRefreshAutoField -InputObject $copy -Name 'RequestId')) { $copy['RequestId'] = $RequestId }
            $record.Handoff = $copy
        }
    }
    $ended = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $result -Name 'LastAttemptEndedUtc')
    if ($null -eq $ended) { $ended = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $result -Name 'CompletedUtc') }
    # One second of slack: the stored instant may be rounded below the launch
    # instant taken in this process, but a result from an earlier attempt is
    # minutes older.
    if ($null -eq $ended -or $ended -lt $LaunchUtc.AddSeconds(-1)) { $record.Reason = 'stale-result'; return [pscustomobject]$record }
    $verdict = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $result -Name 'Verdict') -Fallback 'unknown'
    if ($verdict -in @('repaired', 'already-healthy')) {
        if ([string](Get-HostRefreshAutoField -InputObject $result -Name 'FinalProbeState') -cne 'Responsive') {
            $record.Reason = 'probe-not-responsive'; return [pscustomobject]$record
        }
        if ([string](Get-HostRefreshAutoField -InputObject $result -Name 'RunnerReadiness') -cne 'caller-parked') {
            $record.Reason = 'readiness-mismatch'; return [pscustomobject]$record
        }
    }
    $record.Verdict = $verdict
    $record.Matched = $true
    $record.Reason = 'matched'
    return [pscustomobject]$record
}

function Start-HostRefreshAutoWorkerProcess {
    <#
    .SYNOPSIS
        Start the worker in this console, with SIGINT ignored on Linux and
        macOS, and return its process handle.
    .DESCRIPTION
        No stream is redirected. On Linux and macOS /bin/sh sets SIGINT to
        ignored and replaces itself with the worker, so the handle returned
        is the worker's own; "$0" "$@" hand the executable and every
        argument through without splitting. Elsewhere the worker is started
        directly.
    .OUTPUTS
        [System.Diagnostics.Process]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Private launcher; Invoke-HostRefreshAutoWorker confirms the launch through its own ShouldProcess before calling it.')]
    [CmdletBinding()]
    [OutputType([System.Diagnostics.Process])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.UseShellExecute = $false
    if ($IsWindows) {
        $info.FileName = $FilePath
    } else {
        $info.FileName = '/bin/sh'
        $info.ArgumentList.Add('-c')
        $info.ArgumentList.Add('trap "" INT; exec "$0" "$@"')
        $info.ArgumentList.Add($FilePath)
    }
    foreach ($argument in $ArgumentList) { $info.ArgumentList.Add([string]$argument) }
    return [System.Diagnostics.Process]::Start($info)
}

function Invoke-HostRefreshAutoRun {
    <#
    .SYNOPSIS
        Launch the worker for an admitted or resumed automatic request, read
        and validate its result, and record the outcome on the reservation.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Cycle,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][ValidateSet('attempted', 'resumed')][string]$Mode,
        [int]$Streak,
        [int]$Threshold,
        [string]$MaxRung,
        [int]$Attempt,
        [scriptblock]$WorkerInvoker,
        [AllowNull()]$NowUtc
    )
    $result = [ordered]@{
        Action = $Mode; Reason = ''; Streak = $Streak; Threshold = $Threshold; RequestId = $RequestId
        Verdict = $null; SkipFailurePause = $false; Handoff = $null
    }
    if ($Mode -eq 'resumed') {
        Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_resuming' -Arguments @{
            cycle = "$Cycle"; requestId = $RequestId; attempt = "$($Attempt + 1)"; maxAttempts = "$($script:HostRefreshAutoResumeMaxAttempts)" }
    } else {
        Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_starting' -Arguments @{
            cycle = "$Cycle"; requestId = $RequestId; streak = "$Streak"; maxRung = "$MaxRung" }
    }
    $launchUtc = Get-HostRefreshAutoNow -Clock $NowUtc
    $worker = $null
    $resolved = Resolve-HostRefreshAutoCommand -Name 'New-HostRefreshBudget'
    if (-not $resolved.Resolved) {
        $worker = [pscustomobject]@{ Launched = $false; TimedOut = $false; Reason = $resolved.Reason }
    } else {
        $workerParameter = @{
            RepoRoot = [string]$State['RepoRoot']; PwshExe = [string]$State['PwshExe']; RequestId = $RequestId
            Budget = (New-HostRefreshBudget); ShutdownState = $State['ShutdownState']
        }
        $worker = if ($WorkerInvoker) { & $WorkerInvoker $workerParameter } else { Invoke-HostRefreshAutoWorker @workerParameter -Confirm:$false }
    }
    $launched = [bool](Get-HostRefreshAutoField -InputObject $worker -Name 'Launched')
    if (-not $launched) {
        $result.Verdict = 'launch-failed'
        $result.Reason = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $worker -Name 'Reason') -Fallback 'launch-failed'
        # A request whose worker never started would otherwise sit queued
        # until it expires and block every other channel meanwhile.
        if ((Resolve-HostRefreshAutoCommand -Name 'Set-HostRefreshLaunchOutcome').Resolved) {
            try { $null = Set-HostRefreshLaunchOutcome -RequestId $RequestId -Outcome 'launch-failed' -Confirm:$false }
            catch { Write-Verbose "Invoke-HostRefreshAutoRun: recording the launch failure failed: $($_.Exception.Message)" }
        }
    } elseif ([bool](Get-HostRefreshAutoField -InputObject $worker -Name 'TimedOut')) {
        $result.Verdict = 'worker-timeout'
        $result.Reason = 'worker-timeout'
    } else {
        $read = Get-HostRefreshAutoVerdict -RequestId $RequestId -LaunchUtc $launchUtc
        $result.Verdict = $read.Verdict
        $result.Reason = $read.Reason
        $result.Handoff = $read.Handoff
        if (-not $read.Matched) {
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_verdict_mismatch' -Level Warning -Arguments @{
                cycle = "$Cycle"; requestId = $RequestId; reason = "$($read.Reason)" }
        }
    }
    $afterUtc = Get-HostRefreshAutoNow -Clock $NowUtc
    $budgetPath = Get-HostRefreshAutoStatePath -Name budget
    if ($budgetPath) {
        $null = Set-HostRefreshAutoReservationOutcome -BudgetPath $budgetPath -RequestId $RequestId -Verdict $result.Verdict -NowUtc $afterUtc -Confirm:$false
    }
    Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_finished' -Arguments @{ cycle = "$Cycle"; requestId = $RequestId; verdict = "$($result.Verdict)" }
    if ($result.Verdict -notin @('repaired', 'already-healthy')) {
        $nextDay = Get-HostRefreshAutoUtcDay -Utc $afterUtc.Date.AddDays(1)
        Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_operator_action' -Level Warning -Arguments @{
            cycle = "$Cycle"; requestId = $RequestId; verdict = "$($result.Verdict)"; nextUtcDay = $nextDay }
    }
    $result.SkipFailurePause = ($Branch -eq 'failure' -and $result.Verdict -eq 'repaired')
    return [pscustomobject]$result
}

# --- REGION: Support and evidence
function Get-HostRefreshAutoTriggerSupport {
    <#
    .SYNOPSIS
        Whether automatic repair may act on a host type, and the restart-tier
        ceiling it would use.
    .DESCRIPTION
        Available only when the platform is declared qualified AND the rung
        declaration has at least one available rung of Order 1-4; MaxRung is
        the highest such rung. Pure: it never probes, and on an unqualified
        platform it does not even load the rung declaration.
    .PARAMETER HostType
        The long host-type form Get-HostType returns. Anything else is
        unsupported-host.
    .PARAMETER Rung
        The rung declaration to use instead of Get-VirtualizationRepairRung.
    .OUTPUTS
        [pscustomobject] @{ HostType; Available; Qualified; Reason; Tier;
        MaxRung }. Reason is available, platform-unqualified,
        awaiting-native-qualification, unsupported-host,
        no-available-restart-rung or rung-declaration-missing.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostType,
        [AllowNull()][AllowEmptyCollection()][object[]]$Rung
    )
    $record = [ordered]@{ HostType = $HostType; Available = $false; Qualified = $false; Reason = 'unsupported-host'; Tier = 'restart'; MaxRung = $null }
    $declaration = if ($HostType) { $script:HostRefreshAutoQualification[$HostType] } else { $null }
    if ($null -eq $declaration) { return [pscustomobject]$record }
    $record.Qualified = [bool]$declaration.Qualified
    if (-not $record.Qualified) { $record.Reason = [string]$declaration.Reason; return [pscustomobject]$record }
    $rows = @()
    if ($PSBoundParameters.ContainsKey('Rung')) {
        $rows = @($Rung | Where-Object { $null -ne $_ })
    } else {
        $resolved = Resolve-HostRefreshAutoCommand -Name 'Get-VirtualizationRepairRung'
        if ($resolved.Resolved) {
            try { $rows = @(Get-VirtualizationRepairRung -HostType $HostType) } catch { $rows = @() }
        }
    }
    if ($rows.Count -eq 0) { $record.Reason = 'rung-declaration-missing'; return [pscustomobject]$record }
    $best = $null
    $bestOrder = -1
    foreach ($row in $rows) {
        $order = 0
        if (-not [int]::TryParse("$(Get-HostRefreshAutoField -InputObject $row -Name 'Order')", [ref]$order)) { continue }
        if ($order -lt 1 -or $order -gt 4) { continue }
        if (-not [bool](Get-HostRefreshAutoField -InputObject $row -Name 'Available')) { continue }
        if ($order -gt $bestOrder) { $bestOrder = $order; $best = [string](Get-HostRefreshAutoField -InputObject $row -Name 'Name') }
    }
    if (-not $best) { $record.Reason = 'no-available-restart-rung'; return [pscustomobject]$record }
    $record.Available = $true
    $record.Reason = 'available'
    $record.MaxRung = $best
    return [pscustomobject]$record
}

function ConvertTo-HostRefreshAutoEvidence {
    <#
    .SYNOPSIS
        Classify one service-VM restore sweep as hypervisor fault evidence,
        responsive evidence, or neither.
    .DESCRIPTION
        Only a verified control-channel timeout counts as fault: a row whose
        state could not be read (Outcome state-unknown) because the probe
        timed out (ProbeReason timeout). Any row the hypervisor answered for
        (ProbeReason responsive) makes the sweep responsive, even beside
        timeouts, because an answering hypervisor is not wedged. A denial, a
        missing client, no GUI session, unrecognized output, an unprobed row
        or a row without a ProbeReason (unclassified) counts in neither
        direction, and neither does an empty roster.
    .PARAMETER ServiceRestoreResult
        The records Restore-YurunaServiceVM emitted, as objects or parsed
        dictionaries.
    .OUTPUTS
        [pscustomobject] @{ Verdict fault|responsive|none; ProbeReasons
        [string[]] (distinct, ordinal-sorted); ServiceCount; TimeoutCount;
        ResponsiveCount }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyCollection()][object[]]$ServiceRestoreResult)
    $reasons = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    $serviceCount = 0
    $timeoutCount = 0
    $responsiveCount = 0
    foreach ($row in @($ServiceRestoreResult)) {
        if ($null -eq $row) { continue }
        $serviceCount++
        $reason = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $row -Name 'ProbeReason') -Fallback 'unclassified'
        $null = $reasons.Add($reason)
        if ($reason -ceq 'responsive') { $responsiveCount++; continue }
        $outcome = [string](Get-HostRefreshAutoField -InputObject $row -Name 'Outcome')
        if ($reason -ceq 'timeout' -and $outcome -ceq 'state-unknown') { $timeoutCount++ }
    }
    $verdict = if ($responsiveCount -gt 0) { 'responsive' } elseif ($timeoutCount -gt 0) { 'fault' } else { 'none' }
    return [pscustomobject]@{
        Verdict         = $verdict
        ProbeReasons    = [string[]]@($reasons)
        ServiceCount    = $serviceCount
        TimeoutCount    = $timeoutCount
        ResponsiveCount = $responsiveCount
    }
}

function Write-HostRefreshAutoEvidence {
    <#
    .SYNOPSIS
        Publish this cycle's hypervisor evidence for the resident outer.
    .DESCRIPTION
        Run by the inner runner right after the service-VM restore sweep.
        The sweep absorbs its own probe failures and the cycle may still
        pass, so this file is the only way the outer learns the hypervisor
        timed out. The record carries tokens and counts only -- no VM names,
        no diagnostic text -- because the runtime directory is served.
        Nothing is written for a malformed generation, a phase outside the
        allowlist or a missing runtime directory. Never throws.
    .PARAMETER RuntimeDir
        The runtime directory ($env:YURUNA_RUNTIME_DIR).
    .PARAMETER Generation
        The outer-issued cycle generation, <runnerInstanceId>:<cycle>.
    .PARAMETER Phase
        The runner phase the evidence comes from; only allowlisted
        hypervisor phases are recorded.
    .PARAMETER ServiceRestoreResult
        The Restore-YurunaServiceVM records of this cycle.
    .PARAMETER HostType
        The host type, recorded when it is one of the three long forms.
    .PARAMETER HostId
        The host id, recorded when it has the host-id shape.
    .PARAMETER NowUtc
        A clock: a scriptblock returning a DateTime, or a DateTime.
    .OUTPUTS
        [bool] $true when the file was written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Generation,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Phase,
        [AllowNull()][AllowEmptyCollection()][object[]]$ServiceRestoreResult,
        [AllowNull()][AllowEmptyString()][string]$HostType = '',
        [AllowNull()][AllowEmptyString()][string]$HostId = '',
        [AllowNull()]$NowUtc
    )
    try {
        if ($Generation -cnotmatch $script:HostRefreshAutoGenerationPattern) { Write-Verbose 'Write-HostRefreshAutoEvidence: generation malformed; nothing written.'; return $false }
        if ($Phase -cnotin $script:HostRefreshAutoPhaseAllowlist) { Write-Verbose "Write-HostRefreshAutoEvidence: phase '$Phase' is not allowlisted; nothing written."; return $false }
        if (-not $RuntimeDir -or -not [System.IO.Directory]::Exists($RuntimeDir)) { Write-Verbose 'Write-HostRefreshAutoEvidence: runtime directory missing; nothing written.'; return $false }
        $path = [System.IO.Path]::Combine($RuntimeDir, $script:HostRefreshAutoEvidenceFileName)
        if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_write_evidence' -Arguments @{ generation = $Generation }))) { return $false }
        $evidence = ConvertTo-HostRefreshAutoEvidence -ServiceRestoreResult $ServiceRestoreResult
        $safeHostType = if ($HostType -and $script:HostRefreshAutoQualification.ContainsKey($HostType)) { $HostType.ToLowerInvariant() } else { '' }
        $safeHostId = if ($HostId -cmatch '^[0-9A-Fa-f-]{32,36}$') { $HostId.ToLowerInvariant() } else { '' }
        $now = Get-HostRefreshAutoNow -Clock $NowUtc
        $record = [ordered]@{
            schemaVersion   = 1
            kind            = $script:HostRefreshAutoEvidenceKind
            generation      = $Generation
            phase           = $Phase
            verdict         = $evidence.Verdict
            probeReasons    = [string[]]@($evidence.ProbeReasons)
            serviceCount    = $evidence.ServiceCount
            timeoutCount    = $evidence.TimeoutCount
            responsiveCount = $evidence.ResponsiveCount
            hostType        = $safeHostType
            hostId          = $safeHostId
            observedUtc     = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
            writerPid       = $PID
        }
        if (Write-YurunaStateFileJson -Path $path -InputObject $record -Depth 5 -Confirm:$false -WhatIf:$false) { return $true }
        Write-Warning -Message (Format-YurunaOperatorMessage -Key 'runner.host_refresh_evidence_write_failed' -Arguments @{ reason = 'write-failed' })
        return $false
    } catch {
        # Only a token reaches the operator line: the exception text can carry
        # a path or other detail the line's reader has no use for.
        Write-Verbose "Write-HostRefreshAutoEvidence: $($_.Exception.Message)"
        $reason = ConvertTo-HostRefreshAutoToken -Value $_.Exception.GetType().FullName.ToLowerInvariant() -Fallback 'exception'
        try { Write-Warning -Message (Format-YurunaOperatorMessage -Key 'runner.host_refresh_evidence_write_failed' -Arguments @{ reason = $reason }) }
        catch { Write-Verbose "Write-HostRefreshAutoEvidence: $($_.Exception.Message)" }
        return $false
    }
}

function Read-HostRefreshAutoEvidence {
    <#
    .SYNOPSIS
        Read, validate and optionally consume the evidence file of one cycle.
    .DESCRIPTION
        The file is accepted only for the generation just dispatched, an
        allowlisted phase and a known verdict. -Consume deletes it on every
        path where it exists -- matched, mismatched or corrupt -- so a file
        written for another cycle never lingers into the next one.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER Generation
        The generation the caller dispatched.
    .PARAMETER Consume
        Delete the file after reading it.
    .OUTPUTS
        [pscustomobject] @{ Matched; Reason matched|missing|unreadable|schema|
        generation-mismatch|phase-not-allowlisted|verdict-invalid; Verdict;
        Phase; ProbeReasons [string[]]; ObservedUtc }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Generation,
        [switch]$Consume
    )
    $record = [ordered]@{ Matched = $false; Reason = 'missing'; Verdict = $null; Phase = $null; ProbeReasons = [string[]]@(); ObservedUtc = $null }
    if (-not $RuntimeDir) { return [pscustomobject]$record }
    $path = [System.IO.Path]::Combine($RuntimeDir, $script:HostRefreshAutoEvidenceFileName)
    $read = Read-HostRefreshAutoJsonFile -Path $path
    if ($read.Status -eq 'missing') { return [pscustomobject]$record }
    try {
        if ($read.Status -ne 'ok') { $record.Reason = 'unreadable'; return [pscustomobject]$record }
        $data = $read.Data
        if ("$($data['schemaVersion'])" -ne '1' -or [string]$data['kind'] -cne $script:HostRefreshAutoEvidenceKind) { $record.Reason = 'schema'; return [pscustomobject]$record }
        $record.Phase = ConvertTo-HostRefreshAutoToken -Value $data['phase']
        $record.ObservedUtc = [string]$data['observedUtc']
        $record.ProbeReasons = [string[]]@($data['probeReasons'] | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-HostRefreshAutoToken -Value $_ })
        if (-not $Generation -or [string]$data['generation'] -cne $Generation) { $record.Reason = 'generation-mismatch'; return [pscustomobject]$record }
        if ([string]$data['phase'] -cnotin $script:HostRefreshAutoPhaseAllowlist) { $record.Reason = 'phase-not-allowlisted'; return [pscustomobject]$record }
        $verdict = [string]$data['verdict']
        if ($verdict -cnotin @('fault', 'responsive', 'none')) { $record.Reason = 'verdict-invalid'; return [pscustomobject]$record }
        $record.Verdict = $verdict
        $record.Matched = $true
        $record.Reason = 'matched'
        return [pscustomobject]$record
    } finally {
        if ($Consume -and $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_consume_evidence'))) {
            try { [System.IO.File]::Delete($path) } catch { Write-Verbose "Read-HostRefreshAutoEvidence: removing '$path' failed: $($_.Exception.Message)" }
        }
    }
}

function Update-HostRefreshAutoEvidence {
    <#
    .SYNOPSIS
        Account one dispatched cycle: consume its evidence file and update
        the persisted timeout count.
    .DESCRIPTION
        Called by the resident outer after every dispatch, whatever the
        outcome, so the evidence file never outlives its cycle. Only a
        'completed' outcome can change the count: a matched fault adds one
        (once per generation, so a replayed file cannot count twice), a
        matched responsive observation resets it to zero, and anything else
        -- no evidence, another cycle's file, an aborted, failed-spawn,
        pull-error, paused, drained or shut-down cycle -- leaves it alone.
        The count lives in a private file, so it survives a runner restart
        with a new instance id; a corrupt file restarts it at zero. When the
        private root is unavailable nothing is counted. Never throws.
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER Generation
        The generation the outer minted for the dispatched cycle.
    .PARAMETER Outcome
        The normalized dispatch outcome.
    .PARAMETER StreakPath
        The streak file to use instead of the private-root default.
    .PARAMETER NowUtc
        A clock: a scriptblock returning a DateTime, or a DateTime.
    .OUTPUTS
        [pscustomobject] @{ Outcome; Evidence; Counted; Reset; Streak;
        StreakPersisted; Reason }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Generation,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Outcome,
        [string]$StreakPath,
        [AllowNull()]$NowUtc
    )
    $record = [ordered]@{ Outcome = $Outcome; Evidence = $null; Counted = $false; Reset = $false; Streak = 0; StreakPersisted = $false; Reason = '' }
    try {
        $record.Evidence = Read-HostRefreshAutoEvidence -RuntimeDir $RuntimeDir -Generation $Generation -Consume -Confirm:$false
        $path = if ($PSBoundParameters.ContainsKey('StreakPath')) { $StreakPath } else { Get-HostRefreshAutoStatePath -Name streak -NoCreate }
        $streak = $null
        if ($path) { $streak = Read-HostRefreshAutoStreak -Path $path }
        if ($streak) {
            $record.Streak = [int]$streak.Record.streak
            $record.StreakPersisted = ($streak.Status -ne 'corrupt')
        }
        if ($Outcome -cne 'completed') { $record.Reason = 'not-completed'; return [pscustomobject]$record }
        $evidence = $record.Evidence
        $write = $false
        $next = if ($streak) { $streak.Record } else { $null }
        $now = Get-HostRefreshAutoNow -Clock $NowUtc
        $stamp = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        if (-not $evidence.Matched) {
            $record.Reason = [string]$evidence.Reason
        } elseif ($evidence.Verdict -ceq 'fault') {
            if ($next -and [string]$next.lastCountedGeneration -ceq $Generation) {
                $record.Reason = 'already-counted'
            } else {
                $record.Reason = 'counted'
                $write = $true
            }
        } elseif ($evidence.Verdict -ceq 'responsive') {
            $record.Reason = 'responsive'
            if ($next -and ([int]$next.streak -gt 0 -or $streak.Status -eq 'corrupt')) { $write = $true; $record.Reset = $true }
        } else {
            $record.Reason = 'no-fault-evidence'
        }
        if (-not $write -and $streak -and $streak.Status -eq 'corrupt') { $write = $true }
        if (-not $write) { return [pscustomobject]$record }
        if (-not $path -or ($null -eq $next)) {
            # The path was unresolved without creating the root; a write is
            # needed now, so resolve it again allowing creation.
            if (-not $PSBoundParameters.ContainsKey('StreakPath')) { $path = Get-HostRefreshAutoStatePath -Name streak }
            if (-not $path) {
                $record.Counted = $false; $record.Reset = $false; $record.StreakPersisted = $false
                $record.Reason = 'private-root-unavailable'
                return [pscustomobject]$record
            }
            $streak = Read-HostRefreshAutoStreak -Path $path
            $next = $streak.Record
        }
        if ($record.Reason -ceq 'counted') {
            if ([int]$next.streak -eq 0) { $next.firstFaultUtc = $stamp }
            $next.streak = [int]$next.streak + 1
            $next.lastCountedGeneration = $Generation
            $next.lastFaultUtc = $stamp
            $next.lastProbeReasons = [string[]]@($evidence.ProbeReasons)
        } elseif ($record.Reason -ceq 'responsive') {
            $next.streak = 0
            $next.firstFaultUtc = $null
            $next.lastResponsiveUtc = $stamp
            $next.lastProbeReasons = [string[]]@($evidence.ProbeReasons)
        }
        $record.Streak = [int]$next.streak
        if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_update_streak' -Arguments @{ streak = "$($next.streak)" }))) {
            $record.Counted = $false; $record.Reset = $false; $record.StreakPersisted = $false; $record.Reason = 'preview'
            return [pscustomobject]$record
        }
        if (Write-YurunaStateFileJson -Path $path -InputObject $next -Depth 5 -Confirm:$false -WhatIf:$false) {
            $record.StreakPersisted = $true
            $record.Counted = ($record.Reason -ceq 'counted')
        } else {
            $record.StreakPersisted = $false
            $record.Counted = $false
            $record.Reset = $false
            $record.Reason = 'streak-unwritable'
        }
        return [pscustomobject]$record
    } catch {
        Write-Verbose "Update-HostRefreshAutoEvidence: $($_.Exception.Message)"
        $record.Counted = $false
        $record.Reset = $false
        $record.Reason = 'error'
        return [pscustomobject]$record
    }
}

function Get-HostRefreshAutoStatePath {
    <#
    .SYNOPSIS
        The private path of the timeout-count file or the budget ledger.
    .DESCRIPTION
        Both live under the private state root, never in a served directory:
        the ledger authorizes an unattended restart and the count feeds it.
    .PARAMETER Name
        streak or budget.
    .PARAMETER NoCreate
        Observe only: a root that does not exist yet yields $null instead of
        being created.
    .OUTPUTS
        [string] the path, or $null when the private root is unavailable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('streak', 'budget')][string]$Name,
        [switch]$NoCreate
    )
    $resolved = Resolve-HostRefreshAutoCommand -Name 'Get-YurunaPrivateStatePath'
    if (-not $resolved.Resolved) { return $null }
    $fileName = if ($Name -eq 'streak') { $script:HostRefreshAutoStreakFileName } else { $script:HostRefreshAutoBudgetFileName }
    try {
        $state = Get-YurunaPrivateStatePath -Name $fileName -NoCreate:$NoCreate
    } catch {
        Write-Verbose "Get-HostRefreshAutoStatePath: $($_.Exception.Message)"
        return $null
    }
    if ($state -and $state.Resolved -and $state.Path) { return [string]$state.Path }
    return $null
}

# --- REGION: Budget ledger
function Get-HostRefreshAutoBudget {
    <#
    .SYNOPSIS
        Read the UTC-day reservation ledger.
    .DESCRIPTION
        A missing ledger is an empty one. Anything the critical-record reader
        cannot validate, and a payload of another shape, makes automatic
        repair unavailable until an operator inspects and removes the ledger
        (both the record and its .prev); local repair stays available.
    .PARAMETER BudgetPath
        The ledger (Get-HostRefreshAutoStatePath -Name budget).
    .OUTPUTS
        [pscustomobject] @{ Status ok|missing|corrupt|unreadable|
        writer-unavailable; Reservations [object[]]; Generation }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$BudgetPath)
    $record = [ordered]@{ Status = 'writer-unavailable'; Reservations = @(); Generation = [long]0 }
    $resolved = Resolve-HostRefreshAutoCommand -Name @('Read-YurunaCriticalRecord', 'Write-YurunaCriticalRecord')
    if (-not $resolved.Resolved) { return [pscustomobject]$record }
    try {
        $read = Read-YurunaCriticalRecord -Path $BudgetPath -Kind $script:HostRefreshAutoBudgetKind
    } catch {
        Write-Verbose "Get-HostRefreshAutoBudget: $($_.Exception.Message)"
        $record.Status = 'unreadable'
        return [pscustomobject]$record
    }
    switch ([string]$read.Status) {
        'missing' { $record.Status = 'missing'; return [pscustomobject]$record }
        'ok' { }
        { $_ -in @('corrupt', 'unsupported-version', 'kind-mismatch') } { $record.Status = 'corrupt'; return [pscustomobject]$record }
        default { $record.Status = 'unreadable'; return [pscustomobject]$record }
    }
    $payload = $read.Payload
    if (-not ($payload -is [System.Collections.IDictionary]) -or "$($payload['schemaVersion'])" -ne '1' -or
        [string]$payload['kind'] -cne $script:HostRefreshAutoBudgetKind) {
        $record.Status = 'corrupt'
        return [pscustomobject]$record
    }
    $record.Status = 'ok'
    $record.Generation = [long]$read.Generation
    $record.Reservations = @($payload['reservations'] | Where-Object { $null -ne $_ })
    return [pscustomobject]$record
}

function Test-HostRefreshAutoBudgetAvailable {
    <#
    .SYNOPSIS
        Whether the ledger leaves today's automatic attempt free.
    .DESCRIPTION
        Pure. A reservation dated today uses the day; the UTC day rolls over
        at 00:00:00Z. A reservation dated after today, or reserved later
        than now plus the skew, means the clock went backwards, and the
        ledger refuses rather than letting a rolled-back clock free a used
        day. A row that cannot be parsed fails closed.
    .PARAMETER Reservation
        The ledger rows.
    .PARAMETER NowUtc
        The current time; an Unspecified kind is taken as UTC.
    .PARAMETER ClockSkewSeconds
        How far in the future a reservation instant may lie before it counts
        as a clock rollback.
    .OUTPUTS
        [pscustomobject] @{ Available; Reason available|daily-budget-used|
        clock-rollback|malformed-reservation; UtcDay }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Reservation,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [ValidateRange(0, 86400)][int]$ClockSkewSeconds = 300
    )
    $now = ConvertTo-HostRefreshAutoUtcDate -Value $NowUtc
    $today = Get-HostRefreshAutoUtcDay -Utc $now
    $todayStart = $now.Date
    $rows = @($Reservation | Where-Object { $null -ne $_ })
    $parsed = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $rows) {
        $day = ConvertFrom-HostRefreshAutoUtcDay -Value (Get-HostRefreshAutoField -InputObject $row -Name 'utcDay')
        $reserved = ConvertTo-HostRefreshAutoUtcDate -Value (Get-HostRefreshAutoField -InputObject $row -Name 'reservedUtc')
        if ($null -eq $day -or $null -eq $reserved) {
            return [pscustomobject]@{ Available = $false; Reason = 'malformed-reservation'; UtcDay = $today }
        }
        $parsed.Add([pscustomobject]@{ Day = $day; Reserved = $reserved })
    }
    foreach ($entry in $parsed) {
        if ($entry.Day -gt $todayStart -or $entry.Reserved -gt $now.AddSeconds($ClockSkewSeconds)) {
            return [pscustomobject]@{ Available = $false; Reason = 'clock-rollback'; UtcDay = $today }
        }
    }
    foreach ($entry in $parsed) {
        if ($entry.Day -eq $todayStart) {
            return [pscustomobject]@{ Available = $false; Reason = 'daily-budget-used'; UtcDay = $today }
        }
    }
    return [pscustomobject]@{ Available = $true; Reason = 'available'; UtcDay = $today }
}

function Add-HostRefreshAutoReservation {
    <#
    .SYNOPSIS
        Durably reserve today's automatic attempt, before any request exists.
    .DESCRIPTION
        The caller holds the admission lock and passes it. The ledger is
        re-read and re-checked under that lock, then appended through the
        critical-record writer with a compare-and-set on the generation read.
        Only rows more than the retention period old are pruned -- never a
        row dated today or later, and never an unparseable one. Committed
        $false leaves the day unreserved and refuses the attempt.
    .PARAMETER BudgetPath
        The ledger.
    .PARAMETER AdmissionLock
        The held admission lock (Enter-YurunaSingleFlightLock).
    .PARAMETER RequestId
        The request the reservation is for.
    .PARAMETER Generation
        The cycle generation whose evidence triggered it.
    .PARAMETER HostType
        The host type.
    .PARAMETER NowUtc
        The current time.
    .OUTPUTS
        [pscustomobject] @{ Written; Reason written|preview|admission-lock-not-held|
        budget-unreadable|budget-writer-unavailable|daily-budget-used|
        clock-rollback|malformed-reservation|budget-unwritable; UtcDay }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][AllowNull()]$AdmissionLock,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Generation,
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostType,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $now = ConvertTo-HostRefreshAutoUtcDate -Value $NowUtc
    $today = Get-HostRefreshAutoUtcDay -Utc $now
    $record = [ordered]@{ Written = $false; Reason = 'budget-writer-unavailable'; UtcDay = $today }
    $resolved = Resolve-HostRefreshAutoCommand -Name @('Test-YurunaSingleFlightLockOwned', 'Read-YurunaCriticalRecord', 'Write-YurunaCriticalRecord')
    if (-not $resolved.Resolved) { return [pscustomobject]$record }
    if (-not (Test-YurunaSingleFlightLockOwned -Lock $AdmissionLock)) { $record.Reason = 'admission-lock-not-held'; return [pscustomobject]$record }
    if (-not $PSCmdlet.ShouldProcess($BudgetPath, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_reserve' -Arguments @{ utcDay = $today }))) {
        $record.Reason = 'preview'
        return [pscustomobject]$record
    }
    $budget = Get-HostRefreshAutoBudget -BudgetPath $BudgetPath
    if ($budget.Status -eq 'writer-unavailable') { return [pscustomobject]$record }
    if ($budget.Status -notin @('ok', 'missing')) { $record.Reason = 'budget-unreadable'; return [pscustomobject]$record }
    $cutoff = $now.Date.AddDays(-$script:HostRefreshAutoLedgerRetentionDays)
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($budget.Reservations)) {
        $day = ConvertFrom-HostRefreshAutoUtcDay -Value (Get-HostRefreshAutoField -InputObject $row -Name 'utcDay')
        if ($null -ne $day -and $day -lt $cutoff) { continue }
        $kept.Add($row)
    }
    $check = Test-HostRefreshAutoBudgetAvailable -Reservation $kept.ToArray() -NowUtc $now
    if (-not $check.Available) { $record.Reason = $check.Reason; return [pscustomobject]$record }
    $kept.Add([ordered]@{
        utcDay      = $today
        reservedUtc = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        requestId   = $RequestId
        generation  = ConvertTo-HostRefreshAutoToken -Value $Generation -Fallback ''
        hostType    = ConvertTo-HostRefreshAutoToken -Value $HostType -Fallback ''
        outcome     = $null
        outcomeUtc  = $null
    })
    $payload = [ordered]@{ schemaVersion = 1; kind = $script:HostRefreshAutoBudgetKind; reservations = $kept.ToArray() }
    try {
        $write = Write-YurunaCriticalRecord -Path $BudgetPath -Kind $script:HostRefreshAutoBudgetKind -Payload $payload -ExpectedGeneration $budget.Generation -Confirm:$false
    } catch {
        Write-Verbose "Add-HostRefreshAutoReservation: $($_.Exception.Message)"
        $write = $null
    }
    if ($write -and [bool]$write.Committed) {
        $record.Written = $true
        $record.Reason = 'written'
    } else {
        $record.Reason = 'budget-unwritable'
    }
    return [pscustomobject]$record
}

function Set-HostRefreshAutoReservationOutcome {
    <#
    .SYNOPSIS
        Record how an automatic attempt ended on its reservation row.
    .DESCRIPTION
        Takes the admission lock itself. The row stays -- an outcome never
        frees the day it reserved.
    .PARAMETER BudgetPath
        The ledger.
    .PARAMETER RequestId
        The request whose row is updated.
    .PARAMETER Verdict
        The verdict token to record.
    .PARAMETER NowUtc
        The current time.
    .PARAMETER AdmissionLockPath
        The admission lock to take instead of the private-root default.
    .PARAMETER AdmissionWaitMs
        How long to wait for the admission lock.
    .OUTPUTS
        [bool] $true when the outcome was committed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$BudgetPath,
        [Parameter(Mandatory)][string]$RequestId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Verdict,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [string]$AdmissionLockPath,
        [ValidateRange(0, 30000)][int]$AdmissionWaitMs = 5000
    )
    try {
        $resolved = Resolve-HostRefreshAutoCommand -Name @('Enter-YurunaSingleFlightLock', 'Exit-YurunaSingleFlightLock', 'Get-YurunaLockRank', 'Read-YurunaCriticalRecord', 'Write-YurunaCriticalRecord')
        if (-not $resolved.Resolved) { return $false }
        if (-not $AdmissionLockPath) {
            if (-not (Resolve-HostRefreshAutoCommand -Name 'Get-YurunaHostRefreshAdmissionLockPath').Resolved) { return $false }
            $AdmissionLockPath = Get-YurunaHostRefreshAdmissionLockPath
        }
        if (-not $AdmissionLockPath) { return $false }
        $token = ConvertTo-HostRefreshAutoToken -Value $Verdict -Fallback 'unknown'
        if (-not $PSCmdlet.ShouldProcess($BudgetPath, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_record_outcome' -Arguments @{ verdict = $token }))) { return $false }
        $lock = Enter-YurunaSingleFlightLock -Path $AdmissionLockPath -WaitMilliseconds $AdmissionWaitMs -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-refresh-auto-outcome' }
        if (-not $lock.Held) { Write-Verbose "Set-HostRefreshAutoReservationOutcome: admission lock not held ($($lock.Reason))."; return $false }
        try {
            $budget = Get-HostRefreshAutoBudget -BudgetPath $BudgetPath
            if ($budget.Status -ne 'ok') { return $false }
            $rows = @($budget.Reservations)
            $found = $false
            $now = ConvertTo-HostRefreshAutoUtcDate -Value $NowUtc
            foreach ($row in $rows) {
                if ($row -is [System.Collections.IDictionary] -and [string]$row['requestId'] -ceq $RequestId) {
                    $row['outcome'] = $token
                    $row['outcomeUtc'] = $now.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
                    $found = $true
                }
            }
            if (-not $found) { return $false }
            $payload = [ordered]@{ schemaVersion = 1; kind = $script:HostRefreshAutoBudgetKind; reservations = $rows }
            $write = Write-YurunaCriticalRecord -Path $BudgetPath -Kind $script:HostRefreshAutoBudgetKind -Payload $payload -ExpectedGeneration $budget.Generation -Confirm:$false
            return [bool]($write -and $write.Committed)
        } finally {
            Exit-YurunaSingleFlightLock -Lock $lock
        }
    } catch {
        Write-Verbose "Set-HostRefreshAutoReservationOutcome: $($_.Exception.Message)"
        return $false
    }
}

# --- REGION: Configuration and pool
function Get-HostRefreshAutoThreshold {
    <#
    .SYNOPSIS
        The effective testCycle.autoRefreshAfterStalls: 0 (off) or at least 2.
    .DESCRIPTION
        Read fresh from test.config.yml on every call, so an edit takes
        effect at the next cycle without a runner restart. A pool's
        config.testCycle override wins when it is a whole number of zero or
        more -- including 0, which turns automatic repair off fleet-wide; an
        invalid pool value is ignored. A value that is not a non-negative
        whole number turns it off and warns. 1 is raised to 2: an automatic
        restart needs the timeout observed in two completed cycles.
    .PARAMETER ConfigPath
        The test.config.yml path.
    .PARAMETER PoolTestCycleOverride
        The pool's config.testCycle map.
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigPath,
        [AllowNull()][hashtable]$PoolTestCycleOverride
    )
    $value = 0
    $raw = $null
    if ($ConfigPath -and (Resolve-HostRefreshAutoCommand -Name @('Read-TestConfig', 'Get-TestConfigValue')).Resolved) {
        try {
            $config = Read-TestConfig -Path $ConfigPath -NoCache
            $raw = Get-TestConfigValue -Config $config -Path 'testCycle.autoRefreshAfterStalls'
        } catch {
            Write-Verbose "Get-HostRefreshAutoThreshold: reading '$ConfigPath' failed: $($_.Exception.Message)"
        }
    }
    $number = 0
    $style = [System.Globalization.NumberStyles]::Integer
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($null -ne $raw) {
        if ([int]::TryParse("$raw".Trim(), $style, $culture, [ref]$number) -and $number -ge 0) {
            $value = $number
        } else {
            Write-Warning -Message (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_knob_invalid' -Arguments @{ value = "$raw" })
        }
    }
    if ($PoolTestCycleOverride -and $PoolTestCycleOverride.ContainsKey('autoRefreshAfterStalls')) {
        $poolValue = $PoolTestCycleOverride['autoRefreshAfterStalls']
        if ([int]::TryParse("$poolValue".Trim(), $style, $culture, [ref]$number) -and $number -ge 0) { $value = $number }
    }
    if ($value -gt 0 -and $value -lt $script:HostRefreshAutoMinimumThreshold) { $value = $script:HostRefreshAutoMinimumThreshold }
    return [int]$value
}

function Get-HostRefreshAutoPoolContext {
    <#
    .SYNOPSIS
        The pool's desired state and testCycle override, pulled fresh.
    .DESCRIPTION
        The resident outer holds no pool state of its own -- the per-cycle
        process pulls it and exits -- so a decision about an unattended
        repair pulls it again (bounded; Sync-YurunaPoolIntent never throws).
        No pool sync loaded, or pool sync turned off in the configuration, is
        a single host: run.

        With pool sync on, the pull must produce this host's pool record.
        The runner cycles as a single host when it does not -- no intent was
        pulled or cached, it could not be parsed, or this host is not a
        member -- but an unattended restart cannot tell a fleet that wants
        this host paused from one it simply cannot read, so that case is
        unknown, which refuses an automatic attempt. A reader that throws is
        unknown too.
    .OUTPUTS
        [pscustomobject] @{ DesiredState run|paused|drain|unknown;
        TestCycleOverride [hashtable]; Source pull|no-pool-sync|
        no-pool-record|error }.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    if (-not (Get-Command -Name Sync-YurunaPoolIntent -ErrorAction SilentlyContinue) -or
        -not (Get-Command -Name Resolve-YurunaPoolDesiredState -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'no-pool-sync' }
    }
    try {
        $pool = Sync-YurunaPoolIntent
        if ($null -eq $pool) {
            $enabled = $false
            if (Get-Command -Name Get-YurunaPoolConfig -ErrorAction SilentlyContinue) {
                # The pull has already warned about a half-configured pool;
                # this read only asks whether pool sync is on.
                $poolConfig = Get-YurunaPoolConfig -WarningAction SilentlyContinue
                $enabled = [bool]($poolConfig -and $poolConfig.Enabled)
            }
            if ($enabled) { return [pscustomobject]@{ DesiredState = 'unknown'; TestCycleOverride = @{}; Source = 'no-pool-record' } }
            return [pscustomobject]@{ DesiredState = 'run'; TestCycleOverride = @{}; Source = 'no-pool-sync' }
        }
        $desired = [string](Resolve-YurunaPoolDesiredState -Pool $pool)
        if ($desired -notin @('run', 'paused', 'drain')) { $desired = 'unknown' }
        return [pscustomobject]@{ DesiredState = $desired; TestCycleOverride = (Get-HostRefreshAutoPoolOverride -Pool $pool); Source = 'pull' }
    } catch {
        Write-Verbose "Get-HostRefreshAutoPoolContext: $($_.Exception.Message)"
        return [pscustomobject]@{ DesiredState = 'unknown'; TestCycleOverride = @{}; Source = 'error' }
    }
}

# --- REGION: Admission and worker
function Request-HostRefreshAutoAttempt {
    <#
    .SYNOPSIS
        Admit one automatic repair request, reserving the day first.
    .DESCRIPTION
        Everything happens under one held admission lock, in this order: read
        the budget, check it, ask for the admission decision (read-only),
        write the reservation (a critical write), then create the request. A
        busy host therefore consumes no budget, and any failure after the
        reservation keeps the day used. The request's policy is fixed by the
        automatic channel -- tier restart, no force, no hard stop, no service
        selection -- and is never passed from here. The lifetime lock is
        never taken here.
    .PARAMETER HostType
        The host type.
    .PARAMETER Generation
        The cycle generation whose evidence triggered the attempt.
    .PARAMETER Streak
        The timeout count at the decision.
    .PARAMETER MaxRung
        The restart-tier ceiling (Get-HostRefreshAutoTriggerSupport).
    .PARAMETER RuntimeDir
        The runtime directory.
    .PARAMETER ConfigPath
        The config the runner uses.
    .PARAMETER CallerOuter
        The resident outer: Pid and StartTimeUnixMs. The worker never
        reclaims or restarts it.
    .PARAMETER Evidence
        The evidence record the accounting consumed.
    .PARAMETER NowUtc
        A clock: a scriptblock returning a DateTime, or a DateTime.
    .PARAMETER AdmissionWaitMs
        How long to wait for the admission lock.
    .OUTPUTS
        [pscustomobject] @{ Admitted; RequestId; Reason; UtcDay;
        MissingCommand }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Generation,
        [Parameter(Mandatory)][int]$Streak,
        [Parameter(Mandatory)][AllowEmptyString()][string]$MaxRung,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ConfigPath,
        [Parameter(Mandatory)][AllowNull()]$CallerOuter,
        [Parameter(Mandatory)][AllowNull()]$Evidence,
        [AllowNull()]$NowUtc,
        [ValidateRange(200, 30000)][int]$AdmissionWaitMs = 5000
    )
    $now = Get-HostRefreshAutoNow -Clock $NowUtc
    $record = [ordered]@{ Admitted = $false; RequestId = $null; Reason = ''; UtcDay = (Get-HostRefreshAutoUtcDay -Utc $now); MissingCommand = '' }
    try {
        if ($Generation -cnotmatch $script:HostRefreshAutoGenerationPattern) { $record.Reason = 'generation-invalid'; return [pscustomobject]$record }
        if (-not $MaxRung) { $record.Reason = 'no-available-restart-rung'; return [pscustomobject]$record }
        if (-not $RuntimeDir) { $record.Reason = 'runtime-dir-unset'; return [pscustomobject]$record }
        # The journal's admission reads the refresh gate by name and answers
        # a bare 'unavailable' without it; resolving the reader here names
        # the missing module instead.
        $resolved = Resolve-HostRefreshAutoCommand -Name @(
            'Get-YurunaPrivateStatePath', 'Enter-YurunaSingleFlightLock', 'Exit-YurunaSingleFlightLock', 'Get-YurunaLockRank',
            'Test-YurunaSingleFlightLockOwned', 'Read-YurunaCriticalRecord', 'Write-YurunaCriticalRecord',
            'Get-YurunaHostRefreshAdmissionLockPath', 'Get-HostRefreshAdmissionDecision', 'Request-HostRefreshAdmission',
            'Get-YurunaRefreshGateState')
        if (-not $resolved.Resolved) { $record.Reason = $resolved.Reason; $record.MissingCommand = $resolved.Command; return [pscustomobject]$record }
        if (-not $PSCmdlet.ShouldProcess($HostType, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_admit' -Arguments @{ generation = $Generation }))) {
            $record.Reason = 'preview'
            return [pscustomobject]$record
        }
        $budgetPath = Get-HostRefreshAutoStatePath -Name budget
        $lockPath = Get-YurunaHostRefreshAdmissionLockPath
        if (-not $budgetPath -or -not $lockPath) { $record.Reason = 'private-root-unavailable'; return [pscustomobject]$record }
        $lock = Enter-YurunaSingleFlightLock -Path $lockPath -WaitMilliseconds $AdmissionWaitMs -Rank (Get-YurunaLockRank -Name Admission) -Metadata @{ purpose = 'host-refresh-auto-admission' }
        if (-not $lock.Held) {
            $record.Reason = if ([string]$lock.Reason -in @('held-elsewhere', 'held-by-this-process')) { 'admission-busy' } else { 'admission-unavailable' }
            return [pscustomobject]$record
        }
        try {
            $budget = Get-HostRefreshAutoBudget -BudgetPath $budgetPath
            if ($budget.Status -eq 'writer-unavailable') { $record.Reason = 'budget-writer-unavailable'; return [pscustomobject]$record }
            if ($budget.Status -notin @('ok', 'missing')) { $record.Reason = 'budget-unreadable'; return [pscustomobject]$record }
            $available = Test-HostRefreshAutoBudgetAvailable -Reservation @($budget.Reservations) -NowUtc $now
            if (-not $available.Available) { $record.Reason = $available.Reason; return [pscustomobject]$record }
            $requestId = $null
            if ((Resolve-HostRefreshAutoCommand -Name 'New-YurunaHostRefreshRequestId').Resolved) { $requestId = [string](New-YurunaHostRefreshRequestId) }
            if ($requestId -cnotmatch $script:HostRefreshAutoRequestIdPattern) { $requestId = [guid]::NewGuid().ToString('D') }
            $decision = Get-HostRefreshAdmissionDecision -RequestId $requestId -Channel automatic -Tier restart -MaxRung $MaxRung `
                -RuntimeDir $RuntimeDir -HostType $HostType -AdmissionLock $lock
            $decisionName = [string](Get-HostRefreshAutoField -InputObject $decision -Name 'Decision')
            if ($decisionName -cne 'spawn') {
                $record.Reason = if ($decisionName -ceq 'busy') { 'host-refresh-active' } else { 'admission-' + (ConvertTo-HostRefreshAutoToken -Value $decisionName -Fallback 'unknown') }
                return [pscustomobject]$record
            }
            $reservation = Add-HostRefreshAutoReservation -BudgetPath $budgetPath -AdmissionLock $lock -RequestId $requestId -Generation $Generation `
                -HostType $HostType -NowUtc $now -Confirm:$false
            if (-not $reservation.Written) { $record.Reason = [string]$reservation.Reason; return [pscustomobject]$record }
            $record.RequestId = $requestId
            $callerPid = 0
            $callerStart = [long]0
            $null = [int]::TryParse("$(Get-HostRefreshAutoField -InputObject $CallerOuter -Name 'Pid')", [ref]$callerPid)
            $null = [long]::TryParse("$(Get-HostRefreshAutoField -InputObject $CallerOuter -Name 'StartTimeUnixMs')", [ref]$callerStart)
            $context = @{
                configPath  = $ConfigPath
                callerOuter = if ($callerPid -gt 0) { @{ pid = $callerPid; startTimeUnixMs = $callerStart } } else { $null }
                trigger     = @{
                    generation   = $Generation
                    phase        = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $Evidence -Name 'Phase')
                    probeReasons = [string[]]@(Get-HostRefreshAutoField -InputObject $Evidence -Name 'ProbeReasons' | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-HostRefreshAutoToken -Value $_ })
                    streak       = $Streak
                    observedUtc  = [string](Get-HostRefreshAutoField -InputObject $Evidence -Name 'ObservedUtc')
                }
            }
            $admission = Request-HostRefreshAdmission -RequestId $requestId -Channel automatic -Tier restart -MaxRung $MaxRung `
                -RuntimeDir $RuntimeDir -HostType $HostType -Context $context -AdmissionLock $lock -Confirm:$false
            if ([string](Get-HostRefreshAutoField -InputObject $admission -Name 'Decision') -ceq 'spawn') {
                $record.Admitted = $true
                $record.Reason = 'admitted'
            } else {
                # The reservation stands: the day counts as used even though
                # no request was created, which is the fail-safe direction.
                $record.Reason = 'request-write-failed'
            }
            return [pscustomobject]$record
        } finally {
            Exit-YurunaSingleFlightLock -Lock $lock
        }
    } catch {
        Write-Verbose "Request-HostRefreshAutoAttempt: $($_.Exception.Message)"
        $record.Admitted = $false
        if (-not $record.Reason) { $record.Reason = 'error' }
        return [pscustomobject]$record
    }
}

function Invoke-HostRefreshAutoWorker {
    <#
    .SYNOPSIS
        Run the repair worker for an admitted automatic request, synchronously
        and bounded.
    .DESCRIPTION
        The worker shares this console and has no redirection, so no pipe
        handle is inherited and nothing can wedge on an undrained stream; it
        logs for itself. Its arguments travel as a list, never as one joined
        string, so a repository path with spaces reaches it intact. The
        argument vector is the worker's internal form and carries no policy:
        a vector naming any policy switch is refused before launch.
        YURUNA_NONINTERACTIVE is set for the child and restored afterwards.

        A terminal sends Ctrl+C to its whole foreground process group, and
        the worker has no handler of its own: interrupting a repair halfway
        is worse than finishing it. On Linux and macOS the worker is
        therefore started through /bin/sh with SIGINT ignored and exec'd in
        place -- same process, same handle -- and the .NET runtime keeps a
        SIGINT ignored at startup ignored, as do the processes the worker
        starts. On Windows a console Ctrl+C still reaches the worker.

        The wait polls the held process handle once a second. A shutdown the
        runner's own Ctrl+C handler requested is logged once and does not
        abort the wait. Past TimeoutSeconds only this worker process is
        stopped, through its own handle -- never its tree, never by process
        id -- and its request stays recoverable: the next resume finds its
        worker dead and relaunches it.
    .PARAMETER RepoRoot
        The repository root.
    .PARAMETER PwshExe
        The PowerShell executable.
    .PARAMETER RequestId
        The admitted request.
    .PARAMETER Budget
        The worker budget (New-HostRefreshBudget).
    .PARAMETER TimeoutSeconds
        How long to wait before stopping the worker.
    .PARAMETER ShutdownState
        The loop's shutdown flag holder.
    .PARAMETER ProcessStarter
        Replaces the process start: receives the PowerShell executable and
        the argument array (unquoted, one element per argument) and returns a
        process-like object.
    .PARAMETER ClockTicks
        Replaces the millisecond tick source of the wait.
    .OUTPUTS
        [pscustomobject] @{ Launched; ExitCode; TimedOut; Killed; ElapsedMs;
        WorkerPid; Reason exited|worker-timeout|launch-failed|preview|
        worker-protocol-mismatch|worker-argv-refused|wait-failed|
        dependency-missing:<module> }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$PwshExe,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')][string]$RequestId,
        [Parameter(Mandatory)][psobject]$Budget,
        [ValidateRange(60, 3600)][int]$TimeoutSeconds = 975,
        [AllowNull()][hashtable]$ShutdownState,
        [scriptblock]$ProcessStarter,
        [Parameter(DontShow)][scriptblock]$ClockTicks
    )
    $record = [ordered]@{ Launched = $false; ExitCode = $null; TimedOut = $false; Killed = $false; ElapsedMs = [long]0; WorkerPid = $null; Reason = '' }
    $resolved = Resolve-HostRefreshAutoCommand -Name 'New-HostRefreshWorkerArgumentList'
    if (-not $resolved.Resolved) { $record.Reason = $resolved.Reason; return [pscustomobject]$record }
    try {
        $argv = @(New-HostRefreshWorkerArgumentList -RepoRoot $RepoRoot -RequestId $RequestId -Budget $Budget -IncludeInterpreterArgument)
    } catch {
        Write-Verbose "Invoke-HostRefreshAutoWorker: argument vector refused: $($_.Exception.Message)"
        $record.Reason = 'worker-protocol-mismatch'
        return [pscustomobject]$record
    }
    $refused = @($argv | Where-Object { "$_" -match '^-(force|allowhardstop|tier|maxrung|restoreservicevmname|leavestoppedservicevmname|configpath)$' -or "$_".Contains('"') })
    $fileIndex = [array]::IndexOf([string[]]$argv, '-File')
    $idIndex = [array]::IndexOf([string[]]$argv, '-RequestId')
    if ($refused.Count -gt 0 -or $fileIndex -lt 0 -or $idIndex -lt 0 -or $idIndex + 1 -ge $argv.Count -or [string]$argv[$idIndex + 1] -cne $RequestId) {
        $record.Reason = 'worker-argv-refused'
        return [pscustomobject]$record
    }
    if (-not $PSCmdlet.ShouldProcess($RequestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_run_worker' -Arguments @{ requestId = $RequestId }))) {
        $record.Reason = 'preview'
        return [pscustomobject]$record
    }
    $starter = if ($ProcessStarter) { $ProcessStarter } else {
        { param($FilePath, $ArgumentList) Start-HostRefreshAutoWorkerProcess -FilePath $FilePath -ArgumentList $ArgumentList }
    }
    $clock = if ($ClockTicks) { $ClockTicks } else { { [System.Environment]::TickCount64 } }
    $savedNonInteractive = [System.Environment]::GetEnvironmentVariable('YURUNA_NONINTERACTIVE')
    $process = $null
    $started = [long](& $clock)
    try {
        $env:YURUNA_NONINTERACTIVE = '1'
        $process = & $starter $PwshExe ([string[]]@($argv))
    } catch {
        $record.Reason = 'launch-failed'
        Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_worker_launch_failed' -Level Warning -Arguments @{ requestId = $RequestId; message = "$($_.Exception.Message)" }
        return [pscustomobject]$record
    } finally {
        if ($null -eq $savedNonInteractive) { Remove-Item -LiteralPath 'Env:YURUNA_NONINTERACTIVE' -ErrorAction SilentlyContinue }
        else { $env:YURUNA_NONINTERACTIVE = $savedNonInteractive }
    }
    if ($null -eq $process) {
        $record.Reason = 'launch-failed'
        Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_worker_launch_failed' -Level Warning -Arguments @{ requestId = $RequestId; message = 'no process' }
        return [pscustomobject]$record
    }
    $record.Launched = $true
    try { $record.WorkerPid = [int]$process.Id } catch { $record.WorkerPid = $null }
    $limitMs = [long]$TimeoutSeconds * 1000
    $shutdownLogged = $false
    try {
        while (-not $process.HasExited) {
            $elapsed = [long](& $clock) - $started
            if ($elapsed -ge $limitMs) { break }
            if (-not $shutdownLogged -and $ShutdownState -and $ShutdownState['Requested']) {
                $shutdownLogged = $true
                Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_waiting_on_worker' -Arguments @{
                    requestId = $RequestId; seconds = "$([long][Math]::Ceiling(($limitMs - $elapsed) / 1000))" }
            }
            $null = $process.WaitForExit(1000)
        }
        if (-not $process.HasExited) {
            $record.TimedOut = $true
            $record.Reason = 'worker-timeout'
            try {
                $process.Kill($false)
                $record.Killed = $true
            } catch {
                Write-Verbose "Invoke-HostRefreshAutoWorker: stopping worker $($record.WorkerPid) failed: $($_.Exception.Message)"
            }
            try { $null = $process.WaitForExit(5000) } catch { $null = $_ }
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_worker_timeout' -Level Warning -Arguments @{ requestId = $RequestId; seconds = "$TimeoutSeconds" }
        } else {
            $record.Reason = 'exited'
            try { $record.ExitCode = [int]$process.ExitCode } catch { $record.ExitCode = $null }
        }
    } catch {
        Write-Verbose "Invoke-HostRefreshAutoWorker: waiting on worker failed: $($_.Exception.Message)"
        $record.Reason = 'wait-failed'
    }
    $record.ElapsedMs = [long](& $clock) - $started
    return [pscustomobject]$record
}

# --- REGION: Decision
function Invoke-HostRefreshAutoDecision {
    <#
    .SYNOPSIS
        The resident outer's post-dispatch decision: do nothing, say why not,
        or run one automatic repair.
    .DESCRIPTION
        Checks run in order and the first that fires returns:
          1. resume -- an automatic request this outer process was recorded
             as the caller of, left recovery-pending, queued, or running with
             a dead worker, below the attempt cap and idle for the spacing
             interval, is relaunched with the same id and no new reservation
             while the pool is run and no shutdown is pending. With the knob
             at 0 only a request with an armed obligation resumes (its run
             only restores); anything else is left to the operator, said once
             per request, as is a request recorded for another outer;
          2. anything but a completed cycle (the gated branch, an aborted,
             failed-spawn or storage outcome) does nothing;
          3. threshold 0 is disabled;
          4. a platform not qualified is unavailable, said once per reason;
          5. no fresh counted evidence from this cycle is below threshold;
          6. a count below the threshold is below threshold;
          7. a protocol file that differs from this module is unavailable;
          8. a paused, draining or unknown pool refuses;
          9. a pending shutdown refuses;
         10. admission (budget, decision, reservation, request) may refuse;
         11. the worker runs synchronously, logged before it starts;
         12. its result is believed only for this request, on the automatic
             channel, completed after the launch, and -- for a success --
             with a responsive final probe and the caller parked;
         13. the outcome is recorded on the reservation.
        SkipFailurePause is set only for a repair on the failure branch;
        every other verdict keeps the normal backoff and logs an operator
        action. The count is never reset here. The pool is pulled only when
        this cycle counted fresh evidence or a resume is due.

        Never reads or consumes the operator's cycle-restart flag, the
        preamble-stall state or status.json, never registers a recovery
        handler, and never asks for a hard stop. Never throws; a failure is
        Action error.
    .PARAMETER State
        The loop's State: ConfigPath, RepoRoot, PwshExe, ShutdownState,
        RunnerInstanceId and CycleGeneration are read.
    .PARAMETER Cycle
        The loop's cycle counter.
    .PARAMETER Branch
        success (completed, exit 0), failure (after the failure accounting)
        or gated (the dispatch was held by the refresh gate).
    .PARAMETER Accounting
        The Update-HostRefreshAutoEvidence result of this dispatch.
    .PARAMETER Support
        The Get-HostRefreshAutoTriggerSupport record to use instead of this
        host's declaration.
    .PARAMETER WorkerInvoker
        Replaces the worker run: receives the Invoke-HostRefreshAutoWorker
        parameter hashtable and returns its record.
    .PARAMETER NowUtc
        A clock: a scriptblock returning a DateTime, or a DateTime.
    .OUTPUTS
        [pscustomobject] @{ Action none|disabled|below-threshold|unavailable|
        refused|attempted|resumed|error; Reason; Streak; Threshold; RequestId;
        Verdict; SkipFailurePause; Handoff }.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][int]$Cycle,
        [Parameter(Mandatory)][ValidateSet('success', 'failure', 'gated')][string]$Branch,
        [AllowNull()]$Accounting,
        [AllowNull()]$Support,
        [scriptblock]$WorkerInvoker,
        [AllowNull()]$NowUtc
    )
    $result = [ordered]@{
        Action = 'none'; Reason = ''; Streak = 0; Threshold = 0; RequestId = $null
        Verdict = $null; SkipFailurePause = $false; Handoff = $null
    }
    try {
        $streakValue = 0
        $null = [int]::TryParse("$(Get-HostRefreshAutoField -InputObject $Accounting -Name 'Streak')", [ref]$streakValue)
        $result.Streak = $streakValue
        if (-not $PSCmdlet.ShouldProcess((Get-HostRefreshAutoHostType), (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_decide' -Arguments @{ cycle = "$Cycle" }))) {
            $result.Reason = 'preview'
            return [pscustomobject]$result
        }
        $now = Get-HostRefreshAutoNow -Clock $NowUtc
        $shutdownState = $State['ShutdownState']
        $shutdown = [bool]($shutdownState -is [System.Collections.IDictionary] -and $shutdownState['Requested'])
        $pool = $null
        $threshold = $null

        $resume = Get-HostRefreshAutoResumeCandidate -NowUtc $now
        if ($resume.Eligible) {
            $pool = Get-HostRefreshAutoPoolContext
            if ($pool.DesiredState -eq 'run' -and -not $shutdown) {
                # Turning the knob off stops every automatic repair that has
                # not disrupted anything yet; a request with an armed
                # obligation still resumes, because that run only restores
                # what an earlier attempt stopped.
                if (-not $resume.Restoration) {
                    $threshold = Get-HostRefreshAutoThreshold -ConfigPath ([string]$State['ConfigPath']) -PoolTestCycleOverride $pool.TestCycleOverride
                }
                if ($resume.Restoration -or $threshold -ne 0) {
                    return (Invoke-HostRefreshAutoRun -State $State -Cycle $Cycle -Branch $Branch -RequestId $resume.RequestId -Mode resumed `
                        -Streak $streakValue -Attempt $resume.Attempt -WorkerInvoker $WorkerInvoker -NowUtc $NowUtc)
                }
                Write-HostRefreshAutoLogOnce -Identity "resume-disabled:$($resume.RequestId)" -Key 'runner.host_refresh_auto_resume_disabled' -Level Warning -Arguments @{
                    cycle = "$Cycle"; requestId = [string]$resume.RequestId }
            } else {
                Write-Verbose "Invoke-HostRefreshAutoDecision: resume of $($resume.RequestId) held (pool $($pool.DesiredState), shutdown $shutdown)."
            }
        } elseif ($resume.Reason -ceq 'caller-changed') {
            Write-HostRefreshAutoLogOnce -Identity "caller-changed:$($resume.RequestId)" -Key 'runner.host_refresh_auto_resume_caller_changed' -Level Warning -Arguments @{
                cycle = "$Cycle"; requestId = [string]$resume.RequestId }
        }

        $outcome = [string](Get-HostRefreshAutoField -InputObject $Accounting -Name 'Outcome')
        if ($Branch -eq 'gated' -or $outcome -cne 'completed') { $result.Reason = 'not-a-completed-cycle'; return [pscustomobject]$result }

        $counted = [bool](Get-HostRefreshAutoField -InputObject $Accounting -Name 'Counted')
        if ($counted -and $null -eq $pool) { $pool = Get-HostRefreshAutoPoolContext }
        if ($null -eq $threshold) {
            $override = if ($pool) { $pool.TestCycleOverride } else { @{} }
            $threshold = Get-HostRefreshAutoThreshold -ConfigPath ([string]$State['ConfigPath']) -PoolTestCycleOverride $override
        }
        $result.Threshold = $threshold
        if ($threshold -eq 0) { $result.Action = 'disabled'; $result.Reason = 'threshold-zero'; return [pscustomobject]$result }

        $evidence = Get-HostRefreshAutoField -InputObject $Accounting -Name 'Evidence'
        $phase = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $evidence -Name 'Phase')
        if ($counted) {
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_evidence_counted' -Arguments @{
                cycle = "$Cycle"; phase = $phase; streak = "$streakValue"; threshold = "$threshold" }
        } elseif ([bool](Get-HostRefreshAutoField -InputObject $Accounting -Name 'Reset')) {
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_evidence_reset' -Arguments @{ cycle = "$Cycle"; phase = $phase }
        }

        if ($null -eq $Support) { $Support = Get-HostRefreshAutoTriggerSupport -HostType (Get-HostRefreshAutoHostType) }
        if (-not [bool](Get-HostRefreshAutoField -InputObject $Support -Name 'Available')) {
            $reason = ConvertTo-HostRefreshAutoToken -Value (Get-HostRefreshAutoField -InputObject $Support -Name 'Reason') -Fallback 'unsupported-host'
            $result.Action = 'unavailable'
            $result.Reason = $reason
            Write-HostRefreshAutoLogOnce -Identity "unavailable:$reason" -Key 'runner.host_refresh_auto_unavailable' -Level Warning -Arguments @{ cycle = "$Cycle"; reason = $reason }
            return [pscustomobject]$result
        }
        if (-not $counted) { $result.Action = 'below-threshold'; $result.Reason = 'no-fresh-evidence'; return [pscustomobject]$result }
        if ($streakValue -lt $threshold) { $result.Action = 'below-threshold'; $result.Reason = 'streak-below-threshold'; return [pscustomobject]$result }

        $refuse = {
            param([string]$Action, [string]$Reason)
            $result.Action = $Action
            $result.Reason = $Reason
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_refused' -Arguments @{ cycle = "$Cycle"; reason = $Reason }
            [pscustomobject]$result
        }
        $protocol = Get-HostRefreshAutoProtocolFileVersion -RepoRoot ([string]$State['RepoRoot'])
        if (-not $protocol.Valid -or $protocol.Version -ne $script:HostRefreshAutoProtocolVersion) { return (& $refuse 'unavailable' 'protocol-mismatch') }
        $desired = if ($pool) { [string]$pool.DesiredState } else { 'unknown' }
        if ($desired -ne 'run') { return (& $refuse 'refused' "pool-$desired") }
        if ($shutdown) { return (& $refuse 'refused' 'shutdown-requested') }
        $generation = [string]$State['CycleGeneration']
        $instance = [string]$State['RunnerInstanceId']
        if ($generation -cnotmatch $script:HostRefreshAutoGenerationPattern) { return (& $refuse 'refused' 'generation-missing') }
        if ($instance -cmatch '^[0-9a-f]{32}$' -and -not $generation.StartsWith("${instance}:", [System.StringComparison]::Ordinal)) {
            return (& $refuse 'refused' 'generation-mismatch')
        }
        $hostType = [string](Get-HostRefreshAutoField -InputObject $Support -Name 'HostType')
        if (-not $hostType) { $hostType = Get-HostRefreshAutoHostType }
        $maxRung = [string](Get-HostRefreshAutoField -InputObject $Support -Name 'MaxRung')
        $caller = @{ Pid = $PID; StartTimeUnixMs = (Get-HostRefreshAutoProcessStartTime) }
        $attempt = Request-HostRefreshAutoAttempt -HostType $hostType -Generation $generation -Streak $streakValue -MaxRung $maxRung `
            -RuntimeDir ([string]$env:YURUNA_RUNTIME_DIR) -ConfigPath ([string]$State['ConfigPath']) -CallerOuter $caller `
            -Evidence $evidence -NowUtc $now -Confirm:$false
        if (-not $attempt.Admitted) {
            $reason = [string]$attempt.Reason
            if ($reason.StartsWith('dependency-missing:', [System.StringComparison]::Ordinal)) {
                $module = $reason.Substring('dependency-missing:'.Length)
                $result.Action = 'unavailable'
                $result.Reason = $reason
                Write-HostRefreshAutoLogOnce -Identity "dependency:$module" -Key 'runner.host_refresh_auto_dependency_missing' -Level Warning -Arguments @{
                    cycle = "$Cycle"; command = "$($attempt.MissingCommand)"; module = $module }
                return [pscustomobject]$result
            }
            return (& $refuse 'refused' $reason)
        }
        return (Invoke-HostRefreshAutoRun -State $State -Cycle $Cycle -Branch $Branch -RequestId $attempt.RequestId -Mode attempted `
            -Streak $streakValue -Threshold $threshold -MaxRung $maxRung -WorkerInvoker $WorkerInvoker -NowUtc $NowUtc)
    } catch {
        $result.Action = 'error'
        $result.Reason = 'exception'
        $result.SkipFailurePause = $false
        $result.Handoff = $null
        try { Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_error' -Level Warning -Arguments @{ cycle = "$Cycle"; message = "$($_.Exception.Message)" } }
        catch { Write-Verbose "Invoke-HostRefreshAutoDecision: $($_.Exception.Message)" }
        return [pscustomobject]$result
    }
}

function Stop-HostRefreshAutoQueuedRequest {
    <#
    .SYNOPSIS
        Withdraw an automatic request no worker has claimed, so it does not
        outlive a drain.
    .DESCRIPTION
        Acts only when the blocking request is on the automatic channel and
        still queued; the journal refuses anything a worker already claimed.
        Never throws.
    .PARAMETER Reason
        pool-drain.
    .PARAMETER Cycle
        The loop's cycle counter, for the log line.
    .OUTPUTS
        [bool] $true when a queued automatic request was withdrawn.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateSet('pool-drain')][string]$Reason,
        [int]$Cycle = 0
    )
    try {
        if (-not (Resolve-HostRefreshAutoCommand -Name @('Get-HostRefreshActiveRequest', 'Stop-HostRefreshQueuedRequest')).Resolved) { return $false }
        $request = Get-HostRefreshActiveRequest
        if ($null -eq $request) { return $false }
        if ([string](Get-HostRefreshAutoField -InputObject $request -Name 'channel') -cne 'automatic') { return $false }
        if ([string](Get-HostRefreshAutoField -InputObject $request -Name 'state') -cne 'queued') { return $false }
        $requestId = [string](Get-HostRefreshAutoField -InputObject $request -Name 'requestId')
        if ($requestId -cnotmatch $script:HostRefreshAutoRequestIdPattern) { return $false }
        if (-not $PSCmdlet.ShouldProcess($requestId, (Format-YurunaOperatorMessage -Key 'runner.host_refresh_auto_action_withdraw' -Arguments @{ requestId = $requestId }))) { return $false }
        $stop = Stop-HostRefreshQueuedRequest -RequestId $requestId -Reason $Reason -Confirm:$false
        if ([bool](Get-HostRefreshAutoField -InputObject $stop -Name 'Stopped')) {
            Write-HostRefreshAutoLog -Key 'runner.host_refresh_auto_queued_revoked' -Arguments @{ cycle = "$Cycle"; requestId = $requestId }
            return $true
        }
        return $false
    } catch {
        Write-Verbose "Stop-HostRefreshAutoQueuedRequest: $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function `
    Get-HostRefreshAutoTriggerSupport, ConvertTo-HostRefreshAutoEvidence, Write-HostRefreshAutoEvidence, `
    Read-HostRefreshAutoEvidence, Update-HostRefreshAutoEvidence, Get-HostRefreshAutoStatePath, `
    Get-HostRefreshAutoBudget, Test-HostRefreshAutoBudgetAvailable, Add-HostRefreshAutoReservation, `
    Set-HostRefreshAutoReservationOutcome, Get-HostRefreshAutoThreshold, Get-HostRefreshAutoPoolContext, `
    Request-HostRefreshAutoAttempt, Invoke-HostRefreshAutoWorker, Invoke-HostRefreshAutoDecision, `
    Stop-HostRefreshAutoQueuedRequest
