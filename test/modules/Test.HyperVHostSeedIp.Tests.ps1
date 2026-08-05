<#PSScriptInfo
.VERSION 2026.08.05
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

# A function rather than a file-scope array: only the code above the first
# Describe is guaranteed to have run by the time an It body executes.
function Get-GuestNewVmScriptName {
    return @(
        'guest.amazon.linux.2023', 'guest.ubuntu.server.24', 'guest.ubuntu.server.26',
        'guest.windows.11', 'guest.caching-proxy-service', 'guest.stash-service',
        'guest.pool-control-service', 'guest.download-agent-service'
    )
}

function Get-GuestNewVmScriptPath {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'GuestName IS used -- in the Join-Path -AdditionalChildPath list below.')]
    param([string]$GuestName)
    return (Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', $GuestName, 'New-VM.ps1')
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

    It 'Wait-ExternalSwitchHostIpv4 qualifies the default-route address against the switch''s own segment' {
        # The default-route source is correct only while the route rides the
        # switch's segment -- its vEthernet, or the NIC the switch bridges
        # when management-OS sharing is off. An address on any other adapter
        # belongs to a segment the bridged guest holds no route to: not a
        # degraded answer but a wrong one, and wrong in a way the guest can
        # only discover after the seed carrying it has been burned.
        $fn = Get-FunctionAst -Name 'Wait-ExternalSwitchHostIpv4'
        Assert-True ($null -ne $fn) 'the settle helper must exist'
        Assert-True ($null -ne (Get-CallLine -FunctionAst $fn -CommandName 'Test-YurunaAdapterOnSwitchSegment')) `
            'the route''s adapter must be tested against the switch before its address is accepted'

        $segment = Get-FunctionAst -Name 'Test-YurunaAdapterOnSwitchSegment'
        Assert-True ($null -ne $segment) 'the segment predicate must exist'
        Assert-True ($segment.Extent.Text -match 'vEthernet \(') 'the switch''s own management vNIC is on its segment'
        Assert-True ($null -ne (Get-CallLine -FunctionAst $segment -CommandName 'Get-YurunaSwitchUplinkDescription')) `
            'so is a NIC the switch bridges -- the topology the docstring legitimises'
    }

    It 'Wait-ExternalSwitchHostIpv4 stops waiting for a management vNIC that cannot appear' {
        # Polling the full budget for an adapter Hyper-V says does not exist
        # multiplies a 30s/60s wait across every guest and every failure
        # artifact, inside the tightest watchdog windows in the runner.
        $fn = Get-FunctionAst -Name 'Wait-ExternalSwitchHostIpv4'
        Assert-True ($null -ne (Get-CallLine -FunctionAst $fn -CommandName 'Test-YurunaManagementVnicAbsent')) `
            'a confirmed-absent management vNIC must end the wait'

        $probe = Get-FunctionAst -Name 'Test-YurunaManagementVnicAbsent'
        Assert-True ($null -ne $probe) 'the absence probe must exist'
        Assert-True ($null -ne (Get-CallLine -FunctionAst $probe -CommandName 'Get-VMNetworkAdapter')) `
            'absence must come from Hyper-V, not from an adapter-alias miss'
        # Every unresolvable case answers $false, so the probe can only ever
        # shorten a wait on a positively confirmed absence.
        Assert-True (@($probe.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
                    }, $true) | Where-Object { $_.Extent.Text -match 'return\s+\$false' }).Count -ge 2) `
            'the unresolvable paths must answer $false'
    }

    It 'both reuse branches can decline, so the $null the seed builders handle is reachable' {
        # $null is the only "no bridge" signal the seven guest scripts
        # understand, and each maps it to a working NAT topology. Reusing a
        # switch whose bridge is dead instead hands every guest a carrier-less
        # attachment plus, through the wait above, an empty seed address.
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        $verdictLine = Get-CallLine -FunctionAst $fn -CommandName 'Test-YurunaExternalSwitchUplink'
        $declineLine = Get-CallLine -FunctionAst $fn -CommandName 'Resolve-DegradedExternalSwitchFallback'
        $bindLine    = Get-CallLine -FunctionAst $fn -CommandName 'New-VMSwitch'
        Assert-True ($null -ne $verdictLine) 'the reuse branches must classify the switch they are about to hand out'
        Assert-True ($null -ne $declineLine) 'a degraded verdict must reach the decline path'
        Assert-True ($declineLine -lt $bindLine) 'declining must not fall through to a create on an already-bridged NIC'

        $decline = Get-FunctionAst -Name 'Resolve-DegradedExternalSwitchFallback'
        Assert-True ($null -ne $decline) 'the decline path must exist'
        Assert-True ($decline.Extent.Text -match 'return \$null') 'declining answers $null'
        Assert-True ($decline.Extent.Text -match "Get-VMSwitch -Name 'Default Switch'") `
            'and only when the switch the guest scripts substitute actually exists'
    }
}

# The switch resolver's $null and the seven guest scripts' substitution are
# one contract in two files: every fix in this area deliberately increases how
# often $null is returned, and a script that lost the fallback would pass a
# $null -SwitchName straight to Hyper-V\New-VM.
Describe 'hyper-v-guest-new-vm-switch-fallback' {

    It 'every guest New-VM script substitutes the Default Switch when no External switch is offered' {
        $guestScript = @(Get-GuestNewVmScriptName)
        Assert-True ($guestScript.Count -eq 8) "expected eight Hyper-V guest drivers, found $($guestScript.Count)"
        $missing = @()
        foreach ($guest in $guestScript) {
            $path = Get-GuestNewVmScriptPath -GuestName $guest
            if (-not (Test-Path -LiteralPath $path)) { $missing += "$guest (script not found)"; continue }
            $src = Get-Content -Raw -LiteralPath $path
            # Presence and relative order only -- reformatting must stay free.
            if ($src -notmatch '(?s)\$switchName\s*=\s*Get-OrCreateYurunaExternalSwitch.*?if\s*\(\s*-not\s+\$switchName\s*\).*?\$switchName\s*=\s*''Default Switch''') {
                $missing += $guest
            }
        }
        Assert-True ($missing.Count -eq 0) "these scripts no longer fall back to the Default Switch: $($missing -join ', ')"
    }

    It 'every guest New-VM script checks that the substituted switch exists' {
        # The Default Switch ships only on Windows client SKUs and an operator
        # can delete it. New-VM throws on a name that resolves to nothing, so
        # an unchecked substitution turns a degraded network into a failed
        # provision for every guest in the cycle.
        $guestScript = @(Get-GuestNewVmScriptName)
        $missing = @()
        foreach ($guest in $guestScript) {
            $src = Get-Content -Raw -LiteralPath (Get-GuestNewVmScriptPath -GuestName $guest)
            if ($src -notmatch '(?s)\$switchName\s*=\s*''Default Switch''.{0,800}Get-VMSwitch') { $missing += $guest }
        }
        Assert-True ($guestScript.Count -eq 8) 'the guest-driver list must not go empty'
        Assert-True ($missing.Count -eq 0) "these scripts substitute a switch name without confirming it resolves: $($missing -join ', ')"
    }

    It 'no seed builder treats an empty host IP as fatal' {
        # The templates splice the value unguarded into host.env, /etc/hosts
        # and wgetrc; an empty string is a tolerated (documented) state, while
        # a throw here would red a guest that only lost its host shortcut.
        $seedBuilder = @()
        $fatal       = @()
        foreach ($guest in @(Get-GuestNewVmScriptName)) {
            $src = Get-Content -Raw -LiteralPath (Get-GuestNewVmScriptPath -GuestName $guest)
            if ($src -match '\$YurunaHostIp\s*=\s*Get-GuestReachableHostIp') {
                $seedBuilder += $guest
                if ($src -notmatch '(?s)if\s*\(\s*-not\s+\$YurunaHostIp\s*\)\s*\{\s*\$YurunaHostIp\s*=\s*''''\s*\}') { $fatal += $guest }
            }
        }
        Assert-True ($seedBuilder.Count -ge 6) "expected the six network-seeded guests to resolve a host IP, found $($seedBuilder.Count)"
        Assert-True ($fatal.Count -eq 0) "these scripts no longer flatten an absent host IP to an empty string: $($fatal -join ', ')"
        # guest.windows.11 legitimately needs no host address: its whole
        # sequence is keystrokes, so it must never gain a network dependency.
        Assert-True ('guest.windows.11' -notin $seedBuilder) 'guest.windows.11 must not start depending on a reachable host IP'
    }
}
