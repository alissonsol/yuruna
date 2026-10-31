<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42693904-5594-400c-b81a-812929c53f21
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension service start lifecycle
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
    The stash, pool-control and download-agent starts run one shared pipeline.
.DESCRIPTION
    Start-StashServiceVM.ps1, Start-PoolControlServiceVM.ps1 and
    Start-DownloadAgentServiceVM.ps1 name their service and run
    test/service/Start-ExtensionService.ps1, which runs the service's own
    readiness part inside the start operation's try block. These cases hold
    the entry scripts to forwarding everything they take, the parts to ending
    every run with an exit, and a real start, run against stand-ins for every
    host effect, to the exit code and operation result its part decides.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.ServiceStartSource.psm1') -Force -DisableNameChecking
    $script:ServiceDir = Join-Path (Get-YurunaTestRepoRoot -SuiteDirectory $PSScriptRoot) 'test/service'

    function Get-NamedArgumentText {
        param($CommandAst, [string]$ParameterName)
        $els = $CommandAst.CommandElements
        for ($i = 0; $i -lt $els.Count; $i++) {
            if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $ParameterName) {
                $arg = if ($els[$i].Argument) { $els[$i].Argument } elseif ($i + 1 -lt $els.Count) { $els[$i + 1] } else { $null }
                if ($arg) { return $arg.Extent.Text }
                return ''
            }
        }
        return $null
    }

    # Runs a real entry script in a runspace of its own with every module and
    # host effect replaced by a stand-in, and returns what the run decided.
    # Endpoint: what the readiness wait reports ('ready' or 'silent').
    # Build: '' adopts the running VM; 'ok' or 'fails' rebuilds it.
    # Preview: run the entry script with -WhatIf.
    # The stand-ins read the case through $Fixture* names: the parts keep
    # variables such as $endpoint and $build of their own, which a stand-in
    # called from them would otherwise find first.
    function Invoke-ServiceStartFixture {
        param([string]$Name, [string]$Endpoint = 'ready', [string]$Build = '', [switch]$Preview)
        $driver = {
            param($Path, $FixtureEndpoint, $FixtureBuild, $Preview)
            $null = $FixtureEndpoint, $FixtureBuild
            Set-Variable IsWindows -Value $false -Force
            $fixture = @{ Calls = [System.Collections.Generic.List[string]]::new(); Enter = $null; Result = '' }
            function Import-Module {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'Isolated test stub blocks real module loading.')]
                param()
            }
            function Test-Path {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '',
                    Justification = 'Isolated test stub: every configured path exists.')]
                param()
                $true
            }
            function Use-LogLevelFromEnv {}
            function Initialize-YurunaEntryPoint { @{ RepoRoot = '/unused'; ModulesDir = '/unused/modules' } }
            function Get-EntryPointExitCode { param([string]$Outcome) if ($Outcome -eq 'Ok') { 0 } else { 1 } }
            function Invoke-LibvirtGroupReExecIfNeeded {}
            function Get-HostType { 'test.host' }
            function Get-HostFolder { 'host/test' }
            function Initialize-YurunaHost { $true }
            function Initialize-YurunaRuntimeDir { '/unused/runtime' }
            function Enter-YurunaServiceOperation {
                param([string]$Key, [string]$Script)
                $fixture.Enter = "$Key|$Script"
                [pscustomobject]@{ Proceed = $true; Message = '' }
            }
            function Exit-YurunaServiceOperation {
                param([string]$Result)
                $fixture.Result += $Result
            }
            function Import-Extension {}
            function Read-TestConfig { @{} }
            function Get-YurunaStashStorageConfig { [pscustomobject]@{ NetworkUser = 'u'; NetworkPath = '//nas/stash' } }
            function Get-YurunaPoolStorageConfig { [pscustomobject]@{ NetworkUser = 'u'; NetworkPath = '//nas/pool' } }
            function Test-PoolStorageStoredCredential { $true }
            function Connect-YurunaPoolStorage { $true }
            function Start-YurunaStatusServiceIfEnabled {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated stand-in changes no state.')]
                param()
                @{ ShouldStart = $false; Port = 0 }
            }
            function Get-FrameworkSourceSnapshot { 'snapshot' }
            # Production commands named Assert-*: defined without a function
            # statement, which the suites reserve for Test.Assert.psm1's helpers.
            Set-Item -Path 'function:Assert-GuestFrameworkSource' -Value { $true }
            function Resolve-YurunaServiceVmAdoption {
                if ($FixtureBuild) { [pscustomobject]@{ Decision = 'rebuild'; Reason = 'absent'; Address = '' } }
                else { [pscustomobject]@{ Decision = 'adopt'; Reason = 'serving'; Address = '192.0.2.5' } }
            }
            function Format-YurunaOperatorMessage { param([string]$Key) $Key }
            function Test-YurunaServiceVmBuildPlan { [pscustomobject]@{ Ok = $true } }
            function Remove-YurunaServiceVmAdvertisement {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated stand-in records the call without touching any state.')]
                param()
                $fixture.Calls.Add('withdraw'); $true
            }
            function Invoke-YurunaServiceVmBuild {
                $fixture.Calls.Add('build')
                if ($FixtureBuild -eq 'fails') { [pscustomobject]@{ Ok = $false; Error = 'builder refused'; ExitCode = 124; Degraded = @() } }
                else { [pscustomobject]@{ Ok = $true; Error = ''; ExitCode = 0; Degraded = @() } }
            }
            function Wait-VMIp { '192.0.2.5' }
            function Get-ExtensionServiceReadyTimeoutSeconds {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Stand-in carries the real command''s name.')]
                param()
                60
            }
            function Get-DownloadAgentServiceReadyTimeoutSeconds {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Stand-in carries the real command''s name.')]
                param()
                60
            }
            function Wait-YurunaServiceVmDaemon {
                $fixture.Calls.Add('wait')
                [pscustomobject]@{ Ready = ($FixtureEndpoint -eq 'ready'); Unreachable = $false; StillBuilding = $false; Address = '192.0.2.5'
                    WaitedSeconds = 60; ExtendedSeconds = 0; ObservedState = 'fixture'; CloudInitStatus = 'done'; LastProgress = '' }
            }
            function Get-ServiceVmReadinessVerdict {
                param($Endpoint)
                if ($Endpoint -and $Endpoint.Ready) { [pscustomobject]@{ Outcome = 'Ready'; IsFailure = $false; Summary = 'ready' } }
                else { [pscustomobject]@{ Outcome = 'NotServing'; IsFailure = $true; Summary = 'not serving' } }
            }
            function Confirm-ServiceVmAtRecoveredAddress { [pscustomobject]@{ Ready = $false; Address = ''; Probed = $false; Summary = 'nothing found' } }
            Set-Item -Path 'function:Assert-ServiceVmFrameworkSource' -Value { $true }
            function Test-YurunaServiceOperationCurrent { $true }
            function Resolve-YurunaServiceStartOutcome {
                param($Verdict)
                if ($Verdict.Outcome -eq 'Ready') { [pscustomobject]@{ Result = 'confirmed'; Advertise = $true; State = 'ready'; Degraded = @() } }
                else { [pscustomobject]@{ Result = 'failed'; Advertise = $false; State = 'not-serving'; Degraded = @() } }
            }
            function Write-ExtensionServiceMarker { $fixture.Calls.Add('marker'); $true }
            function Write-DownloadAgentServiceMarker { $fixture.Calls.Add('marker'); $true }
            function Resolve-DownloadAgentServiceBaseUrl { 'http://192.0.2.5' }
            function Update-StashServiceMarkerAddress {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                    Justification = 'Isolated stand-in changes no state.')]
                param()
                'http://192.0.2.5'
            }
            function Get-YurunaHostId { 'fixture-host' }
            function Write-HostRegistrationRecord { $true }
            function Sync-PoolConfigurationAliasOnProxy { [pscustomobject]@{ Changed = $false; Ok = $true; Message = 'current' } }
            function Invoke-YurunaServiceVmFailureDiagnostic { $fixture.Calls.Add('diagnostics') }
            function Format-GuestSshDiagnosticHint { 'hint' }
            function Test-TcpEndpointOpen { $true }
            $info = $null
            $output = @(& $Path -WhatIf:$Preview -Confirm:$false -InformationVariable info -WarningAction SilentlyContinue `
                    -ErrorAction SilentlyContinue 4>$null 6>$null)
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Enter = $fixture.Enter
                Result = $fixture.Result
                Calls = [string[]]$fixture.Calls.ToArray()
                Output = [string[]]@($output | ForEach-Object { "$_" })
                Information = [string[]]@($info | ForEach-Object { "$($_.MessageData)" })
            }
        }
        $shell = [PowerShell]::Create()
        try {
            [void]$shell.AddScript($driver.ToString()).AddArgument((Join-Path $script:ServiceDir $Name)).AddArgument($Endpoint).AddArgument($Build).AddArgument([bool]$Preview)
            $row = @($shell.Invoke()) | Select-Object -Last 1
            if ($shell.HadErrors -and -not $row) { throw "The $Name fixture failed: $($shell.Streams.Error[0])" }
            return $row
        } finally {
            $shell.Dispose()
        }
    }
}

Describe 'the three Start entry scripts forward to the shared pipeline' {
    It '<Name> forwards every parameter the pipeline takes, with its service key' -ForEach @(
        @{ Name = 'Start-StashServiceVM.ps1'; Key = 'stash'; Area = 'stash-service' }
        @{ Name = 'Start-PoolControlServiceVM.ps1'; Key = 'pool-control'; Area = 'pool-control-service' }
        @{ Name = 'Start-DownloadAgentServiceVM.ps1'; Key = 'download-agent'; Area = 'download-agent-service' }
    ) {
        $wrapper = Get-YurunaTestFileAst -Path (Join-Path $script:ServiceDir $Name)
        $calls = @($wrapper.FindAll({ param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Ampersand' -and $n.Extent.Text -match "'Start-ExtensionService\.ps1'"
                }, $true))
        Assert-Equal -Expected 1 -Actual $calls.Count -Because "$Name runs the shared pipeline once"
        $call = $calls[0]
        Assert-StringEqual -Expected "'$Key'" -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'ServiceKey')
        Assert-StringEqual -Expected "'$Area'" -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'Area')
        Assert-StringEqual -Expected '$PSCommandPath' -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'CallerScript')
        Assert-StringEqual -Expected '$false' -Actual (Get-NamedArgumentText -CommandAst $call -ParameterName 'Confirm') -Because 'the entry script has already confirmed the operation'
        $shared = Get-YurunaTestFileAst -Path (Join-Path $script:ServiceDir 'Start-ExtensionService.ps1')
        $declared = @($wrapper.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($parameter in @($shared.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })) {
            if ($parameter -in @('ServiceKey', 'Area', 'CallerScript')) { continue }
            Assert-True ($declared -contains $parameter) "$Name declares -$parameter"
            $forwarded = Get-NamedArgumentText -CommandAst $call -ParameterName $parameter
            Assert-True ($forwarded -eq "`$$parameter" -or $forwarded -eq ":`$$parameter") "$Name forwards -$parameter as given, got '$forwarded'"
        }
        $next = $call.Parent.Parent.Statements | Where-Object { $_.Extent.StartOffset -gt $call.Extent.EndOffset } | Select-Object -First 1
        Assert-StringEqual -Expected 'exit $LASTEXITCODE' -Actual $next.Extent.Text -Because "$Name exits with the code the pipeline exited with"
    }
}

Describe 'what a start runs, read as one text' {
    It 'reads <Name> as the shared pipeline with its own part, loaded once' -ForEach @(
        @{ Name = 'Start-StashServiceVM.ps1'; Own = '== stash-service start: complete'; Other = 'pool-control-service is READY' }
        @{ Name = 'Start-PoolControlServiceVM.ps1'; Own = 'pool-control-service is READY'; Other = 'download-agent-service is READY' }
        @{ Name = 'Start-DownloadAgentServiceVM.ps1'; Own = 'download-agent-service is READY'; Other = '== stash-service start: complete' }
    ) {
        $text = Get-YurunaServiceStartText -Path (Join-Path $script:ServiceDir $Name)
        Assert-True ($text.Contains("Enter-YurunaServiceOperation -Key `$ServiceKey")) 'the shared pipeline is read'
        Assert-True ($text.Contains($Own)) "the $Name part is read in place"
        Assert-True (-not $text.Contains($Other)) 'another service''s part is not'
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($text, [regex]::Escape('<#PSScriptInfo'))).Count -Because 'the part is read without its own header'
        $ast = Get-YurunaServiceStartAst -Path (Join-Path $script:ServiceDir $Name)
        $try = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally -and $n.Finally.Extent.Text -match 'Exit-YurunaServiceOperation' }, $true)
        $wait = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-YurunaServiceVmDaemon' }, $true)
        Assert-True ($null -ne $try -and $null -ne $wait -and $try.Body.Extent.StartOffset -lt $wait.Extent.StartOffset -and $wait.Extent.EndOffset -lt $try.Body.Extent.EndOffset) `
            'the readiness part runs inside the operation''s try block'
    }

    It 'ends every <Key> part at an exit, with no return that would end the start without a code' -ForEach @(
        @{ Key = 'stash' }, @{ Key = 'pool-control' }, @{ Key = 'download-agent' }
    ) {
        $part = Get-YurunaTestFileAst -Path (Join-Path $script:ServiceDir "Start-ExtensionService.$Key.ps1")
        $last = $part.EndBlock.Statements[-1]
        Assert-True ($last -is [System.Management.Automation.Language.ExitStatementAst]) "the $Key part's last statement is an exit, not '$($last.Extent.Text)'"
        $returns = @($part.FindAll({ param($n)
                    if ($n -isnot [System.Management.Automation.Language.ReturnStatementAst]) { return $false }
                    $owner = $n.Parent
                    while ($owner -and $owner -isnot [System.Management.Automation.Language.ScriptBlockAst]) { $owner = $owner.Parent }
                    $owner -eq $part
                }, $true))
        Assert-Equal -Expected 0 -Actual $returns.Count -Because 'a return in a part ends the start with no exit code'
    }

    It 'refuses to run the <Key> part on its own' -ForEach @(
        @{ Key = 'stash' }, @{ Key = 'pool-control' }, @{ Key = 'download-agent' }
    ) {
        $part = Join-Path $script:ServiceDir "Start-ExtensionService.$Key.ps1"
        Assert-Throw { & $part } -Match 'runs only inside Start-ExtensionService\.ps1'
    }
}

Describe 'a start runs through the shared pipeline' {
    It 'a <Key> start whose daemon serves exits 0 and confirms its operation' -ForEach @(
        @{ Key = 'stash'; Name = 'Start-StashServiceVM.ps1'; Banner = '== stash-service start: complete'; OnOutput = $true }
        @{ Key = 'pool-control'; Name = 'Start-PoolControlServiceVM.ps1'; Banner = 'The pool-control-service daemon is serving on :80.'; OnOutput = $false }
        @{ Key = 'download-agent'; Name = 'Start-DownloadAgentServiceVM.ps1'; Banner = 'The download-agent-service daemon is serving on :80.'; OnOutput = $false }
    ) {
        $run = Invoke-ServiceStartFixture -Name $Name -Endpoint 'ready'
        Assert-Equal -Expected 0 -Actual $run.ExitCode
        Assert-StringEqual -Expected "$Key|$Name" -Actual $run.Enter -Because 'the operation is recorded under the service key and the entry script''s name'
        Assert-StringEqual -Expected 'confirmed' -Actual $run.Result -Because 'the finally closes the operation once, with the part''s result'
        Assert-StringEqual -Expected 'wait,marker' -Actual ($run.Calls -join ',')
        $where = if ($OnOutput) { $run.Output } else { $run.Information }
        Assert-True (@($where | Where-Object { $_.Contains($Banner) }).Count -eq 1) "the outcome line keeps its stream; output: $($run.Output -join ' | '); information: $($run.Information -join ' | ')"
        Assert-True (@($run.Output | Where-Object { $_ -eq 'runner.service_adopted' }).Count -eq [int]$OnOutput) 'the adoption line keeps its stream'
    }

    It 'a <Key> start whose daemon never serves exits 1 after its diagnostics and fails its operation' -ForEach @(
        @{ Key = 'stash'; Name = 'Start-StashServiceVM.ps1' }
        @{ Key = 'pool-control'; Name = 'Start-PoolControlServiceVM.ps1' }
        @{ Key = 'download-agent'; Name = 'Start-DownloadAgentServiceVM.ps1' }
    ) {
        $run = Invoke-ServiceStartFixture -Name $Name -Endpoint 'silent'
        Assert-Equal -Expected 1 -Actual $run.ExitCode
        Assert-StringEqual -Expected 'failed' -Actual $run.Result
        Assert-StringEqual -Expected 'wait,marker,diagnostics' -Actual ($run.Calls -join ',')
    }

    It 'a <Key> rebuild withdraws before it builds and ends with the builder''s code when the build fails' -ForEach @(
        @{ Key = 'stash'; Name = 'Start-StashServiceVM.ps1' }
        @{ Key = 'pool-control'; Name = 'Start-PoolControlServiceVM.ps1' }
        @{ Key = 'download-agent'; Name = 'Start-DownloadAgentServiceVM.ps1' }
    ) {
        $built = Invoke-ServiceStartFixture -Name $Name -Endpoint 'ready' -Build 'ok'
        Assert-Equal -Expected 0 -Actual $built.ExitCode
        Assert-StringEqual -Expected 'withdraw,build,wait,marker' -Actual ($built.Calls -join ',')
        $failed = Invoke-ServiceStartFixture -Name $Name -Endpoint 'ready' -Build 'fails'
        Assert-Equal -Expected 124 -Actual $failed.ExitCode
        Assert-StringEqual -Expected 'failed' -Actual $failed.Result
        Assert-StringEqual -Expected 'withdraw,build' -Actual ($failed.Calls -join ',') -Because 'nothing is waited for or advertised after a failed build'
    }

    It 'a <Key> start changes nothing under -WhatIf' -ForEach @(
        @{ Key = 'stash'; Name = 'Start-StashServiceVM.ps1' }
        @{ Key = 'pool-control'; Name = 'Start-PoolControlServiceVM.ps1' }
        @{ Key = 'download-agent'; Name = 'Start-DownloadAgentServiceVM.ps1' }
    ) {
        $run = Invoke-ServiceStartFixture -Name $Name -Preview
        Assert-True ($null -eq $run.Enter) 'no operation is recorded'
        Assert-Equal -Expected 0 -Actual $run.Calls.Count
        Assert-StringEqual -Expected '' -Actual $run.Result
    }
}
