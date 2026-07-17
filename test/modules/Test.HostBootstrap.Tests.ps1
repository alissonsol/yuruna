<#PSScriptInfo
.VERSION 2026.07.17
.GUID 426cdd12-5b35-491f-813f-b70187a4d8bd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host bootstrap pester
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
    Pester coverage for Test.HostBootstrap.psm1: Initialize-YurunaHost, the
    step that imports the matching host driver into the runner's session.
.DESCRIPTION
    Every host driver here is a STUB written into a temp repo tree -- no real
    Yuruna.Host.psm1 is loaded, no VM is touched. Covered: the
    host/<short-host>/modules/Yuruna.Host.psm1 lookup for each of the three
    host types, the -Global import (the driver must be callable from the
    caller's session, not just inside the module), the HostType default via
    Get-HostType, the -Force reload of a changed driver, the hard failure
    when a driver is missing (including an unknown host type), the
    Test.VMUtility co-import, and the documented "importing this module alone
    gives the full Test.Host* surface" sibling contract.
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4
    and Pester 5+. Run: Invoke-Pester -Path test/modules/Test.HostBootstrap.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostBootstrap.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Paths only at file scope; the temp repo trees are built in BeforeAll and
# removed in AfterAll. A standalone run executes this file body twice
# (discovery, then run), so a tree built here would be created and deleted
# during discovery and every It would then import a driver that no longer
# exists. $PID is stable across the two passes.
$bootRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-hostbootstrap-tests-$PID"

# Builds <Root>/host/<short-host>/modules/Yuruna.Host.psm1 -- the layout
# Initialize-YurunaHost searches -- spelled out literally rather than through
# Get-HostFolder, so the test is an independent oracle for the path contract.
# The stub exports a marker so a test can prove WHICH driver got imported and
# that it landed in the caller's session.
function New-HostDriverStub {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$Marker
    )
    $shortHost = $HostType -replace '^host\.', ''
    $folder    = Join-Path (Join-Path (Join-Path $Root 'host') $shortHost) 'modules'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $driverPath = Join-Path $folder 'Yuruna.Host.psm1'
    Set-Content -LiteralPath $driverPath -Value @(
        "function Get-YurunaHostStubMarker { return '$Marker' }",
        'Export-ModuleMember -Function Get-YurunaHostStubMarker'
    )
    return $driverPath
}

# Same idea for the Test.VMUtility co-import: <Root>/test/modules/Test.VMUtility.psm1.
function New-VMUtilityStub {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterAll.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Marker
    )
    $folder = Join-Path (Join-Path $Root 'test') 'modules'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $stubPath = Join-Path $folder 'Test.VMUtility.psm1'
    Set-Content -LiteralPath $stubPath -Value @(
        "function Get-YurunaVMUtilityStubMarker { return '$Marker' }",
        'Export-ModuleMember -Function Get-YurunaVMUtilityStubMarker'
    )
    return $stubPath
}

function Get-ThrownMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action | Out-Null } catch { return "$($_.Exception.Message)" }
    return ''
}

Describe 'Initialize-YurunaHost' {

    BeforeAll {
        New-Item -ItemType Directory -Path $bootRoot -Force | Out-Null
    }

    AfterAll {
        Remove-Module -Name 'Yuruna.Host' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bootRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'driver resolution and import' {

        It 'imports host/<shortHost>/modules/Yuruna.Host.psm1 and returns its path' -TestCases @(
            @{ hostType = 'host.windows.hyper-v'; shortHost = 'windows.hyper-v' }
            @{ hostType = 'host.ubuntu.kvm';      shortHost = 'ubuntu.kvm' }
            @{ hostType = 'host.macos.utm';       shortHost = 'macos.utm' }
        ) {
            param($hostType, $shortHost)
            $repoRoot = Join-Path $bootRoot ("repo-" + ($shortHost -replace '\.', '-'))
            $expected = New-HostDriverStub -Root $repoRoot -HostType $hostType -Marker "driver-$shortHost"

            $returned = Initialize-YurunaHost -RepoRoot $repoRoot -HostType $hostType

            Assert-True (Test-Path -LiteralPath $returned) "the returned path must be the driver that was imported"
            Assert-Equal -Expected (Resolve-Path -LiteralPath $expected).Path -Actual (Resolve-Path -LiteralPath $returned).Path `
                -Because 'the driver lives under host/<shortHost>/modules, keyed off the HostType with the "host." prefix stripped'
            Assert-Equal -Expected "driver-$shortHost" -Actual (Get-YurunaHostStubMarker) `
                -Because 'the driver is imported -Global: every test/ caller must resolve the contract without a HostType branch'
        }

        It 'defaults HostType to Get-HostType when the parameter is omitted' {
            $currentHost = Get-HostType
            Assert-True ([bool]$currentHost) 'Get-HostType must identify this platform, or the default is meaningless'

            $repoRoot = Join-Path $bootRoot 'repo-default-hosttype'
            $expected = New-HostDriverStub -Root $repoRoot -HostType $currentHost -Marker 'driver-from-default'

            $returned = Initialize-YurunaHost -RepoRoot $repoRoot

            Assert-Equal -Expected (Resolve-Path -LiteralPath $expected).Path -Actual (Resolve-Path -LiteralPath $returned).Path
            Assert-Equal -Expected 'driver-from-default' -Actual (Get-YurunaHostStubMarker)
        }

        It 'reloads the driver when the file has changed' {
            $repoRoot = Join-Path $bootRoot 'repo-reload'
            $null = New-HostDriverStub -Root $repoRoot -HostType 'host.windows.hyper-v' -Marker 'driver-v1'
            $null = Initialize-YurunaHost -RepoRoot $repoRoot -HostType 'host.windows.hyper-v'
            Assert-Equal -Expected 'driver-v1' -Actual (Get-YurunaHostStubMarker)

            $null = New-HostDriverStub -Root $repoRoot -HostType 'host.windows.hyper-v' -Marker 'driver-v2'
            $null = Initialize-YurunaHost -RepoRoot $repoRoot -HostType 'host.windows.hyper-v'
            Assert-Equal -Expected 'driver-v2' -Actual (Get-YurunaHostStubMarker) `
                -Because 'the -Force re-import is what makes the bootstrap idempotent AND edit-aware; a stale driver would silently keep running'
        }
    }

    Context 'missing driver' {

        It 'throws, naming the host type and the path it searched, when the driver is absent' {
            $repoRoot = Join-Path $bootRoot 'repo-no-driver'
            New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

            $message = Get-ThrownMessage { Initialize-YurunaHost -RepoRoot $repoRoot -HostType 'host.ubuntu.kvm' }

            Assert-True ($message -match 'Yuruna\.Host\.psm1 not found') 'a missing driver must fail loudly, not dispatch into nothing'
            Assert-True ($message -match 'host\.ubuntu\.kvm') 'the message names the host it looked for'
            Assert-True ($message -match 'ubuntu\.kvm') 'the message shows the path it searched, so the operator can see the layout it expected'
            Assert-True ($message -match 'Cannot dispatch host operations')
        }

        It 'throws for a host type the repo has no folder for' {
            $repoRoot = Join-Path $bootRoot 'repo-unknown-host'
            New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

            $message = Get-ThrownMessage { Initialize-YurunaHost -RepoRoot $repoRoot -HostType 'host.freebsd.bhyve' }

            Assert-True ($message -match 'host\.freebsd\.bhyve') 'an unsupported host fails at the driver lookup rather than importing some other host driver'
            Assert-True ($message -match 'freebsd\.bhyve') 'the derived folder appears in the message'
        }
    }

    Context 'sibling surface' {

        # Documented contract: importing Test.HostBootstrap alone must give a
        # caller the whole Test.Host* surface, because the module pulls in the
        # detection / condition / git siblings with -Global.
        It 'lands the Test.Host* siblings in the caller session' -TestCases @(
            @{ name = 'Get-HostType' }
            @{ name = 'Get-HostFolder' }
            @{ name = 'Get-TestVMName' }
            @{ name = 'Test-GuestFolder' }
            @{ name = 'Assert-HostConditionSet' }
            @{ name = 'Invoke-GitPull' }
            @{ name = 'Update-ProjectClone' }
        ) {
            param($name)
            $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
            Assert-True ([bool]$cmd) "importing Test.HostBootstrap alone must make '$name' resolvable"
            Assert-True ($cmd.ModuleName -like 'Test.Host*') "'$name' resolved to '$($cmd.ModuleName)', which is not a Test.Host* sibling"
        }
    }

    # Ordered last: it evicts the real Test.VMUtility to exercise the
    # not-yet-loaded branch, and restores it afterwards.
    Context 'Test.VMUtility co-import' {

        BeforeAll {
            $vmUtilRepo = Join-Path $bootRoot 'repo-vmutility'
            $null = New-HostDriverStub -Root $vmUtilRepo -HostType 'host.windows.hyper-v' -Marker 'driver-with-vmutility'
            $null = New-VMUtilityStub  -Root $vmUtilRepo -Marker 'vmutility-stub'
            Remove-Module -Name 'Test.VMUtility' -Force -ErrorAction SilentlyContinue
        }

        AfterAll {
            Remove-Module -Name 'Test.VMUtility' -Force -ErrorAction SilentlyContinue
            Import-Module (Join-Path $here 'Test.VMUtility.psm1') -Global -Force -DisableNameChecking -ErrorAction SilentlyContinue
        }

        It 'imports test/modules/Test.VMUtility.psm1 from the repo root alongside the driver when it is not already loaded' {
            Assert-True (-not (Get-Module -Name 'Test.VMUtility')) 'precondition: the not-loaded branch is the one under test'

            $null = Initialize-YurunaHost -RepoRoot $vmUtilRepo -HostType 'host.windows.hyper-v'

            Assert-True ([bool](Get-Module -Name 'Test.VMUtility')) `
                'the host-agnostic helpers (Wait-VMRunning, ...) must arrive with the driver, or the first New-VM step dies on a missing command'
            Assert-Equal -Expected 'vmutility-stub' -Actual (Get-YurunaVMUtilityStubMarker) `
                -Because 'Test.VMUtility is imported -Global too, so the runner session resolves it directly'
        }
    }
}
