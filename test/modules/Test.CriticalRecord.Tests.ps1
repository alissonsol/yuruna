<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42334199-853f-4548-a2c0-8f411e948509
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test critical-record durability host-refresh pester
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
    Test.CriticalRecord's checksummed, generation-numbered private records:
    compare-and-set generations, fallback to the last valid generation on a
    damaged current file (and refusal, not fallback, on a newer version or a
    different kind), a real process killed after each write stage leaving
    either the old or the new generation readable, bounded I/O steps, the
    durability declaration, preview, and a fresh-process dependency closure.
#>

BeforeDiscovery {
    $script:SkipPermissionCase = $IsWindows
    if (-not $IsWindows) {
        Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))) 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
        $identity = Get-YurunaCurrentOwnerId
        if (-not $identity.Resolved -or $identity.IsRoot) { $script:SkipPermissionCase = $true }
    }
    $script:SkipDateString = -not (Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -Force -DisableNameChecking
    $script:ModulePath = Join-Path $here 'Test.CriticalRecord.psm1'
    $script:Pwsh = (Get-Process -Id $PID).Path
    if (-not $script:Pwsh) { $script:Pwsh = 'pwsh' }
    $script:TempDirs = [System.Collections.Generic.List[string]]::new()
    $script:Kind = 'test.record'
    $script:Stages = @('validated', 'temp-written', 'temp-flushed', 'temp-verified',
        'previous-preserved', 'current-replaced', 'directory-committed', 'verified')

    function New-RecordDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture temp dir.')]
        param()
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-critical'
        $script:TempDirs.Add($dir)
        return $dir
    }

    function Write-TestRecord {
        param([string]$Path, [hashtable]$Payload, [long]$Expected)
        Write-YurunaCriticalRecord -Path $Path -Kind $script:Kind -Payload $Payload -ExpectedGeneration $Expected -Confirm:$false
    }

    function Get-FileHex {
        param([string]$Path)
        [Convert]::ToHexString([IO.File]::ReadAllBytes($Path))
    }

    function Get-OrphanTemp {
        param([string]$Directory, [string]$Leaf)
        @(Get-ChildItem -LiteralPath $Directory -File | Where-Object { $_.Name -match ('^' + [regex]::Escape($Leaf) + '(\.prev)?\.[0-9]+-[0-9a-f]{32}\.tmp$') })
    }

    # Rewrites a record's header line with one field changed, keeping the
    # payload and its checksum, so only that field is wrong.
    function Set-RecordHeaderField {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: damages a record file inside a throwaway temp dir.')]
        param([string]$Path, [string]$Name, $Value)
        $bytes = [IO.File]::ReadAllBytes($Path)
        $lineEnd = [Array]::IndexOf($bytes, [byte]10)
        $header = [Text.Encoding]::ASCII.GetString($bytes, 0, $lineEnd) | ConvertFrom-Json -AsHashtable
        $header[$Name] = $Value
        $newHeader = [Text.Encoding]::ASCII.GetBytes(($header | ConvertTo-Json -Compress))
        $payload = [byte[]]::new($bytes.Length - $lineEnd - 1)
        [Array]::Copy($bytes, $lineEnd + 1, $payload, 0, $payload.Length)
        [IO.File]::WriteAllBytes($Path, [byte[]]($newHeader + [byte[]]@(10) + $payload))
    }

    # Appends zero bytes past the record's end, pushing the file over the
    # default MaxBytes while leaving its header intact.
    function Add-RecordPadding {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: damages a record file inside a throwaway temp dir.')]
        param([string]$Path, [int]$Count)
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Append)
        try { $stream.Write([byte[]]::new($Count), 0, $Count) } finally { $stream.Dispose() }
    }

    function Invoke-FlipLastByte {
        param([string]$Path)
        $bytes = [IO.File]::ReadAllBytes($Path)
        $bytes[$bytes.Length - 2] = $bytes[$bytes.Length - 2] -bxor 0x01
        [IO.File]::WriteAllBytes($Path, $bytes)
    }
}

AfterAll {
    foreach ($dir in $script:TempDirs) {
        try {
            if (-not $IsWindows -and [IO.Directory]::Exists($dir)) {
                [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
            }
        } catch { $null = $_ }
        Remove-YurunaTestTempDir $dir
    }
}

Describe 'Write-YurunaCriticalRecord / Read-YurunaCriticalRecord -- generations' {
    It 'creates a record from nothing and refuses a second creation' {
        $path = Join-Path (New-RecordDir) 'a.record'
        $missing = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $missing.Status     | Should -Be 'missing'
        $missing.Generation | Should -Be 0

        $w = Write-TestRecord -Path $path -Payload @{ state = 'queued' } -Expected 0
        $w.Committed          | Should -Be $true
        $w.Reason             | Should -Be 'ok'
        $w.Stage              | Should -Be 'verified'
        $w.Generation         | Should -Be 1
        $w.PreviousGeneration | Should -Be 0
        $w.Durability         | Should -Be 'process-crash'

        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status        | Should -Be 'ok'
        $r.Source        | Should -Be 'current'
        $r.Degraded      | Should -Be $false
        $r.Generation    | Should -Be 1
        $r.Payload.state | Should -Be 'queued'
        $r.WrittenUtc    | Should -Match '^\d{4}-\d{2}-\d{2}T'
        [IO.File]::Exists("$path.prev") | Should -Be $false -Because 'there was no earlier generation to keep'

        $again = Write-TestRecord -Path $path -Payload @{ state = 'other' } -Expected 0
        $again.Committed | Should -Be $false
        $again.Reason    | Should -Be 'generation-conflict'
    }

    It 'keeps the replaced generation as .prev and refuses a stale writer without touching either file' {
        $path = Join-Path (New-RecordDir) 'a.record'
        (Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0).Generation | Should -Be 1
        (Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1).Generation | Should -Be 2
        (Write-TestRecord -Path $path -Payload @{ n = 3 } -Expected 2).Generation | Should -Be 3
        $current = Get-FileHex -Path $path
        $previous = Get-FileHex -Path "$path.prev"
        $prevRead = Read-YurunaCriticalRecord -Path "$path.prev" -Kind $script:Kind
        $prevRead.Payload.n | Should -Be 2

        $stale = Write-TestRecord -Path $path -Payload @{ n = 99 } -Expected 2
        $stale.Reason             | Should -Be 'generation-conflict'
        $stale.PreviousGeneration | Should -Be 3
        (Get-FileHex -Path $path) | Should -Be $current
        (Get-FileHex -Path "$path.prev") | Should -Be $previous
    }

    It 'refuses a writer that lost a race after reading, rather than replacing the newer decision' {
        $path = Join-Path (New-RecordDir) 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $kind = $script:Kind
        # Another writer lands a new generation between this writer's read
        # and its copy of the current file.
        $interloper = {
            param($stage)
            if ($stage -eq 'temp-verified') {
                $null = Write-YurunaCriticalRecord -Path $path -Kind $kind -Payload @{ n = 'interloper' } -ExpectedGeneration 1 -Confirm:$false
            }
        }.GetNewClosure()
        $w = Write-YurunaCriticalRecord -Path $path -Kind $script:Kind -Payload @{ n = 'loser' } -ExpectedGeneration 1 -StageHook $interloper -Confirm:$false
        $w.Committed | Should -Be $false
        $w.Reason    | Should -Be 'generation-conflict'
        $w.Stage     | Should -Be 'previous-preserved'
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Generation | Should -Be 2
        $r.Payload.n  | Should -Be 'interloper'
        @(Get-OrphanTemp -Directory (Split-Path -Parent $path) -Leaf 'a.record').Count | Should -Be 0
    }
}

Describe 'Read-YurunaCriticalRecord -- last valid generation' {
    It 'falls back to the previous generation when the current file is damaged or missing' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        $good = [IO.File]::ReadAllBytes($path)

        [IO.File]::WriteAllBytes($path, [byte[]]@())
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status        | Should -Be 'ok'
        $r.Source        | Should -Be 'previous'
        $r.Degraded      | Should -Be $true
        $r.Generation    | Should -Be 1
        $r.Payload.n     | Should -Be 1
        $r.CurrentReason | Should -Be 'malformed-header'

        [IO.File]::WriteAllBytes($path, $good)
        Invoke-FlipLastByte -Path $path
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.CurrentReason     | Should -Be 'checksum-mismatch'
        $r.Source            | Should -Be 'previous'
        $r.HighestGeneration | Should -Be 2 -Because 'a damaged file''s parseable header still reserves its generation'

        [IO.File]::WriteAllBytes($path, $good[0..($good.Length - 3)])
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.CurrentReason | Should -Be 'truncated'
        $r.Source        | Should -Be 'previous'

        [IO.File]::Delete($path)
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status        | Should -Be 'ok'
        $r.Source        | Should -Be 'previous'
        $r.CurrentReason | Should -Be 'missing'
    }

    It 'never falls back past a newer version or a different kind, and reports corrupt or missing otherwise' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        $good = [IO.File]::ReadAllBytes($path)

        Set-RecordHeaderField -Path $path -Name 'version' -Value 2
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status  | Should -Be 'unsupported-version'
        $r.Source  | Should -BeNullOrEmpty
        $r.Payload | Should -BeNullOrEmpty

        [IO.File]::WriteAllBytes($path, $good)
        (Read-YurunaCriticalRecord -Path $path -Kind 'other.record').Status | Should -Be 'kind-mismatch'

        Invoke-FlipLastByte -Path $path
        Invoke-FlipLastByte -Path "$path.prev"
        (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Status | Should -Be 'corrupt'

        (Read-YurunaCriticalRecord -Path (Join-Path $dir 'none.record') -Kind $script:Kind).Status | Should -Be 'missing'
    }

    It 'writes past a damaged current file with a generation above every one seen, leaving the good .prev alone' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        foreach ($expected in 0..2) { $null = Write-TestRecord -Path $path -Payload @{ n = $expected + 1 } -Expected $expected }
        Invoke-FlipLastByte -Path $path
        $read = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $read.Generation        | Should -Be 2
        $read.HighestGeneration | Should -Be 3
        $prevBytes = Get-FileHex -Path "$path.prev"

        $w = Write-TestRecord -Path $path -Payload @{ n = 'repaired' } -Expected 2
        $w.Committed  | Should -Be $true
        $w.Generation | Should -Be 4 -Because 'generation 3 was already used by the damaged file'
        (Get-FileHex -Path "$path.prev") | Should -Be $prevBytes -Because 'a damaged current is never copied over a good previous generation'
        (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Payload.n | Should -Be 'repaired'
    }

    It 'reserves the generation of an oversized current file, so the next write never reuses it' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        Add-RecordPadding -Path $path -Count 1100000
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status            | Should -Be 'ok'
        $r.Source            | Should -Be 'previous'
        $r.CurrentReason     | Should -Be 'too-large'
        $r.Generation        | Should -Be 1
        $r.HighestGeneration | Should -Be 2 -Because 'the oversized file''s header still carries generation 2'

        $w = Write-TestRecord -Path $path -Payload @{ n = 'after' } -Expected 1
        $w.Committed  | Should -Be $true
        $w.Generation | Should -Be 3 -Because 'generation 2 was already used by the oversized file'
        (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Payload.n | Should -Be 'after'
    }

    It 'refuses, rather than falls back past, an oversized current file of a newer version or another kind' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        $good = [IO.File]::ReadAllBytes($path)

        Set-RecordHeaderField -Path $path -Name 'version' -Value 2
        Add-RecordPadding -Path $path -Count 1100000
        $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
        $r.Status        | Should -Be 'unsupported-version'
        $r.CurrentReason | Should -Be 'unsupported-version'
        $r.Payload       | Should -BeNullOrEmpty

        [IO.File]::WriteAllBytes($path, $good)
        Add-RecordPadding -Path $path -Count 1100000
        $other = Read-YurunaCriticalRecord -Path $path -Kind 'other.record'
        $other.Status | Should -Be 'kind-mismatch'
    }

    It 'refuses to write over two damaged files and leaves both byte-identical' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        Invoke-FlipLastByte -Path $path
        Invoke-FlipLastByte -Path "$path.prev"
        $current = Get-FileHex -Path $path
        $previous = Get-FileHex -Path "$path.prev"
        foreach ($expected in @(0, 1, 2)) {
            $w = Write-TestRecord -Path $path -Payload @{ n = 'x' } -Expected $expected
            $w.Committed | Should -Be $false
            $w.Reason    | Should -Be 'existing-record-invalid'
        }
        (Get-FileHex -Path $path) | Should -Be $current
        (Get-FileHex -Path "$path.prev") | Should -Be $previous
    }
}

Describe 'Crash recovery -- a process killed after each write stage' {
    It 'leaves the old generation readable before the replace and the new one after it, for every stage' {
        $root = New-RecordDir
        $child = Join-Path $root 'crash.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value @'
param([string]$ModulePath, [string]$Path, [string]$Kind, [string]$CrashStage)
Import-Module $ModulePath -DisableNameChecking
$hook = { param($stage) if ($stage -eq $CrashStage) { [System.Diagnostics.Process]::GetCurrentProcess().Kill() } }.GetNewClosure()
$null = Write-YurunaCriticalRecord -Path $Path -Kind $Kind -Payload @{ n = 2 } -ExpectedGeneration 1 -StageHook $hook -Confirm:$false
exit 0
'@
        $processes = @{}
        foreach ($stage in $script:Stages) {
            $dir = Join-Path $root $stage
            $null = [IO.Directory]::CreateDirectory($dir)
            $null = Write-TestRecord -Path (Join-Path $dir 'a.record') -Payload @{ n = 1 } -Expected 0
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $child, '-ModulePath', $script:ModulePath,
                    '-Path', (Join-Path $dir 'a.record'), '-Kind', $script:Kind, '-CrashStage', $stage)) { $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $processes[$stage] = [System.Diagnostics.Process]::Start($psi)
        }
        try {
            foreach ($stage in $script:Stages) { $null = $processes[$stage].WaitForExit(120000) }
            $replacedFrom = [Array]::IndexOf($script:Stages, 'current-replaced')
            for ($i = 0; $i -lt $script:Stages.Count; $i++) {
                $stage = $script:Stages[$i]
                $dir = Join-Path $root $stage
                $path = Join-Path $dir 'a.record'
                $processes[$stage].HasExited | Should -Be $true
                $processes[$stage].ExitCode | Should -Not -Be 0 -Because "the writer was killed at $stage"
                $r = Read-YurunaCriticalRecord -Path $path -Kind $script:Kind
                $r.Status | Should -Be 'ok' -Because "a crash at $stage must leave a readable generation"
                $r.Source | Should -Be 'current' -Because "the replace is atomic, so the current file is never torn ($stage)"
                $expectedGeneration = if ($i -ge $replacedFrom) { 2 } else { 1 }
                $r.Generation | Should -Be $expectedGeneration -Because "crash at $stage"
                $r.Payload.n  | Should -Be $expectedGeneration

                $hasPrev = [IO.File]::Exists("$path.prev")
                $hasPrev | Should -Be ($i -ge [Array]::IndexOf($script:Stages, 'previous-preserved')) -Because "crash at $stage"
                $orphans = @(Get-OrphanTemp -Directory $dir -Leaf 'a.record')
                $expectOrphan = ($i -ge 1 -and $i -lt $replacedFrom)
                ($orphans.Count -gt 0) | Should -Be $expectOrphan -Because "crash at $stage"

                $next = Write-TestRecord -Path $path -Payload @{ n = 'next' } -Expected $r.Generation
                $next.Committed  | Should -Be $true -Because "the next writer recovers after a crash at $stage"
                $next.Generation | Should -Be ($r.Generation + 1)
                @(Get-OrphanTemp -Directory $dir -Leaf 'a.record').Count | Should -Be 0 -Because 'a successful write sweeps an interrupted write''s temporary files'
            }
        } finally {
            foreach ($p in $processes.Values) {
                try { if (-not $p.HasExited -and $p.ProcessName -like 'pwsh*') { $p.Kill() } } catch { $null = $_ }
            }
        }
    }

    It 'sweeps only temporary files of its own record and name shape' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $orphan = Join-Path $dir ('a.record.4242-' + ('0' * 32) + '.tmp')
        $orphanPrev = Join-Path $dir ('a.record.prev.4242-' + ('f' * 32) + '.tmp')
        $unrelated = @((Join-Path $dir 'a.record.notes.tmp'), (Join-Path $dir ('b.record.4242-' + ('0' * 32) + '.tmp')))
        foreach ($f in @($orphan, $orphanPrev) + $unrelated) { [IO.File]::WriteAllText($f, 'x') }
        $null = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        [IO.File]::Exists($orphan) | Should -Be $false
        [IO.File]::Exists($orphanPrev) | Should -Be $false
        foreach ($f in $unrelated) { [IO.File]::Exists($f) | Should -Be $true }
    }
}

Describe 'Write-YurunaCriticalRecord -- refusals write nothing' {
    It 'refuses a record over MaxBytes and a payload deeper than 32 levels' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $big = Write-YurunaCriticalRecord -Path $path -Kind $script:Kind -Payload @{ blob = ('x' * 5000) } -ExpectedGeneration 0 -MaxBytes 1024 -Confirm:$false
        $big.Reason | Should -Be 'too-large'
        $deep = @{ leaf = 1 }
        for ($i = 0; $i -lt 40; $i++) { $deep = @{ inner = $deep } }
        $tooDeep = Write-TestRecord -Path $path -Payload $deep -Expected 0
        $tooDeep.Reason | Should -Be 'payload-too-deep'
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
    }

    It 'refuses a payload that is not a JSON object' {
        $dir = New-RecordDir
        $w = Write-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind $script:Kind -Payload @(1, 2) -ExpectedGeneration 0 -Confirm:$false
        $w.Reason | Should -Be 'serialize-failed'
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
    }

    It 'refuses a record or previous generation that is a symbolic link' -Skip:$IsWindows {
        $dir = New-RecordDir
        $target = Join-Path $dir 'elsewhere'
        [IO.File]::WriteAllText($target, 'untouched')
        $linked = Join-Path $dir 'a.record'
        $null = [IO.File]::CreateSymbolicLink($linked, $target)
        (Write-TestRecord -Path $linked -Payload @{ n = 1 } -Expected 0).Reason | Should -Be 'reparse-point'
        (Read-YurunaCriticalRecord -Path $linked -Kind $script:Kind).Status | Should -Be 'reparse-point'
        $other = Join-Path $dir 'b.record'
        $null = [IO.File]::CreateSymbolicLink("$other.prev", $target)
        (Write-TestRecord -Path $other -Payload @{ n = 1 } -Expected 0).Reason | Should -Be 'reparse-point'
        [IO.File]::ReadAllText($target) | Should -Be 'untouched'
    }

    It 'refuses a missing parent directory' {
        $dir = New-RecordDir
        $w = Write-TestRecord -Path (Join-Path $dir 'missing/a.record') -Payload @{ n = 1 } -Expected 0
        $w.Reason | Should -Be 'parent-missing'
        [IO.Directory]::Exists((Join-Path $dir 'missing')) | Should -Be $false
    }

    It 'reports access-denied for an unwritable directory and leaves the record unchanged' -Skip:$script:SkipPermissionCase {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        $before = Get-FileHex -Path $path
        [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserExecute')
        try {
            $w = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
            $w.Committed | Should -Be $false
            $w.Reason    | Should -Be 'access-denied'
            $w.IoKind    | Should -Be 'access-denied'
            $w.Stage     | Should -Be 'temp-written'
        } finally {
            [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        (Get-FileHex -Path $path) | Should -Be $before
    }

    It 'refuses with deadline-exhausted, writing nothing, when under a second is left' {
        $dir = New-RecordDir
        $tick  = [ref]0L
        $clock = { $tick.Value }.GetNewClosure()
        $deadline = New-YurunaDeadline -TotalMilliseconds 900 -ClockTicks $clock
        $w = Write-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind $script:Kind -Payload @{ n = 1 } -ExpectedGeneration 0 -Deadline $deadline -Confirm:$false
        $w.Committed | Should -Be $false
        $w.Reason    | Should -Be 'deadline-exhausted'
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
    }

    It 'previews under -WhatIf and writes nothing' {
        $dir = New-RecordDir
        $w = Write-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind $script:Kind -Payload @{ n = 1 } -ExpectedGeneration 0 -WhatIf
        $w.Committed | Should -Be $false
        $w.Reason    | Should -Be 'preview'
        $w.Stage     | Should -Be 'none'
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
    }

    It 'rejects a kind outside lowercase letters, digits, dots and hyphens' {
        $dir = New-RecordDir
        { Write-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind 'Upper.Kind' -Payload @{} -ExpectedGeneration 0 -Confirm:$false } | Should -Throw
        { Read-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind 'bad kind' } | Should -Throw
    }
}

Describe 'Durability -- flushes are reported, power loss is never claimed without evidence' {
    It 'declares process-crash durability on every platform' {
        foreach ($platform in @('linux', 'macos', 'windows')) {
            $d = Get-YurunaCriticalRecordDurability -Platform $platform
            $d.Platform           | Should -Be $platform
            $d.PowerLossQualified | Should -Be $false
            $d.Claim              | Should -Be 'process-crash'
            $d.DataFlush          | Should -Not -BeNullOrEmpty
            $d.DirectoryCommit    | Should -Not -BeNullOrEmpty
        }
        (Get-YurunaCriticalRecordDurability -Platform macos).DataFlush | Should -Be 'full-fsync'
        (Get-YurunaCriticalRecordDurability -Platform windows).DirectoryCommit | Should -Be 'write-through-rename'
    }

    It 'refuses a power-loss requirement before writing anything' {
        $dir = New-RecordDir
        $w = Write-YurunaCriticalRecord -Path (Join-Path $dir 'a.record') -Kind $script:Kind -Payload @{ n = 1 } -ExpectedGeneration 0 -RequireDurability PowerLoss -Confirm:$false
        $w.Committed | Should -Be $false
        $w.Reason    | Should -Be 'durability-unavailable'
        @(Get-ChildItem -LiteralPath $dir).Count | Should -Be 0
    }

    It 'confirms its flushes on a normal Linux write' -Skip:(-not $IsLinux) {
        $dir = New-RecordDir
        $w = Write-TestRecord -Path (Join-Path $dir 'a.record') -Payload @{ n = 1 } -Expected 0
        $w.Committed        | Should -Be $true
        $w.FlushesConfirmed | Should -Be $true -Because 'the helper compiled and fsync succeeded for the file and the directory'
    }

    It 'commits without confirmed flushes under ProcessCrash when a flush times out' {
        $dir = New-RecordDir
        Mock -ModuleName Test.CriticalRecord Wait-YurunaCriticalIoTask -ParameterFilter { $Operation -eq 'flush-temp' } -MockWith {
            $null = $Task.Wait(5000)
            [pscustomobject]@{ Completed = $false; TimedOut = $true; Result = $null; Exception = $null }
        }
        $w = Write-TestRecord -Path (Join-Path $dir 'a.record') -Payload @{ n = 1 } -Expected 0
        $w.Committed        | Should -Be $true -Because 'the atomic replace alone survives a process crash'
        $w.FlushesConfirmed | Should -Be $false
        $w.Durability       | Should -Be 'process-crash'
    }

    It 'reports io-timeout, not committed, when the replace does not finish in time' {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ n = 1 } -Expected 0
        Mock -ModuleName Test.CriticalRecord Wait-YurunaCriticalIoTask -ParameterFilter { $Operation -eq 'replace-current' } -MockWith {
            $null = $Task.Wait(5000)
            [pscustomobject]@{ Completed = $false; TimedOut = $true; Result = $null; Exception = $null }
        }
        $w = Write-TestRecord -Path $path -Payload @{ n = 2 } -Expected 1
        $w.Committed | Should -Be $false
        $w.Reason    | Should -Be 'io-timeout'
        $w.Stage     | Should -Be 'current-replaced'
        # The rename finished after the wait gave up: the new generation can
        # be visible even though the writer reported failure.
        (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Generation | Should -Be 2
    }

    It 'refuses under PowerLoss when a flush is unconfirmed, and claims power-loss only when every flush is' {
        $platform = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'macos' } else { 'linux' }
        $module = Get-Module Test.CriticalRecord
        & $module { param($p) $script:CriticalRecordDurability[$p].PowerLossQualified = $true } $platform
        try {
            $dir = New-RecordDir
            if ($IsLinux) {
                $ok = Write-YurunaCriticalRecord -Path (Join-Path $dir 'ok.record') -Kind $script:Kind -Payload @{ n = 1 } -ExpectedGeneration 0 -RequireDurability PowerLoss -Confirm:$false
                $ok.Committed  | Should -Be $true
                $ok.Durability | Should -Be 'power-loss'
            }
            Mock -ModuleName Test.CriticalRecord Wait-YurunaCriticalIoTask -ParameterFilter { $Operation -eq 'flush-temp' } -MockWith {
                $null = $Task.Wait(5000)
                [pscustomobject]@{ Completed = $false; TimedOut = $true; Result = $null; Exception = $null }
            }
            $path = Join-Path $dir 'a.record'
            $w = Write-YurunaCriticalRecord -Path $path -Kind $script:Kind -Payload @{ n = 1 } -ExpectedGeneration 0 -RequireDurability PowerLoss -Confirm:$false
            $w.Committed | Should -Be $false
            $w.Reason    | Should -Be 'durability-unconfirmed'
            $w.Stage     | Should -Be 'temp-flushed'
            [IO.File]::Exists($path) | Should -Be $false
            @(Get-OrphanTemp -Directory $dir -Leaf 'a.record').Count | Should -Be 0 -Because 'a refused write removes its own temporary file'
        } finally {
            & $module { param($p) $script:CriticalRecordDurability[$p].PowerLossQualified = $false } $platform
        }
    }
}

Describe 'Payload round trip -- collections keep their shape after explicit normalization' {
    It 'round-trips zero, one and many keys and one-element, empty and many-element arrays' {
        $dir = New-RecordDir
        $empty = Join-Path $dir 'empty.record'
        $null = Write-TestRecord -Path $empty -Payload @{} -Expected 0
        $p = (Read-YurunaCriticalRecord -Path $empty -Kind $script:Kind).Payload
        $p | Should -BeOfType [hashtable]
        $p.Count | Should -Be 0

        $path = Join-Path $dir 'shapes.record'
        $null = Write-TestRecord -Path $path -Expected 0 -Payload @{
            one = 'x'; single = @('only'); none = @(); many = @(1, 2, 3); nested = @{ inner = @('a') }
        }
        $p = (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Payload
        $p.Count | Should -Be 5
        $p.one | Should -Be 'x'
        # A one-element array is normalized by the caller's schema with @().
        $single = @($p.single)
        $single.Count | Should -Be 1
        $single[0] | Should -Be 'only'
        @($p.none).Count | Should -Be 0
        @($p.many) | Should -Be @(1, 2, 3)
        @($p.nested.inner).Count | Should -Be 1
    }

    It 'hands back date-shaped strings as the strings it was given' -Skip:$script:SkipDateString {
        $dir = New-RecordDir
        $path = Join-Path $dir 'a.record'
        $null = Write-TestRecord -Path $path -Payload @{ observedUtc = '2026-09-25T11:53:08.1822210Z' } -Expected 0
        $value = (Read-YurunaCriticalRecord -Path $path -Kind $script:Kind).Payload.observedUtc
        $value | Should -BeOfType [string]
        $value | Should -Be '2026-09-25T11:53:08.1822210Z'
    }
}

Describe 'Dependency closure' {
    It 'writes and reads in a fresh process that imports only this module' {
        $dir = New-RecordDir
        $closure = Join-Path $dir 'closure.ps1'
        Set-Content -LiteralPath $closure -Encoding utf8 -Value @'
param([string]$ModulePath, [string]$Path)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -DisableNameChecking
if (-not (Initialize-YurunaCriticalRecordIo)) { Write-Output 'INIT=False'; exit 1 }
$w = Write-YurunaCriticalRecord -Path $Path -Kind 'closure.check' -Payload @{ ok = $true } -ExpectedGeneration 0 -Confirm:$false
if (-not $w.Committed) { Write-Output "WRITE=$($w.Reason)"; exit 1 }
$r = Read-YurunaCriticalRecord -Path $Path -Kind 'closure.check'
if ($r.Status -ne 'ok' -or -not $r.Payload.ok) { Write-Output "READ=$($r.Status)"; exit 1 }
Write-Output 'CLOSURE=OK'
exit 0
'@
        $r = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -TimeoutSeconds 90 `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $closure, '-ModulePath', $script:ModulePath, '-Path', (Join-Path $dir 'c.record'))
        @(Get-BoundedNativeOutputLine -Result $r) | Should -Contain 'CLOSURE=OK'
        $r.ExitCode | Should -Be 0
    }
}
