<#PSScriptInfo
.VERSION 2026.09.13
.GUID 42b4865f-6a1d-415a-a630-1e2183bca862
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostpool identity pester
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
    Pester coverage for Get-YurunaHostId (Test.YurunaDir.psm1): the stable
    per-host pool identity persisted in runtime/host.uuid (Phase 0 of the
    multi-host pool harness, docs/opportunities.md).
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). Each case points
    $env:YURUNA_RUNTIME_DIR at a fresh temp dir (an env var, not a $global:, so
    no cross-module channel is touched) and restores it after.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The fixture helpers live at file scope, above the first Describe. A Describe
# body is evaluated during the discovery pass and its scope is torn down before
# any It runs, so a function (or variable) declared inside one is gone by the
# time the It bodies execute; only file-level declarations that precede the
# first Describe are still in scope during the run pass.
function New-RuntimeFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp dir + repoints the runtime env var; no production state.')]
    [OutputType([hashtable])]
    param()
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-hostid-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $prev = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = $tmp
    return @{ Tmp = $tmp; Prev = $prev }
}

function Remove-RuntimeFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test teardown: restores the env var + removes the temp dir.')]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    $env:YURUNA_RUNTIME_DIR = $Fixture.Prev
    Remove-Item -LiteralPath $Fixture.Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

}

Describe 'Get-YurunaHostId' {

    It 'generates a 42-prefixed 32-char id and persists it to host.uuid' {
        $fx = New-RuntimeFixture
        try {
            $id = Get-YurunaHostId
            Assert-True ($id -match '^42[0-9a-fA-F]{30}$') "id shape: $id"
            $onDisk = ([System.IO.File]::ReadAllText((Join-Path $fx.Tmp 'host.uuid'))).Trim()
            Assert-Equal -Expected $id -Actual $onDisk -Because 'persisted value matches the returned id'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }

    It 'is stable: a second call returns the same persisted id' {
        $fx = New-RuntimeFixture
        try {
            $a = Get-YurunaHostId
            $b = Get-YurunaHostId
            Assert-Equal -Expected $a -Actual $b -Because 'host id is stable across calls'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }

    It 'reuses an existing host.uuid rather than regenerating' {
        $fx = New-RuntimeFixture
        try {
            $seed = '42' + ('a' * 30)
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'host.uuid'), $seed, [System.Text.UTF8Encoding]::new($false))
            Assert-Equal -Expected $seed -Actual (Get-YurunaHostId) -Because 'reads the existing file, does not regenerate'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }
}

Describe 'Format-YurunaHostId (the spelling a full id is shown in)' {

    It 'renders a minted id 8-4-4-4-12' {
        $fx = New-RuntimeFixture
        try {
            $id = Get-YurunaHostId
            $shown = Format-YurunaHostId -HostId $id
            Assert-True ($shown -match '^42[0-9a-f]{6}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') "shown: $shown"
            Assert-Equal -Expected $id -Actual ($shown -replace '-', '') -Because 'the dashes are the only difference from the stored key'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }

    It 'passes through anything that is not a 32-hex id' {
        # A pool GUID already carries its dashes and an opaque service id is not
        # this function's to reinterpret; both must survive a render untouched, or
        # a caller that renders every id it shows would corrupt them.
        foreach ($v in @('42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071', 'stash-vm-01', '4253419c', '')) {
            Assert-Equal -Expected $v -Actual (Format-YurunaHostId -HostId $v) -Because "passes through [$v]"
        }
    }

    It 'round-trips through the operator-input normalizer' {
        # The pair is what makes an id readable on a panel and usable in a command:
        # what Format shows must be what ConvertTo accepts, or a pasted id is refused.
        Import-Module (Join-Path $here 'Test.PoolAdmin.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        $id = '42abcdef0123456789abcdef01234567'
        Assert-Equal -Expected $id -Actual (ConvertTo-YurunaHostId -Value (Format-YurunaHostId -HostId $id)) -Because 'shown form is accepted back'
    }
}

Describe 'Get-YurunaHostId keys a host on its hardware, not on chance' {

    It 'derives the id its hardware implies rather than a random one' {
        # A host mints its id into the runtime dir, so anything that takes that
        # dir away -- a reimage, a re-clone, a wiped checkout -- used to leave
        # the machine inventing a fresh identity. Its pool history then forked:
        # the aggregator and the scan list both key hosts by id, so one machine
        # occupied a row per id it had ever had, and pool membership stayed on
        # the id that went quiet.
        $seed = ''
        try {
            Import-Module (Join-Path $here 'Test.HostIdentity.psm1') -Force -DisableNameChecking -ErrorAction Stop
            $seed = [string](Get-HostIdentitySeedUuid -AllowSudo)
        } catch { Set-ItResult -Skipped -Because "Test.HostIdentity did not load: $($_.Exception.Message)" }
        if (-not $seed) {
            Set-ItResult -Skipped -Because 'no stable hardware key is readable here, so this host is keyed at random by design'
        }
        $fx = New-RuntimeFixture
        try {
            Assert-Equal $seed (Get-YurunaHostId) 'a fresh runtime dir did not adopt the hardware-derived id'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }

    It 'gives the same host the same id across two independent runtime dirs' {
        # This is the whole point stated as a test: two fresh runtime dirs on one
        # machine are what a reimage looks like from here, and they must not
        # yield two identities.
        $first = $null
        $fx = New-RuntimeFixture
        try { $first = Get-YurunaHostId } finally { Remove-RuntimeFixture -Fixture $fx }
        $second = $null
        $fx = New-RuntimeFixture
        try { $second = Get-YurunaHostId } finally { Remove-RuntimeFixture -Fixture $fx }
        if (-not $first) { Set-ItResult -Skipped -Because 'the runtime dir was unwritable, so no id could be persisted' }
        # Where no hardware key is readable the id IS random, and saying so is
        # more honest than asserting a stability this host cannot offer.
        Import-Module (Join-Path $here 'Test.HostIdentity.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not (Get-HostIdentitySeedUuid -AllowSudo)) {
            Set-ItResult -Skipped -Because 'no stable hardware key is readable here, so this host is keyed at random by design'
        }
        Assert-Equal $first $second 'one machine produced two identities from two fresh runtime dirs'
    }

    It 'still adopts a persisted host.uuid ahead of anything it could derive' {
        # An existing host must never be re-keyed by this: the file on disk is
        # the identity the pool, the NAS folders and every log line already use.
        $fx = New-RuntimeFixture
        try {
            $existing = '42deadbeefdeadbeefdeadbeefdeadb'
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'host.uuid'), $existing)
            Assert-Equal $existing (Get-YurunaHostId) 'a persisted id was not adopted'
        } finally { Remove-RuntimeFixture -Fixture $fx }
    }

    It 'honors the escape hatch for an operator who means to re-key' {
        # Deriving from hardware would otherwise hand back the very id the
        # removed runtime dir had, taking away the deliberate re-key that
        # removing that dir used to be.
        $prevSeed = $env:YURUNA_HOST_ID_SEED
        $env:YURUNA_HOST_ID_SEED = 'random'
        $ids = @()
        try {
            foreach ($i in 1..2) {
                $fx = New-RuntimeFixture
                try { $ids += [string](Get-YurunaHostId) } finally { Remove-RuntimeFixture -Fixture $fx }
            }
        } finally { $env:YURUNA_HOST_ID_SEED = $prevSeed }
        foreach ($id in $ids) { Assert-True ($id -match '^42[0-9a-fA-F]{30}$') "id shape under the override: $id" }
        Assert-True ($ids[0] -cne $ids[1]) 'the random override returned one id twice'
    }

    It 'agrees with the other function that creates host.uuid' {
        # Test.Perf's Get-PerfHostUuid writes the SAME file, and either can be
        # the one that wins the first-use race. A machine whose identity
        # depended on which got there first would be exactly the forked identity
        # the derivation exists to prevent, so the two must agree.
        try {
            Import-Module (Join-Path $here 'Test.Perf.psm1') -Force -DisableNameChecking -ErrorAction Stop
        } catch { Set-ItResult -Skipped -Because "Test.Perf did not load: $($_.Exception.Message)" }
        $fromDir = $null
        $fx = New-RuntimeFixture
        try { $fromDir = Get-YurunaHostId } finally { Remove-RuntimeFixture -Fixture $fx }
        $fromPerf = $null
        $fx = New-RuntimeFixture
        try { $fromPerf = Get-PerfHostUuid } finally { Remove-RuntimeFixture -Fixture $fx }
        Import-Module (Join-Path $here 'Test.HostIdentity.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
        if (-not (Get-HostIdentitySeedUuid -AllowSudo)) {
            Set-ItResult -Skipped -Because 'no stable hardware key is readable here, so both functions key at random by design'
        }
        Assert-Equal $fromDir $fromPerf 'the two creators of host.uuid derived different ids for one machine'
    }
}
