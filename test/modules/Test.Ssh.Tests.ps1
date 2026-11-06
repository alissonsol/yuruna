<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42539169-cf17-4eb5-b0d6-c972156d3841
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test ssh resilience pester
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
    Pester coverage for Get-SshReadinessFailureCause (Test.Ssh.psm1): the
    cause discriminator Wait-SshReady attaches to an ssh_handshake_failed
    event so the operator/remediator routes the recoverable
    "IP never discovered" lateness class apart from a real sshd/auth fault.
.DESCRIPTION
    Throw-based assertions (Pester 5+). The classifier
    is pure (inputs: IpDiscovered + LastError), so no guest, no network, no
    module state is involved.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Ssh.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.ServiceStartSource.psm1') -Force -DisableNameChecking

}

Describe 'Get-SshReadinessFailureCause' {

    It 'reports ip_not_discovered when no IP was discovered and sshd was never reached' {
        Assert-Equal 'ip_not_discovered' (Get-SshReadinessFailureCause -IpDiscovered $false -LastError '')
        Assert-Equal 'ip_not_discovered' (Get-SshReadinessFailureCause -IpDiscovered $false -LastError 'Could not resolve hostname test-vm-01')
    }

    It 'ranks reached-sshd evidence ABOVE the IP-discovery signal (VM-name-resolvable host)' {
        # No discovered IP, but the bare name resolved and sshd answered with an
        # auth error -- the true cause is auth, not ip_not_discovered.
        Assert-Equal 'auth_denied' (Get-SshReadinessFailureCause -IpDiscovered $false -LastError 'Permission denied (publickey).')
        Assert-Equal 'connection_refused' (Get-SshReadinessFailureCause -IpDiscovered $false -LastError 'ssh: connect to host test-vm port 22: Connection refused')
    }

    It 'classifies auth failures' {
        Assert-Equal 'auth_denied' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'Permission denied (publickey,password).')
        Assert-Equal 'auth_denied' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'Too many authentication failures')
    }

    It 'classifies connection refused (host up, sshd down)' {
        Assert-Equal 'connection_refused' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'connect to host 192.168.7.40 port 22: Connection refused')
    }

    It 'classifies a changed host key' {
        Assert-Equal 'host_key_changed' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'Host key verification failed.')
        Assert-Equal 'host_key_changed' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!')
    }

    It 'classifies the per-probe cap (half-dead post-TCP session) as probe_timeout only with a discovered IP' {
        Assert-Equal 'probe_timeout' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'probe timed out after 15s (ssh hung post-TCP; process killed)')
    }

    It 'classifies a no-IP probe timeout as ip_not_discovered, not probe_timeout (discovery lateness)' {
        # A probe that hung against the unresolved bare-VMName fallback (no IP ever
        # discovered) is the recoverable discovery-lateness class -- ssh never had a
        # real host to reach -- not a genuine post-TCP hang.
        Assert-Equal 'ip_not_discovered' (Get-SshReadinessFailureCause -IpDiscovered $false -LastError 'probe timed out after 15s (ssh hung post-TCP; process killed)')
    }

    It 'classifies an unreachable path to an address that HAS answered before' {
        # Something replied at this address earlier in the wait, so the address
        # is owned by a live machine and the fault is the path to it.
        Assert-Equal 'network_unreachable' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError 'connect to host 192.168.7.40 port 22: No route to host')
        Assert-Equal 'network_unreachable' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError 'connect to host 192.168.7.40 port 22: Connection timed out')
    }

    It 'separates an address nothing ever answered from a path that broke' {
        # A lease table can hold several addresses for one guest: a rebuilt
        # guest takes a new one and the old rows stay until they expire, so an
        # address can be discovered, unexpired, and belong to nothing. Calling
        # that network_unreachable sends a reader to audit a network that is
        # working, which is the wrong machine.
        Assert-Equal 'ip_never_answered' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError 'connect to host 192.168.122.120 port 22: No route to host')
        Assert-Equal 'ip_never_answered' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError 'connect to host 192.168.122.120 port 22: Connection timed out')
    }

    It 'ranks reached-sshd evidence above the never-answered signal' {
        # A refusal or an auth denial IS an answer, so those causes must win
        # even when the caller has not flagged the address as having answered.
        Assert-Equal 'connection_refused' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError 'connect to host 10.0.0.5 port 22: Connection refused')
        Assert-Equal 'auth_denied' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError 'Permission denied (publickey)')
    }

    It 'classifies an unresolved name against a discovered IP context' {
        # Name resolution is decided before the never-answered split, so a
        # resolver fault keeps its own cause whether or not anything answered.
        Assert-Equal 'name_unresolved' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError 'ssh: Could not resolve hostname foo: Name or service not known')
        Assert-Equal 'name_unresolved' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'ssh: Could not resolve hostname foo: Name or service not known')
    }

    It 'falls back to handshake_failed for an unrecognized error on a reachable host' {
        Assert-Equal 'handshake_failed' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'kex_exchange_identification: read: some novel error')
    }
}

Describe 'Select-SshReadinessEvidence' {

    BeforeAll {
        # What sshd sends a BatchMode client whose account the guest has expired.
        $script:ExpiredProbe = @'
Warning: Permanently added '192.168.7.40' (ED25519) to the list of known hosts.
WARNING: Your password has expired.
Password change required but no TTY available.
'@
    }

    It 'reads the cause from an earlier answering probe when the last one was killed at the deadline' {
        # The shape every long wait ends in: probes are capped at the budget
        # that is left, so the final one is killed rather than answered and its
        # note says nothing about the guest. The guest's own words are the only
        # evidence the wait collected, and they name a repair no retry performs.
        $e = Select-SshReadinessEvidence -FinalError 'probe timed out after 14.4s (overall 300s deadline reached mid-probe; process killed)' -AnsweredError $script:ExpiredProbe
        Assert-Equal 'answered_probe' $e.source
        Assert-Equal 'password_expired' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError $e.text)
    }

    It 'reads the cause from an earlier answer when the final probe got no budget to run in' {
        $e = Select-SshReadinessEvidence -FinalError 'probe timed out with no budget to run in: the 300s wait was already spent when ssh started, so nothing was ever asked of the target (process killed)' -AnsweredError $script:ExpiredProbe
        Assert-Equal 'answered_probe' $e.source
        Assert-Equal 'password_expired' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError $e.text)
    }

    It 'reads the cause from an earlier answer when the final probe never started' {
        $e = Select-SshReadinessEvidence -FinalError "Process.Start('ssh') threw: The system cannot find the file specified." -AnsweredError $script:ExpiredProbe
        Assert-Equal 'answered_probe' $e.source
    }

    It 'lets a fresh, meaningful final error outrank an older answer' {
        # A guest can report an expired account and then disappear. The
        # disappearance is the newer fact and the one to act on, so a final
        # probe carrying any verdict keeps the classification -- including
        # verdicts that are not "answers".
        $gone = Select-SshReadinessEvidence -FinalError 'ssh: connect to host 192.168.7.40 port 22: No route to host' -AnsweredError $script:ExpiredProbe
        Assert-Equal 'final_probe' $gone.source
        Assert-Equal 'network_unreachable' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError $gone.text)

        $refused = Select-SshReadinessEvidence -FinalError 'ssh: connect to host 192.168.7.40 port 22: Connection refused' -AnsweredError $script:ExpiredProbe
        Assert-Equal 'final_probe' $refused.source
        Assert-Equal 'connection_refused' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $true -LastError $refused.text)
    }

    It 'leaves a pure timeout with nothing ever answered classified as it always was' {
        $e = Select-SshReadinessEvidence -FinalError 'probe timed out after 15s (ssh hung post-TCP; process killed)' -AnsweredError ''
        Assert-Equal 'final_probe' $e.source
        Assert-Equal 'probe_timeout' (Get-SshReadinessFailureCause -IpDiscovered $true -IpAnswered $false -LastError $e.text)
        Assert-Equal 'ip_not_discovered' (Get-SshReadinessFailureCause -IpDiscovered $false -IpAnswered $false -LastError $e.text)
    }

    It 'keeps the final probe when there is nothing else, whatever it said' {
        $e = Select-SshReadinessEvidence -FinalError '' -AnsweredError ''
        Assert-Equal 'final_probe' $e.source
        Assert-Equal '' $e.text
    }

    It 'does not mistake a guest that mentions a timeout for a killed probe' {
        # The no-verdict markers are strings this module mints, at the start of
        # the note. Text the far end sent must never be read as one.
        $e = Select-SshReadinessEvidence -FinalError 'kex_exchange_identification: read: Connection timed out' -AnsweredError $script:ExpiredProbe
        Assert-Equal 'final_probe' $e.source
    }
}

Describe 'Test-SshTransportLoss' {

    # ssh reports its OWN faults as 255 and passes anything else through as the
    # remote command's status. So 255 is necessary and nowhere near sufficient:
    # an auth refusal, a rejected host key and an unresolvable name are all 255,
    # and none of them is a dropped transport. Getting this wrong in either
    # direction is expensive -- calling a guest failure a transport loss hides a
    # real bug behind a retry, and calling a transport loss a guest failure sends
    # an operator to read a script that never ran.

    It 'recognizes the keepalive giving up on a peer that stopped answering' {
        Test-SshTransportLoss -ExitCode 255 -Output 'Timeout, server amisad-build-admin@192.168.7.165 not responding.' | Should -BeTrue
    }

    It 'recognizes the session dying mid-command' {
        foreach ($text in 'client_loop: send disconnect: Broken pipe',
                          'Connection to 192.168.7.165 closed by remote host.',
                          'Connection reset by peer',
                          'packet_write_wait: Connection to 192.168.7.9 port 22: Broken pipe') {
            Test-SshTransportLoss -ExitCode 255 -Output $text | Should -BeTrue -Because "transport wording: $text"
        }
    }

    It 'recognizes the route disappearing under an established session' {
        foreach ($text in 'ssh: connect to host 192.168.7.165 port 22: No route to host',
                          'ssh: connect to host 192.168.7.165 port 22: Network is unreachable') {
            Test-SshTransportLoss -ExitCode 255 -Output $text | Should -BeTrue -Because "route wording: $text"
        }
    }

    It 'treats a silent 255 as transport loss, since a refusal always says which it was' {
        Test-SshTransportLoss -ExitCode 255 -Output '' | Should -BeTrue
    }

    It 'does NOT claim transport loss for an authentication or host-key refusal' {
        Test-SshTransportLoss -ExitCode 255 -Output 'Permission denied (publickey).' | Should -BeFalse
        Test-SshTransportLoss -ExitCode 255 -Output 'Host key verification failed.' | Should -BeFalse
        Test-SshTransportLoss -ExitCode 255 -Output 'ssh: Could not resolve hostname amisad-build: Name or service not known' | Should -BeFalse
    }

    It 'never claims transport loss for a status the guest actually reported' {
        # The whole point of the discriminator: these came from the far end.
        Test-SshTransportLoss -ExitCode 1 -Output 'tool not on PATH after install: cargo' | Should -BeFalse
        Test-SshTransportLoss -ExitCode 3 -Output 'STASH UNREACHABLE at http://192.168.7.95' | Should -BeFalse
        Test-SshTransportLoss -ExitCode 0 -Output 'AmisAd build tools installed' | Should -BeFalse
    }
}

Describe 'Get-GuestRunToken' {

    # The token is what makes a reconnect an ATTACH rather than a second run, so
    # two invocations of the same step against the same guest must agree on it.
    # Determinism is the property under test; the readable prefix is incidental.

    It 'is stable for the same sequence, step and guest' {
        $a = Get-GuestRunToken -SequencePath '/x/workload.guest.ubuntu.server.24.amisad-core.s003.silence.yml' -StepNumber 3 -VMName 'amisad-core'
        $b = Get-GuestRunToken -SequencePath '/x/workload.guest.ubuntu.server.24.amisad-core.s003.silence.yml' -StepNumber 3 -VMName 'amisad-core'
        $a | Should -Be $b
    }

    It 'separates different steps, guests and sequences' {
        $base = Get-GuestRunToken -SequencePath '/x/seq.yml' -StepNumber 3 -VMName 'amisad-core'
        (Get-GuestRunToken -SequencePath '/x/seq.yml'   -StepNumber 4 -VMName 'amisad-core')  | Should -Not -Be $base
        (Get-GuestRunToken -SequencePath '/x/seq.yml'   -StepNumber 3 -VMName 'amisad-edge-a')| Should -Not -Be $base
        (Get-GuestRunToken -SequencePath '/x/other.yml' -StepNumber 3 -VMName 'amisad-core')  | Should -Not -Be $base
    }

    It 'only ever emits characters the guest-side supervisor accepts' {
        # The supervisor rejects anything outside this class because the token is
        # interpolated into a shell command line and used as a directory name.
        $t = Get-GuestRunToken -SequencePath '/x/a b/weird name (1).yml' -StepNumber 12 -VMName 'vm/../etc'
        $t | Should -Match '^[A-Za-z0-9._-]+$'
    }

    It 'does not start with a dot, which would hide the run directory on the guest' {
        $t = Get-GuestRunToken -SequencePath '/x/.hidden.yml' -StepNumber 1 -VMName 'vm'
        $t | Should -Not -Match '^\.'
    }
}

Describe 'The proven-address memo' {

    # The last word in address discovery, and unlike every other source it is
    # evidence rather than a report: ssh completed a key exchange there. That
    # does not make it current, which is why it is age-bounded and dropped
    # outright when a snapshot restore sends the guest back for a fresh lease.

    AfterEach { Clear-ProvenGuestAddress }

    It 'is empty until something has actually been proven' {
        Clear-ProvenGuestAddress
        Get-ProvenGuestAddress -VMName 'amisad-core' | Should -BeNullOrEmpty
    }

    It 'returns the address a handshake used, per guest' {
        Set-ProvenGuestAddress -VMName 'amisad-core' -Address '192.168.7.140'
        Get-ProvenGuestAddress -VMName 'amisad-core'   | Should -Be '192.168.7.140'
        Get-ProvenGuestAddress -VMName 'amisad-edge-a' | Should -BeNullOrEmpty
    }

    It 'refuses to remember something that is not an address' {
        Set-ProvenGuestAddress -VMName 'amisad-core' -Address '192.168.7.140'
        Set-ProvenGuestAddress -VMName 'amisad-core' -Address 'amisad-core'
        Get-ProvenGuestAddress -VMName 'amisad-core' | Should -Be '192.168.7.140'
    }

    It 'goes quiet once the entry is older than the caller will accept' {
        Set-ProvenGuestAddress -VMName 'amisad-core' -Address '192.168.7.140'
        Get-ProvenGuestAddress -VMName 'amisad-core' -MaxAgeSeconds 0 | Should -BeNullOrEmpty
    }

    It 'is dropped for one guest without disturbing the others' {
        Set-ProvenGuestAddress -VMName 'amisad-core'   -Address '192.168.7.140'
        Set-ProvenGuestAddress -VMName 'amisad-edge-a' -Address '192.168.7.210'
        Clear-ProvenGuestAddress -VMName 'amisad-core'
        Get-ProvenGuestAddress -VMName 'amisad-core'   | Should -BeNullOrEmpty
        Get-ProvenGuestAddress -VMName 'amisad-edge-a' | Should -Be '192.168.7.210'
    }
}

Describe 'Test-DetachedRunInterrupted' {

    # A detached step that dies mid-run and a detached step whose payload
    # genuinely failed look identical in exit status. Getting this wrong in the
    # quiet direction is what turns a recoverable blip into a lost cycle: no
    # reconnect is attempted and the guest script is blamed for a session that
    # ended under it.

    It 'treats a started run with no exit line as an interrupted session' {
        # The signature seen in practice: the client says nothing useful, and
        # the only evidence is that the supervisor announced a run it never
        # finished reporting.
        Test-DetachedRunInterrupted -ExitCode 255 -StdErr "YURUNA_RUN_START token=seq.s3.abc boot=1a3d6677`nTERM environment variable not set." |
            Should -BeTrue
    }

    It 'treats an interrupted re-attach the same way' {
        Test-DetachedRunInterrupted -ExitCode 255 -StdErr 'YURUNA_RUN_ATTACH token=seq.s3.abc boot=1a3d6677 from=42' |
            Should -BeTrue
    }

    It 'does NOT call it interrupted once the run reported its exit' {
        # The payload's own status is known here, so the session ending
        # afterwards is not a reason to go back for more.
        Test-DetachedRunInterrupted -ExitCode 4 -StdErr "YURUNA_RUN_START token=t`nYURUNA_RUN_EXIT rc=4 lines=118" |
            Should -BeFalse
    }

    It 'does NOT call a bootstrap failure interrupted, so it is reported rather than retried' {
        # No supervisor ever ran: no bash, no base64, a refused key. Retrying
        # would loop against something that cannot succeed.
        Test-DetachedRunInterrupted -ExitCode 255 -StdErr 'bash: command not found' | Should -BeFalse
        Test-DetachedRunInterrupted -ExitCode 255 -StdErr 'Permission denied (publickey).' | Should -BeFalse
    }

    It 'still recognizes a transport loss the client did explain' {
        Test-DetachedRunInterrupted -ExitCode 255 -StdErr 'client_loop: send disconnect: Broken pipe' | Should -BeTrue
    }

    It 'is never interrupted on success' {
        Test-DetachedRunInterrupted -ExitCode 0 -StdErr 'YURUNA_RUN_START token=t' | Should -BeFalse
    }
}

Describe 'Get-YurunaSshHostKeyOption' {

    # Call sites splice this sequence into an ssh argument list as it is, so the
    # contract is the flat -o/value order and the exact spelling of every value.
    # ssh takes /dev/null as written on Windows too, so the sequence must be the
    # same on every host.

    It 'returns the three host-key options as a flat -o/value sequence, in order' {
        $options = @(Get-YurunaSshHostKeyOption)
        $expected = @(
            '-o', 'StrictHostKeyChecking=no',
            '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'GlobalKnownHostsFile=/dev/null')
        $options.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $options[$i] | Should -BeOfType ([string])
            $options[$i] | Should -BeExactly $expected[$i] -Because "element $i goes into an ssh argument list unchanged"
        }
    }

    It 'keeps the same fixed sequence for an address target or no target on every platform' {
        $fixed = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'GlobalKnownHostsFile=/dev/null')
        foreach ($target in @('', '192.168.1.40', 'fe80::1')) {
            @(Get-YurunaSshHostKeyOption -VMName $target) | Should -BeExactly $fixed -Because "'$target' carries no guest identity to pin"
        }
    }
}

Describe 'Per-guest SSH host key pins' {
    # A named guest's host key is recorded at first contact and required after
    # it, so a different machine answering at the guest's address is refused
    # instead of receiving the command.
    BeforeAll {
        # The pin folder itself does not exist yet: the module creates it.
        $script:PinRoot = New-YurunaTestTempDir -Prefix 'yuruna-pin'
        $script:PinDir = Join-Path $script:PinRoot 'pins'
        & (Get-Module Test.Ssh) { $script:SavedPinDir = $script:HostKeyPinDir; $script:HostKeyPinDir = $args[0] } $script:PinDir
    }
    AfterAll {
        & (Get-Module Test.Ssh) { $script:HostKeyPinDir = $script:SavedPinDir }
        Remove-YurunaTestTempDir $script:PinRoot
    }

    It 'pins a named guest in its own file under an alias of the name' {
        $options = @(Get-YurunaSshHostKeyOption -VMName 'yuruna-guest-01')
        $pin = Join-Path $script:PinDir 'yuruna-guest-01'
        $options | Should -BeExactly @('-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=`"$pin`"",
            '-o', 'GlobalKnownHostsFile=/dev/null', '-o', 'HostKeyAlias=yuruna-guest-yuruna-guest-01', '-o', 'CheckHostIP=no')
        Test-Path -LiteralPath $script:PinDir -PathType Container | Should -BeTrue
    }

    It 'names the pin file after the guest, hashing a name that is not a plain file name' {
        Get-GuestHostKeyPinPath -VMName 'yuruna-guest-01' | Should -BeExactly (Join-Path $script:PinDir 'yuruna-guest-01')
        Get-GuestHostKeyPinPath -VMName '../escape me' | Should -Match ([regex]::Escape($script:PinDir) + '[\\/]sha256-[0-9a-f]{32}$')
        Get-GuestHostKeyPinPath -VMName '10.0.0.5' | Should -BeExactly ''
    }

    It 'forgets a pin on reset and tolerates a guest with none' {
        $pin = Get-GuestHostKeyPinPath -VMName 'yuruna-guest-02'
        [void][IO.Directory]::CreateDirectory($script:PinDir)
        Set-Content -LiteralPath $pin -Value 'yuruna-guest-yuruna-guest-02 ssh-ed25519 AAAA'
        Reset-GuestHostKeyPin -VMName 'yuruna-guest-02' -Confirm:$false
        Test-Path -LiteralPath $pin | Should -BeFalse
        { Reset-GuestHostKeyPin -VMName 'yuruna-guest-02' -Confirm:$false } | Should -Not -Throw
    }

    It 'makes ssh record the key at first contact and refuse a different one (local sshd)' {
        $ssh = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $keygen = Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $listening = $false
        if ($ssh -and $keygen) {
            $client = [Net.Sockets.TcpClient]::new()
            try { $listening = $client.ConnectAsync('127.0.0.1', 22).Wait(1000) -and $client.Connected } catch { $listening = $false } finally { $client.Dispose() }
        }
        if (-not $listening) { Set-ItResult -Skipped -Because 'no ssh client or no sshd on 127.0.0.1:22'; return }
        $options = @(Get-YurunaSshHostKeyOption -VMName 'yuruna-pin-live')
        $first = (& $ssh.Source -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR @options 127.0.0.1 true 2>&1) -join "`n"
        $first | Should -Not -Match 'Host key verification failed'
        $pin = Get-GuestHostKeyPinPath -VMName 'yuruna-pin-live'
        (Get-Content -LiteralPath $pin -Raw) | Should -Match 'ssh-|ecdsa-'
        $other = Join-Path $script:PinDir 'other'
        & $keygen.Source -q -t ed25519 -N '' -f $other | Out-Null
        Set-Content -LiteralPath $pin -Value ('yuruna-guest-yuruna-pin-live ' + (((Get-Content -LiteralPath "$other.pub") -split ' ')[0..1] -join ' '))
        $second = (& $ssh.Source -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR @options 127.0.0.1 true 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 255
        $second | Should -Match 'Host key verification failed'
    }

    It 'moves a pin to the name a guest was renamed to, under that name''s alias' {
        [void][IO.Directory]::CreateDirectory($script:PinDir)
        Set-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-build-01') -Value 'yuruna-guest-yuruna-build-01 ssh-ed25519 AAAAbuilt'
        Move-GuestHostKeyPin -VMName 'yuruna-build-01' -NewVMName 'yuruna-snap-01' -Confirm:$false
        Get-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-snap-01') | Should -BeExactly 'yuruna-guest-yuruna-snap-01 ssh-ed25519 AAAAbuilt'
        Test-Path -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-build-01') | Should -BeFalse -Because 'no guest answers to the old name after the rename'
    }

    It 'replaces the pin a guest of the new name left behind, from a hashed entry' {
        [void][IO.Directory]::CreateDirectory($script:PinDir)
        Set-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-build-02') -Value '|1|c2FsdA==|aGFzaA== ssh-ed25519 AAAAbuilt'
        Set-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-snap-02') -Value 'yuruna-guest-yuruna-snap-02 ssh-ed25519 AAAAearlier'
        Move-GuestHostKeyPin -VMName 'yuruna-build-02' -NewVMName 'yuruna-snap-02' -Confirm:$false
        Get-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-snap-02') | Should -BeExactly 'yuruna-guest-yuruna-snap-02 ssh-ed25519 AAAAbuilt'
    }

    It 'forgets the new name''s pin when the renamed guest has none' {
        [void][IO.Directory]::CreateDirectory($script:PinDir)
        Set-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-snap-03') -Value 'yuruna-guest-yuruna-snap-03 ssh-ed25519 AAAAearlier'
        Move-GuestHostKeyPin -VMName 'yuruna-build-03' -NewVMName 'yuruna-snap-03' -Confirm:$false
        Test-Path -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-snap-03') | Should -BeFalse
    }

    It 'lets ssh reach a renamed guest that an earlier guest of the name had pinned (local sshd)' {
        $ssh = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $keygen = Get-Command ssh-keygen -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $listening = $false
        if ($ssh -and $keygen) {
            $client = [Net.Sockets.TcpClient]::new()
            try { $listening = $client.ConnectAsync('127.0.0.1', 22).Wait(1000) -and $client.Connected } catch { $listening = $false } finally { $client.Dispose() }
        }
        if (-not $listening) { Set-ItResult -Skipped -Because 'no ssh client or no sshd on 127.0.0.1:22'; return }
        $built = @(Get-YurunaSshHostKeyOption -VMName 'yuruna-pin-build')
        $null = & $ssh.Source -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR @built 127.0.0.1 true 2>&1
        $earlier = Join-Path $script:PinDir 'earlier'
        & $keygen.Source -q -t ed25519 -N '' -f $earlier | Out-Null
        Set-Content -LiteralPath (Get-GuestHostKeyPinPath -VMName 'yuruna-pin-snap') -Value ('yuruna-guest-yuruna-pin-snap ' + (((Get-Content -LiteralPath "$earlier.pub") -split ' ')[0..1] -join ' '))
        $renamed = @(Get-YurunaSshHostKeyOption -VMName 'yuruna-pin-snap')
        $refused = (& $ssh.Source -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR @renamed 127.0.0.1 true 2>&1) -join "`n"
        $refused | Should -Match 'Host key verification failed' -Because 'the pin under the new name holds the earlier guest''s key'
        Move-GuestHostKeyPin -VMName 'yuruna-pin-build' -NewVMName 'yuruna-pin-snap' -Confirm:$false
        $reached = (& $ssh.Source -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR @renamed 127.0.0.1 true 2>&1) -join "`n"
        $reached | Should -Not -Match 'Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED'
    }

    It 'reports a refused pinned guest as a host key mismatch, naming the pin' {
        InModuleScope Test.Ssh {
            Mock Get-GuestAddress { '192.168.1.40' }
            Mock Get-YurunaSshPrivateKeyPath { '/fixture/key' }
            Mock Invoke-BoundedNativeCommand {
                @{ Started = $true; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false
                    DeadlineExhausted = $false; ExitCode = 255; StdOut = ''; StdErr = 'Host key verification failed.'; StartError = '' }
            }
            Mock Test-BoundedNativeResultComplete { $true }
            $r = Invoke-GuestSsh -VMName 'yuruna-guest-03' -GuestKey 'guest.ubuntu.server.26' -User 'yuruna' -Command 'true' -TimeoutSeconds 30
            $r.success | Should -BeFalse
            $r.exitCode | Should -Be 255
            $r.hostKeyMismatch | Should -BeTrue
            $r.output | Should -Match 'Reset-GuestHostKeyPin -VMName yuruna-guest-03'
            $r.output | Should -Match ([regex]::Escape((Get-GuestHostKeyPinPath -VMName 'yuruna-guest-03')))
            Should -Invoke Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'StrictHostKeyChecking=accept-new' }
        }
    }

    It 'forgets the pin wherever a guest is built' {
        $root = Split-Path -Parent (Split-Path -Parent $here)
        foreach ($file in @('test/modules/Test.RunnerInnerLoop.psm1', 'test/modules/Test.Orchestrator.psm1', 'test/Debug-TestSequence.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $root $file) -Raw
            $text | Should -Match ('Reset-GuestHostKeyPin -VMName \$newVmArgs\.VMName -Confirm:\$false \}\r?\n\s*\$r = New-VM @newVmArgs') -Because "$file builds a guest"
        }
        $builderFn = Get-YurunaTestFunctionAst -Path (Join-Path $root 'test/modules/Test.ServiceVm.psm1') -Name 'Invoke-YurunaServiceVmBuild'
        $builder = $builderFn.Extent.Text
        $builder.IndexOf('{ Reset-GuestHostKeyPin -VMName $VMName -Confirm:$false }') | Should -BeGreaterThan 0 -Because 'a rebuilt service guest has new host keys'
        $builder.IndexOf('{ Reset-GuestHostKeyPin -VMName $VMName -Confirm:$false }') | Should -BeLessThan $builder.IndexOf('Invoke-YurunaServiceVmBuilderRun')
        # Adoption keeps the running VM, and with it the pin: the reset lives only
        # on the rebuild path, never in the adoption decision.
        $adoptFn = Get-YurunaTestFunctionAst -Path (Join-Path $root 'test/modules/Test.ServiceVm.psm1') -Name 'Resolve-YurunaServiceVmAdoption'
        $adoptFn.Extent.Text | Should -Not -Match 'Reset-GuestHostKeyPin'
        foreach ($start in @('Start-StashServiceVM.ps1', 'Start-PoolControlServiceVM.ps1', 'Start-DownloadAgentServiceVM.ps1')) {
            # What the start runs: the shared pipeline with its service's readiness part.
            $startText = Get-YurunaServiceStartText -Path (Join-Path $root "test/service/$start")
            $startText | Should -Match 'Invoke-YurunaServiceVmBuild -BuilderPath' -Because "$start rebuilds only through the shared builder"
            $startText.IndexOf("'Test.Ssh.psm1'") | Should -BeLessThan $startText.IndexOf('Invoke-YurunaServiceVmBuild -BuilderPath') -Because "the builder's pin reset needs Test.Ssh loaded in $start"
            $startText.IndexOf("'Test.Ssh.psm1'") | Should -BeGreaterThan 0
            $startText | Should -Not -Match 'Reset-GuestHostKeyPin' -Because "$start adopts without forgetting the pin"
        }
        $proxy = Get-Content -LiteralPath (Join-Path $root 'test/service/Start-CachingProxyServiceVM.ps1') -Raw
        $proxy.IndexOf('Reset-GuestHostKeyPin -VMName $VMName -Confirm:$false') | Should -BeLessThan $proxy.IndexOf('Invoke-YurunaServiceVmBuilderRun -BuilderPath $NewVMScript') -Because 'the cache forgets the pin right before its builder runs'
        $proxy.IndexOf('Reset-GuestHostKeyPin -VMName $VMName -Confirm:$false') | Should -BeGreaterThan $proxy.IndexOf('# --- REGION: Create the VM')
        $proxy.IndexOf('Reset-GuestHostKeyPin') | Should -BeGreaterThan $proxy.IndexOf('# --- REGION: Adopt a healthy VM') -Because 'the cache adopts first and forgets the pin only when it rebuilds'
    }
}

Describe 'Get-GuestAddress' {
    It 'reads the Hyper-V KVP addresses itself only when no driver Get-VMIp is loaded' {
        # The driver's Get-VMIp reads these addresses under its cap; a second,
        # uncapped read after it found none would hold the caller when the
        # service is what failed to answer. The read is gated on Windows, so its
        # placement is pinned by structure rather than by running it.
        $fn = Get-YurunaTestFunctionAst -Path $modulePath -Name 'Get-GuestAddress'
        $reads = @($fn.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-VMNetworkAdapter' }, $true))
        Assert-Equal 1 $reads.Count 'one raw KVP read'
        $offset = $reads[0].Extent.StartOffset
        $clause = $null
        for ($node = $reads[0].Parent; $null -ne $node -and $null -eq $clause; $node = $node.Parent) {
            if ($node -is [Management.Automation.Language.IfStatementAst]) {
                $clause = $node.Clauses | Where-Object { $_.Item2.Extent.StartOffset -le $offset -and $offset -lt $_.Item2.Extent.EndOffset } | Select-Object -First 1
            }
        }
        Assert-NotNull $clause 'the read sits in an if clause'
        $condition = $clause.Item1.Extent.Text
        # Negated inline, or through a variable assigned from the driver lookup.
        $negated = $condition -match '-not\s*\(\s*Get-Command\s+Get-VMIp\b'
        foreach ($match in [regex]::Matches($condition, '-not\s+\$(\w+)')) {
            $name = $match.Groups[1].Value
            $assigned = $fn.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$$name" -and $n.Right.Extent.Text -match '^Get-Command\s+Get-VMIp\b' }, $true)
            if ($assigned) { $negated = $true }
        }
        Assert-True $negated "the KVP read runs only when no driver Get-VMIp is loaded: if ($condition)"
    }
}
