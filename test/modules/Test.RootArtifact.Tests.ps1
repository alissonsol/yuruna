<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b8d1c4-3e07-4a96-9d25-8e14f7b02c6a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test root sudo pester
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
    Pester coverage for Test.RootArtifact.psm1's decidable pieces: the mount-line
    selector, the sudo-answer classifier, root's home path, and the contract that
    the whole sweep is inert on Windows and never throws.
.DESCRIPTION
    The parts that read the live machine (find -uid 0, sudo -n, lsof) are covered
    only for "does not throw / returns the right shape": asserting what they find
    would assert the state of whatever host the suite runs on. The classifiers
    they depend on ARE fully covered here, because those are where a wrong answer
    turns into a wrong diagnosis -- reading sudo's "I need a password" as "root
    has nothing here" would report every uncached host as clean.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RootArtifact.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

Describe 'Select-RootArtifactMountLine (mounts standing under root''s home)' {
    It 'finds a macOS smbfs mount under /var/root' {
        $lines = @(
            '/dev/disk1s1 on / (apfs, local, journaled)',
            '//yuruna-pool@ypool-nas/yuruna.pool on /var/root/Shares/ypool-nas (smbfs, nodev, nosuid, mounted by root)'
        )
        $r = @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/var/root')
        Assert-Equal 1 $r.Count -Because 'one mount under root home'
        Assert-Equal '/var/root/Shares/ypool-nas' $r[0]
    }
    It 'matches the /private spelling macOS reports back' {
        # macOS resolves /var through /private, so the kernel answers with a path
        # that does not literally start with the home it was asked for.
        $lines = @('//yuruna-stash@ystash-nas/yuruna.stash on /private/var/root/Shares/ystash-nas (smbfs)')
        $r = @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/var/root')
        Assert-Equal 1 $r.Count -Because '/private prefix still matched'
    }
    It 'finds a Linux cifs mount under /root' {
        $lines = @('//ypool-nas/yuruna.pool on /root/Shares/ypool-nas type cifs (rw,relatime,vers=3.0)')
        $r = @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/root')
        Assert-Equal 1 $r.Count
        Assert-Equal '/root/Shares/ypool-nas' $r[0]
    }
    It 'ignores the operator''s own mounts' {
        $lines = @(
            '//yuruna-pool@ypool-nas/yuruna.pool on /Users/paulohp/Shares/ypool-nas (smbfs)',
            'map auto_home on /System/Volumes/Data/home (autofs, automounted)'
        )
        Assert-Equal 0 @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/var/root').Count
    }
    It 'does not match root''s home itself, or a sibling that merely starts the same way' {
        # '/var/rootkit/...' shares a prefix with '/var/root' but is not inside it;
        # only a '/'-delimited descendant counts.
        $lines = @(
            'x on /var/root (hfs)',
            'y on /var/rootkit/Shares/ypool-nas (smbfs)'
        )
        Assert-Equal 0 @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/var/root').Count
    }
    It 'survives junk, blank and null input' {
        Assert-Equal 0 @(Select-RootArtifactMountLine -MountLine $null -RootHome '/var/root').Count
        Assert-Equal 0 @(Select-RootArtifactMountLine -MountLine @('', 'no separator here') -RootHome '/var/root').Count
    }
    It 'de-duplicates a point reported twice' {
        $lines = @('a on /var/root/Shares/x (smbfs)', 'b on /var/root/Shares/x (smbfs)')
        Assert-Equal 1 @(Select-RootArtifactMountLine -MountLine $lines -RootHome '/var/root').Count
    }
}

Describe 'Test-RootArtifactSudoAnswered (a refusal is not a "no")' {
    It 'treats a clean exit as an answer' {
        Assert-True (Test-RootArtifactSudoAnswered -ExitCode 0 -StdErr '')
    }
    It 'treats a plain non-zero exit with no complaint as an answer (the path is absent)' {
        Assert-True (Test-RootArtifactSudoAnswered -ExitCode 1 -StdErr '')
    }
    It 'does NOT treat a password demand as an answer' {
        # The whole point: this exits non-zero exactly like "directory absent", and
        # reading it as absent reports every uncached host as clean.
        foreach ($text in @(
            'sudo: a password is required',
            'sudo: a terminal is required to read the password; either use the -S option...',
            'sudo: no tty present and no askpass program specified',
            'Sorry, user paulohp may not run sudo on Mac-2.')) {
            Assert-False (Test-RootArtifactSudoAnswered -ExitCode 1 -StdErr $text) "refusal recognised: $text"
        }
    }
    It 'does not treat a timeout or a failed start as an answer' {
        Assert-False (Test-RootArtifactSudoAnswered -ExitCode 124 -StdErr 'timeout 20s')
        Assert-False (Test-RootArtifactSudoAnswered -ExitCode -1 -StdErr 'not found')
    }
}

Describe 'Get-YurunaRootHomePath' {
    It 'is empty on Windows and a real path elsewhere' {
        $p = Get-YurunaRootHomePath
        if ($IsWindows) { Assert-Equal '' $p -Because 'no root home concept on Windows' }
        elseif ($IsMacOS) { Assert-Equal '/var/root' $p }
        else { Assert-Equal '/root' $p }
    }
}

Describe 'Get-YurunaRootArtifact (contract)' {
    It 'returns an array and never throws on this host' {
        $r = @(Get-YurunaRootArtifact -RepoRoot (Split-Path -Parent (Split-Path -Parent $here)) -Port @(59997, 59998))
        Assert-True ($null -ne $r) 'always an array'
        foreach ($a in $r) {
            Assert-True ([bool]$a.Kind)    'every finding names its kind'
            Assert-True ([bool]$a.Summary) 'every finding carries a summary'
            Assert-True ($a.Blocking -is [bool]) 'blocking is a real bool the caller can gate on'
        }
    }
    It 'is completely inert on Windows' -Skip:(-not $IsWindows) {
        # Windows setup runs elevated by design and leaves nothing the operator
        # cannot modify, so the sweep must not invent findings there.
        Assert-Equal 0 @(Get-YurunaRootArtifact -RepoRoot 'C:\nope' -Port @(8080)).Count
    }
    It 'reports free ports as no finding' -Skip:$IsWindows {
        # Two ports nothing plausibly holds: a finding here would mean the
        # bind-fails-but-no-PID signature is misfiring on an empty port.
        $r = @(Get-YurunaRootArtifact -RepoRoot (Split-Path -Parent (Split-Path -Parent $here)) -Port @(59997, 59998))
        Assert-Equal 0 @($r | Where-Object { $_.Kind -eq 'listener' }).Count -Because 'no listener finding for free ports'
    }
}

Describe 'Write-YurunaRootArtifactReport' {
    It 'prints nothing for an empty or null finding set' {
        $out = Write-YurunaRootArtifactReport -Artifact @() -InformationAction Continue 6>&1
        Assert-Equal 0 @($out).Count -Because 'silent when there is nothing to say'
        $out = Write-YurunaRootArtifactReport -Artifact $null -InformationAction Continue 6>&1
        Assert-Equal 0 @($out).Count -Because 'null tolerated'
    }
}
