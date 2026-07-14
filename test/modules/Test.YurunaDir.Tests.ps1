<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42a1c8e7-5b34-4d29-9f06-1e7d3a2b4c58
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
    multi-host pool harness, docs/opportunities-hostpool.md).
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). Each case points
    $env:YURUNA_RUNTIME_DIR at a fresh temp dir (an env var, not a $global:, so
    no cross-module channel is touched) and restores it after.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

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
