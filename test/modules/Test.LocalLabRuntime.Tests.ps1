<#PSScriptInfo
.VERSION 2026.09.30
.GUID 427d7835-537a-46e8-a963-5fe9f73d0a55
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test local lab runtime pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture parameters bind the dynamically lifted production code and its mocked external boundaries.')]
[CmdletBinding()]
param()

BeforeAll {
    $script:TestRoot = Split-Path -Parent $PSScriptRoot
    $script:RepoRoot = Split-Path -Parent $script:TestRoot
    $script:PriorRuntime = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive runtime
    $null = New-Item -ItemType Directory $env:YURUNA_RUNTIME_DIR -Force
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -Force
    Import-Module powershell-yaml -Global
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Global -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1') -Global -Force -DisableNameChecking
    function Get-FixtureAst {
        param([string]$Path)
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:TestRoot $Path), [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors -join "`n") }
        return $ast
    }
    function Get-FixtureFunction {
        param([string]$Path, [string]$Name)
        $node = (Get-FixtureAst $Path).Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }.GetNewClosure(), $true)
        if (-not $node) { throw "Missing function: $Name" }
        return [scriptblock]::Create($node.Extent.Text)
    }
    function Get-FixtureRegion {
        param([string]$Path, [string]$Start, [string]$End)
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:TestRoot $Path)
        $first = $text.IndexOf($Start, [StringComparison]::Ordinal)
        $last = $text.IndexOf($End, $first, [StringComparison]::Ordinal)
        if ($first -lt 0 -or $last -le $first) { throw "Missing region: $Start" }
        return [scriptblock]::Create($text.Substring($first, $last - $first))
    }
    . (Get-FixtureFunction 'New-LocalTestUser.ps1' Invoke-SelfElevation)
    . (Get-FixtureFunction 'modules/Test.HostAddressBeacon.psm1' Get-HostBridgeDhcpIdentity)
    . (Get-FixtureFunction 'modules/Test.RunnerElevation.psm1' Test-RunnerElevationReady)
    . (Get-FixtureFunction 'modules/Test.PoolWorker.psm1' Invoke-PoolWorkerServiceTeardown)
    . (Get-FixtureFunction 'modules/Test.PoolWorker.psm1' Invoke-PoolWorkerShareWithdrawal)
    . (Get-FixtureFunction 'modules/Test.VMUtility.psm1' Invoke-GuestDhcpRelease)
    . (Get-FixtureFunction 'modules/Test.VMUtility.psm1' Assert-GuestAddressBounded)
    . (Get-FixtureFunction 'modules/Test.VMUtility.psm1' Remove-GuestVMQuietly)
    # External boundaries are replaced before these lifted functions can execute.
    function Invoke-GuestSsh { [CmdletBinding()]param($VMName, $GuestKey, $Command, $TimeoutSeconds, $AddressWaitSeconds); throw 'Unexpected SSH attempt' }
    function Stop-VM { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Mock boundary that never changes machine state.')][CmdletBinding(SupportsShouldProcess)]param([string]$VMName, [switch]$Force); throw 'Unexpected VM stop' }
    function Remove-VM { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Mock boundary that never changes machine state.')][CmdletBinding(SupportsShouldProcess)]param([string]$VMName); throw 'Unexpected VM removal' }
    function Get-VMState { throw 'Unexpected VM state probe' }
    function Get-PoolAggregatorServiceSeedUrl { throw 'Unexpected service discovery' }
    function Get-BestHostIp { '192.0.2.10' }
}

AfterAll { $env:YURUNA_RUNTIME_DIR = $script:PriorRuntime }

Describe 'local account elevation forwards identity fields' {
    It 'forwards explicit first and last names from the script invocation' {
        $script:UserScriptBoundParameters = @{ FirstName='Lab Operator'; LastName='Example Family' }
        $script:FirstName = 'Lab Operator'; $script:LastName = 'Example Family'; $script:AccountName = 'fixture-account'
        Mock Start-Process { }
        Invoke-SelfElevation -WantsPassword $false
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $Verb -eq 'RunAs' -and $ArgumentList -contains '-FirstName' -and
            $ArgumentList -contains '"Lab Operator"' -and $ArgumentList -contains '-LastName' -and
            $ArgumentList -contains '"Example Family"' -and $ArgumentList -contains '-NoPassword'
        }
    }
    It 'does not forward identity fields absent from the script invocation' {
        $script:UserScriptBoundParameters = @{}
        Mock Start-Process { }
        Invoke-SelfElevation -WantsPassword $true
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '-FirstName' -and $ArgumentList -notcontains '-LastName'
        }
    }
}

Describe 'discovery seeds and heals a local pool binding' {
    It 'writes the discovered proxy for a <Existing> binding' -TestCases @(
        @{ Existing=''; Expected='http://192.0.2.42/pool-intent.git' }
        @{ Existing='http://192.0.2.11/pool-intent.git'; Expected='http://192.0.2.42/pool-intent.git' }
        @{ Existing='ssh://git.example/custom.git'; Expected='ssh://git.example/custom.git' }
    ) {
        param($Existing, $Expected)
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $labDir = Join-Path $fixtureRoot lab
        $null = New-Item -ItemType Directory $labDir -Force
        $config = Join-Path $fixtureRoot test.config.yml
        @{ pool=@{ intentGitUrl=$Existing }; language='en-US' } | ConvertTo-Yaml | Set-Content $config
        Mock Import-Module { }
        $region = Get-FixtureRegion -Path 'lab/Set-LabToken.ps1' -Start '$poolHost = if' -End '$took = '
        $fragment = Join-Path $labDir seed-fixture.ps1
        Set-Content $fragment $region.ToString()
        & {
            param($proxyAddress, $baseUrl, $provision, $NoPoolConfig)
            & $fragment
        } '' 'http://192.0.2.42:9400/' @{ok=$true} $false
        $read = Get-Content -Raw $config | ConvertFrom-Yaml
        $read.pool.intentGitUrl | Should -Be $Expected
        if ($Existing -ne 'ssh://git.example/custom.git') { $read.pool.enabled | Should -BeTrue }
        $read.language | Should -Be 'en-US'
    }
    It 'uses canonical discovery for push forwarding despite an obsolete marker' {
        Mock Get-PoolAggregatorServiceSeedUrl { 'http://192.0.2.42:9400/' }
        $state = @{ cachingProxyService=@{address='192.0.2.11'} }
        $state.cachingProxyService.address | Should -Not -Be '192.0.2.42'
        $region = Get-FixtureRegion -Path 'modules/Invoke-PoolPushForwarder.ps1' -Start '$proxyIp = ' -End '# --- REGION: Resolve the cycle'
        . $region
        $proxyIp | Should -Be '192.0.2.42'
        Should -Invoke Get-PoolAggregatorServiceSeedUrl -Times 1 -Exactly
    }
}

Describe 'protected bridge configuration stays readable without a prompt' -Skip:(-not $IsLinux) {
    BeforeEach {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'nmcli' }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq '/etc/netplan/99-yuruna-external.yaml' }
        Mock Get-Content { throw [UnauthorizedAccessException]::new('fixture permission denied') } -ParameterFilter { $LiteralPath -eq '/etc/netplan/99-yuruna-external.yaml' }
    }
    It 'recognizes a multiline netplan identity through noninteractive sudo' {
        Mock sudo { $global:LASTEXITCODE = 0; 'network:', '  bridges:', '    yuruna-br0:', '      dhcp4: true', '      dhcp-identifier: mac' }
        $r = Get-HostBridgeDhcpIdentity
        $r.backend | Should -Be 'networkd'
        $r.pinned | Should -BeTrue
        Should -Invoke sudo -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq '-n cat /etc/netplan/99-yuruna-external.yaml' }
    }
    It 'reports unknown pinning when elevation cannot read the file' {
        Mock sudo { $global:LASTEXITCODE = 1 }
        $r = Get-HostBridgeDhcpIdentity
        $r.pinned | Should -BeNullOrEmpty
        $r.detail | Should -Match 'Cannot read netplan'
    }
}

Describe 'runner readiness requires uncached command execution' -Skip:(-not ($IsLinux -or $IsMacOS)) {
    It 'accepts passwordless execution and probes every command' {
        Mock sudo { $global:LASTEXITCODE = 0 }
        Test-RunnerElevationReady -Command @(@{Command='/fixture/virsh'}, @{Command='/fixture/qemu-img'}) | Should -BeTrue
        Should -Invoke sudo -Times 2 -Exactly -ParameterFilter { $args[0] -eq '-n' -and $args[1] -eq '-k' -and $args[-1] -eq '--version' }
    }
    It 'rejects list-only permission even when cached credentials would work' {
        Mock sudo { $global:LASTEXITCODE = if ($args -contains '-l' -or $args -notcontains '-k') { 0 } else { 1 } }
        Test-RunnerElevationReady -Command @(@{Command='/fixture/virsh'}) | Should -BeFalse
    }
}

Describe 'pool worker child progress does not enter the result stream' {
    It 'returns one typed service result for a noisy child exiting <Code>' -TestCases @(@{Code=0;Action='retired'}, @{Code=7;Action='failed'}) {
        param($Code, $Action)
        $root = Join-Path $TestDrive 'worker with spaces'
        $dir = Join-Path $root service
        $null = New-Item -ItemType Directory $dir -Force
        Set-Content (Join-Path $dir 'Stop-Fixture.ps1') "Write-Output 'native progress'; Write-Host 'host progress'; exit $Code"
        $r = @(Invoke-PoolWorkerServiceTeardown -TestRoot $root -Plan @(@{Key='fixture'; DisplayName='fixture';VMName='never-a-real-vm';Action='retire';StopScript='Stop-Fixture.ps1';State='running'}) -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0] | Should -BeOfType [pscustomobject]
        $r[0].Action | Should -Be $Action
        $r[0].ExitCode | Should -Be $Code
    }
    It 'returns one share result for a noisy child exiting <Code>' -TestCases @(@{Code=0;Action='withdrawn'}, @{Code=7;Action='failed'}) {
        param($Code, $Action)
        $root = Join-Path $TestDrive 'worker with spaces'
        $dir = Join-Path $root lab
        $null = New-Item -ItemType Directory $dir -Force
        Set-Content (Join-Path $dir 'Clear-LocalLabStorage.ps1') ('param([switch]$Force); if (-not $Force) { exit 99 }; Write-Output "share progress"; exit ' + $Code)
        $r = @(Invoke-PoolWorkerShareWithdrawal -TestRoot $root -Confirm:$false)
        $r.Count | Should -Be 1
        $r[0].Action | Should -Be $Action
        $r[0].ExitCode | Should -Be $Code
    }
}

Describe 'DHCP release has time to run before forced teardown' {
    BeforeEach {
        $script:DhcpReleaseAttempted = 0; $script:DhcpReleaseSucceeded = 0
        $script:Order = [Collections.Generic.List[string]]::new()
        Mock Assert-GuestAddressBounded { }
        Mock Get-VMState { 'not-found' }
        Mock Stop-VM { $script:Order.Add('stop') }
        Mock Remove-VM { $script:Order.Add('remove') }
        Mock Start-Sleep { $script:Order.Add("grace:$Seconds") }
    }
    It 'acknowledges a detached request and waits before stopping the VM' {
        Mock Invoke-GuestSsh { $script:Order.Add('ack'); @{exitCode=0} }
        Remove-GuestVMQuietly -VMName never-a-real-vm -GuestKey guest.fixture
        ($script:Order -join ',') | Should -Be 'ack,grace:2,stop,remove'
        Should -Invoke Invoke-GuestSsh -Times 1 -Exactly -ParameterFilter {
            $Command -match '^nohup ' -and $Command -match '</dev/null & exit 0$' -and $TimeoutSeconds -eq 8 -and $AddressWaitSeconds -eq 0
        }
        $script:DhcpReleaseSucceeded | Should -Be 1
    }
    It 'still tears down an unreachable guest without an additional grace delay' {
        Mock Invoke-GuestSsh { @{exitCode=255} }
        Remove-GuestVMQuietly -VMName never-a-real-vm -GuestKey guest.fixture
        ($script:Order -join ',') | Should -Be 'stop,remove'
        $script:DhcpReleaseSucceeded | Should -Be 0
    }
    It 'launches the scheduled release after the shell acknowledges it' -Skip:(-not ($IsLinux -or $IsMacOS)) {
        $marker = Join-Path $TestDrive release-ran
        $library = Join-Path $TestDrive release.sh
        Set-Content $library ('printf released > ' + "'$marker'")
        Mock Invoke-GuestSsh {
            param($Command)
            $fixtureCommand = $Command.Replace('/usr/local/lib/yuruna/yuruna-network.sh', "'$library'")
            & bash -c $fixtureCommand
            @{exitCode=$LASTEXITCODE}
        }
        Mock Start-Sleep { param($Seconds) [Threading.Thread]::Sleep($Seconds * 1000) }
        Invoke-GuestDhcpRelease -VMName never-a-real-vm -GuestKey guest.fixture | Should -BeTrue
        (Get-Content -Raw $marker) | Should -Be 'released'
    }
}

Describe 'pool-control markers advertise reachable endpoints' {
    It 'advertises <Expected> for <Mode> with forwarding <Forwarded>' -TestCases @(
        @{Mode='Shared';Forwarded=$true;Ready=$true;Unreachable=$false;Expected='http://192.0.2.10:8081'}
        @{Mode='Shared';Forwarded=$false;Ready=$true;Unreachable=$false;Expected=''}
        @{Mode='Shared';Forwarded=$true;Ready=$false;Unreachable=$false;Expected=''}
        @{Mode='Shared';Forwarded=$true;Ready=$true;Unreachable=$true;Expected=''}
        @{Mode='Bridged';Forwarded=$false;Ready=$true;Unreachable=$false;Expected='http://192.0.2.42'}
    ) {
        param($Mode, $Forwarded, $Ready, $Unreachable, $Expected)
        $script:bundleMode=$Mode; $script:poolControlForwarded=$Forwarded; $script:daemonReady=$Ready
        $script:listeningButUnreachable=$Unreachable; $script:HostType='host.macos.utm'; $script:vmIp='192.0.2.42'
        $ast = Get-FixtureAst 'service/Start-PoolControlServiceVM.ps1'
        $assignment = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$poolControlServiceBaseUrl'}, $true)
        . ([scriptblock]::Create($assignment.Extent.Text))
        $poolControlServiceBaseUrl | Should -Be $Expected
    }
}

Describe 'orchestration finalizes escaping failures honestly' {
    BeforeAll {
        function Write-OrchestratorLine { }
        function Write-CycleStepEvent { }
        function Complete-Run { param($OverallStatus, $MaxHistoryRuns) }
        function Stop-LogFile { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mock boundary that never changes files.')][CmdletBinding()]param($Outcome, $Reason) }
        function Set-NestedRunStatus { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Mock boundary that never changes machine state.')][CmdletBinding(SupportsShouldProcess)]param($Status, $StatusPath, $NodeId) }
        function Stop-NestedLogFile { [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Mock boundary that never changes machine state.')][CmdletBinding(SupportsShouldProcess)]param() }
        $ast = Get-FixtureAst 'modules/Test.Orchestrator.psm1'
        $node = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.TryStatementAst] -and $n.Finally -and
            $n.CatchClauses.Count -gt 0 -and $n.CatchClauses[0].Body.Extent.Text -match '\$overall = ''fail'''
        }, $true)
        $script:FinalizeRegion = [scriptblock]::Create($node.Extent.Text)
        $script:RunnerFinalizedRegion = Get-FixtureRegion -Path 'modules/Test.RunnerInnerLoop.psm1' -Start '$finalizationException = $_.Exception' -End '    if ($_.Exception.Message -like'
    }
    It 'records <Outcome> once for an escaping exception, nested=<Nested>' -TestCases @(
        @{Restart=$false;Nested=$false;Outcome='fail'}
        @{Restart=$true;Nested=$false;Outcome='aborted'}
        @{Restart=$false;Nested=$true;Outcome='fail'}
    ) {
        param($Restart, $Nested, $Outcome)
        $script:Thrown = [Management.Automation.RuntimeException]::new('fixture entry failure')
        if ($Restart) { $script:Thrown.Data['YurunaCycleRestart']=$true }
        Mock Write-CycleStepEvent { throw $script:Thrown }
        Mock Complete-Run { }
        Mock Stop-LogFile { }
        Mock Set-NestedRunStatus { }
        Mock Stop-NestedLogFile { }
        $script:ExpectedOutcome = $Outcome
        $script:CycleFinalized = $false
        $caught = & {
            param($entries, $orchNested, $overall, $Config, $statusFile, $orchNodeId)
            try { . $script:FinalizeRegion } catch {
                . $script:RunnerFinalizedRegion
                return $_.Exception
            }
        } @(@{index=1;name='fixture';kind='guest'}) $Nested pass @{} fixture-status fixture-node
        $caught.Message | Should -Match 'fixture entry failure'
        if ($Nested) {
            Should -Invoke Set-NestedRunStatus -Times 1 -Exactly -ParameterFilter { $Status -eq 'fail' }
            Should -Invoke Complete-Run -Times 0 -Exactly
            $script:CycleFinalized | Should -BeFalse
        } else {
            Should -Invoke Complete-Run -Times 1 -Exactly -ParameterFilter { $OverallStatus -eq 'fail' }
            Should -Invoke Stop-LogFile -Times 1 -Exactly -ParameterFilter { $Outcome -eq $script:ExpectedOutcome }
            $script:CycleFinalized | Should -BeTrue
        }
    }
}

Describe 'host-side pool-control launch boundaries' {
    It 'passes repository and executable paths with spaces to the native daemon' -Skip:(-not $IsLinux) {
        $fixtureDir = Join-Path $TestDrive 'host proof with spaces'
        $null = New-Item -ItemType Directory $fixtureDir -Force
        $binPath = Join-Path $fixtureDir 'daemon fixture'
        $outputPath = Join-Path $fixtureDir argv.json
        Set-Content $binPath ("#!/usr/bin/python3`nimport json,sys`nwith open(" + ($outputPath | ConvertTo-Json -Compress) + ", 'w') as f: json.dump(sys.argv[1:],f)")
        & chmod +x $binPath
        $build = Get-FixtureRegion -Path 'service/Start-PoolControlServiceVM.ps1' -Start '$goArgs = ' -End '# A stop published'
        $launch = Get-FixtureRegion -Path 'service/Start-PoolControlServiceVM.ps1' -Start '    $launch = ' -End '    Start-Sleep -Seconds 1'
        & {
            param($repoRoot, $pwshExe, $poolControlLanguage, $intentGitUrl, $AggregatorUrl, $hostId, $Port, $AllowPseudoLocale)
            . $build
            . $launch
            try { $proc.WaitForExit(); $proc.ExitCode | Should -Be 0 } finally { $proc.Dispose() }
        } 'C:\repository folder' 'C:\Program Files\PowerShell\pwsh.exe' 'en-US' 'https://example.test/a b.git' 'https://192.0.2.42:9400' 'fixture-host-id' 8081 $true
        $argv = @(Get-Content -Raw $outputPath | ConvertFrom-Json)
        $argv | Should -Be @('--http-addr','0.0.0.0:8081','--repo-dir','C:\repository folder','--pwsh','C:\Program Files\PowerShell\pwsh.exe',
            '--language','en-US','--intent-git-url','https://example.test/a b.git','--aggregator-url','https://192.0.2.42:9400','--host-id','fixture-host-id','--allow-pseudo-locale')
    }
    It 'initializes identity and writes registration from the host-proof path' {
        function Get-YurunaHostId { 'fixture-host-id' }
        $priorId = Get-Variable __YurunaHostId -Scope Global -ErrorAction SilentlyContinue
        try {
            Remove-Variable __YurunaHostId -Scope Global -ErrorAction SilentlyContinue
            $init = Get-FixtureRegion -Path 'service/Start-PoolControlServiceVM.ps1' -Start '$hostId = Get-YurunaHostId' -End '# Read the same validated lab-wide language'
            & { param($ModulesDir); . $init; $hostId | Should -Be 'fixture-host-id' } $PSScriptRoot
            (Get-Variable __YurunaHostId -Scope Global -ValueOnly) | Should -Be 'fixture-host-id'
            Import-Module (Join-Path $PSScriptRoot 'Test.ExtensionService.psm1') -Global -Force
            $null = Write-ExtensionServiceMarker -Area pool-control-service -RuntimeDir $env:YURUNA_RUNTIME_DIR -Active $true -BaseUrl 'http://192.0.2.10:8081' -HostingMode host-process
            $ast = Get-FixtureAst 'service/Start-PoolControlServiceVM.ps1'
            $registration = @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -like 'Get-Command Write-HostRegistrationRecord*'}, $true))[-1]
            & { param($repoRoot); . ([scriptblock]::Create($registration.Extent.Text)) } $script:RepoRoot
            $record = Get-Content -Raw (Join-Path $env:YURUNA_RUNTIME_DIR host.registration.json) | ConvertFrom-Json
            $record.hostId | Should -Be 'fixture-host-id'
            $record.hostType | Should -Be (Get-HostType)
            $record.activeExtensions | Should -Contain pool-control-service
            $record.extensionTargets.'pool-control-service' | Should -Be 'http://192.0.2.10:8081'
        } finally {
            if ($priorId) { Set-Variable __YurunaHostId -Scope Global -Value $priorId.Value }
            else { Remove-Variable __YurunaHostId -Scope Global -ErrorAction SilentlyContinue }
        }
    }
}
