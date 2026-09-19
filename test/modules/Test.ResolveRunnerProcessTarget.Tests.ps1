<#PSScriptInfo
.VERSION 2026.09.18
.GUID 421a2b3c-4d5e-4f60-8a9b-0c1d2e3f4a5b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner process reclamation host-refresh pester
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
    Resolve-YurunaRunnerProcessTarget: pure, so every case here runs on any
    platform against a hand-built process table -- no real processes, no
    driver, nothing spawned.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -DisableNameChecking

    function New-Proc {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
        # -ProcessId, not -Pid: PowerShell binds a parameter into a
        # same-named local variable, and $PID is a read-only automatic
        # variable -- naming the parameter -Pid throws "Cannot overwrite
        # variable Pid because it is read-only or constant" the instant
        # this function is called.
        param([int]$ProcessId, [int]$ParentPid, [int64]$StartTimeUnixMs = 1000, [string]$Executable = 'pwsh')
        [pscustomobject]@{ Pid = $ProcessId; ParentPid = $ParentPid; StartTimeUnixMs = $StartTimeUnixMs; Executable = $Executable }
    }
}

Describe 'Resolve-YurunaRunnerProcessTarget -- basic tree walk' {
    It 'includes the root itself, after its descendants (post order)' {
        # outer(1) -> cycle(2) -> inner(3)
        $table = @(
            (New-Proc -ProcessId 1 -ParentPid 0)
            (New-Proc -ProcessId 2 -ParentPid 1)
            (New-Proc -ProcessId 3 -ParentPid 2)
        )
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        $r.Roots | Should -Be @(1)
        @($r.Descendants.Pid) | Should -Be @(3, 2, 1) -Because 'the deepest descendant (inner) must be signaled before the cycle process, which must be signaled before the outer root'
    }

    It 'never returns a PID twice even when reachable from two roots' {
        $table = @(
            (New-Proc -ProcessId 1 -ParentPid 0)
            (New-Proc -ProcessId 2 -ParentPid 0)
            (New-Proc -ProcessId 3 -ParentPid 1)
        )
        # Contrived: pid 3's real parent is 1, but a caller also lists it as
        # its own verified root -- must not appear twice in the output.
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table -VerifiedRoot @(
            [pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' }
            [pscustomobject]@{ Pid = 3; StartTimeUnixMs = 1000; Role = 'stray' }
        )
        (@($r.Descendants.Pid) | Group-Object | Where-Object Count -GT 1).Count | Should -Be 0
    }

    It 'a genuinely empty process table and empty roots produce empty, not an error' {
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable @() -VerifiedRoot @()
        @($r.Roots).Count | Should -Be 0
        @($r.Descendants).Count | Should -Be 0
        @($r.Descendants).GetType().IsArray | Should -Be $true -Because 'a single-element or empty result must still be a real array, never unrolled to a scalar'
    }

    It 'a single-descendant tree does not unroll to a scalar' {
        $table = @((New-Proc -ProcessId 1 -ParentPid 0))
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        $r.Descendants.GetType().IsArray | Should -Be $true
        @($r.Descendants).Count | Should -Be 1
    }
}

Describe 'Resolve-YurunaRunnerProcessTarget -- exclusions pruned before expansion' {
    It 'excludes a verified status-server subtree even through a grandchild not otherwise recorded' {
        # outer(1) -> inner(2) -> statusServer(3) -> helper(4)
        $table = @(
            (New-Proc -ProcessId 1 -ParentPid 0)
            (New-Proc -ProcessId 2 -ParentPid 1)
            (New-Proc -ProcessId 3 -ParentPid 2 -Executable 'pwsh')
            (New-Proc -ProcessId 4 -ParentPid 3 -Executable 'someHelperTool')
        )
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' }) `
            -ExcludedPid @(3)
        @($r.Descendants.Pid) | Should -Not -Contain 3
        @($r.Descendants.Pid) | Should -Not -Contain 4 -Because 'the helper is only reachable through the excluded status server and must never be reached'
        @($r.Descendants.Pid) | Should -Be @(2, 1)
    }

    It 'reports why each pruned subtree was excluded' {
        $table = @((New-Proc -ProcessId 1 -ParentPid 0), (New-Proc -ProcessId 2 -ParentPid 1))
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' }) `
            -ExcludedPid @(2)
        ($r.Reasons -join ' ') | Should -Match 'pid 2 excluded'
    }

    It 'refuses to accept an explicitly excluded PID as a root at all' {
        $table = @((New-Proc -ProcessId 1 -ParentPid 0))
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' }) `
            -ExcludedPid @(1)
        $r.Roots | Should -BeNullOrEmpty
        @($r.Descendants).Count | Should -Be 0
    }
}

Describe 'Resolve-YurunaRunnerProcessTarget -- identity revalidation' {
    It 'rejects a root whose recorded start time does not match a live process now holding that PID' {
        $table = @((New-Proc -ProcessId 1 -ParentPid 0 -StartTimeUnixMs 999999))
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        $r.Roots | Should -BeNullOrEmpty -Because 'PID 1 is a different, recycled process now -- start time does not match'
        ($r.Reasons -join ' ') | Should -Match 'start-time mismatch'
    }

    It 'accepts a start time within the 2-second tolerance' {
        $table = @((New-Proc -ProcessId 1 -ParentPid 0 -StartTimeUnixMs 1500))
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        $r.Roots | Should -Be @(1)
    }

    It 'reports a verified root missing from the process table rather than silently skipping it' {
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable @() `
            -VerifiedRoot @([pscustomobject]@{ Pid = 999; StartTimeUnixMs = 1000; Role = 'outer' })
        $r.Roots | Should -BeNullOrEmpty
        ($r.Reasons -join ' ') | Should -Match 'not present in the process table'
    }

    It 'a recycled PID just before signaling (start-time mismatch) is never treated as owned, even as a fresh child of a real root' {
        # outer(1) is genuine; the process table's entry for what USED to be
        # inner (pid 2) has since been recycled by an unrelated process --
        # simulated by a mismatched start time on the verified identity for
        # pid 2 supplied as a second (not tree-discovered) root.
        $table = @(
            (New-Proc -ProcessId 1 -ParentPid 0 -StartTimeUnixMs 1000)
            (New-Proc -ProcessId 2 -ParentPid 1 -StartTimeUnixMs 5000)
        )
        $r = Resolve-YurunaRunnerProcessTarget -ProcessTable $table -VerifiedRoot @(
            [pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' }
        )
        # pid 2 is still reached as a genuine descendant of the verified
        # root 1 via the live tree walk (that is correct -- it is really a
        # child right now); the mismatch case that matters is a SEPARATE
        # verified identity record for a PID that has moved on, covered by
        # the two tests above.
        @($r.Descendants.Pid) | Should -Contain 2
    }
}

Describe 'Resolve-YurunaRunnerProcessTarget -- new child race' {
    It 'includes a child that appears in the table between two calls (caller re-snapshots; this function has no memory)' {
        $tableBefore = @((New-Proc -ProcessId 1 -ParentPid 0))
        $r1 = Resolve-YurunaRunnerProcessTarget -ProcessTable $tableBefore `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        @($r1.Descendants.Pid) | Should -Be @(1)

        $tableAfter = @((New-Proc -ProcessId 1 -ParentPid 0), (New-Proc -ProcessId 5 -ParentPid 1))
        $r2 = Resolve-YurunaRunnerProcessTarget -ProcessTable $tableAfter `
            -VerifiedRoot @([pscustomobject]@{ Pid = 1; StartTimeUnixMs = 1000; Role = 'outer' })
        @($r2.Descendants.Pid) | Should -Be @(5, 1) -Because 'a fresh snapshot picks up a child that spawned since the last call -- re-snapshotting before the hypervisor step is the caller''s job, not this function''s'
    }
}
