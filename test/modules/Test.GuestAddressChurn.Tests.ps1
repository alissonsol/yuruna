<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42c9d1b7-5e34-4a86-9f02-6b1d7c8e4a55
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp address churn readiness pester
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
    Pester coverage for the two guards against a guest whose address moves while
    it boots: the settle window in Invoke-WaitVmIp, and the re-resolving
    readiness wait in Wait-YurunaServiceVmEndpoint.
.DESCRIPTION
    A guest's DHCP client identity is derived from its machine-id by default, and
    cloud-init changes that mid-boot -- so the guest re-requests, the server sees
    a new client, and it lands on a different address two or three times in the
    first seconds. Both helpers exist to keep a host-side decision from being
    frozen against an address the guest abandoned; these tests drive that churn
    through the helpers' injected resolve/probe/ask hooks, so no VM, no DHCP
    server and no network are needed.

    Everything shared lives in BeforeAll, never at file scope: under Pester 5+ an
    It block cannot see file-scope functions or variables, so a fixture declared
    out there is missing at run time rather than merely stale.
    Run: Invoke-Pester -Path test/modules/Test.GuestAddressChurn.Tests.ps1
#>

BeforeAll {
    $repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    Import-Module (Join-Path $repo 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $repo 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking

    function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
    function Assert-Equal {
        param($Expected, $Actual, [string]$Because = '')
        if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
    }

    # A resolver that hands back a scripted sequence, one answer per call, then
    # repeats the last one forever. That is the shape of the real fault: several
    # addresses in quick succession, then stability.
    function Get-SequenceResolver {
        param([string[]]$Answer)
        $state = [pscustomobject]@{ Index = 0; Calls = 0; Answers = $Answer }
        $sb = {
            $state.Calls++
            $i = [Math]::Min($state.Index, $state.Answers.Count - 1)
            $state.Index++
            return $state.Answers[$i]
        }.GetNewClosure()
        return [pscustomobject]@{ Script = $sb; State = $state }
    }
}

Describe 'Invoke-WaitVmIp settle window' {

    It 'returns the address the guest SETTLED on, not the first one it was seen at' {
        # .13 -> .14 -> .15 is the observed churn: two re-requests under changed
        # client identities before the guest keeps an address.
        $r = Get-SequenceResolver -Answer @('192.168.64.13', '192.168.64.14', '192.168.64.15')
        $got = Invoke-WaitVmIp -VMName 'guest' -TimeoutSeconds 30 -PollSeconds 1 -StableForSeconds 3 -ResolveVmIp $r.Script
        Assert-Equal -Expected '192.168.64.15' -Actual $got -Because 'the first answer is the one the guest abandons; the settle window exists to outlast that.'
    }

    It 'returns promptly when the address never moves' {
        $r = Get-SequenceResolver -Answer @('10.0.0.5')
        $start = Get-Date
        $got = Invoke-WaitVmIp -VMName 'guest' -TimeoutSeconds 30 -PollSeconds 1 -StableForSeconds 2 -ResolveVmIp $r.Script
        $elapsed = ((Get-Date) - $start).TotalSeconds
        Assert-Equal -Expected '10.0.0.5' -Actual $got
        Assert-True ($elapsed -lt 10) 'a stable address must cost one settle window, not the whole timeout.'
    }

    It 'keeps the current candidate when a poll momentarily returns nothing' {
        # The lease file being rewritten under the reader is not evidence the
        # guest moved; an empty answer must not restart the window or, worse,
        # replace a good address with nothing.
        $r = Get-SequenceResolver -Answer @('10.0.0.5', '', '', '10.0.0.5')
        $got = Invoke-WaitVmIp -VMName 'guest' -TimeoutSeconds 30 -PollSeconds 1 -StableForSeconds 3 -ResolveVmIp $r.Script
        Assert-Equal -Expected '10.0.0.5' -Actual $got
    }

    It 'honours StableForSeconds 0 as the first-answer behaviour' {
        $r = Get-SequenceResolver -Answer @('10.0.0.5', '10.0.0.9')
        $got = Invoke-WaitVmIp -VMName 'guest' -TimeoutSeconds 30 -PollSeconds 1 -StableForSeconds 0 -ResolveVmIp $r.Script
        Assert-Equal -Expected '10.0.0.5' -Actual $got -Because 'a caller that re-resolves on its own must be able to waive the wait.'
        Assert-Equal -Expected 1 -Actual $r.State.Calls -Because 'waiving the window must not cost extra resolver calls.'
    }

    It 'still returns nothing when no address ever appears' {
        $r = Get-SequenceResolver -Answer @('')
        $got = Invoke-WaitVmIp -VMName 'guest' -TimeoutSeconds 3 -PollSeconds 1 -ResolveVmIp $r.Script
        Assert-True ([string]::IsNullOrEmpty([string]$got)) 'no address is still no address.'
    }
}

Describe 'Wait progress line' {

    It 'rewrites one line in place rather than scrolling, on a terminal' {
        $out = [System.IO.StringWriter]::new()
        $saved = [Console]::Out
        try {
            [Console]::SetOut($out)
            Write-YurunaWaitProgress -Message '00m03s / 45m  building' -Mode inplace
            Write-YurunaWaitProgress -Message '00m06s / 45m  building' -Mode inplace
            Write-YurunaWaitProgress -Message '00m09s / 45m  building' -Mode inplace
            Close-YurunaWaitProgress
        } finally { [Console]::SetOut($saved) }
        $text = $out.ToString()
        Assert-True ($text -notmatch "`n") 'an in-place line must never emit a newline -- that is what makes it scroll.'
        Assert-True ([regex]::Matches($text, "`r").Count -ge 3) 'every frame rewinds to column zero.'
        Assert-True ($text -match '00m09s') 'the latest frame must be present.'
        Assert-True ($text.EndsWith("`r")) 'the erase must leave the cursor at column zero so the caller''s verdict starts on a clean row.'
    }

    It 'pads a shorter frame so no tail of the previous one survives' {
        $out = [System.IO.StringWriter]::new()
        $saved = [Console]::Out
        try {
            [Console]::SetOut($out)
            Write-YurunaWaitProgress -Message 'a very long build step indeed' -Mode inplace
            Write-YurunaWaitProgress -Message 'short' -Mode inplace
        } finally { [Console]::SetOut($saved); Close-YurunaWaitProgress }
        $frames = $out.ToString() -split "`r" | Where-Object { $_ }
        Assert-True ($frames[-1].Length -ge $frames[0].Length) 'the shorter frame must be padded to at least the previous width.'
        Assert-True ($frames[-1] -notmatch 'indeed') 'no remnant of the longer frame may remain.'
    }

    It 'falls back to whole lines when output is redirected, throttled to avoid flooding a log' {
        # The installer drains a child's stdout into a file. Carriage returns
        # there produce one unreadable mega-line, and an unthrottled line per
        # poll produces hundreds of identical entries.
        $emitted = [System.Collections.Generic.List[string]]::new()
        $saved = $InformationPreference
        try {
            $InformationPreference = 'Continue'
            Write-YurunaWaitProgress -Message 'same text' -Mode lines -RedirectedEverySeconds 300 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
            Write-YurunaWaitProgress -Message 'same text' -Mode lines -RedirectedEverySeconds 300 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
            Write-YurunaWaitProgress -Message 'changed text' -Mode lines -RedirectedEverySeconds 300 6>&1 |
                ForEach-Object { $emitted.Add("$_") }
        } finally { $InformationPreference = $saved }
        Assert-Equal -Expected 2 -Actual $emitted.Count -Because 'the repeat is suppressed; only a CHANGE earns a new line.'
        Assert-True ($emitted[0] -match 'same text')
        Assert-True ($emitted[1] -match 'changed text')
    }

    It 'reports in-place as unsupported when the caller is marked non-interactive' {
        $saved = $env:YURUNA_NONINTERACTIVE
        try {
            $env:YURUNA_NONINTERACTIVE = '1'
            Assert-True (-not (Test-YurunaProgressLineSupported)) 'an installer collecting our output must get lines, not carriage returns.'
        } finally { $env:YURUNA_NONINTERACTIVE = $saved }
    }
}

Describe 'Wait-YurunaServiceVmEndpoint follows a moving guest' {

    It 'probes the CURRENT address on every poll, not the one it started with' {
        # The whole failure in one case: the caller hands over the address the
        # guest already left, the guest answers somewhere else, and the wait has
        # to find it rather than time out against the dead one.
        $probed = [System.Collections.Generic.List[string]]::new()
        $moved  = [System.Collections.Generic.List[string]]::new()
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 20 `
            -Address '192.168.64.13' -PollSeconds 1 `
            -ResolveAddress { '192.168.64.15' } `
            -TestPortOpen { param($a) $probed.Add($a); $a -eq '192.168.64.15' } `
            -OnAddressChanged { param($a) $moved.Add($a) }

        Assert-True $result.Ready 'the daemon answers at the address the guest moved to.'
        Assert-Equal -Expected '192.168.64.15' -Actual $result.Address
        Assert-Equal -Expected 1 -Actual $result.AddressChanges
        Assert-True (-not $probed.Contains('192.168.64.13')) 'the stale address must never be probed once a newer one resolves.'
        Assert-Equal -Expected '192.168.64.15' -Actual ($moved -join ',') -Because 'the caller must be told, so it can re-point a forwarder still dialing the old address.'
    }

    It 'reports Unreachable (not merely not-ready) when the daemon is up but the host cannot reach it' {
        # The service IS running; only this host's path to it is broken. The
        # caller turns that into a degraded success, so a bring-up is not failed
        # over a local networking gap the daemon is not responsible for.
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 20 `
            -Address '10.0.0.5' -GuestKey 'guest.x' -User 'x-admin' `
            -InGuestCheckAfterSeconds 0 -PollSeconds 1 `
            -ResolveAddress { '10.0.0.5' } `
            -TestPortOpen { $false } `
            -InvokeInGuest { @{ success = $true; exitCode = 0; output = 'YURUNA_LISTENING' } }

        Assert-True (-not $result.Ready) 'the host could not open the socket, so Ready stays false.'
        Assert-True $result.Unreachable 'the guest confirmed the daemon is bound.'
        Assert-True $result.ListeningInGuest
    }

    It 'keeps waiting while the daemon is still building in-guest' {
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 5 `
            -Address '10.0.0.5' -GuestKey 'guest.x' -User 'x-admin' `
            -InGuestCheckAfterSeconds 0 -PollSeconds 1 `
            -ResolveAddress { '10.0.0.5' } `
            -TestPortOpen { $false } `
            -InvokeInGuest { @{ success = $true; exitCode = 0; output = 'YURUNA_NOT_LISTENING' } }

        Assert-True (-not $result.Ready)
        Assert-True (-not $result.Unreachable) 'a daemon that has not bound yet is NOT an unreachable-address fault -- calling it one ends the wait that was about to succeed.'
    }

    It 'adopts the address SSH reached rather than calling the guest unreachable' {
        # The exact misdiagnosis this function replaces: the port probe is stuck
        # on a stale address while SSH is talking to the guest at its real one.
        # That is a stale probe target, not a broken path, and the fix is to
        # follow SSH -- not to declare the bring-up failed.
        $probed = [System.Collections.Generic.List[string]]::new()
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 20 `
            -Address '192.168.64.13' -GuestKey 'guest.x' -User 'x-admin' `
            -InGuestCheckAfterSeconds 0 -PollSeconds 1 `
            -ResolveAddress { if ($probed.Count -ge 1) { '192.168.64.15' } else { '192.168.64.13' } } `
            -TestPortOpen { param($a) $probed.Add($a); $a -eq '192.168.64.15' } `
            -InvokeInGuest { @{ success = $true; exitCode = 0; output = 'YURUNA_LISTENING' } }

        Assert-True $result.Ready 'following SSH to the live address is what makes the probe succeed.'
        Assert-True (-not $result.Unreachable) 'a stale probe target must never be reported as an unreachable service.'
        Assert-Equal -Expected '192.168.64.15' -Actual $result.Address
    }

    It 'extends the budget while cloud-init reports the guest is still building' {
        # The observed failure: a 15-minute budget against a ~30-minute first
        # build. The guest was progressing the whole time and said so; the wait
        # has to believe it rather than a constant chosen on another host.
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 4 `
            -MaxTimeoutSeconds 12 -Address '10.0.0.5' -GuestKey 'guest.x' -User 'x-admin' `
            -InGuestCheckAfterSeconds 0 -InGuestCheckEverySeconds 1 -PollSeconds 1 `
            -ResolveAddress { '10.0.0.5' } `
            -TestPortOpen { $false } `
            -InvokeInGuest { @{ success = $true; exitCode = 0; output = "YURUNA_NOT_LISTENING`nYURUNA_CLOUDINIT=running`nYURUNA_PROGRESS=Setting up golang-1.26-go" } }

        Assert-True ($result.ExtendedSeconds -gt 0) 'a guest that says it is still working must buy more time.'
        Assert-True ($result.WaitedSeconds -gt 4) 'the wait must actually outlast the original budget.'
        Assert-True ($result.WaitedSeconds -le 20) 'and must still stop at the cap rather than running forever.'
        Assert-True $result.StillBuilding 'hitting the cap while building is its own verdict, not a failure.'
        Assert-Equal -Expected 'running' -Actual $result.CloudInitStatus
        Assert-Equal -Expected 'Setting up golang-1.26-go' -Actual $result.LastProgress -Because 'the last build step is what makes a long wait legible.'
    }

    It 'does NOT extend once cloud-init is done -- a missing daemon is then a real failure' {
        $result = Wait-YurunaServiceVmEndpoint -VMName 'guest' -Port 80 -TimeoutSeconds 4 `
            -MaxTimeoutSeconds 60 -Address '10.0.0.5' -GuestKey 'guest.x' -User 'x-admin' `
            -InGuestCheckAfterSeconds 0 -InGuestCheckEverySeconds 1 -PollSeconds 1 `
            -ResolveAddress { '10.0.0.5' } `
            -TestPortOpen { $false } `
            -InvokeInGuest { @{ success = $true; exitCode = 0; output = "YURUNA_NOT_LISTENING`nYURUNA_CLOUDINIT=done`nYURUNA_PROGRESS=Cloud-init finished" } }

        Assert-Equal -Expected 0 -Actual $result.ExtendedSeconds -Because 'the build is over; waiting longer cannot help and would only hide the fault.'
        Assert-True (-not $result.StillBuilding)
        Assert-True ($result.WaitedSeconds -le 10) 'it must stop at the original budget.'
    }

    It 'never dials the VM name that address resolution falls back to' {
        # Get-GuestAddress returns the VM NAME when it can discover no address --
        # documented and useful for ssh, useless as a probe target.
        $probed = [System.Collections.Generic.List[string]]::new()
        $result = Wait-YurunaServiceVmEndpoint -VMName 'yuruna-stash-service' -Port 80 `
            -TimeoutSeconds 4 -Address '' -PollSeconds 1 `
            -ResolveAddress { param($n) $n } `
            -TestPortOpen { param($a) $probed.Add($a); $false }

        Assert-True (-not $probed.Contains('yuruna-stash-service')) 'the name fallback must be discarded, not dialed.'
        Assert-True (-not $result.Ready)
    }
}
