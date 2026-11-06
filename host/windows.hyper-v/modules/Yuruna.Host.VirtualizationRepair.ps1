<#PSScriptInfo
.VERSION 2026.11.05
.GUID 424c4d3c-cf14-4b3d-b338-493cb7892bac
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver virtualization repair
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

# --- REGION: Virtualization repair
# --- REGION: Test-VirtualizationResponsive
function Test-VirtualizationResponsive {
    <#
    .SYNOPSIS
        Bounded, read-only probe of Hyper-V. Returns the versioned
        Yuruna.VirtualizationProbe record (schema version 1).
    .DESCRIPTION
        The DISM feature state and the vmms service being Running are
        prerequisites, not proof Hyper-V answers a request, so the probe makes one
        read-only provider round trip in a single bounded child pwsh
        ($script:HyperVProbeScript): Get-Service vmms, an explicit
        `Import-Module Hyper-V` (no reliance on autoload in a -NoProfile child),
        then `Hyper-V\Get-VM`. The child reports what it saw as
        `yuruna-probe <key>=<token>` lines written through [Console]::Out, which
        flushes each line, so the evidence survives a kill at the cap. Status and
        start-type tokens are .NET enum names and error categories are enum
        values, so nothing here depends on the display language.

        DISM runs only on unhealthy paths, through Get-HyperVFeatureState, inside
        the probe's remaining time, and its answer is kept separate from the
        service status: a feature that is not installed is a missing client, a
        stopped vmms with the feature Enabled is 'app-stopped'.

        Classification of the child:
          * not launchable                       -> Undetermined/missing-client
          * less than one second of budget left  -> Undetermined/deadline-exhausted
                                                     (nothing is launched)
          * no answer inside the cap after the   -> Unresponsive/timeout (the
            child reported module=loaded             running-but-unresponsive VMMS
                                                     case: the child was waiting on
                                                     Hyper-V\Get-VM)
          * no answer inside the cap before      -> Undetermined/timeout (a slow pwsh
            module=loaded                            start, service query or first
                                                     module load is not a hung VMMS)
          * output not drained or truncated      -> Undetermined/invalid-response
          * exit 0 with provider=ok              -> Responsive/responsive
          * exit 2, vmms not installed           -> Undetermined/missing-client
          * exit 5, vmms Stopped                 -> Unresponsive/app-stopped when the
                                                     feature is Enabled; missing-client
                                                     when it is Disabled, pending or
                                                     unavailable; permission-denied when
                                                     DISM needs elevation; otherwise
                                                     provider-error
          * exit 5, any other service status     -> Undetermined/provider-error
          * exit 3, Hyper-V module missing       -> Undetermined/missing-client
          * exit 4, PermissionDenied category or -> Undetermined/permission-denied
            access-denied wording
          * exit 4 otherwise, exit 6             -> Undetermined/provider-error
          * any other exit                       -> Undetermined/invalid-response

        Evidence keys, always present: serviceStatus, serviceStartType,
        featureState, featureProbe, providerModule, elevated, exitCode,
        drainTimedOut, outputTruncated. The diagnostic field is private.

        Never throws, never prompts, changes nothing.
    .PARAMETER TimeoutSeconds
        Upper bound for the probe.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline / New-YurunaDeadlineFromExpiry);
        the probe never outlives it.
    .OUTPUTS
        [pscustomobject] Yuruna.VirtualizationProbe
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20,
        [object]$Deadline
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $clock = if ($null -ne $Deadline -and $Deadline.ClockTicks) { $Deadline.ClockTicks } else { { [Environment]::TickCount64 } }
    $evidence = [ordered]@{
        serviceStatus    = 'Unknown'
        serviceStartType = 'Unknown'
        featureState     = 'NotProbed'
        featureProbe     = 'not-probed'
        providerModule   = 'not-probed'
        elevated         = [bool](Test-IsAdministrator)
        exitCode         = -1
        drainTimedOut    = $false
        outputTruncated  = $false
    }
    $state = 'Undetermined'; $reason = 'invalid-response'
    $started = $false; $timedOut = $false; $deadlineExhausted = $false; $diagnostic = ''
    try {
        do {
            $capSeconds = $TimeoutSeconds
            if ($null -ne $Deadline) {
                $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 600
                if ($null -eq $bounded) { $reason = 'deadline-exhausted'; $deadlineExhausted = $true; break }
                $capSeconds = [Math]::Min($TimeoutSeconds, [int]$bounded)
            }
            $probeDeadline = New-YurunaDeadlineFromExpiry -ExpiryTick ([long](& $clock) + [long]$capSeconds * 1000) -ClockTicks $clock
            $result = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) `
                -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script:HyperVProbeScript) `
                -TimeoutSeconds $capSeconds
            $started = [bool]$result.Started
            $evidence.exitCode        = [int]$result.ExitCode
            $evidence.drainTimedOut   = [bool]$result['DrainTimedOut']
            $evidence.outputTruncated = [bool]$result['OutputTruncated']
            $facts = ConvertFrom-HyperVProbeOutput -Text ([string]$result.StdOut)
            if ($facts.ContainsKey('service')) { $evidence.serviceStatus = ConvertTo-HyperVServiceToken -Value $facts['service'] }
            if ($facts.ContainsKey('start')) { $evidence.serviceStartType = ConvertTo-HyperVStartTypeToken -Value $facts['start'] }
            if ($facts.ContainsKey('module')) { $evidence.providerModule = if ($facts['module'] -eq 'loaded') { 'loaded' } else { 'missing' } }
            $diagnostic = [string]$result.StdErr
            if (-not $started) { $reason = 'missing-client'; break }
            if ($result.TimedOut) {
                $reason = 'timeout'; $timedOut = $true
                # Only a child that had already loaded the Hyper-V module was
                # waiting on VMMS itself. A slow pwsh start, service query or
                # first module load says nothing about VMMS, so a timeout that
                # never got that far is not evidence it is hung.
                if ($facts['module'] -eq 'loaded') { $state = 'Unresponsive' }
                break
            }
            if (-not (Test-DriverNativeResultComplete -Result $result)) { $reason = 'invalid-response'; break }
            # The feature probe explains the unhealthy exits; it shares the budget.
            $probeFeature = {
                $featureCap = Get-YurunaDeadlineBoundedSeconds -Deadline $probeDeadline -Ceiling 120
                if ($null -eq $featureCap) { return $false }
                $feature = Get-HyperVFeatureState -TimeoutSeconds $featureCap
                $evidence.featureState = [string]$feature.State
                $evidence.featureProbe = if ($feature.Probe -eq 'unknown-to-sku') { 'ok' } else { [string]$feature.Probe }
                return $true
            }
            switch ([int]$result.ExitCode) {
                0 {
                    if ($facts['provider'] -eq 'ok') { $state = 'Responsive'; $reason = 'responsive' }
                    else { $reason = 'invalid-response' }
                }
                2 {
                    $evidence.serviceStatus = 'Missing'
                    $null = & $probeFeature
                    $reason = 'missing-client'
                }
                3 {
                    $evidence.providerModule = 'missing'
                    $null = & $probeFeature
                    $reason = 'missing-client'
                }
                4 {
                    $category = [string]$facts['error-category']
                    if ($category -eq 'PermissionDenied' -or $diagnostic -match '(?i)access is denied|required permission|not authorized') { $reason = 'permission-denied' }
                    else { $reason = 'provider-error' }
                }
                5 {
                    if ($evidence.serviceStatus -ne 'Stopped') { $reason = 'provider-error'; break }
                    if (-not (& $probeFeature)) { $reason = 'deadline-exhausted'; $deadlineExhausted = $true; break }
                    if ($evidence.featureState -eq 'Enabled') { $state = 'Unresponsive'; $reason = 'app-stopped' }
                    elseif ($evidence.featureState -in @('Disabled', 'DisablePending', 'EnablePending', 'Unavailable')) { $reason = 'missing-client' }
                    elseif ($evidence.featureProbe -eq 'not-elevated') { $reason = 'permission-denied' }
                    else { $reason = 'provider-error' }
                }
                6 { $reason = 'provider-error' }
                default { $reason = 'invalid-response' }
            }
        } while ($false)
    } catch {
        # The record is the contract: an unexpected fault (under a caller's
        # ErrorActionPreference of Stop any non-terminating error is one)
        # becomes an Undetermined answer, which authorizes nothing.
        $state = 'Undetermined'; $reason = 'provider-error'
        $diagnostic = "$diagnostic $($_.Exception.Message)"
    }
    return New-HyperVVirtualizationProbeRecord -State $state -Reason $reason -Started $started -TimedOut $timedOut `
        -DeadlineExhausted $deadlineExhausted -ObservedUtc $observedUtc -ObservedTick ([long](& $clock)) `
        -ElapsedMs $stopwatch.ElapsedMilliseconds -Evidence $evidence -Diagnostic $diagnostic
}

<#
.SYNOPSIS
    Build one Yuruna.VirtualizationProbe record (schema version 1).
.DESCRIPTION
    Every return path of the probe goes through here so the record always has
    every field and every evidence key, whichever branch produced it.
#>
function New-HyperVVirtualizationProbeRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [bool]$Started,
        [bool]$TimedOut,
        [bool]$DeadlineExhausted,
        [Parameter(Mandatory)][string]$ObservedUtc,
        [long]$ObservedTick,
        [long]$ElapsedMs,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,
        [AllowEmptyString()][string]$Diagnostic = ''
    )
    $arguments = @{} + $PSBoundParameters
    $arguments['Diagnostic'] = Format-VirtualizationProbeDiagnostic -Text $Diagnostic
    New-YurunaVirtualizationProbeRecord @arguments -HostType (Resolve-HostTag)
}

# See https://yuruna.link/42e220c4-0004
$script:HyperVProbeScript = @'
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    function Write-ProbeFact([string]$Name, [string]$Value) { [Console]::Out.WriteLine('yuruna-probe ' + $Name + '=' + $Value) }
    try {
        $service = Get-Service -Name 'vmms' -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            Write-ProbeFact 'service' 'Missing'
            exit 2
        }
        Write-ProbeFact 'service' 'Unknown'
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 6
    }
    Write-ProbeFact 'service' ([string]$service.Status)
    Write-ProbeFact 'start' ([string]$service.StartType)
    if ([string]$service.Status -ne 'Running') { exit 5 }
    try {
        Import-Module Hyper-V -ErrorAction Stop
    } catch {
        Write-ProbeFact 'module' 'missing'
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 3
    }
    Write-ProbeFact 'module' 'loaded'
    try {
        $null = Hyper-V\Get-VM -ErrorAction Stop
    } catch {
        Write-ProbeFact 'error-category' ([string]$_.CategoryInfo.Category)
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 4
    }
    Write-ProbeFact 'provider' 'ok'
    exit 0
'@
$script:HyperVServiceScript = @'
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        $service = Get-Service -Name 'vmms' -ErrorAction Stop
    } catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            [Console]::Out.WriteLine('yuruna-probe service=Missing')
            exit 2
        }
        [Console]::Out.WriteLine('yuruna-probe service=Unknown')
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 6
    }
    [Console]::Out.WriteLine('yuruna-probe service=' + [string]$service.Status)
    [Console]::Out.WriteLine('yuruna-probe start=' + [string]$service.StartType)
    exit 0
'@
$script:HyperVStartScript = @'
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        Start-Service -Name vmms -ErrorAction Stop -WarningAction SilentlyContinue
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
    exit 0
'@
# Tokens the probe and rung 2 accept from the child; anything else is Unknown.
$script:HyperVServiceStatusToken = @('Running', 'Stopped', 'StartPending', 'StopPending', 'ContinuePending', 'PausePending', 'Paused', 'Missing', 'Unknown')
$script:HyperVStartTypeToken = @('Boot', 'System', 'Automatic', 'Manual', 'Disabled')

<#
.SYNOPSIS
    Parse the `yuruna-probe <key>=<token>` lines a child script printed into a
    hashtable; any other line is ignored.
#>
function ConvertFrom-HyperVProbeOutput {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $facts = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $facts }
    foreach ($line in ($Text -split '\r?\n')) {
        $m = [regex]::Match($line.Trim(), '^yuruna-probe (?<key>[a-z-]+)=(?<value>\S+)$')
        if ($m.Success) { $facts[$m.Groups['key'].Value] = $m.Groups['value'].Value }
    }
    return $facts
}

<#
.SYNOPSIS
    Map a child-reported service status to its token, or 'Unknown'.
#>
function ConvertTo-HyperVServiceToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $match = @($script:HyperVServiceStatusToken | Where-Object { $_ -ceq $Value }) | Select-Object -First 1
    if ($match) { return [string]$match }
    return 'Unknown'
}

<#
.SYNOPSIS
    Map a child-reported service start type to its token, or 'Unknown'.
#>
function ConvertTo-HyperVStartTypeToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $match = @($script:HyperVStartTypeToken | Where-Object { $_ -ceq $Value }) | Select-Object -First 1
    if ($match) { return [string]$match }
    return 'Unknown'
}

<#
.SYNOPSIS
    $true when a bounded-command result is a complete answer: the process
    launched and none of TimedOut, DrainTimedOut, OutputTruncated or KillFailed
    is set. A missing key counts as not set.
.DESCRIPTION
    An exit code read from an incomplete result can describe a process whose
    output was cut, so nothing positive (responsive, absent, stopped) is ever
    concluded from one.
#>
function Test-DriverNativeResultComplete {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Result)
    return (Test-BoundedNativeResultComplete -Result $Result)
}

<#
.SYNOPSIS
    Reduce captured native output to a single private diagnostic line of at most
    1024 characters, with ANSI sequences and control characters removed.
.DESCRIPTION
    The probe record carries this for the worker's private log only. Stripping
    control characters keeps a hostile or garbled tool from writing terminal
    escapes or forged log lines through it.
#>
function Format-VirtualizationProbeDiagnostic {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    return (Format-YurunaVirtualizationProbeDiagnostic @PSBoundParameters)
}

<#
.SYNOPSIS
    Read the Microsoft-Hyper-V-All feature state through a bounded dism.exe
    call, keeping a failed query apart from a feature that is not enabled.
.DESCRIPTION
    Runs `dism.exe /English /Online /Get-FeatureInfo
    /FeatureName:Microsoft-Hyper-V-All` from %WINDIR%\System32 (C:\Windows when
    WINDIR is unset) under Invoke-BoundedNativeCommand. /English keeps the
    'State :' label and values parseable on any display language. The whole
    value after 'State :' is read, so 'Enable Pending' is not mistaken for
    'Enable'.

    State: Enabled | Disabled (including 'Disabled with Payload Removed') |
    EnablePending | DisablePending | Unavailable (the edition does not carry the
    feature) | Unknown.
    Probe: ok | timeout | not-elevated (exit 740 or the elevation wording) |
    missing-client (dism.exe not launchable) | provider-error | invalid-response
    (output not drained, truncated, or with no recognizable state) |
    unknown-to-sku (0x800f080c: the feature does not exist on this edition).
    Output is the raw captured text, capped, for a private log only.
.PARAMETER TimeoutSeconds
    Cap for the dism.exe call.
.OUTPUTS
    [pscustomobject] @{ State; Probe; ExitCode; ElapsedMs; Output; Path }
#>
function Get-HyperVFeatureState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateRange(1, 600)][int]$TimeoutSeconds = 120)
    $windowsRoot = if ($env:WINDIR) { $env:WINDIR } else { 'C:\Windows' }
    $dismExe = [IO.Path]::Combine($windowsRoot, 'System32', 'dism.exe')
    $result = Invoke-BoundedNativeCommand -FilePath $dismExe `
        -ArgumentList @('/English', '/Online', '/Get-FeatureInfo', '/FeatureName:Microsoft-Hyper-V-All') `
        -TimeoutSeconds $TimeoutSeconds
    $text = "$($result.StdOut)`n$($result.StdErr)".Trim()
    if ($text.Length -gt 8192) { $text = $text.Substring(0, 8192) }
    $emit = {
        param([string]$State, [string]$Probe)
        [pscustomobject]@{
            State = $State; Probe = $Probe; ExitCode = [int]$result.ExitCode
            ElapsedMs = [long]$result['ElapsedMs']; Output = $text; Path = $dismExe
        }
    }
    if (-not $result.Started) { return (& $emit 'Unknown' 'missing-client') }
    if ($result.TimedOut) { return (& $emit 'Unknown' 'timeout') }
    if (-not (Test-DriverNativeResultComplete -Result $result)) { return (& $emit 'Unknown' 'invalid-response') }
    if ($text -match '(?i)0x800f080c|Feature name .* is unknown') { return (& $emit 'Unavailable' 'unknown-to-sku') }
    if ($result.ExitCode -eq 740 -or $text -match '(?i)Elevated permissions are required') { return (& $emit 'Unknown' 'not-elevated') }
    if ($result.ExitCode -ne 0) { return (& $emit 'Unknown' 'provider-error') }
    $value = $null
    foreach ($line in ([string]$result.StdOut -split '\r?\n')) {
        $m = [regex]::Match($line, '^\s*State\s*:\s*(?<value>.+?)\s*$')
        if ($m.Success) { $value = $m.Groups['value'].Value; break }
    }
    if ($null -eq $value) { return (& $emit 'Unknown' 'invalid-response') }
    switch -Regex ($value) {
        '^Enabled$'         { return (& $emit 'Enabled' 'ok') }
        '^Enable Pending$'  { return (& $emit 'EnablePending' 'ok') }
        '^Disable Pending$' { return (& $emit 'DisablePending' 'ok') }
        '^Disabled\b'       { return (& $emit 'Disabled' 'ok') }
    }
    return (& $emit 'Unknown' 'invalid-response')
}

<#
.SYNOPSIS
    Read the vmms service status and start type in a bounded child process.
.DESCRIPTION
    Get-Service against a wedged Service Control Manager has no timeout of its
    own, so the read runs in a child pwsh under Invoke-BoundedNativeCommand.
    Status is one of Running, Stopped, StartPending, StopPending,
    ContinuePending, PausePending, Paused, Missing (vmms is not installed) or
    Unknown (anything that is not a complete answer). StartType is Boot, System,
    Automatic, Manual, Disabled or Unknown.
.PARAMETER TimeoutSeconds
    Cap for the child process.
.OUTPUTS
    [pscustomobject] @{ Status; StartType; TimedOut; Started; ExitCode; ElapsedMs }
#>
function Get-HyperVServiceEvidence {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateRange(1, 600)][int]$TimeoutSeconds = 15)
    $result = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) `
        -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script:HyperVServiceScript) `
        -TimeoutSeconds $TimeoutSeconds
    $status = 'Unknown'
    $startType = 'Unknown'
    if ((Test-DriverNativeResultComplete -Result $result) -and $result.ExitCode -in @(0, 2)) {
        $facts = ConvertFrom-HyperVProbeOutput -Text ([string]$result.StdOut)
        $status = ConvertTo-HyperVServiceToken -Value ([string]$facts['service'])
        if ($result.ExitCode -eq 2 -and $status -ne 'Missing') { $status = 'Unknown' }
        if ($result.ExitCode -eq 0 -and $status -eq 'Missing') { $status = 'Unknown' }
        $startType = ConvertTo-HyperVStartTypeToken -Value ([string]$facts['start'])
    }
    return [pscustomobject]@{
        Status    = $status
        StartType = $startType
        TimedOut  = [bool]$result.TimedOut
        Started   = [bool]$result.Started
        ExitCode  = [int]$result.ExitCode
        ElapsedMs = [long]$result['ElapsedMs']
    }
}

<#
.SYNOPSIS
    Build one action row of a Yuruna.VirtualizationStartResult.
#>
function New-VirtualizationStartAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('unit-start', 'service-start', 'network-start', 'wait', 'app-launch')][string]$Kind,
        [AllowEmptyString()][string]$Before = '',
        [AllowEmptyString()][string]$After = '',
        [Parameter(Mandatory)][ValidateSet('started', 'already-running', 'socket-live', 'refused', 'failed', 'unknown', 'skipped', 'preview')][string]$Result,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyCollection()][string[]]$Command = @(),
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [bool]$TimedOut = $false,
        [long]$ElapsedMs = 0
    )
    return (New-YurunaVirtualizationStartAction @PSBoundParameters)
}

<#
.SYNOPSIS
    Build a Yuruna.VirtualizationStartResult (schema version 1), deriving the
    outcome from the actions unless one is given.
.DESCRIPTION
    Derived precedence: any failed action -> failed; else any unknown ->
    unknown; else any started -> started; else any preview -> preview; else
    already-running. The reason is the first matching action's reason.
#>
function New-VirtualizationStartResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('started', 'already-running', 'refused', 'failed', 'unknown', 'unavailable', 'preview', '')][string]$Outcome = '',
        [AllowEmptyString()][string]$Reason = '',
        [Parameter(Mandatory)][string]$Layout,
        [AllowEmptyCollection()][object[]]$Action = @(),
        [Parameter(Mandatory)][string]$ObservedUtc,
        [long]$ElapsedMs
    )
    return (New-YurunaVirtualizationStartResult @PSBoundParameters -HostType (Resolve-HostTag))
}

<#
.SYNOPSIS
    Poll vmms through a pending state until it reports Running or the wait
    runs out; returns the last evidence read.
.DESCRIPTION
    Polls every two seconds for at most min(MaximumSeconds, the budget's
    remaining time), each read capped at min(remaining, 15) seconds.
#>
function Wait-HyperVServicePendingState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Budget,
        [Parameter(Mandatory)]$Evidence,
        [ValidateRange(1, 600)][int]$MaximumSeconds = 30
    )
    $clock = if ($Budget.ClockTicks) { $Budget.ClockTicks } else { { [Environment]::TickCount64 } }
    $wait = New-YurunaDeadlineFromExpiry -ExpiryTick ([Math]::Min([long](& $clock) + [long]$MaximumSeconds * 1000, [long]$Budget.ExpiryTick)) -ClockTicks $clock
    $last = $Evidence
    while ($last.Status -in @('StartPending', 'ContinuePending')) {
        $remaining = Get-YurunaDeadlineRemainingMs -Deadline $wait
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Min(2000, $remaining))
        $readCap = Get-YurunaDeadlineBoundedSeconds -Deadline $wait -Ceiling 15
        if ($null -eq $readCap) { break }
        $last = Get-HyperVServiceEvidence -TimeoutSeconds $readCap
    }
    return $last
}

# --- REGION: Start-VirtualizationServiceIfStopped
function Start-VirtualizationServiceIfStopped {
    <#
    .SYNOPSIS
        Start the Hyper-V Virtual Machine Management service (vmms) only when this
        function positively observes it Stopped and the process is elevated;
        refuse on anything it cannot establish. Returns a
        Yuruna.VirtualizationStartResult.
    .DESCRIPTION
        Runs its own bounded detection (Get-HyperVServiceEvidence) immediately
        before acting and never trusts an earlier probe:
          * status Unknown or a timed-out read     -> refused/service-state-unknown
          * vmms not installed                     -> refused/service-missing, with
                                                      the DISM feature state in the
                                                      action's 'before'
          * Running                                -> already-running
          * start type Disabled                    -> refused/service-disabled (an
                                                      operator's choice)
          * StopPending                            -> refused/pending-stop: something
                                                      is deliberately stopping it
          * Paused or PausePending                 -> refused/service-paused
          * StartPending or ContinuePending        -> a bounded wait; Running gives
                                                      already-running, otherwise
                                                      refused/pending-timeout
          * Stopped                                -> start, when elevated; otherwise
                                                      refused/not-elevated (no
                                                      relaunch is attempted)
        The start runs `Start-Service -Name vmms` in a bounded child and is
        confirmed by a fresh read: Running is 'started'; a start still pending gets
        the bounded wait; anything else is failed/start-failed after a failing
        child, unknown/start-timed-out after a timeout, or
        unknown/postcondition-unknown.

        -WhatIf runs only the read-only detection and reports the planned start as
        'preview'. Every child is capped by the remaining time of
        min(TimeoutSeconds, -Deadline); with less than one second left nothing is
        launched. -DependentVMName is accepted for contract parity and not used:
        Hyper-V needs no per-guest network start here. Never throws and never
        prompts.
    .PARAMETER TimeoutSeconds
        Upper bound for the whole call.
    .PARAMETER Deadline
        Optional shared deadline; the call never outlives it.
    .PARAMETER DependentVMName
        Guests whose restoration depends on this hypervisor (not used on Hyper-V).
    .OUTPUTS
        [pscustomobject] Yuruna.VirtualizationStartResult
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'DependentVMName',
        Justification = 'Declared by the host contract on every driver; Hyper-V has no per-guest network to start.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        [object]$Deadline,
        [AllowEmptyCollection()][string[]]$DependentVMName = @()
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $clock = if ($null -ne $Deadline -and $Deadline.ClockTicks) { $Deadline.ClockTicks } else { { [Environment]::TickCount64 } }
    $expiry = [long](& $clock) + [long]$TimeoutSeconds * 1000
    if ($null -ne $Deadline) { $expiry = [Math]::Min($expiry, [long]$Deadline.ExpiryTick) }
    $budget = New-YurunaDeadlineFromExpiry -ExpiryTick $expiry -ClockTicks $clock
    $actions = [System.Collections.Generic.List[object]]::new()
    $finish = {
        param([string]$Outcome, [string]$Reason)
        New-VirtualizationStartResult -Outcome $Outcome -Reason $Reason -Layout 'not-applicable' -Action $actions.ToArray() `
            -ObservedUtc $observedUtc -ElapsedMs $stopwatch.ElapsedMilliseconds
    }
    $refuse = {
        param([string]$Reason, [string]$Before, [string]$Kind = 'service-start')
        $actions.Add((New-VirtualizationStartAction -Target 'vmms' -Kind $Kind -Before $Before -After $Before -Result 'refused' -Reason $Reason))
        & $finish 'refused' $Reason
    }

    $mutated = $false
    try {
        $readCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 15
        if ($null -eq $readCap) { return (& $finish 'refused' 'deadline-exhausted') }
        $service = Get-HyperVServiceEvidence -TimeoutSeconds $readCap
        if ($service.TimedOut -or $service.Status -eq 'Unknown') { return (& $refuse 'service-state-unknown' 'Unknown') }
        if ($service.Status -eq 'Missing') {
            $featureWord = 'NotProbed'
            $featureCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 120
            if ($null -ne $featureCap) { $featureWord = [string](Get-HyperVFeatureState -TimeoutSeconds $featureCap).State }
            return (& $refuse 'service-missing' $featureWord)
        }
        if ($service.Status -eq 'Running') {
            $actions.Add((New-VirtualizationStartAction -Target 'vmms' -Kind 'service-start' -Before 'Running' -After 'Running' -Result 'already-running' -Reason 'already-running'))
            return (& $finish 'already-running' 'already-running')
        }
        if ($service.StartType -eq 'Disabled') { return (& $refuse 'service-disabled' $service.Status) }
        switch ($service.Status) {
            'StopPending' { return (& $refuse 'pending-stop' 'StopPending') }
            { $_ -in @('Paused', 'PausePending') } { return (& $refuse 'service-paused' $service.Status) }
            { $_ -in @('StartPending', 'ContinuePending') } {
                $settled = Wait-HyperVServicePendingState -Budget $budget -Evidence $service
                if ($settled.Status -eq 'Running') {
                    $actions.Add((New-VirtualizationStartAction -Target 'vmms' -Kind 'wait' -Before $service.Status -After 'Running' -Result 'already-running' -Reason 'already-running'))
                    return (& $finish 'already-running' 'already-running')
                }
                return (& $refuse 'pending-timeout' $service.Status 'wait')
            }
            'Stopped' { break }
            default { return (& $refuse 'service-state-unknown' $service.Status) }
        }

        if (-not (Test-IsAdministrator)) { return (& $refuse 'not-elevated' 'Stopped') }
        $startCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 60
        if ($null -eq $startCap) { return (& $refuse 'deadline-exhausted' 'Stopped') }
        $command = @('Start-Service', '-Name', 'vmms')
        if (-not $PSCmdlet.ShouldProcess('vmms', (Format-YurunaOperatorMessage -Key 'host.hyperv_start_vmms_action'))) {
            $actions.Add((New-VirtualizationStartAction -Target 'vmms' -Kind 'service-start' -Before 'Stopped' -Result 'preview' -Reason 'preview' -Command $command))
            return (& $finish 'preview' 'preview')
        }
        $start = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script:HyperVStartScript) `
            -TimeoutSeconds $startCap
        $mutated = [bool]$start.Started
        $common = @{ Target = 'vmms'; Kind = 'service-start'; Before = 'Stopped'; Command = $command
            ExitCode = [int]$start.ExitCode; TimedOut = [bool]$start.TimedOut; ElapsedMs = [long]$start['ElapsedMs'] }
        if (-not $start.Started) {
            $actions.Add((New-VirtualizationStartAction @common -Result 'refused' -Reason 'missing-client'))
            return (& $finish 'refused' 'missing-client')
        }
        $after = [pscustomobject]@{ Status = 'Unknown' }
        $postCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 15
        if ($null -ne $postCap) { $after = Get-HyperVServiceEvidence -TimeoutSeconds $postCap }
        if ($after.Status -in @('StartPending', 'ContinuePending')) { $after = Wait-HyperVServicePendingState -Budget $budget -Evidence $after }
        $afterWord = [string]$after.Status
        if ($afterWord -eq 'Running') {
            $actions.Add((New-VirtualizationStartAction @common -After $afterWord -Result 'started' -Reason 'started'))
        } elseif ($start.TimedOut -or $afterWord -in @('StartPending', 'ContinuePending')) {
            $actions.Add((New-VirtualizationStartAction @common -After $afterWord -Result 'unknown' -Reason 'start-timed-out'))
        } elseif ($start.ExitCode -ne 0) {
            $actions.Add((New-VirtualizationStartAction @common -After $afterWord -Result 'failed' -Reason 'start-failed'))
        } else {
            $actions.Add((New-VirtualizationStartAction @common -After $afterWord -Result 'unknown' -Reason 'postcondition-unknown'))
        }
        return (& $finish '' '')
    } catch {
        # Never throw: under a caller's ErrorActionPreference of Stop any
        # non-terminating error is a throw. After the start child ran its
        # outcome is unknown until a fresh probe; before, nothing changed.
        Write-Verbose "Start-VirtualizationServiceIfStopped: $($_.Exception.Message)"
        if ($mutated) { return (& $finish 'unknown' 'postcondition-unknown') }
        return (& $finish 'refused' 'service-state-unknown')
    }
}

function Get-YurunaVMAccountSid {
    <#
    .SYNOPSIS
        The SID of a virtual machine's own virtual account, computed from its id.
    .DESCRIPTION
        Windows gives each VM an account under the NT VIRTUAL MACHINE authority,
        and its SID is derived from the machine's GUID: S-1-5-83-1 followed by
        the GUID's sixteen bytes read as four little-endian unsigned 32-bit
        values. Computing it is exact and needs nothing from the machine.

        The alternative -- asking Windows to translate the account NAME -- is
        what this replaces. "NT VIRTUAL MACHINE" is a display name, and Windows
        localizes it, so on a host installed in another language the lookup
        throws, the caller cannot prove which entries are stale, and it skips
        the cleanup entirely. That direction is safe, which is why nobody
        noticed: the cleanup simply stopped happening, one warning at a time.
    .OUTPUTS
        System.String -- the SID in its S-1-5-... string form.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][guid]$VMId)

    $bytes = $VMId.ToByteArray()
    $parts = for ($i = 0; $i -lt 16; $i += 4) { [System.BitConverter]::ToUInt32($bytes, $i) }
    return 'S-1-5-83-1-' + ($parts -join '-')
}

function Remove-OrphanedVMFileAccess {
    <#
    .SYNOPSIS
        Strip stale per-VM access ACEs from a file's ACL, keeping only the
        ACEs of VMs that still exist. Returns the number removed.
    .DESCRIPTION
        Guards against Hyper-V shared-image DACL bloat: each attach appends a
        per-VM ACE (SID family S-1-5-83-1-*) that Remove-VM never revokes,
        until the ~64 KB DACL cap fails the next attach with 0x8007053C /
        0x80070005 regardless of caller elevation. Only stale per-VM ACEs are
        removed -- inherited ACEs, admin/SYSTEM, the all-VMs group
        (S-1-5-83-0), capability SIDs, and live VMs' own ACEs stay, so it is
        safe to run while other VMs use the file. Set-Acl writes a SMALLER
        descriptor, so it succeeds even when the on-disk ACL is already at
        the limit. See https://yuruna.link/429f3d06-0093
    .OUTPUTS
        System.Int32 -- the number of stale per-VM ACEs removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Path)

    if (-not $IsWindows) { return 0 }
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }

    # A specific VM's virtual account is S-1-5-83-1-<RID derived from its
    # GUID>; the all-VMs group is S-1-5-83-0 and must be preserved.
    $perVmSidPrefix = 'S-1-5-83-1-'

    # Live set: translate each existing VM's virtual-account name to its SID.
    # If ANY translation fails we cannot prove which ACEs are stale, so we
    # abort rather than risk purging a live VM's access.
    $liveSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($vm in (Hyper-V\Get-VM -ErrorAction Stop)) {
            [void]$liveSids.Add((Get-YurunaVMAccountSid -VMId $vm.Id))
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_710526e17721aa1a' -Arguments @{ message = "$($_.Exception.Message)"; path = "$Path" })
        return 0
    }

    $acl = Get-Acl -LiteralPath $Path
    $staleSids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rule in $acl.Access) {
        if ($rule.IsInherited) { continue }
        # Normalize to a SID string -- the name form for a deleted VM still
        # translates because the SID is derived from the GUID, not a lookup.
        $sidVal = $null
        try {
            $sidVal = if ($rule.IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
                $rule.IdentityReference.Value
            } else {
                $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
        } catch { continue }   # un-translatable, non-VM principal -- leave it
        if ($sidVal -like "$perVmSidPrefix*" -and -not $liveSids.Contains($sidVal)) {
            [void]$staleSids.Add($sidVal)
        }
    }

    if ($staleSids.Count -eq 0) { return 0 }

    if ($PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'host.operator_02eff2d9f27b202c' -Arguments @{ count = "$($staleSids.Count)" }))) {
        foreach ($s in $staleSids) {
            # Purge by SID so both stored forms (raw SID and resolved
            # NT VIRTUAL MACHINE\<guid> name) for that account are removed.
            $acl.PurgeAccessRules([System.Security.Principal.SecurityIdentifier]$s)
        }
        try {
            Set-Acl -LiteralPath $Path -AclObject $acl
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_379851375f35c850' -Arguments @{ path = "$Path"; message = "$($_.Exception.Message)" })
            return 0
        }
    }
    return $staleSids.Count
}

function Disable-HyperVHeartbeatForLinuxGuest {
    <#
    .SYNOPSIS
        Turn the Heartbeat integration service off for a Linux guest on an
        ARM64 host. No-op on AMD64.
    .DESCRIPTION
        Disabling Heartbeat helped Linux guests pass early boot stalls on the
        ARM64 lab host. Affected boots reported soft lockups in the shared
        VMBus hypercall path and stopped near these utility-driver messages:

            hv_utils: Heartbeat IC version 3.0
            hv_utils: Shutdown IC version 3.2
            hv_utils: TimeSync IC version 4.0

        The workaround remains without attributing every VMBus
        stall to Heartbeat. Storage requests share the hypercall path, and
        timer-related overhead can persist with Heartbeat already disabled.
        AMD64 is untouched. Callers gate Linux guest selection because this
        function checks host architecture, not the guest operating system.

        Nothing in the harness depends on the Hyper-V heartbeat. Only
        guest.caching-proxy-service/New-VM.ps1 reads it, as one line of a
        readiness summary, and Get-VMIp resolves addresses through KVP and ARP
        -- neither of which this touches.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)

    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.operator_ce28ce6cce0e7f70'))) { return $false }
    try {
        $null = Invoke-HyperVLifecycleCmdlet -Verb 'Disable-VMIntegrationService' -VMName $VMName -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            Disable-VMIntegrationService -VMName $Name -Name 'Heartbeat' -ErrorAction Stop
        }
        Write-Verbose "Heartbeat integration service disabled for '$VMName' (ARM64 Linux guest boot workaround)."
        return $true
    } catch {
        # A guest that boots anyway is the good case, and one that wedges
        # reports it as its own boot failure with the console signature above.
        # Neither is worth failing VM creation over.
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8107fa04808ac8e9' -Arguments @{ vMName = "$VMName"; message = "$($_.Exception.Message)" })
        return $false
    }
}

function Limit-HyperVLinuxGuestCoreCount {
    <#
    .SYNOPSIS
        Cap the vCPU count of a Linux guest on an ARM64 host. No-op on AMD64.
    .DESCRIPTION
        Stock Ubuntu's architectural timer produced high interrupt overhead on
        the affected ARM64 Hyper-V host. A controlled 12 GB installer comparison
        reached its confirmation prompt in about 115 seconds with one processor
        and 554-564 seconds with two; another two-processor run was still making
        progress at the 600-second observation limit. These are serial boot
        measurements, not a general estimate of multicore workload capacity.

        A same-kernel clockevent control isolated substantial overhead to the
        architectural timer path. This conservative cap remains useful for
        stock guests until a replacement kernel passes installed-system tests.

        The default cap is two because kubeadm's preflight check refuses to
        initialize a control plane on a single processor, and the guests this
        applies to go on to run one. A provisioning caller may select a lower
        temporary cap when its sequence includes an explicit, offline transition
        back to two before kubeadm starts.

        Explicit requests are also capped so callers share the same provisioning
        policy on affected ARM64 hosts.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$RequestedCores,
        [int]$MaximumCores = 2
    )

    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
        return $RequestedCores
    }
    if ($RequestedCores -le $MaximumCores) { return $RequestedCores }
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_c9cdde915a1c6b17' -Arguments @{ maximumCores = "$MaximumCores"; requestedCores = "$RequestedCores" })
    return $MaximumCores
}

function Set-HyperVArm64LinuxGuestProcessorCount {
    <#
    .SYNOPSIS
        Set the post-provisioning processor count of a stopped ARM64 Linux VM.
    .DESCRIPTION
        The Ubuntu ARM64 installer and package-update path is fastest with one
        virtual processor on affected Hyper-V hosts, while kubeadm requires two.
        This helper performs the offline transition between those phases. It is
        deliberately a no-op on AMD64 so the shared Ubuntu sequence preserves
        the normal host-sizing policy there.
    .OUTPUTS
        [bool] true when the requested state is established (or is not needed
        on this architecture); false when the VM is absent, not stopped, or the
        Hyper-V update cannot be confirmed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][ValidateRange(1, 1024)][int]$Count
    )

    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [System.Runtime.InteropServices.Architecture]::Arm64) {
        return $true
    }
    $resolved = Resolve-HyperVVM -VMName $VMName
    if ($resolved.Presence -ne 'present' -or [string]$resolved.VM.State -ne 'Off') {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($VMName)) {
        return $false
    }
    try {
        $processor = Invoke-HyperVLifecycleCmdlet -Verb 'Set-VMProcessor' -VMName $VMName -ArgumentList @($VMName, $Count) -ScriptBlock {
            param($VMName, $Count)
            Hyper-V\Set-VMProcessor -VMName $VMName -Count $Count -ErrorAction Stop
            Hyper-V\Get-VMProcessor -VMName $VMName -ErrorAction Stop
        } | Select-Object -First 1
        return ([int]$processor.Count -eq $Count)
    } catch {
        Write-Verbose "Set-HyperVArm64LinuxGuestProcessorCount: $($_.Exception.Message)"
        return $false
    }
}
