<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42baeedc-3176-482c-b82b-04bd087fb651
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm bounded native passive address pester
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
    Every native call the macOS driver makes is bounded, sudo never
    prompts, detached launches are never tree-killed, and the passive
    address resolver sends no Apple Event.
.DESCRIPTION
    Two kinds of case. Source scans over the driver and the macOS
    host-condition module pin the shapes a static reading can prove (no bare
    utmctl lifecycle verb, no pkill, no unscoped pgrep, sudo only with -n,
    detached launches outside the tree-killing runner). Behavioral cases run
    the real code against the stand-in host from Test.MacUtmFakeHost on any
    POSIX host; the scans alone would not establish a bound. Windows skips
    the behavioral cases because the stand-ins are /bin/sh scripts.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DriverPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
    $script:MacConditionPath = Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1'
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.MacUtmFakeHost.psm1') -Force -Global -DisableNameChecking
    $script:Driver = Get-MacUtmFakeDriver
    $script:DriverAst = [Management.Automation.Language.Parser]::ParseFile($script:DriverPath, [ref]$null, [ref]$null)
    $script:MacConditionAst = [Management.Automation.Language.Parser]::ParseFile($script:MacConditionPath, [ref]$null, [ref]$null)
    $script:CanShim = -not $IsWindows
    if ($script:CanShim) {
        $script:FakeRoot = Join-Path ([IO.Path]::GetTempPath()) ("yrn-macbound-" + [guid]::NewGuid().ToString('N'))
        $script:Fake = New-MacUtmFakeHost -Root $script:FakeRoot
    }
    $script:Skip = 'the stand-in tools are POSIX shell scripts'

    function Invoke-InDriver {
        param([scriptblock]$Body, [object[]]$Argument = @())
        return (& $script:Driver $Body @Argument)
    }
    function Get-Call { param([string]$Tool) return @(Get-MacUtmFakeCall -FakeHost $script:Fake -Tool $Tool) }
    function Set-State {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the fake host state directory.')]
        [CmdletBinding()]
        param([string]$Key, [string]$Value)
        Set-MacUtmFakeState -FakeHost $script:Fake -Key $Key -Value $Value
    }
    function Get-CommandSite {
        param($Ast, [string]$Name, [string]$Function)
        $wanted = $Name
        $scope = $Ast
        if ($Function) {
            $scope = @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true))[0]
            if (-not $scope) { throw "no function $Function" }
        }
        return @($scope.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and "$($n.CommandElements[0].Extent.Text)".Trim("'", '"') -eq $wanted }, $true))
    }
    function Get-NamedArgumentText {
        param($Command, [string]$Parameter)
        $elements = @($Command.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq $Parameter) {
                return "$($elements[$i + 1].Extent.Text)"
            }
        }
        return $null
    }

    $script:IfconfigFixture = @"
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
`tinet 192.168.7.101 netmask 0xffffff00 broadcast 192.168.7.255
bridge100: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
`tinet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
`tinet 127.0.0.1 netmask 0xff000000
"@
    $script:LeaseFixture = @"
{
`tname=yuruna-caching-proxy-service
`tip_address=192.168.64.5
`thw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:79:63:72:b7:3c:4f:7d:73
`tlease=0x6a6c58b9
}
"@
    $script:GuestMac = 'E6:01:BC:6D:21:CD'
}

AfterAll {
    if ($script:Fake) { Remove-MacUtmFakeHost -FakeHost $script:Fake }
}

Describe 'Native calls in the macOS driver are bounded (source)' {
    It 'issues no bare utmctl lifecycle verb anywhere' {
        $bare = @(Get-CommandSite -Ast $script:DriverAst -Name 'utmctl' | Where-Object {
            $_.CommandElements.Count -gt 1 -and "$($_.CommandElements[1].Extent.Text)" -in @('start', 'stop', 'delete') })
        Assert-Equal 0 $bare.Count -Because (($bare | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', ')
    }

    It 'never uses pkill, and every process match is scoped to this user' {
        Assert-Equal 0 (Get-CommandSite -Ast $script:DriverAst -Name 'pkill').Count -Because 'pkill cannot be scoped and revalidated'
        Assert-Equal 0 (Get-CommandSite -Ast $script:DriverAst -Name 'pgrep').Count -Because 'pgrep runs only through the bounded helper'
        $helper = @(Get-CommandSite -Ast $script:DriverAst -Name 'Invoke-UtmHostTool' | Where-Object { (Get-NamedArgumentText -Command $_ -Parameter 'Tool') -eq "'pgrep'" })
        Assert-True ($helper.Count -ge 1) 'the census still runs pgrep'
        foreach ($site in $helper) { Assert-Match "'-U'" (Get-NamedArgumentText -Command $site -Parameter 'ArgumentList') 'scoped with -U' }
        Assert-Equal 0 (Get-CommandSite -Ast $script:DriverAst -Name 'killall' | Where-Object { $_.Extent.Text -match 'UTM|QEMU' }).Count
    }

    It 'runs no bare helper tool in <Function>' -TestCases @(
        @{ Function = 'Wait-UtmVMPoweredOff' }, @{ Function = 'Set-VncDisplayInBundle' }, @{ Function = 'Set-GuestMacInBundle' },
        @{ Function = 'Rename-VM' }, @{ Function = 'Get-VncDisplayFromBundle' }, @{ Function = 'Get-ClaimedVncDisplay' },
        @{ Function = 'Get-UtmBundleNetwork' }, @{ Function = 'Get-UtmBridgedGuestIp' }, @{ Function = 'Resolve-UtmGuestIpByMac' },
        @{ Function = 'Start-CachingProxyServiceForwarder' }, @{ Function = 'Stop-CachingProxyServiceForwarder' },
        @{ Function = 'Get-CachingProxyServiceForwarder' }, @{ Function = 'Stop-AllCachingProxyServiceForwarder' },
        @{ Function = 'Invoke-MacElevationIfNeeded' }, @{ Function = 'Restore-SudoUserOwnership' },
        @{ Function = 'Stop-UtmDialogWatchdog' }, @{ Function = 'Stop-UtmApplication' }, @{ Function = 'Start-UtmApplication' },
        @{ Function = 'Get-UtmApplicationState' }, @{ Function = 'Get-VMStateRecord' }, @{ Function = 'Test-VirtualizationResponsive' },
        @{ Function = 'Get-VMPassiveAddress' }, @{ Function = 'Get-VMPassiveAddressContext' }, @{ Function = 'Get-PortMapTarget' }
    ) {
        param($Function)
        $forbidden = @('/usr/sbin/arp', 'arp', '/usr/libexec/PlistBuddy', 'PlistBuddy', 'plutil', 'qemu-img', '/bin/ps', 'ps',
            '/usr/bin/id', 'id', '/usr/bin/dscl', 'dscl', 'launchctl', 'pgrep', 'killall', '/bin/kill', 'kill', 'osascript', 'open', 'utmctl', 'sudo')
        $fn = @($script:DriverAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Function }, $true))
        Assert-Equal 1 $fn.Count -Because "$Function is defined once"
        $bare = @($fn[0].FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object {
            $forbidden -contains "$($_.CommandElements[0].Extent.Text)".Trim("'", '"') })
        # The one sanctioned prompt: `sudo -v`, reached only after `sudo -n -v`
        # failed and Test-YurunaCanPrompt confirmed someone can answer it.
        if ($Function -eq 'Invoke-MacElevationIfNeeded') {
            $bare = @($bare | Where-Object { $_.Extent.Text -notmatch '^&?\s*sudo -v$' })
            $text = $fn[0].Extent.Text
            Assert-True ($text.IndexOf('Test-YurunaCanPrompt') -ge 0 -and $text.IndexOf('Test-YurunaCanPrompt') -lt $text.IndexOf('& sudo -v')) 'the prompt is gated'
        }
        Assert-Equal 0 $bare.Count -Because (($bare | ForEach-Object { $_.Extent.Text }) -join ' | ')
    }

    It 'passes -n first on every sudo it runs, in the driver and the host-condition module' {
        $driverSudo = @(Get-CommandSite -Ast $script:DriverAst -Name 'Invoke-UtmHostTool' | Where-Object { (Get-NamedArgumentText -Command $_ -Parameter 'Tool') -eq "'sudo'" })
        Assert-True ($driverSudo.Count -ge 1) 'the driver elevates through the bounded helper'
        foreach ($site in $driverSudo) { Assert-Match "^\(?@\('-n'" (Get-NamedArgumentText -Command $site -Parameter 'ArgumentList') "line $($site.Extent.StartLineNumber)" }
        $conditionSudo = @(Get-CommandSite -Ast $script:MacConditionAst -Name 'Invoke-BoundedNativeCommand' | Where-Object { (Get-NamedArgumentText -Command $_ -Parameter 'FilePath') -eq "'sudo'" })
        Assert-True ($conditionSudo.Count -ge 2) 'the probe and the privileged write are both bounded'
        foreach ($site in $conditionSudo) { Assert-Match "^\(?@\('-n'" (Get-NamedArgumentText -Command $site -Parameter 'ArgumentList') "line $($site.Extent.StartLineNumber)" }
        $bareSudo = @(Get-CommandSite -Ast $script:MacConditionAst -Name 'sudo' -Function 'Test-MacSudoAvailable') + @(Get-CommandSite -Ast $script:MacConditionAst -Name 'sudo' -Function 'Invoke-MacPrivilegedSetting')
        Assert-Equal 0 $bareSudo.Count
    }

    It 'refuses at run time to run sudo without -n' {
        Assert-Throw { Invoke-InDriver { Invoke-UtmHostTool -Tool 'sudo' -ArgumentList @('-v') } }
        Assert-Throw { Invoke-InDriver { Invoke-UtmHostTool -Tool 'sudo' } }
    }

    It 'never hands a detached launch to the tree-killing runner' {
        $launch = @($script:DriverAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-UtmDetachedLaunch' }, $true))[0]
        Assert-Equal 0 @($launch.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-BoundedNativeCommand' }, $true)).Count
        Assert-True ($launch.Extent.Text -notmatch '\.Kill\(') 'nothing it started is killed'
        foreach ($function in @('Start-UtmDialogWatchdog', 'Start-CachingProxyServiceForwarder')) {
            Assert-True ((Get-CommandSite -Ast $script:DriverAst -Name 'Start-Process' -Function $function).Count -ge 1) "$function spawns detached"
            Assert-Equal 0 (Get-CommandSite -Ast $script:DriverAst -Name 'Invoke-BoundedNativeCommand' -Function $function).Count -Because $function
        }
        $openThroughRunner = @(Get-CommandSite -Ast $script:DriverAst -Name 'Invoke-UtmHostTool' | Where-Object { (Get-NamedArgumentText -Command $_ -Parameter 'Tool') -eq "'open'" })
        Assert-Equal 0 $openThroughRunner.Count
        foreach ($function in @('Start-UtmVM', 'Start-UtmApplication')) {
            Assert-True ((Get-CommandSite -Ast $script:DriverAst -Name 'Start-UtmDetachedLaunch' -Function $function).Count -eq 1) "$function launches through the detached helper"
        }
    }
}

Describe 'Invoke-UtmctlLifecycle (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'applies each verb''s default cap and reports a known outcome' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'vm1' -Status 'stopped'
        Assert-Equal 300 (Invoke-UtmctlLifecycle -Verb 'start' -VMName 'vm1').TimeoutSeconds
        Assert-Equal 120 (Invoke-UtmctlLifecycle -Verb 'stop' -VMName 'vm1').TimeoutSeconds
        $kill = Invoke-UtmctlLifecycle -Verb 'stop' -VMName 'vm1' -Kill
        Assert-Equal 60 $kill.TimeoutSeconds
        Assert-True $kill.OutcomeKnown
        Assert-StringEqual 'none' $kill.FailureKind
        Assert-Equal 120 (Invoke-UtmctlLifecycle -Verb 'delete' -VMName 'vm1').TimeoutSeconds
        Assert-StringEqual 'utmctl start vm1|utmctl stop vm1|utmctl stop vm1 --kill|utmctl delete vm1' ((Get-Call 'utmctl') -join '|')
    }

    It 'bounds a hung verb and marks its outcome unknown' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'stop.mode' 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-UtmctlLifecycle -Verb 'stop' -VMName 'vm1' -TimeoutSeconds 1 -WarningVariable warned -WarningAction SilentlyContinue
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-True $r.TimedOut
        Assert-False $r.OutcomeKnown 'a timed-out verb has an unknown effect'
        Assert-Equal 1 @($warned).Count -Because 'the timeout is reported'
        $quiet = Invoke-UtmctlLifecycle -Verb 'stop' -VMName 'vm1' -TimeoutSeconds 1 -Quiet -WarningVariable quietWarned -WarningAction SilentlyContinue
        Assert-True $quiet.TimedOut
        Assert-Equal 0 @($quietWarned).Count -Because '-Quiet suppresses it'
    }

    It 'launches nothing with under one second left' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $r = Invoke-UtmctlLifecycle -Verb 'start' -VMName 'vm1' -Deadline (New-YurunaDeadline -TotalMilliseconds 400) -Quiet
        Assert-True $r.DeadlineExhausted
        Assert-False $r.Started
        Assert-False $r.OutcomeKnown
        Assert-Equal 0 (Get-Call 'utmctl').Count
    }

    It 'classifies an Apple Event refusal at exit 0' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'start.mode' 'deny'
        $r = Invoke-UtmctlLifecycle -Verb 'start' -VMName 'vm1'
        Assert-Equal 0 $r.ExitCode
        Assert-StringEqual 'apple-event' $r.FailureKind
        Assert-Match '-1743' $r.Text
    }

    It 'refuses -Kill with a verb other than stop' {
        Assert-Throw { Invoke-UtmctlLifecycle -Verb 'start' -VMName 'vm1' -Kill }
        Assert-Throw { Invoke-UtmctlLifecycle -Verb 'delete' -VMName 'vm1' -Kill }
    }
}

Describe 'The UTM state record and inventory tell failure from absence' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'reads <Mode> as <State>/<Registration>/<Reason>' -TestCases @(
        @{ Mode = 'registry';      Registered = $true;  State = 'stopped'; Registration = 'Registered'; Reason = 'observed' }
        @{ Mode = 'registry';      Registered = $false; State = 'absent';  Registration = 'Absent';     Reason = 'not-found' }
        @{ Mode = 'oserr-nonzero'; Registered = $true;  State = 'unknown'; Registration = 'Unknown';    Reason = 'provider-error' }
        @{ Mode = 'deny-exit0';    Registered = $true;  State = 'unknown'; Registration = 'Unknown';    Reason = 'permission-denied' }
        @{ Mode = 'garbage';       Registered = $true;  State = 'unknown'; Registration = 'Registered'; Reason = 'invalid-response' }
        @{ Mode = 'hang';          Registered = $true;  State = 'unknown'; Registration = 'Unknown';    Reason = 'timeout' }
    ) {
        param($Mode, $Registered, $State, $Registration, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        if ($Registered) { Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'vm1' -Status 'suspended' }
        Set-State 'status.mode' $Mode
        $r = Get-VMStateRecord -VMName 'vm1' -TimeoutSeconds 1 -WarningAction SilentlyContinue
        Assert-StringEqual $State $r.State
        Assert-StringEqual $Registration $r.Registration
        Assert-StringEqual $Reason $r.Reason
        if ($Mode -ne 'hang') {
            Assert-StringEqual $State (Get-VMState -VMName 'vm1') -Because 'Get-VMState reads the same record'
            Assert-StringEqual $Registration (Get-UtmVMRegistrationState -VMName 'vm1') -Because 'so does the registration'
        }
    }

    It 'reads a missing client as unknown, never absent' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Exit-MacUtmFakeHost -FakeHost $script:Fake
        Enter-MacUtmFakeHost -FakeHost $script:Fake -Utmctl 'missing'
        $r = Get-VMStateRecord -VMName 'vm1'
        Assert-StringEqual 'unknown' $r.State
        Assert-StringEqual 'missing-client' $r.Reason
        Assert-StringEqual 'Unknown' (Get-UtmVMRegistrationState -VMName 'vm1')
    }

    It 'tells a failed listing (<Mode>) from an empty one' -TestCases @(
        @{ Mode = 'deny'; Listed = $false; Reason = 'permission-denied' }
        @{ Mode = 'empty'; Listed = $false; Reason = 'invalid-response' }
        @{ Mode = 'header'; Listed = $true; Reason = 'listed' }
    ) {
        param($Mode, $Listed, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'list.mode' $Mode
        $inventory = Get-UtmRunningVmInventory
        Assert-Equal $Listed $inventory.Listed
        Assert-StringEqual $Reason $inventory.Reason
        Assert-Equal 0 @(Get-RunningVmName).Count -Because 'the wrapper still emits nothing in either case'
    }
}

Describe 'The passive address resolver (host.macos.utm)' {
    BeforeEach {
        if ($script:CanShim) {
            Reset-MacUtmFakeHost -FakeHost $script:Fake
            Enter-MacUtmFakeHost -FakeHost $script:Fake
            Set-State 'ifconfig.txt' $script:IfconfigFixture
            Set-State 'dhcpd_leases' $script:LeaseFixture
        }
    }
    AfterEach {
        if ($script:CanShim) {
            Assert-Equal 0 (Get-Call 'utmctl').Count -Because 'no Apple Event from the passive resolver'
            Assert-Equal 0 (Get-Call 'osascript').Count -Because 'no Apple Event from the passive resolver'
            Exit-MacUtmFakeHost -FakeHost $script:Fake
        }
    }

    It 'corroborates a shared-NAT lease with the ARP row carrying the bundle MAC' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-caching-proxy-service' -Unregistered -WithBundle -Mode 'Shared' -MacAddress $script:GuestMac
        Set-State 'arp.txt' '? (192.168.64.5) at e6:1:bc:6d:21:cd on bridge100 ifscope [ethernet]'
        $context = Get-VMPassiveAddressContext -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual 'Yuruna.PassiveAddressContext' $context.PSObject.TypeNames[0]
        Assert-StringEqual 'ok' $context.ArpReason
        Assert-StringEqual 'captured' $context.LeaseReason
        Assert-StringEqual $script:GuestMac $context.ArpMap['192.168.64.5']
        $r = Get-VMPassiveAddress -VMName 'yuruna-caching-proxy-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual '192.168.64.5' $r.Address
        Assert-StringEqual 'shared-lease' $r.Origin
        Assert-StringEqual 'ok' $r.Reason
        Assert-True $r.MacCorroborated
        Assert-StringEqual 'Shared' $r.NetworkMode
        Assert-StringEqual $script:GuestMac $r.BundleMac
    }

    It 'reports a lease with no ARP corroboration as lease-only, with no address' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-caching-proxy-service' -Unregistered -WithBundle -Mode 'Shared' -MacAddress $script:GuestMac
        Set-State 'arp.txt' '? (192.168.64.9) at aa:bb:cc:dd:ee:ff on bridge100 ifscope [ethernet]'
        $context = Get-VMPassiveAddressContext -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        $r = Get-VMPassiveAddress -VMName 'yuruna-caching-proxy-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-Null $r.Address 'a DUID-keyed lease is a candidate, not proof'
        Assert-StringEqual 'lease-only' $r.Reason
        Assert-StringEqual 'none' $r.Origin
        $detail = Resolve-UtmGuestAddressPassive -VMName 'yuruna-caching-proxy-service' -ArpLine @('? (192.168.64.9) at aa:bb:cc:dd:ee:ff on bridge100') -LeaseText $script:LeaseFixture -OnLinkVerdict { param($ip) $null = $ip; 'onlink' }
        Assert-StringEqual 'lease-candidate' $detail.Source
        Assert-StringEqual '192.168.64.5' $detail.LeaseCandidate
    }

    It 'finds a bridged guest by its bundle MAC on an on-link row' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Unregistered -WithBundle -Mode 'Bridged' -MacAddress $script:GuestMac
        Set-State 'arp.txt' "? (10.211.55.3) at e6:1:bc:6d:21:cd on bridge101 ifscope [ethernet]`n? (192.168.7.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]"
        $context = Get-VMPassiveAddressContext -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        $r = Get-VMPassiveAddress -VMName 'yuruna-stash-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual '192.168.7.51' $r.Address -Because 'the offlink copy of the MAC is not where the guest is'
        Assert-StringEqual 'arp' $r.Origin
        Assert-StringEqual 'Bridged' $r.NetworkMode
    }

    It 'misses rather than guesses: <Case>' -TestCases @(
        @{ Case = 'offlink row only'; Arp = '? (10.211.55.3) at e6:1:bc:6d:21:cd on bridge101 ifscope [ethernet]'; Reason = 'arp-miss' }
        @{ Case = 'two onlink rows';  Arp = "? (192.168.7.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]`n? (192.168.7.52) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]"; Reason = 'ambiguous-arp' }
        @{ Case = 'conflicting row';  Arp = "? (192.168.7.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]`n? (192.168.7.51) at 11:22:33:44:55:66 on en1 ifscope [ethernet]"; Reason = 'arp-miss' }
    ) {
        param($Case, $Arp, $Reason)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Unregistered -WithBundle -Mode 'Bridged' -MacAddress $script:GuestMac
        Set-State 'arp.txt' $Arp
        $context = Get-VMPassiveAddressContext -ArpOnly -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual 'skipped' $context.LeaseReason
        $r = Get-VMPassiveAddress -VMName 'yuruna-stash-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-Null $r.Address $Case
        Assert-StringEqual $Reason $r.Reason $Case
        if ($Case -eq 'conflicting row') { Assert-True ($context.ArpConflict -contains '192.168.7.51') 'the conflict is named' }
    }

    It 'reports a guest with no bundle as no-bundle' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $context = Get-VMPassiveAddressContext -Deadline (New-YurunaDeadline -TotalMilliseconds 20000) -ArpLine @() -LeaseText ''
        Assert-StringEqual 'injected' $context.ArpReason
        Assert-StringEqual 'injected' $context.LeaseReason
        $r = Get-VMPassiveAddress -VMName 'no-such-guest' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual 'no-bundle' $r.Reason
    }

    It 'bounds a hung ARP read and falls back to a tool-failed or lease-only verdict' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Unregistered -WithBundle -Mode 'Bridged' -MacAddress $script:GuestMac
        Set-State 'arp.mode' 'hang'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $table = Get-UtmArpTable -Deadline (New-YurunaDeadline -TotalMilliseconds 2500)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 5) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-False $table.Captured
        Assert-StringEqual 'timeout' $table.Reason
        $context = Get-VMPassiveAddressContext -ArpOnly -Deadline (New-YurunaDeadline -TotalMilliseconds 2500)
        Assert-StringEqual 'timeout' $context.ArpReason
        $r = Get-VMPassiveAddress -VMName 'yuruna-stash-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-StringEqual 'tool-failed' $r.Reason
    }

    It 'reports an ARP table the context had no time to read as deadline-exhausted, not tool-failed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'yuruna-stash-service' -Unregistered -WithBundle -Mode 'Bridged' -MacAddress $script:GuestMac
        Set-State 'arp.txt' '? (192.168.7.51) at e6:1:bc:6d:21:cd on en0 ifscope [ethernet]'
        $context = Get-VMPassiveAddressContext -ArpOnly -Deadline (New-YurunaDeadline -TotalMilliseconds 300)
        Assert-StringEqual 'deadline-exhausted' $context.ArpReason
        Assert-Equal 0 (Get-Call 'arp').Count -Because 'nothing is launched without a usable second'
        $r = Get-VMPassiveAddress -VMName 'yuruna-stash-service' -Context $context -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-Null $r.Address
        Assert-StringEqual 'deadline-exhausted' $r.Reason
    }

    It 'judges on-link from one bounded ifconfig read' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $evidence = Get-UtmHostSubnetEvidence -Deadline (New-YurunaDeadline -TotalMilliseconds 20000)
        Assert-True $evidence.Captured
        Assert-Equal 2 $evidence.Subnet.Count -Because 'loopback is excluded'
        Assert-StringEqual 'onlink' (& $evidence.OnLinkVerdict '192.168.64.77')
        Assert-StringEqual 'onlink' (& $evidence.OnLinkVerdict '192.168.7.9')
        Assert-StringEqual 'offlink' (& $evidence.OnLinkVerdict '10.211.55.3')
        Assert-Equal 1 (Get-Call 'ifconfig').Count
        Set-State 'ifconfig.mode' 'hang'
        $failed = Get-UtmHostSubnetEvidence -Deadline (New-YurunaDeadline -TotalMilliseconds 2500)
        Assert-False $failed.Captured
        Assert-StringEqual 'unknown' (& $failed.OnLinkVerdict '192.168.64.77') -Because 'no evidence is never offlink'
    }

    It 'reads the forwarder mappings as zero, one or many typed rows' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Assert-Equal 0 @(Get-PortMapTarget).Count
        $dir = Join-Path $script:Fake.Home 'yuruna/image/caching-proxy-service'
        $null = New-Item -ItemType Directory -Force -Path $dir
        [IO.File]::WriteAllText((Join-Path $dir 'forwarder.3128.pid'), "900`n")
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 900 -Name 'pwsh' -Command '/usr/local/bin/pwsh -NoProfile -NoLogo -File /x/Start-CachingProxyServiceForwarder.ps1 -CacheIp 192.168.64.5 -Port 3128 -VMPort 3128 -PidFile /x/p -LogFile /x/l'
        $one = @(Get-PortMapTarget)
        Assert-Equal 1 $one.Count
        Assert-StringEqual 'Yuruna.PortMapTarget' $one[0].PSObject.TypeNames[0]
        Assert-Equal 3128 $one[0].HostPort
        Assert-StringEqual '192.168.64.5' $one[0].TargetAddress
        Assert-Equal 3128 $one[0].TargetPort
        Assert-True $one[0].OwnerVerified
        Assert-StringEqual 'forwarder-pidfile' $one[0].Origin
        [IO.File]::WriteAllText((Join-Path $dir 'forwarder.8022.pid'), "901`n")
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 901 -Name 'pwsh' -Command '/usr/local/bin/pwsh -File /x/Start-CachingProxyServiceForwarder.ps1 -CacheIp 192.168.64.5 -Port 8022 -VMPort 22'
        [IO.File]::WriteAllText((Join-Path $dir 'forwarder.80.pid'), "902`n")
        $many = @(Get-PortMapTarget)
        Assert-Equal 3 $many.Count
        $ssh = @($many | Where-Object { $_.HostPort -eq 8022 })[0]
        Assert-Equal 22 $ssh.TargetPort
        $dead = @($many | Where-Object { $_.HostPort -eq 80 })[0]
        Assert-False $dead.OwnerVerified 'a pidfile whose process is gone is reported, unverified'
        Assert-Equal 0 (Get-Call 'kill').Count -Because 'read-only'
    }
}

Describe 'Test.HostCondition.Mac native calls are bounded' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'Test-MacSudoAvailable answers <Mode> as <Expected> within its bound' -TestCases @(
        @{ Mode = 'ok'; Expected = $true }, @{ Mode = 'deny'; Expected = $false }, @{ Mode = 'hang'; Expected = $false }
    ) {
        param($Mode, $Expected)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'sudo.mode' $Mode
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Assert-Equal $Expected (Test-MacSudoAvailable -TimeoutSeconds 1)
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-StringEqual 'sudo -n true' ((Get-Call 'sudo') -join '|')
    }

    It 'Invoke-MacPrivilegedSetting runs sudo -n and reports <Mode>' -TestCases @(
        @{ Mode = 'ok'; Expected = $true; Warned = 0 }, @{ Mode = 'deny'; Expected = $false; Warned = 1 }, @{ Mode = 'hang'; Expected = $false; Warned = 1 }
    ) {
        param($Mode, $Expected, $Warned)
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-State 'sudo.mode' $Mode
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # Module-private: reached through the module's own scope.
        $condition = Get-Module -Name 'Test.HostCondition.Mac' | Select-Object -First 1
        $run = & $condition {
            $emitted = Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', 'sleep', '0') -TimeoutSeconds 1 -WarningVariable seen -WarningAction SilentlyContinue
            [pscustomobject]@{ Ok = $emitted; Warned = @($seen).Count }
        }
        Assert-Equal $Expected $run.Ok
        Assert-True ($sw.Elapsed.TotalSeconds -lt 4) "bounded ($($sw.Elapsed.TotalSeconds) s)"
        Assert-Equal $Warned $run.Warned
        Assert-StringEqual 'sudo -n pmset -a sleep 0' ((Get-Call 'sudo') -join '|')
    }

    It 'Invoke-MacBoundedTool reports the exit code: answered, timed out, not started' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $answered = Invoke-MacBoundedTool -Tool 'launchctl' -Arguments @('managername') -TimeoutSeconds 2
        Assert-Equal 0 $answered.ExitCode
        Assert-StringEqual 'Aqua' $answered.Text
        Set-State 'launchctl.mode' 'hang'
        $hung = Invoke-MacBoundedTool -Tool 'launchctl' -Arguments @('managername') -TimeoutSeconds 1 -WarningAction SilentlyContinue
        Assert-Equal 124 $hung.ExitCode
        Assert-True $hung.TimedOut
        $missing = Invoke-MacBoundedTool -Tool 'no-such-tool-for-this-case' -TimeoutSeconds 1
        Assert-Equal (-1) $missing.ExitCode
        Assert-False $missing.Started
    }

    It 'bounds the Automation grant prompt through the bounded tool runner' {
        $grant = @(Get-MacOperatorGrant -Id 'AutomationUtm')[0]
        Assert-Null $grant.Probe 'the grant is deliberately never read'
        $promptAst = $grant.Prompt.Ast
        $commands = @($promptAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { "$($_.CommandElements[0].Extent.Text)" })
        Assert-True ($commands -notcontains 'utmctl') 'no bare utmctl'
        $bounded = @($promptAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-MacBoundedTool' }, $true))
        Assert-Equal 1 $bounded.Count
        Assert-True ($null -ne (Get-NamedArgumentText -Command $bounded[0] -Parameter 'TimeoutSeconds')) 'with an explicit cap'
    }
}
