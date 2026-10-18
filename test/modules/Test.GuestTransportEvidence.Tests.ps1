<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42cba348-5965-4459-9ee1-5e87817e17e2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic ssh transport evidence pester
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
    A guest that cannot be reached is recorded as unreachable, not as a guest
    with no log to show.
.DESCRIPTION
    When a guest drops off the network mid-step, every host-side read of it
    fails the same way: the SSH client exits 255 with one line about the
    connection and nothing is captured. A step record that describes that as
    a missing profile and the transport as "unavailable", the reading reserved
    for a probe that never ran, sends the reader after a file on the guest, or
    after whatever the guest's own console blamed, and drops the one fact the
    host measured: the guest did not answer.

    These cases pin: the classification of the client's text; its precedence
    over the log-identity verdict; the readiness cause the diagnostic keeps
    from Wait-SshReady; and the bounded port probe the restart clock sample
    takes, which separates "sshd not up yet" from "guest off the network"
    without waiting for either.
    Run: Invoke-Pester -Path test/modules/Test.GuestTransportEvidence.Tests.ps1
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Ssh.psm1') -Global -Force -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Force
    $script:diag = Get-Module Test.Diagnostic
    # A port nothing listens on: bind an ephemeral port, read it, release it.
    function Get-ClosedLoopbackPort {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try { return [int]$listener.LocalEndpoint.Port } finally { $listener.Stop() }
    }
}

BeforeDiscovery {
    $script:Python3Runs = $false
    try {
        & python3 -c 'pass' *> $null
        $script:Python3Runs = ($LASTEXITCODE -eq 0)
    } catch {
        $script:Python3Runs = $false
    }
}

Describe 'the execution profile names a dead transport' {
    It 'reads the client''s connect timeout as a timed-out transport and keeps it over the log identity' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            return @{ success=$false; exitCode=255; output="ssh: connect to host 192.0.2.10 port 22: Connection timed out`r`n" }
        }
        $capture = Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive `
            -StepInvocationId lost-step -SequenceInvocationId lost-sequence -ScriptPath guest/ubuntu.server.26/ubuntu.server.26.k8s.sh
        $capture.timedOut | Should -BeTrue
        $capture.transport | Should -Be 'timed-out'
        $capture.transportFailed | Should -BeTrue
        $capture.transportDetail | Should -Match 'Connection timed out'
        $capture.sshResponsive | Should -BeFalse
        $capture.reasonCode | Should -Be 'profile-ssh-timeout' -Because 'a dead path says nothing about which log the guest holds'
        $capture.executionLog.state | Should -Not -Be current
        $capture.diagnosticOutcome | Should -Be 'unavailable'
    }
    It 'reads no-route, unreachable-network and refused lines as an unreachable transport' {
        foreach ($line in @('ssh: connect to host 192.0.2.10 port 22: No route to host',
                            'ssh: connect to host 192.0.2.10 port 22: Network is unreachable',
                            'ssh: connect to host 192.0.2.10 port 22: Connection refused')) {
            $script:transportLine = $line
            Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic { return @{ success=$false; exitCode=255; output=$script:transportLine } }
            $capture = Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive `
                -StepInvocationId lost-step -SequenceInvocationId lost-sequence -ScriptPath guest/x.sh
            $capture.timedOut | Should -BeFalse
            $capture.transport | Should -Be 'unreachable'
            $capture.transportFailed | Should -BeTrue
            $capture.reasonCode | Should -Be 'profile-ssh-unreachable'
            $capture.transportDetail | Should -Match 'port 22'
        }
    }
    It 'leaves a failure it cannot read unclassified, and a transport that answered responsive' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            return @{ success=$false; exitCode=255; output='kex_exchange_identification: read: Connection reset by peer' }
        }
        $capture = Test.Diagnostic\Save-GuestExecutionProfile -VMName vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -StepInvocationId lost-step
        $capture.transport | Should -Be 'unknown'
        $capture.transportFailed | Should -BeFalse
        $capture.reasonCode | Should -Be 'profile-ssh-unavailable'
        (Test.Diagnostic\Get-GuestTransportVerdict -Result @{ success=$true; exitCode=0; output='--- YURUNA EXECUTION LOG ---' }).state | Should -Be responsive
        (Test.Diagnostic\Get-GuestTransportVerdict -Result @{ success=$false; exitCode=1; output='Timed out after 20s' }).state | Should -Be unknown `
            -Because 'only the SSH client (255) or the harness kill (-1) speak for the transport'
        (Test.Diagnostic\Get-GuestTransportVerdict -Result $null).state | Should -Be unknown
        (Test.Diagnostic\Get-GuestTransportVerdict -Result @{ success=$false; exitCode=-1; output='Timed out after 20s'; timedOut=$true }).state | Should -Be 'timed-out'
    }
}

Describe 'the readiness wait keeps its verdict for the diagnostic' {
    BeforeAll {
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-GuestSshUser -ModuleName Test.Ssh { return 'fixture-user' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Set-ProvenGuestAddress -ModuleName Test.Ssh { }
    }
    It 'records the cause, the target and the client line when the guest never answered' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            return @{ Started=$true; ExitCode=255; StdOut=''; StdErr='ssh: connect to host 192.0.2.10 port 22: Connection timed out'
                TimedOut=$false; DrainTimedOut=$false; OutputTruncated=$false; KillFailed=$false }
        }
        Test.Ssh\Wait-SshReady -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 2 -PollSeconds 1 | Should -BeFalse
        $readiness = Test.Ssh\Get-LastSshReadiness
        $readiness.vmName | Should -Be fixture-vm
        $readiness.cause | Should -Not -BeNullOrEmpty
        $readiness.cause | Should -Not -Be ready
        $readiness.target | Should -Be '192.0.2.10'
        $readiness.ipDiscovered | Should -BeTrue
        $readiness.ipAnswered | Should -BeFalse
        $readiness.attempts | Should -BeGreaterOrEqual 1
        $readiness.lastError | Should -Match 'Connection timed out'
        $readiness.timeoutSeconds | Should -Be 2
    }
    It 'records a ready verdict with the address the handshake used' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            return @{ Started=$true; ExitCode=0; StdOut='yuruna-ssh-ready'; StdErr=''
                TimedOut=$false; DrainTimedOut=$false; OutputTruncated=$false; KillFailed=$false }
        }
        Test.Ssh\Wait-SshReady -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 2 -PollSeconds 1 | Should -BeTrue
        $readiness = Test.Ssh\Get-LastSshReadiness
        $readiness.cause | Should -Be ready
        $readiness.target | Should -Be '192.0.2.10'
        $readiness.ipAnswered | Should -BeTrue
    }
    It 'hands a copy back, so a caller cannot edit the kept verdict' {
        $first = Test.Ssh\Get-LastSshReadiness
        $first.cause = 'edited'
        (Test.Ssh\Get-LastSshReadiness).cause | Should -Be ready
    }
    It 'names the readiness cause in the silence the diagnostic publishes' {
        Mock Send-YurunaDegradation -ModuleName Test.Diagnostic { $script:silenceReason = $Reason }
        & $script:diag { $script:LastDiagnosticSshReadiness = @{ cause='ip_unanswered'; target='192.0.2.10' } }
        & $script:diag { Publish-GuestDiagnosticSilence -VMName fixture-vm -Attempted @('ssh-not-ready', 'console') -LastResult $null }
        $script:silenceReason | Should -Match 'ssh readiness: ip_unanswered'
        & $script:diag { $script:LastDiagnosticSshReadiness = $null }
    }
}

Describe 'the restart clock sample probes the SSH port' {
    It 'records a bounded port probe beside the clock sample without waiting for sshd' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            return @{ success=$false; exitCode=-1; output='Invoke-GuestSsh timed out after 3s: fixture-user@192.0.2.10' }
        }
        Mock Save-HyperVCpuRestartHostContext -ModuleName Test.Diagnostic { return @{ status='complete'; settings=@{ processorCount=2 } } }
        Mock 'Test.Ssh\Get-ProvenGuestAddress' -ModuleName Test.Diagnostic { return '192.0.2.10' }
        Mock Test-GuestSshPortProbe -ModuleName Test.Diagnostic {
            return @{ address=$Address; port=22; connected=$false; banner=''; elapsedMs=7; error='connection refused' }
        }
        $capture = Test.Diagnostic\Save-GuestCpuRestartEvidence -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -Phase after-cpu-restart
        $capture.sshProbe.address | Should -Be '192.0.2.10'
        $capture.sshProbe.connected | Should -BeFalse
        (Get-Content $capture.outPath -Raw) | Should -Match '# SSH port probe: .*"connected":\s*false'
        (Get-Content (Join-Path $TestDrive 'guest.cpu-clock.after-cpu-restart.json') -Raw | ConvertFrom-Json).sshProbe.error | Should -Be 'connection refused'
        Should -Invoke Test-GuestSshPortProbe -ModuleName Test.Diagnostic -Times 1 -Exactly -ParameterFilter { $Address -eq '192.0.2.10' }
    }
    It 'reports no address without opening a socket' {
        $probe = Test.Diagnostic\Test-GuestSshPortProbe -Address ''
        $probe.connected | Should -BeFalse
        $probe.error | Should -Be 'no address'
        $probe.elapsedMs | Should -Be 0
    }
    It 'reports a closed port quickly, with the error the stack gave' {
        $port = Get-ClosedLoopbackPort
        $probe = Test.Diagnostic\Test-GuestSshPortProbe -Address 127.0.0.1 -Port $port -TimeoutMilliseconds 1500
        $probe.connected | Should -BeFalse
        $probe.error | Should -Not -BeNullOrEmpty
        $probe.elapsedMs | Should -BeLessThan 1500
    }
    It 'connects to a listening port and keeps the banner it sent' -Skip:(-not $script:Python3Runs) {
        $portFile = Join-Path $TestDrive 'banner.port'
        $server = Join-Path $TestDrive 'banner-server.py'
        [IO.File]::WriteAllText($server, @'
import socket, sys, time
s = socket.socket()
s.bind(('127.0.0.1', 0))
s.listen(1)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.getsockname()[1]))
c, _ = s.accept()
c.sendall(b'SSH-2.0-fixture\r\n')
time.sleep(2)
c.close()
'@)
        $process = Start-Process -FilePath python3 -ArgumentList @('-I', $server, $portFile) -PassThru -NoNewWindow `
            -RedirectStandardError (Join-Path $TestDrive 'banner.err')
        try {
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $portFile) -and $deadline.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 100 }
            Test-Path $portFile | Should -BeTrue -Because 'the fixture listener must have started'
            $port = [int](Get-Content $portFile -Raw).Trim()
            $probe = Test.Diagnostic\Test-GuestSshPortProbe -Address 127.0.0.1 -Port $port -TimeoutMilliseconds 2000
            $probe.connected | Should -BeTrue
            $probe.banner | Should -Match 'SSH-2\.0-fixture'
            $probe.error | Should -BeNullOrEmpty
        } finally {
            if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}
