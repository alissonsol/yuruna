<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42c7d1e8-6b02-4f3a-9c51-8e2a4d7b1f60
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host hyper-v network wifi nat pester
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
    Guard: on a not-bridgeable default-route uplink the Hyper-V host must
    build guests on NAT (Default Switch), never on a bridged External
    vSwitch.
.DESCRIPTION
    An External vSwitch L2-bridges the guest's MAC onto the uplink. Two
    uplink classes cannot forward frames for that guest MAC: Wi-Fi (802.11
    refuses a MAC the AP never authenticated) and USB Ethernet adapters
    (the miniport lacks the promiscuous/MAC-spoofing support bridging
    needs). Either way a bridged guest never gets a DHCP lease and boots
    with eth0 DOWN -- the fetch-and-execute step then fails and the runner
    faults. host.macos.utm keys UTM's Shared(NAT)-vs-Bridged choice on
    Test-MacUplinkNotBridgeable; the Windows analog is
    Test-WindowsUplinkNotBridgeable diverting Get-OrCreateYurunaExternalSwitch
    to return $null (whereupon New-VM.ps1 falls back to the Default Switch).

    Source-level (AST) guards: the real paths need a live hypervisor plus a
    Wi-Fi radio or USB NIC to exercise, and the regression they protect
    against is a call-shape regression (the divert getting dropped or
    bypassed) or a criterion getting dropped. Parsing the source keeps the
    test platform-agnostic, and comments mentioning Wi-Fi/USB can neither
    satisfy nor break them.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$hostFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', 'modules', 'Yuruna.Host.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Parse once; each test reads the function bodies out of the AST so that
# comments and strings can never be mistaken for calls.
$ast     = [System.Management.Automation.Language.Parser]::ParseFile($hostFile, [ref]$null, [ref]$null)
$srcText = Get-Content -Raw $hostFile

function Get-FunctionAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    param([string]$Name)
    return $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
}

Describe 'hyper-v-wifi-nat-divert' {

    It 'Test-WindowsUplinkNotBridgeable exists and decides on the 802.11 media type' {
        $fn = Get-FunctionAst -Name 'Test-WindowsUplinkNotBridgeable'
        Assert-True ($null -ne $fn) 'the not-bridgeable detector must exist'
        # It must key off the physical media type, not a name heuristic.
        Assert-True ($fn.Extent.Text -match 'Native 802\.11') 'must test PhysicalMediaType against Native 802.11'
        Assert-True ($fn.Extent.Text -match 'PhysicalMediaType') 'must read the adapter PhysicalMediaType'
    }

    It 'Test-WindowsUplinkNotBridgeable also rejects a USB-attached uplink' {
        # A Hyper-V External vSwitch can't carry a bridged guest MAC over a
        # USB NIC (the miniport lacks promiscuous/MAC-spoof support), so the
        # detector must consult the PnP bus, not just the media type.
        $fn = Get-FunctionAst -Name 'Test-WindowsUplinkNotBridgeable'
        Assert-True ($fn.Extent.Text -match 'PnPDeviceID') 'must read the adapter PnPDeviceID to spot a USB bus'
        Assert-True ($fn.Extent.Text -match "USB") 'must treat a USB-attached uplink as not bridgeable'
    }

    It 'Test-WindowsUplinkNotBridgeable resolves a vEthernet route back to the physical NIC' {
        # -AllowManagementOS rides the host IP on vEthernet (<switch>); a
        # Wi-Fi- or USB-backed External switch must still read as not bridgeable.
        $fn = Get-FunctionAst -Name 'Test-WindowsUplinkNotBridgeable'
        Assert-True ($fn.Extent.Text -match 'Hyper-V Virtual Ethernet') 'must special-case a vEthernet default route'
        Assert-True ($fn.Extent.Text -match 'NetAdapterInterfaceDescription') 'must follow the vSwitch to its physical adapter'
    }

    It 'Get-OrCreateYurunaExternalSwitch diverts a not-bridgeable host to NAT before creating a bridge' {
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        Assert-True ($null -ne $fn) 'the switch resolver must exist'

        # The not-bridgeable check must be called...
        $wifiCall = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Test-WindowsUplinkNotBridgeable'
        }, $true))
        Assert-True ($wifiCall.Count -ge 1) 'must consult Test-WindowsUplinkNotBridgeable'

        # ...and it must gate a `return $null` that sits BEFORE any
        # New-VMSwitch, so a not-bridgeable host never bridges.
        $newSwitch = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'New-VMSwitch'
        }, $true))
        Assert-True ($newSwitch.Count -ge 1) 'the create path must still exist for wired hosts'

        $returns = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true))
        $wifiLine   = $wifiCall[0].Extent.StartLineNumber
        $switchLine = ($newSwitch | Measure-Object -Property { $_.Extent.StartLineNumber } -Minimum).Minimum
        $earlyNull  = @($returns | Where-Object {
            $_.Extent.StartLineNumber -gt $wifiLine -and
            $_.Extent.StartLineNumber -lt $switchLine -and
            $_.Extent.Text -match 'return\s+\$null'
        })
        Assert-True ($earlyNull.Count -ge 1) 'the not-bridgeable check must guard a `return $null` before New-VMSwitch'
    }

    It 'Test-WindowsUplinkNotBridgeable is exported' {
        Assert-True ($srcText -match 'Export-ModuleMember[\s\S]*Test-WindowsUplinkNotBridgeable') `
            'the detector must be exported for callers and tests'
    }
}
