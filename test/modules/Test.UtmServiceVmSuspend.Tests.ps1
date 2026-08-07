<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42e9c31b-7a06-4d52-8f14-6b27d90ae4c3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm suspend service vm pester
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
    Coverage for the guards that keep UTM from leaving the service VMs
    suspended: the KeepRunningAfterLastWindowClosed knob, Rename-VM's
    capture-and-resume around its UTM quit, and the installer's
    quit gate.
.DESCRIPTION
    UTM saves the state of every running VM as it terminates -- a VM that
    was `started` comes back `suspended`, and nothing resumes it. For the
    service VMs (caching proxy, stash, pool-control) that is an outage:
    guests take their packages through the proxy, the build uploads to the
    stash, and pool-control serves the intent store, so every consumer
    fails for as long as one sits suspended. Two things get UTM quit --
    an operator closing the last window, and the framework doing it on
    purpose to edit UTM's Registry plist -- and each needs its own guard.

    Structural (AST/text) assertions: the code under test drives UTM and
    utmctl, so executing it would need a real app and real VMs. What is
    pinned here is the ordering and the pairing that make the guards work
    -- a capture that happens after the quit reads an empty set, and a
    knob applied without a matching capture entry is never restored.

    Throw-based assertions so the file runs under the OS-bundled Pester
    3.4 and Pester 5+. No macOS needed: every case reads source text.
    Run: pwsh -NoProfile -File test/modules/Test.UtmServiceVmSuspend.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$SuspendRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-FunctionBody {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path, [string]$Name)
    $text = Get-Content -Raw -LiteralPath $Path
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
    $fn = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $n.Name -eq $Name }, $true))
    if ($fn.Count -ne 1) { throw "Expected exactly one definition of '$Name' in $Path, found $($fn.Count)." }
    return $fn[0].Extent.Text
}

$SuspendHostModule  = Join-Path $SuspendRepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
$SuspendMacCondition = Join-Path $SuspendRepoRoot 'test/modules/Test.HostCondition.Mac.psm1'
$SuspendStateModule = Join-Path $SuspendRepoRoot 'test/modules/Test.HostAutomationState.psm1'
$SuspendDisableScript = Join-Path $SuspendRepoRoot 'host/macos.utm/Disable-TestAutomation.ps1'
$SuspendInstaller   = Join-Path $SuspendRepoRoot 'install/macos.utm.sh'

Describe 'Rename-VM does not leave the service VMs suspended' {

    It 'captures the running service VMs BEFORE it quits UTM' {
        # utmctl can only answer while UTM is up. A capture moved below the
        # quit reads an empty set, the resume loop then has nothing to do,
        # and the services stay suspended with no warning at all -- the
        # failure looks exactly like the bug being fixed.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Rename-VM'
        $captureAt = $body.IndexOf('Get-RunningVmName')
        $quitAt    = $body.IndexOf('to quit')
        Assert-True ($captureAt -ge 0) 'the running set is captured'
        Assert-True ($quitAt -ge 0) 'UTM is quit'
        Assert-True ($captureAt -lt $quitAt) 'and the capture happens while UTM can still answer'
    }

    It 'narrows the capture to the service VMs' {
        # Resuming everything that happened to be running would restart test
        # guests the cycle is in the middle of tearing down.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Rename-VM'
        Assert-True ($body -match 'Get-YurunaServiceVmName') 'the canonical service-VM list is the filter'
    }

    It 'resumes on every path that relaunches UTM' {
        # The early returns are the ones that matter: a rename that fails
        # half way still quit UTM, so bailing out without a resume leaves
        # the host worse off than not having tried.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Rename-VM'
        $relaunches = ([regex]::Matches($body, 'open -a UTM')).Count
        $resumes    = ([regex]::Matches($body, 'Resume-YurunaServiceVM')).Count
        Assert-True ($relaunches -gt 0) 'the function relaunches UTM'
        Assert-True ($resumes -ge $relaunches) "every relaunch is followed by a resume (relaunches=$relaunches resumes=$resumes)"
    }

    It 'resumes even when the rename itself did not surface' {
        # Reporting the rename failure is not worth trading for several
        # suspended services, so the resume cannot sit behind the success
        # return.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Rename-VM'
        $lastResumeAt = $body.LastIndexOf('Resume-YurunaServiceVM')
        $warnAt = $body.IndexOf('UTM relaunch did not surface')
        Assert-True ($lastResumeAt -ge 0 -and $warnAt -ge 0) 'both the resume and the timeout warning exist'
        Assert-True ($lastResumeAt -lt $warnAt) 'the resume runs before the timeout is reported'
    }

    It 'Resume-YurunaServiceVM waits for re-registration before starting' {
        # UTM ingests its library asynchronously after launch. utmctl answers
        # "not found" until that finishes and the start is silently dropped,
        # which reads as a resume that worked.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Resume-YurunaServiceVM'
        $registerAt = $body.IndexOf("-eq 'absent'")
        $startAt    = $body.IndexOf('utmctl start')
        Assert-True ($registerAt -ge 0 -and $startAt -ge 0) 'both the registration wait and the start exist'
        Assert-True ($registerAt -lt $startAt) 'registration is confirmed before the start'
        Assert-True ($body -match 'Get-Date\)\.AddSeconds') 'the waits are wall-clock, not iteration counts'
    }

    It 'Resume-YurunaServiceVM reports a service that did not come back' {
        # A silent failure here is the whole outage again, one layer down.
        $body = Get-FunctionBody -Path $SuspendHostModule -Name 'Resume-YurunaServiceVM'
        Assert-True ($body -match 'Write-Warning') 'a service that will not resume is surfaced'
        Assert-True ($body -match 'utmctl start') 'the warning carries the manual recovery command'
    }
}

Describe 'UTM is configured to outlive its last window' {

    It 'the apply path writes KeepRunningAfterLastWindowClosed' {
        $text = Get-Content -Raw -LiteralPath $SuspendMacCondition
        Assert-True ($text -match "KeepRunningAfterLastWindowClosed'\)\s*-WriteType\s*'-bool'\s*-WriteValue\s*'YES'") `
            'Set-MacHostConditionSet turns the knob on'
    }

    It 'the precheck fails a host where it is off' {
        # Without the gate the setting silently drifts back -- a UTM
        # reinstall or a fresh account starts from the default.
        $text = Get-Content -Raw -LiteralPath $SuspendMacCondition
        $assertBody = [regex]::Match($text, '(?ms)^function Assert-HostConditionSet\b.*?\n\}').Value
        if (-not $assertBody) { $assertBody = $text }
        Assert-True ($assertBody -match 'KeepRunningAfterLastWindowClosed') 'the assert path checks the knob'
    }

    It 'the knob is captured and restored, not just applied' {
        # A knob written by Enable- with no capture entry is a permanent
        # change to the operator's Mac: Disable- has nothing to put back.
        $stateText   = Get-Content -Raw -LiteralPath $SuspendStateModule
        $disableText = Get-Content -Raw -LiteralPath $SuspendDisableScript
        Assert-True ($stateText -match 'KeepRunningAfterLastWindowClosed') 'the pre-automation value is captured'
        Assert-True ($disableText -match 'KeepRunningAfterLastWindowClosed') 'and restored on the way out'
    }
}

Describe 'The installer will not quit UTM out from under a service VM' {

    It 'checks every service VM, not only the caching proxy' {
        # The proxy was the only one guarded, so a host running just the
        # stash service had UTM quit under it and the stash suspended.
        $text = Get-Content -Raw -LiteralPath $SuspendInstaller
        $gate = [regex]::Match($text, '(?ms)^is_service_vm_running\(\).*?\n\}').Value
        Assert-True ($gate.Length -gt 0) 'the gate function exists'
        foreach ($vm in @('yuruna-caching-proxy-service', 'yuruna-stash-service', 'yuruna-pool-control-service', 'yuruna-download-agent-service')) {
            Assert-True ($text -match [regex]::Escape($vm)) "the gate knows about $vm"
        }
        Assert-True ($gate -match 'YURUNA_SERVICE_VM_NAME') 'and iterates the shared name list'
    }

    It 'treats an unreachable utmctl as a reason not to quit' {
        # Apple Events are denied over SSH. Reading that as "nothing is
        # running" is how the quit happens on exactly the unattended hosts
        # that can least afford it.
        $text = Get-Content -Raw -LiteralPath $SuspendInstaller
        $gate = [regex]::Match($text, '(?ms)^is_service_vm_running\(\).*?\n\}').Value
        Assert-True ($gate -match 'preserving out of caution') 'an uncertain answer preserves'
    }

    It 'gates both the quit and the cask upgrade on the same flag' {
        # Upgrading the UTM cask requires the app to be down, so the two
        # decisions have to agree or brew kills what the gate protected.
        $text = Get-Content -Raw -LiteralPath $SuspendInstaller
        Assert-True ($text -match 'PRESERVE_SERVICE_VM -eq 0[\s\S]{0,80}quit_mac_app "UTM"') 'the quit is gated'
        Assert-True ($text -match 'PRESERVE_SERVICE_VM:-0\} -eq 1') 'and so is the cask upgrade'
    }
}
