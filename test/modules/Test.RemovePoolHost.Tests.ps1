<#PSScriptInfo
.VERSION 2026.07.24
.GUID 42b8d1f3-6a4c-4e29-9b57-0d3e2f6a8c15
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool admin gc pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Functional Pester coverage for test/Remove-PoolHost.ps1: it deletes a stale
    host's NAS records (identity + replicated cycles) resolved from
    test.config.yml, refuses a recently-seen record without -Force, and rejects a
    malformed hostId.
.DESCRIPTION
    Each case builds a throwaway pool share + a -ConfigPath fixture pointing at
    it, runs the script in a child pwsh, and asserts exit code + on-disk state.
    The recency case guards the specific regression where the guard's terminating
    Write-Error was swallowed by the parse try/catch. Membership (intent store) is
    not exercised here -- the fixture config has no pool.intentGitUrl, so the
    script takes the storage-only path. Throw-based assertions (Pester 4.10.1 /
    5+); runs the script as a child so its `exit` codes are observable.
#>

$here = Split-Path -Parent $PSCommandPath
$rph  = Join-Path (Split-Path -Parent $here) 'Remove-PoolHost.ps1'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected', got '$Actual'. $Because" } }

function New-RphFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway pool tree the calling It block deletes in its finally.')]
    param([string]$LastSeenUtc = '2020-01-01T00:00:00Z')
    $id       = '42cafe0000000000000000000000dead'
    $tmp      = Join-Path ([System.IO.Path]::GetTempPath()) ("rph_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $pool     = Join-Path $tmp 'pool'
    $hostsDir = Join-Path $pool 'hosts'
    $cycleDir = Join-Path $pool $id
    New-Item -ItemType Directory -Force -Path (Join-Path $cycleDir 'cycle1') | Out-Null
    New-Item -ItemType Directory -Force -Path $hostsDir | Out-Null
    Set-Content (Join-Path $cycleDir 'cycle1/manifest.json') '{}'
    $infoFile = Join-Path $hostsDir "info.$id.yml"
    Set-Content $infoFile "hostUuid: $id`nlastSeenUtc: '$LastSeenUtc'`nhardware: {}`n"
    $cfgDir  = Join-Path $tmp 'test'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfgPath = Join-Path $cfgDir 'test.config.yml'
    # single-quoted YAML scalar keeps the Windows backslashes literal
    Set-Content $cfgPath "networkStorage:`n  poolNetworkPath: '//fake/pool'`n  poolNetworkUser: 'fakeuser'`n  poolLocalPath: '$pool'`npool:`n  networkReplicate: false`n"
    return [pscustomobject]@{ Tmp = $tmp; Id = $id; InfoFile = $infoFile; CycleDir = $cycleDir; CfgPath = $cfgPath }
}

Describe 'Remove-PoolHost' {
    It 'deletes a stale identity record and its replicated cycle folder' {
        $f = New-RphFixture
        try {
            & pwsh -NoProfile -File $rph -HostId $f.Id -ConfigPath $f.CfgPath *> $null
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because 'stale removal exits 0'
            Assert-True (-not (Test-Path -LiteralPath $f.InfoFile)) 'the identity record is deleted'
            Assert-True (-not (Test-Path -LiteralPath $f.CycleDir)) 'the replicated cycle folder is deleted'
        } finally { Remove-Item -Recurse -Force -LiteralPath $f.Tmp -ErrorAction SilentlyContinue }
    }

    It 'rejects a malformed hostId with a non-zero exit' {
        $f = New-RphFixture
        try {
            & pwsh -NoProfile -File $rph -HostId 'not-a-uuid' -ConfigPath $f.CfgPath *> $null
            Assert-True ($LASTEXITCODE -ne 0) 'a bad hostId fails'
            Assert-True (Test-Path -LiteralPath $f.InfoFile) 'nothing is deleted on a bad id'
        } finally { Remove-Item -Recurse -Force -LiteralPath $f.Tmp -ErrorAction SilentlyContinue }
    }

    It 'refuses a recently-seen record without -Force, then deletes it with -Force' {
        $f = New-RphFixture -LastSeenUtc ([datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"))
        try {
            & pwsh -NoProfile -File $rph -HostId $f.Id -ConfigPath $f.CfgPath *> $null
            Assert-True ($LASTEXITCODE -ne 0) 'a record seen < 24h ago is refused without -Force'
            Assert-True (Test-Path -LiteralPath $f.InfoFile) 'the record survives the refusal'
            & pwsh -NoProfile -File $rph -HostId $f.Id -ConfigPath $f.CfgPath -Force *> $null
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because '-Force overrides the recency guard'
            Assert-True (-not (Test-Path -LiteralPath $f.InfoFile)) 'the record is deleted with -Force'
        } finally { Remove-Item -Recurse -Force -LiteralPath $f.Tmp -ErrorAction SilentlyContinue }
    }

    It 'is idempotent when the host has no records' {
        $f = New-RphFixture
        try {
            Remove-Item -Recurse -Force -LiteralPath (Split-Path -Parent $f.InfoFile) -ErrorAction SilentlyContinue
            Remove-Item -Recurse -Force -LiteralPath $f.CycleDir -ErrorAction SilentlyContinue
            & pwsh -NoProfile -File $rph -HostId $f.Id -ConfigPath $f.CfgPath *> $null
            Assert-Equal -Expected 0 -Actual $LASTEXITCODE -Because 'a no-op removal still succeeds'
        } finally { Remove-Item -Recurse -Force -LiteralPath $f.Tmp -ErrorAction SilentlyContinue }
    }
}
