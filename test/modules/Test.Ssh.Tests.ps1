<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42d3b9c1-7e4a-4f86-9b21-5c0d8a6f1e23
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

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Ssh.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

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

    It 'classifies the per-probe cap (half-dead post-TCP session)' {
        Assert-Equal 'probe_timeout' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'probe timed out after 15s (ssh hung post-TCP; process killed)')
    }

    It 'classifies an unreachable network path to a discovered IP' {
        Assert-Equal 'network_unreachable' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'connect to host 192.168.7.40 port 22: No route to host')
        Assert-Equal 'network_unreachable' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'connect to host 192.168.7.40 port 22: Connection timed out')
    }

    It 'classifies an unresolved name against a discovered IP context' {
        Assert-Equal 'name_unresolved' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'ssh: Could not resolve hostname foo: Name or service not known')
    }

    It 'falls back to handshake_failed for an unrecognized error on a reachable host' {
        Assert-Equal 'handshake_failed' (Get-SshReadinessFailureCause -IpDiscovered $true -LastError 'kex_exchange_identification: read: some novel error')
    }
}
