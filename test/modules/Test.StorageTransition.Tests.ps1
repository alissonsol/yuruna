<#PSScriptInfo
.VERSION 2026.08.07
.GUID 429bbdcc-9f46-47af-ab9b-b756158fc1f7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test storage smb takeover nas local pester
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
    Telling storage this machine SERVES from storage it merely MOUNTS, and
    completing the move from the second to the first.
.DESCRIPTION
    WHAT MAKES THIS HARD. A machine backed by a NAS and a machine serving its own
    shares carry byte-identical storage config: same share paths, same accounts,
    same mount points. Only the server name differs, and the name is an alias --
    written by this same setup, so a check that reads it answers "this is local"
    because an earlier run made it say local. An established SMB session never
    re-resolves that name either, so a mount made against a NAS keeps working
    long after the alias moved to loopback: the name reads local while the socket
    still crosses the LAN.

    So the evidence has to come from somewhere neither the config nor the hosts
    file can reach: the OS share table (what this machine will actually serve)
    and the live session (who is actually answering). These tests pin both, and
    the wiring in install/setup.ps1 that makes the storage step ask.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.StorageTransition.Tests.ps1
         (or Invoke-Pester -Path test/modules/Test.StorageTransition.Tests.ps1)
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path

Import-Module (Join-Path $here 'Test.PoolStorage.psm1')    -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.LocalLabStorage.psm1') -Force -DisableNameChecking

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

# Pester is not installed on every host that runs this repo's scripts, and the
# assertions here are plain throws, so the harness the file needs is three
# functions. Defined only when the real ones are absent; every fixture is
# computed at file scope, so the immediate-run shim and Pester's
# discovery-then-run split observe the same state.
if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function Context  { param([string]$Name, [scriptblock]$Fixture) Write-Output "  Context: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

# --- fixtures -------------------------------------------------------------
# The two worlds that look alike. A NAS layout puts a directory inside a share
# ('work/yuruna.pool'); a machine serving its own storage publishes the share
# itself. Both are reached under the same alias, and on this host that alias
# resolved to loopback while the sessions were still going to the NAS.
$NasNetworkPath   = '//ypool-nas/work/yuruna.pool'
$LocalNetworkPath = '//ypool-nas/yuruna.pool'
$MountPoint       = '/Users/ytest/Shares/ypool-nas'

$NasMountLine   = "//yuruna-pool@ypool-nas/work/yuruna.pool on $MountPoint (smbfs, nodev, nosuid, mounted by ytest)"
$LocalMountLine = "//yuruna-pool@ypool-nas/yuruna.pool on $MountPoint (smbfs, nodev, nosuid, mounted by ytest)"
$DiskMountLine  = '/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)'

# A machine with no lab mounts at all: the first-time host, where every check
# below has to come back "nothing to do" rather than "cannot tell".
$FirstRunMountLines = @(
    $DiskMountLine,
    'devfs on /dev (devfs, local, nobrowse)',
    'map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)'
)

# Socket-table output in each platform's spelling. The macOS set deliberately
# carries BOTH sides of a loopback SMB conversation plus the LAN session, which
# is what a machine that serves its own shares AND still mounts a NAS looks like.
$MacNetstatLines = @(
    'Active Internet connections (including servers)',
    'Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)',
    "tcp4       0      0  192.168.7.207.52341    192.168.7.25.445       ESTABLISHED",
    'tcp4       0      0  *.445                  *.*                    LISTEN'
)
$MacLoopbackNetstatLines = @(
    'tcp4       0      0  127.0.0.1.51000        127.0.0.1.445          ESTABLISHED',
    'tcp4       0      0  127.0.0.1.445          127.0.0.1.51000        ESTABLISHED'
)
$SsLines = @(
    'State  Recv-Q Send-Q Local Address:Port  Peer Address:Port',
    'ESTAB  0      0      192.168.7.207:44444 192.168.7.25:445'
)
$MultichannelLines = @(
    '       id         client IF             server IF   state                     server ip                 port   speed',
    '        1         en0                   1           [Connected]               192.168.7.25              445    1.0 Gb'
)
$ProcMountsLines = @(
    'sysfs /sys sysfs rw,nosuid,nodev,noexec,relatime 0 0',
    "//ypool-nas/yuruna.pool /mnt/ypool-nas cifs rw,relatime,vers=3.1.1,addr=192.168.7.25,file_mode=0755 0 0"
)

$ThisMachine = @('127.0.0.1', '::1', '192.168.7.207')

# --- how install/setup.ps1 wires the steps --------------------------------
# Read from the source rather than re-stated here: the property under test is
# that the STEP asks the share table, and a copy of the rule in a test file would
# go on passing after the step stopped asking.
function Get-SetupStepCall {
    <#
    .SYNOPSIS
        One record per Invoke-SetupStep call in a file: its name, the facts it
        provides and requires, its line, and the source text of its AlreadyDone
        predicate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][string]$Path)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $calls = @($ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Invoke-SetupStep' }, $true))
    $out = @()
    foreach ($call in $calls) {
        $elements = @($call.CommandElements)
        $record = @{ Name = ''; Provides = ''; Requires = ''; AlreadyDone = ''; Line = $call.Extent.StartLineNumber }
        for ($i = 0; $i -lt $elements.Count; $i++) {
            $element = $elements[$i]
            if (-not ($element -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
            # A parameter's value is either attached to it (-Name:'x') or the next
            # element (-Name 'x'); both spellings have to resolve to the value.
            $value = if ($element.Argument) { $element.Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
            if (-not $value) { continue }
            $text = "$($value.Extent.Text)".Trim("'", '"')
            switch ($element.ParameterName) {
                'Name'        { $record.Name = $text }
                'Provides'    { $record.Provides = $text }
                'Requires'    { $record.Requires = $text }
                'AlreadyDone' { $record.AlreadyDone = "$($value.Extent.Text)" }
            }
        }
        if ($record.Name) { $out += $record }
    }
    return $out
}

$SetupSteps    = @(Get-SetupStepCall -Path (Join-Path $repoRoot 'install/setup.ps1'))
$StorageStep   = @($SetupSteps | Where-Object { $_.Name -like 'Stand up local pool and stash shares*' })
$TakeoverStep  = @($SetupSteps | Where-Object { $_.Name -like 'Stop using storage served by another machine*' })

Describe 'already done means this machine serves the share' {
    It 'refuses a NAS mount masquerading behind a loopback alias' {
        # Exactly this host's state: the alias resolves to loopback, the mount is
        # live and writable -- and the share table has never heard of the share,
        # because no local SMB server was ever created.
        Assert-False (Test-LocalLabStorageTierStoodUp -ServedPath '' -AliasIsLocal $true -Mounted $true) `
            'a live mount plus a loopback alias is what a machine still pointed at a NAS looks like'
    }

    It 'accepts a share this machine actually publishes' {
        Assert-True (Test-LocalLabStorageTierStoodUp -ServedPath '/Users/Shared/yuruna/yuruna.pool' -AliasIsLocal $true -Mounted $true) `
            'share table + alias + live mount is the whole of "stood up here"'
    }

    It 'refuses when the alias resolves somewhere other than this machine' {
        # The shares exist here, but the name sends every mount to another server,
        # so the storage this run would use is still not this machine's.
        Assert-False (Test-LocalLabStorageTierStoodUp -ServedPath '/Users/Shared/yuruna/yuruna.pool' -AliasIsLocal $false -Mounted $true) `
            'publishing a share says nothing about where the alias points'
    }

    It 'refuses when the share is published but not mounted' {
        Assert-False (Test-LocalLabStorageTierStoodUp -ServedPath '/Users/Shared/yuruna/yuruna.pool' -AliasIsLocal $true -Mounted $false) `
            'a tier is not stood up until it is reachable through the network stack the runner uses'
    }

    It 'reads no share name out of a path shape this machine never publishes' {
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageShareName -NetworkPath $NasNetworkPath) `
            'a directory inside a share is the NAS layout; reading its first segment would name someone else''s share'
        Assert-Equal -Expected 'yuruna.pool' -Actual (Get-LocalLabStorageShareName -NetworkPath $LocalNetworkPath) 'local layout'
        Assert-Equal -Expected 'yuruna.pool' -Actual (Get-LocalLabStorageShareName -NetworkPath '//yuruna-pool@ypool-nas/yuruna.pool') 'the account belongs to the server field'
        Assert-Equal -Expected 'yuruna.pool' -Actual (Get-LocalLabStorageShareName -NetworkPath '\\ypool-nas\yuruna.pool') 'windows spelling'
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageShareName -NetworkPath '') 'nothing configured'
    }

    It 'derives the storage root from the directory the share resolves to' {
        # The root is never recorded, so this derivation is the only thing that
        # can name the disk a withdrawal leaves behind. When it silently answers
        # '' the teardown reports "no storage root could be derived" one line
        # after listing both published shares, and the data goes unreported.
        Assert-Equal -Expected '/Users/Shared/yuruna' `
            -Actual (Get-LocalLabStorageShareRoot -SharePath '/Users/Shared/yuruna/yuruna.pool' -ShareName 'yuruna.pool' -Platform 'macos')
        Assert-Equal -Expected '/srv/yuruna' `
            -Actual (Get-LocalLabStorageShareRoot -SharePath '/srv/yuruna/yuruna.stash/' -ShareName 'yuruna.stash' -Platform 'linux') 'trailing separator'
        Assert-Equal -Expected 'D:\yuruna' `
            -Actual (Get-LocalLabStorageShareRoot -SharePath 'D:\yuruna\yuruna.pool' -ShareName 'yuruna.pool' -Platform 'windows') 'windows spelling'
    }

    It 'refuses a root it cannot stand behind' {
        Assert-Equal -Expected '' `
            -Actual (Get-LocalLabStorageShareRoot -SharePath '/Users/someone/pictures' -ShareName 'yuruna.pool' -Platform 'macos') `
            'an unrelated share of the same name must not contribute its parent'
        Assert-Equal -Expected '' `
            -Actual (Get-LocalLabStorageShareRoot -SharePath '/yuruna.pool' -ShareName 'yuruna.pool' -Platform 'macos') `
            'a share at a filesystem root leaves no parent to be the storage root'
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageShareRoot -SharePath '' -ShareName 'yuruna.pool' -Platform 'macos') 'nothing resolved'
    }

    It 'publishes nothing for a NAS-shaped path, without asking the OS' {
        # Refused on shape alone, so this holds on every platform and never
        # depends on what the running host happens to share.
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageServedPath -NetworkPath $NasNetworkPath -Platform 'macos') 'macos'
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageServedPath -NetworkPath $NasNetworkPath -Platform 'linux') 'linux'
        Assert-Equal -Expected '' -Actual (Get-LocalLabStorageServedPath -NetworkPath '\\srv\work\yuruna.pool' -Platform 'windows') 'windows'
    }
}

Describe 'who is actually serving a mount' {
    It 'calls a session to another machine remote' {
        $verdict = Get-PoolStorageMountOwnership -PeerAddress '192.168.7.25' -LocalAddress $ThisMachine
        Assert-Equal -Expected 'remote' -Actual $verdict.Verdict 'the peer is not one of this machine''s addresses'
        Assert-True ($verdict.Reason -match '192\.168\.7\.25') 'the reason has to name the server being left'
    }

    It 'calls a session to one of this machine''s own addresses local' {
        Assert-Equal -Expected 'local' -Actual (Get-PoolStorageMountOwnership -PeerAddress '192.168.7.207' -LocalAddress $ThisMachine).Verdict `
            'a machine can publish on its LAN address as well as loopback'
    }

    It 'calls loopback local even with no interface list to compare against' {
        Assert-Equal -Expected 'local' -Actual (Get-PoolStorageMountOwnership -PeerAddress '127.0.0.1' -LocalAddress @()).Verdict `
            'local lab storage is published on loopback by design'
    }

    It 'concludes remote when the peer is unreadable and this machine publishes no such share' {
        $verdict = Get-PoolStorageMountOwnership -PeerAddress '' -LocalAddress $ThisMachine -HostServesShare 'no'
        Assert-Equal -Expected 'remote' -Actual $verdict.Verdict `
            'a machine that serves no such share cannot be the machine answering for it'
    }

    It 'refuses to conclude when the peer is unreadable and this machine does publish the share' {
        $verdict = Get-PoolStorageMountOwnership -PeerAddress '' -LocalAddress $ThisMachine -HostServesShare 'yes'
        Assert-Equal -Expected 'unknown' -Actual $verdict.Verdict `
            'its own copy and another machine''s copy are indistinguishable from here, and a guess would unmount live storage'
    }

    It 'refuses to conclude when neither the session nor the share table could be read' {
        Assert-Equal -Expected 'unknown' -Actual (Get-PoolStorageMountOwnership -PeerAddress '' -HostServesShare 'unknown').Verdict `
            'cannot prove local is not the same answer as is local'
    }
}

Describe 'reading the peer out of what each platform prints' {
    It 'rejects a bare port number as an address' {
        # [IPAddress]::TryParse('445') succeeds (0.0.1.189), so a column of ports
        # would otherwise read as a table of servers.
        Assert-Equal -Expected '' -Actual (Get-PoolStorageNormalAddress -Address '445') 'a port is not an address'
        Assert-Equal -Expected '' -Actual (Get-PoolStorageNormalAddress -Address '1.0 Gb') 'a link speed is not an address'
        Assert-Equal -Expected '192.168.7.25' -Actual (Get-PoolStorageNormalAddress -Address '192.168.7.25') 'ipv4'
        Assert-Equal -Expected 'fe80::1' -Actual (Get-PoolStorageNormalAddress -Address '[fe80::1%en0]') 'brackets and zone stripped'
    }

    It 'takes the server ip from a multichannel row, not the interface columns' {
        Assert-Equal -Expected '192.168.7.25' -Actual (Get-PoolStorageMultichannelPeer -Line $MultichannelLines) 'macOS session table'
        Assert-Equal -Expected '' -Actual (Get-PoolStorageMultichannelPeer -Line @($MultichannelLines[0])) 'the header names the column, it is not a row'
        Assert-Equal -Expected '' -Actual (Get-PoolStorageMultichannelPeer -Line @()) 'no output means no answer'
    }

    It 'takes the foreign endpoint of an established SMB session' {
        Assert-Equal -Expected '192.168.7.25' -Actual (@(Get-PoolStorageEstablishedPeer -Line $MacNetstatLines) -join ',') 'macOS netstat'
        Assert-Equal -Expected '192.168.7.25' -Actual (@(Get-PoolStorageEstablishedPeer -Line $SsLines) -join ',') 'ss spelling'
    }

    It 'does not report this machine as its own peer when it SERVES a session' {
        # The server side of a loopback SMB conversation has the SMB port as its
        # LOCAL endpoint and an ephemeral foreign one. Counted as a peer it would
        # make a self-serving host look like it holds two different sessions, and
        # two sessions are not attributable to a mount.
        Assert-Equal -Expected '127.0.0.1' -Actual (@(Get-PoolStorageEstablishedPeer -Line $MacLoopbackNetstatLines) -join ',') `
            'only the client side of the loopback conversation is a peer'
    }

    It 'finds no peer where nothing is established' {
        Assert-Equal -Expected 0 -Actual @(Get-PoolStorageEstablishedPeer -Line @('tcp4 0 0 *.445 *.* LISTEN')).Count 'a listener is not a session'
        Assert-Equal -Expected 0 -Actual @(Get-PoolStorageEstablishedPeer -Line @()).Count 'nothing in, nothing out'
    }

    It 'reads the address the Linux kernel recorded for a cifs mount' {
        Assert-Equal -Expected '192.168.7.25' -Actual (Get-PoolStorageCifsPeer -Line $ProcMountsLines -MountPoint '/mnt/ypool-nas') 'addr= is the address the mount dialled'
        Assert-Equal -Expected '' -Actual (Get-PoolStorageCifsPeer -Line $ProcMountsLines -MountPoint '/mnt/other') 'a different mount point is not our mount'
    }
}

Describe 'the mounts a storage tier is carried by' {
    It 'includes the mount standing on our point with our share' {
        # The masquerade: everything about this mount matches the config, and the
        # server answering it is somewhere else entirely. Leaving it out of the
        # list is what made the machine read as "nothing to do".
        $found = @(Find-PoolStorageTierMount -MountLines @($DiskMountLine, $LocalMountLine) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath)
        Assert-Equal -Expected 1 -Actual $found.Count 'our own share at our own point is still a mount we are carried by'
        Assert-Equal -Expected 'current' -Actual $found[0].Reason 'reason'
        Assert-Equal -Expected 'ypool-nas' -Actual $found[0].HostName 'the server name the session was dialled under'
    }

    It 'includes a foreign share standing on our mount point' {
        $found = @(Find-PoolStorageTierMount -MountLines @($NasMountLine) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath)
        Assert-Equal -Expected 1 -Actual $found.Count 'something else is standing where we mount'
        Assert-Equal -Expected 'mount-point' -Actual $found[0].Reason 'reason'
    }

    It 'includes another mount held against the same server name' {
        # An SMB client keeps ONE session per server name, so a mount elsewhere
        # under 'ypool-nas' decides where OUR next mount of that name goes.
        $elsewhere = "//yuruna-stash@ypool-nas/other on /Users/ytest/Shares/other (smbfs)"
        $found = @(Find-PoolStorageTierMount -MountLines @($elsewhere) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath)
        Assert-Equal -Expected 1 -Actual $found.Count 'the session, not the mount point, is what this one is about'
        Assert-Equal -Expected 'server-session' -Actual $found[0].Reason 'reason'
    }

    It 'ignores mounts that have nothing to do with this tier' {
        $other = '//other-nas/media on /Users/ytest/Shares/media (smbfs)'
        Assert-Equal -Expected 0 -Actual @(Find-PoolStorageTierMount -MountLines @($DiskMountLine, $other) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath).Count `
            'another server''s share at another point is not ours'
    }

    It 'needs no takeover on a host that mounts nothing' {
        # Every first-time host. The takeover step is a no-op here, not a failure
        # and not a question.
        Assert-Equal -Expected 0 -Actual @(Find-PoolStorageTierMount -MountLines $FirstRunMountLines -LocalPath $MountPoint -NetworkPath $LocalNetworkPath).Count `
            'no lab mounts means nothing to release'
        Assert-Equal -Expected 0 -Actual @(Find-PoolStorageTierMount -MountLines @() -LocalPath $MountPoint -NetworkPath $LocalNetworkPath).Count `
            'an unreadable mount table is not a takeover either'
    }

    It 'still keeps the correct mount out of the superseded set' {
        # The mount path unmounts everything this returns before mounting, so the
        # already-correct mount has to stay out of it or every converged re-run
        # would churn a healthy mount.
        $superseded = @(Find-PoolStorageSupersededMount -MountLines @($LocalMountLine) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath)
        Assert-Equal -Expected 0 -Actual $superseded.Count 'nothing to supersede when the mount is already what we want'
        $replaced = @(Find-PoolStorageSupersededMount -MountLines @($NasMountLine) -LocalPath $MountPoint -NetworkPath $LocalNetworkPath)
        Assert-Equal -Expected 1 -Actual $replaced.Count 'a different share on our point still has to go'
    }
}

Describe 'the storage steps as install/setup.ps1 wires them' {
    It 'has exactly one local-storage step and one takeover step' {
        Assert-Equal -Expected 1 -Actual $StorageStep.Count 'the local-storage step'
        Assert-Equal -Expected 1 -Actual $TakeoverStep.Count 'the takeover step'
    }

    It 'settles the takeover before local storage is stood up' {
        # Order is the property: the new shares mount at the points the old ones
        # hold, and an SMB client reuses one session per server name -- so storage
        # stood up first would be mounted through the server being left.
        Assert-True ($TakeoverStep[0].Line -lt $StorageStep[0].Line) `
            'the takeover step has to run before New-LocalLabStorage'
    }

    It 'makes local storage depend on the takeover through the step graph' {
        Assert-Equal -Expected 'storage-owner' -Actual $TakeoverStep[0].Provides 'the takeover establishes the fact'
        Assert-Equal -Expected 'storage-owner' -Actual $StorageStep[0].Requires 'and the storage step declares it'
        Assert-Equal -Expected 'storage' -Actual $StorageStep[0].Provides 'everything downstream still keys on storage'
    }

    It 'decides already-done from what this machine publishes' {
        $predicate = $StorageStep[0].AlreadyDone
        Assert-True ($predicate -match 'Test-LocalLabStorageTierStoodUp') `
            'the step must apply the same rule these tests do, not a second copy of it'
        Assert-True ($predicate -match 'Get-LocalLabStorageServedPath') `
            'the OS share table is the evidence a hosts-file edit cannot forge'
        Assert-True ($predicate -match 'Get-YurunaStashStorageConfig') `
            'the step stands up both tiers, so both have to be true before it may be skipped'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
