<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42e081b9-58a9-4e13-8b33-aad4c1f05feb
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test private-state host-refresh pester
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
    The private state root and its helpers in automation/Yuruna.Common.psm1:
    owner-only creation, refusal (never a silent pass) when an owner cannot
    be read or does not match, the portable owner read and its BSD-safe
    fallback, links and aliases, served-tree containment, network file
    systems, home verification, observe-only mode (explicit or through an
    ambient -WhatIf), per-file paths under the root, and canonical path
    resolution. Every case runs against a temporary home, never $HOME.
#>

BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:SkipPermissionCase = $IsWindows
    if (-not $IsWindows) {
        $identity = Get-YurunaCurrentOwnerId
        if (-not $identity.Resolved -or $identity.IsRoot) { $script:SkipPermissionCase = $true }
    }
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:Me = Get-YurunaCurrentOwnerId
    $script:OwnerOnly = [IO.UnixFileMode]'UserRead, UserWrite, UserExecute'
    $script:TempDirs = [System.Collections.Generic.List[string]]::new()

    function New-TempHome {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture temp dir.')]
        param()
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-private'
        $script:TempDirs.Add($dir)
        return $dir
    }

    function Get-Mode {
        param([string]$Path)
        [IO.File]::GetUnixFileMode($Path)
    }
}

AfterAll {
    foreach ($dir in $script:TempDirs) {
        if (-not $IsWindows) {
            foreach ($d in @(Get-ChildItem -LiteralPath $dir -Recurse -Directory -Force -ErrorAction SilentlyContinue) + @(Get-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                try { if (-not $d.LinkTarget) { [IO.File]::SetUnixFileMode($d.FullName, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') } } catch { $null = $_ }
            }
        }
        Remove-YurunaTestTempDir $dir
    }
}

Describe 'Get-YurunaPrivateStateRoot -- creation' {
    It 'creates both directories owner-only and reports the owner as verified' {
        $homeDir = New-TempHome
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.Resolved      | Should -Be $true
        $r.Reason        | Should -Be 'ok'
        $r.OwnerVerified | Should -Be $true
        $r.HomeVerified  | Should -Be 'not-requested'
        $r.Path          | Should -Be (Join-Path (Join-Path $homeDir '.yuruna') 'host-refresh')
        $r.FileSystem    | Should -Not -BeNullOrEmpty
        [IO.Directory]::Exists($r.Path) | Should -Be $true
        if (-not $IsWindows) {
            (Get-Mode (Join-Path $homeDir '.yuruna')) | Should -Be $script:OwnerOnly
            (Get-Mode $r.Path) | Should -Be $script:OwnerOnly
        }
        $again = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $again.Resolved | Should -Be $true -Because 'resolving an existing, already secured root is idempotent'
    }

    It 'keeps the textual path while reporting the canonical one through a linked home' -Skip:$IsWindows {
        $base = New-TempHome
        $real = Join-Path $base 'real-home'
        $null = [IO.Directory]::CreateDirectory($real)
        $alias = Join-Path $base 'alias-home'
        $null = [IO.Directory]::CreateSymbolicLink($alias, $real)
        $r = Get-YurunaPrivateStateRoot -HomePath $alias
        $r.Resolved      | Should -Be $true
        $r.Path          | Should -Be (Join-Path $alias '.yuruna/host-refresh')
        $r.CanonicalPath | Should -Be ((Resolve-YurunaCanonicalPath -Path (Join-Path $real '.yuruna/host-refresh')).Path)
    }

    It 'tightens a loose existing root to owner-only, and only reports it under -NoCreate' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $root = Join-Path $homeDir '.yuruna/host-refresh'
        $null = [IO.Directory]::CreateDirectory((Join-Path $homeDir '.yuruna'), $script:OwnerOnly)
        $null = [IO.Directory]::CreateDirectory($root)
        $loose = [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupWrite, GroupExecute, OtherRead, OtherExecute'
        [IO.File]::SetUnixFileMode($root, $loose)
        $observed = Get-YurunaPrivateStateRoot -HomePath $homeDir -NoCreate
        $observed.Resolved | Should -Be $false
        $observed.Reason   | Should -Be 'permission-loose'
        (Get-Mode $root) | Should -Be $loose -Because 'an observation re-modes nothing'
        $fixed = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $fixed.Resolved | Should -Be $true
        (Get-Mode $root) | Should -Be $script:OwnerOnly
    }

    It 'creates nothing and reports absent under -NoCreate or an ambient -WhatIf' {
        $homeDir = New-TempHome
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir -NoCreate
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'absent'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false

        $inModule = & (Get-Module Yuruna.Common) { param($h) $WhatIfPreference = $true; Get-YurunaPrivateStateRoot -HomePath $h } $homeDir
        $inModule.Reason | Should -Be 'absent'

        $saved = $global:WhatIfPreference
        try {
            $global:WhatIfPreference = $true
            $ambient = Get-YurunaPrivateStateRoot -HomePath $homeDir
        } finally { $global:WhatIfPreference = $saved }
        $ambient.Reason | Should -Be 'absent'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false
    }

    It 'creates nothing when an advanced function in another module was given -WhatIf' {
        # That -WhatIf lives in the other module's session state, which this
        # module's own scope chain never reaches.
        $homeDir = New-TempHome
        $standIn = New-Module -Name 'Yuruna.PreviewStandIn' -ScriptBlock {
            function Invoke-PreviewStandIn {
                <#
                .SYNOPSIS
                    A caller in another module that resolves the private root
                    under its own -WhatIf.
                #>
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
                    Justification = 'Stand-in caller: it only carries -WhatIf into the call it makes.')]
                [CmdletBinding(SupportsShouldProcess)]
                param([string]$HomePath, [switch]$Subdirectory)
                if ($Subdirectory) { Get-YurunaPrivateStatePath -HomePath $HomePath -Name 'x.lock' -Subdirectory 'work' }
                else { Get-YurunaPrivateStateRoot -HomePath $HomePath }
            }
            Export-ModuleMember -Function Invoke-PreviewStandIn
        }
        try {
            (Invoke-PreviewStandIn -HomePath $homeDir -WhatIf).Reason | Should -Be 'absent'
            [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false
            (Invoke-PreviewStandIn -HomePath $homeDir).Reason | Should -Be 'ok' -Because 'without -WhatIf the same call creates the root'
            (Invoke-PreviewStandIn -HomePath $homeDir -Subdirectory -WhatIf).Reason | Should -Be 'absent'
            [IO.Directory]::Exists((Join-Path $homeDir '.yuruna/host-refresh/work')) | Should -Be $false
        } finally { Remove-Module -ModuleInfo $standIn -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses without a home directory' {
        $r = Get-YurunaPrivateStateRoot -HomePath ''
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'no-home'
    }

    It 'refuses a file where a directory should be' {
        $homeDir = New-TempHome
        [IO.File]::WriteAllText((Join-Path $homeDir '.yuruna'), 'not a directory')
        (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be 'resolve-failed'
    }

    It 'reports create-failed with the I/O kind when the home is not writable' -Skip:$script:SkipPermissionCase {
        $homeDir = New-TempHome
        [IO.File]::SetUnixFileMode($homeDir, [IO.UnixFileMode]'UserRead, UserExecute')
        try {
            $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
            $r.Reason | Should -Be 'create-failed'
            $r.IoKind | Should -Be 'access-denied'
        } finally { [IO.File]::SetUnixFileMode($homeDir, $script:OwnerOnly) }
    }
}

Describe 'Get-YurunaPrivateStateRoot -- links and parents' {
    It 'refuses a linked .yuruna and a linked host-refresh' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $elsewhere = Join-Path $homeDir 'elsewhere'
        $null = [IO.Directory]::CreateDirectory($elsewhere)
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $homeDir '.yuruna'), $elsewhere)
        (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be 'reparse-point'
        [IO.Directory]::Exists((Join-Path $elsewhere 'host-refresh')) | Should -Be $false -Because 'nothing is created through the link'

        $second = New-TempHome
        $null = [IO.Directory]::CreateDirectory((Join-Path $second '.yuruna'), $script:OwnerOnly)
        $target = Join-Path $second 'target'
        $null = [IO.Directory]::CreateDirectory($target)
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $second '.yuruna/host-refresh'), $target)
        (Get-YurunaPrivateStateRoot -HomePath $second).Reason | Should -Be 'reparse-point'
    }

    It 'refuses a .yuruna other users can write, and leaves its mode alone' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $parent = Join-Path $homeDir '.yuruna'
        $null = [IO.Directory]::CreateDirectory($parent)
        $open = [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupWrite, GroupExecute, OtherRead, OtherWrite, OtherExecute'
        [IO.File]::SetUnixFileMode($parent, $open)
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'parent-untrusted'
        (Get-Mode $parent) | Should -Be $open
    }

    It 'accepts a group-writable .yuruna only for the user''s own private group with no other member' -Skip:(-not $IsLinux) {
        $me = $script:Me
        $homeDir = New-TempHome
        $parent = Join-Path $homeDir '.yuruna'
        $null = [IO.Directory]::CreateDirectory($parent)
        [IO.File]::SetUnixFileMode($parent, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupWrite, GroupExecute, OtherRead, OtherExecute')
        $groupId = [string](Get-Item -Force -LiteralPath $parent).UnixStat.GroupId

        $private = [pscustomobject]@{ Resolved = $true; OwnerId = $me.OwnerId; UserName = 'someone'; IsRoot = $false; Elevated = $false
            PrimaryGroupId = $groupId; PrimaryGroupName = 'someone'; Reason = 'ok' }
        Mock -ModuleName Yuruna.Common Get-YurunaCurrentOwnerId { $private }.GetNewClosure()
        $complete = @{ ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $true; DrainTimedOut = $false
            KillFailed = $false; OutputTruncated = $false; ElapsedMs = 1; DeadlineExhausted = $false; ProcessId = 1 }
        $cases = @(
            @{ StdOut = "someone:x:${groupId}:`n"; Expected = 'ok'; Why = 'no member is listed' }
            @{ StdOut = "someone:x:${groupId}:someone`n"; Expected = 'ok'; Why = 'the only member is the user' }
            @{ StdOut = "someone:x:${groupId}:someone,mallory`n"; Expected = 'parent-untrusted'; Why = 'another member could swap the directory' }
            @{ StdOut = "wheel:x:${groupId}:`n"; Expected = 'parent-untrusted'; Why = 'the group does not carry the user''s name' }
            @{ StdOut = ''; ExitCode = 2; Expected = 'parent-untrusted'; Why = 'a group the database does not know is unproven' }
            @{ StdOut = "someone:x:${groupId}:`n"; TimedOut = $true; Expected = 'parent-untrusted'; Why = 'a lookup that did not answer refuses' }
            @{ StdOut = "someone:x:${groupId}:`n"; OutputTruncated = $true; Expected = 'parent-untrusted'; Why = 'partial output is not an answer' }
        )
        foreach ($case in $cases) {
            $answer = $complete.Clone()
            foreach ($key in @('StdOut', 'ExitCode', 'TimedOut', 'OutputTruncated')) { if ($case.ContainsKey($key)) { $answer[$key] = $case[$key] } }
            Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand { $answer }.GetNewClosure() -ParameterFilter { $FilePath -eq 'getent' }
            (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be $case.Expected -Because $case.Why
        }
        Should -Invoke -ModuleName Yuruna.Common Invoke-BoundedNativeCommand -ParameterFilter {
            $FilePath -eq 'getent' -and $ArgumentList[0] -eq 'group' -and $ArgumentList[1] -eq $groupId
        }

        $shared = [pscustomobject]@{ Resolved = $true; OwnerId = $me.OwnerId; UserName = 'someone'; IsRoot = $false; Elevated = $false
            PrimaryGroupId = $groupId; PrimaryGroupName = 'staff'; Reason = 'ok' }
        Mock -ModuleName Yuruna.Common Get-YurunaCurrentOwnerId { $shared }.GetNewClosure()
        (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be 'parent-untrusted' -Because 'a group other users share can swap the directory'
        (Get-Mode $parent) | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupWrite, GroupExecute, OtherRead, OtherExecute')
    }

    It 'treats a group as private only on Linux, where a bounded group lookup is made' {
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand { throw 'no lookup expected' } -ParameterFilter { $FilePath -eq 'getent' }
        $owner = [pscustomobject]@{ Resolved = $true; OwnerId = '501'; UserName = 'someone'; IsRoot = $false; Elevated = $false
            PrimaryGroupId = '501'; PrimaryGroupName = 'someone'; Reason = 'ok' }
        foreach ($platform in @('macos', 'windows')) {
            $private = & (Get-Module Yuruna.Common) { param($o, $p) Test-YurunaUserPrivateGroup -GroupId '501' -CurrentOwner $o -Platform $p } $owner $platform
            $private | Should -Be $false -Because "$platform has no bounded group lookup here"
        }
        Should -Invoke -ModuleName Yuruna.Common Invoke-BoundedNativeCommand -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'getent' }
    }
}

Describe 'Get-YurunaPrivateStateRoot -- owner checks fail closed' {
    It 'refuses when a directory''s owner cannot be read' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $false; OwnerId = $null; Reason = 'lookup-failed' } }
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.Resolved      | Should -Be $false
        $r.Reason        | Should -Be 'owner-unverified'
        $r.OwnerVerified | Should -Be $false
    }

    It 'refuses when a directory belongs to someone else' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPathOwnerId { [pscustomobject]@{ Resolved = $true; OwnerId = '99999'; Reason = 'ok' } }
        (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be 'owner-mismatch'
    }

    It 'refuses when the current identity cannot be read' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaCurrentOwnerId {
            [pscustomobject]@{ Resolved = $false; OwnerId = $null; UserName = $null; IsRoot = $false; Elevated = $false
                PrimaryGroupId = $null; PrimaryGroupName = $null; Reason = 'lookup-failed' }
        }
        (Get-YurunaPrivateStateRoot -HomePath $homeDir).Reason | Should -Be 'owner-unverified'
    }

    It 'accepts the Administrators owner on Windows only for an elevated process, for the root and every subdirectory alike' {
        $check = {
            param([string]$OwnerId, [bool]$Elevated, [string]$Platform, [bool]$Resolved = $true)
            $current = [pscustomobject]@{ Resolved = $Resolved; OwnerId = 'S-1-5-21-1-2-3-1001'; Elevated = $Elevated }
            Test-YurunaPrivateOwnerMatch -OwnerId $OwnerId -CurrentOwner $current -Platform $Platform
        }
        $common = Get-Module Yuruna.Common
        (& $common $check 'S-1-5-21-1-2-3-1001' $false 'windows') | Should -Be $true
        (& $common $check 's-1-5-21-1-2-3-1001' $false 'windows') | Should -Be $true -Because 'a SID compares without regard to case'
        (& $common $check 'S-1-5-32-544' $true 'windows') | Should -Be $true -Because 'an elevated process creates directories owned by Administrators'
        (& $common $check 'S-1-5-32-544' $false 'windows') | Should -Be $false
        (& $common $check 'S-1-5-32-544' $true 'linux') | Should -Be $false
        (& $common $check 'S-1-5-21-9-9-9-500' $true 'windows') | Should -Be $false
        (& $common $check '' $true 'windows') | Should -Be $false
        (& $common $check 'S-1-5-21-1-2-3-1001' $false 'windows' $false) | Should -Be $false -Because 'an unknown identity never matches'
        # One rule for the root and its subdirectories, so the two cannot drift.
        foreach ($name in @('Get-YurunaPrivateStateRoot', 'Get-YurunaPrivateStatePath')) {
            $calls = (Get-Command -Name $name).ScriptBlock.Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Confirm-YurunaPrivateDirectory'
                }, $true)
            @($calls).Count | Should -BeGreaterOrEqual 1 -Because "$name decides ownership through the shared rule"
        }
    }
}

Describe 'Owner and identity helpers' {
    It 'reads this process''s identity and the owner of a file it created as the same id' {
        $me = Get-YurunaCurrentOwnerId
        $me.Resolved | Should -Be $true
        $me.OwnerId  | Should -Not -BeNullOrEmpty
        $me.UserName | Should -Not -BeNullOrEmpty
        $homeDir = New-TempHome
        $file = Join-Path $homeDir 'owned.txt'
        [IO.File]::WriteAllText($file, '')
        $owner = Get-YurunaPathOwnerId -Path $file
        $owner.Resolved | Should -Be $true
        # An elevated Windows process creates files owned by the Administrators
        # group rather than by its user (the rule Test-YurunaPrivateOwnerMatch applies).
        $expectedOwner = if ($IsWindows -and $me.Elevated) { 'S-1-5-32-544' } else { $me.OwnerId }
        $owner.OwnerId  | Should -Be $expectedOwner
        if (-not $IsWindows) {
            $me.OwnerId | Should -Match '^\d+$'
            $me.IsRoot  | Should -Be ($me.OwnerId -eq '0')
        }
        (Get-YurunaPathOwnerId -Path (Join-Path $homeDir 'missing')).Reason | Should -Be 'not-found'
    }

    It 'falls back to stat with the platform''s own flag spelling, and fails closed when that fails too' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $file = Join-Path $homeDir 'owned.txt'
        [IO.File]::WriteAllText($file, '')
        Mock -ModuleName Yuruna.Common Get-YurunaUnixPathStat { $null }
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand {
            @{ ExitCode = 0; StdOut = "1234`n"; StdErr = ''; TimedOut = $false; Started = $true; DrainTimedOut = $false
                KillFailed = $false; OutputTruncated = $false; ElapsedMs = 1; DeadlineExhausted = $false; ProcessId = 1 }
        } -ParameterFilter { $FilePath -eq 'stat' }
        $mac = Get-YurunaPathOwnerId -Path $file -Platform macos
        $mac.OwnerId | Should -Be '1234'
        Should -Invoke -ModuleName Yuruna.Common Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'stat' -and $ArgumentList[0] -eq '-f' -and $ArgumentList[1] -eq '%u' -and $ArgumentList[2] -eq $file
        }
        $linux = Get-YurunaPathOwnerId -Path $file -Platform linux
        $linux.OwnerId | Should -Be '1234'
        Should -Invoke -ModuleName Yuruna.Common Invoke-BoundedNativeCommand -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'stat' -and $ArgumentList[0] -eq '-c' -and $ArgumentList[1] -eq '%u'
        }
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand {
            @{ ExitCode = 1; StdOut = ''; StdErr = 'stat: illegal option -- c'; TimedOut = $false; Started = $true }
        } -ParameterFilter { $FilePath -eq 'stat' }
        $failed = Get-YurunaPathOwnerId -Path $file -Platform macos
        $failed.Resolved | Should -Be $false
        $failed.Reason   | Should -Be 'lookup-failed'
        $failed.OwnerId  | Should -BeNullOrEmpty
    }

    It 'reports the effective ids when id prints euid and egid beside the real ones' -Skip:$IsWindows {
        # id leads with the REAL uid and gid; the effective ones appear only
        # when they differ, and they are what ownership checks compare.
        $common = Get-Module Yuruna.Common
        $clearCache = { $script:YurunaCurrentOwnerCache = $null }
        $answer = @{ ExitCode = 0; StdOut = ''; StdErr = ''; TimedOut = $false; Started = $true; DrainTimedOut = $false
            KillFailed = $false; OutputTruncated = $false; ElapsedMs = 1; DeadlineExhausted = $false; ProcessId = 1 }
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand { $answer }.GetNewClosure() -ParameterFilter { $FilePath -eq 'id' }
        try {
            & $common $clearCache
            $answer.StdOut = "uid=1001(alice) gid=1001(alice) euid=0(root) egid=0(root) groups=1001(alice),27(sudo)`n"
            $r = Get-YurunaCurrentOwnerId
            $r.OwnerId          | Should -Be '0'
            $r.UserName         | Should -Be 'root'
            $r.IsRoot           | Should -Be $true
            $r.PrimaryGroupId   | Should -Be '0'
            $r.PrimaryGroupName | Should -Be 'root'

            & $common $clearCache
            $answer.StdOut = "uid=0(root) gid=0(root) euid=1001(alice) groups=0(root)`n"
            $r = Get-YurunaCurrentOwnerId
            $r.OwnerId        | Should -Be '1001'
            $r.UserName       | Should -Be 'alice'
            $r.IsRoot         | Should -Be $false
            $r.PrimaryGroupId | Should -Be '0' -Because 'without egid the real gid is also the effective one'

            & $common $clearCache
            $answer.StdOut = "uid=1001(alice) gid=1001(alice) groups=1001(alice),27(sudo)`n"
            $r = Get-YurunaCurrentOwnerId
            $r.OwnerId          | Should -Be '1001'
            $r.PrimaryGroupName | Should -Be 'alice'
        } finally { & $common $clearCache }
    }

    It 'treats a timed-out stat fallback as unknown, never as an owner' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $file = Join-Path $homeDir 'owned.txt'
        [IO.File]::WriteAllText($file, '')
        Mock -ModuleName Yuruna.Common Get-YurunaUnixPathStat { $null }
        Mock -ModuleName Yuruna.Common Invoke-BoundedNativeCommand {
            @{ ExitCode = 124; StdOut = '1001'; StdErr = ''; TimedOut = $true; Started = $true }
        } -ParameterFilter { $FilePath -eq 'stat' }
        (Get-YurunaPathOwnerId -Path $file).Resolved | Should -Be $false
    }
}

Describe 'Get-YurunaPrivateStateRoot -- served trees and file systems' {
    It 'refuses a root inside a served tree, a served tree reached through an alias, and a served tree inside the root' -Skip:$IsWindows {
        $homeDir = New-TempHome
        (Get-YurunaPrivateStateRoot -HomePath $homeDir -ServedRoot @($homeDir)).Reason | Should -Be 'served-tree'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false -Because 'containment is checked before anything is created'

        $base = New-TempHome
        $alias = Join-Path $base 'served-alias'
        $null = [IO.Directory]::CreateSymbolicLink($alias, $homeDir)
        (Get-YurunaPrivateStateRoot -HomePath $homeDir -ServedRoot @($alias)).Reason | Should -Be 'served-tree'

        (Get-YurunaPrivateStateRoot -HomePath $homeDir -ServedRoot @((Join-Path $homeDir '.yuruna/host-refresh/work'))).Reason | Should -Be 'served-tree'

        $unrelated = Get-YurunaPrivateStateRoot -HomePath $homeDir -ServedRoot @($base, '', (Join-Path $homeDir 'repo'))
        $unrelated.Resolved | Should -Be $true
    }

    It 'refuses a network file system before creating anything' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPathDriveInfo {
            [pscustomobject]@{ Resolved = $true; MountPoint = '/'; DriveType = 'Network'; FileSystem = 'nfs'; Reason = 'ok' }
        }
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.Reason     | Should -Be 'network-filesystem'
        $r.FileSystem | Should -Be 'nfs'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false
    }

    It 'refuses, creating nothing, when the mount that would hold the root cannot be identified' {
        # Skipping the network check for an unknown mount would accept the
        # very location it exists to exclude, such as a Windows UNC home.
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPathDriveInfo {
            [pscustomobject]@{ Resolved = $false; MountPoint = $null; DriveType = $null; FileSystem = $null; Reason = 'no-mount' }
        }
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'resolve-failed'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false
    }

    It 'reports the local file system that holds the root' {
        $homeDir = New-TempHome
        $drive = Get-YurunaPathDriveInfo -Path $homeDir
        $drive.Resolved   | Should -Be $true
        $drive.MountPoint | Should -Not -BeNullOrEmpty
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
        $r.FileSystem | Should -Be $drive.FileSystem
        $r.DriveType  | Should -Be $drive.DriveType
        $r.DriveType  | Should -Not -Be 'Network'
    }
}

Describe 'Get-YurunaPrivateStateRoot -VerifyHome' {
    It 'verifies a home that matches the account database' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPasswdHome { $homeDir }.GetNewClosure()
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir -VerifyHome
        $r.Resolved     | Should -Be $true
        $r.HomeVerified | Should -Be 'verified'
    }

    It 'refuses a home that differs from the account database, creating nothing' {
        $homeDir = New-TempHome
        $other = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPasswdHome { $other }.GetNewClosure()
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir -VerifyHome
        $r.Resolved     | Should -Be $false
        $r.Reason       | Should -Be 'home-mismatch'
        $r.HomeVerified | Should -Be 'mismatch'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false
    }

    It 'resolves but reports unverified when the account database cannot be read' {
        $homeDir = New-TempHome
        Mock -ModuleName Yuruna.Common Get-YurunaPasswdHome { $null }
        $r = Get-YurunaPrivateStateRoot -HomePath $homeDir -VerifyHome
        $r.Resolved     | Should -Be $true
        $r.HomeVerified | Should -Be 'unverified'
    }

    It 'reads the account database home for this user on this host' -Skip:$IsWindows {
        $recorded = & (Get-Module Yuruna.Common) { Get-YurunaPasswdHome }
        $recorded | Should -Not -BeNullOrEmpty
        [IO.Directory]::Exists($recorded) | Should -Be $true
    }
}

Describe 'Get-YurunaPrivateStatePath' {
    It 'returns a leaf path under an owner-only subdirectory without creating the leaf' {
        $homeDir = New-TempHome
        $r = Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'stdin.empty' -Subdirectory 'work'
        $r.Resolved | Should -Be $true
        $r.Path     | Should -Be (Join-Path $homeDir '.yuruna/host-refresh/work/stdin.empty')
        [IO.File]::Exists($r.Path) | Should -Be $false
        [IO.Directory]::Exists((Split-Path -Parent $r.Path)) | Should -Be $true
        if (-not $IsWindows) { (Get-Mode (Split-Path -Parent $r.Path)) | Should -Be $script:OwnerOnly }
        $leaf = Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'host-refresh.journal'
        $leaf.Path | Should -Be (Join-Path $homeDir '.yuruna/host-refresh/host-refresh.journal')
    }

    It 'refuses names that could leave the root or hide a file' {
        $homeDir = New-TempHome
        foreach ($name in @('../x', 'a/b', '', '.hidden', 'a b', ('x' * 129), 'a\b')) {
            (Get-YurunaPrivateStatePath -HomePath $homeDir -Name $name).Reason | Should -Be 'invalid-name' -Because "'$name' is not a plain file name"
        }
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'ok.lock' -Subdirectory '..').Reason | Should -Be 'invalid-name'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna')) | Should -Be $false -Because 'an invalid name is refused before the root is touched'
    }

    It 'observes a missing subdirectory without creating it and reports a loose one' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $null = Get-YurunaPrivateStateRoot -HomePath $homeDir
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'x' -Subdirectory 'work' -NoCreate).Reason | Should -Be 'absent'
        [IO.Directory]::Exists((Join-Path $homeDir '.yuruna/host-refresh/work')) | Should -Be $false
        $work = Join-Path $homeDir '.yuruna/host-refresh/work'
        $null = [IO.Directory]::CreateDirectory($work)
        [IO.File]::SetUnixFileMode($work, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute')
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'x' -Subdirectory 'work' -NoCreate).Reason | Should -Be 'permission-loose'
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'x' -Subdirectory 'work').Resolved | Should -Be $true
        (Get-Mode $work) | Should -Be $script:OwnerOnly
    }

    It 'refuses a linked subdirectory or leaf' -Skip:$IsWindows {
        $homeDir = New-TempHome
        $root = (Get-YurunaPrivateStateRoot -HomePath $homeDir).Path
        $outside = Join-Path $homeDir 'outside'
        $null = [IO.Directory]::CreateDirectory($outside)
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $root 'work'), $outside)
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'x' -Subdirectory 'work').Reason | Should -Be 'reparse-point'
        $null = [IO.File]::CreateSymbolicLink((Join-Path $root 'journal'), (Join-Path $outside 'target'))
        (Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'journal').Reason | Should -Be 'reparse-point'
    }

    It 'passes a root refusal through unchanged' {
        $homeDir = New-TempHome
        $r = Get-YurunaPrivateStatePath -HomePath $homeDir -Name 'x.lock' -NoCreate
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'absent'
        $r.Path     | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-YurunaCanonicalPath' {
    It 'resolves nested and relative links and keeps a missing tail' -Skip:$IsWindows {
        $base = New-TempHome
        $real = Join-Path $base 'real'
        $null = [IO.Directory]::CreateDirectory((Join-Path $real 'deep'))
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $base 'hop1'), $real)
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $base 'hop2'), 'hop1')
        $expectedBase = (Resolve-YurunaCanonicalPath -Path $base).Path
        $r = Resolve-YurunaCanonicalPath -Path (Join-Path $base 'hop2/deep/not/yet')
        $r.Resolved  | Should -Be $true
        $r.Reason    | Should -Be 'ok'
        $r.LinkCount | Should -BeGreaterOrEqual 2
        $r.Path      | Should -Be (Join-Path $expectedBase 'real/deep/not/yet')
    }

    It 'applies .. after a link to the link''s target, the way the kernel does' -Skip:$IsWindows {
        $base = New-TempHome
        $null = [IO.Directory]::CreateDirectory((Join-Path $base 'a/b'))
        $null = [IO.Directory]::CreateSymbolicLink((Join-Path $base 'link'), (Join-Path $base 'a/b'))
        $expectedBase = (Resolve-YurunaCanonicalPath -Path $base).Path
        (Resolve-YurunaCanonicalPath -Path (Join-Path $base 'link/..')).Path | Should -Be (Join-Path $expectedBase 'a')
    }

    It 'reports a link loop instead of spinning' -Skip:$IsWindows {
        $base = New-TempHome
        $null = [IO.File]::CreateSymbolicLink((Join-Path $base 'loop1'), (Join-Path $base 'loop2'))
        $null = [IO.File]::CreateSymbolicLink((Join-Path $base 'loop2'), (Join-Path $base 'loop1'))
        $r = Resolve-YurunaCanonicalPath -Path (Join-Path $base 'loop1/x') -MaxLinks 8
        $r.Resolved | Should -Be $false
        $r.Reason   | Should -Be 'link-loop'
    }

    It 'resolves a relative path against the current location' {
        $base = New-TempHome
        Push-Location -LiteralPath $base
        try {
            $r = Resolve-YurunaCanonicalPath -Path 'child/./file.txt'
            $r.Path | Should -Be (Join-Path (Resolve-YurunaCanonicalPath -Path $base).Path 'child/file.txt')
        } finally { Pop-Location }
    }
}

# Defined only where it can run: a new suite may not carry skips, and the
# Windows ACL case has nothing to exercise on another platform.
if ($IsWindows) {
    Describe 'Windows owner and ACL' {
        It 'secures the root to the current identity alone' {
            $homeDir = New-TempHome
            $r = Get-YurunaPrivateStateRoot -HomePath $homeDir
            $r.Resolved | Should -Be $true
            $acl = Get-Acl -LiteralPath $r.Path
            $acl.AreAccessRulesProtected | Should -Be $true
            $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            foreach ($rule in @($acl.Access)) {
                $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value | Should -Be $me
            }
            (Get-YurunaPrivateStateRoot -HomePath $homeDir -NoCreate).Reason | Should -Be 'ok'
        }
    }
}
