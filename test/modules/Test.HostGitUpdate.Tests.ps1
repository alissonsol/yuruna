<#PSScriptInfo
.VERSION 2026.10.22
.GUID 421e5032-3844-4d14-b69c-9033a127d516
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git update pester
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
    Exercise repository updates against real, disposable Git histories.
.DESCRIPTION
    A deployment follows its configured upstream snapshot even when that
    history is replaced. The source snapshot must be exact, but operator
    configuration and local files must never be overwritten to obtain it.
    The fixtures use file URLs so shallow-clone behavior is real and no
    network, customer checkout or global Git configuration is involved.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -Force -DisableNameChecking
    $script:RealUpdateGit = & (Get-Module Test.HostGit) { Get-Command Invoke-GitUpdateCommand }

    function Invoke-FixtureGit {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
        $output = @(& git -C $Path @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $($Arguments -join ' '): $($output -join ' ')" }
        return ($output -join "`n").Trim()
    }

    function Set-FixtureFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only disposable fixture files under Pester TestDrive.')]
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name, [string]$Text = 'new source')
        $path = Join-Path $Root $Name
        [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
        [IO.File]::WriteAllText($path, $Text)
    }

    function New-UpdateFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates only disposable local repositories under Pester TestDrive.')]
        param([switch]$Shallow)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $remote = Join-Path $root 'remote'
        $local = Join-Path $root 'customer'
        [IO.Directory]::CreateDirectory($remote) | Out-Null
        $null = Invoke-FixtureGit $remote @('init', '--quiet', '--initial-branch=main')
        $null = Invoke-FixtureGit $remote @('config', 'user.name', 'fixture')
        $null = Invoke-FixtureGit $remote @('config', 'user.email', 'fixture@example.invalid')
        Set-FixtureFile -Root $remote -Name 'source.txt' -Text 'old source'
        Set-FixtureFile -Root $remote -Name 'removed.txt' -Text 'removed by the next release'
        Set-FixtureFile -Root $remote -Name '.gitignore' -Text "test.config.yml`nruntime/`nprivate/`nlog/`noperator-*`n"
        $null = Invoke-FixtureGit $remote @('add', '.')
        $null = Invoke-FixtureGit $remote @('commit', '--quiet', '-m', 'old release')
        $url = ([UriBuilder]::new('file', '', -1, $remote)).Uri.AbsoluteUri
        $arguments = @('clone', '--quiet')
        if ($Shallow) { $arguments += @('--depth', '1') }
        $null = Invoke-FixtureGit $root ($arguments + @($url, $local))
        $null = Invoke-FixtureGit $local @('config', 'user.name', 'fixture')
        $null = Invoke-FixtureGit $local @('config', 'user.email', 'fixture@example.invalid')
        return @{ Root = $root; Remote = $remote; Local = $local; Url = $url;
            Original = (Invoke-FixtureGit $local @('rev-parse', 'HEAD')) }
    }

    function Add-FixtureRelease {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Commits only disposable source fixtures under Pester TestDrive.')]
        param([Parameter(Mandatory)][hashtable]$Fixture, [switch]$Unrelated, [string]$AddedPath = 'added.txt')
        if ($Unrelated) {
            $null = Invoke-FixtureGit $Fixture.Remote @('checkout', '--quiet', '--orphan', 'replacement')
            $null = Invoke-FixtureGit $Fixture.Remote @('rm', '--quiet', '-rf', '.')
            Set-FixtureFile -Root $Fixture.Remote -Name '.gitignore' -Text "test.config.yml`nruntime/`nprivate/`nlog/`noperator-*`n"
        } else {
            $null = Invoke-FixtureGit $Fixture.Remote @('rm', '--quiet', 'removed.txt')
        }
        Set-FixtureFile -Root $Fixture.Remote -Name 'source.txt' -Text 'new source'
        Set-FixtureFile -Root $Fixture.Remote -Name $AddedPath
        $null = Invoke-FixtureGit $Fixture.Remote @('add', '--force', '.')
        $null = Invoke-FixtureGit $Fixture.Remote @('commit', '--quiet', '-m', 'new release')
        if ($Unrelated) { $null = Invoke-FixtureGit $Fixture.Remote @('branch', '-M', 'main') }
        return (Invoke-FixtureGit $Fixture.Remote @('rev-parse', 'HEAD'))
    }

    function Confirm-FixtureUnchanged {
        param([Parameter(Mandatory)][hashtable]$Fixture)
        Invoke-FixtureGit $Fixture.Local @('rev-parse', 'HEAD') | Should -BeExactly $Fixture.Original
        Get-Content -LiteralPath (Join-Path $Fixture.Local 'source.txt') -Raw | Should -BeExactly 'old source'
        Test-Path -LiteralPath (Join-Path $Fixture.Local 'removed.txt') | Should -BeTrue
    }
}

Describe 'A framework checkout follows an upstream snapshot independently of ancestry' {
    It 'installs the selected snapshot when the upstream advances after selection' {
        $f = New-UpdateFixture
        $selected = Add-FixtureRelease $f
        $context = @{ mode = 'off' }
        $selection = Resolve-GitSourceSelection -RepositoryUrl $f.Url -Ref refs/heads/main -SourceContext $context -Operation Framework
        $selection.success | Should -BeTrue -Because $selection.detail
        $selection.selectedSha | Should -BeExactly $selected
        Set-FixtureFile -Root $f.Remote -Name 'later.txt' -Text 'next generation'
        $null = Invoke-FixtureGit $f.Remote @('add', '.')
        $null = Invoke-FixtureGit $f.Remote @('commit', '--quiet', '-m', 'later release')
        $later = Invoke-FixtureGit $f.Remote @('rev-parse', 'HEAD')
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local -SourceContext $context -SourceSelection $selection -Confirm:$false
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        $result.Revision | Should -BeExactly $selected
        $result.Revision | Should -Not -Be $later
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $selected
        Invoke-FixtureGit $f.Local @('remote', 'get-url', 'origin') | Should -BeExactly $f.Url
        Invoke-FixtureGit $f.Local @('for-each-ref', '--format=%(refname)', 'refs/yuruna/source-candidates') | Should -BeNullOrEmpty
        $result.SourceSelection.selectedSha | Should -BeExactly $selected
    }

    It 'installs the exact <History> snapshot from a <Clone> clone and preserves operator state' -TestCases @(
        @{ History = 'ordinary'; Clone = 'full'; Unrelated = $false; Shallow = $false }
        @{ History = 'unrelated'; Clone = 'full'; Unrelated = $true; Shallow = $false }
        @{ History = 'ordinary'; Clone = 'shallow'; Unrelated = $false; Shallow = $true }
        @{ History = 'unrelated'; Clone = 'shallow'; Unrelated = $true; Shallow = $true }
    ) {
        param($Unrelated, $Shallow)
        $f = New-UpdateFixture -Shallow:$Shallow
        $preserved = @{
            'test.config.yml' = "repositories:`n  projectUrl: file:///operator/project`n"
            'runtime/host.uuid' = 'operator-host-identity'
            'private/credential.txt' = 'operator-private-state'
            'log/retained.txt' = 'previous cycle evidence'
            'operator-note.txt' = 'ignored operator note'
            'local-note.txt' = 'untracked operator note'
        }
        foreach ($path in $preserved.Keys) { Set-FixtureFile -Root $f.Local -Name $path -Text $preserved[$path] }
        $target = Add-FixtureRelease $f -Unrelated:$Unrelated
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        $result.Changed | Should -BeTrue
        $result.PreviousRevision | Should -BeExactly $f.Original
        $result.Revision | Should -BeExactly $target
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $target
        Invoke-FixtureGit $f.Local @('diff', '--name-only', 'HEAD') | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $f.Local 'removed.txt') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $f.Local 'added.txt') -Raw | Should -BeExactly 'new source'
        foreach ($path in $preserved.Keys) {
            Get-Content -LiteralPath (Join-Path $f.Local $path) -Raw | Should -BeExactly $preserved[$path]
        }
        Invoke-FixtureGit $f.Local @('rev-parse', $result.BackupRef) | Should -BeExactly $f.Original
        $again = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $again.Success | Should -BeTrue
        $again.Changed | Should -BeFalse
    }

    It 'preserves a clean local commit in a recoverable ref and installs the remote source' {
        $f = New-UpdateFixture
        Set-FixtureFile -Root $f.Local -Name 'local-committed.txt' -Text 'customer source modification'
        $null = Invoke-FixtureGit $f.Local @('add', '.')
        $null = Invoke-FixtureGit $f.Local @('commit', '--quiet', '-m', 'local customization')
        $previous = Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD')
        $target = Add-FixtureRelease $f
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        $result.Revision | Should -BeExactly $target
        Invoke-FixtureGit $f.Local @('rev-parse', $result.BackupRef) | Should -BeExactly $previous
        Invoke-FixtureGit $f.Local @('show', ($result.BackupRef + ':local-committed.txt')) |
            Should -BeExactly 'customer source modification'
        Test-Path -LiteralPath (Join-Path $f.Local 'local-committed.txt') | Should -BeFalse
    }

    It 'follows an intentional upstream rewind and retains the displaced revision' {
        $f = New-UpdateFixture
        $advanced = Add-FixtureRelease $f
        (Invoke-GitRepositoryUpdate -RepoRoot $f.Local).Success | Should -BeTrue
        $null = Invoke-FixtureGit $f.Remote @('reset', '--hard', $f.Original)
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        $result.Revision | Should -BeExactly $f.Original
        Invoke-FixtureGit $f.Local @('rev-parse', $result.BackupRef) | Should -BeExactly $advanced
        Test-Path -LiteralPath (Join-Path $f.Local 'removed.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $f.Local 'added.txt') | Should -BeFalse
    }

    It 'uses the configured upstream remote and branch instead of assuming origin main' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('remote', 'rename', 'origin', 'release')
        $null = Invoke-FixtureGit $f.Remote @('checkout', '--quiet', '-b', 'stable')
        $null = Invoke-FixtureGit $f.Local @('config', 'branch.main.merge', 'refs/heads/stable')
        $target = Add-FixtureRelease $f
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        $result.Revision | Should -BeExactly $target
    }
}

Describe 'An update never overwrites operator work' {
    It 'preserves a <Kind> sibling when a release adds source in the same directory' -TestCases @(
        @{ Kind = 'untracked'; Directory = 'package' }
        @{ Kind = 'ignored'; Directory = 'operator-package' }
    ) {
        param($Directory)
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath "$Directory/source.txt"
        Set-FixtureFile -Root $f.Local -Name "$Directory/note.txt" -Text 'operator sibling'
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue -Because $result.ErrorMessage
        Get-Content -LiteralPath (Join-Path $f.Local "$Directory/note.txt") -Raw | Should -BeExactly 'operator sibling'
        Get-Content -LiteralPath (Join-Path $f.Local "$Directory/source.txt") -Raw | Should -BeExactly 'new source'
    }

    It 'refuses <Kind> tracked changes without moving HEAD or changing the index' -TestCases @(
        @{ Kind = 'unstaged'; Stage = $false }
        @{ Kind = 'staged'; Stage = $true }
    ) {
        param($Stage)
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f
        Set-FixtureFile -Root $f.Local -Name 'source.txt' -Text 'operator edit'
        if ($Stage) { $null = Invoke-FixtureGit $f.Local @('add', 'source.txt') }
        $status = Invoke-FixtureGit $f.Local @('status', '--porcelain')
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Not -BeNullOrEmpty
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $f.Original
        Invoke-FixtureGit $f.Local @('status', '--porcelain') | Should -BeExactly $status
        Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw | Should -BeExactly 'operator edit'
    }

    It 'refuses a <Kind> file occupying incoming source' -TestCases @(
        @{ Kind = 'untracked'; Name = 'new.txt' }
        @{ Kind = 'ignored'; Name = 'operator-new.txt' }
    ) {
        param($Name)
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath $Name
        Set-FixtureFile -Root $f.Local -Name $Name -Text 'operator file'
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Confirm-FixtureUnchanged $f
        Get-Content -LiteralPath (Join-Path $f.Local $Name) -Raw | Should -BeExactly 'operator file'
    }

    It 'refuses a local file obstructing a new source directory' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath 'package/new.txt'
        Set-FixtureFile -Root $f.Local -Name 'package' -Text 'operator file'
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Confirm-FixtureUnchanged $f
        Get-Content -LiteralPath (Join-Path $f.Local 'package') -Raw | Should -BeExactly 'operator file'
    }

    It 'refuses a local directory occupying a new source file' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath 'package'
        Set-FixtureFile -Root $f.Local -Name 'package/operator.txt' -Text 'operator data'
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Confirm-FixtureUnchanged $f
        Get-Content -LiteralPath (Join-Path $f.Local 'package/operator.txt') -Raw | Should -BeExactly 'operator data'
    }

    It 'refuses an empty directory occupying a new source file' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath 'package'
        [IO.Directory]::CreateDirectory((Join-Path $f.Local 'package')) | Out-Null
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Confirm-FixtureUnchanged $f
        Test-Path -LiteralPath (Join-Path $f.Local 'package') -PathType Container | Should -BeTrue
    }

    It 'refuses a directory link in the incoming path without touching its target' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f -AddedPath 'package/new.txt'
        $outside = Join-Path $f.Root 'operator-directory'
        Set-FixtureFile -Root $outside -Name 'new.txt' -Text 'operator data'
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $kind -Path (Join-Path $f.Local 'package') -Target $outside | Out-Null
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Confirm-FixtureUnchanged $f
        Get-Content -LiteralPath (Join-Path $outside 'new.txt') -Raw | Should -BeExactly 'operator data'
        (Get-Item -LiteralPath (Join-Path $f.Local 'package')).LinkType | Should -Not -BeNullOrEmpty
    }
}

Describe 'Refusal and interruption leave a usable framework checkout' {
    It 'keeps an unfinished merge and its conflicted index for the operator' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('checkout', '--quiet', '-b', 'operator-branch')
        Set-FixtureFile -Root $f.Local -Name 'source.txt' -Text 'first operator change'
        $null = Invoke-FixtureGit $f.Local @('commit', '--quiet', '-am', 'first change')
        $null = Invoke-FixtureGit $f.Local @('checkout', '--quiet', 'main')
        Set-FixtureFile -Root $f.Local -Name 'source.txt' -Text 'second operator change'
        $null = Invoke-FixtureGit $f.Local @('commit', '--quiet', '-am', 'second change')
        & git -C $f.Local merge operator-branch 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
        $index = Invoke-FixtureGit $f.Local @('ls-files', '--unmerged')
        $head = Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD')
        $source = Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match 'unfinished|merge'
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $head
        Invoke-FixtureGit $f.Local @('ls-files', '--unmerged') | Should -BeExactly $index
        Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw | Should -BeExactly $source
        Test-Path -LiteralPath (Join-Path $f.Local '.git/MERGE_HEAD') | Should -BeTrue
    }

    It 'keeps an intentional detached pin without contacting a remote' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('checkout', '--quiet', '--detach')
        $null = Add-FixtureRelease $f
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'a pinned checkout must not fetch' }
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue
        $result.Skipped | Should -BeTrue
        Confirm-FixtureUnchanged $f
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly
    }

    It 'leaves a pinned checkout and its tracked operator edits outside automatic updates' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('checkout', '--quiet', '--detach')
        Set-FixtureFile -Root $f.Local -Name 'source.txt' -Text 'operator edit at a fixed release'
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { throw 'a pinned checkout must not fetch' }
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeTrue
        $result.Skipped | Should -BeTrue
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $f.Original
        Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw | Should -BeExactly 'operator edit at a fixed release'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Times 0 -Exactly
    }

    It 'reports an attached branch with no upstream without changing its source' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('branch', '--unset-upstream')
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match 'upstream|tracking'
        Confirm-FixtureUnchanged $f
    }

    It 'preserves the active source when its remote cannot be reached' {
        $f = New-UpdateFixture
        $null = Invoke-FixtureGit $f.Local @('remote', 'set-url', 'origin', (Join-Path $f.Root 'missing-remote'))
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Not -BeNullOrEmpty
        Confirm-FixtureUnchanged $f
    }

    It 'surfaces <Kind> without applying any fetched source' -TestCases @(
        @{ Kind = 'authentication rejection'; Code = 128; Message = 'fatal: Authentication failed' }
        @{ Kind = 'network timeout'; Code = 124; Message = 'git operation timed out' }
    ) {
        param($Code, $Message)
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f
        $script:NetworkFailure = @{ ExitCode = $Code; Output = $Message }
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommand { $script:NetworkFailure }
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match ([regex]::Escape($Message))
        Confirm-FixtureUnchanged $f
        Should -Invoke -ModuleName Test.HostGit Invoke-GitNetworkCommand -Exactly -Times 1
    }

    It 'preserves source under an index lock and completes after the lock is released' {
        $f = New-UpdateFixture
        $target = Add-FixtureRelease $f
        $lockPath = Join-Path $f.Local '.git/index.lock'
        [IO.File]::WriteAllText($lockPath, 'held by another process')
        try {
            $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
            $result.Success | Should -BeFalse
            Confirm-FixtureUnchanged $f
            Get-Content -LiteralPath $lockPath -Raw | Should -BeExactly 'held by another process'
        } finally { Remove-Item -LiteralPath $lockPath -Force }
        $retry = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $retry.Success | Should -BeTrue -Because $retry.ErrorMessage
        $retry.Revision | Should -BeExactly $target
    }

    It 'refuses to update when the previous revision cannot be retained' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f
        Set-FixtureFile -Root $f.Local -Name '.git/refs/yuruna/update-backups' -Text 'operator obstruction'
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match 'preserve|backup'
        Confirm-FixtureUnchanged $f
        Get-Content -LiteralPath (Join-Path $f.Local '.git/refs/yuruna/update-backups') -Raw |
            Should -BeExactly 'operator obstruction'
    }

    It 'protects a tracked edit made after update preparation but before application' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f
        Mock -ModuleName Test.HostGit Invoke-GitUpdateCommand {
            if ($ArgumentList[0] -eq 'reset') {
                [IO.File]::WriteAllText((Join-Path $RepoRoot 'source.txt'), 'concurrent operator edit')
            }
            & $script:RealUpdateGit @PesterBoundParameters
        }
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        Invoke-FixtureGit $f.Local @('rev-parse', 'HEAD') | Should -BeExactly $f.Original
        Invoke-FixtureGit $f.Local @('rev-parse', $result.BackupRef) | Should -BeExactly $f.Original
        Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw | Should -BeExactly 'concurrent operator edit'
    }

    It 'retains the recovery ref and refuses another apply after an interrupted partial write' {
        $f = New-UpdateFixture
        $null = Add-FixtureRelease $f
        Mock -ModuleName Test.HostGit Invoke-GitUpdateCommand {
            if ($ArgumentList[0] -eq 'reset') {
                [IO.File]::WriteAllText((Join-Path $RepoRoot 'source.txt'), 'partially applied source')
                return @{ ExitCode = 124; Output = ''; Error = 'interrupted checkout' }
            }
            & $script:RealUpdateGit @PesterBoundParameters
        }
        $result = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match 'interrupted checkout'
        $result.ErrorMessage | Should -Match ([regex]::Escape($result.BackupRef))
        Invoke-FixtureGit $f.Local @('rev-parse', $result.BackupRef) | Should -BeExactly $f.Original
        $retry = Invoke-GitRepositoryUpdate -RepoRoot $f.Local
        $retry.Success | Should -BeFalse
        $retry.ErrorMessage | Should -Match 'local changes'
        Get-Content -LiteralPath (Join-Path $f.Local 'source.txt') -Raw | Should -BeExactly 'partially applied source'
        Should -Invoke -ModuleName Test.HostGit Invoke-GitUpdateCommand -Exactly -Times 1 -ParameterFilter {
            $ArgumentList[0] -eq 'reset'
        }
    }
}
