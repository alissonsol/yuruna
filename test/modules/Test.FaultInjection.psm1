<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42962532-374f-4dd9-ac02-5dcd939d7a48
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner fault-injection chaos
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
    Named fault points a chaos test can fire inside the composed runner.
.DESCRIPTION
    The runner's recovery mechanisms are unit-tested one at a time with mocks;
    a fault point lets a test drive the real loop -- resident, cycle process,
    inner -- through a fault at a known place and assert where it ends up.

    A point fires only when BOTH hold: YURUNA_FAULT_POINTS names it, and the
    process's runtime folder holds the test-only marker file
    'fault-injection.enabled'. A test creates that marker in its private
    runtime folder; a runner's own runtime folder never has one, so an
    environment variable left behind cannot reach a real cycle. Call sites
    test the variable before anything else, so a process without it pays one
    environment read.

    YURUNA_FAULT_POINTS is a comma-separated list of name[:action] entries.
    Actions: throw (the default) raises 'YurunaFaultInjected: <name>'; exit
    ends the process with code 97; hang sleeps for
    YURUNA_FAULT_HANG_SECONDS (default 3600), with no heartbeat, as a wedged
    call would; kill force-stops the process. Every fired point appends a line
    to <runtime>/fault-injection.log first, so a test can tell which points
    ran, in which process.
#>

# The places a fault can be fired, each named after what it interrupts.
$script:FaultPointName = @(
    'cycle-import',       # the per-cycle process, after its module set loaded
    'inner-import',       # the inner, after its module set loaded
    'before-inner-pid',   # the inner, before it records inner.pid
    'step-heartbeat',     # every step heartbeat write
    'capture',            # Wait-ForText, before each screen capture
    'ocr',                # every OCR provider call
    'ledger-read',        # every recovery ledger read
    'status-write'        # every status.json write
)

function Get-YurunaFaultPointName {
    <#
    .SYNOPSIS
        The names a fault point can be fired by.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return [string[]]@($script:FaultPointName)
}

function Invoke-YurunaFaultPoint {
    <#
    .SYNOPSIS
        Fire the named fault point when a test armed it; otherwise nothing.
    .PARAMETER Name
        One of Get-YurunaFaultPointName.
    .PARAMETER RuntimeDir
        The runtime folder that must hold the marker; YURUNA_RUNTIME_DIR by
        default.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR
    )
    $armed = [string]$env:YURUNA_FAULT_POINTS
    if (-not $armed -or -not $RuntimeDir) { return }
    if (-not [System.IO.File]::Exists((Join-Path $RuntimeDir 'fault-injection.enabled'))) { return }
    $action = $null
    foreach ($entry in $armed.Split(',')) {
        $parts = $entry.Trim().Split(':', 2)
        if ($parts[0] -ceq $Name) { $action = if ($parts.Count -gt 1 -and $parts[1]) { $parts[1] } else { 'throw' }; break }
    }
    if (-not $action) { return }
    try {
        [System.IO.File]::AppendAllText((Join-Path $RuntimeDir 'fault-injection.log'),
            "$([DateTime]::UtcNow.ToString('o')) pid=$PID point=$Name action=$action" + [Environment]::NewLine)
    } catch {
        Write-Verbose "Invoke-YurunaFaultPoint: log unavailable: $($_.Exception.Message)"
    }
    switch -CaseSensitive ($action) {
        'exit' { [Environment]::Exit(97) }
        'kill' { Stop-Process -Id $PID -Force }
        'hang' {
            $seconds = 3600
            if ($env:YURUNA_FAULT_HANG_SECONDS) { $seconds = [int]$env:YURUNA_FAULT_HANG_SECONDS }
            Start-Sleep -Seconds $seconds
        }
        default { throw [System.Management.Automation.RuntimeException]::new("YurunaFaultInjected: $Name") }
    }
}

Export-ModuleMember -Function Get-YurunaFaultPointName, Invoke-YurunaFaultPoint
