<#PSScriptInfo
.VERSION 2026.06.12
.GUID 42b6d9f1-3c75-4e82-a0d4-6f8b1c2e3a49
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostpool capability registration pester
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
    Pester coverage for Write-HostRegistrationRecord (Test.Capability.psm1): the
    runtime/host.registration.json the pool aggregator reads (Phase 0 of the
    multi-host pool harness, docs/opportunities-hostpool.md).
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). The fixture points
    $env:YURUNA_RUNTIME_DIR at a temp dir and seeds the $global:__Yuruna* identity
    channels the writer reads; all $global: access is confined to suppressed
    helpers (matching the production Copy-FailureArtifactsToStatusLog pattern).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Capability.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Write-HostRegistrationRecord' {

    function New-RegFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test must seed/save the $global:__Yuruna* identity channels the writer reads.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: temp dir + seeds globals/env; no production state.')]
        [OutputType([hashtable])]
        param()
        $saved = @{ HostId = $global:__YurunaHostId; RunId = $global:__YurunaRunId; RuntimeDir = $env:YURUNA_RUNTIME_DIR }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('yrn-reg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $env:YURUNA_RUNTIME_DIR = $tmp
        $global:__YurunaHostId = '42' + ('b' * 30)
        $global:__YurunaRunId  = [guid]::NewGuid().ToString()
        return @{ Tmp = $tmp; Saved = $saved }
    }

    function Remove-RegFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
            Justification = 'Test teardown: restores the $global:__Yuruna* channels it saved.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test teardown: restores saved globals/env + removes the temp dir.')]
        param([Parameter(Mandatory)][hashtable]$Fixture)
        $global:__YurunaHostId  = $Fixture.Saved.HostId
        $global:__YurunaRunId   = $Fixture.Saved.RunId
        $env:YURUNA_RUNTIME_DIR = $Fixture.Saved.RuntimeDir
        Remove-Item -LiteralPath $Fixture.Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'writes host.registration.json with identity, capabilities, and reserved fields' {
        $fx = New-RegFixture
        try {
            $path = Write-HostRegistrationRecord -HostType 'host.windows.hyper-v' -RepoRoot $fx.Tmp
            Assert-True ($null -ne $path) 'returns the written path'
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-Equal 1 $rec.schemaVersion 'schemaVersion'
            Assert-Equal ('42' + ('b' * 30)) $rec.hostId 'hostId from the process global'
            Assert-Equal 'host.windows.hyper-v' $rec.hostType 'hostType passthrough'
            Assert-Equal 'hyper-v' $rec.hypervisor 'hypervisor derived from hostType'
            Assert-True ($null -ne $rec.capabilities) 'capabilities block present'
            Assert-Equal 'host.windows.hyper-v' $rec.capabilities.hostType 'capabilities carries hostType'
            # Reserved Horizon-B / planner fields exist (as null) so consumers can rely on the shape.
            foreach ($f in 'capacity','ipPool','disk','supportedGuests') {
                Assert-True ($rec.PSObject.Properties.Name -contains $f) "reserved field present: $f"
            }
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'derives the hypervisor short-name for each platform' {
        $fx = New-RegFixture
        try {
            $regPath = Join-Path $fx.Tmp 'host.registration.json'
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $kvm = (Get-Content -Raw $regPath | ConvertFrom-Json).hypervisor
            Assert-Equal 'kvm' $kvm 'host.ubuntu.kvm -> kvm'
            [void](Write-HostRegistrationRecord -HostType 'host.macos.utm' -RepoRoot $fx.Tmp)
            $utm = (Get-Content -Raw $regPath | ConvertFrom-Json).hypervisor
            Assert-Equal 'utm' $utm 'host.macos.utm -> utm'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'returns null without throwing when the runtime dir is unset' {
        $fx = New-RegFixture
        try {
            $env:YURUNA_RUNTIME_DIR = ''
            $r = Write-HostRegistrationRecord -HostType 'host.windows.hyper-v' -RepoRoot $fx.Tmp
            Assert-True ($null -eq $r) 'best-effort: returns null, no throw, when runtime dir is unset'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'carries poolId + gating from pool.state.json into the record (the gating consumer leg)' {
        $fx = New-RegFixture
        try {
            # The runner derives these into pool.state.json; the registration writer forwards
            # them so the aggregator gets the gating policy without parsing pools.yml.
            $state = [ordered]@{ poolId = 'lab'; desiredState = 'run'; intentOk = $true;
                gating = [ordered]@{ failuresBeforeAlert = 3; quorum = [ordered]@{ healthyThreshold = 0.5; degradedAfterMinutes = 30 } } }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'pool.state.json'), ($state | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-Equal 'lab' $rec.poolId 'poolId carried'
            Assert-Equal 3 $rec.gating.failuresBeforeAlert 'gating.failuresBeforeAlert carried'
            Assert-Equal 0.5 $rec.gating.quorum.healthyThreshold 'gating.quorum.healthyThreshold carried'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'writes a null gating when pool.state.json has none' {
        $fx = New-RegFixture
        try {
            $state = [ordered]@{ poolId = 'lab'; desiredState = 'run'; intentOk = $true }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'pool.state.json'), ($state | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-True ($null -eq $rec.gating) 'gating null when pool.state.json carries none'
        } finally { Remove-RegFixture -Fixture $fx }
    }
}
