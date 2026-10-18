<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42d1e9a4-db28-4ba0-8a3a-5806a893ed05
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host condition registry provider
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
    Every supported host registers a condition provider, and every slot in
    the record it registers is one somebody reads.
.DESCRIPTION
    The registry binds a per-host record -- Assert, AssertMinimum,
    RequiresElevation and the optional capabilities -- that the dispatchers
    invoke by slot. Registration is all-or-nothing per host: a name listed as
    mandatory that cannot be resolved skips the ENTIRE registration for that
    platform, leaving a host with no Assert and no AssertMinimum. The only
    signal is a Write-Warning at import, which an unattended cycle does not
    read, and the effect surfaces much later as "unknown host type, skipping
    checks" -- which passes. So the first rule here is simply that all three
    hosts are present after a plain import.

    The second rule is why the registry could carry a mandatory slot that
    nothing ever invoked: a record field costs nothing to declare and nothing
    to store, so an unread one is invisible. Requiring every slot to have a
    dispatch site makes the record self-limiting -- a field is either wired to
    a caller or it does not belong in the record. It also protects the first
    rule, because an unread mandatory slot is the cheapest way to lose an
    entire platform's registration: the host stops registering over a function
    whose absence changes no behavior.

    The third rule is the content of the record. The facade fills each
    optional slot by resolving a function name when it registers a host. A
    name that resolves fills its slot; a name that does not leaves the slot
    $null and says so on the verbose stream only, because every dispatcher
    reads an empty slot as "this host needs nothing here". A platform module
    that loses or renames an optional function therefore loses the capability
    without a failure anywhere, so the record each host stores and the line
    each missing capability writes are held here, byte for byte.

    Registration happens at import, on whatever OS the suite runs on, because
    the platform modules define their functions unconditionally and only
    branch at call time. That is what makes this checkable from one host
    rather than needing all three.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.psm1') -Force -DisableNameChecking

    $script:Matrix = Get-HostConditionProviderMatrix
    $script:Expected = @('host.windows.hyper-v', 'host.macos.utm', 'host.ubuntu.kvm')

    # The dispatchers live across the Test.Host* family, not in one module.
    $script:FamilyText = (Get-ChildItem -Path $here -Filter 'Test.Host*.psm1' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

    $script:Facade = Get-Module -Name 'Test.HostCondition'
    $script:RecordFields = 'HostType, Assert, AssertMinimum, RequiresElevation, Display, DisplayTeardown, ClockSync, NetworkHealth, MetricsExporter'
    $script:OptionalSlots = @('Display', 'DisplayTeardown', 'ClockSync', 'NetworkHealth', 'MetricsExporter')
}

Describe 'every supported host registers a condition provider' {
    It 'registers all three host types on a plain import' {
        $missing = @($script:Expected | Where-Object { -not $script:Matrix.Contains($_) })
        Assert-True ($missing.Count -eq 0) @"
these host types did not register, so their Assert and AssertMinimum are gone
and the dispatcher will skip their checks and pass:
$($missing -join "`n")
"@
    }

    It 'binds the mandatory slots on every registered host' {
        $broken = [Collections.Generic.List[string]]::new()
        foreach ($hostType in $script:Expected) {
            $record = $script:Matrix[$hostType]
            if (-not $record) { continue }
            foreach ($slot in @('Assert', 'AssertMinimum')) {
                if (-not $record.$slot) { $broken.Add("${hostType}: $slot is empty") }
            }
        }
        Assert-True ($broken.Count -eq 0) ($broken -join "`n")
    }
}

Describe 'every slot in a provider record has a caller' {
    It 'invokes each registered slot somewhere in the Test.Host* family' {
        # HostType is the registry key rather than a dispatched capability.
        $orphans = [Collections.Generic.List[string]]::new()
        foreach ($hostType in $script:Expected) {
            $record = $script:Matrix[$hostType]
            if (-not $record) { continue }
            foreach ($slot in $record.Keys) {
                if ($slot -eq 'HostType') { continue }
                if ($script:FamilyText -notmatch ('\$provider\.' + [regex]::Escape($slot) + '\b')) {
                    $orphans.Add("${hostType}: $slot")
                }
            }
        }
        Assert-True ($orphans.Count -eq 0) @"
these provider slots are stored but never invoked. An unread slot is dead
weight, and a mandatory one costs a whole platform its registration when its
function goes missing:
$(($orphans | Sort-Object -Unique) -join "`n")
"@
    }
}

Describe 'the record each supported host registers' {
    # Each slot is named by the function expected in it; $null is a capability
    # the platform does not offer. The platform modules define every one of
    # these functions on every OS, so the table holds wherever the suite runs.
    It 'binds every slot of <HostType> to the function the facade names for it' -TestCases @(
        @{
            HostType = 'host.windows.hyper-v'; RequiresElevation = $true
            Slot = @{
                Assert = 'Assert-WindowsHostConditionSet'; AssertMinimum = 'Test-WindowsHostMinimum'
                Display = 'Install-YurunaVirtualDisplay'; DisplayTeardown = 'Remove-YurunaVirtualDisplay'
                ClockSync = 'Sync-WindowsHostClock'; NetworkHealth = 'Test-WindowsGuestNetworkHealth'
                MetricsExporter = 'Initialize-WindowsHostMetricsExporter'
            }
        }
        @{
            HostType = 'host.macos.utm'; RequiresElevation = $false
            Slot = @{
                Assert = 'Assert-MacHostConditionSet'; AssertMinimum = 'Test-MacHostMinimum'
                Display = $null; DisplayTeardown = $null
                ClockSync = 'Sync-MacHostClock'; NetworkHealth = $null
                MetricsExporter = $null
            }
        }
        @{
            HostType = 'host.ubuntu.kvm'; RequiresElevation = $false
            Slot = @{
                Assert = 'Assert-LinuxHostConditionSet'; AssertMinimum = 'Test-LinuxHostMinimum'
                Display = $null; DisplayTeardown = $null
                ClockSync = 'Sync-LinuxHostClock'; NetworkHealth = $null
                MetricsExporter = $null
            }
        }
    ) {
        param([string]$HostType, [bool]$RequiresElevation, [hashtable]$Slot)

        $record = Get-HostConditionProvider -HostType $HostType
        Assert-NotNull $record "$HostType is not registered"
        Assert-True ($record -is [System.Collections.Specialized.OrderedDictionary]) 'a record is an ordered dictionary'
        Assert-True ((@($record.Keys) -join ', ') -ceq $script:RecordFields) `
            "the record fields or their order changed: $(@($record.Keys) -join ', ')"
        Assert-True ($record.HostType -ceq $HostType) 'the record names the host type it is stored under'
        Assert-True ($record.RequiresElevation -is [bool]) 'RequiresElevation is a boolean, not a truthy value'
        Assert-Equal -Expected $RequiresElevation -Actual $record.RequiresElevation -Because 'RequiresElevation'

        $findings = @()
        foreach ($name in @('Assert', 'AssertMinimum') + $script:OptionalSlots) {
            $want = $Slot[$name]
            $have = $record[$name]
            if ($null -eq $want) {
                if ($null -ne $have) { $findings += "$name must be `$null on this host and holds a $($have.GetType().Name)" }
                continue
            }
            if ($have -isnot [scriptblock]) { $findings += "$name must hold the body of $want and is empty"; continue }
            if (-not [object]::ReferenceEquals($have, (Get-Command -Name $want).ScriptBlock)) {
                $findings += "$name must hold the body of $want and holds another script block"
            }
        }
        Assert-NoFinding $findings "$HostType registered a different record"
    }
}

Describe 'optional capabilities are resolved by name when a host registers' {
    BeforeAll {
        # Global on purpose: the facade resolves names with Get-Command from
        # its own module scope, which reaches the global session and not the
        # scope of this file.
        $script:FixtureFunction = @(
            'Test-YurunaRegistryFixtureAssert', 'Test-YurunaRegistryFixtureMinimum', 'Get-YurunaRegistryFixtureDisplay',
            'Get-YurunaRegistryFixtureTeardown', 'Get-YurunaRegistryFixtureClock', 'Get-YurunaRegistryFixtureNetwork',
            'Get-YurunaRegistryFixtureMetric')
        function global:Test-YurunaRegistryFixtureAssert { $true }
        function global:Test-YurunaRegistryFixtureMinimum { $true }
        function global:Get-YurunaRegistryFixtureDisplay { 'AlreadyActive' }
        function global:Get-YurunaRegistryFixtureTeardown { 'AlreadyAbsent' }
        function global:Get-YurunaRegistryFixtureClock { @{ Succeeded = $true; Message = '' } }
        function global:Get-YurunaRegistryFixtureNetwork { @{ Healthy = $true } }
        function global:Get-YurunaRegistryFixtureMetric { [pscustomobject]@{ Status = 'Present'; Reason = '' } }

        # The registration helper's own parameter for each optional slot, and
        # the fixture function that fills the slot.
        $script:SlotParameter = [ordered]@{
            Display = 'DisplayFn'; DisplayTeardown = 'TeardownFn'; ClockSync = 'ClockSyncFn'
            NetworkHealth = 'NetworkHealthFn'; MetricsExporter = 'MetricsExporterFn'
        }
        $script:SlotFixture = @{
            Display = 'Get-YurunaRegistryFixtureDisplay'; DisplayTeardown = 'Get-YurunaRegistryFixtureTeardown'
            ClockSync = 'Get-YurunaRegistryFixtureClock'; NetworkHealth = 'Get-YurunaRegistryFixtureNetwork'
            MetricsExporter = 'Get-YurunaRegistryFixtureMetric'
        }

        function Get-FixtureArgument {
            <#
            .SYNOPSIS
                Arguments that register a fixture host whose five optional
                functions all exist.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([Parameter(Mandatory)][string]$HostType)

            $argument = @{
                HostType = $HostType; RequiresElevation = $true
                AssertFn = 'Test-YurunaRegistryFixtureAssert'; MinimumFn = 'Test-YurunaRegistryFixtureMinimum'
            }
            foreach ($slot in $script:SlotParameter.Keys) { $argument[$script:SlotParameter[$slot]] = $script:SlotFixture[$slot] }
            return $argument
        }

        function Invoke-FixtureRegistration {
            <#
            .SYNOPSIS
                Runs the facade's private registration helper and returns what
                it wrote and what it stored.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param([Parameter(Mandatory, Position = 0)][hashtable]$Argument)

            # -Verbose so the capability lines are written at all; the two
            # redirections return warnings and verbose lines as records rather
            # than letting them reach the host.
            $emitted = @(& $script:Facade { param($a) Register-IfAvailable @a -Verbose } $Argument 3>&1 4>&1)
            return [pscustomobject]@{
                Verbose = @($emitted | Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
                Warning = @($emitted | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
                Output  = @($emitted | Where-Object {
                        $_ -isnot [System.Management.Automation.VerboseRecord] -and $_ -isnot [System.Management.Automation.WarningRecord]
                    })
                Record  = Get-HostConditionProvider -HostType $Argument.HostType
            }
        }

        function Get-SlotFinding {
            <#
            .SYNOPSIS
                What differs between a stored record and the fixture function
                expected in each optional slot. A slot absent from -Want is
                expected to be $null.
            #>
            [CmdletBinding()]
            [OutputType([string[]])]
            param([Parameter(Mandatory)]$Record, [hashtable]$Want = @{})

            $findings = @()
            foreach ($slot in $script:OptionalSlots) {
                $have = $Record[$slot]
                if ($null -eq $Want[$slot]) {
                    if ($null -ne $have) { $findings += "$slot must be `$null" }
                    continue
                }
                if (-not [object]::ReferenceEquals($have, (Get-Command -Name $Want[$slot]).ScriptBlock)) {
                    $findings += "$slot must hold the body of $($Want[$slot])"
                }
            }
            return $findings
        }
    }

    AfterAll {
        foreach ($name in $script:FixtureFunction) { Remove-Item -Path "Function:/$name" -ErrorAction SilentlyContinue }
        # The registry outlives a re-import by design, so the fixture hosts are
        # taken out by key; clearing it would also drop the three real hosts.
        $store = (Get-YurunaRegistryDirectory)['HostCondition'].Store[0]
        foreach ($hostType in @($store.Keys | Where-Object { $_ -like 'host.fixture.*' })) { $store.Remove($hostType) }
    }

    It 'fills all five optional slots when every named function exists' {
        $run = Invoke-FixtureRegistration (Get-FixtureArgument -HostType 'host.fixture.full')
        Assert-Equal -Expected 0 -Actual ($run.Verbose.Count + $run.Warning.Count + $run.Output.Count) `
            -Because "a registration with nothing missing writes nothing: $($run.Verbose + $run.Warning -join ' | ')"
        Assert-NotNull $run.Record 'the fixture host did not register'
        Assert-True ((@($run.Record.Keys) -join ', ') -ceq $script:RecordFields) 'the record fields or their order changed'
        Assert-True ($run.Record.HostType -ceq 'host.fixture.full') 'the record names its host type'
        Assert-True ($run.Record.RequiresElevation -is [bool] -and $run.Record.RequiresElevation) 'RequiresElevation is carried into the record'
        Assert-True ([object]::ReferenceEquals($run.Record.Assert, (Get-Command -Name 'Test-YurunaRegistryFixtureAssert').ScriptBlock)) `
            'Assert must hold the body of the function named for it'
        Assert-True ([object]::ReferenceEquals($run.Record.AssertMinimum, (Get-Command -Name 'Test-YurunaRegistryFixtureMinimum').ScriptBlock)) `
            'AssertMinimum must hold the body of the function named for it'
        Assert-NoFinding (Get-SlotFinding -Record $run.Record -Want $script:SlotFixture) 'an optional slot is not bound to its function'
    }

    It 'leaves <Slot> empty and says so on the verbose stream when its function is absent' -TestCases @(
        @{ Slot = 'Display';         Wording = 'display ensure' }
        @{ Slot = 'DisplayTeardown'; Wording = 'display teardown' }
        @{ Slot = 'ClockSync';       Wording = 'clock sync' }
        @{ Slot = 'NetworkHealth';   Wording = 'guest-network probe' }
        @{ Slot = 'MetricsExporter'; Wording = 'metrics-exporter convergence' }
    ) {
        param([string]$Slot, [string]$Wording)

        $fixtureHost = "host.fixture.without-$Slot"
        $argument = Get-FixtureArgument -HostType $fixtureHost
        $argument[$script:SlotParameter[$Slot]] = 'Get-YurunaRegistryFixtureAbsent'
        $run = Invoke-FixtureRegistration $argument

        $line = "Test.HostCondition: $fixtureHost $Wording 'Get-YurunaRegistryFixtureAbsent' not found; skipping that capability."
        Assert-Equal -Expected 1 -Actual $run.Verbose.Count -Because "one line per missing capability: $($run.Verbose -join ' | ')"
        Assert-True ([string]::Equals($line, $run.Verbose[0], [StringComparison]::Ordinal)) `
            "the verbose line changed.`nexpected: $line`nactual:   $($run.Verbose[0])"
        Assert-Equal -Expected 0 -Actual $run.Warning.Count -Because 'a missing optional capability is not a warning'

        # An optional name that cannot be resolved costs only its own slot.
        Assert-NotNull $run.Record 'a missing optional capability must never cost the host its registration'
        Assert-True ($run.Record.Assert -is [scriptblock] -and $run.Record.AssertMinimum -is [scriptblock]) 'the mandatory slots stay bound'
        $want = $script:SlotFixture.Clone()
        $want[$Slot] = $null
        Assert-NoFinding (Get-SlotFinding -Record $run.Record -Want $want) "only $Slot may be empty"
    }

    It 'reports every missing capability, in slot order' {
        $argument = Get-FixtureArgument -HostType 'host.fixture.bare'
        $expected = @()
        foreach ($pair in @(
                @('DisplayFn', 'display ensure'), @('TeardownFn', 'display teardown'), @('ClockSyncFn', 'clock sync'),
                @('NetworkHealthFn', 'guest-network probe'), @('MetricsExporterFn', 'metrics-exporter convergence'))) {
            $argument[$pair[0]] = "Get-YurunaRegistryFixtureAbsent$($pair[0])"
            $expected += "Test.HostCondition: host.fixture.bare $($pair[1]) 'Get-YurunaRegistryFixtureAbsent$($pair[0])' not found; skipping that capability."
        }
        $run = Invoke-FixtureRegistration $argument
        Assert-True ([string]::Equals(($expected -join "`n"), ($run.Verbose -join "`n"), [StringComparison]::Ordinal)) `
            "the verbose lines or their order changed:`n$($run.Verbose -join "`n")"
        Assert-Equal -Expected 0 -Actual $run.Warning.Count -Because 'missing optional capabilities are not warnings'
        Assert-NotNull $run.Record 'the host still registers with its mandatory slots'
        Assert-NoFinding (Get-SlotFinding -Record $run.Record) 'every optional slot is empty'
    }

    It 'says nothing about a capability that was never named' {
        $never = Invoke-FixtureRegistration @{
            HostType = 'host.fixture.unnamed'; AssertFn = 'Test-YurunaRegistryFixtureAssert'; MinimumFn = 'Test-YurunaRegistryFixtureMinimum'
        }
        $blank = Invoke-FixtureRegistration @{
            HostType = 'host.fixture.blank'; AssertFn = 'Test-YurunaRegistryFixtureAssert'; MinimumFn = 'Test-YurunaRegistryFixtureMinimum'
            DisplayFn = ''; TeardownFn = ''; ClockSyncFn = ''; NetworkHealthFn = ''; MetricsExporterFn = ''
        }
        foreach ($run in @($never, $blank)) {
            Assert-Equal -Expected 0 -Actual ($run.Verbose.Count + $run.Warning.Count) `
                -Because "an unnamed capability is not a missing one: $($run.Verbose + $run.Warning -join ' | ')"
            Assert-NotNull $run.Record 'the host registers with its mandatory slots alone'
            Assert-True ((@($run.Record.Keys) -join ', ') -ceq $script:RecordFields) 'an empty slot is still a field of the record'
            Assert-NoFinding (Get-SlotFinding -Record $run.Record) 'every optional slot is empty'
            Assert-True ($run.Record.RequiresElevation -is [bool] -and -not $run.Record.RequiresElevation) `
                'RequiresElevation is $false unless the caller says otherwise'
        }
    }

    It 'leaves a slot empty without comment when its name resolves to something that is not a function' {
        $argument = Get-FixtureArgument -HostType 'host.fixture.cmdlet'
        $argument.ClockSyncFn = 'Get-Date'
        $run = Invoke-FixtureRegistration $argument
        Assert-Equal -Expected 0 -Actual ($run.Verbose.Count + $run.Warning.Count) -Because 'the name did resolve'
        Assert-NotNull $run.Record 'the host registers'
        $want = $script:SlotFixture.Clone()
        $want.ClockSync = $null
        Assert-NoFinding (Get-SlotFinding -Record $run.Record -Want $want) 'a cmdlet has no script block to store'
    }

    It 'skips the whole registration with one warning when <What> is missing' -TestCases @(
        @{
            What = 'Assert'; Missing = 'Get-YurunaRegistryFixtureAbsentAssert'
            AssertFn = 'Get-YurunaRegistryFixtureAbsentAssert'; MinimumFn = 'Test-YurunaRegistryFixtureMinimum'
        }
        @{
            What = 'AssertMinimum'; Missing = 'Get-YurunaRegistryFixtureAbsentMinimum'
            AssertFn = 'Test-YurunaRegistryFixtureAssert'; MinimumFn = 'Get-YurunaRegistryFixtureAbsentMinimum'
        }
        @{
            What = 'each mandatory function'; Missing = 'Get-YurunaRegistryFixtureAbsentAssert, Get-YurunaRegistryFixtureAbsentMinimum'
            AssertFn = 'Get-YurunaRegistryFixtureAbsentAssert'; MinimumFn = 'Get-YurunaRegistryFixtureAbsentMinimum'
        }
    ) {
        param([string]$What, [string]$Missing, [string]$AssertFn, [string]$MinimumFn)

        $fixtureHost = "host.fixture.torn-$($What -replace '\s', '-')"
        $argument = Get-FixtureArgument -HostType $fixtureHost
        $argument.AssertFn = $AssertFn
        $argument.MinimumFn = $MinimumFn
        # Unresolvable too, and never reported: the mandatory check returns first.
        $argument.DisplayFn = 'Get-YurunaRegistryFixtureAbsent'
        $run = Invoke-FixtureRegistration $argument

        # Rendered through the catalog here as well, so the comparison holds
        # under whatever operator locale the host resolves.
        $warning = & $script:Facade {
            param($a) Format-YurunaOperatorMessage -Key 'runner.operator_597096826951b442' -Arguments $a
        } @{ hostType = $fixtureHost; join = $Missing }
        Assert-Equal -Expected 1 -Actual $run.Warning.Count -Because "one warning names every missing function: $($run.Warning -join ' | ')"
        Assert-True ([string]::Equals($warning, $run.Warning[0], [StringComparison]::Ordinal)) `
            "the warning changed.`nexpected: $warning`nactual:   $($run.Warning[0])"
        Assert-True ($run.Warning[0].Contains($fixtureHost) -and $run.Warning[0].Contains($Missing)) `
            'the warning names the host type and every missing function'
        Assert-Equal -Expected 0 -Actual $run.Verbose.Count `
            -Because 'optional capabilities are not resolved for a host that will not register'
        Assert-Null $run.Record 'a host with a missing mandatory function must not register at all'
    }

    It 'makes one registration call that names every optional slot, empty or not' {
        Mock Register-HostConditionProvider -ModuleName Test.HostCondition { }
        $null = Invoke-FixtureRegistration @{
            HostType = 'host.fixture.call'; AssertFn = 'Test-YurunaRegistryFixtureAssert'; MinimumFn = 'Test-YurunaRegistryFixtureMinimum'
            ClockSyncFn = 'Get-YurunaRegistryFixtureClock'
        }
        Should -Invoke -CommandName Register-HostConditionProvider -ModuleName Test.HostCondition -Times 1 -Exactly -Scope It
        # An empty slot is passed as an explicit $null, so what the record holds
        # never depends on the defaults of the function that stores it.
        Should -Invoke -CommandName Register-HostConditionProvider -ModuleName Test.HostCondition -Times 1 -Exactly -Scope It -ParameterFilter {
            $bound = $PesterBoundParameters
            $unbound = @('HostType', 'Assert', 'AssertMinimum', 'RequiresElevation', 'Display', 'DisplayTeardown', 'ClockSync',
                'NetworkHealth', 'MetricsExporter' | Where-Object { -not $bound.ContainsKey($_) })
            $unbound.Count -eq 0 -and $HostType -ceq 'host.fixture.call' -and $RequiresElevation -eq $false -and
            $Assert -is [scriptblock] -and $AssertMinimum -is [scriptblock] -and $ClockSync -is [scriptblock] -and
            $null -eq $Display -and $null -eq $DisplayTeardown -and $null -eq $NetworkHealth -and $null -eq $MetricsExporter
        }
    }

    It 'makes no registration call for a host with a missing mandatory function' {
        Mock Register-HostConditionProvider -ModuleName Test.HostCondition { }
        $argument = Get-FixtureArgument -HostType 'host.fixture.nocall'
        $argument.MinimumFn = 'Get-YurunaRegistryFixtureAbsentMinimum'
        $run = Invoke-FixtureRegistration $argument
        Assert-Equal -Expected 1 -Actual $run.Warning.Count -Because 'the missing function is reported'
        Should -Invoke -CommandName Register-HostConditionProvider -ModuleName Test.HostCondition -Times 0 -Exactly -Scope It
    }
}

Describe 'an optional slot nobody supplied is stored as $null' {
    AfterAll {
        $store = (Get-YurunaRegistryDirectory)['HostCondition'].Store[0]
        foreach ($hostType in @($store.Keys | Where-Object { $_ -like 'host.fixture.*' })) { $store.Remove($hostType) }
    }

    It 'stores the same record whether an optional argument is omitted, passed as $null or splatted as $null' {
        $assert = { $true }
        $minimum = { $true }
        Register-HostConditionProvider -HostType 'host.fixture.omitted' -Assert $assert -AssertMinimum $minimum
        Register-HostConditionProvider -HostType 'host.fixture.null' -Assert $assert -AssertMinimum $minimum `
            -Display $null -DisplayTeardown $null -ClockSync $null -NetworkHealth $null -MetricsExporter $null
        $empty = @{ Display = $null; DisplayTeardown = $null; ClockSync = $null; NetworkHealth = $null; MetricsExporter = $null }
        Register-HostConditionProvider -HostType 'host.fixture.splat' -Assert $assert -AssertMinimum $minimum @empty

        $findings = @()
        foreach ($hostType in @('host.fixture.omitted', 'host.fixture.null', 'host.fixture.splat')) {
            $record = Get-HostConditionProvider -HostType $hostType
            if ((@($record.Keys) -join ', ') -cne $script:RecordFields) { $findings += "${hostType}: fields are $(@($record.Keys) -join ', ')" }
            if (-not [object]::ReferenceEquals($record.Assert, $assert)) { $findings += "${hostType}: Assert is not the block that was passed" }
            if (-not [object]::ReferenceEquals($record.AssertMinimum, $minimum)) { $findings += "${hostType}: AssertMinimum is not the block that was passed" }
            if ($record.RequiresElevation -isnot [bool] -or $record.RequiresElevation) { $findings += "${hostType}: RequiresElevation is not `$false" }
            foreach ($slot in $script:OptionalSlots) {
                if (-not $record.Contains($slot)) { $findings += "${hostType}: $slot is not a field of the record" }
                elseif ($null -ne $record[$slot]) { $findings += "${hostType}: $slot is not `$null" }
            }
        }
        Assert-NoFinding $findings 'the three ways of leaving a capability out do not store the same record'
    }
}
