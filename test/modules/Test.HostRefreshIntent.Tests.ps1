<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42e5f6a7-8b9c-4d0e-af1a-2b3c4d5e6f7a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh request intent pester
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
    Confirm-HostRefreshIntent's request state machine: new/retry/policy-
    mismatch/active-collision/abandoned-after-three-attempts, against a real
    file on disk (not mocked) since the write path (atomic temp+move) is
    part of what this verifies.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.HostRefreshIntent.psm1') -Force -DisableNameChecking
    $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("yrn-hri-" + [Guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Confirm-HostRefreshIntent -- new request' {
    It 'accepts a brand-new request id with no prior journal' {
        $path = Join-Path $script:TmpDir 'r1.json'
        $id = New-YurunaHostRefreshRequestId
        $r = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'restart' }
        $r.Accepted | Should -Be $true
        $r.Reason   | Should -Be 'accepted-new'
        $r.Request.State   | Should -Be 'running'
        $r.Request.Attempt | Should -Be 1
    }

    It 'persists the request to disk so a fresh read sees it' {
        $path = Join-Path $script:TmpDir 'r2.json'
        $id = New-YurunaHostRefreshRequestId
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'restart' }
        $reread = Read-YurunaHostRefreshRequest -Path $path
        $reread.RequestId | Should -Be $id
    }
}

Describe 'Confirm-HostRefreshIntent -- retry of the same request' {
    It 'increments Attempt and keeps the same RequestId when Policy matches exactly' {
        $path = Join-Path $script:TmpDir 'r3.json'
        $id = New-YurunaHostRefreshRequestId
        $policy = @{ Tier = 'restart'; MaxRung = 2 }
        $null   = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy
        $second = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy
        $second.Accepted | Should -Be $true
        $second.Reason   | Should -Be 'accepted-retry'
        $second.Request.Attempt | Should -Be 2
        $second.Request.RequestId | Should -Be $id
    }

    It 'refuses and marks abandoned after three attempts' {
        $path = Join-Path $script:TmpDir 'r4.json'
        $id = New-YurunaHostRefreshRequestId
        $policy = @{ Tier = 'restart' }
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy   # attempt 1
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy   # attempt 2
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy   # attempt 3
        $fourth = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy $policy # attempt 4 -- refused
        $fourth.Accepted | Should -Be $false
        $fourth.Reason   | Should -Be 'refused-terminal-no-retry'
        $fourth.Request.State | Should -Be 'abandoned'
    }
}

Describe 'Confirm-HostRefreshIntent -- immutable policy' {
    It 'refuses a retry whose policy differs from the originally recorded one, even mid-run' {
        $path = Join-Path $script:TmpDir 'r5.json'
        $id = New-YurunaHostRefreshRequestId
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'restart' }
        $changed = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'full' }
        $changed.Accepted | Should -Be $false
        $changed.Reason   | Should -Be 'refused-policy-mismatch'
    }

    It 'refuses a policy change even after the request completed' {
        $path = Join-Path $script:TmpDir 'r6.json'
        $id = New-YurunaHostRefreshRequestId
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'restart' }
        $null = Complete-YurunaHostRefreshRequest -RequestPath $path -State 'completed' -Verdict 'already-healthy' -Confirm:$false
        $changed = Confirm-HostRefreshIntent -RequestPath $path -RequestId $id -Policy @{ Tier = 'full' }
        $changed.Reason | Should -Be 'refused-policy-mismatch'
    }
}

Describe 'Confirm-HostRefreshIntent -- a different request ID while one is active' {
    It 'refuses a new request id while the existing one is still queued or running' {
        $path = Join-Path $script:TmpDir 'r7.json'
        $idA = New-YurunaHostRefreshRequestId
        $idB = New-YurunaHostRefreshRequestId
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $idA -Policy @{ Tier = 'restart' }
        $second = Confirm-HostRefreshIntent -RequestPath $path -RequestId $idB -Policy @{ Tier = 'restart' }
        $second.Accepted | Should -Be $false
        $second.Reason   | Should -Be 'refused-active-other-request'
        $second.Request.RequestId | Should -Be $idA -Because 'the active request is returned so the caller can report it, not silently swapped'
    }

    It 'admits a new request id once the prior one has completed' {
        $path = Join-Path $script:TmpDir 'r8.json'
        $idA = New-YurunaHostRefreshRequestId
        $idB = New-YurunaHostRefreshRequestId
        $null = Confirm-HostRefreshIntent -RequestPath $path -RequestId $idA -Policy @{ Tier = 'restart' }
        $null = Complete-YurunaHostRefreshRequest -RequestPath $path -State 'completed' -Verdict 'repaired' -Confirm:$false
        $second = Confirm-HostRefreshIntent -RequestPath $path -RequestId $idB -Policy @{ Tier = 'restart' }
        $second.Accepted | Should -Be $true
        $second.Reason   | Should -Be 'accepted-new'
    }
}

Describe 'Write-YurunaHostRefreshRequest -- atomic replace' {
    It 'never leaves a stray .tmp sibling after a successful write' {
        $path = Join-Path $script:TmpDir 'r9.json'
        $null = Write-YurunaHostRefreshRequest -Path $path -Request @{ RequestId = 'x' } -Confirm:$false
        $siblings = Get-ChildItem -LiteralPath $script:TmpDir -Filter 'r9.json.*.tmp' -ErrorAction SilentlyContinue
        @($siblings).Count | Should -Be 0
    }

    It 'Read-YurunaHostRefreshRequest returns $null rather than throwing for a missing file' {
        $missing = Join-Path $script:TmpDir ("missing-" + [Guid]::NewGuid().ToString('n') + '.json')
        Read-YurunaHostRefreshRequest -Path $missing | Should -BeNullOrEmpty
    }
}
