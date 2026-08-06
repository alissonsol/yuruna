<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42646cc9-f27d-42cf-9882-9c56c352de85
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host hyper-v vswitch uplink pester
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
    Guard: an External vSwitch is classified before it is handed to a guest,
    and the classification never demotes a working bridge.
.DESCRIPTION
    A Hyper-V vSwitch object outlives its uplink binding across a host
    reboot: the object keeps its name, its type and the description of the
    NIC it was bridged to, while the host's IP stack sits back on the bare
    physical adapter and nothing forwards frames for a guest MAC. Finding
    the object is therefore not evidence that a guest attached to it gets a
    carrier, and Test-YurunaExternalSwitchUplink is the one predicate that
    asks the question.

    Behavioral coverage runs through the function's record seam: binding
    -SwitchRecord puts it in fully-injected mode for all three record
    parameters together, so fabricated Get-VMSwitch / Get-NetAdapter /
    Get-NetIPAddress shapes drive the whole verdict ladder with no live
    Hyper-V and no Net* cmdlets -- the suite has to pass on Windows, Linux
    and macOS alike.

    The asymmetry the negative controls protect: a false unhealthy verdict
    demotes an entire host to Default Switch NAT (its cache VM loses its LAN
    IP, ARP discovery no-ops), while a missed degraded switch costs one
    cycle. So every shape that is merely unusual -- a Switch Embedded Team
    reported only on the plural description property, a renamed management
    vNIC, an unresolvable binding -- must read as usable.

    The module is imported at file scope (it persists into the run phase);
    the module handle is fetched INSIDE each It, and throw-based Assert-*
    helpers keep the file runnable under Pester 4.10.1 and 5+.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$hostFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'windows.hyper-v', 'modules', 'Yuruna.Host.psm1'
$contractFile = Join-Path $repoRoot 'host' -AdditionalChildPath 'Yuruna.Host.Contract.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ("$Expected" -ne "$Actual") { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-NotEqual { param($Expected, $Actual, [string]$Because = '') if ("$Expected" -eq "$Actual") { throw "Expected anything but [$Expected]. $Because" } }

Import-Module $hostFile -Force -DisableNameChecking -ErrorAction SilentlyContinue

# Parse once so the call-shape guards read the real AST rather than text
# that a comment or a string could satisfy.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($hostFile, [ref]$null, [ref]$null)

# The closed vocabulary every consumer switches on. 'healthy' and 'unknown'
# are the usable pair; the rest are degraded.
$UplinkVerdict = @('healthy', 'unknown', 'not-external', 'uplink-missing', 'uplink-down',
    'management-os-detached', 'management-os-unaddressed')

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
    return @($calls | ForEach-Object { $_.Extent.StartLineNumber } | Sort-Object)
}

# --- record seam ------------------------------------------------------------
# Shapes match what the live branch reads: Get-VMSwitch for the switch,
# Get-NetAdapter concatenated with Get-VMNetworkAdapter -ManagementOS for the
# adapters, Get-NetIPAddress for the addresses.

function Get-SwitchRecord {
    param(
        [string]$Name = 'Yuruna-External',
        [string]$SwitchType = 'External',
        [object]$AllowManagementOS = $true,
        [string]$Uplink = 'Intel(R) Ethernet Connection I219-LM',
        [string[]]$UplinkTeam
    )
    $record = [ordered]@{
        Name                          = $Name
        SwitchType                    = $SwitchType
        AllowManagementOS             = $AllowManagementOS
        NetAdapterInterfaceDescription = $Uplink
    }
    # Only a teamed switch carries the plural property, so it is added only
    # when a team is named -- otherwise the singular read is what is exercised.
    if ($PSBoundParameters.ContainsKey('UplinkTeam')) { $record['NetAdapterInterfaceDescriptions'] = $UplinkTeam }
    return [pscustomobject]$record
}

function Get-AdapterRecord {
    param(
        [string]$Alias,
        [string]$Description,
        [string]$Status = 'Up',
        [string]$Mac = '',
        [int]$Index = 0
    )
    return [pscustomobject]@{
        Name                 = $Alias
        InterfaceAlias       = $Alias
        InterfaceDescription = $Description
        Status               = $Status
        MacAddress           = $Mac
        InterfaceIndex       = $Index
    }
}

# Hyper-V's own answer to "is a management-OS vNIC present on this switch",
# which is what the classifier asks instead of matching an adapter alias.
function Get-ManagementVnicRecord {
    param([string]$SwitchName = 'Yuruna-External', [string]$Mac = '')
    return [pscustomobject]@{ IsManagementOs = $true; SwitchName = $SwitchName; MacAddress = $Mac }
}

function Get-HostIpRecord {
    param([string]$Address, [string]$Alias, [int]$Index = 0)
    return [pscustomobject]@{ IPAddress = $Address; InterfaceAlias = $Alias; InterfaceIndex = $Index }
}

function Invoke-UplinkVerdict {
    param([string]$SwitchName, $SwitchRecord, $AdapterRecord, $HostIpRecord)
    $mod = Get-Module Yuruna.Host
    & $mod {
        param($n, $s, $a, $i)
        Test-YurunaExternalSwitchUplink -SwitchName $n -SwitchRecord $s -AdapterRecord $a -HostIpRecord $i
    } $SwitchName @($SwitchRecord) @($AdapterRecord) @($HostIpRecord)
}

function Invoke-OnSwitchSegment {
    param($SwitchRecord, $Adapter, [string]$SwitchName)
    $mod = Get-Module Yuruna.Host
    & $mod {
        param($s, $a, $n)
        Test-YurunaAdapterOnSwitchSegment -SwitchRecord $s -Adapter $a -SwitchName $n
    } $SwitchRecord $Adapter $SwitchName
}

# What Wait-ExternalSwitchHostIpv4 would answer for the same records: the
# address on 'vEthernet (<switch>)' first, then a default-route address but
# only when its adapter is on the switch's own segment. Mirrors the shipped
# acceptance rule through the module's own segment predicate, so the two can
# be compared instead of asserted independently.
function Test-WaitWouldAnswer {
    param([string]$SwitchName, $SwitchRecord, $AdapterRecord, $HostIpRecord)
    $usable = { param($Address) $Address -and ($Address -notmatch '^(127\.|169\.254\.)') }
    foreach ($ip in @($HostIpRecord)) {
        if (-not (& $usable $ip.IPAddress)) { continue }
        if ("$($ip.InterfaceAlias)" -eq "vEthernet ($SwitchName)") { return $true }
        $owner = @($AdapterRecord | Where-Object {
                $_ -and (("$($_.InterfaceAlias)" -eq "$($ip.InterfaceAlias)") -or
                    (($_.InterfaceIndex) -and ($ip.InterfaceIndex) -and ("$($_.InterfaceIndex)" -eq "$($ip.InterfaceIndex)")))
            }) | Select-Object -First 1
        if ($owner -and (Invoke-OnSwitchSegment -SwitchRecord $SwitchRecord -Adapter $owner -SwitchName $SwitchName)) { return $true }
    }
    return $false
}

# The wired NIC the switch names as its uplink, and the host address sitting
# directly on it -- the post-reboot shape both incident fingerprints share.
function Get-CapturedHostState {
    # One host's Get-VMSwitch / Get-NetAdapter / Get-NetIPAddress state, kept
    # verbatim. Built inside a function rather than assigned in the Describe
    # body because a Describe body runs at discovery time and its variables are
    # not in scope when the It bodies later execute.
    return @{
        Switch = [pscustomobject][ordered]@{
            Name                            = 'Yuruna-External'
            SwitchType                      = 'External'
            AllowManagementOS               = $true
            NetAdapterInterfaceDescription  = 'Intel(R) Ethernet Controller I226-V'
            # A real record carries BOTH properties, the plural holding the same
            # single member as the singular even on a switch that is not teamed,
            # so the union read is exercised the way production presents it.
            NetAdapterInterfaceDescriptions = @('Intel(R) Ethernet Controller I226-V')
        }
        DefaultSwitch = [pscustomobject][ordered]@{
            Name                           = 'Default Switch'
            SwitchType                     = 'Internal'
            AllowManagementOS              = $true
            NetAdapterInterfaceDescription = ''
        }
        Nic = (Get-AdapterRecord -Alias 'Ethernet' -Description 'Intel(R) Ethernet Controller I226-V' `
            -Status 'Up' -Mac 'A8-B8-E0-01-02-03' -Index 4)
        Ip  = (Get-HostIpRecord -Address '192.168.7.69' -Alias 'Ethernet' -Index 4)
    }
}
function Get-BareNicSet {
    return @{
        Nic = (Get-AdapterRecord -Alias 'Ethernet' -Description 'Intel(R) Ethernet Connection I219-LM' -Status 'Up' -Mac '00-11-22-33-44-55' -Index 12)
        Ip  = (Get-HostIpRecord -Address '192.168.7.69' -Alias 'Ethernet' -Index 12)
    }
}

Describe 'hyper-v-uplink-classifier: verdict ladder' {

    It 'loaded the windows.hyper-v host module' {
        Assert-True ($null -ne (Get-Module Yuruna.Host)) 'Yuruna.Host (windows.hyper-v) must import for the classifier seam'
    }

    It 'reports unknown when there is no switch record at all' {
        # An absent switch is the create path's business, not a fault.
        Assert-Equal -Expected 'unknown' -Actual (Invoke-UplinkVerdict -SwitchName 'Yuruna-External' -SwitchRecord $null -AdapterRecord @() -HostIpRecord @())
    }

    It 'reports not-external when the name now belongs to an Internal switch' {
        $bare = Get-BareNicSet
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord -SwitchType 'Internal' -Uplink '') `
            -AdapterRecord @($bare.Nic) -HostIpRecord @($bare.Ip)
        Assert-Equal -Expected 'not-external' -Actual $verdict 'an Internal switch bearing the preferred name must not be handed out as a bridge'
    }

    # Incident fingerprint (b): the switch survived the reboot with no uplink
    # binding at all, while the host holds its LAN address on the bare NIC.
    It 'reports uplink-missing when the switch names no uplink adapter and the host IP sits on a bare NIC' {
        $bare = Get-BareNicSet
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord -Uplink '') `
            -AdapterRecord @($bare.Nic) -HostIpRecord @($bare.Ip)
        Assert-Equal -Expected 'uplink-missing' -Actual $verdict 'a switch with no bound NIC cannot bridge anything'
    }

    It 'reports uplink-down when the bound NIC is not Up' {
        $down = Get-AdapterRecord -Alias 'Ethernet' -Description 'Intel(R) Ethernet Connection I219-LM' -Status 'Disconnected' -Mac '00-11-22-33-44-55' -Index 12
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @($down) -HostIpRecord @(Get-HostIpRecord -Address '192.168.7.69' -Alias 'Ethernet' -Index 12)
        Assert-Equal -Expected 'uplink-down' -Actual $verdict 'Hyper-V cannot bridge a link that is down'
    }

    # Incident fingerprint (a): the binding survived and the NIC is Up, but
    # the management-OS vNIC the switch is configured to share is gone, so the
    # host's address is back on the bare NIC and no guest MAC is forwarded.
    It 'reports management-os-detached when sharing is on but Hyper-V reports no management vNIC' {
        $bare = Get-BareNicSet
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord -AllowManagementOS $true) `
            -AdapterRecord @($bare.Nic) -HostIpRecord @($bare.Ip)
        Assert-Equal -Expected 'management-os-detached' -Actual $verdict 'AllowManagementOS true with no management vNIC is a bridge that lost its host leg'
    }

    It 'reports management-os-unaddressed when the management vNIC exists but holds only APIPA' {
        # 802.1X held down, or DHCP dead on that segment: the link is Up and
        # the vNIC exists, yet nothing forwards and no seed address can be cut.
        $bare  = Get-BareNicSet
        $vnic  = Get-ManagementVnicRecord -Mac '00155D010203'
        $veth  = Get-AdapterRecord -Alias 'vEthernet (Yuruna-External)' -Description 'Hyper-V Virtual Ethernet Adapter' -Mac '00-15-5D-01-02-03' -Index 40
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @($bare.Nic, $vnic, $veth) `
            -HostIpRecord @(Get-HostIpRecord -Address '169.254.11.22' -Alias 'vEthernet (Yuruna-External)' -Index 40)
        Assert-Equal -Expected 'management-os-unaddressed' -Actual $verdict 'an APIPA-only management vNIC means DHCP never answered on that segment'
    }

    It 'reports healthy for a live bridge with an addressed management vNIC' {
        $bare = Get-BareNicSet
        $vnic = Get-ManagementVnicRecord -Mac '00155D010203'
        $veth = Get-AdapterRecord -Alias 'vEthernet (Yuruna-External)' -Description 'Hyper-V Virtual Ethernet Adapter' -Mac '00-15-5D-01-02-03' -Index 40
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @($bare.Nic, $vnic, $veth) `
            -HostIpRecord @(Get-HostIpRecord -Address '192.168.7.69' -Alias 'vEthernet (Yuruna-External)' -Index 40)
        Assert-Equal -Expected 'healthy' -Actual $verdict
    }
}

Describe 'hyper-v-uplink-classifier: negative controls (a working bridge must never read degraded)' {

    It 'reports healthy for a switch created without management-OS sharing (no vEthernet by design)' {
        # -AllowManagementOS:$false is a legitimate topology: the host keeps
        # its address on the bridged NIC and shares the guest's segment there.
        $bare = Get-BareNicSet
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord -AllowManagementOS $false) `
            -AdapterRecord @($bare.Nic) -HostIpRecord @($bare.Ip)
        Assert-Equal -Expected 'healthy' -Actual $verdict 'no management vNIC is expected here, so its absence is not a fault'
    }

    It 'reports healthy for a Switch Embedded Team whose members appear only on the plural property' {
        # On a SET/LBFO uplink the singular NetAdapterInterfaceDescription
        # names the team, which matches no single adapter; the members are on
        # the plural property. Reading only the singular one would demote every
        # teamed host in the fleet.
        $bare = Get-BareNicSet
        $team = Get-SwitchRecord -Name 'LAN-Bridge' -AllowManagementOS $false `
            -Uplink 'Microsoft Network Adapter Multiplexor Driver' `
            -UplinkTeam @('Intel(R) Ethernet Connection I219-LM', 'Intel(R) I210 Gigabit Network Connection #2')
        $verdict = Invoke-UplinkVerdict -SwitchName 'LAN-Bridge' -SwitchRecord $team `
            -AdapterRecord @($bare.Nic) -HostIpRecord @($bare.Ip)
        Assert-Equal -Expected 'healthy' -Actual $verdict 'a match on any team member counts as bound'
    }

    It 'reports healthy for a management vNIC that was renamed away from the default alias' {
        # Rename-NetAdapter on the management vNIC (common when scripting a
        # static address), or a disambiguating enumeration suffix, breaks the
        # 'vEthernet (<switch>)' alias shape on a bridge that works perfectly.
        # Presence comes from Hyper-V and the host NIC is found by MAC.
        $bare = Get-BareNicSet
        $vnic = Get-ManagementVnicRecord -Mac '00155D010203'
        $renamed = Get-AdapterRecord -Alias 'LabMgmt' -Description 'Hyper-V Virtual Ethernet Adapter' -Mac '00-15-5D-01-02-03' -Index 40
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @($bare.Nic, $vnic, $renamed) `
            -HostIpRecord @(Get-HostIpRecord -Address '192.168.7.69' -Alias 'LabMgmt' -Index 40)
        Assert-Equal -Expected 'healthy' -Actual $verdict 'an alias string must never be what decides a fleet-wide demotion'
    }

    It 'fails open to unknown when a named binding resolves to no adapter' {
        # A driver-supplied description change, an enumeration in flight or a
        # team shape this code has not seen: ambiguous, not broken.
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @(Get-AdapterRecord -Alias 'Wi-Fi' -Description 'Some Other Adapter' -Index 3) `
            -HostIpRecord @(Get-HostIpRecord -Address '192.168.7.69' -Alias 'Wi-Fi' -Index 3)
        Assert-Equal -Expected 'unknown' -Actual $verdict 'an unresolvable binding must not become a positive fault'
    }

    It 'stays in injected mode for all three record parameters at once' {
        # Binding any record parameter selects the seam wholesale, so a call
        # that supplies only a switch record can never reach live Get-NetAdapter
        # on a machine with no Hyper-V -- it answers 'unknown' instead.
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' -SwitchRecord (Get-SwitchRecord) `
            -AdapterRecord @() -HostIpRecord @()
        Assert-Equal -Expected 'unknown' -Actual $verdict 'a half-armed seam must fail open, not fall through to live cmdlets'
    }
}

Describe 'hyper-v-uplink-classifier: vocabulary and cross-function agreement' {

    It 'returns only verdicts from the closed vocabulary' {
        $fn = Get-FunctionAst -Name 'Test-YurunaExternalSwitchUplink'
        Assert-True ($null -ne $fn) 'the classifier must exist'
        $returns = @($fn.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.ReturnStatementAst]
                }, $true))
        Assert-True ($returns.Count -ge 7) "expected one return per verdict, found $($returns.Count)"
        $emitted = @($returns | ForEach-Object {
                $literal = $_.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst]
                    }, $true) | Select-Object -First 1
                if ($literal) { $literal.Value } else { "<non-literal: $($_.Extent.Text)>" }
            } | Sort-Object -Unique)
        $stray = @($emitted | Where-Object { $_ -notin $UplinkVerdict })
        Assert-Equal -Expected 0 -Actual $stray.Count "these are outside the closed vocabulary every consumer switches on: $($stray -join ', ')"
        $missing = @($UplinkVerdict | Where-Object { $_ -notin $emitted })
        Assert-Equal -Expected 0 -Actual $missing.Count "the ladder no longer emits: $($missing -join ', ')"
    }

    It 'exposes healthy and unknown as the usable pair' {
        $mod = Get-Module Yuruna.Host
        $ok = @(& $mod { $script:UplinkVerdictOk })
        Assert-Equal -Expected 'healthy,unknown' -Actual (($ok | Sort-Object) -join ',') `
            'unknown must map to usable, or an unevaluable probe would demote a host to NAT'
    }

    # The classifier and the host-IP wait must not disagree: a verdict of
    # 'healthy' on a state where the wait can only answer $null leaves a guest
    # bridged to a forwarding-dead switch AND carrying an empty seed address,
    # which is strictly worse for diagnosis than either fault alone. The cases
    # below are the ones where the host's address sits on the switch's own
    # segment in one of the two shapes the wait accepts.
    It 'never reports healthy for a state where the host-IP wait would answer nothing' {
        $bare = Get-BareNicSet
        $vnic = Get-ManagementVnicRecord -Mac '00155D010203'
        $veth = Get-AdapterRecord -Alias 'vEthernet (Yuruna-External)' -Description 'Hyper-V Virtual Ethernet Adapter' -Mac '00-15-5D-01-02-03' -Index 40
        $cases = @(
            @{ Name = 'sharing off, host address on the bridged NIC'
                Switch = (Get-SwitchRecord -AllowManagementOS $false); Adapter = @($bare.Nic); Ip = @($bare.Ip) }
            @{ Name = 'management vNIC addressed'
                Switch = (Get-SwitchRecord); Adapter = @($bare.Nic, $vnic, $veth)
                Ip = @(Get-HostIpRecord -Address '192.168.7.69' -Alias 'vEthernet (Yuruna-External)' -Index 40) }
            @{ Name = 'management vNIC at APIPA'
                Switch = (Get-SwitchRecord); Adapter = @($bare.Nic, $vnic, $veth)
                Ip = @(Get-HostIpRecord -Address '169.254.11.22' -Alias 'vEthernet (Yuruna-External)' -Index 40) }
            @{ Name = 'management vNIC gone, address back on the bare NIC'
                Switch = (Get-SwitchRecord); Adapter = @($bare.Nic); Ip = @($bare.Ip) }
            @{ Name = 'bound NIC down'
                Switch = (Get-SwitchRecord)
                Adapter = @(Get-AdapterRecord -Alias 'Ethernet' -Description 'Intel(R) Ethernet Connection I219-LM' -Status 'Disconnected' -Mac '00-11-22-33-44-55' -Index 12)
                Ip = @() }
        )
        foreach ($case in $cases) {
            $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' -SwitchRecord $case.Switch -AdapterRecord $case.Adapter -HostIpRecord $case.Ip
            if ($verdict -ne 'healthy') { continue }
            Assert-True (Test-WaitWouldAnswer -SwitchName 'Yuruna-External' -SwitchRecord $case.Switch -AdapterRecord $case.Adapter -HostIpRecord $case.Ip) `
                "'$($case.Name)' classifies healthy, but the host-IP wait would find no address on the switch's segment"
        }
    }
}

Describe 'hyper-v-uplink-classifier: the reuse branches consult it and can decline' {

    It 'classifies in both reuse branches before the create path' {
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        Assert-True ($null -ne $fn) 'the switch resolver must exist'
        $verdictLines = @(Get-CallLine -FunctionAst $fn -CommandName 'Test-YurunaExternalSwitchUplink')
        $bindLines    = @(Get-CallLine -FunctionAst $fn -CommandName 'New-VMSwitch')
        $divertLines  = @(Get-CallLine -FunctionAst $fn -CommandName 'Test-WindowsUplinkNotBridgeable')
        Assert-True ($verdictLines.Count -ge 2) "the preferred-name branch and the any-External branch must each classify (found $($verdictLines.Count))"
        Assert-Equal -Expected 1 -Actual $bindLines.Count 'a second, earlier create site would invert the ordering guards in the seed-IP suite'
        Assert-True ($divertLines.Count -ge 1) 'the not-bridgeable divert must still run'
        Assert-True ($divertLines[0] -lt $verdictLines[0]) 'the Wi-Fi/USB divert answers first; it is a steady state, not a fault'
        Assert-True ($verdictLines[-1] -lt $bindLines[0]) 'both reuse branches must classify before anything is created'
    }

    It 'routes every degraded verdict through the shared decline path' {
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        $declineLines = @(Get-CallLine -FunctionAst $fn -CommandName 'Resolve-DegradedExternalSwitchFallback')
        $bindLines    = @(Get-CallLine -FunctionAst $fn -CommandName 'New-VMSwitch')
        Assert-True ($declineLines.Count -ge 2) "each reuse branch must decline through one place (found $($declineLines.Count))"
        Assert-True ($declineLines[-1] -lt $bindLines[0]) `
            'declining must not fall through to a create: Hyper-V allows one External switch per NIC, so a blind create tears the original down and disconnects every VM on it'
    }

    It 'declining answers $null only when a Default Switch exists to fall back to' {
        $fn = Get-FunctionAst -Name 'Resolve-DegradedExternalSwitchFallback'
        Assert-True ($null -ne $fn) 'the decline path must exist'
        # $null is the only "no bridge" signal the guest scripts understand and
        # each substitutes the literal 'Default Switch' for it. Windows Server
        # SKUs ship none, so declining there would turn a degraded-but-booting
        # cycle into a New-VM failure for every guest.
        Assert-True ($fn.Extent.Text -match "Get-VMSwitch -Name 'Default Switch'") 'the fallback switch must be confirmed to exist'
        Assert-True ($fn.Extent.Text -match 'return \$null') 'a degraded switch must be declinable'
        Assert-True ($fn.Extent.Text -match 'return \$SwitchName') 'with no Default Switch the degraded name is handed back anyway -- a bridge with no carrier still boots a VM'
        Assert-True ($fn.Extent.Text -match '\$script:DegradedSwitchLatch') `
            'the branches run several times per cycle plus once per read-only probe, so the diagnosis is latched rather than repeated'
    }

    It 'keeps the switch resolver free of the settle wait' {
        # The seed-IP suite compares the minimum Wait-ExternalSwitchHostIpv4
        # line against the minimum New-VMSwitch line; a wait added to a reuse
        # branch would sit above the bind and invert that ordering.
        $fn = Get-FunctionAst -Name 'Get-OrCreateYurunaExternalSwitch'
        $waitLines = @(Get-CallLine -FunctionAst $fn -CommandName 'Wait-ExternalSwitchHostIpv4')
        $bindLines = @(Get-CallLine -FunctionAst $fn -CommandName 'New-VMSwitch')
        Assert-Equal -Expected 1 -Actual $waitLines.Count 'exactly one settle wait, on the create path'
        Assert-True ($waitLines[0] -gt $bindLines[0]) 'the settle wait belongs after the bind'
    }
}

Describe 'hyper-v-uplink-classifier: cache-reachability discriminator' {

    It 'Test-CacheVmOnYurunaExternalSwitch consults the uplink verdict' {
        $fn = Get-FunctionAst -Name 'Test-CacheVmOnYurunaExternalSwitch'
        Assert-True ($null -ne $fn) 'the discriminator must exist'
        Assert-True ((Get-CallLine -FunctionAst $fn -CommandName 'Test-YurunaExternalSwitchUplink').Count -ge 1) `
            'a cache attached to a switch whose bridge is dead holds no LAN address, so the fast path would delete the only remaining way to reach it'
        Assert-True ($fn.Extent.Text -match "SwitchType -ne 'External'") 'a non-External attachment still short-circuits before any classification'
    }

    It 'maps an unevaluable uplink back to the bridged fast path' {
        # The inverse is the destructive direction: Add-PortMap is
        # clear-all-first, so a false "not bridged" tears down every mapping
        # and republishes a NAT path that loses the real client IP.
        $fn = Get-FunctionAst -Name 'Test-CacheVmOnYurunaExternalSwitch'
        Assert-True ($fn.Extent.Text -match '\$script:UplinkVerdictOk') 'the usable pair (healthy + unknown) is what the fast path keys on'
    }

    It 'answers $false for a cache VM that does not exist' {
        $mod = Get-Module Yuruna.Host
        $answer = & $mod { param($n) Test-CacheVmOnYurunaExternalSwitch -VMName $n } 'yuruna-absent-cache-vm-42646cc9'
        Assert-Equal -Expected $false -Actual $answer 'no VM means no bridged cache, on every platform'
    }
}

Describe 'hyper-v-uplink-classifier: it stays driver-private' {

    It 'is exported from the driver module' {
        $src = Get-Content -Raw -LiteralPath $hostFile
        Assert-True ($src -match 'Export-ModuleMember[\s\S]*Test-YurunaExternalSwitchUplink') 'consumers resolve it by name behind a Get-Command probe'
    }

    It 'is not added to the cross-driver contract' {
        # Adding a verb to the contract is a widening event across all three
        # drivers, and switch-object health has a KVM analog but no macOS one.
        $src = Get-Content -Raw -LiteralPath $contractFile
        Assert-True ($src -notmatch 'Test-YurunaExternalSwitchUplink') 'the contract must stay platform-neutral'
    }

    It 'keeps its private helpers unexported' {
        $src = Get-Content -Raw -LiteralPath $hostFile
        $exportBlock = [regex]::Match($src, '(?ms)^Export-ModuleMember -Function.*?(?=\r?\n\r?\n)').Value
        Assert-True ($exportBlock.Length -gt 0) 'the export block must be findable'
        foreach ($private in @('Get-YurunaSwitchUplinkDescription', 'Test-YurunaAdapterOnSwitchSegment',
                'Test-YurunaSwitchOnDefaultRoute', 'Test-YurunaManagementVnicAbsent',
                'Resolve-DegradedExternalSwitchFallback')) {
            Assert-True ($exportBlock -notmatch $private) "$private is an implementation detail of the classifier, not a caller-facing verb"
        }
    }
}

Describe 'hyper-v-uplink-classifier: the state a real host presented' {
    # Captured verbatim from a runner host whose guests all booted with eth0
    # DOWN. It is the case the ladder exists for, and the one every cheaper
    # check misses: the switch still names a present, Up physical NIC, so the
    # binding LOOKS intact -- but the host's own IPv4 sits on that NIC directly
    # instead of on a vEthernet, which is only possible when the bridge is not
    # in effect. Sharing is on and Hyper-V reports no management vNIC, and that
    # pair is the whole signal.
    It 'classifies the captured record as management-os-detached' {
        $captured = Get-CapturedHostState
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord $captured.Switch -AdapterRecord @($captured.Nic) -HostIpRecord @($captured.Ip)
        Assert-Equal -Expected 'management-os-detached' -Actual $verdict 'the captured record must classify as degraded, not healthy'
    }

    It 'is missed by every rung above the management-vNIC check' {
        # Guards the ladder against being "simplified" back to the cheap checks:
        # the type is External, an uplink is named, and that uplink resolves to
        # an adapter that is Up, so nothing before the management-vNIC rung has
        # anything to report.
        $captured = Get-CapturedHostState
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord $captured.Switch -AdapterRecord @($captured.Nic) -HostIpRecord @($captured.Ip)
        foreach ($cheap in @('not-external', 'uplink-missing', 'uplink-down')) {
            Assert-NotEqual -Expected $cheap -Actual $verdict "the captured record does not trip the $cheap rung"
        }
    }

    It 'stays degraded when the management vNIC exists but never got an address' {
        # The same host one rung further along: whether Hyper-V reports no
        # management vNIC or reports one holding only APIPA, the guests have no
        # usable path either way, so both must decline the switch.
        $captured = Get-CapturedHostState
        $apipa = Get-AdapterRecord -Alias 'vEthernet (Yuruna-External)' -Description 'Hyper-V Virtual Ethernet Adapter' `
            -Status 'Up' -Mac 'A8-B8-E0-01-02-03' -Index 21
        $verdict = Invoke-UplinkVerdict -SwitchName 'Yuruna-External' `
            -SwitchRecord $captured.Switch `
            -AdapterRecord @($captured.Nic, $apipa) `
            -HostIpRecord @($captured.Ip, (Get-HostIpRecord -Address '169.254.11.22' -Alias 'vEthernet (Yuruna-External)' -Index 21))
        Assert-NotEqual -Expected 'healthy' -Actual $verdict 'an unaddressed management vNIC is not a working bridge'
    }

    It 'has a Default Switch to decline to' {
        # The companion record from the same host. Without it the reuse branches
        # must keep returning the degraded name, because New-VM throws on a
        # switch name that resolves to nothing.
        $captured = Get-CapturedHostState
        $verdict = Invoke-UplinkVerdict -SwitchName 'Default Switch' `
            -SwitchRecord $captured.DefaultSwitch -AdapterRecord @($captured.Nic) -HostIpRecord @($captured.Ip)
        Assert-Equal -Expected 'not-external' -Actual $verdict 'the Default Switch is Internal, so it is never an External candidate'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
