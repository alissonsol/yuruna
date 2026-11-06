<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4236f243-109b-48f8-8baf-44f14469804e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest ssh host keys sshd systemd pester
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
    An Ubuntu guest recreates SSH host keys it lost, before sshd needs them.
.DESCRIPTION
    WHY THIS EXISTS. cloud-init replaces the host keys on the installed
    system's first boot. A guest that stalls seconds later and is powered off
    hard -- the cold restart that rescues a stalled first boot -- can come
    back with the new key files empty or absent while cloud-init's marker that
    the module ran survives. cloud-init
    never writes the keys again, and every later sshd start fails with
    "no hostkeys available": the harness loses every SSH path to the guest,
    and a workload that enables ssh fails outright.

    The seed installs a oneshot unit that runs ssh-keygen -A ahead of sshd.
    Each line pinned here fails silently when it is wrong -- the unit stays
    enabled, the install stays clean, and sshd still finds no key.

    Static assertions over the seed, because the thing under test is what the
    guest is BUILT with; there is no guest to run.
    Run: Invoke-Pester -Path test/modules/Test.GuestSshHostKeys.Tests.ps1
#>

BeforeAll {
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:Seed = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/vmconfig/ubuntu.server.base.user-data')
    # The unit body exactly as the late-command writes it: the heredoc between
    # its cat line and its EOF terminator.
    $script:Unit = [regex]::Match($script:Seed,
        "(?s)cat > /target/etc/systemd/system/yuruna-ssh-hostkeys\.service << 'EOF'\r?\n(.*?)\r?\n[ \t]*EOF\r?\n").Groups[1].Value
}

Describe 'the Ubuntu seed installs the host-key repair' {

    It 'writes the unit into the installed system and enables it there' {
        $script:Unit | Should -Not -BeNullOrEmpty -Because 'the seed must write yuruna-ssh-hostkeys.service under /target'
        $script:Seed | Should -Match 'curtin in-target --target=/target -- systemctl enable[^\r\n]*yuruna-ssh-hostkeys\.service' `
            -Because 'a unit that is written but not enabled never runs'
    }
}

Describe 'the lines that decide whether the repair runs before sshd' {

    It 'runs ssh-keygen -A, which creates only missing or empty keys' {
        # ssh-keygen -A skips every key type whose private key exists with a
        # nonzero size, so a healthy guest keeps the keys an SSH pin trusts.
        # Any form that names a key file regenerates it, every time.
        $execStart = [regex]::Matches($script:Unit, '(?m)^\s*ExecStart=([^\r\n]*)$')
        $execStart.Count | Should -Be 1
        $execStart[0].Groups[1].Value.Trim() | Should -BeExactly '/usr/bin/ssh-keygen -A'
    }

    It 'is a oneshot, so sshd waits for the keys and not just for a process to start' {
        # Before= orders start jobs. A Type=simple job is complete once its
        # process is forked, so sshd's configuration test would race the key
        # writes it depends on; a oneshot job completes when the process exits.
        $script:Unit | Should -Match '(?m)^\s*Type=oneshot\s*$'
    }

    It 'is wanted by and ordered before ssh.service, which every sshd start goes through' {
        # Ubuntu starts sshd through ssh.service at boot, from ssh.socket on a
        # connection, and on systemctl start. Wanting the unit from the
        # service brings it along on each of them, and the ordering makes the
        # service wait for it.
        $script:Unit | Should -Match '(?m)^\s*WantedBy=ssh\.service\s*$'
        $script:Unit | Should -Match '(?m)^\s*Before=ssh\.service\s*$'
    }

    It 'has no first-boot condition' {
        # openssh-server's own sshd-keygen.service carries ConditionFirstBoot=yes,
        # and an installed system never has a systemd first boot because the
        # installer writes its machine ID. That condition is why the packaged
        # unit cannot repair a lost key; carrying it here would repeat that.
        $script:Unit | Should -Not -BeNullOrEmpty -Because 'an absent unit has no condition to read'
        $script:Unit | Should -Not -Match 'ConditionFirstBoot'
    }
}
