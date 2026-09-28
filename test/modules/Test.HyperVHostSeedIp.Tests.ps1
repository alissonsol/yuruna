<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4250adff-0991-409e-81bf-56dfdf1149db
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

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$hostFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', 'modules', 'Yuruna.Host.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
            'so is a NIC the switch bridges -- the topology the docstring legitimizes'
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
        # The Windows guest is seeded the same way, and the flatten check above
        # covers it: the address is a HINT, so an absent one is a lost shortcut
        # rather than a failed provision. What makes the hint safe to seed at
        # all is the resolver the bootstrap carries, which re-finds the host
        # when the seeded address has moved -- the seed alone would bake in an
        # address a 30-minute lease can invalidate before Setup finishes.
        Assert-True ('guest.windows.11' -in $seedBuilder) 'the Windows guest resolves the status-service address like the others'
        $windowsGuest = Get-Content -Raw -LiteralPath (Get-GuestNewVmScriptPath -GuestName 'guest.windows.11')
        Assert-True ($windowsGuest -match 'New-WindowsGuestBootstrap') 'and hands it to the bootstrap builder that embeds the resolver'
    }
}

# The seed carries an address the guest can correct later; Get-BestHostIp is
# the other half of that -- what this host publishes about ITSELF, to the pool
# directory the guest corrects against. A wrong answer here is worse than a
# stale seed: it does not merely age, it never changes, so a host that is
# renumbering constantly looks perfectly still and no guest is ever told.
#
# Behavioral rather than AST, because what has to hold is the choice the
# function makes among adapters, and no call shape expresses that. The function
# body is lifted out of the module and run against a recorded inventory, so
# these cases need neither a live hypervisor nor a Windows host.
Describe 'hyper-v-host-own-address' {

    BeforeAll {
        # A Hyper-V host bridged the way this framework builds one: the LAN
        # address sits on the External switch's management vNIC, two internal
        # vNICs and two foreign NAT adapters sit alongside it, and only the
        # first is an address anything off this machine can reach.
        $script:BestIpHarness = @'
param([bool]$HyperVReadable, [bool]$HasDefaultRoute)
$addresses = @(
    [pscustomobject]@{ IPAddress = '192.168.7.105'; InterfaceAlias = 'vEthernet (Yuruna-External)';   InterfaceIndex = 25; PrefixOrigin = 'Dhcp' }
    [pscustomobject]@{ IPAddress = '172.24.144.1';  InterfaceAlias = 'vEthernet (WSLCore)';           InterfaceIndex = 40; PrefixOrigin = 'Manual' }
    [pscustomobject]@{ IPAddress = '192.168.128.1'; InterfaceAlias = 'vEthernet (Default Switch)';    InterfaceIndex = 41; PrefixOrigin = 'Manual' }
    [pscustomobject]@{ IPAddress = '192.168.159.1'; InterfaceAlias = 'VMware Network Adapter VMnet8'; InterfaceIndex = 12; PrefixOrigin = 'Manual' }
    [pscustomobject]@{ IPAddress = '192.168.80.1';  InterfaceAlias = 'VMware Network Adapter VMnet1'; InterfaceIndex = 11; PrefixOrigin = 'Manual' }
    [pscustomobject]@{ IPAddress = '127.0.0.1';     InterfaceAlias = 'Loopback Pseudo-Interface 1';   InterfaceIndex = 1;  PrefixOrigin = 'WellKnown' }
)
$metric = @{ 25 = 25; 40 = 5; 41 = 5; 12 = 35; 11 = 35; 1 = 75 }
function Get-NetIPAddress { param($AddressFamily, $InterfaceAlias, $InterfaceIndex, $ErrorAction) $addresses }
function Get-NetIPInterface { param($InterfaceIndex, $AddressFamily, $ErrorAction) [pscustomobject]@{ InterfaceMetric = $metric[$InterfaceIndex] } }
function Get-NetRoute {
    param($AddressFamily, $DestinationPrefix, $InterfaceIndex, $ErrorAction)
    if (-not $HasDefaultRoute) { return @() }
    @([pscustomobject]@{ InterfaceIndex = 25; NextHop = '192.168.7.1' })
}
function Get-VMSwitch {
    param($Name, $ErrorAction)
    if (-not $HyperVReadable) { throw 'You do not have the required permission to complete this task.' }
    @(
        [pscustomobject]@{ Name = 'Yuruna-External'; SwitchType = 'External' }
        [pscustomobject]@{ Name = 'Default Switch';  SwitchType = 'Internal' }
        [pscustomobject]@{ Name = 'WSLCore';         SwitchType = 'Internal' }
    )
}
__FUNCTION__
Get-BestHostIp
'@

        # Defined here rather than beside the It blocks: a bare function in a
        # Describe body is created during discovery, in a scope no test body
        # can see.
        #
        # Stubs shadow cmdlets only inside the scope that defines them, so the
        # harness and the lifted function have to be one scriptblock.
        function Invoke-BestHostIpProbe {
            param([bool]$HyperVReadable = $true, [bool]$HasDefaultRoute = $true)
            $fn = Get-FunctionAst -Name 'Get-BestHostIp'
            Assert-True ($null -ne $fn) 'the host must be able to answer what address it is on'
            $sb = [scriptblock]::Create($script:BestIpHarness.Replace('__FUNCTION__', $fn.Extent.Text))
            return [string](& $sb -HyperVReadable $HyperVReadable -HasDefaultRoute $HasDefaultRoute)
        }
    }

    It 'answers the External switch vEthernet, not a foreign hypervisor NAT adapter' {
        # Excluding every vEthernet is the intuitive way to skip the internal
        # vNICs, and on this topology it excludes the only correct answer --
        # leaving an address that is local to this machine, permanent, and
        # therefore silently untrue.
        Invoke-BestHostIpProbe | Should -Be '192.168.7.105'
    }

    It 'keeps the internal and NAT vNICs out' {
        $answer = Invoke-BestHostIpProbe
        $answer | Should -Not -Be '192.168.128.1' -Because 'the Default Switch is an internal NAT segment no LAN peer routes to'
        $answer | Should -Not -Be '172.24.144.1'  -Because 'the WSL vNIC is the same kind of segment'
    }

    It 'still finds the LAN vEthernet when Hyper-V refuses to name its switches' {
        # Get-VMSwitch needs Hyper-V administrator rights and the address
        # beacon does not always have them; the default route is readable by
        # anyone and rides the LAN-facing adapter whatever it is called.
        Invoke-BestHostIpProbe -HyperVReadable $false | Should -Be '192.168.7.105'
    }

    It 'prefers the External switch vNIC when there is no default route to rank by' {
        # A host between DHCP leases has no default route at all -- the moment
        # a renumber is happening, which is exactly when the beacon must not
        # answer with something else.
        Invoke-BestHostIpProbe -HasDefaultRoute $false | Should -Be '192.168.7.105'
    }
}

Describe 'Windows first-logon bootstrap transport on every host family' {
    BeforeAll {
        $script:SeedRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        Import-Module (Join-Path $script:SeedRepoRoot 'automation/Yuruna.GuestSeed.psm1') -Force -DisableNameChecking
        $script:SeedBundle = New-WindowsGuestBootstrap -RepoRoot $script:SeedRepoRoot -StatusServiceIp '192.0.2.10' `
            -StatusServicePort '8080' -HostId '00000000-0000-0000-0000-000000000001' -CachingProxyIp '192.0.2.20' -GhToken 'fixture-token'
        $script:SeedLauncher = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($script:SeedBundle.EncodedCommand))
    }

    It 'carries full scripts on media and keeps every answer-file command under 1024 characters' {
        $script:SeedBundle.Files.Count | Should -Be 2
        $script:SeedBundle.Files['yuruna-host-locate.ps1'] | Should -Be ([IO.File]::ReadAllText((Join-Path $script:SeedRepoRoot 'automation/yuruna-host-locate.ps1')))
        $script:SeedBundle.Files['yuruna-bootstrap.ps1'] | Should -Match 'YURUNA_HOST_ID=00000000-0000-0000-0000-000000000001'
        $script:SeedBundle.Files['yuruna-bootstrap.ps1'] | Should -Match "token = 'fixture-token'"
        foreach ($body in $script:SeedBundle.Files.Values) {
            $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
        }
        foreach ($family in @('windows.hyper-v', 'macos.utm', 'ubuntu.kvm')) {
            $template = Join-Path $script:SeedRepoRoot "host/$family/guest.windows.11/vmconfig/autounattend.xml"
            [xml]$answer = ([IO.File]::ReadAllText($template)).Replace('GUEST_BOOTSTRAP_B64_PLACEHOLDER', $script:SeedBundle.EncodedCommand)
            $commands = @($answer.SelectNodes('//*[local-name()="FirstLogonCommands"]//*[local-name()="CommandLine"]'))
            $bootstrapCommands = @($commands | Where-Object { $_.InnerText -match '-EncodedCommand ' })
            $bootstrapCommands.Count | Should -Be 1
            $bootstrapCommands[0].InnerText.Length | Should -BeLessOrEqual 1024 -Because "$family must fit the Windows Setup command-line field"
        }
    }

    It 'locates and executes the seed file without requiring a fixed drive letter' {
        $seedDrive = Join-Path $TestDrive 'seed CD with spaces'
        $null = New-Item -ItemType Directory -Path $seedDrive -Force
        Set-Content -LiteralPath (Join-Path $seedDrive 'yuruna-bootstrap.ps1') -Value "'seed-launched'"
        function Get-CimInstance {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Local CD inventory stand-in keeps launcher execution isolated from the host.')]
            param([string]$ClassName, [string]$Filter)
            if ($ClassName -ne 'Win32_LogicalDisk' -or $Filter -ne 'DriveType=5') { throw 'The launcher must inspect only CD media.' }
            [pscustomobject]@{ DeviceID = $seedDrive }
        }
        $result = & ([scriptblock]::Create($script:SeedLauncher))
        $result | Should -Be 'seed-launched'
    }

    It 'refuses absent or ambiguous seed media before running any script' {
        $first = Join-Path $TestDrive 'first seed CD'
        $second = Join-Path $TestDrive 'second seed CD'
        foreach ($path in @($first, $second)) {
            $null = New-Item -ItemType Directory -Path $path -Force
            Set-Content -LiteralPath (Join-Path $path 'yuruna-bootstrap.ps1') -Value "throw 'unexpected execution'"
        }
        function Get-CimInstance {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Local CD inventory stand-in keeps launcher execution isolated from the host.')]
            param([string]$ClassName, [string]$Filter)
            $null = $ClassName, $Filter
            foreach ($path in $seedDrives) { [pscustomobject]@{ DeviceID = $path } }
        }
        foreach ($seedDrives in @(@(), @($first, $second))) {
            { & ([scriptblock]::Create($script:SeedLauncher)) } | Should -Throw '*Expected one Yuruna seed CD*'
        }
    }

    It 'writes both scripts beside the answer file from each production builder' {
        foreach ($family in @('windows.hyper-v', 'macos.utm', 'ubuntu.kvm')) {
            $builder = Join-Path $script:SeedRepoRoot "host/$family/guest.windows.11/New-VM.ps1"
            $source = [IO.File]::ReadAllText($builder)
            $ast = Get-YurunaTestFileAst -Path $builder
            $call = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-WindowsGuestBootstrap' }, $true)
            $start = $call
            while ($start -and $start -isnot [Management.Automation.Language.AssignmentStatementAst]) { $start = $start.Parent }
            Assert-NotNull $start 'the builder must render its seed bundle before writing the ISO'
            $write = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-Content' }, $true) |
                Where-Object { $_.Extent.StartOffset -gt $start.Extent.StartOffset } | Sort-Object { $_.Extent.StartOffset })[0]
            $seedCode = [scriptblock]::Create($source.Substring($start.Extent.StartOffset, $write.Extent.EndOffset - $start.Extent.StartOffset))
            $seedDirectory = & {
                param($Code, $FixtureRoot, $BuilderRoot, $Family)
                $repoRoot = $BuilderRoot
                $_utmRepoRoot = $BuilderRoot
                $_kvmRepoRoot = $BuilderRoot
                $vmDir = Join-Path $FixtureRoot $Family
                $SeedDir = Join-Path $vmDir 'seed'
                $null = New-Item -ItemType Directory -Path $SeedDir -Force
                $AnswerFileTemplate = Join-Path $BuilderRoot "host/$Family/guest.windows.11/vmconfig/autounattend.xml"
                $autoTemplate = $AnswerFileTemplate
                $VMName = 'fixture-windows'
                $YurunaHostIp = '192.0.2.10'; $YurunaHostPort = '8080'
                $YurunaHostId = '00000000-0000-0000-0000-000000000001'; $YurunaCacheIp = '192.0.2.20'
                $ghSource = @{ Token = 'fixture-token' }
                function Get-YurunaGitHubSource { param($RepoRoot) $null = $RepoRoot; @{ Token = 'fixture-token' } }
                $null = $_utmRepoRoot, $_kvmRepoRoot, $autoTemplate, $VMName, $YurunaHostIp, $YurunaHostPort, $YurunaHostId, $YurunaCacheIp, $ghSource
                . $Code
                if ($Family -eq 'ubuntu.kvm') { $autoSrc } else { $SeedDir }
            } $seedCode $TestDrive $script:SeedRepoRoot $family
            foreach ($filename in @('autounattend.xml', 'yuruna-bootstrap.ps1', 'yuruna-host-locate.ps1')) {
                Test-Path -LiteralPath (Join-Path $seedDirectory $filename) -PathType Leaf | Should -BeTrue -Because "$family must include $filename on its seed CD"
            }
            [xml]$answer = [IO.File]::ReadAllText((Join-Path $seedDirectory 'autounattend.xml'))
            $answer.OuterXml | Should -Not -Match 'GUEST_BOOTSTRAP_B64_PLACEHOLDER'
            if ($family -eq 'ubuntu.kvm') {
                $iso = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'genisoimage' }, $true)
                @($iso.CommandElements | Where-Object { $_.Extent.Text -eq '$autoSrc' }).Count | Should -Be 1 -Because 'the ISO must carry the complete seed directory'
            }
        }
    }
}
