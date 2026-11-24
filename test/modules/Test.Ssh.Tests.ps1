<#PSScriptInfo
.VERSION 2026.11.23
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

    It 'keeps a banner exchange timeout distinct from an unreachable network path' {
        foreach ($discovered in @($false, $true)) {
            Get-SshReadinessFailureCause -IpDiscovered $discovered -IpAnswered $true `
                -LastError 'Connection timed out during banner exchange' | Should -Be 'probe_timeout'
        }
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

Describe 'Read-only harness SSH key inspection' {
    BeforeAll {
        $script:KeyModule = Get-Module Test.Ssh
        $script:Keygen = Get-Command ssh-keygen -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $script:SavedKeyPaths = & $script:KeyModule {
            @{ Directory=$script:SshKeyDir; Private=$script:SshKeyPath; Public=$script:SshPubPath; Cached=$script:CachedSshKey }
        }

        function New-SshFixturePair {
            <# Create an isolated native key pair for observable read-only checks. #>
            [CmdletBinding(SupportsShouldProcess)]
            param([string]$Path, [switch]$Encrypted)
            if (-not $PSCmdlet.ShouldProcess($Path, 'Create a test SSH key pair')) { return }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
            $fixturePhrase = if ($Encrypted) { 'fixture-passphrase' } else { '' }
            & $script:Keygen.Source -q -t ed25519 -N $fixturePhrase -C fixture -f $Path
            if ($LASTEXITCODE -ne 0) { throw 'Fixture ssh-keygen failed.' }
        }

        function Get-SshFixtureSnapshot {
            <# Capture names, contents, write times and permissions without exposing key bytes. #>
            param([string]$Path)
            $items = @((Get-Item -LiteralPath $Path)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)
            $entries = foreach ($item in $items | Sort-Object FullName) {
                # Windows directory enumeration can return metadata cached before fixture writes.
                $item.Refresh()
                [ordered]@{
                    name = $item.FullName.Substring($Path.Length)
                    directory = $item.PSIsContainer
                    hash = $(if (-not $item.PSIsContainer) { (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash })
                    written = $item.LastWriteTimeUtc.Ticks
                    permissions = $(if ($IsWindows) { (Get-Acl -LiteralPath $item.FullName).Sddl }
                        else { [int][IO.File]::GetUnixFileMode($item.FullName) })
                }
            }
            return ConvertTo-Json -InputObject @($entries) -Depth 4 -Compress
        }
    }

    BeforeEach {
        $script:KeyFixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:KeyFixtureRoot
        $script:KeyDirectory = Join-Path $script:KeyFixtureRoot 'keys'
        $script:PrivateKey = Join-Path $script:KeyDirectory 'yuruna_ed25519'
        $script:PublicKey = "$script:PrivateKey.pub"
        & $script:KeyModule {
            param($Directory)
            $script:SshKeyDir = $Directory
            $script:SshKeyPath = Join-Path $Directory 'yuruna_ed25519'
            $script:SshPubPath = "$script:SshKeyPath.pub"
            $script:CachedSshKey = $null
        } $script:KeyDirectory
    }

    AfterEach {
        & $script:KeyModule {
            param($Saved)
            $script:SshKeyDir = $Saved.Directory
            $script:SshKeyPath = $Saved.Private
            $script:SshPubPath = $Saved.Public
            $script:CachedSshKey = $Saved.Cached
        } $script:SavedKeyPaths
    }

    It 'snapshots current directory metadata instead of stale enumeration values' {
        $null=[IO.Directory]::CreateDirectory($script:KeyDirectory)
        $script:StaleSnapshotDirectory=Get-Item -LiteralPath $script:KeyDirectory
        $null=$script:StaleSnapshotDirectory.LastWriteTimeUtc
        $expected=[datetime]::new(2025,1,2,3,4,5,[DateTimeKind]::Utc)
        [IO.Directory]::SetLastWriteTimeUtc($script:KeyDirectory,$expected)
        Mock Get-ChildItem { $script:StaleSnapshotDirectory } -ParameterFilter { $LiteralPath -eq $script:KeyFixtureRoot }

        $snapshot=@(Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | ConvertFrom-Json)
        ($snapshot | Where-Object { $_.name -eq [IO.Path]::DirectorySeparatorChar+'keys' }).written | Should -Be $expected.Ticks
        $changed=$expected.AddMinutes(1)
        [IO.Directory]::SetLastWriteTimeUtc($script:KeyDirectory,$changed)
        $snapshot=@(Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | ConvertFrom-Json)
        ($snapshot | Where-Object { $_.name -eq [IO.Path]::DirectorySeparatorChar+'keys' }).written | Should -Be $changed.Ticks
    }

    It 'plans a missing key without creating its directory or files' {
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        Get-YurunaSshPublicKey -ReadOnly | Should -BeNullOrEmpty
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
        Test-Path -LiteralPath $script:KeyDirectory | Should -BeFalse
    }

    It 'plans a missing pair in an existing directory without changing its permissions' {
        $null = New-Item -ItemType Directory -Path $script:KeyDirectory
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($script:KeyDirectory, [IO.UnixFileMode]488) }
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        Get-YurunaSshPublicKey -ReadOnly | Should -BeNullOrEmpty
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'returns the existing matching public key without altering files or permissions' {
        New-SshFixturePair -Path $script:PrivateKey
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($script:KeyDirectory, [IO.UnixFileMode]488)
            [IO.File]::SetUnixFileMode($script:PrivateKey, [IO.UnixFileMode]256)
            [IO.File]::SetUnixFileMode($script:PublicKey, [IO.UnixFileMode]416)
        }
        $expected = (Get-Content -LiteralPath $script:PublicKey -Raw).Trim()
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        Get-YurunaSshPublicKey -ReadOnly | Should -BeExactly $expected
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'refuses <State> without repairing or changing any existing material' -ForEach @(
        @{ State='malformed-private'; Reason='private-key-unusable' },
        @{ State='encrypted-private'; Reason='private-key-unusable' },
        @{ State='malformed-public'; Reason='public-key-invalid-or-mismatched' },
        @{ State='mismatched-public'; Reason='public-key-invalid-or-mismatched' },
        @{ State='missing-private'; Reason='incomplete-key-pair' },
        @{ State='missing-public'; Reason='incomplete-key-pair' },
        @{ State='private-directory'; Reason='invalid-key-file' },
        @{ State='public-directory'; Reason='invalid-key-file' }
    ) {
        New-SshFixturePair -Path $script:PrivateKey -Encrypted:($State -eq 'encrypted-private')
        switch ($State) {
            malformed-private { Set-Content -LiteralPath $script:PrivateKey -Value 'invalid fixture private key' }
            malformed-public { Set-Content -LiteralPath $script:PublicKey -Value 'invalid fixture public key' }
            mismatched-public {
                $other = Join-Path $script:KeyFixtureRoot 'other'
                New-SshFixturePair -Path $other
                Copy-Item -LiteralPath "$other.pub" -Destination $script:PublicKey
            }
            missing-private { Remove-Item -LiteralPath $script:PrivateKey }
            missing-public { Remove-Item -LiteralPath $script:PublicKey }
            private-directory {
                Remove-Item -LiteralPath $script:PrivateKey
                $null = New-Item -ItemType Directory -Path $script:PrivateKey
            }
            public-directory {
                Remove-Item -LiteralPath $script:PublicKey
                $null = New-Item -ItemType Directory -Path $script:PublicKey
            }
        }
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        { Get-YurunaSshPublicKey -ReadOnly } | Should -Throw -ExpectedMessage "*$Reason*"
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'refuses a file blocking the <Location> key-directory path without mutation' -ForEach @(
        @{ Location='immediate' }, @{ Location='ancestor' }
    ) {
        Set-Content -LiteralPath $script:KeyDirectory -Value 'keep blocking file'
        if ($Location -eq 'ancestor') {
            $script:KeyDirectory = Join-Path $script:KeyDirectory 'nested'
            & $script:KeyModule { $script:SshKeyDir = $args[0]; $script:SshKeyPath = Join-Path $args[0] 'yuruna_ed25519'; $script:SshPubPath = "$script:SshKeyPath.pub" } $script:KeyDirectory
        }
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        { Get-YurunaSshPublicKey -ReadOnly } | Should -Throw -ExpectedMessage '*invalid-key-directory*'
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'refuses a planned creation when ssh-keygen is missing without making directories' {
        Mock Get-Command -ModuleName Test.Ssh { $null } -ParameterFilter { $Name -eq 'ssh-keygen' }
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        { Get-YurunaSshPublicKey -ReadOnly } | Should -Throw -ExpectedMessage '*ssh-keygen not found*'
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'does not mistake denied key-file access for an absent pair under ErrorAction Continue' {
        New-SshFixturePair -Path $script:PrivateKey
        Mock Test-Path -ModuleName Test.Ssh {
            if ($PathType) { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType }
            else { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath }
        }
        Mock Test-Path -ModuleName Test.Ssh {
            Write-Error -Message 'fixture key path access denied' -Category PermissionDenied
            return $false
        } -ParameterFilter { [IO.Path]::GetFileName($LiteralPath) -in @('yuruna_ed25519', 'yuruna_ed25519.pub') }
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        { Get-YurunaSshPublicKey -ReadOnly -ErrorAction Continue 2>$null } | Should -Throw -ExpectedMessage '*invalid-key-file*'
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'still creates a usable key pair during a normal build and keeps it on later calls' {
        $public = Get-YurunaSshPublicKey
        $public | Should -Match '^ssh-ed25519 '
        $public | Should -BeExactly (Get-Content -LiteralPath $script:PublicKey -Raw).Trim()
        & $script:Keygen.Source -y -P '' -f $script:PrivateKey | Should -Not -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
        $before = Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot
        Get-YurunaSshPublicKey | Should -BeExactly $public
        Get-SshFixtureSnapshot -Path $script:KeyFixtureRoot | Should -BeExactly $before
    }

    It 'retains normal-build replacement of an unusable legacy encrypted key' {
        New-SshFixturePair -Path $script:PrivateKey -Encrypted
        $before = (Get-FileHash -LiteralPath $script:PrivateKey -Algorithm SHA256).Hash
        Get-YurunaSshPublicKey -WarningAction SilentlyContinue | Should -Match '^ssh-ed25519 '
        (Get-FileHash -LiteralPath $script:PrivateKey -Algorithm SHA256).Hash | Should -Not -BeExactly $before
        & $script:Keygen.Source -y -P '' -f $script:PrivateKey | Should -Not -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'hardens an existing native key without replacing its material' {
        New-SshFixturePair -Path $script:PrivateKey
        if ($IsWindows) {
            $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
            $initial=Get-Acl -LiteralPath $script:PrivateKey
            $initial.AreAccessRulesProtected | Should -BeTrue
            $initial.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly $sid.Value
        }
        $hash=(Get-FileHash -LiteralPath $script:PrivateKey -Algorithm SHA256).Hash
        $publicHash=(Get-FileHash -LiteralPath $script:PublicKey -Algorithm SHA256).Hash

        Initialize-YurunaSshKey | Should -BeExactly $script:PrivateKey

        (Get-FileHash -LiteralPath $script:PrivateKey -Algorithm SHA256).Hash | Should -BeExactly $hash
        (Get-FileHash -LiteralPath $script:PublicKey -Algorithm SHA256).Hash | Should -BeExactly $publicHash
        if ($IsWindows) {
            $written=Get-Acl -LiteralPath $script:PrivateKey
            $written.AreAccessRulesProtected | Should -BeTrue
            $written.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly $sid.Value
            $rules=@($written.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
            $rules | Should -HaveCount 1
            $rules[0].IdentityReference.Value | Should -BeExactly $sid.Value
            $rules[0].IsInherited | Should -BeFalse
            $rules[0].AccessControlType | Should -Be ([Security.AccessControl.AccessControlType]::Allow)
            $rules[0].FileSystemRights | Should -Be ([Security.AccessControl.FileSystemRights]::FullControl)

            Mock Get-Acl -ModuleName Test.Ssh {
                $acl=Microsoft.PowerShell.Security\Get-Acl -LiteralPath $LiteralPath
                $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
                return $acl
            }
            Mock Set-Acl -ModuleName Test.Ssh { throw 'fixture-owner-repair-denied' }
            { Initialize-YurunaSshKey } | Should -Throw -ExpectedMessage "*$script:PrivateKey*fixture-owner-repair-denied*"
            Should -Invoke Set-Acl -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter {
                $AclObject.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            }
        } else {
            [IO.File]::GetUnixFileMode($script:PrivateKey) | Should -Be ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
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

Describe 'Invoke-GuestSshPasswordRotation' {
    # A scripted client stands in for ssh: it prints the prompts a guest's PAM
    # prints, reads each answer from its input like the guest's terminal would,
    # and writes what it received to a file the case reads back.
    BeforeAll {
        Import-Module (Join-Path $here 'Test.Log.psm1') -Global -Force -DisableNameChecking
        Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Global -Force -DisableNameChecking
        $script:Pwsh = (Get-Process -Id $PID).Path
        $script:Current = 'Fixture-Current-7351'
        $script:New = 'Fixture-New-9024'
        $script:StandIn = Join-Path $TestDrive 'ssh-stand-in.ps1'
        Set-Content -LiteralPath $script:StandIn -Encoding utf8NoBOM -Value @'
param([string]$Mode, [string]$AnswerFile)
$out = [Console]::Out
function Send-Text([string]$Text) { $out.Write($Text); $out.Flush() }
function Read-Answer([string]$Prompt) {
    Send-Text $Prompt
    $line = [Console]::In.ReadLine()
    # $null is the client closing its input, which is no answer.
    if ($null -ne $line) { Add-Content -LiteralPath $AnswerFile -Value $line }
    Send-Text "`r`n"
    return $line
}
$banner = "WARNING: Your password has expired.`r`nYou are required to change your password immediately (administrator enforced).`r`nChanging password for fixture.`r`n"
switch ($Mode) {
    'ubuntu26' {
        Send-Text $banner
        $null = Read-Answer 'Current password: '; $null = Read-Answer 'New password: '; $null = Read-Answer 'Retype new password: '
        Send-Text "yuruna-ssh-rotated`r`n"
    }
    'ubuntu24' {
        Send-Text $banner
        $null = Read-Answer '(current) UNIX password: '; $null = Read-Answer 'Enter new UNIX password: '; $null = Read-Answer 'Retype new UNIX password: '
        Send-Text "passwd: password updated successfully`r`n"
        Start-Sleep -Seconds 60
    }
    'refused' {
        $null = Read-Answer 'Current password: '; $null = Read-Answer 'New password: '; $null = Read-Answer 'Retype new password: '
        Send-Text "Sorry, passwords do not match.`r`npasswd: Authentication token manipulation error`r`n"
        Start-Sleep -Seconds 60
    }
    'reprompt' {
        $null = Read-Answer 'Current password: '; $null = Read-Answer 'New password: '; $null = Read-Answer 'Retype new password: '
        $null = Read-Answer 'New password: '
    }
    'newfirst' { $null = Read-Answer 'New password: ' }
    'hang' { Send-Text 'Current password: '; Start-Sleep -Seconds 60 }
    'nochange' { Send-Text "yuruna-ssh-rotated`r`n" }
    'silent' { $null = Read-Answer 'Current password: '; $null = Read-Answer 'New password: '; $null = Read-Answer 'Retype password: ' }
    'echo' {
        foreach ($prompt in 'Current password: ', 'New password: ', 'Retype new password: ') { Send-Text ((Read-Answer $prompt) + "`r`n") }
        Send-Text "yuruna-ssh-rotated`r`n"
    }
}
'@
        $script:RotationArguments = @{ VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'; Username = 'fixture'
            CurrentPassword = $script:Current; NewPassword = $script:New; TimeoutSeconds = 20 }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-YurunaSshHostKeyOption -ModuleName Test.Ssh { return @('-o', 'StrictHostKeyChecking=yes') }
    }
    BeforeEach {
        $script:AnswerFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:Mode = ''
        $script:ClientIds = [System.Collections.Generic.List[int]]::new()
        $script:Events = [System.Collections.Generic.List[hashtable]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.Ssh { $script:Events.Add($EventRecord) }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh { throw 'no probe expected' }
        Mock Start-GuestSshRotationClient -ModuleName Test.Ssh {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $script:StandIn, $script:Mode, $script:AnswerFile)) { $startInfo.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $script:ClientIds.Add($process.Id)
            return $process
        }
    }
    AfterEach {
        foreach ($id in $script:ClientIds) {
            $left = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($left -and $left.Path -eq $script:Pwsh) { $left.Kill() }
        }
    }

    It 'answers the <Mode> prompts in order and succeeds on the guest''s confirmation' -TestCases @(
        @{ Mode = 'ubuntu26' }, @{ Mode = 'ubuntu24' }
    ) {
        param($Mode)
        $script:Mode = $Mode
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 15 -Because 'a client that lingers after the confirmation is ended'
        $result.Ok | Should -BeTrue -Because $result.Detail
        $result.Code | Should -BeExactly ''
        $result.Answered | Should -Be 3
        $result.Target | Should -BeExactly 'fixture@192.0.2.10'
        @(Get-Content -LiteralPath $script:AnswerFile) | Should -Be @($script:Current, $script:New, $script:New)
        Get-Process -Id $script:ClientIds[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq '-tt' -and $ArgumentList -contains 'fixture@192.0.2.10' -and $ArgumentList -contains 'StrictHostKeyChecking=yes'
        }
    }

    It 'stops at a refusal from PAM without answering again' {
        $script:Mode = 'refused'
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'refused'
        $result.Detail | Should -Match 'Authentication token manipulation error'
        @(Get-Content -LiteralPath $script:AnswerFile).Count | Should -Be 3
        Get-Process -Id $script:ClientIds[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'does not answer a prompt asked again after the last answer' {
        $script:Mode = 'reprompt'
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $result.Code | Should -BeExactly 'refused'
        @(Get-Content -LiteralPath $script:AnswerFile).Count | Should -Be 3 -Because 'a fourth answer would type a password into whatever the guest asked next'
    }

    It 'answers nothing when the prompts come out of order' {
        $script:Mode = 'newfirst'
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $result.Code | Should -BeExactly 'unexpected-prompt'
        $result.Answered | Should -Be 0
        Test-Path -LiteralPath $script:AnswerFile | Should -BeFalse
    }

    It 'reports not-expired, not a rotation, when the login needed no change' {
        $script:Mode = 'nochange'
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $result.Ok | Should -BeFalse -Because 'the vault must not take a password the guest never got'
        $result.Code | Should -BeExactly 'not-expired'
    }

    It 'ends a client that never finishes within the timeout' {
        $script:Mode = 'hang'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments -TimeoutSeconds 3
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'timeout'
        Get-Process -Id $script:ClientIds[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $script:Events.Count | Should -Be 1
        $script:Events[0].failureClass | Should -BeExactly 'credential_expired'
        $script:Events[0].severity | Should -BeExactly 'hard'
    }

    It 'reports and records a timeout without connecting when no time is left' {
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments -TimeoutSeconds 0
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'timeout'
        $result.Answered | Should -Be 0
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 0 -Exactly
        $script:Events.Count | Should -Be 1
        $script:Events[0].event | Should -BeExactly 'ssh_password_rotation'
        $script:Events[0].ok | Should -BeFalse
        $script:Events[0].code | Should -BeExactly 'timeout'
        $script:Events[0].target | Should -BeExactly 'fixture@192.0.2.10'
        $script:Events[0].failureClass | Should -BeExactly 'credential_expired'
        $script:Events[0].severity | Should -BeExactly 'hard'
        @(Test-CycleEventSchema -Record $script:Events[0]).Count | Should -Be 0
    }

    It 'judges a session that ends silently after the last answer by one probe that answers <Probe>' -TestCases @(
        @{ Probe = 'expired'; ExitCode = 255; Text = 'You are required to change your password immediately (administrator enforced). Password change required but no TTY available'; Ok = $false; Code = 'still-expired' }
        @{ Probe = 'ready'; ExitCode = 0; Text = 'yuruna-ssh-ready'; Ok = $true; Code = '' }
    ) {
        param($Probe, $ExitCode, $Text, $Ok, $Code)
        $null = $Probe
        $script:Mode = 'silent'
        $script:ProbeAnswer = @{ Started = $true; ExitCode = $ExitCode; StdOut = ''; StdErr = $Text; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh { return $script:ProbeAnswer }
        $result = Invoke-GuestSshPasswordRotation @script:RotationArguments
        $result.Ok | Should -Be $Ok
        $result.Code | Should -BeExactly $Code
        $result.Answered | Should -Be 3
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains 'BatchMode=yes' -and $ArgumentList -notcontains '-tt' }
    }

    It 'keeps both passwords out of the result, the event, the arguments and the verbose stream' {
        $script:Mode = 'echo'
        $verbose = Invoke-GuestSshPasswordRotation @script:RotationArguments -Verbose 4>&1
        $result = @($verbose | Where-Object { $_ -is [hashtable] })[0]
        $result.Ok | Should -BeTrue -Because $result.Detail
        $result.Detail | Should -Match '\*\*\*' -Because 'the guest echoed the answers, and the echo is kept masked'
        $everything = (@($verbose | ForEach-Object { [string]$_ }) -join "`n") + (ConvertTo-Json -InputObject $result -Depth 6) + (ConvertTo-Json -InputObject @($script:Events) -Depth 6)
        $everything.Contains($script:Current) | Should -BeFalse
        $everything.Contains($script:New) | Should -BeFalse
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ').Contains($script:Current) -eq $false -and ($ArgumentList -join ' ').Contains($script:New) -eq $false
        }
        $script:Events.Count | Should -Be 1
        $script:Events[0].event | Should -BeExactly 'ssh_password_rotation'
        $script:Events[0].ok | Should -BeTrue
        $script:Events[0].ContainsKey('failureClass') | Should -BeFalse
        @(Test-CycleEventSchema -Record $script:Events[0]).Count | Should -Be 0
    }
}

Describe 'Set-GuestSshPassword' {
    # A scripted client stands in for ssh: it reads its whole input like the
    # remote chpasswd would, writes what it received to a file the case reads
    # back, and answers the way a guest's sudo and chpasswd do.
    BeforeAll {
        Import-Module (Join-Path $here 'Test.Log.psm1') -Global -Force -DisableNameChecking
        Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Global -Force -DisableNameChecking
        $script:Pwsh = (Get-Process -Id $PID).Path
        $script:New = 'Fixture-New-9024'
        $script:StandIn = Join-Path $TestDrive 'ssh-set-stand-in.ps1'
        Set-Content -LiteralPath $script:StandIn -Encoding utf8NoBOM -Value @'
param([string]$Mode, [string]$InputFile)
if ($Mode -eq 'hang') { Start-Sleep -Seconds 60; exit 0 }
$received = [Console]::In.ReadToEnd()
Set-Content -LiteralPath $InputFile -Value $received -NoNewline
switch ($Mode) {
    'ok' { [Console]::Out.Write("yuruna-ssh-password-set`n"); exit 0 }
    'echo' { [Console]::Out.Write("$received" + "yuruna-ssh-password-set`n"); exit 0 }
    'sudo' { [Console]::Error.Write("sudo: a password is required`n"); exit 1 }
    'chpasswd' { [Console]::Error.Write("chpasswd: (user fixture) pam_chauthtok() failed, error:`nAuthentication token manipulation error`n"); exit 1 }
    'warned' { [Console]::Error.Write("chpasswd: (line 1, user fixture) password not changed`n"); [Console]::Out.Write("yuruna-ssh-password-set`n"); exit 0 }
    'transport' { [Console]::Error.Write("Connection to 192.0.2.10 closed by remote host.`n"); exit 255 }
}
'@
        $script:SetArguments = @{ VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'; Username = 'fixture'
            NewPassword = $script:New; TimeoutSeconds = 20 }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-YurunaSshHostKeyOption -ModuleName Test.Ssh { return @('-o', 'StrictHostKeyChecking=yes') }
    }
    BeforeEach {
        $script:InputFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.txt')
        $script:Mode = ''
        $script:ClientIds = [System.Collections.Generic.List[int]]::new()
        $script:ClientLines = [System.Collections.Generic.List[string]]::new()
        $script:Events = [System.Collections.Generic.List[hashtable]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.Ssh { $script:Events.Add($EventRecord) }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh { throw 'no probe expected' }
        Mock Start-GuestSshRotationClient -ModuleName Test.Ssh {
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardInput = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
            foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $script:StandIn, $script:Mode, $script:InputFile)) { $startInfo.ArgumentList.Add($argument) }
            $process = [System.Diagnostics.Process]::Start($startInfo)
            $script:ClientIds.Add($process.Id)
            # The command line the operating system holds for the client: what
            # any other process on the host could read.
            $script:ClientLines.Add((Get-Process -Id $process.Id -ErrorAction SilentlyContinue).CommandLine)
            return $process
        }
    }
    AfterEach {
        foreach ($id in $script:ClientIds) {
            $left = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($left -and $left.Path -eq $script:Pwsh) { $left.Kill() }
        }
    }

    It 'gives the password to sudo -n chpasswd only on standard input and succeeds on the marker' {
        $script:Mode = 'ok'
        $result = Set-GuestSshPassword @script:SetArguments
        $result.Ok | Should -BeTrue -Because $result.Detail
        $result.Code | Should -BeExactly ''
        $result.ExitCode | Should -Be 0
        $result.Target | Should -BeExactly 'fixture@192.0.2.10'
        Get-Content -LiteralPath $script:InputFile -Raw | Should -BeExactly "fixture:$($script:New)`n"
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq '-T' -and $ArgumentList -notcontains '-tt' -and $ArgumentList -contains 'fixture@192.0.2.10' -and
                $ArgumentList -contains 'StrictHostKeyChecking=yes' -and $ArgumentList[-1] -eq 'sudo -n chpasswd && echo yuruna-ssh-password-set' -and
                -not ($ArgumentList -join ' ').Contains($script:New)
        }
        foreach ($line in $script:ClientLines) { ([string]$line).Contains($script:New) | Should -BeFalse }
        Get-Process -Id $script:ClientIds[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $script:Events.Count | Should -Be 1
        $script:Events[0].event | Should -BeExactly 'ssh_password_set'
        $script:Events[0].ok | Should -BeTrue
        $script:Events[0].ContainsKey('failureClass') | Should -BeFalse
        @(Test-CycleEventSchema -Record $script:Events[0]).Count | Should -Be 0
    }

    It 'fails with <Code> when the guest answers <Mode>' -TestCases @(
        @{ Mode = 'sudo'; Code = 'sudo-refused'; Text = 'sudo: a password is required' }
        @{ Mode = 'chpasswd'; Code = 'chpasswd-failed'; Text = 'Authentication token manipulation error' }
        @{ Mode = 'warned'; Code = 'chpasswd-failed'; Text = 'password not changed' }
        @{ Mode = 'transport'; Code = 'ssh-failed'; Text = 'closed by remote host' }
    ) {
        param($Mode, $Code, $Text)
        $script:Mode = $Mode
        $result = Set-GuestSshPassword @script:SetArguments
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly $Code
        $result.Dispatched | Should -BeTrue -Because 'the client started, so the guest may have received the password'
        $result.Detail | Should -Match ([regex]::Escape($Text))
        $script:Events.Count | Should -Be 1
        $script:Events[0].ok | Should -BeFalse
        $script:Events[0].failureClass | Should -BeExactly 'provisioning_failure'
        $script:Events[0].severity | Should -BeExactly 'hard'
        @(Test-CycleEventSchema -Record $script:Events[0]).Count | Should -Be 0
    }

    It 'ends a client that never finishes within the timeout' {
        $script:Mode = 'hang'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Set-GuestSshPassword @script:SetArguments -TimeoutSeconds 3
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'timeout'
        Get-Process -Id $script:ClientIds[0] -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $script:Events.Count | Should -Be 1
        $script:Events[0].code | Should -BeExactly 'timeout'
    }

    It 'keeps the password out of the result, the event and the verbose stream when the guest echoes it' {
        $script:Mode = 'echo'
        $verbose = Set-GuestSshPassword @script:SetArguments -Verbose 4>&1
        $result = @($verbose | Where-Object { $_ -is [hashtable] })[0]
        $result.Ok | Should -BeTrue -Because $result.Detail
        $result.Detail | Should -Match 'fixture:\*\*\*' -Because 'the echoed line is kept masked'
        $everything = (@($verbose | ForEach-Object { [string]$_ }) -join "`n") + (ConvertTo-Json -InputObject $result -Depth 6) + (ConvertTo-Json -InputObject @($script:Events) -Depth 6)
        $everything.Contains($script:New) | Should -BeFalse
    }

    It 'refuses a password with a line break before it connects' {
        $result = Set-GuestSshPassword @script:SetArguments -NewPassword "Fixture`nSecond-Line"
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'invalid-password'
        $result.Dispatched | Should -BeFalse
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 0 -Exactly
        $script:Events.Count | Should -Be 1
        ([string]$script:Events[0].detail).Contains('Second-Line') | Should -BeFalse
    }

    It 'reports and records a timeout without connecting when no time is left' {
        $result = Set-GuestSshPassword @script:SetArguments -TimeoutSeconds 0
        $result.Ok | Should -BeFalse
        $result.Code | Should -BeExactly 'timeout'
        $result.Dispatched | Should -BeFalse
        Should -Invoke Start-GuestSshRotationClient -ModuleName Test.Ssh -Times 0 -Exactly
        $script:Events.Count | Should -Be 1
        $script:Events[0].event | Should -BeExactly 'ssh_password_set'
        $script:Events[0].ok | Should -BeFalse
        $script:Events[0].code | Should -BeExactly 'timeout'
        $script:Events[0].target | Should -BeExactly 'fixture@192.0.2.10'
        $script:Events[0].failureClass | Should -BeExactly 'provisioning_failure'
        $script:Events[0].severity | Should -BeExactly 'hard'
        @(Test-CycleEventSchema -Record $script:Events[0]).Count | Should -Be 0
    }
}

Describe 'Wait-SshReady on an expired password' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.Log.psm1') -Global -Force -DisableNameChecking
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-GuestSshUser -ModuleName Test.Ssh { return 'fixture-user' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Set-ProvenGuestAddress -ModuleName Test.Ssh { }
    }
    BeforeEach {
        $script:Events = [System.Collections.Generic.List[hashtable]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.Ssh { $script:Events.Add($EventRecord) }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            return @{ Started = $true; ExitCode = 255; StdOut = ''
                StdErr = 'You are required to change your password immediately (administrator enforced). Password change required but no TTY available'
                TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
        }
    }

    It 'returns at the first expired answer and reports nothing with Return' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Wait-SshReady -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 30 -PollSeconds 1 -OnExpiredLogin Return | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        (Get-LastSshReadiness).cause | Should -BeExactly 'password_expired'
        (Get-LastSshReadiness).attempts | Should -Be 1
        $script:Events.Count | Should -Be 0 -Because 'the caller is about to repair the account'
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly
    }

    It 'fails at the first expired answer with the credential_expired report with Fail' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        Wait-SshReady -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 30 -PollSeconds 1 -OnExpiredLogin Fail | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 10
        (Get-LastSshReadiness).attempts | Should -Be 1
        $script:Events.Count | Should -Be 1
        $script:Events[0].event | Should -BeExactly 'ssh_handshake_failed'
        $script:Events[0].cause | Should -BeExactly 'password_expired'
        $script:Events[0].failureClass | Should -BeExactly 'credential_expired'
    }

    It 'keeps waiting by default, as for any other answer' {
        Wait-SshReady -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 3 -PollSeconds 1 | Should -BeFalse
        (Get-LastSshReadiness).attempts | Should -BeGreaterThan 1
        $script:Events.Count | Should -Be 1
    }
}

Describe 'Wait-SshReady and a host key pin no login confirmed' {
    # A fresh guest's live installer answers SSH with its own host key before
    # the installed system does, and accept-new pins whatever key the first
    # handshake shows. The stand-in client below pins like accept-new: it
    # records the guest's current key when the pin is absent and refuses a
    # different one, then answers as the scripted guest does.
    BeforeAll {
        $script:UnconfirmedPinRoot = New-YurunaTestTempDir -Prefix 'yuruna-pin-unconfirmed'
        $script:UnconfirmedPinDir = Join-Path $script:UnconfirmedPinRoot 'pins'
        & (Get-Module Test.Ssh) { $script:SavedPinDir = $script:HostKeyPinDir; $script:HostKeyPinDir = $args[0] } $script:UnconfirmedPinDir
        $script:GuestPin = Join-Path $script:UnconfirmedPinDir 'fixture-guest'
        Import-Module (Join-Path $here '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-GuestSshUser -ModuleName Test.Ssh { return 'fixture-user' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Set-ProvenGuestAddress -ModuleName Test.Ssh { }
        Mock Send-CycleEventSafely -ModuleName Test.Ssh { }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            $turn = $script:GuestScript[[Math]::Min($script:GuestCalls, $script:GuestScript.Count - 1)]
            $script:GuestCalls++
            $answer = @{ Started = $true; ExitCode = 255; StdOut = ''; StdErr = ''; TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false }
            if (-not (Test-Path -LiteralPath $script:GuestPin)) {
                Set-Content -LiteralPath $script:GuestPin -Value $turn.Key -NoNewline
            } elseif ((Get-Content -LiteralPath $script:GuestPin -Raw) -ne $turn.Key) {
                $answer.StdErr = "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@`nOffending ED25519 key in $($script:GuestPin):1`nHost key verification failed."
                return $answer
            }
            switch ($turn.Answer) {
                'ready' { $answer.ExitCode = 0; $answer.StdOut = 'yuruna-ssh-ready' }
                'expired' { $answer.StdErr = 'You are required to change your password immediately (administrator enforced). Password change required but no TTY available' }
                default { $answer.StdErr = 'fixture-user@192.0.2.10: Permission denied (publickey,password).' }
            }
            return $answer
        }
    }
    AfterAll {
        & (Get-Module Test.Ssh) { $script:HostKeyPinDir = $script:SavedPinDir }
        Remove-YurunaTestTempDir $script:UnconfirmedPinRoot
    }
    BeforeEach {
        $script:GuestCalls = 0
        [void][IO.Directory]::CreateDirectory($script:UnconfirmedPinDir)
        Remove-Item -LiteralPath $script:GuestPin -Force -ErrorAction SilentlyContinue
        & (Get-Module Test.Ssh) { $script:ConfirmedHostKeyPin.Clear() }
    }

    It 'forgets the installer''s pin when the installed system presents its own key, and reaches a shell' {
        $script:GuestScript = @(@{ Key = 'installer'; Answer = 'denied' }, @{ Key = 'installed'; Answer = 'ready' })
        $warnings = @()
        $ready = Wait-SshReady -VMName fixture-guest -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 20 -PollSeconds 1 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } else { $_ } }
        $ready | Should -BeTrue
        (Get-LastSshReadiness).cause | Should -BeExactly 'ready'
        Get-Content -LiteralPath $script:GuestPin -Raw | Should -BeExactly 'installed'
        $warnings.Count | Should -Be 1
        $warnings[0] | Should -BeExactly (Format-YurunaOperatorMessage -Key 'runner.ssh_host_key_pin_unconfirmed_reset' -Arguments @{
                vmName = 'fixture-guest'; address = '192.0.2.10'; pin = $script:GuestPin; count = 1; limit = 3 })
    }

    It 'keeps refusing a changed key when the pin predates the wait' {
        Set-Content -LiteralPath $script:GuestPin -Value 'earlier' -NoNewline
        [IO.File]::SetLastWriteTimeUtc($script:GuestPin, [DateTime]::UtcNow.AddMinutes(-5))
        $script:GuestScript = @(@{ Key = 'installed'; Answer = 'ready' })
        Wait-SshReady -VMName fixture-guest -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 3 -PollSeconds 1 -WarningVariable warned -WarningAction SilentlyContinue | Should -BeFalse
        (Get-LastSshReadiness).cause | Should -BeExactly 'host_key_changed'
        Get-Content -LiteralPath $script:GuestPin -Raw | Should -BeExactly 'earlier'
        @($warned | Where-Object { [string]$_ -match 'no login has authenticated' }).Count | Should -Be 0
    }

    It 'keeps a pin a login authenticated against earlier in the same wait' {
        # An expired-password answer comes after the key authenticated.
        $script:GuestScript = @(@{ Key = 'installer'; Answer = 'expired' }, @{ Key = 'installed'; Answer = 'ready' })
        Wait-SshReady -VMName fixture-guest -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 4 -PollSeconds 1 -WarningAction SilentlyContinue | Should -BeFalse
        (Get-LastSshReadiness).cause | Should -BeExactly 'host_key_changed'
        Get-Content -LiteralPath $script:GuestPin -Raw | Should -BeExactly 'installer'
    }

    It 'stops forgetting pins at the bound a shared scope carries' {
        $scope = @{ SinceUtc = [DateTime]::UtcNow; Resets = 2 }
        $script:GuestScript = @(
            @{ Key = 'k1'; Answer = 'denied' }, @{ Key = 'k2'; Answer = 'denied' }, @{ Key = 'k2'; Answer = 'denied' },
            @{ Key = 'k3'; Answer = 'ready' })
        $warnings = @()
        $ready = Wait-SshReady -VMName fixture-guest -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 6 -PollSeconds 1 -HostKeyPinScope $scope 3>&1 |
            ForEach-Object { if ($_ -is [System.Management.Automation.WarningRecord]) { $warnings += [string]$_.Message } else { $_ } }
        $ready | Should -BeFalse
        $scope.Resets | Should -Be 3
        @($warnings | Where-Object { $_ -match 'no login has authenticated' }).Count | Should -Be 1
        Get-Content -LiteralPath $script:GuestPin -Raw | Should -BeExactly 'k2'
        (Get-LastSshReadiness).cause | Should -BeExactly 'host_key_changed'
    }
}
