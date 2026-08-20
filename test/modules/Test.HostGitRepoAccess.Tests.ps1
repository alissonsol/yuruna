<#PSScriptInfo
.VERSION 2026.08.20
.GUID 424d0ae7-c25c-4fdf-b29d-12a4768bb7d1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit repository access pester
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
    Guards Get-GitRepositoryName / Get-HostRepositoryAccess (Test.HostGit.psm1):
    the repository answer a host serves to the pool UIs' Framework and Project
    columns.
.DESCRIPTION
    The columns read as a lab-wide inventory -- which machine is on which
    repository, and where that repository lives -- so four properties are
    pinned here:

      * every clone form yields the SAME name. https, scp-like ssh, ssh:// and
        a local clone path all name one repository, and a remote written with
        or without .git must not read as two different machines.
      * the clone a host holds answers before the network does. It is the truth
        about what the machine tracks (a pool assignment overrides the
        configured url for a cycle), and it costs no round trip.
      * a configured url this host cannot read says so ('No access'), while
        NOTHING configured stays blank. Those are different operator states: a
        credential to fix vs. the in-tree project layout, which is fine.
      * the answer carries WHERE that repository is, so the column can link to
        it -- the clone's own origin when a clone answered, the configured url
        when the probe did (the refused one included), and nothing at all while
        the answer is still pending.

    The network branch is opt-in, so the local reads here touch real temp git
    repos and only the probe path is mocked.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

Import-Module $modulePath -Force

# Real repos: only remote.origin.url is read, so they need no commits, and the
# config edits are local (no network).
$script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-repoaccess-tests-" + [guid]::NewGuid().ToString('N'))
$script:cloned   = Join-Path $script:tmpRoot 'framework-clone'
$script:noOrigin = Join-Path $script:tmpRoot 'no-origin-clone'
$script:notARepo = Join-Path $script:tmpRoot 'plain-directory'
foreach ($d in @($script:cloned, $script:noOrigin, $script:notARepo)) {
    $null = New-Item -ItemType Directory -Path $d -Force
}
foreach ($r in @($script:cloned, $script:noOrigin)) { & git -C $r init --quiet 2>$null }
& git -C $script:cloned remote add origin 'https://github.com/alius-git/amisad.dev.git' 2>$null
}

AfterAll {
    if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
        Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-GitRepositoryName -- one repository, one name' {
    It 'takes the last segment of an https clone url' {
        Assert-Equal 'amisad.dev' (Get-GitRepositoryName -Url 'https://github.com/alius-git/amisad.dev')
    }
    It 'strips a trailing .git and trailing slash' {
        Assert-Equal 'yuruna' (Get-GitRepositoryName -Url 'https://github.com/alius-git/yuruna.git/')
    }
    It 'reads an scp-like ssh remote' {
        Assert-Equal 'yuruna-fork' (Get-GitRepositoryName -Url 'git@github.com:alius-git/yuruna-fork.git')
    }
    It 'reads an ssh:// remote with a user and port' {
        Assert-Equal 'yuruna' (Get-GitRepositoryName -Url 'ssh://git@github.com:22/alius-git/yuruna.git')
    }
    It 'reads a local clone path on either separator' {
        Assert-Equal 'yuruna' (Get-GitRepositoryName -Url '/home/operator/git/yuruna')
        Assert-Equal 'yuruna' (Get-GitRepositoryName -Url 'C:\git\yuruna')
    }
    It 'does not mistake a query string or fragment for the name' {
        Assert-Equal 'amisad.dev' (Get-GitRepositoryName -Url 'https://github.com/alius-git/amisad.dev?ref=main')
    }
    It 'returns empty for nothing at all' {
        Assert-Equal '' (Get-GitRepositoryName -Url '')
        Assert-Equal '' (Get-GitRepositoryName -Url '   ')
        Assert-Equal '' (Get-GitRepositoryName -Url $null)
    }
}

Describe 'Get-HostRepositoryAccess -- the clone this host holds answers first' {
    It 'names the repository from remote.origin.url, not from what was configured' {
        # The configured url is deliberately a DIFFERENT repository: a pool
        # assignment overrides it for a cycle, and the column must report the
        # repository the machine is actually on.
        $r = Get-HostRepositoryAccess -RepoDir $script:cloned -ConfiguredUrl 'https://github.com/alius-git/some-other-project'
        Assert-Equal 'amisad.dev' $r.Access
        Assert-Equal 'clone'      $r.Source
        # The name travels with where it was read from, so the column can offer
        # the repository itself -- and it is the CLONE's origin, matching the
        # name beside it rather than the configured url that lost.
        Assert-Equal 'https://github.com/alius-git/amisad.dev' $r.Url
    }
    It 'points at a local copy when that is what the host is on' {
        $local = Join-Path $script:tmpRoot 'local-origin-clone'
        $null = New-Item -ItemType Directory -Path $local -Force
        & git -C $local init --quiet 2>$null
        & git -C $local remote add origin $script:cloned 2>$null
        $r = Get-HostRepositoryAccess -RepoDir $local -ConfiguredUrl ''
        Assert-Equal 'framework-clone' $r.Access
        Assert-Equal ((Resolve-GitRemoteLink -Url $script:cloned).Url) $r.Url `
            -Because 'a host on a local mirror must not be reported as being on what that mirror was cloned from'
    }
    It 'never probes when the clone answered' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'the network must not be touched when a clone can answer' }
        $r = Get-HostRepositoryAccess -RepoDir $script:cloned -ConfiguredUrl 'https://github.com/alius-git/amisad.dev' -Probe
        Assert-Equal 'amisad.dev' $r.Access
        Assert-MockCalled -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0 -Scope It
    }
    It 'reports nothing for a host with neither a clone nor a configured url (in-tree project layout)' {
        $r = Get-HostRepositoryAccess -RepoDir $script:notARepo -ConfiguredUrl ''
        Assert-Equal ''             $r.Access
        Assert-Equal 'unconfigured' $r.Source
    }
    It 'falls through a repo with no origin remote to the configured url' {
        $r = Get-HostRepositoryAccess -RepoDir $script:noOrigin -ConfiguredUrl 'https://github.com/alius-git/yuruna'
        Assert-Equal 'unprobed' $r.Source
    }
}

Describe 'Get-HostRepositoryAccess -- the probe is opt-in and decides the blank' {
    It 'defers without -Probe, so a caller under a deadline pays no round trip' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'the probe must be opt-in' }
        $r = Get-HostRepositoryAccess -RepoDir $script:notARepo -ConfiguredUrl 'https://github.com/alius-git/yuruna'
        Assert-Equal ''         $r.Access
        Assert-Equal 'unprobed' $r.Source
        # Nothing to point at while the answer is pending: the column renders a
        # blank here, and a blank must not carry a link.
        Assert-Equal '' $r.Url
        Assert-MockCalled -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0 -Scope It
    }
    It 'names the configured repository when the probe reaches it (cloned soon, readable now)' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { return @{ ExitCode = 0; Output = '' } }
        $r = Get-HostRepositoryAccess -RepoDir $script:notARepo -ConfiguredUrl 'https://github.com/alius-git/yuruna.git' -Probe
        Assert-Equal 'yuruna' $r.Access
        Assert-Equal 'probe'  $r.Source
        Assert-Equal 'https://github.com/alius-git/yuruna' $r.Url
    }
    It 'says No access when the credential is refused, and keeps the reason' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            return @{ ExitCode = 128; Output = "fatal: Authentication failed for 'https://github.com/alius-git/private.git/'" }
        }
        $r = Get-HostRepositoryAccess -RepoDir $script:notARepo -ConfiguredUrl 'https://github.com/alius-git/private' -Probe
        Assert-Equal 'No access' $r.Access
        Assert-Equal 'denied'    $r.Source
        # The url it could NOT read is exactly the one an operator opens next:
        # a url naming the wrong repository looks identical to a missing
        # credential until someone follows it.
        Assert-Equal 'https://github.com/alius-git/private' $r.Url
    }
    It 'says No access for an outage too -- the column has one failure word' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            return @{ ExitCode = 128; Output = "fatal: unable to access: Could not resolve host: github.com" }
        }
        $r = Get-HostRepositoryAccess -RepoDir $script:notARepo -ConfiguredUrl 'https://github.com/alius-git/yuruna' -Probe
        Assert-Equal 'No access'   $r.Access
        Assert-Equal 'unreachable' $r.Source
    }
}

Describe 'Test-GitRemoteAccess -- the auth/network split survives the collapse' {
    It 'reports ok for a remote it could read' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { return @{ ExitCode = 0; Output = '' } }
        $r = Test-GitRemoteAccess -Url 'https://github.com/alius-git/yuruna'
        Assert-Equal $true $r.Reachable
        Assert-Equal 'ok'  $r.Reason
    }
    It 'classifies a refusal as denied and carries the words git used' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            return @{ ExitCode = 128; Output = 'remote: Repository not found.' }
        }
        $r = Test-GitRemoteAccess -Url 'https://github.com/alius-git/private'
        Assert-Equal $false    $r.Reachable
        Assert-Equal 'denied'  $r.Reason
        Assert-Equal 'remote: Repository not found.' $r.Detail
    }
    It 'does not reach the network for an empty url' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'nothing to probe' }
        $r = Test-GitRemoteAccess -Url ''
        Assert-Equal $false $r.Reachable
        Assert-MockCalled -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 0 -Scope It
    }
}
