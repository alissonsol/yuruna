<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42c12b0b-52ae-4ce9-b731-05621db9391f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence failure-label pester
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
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    Get-SequenceActionFailureLabel hands a FailureLabel closure VMName and
    GuestKey, not only Step/Vars/ExpandVariable.
.DESCRIPTION
    WHY THIS EXISTS. startVm's FailureLabel reads $Context.VMName to name the
    VM a failed start was acting on. Get-SequenceActionFailureLabel built its
    own $ctx hashtable with only Step, Vars and ExpandVariable, so that read
    always answered $null and every startVm failure recorded the unreadable
    `startVm: ""` -- on a pool host, two independent guests failed this way
    the same day and the record named neither VM. networkRelease's label
    reads $Context.GuestKey and had the same gap. Both are fixed by passing
    -VMName/-GuestKey through to the label context; this suite pins the
    parameter contract so a future change to the context shape fails a test
    instead of going blank in a failure record months later.
    Run: Invoke-Pester -Path test/modules/Test.SequenceActionFailureLabel.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    # Registers every built-in verb, including startVm and networkRelease.
    Import-Module (Join-Path $here 'Test.SequenceHandler.psm1') -Force -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
}

Describe 'Get-SequenceActionFailureLabel threads VMName and GuestKey to the closure' {
    It 'passes VMName through, matching the Handler context startVm reads' {
        # A throwaway verb in the in-memory registry; Register-SequenceAction
        # is idempotent by Name, so nothing needs removing afterward.
        Register-SequenceAction -Name 'yurunaTestProbeVmName' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
            -FailureClass 'unknown' -Severity 'soft' `
            -FailureLabel { param($c) "probe: `"$($c.VMName)`"" } `
            -Handler { $true }
        $label = Get-SequenceActionFailureLabel -Step @{ action = 'yurunaTestProbeVmName' } -Vars @{} `
            -ExpandVariable { param($v) $v } -VMName 'test-guest.ubuntu.server.26-01' -GuestKey 'guest.ubuntu.server.26'
        Assert-Equal -Expected 'probe: "test-guest.ubuntu.server.26-01"' -Actual $label
    }

    It 'passes GuestKey through, matching the Handler context networkRelease reads' {
        Register-SequenceAction -Name 'yurunaTestProbeGuestKey' -ReplaySafety 'observe' -HostIORequirement @() -OcrRequired $false `
            -FailureClass 'unknown' -Severity 'soft' `
            -FailureLabel { param($c) "probe: $($c.GuestKey)" } `
            -Handler { $true }
        $label = Get-SequenceActionFailureLabel -Step @{ action = 'yurunaTestProbeGuestKey' } -Vars @{} `
            -ExpandVariable { param($v) $v } -VMName 'test-guest.ubuntu.server.26-01' -GuestKey 'guest.ubuntu.server.26'
        Assert-Equal -Expected 'probe: guest.ubuntu.server.26' -Actual $label
    }

    It 'still renders Step/Vars/ExpandVariable-only labels when VMName and GuestKey are omitted' {
        # Most registered verbs (fetchAndExecute, pressKey, ...) never touch
        # VMName/GuestKey; the new parameters must stay optional for them.
        $label = Get-SequenceActionFailureLabel -Step @{ action = 'pressKey'; name = 'Enter' } -Vars @{} `
            -ExpandVariable { param($v) $v }
        Assert-Equal -Expected 'pressKey: Enter' -Actual $label
    }

    It 'names the VM in a real startVm failure label instead of leaving it blank' {
        $step = @{ action = 'startVm'; timeoutSeconds = 180; description = 'Restore workload processors and start the VM' }
        $label = Get-SequenceActionFailureLabel -Step $step -Vars @{} -ExpandVariable { param($v) $v } `
            -VMName 'test-guest.ubuntu.server.26-01' -GuestKey 'guest.ubuntu.server.26'
        Assert-Equal -Expected 'startVm: "test-guest.ubuntu.server.26-01"' -Actual $label
    }

    It 'names the guest in a real networkRelease failure label instead of leaving it blank' {
        $step = @{ action = 'networkRelease' }
        $label = Get-SequenceActionFailureLabel -Step $step -Vars @{} -ExpandVariable { param($v) $v } `
            -VMName 'test-guest.ubuntu.server.26-01' -GuestKey 'guest.ubuntu.server.26'
        Assert-Equal -Expected 'networkRelease: guest.ubuntu.server.26' -Actual $label
    }
}
