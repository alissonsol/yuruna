<#PSScriptInfo
.VERSION 2026.07.26
.GUID 42b1c9e4-7d52-4f8a-9c36-e15a8d40b972
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host hyper-v network seed vswitch pester
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
    Guard: the host IPv4 baked into a Hyper-V guest seed must be an
    address that guest can actually route to.
.DESCRIPTION
    New-VM.ps1 resolves the guest-reachable host IPv4 immediately after
    the External vSwitch is created, and writes it into the seed ISO
    (/etc/yuruna/host.env) where it can no longer be corrected. Two
    ways that address goes wrong, both guarded here:

    * Bridging a NIC tears the host's IP stack off it and re-attaches it
      to `vEthernet (<switch>)`, which then re-DHCPs. A lookup during
      that window sees no address at all and no default route.
    * Answering "no LAN address" with the Default Switch's 172.x.x.x
      hands an External-attached guest an internal NAT address it holds
      no route to. The guest then boots, spends its fetch timeout on a
      host that was never reachable, and falls through to its off-LAN
      source -- so the failure surfaces far from its cause.

    Source-level (AST) guards: exercising the real paths needs a live
    hypervisor plus a vSwitch bind in flight, and what these protect
    against is a call-shape regression (the settle wait getting dropped,
    or the unroutable fall-through coming back). Parsing the source
    keeps the test platform-agnostic, and comments about waiting can
    neither satisfy nor break them.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$hostFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', 'modules', 'Yuruna.Host.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Parse once; each test reads the function bodies out of the AST so that
# comments and strings can never be mistaken for calls.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($hostFile, [ref]$null, [ref]$null)

function Get-FunctionAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    param([string]$Name)
    return $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
}

function Get-CallLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'CommandName IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    param($FunctionAst, [string]$CommandName)
    $calls = @($FunctionAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq $CommandName
    }, $true))
    if ($calls.Count -eq 0) { return $null }
    return ($calls | Measure-Object -Property { $_.Extent.StartLineNumber } -Minimum).Minimum
}

Describe 'hyper-v-guest-seed-host-ip' {

    It 'Wait-ExternalSwitchHostIpv4 polls both the switch vEthernet and the default route' {
        $fn = Get-FunctionAst -Name 'Wait-ExternalSwitchHostIpv4'
        Assert-True ($null -ne $fn) 'the settle helper must exist'
        Assert-True ($fn.Extent.Text -match 'vEthernet \(') 'must look up the address on the switch''s own vEthernet'
        Assert-True ($fn.Extent.Text -match "DestinationPrefix '0\.0\.0\.0/0'") 'must also accept the default-route address'
        Assert-True ($null -ne (Get-CallLine -FunctionAst $fn -CommandName 'Start-Sleep')) 'must retry rather than answer from a single sample'
    }

    It 'Wait-ExternalSwitchHostIpv4 rejects an address that means "DHCP has not answered"' {
        $fn = Get-FunctionAst -Name 'Wait-ExternalSwitchHostIpv4'
        # APIPA on the vEthernet is exactly the mid-bind state to wait out;
        # returning it would bake a link-local address no guest can reach.
        Assert-True ($fn.Extent.Text -match '169\\\.254\\\.') 'must reject APIPA addresses'
        Assert-True ($fn.Extent.Text -match '127\\\.') 'must reject loopback'
    }

    It 'Get-OrCreateYurunaExternalSwitch does not report ready until the host is addressable again' {
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        $bindLine = Get-CallLine -FunctionAst $fn -CommandName 'New-VMSwitch'
        $waitLine = Get-CallLine -FunctionAst $fn -CommandName 'Wait-ExternalSwitchHostIpv4'
        Assert-True ($null -ne $bindLine) 'the create path must still exist'
        Assert-True ($null -ne $waitLine) 'the bind must be followed by a settle wait'
        Assert-True ($waitLine -gt $bindLine) 'the settle wait must come after the bind, not before it'
    }

    It 'Get-GuestReachableHostIp never answers an External switch with the Default Switch address' {
        $fn = Get-FunctionAst -Name 'Get-GuestReachableHostIp'
        $waitLine = Get-CallLine -FunctionAst $fn -CommandName 'Wait-ExternalSwitchHostIpv4'
        Assert-True ($null -ne $waitLine) 'the External branch must resolve through the settle wait'

        # The Default-Switch lookup is the tail of the function. Reaching it
        # from the External branch is the unroutable-answer regression, so a
        # `return` has to stand between the two.
        $defaultLookup = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$defaultSwitchIp'
        }, $true))
        Assert-True ($defaultLookup.Count -ge 1) 'the Default-Switch path must still exist for NAT-attached guests'
        $defaultLine = $defaultLookup[0].Extent.StartLineNumber

        $returns = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
        }, $true) | Where-Object {
            $_.Extent.StartLineNumber -gt $waitLine -and $_.Extent.StartLineNumber -lt $defaultLine
        })
        Assert-True ($returns.Count -ge 1) 'the External branch must return before the Default-Switch lookup'
        Assert-True (@($returns | Where-Object { $_.Extent.Text -match 'return\s+\$null' }).Count -ge 1) `
            'an External switch with no host address must report none, not a Default Switch address'
    }
}
