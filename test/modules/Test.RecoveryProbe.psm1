<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4251f97d-1a31-47c3-8c4a-f3eb763b242b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery probe failure-pause half-open
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
    The probes the failure pause consults to learn that a host condition the
    cycle reported has cleared.
.DESCRIPTION
    Most failure pauses wait for something an operator does: a commit, a
    configuration edit, a restart request. A host condition can also clear on
    its own -- a hypervisor that answers again, a bridged switch that forwards
    again, a pool share with room again -- and without a probe the runner waits
    out the whole pause after it did. Each registered failure class names how
    often to ask and how long one question may take. The pause asks through
    test/modules/Invoke-RecoveryProbe.ps1 in a short-lived process, because the
    resident runner does not load the host driver or the pool storage modules,
    and a probe that hangs in a driver call must not hang the runner. A cleared
    probe ends the pause through the recovery ledger (end_failure_pause_on_probe
    in Test.RecoveryActions), whose budget bounds how often a condition that
    comes and goes can cut a pause short.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

$script:RecoveryProbe = [ordered]@{}

function Register-RecoveryProbe {
    <#
    .SYNOPSIS
        Register the probe the failure pause runs for a failure class.
    .PARAMETER FailureClass
        The class whose condition the probe checks; the probe script must
        accept it as its -FailureClass.
    .PARAMETER IntervalSeconds
        The least time between two probes in one pause.
    .PARAMETER TimeoutSeconds
        The bound on one probe process, module loading included.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registry mutation in session memory; nothing outside the process changes.')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9_]*$')][string]$FailureClass,
        [Parameter(Mandatory)][ValidateRange(30, 86400)][int]$IntervalSeconds,
        [ValidateRange(5, 900)][int]$TimeoutSeconds = 120
    )
    $script:RecoveryProbe[$FailureClass] = [pscustomobject]@{
        FailureClass = $FailureClass; IntervalSeconds = $IntervalSeconds; TimeoutSeconds = $TimeoutSeconds
    }
}

function Get-RecoveryProbe {
    <#
    .SYNOPSIS
        The probe registered for a failure class, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()][AllowEmptyString()][string]$FailureClass)
    if (-not $FailureClass -or -not $script:RecoveryProbe.Contains($FailureClass)) { return $null }
    return $script:RecoveryProbe[$FailureClass]
}

function Invoke-RecoveryProbe {
    <#
    .SYNOPSIS
        Run the probe registered for a failure class in a short-lived process.
    .DESCRIPTION
        The probe exits 0 when the condition has cleared, 1 when it still holds
        and 2 when it cannot tell. Only a complete run that exited 0 counts as
        cleared: a probe that timed out or could not start proves nothing.
    .PARAMETER FailureClass
        The class to probe.
    .PARAMETER RepoRoot
        The repository whose test/modules/Invoke-RecoveryProbe.ps1 runs.
    .PARAMETER ConfigPath
        The runner configuration the probe reads.
    .PARAMETER Runner
        Test seam: called with FilePath, ArgumentList and TimeoutSeconds in place
        of Invoke-BoundedNativeCommand, and returns its result shape.
    .OUTPUTS
        [pscustomobject] @{ Ran; Cleared; ExitCode; Detail }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$FailureClass,
        [Parameter(Mandatory)][string]$RepoRoot,
        [AllowNull()][AllowEmptyString()][string]$ConfigPath,
        [scriptblock]$Runner
    )
    $probe = Get-RecoveryProbe -FailureClass $FailureClass
    if (-not $probe) { return [pscustomobject]@{ Ran = $false; Cleared = $false; ExitCode = $null; Detail = 'no probe for this class' } }
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', (Join-Path $RepoRoot 'test/modules/Invoke-RecoveryProbe.ps1'), '-FailureClass', $FailureClass)
    if ($ConfigPath) { $arguments += @('-ConfigPath', $ConfigPath) }
    $pwsh = [Environment]::ProcessPath
    $run = $null
    try {
        $run = if ($Runner) { & $Runner $pwsh $arguments $probe.TimeoutSeconds }
            else { Invoke-BoundedNativeCommand -FilePath $pwsh -ArgumentList $arguments -TimeoutSeconds $probe.TimeoutSeconds }
    } catch {
        return [pscustomobject]@{ Ran = $false; Cleared = $false; ExitCode = $null; Detail = "probe could not run: $($_.Exception.Message)" }
    }
    $lines = @(([string]$run.StdOut) -split "`r?`n" | Where-Object { $_.Trim() })
    $detail = if ($lines.Count -gt 0) { $lines[-1].Trim() } else { '' }
    if (-not $run.Started) { return [pscustomobject]@{ Ran = $false; Cleared = $false; ExitCode = $null; Detail = 'probe could not start' } }
    if ($run.TimedOut) { return [pscustomobject]@{ Ran = $true; Cleared = $false; ExitCode = $run.ExitCode; Detail = "probe timed out after $($probe.TimeoutSeconds) s" } }
    return [pscustomobject]@{ Ran = $true; Cleared = ([int]$run.ExitCode -eq 0); ExitCode = [int]$run.ExitCode; Detail = $detail }
}

# The host conditions that clear without anyone acting, and the checks the
# cycle itself uses to raise them; Invoke-RecoveryProbe.ps1 holds the checks.
Register-RecoveryProbe -FailureClass 'hypervisor_unresponsive' -IntervalSeconds 300 -TimeoutSeconds 180
Register-RecoveryProbe -FailureClass 'host_network_degraded' -IntervalSeconds 300 -TimeoutSeconds 180
Register-RecoveryProbe -FailureClass 'pool_storage_full' -IntervalSeconds 600 -TimeoutSeconds 180

Export-ModuleMember -Function Register-RecoveryProbe, Get-RecoveryProbe, Invoke-RecoveryProbe
