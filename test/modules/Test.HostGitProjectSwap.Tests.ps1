<#PSScriptInfo
.VERSION 2026.10.18
.GUID 4207281c-d594-4c5f-b5f3-215bb075539f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit project clone swap pester
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
    Pins how Update-ProjectClone replaces <RepoRoot>/project/: the new checkout
    is built beside the old one and swapped in only when it is proven complete,
    so no failure or interruption can leave the host without a usable checkout.
.DESCRIPTION
    Deleting project/ before cloning its replacement is the hazard: a clone that
    fails -- the network drops, the disk fills, the process is killed -- leaves
    nothing to test with, and the next cycle starts from a missing checkout. These cases run the real git against a throwaway local repository
    for the success path and mock the network layer for the failure paths, always
    inside a temporary RepoRoot: the framework's own project/ is never touched.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The mocked clone runs in the module scope and hands its file watchers back to the test through a global.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostGit.psm1') -Force -DisableNameChecking
# Captured before any Mock: a filtered mock alone fails the calls its
# filter does not match, and this suite relies on the real command there.
$script:RealMoveProjectCloneDirectory = & (Get-Module Test.HostGit) { Get-Command Move-ProjectCloneDirectory }
$script:RealRemoveProjectCloneDirectory = & (Get-Module Test.HostGit) { Get-Command Remove-ProjectCloneDirectory }

function New-GitRemoteFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a throwaway repository under the temp directory.')]
    [OutputType([string])]
    param([string]$Root)
    $remote = Join-Path $Root 'remote'
    New-Item -ItemType Directory -Path $remote -Force | Out-Null
    & git -C $remote init --quiet 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $remote 'tracked.txt') -Value 'from the remote' -Encoding utf8
    & git -C $remote add tracked.txt 2>&1 | Out-Null
    & git -C $remote -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m 'fixture' 2>&1 | Out-Null
    return $remote
}

function New-RepoRootFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a throwaway RepoRoot under the temp directory.')]
    [OutputType([string])]
    param([string]$Root, [switch]$WithCheckout)
    $repoRoot = Join-Path $Root 'repo'
    New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null
    if ($WithCheckout) {
        $project = Join-Path $repoRoot 'project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'old.txt') -Value 'the last good checkout' -Encoding utf8
    }
    return $repoRoot
}
}

Describe 'Update-ProjectClone swaps in a proven-complete clone' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pcswap-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Remote = New-GitRemoteFixture -Root $script:Root
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'replaces the checkout with a fresh clone and leaves nothing beside it' {
        $repo = New-RepoRootFixture -Root $script:Root -WithCheckout
        $r = Update-ProjectClone -RepoRoot $repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        Get-Content -LiteralPath (Join-Path $repo 'project/tracked.txt') -Raw | Should -Match 'from the remote'
        Test-Path -LiteralPath (Join-Path $repo 'project/old.txt') | Should -BeFalse -Because 'a refresh must not carry the previous cycle forward'
        Test-Path -LiteralPath (Join-Path $repo 'project.incoming') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo 'project.previous') | Should -BeFalse
        $head = (& git -C $script:Remote rev-parse HEAD).Trim()
        $r.revision | Should -Be $head -Because 'the result names the revision that was verified and installed'
    }
    It 'creates the checkout when there was none' {
        $repo = New-RepoRootFixture -Root $script:Root
        $r = Update-ProjectClone -RepoRoot $repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        Test-Path -LiteralPath (Join-Path $repo 'project/tracked.txt') | Should -BeTrue
    }
    It 'is a no-op without a project URL' {
        $repo = New-RepoRootFixture -Root $script:Root -WithCheckout
        $r = Update-ProjectClone -RepoRoot $repo -ProjectUrl '' -Confirm:$false 6>$null
        $r.skipped | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'project/old.txt') | Should -BeTrue
    }
    It 'changes nothing under -WhatIf' {
        $repo = New-RepoRootFixture -Root $script:Root -WithCheckout
        $null = Update-ProjectClone -RepoRoot $repo -ProjectUrl $script:Remote -WhatIf 6>$null
        Test-Path -LiteralPath (Join-Path $repo 'project/old.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $repo 'project.incoming') | Should -BeFalse
    }
}

Describe 'Update-ProjectClone never costs the last good checkout' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pcfail-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Remote = New-GitRemoteFixture -Root $script:Root
        $script:Repo = New-RepoRootFixture -Root $script:Root -WithCheckout
        Mock -ModuleName Test.HostGit Get-FileLockingProcess { @() }
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { & $script:RealMoveProjectCloneDirectory @PesterBoundParameters }
        Mock -ModuleName Test.HostGit Remove-ProjectCloneDirectory { & $script:RealRemoveProjectCloneDirectory @PesterBoundParameters }
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'keeps the checkout when the clone fails, and removes the partial clone' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs -contains 'clone') {
                New-Item -ItemType Directory -Path ($GitArgs[-1]) -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $GitArgs[-1] 'partial.txt') -Value 'half a clone'
                return @{ ExitCode = 128; Output = 'fatal: early EOF' }
            }
            return @{ ExitCode = 0; Output = '' }
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl 'https://example.invalid/p.git' -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.errorMessage | Should -Match 'git clone failed \(exit 128\)'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue -Because 'the last good checkout survives a failed clone'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'keeps the checkout when the clone is not a git checkout at all' {
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs -contains 'clone') {
                New-Item -ItemType Directory -Path ($GitArgs[-1]) -Force | Out-Null
                return @{ ExitCode = 0; Output = '' }
            }
            return @{ ExitCode = 0; Output = '' }
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl 'https://example.invalid/p.git' -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.errorMessage | Should -Match 'not usable'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'keeps the checkout when the clone arrived without its working tree' {
        $remote = $script:Remote
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs -contains 'clone') {
                $dest = $GitArgs[-1]
                & git clone --quiet $remote $dest 2>&1 | Out-Null
                Remove-Item -LiteralPath (Join-Path $dest 'tracked.txt') -Force
                return @{ ExitCode = 0; Output = '' }
            }
            return @{ ExitCode = 0; Output = '' }
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $remote -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.errorMessage | Should -Match 'missing from the working tree'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'stops with the checkout in place when it can neither be set aside nor removed' {
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { throw 'The process cannot access the file because it is being used by another process.' } -ParameterFilter { $Destination -like '*project.previous' }
        Mock -ModuleName Test.HostGit Remove-ProjectCloneDirectory { $false } -ParameterFilter { $Path -like '*[\\/]project' }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.errorMessage | Should -Match 'Failed to set aside the previous project clone'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'replaces the checkout in place when the rename is refused but the removal is not' {
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { throw 'Access to the path is denied.' } -ParameterFilter { $Destination -like '*project.previous' }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        Get-Content -LiteralPath (Join-Path $script:Repo 'project/tracked.txt') -Raw | Should -Match 'from the remote'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeFalse -Because 'a refresh must not carry the previous cycle forward'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'installs the clone by copying it when it cannot be renamed into place' {
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { throw 'access denied' } -ParameterFilter { $Path -like '*project.incoming' }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        Get-Content -LiteralPath (Join-Path $script:Repo 'project/tracked.txt') -Raw | Should -Match 'from the remote'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
        $r.revision | Should -Be ((& git -C $script:Remote rev-parse HEAD).Trim())
    }
    It 'puts the checkout back when the clone can be neither renamed nor copied into place' {
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { throw 'access denied' } -ParameterFilter { $Path -like '*project.incoming' }
        Mock -ModuleName Test.HostGit Copy-ProjectCloneDirectory { $false }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        $r.errorMessage | Should -Match 'Failed to move the fresh project clone into place'
        $r.errorMessage | Should -Match 'put back'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue -Because 'a failure after the swap began is rolled back'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
    }
    It 'still succeeds when the displaced copy will not delete yet' {
        Mock -ModuleName Test.HostGit Remove-ProjectCloneDirectory { $false } -ParameterFilter { $Path -like '*project.previous' }
        Mock -ModuleName Test.HostGit Write-Warning { }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because 'the swap itself worked; the leftover is cleaned by the next refresh'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/tracked.txt') | Should -BeTrue
    }
}

Describe 'Update-ProjectClone with a file watcher on the checkout' -Skip:(-not $IsWindows) {
    # An editor or a build tool that watches a folder below the checkout (a C# language
    # server watching a project's obj folder is the case that surfaced this) makes
    # Windows refuse to rename the checkout, while a delete still goes through.
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pcwatch-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Remote = New-GitRemoteFixture -Root $script:Root
        $script:Repo = New-RepoRootFixture -Root $script:Root -WithCheckout
        $script:Deep = Join-Path $script:Repo 'project/example/site/obj/Debug'
        New-Item -ItemType Directory -Path $script:Deep -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Deep 'built.txt') -Value 'build output' -Encoding utf8
        $script:Watcher = [System.IO.FileSystemWatcher]::new($script:Deep)
        $script:Watcher.EnableRaisingEvents = $true
        Mock -ModuleName Test.HostGit Get-FileLockingProcess { @() }
        Mock -ModuleName Test.HostGit Move-ProjectCloneDirectory { & $script:RealMoveProjectCloneDirectory @PesterBoundParameters }
        Mock -ModuleName Test.HostGit Remove-ProjectCloneDirectory { & $script:RealRemoveProjectCloneDirectory @PesterBoundParameters }
        $global:__swapWatchers = [System.Collections.Generic.List[System.IO.FileSystemWatcher]]::new()
    }
    AfterEach {
        $script:Watcher.Dispose()
        foreach ($w in $global:__swapWatchers) { $w.Dispose() }
        Remove-Variable -Name __swapWatchers -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'replaces the checkout in place instead of failing the refresh' {
        $renameRefused = $false
        try { [System.IO.Directory]::Move((Join-Path $script:Repo 'project'), (Join-Path $script:Repo 'project.probe')) } catch { $renameRefused = $true }
        if (-not $renameRefused) {
            [System.IO.Directory]::Move((Join-Path $script:Repo 'project.probe'), (Join-Path $script:Repo 'project'))
            Set-ItResult -Skipped -Because 'this Windows build lets a watched folder be renamed, so the case cannot be built here'
            return
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        Get-Content -LiteralPath (Join-Path $script:Repo 'project/tracked.txt') -Raw | Should -Match 'from the remote'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
    }
    It 'installs a fresh clone that is itself watched, by copying it' {
        # The language server reaches the new clone's build output folder within a second
        # of the clone finishing, so the rename into place is refused as well.
        $remote = $script:Remote
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs -contains 'clone') {
                $dest = $GitArgs[-1]
                & git clone --quiet $remote $dest 2>&1 | Out-Null
                $deep = Join-Path $dest 'example/site/obj/Debug'
                New-Item -ItemType Directory -Path $deep -Force | Out-Null
                $watcher = [System.IO.FileSystemWatcher]::new($deep)
                $watcher.EnableRaisingEvents = $true
                $global:__swapWatchers.Add($watcher)
                return @{ ExitCode = 0; Output = '' }
            }
            return @{ ExitCode = 0; Output = '' }
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $remote -Confirm:$false 6>$null
        $r.success | Should -BeTrue -Because $r.errorMessage
        $global:__swapWatchers.Count | Should -Be 1 -Because 'the clone was watched, so the rename into place was refused'
        Get-Content -LiteralPath (Join-Path $script:Repo 'project/tracked.txt') -Raw | Should -Match 'from the remote'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/example/site/obj/Debug') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'leaves the checkout whole, not half moved, when it can neither be renamed nor removed' {
        Mock -ModuleName Test.HostGit Remove-ProjectCloneDirectory { $false } -ParameterFilter { $Path -like '*[\\/]project' }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl $script:Remote -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/old.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Deep 'built.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse -Because 'a refused rename moves nothing; Move-Item would have carried some children across'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
}

Describe 'Restore-ProjectCloneSwap recovers an interrupted refresh' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pcrec-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Repo = New-RepoRootFixture -Root $script:Root
        function Add-Dir {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a marker directory under the temp RepoRoot.')]
            param([string]$Name, [string]$Marker)
            $d = Join-Path $script:Repo $Name
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $d $Marker) -Value $Marker -Encoding utf8
        }
        $script:AddDir = ${function:Add-Dir}
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'puts the set-aside checkout back when the replacement never arrived' {
        & $script:AddDir 'project.previous' 'previous.txt'
        & $script:AddDir 'project.incoming' 'half.txt'
        $actions = @(Restore-ProjectCloneSwap -RepoRoot $script:Repo -Confirm:$false)
        $actions | Should -Contain 'restored-previous'
        $actions | Should -Contain 'removed-incoming'
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/previous.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.incoming') | Should -BeFalse
    }
    It 'deletes the displaced copy a finished swap left behind, and keeps the checkout' {
        & $script:AddDir 'project' 'current.txt'
        & $script:AddDir 'project.previous' 'previous.txt'
        $actions = @(Restore-ProjectCloneSwap -RepoRoot $script:Repo -Confirm:$false)
        $actions | Should -Be @('removed-previous')
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/current.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Repo 'project.previous') | Should -BeFalse
    }
    It 'deletes a clone that never finished, and keeps the checkout' {
        & $script:AddDir 'project' 'current.txt'
        & $script:AddDir 'project.incoming' 'half.txt'
        $actions = @(Restore-ProjectCloneSwap -RepoRoot $script:Repo -Confirm:$false)
        $actions | Should -Be @('removed-incoming')
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/current.txt') | Should -BeTrue
    }
    It 'does nothing when there is nothing to recover' {
        & $script:AddDir 'project' 'current.txt'
        @(Restore-ProjectCloneSwap -RepoRoot $script:Repo -Confirm:$false).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/current.txt') | Should -BeTrue
    }
    It 'restores the checkout even when the refresh that follows fails' {
        & $script:AddDir 'project.previous' 'previous.txt'
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand {
            if ($GitArgs -contains 'clone') { return @{ ExitCode = 128; Output = 'fatal: unreachable' } }
            return @{ ExitCode = 0; Output = '' }
        }
        $r = Update-ProjectClone -RepoRoot $script:Repo -ProjectUrl 'https://example.invalid/p.git' -Confirm:$false 6>$null
        $r.success | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Repo 'project/previous.txt') | Should -BeTrue -Because 'a usable checkout exists whenever one ever did'
    }
}

Describe 'Test-ProjectCloneHealth' {
    BeforeEach {
        $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('pchealth-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
        $script:Remote = New-GitRemoteFixture -Root $script:Root
    }
    AfterEach { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts a complete clone and names its revision' {
        $dest = Join-Path $script:Root 'clone'
        & git clone --quiet $script:Remote $dest 2>&1 | Out-Null
        $h = Test-ProjectCloneHealth -Path $dest
        $h.Healthy | Should -BeTrue -Because $h.Reason
        $h.Revision | Should -Be ((& git -C $script:Remote rev-parse HEAD).Trim())
    }
    It 'rejects a directory that is not a checkout' {
        $dest = Join-Path $script:Root 'plain'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        (Test-ProjectCloneHealth -Path $dest).Healthy | Should -BeFalse
    }
    It 'rejects a clone of an empty repository, which has no commit to verify' {
        $empty = Join-Path $script:Root 'empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        & git -C $empty init --quiet 2>&1 | Out-Null
        $dest = Join-Path $script:Root 'clone-of-empty'
        & git clone --quiet $empty $dest 2>&1 | Out-Null
        $h = Test-ProjectCloneHealth -Path $dest
        $h.Healthy | Should -BeFalse
        $h.Reason | Should -Match 'HEAD does not resolve'
    }
    It 'rejects a clone with tracked files missing and says how many' {
        $dest = Join-Path $script:Root 'clone'
        & git clone --quiet $script:Remote $dest 2>&1 | Out-Null
        Remove-Item -LiteralPath (Join-Path $dest 'tracked.txt') -Force
        $h = Test-ProjectCloneHealth -Path $dest
        $h.Healthy | Should -BeFalse
        $h.Reason | Should -Match '1 tracked file\(s\) are missing'
    }
    It 'does not reject a clone for files whose line endings differ from the index' {
        $dest = Join-Path $script:Root 'clone'
        & git clone --quiet $script:Remote $dest 2>&1 | Out-Null
        Set-Content -LiteralPath (Join-Path $dest 'tracked.txt') -Value "from the remote`r`n" -Encoding utf8 -NoNewline
        (Test-ProjectCloneHealth -Path $dest).Healthy | Should -BeTrue -Because 'only missing files are the corruption this guards against'
    }
}

Describe 'The framework does not mistake the swap directories for source' {
    It 'ignores project.incoming and project.previous like project' {
        $repoRoot = (Resolve-Path -LiteralPath (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
        $ignore = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.gitignore')
        $ignore | Should -Contain 'project/'
        $ignore | Should -Contain 'project.incoming/'
        $ignore | Should -Contain 'project.previous/'
    }
}
