<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42c1d8e4-6b7a-4c39-9f52-0a1b2c3d4e5f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery boot pester
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
    Pester coverage for the boot-recovery orphan sweep in Test.Recovery.psm1:
    Find-OrphanIncompleteCycle detects a crashed cycle and
    Resolve-OrphanIncompleteCycle archives it so a second sweep is a no-op.
.DESCRIPTION
    The crash signal is a HIDDEN file: the cycle-folder marker is named
    `.incomplete`, and the FileSystem provider treats a dot-prefixed name as
    hidden on macOS/Linux. Cmdlets that skip hidden items without -Force
    therefore see a marker Test-Path says is present and then fail to open it,
    which strands every crashed cycle folder on disk (detected, never
    archived, re-reported on the next boot). These cases run the sweep against
    a real temp log dir so that provider behavior is exercised, not mocked.

    Both crash shapes are covered: a folder carrying the `.incomplete` suffix
    WITH its marker file, and one whose marker is already gone (the rename
    failed after the marker was removed). Throw-based assertions so the file
    runs under the OS-bundled Pester 3.4 and under Pester 5+.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Recovery.psm1'
Import-Module $modulePath -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# File-scope fixture helper: a Describe body runs during discovery and
# everything it declares is discarded before any It executes, so a helper
# defined there would be a CommandNotFoundException by the time an It calls it.
# Only the path computation is at file scope; the directories themselves are
# created inside the It bodies, which run once.
$script:CycleLeaf = '004116.2026-07-29.10-04-33.4287d16ff2c346a98ea90fd3a0c307da'

function New-CrashedCycleFixture {
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a throwaway temp log dir the calling It block removes in its finally.')]
    param([switch]$WithoutMarker)
    $logDir = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-recovery-' + [guid]::NewGuid().ToString('N'))
    $folder = Join-Path $logDir ($script:CycleLeaf + '.incomplete')
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    # A transcript sibling proves the folder rename carries content along.
    [System.IO.File]::WriteAllText((Join-Path $folder ($script:CycleLeaf + '.html')), '<html></html>')
    if (-not $WithoutMarker) {
        $payload = '{"cycleStartUtc":"2026-07-29T10:04:33Z","cycleNumber":4116,"cycleFolder":"' +
                   $script:CycleLeaf + '","startedAtUtc":"2026-07-29T10:04:33Z","pid":47052,"hostname":"fixture.local"}'
        [System.IO.File]::WriteAllText((Join-Path $folder '.incomplete'), $payload)
    }
    return @{ LogDir = $logDir; Folder = $folder }
}

Describe 'Boot recovery detects a crashed cycle through its hidden marker' {
    It 'finds the .incomplete marker file inside a suffixed cycle folder' {
        $fx = New-CrashedCycleFixture
        try {
            $orphans = @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir)
            Assert-Equal -Expected 1 -Actual $orphans.Count -Because 'the crashed cycle must surface exactly one orphan signal'
            Assert-Equal -Expected '.incomplete' -Actual $orphans[0].Name -Because 'the marker FILE is the signal when it survived the crash'
            Assert-True ($orphans[0] -is [System.IO.FileInfo]) `
                'a dot-prefixed name is hidden to the provider -- the lookup must pass -Force or it yields nothing at all'
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'falls back to the folder itself when the marker is already gone' {
        $fx = New-CrashedCycleFixture -WithoutMarker
        try {
            $orphans = @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir)
            Assert-Equal -Expected 1 -Actual $orphans.Count -Because 'the .incomplete SUFFIX alone still signals a crash'
            Assert-True ($orphans[0] -is [System.IO.DirectoryInfo]) 'with no marker file the folder is the signal'
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'ignores a cleanly-closed cycle folder' {
        $fx = New-CrashedCycleFixture
        try {
            $closed = Join-Path -Path $fx.LogDir -ChildPath $script:CycleLeaf
            Move-Item -LiteralPath $fx.Folder -Destination $closed
            Remove-Item -LiteralPath (Join-Path -Path $closed -ChildPath '.incomplete') -Force
            Assert-Equal -Expected 0 -Actual @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir).Count `
                -Because 'no suffix and no marker means the cycle closed cleanly'
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Boot recovery archives what it detects (a second sweep is a no-op)' {
    It 'renames the folder away from .incomplete and replaces the marker with an .aborted archive' {
        $fx = New-CrashedCycleFixture
        try {
            $orphans = @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir)
            $result  = Resolve-OrphanIncompleteCycle -MarkerPath $orphans[0].FullName -Confirm:$false
            Assert-True ($null -ne $result) 'archiving a detected orphan must report what it did'
            Assert-True ($result.cycleFolder -match '\.aborted\.') "folder must be renamed to .aborted.<UTC>, got '$($result.cycleFolder)'"
            Assert-Equal -Expected 'marker_file' -Actual $result.signal -Because 'the marker file carries the forensic payload'
            Assert-True ($result.archivedAs -match '^\.aborted\..*\.json$') `
                "the payload must be archived beside the cycle, got '$($result.archivedAs)'"
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'carries the marker payload into the archive and leaves the sweep with nothing to do' {
        $fx = New-CrashedCycleFixture
        try {
            $orphans = @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir)
            $result  = Resolve-OrphanIncompleteCycle -MarkerPath $orphans[0].FullName -Confirm:$false
            Assert-Equal -Expected 47052 -Actual $result.markerPid -Because 'the crashed pid must survive into the archive'
            $final = Join-Path -Path $fx.LogDir -ChildPath $result.cycleFolder
            # The archive is the forensic record a post-mortem reads, so assert
            # the payload on DISK, not the in-memory report: the cycle start has
            # to come back out with its UTC designator intact.
            $archived = Get-Content -Raw -LiteralPath (Join-Path -Path $final -ChildPath $result.archivedAs)
            Assert-True ($archived -match '"cycleStartUtc"\s*:\s*"2026-07-29T10:04:33Z"') `
                "the crashed cycle start must survive into the archive verbatim, got: $archived"
            Assert-True ($archived -match '"recoverySignal"\s*:\s*"marker_file"') `
                'the archive must record which crash signal recovered it'
            Assert-True (Test-Path -LiteralPath (Join-Path -Path $final -ChildPath ($script:CycleLeaf + '.html'))) `
                'the rename must carry the cycle transcript along'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path -Path $final -ChildPath '.incomplete'))) `
                'the consumed marker must be gone or the next sweep re-archives the same cycle'
            # -Force on the enumeration for the same hidden-dotfile reason the
            # production lookup needs it: `.aborted.<UTC>.json` is dot-prefixed.
            Assert-Equal -Expected 1 -Actual @(Get-ChildItem -LiteralPath $final -Filter '.aborted.*.json' -Force).Count `
                -Because 'the archived payload lands beside the cycle it describes'
            Assert-Equal -Expected 0 -Actual @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir).Count `
                -Because 'a second sweep must be a no-op'
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'archives the marker-less shape by renaming the folder alone' {
        $fx = New-CrashedCycleFixture -WithoutMarker
        try {
            $orphans = @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir)
            $result  = Resolve-OrphanIncompleteCycle -MarkerPath $orphans[0].FullName -Confirm:$false
            Assert-Equal -Expected 'folder_suffix' -Actual $result.signal -Because 'with no marker the folder suffix is the only signal'
            Assert-True ($result.cycleFolder -match '\.aborted\.') 'the folder must still leave the .incomplete state'
            Assert-Equal -Expected 0 -Actual @(Find-OrphanIncompleteCycle -LogDir $fx.LogDir).Count `
                -Because 'a second sweep must be a no-op'
        } finally { Remove-Item -LiteralPath $fx.LogDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
