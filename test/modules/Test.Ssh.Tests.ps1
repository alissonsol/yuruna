<#PSScriptInfo
.VERSION 2026.08.25
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
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). The classifier
    is pure (inputs: IpDiscovered + LastError), so no guest, no network, no
    module state is involved.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Ssh.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
