<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42d7e0b4-3a91-4c6f-8b25-1e9d6f4a7c80
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hyper-v vmms dism responsive start-if-stopped host-refresh pester
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
    The Hyper-V driver's bounded probe, the bounded DISM feature read,
    Assert-HyperVEnabled over it, the vmms rung-2 action, and the rule that a
    provider failure never reads as an absent VM.
.DESCRIPTION
    Runs on any host. Every native call goes through a module-scoped mock of
    Invoke-BoundedNativeCommand that answers as the probe child, the service
    child, the start child or dism.exe would; Hyper-V cmdlets are module-scoped
    mocks over a stub module that throws on any unexpected live call; time is an
    injected clock advanced by a mocked Start-Sleep. Nothing here starts a
    service or touches a VM.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue

    $script:HyperVStub = $null
    if (-not (Get-Command 'Hyper-V\Get-VM' -ErrorAction SilentlyContinue)) {
        $script:HyperVStub = New-Module -Name 'Hyper-V' -ScriptBlock {
            function Get-VM {
                <# .SYNOPSIS
                    Stub VM query; every test replaces it with a mock. #>
                [CmdletBinding()] param([string[]]$Name) throw "Unexpected live VM query: $Name"
            }
            function Stop-VM {
                <# .SYNOPSIS
                    Stub VM stop that refuses to run. #>
                [CmdletBinding(SupportsShouldProcess)] param([string]$Name, [switch]$Force, [switch]$TurnOff)
                if ($PSCmdlet.ShouldProcess($Name)) { throw "Unexpected live VM stop: $Name $Force $TurnOff" }
            }
            function Remove-VM {
                <# .SYNOPSIS
                    Stub VM removal that refuses to run. #>
                [CmdletBinding(SupportsShouldProcess)] param([string]$Name, [switch]$Force)
                if ($PSCmdlet.ShouldProcess($Name)) { throw "Unexpected live VM removal: $Name $Force" }
            }
            function Rename-VM {
                <# .SYNOPSIS
                    Stub VM rename that refuses to run. #>
                [CmdletBinding(SupportsShouldProcess)] param([string]$Name, [string]$NewName)
                if ($PSCmdlet.ShouldProcess($Name)) { throw "Unexpected live VM rename: $Name $NewName" }
            }
            function Get-VMHost {
                <# .SYNOPSIS
                    Stub host query; tests mock it. #>
                [CmdletBinding()] param() throw 'Unexpected live host query.'
            }
            function Get-VMNetworkAdapter {
                <# .SYNOPSIS
                    Stub adapter query; tests mock it. #>
                [CmdletBinding()] param([string]$VMName) throw "Unexpected live adapter query: $VMName"
            }
            function Set-VMNetworkAdapter {
                <# .SYNOPSIS
                    Stub adapter change that refuses to run. #>
                [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$VMNetworkAdapter, [string]$StaticMacAddress)
                process { if ($PSCmdlet.ShouldProcess("$VMNetworkAdapter")) { throw "Unexpected live adapter change: $StaticMacAddress" } }
            }
            function Move-VMStorage {
                <# .SYNOPSIS
                    Stub storage move that refuses to run. #>
                [CmdletBinding(SupportsShouldProcess)] param([string]$VMName, [string]$DestinationStoragePath)
                if ($PSCmdlet.ShouldProcess($VMName)) { throw "Unexpected live storage move: $DestinationStoragePath" }
            }
            Export-ModuleMember -Function Get-VM, Stop-VM, Remove-VM, Rename-VM, Get-VMHost, Get-VMNetworkAdapter, Set-VMNetworkAdapter, Move-VMStorage
        }
        Import-Module $script:HyperVStub -Global
    }

    # Get-Service exists only on Windows; Assert-HyperVEnabled's in-process
    # read is mocked, and Pester can only mock a command that resolves.
    $script:ServiceStub = $false
    if (-not (Get-Command -Name 'Get-Service' -ErrorAction SilentlyContinue)) {
        $script:ServiceStub = $true
        function global:Get-Service {
            <# .SYNOPSIS
                Stub service query; tests mock it. #>
            [CmdletBinding()] param([string[]]$Name) throw "Unexpected live service query: $Name"
        }
    }

    $script:DriverPath = Join-Path $repoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    $script:Module = Get-Module Yuruna.Host
    $script:ProbeScript   = & $script:Module { $script:HyperVProbeScript }
    $script:ServiceScript = & $script:Module { $script:HyperVServiceScript }
    $script:StartScript   = & $script:Module { $script:HyperVStartScript }
    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('yrn-hyperv-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $script:TempRoot -Force

    function New-NativeResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture result.')]
        param([int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '', [switch]$TimedOut, [switch]$NotStarted, [switch]$Undrained)
        $code = if ($NotStarted) { -1 } elseif ($TimedOut) { 124 } else { $ExitCode }
        return @{ ExitCode = $code; StdOut = $StdOut; StdErr = $StdErr; TimedOut = [bool]$TimedOut; Started = -not $NotStarted
            DrainTimedOut = [bool]$Undrained; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 4 }
    }

    function New-DismResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param([string]$State)
        return New-NativeResult -StdOut "Deployment Image Servicing and Management tool`r`nVersion: 10.0`r`n`r`nFeature Information:`r`n`r`nFeature Name : Microsoft-Hyper-V-All`r`nDisplay Name : Hyper-V`r`nState : $State`r`nRestart Required : Possible`r`n"
    }

    function New-ServiceResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param([string]$Status, [string]$Start = 'Automatic')
        if ($Status -eq 'Missing') { return (New-NativeResult -ExitCode 2 -StdOut "yuruna-probe service=Missing`n") }
        return (New-NativeResult -StdOut "yuruna-probe service=$Status`nyuruna-probe start=$Start`n")
    }

    function Invoke-HyperVFixtureNative {
        param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSeconds)
        $remaining = if ($script:Deadline) { Get-YurunaDeadlineRemainingMs -Deadline $script:Deadline } else { [long]::MaxValue }
        $leaf = Split-Path -Leaf ($FilePath -replace '\\', '/')
        $body = [string]@($ArgumentList)[-1]
        $kind = if ($leaf -eq 'dism.exe') { 'dism' }
            elseif ($body -ceq $script:ProbeScript) { 'probe' }
            elseif ($body -ceq $script:ServiceScript) { 'service' }
            elseif ($body -ceq $script:StartScript) { 'start' }
            else { 'other' }
        $script:Calls.Add([pscustomobject]@{ Kind = $kind; FilePath = $FilePath; Argv = [string[]]@($ArgumentList); TimeoutSeconds = $TimeoutSeconds; RemainingMs = $remaining })
        switch ($kind) {
            'dism'    { return (& $script:OnDism) }
            'probe'   { return (& $script:OnProbe) }
            'service' { return (& $script:OnService) }
            'start'   { return (& $script:OnStart) }
        }
        throw "unexpected native call: $FilePath $($ArgumentList -join ' ')"
    }

    function Get-FixtureCall {
        param([string]$Kind)
        return @($script:Calls | Where-Object { $_.Kind -eq $Kind })
    }

    function Reset-HyperVFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param()
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Tick = [long]7000000
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 120000 -ClockTicks { $script:Tick }
        $script:Elevated = $true
        $script:OnDism = { New-DismResult -State 'Enabled' }
        $script:OnProbe = { New-NativeResult -StdOut "yuruna-probe service=Running`nyuruna-probe start=Automatic`nyuruna-probe module=loaded`nyuruna-probe provider=ok`n" }
        $script:ServiceQueue = [System.Collections.Generic.Queue[object]]::new()
        $script:LastService = New-ServiceResult -Status 'Running'
        $script:OnService = {
            if ($script:ServiceQueue.Count -gt 0) { $script:LastService = $script:ServiceQueue.Dequeue() }
            $script:LastService
        }
        $script:OnStart = { New-NativeResult }
    }

    function Set-ServiceSequence {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds or resets in-memory fixture state only.')]
        param([object[]]$Result)
        $script:ServiceQueue.Clear()
        foreach ($item in $Result) { $script:ServiceQueue.Enqueue($item) }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    if ($script:HyperVStub) { Remove-Module -ModuleInfo $script:HyperVStub -Force -ErrorAction SilentlyContinue }
    if ($script:ServiceStub) { Remove-Item -Path 'Function:\Get-Service' -ErrorAction SilentlyContinue }
}

Describe 'Hyper-V probe child scripts' {
    It 'parse cleanly and use no double quotes, so they cross the command line unaltered' {
        foreach ($text in @($script:ProbeScript, $script:ServiceScript, $script:StartScript)) {
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
            @($errors).Count | Should -Be 0
            $text | Should -Not -Match '"'
        }
        $script:ProbeScript | Should -Match 'Import-Module Hyper-V -ErrorAction Stop'
        $script:ProbeScript | Should -Match 'Hyper-V\\Get-VM -ErrorAction Stop'
        $script:StartScript | Should -Match 'Start-Service -Name vmms'
    }

    It 'speaks the yuruna-probe line protocol in a real child pwsh' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'on Windows the child would query the real service'; return }
        # Off Windows, Get-Service does not exist, which the child reports
        # through the same ObjectNotFound path a missing vmms takes.
        $real = Invoke-BoundedNativeCommand -FilePath (Get-PwshApplicationPath) `
            -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $script:ProbeScript) -TimeoutSeconds 60
        $real.Started | Should -BeTrue
        $real.ExitCode | Should -Be 2
        @(([string]$real.StdOut).Trim() -split '\r?\n') | Should -Be @('yuruna-probe service=Missing')
    }
}

Describe 'Test-VirtualizationResponsive (Hyper-V)' {
    BeforeEach {
        Reset-HyperVFixture
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-HyperVFixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
        Mock -ModuleName Yuruna.Host Test-IsAdministrator { $script:Elevated }
    }

    It 'returns a schema-1 record with every Windows evidence key on the healthy path, and never runs DISM there' {
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.PSObject.TypeNames | Should -Contain 'Yuruna.VirtualizationProbe'
        $r.schemaVersion | Should -Be 1
        $r.hostType | Should -Be 'host.windows.hyper-v'
        $r.state | Should -Be 'Responsive'
        $r.reason | Should -Be 'responsive'
        $r.corroborated | Should -BeFalse
        foreach ($key in 'serviceStatus', 'serviceStartType', 'featureState', 'featureProbe', 'providerModule', 'elevated', 'exitCode', 'drainTimedOut', 'outputTruncated') {
            $r.evidence.PSObject.Properties.Name | Should -Contain $key
        }
        $r.evidence.serviceStatus | Should -Be 'Running'
        $r.evidence.serviceStartType | Should -Be 'Automatic'
        $r.evidence.featureState | Should -Be 'NotProbed'
        $r.evidence.providerModule | Should -Be 'loaded'
        $r.evidence.elevated | Should -BeTrue
        (Get-FixtureCall 'dism').Count | Should -Be 0
    }

    It 'launches one bounded -NonInteractive child that imports Hyper-V explicitly' {
        $null = Test-VirtualizationResponsive -TimeoutSeconds 9
        $probe = Get-FixtureCall 'probe'
        $probe.Count | Should -Be 1
        $probe[0].Argv[0..3] | Should -Be @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command')
        $probe[0].Argv[4] | Should -Match 'Import-Module Hyper-V'
        $probe[0].Argv[4] | Should -Match 'Hyper-V\\Get-VM'
        $probe[0].TimeoutSeconds | Should -Be 9
    }

    It 'classifies <Case> as <State>/<Reason>' -ForEach @(
        @{ Case = 'an unlaunchable child'; State = 'Undetermined'; Reason = 'missing-client'; Probe = { New-NativeResult -NotStarted }; Dism = 'Enabled' }
        @{ Case = 'a timeout after module=loaded'; State = 'Unresponsive'; Reason = 'timeout'; Probe = { New-NativeResult -TimedOut -StdOut "yuruna-probe service=Running`nyuruna-probe start=Automatic`nyuruna-probe module=loaded`n" }; Dism = 'Enabled' }
        @{ Case = 'a timeout during the first Hyper-V module load'; State = 'Undetermined'; Reason = 'timeout'; Probe = { New-NativeResult -TimedOut -StdOut "yuruna-probe service=Running`nyuruna-probe start=Automatic`n" }; Dism = 'Enabled' }
        @{ Case = 'a timeout before the child printed anything'; State = 'Undetermined'; Reason = 'timeout'; Probe = { New-NativeResult -TimedOut }; Dism = 'Enabled' }
        @{ Case = 'exit 0 with undrained output'; State = 'Undetermined'; Reason = 'invalid-response'; Probe = { New-NativeResult -Undrained -StdOut "yuruna-probe provider=ok`n" }; Dism = 'Enabled' }
        @{ Case = 'exit 0 without provider=ok'; State = 'Undetermined'; Reason = 'invalid-response'; Probe = { New-NativeResult -StdOut "yuruna-probe service=Running`n" }; Dism = 'Enabled' }
        @{ Case = 'vmms missing with the feature disabled'; State = 'Undetermined'; Reason = 'missing-client'; Probe = { New-NativeResult -ExitCode 2 -StdOut "yuruna-probe service=Missing`n" }; Dism = 'Disabled' }
        @{ Case = 'vmms Stopped with the feature Enabled'; State = 'Unresponsive'; Reason = 'app-stopped'; Probe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=Stopped`nyuruna-probe start=Manual`n" }; Dism = 'Enabled' }
        @{ Case = 'vmms Stopped with the feature Disabled'; State = 'Undetermined'; Reason = 'missing-client'; Probe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=Stopped`nyuruna-probe start=Manual`n" }; Dism = 'Disabled' }
        @{ Case = 'vmms Stopped with the feature Enable Pending'; State = 'Undetermined'; Reason = 'missing-client'; Probe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=Stopped`nyuruna-probe start=Manual`n" }; Dism = 'Enable Pending' }
        @{ Case = 'vmms StopPending'; State = 'Undetermined'; Reason = 'provider-error'; Probe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=StopPending`nyuruna-probe start=Automatic`n" }; Dism = 'Enabled' }
        @{ Case = 'the Hyper-V module missing'; State = 'Undetermined'; Reason = 'missing-client'; Probe = { New-NativeResult -ExitCode 3 -StdOut "yuruna-probe service=Running`nyuruna-probe module=missing`n" }; Dism = 'Enabled' }
        @{ Case = 'a PermissionDenied category with a non-English message'; State = 'Undetermined'; Reason = 'permission-denied'; Probe = { New-NativeResult -ExitCode 4 -StdOut "yuruna-probe service=Running`nyuruna-probe module=loaded`nyuruna-probe error-category=PermissionDenied`n" -StdErr 'Zugriff verweigert.' }; Dism = 'Enabled' }
        @{ Case = 'access-denied wording under another category'; State = 'Undetermined'; Reason = 'permission-denied'; Probe = { New-NativeResult -ExitCode 4 -StdOut "yuruna-probe error-category=InvalidOperation`n" -StdErr 'Access is denied.' }; Dism = 'Enabled' }
        @{ Case = 'any other provider failure'; State = 'Undetermined'; Reason = 'provider-error'; Probe = { New-NativeResult -ExitCode 4 -StdOut "yuruna-probe error-category=InvalidOperation`n" -StdErr 'The operation failed.' }; Dism = 'Enabled' }
        @{ Case = 'a service query failure'; State = 'Undetermined'; Reason = 'provider-error'; Probe = { New-NativeResult -ExitCode 6 -StdOut "yuruna-probe service=Unknown`n" }; Dism = 'Enabled' }
        @{ Case = 'an unexpected exit code'; State = 'Undetermined'; Reason = 'invalid-response'; Probe = { New-NativeResult -ExitCode 9 }; Dism = 'Enabled' }
    ) {
        $script:OnProbe = $Probe
        $script:DismState = $Dism
        $script:OnDism = { New-DismResult -State $script:DismState }
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.state | Should -Be $State
        $r.reason | Should -Be $Reason
    }

    It 'keeps a missing vmms and a stopped vmms apart in state, reason and feature evidence' {
        $script:OnProbe = { New-NativeResult -ExitCode 2 -StdOut "yuruna-probe service=Missing`n" }
        $script:OnDism = { New-DismResult -State 'Disabled' }
        $missing = Test-VirtualizationResponsive -Deadline $script:Deadline
        $script:OnProbe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=Stopped`nyuruna-probe start=Manual`n" }
        $script:OnDism = { New-DismResult -State 'Enabled' }
        $stopped = Test-VirtualizationResponsive -Deadline $script:Deadline
        $missing.reason | Should -Not -Be 'app-stopped'
        $missing.state | Should -Not -Be $stopped.state
        $missing.evidence.featureState | Should -Be 'Disabled'
        $missing.evidence.serviceStatus | Should -Be 'Missing'
        $stopped.evidence.featureState | Should -Be 'Enabled'
        $stopped.evidence.serviceStatus | Should -Be 'Stopped'
    }

    It 'reports the running-but-unresponsive VMMS case with its service evidence' {
        $script:OnProbe = { New-NativeResult -TimedOut -StdOut "yuruna-probe service=Running`nyuruna-probe start=Automatic`nyuruna-probe module=loaded`n" }
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.state | Should -Be 'Unresponsive'
        $r.timedOut | Should -BeTrue
        $r.evidence.serviceStatus | Should -Be 'Running'
    }

    It 'reads a timeout during a slow first module load as Undetermined/timeout, still flagged timedOut' {
        $script:OnProbe = { New-NativeResult -TimedOut -StdOut "yuruna-probe service=Running`nyuruna-probe start=Automatic`n" }
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.state | Should -Be 'Undetermined'
        $r.reason | Should -Be 'timeout'
        $r.timedOut | Should -BeTrue
        $r.evidence.providerModule | Should -Be 'not-probed'
        $r.evidence.serviceStatus | Should -Be 'Running'
        (Get-FixtureCall 'dism').Count | Should -Be 0
    }

    It 'reports permission-denied when DISM needs elevation to explain a stopped vmms' {
        $script:OnProbe = { New-NativeResult -ExitCode 5 -StdOut "yuruna-probe service=Stopped`nyuruna-probe start=Manual`n" }
        $script:OnDism = { New-NativeResult -ExitCode 740 -StdOut 'Error: 740 Elevated permissions are required to run DISM.' }
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.reason | Should -Be 'permission-denied'
        $r.evidence.featureProbe | Should -Be 'not-elevated'
    }

    It 'never throws: an internal fault becomes Undetermined/provider-error' {
        $script:OnProbe = { throw 'probe plumbing exploded' }
        $r = Test-VirtualizationResponsive -Deadline $script:Deadline
        $r.state | Should -Be 'Undetermined'
        $r.reason | Should -Be 'provider-error'
        $r.diagnostic | Should -Match 'probe plumbing exploded'
    }

    It 'makes no call when the shared deadline is exhausted' {
        $r = Test-VirtualizationResponsive -Deadline (New-YurunaDeadline -TotalMilliseconds 300 -ClockTicks { $script:Tick })
        $r.reason | Should -Be 'deadline-exhausted'
        $r.deadlineExhausted | Should -BeTrue
        $r.started | Should -BeFalse
        $script:Calls.Count | Should -Be 0
    }
}

Describe 'Get-HyperVFeatureState -- bounded DISM' {
    BeforeEach {
        Reset-HyperVFixture
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-HyperVFixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
    }

    It 'maps <Case> to <State>/<Probe>' -ForEach @(
        @{ Case = 'Enabled'; Result = { New-DismResult -State 'Enabled' }; State = 'Enabled'; Probe = 'ok' }
        @{ Case = 'Disabled'; Result = { New-DismResult -State 'Disabled' }; State = 'Disabled'; Probe = 'ok' }
        @{ Case = 'Enable Pending'; Result = { New-DismResult -State 'Enable Pending' }; State = 'EnablePending'; Probe = 'ok' }
        @{ Case = 'Disable Pending'; Result = { New-DismResult -State 'Disable Pending' }; State = 'DisablePending'; Probe = 'ok' }
        @{ Case = 'Disabled with Payload Removed'; Result = { New-DismResult -State 'Disabled with Payload Removed' }; State = 'Disabled'; Probe = 'ok' }
        @{ Case = '0x800f080c'; Result = { New-NativeResult -ExitCode -2146498548 -StdOut "Error: 0x800f080c`r`n`r`nFeature name Microsoft-Hyper-V-All is unknown." }; State = 'Unavailable'; Probe = 'unknown-to-sku' }
        @{ Case = 'exit 740'; Result = { New-NativeResult -ExitCode 740 -StdOut 'Error: 740 Elevated permissions are required to run DISM.' }; State = 'Unknown'; Probe = 'not-elevated' }
        @{ Case = 'a timeout'; Result = { New-NativeResult -TimedOut }; State = 'Unknown'; Probe = 'timeout' }
        @{ Case = 'a missing dism.exe'; Result = { New-NativeResult -NotStarted }; State = 'Unknown'; Probe = 'missing-client' }
        @{ Case = 'another failure'; Result = { New-NativeResult -ExitCode 87 -StdOut 'Error: 87 The parameter is incorrect.' }; State = 'Unknown'; Probe = 'provider-error' }
        @{ Case = 'no state line'; Result = { New-NativeResult -StdOut 'Deployment Image Servicing and Management tool' }; State = 'Unknown'; Probe = 'invalid-response' }
        @{ Case = 'an unrecognized state'; Result = { New-DismResult -State 'Staged' }; State = 'Unknown'; Probe = 'invalid-response' }
    ) {
        $script:OnDism = $Result
        $feature = Get-HyperVFeatureState -TimeoutSeconds 30
        $feature.State | Should -Be $State
        $feature.Probe | Should -Be $Probe
    }

    It 'runs dism.exe from System32 with /English and the Hyper-V feature name, under the given cap' {
        $null = Get-HyperVFeatureState -TimeoutSeconds 42
        $call = Get-FixtureCall 'dism'
        $call.Count | Should -Be 1
        ($call[0].FilePath -replace '\\', '/') | Should -Match '/System32/dism\.exe$'
        $call[0].Argv | Should -Be @('/English', '/Online', '/Get-FeatureInfo', '/FeatureName:Microsoft-Hyper-V-All')
        $call[0].TimeoutSeconds | Should -Be 42
    }
}

Describe 'Assert-HyperVEnabled over the bounded DISM read' {
    BeforeEach {
        Reset-HyperVFixture
        $script:Service = [pscustomobject]@{ Status = 'Running' }
        Mock -ModuleName Yuruna.Host Get-Service { $script:Service }
    }

    It 'has no direct dism.exe invocation and reads the feature through Get-HyperVFeatureState' {
        $fn = Get-YurunaTestFunctionAst -Path $script:DriverPath -Name 'Assert-HyperVEnabled'
        $commands = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        @($commands | Where-Object { $_.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Unknown }).Count | Should -Be 0
        @($commands | Where-Object { "$($_.GetCommandName())" -match 'dism' }).Count | Should -Be 0
        @($commands | Where-Object { $_.GetCommandName() -eq 'Get-HyperVFeatureState' }).Count | Should -Be 1
    }

    It 'returns $false at once on a DISM timeout, without reading the service' {
        Mock -ModuleName Yuruna.Host Get-HyperVFeatureState { [pscustomobject]@{ State = 'Unknown'; Probe = 'timeout'; ExitCode = 124; Output = ''; Path = 'dism.exe' } }
        Assert-HyperVEnabled -InformationAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host Get-Service -Times 0 -Exactly
    }

    It 'returns $false for a feature that is not Enabled' {
        Mock -ModuleName Yuruna.Host Get-HyperVFeatureState { [pscustomobject]@{ State = 'EnablePending'; Probe = 'ok'; ExitCode = 0; Output = ''; Path = 'dism.exe' } }
        Assert-HyperVEnabled -InformationAction SilentlyContinue | Should -BeFalse
    }

    It 'returns $true only with the feature Enabled and vmms Running' {
        Mock -ModuleName Yuruna.Host Get-HyperVFeatureState { [pscustomobject]@{ State = 'Enabled'; Probe = 'ok'; ExitCode = 0; Output = ''; Path = 'dism.exe' } }
        Assert-HyperVEnabled -InformationAction SilentlyContinue | Should -BeTrue
        $script:Service = [pscustomobject]@{ Status = 'Stopped' }
        Assert-HyperVEnabled -InformationAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'Start-VirtualizationServiceIfStopped (Hyper-V rung 2)' {
    BeforeEach {
        Reset-HyperVFixture
        Mock -ModuleName Yuruna.Host Invoke-BoundedNativeCommand {
            Invoke-HyperVFixtureNative -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds
        }
        Mock -ModuleName Yuruna.Host Test-IsAdministrator { $script:Elevated }
        Mock -ModuleName Yuruna.Host Start-Sleep { $script:Tick += [long]$Milliseconds }
    }

    It 'reports already-running with no start child when vmms is Running' {
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.PSObject.TypeNames | Should -Contain 'Yuruna.VirtualizationStartResult'
        $r.hostType | Should -Be 'host.windows.hyper-v'
        $r.layout | Should -Be 'not-applicable'
        $r.outcome | Should -Be 'already-running'
        (Get-FixtureCall 'start').Count | Should -Be 0
    }

    It 'starts a positively Stopped vmms when elevated and confirms it Running' {
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'), (New-ServiceResult -Status 'Running'))
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'started'
        $start = Get-FixtureCall 'start'
        $start.Count | Should -Be 1
        $start[0].Argv[4] | Should -Match 'Start-Service -Name vmms'
        $start[0].Argv[2] | Should -Be '-NonInteractive'
        $row = $r.actions | Where-Object { $_.kind -eq 'service-start' }
        $row.before | Should -Be 'Stopped'
        $row.after | Should -Be 'Running'
    }

    It 'refuses with not-elevated and starts nothing on a non-elevated host' {
        $script:Elevated = $false
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'))
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'not-elevated'
        (Get-FixtureCall 'start').Count | Should -Be 0
    }

    It 'refuses <Status> with <Reason>' -ForEach @(
        @{ Status = 'StopPending'; Start = 'Automatic'; Reason = 'pending-stop' }
        @{ Status = 'Paused'; Start = 'Automatic'; Reason = 'service-paused' }
        @{ Status = 'PausePending'; Start = 'Automatic'; Reason = 'service-paused' }
        @{ Status = 'Stopped'; Start = 'Disabled'; Reason = 'service-disabled' }
        @{ Status = 'Unknown'; Start = 'Automatic'; Reason = 'service-state-unknown' }
    ) {
        Set-ServiceSequence @((New-ServiceResult -Status $Status -Start $Start))
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be $Reason
        (Get-FixtureCall 'start').Count | Should -Be 0
    }

    It 'refuses a missing vmms with the DISM feature state as evidence' {
        Set-ServiceSequence @((New-ServiceResult -Status 'Missing'))
        $script:OnDism = { New-DismResult -State 'Disabled' }
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'service-missing'
        $r.actions[0].before | Should -Be 'Disabled'
        (Get-FixtureCall 'dism').Count | Should -Be 1
    }

    It 'waits boundedly for StartPending and reports already-running once it runs' {
        Set-ServiceSequence @((New-ServiceResult -Status 'StartPending'), (New-ServiceResult -Status 'StartPending'), (New-ServiceResult -Status 'Running'))
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'already-running'
        $r.actions[0].kind | Should -Be 'wait'
        (Get-FixtureCall 'start').Count | Should -Be 0
    }

    It 'refuses with pending-timeout when StartPending never resolves, inside the wait window' {
        Set-ServiceSequence @((New-ServiceResult -Status 'StartPending'))
        $startTick = $script:Tick
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -Be 'pending-timeout'
        ($script:Tick - $startTick) | Should -BeLessOrEqual 30000
    }

    It 'previews under -WhatIf without a start child' {
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'))
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -WhatIf
        $r.outcome | Should -Be 'preview'
        (Get-FixtureCall 'start').Count | Should -Be 0
    }

    It 'reads a timed-out start as <Outcome> when the service then reports <After>' -ForEach @(
        @{ After = 'Running'; Outcome = 'started'; Reason = 'started' }
        @{ After = 'Stopped'; Outcome = 'unknown'; Reason = 'start-timed-out' }
    ) {
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'), (New-ServiceResult -Status $After))
        $script:OnStart = { New-NativeResult -TimedOut }
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be $Outcome
        $r.reason | Should -Be $Reason
    }

    It 'reports failed/start-failed when the start child fails and vmms stays Stopped' {
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'), (New-ServiceResult -Status 'Stopped'))
        $script:OnStart = { New-NativeResult -ExitCode 1 -StdErr 'Service cannot be started.' }
        $r = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $r.outcome | Should -Be 'failed'
        $r.reason | Should -Be 'start-failed'
    }

    It 'never throws: a fault before the start is refused, after the start child it is unknown' {
        $script:OnService = { throw 'service child exploded' }
        $before = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        $before.outcome | Should -Be 'refused'
        $before.reason | Should -Be 'service-state-unknown'
        (Get-FixtureCall 'start').Count | Should -Be 0

        $script:ServiceCalls = 0
        $script:OnService = {
            $script:ServiceCalls++
            if ($script:ServiceCalls -gt 1) { throw 'post-read exploded' }
            New-ServiceResult -Status 'Stopped'
        }
        $after = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        (Get-FixtureCall 'start').Count | Should -Be 1
        $after.outcome | Should -Be 'unknown'
        $after.reason | Should -Be 'postcondition-unknown'
    }

    It 'makes no call when the deadline is exhausted, and caps every call at the remaining time' {
        $r = Start-VirtualizationServiceIfStopped -Deadline (New-YurunaDeadline -TotalMilliseconds 200 -ClockTicks { $script:Tick }) -Confirm:$false
        $r.reason | Should -Be 'deadline-exhausted'
        $script:Calls.Count | Should -Be 0
        $script:Deadline = New-YurunaDeadline -TotalMilliseconds 9500 -ClockTicks { $script:Tick }
        Set-ServiceSequence @((New-ServiceResult -Status 'Stopped'), (New-ServiceResult -Status 'StartPending'), (New-ServiceResult -Status 'Running'))
        $null = Start-VirtualizationServiceIfStopped -Deadline $script:Deadline -Confirm:$false
        foreach ($call in $script:Calls) {
            $call.TimeoutSeconds | Should -BeLessOrEqual ([Math]::Ceiling($call.RemainingMs / 1000.0))
        }
    }
}

Describe 'Hyper-V VM presence: a provider failure never reads as absent' {
    BeforeEach {
        Reset-HyperVFixture
        $script:Keys = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Yuruna.Host Format-YurunaOperatorMessage { $script:Keys.Add($Key); $Key }
        $script:LookupBehavior = 'throw'
        $script:Inventory = @()
        $script:InventoryThrows = $false
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VM' {
            if ($Name) {
                switch ($script:LookupBehavior) {
                    'throw'  { throw [System.Management.Automation.ItemNotFoundException]::new('Hyper-V konnte keinen virtuellen Computer finden.') }
                    'empty'  { return }
                    default  { return @($script:LookupBehavior) }
                }
            }
            if ($script:InventoryThrows) { throw 'Die RPC-Verbindung ist fehlgeschlagen.' }
            return @($script:Inventory)
        }
    }

    It 'Get-VMState is unknown when the lookup and the inventory both fail' {
        $script:InventoryThrows = $true
        Get-VMState -VMName 'vm-a' | Should -Be 'unknown'
    }

    It 'Get-VMState is absent when a localized lookup failure is followed by an inventory without the name' {
        $script:Inventory = @([pscustomobject]@{ Name = 'other'; State = 'Running' })
        Get-VMState -VMName 'vm-a' | Should -Be 'absent'
    }

    It 'Get-VMState is unknown when the inventory lists the name the lookup missed' {
        $script:Inventory = @([pscustomobject]@{ Name = 'vm-a'; State = 'Off' })
        Get-VMState -VMName 'vm-a' | Should -Be 'unknown'
    }

    It 'Get-VMState is unknown for a duplicated name' {
        $script:LookupBehavior = @([pscustomobject]@{ Name = 'vm-a'; State = 'Off' }, [pscustomobject]@{ Name = 'vm-a'; State = 'Running' })
        Get-VMState -VMName 'vm-a' | Should -Be 'unknown'
    }

    It 'Get-VMState ignores wildcard neighbors and decides from the inventory' {
        $script:LookupBehavior = @([pscustomobject]@{ Name = 'vm-ab'; State = 'Running' })
        $script:Inventory = @([pscustomobject]@{ Name = 'vm-ab'; State = 'Running' })
        Get-VMState -VMName 'vm-a' | Should -Be 'absent'
    }

    It 'Get-VMState maps <Raw> to <Expected>' -ForEach @(
        @{ Raw = 'Running'; Expected = 'running' }
        @{ Raw = 'Off'; Expected = 'stopped' }
        @{ Raw = 'Saved'; Expected = 'stopped' }
        @{ Raw = 'Starting'; Expected = 'unknown' }
    ) {
        $script:LookupBehavior = @([pscustomobject]@{ Name = 'vm-a'; State = $Raw })
        Get-VMState -VMName 'vm-a' | Should -Be $Expected
    }

    It 'Resolve-HyperVVM finds a VM named <VMName> by exact inventory match, never by a -Name pattern' -ForEach @(
        @{ VMName = 'vm[1]'; Neighbor = 'vm1' }
        @{ VMName = 'vm*'; Neighbor = 'vm-other' }
        @{ VMName = 'vm?'; Neighbor = 'vmx' }
        @{ VMName = 'vm`a'; Neighbor = 'vma' }
    ) {
        $script:Inventory = @([pscustomobject]@{ Name = $Neighbor; State = 'Running' }, [pscustomobject]@{ Name = $VMName; State = 'Off' })
        $resolved = Resolve-HyperVVM -VMName $VMName
        $resolved.Presence | Should -Be 'present'
        $resolved.VM.Name | Should -BeExactly $VMName
        Get-VMState -VMName $VMName | Should -Be 'stopped'
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VM' -Times 0 -Exactly -ParameterFilter { $null -ne $Name }
    }

    It 'Resolve-HyperVVM reads a wildcard-bearing name as <Presence>/<Cause> when the inventory lists it <Listed> times' -ForEach @(
        @{ Listed = 0; Presence = 'absent'; Cause = 'ok' }
        @{ Listed = 2; Presence = 'unknown'; Cause = 'ambiguous' }
    ) {
        $script:Inventory = @([pscustomobject]@{ Name = 'vm1'; State = 'Running' })
        for ($i = 0; $i -lt $Listed; $i++) { $script:Inventory += [pscustomobject]@{ Name = 'vm[1]'; State = 'Off' } }
        $resolved = Resolve-HyperVVM -VMName 'vm[1]'
        $resolved.Presence | Should -Be $Presence
        $resolved.Cause | Should -Be $Cause
    }

    It 'Resolve-HyperVVM reads a wildcard-bearing name as unknown when the inventory fails' {
        $script:InventoryThrows = $true
        $resolved = Resolve-HyperVVM -VMName 'vm[1]'
        $resolved.Presence | Should -Be 'unknown'
        $resolved.Cause | Should -Be 'inventory-failed'
    }

    It 'Resolve-HyperVVM reports missing-client when the Hyper-V module is not available' {
        Mock -ModuleName Yuruna.Host Get-Command { $null } -ParameterFilter { $Name -eq 'Hyper-V\Get-VM' }
        $resolved = Resolve-HyperVVM -VMName 'vm-a'
        $resolved.Presence | Should -Be 'unknown'
        $resolved.Cause | Should -Be 'missing-client'
    }

    It 'Remove-HyperVTestVM removes nothing and keeps the disk when presence is unknown' {
        $script:InventoryThrows = $true
        $vhd = Join-Path $script:TempRoot ('vhd-' + [guid]::NewGuid().ToString('N'))
        $sentinel = Join-Path $vhd 'vm-a/disk.vhdx'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $sentinel) -Force
        Set-Content -LiteralPath $sentinel -Value 'guest data'
        $script:Vhd = $vhd
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMHost' { [pscustomobject]@{ VirtualHardDiskPath = $script:Vhd } }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Remove-VM' { }
        Remove-HyperVTestVM -VMName 'vm-a' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Remove-VM' -Times 0 -Exactly
        Test-Path -LiteralPath $sentinel | Should -BeTrue
        $script:Keys | Should -Contain 'host.hyperv_vm_state_unknown'
    }

    It 'Remove-HyperVTestVM deletes the disk directory of a positively absent VM' {
        $vhd = Join-Path $script:TempRoot ('vhd-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $vhd 'vm-a') -Force
        $script:Vhd = $vhd
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMHost' { [pscustomobject]@{ VirtualHardDiskPath = $script:Vhd } }
        Remove-HyperVTestVM -VMName 'vm-a' -Confirm:$false | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $vhd 'vm-a') | Should -BeFalse
    }

    It 'Remove-HyperVTestVM keeps the disk when the post-removal read is <After>' -ForEach @(
        @{ After = 'unknown' }
        @{ After = 'present' }
    ) {
        $script:LookupBehavior = @([pscustomobject]@{ Name = 'vm-a'; State = 'Off' })
        $script:AfterRemoval = $After
        $vhd = Join-Path $script:TempRoot ('vhd-' + [guid]::NewGuid().ToString('N'))
        $sentinel = Join-Path $vhd 'vm-a/disk.vhdx'
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $sentinel) -Force
        Set-Content -LiteralPath $sentinel -Value 'guest data'
        $script:Vhd = $vhd
        Mock -ModuleName Yuruna.Host Stop-HyperVVMForce { $true }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMHost' { [pscustomobject]@{ VirtualHardDiskPath = $script:Vhd } }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Remove-VM' {
            if ($script:AfterRemoval -eq 'unknown') { $script:LookupBehavior = 'throw'; $script:InventoryThrows = $true }
        }
        Remove-HyperVTestVM -VMName 'vm-a' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Remove-VM' -Times 1 -Exactly
        Test-Path -LiteralPath $sentinel | Should -BeTrue
    }

    It 'Remove-HyperVTestVM confirms a removal that reads positively absent afterwards' {
        $script:LookupBehavior = @([pscustomobject]@{ Name = 'vm-a'; State = 'Off' })
        $vhd = Join-Path $script:TempRoot ('vhd-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $vhd 'vm-a') -Force
        $script:Vhd = $vhd
        Mock -ModuleName Yuruna.Host Stop-HyperVVMForce { $true }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMHost' { [pscustomobject]@{ VirtualHardDiskPath = $script:Vhd } }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Remove-VM' { $script:LookupBehavior = 'throw'; $script:Inventory = @() }
        Remove-HyperVTestVM -VMName 'vm-a' -Confirm:$false -InformationAction SilentlyContinue | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $vhd 'vm-a') | Should -BeFalse
    }

    It 'Stop-HyperVVMForce returns $false on unknown without starting a job, and $true on absent' {
        Mock -ModuleName Yuruna.Host Start-Job { throw 'no job expected' }
        $script:InventoryThrows = $true
        Stop-HyperVVMForce -VMName 'vm-a' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        $script:InventoryThrows = $false
        Stop-HyperVVMForce -VMName 'vm-a' -Confirm:$false | Should -BeTrue
        Should -Invoke -ModuleName Yuruna.Host Start-Job -Times 0 -Exactly
    }

    It 'Request-HyperVVMShutdown does not report a VM of unknown presence as stopped' {
        Mock -ModuleName Yuruna.Host Start-Job { throw 'no job expected' }
        $script:InventoryThrows = $true
        Request-HyperVVMShutdown -VMName 'vm-a' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host Start-Job -Times 0 -Exactly
    }

    It 'Rename-VM refuses an unknown destination without calling Hyper-V\Rename-VM' {
        $script:LookupBehavior = 'throw'
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VM' {
            if ($Name -and $Name[0] -eq 'src') { return [pscustomobject]@{ Name = 'src'; State = 'Off' } }
            throw 'Die RPC-Verbindung ist fehlgeschlagen.'
        }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' { }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' -Times 0 -Exactly
        $script:Keys | Should -Contain 'host.hyperv_vm_state_unknown'
    }

    It 'Rename-VM refuses an unknown source without calling Hyper-V\Rename-VM' {
        $script:InventoryThrows = $true
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' { }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' -Times 0 -Exactly
    }

    It 'Rename-VM refuses a source that is not positively stopped' {
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VM' {
            if ($Name -and $Name[0] -eq 'src') { return [pscustomobject]@{ Name = 'src'; State = 'Running' } }
            if ($Name) { throw [System.Management.Automation.ItemNotFoundException]::new('not found') }
            return @([pscustomobject]@{ Name = 'src'; State = 'Running' })
        }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' { }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' -Times 0 -Exactly
        $script:Keys | Should -Contain 'host.hyperv_rename_source_not_stopped'
    }

    It 'Rename-VM renames a present source onto a positively absent destination' {
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VM' {
            if ($Name -and $Name[0] -eq 'src') { return [pscustomobject]@{ Name = 'src'; State = 'Off' } }
            if ($Name) { throw [System.Management.Automation.ItemNotFoundException]::new('not found') }
            return @([pscustomobject]@{ Name = 'src'; State = 'Off' })
        }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' { }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMNetworkAdapter' { }
        Mock -ModuleName Yuruna.Host -CommandName 'Hyper-V\Get-VMHost' { [pscustomobject]@{ VirtualHardDiskPath = $null } }
        Rename-VM -VMName 'src' -NewName 'dst' -Confirm:$false | Should -BeTrue
        Should -Invoke -ModuleName Yuruna.Host -CommandName 'Hyper-V\Rename-VM' -Times 1 -Exactly
    }
}

Describe 'Hyper-V driver contract surface' {
    It 'exports the probe, the rung-2 verb and the new platform helpers' {
        $exported = @((Get-Module Yuruna.Host).ExportedFunctions.Keys)
        foreach ($name in 'Test-VirtualizationResponsive', 'Start-VirtualizationServiceIfStopped', 'Get-HyperVFeatureState', 'Get-HyperVServiceEvidence', 'Resolve-HyperVVM', 'Assert-HyperVEnabled') {
            $exported | Should -Contain $name
        }
    }
}
