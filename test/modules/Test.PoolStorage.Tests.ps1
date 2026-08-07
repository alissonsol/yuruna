<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42d6f9b2-0c4e-4a38-9b7d-2e3f4a5b6c7d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool storage smb pester
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
    Pester coverage for the pure (no-I/O) parts of Test.PoolStorage.psm1: the
    config accessor (off/on cases), SMB path normalization, and the Linux
    credentials-file body. The actual mount/copy are integration-verified on a
    real share (they touch the OS network stack).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.PoolStorage.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Null { param($Actual, [string]$Because = '') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

# Build a ledger object the way Read-PoolStorageLedger would (replicated map +
# scalar status), for the pure pending/merge tests.
function Get-TestLedger { param([string[]]$Replicated = @()) $r = [ordered]@{}; foreach ($n in $Replicated) { $r[$n] = '2026-06-10T00:00:00Z' }; return [ordered]@{ replicated = $r } }

# The fixture helpers below sit at file scope, above the first Describe, because that
# is the only region an It block can still reach at run time: a Describe body is
# executed during the discovery pass and everything it declares -- functions included --
# is discarded before the first It runs, so a helper defined inside one would surface
# as a CommandNotFoundException in the assertion rather than as a real failure.

# A pscustomobject of the shape Get-YurunaPoolStorageConfig returns.
function Get-TestPoolConfig { param([string]$LocalPath = '/mnt/ypool-nas') [pscustomobject]@{ Replicate = $true; NetworkPath = '//srv/work'; NetworkUser = 'u'; LocalPath = $LocalPath } }

# N cycles, oldest-first (zero-padded so lexical == chronological).
function Get-NSeq { param([int]$N) 1..$N | ForEach-Object { '{0:D6}.d.t.h' -f $_ } }

Describe 'Get-PoolStorageUncPath (SMB path normalization)' {
    It 'normalizes a Windows UNC input to either style' {
        Assert-Equal -Expected '\\srv\work' -Actual (Get-PoolStorageUncPath -Path '\\srv\work' -Style windows) -Because 'win<-win'
        Assert-Equal -Expected '//srv/work' -Actual (Get-PoolStorageUncPath -Path '\\srv\work' -Style unix) -Because 'unix<-win'
    }
    It 'normalizes a unix //share input to either style' {
        Assert-Equal -Expected '\\srv\work' -Actual (Get-PoolStorageUncPath -Path '//srv/work' -Style windows) -Because 'win<-unix'
        Assert-Equal -Expected '//srv/work' -Actual (Get-PoolStorageUncPath -Path '//srv/work' -Style unix) -Because 'unix<-unix'
    }
    It 'handles a multi-segment share path' {
        Assert-Equal -Expected '\\srv\work\sub' -Actual (Get-PoolStorageUncPath -Path '//srv/work/sub' -Style windows) -Because 'multi win'
        Assert-Equal -Expected '//srv/work/sub' -Actual (Get-PoolStorageUncPath -Path '\\srv\work\sub' -Style unix) -Because 'multi unix'
    }
}

Describe 'Test-PoolStorageMountMatch (anchored mount detection)' {
    It 'matches our share at our exact mount point (Linux)' {
        $l = '//srv/work on /mnt/ypool-nas type cifs (rw,relatime,vers=3.0)'
        Assert-True (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work') 'linux exact'
    }
    It 'matches our share at our exact mount point (macOS, strips user@)' {
        $l = '//yurunanet@srv/work on /Users/u/Shares/ypool-nas (smbfs, nodev, nosuid)'
        Assert-True (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/Users/u/Shares/ypool-nas' -NetworkPath '//srv/work') 'macos exact'
    }
    It 'rejects a DIFFERENT share at the same mount point (share-suffix collision)' {
        $l = '//srv/work2 on /mnt/ypool-nas type cifs (rw)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work')) 'work2 != work'
    }
    It 'rejects a server-name-suffix collision' {
        $l = '//other-srv/work on /mnt/ypool-nas type cifs (rw)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work')) 'other-srv != srv'
    }
    It 'rejects our share at a DIFFERENT mount point' {
        $l = '//srv/work on /mnt/ypool-nas type cifs (rw)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/other' -NetworkPath '//srv/work')) 'point mismatch'
    }
    It 'rejects a mount-point prefix collision' {
        $l = '//srv/work on /mnt/ypool-nas2 type cifs (rw)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work')) 'ypool-nas2 != ypool-nas'
    }
    It 'accepts a Windows-style NetworkPath form (normalized)' {
        $l = '//srv/work on /mnt/ypool-nas type cifs (rw)'
        Assert-True (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/mnt/ypool-nas' -NetworkPath '\\srv\work') 'win-form normalized'
    }
    It 'returns false on empty or null mount output' {
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @() -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work')) 'empty'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines $null -LocalPath '/mnt/ypool-nas' -NetworkPath '//srv/work')) 'null'
    }
}

Describe 'ConvertFrom-PoolStorageMountLine (mount-line parser)' {
    It 'splits a macOS smbfs line into remote/point/host/share-sub (strips user@)' {
        $p = ConvertFrom-PoolStorageMountLine -MountLine '//pooluser@srv/work/sub on /Users/u/Shares/x (smbfs, nodev, nosuid)'
        Assert-Equal -Expected '/Users/u/Shares/x' -Actual $p.MountPoint -Because 'point'
        Assert-Equal -Expected 'srv' -Actual $p.HostName -Because 'host'
        Assert-Equal -Expected 'work/sub' -Actual $p.ShareSub -Because 'share-sub'
    }
    It 'splits a Linux cifs line (type-delimited point)' {
        $p = ConvertFrom-PoolStorageMountLine -MountLine '//srv/work on /mnt/x type cifs (rw,relatime)'
        Assert-Equal -Expected '/mnt/x' -Actual $p.MountPoint -Because 'point'
        Assert-Equal -Expected 'work' -Actual $p.ShareSub -Because 'share-sub'
    }
    It 'parses a hostless mount to an empty share-sub (filtered out downstream)' {
        $p = ConvertFrom-PoolStorageMountLine -MountLine 'map auto_home on /System/Volumes/Data/home'
        Assert-Equal -Expected '' -Actual $p.ShareSub -Because 'no share component'
    }
    It 'returns null for a line with no separator, empty, or null' {
        Assert-Null (ConvertFrom-PoolStorageMountLine -MountLine 'garbage line') 'no separator'
        Assert-Null (ConvertFrom-PoolStorageMountLine -MountLine '') 'empty'
        Assert-Null (ConvertFrom-PoolStorageMountLine -MountLine $null) 'null'
    }
}

Describe 'Get-PoolStorageComparableMountPoint (macOS /private fold)' {
    It 'folds the /private prefix macOS reports for /var, /tmp and /etc' {
        Assert-Equal -Expected '/var/root/Shares/x' -Actual (Get-PoolStorageComparableMountPoint -Path '/private/var/root/Shares/x') -Because 'var'
        Assert-Equal -Expected '/tmp/x'             -Actual (Get-PoolStorageComparableMountPoint -Path '/private/tmp/x')             -Because 'tmp'
        Assert-Equal -Expected '/etc/x'             -Actual (Get-PoolStorageComparableMountPoint -Path '/private/etc/x')             -Because 'etc'
    }
    It 'leaves a path that merely starts with /private alone' {
        Assert-Equal -Expected '/private/data/x' -Actual (Get-PoolStorageComparableMountPoint -Path '/private/data/x') -Because 'not one of the symlinked roots'
        Assert-Equal -Expected '/privateer/x'    -Actual (Get-PoolStorageComparableMountPoint -Path '/privateer/x')    -Because 'prefix must be a whole segment'
    }
    It 'drops a trailing slash but never reduces the root to empty' {
        Assert-Equal -Expected '/mnt/x' -Actual (Get-PoolStorageComparableMountPoint -Path '/mnt/x/') -Because 'trailing slash'
        Assert-Equal -Expected '/'      -Actual (Get-PoolStorageComparableMountPoint -Path '/')      -Because 'root stays root'
        Assert-Equal -Expected ''       -Actual (Get-PoolStorageComparableMountPoint -Path $null)    -Because 'null'
    }
}

Describe 'Test-PoolStorageMountMatch (live-mount detection)' {
    It 'matches a macOS mount reported through /private against the path we asked for' {
        # The root-run case: LocalPath resolves under /var/root, macOS answers
        # /private/var/root. A string compare here reads "not mounted", the
        # remount fails EEXIST, and the caller blames the credential.
        $l = '//yuruna-stash@ystash-nas/yuruna.stash on /private/var/root/Shares/ystash-nas (smbfs, nodev, nosuid)'
        Assert-True (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/var/root/Shares/ystash-nas' -NetworkPath '//ystash-nas/yuruna.stash') 'mounted'
    }
    It 'still refuses a different share at the same point' {
        $l = '//yuruna-pool@ypool-nas/yuruna.pool on /private/var/root/Shares/ystash-nas (smbfs)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/var/root/Shares/ystash-nas' -NetworkPath '//ystash-nas/yuruna.stash')) 'other share'
    }
    It 'still refuses our share at a different point' {
        $l = '//yuruna-stash@ystash-nas/yuruna.stash on /Users/u/Shares/ystash-nas (smbfs)'
        Assert-True (-not (Test-PoolStorageMountMatch -MountLines @($l) -LocalPath '/var/root/Shares/ystash-nas' -NetworkPath '//ystash-nas/yuruna.stash')) 'other point'
    }
}

Describe 'Get-PoolStorageProcessErrorDetail (credential redaction)' {
    It 'redacts the password mount_smbfs echoes back from the URL it was handed' {
        $raw = 'mount_smbfs: mount error: //yuruna-stash:A%26%5E-Zd5%3D%25wQ@ystash-nas/yuruna.stash: File exists'
        $out = Get-PoolStorageProcessErrorDetail -StdErr $raw
        Assert-True ($out -notmatch 'A%26%5E') 'password gone'
        Assert-True ($out -match '//yuruna-stash:\*\*\*@ystash-nas/yuruna\.stash') 'user + share still readable'
        Assert-True ($out -match 'File exists') 'diagnosis preserved'
    }
    It 'leaves a message with no credential untouched' {
        $out = Get-PoolStorageProcessErrorDetail -StdErr 'mount_smbfs: server connection failed: No route to host'
        Assert-Equal -Expected ': mount_smbfs: server connection failed: No route to host' -Actual $out -Because 'unchanged'
    }
}

Describe 'Find-PoolStorageConflictingMount (same share, other point -> macOS "File exists")' {
    It 'flags a stale mount of the same share under a RETIRED host alias' {
        # The real ypsp->ypool-nas case: same share/sub, different (now-dead) host
        # alias, different mount point -> macOS rejects the new mount with EEXIST.
        $l = '//pooluser@ypsp/work/yuruna.pool on /Users/u/Shares/ypsp (smbfs, nodev, nosuid)'
        $c = @(Find-PoolStorageConflictingMount -MountLines @($l) -LocalPath '/Users/u/Shares/ypool-nas' -NetworkPath '//ypool-nas/work/yuruna.pool')
        Assert-Equal -Expected 1 -Actual $c.Count -Because 'one conflict'
        Assert-Equal -Expected '/Users/u/Shares/ypsp' -Actual $c[0].MountPoint -Because 'stale point'
        Assert-True (-not $c[0].HostMatches) 'host differs (ypsp != ypool-nas)'
    }
    It 'flags a same-host duplicate at a different point and reports HostMatches' {
        $l = '//pooluser@ypool-nas/work/yuruna.pool on /Users/u/Shares/dup (smbfs)'
        $c = @(Find-PoolStorageConflictingMount -MountLines @($l) -LocalPath '/Users/u/Shares/ypool-nas' -NetworkPath '//ypool-nas/work/yuruna.pool')
        Assert-Equal -Expected 1 -Actual $c.Count -Because 'one conflict'
        Assert-True $c[0].HostMatches 'same host'
    }
    It 'does NOT flag OUR own mount at LocalPath (not a blocker)' {
        $l = '//pooluser@ypool-nas/work/yuruna.pool on /Users/u/Shares/ypool-nas (smbfs)'
        $c = @(Find-PoolStorageConflictingMount -MountLines @($l) -LocalPath '/Users/u/Shares/ypool-nas' -NetworkPath '//ypool-nas/work/yuruna.pool')
        Assert-Equal -Expected 0 -Actual $c.Count -Because 'our own point is fine'
    }
    It 'does NOT flag a DIFFERENT share path (share-suffix collision)' {
        $l = '//pooluser@ypool-nas/work/yuruna.pool2 on /Users/u/Shares/other (smbfs)'
        $c = @(Find-PoolStorageConflictingMount -MountLines @($l) -LocalPath '/Users/u/Shares/ypool-nas' -NetworkPath '//ypool-nas/work/yuruna.pool')
        Assert-Equal -Expected 0 -Actual $c.Count -Because 'pool2 != pool'
    }
    It 'returns an empty set on empty or null mount output' {
        Assert-Equal -Expected 0 -Actual (@(Find-PoolStorageConflictingMount -MountLines @() -LocalPath '/x' -NetworkPath '//srv/work/sub')).Count -Because 'empty'
        Assert-Equal -Expected 0 -Actual (@(Find-PoolStorageConflictingMount -MountLines $null -LocalPath '/x' -NetworkPath '//srv/work/sub')).Count -Because 'null'
    }
}

Describe 'Get-YurunaPoolStorageConfig (feature on/off)' {
    It 'returns null when replicate is false' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $false }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '/mnt/ypool-nas' } }
        Assert-Null (Get-YurunaPoolStorageConfig -Config $cfg) 'replicate false -> off'
    }
    It 'with -IgnoreReplicate returns the object even when replicate is false (pre-validation)' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $false }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '/mnt/ypool-nas' } }
        $r = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate
        Assert-True ($null -ne $r) 'object returned despite replicate false'
        Assert-Equal -Expected $false -Actual $r.Replicate -Because 'Replicate field reflects the real flag'
        Assert-Equal -Expected '//srv/work' -Actual $r.NetworkPath -Because 'paths normalized'
    }
    It 'with -IgnoreReplicate still returns null when a path is empty' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $false }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '' } }
        Assert-Null (Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate) 'incomplete -> still null'
    }
    It 'returns null when the networkStorage section is absent' {
        Assert-Null (Get-YurunaPoolStorageConfig -Config ([ordered]@{ statusService = [ordered]@{ port = 8080 } })) 'no section -> off'
    }
    It 'returns null when replicate is true but a required path is empty' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $true }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '' } }
        Assert-Null (Get-YurunaPoolStorageConfig -Config $cfg) 'empty localPath -> off'
    }
    It 'returns the trimmed config object when fully set' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $true }; networkStorage = [ordered]@{ poolStorageNetworkPath = ' //srv/work '; poolStorageNetworkUser = ' yurunanet '; poolStorageLocalPath = ' /mnt/ypool-nas ' } }
        $r = Get-YurunaPoolStorageConfig -Config $cfg
        Assert-True ($null -ne $r) 'object returned'
        Assert-Equal -Expected '//srv/work' -Actual $r.NetworkPath -Because 'networkPath trimmed'
        Assert-Equal -Expected 'yurunanet'  -Actual $r.NetworkUser -Because 'networkUser trimmed'
        Assert-Equal -Expected '/mnt/ypool-nas'  -Actual $r.LocalPath   -Because 'localPath trimmed'
        Assert-True $r.Replicate 'replicate true'
    }
    It 'expands a leading ~ in localPath to $HOME' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $true }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '~/Shares/ypool-nas' } }
        $r = Get-YurunaPoolStorageConfig -Config $cfg
        Assert-Equal -Expected (Join-Path $HOME 'Shares/ypool-nas') -Actual $r.LocalPath -Because '~ -> $HOME'
    }
    It 'leaves a non-tilde path untouched (a bare ~ in the middle is not expanded)' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $true }; networkStorage = [ordered]@{ poolStorageNetworkPath = '//srv/work'; poolStorageNetworkUser = 'u'; poolStorageLocalPath = '/mnt/a~b' } }
        $r = Get-YurunaPoolStorageConfig -Config $cfg
        Assert-Equal -Expected '/mnt/a~b' -Actual $r.LocalPath -Because 'mid-path ~ untouched'
    }
    It 'returns null (never hangs on a Mandatory-param prompt) with no -Config and no YURUNA_CONFIG_PATH' {
        # Regression: the no-Config fallback must resolve a concrete path before
        # calling Read-TestConfig, never invoke it by-name with $Path omitted.
        $saved = $env:YURUNA_CONFIG_PATH
        try {
            $env:YURUNA_CONFIG_PATH = ''
            Assert-Null (Get-YurunaPoolStorageConfig) 'no path -> off, not a prompt'
        } finally {
            $env:YURUNA_CONFIG_PATH = $saved
        }
    }
    It 'ignores a legacy poolStorage node (clean break)' {
        $cfg = [ordered]@{ poolStorage = [ordered]@{ replicate = $true; networkPath = '//srv/work'; networkUser = 'u'; localPath = '/mnt/ypool-nas' } }
        Assert-Null (Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate) 'legacy poolStorage is not read'
    }
}

Describe 'Get-YurunaStashStorageConfig (isolated stash storage)' {
    It 'returns the stash record from networkStorage.stash* (independent of the pool)' {
        $cfg = [ordered]@{ pool = [ordered]@{ networkReplicate = $true }; networkStorage = [ordered]@{
            poolStorageNetworkPath = '//srv/work/pool'; poolStorageNetworkUser = 'u-pool'; poolStorageLocalPath = 'y:'
            stashStorageNetworkPath = ' //srv/work/stash '; stashStorageNetworkUser = ' u-stash '; stashStorageLocalPath = ' z: '
        } }
        $r = Get-YurunaStashStorageConfig -Config $cfg
        Assert-True ($null -ne $r) 'object returned'
        Assert-Equal -Expected '//srv/work/stash' -Actual $r.NetworkPath -Because 'stashStorageNetworkPath trimmed'
        Assert-Equal -Expected 'u-stash'           -Actual $r.NetworkUser -Because 'stashStorageNetworkUser trimmed'
        Assert-Equal -Expected 'z:'                -Actual $r.LocalPath   -Because 'stashStorageLocalPath trimmed'
        Assert-Equal -Expected $false              -Actual $r.Replicate   -Because 'stash never replicates'
    }
    It 'returns null when any stash field is unset' {
        $cfg = [ordered]@{ networkStorage = [ordered]@{ stashStorageNetworkPath = '//srv/work/stash'; stashStorageNetworkUser = 'u-stash'; stashStorageLocalPath = '' } }
        Assert-Null (Get-YurunaStashStorageConfig -Config $cfg) 'incomplete -> null'
    }
    It 'returns null when networkStorage is absent' {
        Assert-Null (Get-YurunaStashStorageConfig -Config ([ordered]@{ statusService = [ordered]@{ port = 8080 } })) 'no section -> null'
    }
    It 'expands a leading ~ in stashStorageLocalPath to $HOME' {
        $cfg = [ordered]@{ networkStorage = [ordered]@{ stashStorageNetworkPath = '//srv/work/stash'; stashStorageNetworkUser = 'u'; stashStorageLocalPath = '~/Shares/stash' } }
        $r = Get-YurunaStashStorageConfig -Config $cfg
        Assert-Equal -Expected (Join-Path $HOME 'Shares/stash') -Actual $r.LocalPath -Because '~ -> $HOME'
    }
}

Describe 'Get-PoolStorageServerName (server extraction)' {
    It 'extracts the host from a Windows UNC path' {
        Assert-Equal -Expected 'srv' -Actual (Get-PoolStorageServerName -NetworkPath '\\srv\work') -Because 'win UNC'
        Assert-Equal -Expected 'srv' -Actual (Get-PoolStorageServerName -NetworkPath '\\srv\work\sub') -Because 'win UNC multi'
    }
    It 'extracts the host from a unix //share path' {
        Assert-Equal -Expected 'srv' -Actual (Get-PoolStorageServerName -NetworkPath '//srv/work') -Because 'unix'
        Assert-Equal -Expected '192.168.1.5' -Actual (Get-PoolStorageServerName -NetworkPath '//192.168.1.5/work') -Because 'ip'
    }
    It 'strips a user@ prefix (macOS smbfs form)' {
        Assert-Equal -Expected 'srv' -Actual (Get-PoolStorageServerName -NetworkPath '//yurunanet@srv/work') -Because 'user@host'
    }
    It 'returns empty for a path with no server' {
        Assert-Equal -Expected '' -Actual (Get-PoolStorageServerName -NetworkPath '//') -Because 'no host'
    }
}

Describe 'Test-PoolStorageHostResolvable (dead-alias guard)' {
    It 'returns false for an empty, whitespace, or null server name' {
        Assert-True (-not (Test-PoolStorageHostResolvable -ServerName '')) 'empty -> false'
        Assert-True (-not (Test-PoolStorageHostResolvable -ServerName '   ')) 'whitespace -> false'
        Assert-True (-not (Test-PoolStorageHostResolvable -ServerName $null)) 'null -> false'
    }
    It 'returns false for a name that cannot resolve (no DNS/hosts/NetBIOS entry)' {
        # A syntactically valid but deliberately non-existent name: GetHostAddresses
        # throws "No such host is known.", which the guard maps to $false. (The
        # positive case -- a name that DOES resolve -- is environment-dependent and
        # covered by the live mount integration path.)
        Assert-True (-not (Test-PoolStorageHostResolvable -ServerName 'no-such-host-yuruna-3f9c1a2b')) 'unresolvable -> false'
    }
}

Describe 'Test-PoolStorageServerIsLocal (is this storage served by this machine?)' {
    It 'returns false for an empty, whitespace, or null share path' {
        Assert-True (-not (Test-PoolStorageServerIsLocal -NetworkPath '')) 'empty -> false'
        Assert-True (-not (Test-PoolStorageServerIsLocal -NetworkPath '   ')) 'whitespace -> false'
        Assert-True (-not (Test-PoolStorageServerIsLocal -NetworkPath $null)) 'null -> false'
    }
    It 'returns false for a name that cannot resolve (an unreachable NAS is not local storage)' {
        Assert-True (-not (Test-PoolStorageServerIsLocal -NetworkPath '//no-such-host-yuruna-3f9c1a2b/work/yuruna.pool')) 'unresolvable -> false'
    }
    It 'recognizes a loopback-resolving alias, including the macOS user@ form' {
        # 'localhost' is the one name every platform resolves to loopback and to
        # nothing else, so it stands in for the host alias New-LocalLabStorage
        # writes. A real ypool-nas is environment-dependent and belongs to the
        # live mount integration path.
        Assert-True (Test-PoolStorageServerIsLocal -NetworkPath '//localhost/yuruna.pool') 'unix form'
        Assert-True (Test-PoolStorageServerIsLocal -NetworkPath '//yuruna-pool@localhost/yuruna.pool') 'user@ stripped'
        Assert-True (Test-PoolStorageServerIsLocal -NetworkPath '\\localhost\yuruna.pool') 'windows UNC form'
    }
}

Describe 'Get-PoolStorageLinuxSudoHint (Linux sudo precondition hint)' {
    It 'returns the sudoers rule + install commands for the given user/paths' {
        $h = @(Get-PoolStorageLinuxSudoHint -User 'test' -MkdirPath '/usr/bin/mkdir' -MountPath '/usr/bin/mount' -UmountPath '/usr/bin/umount')
        Assert-True ($h.Count -ge 2) 'at least the two command lines'
        $joined = $h -join "`n"
        Assert-True ($joined -match 'test ALL=\(root\) NOPASSWD: /usr/bin/mkdir, /usr/bin/mount, /usr/bin/umount') 'rule line present'
        Assert-True ($joined -match '/etc/sudoers\.d/yuruna-poolstorage') 'drop-in path present'
        Assert-True ($joined -match 'sudo tee') 'install command present'
    }
    It 'returns an empty array for a blank user (nothing actionable)' {
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStorageLinuxSudoHint -User '').Count) -Because 'blank user -> empty'
    }
}

Describe 'Get-PoolStorageSudoSpec (shared rule/file spec)' {
    It 'builds the file, rule, and command list the installer and hint both use' {
        $spec = Get-PoolStorageSudoSpec -User 'ytest' -MkdirPath '/usr/bin/mkdir' -MountPath '/usr/bin/mount' -UmountPath '/usr/bin/umount'
        Assert-Equal -Expected '/etc/sudoers.d/yuruna-poolstorage' -Actual $spec.File
        Assert-Equal -Expected 'ytest ALL=(root) NOPASSWD: /usr/bin/mkdir, /usr/bin/mount, /usr/bin/umount' -Actual $spec.Rule
        Assert-Equal -Expected 3 -Actual (@($spec.Commands).Count) -Because 'mkdir + mount + umount'
    }
    It 'is the single source of truth behind the operator hint (rule text matches)' {
        # The hint must not drift from the spec -- the hint should quote the exact rule.
        $spec = Get-PoolStorageSudoSpec -User 'ytest'
        $hint = (Get-PoolStorageLinuxSudoHint -User 'ytest') -join "`n"
        Assert-True ($hint -match [regex]::Escape($spec.Rule)) 'the hint quotes the spec rule verbatim'
        Assert-True ($hint -match [regex]::Escape($spec.File)) 'the hint quotes the spec drop-in path'
    }
    It 'yields an empty rule for a blank user' {
        $spec = Get-PoolStorageSudoSpec -User ''
        Assert-Equal -Expected '' -Actual $spec.Rule
        Assert-Equal -Expected 0 -Actual (@($spec.Commands).Count)
    }
}

Describe 'Set-PoolStorageSudoers (interactive drop-in installer)' {
    It 'is a no-op on non-Linux platforms (macOS/Windows mounts need no sudo)' {
        # This guard is specifically about the non-Linux path; on Linux the
        # behavior is environment-dependent (probe + ShouldProcess) and is
        # covered by the -WhatIf test below.
        if ($IsLinux) { return }
        $r = Set-PoolStorageSudoers
        Assert-Equal -Expected 'unsupported' -Actual $r.Action -Because 'only Linux needs the sudo mount drop-in'
    }
    It 'never prompts and never writes under -WhatIf' {
        # -WhatIf must not reach the sudo tee write. On Linux ShouldProcess returns
        # the whatif verdict; on other platforms it short-circuits as unsupported.
        # Either way the Action is never "installed" and nothing is written.
        $r = Set-PoolStorageSudoers -WhatIf
        Assert-True ($r.Action -in @('whatif', 'unsupported', 'present')) "WhatIf must not install (got '$($r.Action)')"
    }
}

Describe 'Initialize-PoolStorageTargetFolder (subfolder ensure)' {
    It 'is a no-op (ok) for a bare share root -- no subfolder to create over SMB' {
        # NetworkPath = '\\srv\share' has no leaf: nothing is provisioned over SMB,
        # so the function returns ok without attempting any mount.
        $cfg = [pscustomobject]@{ Replicate = $false; NetworkPath = '\\srv\work'; NetworkUser = 'u'; LocalPath = 'z:' }
        $r = Initialize-PoolStorageTargetFolder -Config $cfg
        Assert-True ($r.ok) 'share root -> ok'
        Assert-True (-not $r.created) 'share root -> nothing created'
    }
    It 'neither mounts nor creates under -WhatIf (returns before any I/O)' {
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) 'stash-target-whatif-should-not-exist'
        $cfg  = [pscustomobject]@{ Replicate = $false; NetworkPath = '//srv/work/yuruna.stash'; NetworkUser = 'u'; LocalPath = $fake }
        $r = Initialize-PoolStorageTargetFolder -Config $cfg -WhatIf
        Assert-True (-not $r.ok) 'whatif -> not ok'
        Assert-Equal -Expected 'skipped (WhatIf)' -Actual $r.error -Because 'whatif -> skipped before mount'
        Assert-True (-not (Test-Path -LiteralPath $fake)) 'whatif created nothing on disk'
    }
}

Describe 'Get-PoolStorageCycleIdentity (stable identity, no duplicate replication)' {
    It 'strips the .incomplete suffix' {
        Assert-Equal -Expected '000001.2026-06-10.12-00-00.42abc' -Actual (Get-PoolStorageCycleIdentity -Name '000001.2026-06-10.12-00-00.42abc.incomplete') -Because 'incomplete -> base'
    }
    It 'strips the .aborted.<UTC> suffix' {
        Assert-Equal -Expected '000001.2026-06-10.12-00-00.42abc' -Actual (Get-PoolStorageCycleIdentity -Name '000001.2026-06-10.12-00-00.42abc.aborted.2026-06-10T13-00-00Z') -Because 'aborted -> base'
    }
    It 'leaves a bare base name unchanged' {
        Assert-Equal -Expected '000001.2026-06-10.12-00-00.42abc' -Actual (Get-PoolStorageCycleIdentity -Name '000001.2026-06-10.12-00-00.42abc') -Because 'bare unchanged'
    }
    It 'all three lifecycle forms collapse to ONE identity (no duplicate)' {
        $a = Get-PoolStorageCycleIdentity -Name '000007.d.t.h.incomplete'
        $b = Get-PoolStorageCycleIdentity -Name '000007.d.t.h'
        $c = Get-PoolStorageCycleIdentity -Name '000007.d.t.h.aborted.2026-06-10T13-00-00Z'
        Assert-True (($a -eq $b) -and ($b -eq $c)) 'one identity across the lifecycle'
    }
    It 'accepts a full path leaf' {
        Assert-Equal -Expected '000002.d.t.h' -Actual (Get-PoolStorageCycleIdentity -Name '/var/log/000002.d.t.h.incomplete') -Because 'path leaf stripped'
    }
}

Describe 'Get-PoolStoragePendingSet (backlog, oldest-first)' {
    It 'returns all local cycles when the ledger is empty, oldest-first' {
        $names = @('000003.d.t.h', '000001.d.t.h', '000002.d.t.h')
        $p = Get-PoolStoragePendingSet -LocalNames $names -Ledger (Get-TestLedger)
        Assert-Equal -Expected '000001.d.t.h,000002.d.t.h,000003.d.t.h' -Actual ($p -join ',') -Because 'sorted ascending'
    }
    It 'excludes cycles already in the ledger' {
        $names = @('000001.d.t.h', '000002.d.t.h', '000003.d.t.h')
        $p = Get-PoolStoragePendingSet -LocalNames $names -Ledger (Get-TestLedger -Replicated @('000001.d.t.h', '000002.d.t.h'))
        Assert-Equal -Expected '000003.d.t.h' -Actual ($p -join ',') -Because 'only the un-replicated one'
    }
    It 'filters non-cycle names and dedupes' {
        $names = @('000001.d.t.h', 'history.2026-06-10', '000001.d.t.h', 'notacycle')
        $p = Get-PoolStoragePendingSet -LocalNames $names -Ledger (Get-TestLedger)
        Assert-Equal -Expected '000001.d.t.h' -Actual ($p -join ',') -Because 'regex-filtered + deduped'
    }
    It 'returns empty for empty or null input' {
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStoragePendingSet -LocalNames @() -Ledger (Get-TestLedger)).Count) -Because 'empty'
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStoragePendingSet -LocalNames $null -Ledger (Get-TestLedger)).Count) -Because 'null'
    }
}

Describe 'Merge-PoolStorageLedger (commit + prune + status)' {
    It 'adds newly committed cycles with the timestamp' {
        $m = Merge-PoolStorageLedger -Ledger (Get-TestLedger) -Committed @('000001.d.t.h') -NowUtc '2026-06-10T12:00:00Z'
        Assert-Equal -Expected '2026-06-10T12:00:00Z' -Actual $m.replicated['000001.d.t.h'] -Because 'committed with utc'
    }
    It 'is idempotent re-adding an existing cycle' {
        $base = Get-TestLedger -Replicated @('000001.d.t.h')
        $m = Merge-PoolStorageLedger -Ledger $base -Committed @('000001.d.t.h') -NowUtc '2026-06-10T13:00:00Z'
        Assert-Equal -Expected 1 -Actual $m.replicated.Count -Because 'still one entry'
    }
    It 'prunes replicated entries no longer present locally' {
        $base = Get-TestLedger -Replicated @('000001.d.t.h', '000002.d.t.h')
        $m = Merge-PoolStorageLedger -Ledger $base -LocalNames @('000002.d.t.h')
        Assert-Equal -Expected '000002.d.t.h' -Actual (($m.replicated.Keys) -join ',') -Because 'gone-local pruned'
    }
    It 'merges scalar status fields' {
        $m = Merge-PoolStorageLedger -Ledger (Get-TestLedger) -Status @{ lastConnectOk = $false; lastError = 'x' }
        Assert-Equal -Expected $false -Actual $m['lastConnectOk'] -Because 'status carried'
        Assert-Equal -Expected 'x' -Actual $m['lastError'] -Because 'status carried'
    }
    It 'carries forward a prior scalar when a failure-run $Status omits it' {
        # A failure run's $Status has no lastCopied (only a successful copy sets it);
        # the prior run's lastCopied must survive rather than being dropped.
        $ledger = @{ replicated = ([ordered]@{ 'cycleA' = 't' }); lastCopied = 5; lastConnectOk = $true }
        $m = Merge-PoolStorageLedger -Ledger $ledger -Status @{ lastConnectOk = $false; lastError = 'boom'; pendingCount = 3 } -LocalNames @('cycleA')
        Assert-Equal -Expected 5 -Actual $m['lastCopied'] -Because 'lastCopied is carried forward, not dropped, when $Status omits it'
        Assert-Equal -Expected $false -Actual $m['lastConnectOk'] -Because '$Status still overwrites the keys it supplies'
    }
    It 'lets a present $Status key overwrite the carried-forward value' {
        $ledger = @{ replicated = ([ordered]@{}); lastCopied = 5 }
        $m = Merge-PoolStorageLedger -Ledger $ledger -Status @{ lastCopied = 3; pendingCount = 0 }
        Assert-Equal -Expected 3 -Actual $m['lastCopied'] -Because 'a present $Status key wins over the carried-forward value'
    }
}

Describe 'Test-PoolStorageVaultDecision (loud-fail gate)' {
    It 'proceeds when a non-empty vaultKey is mapped (no auto-gen)' {
        Assert-True (Test-PoolStorageVaultDecision -VaultKey 'smb.x' -EntryExists $false) 'vaultKey set'
    }
    It 'proceeds when an entry already exists under the empty-vaultKey path' {
        Assert-True (Test-PoolStorageVaultDecision -VaultKey '' -EntryExists $true) 'entry exists'
    }
    It 'bails when empty vaultKey AND no entry (would mint junk)' {
        Assert-True (-not (Test-PoolStorageVaultDecision -VaultKey '' -EntryExists $false)) 'would auto-gen -> bail'
    }
}

Describe 'Get-PoolStorageHostFolderPath (per-host destination root)' {
    It 'joins localPath and hostId' {
        $cfg = Get-TestPoolConfig
        Assert-Equal -Expected (Join-Path '/mnt/ypool-nas' '4212abc') -Actual (Get-PoolStorageHostFolderPath -Config $cfg -HostId '4212abc') -Because 'host root = localPath/hostId'
    }
    It 'is the PARENT of the cycle destination Copy-PoolStorageCycle writes (no drift)' {
        # Copy-PoolStorageCycle writes <localPath>/<HostId>/<CycleName>/; the gate
        # pre-flight must target exactly that host root, or it would create/verify
        # the wrong folder and pass while the real copy still fails.
        $cfg       = Get-TestPoolConfig
        $hostRoot  = Get-PoolStorageHostFolderPath -Config $cfg -HostId '4212abc'
        $cycleDest = Join-Path $cfg.LocalPath (Join-Path '4212abc' '000001.d.t.h')
        Assert-Equal -Expected $hostRoot -Actual (Split-Path -Parent $cycleDest) -Because 'host root is the cycle-dest parent'
    }
    It 'composes a bare Windows drive-letter localPath without a DriveNotFound throw' -Skip:(-not $IsWindows) {
        # Join-Path resolves the 'y:' qualifier against the PSDrive table and
        # throws DriveNotFoundException when the SMB mapping has not been
        # enumerated in this runspace (this helper runs before the mount); the
        # per-host root must compose by string so an unmounted drive letter still
        # yields 'y:\<hostId>' instead of $null.
        $cfg = Get-TestPoolConfig -LocalPath 'y:'
        Assert-Equal -Expected 'y:\4212abc' -Actual (Get-PoolStorageHostFolderPath -Config $cfg -HostId '4212abc') -Because 'bare drive -> y:\hostId'
    }
}

Describe 'Initialize-PoolStorageHostFolder (-WhatIf is a no-I/O no-op)' {
    It 'neither mounts nor creates the folder under -WhatIf' {
        # A localPath that does not exist: under -WhatIf the function must return
        # before any mount/create, so the path is never brought into being.
        $fake = Join-Path ([System.IO.Path]::GetTempPath()) 'ypool-nas-whatif-should-not-exist'
        $cfg  = [pscustomobject]@{ Replicate = $true; NetworkPath = '//srv/work'; NetworkUser = 'u'; LocalPath = $fake }
        $r = Initialize-PoolStorageHostFolder -Config $cfg -HostId '4212abc' -WhatIf
        Assert-True (-not $r.ok) 'whatif -> not ok'
        Assert-True (-not (Test-Path -LiteralPath $fake)) 'whatif created nothing on disk'
    }
}

Describe 'Get-PoolStorageDrainOrder (hybrid newest + oldest, recency)' {
    It 'returns the list unchanged when it fits in one run' {
        $p = @(Get-NSeq 5)
        Assert-Equal -Expected ($p -join ',') -Actual ((Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 100) -join ',') -Because 'fits -> unchanged'
    }
    It 'includes the NEWEST cycles when the backlog exceeds Max (recency win)' {
        $p = @(Get-NSeq 30)                                   # 000001..000030
        $order = @(Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 10 -NewestShare 3)
        Assert-Equal -Expected 10 -Actual $order.Count -Because 'copies exactly Max'
        Assert-True ($order -contains '000030.d.t.h') 'newest is scheduled this run'
        Assert-True ($order -contains '000001.d.t.h') 'oldest still backfills'
        # 7 oldest (000001..000007) + 3 newest (000028..000030); no overlap.
        Assert-True ($order -contains '000007.d.t.h') 'oldest window = Max - NewestShare'
        Assert-True (-not ($order -contains '000008.d.t.h')) 'gap between the two windows'
        # Newest come FIRST so they commit before a later old-cycle stall.
        Assert-Equal -Expected '000028.d.t.h' -Actual $order[0] -Because 'newest batch leads the run'
        Assert-Equal -Expected '000001.d.t.h' -Actual $order[3] -Because 'oldest backfill follows the newest batch'
    }
    It 'never overlaps the head/tail windows (no duplicates)' {
        $p = @(Get-NSeq 12)
        $order = @(Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 12 -NewestShare 5)
        Assert-Equal -Expected 12 -Actual $order.Count -Because 'all 12 (fits) -> unchanged, no dup'
        $order = @(Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 11 -NewestShare 5)
        Assert-Equal -Expected 11 -Actual ($order | Sort-Object -Unique).Count -Because 'no duplicates across windows'
    }
    It 'returns distinct well-formed names when NewestShare is 1 (single-element slice)' {
        # Regression: a single-element newest/oldest slice must NOT unwrap to a
        # scalar and string-concatenate (which would fuse 000030+000001 and drop a
        # real cycle). Exercises newestCount==1 over a backlog > Max.
        $p = @(Get-NSeq 30)
        $order = @(Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 5 -NewestShare 1)
        Assert-Equal -Expected 5 -Actual $order.Count -Because 'exactly Max distinct entries'
        Assert-Equal -Expected 5 -Actual ($order | Sort-Object -Unique).Count -Because 'all distinct, none fused'
        foreach ($n in $order) { Assert-True ($n -match '^\d{6}\.d\.t\.h$') "well-formed name: $n" }
        Assert-Equal -Expected '000030.d.t.h' -Actual $order[0] -Because 'the single newest leads the run'
        Assert-Equal -Expected '000001.d.t.h' -Actual $order[1] -Because 'oldest backfill follows'
    }
    It 'handles NewestShare >= Max (oldest window empty, no $null fusion)' {
        $p = @(Get-NSeq 30)
        $order = @(Get-PoolStorageDrainOrder -PendingOldestFirst $p -Max 3 -NewestShare 10)
        Assert-Equal -Expected 3 -Actual $order.Count -Because 'all 3 from the newest window'
        Assert-Equal -Expected '000028.d.t.h,000029.d.t.h,000030.d.t.h' -Actual (($order | Sort-Object) -join ',') -Because 'the 3 newest'
    }
    It 'handles empty / null / zero Max safely' {
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStorageDrainOrder -PendingOldestFirst @() -Max 10).Count) -Because 'empty'
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStorageDrainOrder -PendingOldestFirst $null -Max 10).Count) -Because 'null'
        Assert-Equal -Expected 0 -Actual (@(Get-PoolStorageDrainOrder -PendingOldestFirst (Get-NSeq 5) -Max 0).Count) -Because 'max 0'
    }
}

Describe 'Get-PoolStorageHealthWarning (loud-fail surfacing logic)' {
    It 'returns null when replicate is off (even with a failing ledger)' {
        $led = [ordered]@{ lastConnectOk = $false; pendingCount = 5; lastError = 'x' }
        Assert-Null (Get-PoolStorageHealthWarning -Ledger $led -Replicate $false) 'replicate off -> silent'
    }
    It 'returns null for a fresh ledger with no recorded attempt' {
        Assert-Null (Get-PoolStorageHealthWarning -Ledger ([ordered]@{ replicated = [ordered]@{} }) -Replicate $true) 'no attempt yet -> null'
    }
    It 'warns when the last drain could not connect' {
        $led = [ordered]@{ lastConnectOk = $false; pendingCount = 12; lastError = 'server unreachable: nas:445' }
        $w = Get-PoolStorageHealthWarning -Ledger $led -Replicate $true
        Assert-True ($w -match 'FAILING' -and $w -match '12' -and $w -match 'unreachable') 'connect-fail warning carries count + cause'
    }
    It 'warns when connected but copied 0 with a backlog (write/permission stall)' {
        $led = [ordered]@{ lastConnectOk = $true; lastCopied = 0; pendingCount = 30; lastError = '' }
        $w = Get-PoolStorageHealthWarning -Ledger $led -Replicate $true
        Assert-True ($w -match 'copied 0' -and $w -match '30') 'stall warning'
    }
    It 'is SILENT on a healthy mid-backlog drain (copied > 0)' {
        $led = [ordered]@{ lastConnectOk = $true; lastCopied = 100; pendingCount = 524; lastError = '' }
        Assert-Null (Get-PoolStorageHealthWarning -Ledger $led -Replicate $true) 'draining normally -> no noise'
    }
    It 'is SILENT when fully caught up (pending 0, copied 0)' {
        $led = [ordered]@{ lastConnectOk = $true; lastCopied = 0; pendingCount = 0; lastError = '' }
        Assert-Null (Get-PoolStorageHealthWarning -Ledger $led -Replicate $true) 'caught up -> no noise'
    }
}


Describe 'Remove-PoolStorageTree (retry-tolerant recursive delete)' {
    It 'deletes a nested tree and reports success' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-rmtree-' + [guid]::NewGuid().ToString('N'))
        try {
            $leaf = Join-Path $root 'a/b/c'
            $null = New-Item -ItemType Directory -Force -Path $leaf
            Set-Content (Join-Path $leaf 'f.txt') 'x'
            Assert-True (Remove-PoolStorageTree -Path $root -Confirm:$false) 'deep tree deleted'
            Assert-True (-not (Test-Path -LiteralPath $root)) 'root is gone'
        } finally { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
    }
    It 'treats an already-absent path as success (idempotent)' {
        $gone = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-rmtree-' + [guid]::NewGuid().ToString('N'))
        Assert-True (Remove-PoolStorageTree -Path $gone -Confirm:$false) 'missing path -> true'
    }
    It 'gives up on its budget and returns false rather than throwing' {
        # An open handle makes the delete fail the same way every retry, which is the
        # branch that must surface as a warning + $false instead of a terminating error.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-rmtree-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $held = Join-Path $root 'locked.bin'
        $fs   = [System.IO.File]::Open($held, 'CreateNew', 'Write', 'None')
        try {
            $r = Remove-PoolStorageTree -Path $root -BudgetSeconds 1 -DelayMilliseconds 100 -Confirm:$false -WarningAction SilentlyContinue
            Assert-True (-not $r) 'undeletable tree -> false'
            Assert-True (Test-Path -LiteralPath $root) 'the tree survives'
        } finally { $fs.Dispose(); Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
    }
    It 'honors -WhatIf' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-rmtree-' + [guid]::NewGuid().ToString('N'))
        try {
            $null = New-Item -ItemType Directory -Force -Path $root
            $null = Remove-PoolStorageTree -Path $root -WhatIf
            Assert-True (Test-Path -LiteralPath $root) '-WhatIf deletes nothing'
        } finally { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-PoolStorageRoutableAddress' {
    It 'accepts a routable LAN address' {
        Assert-True (Test-PoolStorageRoutableAddress -Address '192.168.7.20')
    }
    It 'accepts the UTM shared-NAT gateway' {
        Assert-True (Test-PoolStorageRoutableAddress -Address '192.168.64.1')
    }
    It 'rejects loopback' {
        # What a local-lab hosts-file alias resolves to on the host. Baking it
        # into a guest sends the guest to its OWN loopback: cifs_mount -111.
        Assert-Equal $false (Test-PoolStorageRoutableAddress -Address '127.0.0.1')
    }
    It 'rejects the whole 127/8 block, not just 127.0.0.1' {
        Assert-Equal $false (Test-PoolStorageRoutableAddress -Address '127.1.2.3')
    }
    It 'rejects link-local' {
        Assert-Equal $false (Test-PoolStorageRoutableAddress -Address '169.254.10.5')
    }
    It 'rejects empty and unparseable input' {
        Assert-Equal $false (Test-PoolStorageRoutableAddress -Address '')
        Assert-Equal $false (Test-PoolStorageRoutableAddress -Address 'ypool-nas')
    }
}

Describe 'Select-PoolStorageSeedAddress' {
    It 'keeps a routable resolved address (a real NAS) and ignores the fallback' {
        Assert-Equal '10.0.0.9' (Select-PoolStorageSeedAddress -ResolvedAddress '10.0.0.9' -GuestReachableAddress '192.168.64.1')
    }
    It 'substitutes the guest-reachable host address when the name resolved to loopback' {
        Assert-Equal '192.168.64.1' (Select-PoolStorageSeedAddress -ResolvedAddress '127.0.0.1' -GuestReachableAddress '192.168.64.1')
    }
    It 'substitutes when the name resolved to link-local' {
        Assert-Equal '192.168.7.20' (Select-PoolStorageSeedAddress -ResolvedAddress '169.254.3.4' -GuestReachableAddress '192.168.7.20')
    }
    It 'returns empty when neither address is usable, so the guest falls back to name resolution' {
        Assert-Equal '' (Select-PoolStorageSeedAddress -ResolvedAddress '127.0.0.1' -GuestReachableAddress '')
    }
    It 'never returns a loopback fallback either' {
        # Both ends of the channel must apply the same rule; a fallback that is
        # itself loopback is no better than the value it replaces.
        Assert-Equal '' (Select-PoolStorageSeedAddress -ResolvedAddress '127.0.0.1' -GuestReachableAddress '127.0.0.1')
    }
    It 'uses the fallback when the name did not resolve at all' {
        Assert-Equal '192.168.64.1' (Select-PoolStorageSeedAddress -ResolvedAddress '' -GuestReachableAddress '192.168.64.1')
    }
}

Describe 'Test-PoolStorageWriteProbe (a mount-table entry is not proof the mount works)' {
    It 'passes on a writable directory and leaves nothing behind' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('yrn-probe-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        try {
            $before = @(Get-ChildItem -LiteralPath $dir -Force).Count
            $r = Test-PoolStorageWriteProbe -Path $dir
            Assert-True $r.Ok "writable dir probes OK (error: $($r.Error))"
            Assert-Equal '' "$($r.Error)" -Because 'no error text on success'
            # The probe file must not survive: this share is replicated, so litter
            # from a health check would be copied around the pool.
            Assert-Equal $before @(Get-ChildItem -LiteralPath $dir -Force).Count -Because 'probe file removed'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'fails, with a reason, when the mount point is not there' {
        # The shape a dead mount leaves once its point is gone; also the shape a
        # never-created localPath has.
        $missing = Join-Path ([IO.Path]::GetTempPath()) ('yrn-probe-absent-' + [guid]::NewGuid().ToString('N'))
        $r = Test-PoolStorageWriteProbe -Path $missing
        Assert-True (-not $r.Ok) 'an absent mount point is not usable'
        Assert-True ([bool]"$($r.Error)") 'carries a reason the caller can surface'
    }
    It 'reports a blank path rather than probing the current directory' {
        foreach ($bad in @('', '   ')) {
            $r = Test-PoolStorageWriteProbe -Path $bad
            Assert-True (-not $r.Ok) "blank path rejected: [$bad]"
        }
    }
    It 'treats an unresponsive share as unusable rather than waiting on it' {
        # The cap IS the answer for a wedged mount, so it must be enforced: a
        # 1s budget against a body that sleeps past it has to come back false,
        # promptly, instead of blocking the caller.
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('yrn-probe-slow-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $r = Test-PoolStorageWriteProbe -Path $dir -TimeoutSeconds 1
            $sw.Stop()
            # A local temp dir answers instantly, so this asserts the budget is
            # honoured as a CAP, never as a delay.
            Assert-True $r.Ok 'a responsive path still passes under a tight cap'
            Assert-True ($sw.Elapsed.TotalSeconds -lt 15) "returned promptly ($([int]$sw.Elapsed.TotalSeconds)s)"
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
