<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42861ba7-21b4-45b8-96e4-6615fceded8a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service vm build plan adopt outcome pester
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
    Pester coverage for the service VM bring-up pipeline: builder plans that
    run before teardown, the bounded build, adoption of a running guest, the
    one start outcome, and the host-side proof's previous daemon.
.DESCRIPTION
    Builders cannot run here (they need a hypervisor and a base image), so their
    plan-before-teardown order is read from the syntax tree of all twelve. The
    shared functions run for real against stub builders and injected probes.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.ServiceStartSource.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.ExtensionService.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.SeedMedia.psm1') -Force -DisableNameChecking

    function Get-BuilderCommand {
        param($Ast, [string[]]$Name)
        $wanted = $Name
        @($Ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $wanted }, $true)) |
            Sort-Object { $_.Extent.StartOffset }
    }
    function New-StubBuilder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes a disposable stub script under Pester TestDrive only.')]
        param([string]$Body)
        $path = Join-Path $TestDrive ("builder-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, "param([string]`$VMName, [switch]`$AllowPseudoLocale, [switch]`$PlanOnly)`n$Body`n")
        return $path
    }
}

Describe 'service VM builders resolve their plan before anything is torn down' {
    It '<Builder> checks every refusing input, then stops for -PlanOnly, before its teardown' -ForEach @(
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            foreach ($service in 'caching-proxy-service', 'stash-service', 'pool-control-service', 'download-agent-service') {
                @{ Builder = "host/$platform/guest.$service/New-VM.ps1"; Platform = $platform; Service = $service }
            }
        }
    ) {
        $path = Join-Path $script:RepoRoot $Builder
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-Equal -Expected 0 -Actual @($errors).Count -Because "$Builder parses"
        $param = $ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PlanOnly' }
        Assert-True ($null -ne $param) "$Builder takes -PlanOnly"

        $teardownName = @{ 'ubuntu.kvm' = 'Remove-KvmDomainDefinition'; 'macos.utm' = 'Remove-UtmTestVM'; 'windows.hyper-v' = 'Remove-HyperVGuestDefinition' }[$Platform]
        $teardown = @(Get-BuilderCommand -Ast $ast -Name $teardownName)
        Assert-Equal -Expected 1 -Actual $teardown.Count -Because "$Builder tears the prior VM down once"
        $planExit = @($ast.FindAll({ param($n)
                    $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '$PlanOnly' }, $true))
        Assert-Equal -Expected 1 -Actual $planExit.Count -Because "$Builder has one -PlanOnly exit"
        Assert-True ($planExit[0].Clauses[0].Item2.Extent.Text -match 'exit 0') "$Builder exits 0 after an accepted plan"
        Assert-True ($planExit[0].Extent.EndOffset -lt $teardown[0].Extent.StartOffset) "$Builder stops for -PlanOnly before its teardown"

        $network = @{ 'ubuntu.kvm' = 'Resolve-GuestHostBinding'; 'macos.utm' = 'Resolve-UtmNetworkMode'; 'windows.hyper-v' = 'Resolve-HyperVGuestSwitch' }[$Platform]
        foreach ($inputCommand in 'Get-YurunaSshPublicKey', 'Get-Password', $network) {
            $calls = @(Get-BuilderCommand -Ast $ast -Name $inputCommand)
            Assert-True ($calls.Count -ge 1) "$Builder reads $inputCommand"
            Assert-True ($calls[0].Extent.EndOffset -lt $planExit[0].Extent.StartOffset) "$Builder reads $inputCommand in its plan"
        }
        $text = $ast.Extent.Text
        $templateCheck = $text.IndexOf("host.operator_9a1ef2a7551102d0")
        Assert-True ($templateCheck -gt 0 -and $templateCheck -lt $planExit[0].Extent.StartOffset) "$Builder checks its seed templates in its plan"
        $hostDegraded = $text.IndexOf("Write-SeedDegradation -VMName `$VMName -Name 'hostAddress'")
        Assert-True ($hostDegraded -gt 0 -and $hostDegraded -lt $planExit[0].Extent.StartOffset) "$Builder reports an empty host address in its plan"
        # A malformed vmStart.serviceHostNames entry refuses these three seeds. By
        # the time the builder renders, its Start has removed the proxy VM or
        # withdrawn the service's advertisement, so the plan reads the names.
        if ($Service -ne 'pool-control-service') {
            $names = @(Get-BuilderCommand -Ast $ast -Name 'Get-ExtensionServiceHostNameSeed')
            Assert-True ($names.Count -ge 1) "$Builder reads the service host names"
            Assert-True ($names[0].Extent.EndOffset -lt $planExit[0].Extent.StartOffset) "$Builder reads the service host names in its plan"
        }

        # Every later step that can still refuse the build runs before teardown too.
        foreach ($prepare in 'Assert-YurunaBaseImage', 'New-CloudInitUserData', 'Get-YurunaConfigServiceSeedMaterial', 'Get-YurunaBumpCa') {
            foreach ($call in @(Get-BuilderCommand -Ast $ast -Name $prepare)) {
                Assert-True ($call.Extent.EndOffset -lt $teardown[0].Extent.StartOffset) "$Builder runs $prepare before its teardown"
            }
        }
        if ($Service -ne 'caching-proxy-service') {
            $aggregator = $text.IndexOf("Write-SeedDegradation -VMName `$VMName -Name 'aggregatorUrl'")
            Assert-True ($aggregator -gt $planExit[0].Extent.EndOffset -and $aggregator -lt $teardown[0].Extent.StartOffset) "$Builder reports an unresolved aggregator before its teardown"
        }
        if ($Builder -eq 'host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1') {
            $empty = $text.IndexOf("host.operator_a32e7c960a5619ec")
            Assert-True ($empty -gt 0 -and $empty -lt $planExit[0].Extent.StartOffset) 'the KVM proxy refuses an unresolved network in its plan'
        }
    }

    It '<Builder> refuses a malformed service host name in its plan' -ForEach @(
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            foreach ($service in 'caching-proxy-service', 'stash-service', 'download-agent-service') {
                @{ Builder = "host/$platform/guest.$service/New-VM.ps1" }
            }
        }
    ) {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $Builder), [ref]$null, [ref]$null)
        $names = @(Get-BuilderCommand -Ast $ast -Name 'Get-ExtensionServiceHostNameSeed')
        Assert-True ($names.Count -ge 1) "$Builder reads the service host names"
        # The builder's own statement, so a catch that swallowed the refusal fails here.
        $statement = $names[0]
        while ($statement.Parent -and $statement.Parent -isnot [Management.Automation.Language.NamedBlockAst]) { $statement = $statement.Parent }
        $module = Join-Path $script:RepoRoot 'test/modules/Test.ExtensionService.psm1'
        # The comma-joined form of the daemon's flag is one entry, and no name.
        $stub = New-StubBuilder ("`$ErrorActionPreference = 'Stop'`nImport-Module '$module' -DisableNameChecking`n" +
            "`$tc = [ordered]@{ vmStart = [ordered]@{ serviceHostNames = @('cache.lab,stash.lab') } }`n" +
            "$($statement.Extent.Text)`nexit 0")
        $plan = Test-YurunaServiceVmBuildPlan -BuilderPath $stub -VMName 'fixture-vm' 6>$null
        Assert-Equal -Expected $false -Actual $plan.Ok -Because "$Builder refuses the plan"
    }
}

Describe 'Write-SeedDegradation' {
    It 'warns and emits the token line the build collects' {
        $warnings = $null
        $out = @(Write-SeedDegradation -VMName 'fixture-vm' -Name 'aggregatorUrl' -WarningVariable warnings -WarningAction SilentlyContinue)
        Assert-StringEqual -Expected 'YURUNA_SEED_DEGRADED=aggregatorUrl' -Actual ($out -join '|')
        Assert-Equal -Expected 1 -Actual @($warnings).Count
    }
}

Describe 'Test-YurunaServiceVmBuildPlan' {
    It 'runs the builder with -PlanOnly and accepts exit 0' {
        $record = Join-Path $TestDrive 'plan-args.txt'
        $builder = New-StubBuilder "Set-Content -LiteralPath '$record' -Value (`"`$VMName|`$PlanOnly`"); exit 0"
        $result = Test-YurunaServiceVmBuildPlan -BuilderPath $builder -VMName 'fixture-vm' 6>$null
        Assert-True $result.Ok 'an accepted plan'
        Assert-StringEqual -Expected 'fixture-vm|True' -Actual (Get-Content -LiteralPath $record -Raw).Trim()
    }
    It 'refuses with the builder exit code and names the VM' {
        $builder = New-StubBuilder 'exit 3'
        $result = Test-YurunaServiceVmBuildPlan -BuilderPath $builder -VMName 'fixture-vm' 6>$null
        Assert-Equal -Expected $false -Actual $result.Ok
        Assert-Equal -Expected 3 -Actual $result.ExitCode
        Assert-True ($result.Error -like '*fixture-vm*exit 3*') "the refusal names the VM and the exit: $($result.Error)"
    }
    It 'refuses a builder that is not there' {
        $result = Test-YurunaServiceVmBuildPlan -BuilderPath (Join-Path $TestDrive 'absent.ps1') -VMName 'fixture-vm'
        Assert-Equal -Expected $false -Actual $result.Ok
    }
    It 'collects the seed values the plan reports baked empty' {
        $builder = New-StubBuilder "Write-Output 'YURUNA_SEED_DEGRADED=hostAddress'; exit 0"
        $result = Test-YurunaServiceVmBuildPlan -BuilderPath $builder -VMName 'fixture-vm' 6>$null
        Assert-StringEqual -Expected 'hostAddress' -Actual ($result.Degraded -join ',')
    }
}

Describe 'Invoke-YurunaServiceVmBuild bounds and relays the builder' {
    BeforeAll {
        function global:Wait-VMRunning { param($VMName, $TimeoutSeconds) $null = $VMName, $TimeoutSeconds; $true }
        function global:Start-YurunaConfigServiceIfEnabled { param($Config, $StartScript) $null = $Config, $StartScript }
        Mock -ModuleName Test.ServiceVm Test-YurunaServiceOperationCurrent { $true }
    }
    AfterAll {
        Remove-Item -LiteralPath function:global:Wait-VMRunning, function:global:Start-YurunaConfigServiceIfEnabled -ErrorAction SilentlyContinue
    }
    It 'stops a builder that outlives its bound and classifies the stop' {
        $pidFile = Join-Path $TestDrive 'builder.pid'
        $builder = New-StubBuilder "Set-Content -LiteralPath '$pidFile' -Value `$PID; Start-Sleep -Seconds 60"
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-YurunaServiceVmBuild -BuilderPath $builder -HostType 'host.ubuntu.kvm' -VMName 'fixture-vm' -OperationContext @{} -TimeoutSeconds 4 -Confirm:$false 6>$null
        $clock.Stop()
        Assert-Equal -Expected $false -Actual $result.Ok
        Assert-StringEqual -Expected 'build-timeout' -Actual $result.Outcome
        Assert-Equal -Expected 124 -Actual $result.ExitCode
        Assert-True ($clock.Elapsed.TotalSeconds -lt 30) "the bound ended the wait ($($clock.Elapsed.TotalSeconds) s)"
        $builderPid = [int](Get-Content -LiteralPath $pidFile -Raw).Trim()
        Assert-True ($null -eq (Get-Process -Id $builderPid -ErrorAction SilentlyContinue)) 'the builder process is gone'
    }
    It 'relays builder lines, keeps the degradation tokens out of them, and reports a built VM' {
        $builder = New-StubBuilder "Write-Output 'first line'; Write-Output 'YURUNA_SEED_DEGRADED=aggregatorUrl'; Write-Output 'last line'; exit 0"
        $all = @(Invoke-YurunaServiceVmBuild -BuilderPath $builder -HostType 'host.ubuntu.kvm' -VMName 'fixture-vm' -OperationContext @{} -Confirm:$false 6>&1)
        $result = $all | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        $info = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] })
        Assert-True $result.Ok 'the build passed'
        Assert-StringEqual -Expected 'built' -Actual $result.Outcome
        Assert-StringEqual -Expected 'aggregatorUrl' -Actual ($result.Degraded -join ',')
        $lines = @($info | ForEach-Object { [string]$_.MessageData })
        Assert-True ($lines -contains 'first line' -and $lines -contains 'last line') "the builder output is relayed: $($lines -join ' / ')"
        Assert-True (-not ($lines -match 'YURUNA_SEED_DEGRADED')) 'the token is not printed'
    }
    It 'passes a failing builder exit code through' {
        $builder = New-StubBuilder 'exit 23'
        $result = Invoke-YurunaServiceVmBuild -BuilderPath $builder -HostType 'host.ubuntu.kvm' -VMName 'fixture-vm' -OperationContext @{} -Confirm:$false 6>$null
        Assert-Equal -Expected 23 -Actual $result.ExitCode
        Assert-StringEqual -Expected 'build-failed' -Actual $result.Outcome
    }
}

Describe 'Invoke-YurunaServiceVmBuilderRun' {
    It 'relays complete CRLF lines and split terminators without carriage returns or seed tokens' {
        $builder = New-StubBuilder 'exit 0'
        Mock -ModuleName Test.ServiceVm Invoke-BoundedNativeCommand {
            param($OutputHandler)
            & $OutputHandler "first line`r`nYURUNA_SEED_DEGRADED=aggregatorUrl`r" 'stdout'
            & $OutputHandler "`nlast line`r`n" 'stdout'
            & $OutputHandler "diagnostic`r`n" 'stderr'
            [pscustomobject]@{ Started = $true; TimedOut = $false; ExitCode = 0 }
        }
        $all = @(Invoke-YurunaServiceVmBuilderRun -BuilderPath $builder -VMName 'fixture-vm' 6>&1)
        $result = $all | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        $lines = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        Assert-True $result.Ok 'the builder succeeded'
        Assert-StringEqual -Expected 'aggregatorUrl' -Actual ($result.Degraded -join ',')
        Assert-Equal -Expected 3 -Actual $lines.Count -Because 'each stream relays complete lines and consumes the seed token'
        Assert-StringEqual -Expected "first line|last line|diagnostic" -Actual ($lines -join '|')
    }

    It 'passes each builder argument after -VMName to the child, a value holding a space included' {
        $builder = Join-Path $TestDrive ("builder-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($builder, "param([string]`$VMName, [string]`$MacAddress, [int]`$MemoryMb, [string]`$SquidCacheMem, [switch]`$AllowPseudoLocale)`nWrite-Output ('BOUND:{0}|{1}|{2}|{3}|{4}' -f `$VMName, `$MacAddress, `$MemoryMb, `$SquidCacheMem, [bool]`$AllowPseudoLocale)`n")
        $all = @(Invoke-YurunaServiceVmBuilderRun -BuilderPath $builder -VMName 'fixture-vm' -AllowPseudoLocale `
                -BuilderArgument @('-MacAddress', '02:42:42:42:42:42', '-MemoryMb', '4096', '-SquidCacheMem', '2 GB') 6>&1)
        $result = $all | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        $lines = @($all | Where-Object { $_ -is [Management.Automation.InformationRecord] } | ForEach-Object { [string]$_.MessageData })
        Assert-True $result.Ok 'the run passed'
        Assert-StringEqual -Expected 'built' -Actual $result.Outcome
        Assert-True ($lines -contains 'BOUND:fixture-vm|02:42:42:42:42:42|4096|2 GB|True') "every argument bound by name: $($lines -join ' / ')"
    }
    It 'refuses a builder that is not there without starting a child' {
        Mock -ModuleName Test.ServiceVm Invoke-ServiceVmBuilderProcess { throw 'must not start a child' }
        $result = Invoke-YurunaServiceVmBuilderRun -BuilderPath (Join-Path $TestDrive 'absent.ps1') -VMName 'fixture-vm'
        Assert-Equal -Expected $false -Actual $result.Ok
        Assert-StringEqual -Expected 'build-failed' -Actual $result.Outcome
        Assert-Equal -Expected 1 -Actual $result.ExitCode
    }
}

Describe 'Resolve-YurunaServiceVmAdoption' {
    BeforeAll {
        $script:Hooks = @{
            GetState       = { param($Name) $null = $Name; $script:State }
            ResolveAddress = { param($Name) $null = $Name; $script:Address }
            TestPortOpen   = { param($Address, $Port) $null = $Address, $Port; $script:Serving }
            InvokeInGuest  = { param($Address, $Key, $Account, $Command) $null = $Address, $Key, $Account, $Command
                if ($null -eq $script:CloudInit) { return $null }; @{ output = "YURUNA_CLOUDINIT=$($script:CloudInit)" } }
        }
    }
    It '<Case>' -ForEach @(
        @{ Case = 'rebuilds a VM that is not running'; State = 'stopped'; Address = ''; Serving = $false; CloudInit = $null; Source = $true; Decision = 'rebuild'; Reason = 'vm-not-running (stopped)' }
        @{ Case = 'rebuilds when the driver resolves no live address'; State = 'running'; Address = ''; Serving = $true; CloudInit = $null; Source = $true; Decision = 'rebuild'; Reason = 'no-live-address' }
        @{ Case = 'adopts a guest serving at its live address'; State = 'running'; Address = '192.0.2.40'; Serving = $true; CloudInit = $null; Source = $true; Decision = 'adopt-serving'; Reason = 'serving' }
        @{ Case = 'rebuilds a serving guest whose build is stale'; State = 'running'; Address = '192.0.2.40'; Serving = $true; CloudInit = $null; Source = $false; Decision = 'rebuild'; Reason = 'stale-build' }
        @{ Case = 'adopts a guest that reports cloud-init still running'; State = 'running'; Address = '192.0.2.40'; Serving = $false; CloudInit = 'running'; Source = $true; Decision = 'adopt-building'; Reason = 'building' }
        @{ Case = 'rebuilds a guest whose cloud-init finished without a daemon'; State = 'running'; Address = '192.0.2.40'; Serving = $false; CloudInit = 'error'; Source = $true; Decision = 'rebuild'; Reason = 'not-serving (cloud-init: error)' }
        @{ Case = 'rebuilds a guest that does not answer'; State = 'running'; Address = '192.0.2.40'; Serving = $false; CloudInit = $null; Source = $true; Decision = 'rebuild'; Reason = 'not-serving (guest silent)' }
    ) {
        $script:State = $State; $script:Address = $Address; $script:Serving = $Serving; $script:CloudInit = $CloudInit
        $sourceAnswer = $Source
        $result = Resolve-YurunaServiceVmAdoption -VMName 'fixture-vm' -Port 80 -GuestKey 'guest.fixture' -User 'fixture-admin' `
            -SourceCheck { param($a) $null = $a; $sourceAnswer }.GetNewClosure() @script:Hooks
        Assert-StringEqual -Expected $Decision -Actual $result.Decision
        Assert-StringEqual -Expected $Reason -Actual $result.Reason
        if ($Decision -ne 'rebuild') { Assert-StringEqual -Expected $Address -Actual $result.Address }
    }
}

Describe 'Resolve-YurunaServiceStartOutcome' {
    It '<Case>' -ForEach @(
        @{ Case = 'a serving daemon is confirmed and advertised'; Outcome = 'Ready'; Failure = $false; Wanted = $true; Source = $true; Result = 'confirmed'; Advertise = $true; Exit = 'Ok'; State = 'serving' }
        @{ Case = 'a daemon serving only inside the guest is advertised'; Outcome = 'Unreachable'; Failure = $false; Wanted = $true; Source = $true; Result = 'confirmed'; Advertise = $true; Exit = 'Ok'; State = 'serving' }
        @{ Case = 'a guest still building is confirmed but not advertised'; Outcome = 'StillBuilding'; Failure = $false; Wanted = $true; Source = $true; Result = 'confirmed'; Advertise = $false; Exit = 'Ok'; State = 'building' }
        @{ Case = 'a daemon that never served is failed and not advertised'; Outcome = 'NotServing'; Failure = $true; Wanted = $true; Source = $true; Result = 'failed'; Advertise = $false; Exit = 'Failure'; State = 'not-serving' }
        @{ Case = 'a refused build is failed and not advertised'; Outcome = 'Ready'; Failure = $false; Wanted = $true; Source = $false; Result = 'failed'; Advertise = $false; Exit = 'Failure'; State = 'wrong-build' }
        @{ Case = 'a stop requested during the start wins over a serving daemon'; Outcome = 'Ready'; Failure = $false; Wanted = $false; Source = $true; Result = 'failed'; Advertise = $false; Exit = 'Failure'; State = 'stop-requested' }
    ) {
        $verdict = [pscustomobject]@{ Outcome = $Outcome; IsFailure = $Failure }
        $o = Resolve-YurunaServiceStartOutcome -Verdict $verdict -StillWanted $Wanted -SourceAccepted $Source -Degraded @('hostAddress')
        Assert-StringEqual -Expected $Result -Actual $o.Result
        Assert-Equal -Expected $Advertise -Actual $o.Advertise
        Assert-StringEqual -Expected $Exit -Actual $o.Outcome
        Assert-StringEqual -Expected $State -Actual $o.State
        Assert-StringEqual -Expected 'hostAddress' -Actual ($o.Degraded -join ',') -Because 'degradations never change the result, and are carried for the report'
    }
}

Describe 'Remove-YurunaServiceVmAdvertisement' {
    BeforeAll {
        # Loaded first so the module-scope mocks below replace the real commands
        # the function imports, and no host identity or registration is touched.
        Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.Capability.psm1') -Global -DisableNameChecking
        Mock -ModuleName Test.ServiceVm Get-YurunaHostId { 'fixture-host' }
        Mock -ModuleName Test.ServiceVm Write-HostRegistrationRecord { $script:Registered++; $true }
    }
    It 'removes the marker and regenerates the registration' {
        $script:Registered = 0
        $runtime = Join-Path $TestDrive 'runtime'
        [void](New-Item -ItemType Directory -Path $runtime)
        [void](Write-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtime -Active $true -VMName 'fixture-vm' -HostType 'host.ubuntu.kvm' -HostingMode 'vm')
        Assert-True ($null -ne (Read-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtime)) 'the fixture marker exists'
        $removed = Remove-YurunaServiceVmAdvertisement -Area 'stash-service' -HostType 'host.ubuntu.kvm' -RepoRoot $script:RepoRoot -RuntimeDir $runtime -Confirm:$false 6>$null
        Assert-True $removed 'nothing remains advertised'
        Assert-True ($null -eq (Read-ExtensionServiceMarker -Area 'stash-service' -RuntimeDir $runtime)) 'the marker is gone'
        Assert-Equal -Expected 1 -Actual $script:Registered -Because 'the registration record is regenerated once'
    }
}

Describe 'Stop-ExtensionServiceHostProcess' {
    BeforeEach {
        $script:Child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru
        $script:ChildStart = [DateTimeOffset]::new($script:Child.StartTime).ToUnixTimeMilliseconds()
    }
    AfterEach {
        if ($script:Child -and -not $script:Child.HasExited) { $script:Child.Kill($true) }
    }
    It 'stops a daemon whose identity still matches' {
        Mock -ModuleName Test.ExtensionService Get-ExtensionServiceHostProcessState { [pscustomobject]@{ Alive = $true; IdentityVerified = $true; Reason = 'verified' } }
        $deployment = [pscustomobject]@{ Pid = $script:Child.Id; ProcessStartUnixMs = $script:ChildStart }
        $r = Stop-ExtensionServiceHostProcess -Deployment $deployment -Area 'pool-control-service' -Confirm:$false
        Assert-True $r.Stopped "the daemon is stopped ($($r.Reason))"
        Assert-Equal -Expected $false -Actual $r.LeftRunning
        Assert-True $r.IdentityVerified 'the identity was verified'
        Assert-StringEqual -Expected '' -Actual $r.StopError
        Assert-True ($script:Child.WaitForExit(5000)) 'the process exited'
    }
    It 'leaves a process it cannot verify alone and reports it' {
        Mock -ModuleName Test.ExtensionService Get-ExtensionServiceHostProcessState { [pscustomobject]@{ Alive = $true; IdentityVerified = $false; Reason = 'name-mismatch' } }
        $deployment = [pscustomobject]@{ Pid = $script:Child.Id; ProcessStartUnixMs = $script:ChildStart }
        $r = Stop-ExtensionServiceHostProcess -Deployment $deployment -Area 'pool-control-service' -Confirm:$false
        Assert-True $r.LeftRunning 'an unverified process is reported as left running'
        Assert-StringEqual -Expected 'name-mismatch' -Actual $r.Reason
        Assert-Equal -Expected $false -Actual $r.IdentityVerified
        Assert-Equal -Expected $false -Actual $script:Child.HasExited
    }
    It 'refuses to stop a reused pid whose start time differs' {
        Mock -ModuleName Test.ExtensionService Get-ExtensionServiceHostProcessState { [pscustomobject]@{ Alive = $true; IdentityVerified = $true; Reason = 'verified' } }
        $deployment = [pscustomobject]@{ Pid = $script:Child.Id; ProcessStartUnixMs = $script:ChildStart - 60000 }
        $r = Stop-ExtensionServiceHostProcess -Deployment $deployment -Area 'pool-control-service' -Confirm:$false
        Assert-True $r.LeftRunning 'the handle recheck refuses a start-time mismatch'
        Assert-True $r.IdentityVerified 'the recorded identity was verified before the handle recheck refused'
        Assert-StringEqual -Expected '' -Actual $r.StopError
        Assert-Equal -Expected $false -Actual $script:Child.HasExited
    }
    It 'carries the error a verified stop raised' {
        Mock -ModuleName Test.ExtensionService Get-ExtensionServiceHostProcessState { [pscustomobject]@{ Alive = $true; IdentityVerified = $true; Reason = 'verified' } }
        Mock -ModuleName Test.ExtensionService Stop-Process { throw 'fixture: access denied' }
        $deployment = [pscustomobject]@{ Pid = $script:Child.Id; ProcessStartUnixMs = $script:ChildStart }
        $r = Stop-ExtensionServiceHostProcess -Deployment $deployment -Area 'pool-control-service' -Confirm:$false
        Assert-True $r.LeftRunning 'a stop that raised leaves the daemon running'
        Assert-Match -Pattern 'access denied' -Actual $r.StopError
        Assert-Equal -Expected $false -Actual $script:Child.HasExited
    }
    It 'reports nothing to stop for a deployment without a pid' {
        $r = Stop-ExtensionServiceHostProcess -Deployment ([pscustomobject]@{ Pid = $null; ProcessStartUnixMs = 0 }) -Area 'pool-control-service' -Confirm:$false
        Assert-Equal -Expected $false -Actual $r.LeftRunning
        Assert-StringEqual -Expected 'no-process' -Actual $r.Reason
    }
}

Describe 'service Start scripts adopt, plan, withdraw and build in that order' {
    It '<Name> keeps a running guest, and plans before it withdraws and builds' -ForEach @(
        @{ Name = 'Start-StashServiceVM.ps1' }, @{ Name = 'Start-PoolControlServiceVM.ps1' }, @{ Name = 'Start-DownloadAgentServiceVM.ps1' }
    ) {
        $path = Join-Path $script:RepoRoot "test/service/$Name"
        $wrapper = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        Assert-True ($null -ne ($wrapper.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ForceRebuild' })) "$Name takes -ForceRebuild"
        # The order is what the start runs: the shared pipeline with the service's readiness part.
        $ast = Get-YurunaServiceStartAst -Path $path
        $order = foreach ($step in 'Resolve-YurunaServiceVmAdoption', 'Test-YurunaServiceVmBuildPlan', 'Remove-YurunaServiceVmAdvertisement', 'Invoke-YurunaServiceVmBuild') {
            $calls = @(Get-BuilderCommand -Ast $ast -Name $step)
            Assert-Equal -Expected 1 -Actual $calls.Count -Because "$Name calls $step once"
            $calls[0]
        }
        for ($i = 1; $i -lt $order.Count; $i++) {
            Assert-True ($order[$i - 1].Extent.EndOffset -lt $order[$i].Extent.StartOffset) "$Name calls $($order[$i - 1].GetCommandName()) before $($order[$i].GetCommandName())"
        }
        $guard = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq "`$adoption.Decision -ne 'rebuild'" }, $true)
        Assert-True ($null -ne $guard -and $null -ne $guard.ElseClause) "$Name branches on the adoption decision"
        Assert-True ($guard.ElseClause.Extent.StartOffset -lt $order[1].Extent.StartOffset -and $guard.ElseClause.Extent.EndOffset -gt $order[3].Extent.EndOffset) `
            "$Name plans, withdraws and builds only when it does not adopt"
        $recheck = @(Get-BuilderCommand -Ast $ast -Name 'Test-YurunaServiceOperationCurrent')
        $outcome = @(Get-BuilderCommand -Ast $ast -Name 'Resolve-YurunaServiceStartOutcome')
        $marker = @(Get-BuilderCommand -Ast $ast -Name 'Write-ExtensionServiceMarker', 'Write-DownloadAgentServiceMarker') | Where-Object { $_.Extent.Text -match '-HostingMode .vm.|-BaseUrl \$downloadAgentServiceBaseUrl' }
        Assert-True ($outcome.Count -eq 1) "$Name resolves one outcome"
        $before = @($recheck | Where-Object { $_.Extent.EndOffset -lt $outcome[0].Extent.StartOffset -and $_.Extent.StartOffset -gt $order[3].Extent.EndOffset })
        Assert-True ($before.Count -ge 1) "$Name rechecks for a stop after the build and before it decides the outcome"
        Assert-True (@($marker).Count -ge 1 -and $outcome[0].Extent.EndOffset -lt @($marker)[0].Extent.StartOffset) "$Name decides the outcome before it writes the marker"
        Assert-True (@($marker)[0].Extent.Text -match '-Active \$startOutcome\.Advertise') "$Name advertises only what the outcome allows"
    }

    It 'the shared stop script stops a host process only through the shared identity-verified stop' {
        $path = Join-Path $script:RepoRoot 'test/service/Stop-ExtensionService.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        Assert-Equal -Expected 1 -Actual @(Get-BuilderCommand -Ast $ast -Name 'Stop-ExtensionServiceHostProcess').Count -Because 'one shared stop'
        Assert-Equal -Expected 0 -Actual @(Get-BuilderCommand -Ast $ast -Name 'Stop-Process', 'Get-Process', 'Get-ExtensionServiceHostProcessState').Count -Because 'no copy of the kill or its identity check'
    }

    It 'the caching proxy plans before its teardown, builds only through the bounded run, and reports a degraded seed' {
        $path = Join-Path $script:RepoRoot 'test/service/Start-CachingProxyServiceVM.ps1'
        $text = Get-Content -Raw -LiteralPath $path
        $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $plan = @(Get-BuilderCommand -Ast $ast -Name 'Test-YurunaServiceVmBuildPlan')
        $run = @(Get-BuilderCommand -Ast $ast -Name 'Invoke-YurunaServiceVmBuilderRun')
        $pin = @(Get-BuilderCommand -Ast $ast -Name 'Reset-GuestHostKeyPin')
        Assert-Equal -Expected 1 -Actual $plan.Count -Because 'the proxy plans once'
        Assert-Equal -Expected 1 -Actual $run.Count -Because 'the proxy builds once, through the bounded run'
        $teardown = $text.IndexOf('# --- REGION: Remove existing VM')
        Assert-True ($plan[0].Extent.StartOffset -lt $teardown -and $teardown -lt $run[0].Extent.StartOffset) 'plan, then teardown, then build'
        Assert-True ($pin.Count -eq 1 -and $pin[0].Extent.EndOffset -lt $run[0].Extent.StartOffset) 'the rebuilt guest''s pin is forgotten before the build'
        Assert-True ($run[0].Extent.Text -notmatch '-TimeoutSeconds') 'the build takes the shared bound (YURUNA_SERVICE_VM_BUILD_TIMEOUT_SECONDS)'
        $ready = $text.IndexOf("Write-Output `"== caching-proxy-service is READY")
        $degraded = $text.IndexOf("'runner.service_start_degraded'")
        Assert-True ($degraded -gt $ready) 'a seed value baked empty is reported when the proxy is ready'
        Assert-True ($text -match '\$cpBuildDegraded = @\(\$cpBuild\.Degraded\)') 'the degraded names come from the build run'
    }

    It 'the host-side proof stops its previous daemon before it launches, and never records a daemon that already exited' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'test/service/Start-PoolControlServiceVM.ps1')
        $stop = $text.IndexOf('Stop-ExtensionServiceHostProcess')
        $launch = $text.IndexOf('[Diagnostics.Process]::Start($launch)')
        $exited = $text.IndexOf('if ($proc.HasExited)')
        $marker = $text.IndexOf("-Active `$true -BaseUrl")
        Assert-True ($stop -gt 0 -and $stop -lt $launch) 'the previous daemon is stopped before a new one starts'
        Assert-True ($exited -gt $launch -and $exited -lt $marker) 'a daemon that exited at once is not recorded'
    }
}

Describe 'Stop-ConfigService follows the lifecycle opening' {
    It 'answers -WhatIf and changes nothing, its PID file included' {
        $runtime = Join-Path $TestDrive 'config-runtime'
        [void](New-Item -ItemType Directory -Path $runtime)
        $pidFile = Join-Path $runtime 'config-server.pid'
        [IO.File]::WriteAllText($pidFile, '999999')
        $previous = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = $runtime
            $null = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'test/service/Stop-ConfigService.ps1') -WhatIf 2>&1
            Assert-Equal 0 $LASTEXITCODE -Because 'the script takes -WhatIf, as Stop-StatusService does'
        } finally {
            Restore-YurunaTestEnvironment -Saved $previous
        }
        Assert-True (Test-Path -LiteralPath $pidFile) 'a preview leaves the PID file in place'
    }
}

Describe 'Stop-StatusService follows the lifecycle opening' {
    It 'changes nothing under -WhatIf, its marker included' {
        $runtime = Join-Path $TestDrive 'status-runtime'
        [void](New-Item -ItemType Directory -Path $runtime)
        $marker = Join-Path $runtime 'status-service.json'
        [IO.File]::WriteAllText($marker, '{}')
        $previous = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = $runtime
            $null = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $script:RepoRoot 'test/service/Stop-StatusService.ps1') -WhatIf
        } finally {
            Restore-YurunaTestEnvironment -Saved $previous
        }
        Assert-True (Test-Path -LiteralPath $marker) 'a preview leaves the marker in place'
    }
}
