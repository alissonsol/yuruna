<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42d76e1e-670d-4849-af41-08ce879f3532
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool storage move archive verify pester
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
    Move mode: copy, verify, commit, delete -- and every way that sequence can be
    interrupted.
.DESCRIPTION
    WHAT MAKES THIS WORTH PINNING. Copy mode is forgiving: a bad copy is retried and
    the local folder is still there. Move mode deletes that folder, so the ORDER of
    the commit steps is the only thing standing between a crash and a lost cycle --
    and, worse, a plausible-looking implementation deletes the ARCHIVE instead:

      * verifying after the sentinel is written counts one file too many (the
        sentinel lives inside the destination), so every cycle "fails" verification
        and its good archive is removed;
      * re-verifying a cycle whose archive is already committed compares a possibly
        half-deleted local source against a complete copy, fails, and removes it;
      * writing the ledger after the delete leaves a killed delete looking pending,
        so the folder is neither swept nor re-archived.

    These tests drive the real Invoke-PoolStorageDrain against a local directory
    standing in for the mounted share -- the mount is the one part not exercised
    here, and it is the part every other poolStorage suite already covers.

    Assertions are plain throws and the Pester harness is shimmed when Pester is
    absent, so this runs either way.
    Run: pwsh -NoProfile -File test/modules/Test.PoolStorageMove.Tests.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolStorage.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.StateFile.psm1')   -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# --- REGION: https://yuruna.link/42d69dfa-0015
# A host directory tree that looks like a real one: a log dir with finished cycle
# folders, a runtime dir for the ledger, and a directory standing in for the mounted
# share. The vault + reachability + mount gates are stubbed to succeed, because what
# is under test is the commit sequence, not the mount (which every other poolStorage
# suite covers).

function Get-MoveFixture {
    param([string[]]$Cycles = @('000001.2026-08-16.10-00-00.HOSTID'), [string]$Suffix = '')
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-move-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $log = Join-Path $root 'log'
    $runtime = Join-Path $root 'runtime'
    $share = Join-Path $root 'share'
    foreach ($d in @($log, $runtime, $share)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    foreach ($c in $Cycles) {
        $dir = Join-Path $log ($c + $Suffix)
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir "$c.html") -Value "<html>$c</html>" -NoNewline
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'guest-1') | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'guest-1/diag.txt') -Value 'diagnostics' -NoNewline
    }
    return [pscustomobject]@{ Root = $root; LogDir = $log; RuntimeDir = $runtime; Share = $share }
}

function Clear-MoveFixture {
    param($Fixture)
    if ($Fixture -and (Test-Path -LiteralPath $Fixture.Root)) {
        Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-MoveConfigDoc {
    param($Fixture, [bool]$MoveLogs = $true)
    return [ordered]@{ networkStorage = [ordered]@{
        poolStorageNetworkPath = '//test-nas/work'
        poolStorageNetworkUser = 'pool-user'
        poolStorageLocalPath   = $Fixture.Share
        moveLogsToPoolStorage  = $MoveLogs
    } }
}

# Stub the three gates the drain runs before touching anything: they answer for the
# vault, the NAS and the mount, all of which this fixture replaces with a plain
# directory. Set-Item into function:script: inside the module's own session state --
# a bare `function` definition inside an invoked scriptblock lands in that
# invocation's scope and is gone before the drain looks anything up.
function Enable-MoveStub {
    # Re-import first: several tests replace a module internal, and a stub that
    # leaked into the next test would make it pass or fail for the wrong reason.
    Import-Module (Join-Path $PSScriptRoot 'Test.PoolStorage.psm1') -Force -DisableNameChecking
    & (Get-Module Test.PoolStorage) {
        Set-Item -Path function:script:Test-PoolStorageVaultReady       -Value { param($Config) $null = $Config; return $true }
        Set-Item -Path function:script:Test-PoolStorageServerReachable  -Value { param($Config, $TimeoutSeconds) $null = $Config; $null = $TimeoutSeconds; return $true }
        Set-Item -Path function:script:Connect-YurunaPoolStorage        -Value { param($Config) $null = $Config; return $true }
    }
}

function Get-ArchivedCyclePath {
    param($Fixture, [string]$HostId, [string]$Cycle)
    return (Join-Path $Fixture.Share (Join-Path 'hosts' (Join-Path $HostId (Join-Path 'test-cycles' $Cycle))))
}

$script:HOSTID = 'HOSTID'
}

Describe 'Test-PoolStorageSpaceSufficient (the arithmetic both space checks share)' {
    It 'requires the measured size plus headroom plus the reserve' {
        $v = Test-PoolStorageSpaceSufficient -FreeBytes 100GB -NeedBytes 1GB
        Assert-True $v.ok 'plenty of room'
        # ceil(1 GiB * 1.10) + 2 GiB reserve -- rounded UP, so a cycle can never be
        # admitted by a fraction of a byte.
        Assert-Equal -Expected ([long][math]::Ceiling(1GB * 1.10) + 2GB) -Actual $v.required -Because 'required = ceil(need*headroom) + reserve'
    }
    It 'refuses when the reserve would be eaten, even though the copy itself would fit' {
        # 2.5 GiB free, 1 GiB cycle: the bytes fit, but landing them leaves 1.5 GiB --
        # below the reserve the share's other tenants (image pool, proxy archive,
        # pool-intent.git) depend on.
        $v = Test-PoolStorageSpaceSufficient -FreeBytes ([long](2.5 * 1GB)) -NeedBytes 1GB
        Assert-False $v.ok 'reserve is protected, not just the copy'
        Assert-True ($v.shortfall -gt 0) 'shortfall reported'
    }
    It 'treats an UNMEASURABLE share as sufficient (never fails a cycle on a reading it could not take)' {
        $v = Test-PoolStorageSpaceSufficient -FreeBytes -1 -NeedBytes 500GB
        Assert-True $v.ok 'unknown free space -> proceed and let the copy fail loudly if it must'
    }
    It 'reports the reserve so a caller can explain the number to an operator' {
        Assert-Equal -Expected 2GB -Actual (Test-PoolStorageSpaceSufficient -FreeBytes 1GB -NeedBytes 1GB).reserve -Because 'reserve surfaced'
    }
}

Describe 'Get-PoolStorageProjectedSize (what the pre-spawn check expects a cycle to cost)' {
    It 'falls back to the floor when nothing has been archived yet' {
        Assert-Equal -Expected 1GB -Actual (Get-PoolStorageProjectedSize -Ledger ([ordered]@{})) -Because 'empty sample -> floor'
        Assert-Equal -Expected 1GB -Actual (Get-PoolStorageProjectedSize -Ledger $null) -Because 'no ledger -> floor'
    }
    It 'takes the MAX of the sample, not the mean' {
        # Guessing high costs one skipped cycle; guessing low costs a cycle that runs
        # to completion and then cannot be archived.
        $led = [ordered]@{ recentArchivedBytes = @(1GB, 9GB, 2GB) }
        Assert-Equal -Expected 9GB -Actual (Get-PoolStorageProjectedSize -Ledger $led) -Because 'max, so the big cycle is planned for'
    }
    It 'ignores junk entries in the sample' {
        $led = [ordered]@{ recentArchivedBytes = @(0, -5, 3GB, $null) }
        Assert-Equal -Expected 3GB -Actual (Get-PoolStorageProjectedSize -Ledger $led) -Because 'only positive samples count'
    }
}

Describe 'Add-PoolStorageArchivedSize (the rolling sample)' {
    It 'appends newest-last and caps the sample' {
        $s = @()
        foreach ($n in 1..8) { $s = Add-PoolStorageArchivedSize -Existing $s -Bytes ($n * 1MB) }
        Assert-Equal -Expected 5 -Actual (@($s).Count) -Because 'capped at PoolStorageProjectionSample'
        Assert-Equal -Expected (8MB) -Actual (@($s)[-1]) -Because 'newest last'
        Assert-Equal -Expected (4MB) -Actual (@($s)[0]) -Because 'oldest dropped'
    }
    It 'ignores a non-measurable size' {
        $s = Add-PoolStorageArchivedSize -Existing @(1MB) -Bytes -1
        Assert-Equal -Expected 1 -Actual (@($s).Count) -Because '-1 is not a sample'
    }
}

Describe 'Test-PoolStorageCycleCopy (shape verification)' {
    It 'passes on an identical tree' {
        $f = Get-MoveFixture
        try {
            $src = Join-Path $f.LogDir '000001.2026-08-16.10-00-00.HOSTID'
            $dst = Join-Path $f.Share 'copy'
            Copy-Item -LiteralPath $src -Destination $dst -Recurse
            $r = Test-PoolStorageCycleCopy -Source $src -Destination $dst
            Assert-True $r.ok 'identical trees verify'
        } finally { Clear-MoveFixture $f }
    }
    It 'fails when a file is missing (the truncated-tree case a per-file copy check cannot see)' {
        $f = Get-MoveFixture
        try {
            $src = Join-Path $f.LogDir '000001.2026-08-16.10-00-00.HOSTID'
            $dst = Join-Path $f.Share 'copy'
            Copy-Item -LiteralPath $src -Destination $dst -Recurse
            Remove-Item -LiteralPath (Join-Path $dst 'guest-1/diag.txt') -Force
            $r = Test-PoolStorageCycleCopy -Source $src -Destination $dst
            Assert-False $r.ok 'missing file caught'
            Assert-True ($r.reason -match 'file count') 'reason names the count'
        } finally { Clear-MoveFixture $f }
    }
    It 'fails when a file is truncated' {
        $f = Get-MoveFixture
        try {
            $src = Join-Path $f.LogDir '000001.2026-08-16.10-00-00.HOSTID'
            $dst = Join-Path $f.Share 'copy'
            Copy-Item -LiteralPath $src -Destination $dst -Recurse
            Set-Content -LiteralPath (Join-Path $dst 'guest-1/diag.txt') -Value 'x' -NoNewline
            $r = Test-PoolStorageCycleCopy -Source $src -Destination $dst
            Assert-False $r.ok 'short file caught'
            Assert-True ($r.reason -match 'bytes') 'reason names the bytes'
        } finally { Clear-MoveFixture $f }
    }
}

Describe 'Invoke-PoolStorageDrain -MoveLogs (the commit sequence)' {
    It 'copies, commits with the sentinel, records the ledger, and deletes the local folder' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 1 -Actual $r.moved -Because 'one cycle moved'
            Assert-Equal -Expected 1 -Actual $r.deleted -Because 'its local folder deleted'
            $dest = Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle $cycle
            Assert-True (Test-Path -LiteralPath $dest) 'archived under hosts/<hostId>/test-cycles/'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest '.yuruna-complete')) 'sentinel committed'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest "$cycle.html")) 'artifacts archived'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest 'guest-1/diag.txt')) 'nested artifacts archived'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'local folder gone'
        } finally { Clear-MoveFixture $f }
    }

    It 'NEVER touches a folder whose leaf is still .incomplete (that is the live cycle)' {
        $f = Get-MoveFixture -Cycles @('000002.2026-08-16.11-00-00.HOSTID') -Suffix '.incomplete'
        try {
            Enable-MoveStub
            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 0 -Actual $r.moved -Because 'the running cycle is not archived'
            Assert-Equal -Expected 0 -Actual $r.deleted -Because 'and certainly not deleted'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.LogDir '000002.2026-08-16.11-00-00.HOSTID.incomplete')) 'still local'
        } finally { Clear-MoveFixture $f }
    }

    It 'ADOPTS an already-committed archive instead of re-copying it (kill after sentinel, before ledger)' {
        # The killer detail: the local source may itself be half-deleted here. Re-
        # verifying it against the complete archive would fail and take the archive
        # with it -- destroying the only copy of a finished cycle.
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            $dest = Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle $cycle
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Set-Content -LiteralPath (Join-Path $dest "$cycle.html") -Value "<html>$cycle</html>" -NoNewline
            New-Item -ItemType Directory -Force -Path (Join-Path $dest 'guest-1') | Out-Null
            Set-Content -LiteralPath (Join-Path $dest 'guest-1/diag.txt') -Value 'diagnostics' -NoNewline
            Set-Content -LiteralPath (Join-Path $dest '.yuruna-complete') -Value 'committed' -NoNewline
            # A half-deleted local source, exactly as an interrupted delete leaves it.
            Remove-Item -LiteralPath (Join-Path $f.LogDir "$cycle/guest-1/diag.txt") -Force

            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 1 -Actual $r.moved -Because 'the committed archive is adopted'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest '.yuruna-complete')) 'THE ARCHIVE SURVIVED'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest 'guest-1/diag.txt')) 'and was not overwritten by the partial source'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'the local remainder is finished off'
        } finally { Clear-MoveFixture $f }
    }

    It 'SWEEPS a local folder whose archive is committed and whose ledger entry exists (kill during delete)' {
        # Not pending (the ledger has it), so only the sweep can finish it. Without
        # the sweep it survives until rotation -- on a host whose whole point is that
        # local storage stays flat.
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            $dest = Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle $cycle
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Set-Content -LiteralPath (Join-Path $dest '.yuruna-complete') -Value 'committed' -NoNewline
            $ledger = [ordered]@{ replicated = [ordered]@{ $cycle = '2026-08-16T10:30:00Z' } }
            $null = Write-PoolStorageLedger -RuntimeDir $f.RuntimeDir -Ledger $ledger -Confirm:$false

            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 1 -Actual $r.deleted -Because 'the sweep finished the interrupted delete'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'local folder gone'
            Assert-True (Test-Path -LiteralPath (Join-Path $dest '.yuruna-complete')) 'archive untouched'
        } finally { Clear-MoveFixture $f }
    }

    It 'keeps the local folder and removes the DESTINATION when verification fails' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            # Make the copy come out short: a stub Sync that drops one file.
            & (Get-Module Test.PoolStorage) {
                Set-Item -Path function:script:Sync-YurunaPoolStorageFolder -Value {
                    param($Config, $Source, $DestSubPath)
                    $dest = Join-PoolStoragePath -LocalPath $Config.LocalPath -SubPath $DestSubPath
                    New-Item -ItemType Directory -Force -Path $dest | Out-Null
                    # Copy the top-level file only -- the nested one never arrives.
                    Get-ChildItem -LiteralPath $Source -File | ForEach-Object {
                        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Force
                    }
                    return $true
                }
            }
            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 0 -Actual $r.moved -Because 'a failed verification is not a move'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'LOCAL FOLDER KEPT -- nothing is lost'
            Assert-False (Test-Path -LiteralPath (Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle $cycle)) 'the untrustworthy destination is removed'
        } finally { Clear-MoveFixture $f }
    }

    It 'refuses to copy anything when the share is full, and reports spaceShort' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            & (Get-Module Test.PoolStorage) { Set-Item -Path function:script:Get-PoolStorageFreeSpace -Value { param($Config) $null = $Config; return [long]1024 } }
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -SpaceCheck -NoLock -Confirm:$false
            Assert-True $r.spaceShort 'spaceShort reported'
            Assert-Equal -Expected 0 -Actual $r.moved -Because 'nothing copied'
            Assert-Equal -Expected 0 -Actual $r.deleted -Because 'and nothing deleted'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'the cycle is still local'
            Assert-True ($r.error -match 'full') 'the error says the share is full'
        } finally { Clear-MoveFixture $f }
    }

    It 'records recentArchivedBytes in COPY mode too, so a host flipped to move has a real projection' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cycle = '000001.2026-08-16.10-00-00.HOSTID'
            $null = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f -MoveLogs $false) -SpaceCheck -NoLock -Confirm:$false
            $led = Read-PoolStorageLedger -RuntimeDir $f.RuntimeDir
            Assert-True ($led.Contains('recentArchivedBytes')) 'the sample exists after a copy-mode run'
            Assert-True ((@($led['recentArchivedBytes']) | Measure-Object).Count -ge 1) 'and has an entry'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.LogDir $cycle)) 'copy mode keeps the local folder'
        } finally { Clear-MoveFixture $f }
    }

    It 'never re-archives a cycle whose local folder is gone (the ledger prune stays safe)' {
        # Move mode empties the replicated map as it deletes, which looks alarming
        # until you follow it through: pending is "local minus ledger", so a folder
        # that is gone locally can never re-enter the pending set.
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $cfg = Get-MoveConfigDoc -Fixture $f
            $null = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir -Config $cfg -MoveLogs -NoLock -Confirm:$false
            $dest = Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle '000001.2026-08-16.10-00-00.HOSTID'
            # -Force: the sentinel is dot-prefixed, so it is hidden on Unix and
            # Get-Item skips it without one.
            $stamp = (Get-Item -Force -LiteralPath (Join-Path $dest '.yuruna-complete')).LastWriteTimeUtc
            $second = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir -Config $cfg -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 0 -Actual $second.moved -Because 'nothing left to move'
            Assert-Equal -Expected $stamp -Actual (Get-Item -Force -LiteralPath (Join-Path $dest '.yuruna-complete')).LastWriteTimeUtc -Because 'the archive was not rewritten'
        } finally { Clear-MoveFixture $f }
    }

    It 'archives cycles that have rotated into a history bucket, flattening them onto the share' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            $bucket = Join-Path $f.LogDir 'history.2026-08-01'
            $rotated = '000042.2026-08-01.09-00-00.HOSTID'
            New-Item -ItemType Directory -Force -Path (Join-Path $bucket $rotated) | Out-Null
            Set-Content -LiteralPath (Join-Path $bucket "$rotated/$rotated.html") -Value 'old' -NoNewline

            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -NoLock -Confirm:$false
            Assert-Equal -Expected 2 -Actual $r.moved -Because 'the top-level cycle AND the rotated one'
            $dest = Get-ArchivedCyclePath -Fixture $f -HostId $script:HOSTID -Cycle $rotated
            Assert-True (Test-Path -LiteralPath $dest) 'the rotated cycle lands FLAT under test-cycles/, with no bucket'
            Assert-False (Test-Path -LiteralPath (Join-Path $bucket $rotated)) 'and its local copy is gone'
        } finally { Clear-MoveFixture $f }
    }
}

Describe 'Enter-/Exit-PoolStorageDrainLock (single instance across BOTH invocation paths)' {
    It 'is held once and refused to a second caller until released' {
        # The lock lives in the orchestrator rather than the detached wrapper
        # precisely so the in-process mover is covered by it: otherwise the
        # synchronous move could delete folders a straggler detached drain is
        # copying from.
        $f = Get-MoveFixture
        try {
            Assert-True (Enter-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir) 'first caller acquires'
            Assert-False (Enter-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir) 'second caller refused while it is held live'
            $null = Exit-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir -Confirm:$false
            Assert-True (Enter-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir) 'acquired again after release'
            $null = Exit-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir -Confirm:$false
        } finally { Clear-MoveFixture $f }
    }
    It 'reclaims a lock left behind by a process that no longer exists' {
        $f = Get-MoveFixture
        try {
            $lock = Join-Path $f.RuntimeDir 'poolstorage.drain.lock'
            # A PID that cannot be running, with a start time that cannot match.
            Set-Content -LiteralPath $lock -Value (@{ pid = 999999; startUtc = '2000-01-01T00:00:00.0000000Z' } | ConvertTo-Json -Compress)
            Assert-True (Enter-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir) 'stale lock reclaimed rather than blocking archiving forever'
            $null = Exit-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir -Confirm:$false
        } finally { Clear-MoveFixture $f }
    }
    It 'reports lockBusy and does nothing when the lock is already held' {
        $f = Get-MoveFixture
        try {
            Enable-MoveStub
            Assert-True (Enter-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir) 'hold it'
            $r = Invoke-PoolStorageDrain -HostId $script:HOSTID -LogDir $f.LogDir -RuntimeDir $f.RuntimeDir `
                -Config (Get-MoveConfigDoc -Fixture $f) -MoveLogs -Confirm:$false
            Assert-True $r.lockBusy 'lockBusy reported'
            Assert-Equal -Expected 0 -Actual $r.moved -Because 'nothing archived while another run holds the lock'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.LogDir '000001.2026-08-16.10-00-00.HOSTID')) 'and nothing deleted'
            $null = Exit-PoolStorageDrainLock -RuntimeDir $f.RuntimeDir -Confirm:$false
        } finally { Clear-MoveFixture $f }
    }
}
