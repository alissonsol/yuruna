<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42b063c4-f3bc-4a1f-885e-8a2c257e7130
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
    runtime/host.registration.json the pool-aggregator service reads (Phase 0 of the
    multi-host pool harness, docs/opportunities.md).
.DESCRIPTION
    Throw-based assertions (Pester 5+). The fixture points
    $env:YURUNA_RUNTIME_DIR at a temp dir and seeds the $global:__Yuruna* identity
    channels the writer reads; all $global: access is confined to suppressed
    helpers (matching the production Copy-FailureArtifactsToStatusLog pattern).
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Capability.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The fixture pair lives at file scope, not inside the Describe: a Describe body is
# executed during test discovery and everything it declares -- functions included -- is
# discarded before any It runs, so a Describe-local New-RegFixture would be unresolvable
# at the moment the It calls it.
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

}

Describe 'Write-HostRegistrationRecord' {

    It 'publishes project origin without embedded credentials' -TestCases @(
        @{ Remote = 'https://fixture-user:PRIVATE_FIXTURE_TOKEN@example.invalid/owner/project.git' }
        @{ Remote = 'ssh://fixture-user:PRIVATE_FIXTURE_TOKEN@example.invalid/owner/project.git' }
    ) {
        param($Remote)
        $fx = New-RegFixture
        try {
            $runtime = Join-Path $fx.Tmp 'runtime'
            $project = Join-Path $fx.Tmp 'project'
            $null = New-Item -ItemType Directory -Path $runtime, $project
            $env:YURUNA_RUNTIME_DIR = $runtime
            & git -C $project init --quiet
            & git -C $project remote add origin $Remote
            $path = Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp
            Assert-NotNull $path
            $json = [IO.File]::ReadAllText($path)
            Assert-False ($json -match 'PRIVATE_FIXTURE_TOKEN|fixture-user') 'registration cannot publish credentials'
            Assert-StringEqual 'https://example.invalid/owner/project' ($json | ConvertFrom-Json).projectUrl
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'writes host.registration.json with identity, capabilities, and reserved fields' {
        $fx = New-RegFixture
        try {
            $path = Write-HostRegistrationRecord -HostType 'host.windows.hyper-v' -RepoRoot $fx.Tmp
            Assert-True ($null -ne $path) 'returns the written path'
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-Equal -Expected 1 -Actual $rec.schemaVersion -Because 'schemaVersion'
            Assert-Equal -Expected ('42' + ('b' * 30)) -Actual $rec.hostId -Because 'hostId from the process global'
            Assert-Equal -Expected 'host.windows.hyper-v' -Actual $rec.hostType -Because 'hostType passthrough'
            Assert-Equal -Expected 'hyper-v' -Actual $rec.hypervisor -Because 'hypervisor derived from hostType'
            Assert-True ($null -ne $rec.capabilities) 'capabilities block present'
            Assert-Equal -Expected 'host.windows.hyper-v' -Actual $rec.capabilities.hostType -Because 'capabilities carries hostType'
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
            Assert-Equal -Expected 'kvm' -Actual $kvm -Because 'host.ubuntu.kvm -> kvm'
            [void](Write-HostRegistrationRecord -HostType 'host.macos.utm' -RepoRoot $fx.Tmp)
            $utm = (Get-Content -Raw $regPath | ConvertFrom-Json).hypervisor
            Assert-Equal -Expected 'utm' -Actual $utm -Because 'host.macos.utm -> utm'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'publishes the project facts and the access marker, and no other project data' {
        $fx = New-RegFixture
        try {
            $root = Join-Path $fx.Tmp 'checkout'
            $runtimeDir = Join-Path $root 'runtime/host'
            $projectDir = Join-Path $root 'runtime/project'
            New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $projectDir 'test') -Force | Out-Null
            $env:YURUNA_RUNTIME_DIR = $runtimeDir
            [IO.File]::WriteAllText((Join-Path $projectDir 'test/test.runner.yml'), "sequences: [workload.example]`n",
                [Text.UTF8Encoding]::new($false))
            & git -C $projectDir init --quiet
            & git -C $projectDir remote add origin 'https://example.invalid/owner/project.git'
            & git -C $projectDir -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false `
                commit --allow-empty --quiet --no-verify -m fixture
            $expectedCommit = "$(& git -C $projectDir rev-parse --short HEAD)".Trim()
            $access = [ordered]@{ url = 'https://example.invalid/owner/project'; status = 'denied'
                assignedBy = [ordered]@{ poolId = 'lab' }; checkedAt = '2026-01-01T00:00:00Z'; detail = 'fixture' }
            [IO.File]::WriteAllText((Join-Path $runtimeDir 'project.access.json'), ($access | ConvertTo-Json -Depth 4),
                [Text.UTF8Encoding]::new($false))

            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $runtimeDir 'host.registration.json') | ConvertFrom-Json
            Assert-StringEqual -Expected 'https://example.invalid/owner/project' -Actual $rec.projectUrl `
                'the registration lost the project origin'
            Assert-StringEqual -Expected $expectedCommit -Actual $rec.projectCommit `
                'the registration lost the project commit'
            Assert-StringEqual -Expected 'denied' -Actual $rec.projectAccess.status `
                'the registration lost the access probe result'
            Assert-StringEqual -Expected 'poolId' -Actual (@($rec.projectAccess.assignedBy.PSObject.Properties.Name) -join ',') `
                'assignedBy names the pool and nothing else'
            $names = [string[]]@($rec.PSObject.Properties.Name)
            [Array]::Sort($names, [StringComparer]::Ordinal)
            Assert-StringEqual -Expected ('activeExtensions,capabilities,capacity,disk,extensionTargets,gating,hostId,hostType,' +
                    'hostname,hypervisor,ipPool,network,pid,poolGuid,poolId,projectAccess,projectCommit,projectUrl,' +
                    'runId,schemaVersion,statusPort,supportedGuests,writtenAtUtc') `
                -Actual ($names -join ',') 'the registration record gained or lost a top-level field'
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
                gating = [ordered]@{ failuresBeforeAlert = 3; quorum = [ordered]@{ healthyThreshold = 0.5; degradedAfterSeconds = 1800 } } }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'pool.state.json'), ($state | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-Equal -Expected 'lab' -Actual $rec.poolId -Because 'poolId carried'
            Assert-Equal -Expected 3 -Actual $rec.gating.failuresBeforeAlert -Because 'gating.failuresBeforeAlert carried'
            Assert-Equal -Expected 0.5 -Actual $rec.gating.quorum.healthyThreshold -Because 'gating.quorum.healthyThreshold carried'
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

    It 'folds an active stash-service marker into activeExtensions + extensionTargets' {
        $fx = New-RegFixture
        try {
            $marker = [ordered]@{ active = $true; vmName = 'yuruna-stash-service';
                hostType = 'host.windows.hyper-v'; stashBaseUrl = 'http://10.0.0.5' }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'stash-service.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.windows.hyper-v' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-True ($rec.activeExtensions -contains 'stash-service') 'activeExtensions carries stash-service'
            Assert-Equal -Expected 'http://10.0.0.5' -Actual $rec.extensionTargets.'stash-service' -Because 'extensionTargets carries the advertised stash URL'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'does not advertise a torn-down stash marker (active:false)' {
        $fx = New-RegFixture
        try {
            $marker = [ordered]@{ active = $false; vmName = 'yuruna-stash-service';
                hostType = 'host.windows.hyper-v'; stashBaseUrl = 'http://10.0.0.5' }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'stash-service.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.windows.hyper-v' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-True (-not ($rec.activeExtensions -contains 'stash-service')) 'active:false marker is not advertised'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'folds an active download-agent-service marker into activeExtensions + extensionTargets' {
        $fx = New-RegFixture
        try {
            $marker = [ordered]@{ active = $true; vmName = 'yuruna-download-agent-service';
                hostType = 'host.ubuntu.kvm'; downloadAgentServiceBaseUrl = 'http://10.0.0.9' }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'download-agent-service.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-True ($rec.activeExtensions -contains 'download-agent-service') 'activeExtensions carries download-agent-service'
            Assert-Equal -Expected 'http://10.0.0.9' -Actual $rec.extensionTargets.'download-agent-service' -Because 'extensionTargets carries the advertised agent URL'
        } finally { Remove-RegFixture -Fixture $fx }
    }

    It 'does not advertise a torn-down download-agent marker (active:false)' {
        $fx = New-RegFixture
        try {
            $marker = [ordered]@{ active = $false; vmName = 'yuruna-download-agent-service';
                hostType = 'host.ubuntu.kvm'; downloadAgentServiceBaseUrl = 'http://10.0.0.9' }
            [System.IO.File]::WriteAllText((Join-Path $fx.Tmp 'download-agent-service.json'), ($marker | ConvertTo-Json), [System.Text.UTF8Encoding]::new($false))
            [void](Write-HostRegistrationRecord -HostType 'host.ubuntu.kvm' -RepoRoot $fx.Tmp)
            $rec = Get-Content -Raw (Join-Path $fx.Tmp 'host.registration.json') | ConvertFrom-Json
            Assert-True (-not ($rec.activeExtensions -contains 'download-agent-service')) 'active:false marker is not advertised'
        } finally { Remove-RegFixture -Fixture $fx }
    }
}
