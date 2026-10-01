<#PSScriptInfo
.GUID 42be47e1-a8ca-4869-85bf-16e98c15bb5d
.LICENSEURI https://yuruna.link/license
.VERSION 2026.09.30
.BUILD 260927
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna review regression pester
.PROJECTURI https://yuruna.com
.DESCRIPTION
    Functional regression fixtures for runner, VM, and service failure handling.
#>
#requires -version 7
if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) { throw 'Run this suite with Pester.' }

BeforeAll {
    $script:Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:Repo 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1') -Global -DisableNameChecking
    foreach ($entry in @(
        @('host/ubuntu.kvm/modules/Yuruna.Host.psm1', 'Remove-KvmDomainDefinition'),
        @('host/ubuntu.kvm/modules/Yuruna.Host.psm1', 'Test-DriverNativeResultComplete'),
        @('host/ubuntu.kvm/modules/Yuruna.Host.psm1', 'New-KvmServiceDomain'),
        @('host/macos.utm/modules/Yuruna.Host.psm1', 'Write-UtmBundleConfiguration'),
        @('host/macos.utm/modules/Yuruna.Host.psm1', 'Test-UtmBoundedResultComplete'),
        @('host/windows.hyper-v/modules/Yuruna.Host.psm1', 'Get-WindowsDefaultIPv4Route'),
        @('host/windows.hyper-v/modules/Yuruna.Host.psm1', 'Get-WindowsDefaultRoutePhysicalAdapter'),
        @('test/modules/Test.ServiceVm.psm1', 'Invoke-YurunaServiceVmBuild'),
        @('test/modules/Test.ServiceVm.psm1', 'Invoke-YurunaServiceVmFailureDiagnostic'),
        @('test/modules/Test.HostCondition.Windows.psm1', 'Get-WindowsVhdxFilterIssue'),
        @('test/modules/Test.SequenceHandler.psm1', 'Restore-SequenceSnapshot'),
        @('test/modules/Test.RunnerInnerLoop.psm1', 'Invoke-BoundedHostSystemDiagnostic')
    )) {
        $function = Get-YurunaTestFunctionAst -Path (Join-Path $script:Repo $entry[0]) -Name $entry[1]
        . ([scriptblock]::Create($function.Extent.Text))
    }
    Import-Module (Join-Path $script:Repo 'automation/Yuruna.Common.psm1') -Global -DisableNameChecking -Verbose:$false
    $script:VirshUri = 'qemu:///system'
    $script:AntiVirusAltitudeMin = 320000
    $script:AntiVirusAltitudeMax = 329998
}

Describe 'local review functional regressions' {
    It 'retains polluted handler output so the engine can reject it' {
        Register-SequenceAction -Name 'review-output-fixture' -Handler { 'unexpected progress'; return $false }
        $result = Invoke-SequenceActionHandler -Name 'review-output-fixture' -Context @{}
        $result.Count | Should -Be 2
        $result[-1] | Should -BeFalse
        ($result -is [bool]) | Should -BeFalse
    }

    It 'bounds the shared OCR history and removes evicted sidecars' {
        $queue = [Collections.Generic.Queue[string]]::new()
        foreach ($index in 1..3) {
            $path = Join-Path $TestDrive "raw_$index.png"
            [IO.File]::WriteAllText($path, 'frame')
            [IO.File]::WriteAllText([IO.Path]::ChangeExtension($path, '.txt'), 'ocr')
            Add-OcrHistoryFrame -Queue $queue -Path $path -Limit 2
        }
        $queue.Count | Should -Be 2
        Test-Path (Join-Path $TestDrive 'raw_1.png') | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'raw_1.txt') | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'raw_2.txt') | Should -BeTrue
    }

    It 'does not treat a neighboring Defender path as VHDX coverage' {
        $filterReading = @{ VhdxPath = 'D:\VMs\guest.vhdx'; VhdxVolume = 'D:'; Filters = @(@{ Name = 'scanner'; Altitude = 325000 }); Exclusions = @('D:\VM') }
        (Get-WindowsVhdxFilterIssue $filterReading).Issue.Count | Should -Be 2
        $filterReading.Exclusions = @('D:\VMs')
        (Get-WindowsVhdxFilterIssue $filterReading).Issue.Count | Should -Be 1
        $filterReading.Exclusions = @()
        $filterReading.ExclusionExtensions = @('.vhdx')
        (Get-WindowsVhdxFilterIssue $filterReading).Issue.Count | Should -Be 1
        $filterReading.ExclusionExtensions = @()
        $filterReading.ExclusionProcesses = @('C:\Windows\System32\vmwp.exe')
        (Get-WindowsVhdxFilterIssue $filterReading).Issue.Count | Should -Be 1
    }

    It 'rejects a failed ordered status record after restoring and invalidates the old address' {
        $script:ClearedAddress = ''
        function Restore-VMDiskSnapshot { [CmdletBinding(SupportsShouldProcess)] [OutputType([bool])] param($VMName, $Id) [void]$Id; return $PSCmdlet.ShouldProcess($VMName, 'Fixture restore') }
        function Clear-ProvenGuestAddress { param($VMName) $script:ClearedAddress = $VMName }
        function Start-VM { [CmdletBinding(SupportsShouldProcess)] [OutputType([string], [Collections.Specialized.OrderedDictionary])] param($VMName) $null = $PSCmdlet.ShouldProcess($VMName, 'Fixture start'); 'progress'; [ordered]@{ success = $false; errorMessage = 'start refused' } }
        function Test-VMDiskSnapshot { param($VMName, $Id) [void]$VMName; [void]$Id; return $true }
        function Test-SnapshotManifestMatch { param($VMName, $SnapshotId, $HostType) [void]$VMName; [void]$SnapshotId; [void]$HostType; return @{ Status = 'matched' } }
        Restore-SequenceSnapshot -c @{ VMName = 'fixture-vm'; HostType = 'host.ubuntu.kvm' } -snapId 'fixture-snapshot' -WarningAction SilentlyContinue | Should -BeFalse
        $script:ClearedAddress | Should -Be 'fixture-vm'
    }

    It 'bounds a stalled cycle startup diagnostic and leaves a timeout record' {
        $scriptPath = Join-Path $TestDrive 'stalled-diagnostic.ps1'
        $output = Join-Path $TestDrive 'diagnostic.txt'
        [IO.File]::WriteAllText($scriptPath, 'param([string]$OutFile) Start-Sleep -Seconds 30')
        $priorJobs = @(Get-Job).Count
        $timer = [Diagnostics.Stopwatch]::StartNew()
        Invoke-BoundedHostSystemDiagnostic -ScriptPath $scriptPath -OutFile $output -TimeoutSeconds 1
        $timer.Elapsed.TotalSeconds | Should -BeLessThan 15
        Test-Path $output | Should -BeTrue
        @(Get-Job).Count | Should -Be $priorJobs
    }
}

Describe 'shared local VM and service primitives' {
    It 'refuses KVM replacement when undefine leaves the domain registered' {
        function Invoke-VirshBounded { param($VirshArgs, $TimeoutSeconds) [void]$TimeoutSeconds; return @{ Started = $true; ExitCode = 0; Stdout = $(if ($VirshArgs[0] -eq 'list') { 'review-domain' } else { 'still defined' }); Stderr = '' } }
        { Remove-KvmDomainDefinition -VMName 'review-domain' -Confirm:$false } | Should -Throw
    }
    It 'does not infer KVM absence from an incomplete listing' {
        function Invoke-VirshBounded { param($VirshArgs, $TimeoutSeconds) [void]$TimeoutSeconds; return @{ Started = $true; ExitCode = 0; Stdout = ''; Stderr = ''; TimedOut = ($VirshArgs[0] -eq 'list') } }
        { Remove-KvmDomainDefinition -VMName 'review-domain' -Confirm:$false } | Should -Throw
    }
    It 'preserves KVM service memory, MAC, reboot and guest-agent configuration' {
        $script:InstallArguments = @()
        function Resolve-KvmOsVariant { param($Candidates) [void]$Candidates; return 'ubuntu26.04' }
        # nproc is a Linux tool and the function refuses a host under four cores,
        # so the count is fixed instead of read from whichever host runs the case.
        function nproc { return '8' }
        function Invoke-BoundedNativeCommand { param($FilePath, $ArgumentList, $TimeoutSeconds) [void]$FilePath; [void]$TimeoutSeconds; $script:InstallArguments = $ArgumentList; return @{ Started = $true; ExitCode = 0; Stdout = ''; Stderr = '' } }
        New-KvmServiceDomain -VMName 'review-domain' -DiskPath '/tmp/review-disk' -SeedPath '/tmp/review-seed' -NetworkName 'default' -MemoryMb 4096 -MacAddress '02:01:02:03:04:05' -Confirm:$false | Should -BeTrue
        $joined = $script:InstallArguments -join ' '
        $joined | Should -Match '--memory 4096'
        $joined | Should -Match 'network=default,model=virtio,mac=02:01:02:03:04:05'
        $joined | Should -Match 'on_reboot=restart'
        $joined | Should -Match 'org.qemu.guest_agent.0'
    }
    It 'renders UTM XML values literally and validates the written configuration' {
        $bundle = Join-Path $TestDrive 'review.utm'
        New-Item -ItemType Directory $bundle | Out-Null
        $template = Join-Path $TestDrive 'template.plist'
        [IO.File]::WriteAllText($template, '<plist><dict><key>Name</key><string>__VM_NAME__</string></dict></plist>')
        function Invoke-UtmHostTool { param($Tool, $ArgumentList, $TimeoutSeconds) [void]$ArgumentList; [void]$TimeoutSeconds; $Tool | Should -Be 'plutil'; return @{ Started = $true; ExitCode = 0; Stdout = 'OK'; Stderr = '' } }
        Write-UtmBundleConfiguration -TemplatePath $template -BundlePath $bundle -Replacement @{ '__VM_NAME__' = 'name $& <literal>' } -Confirm:$false
        $xml = [xml][IO.File]::ReadAllText((Join-Path $bundle 'config.plist'))
        $xml.plist.dict.string | Should -BeExactly 'name $& <literal>'
        function Invoke-UtmHostTool { param($Tool, $ArgumentList, $TimeoutSeconds) [void]$Tool; [void]$ArgumentList; [void]$TimeoutSeconds; return @{ Started = $true; ExitCode = 42; Stdout = 'bad plist'; Stderr = '' } }
        { Write-UtmBundleConfiguration -TemplatePath $template -BundlePath $bundle -Replacement @{ '__VM_NAME__' = 'guest' } -Confirm:$false } | Should -Throw
    }
    It 'ranks route and interface metrics and resolves every external team member' {
        function Get-NetRoute { param($AddressFamily, $DestinationPrefix, $ErrorAction) [void]$AddressFamily; [void]$DestinationPrefix; [void]$ErrorAction
            [pscustomobject]@{ NextHop='192.0.2.1'; RouteMetric=10; InterfaceMetric=20; InterfaceIndex=1 }
            [pscustomobject]@{ NextHop='192.0.2.1'; RouteMetric=10; InterfaceMetric=5; InterfaceIndex=2 }
            [pscustomobject]@{ NextHop='0.0.0.0'; RouteMetric=0; InterfaceMetric=0; InterfaceIndex=3 }
        }
        (Get-WindowsDefaultIPv4Route).InterfaceIndex | Should -Be 2
        function Get-NetAdapter { param($InterfaceIndex, $ErrorAction) [void]$ErrorAction
            if ($InterfaceIndex) { [pscustomobject]@{ InterfaceDescription='Hyper-V Virtual Ethernet Adapter'; InterfaceAlias='vEthernet (team)' } }
            else { [pscustomobject]@{ InterfaceDescription='wired' }; [pscustomobject]@{ InterfaceDescription='usb' }; [pscustomobject]@{ InterfaceDescription='unrelated' } }
        }
        function Get-VMSwitch { param($ErrorAction) [void]$ErrorAction; [pscustomobject]@{ Name='team'; SwitchType='External' } }
        function Get-YurunaSwitchUplinkDescription { param($SwitchRecord) [void]$SwitchRecord; 'wired'; 'usb' }
        $members = @(Get-WindowsDefaultRoutePhysicalAdapter)
        $members.Count | Should -Be 2
        $members.InterfaceDescription | Should -Contain 'usb'
    }
    It 'keeps the original proxy backup across repeated promotions' {
        $path = Join-Path $TestDrive 'proxy.json'
        $script:BackupReads = 0
        Save-YurunaHostProxyBackup -Path $path -PromotedTo 'http://first:3128' -ReadState { $script:BackupReads++; @{ previousUrl = 'http://original:8080' } }
        Save-YurunaHostProxyBackup -Path $path -PromotedTo 'http://second:3128' -ReadState { $script:BackupReads++; @{ previousUrl = 'http://first:3128' } }
        $script:BackupReads | Should -Be 1
        (Read-YurunaHostProxyBackup -Path $path).previousUrl | Should -Be 'http://original:8080'
        (Read-YurunaHostProxyBackup -Path $path).promotedTo | Should -Be 'http://first:3128'
        Remove-YurunaHostProxyBackup -Path $path -Confirm:$false
        Test-Path $path | Should -BeFalse
    }
    It 'stops service startup at a failed child builder without claiming a running guest' {
        $builder = Join-Path $TestDrive 'failed-builder.ps1'
        [IO.File]::WriteAllText($builder, 'param($VMName, [switch]$AllowPseudoLocale) exit 23')
        function Test-YurunaServiceOperationCurrent { param($Context) [void]$Context; return $true }
        function Wait-VMRunning { param($VMName, $TimeoutSeconds) [void]$VMName; [void]$TimeoutSeconds; throw 'must not check running after a failed build' }
        $result = Invoke-YurunaServiceVmBuild -BuilderPath $builder -HostType 'host.ubuntu.kvm' -VMName 'review-domain' -OperationContext @{} -Confirm:$false
        $result.Ok | Should -BeFalse
        $result.ExitCode | Should -Be 23
    }
    It 'retains partial SSH diagnostics when the guest command fails' {
        function Initialize-YurunaLogDir { return $TestDrive }
        function Get-VMScreenshot { param($VMName, $OutFile) [void]$VMName; [void]$OutFile; return $true }
        function Invoke-GuestSsh { param($VMName,$GuestKey,$User,$Command,$TimeoutSeconds)
            $VMName | Should -Be '192.0.2.42'; $GuestKey | Should -Be 'guest.stash-service'; $User | Should -Be 'stash-admin'; $TimeoutSeconds | Should -Be 120
            $Command | Should -Match 'cloud-init status'; $Command | Should -Match 'journalctl'; $Command | Should -Match 'findmnt --'
            return @{ success=$false; exitCode=23; output='partial cloud-init evidence' }
        }
        $capture = @(Invoke-YurunaServiceVmFailureDiagnostic -ServiceName 'stash-service' -GuestKey 'guest.stash-service' -User 'stash-admin' -VMName 'review-domain' -Address '192.0.2.42' -MountPath '/mnt/stash' 6>&1 | ForEach-Object { [string]$_ }) -join "`n"
        $capture | Should -Match 'partial cloud-init evidence'
        $capture | Should -Match 'capture returned no frame'
    }
}
