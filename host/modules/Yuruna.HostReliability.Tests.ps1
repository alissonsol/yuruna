<#PSScriptInfo
.VERSION 2026.09.27
.GUID 4270c5ae-4f32-42b7-a8e4-08bd28d7d218
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host lifecycle pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture commands retain the signatures called by isolated production functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Production functions and blocks consume these fixture variables through dynamic scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'These test-local stubs isolate file paths and timing from the live host.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'These test-local stubs perform no host mutation.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The Hyper-V fixture intentionally returns a small hashtable model.')]
[CmdletBinding()]
param()
if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) { throw 'Run this suite with Pester.' }
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    function Get-SourceFunction {
        param([string]$Path, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $Path), [ref]$null, [ref]$null)
        $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
        if (-not $functionAst) { throw "Missing function $Name in $Path" }
        return $functionAst.Extent.Text
    }
    function Format-YurunaOperatorMessage { param($Key, $Arguments) return $Key }
}
Describe 'Cache host discovery honors explicit remote topology' {
    It 'uses a reachable explicit cache and refuses an unreachable one on <Platform>' -ForEach @(
        @{ Platform = 'macos.utm' }, @{ Platform = 'windows.hyper-v' }, @{ Platform = 'ubuntu.kvm' }
    ) {
        . ([scriptblock]::Create((Get-SourceFunction "host/$Platform/modules/Yuruna.Host.psm1" 'Resolve-CacheHostIp')))
        function Get-CachingProxyServicePort { return 3128 }
        function Test-IpAddress { param($Address) return $Address -eq '192.0.2.5' }
        function Test-CachingProxyServicePort { return $script:CacheReachable }
        function Get-VM { throw 'Local discovery must not override an explicit pin.' }
        function Get-CachingProxyServiceVmIp { throw 'Local discovery must not override an explicit pin.' }
        function Read-CachingProxyServiceState { throw 'Local discovery must not override an explicit pin.' }
        $prior = $env:YURUNA_CACHING_PROXY_SERVICE_IP
        try {
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = ' 192.0.2.5 '
            $script:CacheReachable = $true
            Resolve-CacheHostIp | Should -Be '192.0.2.5'
            $script:CacheReachable = $false
            Resolve-CacheHostIp | Should -BeNullOrEmpty
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = 'invalid'
            Resolve-CacheHostIp | Should -BeNullOrEmpty
        } finally { $env:YURUNA_CACHING_PROXY_SERVICE_IP = $prior }
    }
}
Describe 'Image lookup includes every installed guest builder' {
    It 'resolves Ubuntu 26 and the UTM macOS image without loading a hypervisor' {
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            $source = Get-Content (Join-Path $script:RepoRoot "host/$platform/modules/Yuruna.Host.psm1") -Raw
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
            $table = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] -and $node.Extent.Text.Contains("'guest.ubuntu.server.24'") }, $true)
            $paths = & ([scriptblock]::Create($table.Extent.Text))
            $paths['guest.ubuntu.server.26'] | Should -Match 'guest\.ubuntu\.server\.26\.iso$'
            if ($platform -eq 'macos.utm') { $paths['guest.macos.26'] | Should -Match 'guest\.macos\.26\.ipsw$' }
        }
    }
}
Describe 'Forwarder identity survives refused signals' {
    It 'keeps the pidfile and reports false until the process is confirmed gone' {
        . ([scriptblock]::Create((Get-SourceFunction 'host/macos.utm/modules/Yuruna.Host.psm1' 'Stop-CachingProxyServiceForwarder')))
        $script:FixturePid = Join-Path $TestDrive 'forwarder.80.pid'
        Set-Content $script:FixturePid '12345'
        function Join-Path { param($Path, $ChildPath) if ($ChildPath -like '*.pid') { return $script:FixturePid }; return $TestDrive }
        function Invoke-UtmHostTool {
            param($Tool, $ArgumentList)
            if ($Tool -eq 'ps' -and $ArgumentList[-1] -eq 'command=') { return @{ ExitCode = 0; StdOut = 'pwsh Start-CachingProxyServiceForwarder.ps1' } }
            if ($Tool -eq 'ps' -and $ArgumentList[-1] -eq 'user=') { return @{ ExitCode = 0; StdOut = 'root' } }
            if ($Tool -eq 'ps') { return @{ ExitCode = $script:AliveCode; StdOut = '12345' } }
            return @{ ExitCode = 1; StdOut = '' }
        }
        function Test-UtmBoundedResultComplete { return $true }
        function Get-UtmCurrentUid { return '1000' }
        function New-YurunaDeadline { return @{} }
        function Wait-UtmInterval { return $false }
        function Start-Sleep { }
        $script:UtmHostTool = @{ kill = '/bin/kill' }
        $script:AliveCode = 0
        Stop-CachingProxyServiceForwarder -Port 80 -Quiet -Confirm:$false | Should -BeFalse
        [IO.File]::Exists($script:FixturePid) | Should -BeTrue
        $script:AliveCode = 1
        Stop-CachingProxyServiceForwarder -Port 80 -Quiet -Confirm:$false | Should -BeTrue
        [IO.File]::Exists($script:FixturePid) | Should -BeFalse
    }
}
Describe 'Orphan classification preserves the distinction between VM disks and system data' {
    It 'recognizes a nested or adjacent VHD root as user artifacts' {
        . ([scriptblock]::Create((Get-SourceFunction 'host/windows.hyper-v/Remove-OrphanedVMFiles.ps1' 'Test-IsHyperVSystemPath')))
        $vmPathNormalized = 'C:\HyperV'
        $hyperVVmDataPath = 'C:\HyperV\Virtual Machines'
        foreach ($vhdPath in 'C:\HyperV\Virtual Hard Disks', 'C:\HyperVDisks') {
            Test-IsHyperVSystemPath "$vhdPath\guest\guest.vhdx" | Should -BeFalse
        }
        Test-IsHyperVSystemPath 'C:\HyperV\Resource Types\state' | Should -BeTrue
        Test-IsHyperVSystemPath 'C:\HyperVBackup\guest.vhdx' | Should -BeFalse
    }
    It 'aborts inventory before cleanup when a registered disk query fails' {
        $source = Get-Content (Join-Path $script:RepoRoot 'host/windows.hyper-v/Remove-OrphanedVMFiles.ps1') -Raw
        $start = $source.IndexOf('$allVMs =')
        $end = $source.IndexOf('# --- REGION:', $source.IndexOf('foreach ($vm in $allVMs)', $start) + 1)
        $inventory = $source.Substring($start, $end - $start)
        function Get-VM { [CmdletBinding()]param(); return @{ Name = 'registered'; Path = ''; ConfigurationLocation = ''; SnapshotFileLocation = '' } }
        function Get-VMHardDiskDrive { [CmdletBinding()]param($VMName); Write-Error 'inventory unavailable' }
        function Write-CleanupMessage { }
        $allFiles = @('C:\VMDisks\registered\registered.vhdx')
        $ErrorActionPreference = 'Continue'
        { & ([scriptblock]::Create($inventory)) } | Should -Throw '*inventory unavailable*'
    }
}
Describe 'VM provisioning fails immediately on non-terminating cmdlet errors' {
    It 'halts each affected builder before a later completion step' {
        $paths = Get-ChildItem (Join-Path $script:RepoRoot 'host/macos.utm/guest.*/New-VM.ps1')
        $paths += Get-ChildItem (Join-Path $script:RepoRoot 'host/windows.hyper-v/guest.*/New-VM.ps1')
        foreach ($path in $paths) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path.FullName, [ref]$null, [ref]$null)
            $assignment = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$ErrorActionPreference' }, $true)
            $assignment | Should -Not -BeNullOrEmpty -Because $path.FullName
            $probe = [scriptblock]::Create($assignment.Extent.Text + "; Write-Error 'failed VM start'; 'reported complete'")
            { & $probe } | Should -Throw '*failed VM start*'
        }
    }
}
Describe 'Host control results preserve the caller contract' {
    It 'retains the outer Confirm setting through Restore-Knob on <Platform>' -ForEach @(
        @{ Platform = 'ubuntu.kvm' }, @{ Platform = 'windows.hyper-v' }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot "host/$Platform/Disable-TestAutomation.ps1") -Raw
        $capture = [regex]::Match($source, '(?m)^\$Script:DisableCmdlet = \$PSCmdlet$').Value
        $restore = Get-SourceFunction "host/$Platform/Disable-TestAutomation.ps1" 'Restore-Knob'
        function Invoke-HostKnobRestore { param($Cmdlet); return $Cmdlet.MyInvocation.BoundParameters['Confirm'] }
        $probe = [scriptblock]::Create("[CmdletBinding(SupportsShouldProcess)]param()`n" + $capture + "`n" + $restore + "`nRestore-Knob -Name fixture -Description fixture -Apply { }" )
        & $probe -Confirm:$false | Should -BeFalse
        & $probe -Confirm:$true | Should -BeTrue
    }
    It 'returns a single false when an old forwarder stops but its replacement fails' {
        . ([scriptblock]::Create((Get-SourceFunction 'host/windows.hyper-v/modules/Yuruna.Host.psm1' 'Add-PortMap')))
        function Test-Ipv4Address { return $true }
        function Test-IsAdministrator { return $true }
        function Get-PortMapStatePath { return (Join-Path $TestDrive 'port-map.json') }
        function Clear-AllCachingProxyServicePortMapping { return $true }
        function Stop-WindowsCachingProxyServiceForwarder { return $true }
        function Add-CachingProxyServiceFirewallRule { }
        function Start-WindowsCachingProxyServiceForwarder { return @{ Success = $false } }
        function netsh { }
        $output = @(Add-PortMap -VMIp '192.0.2.8' -Port 80 -ProxyProtocolPort 80 -Confirm:$false -WarningAction SilentlyContinue)
        $output.Count | Should -Be 1
        $output[0] | Should -BeFalse
    }
}
Describe 'Switch repair budgets survive JSON DateTime conversion and operator culture' {
    It 'ages and rewrites the same UTC state under <Culture>' -ForEach @(
        @{ Culture = 'en-US' }, @{ Culture = 'de-DE' }, @{ Culture = 'pt-BR' }, @{ Culture = 'th-TH' }
    ) {
        $source = Get-SourceFunction 'host/windows.hyper-v/modules/Yuruna.Host.psm1' 'Repair-YurunaExternalSwitch'
        $start = $source.IndexOf('    $attempts = 0')
        $end = $source.IndexOf('    if ($attempts -ge $MaxAttempts)', $start)
        $budget = $source.Substring($start, $end - $start)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $recordSource = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$record' }, $true).Extent.Text
        $priorCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
            $SwitchName = 'fixture'
            $ResetAfterHours = 24
            foreach ($age in 1, 25) {
                foreach ($asObject in $true, $false) {
                    $stamp = [datetime]::UtcNow.AddHours(-$age).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                    $state = @{ switchName = 'fixture'; attempts = 3; firstAttemptUtc = $stamp } | ConvertTo-Json | ConvertFrom-Json
                    if (-not $asObject) { $state.firstAttemptUtc = $stamp }
                    . ([scriptblock]::Create($budget))
                    $attempts | Should -Be $(if ($age -eq 25) { 0 } else { 3 })
                    $attempts++
                    . ([scriptblock]::Create($recordSource))
                    $record.firstAttemptUtc | Should -Match '^20\d\d-\d\d-\d\dT.*Z$'
                    if ($age -eq 1) { $record.firstAttemptUtc | Should -Be $stamp }
                }
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $priorCulture }
    }
}
Describe 'Windows ISO adoption follows the configured VHD root' {
    It 'copies an existing default ISO to the configured root before success' {
        $source = Get-Content (Join-Path $script:RepoRoot 'host/windows.hyper-v/guest.windows.11/Get-Image.ps1') -Raw
        $start = $source.IndexOf('# --- REGION: Short-circuit #2:')
        $end = $source.IndexOf('# --- REGION:', $start + 15)
        $body = $source.Substring($start, $end - $start)
        $defaultDownloadDir = Join-Path $TestDrive 'default'
        $downloadDir = Join-Path $TestDrive 'configured'
        [void](New-Item $defaultDownloadDir, $downloadDir -ItemType Directory)
        $defaultBaseFile = Join-Path $defaultDownloadDir 'fixture.iso'
        $baseImageFile = Join-Path $downloadDir 'fixture.iso'
        Set-Content $defaultBaseFile 'image-data'
        $fixture = Join-Path $TestDrive 'adopt.ps1'
        $variables = @('defaultDownloadDir', 'downloadDir', 'defaultBaseFile', 'baseImageFile') | ForEach-Object {
            '$' + $_ + " = '" + (Get-Variable $_ -ValueOnly).Replace("'", "''") + "'"
        }
        [IO.File]::WriteAllText($fixture, "function Format-YurunaOperatorMessage { 'fixture' }`n" + ($variables -join "`n") + "`n" + $body + "`nexit 9")
        & pwsh -NoProfile -NonInteractive -File $fixture | Out-Null
        $LASTEXITCODE | Should -Be 0
        Get-Content $baseImageFile -Raw | Should -Be (Get-Content $defaultBaseFile -Raw)
    }
}
Describe 'KVM capture lifetime belongs to its arming process' {
    It 'redirects all standard streams, bounds quiet captures, and kills the complete capture tree' {
        . ([scriptblock]::Create((Get-SourceFunction 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' 'Start-VMDhcpCapture')))
        . ([scriptblock]::Create((Get-SourceFunction 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' 'Stop-VMDhcpCapture')))
        function Get-YurunaGuestBridge { return @{ Bridge = 'fixture'; Network = 'fixture' } }
        function Get-VMMac { return '52:54:00:00:00:01' }
        function Get-Command { param($Name); return @{ Name = $Name } }
        function Start-Sleep { }
        function Write-YurunaDhcpGap { throw 'Unexpected capture failure' }
        function Start-Process {
            param($FilePath, $ArgumentList, [switch]$PassThru, [switch]$NoNewWindow,
                $RedirectStandardInput, $RedirectStandardOutput, $RedirectStandardError, $ErrorAction)
            $script:SpawnArguments = $ArgumentList
            $FilePath | Should -Be 'timeout'
            $RedirectStandardInput | Should -Match '\.stdin$'
            (Get-Item -LiteralPath $RedirectStandardInput).Length | Should -Be 0
            $RedirectStandardOutput | Should -Be '/dev/null'
            $RedirectStandardError | Should -Match '\.err$'
            $fixtureProcess = [pscustomobject]@{ HasExited = $false; EntireTree = $false }
            $fixtureProcess | Add-Member ScriptMethod Kill { param($EntireTree); $this.EntireTree = $EntireTree; $this.HasExited = $true }
            $fixtureProcess | Add-Member ScriptMethod WaitForExit { param($Timeout); return $Timeout -gt 0 }
            return $fixtureProcess
        }
        $script:YurunaDhcpCapture = $null
        $script:YurunaDhcpWireRefusal = ''
        Start-VMDhcpCapture -VMName ('fixture-' + [guid]::NewGuid().ToString('N')) | Should -BeTrue
        $script:SpawnArguments[0..3] | Should -Be @('--signal=TERM', '--kill-after=5s', '300s', 'tcpdump')
        $process = $script:YurunaDhcpCapture.Process
        Stop-VMDhcpCapture | Should -BeTrue
        $process.HasExited | Should -BeTrue
        $process.EntireTree | Should -BeTrue
    }
}
Describe 'KVM capture subprocess teardown' -Skip:(-not $IsLinux) {
    It 'releases the output pipe and capture process on <EndMode>' -ForEach @(
        @{ EndMode = 'process exit' }, @{ EndMode = 'module unload' }
    ) {
        $bin = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory $bin)
        $fakeCapture = Join-Path $bin 'tcpdump'
        $pidFile = Join-Path $bin 'capture.pid'
        [IO.File]::WriteAllText($fakeCapture, "#!/bin/bash`nprintf '%s\n' `"`$`$`" > `"`$YURUNA_CAPTURE_FIXTURE_PID`"`nsleep 30`n")
        [IO.File]::SetUnixFileMode($fakeCapture, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        $source = Get-Content (Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Raw
        $start = $source.IndexOf('$script:YurunaDhcpCapture = $null')
        $end = $source.IndexOf('# What last happened', $start)
        $moduleBody = $source.Substring($start, $end - $start)
        foreach ($name in 'Start-VMDhcpCapture', 'Stop-VMDhcpCapture') {
            $moduleBody += "`n" + (Get-SourceFunction 'host/ubuntu.kvm/modules/Yuruna.Host.psm1' $name)
        }
        $moduleBody += @'

function Get-YurunaGuestBridge { @{ Bridge = 'fixture'; Network = 'fixture' } }
function Get-VMMac { '52:54:00:00:00:01' }
function Write-YurunaDhcpGap { param($Reason) throw $Reason }
'@
        $modulePath = Join-Path $bin 'Yuruna.Host.psm1'
        [IO.File]::WriteAllText($modulePath, $moduleBody)
        $fixture = Join-Path $bin 'arm.ps1'
        $body = "`$ErrorActionPreference = 'Stop'`nImport-Module '" + $modulePath.Replace("'", "''") + "' -DisableNameChecking`n"
        $body += "if (-not (Start-VMDhcpCapture -VMName 'fixture-lifetime')) { throw 'not armed' }`n"
        if ($EndMode -eq 'module unload') { $body += "Remove-Module Yuruna.Host`n" }
        $body += "'child-finished'`n"
        [IO.File]::WriteAllText($fixture, $body)
        $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($argument in '-NoProfile', '-NonInteractive', '-File', $fixture) { $info.ArgumentList.Add($argument) }
        $info.Environment['PATH'] = $bin + [IO.Path]::PathSeparator + $env:PATH
        $info.Environment['YURUNA_CAPTURE_FIXTURE_PID'] = $pidFile
        $child = [Diagnostics.Process]::Start($info)
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        try {
            $child.WaitForExit(8000) | Should -BeTrue
            $stdout.Wait(1000) | Should -BeTrue
            $child.ExitCode | Should -Be 0 -Because $stderr.GetAwaiter().GetResult()
            $stdout.GetAwaiter().GetResult() | Should -Match 'child-finished'
            [IO.File]::Exists($pidFile) | Should -BeTrue
            $capturePid = [int][IO.File]::ReadAllText($pidFile)
            Get-Process -Id $capturePid -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            if (-not $child.HasExited) { $child.Kill($true) }
            $child.Dispose()
            if ([IO.File]::Exists($pidFile)) {
                $capturePid = [int][IO.File]::ReadAllText($pidFile)
                Stop-Process -Id $capturePid -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
