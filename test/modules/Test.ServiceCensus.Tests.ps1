<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42875271-1829-42b3-b731-1d7a16616cfd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service census intent lock beacon pester
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
    Test.ServiceCensus: the census store, start/stop intents, per-service
    operation locks, identity capture, the passive beacon tick and the
    capability table.
.DESCRIPTION
    Every case works in a private state root under TestDrive; nothing reads
    or writes the operator's $HOME/.yuruna. Cross-process cases spawn
    disposable pwsh children that import the module from this checkout and
    synchronize through barrier files, so a lock is proven held by another
    process while the test contends for it. Driver commands are global
    stand-ins that record their calls; the passive resolver is faked the
    same way, and every forbidden control-channel command is defined as a
    counting trap to prove the census never reaches one.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $script:CensusModule = Join-Path $here 'Test.ServiceCensus.psm1'
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $script:CensusModule -Force -DisableNameChecking -Global
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.CriticalRecord.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.ExtensionService.psm1') -DisableNameChecking -Global
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -DisableNameChecking -Global
    $script:Pwsh = (Get-Command -Name pwsh).Source

    $script:ForbiddenName = @('Get-VMIp', 'Get-VMState', 'Get-VMStateRecord', 'Get-RunningVmName', 'Get-VMName',
        'Test-UtmctlResponsive', 'Invoke-UtmctlProbe', 'Test-VirtualizationResponsive', 'Get-YurunaServiceVmAddress',
        'Get-UtmBridgedGuestIp', 'Get-UtmAgentReportedIp', 'Resolve-UtmGuestIpByMac', 'utmctl', 'osascript', 'Start-VM', 'Stop-VM')

    function New-CensusRoot {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixture: builds private state under TestDrive only.')]
        [CmdletBinding()]
        param()
        $root = Join-Path $TestDrive ('census-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $root -Force
        $runtime = Join-Path $root 'runtime'
        $null = New-Item -ItemType Directory -Path $runtime -Force
        [pscustomobject]@{ StateRoot = $root; RuntimeDir = $runtime; Record = (Join-Path $root 'service-census.record') }
    }

    function Get-RootListing {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) { return '<absent>' }
        return (@(Get-ChildItem -LiteralPath $Path -Force -Recurse | ForEach-Object { $_.FullName.Substring($Path.Length) } | Sort-Object) -join '|')
    }

    function Get-FreeLoopbackPort {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        try { return ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port } finally { $probe.Stop() }
    }

    function Wait-ForFile {
        param([string]$Path, [int]$TimeoutMilliseconds = 30000)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
            if ([System.IO.File]::Exists($Path)) { return $true }
            Start-Sleep -Milliseconds 50
        }
        return $false
    }

    # A disposable pwsh child that imports the census module from this
    # checkout, runs one scenario, signals Ready, waits (bounded) for
    # Release, and writes what happened to Result.
    $script:ChildScript = @'
param([string]$ModulePath, [string]$StateRoot, [string]$Ready, [string]$Release, [string]$Result, [string]$Mode, [int]$Count = 1)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -DisableNameChecking
$waitRelease = {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not [System.IO.File]::Exists($Release) -and $sw.ElapsedMilliseconds -lt 60000) { Start-Sleep -Milliseconds 50 }
}
$out = [ordered]@{ Mode = $Mode }
switch ($Mode) {
    'hold-lock' {
        $ctx = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $StateRoot -Confirm:$false
        $out.Held = [bool]$ctx.Held
        Set-Content -LiteralPath $Ready -Value 'ready'
        & $waitRelease
        Exit-YurunaServiceOperationLockSet -Context $ctx
    }
    'hold-start' {
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -Script 'child-start' -StateRoot $StateRoot -Confirm:$false
        $out.Proceed = [bool]$op.Proceed
        $out.Generation = [long]$op.Generation
        Set-Content -LiteralPath $Ready -Value 'ready'
        & $waitRelease
        $exit = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false 3>$null
        $out.ExitResult = [string]$exit.Result
    }
    'stop-wait' {
        Set-Content -LiteralPath $Ready -Value 'ready'
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -Script 'child-stop' -WaitSeconds 30 -StateRoot $StateRoot -Confirm:$false
        $out.Proceed = [bool]$op.Proceed
        $out.Reason = [string]$op.Reason
        $out.Generation = [long]$op.Generation
        $out.NewerOperation = [string]$op.NewerOperation
        if ($op.Proceed) { $null = Exit-YurunaServiceOperation -Context $op -Result failed -Confirm:$false }
    }
    'intent-loop' {
        Set-Content -LiteralPath $Ready -Value 'ready'
        $published = 0
        for ($i = 0; $i -lt $Count; $i++) {
            $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -Script 'child-loop' -WaitSeconds 30 -StateRoot $StateRoot -Confirm:$false
            if ($op.Proceed) {
                $published++
                $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false
            }
        }
        $out.Published = $published
    }
}
$json = ConvertTo-Json -InputObject $out -Compress
[System.IO.File]::WriteAllText($Result, $json)
'@

    function Invoke-CensusChild {
        param([string]$StateRoot, [string]$Mode, [int]$Count = 1)
        $dir = Join-Path $TestDrive ('child-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $dir -Force
        $scriptPath = Join-Path $dir 'child.ps1'
        [System.IO.File]::WriteAllText($scriptPath, $script:ChildScript)
        $paths = [pscustomobject]@{
            Ready = (Join-Path $dir 'ready'); Release = (Join-Path $dir 'release'); Result = (Join-Path $dir 'result.json')
            Process = $null
        }
        $argumentList = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ModulePath', $script:CensusModule,
            '-StateRoot', $StateRoot, '-Ready', $paths.Ready, '-Release', $paths.Release, '-Result', $paths.Result, '-Mode', $Mode, '-Count', "$Count")
        $paths.Process = Start-Process -FilePath $script:Pwsh -ArgumentList $argumentList -PassThru -RedirectStandardError (Join-Path $dir 'stderr.txt') -RedirectStandardOutput (Join-Path $dir 'stdout.txt')
        return $paths
    }

    function Complete-CensusChild {
        param($Child, [int]$TimeoutMilliseconds = 60000)
        if (-not [System.IO.File]::Exists($Child.Release)) { Set-Content -LiteralPath $Child.Release -Value 'go' }
        if (-not $Child.Process.WaitForExit($TimeoutMilliseconds)) {
            Stop-Process -Id $Child.Process.Id -Force -ErrorAction SilentlyContinue
            throw 'the disposable child did not finish in time'
        }
        if (-not [System.IO.File]::Exists($Child.Result)) { throw "the disposable child wrote no result: $(Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $Child.Result) 'stderr.txt') -ErrorAction SilentlyContinue)" }
        return (Get-Content -Raw -LiteralPath $Child.Result | ConvertFrom-Json)
    }

    function Publish-TestIntent {
        # A direct intent publication through the module's own writer, used
        # where a test must record a newer intent while it holds the lock a
        # script would otherwise need.
        param([string]$Root, [string]$Key, [string]$Operation, [string]$VMName)
        & (Get-Module Test.ServiceCensus) {
            param($Root, $Key, $Operation, $VMName)
            $mutation = {
                param($State, $Output, $Argument)
                $Output.Output = Publish-ServiceIntent -State $State -Key $Argument.Key -Operation $Argument.Operation -VMName $Argument.VMName `
                    -HostingMode 'vm' -Script 'test' -NowUnixMs (Get-ServiceCensusUtcNow) -ProcessStartUnixMs 0
                return $true
            }
            Invoke-ServiceCensusMutation -Root $Root -Mutation $mutation -Argument @{ Key = $Key; Operation = $Operation; VMName = $VMName } -LockWaitMilliseconds 5000
        } $Root $Key $Operation $VMName
    }

    $script:Passive = @{
        Enabled = $false
        ContextCalls = [System.Collections.Generic.List[object]]::new()
        AddressCalls = [System.Collections.Generic.List[string]]::new()
        Address = @{}
        ArpMap = @{}
        Subnet = [pscustomobject]@{ HostIp = '192.168.64.1'; SubnetPrefix = '192.168.64.'; Reason = 'injected' }
        ContextDelayMs = 0
        PortMap = $null
    }
    function Install-PassiveResolver {
        $script:Passive.ContextCalls.Clear()
        $script:Passive.AddressCalls.Clear()
        $script:Passive.Address = @{}
        $script:Passive.ArpMap = @{}
        $script:Passive.ContextDelayMs = 0
        function global:Get-VMPassiveAddressContext {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in with the driver''s signature; the lease and ARP injections are not needed to answer.')]
            param([AllowNull()]$Deadline, [switch]$ArpOnly, [string[]]$ArpLine, [string]$LeaseText, $SubnetEvidence)
            $script:Passive.ContextCalls.Add([pscustomobject]@{ ArpOnly = [bool]$ArpOnly; SubnetEvidence = $SubnetEvidence })
            if ($script:Passive.ContextDelayMs -gt 0 -and $Deadline) {
                $sleep = [Math]::Min([long]$script:Passive.ContextDelayMs, (Get-YurunaDeadlineRemainingMs -Deadline $Deadline))
                if ($sleep -gt 0) { Start-Sleep -Milliseconds $sleep }
            }
            [pscustomobject]@{
                PSTypeName = 'Yuruna.PassiveAddressContext'; ArpMap = $script:Passive.ArpMap; ArpReason = 'injected'
                LeaseText = ''; LeaseReason = 'skipped'; SubnetEvidence = $script:Passive.Subnet; ObservedUnixMs = 0
            }
        }
        function global:Get-VMPassiveAddress {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in with the driver''s signature; context and deadline are not needed to answer.')]
            param([string]$VMName, $Context, $Deadline)
            $script:Passive.AddressCalls.Add($VMName)
            if ($script:Passive.Address.ContainsKey($VMName)) { return $script:Passive.Address[$VMName] }
            [pscustomobject]@{ VMName = $VMName; Address = $null; Origin = 'none'; BundlePath = ''; BundleMac = ''; NetworkMode = ''
                MacCorroborated = $false; Reason = 'arp-miss'; ElapsedMs = 1 }
        }
    }
    function Uninstall-PassiveResolver {
        foreach ($name in @('Get-VMPassiveAddressContext', 'Get-VMPassiveAddress', 'Get-PortMapTarget')) {
            Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue
        }
    }

    $script:Trap = @{ Calls = [System.Collections.Generic.List[string]]::new() }
    function Install-ForbiddenTrap {
        $script:Trap.Calls.Clear()
        foreach ($name in $script:ForbiddenName) {
            $recorded = $name
            Set-Item -Path "Function:\global:$name" -Value ({ $script:Trap.Calls.Add($recorded); $null }.GetNewClosure())
        }
    }
    function Uninstall-ForbiddenTrap {
        foreach ($name in $script:ForbiddenName) { Remove-Item -Path "Function:\$name" -Force -ErrorAction SilentlyContinue }
    }

    $script:StashRoster = {
        param([int]$HealthPort)
        @([pscustomobject]@{ Key = 'stash'; Area = 'stash-service'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'
                HealthPort = $HealthPort; StartScript = 'Start-StashServiceVM.ps1'; StopScript = 'Stop-StashServiceVM.ps1' })
    }
}

AfterAll {
    Uninstall-PassiveResolver
    Uninstall-ForbiddenTrap
}

Describe 'the census store' {
    BeforeEach { $script:Env = New-CensusRoot }

    It 'reads an absent census as valid and empty, creating nothing' {
        $before = Get-RootListing -Path $script:Env.StateRoot
        $c = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
        $c.Valid | Should -BeTrue
        $c.Present | Should -BeFalse
        $c.Reason | Should -Be 'absent'
        $c.EvidenceLifetimeSeconds | Should -Be 86400
        $c.EvidenceLifetimeOrigin | Should -Be 'default'
        Get-RootListing -Path $script:Env.StateRoot | Should -Be $before
        $missing = Join-Path $TestDrive 'no-such-root'
        (Read-YurunaServiceCensus -StateRoot $missing).Reason | Should -Be 'absent'
        Test-Path -LiteralPath $missing | Should -BeFalse -Because 'a reader never creates the root'
    }

    It 'never overwrites a corrupt census, and every mutator refuses on it' {
        [System.IO.File]::WriteAllText($script:Env.Record, "not a record`n")
        $bytes = [System.IO.File]::ReadAllBytes($script:Env.Record)
        (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Reason | Should -Be 'corrupt'
        $merge = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'timeout' }) -Confirm:$false
        $merge.Reason | Should -Be 'corrupt'
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $op.Proceed | Should -BeFalse
        $op.Reason | Should -Be 'census-corrupt'
        $op.Message | Should -Not -BeNullOrEmpty
        $start = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $start.Proceed | Should -BeFalse
        $start.Reason | Should -Be 'census-corrupt'
        $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false
        $tick.Reason | Should -Be 'census-corrupt'
        [System.IO.File]::ReadAllBytes($script:Env.Record) | Should -Be $bytes -Because 'an unreadable census is evidence of something, never overwritten'
        (Get-YurunaSingleFlightLockState -Path (Join-Path $script:Env.StateRoot 'service-operation.stash.lock')).State | Should -BeIn @('free', 'absent') -Because 'a refused start releases the lock it took'
    }

    It 'tells a census it cannot read just now from a damaged one, and refuses on it without touching it' {
        Mock -ModuleName Test.ServiceCensus Format-YurunaOperatorMessage { "$Key|$(if ($Arguments) { $Arguments['reason'] })" }
        # A directory where the record belongs reads as an I/O failure, which
        # says nothing about any content.
        $null = New-Item -ItemType Directory -Path $script:Env.Record -Force
        $c = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Be 'unreadable'
        $c.Detail | Should -Be 'io-error'
        (Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'timeout' }) -Confirm:$false).Reason | Should -Be 'unreadable'
        foreach ($operation in @('Stop', 'Start')) {
            $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation $operation -WaitSeconds 0 -StateRoot $script:Env.StateRoot -Confirm:$false
            $op.Proceed | Should -BeFalse
            $op.Reason | Should -Be 'census-unreadable' -Because 'a read that failed is worth retrying, unlike a damaged record'
            $op.Detail | Should -Be 'io-error'
            $op.Message | Should -Be 'runner.service_census_unreadable|io-error'
        }
        (Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false).Reason | Should -Be 'census-unreadable'
        @(Get-ChildItem -LiteralPath $script:Env.Record -Force).Count | Should -Be 0 -Because 'nothing was written in its place'
        (Get-YurunaSingleFlightLockState -Path (Join-Path $script:Env.StateRoot 'service-operation.stash.lock')).State | Should -BeIn @('free', 'absent')

        # A read the deadline cut short is unreadable too, never corrupt.
        $readable = New-CensusRoot
        $null = Update-YurunaServiceCensusObservation -StateRoot $readable.StateRoot -Observation @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'refused' }) -Confirm:$false
        $spent = New-YurunaDeadline -TotalMilliseconds 0
        $late = Read-YurunaServiceCensus -StateRoot $readable.StateRoot -Deadline $spent
        $late.Reason | Should -Be 'unreadable'
        $late.Detail | Should -Be 'io-timeout'
        (Read-YurunaServiceCensus -StateRoot $readable.StateRoot).Reason | Should -Be 'ok'
    }

    It 'refuses a census written by a newer schema' {
        $payload = @{ schemaVersion = 2; intentCounter = 0; services = @{} }
        $w = Write-YurunaCriticalRecord -Path $script:Env.Record -Kind 'service-census' -Payload $payload -ExpectedGeneration 0 -Confirm:$false
        $w.Committed | Should -BeTrue
        $c = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
        $c.Valid | Should -BeFalse
        $c.Reason | Should -Be 'unsupported-version'
    }

    It 'keeps a one-entry history an array and timestamps exact across a round trip' {
        foreach ($operation in @('Stop', 'Start')) {
            $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation $operation -StateRoot $script:Env.StateRoot -Confirm:$false
            $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false
        }
        $observed = [long]1790000000123
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'refused'; ObservedUnixMs = $observed })
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
        ,$svc.history | Should -BeOfType [object[]]
        @($svc.history).Count | Should -Be 1
        $svc.history[0].operation | Should -Be 'stop'
        $svc.lastProbeUnixMs | Should -BeOfType [long]
        $svc.lastProbeUnixMs | Should -Be $observed -Because 'authoritative instants are numbers; nothing drifts with the host time zone'
    }

    It 'expires evidence after the lifetime without touching the desired state' {
        $t0 = [long]1790000000000
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -NowUnixMs $t0 -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; Answered = $true; AnsweredIdentity = 'mac-corroborated'
                AnsweredAddress = '192.168.64.9'; ProbeOutcome = 'answered'; ObservedUnixMs = $t0 })
        $fresh = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 + 60000)).Services['stash']
        $fresh.evidenceFresh | Should -BeTrue
        $fresh.evidenceAgeSeconds | Should -Be 60
        $stale = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 + 86401000)).Services['stash']
        $stale.evidenceFresh | Should -BeFalse -Because 'expired evidence is unknown'
        $stale.desiredState | Should -Be 'running' -Because 'desired state never expires with health evidence'
        $behind = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 - 5000)).Services['stash']
        $behind.evidenceAgeSeconds | Should -Be 0 -Because 'a clock behind the evidence counts as age zero'
        (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 + 7200000) -EvidenceLifetimeSeconds 3600).Services['stash'].evidenceFresh | Should -BeFalse
    }

    It 'merges observations monotonically: a timeout never clears an earlier positive' {
        $t0 = [long]1790000000000
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; Address = '10.0.0.5'; AddressOrigin = 'arp'; AddressResolvedUnixMs = $t0
                BundleMac = 'AA:BB:CC:DD:EE:01'; MacCorroborated = $true; Answered = $true; AnsweredIdentity = 'mac-corroborated'; AnsweredAddress = '10.0.0.5'
                ProbeOutcome = 'answered'; ObservedUnixMs = $t0 })
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; Address = '10.0.0.99'; AddressOrigin = 'arp'; AddressResolvedUnixMs = ($t0 - 1)
                ProbeOutcome = 'timeout'; ObservedUnixMs = ($t0 + 400000) })
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 + 400000)).Services['stash']
        $svc.lastAnsweredUnixMs | Should -Be $t0
        $svc.lastProbeOutcome | Should -Be 'timeout'
        $svc.lastProbeUnixMs | Should -Be ($t0 + 400000)
        $svc.address | Should -Be '10.0.0.5' -Because 'an older resolution never replaces a newer one'
    }

    It 'discards evidence about a previous guest when the VM name changes' {
        $t0 = [long]1790000000000
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; Answered = $true; AnsweredIdentity = 'mac-corroborated'; ObservedUnixMs = $t0 })
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'custom-stash'; ProbeOutcome = 'no-address'; ObservedUnixMs = ($t0 + 1000) })
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
        $svc.vmName | Should -Be 'custom-stash'
        $svc.lastAnsweredUnixMs | Should -Be 0
    }

    It 'skips a write when only the clocks moved a little' {
        $t0 = [long]1790000000000
        $row = { param($at) @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'refused'; ObservedUnixMs = $at }) }
        (Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation (& $row $t0) -Confirm:$false).Wrote | Should -BeTrue
        $again = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation (& $row ($t0 + 15000)) -Confirm:$false
        $again.Wrote | Should -BeFalse
        $again.Reason | Should -Be 'unchanged'
        (Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation (& $row ($t0 + 301000)) -Confirm:$false).Wrote | Should -BeTrue
    }
}

Describe 'start and stop intents' {
    BeforeEach { $script:Env = New-CensusRoot }

    It 'records a stop as pending, then confirmed, with desired state stopped' {
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -Script 's.ps1' -StateRoot $script:Env.StateRoot -Confirm:$false
        $op.Proceed | Should -BeTrue
        $pending = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
        $pending.Result | Should -Be 'pending'
        $pending.DesiredState | Should -Be 'stopped'
        $pending.Script | Should -Be 's.ps1'
        $pending.Pid | Should -Be $PID
        (Test-YurunaServiceOperationCurrent -Context $op) | Should -BeTrue
        $exit = Exit-YurunaServiceOperation -Context $op -Result confirmed -FinalState 'absent' -Confirm:$false
        $exit.Result | Should -Be 'confirmed'
        $done = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
        $done.Result | Should -Be 'confirmed'
        $done.CompletedUnixMs | Should -BeGreaterThan 0
        (Test-YurunaServiceOperationCurrent -Context $op) | Should -BeFalse -Because 'a closed operation no longer owns the service'
    }

    It 'keeps a failed stop as a request to stay stopped' {
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result failed -FinalState 'running' -Confirm:$false
        (Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot).DesiredState | Should -Be 'stopped'
    }

    It 'leaves the baseline in force while a start is pending or failed, and runs once it is confirmed' {
        $stop = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $stop -Result confirmed -Confirm:$false
        $start = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        (Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot).DesiredState | Should -Be 'stopped' -Because 'a pending start is not yet a running service'
        $null = Exit-YurunaServiceOperation -Context $start -Result failed -Confirm:$false
        (Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot).DesiredState | Should -Be 'stopped'
        $again = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $again -Result confirmed -Confirm:$false
        (Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot).DesiredState | Should -Be 'running' -Because 'an explicit confirmed start supersedes the stop'
    }

    It 'closes a start as superseded when a newer stop was recorded meanwhile, and the stop stands' {
        $start = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -Script 'Start-X.ps1' -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Publish-TestIntent -Root $script:Env.StateRoot -Key 'stash' -Operation 'stop' -VMName 'yuruna-stash-service'
        (Test-YurunaServiceOperationCurrent -Context $start) | Should -BeFalse -Because 'the start no longer reflects what the operator wants'
        $exit = Exit-YurunaServiceOperation -Context $start -Result confirmed -WarningVariable warned -WarningAction SilentlyContinue -Confirm:$false
        $exit.Result | Should -Be 'superseded'
        $exit.NewerOperation | Should -Be 'stop'
        @($warned).Count | Should -Be 1
        $intent = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
        $intent.Operation | Should -Be 'stop'
        $intent.Result | Should -Be 'pending'
        $intent.DesiredState | Should -Be 'stopped'
    }

    It 'numbers intents from one counter across every key' {
        $a = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $a -Result confirmed -Confirm:$false
        $b = Enter-YurunaServiceOperation -Key 'pool-control' -VMName 'yuruna-pool-control-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $b -Result confirmed -Confirm:$false
        $c = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $c -Result confirmed -Confirm:$false
        @($a.Generation, $b.Generation, $c.Generation) | Should -Be @(1, 2, 3)
        (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).IntentCounter | Should -Be 3
    }

    It 'refuses, changing nothing, when the census lock cannot be taken' {
        $lockPath = Join-Path $script:Env.StateRoot 'service-census.lock'
        $held = Enter-YurunaSingleFlightLock -Path $lockPath -Rank (Get-YurunaLockRank -Name CensusMerge)
        $held.Held | Should -BeTrue
        try {
            $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
            $op.Proceed | Should -BeFalse
            $op.Reason | Should -Be 'intent-not-persisted'
        } finally { Exit-YurunaSingleFlightLock -Lock $held }
        Test-Path -LiteralPath $script:Env.Record | Should -BeFalse
        (Get-YurunaSingleFlightLockState -Path (Join-Path $script:Env.StateRoot 'service-operation.stash.lock')).State | Should -Be 'absent' -Because 'no service lock is taken for a request that was never recorded'
    }

    It 'refuses without a private root and names why' {
        $missing = Join-Path $TestDrive 'nowhere'
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $missing -Confirm:$false
        $op.Proceed | Should -BeFalse
        $op.Reason | Should -Be 'root-unavailable'
        Test-Path -LiteralPath $missing | Should -BeFalse
        (Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false).Result | Should -Be 'not-recorded'
        (Exit-YurunaServiceOperation -Context $null -Result failed -Confirm:$false).Result | Should -Be 'not-recorded'
    }

    It 'previews without recording or locking anything' {
        $before = Get-RootListing -Path $script:Env.StateRoot
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -WhatIf
        $op.Proceed | Should -BeFalse
        $op.Reason | Should -Be 'preview'
        Get-RootListing -Path $script:Env.StateRoot | Should -Be $before
    }
}

Describe 'per-service operation locks' {
    BeforeEach { $script:Env = New-CensusRoot }

    It 'takes a set in ordinal key order and validates a nested context' {
        $set = Enter-YurunaServiceOperationLockSet -Key @('stash', 'caching-proxy', 'pool-control', 'stash') -StateRoot $script:Env.StateRoot -Purpose 'test' -Confirm:$false
        try {
            $set.Held | Should -BeTrue
            $set.Reason | Should -Be 'acquired'
            ($set.Keys -join ',') | Should -Be 'caching-proxy,pool-control,stash'
            Test-YurunaServiceOperationLockContext -Context $set -Key 'stash' | Should -BeTrue
            Test-YurunaServiceOperationLockContext -Context $set -Key 'download-agent' | Should -BeFalse
        } finally { Exit-YurunaServiceOperationLockSet -Context $set }
        Test-YurunaServiceOperationLockContext -Context $set -Key 'stash' | Should -BeFalse -Because 'a released set confers nothing'
        Exit-YurunaServiceOperationLockSet -Context $set
        Exit-YurunaServiceOperationLockSet -Context $null
    }

    It 'is all or nothing: a key busy in another process releases every lock already taken' {
        $child = Invoke-CensusChild -StateRoot $script:Env.StateRoot -Mode 'hold-lock'
        try {
            Wait-ForFile -Path $child.Ready | Should -BeTrue
            $set = Enter-YurunaServiceOperationLockSet -Key @('caching-proxy', 'pool-control', 'stash') -StateRoot $script:Env.StateRoot -Confirm:$false
            $set.Held | Should -BeFalse
            $set.Reason | Should -Be 'busy'
            $set.BusyKey | Should -Be 'stash'
            foreach ($key in @('caching-proxy', 'pool-control')) {
                (Get-YurunaSingleFlightLockState -Path (Join-Path $script:Env.StateRoot "service-operation.$key.lock")).State | Should -Be 'free'
            }
            $null = Complete-CensusChild -Child $child
        } finally {
            if (-not $child.Process.HasExited) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'refuses same-process reentry rather than sharing a held lock' {
        $holder = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
        try {
            $again = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
            $again.Held | Should -BeFalse
            $again.Reason | Should -Be 'busy'
        } finally { Exit-YurunaServiceOperationLockSet -Context $holder }
    }

    It 'reports a lock file it cannot open as lock-unavailable, never as another operation' {
        Mock -ModuleName Test.ServiceCensus Format-YurunaOperatorMessage { "$Key|$(if ($Arguments) { $Arguments['reason'] })" }
        # A directory where the lock file belongs cannot be opened as one.
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Env.StateRoot 'service-operation.stash.lock') -Force
        $set = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
        $set.Held | Should -BeFalse
        $set.Reason | Should -Not -Be 'busy'
        $set.LockReason | Should -Not -BeNullOrEmpty
        $set.LockReason | Should -Not -BeIn @('held-elsewhere', 'held-by-this-process')
        $start = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Start -StateRoot $script:Env.StateRoot -Confirm:$false
        $start.Proceed | Should -BeFalse
        $start.Reason | Should -Be 'lock-unavailable'
        $start.Detail | Should -Be $set.LockReason
        $start.Message | Should -Be "runner.service_operation_lock_unavailable|$($set.LockReason)"
        Test-Path -LiteralPath $script:Env.Record | Should -BeFalse -Because 'a start that cannot take its lock records no intent'
        $stop = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -WaitSeconds 0 -StateRoot $script:Env.StateRoot -Confirm:$false
        $stop.Proceed | Should -BeFalse
        $stop.Reason | Should -Be 'lock-unavailable'
        $intent = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
        $intent.Result | Should -Be 'failed'
        $intent.DesiredState | Should -Be 'stopped' -Because 'the stop is on record even though it could not run'
    }

    It 'names a pending request in a busy message only while the process that made it still runs' {
        $selfStart = [DateTimeOffset]::new((Get-Process -Id $PID).StartTime).ToUnixTimeMilliseconds()
        $running = [ordered]@{ generation = 2; operation = 'start'; result = 'pending'; script = 'running-start'; pid = $PID; processStartUnixMs = $selfStart }
        $reused = [ordered]@{ generation = 4; operation = 'stop'; result = 'pending'; script = 'reused-pid'; pid = $PID; processStartUnixMs = 1000 }
        $exited = [ordered]@{ generation = 3; operation = 'stop'; result = 'pending'; script = 'exited'; pid = 2147483000; processStartUnixMs = 0 }
        $detail = & (Get-Module Test.ServiceCensus) {
            param($Newest, $Older, $Oldest)
            Format-ServiceOperationBusyDetail -Record ([pscustomobject]@{ intent = $Newest; history = @($Older, $Oldest) })
            Format-ServiceOperationBusyDetail -Record ([pscustomobject]@{ intent = $Newest; history = @($Older) })
        } $reused $exited $running
        $detail[0] | Should -Be "operation=start script=running-start pid=$PID" -Because 'a pid now held by another process, and one no process holds, name nobody'
        $detail[1] | Should -Be 'unrecorded'
    }

    It 'refuses an invalid key, a spent deadline and a missing root' {
        (Enter-YurunaServiceOperationLockSet -Key @('Stash!') -StateRoot $script:Env.StateRoot -Confirm:$false).Reason | Should -Be 'invalid-key'
        (Enter-YurunaServiceOperationLockSet -Key @() -StateRoot $script:Env.StateRoot -Confirm:$false).Reason | Should -Be 'invalid-key'
        $spent = New-YurunaDeadline -TotalMilliseconds 0
        (Enter-YurunaServiceOperationLockSet -Key @('stash') -Deadline $spent -StateRoot $script:Env.StateRoot -Confirm:$false).Reason | Should -Be 'deadline'
        (Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot (Join-Path $TestDrive 'absent-root') -Confirm:$false).Reason | Should -Be 'root-unavailable'
    }

    It 'excludes another process: busy while a disposable child holds the lock, acquired after it lets go' {
        $child = Invoke-CensusChild -StateRoot $script:Env.StateRoot -Mode 'hold-lock'
        try {
            Wait-ForFile -Path $child.Ready | Should -BeTrue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $busy = Enter-YurunaServiceOperationLockSet -Key @('stash') -WaitMilliseconds 400 -StateRoot $script:Env.StateRoot -Confirm:$false
            $sw.Stop()
            $busy.Held | Should -BeFalse
            $busy.Reason | Should -Be 'busy'
            $sw.ElapsedMilliseconds | Should -BeGreaterOrEqual 350 -Because 'the contender waited its bound while the other process held the lock'
            $result = Complete-CensusChild -Child $child
            $result.Held | Should -BeTrue
            $after = Enter-YurunaServiceOperationLockSet -Key @('stash') -WaitMilliseconds 5000 -StateRoot $script:Env.StateRoot -Confirm:$false
            $after.Held | Should -BeTrue
            Exit-YurunaServiceOperationLockSet -Context $after
        } finally {
            if (-not $child.Process.HasExited) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'publishes a stop as pending, then reports operation-busy while another process holds the service' {
        $child = Invoke-CensusChild -StateRoot $script:Env.StateRoot -Mode 'hold-start'
        try {
            Wait-ForFile -Path $child.Ready | Should -BeTrue
            $stop = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -Script 'Stop-StashServiceVM.ps1' -WaitSeconds 1 -StateRoot $script:Env.StateRoot -Confirm:$false
            $stop.Proceed | Should -BeFalse
            $stop.Reason | Should -Be 'operation-busy'
            $stop.BusyDetail | Should -Match 'operation=start script=child-start pid=\d+'
            $stop.Message | Should -Not -BeNullOrEmpty
            $intent = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
            $intent.Operation | Should -Be 'stop'
            $intent.Result | Should -Be 'failed'
            $intent.DesiredState | Should -Be 'stopped' -Because 'the stop is on record even though it could not run'
            $result = Complete-CensusChild -Child $child
            $result.ExitResult | Should -Be 'superseded' -Because 'the start finished after a newer stop was recorded'
            (Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot).DesiredState | Should -Be 'stopped'
        } finally {
            if (-not $child.Process.HasExited) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'supersedes a waiting stop before it mutates anything when a newer start is recorded first' {
        $holder = Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -Confirm:$false
        $child = $null
        try {
            $child = Invoke-CensusChild -StateRoot $script:Env.StateRoot -Mode 'stop-wait'
            Wait-ForFile -Path $child.Ready | Should -BeTrue
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $published = $false
            while ($sw.ElapsedMilliseconds -lt 30000) {
                $intent = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
                if ($intent.Operation -eq 'stop' -and $intent.Result -eq 'pending') { $published = $true; break }
                Start-Sleep -Milliseconds 50
            }
            $published | Should -BeTrue -Because 'the waiting stop publishes its intent before it waits for the lock'
            $null = Publish-TestIntent -Root $script:Env.StateRoot -Key 'stash' -Operation 'start' -VMName 'yuruna-stash-service'
        } finally { Exit-YurunaServiceOperationLockSet -Context $holder }
        try {
            $result = Complete-CensusChild -Child $child
            $result.Proceed | Should -BeFalse
            $result.Reason | Should -Be 'superseded'
            $result.NewerOperation | Should -Be 'start'
            $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
            $svc.intent.operation | Should -Be 'start'
            @($svc.history | Where-Object { $_.generation -eq $result.Generation })[0].result | Should -Be 'superseded'
        } finally {
            if ($child -and -not $child.Process.HasExited) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'stop and beacon interleaving' {
    BeforeEach { $script:Env = New-CensusRoot }

    It 'keeps both a stop published after the observation was computed and the observation itself' {
        $before = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
        $observation = @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'answered'; Answered = $true
                AnsweredIdentity = ''; ObservedUnixMs = [long]1790000000000 })
        $before.IntentCounter | Should -Be 0
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'yuruna-stash-service' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false
        $merge = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation $observation -Confirm:$false
        $merge.Reason | Should -Be 'ok'
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
        $svc.intent.operation | Should -Be 'stop'
        $svc.desiredState | Should -Be 'stopped'
        $svc.lastUncorroboratedAnswerUnixMs | Should -Be 1790000000000
    }

    It 'loses no intent generation while another process publishes in a loop against a ticking merge' {
        $child = Invoke-CensusChild -StateRoot $script:Env.StateRoot -Mode 'intent-loop' -Count 12
        try {
            Wait-ForFile -Path $child.Ready | Should -BeTrue
            $outcomes = [System.Collections.Generic.List[string]]::new()
            for ($i = 0; $i -lt 25 -and -not $child.Process.HasExited; $i++) {
                $merge = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -LockWaitMilliseconds 2000 -Confirm:$false -Observation @(
                    [pscustomobject]@{ Key = 'pool-control'; VMName = 'yuruna-pool-control-service'; ProbeOutcome = 'refused'; ObservedUnixMs = ([long]1790000000000 + ($i * 400000)) })
                $outcomes.Add([string]$merge.Reason)
            }
            $result = Complete-CensusChild -Child $child
            $result.Published | Should -Be 12
            $census = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
            $census.Valid | Should -BeTrue
            $census.IntentCounter | Should -Be 12
            $census.Services['stash'].intent.generation | Should -Be 12
            $census.Services['stash'].intent.result | Should -Be 'confirmed'
            @($census.Services['stash'].history).Count | Should -Be 8 -Because 'history is capped at eight entries'
            @($outcomes | Where-Object { $_ -notin @('ok', 'unchanged', 'lock-busy') }) | Should -BeNullOrEmpty
        } finally {
            if (-not $child.Process.HasExited) { Stop-Process -Id $child.Process.Id -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'identity capture' {
    BeforeEach { $script:Env = New-CensusRoot }

    It 'agrees with the hard-coded list on this checkout, with every source recorded' {
        $set = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot
        $set.RosterAgreement | Should -BeTrue
        @($set.RosterDisagreement).Count | Should -Be 0
        @($set.Rows).Count | Should -Be 4
        foreach ($row in $set.Rows) {
            $row.Source | Should -Be 'manifest+hard-coded'
            $row.VMNameSource | Should -Be 'manifest-default'
            $row.HostingMode | Should -Be 'vm'
            $row.ForwardersCaptured | Should -BeFalse
        }
    }

    It 'reports roster drift in either direction' {
        $extra = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot `
            -HardCodedName @('yuruna-caching-proxy-service', 'yuruna-stash-service', 'yuruna-pool-control-service', 'yuruna-download-agent-service', 'yuruna-extra-service')
        $extra.RosterAgreement | Should -BeFalse
        $extra.RosterDisagreement | Should -Contain 'hard-coded-only:yuruna-extra-service'
        (@($extra.Rows | Where-Object Key -eq 'extra')[0]).Source | Should -Be 'hard-coded'
        $missing = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot `
            -HardCodedName @('yuruna-caching-proxy-service', 'yuruna-stash-service', 'yuruna-pool-control-service')
        $missing.RosterDisagreement | Should -Contain 'manifest-only:yuruna-download-agent-service'
    }

    It 'captures a custom VM name from the marker and flags a conflicting intent' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -VMName 'custom-stash')
        $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot).Rows | Where-Object Key -eq 'stash')[0]
        $row.VMName | Should -Be 'custom-stash'
        $row.VMNameSource | Should -Be 'marker'
        $row.Ambiguity | Should -Be ''
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'another-stash' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result failed -Confirm:$false
        $conflict = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot).Rows | Where-Object Key -eq 'stash')[0]
        $conflict.Ambiguity | Should -Be 'conflicting-identity'
    }

    It 'takes the name from the newest intent when no marker remains' {
        $op = Enter-YurunaServiceOperation -Key 'stash' -VMName 'custom-stash' -Operation Stop -StateRoot $script:Env.StateRoot -Confirm:$false
        $null = Exit-YurunaServiceOperation -Context $op -Result confirmed -Confirm:$false
        $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot).Rows | Where-Object Key -eq 'stash')[0]
        $row.VMName | Should -Be 'custom-stash'
        $row.VMNameSource | Should -Be 'intent'
        $row.DesiredState | Should -Be 'stopped'
    }

    It 'flags a custom name that is another service''s default' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -VMName 'yuruna-pool-control-service')
        $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot).Rows | Where-Object Key -eq 'stash')[0]
        $row.Ambiguity | Should -Be 'duplicate-name'
    }

    It 'verifies a host-side pool-control process by name, start time and a loopback connect' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        try {
            [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -HostingMode 'host-process' `
                    -BaseUrl "http://127.0.0.1:$port/" -Extra ([ordered]@{ pid = 4242; port = $port; processStartUnixMs = 1790000000000 }))
            $lookup = { param($ProcessId) $null = $ProcessId; [pscustomobject]@{ Name = 'pool-control-service'; Path = ''; StartUnixMs = [long]1790000000100 } }
            $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot -ProcessLookup $lookup).Rows | Where-Object Key -eq 'pool-control')[0]
            $row.HostingMode | Should -Be 'host-process'
            $row.HostProcess.Verified | Should -BeTrue
            $row.HostProcess.IdentityVerified | Should -BeTrue
            $row.HostProcess.PortAnswered | Should -BeTrue
            $row.Advertised.Address | Should -Be '127.0.0.1'
            $row.Advertised.Port | Should -Be $port
            $row.Advertised.Origin | Should -Be 'marker'
        } finally { $listener.Stop() }
    }

    It 'validates a legacy marker that only carries a pid through the process lookup' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        try {
            [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -Extra ([ordered]@{ pid = 77; port = $port }))
            $lookup = { param($ProcessId) $null = $ProcessId; [pscustomobject]@{ Name = 'pool-control-se'; Path = ''; StartUnixMs = [long]1 } }
            $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot -ProcessLookup $lookup).Rows | Where-Object Key -eq 'pool-control')[0]
            $row.HostingMode | Should -Be 'host-process'
            $row.HostProcess.StartTimeMatches | Should -BeNullOrEmpty
        } finally { $listener.Stop() }
    }

    It 'calls a dead host process none, and an unverifiable one ambiguous' {
        [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -HostingMode 'host-process' -Extra ([ordered]@{ pid = 4242; port = 1 }))
        $dead = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot -ProcessLookup { param($ProcessId) $null = $ProcessId; $null }).Rows | Where-Object Key -eq 'pool-control')[0]
        $dead.HostingMode | Should -Be 'none'
        $dead.Ambiguity | Should -Be ''
        $stranger = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot `
                    -ProcessLookup { param($ProcessId) $null = $ProcessId; [pscustomobject]@{ Name = 'bash'; Path = ''; StartUnixMs = [long]1 } }).Rows | Where-Object Key -eq 'pool-control')[0]
        $stranger.HostingMode | Should -Be 'unknown'
        $stranger.Ambiguity | Should -Be 'host-side-unverified'
    }

    It 'reads the caching proxy''s advertised address from its state file' {
        Set-Content -LiteralPath (Join-Path $script:Env.RuntimeDir 'yuruna-caching-proxy-service.yml') -Value @('password: x', 'ipAddress: "192.168.64.9"')
        $row = @((Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot).Rows | Where-Object Key -eq 'caching-proxy')[0]
        $row.Advertised.Address | Should -Be '192.168.64.9'
        $row.Advertised.Port | Should -Be 3128
        $row.Advertised.Origin | Should -Be 'cp-state'
    }

    It 'fills the provider identity and the forwarder table only with -ResolveProvider, and only through the passive resolver' {
        Install-PassiveResolver
        $script:Passive.Address['yuruna-stash-service'] = [pscustomobject]@{ VMName = 'yuruna-stash-service'; Address = '192.168.64.7'; Origin = 'arp'
            BundlePath = '/b/stash.utm/config.plist'; BundleMac = 'AA:BB:CC:DD:EE:07'; NetworkMode = 'Shared'; MacCorroborated = $true; Reason = 'ok'; ElapsedMs = 1 }
        function global:Get-PortMapTarget {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stand-in with the driver''s signature.')]
            param($Deadline)
            [pscustomobject]@{ HostPort = 2222; TargetAddress = '192.168.64.7'; TargetPort = 22; OwnerPid = 9; OwnerVerified = $true; Origin = 'forwarder-pidfile' }
        }
        Install-ForbiddenTrap
        try {
            $plain = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot -HostType 'host.macos.utm'
            $script:Passive.ContextCalls.Count | Should -Be 0
            $set = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot -HostType 'host.macos.utm' -ResolveProvider
            $stash = @($set.Rows | Where-Object Key -eq 'stash')[0]
            $stash.Provider.Kind | Should -Be 'utm'
            $stash.Provider.BundleMac | Should -Be 'AA:BB:CC:DD:EE:07'
            $stash.Provider.Verified | Should -BeTrue
            $stash.ForwardersCaptured | Should -BeTrue
            @($stash.Forwarders).Count | Should -Be 1
            @($plain.Rows | Where-Object Key -eq 'stash')[0].Provider.BundleMac | Should -Be ''
            $script:Trap.Calls.Count | Should -Be 0 -Because 'identity capture never asks the control channel'
        } finally {
            Uninstall-ForbiddenTrap
            Uninstall-PassiveResolver
        }
    }

    It 'creates and writes nothing while capturing, reading or previewing' {
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true)
        $before = Get-RootListing -Path $script:Env.StateRoot
        $null = Get-YurunaServiceVmIdentitySet -RuntimeDir $script:Env.RuntimeDir -StateRoot $script:Env.StateRoot
        $null = Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot
        $null = Get-YurunaServiceIntent -Key 'stash' -StateRoot $script:Env.StateRoot
        (Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -WhatIf).Reason | Should -Be 'preview'
        (Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Observation @([pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service' }) -WhatIf).Reason | Should -Be 'preview'
        (Enter-YurunaServiceOperationLockSet -Key @('stash') -StateRoot $script:Env.StateRoot -WhatIf).Reason | Should -Be 'preview'
        Get-RootListing -Path $script:Env.StateRoot | Should -Be $before
    }
}

Describe 'the passive census tick' {
    BeforeEach {
        $script:Env = New-CensusRoot
        Install-PassiveResolver
        Install-ForbiddenTrap
    }
    AfterEach {
        Uninstall-ForbiddenTrap
        Uninstall-PassiveResolver
    }

    It 'makes no control-channel call on an ARP miss, and never counts an uncorroborated answer' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        try {
            [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -BaseUrl "http://127.0.0.1:$port")
            $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Roster (& $script:StashRoster 80) -HardCodedName @('yuruna-stash-service') -Confirm:$false
        } finally { $listener.Stop() }
        $tick.Ran | Should -BeTrue
        $tick.Reason | Should -Be 'ok'
        $script:Trap.Calls.Count | Should -Be 0 -Because "the census reached: $($script:Trap.Calls -join ', ')"
        $stash = @($tick.Services | Where-Object Key -eq 'stash')[0]
        $stash.ProbeOutcome | Should -Be 'answered'
        $stash.Positive | Should -BeFalse -Because 'a TCP answer on an address no MAC ties to the guest is not the guest'
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
        $svc.lastAnsweredUnixMs | Should -Be 0
        $svc.lastUncorroboratedAnswerUnixMs | Should -BeGreaterThan 0
        @($script:Passive.ContextCalls | Where-Object { $_.ArpOnly }).Count | Should -Be 1 -Because 'an answer triggers one post-probe ARP read'
    }

    It 'counts an answer whose address carries the bundle MAC in a post-probe ARP read' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $script:Passive.Address['yuruna-stash-service'] = [pscustomobject]@{ VMName = 'yuruna-stash-service'; Address = '127.0.0.1'; Origin = 'arp'
            BundlePath = '/b'; BundleMac = 'AA:BB:CC:DD:EE:01'; NetworkMode = 'Shared'; MacCorroborated = $true; Reason = 'ok'; ElapsedMs = 1 }
        $script:Passive.ArpMap = @{ '127.0.0.1' = 'AA:BB:CC:DD:EE:01' }
        try {
            $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Roster (& $script:StashRoster $port) -HardCodedName @('yuruna-stash-service') -Confirm:$false
        } finally { $listener.Stop() }
        @($tick.Services | Where-Object Key -eq 'stash')[0].Positive | Should -BeTrue
        $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash']
        $svc.lastAnsweredIdentity | Should -Be 'mac-corroborated'
        $svc.address | Should -Be '127.0.0.1'
        $svc.addressOrigin | Should -Be 'arp'
        $svc.bundleMac | Should -Be 'AA:BB:CC:DD:EE:01'
        $script:Passive.ContextCalls.Count | Should -Be 2
        $script:Passive.ContextCalls[0].ArpOnly | Should -BeFalse
        $script:Passive.ContextCalls[1].ArpOnly | Should -BeTrue
        $script:Passive.ContextCalls[1].SubnetEvidence | Should -Be $script:Passive.Subnet -Because 'the subnet evidence is captured once per tick and handed on'
        $script:Trap.Calls.Count | Should -Be 0
    }

    It 'never lets a lease-only match prove identity' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $script:Passive.Address['yuruna-stash-service'] = [pscustomobject]@{ VMName = 'yuruna-stash-service'; Address = $null; Origin = 'none'
            BundlePath = '/b'; BundleMac = 'AA:BB:CC:DD:EE:01'; NetworkMode = 'Shared'; MacCorroborated = $false; Reason = 'lease-only'; ElapsedMs = 1 }
        $script:Passive.ArpMap = @{ '127.0.0.1' = 'AA:BB:CC:DD:EE:99' }
        try {
            [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -BaseUrl "http://127.0.0.1:$port")
            $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Roster (& $script:StashRoster $port) -HardCodedName @('yuruna-stash-service') -Confirm:$false
        } finally { $listener.Stop() }
        @($tick.Services | Where-Object Key -eq 'stash')[0].Positive | Should -BeFalse
        (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot).Services['stash'].lastAnsweredUnixMs | Should -Be 0
    }

    It 're-resolves at most once per ten minutes and keeps a prior positive through a MAC mismatch' {
        $port = Get-FreeLoopbackPort
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $script:Passive.Address['yuruna-stash-service'] = [pscustomobject]@{ VMName = 'yuruna-stash-service'; Address = '127.0.0.1'; Origin = 'arp'
            BundlePath = '/b'; BundleMac = 'AA:BB:CC:DD:EE:01'; NetworkMode = 'Shared'; MacCorroborated = $true; Reason = 'ok'; ElapsedMs = 1 }
        $script:Passive.ArpMap = @{ '127.0.0.1' = 'AA:BB:CC:DD:EE:01' }
        $t0 = [long]1790000000000
        $tickAt = {
            param([long]$At)
            Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -NowUnixMs $At `
                -Roster (& $script:StashRoster $port) -HardCodedName @('yuruna-stash-service') -Confirm:$false
        }
        try {
            $null = & $tickAt $t0
            $script:Passive.AddressCalls.Count | Should -Be 1
            # The address now belongs to someone else: the answer is real, the
            # MAC is not the guest's.
            $script:Passive.ArpMap = @{ '127.0.0.1' = 'AA:BB:CC:DD:EE:99' }
            $second = & $tickAt ($t0 + 60000)
            $script:Passive.AddressCalls.Count | Should -Be 1 -Because 'a resolver answer is cached for ten minutes'
            @($second.Services | Where-Object Key -eq 'stash')[0].Positive | Should -BeFalse
            $svc = (Read-YurunaServiceCensus -StateRoot $script:Env.StateRoot -NowUnixMs ($t0 + 60000)).Services['stash']
            $svc.lastAnsweredUnixMs | Should -Be $t0 -Because 'a reused address never clears the earlier positive, and never extends it'
            $null = & $tickAt ($t0 + 601000)
            $script:Passive.AddressCalls.Count | Should -Be 2
        } finally { $listener.Stop() }
    }

    It 'attempts a resolution that found nothing at most once per ten minutes as well' {
        $t0 = [long]1790000000000
        $tickAt = {
            param([string]$Root, [long]$At)
            Invoke-YurunaServiceCensusTick -StateRoot $Root -RuntimeDir $script:Env.RuntimeDir -NowUnixMs $At `
                -Roster (& $script:StashRoster 80) -HardCodedName @('yuruna-stash-service') -Confirm:$false
        }
        $resolutions = { @($script:Passive.ContextCalls | Where-Object { -not $_.ArpOnly }).Count }
        foreach ($offset in @(0, 20000, 40000)) {
            (& $tickAt $script:Env.StateRoot ($t0 + $offset)).Ran | Should -BeTrue
        }
        & $resolutions | Should -Be 1 -Because 'an ARP miss leaves no address to cache, and still postpones the next attempt'
        $script:Passive.AddressCalls.Count | Should -Be 1
        $null = & $tickAt $script:Env.StateRoot ($t0 + 601000)
        & $resolutions | Should -Be 2
        $script:Passive.AddressCalls.Count | Should -Be 2

        # A resolver that throws has been attempted all the same.
        function global:Get-VMPassiveAddressContext {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stand-in with the driver''s signature; it fails before using any of them.')]
            param([AllowNull()]$Deadline, [switch]$ArpOnly, [string[]]$ArpLine, [string]$LeaseText, $SubnetEvidence)
            $script:Passive.ContextCalls.Add([pscustomobject]@{ ArpOnly = [bool]$ArpOnly; SubnetEvidence = $null })
            throw 'arp is broken'
        }
        $other = New-CensusRoot
        $script:Passive.ContextCalls.Clear()
        foreach ($offset in @(0, 20000)) { $null = & $tickAt $other.StateRoot ($t0 + $offset) }
        $script:Passive.ContextCalls.Count | Should -Be 1
    }

    It 'finishes inside five seconds against four silent addresses and a slow resolver' {
        $script:Passive.ContextDelayMs = 1500
        $roster = @(
            [pscustomobject]@{ Key = 'caching-proxy'; Area = 'caching-proxy-service'; VMName = 'yuruna-caching-proxy-service'; DisplayName = 'Caching-proxy service'; HealthPort = 3128 }
            [pscustomobject]@{ Key = 'stash'; Area = 'stash-service'; VMName = 'yuruna-stash-service'; DisplayName = 'Stash service'; HealthPort = 80 }
            [pscustomobject]@{ Key = 'pool-control'; Area = 'pool-control-service'; VMName = 'yuruna-pool-control-service'; DisplayName = 'Pool-control service'; HealthPort = 80 }
            [pscustomobject]@{ Key = 'download-agent'; Area = 'download-agent-service'; VMName = 'yuruna-download-agent-service'; DisplayName = 'Download-agent service'; HealthPort = 80 }
        )
        # TEST-NET-1 (RFC 5737): routable nowhere, so every connect waits out its cap.
        Set-Content -LiteralPath (Join-Path $script:Env.RuntimeDir 'yuruna-caching-proxy-service.yml') -Value 'ipAddress: 192.0.2.4'
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -BaseUrl 'http://192.0.2.1')
        [void](Write-ExtensionServiceMarker -Area 'pool-control-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -BaseUrl 'http://192.0.2.2')
        [void](Write-ExtensionServiceMarker -Area 'download-agent-service' -RuntimeDir $script:Env.RuntimeDir -Active $true -BaseUrl 'http://192.0.2.3')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Roster $roster `
            -HardCodedName @($roster | ForEach-Object VMName) -Confirm:$false
        $sw.Stop()
        $tick.ElapsedMs | Should -BeLessOrEqual 5500
        $sw.ElapsedMilliseconds | Should -BeLessOrEqual 6000
        $tick.Reason | Should -BeIn @('ok', 'unchanged', 'budget-exhausted')
        $script:Passive.ContextCalls.Count | Should -Be 1 -Because 'one passive context per tick, and no ARP read without an answer'
        $script:Trap.Calls.Count | Should -Be 0
    }

    It 'refuses to run as root and writes nothing' {
        $before = Get-RootListing -Path $script:Env.StateRoot
        $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -UserName 'root' -Confirm:$false
        if ($IsWindows) { Set-ItResult -Skipped -Because 'the root refusal applies to Unix accounts only'; return }
        $tick.Reason | Should -Be 'running-as-root'
        $tick.Ran | Should -BeFalse
        Get-RootListing -Path $script:Env.StateRoot | Should -Be $before
    }

    It 'writes nothing without a private root' {
        $missing = Join-Path $TestDrive 'no-root-here'
        (Invoke-YurunaServiceCensusTick -StateRoot $missing -RuntimeDir $script:Env.RuntimeDir -Confirm:$false).Reason | Should -Be 'root-unavailable'
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'skips the merge, leaving the census byte-identical, while the merge lock is busy' {
        $null = Update-YurunaServiceCensusObservation -StateRoot $script:Env.StateRoot -Confirm:$false -Observation @(
            [pscustomobject]@{ Key = 'stash'; VMName = 'yuruna-stash-service'; ProbeOutcome = 'refused'; ObservedUnixMs = [long]1790000000000 })
        $bytes = [System.IO.File]::ReadAllBytes($script:Env.Record)
        $held = Enter-YurunaSingleFlightLock -Path (Join-Path $script:Env.StateRoot 'service-census.lock') -Rank (Get-YurunaLockRank -Name CensusMerge)
        try {
            $tick = Invoke-YurunaServiceCensusTick -StateRoot $script:Env.StateRoot -RuntimeDir $script:Env.RuntimeDir -Confirm:$false
            $tick.Reason | Should -Be 'lock-busy'
        } finally { Exit-YurunaSingleFlightLock -Lock $held }
        [System.IO.File]::ReadAllBytes($script:Env.Record) | Should -Be $bytes
    }
}

Describe 'the capability table' {
    It 'declares every host type, with a reason for every capability it withholds' {
        foreach ($hostType in @('host.macos.utm', 'host.ubuntu.kvm', 'host.windows.hyper-v', 'host.other')) {
            $c = Get-YurunaServiceCensusCapability -HostType $hostType
            $c.HostType | Should -Be $hostType
            $c.EvidenceUsableForRepair | Should -Be ([bool]($c.StoreQualified -and $c.PassiveCorroborationQualified))
            if (-not $c.EvidenceUsableForRepair) { $c.UnavailableReason | Should -Not -BeNullOrEmpty }
        }
        (Get-YurunaServiceCensusCapability -HostType 'host.ubuntu.kvm').StoreQualified | Should -BeTrue
        (Get-YurunaServiceCensusCapability -HostType 'host.ubuntu.kvm').UnavailableReason | Should -Be 'no-passive-resolver'
        (Get-YurunaServiceCensusCapability -HostType 'host.macos.utm').EvidenceUsableForRepair | Should -BeFalse
        (Get-YurunaServiceCensusCapability -HostType 'host.macos.utm').UnavailableReason | Should -Be 'lock-contention-unverified-on-macos' -Because 'the store is the first capability macOS withholds'
        (Get-YurunaServiceCensusCapability -HostType 'host.windows.hyper-v').EvidenceUsableForRepair | Should -BeFalse
        (Get-YurunaServiceCensusCapability -HostType 'host.other').UnavailableReason | Should -Be 'unknown-host-type'
    }
}

Describe 'static guarantees' {
    It 'names no control-channel command anywhere in the census module' {
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:CensusModule, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $findings = [System.Collections.Generic.List[string]]::new()
        foreach ($command in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $name = $command.GetCommandName()
            if ($name -and $script:ForbiddenName -contains $name) { $findings.Add("command ${name} at line $($command.Extent.StartLineNumber)") }
        }
        foreach ($token in $tokens) {
            foreach ($name in $script:ForbiddenName) {
                if ($token.Text -match ('(?i)(?<![A-Za-z0-9-])' + [regex]::Escape($name) + '(?![A-Za-z0-9-])')) {
                    $findings.Add("token '$name' at line $($token.Extent.StartLineNumber)")
                }
            }
        }
        $findings | Should -BeNullOrEmpty -Because 'a comment or string naming such a command is how a future edit starts calling it'
        foreach ($allowed in @('Get-VMPassiveAddressContext', 'Get-VMPassiveAddress', 'Get-PortMapTarget')) {
            (Get-Content -Raw -LiteralPath $script:CensusModule) | Should -Match ([regex]::Escape("'$allowed'")) -Because 'the passive resolver is looked up by name at call time'
        }
    }

    It 'runs the beacon''s census tick inside the loop, beside the announce tick and in its own try' {
        $beacon = Join-Path (Split-Path -Parent $script:CensusModule) 'Invoke-HostAddressBeacon.ps1'
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($beacon, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0
        $tick = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-YurunaServiceCensusTick' }, $true))
        $tick.Count | Should -Be 1
        $ancestors = [System.Collections.Generic.List[object]]::new()
        $cursor = $tick[0].Parent
        while ($cursor) { $ancestors.Add($cursor); $cursor = $cursor.Parent }
        @($ancestors | Where-Object { $_ -is [System.Management.Automation.Language.WhileStatementAst] }).Count | Should -Be 1 -Because 'the census ticks with the loop'
        $innerTry = @($ancestors | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] })[0]
        $innerTry | Should -Not -BeNullOrEmpty
        @($innerTry.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-HostAddressBeaconTick' }, $true)).Count |
            Should -Be 0 -Because 'a census failure must not share the announce tick''s try'
        $import = @($ast.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' -and $n.Extent.Text -match 'Test\.ServiceCensus\.psm1' }, $true))
        $import.Count | Should -Be 1
        $guard = $import[0].Parent
        while ($guard -and -not ($guard -is [System.Management.Automation.Language.TryStatementAst])) { $guard = $guard.Parent }
        $guard | Should -Not -BeNullOrEmpty -Because 'a census that cannot load never ends the beacon'
    }

    It 'leaves the teardown loop to the stop scripts, which record their own intents' {
        $stateModule = Join-Path (Split-Path -Parent $script:CensusModule) 'Test.HostAutomationState.psm1'
        $fn = Get-YurunaTestFunctionAst -Path $stateModule -Name 'Stop-YurunaServiceVMSet'
        $fn.Extent.Text | Should -Not -Match 'Enter-YurunaServiceOperation|Exit-YurunaServiceOperation|ServiceCensus'
    }
}

Describe 'the beacon keeps announcing whatever the census does' -Skip:$IsWindows {
    BeforeAll {
        # A mirror of this checkout in which every entry is a link to the real
        # one, except the census module, which is replaced by a file that
        # cannot load: the beacon under test is the real script.
        $script:Mirror = Join-Path $TestDrive 'mirror'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Mirror 'test/modules') -Force
        foreach ($entry in Get-ChildItem -LiteralPath $script:RepoRoot -Force) {
            if ($entry.Name -in @('test', '.git')) { continue }
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:Mirror $entry.Name) -Target $entry.FullName
        }
        foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test') -Force) {
            if ($entry.Name -eq 'modules') { continue }
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:Mirror "test/$($entry.Name)") -Target $entry.FullName
        }
        foreach ($entry in Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/modules') -Force -File) {
            if ($entry.Name -eq 'Test.ServiceCensus.psm1') { continue }
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:Mirror "test/modules/$($entry.Name)") -Target $entry.FullName
        }
        Set-Content -LiteralPath (Join-Path $script:Mirror 'test/modules/Test.ServiceCensus.psm1') -Value 'throw "census module deliberately unloadable"'

        function Invoke-BeaconRun {
            param([string]$Script, [string]$HomeDir, [string]$RuntimeDir)
            $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
            foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Script, '-RuntimeDir', $RuntimeDir, '-CacheAddress', '', '-IntervalSeconds', '1')) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false
            $psi.Environment['HOME'] = $HomeDir
            $psi.Environment['YURUNA_RUNTIME_DIR'] = $RuntimeDir
            $psi.Environment['NO_COLOR'] = '1'
            $process = [System.Diagnostics.Process]::Start($psi)
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $finished = $process.WaitForExit(90000)
            if (-not $finished) { $process.Kill($true) }
            [pscustomobject]@{
                Finished = $finished; ExitCode = if ($finished) { $process.ExitCode } else { -1 }
                Output = ([regex]::Replace($stdout.Result + $stderr.Result, "\x1b\[[0-9;]*[A-Za-z]", ''))
            }
        }
    }

    It 'runs the tick on every pass with a working census, and writes its record under the private root' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'the stand-in home relies on HOME, which Windows does not read'; return }
        $homeDir = Join-Path $TestDrive 'home-ok'
        $runtime = Join-Path $TestDrive 'runtime-ok'
        $null = New-Item -ItemType Directory -Path $homeDir, $runtime -Force
        $run = Invoke-BeaconRun -Script (Join-Path $script:RepoRoot 'test/modules/Invoke-HostAddressBeacon.ps1') -HomeDir $homeDir -RuntimeDir $runtime
        $run.Finished | Should -BeTrue
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'status service is gone|runner\.operator_ff5d44dc6a9f0d66'
        Test-Path -LiteralPath (Join-Path $homeDir '.yuruna/host-refresh/service-census.record') | Should -BeTrue
    }

    It 'keeps looping, and ends only on the status-service signal, when the census cannot load' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'the stand-in home relies on HOME, which Windows does not read'; return }
        $homeDir = Join-Path $TestDrive 'home-broken'
        $runtime = Join-Path $TestDrive 'runtime-broken'
        $null = New-Item -ItemType Directory -Path $homeDir, $runtime -Force
        $run = Invoke-BeaconRun -Script (Join-Path $script:Mirror 'test/modules/Invoke-HostAddressBeacon.ps1') -HomeDir $homeDir -RuntimeDir $runtime
        $run.Finished | Should -BeTrue
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'status service is gone|runner\.operator_ff5d44dc6a9f0d66'
        Test-Path -LiteralPath (Join-Path $homeDir '.yuruna/host-refresh/service-census.record') | Should -BeFalse
    }
}
